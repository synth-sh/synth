const std = @import("std");

const Conversation = @import("../core/conversation.zig");
const Hooks = @import("../core/hooks.zig");

/// The seam every model backend plugs into.
const Provider = @This();

userdata: *anyopaque,
respond: *const fn (*anyopaque, *Conversation, Turn, std.mem.Allocator, ?Sink) anyerror!Reply,
name: []const u8,
/// The model tag this provider is talking to, e.g. `qwen3`. Distinct from
/// `name`, which is the backend ("Ollama"). Shown together as
/// "model · backend".
model: []const u8 = "",
observes_attempts: bool = false,
/// Context window in tokens, or 0 when unknown.
context_limit: u32 = 0,
/// Whether the model can be shown images. False means an attached image is
/// dropped from the request, which the composer says up front rather than
/// letting it be sent into a void.
vision: bool = true,
/// The reasoning effort in force, or "" for a backend that has no such setting.
effort: []const u8 = "",

/// Models this backend can be pointed at. Null when it has only one, which is
/// why the UI asks rather than assuming - a hosted backend may not offer a
/// choice at all. Caller owns the result and each name.
list_models: ?*const fn (*anyopaque, std.mem.Allocator) anyerror![][]const u8 = null,
/// Switch models mid-session, returning what the caller should now display.
/// Null alongside `list_models`.
set_model: ?*const fn (*anyopaque, []const u8) anyerror!Current = null,
/// What the backend is pointed at now. Called after a turn lands: the window a
/// model is *loaded* with is not knowable until it is running.
refresh: ?*const fn (*anyopaque) Current = null,
/// Point the backend at another endpoint, with another credential, and say
/// what it is running as afterwards. Null for a backend with nothing to
/// connect to - a local process, a fake in a test.
reconnect: ?*const fn (*anyopaque, Connection) anyerror!Current = null,
/// Turn an error from `respond` into something a person can act on. Optional;
/// without it the caller has only the error name.
describe_error: ?*const fn (*anyopaque, anyerror, std.mem.Allocator) anyerror![]const u8 = null,
/// The reasoning effort levels a model accepts. Borrowed until a reconnect.
efforts: ?*const fn (*anyopaque, []const u8) Efforts = null,
/// Ask for one of `efforts` from the next turn on; "" returns to the model's
/// own default, and so does a level the current model does not offer.
set_effort: ?*const fn (*anyopaque, []const u8) void = null,
/// Break off whatever `respond` is waiting on, from another thread.
///
/// Signalling a worker parked in a socket read does not wake it; the read
/// returns when the response does, which for a model mid-answer is however
/// long it has left. Shutting the socket down is what makes it return now.
/// Null for a backend with nothing to break off.
abort: ?*const fn (*anyopaque) void = null,

/// Everything one call needs that is not the transcript. Assembled by the
/// caller: which agent is in force, what it may call and what it was told are
/// decisions a backend has no business making, and a backend that assembled its
/// own prompt would have to be told about agents to do it.
pub const Turn = struct {
    backend: ?*@import("backend.zig") = null,
    stop: ?*const std.atomic.Value(bool) = null,
    model_policy: @import("../core/model_policy.zig").Policy = .{},
    settings: @import("../core/model_policy.zig").Settings = .{},
    /// The system prompt, complete. Borrowed for the length of the call.
    system: []const u8,
    /// Tool definitions as JSON, from `Registry.schemaJson`. Empty means the
    /// model is told about no tools at all.
    tools_json: []const u8 = "",
    /// A one-off instruction, sent as the last user message and not part of the
    /// transcript. Compaction is what this is for.
    instruction: []const u8 = "",
    /// Reserve less output space while summarizing, but never discard history.
    compacting: bool = false,
    display_messages: bool = false,
    stream_display: bool = true,
    hooks: ?*const Hooks.Runner = null,
    attempts: ?*std.atomic.Value(u32) = null,
    hook_input: Hooks.Invocation = .{ .event = .pre_model_request },
};

pub const Attempt = struct {
    allocator: std.mem.Allocator,
    turn: Turn,
    sink: ?Sink,
    status: enum { failed, completed, cancelled } = .failed,
    finished: bool = false,
    error_message: []const u8 = "",
    usage: Usage = .{},

    pub fn begin(turn: Turn, allocator: std.mem.Allocator, sink: ?Sink) Attempt {
        var attempt: Attempt = .{ .allocator = allocator, .turn = turn, .sink = sink };
        attempt.turn.hook_input.attempt = if (turn.attempts) |counter| counter.fetchAdd(1, .acq_rel) + 1 else 1;
        attempt.emit(.pre_model_request);
        return attempt;
    }
    pub fn complete(self: *Attempt, usage: Usage) void {
        self.status = .completed;
        self.usage = usage;
    }
    pub fn finish(self: *Attempt) void {
        if (self.finished) return;
        self.finished = true;
        if (self.sink) |sink| {
            if (sink.stopped(sink.userdata)) self.status = .cancelled;
        }
        self.emit(.post_model_request);
    }
    fn emit(self: *Attempt, event: Hooks.Event) void {
        const configured = self.turn.hooks orelse return;
        var runner = configured.*;
        runner.stop = null;
        const cleaning_up = event == .post_model_request and self.status == .cancelled;
        const protection = if (cleaning_up) runner.io.swapCancelProtection(.blocked) else null;
        defer if (protection) |previous| {
            _ = runner.io.swapCancelProtection(previous);
        };
        if (cleaning_up) {
            runner.timeout_ms = @min(runner.timeout_ms, 1000);
            runner.deadline_ms = std.Io.Clock.now(.awake, runner.io).toMilliseconds() + 3000;
        }
        var invocation = self.turn.hook_input;
        invocation.event = event;
        invocation.status = if (event == .post_model_request) @tagName(self.status) else "";
        invocation.error_message = self.error_message;
        invocation.input_tokens = self.usage.prompt_tokens;
        invocation.output_tokens = self.usage.completion_tokens;
        var result = runner.evaluate(self.allocator, invocation) catch |err| {
            if (runner.runtime) |runtime| {
                const message = std.fmt.allocPrint(self.allocator, "{s} hook failed: {s}", .{ event.name(), @errorName(err) }) catch return;
                defer self.allocator.free(message);
                runtime.notice(message) catch {};
            }
            return;
        };
        defer result.deinit(self.allocator);
        if (result.message) |message| {
            if (runner.runtime) |runtime| runtime.notice(message) catch {};
        }
    }
};

/// Where a backend should point, and what to call it there. The label is the
/// provider's, not the backend's: one ollama client serves both the server on
/// this machine and the hosted one, and the sidebar has to say which.
pub const Connection = struct {
    label: []const u8,
    host: []const u8,
    api_key: ?[]const u8 = null,
};

/// What a backend is pointed at right now. `model` and `name` are owned by the
/// provider and stay valid until the next switch.
pub const Current = struct {
    model: []const u8,
    /// What the backend is called now, e.g. "Ollama Cloud".
    name: []const u8 = "",
    context_limit: u32 = 0,
    vision: bool = true,
    effort: []const u8 = "",
};

/// Whether this backend can be pointed somewhere else at runtime.
pub fn connectable(self: Provider) bool {
    return self.reconnect != null;
}

/// Re-read what the backend is pointed at, for a caller holding a copy of this
/// struct that may have gone stale. Cheap: no I/O, only what the backend has
/// already learned.
pub fn current(self: Provider) Current {
    const refresh = self.refresh orelse return .{
        .model = self.model,
        .name = self.name,
        .context_limit = self.context_limit,
        .vision = self.vision,
        .effort = self.effort,
    };
    return refresh(self.userdata);
}

/// The reasoning effort levels a model accepts, and the one it runs at when
/// none is chosen. Empty for a model, or a backend, with no such setting.
pub const Efforts = struct {
    /// Mildest first.
    levels: []const []const u8 = &.{},
    default: []const u8 = "",

    /// `wanted` when it is on offer, else the default.
    pub fn pick(self: Efforts, wanted: []const u8) []const u8 {
        for (self.levels) |level| {
            if (std.mem.eql(u8, level, wanted)) return level;
        }
        return self.default;
    }
};

pub fn effortsFor(self: Provider, model: []const u8) Efforts {
    const efforts = self.efforts orelse return .{};
    return efforts(self.userdata, model);
}

pub fn mentionsOverflow(why: []const u8) bool {
    const needles: []const []const u8 = &.{
        "context length",  "context window",      "too long",     "too large",
        "too many token",  "exceeds",             "input length", "token limit",
        "maximum context", "must have less than",
    };
    for (needles) |needle| {
        if (containsIgnoreCase(why, needle)) return true;
    }
    return false;
}

pub fn errorType(err: anyerror, details: []const u8) []const u8 {
    switch (err) {
        error.ContextTooLarge => return "invalid_request",
        error.RateLimit => return "rate_limit",
        error.Unauthorized, error.NotSignedIn => return "authentication_failed",
        error.ModelNotFound => return "model_not_found",
        error.Overloaded => return "overloaded",
        error.BillingError => return "billing_error",
        else => {},
    }
    inline for (.{ .{ "HTTP 429", "rate_limit" }, .{ "HTTP 401", "authentication_failed" }, .{ "HTTP 403", "authentication_failed" }, .{ "HTTP 500", "server_error" }, .{ "HTTP 502", "server_error" }, .{ "HTTP 503", "server_error" } }) |entry| {
        if (containsIgnoreCase(details, entry[0])) return entry[1];
    }
    return "unknown";
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// What went wrong, in the backend's own words where it has any. Caller owns
/// the result.
pub fn explain(self: Provider, err: anyerror, allocator: std.mem.Allocator) ![]const u8 {
    if (err == error.ContextTooLarge) return allocator.dupe(u8, "Context is full. History was preserved. Use /compact or a model with a larger context window.");
    const describe = self.describe_error orelse
        return std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
    return describe(self.userdata, err, allocator) catch
        std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)});
}

/// Whether this backend offers a choice of model.
pub fn switchable(self: Provider) bool {
    return self.list_models != null and self.set_model != null;
}

/// The models on offer, newest first. Empty when the backend has no choice.
pub fn models(self: Provider, allocator: std.mem.Allocator) ![][]const u8 {
    const list = self.list_models orelse return allocator.alloc([]const u8, 0);
    return list(self.userdata, allocator);
}

/// What a turn cost. Zero when the provider does not report it.
pub const Usage = struct {
    /// Tokens in the request. Doubles as "how full is the context", since the
    /// whole conversation is resent each turn.
    prompt_tokens: u32 = 0,
    /// The part of `prompt_tokens` served from the provider's prompt cache,
    /// where it says.
    cached_tokens: u32 = 0,
    /// The part of `prompt_tokens` written to the prompt cache, where the
    /// provider says.
    cache_write_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    /// The part of `completion_tokens` spent reasoning, where the provider says.
    reasoning_tokens: u32 = 0,
    /// Time spent generating, for a tokens-per-second figure.
    eval_duration_ns: u64 = 0,
};

/// One turn from the model: prose, tool calls, or both.
pub const Reply = struct {
    /// Allocated with the respond allocator; owned by the caller.
    text: []const u8 = "",
    /// Tool calls the model wants run. Owned by the caller, which frees each
    /// call with `Conversation.ToolCall.deinit`.
    tool_calls: []Conversation.ToolCall = &.{},
    /// The provider's own record of this turn, replayed verbatim on later
    /// turns. Opaque to everything but the provider that wrote it.
    provider_state: ?[]const u8 = null,
    usage: Usage = .{},

    pub fn deinit(self: *Reply, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.tool_calls) |*call| call.deinit(allocator);
        allocator.free(self.tool_calls);
        if (self.provider_state) |state| allocator.free(state);
    }
};

pub const RetryInfo = struct {
    attempt: usize,
    allowed: bool,
    delay_ms: u64,
    status: u16 = 0,
    error_type: []const u8 = "",
    error_message: []const u8 = "",
};

/// Callbacks run on the provider worker thread.
pub const Sink = struct {
    onRetry: ?*const fn (*anyopaque, RetryInfo) ?u64 = null,

    userdata: *anyopaque,
    /// A fragment of the model's thinking output.
    onThinking: *const fn (*anyopaque, []const u8) void,
    /// A fragment of the model's answer. Without this the reply only appears
    /// once the whole turn lands, which reads as a hang on a long answer.
    onText: *const fn (*anyopaque, []const u8) void,
    /// The model has stopped reasoning and started answering. What follows can
    /// take far longer than the thinking did - a tool call whose arguments are
    /// a whole file, say - so a UI timing the thought needs to be told where it
    /// ended. Defaulted: a provider that cannot tell simply never calls it.
    onThinkingDone: *const fn (*anyopaque) void = ignoreThinkingDone,
    /// Whether the caller has given up on this turn. A worker thread cannot be
    /// killed, so a provider that streams must check between chunks and return
    /// early - otherwise quitting mid-turn blocks until the model is done.
    stopped: *const fn (*anyopaque) bool,
    pub fn retryDecision(self: Sink, info: RetryInfo) ?u64 {
        if (self.onRetry) |callback| return callback(self.userdata, info);
        return if (info.allowed) info.delay_ms else null;
    }
};

fn ignoreThinkingDone(_: *anyopaque) void {}

test "a TGI length refusal reads as an overflow, a quota refusal does not" {
    const testing = std.testing;
    try testing.expect(mentionsOverflow("Input validation error: `inputs` must have less than 2048 tokens. Given: 4194"));
    try testing.expect(!mentionsOverflow("You exceeded your current quota, please check your plan and billing details."));
}

test "error classification does not mistake token counts for HTTP failures" {
    const testing = std.testing;
    try testing.expectEqualStrings("unknown", errorType(error.HttpError, "context service rejected 1500 tokens"));
    try testing.expectEqualStrings("invalid_request", errorType(error.ContextTooLarge, "HTTP 503"));
    try testing.expectEqualStrings("server_error", errorType(error.HttpError, "HTTP 503: unavailable"));
}

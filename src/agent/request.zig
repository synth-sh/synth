//! One provider turn, running off the UI's event loop.

const std = @import("std");

const Provider = @import("../provider/provider.zig");
const Conversation = @import("../core/conversation.zig");
const Thought = @import("thought.zig");
const tool = @import("../tools/tool.zig");

const Request = @This();
const Preparation = @import("request_prepare.zig");
const display_id_bytes = 64;

allocator: std.mem.Allocator,
io: std.Io,
provider: Provider,
provider_mutex: std.Io.Mutex = .init,
owned_backend: ?*@import("../provider/backend.zig").Spawned = null,
prepared_conversation: ?Conversation = null,
allowed_tools: ?[]const []const u8 = null,
completed_ms: i64 = 0,
conversation: *Conversation,
/// Owned copy of the turn's strings: the loop is free to rebuild its prompt or
/// switch agents while this is in flight.
turn: Provider.Turn,
hook_arena: std.heap.ArenaAllocator,
attempt_number: std.atomic.Value(u32) = .init(0),
thoughts: Thought.Stream,
/// The answer as it arrives, for the UI to render before the turn lands.
content: Thought.Stream,
display_pending: std.ArrayList(u8) = .empty,
display_index: usize = 0,
display_bytes: usize = 0,
display_failed: bool = false,
display_id: [display_id_bytes]u8 = @splat(0),
display_id_len: usize = 0,

future: std.Io.Future(void) = undefined,
/// Whether the future has been awaited and freed. Awaiting twice is undefined,
/// and cancelling happens on a worker thread while the owner still holds this.
reaped: bool = false,
done: std.atomic.Value(bool) = .init(false),
/// A cooperative nudge, checked by the provider between chunks. Cancellation
/// proper is `cancel`; this is the cheap non-blocking half, and it covers the
/// case where a provider swallows `error.Canceled` from an inner call.
stop: std.atomic.Value(bool) = .init(false),
/// When a chunk last arrived, on the monotonic clock. A dead connection and a
/// thinking model differ only in how long the silence runs.
progress_ms: std.atomic.Value(i64) = .init(0),
/// Allocated with `allocator`; ownership passes to whoever calls `join`.
reply: ?Provider.Reply = null,
failed: ?anyerror = null,

/// Spawn the worker. The returned request is owned by the caller, which must
/// eventually call `join` or `cancel`, then `destroy`.
pub fn start(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: Provider,
    conversation: *Conversation,
    turn: Provider.Turn,
) !*Request {
    const self = try allocator.create(Request);
    errdefer allocator.destroy(self);

    self.* = .{
        .allocator = allocator,
        .io = io,
        .provider = provider,
        .conversation = conversation,
        .turn = .{
            .backend = turn.backend,
            .model_policy = turn.model_policy,
            .settings = turn.settings,
            .system = try allocator.dupe(u8, turn.system),
            .tools_json = try allocator.dupe(u8, turn.tools_json),
            .instruction = try allocator.dupe(u8, turn.instruction),
            .compacting = turn.compacting,
            .display_messages = turn.display_messages,
            .stream_display = turn.stream_display,
            .hooks = turn.hooks,
            .hook_input = turn.hook_input,
        },
        .hook_arena = .init(allocator),
        .thoughts = .init(allocator, io),
        .content = .init(allocator, io),
        .progress_ms = .init(tool.monotonicMilliseconds(io)),
    };
    errdefer {
        self.freeTurn();
        self.thoughts.deinit();
        self.content.deinit();
    }

    self.turn.hook_input = try turn.hook_input.dupe(self.hook_arena.allocator());
    self.turn.hook_input.model = try self.hook_arena.allocator().dupe(u8, provider.model);
    self.turn.hook_input.provider = try self.hook_arena.allocator().dupe(u8, provider.name);
    if (turn.compacting) self.turn.hook_input.request_purpose = .compaction;
    self.turn.attempts = &self.attempt_number;
    self.turn.stop = &self.stop;
    self.display_id_len = (try std.fmt.bufPrint(&self.display_id, "{s}-{d}", .{ turn.hook_input.agent_id, turn.hook_input.request_id })).len;
    if (self.turn.hooks) |runner| if (runner.runtime) |runtime| runtime.retainSnapshot(self.turn.hook_input.transcript_path);
    errdefer if (self.turn.hooks) |runner| if (runner.runtime) |runtime| runtime.releaseSnapshot(self.turn.hook_input.transcript_path);
    self.future = try io.concurrent(run, .{self});
    return self;
}

pub fn ownBackend(self: *Request) !*@import("../provider/backend.zig").Spawned {
    if (self.owned_backend) |owned| return owned;
    const backend = self.turn.backend orelse return error.ModelRoutingUnavailable;
    const owned = try backend.spawn(self.allocator);
    self.provider_mutex.lockUncancelable(self.io);
    defer self.provider_mutex.unlock(self.io);
    self.owned_backend = owned;
    self.provider = owned.provider();
    return owned;
}

/// Non-blocking check for the owning thread.
pub fn isFinished(self: *Request) bool {
    return self.done.load(.acquire);
}

/// Ask the provider to give up, and break off whatever it is waiting on.
///
/// Non-blocking. The flag is checked between chunks; the abort is what reaches
/// a worker parked in a socket read, which no flag ever does.
pub fn requestStop(self: *Request) void {
    self.stop.store(true, .release);
    self.provider_mutex.lockUncancelable(self.io);
    defer self.provider_mutex.unlock(self.io);
    if (self.provider.abort) |abort| abort(self.provider.userdata);
}

pub fn stalled(self: *Request, limit_ms: i64) bool {
    if (limit_ms <= 0) return false;
    if (self.isFinished()) return false;
    const quiet = tool.monotonicMilliseconds(self.io) - self.progress_ms.load(.acquire);
    return quiet >= limit_ms;
}

pub fn join(self: *Request) void {
    if (self.reaped) return;
    self.reaped = true;
    self.future.await(self.io);
    if (self.turn.backend) |backend| if (self.owned_backend) |child| backend.rememberTransport(child, self.turn.hook_input.request_purpose);
}

/// Interrupt the turn and wait for it to unwind.
///
/// Blocks for as long as the worker takes to notice, which for a provider
/// midway through a socket read is not bounded by anything this side controls.
/// Never call it from the thread drawing the screen.
pub fn cancel(self: *Request) void {
    if (self.reaped) return;
    self.reaped = true;
    self.requestStop();
    self.future.cancel(self.io);
}

pub fn destroy(self: *Request) void {
    const allocator = self.allocator;
    self.thoughts.deinit();
    self.content.deinit();
    self.display_pending.deinit(allocator);
    if (self.reply) |*reply| reply.deinit(allocator);
    if (self.turn.hooks) |runner| if (runner.runtime) |runtime| runtime.releaseSnapshot(self.turn.hook_input.transcript_path);
    self.freeTurn();
    if (self.prepared_conversation) |*convo| convo.deinit();
    if (self.owned_backend) |owned| owned.deinit();
    allocator.destroy(self);
}

fn freeTurn(self: *Request) void {
    self.hook_arena.deinit();
    self.allocator.free(self.turn.system);
    self.allocator.free(self.turn.tools_json);
    self.allocator.free(self.turn.instruction);
}

fn run(self: *Request) void {
    defer {
        self.completed_ms = tool.monotonicMilliseconds(self.io);
        self.done.store(true, .release);
    }
    defer self.finishDisplay();

    Preparation.prepare(self) catch |err| {
        self.failed = err;
        return;
    };

    var attempt: ?Provider.Attempt = if (self.provider.observes_attempts) null else Provider.Attempt.begin(self.turn, self.allocator, .{
        .userdata = self,
        .onThinking = onThinking,
        .onText = onText,
        .stopped = stopped,
    });
    defer if (attempt) |*value| {
        if (self.reply) |reply| value.complete(reply.usage);
        if (self.failed) |err| value.error_message = @errorName(err);
        value.finish();
    };
    if (self.stop.load(.acquire)) {
        self.failed = error.Canceled;
        return;
    }
    self.reply = self.provider.respond(
        self.provider.userdata,
        if (self.prepared_conversation) |*convo| convo else self.conversation,
        self.turn,
        self.allocator,
        .{
            .userdata = self,
            .onThinking = onThinking,
            .onText = onText,
            .onRetry = Preparation.onRetry,
            .onThinkingDone = onThinkingDone,
            .stopped = stopped,
        },
    ) catch |err| {
        self.failed = err;
        return;
    };
    if (self.allowed_tools) |names| {
        calls: for (self.reply.?.tool_calls) |*call| {
            for (names) |name| if (std.mem.eql(u8, name, call.name)) continue :calls;
            call.status = .rejected;
            call.result = self.allocator.dupe(u8, "tool excluded from this model request") catch {
                self.failed = error.OutOfMemory;
                return;
            };
            call.result_bytes = call.result.?.len;
        }
    }
}

/// Worker thread, via the provider's sink.
fn onThinking(ptr: *anyopaque, bytes: []const u8) void {
    const self: *Request = @ptrCast(@alignCast(ptr));
    self.markProgress();
    self.thoughts.append(bytes);
}

/// Worker thread, via the provider's sink.
fn onText(ptr: *anyopaque, bytes: []const u8) void {
    const self: *Request = @ptrCast(@alignCast(ptr));
    self.markProgress();
    if (!self.displaysHooks()) {
        self.content.append(bytes);
        return;
    }
    self.display_bytes += bytes.len;
    if (!self.turn.stream_display) return;
    if (self.display_failed) {
        self.content.append(bytes);
        return;
    }
    self.display_pending.appendSlice(self.allocator, bytes) catch {
        self.content.append(self.display_pending.items);
        self.display_pending.clearRetainingCapacity();
        self.content.append(bytes);
        self.display_failed = true;
        return;
    };
    if (std.mem.lastIndexOfScalar(u8, self.display_pending.items, '\n')) |last| {
        self.displayBatch(self.display_pending.items[0 .. last + 1], false);
        const remaining = self.display_pending.items.len - last - 1;
        std.mem.copyForwards(u8, self.display_pending.items[0..remaining], self.display_pending.items[last + 1 ..]);
        self.display_pending.shrinkRetainingCapacity(remaining);
    }
}

pub fn displaysHooks(self: *const Request) bool {
    if (!self.turn.display_messages) return false;
    const runner = self.turn.hooks orelse return false;
    var input = self.turn.hook_input;
    input.event = .message_display;
    const current = self.provider.current();
    input.model = current.model;
    input.provider = if (current.name.len > 0) current.name else self.provider.name;
    return runner.hasMatching(self.allocator, input, true);
}

fn displayBatch(self: *Request, delta: []const u8, final: bool) void {
    var runner = self.turn.hooks.?.*;
    runner.stop = &self.stop;
    var input = self.turn.hook_input;
    input.event = .message_display;
    const current = self.provider.current();
    input.model = current.model;
    input.provider = if (current.name.len > 0) current.name else self.provider.name;
    input.message_id = self.display_id[0..self.display_id_len];
    input.index = self.display_index;
    input.final = final;
    input.delta = delta;
    self.display_index += 1;
    var result = runner.evaluate(self.allocator, input) catch {
        self.content.append(delta);
        return;
    };
    defer result.deinit(self.allocator);
    self.content.append(result.display_content orelse delta);
}

fn finishDisplay(self: *Request) void {
    if (!self.displaysHooks() or self.display_failed) return;
    const text = if (self.reply) |reply| reply.text else "";
    if (!self.turn.stream_display or self.display_bytes == 0) {
        if (text.len > 0) self.displayBatch(text, true);
    } else self.displayBatch(self.display_pending.items, true);
}

/// Worker thread. Says the connection is still delivering.
fn markProgress(self: *Request) void {
    self.progress_ms.store(tool.monotonicMilliseconds(self.io), .release);
}

/// Worker thread, via the provider's sink.
fn onThinkingDone(ptr: *anyopaque) void {
    const self: *Request = @ptrCast(@alignCast(ptr));
    self.thoughts.close();
}

/// Worker thread, via the provider's sink.
fn stopped(ptr: *anyopaque) bool {
    const self: *Request = @ptrCast(@alignCast(ptr));
    return self.stop.load(.acquire);
}

test "context edits preserve reference history and cannot rewrite reviewer evidence" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Hooks = @import("../core/hooks.zig");
    const runner: Hooks.Runner = .{ .io = io, .root = ".", .set = .{ .model_context = &.{.{ .command = "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"ModelContext\",\"contextEdits\":[{\"seq\":42,\"text\":\"prepared\"}]}}'" }} } };
    const Fake = struct {
        fn respond(_: *anyopaque, convo: *Conversation, _: Provider.Turn, allocator: std.mem.Allocator, _: ?Provider.Sink) !Provider.Reply {
            try std.testing.expectEqual(@as(u64, 42), convo.messages.items[0].seq);
            try std.testing.expectEqual(Conversation.Origin.hook, convo.messages.items[0].origin);
            return .{ .text = try allocator.dupe(u8, convo.messages.items[0].text) };
        }
    };
    var marker: u8 = 0;
    const provider: Provider = .{ .userdata = &marker, .name = "fake", .respond = Fake.respond };
    var convo = Conversation.init(a);
    defer convo.deinit();
    convo.next_seq = 42;
    _ = try convo.addUser("reference human request", &.{}, &.{});
    const request = try start(a, io, provider, &convo, .{ .system = "test", .hooks = &runner });
    defer request.destroy();
    request.join();
    try std.testing.expect(request.failed == null);
    try std.testing.expectEqualStrings("prepared", request.reply.?.text);
    try std.testing.expectEqualStrings("reference human request", convo.messages.items[0].text);
    try std.testing.expectEqual(Conversation.Origin.human, convo.messages.items[0].origin);
    const reviewer = try start(a, io, provider, &convo, .{ .system = "test", .hooks = &runner, .hook_input = .{ .event = .pre_model_request, .request_purpose = .approval_judge } });
    defer reviewer.destroy();
    reviewer.join();
    try std.testing.expectEqual(error.ReviewerContextImmutable, reviewer.failed.?);
}

test "request settings and retry hooks enforce bounds before transport" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const Hooks = @import("../core/hooks.zig");
    const runner: Hooks.Runner = .{ .io = io, .root = ".", .set = .{
        .model_settings = &.{.{ .command = "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"ModelSettings\",\"settings\":{\"temperature\":0.25,\"max_output_tokens\":128,\"attempts\":2}}}'" }},
        .model_retry = &.{.{ .command = "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"ModelRetry\",\"retryDelayMs\":7}}'" }},
    } };
    const Fake = struct {
        fn respond(_: *anyopaque, _: *Conversation, turn: Provider.Turn, _: std.mem.Allocator, sink: ?Provider.Sink) !Provider.Reply {
            try std.testing.expectEqual(@as(?f32, 0.25), turn.settings.temperature);
            try std.testing.expectEqual(@as(?u32, 128), turn.settings.max_output_tokens);
            try std.testing.expectEqual(@as(?u8, 2), turn.settings.attempts);
            try std.testing.expectEqual(@as(?u64, 7), sink.?.retryDecision(.{ .attempt = 1, .allowed = true, .delay_ms = 500 }));
            return .{};
        }
    };
    var marker: u8 = 0;
    var convo = Conversation.init(a);
    defer convo.deinit();
    const provider: Provider = .{ .userdata = &marker, .name = "fake", .respond = Fake.respond };
    const request = try start(a, io, provider, &convo, .{ .system = "test", .hooks = &runner });
    defer request.destroy();
    request.join();
    try std.testing.expect(request.failed == null);
    const denied = try start(a, io, provider, &convo, .{ .system = "test", .model_policy = .{ .restrict_routes = true } });
    defer denied.destroy();
    denied.join();
    try std.testing.expectEqual(error.ModelRouteDenied, denied.failed.?);
}

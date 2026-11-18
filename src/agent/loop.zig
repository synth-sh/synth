//! The agent loop: ask the model, run the tools it asks for, feed the results
//! back, repeat until it answers in prose.

const std = @import("std");
const HumanIntent = @import("../core/human_intent.zig");
const paths = @import("../core/paths.zig");
const testing = std.testing;

const Config = @import("../core/config.zig");
const Database = @import("../core/database.zig");
const Hooks = @import("../core/hooks.zig");
const HookFlow = @import("hook_flow.zig");
const Provider = @import("../provider/provider.zig");
const recap = @import("recap.zig");
const redact = @import("../core/redact.zig");
const ask_user = @import("../tools/ask.zig");
const todo_tool = @import("../tools/todo.zig");
const Registry = @import("../tools/registry.zig");
const agents = @import("agent.zig");
const Context = @import("context.zig");
const base_prompt = @import("prompt.zig");
const Project = @import("../core/project.zig");
const skill = @import("../core/skill.zig");
const todo = @import("../core/todo.zig");
const tool = @import("../tools/tool.zig");
const Conversation = @import("../core/conversation.zig");
const mention = @import("../core/mention.zig");
const Request = @import("request.zig");
const classifier = @import("classifier.zig");
const window = @import("../provider/window.zig");
const permission = @import("permission.zig");
const safety = @import("safety.zig");
const Thought = @import("thought.zig");
const ToolRun = @import("tool_run.zig");

const Loop = @This();

/// How many times the same tool call may repeat before the turn is stopped.
/// Two is a model correcting itself; three is a model stuck.
pub const max_repeats: usize = 3;

/// How long one turn may run before the loop gives up on it. A backstop for a
/// turn that is merely expensive: the step ceiling counts calls and the repeat
/// check catches a model going in circles, and neither notices a turn that is
/// simply grinding. Generous, because a real refactor against a local model
/// legitimately takes a while. Zero turns it off.
pub const default_turn_ms: i64 = 30 * std.time.ms_per_min;

/// How long the provider may deliver nothing before the turn is given up on.
/// Generous, because the gap before the first token is real work.
pub const default_stall_ms: i64 = 2 * std.time.ms_per_min;

/// Tokens one turn may spend, prompt and completion together. The whole
/// transcript is resent every step, so a long turn's cost grows with the square
/// of its length; this is what notices. Zero turns it off.
pub const default_turn_tokens: u64 = 2_000_000;

/// Stands in for an assistant turn that said nothing at all, so the transcript
/// shows a turn happened. Named because a caller reading the transcript back -
/// a subagent handing up its answer - has to tell it from something the model
/// meant to say.
pub const no_reply = "(no reply)";

/// How every reason the loop halts on opens. A subagent's caller strips it.
pub const halt_prefix = "Stopped: ";

/// Messages whose pasted images stay in memory. Older ones keep their token in
/// the text but stop being resent; the bodies remain in the blob table.
const max_resident_images: usize = 2;
/// How much attachment text is held in full across the whole transcript. Past
/// this the oldest are cut back to a preview, which is recoverable from the
/// `attachment` table. Generous enough for a handful of skills and mentioned
/// files, small enough that a session full of them cannot grow without bound.
const max_resident_attachment_bytes: usize = 256 * 1024;

/// Cap on tool output fed back to the model. The whole conversation is resent
/// every turn, so an unbounded `read` of a large file does not just cost once -
/// it inflates every request that follows, until the context fills and the
/// model slows to a crawl. The full output is still shown in the transcript.
pub const max_tool_result_bytes: usize = 8 * 1024;

pub const Outcome = recap.Outcome;

pub const State = enum {
    idle,
    running_hooks,
    /// Waiting on the model.
    thinking,
    /// Waiting on the user to approve tool calls.
    awaiting_approval,
    /// Waiting on the user to answer a question the model asked.
    awaiting_answer,
    /// Running approved tools.
    running_tools,
    /// Auto mode is having a call judged.
    classifying,
    /// Asking the model to summarise the transcript so far.
    compacting,
    /// The user gave up, and the worker has been asked to stop but has not
    /// unwound yet. Still busy: the worker holds the conversation, so nothing
    /// may be submitted or edited until it lets go.
    cancelling,

    /// A human-readable label for the state, for the UI to render.
    pub fn label(self: State) []const u8 {
        return switch (self) {
            .idle => "",
            .running_hooks => "Running hooks",
            .thinking => "Thinking",
            .awaiting_approval => "Awaiting approval",
            .awaiting_answer => "Waiting for your answer",
            .running_tools => "Running tools",
            .classifying => "Checking a call",
            .compacting => "Compacting",
            .cancelling => "Cancelling",
        };
    }
};

/// A remembered "allow always", scoped to the project and to what the call was
/// doing: `bash` approved for `git commit *` does not approve `git push`
/// (`permission.zig` has the patterns). Every other tool stores `*`, or the
/// path of a call that reached outside the project.
const Allowance = struct {
    tool: []const u8,
    pattern: []const u8,
};

allocator: std.mem.Allocator,
io: std.Io,
provider: Provider,
backend: ?*@import("../provider/backend.zig") = null,
model_policy: Config.ModelPolicy.Policy = .{},
human_intent: @import("../core/human_intent.zig") = .{},
review_started_ms: i64 = 0,
effective_model: ?[]const u8 = null,
effective_provider: ?[]const u8 = null,
registry: *const Registry,
conversation: *Conversation,
reads: *tool.ReadLog,
hooks: ?*const Hooks.Runner = null,
hook_flow: HookFlow = .{},
control_files: []const []const u8 = &.{},
stream_display: bool = true,
interrupted: bool = false,
stop_hook_active: bool = false,
approved_ask_index: ?usize = null,
pending_submit: ?Submission = null,
/// Root every tool resolves against. Borrowed.
project_root: []const u8,
working_directory: ?[]const u8 = null,
additional_roots: std.ArrayList([]const u8) = .empty,
workspace_prompt: ?[]const u8 = null,

/// Persistence, when attached. Null in tests and in `synth run`, which are
/// deliberately stateless. All database calls stay on this (the UI) thread.
db: ?*Database = null,
project_id: ?i64 = null,
/// The session's name, owned. Null until one is given.
session_title: ?[]const u8 = null,
session_id: ?i64 = null,
/// The loop that started this one, for a subagent. Its file changes are
/// undone with the parent's turns, and auto mode judges its calls by what the
/// parent's person asked for.
parent: ?*Loop = null,
/// Files the running batch checkpointed, to record what it left in them once
/// it settles. Owned.
checkpointed: std.ArrayList([]u8) = .empty,
/// The cwd and model for the session row, held until the session is actually
/// created on the first message. A session is not created just for opening the
/// app.
session_cwd: []const u8 = "",
/// Model the session runs under, recorded on its row. Borrowed from the config
/// until a switch, which is when `session_model_owned` takes over: the
/// provider frees its own copy on the *next* switch, so keeping that slice
/// would leave this dangling.
session_model: []const u8 = "",
/// The handle the session row is created under, when one was given out before
/// the row existed. Borrowed.
session_public_id: ?[]const u8 = null,
session_model_owned: ?[]u8 = null,
/// Database message id for each conversation message, keyed by the message's
/// stable `seq`. Keyed by seq rather than index so trimming older messages from
/// memory does not shift the mapping.
message_ids: std.AutoHashMapUnmanaged(u64, i64) = .empty,

state: State = .idle,
request: ?*Request = null,
/// Requests started so far, so a watcher can tell one stream from the next
/// even when a request ends and another begins inside the same poll.
requests_started: u64 = 0,
tools: ?*ToolRun = null,
/// How many of the running batch's results have been copied into the
/// conversation. Advances while the batch runs, so cards settle one at a time.
tools_adopted: usize = 0,
/// What each running call last said it was doing, refreshed once a poll so a
/// frame draws a stable set of lines rather than racing the workers.
notes: []ToolRun.Note = &.{},
/// Whether the workers have been told to stop and handed to `canceller`.
signalled: bool = false,
/// The off-thread wait for the signalled workers, and whether it has finished.
///
/// `Io.Future.cancel` blocks until the worker unwinds, re-signalling on a
/// doubling backoff. On the UI's thread that is the terminal locked up for as
/// long as a blocked socket read takes to give up, so the wait happens here and
/// the UI keeps polling `reaped` instead.
canceller: ?std.Io.Future(void) = null,
reaped: std.atomic.Value(bool) = .init(false),
steps: usize = 0,
/// When this turn started, on the monotonic clock, and what it has spent since.
/// Both reset by `submit`.
turn_started_ms: ?i64 = null,
turn_tokens: u64 = 0,
/// What the user typed while the turn was running, waiting to be handed to the
/// model at its next step.
steering: std.ArrayList(Submission) = .empty,
/// The turn's limits. Zero disables either one.
max_turn_ms: i64 = default_turn_ms,
max_turn_tokens: u64 = default_turn_tokens,
/// How long the provider may go silent before the turn is abandoned. Zero
/// disables it.
max_stall_ms: i64 = default_stall_ms,
/// Whether the turn now unwinding is one the stall check gave up on.
timed_out: bool = false,
/// `seq` of the assistant message whose tool calls are being decided. A seq
/// rather than an index: trimming the transcript shifts indices down and paging
/// history back in shifts them up, either of which would leave a decision
/// pointing at the wrong message.
pending_seq: ?u64 = null,
/// Which pending call the approval prompt is on.
pending_index: usize = 0,
/// Tools the user chose to always allow.
allowed: std.ArrayList(Allowance) = .empty,
/// Whether the preset list of read-only shell commands runs without asking.
/// Off makes every `bash` call a question, however harmless.
auto_approve_safe: bool = true,
/// Who decides a call that would otherwise stop for the person.
approvals: Config.Approvals = .ask,
/// The call auto mode is having judged, while it is.
judging: ?Judging = null,
/// Calls auto mode blocked in a row, and in all, toward handing decisions back.
blocks_in_row: u32 = 0,
blocks_total: u32 = 0,

/// How a tool call starts a subagent. Installed by whoever assembled the loop,
/// because the implementation needs a loop and the loop must not need it.
delegate: ?tool.Delegate = null,
/// What the session's client does in place of the disk and a shell.
handoff: tool.Handoff = .{},
/// What the model may do this turn. The tool schema sent with every request is
/// this agent's list, and the guard refuses anything outside it.
agent: agents.Agent = agents.all[0],
/// The last batch of tool calls, as tool name and arguments run together, and
/// how many times running it has come back identical. A step ceiling catches a
/// model looping at step two hundred; this catches it at step three.
last_calls: ?[]u8 = null,
repeats: usize = 0,
/// How the last turn ended, and which message began it. Together these are all
/// the UI needs to recap a turn: everything else it wants is already in the
/// messages between there and the end.
///
/// A seq rather than an index, for the same reason `pending_seq` is one: paging
/// older history in and trimming it back out both move every index.
outcome: ?Outcome = null,
/// Turns that have ended. Only `finish` raises it, so a compaction settling
/// back to idle is not mistaken for a turn finishing.
finished: usize = 0,
turn_start_seq: ?u64 = null,
/// The agent's tool schema, owned and sent with every call.
tools_json: ?[]u8 = null,
/// Base instructions, before the agent's and the project's are appended.
system_prompt: []const u8 = base_prompt.default,
/// What the model is asked to end its commit messages with. Empty asks for
/// nothing.
commit_trailer: []const u8 = "",
/// Where the app is running, for the environment block. Borrowed.
project: ?*const Project = null,
/// The skills this project offers, for the `<skills>` block. Borrowed, and
/// empty where nothing discovered any.
skills: []const skill.Skill = &.{},
/// The steps the model says it is working through. Owned, and only ever
/// written on the thread that draws.
todos: todo.List = undefined,
/// The assembled system prompt, shared by the steps of one turn.
prompt_cache: Context.Cache = .{},
/// Set when a turn ends in failure, for the UI to surface.
last_error: ?anyerror = null,
/// Running totals for the session, for the sidebar.
usage: Usage = .{},
/// Fraction of the request budget that triggers compaction before the next
/// model call, including calls within a tool turn. Zero disables it.
auto_compact_at: f64 = 0.85,
/// Set while the outstanding request is a summarisation rather than a turn.
compacting: bool = false,
resume_after_compaction: bool = false,
/// Whether this turn already bought itself room by compacting. One recovery is
/// a full context; a second in the same turn means it will never fit.
recovered_from_overflow: bool = false,

pub const Usage = struct {
    /// Latest reported input plus output, including opaque reasoning tokens.
    /// A conservative size for the history replayed on the next call.
    context_tokens: u32 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    eval_duration_ns: u64 = 0,
    /// Model calls, which exceeds user turns whenever tools are involved.
    calls: u32 = 0,

    /// Generation speed across the session, or null before anything ran.
    pub fn tokensPerSecond(self: Usage) ?f64 {
        if (self.eval_duration_ns == 0 or self.output_tokens == 0) return null;
        const seconds = @as(f64, @floatFromInt(self.eval_duration_ns)) / std.time.ns_per_s;
        if (seconds <= 0) return null;
        return @as(f64, @floatFromInt(self.output_tokens)) / seconds;
    }

    /// Fraction of the context window in use, or null when the limit is
    /// unknown.
    pub fn contextFraction(self: Usage, limit: u32) ?f64 {
        if (limit == 0 or self.context_tokens == 0) return null;
        return @as(f64, @floatFromInt(self.context_tokens)) / @as(f64, @floatFromInt(limit));
    }
};

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    provider: Provider,
    registry: *const Registry,
    conversation: *Conversation,
    reads: *tool.ReadLog,
    project_root: []const u8,
) Loop {
    var identity: [16]u8 = undefined;
    io.random(&identity);
    conversation.preserve_context = true;
    return .{
        .allocator = allocator,
        .io = io,
        .provider = provider,
        .registry = registry,
        .conversation = conversation,
        .reads = reads,
        .project_root = project_root,
        .todos = .init(allocator),
        .hook_flow = .{ .identity = std.fmt.bytesToHex(identity, .lower) },
    };
}

/// Attach persistence. Resolves the project and seeds the "always allow" list
/// from remembered approvals. The session row itself is deferred until the
/// first message, so merely opening the app does not create an empty session.
/// Call once, before the first `submit`.
pub fn attachDatabase(
    self: *Loop,
    db: *Database,
    project_name: []const u8,
    cwd: []const u8,
    model: []const u8,
) !void {
    self.db = db;
    self.project_id = try db.resolveProject(self.project_root, "git", project_name);
    self.session_cwd = cwd;
    self.session_model = model;
    try self.reloadAllowances();
}

/// Replace the allowances held in memory with the ones the database holds,
/// which another session may have changed.
pub fn reloadAllowances(self: *Loop) !void {
    const db = self.db orelse return;
    const project_id = self.project_id orelse return;
    const remembered = try db.approvals(project_id, self.allocator);
    defer {
        for (remembered) |approval| approval.deinit(self.allocator);
        self.allocator.free(remembered);
    }

    for (self.allowed.items) |allowance| {
        self.allocator.free(allowance.tool);
        self.allocator.free(allowance.pattern);
    }
    self.allowed.clearRetainingCapacity();
    for (remembered) |approval| try self.remember(approval.tool, approval.pattern);
}

/// Rename the current session. The row is created first if the session has not
/// written anything yet, so a name given before the first prompt still sticks.
pub fn rename(self: *Loop, name: []const u8) !void {
    const db = self.db orelse return;
    const session_id = try self.ensureSession();
    try db.setSessionTitle(session_id, name);

    if (self.session_title) |old| self.allocator.free(old);
    self.session_title = if (name.len > 0) try self.allocator.dupe(u8, name) else null;
}

/// Record a model switch against the session.
pub fn setModel(self: *Loop, model: []const u8) !void {
    const owned = try self.allocator.dupe(u8, model);
    if (self.session_model_owned) |previous| self.allocator.free(previous);
    self.session_model_owned = owned;
    self.session_model = owned;
    // A provider/model selection invalidates the previous tokenizer's count.
    self.usage.context_tokens = 0;

    const db = self.db orelse return;
    const session_id = self.session_id orelse return;
    try db.setSessionModel(session_id, owned);
}

/// What this session is called, or "" when it is untitled.
pub fn title(self: *const Loop) []const u8 {
    return self.session_title orelse "";
}

/// Adopt an existing session: its id, its name, and the tail of its transcript.
/// Load at least `limit` messages, and always the whole unsummarised context.
/// Older, summarised history stays in the database and pages in on scroll.
pub fn resumeSession(self: *Loop, session_id: i64, limit: usize) !void {
    const db = self.db orelse return error.NoDatabase;

    const total = try db.countMessages(session_id);
    // Seqs restart per session, so old entries point at another session's rows.
    self.message_ids.clearRetainingCapacity();

    const context_count = try db.contextMessageCount(session_id);
    const loaded = try db.loadMessages(self.allocator, session_id, std.math.maxInt(i64), @max(limit, context_count));
    defer self.allocator.free(loaded);

    std.mem.reverse(Conversation.Message, loaded);
    if (self.pending_submit) |*pending| pending.deinit(self.allocator);
    self.pending_submit = null;
    self.endHookSession("resume");
    if (self.hook_flow.context) |context| self.allocator.free(context);
    self.hook_flow.context = null;
    self.hook_flow.reset();
    self.prompt_cache.invalidate(self.allocator);
    try self.conversation.adopt(loaded, total - @min(total, loaded.len));

    const hook_handle = try db.sessionPublicId(session_id, self.allocator);
    if (self.hook_flow.session_handle) |old| self.allocator.free(old);
    self.hook_flow.session_handle = hook_handle;
    self.session_id = session_id;
    self.hook_flow.session_started = false;
    self.hook_flow.session_source = .@"resume";
    self.stop_hook_active = false;
    if (self.session_title) |old| self.allocator.free(old);
    self.session_title = null;
    const name = try db.sessionTitle(session_id, self.allocator);
    if (name.len > 0) self.session_title = name else self.allocator.free(name);

    try self.restoreModel(session_id);
    try self.restoreAgent(session_id);
    try self.restoreTodos(session_id);
}

/// Leave the saved session intact and make the next prompt start a new one.
/// The provider, model, agent and project-scoped approvals stay in use.
pub fn resetForNewSession(self: *Loop) bool {
    if (self.isBusy()) return false;

    if (self.pending_submit) |*pending| pending.deinit(self.allocator);
    self.pending_submit = null;
    self.endHookSession("clear");
    self.hook_flow.reset();
    self.prompt_cache.invalidate(self.allocator);
    self.clearHumanIntent();
    self.conversation.clear();
    if (self.hook_flow.session_handle) |old| self.allocator.free(old);
    self.hook_flow.session_handle = null;
    self.hook_flow.session_started = false;
    self.hook_flow.session_source = .clear;
    self.stop_hook_active = false;
    self.hook_flow.pre_seq = null;
    if (self.hook_flow.context) |context| self.allocator.free(context);
    self.hook_flow.context = null;
    self.session_id = null;
    if (self.session_title) |old| self.allocator.free(old);
    self.session_title = null;
    self.message_ids.clearRetainingCapacity();
    self.pending_seq = null;
    self.pending_index = 0;
    self.todos.clear();
    self.dropSteering();
    self.usage = .{};
    self.outcome = null;
    self.turn_start_seq = null;
    self.last_error = null;
    return true;
}

/// Bring back the steps the session was working through.
fn restoreTodos(self: *Loop, session_id: i64) !void {
    const db = self.db orelse return;

    const items = try db.loadTodos(self.allocator, session_id);
    defer {
        for (items) |item| self.allocator.free(item.text);
        self.allocator.free(items);
    }

    try self.todos.replace(items);
}

/// Point the provider back at the model the session was last run under.
fn restoreModel(self: *Loop, session_id: i64) !void {
    if (self.model_policy.restrict_routes) return;
    const db = self.db orelse return;
    const set = self.provider.set_model orelse return;

    const stored = try db.sessionModel(session_id, self.allocator);
    defer self.allocator.free(stored);
    if (stored.len == 0) return;
    if (std.mem.eql(u8, stored, self.provider.model)) return;

    const now = set(self.provider.userdata, stored) catch return;
    try self.adoptModel(now);
}

pub const ModelSwitch = struct {
    requested_model: []const u8,
    source: []const u8,
};

pub fn beginModelSwitch(self: *Loop, model: []const u8, source: []const u8) !ModelSwitch {
    if (self.model_policy.restrict_routes) return error.ModelRouteDenied;
    if (self.isBusy()) return error.Busy;
    try self.trackModel("initial");
    if (self.hooks) |runner| {
        var result = try runner.evaluate(self.allocator, try self.exportHookInput(.{ .event = .pre_model_switch, .from_model = self.provider.model, .to_model = model, .requested_model = model, .source = source }));
        defer result.deinit(self.allocator);
        if (result.blocked != null or result.stop) {
            self.say("Model switch blocked: {s}", .{result.blocked orelse "stopped by hook"});
            return error.HookBlocked;
        }
        try self.acceptHookResult(&result);
    }
    return .{ .requested_model = model, .source = source };
}

pub fn commitModelSwitch(self: *Loop, change: ModelSwitch) !void {
    const set = self.provider.set_model orelse return error.ModelFixed;
    const now = try set(self.provider.userdata, change.requested_model);
    self.provider.model = now.model;
    if (now.name.len > 0) self.provider.name = now.name;
    self.provider.context_limit = now.context_limit;
    self.provider.vision = now.vision;
    try self.setModel(now.model);
    try self.trackModel(change.source);
}

pub fn switchModel(self: *Loop, model: []const u8) !void {
    const change = try self.beginModelSwitch(model, "command");
    try self.commitModelSwitch(change);
}

pub fn workingDirectory(self: *const Loop) []const u8 {
    return self.working_directory orelse self.project_root;
}

fn directoryPath(self: *Loop, path: []const u8) ![]u8 {
    if (path.len == 0) return error.InvalidParams;
    const lexical = try std.fs.path.resolve(self.allocator, &.{ self.workingDirectory(), path });
    defer self.allocator.free(lexical);
    const reference = try std.Io.Dir.cwd().realPathFileAlloc(self.io, lexical, self.allocator);
    defer self.allocator.free(reference);
    var dir = try std.Io.Dir.cwd().openDir(self.io, reference, .{});
    dir.close(self.io);
    return self.allocator.dupe(u8, reference);
}

pub fn changeDirectory(self: *Loop, path: []const u8) !void {
    if (self.isBusy()) return error.Busy;
    try self.adoptDirectory(path);
}

fn adoptDirectory(self: *Loop, path: []const u8) !void {
    const next = try self.directoryPath(path);
    if (std.mem.eql(u8, next, self.workingDirectory())) {
        self.allocator.free(next);
        return;
    }
    const old = self.working_directory;
    const previous = self.workingDirectory();
    self.working_directory = next;
    self.prompt_cache.invalidate(self.allocator);
    self.observeHook(.{ .event = .cwd_changed, .old_cwd = previous, .new_cwd = next });
    if (old) |owned| self.allocator.free(owned);
}

pub fn addDirectory(self: *Loop, path: []const u8, source: []const u8) !void {
    if (self.isBusy()) return error.Busy;
    const reference = try self.directoryPath(path);
    errdefer self.allocator.free(reference);
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const primary = self.followLinks(arena.allocator(), self.project_root) orelse self.project_root;
    const covered = pathInside(primary, reference) or for (self.additional_roots.items) |root| {
        if (pathInside(root, reference)) break true;
    } else false;
    if (covered) {
        self.allocator.free(reference);
        return;
    }
    try self.additional_roots.append(self.allocator, reference);
    self.prompt_cache.invalidate(self.allocator);
    self.observeHook(.{ .event = .directory_added, .directory = reference, .source = source });
}

pub const trackModel = HookFlow.trackModel;

fn adoptModel(self: *Loop, now: Provider.Current) !void {
    self.provider.model = now.model;
    if (now.name.len > 0) self.provider.name = now.name;
    self.provider.context_limit = now.context_limit;
    self.provider.vision = now.vision;
    try self.setModel(now.model);
    try self.trackModel("resume");
}

/// Switch agents: rebuild the tool schema, hand it to the provider with the
/// agent's instructions, and remember it on the session.
pub fn useAgent(self: *Loop, id: []const u8) !void {
    const chosen = agents.findOrDefault(id);
    const json = try self.registry.schemaJson(self.allocator, chosen.tools);
    errdefer self.allocator.free(json);

    if (self.tools_json) |old| self.allocator.free(old);
    self.tools_json = json;
    self.agent = chosen;

    self.prompt_cache.invalidate(self.allocator);

    if (self.db) |db| {
        if (self.session_id) |session_id| try db.setSessionAgent(session_id, chosen.id);
    }
}

/// Everything one call needs besides the transcript. Assembling it here rather
/// than in the backend is what keeps a provider from having to know what an
/// agent is.
fn turn(self: *Loop, instruction: []const u8) Provider.Turn {
    const last = self.conversation.last();
    const continuing_summary = instruction.len == 0 and last != null and last.?.role == .system;
    return .{
        .backend = self.backend,
        .model_policy = self.model_policy,
        .system = self.systemPrompt(),
        .display_messages = true,
        .stream_display = self.stream_display,
        .tools_json = self.tools_json orelse "",
        .hooks = self.hooks,
        .hook_input = self.hookInput(.{ .event = .pre_model_request }),
        .instruction = if (continuing_summary) "Continue the user's task from the conversation summary." else instruction,
    };
}

/// The base instructions, the agent's, and the project's, assembled once per
/// turn and reused across its tool steps.
fn systemPrompt(self: *Loop) []const u8 {
    const project = self.project orelse return self.system_prompt;
    const text = self.prompt_cache.get(
        self.allocator,
        self.io,
        self.system_prompt,
        self.agent.prompt,
        project,
        self.skills,
        self.commit_trailer,
    ) catch return self.system_prompt;
    if (self.prompt_cache.generation != self.hook_flow.instruction_generation) {
        self.hook_flow.instruction_generation = self.prompt_cache.generation;
        if (self.prompt_cache.instruction_path) |path| {
            const load_reason = if (self.hook_flow.session_source == .compact) "compact" else "session_start";
            self.observeHook(.{
                .event = .instructions_loaded,
                .file_path = path,
                .memory_type = "Project",
                .load_reason = load_reason,
            });
        }
    }
    if (self.working_directory == null and self.additional_roots.items.len == 0) return text;
    var writer: std.Io.Writer.Allocating = .init(self.allocator);
    defer writer.deinit();
    writer.writer.print("{s}\n<workspace>\nCurrent working directory: {s}\nAdditional permitted roots: ", .{ text, self.workingDirectory() }) catch return text;
    std.json.Stringify.value(self.additional_roots.items, .{}, &writer.writer) catch return text;
    writer.writer.writeAll("\nRelative tool paths resolve from the current working directory.\n</workspace>\n") catch return text;
    const owned = writer.toOwnedSlice() catch return text;
    if (self.workspace_prompt) |old| self.allocator.free(old);
    self.workspace_prompt = owned;
    return owned;
}

/// The agent after the current one, applied. What one key cycles through.
pub fn cycleAgent(self: *Loop) !void {
    try self.useAgent(agents.next(self.agent.id).id);
}

/// Point the loop back at the agent the session was last run under.
fn restoreAgent(self: *Loop, session_id: i64) !void {
    const db = self.db orelse return;
    const stored = try db.sessionAgent(session_id, self.allocator);
    defer self.allocator.free(stored);
    if (stored.len == 0) return;
    try self.useAgent(stored);
}

/// The database this loop persists to, for the UI's session picker.
pub fn database(self: *Loop) ?*Database {
    return self.db;
}

/// The handle this session is resumed by, or "" when there is no database.
/// Caller owns the result.
pub fn sessionHandle(self: *Loop, allocator: std.mem.Allocator) ![]const u8 {
    const db = self.db orelse return allocator.dupe(u8, "");
    const session_id = self.session_id orelse return allocator.dupe(u8, "");
    return db.sessionPublicId(session_id, allocator);
}

/// Create the session row if it does not exist yet. Called lazily on the first
/// message so an empty launch leaves no session behind.
fn ensureSession(self: *Loop) !i64 {
    if (self.session_id) |id| return id;
    const db = self.db orelse return error.NoDatabase;
    const project_id = self.project_id orelse return error.NoProject;
    const public_id = self.session_public_id orelse self.hook_flow.session_handle;
    const id = if (public_id) |handle|
        try db.createSessionAs(project_id, self.session_cwd, self.session_model, handle)
    else
        try db.createSession(project_id, self.session_cwd, self.session_model);
    self.session_id = id;
    try db.setSessionAgent(id, self.agent.id);
    return id;
}

/// Ask every live worker to give up. Non-blocking: the joins still happen in
/// `deinit`, but a provider that checks the flag cuts that wait from "however
/// long the model takes" to a chunk or two.
pub fn requestStop(self: *Loop) void {
    if (self.request) |request| request.requestStop();
    if (self.judging) |judging| judging.request.requestStop();
    if (self.tools) |tools| tools.requestStop();
    if (self.hook_flow.dispatch) |dispatch| dispatch.requestStop();
}

pub fn deinit(self: *Loop) void {
    if (self.effective_model) |value| self.allocator.free(value);
    if (self.effective_provider) |value| self.allocator.free(value);
    self.clearHumanIntent();
    self.human_intent.deinit(self.allocator);
    self.hook_flow.watch.deinit(self.allocator);
    if (self.hook_flow.model) |model| self.allocator.free(model);
    if (self.session_title) |t| self.allocator.free(t);
    if (self.hook_flow.context) |context| self.allocator.free(context);
    if (self.hook_flow.failure) |failure| self.allocator.free(failure);
    self.session_title = null;
    if (self.session_model_owned) |m| self.allocator.free(m);
    self.session_model_owned = null;
    if (self.canceller) |*canceller| {
        canceller.await(self.io);
        self.canceller = null;
    }
    if (self.request) |request| {
        request.cancel();
        request.destroy();
        self.request = null;
    }
    if (self.judging) |judging| {
        judging.request.cancel();
        judging.destroy(self.allocator);
        self.judging = null;
    }
    if (self.tools) |tools| {
        tools.cancel();
        tools.destroy();
        self.tools = null;
    }
    if (self.hook_flow.dispatch) |dispatch| {
        dispatch.cancel();
        dispatch.destroy();
        self.hook_flow.dispatch = null;
    }
    if (self.hooks) |runner| if (runner.runtime) |runtime| runtime.discardAgent(&self.hook_flow.identity);
    if (self.pending_submit) |*pending| pending.deinit(self.allocator);
    self.pending_submit = null;

    self.clearNotes();
    self.todos.deinit();
    if (self.hook_flow.notice) |notice| self.allocator.free(notice);
    for (self.steering.items) |*pending| pending.deinit(self.allocator);
    self.steering.deinit(self.allocator);
    self.prompt_cache.deinit(self.allocator);
    if (self.last_calls) |calls| self.allocator.free(calls);
    if (self.tools_json) |json| self.allocator.free(json);
    for (self.allowed.items) |allowance| {
        self.allocator.free(allowance.tool);
        self.allocator.free(allowance.pattern);
    }
    self.allowed.deinit(self.allocator);
    for (self.checkpointed.items) |path| self.allocator.free(path);
    self.checkpointed.deinit(self.allocator);
    if (self.hook_flow.export_path) |path| {
        if (self.hooks) |runner| if (runner.runtime) |runtime| runtime.releaseSnapshot(path);
        self.allocator.free(path);
    }
    self.hook_flow.export_path = null;
    if (self.hook_flow.session_handle) |handle| self.allocator.free(handle);
    self.hook_flow.asks.deinit(self.allocator);
    self.message_ids.deinit(self.allocator);
    if (self.workspace_prompt) |text| self.allocator.free(text);
    if (self.working_directory) |path| self.allocator.free(path);
    for (self.additional_roots.items) |path| self.allocator.free(path);
    self.additional_roots.deinit(self.allocator);
}

pub fn isBusy(self: *const Loop) bool {
    return self.state != .idle;
}

/// Re-read the backend's current state into the copy of `Provider` held here.
/// Safe only between turns: the backend writes some of this from the worker
/// thread.
pub fn syncProvider(self: *Loop) void {
    const now = self.provider.current();
    self.provider.model = now.model;
    if (now.name.len > 0) self.provider.name = now.name;
    self.provider.context_limit = now.context_limit;
    self.provider.vision = now.vision;
    self.provider.effort = now.effort;
    self.trackModel("automatic") catch {};
}

/// Run the current model at `level` from the next turn on. Between turns
/// only: the request in flight reads the level as it is built.
pub fn setEffort(self: *Loop, level: []const u8) void {
    const set = self.provider.set_effort orelse return;
    set(self.provider.userdata, level);
    self.syncProvider();
}

/// What the loop is doing, for the UI's status row.
pub fn label(self: *Loop) []const u8 {
    if (self.state == .thinking) {
        if (self.request) |request| {
            if (request.thoughts.isClosed()) return "Responding";
        }
    }
    return self.state.label();
}

/// The thinking stream of the in-flight request, for the UI to render.
pub fn thoughts(self: *Loop) ?*Thought.Stream {
    const request = self.request orelse return null;
    return &request.thoughts;
}

/// The answer as it streams in, for the UI to render before the turn lands.
pub fn streamingText(self: *Loop) ?*Thought.Stream {
    const request = self.request orelse return null;
    return &request.content;
}

/// What the composer held back from the draft: pasted blocks and images, each
/// standing in the prompt as a token. Borrowed for the length of the call.
pub const Extras = struct {
    command_name: []const u8 = "",
    command_args: []const u8 = "",
    expanded_prompt: []const u8 = "",
    attachments: []const mention.Attachment = &.{},
    /// Base64-encoded image data.
    images: []const []const u8 = &.{},
};

/// A prompt and what came with it, owned.
pub const Submission = struct {
    command_name: []const u8 = "",
    command_args: []const u8 = "",
    expanded_prompt: []const u8 = "",
    prompt: []u8,
    attachments: []mention.Attachment,
    images: [][]u8,

    fn init(allocator: std.mem.Allocator, prompt: []const u8, extras: Extras) !Submission {
        const owned_prompt = try allocator.dupe(u8, prompt);
        errdefer allocator.free(owned_prompt);

        const attachments = try allocator.alloc(mention.Attachment, extras.attachments.len);
        var attachments_built: usize = 0;
        errdefer {
            for (attachments[0..attachments_built]) |*attachment| attachment.deinit(allocator);
            allocator.free(attachments);
        }
        for (extras.attachments, attachments) |source, *dest| {
            const path = try allocator.dupe(u8, source.path);
            errdefer allocator.free(path);
            dest.* = .{
                .path = path,
                .content = try allocator.dupe(u8, source.content),
                .content_bytes = source.content_bytes,
            };
            attachments_built += 1;
        }

        const images = try allocator.alloc([]u8, extras.images.len);
        var images_built: usize = 0;
        errdefer {
            for (images[0..images_built]) |image| allocator.free(image);
            allocator.free(images);
        }
        for (extras.images, images) |source, *dest| {
            dest.* = try allocator.dupe(u8, source);
            images_built += 1;
        }

        const command_name = try allocator.dupe(u8, extras.command_name);
        errdefer allocator.free(command_name);
        const command_args = try allocator.dupe(u8, extras.command_args);
        errdefer allocator.free(command_args);
        return .{ .prompt = owned_prompt, .attachments = attachments, .images = images, .command_name = command_name, .command_args = command_args, .expanded_prompt = try allocator.dupe(u8, extras.expanded_prompt) };
    }

    pub fn asExtras(self: *const Submission) Extras {
        return .{ .attachments = self.attachments, .images = self.images, .command_name = self.command_name, .command_args = self.command_args, .expanded_prompt = self.expanded_prompt };
    }

    pub fn deinit(self: *Submission, allocator: std.mem.Allocator) void {
        allocator.free(self.command_name);
        allocator.free(self.command_args);
        allocator.free(self.expanded_prompt);
        allocator.free(self.prompt);
        for (self.attachments) |*attachment| attachment.deinit(allocator);
        allocator.free(self.attachments);
        for (self.images) |image| allocator.free(image);
        allocator.free(self.images);
    }
};

/// What the model is asked for when compacting. The summary is fed back as the
/// only history, so it has to carry the parts a later turn would need.
const compaction_prompt =
    \\Summarise this conversation so far, for your own use as the only record of
    \\it. Keep: what the user is trying to do, decisions made and why, files and
    \\symbols touched, what worked, what failed, and anything still outstanding.
    \\Drop pleasantries and repeated tool output. Write it as notes, not prose,
    \\and do not address the user.
;

/// Ask the model to summarise the transcript. The summary lands as a system
/// message, which is where `buildMessages` starts from - everything before it
/// stays in the transcript and in the database, but stops being sent.
pub fn compact(self: *Loop) !void {
    if (self.isBusy()) return;
    if (self.conversation.messages.items.len == 0) return;

    try self.startCompaction(false);
}

fn startCompaction(self: *Loop, resume_turn: bool) !void {
    self.hook_flow.resume_turn = resume_turn;
    if (try self.lifecycle(.pre_compact, .compact)) return;
    try self.startCompactionRequest(resume_turn);
}

fn startCompactionRequest(self: *Loop, resume_turn: bool) !void {
    const request_turn: Provider.Turn = .{
        .backend = self.backend,
        .model_policy = self.model_policy,
        .system = self.systemPrompt(),
        .instruction = compaction_prompt,
        .compacting = true,
        .hooks = self.hooks,
        .hook_input = try self.exportHookInput(.{ .event = .pre_model_request, .request_purpose = .compaction }),
    };
    if (!try self.contextFits(request_turn)) return self.stop("Stopped: history is too large to compact safely with this model. Nothing was discarded. Switch to a model with a larger context window, or use /clear to start a new session.");
    self.request = try Request.start(
        self.allocator,
        self.io,
        self.provider,
        self.conversation,
        request_turn,
    );
    self.requests_started += 1;
    self.compacting = true;
    self.resume_after_compaction = resume_turn;
    self.state = .compacting;
}

/// Check the same budget the serializers enforce, even for an unknown model.
pub fn shouldCompact(self: *Loop) bool {
    if (self.auto_compact_at <= 0) return false;
    const request_turn = self.turn("");
    const budget = window.requestBudget(self.provider.context_limit, request_turn);
    const estimated = window.contextTokens(self.conversation, self.provider.vision);
    const prompt_overhead = (request_turn.system.len + request_turn.tools_json.len) / 4;
    const reported = self.usage.context_tokens -| prompt_overhead;
    const used = @max(estimated, reported);
    const token_threshold = @as(f64, @floatFromInt(budget)) * self.auto_compact_at;
    return used > 0 and @as(f64, @floatFromInt(used)) >= token_threshold;
}

const context_full_notice = "Stopped: context is full. History was preserved. Use /compact or switch to a model with a larger context window before continuing.";

fn contextFits(self: *Loop, request_turn: Provider.Turn) !bool {
    if (self.model_policy.selected(request_turn.hook_input.request_purpose) != null) return true;
    if (self.hooks) |runner| if (runner.set.model_resolve.len > 0) return true;
    const budget = window.requestBudget(self.provider.context_limit, request_turn);
    const kept = window.completeMessages(self.conversation, self.allocator, budget, self.provider.vision) catch |err| switch (err) {
        error.ContextTooLarge => return false,
        else => return err,
    };
    self.allocator.free(kept);
    return true;
}

/// Turn a finished summarisation into the system message that replaces the
/// history it summarises.
fn finishCompaction(self: *Loop, summary: []const u8) !void {
    const resume_turn = self.resume_after_compaction;
    self.compacting = false;
    self.resume_after_compaction = false;
    self.state = .idle;
    if (summary.len == 0) return self.stop("Stopped: compaction returned no summary. History was preserved; try /compact again.");
    _ = try self.conversation.append(.{ .role = .system, .text = summary });
    try self.persistMessage(self.conversation.messages.items.len - 1);

    self.usage.context_tokens = 0;
    self.prompt_cache.invalidate(self.allocator);
    self.hook_flow.resume_turn = resume_turn;
    if (try self.lifecycle(.post_compact, .compact_session)) return;
    self.hook_flow.session_source = .compact;
    if (try self.lifecycle(.session_start, .after_compact)) return;
    if (resume_turn) return self.ask();
    self.outcome = .done;
}

/// Start a turn. Attachments come from `@path` mentions in the prompt, plus
/// whatever the composer held back.
pub fn submit(self: *Loop, prompt: []const u8, extras: Extras) !void {
    if (self.isBusy()) return;
    self.hook_flow.idle_since = null;
    self.hook_flow.idle_notified = false;
    self.hook_flow.permission_notice = null;
    try self.prepareHookIdentity();

    if (self.hook_flow.notice) |notice| self.allocator.free(notice);
    self.hook_flow.notice = null;

    if (self.hooks) |runner| {
        if (runner.set.hasUntrusted()) {
            if (self.pending_submit) |*old| old.deinit(self.allocator);
            self.pending_submit = try Submission.init(self.allocator, prompt, extras);
            self.say("{s}", .{Hooks.review_notice});
            const queued = try std.fmt.allocPrint(self.allocator, "{s}\n\nQueued prompt: {s}", .{ Hooks.review_notice, prompt });
            defer self.allocator.free(queued);
            _ = try self.conversation.append(.{ .role = .assistant, .origin = .harness, .text = queued });
            try self.persistMessage(self.conversation.messages.items.len - 1);
            return;
        }
    }
    if (!self.hook_flow.session_started) {
        self.hook_flow.session_started = true;
        if (try self.lifecycle(if (self.parent == null) .session_start else .subagent_start, .begin_prompt)) {
            self.pending_submit = try Submission.init(self.allocator, prompt, extras);
            return;
        }
    }
    try self.submitPrompt(prompt, extras);
}

fn submitPrompt(self: *Loop, prompt: []const u8, extras: Extras) !void {
    if (self.hooks) |runner| {
        if (runner.set.forEvent(.user_prompt_submit).len == 0) return self.expandPrompt(prompt, extras);

        self.pending_submit = try Submission.init(self.allocator, prompt, extras);
        errdefer {
            self.pending_submit.?.deinit(self.allocator);
            self.pending_submit = null;
        }
        self.hook_flow.dispatch = try self.dispatchHook(.{
            .event = .user_prompt_submit,
            .prompt = self.pending_submit.?.prompt,
        });
        self.hook_flow.pending = .prompt;
        self.state = .running_hooks;
        return;
    }

    try self.expandPrompt(prompt, extras);
}

pub fn resumePendingPrompt(self: *Loop) !void {
    if (self.isBusy()) return;
    if (self.hooks) |runner| if (runner.set.hasUntrusted()) return;
    var pending = self.pending_submit orelse return;
    self.pending_submit = null;
    defer pending.deinit(self.allocator);
    try self.submit(pending.prompt, pending.asExtras());
}

fn expandPrompt(self: *Loop, prompt: []const u8, extras: Extras) !void {
    if (extras.command_name.len > 0) {
        if (self.hooks) |runner| {
            if (runner.set.user_prompt_expansion.len > 0) {
                self.pending_submit = try Submission.init(self.allocator, prompt, extras);
                errdefer {
                    self.pending_submit.?.deinit(self.allocator);
                    self.pending_submit = null;
                }
                self.hook_flow.dispatch = try self.dispatchHook(.{ .event = .user_prompt_expansion, .prompt = prompt, .command_name = extras.command_name, .command_args = extras.command_args, .expanded_prompt = extras.expanded_prompt });
                self.hook_flow.pending = .expansion;
                self.state = .running_hooks;
                return;
            }
        }
    }
    try self.finishSubmit(prompt, extras);
}

fn clearHumanIntent(self: *Loop) void {
    self.human_intent.deinit(self.allocator);
}

fn recordHuman(self: *Loop, text: []const u8, authorization: bool) !void {
    const root = self.parent orelse self;
    try root.human_intent.record(root.allocator, text, authorization);
    if (authorization) {
        if (root.db) |db| if (root.session_id) |id| try db.recordAuthorization(id, root.conversation.next_seq, text);
    }
}

fn finishSubmit(self: *Loop, prompt: []const u8, extras: Extras) !void {
    try self.recordUserPrompt(prompt, extras);
    self.steps = 0;
    self.recovered_from_overflow = false;
    self.repeats = 0;
    self.outcome = null;
    self.turn_start_seq = self.conversation.messages.items[self.conversation.messages.items.len - 1].seq;
    self.turn_started_ms = tool.monotonicMilliseconds(self.io);
    self.turn_tokens = 0;
    self.stop_hook_active = false;
    if (self.hook_flow.failure) |failure| self.allocator.free(failure);
    self.hook_flow.failure = null;
    if (self.last_calls) |calls| self.allocator.free(calls);
    self.last_calls = null;
    self.last_error = null;
    try self.ask();
}

fn recordUserPrompt(self: *Loop, prompt: []const u8, extras: Extras) !void {
    var mentioned: mention.Resolved =
        mention.resolve(self.allocator, self.io, self.workingDirectory(), prompt) catch .{};
    defer mentioned.deinit(self.allocator);

    const files = mentioned.attachments;
    const attachments = try self.allocator.alloc(mention.Attachment, files.len + extras.attachments.len);
    defer self.allocator.free(attachments);
    @memcpy(attachments[0..files.len], files);
    @memcpy(attachments[files.len..], extras.attachments);

    const images = try self.allocator.alloc([]const u8, mentioned.images.len + extras.images.len);
    defer self.allocator.free(images);
    @memcpy(images[0..mentioned.images.len], mentioned.images);
    @memcpy(images[mentioned.images.len..], extras.images);

    const submitted = try self.conversation.addUser(prompt, attachments, images);
    if (self.parent != null) submitted.origin = .agent else try self.recordHuman(prompt, false);
    try self.persistMessage(self.conversation.messages.items.len - 1);
}

const HookPurpose = HookFlow.Purpose;

const HookResume = HookFlow.Resume;

const pollHookFiles = HookFlow.pollHookFiles;

fn startConfigChange(self: *Loop, continuation: HookResume) !bool {
    const runner = self.hooks orelse return false;
    if (runner.set.config_change.len == 0) return false;
    const change = self.hook_flow.watch.take(.config_change) orelse return false;
    self.hook_flow.dispatch = try self.dispatchHook(.{ .event = .config_change, .source = change.source, .file_path = change.path });
    self.hook_flow.pending = .{ .lifecycle = continuation };
    self.state = .running_hooks;
    return true;
}

const observeHook = HookFlow.observeHook;

fn endHookSession(self: *Loop, reason: []const u8) void {
    if (self.parent != null) return;
    const configured = self.hooks orelse return;
    if (configured.runtime) |runtime| runtime.cancelBackground();
    if (!self.hook_flow.session_started) return;
    var runner = configured.*;
    runner.deadline_ms = tool.monotonicMilliseconds(self.io) + Hooks.cleanup_timeout_ms;
    var input = self.exportHookInput(.{ .event = .session_end }) catch self.hookInput(.{ .event = .session_end });
    input.reason = reason;
    var result = runner.evaluate(self.allocator, input) catch return;
    result.deinit(self.allocator);
}

pub const notifyHook = HookFlow.notifyHook;

fn awaitApproval(self: *Loop) void {
    self.state = .awaiting_approval;
    const call = self.pendingCall() orelse return;
    const signature = std.hash.Wyhash.hash(self.pending_seq orelse 0, call.id);
    if (self.hook_flow.permission_notice == signature) return;
    self.hook_flow.permission_notice = signature;
    self.observeHook(.{ .event = .notification, .notification_type = "permission_prompt", .message = call.arguments, .tool_name = call.name, .tool_call_id = call.id });
}

pub const hookInput = HookFlow.hookInput;

const prepareHookIdentity = HookFlow.prepareHookIdentity;

pub const exportHookInput = HookFlow.exportHookInput;

const dispatchHook = HookFlow.dispatchHook;

const lifecycle = HookFlow.lifecycle;

fn pollLifecycle(self: *Loop, dispatch: *Hooks.Dispatch) !bool {
    if (self.hook_flow.continuation() == .failed_turn) {
        try self.acceptHookResult(&dispatch.result);
        if (dispatch.failed) |err| self.say("StopFailure hook failed: {s}", .{@errorName(err)});
        self.finish(.failed);
        return true;
    }
    if (dispatch.invocation.event == .subagent_start) {
        if (dispatch.failed) |err| self.say("SubagentStart hook failed: {s}", .{@errorName(err)});
    }
    if (self.hook_flow.continuation() == .finish_turn) {
        try self.acceptHookResult(&dispatch.result);
        if (dispatch.failed) |err| {
            self.last_error = err;
            self.say("Completion hook failed: {s}", .{@errorName(err)});
            self.finish(.failed);
            return true;
        }
        if (dispatch.takeBlocked()) |reason| {
            defer self.allocator.free(reason);
            if (!dispatch.result.stop) {
                self.stop_hook_active = true;
                const continuation = try std.fmt.allocPrint(self.allocator, "[Completion hook continuation] {s}", .{reason});
                defer self.allocator.free(continuation);
                _ = try self.conversation.append(.{ .role = .user, .origin = .harness, .text = continuation });
                try self.persistMessage(self.conversation.messages.items.len - 1);
                try self.ask();
                return true;
            }
        }
        self.finish(.done);
        return true;
    }
    if (dispatch.invocation.event != .subagent_start and (dispatch.failed != null or dispatch.blocked != null or dispatch.result.stop)) {
        if (self.hook_flow.notice) |old| self.allocator.free(old);
        self.hook_flow.notice = if (dispatch.failed) |err|
            try std.fmt.allocPrint(self.allocator, "Lifecycle hook failed: {s}", .{@errorName(err)})
        else
            dispatch.takeBlocked();
        if (self.pending_submit) |*pending| pending.deinit(self.allocator);
        self.pending_submit = null;
        if (dispatch.invocation.event == .session_start) self.hook_flow.session_started = false;
        self.state = .idle;
        if ((self.hook_flow.resume_turn and self.hook_flow.continuation() != .begin_prompt and self.hook_flow.continuation() != .config_idle) or self.hook_flow.continuation() == .ask_model) self.finish(.halted);
        return true;
    }
    try self.acceptHookResult(&dispatch.result);
    self.state = .idle;
    switch (self.hook_flow.continuation()) {
        .begin_prompt => {
            var pending = self.pending_submit orelse return false;
            self.pending_submit = null;
            defer pending.deinit(self.allocator);
            try self.submitPrompt(pending.prompt, pending.asExtras());
        },
        .ask_model => try self.ask(),
        .config_idle => {},
        .compact => try self.startCompactionRequest(self.hook_flow.resume_turn),
        .compact_session => {
            self.hook_flow.session_source = .compact;
            if (try self.lifecycle(.session_start, .after_compact)) return true;
            if (self.hook_flow.resume_turn) try self.ask();
        },
        .after_compact => if (self.hook_flow.resume_turn) try self.ask(),
        .finish_turn, .failed_turn => unreachable,
    }
    return true;
}

fn pollPromptHooks(self: *Loop) !bool {
    if (self.hook_flow.purpose() != .prompt) return self.pollOtherHooks();
    const dispatch = self.hook_flow.dispatch orelse return false;
    if (!dispatch.isFinished()) return false;

    dispatch.join();
    self.hook_flow.dispatch = null;
    defer dispatch.destroy();

    var pending = self.pending_submit orelse return false;
    self.pending_submit = null;
    defer pending.deinit(self.allocator);

    if (dispatch.failed) |err| {
        self.say("UserPromptSubmit hook failed: {s}", .{@errorName(err)});
        self.state = .idle;
        return true;
    }
    if (dispatch.takeBlocked()) |reason| {
        self.hook_flow.setNotice(self.allocator, reason);
        self.state = .idle;
        return true;
    }

    self.state = .idle;
    try self.acceptHookResult(&dispatch.result);
    try self.expandPrompt(pending.prompt, pending.asExtras());
    return true;
}

fn pollOtherHooks(self: *Loop) !bool {
    const dispatch = self.hook_flow.dispatch orelse return false;
    if (!dispatch.isFinished()) return false;
    dispatch.join();
    self.hook_flow.dispatch = null;
    defer dispatch.destroy();

    if (self.hook_flow.purpose() == .lifecycle) return self.pollLifecycle(dispatch);
    if (self.hook_flow.purpose() == .expansion) {
        var pending = self.pending_submit orelse return false;
        self.pending_submit = null;
        defer pending.deinit(self.allocator);
        self.state = .idle;
        if (dispatch.failed) |err| {
            self.say("UserPromptExpansion hook failed: {s}", .{@errorName(err)});
            return true;
        }
        if (dispatch.takeBlocked()) |reason| {
            self.hook_flow.setNotice(self.allocator, reason);
            return true;
        }
        try self.acceptHookResult(&dispatch.result);
        try self.finishSubmit(pending.prompt, pending.asExtras());
        return true;
    }
    if (self.hook_flow.purpose() == .auto_denied) {
        try self.acceptHookResult(&dispatch.result);
        if (dispatch.result.retry) {
            const message_index = self.pendingIndex() orelse return false;
            const call = &self.conversation.messages.items[message_index].tool_calls[self.hook_flow.callIndex()];
            const text = try std.fmt.allocPrint(self.allocator, "{s}\n[PermissionDenied hook] You may retry this call after addressing the denial.", .{call.result orelse ""});
            if (call.result) |old| self.allocator.free(old);
            call.result = text;
            call.result_bytes = text.len;
            try self.persistToolCall(message_index, self.hook_flow.callIndex());
        }
        try self.afterAutoBlock();
        return true;
    }
    if (self.hook_flow.purpose() == .task_policy) {
        const message_index = self.pendingIndex() orelse return false;
        const call = &self.conversation.messages.items[message_index].tool_calls[self.hook_flow.callIndex()];
        if (dispatch.failed != null or dispatch.blocked != null) {
            call.status = .rejected;
            call.result = dispatch.takeBlocked() orelse try std.fmt.allocPrint(self.allocator, "Task hook failed: {s}", .{@errorName(dispatch.failed.?)});
            call.result_bytes = call.result.?.len;
            try self.persistToolCall(message_index, self.hook_flow.callIndex());
        } else try self.acceptHookResult(&dispatch.result);
        self.state = .idle;
        try self.runApproved();
        return true;
    }

    if (self.hook_flow.purpose() == .steering) {
        var pending = self.steering.orderedRemove(0);
        defer pending.deinit(self.allocator);
        if (dispatch.failed) |err| {
            self.say("UserPromptSubmit hook failed: {s}", .{@errorName(err)});
        } else if (dispatch.takeBlocked()) |reason| {
            self.hook_flow.setNotice(self.allocator, reason);
        } else {
            try self.acceptHookResult(&dispatch.result);
            try self.recordUserPrompt(pending.prompt, pending.asExtras());
        }
        try self.ask();
        return true;
    }
    if (self.hook_flow.purpose() == .tool_policy or self.hook_flow.purpose() == .permission or self.hook_flow.purpose() == .evaluation) {
        const message_index = self.pendingIndex() orelse return false;
        const index = self.hook_flow.callIndex();
        const call = &self.conversation.messages.items[message_index].tool_calls[index];
        const reason = if (dispatch.failed) |err|
            try std.fmt.allocPrint(self.allocator, "hook failed: {s}", .{@errorName(err)})
        else
            dispatch.takeBlocked();
        if (reason) |blocked| {
            const copy = try self.allocator.dupe(u8, blocked);
            if (self.hook_flow.failure) |old| self.allocator.free(old);
            self.hook_flow.failure = copy;
            call.status = .rejected;
            call.result = blocked;
            call.result_bytes = blocked.len;
        } else {
            if (dispatch.result.replacement) |replacement| {
                var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, replacement, .{}) catch return error.InvalidHookOutput;
                defer parsed.deinit();
                if (parsed.value != .object) return error.InvalidHookOutput;
                const definition = self.registry.get(call.name) orelse return error.UnknownTool;
                const schema = try std.json.parseFromSlice(std.json.Value, self.allocator, definition.schema, .{});
                defer schema.deinit();
                @import("../core/hook_schema.zig").validate(schema.value, parsed.value) catch {
                    call.status = .rejected;
                    call.result = try self.allocator.dupe(u8, "hook replacement does not satisfy the tool input schema");
                    call.result_bytes = call.result.?.len;
                    try self.persistToolCall(message_index, index);
                    try self.autoApprove();
                    return true;
                };
                const effective = try self.allocator.dupe(u8, replacement);
                self.allocator.free(call.arguments);
                call.arguments = effective;
            }
            try self.acceptHookResult(&dispatch.result);
            if (self.hook_flow.purpose() == .tool_policy and dispatch.result.permission == .ask) try self.hook_flow.asks.append(self.allocator, call.id);
            if (dispatch.result.replacement != null) {
                _ = try self.anchorToolPaths(call);
                try self.prepareAction(call);
            }
            if (self.hook_flow.purpose() == .evaluation and dispatch.result.permission == .ask) {
                try self.hook_flow.asks.append(self.allocator, call.id);
                self.hook_flow.permission_index = @max(self.hook_flow.permission_index, index + 1);
            }
        }
        try self.persistToolCall(message_index, index);
        try self.autoApprove();
        return true;
    }
    return self.pollOwnerHooks(dispatch);
}

fn startPolicyHook(self: *Loop, purpose: HookPurpose, index: usize) !void {
    const message_index = self.pendingIndex() orelse return;
    const call = self.conversation.messages.items[message_index].tool_calls[index];
    self.hook_flow.dispatch = try self.dispatchHook(.{
        .event = switch (purpose) {
            .tool_policy => .pre_tool_use,
            .evaluation => .permission_evaluate,
            else => .permission_request,
        },
        .permission_effect = if (self.needsNoDecision(&call)) "allow" else "ask",
        .action = call.prepared_action orelse "",
        .tool_name = call.name,
        .tool_input = call.arguments,
        .tool_call_id = call.id,
        .model = self.provider.model,
        .permission_mode = @tagName(self.approvals),
    });
    self.hook_flow.pending = HookFlow.Pending.policy(purpose, index);
    self.state = .running_hooks;
}

const acceptHookResult = HookFlow.acceptHookResult;

fn startOwnerPost(self: *Loop, index: usize, response: []const u8) !void {
    const message_index = self.pendingIndex() orelse return;
    const call = self.conversation.messages.items[message_index].tool_calls[index];
    self.hook_flow.dispatch = try self.dispatchHook(.{
        .event = if (call.status == .failed) .post_tool_use_failure else .post_tool_use,
        .error_message = if (call.status == .failed) response else "",
        .tool_name = call.name,
        .tool_call_id = call.id,
        .tool_input = call.arguments,
        .tool_response = response,
    });
    self.hook_flow.pending = .{ .owner_post = index };
    self.state = .running_hooks;
}

fn pollOwnerHooks(self: *Loop, dispatch: *Hooks.Dispatch) !bool {
    const message_index = self.pendingIndex() orelse return false;
    const index = self.hook_flow.callIndex();
    try self.acceptHookResult(&dispatch.result);
    if (dispatch.takeBlocked()) |feedback| {
        defer self.allocator.free(feedback);
        try self.applyPostFeedback(message_index, index, feedback);
    } else if (dispatch.result.feedback) |feedback| {
        try self.applyPostFeedback(message_index, index, feedback);
    }
    if (dispatch.failed) |err| self.say("PostToolUse hook failed: {s}", .{@errorName(err)});
    self.state = .idle;
    try self.runApproved();
    return true;
}

pub fn takeHookNotice(self: *Loop) ?[]u8 {
    const notice = self.hook_flow.notice;
    self.hook_flow.notice = null;
    return notice;
}

/// Page up to `limit` older messages in from the database, prepending them to
/// the conversation. Returns how many were loaded. No-op without a database or
/// when there is no older history.
pub fn pageHistory(self: *Loop, limit: usize) !usize {
    const db = self.db orelse return 0;
    const session_id = self.session_id orelse return 0;
    const before = self.conversation.firstSeq() orelse return 0;
    if (before == 0) return 0;

    const loaded = try db.loadMessages(self.allocator, session_id, @intCast(before), limit);
    if (loaded.len == 0) {
        self.allocator.free(loaded);
        return 0;
    }

    std.mem.reverse(Conversation.Message, loaded);
    try self.conversation.prepend(loaded);
    self.allocator.free(loaded);
    return loaded.len;
}

/// Load the full reasoning body for a message, replacing its in-memory preview.
/// No-op without a database, or when the message has no reasoning, or when the
/// preview already holds the full text.
pub fn loadThinking(self: *Loop, msg: *Conversation.Message) !void {
    const db = self.db orelse return;
    const session_id = self.session_id orelse return;
    if (msg.thinking_bytes <= Conversation.preview_bytes) return;
    if (msg.thinking) |t| {
        if (t.len >= msg.thinking_bytes) return;
    }

    const full = try db.loadThinking(self.allocator, session_id, @intCast(msg.seq)) orelse return;
    if (msg.thinking) |t| self.allocator.free(t);
    msg.thinking = full;
}

/// Load an attachment in full, replacing its in-memory preview. No-op without a
/// database, or when the preview already holds the whole file.
pub fn loadAttachment(self: *Loop, msg: *Conversation.Message, index: usize) !void {
    const db = self.db orelse return;
    const session_id = self.session_id orelse return;
    if (index >= msg.attachments.len) return;

    const attachment = &msg.attachments[index];
    if (!attachment.shortened()) return;

    const full = try db.loadAttachment(
        self.allocator,
        session_id,
        @intCast(msg.seq),
        @intCast(index),
    ) orelse return;

    self.allocator.free(attachment.content);
    attachment.content = full;
}

/// Load the full result body for a tool call, replacing its in-memory preview.
/// No-op without a database, or when the preview already holds the full text.
pub fn loadToolResult(self: *Loop, msg: *Conversation.Message, call_index: usize) !void {
    const db = self.db orelse return;
    const session_id = self.session_id orelse return;
    if (call_index >= msg.tool_calls.len) return;
    const call = &msg.tool_calls[call_index];
    if (call.result_bytes <= Conversation.preview_bytes) return;
    if (call.result) |r| {
        if (r.len >= call.result_bytes) return;
    }

    const full = try db.loadToolResult(
        self.allocator,
        session_id,
        @intCast(msg.seq),
        @intCast(call_index),
    ) orelse return;
    if (call.result) |r| self.allocator.free(r);
    call.result = full;
}

fn ask(self: *Loop) !void {
    try self.pollHookFiles(true);
    if (try self.startConfigChange(.ask_model)) return;
    if (self.steering.items.len > 0) {
        if (self.hooks) |runner| {
            if (runner.set.forEvent(.user_prompt_submit).len > 0) {
                self.hook_flow.dispatch = try self.dispatchHook(.{
                    .event = .user_prompt_submit,
                    .prompt = self.steering.items[0].prompt,
                });
                self.hook_flow.pending = .steering;
                self.state = .running_hooks;
                return;
            }
        }
    }
    try self.applySteering();
    if (self.hooks) |runner| {
        if (runner.runtime) |runtime| {
            var background = try runtime.drainFor(self.allocator, &self.hook_flow.identity);
            defer background.deinit(self.allocator);
            try self.acceptHookResult(&background);
        }
    }
    if (self.hook_flow.context) |context| {
        defer self.allocator.free(context);
        self.hook_flow.context = null;
        _ = try self.conversation.append(.{ .role = .user, .origin = .hook, .text = context });
        try self.persistMessage(self.conversation.messages.items.len - 1);
    }
    if (self.overBudget()) |reason| return self.stop(reason);
    if (self.shouldCompact()) return self.startCompaction(true);
    if (!try self.contextFits(self.turn(""))) {
        const may_recover = self.auto_compact_at > 0 and !self.recovered_from_overflow;
        if (!may_recover) return self.stop(context_full_notice);
        self.recovered_from_overflow = true;
        return self.startCompaction(true);
    }
    self.steps += 1;
    if (self.steps > self.agent.steps and !self.isRunningWithoutLimit()) {
        return self.stop("Stopped: too many tool calls in one turn.");
    }
    try self.trackModel("initial");
    var request_turn = self.turn("");
    request_turn.hook_input = try self.exportHookInput(.{ .event = .pre_model_request });
    self.request = try Request.start(
        self.allocator,
        self.io,
        self.provider,
        self.conversation,
        request_turn,
    );
    self.requests_started += 1;
    self.state = .thinking;
}

/// Hand the model whatever was typed while it was working.
///
/// Drained here rather than the moment it is typed: a user message written
/// between an assistant's tool calls and their results would split an exchange
/// the wire format requires to be whole. By the time a step is being asked for,
/// every result is in.
fn applySteering(self: *Loop) !void {
    while (self.steering.items.len > 0) {
        var pending = self.steering.orderedRemove(0);
        defer pending.deinit(self.allocator);
        try self.recordUserPrompt(pending.prompt, pending.asExtras());
    }
}

/// Add to what the model is being asked, without waiting for the turn to end.
///
/// A correction is only worth anything while there is still work to redirect,
/// so this is refused when the loop is idle - the caller starts a turn instead.
pub fn steer(self: *Loop, text: []const u8, extras: Extras) !bool {
    if (!self.isBusy()) return false;

    var pending: Submission = try .init(self.allocator, text, extras);
    errdefer pending.deinit(self.allocator);
    try self.steering.append(self.allocator, pending);
    return true;
}

/// What has been typed mid-turn and not yet handed over, for the UI to show as
/// waiting.
pub fn pendingSteering(self: *const Loop) []const Submission {
    return self.steering.items;
}

/// Take the oldest thing typed mid-turn, handing ownership to the caller.
///
/// For when the turn it was meant to steer ended before it could be handed
/// over - cancelled, or stopped at a limit. It is a prompt now rather than a
/// correction, and the caller starts a turn with it. Leaving it pending would
/// mean it silently rode along with whatever was typed next.
pub fn takeSteering(self: *Loop) ?Submission {
    if (self.steering.items.len == 0) return null;
    return self.steering.orderedRemove(0);
}

/// Throw away anything typed mid-turn that has not been handed over. Used when
/// the transcript it was meant for is being swapped out from under it.
pub fn dropSteering(self: *Loop) void {
    for (self.steering.items) |*pending| pending.deinit(self.allocator);
    self.steering.clearRetainingCapacity();
}

/// Why this turn should not take another step, or null while it may.
///
/// Checked before asking rather than after answering: the point is to stop
/// spending, and a turn that has already blown its budget spends again the
/// moment it takes another step.
fn overBudget(self: *Loop) ?[]const u8 {
    if (self.max_turn_tokens > 0 and self.turn_tokens >= self.max_turn_tokens) {
        return "Stopped: this turn has spent its token budget. Ask again to carry on.";
    }
    if (self.max_turn_ms > 0) {
        const started = self.turn_started_ms orelse return null;
        const spent = tool.monotonicMilliseconds(self.io) - started;
        if (spent >= self.max_turn_ms) {
            return "Stopped: this turn ran out of time. Ask again to carry on.";
        }
    }
    return null;
}

/// Abandon a turn whose provider has stopped sending.
///
/// Interrupted the way cancelling interrupts it: a worker blocked on a socket
/// read unwinds for nothing short of its future being cancelled.
fn giveUpIfStalled(self: *Loop, request: *Request) bool {
    if (!request.stalled(self.max_stall_ms)) return false;

    self.timed_out = true;
    self.requestStop();
    self.startReaping();

    self.compacting = false;
    self.state = .cancelling;
    return true;
}

/// Abandon the turn, discarding whatever the worker had produced.
pub fn cancel(self: *Loop) !void {
    if (!self.isBusy()) {
        if (self.pending_submit) |*pending| pending.deinit(self.allocator);
        self.pending_submit = null;
        return;
    }
    if (self.state == .cancelling) return;

    // `Io.Future.cancel` waits on the calling thread, so `canceller` takes it.
    self.interrupted = true;
    self.requestStop();
    self.startReaping();

    self.compacting = false;
    self.state = .cancelling;
}

/// Interrupt both workers, waiting for them somewhere other than here.
fn startReaping(self: *Loop) void {
    if (self.signalled) return;
    self.signalled = true;
    self.reaped.store(false, .release);

    if (self.io.concurrent(reap, .{self})) |future| {
        self.canceller = future;
    } else |_| {
        // No thread for the wait; stalling beats never leaving `Cancelling`.
        self.reap();
    }
}

/// Interrupt both workers and wait for them to unwind, off the UI's thread.
fn reap(self: *Loop) void {
    if (self.request) |request| request.cancel();
    if (self.judging) |judging| judging.request.cancel();
    if (self.tools) |tools| tools.cancel();
    if (self.hook_flow.dispatch) |dispatch| dispatch.cancel();
    if (self.interrupted and self.parent == null) {
        self.interrupted = false;
        if (self.hooks) |configured| {
            var runner = configured.*;
            runner.stop = null;
            runner.deadline_ms = std.Io.Clock.now(.awake, self.io).toMilliseconds() + Hooks.cleanup_timeout_ms;
            var result = runner.evaluate(self.allocator, self.hookInput(.{ .event = .interrupt })) catch null;
            if (result) |*value| {
                defer value.deinit(self.allocator);
                if (value.message) |message| if (runner.runtime) |runtime| {
                    runtime.notice(message) catch {};
                };
            }
        }
    }
    self.reaped.store(true, .release);
}

/// Reap a cancelled turn once its worker has actually stopped.
///
/// Nothing here touches the conversation until both workers are gone: the
/// provider borrows it, and a tool run writes into results the loop is about to
/// free.
fn pollCancelled(self: *Loop) !bool {
    if (self.canceller) |*canceller| {
        if (!self.reaped.load(.acquire)) return false;
        canceller.await(self.io);
        self.canceller = null;
    } else if (!self.reaped.load(.acquire)) {
        // Only when there was no thread for the reaper, and it ran inline.
        self.startReaping();
        return false;
    }

    if (self.hook_flow.dispatch) |dispatch| {
        dispatch.join();
        if (dispatch.invocation.event == .session_start) self.hook_flow.session_started = false;
        dispatch.destroy();
        self.hook_flow.dispatch = null;
    }

    if (self.request) |request| {
        request.join();
        request.destroy();
        self.request = null;
    }

    if (self.judging) |judging| {
        judging.request.join();
        judging.destroy(self.allocator);
        self.judging = null;
    }

    if (self.tools) |tools| {
        tools.join();
        self.tools = null;
        defer tools.destroy();
        try self.adoptSettled(tools);
        try self.persistReads();
        self.sealCheckpoints();
    }
    self.clearNotes();

    try self.abandonPending("cancelled");
    if (self.pending_submit) |*pending| pending.deinit(self.allocator);
    self.pending_submit = null;

    if (self.timed_out) {
        self.last_error = error.Timeout;
        const text = "Request failed - the provider stopped responding.";
        _ = try self.conversation.addAssistant(text, null, null);
        try self.persistMessage(self.conversation.messages.items.len - 1);
        self.finish(.failed);
        return true;
    }

    self.finish(.cancelled);
    return true;
}

/// Mark every call the cancelled turn left unfinished, so the transcript says
/// what happened to it rather than leaving a row spinning forever.
fn abandonPending(self: *Loop, reason: []const u8) !void {
    const index = self.pendingIndex() orelse return;
    for (self.conversation.messages.items[index].tool_calls, 0..) |*call, i| {
        if (call.status != .pending and call.status != .running) continue;
        call.status = .rejected;
        if (call.result == null) {
            call.result = try self.allocator.dupe(u8, reason);
            call.result_bytes = reason.len;
        }
        try self.persistToolCall(index, i);
    }
    try self.appendToolResults();
}

/// Advance the loop. Called from the UI's tick; returns true if anything
/// changed and the screen needs redrawing.
pub fn poll(self: *Loop) !bool {
    try self.pollHookFiles(false);
    if (self.state == .idle and try self.startConfigChange(.config_idle)) return true;
    if (self.state == .idle and !self.hook_flow.idle_notified) {
        if (self.hook_flow.idle_since) |since| {
            if (tool.monotonicMilliseconds(self.io) - since >= 60_000) {
                self.hook_flow.idle_notified = true;
                self.notifyHook("idle_prompt", "The agent is waiting for input");
            }
        }
    }
    var background_changed = false;
    if (self.hooks) |runner| {
        if (runner.runtime) |runtime| {
            var background = try runtime.drainFor(self.allocator, &self.hook_flow.identity);
            defer background.deinit(self.allocator);
            background_changed = background.message != null or background.context != null;
            try self.acceptHookResult(&background);
        }
    }
    const changed = try switch (self.state) {
        .idle, .awaiting_approval, .awaiting_answer => false,
        .running_hooks => self.pollPromptHooks(),
        .thinking, .compacting => self.pollRequest(),
        .running_tools => self.pollTools(),
        .classifying => self.pollJudging(),
        .cancelling => self.pollCancelled(),
    };
    return changed or background_changed;
}

fn pollRequest(self: *Loop) !bool {
    const request = self.request orelse return false;
    if (!request.isFinished()) return self.giveUpIfStalled(request);

    request.join();
    self.request = null;
    defer request.destroy();
    if (!self.compacting and request.reply != null) {
        const current = request.provider.current();
        const model = try self.allocator.dupe(u8, current.model);
        errdefer self.allocator.free(model);
        const provider = try self.allocator.dupe(u8, if (current.name.len > 0) current.name else request.provider.name);
        if (self.effective_model) |old| self.allocator.free(old);
        if (self.effective_provider) |old| self.allocator.free(old);
        self.effective_model = model;
        self.effective_provider = provider;
    }

    self.syncProvider();

    const thinking: ?[]const u8 = if (request.thoughts.isEmpty())
        null
    else
        try request.thoughts.snapshot(self.allocator);
    defer if (thinking) |t| self.allocator.free(t);
    const thinking_ms = request.thoughts.elapsedMs();

    if (request.failed) |err| {
        self.last_error = err;

        const server_refused_the_size = err == error.ContextTooLarge and !self.compacting;
        const may_recover = self.auto_compact_at > 0 and !self.recovered_from_overflow;
        if (server_refused_the_size and may_recover) {
            self.recovered_from_overflow = true;
            try self.startCompaction(true);
            return true;
        }

        const detail = request.provider.explain(err, self.allocator) catch
            try std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)});
        defer self.allocator.free(detail);

        const text = try std.fmt.allocPrint(self.allocator, "Request failed - {s}", .{detail});
        defer self.allocator.free(text);
        _ = try self.conversation.addAssistant(text, thinking, thinking_ms);
        try self.persistMessage(self.conversation.messages.items.len - 1);
        if (self.hooks) |runner| {
            if (runner.set.stop_failure.len > 0) {
                self.hook_flow.dispatch = try self.dispatchHook(.{ .event = .stop_failure, .error_type = Provider.errorType(err, detail), .error_message = detail, .last_assistant_message = text });
                self.hook_flow.pending = .{ .lifecycle = .failed_turn };
                self.state = .running_hooks;
                return true;
            }
        }
        self.finish(.failed);
        return true;
    }

    if (request.reply) |reply| {
        self.usage.calls += 1;
        self.usage.input_tokens += reply.usage.prompt_tokens;
        self.usage.output_tokens += reply.usage.completion_tokens;
        self.turn_tokens += reply.usage.prompt_tokens + reply.usage.completion_tokens;
        self.usage.eval_duration_ns += reply.usage.eval_duration_ns;
        if (reply.usage.prompt_tokens > 0) {
            self.usage.context_tokens = reply.usage.prompt_tokens +| reply.usage.completion_tokens;
        }
    }

    const reply = request.reply orelse {
        self.finish(.failed);
        return true;
    };

    if (self.compacting) {
        try self.finishCompaction(reply.text);
        return true;
    }

    const text = if (reply.text.len == 0 and reply.tool_calls.len == 0)
        no_reply
    else
        reply.text;

    const display_text = if (request.displaysHooks()) try request.content.snapshot(self.allocator) else null;
    defer if (display_text) |shown| self.allocator.free(shown);
    _ = try self.conversation.append(.{
        .role = .assistant,
        .text = text,
        .display_text = display_text,
        .thinking = thinking,
        .thinking_ms = thinking_ms,
        .tool_calls = reply.tool_calls,
        .provider_state = reply.provider_state,
    });
    try self.persistMessage(self.conversation.messages.items.len - 1);

    if (reply.tool_calls.len == 0) {
        if (try self.lifecycle(if (self.parent == null) .stop else .subagent_stop, .finish_turn)) return true;
        self.finish(.done);
        return true;
    }

    self.pending_seq = self.conversation.messages.items[self.conversation.messages.items.len - 1].seq;
    self.pending_index = 0;
    if (try self.repeating(reply.tool_calls)) {
        try self.stop("Stopped: the same tool call came back three times running.");
        return true;
    }

    try self.autoApprove();
    return true;
}

/// What the turn that just ended did, read back off the transcript. The caller
/// owns the result. Empty while a turn is still running, since the turn it would
/// describe is the one in progress.
pub fn lastTurn(self: *Loop, allocator: std.mem.Allocator) !recap.Recap {
    return recap.of(allocator, self.conversation.messages.items, self.turn_start_seq);
}

/// The one place a turn ends. Anything that has to happen once per turn goes
/// here rather than at each of the places that used to set `.idle` by hand.
fn finish(self: *Loop, outcome: Outcome) void {
    self.state = .idle;
    self.finished += 1;
    self.hook_flow.asks.clearRetainingCapacity();
    self.pending_seq = null;
    self.pending_index = 0;
    self.repeats = 0;
    self.compacting = false;
    self.outcome = outcome;
    self.notifyHook("agent_completed", @tagName(outcome));
    self.hook_flow.idle_since = tool.monotonicMilliseconds(self.io);
    self.hook_flow.idle_notified = false;
    self.resume_after_compaction = false;

    self.timed_out = false;

    // Left raised, these would send the next cancel down the inline join.
    self.signalled = false;
    self.reaped.store(false, .release);

    // Written down now: trimming older messages would make the turn unreadable.
    self.recordSummary(outcome) catch {};
}

/// Append what the turn did as a `summary` message. Failing to write one is
/// not worth failing the turn over, so the caller swallows it.
fn recordSummary(self: *Loop, outcome: Outcome) !void {
    var done = try self.lastTurn(self.allocator);
    defer done.deinit(self.allocator);
    if (!done.any()) return;

    const line = try recap.text(self.allocator, &done, outcome);
    defer self.allocator.free(line);

    _ = try self.conversation.append(.{ .role = .summary, .text = line });
    try self.persistMessage(self.conversation.messages.items.len - 1);
}

/// End the turn with a message saying why. The message is an assistant turn, so
/// the model sees it too and a later turn is not left guessing.
fn stop(self: *Loop, reason: []const u8) !void {
    std.debug.assert(std.mem.startsWith(u8, reason, halt_prefix));
    try self.abandonPending(reason);
    _ = try self.conversation.addAssistant(reason, null, null);
    try self.persistMessage(self.conversation.messages.items.len - 1);
    self.finish(.halted);
}

/// Whether this batch of calls is the one before it, again. Identical means
/// same tools in the same order with the same arguments: a model reading three
/// files and then re-reading one of them is working, not looping.
fn repeating(self: *Loop, calls: []const Conversation.ToolCall) !bool {
    var signature: std.Io.Writer.Allocating = .init(self.allocator);
    errdefer signature.deinit();
    for (calls) |call| {
        try signature.writer.print("{s}\x00{s}\x00", .{ call.name, call.arguments });
    }
    const current = try signature.toOwnedSlice();

    if (self.last_calls) |previous| {
        if (std.mem.eql(u8, previous, current)) {
            self.allocator.free(current);
            self.repeats += 1;
            return self.repeats >= max_repeats;
        }
        self.allocator.free(previous);
    }

    self.last_calls = current;
    self.repeats = 1;
    return false;
}

fn action(self: *Loop, call: *const Conversation.ToolCall) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, call.arguments, .{});
    if (input != .object) return error.InvalidToolInput;
    var targets: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "path", "file" }) |field| {
        if (input.object.get(field)) |value| {
            if (value != .string) continue;
            try targets.append(a, self.resolveAgainstProject(a, value.string) orelse return error.UnresolvedActionTarget);
        }
    }
    var roots: std.ArrayList([]const u8) = .empty;
    try roots.append(a, self.followLinks(a, self.project_root) orelse return error.UnresolvedActionTarget);
    for (self.additional_roots.items) |root| try roots.append(a, self.followLinks(a, root) orelse return error.UnresolvedActionTarget);
    return std.json.Stringify.valueAlloc(self.allocator, .{
        .call_id = call.id,
        .tool = call.name,
        .arguments = input,
        .cwd = try paths.resolve(self.io, a, self.workingDirectory(), "."),
        .allowed_roots = roots.items,
        .resolved_targets = targets.items,
        .agent_id = &self.hook_flow.identity,
        .parent_agent_id = if (self.parent) |parent| @as([]const u8, &parent.hook_flow.identity) else "",
        .parent_tool_call_id = self.hook_flow.parent_call_id,
    }, .{});
}

fn prepareAction(self: *Loop, call: *Conversation.ToolCall) !void {
    const prepared = self.action(call) catch |err| {
        if (err == error.OutOfMemory) return err;
        call.status = .rejected;
        call.result = try self.allocator.dupe(u8, "could not resolve the action's execution context");
        call.result_bytes = call.result.?.len;
        return;
    };
    if (call.prepared_action) |old| self.allocator.free(old);
    call.prepared_action = prepared;
}

fn approve(self: *Loop, call: *Conversation.ToolCall) !void {
    if (call.status != .pending) return;
    const prepared = call.prepared_action orelse return error.UnpreparedAction;
    const current = try self.action(call);
    defer self.allocator.free(current);
    if (!std.mem.eql(u8, current, prepared)) {
        call.status = .rejected;
        call.result = try self.allocator.dupe(u8, "action changed while awaiting approval; propose it again");
        call.result_bytes = call.result.?.len;
        return;
    }
    if (call.approved_action) |old| self.allocator.free(old);
    call.approved_action = try self.allocator.dupe(u8, prepared);
    call.begin(tool.monotonicMilliseconds(self.io));
}

fn autoApprove(self: *Loop) !void {
    // Each session is its own process, so another may have changed them.
    self.reloadAllowances() catch {};
    const message_index = self.pendingIndex() orelse return;
    const calls = self.conversation.messages.items[message_index].tool_calls;

    for (calls, 0..) |*call, i| {
        if (call.status != .pending) continue;
        if (!self.agent.allows(call.name)) {
            try self.refuse(message_index, i);
            continue;
        }
        if (self.registry.get(call.name) == null) {
            try self.refuse(message_index, i);
            continue;
        }
        if (try self.anchorToolPaths(call)) try self.persistToolCall(message_index, i);
        try self.prepareAction(call);
        if (call.status != .pending) {
            try self.persistToolCall(message_index, i);
            continue;
        }
        if (self.hooks) |runner| {
            if (self.hook_flow.pre_seq != self.pending_seq) {
                self.hook_flow.pre_seq = self.pending_seq;
                self.hook_flow.pre_index = 0;
                self.hook_flow.permission_index = 0;
                self.hook_flow.evaluate_index = 0;
                self.hook_flow.asks.clearRetainingCapacity();
            }
            if (i >= self.hook_flow.pre_index) {
                self.hook_flow.pre_index = i + 1;
                if (runner.set.forEvent(.pre_tool_use).len > 0) {
                    try self.startPolicyHook(.tool_policy, i);
                    return;
                }
            }
            if (i >= self.hook_flow.evaluate_index) {
                self.hook_flow.evaluate_index = i + 1;
                if (runner.set.permission_evaluate.len > 0) {
                    try self.startPolicyHook(.evaluation, i);
                    return;
                }
            }
            if (!self.needsNoDecision(call) and i >= self.hook_flow.permission_index) {
                self.hook_flow.permission_index = i + 1;
                if (runner.set.forEvent(.permission_request).len > 0) {
                    try self.startPolicyHook(.permission, i);
                    return;
                }
            }
        }
        if (self.needsNoDecision(call)) try self.approve(call);
    }

    if (self.firstPending() != null) {
        if (self.approvals == .auto) return self.judgeNext();
        self.awaitApproval();
        return;
    }
    try self.runApproved();
}

/// A call auto mode is having judged, and the request judging it.
const Judging = struct {
    request: *Request,
    /// What the request is shown, borrowed by it until it is joined.
    convo: *Conversation,
    call: usize,
    stage: classifier.Stage,

    fn destroy(self: Judging, allocator: std.mem.Allocator) void {
        self.request.destroy();
        self.convo.deinit();
        allocator.destroy(self.convo);
    }
};

/// Hand decisions on calls to `mode` from now on, with a clean slate of blocks.
pub fn setApprovals(self: *Loop, mode: Config.Approvals) void {
    self.approvals = mode;
    self.blocks_in_row = 0;
    self.blocks_total = 0;
}

/// Blocks in a row, and in a session, after which auto mode hands decisions
/// back to the person: something is off, with the task or with the judge.
const max_blocks_in_row = 3;
const max_blocks_total = 20;

/// Have the next call still waiting on a decision judged, letting an edit
/// inside the project through on the way; run the batch once none is left.
fn judgeNext(self: *Loop) !void {
    const message_index = self.pendingIndex() orelse return;
    const calls = self.conversation.messages.items[message_index].tool_calls;
    for (calls, 0..) |*call, index| {
        if (call.status != .pending) continue;
        if (self.hookRequiresApproval(call)) {
            self.awaitApproval();
            return;
        }
        if (self.editsInside(call)) {
            try self.approve(call);
            continue;
        }
        return self.startJudging(index, .quick);
    }
    try self.runApproved();
}

fn editsInside(self: *const Loop, call: *const Conversation.ToolCall) bool {
    if (!std.mem.eql(u8, call.name, "write") and !std.mem.eql(u8, call.name, "edit")) return false;
    return !self.escapesProject(call);
}

fn startJudging(self: *Loop, call_index: usize, stage: classifier.Stage) !void {
    if (stage == .quick) self.review_started_ms = tool.monotonicMilliseconds(self.io);
    const message_index = self.pendingIndex() orelse return;
    const call = self.conversation.messages.items[message_index].tool_calls[call_index];
    const asker = self.parent orelse self;

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const stored_intent = if (asker.db) |db| if (asker.session_id) |id| try db.humanIntent(self.allocator, id) else null else null;
    defer if (stored_intent) |snapshot| snapshot.deinit(self.allocator);
    const remembered = try asker.human_intent.view(arena_state.allocator());
    const intent = if (stored_intent) |snapshot| snapshot.messages else if (remembered.len > 0) remembered else asker.conversation.messages.items;
    const complete_intent = if (stored_intent) |snapshot| snapshot.is_complete else asker.human_intent.is_complete;
    if (!complete_intent) {
        _ = try self.judgeUnavailable(call_index, "human instructions exceed the review context budget");
        return;
    }
    const has_human = for (intent) |message| {
        if (message.role == .user and message.origin == .human and std.mem.trim(u8, message.text, " \t\r\n").len > 0) break true;
    } else false;
    if (!has_human) {
        _ = try self.judgeUnavailable(call_index, "no verified human request is available");
        return;
    }
    const material = try classifier.material(
        arena_state.allocator(),
        call.prepared_action orelse return error.UnpreparedAction,
        intent,
        self.conversation.messages.items,
        call,
    );

    const convo = try self.allocator.create(Conversation);
    errdefer self.allocator.destroy(convo);
    convo.* = .init(self.allocator);
    errdefer convo.deinit();
    _ = try convo.append(.{ .role = .user, .origin = .harness, .text = material });

    const request = try Request.start(self.allocator, self.io, self.provider, convo, .{
        .backend = self.backend,
        .model_policy = self.model_policy,
        .system = classifier.system_prompt,
        .hooks = self.hooks,
        .hook_input = try self.exportHookInput(.{ .event = .pre_model_request, .request_purpose = .approval_judge }),
        .instruction = classifier.instruction(stage),
    });
    self.requests_started += 1;
    request.started_ms = self.review_started_ms;
    self.judging = .{ .request = request, .convo = convo, .call = call_index, .stage = stage };
    self.state = .classifying;
}

fn pollJudging(self: *Loop) !bool {
    const judging = self.judging orelse return false;
    if (!judging.request.isFinished()) {
        if (!judging.request.expired(self.model_policy.reviewer_timeout_ms)) return false;
        judging.request.cancel();
        self.judging = null;
        defer judging.destroy(self.allocator);
        return self.judgeUnavailable(judging.call, "reviewer timed out");
    }
    judging.request.join();
    self.judging = null;
    defer judging.destroy(self.allocator);

    const message_index = self.pendingIndex() orelse return true;
    const call = &self.conversation.messages.items[message_index].tool_calls[judging.call];
    const reply = judging.request.reply orelse {
        const why = if (judging.request.failed) |err| @errorName(err) else "no answer";
        return self.judgeUnavailable(judging.call, why);
    };
    self.usage.calls += 1;
    self.usage.input_tokens += reply.usage.prompt_tokens;
    self.usage.output_tokens += reply.usage.completion_tokens;
    self.turn_tokens += reply.usage.prompt_tokens + reply.usage.completion_tokens;

    switch (classifier.verdict(judging.stage, reply.text)) {
        .allow => {
            self.blocks_in_row = 0;
            try self.approve(call);
            try self.judgeNext();
        },
        .block => |reason| switch (judging.stage) {
            .quick => try self.startJudging(judging.call, .careful),
            .careful => try self.block(message_index, judging.call, reason),
        },
        .unclear => switch (judging.stage) {
            .quick => try self.startJudging(judging.call, .careful),
            .careful => return self.judgeUnavailable(judging.call, "its answer could not be read"),
        },
    }
    return true;
}

fn judgeUnavailable(self: *Loop, index: usize, why: []const u8) anyerror!bool {
    const message_index = self.pendingIndex() orelse return true;
    if (self.model_policy.reviewer_fallback == .deny) {
        try self.block(message_index, index, why);
        return true;
    }
    return self.askInstead(&self.conversation.messages.items[message_index].tool_calls[index], why);
}

fn askInstead(self: *Loop, call: *const Conversation.ToolCall, why: []const u8) bool {
    self.say("Auto mode could not judge the {s} call ({s}), so it is asking you", .{ call.name, why });
    self.awaitApproval();
    return true;
}

/// Turn a call down on auto mode's say-so, telling the model why, and hand
/// decisions back to the person once that has happened too often.
fn block(self: *Loop, message_index: usize, call_index: usize, reason: []const u8) !void {
    const call = &self.conversation.messages.items[message_index].tool_calls[call_index];
    const text = try std.fmt.allocPrint(
        self.allocator,
        "Blocked by auto mode: {s}. Do this another way, or ask the user first.",
        .{if (reason.len > 0) reason else "it looked unsafe"},
    );
    call.status = .rejected;
    call.result = text;
    call.result_bytes = text.len;
    try self.persistToolCall(message_index, call_index);

    if (self.hooks) |runner| {
        if (runner.set.permission_denied.len > 0) {
            self.hook_flow.dispatch = try self.dispatchHook(.{ .event = .permission_denied, .request_purpose = .approval_judge, .tool_name = call.name, .tool_input = call.arguments, .tool_call_id = call.id, .error_message = reason });
            self.hook_flow.pending = .{ .auto_denied = call_index };
            self.state = .running_hooks;
            return;
        }
    }
    try self.afterAutoBlock();
}

fn afterAutoBlock(self: *Loop) !void {
    self.blocks_in_row += 1;
    self.blocks_total += 1;
    if (self.blocks_in_row >= max_blocks_in_row or self.blocks_total >= max_blocks_total) {
        if (self.model_policy.reviewer_fallback == .deny) return self.stop("Stopped: repeated automatic approval denials; no actions were authorized by fallback.");
        self.approvals = .ask;
        self.blocks_in_row = 0;
        self.blocks_total = 0;
        self.say("Auto mode blocked too many calls, so decisions are back with you", .{});
        if (self.firstPending() != null) {
            self.awaitApproval();
            return;
        }
        return self.runApproved();
    }
    try self.judgeNext();
}

/// The question the model is waiting on an answer to, or null when it is not.
pub fn pendingQuestion(self: *Loop) ?*Conversation.ToolCall {
    if (self.state != .awaiting_answer) return null;
    return self.firstAsk();
}

/// The first `ask_user` call still waiting to be answered.
fn firstAsk(self: *Loop) ?*Conversation.ToolCall {
    const message_index = self.pendingIndex() orelse return null;
    const calls = self.conversation.messages.items[message_index].tool_calls;
    for (calls) |*call| {
        if (call.status != .running) continue;
        if (std.mem.eql(u8, call.name, ask_user.name)) return call;
    }
    return null;
}

/// Write the user's answer in as the result of the question, then carry on.
///
/// The answer settles one call. Anything else the model asked for in the same
/// batch runs afterwards, and a second question stops the turn again.
pub fn answer(self: *Loop, text: []const u8) !void {
    if (self.state != .awaiting_answer) return;

    const message_index = self.pendingIndex() orelse return;
    const calls = self.conversation.messages.items[message_index].tool_calls;

    for (calls, 0..) |*call, i| {
        if (call.status != .running) continue;
        if (!std.mem.eql(u8, call.name, ask_user.name)) continue;

        const receipt = try std.json.Stringify.valueAlloc(self.allocator, .{ .kind = "human_answer", .message_seq = self.conversation.messages.items[message_index].seq, .call_index = i, .answer = HumanIntent.clip(text, HumanIntent.decision_bytes / 2), .is_complete = text.len <= HumanIntent.decision_bytes / 2 }, .{});
        defer self.allocator.free(receipt);
        try self.recordHuman(receipt, true);
        self.approved_ask_index = null;
        call.settle(.ok, tool.monotonicMilliseconds(self.io));
        call.result = try self.allocator.dupe(u8, text);
        call.result_bytes = text.len;
        try self.persistToolCall(message_index, i);
        if (self.hooks) |runner| {
            if (runner.set.forEvent(.post_tool_use).len > 0) {
                try self.startOwnerPost(i, call.result.?);
                return;
            }
        }
        break;
    }

    try self.runApproved();
}

/// Write the step list to the session it belongs to. No-op without a database,
/// or before the session row exists - there is nothing to attach it to yet, and
/// the next write after the first message picks it up.
fn persistTodos(self: *Loop) !void {
    const db = self.db orelse return;
    const session_id = self.session_id orelse return;
    try db.setTodos(session_id, self.todos.items.items);
}

fn checkTodoTasks(self: *Loop, message_index: usize, call_index: usize) !bool {
    const runner = self.hooks orelse return false;
    if (runner.set.task_created.len == 0 and runner.set.task_completed.len == 0) return false;
    const call = self.conversation.messages.items[message_index].tool_calls[call_index];
    if (self.hook_flow.task_seq != self.pending_seq or self.hook_flow.task_call != call_index) {
        self.hook_flow.task_seq = self.pending_seq;
        self.hook_flow.task_call = call_index;
        self.hook_flow.task_cursor = 0;
    }
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    var next = todo.List.init(arena.allocator());
    try next.replace(todo_tool.parse(arena.allocator(), call.arguments));
    while (self.hook_flow.task_cursor < next.items.items.len * 2) {
        const cursor = self.hook_flow.task_cursor;
        self.hook_flow.task_cursor += 1;
        const item = next.items.items[cursor / 2];
        const previous: ?todo.Status = for (self.todos.items.items) |old| {
            if (std.mem.eql(u8, old.text, item.text)) break old.status;
        } else null;
        const event: Hooks.Event = if (cursor % 2 == 0) .task_created else .task_completed;
        if (event == .task_created and previous != null) continue;
        if (event == .task_completed and (item.status != .done or previous == .done)) continue;
        if (runner.set.forEvent(event).len == 0) continue;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(item.text, &digest, .{});
        const task_id = std.fmt.bytesToHex(digest, .lower);
        self.hook_flow.dispatch = try self.dispatchHook(.{ .event = event, .task_id = &task_id, .task_subject = item.text, .task_description = item.text, .tool_call_id = call.id });
        self.hook_flow.pending = .{ .task_policy = call_index };
        self.state = .running_hooks;
        return true;
    }
    return false;
}

fn anchorToolPaths(self: *Loop, call: *Conversation.ToolCall) !bool {
    if (self.working_directory == null) return false;
    const names = [_][]const u8{ "read", "write", "edit", "list", "glob", "grep" };
    const filesystem = for (names) |name| {
        if (std.mem.eql(u8, call.name, name)) break true;
    } else false;
    if (!filesystem) return false;
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    var parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), call.arguments, .{}) catch return false;
    if (parsed != .object) return false;
    const field = parsed.object.get("path") orelse return false;
    if (field != .string or std.fs.path.isAbsolute(field.string)) return false;
    try parsed.object.put(arena.allocator(), "path", .{ .string = try std.fs.path.resolve(arena.allocator(), &.{ self.workingDirectory(), field.string }) });
    const arguments = try std.json.Stringify.valueAlloc(self.allocator, parsed, .{});
    self.allocator.free(call.arguments);
    call.arguments = arguments;
    return true;
}

/// Settle every `todo` call in the batch, here on the thread that draws.
///
/// The list is what the sidebar reads every frame, so a tool worker writing it
/// would be a race - and there is nothing in it worth a worker: no file is
/// touched and no process runs.
fn applyTodo(self: *Loop, message_index: usize, i: usize) !void {
    const call = &self.conversation.messages.items[message_index].tool_calls[i];
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();

    try self.todos.replace(todo_tool.parse(arena_state.allocator(), call.arguments));
    try self.persistTodos();

    const text = try todo_tool.summary(self.allocator, &self.todos);
    call.settle(.ok, tool.monotonicMilliseconds(self.io));
    if (call.result) |old| self.allocator.free(old);
    call.result = text;
    call.result_bytes = text.len;
    try self.persistToolCall(message_index, i);
}

/// Where the message being decided currently sits, or null when there is no
/// decision outstanding - or when that message has been trimmed out from under
/// it, which `Conversation.trim` is written to avoid.
fn pendingIndex(self: *const Loop) ?usize {
    const seq = self.pending_seq orelse return null;
    for (self.conversation.messages.items, 0..) |msg, i| {
        if (msg.seq == seq) return i;
    }
    return null;
}

/// Index of the next call still waiting on the user.
pub fn firstPending(self: *Loop) ?usize {
    const message_index = self.pendingIndex() orelse return null;
    const calls = self.conversation.messages.items[message_index].tool_calls;
    for (calls, 0..) |call, i| {
        if (call.status == .pending) return i;
    }
    return null;
}

/// The call the approval prompt is currently asking about.
pub fn pendingCall(self: *Loop) ?*Conversation.ToolCall {
    const message_index = self.pendingIndex() orelse return null;
    const index = self.firstPending() orelse return null;
    return &self.conversation.messages.items[message_index].tool_calls[index];
}

/// The answer to a call waiting on a decision. `always` says how far the
/// allowance it leaves behind reaches.
pub const Decision = union(enum) { once, always: permission.Breadth, deny };

/// What "allow always" would store for a call at one breadth.
pub const Proposal = struct {
    breadth: permission.Breadth,
    patterns: []const []const u8,
};

/// Record the user's answer for the call currently being asked about.
pub fn decide(self: *Loop, decision: Decision) !void {
    const call = self.pendingCall() orelse return;
    const message_index = self.pendingIndex() orelse return;
    const call_index = self.firstPending() orelse return;

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(call.prepared_action orelse "", &hash, .{});
    const receipt = try std.json.Stringify.valueAlloc(self.allocator, .{
        .kind = "human_tool_decision",
        .decision = std.meta.activeTag(decision),
        .breadth = if (decision == .always) @tagName(decision.always) else "",
        .action_hash = std.fmt.bytesToHex(hash, .lower),
    }, .{});
    defer self.allocator.free(receipt);

    switch (decision) {
        .once => try self.approve(call),
        .always => |breadth| {
            try self.approve(call);
            if (call.status == .running) try self.allow(call, breadth);
        },
        .deny => {
            call.status = .rejected;
            call.result = try self.allocator.dupe(u8, "denied by the user");
            call.result_bytes = "denied by the user".len;
            try self.persistToolCall(message_index, call_index);
        },
    }

    if (decision == .deny or call.status == .running) try self.recordHuman(receipt, true);
    if (call.status == .rejected) try self.persistToolCall(message_index, call_index);
    if (decision == .always and call.status == .running) try self.autoApproveRemaining(message_index);

    if (self.firstPending() != null) return;
    try self.runApproved();
}

/// Mark every still-pending call in `message_index` as approved when the
/// allowance list or a read-only tool definition covers it. Used after a
/// decision that may have changed the answer for calls beyond the first.
fn autoApproveRemaining(self: *Loop, message_index: usize) !void {
    const calls = self.conversation.messages.items[message_index].tool_calls;
    for (calls) |*call| {
        if (call.status != .pending) continue;
        if (self.needsNoDecision(call)) try self.approve(call);
    }
}

/// Turn down a call the current agent has no business making. The model was
/// not told this tool exists, so this is a hallucinated name or a stale schema;
/// either way it comes back as a result it can read rather than a prompt the
/// user has to answer.
fn refuse(self: *Loop, message_index: usize, call_index: usize) !void {
    const call = &self.conversation.messages.items[message_index].tool_calls[call_index];
    const reason = try std.fmt.allocPrint(
        self.allocator,
        "{s} is not available in {s} mode",
        .{ call.name, self.agent.label },
    );
    call.status = .rejected;
    call.result = reason;
    call.result_bytes = reason.len;
    try self.persistToolCall(message_index, call_index);
}

/// Whether this call can run without stopping for the user: a tool that only
/// reads, a shell command the preset safe list covers, or something the user
/// has already said always to allow.
fn needsNoDecision(self: *const Loop, call: *const Conversation.ToolCall) bool {
    if (!self.agent.allows(call.name)) return false;
    if (self.hookRequiresApproval(call)) return false;
    if (self.approvals == .all) return true;

    if (self.outsidePath(self.allocator, call) catch null) |path| {
        defer self.allocator.free(path);
        return self.coversExactly(call.name, path);
    }

    const definition = self.registry.get(call.name) orelse return false;
    if (definition.read_only) return true;
    if (self.isSafe(call)) return true;
    return self.isAllowed(call);
}

fn hookRequiresApproval(self: *const Loop, call: *const Conversation.ToolCall) bool {
    if (self.registry.get(call.name)) |definition| if (!definition.read_only) {
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        const input = std.json.parseFromSliceLeaky(std.json.Value, arena, call.arguments, .{}) catch return true;
        if (input == .object) {
            for ([_][]const u8{ "path", "file" }) |field| {
                if (input.object.get(field)) |target| {
                    if (target != .string) continue;
                    if (permission.protectedPath(arena, self.io, self.project_root, target.string, self.control_files, if (self.hooks) |runner| runner.set else .{}) catch true) return true;
                }
            }
        }
    };
    for (self.hook_flow.asks.items) |id| if (std.mem.eql(u8, call.id, id)) return true;
    return false;
}

/// Whether a call cleared to run may resolve paths outside the project: one
/// the user was asked about, one naming such a path, which running means was
/// cleared, or any call when approvals are `all`.
fn mayReachOutside(self: *const Loop, call: *const Conversation.ToolCall) bool {
    return self.approvals == .all or self.escapesProject(call) or !self.needsNoDecision(call);
}

/// Whether a call names a path outside the project.
///
/// Such a call never skips the guard, whatever the tool says about being
/// read-only: reading `~/.ssh/id_rsa` is not made safe by `read` being a
/// read-only tool. Anything unparseable counts as escaping, so a malformed
/// argument is asked about rather than waved through.
fn escapesProject(self: *const Loop, call: *const Conversation.ToolCall) bool {
    if (call.arguments.len > 0 and !isObject(self.allocator, call.arguments)) return true;
    const outside = self.outsidePath(self.allocator, call) catch return true;
    if (outside) |path| {
        self.allocator.free(path);
        return true;
    }
    return false;
}

fn isObject(allocator: std.mem.Allocator, text: []const u8) bool {
    var scratch: std.heap.ArenaAllocator = .init(allocator);
    defer scratch.deinit();
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, scratch.allocator(), text, .{}) catch return false;
    return parsed == .object;
}

/// The path this call names that lies outside the project, resolved so that an
/// allowance on `/tmp/notes.md` cannot be spent on `/tmp/../etc/passwd`. Null
/// when the call stays inside, or names no path at all.
fn outsidePath(
    self: *const Loop,
    allocator: std.mem.Allocator,
    call: *const Conversation.ToolCall,
) !?[]u8 {
    if (call.arguments.len == 0) return null;

    var scratch: std.heap.ArenaAllocator = .init(self.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, call.arguments, .{}) catch return null;
    const fields = switch (parsed) {
        .object => |object| object,
        else => return null,
    };

    for ([_][]const u8{ "path", "file" }) |name| {
        const value = fields.get(name) orelse continue;
        if (value != .string) continue;
        if (value.string.len == 0) continue;

        const resolved = self.resolveAgainstProject(arena, value.string) orelse
            return try allocator.dupe(u8, value.string);
        if (!self.inside(arena, resolved)) return try allocator.dupe(u8, resolved);
    }
    return null;
}

fn resolveAgainstProject(self: *const Loop, arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const joined = if (std.fs.path.isAbsolute(path))
        arena.dupe(u8, path) catch return null
    else
        std.fs.path.join(arena, &.{ self.workingDirectory(), path }) catch return null;

    const lexical = std.fs.path.resolve(arena, &.{joined}) catch return null;
    return self.followLinks(arena, lexical);
}

/// `lexical` with the links in the part of it that exists followed, since the
/// OS follows them when the call runs: `link/x` under a project is outside it
/// when `link` points out. Null when that cannot be told, a dangling link
/// included.
fn followLinks(self: *const Loop, arena: std.mem.Allocator, lexical: []const u8) ?[]const u8 {
    return paths.resolve(self.io, arena, self.workingDirectory(), lexical) catch null;
}

fn inside(self: *const Loop, arena: std.mem.Allocator, resolved: []const u8) bool {
    for ([_][]const u8{self.project_root}) |root| {
        const reference = self.followLinks(arena, root) orelse return false;
        if (pathInside(reference, resolved)) return true;
    }
    for (self.additional_roots.items) |root| if (pathInside(root, resolved)) return true;
    return false;
}

const pathInside = paths.inside;

/// Whether the preset list of read-only commands covers this call. Only `bash`
/// has commands to classify; every other tool is settled by `read_only`.
fn isSafe(self: *const Loop, call: *const Conversation.ToolCall) bool {
    if (!self.auto_approve_safe) return false;
    if (!std.mem.eql(u8, call.name, "bash")) return false;

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, arena, call.arguments, .{}) catch return false;
    if (parsed.value != .object) return false;
    const command = jsonString(parsed.value.object, "command") orelse return false;

    return safety.verdict(arena, command) == .safe;
}

/// Truncate tool output destined for the model, keeping the head and marking
/// what was dropped so it does not look like the tool simply stopped.
fn trimForModel(self: *Loop, name: []const u8, result: []const u8) ![]const u8 {
    const ceiling = self.resultCeiling(name);
    if (result.len <= ceiling) return result;

    var cut = ceiling;
    if (std.mem.lastIndexOfScalar(u8, result[0..cut], '\n')) |newline| cut = newline;

    return std.fmt.allocPrint(
        self.allocator,
        "{s}\n... truncated, {d} more bytes not shown",
        .{ result[0..cut], result.len - cut },
    );
}

/// How much of one tool's output the model may see. A tool that says nothing
/// takes `max_tool_result_bytes`.
fn resultCeiling(self: *const Loop, name: []const u8) usize {
    const found = self.registry.get(name) orelse return max_tool_result_bytes;
    return found.max_result_bytes orelse max_tool_result_bytes;
}

/// Record an "allow always" for what this call is doing, and persist it.
fn allow(self: *Loop, call: *const Conversation.ToolCall, breadth: permission.Breadth) !void {
    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();

    for (try self.allowancesFor(arena_state.allocator(), call, breadth)) |pattern| {
        try self.remember(call.name, pattern);
        if (self.db) |db| {
            if (self.project_id) |project_id| {
                try db.addApproval(project_id, call.name, pattern);
            }
        }
    }
}

/// Hold an allowance in memory, without touching the database.
fn remember(self: *Loop, name: []const u8, pattern: []const u8) !void {
    for (self.allowed.items) |allowance| {
        if (std.mem.eql(u8, allowance.tool, name) and
            std.mem.eql(u8, allowance.pattern, pattern)) return;
    }

    const name_copy = try self.allocator.dupe(u8, name);
    errdefer self.allocator.free(name_copy);
    try self.allowed.append(self.allocator, .{
        .tool = name_copy,
        .pattern = try self.allocator.dupe(u8, pattern),
    });
}

/// What "allow always" could store for `call`, narrowest first, each reaching
/// further than the one before.
pub fn proposals(self: *const Loop, arena: std.mem.Allocator, call: *const Conversation.ToolCall) ![]const Proposal {
    var out: std.ArrayList(Proposal) = .empty;
    for (std.enums.values(permission.Breadth)) |breadth| {
        const patterns = try self.allowancesFor(arena, call, breadth);
        if (out.items.len > 0 and samePatterns(out.getLast().patterns, patterns)) continue;
        try out.append(arena, .{ .breadth = breadth, .patterns = patterns });
    }
    return out.items;
}

/// The allowances an "allow always" at `breadth` stores for `call`: the path
/// of one reaching outside the project, a pattern for each command of a shell
/// line that is neither safe nor already allowed, or `*`. A line the splitter
/// will not vouch for is only ever allowed as written.
fn allowancesFor(
    self: *const Loop,
    arena: std.mem.Allocator,
    call: *const Conversation.ToolCall,
    breadth: permission.Breadth,
) ![]const []const u8 {
    if (try self.outsidePath(arena, call)) |path| return onePattern(arena, path);
    if (!std.mem.eql(u8, call.name, "bash")) return onePattern(arena, "*");

    const command = shellCommand(arena, call.arguments);
    const parts = try safety.segments(arena, command) orelse return onePattern(arena, command);
    if (parts.len == 0) return onePattern(arena, command);

    var out: std.ArrayList([]const u8) = .empty;
    next: for (parts) |part| {
        if (self.segmentAllowed(part)) continue;
        const pattern = try permission.pattern(arena, part, breadth);
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing, pattern)) continue :next;
        }
        try out.append(arena, pattern);
    }
    return out.items;
}

fn onePattern(arena: std.mem.Allocator, pattern: []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, 1);
    out[0] = try arena.dupe(u8, pattern);
    return out;
}

fn samePatterns(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

/// The command a `bash` call runs, trimmed, or its raw arguments when they
/// name none.
fn shellCommand(arena: std.mem.Allocator, arguments: []const u8) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments, .{}) catch
        return std.mem.trim(u8, arguments, " \t\r\n");
    if (parsed != .object) return std.mem.trim(u8, arguments, " \t\r\n");
    const command = jsonString(parsed.object, "command") orelse return std.mem.trim(u8, arguments, " \t\r\n");
    return std.mem.trim(u8, command, " \t\r\n");
}

fn jsonString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn isAllowed(self: *const Loop, call: *const Conversation.ToolCall) bool {
    if (!std.mem.eql(u8, call.name, "bash")) return self.coversExactly(call.name, "*");

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const command = shellCommand(arena, call.arguments);
    const parts = (safety.segments(arena, command) catch null) orelse &.{};
    if (parts.len == 0) return self.coversExactly("bash", command) or (self.approvals != .auto and self.coversExactly("bash", "*"));
    for (parts) |part| {
        if (!self.segmentAllowed(part)) return false;
    }
    return true;
}

/// Whether one command of a shell line may run: it is on the safe list, or an
/// allowance covers it.
fn segmentAllowed(self: *const Loop, part: safety.Segment) bool {
    if (self.auto_approve_safe and safety.isSafeSegment(part)) return true;
    for (self.allowed.items) |allowance| {
        if (!std.mem.eql(u8, allowance.tool, "bash")) continue;
        if (self.approvals == .auto and permission.runsAnything(allowance.pattern)) continue;
        if (permission.covers(allowance.pattern, part)) return true;
    }
    return false;
}

/// Whether an allowance names this pattern outright, ignoring `*`.
fn coversExactly(self: *const Loop, name: []const u8, pattern: []const u8) bool {
    for (self.allowed.items) |allowance| {
        if (!std.mem.eql(u8, allowance.tool, name)) continue;
        if (std.mem.eql(u8, allowance.pattern, pattern)) return true;
    }
    return false;
}

/// Persist the message at `index` (the most recently appended one) and its
/// tool calls and reasoning blob. No-op when no database is attached.
fn persistMessage(self: *Loop, index: usize) !void {
    const db = self.db orelse return;
    const session_id = try self.ensureSession();

    const msg = &self.conversation.messages.items[index];
    const role = @tagName(msg.role);
    const thinking_ms: ?i64 = if (msg.thinking_ms) |ms| @intCast(ms) else null;
    const thinking_bytes: i64 = @intCast(msg.thinking_bytes);

    const message_id = try db.appendMessage(
        session_id,
        @intCast(msg.seq),
        role,
        msg.text,
        thinking_ms,
        thinking_bytes,
        .of(msg.*),
    );
    try db.setMessageOrigin(message_id, msg.origin);
    try self.message_ids.put(self.allocator, msg.seq, message_id);

    if (msg.thinking) |thinking| {
        if (thinking.len > 0) {
            try db.appendBlob(message_id, 0, "reasoning", thinking);
            self.shrinkThinking(msg);
        }
    }

    if (msg.provider_state) |state| {
        try db.appendBlob(message_id, 0, Database.provider_state_blob, state);
    }

    for (msg.attachments, 0..) |attachment, i| {
        try db.appendAttachment(message_id, @intCast(i), attachment.path, attachment.content);
    }

    for (msg.images, 0..) |image, i| {
        try db.appendBlob(message_id, @intCast(i), "image", image);
    }
    self.conversation.dropOldImages(max_resident_images);
    self.conversation.shrinkAttachments(max_resident_attachment_bytes);

    for (msg.tool_calls, 0..) |call, i| {
        _ = try db.appendToolCall(
            message_id,
            @intCast(i),
            call.id,
            call.name,
            call.arguments,
            @tagName(call.status),
            call.result,
            @intCast(call.result_bytes),
            if (call.elapsed_ms) |ms| @intCast(ms) else null,
        );
    }
}

/// Say something the UI will surface once. Replaces whatever was pending.
pub fn say(self: *Loop, comptime fmt: []const u8, args: anytype) void {
    const said = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
    if (self.hook_flow.notice) |old| self.allocator.free(old);
    self.hook_flow.notice = said;
    self.notifyHook("notice", said);
}

/// Write a subagent's messages into a session of its own, hung off the call
/// that produced it. Read back by whatever reads any other session.
pub fn storeSubagent(self: *Loop, call_index: usize, convo: *Conversation) !void {
    const message_index = self.pendingIndex() orelse return;
    return self.persistSubagent(message_index, call_index, convo);
}

fn persistSubagent(
    self: *Loop,
    message_index: usize,
    call_index: usize,
    convo: *Conversation,
) !void {
    const db = self.db orelse return;
    const project_id = self.project_id orelse return;
    const parent_session = self.session_id orelse return;
    if (convo.messages.items.len == 0) return;

    const msg = &self.conversation.messages.items[message_index];
    const parent_message = self.message_ids.get(msg.seq) orelse return;
    const call_row = try db.toolCallId(parent_message, @intCast(call_index)) orelse return;

    const session = try db.createSubagentSession(
        project_id,
        self.session_cwd,
        self.session_model,
        parent_session,
        call_row,
    );

    for (convo.messages.items) |child| {
        const thinking_bytes: i64 = if (child.thinking) |t| @intCast(t.len) else 0;
        const message_id = try db.appendMessage(
            session,
            @intCast(child.seq),
            @tagName(child.role),
            child.text,
            if (child.thinking_ms) |ms| @intCast(ms) else null,
            thinking_bytes,
            .of(child),
        );
        try db.setMessageOrigin(message_id, child.origin);
        if (child.thinking) |thinking| {
            try db.appendBlob(message_id, 0, "reasoning", thinking);
        }
        for (child.tool_calls, 0..) |call, i| {
            _ = try db.appendToolCall(
                message_id,
                @intCast(i),
                call.id,
                call.name,
                call.arguments,
                @tagName(call.status),
                call.result,
                @intCast(call.result_bytes),
                if (call.elapsed_ms) |ms| @intCast(ms) else null,
            );
        }
    }
}

/// Persist a tool call's settled status and result. No-op without a database.
fn persistToolCall(self: *Loop, message_index: usize, call_index: usize) !void {
    const db = self.db orelse return;
    const msg = &self.conversation.messages.items[message_index];
    const message_id = self.message_ids.get(msg.seq) orelse return;

    const call = &msg.tool_calls[call_index];

    if (call.result) |result| {
        if (result.len > Conversation.preview_bytes) {
            try db.appendBlob(message_id, @intCast(call_index), "tool_result", result);
        }
    }

    try db.updateToolCall(
        message_id,
        @intCast(call_index),
        @tagName(call.status),
        call.arguments,
        call.result,
        @intCast(call.result_bytes),
        if (call.elapsed_ms) |ms| @intCast(ms) else null,
    );
    if (call.approved_action) |snapshot| try db.appendBlob(message_id, @intCast(call_index), "approved_action", snapshot);
    self.shrinkResult(call);
}

/// Replace a message's reasoning with a preview, freeing the full copy. The
/// full text is already in the blob table.
fn shrinkThinking(self: *Loop, msg: *Conversation.Message) void {
    const thinking = msg.thinking orelse return;
    if (thinking.len <= Conversation.preview_bytes) return;
    const preview = Conversation.preview(self.allocator, thinking) catch return;
    self.allocator.free(thinking);
    msg.thinking = preview;
}

/// Replace a tool call's result with a preview, freeing the full copy. The full
/// text is already in the blob table.
fn shrinkResult(self: *Loop, call: *Conversation.ToolCall) void {
    const result = call.result orelse return;
    if (result.len <= Conversation.preview_bytes) return;
    const preview = Conversation.preview(self.allocator, result) catch return;
    self.allocator.free(result);
    call.result = preview;
}

/// Flush the read log to the `read_file` table. No-op without a database.
fn persistReads(self: *Loop) !void {
    const db = self.db orelse return;
    const session_id = try self.ensureSession();

    var it = self.reads.iterator();
    while (it.next()) |entry| {
        try db.recordRead(session_id, entry.key_ptr.*, @intCast(entry.value_ptr.*));
    }
}

/// Largest file a checkpoint keeps. Past this a turn's change to it cannot be
/// undone, which beats copying a huge file on every edit.
const max_checkpoint_bytes = 8 * 1024 * 1024;

/// Keep what every file a `write` or `edit` in `batch` is about to change
/// holds now, under the prompt that began the turn, so the turn can be undone.
fn checkpointBatch(self: *Loop, batch: []const ToolRun.Call) !void {
    const owner = self.parent orelse self;
    const db = owner.db orelse return;
    const seq = owner.turn_start_seq orelse return;

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (batch) |call| {
        if (!std.mem.eql(u8, call.name, "write") and !std.mem.eql(u8, call.name, "edit")) continue;
        const path = self.changedPath(arena, call.arguments) orelse continue;
        const content = readCheckpointed(self.io, arena, path) catch |err| {
            self.say("Could not checkpoint {s}, so /rewind cannot put it back: {s}", .{ path, @errorName(err) });
            continue;
        };
        try db.saveCheckpoint(try owner.ensureSession(), seq, path, content);
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        try self.checkpointed.append(self.allocator, owned);
    }
}

/// Record what the batch left in each file it checkpointed, so a rewind can
/// tell when someone changed one since.
fn sealCheckpoints(self: *Loop) void {
    defer {
        for (self.checkpointed.items) |path| self.allocator.free(path);
        self.checkpointed.clearRetainingCapacity();
    }
    const owner = self.parent orelse self;
    const db = owner.db orelse return;
    const seq = owner.turn_start_seq orelse return;
    const session_id = owner.session_id orelse return;

    var arena_state: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena_state.deinit();
    for (self.checkpointed.items) |path| {
        const content = (readCheckpointed(self.io, arena_state.allocator(), path) catch continue) orelse continue;
        db.sealCheckpoint(session_id, seq, path, std.hash.Wyhash.hash(0, content)) catch |err| {
            self.say("Could not checkpoint {s}: {s}", .{ path, @errorName(err) });
        };
    }
}

/// The absolute path a file-changing call names, or null when it names none.
fn changedPath(self: *const Loop, arena: std.mem.Allocator, arguments: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, arguments, .{}) catch return null;
    if (parsed != .object) return null;
    const path = jsonString(parsed.object, "path") orelse return null;
    if (path.len == 0) return null;
    return self.resolveAgainstProject(arena, path);
}

/// What `path` holds, or null when it does not exist.
fn readCheckpointed(io: std.Io, arena: std.mem.Allocator, path: []const u8) !?[]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_checkpoint_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// A file a rewind puts back.
pub const Rewound = struct {
    path: []const u8,
    /// It did not exist before, so going back removes it.
    removed: bool,
    /// Something other than synth's tools changed it after they did, and
    /// putting it back loses that.
    changed: bool,
};

/// The session's turns that changed files, oldest first. Allocated in
/// `arena`.
pub fn checkpointTurns(self: *Loop, arena: std.mem.Allocator) ![]Database.CheckpointTurn {
    const db = self.db orelse return &.{};
    const session_id = self.session_id orelse return &.{};
    return db.checkpointTurns(session_id, arena);
}

/// Put every file the turns from `seq` on changed back the way it was before
/// them, or with `apply` false, only say what that would do. Allocated in
/// `arena`.
pub fn rewind(self: *Loop, arena: std.mem.Allocator, seq: u64, apply: bool) ![]Rewound {
    if (apply and self.isBusy()) return error.Busy;
    const db = self.db orelse return &.{};
    const session_id = self.session_id orelse return &.{};

    const restores = try db.checkpointsFrom(session_id, seq, arena);
    const out = try arena.alloc(Rewound, restores.len);
    for (restores, out) |restore, *rewound| {
        const current = readCheckpointed(self.io, arena, restore.path) catch null;
        const changed = if (restore.after_hash) |hash|
            current == null or std.hash.Wyhash.hash(0, current.?) != hash
        else
            false;
        rewound.* = .{ .path = restore.path, .removed = restore.content == null, .changed = changed };
        if (!apply) continue;

        if (restore.content) |content| {
            if (std.fs.path.dirname(restore.path)) |parent| std.Io.Dir.cwd().createDirPath(self.io, parent) catch {};
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = restore.path, .data = content });
        } else {
            std.Io.Dir.cwd().deleteFile(self.io, restore.path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
        }
    }
    if (apply) try db.dropCheckpointsFrom(session_id, seq);
    return out;
}

/// Hand every approved call to a worker. Denials skip straight to their result.
fn runApproved(self: *Loop) !void {
    const message_index = self.pendingIndex() orelse return;
    const calls = self.conversation.messages.items[message_index].tool_calls;
    for (calls, 0..) |*call, i| {
        if (call.status != .running) continue;
        const current = self.action(call) catch null;
        defer if (current) |value| self.allocator.free(value);
        if (current == null or call.approved_action == null or !std.mem.eql(u8, current.?, call.approved_action.?)) {
            call.settle(.rejected, tool.monotonicMilliseconds(self.io));
            if (call.result) |old| self.allocator.free(old);
            call.result = try self.allocator.dupe(u8, "approved action changed before execution; propose it again");
            call.result_bytes = call.result.?.len;
        }
        try self.persistToolCall(message_index, i);
    }

    if (self.hooks) |runner| {
        const calls_for_hooks = self.conversation.messages.items[message_index].tool_calls;
        for (calls_for_hooks, 0..) |call, i| {
            if (call.status != .running) continue;
            const is_todo = std.mem.eql(u8, call.name, todo_tool.name);
            const is_ask = std.mem.eql(u8, call.name, ask_user.name);
            if (!is_todo and !is_ask) continue;
            if (is_ask and self.approved_ask_index == i) continue;
            if (is_todo) {
                if (try self.checkTodoTasks(message_index, i)) return;
                try self.applyTodo(message_index, i);
                if (runner.set.forEvent(.post_tool_use).len > 0) {
                    try self.startOwnerPost(i, calls_for_hooks[i].result.?);
                    return;
                }
            } else {
                self.approved_ask_index = i;
                self.state = .awaiting_answer;
                self.notifyHook("agent_needs_input", call.arguments);
                return;
            }
        }
    } else {
        const calls_for_todos = self.conversation.messages.items[message_index].tool_calls;
        for (calls_for_todos, 0..) |call, i| {
            if (call.status != .running) continue;
            if (std.mem.eql(u8, call.name, todo_tool.name)) try self.applyTodo(message_index, i);
        }
    }

    var roots: std.ArrayList([]const u8) = .empty;
    defer roots.deinit(self.allocator);
    try roots.append(self.allocator, self.project_root);
    try roots.appendSlice(self.allocator, self.additional_roots.items);
    const post_input = try self.exportHookInput(.{ .event = .post_tool_use });
    var batch: std.ArrayList(ToolRun.Call) = .empty;
    defer batch.deinit(self.allocator);

    for (calls, 0..) |call, i| {
        if (call.status != .running) continue;
        if (std.mem.eql(u8, call.name, todo_tool.name)) continue;
        try batch.append(self.allocator, .{
            .hook_input = blk: {
                var input = post_input;
                input.tool_call_id = call.id;
                break :blk input;
            },
            .seq = self.conversation.messages.items[message_index].seq,
            .index = i,
            .name = call.name,
            .arguments = call.arguments,
            .approved_action = call.approved_action,
            .allow_outside = self.mayReachOutside(&call),
            .additional_roots = roots.items,
        });
    }

    // A question is answered, not run. The rest of the batch waits its turn.
    if (self.firstAsk()) |question| {
        self.notifyHook("agent_needs_input", question.arguments);
        self.state = .awaiting_answer;
        return;
    }

    if (batch.items.len == 0) {
        try self.finishToolMessages();
        return;
    }

    self.checkpointBatch(batch.items) catch |err| self.say("Could not checkpoint the files this changes: {s}", .{@errorName(err)});
    self.tools_adopted = 0;
    self.tools = try ToolRun.start(
        self.allocator,
        self.io,
        self.registry,
        self.workingDirectory(),
        self.reads,
        self.delegate,
        self.handoff,
        self.hooks,
        batch.items,
    );
    self.state = .running_tools;
}

/// Copy across every result the worker has finished so far.
///
/// Called while the batch is still running, so a card settles as its call
/// lands rather than when the last one does - which is what made a run of
/// edits look stuck. Calls that ran together settle together.
///
/// `tools_adopted` is what keeps this idempotent - each result is taken once,
/// so the final pass after the worker exits cannot dupe a result twice and
/// leak the first copy.
/// The name of the call the running batch is on, for anything that wants to say
/// what is happening in a couple of words. The first unsettled one: a batch
/// runs in order, so that is the one still going.
pub fn runningToolName(self: *const Loop) ?[]const u8 {
    const tools = self.tools orelse return null;
    const at = tools.settledCount();
    if (at >= tools.calls.len) return null;
    return tools.calls[at].name;
}

/// What the call at `index` of the message `seq` is doing now, or null when it
/// is not one of the running batch or has said nothing yet.
pub fn toolNote(self: *const Loop, seq: u64, index: usize) ?[]const u8 {
    if (self.pending_seq != seq) return null;
    if (index >= self.notes.len) return null;
    const text = self.notes[index].text();
    return if (text.len == 0) null else text;
}

/// Take a copy of what every unsettled call is saying. Returns whether any of
/// them changed, which is what tells the UI to draw again.
fn refreshNotes(self: *Loop, tools: *ToolRun) !bool {
    if (self.notes.len != tools.calls.len) {
        self.allocator.free(self.notes);
        self.notes = try self.allocator.alloc(ToolRun.Note, tools.calls.len);
        @memset(self.notes, .{});
    }

    var changed = false;
    for (self.notes, 0..) |*note, at| {
        var fresh: ToolRun.Note = .{};
        tools.copyNote(at, &fresh);
        if (fresh.len == note.len and std.mem.eql(u8, fresh.text(), note.text())) continue;
        note.* = fresh;
        changed = true;
    }
    return changed;
}

fn clearNotes(self: *Loop) void {
    self.allocator.free(self.notes);
    self.notes = &.{};
}

fn adoptSettled(self: *Loop, tools: *ToolRun) !void {
    const settled = tools.settledCount();
    if (self.tools_adopted >= settled) return;

    const message_index = self.pendingIndex() orelse return;

    while (self.tools_adopted < settled) : (self.tools_adopted += 1) {
        const result = tools.results[self.tools_adopted];
        const calls = self.conversation.messages.items[message_index].tool_calls;
        if (result.index >= calls.len) continue;

        const call = &calls[result.index];
        call.settle(if (result.is_error) .failed else .ok, tool.monotonicMilliseconds(self.io));
        call.result = try redact.scrub(self.allocator, result.content);
        call.result_bytes = result.content.len;
        try self.persistToolCall(message_index, result.index);
        try self.acceptHookResult(&result.hook_result);
        if (result.hook_error) |err| self.say("PostToolUse hook failed: {s}", .{@errorName(err)});
        if (result.hook_result.blocked orelse result.hook_result.feedback) |feedback| try self.applyPostFeedback(message_index, result.index, feedback);
    }
}

fn applyPostFeedback(self: *Loop, message_index: usize, index: usize, feedback: []const u8) !void {
    const msg = &self.conversation.messages.items[message_index];
    const call = &msg.tool_calls[index];
    if (self.db) |db| {
        if (self.message_ids.get(msg.seq)) |message_id| {
            if (call.result) |original| try db.appendBlob(message_id, @intCast(index), "hook_original_tool_result", original);
        }
    }
    const replacement = try std.fmt.allocPrint(self.allocator, "Tool {s} executed. Hook feedback: {s}", .{ call.name, feedback });
    if (call.result) |old| self.allocator.free(old);
    call.result = replacement;
    call.result_bytes = replacement.len;
    try self.persistToolCall(message_index, index);
}

fn pollTools(self: *Loop) !bool {
    const tools = self.tools orelse return false;

    const moved = try self.refreshNotes(tools);
    try self.adoptSettled(tools);
    if (!tools.isFinished()) return moved;

    tools.join();
    self.tools = null;
    defer tools.destroy();

    // Anything that landed between the check above and the worker exiting.
    try self.adoptSettled(tools);
    self.clearNotes();

    try self.persistReads();
    self.sealCheckpoints();

    try self.finishToolMessages();
    return true;
}

/// Append one `.tool` message per settled call, then ask the model again with
/// the results in hand.
fn finishToolMessages(self: *Loop) !void {
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var batch: std.ArrayList(struct { tool_name: []const u8, tool_input: std.json.Value, tool_use_id: []const u8, tool_response: []const u8, status: []const u8 }) = .empty;
    if (self.hooks) |runner| {
        if (runner.set.post_tool_batch.len > 0) {
            if (self.pendingIndex()) |index| {
                for (self.conversation.messages.items[index].tool_calls) |call| {
                    const original = call.result orelse "";
                    const trimmed = try self.trimForModel(call.name, original);
                    defer if (trimmed.ptr != original.ptr) self.allocator.free(trimmed);
                    try batch.append(a, .{ .tool_name = call.name, .tool_input = std.json.parseFromSliceLeaky(std.json.Value, a, call.arguments, .{}) catch .null, .tool_use_id = call.id, .tool_response = try a.dupe(u8, trimmed), .status = @tagName(call.status) });
                }
            }
        }
    }
    const payload = try std.json.Stringify.valueAlloc(a, batch.items, .{});
    try self.appendToolResults();
    if (self.hooks) |runner| {
        if (runner.set.post_tool_batch.len > 0) {
            self.hook_flow.dispatch = try self.dispatchHook(.{ .event = .post_tool_batch, .tool_calls = payload });
            self.hook_flow.pending = .{ .lifecycle = .ask_model };
            self.state = .running_hooks;
            return;
        }
    }
    try self.ask();
}

/// Keep the wire history complete even when a turn ends without another request.
fn appendToolResults(self: *Loop) !void {
    const message_index = self.pendingIndex() orelse return;

    const calls = self.conversation.messages.items[message_index].tool_calls;
    const settled = try self.allocator.alloc(struct {
        name: []const u8,
        id: []const u8,
        result: []const u8,
    }, calls.len);
    defer self.allocator.free(settled);

    var count: usize = 0;
    for (calls) |call| {
        if (!call.status.isSettled()) continue;
        settled[count] = .{
            .name = call.name,
            .id = call.id,
            .result = call.result orelse "",
        };
        count += 1;
    }

    for (settled[0..count]) |entry| {
        const trimmed = try self.trimForModel(entry.name, entry.result);
        defer if (trimmed.ptr != entry.result.ptr) self.allocator.free(trimmed);
        _ = try self.conversation.addToolResult(entry.name, entry.id, trimmed);
        try self.persistMessage(self.conversation.messages.items.len - 1);
    }

    self.pending_seq = null;
    self.pending_index = 0;
}

fn isRunningWithoutLimit(self: *const Loop) bool {
    return self.max_stall_ms == 0 and self.max_turn_ms == 0 and self.max_turn_tokens == 0;
}

/// A provider that asks for `list` on its first turn and answers on its
/// second, so the whole approve/execute/resume path is exercisable with no
/// model attached.
const FakeProvider = struct {
    io: std.Io,
    /// Stands in for model latency. Slept in one go, and a cancellation point,
    /// so the cancel test has something real to interrupt.
    latency: std.Io.Duration = .fromMilliseconds(0),
    /// Number of identical calls to emit on the first turn. Default 1.
    parallel_calls: usize = 1,
    /// The tool those calls name.
    tool_name: []const u8 = "list",
    /// The arguments those calls carry.
    tool_arguments: []const u8 = "{\"path\":\".\"}",
    /// Ask for the same tool forever, the way a stuck model does.
    loop_forever: bool = false,
    /// Reported prompt tokens, for the tests that care what a turn spends.
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    /// Spend `latency` in a busy loop rather than a sleep, so the worker is
    /// deaf to both the stop flag and the signal. Stands in for a provider
    /// blocked inside a socket read, which is the only case where cancelling
    /// costs real time.
    deaf: bool = false,
    /// What it answers when asked to judge a call, at each stage, and how
    /// often it has been.
    quick: []const u8 = "ALLOW",
    careful: []const u8 = "VERDICT: ALLOW",
    judged: usize = 0,

    fn provider(self: *FakeProvider) Provider {
        return .{ .name = "fake", .userdata = self, .respond = respond };
    }

    fn respond(
        ptr: *anyopaque,
        convo: *Conversation,
        asked: Provider.Turn,
        allocator: std.mem.Allocator,
        sink: ?Provider.Sink,
    ) !Provider.Reply {
        const self: *FakeProvider = @ptrCast(@alignCast(ptr));

        if (self.deaf) {
            const until = tool.monotonicMilliseconds(self.io) + @as(i64, @intCast(@divTrunc(self.latency.nanoseconds, std.time.ns_per_ms)));
            while (tool.monotonicMilliseconds(self.io) < until) {}
        } else {
            try std.Io.sleep(self.io, self.latency, .real);
        }
        if (sink) |s| {
            if (s.stopped(s.userdata)) return .{};
            s.onThinking(s.userdata, "thinking about it\n");
        }

        if (std.mem.eql(u8, asked.system, classifier.system_prompt)) {
            self.judged += 1;
            const quick = std.mem.eql(u8, asked.instruction, classifier.instruction(.quick));
            return .{ .text = try allocator.dupe(u8, if (quick) self.quick else self.careful) };
        }

        // A one-off instruction is a question, not a turn.
        if (asked.instruction.len > 0) {
            return .{
                .text = try std.fmt.allocPrint(allocator, "answered: {s}", .{asked.instruction}),
                .usage = .{ .prompt_tokens = self.prompt_tokens, .completion_tokens = self.completion_tokens },
            };
        }

        const last = convo.last();
        const answering_tool = last != null and last.?.role == .tool;
        if (!answering_tool or self.loop_forever) {
            const n = if (self.parallel_calls == 0) 1 else self.parallel_calls;
            const calls = try allocator.alloc(Conversation.ToolCall, n);
            errdefer allocator.free(calls);
            for (calls, 0..) |*call, i| {
                call.* = .{
                    .id = try std.fmt.allocPrint(allocator, "fake-{d}", .{i + 1}),
                    .name = try allocator.dupe(u8, self.tool_name),
                    .arguments = try allocator.dupe(u8, self.tool_arguments),
                };
            }
            return .{
                .text = try allocator.dupe(u8, "Let me look at the project."),
                .tool_calls = calls,
                .usage = .{ .prompt_tokens = self.prompt_tokens, .completion_tokens = self.completion_tokens },
            };
        }

        const question = if (convo.last()) |msg| msg.text else "";
        return .{
            .text = try std.fmt.allocPrint(allocator, "answered: {s}", .{question}),
            .usage = .{ .prompt_tokens = self.prompt_tokens, .completion_tokens = self.completion_tokens },
        };
    }
};

/// The last thing the model said. A finished turn ends with the harness's own
/// summary, so the reply before it is what a test about the reply wants.
fn lastAssistant(convo: *Conversation) ?Conversation.Message {
    var i = convo.messages.items.len;
    while (i > 0) {
        i -= 1;
        if (convo.messages.items[i].role == .assistant) return convo.messages.items[i];
    }
    return null;
}

/// Drive the loop to a stopping point: idle, or waiting on the user. Polls on
/// a short sleep rather than spinning, since the work is on another thread.
fn settle(self: *Loop) !void {
    var waited_ms: usize = 0;
    while (self.isBusy() and self.state != .awaiting_approval and self.state != .awaiting_answer) {
        _ = try self.poll();
        if (!self.isBusy() or self.state == .awaiting_approval or self.state == .awaiting_answer) break;
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .real);
        waited_ms += 1;
        if (waited_ms > 5_000) return error.LoopDidNotSettle;
    }
}

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    convo: Conversation,
    registry: Registry,
    reads: tool.ReadLog,
    fake: FakeProvider,

    fn init() !*Fixture {
        const self = try testing.allocator.create(Fixture);
        var tmp = testing.tmpDir(.{});
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(testing.io, &buf);

        self.* = .{
            .tmp = tmp,
            .root = try testing.allocator.dupe(u8, buf[0..n]),
            .convo = .init(testing.allocator),
            .registry = try Registry.init(testing.allocator),
            .reads = .init(testing.allocator),
            .fake = .{ .io = testing.io },
        };
        return self;
    }

    fn deinit(self: *Fixture) void {
        self.reads.deinit();
        self.registry.deinit();
        self.convo.deinit();
        testing.allocator.free(self.root);
        self.tmp.cleanup();
        testing.allocator.destroy(self);
    }

    fn loop(self: *Fixture) Loop {
        return .init(
            testing.allocator,
            testing.io,
            self.fake.provider(),
            &self.registry,
            &self.convo,
            &self.reads,
            self.root,
        );
    }
};

test "a blocked prompt never enters the model transcript" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    const hook = Hooks.Hook{ .command = "echo prompt rejected >&2; exit 2" };
    var runner: Hooks.Runner = .{
        .io = testing.io,
        .root = fixture.root,
        .set = .{ .user_prompt_submit = &.{hook} },
    };
    loop.hooks = &runner;

    try loop.submit("do not send this", .{});
    try testing.expectEqual(State.running_hooks, loop.state);
    try settle(&loop);

    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqual(@as(usize, 0), fixture.convo.messages.items.len);
    const notice = loop.takeHookNotice().?;
    defer testing.allocator.free(notice);
    try testing.expectEqualStrings("prompt rejected", notice);
}

test "a rejected steering prompt never enters the transcript" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    const hook = Hooks.Hook{ .command = "read payload; case \"$payload\" in *rejected*) echo steering denied >&2; exit 2;; esac" };
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .user_prompt_submit = &.{hook} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expectEqual(State.idle, loop.state);
    fixture.fake.latency = .fromMilliseconds(80);
    try loop.submit("again", .{});
    try testing.expect(try loop.steer("rejected", .{}));
    try settle(&loop);
    for (fixture.convo.messages.items) |msg| {
        try testing.expect(!std.mem.eql(u8, msg.text, "rejected"));
    }
    const notice = loop.takeHookNotice() orelse return error.TestExpectedNotice;
    defer testing.allocator.free(notice);
    try testing.expectEqualStrings("steering denied", notice);
}

test "a read-only tool call runs without asking" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("what is here?", .{});
    try settle(&loop);

    try testing.expectEqual(State.idle, loop.state);

    const calls = fixture.convo.messages.items[1].tool_calls;
    try testing.expectEqual(@as(usize, 1), calls.len);
    try testing.expectEqual(Conversation.ToolCall.Status.ok, calls[0].status);

    // Prompt, call, result, reply, and the summary written once the turn ends.
    try testing.expectEqual(@as(usize, 5), fixture.convo.messages.items.len);
    try testing.expectEqual(Conversation.Role.tool, fixture.convo.messages.items[2].role);
    try testing.expectEqual(Conversation.Role.summary, fixture.convo.last().?.role);
}

test "a mutating tool call stops for approval" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.registry.tools.getPtr("list").?.read_only = false;

    try loop.submit("go", .{});
    try settle(&loop);

    try testing.expectEqual(State.awaiting_approval, loop.state);
    try testing.expect(loop.pendingCall() != null);
    try testing.expect(fixture.convo.hasPendingToolCalls());
}

test "denial still reports back to the model" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.registry.tools.getPtr("list").?.read_only = false;

    try loop.submit("go", .{});
    try settle(&loop);
    try loop.decide(.deny);
    try settle(&loop);

    const calls = fixture.convo.messages.items[1].tool_calls;
    try testing.expectEqual(Conversation.ToolCall.Status.rejected, calls[0].status);

    try testing.expectEqual(Conversation.Role.tool, fixture.convo.messages.items[2].role);
    try testing.expect(std.mem.indexOf(u8, fixture.convo.messages.items[2].text, "denied") != null);
    try testing.expectEqual(State.idle, loop.state);
}

test "allow always skips the prompt next time" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.registry.tools.getPtr("list").?.read_only = false;

    try loop.submit("first", .{});
    try settle(&loop);
    try loop.decide(.{ .always = .subcommand });
    try settle(&loop);
    try testing.expectEqual(State.idle, loop.state);

    try loop.submit("second", .{});
    try settle(&loop);

    try testing.expectEqual(State.idle, loop.state);
    const same: Conversation.ToolCall = .{ .id = "", .name = "list", .arguments = "{\"path\":\".\"}" };
    try testing.expect(loop.isAllowed(&same));
    const elsewhere: Conversation.ToolCall = .{ .id = "", .name = "list", .arguments = "{\"path\":\"docs\"}" };
    try testing.expect(loop.isAllowed(&elsewhere));
}

test "allow always covers the rest of a same-message batch" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.registry.tools.getPtr("list").?.read_only = false;
    fixture.fake.parallel_calls = 3;

    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expectEqual(State.awaiting_approval, loop.state);

    try loop.decide(.{ .always = .subcommand });
    try settle(&loop);
    try testing.expectEqual(State.idle, loop.state);

    const calls = fixture.convo.messages.items[1].tool_calls;
    try testing.expectEqual(@as(usize, 3), calls.len);
    for (calls) |call| {
        try testing.expectEqual(Conversation.ToolCall.Status.ok, call.status);
    }
}

test "reported reasoning usage triggers compaction and model selection invalidates it" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.fake.prompt_tokens = 500;
    fixture.fake.completion_tokens = 30000;
    var loop = fixture.loop();
    defer loop.deinit();
    fixture.registry.tools.getPtr("list").?.read_only = false;
    try loop.submit("go", .{});
    try loop.settle();
    try testing.expectEqual(State.awaiting_approval, loop.state);
    try testing.expect(loop.shouldCompact());
    try loop.cancel();
    try loop.settle();
    try loop.setModel("another-provider-model");
    try testing.expect(!loop.shouldCompact());
    try testing.expectEqual(@as(u64, 30000), loop.usage.output_tokens);
}

test "usage derives rate and context fraction" {
    const usage: Usage = .{
        .context_tokens = 8_192,
        .output_tokens = 500,
        .eval_duration_ns = 10 * std.time.ns_per_s,
    };

    try testing.expectApproxEqAbs(@as(f64, 50), usage.tokensPerSecond().?, 0.001);
    try testing.expectApproxEqAbs(@as(f64, 0.25), usage.contextFraction(32_768).?, 0.001);

    try testing.expect(usage.contextFraction(0) == null);
    try testing.expect((Usage{}).tokensPerSecond() == null);
}

fn leakHandler(ctx: tool.Context, _: tool.Input) anyerror!tool.Output {
    return tool.Output.ok(try ctx.allocator.dupe(
        u8,
        "AWS_SECRET_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE\n",
    ));
}

test "a secret in tool output never reaches the transcript" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.registry.register(.{
        .name = "leak",
        .description = "hands back a secret",
        .schema = "{\"type\":\"object\",\"properties\":{}}",
        .handler = leakHandler,
        .read_only = true,
        .parallel = true,
    });
    fixture.fake.tool_name = "leak";
    fixture.fake.tool_arguments = "{}";

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("show me the config", .{});
    try settle(&loop);

    const secret = "AKIAIOSFODNN7EXAMPLE";
    const call = fixture.convo.messages.items[1].tool_calls[0];
    try testing.expect(std.mem.indexOf(u8, call.result.?, secret) == null);

    const result_message = fixture.convo.messages.items[2];
    try testing.expectEqual(Conversation.Role.tool, result_message.role);
    try testing.expect(std.mem.indexOf(u8, result_message.text, secret) == null);
    try testing.expect(std.mem.indexOf(u8, result_message.text, redact.mask) != null);
    try testing.expect(std.mem.indexOf(u8, result_message.text, "AWS_SECRET_ACCESS_KEY=") != null);
}

test "a compaction settling back to idle is not a finished turn" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("go", .{});
    try settle(&loop);
    const after_turn = loop.finished;
    try testing.expectEqual(@as(usize, 1), after_turn);

    try loop.compact();
    try settle(&loop);

    // Compaction ends by setting `.idle` directly, so nothing counted it.
    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqual(after_turn, loop.finished);
}

test "oversized tool output is truncated for the model" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    const big = try testing.allocator.alloc(u8, max_tool_result_bytes * 2);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    const trimmed = try loop.trimForModel("list", big);
    defer testing.allocator.free(trimmed);

    try testing.expect(trimmed.len < big.len);
    try testing.expect(std.mem.indexOf(u8, trimmed, "truncated") != null);

    const small = "fine";
    try testing.expectEqual(small.ptr, (try loop.trimForModel("list", small)).ptr);
}

test "a tool asked for a document keeps more of it than the default allows" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    try fixture.registry.register(.{
        .name = "roomy",
        .description = "hands back a document",
        .schema = "{\"type\":\"object\",\"properties\":{}}",
        .handler = leakHandler,
        .read_only = true,
        .parallel = true,
        .max_result_bytes = max_tool_result_bytes * 4,
    });

    var loop = fixture.loop();
    defer loop.deinit();

    const big = try testing.allocator.alloc(u8, max_tool_result_bytes * 2);
    defer testing.allocator.free(big);
    @memset(big, 'x');

    // Under its own ceiling, so it arrives whole.
    const kept = try loop.trimForModel("roomy", big);
    try testing.expectEqual(big.ptr, kept.ptr);

    const cut = try loop.trimForModel("list", big);
    defer testing.allocator.free(cut);
    try testing.expect(cut.len < big.len);
}

test "cancel returns while the worker is still running" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    // Long enough that the worker is still inside `respond` when cancel lands.
    fixture.fake.latency = .fromMilliseconds(300);

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("go", .{});
    try testing.expect(loop.isBusy());

    const started: std.Io.Timestamp = .now(testing.io, .awake);
    try loop.cancel();
    const elapsed = started.durationTo(.now(testing.io, .awake)).nanoseconds;

    // The point of the whole thing: asking costs nothing.
    try testing.expect(elapsed < 50 * std.time.ns_per_ms);
    try testing.expectEqual(State.cancelling, loop.state);
    try testing.expect(loop.request != null);
    try testing.expect(loop.isBusy());

    // Asking twice changes nothing and still does not block.
    try loop.cancel();
    try testing.expectEqual(State.cancelling, loop.state);

    try loop.settle();

    try testing.expectEqual(State.idle, loop.state);
    try testing.expect(loop.request == null);
    try testing.expect(!fixture.convo.hasPendingToolCalls());
}

fn expectAnsweredToolCalls(convo: *Conversation) !void {
    for (convo.messages.items, 0..) |message, index| {
        for (message.tool_calls) |call| {
            try testing.expect(call.status.isSettled());
            var outputs: usize = 0;
            for (convo.messages.items[index + 1 ..]) |result| {
                if (result.role != .tool) break;
                if (std.mem.eql(u8, result.tool_call_id orelse "", call.id)) outputs += 1;
            }
            try testing.expectEqual(@as(usize, 1), outputs);
        }
    }
}

test "cancelling at approval or during execution leaves complete tool exchanges" {
    for ([_]bool{ false, true }) |start_tools| {
        const fixture = try Fixture.init();
        defer fixture.deinit();

        fixture.registry.tools.getPtr("list").?.read_only = false;

        var loop = fixture.loop();
        defer loop.deinit();

        try loop.submit("go", .{});
        try loop.settle();
        try testing.expectEqual(State.awaiting_approval, loop.state);

        if (start_tools) try loop.decide(.once);
        try loop.cancel();
        try loop.settle();

        try testing.expectEqual(State.idle, loop.state);
        try testing.expect(loop.tools == null);
        try testing.expect(loop.pendingCall() == null);
        try testing.expect(!fixture.convo.hasPendingToolCalls());

        try expectAnsweredToolCalls(&fixture.convo);
        fixture.registry.tools.getPtr("list").?.read_only = true;
        try loop.submit("continue", .{});
        try loop.settle();
        try testing.expectEqual(Outcome.done, loop.outcome);
        try expectAnsweredToolCalls(&fixture.convo);
    }
}

fn expectProposals(loop: *const Loop, command: []const u8, wanted: []const []const []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const call: Conversation.ToolCall = .{
        .id = "call_0",
        .name = "bash",
        .arguments = try std.fmt.allocPrint(arena, "{{\"command\":{f}}}", .{std.json.fmt(command, .{})}),
    };
    const got = try loop.proposals(arena, &call);
    try testing.expectEqual(wanted.len, got.len);
    for (wanted, got) |want, proposal| {
        try testing.expectEqual(want.len, proposal.patterns.len);
        for (want, proposal.patterns) |pattern, actual| try testing.expectEqualStrings(pattern, actual);
    }
}

test "an always-allow proposes the commands that needed asking, narrowest first" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try expectProposals(&loop, "git commit -m x", &.{
        &.{"git commit -m x"}, &.{"git commit *"}, &.{"git *"},
    });
    try expectProposals(&loop, "rm -rf build", &.{
        &.{"rm -rf build"}, &.{"rm *"},
    });
    try expectProposals(&loop, "cd /a && zig build test 2>&1 | tail -20; echo done", &.{
        &.{"zig build test 2>&1"}, &.{"zig build *"}, &.{"zig *"},
    });
    try expectProposals(&loop, "find . | xargs rm", &.{
        &.{"xargs rm"}, &.{"xargs *"},
    });
    try expectProposals(&loop, "make && make install", &.{
        &.{ "make", "make install" }, &.{ "make", "make install *" }, &.{"make *"},
    });

    try expectProposals(&loop, "grep foo > out.txt", &.{&.{"grep foo > out.txt"}});
    try expectProposals(&loop, "echo $(rm -rf /)", &.{&.{"echo $(rm -rf /)"}});
    try expectProposals(&loop, "VAR=x grep foo", &.{&.{"VAR=x grep foo"}});
    try expectProposals(&loop, "cd", &.{&.{"cd"}});

    try loop.remember("bash", "xargs *");
    try expectProposals(&loop, "find . -delete | xargs rm", &.{
        &.{"find . -delete"}, &.{"find *"},
    });

    loop.auto_approve_safe = false;
    try expectProposals(&loop, "grep -rn foo src | xargs rm", &.{
        &.{"grep -rn foo src"}, &.{"grep *"},
    });

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const write: Conversation.ToolCall = .{ .id = "call_1", .name = "write", .arguments = "{\"path\":\"src/main.zig\",\"content\":\"x\"}" };
    const written = try loop.proposals(arena_state.allocator(), &write);
    try testing.expectEqual(@as(usize, 1), written.len);
    try testing.expectEqualStrings("*", written[0].patterns[0]);
}

test "an always-allow on a subcommand does not reach its siblings" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.remember("bash", "git commit *");
    var call: Conversation.ToolCall = .{
        .id = "call_0",
        .name = "bash",
        .arguments = "{\"command\":\"git commit -m wip\"}",
    };
    try testing.expect(loop.isAllowed(&call));
    call.arguments = "{\"command\":\"git status && git commit -m wip\"}";
    try testing.expect(loop.isAllowed(&call));
    call.arguments = "{\"command\":\"git push --force\"}";
    try testing.expect(!loop.isAllowed(&call));
    call.arguments = "{\"command\":\"git commit -m wip; git push\"}";
    try testing.expect(!loop.isAllowed(&call));
    call.arguments = "{\"command\":\"git commit -m $(whoami)\"}";
    try testing.expect(!loop.isAllowed(&call));
}

test "auto-approval needs every program in a command, not just the first" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.remember("bash", "find *");
    var call: Conversation.ToolCall = .{
        .id = "call_0",
        .name = "bash",
        .arguments = "{\"command\":\"find . -type f\"}",
    };
    try testing.expect(loop.isAllowed(&call));

    call.arguments = "{\"command\":\"find . | xargs rm\"}";
    try testing.expect(!loop.isAllowed(&call));

    try loop.remember("bash", "xargs *");
    try testing.expect(loop.isAllowed(&call));
}

test "a read-only command runs without asking, and the toggle takes that away" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    var call: Conversation.ToolCall = .{
        .id = "call_0",
        .name = "bash",
        .arguments = "{\"command\":\"grep -rn foo src | head -20\"}",
    };
    try testing.expect(loop.needsNoDecision(&call));
    try testing.expectEqual(@as(usize, 0), loop.allowed.items.len);

    call.arguments = "{\"command\":\"rm -rf build\"}";
    try testing.expect(!loop.needsNoDecision(&call));

    loop.auto_approve_safe = false;
    call.arguments = "{\"command\":\"grep -rn foo src\"}";
    try testing.expect(!loop.needsNoDecision(&call));

    try loop.remember("bash", "grep *");
    try testing.expect(loop.needsNoDecision(&call));

    loop.auto_approve_safe = true;
    call.arguments = "not json";
    try testing.expect(!loop.isSafe(&call));
    call.arguments = "{\"path\":\"x\"}";
    try testing.expect(!loop.isSafe(&call));
    call.name = "write";
    call.arguments = "{\"command\":\"ls\"}";
    try testing.expect(!loop.isSafe(&call));
}

test "an agent's tools are the ones the model is told about" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.useAgent("build");
    try testing.expect(std.mem.indexOf(u8, loop.tools_json.?, "\"write\"") != null);
    try testing.expect(std.mem.indexOf(u8, loop.tools_json.?, "\"bash\"") != null);

    try loop.useAgent("plan");
    try testing.expectEqualStrings("plan", loop.agent.id);
    try testing.expect(std.mem.indexOf(u8, loop.tools_json.?, "\"read\"") != null);
    try testing.expect(std.mem.indexOf(u8, loop.tools_json.?, "\"write\"") == null);
    try testing.expect(std.mem.indexOf(u8, loop.tools_json.?, "\"bash\"") == null);

    try loop.useAgent("review");
    try testing.expect(std.mem.indexOf(u8, loop.tools_json.?, "\"bash\"") != null);
    try testing.expect(std.mem.indexOf(u8, loop.tools_json.?, "\"edit\"") == null);
}

test "a tool outside the agent is refused rather than prompted" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.fake.tool_name = "write";

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.useAgent("plan");
    try loop.submit("go", .{});
    try settle(&loop);

    // Plan mode cannot write, so nothing stops for the user and nothing runs.
    try testing.expectEqual(State.idle, loop.state);
    const call = fixture.convo.messages.items[1].tool_calls[0];
    try testing.expectEqual(Conversation.ToolCall.Status.rejected, call.status);
    try testing.expect(std.mem.indexOf(u8, call.result.?, "not available in Plan mode") != null);
}

test "a subagent transcript is stored as a session of its own" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var db = try Database.init(testing.allocator, testing.io, ":memory:");
    defer db.deinit();

    var kept: Conversation = .init(testing.allocator);
    defer kept.deinit();
    _ = try kept.addUser("where is the parser", &.{}, &.{});
    _ = try kept.addAssistant("src/parse.zig:40", "thinking about it", 12);

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.attachDatabase(&db, "project", fixture.root, "model");
    try loop.submit("go", .{});

    // While the call is pending, which is when a subagent finishes.
    while (loop.state != .running_tools and loop.isBusy()) {
        _ = try loop.poll();
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .real);
    }
    try loop.storeSubagent(0, &kept);
    try settle(&loop);

    const parent = loop.session_id.?;
    const message_id = loop.message_ids.get(loop.conversation.messages.items[1].seq).?;
    const call_row = (try db.toolCallId(message_id, 0)).?;

    const child = try db.subagentSession(call_row) orelse return error.NoSubagentSession;
    try testing.expect(child != parent);
    try testing.expectEqual(@as(u64, 2), try db.countMessages(child));
}

test "auto mode runs what its judge allows, and lets edits inside the project through unjudged" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    loop.approvals = .auto;

    fixture.fake.tool_name = "bash";
    fixture.fake.tool_arguments = "{\"command\":\"rm -rf build\"}";
    try loop.submit("clear out the build directory", .{});
    try settle(&loop);
    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqual(@as(usize, 1), fixture.fake.judged);
    try testing.expect(fixture.convo.messages.items[1].tool_calls[0].status != .rejected);

    fixture.fake.tool_name = "write";
    fixture.fake.tool_arguments = "{\"path\":\"notes.md\",\"content\":\"x\"}";
    try loop.submit("write a note", .{});
    try settle(&loop);
    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqual(@as(usize, 1), fixture.fake.judged);

    fixture.fake.tool_arguments = "{\"path\":\"/tmp/elsewhere.md\",\"content\":\"x\"}";
    fixture.fake.quick = "BLOCK";
    fixture.fake.careful = "Outside the project.\nVERDICT: BLOCK: that path is outside the project";
    try loop.submit("write it elsewhere", .{});
    try settle(&loop);
    try testing.expectEqual(@as(usize, 3), fixture.fake.judged);
}

test "a link inside the project that points out does not make an edit through it inside" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var outside = testing.tmpDir(.{});
    defer outside.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = buf[0..try outside.dir.realPath(testing.io, &buf)];
    try fixture.tmp.dir.symLink(testing.io, target, "link", .{ .is_directory = true });
    const missing = try std.fs.path.join(testing.allocator, &.{ target, "missing.md" });
    defer testing.allocator.free(missing);
    try fixture.tmp.dir.symLink(testing.io, missing, "dangling.md", .{});

    var loop = fixture.loop();
    defer loop.deinit();
    loop.approvals = .auto;
    fixture.fake.tool_name = "write";
    fixture.fake.quick = "BLOCK";
    fixture.fake.careful = "Outside the project.\nVERDICT: BLOCK: that path leaves the project";

    fixture.fake.tool_arguments = "{\"path\":\"link/notes.md\",\"content\":\"x\"}";
    try loop.submit("write a note", .{});
    try settle(&loop);
    try testing.expectEqual(@as(usize, 2), fixture.fake.judged);
    try testing.expectError(error.FileNotFound, outside.dir.access(testing.io, "notes.md", .{}));

    fixture.fake.tool_arguments = "{\"path\":\"dangling.md\",\"content\":\"x\"}";
    const before = fixture.convo.messages.items.len;
    try loop.submit("write another", .{});
    try settle(&loop);
    var checked = false;
    for (fixture.convo.messages.items[before..]) |message| {
        for (message.tool_calls) |call| {
            try testing.expectEqual(Conversation.ToolCall.Status.rejected, call.status);
            checked = true;
        }
    }
    try testing.expect(checked);
    try testing.expectError(error.FileNotFound, outside.dir.access(testing.io, "missing.md", .{}));
}

test "malformed JSON never reaches approval or execution" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    loop.approvals = .ask;

    fixture.fake.tool_name = "write";
    fixture.fake.tool_arguments = "{\"path\":\"notes.md\",";
    try loop.submit("write a note", .{});
    try settle(&loop);
    try testing.expectEqual(@as(usize, 0), fixture.fake.judged);
    try testing.expectEqual(Conversation.ToolCall.Status.rejected, firstCall(&loop).status);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.access(testing.io, "notes.md", .{}));
}

test "auto mode's block is a considered one, and goes back to the model" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    loop.approvals = .auto;

    fixture.fake.tool_name = "bash";
    fixture.fake.tool_arguments = "{\"command\":\"rm -rf build\"}";
    fixture.fake.quick = "BLOCK";
    fixture.fake.careful = "Nobody asked for that.\nVERDICT: BLOCK: deleting the build tree was not asked for";
    try loop.submit("what is in this project?", .{});
    try settle(&loop);

    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqual(@as(usize, 2), fixture.fake.judged);
    const call = fixture.convo.messages.items[1].tool_calls[0];
    try testing.expectEqual(Conversation.ToolCall.Status.rejected, call.status);
    try testing.expect(std.mem.indexOf(u8, call.result.?, "deleting the build tree was not asked for") != null);
    try testing.expectEqual(Config.Approvals.auto, loop.approvals);
}

test "auto mode hands decisions back after three blocks in a row" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    loop.approvals = .auto;

    fixture.fake.tool_name = "bash";
    fixture.fake.tool_arguments = "{\"command\":\"rm -rf build\"}";
    fixture.fake.parallel_calls = 4;
    fixture.fake.quick = "BLOCK";
    fixture.fake.careful = "VERDICT: BLOCK: no";
    try loop.submit("go", .{});
    try settle(&loop);

    try testing.expectEqual(State.awaiting_approval, loop.state);
    try testing.expectEqual(Config.Approvals.ask, loop.approvals);
    const calls = fixture.convo.messages.items[1].tool_calls;
    for (calls[0..3]) |call| try testing.expectEqual(Conversation.ToolCall.Status.rejected, call.status);
    try testing.expectEqual(Conversation.ToolCall.Status.pending, calls[3].status);
}

test "a call auto mode cannot get a readable verdict on is put to the person" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    loop.approvals = .auto;

    fixture.fake.tool_name = "bash";
    fixture.fake.tool_arguments = "{\"command\":\"rm -rf build\"}";
    fixture.fake.quick = "Let me think.";
    fixture.fake.careful = "It depends.";
    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expectEqual(State.awaiting_approval, loop.state);
    try testing.expectEqual(Config.Approvals.auto, loop.approvals);
}

test "auto mode does not wave a call through on an allowance that runs anything" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();

    const call: Conversation.ToolCall = .{ .id = "call_0", .name = "bash", .arguments = "{\"command\":\"python3 cleanup.py\"}" };
    try loop.remember("bash", "python3 *");
    try testing.expect(loop.needsNoDecision(&call));
    loop.approvals = .auto;
    try testing.expect(!loop.needsNoDecision(&call));
    try loop.remember("bash", "python3 cleanup.py");
    try testing.expect(loop.needsNoDecision(&call));
}

test "a turn's file changes are kept, and undone back to the prompt that made them" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one" });

    var db = try Database.init(testing.allocator, testing.io, ":memory:");
    defer db.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    try loop.attachDatabase(&db, "project", fixture.root, "model");

    fixture.fake.tool_name = "write";
    fixture.fake.tool_arguments = "{\"path\":\"a.txt\",\"content\":\"two\"}";
    try loop.submit("change a", .{});
    try settle(&loop);
    try loop.decide(.once);
    try settle(&loop);

    fixture.fake.tool_arguments = "{\"path\":\"sub/b.txt\",\"content\":\"new\"}";
    try loop.submit("make b", .{});
    try settle(&loop);
    try loop.decide(.once);
    try settle(&loop);

    fixture.fake.tool_arguments = "{\"path\":\"a.txt\",\"content\":\"three\"}";
    try loop.submit("change a again", .{});
    try settle(&loop);
    try loop.decide(.once);
    try settle(&loop);

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const turns = try loop.checkpointTurns(arena);
    try testing.expectEqual(@as(usize, 3), turns.len);
    try testing.expectEqualStrings("make b", turns[1].prompt);
    try testing.expectEqual(@as(u32, 1), turns[1].files);

    const later = try loop.rewind(arena, turns[1].seq, false);
    try testing.expectEqual(@as(usize, 2), later.len);
    try testing.expect(std.mem.endsWith(u8, later[0].path, "a.txt"));
    try testing.expect(!later[0].removed and !later[0].changed);
    try testing.expect(std.mem.endsWith(u8, later[1].path, "b.txt"));
    try testing.expect(later[1].removed);

    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "by hand" });
    const preview = try loop.rewind(arena, turns[0].seq, false);
    try testing.expect(preview[0].changed);
    try testing.expectEqualStrings("by hand", try fixture.tmp.dir.readFileAlloc(testing.io, "a.txt", arena, .unlimited));

    _ = try loop.rewind(arena, turns[0].seq, true);
    try testing.expectEqualStrings("one", try fixture.tmp.dir.readFileAlloc(testing.io, "a.txt", arena, .unlimited));
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.access(testing.io, "sub/b.txt", .{}));
    try testing.expectEqual(@as(usize, 0), (try loop.checkpointTurns(arena)).len);
}

test "a file too large to checkpoint is still changed, and the person told it cannot be put back" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const large = try testing.allocator.alloc(u8, max_checkpoint_bytes + 1);
    defer testing.allocator.free(large);
    @memset(large, 'x');
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "big.txt", .data = large });

    var db = try Database.init(testing.allocator, testing.io, ":memory:");
    defer db.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    try loop.attachDatabase(&db, "project", fixture.root, "model");

    fixture.fake.tool_name = "write";
    fixture.fake.tool_arguments = "{\"path\":\"big.txt\",\"content\":\"small\"}";
    try loop.submit("shrink it", .{});
    try settle(&loop);
    try loop.decide(.once);
    try settle(&loop);

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("small", try fixture.tmp.dir.readFileAlloc(testing.io, "big.txt", arena, .unlimited));
    const notice = loop.hook_flow.notice orelse return error.TestExpectedNotice;
    try testing.expect(std.mem.indexOf(u8, notice, "big.txt") != null);
    try testing.expect(std.mem.indexOf(u8, notice, "/rewind") != null);
}

test "a resumed session's tool results still name the calls they answer" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var db = try Database.init(testing.allocator, testing.io, ":memory:");
    defer db.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    try loop.attachDatabase(&db, "project", fixture.root, "model");

    fixture.fake.tool_name = "write";
    fixture.fake.tool_arguments = "{\"path\":\"a.txt\",\"content\":\"x\"}";
    try loop.submit("write a", .{});
    try settle(&loop);
    try loop.decide(.once);
    try settle(&loop);
    const call_id = try testing.allocator.dupe(u8, firstCall(&loop).id);
    defer testing.allocator.free(call_id);

    var resumed = fixture.loop();
    defer resumed.deinit();
    try resumed.attachDatabase(&db, "project", fixture.root, "model");
    try resumed.resumeSession(loop.session_id.?, 50);

    var results: usize = 0;
    for (resumed.conversation.messages.items) |msg| {
        if (msg.role != .tool) continue;
        results += 1;
        try testing.expectEqualStrings(call_id, msg.tool_call_id.?);
        try testing.expectEqualStrings("write", msg.tool_name.?);
    }
    try testing.expectEqual(@as(usize, 1), results);
}

test "a session comes back in the mode it was left in" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var db = try Database.init(testing.allocator, testing.io, ":memory:");
    defer db.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.attachDatabase(&db, "project", fixture.root, "model");
    try loop.useAgent("build");
    try loop.submit("go", .{});
    try settle(&loop);

    try loop.useAgent("review");
    const session_id = loop.session_id.?;

    var resumed = fixture.loop();
    defer resumed.deinit();
    try resumed.attachDatabase(&db, "project", fixture.root, "model");
    try resumed.useAgent("build");
    try resumed.resumeSession(session_id, 50);

    try testing.expectEqualStrings("review", resumed.agent.id);
}

test "a new session preserves the old one and resets its state" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var db = try Database.init(testing.allocator, testing.io, ":memory:");
    defer db.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.attachDatabase(&db, "project", fixture.root, "model");
    try loop.useAgent("review");
    try loop.submit("first", .{});
    try settle(&loop);
    try loop.rename("old work");
    try loop.todos.replace(&.{.{ .text = "old step", .status = .done }});
    loop.pending_seq = 0;
    loop.pending_index = 1;

    const old_session = loop.session_id.?;
    const old_messages = try db.countMessages(old_session);
    try testing.expect(old_messages > 0);
    try testing.expect(loop.usage.calls > 0);

    try testing.expect(loop.resetForNewSession());
    try testing.expect(loop.session_id == null);
    try testing.expectEqualStrings("", loop.title());
    try testing.expectEqual(@as(u64, 0), fixture.convo.totalCount());
    try testing.expectEqual(@as(usize, 0), loop.message_ids.count());
    try testing.expect(loop.pending_seq == null);
    try testing.expectEqual(@as(usize, 0), loop.pending_index);
    try testing.expectEqual(@as(usize, 0), loop.todos.items.items.len);
    try testing.expectEqual(@as(u32, 0), loop.usage.calls);
    try testing.expectEqualStrings("review", loop.agent.id);
    try testing.expectEqual(old_messages, try db.countMessages(old_session));

    try loop.submit("second", .{});
    try settle(&loop);

    const new_session = loop.session_id.?;
    try testing.expect(new_session != old_session);
    try testing.expectEqual(@as(u64, 0), fixture.convo.messages.items[0].seq);

    const stored_agent = try db.sessionAgent(new_session, testing.allocator);
    defer testing.allocator.free(stored_agent);
    try testing.expectEqualStrings("review", stored_agent);
}

test "the same call three times running stops the turn" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.fake.loop_forever = true;

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("go", .{});
    try settle(&loop);

    try testing.expectEqual(State.idle, loop.state);
    const last = lastAssistant(loop.conversation).?;
    try testing.expect(std.mem.indexOf(u8, last.text, "three times running") != null);

    // Three model calls, not two hundred: the ceiling never came into it.
    try testing.expect(loop.steps <= max_repeats + 1);
    try expectAnsweredToolCalls(&fixture.convo);
    fixture.fake.loop_forever = false;
    try loop.submit("continue", .{});
    try settle(&loop);
    try testing.expectEqual(Outcome.done, loop.outcome);
    try expectAnsweredToolCalls(&fixture.convo);
}

test "different calls are work, not a loop" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    const first: []const Conversation.ToolCall = &.{
        .{ .id = "1", .name = "list", .arguments = "{\"path\":\".\"}" },
    };
    const second: []const Conversation.ToolCall = &.{
        .{ .id = "2", .name = "list", .arguments = "{\"path\":\"src\"}" },
    };

    try testing.expect(!try loop.repeating(first));
    try testing.expect(!try loop.repeating(second));
    try testing.expect(!try loop.repeating(first));
    try testing.expectEqual(@as(usize, 1), loop.repeats);

    // The same one twice is a model correcting itself; three times is stuck.
    try testing.expect(!try loop.repeating(first));
    try testing.expect(try loop.repeating(first));
}

test "an agent's step ceiling is the one that applies" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.useAgent("plan");
    try testing.expectEqual(@as(usize, 40), loop.agent.steps);

    try loop.useAgent("build");
    try testing.expect(loop.agent.steps > 40);
}

test "a pending decision survives history being paged in" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.registry.tools.getPtr("list").?.read_only = false;

    loop.conversation.next_seq = 50;
    loop.conversation.dropped = 50;

    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expectEqual(State.awaiting_approval, loop.state);

    const before = loop.pendingCall().?;

    var older = [_]Conversation.Message{
        .{ .seq = 10, .role = .user, .text = "" },
        .{ .seq = 11, .role = .assistant, .text = "" },
    };
    try loop.conversation.prepend(&older);

    const after = loop.pendingCall().?;
    try testing.expectEqualStrings(before.name, after.name);
    try testing.expectEqualStrings("list", after.name);
}

test "compaction summarises the transcript into a system message" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("what is here?", .{});
    try settle(&loop);
    const before = loop.conversation.messages.items.len;

    try loop.compact();
    try testing.expectEqual(State.compacting, loop.state);
    try settle(&loop);

    try testing.expectEqual(State.idle, loop.state);
    try testing.expect(!loop.compacting);

    try testing.expectEqual(before + 1, loop.conversation.messages.items.len);
    const summary = loop.conversation.messages.items[before];
    try testing.expectEqual(Conversation.Role.system, summary.role);
    try testing.expect(summary.text.len > 0);

    // The fake echoes its input, so this is the only proof the instruction arrived.
    try testing.expect(std.mem.indexOf(u8, summary.text, "Summarise this conversation") != null);
}

test "a compaction after a cancelled turn ends done" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("go", .{});
    try loop.cancel();
    try loop.settle();
    try testing.expectEqual(@as(?Outcome, .cancelled), loop.outcome);

    try loop.compact();
    try settle(&loop);
    try testing.expectEqual(@as(?Outcome, .done), loop.outcome);
}

test "a turn carries the agent's prompt and tools, not the provider's" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();
    loop.system_prompt = "base instructions";

    try loop.useAgent("plan");
    const planning = loop.turn("");
    try testing.expectEqualStrings("base instructions", planning.system);
    try testing.expect(std.mem.indexOf(u8, planning.tools_json, "\"read\"") != null);
    try testing.expect(std.mem.indexOf(u8, planning.tools_json, "\"write\"") == null);
    try testing.expectEqualStrings("", planning.instruction);

    // With a project the agent's own instructions are folded in.
    var project = try Project.detect(testing.allocator, testing.io, fixture.root);
    defer project.deinit(testing.allocator);
    loop.project = &project;

    const with_project = loop.turn("summarise");
    try testing.expect(std.mem.startsWith(u8, with_project.system, "base instructions"));
    try testing.expect(std.mem.indexOf(u8, with_project.system, "plan mode") != null);
    try testing.expect(std.mem.indexOf(u8, with_project.system, "<environment>") != null);
    try testing.expectEqualStrings("summarise", with_project.instruction);
}

test "a tool turn compacts with its task intact and continues without another user message" {
    const Script = struct {
        calls: usize = 0,
        fail_compaction: bool = false,
        fn respond(ptr: *anyopaque, convo: *Conversation, asked: Provider.Turn, allocator: std.mem.Allocator, _: ?Provider.Sink) !Provider.Reply {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) {
                try testing.expect(!asked.compacting);
                const calls = try allocator.alloc(Conversation.ToolCall, 1);
                calls[0] = .{ .id = try allocator.dupe(u8, "list-1"), .name = try allocator.dupe(u8, "list"), .arguments = try allocator.dupe(u8, "{\"path\":\".\"}") };
                return .{ .text = try allocator.dupe(u8, "checking files"), .tool_calls = calls, .usage = .{ .prompt_tokens = 30000 } };
            }
            if (self.calls == 2) {
                try testing.expect(asked.compacting);
                try testing.expectEqualStrings("", asked.tools_json);
                try testing.expectEqualStrings("Implement catalog caching. Keep the original task throughout the tool run.", convo.messages.items[0].text);
                try testing.expectEqual(Conversation.Role.tool, convo.last().?.role);
                if (self.fail_compaction) return error.SummaryUnavailable;
                return .{ .text = try allocator.dupe(u8, "Task: implement catalog caching. Files inspected; continue implementation.") };
            }
            try testing.expect(!asked.compacting);
            const kept = try window.completeMessages(convo, allocator, 1000, true);
            defer allocator.free(kept);
            try testing.expectEqual(@as(usize, 1), kept.len);
            try testing.expectEqualStrings("Task: implement catalog caching. Files inspected; continue implementation.", kept[0].text);
            try testing.expect(asked.instruction.len > 0);
            return .{ .text = try allocator.dupe(u8, "implemented") };
        }
    };
    for ([_]u32{ 40000, 0 }) |limit| {
        for ([_]bool{ false, true }) |fail_compaction| {
            const fixture = try Fixture.init();
            defer fixture.deinit();
            var script: Script = .{ .fail_compaction = fail_compaction };
            var loop = fixture.loop();
            defer loop.deinit();
            const logger: Hooks.Hook = .{ .command = "cat >> automatic-events" };
            const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .pre_compact = &.{logger}, .post_compact = &.{logger}, .session_start = &.{logger} } };
            loop.hooks = &runner;
            loop.system_prompt = "system";
            loop.provider = .{ .name = "script", .userdata = &script, .respond = Script.respond, .context_limit = limit };
            try loop.submit("Implement catalog caching. Keep the original task throughout the tool run.", .{});
            try settle(&loop);
            try testing.expectEqual(State.idle, loop.state);
            try testing.expectEqual(@as(usize, 1), loop.finished);
            const trace = try fixture.tmp.dir.readFileAlloc(testing.io, "automatic-events", testing.allocator, .limited(16 * 1024));
            defer testing.allocator.free(trace);
            var events = std.mem.tokenizeScalar(u8, trace, '\n');
            const expected: []const []const u8 = if (fail_compaction) &.{ "SessionStart", "PreCompact" } else &.{ "SessionStart", "PreCompact", "PostCompact", "SessionStart" };
            for (expected) |event| {
                const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, events.next().?, .{});
                defer parsed.deinit();
                try testing.expectEqualStrings(event, parsed.value.object.get("hook_event_name").?.string);
                if (std.mem.endsWith(u8, event, "Compact")) try testing.expectEqualStrings("auto", parsed.value.object.get("trigger").?.string);
            }
            try testing.expect(events.next() == null);
            if (fail_compaction) {
                try testing.expectEqual(@as(usize, 2), script.calls);
                try testing.expectEqual(Outcome.failed, loop.outcome.?);
                try testing.expectEqual(Conversation.Role.user, fixture.convo.messages.items[0].role);
            } else {
                try testing.expectEqual(@as(usize, 3), script.calls);
                try testing.expectEqualStrings("implemented", lastAssistant(&fixture.convo).?.text);
                try testing.expectEqual(Outcome.done, loop.outcome.?);
            }
        }
    }
}

test "a full context stops without sending a truncated request when auto-compaction is disabled" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    loop.system_prompt = "";
    loop.provider.context_limit = 100;
    loop.auto_compact_at = 0;
    try loop.submit("preserve this task " ** 40, .{});
    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqual(Outcome.halted, loop.outcome.?);
    try testing.expectEqual(@as(u32, 0), loop.usage.calls);
    try testing.expectEqualStrings("preserve this task " ** 40, fixture.convo.messages.items[0].text);

    try loop.compact();
    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqual(@as(u32, 0), loop.usage.calls);
    try testing.expectEqualStrings("preserve this task " ** 40, fixture.convo.messages.items[0].text);
    const notice = lastAssistant(&fixture.convo).?.text;
    try testing.expect(std.mem.indexOf(u8, notice, "too large to compact") != null);
    try testing.expect(std.mem.indexOf(u8, notice, "/clear") != null);
    try testing.expect(std.mem.indexOf(u8, notice, "Use /compact") == null);
}

test "resuming loads the task beyond the display page, or its latest checkpoint" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const path = try std.fs.path.join(testing.allocator, &.{ fixture.root, "context.db" });
    defer testing.allocator.free(path);
    var db = try Database.init(testing.allocator, testing.io, path);
    defer db.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    try loop.attachDatabase(&db, "project", fixture.root, "model");
    const session = try db.createSession(loop.project_id.?, fixture.root, "model");
    _ = try db.appendMessage(session, 0, "user", "original task", null, 0, null);
    _ = try db.appendMessage(session, 1, "assistant", "progress", null, 0, null);
    _ = try db.appendMessage(session, 2, "user", "continue", null, 0, null);
    try loop.resumeSession(session, 1);
    try testing.expectEqualStrings("original task", fixture.convo.messages.items[0].text);
    _ = try db.appendMessage(session, 3, "system", "task and progress checkpoint", null, 0, null);
    _ = try db.appendMessage(session, 4, "user", "next step", null, 0, null);
    try loop.resumeSession(session, 1);
    try testing.expectEqual(@as(usize, 2), fixture.convo.messages.items.len);
    try testing.expectEqualStrings("task and progress checkpoint", fixture.convo.messages.items[0].text);
    try testing.expectEqualStrings("next step", fixture.convo.last().?.text);
}

test "switching models is recorded on the session row" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrint(&path_buffer, "{s}/models.db", .{fixture.root});
    var db = try Database.init(testing.allocator, testing.io, db_path);
    defer db.deinit();

    try loop.attachDatabase(&db, "harness", fixture.root, "configured-model");

    try loop.setModel("second-model");
    try testing.expect(loop.session_id == null);

    const session_id = try loop.ensureSession();
    const at_creation = try db.sessionModel(session_id, testing.allocator);
    defer testing.allocator.free(at_creation);
    try testing.expectEqualStrings("second-model", at_creation);

    try loop.setModel("third-model");
    const after = try db.sessionModel(session_id, testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("third-model", after);

    try testing.expectEqualStrings("third-model", loop.session_model);
    try testing.expect(loop.session_model_owned != null);
}

/// A backend that offers a choice of model, which `FakeProvider` does not.
/// Only the switching half is real: nothing here is ever asked to answer.
const SwitchableProvider = struct {
    buffer: [64]u8 = undefined,
    model: []const u8 = "configured-model",
    switches: usize = 0,

    fn provider(self: *SwitchableProvider) Provider {
        return .{
            .name = "switchable",
            .model = self.model,
            .userdata = self,
            .respond = respond,
            .set_model = switchTo,
        };
    }

    fn respond(_: *anyopaque, _: *Conversation, _: Provider.Turn, _: std.mem.Allocator, _: ?Provider.Sink) !Provider.Reply {
        return error.NotAsked;
    }

    fn switchTo(ptr: *anyopaque, name: []const u8) anyerror!Provider.Current {
        const self: *SwitchableProvider = @ptrCast(@alignCast(ptr));
        if (std.mem.eql(u8, name, "gone")) return error.NoSuchModel;
        self.model = self.buffer[0..name.len];
        @memcpy(self.buffer[0..name.len], name);
        self.switches += 1;
        return .{ .model = self.model, .context_limit = 4096, .vision = false };
    }
};

test "a resumed session runs under the model it was last used with" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrint(&path_buffer, "{s}/resume-model.db", .{fixture.root});
    var db = try Database.init(testing.allocator, testing.io, db_path);
    defer db.deinit();

    const session_id = blk: {
        var loop = fixture.loop();
        defer loop.deinit();
        try loop.attachDatabase(&db, "harness", fixture.root, "configured-model");
        const id = try loop.ensureSession();
        try loop.setModel("minimax-m3");
        break :blk id;
    };

    var backend: SwitchableProvider = .{};
    var loop = fixture.loop();
    loop.provider = backend.provider();
    defer loop.deinit();

    try loop.attachDatabase(&db, "harness", fixture.root, "configured-model");
    try loop.resumeSession(session_id, 50);

    try testing.expectEqualStrings("minimax-m3", loop.provider.model);
    try testing.expectEqualStrings("minimax-m3", loop.session_model);
    try testing.expectEqual(@as(u32, 4096), loop.provider.context_limit);
    try testing.expect(!loop.provider.vision);
}

test "resume leaves the provider alone when there is nothing to restore" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const db_path = try std.fmt.bufPrint(&path_buffer, "{s}/resume-same.db", .{fixture.root});
    var db = try Database.init(testing.allocator, testing.io, db_path);
    defer db.deinit();

    const session_id = blk: {
        var loop = fixture.loop();
        defer loop.deinit();
        try loop.attachDatabase(&db, "harness", fixture.root, "configured-model");
        break :blk try loop.ensureSession();
    };

    var backend: SwitchableProvider = .{};
    var loop = fixture.loop();
    loop.provider = backend.provider();
    defer loop.deinit();

    try loop.attachDatabase(&db, "harness", fixture.root, "configured-model");
    try loop.resumeSession(session_id, 50);

    try testing.expectEqualStrings("configured-model", loop.provider.model);
    try testing.expectEqual(@as(usize, 0), backend.switches);

    try db.setSessionModel(session_id, "gone");
    try loop.resumeSession(session_id, 50);
    try testing.expectEqualStrings("configured-model", loop.provider.model);
}

test "a path outside the project is asked about, whatever the tool is" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    var call: Conversation.ToolCall = .{
        .id = "call_0",
        .name = "read",
        .arguments = "{\"path\":\"src/main.zig\"}",
    };
    try testing.expect(loop.needsNoDecision(&call));

    call.arguments = "{\"path\":\"/etc/passwd\"}";
    try testing.expect(!loop.needsNoDecision(&call));

    call.arguments = "{\"path\":\"../../etc/passwd\"}";
    try testing.expect(!loop.needsNoDecision(&call));

    call.arguments = "{\"path\":\"src/../src/main.zig\"}";
    try testing.expect(loop.needsNoDecision(&call));
}

test "a standing allowance does not extend outside the project" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.remember("write", "*");

    var call: Conversation.ToolCall = .{
        .id = "call_0",
        .name = "write",
        .arguments = "{\"path\":\"notes.md\"}",
    };
    try testing.expect(loop.needsNoDecision(&call));

    call.arguments = "{\"path\":\"/tmp/notes.md\"}";
    try testing.expect(!loop.needsNoDecision(&call));
}

test "approving everything covers commands and paths outside the project" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    var call: Conversation.ToolCall = .{
        .id = "call_0",
        .name = "bash",
        .arguments = "{\"command\":\"rm -rf build\"}",
    };
    try testing.expect(!loop.needsNoDecision(&call));

    loop.approvals = .all;
    try testing.expect(loop.needsNoDecision(&call));

    call.name = "read";
    call.arguments = "{\"path\":\"/etc/passwd\"}";
    try testing.expect(loop.needsNoDecision(&call));

    call.name = "write";
    call.arguments = "{\"path\":\"/tmp/notes.md\"}";
    try testing.expect(loop.needsNoDecision(&call));
    try testing.expectEqual(@as(usize, 0), loop.allowed.items.len);
}

/// A file outside `fixture`'s project, and a `read` of it for the fake to ask for.
fn readOutside(fixture: *Fixture, outside: *testing.TmpDir) ![]u8 {
    try outside.dir.writeFile(testing.io, .{ .sub_path = "notes.md", .data = "outside" });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = buf[0..try outside.dir.realPath(testing.io, &buf)];
    const arguments = try std.fmt.allocPrint(testing.allocator, "{{\"path\":\"{s}/notes.md\"}}", .{dir});
    fixture.fake.tool_name = "read";
    fixture.fake.tool_arguments = arguments;
    return arguments;
}

fn firstCall(loop: *const Loop) Conversation.ToolCall {
    for (loop.conversation.messages.items) |msg| {
        if (msg.tool_calls.len > 0) return msg.tool_calls[0];
    }
    unreachable;
}

test "approving everything runs a call outside the project, not just its prompt" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var outside = testing.tmpDir(.{});
    defer outside.cleanup();
    const arguments = try readOutside(fixture, &outside);
    defer testing.allocator.free(arguments);

    var loop = fixture.loop();
    defer loop.deinit();
    loop.approvals = .all;

    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqual(Conversation.ToolCall.Status.ok, firstCall(&loop).status);
}

test "saying always to a path outside the project runs the call" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var outside = testing.tmpDir(.{});
    defer outside.cleanup();
    const arguments = try readOutside(fixture, &outside);
    defer testing.allocator.free(arguments);

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expectEqual(State.awaiting_approval, loop.state);
    try loop.decide(.{ .always = .command });
    try settle(&loop);
    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqual(Conversation.ToolCall.Status.ok, firstCall(&loop).status);
}

test "a question stops the turn and its answer becomes the result" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.fake.tool_name = "ask_user";
    fixture.fake.tool_arguments = "{\"question\":\"Which one?\"}";

    try loop.submit("go", .{});
    try settle(&loop);

    try testing.expectEqual(State.awaiting_answer, loop.state);

    const asked = loop.pendingQuestion() orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, asked.arguments, "Which one?") != null);

    try loop.answer("the left one");
    try settle(&loop);

    const call = &loop.conversation.messages.items[1].tool_calls[0];
    try testing.expectEqual(Conversation.ToolCall.Status.ok, call.status);
    try testing.expectEqualStrings("the left one", call.result.?);
}

test "pre-tool hook denies owner-thread question before it is shown" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    fixture.fake.tool_name = "ask_user";
    fixture.fake.tool_arguments = "{\"question\":\"Which one?\"}";
    const hook = Hooks.Hook{ .matcher = "ask_user", .command = "echo no questions >&2; exit 2" };
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .pre_tool_use = &.{hook} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expect(loop.pendingQuestion() == null);
    try testing.expectEqual(Conversation.ToolCall.Status.rejected, fixture.convo.messages.items[1].tool_calls[0].status);
}

test "an answer offered when nothing was asked is ignored" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try testing.expectEqual(State.idle, loop.state);
    try loop.answer("nobody asked");
    try testing.expectEqual(State.idle, loop.state);
    try testing.expect(loop.pendingQuestion() == null);
}

test "a provider that goes quiet is given up on rather than waited out" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.fake.latency = .fromMilliseconds(30_000);
    loop.max_stall_ms = 40;

    try loop.submit("go", .{});

    while (loop.isBusy()) {
        _ = try loop.poll();
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .real);
    }

    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqual(Outcome.failed, loop.outcome.?);
    try testing.expectEqual(error.Timeout, loop.last_error.?);

    const last = loop.conversation.messages.items[loop.conversation.messages.items.len - 1];
    try testing.expect(std.mem.indexOf(u8, last.text, "stopped responding") != null);
}

test "a stall is measured from the last chunk, not from the start" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.fake.latency = .fromMilliseconds(120);
    loop.max_stall_ms = 60;

    try loop.submit("go", .{});

    var request = loop.request.?;
    var ticks: usize = 0;
    while (ticks < 12) : (ticks += 1) {
        request.progress_ms.store(tool.monotonicMilliseconds(testing.io), .release);
        try testing.expect(!request.stalled(loop.max_stall_ms));
        try std.Io.sleep(testing.io, .fromMilliseconds(20), .real);
    }

    try loop.cancel();
    while (loop.isBusy()) {
        _ = try loop.poll();
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .real);
    }
    try testing.expectEqual(Outcome.cancelled, loop.outcome.?);
}

test "a stall limit of zero or less leaves the turn alone" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.fake.latency = .fromMilliseconds(200);

    // A negative limit reads as disabled too, the way the turn budgets do.
    for ([_]i64{ 0, -1 }) |limit| {
        loop.max_stall_ms = limit;

        try loop.submit("go", .{});
        while (loop.isBusy()) {
            _ = try loop.poll();
            try std.Io.sleep(testing.io, .fromMilliseconds(1), .real);
        }

        try testing.expectEqual(Outcome.done, loop.outcome.?);
    }
}

test "cancelling signals the worker at once, and the turn ends with it" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.fake.latency = .fromMilliseconds(30_000);

    try loop.submit("go", .{});
    while (loop.state != .thinking) {
        _ = try loop.poll();
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .real);
    }

    try loop.cancel();
    try testing.expect(loop.signalled);

    const started = tool.monotonicMilliseconds(testing.io);
    while (loop.isBusy()) {
        _ = try loop.poll();
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .real);
    }
    const spent = tool.monotonicMilliseconds(testing.io) - started;

    try testing.expectEqual(State.idle, loop.state);
    // A worker in a cancellation point goes as soon as it is signalled.
    try testing.expect(spent < 250);
}

test "a second cancel reaps off-thread like the first" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    // Deaf to the stop flag, so only the reaper's signal ends the worker.
    fixture.fake.latency = .fromMilliseconds(500);
    fixture.fake.deaf = true;

    var round: usize = 0;
    while (round < 2) : (round += 1) {
        try loop.submit("go", .{});
        while (loop.state != .thinking) {
            _ = try loop.poll();
            try std.Io.sleep(testing.io, .fromMilliseconds(1), .real);
        }

        const started = tool.monotonicMilliseconds(testing.io);
        try loop.cancel();

        // Without a reaper the turn is joined here, and the screen is gone.
        try testing.expect(loop.signalled);
        try testing.expect(loop.canceller != null);
        try testing.expect(tool.monotonicMilliseconds(testing.io) - started < 50);

        while (loop.isBusy()) {
            _ = try loop.poll();
            try std.Io.sleep(testing.io, .fromMilliseconds(1), .real);
        }
        try testing.expectEqual(State.idle, loop.state);

        // Cleared with the turn, so the next cancel starts a reaper of its own.
        try testing.expect(!loop.signalled);
    }
}

test "a plan is applied without a worker, and reads back as progress" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.fake.tool_name = "todo";
    fixture.fake.tool_arguments =
        \\{"items":[{"text":"read the code","status":"done"},{"text":"write the test","status":"active"},{"text":"run it"}]}
    ;

    try loop.submit("go", .{});
    try settle(&loop);

    try testing.expectEqual(@as(usize, 3), loop.todos.items.items.len);
    try testing.expectEqualStrings("write the test", loop.todos.current().?.text);
    try testing.expectEqual(@as(usize, 1), loop.todos.done());

    const call = &loop.conversation.messages.items[1].tool_calls[0];
    try testing.expectEqual(Conversation.ToolCall.Status.ok, call.status);
    try testing.expectEqualStrings("1/3 done, now: write the test", call.result.?);
}

test "pre-tool hook denies owner-thread todo without changing the list" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    fixture.fake.tool_name = "todo";
    fixture.fake.tool_arguments = "{\"items\":[{\"text\":\"should not appear\"}]}";
    const hook = Hooks.Hook{ .matcher = "todo", .command = "echo no todos >&2; exit 2" };
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .pre_tool_use = &.{hook} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expectEqual(@as(usize, 0), loop.todos.items.items.len);
    try testing.expectEqual(Conversation.ToolCall.Status.rejected, fixture.convo.messages.items[1].tool_calls[0].status);
}

test "post-tool hook runs after an owner-thread todo settles" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    fixture.fake.tool_name = "todo";
    fixture.fake.tool_arguments = "{\"items\":[{\"text\":\"kept\"}]}";
    const hook = Hooks.Hook{ .matcher = "todo", .command = "read payload; case \"$payload\" in *tool_response*) echo observed > post-tool-observed; exit 0;; *) exit 2;; esac" };
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .post_tool_use = &.{hook} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    const observed = try fixture.tmp.dir.readFileAlloc(testing.io, "post-tool-observed", testing.allocator, .limited(1024));
    defer testing.allocator.free(observed);
    try testing.expectEqualStrings("observed\n", observed);
    try testing.expectEqual(@as(usize, 1), loop.todos.items.items.len);
    try testing.expectEqual(Conversation.ToolCall.Status.ok, fixture.convo.messages.items[1].tool_calls[0].status);
}

test "a plan survives the session being resumed" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    const db_path = try std.fs.path.join(testing.allocator, &.{ fixture.root, "t.db" });
    defer testing.allocator.free(db_path);

    var db = try Database.init(testing.allocator, testing.io, db_path);
    defer db.deinit();

    fixture.fake.tool_name = "todo";
    fixture.fake.tool_arguments =
        \\{"items":[{"text":"first","status":"done"},{"text":"second","status":"active"}]}
    ;

    var loop = fixture.loop();
    try loop.attachDatabase(&db, "project", fixture.root, "fake");
    try loop.submit("go", .{});
    try settle(&loop);

    const session_id = loop.session_id orelse return error.TestUnexpectedResult;
    loop.deinit();

    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    var next: Loop = .init(
        testing.allocator,
        testing.io,
        fixture.fake.provider(),
        &fixture.registry,
        &convo,
        &fixture.reads,
        fixture.root,
    );
    defer next.deinit();

    try next.attachDatabase(&db, "project", fixture.root, "fake");
    try next.resumeSession(session_id, 50);

    try testing.expectEqual(@as(usize, 2), next.todos.items.items.len);
    try testing.expectEqualStrings("second", next.todos.current().?.text);
    try testing.expectEqual(@as(usize, 1), next.todos.done());
}

test "a turn that has spent its tokens stops rather than asking again" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    loop.max_turn_tokens = 10;
    fixture.fake.prompt_tokens = 40;

    try loop.submit("go", .{});
    try settle(&loop);

    try testing.expect(loop.turn_tokens >= 10);
    const last = lastAssistant(loop.conversation).?;
    try testing.expect(std.mem.indexOf(u8, last.text, "token budget") != null);
}

test "a turn that has run out of time stops rather than asking again" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    loop.max_turn_ms = 1;

    try loop.submit("go", .{});
    loop.turn_started_ms = tool.monotonicMilliseconds(loop.io) - 1000;
    try settle(&loop);

    const last = lastAssistant(loop.conversation).?;
    try testing.expect(std.mem.indexOf(u8, last.text, "ran out of time") != null);
}

test "a budget of zero is no budget at all" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    loop.max_turn_ms = 0;
    loop.max_turn_tokens = 0;
    loop.turn_started_ms = 0;
    loop.turn_tokens = std.math.maxInt(u64);

    try testing.expect(loop.overBudget() == null);
}

test "each turn gets the whole budget again" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.fake.prompt_tokens = 40;

    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expect(loop.turn_tokens > 0);

    try loop.submit("again", .{});
    try testing.expectEqual(@as(u64, 0), loop.turn_tokens);
}

test "a correction typed mid-turn reaches the model at its next step" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("go", .{});
    try testing.expect(loop.isBusy());

    try testing.expect(try loop.steer("no, not that file", .{}));
    try testing.expect(try loop.steer("and be quick", .{}));
    try testing.expectEqual(@as(usize, 2), loop.pendingSteering().len);

    try settle(&loop);

    try testing.expectEqual(@as(usize, 0), loop.pendingSteering().len);

    var seen: usize = 0;
    for (loop.conversation.messages.items) |msg| {
        if (msg.role != .user) continue;
        if (std.mem.eql(u8, msg.text, "no, not that file")) seen += 1;
        if (std.mem.eql(u8, msg.text, "and be quick")) seen += 1;
    }
    try testing.expectEqual(@as(usize, 2), seen);
}

test "steering brings along what came with it" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("go", .{});
    const attachments = [_]mention.Attachment{.{ .path = "pasted", .content = "a long paste" }};
    try testing.expect(try loop.steer("and look at this", .{ .attachments = &attachments, .images = &.{"aW1hZ2U="} }));
    try settle(&loop);

    const steered = for (loop.conversation.messages.items) |msg| {
        if (msg.role == .user and std.mem.eql(u8, msg.text, "and look at this")) break msg;
    } else return error.TestUnexpectedResult;
    try testing.expectEqualStrings("a long paste", steered.attachments[0].content);
    try testing.expectEqualStrings("aW1hZ2U=", steered.images[0]);
}

test "steering never splits an assistant's calls from their results" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("go", .{});
    try testing.expect(try loop.steer("actually, stop reading", .{}));
    try settle(&loop);

    const messages = loop.conversation.messages.items;

    var found = false;
    for (messages, 0..) |msg, i| {
        if (msg.role != .user) continue;
        if (!std.mem.eql(u8, msg.text, "actually, stop reading")) continue;
        found = true;

        try testing.expect(i > 0);
        try testing.expectEqual(@as(usize, 0), messages[i - 1].tool_calls.len);
    }
    try testing.expect(found);
}

test "there is nothing to steer when the loop is idle" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try testing.expect(!try loop.steer("hello?", .{}));
    try testing.expectEqual(@as(usize, 0), loop.pendingSteering().len);
}

test "steering is dropped when the transcript it was meant for is swapped out" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("go", .{});
    try testing.expect(try loop.steer("never mind", .{}));

    loop.dropSteering();
    try testing.expectEqual(@as(usize, 0), loop.pendingSteering().len);

    try settle(&loop);
    for (loop.conversation.messages.items) |msg| {
        try testing.expect(!std.mem.eql(u8, msg.text, "never mind"));
    }
}

test "a cancelled turn hands back what was typed during it" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    fixture.fake.latency = .fromMilliseconds(50);

    try loop.submit("go", .{});
    try testing.expect(try loop.steer("wait, do this instead", .{}));

    try loop.cancel();
    try settle(&loop);

    var left = loop.takeSteering() orelse return error.TestUnexpectedResult;
    defer left.deinit(testing.allocator);
    try testing.expectEqualStrings("wait, do this instead", left.prompt);
    try testing.expectEqual(@as(usize, 0), loop.pendingSteering().len);

    for (loop.conversation.messages.items) |msg| {
        if (msg.role != .user) continue;
        try testing.expect(!std.mem.eql(u8, msg.text, "wait, do this instead"));
    }
}

test "taking steering from a turn that had none is not an error" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try testing.expect(loop.takeSteering() == null);
}

test "a finished turn says how it ended and what it did" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try testing.expect(loop.outcome == null);

    try loop.submit("what is here?", .{});
    try settle(&loop);

    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqual(Outcome.done, loop.outcome.?);

    var did = try loop.lastTurn(testing.allocator);
    defer did.deinit(testing.allocator);

    // The fixture's model asks for one `list`, which counts as a read.
    try testing.expectEqual(@as(usize, 1), did.ok);
    try testing.expectEqual(@as(usize, 0), did.changed);
    try testing.expect(did.any());
}

test "the turn a recap covers starts at the prompt that began it" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.submit("first", .{});
    try settle(&loop);
    const first_start = loop.turn_start_seq.?;

    try loop.submit("second", .{});
    try settle(&loop);

    try testing.expect(loop.turn_start_seq.? > first_start);
    for (fixture.convo.messages.items) |msg| {
        if (msg.seq != loop.turn_start_seq.?) continue;
        try testing.expectEqual(Conversation.Role.user, msg.role);
        try testing.expectEqualStrings("second", msg.text);
    }

    var did = try loop.lastTurn(testing.allocator);
    defer did.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), did.ok);
}

test "what a turn did survives the session being resumed" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    const db_path = try std.fs.path.join(testing.allocator, &.{ fixture.root, "t.db" });
    defer testing.allocator.free(db_path);

    var db = try Database.init(testing.allocator, testing.io, db_path);
    defer db.deinit();

    var loop = fixture.loop();
    try loop.attachDatabase(&db, "project", fixture.root, "fake");
    try loop.submit("go", .{});
    try settle(&loop);

    const written = loop.conversation.last().?;
    try testing.expectEqual(Conversation.Role.summary, written.role);
    const said = try testing.allocator.dupe(u8, written.text);
    defer testing.allocator.free(said);

    const session_id = loop.session_id orelse return error.TestUnexpectedResult;
    loop.deinit();

    var convo: Conversation = .init(testing.allocator);
    defer convo.deinit();

    var next: Loop = .init(
        testing.allocator,
        testing.io,
        fixture.fake.provider(),
        &fixture.registry,
        &convo,
        &fixture.reads,
        fixture.root,
    );
    defer next.deinit();

    try next.attachDatabase(&db, "project", fixture.root, "fake");
    try next.resumeSession(session_id, 50);

    const restored = convo.last().?;
    try testing.expectEqual(Conversation.Role.summary, restored.role);
    try testing.expectEqualStrings(said, restored.text);
}

test "saying always to a path outside the project covers that path again" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    var call: Conversation.ToolCall = .{
        .id = "call_0",
        .name = "read",
        .arguments = "{\"path\":\"/tmp/hooks.zig\"}",
    };

    try testing.expect(!loop.needsNoDecision(&call));
    try loop.allow(&call, .subcommand);
    try testing.expect(loop.needsNoDecision(&call));

    call.arguments = "{\"path\":\"/tmp/other.zig\"}";
    try testing.expect(!loop.needsNoDecision(&call));
}

test "an allowance outside the project is keyed on the resolved path" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    var call: Conversation.ToolCall = .{
        .id = "call_0",
        .name = "read",
        .arguments = "{\"path\":\"/tmp/hooks.zig\"}",
    };
    try loop.allow(&call, .subcommand);

    call.arguments = "{\"path\":\"/tmp/nested/../hooks.zig\"}";
    try testing.expect(loop.needsNoDecision(&call));

    call.arguments = "{\"path\":\"/tmp/../etc/passwd\"}";
    try testing.expect(!loop.needsNoDecision(&call));
}

test "a blanket allowance still stops at the project boundary" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.remember("read", "*");

    var call: Conversation.ToolCall = .{
        .id = "call_0",
        .name = "read",
        .arguments = "{\"path\":\"notes.md\"}",
    };
    try testing.expect(loop.needsNoDecision(&call));

    call.arguments = "{\"path\":\"/tmp/hooks.zig\"}";
    try testing.expect(!loop.needsNoDecision(&call));
}

test "a request the backend calls too large compacts and carries on" {
    const Script = struct {
        calls: usize = 0,
        refusals: usize = 0,
        fn respond(ptr: *anyopaque, _: *Conversation, asked: Provider.Turn, allocator: std.mem.Allocator, _: ?Provider.Sink) !Provider.Reply {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (asked.compacting) return .{ .text = try allocator.dupe(u8, "Summary of the work so far.") };
            // The local estimate let this through and the backend disagreed.
            if (self.refusals == 0) {
                self.refusals += 1;
                return error.ContextTooLarge;
            }
            return .{ .text = try allocator.dupe(u8, "carried on") };
        }
    };
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var script: Script = .{};
    var loop = fixture.loop();
    defer loop.deinit();
    loop.system_prompt = "";
    loop.provider = .{ .name = "script", .userdata = &script, .respond = Script.respond, .context_limit = 4000 };

    try loop.submit("do the thing", .{});
    try settle(&loop);

    try testing.expectEqual(@as(usize, 1), script.refusals);
    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqual(Outcome.done, loop.outcome.?);
    try testing.expectEqualStrings("carried on", lastAssistant(&fixture.convo).?.text);
}

test "a compaction the backend also refuses reports instead of trying again" {
    const Script = struct {
        calls: usize = 0,
        fn respond(ptr: *anyopaque, _: *Conversation, _: Provider.Turn, _: std.mem.Allocator, _: ?Provider.Sink) !Provider.Reply {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            return error.ContextTooLarge;
        }
    };
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var script: Script = .{};
    var loop = fixture.loop();
    defer loop.deinit();
    loop.system_prompt = "";
    loop.provider = .{ .name = "script", .userdata = &script, .respond = Script.respond, .context_limit = 4000 };

    try loop.submit("do the thing", .{});
    try settle(&loop);

    // The turn, then one compaction attempt. Not a third.
    try testing.expectEqual(@as(usize, 2), script.calls);
    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqual(Outcome.failed, loop.outcome.?);
}

test "a turn that will not fit compacts and carries on instead of stopping" {
    const Script = struct {
        calls: usize = 0,
        fn respond(ptr: *anyopaque, _: *Conversation, asked: Provider.Turn, allocator: std.mem.Allocator, _: ?Provider.Sink) !Provider.Reply {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (asked.compacting) return .{ .text = try allocator.dupe(u8, "Summary of the work so far.") };
            return .{ .text = try allocator.dupe(u8, "carried on") };
        }
    };
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var script: Script = .{};
    var loop = fixture.loop();
    defer loop.deinit();
    loop.system_prompt = "";
    loop.provider = .{ .name = "script", .userdata = &script, .respond = Script.respond, .context_limit = 4000 };

    // Fill the window past what a turn can carry, then ask for one more.
    for (0..8) |_| {
        _ = try fixture.convo.append(.{ .role = .user, .text = "prior work " ** 60 });
        _ = try fixture.convo.append(.{ .role = .assistant, .text = "acknowledged " ** 60 });
    }
    try loop.submit("and now the next thing", .{});
    try settle(&loop);

    // It compacted and then answered, rather than handing back a dead end.
    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqual(Outcome.done, loop.outcome.?);
    try testing.expectEqualStrings("carried on", lastAssistant(&fixture.convo).?.text);
    try testing.expect(script.calls >= 2);
}

test "a call that runs comes out of the turn with a duration on it" {
    const fixture = try Fixture.init();
    defer fixture.deinit();

    var db = try Database.init(testing.allocator, testing.io, ":memory:");
    defer db.deinit();

    var loop = fixture.loop();
    defer loop.deinit();

    try loop.attachDatabase(&db, "project", fixture.root, "model");
    try loop.submit("go", .{});
    try settle(&loop);

    var timed: usize = 0;
    for (fixture.convo.messages.items) |msg| {
        for (msg.tool_calls) |call| {
            if (call.status != .ok and call.status != .failed) continue;
            timed += 1;
            try testing.expect(call.elapsed_ms != null);
            // The clock is stopped, so nothing is left counting.
            try testing.expect(call.started_ms == null);
        }
    }
    try testing.expect(timed > 0);

    // And what the turn measured is what the session keeps.
    const session = loop.session_id.?;
    const message = (try db.messageId(session, 1)).?;
    const stored = try db.loadToolCalls(testing.allocator, message);
    defer {
        for (stored) |*call| call.deinit(testing.allocator);
        testing.allocator.free(stored);
    }
    try testing.expect(stored.len > 0);
    try testing.expect(stored[0].elapsed_ms != null);
}

test "a hook rewrite is approved using effective arguments and runs once" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    fixture.fake.tool_name = "bash";
    fixture.fake.tool_arguments = "{\"command\":\"pwd\"}";
    const hook: Hooks.Hook = .{ .legacy = false, .matcher = "bash", .command = "echo rewrite >> rewrites; printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":{\"command\":\"rm -rf dangerous\"}}}'" };
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .pre_tool_use = &.{hook} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expectEqual(State.awaiting_approval, loop.state);
    try testing.expectEqualStrings("{\"command\":\"rm -rf dangerous\"}", loop.pendingCall().?.arguments);
    try loop.decide(.deny);
    try settle(&loop);
    const rewrites = try fixture.tmp.dir.readFileAlloc(testing.io, "rewrites", testing.allocator, .limited(1024));
    defer testing.allocator.free(rewrites);
    try testing.expectEqualStrings("rewrite\n", rewrites);
}

test "pre-tool policy denies before an approval can be shown" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    fixture.fake.tool_name = "bash";
    fixture.fake.tool_arguments = "{\"command\":\"touch should-not-exist\"}";
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .pre_tool_use = &.{.{ .command = "exit 2" }} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqual(Conversation.ToolCall.Status.rejected, fixture.convo.messages.items[1].tool_calls[0].status);
}

test "hook allowances cannot bypass ordinary approval" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    fixture.fake.tool_name = "bash";
    fixture.fake.tool_arguments = "{\"command\":\"touch permitted\"}";
    const hook: Hooks.Hook = .{ .legacy = false, .command = "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\"}}}'" };
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .permission_request = &.{hook} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expectEqual(State.awaiting_approval, loop.state);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.access(testing.io, "permitted", .{}));
    try loop.decide(.once);
    try settle(&loop);
    try testing.expectEqual(Conversation.ToolCall.Status.ok, fixture.convo.messages.items[1].tool_calls[0].status);
}

test "lifecycle trace pairs model attempts and orders session and tool events" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    const logger: Hooks.Hook = .{ .command = "cat >> hook-events" };
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{
        .session_start = &.{logger},
        .pre_model_request = &.{logger},
        .post_model_request = &.{logger},
        .pre_tool_use = &.{logger},
        .post_tool_use = &.{logger},
        .stop = &.{logger},
    } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    const trace = try fixture.tmp.dir.readFileAlloc(testing.io, "hook-events", testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(trace);
    const expected = [_][]const u8{ "SessionStart", "PreModelRequest", "PostModelRequest", "PreToolUse", "PostToolUse", "PreModelRequest", "PostModelRequest", "Stop" };
    var lines = std.mem.tokenizeScalar(u8, trace, '\n');
    for (expected) |name| {
        const line = lines.next() orelse return error.MissingHookEvent;
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings(name, parsed.value.object.get("hook_event_name").?.string);
        try testing.expect(parsed.value.object.get("session_id").?.string.len > 0);
    }
    try testing.expect(lines.next() == null);
}

test "session-start denial cannot be bypassed by resubmitting a prompt" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .session_start = &.{.{ .command = "exit 2" }} } };
    loop.hooks = &runner;
    for (0..2) |_| {
        try loop.submit("never persist", .{});
        try settle(&loop);
        try testing.expectEqual(@as(usize, 0), fixture.convo.messages.items.len);
        try testing.expectEqual(@as(usize, 0), loop.requests_started);
    }
}

test "completion continuation keeps the existing turn budget" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    const hook: Hooks.Hook = .{ .legacy = false, .command = "printf '%s' '{\"decision\":\"block\",\"reason\":\"continue checking\"}'" };
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .stop = &.{hook} } };
    loop.hooks = &runner;
    loop.max_turn_tokens = 250;
    fixture.fake.prompt_tokens = 100;
    fixture.fake.completion_tokens = 20;
    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expectEqual(State.idle, loop.state);
    try testing.expect(loop.stop_hook_active);
    try testing.expect(loop.turn_tokens >= 250);
}

test "rewritten file arguments drive checkpoints execution and persistence" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const path = try std.fs.path.join(testing.allocator, &.{ fixture.root, "session.db" });
    defer testing.allocator.free(path);
    var db = try Database.init(testing.allocator, testing.io, path);
    defer db.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    try loop.attachDatabase(&db, "project", fixture.root, "fake");
    loop.approvals = .all;
    fixture.fake.tool_name = "write";
    fixture.fake.tool_arguments = "{\"path\":\"original.txt\",\"content\":\"original\"}";
    const hook: Hooks.Hook = .{ .legacy = false, .command = "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":{\"path\":\"effective.txt\",\"content\":\"effective\"}}}'" };
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .pre_tool_use = &.{hook} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    const content = try fixture.tmp.dir.readFileAlloc(testing.io, "effective.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("effective", content);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, "original.txt", .{}));
    const stored = try db.loadMessages(testing.allocator, loop.session_id.?, std.math.maxInt(i64), 100);
    defer {
        for (stored) |*message| message.deinit(testing.allocator);
        testing.allocator.free(stored);
    }
    var checked = false;
    for (stored) |message| for (message.tool_calls) |call| {
        checked = true;
        try testing.expect(std.mem.indexOf(u8, call.arguments, "effective.txt") != null);
    };
    try testing.expect(checked);
    const checkpoint = (try db.conn.row("SELECT path FROM checkpoint WHERE session_id = ?", .{loop.session_id.?})).?;
    defer checkpoint.deinit();
    try testing.expect(std.mem.endsWith(u8, checkpoint.text(0), "effective.txt"));
}

test "post-tool feedback preserves side effects and the original stored result" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const path = try std.fs.path.join(testing.allocator, &.{ fixture.root, "session.db" });
    defer testing.allocator.free(path);
    var db = try Database.init(testing.allocator, testing.io, path);
    defer db.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    try loop.attachDatabase(&db, "project", fixture.root, "fake");
    loop.approvals = .all;
    fixture.fake.tool_name = "write";
    fixture.fake.tool_arguments = "{\"path\":\"note.txt\",\"content\":\"kept\"}";
    const hook: Hooks.Hook = .{ .legacy = false, .command = "printf '%s' '{\"decision\":\"block\",\"reason\":\"verify the file\"}'" };
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .post_tool_use = &.{hook} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    const content = try fixture.tmp.dir.readFileAlloc(testing.io, "note.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("kept", content);
    const call = fixture.convo.messages.items[1].tool_calls[0];
    try testing.expectEqual(Conversation.ToolCall.Status.ok, call.status);
    try testing.expect(std.mem.indexOf(u8, call.result.?, "verify the file") != null);
    const original = (try db.conn.row("SELECT body FROM blob WHERE kind = 'hook_original_tool_result'", .{})).?;
    defer original.deinit();
    try testing.expect(std.mem.indexOf(u8, original.text(0), "verify the file") == null);
}

test "pre-compaction stop leaves history intact and starts no model attempt" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    try fixture.convo.add(.user, "keep history");
    const hook: Hooks.Hook = .{ .legacy = false, .command = "printf '%s' '{\"continue\":false,\"stopReason\":\"keep history\"}'" };
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .pre_compact = &.{hook} } };
    loop.hooks = &runner;
    try loop.compact();
    try settle(&loop);
    try testing.expectEqual(@as(usize, 1), fixture.convo.messages.items.len);
    try testing.expectEqualStrings("keep history", fixture.convo.messages.items[0].text);
    try testing.expectEqual(@as(u64, 0), loop.requests_started);
}

test "successful manual compaction emits post and a new session context" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    try fixture.convo.add(.user, "summarize history");
    const logger: Hooks.Hook = .{ .command = "cat >> compact-events" };
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .pre_compact = &.{logger}, .post_compact = &.{logger}, .session_start = &.{logger} } };
    loop.hooks = &runner;
    try loop.compact();
    try settle(&loop);
    const trace = try fixture.tmp.dir.readFileAlloc(testing.io, "compact-events", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(trace);
    var lines = std.mem.tokenizeScalar(u8, trace, '\n');
    for ([_][]const u8{ "PreCompact", "PostCompact", "SessionStart" }) |expected| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, lines.next().?, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings(expected, parsed.value.object.get("hook_event_name").?.string);
        if (std.mem.eql(u8, expected, "SessionStart")) {
            try testing.expectEqualStrings("compact", parsed.value.object.get("source").?.string);
        } else try testing.expectEqualStrings("manual", parsed.value.object.get("trigger").?.string);
    }
    try testing.expect(lines.next() == null);
}

test "an explicit interruption emits one bounded cleanup event" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    fixture.fake.latency = .fromSeconds(5);
    const logger: Hooks.Hook = .{ .command = "cat >> interrupt-events" };
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .interrupt = &.{logger}, .pre_model_request = &.{logger}, .post_model_request = &.{logger} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    var pre_emitted = false;
    for (0..200) |_| {
        if (fixture.tmp.dir.readFileAlloc(testing.io, "interrupt-events", testing.allocator, .limited(16 * 1024))) |trace| {
            defer testing.allocator.free(trace);
            if (std.mem.endsWith(u8, trace, "\n")) {
                pre_emitted = true;
                break;
            }
        } else |_| {}
        try std.Io.sleep(testing.io, .fromMilliseconds(5), .awake);
    }
    try testing.expect(pre_emitted);
    try loop.cancel();
    try loop.cancel();
    try settle(&loop);
    const trace = try fixture.tmp.dir.readFileAlloc(testing.io, "interrupt-events", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(trace);
    var lines = std.mem.tokenizeScalar(u8, trace, '\n');
    for ([_][]const u8{ "PreModelRequest", "PostModelRequest", "Interrupt" }, 0..) |event, index| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, lines.next().?, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings(event, parsed.value.object.get("hook_event_name").?.string);
        if (index == 1) try testing.expectEqualStrings("cancelled", parsed.value.object.get("status").?.string);
    }
    try testing.expect(lines.next() == null);
    try testing.expectEqual(Outcome.cancelled, loop.outcome.?);
}

test "transcript exports are private immutable snapshots with explicit null fallback" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var runtime: Hooks.Runtime = .{ .allocator = testing.allocator, .io = testing.io };
    defer runtime.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .runtime = &runtime, .set = .{ .pre_tool_use = &.{.{ .command = "true", .transcript = true }} } };
    loop.hooks = &runner;
    try fixture.convo.add(.user, "history");
    try testing.expect((try loop.exportHookInput(.{ .event = .stop })).transcript_path == null);
    const first = try loop.exportHookInput(.{ .event = .pre_tool_use });
    const first_path = try testing.allocator.dupe(u8, first.transcript_path.?);
    defer testing.allocator.free(first_path);
    runtime.retainSnapshot(first_path);
    defer runtime.releaseSnapshot(first_path);
    try fixture.convo.add(.assistant, "later");
    const second = try loop.exportHookInput(.{ .event = .pre_tool_use });
    try testing.expect(!std.mem.eql(u8, first_path, second.transcript_path.?));
    const original = try std.Io.Dir.cwd().readFileAlloc(testing.io, first_path, testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(original);
    try testing.expect(std.mem.indexOf(u8, original, "history") != null);
    try testing.expect(std.mem.indexOf(u8, original, "later") == null);
    const file = try std.Io.Dir.cwd().openFile(testing.io, first_path, .{});
    defer file.close(testing.io);
    const stat = try file.stat(testing.io);
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "cancellation during shared pre-tool policy prevents tool execution" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    loop.approvals = .all;
    fixture.fake.tool_name = "write";
    fixture.fake.tool_arguments = "{\"path\":\"must-not-exist\",\"content\":\"bad\"}";
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .pre_tool_use = &.{.{ .command = "read payload; echo started > hook-started; sleep 5" }} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    var started = false;
    for (0..200) |_| {
        _ = try loop.poll();
        if (fixture.tmp.dir.openFile(testing.io, "hook-started", .{})) |file| {
            file.close(testing.io);
            started = true;
            break;
        } else |_| {}
        try std.Io.sleep(testing.io, .fromMilliseconds(5), .awake);
    }
    try testing.expect(started);
    try loop.cancel();
    try settle(&loop);
    try testing.expectEqual(Outcome.cancelled, loop.outcome.?);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, "must-not-exist", .{}));
    try expectAnsweredToolCalls(&fixture.convo);
}

test "pre-tool policy is not invoked again by the execution worker" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .pre_tool_use = &.{.{ .command = "read payload; printf '.\\n' >> hook-count" }} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    const count = try fixture.tmp.dir.readFileAlloc(testing.io, "hook-count", testing.allocator, .limited(1024));
    defer testing.allocator.free(count);
    try testing.expectEqualStrings(".\n", count);
}

test "session hooks distinguish startup clear and resume with persistent handles" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const path = try std.fs.path.join(testing.allocator, &.{ fixture.root, "session.db" });
    defer testing.allocator.free(path);
    var db = try Database.init(testing.allocator, testing.io, path);
    defer db.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    try loop.attachDatabase(&db, "project", fixture.root, "fake");
    const logger: Hooks.Hook = .{ .command = "cat >> starts" };
    var runtime: Hooks.Runtime = .{ .allocator = testing.allocator, .io = testing.io };
    defer runtime.deinit();
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .runtime = &runtime, .set = .{ .session_start = &.{logger}, .session_end = &.{.{ .command = "cat >> ends" }} } };
    loop.hooks = &runner;
    try loop.submit("first", .{});
    try settle(&loop);
    const original_session = loop.session_id.?;
    const original_handle = try db.sessionPublicId(original_session, testing.allocator);
    defer testing.allocator.free(original_handle);
    try testing.expect(loop.resetForNewSession());
    try loop.submit("second", .{});
    try settle(&loop);
    const next_handle = try db.sessionPublicId(loop.session_id.?, testing.allocator);
    defer testing.allocator.free(next_handle);
    try testing.expect(!std.mem.eql(u8, original_handle, next_handle));
    try loop.resumeSession(original_session, 100);
    const ends = try fixture.tmp.dir.readFileAlloc(testing.io, "ends", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(ends);
    var end_lines = std.mem.tokenizeScalar(u8, ends, '\n');
    for ([_][]const u8{ "clear", "resume" }, 0..) |reason, index| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, end_lines.next().?, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings(reason, parsed.value.object.get("reason").?.string);
        try testing.expectEqualStrings(if (index == 0) original_handle else next_handle, parsed.value.object.get("session_id").?.string);
    }
    try testing.expect(end_lines.next() == null);
    try loop.submit("third", .{});
    try settle(&loop);
    const trace = try fixture.tmp.dir.readFileAlloc(testing.io, "starts", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(trace);
    var lines = std.mem.tokenizeScalar(u8, trace, '\n');
    for ([_][]const u8{ "startup", "clear", "resume" }, 0..) |source, index| {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, lines.next().?, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings(source, parsed.value.object.get("source").?.string);
        try testing.expectEqualStrings(if (index == 1) next_handle else original_handle, parsed.value.object.get("session_id").?.string);
    }
    try testing.expect(lines.next() == null);
}

test "failed compaction preserves history and does not emit success events" {
    const Failing = struct {
        fn respond(_: *anyopaque, _: *Conversation, _: Provider.Turn, _: std.mem.Allocator, _: ?Provider.Sink) anyerror!Provider.Reply {
            return error.TestProviderFailure;
        }
    };
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    loop.provider.respond = Failing.respond;
    try fixture.convo.add(.user, "keep this");
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{
        .pre_compact = &.{.{ .command = "cat >> compact-events" }},
        .post_compact = &.{.{ .command = "touch wrong-success" }},
        .session_start = &.{.{ .command = "touch wrong-success" }},
    } };
    loop.hooks = &runner;
    try loop.compact();
    try settle(&loop);
    try testing.expectEqualStrings("keep this", fixture.convo.messages.items[0].text);
    try testing.expectEqual(Outcome.failed, loop.outcome.?);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, "wrong-success", .{}));
}

test "idle background context does not create a turn" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var runtime: Hooks.Runtime = .{ .allocator = testing.allocator, .io = testing.io };
    defer runtime.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .runtime = &runtime, .set = .{ .pre_tool_use = &.{.{ .legacy = false, .async = true, .command = "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"later context\"}}'" }} } };
    loop.hooks = &runner;
    var immediate = try runner.evaluate(testing.allocator, loop.hookInput(.{ .event = .pre_tool_use }));
    defer immediate.deinit(testing.allocator);
    try settleHookObservers(&runtime);
    _ = try loop.poll();
    try testing.expectEqual(State.idle, loop.state);
    try testing.expectEqual(@as(u64, 0), loop.requests_started);
    try testing.expectEqual(@as(usize, 0), fixture.convo.messages.items.len);
    try loop.submit("inspect", .{});
    try settle(&loop);
    const delivered = for (fixture.convo.messages.items) |message| {
        if (message.origin == .hook and std.mem.indexOf(u8, message.text, "later context") != null) break true;
    } else false;
    try testing.expect(delivered);
}

test "cancelling a model pre-event never starts the provider afterward" {
    const Counting = struct {
        calls: std.atomic.Value(usize) = .init(0),
        fn respond(raw: *anyopaque, _: *Conversation, _: Provider.Turn, allocator: std.mem.Allocator, _: ?Provider.Sink) !Provider.Reply {
            const self: *@This() = @ptrCast(@alignCast(raw));
            _ = self.calls.fetchAdd(1, .acq_rel);
            return .{ .text = try allocator.dupe(u8, "should not run") };
        }
    };
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var counting: Counting = .{};
    var loop = fixture.loop();
    defer loop.deinit();
    loop.provider = .{ .name = "counting", .userdata = &counting, .respond = Counting.respond };
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .pre_model_request = &.{.{ .command = "read payload; echo started > model-pre; sleep 5" }} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    var started = false;
    for (0..200) |_| {
        if (fixture.tmp.dir.openFile(testing.io, "model-pre", .{})) |file| {
            file.close(testing.io);
            started = true;
            break;
        } else |_| {}
        try std.Io.sleep(testing.io, .fromMilliseconds(5), .awake);
    }
    try testing.expect(started);
    try loop.cancel();
    try settle(&loop);
    try testing.expectEqual(@as(usize, 0), counting.calls.load(.acquire));
    try testing.expectEqual(Outcome.cancelled, loop.outcome.?);
}

fn settleHookObservers(runtime: *Hooks.Runtime) !void {
    var spins: usize = 0;
    while (runtime.background.items.len > 0) : (spins += 1) {
        if (spins > 5000) return error.HookObserversDidNotSettle;
        var result = try runtime.drainFor(testing.allocator, "");
        result.deinit(testing.allocator);
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .awake);
    }
}

test "PostToolBatch sees one complete parallel batch and can stop before another model call" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "seed.txt", .data = "seed" });
    var loop = fixture.loop();
    defer loop.deinit();
    fixture.fake.parallel_calls = 3;
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .post_tool_batch = &.{.{ .legacy = false, .command = "cat > batch.json; printf '%s' '{\"decision\":\"block\",\"reason\":\"inspect batch\"}'" }} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expectEqual(@as(usize, 1), loop.requests_started);
    try testing.expectEqual(Outcome.halted, loop.outcome.?);
    const payload = try fixture.tmp.dir.readFileAlloc(testing.io, "batch.json", testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    const calls = parsed.value.object.get("tool_calls").?.array.items;
    try testing.expectEqual(@as(usize, 3), calls.len);
    for (calls) |call| {
        try testing.expectEqualStrings("ok", call.object.get("status").?.string);
        try testing.expect(call.object.get("tool_use_id").?.string.len > 0);
        try testing.expect(call.object.get("tool_response").?.string.len > 0);
    }
    var results: usize = 0;
    for (fixture.convo.messages.items) |msg| if (msg.role == .tool) {
        results += 1;
    };
    try testing.expectEqual(@as(usize, 3), results);
}

test "an answered owner-thread question reaches PostToolBatch exactly once" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.fake.tool_name = "ask_user";
    fixture.fake.tool_arguments = "{\"question\":\"Continue?\"}";
    var loop = fixture.loop();
    defer loop.deinit();
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .post_tool_batch = &.{.{ .command = "cat >> batch.jsonl" }} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expectEqual(State.awaiting_answer, loop.state);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, "batch.jsonl", .{}));
    try loop.answer("yes");
    try settle(&loop);
    const payload = try fixture.tmp.dir.readFileAlloc(testing.io, "batch.jsonl", testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("yes", parsed.value.object.get("tool_calls").?.array.items[0].object.get("tool_response").?.string);
}

test "task hooks guard normalized todo creation and completion before mutation" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.fake.tool_name = "todo";
    fixture.fake.tool_arguments = "{\"items\":[{\"text\":\"  protected task  \",\"status\":\"pending\"}]}";
    var loop = fixture.loop();
    defer loop.deinit();
    var runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .task_created = &.{.{ .command = "cat > created.json; echo creation-denied >&2; exit 2" }} } };
    loop.hooks = &runner;
    try loop.submit("plan", .{});
    try settle(&loop);
    try testing.expectEqual(@as(usize, 0), loop.todos.items.items.len);
    const created = try fixture.tmp.dir.readFileAlloc(testing.io, "created.json", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(created);
    const value = try std.json.parseFromSlice(std.json.Value, testing.allocator, created, .{});
    defer value.deinit();
    try testing.expectEqualStrings("protected task", value.value.object.get("task_subject").?.string);
    try testing.expectEqual(@as(usize, 64), value.value.object.get("task_id").?.string.len);
    try loop.todos.replace(&.{.{ .text = "protected task", .status = .active }});
    fixture.fake.tool_arguments = "{\"items\":[{\"text\":\"protected task\",\"status\":\"done\"}]}";
    runner.set.task_created = &.{};
    runner.set.task_completed = &.{.{ .command = "cat > completed.json; echo completion-denied >&2; exit 2" }};
    try loop.submit("finish", .{});
    try settle(&loop);
    try testing.expectEqual(todo.Status.active, loop.todos.items.items[0].status);
    const completed = try fixture.tmp.dir.readFileAlloc(testing.io, "completed.json", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(completed);
    try testing.expect(std.mem.indexOf(u8, completed, "TaskCompleted") != null);
}

test "accepted task transitions emit creation once and completion once" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.fake.tool_name = "todo";
    fixture.fake.tool_arguments = "{\"items\":[{\"text\":\"one task\",\"status\":\"pending\"}]}";
    var loop = fixture.loop();
    defer loop.deinit();
    const logger: Hooks.Hook = .{ .command = "cat >> tasks.jsonl" };
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .task_created = &.{logger}, .task_completed = &.{logger} } };
    loop.hooks = &runner;
    try loop.submit("plan", .{});
    try settle(&loop);
    try loop.submit("keep same plan", .{});
    try settle(&loop);
    fixture.fake.tool_arguments = "{\"items\":[{\"text\":\"one task\",\"status\":\"done\"}]}";
    try loop.submit("finish", .{});
    try settle(&loop);
    const trace = try fixture.tmp.dir.readFileAlloc(testing.io, "tasks.jsonl", testing.allocator, .limited(32 * 1024));
    defer testing.allocator.free(trace);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "TaskCreated"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, trace, "TaskCompleted"));
    try testing.expectEqual(todo.Status.done, loop.todos.items.items[0].status);
}

test "StopFailure observes a terminal provider error without running Stop" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const Failure = struct {
        fn respond(_: *anyopaque, _: *Conversation, _: Provider.Turn, _: std.mem.Allocator, _: ?Provider.Sink) !Provider.Reply {
            return error.NotSignedIn;
        }
    };
    var runtime: Hooks.Runtime = .{ .allocator = testing.allocator, .io = testing.io };
    defer runtime.deinit();
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .runtime = &runtime, .set = .{
        .stop_failure = &.{.{ .legacy = false, .matcher = "authentication_failed", .command = "cat > failure.json" }},
        .stop = &.{.{ .command = "touch normal-stop" }},
    } };
    var loop = fixture.loop();
    defer loop.deinit();
    loop.provider.respond = Failure.respond;
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    try settleHookObservers(&runtime);
    try testing.expectEqual(Outcome.failed, loop.outcome.?);
    const payload = try fixture.tmp.dir.readFileAlloc(testing.io, "failure.json", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("authentication_failed", parsed.value.object.get("error").?.string);
    try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("last_assistant_message").?.string, "NotSignedIn") != null);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, "normal-stop", .{}));
}

test "PermissionDenied observes auto denial and retry never grants permission" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.fake.tool_name = "bash";
    fixture.fake.tool_arguments = "{\"command\":\"rm -rf never-created\"}";
    fixture.fake.quick = "BLOCK";
    fixture.fake.careful = "VERDICT: BLOCK: destructive";
    var loop = fixture.loop();
    defer loop.deinit();
    loop.approvals = .auto;
    const hook: Hooks.Hook = .{ .legacy = false, .matcher = "Bash", .command = "cat >> denied.jsonl; printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionDenied\",\"retry\":true}}'" };
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .permission_denied = &.{hook}, .post_tool_use = &.{.{ .command = "touch wrongly-executed" }} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    const call = fixture.convo.messages.items[1].tool_calls[0];
    try testing.expectEqual(Conversation.ToolCall.Status.rejected, call.status);
    try testing.expect(std.mem.indexOf(u8, call.result.?, "may retry") != null);
    const payload = try fixture.tmp.dir.readFileAlloc(testing.io, "denied.jsonl", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(payload);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, payload, "PermissionDenied"));
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, "wrongly-executed", .{}));
}

test "model switch hooks guard the provider and report only successful actual switches" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var backend: SwitchableProvider = .{};
    var runtime: Hooks.Runtime = .{ .allocator = testing.allocator, .io = testing.io };
    defer runtime.deinit();
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .runtime = &runtime, .set = .{
        .pre_model_switch = &.{.{ .legacy = false, .matcher = "blocked", .command = "echo model-denied >&2; exit 2" }},
        .post_model_switch = &.{.{ .legacy = false, .matcher = "allowed", .command = "cat >> switched.jsonl" }},
    } };
    var loop = fixture.loop();
    defer loop.deinit();
    loop.provider = backend.provider();
    loop.hooks = &runner;
    try testing.expectError(error.HookBlocked, loop.switchModel("blocked"));
    try testing.expectEqual(@as(usize, 0), backend.switches);
    try loop.switchModel("allowed");
    try testing.expectError(error.NoSuchModel, loop.switchModel("gone"));
    try settleHookObservers(&runtime);
    try testing.expectEqual(@as(usize, 1), backend.switches);
    const payload = try fixture.tmp.dir.readFileAlloc(testing.io, "switched.jsonl", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("configured-model", parsed.value.object.get("from_model").?.string);
    try testing.expectEqualStrings("allowed", parsed.value.object.get("to_model").?.string);
    try testing.expectEqualStrings("command", parsed.value.object.get("source").?.string);
}

test "instruction loading reports the actual file once per cached load" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "AGENTS.md", .data = "Use the project instructions." });
    var project = try Project.detect(testing.allocator, testing.io, fixture.root);
    defer project.deinit(testing.allocator);
    var runtime: Hooks.Runtime = .{ .allocator = testing.allocator, .io = testing.io };
    defer runtime.deinit();
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .runtime = &runtime, .set = .{ .instructions_loaded = &.{.{ .legacy = false, .matcher = "session_start", .command = "cat >> instructions.jsonl" }} } };
    var loop = fixture.loop();
    defer loop.deinit();
    loop.project = &project;
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    try settleHookObservers(&runtime);
    try loop.submit("continue", .{});
    try settle(&loop);
    try settleHookObservers(&runtime);
    const payload = try fixture.tmp.dir.readFileAlloc(testing.io, "instructions.jsonl", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expect(std.mem.endsWith(u8, parsed.value.object.get("file_path").?.string, "/AGENTS.md"));
    try testing.expectEqualStrings("Project", parsed.value.object.get("memory_type").?.string);
}

test "skill expansion hook rejects before persistence or inference" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .user_prompt_expansion = &.{.{ .legacy = false, .command = "cat > expansion.json; printf '%s' '{\"decision\":\"block\",\"reason\":\"skill denied\"}'" }} } };
    loop.hooks = &runner;
    try loop.submit("/release 1.0", .{ .command_name = "release", .command_args = "1.0", .expanded_prompt = "Publish release 1.0" });
    try settle(&loop);
    try testing.expectEqual(@as(usize, 0), loop.requests_started);
    try testing.expectEqual(@as(usize, 0), fixture.convo.messages.items.len);
    const payload = try fixture.tmp.dir.readFileAlloc(testing.io, "expansion.json", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("release", parsed.value.object.get("command_name").?.string);
    try testing.expectEqualStrings("Publish release 1.0", parsed.value.object.get("expanded_prompt").?.string);
}

test "external file and configuration changes fire while idle without starting inference" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var runtime: Hooks.Runtime = .{ .allocator = testing.allocator, .io = testing.io };
    defer runtime.deinit();
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .runtime = &runtime, .set = .{
        .file_changed = &.{.{ .legacy = false, .matcher = ".env", .command = "cat > file-change.json" }},
        .config_change = &.{.{ .legacy = false, .matcher = "project_settings", .command = "cat > config-change.json" }},
    } };
    var loop = fixture.loop();
    defer loop.deinit();
    loop.hooks = &runner;
    try loop.hook_flow.watch.configure(testing.allocator, testing.io, fixture.root, "", null, runner.set, &.{});
    try fixture.tmp.dir.createDir(testing.io, ".synth", .default_dir);
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = ".synth/hooks.json", .data = "{}" });
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = ".env", .data = "outside write" });
    _ = try loop.poll();
    try settle(&loop);
    try settleHookObservers(&runtime);
    try testing.expectEqual(@as(usize, 0), loop.requests_started);
    try testing.expect(loop.outcome == null);
    const file = try fixture.tmp.dir.readFileAlloc(testing.io, "file-change.json", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(file);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, file, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("add", parsed.value.object.get("event").?.string);
    const config = try fixture.tmp.dir.readFileAlloc(testing.io, "config-change.json", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(config);
    try testing.expect(std.mem.indexOf(u8, config, "project_settings") != null);
}

test "permission and idle notifications are filtered and emitted once" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.fake.tool_name = "write";
    fixture.fake.tool_arguments = "{\"path\":\"note.txt\",\"content\":\"note\"}";
    var runtime: Hooks.Runtime = .{ .allocator = testing.allocator, .io = testing.io };
    defer runtime.deinit();
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .runtime = &runtime, .set = .{ .notification = &.{.{ .legacy = false, .matcher = "permission_prompt|idle_prompt", .command = "cat >> notifications.jsonl" }} } };
    var loop = fixture.loop();
    defer loop.deinit();
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    _ = try loop.poll();
    try loop.decide(.deny);
    try settle(&loop);
    loop.hook_flow.idle_since = tool.monotonicMilliseconds(testing.io) - 60_001;
    _ = try loop.poll();
    _ = try loop.poll();
    try settleHookObservers(&runtime);
    const payload = try fixture.tmp.dir.readFileAlloc(testing.io, "notifications.jsonl", testing.allocator, .limited(32 * 1024));
    defer testing.allocator.free(payload);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, payload, "permission_prompt"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, payload, "idle_prompt"));
}

test "display-only hook output does not alter the model transcript or SQLite" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    const Text = struct {
        fn respond(_: *anyopaque, _: *Conversation, _: Provider.Turn, allocator: std.mem.Allocator, _: ?Provider.Sink) !Provider.Reply {
            return .{ .text = try allocator.dupe(u8, "reference model answer") };
        }
    };
    const path = try std.fs.path.join(testing.allocator, &.{ fixture.root, "display.db" });
    defer testing.allocator.free(path);
    var db = try Database.init(testing.allocator, testing.io, path);
    defer db.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    loop.provider.respond = Text.respond;
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .message_display = &.{.{ .legacy = false, .command = "cat >/dev/null; printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"MessageDisplay\",\"displayContent\":\"visible answer\"}}'" }} } };
    loop.hooks = &runner;
    try loop.attachDatabase(&db, "test", fixture.root, "fake");
    try loop.submit("answer", .{});
    try settle(&loop);
    const reply = lastAssistant(&fixture.convo).?;
    try testing.expectEqualStrings("reference model answer", reply.text);
    try testing.expectEqualStrings("visible answer", reply.displayedText());
    const rows = try db.loadMessages(testing.allocator, loop.session_id.?, std.math.maxInt(i64), 100);
    defer {
        for (rows) |*row| row.deinit(testing.allocator);
        testing.allocator.free(rows);
    }
    var found = false;
    for (rows) |row| {
        if (row.role != .assistant) continue;
        try testing.expectEqualStrings("reference model answer", row.text);
        try testing.expect(row.display_text == null);
        found = true;
    }
    try testing.expect(found);
}

test "automatic model refresh reports a change once with the previous owned model" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var backend: SwitchableProvider = .{};
    var runtime: Hooks.Runtime = .{ .allocator = testing.allocator, .io = testing.io };
    defer runtime.deinit();
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .runtime = &runtime, .set = .{
        .pre_model_switch = &.{.{ .command = "touch wrong-explicit-switch; exit 2" }},
        .post_model_switch = &.{.{ .command = "cat >> automatic-model.jsonl" }},
    } };
    const Refresh = struct {
        fn current(raw: *anyopaque) Provider.Current {
            const value: *SwitchableProvider = @ptrCast(@alignCast(raw));
            return .{ .model = value.model };
        }
    };
    var loop = fixture.loop();
    defer loop.deinit();
    loop.provider = backend.provider();
    loop.provider.refresh = Refresh.current;
    loop.hooks = &runner;
    try loop.trackModel("initial");
    _ = try SwitchableProvider.switchTo(&backend, "discovered-model");
    loop.syncProvider();
    loop.syncProvider();
    try settleHookObservers(&runtime);
    const payload = try fixture.tmp.dir.readFileAlloc(testing.io, "automatic-model.jsonl", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(payload);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, payload, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("configured-model", parsed.value.object.get("from_model").?.string);
    try testing.expectEqualStrings("discovered-model", parsed.value.object.get("to_model").?.string);
    try testing.expectEqualStrings("automatic", parsed.value.object.get("source").?.string);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.openFile(testing.io, "wrong-explicit-switch", .{}));
}

test "directory registration updates approval boundaries and emits one source-matched hook" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var outside = testing.tmpDir(.{});
    defer outside.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const extra = buffer[0..try outside.dir.realPath(testing.io, &buffer)];
    var runtime: Hooks.Runtime = .{ .allocator = testing.allocator, .io = testing.io };
    defer runtime.deinit();
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .runtime = &runtime, .set = .{
        .directory_added = &.{.{ .legacy = false, .matcher = "register_repo_root", .command = "cat >> directories.jsonl" }},
    } };
    var loop = fixture.loop();
    defer loop.deinit();
    loop.hooks = &runner;
    const args = try std.fmt.allocPrint(testing.allocator, "{{\"path\":\"{s}/file.txt\"}}", .{extra});
    defer testing.allocator.free(args);
    const call: Conversation.ToolCall = .{ .id = "outside-read", .name = "read", .arguments = args };
    try testing.expect(!loop.needsNoDecision(&call));
    try loop.addDirectory(extra, "register_repo_root");
    try loop.addDirectory(extra, "register_repo_root");
    try testing.expectEqual(@as(usize, 1), loop.additional_roots.items.len);
    try testing.expect(loop.needsNoDecision(&call));
    try settleHookObservers(&runtime);
    const trace = try fixture.tmp.dir.readFileAlloc(testing.io, "directories.jsonl", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(trace);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, trace, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(extra, parsed.value.object.get("directory").?.string);
    try testing.expectEqualStrings("register_repo_root", parsed.value.object.get("source").?.string);
    try fixture.tmp.dir.symLink(testing.io, "/", "escape", .{ .is_directory = true });
    const escaping: Conversation.ToolCall = .{ .id = "escape", .name = "read", .arguments = "{\"path\":\"escape/etc/passwd\"}" };
    try testing.expect(!loop.needsNoDecision(&escaping));
}

test "directory changes preserve worker paths and report session cwd from project hooks" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDir(testing.io, "sub", .default_dir);
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "sub/seed.txt", .data = "from the new directory" });
    var runtime: Hooks.Runtime = .{ .allocator = testing.allocator, .io = testing.io };
    defer runtime.deinit();
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .runtime = &runtime, .set = .{
        .cwd_changed = &.{.{ .legacy = false, .command = "cat >> cwd.jsonl" }},
    } };
    var loop = fixture.loop();
    defer loop.deinit();
    loop.hooks = &runner;
    try loop.changeDirectory("sub");
    const next = try std.fs.path.join(testing.allocator, &.{ fixture.root, "sub" });
    defer testing.allocator.free(next);
    try testing.expectEqualStrings(next, loop.workingDirectory());
    try loop.changeDirectory(".");
    try settleHookObservers(&runtime);
    const trace = try fixture.tmp.dir.readFileAlloc(testing.io, "cwd.jsonl", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(trace);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, trace, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(fixture.root, parsed.value.object.get("old_cwd").?.string);
    try testing.expectEqualStrings(next, parsed.value.object.get("new_cwd").?.string);
    try testing.expectEqualStrings(next, parsed.value.object.get("cwd").?.string);
    fixture.fake.tool_name = "read";
    fixture.fake.tool_arguments = "{\"path\":\"seed.txt\"}";
    try loop.submit("read here", .{});
    try settle(&loop);
    var found = false;
    for (fixture.convo.messages.items) |message| for (message.tool_calls) |call| {
        if (std.mem.eql(u8, call.name, "read")) {
            try testing.expectEqual(Conversation.ToolCall.Status.ok, call.status);
            try testing.expect(std.mem.indexOf(u8, call.result.?, "from the new directory") != null);
            found = true;
        }
    };
    try testing.expect(found);
}

test "directory failures leave the session workspace unchanged" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    try testing.expectError(error.FileNotFound, loop.changeDirectory("missing"));
    try testing.expectError(error.FileNotFound, loop.addDirectory("missing", "slash_command"));
    try testing.expectEqual(@as(usize, 0), loop.additional_roots.items.len);
    loop.state = .awaiting_answer;
    try testing.expectError(error.Busy, loop.changeDirectory("sub"));
    try testing.expectError(error.Busy, loop.addDirectory("sub", "slash_command"));
    loop.state = .idle;
}

test "normal judge and compaction requests route separately with paired purposes" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.fake.tool_name = "bash";
    fixture.fake.tool_arguments = "{\"command\":\"rm -rf never-created\"}";
    fixture.fake.quick = "BLOCK";
    fixture.fake.careful = "VERDICT: BLOCK: destructive";
    var loop = fixture.loop();
    defer loop.deinit();
    loop.approvals = .auto;
    loop.provider.model = "local-test";
    const definitions = [_]Hooks.Hook{
        .{ .command = "cat >> agent-requests.jsonl", .when = .{ .agent_scope = .main, .request_purpose = .agent } },
        .{ .command = "cat >> judge-requests.jsonl", .when = .{ .request_purpose = .approval_judge, .model = "local-test", .provider = "fake" } },
        .{ .command = "cat >> compact-requests.jsonl", .when = .{ .request_purpose = .compaction } },
    };
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .pre_model_request = &definitions, .post_model_request = &definitions } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expectEqual(@as(usize, 2), fixture.fake.judged);
    try loop.compact();
    try settle(&loop);
    for ([_][]const u8{ "agent", "judge", "compact" }, [_][]const u8{ "agent", "approval_judge", "compaction" }, [_]usize{ 4, 4, 2 }) |file, purpose, expected| {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}-requests.jsonl", .{file});
        defer testing.allocator.free(path);
        const trace = try fixture.tmp.dir.readFileAlloc(testing.io, path, testing.allocator, .limited(64 * 1024));
        defer testing.allocator.free(trace);
        var lines = std.mem.tokenizeScalar(u8, trace, '\n');
        var count: usize = 0;
        var previous_id: i64 = 0;
        while (lines.next()) |line| : (count += 1) {
            const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
            defer parsed.deinit();
            const object = parsed.value.object;
            try testing.expectEqualStrings(purpose, object.get("request_purpose").?.string);
            try testing.expectEqualStrings("main", object.get("agent_scope").?.string);
            try testing.expectEqualStrings("fake", object.get("provider").?.string);
            try testing.expectEqualStrings("local-test", object.get("model").?.string);
            try testing.expectEqualStrings(if (count % 2 == 0) "PreModelRequest" else "PostModelRequest", object.get("hook_event_name").?.string);
            const id = object.get("request_id").?.integer;
            if (count % 2 == 0) previous_id = id else try testing.expectEqual(previous_id, id);
        }
        try testing.expectEqual(expected, count);
    }
}

test "child background context must not be consumed by parent" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var runtime: Hooks.Runtime = .{ .allocator = testing.allocator, .io = testing.io };
    defer runtime.deinit();
    var parent = fixture.loop();
    defer parent.deinit();
    var child_convo = Conversation.init(testing.allocator);
    defer child_convo.deinit();
    var child = fixture.loop();
    defer child.deinit();
    child.conversation = &child_convo;
    child.parent = &parent;
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .runtime = &runtime, .set = .{
        .pre_tool_use = &.{.{ .legacy = false, .async = true, .when = .{ .agent_scope = .subagent }, .command = "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"CHILD-ONLY-CONTEXT\"}}'" }},
    } };
    parent.hooks = &runner;
    child.hooks = &runner;
    var dispatched = try runner.evaluate(testing.allocator, child.hookInput(.{ .event = .pre_tool_use, .tool_name = "read" }));
    defer dispatched.deinit(testing.allocator);
    try settleHookObservers(&runtime);
    _ = try parent.poll();
    _ = try child.poll();
    try parent.submit("main request", .{});
    try settle(&parent);
    for (fixture.convo.messages.items) |message| {
        try testing.expect(std.mem.indexOf(u8, message.text, "CHILD-ONLY-CONTEXT") == null);
    }
    try child.submit("child request", .{});
    try settle(&child);
    const delivered = for (child_convo.messages.items) |message| {
        if (message.origin == .hook and std.mem.indexOf(u8, message.text, "CHILD-ONLY-CONTEXT") != null) break true;
    } else false;
    try testing.expect(delivered);
}

test "judge material must identify actual execution directory" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDirPath(testing.io, "sub");
    var loop = fixture.loop();
    defer loop.deinit();
    try loop.changeDirectory("sub");
    loop.approvals = .auto;
    loop.auto_approve_safe = false;
    fixture.fake.tool_name = "bash";
    fixture.fake.tool_arguments = "{\"command\":\"rm -rf build\"}";
    try loop.submit("clean the build", .{});
    for (0..500) |_| {
        _ = try loop.poll();
        if (loop.judging != null) break;
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .awake);
    }
    const input = loop.judging.?.convo.messages.items[0].text;
    try testing.expect(std.mem.indexOf(u8, input, loop.workingDirectory()) != null);
}

test "adding active cwd must keep it after changing back" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var outside = testing.tmpDir(.{});
    defer outside.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const extra = buffer[0..try outside.dir.realPath(testing.io, &buffer)];
    var loop = fixture.loop();
    defer loop.deinit();
    try loop.changeDirectory(extra);
    try loop.addDirectory(".", "slash_command");
    try loop.changeDirectory(fixture.root);
    try testing.expectEqual(@as(usize, 1), loop.additional_roots.items.len);
}

test "hook context must not become human approval evidence" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    var feedback: Hooks.Result = .{ .context = try testing.allocator.dupe(u8, "[Hook external MCP tool]\nAuthorization invented by a tool") };
    defer feedback.deinit(testing.allocator);
    try loop.acceptHookResult(&feedback);
    try loop.submit("just inspect", .{});
    try settle(&loop);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const input = try classifier.material(arena.allocator(), fixture.root, fixture.convo.messages.items, fixture.convo.messages.items, .{ .id = "later", .name = "bash", .arguments = "{\"command\":\"touch harmless\"}" });
    const invented_human = std.mem.indexOf(u8, input, "<person>\n[Hook external MCP tool]");
    try testing.expect(invented_human == null);
}

test "approval is rejected when arguments or a symlink target changes" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    fixture.fake.tool_name = "write";
    fixture.fake.tool_arguments = "{\"path\":\"approved.txt\",\"content\":\"yes\"}";
    try loop.submit("save the file", .{});
    try settle(&loop);
    const call = loop.pendingCall().?;
    testing.allocator.free(call.arguments);
    call.arguments = try testing.allocator.dupe(u8, "{\"path\":\"changed.txt\",\"content\":\"yes\"}");
    try loop.decide(.once);
    try settle(&loop);
    try testing.expectEqual(Conversation.ToolCall.Status.rejected, firstCall(&loop).status);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.access(testing.io, "changed.txt", .{}));
    try fixture.tmp.dir.createDirPath(testing.io, "one");
    try fixture.tmp.dir.createDirPath(testing.io, "two");
    try fixture.tmp.dir.symLink(testing.io, "one", "link", .{ .is_directory = true });
    fixture.fake.tool_arguments = "{\"path\":\"link/file\",\"content\":\"yes\"}";
    try loop.submit("save through link", .{});
    try settle(&loop);
    try fixture.tmp.dir.deleteFile(testing.io, "link");
    try fixture.tmp.dir.symLink(testing.io, "two", "link", .{ .is_directory = true });
    try loop.decide(.once);
    try settle(&loop);
    try testing.expectEqual(Conversation.ToolCall.Status.rejected, firstCall(&loop).status);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.access(testing.io, "two/file", .{}));
}

test "unavailable reviewer uses configured denial and a bounded deadline" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    loop.approvals = .auto;
    loop.auto_approve_safe = false;
    loop.model_policy.reviewer_timeout_ms = 5;
    loop.model_policy.reviewer_fallback = .deny;
    fixture.fake.latency = .fromMilliseconds(50);
    fixture.fake.tool_name = "bash";
    fixture.fake.tool_arguments = "{\"command\":\"touch should-not-exist\"}";
    try loop.submit("inspect only", .{});
    while (loop.judging == null) {
        _ = try loop.poll();
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .awake);
    }
    loop.judging.?.request.started_ms -= 100;
    _ = try loop.pollJudging();
    try settle(&loop);
    try testing.expectEqual(Conversation.ToolCall.Status.rejected, firstCall(&loop).status);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.access(testing.io, "should-not-exist", .{}));
}

test "permission evaluation denies normally allowed read-only calls" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    const deny: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .permission_evaluate = &.{.{ .legacy = false, .command = "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionEvaluate\",\"effect\":\"deny\",\"reason\":\"policy\"}}'" }} } };
    loop.hooks = &deny;
    try loop.submit("inspect", .{});
    try settle(&loop);
    try testing.expectEqual(Conversation.ToolCall.Status.rejected, firstCall(&loop).status);
}

test "changing cwd cannot authorize reads from another root" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var outside = testing.tmpDir(.{});
    defer outside.cleanup();
    const path = try outside.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(path);
    try outside.dir.writeFile(testing.io, .{ .sub_path = "private.txt", .data = "secret" });
    var loop = fixture.loop();
    defer loop.deinit();
    try loop.changeDirectory(path);
    fixture.fake.tool_name = "read";
    fixture.fake.tool_arguments = "{\"path\":\"private.txt\"}";
    try loop.submit("inspect the project", .{});
    try settle(&loop);
    try testing.expectEqual(State.awaiting_approval, loop.state);
    try testing.expectEqualStrings("read", loop.pendingCall().?.name);
}

test "relative policies stay rooted in the project after a directory change" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDirPath(testing.io, "scripts");
    try fixture.tmp.dir.createDirPath(testing.io, "sub/scripts");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "scripts/policy.sh", .data = "echo protected >&2; exit 2" });
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "sub/scripts/policy.sh", .data = "touch attacker-ran" });
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .pre_tool_use = &.{.{ .command = "bash ./scripts/policy.sh" }} } };
    var loop = fixture.loop();
    defer loop.deinit();
    loop.hooks = &runner;
    try loop.changeDirectory("sub");
    try loop.submit("inspect", .{});
    try settle(&loop);
    const call = fixture.convo.messages.items[1].tool_calls[0];
    try testing.expectEqual(Conversation.ToolCall.Status.rejected, call.status);
    try testing.expect(std.mem.indexOf(u8, call.result.?, "protected") != null);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.access(testing.io, "sub/attacker-ran", .{}));
}

test "local model string-encoded numeric arguments remain supported" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "lines.txt", .data = "first\nsecond\nthird\n" });
    fixture.fake.tool_name = "read";
    fixture.fake.tool_arguments = "{\"path\":\"lines.txt\",\"offset\":\"2\",\"limit\":\"1\"}";
    var loop = fixture.loop();
    defer loop.deinit();
    try loop.submit("read the second line", .{});
    try settle(&loop);
    const call = fixture.convo.messages.items[1].tool_calls[0];
    try testing.expectEqual(Conversation.ToolCall.Status.ok, call.status);
    try testing.expect(std.mem.indexOf(u8, call.result.?, "second") != null);
    try testing.expect(std.mem.indexOf(u8, call.result.?, "third") == null);
}

test "explicit hook asks require a human across modes stages and later batch calls" {
    const cases = [_]struct { mode: Config.Approvals, source: Hooks.Event, second: bool = false }{
        .{ .mode = .all, .source = .pre_tool_use },
        .{ .mode = .auto, .source = .pre_tool_use },
        .{ .mode = .all, .source = .permission_evaluate },
        .{ .mode = .auto, .source = .permission_evaluate },
        .{ .mode = .auto, .source = .permission_evaluate, .second = true },
    };
    for (cases) |case| {
        const fixture = try Fixture.init();
        defer fixture.deinit();
        var loop = fixture.loop();
        defer loop.deinit();
        loop.approvals = case.mode;
        loop.auto_approve_safe = false;
        fixture.fake.tool_name = "bash";
        fixture.fake.tool_arguments = "{\"command\":\"touch requires-approval\"}";
        fixture.fake.parallel_calls = if (case.second) 2 else 1;
        const pre: Hooks.Hook = .{ .legacy = false, .command = "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\"}}'" };
        const evaluate: Hooks.Hook = .{ .legacy = false, .command = "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionEvaluate\",\"effect\":\"ask\"}}'" };
        const later: Hooks.Hook = .{ .legacy = false, .command =
            \\read payload; case "$payload" in *'"tool_call_id":"fake-2"'*) printf '%s' '{"hookSpecificOutput":{"hookEventName":"PermissionEvaluate","effect":"ask"}}';; esac
        };
        var set: Hooks.Set = .{
            .permission_request = &.{.{ .legacy = false, .command = "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\"}}}'" }},
        };
        if (case.source == .pre_tool_use) set.pre_tool_use = &.{pre};
        if (case.source == .permission_evaluate) set.permission_evaluate = if (case.second) &.{later} else &.{evaluate};
        const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = set };
        loop.hooks = &runner;
        try loop.submit("inspect only", .{});
        try settle(&loop);
        try testing.expectEqual(State.awaiting_approval, loop.state);
        try testing.expectEqualStrings(if (case.second) "fake-2" else "fake-1", loop.pendingCall().?.id);
        try testing.expectError(error.FileNotFound, fixture.tmp.dir.access(testing.io, "requires-approval", .{}));
    }
}

test "steering with prompt hooks resolves mentions and retains human provenance" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "mentioned.txt", .data = "steered file content" });
    var loop = fixture.loop();
    defer loop.deinit();
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .user_prompt_submit = &.{.{ .command = "true" }} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try testing.expect(try loop.steer("also read @mentioned.txt", .{ .images = &.{"aW1hZ2U="} }));
    try settle(&loop);
    const steered = for (fixture.convo.messages.items) |msg| {
        if (std.mem.eql(u8, msg.text, "also read @mentioned.txt")) break msg;
    } else return error.TestUnexpectedResult;
    try testing.expectEqual(Conversation.Origin.human, steered.origin);
    try testing.expectEqualStrings("steered file content", steered.attachments[0].content);
    try testing.expectEqualStrings("aW1hZ2U=", steered.images[0]);
}

test "adding a home root never grants automatic writes to hook control files" {
    for ([_][]const u8{ ".synth/hooks.json", "state/hook-trust.json", "config.json", ".git/hooks/pre-commit" }) |name| {
        const fixture = try Fixture.init();
        defer fixture.deinit();
        try fixture.tmp.dir.createDirPath(testing.io, "project");
        try fixture.tmp.dir.createDirPath(testing.io, "home/.synth");
        try fixture.tmp.dir.createDirPath(testing.io, "home/state");
        try fixture.tmp.dir.createDirPath(testing.io, "home/.git/hooks");
        const project = try std.fs.path.join(testing.allocator, &.{ fixture.root, "project" });
        defer testing.allocator.free(project);
        const home = try std.fs.path.join(testing.allocator, &.{ fixture.root, "home" });
        defer testing.allocator.free(home);
        const target = try std.fs.path.join(testing.allocator, &.{ home, name });
        defer testing.allocator.free(target);
        const trust = try std.fs.path.join(testing.allocator, &.{ home, "state/hook-trust.json" });
        defer testing.allocator.free(trust);
        const config = try std.fs.path.join(testing.allocator, &.{ home, "config.json" });
        defer testing.allocator.free(config);
        var loop = fixture.loop();
        defer loop.deinit();
        loop.project_root = project;
        loop.control_files = &.{ trust, config };
        loop.approvals = .auto;
        try loop.addDirectory(home, "slash_command");
        fixture.fake.tool_name = "write";
        const args = try std.json.Stringify.valueAlloc(testing.allocator, .{ .path = target, .content = "forged policy" }, .{});
        defer testing.allocator.free(args);
        fixture.fake.tool_arguments = args;
        try loop.submit("update the file", .{});
        try settle(&loop);
        try testing.expectEqual(State.awaiting_approval, loop.state);
        try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, target, .{}));
        try loop.decide(.deny);
        try settle(&loop);
    }
}

test "a referenced hook script requires human approval before editing" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.createDirPath(testing.io, "scripts");
    try fixture.tmp.dir.writeFile(testing.io, .{ .sub_path = "scripts/check.sh", .data = "cat >/dev/null\n" });
    var loop = fixture.loop();
    defer loop.deinit();
    loop.approvals = .auto;
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .pre_tool_use = &.{.{ .command = "bash './scripts/check.sh'" }} } };
    loop.hooks = &runner;
    fixture.fake.tool_name = "write";
    fixture.fake.tool_arguments = "{\"path\":\"scripts/check.sh\",\"content\":\"forged policy\"}";
    try loop.submit("update the script", .{});
    try settle(&loop);
    try testing.expectEqual(State.awaiting_approval, loop.state);
    const original = try fixture.tmp.dir.readFileAlloc(testing.io, "scripts/check.sh", testing.allocator, .limited(1024));
    defer testing.allocator.free(original);
    try testing.expectEqualStrings("cat >/dev/null\n", original);
    try loop.decide(.deny);
    try settle(&loop);
}

test "an unavailable completion policy does not report a successful turn" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    const runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .stop = &.{.{ .command = "synth-no-such-hook-command" }} } };
    loop.hooks = &runner;
    try loop.submit("go", .{});
    try settle(&loop);
    try testing.expectEqual(Outcome.failed, loop.outcome.?);
    const notice = loop.takeHookNotice().?;
    defer testing.allocator.free(notice);
    try testing.expect(std.mem.indexOf(u8, notice, "HookCommandUnavailable") != null);
}

test "an unreviewed prompt remains visible and resumes after trust" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    var runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .pre_tool_use = &.{.{ .command = "true", .trusted = false }} } };
    loop.hooks = &runner;
    try loop.submit("keep my request", .{});
    try testing.expect(std.mem.indexOf(u8, lastAssistant(&fixture.convo).?.text, "Queued prompt: keep my request") != null);
    try testing.expectEqual(@as(u64, 0), loop.requests_started);
    runner.set.pre_tool_use = &.{.{ .command = "true" }};
    try loop.resumePendingPrompt();
    try settle(&loop);
    const request = for (fixture.convo.messages.items) |msg| {
        if (msg.origin == .human and std.mem.eql(u8, msg.text, "keep my request")) break msg;
    } else return error.TestUnexpectedResult;
    try testing.expectEqual(Conversation.Role.user, request.role);
    try testing.expectEqual(Outcome.done, loop.outcome.?);
}

test "clipped human instructions require a human decision instead of model review" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    loop.approvals = .auto;
    fixture.fake.tool_name = "bash";
    fixture.fake.tool_arguments = "{\"command\":\"touch must-not-run\"}";
    const request = try testing.allocator.alloc(u8, HumanIntent.prompt_bytes + 1);
    defer testing.allocator.free(request);
    @memset(request, 'x');
    try loop.submit(request, .{});
    try settle(&loop);
    try testing.expectEqual(State.awaiting_approval, loop.state);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.access(testing.io, "must-not-run", .{}));
    try loop.decide(.deny);
    try settle(&loop);
}

test "cancelling a queued unreviewed prompt prevents later execution" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    var runner: Hooks.Runner = .{ .io = testing.io, .root = fixture.root, .set = .{ .pre_tool_use = &.{.{ .command = "true", .trusted = false }} } };
    loop.hooks = &runner;
    try loop.submit("cancel this request", .{});
    try loop.cancel();
    runner.set.pre_tool_use = &.{.{ .command = "true" }};
    try loop.resumePendingPrompt();
    try settle(&loop);
    try testing.expectEqual(@as(u64, 0), loop.requests_started);
    for (fixture.convo.messages.items) |message| try testing.expect(message.origin != .human);
}

test "a clipped answer keeps subsequent actions behind human review" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var loop = fixture.loop();
    defer loop.deinit();
    loop.approvals = .auto;
    fixture.fake.tool_name = "ask_user";
    fixture.fake.tool_arguments = "{\"question\":\"Any restrictions?\"}";
    try loop.submit("inspect", .{});
    try settle(&loop);
    try testing.expectEqual(State.awaiting_answer, loop.state);
    const answer_text = try testing.allocator.alloc(u8, HumanIntent.decision_bytes);
    defer testing.allocator.free(answer_text);
    @memset(answer_text, 'x');
    try loop.answer(answer_text);
    try settle(&loop);
    fixture.fake.tool_name = "bash";
    fixture.fake.tool_arguments = "{\"command\":\"touch must-not-run\"}";
    try loop.submit("continue", .{});
    try settle(&loop);
    try testing.expectEqual(State.awaiting_approval, loop.state);
    try testing.expectError(error.FileNotFound, fixture.tmp.dir.access(testing.io, "must-not-run", .{}));
    try loop.decide(.deny);
    try settle(&loop);
}

test "reading from an outside cwd still requires human approval" {
    const fixture = try Fixture.init();
    defer fixture.deinit();
    var outside = testing.tmpDir(.{});
    defer outside.cleanup();
    try outside.dir.writeFile(testing.io, .{ .sub_path = "secret.txt", .data = "outside contents" });
    const cwd = try outside.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(cwd);
    var loop = fixture.loop();
    defer loop.deinit();
    try loop.changeDirectory(cwd);
    fixture.fake.tool_name = "read";
    fixture.fake.tool_arguments = "{\"path\":\"secret.txt\"}";
    try loop.submit("read here", .{});
    try settle(&loop);
    try testing.expectEqual(State.awaiting_approval, loop.state);
    try loop.decide(.once);
    try settle(&loop);
    const call = fixture.convo.messages.items[1].tool_calls[0];
    try testing.expectEqual(Conversation.ToolCall.Status.ok, call.status);
    try testing.expect(std.mem.indexOf(u8, call.result.?, "outside contents") != null);
}

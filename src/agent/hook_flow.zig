const std = @import("std");
const Hooks = @import("../core/hooks.zig");
const HooksCopy = @import("../core/hooks_copy.zig");
const HookWatch = @import("../core/hook_watch.zig");
const Conversation = @import("../core/conversation.zig");
const Flow = @This();
const Loop = @import("loop.zig");
const Database = @import("../core/database.zig");

pub const identity_bytes = 16;
const transcript_buffer_bytes = 4 * 1024;
const TranscriptHash = std.crypto.hash.Blake3;

pub const Compaction = enum {
    manual,
    during_turn,

    pub fn trigger(self: Compaction) []const u8 {
        return switch (self) {
            .manual => "manual",
            .during_turn => "auto",
        };
    }
};
pub const Resume = enum { begin_prompt, ask_model, compact, compact_session, after_compact, finish_turn, config_idle, failed_turn };
pub const Pending = union(enum) {
    prompt,
    steering,
    expansion,
    model_switch,
    owner_post: usize,
    policy: usize,
    lifecycle: Resume,
    auto_denied: usize,
    task_policy: usize,
};

pending: Pending = .prompt,
dispatch: ?*Hooks.Dispatch = null,
reload: ?struct {
    userdata: *anyopaque,
    call: *const fn (*anyopaque) anyerror!void,
} = null,
task_seq: ?u64 = null,
task_call: usize = 0,
task_cursor: usize = 0,
permission_notice: ?u64 = null,
model: ?[]u8 = null,
instruction_generation: u64 = 0,
watch: HookWatch = .{},
idle_since: ?i64 = null,
idle_notified: bool = false,
policy: struct { pre_tool_use: usize = 0, permission_evaluate: usize = 0, permission_request: usize = 0 } = .{},
asks: std.ArrayList([]const u8) = .empty,
context: ?[]u8 = null,
session_started: bool = false,
session_source: enum { startup, clear, @"resume", compact } = .startup,
compaction: Compaction = .manual,
compaction_veto_seq: ?u64 = null,
parent_call_id: []const u8 = "",
identity: [identity_bytes * 2]u8 = @splat(0),
notice: ?[]u8 = null,
failure: ?[]u8 = null,
transcript: Transcript = .{},
session_handle: ?[]const u8 = null,

pub fn setNotice(self: *Flow, allocator: std.mem.Allocator, notice: ?[]u8) void {
    if (self.notice) |old| allocator.free(old);
    self.notice = notice;
}

pub fn reset(self: *Flow, allocator: std.mem.Allocator) void {
    self.transcript.deinit(allocator);
    self.compaction = .manual;
    self.compaction_veto_seq = null;
    self.policy = .{};
    self.task_seq = null;
    self.task_cursor = 0;
    self.permission_notice = null;
    self.asks.clearRetainingCapacity();
    self.idle_since = null;
    self.idle_notified = false;
}

pub fn hookInput(self: *const Loop, invocation: Hooks.Invocation) Hooks.Invocation {
    var input = invocation;
    input.cwd = self.workingDirectory();
    input.is_interrupt = invocation.event == .interrupt;
    input.session_id = self.session_public_id orelse self.hook_flow.session_handle orelse &self.hook_flow.identity;
    const owner = self.parent orelse self;
    const turn_number = owner.turn_start_seq orelse owner.conversation.next_seq;
    input.turn_number = turn_number;
    input.agent_id = &self.hook_flow.identity;
    input.agent_type = self.agent.id;
    input.agent_scope = if (self.parent == null) .main else .subagent;
    input.provider = self.effective_provider orelse self.provider.name;
    if (invocation.event == .pre_compact or invocation.event == .post_compact) input.request_purpose = .compaction;
    input.model = self.effective_model orelse self.provider.model;
    if (invocation.event == .pre_model_switch or invocation.event == .post_model_switch) {
        input.model = self.provider.model;
        input.provider = self.provider.name;
    }
    input.permission_mode = @tagName(self.approvals);
    input.stop_hook_active = self.stop_hook_active;
    input.request_id = self.requests_started + 1;
    if (invocation.event == .session_end) input.reason = "shutdown";
    if (self.parent) |parent| {
        input.parent_agent_id = &parent.hook_flow.identity;
        input.parent_tool_call_id = self.hook_flow.parent_call_id;
        input.parent_session_id = parent.session_public_id orelse parent.hook_flow.session_handle orelse &parent.hook_flow.identity;
        input.session_id = input.parent_session_id;
        if (invocation.event == .subagent_start or invocation.event == .subagent_stop) input.tool_call_id = self.hook_flow.parent_call_id;
    }
    if (invocation.event == .stop or invocation.event == .subagent_stop) {
        if (self.conversation.last()) |message| input.last_assistant_message = message.text;
    }
    return input;
}

pub fn prepareHookIdentity(self: *Loop) !void {
    if (self.db) |db| {
        if (self.session_public_id == null and self.hook_flow.session_handle == null) {
            if (self.session_id) |id| {
                self.hook_flow.session_handle = try db.sessionPublicId(id, self.allocator);
            } else {
                var id_buffer: [Database.public_id_bytes]u8 = undefined;
                self.hook_flow.session_handle = try self.allocator.dupe(u8, db.newPublicId(&id_buffer));
            }
        }
    }
}

pub fn exportHookInput(self: *Loop, invocation: Hooks.Invocation) !Hooks.Invocation {
    try prepareHookIdentity(self);
    var input = hookInput(self, invocation);
    const runner = self.hooks orelse return input;
    const events: []const Hooks.Event = switch (invocation.event) {
        .pre_model_request => &.{ .pre_model_request, .post_model_request, .message_display, .model_resolve, .model_settings, .model_context, .model_retry, .http_request, .http_response },
        .post_tool_use => &.{ .post_tool_use, .post_tool_use_failure },
        else => &.{invocation.event},
    };
    var needed = false;
    for (events) |event| {
        for (runner.set.forEvent(event)) |hook| {
            if (hook.enabled and hook.trusted and hook.transcript) needed = true;
        }
    }
    if (!needed) return input;
    const runtime = runner.runtime orelse return input;
    input.transcript_path = try self.hook_flow.transcript.exportSnapshot(self.allocator, runtime, self.conversation.messages.items);
    return input;
}

const Transcript = struct {
    current: ?Snapshot = null,
    rows: std.ArrayList(Row) = .empty,

    const Row = struct { hash: [TranscriptHash.digest_length]u8, end: u64 };

    const Snapshot = struct {
        path: []u8,
        runtime: *Hooks.Runtime,
        stat: std.Io.File.Stat,

        fn open(self: Snapshot, runtime: *Hooks.Runtime) ?std.Io.File {
            if (self.runtime != runtime) return null;
            const file = std.Io.Dir.cwd().openFile(runtime.io, self.path, .{
                .mode = .read_write,
                .allow_directory = false,
                .follow_symlinks = false,
            }) catch return null;
            if (file.stat(runtime.io)) |stat| {
                if (stat.kind == .file and stat.nlink == 1 and stat.inode == self.stat.inode and stat.size == self.stat.size and
                    stat.mtime.nanoseconds == self.stat.mtime.nanoseconds and stat.ctime.nanoseconds == self.stat.ctime.nanoseconds) return file;
            } else |_| {}
            file.close(runtime.io);
            return null;
        }
    };

    const Record = struct {
        seq: u64,
        role: Conversation.Role,
        text: []const u8,
        tool_calls: []const Conversation.ToolCall,

        fn fromMessage(message: Conversation.Message) Record {
            return .{ .seq = message.seq, .role = message.role, .text = message.text, .tool_calls = message.tool_calls };
        }

        fn digest(self: Record) [TranscriptHash.digest_length]u8 {
            var hasher: TranscriptHash = .init(.{});
            hashField(&hasher, self);
            var bytes: [TranscriptHash.digest_length]u8 = undefined;
            hasher.final(&bytes);
            return bytes;
        }
    };

    fn hashField(hasher: *TranscriptHash, value: anytype) void {
        switch (@typeInfo(@TypeOf(value))) {
            .pointer => |info| {
                std.hash.autoHash(hasher, value.len);
                if (info.child == u8) hasher.update(value) else for (value) |item| hashField(hasher, item);
            },
            .optional => {
                std.hash.autoHash(hasher, value != null);
                if (value) |item| hashField(hasher, item);
            },
            .@"struct" => |info| inline for (info.fields) |field| hashField(hasher, @field(value, field.name)),
            else => std.hash.autoHash(hasher, value),
        }
    }

    fn exportSnapshot(self: *Transcript, allocator: std.mem.Allocator, runtime: *Hooks.Runtime, messages: []const Conversation.Message) ![]const u8 {
        const io = runtime.io;
        try self.rows.ensureTotalCapacity(allocator, messages.len);
        if (self.current) |snapshot| {
            if (snapshot.open(runtime)) |file| {
                defer file.close(io);
                const limit = @min(self.rows.items.len, messages.len);
                var prefix: usize = 0;
                for (messages[0..limit], self.rows.items[0..limit]) |message, row| {
                    const digest = Record.fromMessage(message).digest();
                    if (!std.mem.eql(u8, &row.hash, &digest)) break;
                    prefix += 1;
                }
                if (prefix == messages.len and prefix == self.rows.items.len) return snapshot.path;
                // Any worker that can pass this path on to another worker already holds a reference.
                if (prefix > 0 and runtime.snapshotIsExclusive(snapshot.path)) {
                    errdefer self.release(allocator);
                    try self.writeTail(io, file, prefix, messages[prefix..]);
                    self.current.?.stat = try file.stat(io);
                    return snapshot.path;
                }
            }
        }

        const path = try runtime.privatePath(allocator, "jsonl");
        errdefer allocator.free(path);
        const directory = std.Io.Dir.cwd();
        const file = try directory.createFile(io, path, .{ .exclusive = true, .permissions = Hooks.private_file_permissions });
        defer file.close(io);
        errdefer directory.deleteFile(io, path) catch {};
        self.release(allocator);
        try self.writeTail(io, file, 0, messages);
        const stat = try file.stat(io);
        try runtime.registerSnapshot(path);
        self.current = .{ .path = path, .runtime = runtime, .stat = stat };
        return path;
    }

    fn writeTail(self: *Transcript, io: std.Io, file: std.Io.File, prefix: usize, tail: []const Conversation.Message) !void {
        var buffer: [transcript_buffer_bytes]u8 = undefined;
        var writer = file.writer(io, &buffer);
        if (prefix > 0) try writer.seekToUnbuffered(self.rows.items[prefix - 1].end);
        self.rows.shrinkRetainingCapacity(prefix);
        for (tail) |message| {
            const record = Record.fromMessage(message);
            try std.json.Stringify.value(record, .{}, &writer.interface);
            try writer.interface.writeByte('\n');
            self.rows.appendAssumeCapacity(.{ .hash = record.digest(), .end = writer.logicalPos() });
        }
        try writer.end();
    }

    fn release(self: *Transcript, allocator: std.mem.Allocator) void {
        if (self.current) |snapshot| {
            snapshot.runtime.releaseSnapshot(snapshot.path);
            allocator.free(snapshot.path);
            self.current = null;
        }
        self.rows.clearRetainingCapacity();
    }

    pub fn deinit(self: *Transcript, allocator: std.mem.Allocator) void {
        self.release(allocator);
        self.rows.deinit(allocator);
        self.* = .{};
    }
};

pub fn begin(self: *Loop, runner: Hooks.Runner, input: Hooks.Invocation, pending: Pending) !void {
    self.hook_flow.dispatch = try Hooks.Dispatch.start(self.allocator, runner, input);
    self.hook_flow.pending = pending;
    self.state = .running_hooks;
}

pub fn start(self: *Loop, invocation: Hooks.Invocation, pending: Pending) !bool {
    const runner = self.hooks orelse return false;
    if (runner.set.forEvent(invocation.event).len == 0) return false;
    try begin(self, runner.*, try exportHookInput(self, invocation), pending);
    return true;
}

pub fn observeHook(self: *Loop, invocation: Hooks.Invocation) void {
    const runner = self.hooks orelse return;
    if (runner.set.forEvent(invocation.event).len == 0) return;
    const input = exportHookInput(self, invocation) catch hookInput(self, invocation);
    runner.observe(input) catch |err| {
        if (runner.runtime) |runtime| runtime.notice(@errorName(err)) catch {};
    };
}

pub fn notifyHook(self: *Loop, kind: Hooks.NotificationType, message: []const u8) void {
    observeHook(self, .{ .event = .notification, .notification_type = @tagName(kind), .message = message });
}

pub fn acceptHookResult(self: *Loop, result: *const Hooks.Result) !void {
    if (result.message) |message| {
        self.hook_flow.setNotice(self.allocator, try self.allocator.dupe(u8, message));
    }
    if (result.context) |context| {
        const combined = if (self.hook_flow.context) |old|
            try std.fmt.allocPrint(self.allocator, HooksCopy.join_lines, .{ old, context })
        else
            try self.allocator.dupe(u8, context);
        if (self.hook_flow.context) |old| self.allocator.free(old);
        self.hook_flow.context = combined;
        if (self.hooks) |runner| {
            if (runner.runtime) |runtime| {
                var bounded: Hooks.Result = .{ .context = self.hook_flow.context };
                try runtime.bound(self.allocator, &bounded);
                self.hook_flow.context = bounded.context;
            }
        }
    }
}

pub fn pollHookFiles(self: *Loop, force: bool) !void {
    try self.hook_flow.watch.poll(self.io, force);
    while (self.hook_flow.watch.take(.file_changed)) |change| observeHook(self, .{ .event = .file_changed, .file_path = change.path, .event_type = change.kind });
}

pub fn trackModel(self: *Loop, source: Hooks.ModelSwitchSource) !void {
    if (self.hook_flow.model) |old| {
        if (std.mem.eql(u8, old, self.provider.model)) return;
    }
    const current = try self.allocator.dupe(u8, self.provider.model);
    if (self.hook_flow.model) |old| {
        observeHook(self, .{ .event = .post_model_switch, .from_model = old, .to_model = current, .source = @tagName(source) });
        self.allocator.free(old);
    }
    self.hook_flow.model = current;
}

pub fn lifecycle(self: *Loop, event: Hooks.Event, next: Resume) !bool {
    return start(self, .{
        .event = event,
        .source = @tagName(self.hook_flow.session_source),
        .trigger = self.hook_flow.compaction.trigger(),
    }, .{ .lifecycle = next });
}

test "transcript export reuses unchanged rows and preserves a retained snapshot" {
    const testing = std.testing;
    const a = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var runtime: Hooks.Runtime = .{ .allocator = a, .io = io, .temp_root = root };
    defer runtime.deinit();
    var transcript: Transcript = .{};
    defer transcript.deinit(a);
    var calls = [_]Conversation.ToolCall{.{ .id = "c1", .name = "read", .arguments = "{}" }};
    const messages = [_]Conversation.Message{
        .{ .seq = 0, .role = .user, .text = "Read the document" },
        .{ .seq = 1, .role = .assistant, .text = "", .tool_calls = &calls },
    };
    const directory = std.Io.Dir.cwd();
    const limit: std.Io.Limit = .limited(transcript_buffer_bytes);

    const first = try transcript.exportSnapshot(a, &runtime, messages[0..1]);
    const path = try a.dupe(u8, first);
    defer a.free(path);
    const unchanged = try transcript.exportSnapshot(a, &runtime, messages[0..1]);
    try testing.expectEqualStrings(path, unchanged);
    const appended = try transcript.exportSnapshot(a, &runtime, &messages);
    try testing.expectEqualStrings(path, appended);

    calls[0].status = .ok;
    calls[0].result = "complete";
    const updated = try transcript.exportSnapshot(a, &runtime, &messages);
    try testing.expectEqualStrings(path, updated);
    const old = try directory.readFileAlloc(io, path, a, limit);
    defer a.free(old);
    try testing.expect(std.mem.indexOf(u8, old, "\"result\":\"complete\"") != null);

    runtime.retainSnapshot(path);
    defer runtime.releaseSnapshot(path);
    const shortened = try transcript.exportSnapshot(a, &runtime, messages[0..1]);
    try testing.expect(!std.mem.eql(u8, path, shortened));
    const still_retained = try directory.readFileAlloc(io, path, a, limit);
    defer a.free(still_retained);
    try testing.expectEqualStrings(old, still_retained);
    const current = try directory.readFileAlloc(io, shortened, a, limit);
    defer a.free(current);
    try testing.expectEqualStrings("{\"seq\":0,\"role\":\"user\",\"text\":\"Read the document\",\"tool_calls\":[]}\n", current);
    runtime.releaseSnapshot(path);
    try testing.expectError(error.FileNotFound, directory.access(io, path, .{}));
}

const std = @import("std");
const Hooks = @import("../core/hooks.zig");
const HookWatch = @import("../core/hook_watch.zig");
const Flow = @This();
const Loop = @import("loop.zig");
const Database = @import("../core/database.zig");

pub const Compaction = enum { manual, idle, during_turn };
pub const Resume = enum { begin_prompt, ask_model, compact, compact_session, after_compact, finish_turn, config_idle, failed_turn };
pub const Pending = union(enum) {
    prompt,
    steering,
    expansion,
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
identity: [32]u8 = @splat(0),
notice: ?[]u8 = null,
failure: ?[]u8 = null,
export_path: ?[]u8 = null,
session_handle: ?[]const u8 = null,

pub fn setNotice(self: *Flow, allocator: std.mem.Allocator, notice: ?[]u8) void {
    if (self.notice) |old| allocator.free(old);
    self.notice = notice;
}

pub fn reset(self: *Flow) void {
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

pub fn hookInput(self: *Loop, invocation: Hooks.Invocation) Hooks.Invocation {
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
    const path = try runtime.privatePath(self.allocator, "jsonl");
    errdefer self.allocator.free(path);
    const file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(self.io);
    errdefer std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(self.io, &buffer);
    for (self.conversation.messages.items) |message| {
        try std.json.Stringify.value(.{ .seq = message.seq, .role = message.role, .text = message.text, .tool_calls = message.tool_calls }, .{}, &writer.interface);
        try writer.interface.writeByte('\n');
    }
    try writer.interface.flush();
    try runtime.registerSnapshot(path);
    if (self.hook_flow.export_path) |old| {
        runtime.releaseSnapshot(old);
        self.allocator.free(old);
    }
    self.hook_flow.export_path = path;
    input.transcript_path = path;
    return input;
}

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

pub fn notifyHook(self: *Loop, kind: []const u8, message: []const u8) void {
    observeHook(self, .{ .event = .notification, .notification_type = kind, .message = message });
}

pub fn acceptHookResult(self: *Loop, result: *const Hooks.Result) !void {
    if (result.message) |message| {
        self.hook_flow.setNotice(self.allocator, try self.allocator.dupe(u8, message));
    }
    if (result.context) |context| {
        const combined = if (self.hook_flow.context) |old|
            try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ old, context })
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

pub fn trackModel(self: *Loop, source: []const u8) !void {
    if (self.hook_flow.model) |old| {
        if (std.mem.eql(u8, old, self.provider.model)) return;
    }
    const current = try self.allocator.dupe(u8, self.provider.model);
    if (self.hook_flow.model) |old| {
        observeHook(self, .{ .event = .post_model_switch, .from_model = old, .to_model = current, .source = source });
        self.allocator.free(old);
    }
    self.hook_flow.model = current;
}

pub fn lifecycle(self: *Loop, event: Hooks.Event, next: Resume) !bool {
    return start(self, .{
        .event = event,
        .source = @tagName(self.hook_flow.session_source),
        .trigger = if (self.hook_flow.compaction != .manual) "auto" else "manual",
    }, .{ .lifecycle = next });
}

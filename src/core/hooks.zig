const std = @import("std");
const builtin = @import("builtin");
pub const Result = @import("hook_result.zig").Result;
const output = @import("hook_result.zig");
const regex = @import("regex.zig");
const ansi = @import("ansi.zig");

const stderr_limit: usize = 64 * 1024;
const poll_slice_ms: u64 = 100;
pub const default_timeout_ms: u64 = 30_000;
pub const cleanup_timeout_ms: i64 = 3000;
const posix_signals = switch (builtin.os.tag) {
    .windows, .wasi => false,
    else => true,
};

pub const Event = enum {
    session_start,
    session_end,
    user_prompt_submit,
    pre_tool_use,
    permission_request,
    post_tool_use,
    pre_compact,
    post_compact,
    subagent_start,
    subagent_stop,
    stop,
    interrupt,
    pre_model_request,
    post_model_request,
    post_tool_use_failure,
    post_tool_batch,
    permission_denied,
    stop_failure,
    notification,
    instructions_loaded,
    config_change,
    file_changed,
    pre_model_switch,
    post_model_switch,
    task_created,
    task_completed,
    user_prompt_expansion,
    message_display,
    cwd_changed,
    directory_added,
    model_retry,
    http_response,
    http_request,
    permission_evaluate,
    model_settings,
    model_context,
    model_resolve,

    pub fn name(self: Event) []const u8 {
        inline for (std.meta.fields(Event)) |field| {
            if (self == @field(Event, field.name)) return comptime wireName(field.name);
        }
        unreachable;
    }
    pub fn oneOf(self: Event, choices: []const Event) bool {
        for (choices) |choice| if (self == choice) return true;
        return false;
    }
    pub fn fromName(value: []const u8) ?Event {
        inline for (std.meta.tags(Event)) |event| {
            if (std.mem.eql(u8, event.name(), value)) return event;
        }
        return null;
    }
    pub fn matcherValue(self: Event, input: Invocation) ?[]const u8 {
        if (self.toolMatcher()) return input.tool_name;
        return switch (self) {
            .session_start, .config_change, .directory_added => input.source,
            .session_end => input.reason,
            .notification => input.notification_type,
            .subagent_start, .subagent_stop => input.agent_type,
            .pre_compact, .post_compact => input.trigger,
            .instructions_loaded => input.load_reason,
            .pre_model_switch, .post_model_switch => input.to_model,
            .stop_failure => input.error_type,
            .file_changed => std.fs.path.basename(input.file_path),
            else => null,
        };
    }

    pub fn requestStage(self: Event) bool {
        return switch (self) {
            .model_resolve, .model_context, .model_settings, .model_retry, .http_request, .http_response => true,
            else => false,
        };
    }

    pub fn observational(self: Event) bool {
        return switch (self) {
            .session_end, .interrupt, .subagent_start, .pre_model_request, .post_model_request, .post_tool_use_failure, .permission_denied, .stop_failure, .notification, .instructions_loaded, .file_changed, .post_model_switch, .message_display, .cwd_changed, .directory_added => true,
            else => false,
        };
    }

    pub fn toolMatcher(self: Event) bool {
        return self == .pre_tool_use or self == .post_tool_use or self == .post_tool_use_failure or self == .permission_request or self == .permission_denied or self == .permission_evaluate;
    }
};

fn wireName(comptime tag: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(20_000);
        var buffer: [tag.len]u8 = undefined;
        var length = 0;
        var upper = true;
        for (tag) |letter| {
            if (letter == '_') {
                upper = true;
                continue;
            }
            buffer[length] = if (upper) std.ascii.toUpper(letter) else letter;
            upper = false;
            length += 1;
        }
        return std.fmt.comptimePrint("{s}", .{buffer[0..length]});
    }
}

pub const AgentScope = enum { main, subagent };
pub const RequestPurpose = @import("model_policy.zig").Purpose;

pub const When = struct {
    agent_scope: ?AgentScope = null,
    request_purpose: ?RequestPurpose = null,
    agent_type: ?[]const u8 = null,
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,

    pub fn accepts(self: When, input: Invocation) bool {
        if (self.agent_scope) |value| if (value != input.agent_scope) return false;
        if (self.request_purpose) |value| if (value != input.request_purpose) return false;
        inline for (.{ "agent_type", "model", "provider" }) |field| {
            if (@field(self, field)) |value| if (!std.mem.eql(u8, value, @field(input, field))) return false;
        }
        return true;
    }
};

fn parseWhen(allocator: std.mem.Allocator, value: std.json.Value) !When {
    if (value != .object or value.object.count() == 0) return error.InvalidHookFilter;
    var fields = value.object.iterator();
    while (fields.next()) |field| {
        if (field.value_ptr.* != .string or field.value_ptr.string.len == 0) return error.InvalidHookFilter;
    }
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    return std.json.parseFromSliceLeaky(When, allocator, encoded, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidHookFilter,
    };
}

pub const Hook = struct {
    matcher: []const u8 = "",
    command: []const u8 = "",
    legacy: bool = true,
    id: []const u8 = "",
    trusted: bool = true,
    enabled: bool = true,
    transcript: bool = false,
    stream: bool = false,
    source: []const u8 = "config",
    timeout_ms: ?u64 = null,
    async: bool = false,
    type: enum { command, mcp_tool } = .command,
    server: []const u8 = "",
    tool: []const u8 = "",
    arguments: std.json.Value = .null,
    when: ?When = null,

    pub fn jsonStringify(self: Hook, writer: anytype) !void {
        // Absent filters must preserve previously trusted declaration bytes.
        try writer.beginObject();
        inline for (std.meta.fields(Hook)) |field| {
            if ((!std.mem.eql(u8, field.name, "when") or self.when != null) and (!std.mem.eql(u8, field.name, "stream") or self.stream)) {
                try writer.objectField(field.name);
                try writer.write(@field(self, field.name));
            }
        }
        try writer.endObject();
    }
};

pub const Set = struct {
    session_start: []const Hook = &.{},
    session_end: []const Hook = &.{},
    user_prompt_submit: []const Hook = &.{},
    pre_tool_use: []const Hook = &.{},
    permission_request: []const Hook = &.{},
    post_tool_use: []const Hook = &.{},
    pre_compact: []const Hook = &.{},
    post_compact: []const Hook = &.{},
    subagent_start: []const Hook = &.{},
    subagent_stop: []const Hook = &.{},
    stop: []const Hook = &.{},
    interrupt: []const Hook = &.{},
    pre_model_request: []const Hook = &.{},
    post_model_request: []const Hook = &.{},

    post_tool_use_failure: []const Hook = &.{},
    post_tool_batch: []const Hook = &.{},
    permission_denied: []const Hook = &.{},
    stop_failure: []const Hook = &.{},
    notification: []const Hook = &.{},
    instructions_loaded: []const Hook = &.{},
    config_change: []const Hook = &.{},
    file_changed: []const Hook = &.{},
    pre_model_switch: []const Hook = &.{},
    post_model_switch: []const Hook = &.{},
    task_created: []const Hook = &.{},
    task_completed: []const Hook = &.{},
    user_prompt_expansion: []const Hook = &.{},
    message_display: []const Hook = &.{},
    cwd_changed: []const Hook = &.{},
    directory_added: []const Hook = &.{},
    model_retry: []const Hook = &.{},
    http_response: []const Hook = &.{},
    http_request: []const Hook = &.{},
    permission_evaluate: []const Hook = &.{},
    model_settings: []const Hook = &.{},
    model_context: []const Hook = &.{},
    model_resolve: []const Hook = &.{},

    pub fn hasUntrusted(self: Set) bool {
        inline for (std.meta.fields(Set)) |field| {
            for (@field(self, field.name)) |hook| if (hook.enabled and !hook.trusted) return true;
        }
        return false;
    }

    pub fn forEvent(self: Set, event: Event) []const Hook {
        inline for (std.meta.fields(Event)) |field| {
            if (event == @field(Event, field.name)) return @field(self, field.name);
        }
        unreachable;
    }
    pub fn append(self: *Set, allocator: std.mem.Allocator, other: Set) !void {
        inline for (std.meta.fields(Set)) |field| {
            const old = @field(self, field.name);
            const added = @field(other, field.name);
            if (added.len > 0) @field(self, field.name) = try std.mem.concat(allocator, Hook, &.{ old, added });
        }
    }
};

pub fn effectiveTimeout(event: Event, fallback: u64, hook: Hook) u64 {
    if (event == .session_end or event == .interrupt) return @min(hook.timeout_ms orelse 1000, 3000);
    if (event == .message_display and fallback == default_timeout_ms) return hook.timeout_ms orelse 10_000;
    return hook.timeout_ms orelse fallback;
}

pub fn validTimeout(value: u64) !void {
    if (value == 0 or value > 86_400_000) return error.InvalidHookTimeout;
}

pub fn parse(allocator: std.mem.Allocator, value: std.json.Value, source: []const u8) !Set {
    if (value != .object) return error.InvalidHooks;
    var set: Set = .{};
    var entries = value.object.iterator();
    while (entries.next()) |entry| {
        const event = Event.fromName(entry.key_ptr.*) orelse return error.InvalidHookEvent;
        if (entry.value_ptr.* != .array) return error.InvalidHooks;
        var hooks: std.ArrayList(Hook) = .empty;
        for (entry.value_ptr.array.items) |definition| {
            if (definition != .object) return error.InvalidHooks;
            try parseDeclaration(allocator, definition, event, source, &hooks);
        }
        inline for (std.meta.fields(Set)) |field| {
            if (event == @field(Event, field.name)) @field(set, field.name) = hooks.items;
        }
    }
    return set;
}

const Declaration = struct { event: Event, source: []const u8, matcher: []const u8, when: ?When };

fn parseDeclaration(a: std.mem.Allocator, value: std.json.Value, event: Event, source: []const u8, hooks: *std.ArrayList(Hook)) !void {
    const matcher = if (value.object.get("matcher")) |field| matcher: {
        if (field != .string) return error.InvalidHookMatcher;
        break :matcher field.string;
    } else "";
    const filter = if (value.object.get("when")) |field| try parseWhen(a, field) else null;
    const declaration: Declaration = .{ .event = event, .source = source, .matcher = matcher, .when = filter };
    if (event == .file_changed and std.mem.indexOfAny(u8, matcher, "/\\") != null) return error.InvalidHookMatcher;
    if (value.object.get("hooks")) |group| {
        if (group != .array or value.object.contains("command")) return error.InvalidHooks;
        var fields = value.object.iterator();
        while (fields.next()) |field| {
            const key = field.key_ptr.*;
            const valid = std.mem.eql(u8, key, "matcher") or std.mem.eql(u8, key, "hooks") or std.mem.eql(u8, key, "when");
            if (!valid) return error.InvalidHookDefinition;
        }
        for (group.array.items) |handler| try hooks.append(a, try parseHandler(a, handler, declaration, false));
    } else try hooks.append(a, try parseHandler(a, value, declaration, true));
}

fn parseHandler(a: std.mem.Allocator, value: std.json.Value, declaration: Declaration, legacy: bool) !Hook {
    try validateDefinition(value, legacy);
    const encoded = try std.json.Stringify.valueAlloc(a, value, .{});
    var hook = try std.json.parseFromSliceLeaky(Hook, a, encoded, .{});
    hook.source = declaration.source;
    hook.matcher = declaration.matcher;
    hook.when = declaration.when;
    hook.legacy = legacy;
    if (hook.type == .command and hook.command.len == 0) return error.InvalidHooks;
    if (legacy and (hook.type != .command or hook.async)) return error.InvalidHooks;
    if (hook.type == .mcp_tool) {
        if (hook.server.len == 0 or hook.tool.len == 0 or !value.object.contains("arguments")) return error.InvalidHookDefinition;
        if (hook.arguments != .object and hook.arguments != .string) return error.InvalidHookDefinition;
        if (hook.async) return error.AsyncMcpHookUnsupported;
        if (declaration.event == .session_end) return error.SessionEndMcpHookUnsupported;
    } else if (hook.server.len > 0 or hook.tool.len > 0 or hook.arguments != .null) return error.InvalidHookDefinition;
    if (hook.async and (declaration.event.requestStage() or declaration.event == .permission_evaluate)) return error.InvalidHookAsync;
    if (hook.async and declaration.event == .session_end) return error.AsyncSessionEndHookUnsupported;
    if (hook.timeout_ms) |ms| try validTimeout(ms);
    const has_pattern = !legacy and declaration.event.matcherValue(.{ .event = declaration.event }) != null and declaration.event != .file_changed and hook.matcher.len > 0 and !std.mem.eql(u8, hook.matcher, "*");
    if (has_pattern) {
        var compiled = try compileMatcher(a, hook.matcher);
        compiled.deinit();
    }
    return hook;
}

fn validateDefinition(value: std.json.Value, legacy: bool) !void {
    if (value != .object) return error.InvalidHooks;
    if (value.object.get("type")) |kind| {
        if (kind != .string) return error.InvalidHookDefinition;
        if (!std.mem.eql(u8, kind.string, "command") and !std.mem.eql(u8, kind.string, "mcp_tool")) return error.UnsupportedHookHandlerType;
    }
    const kind = if (value.object.get("type")) |v| v.string else "command";
    var entries = value.object.iterator();
    while (entries.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, kind, "mcp_tool")) {
            if (std.mem.eql(u8, key, "command")) return error.InvalidHookDefinition;
        } else if (std.mem.eql(u8, key, "server") or std.mem.eql(u8, key, "tool") or std.mem.eql(u8, key, "arguments")) return error.InvalidHookDefinition;
        if (legacy) {
            if (std.mem.eql(u8, key, "matcher") or std.mem.eql(u8, key, "command") or std.mem.eql(u8, key, "timeout_ms") or std.mem.eql(u8, key, "transcript") or std.mem.eql(u8, key, "stream") or std.mem.eql(u8, key, "when")) continue;
            return error.InvalidHookDefinition;
        }
        var valid = false;
        inline for (.{ "type", "command", "timeout_ms", "async", "stream", "server", "tool", "arguments", "transcript" }) |allowed| {
            if (std.mem.eql(u8, key, allowed)) valid = true;
        }
        if (!valid) return error.InvalidHookDefinition;
    }
}

pub const Invocation = struct {
    request_system: []const u8 = "",
    request_instruction: []const u8 = "",
    request_tools: []const u8 = "",
    request_routes: []const u8 = "",
    permission_effect: []const u8 = "",
    action: []const u8 = "",
    http: []const u8 = "",
    route: []const u8 = "",
    request_context: []const u8 = "",
    request_settings: []const u8 = "",
    http_status: u16 = 0,
    retry_delay_ms: u64 = 0,
    retry_allowed: bool = false,
    event: Event,
    agent_scope: AgentScope = .main,
    request_purpose: RequestPurpose = .agent,
    provider: []const u8 = "",
    parent_agent_id: []const u8 = "",
    parent_tool_call_id: []const u8 = "",
    cwd: ?[]const u8 = null,
    old_cwd: []const u8 = "",
    new_cwd: []const u8 = "",
    directory: []const u8 = "",
    prompt: []const u8 = "",
    tool_name: []const u8 = "",
    tool_input: []const u8 = "{}",
    tool_response: []const u8 = "",
    session_id: []const u8 = "",
    turn_id: []const u8 = "",
    tool_call_id: []const u8 = "",
    agent_id: []const u8 = "",
    agent_type: []const u8 = "",
    model: []const u8 = "",
    permission_mode: []const u8 = "ask",
    source: []const u8 = "",
    trigger: []const u8 = "",
    stop_hook_active: bool = false,
    status: []const u8 = "",
    error_message: []const u8 = "",
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    transcript_path: ?[]const u8 = null,
    last_assistant_message: ?[]const u8 = null,
    parent_session_id: []const u8 = "",
    reason: []const u8 = "",
    request_id: u64 = 0,
    attempt: u32 = 0,
    tool_calls: []const u8 = "[]",
    error_type: []const u8 = "",
    is_interrupt: bool = false,
    duration_ms: i64 = 0,
    notification_type: []const u8 = "",
    message: []const u8 = "",
    title: []const u8 = "",
    file_path: []const u8 = "",
    event_type: []const u8 = "",
    load_reason: []const u8 = "",
    memory_type: []const u8 = "",
    from_model: []const u8 = "",
    to_model: []const u8 = "",
    requested_model: ?[]const u8 = null,
    task_id: []const u8 = "",
    task_subject: []const u8 = "",
    task_description: []const u8 = "",
    command_name: []const u8 = "",
    command_args: []const u8 = "",
    expanded_prompt: []const u8 = "",
    message_id: []const u8 = "",
    index: usize = 0,
    final: bool = false,
    delta: []const u8 = "",

    pub fn dupe(self: Invocation, arena: std.mem.Allocator) !Invocation {
        var copy = self;
        inline for (std.meta.fields(Invocation)) |field| {
            if (field.type == []const u8) @field(copy, field.name) = try arena.dupe(u8, @field(self, field.name));
            if (field.type == ?[]const u8) {
                if (@field(self, field.name)) |value| @field(copy, field.name) = try arena.dupe(u8, value);
            }
        }
        return copy;
    }
};

pub const Record = struct {
    id: [64]u8 = @splat(0),
    event: Event,
    agent_scope: AgentScope = .main,
    request_purpose: RequestPurpose = .agent,
    duration_ms: i64,
    status: []const u8,
    exit_code: ?u8 = null,
    error_name: []const u8 = "",
    request_id: u64 = 0,
    attempt: u32 = 0,
    agent_id: [64]u8 = @splat(0),
    session_id: [64]u8 = @splat(0),
    turn_id: [64]u8 = @splat(0),
    call_id: [64]u8 = @splat(0),
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    active: std.atomic.Value(usize) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    background: std.ArrayList(*Job) = .empty,
    background_mutex: std.Io.Mutex = .init,
    records: [64]Record = undefined,
    records_len: usize = 0,
    records_next: usize = 0,
    records_mutex: std.Io.Mutex = .init,
    pending: Result = .{},
    deliveries: std.ArrayList(Delivery) = .empty,

    temp_dir: ?[]u8 = null,
    temp_mutex: std.Io.Mutex = .init,
    snapshots: std.StringHashMapUnmanaged(usize) = .empty,

    const Delivery = struct { agent_id: []u8, result: Result = .{} };

    fn enter(self: *Runtime, stop: ?*const std.atomic.Value(bool), deadline_ms: ?i64) !void {
        while (true) {
            if (self.stop.load(.acquire)) return error.Cancelled;
            if (deadline_ms) |deadline| if (std.Io.Clock.now(.awake, self.io).toMilliseconds() >= deadline) return error.Timeout;
            if (stop) |flag| if (flag.load(.acquire)) return error.Cancelled;
            const active = self.active.load(.acquire);
            if (active < 8 and self.active.cmpxchgWeak(active, active + 1, .acq_rel, .acquire) == null) return;
            try std.Io.sleep(self.io, .fromMilliseconds(5), .awake);
        }
    }
    fn leave(self: *Runtime) void {
        _ = self.active.fetchSub(1, .release);
    }
    fn record(self: *Runtime, hook: Hook, invocation: Invocation, started: i64, status: []const u8, exit_code: ?u8, error_name: []const u8) void {
        self.records_mutex.lockUncancelable(self.io);
        defer self.records_mutex.unlock(self.io);
        var record_value: Record = .{ .event = invocation.event, .duration_ms = std.Io.Clock.now(.awake, self.io).toMilliseconds() - started, .status = status };
        record_value.agent_scope = invocation.agent_scope;
        record_value.request_purpose = invocation.request_purpose;
        record_value.exit_code = exit_code;
        record_value.request_id = invocation.request_id;
        record_value.attempt = invocation.attempt;
        record_value.error_name = error_name;
        inline for (.{ .{ "session_id", "session_id" }, .{ "turn_id", "turn_id" }, .{ "call_id", "tool_call_id" }, .{ "agent_id", "agent_id" } }) |pair| {
            const value = @field(invocation, pair[1]);
            const length = @min(64, value.len);
            @memcpy(@field(record_value, pair[0])[0..length], value[0..length]);
        }
        @memcpy(record_value.id[0..@min(64, hook.id.len)], hook.id[0..@min(64, hook.id.len)]);
        self.records[self.records_next] = record_value;
        self.records_next = (self.records_next + 1) % self.records.len;
        self.records_len = @min(self.records_len + 1, self.records.len);
    }
    fn launch(self: *Runtime, runner: Runner, hook: Hook, invocation: Invocation) !void {
        self.background_mutex.lockUncancelable(self.io);
        defer self.background_mutex.unlock(self.io);
        var i: usize = 0;
        while (i < self.background.items.len) {
            const job = self.background.items[i];
            if (!job.done.load(.acquire)) {
                i += 1;
                continue;
            }
            _ = self.background.orderedRemove(i);
            defer job.destroy();
            job.join();
            try self.collect(job);
        }
        if (self.background.items.len >= 64) return error.BackgroundHookLimit;
        var session_runner = runner;
        session_runner.stop = &self.stop;
        const job = try Job.start(self.allocator, session_runner, hook, invocation);
        errdefer job.destroy();
        try self.background.append(self.allocator, job);
    }
    fn collect(self: *Runtime, job: *Job) !void {
        if (job.failed) |err| {
            const message = try std.fmt.allocPrint(self.allocator, "Background hook failed: {s}", .{@errorName(err)});
            if (self.pending.message) |old| self.allocator.free(old);
            self.pending.message = message;
            return;
        }
        if (job.result.blocked != null or job.result.replacement != null or job.result.permission != null or job.result.feedback != null or job.result.stop or job.result.retry or job.result.display_content != null) {
            if (job.result.message) |old| job.arena.allocator().free(old);
            job.result.message = try job.arena.allocator().dupe(u8, "Background hook control effects were ignored");
        }
        job.result.blocked = null;
        job.result.replacement = null;
        job.result.feedback = null;
        job.result.permission = null;
        job.result.stop = false;
        job.result.retry = false;
        job.result.display_content = null;
        var destination: ?*Result = &self.pending;
        if (job.invocation.agent_id.len > 0) {
            destination = null;
            for (self.deliveries.items) |*delivery| {
                if (std.mem.eql(u8, delivery.agent_id, job.invocation.agent_id)) {
                    destination = &delivery.result;
                    break;
                }
            }
            if (destination == null) {
                const id = try self.allocator.dupe(u8, job.invocation.agent_id);
                errdefer self.allocator.free(id);
                try self.deliveries.append(self.allocator, .{ .agent_id = id });
                destination = &self.deliveries.items[self.deliveries.items.len - 1].result;
            }
        }
        try destination.?.merge(self.allocator, job.result);
        try self.bound(self.allocator, destination.?);
    }
    pub fn notice(self: *Runtime, message: []const u8) !void {
        self.background_mutex.lockUncancelable(self.io);
        defer self.background_mutex.unlock(self.io);
        const copy = try self.allocator.dupe(u8, message);
        if (self.pending.message) |old| self.allocator.free(old);
        self.pending.message = copy;
        try self.bound(self.allocator, &self.pending);
    }
    pub fn discardAgent(self: *Runtime, agent_id: []const u8) void {
        self.background_mutex.lockUncancelable(self.io);
        defer self.background_mutex.unlock(self.io);
        var i: usize = 0;
        while (i < self.background.items.len) {
            if (std.mem.eql(u8, self.background.items[i].invocation.agent_id, agent_id)) {
                const job = self.background.orderedRemove(i);
                job.destroy();
            } else i += 1;
        }
        i = 0;
        while (i < self.deliveries.items.len) {
            if (std.mem.eql(u8, self.deliveries.items[i].agent_id, agent_id)) {
                var delivery = self.deliveries.orderedRemove(i);
                self.allocator.free(delivery.agent_id);
                delivery.result.deinit(self.allocator);
            } else i += 1;
        }
    }
    pub fn drainFor(self: *Runtime, allocator: std.mem.Allocator, agent_id: []const u8) !Result {
        self.background_mutex.lockUncancelable(self.io);
        defer self.background_mutex.unlock(self.io);
        var i: usize = 0;
        while (i < self.background.items.len) {
            const job = self.background.items[i];
            if (!job.done.load(.acquire)) {
                i += 1;
                continue;
            }
            _ = self.background.orderedRemove(i);
            defer job.destroy();
            job.join();
            try self.collect(job);
        }
        var result: Result = .{};
        errdefer result.deinit(allocator);
        if (agent_id.len == 0) {
            try result.merge(allocator, self.pending);
            self.pending.deinit(self.allocator);
        } else if (self.pending.message) |message| {
            result.message = try allocator.dupe(u8, message);
            self.allocator.free(message);
            self.pending.message = null;
        }
        i = 0;
        while (i < self.deliveries.items.len) {
            if (std.mem.eql(u8, self.deliveries.items[i].agent_id, agent_id)) {
                var delivery = self.deliveries.orderedRemove(i);
                defer self.allocator.free(delivery.agent_id);
                defer delivery.result.deinit(self.allocator);
                try result.merge(allocator, delivery.result);
            } else i += 1;
        }
        return result;
    }
    pub fn registerSnapshot(self: *Runtime, path: []const u8) !void {
        self.temp_mutex.lockUncancelable(self.io);
        defer self.temp_mutex.unlock(self.io);
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        try self.snapshots.put(self.allocator, key, 1);
    }
    pub fn retainSnapshot(self: *Runtime, path: ?[]const u8) void {
        const key = path orelse return;
        self.temp_mutex.lockUncancelable(self.io);
        defer self.temp_mutex.unlock(self.io);
        if (self.snapshots.getPtr(key)) |refs| refs.* += 1;
    }
    pub fn releaseSnapshot(self: *Runtime, path: ?[]const u8) void {
        const key = path orelse return;
        self.temp_mutex.lockUncancelable(self.io);
        defer self.temp_mutex.unlock(self.io);
        const refs = self.snapshots.getPtr(key) orelse return;
        refs.* -= 1;
        if (refs.* != 0) return;
        const removed = self.snapshots.fetchRemove(key).?;
        std.Io.Dir.cwd().deleteFile(self.io, key) catch {};
        self.allocator.free(removed.key);
    }
    pub fn privatePath(self: *Runtime, allocator: std.mem.Allocator, extension: []const u8) ![]u8 {
        self.temp_mutex.lockUncancelable(self.io);
        defer self.temp_mutex.unlock(self.io);
        var nonce: [16]u8 = undefined;
        self.io.random(&nonce);
        if (self.temp_dir == null) {
            const path = try std.fmt.allocPrint(self.allocator, "/tmp/synth-hooks-{s}", .{std.fmt.bytesToHex(nonce, .lower)});
            errdefer self.allocator.free(path);
            try std.Io.Dir.cwd().createDir(self.io, path, .fromMode(0o700));
            self.temp_dir = path;
            self.io.random(&nonce);
        }
        return std.fmt.allocPrint(allocator, "{s}/{s}.{s}", .{ self.temp_dir.?, std.fmt.bytesToHex(nonce, .lower), extension });
    }
    pub fn bound(self: *Runtime, allocator: std.mem.Allocator, result: *Result) !void {
        inline for (.{ "context", "message", "blocked", "feedback" }) |field| {
            if (@field(result, field)) |value| {
                if (value.len > 8192) {
                    const path = try self.privatePath(allocator, "txt");
                    defer allocator.free(path);
                    const file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .exclusive = true, .permissions = .fromMode(0o600) });
                    defer file.close(self.io);
                    var buffer: [4096]u8 = undefined;
                    var writer = file.writer(self.io, &buffer);
                    try writer.interface.writeAll(value);
                    try writer.interface.flush();
                    var preview_end: usize = 4096;
                    while (preview_end > 0 and value[preview_end] & 0xc0 == 0x80) preview_end -= 1;
                    const preview = try std.fmt.allocPrint(allocator, "{s}\n[Full hook output: {s}]", .{ value[0..preview_end], path });
                    allocator.free(value);
                    @field(result, field) = preview;
                }
            }
        }
    }
    pub fn cancelBackground(self: *Runtime) void {
        self.stop.store(true, .release);
        self.background_mutex.lockUncancelable(self.io);
        defer self.background_mutex.unlock(self.io);
        for (self.background.items) |job| job.destroy();
        self.background.clearRetainingCapacity();
        for (self.deliveries.items) |*delivery| {
            self.allocator.free(delivery.agent_id);
            delivery.result.deinit(self.allocator);
        }
        self.deliveries.clearRetainingCapacity();
        self.pending.deinit(self.allocator);
        self.stop.store(false, .release);
    }
    pub fn deinit(self: *Runtime) void {
        self.cancelBackground();
        self.background.deinit(self.allocator);
        self.deliveries.deinit(self.allocator);
        self.deliveries = .empty;
        self.background = .empty;
        self.pending.deinit(self.allocator);
        var snapshots = self.snapshots.keyIterator();
        while (snapshots.next()) |key| self.allocator.free(key.*);
        self.snapshots.deinit(self.allocator);
        if (self.temp_dir) |path| {
            std.Io.Dir.cwd().deleteTree(self.io, path) catch {};
            self.allocator.free(path);
            self.temp_dir = null;
        }
    }
};

const Job = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    runner: Runner,
    hook: Hook,
    invocation: Invocation,
    result: Result = .{},
    failed: ?anyerror = null,
    future: std.Io.Future(void) = undefined,
    joined: bool = false,
    done: std.atomic.Value(bool) = .init(false),

    fn start(allocator: std.mem.Allocator, runner: Runner, hook: Hook, invocation: Invocation) !*Job {
        const self = try allocator.create(Job);
        self.* = .{ .allocator = allocator, .arena = .init(allocator), .runner = runner, .hook = hook, .invocation = invocation };
        errdefer {
            self.arena.deinit();
            allocator.destroy(self);
        }
        self.invocation = try invocation.dupe(self.arena.allocator());
        if (runner.runtime) |runtime| runtime.retainSnapshot(self.invocation.transcript_path);
        errdefer if (runner.runtime) |runtime| runtime.releaseSnapshot(self.invocation.transcript_path);
        self.future = try runner.io.concurrent(run, .{self});
        return self;
    }
    fn run(self: *Job) void {
        defer {
            self.done.store(true, .release);
        }
        self.result = self.runner.runHook(self.arena.allocator(), self.hook, self.invocation) catch |err| {
            self.failed = err;
            return;
        };
    }
    fn join(self: *Job) void {
        if (self.joined) return;
        self.future.await(self.runner.io);
        self.joined = true;
    }
    fn destroy(self: *Job) void {
        if (!self.joined) self.future.cancel(self.runner.io);
        if (self.runner.runtime) |runtime| runtime.releaseSnapshot(self.invocation.transcript_path);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
};

pub const Runner = struct {
    io: std.Io,
    root: []const u8,
    set: Set,
    timeout_ms: u64 = default_timeout_ms,
    runtime: ?*Runtime = null,
    deadline_ms: ?i64 = null,
    mcp_executor: ?McpExecutor = null,

    /// Raised when the turn is cancelled. Checked between hooks and on every
    /// slice of the wait for one, so a cancel lands without needing the signal
    /// that interrupts a blocked syscall to arrive first.
    stop: ?*const std.atomic.Value(bool) = null,

    pub const McpExecutor = struct {
        userdata: *anyopaque,
        call: *const fn (*anyopaque, std.mem.Allocator, Hook, []const u8, u64, ?*const std.atomic.Value(bool)) anyerror![]const u8,
    };

    fn givenUp(self: Runner) bool {
        const flag = self.stop orelse return false;
        return flag.load(.acquire);
    }

    pub fn hasMatching(self: Runner, allocator: std.mem.Allocator, invocation: Invocation, require_trust: bool) bool {
        for (self.set.forEvent(invocation.event)) |hook| {
            if (!hook.enabled or (require_trust and !hook.trusted)) continue;
            if (hookMatches(allocator, hook, invocation) catch false) return true;
        }
        return false;
    }

    pub fn observe(self: Runner, invocation: Invocation) !void {
        if (!invocation.event.observational()) return error.InvalidHookEvent;
        const runtime = self.runtime orelse return;
        for (self.set.forEvent(invocation.event)) |hook| {
            if (!hook.enabled) continue;
            if (!try hookMatches(runtime.allocator, hook, invocation)) continue;
            if (!hook.trusted) {
                try runtime.notice("Hooks need review; an observation handler was not executed");
                continue;
            }
            try runtime.launch(self, hook, invocation);
        }
    }

    pub fn dispatch(self: Runner, allocator: std.mem.Allocator, invocation: Invocation) !?[]u8 {
        var result = try self.evaluate(allocator, invocation);
        defer result.deinit(allocator);
        const blocked = result.blocked;
        result.blocked = null;
        return blocked;
    }

    pub fn evaluate(self: Runner, allocator: std.mem.Allocator, invocation: Invocation) !Result {
        var outcome: Result = .{};
        errdefer outcome.deinit(allocator);
        var inherited: std.ArrayList(Hook) = .empty;
        defer inherited.deinit(allocator);
        var inherited_count: usize = 0;
        if (invocation.event == .post_tool_use_failure) {
            for (self.set.post_tool_use) |hook| if (hook.legacy) try inherited.append(allocator, hook);
            inherited_count = inherited.items.len;
            try inherited.appendSlice(allocator, self.set.post_tool_use_failure);
        }
        const definitions = if (invocation.event == .post_tool_use_failure) inherited.items else self.set.forEvent(invocation.event);
        var at: usize = 0;
        var failure: ?anyerror = null;
        var failure_at: usize = std.math.maxInt(usize);
        var legacy_blocked = false;
        while (at < definitions.len) {
            const hook = definitions[at];
            if (hook.enabled and hook.async and (invocation.event.requestStage() or invocation.event == .permission_evaluate)) return error.InvalidHookAsync;
            if (self.givenUp()) return error.Cancelled;
            if (!hook.enabled) {
                at += 1;
                continue;
            }
            const matched = hookMatches(allocator, hook, invocation) catch |err| {
                if (err == error.OutOfMemory) return err;
                if (at < failure_at) {
                    failure = err;
                    failure_at = at;
                }
                if (self.runtime) |runtime| runtime.record(hook, invocation, std.Io.Clock.now(.awake, self.io).toMilliseconds(), "failed", null, @errorName(err));
                at += 1;
                continue;
            };
            if (!matched) {
                at += 1;
                continue;
            }
            if (!hook.trusted) {
                if (at < failure_at) {
                    failure = error.HookNeedsReview;
                    failure_at = at;
                }
                at += 1;
                continue;
            }
            if (hook.legacy) {
                if (legacy_blocked) {
                    at += 1;
                    continue;
                }
                var legacy_input = invocation;
                if (at < inherited_count) legacy_input.event = .post_tool_use;
                var result = self.runHook(allocator, hook, legacy_input) catch |err| {
                    if (at < failure_at) {
                        failure = err;
                        failure_at = at;
                    }
                    legacy_blocked = true;
                    at += 1;
                    continue;
                };
                legacy_blocked = result.blocked != null;
                defer result.deinit(allocator);
                try outcome.merge(allocator, result);
                if (self.runtime) |runtime| try runtime.bound(allocator, &outcome);
                at += 1;
                continue;
            }
            const start = at;
            var end = at;
            while (end < definitions.len and !definitions[end].legacy) : (end += 1) {}
            const jobs = try allocator.alloc(?*Job, end - start);
            @memset(jobs, null);
            defer {
                for (jobs) |maybe| if (maybe) |job| {
                    job.destroy();
                };
                allocator.free(jobs);
            }
            var slots: [8]?*Job = @splat(null);
            var running: usize = 0;
            var pending: usize = 0;
            var merged = start;
            while (at < end or running > 0) {
                if (self.givenUp()) return error.Cancelled;
                while (at < end and running < slots.len and pending < 64) : (at += 1) {
                    const grouped = definitions[at];
                    if (!grouped.enabled) continue;
                    const grouped_match = hookMatches(allocator, grouped, invocation) catch |err| {
                        if (err == error.OutOfMemory) return err;
                        if (at < failure_at) {
                            failure = err;
                            failure_at = at;
                        }
                        if (self.runtime) |runtime| runtime.record(grouped, invocation, std.Io.Clock.now(.awake, self.io).toMilliseconds(), "failed", null, @errorName(err));
                        continue;
                    };
                    if (!grouped_match) continue;
                    if (!grouped.trusted) {
                        if (at < failure_at) {
                            failure = error.HookNeedsReview;
                            failure_at = at;
                        }
                        continue;
                    }
                    if (grouped.async and (invocation.event.requestStage() or invocation.event == .permission_evaluate)) return error.InvalidHookAsync;
                    if (grouped.async) {
                        const runtime = self.runtime orelse return error.BackgroundHooksUnavailable;
                        try runtime.launch(self, grouped, invocation);
                    } else {
                        const job = try Job.start(allocator, self, grouped, invocation);
                        jobs[at - start] = job;
                        for (&slots) |*slot| {
                            if (slot.* == null) {
                                slot.* = job;
                                break;
                            }
                        }
                        running += 1;
                        pending += 1;
                    }
                }
                var progressed = false;
                for (&slots) |*slot| {
                    const job = slot.* orelse continue;
                    if (!job.done.load(.acquire)) continue;
                    job.join();
                    slot.* = null;
                    running -= 1;
                    progressed = true;
                    if (job.failed != null) continue;
                }
                while (merged < at) : (merged += 1) {
                    const job = jobs[merged - start] orelse continue;
                    if (!job.joined) break;
                    if (job.failed) |err| {
                        if (merged < failure_at) {
                            failure = err;
                            failure_at = merged;
                        }
                    } else try outcome.merge(allocator, job.result);
                    if (self.runtime) |runtime| try runtime.bound(allocator, &outcome);
                    job.destroy();
                    jobs[merged - start] = null;
                    pending -= 1;
                }
                if (!progressed and running > 0) try std.Io.sleep(self.io, .fromMilliseconds(1), .awake);
            }
        }
        if (failure) |err| {
            const strict = invocation.event.requestStage() or invocation.event == .permission_evaluate or switch (invocation.event) {
                .session_start, .user_prompt_submit, .pre_tool_use, .permission_request, .pre_compact, .post_compact, .post_tool_batch, .task_created, .task_completed, .pre_model_switch, .user_prompt_expansion, .config_change => true,
                else => false,
            };
            if (strict or err == error.OutOfMemory) return err;
            var diagnostic: Result = .{ .message = try std.fmt.allocPrint(allocator, "{s} hook failed: {s}", .{ invocation.event.name(), @errorName(err) }) };
            defer diagnostic.deinit(allocator);
            try outcome.merge(allocator, diagnostic);
        }
        if (self.runtime) |runtime| try runtime.bound(allocator, &outcome);
        return outcome;
    }

    fn runHook(self: Runner, allocator: std.mem.Allocator, hook: Hook, invocation: Invocation) !Result {
        if (self.runtime) |runtime| try runtime.enter(self.stop, self.deadline_ms);
        defer if (self.runtime) |runtime| runtime.leave();
        var configured = self;
        configured.timeout_ms = effectiveTimeout(invocation.event, self.timeout_ms, hook);
        const started = std.Io.Clock.now(.awake, self.io).toMilliseconds();
        if (self.deadline_ms) |deadline| {
            if (started >= deadline) return error.Timeout;
            configured.timeout_ms = @min(configured.timeout_ms, @as(u64, @intCast(deadline - started)));
        }
        if (self.runtime) |runtime| runtime.record(hook, invocation, started, "started", null, "");
        var exit_code: ?u8 = null;
        var result = configured.executeHook(allocator, hook, invocation, &exit_code) catch |err| {
            if (self.runtime) |runtime| runtime.record(hook, invocation, started, "failed", exit_code, @errorName(err));
            return err;
        };
        errdefer result.deinit(allocator);
        if (self.runtime) |runtime| {
            runtime.bound(allocator, &result) catch |err| {
                runtime.record(hook, invocation, started, "failed", exit_code, @errorName(err));
                return err;
            };
            runtime.record(hook, invocation, started, "completed", exit_code, "");
        }
        return result;
    }

    fn executeHook(self: Runner, allocator: std.mem.Allocator, hook: Hook, invocation: Invocation, exit_code: *?u8) !Result {
        const command = if (hook.type == .command)
            try self.runCommand(allocator, hook.command, invocation)
        else blk: {
            const executor = self.mcp_executor orelse return error.McpHooksUnavailable;
            var arena: std.heap.ArenaAllocator = .init(allocator);
            defer arena.deinit();
            var payload: std.Io.Writer.Allocating = .init(arena.allocator());
            try writeJson(arena.allocator(), &payload.writer, self.root, invocation);
            const input = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), payload.written(), .{});
            const expanded = try @import("hook_interpolation.zig").expand(arena.allocator(), hook.arguments, input);
            if (expanded != .object) return error.InvalidHookMcpArguments;
            const args = try std.json.Stringify.valueAlloc(arena.allocator(), expanded, .{});
            const response = try executor.call(executor.userdata, allocator, hook, args, self.timeout_ms, self.stop);
            errdefer allocator.free(response);
            break :blk CommandResult{ .code = 0, .stdout = response, .stderr = try allocator.dupe(u8, ""), .overflow = response.len > stderr_limit };
        };
        exit_code.* = command.code;
        defer allocator.free(command.stderr);
        defer allocator.free(command.stdout);
        if (!hook.legacy and command.overflow) return error.HookOutputTooLarge;
        var result: Result = .{};
        errdefer result.deinit(allocator);
        if (command.code == 126 or command.code == 127) return error.HookCommandUnavailable;
        const advisory = invocation.event.observational();
        if (command.code == 2 and advisory and !(hook.legacy and invocation.event == .post_tool_use_failure)) {
            result.message = try allocator.dupe(u8, "Observation hook exited 2; control effect ignored");
        } else if (command.code == 2 and ((invocation.event != .post_tool_use and invocation.event != .post_tool_use_failure) or !hook.legacy)) {
            const reason = std.mem.trim(u8, command.stderr, " \t\r\n");
            result.blocked = try allocator.dupe(u8, if (reason.len > 0) reason else "blocked by hook");
        } else if (!hook.legacy and command.code == 0) {
            result = try output.parse(allocator, command.stdout, invocation.event);
        }
        if (result.feedback != null and !std.mem.startsWith(u8, invocation.tool_name, "mcp__")) return error.UnsupportedHookEffect;
        inline for (.{ "context", "blocked", "feedback" }) |field| {
            if (@field(result, field)) |text_value| {
                if (!hook.legacy or !std.mem.eql(u8, field, "blocked") or invocation.event == .stop or invocation.event == .subagent_stop) {
                    const attributed = try std.fmt.allocPrint(allocator, "[Hook {s}{s}]\n{s}", .{ hook.source, if (hook.type == .mcp_tool) " / external MCP tool" else "", text_value });
                    allocator.free(text_value);
                    @field(result, field) = attributed;
                }
            }
        }
        inline for (.{ "context", "message", "blocked", "feedback", "display_content" }) |field| {
            if (@field(result, field)) |value| {
                if (ansi.hasControls(value)) {
                    const cleaned = try ansi.clean(allocator, value);
                    allocator.free(value);
                    @field(result, field) = cleaned;
                }
            }
        }
        if (invocation.event.requestStage()) {
            if (result.blocked) |blocked| {
                if (self.runtime) |runtime| try runtime.notice(blocked);
                return error.HookBlocked;
            }
        }
        return result;
    }

    const CommandResult = struct {
        code: u8,
        stderr: []u8,
        stdout: []const u8,
        overflow: bool,
    };

    fn runCommand(
        self: Runner,
        allocator: std.mem.Allocator,
        command: []const u8,
        invocation: Invocation,
    ) !CommandResult {
        var dir = try std.Io.Dir.cwd().openDir(self.io, self.root, .{});
        defer dir.close(self.io);

        var payload_writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer payload_writer.deinit();
        try writeJson(allocator, &payload_writer.writer, self.root, invocation);
        try payload_writer.writer.writeByte('\n');
        const payload = try payload_writer.toOwnedSlice();
        defer allocator.free(payload);

        if (self.givenUp()) return error.Cancelled;
        var child = try std.process.spawn(self.io, .{
            .argv = &.{ "bash", "-lc", command },
            .cwd = .{ .dir = dir },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (posix_signals) 0 else null,
        });
        var reaped = false;
        defer if (!reaped) killGroup(self.io, &child);

        var input: InputWrite = .{ .io = self.io, .child = &child, .payload = payload };
        var input_future = try self.io.concurrent(InputWrite.run, .{&input});
        defer input_future.cancel(self.io);

        var buffers: std.Io.File.MultiReader.Buffer(2) = undefined;
        var readers: std.Io.File.MultiReader = undefined;
        readers.init(allocator, self.io, buffers.toStreams(), &.{ child.stderr.?, child.stdout.? });
        defer readers.deinit();

        const stderr_reader = readers.reader(0);
        const stdout_reader = readers.reader(1);
        var stdout_writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer stdout_writer.deinit();
        var overflow = false;
        var stderr_writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer stderr_writer.deinit();
        const deadline = std.Io.Clock.now(.awake, self.io).toMilliseconds() + @as(i64, @intCast(self.timeout_ms));
        var stderr_done = false;

        while (!stderr_done or !input.done.isSet()) {
            // Returning runs the `killGroup` defer, taking the whole group.
            if (self.givenUp()) return error.Cancelled;
            const left = deadline - std.Io.Clock.now(.awake, self.io).toMilliseconds();
            if (left <= 0) return error.Timeout;
            const slice = @min(poll_slice_ms, @as(u64, @intCast(left)));

            if (stderr_done) {
                input.done.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(slice)), .clock = .awake } }) catch |err| switch (err) {
                    error.Timeout => {},
                    else => return err,
                };
            } else {
                readers.fill(64, .{ .duration = .{
                    .raw = .fromMilliseconds(@intCast(slice)),
                    .clock = .awake,
                } }) catch |err| switch (err) {
                    error.EndOfStream => stderr_done = true,
                    error.Timeout => {},
                    else => |other| return other,
                };
                const buffered = stderr_reader.buffered();
                const remaining = stderr_limit - stderr_writer.written().len;
                try stderr_writer.writer.writeAll(buffered[0..@min(buffered.len, remaining)]);
                stderr_reader.tossBuffered();
                const out_buffered = stdout_reader.buffered();
                const out_remaining = stderr_limit - stdout_writer.written().len;
                overflow = overflow or out_buffered.len > out_remaining;
                try stdout_writer.writer.writeAll(out_buffered[0..@min(out_buffered.len, out_remaining)]);
                stdout_reader.tossBuffered();
            }
        }

        input_future.await(self.io);
        try readers.checkAnyError();

        const pid = child.id.?;
        var waiter: ChildWait = .{ .io = self.io, .child = &child };
        var wait_future = try self.io.concurrent(ChildWait.run, .{&waiter});
        var cancelled = false;
        while (!waiter.done.isSet()) {
            const expired = deadline - std.Io.Clock.now(.awake, self.io).toMilliseconds() <= 0;
            if (self.givenUp() or cancelled or expired) {
                if (posix_signals) {
                    std.posix.kill(-pid, .TERM) catch {};
                    std.posix.kill(-pid, .KILL) catch {};
                }
                wait_future.await(self.io);
                reaped = true;
                if (expired) return error.Timeout;
                return error.Cancelled;
            }
            const left = deadline - std.Io.Clock.now(.awake, self.io).toMilliseconds();
            if (left <= 0) continue;
            waiter.done.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(@min(poll_slice_ms, @as(u64, @intCast(left))))), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => cancelled = true,
            };
        }
        wait_future.await(self.io);
        reaped = true;
        if (cancelled or self.givenUp()) return error.Cancelled;
        const term = try waiter.term;
        const stderr = try stderr_writer.toOwnedSlice();
        errdefer allocator.free(stderr);
        const code: u8 = switch (term) {
            .exited => |value| value,
            else => 1,
        };
        return .{ .code = code, .stderr = stderr, .stdout = try stdout_writer.toOwnedSlice(), .overflow = overflow };
    }
};

const ChildWait = struct {
    io: std.Io,
    child: *std.process.Child,
    term: std.process.Child.WaitError!std.process.Child.Term = undefined,
    done: std.Io.Event = .unset,

    fn run(self: *ChildWait) void {
        self.term = self.child.wait(self.io);
        self.done.set(self.io);
    }
};

const InputWrite = struct {
    io: std.Io,
    child: *std.process.Child,
    payload: []const u8,
    done: std.Io.Event = .unset,

    fn run(self: *InputWrite) void {
        defer self.done.set(self.io);
        defer {
            if (self.child.stdin) |stdin| stdin.close(self.io);
            self.child.stdin = null;
        }

        var buffer: [4096]u8 = undefined;
        var writer = self.child.stdin.?.writer(self.io, &buffer);
        writer.interface.writeAll(self.payload) catch return;
        writer.interface.flush() catch return;
    }
};

fn killGroup(io: std.Io, child: *std.process.Child) void {
    const pid = child.id orelse return;
    if (posix_signals) std.posix.kill(-pid, .TERM) catch {};
    child.kill(io);
    if (posix_signals) std.posix.kill(-pid, .KILL) catch {};
}

pub const Dispatch = struct {
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    runner: Runner,
    invocation: Invocation,
    blocked: ?[]u8 = null,
    result: Result = .{},
    failed: ?anyerror = null,
    future: std.Io.Future(void) = undefined,
    done: std.atomic.Value(bool) = .init(false),
    /// Whether the future has been awaited. Cancelling and joining race when a
    /// turn is cancelled off-thread, and the first one there does the wait.
    reaped: bool = false,
    stop: std.atomic.Value(bool) = .init(false),

    pub fn start(allocator: std.mem.Allocator, runner: Runner, invocation: Invocation) !*Dispatch {
        const self = try allocator.create(Dispatch);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .arena = .init(allocator),
            .runner = runner,
            .invocation = invocation,
        };
        errdefer self.arena.deinit();
        self.invocation = try invocation.dupe(self.arena.allocator());
        self.runner.stop = &self.stop;
        if (runner.runtime) |runtime| runtime.retainSnapshot(self.invocation.transcript_path);
        errdefer if (runner.runtime) |runtime| runtime.releaseSnapshot(self.invocation.transcript_path);
        self.future = try runner.io.concurrent(run, .{self});
        return self;
    }

    /// Ask the hooks to stop without waiting for them. Cheap, and safe from
    /// the thread drawing the screen.
    pub fn requestStop(self: *Dispatch) void {
        self.stop.store(true, .release);
    }

    pub fn isFinished(self: *Dispatch) bool {
        return self.done.load(.acquire);
    }

    pub fn join(self: *Dispatch) void {
        if (self.reaped) return;
        self.reaped = true;
        self.future.await(self.runner.io);
    }

    /// Interrupt the hooks and wait for them to unwind. Blocks for as long as
    /// a hook command takes to give up, so never call it from the thread
    /// drawing the screen.
    pub fn cancel(self: *Dispatch) void {
        if (self.reaped) return;
        self.reaped = true;
        self.requestStop();
        self.future.cancel(self.runner.io);
    }

    pub fn takeBlocked(self: *Dispatch) ?[]u8 {
        const blocked = self.blocked;
        self.blocked = null;
        return blocked;
    }

    pub fn destroy(self: *Dispatch) void {
        const allocator = self.allocator;
        if (self.blocked) |blocked| allocator.free(blocked);
        self.result.deinit(allocator);
        if (self.runner.runtime) |runtime| runtime.releaseSnapshot(self.invocation.transcript_path);
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn run(self: *Dispatch) void {
        defer self.done.store(true, .release);
        self.result = self.runner.evaluate(self.allocator, self.invocation) catch |err| {
            self.failed = err;
            return;
        };
        self.blocked = self.result.blocked;
        self.result.blocked = null;
    }
};

fn compileMatcher(allocator: std.mem.Allocator, pattern: []const u8) !regex.Regex {
    if (std.mem.indexOf(u8, pattern, "(?") != null) return error.UnsupportedHookRegex;
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        if (pattern[index] == '\\' and index + 1 < pattern.len) {
            index += 1;
            if (std.ascii.isAlphanumeric(pattern[index]) and std.mem.indexOfScalar(u8, "dDwWsSbBntr0", pattern[index]) == null) return error.UnsupportedHookRegex;
        }
    }
    return regex.compile(allocator, pattern, .{});
}

fn hookMatches(allocator: std.mem.Allocator, hook: Hook, invocation: Invocation) !bool {
    if (hook.when) |filter| if (!filter.accepts(invocation)) return false;
    const value = invocation.event.matcherValue(invocation) orelse return true;
    if (hook.legacy) return matches(hook.matcher, value);
    if (hook.matcher.len == 0 or std.mem.eql(u8, hook.matcher, "*")) return true;
    if (invocation.event == .file_changed) {
        var names = std.mem.tokenizeScalar(u8, hook.matcher, '|');
        while (names.next()) |name| if (std.mem.eql(u8, value, name)) return true;
        return false;
    }
    var compiled = try compileMatcher(allocator, hook.matcher);
    defer compiled.deinit();
    if (try compiled.checkedMatches(value)) return true;
    if (!invocation.event.toolMatcher()) return false;
    const alias: []const u8 = if (std.mem.eql(u8, invocation.tool_name, "bash")) "Bash" else if (std.mem.eql(u8, invocation.tool_name, "read")) "Read" else if (std.mem.eql(u8, invocation.tool_name, "write")) "Write" else if (std.mem.eql(u8, invocation.tool_name, "edit")) "Edit" else if (std.mem.eql(u8, invocation.tool_name, "task")) "Agent" else "";
    return alias.len > 0 and try compiled.checkedMatches(alias);
}

fn matches(matcher: []const u8, tool_name: []const u8) bool {
    if (matcher.len == 0) return true;
    return std.mem.eql(u8, matcher, tool_name);
}

fn writeJson(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    root: []const u8,
    invocation: Invocation,
) !void {
    try w.writeAll("{\"hook_event_name\":");
    try std.json.Stringify.encodeJsonString(invocation.event.name(), .{}, w);
    try w.writeAll(",\"cwd\":");
    try std.json.Stringify.encodeJsonString(invocation.cwd orelse root, .{}, w);

    try w.writeAll(",\"agent_scope\":");
    try std.json.Stringify.value(invocation.agent_scope, .{}, w);
    try w.writeAll(",\"request_purpose\":");
    try std.json.Stringify.value(invocation.request_purpose, .{}, w);
    inline for (.{ "request_system", "request_instruction", "request_tools", "request_routes", "permission_effect", "action", "http", "route", "request_context", "request_settings", "provider", "parent_agent_id", "parent_tool_call_id", "old_cwd", "new_cwd", "directory", "session_id", "turn_id", "tool_call_id", "agent_id", "agent_type", "model", "permission_mode", "source", "trigger", "status", "error_type", "error_message", "parent_session_id", "reason", "notification_type", "message", "title", "file_path", "event_type", "load_reason", "memory_type", "from_model", "to_model", "task_id", "task_subject", "task_description", "command_name", "command_args", "expanded_prompt", "message_id", "delta" }) |field| {
        try w.writeAll(",\"" ++ field ++ "\":");
        try std.json.Stringify.encodeJsonString(@field(invocation, field), .{}, w);
    }
    try w.writeAll(",\"tool_use_id\":");
    try std.json.Stringify.encodeJsonString(invocation.tool_call_id, .{}, w);
    try w.writeAll(",\"requested_model\":");
    try std.json.Stringify.value(invocation.requested_model, .{}, w);
    try w.writeAll(",\"last_assistant_message\":");
    try std.json.Stringify.value(invocation.last_assistant_message, .{}, w);
    try w.print(",\"http_status\":{d},\"retry_delay_ms\":{d},\"retry_allowed\":{s}", .{ invocation.http_status, invocation.retry_delay_ms, if (invocation.retry_allowed) "true" else "false" });
    try w.print(",\"request_id\":{d},\"attempt\":{d}", .{ invocation.request_id, invocation.attempt });
    if (invocation.event == .subagent_stop) {
        try w.writeAll(",\"agent_transcript_path\":");
        try std.json.Stringify.value(invocation.transcript_path, .{}, w);
    }
    try w.writeAll(",\"transcript_path\":");
    try std.json.Stringify.value(invocation.transcript_path, .{}, w);
    try w.print(",\"stop_hook_active\":{s},\"input_tokens\":{d},\"output_tokens\":{d}", .{ if (invocation.stop_hook_active) "true" else "false", invocation.input_tokens, invocation.output_tokens });
    if (invocation.event == .user_prompt_submit or invocation.event == .user_prompt_expansion) {
        try w.writeAll(",\"prompt\":");
        try std.json.Stringify.encodeJsonString(invocation.prompt, .{}, w);
    }
    if (invocation.event.toolMatcher()) {
        try w.writeAll(",\"tool_name\":");
        try std.json.Stringify.encodeJsonString(invocation.tool_name, .{}, w);
        try w.writeAll(",\"tool_input\":");
        if (try std.json.validate(allocator, invocation.tool_input)) {
            try w.writeAll(invocation.tool_input);
        } else {
            try w.writeAll("{}");
        }
    }
    if (invocation.event == .post_tool_use or invocation.event == .post_tool_use_failure) {
        try w.writeAll(",\"tool_response\":");
        try std.json.Stringify.encodeJsonString(invocation.tool_response, .{}, w);
    }
    try w.writeAll(",\"error\":");
    try std.json.Stringify.encodeJsonString(if (invocation.error_type.len > 0) invocation.error_type else invocation.error_message, .{}, w);
    try w.writeAll(",\"error_details\":");
    try std.json.Stringify.encodeJsonString(invocation.error_message, .{}, w);
    try w.print(",\"is_interrupt\":{s},\"duration_ms\":{d},\"index\":{d},\"final\":{s}", .{ if (invocation.is_interrupt) "true" else "false", invocation.duration_ms, invocation.index, if (invocation.final) "true" else "false" });
    if (invocation.event == .file_changed) {
        try w.writeAll(",\"event\":");
        try std.json.Stringify.encodeJsonString(invocation.event_type, .{}, w);
    }
    if (invocation.event == .post_tool_batch) {
        try w.writeAll(",\"tool_calls\":");
        if (try std.json.validate(allocator, invocation.tool_calls)) try w.writeAll(invocation.tool_calls) else try w.writeAll("[]");
    }
    try w.writeByte('}');
}

test "a matching pre-tool hook can block" {
    const testing = std.testing;
    const hook = Hook{ .matcher = "bash", .command = "read payload; echo blocked by policy >&2; exit 2" };
    const runner: Runner = .{
        .io = testing.io,
        .root = ".",
        .set = .{ .pre_tool_use = &.{hook} },
    };

    const reason = try runner.dispatch(testing.allocator, .{
        .event = .pre_tool_use,
        .tool_name = "bash",
        .tool_input = "{\"command\":\"make\"}",
    });
    defer if (reason) |text| testing.allocator.free(text);
    try testing.expectEqualStrings("blocked by policy", reason.?);
}

test "a hook with closed pipes still times out" {
    const testing = std.testing;
    if (!posix_signals) return error.SkipZigTest;
    const runner: Runner = .{
        .io = testing.io,
        .root = ".",
        .set = .{ .user_prompt_submit = &.{.{ .command = "exec 0<&- 2>&-; sleep 2" }} },
        .timeout_ms = 50,
    };
    const started: std.Io.Timestamp = .now(testing.io, .awake);
    try testing.expectError(error.Timeout, runner.dispatch(testing.allocator, .{ .event = .user_prompt_submit }));
    try testing.expect(started.durationTo(.now(testing.io, .awake)).nanoseconds < std.time.ns_per_s);
}

test "raising the stop flag ends a hook that would otherwise run on" {
    const testing = std.testing;
    if (!posix_signals) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(testing.io, &root_buffer)];

    // Outlasts both the test and the timeout, so only the flag can end it.
    const hook = Hook{ .command = "read payload; sleep 30" };
    var stop: std.atomic.Value(bool) = .init(false);
    const runner: Runner = .{
        .io = testing.io,
        .root = root,
        .set = .{ .user_prompt_submit = &.{hook} },
        .timeout_ms = 60_000,
        .stop = &stop,
    };

    var raiser: StopAfter = .{ .io = testing.io, .flag = &stop };
    var future = try testing.io.concurrent(StopAfter.run, .{&raiser});
    defer future.await(testing.io);

    const started: std.Io.Timestamp = .now(testing.io, .awake);
    try testing.expectError(
        error.Cancelled,
        runner.dispatch(testing.allocator, .{ .event = .user_prompt_submit, .prompt = "go" }),
    );
    const elapsed = started.durationTo(.now(testing.io, .awake)).nanoseconds;
    try testing.expect(elapsed < 5 * std.time.ns_per_s);
}

/// Raises a stop flag once the command under test is certainly running.
const StopAfter = struct {
    io: std.Io,
    flag: *std.atomic.Value(bool),

    fn run(self: *StopAfter) void {
        std.Io.sleep(self.io, .fromMilliseconds(150), .awake) catch {};
        self.flag.store(true, .release);
    }
};

test "a matcher leaves other tools alone" {
    const testing = std.testing;
    const hook = Hook{ .matcher = "write", .command = "exit 2" };
    const runner: Runner = .{
        .io = testing.io,
        .root = ".",
        .set = .{ .pre_tool_use = &.{hook} },
    };
    try testing.expect(try runner.dispatch(testing.allocator, .{ .event = .pre_tool_use, .tool_name = "read" }) == null);
}

test "large input and stderr cannot block each other" {
    const testing = std.testing;
    const prompt = try testing.allocator.alloc(u8, 128 * 1024);
    defer testing.allocator.free(prompt);
    @memset(prompt, 'x');

    const hook = Hook{
        .command = "i=0; while [ $i -lt 16384 ]; do printf 12345678 >&2; i=$((i + 1)); done; exit 2",
    };
    const runner: Runner = .{
        .io = testing.io,
        .root = ".",
        .set = .{ .user_prompt_submit = &.{hook} },
        .timeout_ms = 2_000,
    };

    const reason = try runner.dispatch(testing.allocator, .{
        .event = .user_prompt_submit,
        .prompt = prompt,
    });
    defer if (reason) |text| testing.allocator.free(text);
    try testing.expectEqual(stderr_limit, reason.?.len);
}

test "a hook is killed when its deadline passes" {
    const testing = std.testing;
    const hook = Hook{ .command = "sleep 5" };
    const runner: Runner = .{
        .io = testing.io,
        .root = ".",
        .set = .{ .user_prompt_submit = &.{hook} },
        .timeout_ms = 50,
    };

    try testing.expectError(error.Timeout, runner.dispatch(testing.allocator, .{
        .event = .user_prompt_submit,
        .prompt = "hello",
    }));
}

test "grouped output is structured while legacy stdout stays ignored" {
    const a = std.testing.allocator;
    const command = "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":{\"command\":\"echo safe\"},\"additionalContext\":\"from policy\"}}'";
    var runner: Runner = .{ .io = std.testing.io, .root = ".", .set = .{ .pre_tool_use = &.{.{ .command = command }} } };
    var legacy = try runner.evaluate(a, .{ .event = .pre_tool_use });
    defer legacy.deinit(a);
    try std.testing.expect(legacy.replacement == null);
    runner.set.pre_tool_use = &.{.{ .command = command, .legacy = false, .source = "test policy" }};
    var grouped = try runner.evaluate(a, .{ .event = .pre_tool_use });
    defer grouped.deinit(a);
    try std.testing.expectEqualStrings("{\"command\":\"echo safe\"}", grouped.replacement.?);
    try std.testing.expectEqualStrings("[Hook test policy]\nfrom policy", grouped.context.?);
}

test "oversized structured stdout is drained and rejected" {
    const runner: Runner = .{ .io = std.testing.io, .root = ".", .set = .{ .pre_tool_use = &.{.{ .legacy = false, .command = "head -c 131072 /dev/zero; head -c 131072 /dev/zero >&2" }} } };
    try std.testing.expectError(error.HookOutputTooLarge, runner.evaluate(std.testing.allocator, .{ .event = .pre_tool_use }));
}

test "grouped config normalizes without changing legacy declarations" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"PreToolUse\":[{\"matcher\":\"read\",\"command\":\"true\"},{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"true\",\"timeout_ms\":50}]}]}", .{});
    const set = try parse(a, value, "test.json");
    try std.testing.expect(set.pre_tool_use[0].legacy);
    try std.testing.expect(!set.pre_tool_use[1].legacy);
    try std.testing.expectEqualStrings("test.json", set.pre_tool_use[1].source);
    try std.testing.expectEqual(@as(?u64, 50), set.pre_tool_use[1].timeout_ms);
    try std.testing.expectError(error.InvalidHookTimeout, validTimeout(0));
    try std.testing.expectError(error.InvalidHookTimeout, validTimeout(std.math.maxInt(u64)));
}

test "event payload keeps empty fields and a nullable transcript" {
    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try writeJson(std.testing.allocator, &writer.writer, ".", .{ .event = .post_tool_use });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("", parsed.value.object.get("tool_response").?.string);
    try std.testing.expect(parsed.value.object.get("transcript_path").? == .null);
    try std.testing.expectEqualStrings("", parsed.value.object.get("session_id").?.string);
}

test "grouped hooks run despite denial and apply rewrites in declaration order" {
    const a = std.testing.allocator;
    const first: Hook = .{ .legacy = false, .command = "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"first\",\"updatedInput\":{\"command\":\"first\"}}}'" };
    const last: Hook = .{ .legacy = false, .command = "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"last\",\"updatedInput\":{\"command\":\"last\"}}}'" };
    const deny: Hook = .{ .legacy = false, .command = "echo denied >&2; exit 2" };
    const runner: Runner = .{ .io = std.testing.io, .root = ".", .set = .{ .pre_tool_use = &.{ first, deny, last } } };
    var result = try runner.evaluate(a, .{ .event = .pre_tool_use });
    defer result.deinit(a);
    try std.testing.expect(result.blocked != null);
    try std.testing.expect(std.mem.indexOf(u8, result.context.?, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.context.?, "last") != null);
    try std.testing.expectEqualStrings("{\"command\":\"last\"}", result.replacement.?);
}

test "grouped matcher accepts aliases and alternation" {
    const a = std.testing.allocator;
    const hook: Hook = .{ .legacy = false, .matcher = "^(Bash|bash|Edit)$", .command = "true" };
    try std.testing.expect(try hookMatches(a, hook, .{ .event = .pre_tool_use, .tool_name = "bash" }));
    try std.testing.expect(try hookMatches(a, hook, .{ .event = .pre_tool_use, .tool_name = "edit" }));
    try std.testing.expect(!try hookMatches(a, hook, .{ .event = .pre_tool_use, .tool_name = "read" }));
    try std.testing.expectError(error.UnsupportedHookRegex, compileMatcher(a, "(?=bash)"));
    try std.testing.expectError(error.UnsupportedHookRegex, compileMatcher(a, "(bash)\\1"));
}

test "background output waits for a boundary and has no control authority" {
    const a = std.testing.allocator;
    var runtime: Runtime = .{ .allocator = a, .io = std.testing.io };
    defer runtime.deinit();
    const hook: Hook = .{ .legacy = false, .async = true, .command = "printf '%s' '{\"decision\":\"block\",\"reason\":\"ignored\",\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"additionalContext\":\"background context\"}}'" };
    const runner: Runner = .{ .io = std.testing.io, .root = ".", .runtime = &runtime, .set = .{ .pre_tool_use = &.{hook} } };
    var immediate = try runner.evaluate(a, .{ .event = .pre_tool_use });
    defer immediate.deinit(a);
    try std.testing.expect(immediate.blocked == null);
    try std.testing.expect(immediate.context == null);
    runtime.background.items[0].join();
    var delivered = try runtime.drainFor(a, "");
    defer delivered.deinit(a);
    try std.testing.expect(delivered.blocked == null);
    try std.testing.expect(std.mem.indexOf(u8, delivered.context.?, "background context") != null);
    try std.testing.expectEqualStrings("Background hook control effects were ignored", delivered.message.?);
}

test "large hook context spills to an owner-only file" {
    const a = std.testing.allocator;
    var runtime: Runtime = .{ .allocator = a, .io = std.testing.io };
    defer runtime.deinit();
    var result: Result = .{ .context = try a.alloc(u8, 20_000) };
    defer result.deinit(a);
    @memset(result.context.?, 'x');
    try runtime.bound(a, &result);
    try std.testing.expect(result.context.?.len < 8192);
    const start = std.mem.indexOf(u8, result.context.?, "/tmp/synth-hooks-").?;
    const path = result.context.?[start .. result.context.?.len - 1];
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(u64, 20_000), stat.size);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "concurrent dispatches share the session admission bound" {
    const Probe = struct {
        active: std.atomic.Value(usize) = .init(0),
        peak: std.atomic.Value(usize) = .init(0),
        fn call(raw: *anyopaque, a: std.mem.Allocator, _: Hook, _: []const u8, _: u64, _: ?*const std.atomic.Value(bool)) ![]const u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const count = self.active.fetchAdd(1, .acq_rel) + 1;
            _ = self.peak.fetchMax(count, .acq_rel);
            defer _ = self.active.fetchSub(1, .release);
            try std.Io.sleep(std.testing.io, .fromMilliseconds(40), .awake);
            return a.dupe(u8, "{}");
        }
    };
    const a = std.testing.allocator;
    var probe: Probe = .{};
    var runtime: Runtime = .{ .allocator = a, .io = std.testing.io };
    defer runtime.deinit();
    const definitions = [_]Hook{.{ .legacy = false, .matcher = "^(Bash|bash)$", .type = .mcp_tool, .arguments = .{ .object = .empty }, .server = "test", .tool = "guard" }} ** 8;
    const runner: Runner = .{ .io = std.testing.io, .root = ".", .runtime = &runtime, .mcp_executor = .{ .userdata = &probe, .call = Probe.call }, .set = .{ .pre_tool_use = &definitions } };
    const first = try Dispatch.start(a, runner, .{ .event = .pre_tool_use, .tool_name = "bash" });
    defer first.destroy();
    const second = try Dispatch.start(a, runner, .{ .event = .pre_tool_use, .tool_name = "bash" });
    defer second.destroy();
    first.join();
    second.join();
    try std.testing.expect(first.failed == null);
    try std.testing.expect(second.failed == null);
    try std.testing.expect(probe.peak.load(.acquire) > 1);
    try std.testing.expect(probe.peak.load(.acquire) <= 8);
}

test "cancellation while queued prevents a command from starting" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    var runtime: Runtime = .{ .allocator = a, .io = std.testing.io };
    defer runtime.deinit();
    runtime.active.store(8, .release);
    const runner: Runner = .{ .io = std.testing.io, .root = root, .runtime = &runtime, .set = .{ .pre_tool_use = &.{.{ .legacy = false, .command = "touch launched" }} } };
    const dispatch = try Dispatch.start(a, runner, .{ .event = .pre_tool_use });
    defer dispatch.destroy();
    dispatch.requestStop();
    dispatch.join();
    runtime.active.store(0, .release);
    try std.testing.expectEqual(error.Cancelled, dispatch.failed.?);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "launched", .{}));
}

test "protected-path example rejects equivalent paths and symlink targets" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    var runner: Runner = .{ .io = std.testing.io, .root = root, .set = .{} };
    const probe = try runner.runCommand(a, "command -v python3", .{ .event = .pre_tool_use });
    defer a.free(probe.stdout);
    defer a.free(probe.stderr);
    if (probe.code != 0) return error.SkipZigTest;
    const script = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "examples/hooks/protect-paths.sh", a, .limited(16 * 1024));
    defer a.free(script);
    runner.set.pre_tool_use = &.{.{ .command = script }};
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".env", .data = "secret" });
    try tmp.dir.symLink(std.testing.io, ".env", "alias", .{});
    try tmp.dir.createDirPath(std.testing.io, ".github/workflows");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "safe", .data = "content" });
    try tmp.dir.symLink(std.testing.io, "../../safe", ".github/workflows/check.yml", .{});
    const absolute = try std.fs.path.join(a, &.{ root, ".env" });
    defer a.free(absolute);
    for ([_][]const u8{ ".env", "./.env", "nested/../.env", absolute, "alias", ".github/workflows/check.yml" }) |path| {
        const arguments = try std.json.Stringify.valueAlloc(a, .{ .path = path }, .{});
        defer a.free(arguments);
        const denied = try runner.dispatch(a, .{ .event = .pre_tool_use, .tool_name = "write", .tool_input = arguments });
        defer if (denied) |reason| a.free(reason);
        try std.testing.expect(denied != null);
    }
    try std.testing.expect(try runner.dispatch(a, .{ .event = .pre_tool_use, .tool_name = "write", .tool_input = "{\"path\":\"safe\"}" }) == null);
    try tmp.dir.createDir(std.testing.io, "bin", .default_dir);
    try tmp.dir.symLink(std.testing.io, "/bin/cat", "bin/cat", .{});
    const without_jq = try std.fmt.allocPrint(a, "PATH=\"$(pwd -P)/bin\"\n{s}", .{script});
    defer a.free(without_jq);
    runner.set.pre_tool_use = &.{.{ .command = without_jq }};
    const missing_dependency = try runner.dispatch(a, .{ .event = .pre_tool_use, .tool_name = "write", .tool_input = "{\"path\":\".env\"}" });
    defer if (missing_dependency) |reason| a.free(reason);
    try std.testing.expect(missing_dependency != null);
}

test "a deadline kills descendants before they can finish later work" {
    if (!posix_signals) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    const runner: Runner = .{ .io = std.testing.io, .root = root, .timeout_ms = 50, .set = .{ .pre_tool_use = &.{.{ .command = "(sleep 0.3; touch survived) & wait" }} } };
    try std.testing.expectError(error.Timeout, runner.dispatch(std.testing.allocator, .{ .event = .pre_tool_use }));
    try std.Io.sleep(std.testing.io, .fromMilliseconds(400), .awake);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "survived", .{}));
}

test "session shutdown joins a running background command" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    var runtime: Runtime = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    var destroyed = false;
    defer if (!destroyed) runtime.deinit();
    const runner: Runner = .{ .io = std.testing.io, .root = root, .runtime = &runtime, .set = .{ .pre_tool_use = &.{.{ .legacy = false, .async = true, .command = "read payload; echo ready > started; sleep 30" }} } };
    var result = try runner.evaluate(std.testing.allocator, .{ .event = .pre_tool_use });
    defer result.deinit(std.testing.allocator);
    var started = false;
    for (0..200) |_| {
        if (tmp.dir.openFile(std.testing.io, "started", .{})) |file| {
            file.close(std.testing.io);
            started = true;
            break;
        } else |_| {}
        try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    }
    try std.testing.expect(started);
    const before = std.Io.Clock.now(.awake, std.testing.io).toMilliseconds();
    runtime.deinit();
    destroyed = true;
    try std.testing.expect(std.Io.Clock.now(.awake, std.testing.io).toMilliseconds() - before < 1000);
    try std.testing.expectEqual(@as(usize, 0), runtime.active.load(.acquire));
}

test "event input fixtures preserve field values and escaping" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixtures = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("fixtures/hooks/inputs.json"), .{});
    for (fixtures.array.items) |fixture| {
        const event = Event.fromName(fixture.object.get("event").?.string).?;
        var input = fixture.object.get("input").?;
        try input.object.put(a, "event", .{ .string = @tagName(event) });
        const invocation = try std.json.parseFromSliceLeaky(Invocation, a, try std.json.Stringify.valueAlloc(a, input, .{}), .{});
        var writer: std.Io.Writer.Allocating = .init(a);
        try writeJson(a, &writer.writer, ".", invocation);
        const payload = try std.json.parseFromSliceLeaky(std.json.Value, a, writer.written(), .{});
        var expected = fixture.object.get("expected").?.object.iterator();
        while (expected.next()) |field| {
            const actual = payload.object.get(field.key_ptr.*) orelse return error.MissingHookInput;
            try std.testing.expectEqualStrings(try std.json.Stringify.valueAlloc(a, field.value_ptr.*, .{}), try std.json.Stringify.valueAlloc(a, actual, .{}));
        }
    }
}

test "policy regex budget exhaustion fails visibly" {
    const a = std.testing.allocator;
    const input = try a.alloc(u8, 2000);
    defer a.free(input);
    @memset(input, 'a');
    var compiled = try compileMatcher(a, "(a|aa)*b");
    defer compiled.deinit();
    try std.testing.expectError(error.RegexResourceLimit, compiled.checkedMatches(input));
}

test "an observation failure does not discard a sibling's valid feedback" {
    const a = std.testing.allocator;
    const runner: Runner = .{ .io = std.testing.io, .root = ".", .set = .{ .post_tool_use = &.{
        .{ .legacy = false, .command = "printf '%s' '{\"decision\":\"block\",\"reason\":\"verify\"}'" },
        .{ .legacy = false, .command = "printf invalid-json" },
    } } };
    var result = try runner.evaluate(a, .{ .event = .post_tool_use, .tool_name = "read" });
    defer result.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, result.blocked.?, "verify") != null);
    try std.testing.expect(result.message != null);
}

test "legacy lists stop serially without suppressing grouped handlers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    const runner: Runner = .{ .io = std.testing.io, .root = root, .set = .{ .pre_tool_use = &.{
        .{ .command = "printf 'first\\n' >> steps; exit 2" },
        .{ .command = "printf 'must-not-run\\n' >> steps" },
        .{ .legacy = false, .command = "printf 'grouped\\n' >> steps" },
    } } };
    var result = try runner.evaluate(std.testing.allocator, .{ .event = .pre_tool_use });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.blocked != null);
    const steps = try tmp.dir.readFileAlloc(std.testing.io, "steps", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(steps);
    try std.testing.expectEqualStrings("first\ngrouped\n", steps);
}

test "queued handlers start when a slot frees rather than waiting for the whole group" {
    const slow: Hook = .{ .legacy = false, .command = "sleep 0.3; printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":{\"command\":\"slow\"}}}'" };
    const fast: Hook = .{ .legacy = false, .command = "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":{\"command\":\"fast\"}}}'" };
    const definitions = [_]Hook{slow} ++ ([_]Hook{.{ .legacy = false, .command = "true" }} ** 7) ++ [_]Hook{fast};
    const runner: Runner = .{ .io = std.testing.io, .root = ".", .set = .{ .pre_tool_use = &definitions } };
    var result = try runner.evaluate(std.testing.allocator, .{ .event = .pre_tool_use });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{\"command\":\"fast\"}", result.replacement.?);
}

test "grouped failures are reported in declaration order" {
    const runner: Runner = .{ .io = std.testing.io, .root = ".", .set = .{ .pre_tool_use = &.{
        .{ .legacy = false, .command = "sleep 0.05; printf bad" },
        .{ .legacy = false, .type = .mcp_tool, .arguments = .{ .object = .empty }, .server = "missing", .tool = "missing" },
    } } };
    try std.testing.expectError(error.SyntaxError, runner.evaluate(std.testing.allocator, .{ .event = .pre_tool_use }));
}

test "hook notices cannot inject terminal control sequences" {
    const runner: Runner = .{ .io = std.testing.io, .root = ".", .set = .{ .pre_tool_use = &.{.{ .legacy = false, .command = "printf '%s' '{\"systemMessage\":\"\\u001b[31mred\\u001b[0m\"}'" }} } };
    var result = try runner.evaluate(std.testing.allocator, .{ .event = .pre_tool_use });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("red", result.message.?);
}

test "unreviewed hooks do not suppress admitted observation handlers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    const runner: Runner = .{ .io = std.testing.io, .root = root, .set = .{ .session_end = &.{
        .{ .trusted = false, .command = "touch forbidden" },
        .{ .command = "touch admitted" },
    } } };
    var result = try runner.evaluate(std.testing.allocator, .{ .event = .session_end });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.message != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "forbidden", .{}));
    const admitted = try tmp.dir.openFile(std.testing.io, "admitted", .{});
    admitted.close(std.testing.io);
}

test "MCP interpolation must produce an argument object before calling the server" {
    const Executor = struct {
        fn call(_: *anyopaque, _: std.mem.Allocator, _: Hook, _: []const u8, _: u64, _: ?*const std.atomic.Value(bool)) anyerror![]const u8 {
            return error.UnexpectedMcpCall;
        }
    };
    var slot: u8 = 0;
    const hook: Hook = .{ .legacy = false, .type = .mcp_tool, .server = "test", .tool = "guard", .arguments = .{ .string = "${tool_name}" } };
    const runner: Runner = .{ .io = std.testing.io, .root = ".", .mcp_executor = .{ .userdata = &slot, .call = Executor.call }, .set = .{ .pre_tool_use = &.{hook} } };
    try std.testing.expectError(error.InvalidHookMcpArguments, runner.evaluate(std.testing.allocator, .{ .event = .pre_tool_use, .tool_name = "bash" }));
}

test "event matchers filter lifecycle metadata and ignore unsupported matcher fields" {
    const a = std.testing.allocator;
    const cases = [_]struct { input: Invocation, matcher: []const u8 }{
        .{ .input = .{ .event = .session_start, .source = "resume" }, .matcher = "resume|clear" },
        .{ .input = .{ .event = .session_end, .reason = "clear" }, .matcher = "clear" },
        .{ .input = .{ .event = .pre_compact, .trigger = "auto" }, .matcher = "auto" },
        .{ .input = .{ .event = .post_compact, .trigger = "manual" }, .matcher = "manual" },
        .{ .input = .{ .event = .subagent_start, .agent_type = "explore" }, .matcher = "explore" },
        .{ .input = .{ .event = .subagent_stop, .agent_type = "review" }, .matcher = "review" },
        .{ .input = .{ .event = .notification, .notification_type = "permission_prompt" }, .matcher = "permission_prompt" },
        .{ .input = .{ .event = .stop_failure, .error_type = "rate_limit" }, .matcher = "rate_limit" },
        .{ .input = .{ .event = .pre_model_switch, .to_model = "local-model" }, .matcher = "^local-" },
        .{ .input = .{ .event = .post_model_switch, .to_model = "cloud-model" }, .matcher = "^cloud-" },
        .{ .input = .{ .event = .config_change, .source = "project_settings" }, .matcher = "project_settings" },
        .{ .input = .{ .event = .instructions_loaded, .load_reason = "compact" }, .matcher = "compact" },
        .{ .input = .{ .event = .file_changed, .file_path = "/p/.env" }, .matcher = ".env|.envrc" },
        .{ .input = .{ .event = .post_tool_use_failure, .tool_name = "bash" }, .matcher = "Bash" },
        .{ .input = .{ .event = .permission_denied, .tool_name = "write" }, .matcher = "Write" },
    };
    for (cases) |case| {
        try std.testing.expect(try hookMatches(a, .{ .legacy = false, .matcher = case.matcher }, case.input));
        try std.testing.expect(!try hookMatches(a, .{ .legacy = false, .matcher = "unrelated" }, case.input));
    }
    try std.testing.expect(try hookMatches(a, .{ .legacy = false, .matcher = "ignored" }, .{ .event = .post_tool_batch }));
}

test "every supported event has input and result fixtures and parses as configuration" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const inputs = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("fixtures/hooks/inputs.json"), .{});
    const results = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("fixtures/hooks/results.json"), .{});
    inline for (std.meta.fields(Event)) |field| {
        const event: Event = @field(Event, field.name);
        var has_input = false;
        var has_result = false;
        for (inputs.array.items) |item| if (std.mem.eql(u8, item.object.get("event").?.string, event.name())) {
            has_input = true;
        };
        for (results.array.items) |item| if (std.mem.eql(u8, item.object.get("event").?.string, event.name()) and !item.object.contains("invalid")) {
            has_result = true;
        };
        try std.testing.expect(has_input and has_result);
        const source = try std.fmt.allocPrint(a, "{{\"{s}\":[{{\"hooks\":[{{\"type\":\"command\",\"command\":\"true\"}}]}}]}}", .{event.name()});
        const config = try std.json.parseFromSliceLeaky(std.json.Value, a, source, .{});
        const set = try parse(a, config, "fixture");
        try std.testing.expectEqual(@as(usize, 1), set.forEvent(event).len);
    }
    for ([_][]const u8{ "Setup", "TeammateIdle", "WorktreeCreate", "WorktreeRemove", "Elicitation", "ElicitationResult" }) |name| {
        const source = try std.fmt.allocPrint(a, "{{\"{s}\":[]}}", .{name});
        const unsupported = try std.json.parseFromSliceLeaky(std.json.Value, a, source, .{});
        try std.testing.expectError(error.InvalidHookEvent, parse(a, unsupported, "fixture"));
    }
}

test "routing filters require every exact field and compose with event matchers" {
    const a = std.testing.allocator;
    const input: Invocation = .{ .event = .pre_tool_use, .agent_scope = .subagent, .request_purpose = .agent, .agent_type = "task", .model = "qwen3", .provider = "local", .tool_name = "read" };
    const filter: When = .{ .agent_scope = .subagent, .request_purpose = .agent, .agent_type = "task", .model = "qwen3", .provider = "local" };
    try std.testing.expect(try hookMatches(a, .{ .legacy = false, .matcher = "^Read$", .when = filter }, input));
    const mismatches = [_]When{
        .{ .agent_scope = .main }, .{ .request_purpose = .approval_judge }, .{ .agent_type = "build" }, .{ .model = "qwen" }, .{ .provider = "remote" },
    };
    for (mismatches) |wrong| try std.testing.expect(!try hookMatches(a, .{ .when = wrong }, input));
    try std.testing.expect(!try hookMatches(a, .{ .matcher = "write", .when = filter }, input));
    try std.testing.expect(!try hookMatches(a, .{ .when = .{ .agent_scope = .subagent } }, .{ .event = .stop }));
}

test "routing configuration rejects typos null selectors and handler-level ambiguity" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "{}", "null", "[]", "{\"agent_scope\":\"child\"}", "{\"request_purpose\":\"judge\"}", "{\"model\":null}", "{\"provider\":\"\"}", "{\"agent_scp\":\"main\"}" }) |filter| {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, a, filter, .{});
        try std.testing.expectError(error.InvalidHookFilter, parseWhen(a, value));
    }
    const source =
        \\{"PreToolUse":[{"matcher":"Read","when":{"agent_scope":"subagent","request_purpose":"agent","model":"qwen3"},"hooks":[{"command":"true"}]},{"when":{"agent_scope":"main"},"command":"true"}]}
    ;
    const set = try parse(a, try std.json.parseFromSliceLeaky(std.json.Value, a, source, .{}), "policy.json");
    try std.testing.expectEqual(AgentScope.subagent, set.pre_tool_use[0].when.?.agent_scope.?);
    try std.testing.expectEqualStrings("qwen3", set.pre_tool_use[0].when.?.model.?);
    try std.testing.expect(set.pre_tool_use[1].legacy);
    try std.testing.expectEqual(AgentScope.main, set.pre_tool_use[1].when.?.agent_scope.?);
    const ambiguous = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"PreToolUse":[{"hooks":[{"command":"true","when":{"agent_scope":"main"}}]}]}
    , .{});
    try std.testing.expectError(error.InvalidHookDefinition, parse(a, ambiguous, "policy.json"));
}

test "unfiltered declaration encoding retains existing trust identity bytes" {
    const a = std.testing.allocator;
    const encoded = try std.json.Stringify.valueAlloc(a, Hook{ .command = "true" }, .{});
    defer a.free(encoded);
    try std.testing.expectEqualStrings(
        \\{"matcher":"","command":"true","legacy":true,"id":"","trusted":true,"enabled":true,"transcript":false,"source":"config","timeout_ms":null,"async":false,"type":"command","server":"","tool":"","arguments":null}
    , encoded);
}

test "request and permission stages reject malformed output and blocking exits" {
    const a = std.testing.allocator;
    inline for (.{ Event.model_resolve, Event.model_context, Event.model_settings, Event.model_retry, Event.permission_evaluate, Event.http_request, Event.http_response }) |event| {
        var set: Set = .{};
        @field(set, @tagName(event)) = &.{.{ .legacy = false, .command = "printf 'invalid json'" }};
        var runner: Runner = .{ .io = std.testing.io, .root = ".", .set = set };
        try std.testing.expectError(error.SyntaxError, runner.evaluate(a, .{ .event = event }));
        @field(set, @tagName(event)) = &.{.{ .legacy = false, .command = "echo blocked >&2; exit 2" }};
        runner.set = set;
        if (event == .permission_evaluate) {
            var result = try runner.evaluate(a, .{ .event = event });
            defer result.deinit(a);
            try std.testing.expect(result.blocked != null);
        } else try std.testing.expectError(error.HookBlocked, runner.evaluate(a, .{ .event = event }));
    }
}

test "background saturation rejects excess work without waiting for long commands" {
    const a = std.testing.allocator;
    var runtime: Runtime = .{ .allocator = a, .io = std.testing.io };
    defer runtime.deinit();
    var hooks: [65]Hook = @splat(.{ .legacy = false, .async = true, .command = "cat >/dev/null; sleep 30" });
    hooks[64].command = "echo excess";
    const runner: Runner = .{ .io = std.testing.io, .root = ".", .runtime = &runtime, .set = .{ .pre_tool_use = &hooks } };
    const started = std.Io.Clock.now(.awake, std.testing.io).toMilliseconds();
    try std.testing.expectError(error.BackgroundHookLimit, runner.evaluate(a, .{ .event = .pre_tool_use }));
    try std.testing.expect(std.Io.Clock.now(.awake, std.testing.io).toMilliseconds() - started < 1000);
}

test "a transcript snapshot survives its owner until the last hook reader finishes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var runtime: Runtime = .{ .allocator = a, .io = std.testing.io };
    defer runtime.deinit();
    const path = try runtime.privatePath(a, "jsonl");
    defer a.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "original transcript" });
    try runtime.registerSnapshot(path);
    const command = try std.fmt.allocPrint(a, "cat '{s}' > observed", .{path});
    defer a.free(command);
    const runner: Runner = .{ .io = std.testing.io, .root = root, .runtime = &runtime, .set = .{ .pre_tool_use = &.{.{ .command = command }} } };
    const dispatch = try Dispatch.start(a, runner, .{ .event = .pre_tool_use, .transcript_path = path });
    runtime.releaseSnapshot(path);
    dispatch.join();
    const observed = try tmp.dir.readFileAlloc(std.testing.io, "observed", a, .limited(1024));
    defer a.free(observed);
    try std.testing.expectEqualStrings("original transcript", observed);
    const file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    file.close(std.testing.io);
    dispatch.destroy();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, path, .{}));
}

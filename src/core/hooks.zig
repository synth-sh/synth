const std = @import("std");
const ToolInput = @import("hook_tool_input.zig");
const Filesystem = @import("../tools/filesystem.zig");
const output = @import("hook_result.zig");
const HooksCopy = @import("hooks_copy.zig");
const HookCommand = @import("hook_command.zig");
const regex = @import("regex.zig");
const ansi = @import("ansi.zig");
const ModelClass = @import("model_class.zig");
const mcp = @import("../tools/mcp.zig");
const shell = @import("../tools/shell.zig");
const task = @import("../tools/task.zig");

pub const Result = output.Result;
pub const Permission = output.Permission;

pub const default_timeout_ms: u64 = 30_000;
pub const cleanup_timeout_ms: i64 = 3 * std.time.ms_per_s;
pub const cleanup_handler_timeout_ms: u64 = std.time.ms_per_s;
pub const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const private_directory_permissions = std.Io.Dir.Permissions.fromMode(0o700);
const display_timeout_ms: u64 = 10 * std.time.ms_per_s;
const capacity_poll_ms = 5;
const dispatch_poll_ms = 1;
const record_capacity = 64;
const record_id_bytes = 64;
const pending_dispatch_capacity = 64;
const temp_nonce_bytes = 16;
const max_inline_output_bytes = 8 * 1024;
const output_preview_bytes = 4 * 1024;
const output_file_buffer_bytes = 4 * 1024;
const blocking_exit_code = 2;
const not_executable_exit_code = 126;
const command_not_found_exit_code = 127;

const claude_tool_names = std.StaticStringMap([]const u8).initComptime(.{
    .{ shell.tool_name, "Bash" }, .{ @tagName(Filesystem.Name.read), "Read" }, .{ @tagName(Filesystem.Name.write), "Write" }, .{ @tagName(Filesystem.Name.edit), "Edit" }, .{ task.tool_name, "Agent" },
});

const max_timeout_ms: u64 = 86_400_000;
const background_limit: usize = 64;
const concurrent_limit = 8;

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
            .file_changed => input.file_path,
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
pub const ConfigSource = enum { user_settings, project_settings, skills };
pub const ModelSwitchSource = enum { initial, @"resume", automatic, command, sdk, picker };
pub const NotificationType = enum { notice, auth_success, idle_prompt, agent_completed, agent_needs_input, permission_prompt };
pub const inline_source = "config";

pub const When = struct {
    agent_scope: ?AgentScope = null,
    request_purpose: ?RequestPurpose = null,
    agent_type: ?[]const u8 = null,
    model: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    trust: ?ModelClass.Choice(ModelClass.Trust) = null,
    tier: ?ModelClass.Choice(ModelClass.Tier) = null,

    pub fn accepts(self: When, input: Invocation) bool {
        if (self.trust) |choice| if (!choice.has(input.model_trust)) return false;
        if (self.tier) |choice| if (!choice.has(input.model_tier)) return false;
        if (self.agent_scope) |value| if (value != input.agent_scope) return false;
        if (self.request_purpose) |value| if (value != input.request_purpose) return false;
        inline for ([_]Invocation.Field{ .agent_type, .model, .provider }) |input_field| {
            const field = @tagName(input_field);
            if (@field(self, field)) |value| if (!std.mem.eql(u8, value, @field(input, field))) return false;
        }
        return true;
    }
};

fn parseWhen(allocator: std.mem.Allocator, value: std.json.Value) !When {
    if (value != .object or value.object.count() == 0) return error.InvalidHookFilter;
    var fields = value.object.iterator();
    while (fields.next()) |field| {
        const is_class = std.mem.eql(u8, field.key_ptr.*, "trust") or std.mem.eql(u8, field.key_ptr.*, "tier");
        if (is_class and field.value_ptr.* == .array) continue;
        if (field.value_ptr.* != .string or field.value_ptr.string.len == 0) return error.InvalidHookFilter;
    }
    return std.json.parseFromValueLeaky(When, allocator, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.InvalidHookFilter,
    };
}

pub const Hook = struct {
    matcher: []const u8 = "",
    command: []const u8 = "",
    id: []const u8 = "",
    trusted: bool = true,
    enabled: bool = true,
    transcript: bool = false,
    stream: bool = false,
    source: []const u8 = inline_source,
    timeout_ms: ?u64 = null,
    async: bool = false,
    type: Kind = .command,
    server: []const u8 = "",
    tool: []const u8 = "",
    arguments: std.json.Value = .null,
    when: ?When = null,
    on_failure: ?OnFailure = null,

    const Kind = enum { command, mcp_tool };
    pub const OnFailure = enum { block, @"continue" };

    fn blocksOnFailure(self: Hook, event: Event) bool {
        const default: OnFailure = if (event.requestStage()) .block else .@"continue";
        return (self.on_failure orelse default) == .block;
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
    if (event == .session_end or event == .interrupt) return @min(hook.timeout_ms orelse cleanup_handler_timeout_ms, @as(u64, cleanup_timeout_ms));
    if (event == .message_display and fallback == default_timeout_ms) return hook.timeout_ms orelse display_timeout_ms;
    return hook.timeout_ms orelse fallback;
}

pub fn validTimeout(value: u64) !void {
    if (value == 0 or value > max_timeout_ms) return error.InvalidHookTimeout;
}

pub fn parse(allocator: std.mem.Allocator, value: std.json.Value, source: []const u8) !Set {
    if (value != .object) return error.InvalidHooks;
    const events = try unwrapEvents(value);
    var set: Set = .{};
    var entries = events.object.iterator();
    while (entries.next()) |entry| {
        const event = Event.fromName(entry.key_ptr.*) orelse {
            std.log.warn("{s}: ignoring hooks for unknown event {s}", .{ source, entry.key_ptr.* });
            continue;
        };
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

const GroupField = enum { matcher, hooks, when };
const HandlerField = enum { type, command, timeout_ms, timeout, async, stream, server, tool, arguments, transcript, onFailure };
const input_alias = "input";

fn unwrapEvents(value: std.json.Value) !std.json.Value {
    const wrapped = value.object.get(@tagName(GroupField.hooks)) orelse return value;
    if (wrapped != .object) return error.InvalidHooks;
    for (value.object.keys()) |key| {
        if (!std.mem.eql(u8, key, @tagName(GroupField.hooks)) and !std.mem.eql(u8, key, "description")) return error.InvalidHooks;
    }
    return wrapped;
}

const Declaration = struct { event: Event, source: []const u8, matcher: []const u8, when: ?When };

fn parseDeclaration(a: std.mem.Allocator, value: std.json.Value, event: Event, source: []const u8, hooks: *std.ArrayList(Hook)) !void {
    const matcher = if (value.object.get(@tagName(GroupField.matcher))) |field| matcher: {
        if (field != .string) return error.InvalidHookMatcher;
        break :matcher field.string;
    } else "";
    const filter = if (value.object.get(@tagName(GroupField.when))) |field| try parseWhen(a, field) else null;
    const declaration: Declaration = .{ .event = event, .source = source, .matcher = matcher, .when = filter };
    if (event == .file_changed) {
        var names = std.mem.tokenizeScalar(u8, matcher, '|');
        while (names.next()) |name| {
            if (std.mem.indexOfScalar(u8, name, '\\') != null) return error.InvalidHookMatcher;
            var components = std.mem.splitScalar(u8, name, '/');
            while (components.next()) |component| {
                if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.InvalidHookMatcher;
            }
        }
    }
    const group = value.object.get(@tagName(GroupField.hooks)) orelse {
        if (value.object.contains(@tagName(HandlerField.command))) return error.FlatHookFormatNeedsGrouping;
        return error.InvalidHooks;
    };
    if (group != .array) return error.InvalidHooks;
    var fields = value.object.iterator();
    while (fields.next()) |field| {
        if (std.meta.stringToEnum(GroupField, field.key_ptr.*) == null) return error.InvalidHookDefinition;
    }
    for (group.array.items) |handler| try hooks.append(a, try parseHandler(a, handler, declaration));
}

fn parseHandler(a: std.mem.Allocator, definition: std.json.Value, declaration: Declaration) !Hook {
    const value = try withArgumentsKey(a, definition);
    try validateDefinition(value, declaration.source);
    const timeout_ms: ?u64 = if (value.object.get(@tagName(HandlerField.timeout))) |seconds| blk: {
        if (seconds != .integer or seconds.integer <= 0 or seconds.integer > max_timeout_ms / std.time.ms_per_s or value.object.contains(@tagName(HandlerField.timeout_ms))) return error.InvalidHookTimeout;
        break :blk @intCast(seconds.integer * std.time.ms_per_s);
    } else null;
    var hook = try std.json.parseFromValueLeaky(Hook, a, value, .{ .ignore_unknown_fields = true });
    if (timeout_ms) |ms| hook.timeout_ms = ms;
    if (value.object.get(@tagName(HandlerField.onFailure))) |setting| {
        if (setting != .string) return error.InvalidHookDefinition;
        hook.on_failure = std.meta.stringToEnum(Hook.OnFailure, setting.string) orelse return error.InvalidHookDefinition;
    }
    hook.source = declaration.source;
    hook.matcher = declaration.matcher;
    hook.when = declaration.when;
    if (hook.type == .command and hook.command.len == 0) return error.InvalidHooks;
    if (hook.type == .mcp_tool) {
        if (hook.server.len == 0 or hook.tool.len == 0 or !value.object.contains(@tagName(HandlerField.arguments))) return error.InvalidHookDefinition;
        if (hook.arguments != .object and hook.arguments != .string) return error.InvalidHookDefinition;
        if (hook.async) return error.AsyncMcpHookUnsupported;
        if (declaration.event == .session_end) return error.SessionEndMcpHookUnsupported;
    }
    if (hook.async and (declaration.event.requestStage() or declaration.event == .permission_evaluate)) return error.InvalidHookAsync;
    if (hook.async and declaration.event == .session_end) return error.AsyncSessionEndHookUnsupported;
    if (hook.timeout_ms) |ms| try validTimeout(ms);
    const has_pattern = declaration.event.matcherValue(.{ .event = declaration.event }) != null and declaration.event != .file_changed and hook.matcher.len > 0 and !std.mem.eql(u8, hook.matcher, "*");
    if (has_pattern) {
        var compiled = try compileMatcher(a, hook.matcher);
        compiled.deinit();
    }
    return hook;
}

fn withArgumentsKey(a: std.mem.Allocator, definition: std.json.Value) !std.json.Value {
    if (definition != .object) return definition;
    const input = definition.object.get(input_alias) orelse return definition;
    if (definition.object.contains(@tagName(HandlerField.arguments))) return error.InvalidHookDefinition;
    var object = try definition.object.clone(a);
    _ = object.orderedRemove(input_alias);
    try object.put(a, @tagName(HandlerField.arguments), input);
    return .{ .object = object };
}

fn validateDefinition(value: std.json.Value, source: []const u8) !void {
    if (value != .object) return error.InvalidHooks;
    const kind: Hook.Kind = if (value.object.get(@tagName(HandlerField.type))) |field| blk: {
        if (field != .string) return error.InvalidHookDefinition;
        break :blk std.meta.stringToEnum(Hook.Kind, field.string) orelse return error.UnsupportedHookHandlerType;
    } else .command;
    for (value.object.keys()) |key| {
        const field = std.meta.stringToEnum(HandlerField, key) orelse {
            std.log.warn("{s}: ignoring unknown hook handler key {s}", .{ source, key });
            continue;
        };
        const allowed = switch (field) {
            .type, .timeout_ms, .timeout, .async, .stream, .transcript => true,
            .command, .onFailure => kind == .command,
            .server, .tool, .arguments => kind == .mcp_tool,
        };
        if (!allowed) return error.InvalidHookDefinition;
    }
}

pub const Invocation = struct {
    const Field = std.meta.FieldEnum(Invocation);

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
    model_trust: []const u8 = "",
    model_tier: []const u8 = "",
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
    turn_number: ?u64 = null,
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
    id: [record_id_bytes]u8 = @splat(0),
    event: Event,
    agent_scope: AgentScope = .main,
    request_purpose: RequestPurpose = .agent,
    duration_ms: i64,
    status: Status,
    exit_code: ?u8 = null,
    error_name: []const u8 = "",
    request_id: u64 = 0,
    attempt: u32 = 0,
    agent_id: [record_id_bytes]u8 = @splat(0),
    session_id: [record_id_bytes]u8 = @splat(0),
    turn_id: [record_id_bytes]u8 = @splat(0),
    call_id: [record_id_bytes]u8 = @splat(0),

    pub const Status = enum { started, failed, completed };
};

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    active: std.atomic.Value(usize) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    background: std.ArrayList(*Dispatch) = .empty,
    background_mutex: std.Io.Mutex = .init,
    records: [record_capacity]Record = undefined,
    records_len: usize = 0,
    records_next: usize = 0,
    records_mutex: std.Io.Mutex = .init,
    pending: Result = .{},
    deliveries: std.StringHashMapUnmanaged(Result) = .empty,

    temp_dir: ?[]u8 = null,
    temp_mutex: std.Io.Mutex = .init,
    snapshots: std.StringHashMapUnmanaged(usize) = .empty,

    fn enter(self: *Runtime, stop: ?*const std.atomic.Value(bool), deadline_ms: ?i64) !void {
        while (true) {
            if (self.stop.load(.acquire)) return error.Cancelled;
            if (deadline_ms) |deadline| if (std.Io.Clock.now(.awake, self.io).toMilliseconds() >= deadline) return error.Timeout;
            if (stop) |flag| if (flag.load(.acquire)) return error.Cancelled;
            const active = self.active.load(.acquire);
            if (active < concurrent_limit and self.active.cmpxchgWeak(active, active + 1, .acq_rel, .acquire) == null) return;
            try std.Io.sleep(self.io, .fromMilliseconds(capacity_poll_ms), .awake);
        }
    }
    fn leave(self: *Runtime) void {
        _ = self.active.fetchSub(1, .release);
    }
    fn record(self: *Runtime, hook: Hook, invocation: Invocation, started: i64, status: Record.Status, exit_code: ?u8, error_name: []const u8) void {
        self.records_mutex.lockUncancelable(self.io);
        defer self.records_mutex.unlock(self.io);
        var record_value: Record = .{ .event = invocation.event, .duration_ms = std.Io.Clock.now(.awake, self.io).toMilliseconds() - started, .status = status };
        record_value.agent_scope = invocation.agent_scope;
        record_value.request_purpose = invocation.request_purpose;
        record_value.exit_code = exit_code;
        record_value.request_id = invocation.request_id;
        record_value.attempt = invocation.attempt;
        record_value.error_name = error_name;
        inline for ([_]Invocation.Field{ .session_id, .turn_id, .tool_call_id, .agent_id }) |field| {
            const name = @tagName(field);
            const record_field = if (field == .tool_call_id) "call_id" else name;
            const value = @field(invocation, name);
            const length = @min(record_id_bytes, value.len);
            @memcpy(@field(record_value, record_field)[0..length], value[0..length]);
        }
        if (invocation.turn_number) |number| _ = std.fmt.bufPrint(&record_value.turn_id, "{d}", .{number}) catch {};
        const id_len = @min(record_value.id.len, hook.id.len);
        @memcpy(record_value.id[0..id_len], hook.id[0..id_len]);
        self.records[self.records_next] = record_value;
        self.records_next = (self.records_next + 1) % self.records.len;
        self.records_len = @min(self.records_len + 1, self.records.len);
    }
    fn launch(self: *Runtime, runner: Runner, hook: Hook, invocation: Invocation) !void {
        self.background_mutex.lockUncancelable(self.io);
        defer self.background_mutex.unlock(self.io);
        try self.collectFinished();
        if (self.background.items.len >= background_limit) return error.BackgroundHookLimit;
        var session_runner = runner;
        session_runner.stop = &self.stop;
        try self.background.ensureUnusedCapacity(self.allocator, 1);
        self.background.appendAssumeCapacity(try Dispatch.startHook(self.allocator, session_runner, hook, invocation));
    }
    fn collectFinished(self: *Runtime) !void {
        var i: usize = 0;
        while (i < self.background.items.len) {
            const job = self.background.items[i];
            if (!job.isFinished()) {
                i += 1;
                continue;
            }
            _ = self.background.orderedRemove(i);
            defer job.destroy();
            job.join();
            try self.collect(job);
        }
    }
    fn collect(self: *Runtime, job: *Dispatch) !void {
        if (job.failed) |err| {
            const message = try std.fmt.allocPrint(self.allocator, HooksCopy.named_failure, .{ "Background", @errorName(err) });
            if (self.pending.message) |old| self.allocator.free(old);
            self.pending.message = message;
            return;
        }
        const control = job.result.blocked != null or job.result.replacement != null or job.result.permission != null or job.result.feedback != null or job.result.stop or job.result.retry or job.result.display_content != null;
        const destination = try self.deliveryFor(job.invocation.agent_id);
        try destination.merge(self.allocator, .{
            .context = job.result.context,
            .message = if (control) try job.arena.allocator().dupe(u8, "Background hook control effects were ignored") else job.result.message,
        });
        try self.bound(self.allocator, destination);
    }
    fn deliveryFor(self: *Runtime, agent_id: []const u8) !*Result {
        if (agent_id.len == 0) return &self.pending;
        if (self.deliveries.getPtr(agent_id)) |result| return result;
        const key = try self.allocator.dupe(u8, agent_id);
        errdefer self.allocator.free(key);
        const entry = try self.deliveries.getOrPut(self.allocator, key);
        entry.value_ptr.* = .{};
        return entry.value_ptr;
    }
    fn takeDelivery(self: *Runtime, agent_id: []const u8) ?Result {
        const entry = self.deliveries.fetchRemove(agent_id) orelse return null;
        self.allocator.free(entry.key);
        return entry.value;
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
        if (self.takeDelivery(agent_id)) |value| {
            var result = value;
            result.deinit(self.allocator);
        }
    }
    pub fn drainFor(self: *Runtime, allocator: std.mem.Allocator, agent_id: []const u8) !Result {
        self.background_mutex.lockUncancelable(self.io);
        defer self.background_mutex.unlock(self.io);
        try self.collectFinished();
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
        if (self.takeDelivery(agent_id)) |value| {
            var delivery = value;
            defer delivery.deinit(self.allocator);
            try result.merge(allocator, delivery);
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
        var nonce: [temp_nonce_bytes]u8 = undefined;
        self.io.random(&nonce);
        if (self.temp_dir == null) {
            const path = try std.fmt.allocPrint(self.allocator, "/tmp/synth-hooks-{s}", .{std.fmt.bytesToHex(nonce, .lower)});
            errdefer self.allocator.free(path);
            try std.Io.Dir.cwd().createDir(self.io, path, private_directory_permissions);
            self.temp_dir = path;
            self.io.random(&nonce);
        }
        return std.fmt.allocPrint(allocator, "{s}/{s}.{s}", .{ self.temp_dir.?, std.fmt.bytesToHex(nonce, .lower), extension });
    }
    pub fn bound(self: *Runtime, allocator: std.mem.Allocator, result: *Result) !void {
        inline for ([_]Result.Field{ .context, .message, .blocked, .feedback }) |result_field| {
            const field = @tagName(result_field);
            if (@field(result, field)) |value| {
                if (value.len > max_inline_output_bytes) {
                    const path = try self.privatePath(allocator, "txt");
                    defer allocator.free(path);
                    const file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .exclusive = true, .permissions = private_file_permissions });
                    defer file.close(self.io);
                    var buffer: [output_file_buffer_bytes]u8 = undefined;
                    var writer = file.writer(self.io, &buffer);
                    try writer.interface.writeAll(value);
                    try writer.interface.flush();
                    var preview_end: usize = output_preview_bytes;
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
        var deliveries = self.deliveries.iterator();
        while (deliveries.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
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

pub const Runner = struct {
    io: std.Io,
    root: []const u8,
    set: Set,
    timeout_ms: u64 = default_timeout_ms,
    runtime: ?*Runtime = null,
    deadline_ms: ?i64 = null,
    mcp_executor: ?McpExecutor = null,
    rewrite_author: ?usize = null,
    classes: []const ModelClass.Class = &.{},

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

    pub fn classified(self: Runner, invocation: Invocation) Invocation {
        const class = ModelClass.resolve(self.classes, invocation.provider, invocation.model);
        var result = invocation;
        result.model_trust = @tagName(class.trust);
        result.model_tier = @tagName(class.tier);
        return result;
    }

    pub fn hasMatching(self: Runner, allocator: std.mem.Allocator, raw: Invocation, require_trust: bool) bool {
        const invocation = self.classified(raw);
        for (self.set.forEvent(invocation.event)) |hook| {
            if (!hook.enabled or (require_trust and !hook.trusted)) continue;
            if (hookMatches(allocator, self.root, hook, invocation) catch false) return true;
        }
        return false;
    }

    pub fn observe(self: Runner, raw: Invocation) !void {
        const invocation = self.classified(raw);
        if (!invocation.event.observational()) return error.InvalidHookEvent;
        const runtime = self.runtime orelse return;
        for (self.set.forEvent(invocation.event)) |hook| {
            if (!hook.enabled) continue;
            if (!try hookMatches(runtime.allocator, self.root, hook, invocation)) continue;
            if (!hook.trusted) {
                try runtime.notice(HooksCopy.observation_needs_review);
                continue;
            }
            try runtime.launch(self, hook, invocation);
        }
    }

    const FirstFailure = struct {
        index: usize = std.math.maxInt(usize),
        err: ?anyerror = null,

        fn record(self: *FirstFailure, index: usize, err: anyerror) void {
            if (index < self.index) self.* = .{ .index = index, .err = err };
        }
    };

    fn admits(self: Runner, allocator: std.mem.Allocator, hook: Hook, invocation: Invocation, index: usize, failure: *FirstFailure) !bool {
        if (!hook.enabled) return false;
        if (hook.async and (invocation.event.requestStage() or invocation.event == .permission_evaluate)) return error.InvalidHookAsync;
        if (self.rewrite_author == index or (self.rewrite_author != null and hook.async)) return false;
        const matched = hookMatches(allocator, self.root, hook, invocation) catch |err| {
            if (err == error.OutOfMemory) return err;
            failure.record(index, err);
            if (self.runtime) |runtime| runtime.record(hook, invocation, std.Io.Clock.now(.awake, self.io).toMilliseconds(), .failed, null, @errorName(err));
            return false;
        };
        if (matched and !hook.trusted) {
            failure.record(index, error.HookNeedsReview);
            return false;
        }
        return matched;
    }

    pub fn evaluate(self: Runner, allocator: std.mem.Allocator, raw: Invocation) !Result {
        const invocation = self.classified(raw);
        var outcome: Result = .{};
        errdefer outcome.deinit(allocator);
        const definitions = self.set.forEvent(invocation.event);
        var at: usize = 0;
        var failure: FirstFailure = .{};
        const PendingJob = struct { index: usize, job: *Dispatch };
        var buffer: [pending_dispatch_capacity]PendingJob = undefined;
        var pending: std.Deque(PendingJob) = .initBuffer(&buffer);
        defer while (pending.popFront()) |entry| entry.job.destroy();
        var running: usize = 0;
        while (at < definitions.len or running > 0) {
            if (self.givenUp()) return error.Cancelled;
            while (at < definitions.len and running < concurrent_limit and pending.len < buffer.len) : (at += 1) {
                const hook = definitions[at];
                if (!try self.admits(allocator, hook, invocation, at, &failure)) continue;
                if (hook.async) {
                    const runtime = self.runtime orelse return error.BackgroundHooksUnavailable;
                    try runtime.launch(self, hook, invocation);
                } else {
                    const job = try Dispatch.startHook(allocator, self, hook, invocation);
                    pending.pushBackAssumeCapacity(.{ .index = at, .job = job });
                    running += 1;
                }
            }
            var progressed = false;
            var jobs = pending.iterator();
            while (jobs.next()) |entry| {
                if (entry.job.reaped or !entry.job.isFinished()) continue;
                entry.job.join();
                running -= 1;
                progressed = true;
            }
            while (pending.front()) |entry| {
                const job = entry.job;
                if (!job.reaped) break;
                _ = pending.popFront();
                defer job.destroy();
                if (job.failed) |err| {
                    failure.record(entry.index, err);
                } else {
                    try outcome.merge(allocator, job.result);
                    if (job.result.replacement != null) outcome.replacement_author = entry.index;
                }
                if (self.runtime) |runtime| try runtime.bound(allocator, &outcome);
            }
            if (!progressed and running > 0) try std.Io.sleep(self.io, .fromMilliseconds(dispatch_poll_ms), .awake);
        }
        if (failure.err) |err| {
            const strict = !invocation.event.observational() and invocation.event != .post_tool_use;
            if (strict or err == error.OutOfMemory) return err;
            var diagnostic: Result = .{ .message = try std.fmt.allocPrint(allocator, HooksCopy.named_failure, .{ invocation.event.name(), @errorName(err) }) };
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
        if (self.runtime) |runtime| runtime.record(hook, invocation, started, .started, null, "");
        var exit_code: ?u8 = null;
        var result = configured.executeHook(allocator, hook, invocation, &exit_code) catch |err| {
            if (self.runtime) |runtime| runtime.record(hook, invocation, started, .failed, exit_code, @errorName(err));
            return err;
        };
        errdefer result.deinit(allocator);
        if (self.runtime) |runtime| {
            runtime.bound(allocator, &result) catch |err| {
                runtime.record(hook, invocation, started, .failed, exit_code, @errorName(err));
                return err;
            };
            runtime.record(hook, invocation, started, .completed, exit_code, "");
        }
        return result;
    }

    fn executeHook(self: Runner, allocator: std.mem.Allocator, hook: Hook, invocation: Invocation, exit_code: *?u8) !Result {
        const command = if (hook.type == .command) blk: {
            var payload: std.Io.Writer.Allocating = .init(allocator);
            defer payload.deinit();
            try writeJson(allocator, &payload.writer, self.root, invocation);
            try payload.writer.writeByte('\n');
            break :blk try HookCommand.run(self.io, allocator, .{
                .root = self.root,
                .timeout_ms = self.timeout_ms,
                .stop = self.stop,
            }, hook.command, payload.written());
        } else blk: {
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
            break :blk HookCommand.Output{ .code = 0, .stdout = response, .stderr = try allocator.dupe(u8, ""), .overflow = response.len > HookCommand.output_limit };
        };
        exit_code.* = command.code;
        defer allocator.free(command.stderr);
        defer allocator.free(command.stdout);
        if (command.overflow) return error.HookOutputTooLarge;
        var result: Result = .{};
        errdefer result.deinit(allocator);
        if (command.code == not_executable_exit_code or command.code == command_not_found_exit_code) return error.HookCommandUnavailable;
        const exited_abnormally = command.code != 0 and command.code != blocking_exit_code;
        if (exited_abnormally and hook.blocksOnFailure(invocation.event)) return error.HookCommandFailed;
        const advisory = invocation.event.observational();
        if (command.code == blocking_exit_code and advisory) {
            result.message = try allocator.dupe(u8, std.fmt.comptimePrint("Observation hook exited {d}; control effect ignored", .{blocking_exit_code}));
        } else if (command.code == blocking_exit_code) {
            const reason = std.mem.trim(u8, command.stderr, " \t\r\n");
            result.blocked = try allocator.dupe(u8, if (reason.len > 0) reason else HooksCopy.blocked);
        } else if (command.code == 0) {
            result = try output.parse(allocator, command.stdout, invocation.event);
        }
        if (result.feedback != null and !std.mem.startsWith(u8, invocation.tool_name, mcp.prefix)) return error.UnsupportedHookEffect;
        inline for ([_]Result.Field{ .context, .blocked, .feedback }) |result_field| {
            const field = @tagName(result_field);
            if (@field(result, field)) |text_value| {
                const attributed = try std.fmt.allocPrint(allocator, "[Hook {s}{s}]\n{s}", .{ hook.source, if (hook.type == .mcp_tool) " / external MCP tool" else "", text_value });
                allocator.free(text_value);
                @field(result, field) = attributed;
            }
        }
        inline for ([_]Result.Field{ .context, .message, .blocked, .feedback, .display_content }) |result_field| {
            const field = @tagName(result_field);
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
};

pub const Dispatch = struct {
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    runner: Runner,
    invocation: Invocation,
    hook: ?Hook,
    result: Result = .{},
    failed: ?anyerror = null,
    future: std.Io.Future(void) = undefined,
    done: std.atomic.Value(bool) = .init(false),
    reaped: bool = false,
    stop: std.atomic.Value(bool) = .init(false),

    pub fn start(allocator: std.mem.Allocator, runner: Runner, invocation: Invocation) !*Dispatch {
        return launch(allocator, runner, invocation, null);
    }

    fn startHook(allocator: std.mem.Allocator, runner: Runner, hook: Hook, invocation: Invocation) !*Dispatch {
        return launch(allocator, runner, invocation, hook);
    }

    fn launch(allocator: std.mem.Allocator, runner: Runner, invocation: Invocation, hook: ?Hook) !*Dispatch {
        const self = try allocator.create(Dispatch);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .arena = .init(allocator),
            .runner = runner,
            .invocation = invocation,
            .hook = hook,
        };
        errdefer self.arena.deinit();
        self.invocation = try invocation.dupe(self.arena.allocator());
        if (hook == null) self.runner.stop = &self.stop;
        if (runner.runtime) |runtime| runtime.retainSnapshot(self.invocation.transcript_path);
        errdefer if (runner.runtime) |runtime| runtime.releaseSnapshot(self.invocation.transcript_path);
        self.future = try runner.io.concurrent(run, .{self});
        return self;
    }

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

    pub fn cancel(self: *Dispatch) void {
        if (self.reaped) return;
        self.reaped = true;
        self.requestStop();
        self.future.cancel(self.runner.io);
    }

    pub fn destroy(self: *Dispatch) void {
        self.cancel();
        const allocator = self.allocator;
        if (self.hook == null) self.result.deinit(allocator);
        if (self.runner.runtime) |runtime| runtime.releaseSnapshot(self.invocation.transcript_path);
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn run(self: *Dispatch) void {
        defer self.done.store(true, .release);
        self.result = (if (self.hook) |hook|
            self.runner.runHook(self.arena.allocator(), hook, self.invocation)
        else
            self.runner.evaluate(self.allocator, self.invocation)) catch |err| {
            self.failed = err;
            return;
        };
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

fn hookMatches(allocator: std.mem.Allocator, root: []const u8, hook: Hook, invocation: Invocation) !bool {
    if (hook.when) |filter| if (!filter.accepts(invocation)) return false;
    const value = invocation.event.matcherValue(invocation) orelse return true;
    if (hook.matcher.len == 0 or std.mem.eql(u8, hook.matcher, "*")) return true;
    if (invocation.event == .file_changed) {
        const directory = std.mem.trimEnd(u8, root, "/");
        if (value.len <= directory.len or !std.mem.startsWith(u8, value, directory) or value[directory.len] != '/') return false;
        const relative = value[directory.len + 1 ..];
        var names = std.mem.tokenizeScalar(u8, hook.matcher, '|');
        while (names.next()) |name| if (std.mem.eql(u8, relative, name)) return true;
        return false;
    }
    var compiled = try compileMatcher(allocator, hook.matcher);
    defer compiled.deinit();
    if (try compiled.checkedMatches(value)) return true;
    if (!invocation.event.toolMatcher()) return false;
    const alias = claude_tool_names.get(value) orelse return false;
    return compiled.checkedMatches(alias);
}

fn writeJson(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    root: []const u8,
    invocation: Invocation,
) !void {
    var json: std.json.Stringify = .{ .writer = w };
    try json.beginObject();
    try json.objectField("hook_event_name");
    try json.write(invocation.event.name());
    try json.objectField("cwd");
    try json.write(invocation.cwd orelse root);
    inline for ([_]Invocation.Field{
        .agent_scope,       .request_purpose,   .request_system,      .request_instruction,    .request_tools,    .request_routes,
        .permission_effect, .action,            .http,                .route,                  .request_context,  .request_settings,
        .provider,          .parent_agent_id,   .parent_tool_call_id, .old_cwd,                .new_cwd,          .directory,
        .session_id,        .tool_call_id,      .agent_id,            .agent_type,             .model,            .model_trust,
        .model_tier,        .permission_mode,   .source,              .trigger,                .status,           .error_type,
        .error_message,     .parent_session_id, .reason,              .notification_type,      .message,          .title,
        .file_path,         .event_type,        .load_reason,         .memory_type,            .from_model,       .to_model,
        .task_id,           .task_subject,      .task_description,    .command_name,           .command_args,     .expanded_prompt,
        .message_id,        .delta,             .requested_model,     .last_assistant_message, .http_status,      .retry_delay_ms,
        .retry_allowed,     .request_id,        .attempt,             .transcript_path,        .stop_hook_active, .input_tokens,
        .output_tokens,     .is_interrupt,      .duration_ms,         .index,                  .final,
    }) |field| {
        const name = @tagName(field);
        try json.objectField(name);
        try json.write(@field(invocation, name));
    }
    try json.objectField(@tagName(Invocation.Field.turn_id));
    if (invocation.turn_number) |number| try json.print("\"{d}\"", .{number}) else try json.write(invocation.turn_id);
    try json.objectField("tool_use_id");
    try json.write(invocation.tool_call_id);
    try json.objectField("error");
    try json.write(if (invocation.error_type.len > 0) invocation.error_type else invocation.error_message);
    try json.objectField("error_details");
    try json.write(invocation.error_message);
    if (invocation.event == .subagent_stop) {
        try json.objectField("agent_transcript_path");
        try json.write(invocation.transcript_path);
    }
    if (invocation.event == .user_prompt_submit or invocation.event == .user_prompt_expansion) {
        try json.objectField("prompt");
        try json.write(invocation.prompt);
    }
    if (invocation.event.toolMatcher()) {
        try json.objectField("tool_name");
        try json.write(claude_tool_names.get(invocation.tool_name) orelse invocation.tool_name);
        var scratch: std.heap.ArenaAllocator = .init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var arguments = std.json.parseFromSliceLeaky(std.json.Value, a, invocation.tool_input, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => std.json.Value{ .object = .empty },
        };
        try ToolInput.addAliases(a, invocation.tool_name, &arguments);
        try json.objectField("tool_input");
        try json.write(arguments);
    }
    if (invocation.event == .post_tool_use or invocation.event == .post_tool_use_failure) {
        try json.objectField("tool_response");
        try json.write(invocation.tool_response);
    }
    if (invocation.event == .file_changed) {
        try json.objectField("event");
        try json.write(invocation.event_type);
    }
    if (invocation.event == .post_tool_batch) {
        try json.objectField("tool_calls");
        try json.beginWriteRaw();
        try w.writeAll(if (try std.json.validate(allocator, invocation.tool_calls)) invocation.tool_calls else "[]");
        json.endWriteRaw();
    }
    try json.endObject();
}

test "a matching pre-tool hook can block" {
    const testing = std.testing;
    const hook = Hook{ .matcher = "bash", .command = "read payload; echo blocked by policy >&2; exit 2" };
    const runner: Runner = .{
        .io = testing.io,
        .root = ".",
        .set = .{ .pre_tool_use = &.{hook} },
    };

    var result = try runner.evaluate(testing.allocator, .{
        .event = .pre_tool_use,
        .tool_name = "bash",
        .tool_input = "{\"command\":\"make\"}",
    });
    defer result.deinit(testing.allocator);
    try testing.expectEqualStrings("[Hook config]\nblocked by policy", result.blocked.?);
}

test "command and JSON hook denials share the default reason" {
    const testing = std.testing;
    const commands = [_][]const u8{
        "exit 2",
        "printf '%s' '{\"decision\":\"block\"}'",
        "printf '%s' '{\"decision\":\"block\",\"reason\":null}'",
        "printf '%s' '{\"decision\":\"block\",\"reason\":\"\"}'",
    };
    for (commands) |command| {
        const runner: Runner = .{
            .io = testing.io,
            .root = ".",
            .set = .{ .pre_tool_use = &.{.{ .command = command }} },
        };
        var result = try runner.evaluate(testing.allocator, .{ .event = .pre_tool_use });
        defer result.deinit(testing.allocator);
        try testing.expectEqualStrings("[Hook config]\n" ++ HooksCopy.blocked, result.blocked.?);
    }
}

test "a hook with closed pipes still times out" {
    const testing = std.testing;
    if (!HookCommand.supports_process_groups) return error.SkipZigTest;
    const runner: Runner = .{
        .io = testing.io,
        .root = ".",
        .set = .{ .user_prompt_submit = &.{.{ .command = "exec 0<&- 2>&-; sleep 2" }} },
        .timeout_ms = 50,
    };
    const started: std.Io.Timestamp = .now(testing.io, .awake);
    try testing.expectError(error.Timeout, runner.evaluate(testing.allocator, .{ .event = .user_prompt_submit }));
    try testing.expect(started.durationTo(.now(testing.io, .awake)).nanoseconds < std.time.ns_per_s);
}

test "raising the stop flag ends a hook that would otherwise run on" {
    const testing = std.testing;
    if (!HookCommand.supports_process_groups) return error.SkipZigTest;

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
        runner.evaluate(testing.allocator, .{ .event = .user_prompt_submit, .prompt = "go" }),
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
    var result = try runner.evaluate(testing.allocator, .{ .event = .pre_tool_use, .tool_name = "read" });
    defer result.deinit(testing.allocator);
    try testing.expect(result.blocked == null);
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

    var result = try runner.evaluate(testing.allocator, .{
        .event = .user_prompt_submit,
        .prompt = prompt,
    });
    defer result.deinit(testing.allocator);
    try testing.expectEqual(HookCommand.output_limit + "[Hook config]\n".len, result.blocked.?.len);
}

test "oversized structured stdout is drained and rejected" {
    const runner: Runner = .{ .io = std.testing.io, .root = ".", .set = .{ .pre_tool_use = &.{.{ .command = "head -c 131072 /dev/zero; head -c 131072 /dev/zero >&2" }} } };
    try std.testing.expectError(error.HookOutputTooLarge, runner.evaluate(std.testing.allocator, .{ .event = .pre_tool_use }));
}

test "protected-path example rejects equivalent paths and symlink targets" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    var runner: Runner = .{ .io = std.testing.io, .root = root, .set = .{} };
    const script_path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, "examples/hooks/protect-paths.sh", a);
    defer a.free(script_path);
    const script = try std.fmt.allocPrint(a, "bash '{s}'", .{script_path});
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
        var denied = try runner.evaluate(a, .{ .event = .pre_tool_use, .tool_name = "write", .tool_input = arguments });
        defer denied.deinit(a);
        try std.testing.expect(denied.blocked != null);
    }
    var allowed = try runner.evaluate(a, .{ .event = .pre_tool_use, .tool_name = "write", .tool_input = "{\"path\":\"safe\"}" });
    defer allowed.deinit(a);
    try std.testing.expect(allowed.blocked == null);
    try tmp.dir.createDir(std.testing.io, "bin", .default_dir);
    const without_python = try std.fmt.allocPrint(a, "PATH=\"$(pwd -P)/bin\" \"$BASH\" '{s}'", .{script_path});
    defer a.free(without_python);
    runner.set.pre_tool_use = &.{.{ .command = without_python }};
    try std.testing.expectError(error.HookCommandUnavailable, runner.evaluate(a, .{ .event = .pre_tool_use, .tool_name = "write", .tool_input = "{\"path\":\".env\"}" }));
}

test "a deadline kills descendants before they can finish later work" {
    if (!HookCommand.supports_process_groups) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    const runner: Runner = .{ .io = std.testing.io, .root = root, .timeout_ms = 50, .set = .{ .pre_tool_use = &.{.{ .command = "(sleep 0.3; touch survived) & wait" }} } };
    try std.testing.expectError(error.Timeout, runner.evaluate(std.testing.allocator, .{ .event = .pre_tool_use }));
    try std.Io.sleep(std.testing.io, .fromMilliseconds(400), .awake);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "survived", .{}));
}

test "policy regex budget exhaustion fails visibly" {
    const a = std.testing.allocator;
    const input = try a.alloc(u8, 2000);
    defer a.free(input);
    @memset(input, 'a');
    const runner: Runner = .{ .io = std.testing.io, .root = ".", .set = .{ .pre_tool_use = &.{.{ .matcher = "(a|aa)*b", .command = "true" }} } };
    try std.testing.expectError(error.RegexResourceLimit, runner.evaluate(a, .{ .event = .pre_tool_use, .tool_name = input }));
}

test "hook notices cannot inject terminal control sequences" {
    const runner: Runner = .{ .io = std.testing.io, .root = ".", .set = .{ .pre_tool_use = &.{.{ .command = "printf '%s' '{\"systemMessage\":\"\\u001b[31mred\\u001b[0m\"}'" }} } };
    var result = try runner.evaluate(std.testing.allocator, .{ .event = .pre_tool_use });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("red", result.message.?);
}

test "permission and retry hooks reject malformed output and preserve blocking reasons" {
    const block: Hook = .{ .source = "team policy", .command = "echo blocked >&2; exit 2" };
    var runner: Runner = .{ .io = std.testing.io, .root = ".", .set = .{ .permission_evaluate = &.{block}, .model_retry = &.{block} } };
    var result = try runner.evaluate(std.testing.allocator, .{ .event = .permission_evaluate });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("[Hook team policy]\nblocked", result.blocked.?);
    try std.testing.expectError(error.HookBlocked, runner.evaluate(std.testing.allocator, .{ .event = .model_retry }));
    const malformed: Hook = .{ .command = "printf invalid" };
    runner.set = .{ .permission_evaluate = &.{malformed}, .model_retry = &.{malformed} };
    for ([_]Event{ .permission_evaluate, .model_retry }) |event| {
        try std.testing.expectError(error.SyntaxError, runner.evaluate(std.testing.allocator, .{ .event = event }));
    }
}

test "missing or unexecutable completion policies fail closed" {
    const a = std.testing.allocator;
    inline for (.{ Event.stop, Event.subagent_stop }) |event| {
        for ([_][]const u8{ "exit 126", "synth-no-such-hook-command" }) |command| {
            var set: Set = .{};
            @field(set, @tagName(event)) = &.{.{ .command = command }};
            const runner: Runner = .{ .io = std.testing.io, .root = ".", .set = set };
            try std.testing.expectError(error.HookCommandUnavailable, runner.evaluate(a, .{ .event = event }));
        }
    }
}

test "a failing hook blocks request events and lets other events continue unless told otherwise" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const failing: Hook = .{ .command = "exit 1" };
    const failing_but_continuing: Hook = .{ .command = "exit 1", .on_failure = .@"continue" };
    const failing_and_blocking: Hook = .{ .command = "exit 1", .on_failure = .block };
    var runner: Runner = .{ .io = std.testing.io, .root = root, .set = .{
        .model_context = &.{failing},
        .http_request = &.{failing_but_continuing},
        .pre_tool_use = &.{failing},
    } };
    try std.testing.expectError(error.HookCommandFailed, runner.evaluate(a, .{ .event = .model_context }));
    var tolerated_request = try runner.evaluate(a, .{ .event = .http_request });
    tolerated_request.deinit(a);
    var tolerated_tool = try runner.evaluate(a, .{ .event = .pre_tool_use, .tool_name = "write", .tool_input = "{}" });
    tolerated_tool.deinit(a);
    runner.set.pre_tool_use = &.{failing_and_blocking};
    try std.testing.expectError(error.HookCommandFailed, runner.evaluate(a, .{ .event = .pre_tool_use, .tool_name = "write", .tool_input = "{}" }));
}

test "upstream hook files load: wrapper, unknown events and keys, input on MCP handlers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\{"description":"lint","hooks":{
        \\  "PreToolUse":[{"matcher":"Bash","hooks":[
        \\    {"type":"command","command":"true","statusMessage":"checking","commandWindows":"x"},
        \\    {"type":"mcp_tool","server":"s","tool":"t","input":{"q":"${tool_name}"}}]}],
        \\  "SomethingNew":[{"hooks":[{"command":"true"}]}]}}
    ;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, source, .{});
    const set = try parse(a, parsed, "hooks.json");
    try std.testing.expectEqual(@as(usize, 2), set.pre_tool_use.len);
    try std.testing.expect(set.pre_tool_use[1].arguments == .object);
}

test "MCP hook declarations reject command exit-code overrides" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\{"PreToolUse":[{"hooks":[{"type":"mcp_tool","server":"s","tool":"t","arguments":{},"onFailure":"continue"}]}]}
    ;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, source, .{});
    try testing.expectError(error.InvalidHookDefinition, parse(a, parsed, "hooks.json"));
}

test "a flat hook definition from the old format says how to group it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"PreToolUse\":[{\"matcher\":\"bash\",\"command\":\"true\"}]}", .{});
    try std.testing.expectError(error.FlatHookFormatNeedsGrouping, parse(a, parsed, "hooks.json"));
    const mixed = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"hooks\":{},\"extra\":1}", .{});
    try std.testing.expectError(error.InvalidHooks, parse(a, mixed, "hooks.json"));
}

test "when filters on the declared class of the model and reaches the hook input" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    const source =
        \\{"PreToolUse":[{"when":{"trust":["local","private"],"tier":"small"},"hooks":[{"command":"cat > payload; printf '{\"decision\":\"block\",\"reason\":\"small local model\"}'"}]}]}
    ;
    const set = try parse(a, try std.json.parseFromSliceLeaky(std.json.Value, a, source, .{}), "hooks.json");
    const classes = [_]ModelClass.Class{
        .{ .model = "qwen3:27b", .trust = .local, .tier = .small },
        .{ .model = "astra", .trust = .hosted, .tier = .frontier },
    };
    const runner: Runner = .{ .io = std.testing.io, .root = root, .set = set, .classes = &classes };
    var local = try runner.evaluate(a, .{ .event = .pre_tool_use, .tool_name = "bash", .model = "qwen3:27b" });
    defer local.deinit(a);
    try std.testing.expect(local.blocked != null);
    var frontier = try runner.evaluate(a, .{ .event = .pre_tool_use, .tool_name = "bash", .model = "astra" });
    defer frontier.deinit(a);
    try std.testing.expect(frontier.blocked == null);
    const payload = try tmp.dir.readFileAlloc(std.testing.io, "payload", a, .limited(1 << 16));
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"model_trust\":\"local\"") != null);
}

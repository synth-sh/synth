const std = @import("std");
const builtin = @import("builtin");
pub const Result = @import("hook_result.zig").Result;
const output = @import("hook_result.zig");
const regex = @import("regex.zig");

const stderr_limit: usize = 64 * 1024;
const poll_slice_ms: u64 = 100;
pub const default_timeout_ms: u64 = 30_000;
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

    pub fn name(self: Event) []const u8 {
        return switch (self) {
            .session_start => "SessionStart",
            .session_end => "SessionEnd",
            .user_prompt_submit => "UserPromptSubmit",
            .pre_tool_use => "PreToolUse",
            .permission_request => "PermissionRequest",
            .post_tool_use => "PostToolUse",
            .pre_compact => "PreCompact",
            .post_compact => "PostCompact",
            .subagent_start => "SubagentStart",
            .subagent_stop => "SubagentStop",
            .stop => "Stop",
            .interrupt => "Interrupt",
            .pre_model_request => "PreModelRequest",
            .post_model_request => "PostModelRequest",
        };
    }
    pub fn fromName(value: []const u8) ?Event {
        inline for (std.meta.tags(Event)) |event| {
            if (std.mem.eql(u8, event.name(), value)) return event;
        }
        return null;
    }
    pub fn toolMatcher(self: Event) bool {
        return self == .pre_tool_use or self == .post_tool_use or self == .permission_request;
    }
};

pub const Hook = struct {
    matcher: []const u8 = "",
    command: []const u8 = "",
    legacy: bool = true,
    id: []const u8 = "",
    trusted: bool = true,
    enabled: bool = true,
    transcript: bool = false,
    source: []const u8 = "config",
    timeout_ms: ?u64 = null,
    async: bool = false,
    type: enum { command, mcp_tool } = .command,
    server: []const u8 = "",
    tool: []const u8 = "",
    arguments: std.json.Value = .null,
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

    pub fn forEvent(self: Set, event: Event) []const Hook {
        return switch (event) {
            .session_start => self.session_start,
            .session_end => self.session_end,
            .user_prompt_submit => self.user_prompt_submit,
            .pre_tool_use => self.pre_tool_use,
            .permission_request => self.permission_request,
            .post_tool_use => self.post_tool_use,
            .pre_compact => self.pre_compact,
            .post_compact => self.post_compact,
            .subagent_start => self.subagent_start,
            .subagent_stop => self.subagent_stop,
            .stop => self.stop,
            .interrupt => self.interrupt,
            .pre_model_request => self.pre_model_request,
            .post_model_request => self.post_model_request,
        };
    }
    pub fn append(self: *Set, allocator: std.mem.Allocator, other: Set) !void {
        inline for (std.meta.fields(Set)) |field| {
            const old = @field(self, field.name);
            const added = @field(other, field.name);
            if (added.len > 0) @field(self, field.name) = try std.mem.concat(allocator, Hook, &.{ old, added });
        }
    }
};

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
            const matcher = if (definition.object.get("matcher")) |m| blk: {
                if (m != .string) return error.InvalidHookMatcher;
                break :blk m.string;
            } else "";
            if (definition.object.get("hooks")) |group| {
                if (group != .array or definition.object.contains("command")) return error.InvalidHooks;
                var group_fields = definition.object.iterator();
                while (group_fields.next()) |field| {
                    if (!std.mem.eql(u8, field.key_ptr.*, "matcher") and !std.mem.eql(u8, field.key_ptr.*, "hooks")) return error.InvalidHookDefinition;
                }
                for (group.array.items) |handler| {
                    try validateDefinition(handler, false);
                    const encoded = try std.json.Stringify.valueAlloc(allocator, handler, .{});
                    var hook = try std.json.parseFromSliceLeaky(Hook, allocator, encoded, .{});
                    if (hook.type == .command and hook.command.len == 0) return error.InvalidHooks;
                    if (hook.type == .mcp_tool and (hook.server.len == 0 or hook.tool.len == 0 or hook.async or event == .session_end)) return error.InvalidHooks;
                    if (hook.async and event == .session_end) return error.InvalidHooks;
                    if (hook.timeout_ms) |ms| try validTimeout(ms);
                    hook.matcher = matcher;
                    hook.source = source;
                    hook.legacy = false;
                    if (event.toolMatcher() and matcher.len > 0 and !std.mem.eql(u8, matcher, "*")) {
                        var compiled = try compileMatcher(allocator, matcher);
                        compiled.deinit();
                    }
                    try hooks.append(allocator, hook);
                }
            } else {
                try validateDefinition(definition, true);
                const encoded = try std.json.Stringify.valueAlloc(allocator, definition, .{});
                var hook = try std.json.parseFromSliceLeaky(Hook, allocator, encoded, .{});
                if (hook.command.len == 0 or hook.type != .command or hook.async) return error.InvalidHooks;
                if (hook.timeout_ms) |ms| try validTimeout(ms);
                hook.source = source;
                hook.legacy = true;
                try hooks.append(allocator, hook);
            }
        }
        inline for (std.meta.fields(Set)) |field| {
            if (event == @field(Event, field.name)) @field(set, field.name) = hooks.items;
        }
    }
    return set;
}

fn validateDefinition(value: std.json.Value, legacy: bool) !void {
    if (value != .object) return error.InvalidHooks;
    var entries = value.object.iterator();
    while (entries.next()) |entry| {
        const key = entry.key_ptr.*;
        if (legacy and std.mem.eql(u8, key, "matcher")) continue;
        var valid = false;
        inline for (.{ "type", "command", "timeout_ms", "async", "server", "tool", "arguments", "transcript" }) |allowed| {
            if (std.mem.eql(u8, key, allowed)) valid = true;
        }
        if (!valid) return error.InvalidHookDefinition;
    }
}

pub const Invocation = struct {
    event: Event,
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
    started_ms: i64,
    duration_ms: i64,
    status: []const u8,
    exit_code: ?u8 = null,
    error_name: []const u8 = "",
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
    temp_dir: ?[]u8 = null,
    temp_mutex: std.Io.Mutex = .init,

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
        var record_value: Record = .{ .event = invocation.event, .started_ms = started, .duration_ms = std.Io.Clock.now(.awake, self.io).toMilliseconds() - started, .status = status };
        record_value.exit_code = exit_code;
        record_value.error_name = error_name;
        inline for (.{ .{ "session_id", "session_id" }, .{ "turn_id", "turn_id" }, .{ "call_id", "tool_call_id" } }) |pair| {
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
        while (true) {
            self.background_mutex.lockUncancelable(self.io);
            if (self.background.items.len < 64) {
                defer self.background_mutex.unlock(self.io);
                var session_runner = runner;
                session_runner.stop = &self.stop;
                const job = try Job.start(self.allocator, session_runner, hook, invocation, null);
                errdefer job.destroy();
                try self.background.append(self.allocator, job);
                return;
            }
            const oldest = self.background.orderedRemove(0);
            self.background_mutex.unlock(self.io);
            defer oldest.destroy();
            oldest.join();
            self.background_mutex.lockUncancelable(self.io);
            defer self.background_mutex.unlock(self.io);
            try self.collect(oldest);
        }
    }
    fn collect(self: *Runtime, job: *Job) !void {
        if (job.failed) |err| {
            const message = try std.fmt.allocPrint(self.allocator, "Background hook failed: {s}", .{@errorName(err)});
            if (self.pending.message) |old| self.allocator.free(old);
            self.pending.message = message;
            return;
        }
        if (job.result.blocked != null or job.result.replacement != null or job.result.permission != null or job.result.feedback != null or job.result.stop) {
            if (job.result.message) |old| job.arena.allocator().free(old);
            job.result.message = try job.arena.allocator().dupe(u8, "Background hook control effects were ignored");
        }
        job.result.blocked = null;
        job.result.replacement = null;
        job.result.feedback = null;
        job.result.permission = null;
        job.result.stop = false;
        try self.pending.merge(self.allocator, job.result);
        try self.bound(self.allocator, &self.pending);
    }
    pub fn notice(self: *Runtime, message: []const u8) !void {
        self.background_mutex.lockUncancelable(self.io);
        defer self.background_mutex.unlock(self.io);
        const copy = try self.allocator.dupe(u8, message);
        if (self.pending.message) |old| self.allocator.free(old);
        self.pending.message = copy;
        try self.bound(self.allocator, &self.pending);
    }
    pub fn drain(self: *Runtime, allocator: std.mem.Allocator) !Result {
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
        try result.merge(allocator, self.pending);
        self.pending.deinit(self.allocator);
        return result;
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
        inline for (.{ "context", "message", "blocked" }) |field| {
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
        self.pending.deinit(self.allocator);
        self.stop.store(false, .release);
    }
    pub fn deinit(self: *Runtime) void {
        self.cancelBackground();
        self.background.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        if (self.temp_dir) |path| {
            std.Io.Dir.cwd().deleteTree(self.io, path) catch {};
            self.allocator.free(path);
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
    completion: ?*std.atomic.Value(usize),
    order: usize = 0,
    future: std.Io.Future(void) = undefined,
    joined: bool = false,
    done: std.atomic.Value(bool) = .init(false),

    fn start(allocator: std.mem.Allocator, runner: Runner, hook: Hook, invocation: Invocation, completion: ?*std.atomic.Value(usize)) !*Job {
        const self = try allocator.create(Job);
        self.* = .{ .allocator = allocator, .arena = .init(allocator), .runner = runner, .hook = hook, .invocation = invocation, .completion = completion };
        errdefer {
            self.arena.deinit();
            allocator.destroy(self);
        }
        self.invocation = try invocation.dupe(self.arena.allocator());
        self.future = try runner.io.concurrent(run, .{self});
        return self;
    }
    fn run(self: *Job) void {
        defer {
            if (self.completion) |counter| self.order = counter.fetchAdd(1, .acq_rel) + 1;
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
        const definitions = self.set.forEvent(invocation.event);
        var at: usize = 0;
        var completion: std.atomic.Value(usize) = .init(0);
        var replacement_order: usize = 0;
        var failure: ?anyerror = null;
        while (at < definitions.len) {
            const hook = definitions[at];
            if (self.givenUp()) return error.Cancelled;
            if (!hook.enabled or !try hookMatches(allocator, hook, invocation)) {
                at += 1;
                continue;
            }
            if (!hook.trusted) return error.HookNeedsReview;
            if (hook.legacy) {
                var result = try self.runHook(allocator, hook, invocation);
                defer result.deinit(allocator);
                try outcome.merge(allocator, result);
                at += 1;
                if (outcome.blocked != null) break;
                continue;
            }
            var jobs: [8]?*Job = @splat(null);
            defer for (jobs) |maybe| {
                if (maybe) |job| job.destroy();
            };
            var count: usize = 0;
            while (at < definitions.len and !definitions[at].legacy and count < jobs.len) : (at += 1) {
                const grouped = definitions[at];
                if (!grouped.enabled or !try hookMatches(allocator, grouped, invocation)) continue;
                if (!grouped.trusted) return error.HookNeedsReview;
                if (grouped.async) {
                    const runtime = self.runtime orelse return error.BackgroundHooksUnavailable;
                    try runtime.launch(self, grouped, invocation);
                } else {
                    jobs[count] = try Job.start(allocator, self, grouped, invocation, &completion);
                    count += 1;
                }
            }
            for (jobs[0..count]) |maybe| {
                const job = maybe.?;
                job.join();
                if (job.failed) |err| {
                    if (failure == null) failure = err;
                    continue;
                }
                if (job.order < replacement_order) {
                    if (job.result.replacement) |old| job.arena.allocator().free(old);
                    job.result.replacement = null;
                } else if (job.result.replacement != null) replacement_order = job.order;
                try outcome.merge(allocator, job.result);
            }
            if (self.runtime) |runtime| try runtime.bound(allocator, &outcome);
        }
        if (failure) |err| return err;
        return outcome;
    }

    fn runHook(self: Runner, allocator: std.mem.Allocator, hook: Hook, invocation: Invocation) !Result {
        if (self.runtime) |runtime| try runtime.enter(self.stop, self.deadline_ms);
        defer if (self.runtime) |runtime| runtime.leave();
        var configured = self;
        configured.timeout_ms = hook.timeout_ms orelse self.timeout_ms;
        if (invocation.event == .session_end or invocation.event == .interrupt) configured.timeout_ms = @min(hook.timeout_ms orelse 1000, 3000);
        const started = std.Io.Clock.now(.awake, self.io).toMilliseconds();
        if (self.deadline_ms) |deadline| {
            if (started >= deadline) return error.Timeout;
            configured.timeout_ms = @min(configured.timeout_ms, @as(u64, @intCast(deadline - started)));
        }
        if (self.runtime) |runtime| runtime.record(hook, invocation, started, "started", null, "");
        var exit_code: ?u8 = null;
        const result = configured.executeHook(allocator, hook, invocation, &exit_code) catch |err| {
            if (self.runtime) |runtime| runtime.record(hook, invocation, started, "failed", exit_code, @errorName(err));
            return err;
        };
        if (self.runtime) |runtime| runtime.record(hook, invocation, started, "completed", exit_code, "");
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
        const advisory = invocation.event == .pre_model_request or invocation.event == .post_model_request or invocation.event == .interrupt or invocation.event == .session_end or invocation.event == .subagent_start;
        if (command.code == 2 and advisory) {
            result.message = try allocator.dupe(u8, "Observation hook exited 2; control effect ignored");
        } else if (command.code == 2 and (invocation.event != .post_tool_use or !hook.legacy)) {
            const reason = std.mem.trim(u8, command.stderr, " \t\r\n");
            result.blocked = try allocator.dupe(u8, if (reason.len > 0) reason else "blocked by hook");
        } else if (!hook.legacy and command.code == 0) {
            result = try output.parse(allocator, command.stdout, invocation.event.name());
        }
        if (result.feedback != null and !std.mem.startsWith(u8, invocation.tool_name, "mcp__")) return error.UnsupportedHookEffect;
        inline for (.{ "context", "blocked", "feedback" }) |field| {
            if (@field(result, field)) |text_value| {
                if (!hook.legacy or !std.mem.eql(u8, field, "blocked")) {
                    const attributed = try std.fmt.allocPrint(allocator, "[Hook {s}{s}]\n{s}", .{ hook.source, if (hook.type == .mcp_tool) " / external MCP tool" else "", text_value });
                    allocator.free(text_value);
                    @field(result, field) = attributed;
                }
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

        while (!stderr_done or !input.done.load(.acquire)) {
            // Returning runs the `killGroup` defer, taking the whole group.
            if (self.givenUp()) return error.Cancelled;
            const left = deadline - std.Io.Clock.now(.awake, self.io).toMilliseconds();
            if (left <= 0) return error.Timeout;
            const slice = @min(poll_slice_ms, @as(u64, @intCast(left)));

            if (stderr_done) {
                try std.Io.sleep(self.io, .fromMilliseconds(@intCast(slice)), .awake);
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
        while (!waiter.done.load(.acquire)) {
            const expired = deadline - std.Io.Clock.now(.awake, self.io).toMilliseconds() <= 0;
            if (self.givenUp() or expired) {
                if (posix_signals) {
                    std.posix.kill(-pid, .TERM) catch {};
                    std.posix.kill(-pid, .KILL) catch {};
                }
                wait_future.await(self.io);
                reaped = true;
                if (expired) return error.Timeout;
                return error.Cancelled;
            }
            std.Io.sleep(self.io, .fromMilliseconds(poll_slice_ms), .awake) catch {};
        }
        wait_future.await(self.io);
        reaped = true;
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
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *ChildWait) void {
        self.term = self.child.wait(self.io);
        self.done.store(true, .release);
    }
};

const InputWrite = struct {
    io: std.Io,
    child: *std.process.Child,
    payload: []const u8,
    done: std.atomic.Value(bool) = .init(false),

    fn run(self: *InputWrite) void {
        defer self.done.store(true, .release);
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
    if (!invocation.event.toolMatcher()) return true;
    if (hook.legacy) return matches(hook.matcher, invocation.tool_name);
    if (hook.matcher.len == 0 or std.mem.eql(u8, hook.matcher, "*")) return true;
    var compiled = try compileMatcher(allocator, hook.matcher);
    defer compiled.deinit();
    if (try compiled.checkedMatches(invocation.tool_name)) return true;
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
    try std.json.Stringify.encodeJsonString(root, .{}, w);

    inline for (.{ "session_id", "turn_id", "tool_call_id", "agent_id", "agent_type", "model", "permission_mode", "source", "trigger", "status", "error_message", "parent_session_id", "reason" }) |field| {
        try w.writeAll(",\"" ++ field ++ "\":");
        try std.json.Stringify.encodeJsonString(@field(invocation, field), .{}, w);
    }
    try w.writeAll(",\"tool_use_id\":");
    try std.json.Stringify.encodeJsonString(invocation.tool_call_id, .{}, w);
    try w.writeAll(",\"last_assistant_message\":");
    try std.json.Stringify.value(invocation.last_assistant_message, .{}, w);
    try w.print(",\"request_id\":{d},\"attempt\":{d}", .{ invocation.request_id, invocation.attempt });
    if (invocation.event == .subagent_stop) {
        try w.writeAll(",\"agent_transcript_path\":");
        try std.json.Stringify.value(invocation.transcript_path, .{}, w);
    }
    try w.writeAll(",\"transcript_path\":");
    try std.json.Stringify.value(invocation.transcript_path, .{}, w);
    try w.print(",\"stop_hook_active\":{s},\"input_tokens\":{d},\"output_tokens\":{d}", .{ if (invocation.stop_hook_active) "true" else "false", invocation.input_tokens, invocation.output_tokens });
    if (invocation.event == .user_prompt_submit) {
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
    if (invocation.event == .post_tool_use) {
        try w.writeAll(",\"tool_response\":");
        try std.json.Stringify.encodeJsonString(invocation.tool_response, .{}, w);
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

test "grouped hooks all run despite denial and the last completed rewrite wins" {
    const a = std.testing.allocator;
    const slow: Hook = .{ .legacy = false, .command = "sleep 0.08; printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":{\"command\":\"slow\"}}}'" };
    const fast: Hook = .{ .legacy = false, .command = "printf '%s' '{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"updatedInput\":{\"command\":\"fast\"}}}'" };
    var runtime: Runtime = .{ .allocator = a, .io = std.testing.io };
    defer runtime.deinit();
    const runner: Runner = .{ .io = std.testing.io, .root = ".", .runtime = &runtime, .set = .{ .pre_tool_use = &.{ slow, fast, .{ .legacy = false, .command = "exit 2" } } } };
    var result = try runner.evaluate(a, .{ .event = .pre_tool_use });
    defer result.deinit(a);
    try std.testing.expect(result.blocked != null);
    try std.testing.expectEqualStrings("{\"command\":\"slow\"}", result.replacement.?);
    try std.testing.expectEqual(@as(usize, 6), runtime.records_len);
    try std.testing.expectEqual(@as(usize, 0), runtime.active.load(.acquire));
}

test "grouped matcher aliases and alternation invoke a handler once" {
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
    var delivered = try runtime.drain(a);
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
    const definitions = [_]Hook{.{ .legacy = false, .type = .mcp_tool, .server = "test", .tool = "gate" }} ** 8;
    const runner: Runner = .{ .io = std.testing.io, .root = ".", .runtime = &runtime, .mcp_executor = .{ .userdata = &probe, .call = Probe.call }, .set = .{ .pre_tool_use = &definitions } };
    const first = try Dispatch.start(a, runner, .{ .event = .pre_tool_use });
    defer first.destroy();
    const second = try Dispatch.start(a, runner, .{ .event = .pre_tool_use });
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

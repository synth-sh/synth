const std = @import("std");
const Event = @import("hooks.zig").Event;
const HooksCopy = @import("hooks_copy.zig");

pub const Permission = enum { allow, deny, ask };
pub const HttpPatch = struct { headers: ?std.json.Value = null, status: ?u16 = null, body: ?std.json.Value = null, drop: bool = false };

const PatchField = enum { messages, tools, headers, drop };
const OutputField = enum { @"continue", suppressOutput, systemMessage, reason, stopReason, decision, hookSpecificOutput };
const Decision = enum { block, approve };
const SpecificField = enum {
    hookEventName,
    requestContext,
    http,
    effect,
    reason,
    route,
    contextEdits,
    settings,
    retryAllowed,
    retryDelayMs,
    additionalContext,
    displayContent,
    retry,
    updatedInput,
    permissionDecision,
    updatedMCPToolOutput,
    permissionDecisionReason,
    decision,
};
const PermissionEffect = enum { allow, deny, ask, @"defer" };
const PermissionRequestField = enum { behavior, message, interrupt, updatedInput, updatedPermissions };

pub const Result = struct {
    request_context: ?[]u8 = null,
    http: ?[]u8 = null,
    model_route: ?[]u8 = null,
    context_edits: ?[]u8 = null,
    settings: ?[]u8 = null,
    retry_allowed: ?bool = null,
    retry_delay_ms: ?u64 = null,
    blocked: ?[]u8 = null,
    context: ?[]u8 = null,
    message: ?[]u8 = null,
    replacement: ?[]u8 = null,
    replacement_author: ?usize = null,
    feedback: ?[]u8 = null,
    permission: ?Permission = null,
    stop: bool = false,
    retry: bool = false,
    display_content: ?[]u8 = null,

    pub const Field = std.meta.FieldEnum(Result);

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        inline for ([_]Field{ .request_context, .http, .model_route, .context_edits, .settings, .blocked, .context, .message, .replacement, .feedback, .display_content }) |field| {
            if (@field(self, @tagName(field))) |value| allocator.free(value);
        }
        self.* = .{};
    }

    pub fn takeBlocked(self: *Result) ?[]u8 {
        const reason_text = self.blocked;
        self.blocked = null;
        return reason_text;
    }

    fn decide(self: *Result, value: Permission) void {
        if (value == .deny or self.permission == null or (value == .ask and self.permission != .deny)) self.permission = value;
    }

    pub fn merge(self: *Result, allocator: std.mem.Allocator, other: Result) !void {
        if (other.blocked) |value| {
            if (self.blocked == null) self.blocked = try allocator.dupe(u8, value);
        }
        inline for ([_]Field{ .context, .message }) |field| {
            const name = @tagName(field);
            if (@field(other, name)) |value| {
                const combined = if (@field(self, name)) |old|
                    try std.fmt.allocPrint(allocator, HooksCopy.join_lines, .{ old, value })
                else
                    try allocator.dupe(u8, value);
                if (@field(self, name)) |old| allocator.free(old);
                @field(self, name) = combined;
            }
        }
        inline for ([_]Field{ .request_context, .http, .model_route, .context_edits, .settings, .replacement, .feedback, .display_content }) |field| {
            const name = @tagName(field);
            if (@field(other, name)) |value| {
                const copy = if (@field(self, name)) |old| switch (field) {
                    .request_context, .settings, .http, .context_edits => try combine(allocator, old, value, field),
                    else => try allocator.dupe(u8, value),
                } else try allocator.dupe(u8, value);
                if (@field(self, name)) |old| allocator.free(old);
                @field(self, name) = copy;
            }
        }
        if (other.permission) |value| self.decide(value);
        if (other.retry_allowed) |allowed| self.retry_allowed = if (self.retry_allowed == false) false else allowed;
        if (other.retry_delay_ms) |delay| self.retry_delay_ms = delay;
        self.stop = self.stop or other.stop;
        self.retry = self.retry or other.retry;
    }
};

fn combine(allocator: std.mem.Allocator, before: []const u8, after: []const u8, kind: Result.Field) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var lhs = try std.json.parseFromSliceLeaky(std.json.Value, a, before, .{});
    const rhs = try std.json.parseFromSliceLeaky(std.json.Value, a, after, .{});
    if (kind == .context_edits) {
        try lhs.array.appendSlice(rhs.array.items);
    } else {
        var it = rhs.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            if (value == .null) continue;
            if (lhs.object.getPtr(key)) |old| {
                if (std.meta.stringToEnum(PatchField, key)) |field| switch (field) {
                    .messages => {
                        try old.array.appendSlice(value.array.items);
                        continue;
                    },
                    .tools => if (old.* == .array and value == .array) {
                        var kept: std.array_list.Managed(std.json.Value) = .init(a);
                        for (old.array.items) |candidate| {
                            for (value.array.items) |allowed| if (std.mem.eql(u8, candidate.string, allowed.string)) {
                                try kept.append(candidate);
                                break;
                            };
                        }
                        old.* = .{ .array = kept };
                        continue;
                    },
                    .headers => if (old.* == .object and value == .object) {
                        var headers = value.object.iterator();
                        while (headers.next()) |header| try old.object.put(a, header.key_ptr.*, header.value_ptr.*);
                        continue;
                    },
                    .drop => if (old.* == .bool and value == .bool) {
                        old.bool = old.bool or value.bool;
                        continue;
                    },
                };
            }
            try lhs.object.put(a, key, value);
        }
    }
    return std.json.Stringify.valueAlloc(allocator, lhs, .{});
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8, event: Event) !Result {
    if (std.mem.trim(u8, source, " \r\n\t").len == 0) return .{};
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidHookOutput;
    var result: Result = .{};
    errdefer result.deinit(allocator);
    var fields = root.object.iterator();
    while (fields.next()) |entry| {
        const key = std.meta.stringToEnum(OutputField, entry.key_ptr.*) orelse return error.UnsupportedHookEffect;
        const value = entry.value_ptr.*;
        if (value == .null) switch (key) {
            .systemMessage, .stopReason, .reason, .decision, .hookSpecificOutput => continue,
            else => {},
        };
        switch (key) {
            .@"continue" => {
                if (value != .bool) return error.InvalidHookOutput;
                result.stop = !value.bool;
            },
            .suppressOutput => if (value != .bool) return error.InvalidHookOutput,
            .systemMessage => result.message = try string(allocator, value),
            .reason, .stopReason => _ = try text(value),
            .decision => {
                const name = try text(value);
                if (!event.oneOf(&.{ .pre_tool_use, .post_tool_use, .user_prompt_submit, .stop, .subagent_stop, .post_tool_batch, .task_created, .task_completed, .pre_model_switch, .user_prompt_expansion, .config_change })) return error.UnsupportedHookEffect;
                switch (std.meta.stringToEnum(Decision, name) orelse return error.InvalidHookOutput) {
                    .block => {
                        const blocked = try reason(allocator, root, @tagName(OutputField.reason));
                        if (result.blocked) |old| allocator.free(old);
                        result.blocked = blocked;
                    },
                    .approve => {
                        if (event != .pre_tool_use) return error.InvalidHookOutput;
                        result.decide(.allow);
                    },
                }
            },
            .hookSpecificOutput => {
                if (value != .object) return error.InvalidHookOutput;
                const named = value.object.get(@tagName(SpecificField.hookEventName)) orelse return error.InvalidHookOutput;
                if (Event.fromName(try text(named)) != event) return error.InvalidHookEvent;
                try specific(allocator, &result, value, event);
            },
        }
    }
    if (event.observational() and (result.stop or result.blocked != null or result.replacement != null or result.permission != null)) return error.UnsupportedHookEffect;
    if (event.requestStage() and (result.stop or result.context != null or result.blocked != null or result.permission != null)) return error.UnsupportedHookEffect;
    if (event == .post_tool_use and result.stop) return error.UnsupportedHookEffect;
    if (event.oneOf(&.{ .task_created, .task_completed })) result.stop = false;
    if (result.stop and result.blocked == null) result.blocked = try reason(allocator, root, @tagName(OutputField.stopReason));
    return result;
}

fn specific(allocator: std.mem.Allocator, result: *Result, value: std.json.Value, event: Event) !void {
    var fields = value.object.iterator();
    while (fields.next()) |entry| {
        const key = std.meta.stringToEnum(SpecificField, entry.key_ptr.*) orelse return error.UnsupportedHookEffect;
        const field = entry.value_ptr.*;
        switch (key) {
            .hookEventName => {},
            .requestContext => {
                if (event != .model_context or field != .object) return error.UnsupportedHookEffect;
                result.request_context = try encodePatch(@import("request_context.zig").Patch, allocator, field);
            },
            .http => {
                if (!event.oneOf(&.{ .http_request, .http_response }) or field != .object) return error.UnsupportedHookEffect;
                result.http = try encodePatch(HttpPatch, allocator, field);
            },
            .effect => {
                if (event != .permission_evaluate) return error.UnsupportedHookEffect;
                result.decide(try parsePermissionEffect(field) orelse continue);
                if (result.permission == .deny and result.blocked == null) result.blocked = try reason(allocator, value, @tagName(SpecificField.reason));
            },
            .reason => {
                if (event != .permission_evaluate) return error.UnsupportedHookEffect;
                _ = try text(field);
            },
            .route => {
                if (event != .model_resolve) return error.UnsupportedHookEffect;
                result.model_route = try string(allocator, field);
            },
            .contextEdits => {
                if (event != .model_context or field != .array) return error.UnsupportedHookEffect;
                result.context_edits = try std.json.Stringify.valueAlloc(allocator, field, .{});
            },
            .settings => {
                if (event != .model_settings or field != .object) return error.UnsupportedHookEffect;
                result.settings = try encodePatch(@import("model_policy.zig").Settings, allocator, field);
            },
            .retryAllowed => {
                if (event != .model_retry or field != .bool) return error.UnsupportedHookEffect;
                result.retry_allowed = field.bool;
            },
            .retryDelayMs => {
                if (event != .model_retry or field != .integer or field.integer < 0 or field.integer > @import("../provider/retry.zig").max_delay_ms) return error.InvalidHookOutput;
                result.retry_delay_ms = @intCast(field.integer);
            },
            .additionalContext => {
                if (!event.oneOf(&.{ .pre_tool_use, .post_tool_use, .user_prompt_submit, .session_start, .subagent_start, .post_tool_use_failure, .post_tool_batch })) return error.UnsupportedHookEffect;
                if (field != .null) result.context = try string(allocator, field);
            },
            .displayContent => {
                if (event != .message_display) return error.UnsupportedHookEffect;
                if (field != .null) result.display_content = try string(allocator, field);
            },
            .retry => {
                if (event != .permission_denied) return error.UnsupportedHookEffect;
                if (field != .bool) return error.InvalidHookOutput;
                result.retry = field.bool;
            },
            .updatedInput => {
                if (event != .pre_tool_use) return error.UnsupportedHookEffect;
                if (field == .null) continue;
                if (field != .object) return error.InvalidHookOutput;
                result.replacement = try std.json.Stringify.valueAlloc(allocator, field, .{});
            },
            .permissionDecision => {
                if (event != .pre_tool_use) return error.UnsupportedHookEffect;
                if (field == .null) continue;
                result.decide(try parsePermissionEffect(field) orelse continue);
                if (result.permission == .deny and result.blocked == null) result.blocked = try reason(allocator, value, @tagName(SpecificField.permissionDecisionReason));
            },
            .updatedMCPToolOutput => {
                if (event != .post_tool_use) return error.UnsupportedHookEffect;
                if (field != .null) result.feedback = try std.json.Stringify.valueAlloc(allocator, field, .{});
            },
            .permissionDecisionReason => {
                if (event != .pre_tool_use) return error.UnsupportedHookEffect;
                if (field != .null) _ = try text(field);
            },
            .decision => {
                if (event != .permission_request) return error.UnsupportedHookEffect;
                if (field == .null) continue;
                result.decide(try permissionRequestDecision(field));
                if (result.permission == .ask) return error.InvalidHookOutput;
                if (result.permission == .deny) result.blocked = try reason(allocator, field, @tagName(PermissionRequestField.message));
            },
        }
    }
}

fn parsePermissionEffect(value: std.json.Value) !?Permission {
    const effect = std.meta.stringToEnum(PermissionEffect, try text(value)) orelse return error.InvalidHookOutput;
    return switch (effect) {
        .allow => .allow,
        .deny => .deny,
        .ask => .ask,
        .@"defer" => null,
    };
}

fn permissionRequestDecision(value: std.json.Value) !Permission {
    if (value != .object) return error.InvalidHookOutput;
    var behavior: ?[]const u8 = null;
    var entries = value.object.iterator();
    while (entries.next()) |item| {
        const name = std.meta.stringToEnum(PermissionRequestField, item.key_ptr.*) orelse return error.UnsupportedHookEffect;
        const field = item.value_ptr.*;
        switch (name) {
            .behavior => behavior = try text(field),
            .message => if (field != .null) {
                _ = try text(field);
            },
            .interrupt => {
                if (field != .bool) return error.InvalidHookOutput;
                if (field.bool) return error.UnsupportedHookEffect;
            },
            .updatedInput, .updatedPermissions => if (field != .null) return error.UnsupportedHookEffect,
        }
    }
    return std.meta.stringToEnum(Permission, behavior orelse return error.InvalidHookOutput) orelse error.InvalidHookOutput;
}

fn encodePatch(comptime T: type, allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    const parsed = try std.json.parseFromValue(T, allocator, value, .{});
    defer parsed.deinit();
    if (@hasDecl(T, "validate")) try parsed.value.validate();
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn text(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidHookOutput;
    return value.string;
}
fn string(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return allocator.dupe(u8, try text(value));
}
fn reason(allocator: std.mem.Allocator, object: std.json.Value, key: []const u8) ![]u8 {
    const field = object.object.get(key) orelse .null;
    const value = if (field == .null) "" else try text(field);
    return allocator.dupe(u8, if (value.len == 0) HooksCopy.blocked else value);
}

test "permission aggregation retains asks and denials over allowances" {
    var result: Result = .{};
    defer result.deinit(std.testing.allocator);
    try result.merge(std.testing.allocator, .{ .permission = .ask });
    try result.merge(std.testing.allocator, .{ .permission = .allow });
    try std.testing.expectEqual(Permission.ask, result.permission.?);
    try result.merge(std.testing.allocator, .{ .permission = .deny });
    try result.merge(std.testing.allocator, .{ .permission = .allow });
    try std.testing.expectEqual(Permission.deny, result.permission.?);
}

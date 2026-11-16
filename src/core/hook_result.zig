const std = @import("std");

pub const Permission = enum { allow, deny, ask };

pub const Result = struct {
    model_route: ?[]u8 = null,
    context_edits: ?[]u8 = null,
    settings: ?[]u8 = null,
    retry_allowed: ?bool = null,
    retry_delay_ms: ?u64 = null,
    blocked: ?[]u8 = null,
    context: ?[]u8 = null,
    message: ?[]u8 = null,
    replacement: ?[]u8 = null,
    feedback: ?[]u8 = null,
    permission: ?Permission = null,
    stop: bool = false,
    retry: bool = false,
    display_content: ?[]u8 = null,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        inline for (.{ "model_route", "context_edits", "settings", "blocked", "context", "message", "replacement", "feedback", "display_content" }) |field| {
            if (@field(self, field)) |value| allocator.free(value);
        }
        self.* = .{};
    }

    fn decide(self: *Result, value: Permission) void {
        if (value == .deny or self.permission == null or (value == .ask and self.permission != .deny)) self.permission = value;
    }

    pub fn merge(self: *Result, allocator: std.mem.Allocator, other: Result) !void {
        if (other.blocked) |value| {
            if (self.blocked == null) self.blocked = try allocator.dupe(u8, value);
        }
        inline for (.{ "context", "message" }) |field| {
            if (@field(other, field)) |value| {
                const combined = if (@field(self, field)) |old|
                    try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ old, value })
                else
                    try allocator.dupe(u8, value);
                if (@field(self, field)) |old| allocator.free(old);
                @field(self, field) = combined;
            }
        }
        inline for (.{ "model_route", "context_edits", "settings", "replacement", "feedback", "display_content" }) |field| {
            if (@field(other, field)) |value| {
                const copy = try allocator.dupe(u8, value);
                if (@field(self, field)) |old| allocator.free(old);
                @field(self, field) = copy;
            }
        }
        if (other.permission) |value| self.decide(value);
        if (other.retry_allowed) |allowed| self.retry_allowed = if (self.retry_allowed == false) false else allowed;
        if (other.retry_delay_ms) |delay| self.retry_delay_ms = delay;
        self.stop = self.stop or other.stop;
        self.retry = self.retry or other.retry;
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8, event: []const u8) !Result {
    if (std.mem.trim(u8, source, " \r\n\t").len == 0) return .{};
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidHookOutput;
    var result: Result = .{};
    errdefer result.deinit(allocator);
    var fields = root.object.iterator();
    while (fields.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (value == .null and oneOf(key, &.{ "systemMessage", "stopReason", "reason", "decision", "hookSpecificOutput" })) continue;
        if (std.mem.eql(u8, key, "continue")) {
            if (value != .bool) return error.InvalidHookOutput;
            result.stop = !value.bool;
        } else if (std.mem.eql(u8, key, "suppressOutput")) {
            if (value != .bool) return error.InvalidHookOutput;
        } else if (std.mem.eql(u8, key, "systemMessage")) {
            result.message = try string(allocator, value);
        } else if (std.mem.eql(u8, key, "reason") or std.mem.eql(u8, key, "stopReason")) {
            _ = try text(value);
        } else if (std.mem.eql(u8, key, "decision")) {
            const decision = try text(value);
            if (!oneOf(event, &.{ "PreToolUse", "PostToolUse", "UserPromptSubmit", "Stop", "SubagentStop", "PostToolBatch", "TaskCreated", "TaskCompleted", "PreModelSwitch", "UserPromptExpansion", "ConfigChange" })) return error.UnsupportedHookEffect;
            if (std.mem.eql(u8, decision, "block")) {
                if (result.blocked) |old| allocator.free(old);
                result.blocked = try reason(allocator, root, "reason");
            } else if (std.mem.eql(u8, event, "PreToolUse") and std.mem.eql(u8, decision, "approve")) {
                result.decide(.allow);
            } else return error.InvalidHookOutput;
        } else if (std.mem.eql(u8, key, "hookSpecificOutput")) {
            if (value != .object) return error.InvalidHookOutput;
            const named = value.object.get("hookEventName") orelse return error.InvalidHookOutput;
            if (!std.mem.eql(u8, try text(named), event)) return error.InvalidHookEvent;
            try specific(allocator, &result, value, event);
        } else return error.UnsupportedHookEffect;
    }
    if (oneOf(event, &.{ "PreModelRequest", "PostModelRequest", "SessionEnd", "Interrupt", "SubagentStart", "PostToolUseFailure", "PermissionDenied", "StopFailure", "Notification", "InstructionsLoaded", "FileChanged", "PostModelSwitch", "MessageDisplay", "CwdChanged", "DirectoryAdded" }) and (result.stop or result.blocked != null or result.replacement != null or result.permission != null)) return error.UnsupportedHookEffect;
    if (oneOf(event, &.{ "ModelResolve", "ModelContext", "ModelSettings", "ModelRetry" }) and (result.stop or result.context != null or result.blocked != null or result.permission != null)) return error.UnsupportedHookEffect;
    if (std.mem.eql(u8, event, "PostToolUse") and result.stop) return error.UnsupportedHookEffect;
    if (oneOf(event, &.{ "TaskCreated", "TaskCompleted" })) result.stop = false;
    if (result.stop and result.blocked == null) result.blocked = try reason(allocator, root, "stopReason");
    return result;
}

fn specific(allocator: std.mem.Allocator, result: *Result, value: std.json.Value, event: []const u8) !void {
    var fields = value.object.iterator();
    while (fields.next()) |entry| {
        const key = entry.key_ptr.*;
        const field = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "hookEventName")) continue;
        if (std.mem.eql(u8, key, "route")) {
            if (!std.mem.eql(u8, event, "ModelResolve")) return error.UnsupportedHookEffect;
            result.model_route = try string(allocator, field);
        } else if (std.mem.eql(u8, key, "contextEdits")) {
            if (!std.mem.eql(u8, event, "ModelContext") or field != .array) return error.UnsupportedHookEffect;
            result.context_edits = try std.json.Stringify.valueAlloc(allocator, field, .{});
        } else if (std.mem.eql(u8, key, "settings")) {
            if (!std.mem.eql(u8, event, "ModelSettings") or field != .object) return error.UnsupportedHookEffect;
            const encoded = try std.json.Stringify.valueAlloc(allocator, field, .{});
            errdefer allocator.free(encoded);
            const parsed = try std.json.parseFromSlice(@import("model_policy.zig").Settings, allocator, encoded, .{});
            defer parsed.deinit();
            try parsed.value.validate();
            result.settings = encoded;
        } else if (std.mem.eql(u8, key, "retryAllowed")) {
            if (!std.mem.eql(u8, event, "ModelRetry") or field != .bool) return error.UnsupportedHookEffect;
            result.retry_allowed = field.bool;
        } else if (std.mem.eql(u8, key, "retryDelayMs")) {
            if (!std.mem.eql(u8, event, "ModelRetry") or field != .integer or field.integer < 0 or field.integer > 60_000) return error.InvalidHookOutput;
            result.retry_delay_ms = @intCast(field.integer);
        } else if (std.mem.eql(u8, key, "additionalContext")) {
            if (!oneOf(event, &.{ "PreToolUse", "PostToolUse", "UserPromptSubmit", "SessionStart", "SubagentStart", "PostToolUseFailure", "PostToolBatch" })) return error.UnsupportedHookEffect;
            if (field == .null) continue;
            result.context = try string(allocator, field);
        } else if (std.mem.eql(u8, key, "displayContent")) {
            if (!std.mem.eql(u8, event, "MessageDisplay")) return error.UnsupportedHookEffect;
            if (field != .null) result.display_content = try string(allocator, field);
        } else if (std.mem.eql(u8, key, "retry")) {
            if (!std.mem.eql(u8, event, "PermissionDenied")) return error.UnsupportedHookEffect;
            if (field != .bool) return error.InvalidHookOutput;
            result.retry = field.bool;
        } else if (std.mem.eql(u8, key, "updatedInput")) {
            if (!std.mem.eql(u8, event, "PreToolUse")) return error.UnsupportedHookEffect;
            if (field == .null) continue;
            if (field != .object) return error.InvalidHookOutput;
            result.replacement = try std.json.Stringify.valueAlloc(allocator, field, .{});
        } else if (std.mem.eql(u8, key, "permissionDecision")) {
            if (!std.mem.eql(u8, event, "PreToolUse")) return error.UnsupportedHookEffect;
            if (field == .null) continue;
            result.decide(std.meta.stringToEnum(Permission, try text(field)) orelse return error.InvalidHookOutput);
            if (result.permission == .deny and result.blocked == null) result.blocked = try reason(allocator, value, "permissionDecisionReason");
        } else if (std.mem.eql(u8, key, "updatedMCPToolOutput")) {
            if (!std.mem.eql(u8, event, "PostToolUse")) return error.UnsupportedHookEffect;
            if (field == .null) continue;
            result.feedback = try std.json.Stringify.valueAlloc(allocator, field, .{});
        } else if (std.mem.eql(u8, key, "permissionDecisionReason")) {
            if (!std.mem.eql(u8, event, "PreToolUse")) return error.UnsupportedHookEffect;
            if (field == .null) continue;
            _ = try text(field);
        } else if (std.mem.eql(u8, key, "decision")) {
            if (!std.mem.eql(u8, event, "PermissionRequest")) return error.UnsupportedHookEffect;
            if (field == .null) continue;
            if (field != .object) return error.InvalidHookOutput;
            var entries = field.object.iterator();
            while (entries.next()) |item| {
                const name = item.key_ptr.*;
                const item_value = item.value_ptr.*;
                if (std.mem.eql(u8, name, "behavior")) {
                    _ = try text(item_value);
                } else if (std.mem.eql(u8, name, "message")) {
                    if (item_value != .null) _ = try text(item_value);
                } else if (std.mem.eql(u8, name, "interrupt")) {
                    if (item_value != .bool) return error.InvalidHookOutput;
                    if (item_value.bool) return error.UnsupportedHookEffect;
                } else if (oneOf(name, &.{ "updatedInput", "updatedPermissions" })) {
                    if (item_value != .null) return error.UnsupportedHookEffect;
                } else return error.UnsupportedHookEffect;
            }
            result.decide(std.meta.stringToEnum(Permission, try text(field.object.get("behavior") orelse return error.InvalidHookOutput)) orelse return error.InvalidHookOutput);
            if (result.permission == .ask) return error.InvalidHookOutput;
            if (result.permission == .deny) result.blocked = try reason(allocator, field, "message");
        } else return error.UnsupportedHookEffect;
    }
}

fn text(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidHookOutput;
    return value.string;
}
fn string(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    return allocator.dupe(u8, try text(value));
}
fn reason(allocator: std.mem.Allocator, object: std.json.Value, key: []const u8) ![]u8 {
    const value = if (object.object.get(key)) |v| (if (v == .null) "blocked by hook" else try text(v)) else "blocked by hook";
    return allocator.dupe(u8, if (value.len == 0) "blocked by hook" else value);
}
fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, value, choice)) return true;
    return false;
}

test "structured policy validates events types and effects" {
    const a = std.testing.allocator;
    var result = try parse(a, "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"updatedInput\":{\"command\":\"echo ok\"},\"additionalContext\":\"context\"}}", "PreToolUse");
    defer result.deinit(a);
    try std.testing.expect(result.blocked != null);
    try std.testing.expectEqualStrings("{\"command\":\"echo ok\"}", result.replacement.?);
    try std.testing.expectError(error.InvalidHookOutput, parse(a, "{\"continue\":1}", "Stop"));
    try std.testing.expectError(error.InvalidHookEvent, parse(a, "{\"hookSpecificOutput\":{\"hookEventName\":\"Stop\"}}", "PreToolUse"));
    try std.testing.expectError(error.UnsupportedHookEffect, parse(a, "{\"unknown\":true}", "Stop"));
}

test "pinned event result compatibility fixtures" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixtures = try std.json.parseFromSliceLeaky(std.json.Value, a, @embedFile("fixtures/hooks/results.json"), .{});
    for (fixtures.array.items) |fixture| {
        const event = fixture.object.get("event").?.string;
        const encoded = try std.json.Stringify.valueAlloc(a, fixture.object.get("output").?, .{});
        if (fixture.object.contains("invalid")) {
            if (parse(a, encoded, event)) |_| return error.InvalidFixtureAccepted else |_| {}
            continue;
        }
        var result = try parse(std.testing.allocator, encoded, event);
        defer result.deinit(std.testing.allocator);
        try std.testing.expectEqual(fixture.object.contains("blocked"), result.blocked != null);
        try std.testing.expectEqual(fixture.object.contains("context"), result.context != null);
        try std.testing.expectEqual(fixture.object.contains("replacement"), result.replacement != null);
        try std.testing.expectEqual(fixture.object.contains("feedback"), result.feedback != null);
        try std.testing.expectEqual(fixture.object.contains("display"), result.display_content != null);
        try std.testing.expectEqual(fixture.object.contains("retry"), result.retry);
    }
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

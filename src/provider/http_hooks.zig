const std = @import("std");
const Hooks = @import("../core/hooks.zig");

const Patch = @import("../core/hook_result.zig").HttpPatch;

pub const Request = struct {
    body: []u8,
    headers: std.http.Client.Request.Headers,
    extra_headers: []const std.http.Header,
};

pub const Head = struct {
    status: std.http.Status,
    headers: []const std.http.Header,

    pub fn get(self: Head, name: []const u8) ?[]const u8 {
        for (self.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
        return null;
    }
};

pub const Exchange = struct {
    runner: ?*const Hooks.Runner,
    input: Hooks.Invocation,
    url: []const u8,
    protocol: []const u8,
    stop: ?*const std.atomic.Value(bool),
    head: Head = .{ .status = .ok, .headers = &.{} },
    index: usize = 0,
    hook_failed: bool = false,

    fn enabled(self: Exchange, a: std.mem.Allocator, event: Hooks.Event) bool {
        const runner = self.runner orelse return false;
        var input = self.input;
        input.event = event;
        return runner.hasMatching(a, input, false);
    }

    fn evaluate(self: *Exchange, a: std.mem.Allocator, phase: []const u8, body: ?std.json.Value, headers: []const std.http.Header) !?Patch {
        var runner = (self.runner orelse return null).*;
        runner.stop = self.stop;
        var input = self.input;
        if (std.mem.eql(u8, phase, "event")) {
            var handlers: std.ArrayList(Hooks.Hook) = .empty;
            for (runner.set.http_response) |hook| if (hook.stream) try handlers.append(a, hook);
            runner.set.http_response = handlers.items;
        }
        input.event = if (std.mem.eql(u8, phase, "request")) .http_request else .http_response;
        inline for (.{ "request_context", "request_system", "request_instruction", "request_tools", "request_routes" }) |field| @field(input, field) = "";
        if (!runner.hasMatching(a, input, false)) return null;
        var visible: std.json.ObjectMap = .empty;
        for (headers) |header| try visible.put(a, header.name, .{ .string = if (sensitive(header.name)) "<redacted>" else header.value });
        input.http = try std.json.Stringify.valueAlloc(a, .{
            .phase = phase,
            .method = "POST",
            .url = self.url,
            .protocol = self.protocol,
            .status = @intFromEnum(self.head.status),
            .headers = std.json.Value{ .object = visible },
            .body = body,
            .index = self.index,
        }, .{});
        const result = try runner.evaluate(a, input);
        if (result.message) |message| if (runner.runtime) |runtime| try runtime.notice(message);
        const encoded = result.http orelse return null;
        return try std.json.parseFromSliceLeaky(Patch, a, encoded, .{});
    }

    pub fn request(self: *Exchange, a: std.mem.Allocator, body: []u8, headers: std.http.Client.Request.Headers, extra: []const std.http.Header) !Request {
        if (!self.enabled(a, .http_request)) return .{ .body = body, .headers = headers, .extra_headers = extra };
        var all: std.ArrayList(std.http.Header) = .empty;
        inline for (std.meta.fields(std.http.Client.Request.Headers)) |field| {
            const value = @field(headers, field.name);
            if (value == .override) try all.append(a, .{ .name = try headerName(a, field.name), .value = value.override });
        }
        try all.appendSlice(a, extra);
        const original = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        const patch = try self.evaluate(a, "request", original, all.items) orelse return .{ .body = body, .headers = headers, .extra_headers = extra };
        if (patch.status != null or patch.drop) return error.InvalidHttpHookOutput;
        var prepared = body;
        if (patch.body) |replacement| {
            if (replacement != .object) return error.InvalidHttpHookOutput;
            try immutableField(a, original, replacement, "model");
            const encoded = try std.json.Stringify.valueAlloc(a, replacement, .{});
            if (self.input.request_purpose == .approval_judge and !try equal(a, original, replacement)) return error.ReviewerContextImmutable;
            prepared = encoded;
        }
        var adjusted = headers;
        if (patch.headers) |overrides| {
            try updateHeaders(a, &all, overrides);
            inline for (std.meta.fields(std.http.Client.Request.Headers)) |field| {
                if (@field(adjusted, field.name) == .override) @field(adjusted, field.name) = .omit;
                var entries = overrides.object.iterator();
                while (entries.next()) |entry| {
                    if (entry.value_ptr.* == .string and std.mem.eql(u8, entry.value_ptr.string, "<redacted>")) continue;
                    if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, try headerName(a, field.name))) @field(adjusted, field.name) = .omit;
                }
            }
        } else return .{ .body = prepared, .headers = headers, .extra_headers = extra };
        return .{ .body = prepared, .headers = adjusted, .extra_headers = all.items };
    }

    pub fn response(self: *Exchange, a: std.mem.Allocator, original: std.http.Client.Response.Head) !Head {
        var headers: std.ArrayList(std.http.Header) = .empty;
        var it = original.iterateHeaders();
        while (it.next()) |header| try headers.append(a, .{ .name = try a.dupe(u8, header.name), .value = try a.dupe(u8, header.value) });
        self.head = .{ .status = original.status, .headers = headers.items };
        if (try self.evaluate(a, "headers", null, headers.items)) |patch| {
            if (patch.body != null or patch.drop) return error.InvalidHttpHookOutput;
            if (patch.status) |status| {
                if (status < 200 or status > 599 or status / 100 == 3) return error.InvalidHttpHookOutput;
                if (self.input.request_purpose == .approval_judge and status != @intFromEnum(original.status)) return error.ReviewerContextImmutable;
                self.head.status = @enumFromInt(status);
            }
            if (patch.headers) |values| try updateHeaders(a, &headers, values);
            self.head.headers = headers.items;
        }
        return self.head;
    }

    pub fn payload(self: *Exchange, a: std.mem.Allocator, body: []const u8, streaming: bool) !?[]const u8 {
        errdefer self.hook_failed = true;
        defer self.index += 1;
        if (!self.enabled(a, .http_response)) return body;
        if (streaming) {
            var input = self.input;
            input.event = .http_response;
            const runner = self.runner orelse return body;
            var selected = false;
            for (runner.set.http_response) |hook| {
                if (hook.stream and hook.enabled and hook.trusted and (hook.when == null or hook.when.?.accepts(input))) selected = true;
            }
            if (!selected) return body;
        }
        const input = std.json.parseFromSliceLeaky(std.json.Value, a, body, .{}) catch std.json.Value{ .string = body };
        const patch = try self.evaluate(a, if (streaming) "event" else "body", input, self.head.headers) orelse return body;
        if (patch.headers != null or patch.status != null) return error.InvalidHttpHookOutput;
        if (patch.drop) {
            if (!streaming or self.input.request_purpose == .approval_judge) return error.InvalidHttpHookOutput;
            return null;
        }
        if (patch.body) |replacement| {
            if (self.input.request_purpose == .approval_judge and !try equal(a, input, replacement)) return error.ReviewerContextImmutable;
            return try std.json.Stringify.valueAlloc(a, replacement, .{});
        }
        return body;
    }
};

fn sensitive(name: []const u8) bool {
    for ([_][]const u8{ "authorization", "proxy-authorization", "x-api-key", "api-key", "cookie", "set-cookie" }) |key| if (std.ascii.eqlIgnoreCase(name, key)) return true;
    return false;
}

fn headerName(a: std.mem.Allocator, field: []const u8) ![]const u8 {
    const value = try a.dupe(u8, field);
    std.mem.replaceScalar(u8, value, '_', '-');
    return value;
}

fn updateHeaders(a: std.mem.Allocator, headers: *std.ArrayList(std.http.Header), values: std.json.Value) !void {
    if (values != .object) return error.InvalidHttpHookOutput;
    var it = values.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (name.len == 0) return error.InvalidHttpHookOutput;
        for (name) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return error.InvalidHttpHookOutput;
        for ([_][]const u8{ "host", "content-length", "transfer-encoding", "connection", "upgrade", "proxy-authorization" }) |reserved| if (std.ascii.eqlIgnoreCase(name, reserved)) return error.ProtectedHttpHeader;
        const value = entry.value_ptr.*;
        if (value != .string and value != .null) return error.InvalidHttpHookOutput;
        if (value == .string) {
            if (std.mem.eql(u8, value.string, "<redacted>")) continue;
            for (value.string) |c| if (c < 32 or c == 127) return error.InvalidHttpHookOutput;
        }
        var index: usize = 0;
        while (index < headers.items.len) {
            if (std.ascii.eqlIgnoreCase(headers.items[index].name, name)) _ = headers.orderedRemove(index) else index += 1;
        }
        if (value == .string) try headers.append(a, .{ .name = name, .value = value.string });
    }
}

fn equal(a: std.mem.Allocator, lhs: std.json.Value, rhs: std.json.Value) !bool {
    return std.mem.eql(u8, try std.json.Stringify.valueAlloc(a, lhs, .{}), try std.json.Stringify.valueAlloc(a, rhs, .{}));
}

fn immutableField(a: std.mem.Allocator, before: std.json.Value, after: std.json.Value, field: []const u8) !void {
    const lhs = before.object.get(field) orelse .null;
    const rhs = after.object.get(field) orelse .null;
    if (!try equal(a, lhs, rhs)) return error.ProtectedHttpField;
}

test "HTTP overrides reject destination headers injection and invalid payload fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var headers: std.ArrayList(std.http.Header) = .empty;
    try std.testing.expectError(error.ProtectedHttpHeader, updateHeaders(a, &headers, try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"Host\":\"evil\"}", .{})));
    try std.testing.expectError(error.InvalidHttpHookOutput, updateHeaders(a, &headers, try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"x-test\":\"a\\r\\nb\"}", .{})));
    const before = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"model\":\"local\"}", .{});
    const after = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"model\":\"remote\"}", .{});
    try std.testing.expectError(error.ProtectedHttpField, immutableField(a, before, after, "model"));
}

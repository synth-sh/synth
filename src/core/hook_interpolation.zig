const std = @import("std");

pub fn expand(arena: std.mem.Allocator, value: std.json.Value, input: std.json.Value) !std.json.Value {
    return expandDepth(arena, value, input, 0);
}
fn expandDepth(arena: std.mem.Allocator, value: std.json.Value, input: std.json.Value, depth: usize) anyerror!std.json.Value {
    if (depth > 64) return error.HookInterpolationTooDeep;
    switch (value) {
        .string => |source| {
            if (std.mem.startsWith(u8, source, "${") and std.mem.endsWith(u8, source, "}") and std.mem.indexOf(u8, source[2 .. source.len - 1], "}") == null) return lookup(input, source[2 .. source.len - 1]);
            var writer: std.Io.Writer.Allocating = .init(arena);
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, source, at, "${")) |start| {
                try writer.writer.writeAll(source[at..start]);
                const end = std.mem.indexOfScalarPos(u8, source, start + 2, '}') orelse return error.InvalidHookInterpolation;
                const field = try lookup(input, source[start + 2 .. end]);
                if (field == .string) try writer.writer.writeAll(field.string) else try std.json.Stringify.value(field, .{}, &writer.writer);
                at = end + 1;
            }
            try writer.writer.writeAll(source[at..]);
            return .{ .string = try writer.toOwnedSlice() };
        },
        .object => |object| {
            var result: std.json.ObjectMap = .empty;
            var entries = object.iterator();
            while (entries.next()) |entry| try result.put(arena, entry.key_ptr.*, try expandDepth(arena, entry.value_ptr.*, input, depth + 1));
            return .{ .object = result };
        },
        .array => |array| {
            var result: std.array_list.Managed(std.json.Value) = .init(arena);
            for (array.items) |item| try result.append(try expandDepth(arena, item, input, depth + 1));
            return .{ .array = result };
        },
        else => return value,
    }
}
fn lookup(input: std.json.Value, path: []const u8) !std.json.Value {
    var current = input;
    var fields = std.mem.splitScalar(u8, path, '.');
    while (fields.next()) |field| {
        if (current == .object) {
            current = current.object.get(field) orelse return error.MissingHookField;
        } else if (current == .array) {
            const index = std.fmt.parseInt(usize, field, 10) catch return error.MissingHookField;
            if (index >= current.array.items.len) return error.MissingHookField;
            current = current.array.items[index];
        } else return error.MissingHookField;
    }
    return current;
}

test "MCP interpolation preserves full-value types through nested arrays" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"tool_input\":{\"count\":3,\"flag\":true}}", .{});
    const template = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"items\":[\"${tool_input.count}\",\"flag=${tool_input.flag}\",\"${tool_input}\"]}", .{});
    const result = try expand(a, template, input);
    const items = result.object.get("items").?.array.items;
    try std.testing.expectEqual(@as(i64, 3), items[0].integer);
    try std.testing.expectEqualStrings("flag=true", items[1].string);
    try std.testing.expect(items[2] == .object);
    try std.testing.expectError(error.MissingHookField, expand(a, .{ .string = "${missing}" }, input));
}

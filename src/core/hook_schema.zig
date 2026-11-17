const std = @import("std");

pub fn validate(schema: std.json.Value, value: std.json.Value) !void {
    if (schema != .object) return error.InvalidToolSchema;
    if (schema.object.get("type")) |kind| {
        if (kind != .string) return error.InvalidToolSchema;
        const Kind = enum { object, array, string, boolean, integer, number, null };
        const parsed = std.meta.stringToEnum(Kind, kind.string) orelse return error.UnsupportedToolSchema;
        const valid = switch (parsed) {
            .object => value == .object,
            .array => value == .array,
            .string => value == .string,
            .boolean => value == .bool,
            .integer => value == .integer,
            .number => value == .integer or value == .float,
            .null => value == .null,
        };
        if (!valid) return error.InvalidToolInput;
    }
    if (schema.object.get("enum")) |choices| {
        if (choices != .array) return error.InvalidToolSchema;
        var found = false;
        for (choices.array.items) |choice| {
            if (choice == .string and value == .string and std.mem.eql(u8, choice.string, value.string)) found = true;
        }
        if (!found) return error.InvalidToolInput;
    }
    if (value == .object) {
        if (schema.object.get("required")) |required| {
            if (required != .array) return error.InvalidToolSchema;
            for (required.array.items) |key| {
                if (key != .string) return error.InvalidToolSchema;
                if (!value.object.contains(key.string)) return error.InvalidToolInput;
            }
        }
        var entries = value.object.iterator();
        while (entries.next()) |entry| {
            if (schema.object.get("properties")) |properties| {
                if (properties != .object) return error.InvalidToolSchema;
                if (properties.object.get(entry.key_ptr.*)) |property| {
                    try validate(property, entry.value_ptr.*);
                    continue;
                }
            }
            if (schema.object.get("additionalProperties")) |additional| {
                if (additional == .bool and !additional.bool) return error.InvalidToolInput;
            }
        }
    }
    if (value == .array) {
        if (schema.object.get("items")) |items| {
            for (value.array.items) |item| try validate(items, item);
        }
    }
}

test "replacement arguments must satisfy required fields and types" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"type\":\"object\",\"required\":[\"command\"],\"properties\":{\"command\":{\"type\":\"string\"}}}", .{});
    const wrong = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"command\":false}", .{});
    try std.testing.expectError(error.InvalidToolInput, validate(schema, wrong));
    try std.testing.expectError(error.InvalidToolInput, validate(schema, .{ .object = .empty }));
}

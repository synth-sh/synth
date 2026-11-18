const std = @import("std");

pub fn validate(schema: std.json.Value, value: std.json.Value) !void {
    if (schema != .object) return error.InvalidToolSchema;
    if (schema.object.get("type")) |kind| {
        const valid = switch (kind) {
            .string => try typeMatches(kind.string, value),
            .array => valid: {
                var matched = false;
                for (kind.array.items) |choice| {
                    if (choice != .string) return error.InvalidToolSchema;
                    matched = matched or try typeMatches(choice.string, value);
                }
                break :valid matched;
            },
            else => return error.InvalidToolSchema,
        };
        if (!valid) return error.InvalidToolInput;
    }
    if (schema.object.get("enum")) |choices| {
        if (choices != .array) return error.InvalidToolSchema;
        var found = false;
        for (choices.array.items) |choice| {
            if (jsonEqual(choice, value)) found = true;
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

fn typeMatches(name: []const u8, value: std.json.Value) !bool {
    const Kind = enum { object, array, string, boolean, integer, number, null };
    const kind = std.meta.stringToEnum(Kind, name) orelse return error.UnsupportedToolSchema;
    return switch (kind) {
        .object => value == .object,
        .array => value == .array,
        .string => value == .string,
        .boolean => value == .bool,
        .integer => value == .integer or (value == .float and @floor(value.float) == value.float),
        .number => value == .integer or value == .float,
        .null => value == .null,
    };
}

pub fn jsonEqual(lhs: std.json.Value, rhs: std.json.Value) bool {
    const lhs_number: ?f128 = switch (lhs) {
        .integer => |v| @floatFromInt(v),
        .float => |v| @floatCast(v),
        else => null,
    };
    const rhs_number: ?f128 = switch (rhs) {
        .integer => |v| @floatFromInt(v),
        .float => |v| @floatCast(v),
        else => null,
    };
    if (lhs_number != null and rhs_number != null) return lhs_number.? == rhs_number.?;
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .null => true,
        .bool => |v| v == rhs.bool,
        .integer, .float => unreachable,
        .string, .number_string => |v| std.mem.eql(u8, v, switch (rhs) {
            .string => |text| text,
            .number_string => |text| text,
            else => unreachable,
        }),
        .array => |values| equal: {
            if (values.items.len != rhs.array.items.len) break :equal false;
            for (values.items, rhs.array.items) |a, b| if (!jsonEqual(a, b)) break :equal false;
            break :equal true;
        },
        .object => |values| equal: {
            if (values.count() != rhs.object.count()) break :equal false;
            var fields = values.iterator();
            while (fields.next()) |field| {
                const other = rhs.object.get(field.key_ptr.*) orelse break :equal false;
                if (!jsonEqual(field.value_ptr.*, other)) break :equal false;
            }
            break :equal true;
        },
    };
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

test "MCP replacements accept nullable types and numeric enum values" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"type\":\"object\",\"properties\":{\"value\":{\"type\":[\"string\",\"null\"]},\"mode\":{\"type\":\"integer\",\"enum\":[1,2]}}}", .{});
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"value\":\"updated\",\"mode\":1}", .{});
    try validate(schema, value);
    const invalid = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"value\":true,\"mode\":3}", .{});
    try std.testing.expectError(error.InvalidToolInput, validate(schema, invalid));
}

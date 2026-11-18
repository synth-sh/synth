const std = @import("std");
const schema = @import("hook_schema.zig");

const edit_fields = .{ .{ "old", "old_string" }, .{ "new", "new_string" } };

fn fileTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "read") or std.mem.eql(u8, name, "write") or std.mem.eql(u8, name, "edit");
}

pub fn addAliases(a: std.mem.Allocator, name: []const u8, value: *std.json.Value) !void {
    if (value.* != .object or !fileTool(name)) return;
    try addAlias(a, value, "path", "file_path");
    if (!std.mem.eql(u8, name, "edit")) return;
    inline for (edit_fields) |pair| try addAlias(a, value, pair[0], pair[1]);
    if (value.object.getPtr("edits")) |edits| {
        if (edits.* == .array) for (edits.array.items) |*edit| {
            inline for (edit_fields) |pair| try addAlias(a, edit, pair[0], pair[1]);
        };
    }
}

fn addAlias(a: std.mem.Allocator, value: *std.json.Value, native: []const u8, alias: []const u8) !void {
    if (value.* != .object) return;
    if (value.object.get(native)) |field| try value.object.put(a, alias, field);
}

pub fn normalize(a: std.mem.Allocator, name: []const u8, original: []const u8, replacement: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var value = try std.json.parseFromSliceLeaky(std.json.Value, scratch, replacement, .{});
    if (value != .object) return error.InvalidHookOutput;
    if (fileTool(name)) {
        const before = try std.json.parseFromSliceLeaky(std.json.Value, scratch, original, .{});
        try normalizeAlias(scratch, &value, before, "path", "file_path");
        if (std.mem.eql(u8, name, "edit")) {
            inline for (edit_fields) |pair| try normalizeAlias(scratch, &value, before, pair[0], pair[1]);
            if (value.object.getPtr("edits")) |edits| {
                if (edits.* == .array) for (edits.array.items, 0..) |*edit, i| {
                    const previous = if (before == .object) before.object.get("edits") else null;
                    const baseline: std.json.Value = if (previous != null and previous.? == .array and i < previous.?.array.items.len) previous.?.array.items[i] else .null;
                    inline for (edit_fields) |pair| try normalizeAlias(scratch, edit, baseline, pair[0], pair[1]);
                };
            }
        }
    }
    return std.json.Stringify.valueAlloc(a, value, .{});
}

fn normalizeAlias(a: std.mem.Allocator, value: *std.json.Value, before: std.json.Value, native: []const u8, alias: []const u8) !void {
    if (value.* != .object) return;
    const changed = value.object.get(alias) orelse return;
    if (value.object.get(native)) |current| {
        const baseline = if (before == .object) before.object.get(native) else null;
        if (baseline) |old| {
            if (!schema.jsonEqual(old, current)) {
                if (!schema.jsonEqual(old, changed) and !schema.jsonEqual(current, changed)) return error.ConflictingHookAliases;
                _ = value.object.orderedRemove(alias);
                return;
            }
        } else if (!schema.jsonEqual(current, changed)) return error.ConflictingHookAliases;
    }
    try value.object.put(a, native, changed);
    _ = value.object.orderedRemove(alias);
}

test "updated inputs normalize either spelling without ignoring edits or MCP arguments" {
    const a = std.testing.allocator;
    for ([_]struct { name: []const u8 = "edit", before: []const u8, after: []const u8, expected: []const u8 }{
        .{ .name = "write", .before = "{\"path\":\"old\"}", .after = "{\"file_path\":\"new\",\"content\":\"x\"}", .expected = "{\"content\":\"x\",\"path\":\"new\"}" },
        .{ .before = "{\"path\":\"old\"}", .after = "{\"path\":\"old\",\"file_path\":\"new\",\"old_string\":\"a\",\"new_string\":\"b\"}", .expected = "{\"path\":\"new\",\"old\":\"a\",\"new\":\"b\"}" },
        .{ .before = "{\"path\":\"old\"}", .after = "{\"path\":\"new\",\"file_path\":\"old\"}", .expected = "{\"path\":\"new\"}" },
        .{ .before = "{\"path\":\"x\"}", .after = "{\"file_path\":\"x\",\"edits\":[{\"old_string\":\"a\",\"new_string\":\"b\"}]}", .expected = "{\"edits\":[{\"old\":\"a\",\"new\":\"b\"}],\"path\":\"x\"}" },
        .{ .name = "mcp__server__edit", .before = "{}", .after = "{\"path\":\"x\",\"file_path\":\"y\"}", .expected = "{\"path\":\"x\",\"file_path\":\"y\"}" },
    }) |case| {
        const result = try normalize(a, case.name, case.before, case.after);
        defer a.free(result);
        const actual = try std.json.parseFromSlice(std.json.Value, a, result, .{});
        defer actual.deinit();
        const expected = try std.json.parseFromSlice(std.json.Value, a, case.expected, .{});
        defer expected.deinit();
        try std.testing.expect(schema.jsonEqual(actual.value, expected.value));
    }
    try std.testing.expectError(error.ConflictingHookAliases, normalize(a, "write", "{\"path\":\"old\"}", "{\"path\":\"one\",\"file_path\":\"two\"}"));
}

test "batched edit inputs expose aliases for every replacement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var value = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"path\":\"x\",\"edits\":[{\"old\":\"a\",\"new\":\"b\"},{\"old\":\"c\",\"new\":\"d\"}]}", .{});
    try addAliases(a, "edit", &value);
    const edits = value.object.get("edits").?.array.items;
    try std.testing.expectEqualStrings("a", edits[0].object.get("old_string").?.string);
    try std.testing.expectEqualStrings("d", edits[1].object.get("new_string").?.string);
}

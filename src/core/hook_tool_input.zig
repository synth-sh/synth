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

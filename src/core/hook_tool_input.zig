const std = @import("std");
const schema = @import("hook_schema.zig");
const Filesystem = @import("../tools/filesystem.zig");

const edit_fields = .{ .{ Filesystem.old_text_field, "old_string" }, .{ Filesystem.new_text_field, "new_string" } };
const path_alias = "file_path";

fn fileTool(name: []const u8) ?Filesystem.Name {
    const kind = std.meta.stringToEnum(Filesystem.Name, name) orelse return null;
    return switch (kind) {
        .read, .write, .edit => kind,
        .list, .glob, .grep => null,
    };
}

pub fn addAliases(a: std.mem.Allocator, name: []const u8, value: *std.json.Value) !void {
    if (value.* != .object) return;
    const kind = fileTool(name) orelse return;
    try addAlias(a, value, Filesystem.path_field, path_alias);
    if (kind != .edit) return;
    inline for (edit_fields) |pair| try addAlias(a, value, pair[0], pair[1]);
    if (value.object.getPtr(Filesystem.edits_field)) |edits| {
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
    if (fileTool(name)) |kind| {
        const before = try std.json.parseFromSliceLeaky(std.json.Value, scratch, original, .{});
        try normalizeAlias(scratch, &value, before, Filesystem.path_field, path_alias);
        if (kind == .edit) {
            inline for (edit_fields) |pair| try normalizeAlias(scratch, &value, before, pair[0], pair[1]);
            if (value.object.getPtr(Filesystem.edits_field)) |edits| {
                if (edits.* == .array) for (edits.array.items, 0..) |*edit, i| {
                    const previous = if (before == .object) before.object.get(Filesystem.edits_field) else null;
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

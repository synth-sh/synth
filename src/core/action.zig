const std = @import("std");

const paths = @import("paths.zig");

pub fn verify(io: std.Io, a: std.mem.Allocator, cwd: []const u8, name: []const u8, arguments: []const u8, snapshot: []const u8) !void {
    const Action = struct { tool: []const u8, arguments: std.json.Value, cwd: []const u8, resolved_targets: []const []const u8 };
    const approved = try std.json.parseFromSliceLeaky(Action, a, snapshot, .{ .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, name, approved.tool) or !std.mem.eql(u8, try paths.resolve(io, a, cwd, "."), approved.cwd)) return error.ApprovedActionChanged;
    const input = try std.json.parseFromSliceLeaky(std.json.Value, a, arguments, .{});
    if (input != .object) return error.ApprovedActionChanged;
    const effective = try std.json.Stringify.valueAlloc(a, input, .{});
    const expected = try std.json.Stringify.valueAlloc(a, approved.arguments, .{});
    if (!std.mem.eql(u8, effective, expected)) return error.ApprovedActionChanged;
    var i: usize = 0;
    for ([_][]const u8{ "path", "file" }) |field| {
        if (input.object.get(field)) |value| {
            if (value != .string) continue;
            const target = try paths.resolve(io, a, cwd, value.string);
            if (i >= approved.resolved_targets.len or !std.mem.eql(u8, target, approved.resolved_targets[i])) return error.ApprovedActionChanged;
            i += 1;
        }
    }
    if (i != approved.resolved_targets.len) return error.ApprovedActionChanged;
}

test "worker verification detects retargeted paths after approval" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.createDirPath(io, "one");
    try tmp.dir.createDirPath(io, "two");
    try tmp.dir.symLink(io, "one", "link", .{ .is_directory = true });
    const snapshot = try std.json.Stringify.valueAlloc(a, .{ .tool = "write", .arguments = .{ .path = "link/file", .content = "value" }, .cwd = root, .resolved_targets = [_][]const u8{try paths.resolve(io, a, root, "link/file")} }, .{});
    const arguments = "{\"path\":\"link/file\",\"content\":\"value\"}";
    try verify(io, a, root, "write", arguments, snapshot);
    try tmp.dir.deleteFile(io, "link");
    try tmp.dir.symLink(io, "two", "link", .{ .is_directory = true });
    try std.testing.expectError(error.ApprovedActionChanged, verify(io, a, root, "write", arguments, snapshot));
}

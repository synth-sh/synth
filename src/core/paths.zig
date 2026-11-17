const std = @import("std");

pub fn resolve(io: std.Io, a: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]const u8 {
    const lexical = try std.fs.path.resolve(a, &.{ cwd, path });
    var existing: []const u8 = lexical;
    while (true) {
        if (std.Io.Dir.cwd().realPathFileAlloc(io, existing, a)) |real| {
            return std.fs.path.join(a, &.{ real, lexical[existing.len..] });
        } else |err| switch (err) {
            error.FileNotFound => {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                if (std.Io.Dir.cwd().readLink(io, existing, &buffer)) |_| return error.UnresolvedActionTarget else |_| {}
            },
            else => return err,
        }
        existing = std.fs.path.dirname(existing) orelse return error.UnresolvedActionTarget;
    }
}

pub fn inside(root: []const u8, path: []const u8) bool {
    return std.mem.eql(u8, root, path) or (std.mem.startsWith(u8, path, root) and (std.mem.endsWith(u8, root, "/") or path[root.len] == '/'));
}

pub fn directoryError(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "directory does not exist",
        error.NotDir => "path is not a directory",
        error.AccessDenied => "permission denied",
        error.Busy => "wait until the session is idle",
        error.InvalidParams => "enter a directory path",
        else => "directory is unavailable",
    };
}

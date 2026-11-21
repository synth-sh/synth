const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const synth_config_dir = ".synth";
pub const default_temp_root = "/tmp";

pub fn tempRoot(environ: *const std.process.Environ.Map) []const u8 {
    const path = environ.get("TMPDIR") orelse return default_temp_root;
    if (!std.fs.path.isAbsolute(path)) return default_temp_root;
    const trimmed = std.mem.trimEnd(u8, path, "/");
    return if (trimmed.len == 0) path[0..1] else trimmed;
}

pub const Ownership = struct {
    uid: posix.uid_t,
    mode: u32,

    pub fn kind(self: Ownership) std.Io.File.Kind {
        return switch (self.mode & posix.S.IFMT) {
            posix.S.IFDIR => .directory,
            posix.S.IFREG => .file,
            posix.S.IFLNK => .sym_link,
            else => .unknown,
        };
    }
};

pub fn ownershipNoFollow(path: []const u8) !Ownership {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.BadPathName;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&buffer, "{s}", .{path});
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var found: linux.Statx = undefined;
        const rc = linux.statx(linux.AT.FDCWD, name, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &found);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .NOENT => return error.FileNotFound,
            else => return error.StatFailed,
        }
        if (!found.mask.TYPE or !found.mask.MODE or !found.mask.UID) return error.StatFailed;
        return .{ .uid = found.uid, .mode = found.mode };
    }
    var found: std.c.Stat = undefined;
    switch (posix.errno(std.c.fstatat(std.c.AT.FDCWD, name, &found, std.c.AT.SYMLINK_NOFOLLOW))) {
        .SUCCESS => {},
        .NOENT => return error.FileNotFound,
        else => return error.StatFailed,
    }
    return .{ .uid = found.uid, .mode = @intCast(found.mode) };
}

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

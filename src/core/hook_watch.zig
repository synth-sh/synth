const std = @import("std");
const Hooks = @import("hooks.zig");
const skills = @import("skill.zig");

const Watch = @This();

const poll_interval_ms: i64 = std.time.ms_per_s;

const Stamp = struct { inode: std.Io.File.INode, size: u64, modified: i128 };
const Entry = struct {
    path: []const u8,
    event: Hooks.Event,
    source: []const u8,
    stamp: ?Stamp,
    pending: ?[]const u8 = null,
};

pub const Change = struct { path: []const u8, source: []const u8, kind: []const u8 };

entries: std.ArrayList(Entry) = .empty,
last_poll_ms: ?i64 = null,

pub fn deinit(self: *Watch, allocator: std.mem.Allocator) void {
    for (self.entries.items) |entry| allocator.free(entry.path);
    self.entries.deinit(allocator);
    self.* = .{};
}

pub fn configure(self: *Watch, allocator: std.mem.Allocator, io: std.Io, root: []const u8, config_path: []const u8, home: ?[]const u8, set: Hooks.Set, available: []const skills.Skill, reviewed_config_paths: []const []const u8) !void {
    var next: Watch = .{};
    errdefer next.deinit(allocator);
    if (set.config_change.len > 0) {
        if (config_path.len > 0) try next.add(allocator, io, config_path, .config_change, "user_settings");
        const project_hooks = try std.fs.path.join(allocator, &.{ root, ".synth", "hooks.json" });
        defer allocator.free(project_hooks);
        try next.add(allocator, io, project_hooks, .config_change, "project_settings");
        if (home) |dir| {
            const user_hooks = try std.fs.path.join(allocator, &.{ dir, ".synth", "hooks.json" });
            defer allocator.free(user_hooks);
            try next.add(allocator, io, user_hooks, .config_change, "user_settings");
        }
        for (available) |skill| {
            const path = try std.fs.path.join(allocator, &.{ skill.dir, skills.file_name });
            defer allocator.free(path);
            try next.add(allocator, io, path, .config_change, "skills");
        }
    }
    for (set.file_changed) |hook| {
        if (!hook.enabled or !hook.trusted) continue;
        var names = std.mem.tokenizeScalar(u8, hook.matcher, '|');
        while (names.next()) |name| {
            const path = try std.fs.path.join(allocator, &.{ root, name });
            defer allocator.free(path);
            try next.add(allocator, io, path, .file_changed, "");
        }
    }
    keep: for (next.entries.items) |*entry| {
        if (entry.event == .config_change) {
            for (reviewed_config_paths) |path| {
                if (std.mem.eql(u8, entry.path, path)) continue :keep;
            }
        }
        for (self.entries.items) |old| {
            if (entry.event == old.event and std.mem.eql(u8, entry.path, old.path)) {
                entry.stamp = old.stamp;
                entry.pending = old.pending;
                break;
            }
        }
    }
    self.deinit(allocator);
    self.* = next;
}

fn add(self: *Watch, allocator: std.mem.Allocator, io: std.Io, path: []const u8, event: Hooks.Event, source: []const u8) !void {
    for (self.entries.items) |entry| if (entry.event == event and std.mem.eql(u8, entry.path, path)) return;
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try self.entries.append(allocator, .{ .path = owned, .event = event, .source = source, .stamp = try stamp(io, path) });
}

fn stamp(io: std.Io, path: []const u8) !?Stamp {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => return err,
    };
    if (stat.kind != .file) return null;
    return .{ .inode = stat.inode, .size = stat.size, .modified = stat.mtime.nanoseconds };
}

pub fn poll(self: *Watch, io: std.Io, force: bool) !void {
    if (self.entries.items.len == 0) return;
    const now = std.Io.Clock.now(.awake, io).toMilliseconds();
    if (!force) if (self.last_poll_ms) |previous| if (now - previous < poll_interval_ms) return;
    self.last_poll_ms = now;
    for (self.entries.items) |*entry| {
        const current = try stamp(io, entry.path);
        if (std.meta.eql(entry.stamp, current)) continue;
        entry.pending = if (entry.stamp == null) "add" else if (current == null) "unlink" else "change";
        entry.stamp = current;
    }
}

pub fn take(self: *Watch, event: Hooks.Event) ?Change {
    for (self.entries.items) |*entry| {
        if (entry.event != event) continue;
        const kind = entry.pending orelse continue;
        entry.pending = null;
        return .{ .path = entry.path, .source = entry.source, .kind = kind };
    }
    return null;
}

const std = @import("std");
const Hooks = @import("hooks.zig");
const Config = @import("config.zig");

pub const State = struct { trusted: bool = false, disabled: bool = false };
pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.StringHashMapUnmanaged(State) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8) !Store {
        var self: Store = .{ .arena = .init(allocator) };
        errdefer self.deinit();
        const filename = path orelse return self;
        const a = self.arena.allocator();
        const source = std.Io.Dir.cwd().readFileAlloc(io, filename, a, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return self,
            else => return err,
        };
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, source, .{});
        if (parsed != .object) return error.InvalidHookTrustStore;
        var entries = parsed.object.iterator();
        while (entries.next()) |entry| {
            const json = try std.json.Stringify.valueAlloc(a, entry.value_ptr.*, .{});
            try self.entries.put(a, entry.key_ptr.*, try std.json.parseFromSliceLeaky(State, a, json, .{}));
        }
        return self;
    }
    pub fn deinit(self: *Store) void {
        self.arena.deinit();
    }
    pub fn get(self: Store, id: []const u8) State {
        return self.entries.get(id) orelse .{};
    }
    pub fn put(self: *Store, id: []const u8, state: State) !void {
        try self.entries.put(self.arena.allocator(), try self.arena.allocator().dupe(u8, id), state);
    }
    pub fn save(self: *const Store, io: std.Io, path: []const u8) !void {
        try Config.ensureDir(io, path);
        const a = self.arena.allocator();
        var writer: std.Io.Writer.Allocating = .init(a);
        var json: std.json.Stringify = .{ .writer = &writer.writer };
        try json.beginObject();
        var entries = self.entries.iterator();
        while (entries.next()) |entry| {
            try json.objectField(entry.key_ptr.*);
            try json.write(entry.value_ptr.*);
        }
        try json.endObject();
        var nonce: [16]u8 = undefined;
        io.random(&nonce);
        const temporary = try std.fmt.allocPrint(a, "{s}.{s}.tmp", .{ path, std.fmt.bytesToHex(nonce, .lower) });
        const file = try std.Io.Dir.cwd().createFile(io, temporary, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        defer file.close(io);
        errdefer std.Io.Dir.cwd().deleteFile(io, temporary) catch {};
        var buffer: [4096]u8 = undefined;
        var out = file.writer(io, &buffer);
        try out.interface.writeAll(writer.written());
        try out.interface.flush();
        try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), path, io);
    }
};

pub fn discover(arena: std.mem.Allocator, io: std.Io, inline_set: Hooks.Set, root: []const u8, home: ?[]const u8, store: Store) !Hooks.Set {
    var set: Hooks.Set = .{};
    try set.append(arena, inline_set);
    if (home) |user_home| try loadFile(arena, io, &set, try std.fs.path.join(arena, &.{ user_home, ".synth", "hooks.json" }));
    try loadFile(arena, io, &set, try std.fs.path.join(arena, &.{ root, ".synth", "hooks.json" }));
    inline for (std.meta.fields(Hooks.Set)) |field| {
        const definitions = try arena.dupe(Hooks.Hook, @field(set, field.name));
        for (definitions, 0..) |*hook, index| {
            const event = @field(Hooks.Event, field.name);
            const encoded = try std.json.Stringify.valueAlloc(arena, .{ root, event.name(), index, hook.* }, .{});
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(encoded, &hash, .{});
            hook.id = try arena.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
            const state = store.get(hook.id);
            hook.trusted = state.trusted;
            hook.enabled = !state.disabled;
        }
        @field(set, field.name) = definitions;
    }
    return set;
}

fn loadFile(arena: std.mem.Allocator, io: std.Io, set: *Hooks.Set, path: []const u8) !void {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{});
    const hooks = if (parsed == .object) parsed.object.get("hooks") orelse parsed else parsed;
    try set.append(arena, try Hooks.parse(arena, hooks, path));
}

test "trust is invalidated by definition changes and project identity" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var store = try Store.init(std.testing.allocator, std.testing.io, null);
    defer store.deinit();
    const set: Hooks.Set = .{ .pre_tool_use = &.{.{ .command = "true" }} };
    const initial = try discover(a, std.testing.io, set, root, null, store);
    try std.testing.expect(!initial.pre_tool_use[0].trusted);
    try store.put(initial.pre_tool_use[0].id, .{ .trusted = true });
    const trusted = try discover(a, std.testing.io, set, root, null, store);
    try std.testing.expect(trusted.pre_tool_use[0].trusted);
    const changed = try discover(a, std.testing.io, .{ .pre_tool_use = &.{.{ .command = "false" }} }, root, null, store);
    try std.testing.expect(!changed.pre_tool_use[0].trusted);
    try store.put(initial.pre_tool_use[0].id, .{ .trusted = true, .disabled = true });
    const disabled = try discover(a, std.testing.io, set, root, null, store);
    try std.testing.expect(!disabled.pre_tool_use[0].enabled);
}

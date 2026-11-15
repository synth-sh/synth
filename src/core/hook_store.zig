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
    pub fn save(self: *Store, io: std.Io, path: []const u8) !void {
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

pub fn discover(arena: std.mem.Allocator, io: std.Io, inline_set: Hooks.Set, root: []const u8, home: ?[]const u8, timeout_ms: u64, store: Store) !Hooks.Set {
    var set: Hooks.Set = .{};
    try set.append(arena, inline_set);
    if (home) |user_home| try loadFile(arena, io, &set, try std.fs.path.join(arena, &.{ user_home, ".synth", "hooks.json" }));
    try loadFile(arena, io, &set, try std.fs.path.join(arena, &.{ root, ".synth", "hooks.json" }));
    inline for (std.meta.fields(Hooks.Set)) |field| {
        const definitions = try arena.dupe(Hooks.Hook, @field(set, field.name));
        for (definitions, 0..) |*hook, index| {
            const event = @field(Hooks.Event, field.name);
            const encoded = try std.json.Stringify.valueAlloc(arena, .{ root, event.name(), index, hook.timeout_ms orelse timeout_ms, hook.* }, .{});
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
    const initial = try discover(a, std.testing.io, set, root, null, Hooks.default_timeout_ms, store);
    try std.testing.expect(!initial.pre_tool_use[0].trusted);
    try store.put(initial.pre_tool_use[0].id, .{ .trusted = true });
    const trusted = try discover(a, std.testing.io, set, root, null, Hooks.default_timeout_ms, store);
    try std.testing.expect(trusted.pre_tool_use[0].trusted);
    const changed = try discover(a, std.testing.io, .{ .pre_tool_use = &.{.{ .command = "false" }} }, root, null, Hooks.default_timeout_ms, store);
    try std.testing.expect(!changed.pre_tool_use[0].trusted);
    try store.put(initial.pre_tool_use[0].id, .{ .trusted = true, .disabled = true });
    const disabled = try discover(a, std.testing.io, set, root, null, Hooks.default_timeout_ms, store);
    try std.testing.expect(!disabled.pre_tool_use[0].enabled);
}

pub const Action = enum { list, review, trust, revoke, enable, disable };

pub fn change(arena: std.mem.Allocator, io: std.Io, set: *Hooks.Set, path: ?[]const u8, action: Action, id: []const u8) !void {
    if (action == .list or action == .review) return;
    const filename = path orelse return error.HookTrustStoreUnavailable;
    var store = try Store.init(arena, io, filename);
    defer store.deinit();
    var found = false;
    var updated = set.*;
    inline for (std.meta.fields(Hooks.Set)) |field| {
        const definitions = try arena.dupe(Hooks.Hook, @field(set, field.name));
        for (definitions) |*hook| {
            if (!std.mem.eql(u8, hook.id, id)) continue;
            found = true;
            var state = store.get(hook.id);
            switch (action) {
                .trust => state.trusted = true,
                .revoke => state.trusted = false,
                .enable => state.disabled = false,
                .disable => state.disabled = true,
                else => unreachable,
            }
            try store.put(hook.id, state);
            hook.trusted = state.trusted;
            hook.enabled = !state.disabled;
        }
        @field(updated, field.name) = definitions;
    }
    if (!found) return error.HookNotFound;
    try store.save(io, filename);
    set.* = updated;
}

pub fn report(allocator: std.mem.Allocator, set: Hooks.Set, timeout_ms: u64, review: bool, runtime: ?*Hooks.Runtime) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var count: usize = 0;
    inline for (std.meta.fields(Hooks.Set)) |field| {
        for (@field(set, field.name)) |hook| {
            count += 1;
            const event = @field(Hooks.Event, field.name);
            try writer.writer.print("{s}\n  {s}  {s}  {s}  {s}  {s} timeout={d}ms\n  source: {s}\n  matcher: {s}\n", .{
                hook.id, event.name(), if (hook.legacy) "legacy serial" else if (hook.async) "background" else "grouped sync", if (hook.trusted) "trusted" else "NEEDS REVIEW", if (hook.enabled) "enabled" else "disabled", @tagName(hook.type), hook.timeout_ms orelse timeout_ms, hook.source, hook.matcher,
            });
            if (review) {
                try writer.writer.writeAll("  definition: ");
                try std.json.Stringify.value(hook, .{}, &writer.writer);
                try writer.writer.writeByte('\n');
            }
        }
    }
    if (count == 0) try writer.writer.writeAll("No hooks configured.\n");
    if (runtime) |active| {
        active.records_mutex.lockUncancelable(active.io);
        defer active.records_mutex.unlock(active.io);
        for (0..active.records_len) |at| {
            const index = (active.records_next + active.records.len - active.records_len + at) % active.records.len;
            const record = active.records[index];
            try writer.writer.print("  recent: {s} {s} {s} {d}ms\n", .{ &record.id, record.event.name(), record.status, record.duration_ms });
            try writer.writer.print("    session={s} turn={s} call={s}\n", .{ std.mem.trimEnd(u8, &record.session_id, "\x00"), std.mem.trimEnd(u8, &record.turn_id, "\x00"), std.mem.trimEnd(u8, &record.call_id, "\x00") });
            if (record.error_name.len > 0) try writer.writer.print("    error: {s}\n", .{record.error_name});
            if (record.exit_code) |code| try writer.writer.print("    exit: {d}\n", .{code});
        }
    }
    const raw = try writer.toOwnedSlice();
    if (!@import("ansi.zig").hasControls(raw)) return raw;
    defer allocator.free(raw);
    return @import("ansi.zig").clean(allocator, raw);
}

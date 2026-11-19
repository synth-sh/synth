const std = @import("std");
const Hooks = @import("hooks.zig");
const Config = @import("config.zig");

pub const State = struct { trusted: bool = false, disabled: bool = false };
pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.json.ArrayHashMap(State) = .{},

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
        self.entries = try std.json.parseFromValueLeaky(std.json.ArrayHashMap(State), a, parsed, .{});
        return self;
    }
    pub fn deinit(self: *Store) void {
        self.arena.deinit();
    }
    pub fn get(self: Store, id: []const u8) State {
        return self.entries.map.get(id) orelse .{};
    }
    pub fn put(self: *Store, id: []const u8, state: State) !void {
        try self.entries.map.put(self.arena.allocator(), try self.arena.allocator().dupe(u8, id), state);
    }
    pub fn save(self: *Store, io: std.Io, path: []const u8) !void {
        var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .make_path = true, .permissions = .fromMode(0o600) });
        defer file.deinit(io);
        var buffer: [4096]u8 = undefined;
        var out = file.file.writer(io, &buffer);
        try std.json.Stringify.value(self.entries, .{}, &out.interface);
        try out.interface.flush();
        try file.replace(io);
    }
};

pub fn discover(arena: std.mem.Allocator, io: std.Io, inline_set: Hooks.Set, root: []const u8, home: ?[]const u8, store: Store) !Hooks.Set {
    var set: Hooks.Set = .{};
    try set.append(arena, inline_set);
    const user_source = if (home) |dir| try std.fs.path.join(arena, &.{ dir, ".synth", "hooks.json" }) else null;
    if (user_source) |path| try loadFile(arena, io, &set, path);
    try loadFile(arena, io, &set, try std.fs.path.join(arena, &.{ root, ".synth", "hooks.json" }));
    inline for (std.meta.fields(Hooks.Set)) |field| {
        const definitions = try arena.dupe(Hooks.Hook, @field(set, field.name));
        for (definitions, 0..) |*hook, index| {
            const event = @field(Hooks.Event, field.name);
            var source_index: usize = 0;
            for (definitions[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier.source, hook.source)) source_index += 1;
            }
            const source_path = try std.fs.path.resolve(arena, &.{ root, hook.source });
            const source_is_user = (if (user_source) |path| std.mem.eql(u8, path, hook.source) else false) or !@import("paths.zig").inside(root, source_path);
            const user_hook = source_is_user and independentCommand(hook.command);
            const encoded = try std.json.Stringify.valueAlloc(arena, .{ if (user_hook) "" else root, event.name(), source_index, hook.* }, .{});
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

fn independentCommand(command: []const u8) bool {
    if (std.mem.indexOfAny(u8, command, ";&|<>()$`\\") != null) return false;
    var words = std.mem.tokenizeAny(u8, command, " \t\r\n");
    const program = std.mem.trim(u8, words.next() orelse return false, "\"'");
    if (!std.fs.path.isAbsolute(program)) return false;
    while (words.next()) |word| {
        const value = std.mem.trim(u8, word, "\"'");
        if (std.fs.path.isAbsolute(value)) continue;
        const plain_option = std.mem.startsWith(u8, value, "-") and std.mem.indexOfAny(u8, value, "=/\\$`\"'") == null;
        if (!plain_option) return false;
    }
    return true;
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
    const moved = try discover(a, std.testing.io, set, try std.fs.path.join(a, &.{ root, "elsewhere" }), null, store);
    try std.testing.expect(!moved.pre_tool_use[0].trusted);
    const timeout_changed = try discover(a, std.testing.io, .{ .pre_tool_use = &.{.{ .command = "true", .timeout_ms = 1000 }} }, root, null, store);
    try std.testing.expect(!timeout_changed.pre_tool_use[0].trusted);
    try store.put(initial.pre_tool_use[0].id, .{ .trusted = true, .disabled = true });
    const disabled = try discover(a, std.testing.io, set, root, null, store);
    try std.testing.expect(!disabled.pre_tool_use[0].enabled);
}

pub const Command = struct { action: Action, id: []const u8 };

pub fn parseCommand(line: []const u8) !Command {
    var words = std.mem.tokenizeAny(u8, line, " \t\r\n");
    _ = words.next();
    const action = std.meta.stringToEnum(Action, words.next() orelse "list") orelse return error.UnknownSubcommand;
    const id = words.next() orelse "";
    if (words.next() != null) return error.UnexpectedArgument;
    if (action != .list and action != .review and id.len == 0) return error.MissingHookId;
    return .{ .action = action, .id = id };
}

pub const Action = enum { list, review, trust, revoke, enable, disable };

pub fn change(arena: std.mem.Allocator, io: std.Io, set: *Hooks.Set, path: ?[]const u8, action: Action, id: []const u8) !void {
    if (action == .list or action == .review) return;
    const filename = path orelse return error.HookTrustStoreUnavailable;
    const minimum_id: usize = if (action == .trust or action == .enable) 32 else 8;
    if (id.len < minimum_id) return error.HookIdTooShort;
    var selected: ?[]const u8 = null;
    inline for (std.meta.fields(Hooks.Set)) |field| {
        for (@field(set.*, field.name)) |hook| {
            if (!std.mem.startsWith(u8, hook.id, id)) continue;
            if (selected != null) return error.AmbiguousHookId;
            selected = hook.id;
        }
    }
    const full_id = selected orelse return error.HookNotFound;
    try Config.ensureDir(io, filename);
    const lock_path = try std.fmt.allocPrint(arena, "{s}.lock", .{filename});
    defer arena.free(lock_path);
    const lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .permissions = .fromMode(0o600) });
    defer lock.close(io);
    var store = try Store.init(arena, io, filename);
    defer store.deinit();
    var state = store.get(full_id);
    switch (action) {
        .trust => state.trusted = true,
        .revoke => state.trusted = false,
        .enable => state.disabled = false,
        .disable => state.disabled = true,
        else => unreachable,
    }
    try store.put(full_id, state);
    var updated = set.*;
    inline for (std.meta.fields(Hooks.Set)) |field| {
        const definitions = try arena.dupe(Hooks.Hook, @field(set, field.name));
        for (definitions) |*hook| {
            const saved = store.get(hook.id);
            hook.trusted = saved.trusted;
            hook.enabled = !saved.disabled;
        }
        @field(updated, field.name) = definitions;
    }
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
                hook.id, event.name(), if (hook.legacy) "legacy serial" else if (hook.async) "background" else "grouped sync", if (hook.trusted) "trusted" else "NEEDS REVIEW", if (hook.enabled) "enabled" else "disabled", @tagName(hook.type), Hooks.effectiveTimeout(event, timeout_ms, hook), hook.source, hook.matcher,
            });
            if (hook.when) |filter| {
                try writer.writer.writeAll("  when: ");
                try std.json.Stringify.value(filter, .{ .emit_null_optional_fields = false }, &writer.writer);
                try writer.writer.writeByte('\n');
            }
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
            try writer.writer.print("    agent={s} request={d} attempt={d}\n", .{ std.mem.trimEnd(u8, &record.agent_id, "\x00"), record.request_id, record.attempt });
            try writer.writer.print("    scope={s} purpose={s}\n", .{ @tagName(record.agent_scope), @tagName(record.request_purpose) });
            if (record.error_name.len > 0) try writer.writer.print("    error: {s}\n", .{record.error_name});
            if (record.exit_code) |code| try writer.writer.print("    exit: {d}\n", .{code});
        }
    }
    const raw = try writer.toOwnedSlice();
    if (!@import("ansi.zig").hasControls(raw)) return raw;
    defer allocator.free(raw);
    return @import("ansi.zig").clean(allocator, raw);
}

test "discovery is additive and unrelated sources keep stable ids" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/.synth");
    try tmp.dir.createDirPath(std.testing.io, "project/.synth");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/.synth/hooks.json", .data = "{\"PreToolUse\":[{\"command\":\"user\"}]}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "project/.synth/hooks.json", .data = "{\"hooks\":{\"PreToolUse\":[{\"command\":\"project\"},{\"command\":\"project\"}]}}" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "project", a);
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, "home", a);
    var store = try Store.init(std.testing.allocator, std.testing.io, null);
    defer store.deinit();
    const set = try discover(a, std.testing.io, .{ .pre_tool_use = &.{.{ .command = "inline" }} }, root, home, store);
    try std.testing.expectEqual(@as(usize, 4), set.pre_tool_use.len);
    try std.testing.expectEqualStrings("inline", set.pre_tool_use[0].command);
    try std.testing.expectEqualStrings("user", set.pre_tool_use[1].command);
    try std.testing.expectEqualStrings("project", set.pre_tool_use[2].command);
    try std.testing.expect(!std.mem.eql(u8, set.pre_tool_use[2].id, set.pre_tool_use[3].id));
    const more = try discover(a, std.testing.io, .{ .pre_tool_use = &.{ .{ .command = "inline" }, .{ .command = "another" } } }, root, home, store);
    try std.testing.expectEqualStrings(set.pre_tool_use[2].id, more.pre_tool_use[3].id);
}

test "changing a routing filter invalidates trust and inspection shows the route" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var store = try Store.init(std.testing.allocator, std.testing.io, null);
    defer store.deinit();
    const original = try discover(a, std.testing.io, .{ .pre_tool_use = &.{.{ .command = "true" }} }, root, null, store);
    try store.put(original.pre_tool_use[0].id, .{ .trusted = true });
    const unchanged = try discover(a, std.testing.io, .{ .pre_tool_use = &.{.{ .command = "true" }} }, root, null, store);
    try std.testing.expect(unchanged.pre_tool_use[0].trusted);
    const routed = try discover(a, std.testing.io, .{ .pre_tool_use = &.{.{ .command = "true", .when = .{ .agent_scope = .subagent } }} }, root, null, store);
    try std.testing.expect(!routed.pre_tool_use[0].trusted);
    try std.testing.expect(!std.mem.eql(u8, original.pre_tool_use[0].id, routed.pre_tool_use[0].id));
    const listed = try report(std.testing.allocator, routed, 30000, false, null);
    defer std.testing.allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "when: {\"agent_scope\":\"subagent\"}") != null);
}

test "user hook trust survives project changes and accepts unique id prefixes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var home = std.testing.tmpDir(.{});
    defer home.cleanup();
    try home.dir.createDirPath(io, ".synth");
    try home.dir.writeFile(io, .{ .sub_path = ".synth/hooks.json", .data = "{\"PreToolUse\":[{\"command\":\"/bin/true\"}]}" });
    const path = try home.dir.realPathFileAlloc(io, ".", scratch);
    var store = try Store.init(a, io, null);
    defer store.deinit();
    const initial = try discover(scratch, io, .{}, "/first-project", path, store);
    const id = initial.pre_tool_use[0].id;
    const state_path = try std.fs.path.join(scratch, &.{ path, "trust.json" });
    var updated = initial;
    try change(scratch, io, &updated, state_path, .trust, id[0..32]);
    var saved = try Store.init(a, io, state_path);
    defer saved.deinit();
    const moved = try discover(scratch, io, .{}, "/second-project", path, saved);
    try std.testing.expect(moved.pre_tool_use[0].trusted);
    try std.testing.expectEqualStrings(id, moved.pre_tool_use[0].id);
}

test "relative user commands cannot reuse another checkout's trust" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".synth");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".synth/hooks.json", .data = "{\"PreToolUse\":[{\"command\":\"bash ./guard.sh\"}]}" });
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var store = try Store.init(std.testing.allocator, std.testing.io, null);
    defer store.deinit();
    const first = try discover(a, std.testing.io, .{}, "/checkout-one", home, store);
    try store.put(first.pre_tool_use[0].id, .{ .trusted = true });
    const next = try discover(a, std.testing.io, .{}, "/checkout-two", home, store);
    try std.testing.expect(!next.pre_tool_use[0].trusted);
}

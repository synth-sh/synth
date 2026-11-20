//! What an "allow always" on a shell command stores, and what a stored one
//! covers.
//!
//! An allowance is a list of words. Ending in `*`, it covers any command that
//! starts with the words before it: `git commit *` covers `git commit -m x`
//! and not `git push`. Without the `*` the words have to match exactly. Words
//! are split the way the shell would before expansion, quoted runs whole. A
//! program named bare matches it run from any directory; one named by path
//! matches only that path.

const std = @import("std");
const unicode = @import("uucode");
const Paths = @import("../core/paths.zig");
const Hooks = @import("../core/hooks.zig");
const testing = std.testing;

const safety = @import("safety.zig");

/// How much of a command an allowance reaches, narrowest first.
pub const Breadth = enum {
    /// This command, with these arguments.
    command,
    /// Its subcommand, with any arguments: `git commit *`. A program without
    /// one falls back to the exact command.
    subcommand,
    /// Every use of the program: `git *`.
    program,
};

/// Programs whose first argument picks what they do, so that naming it is the
/// difference between `git status` and `git push`.
const with_subcommands: []const []const u8 = &.{
    "git",       "gh",         "npm",     "pnpm",   "yarn",    "bun",     "deno",
    "npx",       "cargo",      "rustup",  "go",     "zig",     "uv",      "pip",
    "pip3",      "poetry",     "docker",  "podman", "kubectl", "helm",    "terraform",
    "make",      "just",       "nix",     "brew",   "apt",     "apt-get", "dnf",
    "systemctl", "journalctl", "dotnet",  "mvn",    "gradle",  "swift",   "mix",
    "bundle",    "rake",       "flutter", "aws",    "gcloud",  "az",
};

/// Subcommands that run something named by the next word, which is then what
/// the allowance is really about: `npm run *` would be every script.
const runners: []const []const u8 = &.{ "run", "exec", "x", "dlx" };

/// The allowance that covers `segment` at `breadth`.
pub fn pattern(arena: std.mem.Allocator, segment: safety.Segment, breadth: Breadth) ![]const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    try words.append(arena, segment.program);
    var arguments = safety.arguments(segment.arguments);
    while (arguments.next()) |word| try words.append(arena, word);

    const kept: ?usize = switch (breadth) {
        .command => null,
        .subcommand => subcommandLength(words.items),
        .program => 1,
    };
    if (kept) |count| return join(arena, words.items[0..count], true);
    words.items[0] = segment.invoked;
    return join(arena, words.items, false);
}

/// How many leading words name what the command does, or null when it has no
/// subcommand to name: `git -C dir commit` starts with a flag, and is better
/// approved exactly than guessed at.
fn subcommandLength(words: []const []const u8) ?usize {
    if (!contains(with_subcommands, words[0])) return null;
    if (words.len < 2 or !isPlainWord(words[1])) return null;
    if (words.len > 2 and contains(runners, words[1]) and isPlainWord(words[2])) return 3;
    return 2;
}

fn isPlainWord(word: []const u8) bool {
    if (word.len == 0 or !std.ascii.isAlphabetic(word[0])) return false;
    for (word) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.' and c != ':') return false;
    }
    return true;
}

/// A word of the command that is itself `*`, or starts with a backslash, is
/// stored behind one more backslash, so the trailing wildcard is the only bare
/// `*` an allowance can hold.
fn join(arena: std.mem.Allocator, words: []const []const u8, wildcard: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (words, 0..) |word, i| {
        if (i > 0) try out.append(arena, ' ');
        if (std.mem.eql(u8, word, "*") or std.mem.startsWith(u8, word, "\\")) try out.append(arena, '\\');
        try out.appendSlice(arena, word);
    }
    if (wildcard) try out.appendSlice(arena, " *");
    return out.toOwnedSlice(arena);
}

/// Whether the allowance `allowed` covers `segment`.
pub fn covers(allowed: []const u8, segment: safety.Segment) bool {
    if (std.mem.eql(u8, allowed, "*")) return true;

    var wanted = safety.arguments(allowed);
    const program = unescape(wanted.next() orelse return false);
    const named = if (std.mem.indexOfScalar(u8, program, '/') == null) segment.program else segment.invoked;
    if (!std.mem.eql(u8, program, named)) return false;

    var given = safety.arguments(segment.arguments);
    while (wanted.next()) |word| {
        if (std.mem.eql(u8, word, "*")) return wanted.next() == null;
        const actual = given.next() orelse return false;
        if (!std.mem.eql(u8, unescape(word), actual)) return false;
    }
    return given.next() == null;
}

/// Programs that run whatever they are handed: interpreters, shells, and
/// runners whose first argument is what they run.
const interpreters: []const []const u8 = &.{
    "python", "python3", "node",  "ruby", "perl", "php",  "lua",  "sh",
    "bash",   "zsh",     "fish",  "deno", "bun",  "npx",  "bunx", "uvx",
    "pnpx",   "env",     "xargs", "sudo", "ssh",  "eval", "exec",
};

/// Whether an allowance amounts to running any code at all: every command, a
/// whole interpreter, or a runner left open as to what it runs (`npm run *`).
/// Auto mode leaves calls these would cover to its judge.
pub fn runsAnything(allowed: []const u8) bool {
    if (std.mem.eql(u8, allowed, "*")) return true;
    if (!std.mem.endsWith(u8, allowed, " *")) return false;

    var words = safety.arguments(allowed[0 .. allowed.len - 2]);
    const program = unescape(words.next() orelse return false);
    const name = program[if (std.mem.lastIndexOfScalar(u8, program, '/')) |slash| slash + 1 else 0..];
    const second = words.next() orelse return contains(interpreters, name);
    if (words.next() != null) return false;
    return contains(with_subcommands, name) and contains(runners, second);
}

fn unescape(word: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, word, "\\")) word[1..] else word;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |entry| {
        if (std.mem.eql(u8, entry, needle)) return true;
    }
    return false;
}

fn only(arena: std.mem.Allocator, command: []const u8) !safety.Segment {
    const found = (try safety.segments(arena, command)).?;
    try testing.expectEqual(@as(usize, 1), found.len);
    return found[0];
}

fn expectPattern(command: []const u8, breadth: Breadth, wanted: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings(wanted, try pattern(arena, try only(arena, command), breadth));
}

fn expectCovers(allowed: []const u8, command: []const u8, wanted: bool) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(wanted, covers(allowed, try only(arena, command)));
}

test "a subcommand is what an allowance names by default" {
    try expectPattern("git commit -m \"x y\"", .subcommand, "git commit *");
    try expectPattern("zig build test", .subcommand, "zig build *");
    try expectPattern("git status", .subcommand, "git status *");
    try expectPattern("npm run build", .subcommand, "npm run build *");
    try expectPattern("docker exec web ls", .subcommand, "docker exec web *");
    try expectPattern("cargo run --release", .subcommand, "cargo run *");
    try expectPattern("/usr/bin/git push", .subcommand, "git push *");
}

test "a command with no subcommand to name is allowed exactly" {
    try expectPattern("rm -rf build", .subcommand, "rm -rf build");
    try expectPattern("./deploy.sh prod", .subcommand, "./deploy.sh prod");
    try expectPattern("make", .subcommand, "make");
    try expectPattern("git -C src commit", .subcommand, "git -C src commit");
    try expectPattern("npm ./local", .subcommand, "npm ./local");
}

test "breadth reaches from the exact command to the whole program" {
    try expectPattern("git commit -m x", .command, "git commit -m x");
    try expectPattern("git commit -m x", .program, "git *");
    try expectPattern("rm -rf build", .program, "rm *");
    try expectPattern("/bin/rm -rf build", .command, "/bin/rm -rf build");
    try expectPattern("/bin/rm -rf build", .program, "rm *");
    try expectPattern("make", .program, "make *");
}

test "a literal star in the command is not a wildcard" {
    try expectPattern("rm *", .command, "rm \\*");
    try expectCovers("rm \\*", "rm *", true);
    try expectCovers("rm \\*", "rm -rf /", false);
    try expectPattern("echo \\n", .command, "echo \\\\n");
    try expectCovers("echo \\\\n", "echo \\n", true);
}

test "an allowance covers what starts with its words, and nothing else" {
    try expectCovers("git commit *", "git commit -m x", true);
    try expectCovers("git commit *", "git commit", true);
    try expectCovers("git commit *", "/usr/bin/git commit --amend", true);
    try expectCovers("git commit *", "git push --force", false);
    try expectCovers("git commit *", "git commitx", false);
    try expectCovers("git commit *", "git -c x commit", false);
    try expectCovers("git commit *", "gitk commit", false);

    try expectCovers("rm -rf build", "rm -rf build", true);
    try expectCovers("rm -rf build", "rm  -rf   build", true);
    try expectCovers("rm -rf build", "rm -rf build /", false);
    try expectCovers("rm -rf build", "rm -rf", false);
    try expectCovers("rm -rf build", "/bin/rm -rf build", true);

    try expectCovers("./deploy.sh prod", "./deploy.sh prod", true);
    try expectCovers("./deploy.sh prod", "/tmp/deploy.sh prod", false);
    try expectCovers("./deploy.sh prod", "deploy.sh prod", false);

    try expectCovers("git commit -m \"a b\" *", "git commit -m \"a b\" --amend", true);
    try expectCovers("git commit -m \"a b\" *", "git commit -m a b", false);

    try expectCovers("*", "anything at all", true);
    try expectCovers("", "ls", false);
    try expectCovers("git * commit", "git x commit", false);
}

test "an allowance that runs anything is told apart from a narrow one" {
    try testing.expect(runsAnything("*"));
    try testing.expect(runsAnything("python3 *"));
    try testing.expect(runsAnything("/usr/bin/bash *"));
    try testing.expect(runsAnything("npm run *"));
    try testing.expect(runsAnything("uv run *"));
    try testing.expect(runsAnything("npx *"));

    try testing.expect(!runsAnything("npm run build *"));
    try testing.expect(!runsAnything("git commit *"));
    try testing.expect(!runsAnything("git *"));
    try testing.expect(!runsAnything("python3 script.py"));
    try testing.expect(!runsAnything("rm -rf build"));
}

test "allowances stored before word prefixes keep covering what they did" {
    try expectCovers("git *", "git push --force", true);
    try expectCovers("find *", "find", true);
    try expectCovers("find", "find", true);
    try expectCovers("find", "find .", false);
}

pub fn protectedPath(arena: std.mem.Allocator, io: std.Io, root: []const u8, target: []const u8, control_files: []const []const u8, hooks: Hooks.Set) !bool {
    const lexical = try std.fs.path.resolve(arena, &.{ root, target });
    const resolved = try Paths.resolve(io, arena, root, target);
    for ([_][]const u8{ lexical, resolved }) |path| {
        var parts = std.mem.tokenizeScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (sameName(part, ".synth") or sameName(part, ".git")) return true;
        }
    }
    for (control_files) |file| {
        if (try samePath(arena, io, root, file, lexical, resolved)) return true;
    }
    inline for (std.meta.fields(Hooks.Set)) |field| {
        for (@field(hooks, field.name)) |hook| {
            if (!hook.enabled or !hook.trusted) continue;
            if (try samePath(arena, io, root, hook.source, lexical, resolved)) return true;
            var words = safety.shellWords(hook.command);
            while (words.next()) |word| {
                const expanded = try expandProjectDir(arena, word, root);
                const candidate = try safety.literalWord(arena, expanded) orelse continue;
                if (candidate.len == 0 or candidate[0] == '-') continue;
                if (!try mayNameHookScript(arena, io, root, candidate)) continue;
                if (try samePath(arena, io, root, candidate, lexical, resolved)) return true;
            }
        }
    }
    return false;
}

fn mayNameHookScript(arena: std.mem.Allocator, io: std.Io, root: []const u8, candidate: []const u8) !bool {
    const named = try std.fs.path.resolve(arena, &.{ root, candidate });
    if (std.mem.eql(u8, named, root)) return false;
    const stat = std.Io.Dir.cwd().statFile(io, named, .{}) catch return std.mem.indexOfScalar(u8, candidate, '/') != null;
    return stat.kind == .file;
}

const project_dir_variables = [_][]const u8{ "SYNTH_PROJECT_DIR", "CLAUDE_PROJECT_DIR" };

fn expandProjectDir(arena: std.mem.Allocator, word: []const u8, root: []const u8) ![]const u8 {
    var expanded = word;
    for (project_dir_variables) |name| {
        const braced = try std.fmt.allocPrint(arena, "${{{s}}}", .{name});
        const bare = try std.fmt.allocPrint(arena, "${s}", .{name});
        expanded = try std.mem.replaceOwned(u8, arena, expanded, braced, root);
        expanded = try std.mem.replaceOwned(u8, arena, expanded, bare, root);
    }
    return expanded;
}

pub fn commandReachesProtectedPath(arena: std.mem.Allocator, io: std.Io, root: []const u8, working_directory: []const u8, command: []const u8, control_files: []const []const u8, hooks: Hooks.Set) !bool {
    var words = safety.shellWords(command);
    while (words.next()) |word| {
        const literal = try safety.literalWord(arena, word) orelse continue;
        if (literal.len == 0 or literal[0] == '-') continue;
        const target = try std.fs.path.resolve(arena, &.{ working_directory, literal });
        if (try protectedPath(arena, io, root, target, control_files, hooks)) return true;
    }
    return false;
}

const hook_trust_actions = [_][]const u8{ "trust", "revoke", "enable", "disable" };

pub fn commandChangesHookTrust(arena: std.mem.Allocator, command: []const u8) !bool {
    var words = safety.shellWords(command);
    var previous_was_hooks = false;
    while (words.next()) |word| {
        const literal = try safety.literalWord(arena, word) orelse "";
        if (previous_was_hooks) {
            for (hook_trust_actions) |action| if (std.mem.eql(u8, literal, action)) return true;
        }
        previous_was_hooks = std.mem.eql(u8, literal, "hooks");
    }
    return false;
}

fn samePath(arena: std.mem.Allocator, io: std.Io, root: []const u8, file: []const u8, lexical: []const u8, resolved: []const u8) !bool {
    if (file.len == 0) return false;
    const named = std.fs.path.resolve(arena, &.{ root, file }) catch return false;
    if (sameName(named, lexical)) return true;
    const actual = Paths.resolve(io, arena, root, file) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return false,
    };
    return sameName(actual, resolved);
}

const Folded = struct {
    input: std.unicode.Utf8Iterator,
    single: [1]u21 = undefined,
    mapping: []const u21 = &.{},
    index: usize = 0,

    fn next(self: *Folded) ?u21 {
        if (self.index == self.mapping.len) {
            const codepoint = self.input.nextCodepoint() orelse return null;
            self.mapping = unicode.get(.case_folding_full, codepoint).with(&self.single, codepoint);
            self.index = 0;
        }
        const codepoint = self.mapping[self.index];
        self.index += 1;
        return codepoint;
    }
};

fn sameName(a: []const u8, b: []const u8) bool {
    const left = std.unicode.Utf8View.init(a) catch return std.mem.eql(u8, a, b);
    const right = std.unicode.Utf8View.init(b) catch return std.mem.eql(u8, a, b);
    var lhs: Folded = .{ .input = left.iterator() };
    var rhs: Folded = .{ .input = right.iterator() };
    while (lhs.next()) |codepoint| {
        if (codepoint != (rhs.next() orelse return false)) return false;
    }
    return rhs.next() == null;
}

test "hook script protection accounts for shell operators and quoting" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    for ([_][]const u8{ "bash ./scripts/check.sh; true", "bash ./scripts/check.sh&&true", "bash ./scripts/check.sh>/dev/null", "bash ./scripts/'check.sh'", "bash ./scripts/check\\.sh" }) |command| {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        try testing.expect(try protectedPath(arena.allocator(), std.testing.io, root, "scripts/check.sh", &.{}, .{ .pre_tool_use = &.{.{ .command = command }} }));
    }
    for ([_]struct { command: []const u8, path: []const u8 }{
        .{ .command = "bash ./scripts/check\\ file.sh", .path = "scripts/check file.sh" },
        .{ .command = "bash ./scripts/check\\;name.sh", .path = "scripts/check;name.sh" },
        .{ .command = "bash \"./scripts/check\\q.sh\"", .path = "scripts/check\\q.sh" },
    }) |case| {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        try testing.expect(try protectedPath(arena.allocator(), std.testing.io, root, case.path, &.{}, .{ .pre_tool_use = &.{.{ .command = case.command }} }));
    }
}

test "missing hook control files cannot bypass protection through case variants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const trust = try std.fs.path.join(a, &.{ root, "hook-trust.json" });
    for ([_][]const u8{ ".SYNTH/hooks.json", ".ſynth/hooks.json", ".GIT/HOOKS/new", ".git/config", ".git/objects/new", "HOOK-TRUST.json", "hook-truſt.json", "hooK-trust.json" }) |target| {
        try testing.expect(try protectedPath(a, testing.io, root, target, &.{trust}, .{}));
    }
}

test "hook scripts named through project directory variables stay protected" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    for ([_]struct { command: []const u8, path: []const u8 }{
        .{ .command = "python3 \"$SYNTH_PROJECT_DIR/scripts/guard.sh\"", .path = "scripts/guard.sh" },
        .{ .command = "bash ${SYNTH_PROJECT_DIR}/scripts/guard.sh", .path = "scripts/guard.sh" },
        .{ .command = "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/guard.sh", .path = ".claude/hooks/guard.sh" },
    }) |case| {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        try testing.expect(try protectedPath(arena.allocator(), std.testing.io, root, case.path, &.{}, .{ .pre_tool_use = &.{.{ .command = case.command }} }));
    }
}

test "commands that name control files are caught" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    for ([_][]const u8{ "cat > .synth/hooks.json", "echo '{}'>.synth/hooks.json", "mv new.json .synth/hooks.json", "cp x \"./.GIT/hooks/pre-commit\"" }) |command| {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        try testing.expect(try commandReachesProtectedPath(arena.allocator(), std.testing.io, root, root, command, &.{}, .{}));
    }
    for ([_][]const u8{ "ls src", "git status", "zig build test" }) |command| {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        try testing.expect(!try commandReachesProtectedPath(arena.allocator(), std.testing.io, root, root, command, &.{}, .{}));
    }
}

test "commands that change hook trust are caught" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "synth hooks trust abc", "./zig-out/bin/synth hooks enable abc && true", "synth \"hooks\" 'revoke' abc" }) |command| {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        try testing.expect(try commandChangesHookTrust(arena.allocator(), command));
    }
    for ([_][]const u8{ "synth hooks review", "synth hooks list", "echo trust" }) |command| {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        try testing.expect(!try commandChangesHookTrust(arena.allocator(), command));
    }
}

test "ordinary commands are not mistaken for hook scripts" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const hooks: Hooks.Set = .{ .pre_tool_use = &.{.{ .command = "cd \"$CLAUDE_PROJECT_DIR\" && python3 scripts/guard.py | grep -n 2 | jq ." }} };
    for ([_][]const u8{ "rg TODO .", "python3 tools/gen.py", "grep -rn TODO src", "find . -name '*.zig'", "git log -n 2" }) |command| {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        try testing.expect(!try commandReachesProtectedPath(arena.allocator(), std.testing.io, root, root, command, &.{}, hooks));
    }
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    try testing.expect(try commandReachesProtectedPath(arena.allocator(), std.testing.io, root, root, "echo 'exit 0' > scripts/guard.py", &.{}, hooks));
}

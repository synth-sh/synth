//! One agent session, assembled: the project it runs in, the tools it may call,
//! and the loop that drives them, configured the way `config.json` says.
//!
//! Everything here points at everything else, so it lives on the heap and is
//! built and torn down in one place.

const std = @import("std");

const pkg = @import("pkg");
const mcp = @import("mcp");

const Backend = @import("../provider/backend.zig");
const Provider = @import("../provider/provider.zig");
const Config = @import("../core/config.zig");
const Conversation = @import("../core/conversation.zig");
const Database = @import("../core/database.zig");
const Hooks = @import("../core/hooks.zig");
const HookStore = @import("../core/hook_store.zig");
const Project = @import("../core/project.zig");
const skill = @import("../core/skill.zig");
const mcp_tools = @import("../tools/mcp.zig");
const Registry = @import("../tools/registry.zig");
const skill_tool = @import("../tools/skill.zig");
const tool = @import("../tools/tool.zig");
const web = @import("../tools/web.zig");
const agents = @import("agent.zig");
const Loop = @import("loop.zig");
const subagent = @import("subagent.zig");

const Stack = @This();

allocator: std.mem.Allocator,
/// The parsed MCP server list, which the host borrows.
arena: std.heap.ArenaAllocator,
project: Project,
skills: skill.Set,
registry: Registry,
web_settings: web.Settings,
mcp_host: mcp_tools.Host,
reads: tool.ReadLog,
convo: Conversation,
hooks: Hooks.Runner,
hook_runtime: Hooks.Runtime,
hook_inline: Hooks.Set,
hook_home: ?[]const u8,
hook_state_path: ?[]const u8,
hook_config_path: []const u8,
runner: subagent.Runner,
loop: Loop,

pub const Options = struct {
    config: *const Config,
    /// What this session's turns go through. Never shared with another
    /// session: a client is single-writer.
    provider: Provider,
    /// Where subagents get clients of their own. Null leaves them on
    /// `provider`.
    backend: ?*Backend = null,
    /// Where the session runs; the project is whatever repository holds it.
    cwd: []const u8,
    home: ?[]const u8 = null,
    db: ?*Database = null,
    mcp_auth: ?*mcp.Auth = null,
    mcp_stderr: mcp.Transport.Stderr = .ignore,
    /// Servers to connect beside the config's, such as those an editor
    /// brings. Copied. A config server of the same name wins.
    mcp_servers: []const mcp_tools.Server = &.{},
    /// Wait for the MCP servers, so their tools are offered from the first
    /// turn, or leave them connecting for the owner to `install` once
    /// `mcp_host` has settled.
    mcp_connect: enum { wait, background } = .wait,
};

/// Build a session, reaching its MCP servers as `options.mcp_connect` says.
pub fn create(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Stack {
    const config = options.config;

    const self = try allocator.create(Stack);
    errdefer allocator.destroy(self);
    self.allocator = allocator;
    self.arena = .init(allocator);
    errdefer self.arena.deinit();

    self.project = try Project.detect(allocator, io, options.cwd);
    errdefer self.project.deinit(allocator);

    self.skills = try skill.load(allocator, io, self.project.root, config.skill_paths, options.home);
    errdefer self.skills.deinit();

    self.registry = try Registry.init(allocator);
    errdefer self.registry.deinit();
    try skill_tool.install(&self.registry, &self.skills);
    self.web_settings = .{ .search_api_key = config.search_api_key };
    try web.install(&self.registry, &self.web_settings);

    self.mcp_host = .init(allocator, io);
    errdefer self.mcp_host.deinit();
    self.mcp_host.auth = options.mcp_auth;
    self.mcp_host.stderr = options.mcp_stderr;
    const servers = try mcpServers(self.arena.allocator(), config, options.mcp_servers);
    if (servers.len > 0) {
        const client: mcp.Implementation = .{ .name = pkg.name, .version = pkg.version };
        switch (options.mcp_connect) {
            .wait => try self.mcp_host.connectAll(&self.registry, servers, client),
            .background => try self.mcp_host.beginConnectAll(servers, client),
        }
    }

    self.reads = .init(allocator);
    errdefer self.reads.deinit();
    self.convo = .init(allocator);
    errdefer self.convo.deinit();

    self.loop = .init(allocator, io, options.provider, &self.registry, &self.convo, &self.reads, self.project.root);
    self.runner = .{ .parent = &self.loop, .backend = options.backend };
    self.loop.delegate = self.runner.delegate();
    errdefer {
        self.loop.deinit();
        self.runner.deinit();
    }

    self.hook_inline = config.hooks;
    self.hook_home = options.home;
    self.hook_state_path = config.hook_state_path;
    self.hook_config_path = config.path;
    var hook_store = try HookStore.Store.init(allocator, io, config.hook_state_path);
    defer hook_store.deinit();
    const discovered_hooks = try HookStore.discover(self.arena.allocator(), io, config.hooks, self.project.root, options.home, hook_store);
    self.hook_runtime = .{ .allocator = allocator, .io = io };
    errdefer self.hook_runtime.deinit();
    self.hooks = .{
        .io = io,
        .root = self.project.root,
        .set = discovered_hooks,
        .runtime = &self.hook_runtime,
        .mcp_executor = .{ .userdata = self, .call = callHookMcp },
        .timeout_ms = config.hook_timeout_ms,
    };
    self.loop.hooks = &self.hooks;
    self.loop.control_files = if (config.hook_state_path) |path| try self.arena.allocator().dupe([]const u8, &.{ config.path, path }) else try self.arena.allocator().dupe([]const u8, &.{config.path});
    inline for (std.meta.fields(Hooks.Set)) |field| {
        for (@field(discovered_hooks, field.name)) |hook| {
            if (hook.enabled and !hook.trusted and self.loop.hook_flow.notice == null) self.loop.hook_flow.notice = try allocator.dupe(u8, Hooks.review_notice);
        }
    }
    self.loop.auto_approve_safe = config.auto_approve_safe_commands;
    self.loop.approvals = config.approvals;
    self.loop.backend = options.backend;
    self.loop.model_policy = config.model_requests;
    if (config.max_turn_ms) |ms| self.loop.max_turn_ms = ms;
    if (config.max_stall_ms) |ms| self.loop.max_stall_ms = ms;
    if (config.max_turn_tokens) |tokens| self.loop.max_turn_tokens = tokens;
    if (config.system_prompt) |text| self.loop.system_prompt = text;
    self.loop.commit_trailer = config.commit_trailer;
    self.loop.project = &self.project;
    self.loop.skills = self.skills.skills;
    try self.loop.useAgent(agents.default_id);

    if (options.db) |db| {
        try self.loop.attachDatabase(db, self.project.name(), self.project.cwd, options.provider.model);
    }
    try self.loop.hook_flow.watch.configure(allocator, io, self.project.root, self.hook_config_path, self.hook_home, self.hooks.set, self.skills.skills);
    try self.loop.trackModel("initial");
    return self;
}

pub fn manageHooks(self: *Stack, allocator: std.mem.Allocator, action: HookStore.Action, id: []const u8) ![]u8 {
    if (self.loop.isBusy() and action != .list and action != .review) return error.Busy;
    if (!self.loop.isBusy()) {
        var store = try HookStore.Store.init(allocator, self.hooks.io, self.hook_state_path);
        defer store.deinit();
        const discovered = try HookStore.discover(self.arena.allocator(), self.hooks.io, self.hook_inline, self.project.root, self.hook_home, store);
        for (try changedHookSources(self.arena.allocator(), self.hooks.set, discovered)) |changed_source| {
            const path = if (std.mem.eql(u8, changed_source, "config")) self.hook_config_path else changed_source;
            const source = if (std.mem.startsWith(u8, path, self.project.root) and (path.len == self.project.root.len or path[self.project.root.len] == '/')) "project_settings" else "user_settings";
            var result = try self.hooks.evaluate(allocator, try self.loop.exportHookInput(.{ .event = .config_change, .source = source, .file_path = path }));
            defer result.deinit(allocator);
            if (result.blocked != null or result.stop) {
                self.loop.say("Hook configuration change blocked: {s}", .{result.blocked orelse "stopped by hook"});
                return error.HookBlocked;
            }
        }
        self.hooks.set = discovered;
    }
    try HookStore.change(self.arena.allocator(), self.hooks.io, &self.hooks.set, self.hook_state_path, action, id);
    if (!self.loop.isBusy()) try self.loop.hook_flow.watch.configure(self.allocator, self.hooks.io, self.project.root, self.hook_config_path, self.hook_home, self.hooks.set, self.skills.skills);
    try self.loop.resumePendingPrompt();
    return HookStore.report(allocator, self.hooks.set, self.hooks.timeout_ms, action == .review, &self.hook_runtime);
}

fn changedHookSources(allocator: std.mem.Allocator, left: Hooks.Set, right: Hooks.Set) ![][]const u8 {
    var sources: std.ArrayList([]const u8) = .empty;
    if (left.config_change.len == 0) return sources.toOwnedSlice(allocator);
    for ([_]Hooks.Set{ left, right }, [_]Hooks.Set{ right, left }) |before, after| {
        inline for (std.meta.fields(Hooks.Set)) |field| {
            for (@field(before, field.name)) |hook| {
                const unchanged = for (@field(after, field.name)) |other| {
                    if (std.mem.eql(u8, hook.id, other.id)) break true;
                } else false;
                if (unchanged) continue;
                const seen = for (sources.items) |source| {
                    if (std.mem.eql(u8, source, hook.source)) break true;
                } else false;
                if (!seen) try sources.append(allocator, hook.source);
            }
        }
    }
    return sources.toOwnedSlice(allocator);
}

fn callHookMcp(raw: *anyopaque, allocator: std.mem.Allocator, hook: Hooks.Hook, arguments: []const u8, timeout_ms: u64, stop: ?*const std.atomic.Value(bool)) ![]const u8 {
    const self: *Stack = @ptrCast(@alignCast(raw));
    const deadline = tool.monotonicMilliseconds(self.hooks.io) + @as(i64, @intCast(@min(timeout_ms, tool.default_timeout_ms)));
    const result = try self.mcp_host.callConnected(.{
        .allocator = allocator,
        .io = self.hooks.io,
        .project_root = self.project.root,
        .reads = &self.reads,
        .cancelled = stop,
        .deadline_ms = deadline,
    }, hook.server, hook.tool, arguments);
    if (result.is_error) {
        allocator.free(result.content);
        return error.HookMcpCallFailed;
    }
    return result.content;
}

fn mcpServers(arena: std.mem.Allocator, config: *const Config, extra: []const mcp_tools.Server) ![]const mcp_tools.Server {
    const configured = if (config.mcp) |block| try mcp_tools.serversFromJson(arena, block) else &.{};
    if (extra.len == 0) return configured;
    var servers: std.ArrayList(mcp_tools.Server) = .empty;
    try servers.appendSlice(arena, configured);
    for (extra) |server| {
        if (named(configured, server.name)) continue;
        try servers.append(arena, try server.dupe(arena));
    }
    return servers.items;
}

fn named(servers: []const mcp_tools.Server, name: []const u8) bool {
    for (servers) |server| {
        if (std.mem.eql(u8, server.name, name)) return true;
    }
    return false;
}

pub fn destroy(self: *Stack) void {
    // Ordered: the loop joins workers writing to the runner; MCP tools point into the host.
    const end_input = (self.loop.exportHookInput(.{ .event = .session_end }) catch self.loop.hookInput(.{ .event = .session_end })).dupe(self.arena.allocator()) catch Hooks.Invocation{ .event = .session_end };
    self.hook_runtime.retainSnapshot(end_input.transcript_path);
    self.loop.deinit();
    self.runner.deinit();
    self.hook_runtime.cancelBackground();
    var end_runner = self.hooks;
    end_runner.deadline_ms = std.Io.Clock.now(.awake, self.hooks.io).toMilliseconds() + Hooks.cleanup_timeout_ms;
    var end_result = end_runner.evaluate(self.allocator, end_input) catch null;
    if (end_result) |*result| result.deinit(self.allocator);
    self.hook_runtime.releaseSnapshot(end_input.transcript_path);
    self.hook_runtime.deinit();
    self.convo.deinit();
    self.reads.deinit();
    self.registry.deinit();
    self.mcp_host.deinit();
    self.skills.deinit();
    self.project.deinit(self.allocator);
    self.arena.deinit();
    self.allocator.destroy(self);
}

test "a stack assembles a loop ready for its first turn" {
    const testing = std.testing;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    var config: Config = .{ .arena = .init(testing.allocator) };
    defer config.arena.deinit();
    var backend: Backend = .init(.ollama, .{
        .allocator = testing.allocator,
        .io = io,
        .host = "http://127.0.0.1:9",
        .label = "test",
    });
    defer backend.deinit();

    const stack = try create(testing.allocator, io, .{ .config = &config, .provider = backend.provider(), .backend = &backend, .cwd = cwd });
    defer stack.destroy();

    try testing.expectEqualStrings(cwd, stack.project.cwd);
    try testing.expect(!stack.loop.isBusy());
    try testing.expectEqualStrings(agents.default_id, stack.loop.agent.id);
    try testing.expect(stack.registry.get("read") != null);
    try testing.expect(stack.loop.delegate != null);
}

test "main-session shutdown emits one bounded command cleanup" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".git");
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = buffer[0..try tmp.dir.realPath(testing.io, &buffer)];
    var config: Config = .{ .arena = .init(testing.allocator) };
    defer config.arena.deinit();
    var backend: Backend = .init(.ollama, .{ .allocator = testing.allocator, .io = testing.io, .host = "http://127.0.0.1:9", .label = "test" });
    defer backend.deinit();
    const stack = try create(testing.allocator, testing.io, .{ .config = &config, .provider = backend.provider(), .cwd = cwd });
    stack.hooks.set.session_end = &.{.{ .command = "cat >> shutdown-events; exec 0<&- 1>&- 2>&-; sleep 30", .timeout_ms = 1000 }};
    const started = tool.monotonicMilliseconds(testing.io);
    stack.destroy();
    try testing.expect(tool.monotonicMilliseconds(testing.io) - started < 3000);
    const trace = try tmp.dir.readFileAlloc(testing.io, "shutdown-events", testing.allocator, .limited(16 * 1024));
    defer testing.allocator.free(trace);
    var lines = std.mem.tokenizeScalar(u8, trace, '\n');
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, lines.next().?, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("SessionEnd", parsed.value.object.get("hook_event_name").?.string);
    try testing.expectEqualStrings("shutdown", parsed.value.object.get("reason").?.string);
    try testing.expect(lines.next() == null);
}

test "trusted current config policy blocks replacement definitions before adoption" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.createDirPath(io, ".synth");
    try tmp.dir.writeFile(io, .{ .sub_path = ".synth/hooks.json", .data =
        \\{"ConfigChange":[{"hooks":[{"type":"command","command":"cat >> changes; echo locked >&2; exit 2"}]}]}
    });
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = buffer[0..try tmp.dir.realPath(io, &buffer)];
    const trust_path = try std.fs.path.join(a, &.{ cwd, "trust.json" });
    defer a.free(trust_path);
    var config: Config = .{ .arena = .init(a), .hook_state_path = trust_path };
    defer config.arena.deinit();
    var backend: Backend = .init(.ollama, .{ .allocator = a, .io = io, .host = "http://127.0.0.1:9", .label = "test" });
    defer backend.deinit();
    const stack = try create(a, io, .{ .config = &config, .provider = backend.provider(), .cwd = cwd });
    defer stack.destroy();
    const id = try a.dupe(u8, stack.hooks.set.config_change[0].id);
    defer a.free(id);
    a.free(try stack.manageHooks(a, .trust, id));
    try tmp.dir.writeFile(io, .{ .sub_path = ".synth/hooks.json", .data =
        \\{"PreToolUse":[{"command":"touch must-not-run"}]}
    });
    try std.testing.expectError(error.HookBlocked, stack.manageHooks(a, .list, ""));
    try std.testing.expectEqualStrings(id, stack.hooks.set.config_change[0].id);
    try std.testing.expectEqual(@as(usize, 0), stack.hooks.set.pre_tool_use.len);
    const trace = try tmp.dir.readFileAlloc(io, "changes", a, .limited(16 * 1024));
    defer a.free(trace);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, trace, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("project_settings", parsed.value.object.get("source").?.string);
    try std.testing.expect(std.mem.endsWith(u8, parsed.value.object.get("file_path").?.string, "/.synth/hooks.json"));
}

test "shutdown hooks can read their final transcript snapshot" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, ".git");
    const cwd = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(cwd);
    var config: Config = .{ .arena = .init(testing.allocator) };
    defer config.arena.deinit();
    var backend: Backend = .init(.ollama, .{ .allocator = testing.allocator, .io = testing.io, .host = "http://127.0.0.1:9", .label = "test" });
    defer backend.deinit();
    const stack = try create(testing.allocator, testing.io, .{ .config = &config, .provider = backend.provider(), .cwd = cwd });
    try stack.convo.add(.user, "final history");
    stack.hooks.set.session_end = &.{.{ .transcript = true, .command = "python3 -c 'import json,sys; p=json.load(sys.stdin); open(\"archived\",\"w\").write(open(p[\"transcript_path\"]).read())'" }};
    stack.destroy();
    const archived = try tmp.dir.readFileAlloc(testing.io, "archived", testing.allocator, .limited(4096));
    defer testing.allocator.free(archived);
    try testing.expect(std.mem.indexOf(u8, archived, "final history") != null);
}

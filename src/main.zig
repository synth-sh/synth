const std = @import("std");

const pkg = @import("pkg");
const vaxis = @import("vaxis");
pub const panic = vaxis.panic_handler;

const cli = @import("cli.zig");
const commands = @import("commands.zig");

const acp = @import("acp/run.zig");
const router = @import("acp/router.zig");
const Connection = @import("acp/connection.zig");
const Mirror = @import("acp/mirror.zig");
const headless = @import("headless.zig");
const prompt_dump = @import("prompt_dump.zig");
const remote = @import("remote.zig");
const tui_drive = @import("tui/drive.zig");

// We don't want to see the log messages from the libraries we use
pub const std_options = std.Options{
    .logFn = logOutsideOllama,
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .vaxis, .level = .warn },
        .{ .scope = .zqlite, .level = .warn },
        .{ .scope = .clap, .level = .warn },
        .{ .scope = .oauth2, .level = .warn },
        .{ .scope = .http, .level = .warn },
        .{ .scope = .websocket, .level = .warn },
    },
};

/// The ollama package logs every failed request as an error and then returns
/// it, and synth explains the error itself. Written to stderr, the log lands
/// on top of the TUI, which a model listing for a stopped server would do at
/// every launch.
fn logOutsideOllama(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (scope == .ollama) return;
    std.log.defaultLog(level, scope, format, args);
}

pub fn main(init: std.process.Init) !void {
    const command = cli.parse(init, init.arena.allocator()) catch |err| switch (err) {
        error.UsageReported => std.process.exit(2),
        else => |e| return e,
    };
    switch (command) {
        .help => |topic| try writeLine(init.io, cli.usageFor(topic)),
        .version => try writeLine(init.io, pkg.name ++ " " ++ pkg.version ++ "\n"),
        .tui => |options| {
            const left = runTui(init, options) catch |err| switch (err) {
                error.UsageReported => std.process.exit(2),
                else => |e| return e,
            };
            if (left) |l| try tui_drive.sayFarewell(init.io, null, l);
        },
        .run => |options| try headless.run(init, options.message, options.allow),
        .prompt => try prompt_dump.dump(init),
        .acp => |options| try if (options.host) acp.run(init, options.editor) else router.front(init),
        .models => try commands.models(init),
        .skills => try commands.skills(init),
        .session => |sub| try commands.session(init, sub),
        .mcp => |sub| try commands.mcp_command(init, sub),
        .hooks => |sub| try commands.hooks(init, sub.action, sub.id),
        .db => |sub| try commands.database(init, sub),
        .remote => |sub| try remote.run(init, sub),
    }
}

fn writeLine(io: std.Io, text: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);
    try out.interface.writeAll(text);
    try out.interface.flush();
}

/// Run the TUI on a session hosted by a `synth acp` child, which has this
/// terminal's environment and ends when the TUI does, unless detached.
/// Returns how the TUI left the session when there is anything to come back
/// to.
fn runTui(init: std.process.Init, options: cli.Command.Tui) !?tui_drive.Left {
    const io = init.io;
    const root = try projectRoot(init, options.project orelse ".");

    const target: Mirror.Target = if (options.session) |handle|
        .{ .load = .{ .handle = handle, .cwd = root } }
    else if (options.continue_last)
        .{ .latest = root }
    else
        .{ .new = root };
    const connection = try Connection.spawn(init.gpa, io, root);
    const left = try tui_drive.drive(init, connection, Connection.here, target, .{ .model = options.model }) orelse return null;
    return if (left.spoken or left.detached) left else null;
}

fn projectRoot(init: std.process.Init, project: []const u8) ![]const u8 {
    const io = init.io;
    const dir = std.Io.Dir.cwd().openDir(io, project, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => try cli.reject(io, null, "'{s}' is not a command or a directory", .{project}),
        else => |e| return e,
    };
    defer dir.close(io);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(io, &buffer);
    return init.arena.allocator().dupe(u8, buffer[0..len]);
}

test {
    std.testing.refAllDecls(@This());
}

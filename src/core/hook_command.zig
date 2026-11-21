const std = @import("std");
const builtin = @import("builtin");
const paths = @import("paths.zig");

pub const output_limit: usize = 64 * 1024;
const poll_slice_ms: u64 = 100;
const read_chunk_bytes = 64;
const stdin_buffer_bytes = 4 * 1024;
pub const supports_process_groups = switch (builtin.os.tag) {
    .windows, .wasi => false,
    else => true,
};

const plugin_data_suffix = "/" ++ paths.synth_config_dir ++ "/plugin-data";
const directory_variables = [_]struct { name: []const u8, suffix: []const u8 = "" }{
    .{ .name = "SYNTH_PROJECT_DIR" },
    .{ .name = "CLAUDE_PROJECT_DIR" },
    .{ .name = "CLAUDE_PLUGIN_ROOT" },
    .{ .name = "PLUGIN_ROOT" },
    .{ .name = "CLAUDE_PLUGIN_DATA", .suffix = plugin_data_suffix },
    .{ .name = "PLUGIN_DATA", .suffix = plugin_data_suffix },
};

fn environment(a: std.mem.Allocator, root: []const u8) ![directory_variables.len][]const u8 {
    var entries: [directory_variables.len][]const u8 = undefined;
    for (directory_variables, &entries) |variable, *entry| {
        entry.* = try std.fmt.allocPrint(a, "{s}={s}{s}", .{ variable.name, root, variable.suffix });
    }
    return entries;
}

pub fn expandDirectories(a: std.mem.Allocator, word: []const u8, root: []const u8) ![]const u8 {
    var expanded = word;
    inline for (directory_variables) |variable| {
        const braced = "${" ++ variable.name ++ "}";
        const bare = "$" ++ variable.name;
        if (std.mem.indexOf(u8, expanded, braced) != null or std.mem.indexOf(u8, expanded, bare) != null) {
            const directory = if (variable.suffix.len == 0) root else try std.fmt.allocPrint(a, "{s}{s}", .{ root, variable.suffix });
            if (std.mem.indexOf(u8, expanded, braced) != null) expanded = try std.mem.replaceOwned(u8, a, expanded, braced, directory);
            if (std.mem.indexOf(u8, expanded, bare) != null) expanded = try std.mem.replaceOwned(u8, a, expanded, bare, directory);
        }
    }
    return expanded;
}

pub const Options = struct {
    root: []const u8,
    timeout_ms: u64,
    stop: ?*const std.atomic.Value(bool) = null,

    fn cancelled(self: Options) bool {
        const flag = self.stop orelse return false;
        return flag.load(.acquire);
    }
};

pub const Output = struct {
    code: u8,
    stderr: []u8,
    stdout: []const u8,
    overflow: bool,
};

pub fn run(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    command: []const u8,
    payload: []const u8,
) !Output {
    var dir = try std.Io.Dir.cwd().openDir(io, options.root, .{});
    defer dir.close(io);

    if (options.cancelled()) return error.Cancelled;
    var command_arena: std.heap.ArenaAllocator = .init(allocator);
    defer command_arena.deinit();
    const entries = try environment(command_arena.allocator(), options.root);
    const argv = [_][]const u8{ "env", "-u", "BASH_ENV" } ++ entries ++ [_][]const u8{ "bash", "-c", command };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .cwd = .{ .dir = dir },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = if (supports_process_groups) 0 else null,
    });
    var reaped = false;
    defer if (!reaped) killGroup(io, &child);

    var input: InputWrite = .{ .io = io, .child = &child, .payload = payload };
    var input_future = try io.concurrent(InputWrite.run, .{&input});
    defer input_future.cancel(io);

    const output_streams = [_]std.Io.File{ child.stderr.?, child.stdout.? };
    var buffers: std.Io.File.MultiReader.Buffer(output_streams.len) = undefined;
    var readers: std.Io.File.MultiReader = undefined;
    readers.init(allocator, io, buffers.toStreams(), &output_streams);
    defer readers.deinit();

    const stderr_reader = readers.reader(0);
    const stdout_reader = readers.reader(1);
    var stdout_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer stdout_writer.deinit();
    var overflow = false;
    var stderr_writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer stderr_writer.deinit();
    const deadline = std.Io.Clock.now(.awake, io).toMilliseconds() + @as(i64, @intCast(options.timeout_ms));
    var stderr_done = false;

    while (!stderr_done or !input.done.isSet()) {
        // Returning runs the `killGroup` defer, taking the whole group.
        if (options.cancelled()) return error.Cancelled;
        const left = deadline - std.Io.Clock.now(.awake, io).toMilliseconds();
        if (left <= 0) return error.Timeout;
        const slice = @min(poll_slice_ms, @as(u64, @intCast(left)));

        if (stderr_done) {
            input.done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(slice)), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => {},
                else => return err,
            };
        } else {
            readers.fill(read_chunk_bytes, .{ .duration = .{
                .raw = .fromMilliseconds(@intCast(slice)),
                .clock = .awake,
            } }) catch |err| switch (err) {
                error.EndOfStream => stderr_done = true,
                error.Timeout => {},
                else => |other| return other,
            };
            const buffered = stderr_reader.buffered();
            const remaining = output_limit - stderr_writer.written().len;
            try stderr_writer.writer.writeAll(buffered[0..@min(buffered.len, remaining)]);
            stderr_reader.tossBuffered();
            const out_buffered = stdout_reader.buffered();
            const out_remaining = output_limit - stdout_writer.written().len;
            overflow = overflow or out_buffered.len > out_remaining;
            try stdout_writer.writer.writeAll(out_buffered[0..@min(out_buffered.len, out_remaining)]);
            stdout_reader.tossBuffered();
        }
    }

    input_future.await(io);
    try readers.checkAnyError();

    const pid = child.id.?;
    var waiter: ChildWait = .{ .io = io, .child = &child };
    var wait_future = try io.concurrent(ChildWait.run, .{&waiter});
    var cancelled = false;
    while (!waiter.done.isSet()) {
        const expired = deadline - std.Io.Clock.now(.awake, io).toMilliseconds() <= 0;
        if (options.cancelled() or cancelled or expired) {
            if (supports_process_groups) {
                std.posix.kill(-pid, .TERM) catch {};
                std.posix.kill(-pid, .KILL) catch {};
            }
            wait_future.await(io);
            reaped = true;
            if (expired) return error.Timeout;
            return error.Cancelled;
        }
        const left = deadline - std.Io.Clock.now(.awake, io).toMilliseconds();
        if (left <= 0) continue;
        waiter.done.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(@intCast(@min(poll_slice_ms, @as(u64, @intCast(left))))), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => cancelled = true,
        };
    }
    wait_future.await(io);
    reaped = true;
    if (cancelled or options.cancelled()) return error.Cancelled;
    const term = try waiter.term;
    const stderr = try stderr_writer.toOwnedSlice();
    errdefer allocator.free(stderr);
    const code: u8 = switch (term) {
        .exited => |value| value,
        else => 1,
    };
    return .{ .code = code, .stderr = stderr, .stdout = try stdout_writer.toOwnedSlice(), .overflow = overflow };
}

const ChildWait = struct {
    io: std.Io,
    child: *std.process.Child,
    term: std.process.Child.WaitError!std.process.Child.Term = undefined,
    done: std.Io.Event = .unset,

    fn run(self: *ChildWait) void {
        self.term = self.child.wait(self.io);
        self.done.set(self.io);
    }
};

const InputWrite = struct {
    io: std.Io,
    child: *std.process.Child,
    payload: []const u8,
    done: std.Io.Event = .unset,

    fn run(self: *InputWrite) void {
        defer self.done.set(self.io);
        defer {
            if (self.child.stdin) |stdin| stdin.close(self.io);
            self.child.stdin = null;
        }

        var buffer: [stdin_buffer_bytes]u8 = undefined;
        var writer = self.child.stdin.?.writer(self.io, &buffer);
        writer.interface.writeAll(self.payload) catch return;
        writer.interface.flush() catch return;
    }
};

fn killGroup(io: std.Io, child: *std.process.Child) void {
    const pid = child.id orelse return;
    if (supports_process_groups) std.posix.kill(-pid, .TERM) catch {};
    child.kill(io);
    if (supports_process_groups) std.posix.kill(-pid, .KILL) catch {};
}

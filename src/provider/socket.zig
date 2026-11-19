const std = @import("std");

const Socket = @This();

handle: std.posix.fd_t = -1,
mutex: std.Io.Mutex = .init,
aborted: bool = false,

pub fn abort(self: *Socket, io: std.Io) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.aborted = true;
    self.shutdownLocked(io);
}

fn shutdownLocked(self: *Socket, io: std.Io) void {
    if (self.handle == -1) return;
    io.vtable.netShutdown(io.userdata, self.handle, .both) catch {};
    self.handle = -1;
}

pub fn watch(self: *Socket, io: std.Io, request: *std.http.Client.Request) void {
    const connection = request.connection orelse return;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.handle = connection.stream_reader.stream.socket.handle;
    if (self.aborted) self.shutdownLocked(io);
}

pub fn arm(self: *Socket, io: std.Io) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.aborted = false;
    self.handle = -1;
}

pub fn forget(self: *Socket, io: std.Io) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.handle = -1;
}

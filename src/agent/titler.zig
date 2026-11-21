//! Naming a session nobody has named, from its first prompt and reply.
//!
//! The question goes out on a client of its own, beside whatever the session
//! does next, and is shown only the two messages it is about: never the live
//! transcript, which the next turn may be writing to.

const std = @import("std");
const testing = std.testing;

const Backend = @import("../provider/backend.zig");
const Provider = @import("../provider/provider.zig");
const Conversation = @import("../core/conversation.zig");
const Database = @import("../core/database.zig");
const Registry = @import("../tools/registry.zig");
const tool = @import("../tools/tool.zig");
const Loop = @import("loop.zig");
const Request = @import("request.zig");

const Titler = @This();

const system_prompt = "You name conversations.";

pub const prompt =
    \\Generate a concise 3-7 word title for this conversation, omitting punctuation.
    \\Go straight to the title, without any preamble and prefix like `Here's a concise suggestion:...` or `Title:`.
    \\If the conversation is about a specific subject, include it in the title.
    \\Be descriptive. DO NOT speak in the first person.
;

/// The longest title kept, which is what the rename field holds.
pub const max_bytes: usize = 60;
/// How much of the prompt and of the reply the model is shown. The gist is at
/// the start, and a pasted log would otherwise be paid for twice.
const excerpt_bytes: usize = 4 * 1024;
/// Silence after which the question is given up on.
const stall_ms: i64 = 60_000;

allocator: std.mem.Allocator,
io: std.Io,
/// Where the question's own client comes from.
backend: ?*Backend = null,
/// Asked directly instead of a spawned client. Only for one nothing else is
/// calling meanwhile.
provider: ?Provider = null,
pending: ?Pending = null,
/// `loop.finished` when a title was last asked for, so each turn is asked
/// about once and a failure waits for the next.
asked_at: ?usize = null,

const Pending = struct {
    request: *Request,
    convo: *Conversation,
    spawned: ?*Backend.Spawned,
    session_id: i64,
};

/// Name the session from an answer that already came; give up on one that has
/// not.
pub fn deinit(self: *Titler, loop: *Loop) void {
    const pending = self.pending orelse return;
    if (pending.request.isFinished()) {
        _ = self.collect(loop, pending) catch false;
        return;
    }
    pending.request.cancel();
    self.release(pending);
    self.pending = null;
}

/// Whether a question is out, which the session has to keep polling for.
pub fn busy(self: *const Titler) bool {
    return self.pending != null;
}

/// Ask for a title once an untitled session finishes a turn, and name it when
/// the answer comes. Returns true when the title changed.
pub fn poll(self: *Titler, loop: *Loop) !bool {
    if (self.pending) |pending| return self.collect(loop, pending);

    if (loop.isBusy() or loop.title().len > 0) return false;
    if ((loop.outcome orelse return false) != .done) return false;
    if (self.asked_at == loop.finished) return false;
    const session_id = loop.session_id orelse return false;
    self.asked_at = loop.finished;
    try self.ask(loop.conversation, session_id);
    return false;
}

fn ask(self: *Titler, convo: *Conversation, session_id: i64) !void {
    if (self.backend == null and self.provider == null) return;
    const asked = firstPrompt(convo) orelse return;
    const said = lastReply(convo) orelse return;

    const shown = try self.allocator.create(Conversation);
    errdefer self.allocator.destroy(shown);
    shown.* = .init(self.allocator);
    errdefer shown.deinit();
    _ = try shown.addUser(clip(asked, excerpt_bytes), &.{}, &.{});
    _ = try shown.addAssistant(clip(said, excerpt_bytes), null, null);

    const spawned = if (self.backend) |backend| try backend.spawn(self.allocator) else null;
    errdefer if (spawned) |client| client.deinit();
    const provider = if (spawned) |client| client.provider() else self.provider.?;

    const request = try Request.start(self.allocator, self.io, provider, shown, .{
        .system = system_prompt,
        .instruction = prompt,
    });
    self.pending = .{ .request = request, .convo = shown, .spawned = spawned, .session_id = session_id };
}

fn collect(self: *Titler, loop: *Loop, pending: Pending) !bool {
    if (!pending.request.isFinished()) {
        if (pending.request.stalled(stall_ms)) pending.request.requestStop();
        return false;
    }
    pending.request.join();
    self.pending = null;
    defer self.release(pending);

    const reply = pending.request.reply orelse return false;
    if (loop.title().len > 0 or loop.session_id != pending.session_id) return false;
    const name = clean(reply.text);
    if (name.len == 0) return false;
    try loop.rename(name);
    return true;
}

fn release(self: *Titler, pending: Pending) void {
    pending.request.destroy();
    pending.convo.deinit();
    self.allocator.destroy(pending.convo);
    if (pending.spawned) |client| client.deinit();
}

fn firstPrompt(convo: *const Conversation) ?[]const u8 {
    for (convo.messages.items) |msg| {
        if (msg.role == .user and msg.text.len > 0) return msg.text;
    }
    return null;
}

fn lastReply(convo: *const Conversation) ?[]const u8 {
    var at = convo.messages.items.len;
    while (at > 0) {
        at -= 1;
        const msg = convo.messages.items[at];
        if (msg.role != .assistant) continue;
        if (msg.text.len == 0 or std.mem.eql(u8, msg.text, Loop.no_reply)) continue;
        return msg.text;
    }
    return null;
}

/// The title in a reply: its first line, without the dressing a model puts
/// around one, and short enough to show.
pub fn clean(reply: []const u8) []const u8 {
    var lines = std.mem.tokenizeAny(u8, reply, "\r\n");
    var line = trim(lines.next() orelse return "");
    if (std.ascii.startsWithIgnoreCase(line, "title:")) line = trim(line["title:".len..]);
    return std.mem.trimEnd(u8, clip(line, max_bytes), " ");
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\"'`*#_.:");
}

/// At most `limit` bytes of `text`, ending on a character boundary.
fn clip(text: []const u8, limit: usize) []const u8 {
    if (text.len <= limit) return text;
    var end = limit;
    while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
    return text[0..end];
}

test "a title is the first line of the reply" {
    try testing.expectEqualStrings("Fix the login redirect", clean("Fix the login redirect\nIt was looping."));
    try testing.expectEqualStrings("Fix the login redirect", clean("\n\n  Fix the login redirect  \n"));
}

test "a title loses the quotes and prefix a model wraps it in" {
    try testing.expectEqualStrings("Port the parser to Zig", clean("\"Port the parser to Zig.\""));
    try testing.expectEqualStrings("Port the parser to Zig", clean("**Title:** Port the parser to Zig"));
    try testing.expectEqualStrings("", clean("  \n\"\"\n"));
}

test "a long title is cut on a character boundary" {
    const long = "Résumé " ** 20;
    const cut = clean(long);
    try testing.expect(cut.len <= max_bytes);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    try testing.expect(cut[cut.len - 1] != ' ');
}

/// Answers a turn plainly and a request for a title with `title`.
const Fake = struct {
    title: []const u8 = "Fix the login redirect\nsecond line",
    titles_asked: usize = 0,
    /// Fail the title request, the way a dropped connection does.
    fail_titles: bool = false,

    fn provider(self: *Fake) Provider {
        return .{ .name = "fake", .model = "fake", .userdata = self, .respond = respond };
    }

    fn respond(
        ptr: *anyopaque,
        convo: *Conversation,
        asked: Provider.Turn,
        allocator: std.mem.Allocator,
        _: ?Provider.Sink,
    ) anyerror!Provider.Reply {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, asked.instruction, prompt)) return .{ .text = try allocator.dupe(u8, "Done.") };

        self.titles_asked += 1;
        if (self.fail_titles) return error.ConnectionResetByPeer;
        try testing.expectEqual(@as(usize, 2), convo.messages.items.len);
        try testing.expectEqualStrings("the login page loops", convo.messages.items[0].text);
        try testing.expectEqualStrings("Done.", convo.messages.items[1].text);
        return .{ .text = try allocator.dupe(u8, self.title) };
    }
};

const Fixture = struct {
    tmp: testing.TmpDir,
    root: []u8,
    db: Database,
    convo: Conversation,
    registry: Registry,
    reads: tool.ReadLog,
    fake: Fake = .{},
    loop: Loop,
    titler: Titler,

    fn create() !*Fixture {
        const self = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(self);
        self.tmp = testing.tmpDir(.{});
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        self.root = try testing.allocator.dupe(u8, buf[0..try self.tmp.dir.realPath(testing.io, &buf)]);
        self.db = try Database.init(testing.allocator, testing.io, ":memory:");
        self.convo = .init(testing.allocator);
        self.registry = try Registry.init(testing.allocator);
        self.reads = .init(testing.allocator);
        self.fake = .{};
        self.loop = .init(testing.allocator, testing.io, self.fake.provider(), &self.registry, &self.convo, &self.reads, self.root);
        try self.loop.attachDatabase(&self.db, "project", self.root, "fake");
        self.titler = .{ .allocator = testing.allocator, .io = testing.io, .provider = self.fake.provider() };
        return self;
    }

    fn destroy(self: *Fixture) void {
        self.titler.deinit(&self.loop);
        self.loop.deinit();
        self.reads.deinit();
        self.registry.deinit();
        self.convo.deinit();
        self.db.deinit();
        testing.allocator.free(self.root);
        self.tmp.cleanup();
        testing.allocator.destroy(self);
    }

    fn turn(self: *Fixture, text: []const u8) !void {
        try self.loop.submit(text, .{});
        try self.settle();
    }

    /// Poll the loop and the titler until neither has anything outstanding.
    fn settle(self: *Fixture) !void {
        var waited_ms: usize = 0;
        while (true) {
            _ = try self.loop.poll();
            _ = try self.titler.poll(&self.loop);
            if (!self.loop.isBusy() and !self.titler.busy()) return;
            try std.Io.sleep(testing.io, .fromMilliseconds(1), .real);
            waited_ms += 1;
            if (waited_ms > 5_000) return error.DidNotSettle;
        }
    }
};

test "an untitled session is named after its first turn" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    try fixture.turn("the login page loops");
    try testing.expectEqualStrings("Fix the login redirect", fixture.loop.title());
    try testing.expectEqual(@as(usize, 1), fixture.fake.titles_asked);

    const stored = try fixture.db.sessionTitle(fixture.loop.session_id.?, testing.allocator);
    defer testing.allocator.free(stored);
    try testing.expectEqualStrings("Fix the login redirect", stored);

    try fixture.turn("and the logout page");
    try testing.expectEqual(@as(usize, 1), fixture.fake.titles_asked);
}

test "a session named by hand is not renamed" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    try fixture.loop.rename("mine");
    try fixture.turn("the login page loops");
    try testing.expectEqualStrings("mine", fixture.loop.title());
    try testing.expectEqual(@as(usize, 0), fixture.fake.titles_asked);
}

test "a failed title leaves the session untitled until the next turn" {
    const fixture = try Fixture.create();
    defer fixture.destroy();
    fixture.fake.fail_titles = true;

    try fixture.turn("the login page loops");
    try testing.expectEqualStrings("", fixture.loop.title());
    try testing.expectEqual(@as(usize, 1), fixture.fake.titles_asked);

    try fixture.settle();
    try testing.expectEqual(@as(usize, 1), fixture.fake.titles_asked);

    fixture.fake.fail_titles = false;
    try fixture.turn("the login page loops");
    try testing.expectEqualStrings("Fix the login redirect", fixture.loop.title());
    try testing.expectEqual(@as(usize, 2), fixture.fake.titles_asked);
}

test "an answer that came before teardown still names the session" {
    const fixture = try Fixture.create();
    defer fixture.destroy();

    try fixture.loop.submit("the login page loops", .{});
    while (fixture.loop.isBusy()) {
        _ = try fixture.loop.poll();
        try std.Io.sleep(testing.io, .fromMilliseconds(1), .real);
    }
    _ = try fixture.titler.poll(&fixture.loop);
    try testing.expect(fixture.titler.busy());
    while (!fixture.titler.pending.?.request.isFinished()) try std.Io.sleep(testing.io, .fromMilliseconds(1), .real);

    fixture.titler.deinit(&fixture.loop);
    try testing.expect(!fixture.titler.busy());
    try testing.expectEqualStrings("Fix the login redirect", fixture.loop.title());
}

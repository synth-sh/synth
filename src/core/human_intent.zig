const std = @import("std");
const Conversation = @import("conversation.zig");
const Intent = @This();

pub const prompt_bytes = 12 * 1024;
pub const decision_bytes = 2 * 1024;
const max_messages = 64;

is_complete: bool = true,
prompts: std.ArrayList(Conversation.Message) = .empty,
decisions: std.ArrayList(Conversation.Message) = .empty,

pub const Snapshot = struct {
    messages: []Conversation.Message,
    is_complete: bool,

    pub fn deinit(self: Snapshot, a: std.mem.Allocator) void {
        for (self.messages) |*message| message.deinit(a);
        a.free(self.messages);
    }
};

pub fn deinit(self: *Intent, a: std.mem.Allocator) void {
    for (self.prompts.items) |*message| message.deinit(a);
    for (self.decisions.items) |*message| message.deinit(a);
    self.prompts.deinit(a);
    self.decisions.deinit(a);
    self.* = .{};
}

pub fn record(self: *Intent, a: std.mem.Allocator, text: []const u8, decision: bool) !void {
    const messages = if (decision) &self.decisions else &self.prompts;
    const limit: usize = if (decision) decision_bytes else prompt_bytes;
    const available = if (decision) limit else if (messages.items.len == 0) limit / 2 else limit - messages.items[0].text.len;
    const body = try a.dupe(u8, clip(text, available));
    if (body.len < text.len) self.is_complete = false;
    if (decision and std.mem.startsWith(u8, text, "{")) {
        if (std.json.parseFromSlice(std.json.Value, a, text, .{})) |receipt| {
            defer receipt.deinit();
            if (receipt.value == .object) if (receipt.value.object.get("is_complete")) |complete| {
                if (complete != .bool or !complete.bool) self.is_complete = false;
            };
        } else |_| self.is_complete = false;
    }
    errdefer a.free(body);
    try messages.append(a, .{ .role = .user, .origin = if (decision) .human_decision else .human, .text = body });
    var size: usize = 0;
    for (messages.items) |message| size += message.text.len;
    while (size > limit or messages.items.len > max_messages) {
        self.is_complete = false;
        var old = messages.orderedRemove(if (decision or messages.items.len == 1) 0 else 1);
        size -= old.text.len;
        old.deinit(a);
    }
}

pub fn clip(text: []const u8, limit: usize) []const u8 {
    var length = @min(text.len, limit);
    while (length > 0 and length < text.len and text[length] & 0xc0 == 0x80) length -= 1;
    return text[0..length];
}

pub fn view(self: Intent, a: std.mem.Allocator) ![]Conversation.Message {
    return std.mem.concat(a, Conversation.Message, &.{ self.prompts.items, self.decisions.items });
}

pub fn take(self: *Intent, a: std.mem.Allocator) ![]Conversation.Message {
    const result = try self.view(a);
    self.prompts.clearRetainingCapacity();
    self.decisions.clearRetainingCapacity();
    return result;
}

test "decision history cannot displace human requests" {
    const a = std.testing.allocator;
    var intent: Intent = .{};
    defer intent.deinit(a);
    try intent.record(a, "inspect only", false);
    for (0..100) |_| try intent.record(a, "denied action", true);
    const messages = try intent.view(a);
    defer a.free(messages);
    try std.testing.expectEqualStrings("inspect only", messages[0].text);
}

test "the initial task and latest correction survive a long human conversation" {
    const a = std.testing.allocator;
    var intent: Intent = .{};
    defer intent.deinit(a);
    try intent.record(a, "inspect only; do not upload", false);
    for (0..100) |_| try intent.record(a, "continue investigating", false);
    try intent.record(a, "stop now", false);
    const messages = try intent.view(a);
    defer a.free(messages);
    try std.testing.expectEqualStrings("inspect only; do not upload", messages[0].text);
    try std.testing.expectEqualStrings("stop now", messages[messages.len - 1].text);
}

test "clipped answer receipts cannot restore complete review evidence" {
    const a = std.testing.allocator;
    var intent: Intent = .{};
    defer intent.deinit(a);
    try intent.record(a, "inspect the project", false);
    try intent.record(a, "{\"kind\":\"human_answer\",\"answer\":\"partial answer\",\"is_complete\":false}", true);
    try std.testing.expect(!intent.is_complete);
}

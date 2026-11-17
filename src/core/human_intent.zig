const std = @import("std");
const Conversation = @import("conversation.zig");
const Intent = @This();

pub const prompt_bytes = 12 * 1024;
pub const decision_bytes = 2 * 1024;
const max_messages = 64;

prompts: std.ArrayList(Conversation.Message) = .empty,
decisions: std.ArrayList(Conversation.Message) = .empty,

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
    var length = @min(text.len, limit);
    while (length > 0 and length < text.len and text[length] & 0xc0 == 0x80) length -= 1;
    const body = try a.dupe(u8, text[0..length]);
    errdefer a.free(body);
    try messages.append(a, .{ .role = .user, .origin = .human, .text = body });
    var size: usize = 0;
    for (messages.items) |message| size += message.text.len;
    while (size > limit or messages.items.len > max_messages) {
        var old = messages.orderedRemove(0);
        size -= old.text.len;
        old.deinit(a);
    }
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

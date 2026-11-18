const std = @import("std");
const Conversation = @import("conversation.zig");
const Intent = @This();

pub const decision_bytes = 2 * 1024;
pub const max_decisions = 64;

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
    if (decision and std.mem.startsWith(u8, text, "{")) {
        const receipt = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                self.is_complete = false;
                return;
            },
        };
        defer receipt.deinit();
        if (receipt.value == .object) {
            if (receipt.value.object.get("kind")) |kind| {
                if (kind == .string and std.mem.eql(u8, kind.string, "human_answer")) {
                    if (receipt.value.object.get("is_complete")) |complete| {
                        if (complete != .bool or !complete.bool) self.is_complete = false;
                    }
                    const answer = receipt.value.object.get("answer") orelse return error.InvalidHumanAnswer;
                    if (answer != .string) return error.InvalidHumanAnswer;
                    return self.record(a, answer.string, false);
                }
            }
        }
    }
    const body = try a.dupe(u8, if (decision) clip(text, decision_bytes) else text);
    errdefer a.free(body);
    const messages = if (decision) &self.decisions else &self.prompts;
    try messages.append(a, .{ .role = .user, .origin = if (decision) .human_decision else .human, .text = body });
    if (!decision) return;
    var size: usize = 0;
    for (messages.items) |message| size += message.text.len;
    while (size > decision_bytes or messages.items.len > max_decisions) {
        var old = messages.orderedRemove(0);
        size -= old.text.len;
        old.deinit(a);
    }
}

fn clip(text: []const u8, limit: usize) []const u8 {
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
    try std.testing.expect(intent.is_complete);
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
    try std.testing.expect(intent.is_complete);
    try std.testing.expectEqual(@as(usize, 102), messages.len);
}

test "clipped answer receipts cannot restore complete review evidence" {
    const a = std.testing.allocator;
    var intent: Intent = .{};
    defer intent.deinit(a);
    try intent.record(a, "inspect the project", false);
    try intent.record(a, "{\"kind\":\"human_answer\",\"answer\":\"partial answer\",\"is_complete\":false}", true);
    try std.testing.expect(!intent.is_complete);
}

test "human instructions are preserved for the reviewer actual context window" {
    const a = std.testing.allocator;
    var intent: Intent = .{};
    defer intent.deinit(a);
    const prompt = try a.alloc(u8, 7 * 1024);
    defer a.free(prompt);
    @memset(prompt, 'x');
    try intent.record(a, prompt, false);
    const messages = try intent.view(a);
    defer a.free(messages);
    try std.testing.expectEqualStrings(prompt, messages[0].text);
    try std.testing.expect(intent.is_complete);
}

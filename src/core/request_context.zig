const std = @import("std");
const Conversation = @import("conversation.zig");

pub const Patch = struct {
    system: ?[]const u8 = null,
    instruction: ?[]const u8 = null,
    tools: ?[]const []const u8 = null,
    messages: []const Edit = &.{},
};

pub const Edit = struct {
    seq: u64,
    text: ?[]const u8 = null,
    omit: bool = false,
    omit_attachments: bool = false,
    omit_images: bool = false,
    omit_thinking: bool = false,
    tool_results: []const ToolResult = &.{},
};

pub const ToolResult = struct { call_id: []const u8, text: []const u8 };

pub fn selectTools(a: std.mem.Allocator, definitions: []const u8, names: []const []const u8) ![]const u8 {
    const source = try std.json.parseFromSliceLeaky(std.json.Value, a, if (definitions.len == 0) "[]" else definitions, .{});
    if (source != .array) return error.InvalidToolDefinitions;
    var selected: std.ArrayList(std.json.Value) = .empty;
    for (names, 0..) |name, i| {
        for (names[0..i]) |earlier| if (std.mem.eql(u8, name, earlier)) return error.DuplicateRequestTool;
        for (source.array.items) |definition| {
            const function = if (definition == .object) definition.object.get("function") orelse return error.InvalidToolDefinitions else return error.InvalidToolDefinitions;
            const tool_name = if (function == .object) function.object.get("name") orelse return error.InvalidToolDefinitions else return error.InvalidToolDefinitions;
            if (tool_name == .string and std.mem.eql(u8, tool_name.string, name)) {
                try selected.append(a, definition);
                break;
            }
        } else return error.UnknownRequestTool;
    }
    return std.json.Stringify.valueAlloc(a, selected.items, .{});
}

pub fn permits(a: std.mem.Allocator, definitions: []const u8, name: []const u8) !bool {
    _ = selectTools(a, definitions, &.{name}) catch |err| switch (err) {
        error.UnknownRequestTool => return false,
        else => return err,
    };
    return true;
}

pub fn apply(conversation: *Conversation, edits: []const Edit) !void {
    const a = conversation.allocator;
    for (edits) |edit| {
        var index: ?usize = null;
        for (conversation.messages.items, 0..) |message, i| if (message.seq == edit.seq) {
            index = i;
            break;
        };
        const i = index orelse return error.InvalidContextEdit;
        const message = &conversation.messages.items[i];
        if (edit.omit) {
            if (message.tool_calls.len > 0 or message.role == .tool or message.role == .system) return error.IncompleteContextExchange;
            var removed = conversation.messages.orderedRemove(i);
            removed.deinit(a);
            continue;
        }
        if (edit.text) |text| {
            const copy = try a.dupe(u8, text);
            a.free(message.text);
            message.text = copy;
        }
        if (edit.omit_thinking) {
            if (message.thinking) |thinking| a.free(thinking);
            message.thinking = null;
        }
        if (edit.omit_attachments) {
            for (message.attachments) |*attachment| attachment.deinit(a);
            if (message.attachments.len > 0) a.free(message.attachments);
            message.attachments = &.{};
        }
        if (edit.omit_images) {
            for (message.images) |image| a.free(image);
            if (message.images.len > 0) a.free(message.images);
            message.images = &.{};
        }
        for (edit.tool_results) |replacement| {
            for (message.tool_calls) |*call| {
                if (!std.mem.eql(u8, call.id, replacement.call_id)) continue;
                const copy = try a.dupe(u8, replacement.text);
                if (call.result) |old| a.free(old);
                call.result = copy;
                call.result_bytes = copy.len;
                for (conversation.messages.items[i + 1 ..]) |*result| {
                    if (result.role == .user or result.role == .assistant or result.role == .system) break;
                    if (result.role != .tool or !std.mem.eql(u8, result.tool_call_id orelse "", call.id)) continue;
                    const body = try a.dupe(u8, replacement.text);
                    a.free(result.text);
                    result.text = body;
                    result.origin = .hook;
                    break;
                }
                break;
            } else return error.UnknownContextToolCall;
        }
        if (message.provider_state) |state| a.free(state);
        message.provider_state = null;
        message.origin = .hook;
    }
}

test "request tool selection cannot add tools and context cannot split tool exchanges" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const definitions = "[{\"type\":\"function\",\"function\":{\"name\":\"read\"}}]";
    _ = try selectTools(a, definitions, &.{"read"});
    try std.testing.expectError(error.UnknownRequestTool, selectTools(a, definitions, &.{"bash"}));
    try std.testing.expectError(error.DuplicateRequestTool, selectTools(a, definitions, &.{ "read", "read" }));
    var conversation = Conversation.init(std.testing.allocator);
    defer conversation.deinit();
    var calls = [_]Conversation.ToolCall{.{ .id = "call", .name = "read", .arguments = "{}", .status = .ok, .result = "secret" }};
    _ = try conversation.append(.{ .role = .assistant, .text = "", .tool_calls = &calls });
    _ = try conversation.addToolResult("read", "call", "secret");
    try apply(&conversation, &.{.{ .seq = 0, .tool_results = &.{.{ .call_id = "call", .text = "filtered" }} }});
    try std.testing.expectEqualStrings("filtered", conversation.messages.items[0].tool_calls[0].result.?);
    try std.testing.expectEqualStrings("filtered", conversation.messages.items[1].text);
    try std.testing.expectError(error.IncompleteContextExchange, apply(&conversation, &.{.{ .seq = 0, .omit = true }}));
}

test "edited request messages clear replay state without changing reference messages" {
    const a = std.testing.allocator;
    var original = Conversation.init(a);
    defer original.deinit();
    var images = [_][]const u8{"secret-image"};
    _ = try original.append(.{ .role = .user, .origin = .human, .text = "secret", .provider_state = "secret replay", .images = &images, .thinking = "secret reasoning" });
    var prepared = Conversation.init(a);
    defer prepared.deinit();
    try prepared.adoptMessage(try original.messages.items[0].clone(a));
    try apply(&prepared, &.{.{ .seq = 0, .text = "filtered", .omit_images = true, .omit_thinking = true }});
    try std.testing.expect(prepared.messages.items[0].provider_state == null);
    try std.testing.expect(prepared.messages.items[0].thinking == null);
    try std.testing.expectEqual(@as(usize, 0), prepared.messages.items[0].images.len);
    try std.testing.expectEqualStrings("secret replay", original.messages.items[0].provider_state.?);
    try std.testing.expectEqual(Conversation.Origin.human, original.messages.items[0].origin);
}

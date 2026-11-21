const std = @import("std");

pub const Trust = enum { local, private, hosted };
pub const Tier = enum { small, mid, frontier };

pub const Class = struct {
    model: []const u8,
    provider: ?[]const u8 = null,
    trust: Trust = .hosted,
    tier: Tier = .small,
};

pub const Resolved = struct {
    trust: Trust = .hosted,
    tier: Tier = .small,
};

pub fn resolve(classes: []const Class, provider: []const u8, model: []const u8) Resolved {
    for (classes) |class| {
        if (!std.mem.eql(u8, class.model, model)) continue;
        if (class.provider) |name| if (!std.mem.eql(u8, name, provider)) continue;
        return .{ .trust = class.trust, .tier = class.tier };
    }
    return .{};
}

pub fn Choice(comptime T: type) type {
    return struct {
        values: []const T,

        pub fn has(self: @This(), name: []const u8) bool {
            for (self.values) |value| if (std.mem.eql(u8, @tagName(value), name)) return true;
            return false;
        }

        pub fn jsonStringify(self: @This(), writer: anytype) !void {
            try writer.write(self.values);
        }

        pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, _: std.json.ParseOptions) !@This() {
            switch (source) {
                .string => |name| {
                    const value = std.meta.stringToEnum(T, name) orelse return error.InvalidEnumTag;
                    return .{ .values = try allocator.dupe(T, &.{value}) };
                },
                .array => |items| {
                    if (items.items.len == 0) return error.UnexpectedToken;
                    const values = try allocator.alloc(T, items.items.len);
                    for (items.items, values) |item, *slot| {
                        if (item != .string) return error.UnexpectedToken;
                        slot.* = std.meta.stringToEnum(T, item.string) orelse return error.InvalidEnumTag;
                    }
                    return .{ .values = values };
                },
                else => return error.UnexpectedToken,
            }
        }
    };
}

test "a model with no declared class is hosted and small" {
    const classes = [_]Class{.{ .model = "qwen3:27b", .trust = .local, .tier = .mid }};
    try std.testing.expectEqual(Resolved{ .trust = .local, .tier = .mid }, resolve(&classes, "ollama", "qwen3:27b"));
    try std.testing.expectEqual(Resolved{}, resolve(&classes, "ollama", "unknown"));
}

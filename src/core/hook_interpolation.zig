const std = @import("std");

const max_interpolation_depth = 64;
const reference_start = "${";
const reference_end = '}';

pub fn expand(arena: std.mem.Allocator, value: std.json.Value, input: std.json.Value) !std.json.Value {
    return expandDepth(arena, value, input, 0);
}
fn expandDepth(arena: std.mem.Allocator, value: std.json.Value, input: std.json.Value, depth: usize) anyerror!std.json.Value {
    if (depth > max_interpolation_depth) return error.HookInterpolationTooDeep;
    switch (value) {
        .string => |source| {
            if (std.mem.startsWith(u8, source, reference_start) and source[source.len - 1] == reference_end) {
                const field_path = source[reference_start.len .. source.len - 1];
                if (std.mem.indexOfScalar(u8, field_path, reference_end) == null) return lookup(input, field_path);
            }
            var writer: std.Io.Writer.Allocating = .init(arena);
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, source, at, reference_start)) |start| {
                try writer.writer.writeAll(source[at..start]);
                const field_start = start + reference_start.len;
                const end = std.mem.indexOfScalarPos(u8, source, field_start, reference_end) orelse return error.InvalidHookInterpolation;
                const field = try lookup(input, source[field_start..end]);
                if (field == .string) try writer.writer.writeAll(field.string) else try std.json.Stringify.value(field, .{}, &writer.writer);
                at = end + 1;
            }
            try writer.writer.writeAll(source[at..]);
            return .{ .string = try writer.toOwnedSlice() };
        },
        .object => |object| {
            var result: std.json.ObjectMap = .empty;
            var entries = object.iterator();
            while (entries.next()) |entry| try result.put(arena, entry.key_ptr.*, try expandDepth(arena, entry.value_ptr.*, input, depth + 1));
            return .{ .object = result };
        },
        .array => |array| {
            var result: std.array_list.Managed(std.json.Value) = .init(arena);
            for (array.items) |item| try result.append(try expandDepth(arena, item, input, depth + 1));
            return .{ .array = result };
        },
        else => return value,
    }
}
fn lookup(input: std.json.Value, path: []const u8) !std.json.Value {
    var current = input;
    var fields = std.mem.splitScalar(u8, path, '.');
    while (fields.next()) |field| {
        if (current == .object) {
            current = current.object.get(field) orelse return error.MissingHookField;
        } else if (current == .array) {
            const index = std.fmt.parseInt(usize, field, 10) catch return error.MissingHookField;
            if (index >= current.array.items.len) return error.MissingHookField;
            current = current.array.items[index];
        } else return error.MissingHookField;
    }
    return current;
}

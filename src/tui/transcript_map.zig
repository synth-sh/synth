//! Where text sits in the transcript, independent of how far it is scrolled.
//!
//! A selection in the transcript is anchored to a block and a row inside it
//! rather than to the screen, so it stays on the same text while the view
//! scrolls under a drag, and can reach blocks no longer on screen.

const std = @import("std");

const Selection = @import("selection.zig");

/// One block's identity, ordered the way the transcript stacks blocks. Stable
/// across scrolling and across older history being paged in above it.
pub const BlockId = struct {
    /// 0 for the line above trimmed history, a message's seq plus one for its
    /// blocks, and the maximum for the live tail below every message.
    major: u64,
    /// The block's place among those of the same message or of the tail.
    minor: u32,

    pub const notice: BlockId = .{ .major = 0, .minor = 0 };

    pub fn ofMessage(seq: u64, minor: u32) BlockId {
        return .{ .major = seq + 1, .minor = minor };
    }

    pub fn ofTail(minor: u32) BlockId {
        return .{ .major = std.math.maxInt(u64), .minor = minor };
    }

    pub fn order(a: BlockId, b: BlockId) std.math.Order {
        const major = std.math.order(a.major, b.major);
        return if (major != .eq) major else std.math.order(a.minor, b.minor);
    }
};

/// A cell of the transcript: a row of one block's drawing, and a column of the
/// transcript.
pub const Position = struct {
    block: BlockId,
    row: u16,
    col: u16,

    pub fn order(a: Position, b: Position) std.math.Order {
        const block = a.block.order(b.block);
        if (block != .eq) return block;
        const row = std.math.order(a.row, b.row);
        return if (row != .eq) row else std.math.order(a.col, b.col);
    }
};

/// A block as last frame laid it out: its first row, counted from the top of
/// the transcript's area and negative once scrolled above it, and its height.
pub const Placed = struct {
    id: BlockId,
    top: i32,
    height: u16,
};

/// Every block last frame laid out, oldest first, and where the transcript's
/// area was on screen. Blocks past what the frame measured are missing, which
/// is why `project` answers by order for a block it cannot find.
pub const Layout = struct {
    blocks: []const Placed = &.{},
    area: Selection.Rect,
    /// Rows the view has scrolled back since the blocks were placed. Scrolling
    /// between frames moves every block down by it.
    shift: i32 = 0,

    /// The transcript position under a screen point, which is clamped to the
    /// area first. A point between blocks, or past either end, lands on the
    /// nearest edge of the block before it, or of the first block.
    pub fn locate(self: Layout, point: Selection.Point) ?Position {
        if (self.blocks.len == 0) return null;
        const clamped = self.area.clamp(point);
        const row = @as(i32, clamped.row) - self.area.top - self.shift;
        const col = clamped.col - self.area.left;
        const last_col = self.area.right - self.area.left;

        const first = self.blocks[0];
        if (row < first.top) return .{ .block = first.id, .row = 0, .col = 0 };

        var i = self.blocks.len;
        while (i > 0) {
            i -= 1;
            const block = self.blocks[i];
            if (block.height == 0 or row < block.top) continue;
            if (row < block.top + block.height) {
                return .{ .block = block.id, .row = @intCast(row - block.top), .col = col };
            }
            return .{ .block = block.id, .row = block.height - 1, .col = last_col };
        }
        return .{ .block = first.id, .row = 0, .col = 0 };
    }

    /// Where a position is drawn now, held inside the area: one above it maps to
    /// the area's first cell, one below to its last.
    pub fn project(self: Layout, position: Position) Selection.Point {
        const before: Selection.Point = .{ .row = self.area.top, .col = self.area.left };
        const after: Selection.Point = .{ .row = self.area.bottom, .col = self.area.right };
        if (self.blocks.len == 0) return before;

        for (self.blocks) |block| {
            if (block.id.order(position.block) != .eq) continue;
            const row = @as(i64, self.area.top) + block.top + self.shift + position.row;
            if (row < self.area.top) return before;
            if (row > self.area.bottom) return after;
            return self.area.clamp(.{ .row = @intCast(row), .col = self.area.left +| position.col });
        }
        return if (position.block.order(self.blocks[0].id) == .lt) before else after;
    }
};

const testing = std.testing;

fn fixture() Layout {
    const blocks = comptime [_]Placed{
        .{ .id = .ofMessage(4, 0), .top = -6, .height = 4 },
        .{ .id = .ofMessage(4, 1), .top = -1, .height = 3 },
        .{ .id = .ofMessage(5, 1), .top = 3, .height = 5 },
        .{ .id = .ofMessage(6, 1), .top = 9, .height = 2 },
    };
    return .{ .blocks = &blocks, .area = .{ .top = 2, .left = 3, .bottom = 9, .right = 22 } };
}

test "a point inside a block names that block and the row within it" {
    const layout = fixture();
    const at = layout.locate(.{ .row = 6, .col = 10 }).?;
    try testing.expectEqual(BlockId.ofMessage(5, 1), at.block);
    try testing.expectEqual(@as(u16, 1), at.row);
    try testing.expectEqual(@as(u16, 7), at.col);
}

test "a point in the gap between blocks lands at the end of the one above" {
    const layout = fixture();
    const at = layout.locate(.{ .row = 4, .col = 5 }).?;
    try testing.expectEqual(BlockId.ofMessage(4, 1), at.block);
    try testing.expectEqual(@as(u16, 2), at.row);
    try testing.expectEqual(@as(u16, 19), at.col);
}

test "a point past the area is held to its edge first" {
    const layout = fixture();
    const above = layout.locate(.{ .row = 0, .col = 0 }).?;
    try testing.expectEqual(BlockId.ofMessage(4, 1), above.block);
    try testing.expectEqual(@as(u16, 1), above.row);
    try testing.expectEqual(@as(u16, 0), above.col);
}

test "a position is drawn where its block is, and held to the area when it is not" {
    const layout = fixture();
    try testing.expectEqual(Selection.Point{ .row = 6, .col = 10 }, layout.project(.{ .block = .ofMessage(5, 1), .row = 1, .col = 7 }));
    try testing.expectEqual(Selection.Point{ .row = 2, .col = 3 }, layout.project(.{ .block = .ofMessage(4, 0), .row = 0, .col = 4 }));
    try testing.expectEqual(Selection.Point{ .row = 9, .col = 22 }, layout.project(.{ .block = .ofMessage(6, 1), .row = 1, .col = 0 }));
}

test "a block the frame never measured is placed by its order" {
    const layout = fixture();
    try testing.expectEqual(Selection.Point{ .row = 2, .col = 3 }, layout.project(.{ .block = .ofMessage(1, 0), .row = 0, .col = 0 }));
    try testing.expectEqual(Selection.Point{ .row = 9, .col = 22 }, layout.project(.{ .block = .ofTail(0), .row = 0, .col = 0 }));
}

test "positions order by block, then row, then column" {
    const a: Position = .{ .block = .ofMessage(2, 1), .row = 3, .col = 9 };
    const b: Position = .{ .block = .ofMessage(2, 1), .row = 4, .col = 0 };
    const c: Position = .{ .block = .ofTail(0), .row = 0, .col = 0 };
    try testing.expectEqual(std.math.Order.lt, a.order(b));
    try testing.expectEqual(std.math.Order.lt, b.order(c));
    try testing.expectEqual(std.math.Order.gt, c.order(.{ .block = .notice, .row = 9, .col = 9 }));
}

test "scrolling since the frame moves every block by as much" {
    var layout = fixture();
    layout.shift = 3;
    const at = layout.locate(.{ .row = 9, .col = 10 }).?;
    try testing.expectEqual(BlockId.ofMessage(5, 1), at.block);
    try testing.expectEqual(@as(u16, 1), at.row);
    try testing.expectEqual(Selection.Point{ .row = 9, .col = 10 }, layout.project(at));
}

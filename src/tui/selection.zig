//! Mouse text selection.

const std = @import("std");

const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Cell = vaxis.Cell;

const w = @import("widgets.zig");

const Selection = @This();

/// Bytes stored per cell. Enough for any grapheme worth selecting; longer ones
/// are truncated rather than allocated for.
const cell_bytes = 12;

const GridCell = struct {
    bytes: [cell_bytes]u8 = @splat(0),
    len: u8 = 0,
    /// One-based index into `uris`, or 0 when the cell is not part of a link.
    /// An index rather than a slice so a cell painted over by a later surface
    /// loses the link along with the text, which is what makes hit testing
    /// agree with what is on screen.
    link: u16 = 0,
    /// Drawn around the text rather than as part of it: never highlighted or
    /// copied.
    decoration: bool = false,

    fn slice(self: *const GridCell) []const u8 {
        return self.bytes[0..self.len];
    }

    fn isChrome(self: *const GridCell) bool {
        return self.decoration or self.len == 0 or std.mem.eql(u8, self.slice(), " ");
    }
};

pub const Point = struct {
    row: u16,
    col: u16,

    fn beforeOrEqual(self: Point, other: Point) bool {
        if (self.row != other.row) return self.row < other.row;
        return self.col <= other.col;
    }
};

/// A part of the screen drawn as its own document: the transcript, the sidebar,
/// the composer, a dialog. Edges are inclusive.
pub const Rect = struct {
    top: u16,
    left: u16,
    bottom: u16,
    right: u16,

    pub const everything: Rect = .{ .top = 0, .left = 0, .bottom = std.math.maxInt(u16), .right = std.math.maxInt(u16) };

    /// The rect covering `height` rows and `width` columns from (`row`, `col`),
    /// or null when that is no area at all.
    pub fn sized(row: u16, col: u16, height: u16, width: u16) ?Rect {
        if (height == 0 or width == 0) return null;
        return .{ .top = row, .left = col, .bottom = row + height - 1, .right = col + width - 1 };
    }

    fn holds(self: Rect, point: Point) bool {
        return point.row >= self.top and point.row <= self.bottom and
            point.col >= self.left and point.col <= self.right;
    }

    fn clamp(self: Rect, point: Point) Point {
        return .{
            .row = std.math.clamp(point.row, self.top, self.bottom),
            .col = std.math.clamp(point.col, self.left, self.right),
        };
    }
};

allocator: std.mem.Allocator,
/// Row-major snapshot of the last frame, rebuilt on every draw.
cells: []GridCell = &.{},
/// Link targets referenced by the grid, in the order they were first drawn.
/// The slices borrow from whatever drew them - a message's own text - which
/// outlives the frame.
uris: std.ArrayList([]const u8) = .empty,
width: u16 = 0,
height: u16 = 0,

/// Where the drag started, and where it currently is. Both null when nothing
/// is selected.
anchor: ?Point = null,
head: ?Point = null,
dragging: bool = false,
/// The region the drag started in, which it never leaves: a selection spanning
/// the transcript and the sidebar is never what was meant, since they are
/// separate documents that happen to share a screen.
area: Rect = .everything,
/// The regions last frame drew, bottom first, so the last that holds a point
/// is the one on top.
regions: std.ArrayList(Rect) = .empty,

pub fn init(allocator: std.mem.Allocator) Selection {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Selection) void {
    self.allocator.free(self.cells);
    self.uris.deinit(self.allocator);
    self.regions.deinit(self.allocator);
}

pub fn isActive(self: *const Selection) bool {
    return self.anchor != null and self.head != null;
}

pub fn clear(self: *Selection) void {
    self.anchor = null;
    self.head = null;
    self.dragging = false;
    self.area = .everything;
}

/// Forget last frame's regions, before drawing the next.
pub fn resetRegions(self: *Selection) void {
    self.regions.clearRetainingCapacity();
}

/// Record a region drawn above every one recorded before it this frame.
pub fn addRegion(self: *Selection, region: ?Rect) !void {
    try self.regions.append(self.allocator, region orelse return);
}

/// Start a selection at `point`, confined to the topmost region under it.
/// Returns false, selecting nothing, where no region was drawn.
pub fn begin(self: *Selection, point: Point) bool {
    var i = self.regions.items.len;
    const area = while (i > 0) {
        i -= 1;
        if (self.regions.items[i].holds(point)) break self.regions.items[i];
    } else return false;
    self.area = area;
    self.anchor = point;
    self.head = point;
    self.dragging = true;
    return true;
}

/// Move the selection's free end to `point`, held inside the region it started
/// in however far the pointer strays.
pub fn extend(self: *Selection, point: Point) void {
    if (self.anchor == null) return;
    self.head = self.area.clamp(point);
}

pub fn end(self: *Selection) void {
    self.dragging = false;
    if (self.anchor) |anchor| {
        if (self.head) |head| {
            if (anchor.row == head.row and anchor.col == head.col) self.clear();
        }
    }
}

pub const Bounds = struct { start: Point, end: Point };

/// Selection bounds in draw order, regardless of drag direction.
pub fn range(self: *const Selection) ?Bounds {
    const anchor = self.anchor orelse return null;
    const head = self.head orelse return null;
    return if (anchor.beforeOrEqual(head))
        .{ .start = anchor, .end = head }
    else
        .{ .start = head, .end = anchor };
}

/// Whether a cell falls inside the selection. Selection is linear, like a text
/// editor, not rectangular: full rows between the endpoints are included.
pub fn contains(self: *const Selection, row: u16, col: u16) bool {
    const bounds = self.range() orelse return false;
    if (col < self.area.left or col > self.area.right) return false;
    if (row < bounds.start.row or row > bounds.end.row) return false;
    if (row == bounds.start.row and col < bounds.start.col) return false;
    if (row == bounds.end.row and col > bounds.end.col) return false;
    return true;
}

/// The columns of `row` worth highlighting: the selected range, clamped to the
/// pane, hugging the text on both sides. Highlighting the padding a card drew
/// makes the selection look like a block of colour rather than like selected
/// text.
pub fn rowSpan(self: *const Selection, row: u16) ?struct { from: u16, to: u16 } {
    const bounds = self.range() orelse return null;
    if (row < bounds.start.row or row > bounds.end.row or row >= self.height) return null;

    const limit = self.rowLimit(bounds, row);
    var from: u16 = if (row == bounds.start.row)
        @max(self.area.left, bounds.start.col)
    else
        self.bodyLeft(bounds);
    if (from <= limit and self.gridCell(row, from).decoration) {
        while (from <= limit and self.gridCell(row, from).isChrome()) from += 1;
    }
    if (from > limit) return null;

    var last: ?u16 = null;
    var col = from;
    while (col <= limit) : (col += 1) {
        if (!self.gridCell(row, col).isChrome()) last = col;
    }

    return .{ .from = from, .to = last orelse return null };
}

/// The last column of `row` the selection could reach.
fn rowLimit(self: *const Selection, bounds: Bounds, row: u16) u16 {
    return @min(
        self.area.right,
        if (row == bounds.end.row) @min(bounds.end.col, self.width -| 1) else self.width -| 1,
    );
}

/// The column the selected block's text starts at: the leftmost cell holding
/// anything, across every row but the first.
fn bodyLeft(self: *const Selection, bounds: Bounds) u16 {
    var shared: ?u16 = null;

    var row = bounds.start.row +| 1;
    while (row <= bounds.end.row and row < self.height) : (row += 1) {
        const limit = self.rowLimit(bounds, row);
        var col = self.area.left;
        while (col <= limit and col < self.width) : (col += 1) {
            if (self.gridCell(row, col).isChrome()) continue;
            shared = @min(shared orelse col, col);
            break;
        }
    }

    return shared orelse self.area.left;
}

/// Whether the selected part of `row` is drawn decoration and nothing else, like
/// the line under a table's header: it copies as no line at all.
fn isRuleRow(self: *const Selection, bounds: Bounds, row: u16) bool {
    var col = if (row == bounds.start.row) @max(self.area.left, bounds.start.col) else self.bodyLeft(bounds);
    const limit = self.rowLimit(bounds, row);
    while (col <= limit) : (col += 1) {
        if (self.gridCell(row, col).decoration) return true;
    }
    return false;
}

fn gridCell(self: *const Selection, row: u16, col: u16) *const GridCell {
    return &self.cells[@as(usize, row) * self.width + col];
}

/// Copy the composited frame into the grid. Called at the end of `draw`, with
/// the tree the model is about to return.
pub fn capture(self: *Selection, surface: vxfw.Surface) !void {
    const size = surface.size;
    if (size.width != self.width or size.height != self.height) {
        self.allocator.free(self.cells);
        self.cells = try self.allocator.alloc(GridCell, @as(usize, size.width) * size.height);
        self.width = size.width;
        self.height = size.height;
        self.clear();
    }
    @memset(self.cells, .{});
    self.uris.clearRetainingCapacity();

    self.blit(surface, 0, 0);
}

/// The link under a cell, or null. Empty for anything the frame drew over.
pub fn linkAt(self: *const Selection, row: u16, col: u16) ?[]const u8 {
    if (row >= self.height or col >= self.width) return null;
    const index = self.cells[@as(usize, row) * self.width + col].link;
    if (index == 0) return null;
    return self.uris.items[index - 1];
}

/// Walk the tree the same way the renderer does, newest child winning.
fn blit(self: *Selection, surface: vxfw.Surface, row_off: i32, col_off: i32) void {
    if (surface.buffer.len > 0) {
        for (surface.buffer, 0..) |cell, i| {
            const row = row_off + @as(i32, @intCast(i / surface.size.width));
            const col = col_off + @as(i32, @intCast(i % surface.size.width));
            self.put(row, col, cell.char.grapheme, cell.link.uri);
        }
    }
    for (surface.children) |child| {
        self.blit(child.surface, row_off + child.origin.row, col_off + child.origin.col);
    }
}

fn put(self: *Selection, row: i32, col: i32, grapheme: []const u8, uri: []const u8) void {
    if (row < 0 or col < 0) return;
    if (row >= self.height or col >= self.width) return;

    const index = @as(usize, @intCast(row)) * self.width + @as(usize, @intCast(col));
    const len = @min(grapheme.len, cell_bytes);
    var put_cell: GridCell = .{
        .len = @intCast(len),
        .link = self.uriIndex(uri),
        .decoration = w.isDecoration(grapheme),
    };
    @memcpy(put_cell.bytes[0..len], grapheme[0..len]);
    self.cells[index] = put_cell;
}

/// The one-based index of `uri` in `uris`, adding it if this is the first cell
/// of the run. A link covers many cells in a row, so the last entry is checked
/// first and the list stays as short as the number of links on screen.
fn uriIndex(self: *Selection, uri: []const u8) u16 {
    if (uri.len == 0) return 0;
    if (self.uris.items.len > 0) {
        const last = self.uris.items[self.uris.items.len - 1];
        if (last.ptr == uri.ptr and last.len == uri.len) return @intCast(self.uris.items.len);
    }
    if (self.uris.items.len >= std.math.maxInt(u16)) return 0;
    self.uris.append(self.allocator, uri) catch return 0;
    return @intCast(self.uris.items.len);
}

/// Whether a cell holds decoration, which a highlight leaves as drawn.
pub fn isDecorationAt(self: *const Selection, row: u16, col: u16) bool {
    if (row >= self.height or col >= self.width) return false;
    return self.gridCell(row, col).decoration;
}

/// The grapheme at a cell, or empty when out of range or decoration. Borrowed
/// from the grid, which lives until the next capture.
pub fn cellText(self: *const Selection, row: u16, col: u16) []const u8 {
    if (row >= self.height or col >= self.width) return "";
    const at = self.gridCell(row, col);
    return if (at.decoration) "" else at.slice();
}

/// The selected text, with trailing blanks trimmed from each row. Caller owns
/// the result; returns null when nothing is selected.
pub fn text(self: *const Selection, allocator: std.mem.Allocator) !?[]u8 {
    const bounds = self.range() orelse return null;
    if (self.cells.len == 0) return null;

    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var rows: std.ArrayList([]const u8) = .empty;

    var row = bounds.start.row;
    while (row <= bounds.end.row and row < self.height) : (row += 1) {
        const span = self.rowSpan(row) orelse {
            if (!self.isRuleRow(bounds, row)) try rows.append(arena, "");
            continue;
        };

        var line: std.Io.Writer.Allocating = .init(arena);
        var col = span.from;
        while (col <= span.to) : (col += 1) {
            const bytes = self.cellText(row, col);
            try line.writer.writeAll(if (bytes.len == 0) " " else bytes);
        }
        try rows.append(arena, line.written());
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (rows.items, 0..) |line, i| {
        if (i > 0) try out.writer.writeByte('\n');
        try out.writer.writeAll(line);
    }
    return try out.toOwnedSlice();
}

test "linear selection spans whole rows between endpoints" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    selection.cells = try std.testing.allocator.alloc(GridCell, 12);
    @memset(selection.cells, .{});
    selection.width = 4;
    selection.height = 3;

    try selection.addRegion(.everything);
    try std.testing.expect(selection.begin(.{ .row = 0, .col = 2 }));
    selection.extend(.{ .row = 2, .col = 1 });

    try std.testing.expect(!selection.contains(0, 1));
    try std.testing.expect(selection.contains(0, 3));
    try std.testing.expect(selection.contains(1, 0));
    try std.testing.expect(selection.contains(1, 3));
    try std.testing.expect(selection.contains(2, 1));
    try std.testing.expect(!selection.contains(2, 2));
}

test "dragging backwards selects the same range" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    try selection.addRegion(.everything);
    try std.testing.expect(selection.begin(.{ .row = 2, .col = 1 }));
    selection.extend(.{ .row = 0, .col = 2 });

    const bounds = selection.range().?;
    try std.testing.expectEqual(@as(u16, 0), bounds.start.row);
    try std.testing.expectEqual(@as(u16, 2), bounds.end.row);
}

test "text trims the padding panels draw" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    selection.cells = try std.testing.allocator.alloc(GridCell, 8);
    @memset(selection.cells, .{});
    selection.width = 4;
    selection.height = 2;

    for ("hi  ", 0..) |c, i| selection.put(0, @intCast(i), &.{c}, "");
    for ("yo  ", 0..) |c, i| selection.put(1, @intCast(i), &.{c}, "");

    try selection.addRegion(.everything);
    try std.testing.expect(selection.begin(.{ .row = 0, .col = 0 }));
    selection.extend(.{ .row = 1, .col = 3 });

    const copied = (try selection.text(std.testing.allocator)).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("hi\nyo", copied);
}

test "a click without movement selects nothing" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    try selection.addRegion(.everything);
    try std.testing.expect(selection.begin(.{ .row = 1, .col = 1 }));
    selection.end();
    try std.testing.expect(!selection.isActive());
}

test "a selection stays inside the pane it started in" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    selection.cells = try std.testing.allocator.alloc(GridCell, 20);
    @memset(selection.cells, .{});
    selection.width = 10;
    selection.height = 2;

    for ("abcd", 0..) |c, i| selection.put(0, @intCast(i), &.{c}, "");
    for ("SIDE", 0..) |c, i| selection.put(0, @intCast(6 + i), &.{c}, "");
    for ("efgh", 0..) |c, i| selection.put(1, @intCast(i), &.{c}, "");

    try selection.addRegion(.{ .top = 0, .left = 0, .bottom = 1, .right = 4 });
    try selection.addRegion(.{ .top = 0, .left = 5, .bottom = 1, .right = 9 });
    try std.testing.expect(selection.begin(.{ .row = 0, .col = 0 }));
    selection.extend(.{ .row = 1, .col = 7 });

    try std.testing.expect(selection.contains(0, 3));
    try std.testing.expect(!selection.contains(0, 7));

    const copied = (try selection.text(std.testing.allocator)).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("abcd\nefgh", copied);
}

test "copied rows lose the chrome they share, not their own indentation" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    selection.cells = try std.testing.allocator.alloc(GridCell, 60);
    @memset(selection.cells, .{});
    selection.width = 20;
    selection.height = 3;

    for ("    const std = x;", 0..) |c, i| selection.put(0, @intCast(i), &.{c}, "");
    for ("    pub fn main() {", 0..) |c, i| selection.put(1, @intCast(i), &.{c}, "");
    for ("        print();", 0..) |c, i| selection.put(2, @intCast(i), &.{c}, "");

    try selection.addRegion(.everything);
    try std.testing.expect(selection.begin(.{ .row = 0, .col = 4 }));
    selection.extend(.{ .row = 2, .col = 19 });

    const copied = (try selection.text(std.testing.allocator)).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("const std = x;\npub fn main() {\n    print();", copied);
}

test "rows after the first hug the text, not the pane" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    selection.cells = try std.testing.allocator.alloc(GridCell, 60);
    @memset(selection.cells, .{});
    selection.width = 20;
    selection.height = 3;

    for ("    pub fn main() {", 0..) |c, i| selection.put(0, @intCast(i), &.{c}, "");
    for ("        print();", 0..) |c, i| selection.put(1, @intCast(i), &.{c}, "");
    for ("    }", 0..) |c, i| selection.put(2, @intCast(i), &.{c}, "");

    try selection.addRegion(.everything);
    try std.testing.expect(selection.begin(.{ .row = 0, .col = 4 }));
    selection.extend(.{ .row = 2, .col = 19 });

    try std.testing.expectEqual(@as(u16, 4), selection.rowSpan(0).?.from);
    try std.testing.expectEqual(@as(u16, 4), selection.rowSpan(1).?.from);
    try std.testing.expectEqual(@as(u16, 4), selection.rowSpan(2).?.from);
    try std.testing.expectEqual(@as(u16, 18), selection.rowSpan(0).?.to);

    const copied = (try selection.text(std.testing.allocator)).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("pub fn main() {\n    print();\n}", copied);
}

test "a card's bar is chrome, not the start of the text" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    selection.cells = try std.testing.allocator.alloc(GridCell, 40);
    @memset(selection.cells, .{});
    selection.width = 20;
    selection.height = 2;

    selection.put(0, 0, w.block_rule, "");
    for ("  first line", 0..) |c, i| selection.put(0, @intCast(2 + i), &.{c}, "");
    selection.put(1, 0, w.block_rule, "");
    for ("  second line", 0..) |c, i| selection.put(1, @intCast(2 + i), &.{c}, "");

    try selection.addRegion(.everything);
    try std.testing.expect(selection.begin(.{ .row = 0, .col = 4 }));
    selection.extend(.{ .row = 1, .col = 19 });

    const copied = (try selection.text(std.testing.allocator)).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("first line\nsecond line", copied);
}

test "the grid remembers what a cell links to" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    const Dummy = struct {
        fn drawFn(_: *anyopaque, _: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
            unreachable;
        }
    };
    var userdata: u8 = 0;
    const widget: vxfw.Widget = .{ .userdata = &userdata, .drawFn = Dummy.drawFn };

    var buffer: [4]vaxis.Cell = undefined;
    for (&buffer, "abcd", 0..) |*cell, c, i| {
        cell.* = .{
            .char = .{ .grapheme = ([_][]const u8{ "a", "b", "c", "d" })[i], .width = 1 },
            .link = .{ .uri = if (c == 'c' or c == 'd') "https://example.com" else "" },
        };
    }
    const surface: vxfw.Surface = .{
        .size = .{ .width = 4, .height = 1 },
        .widget = widget,
        .buffer = &buffer,
        .children = &.{},
    };

    try selection.capture(surface);

    try std.testing.expect(selection.linkAt(0, 0) == null);
    try std.testing.expectEqualStrings("https://example.com", selection.linkAt(0, 2).?);
    try std.testing.expectEqualStrings("https://example.com", selection.linkAt(0, 3).?);
    try std.testing.expectEqual(@as(usize, 1), selection.uris.items.len);
    try std.testing.expect(selection.linkAt(9, 9) == null);

    var cover: [2]vaxis.Cell = @splat(.{ .char = .{ .grapheme = "x", .width = 1 } });
    const child: vxfw.Surface = .{
        .size = .{ .width = 2, .height = 1 },
        .widget = widget,
        .buffer = &cover,
        .children = &.{},
    };
    var children = [_]vxfw.SubSurface{.{ .origin = .{ .row = 0, .col = 2 }, .surface = child }};
    var covered = surface;
    covered.children = &children;

    try selection.capture(covered);
    try std.testing.expect(selection.linkAt(0, 2) == null);
}

test "decoration between and around text is neither highlighted nor copied" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    selection.cells = try std.testing.allocator.alloc(GridCell, 60);
    @memset(selection.cells, .{});
    selection.width = 20;
    selection.height = 3;

    const message = "\u{2502} quoted";
    selection.put(0, 0, w.solid_rule, "");
    for ("Total", 0..) |c, i| selection.put(0, @intCast(2 + i), &.{c}, "");
    selection.put(0, 8, w.solid_rule, "");
    for ("$2,410", 0..) |c, i| selection.put(0, @intCast(9 + i), &.{c}, "");
    selection.put(1, 0, w.solid_rule, "");
    for (0..10) |i| selection.put(1, @intCast(2 + i), w.decoration("\u{2500}"), "");
    selection.put(2, 0, w.solid_rule, "");
    selection.put(2, 2, message[0..3], "");
    for (" quoted", 0..) |c, i| selection.put(2, @intCast(3 + i), &.{c}, "");

    try selection.addRegion(.everything);
    try std.testing.expect(selection.begin(.{ .row = 0, .col = 0 }));
    selection.extend(.{ .row = 2, .col = 19 });

    try std.testing.expectEqual(@as(u16, 2), selection.rowSpan(0).?.from);
    try std.testing.expect(selection.rowSpan(1) == null);

    const copied = (try selection.text(std.testing.allocator)).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("Total  $2,410\n\u{2502} quoted", copied);
}

test "a blank line inside a barred block still copies as a blank line" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    selection.cells = try std.testing.allocator.alloc(GridCell, 30);
    @memset(selection.cells, .{});
    selection.width = 10;
    selection.height = 3;

    for (0..3) |row| selection.put(@intCast(row), 0, w.solid_rule, "");
    for ("one", 0..) |c, i| selection.put(0, @intCast(2 + i), &.{c}, "");
    for ("two", 0..) |c, i| selection.put(2, @intCast(2 + i), &.{c}, "");

    try selection.addRegion(.everything);
    try std.testing.expect(selection.begin(.{ .row = 0, .col = 0 }));
    selection.extend(.{ .row = 2, .col = 9 });

    const copied = (try selection.text(std.testing.allocator)).?;
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("one\n\ntwo", copied);
}

test "a drag starts only where a region was drawn, and never leaves it" {
    var selection: Selection = .init(std.testing.allocator);
    defer selection.deinit();

    try selection.addRegion(Rect.sized(2, 2, 5, 10));
    try selection.addRegion(Rect.sized(4, 4, 2, 3));

    try std.testing.expect(!selection.begin(.{ .row = 0, .col = 0 }));
    try std.testing.expect(!selection.isActive());

    try std.testing.expect(selection.begin(.{ .row = 4, .col = 5 }));
    selection.extend(.{ .row = 20, .col = 0 });
    try std.testing.expectEqual(Point{ .row = 5, .col = 4 }, selection.head.?);

    selection.clear();
    try std.testing.expect(selection.begin(.{ .row = 2, .col = 3 }));
    selection.extend(.{ .row = 0, .col = 30 });
    try std.testing.expectEqual(Point{ .row = 2, .col = 11 }, selection.head.?);
}

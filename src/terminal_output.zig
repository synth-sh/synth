const std = @import("std");

pub const dim = "\x1b[2m";
pub const bold = "\x1b[1m";
pub const reset = "\x1b[0m";

pub fn writeTranscriptLine(out: *std.Io.Writer, label: []const u8, text: []const u8) !void {
    try out.print(bold ++ "▸ {s}" ++ reset ++ " {s}\n", .{ label, text });
}

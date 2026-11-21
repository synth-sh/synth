const std = @import("std");
const paths = @import("paths.zig");

const plugin_data_suffix = "/" ++ paths.synth_config_dir ++ "/plugin-data";
const directory_variables = [_]struct { name: []const u8, suffix: []const u8 = "" }{
    .{ .name = "SYNTH_PROJECT_DIR" },
    .{ .name = "CLAUDE_PROJECT_DIR" },
    .{ .name = "CLAUDE_PLUGIN_ROOT" },
    .{ .name = "PLUGIN_ROOT" },
    .{ .name = "CLAUDE_PLUGIN_DATA", .suffix = plugin_data_suffix },
    .{ .name = "PLUGIN_DATA", .suffix = plugin_data_suffix },
};

pub fn environment(a: std.mem.Allocator, root: []const u8) ![directory_variables.len][]const u8 {
    var entries: [directory_variables.len][]const u8 = undefined;
    for (directory_variables, &entries) |variable, *entry| {
        entry.* = try std.fmt.allocPrint(a, "{s}={s}{s}", .{ variable.name, root, variable.suffix });
    }
    return entries;
}

pub fn expandDirectories(a: std.mem.Allocator, word: []const u8, root: []const u8) ![]const u8 {
    var expanded = word;
    inline for (directory_variables) |variable| {
        const braced = "${" ++ variable.name ++ "}";
        const bare = "$" ++ variable.name;
        if (std.mem.indexOf(u8, expanded, braced) != null or std.mem.indexOf(u8, expanded, bare) != null) {
            const directory = if (variable.suffix.len == 0) root else try std.fmt.allocPrint(a, "{s}{s}", .{ root, variable.suffix });
            if (std.mem.indexOf(u8, expanded, braced) != null) expanded = try std.mem.replaceOwned(u8, a, expanded, braced, directory);
            if (std.mem.indexOf(u8, expanded, bare) != null) expanded = try std.mem.replaceOwned(u8, a, expanded, bare, directory);
        }
    }
    return expanded;
}

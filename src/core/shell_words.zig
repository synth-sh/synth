const std = @import("std");

/// Split a segment's arguments on whitespace, keeping quoted runs whole.
pub fn arguments(text: []const u8) ArgumentIterator {
    return .{ .text = text };
}

pub fn commandWords(text: []const u8) ArgumentIterator {
    return .{ .text = text, .operators = true };
}

pub const ArgumentIterator = struct {
    text: []const u8,
    at: usize = 0,
    operators: bool = false,

    fn separator(self: *const ArgumentIterator, c: u8) bool {
        return isSpace(c) or (self.operators and std.mem.indexOfScalar(u8, ";&|<>()", c) != null);
    }

    pub fn next(self: *ArgumentIterator) ?[]const u8 {
        while (self.at < self.text.len) {
            if (self.separator(self.text[self.at])) {
                self.at += 1;
            } else if (self.operators and self.text[self.at] == '#') {
                self.at = std.mem.indexOfScalarPos(u8, self.text, self.at, '\n') orelse self.text.len;
            } else break;
        }
        if (self.at >= self.text.len) return null;

        const start = self.at;
        while (self.at < self.text.len and !self.separator(self.text[self.at])) {
            const c = self.text[self.at];
            if (self.operators and c == '\\') {
                self.at += @min(2, self.text.len - self.at);
                continue;
            }
            if (c == '\'' or c == '"') {
                self.at = scanQuoted(self.text, self.at, !self.operators) orelse self.text.len;
                continue;
            }
            self.at += 1;
        }
        return self.text[start..self.at];
    }
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// Step over a quoted run, returning the index just past the closing quote.
/// Null for an unterminated quote, or for a substitution inside a double-quoted
/// string, which the caller treats as un-splittable.
pub fn skipQuoted(command: []const u8, at: usize) ?usize {
    return scanQuoted(command, at, true);
}

fn scanQuoted(command: []const u8, at: usize, reject_substitution: bool) ?usize {
    const quote = command[at];
    var i = at + 1;
    while (i < command.len) : (i += 1) {
        if (quote == '"') {
            if (command[i] == '\\') {
                i += 1;
                continue;
            }
            if (reject_substitution) {
                if (command[i] == '`') return null;
                if (command[i] == '$' and i + 1 < command.len and command[i + 1] == '(') return null;
            }
        }
        if (command[i] == quote) return i + 1;
    }
    return null;
}

pub const Variable = struct { name: []const u8, value: []const u8 };

fn variableValue(variables: []const Variable, name: []const u8) ?[]const u8 {
    for (variables) |variable| {
        if (std.mem.eql(u8, variable.name, name)) return variable.value;
    }
    return null;
}

fn variableName(raw: []const u8, index: *usize) ?[]const u8 {
    const tail = raw[index.* + 1 ..];
    if (std.mem.cutPrefix(u8, tail, "{")) |content| {
        const end = std.mem.indexOfScalar(u8, content, '}') orelse return null;
        index.* += end + "${}".len - 1;
        return content[0..end];
    }
    var end: usize = 0;
    while (end < tail.len and (std.ascii.isAlphanumeric(tail[end]) or tail[end] == '_')) : (end += 1) {}
    if (end == 0) return null;
    index.* += end;
    return tail[0..end];
}

pub fn literalWord(arena: std.mem.Allocator, raw: []const u8, variables: []const Variable) !?[]const u8 {
    const pathname_patterns = "*?[{}";
    const split_or_glob = " \t\n*?[";
    if (std.mem.indexOfAny(u8, raw, "~\\'\"$`" ++ pathname_patterns) == null) return raw;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);
    var quote: u8 = 0;
    var i: usize = 0;
    if (std.mem.startsWith(u8, raw, "~/")) {
        try out.appendSlice(arena, variableValue(variables, "HOME") orelse return null);
        i = 1;
    }

    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '\\' and quote != '\'') {
            if (i + 1 == raw.len) return null;
            const next = raw[i + 1];
            if (quote == '"' and std.mem.indexOfScalar(u8, "$`\"\\\n", next) == null) {
                try out.append(arena, c);
                continue;
            }
            i += 1;
            if (next != '\n') try out.append(arena, next);
        } else if ((c == '\'' or c == '"') and (quote == 0 or quote == c)) {
            quote = if (quote == c) 0 else c;
        } else if (c == '$' and quote != '\'') {
            const name = variableName(raw, &i) orelse return null;
            const value = variableValue(variables, name) orelse return null;
            if (quote == 0 and std.mem.indexOfAny(u8, value, split_or_glob) != null) return null;
            try out.appendSlice(arena, value);
        } else {
            if (c == '`' and quote != '\'') return null;
            if (quote == 0 and std.mem.indexOfScalar(u8, pathname_patterns, c) != null) return null;
            try out.append(arena, c);
        }
    }
    if (quote != 0) return null;
    return try out.toOwnedSlice(arena);
}

//! Helpers for the game's text formats (CRLF, `key=value`, number lists).

const std = @import("std");

pub const Error = error{BadSyntax};

/// Line iterator without `\r` and surrounding spaces.
pub const Lines = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    /// Number of the last returned line (from 1), for error messages.
    line_no: usize = 0,

    pub fn init(text: []const u8) Lines {
        return .{ .it = std.mem.splitScalar(u8, text, '\n') };
    }

    /// Next line, empty ones included.
    pub fn next(self: *Lines) ?[]const u8 {
        const raw = self.it.next() orelse return null;
        self.line_no += 1;
        return std.mem.trim(u8, raw, " \t\r");
    }

    /// Next non-empty line.
    pub fn nextNonEmpty(self: *Lines) ?[]const u8 {
        while (self.next()) |l| if (l.len > 0) return l;
        return null;
    }

    /// Next non-empty line that must start with `prefix`; returns the rest.
    pub fn expect(self: *Lines, prefix: []const u8) Error![]const u8 {
        const l = self.nextNonEmpty() orelse return error.BadSyntax;
        if (!std.mem.startsWith(u8, l, prefix)) return error.BadSyntax;
        return std.mem.trim(u8, l[prefix.len..], " \t");
    }

    pub fn expectInt(self: *Lines, comptime T: type, prefix: []const u8) Error!T {
        return parseInt(T, try self.expect(prefix));
    }

    /// Record count: each record takes at least a byte, so more than the file
    /// length is garbage (otherwise 4 billion from a header goes to gpa.alloc).
    pub fn expectCount(self: *Lines, prefix: []const u8) Error!u32 {
        const n = try self.expectInt(u32, prefix);
        if (n > self.it.buffer.len) return error.BadSyntax;
        return n;
    }

    pub fn expectFloat(self: *Lines, prefix: []const u8) Error!f32 {
        return parseFloat(try self.expect(prefix));
    }
};

/// `key=value`: key trimmed, value as is (the line is already trimmed by
/// `Lines`); null without `=`.
pub fn keyValue(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    return .{ .key = std.mem.trim(u8, line[0..eq], " \t"), .value = line[eq + 1 ..] };
}

fn parseInt(comptime T: type, s: []const u8) Error!T {
    return std.fmt.parseInt(T, std.mem.trim(u8, s, " \t"), 10) catch error.BadSyntax;
}

fn parseFloat(s: []const u8) Error!f32 {
    return std.fmt.parseFloat(f32, std.mem.trim(u8, s, " \t")) catch error.BadSyntax;
}

/// Exactly `n` numbers separated by any of `seps`.
pub fn floats(comptime n: usize, s: []const u8, seps: []const u8) Error![n]f32 {
    var out: [n]f32 = undefined;
    var it = std.mem.tokenizeAny(u8, s, seps);
    for (&out) |*v| v.* = try parseFloat(it.next() orelse return error.BadSyntax);
    if (it.next() != null) return error.BadSyntax;
    return out;
}

/// From `min` to `out.len` numbers; returns the count.
pub fn floatsUpTo(out: []f32, min: usize, s: []const u8, seps: []const u8) Error!usize {
    var it = std.mem.tokenizeAny(u8, s, seps);
    var n: usize = 0;
    while (it.next()) |tok| : (n += 1) {
        if (n == out.len) return error.BadSyntax;
        out[n] = try parseFloat(tok);
    }
    if (n < min) return error.BadSyntax;
    return n;
}

/// Value of field `name NUMBERS` in a line like `pos: 1,2,3, color: 1,1,1, range: 5`:
/// everything after `name` up to the next field with a colon.
pub fn field(line: []const u8, name: []const u8) Error![]const u8 {
    const start = (std.mem.indexOf(u8, line, name) orelse return error.BadSyntax) + name.len;
    const rest = line[start..];
    const end = std.mem.indexOfScalar(u8, rest, ':') orelse return rest;
    // Step back to the start of the next field's name.
    var e = end;
    while (e > 0 and std.ascii.isAlphabetic(rest[e - 1])) e -= 1;
    return rest[0..e];
}

test Lines {
    var l: Lines = .init("a=1\r\n\r\n  b: x \r\n");
    try std.testing.expectEqual(1, try l.expectInt(u32, "a="));
    try std.testing.expectEqualStrings("x", try l.expect("b:"));
    try std.testing.expectEqual(null, l.nextNonEmpty());
}

test field {
    const line = "pos: 1.5,-2,3, color: 1,0.5,0, range: 167.3";
    try std.testing.expectEqual([3]f32{ 1.5, -2, 3 }, try floats(3, try field(line, "pos:"), ", "));
    try std.testing.expectEqual([3]f32{ 1, 0.5, 0 }, try floats(3, try field(line, "color:"), ", "));
    try std.testing.expectEqual([1]f32{167.3}, try floats(1, try field(line, "range:"), ", "));
}

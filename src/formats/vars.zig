//! Initial object variable values (`common/other.dat: variables\<object>.var`).
//! Text: `name=value` lines, CRLF. Values are unquoted; `(null)` is an empty string.

const std = @import("std");
const text_mod = @import("text.zig");
const Allocator = std.mem.Allocator;

const Vars = struct {
    /// Keys and values point into the source text.
    entries: []Entry,

    const Entry = struct { key: []const u8, value: []const u8 };

    pub fn deinit(self: *Vars, gpa: Allocator) void {
        gpa.free(self.entries);
        self.* = undefined;
    }
};

pub fn parse(gpa: Allocator, text: []const u8) Allocator.Error!Vars {
    var list: std.ArrayList(Vars.Entry) = .empty;
    errdefer list.deinit(gpa);
    var lines: text_mod.Lines = .init(text);
    while (lines.next()) |line| {
        const kv = text_mod.keyValue(line) orelse continue;
        try list.append(gpa, .{ .key = kv.key, .value = std.mem.trim(u8, kv.value, " \t") });
    }
    return .{ .entries = try list.toOwnedSlice(gpa) };
}

test parse {
    const gpa = std.testing.allocator;
    var v = try parse(gpa, "nameID=0\r\npos_x= 664 \r\nzbufFile=(null)\r\n");
    defer v.deinit(gpa);
    try std.testing.expectEqual(3, v.entries.len);
    try std.testing.expectEqualStrings("pos_x", v.entries[1].key);
    try std.testing.expectEqualStrings("664", v.entries[1].value);
    try std.testing.expectEqualStrings("(null)", v.entries[2].value);
}

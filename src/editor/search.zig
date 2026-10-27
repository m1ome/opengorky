//! Search in lists: case-insensitive substring match on UTF-8 text, Latin and
//! Cyrillic letters folded (game names are in either).

const std = @import("std");

fn fold(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 32,
        0x410...0x42f => cp + 0x20,
        0x401 => 0x451,
        else => cp,
    };
}

fn decode(s: []const u8, out: []u21) []u21 {
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(s) catch return out[0..0]).iterator();
    while (it.nextCodepoint()) |cp| {
        if (n == out.len) break;
        out[n] = fold(cp);
        n += 1;
    }
    return out[0..n];
}

/// `query` (trimmed) occurs in any of `fields`; an empty query matches everything.
pub fn matches(query: []const u8, fields: []const []const u8) bool {
    const q_raw = std.mem.trim(u8, query, " ");
    if (q_raw.len == 0) return true;
    var qb: [64]u21 = undefined;
    const q = decode(q_raw, &qb);
    for (fields) |f| {
        var fb: [256]u21 = undefined;
        if (std.mem.indexOf(u21, decode(f, &fb), q) != null) return true;
    }
    return false;
}

/// `s` without its last UTF-8 character.
pub fn dropLast(s: []const u8) []const u8 {
    var n = s.len;
    while (n > 0) {
        n -= 1;
        if (s[n] & 0xc0 != 0x80) break;
    }
    return s[0..n];
}

test "search: id and translated name, any case" {
    try std.testing.expect(matches("STILL", &.{ "Кинжал", "stilleto" }));
    try std.testing.expect(matches("кинж", &.{ "Кинжал", "stilleto" }));
    try std.testing.expect(matches("ЖИРАФ", &.{ "garcia", "Жираф" }));
    try std.testing.expect(!matches("axe", &.{ "Кинжал", "stilleto" }));
    try std.testing.expect(matches(" ", &.{"x"}));
    try std.testing.expectEqualStrings("Ки", dropLast("Кин"));
}

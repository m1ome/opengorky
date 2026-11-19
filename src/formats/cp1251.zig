//! Windows-1251 (the Polish edition's: Windows-1250), the game's 8-bit text (its fonts' glyph
//! order), and UTF-8, an OpenGorky project's: the converter writes UTF-8, the OG reader hands
//! the core the font's bytes back (a subtitle's time and its glyphs count bytes, as in the exe).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Page = enum { cp1251, cp1250 };

/// The code page of language number `n` (manifest.languageNumber: 2 Polish).
pub fn forLanguage(n: u8) Page {
    return if (n == 2) .cp1250 else .cp1251;
}

fn table(p: Page) *const [128]u21 {
    return switch (p) {
        .cp1251 => &high,
        .cp1250 => &high1250,
    };
}

/// Windows-1250 0x80…0xFF as code points (an undefined byte as U+0080…U+00FF, itself).
const high1250 = [128]u21{
    0x20AC, 0x0081, 0x201A, 0x0083, 0x201E, 0x2026, 0x2020, 0x2021, 0x0088, 0x2030, 0x0160, 0x2039, 0x015A, 0x0164, 0x017D, 0x0179,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x0098, 0x2122, 0x0161, 0x203A, 0x015B, 0x0165, 0x017E, 0x017A,
    0x00A0, 0x02C7, 0x02D8, 0x0141, 0x00A4, 0x0104, 0x00A6, 0x00A7, 0x00A8, 0x00A9, 0x015E, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x017B,
    0x00B0, 0x00B1, 0x02DB, 0x0142, 0x00B4, 0x00B5, 0x00B6, 0x00B7, 0x00B8, 0x0105, 0x015F, 0x00BB, 0x013D, 0x02DD, 0x013E, 0x017C,
    0x0154, 0x00C1, 0x00C2, 0x0102, 0x00C4, 0x0139, 0x0106, 0x00C7, 0x010C, 0x00C9, 0x0118, 0x00CB, 0x011A, 0x00CD, 0x00CE, 0x010E,
    0x0110, 0x0143, 0x0147, 0x00D3, 0x00D4, 0x0150, 0x00D6, 0x00D7, 0x0158, 0x016E, 0x00DA, 0x0170, 0x00DC, 0x00DD, 0x0162, 0x00DF,
    0x0155, 0x00E1, 0x00E2, 0x0103, 0x00E4, 0x013A, 0x0107, 0x00E7, 0x010D, 0x00E9, 0x0119, 0x00EB, 0x011B, 0x00ED, 0x00EE, 0x010F,
    0x0111, 0x0144, 0x0148, 0x00F3, 0x00F4, 0x0151, 0x00F6, 0x00F7, 0x0159, 0x016F, 0x00FA, 0x0171, 0x00FC, 0x00FD, 0x0163, 0x02D9,
};

/// 0x80…0xFF as code points (0x98, undefined there, as U+FFFD).
const high = [64]u21{
    0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, 0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
    0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0xFFFD, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
    0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7, 0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
    0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7, 0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
} ++ blk: {
    var t: [64]u21 = undefined;
    for (&t, 0..) |*x, i| x.* = 0x0410 + i;
    break :blk t;
};

fn ascii(s: []const u8) bool {
    for (s) |ch| if (ch >= 0x80) return false;
    return true;
}

/// `s` (in `p`) as UTF-8, in `a`; ASCII is itself.
pub fn toUtf8(a: Allocator, s: []const u8, p: Page) Allocator.Error![]const u8 {
    if (ascii(s)) return s;
    const t = table(p);
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        if (ch < 0x80) {
            try out.append(a, ch);
            continue;
        }
        var b: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(t[ch - 0x80], &b) catch unreachable;
        try out.appendSlice(a, b[0..n]);
    }
    return out.items;
}

/// `s` (UTF-8) in `p`, in `a`: a character it has no byte for is `?`, bytes that are no
/// UTF-8 stay as they are.
pub fn fromUtf8(a: Allocator, s: []const u8, p: Page) Allocator.Error![]const u8 {
    if (ascii(s)) return s;
    const view = std.unicode.Utf8View.init(s) catch return s;
    const t = table(p);
    var out: std.ArrayList(u8) = .empty;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x80) {
            try out.append(a, @intCast(cp));
            continue;
        }
        const k = std.mem.indexOfScalar(u21, t, cp);
        try out.append(a, if (k) |i| @intCast(0x80 + i) else '?');
    }
    return out.items;
}

test "cp1251 to UTF-8 and back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = "\xcf\xf0\xe8\xe2\xe5\xf2, \xa8\xe6 \x85";
    try std.testing.expectEqualStrings("Привет, Ёж …", try toUtf8(a, w, .cp1251));
    try std.testing.expectEqualStrings(w, try fromUtf8(a, try toUtf8(a, w, .cp1251), .cp1251));
    try std.testing.expectEqualStrings("plain", try toUtf8(a, "plain", .cp1251));
}

test "cp1250 (the Polish edition) to UTF-8 and back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p: Page = .cp1250;
    const w = "Ostro\xbfnie, one walcz\xb9! \xa3\xf3d\x9f \x8c\xe6 \x81";
    try std.testing.expectEqualStrings("Ostrożnie, one walczą! Łódź Ść \u{81}", try toUtf8(a, w, p));
    try std.testing.expectEqualStrings(w, try fromUtf8(a, try toUtf8(a, w, p), p));
    try std.testing.expectEqual(.cp1250, forLanguage(2));
    try std.testing.expectEqual(.cp1251, forLanguage(5));
}

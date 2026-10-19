//! Bitmap fonts `CZC1` (`common/other.dat: *.fnt` — dialogue, system, small).
//!
//! `CZC1`, `u32 data size`, 256 × `u32` glyph offset (from the data start,
//! `0xFFFFFFFF` — no glyph), data. Glyph: `u32 width`, `u32 height`, `u32` (1),
//! `u32` (0), `width × height` bytes row by row, then padding to 4 bytes.
//! A byte is a color index, not a brightness: every game font has exactly two, the
//! most frequent is the glyph background (0 dialogue, 3 small, 1 system), the other the letter.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("image.zig").Image;

const magic = "CZC1";

const Glyph = struct {
    width: u32,
    height: u32,
    /// Brightness 0..max row by row; points into the source bytes.
    pixels: []const u8,
};

pub const Font = struct {
    glyphs: [256]?Glyph,
    height: u32,
    /// Maximum pixel value.
    max_level: u8,
    /// Glyph background value (the most frequent) — transparent.
    bg: u8 = 0,

    /// Line width (0x47b5e0): sum of (width − 1) — the exe uses −1 letter spacing
    /// (0x47b4fb); characters without a glyph are skipped.
    pub fn measure(self: Font, text: []const u8) u32 {
        var w: u32 = 0;
        for (text) |ch| if (self.glyphs[ch]) |g| {
            w += g.width -| 1;
        };
        return w;
    }

    /// Length of the first line of `text` no wider than `max_w`: breaks at the last
    /// space; a word wider than the line goes whole.
    pub fn lineCut(self: Font, text: []const u8, max_w: u32) usize {
        var cut = text.len;
        while (self.measure(text[0..cut]) > max_w) {
            cut = std.mem.lastIndexOfScalar(u8, text[0 .. cut - 1], ' ') orelse break;
        }
        return cut;
    }

    /// Draws a line into `img` from (x, y) in `color` (alpha blending).
    pub fn draw(self: Font, img: Image, x0: i32, y0: i32, text: []const u8, color: [3]u8) void {
        var x = x0;
        for (text) |ch| {
            const g = self.glyphs[ch] orelse continue;
            for (0..g.height) |gy| for (0..g.width) |gx| {
                const v = g.pixels[gy * g.width + gx];
                if (v == self.bg) continue;
                const px = x + @as(i32, @intCast(gx));
                const py = y0 + @as(i32, @intCast(gy));
                if (px < 0 or py < 0 or px >= img.width or py >= img.height) continue;
                const dst = img.pixels[(@as(usize, @intCast(py)) * img.width + @as(usize, @intCast(px))) * 4 ..][0..4];
                dst.* = .{ color[0], color[1], color[2], 255 };
            };
            x += @as(i32, @intCast(g.width)) - 1;
        }
    }
};

const Error = error{ BadMagic, Truncated };

pub fn parse(bytes: []const u8) Error!Font {
    if (bytes.len < 8 + 1024) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
    const data = bytes[8 + 1024 ..];
    var font: Font = .{ .glyphs = @splat(null), .height = 0, .max_level = 1 };
    var hist: [256]u32 = @splat(0);
    for (&font.glyphs, 0..) |*g, i| {
        const off = std.mem.readInt(u32, bytes[8 + i * 4 ..][0..4], .little);
        if (off == 0xffff_ffff) continue;
        if (@as(usize, off) + 16 > data.len) return error.Truncated;
        const w = std.mem.readInt(u32, data[off..][0..4], .little);
        const h = std.mem.readInt(u32, data[off + 4 ..][0..4], .little);
        const n = @as(usize, w) * h;
        if (@as(usize, off) + 16 + n > data.len) return error.Truncated;
        const px = data[off + 16 ..][0..n];
        g.* = .{ .width = w, .height = h, .pixels = px };
        font.height = @max(font.height, h);
        for (px) |v| {
            font.max_level = @max(font.max_level, v);
            hist[v] += 1;
        }
    }
    font.bg = @intCast(std.mem.indexOfMax(u32, &hist));
    return font;
}

test "parse and measure" {
    var bytes: [8 + 1024 + 16 + 2]u8 = @splat(0xff);
    @memcpy(bytes[0..4], magic);
    std.mem.writeInt(u32, bytes[4..8], 14, .little);
    std.mem.writeInt(u32, bytes[8 + 'A' * 4 ..][0..4], 0, .little);
    const d = bytes[8 + 1024 ..];
    std.mem.writeInt(u32, d[0..4], 2, .little);
    std.mem.writeInt(u32, d[4..8], 1, .little);
    std.mem.writeInt(u32, d[8..12], 1, .little);
    std.mem.writeInt(u32, d[12..16], 0, .little);
    d[16] = 3;
    d[17] = 0;
    const f = try parse(&bytes);
    try std.testing.expectEqual(2, f.glyphs['A'].?.width);
    try std.testing.expectEqual(null, f.glyphs['B']);
    try std.testing.expectEqual(3, f.max_level);
    // Step is width − 1 (letter spacing −1, 0x47b4fb).
    try std.testing.expectEqual(1, f.measure("A"));
    // Break at the last space; a word wider than the line goes whole.
    try std.testing.expectEqual(2, f.lineCut("AA AA", 2));
    try std.testing.expectEqual(5, f.lineCut("AA AA", 4));
    try std.testing.expectEqual(4, f.lineCut("AAAA", 2));
}

/// Overlay a language letter set (0x47b2a0): a `CZC1` file with `base` glyphs, replaced
/// where `extra` has its own. This is how the exe builds font N from `<name>_1.fnt` and
/// `<name>_N_xx.fnt` (the Russian edition puts cp1251 Cyrillic into set 5).
pub fn merge(gpa: Allocator, base: []const u8, extra: []const u8) (Error || Allocator.Error)![]u8 {
    _ = try parse(base);
    _ = try parse(extra);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var offs: [256]u32 = @splat(0xffff_ffff);
    for (&offs, 0..) |*o, i| {
        const src = for ([2][]const u8{ extra, base }) |b| {
            const off = std.mem.readInt(u32, b[8 + i * 4 ..][0..4], .little);
            if (off != 0xffff_ffff) break b[8 + 1024 + off ..];
        } else continue;
        const w = std.mem.readInt(u32, src[0..4], .little);
        const h = std.mem.readInt(u32, src[4..8], .little);
        const n = 16 + @as(usize, w) * h;
        o.* = @intCast(data.items.len);
        try data.appendSlice(gpa, src[0..n]);
        while (data.items.len % 4 != 0) try data.append(gpa, 0);
    }
    const out = try gpa.alloc(u8, 8 + 1024 + data.items.len);
    @memcpy(out[0..4], magic);
    std.mem.writeInt(u32, out[4..8], @intCast(data.items.len), .little);
    for (offs, 0..) |o, i| std.mem.writeInt(u32, out[8 + i * 4 ..][0..4], o, .little);
    @memcpy(out[8 + 1024 ..], data.items);
    return out;
}

test merge {
    const one = struct {
        fn font(ch: u8, w: u32) [8 + 1024 + 20]u8 {
            var b: [8 + 1024 + 20]u8 = @splat(0xff);
            @memcpy(b[0..4], magic);
            std.mem.writeInt(u32, b[4..8], 20, .little);
            std.mem.writeInt(u32, b[8 + @as(usize, ch) * 4 ..][0..4], 0, .little);
            const d = b[8 + 1024 ..];
            std.mem.writeInt(u32, d[0..4], w, .little);
            std.mem.writeInt(u32, d[4..8], 1, .little);
            std.mem.writeInt(u32, d[8..12], 1, .little);
            std.mem.writeInt(u32, d[12..16], 0, .little);
            @memset(d[16..20], 1);
            return b;
        }
    };
    const a = one.font('a', 3);
    const ya = one.font(0xff, 4);
    const m = try merge(std.testing.allocator, &a, &ya);
    defer std.testing.allocator.free(m);
    const f = try parse(m);
    try std.testing.expectEqual(3, f.glyphs['a'].?.width);
    try std.testing.expectEqual(4, f.glyphs[0xff].?.width);
    try std.testing.expectEqual(null, f.glyphs['b']);
}

/// Texture fonts (`3d_*.fnt`): 256 records, a character is a rectangle in the
/// same-named texture `gfx_3d\textures\<name>.3df` (texture background is a red key).
/// 16 bytes: `x, y, width, height`; 24 bytes: `x0, y0, x1, y1, advance, baseline`.
pub const TexGlyph = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    advance: i32,
    /// Baseline in the atlas (24-byte records): glyph top = line_y + (y − base).
    base: i32 = 0,
};

pub fn parseTex(bytes: []const u8) Error![256]?TexGlyph {
    const rec: usize = switch (bytes.len) {
        4096 => 16,
        6144 => 24,
        else => return error.BadMagic,
    };
    var out: [256]?TexGlyph = @splat(null);
    for (&out, 0..) |*g, i| {
        var v: [6]i32 = @splat(0);
        for (0..rec / 4) |k| v[k] = std.mem.readInt(i32, bytes[i * rec + k * 4 ..][0..4], .little);
        g.* = if (rec == 16)
            (if (v[2] > 0) TexGlyph{ .x = v[0], .y = v[1], .w = v[2], .h = v[3], .advance = v[2] } else null)
        else
            // Size includes the edge pixel (0x47a6e0).
            (if (v[4] > 0) TexGlyph{ .x = v[0], .y = v[1], .w = v[2] - v[0] + 1, .h = v[3] - v[1] + 1, .advance = v[4], .base = v[5] } else null);
    }
    return out;
}

test parseTex {
    var bytes: [4096]u8 = @splat(0);
    const a = [_]i32{ 0, 1, 20, 42 };
    for (a, 0..) |v, k| std.mem.writeInt(i32, bytes['A' * 16 + k * 4 ..][0..4], v, .little);
    const t = try parseTex(&bytes);
    try std.testing.expectEqual(20, t['A'].?.w);
    try std.testing.expectEqual(null, t['B']);
}

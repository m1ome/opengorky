//! Bitmap fonts `CZC1` (`common/other.dat: *.fnt` — dialogue, system, small).
//!
//! `CZC1`, `u32 data size`, 256 × `u32` glyph offset (from the data start,
//! `0xFFFFFFFF` — no glyph), data. Glyph: `u32 width`, `u32 height`, `u32` (1),
//! `u32` (0), `width × height` bytes row by row, then padding to 4 bytes.
//! A byte is a color index, not a brightness: the most frequent is the glyph
//! background (0 dialogue, 3 small, 1 system), the others form the letter.
//! Language sets can use different indices from their base font.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("image.zig").Image;

const magic = "CZC1";

const Glyph = struct {
    width: u32,
    height: u32,
    /// Color indices row by row; points into the source bytes.
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
/// Normalize differing background indices so the result has one transparency mask.
pub fn merge(gpa: Allocator, base: []const u8, extra: []const u8) (Error || Allocator.Error)![]u8 {
    const base_font = try parse(base);
    const extra_font = try parse(extra);
    const fg: u8 = blk: {
        for (base_font.glyphs) |g| if (g) |glyph| {
            for (glyph.pixels) |v| if (v != base_font.bg) break :blk v;
        };
        break :blk if (base_font.bg == 0) 1 else 0;
    };
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var offs: [256]u32 = @splat(0xffff_ffff);
    for (&offs, 0..) |*o, i| {
        const source = for ([2][]const u8{ extra, base }, [2]u8{ extra_font.bg, base_font.bg }) |b, bg| {
            const off = std.mem.readInt(u32, b[8 + i * 4 ..][0..4], .little);
            if (off != 0xffff_ffff) break .{
                .bytes = b[8 + 1024 + off ..],
                .bg = bg,
            };
        } else continue;
        const src = source.bytes;
        const w = std.mem.readInt(u32, src[0..4], .little);
        const h = std.mem.readInt(u32, src[4..8], .little);
        const n = 16 + @as(usize, w) * h;
        o.* = @intCast(data.items.len);
        try data.appendSlice(gpa, src[0..n]);
        // 03_small uses background 3 / letter 4, but its Polish set uses
        // background 0 / letter 3. Copying those indices makes the letter
        // transparent and its rectangle opaque when parsed as one font.
        if (source.bg != base_font.bg) {
            for (data.items[o.* + 16 ..][0 .. n - 16]) |*v| {
                v.* = if (v.* == source.bg) base_font.bg else fg;
            }
        }
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

test "merge preserves rendered language glyph masks" {
    const gpa = std.testing.allocator;
    const Colors = struct { bg: u8, fg: u8, extra_bg: u8, extra_fg: u8, extra_fg2: u8 };
    const cases = [_]Colors{
        .{ .bg = 3, .fg = 4, .extra_bg = 0, .extra_fg = 3, .extra_fg2 = 3 }, // Polish small
        .{ .bg = 0, .fg = 3, .extra_bg = 0, .extra_fg = 3, .extra_fg2 = 3 }, // Dialogue
        .{ .bg = 1, .fg = 3, .extra_bg = 1, .extra_fg = 3, .extra_fg2 = 3 }, // System
        .{ .bg = 0, .fg = 3, .extra_bg = 3, .extra_fg = 4, .extra_fg2 = 4 }, // Reverse collision
        .{ .bg = 3, .fg = 4, .extra_bg = 3, .extra_fg = 5, .extra_fg2 = 6 }, // Same background, other ink
        .{ .bg = 3, .fg = 4, .extra_bg = 0, .extra_fg = 5, .extra_fg2 = 6 }, // Several ink indices
        .{ .bg = 3, .fg = 3, .extra_bg = 0, .extra_fg = 3, .extra_fg2 = 3 }, // Blank base
    };
    for (cases) |colors| {
        const bg = colors.bg;
        const fg = colors.fg;
        const extra_bg = colors.extra_bg;
        const extra_fg = colors.extra_fg;
        const extra_fg2 = colors.extra_fg2;
        const main_px = [_]u8{ bg, bg, bg, bg, fg, bg, bg, bg, bg };
        const extra_px = [_]u8{ extra_bg, extra_fg, extra_bg, extra_bg, extra_fg2, extra_bg, extra_bg, extra_bg, extra_bg };
        var main_glyphs: [256]?EditGlyph = @splat(null);
        main_glyphs['A'] = .{ .width = 3, .height = 3, .pixels = &main_px, .order = 0 };
        main_glyphs[0x9c] = main_glyphs['A'];
        main_glyphs[0xdf] = main_glyphs['A'];
        main_glyphs[0xff] = main_glyphs['A'];
        var extra_glyphs: [256]?EditGlyph = @splat(null);
        // Exercise CP1250 ś and CP1251 Я/я byte slots without recoding them.
        extra_glyphs[0x9c] = .{ .width = 3, .height = 3, .pixels = &extra_px, .order = 0 };
        extra_glyphs[0xdf] = extra_glyphs[0x9c];
        extra_glyphs[0xff] = extra_glyphs[0x9c];
        const main_bytes = try encode(gpa, &main_glyphs);
        defer gpa.free(main_bytes);
        const extra_bytes = try encode(gpa, &extra_glyphs);
        defer gpa.free(extra_bytes);
        const merged = try merge(gpa, main_bytes, extra_bytes);
        defer gpa.free(merged);
        const f = try parse(merged);
        try std.testing.expectEqual(bg, f.bg);
        try std.testing.expectEqualSlices(u8, &main_px, f.glyphs['A'].?.pixels);
        if (bg == extra_bg) try std.testing.expectEqualSlices(u8, &extra_px, f.glyphs[0x9c].?.pixels);
        try std.testing.expectEqual(8, f.measure("A\x9c\xdf\xff"));
        try std.testing.expectEqual(null, f.glyphs['B']);
        var img = try Image.init(gpa, 10, 3);
        defer img.deinit(gpa);
        f.draw(img, 0, 0, "A\x9c\xdf\xff", .{ 210, 210, 192 });
        for (0..3) |y| for (0..10) |x| {
            const on = (x == 1 and y == 1 and fg != bg) or ((x == 3 or x == 5 or x == 7) and y < 2);
            const expected = if (on) [_]u8{ 210, 210, 192, 255 } else [_]u8{ 0, 0, 0, 0 };
            try std.testing.expectEqualSlices(u8, &expected, img.pixels[(y * 10 + x) * 4 ..][0..4]);
        };
    }
}

/// A glyph to write: its size, pixels (colour indices, row by row) and place in the data
/// (`order`: the offset it had — the game's files keep their own order; new ones last).
pub const EditGlyph = struct { width: u32, height: u32, pixels: []const u8, order: u32 };

/// The glyphs of `bytes` to edit (pixels point into `bytes`).
pub fn editable(bytes: []const u8) Error![256]?EditGlyph {
    _ = try parse(bytes);
    var out: [256]?EditGlyph = @splat(null);
    const data = bytes[8 + 1024 ..];
    for (&out, 0..) |*g, i| {
        const off = std.mem.readInt(u32, bytes[8 + i * 4 ..][0..4], .little);
        if (off == 0xffff_ffff) continue;
        const w = std.mem.readInt(u32, data[off..][0..4], .little);
        const h = std.mem.readInt(u32, data[off + 4 ..][0..4], .little);
        g.* = .{ .width = w, .height = h, .pixels = data[off + 16 ..][0 .. @as(usize, w) * h], .order = off };
    }
    return out;
}

/// `CZC1` from `glyphs`, laid out by `order` (the game's fonts come back byte for byte).
pub fn encode(gpa: Allocator, glyphs: *const [256]?EditGlyph) Allocator.Error![]u8 {
    var idx: std.ArrayList(u8) = .empty;
    defer idx.deinit(gpa);
    for (glyphs, 0..) |g, i| if (g != null) try idx.append(gpa, @intCast(i));
    std.mem.sort(u8, idx.items, glyphs, struct {
        fn lt(gs: *const [256]?EditGlyph, x: u8, y: u8) bool {
            return gs[x].?.order < gs[y].?.order or (gs[x].?.order == gs[y].?.order and x < y);
        }
    }.lt);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var offs: [256]u32 = @splat(0xffff_ffff);
    for (idx.items) |i| {
        const g = glyphs[i].?;
        offs[i] = @intCast(data.items.len);
        var head: [16]u8 = undefined;
        std.mem.writeInt(u32, head[0..4], g.width, .little);
        std.mem.writeInt(u32, head[4..8], g.height, .little);
        std.mem.writeInt(u32, head[8..12], 1, .little);
        std.mem.writeInt(u32, head[12..16], 0, .little);
        try data.appendSlice(gpa, &head);
        try data.appendSlice(gpa, g.pixels);
        while (data.items.len % 4 != 0) try data.append(gpa, 0);
    }
    const out = try gpa.alloc(u8, 8 + 1024 + data.items.len);
    @memcpy(out[0..4], magic);
    std.mem.writeInt(u32, out[4..8], @intCast(data.items.len), .little);
    for (offs, 0..) |o, i| std.mem.writeInt(u32, out[8 + i * 4 ..][0..4], o, .little);
    @memcpy(out[8 + 1024 ..], data.items);
    return out;
}

test encode {
    // Two glyphs stored 'b' before 'a' come back in that order.
    var b: [8 + 1024 + 40]u8 = @splat(0xff);
    @memcpy(b[0..4], magic);
    std.mem.writeInt(u32, b[4..8], 40, .little);
    std.mem.writeInt(u32, b[8 + 'a' * 4 ..][0..4], 20, .little);
    std.mem.writeInt(u32, b[8 + 'b' * 4 ..][0..4], 0, .little);
    const d = b[8 + 1024 ..];
    for ([_]usize{ 0, 20 }) |o| {
        std.mem.writeInt(u32, d[o..][0..4], 2, .little);
        std.mem.writeInt(u32, d[o + 4 ..][0..4], 2, .little);
        std.mem.writeInt(u32, d[o + 8 ..][0..4], 1, .little);
        std.mem.writeInt(u32, d[o + 12 ..][0..4], 0, .little);
        @memset(d[o + 16 .. o + 20], @intCast(o));
    }
    const gs = try editable(&b);
    const out = try encode(std.testing.allocator, &gs);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, &b, out);
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

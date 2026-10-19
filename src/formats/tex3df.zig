//! 3dfx Glide textures `.3df` (`common/other.dat: gfx_3d\textures\*.3df`).
//!
//! A 4-line text header (`3df v1.1`, format, `lod range: min max`,
//! `aspect ratio: w h`), then a color table (palette for p8, NCC table for yiq)
//! and mip levels from largest to smallest (`decode` is the largest, `decodeMips` all).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("image.zig").Image;

const Format = enum { p8, argb4444, yiq, rgb565, argb1555, i8, a8, ai88 };

const Error = error{ BadHeader, UnsupportedFormat, Truncated } || Allocator.Error;

const Header = struct {
    format: Format,
    width: u32,
    height: u32,
    /// Offset of the color table / data after the text header.
    data_offset: usize,
    /// Mip level count from `lod range` (largest to smallest).
    levels: u32 = 1,
};

fn parseHeader(bytes: []const u8) Error!Header {
    var lines: [4][]const u8 = undefined;
    var pos: usize = 0;
    for (&lines) |*l| {
        const end = std.mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse return error.BadHeader;
        l.* = std.mem.trim(u8, bytes[pos..end], " \r");
        pos = end + 1;
    }
    if (!std.mem.startsWith(u8, lines[0], "3df")) return error.BadHeader;
    const format = std.meta.stringToEnum(Format, lines[1]) orelse return error.UnsupportedFormat;
    const lod = try twoInts(lines[2], "lod range:");
    const aspect = try twoInts(lines[3], "aspect ratio:");
    if (aspect[0] == 0 or aspect[1] == 0 or lod[1] == 0) return error.BadHeader;
    // The large side is the upper LOD limit, the small one follows the aspect ratio.
    const large = lod[1];
    const w: u32 = if (aspect[0] >= aspect[1]) large else @intCast(@as(u64, large) * aspect[0] / aspect[1]);
    const h: u32 = if (aspect[1] >= aspect[0]) large else @intCast(@as(u64, large) * aspect[1] / aspect[0]);
    var levels: u32 = 1;
    var l = large;
    while (l > @max(1, lod[0])) : (l /= 2) levels += 1;
    return .{ .format = format, .width = w, .height = h, .data_offset = pos, .levels = levels };
}

fn twoInts(line: []const u8, prefix: []const u8) Error![2]u32 {
    if (!std.mem.startsWith(u8, line, prefix)) return error.BadHeader;
    var it = std.mem.tokenizeScalar(u8, line[prefix.len..], ' ');
    var out: [2]u32 = undefined;
    for (&out) |*v| v.* = std.fmt.parseInt(u32, it.next() orelse return error.BadHeader, 10) catch return error.BadHeader;
    return out;
}

pub fn decode(gpa: Allocator, bytes: []const u8) Error!Image {
    const hdr = try parseHeader(bytes);
    var tables: Tables = undefined;
    const pos = try tables.read(hdr, bytes);
    return decodeLevel(gpa, hdr.format, &tables, bytes, pos, hdr.width, hdr.height);
}

/// All mip levels (largest to smallest, each half the size, at least 1×1):
/// the exe creates model textures with a mip chain (0x409717: DDSD_MIPMAPCOUNT)
/// and MIPLINEAR filtering (0x406d90: TEXTUREMIN = 4). A truncated file gives what it has.
pub fn decodeMips(gpa: Allocator, bytes: []const u8) Error![]Image {
    const hdr = try parseHeader(bytes);
    var tables: Tables = undefined;
    var pos = try tables.read(hdr, bytes);
    var levels: std.ArrayList(Image) = .empty;
    errdefer {
        for (levels.items) |*l| l.deinit(gpa);
        levels.deinit(gpa);
    }
    var w = hdr.width;
    var h = hdr.height;
    const bpp: usize = switch (hdr.format) {
        .argb4444, .rgb565, .argb1555, .ai88 => 2,
        else => 1,
    };
    for (0..hdr.levels) |_| {
        const n = @as(usize, w) * h * bpp;
        if (pos + n > bytes.len) {
            if (levels.items.len == 0) return error.Truncated;
            break;
        }
        try levels.append(gpa, try decodeLevel(gpa, hdr.format, &tables, bytes, pos, w, h));
        pos += n;
        if (w == 1 and h == 1) break;
        w = @max(1, w / 2);
        h = @max(1, h / 2);
    }
    return levels.toOwnedSlice(gpa);
}

/// Color table before the data: p8 palette or yiq NCC.
const Tables = struct {
    pal: ?*const [1024]u8 = null,
    ncc: ?Ncc = null,

    fn read(t: *Tables, hdr: Header, bytes: []const u8) Error!usize {
        t.* = .{};
        var pos = hdr.data_offset;
        switch (hdr.format) {
            .p8 => {
                if (pos + 1024 > bytes.len) return error.Truncated;
                t.pal = bytes[pos..][0..1024];
                pos += 1024;
            },
            .yiq => {
                if (pos + 80 > bytes.len) return error.Truncated;
                t.ncc = Ncc.parse(bytes[pos..][0..80]);
                pos += 80;
            },
            else => {},
        }
        return pos;
    }
};

fn decodeLevel(gpa: Allocator, format: Format, tables: *const Tables, bytes: []const u8, pos: usize, w: u32, h: u32) Error!Image {
    var img = try Image.init(gpa, w, h);
    errdefer img.deinit(gpa);
    const n = @as(usize, w) * h;
    switch (format) {
        .p8 => {
            if (pos + n > bytes.len) return error.Truncated;
            const pal = tables.pal.?;
            for (bytes[pos..][0..n], 0..) |idx, i| {
                // Palette: u32 big-endian 0x00RRGGBB.
                const e = pal[@as(usize, idx) * 4 ..][0..4];
                img.pixels[i * 4 ..][0..4].* = .{ e[1], e[2], e[3], 0xff };
            }
        },
        .yiq => {
            if (pos + n > bytes.len) return error.Truncated;
            const ncc = tables.ncc.?;
            for (bytes[pos..][0..n], 0..) |t, i| img.pixels[i * 4 ..][0..4].* = ncc.texel(t);
        },
        .argb4444, .rgb565, .argb1555, .ai88 => {
            if (pos + n * 2 > bytes.len) return error.Truncated;
            for (0..n) |i| {
                // 16-bit formats in 3DF are big-endian.
                const v = std.mem.readInt(u16, bytes[pos + i * 2 ..][0..2], .big);
                img.pixels[i * 4 ..][0..4].* = switch (format) {
                    .argb4444 => .{ x4(v >> 8), x4(v >> 4), x4(v), x4(v >> 12) },
                    .rgb565 => .{ x5(v >> 11), x6(v >> 5), x5(v), 0xff },
                    .argb1555 => .{ x5(v >> 10), x5(v >> 5), x5(v), if (v & 0x8000 != 0) 0xff else 0 },
                    .ai88 => .{ @truncate(v), @truncate(v), @truncate(v), @truncate(v >> 8) },
                    else => unreachable,
                };
            }
        },
        .i8, .a8 => {
            if (pos + n > bytes.len) return error.Truncated;
            for (bytes[pos..][0..n], 0..) |v, i| {
                img.pixels[i * 4 ..][0..4].* = if (format == .i8) .{ v, v, v, 0xff } else .{ 0xff, 0xff, 0xff, v };
            }
        },
    }
    return img;
}

fn x4(v: u16) u8 {
    const c: u8 = @truncate(v & 0xf);
    return c << 4 | c;
}

fn x5(v: u16) u8 {
    const c: u8 = @truncate(v & 0x1f);
    return c << 3 | c >> 2;
}

fn x6(v: u16) u8 {
    const c: u8 = @truncate(v & 0x3f);
    return c << 2 | c >> 4;
}

/// 3dfx NCC (Narrow Channel Compression) table: 16 Y values and 4 vectors each
/// (R, G, B) for I and Q; texel `yyyy iiqq`.
const Ncc = struct {
    y: [16]i32,
    i: [4][3]i32,
    q: [4][3]i32,

    fn parse(b: *const [80]u8) Ncc {
        var t: Ncc = undefined;
        for (&t.y, 0..) |*v, k| v.* = std.mem.readInt(u16, b[k * 2 ..][0..2], .big) & 0xff;
        for (&t.i, 0..) |*vec, k| for (vec, 0..) |*v, ch| {
            v.* = std.mem.readInt(i16, b[32 + (k * 3 + ch) * 2 ..][0..2], .big);
        };
        for (&t.q, 0..) |*vec, k| for (vec, 0..) |*v, ch| {
            v.* = std.mem.readInt(i16, b[56 + (k * 3 + ch) * 2 ..][0..2], .big);
        };
        return t;
    }

    fn texel(t: Ncc, v: u8) [4]u8 {
        const y = t.y[v >> 4];
        const i = t.i[(v >> 2) & 3];
        const q = t.q[v & 3];
        var out: [4]u8 = .{ 0, 0, 0, 0xff };
        for (0..3) |ch| out[ch] = @intCast(std.math.clamp(y + i[ch] + q[ch], 0, 255));
        return out;
    }
};

test "p8 texture" {
    const gpa = std.testing.allocator;
    const header = "3df v1.1\np8\nlod range: 1 2\naspect ratio: 2 1\n";
    var bytes: [header.len + 1024 + 2 + 1]u8 = @splat(0);
    @memcpy(bytes[0..header.len], header);
    bytes[header.len + 4 + 1] = 0xff; // palette[1] = red (00 ff 00 00)
    bytes[header.len + 1024 + 1] = 1; // second texel
    var img = try decode(gpa, &bytes);
    defer img.deinit(gpa);
    try std.testing.expectEqual(2, img.width);
    try std.testing.expectEqual(1, img.height);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0xff, 0xff, 0, 0, 0xff }, img.pixels);
}

test "argb4444 big-endian and crlf header" {
    const gpa = std.testing.allocator;
    const header = "3df v1.1\r\nargb4444\r\nlod range: 1 1\r\naspect ratio: 1 1\r\n";
    const bytes = header ++ [_]u8{ 0x8f, 0x00 };
    var img = try decode(gpa, bytes);
    defer img.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0, 0, 0x88 }, img.pixels);
}

test "mip levels" {
    const gpa = std.testing.allocator;
    const header = "3df v1.1\ni8\nlod range: 1 4\naspect ratio: 2 1\n";
    // 4×2, 2×1, 1×1.
    const bytes = header ++ [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 } ++ [_]u8{ 9, 10 } ++ [_]u8{11};
    const mips = try decodeMips(gpa, bytes);
    defer {
        for (mips) |*m| m.deinit(gpa);
        gpa.free(mips);
    }
    try std.testing.expectEqual(3, mips.len);
    try std.testing.expectEqual(2, mips[1].width);
    try std.testing.expectEqual(1, mips[1].height);
    try std.testing.expectEqual(10, mips[1].pixels[4]);
    try std.testing.expectEqual(11, mips[2].pixels[0]);
}

test "huge lod does not overflow" {
    const h = try parseHeader("3df v1.1\np8\nlod range: 1 4294967295\naspect ratio: 1 3\n");
    try std.testing.expectEqual(@as(u32, 1431655765), h.width);
}

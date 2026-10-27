//! Sprites `spr1` (`.spr`, `.spz`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("image.zig").Image;

pub const magic = "spr1";
const raw_flag: u16 = 0x8000;
/// Raw-frame prefix meaning no transparency color key.
const no_color_key: u32 = 0xffff_ffff;

pub const Frame = struct {
    width: u16,
    height: u16,
    raw: bool,
    /// Frame data, including the 4-byte color key of raw frames.
    data: []const u8,
};

pub const Sprite = struct {
    frames: []Frame,

    pub fn deinit(self: *Sprite, gpa: Allocator) void {
        gpa.free(self.frames);
        self.* = undefined;
    }
};

const Error = error{ BadMagic, Truncated, BadFrame };

/// Frames point into `bytes`; do not free it before `Sprite.deinit`.
pub fn parse(gpa: Allocator, bytes: []const u8) (Error || Allocator.Error)!Sprite {
    if (bytes.len < 16) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
    // bytes[4..8]: source pixel format for the graphics converter (0x41c120): 1 is RGB555,
    // otherwise RGB565 (0 in `.spr`, 100 in three `.spz`); not read when drawing.
    const count = std.mem.readInt(u32, bytes[8..12], .little);
    const data_start = std.mem.readInt(u32, bytes[12..16], .little);
    if (count == 0 or 16 + @as(u64, count - 1) * 8 + 4 > data_start or data_start > bytes.len)
        return error.Truncated;

    const frames = try gpa.alloc(Frame, count);
    errdefer gpa.free(frames);

    // Table: count records (u16 width, u16 height, u32 frame end); the last record
    // has no end field — the first frame's data starts there.
    var start: usize = data_start;
    for (frames, 0..) |*f, i| {
        const rec = bytes[16 + i * 8 ..];
        const w = std.mem.readInt(u16, rec[0..2], .little);
        const end: usize = if (i + 1 < count) std.mem.readInt(u32, rec[4..8], .little) else bytes.len;
        if (end < start or end > bytes.len) return error.Truncated;
        f.* = .{
            .width = w & ~raw_flag,
            .height = std.mem.readInt(u16, rec[2..4], .little),
            .raw = w & raw_flag != 0,
            .data = bytes[start..end],
        };
        start = end;
    }
    return .{ .frames = frames };
}

pub fn decodeFrame(gpa: Allocator, frame: Frame) (Error || Allocator.Error)!Image {
    var img = try Image.init(gpa, frame.width, frame.height);
    errdefer img.deinit(gpa);
    if (frame.raw) try decodeRaw(img, frame) else try decodeRle(img, frame);
    return img;
}

fn decodeRaw(img: Image, frame: Frame) Error!void {
    const px_count = @as(usize, frame.width) * frame.height;
    if (frame.data.len != 4 + px_count * 2) return error.BadFrame;
    const key = std.mem.readInt(u32, frame.data[0..4], .little);
    for (0..frame.height) |y| for (0..frame.width) |x| {
        const c = std.mem.readInt(u16, frame.data[4 + (y * frame.width + x) * 2 ..][0..2], .little);
        if (key != no_color_key and c == key) continue;
        img.setRgb565(x, y, c);
    };
}

/// Each row: u16 row length in words (including the length word itself),
/// then u16 commands, `0` ends the row:
///   `00nnnnnn…` skip n pixels (transparent)
///   `10nnnnnn…` n pixels of one color, the color in the next word
///   `11nnnnnn…` n pixels, colors in the next n words
fn decodeRle(img: Image, frame: Frame) Error!void {
    const d = frame.data;
    var pos: usize = 0;
    for (0..frame.height) |y| {
        if (pos + 2 > d.len) return error.Truncated;
        const row_words = std.mem.readInt(u16, d[pos..][0..2], .little);
        const row_end = pos + @as(usize, row_words) * 2;
        if (row_end > d.len) return error.Truncated;
        var q = pos + 2;
        var x: usize = 0;
        while (true) {
            if (q + 2 > row_end) return error.BadFrame;
            const op = std.mem.readInt(u16, d[q..][0..2], .little);
            q += 2;
            if (op == 0) break;
            const n: usize = op & 0x3fff;
            if (x + n > frame.width) return error.BadFrame;
            switch (op >> 14) {
                0 => {},
                2 => {
                    if (q + 2 > row_end) return error.BadFrame;
                    const c = std.mem.readInt(u16, d[q..][0..2], .little);
                    q += 2;
                    for (x..x + n) |xi| img.setRgb565(xi, y, c);
                },
                3 => {
                    if (q + n * 2 > row_end) return error.BadFrame;
                    for (0..n) |i| img.setRgb565(x + i, y, std.mem.readInt(u16, d[q + i * 2 ..][0..2], .little));
                    q += n * 2;
                },
                else => return error.BadFrame,
            }
            x += n;
        }
        if (x != frame.width or q != row_end) return error.BadFrame;
        pos = row_end;
    }
    if (pos != d.len) return error.BadFrame;
}

fn le16(comptime words: []const u16) [words.len * 2]u8 {
    var out: [words.len * 2]u8 = undefined;
    for (words, 0..) |w, i| std.mem.writeInt(u16, out[i * 2 ..][0..2], w, .little);
    return out;
}

/// `spr1` with RLE frames from RGBA images (alpha below 128 is transparent),
/// as the game's own sprites (icons: big frame, then small).
pub fn encode(gpa: Allocator, frames: []const Image) Allocator.Error![]u8 {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var ends: std.ArrayList(u32) = .empty;
    defer ends.deinit(gpa);
    for (frames) |img| {
        for (0..img.height) |y| {
            const row_start = data.items.len;
            try data.appendNTimes(gpa, 0, 2);
            var x: usize = 0;
            while (x < img.width) {
                const opaque_ = img.pixels[(y * img.width + x) * 4 + 3] >= 128;
                var n: usize = 0;
                while (x + n < img.width and n < 0x3fff and (img.pixels[(y * img.width + x + n) * 4 + 3] >= 128) == opaque_) n += 1;
                try putU16(gpa, &data, @as(u16, @intCast(n)) | (if (opaque_) @as(u16, 0xc000) else 0));
                if (opaque_) for (x..x + n) |xi| try putU16(gpa, &data, rgb565(img.pixels[(y * img.width + xi) * 4 ..][0..3].*));
                x += n;
            }
            try putU16(gpa, &data, 0);
            std.mem.writeInt(u16, data.items[row_start..][0..2], @intCast((data.items.len - row_start) / 2), .little);
        }
        try ends.append(gpa, @intCast(data.items.len));
    }
    const start: u32 = @intCast(16 + frames.len * 8 - 4);
    var out = try gpa.alloc(u8, start + data.items.len);
    @memcpy(out[0..4], magic);
    std.mem.writeInt(u32, out[4..8], 0, .little);
    std.mem.writeInt(u32, out[8..12], @intCast(frames.len), .little);
    std.mem.writeInt(u32, out[12..16], start, .little);
    for (frames, 0..) |img, i| {
        const rec = out[16 + i * 8 ..];
        std.mem.writeInt(u16, rec[0..2], @intCast(img.width), .little);
        std.mem.writeInt(u16, rec[2..4], @intCast(img.height), .little);
        if (i + 1 < frames.len) std.mem.writeInt(u32, rec[4..8], start + ends.items[i], .little);
    }
    @memcpy(out[start..], data.items);
    return out;
}

fn putU16(gpa: Allocator, list: *std.ArrayList(u8), v: u16) Allocator.Error!void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try list.appendSlice(gpa, &b);
}

fn rgb565(c: [3]u8) u16 {
    return @as(u16, c[0] >> 3) << 11 | @as(u16, c[1] >> 2) << 5 | c[2] >> 3;
}

test "encode: frames read back" {
    const gpa = std.testing.allocator;
    var a = try Image.init(gpa, 3, 2);
    defer a.deinit(gpa);
    a.pixels[4..8].* = .{ 0xff, 0, 0, 0xff };
    a.pixels[8..12].* = .{ 0, 0xff, 0, 0xff };
    a.pixels[20..24].* = .{ 0, 0, 0xff, 0xff };
    var b = try Image.init(gpa, 1, 1);
    defer b.deinit(gpa);
    b.pixels[0..4].* = .{ 0xff, 0xff, 0xff, 0xff };
    const bytes = try encode(gpa, &.{ a, b });
    defer gpa.free(bytes);
    var spr = try parse(gpa, bytes);
    defer spr.deinit(gpa);
    try std.testing.expectEqual(2, spr.frames.len);
    var x = try decodeFrame(gpa, spr.frames[0]);
    defer x.deinit(gpa);
    try std.testing.expectEqualSlices(u8, a.pixels, x.pixels);
    var y = try decodeFrame(gpa, spr.frames[1]);
    defer y.deinit(gpa);
    try std.testing.expectEqualSlices(u8, b.pixels, y.pixels);
}

test "decode rle frame" {
    const gpa = std.testing.allocator;
    // Row 1: skip 1, literal 2 (red, green). Row 2: fill 3 blue.
    const data = le16(&.{ 6, 0x0001, 0xc002, 0xf800, 0x07e0, 0, 4, 0x8003, 0x001f, 0 });
    var img = try decodeFrame(gpa, .{ .width = 3, .height = 2, .raw = false, .data = &data });
    defer img.deinit(gpa);
    try std.testing.expectEqual(0, img.pixels[3]); // (0,0) transparent
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0, 0, 0xff }, img.pixels[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0xff, 0, 0xff }, img.pixels[8..12]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0xff, 0xff }, img.pixels[20..24]);
}

test "rle row wider than frame is rejected" {
    const gpa = std.testing.allocator;
    const data = le16(&.{ 3, 0x0005, 0 });
    try std.testing.expectError(error.BadFrame, decodeFrame(gpa, .{ .width = 3, .height = 1, .raw = false, .data = &data }));
}

test "parse sprite with two raw frames and color key" {
    const gpa = std.testing.allocator;
    const bytes = "spr1" ++ le16(&.{ 0, 0, 2, 0, 28, 0 }) ++
        le16(&.{ 0x8001, 1, 34, 0 }) ++ le16(&.{ 0x8001, 1 }) ++
        le16(&.{ 0xf800, 0, 0xf800 }) ++ le16(&.{ 0xffff, 0xffff, 0x07e0 });
    var spr = try parse(gpa, bytes);
    defer spr.deinit(gpa);
    try std.testing.expectEqual(2, spr.frames.len);
    try std.testing.expect(spr.frames[0].raw);

    var a = try decodeFrame(gpa, spr.frames[0]);
    defer a.deinit(gpa);
    try std.testing.expectEqual(0, a.pixels[3]); // color matched the key
    var b = try decodeFrame(gpa, spr.frames[1]);
    defer b.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0xff, 0, 0xff }, b.pixels);
}

//! Background z-buffer `zbc1` (`background\*.zbf`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("image.zig").Image;

const magic = "zbc1";

pub const ZBuffer = struct {
    width: u32,
    height: u32,
    /// Depth per pixel, rows top to bottom. The low byte is 0 in every game file.
    depth: []u16,

    pub fn deinit(self: *ZBuffer, gpa: Allocator) void {
        gpa.free(self.depth);
        self.* = undefined;
    }

    /// Grey debug image: the high depth byte as brightness.
    pub fn toImage(self: ZBuffer, gpa: Allocator) Allocator.Error!Image {
        var img = try Image.init(gpa, self.width, self.height);
        for (self.depth, 0..) |d, i| {
            const v: u8 = @truncate(d >> 8);
            img.pixels[i * 4 ..][0..4].* = .{ v, v, v, 0xff };
        }
        return img;
    }
};

const Error = error{ BadMagic, Truncated, BadData };

/// A stream of u16 commands for all `width*height` values in a row (no row split),
/// then u16 0. Commands as in sprite RLE frames:
///   `10nnnnnn…` n equal values, the value in the next word;
///   `11nnnnnn…` n values in the next n words.
/// Skips (`00`) do not occur in game z-buffers; filled with zero just in case.
pub fn decode(gpa: Allocator, bytes: []const u8) (Error || Allocator.Error)!ZBuffer {
    if (bytes.len < 12) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
    const width = std.mem.readInt(u32, bytes[4..8], .little);
    const height = std.mem.readInt(u32, bytes[8..12], .little);
    const total = std.math.mul(usize, width, height) catch return error.BadData;
    // One command word covers at most 0x3fff values: checked before gpa.alloc.
    if (total > (bytes.len - 12) / 2 * 0x3fff) return error.Truncated;

    const depth = try gpa.alloc(u16, total);
    errdefer gpa.free(depth);
    var q: usize = 12;
    var n: usize = 0;
    while (n < total) {
        if (q + 2 > bytes.len) return error.Truncated;
        const op = std.mem.readInt(u16, bytes[q..][0..2], .little);
        q += 2;
        const count: usize = op & 0x3fff;
        if (count == 0 or n + count > total) return error.BadData;
        switch (op >> 14) {
            0 => @memset(depth[n..][0..count], 0),
            2 => {
                if (q + 2 > bytes.len) return error.Truncated;
                @memset(depth[n..][0..count], std.mem.readInt(u16, bytes[q..][0..2], .little));
                q += 2;
            },
            3 => {
                if (q + count * 2 > bytes.len) return error.Truncated;
                for (0..count) |i| depth[n + i] = std.mem.readInt(u16, bytes[q + i * 2 ..][0..2], .little);
                q += count * 2;
            },
            else => return error.BadData,
        }
        n += count;
    }
    return .{ .width = width, .height = height, .depth = depth };
}

/// `zbc1` of `z`: runs of equal values (`10`), the rest literal (`11`), a 0 word at the end.
pub fn encode(gpa: Allocator, z: ZBuffer) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, magic);
    var hb: [8]u8 = undefined;
    std.mem.writeInt(u32, hb[0..4], z.width, .little);
    std.mem.writeInt(u32, hb[4..8], z.height, .little);
    try out.appendSlice(gpa, &hb);
    const put = struct {
        fn w(o: *std.ArrayList(u8), g: Allocator, v: u16) Allocator.Error!void {
            var b: [2]u8 = undefined;
            std.mem.writeInt(u16, &b, v, .little);
            try o.appendSlice(g, &b);
        }
    }.w;
    const d = z.depth;
    var i: usize = 0;
    var lit: usize = i; // start of the pending literal run
    while (i < d.len) {
        var run: usize = 1;
        while (i + run < d.len and run < 0x3fff and d[i + run] == d[i]) run += 1;
        if (run >= 3) {
            while (lit < i) {
                const n = @min(i - lit, 0x3fff);
                try put(&out, gpa, 0xc000 | @as(u16, @intCast(n)));
                for (d[lit..][0..n]) |v| try put(&out, gpa, v);
                lit += n;
            }
            try put(&out, gpa, 0x8000 | @as(u16, @intCast(run)));
            try put(&out, gpa, d[i]);
            i += run;
            lit = i;
        } else i += run;
    }
    while (lit < d.len) {
        const n = @min(d.len - lit, 0x3fff);
        try put(&out, gpa, 0xc000 | @as(u16, @intCast(n)));
        for (d[lit..][0..n]) |v| try put(&out, gpa, v);
        lit += n;
    }
    try put(&out, gpa, 0);
    return out.toOwnedSlice(gpa);
}

test "encode: runs and literals read back" {
    const gpa = std.testing.allocator;
    var vals = [_]u16{ 1, 2, 7, 7, 7, 7, 3, 9, 9, 5 };
    const bytes = try encode(gpa, .{ .width = 5, .height = 2, .depth = &vals });
    defer gpa.free(bytes);
    var z = try decode(gpa, bytes);
    defer z.deinit(gpa);
    try std.testing.expectEqualSlices(u16, &vals, z.depth);
}

test decode {
    const gpa = std.testing.allocator;
    var buf: [12 + 2 * 7]u8 = undefined;
    @memcpy(buf[0..4], magic);
    std.mem.writeInt(u32, buf[4..8], 3, .little);
    std.mem.writeInt(u32, buf[8..12], 1, .little);
    const words = [_]u16{ 0xc001, 0x5d00, 0x8002, 0x6000, 0, 0, 0 };
    for (words, 0..) |w, i| std.mem.writeInt(u16, buf[12 + i * 2 ..][0..2], w, .little);

    var z = try decode(gpa, &buf);
    defer z.deinit(gpa);
    try std.testing.expectEqualSlices(u16, &.{ 0x5d00, 0x6000, 0x6000 }, z.depth);
}

test "header bigger than data" {
    var buf: [12]u8 = undefined;
    @memcpy(buf[0..4], magic);
    std.mem.writeInt(u32, buf[4..8], 65535, .little);
    std.mem.writeInt(u32, buf[8..12], 65535, .little);
    try std.testing.expectError(error.Truncated, decode(std.testing.allocator, &buf));
}

//! Level backgrounds `bkg1` (`background\*.bkg`): raw RGB565 cut into tiles.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("image.zig").Image;

const magic = "bkg1";
const header_size = 0x14;
const tile_rec_size = 20;

const Error = error{ BadMagic, Truncated, BadTile };

pub fn decode(gpa: Allocator, bytes: []const u8) (Error || Allocator.Error)!Image {
    if (bytes.len < header_size) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
    const count = std.mem.readInt(u32, bytes[8..12], .little);
    const width = std.mem.readInt(u32, bytes[12..16], .little);
    const height = std.mem.readInt(u32, bytes[16..20], .little);
    if (header_size + @as(u64, count) * tile_rec_size > bytes.len) return error.Truncated;
    // Header size checked before gpa.alloc (game backgrounds are under 2k pixels per side).
    if (width > 8192 or height > 8192) return error.BadTile;

    var img = try Image.init(gpa, width, height);
    errdefer img.deinit(gpa);
    for (0..count) |i| {
        const rec = bytes[header_size + i * tile_rec_size ..][0..tile_rec_size];
        const f = struct {
            fn at(r: *const [tile_rec_size]u8, n: usize) u32 {
                return std.mem.readInt(u32, r[n * 4 ..][0..4], .little);
            }
        }.at;
        const x0 = f(rec, 0);
        const y0 = f(rec, 1);
        const tw = f(rec, 2);
        const th = f(rec, 3);
        const off = f(rec, 4);
        if (@as(u64, x0) + tw > width or @as(u64, y0) + th > height) return error.BadTile;
        if (@as(u64, off) + @as(u64, tw) * th * 2 > bytes.len) return error.Truncated;
        for (0..th) |y| for (0..tw) |x| {
            const c = std.mem.readInt(u16, bytes[off + (y * tw + x) * 2 ..][0..2], .little);
            img.setRgb565(x0 + x, y0 + y, c);
        };
    }
    return img;
}

test "decode two tiles" {
    const gpa = std.testing.allocator;
    var buf: [header_size + 2 * tile_rec_size + 4]u8 = @splat(0);
    @memcpy(buf[0..4], magic);
    const hdr = [_]u32{ 0, 2, 2, 1 };
    for (hdr, 0..) |v, i| std.mem.writeInt(u32, buf[4 + i * 4 ..][0..4], v, .little);
    const data_off = header_size + 2 * tile_rec_size;
    const tiles = [_][5]u32{ .{ 0, 0, 1, 1, data_off }, .{ 1, 0, 1, 1, data_off + 2 } };
    for (tiles, 0..) |t, ti| for (t, 0..) |v, i| {
        std.mem.writeInt(u32, buf[header_size + ti * tile_rec_size + i * 4 ..][0..4], v, .little);
    };
    std.mem.writeInt(u16, buf[data_off..][0..2], 0xf800, .little);
    std.mem.writeInt(u16, buf[data_off + 2 ..][0..2], 0x001f, .little);

    var img = try decode(gpa, &buf);
    defer img.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0, 0, 0xff, 0, 0, 0xff, 0xff }, img.pixels);
}

//! Minimal PNG writer (RGBA8) for resource export.

const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const Image = @import("image.zig").Image;

pub fn write(gpa: Allocator, w: *Writer, img: Image) (Writer.Error || Allocator.Error)!void {
    try w.writeAll("\x89PNG\r\n\x1a\n");

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], img.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], img.height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8 bits, RGBA, deflate, no filters, no interlace
    try writeChunk(w, "IHDR", &ihdr);

    var zbuf: Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    defer zbuf.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var z = try flate.Compress.init(&zbuf.writer, window, .zlib, .level_4);
    const stride = @as(usize, img.width) * 4;
    for (0..img.height) |y| {
        try z.writer.writeByte(0); // filter None
        try z.writer.writeAll(img.pixels[y * stride ..][0..stride]);
    }
    try z.finish();
    try writeChunk(w, "IDAT", zbuf.written());
    try writeChunk(w, "IEND", "");
}

fn writeChunk(w: *Writer, kind: *const [4]u8, data: []const u8) Writer.Error!void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

test "png round trip through zlib" {
    const gpa = std.testing.allocator;
    var img = try Image.init(gpa, 2, 2);
    defer img.deinit(gpa);
    img.setRgb565(1, 1, 0xf800);

    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, img);
    const png = out.written();
    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", png[0..8]);

    // Inflate IDAT and compare the pixels.
    const idat_len = std.mem.readInt(u32, png[33..37], .big);
    try std.testing.expectEqualSlices(u8, "IDAT", png[37..41]);
    var in: std.Io.Reader = .fixed(png[41..][0..idat_len]);
    var dbuf: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&in, .zlib, &dbuf);
    var raw: [2 * (1 + 8)]u8 = undefined;
    try d.reader.readSliceAll(&raw);
    try std.testing.expectEqual(0, raw[9]);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0, 0, 0xff }, raw[14..18]);
}

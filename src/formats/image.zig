//! In-memory image: RGBA8, rows top to bottom.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Image = struct {
    width: u32,
    height: u32,
    /// width * height * 4 bytes, R, G, B, A.
    pixels: []u8,

    pub fn init(gpa: Allocator, width: u32, height: u32) Allocator.Error!Image {
        const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
        @memset(pixels, 0);
        return .{ .width = width, .height = height, .pixels = pixels };
    }

    pub fn deinit(self: *Image, gpa: Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }

    pub fn setRgb565(self: Image, x: usize, y: usize, c: u16) void {
        const p = self.pixels[(y * self.width + x) * 4 ..][0..4];
        p.* = rgb565ToRgba(c);
    }
};

/// The engine works in 16-bit RGB565 (see the masks in `1.bin`).
fn rgb565ToRgba(c: u16) [4]u8 {
    const r: u8 = @truncate(c >> 11);
    const g: u8 = @truncate((c >> 5) & 0x3f);
    const b: u8 = @truncate(c & 0x1f);
    return .{ (r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2), 0xff };
}

test rgb565ToRgba {
    try std.testing.expectEqual([4]u8{ 0xff, 0xff, 0xff, 0xff }, rgb565ToRgba(0xffff));
    try std.testing.expectEqual([4]u8{ 0xff, 0, 0, 0xff }, rgb565ToRgba(0xf800));
    try std.testing.expectEqual([4]u8{ 0, 0xff, 0, 0xff }, rgb565ToRgba(0x07e0));
    try std.testing.expectEqual([4]u8{ 0, 0, 0xff, 0xff }, rgb565ToRgba(0x001f));
}

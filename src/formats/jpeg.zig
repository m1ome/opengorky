//! JPEG backgrounds (`background\*.jpg`) and PNG (window icon) via stb_image (third_party/stb).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("image.zig").Image;

extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;
extern fn stbi_write_jpg_to_func(func: *const fn (ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void, ctx: ?*anyopaque, w: c_int, h: c_int, comp: c_int, data: [*]const u8, quality: c_int) c_int;
extern fn stbi_info_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, comp: *c_int) c_int;

/// Image size without decoding.
pub fn size(bytes: []const u8) ?[2]u32 {
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const len = std.math.cast(c_int, bytes.len) orelse return null;
    if (stbi_info_from_memory(bytes.ptr, len, &w, &h, &comp) == 0) return null;
    return .{ @intCast(w), @intCast(h) };
}

const Error = error{BadJpeg};

pub fn decode(gpa: Allocator, bytes: []const u8) (Error || Allocator.Error)!Image {
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const len = std.math.cast(c_int, bytes.len) orelse return error.BadJpeg;
    const px = stbi_load_from_memory(bytes.ptr, len, &w, &h, &comp, 4) orelse return error.BadJpeg;
    defer stbi_image_free(px);
    const n: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    return .{ .width = @intCast(w), .height = @intCast(h), .pixels = try gpa.dupe(u8, px[0..n]) };
}

/// JPEG of `img` (RGBA, alpha dropped) at `quality` 1…100, through stb_image_write.
pub fn encode(gpa: Allocator, img: Image, quality: u8) (Allocator.Error || error{EncodeFailed})![]u8 {
    const Ctx = struct {
        gpa: Allocator,
        out: std.ArrayList(u8) = .empty,
        failed: bool = false,
        fn put(p: ?*anyopaque, data: ?*anyopaque, n: c_int) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(p.?));
            const bytes: [*]const u8 = @ptrCast(data.?);
            self.out.appendSlice(self.gpa, bytes[0..@intCast(n)]) catch {
                self.failed = true;
            };
        }
    };
    var ctx: Ctx = .{ .gpa = gpa };
    errdefer ctx.out.deinit(gpa);
    if (stbi_write_jpg_to_func(Ctx.put, &ctx, @intCast(img.width), @intCast(img.height), 4, img.pixels.ptr, quality) == 0 or ctx.failed) return error.EncodeFailed;
    return ctx.out.toOwnedSlice(gpa);
}

test "encode: a JPEG the decoder reads back" {
    const gpa = std.testing.allocator;
    var img = try Image.init(gpa, 16, 8);
    defer img.deinit(gpa);
    @memset(img.pixels, 200);
    const bytes = try encode(gpa, img, 95);
    defer gpa.free(bytes);
    var back = try decode(gpa, bytes);
    defer back.deinit(gpa);
    try std.testing.expectEqual(16, back.width);
    try std.testing.expect(@abs(@as(i32, back.pixels[0]) - 200) < 4);
}

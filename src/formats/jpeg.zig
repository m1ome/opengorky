//! JPEG backgrounds (`background\*.jpg`) and PNG (window icon) via stb_image (third_party/stb).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("image.zig").Image;

extern fn stbi_load_from_memory(buffer: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels_in_file: *c_int, desired_channels: c_int) ?[*]u8;
extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;
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

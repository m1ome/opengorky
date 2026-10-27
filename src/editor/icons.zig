//! UI icons (Lucide, ISC; white PNGs from scripts/editor-icons.swift, embedded):
//! textures made on first use, drawn tinted as a clay image.

const std = @import("std");
const c = @import("sdl");
const og = @import("opengorky");
const clay = @import("clay.zig");

pub const Icon = enum { save, check, play, settings, history, search, folder, chevron_right, chevron_down, map_pin, swords, user, package, clapperboard, volume_2, plus, file_text, mouse_pointer_2, hand, paintbrush, pipette, lightbulb, square_dashed, log_out, crosshair, camera, pencil, code, message_square, maximize, x, undo_2, redo_2, eye, eye_off, lock, lock_open, layers, trash_2, copy, image, grid_3x3, box, pause, skip_back, skip_forward };

var textures: [std.enums.values(Icon).len]?*c.SDL_Texture = @splat(null);

fn texture(r: *c.SDL_Renderer, gpa: std.mem.Allocator, ic: Icon) ?*c.SDL_Texture {
    const k = @backingInt(ic);
    if (textures[k]) |t| return t;
    const png = switch (ic) {
        inline else => |t| @embedFile("ui_" ++ @tagName(t)),
    };
    var img = og.formats.jpeg.decode(gpa, png) catch return null;
    defer img.deinit(gpa);
    const t = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, @intCast(img.width), @intCast(img.height)) orelse return null;
    _ = c.SDL_UpdateTexture(t, null, img.pixels.ptr, @intCast(img.width * 4));
    _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetTextureScaleMode(t, c.SDL_SCALEMODE_LINEAR);
    textures[k] = t;
    return t;
}

/// Icon `ic` as a `px`-point square, in `color`.
pub fn leaf(r: *c.SDL_Renderer, gpa: std.mem.Allocator, ic: Icon, px: f32, color: clay.Color) void {
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(px), .height = clay.fixed(px) } }, .image = .{ .imageData = texture(r, gpa, ic) }, .backgroundColor = color, .userData = &@import("render.zig").tinted });
}

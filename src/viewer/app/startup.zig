//! What the viewer loads at startup besides the archives: the window icon and
//! adjust.kdt settings (shadows, sound).

const std = @import("std");
const og = @import("opengorky");
const c = @import("sdl");

/// Window (and macOS Dock) icon: the project's own image (assets/icon-256.png),
/// embedded in the binary.
pub fn setWindowIcon(gpa: std.mem.Allocator, window: *c.SDL_Window) void {
    var img = og.formats.jpeg.decode(gpa, @embedFile("icon_png")) catch return;
    defer img.deinit(gpa);
    const surf = c.SDL_CreateSurfaceFrom(@intCast(img.width), @intCast(img.height), c.SDL_PIXELFORMAT_ABGR8888, img.pixels.ptr, @intCast(img.width * 4)) orelse return;
    defer c.SDL_DestroySurface(surf);
    _ = c.SDL_SetWindowIcon(window, surf);
}

/// Shadows are on unless adjust.kdt has disable_shadows != 0 (read by `adjust.load`).
pub fn loadShadows() bool {
    return og.formats.adjust.getInt("disable_shadows", 0) == 0;
}

/// Sound settings from adjust.kdt; the defaults without it.
pub fn loadSoundParams() og.audio.sound.Params {
    const adj = og.formats.adjust;
    var p: og.audio.sound.Params = .{};
    p.volume_start = adj.getFloat("sound_volume_start", p.volume_start);
    p.volume_falloff = adj.getFloat("sound_volume_falloff", p.volume_falloff);
    p.pan_start = adj.getFloat("sound_pan_start", p.pan_start);
    p.pan_factor = adj.getFloat("sound_pan_factor", p.pan_factor);
    p.dialog_sound = adj.getInt("dialog_sound_control", 1) != 0;
    return p;
}

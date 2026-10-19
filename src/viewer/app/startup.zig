//! What the viewer loads at startup besides the archives: the window icon and
//! adjust.kdt settings (shadows, sound).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
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

/// Shadows are on unless adjust.kdt has disable_shadows != 0.
pub fn loadShadows(io: Io, gpa: Allocator, game: Io.Dir) bool {
    const bytes = game.readFileAlloc(io, "adjust.kdt", gpa, .limited(1 << 20)) catch return true;
    defer gpa.free(bytes);
    var adj = og.formats.adjust.parse(gpa, bytes) catch return true;
    defer adj.deinit(gpa);
    return adj.int("disable_shadows", 0) == 0;
}

/// Sound settings from adjust.kdt; defaults on error.
pub fn loadSoundParams(io: Io, gpa: Allocator, game: Io.Dir) og.audio.sound.Params {
    var p: og.audio.sound.Params = .{};
    const bytes = game.readFileAlloc(io, "adjust.kdt", gpa, .limited(1 << 20)) catch return p;
    defer gpa.free(bytes);
    var adj = og.formats.adjust.parse(gpa, bytes) catch return p;
    defer adj.deinit(gpa);
    p.volume_start = adj.float("sound_volume_start", p.volume_start);
    p.volume_falloff = adj.float("sound_volume_falloff", p.volume_falloff);
    p.pan_start = adj.float("sound_pan_start", p.pan_start);
    p.pan_factor = adj.float("sound_pan_factor", p.pan_factor);
    p.dialog_sound = adj.int("dialog_sound_control", 1) != 0;
    return p;
}

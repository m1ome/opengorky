//! Event handler context shared by events.zig, keys.zig and mouse.zig.

const std = @import("std");
const og = @import("opengorky");
const c = @import("sdl");
const Options = @import("options.zig").Options;

pub const Flow = enum { next, quit };

/// What the handler needs from `viewer` besides `Viewer`, plus drag state.
pub const Ctx = struct {
    window: *c.SDL_Window,
    renderer: *c.SDL_Renderer,
    io: std.Io,
    mixer: *og.audio.mixer.Mixer,
    opts: *const Options,
    dragging: bool = false,
    drag_dist: f32 = 0,
    /// The UI took the press (the quick list closed on press), so the release of
    /// the same button must not reach the ground.
    press_ui: bool = false,
};

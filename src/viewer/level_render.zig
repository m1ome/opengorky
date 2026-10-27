//! A level drawn as the game draws it: its world composed (level/compose.zig: the
//! background, animations, models with depth, light and shadows) at the start of play —
//! the editor's preview. The scene stays loaded, so a part of it can be drawn again at a
//! finer detail (models rastered at the display's pixels, as the viewer's hires frame).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const compose = @import("level/compose.zig");

/// The video player (the editor's Videos page).
pub const Video = @import("media/video.zig").Video;

pub const Scene = struct {
    gpa: Allocator,
    world: *og.state.world.World,
    view: @import("level.zig").LevelView,

    /// Level `name` as `ticks` game ticks after it starts (a battle: its first turn's
    /// screen with no cells).
    pub fn init(io: Io, gpa: Allocator, r: *c.SDL_Renderer, dat: Io.Dir, models: *og.actor.model_cache.Cache, name: []const u8, ticks: u32) !*Scene {
        const w = try og.game.life.create(io, gpa, dat, name, models, .{});
        errdefer w.destroy();
        for (0..ticks) |_| og.game.tick(w) catch break;
        const s = try gpa.create(Scene);
        errdefer gpa.destroy(s);
        s.* = .{ .gpa = gpa, .world = w, .view = try compose.load(io, gpa, r, dat, w, null, models) };
        // No cursor, hover or battle cells: a window over the battle draws none (0x4b2fb0).
        s.view.window_top = true;
        if (s.view.size()[0] == 0) {
            s.view.deinit();
            return error.NoBackground;
        }
        return s;
    }

    pub fn deinit(self: *Scene) void {
        self.view.deinit();
        self.world.destroy();
        self.gpa.destroy(self);
    }

    pub fn size(self: *Scene) [2]u32 {
        return self.view.size();
    }

    /// Background rectangle `x, y, w, h` (its pixels) at `k` texture pixels per
    /// background pixel, into a new texture (the caller's): the models rastered at that
    /// detail, the pictures scaled.
    pub fn draw(self: *Scene, r: *c.SDL_Renderer, x: u32, y: u32, w: u32, h: u32, k: u32) !*c.SDL_Texture {
        // One band of the actor layer spans the rectangle's width, 480 rows a band.
        compose.setDetail(&self.view, k, w);
        const band_h = 480;
        const whole = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_TARGET, @intCast(w * k), @intCast(h * k)) orelse return error.Texture;
        errdefer c.SDL_DestroyTexture(whole);
        const band = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_TARGET, @intCast(w * k), @intCast(band_h * k)) orelse return error.Texture;
        defer c.SDL_DestroyTexture(band);
        const old = c.SDL_GetRenderTarget(r);
        defer _ = c.SDL_SetRenderTarget(r, old);
        const kf: f32 = @floatFromInt(k);
        var by: u32 = 0;
        while (by < h) : (by += band_h) {
            _ = c.SDL_SetRenderTarget(r, band);
            _ = c.SDL_SetRenderScale(r, kf, kf);
            _ = c.SDL_SetRenderDrawColor(r, 0, 0, 0, 255);
            _ = c.SDL_RenderClear(r);
            try compose.draw(&self.view, r, .{ @floatFromInt(x), @floatFromInt(y + by) }, .{ -10000, -10000 });
            _ = c.SDL_SetRenderScale(r, 1, 1);
            _ = c.SDL_SetRenderTarget(r, whole);
            _ = c.SDL_RenderTexture(r, band, null, &.{ .x = 0, .y = @floatFromInt(by * k), .w = @floatFromInt(w * k), .h = band_h * kf });
        }
        return whole;
    }
};

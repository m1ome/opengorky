//! Actor layer texture: creation per detail level, raster pool, upload of
//! changed parts.

const std = @import("std");
const level_view = @import("../level.zig");
const LevelView = level_view.LevelView;
const og = @import("opengorky");
const render_layer = og.render.layer;
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");
const Canvas = og.render.raster.Canvas;
const Io = std.Io;

/// Uploads part of an RGBA buffer of width `w` through SDL_LockTexture (SDL blits
/// it to the GPU texture). SDL_UpdateTexture on Metal writes from the CPU and
/// compresses (AGX processCompressedRegion) — a noticeable main-thread cost.
pub fn uploadRect(tex: *c.SDL_Texture, pixels: []const u8, w: usize, u: Canvas.Rect) !void {
    const rect: c.SDL_Rect = .{ .x = @intCast(u.x0), .y = @intCast(u.y0), .w = @intCast(u.x1 - u.x0), .h = @intCast(u.y1 - u.y0) };
    var dst: ?*anyopaque = null;
    var dpitch: c_int = 0;
    try gfx.check(c.SDL_LockTexture(tex, &rect, &dst, &dpitch));
    defer c.SDL_UnlockTexture(tex);
    const d: [*]u8 = @ptrCast(dst orelse return);
    const row_bytes = (@as(usize, u.x1) - u.x0) * 4;
    const dp: usize = @intCast(dpitch);
    for (u.y0..u.y1, 0..) |y, i| {
        const s = (y * w + u.x0) * 4;
        @memcpy(d[i * dp ..][0..row_bytes], pixels[s..][0..row_bytes]);
    }
}

/// Merges overlapping rectangles (into their bounding box) until none overlap,
/// so each pixel uploads once. Returns the new count.
pub fn mergeRects(rs: []Canvas.Rect) usize {
    var n = rs.len;
    var changed = true;
    while (changed) {
        changed = false;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var j = i + 1;
            while (j < n) {
                const a = rs[i];
                const b = rs[j];
                if (a.x0 < b.x1 and b.x0 < a.x1 and a.y0 < b.y1 and b.y0 < a.y1) {
                    rs[i] = a.join(b);
                    rs[j] = rs[n - 1];
                    n -= 1;
                    changed = true;
                } else j += 1;
            }
        }
    }
    return n;
}

/// Model raster pool: one per process, threads by core count (at most
/// Canvas.max_threads), tasks run on the Io (std.Io.Group).
pub fn rasterPool(io: Io) *og.render.raster.Canvas.Pool {
    const S = struct {
        var pool: og.render.raster.Canvas.Pool = undefined;
        var ready = false;
    };
    if (!S.ready) {
        S.pool = .{ .io = io };
        S.pool.init(std.math.clamp(std.Thread.getCpuCount() catch 1, 1, og.render.raster.Canvas.max_threads));
        S.ready = true;
    }
    return &S.pool;
}

/// Actor layer and its textures, `ss` times finer than the 640×480 screen.
pub fn makeLayer(self: *LevelView, ss: u32) !void {
    const r = self.renderer;
    if (self.layer) |*l| l.deinit(self.gpa);
    self.layer = null;
    if (self.layer_tex) |t| c.SDL_DestroyTexture(t);
    if (self.glow_tex) |t| c.SDL_DestroyTexture(t);
    if (self.screen_tex) |t| c.SDL_DestroyTexture(t);
    self.layer_tex = null;
    self.glow_tex = null;
    self.screen_tex = null;
    self.layer = try render_layer.Layer.initScaled(self.gpa, 640, 480, ss);
    self.ss = ss;
    // New texture has undefined contents: the first upload is whole.
    self.tex_regions[0] = .{ .x0 = 0, .y0 = 0, .x1 = 640 * ss, .y1 = 480 * ss };
    self.n_tex_regions = 1;
    const w: c_int = @intCast(640 * ss);
    const h: c_int = @intCast(480 * ss);
    self.layer_tex = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STREAMING, w, h);
    if (self.layer_tex) |t| {
        _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetTextureScaleMode(t, c.SDL_SCALEMODE_NEAREST);
    }
    self.glow_tex = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STREAMING, w, h);
    if (self.glow_tex) |t| {
        _ = c.SDL_SetTextureBlendMode(t, gfx.blendAdd());
        _ = c.SDL_SetTextureScaleMode(t, c.SDL_SCALEMODE_NEAREST);
    }
    self.screen_tex = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STREAMING, w, h);
    if (self.screen_tex) |t| {
        // ONE / INVSRCCOLOR (0x408ad0 mode 4).
        _ = c.SDL_SetTextureBlendMode(t, c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_COLOR, c.SDL_BLENDOPERATION_ADD, c.SDL_BLENDFACTOR_ZERO, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDOPERATION_ADD));
        _ = c.SDL_SetTextureScaleMode(t, c.SDL_SCALEMODE_NEAREST);
    }
}

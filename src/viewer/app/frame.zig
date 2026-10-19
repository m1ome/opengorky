//! Viewer frame: detail (hires, auto-lowering), scaling to the window, begin/present, gamma, skipping identical frames.

const std = @import("std");
const og = @import("opengorky");
const viewer = @import("viewer.zig");
const Viewer = viewer.Viewer;
const FrameSig = Viewer.FrameSig;
const c = @import("sdl");
const screen_w = viewer.screen_w;
const screen_h = viewer.screen_h;
const builtin = @import("builtin");
const perf = @import("perf.zig");
const gfx = @import("../media/gfx.zig");

pub fn frameSame(self: *Viewer) bool {
    if (ownTimeOnScreen(self)) {
        self.last_sig = null;
        return false;
    }
    const l = &self.level.?;
    const sig: FrameSig = .{ .level = @intFromPtr(l.world), .ticks = l.world.ticks, .scroll = self.scroll, .mouse = self.mouse, .zoom = self.zoom, .ss = self.detail.k };
    defer self.last_sig = sig;
    const prev = self.last_sig orelse return false;
    return std.meta.eql(prev, sig);
}
fn ownTimeOnScreen(self: *Viewer) bool {
    if (self.level == null or self.video != null or self.transition != null or self.console.open or self.safeOpen()) return true;
    if (self.menu) |m| if (m.open) return true;
    if (self.inventory) |inv| if (inv.open) return true;
    if (self.gui) |g| if (g.go_frame != null or g.go_capture) return true;
    return self.message != null and c.SDL_GetTicks() < self.message_until + 100;
}
pub fn applyScaling(self: *Viewer) void {
    const r = self.renderer;
    _ = c.SDL_SetRenderLogicalPresentation(r, screen_w, screen_h, if (self.cfg.scaling == .integer) c.SDL_LOGICAL_PRESENTATION_INTEGER_SCALE else c.SDL_LOGICAL_PRESENTATION_LETTERBOX);
    const t = self.frame_tex orelse return;
    const sharp = if (@hasDecl(c, "SDL_SCALEMODE_PIXELART")) c.SDL_SCALEMODE_PIXELART else c.SDL_SCALEMODE_LINEAR;
    _ = c.SDL_SetTextureScaleMode(t, switch (self.cfg.scaling) {
        .integer => c.SDL_SCALEMODE_NEAREST,
        .sharp => sharp,
        .smooth => c.SDL_SCALEMODE_LINEAR,
    });
}
/// Frame detail for the window: an integer zoom's factor (frame shown 1:1),
/// otherwise the nearest integer not below window / 640×480 (the frame is scaled
/// down slightly). At most 4; at most 3 in a debug build (software model
/// raster is slower).
fn wantDetail(self: *Viewer) u32 {
    if (self.detail.force > 0) return @min(self.detail.force, 4);
    if (!self.detail.auto or !self.cfg.hires) return 1;
    var w: c_int = 0;
    var h: c_int = 0;
    if (!c.SDL_GetRenderOutputSize(self.renderer, &w, &h)) return 1;
    const k = @min(og.num.toF32(w) / screen_w, og.num.toF32(h) / screen_h);
    const want = if (self.cfg.scaling == .integer) @floor(k + 0.001) else @ceil(k - 0.05);
    const max: f32 = @floatFromInt(@min(self.detail.cap, if (builtin.mode == .debug) 3 else 4));
    return @intFromFloat(std.math.clamp(want, 1, max));
}
/// Frame too slow (work over 30 ms on average over half a second, twice in a row):
/// lower the detail one step to keep ≥ 30 fps on a slow machine or in a debug
/// build. Window-based detail only (not `--hires`).
pub fn adaptDetail(self: *Viewer) void {
    if (perf.window == self.detail.perf_window) return;
    self.detail.perf_window = perf.window;
    if (self.detail.force > 0 or !self.detail.auto or self.detail.k <= 1) return;
    // Two windows in a row, so a one-off spike (level load) doesn't count.
    self.detail.perf_bad = if (perf.work() > 30) self.detail.perf_bad + 1 else 0;
    if (self.detail.perf_bad >= 2) {
        self.detail.perf_bad = 0;
        self.detail.cap = self.detail.k - 1;
        std.log.info("frame {d:.1} ms — detail {d} → {d}", .{ perf.work(), self.detail.k, self.detail.cap });
    }
}
/// Begins a frame: draw into the frame texture (if it was created).
pub fn beginFrame(self: *Viewer) void {
    const r = self.renderer;
    const ss = wantDetail(self);
    if (self.frame_tex != null and ss != self.detail.k) {
        c.SDL_DestroyTexture(self.frame_tex);
        self.frame_tex = null;
        if (self.zoom_tex) |t| c.SDL_DestroyTexture(t);
        self.zoom_tex = null;
        if (self.gamma_tex) |t| c.SDL_DestroyTexture(t);
        self.gamma_tex = null;
    }
    if (self.frame_tex == null) {
        self.frame_tex = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_TARGET, @intCast(screen_w * ss), @intCast(screen_h * ss));
        if (self.frame_tex) |t| _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_NONE);
        self.detail.k = if (self.frame_tex != null) ss else 1;
        applyScaling(self);
    }
    // UI sprites: smoothing K× upscale (`upscale = xbr`).
    gfx.upscale_k = if (self.cfg.upscale == .xbr) self.detail.k else 1;
    if (self.frame_tex) |t| {
        _ = c.SDL_SetRenderTarget(r, t);
        const f: f32 = @floatFromInt(self.detail.k);
        _ = c.SDL_SetRenderScale(r, f, f);
    }
}
/// Presents the frame in the window (with borders).
pub fn presentFrame(self: *Viewer) !void {
    const r = self.renderer;
    if (self.frame_tex) |t| {
        try viewer.check(c.SDL_SetRenderTarget(r, null));
        try viewer.check(c.SDL_SetRenderDrawColor(r, 0, 0, 0, 255));
        try viewer.check(c.SDL_RenderClear(r));
        try viewer.check(c.SDL_RenderTexture(r, t, null, null));
    }
    if (self.window_shot) |path| {
        self.window_shot = null;
        self.screenshot(path) catch |err| std.log.warn("shot {s}: {t}", .{ path, err });
    }
    try viewer.check(c.SDL_RenderPresent(r));
}

/// Gamma (0x4065e0): `ramp[i] = (i/255)^(1/g)`, g = value/100, at least 0.1;
/// SDL3 has no gamma ramp, so the table is applied to the finished frame.
pub fn applyGamma(self: *Viewer) void {
    if (@abs(self.gamma - 100) < 0.5) return;
    const r = self.renderer;
    if (self.gamma_lut_for != self.gamma) {
        const g = @max(self.gamma / 100, 0.1);
        for (&self.gamma_lut, 0..) |*e, i| e.* = @intFromFloat(@round(255 * std.math.pow(f32, og.num.toF32(i) / 255, 1 / g)));
        self.gamma_lut_for = self.gamma;
    }
    const surf = gfx.readFrame(r) orelse return;
    defer c.SDL_DestroySurface(surf);
    const w: usize = @intCast(surf.*.w);
    const h: usize = @intCast(surf.*.h);
    const px: [*]u8 = @ptrCast(surf.*.pixels.?);
    const pitch: usize = @intCast(surf.*.pitch);
    for (0..h) |y| for (0..w) |x| {
        const p = px + y * pitch + x * 4;
        for (0..3) |k| p[k] = self.gamma_lut[p[k]];
    };
    if (self.gamma_tex) |gt| {
        var tw: f32 = 0;
        var th: f32 = 0;
        _ = c.SDL_GetTextureSize(gt, &tw, &th);
        if (tw != og.num.toF32(w) or th != og.num.toF32(h)) {
            c.SDL_DestroyTexture(gt);
            self.gamma_tex = null;
        }
    }
    if (self.gamma_tex == null) self.gamma_tex = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STREAMING, @intCast(w), @intCast(h));
    const t = self.gamma_tex orelse return;
    _ = c.SDL_UpdateTexture(t, null, surf.*.pixels, surf.*.pitch);
    _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_NONE);
    _ = c.SDL_RenderTexture(r, t, null, null);
}

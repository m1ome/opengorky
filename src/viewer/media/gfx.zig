//! SDL helpers for the viewer: textures from game resources.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const Image = og.formats.image.Image;
const sprite = og.formats.sprite;
const shadow = @import("shadow.zig");

const SdlError = error{Sdl};

/// 0–255 colour as 0–1 floats (correctly rounded, same as `N.0 / 255.0`).
pub fn rgb(comptime r: u8, comptime g: u8, comptime b: u8) [3]f32 {
    return comptime .{ @as(f32, r) / 255.0, @as(f32, g) / 255.0, @as(f32, b) / 255.0 };
}

/// Atlas source rectangle of a texture-font glyph.
pub fn glyphSrc(g: og.formats.font.TexGlyph) [4]f32 {
    return .{ og.num.toF32(g.x), og.num.toF32(g.y), og.num.toF32(g.w), og.num.toF32(g.h) };
}

/// Width of `t` in a texture font: advances plus `spacing` between glyphs.
pub fn texTextWidth(glyphs: *const [256]?og.formats.font.TexGlyph, t: []const u8, spacing: f32) f32 {
    var w: f32 = 0;
    for (t) |ch| if (glyphs[ch]) |g| {
        w += og.num.toF32(g.advance) + spacing;
    };
    if (t.len > 0) w -= spacing;
    return w;
}

/// Fills `rect` with `rgba`; the draw colour stays set.
pub fn fillRect(r: *c.SDL_Renderer, rgba: [4]u8, rect: c.SDL_FRect) SdlError!void {
    try check(c.SDL_SetRenderDrawColor(r, rgba[0], rgba[1], rgba[2], rgba[3]));
    try check(c.SDL_RenderFillRect(r, &rect));
}

pub fn check(ok: bool) SdlError!void {
    if (!ok) {
        std.log.err("SDL: {s}", .{c.SDL_GetError()});
        return error.Sdl;
    }
}

/// Tile highlight and name-entry cursor pulse (0x45c8a0): min + (max − min)·(sin(phase) + 1)/2,
/// tile_flash_min/max 0.2/0.4; the phase grows by tile_flash_step 0.15 per logic tick.
pub fn tilePulse(phase: f32) f32 {
    return 0.2 + 0.2 * (@sin(phase) + 1) * 0.5;
}
pub const tile_flash_step = 0.15;

/// Additive colour; destination alpha unchanged.
pub fn blendAdd() c.SDL_BlendMode {
    return c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDOPERATION_ADD, c.SDL_BLENDFACTOR_ZERO, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDOPERATION_ADD);
}

/// Recreates texture `slot` from an image and draws it full screen.
pub fn drawImage(r: *c.SDL_Renderer, slot: *?*c.SDL_Texture, img: Image) SdlError!void {
    try check(c.SDL_RenderTexture(r, try reuseTexture(r, slot, img), null, null));
}

/// Texture `slot` with pixels `img`: updated in place when the size matches
/// (windows and text are redrawn every frame).
pub fn reuseTexture(r: *c.SDL_Renderer, slot: *?*c.SDL_Texture, img: Image) SdlError!*c.SDL_Texture {
    if (slot.*) |old| {
        var w: f32 = 0;
        var h: f32 = 0;
        if (c.SDL_GetTextureSize(old, &w, &h) and w == og.num.toF32(img.width) and h == og.num.toF32(img.height)) {
            try check(c.SDL_UpdateTexture(old, null, img.pixels.ptr, @intCast(img.width * 4)));
            return old;
        }
        c.SDL_DestroyTexture(old);
    }
    slot.* = null;
    slot.* = try textureFromImage(r, img);
    return slot.*.?;
}

pub fn textureFromImage(r: *c.SDL_Renderer, img: Image) SdlError!*c.SDL_Texture {
    // ABGR8888 on little-endian: bytes R, G, B, A, as in Image.
    const tex = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, @intCast(img.width), @intCast(img.height)) orelse {
        try check(false);
        unreachable;
    };
    errdefer c.SDL_DestroyTexture(tex);
    try check(c.SDL_UpdateTexture(tex, null, img.pixels.ptr, @intCast(img.width * 4)));
    try check(c.SDL_SetTextureBlendMode(tex, c.SDL_BLENDMODE_BLEND));
    try check(c.SDL_SetTextureScaleMode(tex, c.SDL_SCALEMODE_NEAREST));
    return tex;
}

/// `.3df` texture for a 3D primitive (effects, grid, arrows, projectile meshes,
/// battle text): before a frame the exe sets LINEAR filtering (0x42090d → 0x406d50:
/// SetRenderState TEXTUREMIN 0x12 and TEXTUREMAG 0x11 = 2; stage 0 the same —
/// 0x40ab5a…0x40ab9c) if the device supports it (+0x60 of the caps, 0x406881) —
/// any hardware one. Background and UI are DirectDraw 1:1 blits, unfiltered.
pub fn textureLinear(r: *c.SDL_Renderer, img: Image) SdlError!*c.SDL_Texture {
    const tex = try textureFromImage(r, img);
    try check(c.SDL_SetTextureScaleMode(tex, c.SDL_SCALEMODE_LINEAR));
    return tex;
}

/// Detail factor of the current frame (`hires` 1…4) when smoothing 2D upscale is on
/// (`upscale = xbr`); 1 — UI sprites draw as is (unsmoothed upscale). Set by the
/// viewer at frame start.
/// shortcut: global render setting read by every Frames.texture call; pass it explicitly if a second window is ever needed.
pub var upscale_k: u32 = 1;

/// Frame set (a background has one frame).
pub const Frames = struct {
    textures: std.ArrayList(*c.SDL_Texture) = .empty,
    sizes: std.ArrayList([2]u32) = .empty,
    /// UI sprite: with `upscale_k` > 1 the frame is drawn from a copy upscaled by
    /// xBR (`og.formats.xbr`) exactly `upscale_k` times, which lands 1:1 in a detail K
    /// frame. The copy is built on first draw and lives until K changes.
    smooth: bool = false,
    /// Source frames (`smooth` only).
    sources: std.ArrayList(Image) = .empty,
    /// Upscaled copies and their factor (0 — none yet).
    hi: std.ArrayList(?*c.SDL_Texture) = .empty,
    hi_k: std.ArrayList(u8) = .empty,
    /// Icon shadows (`drawShadow`), built on first draw (`smooth` only).
    shadows: std.ArrayList(?*c.SDL_Texture) = .empty,

    pub fn deinit(self: *Frames, gpa: Allocator) void {
        for (self.textures.items) |t| c.SDL_DestroyTexture(t);
        for (self.hi.items) |t| if (t) |x| c.SDL_DestroyTexture(x);
        for (self.shadows.items) |t| if (t) |x| c.SDL_DestroyTexture(x);
        for (self.sources.items) |*img| img.deinit(gpa);
        self.textures.deinit(gpa);
        self.sizes.deinit(gpa);
        self.sources.deinit(gpa);
        self.hi.deinit(gpa);
        self.hi_k.deinit(gpa);
        self.shadows.deinit(gpa);
        self.* = .{};
    }

    /// Frame texture to draw and its factor: the upscaled copy when `upscale_k` > 1
    /// (with the source's colour, alpha and blend), else the source.
    fn texture(self: Frames, r: *c.SDL_Renderer, frame: usize) struct { *c.SDL_Texture, f32 } {
        const base = self.textures.items[frame];
        const k = upscale_k;
        if (!self.smooth or k <= 1 or frame >= self.sources.items.len) return .{ base, 1 };
        if (self.hi_k.items[frame] != k) {
            if (self.hi.items[frame]) |old| c.SDL_DestroyTexture(old);
            self.hi.items[frame] = null;
            self.hi_k.items[frame] = @intCast(k);
            // Temporary image freed right here, so no own allocator is needed.
            const gpa = std.heap.smp_allocator;
            if (og.formats.xbr.upscale(gpa, self.sources.items[frame], k)) |big| {
                var img = big;
                defer img.deinit(gpa);
                self.hi.items[frame] = textureFromImage(r, img) catch null;
            } else |_| {}
        }
        const t = self.hi.items[frame] orelse return .{ base, 1 };
        var cr: u8 = 255;
        var cg: u8 = 255;
        var cb: u8 = 255;
        var a: f32 = 1;
        var mode: c.SDL_BlendMode = c.SDL_BLENDMODE_BLEND;
        _ = c.SDL_GetTextureColorMod(base, &cr, &cg, &cb);
        _ = c.SDL_GetTextureAlphaModFloat(base, &a);
        _ = c.SDL_GetTextureBlendMode(base, &mode);
        _ = c.SDL_SetTextureColorMod(t, cr, cg, cb);
        _ = c.SDL_SetTextureAlphaModFloat(t, a);
        _ = c.SDL_SetTextureBlendMode(t, mode);
        return .{ t, @floatFromInt(k) };
    }

    pub fn len(self: Frames) usize {
        return self.textures.items.len;
    }

    fn add(self: *Frames, gpa: Allocator, r: *c.SDL_Renderer, img: Image) !void {
        const tex = try textureFromImage(r, img);
        errdefer c.SDL_DestroyTexture(tex);
        try self.textures.ensureUnusedCapacity(gpa, 1);
        try self.sizes.ensureUnusedCapacity(gpa, 1);
        if (self.smooth) {
            try self.sources.ensureUnusedCapacity(gpa, 1);
            try self.hi.ensureUnusedCapacity(gpa, 1);
            try self.hi_k.ensureUnusedCapacity(gpa, 1);
            try self.shadows.ensureUnusedCapacity(gpa, 1);
            const copy: Image = .{ .width = img.width, .height = img.height, .pixels = try gpa.dupe(u8, img.pixels) };
            self.sources.appendAssumeCapacity(copy);
            self.hi.appendAssumeCapacity(null);
            self.hi_k.appendAssumeCapacity(0);
            self.shadows.appendAssumeCapacity(null);
        }
        self.textures.appendAssumeCapacity(tex);
        self.sizes.appendAssumeCapacity(.{ img.width, img.height });
    }

    pub fn draw(self: Frames, r: *c.SDL_Renderer, frame: usize, x: f32, y: f32) SdlError!void {
        const size = self.sizes.items[frame];
        const dst: c.SDL_FRect = .{ .x = x, .y = y, .w = @floatFromInt(size[0]), .h = @floatFromInt(size[1]) };
        const tex, _ = self.texture(r, frame);
        try check(c.SDL_RenderTexture(r, tex, null, &dst));
    }

    /// Icon shadow (0x47d7b0 → 0x41bdb0, `shadow.zig`) under a frame drawn at
    /// (x, y): 3 px lower. Drawn before the frame itself.
    fn drawShadow(self: *Frames, r: *c.SDL_Renderer, frame: usize, x: f32, y: f32) SdlError!void {
        if (frame >= self.shadows.items.len) return;
        const src = self.sources.items[frame];
        if (self.shadows.items[frame] == null) {
            const gpa = std.heap.smp_allocator;
            const px = shadow.build(gpa, src.width, src.height, src.pixels) catch return;
            defer gpa.free(px);
            self.shadows.items[frame] = textureFromImage(r, .{ .width = src.width, .height = src.height, .pixels = px }) catch return;
        }
        const dst: c.SDL_FRect = .{ .x = x, .y = y + 3, .w = @floatFromInt(src.width), .h = @floatFromInt(src.height) };
        try check(c.SDL_RenderTexture(r, self.shadows.items[frame].?, null, &dst));
    }

    /// Icon with its shadow (0x47d7b0, then the frame).
    pub fn drawShadowed(self: *Frames, r: *c.SDL_Renderer, frame: usize, x: f32, y: f32) SdlError!void {
        try self.drawShadow(r, frame, x, y);
        try self.draw(r, frame, x, y);
    }

    /// Left (top) edge of a frame of size `size` centred on the span from `l` of
    /// length `span` (0x47d6a0: integer division truncating toward zero).
    pub fn center(l: f32, span: f32, size: u32) f32 {
        return l + @trunc((span - og.num.toF32(size)) / 2);
    }

    /// Part `src` (x, y, w, h) of a frame at (x, y): font atlas glyphs.
    pub fn drawPart(self: Frames, r: *c.SDL_Renderer, frame: usize, src: [4]f32, x: f32, y: f32) SdlError!void {
        const tex, const k = self.texture(r, frame);
        const s: c.SDL_FRect = .{ .x = src[0] * k, .y = src[1] * k, .w = src[2] * k, .h = src[3] * k };
        const dst: c.SDL_FRect = .{ .x = x, .y = y, .w = src[2], .h = src[3] };
        try check(c.SDL_RenderTexture(r, tex, &s, &dst));
    }

    /// Frame clipped on the right to width `w` (bars).
    pub fn drawClipped(self: Frames, r: *c.SDL_Renderer, frame: usize, x: f32, y: f32, w: f32) SdlError!void {
        const size = self.sizes.items[frame];
        const fw: f32 = @min(w, og.num.toF32(size[0]));
        if (fw <= 0) return;
        const h: f32 = @floatFromInt(size[1]);
        const tex, const k = self.texture(r, frame);
        const src: c.SDL_FRect = .{ .x = 0, .y = 0, .w = fw * k, .h = h * k };
        const dst: c.SDL_FRect = .{ .x = x, .y = y, .w = fw, .h = h };
        try check(c.SDL_RenderTexture(r, tex, &src, &dst));
    }
};

/// Decodes a resource (sprite, bkg, jpg) into frames.
pub fn loadFrames(gpa: Allocator, r: *c.SDL_Renderer, name: []const u8, data: []const u8) !Frames {
    return loadFramesAs(gpa, r, name, data, false);
}

/// UI sprite (icons, portraits, panels, cursor): with frame detail > 1 and
/// `upscale = xbr` drawn from an upscaled xBR copy (`Frames.smooth`).
pub fn loadSmooth(gpa: Allocator, r: *c.SDL_Renderer, name: []const u8, data: []const u8) !Frames {
    return loadFramesAs(gpa, r, name, data, true);
}

fn loadFramesAs(gpa: Allocator, r: *c.SDL_Renderer, name: []const u8, data: []const u8, smooth: bool) !Frames {
    var frames: Frames = .{ .smooth = smooth };
    errdefer frames.deinit(gpa);
    switch (og.formats.resource.kindOf(name)) {
        .sprite => {
            var spr = try sprite.parse(gpa, data);
            defer spr.deinit(gpa);
            for (spr.frames) |f| {
                var img = try sprite.decodeFrame(gpa, f);
                defer img.deinit(gpa);
                try frames.add(gpa, r, img);
            }
        },
        .background => {
            var img = try og.formats.background.decode(gpa, data);
            defer img.deinit(gpa);
            try frames.add(gpa, r, img);
        },
        .jpeg => {
            var img = try og.formats.jpeg.decode(gpa, data);
            defer img.deinit(gpa);
            try frames.add(gpa, r, img);
        },
        .zbuffer => {
            var z = try og.formats.zbuffer.decode(gpa, data);
            defer z.deinit(gpa);
            var img = try z.toImage(gpa);
            defer img.deinit(gpa);
            try frames.add(gpa, r, img);
        },
        .texture => {
            var img = try og.formats.tex3df.decode(gpa, data);
            defer img.deinit(gpa);
            try frames.add(gpa, r, img);
        },
        .audio, .other => return error.UnsupportedResource,
    }
    return frames;
}

/// Frame copy in memory as ABGR8888 (bytes RGBA); free with SDL_DestroySurface.
pub fn readFrame(r: *c.SDL_Renderer) ?*c.SDL_Surface {
    const raw = c.SDL_RenderReadPixels(r, null) orelse return null;
    if (raw.*.format == c.SDL_PIXELFORMAT_ABGR8888) return raw;
    defer c.SDL_DestroySurface(raw);
    return c.SDL_ConvertSurface(raw, c.SDL_PIXELFORMAT_ABGR8888);
}

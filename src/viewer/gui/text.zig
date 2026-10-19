//! Texture cache for UI text.

const std = @import("std");
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");

/// Font identity for the cache key: address of the first glyph's pixels and height.
pub fn fontId(f: og.formats.font.Font) [2]usize {
    for (f.glyphs) |g| if (g) |x| return .{ @intFromPtr(x.pixels.ptr), f.height };
    return .{ 0, f.height };
}

/// Text textures keyed by (string, colour, font) hash; the least recently used
/// entry is evicted when full.
pub const TextCache = struct {
    const Entry = struct { key: u64, tex: *c.SDL_Texture, used: u64 };
    entries: [96]?Entry = @splat(null),
    clock: u64 = 0,

    pub fn get(self: *TextCache, key: u64) ?*c.SDL_Texture {
        self.clock += 1;
        for (&self.entries) |*e| if (e.*) |*x| if (x.key == key) {
            x.used = self.clock;
            return x.tex;
        };
        return null;
    }

    pub fn put(self: *TextCache, r: *c.SDL_Renderer, key: u64, img: og.formats.image.Image) !*c.SDL_Texture {
        const tex = try gfx.textureFromImage(r, img);
        var slot: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (self.entries, 0..) |e, i| {
            const u = if (e) |x| x.used else 0;
            if (u < oldest) {
                oldest = u;
                slot = i;
            }
        }
        if (self.entries[slot]) |old| c.SDL_DestroyTexture(old.tex);
        self.entries[slot] = .{ .key = key, .tex = tex, .used = self.clock };
        return tex;
    }

    pub fn deinit(self: *TextCache) void {
        for (&self.entries) |*e| if (e.*) |x| {
            c.SDL_DestroyTexture(x.tex);
            e.* = null;
        };
    }
};

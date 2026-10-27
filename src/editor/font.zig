//! Editor text: PT Sans (regular, bold, italic) baked by stb_truetype into one atlas at a
//! few sizes, Latin and Cyrillic. Sizes are in points; glyphs are baked at
//! points × pixel density so text stays sharp on HiDPI screens.

const std = @import("std");
const c = @import("sdl");
const ui = @import("ui");

const files = [_][]const u8{ @embedFile("font_regular"), @embedFile("font_bold"), @embedFile("font_italic") };
pub const regular = 0;
pub const bold = 1;
/// A preview tab's name (as editors show one not kept yet).
pub const italic = 2;
/// Baked sizes in points; other sizes use the nearest.
pub const sizes = [_]u16{ 13, 15, 18 };
/// Code point ranges (start, count): ASCII, Latin-1 (×, «»), Cyrillic, punctuation (—, …).
const ranges = [_][2]u32{ .{ 32, 95 }, .{ 0xa0, 0x60 }, .{ 0x400, 0x60 }, .{ 0x2010, 0x18 } };
const n_chars = 95 + 0x60 + 0x60 + 0x18;
const atlas = 1280;

pub const Font = struct {
    tex: *c.SDL_Texture,
    density: f32,
    /// [font][size][range] glyphs.
    chars: [files.len][sizes.len][n_chars]ui.stbtt_packedchar,
    /// Line height and ascent per [font][size], in points.
    line: [files.len][sizes.len]f32,
    ascent: [files.len][sizes.len]f32,

    pub fn init(gpa: std.mem.Allocator, r: *c.SDL_Renderer, density: f32) !*Font {
        const self = try gpa.create(Font);
        errdefer gpa.destroy(self);
        self.density = density;
        const side: c_int = @intFromFloat(@ceil(atlas * @min(density, 2)));
        const alpha = try gpa.alloc(u8, @intCast(side * side));
        defer gpa.free(alpha);
        var pc: ui.stbtt_pack_context = undefined;
        if (ui.stbtt_PackBegin(&pc, alpha.ptr, side, side, 0, 1, null) == 0) return error.FontPack;
        ui.stbtt_PackSetOversampling(&pc, 1, 1);
        for (files, 0..) |ttf, fi| {
            var info: ui.stbtt_fontinfo = undefined;
            if (ui.stbtt_InitFont(&info, ttf.ptr, 0) == 0) return error.FontInit;
            var asc: c_int = 0;
            var desc: c_int = 0;
            var gap: c_int = 0;
            ui.stbtt_GetFontVMetrics(&info, &asc, &desc, &gap);
            for (sizes, 0..) |pt, si| {
                const px = @as(f32, @floatFromInt(pt)) * density;
                var at: usize = 0;
                for (ranges) |rg| {
                    const n: c_int = @intCast(rg[1]);
                    if (ui.stbtt_PackFontRange(&pc, ttf.ptr, 0, px, @intCast(rg[0]), n, &self.chars[fi][si][at]) == 0) return error.FontAtlasFull;
                    at += rg[1];
                }
                const k = ui.stbtt_ScaleForPixelHeight(&info, px);
                self.line[fi][si] = @as(f32, @floatFromInt(asc - desc + gap)) * k / density;
                self.ascent[fi][si] = @as(f32, @floatFromInt(asc)) * k / density;
            }
        }
        ui.stbtt_PackEnd(&pc);
        // White RGBA with the coverage as alpha: SDL tints it with the color mod.
        const rgba = try gpa.alloc(u8, alpha.len * 4);
        defer gpa.free(rgba);
        for (alpha, 0..) |a, i| rgba[i * 4 ..][0..4].* = .{ 255, 255, 255, a };
        self.tex = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, side, side) orelse return error.Texture;
        _ = c.SDL_UpdateTexture(self.tex, null, rgba.ptr, side * 4);
        _ = c.SDL_SetTextureBlendMode(self.tex, c.SDL_BLENDMODE_BLEND);
        return self;
    }

    pub fn deinit(self: *Font, gpa: std.mem.Allocator) void {
        c.SDL_DestroyTexture(self.tex);
        gpa.destroy(self);
    }

    fn sizeIndex(pt: u16) usize {
        var best: usize = 0;
        for (sizes, 0..) |s, i| {
            if (@abs(@as(i32, s) - pt) < @abs(@as(i32, sizes[best]) - pt)) best = i;
        }
        return best;
    }

    fn glyph(cp: u21) ?usize {
        var at: usize = 0;
        for (ranges) |rg| {
            if (cp >= rg[0] and cp < rg[0] + rg[1]) return at + (cp - rg[0]);
            at += rg[1];
        }
        return null;
    }

    /// Width and line height of UTF-8 `text`, in points.
    pub fn measure(self: *const Font, text: []const u8, font_id: u16, pt: u16) [2]f32 {
        const fi = @min(font_id, files.len - 1);
        const si = sizeIndex(pt);
        var w: f32 = 0;
        var it = (std.unicode.Utf8View.init(text) catch return .{ 0, self.line[fi][si] }).iterator();
        while (it.nextCodepoint()) |cp| {
            const g = glyph(cp) orelse glyph('?').?;
            w += self.chars[fi][si][g].xadvance;
        }
        return .{ w / self.density, self.line[fi][si] };
    }

    /// Draws `text` with its top-left at (x, y) points.
    pub fn draw(self: *const Font, r: *c.SDL_Renderer, text: []const u8, font_id: u16, pt: u16, x: f32, y: f32, rgba: [4]u8) void {
        const fi = @min(font_id, files.len - 1);
        const si = sizeIndex(pt);
        _ = c.SDL_SetTextureColorMod(self.tex, rgba[0], rgba[1], rgba[2]);
        _ = c.SDL_SetTextureAlphaMod(self.tex, rgba[3]);
        const side: c_int = @intFromFloat(@ceil(atlas * @min(self.density, 2)));
        var px: f32 = x * self.density;
        const py: f32 = (y + self.ascent[fi][si]) * self.density;
        var it = (std.unicode.Utf8View.init(text) catch return).iterator();
        while (it.nextCodepoint()) |cp| {
            const g = glyph(cp) orelse glyph('?').?;
            var q: ui.stbtt_aligned_quad = undefined;
            var gy = py;
            ui.stbtt_GetPackedQuad(&self.chars[fi][si], side, side, @intCast(g), &px, &gy, &q, 0);
            const d = self.density;
            const src: c.SDL_FRect = .{ .x = q.s0 * @as(f32, @floatFromInt(side)), .y = q.t0 * @as(f32, @floatFromInt(side)), .w = (q.s1 - q.s0) * @as(f32, @floatFromInt(side)), .h = (q.t1 - q.t0) * @as(f32, @floatFromInt(side)) };
            const dst: c.SDL_FRect = .{ .x = q.x0 / d, .y = q.y0 / d, .w = (q.x1 - q.x0) / d, .h = (q.y1 - q.y0) / d };
            _ = c.SDL_RenderTexture(r, self.tex, &src, &dst);
        }
    }
};

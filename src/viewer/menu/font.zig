//! Menu textures (.3df) and the menu texture font "3D font" (0x47ad40).

const std = @import("std");
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const archive = og.formats.archive;

/// "3D font" glyph (0x47ad40): a rectangle on a 256×256 page.
const Glyph = struct { x: f32, y: f32, w: f32, h: f32, page: u1 };

/// Menu texture font: two pages, letter spacing −6 (0x47ab50).
pub const MenuFont = struct {
    pages: [2]?*c.SDL_Texture = .{ null, null },
    glyphs: [256]?Glyph = @splat(null),
    space: f32 = 14,

    const spacing: f32 = -6;

    pub fn deinit(self: *MenuFont) void {
        if (self.pages[0]) |t| c.SDL_DestroyTexture(t);
        if (self.pages[1] != null and self.pages[1] != self.pages[0]) c.SDL_DestroyTexture(self.pages[1].?);
    }

    fn glyph(self: *const MenuFont, ch: u8) ?Glyph {
        return self.glyphs[std.ascii.toLower(ch)];
    }

    /// Width without scale (0x47b160 with flag 1).
    pub fn width(self: *const MenuFont, text: []const u8) f32 {
        var w: f32 = 0;
        for (text) |ch| w += if (self.glyph(ch)) |g| g.w + spacing else self.space;
        return w;
    }

    /// Text centred on `cx`, baseline `y` (0x47abe0): cell (w+1)×(h+1)·s,
    /// baseline at ¾ of the cell; a scaled glyph grows around its cell.
    pub fn draw(self: *const MenuFont, r: *c.SDL_Renderer, text: []const u8, cx: f32, y: f32, scale: f32, rgb: [3]u8, mode: c.SDL_BlendMode) !void {
        for (self.pages) |pg| if (pg) |t| {
            _ = c.SDL_SetTextureColorMod(t, rgb[0], rgb[1], rgb[2]);
            _ = c.SDL_SetTextureBlendMode(t, mode);
        };
        var pen = cx - self.width(text) / 2;
        for (text) |ch| {
            const g = self.glyph(ch) orelse {
                pen += self.space;
                continue;
            };
            const tex = self.pages[g.page] orelse continue;
            const cw = (g.w + 1) * scale;
            const chh = (g.h + 1) * scale;
            const src: c.SDL_FRect = .{ .x = g.x, .y = g.y, .w = g.w, .h = g.h };
            const dst: c.SDL_FRect = .{ .x = pen - (cw - (g.w + 1)) / 2, .y = y - 0.75 * chh, .w = cw, .h = chh };
            try gfx.check(c.SDL_RenderTexture(r, tex, &src, &dst));
            pen += g.w + spacing;
        }
    }
};

/// Texture `gfx_3d\textures\<name>`.
pub fn loadTex(io: Io, gpa: Allocator, r: *c.SDL_Renderer, other: *archive.Archive, name: []const u8) ?*c.SDL_Texture {
    var buf: [96]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "gfx_3d\\textures\\{s}", .{name}) catch return null;
    const e = other.find(path) orelse return null;
    const data = other.readAlloc(io, gpa, e) catch return null;
    defer gpa.free(data);
    var img = og.formats.tex3df.decode(gpa, data) catch return null;
    defer img.deinit(gpa);
    return gfx.textureLinear(r, img) catch null;
}

/// Two-page font (0x47ad40): `.fnt` entries of 16 bytes (x, y, w, h); the second
/// page replaces chars with w > 0. Space is half of "w" plus the spacing.
pub fn loadFont(io: Io, gpa: Allocator, r: *c.SDL_Renderer, other: *archive.Archive, page1: []const u8, page2: []const u8) MenuFont {
    var f: MenuFont = .{};
    for ([2][]const u8{ page1, page2 }, 0..) |name, k| {
        var buf: [64]u8 = undefined;
        const fnt = std.fmt.bufPrint(&buf, "{s}.fnt", .{name}) catch continue;
        const e = other.find(fnt) orelse continue;
        const data = other.readAlloc(io, gpa, e) catch continue;
        defer gpa.free(data);
        const recs = og.formats.font.parseTex(data) catch continue;
        for (recs, &f.glyphs) |rec, *g| if (rec) |x| {
            g.* = .{ .x = @floatFromInt(x.x), .y = @floatFromInt(x.y), .w = @floatFromInt(x.w), .h = @floatFromInt(x.h), .page = @intCast(k) };
        };
        var tb: [64]u8 = undefined;
        f.pages[k] = if (k == 1 and std.mem.eql(u8, page1, page2)) f.pages[0] else loadTex(io, gpa, r, other, std.fmt.bufPrint(&tb, "{s}.3df", .{name}) catch continue);
    }
    if (f.glyphs['w']) |g| f.space = 0.5 * g.w + MenuFont.spacing;
    return f;
}

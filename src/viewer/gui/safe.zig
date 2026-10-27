//! Safe keypad (GUI_SafeBox, exe 0x457ff0): `sejf.spr` frame 0 background, 1–12
//! pressed keys 1–9, #, 0, *; typed digits in font 2 (`03_sejf.fnt`: glyph rects
//! in frame 2 of the `fonts.spr` atlas).
//! Eight digits close the window and call the area's CheckCode(code); `*` clears, `#` deletes the last.

const std = @import("std");
const actions_mod = og.world.actions;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");
const archive = og.formats.archive;
/// Glyph baseline in the atlas (sixth field of a `03_sejf.fnt` entry).
const baseline = 39;
const World = og.state.world.World;

/// Window at (210, 100) (0x45801e).
const origin = [2]f32{ 210, 100 };
/// Keys from (safe_key_start_x, _y) in steps of safe_key_width × _height (adjust.kdt).
/// Where the pressed key frame (1 + index) is drawn, from the window corner (0x4580bc…0x458118).
const pressed_at = [12][2]f32{
    .{ 46, 23 },  .{ 87, 24 },  .{ 126, 24 },
    .{ 46, 67 },  .{ 87, 66 },  .{ 127, 67 },
    .{ 45, 107 }, .{ 87, 108 }, .{ 125, 106 },
    .{ 46, 143 }, .{ 85, 146 }, .{ 127, 143 },
};

pub const SafeView = struct {
    gpa: Allocator,
    frames: gfx.Frames,
    atlas: gfx.Frames,
    glyphs: [256]?og.formats.font.TexGlyph,
    input: [8]u8 = undefined,
    len: usize = 0,
    /// Pressed key (0..11) while the mouse is held.
    held: ?usize = null,

    pub fn load(io: Io, gpa: Allocator, r: *c.SDL_Renderer, dat: Io.Dir) !SafeView {
        var sprites = try archive.Archive.open(io, gpa, dat, "common/sprite.dat");
        defer sprites.close(io, gpa);
        var other = try archive.Archive.open(io, gpa, dat, "common/other.dat");
        defer other.close(io, gpa);
        const spr = try sprites.readAlloc(io, gpa, sprites.find("sejf.spr") orelse return error.NotFound);
        defer gpa.free(spr);
        var frames = try gfx.loadSmooth(gpa, r, "sejf.spr", spr);
        errdefer frames.deinit(gpa);
        const fonts = try sprites.readAlloc(io, gpa, sprites.find("fonts.spr") orelse return error.NotFound);
        defer gpa.free(fonts);
        var atlas = try gfx.loadFrames(gpa, r, "fonts.spr", fonts);
        errdefer atlas.deinit(gpa);
        const fnt = try other.readAlloc(io, gpa, other.find("03_sejf.fnt") orelse return error.NotFound);
        defer gpa.free(fnt);
        return .{ .gpa = gpa, .frames = frames, .atlas = atlas, .glyphs = try og.formats.font.parseTex(fnt) };
    }

    pub fn deinit(self: *SafeView) void {
        self.atlas.deinit(self.gpa);
        self.frames.deinit(self.gpa);
    }

    /// Key under a screen point: row·3 + column (0..11).
    fn keyAt(x: f32, y: f32) ?usize {
        const adj = og.formats.adjust;
        const fx = (x - origin[0] - @as(f32, @floatFromInt(adj.getInt("safe_key_start_x", 49)))) / @as(f32, @floatFromInt(adj.getInt("safe_key_width", 42)));
        const fy = (y - origin[1] - @as(f32, @floatFromInt(adj.getInt("safe_key_start_y", 24)))) / @as(f32, @floatFromInt(adj.getInt("safe_key_height", 42)));
        if (fx < 0 or fy < 0 or fx >= 3 or fy >= 4) return null;
        return @as(usize, @intFromFloat(fy)) * 3 + @as(usize, @intFromFloat(fx));
    }

    pub fn press(self: *SafeView, x: f32, y: f32) bool {
        self.held = keyAt(x, y);
        return self.held != null;
    }

    /// Mouse release over the same key (0x45831a): digit, "*" clears, "#" deletes
    /// the last digit.
    /// Returns true if the press counts (safekey sound).
    pub fn release(self: *SafeView, w: *World, x: f32, y: f32) !bool {
        const k = self.held orelse return false;
        self.held = null;
        if (keyAt(x, y) != k) return false;
        switch (k) {
            0...8, 10 => if (self.len < self.input.len) {
                self.input[self.len] = if (k == 10) '0' else '1' + @as(u8, @intCast(k));
                self.len += 1;
            },
            9 => self.len -|= 1, // "#" deletes the last digit (0x4584b4)
            11 => self.len = 0,
            else => {},
        }
        if (self.len == self.input.len) {
            const code = std.fmt.parseInt(i32, self.input[0..self.len], 10) catch 0;
            self.len = 0;
            try actions_mod.enterSafeCode(w, code);
        }
        return true;
    }

    pub fn close(self: *SafeView, w: *World) void {
        self.len = 0;
        self.held = null;
        og.world.actions.closeSafe(w);
    }

    pub fn draw(self: *SafeView, r: *c.SDL_Renderer, mouse: [2]f32) !void {
        try self.frames.draw(r, 0, origin[0], origin[1]);
        // Pressed key frame only while the cursor is over it (0x4585f6…0x458609).
        if (self.held) |k| if (keyAt(mouse[0], mouse[1]) == k) try self.frames.draw(r, k + 1, origin[0] + pressed_at[k][0], origin[1] + pressed_at[k][1]);
        // Digits right-aligned at (x + 200, y + 265), y is the baseline (0x458636).
        if (self.atlas.len() < 3) return;
        const t = self.input[0..self.len];
        var x = origin[0] + 200 - gfx.texTextWidth(&self.glyphs, t, 0);
        const base = origin[1] + 265;
        for (t) |ch| if (self.glyphs[ch]) |g| {
            try self.atlas.drawPart(r, 2, gfx.glyphSrc(g), x, base - og.num.toF32(baseline - g.y));
            x += @floatFromInt(g.advance);
        };
    }
};

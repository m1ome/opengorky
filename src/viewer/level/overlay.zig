//! Over the level: letterbox bars, fade and the dialog box (0x459b40), or a debug
//! subtitle when there is no font.

const std = @import("std");
const level = @import("../level.zig");
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");
const LevelView = level.LevelView;
const Image = og.formats.image.Image;
const scenes_mod = og.scene.scenes;

/// Dialog box images from the host: speaker portrait and `dialog_box.spr`.
pub const DialogArt = struct { portrait: ?*gfx.Frames = null, box: ?*gfx.Frames = null };

/// Fade, letterbox bars and subtitles on top of everything.
pub fn drawOverlay(l: *LevelView, r: *c.SDL_Renderer, art: DialogArt) !void {
    const w = l.world;
    // Bars and fade over the whole (wide) frame.
    gfx.wholeView(r);
    const fw = 640 + 2 * gfx.wide;
    if (w.scene.panorama) {
        try gfx.check(c.SDL_SetRenderDrawColor(r, 0, 0, 0, 255));
        const h = @max(0, w.scene.panorama_h);
        try gfx.check(c.SDL_RenderFillRect(r, &.{ .x = 0, .y = 0, .w = fw, .h = h }));
        try gfx.check(c.SDL_RenderFillRect(r, &.{ .x = 0, .y = 479 - h, .w = fw, .h = h + 1 }));
    }
    if (w.scene.fade > 0) {
        try gfx.fillRect(r, .{ 0, 0, 0, @intFromFloat(w.scene.fade * 255) }, .{ .x = 0, .y = 0, .w = fw, .h = 480 });
    }
    gfx.middleView(r);
    if (w.scene.subtitle) |st| {
        if (l.font) |f| try drawDialog(l, r, f, st.speaker, st.text, art) else try drawSubtitle(r, scenes_mod.speakerName(w, st.speaker), st.text);
    }
}

/// Dialog box (0x459b40, 0x459e60): 530×63 strip at (55, 348) (+40 with letterbox),
/// black at alpha 180; portrait (frame 0) bottom-aligned at the left; "Name:" at
/// (+70, +6) in (3,167,175); 2 lines of width 395 at (+110, +24) in (181,181,181);
/// the page shown is the engine's (`w.scene.subtitle_page`); "next"
/// arrow is `dialog_box.spr` frame 1 at (+509, +41).
fn drawDialog(l: *LevelView, r: *c.SDL_Renderer, f: *const og.formats.font.Font, speaker: []const u8, text: []const u8, art: DialogArt) !void {
    const w = l.world;
    // Pages are split and timed by the engine (scene State).
    const np: usize = w.scene.subtitle_pages;
    if (np == 0 or text.len == 0) return;
    const pages = w.scene.pages[0..np];
    const page: usize = @min(w.scene.subtitle_page, np - 1);
    const x: f32 = 55;
    // Box at 348 (388 with panorama); a dialog outside a scene (DialogInit) at 338.
    const interactive = if (w.scene.runner) |sc| std.mem.eql(u8, sc.name, "dialog") else false;
    const y: f32 = if (w.scene.panorama) 388 else if (interactive) 338 else 348;
    try gfx.fillRect(r, .{ 0, 0, 0, 180 }, .{ .x = x, .y = y, .w = 530, .h = 63 });
    if (art.portrait) |p| if (p.len() > 0) {
        const h: f32 = @floatFromInt(p.sizes.items[0][1]);
        try p.draw(r, 0, x, y + 63 - h);
    };
    const key = @intFromPtr(text.ptr) +% page;
    if (l.dialog_page_key != key) {
        l.dialog_page_key = key;
        if (l.subtitle_tex) |t| c.SDL_DestroyTexture(t);
        l.subtitle_tex = null;
        var img = try Image.init(l.gpa, 530, 63);
        defer img.deinit(l.gpa);
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}:", .{scenes_mod.speakerName(w, speaker)}) catch speaker;
        // Name and lines with a (10,10,10) shadow at (+1, +1): flag 1 at 0x459ca8, 0x459d3e.
        f.draw(img, 71, 7, name, .{ 10, 10, 10 });
        f.draw(img, 70, 6, name, .{ 3, 167, 175 });
        var ly: i32 = 24;
        for (pages[page].lines[0..pages[page].n]) |ln| {
            const line = std.mem.trimEnd(u8, text[ln[0]..ln[1]], " ");
            f.draw(img, 111, ly + 1, line, .{ 10, 10, 10 });
            f.draw(img, 110, ly, line, .{ 181, 181, 181 });
            ly += @intCast(f.height + 1);
        }
        l.subtitle_tex = try gfx.textureFromImage(r, img);
        _ = c.SDL_SetTextureBlendMode(l.subtitle_tex.?, c.SDL_BLENDMODE_BLEND);
    }
    if (l.subtitle_tex) |t| try gfx.check(c.SDL_RenderTexture(r, t, null, &.{ .x = x, .y = y, .w = 530, .h = 63 }));
    if (page + 1 < np) if (art.box) |bx| if (bx.len() > 1) try bx.draw(r, 1, x + 509, y + 41);
}

/// Subtitle at the screen bottom: name and word-wrapped text (SDL 8×8 debug font).
fn drawSubtitle(r: *c.SDL_Renderer, speaker: []const u8, text: []const u8) !void {
    const max_chars = 76;
    var lines: [8][]const u8 = undefined;
    var n: usize = 0;
    var rest = text;
    while (rest.len > 0 and n < lines.len) {
        var cut: usize = @min(rest.len, max_chars);
        if (cut < rest.len) {
            if (std.mem.lastIndexOfScalar(u8, rest[0..cut], ' ')) |sp| cut = sp;
        }
        lines[n] = rest[0..cut];
        n += 1;
        rest = std.mem.trimStart(u8, rest[cut..], " ");
    }
    const top: f32 = 470 - og.num.toF32(n + 1) * 10;
    try gfx.fillRect(r, .{ 0, 0, 0, 170 }, .{ .x = 0, .y = top - 4, .w = 640, .h = 480 - top + 4 });
    var buf: [128]u8 = undefined;
    try gfx.check(c.SDL_SetRenderDrawColor(r, 255, 210, 120, 255));
    try gfx.check(c.SDL_RenderDebugText(r, 8, top, try std.fmt.bufPrintSentinel(&buf, "{s}:", .{speaker}, 0)));
    try gfx.check(c.SDL_SetRenderDrawColor(r, 235, 235, 235, 255));
    for (lines[0..n], 0..) |l, i| {
        try gfx.check(c.SDL_RenderDebugText(r, 8, top + 10 * og.num.toF32(i + 1), try std.fmt.bufPrintSentinel(&buf, "{s}", .{l}, 0)));
    }
}

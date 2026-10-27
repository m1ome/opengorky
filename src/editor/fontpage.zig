//! Fonts tab: a bitmap font of the game (`CZC1` `.fnt` in common/other.dat: dialogue,
//! system, small, credits, and each language's letter set `_N_xx`) as a 16×16 grid of its
//! characters; one picked and drawn zoomed (pencil: the letter colour, eraser: the
//! background), its width changed; or every character drawn anew from a TrueType font
//! at the font's height (letters of another language: the game's code page, cp1251 for
//! the Russian edition). A stroke is one undo step; the file keeps its own layout.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const c = @import("sdl");
const fnt = og.formats.font;
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const icons = @import("icons.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;
const common_archive = @import("store.zig").common_archive;

/// The Fonts tab's state (`app.fonts`): the font shown and its glyphs being edited.
pub const State = struct {
    sel: main.Name(64) = .{},
    edit: ?Edit = null,
};

/// The fonts with bitmaps (texture fonts `3d_*` are drawn from a 3D texture: not here).
pub fn names(app: *App, a: Allocator) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var ar = og.formats.archive.Archive.open(app.io, app.gpa, app.dat, common_archive) catch return out.items;
    defer ar.close(app.io, app.gpa);
    for (ar.entries) |e| {
        if (!std.ascii.endsWithIgnoreCase(e.name, ".fnt") or std.ascii.startsWithIgnoreCase(e.name, "3d_")) continue;
        out.append(a, a.dupe(u8, e.name) catch continue) catch {};
    }
    return out.items;
}

/// The font being edited: its glyphs (pixels owned), colours, the picked character, a
/// stroke in progress, textures per character (made on use, dropped on change).
pub const Edit = struct {
    file: usize,
    glyphs: [256]?Glyph = @splat(null),
    bg: u8 = 0,
    fg: u8 = 1,
    sel: u8 = 'A',
    erase: bool = false,
    stroke: bool = false,
    tex: [256]?*c.SDL_Texture = @splat(null),

    const Glyph = struct { w: u32, h: u32, px: []u8, order: u32 };

    pub fn deinit(self: *Edit, gpa: Allocator) void {
        for (&self.glyphs) |*g| if (g.*) |gg| gpa.free(gg.px);
        for (self.tex) |t| if (t) |tt| c.SDL_DestroyTexture(tt);
    }
};

/// Font entry `name` opened for editing (the one shown).
pub fn open(app: *App, name: []const u8) !void {
    const f = try app.store.file(common_archive, name);
    if (app.fonts.edit) |*e| {
        if (e.file == f) return;
        e.deinit(app.gpa);
    }
    app.fonts.edit = null;
    var e: Edit = .{ .file = f };
    errdefer e.deinit(app.gpa);
    try load(app, &e);
    app.fonts.edit = e;
}

/// The glyphs read again from the Store (after opening, and after an undo of the font).
pub fn load(app: *App, e: *Edit) !void {
    for (&e.glyphs) |*g| if (g.*) |gg| {
        app.gpa.free(gg.px);
        g.* = null;
    };
    for (&e.tex) |*t| if (t.*) |tt| {
        c.SDL_DestroyTexture(tt);
        t.* = null;
    };
    const bytes = app.store.text(e.file);
    const parsed = try fnt.parse(bytes);
    e.bg = parsed.bg;
    e.fg = if (parsed.max_level != parsed.bg) parsed.max_level else if (parsed.bg == 0) 1 else 0;
    // The letter colour: the other value glyphs use (two per font).
    for (parsed.glyphs) |g| if (g) |gg| for (gg.pixels) |v| if (v != parsed.bg) {
        e.fg = v;
        break;
    };
    const gs = try fnt.editable(bytes);
    for (gs, 0..) |g, i| if (g) |gg| {
        e.glyphs[i] = .{ .w = gg.width, .h = gg.height, .px = try app.gpa.dupe(u8, gg.pixels), .order = gg.order };
    };
}

/// The glyphs written into the Store (one undo step).
fn commit(app: *App, e: *Edit, what: []const u8) void {
    var gs: [256]?fnt.EditGlyph = @splat(null);
    for (e.glyphs, 0..) |g, i| if (g) |gg| {
        gs[i] = .{ .width = gg.w, .height = gg.h, .pixels = gg.px, .order = gg.order };
    };
    const bytes = fnt.encode(app.gpa, &gs) catch return;
    app.store.replaceLabeled(e.file, bytes, std.fmt.allocPrint(app.frame.allocator(), "{s}: {s}", .{ app.store.files.items[e.file].entry, what }) catch what) catch |err| {
        app.gpa.free(bytes);
        app.setStatus(tx.st_set_failed, .{err});
    };
}

fn texture(app: *App, e: *Edit, ch: u8) ?*c.SDL_Texture {
    if (e.tex[ch]) |t| return t;
    const g = e.glyphs[ch] orelse return null;
    if (g.w == 0 or g.h == 0) return null;
    const rgba = app.frame.allocator().alloc(u8, g.w * g.h * 4) catch return null;
    for (g.px, 0..) |v, k| {
        const on = v != e.bg;
        rgba[k * 4 ..][0..4].* = if (on) .{ 235, 235, 235, 255 } else .{ 0, 0, 0, 0 };
    }
    const t = c.SDL_CreateTexture(app.r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, @intCast(g.w), @intCast(g.h)) orelse return null;
    _ = c.SDL_UpdateTexture(t, null, rgba.ptr, @intCast(g.w * 4));
    _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetTextureScaleMode(t, c.SDL_SCALEMODE_NEAREST);
    e.tex[ch] = t;
    return t;
}

fn dropTex(e: *Edit, ch: u8) void {
    if (e.tex[ch]) |t| c.SDL_DestroyTexture(t);
    e.tex[ch] = null;
}

pub fn page(app: *App, a: Allocator) void {
    const name = app.fonts.sel.get();
    if (name.len == 0) return;
    open(app, name) catch |err| return app.setStatus(tx.st_open_failed, .{ name, err });
    const e = &app.fonts.edit.?;
    clay.openScroll(.{ .id = clay.id("font_page"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 20, .right = 20, .top = 16, .bottom = 16 }, .childGap = 12 } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 12, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    icons.leaf(app.r, app.gpa, .file_text, 28, theme.accent_hover);
    txt(name, 20, theme.text, font_mod.bold);
    clay.close();
    clay.open(.{ .layout = .{ .childGap = 20 } });
    grid(app, a, e);
    glyphEditor(app, a, e);
    clay.close();
    clay.close();
    main.propsOpen(app, "font_props");
    main.propsTitle(tx.get(tx.props), true);
    main.propRow(tx.get(tx.p_file), name);
    var n: usize = 0;
    for (e.glyphs) |g| n += @intFromBool(g != null);
    main.propRow(tx.get(tx.fn_glyphs), std.fmt.allocPrint(a, "{d} / 256", .{n}) catch "");
    main.propNote(tx.get(tx.fn_hint));
    main.propsTitle(tx.get(tx.p_actions), false);
    if (main.toolButton(app, "font_ttf", .plus, tx.get(tx.fn_from_ttf), false, false)) app.askFile(.{ .kind = .ttf, .run = onTtf });
    clay.close();
}

/// The 256 characters, 16 to a row; a click picks one.
fn grid(app: *App, a: Allocator, e: *Edit) void {
    clay.open(.{ .layout = .{ .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 2 } });
    for (0..16) |row| {
        clay.open(.{ .layout = .{ .childGap = 2 } });
        for (0..16) |col| {
            const ch: u8 = @intCast(row * 16 + col);
            const cid = clay.idi("fn_cell", ch);
            const sel = ch == e.sel;
            if (main.clickable(app, .{ .id = cid, .layout = .{ .sizing = .{ .width = clay.fixed(34), .height = clay.fixed(40) }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER }, .childGap = 1 }, .backgroundColor = theme.field, .cornerRadius = clay.radius(3) }, sel)) e.sel = ch;
            if (texture(app, e, ch)) |t| {
                const g = e.glyphs[ch].?;
                const k = @min(2.0, 26.0 / @as(f32, @floatFromInt(@max(g.h, 1))));
                clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(@as(f32, @floatFromInt(g.w)) * k), .height = clay.fixed(@as(f32, @floatFromInt(g.h)) * k) } }, .image = .{ .imageData = t } });
            } else txt("·", 13, theme.line, font_mod.regular);
            txt(std.fmt.allocPrint(a, "{X:0>2}", .{ch}) catch "", 9, theme.dim, font_mod.regular);
            clay.close();
        }
        clay.close();
    }
    clay.close();
}

/// The picked character zoomed: a press paints (pencil or eraser) cell by cell, the
/// stroke written on release; its width −/+, the character made empty or removed.
fn glyphEditor(app: *App, a: Allocator, e: *Edit) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 10 } });
    txt(tx.alloc(a, tx.fn_char, .{ e.sel, e.sel }), 15, theme.text, font_mod.bold);
    clay.open(.{ .layout = .{ .childGap = 6 } });
    if (main.toolButton(app, "fn_pencil", .pencil, tx.get(tx.spr_pencil), !e.erase, false)) e.erase = false;
    if (main.toolButton(app, "fn_eraser", .x, tx.get(tx.spr_eraser), e.erase, false)) e.erase = true;
    if (main.toolButton(app, "fn_narrow", .chevron_right, tx.get(tx.fn_narrower), false, false)) resize(app, e, -1);
    if (main.toolButton(app, "fn_wide", .plus, tx.get(tx.fn_wider), false, false)) resize(app, e, 1);
    clay.close();
    const g = e.glyphs[e.sel] orelse {
        if (main.toolButton(app, "fn_make", .plus, tx.get(tx.fn_make), false, true)) makeGlyph(app, e);
        clay.close();
        return;
    };
    // The canvas: 16 points a pixel (smaller for big glyphs).
    const k: f32 = @min(16, 480 / @as(f32, @floatFromInt(@max(g.w, g.h, 1))));
    const cv = clay.id("fn_canvas");
    clay.open(.{ .id = cv, .layout = .{ .sizing = .{ .width = clay.fixed(@as(f32, @floatFromInt(g.w)) * k), .height = clay.fixed(@as(f32, @floatFromInt(g.h)) * k) } }, .backgroundColor = theme.viewport, .border = .{ .color = theme.line, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } } });
    if (texture(app, e, e.sel)) |t| clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } }, .image = .{ .imageData = t } });
    clay.close();
    // Painting by last frame's box.
    if (app.down and clay.pointerOver(cv)) if (clay.box(cv)) |b| {
        const x: i64 = @intFromFloat(@floor((app.mouse[0] - b.x) / k));
        const y: i64 = @intFromFloat(@floor((app.mouse[1] - b.y) / k));
        if (x >= 0 and y >= 0 and x < g.w and y < g.h) {
            const i: usize = @intCast(y * @as(i64, g.w) + x);
            const v = if (e.erase) e.bg else e.fg;
            if (g.px[i] != v) {
                g.px[i] = v;
                dropTex(e, e.sel);
            }
            e.stroke = true;
        }
    };
    if (!app.down and e.stroke) {
        e.stroke = false;
        commit(app, e, std.fmt.allocPrint(a, "{c}", .{e.sel}) catch "glyph");
    }
    txt(tx.alloc(a, tx.fn_size, .{ g.w, g.h }), 12, theme.dim, font_mod.regular);
    clay.close();
}

fn resize(app: *App, e: *Edit, dw: i32) void {
    const g = &(e.glyphs[e.sel] orelse return);
    const nw: u32 = @intCast(std.math.clamp(@as(i32, @intCast(g.w)) + dw, 1, 64));
    if (nw == g.w) return;
    const px = app.gpa.alloc(u8, nw * g.h) catch return;
    for (0..g.h) |y| for (0..nw) |x| {
        px[y * nw + x] = if (x < g.w) g.px[y * g.w + x] else e.bg;
    };
    app.gpa.free(g.px);
    g.px = px;
    g.w = nw;
    dropTex(e, e.sel);
    commit(app, e, "width");
}

/// An empty character (the font's height, a space's width) for the picked code.
fn makeGlyph(app: *App, e: *Edit) void {
    var h: u32 = 1;
    var last: u32 = 0;
    for (e.glyphs) |g| if (g) |gg| {
        h = @max(h, gg.h);
        last = @max(last, gg.order + 1);
    };
    const w: u32 = @max(2, h / 3);
    const px = app.gpa.alloc(u8, w * h) catch return;
    @memset(px, e.bg);
    e.glyphs[e.sel] = .{ .w = w, .h = h, .px = px, .order = std.math.maxInt(u32) };
    commit(app, e, "new character");
}

/// Every character 32…255 drawn from TrueType file `path` at the font's height, in the
/// game's code page (Cyrillic for the Russian edition), as two colours; one undo step.
pub fn fromTtf(app: *App, path: []const u8) !void {
    const e = &(app.fonts.edit orelse return error.NoFont);
    const ttf = try std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(32 << 20));
    defer app.gpa.free(ttf);
    var info: ui.stbtt_fontinfo = undefined;
    if (ui.stbtt_InitFont(&info, ttf.ptr, ui.stbtt_GetFontOffsetForIndex(ttf.ptr, 0)) == 0) return error.NotTtf;
    var h: u32 = 1;
    for (e.glyphs) |g| if (g) |gg| {
        h = @max(h, gg.h);
    };
    const scale = ui.stbtt_ScaleForPixelHeight(&info, @floatFromInt(h));
    var asc: c_int = 0;
    var desc: c_int = 0;
    var gap: c_int = 0;
    ui.stbtt_GetFontVMetrics(&info, &asc, &desc, &gap);
    const base: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(asc)) * scale));
    var made: usize = 0;
    for (32..256) |b| {
        const cp = codepoint(@intCast(b), app.catalog.cyrillic);
        if (ui.stbtt_FindGlyphIndex(&info, @intCast(cp)) == 0 and b != 32) continue;
        var adv: c_int = 0;
        var lsb: c_int = 0;
        ui.stbtt_GetCodepointHMetrics(&info, @intCast(cp), &adv, &lsb);
        // The exe steps width − 1 (0x47b4fb): one column more than the advance.
        const w: u32 = @intCast(@max(2, @as(i32, @intFromFloat(@ceil(@as(f32, @floatFromInt(adv)) * scale))) + 1));
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        ui.stbtt_GetCodepointBitmapBox(&info, @intCast(cp), scale, scale, &x0, &y0, &x1, &y1);
        const gw: usize = @intCast(@max(0, x1 - x0));
        const gh: usize = @intCast(@max(0, y1 - y0));
        const cov = try app.gpa.alloc(u8, @max(1, gw * gh));
        defer app.gpa.free(cov);
        if (gw > 0 and gh > 0) ui.stbtt_MakeCodepointBitmap(&info, cov.ptr, @intCast(gw), @intCast(gh), @intCast(gw), scale, scale, @intCast(cp));
        const px = try app.gpa.alloc(u8, w * h);
        @memset(px, e.bg);
        for (0..gh) |yy| for (0..gw) |xx| {
            if (cov[yy * gw + xx] < 110) continue;
            const x = @as(i32, @intCast(xx)) + x0;
            const y = @as(i32, @intCast(yy)) + base + y0;
            if (x < 0 or y < 0 or x >= w or y >= h) continue;
            px[@as(usize, @intCast(y)) * w + @as(usize, @intCast(x))] = e.fg;
        };
        const order = if (e.glyphs[b]) |old| blk: {
            app.gpa.free(old.px);
            break :blk old.order;
        } else std.math.maxInt(u32);
        e.glyphs[b] = .{ .w = w, .h = h, .px = px, .order = order };
        dropTex(e, @intCast(b));
        made += 1;
    }
    commit(app, e, "from TrueType");
    app.setStatus(tx.st_font_made, .{made});
}

/// The game's byte `b` as Unicode (latin-1; cp1251 letters for the Russian edition).
fn codepoint(b: u8, cyrillic: bool) u21 {
    if (cyrillic) {
        if (b >= 0xc0) return @as(u21, b) - 0xc0 + 0x410;
        if (b == 0xa8) return 0x401;
        if (b == 0xb8) return 0x451;
    }
    return b;
}

/// File dialog answer (app.askFile).
fn onTtf(app: *App, _: main.FileAsk, path: []const u8) !void {
    try fromTtf(app, path);
}

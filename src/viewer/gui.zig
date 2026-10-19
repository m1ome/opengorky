//! Bottom panel (one for exploration and battle, exe 0x4b1ab0/0x4b1d50/0x4b2440),
//! hero portraits, cursor. Sprites from `common/sprite.dat` (`game_box.spr`,
//! `icons\<hero>.spr`, `mouse.spr`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("media/gfx.zig");
const lang = og.formats.lang;
const archive = og.formats.archive;

pub const panel_h = 68;
/// GUI text colours: light (names, first hint line) and dim (second line, labels)
/// — (210, 210, 192) and (177, 177, 149) in the exe.
pub const text_light = [3]u8{ 210, 210, 192 };
pub const text_dim = [3]u8{ 177, 177, 149 };
const CursorAnchor = enum { corner, center2, push };

/// `mouse.spr` cursor frames (0x450900).
pub const Cursor = struct {
    /// Arrow (corner).
    pub const arrow: usize = 0;
    /// Crosshair.
    pub const crosshair: usize = 1;
    /// Use an item (not medicine), centred on frame 2's size.
    pub const use: usize = 2;
    /// Hand: give.
    pub const give: usize = 3;
    /// Level exit (centred).
    pub const exit: usize = 4;
    /// Push hand (0x452bf0).
    pub const push: usize = 5;
    /// Medicine: red ring with a cross; also the 0% crosshair (0x4527b1).
    pub const heal: usize = 6;
    /// Crosshair outside attack cells: empty ring (7); 16 is full.
    pub const aim_empty: usize = 7;

    /// Crosshair by the cell's range percent: 6 + pct/10 (0x4527b1).
    pub fn aim(pct: u8) usize {
        return heal + @as(usize, pct) / 10;
    }
};

pub const panel_y = 480 - panel_h;

/// Scrollbar (0x4ae790, press 0x4aea50): track from `y` of length `len`, thumb 29,
/// `rows` visible; a click off the thumb — ±16, dragging — top at y − 14.
pub const Scrollbar = struct {
    y: f32,
    len: f32,
    rows: usize,

    pub fn thumb(b: Scrollbar, scroll: usize, n: usize) f32 {
        if (n <= b.rows) return 0;
        return og.num.toF32(scroll) / og.num.toF32(n - b.rows) * (b.len - 29);
    }

    /// Click on the track; true if on the thumb (start dragging).
    pub fn click(b: Scrollbar, scroll: *usize, n: usize, y: f32) bool {
        if (n <= b.rows) return false;
        const top = b.y + b.thumb(scroll.*, n);
        if (y >= top and y <= top + 29) return true;
        scroll.* = if (y < top) scroll.* -| 16 else @min(n - b.rows, scroll.* + 16);
        return false;
    }

    /// `GScrollBar.spr` bar at x (0x4aed50): thumb (frame 0) always, (12 − 15) / 2 =
    /// −1 to the left; up arrow (1) above the track when scrolled; down (2) below it
    /// (y + len − 29 + 33) when more is below.
    pub fn draw(b: Scrollbar, r: *c.SDL_Renderer, spr: *const gfx.Frames, x: f32, scroll: usize, n: usize) !void {
        if (spr.len() < 3) return;
        try spr.draw(r, 0, x - 1, @trunc(b.y + b.thumb(scroll, n)));
        if (scroll > 0) try spr.draw(r, 1, x, b.y - 16);
        if (n > b.rows and scroll < n - b.rows) try spr.draw(r, 2, x, b.y + b.len + 4);
    }

    pub fn drag(b: Scrollbar, scroll: *usize, n: usize, y: f32) void {
        if (n <= b.rows) return;
        const off = std.math.clamp(y - 14 - b.y, 0, b.len - 29);
        scroll.* = @intFromFloat(@round(off / (b.len - 29) * og.num.toF32(n - b.rows)));
    }
};
/// Below this line a click hits the panel, not the ground: 12 px above the panel,
/// so a miss next to a button or the weapon slot doesn't send the hero walking.
pub const panel_hit_y = panel_y - 12;

/// Panel buttons (table 0x52b388; y from the panel top).
pub const Button = enum(u4) { inventory, give, hand, short_list, push, defend, hero0, hero1, hero2, hero3, hero4, turn, end_turn, skills, stats };

/// Shutters of inactive buttons (0x6c6038): frames min..max, ±0.6 per tick.
pub const shutters = [15]?[2]f32{
    .{ 4, 9 },   .{ 4, 9 },   .{ 10, 21 }, null,        .{ 4, 9 }, .{ 4, 9 }, .{ 29, 34 }, .{ 29, 34 },
    .{ 29, 34 }, .{ 29, 34 }, .{ 29, 34 }, .{ 22, 28 }, .{ 4, 9 }, null,      null,
};

const gui_windows = @import("gui/windows.zig");
const gui_text = @import("gui/text.zig");

pub const Gui = struct {
    gpa: Allocator,
    skills: gui_windows.SkillWindow = .{},
    skill_spr: gfx.Frames = .{},
    intro: gfx.Frames = .{},
    dialog_box: gfx.Frames = .{},
    /// Battle text font `3d_msg` (texture and glyph rectangles).
    /// Font pages: main and the language set.
    msg_tex: [2]?*c.SDL_Texture = .{ null, null },
    msg_glyphs: [256]?og.formats.font.TexGlyph = @splat(null),
    msg_page: [256]u1 = @splat(0),
    /// Turn banner (0x4c8ac0): text, colour, phase 1–4, value, hold ticks.
    banner: ?og.popup.Popup = null,
    banner_tick: u64 = 0,
    last_phase: ?og.battle.battle.Phase = null,
    /// Post-battle report (`raport.spr`, 0x451d70): open, top row.
    raport: gfx.Frames = .{},
    report_open: bool = false,
    report_scroll: usize = 0,
    report_done: bool = false,
    /// Quick list (`item_list.spr` at (83, 185), 0x4b0ed0): open, give mode, scroll;
    /// in give mode the picked item waits for a portrait click.
    short_open: bool = false,
    short_give: bool = false,
    short_scroll: usize = 0,
    /// The quick list thumb is being dragged.
    short_drag: bool = false,
    /// Cursor frame for this frame (reset after drawing).
    cursor_frame: usize = 0,
    /// Cursor hotspot this frame: the frame corner; use mode (0x450d4e) — centre of
    /// frame 2's size; push (0x452bf0) — mouse − frame 2 size / 5.
    cursor_anchor: CursorAnchor = .corner,
    /// Panel hidden (space outside scenes, `[0x5247d0]`).
    panel_hidden: bool = false,
    /// Defeat screen: frozen frame and the YES (0) / NO (1) choice.
    go_frame: ?*c.SDL_Texture = null,
    go_sel: u8 = 0,
    /// Capture a frame for the defeat screen after this draw.
    go_capture: bool = false,
    tip_buf: [96]u8 = undefined,
    /// Hint suffix (0x45c6b0): " +N HP" in cyan, " Lv.N" in yellow.
    tip_extra_buf: [32]u8 = undefined,
    tip_extra: []const u8 = "",
    tip_extra_col: [3]u8 = .{ 0, 255, 255 },
    item_list: gfx.Frames = .{},
    scrollbar: gfx.Frames = .{},
    /// Shutter positions (fractional frame) and the world tick they were updated at.
    shutter: [15]f32 = blk: {
        var a: [15]f32 = undefined;
        for (&a, shutters) |*v, sh| v.* = if (sh) |m| m[0] else 0;
        break :blk a;
    },
    shutter_tick: u64 = 0,
    inv_dir: ?bool = null,
    /// Pressed button (mouse held) and the button under the cursor (0x52b384, 0x52b380).
    pressed_btn: ?Button = null,
    hover_btn: ?Button = null,
    /// Panel text (health, round number): font 03_small, digit atlas 02_hp.
    font_bytes: []u8 = &.{},
    font: ?og.formats.font.Font = null,
    /// Font 3 (`04_system`): window names and labels.
    sys_bytes: []u8 = &.{},
    sys_font: ?og.formats.font.Font = null,
    /// Stats window (`HeroStats.spr`, 0x6c5fd0).
    stats: gui_windows.StatsWindow = .{},
    /// Stats window inside the inventory.
    inv_stats: gui_windows.StatsWindow = .{},
    hero_stats: gfx.Frames = .{},
    atlas: gfx.Frames = .{},
    hp_glyphs: [256]?og.formats.font.TexGlyph = @splat(null),
    text: ?og.formats.image.Image = null,
    text_tex: ?*c.SDL_Texture = null,
    /// Ready textures of shadowed text (hints, labels), so they aren't rebuilt every frame.
    texts: gui_text.TextCache = .{},
    /// Window text (full screen).
    win_text: ?og.formats.image.Image = null,
    win_tex: ?*c.SDL_Texture = null,
    panel: gfx.Frames = .{},
    /// Portraits `icons\<spriteFile>.spr` by hero name (lowercase).
    portraits: std.StringHashMapUnmanaged(gfx.Frames) = .empty,
    cursor: gfx.Frames = .{},
    /// Fighter info window (`FighterInfo.spr`, 0x45a2b1).
    fighter_info: gfx.Frames = .{},
    /// Selected hero frame corners (`border.spr`, frames 0–3, 0x45b920).
    border: gfx.Frames = .{},
    /// Battle loading "saw" (`pila.spr` from other.dat, 20 frames 172×177, 0x410f50).
    spinner: gfx.Frames = .{},
    io: Io,
    renderer: *c.SDL_Renderer,
    sprites: archive.Archive,

    pub fn load(io: Io, gpa: Allocator, r: *c.SDL_Renderer, dat: Io.Dir) !Gui {
        const arc = try archive.Archive.open(io, gpa, dat, "common/sprite.dat");
        var g: Gui = .{ .gpa = gpa, .io = io, .renderer = r, .sprites = arc };
        errdefer g.deinit();
        const ln = lang.language(io, gpa, dat);
        g.panel = try loadSprite(io, gpa, r, arc, "game_box.spr");
        g.cursor = loadSprite(io, gpa, r, arc, "mouse.spr") catch .{};
        g.fighter_info = loadSprite(io, gpa, r, arc, "FighterInfo.spr") catch .{};
        g.border = loadSprite(io, gpa, r, arc, "border.spr") catch .{};
        if (archive.Archive.open(io, gpa, dat, "common/other.dat")) |other_| {
            var other = other_;
            defer other.close(io, gpa);
            g.spinner = loadSprite(io, gpa, r, other, "pila.spr") catch .{};
        } else |_| {}
        g.atlas = loadSprite(io, gpa, r, arc, "fonts.spr") catch .{};
        g.skill_spr = loadSprite(io, gpa, r, arc, "WeaponSkill.spr") catch .{};
        g.intro = loadSprite(io, gpa, r, arc, "intro.spr") catch .{};
        g.hero_stats = loadSprite(io, gpa, r, arc, "HeroStats.spr") catch .{};
        g.dialog_box = loadSprite(io, gpa, r, arc, "dialog_box.spr") catch .{};
        g.raport = loadSprite(io, gpa, r, arc, "raport.spr") catch .{};
        g.item_list = loadSprite(io, gpa, r, arc, "item_list.spr") catch .{};
        g.scrollbar = loadSprite(io, gpa, r, arc, "GScrollBar.spr") catch .{};
        if (archive.Archive.open(io, gpa, dat, "common/other.dat")) |other_arc| {
            var other = other_arc;
            defer other.close(io, gpa);
            if (other.find("02_hp.fnt")) |e| if (other.readAlloc(io, gpa, e)) |b| {
                defer gpa.free(b);
                g.hp_glyphs = og.formats.font.parseTex(b) catch @splat(null);
            } else |_| {};
            if (lang.readFont(io, gpa, &other, "03_small", ln)) |b| {
                g.font_bytes = b;
                g.font = og.formats.font.parse(b) catch null;
            }
            if (lang.readFont(io, gpa, &other, "04_system", ln)) |b| {
                g.sys_bytes = b;
                g.sys_font = og.formats.font.parse(b) catch null;
            }
        } else |_| {}
        g.text = og.formats.image.Image.init(gpa, 640, panel_h) catch null;
        if (archive.Archive.open(io, gpa, dat, "common/other.dat")) |oa| {
            var other = oa;
            defer other.close(io, gpa);
            // 3d_msg font (0x47ad40): page 1 is `3d_msg_1`; for language N > 1 the
            // second page is the `3d_msg_N<suffix>` set, whose glyphs replace the main ones.
            var nbuf: [48]u8 = undefined;
            const pages = [2]?[]const u8{ "3d_msg_1", lang.setName(&nbuf, "3d_msg", ln) };
            for (pages, 0..) |name_, k| {
                const name = name_ orelse continue;
                var fb: [64]u8 = undefined;
                const fnt = std.fmt.bufPrint(&fb, "{s}.fnt", .{name}) catch continue;
                if (other.find(fnt)) |e| if (other.readAlloc(io, gpa, e)) |b| {
                    defer gpa.free(b);
                    const glyphs: [256]?og.formats.font.TexGlyph = og.formats.font.parseTex(b) catch @splat(null);
                    for (glyphs, &g.msg_glyphs, &g.msg_page) |x, *dst, *pg| if (x != null) {
                        dst.* = x;
                        pg.* = @intCast(k);
                    };
                } else |_| {};
                var tb: [96]u8 = undefined;
                const tex = std.fmt.bufPrint(&tb, "gfx_3d\\textures\\{s}.3df", .{name}) catch continue;
                if (other.find(tex)) |e| if (other.readAlloc(io, gpa, e)) |b| {
                    defer gpa.free(b);
                    if (og.formats.tex3df.decode(gpa, b)) |img_| {
                        var img = img_;
                        defer img.deinit(gpa);
                        g.msg_tex[k] = gfx.textureLinear(r, img) catch null;
                        if (g.msg_tex[k]) |t| _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_ADD);
                    } else |_| {}
                } else |_| {};
            }
        } else |_| {}
        g.win_text = og.formats.image.Image.init(gpa, 640, 480) catch null;
        return g;
    }

    pub fn deinit(self: *Gui) void {
        self.panel.deinit(self.gpa);
        self.atlas.deinit(self.gpa);
        self.skill_spr.deinit(self.gpa);
        self.intro.deinit(self.gpa);
        self.dialog_box.deinit(self.gpa);
        self.raport.deinit(self.gpa);
        self.item_list.deinit(self.gpa);
        for (self.msg_tex) |tex| if (tex) |t| c.SDL_DestroyTexture(t);
        self.scrollbar.deinit(self.gpa);
        if (self.win_tex) |t| c.SDL_DestroyTexture(t);
        if (self.win_text) |*t| t.deinit(self.gpa);
        if (self.text_tex) |t| c.SDL_DestroyTexture(t);
        self.texts.deinit();
        if (self.text) |*t| t.deinit(self.gpa);
        if (self.font_bytes.len > 0) self.gpa.free(self.font_bytes);
        if (self.sys_bytes.len > 0) self.gpa.free(self.sys_bytes);
        self.hero_stats.deinit(self.gpa);
        var it = self.portraits.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.portraits.deinit(self.gpa);
        self.cursor.deinit(self.gpa);
        self.fighter_info.deinit(self.gpa);
        self.border.deinit(self.gpa);
        self.spinner.deinit(self.gpa);
        self.sprites.close(self.io, self.gpa);
    }

    /// Hero portrait (`spriteFile`, else the name), cached.
    pub fn portrait(self: *Gui, hero: *og.script.object.Object) ?*gfx.Frames {
        const sf = hero.getString("spriteFile");
        return self.icon(if (sf.len > 0) sf else hero.name);
    }

    /// Icon `icons\<name>.spr` (portrait or item), cached.
    pub fn icon(self: *Gui, name: []const u8) ?*gfx.Frames {
        if (name.len == 0 or name.len > 48) return null;
        var key_buf: [64]u8 = undefined;
        const key = std.ascii.lowerString(&key_buf, name);
        if (self.portraits.getPtr(key)) |f| return f;
        var buf: [80]u8 = undefined;
        const file = std.fmt.bufPrint(&buf, "icons\\{s}.spr", .{key}) catch return null;
        const frames = loadSprite(self.io, self.gpa, self.renderer, self.sprites, file) catch gfx.Frames{};
        const owned = self.gpa.dupe(u8, key) catch return null;
        self.portraits.put(self.gpa, owned, frames) catch {
            self.gpa.free(owned);
            return null;
        };
        return self.portraits.getPtr(key);
    }

    pub const ShortItem = og.inventory.list.Entry;

    pub const short_rows = [4][4]f32{ .{ 6, 9, 80, 61 }, .{ 6, 61, 80, 114 }, .{ 6, 114, 80, 166 }, .{ 6, 166, 80, 219 } };

    /// Monster icon by nameID for the report (table 0x523f00).
    pub const monster_icons = [_]struct { id: i32, name: []const u8 }{
        .{ .id = 125, .name = "cripple" },         .{ .id = 105, .name = "cutterpil" },       .{ .id = 107, .name = "fang" },
        .{ .id = 124, .name = "fatman" },          .{ .id = 101, .name = "garcia" },          .{ .id = 113, .name = "grandma" },
        .{ .id = 131, .name = "guard" },           .{ .id = 122, .name = "harvester" },       .{ .id = 118, .name = "headnail" },
        .{ .id = 128, .name = "hornet" },          .{ .id = 108, .name = "hound" },           .{ .id = 138, .name = "incubus" },
        .{ .id = 120, .name = "invisible" },       .{ .id = 100, .name = "jet elmer" },       .{ .id = 115, .name = "judge" },
        .{ .id = 116, .name = "judgeslave" },      .{ .id = 129, .name = "lillith" },         .{ .id = 135, .name = "lillith" },
        .{ .id = 137, .name = "lucy" },            .{ .id = 119, .name = "medusa_rap" },      .{ .id = 139, .name = "messiah" },
        .{ .id = 130, .name = "needle" },          .{ .id = 121, .name = "paingod" },         .{ .id = 132, .name = "puppet" },
        .{ .id = 106, .name = "rc28" },            .{ .id = 126, .name = "reverend insect" }, .{ .id = 136, .name = "schizo family" },
        .{ .id = 109, .name = "sinner" },          .{ .id = 123, .name = "sister of mercy" }, .{ .id = 110, .name = "smoke" },
        .{ .id = 102, .name = "sphinks" },         .{ .id = 133, .name = "squeaker" },        .{ .id = 127, .name = "stinger" },
        .{ .id = 114, .name = "wnuczek" },         .{ .id = 27, .name = "kozow_rap" },        .{ .id = 141, .name = "nato_capitan_rap" },
        .{ .id = 25, .name = "nato_soldier_rap" }, .{ .id = 28, .name = "specnaz_rap" },      .{ .id = 142, .name = "Lamare" },
    };
};

fn loadSprite(io: Io, gpa: Allocator, r: *c.SDL_Renderer, arc: archive.Archive, name: []const u8) !gfx.Frames {
    const e = arc.find(name) orelse return error.NotFound;
    const data = try arc.readAlloc(io, gpa, e);
    defer gpa.free(data);
    return gfx.loadSmooth(gpa, r, name, data);
}

/// Cursor hint (0x45bef0): font 2, white with shadow, at (mouse + (40, 20)); the main
/// line's right edge at most 638, top at most 470; `extra` follows in its own colour.
pub fn drawHint(self: *Gui, r: *c.SDL_Renderer, mx: f32, my: f32, main: []const u8, extra: []const u8, extra_col: [3]u8) !void {
    const f = self.font orelse return;
    // Clamp by the main line width and the top at 470 (0x45bf0a…0x45bf2f).
    const x = @round(@min(mx + 40, 638 - og.num.toF32(f.measure(main))));
    const y = @round(@min(my + 20, 470));
    const tw: u32 = f.measure(main) + f.measure(extra) + 2;
    var h = std.hash.Wyhash.init(1);
    h.update(main);
    h.update("\x00");
    h.update(extra);
    h.update(&extra_col);
    h.update(std.mem.asBytes(&gui_text.fontId(f)));
    const tex = self.texts.get(h.final()) orelse blk: {
        var img = try og.formats.image.Image.init(self.gpa, tw, f.height + 2);
        defer img.deinit(self.gpa);
        @memset(img.pixels, 0);
        // Shadowed (0x47b4e0 with flag 1).
        textShadow(f, img, 0, 0, main, .{ 255, 255, 255 });
        textShadow(f, img, @intCast(f.measure(main)), 0, extra, extra_col);
        break :blk try self.texts.put(r, h.final(), img);
    };
    try gfx.check(c.SDL_RenderTexture(r, tex, null, &.{ .x = x, .y = y, .w = @floatFromInt(tw), .h = @floatFromInt(f.height + 2) }));
}

/// Shadowed text (0x47b4e0): first at (x+1, y+1) in (10,10,10).
pub fn textShadow(f: og.formats.font.Font, img: og.formats.image.Image, x: i32, y: i32, s: []const u8, col: [3]u8) void {
    f.draw(img, x + 1, y + 1, s, .{ 10, 10, 10 });
    f.draw(img, x, y, s, col);
}

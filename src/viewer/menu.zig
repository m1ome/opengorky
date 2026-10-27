//! Main menu and in-game menu (0x4134e0, frame 0x416330): a "flashlight" 3D scene —
//! the breathing monster `gfx_3d\menu.msh`, a light spot behind the cursor, the
//! GORKY 17 logo with a halo, item shadows cast from the cursor, flares. Items are
//! string.tab lines in font `3d_menu_1` (+ `3d_menu_1_1`), the selected glow `3d_menug_1`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("media/gfx.zig");
const lang_mod = og.formats.lang;
const archive = og.formats.archive;
const Image = og.formats.image.Image;
const Font = og.formats.font.Font;
const model_cache = og.actor.model_cache;

const menu_items = @import("menu/items.zig");

// adjust.kdt constants (defaults).
fn startY() f32 {
    return @floatFromInt(og.formats.adjust.getInt("MENU_START_Y", 220));
}
fn hSpace() f32 {
    return @floatFromInt(og.formats.adjust.getInt("MENU_H_SPACE", 47));
}

/// Credits line: a heading (a line with ":") or a name. A `#N` line in `credits.inf`
/// (0x42c773) is not shown; it sets the letter set for the following lines.
const CreditRow = struct {
    title: bool,
    text: []const u8 = "",
    /// Language letter set (`#N`), 1 is the main one.
    charset: u8 = 1,
};

/// Scene blend modes (0x408ad0): 1 additive, 3 darken dst·(1 − src), 4 screen,
/// 5 multiply.
const Modes = struct {
    add: c.SDL_BlendMode,
    darken: c.SDL_BlendMode,
    screen: c.SDL_BlendMode,
    multiply: c.SDL_BlendMode,

    fn init() Modes {
        const one = c.SDL_BLENDFACTOR_ONE;
        const zero = c.SDL_BLENDFACTOR_ZERO;
        const inv = c.SDL_BLENDFACTOR_ONE_MINUS_SRC_COLOR;
        const op = c.SDL_BLENDOPERATION_ADD;
        return .{
            .add = c.SDL_ComposeCustomBlendMode(one, one, op, zero, one, op),
            .darken = c.SDL_ComposeCustomBlendMode(zero, inv, op, zero, one, op),
            .screen = c.SDL_ComposeCustomBlendMode(one, inv, op, zero, one, op),
            .multiply = c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_DST_COLOR, zero, op, zero, one, op),
        };
    }
};

const menu_font = @import("menu/font.zig");

pub const Menu = struct {
    gpa: Allocator,
    io: Io,
    renderer: *c.SDL_Renderer,
    open: bool = false,
    screen: menu_items.Screen = .main,
    /// Screen we came from (for "back" from slots and credits).
    back_to: menu_items.Screen = .main,
    font: menu_font.MenuFont = .{},
    glow: menu_font.MenuFont = .{},
    modes: Modes,
    /// Scene textures (`gfx_3d\textures\*.3df`).
    logo: ?*c.SDL_Texture = null,
    logo_light: ?*c.SDL_Texture = null,
    circle: ?*c.SDL_Texture = null,
    flare: ?*c.SDL_Texture = null,
    lens: ?*c.SDL_Texture = null,
    lens2: ?*c.SDL_Texture = null,
    /// Monster (`menu.msh`, animation "menu" 1..200) and its part textures.
    models: ?*model_cache.Cache = null,
    part_tex: [8]?*c.SDL_Texture = @splat(null),
    part_tex_loaded: bool = false,
    other: ?archive.Archive = null,
    start_ms: u64 = 0,
    /// Selected item per screen (+0x1c) and the last frame's mouse: the selection
    /// changes only when the mouse moves (0x415b42).
    selected: [std.enums.values(menu_items.Screen).len]usize = @splat(0),
    last_mouse: [2]f32 = .{ -1, -1 },
    /// The selection changed: the host plays `menu1`.
    select_sound: bool = false,
    /// Action sound for the host: "click" (item, submenu, back, list, name entry —
    /// 0x414acf, 0x4149bf, 0x415d6b, 0x414c15, 0x4157db), "keyaccept" (slot load and
    /// save — 0x41566a, 0x415803).
    sound: ?[]const u8 = null,
    /// Newest save file (0x412f70), preselected when the slots screen opens.
    newest: ?usize = null,
    /// Slot labels: "01_port" or empty.
    slots: [menu_items.slot_count]?[]u8 = @splat(null),
    /// Slot thumbnails (213×160) and the `save.spr` frame (0x4152d0).
    thumbs: [menu_items.slot_count]?*c.SDL_Texture = @splat(null),
    /// Current game snapshot: the thumbnail while typing a save name (0x415300…0x415321).
    snapshot: ?*c.SDL_Texture = null,
    save_frame: gfx.Frames = .{},
    strings: ?*const og.formats.strtab.Table = null,
    text_font: ?*const Font = null,
    text: Image,
    text_tex: ?*c.SDL_Texture = null,
    /// Credits (Gui/Credits.cpp): background `credits.spr`, text `credits.inf`,
    /// font `01_credits_1.fnt`; scrolling bottom to top.
    credits_bg: gfx.Frames = .{},
    credits_font_bytes: std.ArrayList([]u8) = .empty,
    credits_font: ?Font = null,
    credits_sets: [10]Font = undefined,
    credits_text: ?[]u8 = null,
    credits_rows: std.ArrayList(CreditRow) = .empty,
    credits_start_ms: u64 = 0,
    /// Credits time offset (`--time` shot).
    credits_skip_ms: u64 = 0,
    /// Mixer volumes (effects, music, speech), changed by the sound screen.
    gains: ?*[3]f32 = null,
    /// Actor shadows (graphics screen).
    shadows: ?*bool = null,
    /// Gamma × 100 (0..400, 0x4065e0).
    gamma: ?*f32 = null,
    /// Slider arrows (`strzalka.3df`) and the pull direction: −1, 0, +1 (mouse or
    /// Left/Right, 0x414f40 — a step every frame).
    arrow: ?*c.SDL_Texture = null,
    hold_mouse: i8 = 0,
    hold_key: i8 = 0,
    /// Settings changed: the host saves them.
    options_changed: bool = false,
    /// A game is running: the main menu has "resume" and "save".
    in_game: bool = false,
    /// "save" is available (no battle, no scene).
    can_save: bool = true,
    /// First visible item of the screen (+0x14) and the hover scroll timer.
    first: [std.enums.values(menu_items.Screen).len]usize = @splat(0),
    scroll_timer: f32 = 1,
    /// Name entry cursor pulse phase (0x651ce0), grows in `tickLogic`.
    pulse_phase: f32 = 0,
    /// Last menu logic tick time (SDL ms), for `tickLogic`.
    tick_ms: u64 = 0,
    /// Save name entry (+0x78): slot, text up to 15 chars.
    editing: ?usize = null,
    edit_buf: [15]u8 = undefined,
    edit_len: usize = 0,
    cursor_tex: ?*c.SDL_Texture = null,
    /// Edition language (string.tab line 950): font letter sets.
    language: u8 = 0,

    pub fn load(io: Io, gpa: Allocator, r: *c.SDL_Renderer, dat: Io.Dir) !Menu {
        var m: Menu = .{ .gpa = gpa, .io = io, .renderer = r, .text = try Image.init(gpa, 640, 480), .modes = .init() };
        errdefer m.deinit();
        var sprites = try archive.Archive.open(io, gpa, dat, "common/sprite.dat");
        defer sprites.close(io, gpa);
        m.other = try archive.Archive.open(io, gpa, dat, "common/other.dat");
        const other = &m.other.?;
        // 0x47ad40: language ≤ 1 — the menu's second page `3d_menu_1_1` (the glow the
        // same), else the language set `<name>_N<suffix>`.
        m.language = lang_mod.language(io, gpa, dat);
        var nb: [2][48]u8 = undefined;
        m.font = menu_font.loadFont(io, gpa, r, other, "3d_menu_1", lang_mod.setName(&nb[0], "3d_menu", m.language) orelse "3d_menu_1_1");
        m.glow = menu_font.loadFont(io, gpa, r, other, "3d_menug_1", lang_mod.setName(&nb[1], "3d_menug", m.language) orelse "3d_menug_1");
        m.logo = menu_font.loadTex(io, gpa, r, other, "gorky.3df");
        m.logo_light = menu_font.loadTex(io, gpa, r, other, "gorky-light.3df");
        m.circle = menu_font.loadTex(io, gpa, r, other, "white_circle.3df");
        m.flare = menu_font.loadTex(io, gpa, r, other, "menuflare.3df");
        m.lens = menu_font.loadTex(io, gpa, r, other, "lens.3df");
        m.lens2 = menu_font.loadTex(io, gpa, r, other, "lens2.3df");
        // Slider arrows: strzalka.3df ([0x51d8b8], 0x414e6a); slot name cursor:
        // kursor.3df ([0x51d8a4], 0x4153f7). The exe loads strzalka_glow.3df
        // ([0x51d8bc]) but never draws it.
        m.arrow = menu_font.loadTex(io, gpa, r, other, "strzalka.3df");
        m.cursor_tex = menu_font.loadTex(io, gpa, r, other, "kursor.3df");
        if (other.find("01_credits_1.fnt")) |e| {
            const b = try other.readAlloc(io, gpa, e);
            try m.credits_font_bytes.append(gpa, b);
            m.credits_font = og.formats.font.parse(b) catch null;
        }
        // Language letter sets `01_credits_N_xx.fnt` (0x47b2a0): the main font with
        // set N's letters overlaid; a `#N` line picks the set.
        if (m.credits_font) |cf| {
            for (&m.credits_sets) |*s| s.* = cf;
            for (other.entries) |*e| {
                if (!std.ascii.startsWithIgnoreCase(e.name, "01_credits_") or std.ascii.eqlIgnoreCase(e.name, "01_credits_1.fnt")) continue;
                const k = std.fmt.charToDigit(e.name["01_credits_".len], 10) catch continue;
                const b = try other.readAlloc(io, gpa, e);
                try m.credits_font_bytes.append(gpa, b);
                const extra = og.formats.font.parse(b) catch continue;
                for (&m.credits_sets[k].glyphs, extra.glyphs) |*g, x| if (x != null) {
                    g.* = x;
                };
            }
        }
        if (sprites.find("save.spr")) |e| {
            const data = try sprites.readAlloc(io, gpa, e);
            defer gpa.free(data);
            m.save_frame = gfx.loadSmooth(gpa, r, "save.spr", data) catch .{};
        }
        if (sprites.find("credits.spr")) |e| {
            const data = try sprites.readAlloc(io, gpa, e);
            defer gpa.free(data);
            m.credits_bg = try gfx.loadFrames(gpa, r, "credits.spr", data);
        }
        var lang = try archive.Archive.open(io, gpa, dat, "common/lang.dat");
        defer lang.close(io, gpa);
        if (lang.find("credits.inf")) |e| {
            m.credits_text = try lang.readAlloc(io, gpa, e);
            try m.layoutCredits();
        }
        m.start_ms = c.SDL_GetTicks();
        return m;
    }

    fn layoutCredits(self: *Menu) !void {
        var lines = std.mem.splitScalar(u8, self.credits_text.?, '\n');
        // Default set: the edition language (0x47b4c6 → 0x47b2a0); `#N` changes it.
        var charset: u8 = if (self.language > 1) self.language else 1;
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            // `#N` (0x42c5e0): letter set for the following lines, not shown itself.
            if (line.len >= 2 and line[0] == '#' and std.ascii.isDigit(line[1])) {
                charset = line[1] - '0';
                continue;
            }
            // A heading is a line with ":" (cftCreditsTitle).
            try self.credits_rows.append(self.gpa, .{ .title = std.mem.indexOfScalar(u8, line, ':') != null, .text = line, .charset = charset });
        }
    }

    pub fn deinit(self: *Menu) void {
        self.credits_bg.deinit(self.gpa);
        for (self.credits_font_bytes.items) |b| self.gpa.free(b);
        self.credits_font_bytes.deinit(self.gpa);
        if (self.credits_text) |b| self.gpa.free(b);
        self.credits_rows.deinit(self.gpa);
        self.font.deinit();
        self.glow.deinit();
        for ([_]?*c.SDL_Texture{ self.logo, self.logo_light, self.circle, self.flare, self.lens, self.lens2, self.arrow, self.cursor_tex }) |t| if (t) |x| c.SDL_DestroyTexture(x);
        for (self.part_tex) |t| if (t) |x| c.SDL_DestroyTexture(x);
        if (self.other) |*o| o.close(self.io, self.gpa);
        if (self.text_tex) |t| c.SDL_DestroyTexture(t);
        for (self.slots) |s| if (s) |b| self.gpa.free(b);
        for (self.thumbs) |t| if (t) |x| c.SDL_DestroyTexture(x);
        if (self.snapshot) |x| c.SDL_DestroyTexture(x);
        self.save_frame.deinit(self.gpa);
        self.text.deinit(self.gpa);
    }

    pub fn show(self: *Menu, screen: menu_items.Screen) void {
        self.open = true;
        // The menu is rebuilt on every open (0x4134e0): selection and scroll of all
        // screens start at the first item.
        if (screen == .main or screen == .ingame) {
            self.selected = @splat(0);
            self.first = @splat(0);
            self.editing = null;
        }
        if (screen == .credits) {
            self.back_to = if (self.screen == .credits) .main else self.screen;
            self.credits_start_ms = c.SDL_GetTicks();
            self.credits_skip_ms = 0;
        }
        self.in_game = screen == .ingame or (self.in_game and screen != .main);
        self.screen = screen;
    }

    pub fn items(self: *Menu) []const menu_items.Item {
        return switch (self.screen) {
            .main => &menu_items.main_items,
            .ingame => if (self.can_save) &menu_items.ingame_items else &menu_items.ingame_items_nosave,
            .options => &menu_items.options_items,
            .sound => &menu_items.sound_items,
            .graphics => &menu_items.graphics_items,
            .load, .save => &menu_items.slot_items,
            .credits => &.{},
        };
    }

    /// Item offset (+0x20): main 0, slots and settings 47, sound and graphics 94.
    pub fn offset(self: *Menu) f32 {
        return switch (self.screen) {
            .main, .ingame, .credits => 0,
            .load, .save, .options => hSpace(),
            .sound, .graphics => 2 * hSpace(),
        };
    }

    /// Screen title (0x412d80).
    pub fn title(self: *Menu) ?[]const u8 {
        const id: i32, const fb: []const u8 = switch (self.screen) {
            .load => .{ 307, "load" },
            .save => .{ 301, "save" },
            .options => .{ 302, "options" },
            .sound => .{ 309, "sound options" },
            .graphics => .{ 310, "graphics options" },
            else => return null,
        };
        return self.str(id, fb);
    }

    fn str(self: *Menu, id: i32, fb: []const u8) []const u8 {
        if (id >= 0) if (self.strings) |s| if (s.get(id)) |t| return t;
        return fb;
    }

    /// Item label; volume shows a percentage, shadows on/off.
    pub fn label(self: *Menu, it: menu_items.Item, buf: []u8) []const u8 {
        const name = self.str(it.text_id, it.fallback);
        return switch (it.kind) {
            // Slider (0x414d60): "%s %d", the name got three spaces appended at
            // creation (0x51dbb4), leaving room for the left arrow between name and number.
            .gain, .gamma => if (sliderValue(self, it)) |v| std.fmt.bufPrint(buf, "{s}    {d}", .{ name, @as(i32, @intFromFloat(@round(v))) }) catch name else name,
            // Shadows: list "disabled" / "enabled" (326/327), label "%s: %s" (0x414c40).
            .shadows => std.fmt.bufPrint(buf, "{s}: {s}", .{ name, if (self.shadows) |sh| (if (sh.*) self.str(327, "enabled") else self.str(326, "disabled")) else "" }) catch name,
            // Slot: the save name or "empty N" (311); a name being typed as is.
            .slot => |k| blk: {
                if (self.editing == k) break :blk self.edit_buf[0..self.edit_len];
                if (self.slots[k]) |n| break :blk n;
                break :blk std.fmt.bufPrint(buf, "{s} {d}", .{ self.str(311, "empty"), k + 1 }) catch "empty";
            },
            else => name,
        };
    }

    /// Visible items (+0x14, +0x38): 5 for slots, all for others.
    pub fn visible(self: *Menu) [2]usize {
        const n = self.items().len;
        if (self.screen != .load and self.screen != .save) return .{ 0, n };
        const f = @min(self.first[@backingInt(self.screen)], n -| menu_items.visible_slots);
        return .{ f, @min(n, f + menu_items.visible_slots) };
    }

    /// Baseline of item k: 220 + offset + 47·(k − first visible).
    pub fn itemY(self: *Menu, k: usize) f32 {
        const f = self.visible()[0];
        return startY() + self.offset() + hSpace() * (og.num.toF32(k) - og.num.toF32(f));
    }

    /// Slider (0x508434): volume 0..100 step 1, gamma 0..400 step 5.
    const Slider = struct { min: f32, max: f32, step: f32 };

    const Arrows = struct { hit: [2][4]f32, draw_x: [2]f32 };

    /// Entering the slots screen (0x415a50 → 0x412f70): the slot with the newest file
    /// is selected, the list scrolled to it (no further than the last five items).
    fn selectNewest(self: *Menu) void {
        const k = self.newest orelse return;
        self.selected[@backingInt(self.screen)] = k;
        self.first[@backingInt(self.screen)] = @min(k, menu_items.slot_items.len - menu_items.visible_slots);
    }

    fn slider(it: menu_items.Item) ?Slider {
        return switch (it.kind) {
            .gain => .{ .min = 0, .max = 100, .step = 1 },
            .gamma => .{ .min = 0, .max = 400, .step = 5 },
            else => null,
        };
    }

    fn sliderValue(self: *Menu, it: menu_items.Item) ?f32 {
        return switch (it.kind) {
            .gain => |g| if (self.gains) |gs| @round(gs[g] * 100) else null,
            .gamma => if (self.gamma) |gm| gm.* else null,
            else => null,
        };
    }

    fn setSlider(self: *Menu, it: menu_items.Item, v: f32) void {
        switch (it.kind) {
            .gain => |g| if (self.gains) |gs| {
                gs[g] = v / 100;
            },
            .gamma => if (self.gamma) |gm| {
                gm.* = v;
            },
            else => return,
        }
        self.options_changed = true;
    }

    /// ←/→ pressed: a slider steps at once and then every tick while the key is held
    /// (0x414f40, 0x404220); a list (shadows) steps once with a sound (0x414b90).
    /// Release sets `hold_key = 0`.
    pub fn stepKey(self: *Menu, d: i8) void {
        self.hold_key = d;
        stepSlider(self);
        const list = self.items();
        const sel = self.selected[@backingInt(self.screen)];
        if (sel >= list.len or slider(list[sel]) == null) self.hold_key = 0;
    }

    /// Slider step of the selected item: the arrow under the mouse or a key.
    fn stepSlider(self: *Menu) void {
        const d = if (self.hold_mouse != 0) self.hold_mouse else self.hold_key;
        if (d == 0) return;
        const list = self.items();
        const sel = self.selected[@backingInt(self.screen)];
        if (sel >= list.len) return;
        const it = list[sel];
        const sl = slider(it) orelse {
            // Value list (shadows, 0x414b90): a key step goes to the next value
            // cyclically, "click" sound.
            if (it.kind == .shadows and self.hold_key != 0) {
                _ = self.activate(it);
                self.hold_key = 0;
            }
            return;
        };
        const v = sliderValue(self, it) orelse return;
        setSlider(self, it, std.math.clamp(v + sl.step * og.num.toF32(d), sl.min, sl.max));
    }

    /// Arrows of the selected slider (0x414e20), 32×32 at line − 32: the left one after
    /// the name with three spaces, 23 px further left (left + w(name) − 23); the right
    /// one after the label: clicked at (right + 7), drawn 7 further right (right + 14).
    /// `hit` are the click rects, `draw_x` the draw x.
    pub fn arrows(self: *Menu) ?Arrows {
        const list = self.items();
        const sel = self.selected[@backingInt(self.screen)];
        if (sel >= list.len or slider(list[sel]) == null) return null;
        var buf: [96]u8 = undefined;
        const w = self.font.width(self.label(list[sel], &buf));
        var nb: [96]u8 = undefined;
        const name = std.fmt.bufPrint(&nb, "{s}   ", .{self.str(list[sel].text_id, list[sel].fallback)}) catch "";
        const left = @floor((640 - w) / 2);
        const lx = left + self.font.width(name) - 23;
        const rx = left + w + 7;
        const y = self.itemY(sel);
        return .{ .hit = .{ .{ lx, y - 32, 32, 32 }, .{ rx, y - 32, 32, 32 } }, .draw_x = .{ lx, rx + 7 } };
    }

    fn arrowAt(self: *Menu, mx: f32, my: f32) ?i8 {
        const a = arrows(self) orelse return null;
        for (a.hit, [2]i8{ -1, 1 }) |rc, d| if (mx >= rc[0] and mx < rc[0] + rc[2] and my >= rc[1] and my < rc[1] + rc[3]) return d;
        return null;
    }

    /// Left press on a slider arrow: a step at once, then every tick while the button
    /// is held and the mouse is on the arrow (0x414f5d…0x414fc6, 0x4047c0).
    pub fn press(self: *Menu, mx: f32, my: f32) bool {
        const d = arrowAt(self, mx, my) orelse return false;
        self.hold_mouse = d;
        stepSlider(self);
        return true;
    }

    pub fn release(self: *Menu) void {
        self.hold_mouse = 0;
    }

    /// Item under the mouse (0x415b42): (640 − w)/2 − 32 … (640 + w)/2 + 32 in X,
    /// y + 8 − 47 … y + 8 in Y.
    pub fn itemAt(self: *Menu, mx: f32, my: f32) ?usize {
        const list = self.items();
        var buf: [96]u8 = undefined;
        const vr = self.visible();
        for (list[vr[0]..vr[1]], vr[0]..) |it, k| {
            const w = self.font.width(self.label(it, &buf));
            const y = self.itemY(k);
            const l = @floor((640 - w) / 2); // integer (640 − w) / 2 (0x415bc2)
            if (mx >= l - 32 and mx <= l + w + 32 and my >= y + 8 - hSpace() and my <= y + 8) return k;
        }
        return null;
    }

    /// Arrow selection (0x415940, 0x4159d0): cyclic, the selection stays visible.
    pub fn keyNav(self: *Menu, d: i32) void {
        const n = self.items().len;
        if (n == 0) return;
        const s = &self.selected[@backingInt(self.screen)];
        s.* = @intCast(@mod(@as(i32, @intCast(s.*)) + d, @as(i32, @intCast(n))));
        self.keepVisible();
        self.select_sound = true;
    }

    fn keepVisible(self: *Menu) void {
        if (self.screen != .load and self.screen != .save) return;
        const s = self.selected[@backingInt(self.screen)];
        const f = &self.first[@backingInt(self.screen)];
        if (s < f.*) f.* = s;
        if (s >= f.* + menu_items.visible_slots) f.* = s + 1 - menu_items.visible_slots;
    }

    /// Menu logic ticks at 30 Hz: slot hover scrolling and held slider arrows
    /// (0x414f40: a step per tick while the key or button is held).
    pub fn tickLogic(self: *Menu, mouse: [2]f32) void {
        const now = c.SDL_GetTicks();
        // The menu was closed: don't catch up on ticks.
        if (self.tick_ms == 0 or now -% self.tick_ms > 200) self.tick_ms = now;
        while (now -% self.tick_ms >= tick_len_ms) {
            self.tick_ms +%= tick_len_ms;
            self.pulse_phase += gfx.tileFlashStep();
            if (self.screen == .load or self.screen == .save) self.hoverTick(mouse);
            if (self.hold_key != 0) {
                stepSlider(self);
            } else if (self.hold_mouse != 0 and arrowAt(self, mouse[0], mouse[1]) == self.hold_mouse) {
                stepSlider(self);
            }
        }
    }

    const tick_len_ms = 1000 / og.state.world.tick_hz;

    /// Hovering the edge visible slot (0x415cae…0x415d3d) is menu logic at 30 Hz
    /// (0x405d88 → 0x406040 → 0x415ad0), not the draw frame: timer 1.0, −0.15 per
    /// tick; when it drops below zero and the edge visible slot is under the mouse
    /// the selection moves by one (0x415940 / 0x4159d0, the list follows) and the
    /// timer resets to 1.0 — a step every 7 ticks (≈ 4 slots per second).
    fn hoverTick(self: *Menu, mouse: [2]f32) void {
        const sel = self.selected[@backingInt(self.screen)];
        if (self.itemAt(mouse[0], mouse[1]) == sel and self.scroll_timer < 0) {
            const vr = self.visible();
            const up = sel == vr[0] and sel > 0;
            const down = sel + 1 == vr[1] and sel + 1 < self.items().len;
            if (up or down) {
                self.keyNav(if (up) -1 else 1);
                self.scroll_timer = 1;
                return;
            }
        }
        self.scroll_timer -= 0.15;
    }

    /// Right button, Backspace, Esc (0x415d30…0x415d94): to the parent screen with a
    /// "click". While typing a name the slot (0x415470) takes them, so they don't act;
    /// credits leave only on Esc (`escape`).
    pub fn back(self: *Menu) void {
        if (self.editing != null or self.screen == .credits) return;
        self.sound = "click";
        self.screen = switch (self.screen) {
            .sound, .graphics => .options,
            .main, .ingame => return,
            else => if (self.in_game) .ingame else .main,
        };
    }

    /// Esc: while typing a name — cancel, the old name, "click" (0x4154b0…0x415531);
    /// in credits — end them (0x42c833 → 0x42ca40); otherwise `back`.
    pub fn escape(self: *Menu) void {
        if (self.editing != null) {
            self.editing = null;
            self.sound = "click";
            return;
        }
        if (self.screen == .credits) {
            self.screen = self.back_to;
            return;
        }
        self.back();
    }

    /// Enter: while typing a name — save (0x415830), else like clicking the selection.
    pub fn enter(self: *Menu) menu_items.Action {
        if (self.editing) |k| return .{ .save = k };
        const list = self.items();
        const sel = self.selected[@backingInt(self.screen)];
        if (sel >= list.len) return .none;
        return self.activate(list[sel]);
    }

    /// Click: an action for the host (moves between menu screens happen inside).
    pub fn click(self: *Menu, mx: f32, my: f32) menu_items.Action {
        // Credits don't close on a click, only on Esc (0x42c833).
        if (self.screen == .credits) return .none;
        const k = self.itemAt(mx, my) orelse return .none;
        self.selected[@backingInt(self.screen)] = k;
        return self.activate(self.items()[k]);
    }

    fn activate(self: *Menu, it: menu_items.Item) menu_items.Action {
        switch (it.kind) {
            // Action item (0x414aa0): "click", then the action.
            .action => |a| {
                self.sound = "click";
                return a;
            },
            .open => |scr| {
                self.sound = "click";
                if (scr == .credits) {
                    self.show(.credits);
                    return .none;
                }
                // Submenu (0x414990 → 0x415a50).
                self.back_to = self.screen;
                self.screen = scr;
                self.editing = null;
                if (scr == .load or scr == .save) self.selectNewest();
            },
            .back => self.back(),
            // A slider changes with its arrows; a click on the label does nothing.
            .gain, .gamma => {},
            // List (0x414b90): a click selects the next value, "click".
            .shadows => if (self.shadows) |sh| {
                sh.* = !sh.*;
                self.options_changed = true;
                self.sound = "click";
            },
            // Slot (0x415660): load — "keyaccept", then the file if present; save —
            // name entry ("click"; "empty N" is cleared), a second click or Enter saves
            // (0x4157fc).
            .slot => |k| if (self.screen == .load) {
                self.sound = "keyaccept";
                if (self.slots[k] != null) return .{ .load = k };
            } else if (self.editing == k) {
                return .{ .save = k };
            } else {
                self.editing = k;
                self.sound = "click";
                const n = self.slots[k] orelse "";
                self.edit_len = @min(n.len, self.edit_buf.len);
                @memcpy(self.edit_buf[0..self.edit_len], n[0..self.edit_len]);
            },
        }
        return .none;
    }
};

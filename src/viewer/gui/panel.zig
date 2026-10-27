//! Battle and exploration panel: buttons, portraits, hand weapon, panel tooltip, cursor, hero frame, caption. Gui methods (see gui.zig).

const rects = [15][4]f32{
    .{ 4, 21, 35, 61 },    .{ 40, 21, 73, 61 },   .{ 85, 5, 153, 60 },   .{ 155, 6, 175, 60 },
    .{ 188, 21, 218, 61 }, .{ 224, 21, 257, 61 }, .{ 270, 5, 313, 52 },  .{ 320, 5, 363, 52 },
    .{ 370, 5, 413, 52 },  .{ 420, 5, 463, 52 },  .{ 470, 5, 513, 52 },  .{ 524, 21, 565, 60 },
    .{ 574, 21, 602, 60 }, .{ 609, 20, 633, 41 }, .{ 608, 44, 633, 60 },
};
/// Hints (string.tab); portraits show the hero's name.
const tooltips = [15]i32{ 502, 503, 504, 505, 506, 507, 0, 0, 0, 0, 0, 508, 509, 510, 511 };
/// Pressed button frame and offset (0x4b2380): 35…42.
const pressed = [15]?struct { frame: usize, dx: f32 }{
    .{ .frame = 35, .dx = 4 }, .{ .frame = 36, .dx = 4 }, null,                      .{ .frame = 37, .dx = 1 },
    .{ .frame = 38, .dx = 4 }, .{ .frame = 39, .dx = 4 }, null,                      null,
    null,                      null,                      null,                      null,
    .{ .frame = 40, .dx = 2 }, .{ .frame = 41, .dx = 3 }, .{ .frame = 42, .dx = 3 },
};

const std = @import("std");
const gui_mod = @import("../gui.zig");
const gui_short = @import("short.zig");
const gui_text = @import("text.zig");
const Gui = gui_mod.Gui;
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");
const panel_h = gui_mod.panel_h;
const Cursor = gui_mod.Cursor;
const panel_y = gui_mod.panel_y;
const Button = gui_mod.Button;
const shutters = gui_mod.shutters;

/// Panel button centre (for hotkeys).
pub fn rectCenter(btn: Button) [2]f32 {
    const rc = rect(@backingInt(btn));
    return .{ (rc[0] + rc[2]) / 2, (rc[1] + rc[3]) / 2 };
}

fn rect(i: usize) [4]f32 {
    const r = rects[i];
    return .{ r[0], r[1] + panel_y, r[2], r[3] + panel_y };
}

fn inside(rc: [4]f32, x: f32, y: f32) bool {
    return x >= rc[0] and x <= rc[2] and y >= rc[1] and y <= rc[3];
}

/// The button is a hero portrait.
pub fn isPortrait(b: Button) bool {
    return switch (b) {
        .hero0, .hero1, .hero2, .hero3, .hero4 => true,
        else => false,
    };
}

/// Button under a screen point (first matching rect, 0x4b2440).
pub fn buttonAt(x: f32, y: f32) ?Button {
    for (0..rects.len) |i| if (inside(rect(i), x, y)) return @fromBackingInt(@intCast(i));
    return null;
}

/// Button availability (0x4b18a0).
pub fn enabled(w: *og.state.world.World, btn: Button) bool {
    const hero = w.selectedHero() orelse return false;
    const heroes = w.party();
    const party = heroes.slice();
    const i = @backingInt(btn);
    // A disabled hero (DisableHeroes: inside the tunnel and the worker's room only
    // the selected one) can't be picked; the portrait is shuttered.
    if (i >= 6 and i <= 10) return i - 6 < party.len and party[i - 6].enabled;
    if (btn == .skills or btn == .stats) return true;
    const b = if (w.battle) |*bt| bt else {
        return switch (btn) {
            .inventory, .give, .hand, .short_list => true,
            else => false,
        };
    };
    const busy = b.pending != .none or b.phase != .player;
    const acted = if (b.fighterOf(hero)) |fi| b.fighters.items[fi].acted else false;
    return switch (btn) {
        .inventory, .give, .hand, .short_list, .defend => !busy and !acted,
        // Push (0x4b1907): not Medusa (119), not a woman (`sex` 1, +0x24580), the hero
        // hasn't moved yet; not during a counterattack (phase).
        .push => !busy and !acted and !og.fields.isMedusa(hero) and hero.getInt("sex") != 1,
        .turn => true,
        .end_turn => !busy,
        else => true,
    };
}

/// Shutters per tick (0x4b2440): an inactive button closes (+0.6), an active one opens.
fn tickPanel(self: *Gui, w: *og.state.world.World) void {
    if (w.ticks == self.shutter_tick) return;
    const n = @min(w.ticks -% self.shutter_tick, 30);
    self.shutter_tick = w.ticks;
    // The inventory button changed direction: "menu_open" / "menu_close" (0x4b24ee).
    const inv_open = enabled(w, .inventory);
    if (self.inv_dir) |prev| if (prev != inv_open) {
        w.out.sound(w.gpa, if (inv_open) "menu_open" else "menu_close", null);
    };
    self.inv_dir = inv_open;
    for (shutters, 0..) |sh, i| {
        const m = sh orelse continue;
        const d: f32 = if (enabled(w, @fromBackingInt(@intCast(i)))) -0.6 else 0.6;
        self.shutter[i] = std.math.clamp(self.shutter[i] + d * og.num.toF32(n), m[0], m[1]);
    }
}

/// Tooltip of the button under the cursor (string.tab 502–511; a portrait shows the hero's name).
pub fn tooltip(self: *Gui, w: *og.state.world.World, strings: ?*const og.formats.strtab.Table) ?[]const u8 {
    self.tip_extra = ""; // else a medicine's "+20HP" sticks to the portrait hint
    const btn = self.hover_btn orelse return null;
    const i = @backingInt(btn);
    if (!enabled(w, btn)) return null;
    if (i >= 6 and i <= 10) {
        const heroes = w.party();
        const party = heroes.slice();
        if (i - 6 >= party.len) return null;
        const hero = party[i - 6];
        if (strings) |st| if (st.get(og.fields.nameId(hero))) |t| return t;
        return hero.name;
    }
    // Hand button (0x4b26a7…0x4b26e8): an item in hand shows the item tooltip
    // (0x45c6b0: name and skill "Lv.N"); an empty hand in battle does the same for
    // the fist "GS_fist_all" (0x5249ec); otherwise "Hand" (504).
    if (btn == .hand) if (w.selectedHero()) |hero| {
        const held = og.inventory.equipment.equipped(w, hero, .hand) orelse if (w.battle != null) w.rt.findObject("GS_fist_all") else null;
        if (held) |o| if (gui_short.itemTooltip(self, hero, o, strings)) |t| return t;
    };
    if (strings) |st| return st.get(tooltips[i]);
    return null;
}

/// Atlas font string centred on `cx` at baseline `baseline` (0x47a970): glyph top =
/// line + (y − base), with the 02_HP extra spacing +1 (0x45a25c).
pub fn drawGlyphsBase(self: *Gui, r: *c.SDL_Renderer, glyphs: *const [256]?og.formats.font.TexGlyph, frame: usize, t: []const u8, cx: f32, baseline: f32) !void {
    const spacing = 1;
    if (self.atlas.len() <= frame) return;
    var x = cx - gfx.texTextWidth(glyphs, t, spacing) / 2;
    for (t) |ch| if (glyphs[ch]) |g| {
        const top = baseline + og.num.toF32(g.y - g.base);
        try self.atlas.drawPart(r, frame, gfx.glyphSrc(g), x, top);
        x += og.num.toF32(g.advance) + spacing;
    };
}

/// `scaling = adaptive`: a riveted plate on each side of the wide frame at the
/// panel's low part (rows 16…68), so scrolling past the background's bottom (the
/// exe's 50-row margin) shows no black beside the 640-wide panel. 9-grid: its frame
/// and rivets keep their size, the middle stretches.
fn drawPanelSides(self: *Gui, r: *c.SDL_Renderer) !void {
    if (gfx.wide == 0) return;
    const plate = self.plate orelse return;
    gfx.wholeView(r);
    defer gfx.middleView(r);
    const y0: f32 = 16;
    for ([2]f32{ 0, 640 + gfx.wide }) |x|
        try gfx.check(c.SDL_RenderTexture9Grid(r, plate, null, 33, 33, 45, 45, 0.35, &.{ .x = x, .y = panel_y + y0, .w = gfx.wide, .h = panel_h - y0 }));
}

/// Panel (0x4b1d50): frame 0, portraits (frame 2; 3 when spent in battle), selection
/// frame (frame 3), health bar (frame 2, 38×7) and "hp/max", round number, pressed
/// button, shutters.
pub fn drawPanel(self: *Gui, r: *c.SDL_Renderer, w: *og.state.world.World) !void {
    tickPanel(self, w);
    if (self.panel.len() > 0) try drawPanelSides(self, r);
    if (self.panel.len() > 0) try self.panel.draw(r, 0, 0, panel_y);
    const heroes = w.party();
    if (self.text) |*t| @memset(t.pixels, 0);
    for (heroes.slice(), 0..) |hero, i| {
        if (i >= 5) break;
        const rc = rect(6 + i);
        const sel = std.ascii.eqlIgnoreCase(hero.name, w.selected_hero);
        // Grey portrait (frame 3, 0x4b1de8 → 0x4922d0): in battle — acted
        // (+0x24610/+0x24614) with less than 1 move left; outside battle — Medusa (0x4b1df1).
        var exhausted = w.battle == null and og.fields.isMedusa(hero);
        if (w.battle) |*b| if (b.fighterOf(hero)) |fi| {
            const f = b.fighters.items[fi];
            exhausted = f.acted and f.budget() < 1.0;
        };
        if (self.portrait(hero)) |fr| if (fr.len() > 2) {
            const k: usize = if (exhausted and fr.len() > 3) 3 else 2;
            const size = fr.sizes.items[k];
            try fr.draw(r, k, gfx.Frames.center(rc[0], rc[2] - rc[0], size[0]), gfx.Frames.center(rc[1], rc[3] - rc[1], size[1]));
        };
        if (sel and self.panel.len() > 3) try self.panel.draw(r, 3, rc[0] + 1, rc[1]);
        const max_hp = @max(1, og.fields.maxHp(hero));
        const hp = og.fields.hp(hero);
        if (self.panel.len() > 2) {
            const k = std.math.clamp(og.num.toF32(hp) / og.num.toF32(max_hp), 0, 1);
            try self.panel.drawClipped(r, 2, rc[0] + 2, rc[1] + 50, @trunc(k * 38)); // _ftol (0x4b1d20)
        }
        if (self.font) |f| if (self.text) |t| {
            var tb: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&tb, "{d}/{d}", .{ hp, max_hp }) catch continue;
            const tw: i32 = @intCast(f.measure(s));
            const x: i32 = @as(i32, @intFromFloat(rc[0])) + 21 - @divTrunc(tw, 2);
            const y: i32 = @as(i32, @intFromFloat(rc[1] - panel_y)) + 50;
            f.draw(t, x + 1, y, s, .{ 10, 10, 10 });
            f.draw(t, x, y, s, gui_mod.text_light);
        };
    }
    if (self.text) |t| {
        const tex = try gfx.reuseTexture(r, &self.text_tex, t);
        const dst: c.SDL_FRect = .{ .x = 0, .y = panel_y, .w = 640, .h = panel_h };
        try gfx.check(c.SDL_RenderTexture(r, tex, null, &dst));
    }
    // Round number (0x4b1fbb, 02_hp atlas): centred at x = 547, baseline
    // y = button top 11 + 0x20 = 465.
    if (w.battle) |*b| {
        var tb: [12]u8 = undefined;
        const s = std.fmt.bufPrint(&tb, "{d}", .{b.turn}) catch "";
        try drawGlyphsBase(self, r, &self.hp_glyphs, 1, s, 547, panel_y + 21 + 32);
    }
    // Pressed button only while the mouse is held over it.
    if (self.pressed_btn) |pb| if (pb == self.hover_btn) if (pressed[@backingInt(pb)]) |pf| {
        const rc = rect(@backingInt(pb));
        if (self.panel.len() > pf.frame) try self.panel.draw(r, pf.frame, rc[0] + pf.dx, rc[1] + 1);
    };
}

/// Panel shutters (0x4b2347), over the hand weapon and the ammo count.
pub fn drawShutters(self: *Gui, r: *c.SDL_Renderer) !void {
    for (shutters, 0..) |sh, i| {
        _ = sh orelse continue;
        const fr: usize = @intFromFloat(@trunc(self.shutter[i])); // _ftol (0x4b2358)
        if (fr >= self.panel.len()) continue;
        const rc = rect(i);
        // Shutter from the button's top-left corner (0x4b2347).
        try self.panel.draw(r, fr, rc[0], rc[1]);
    }
}

/// Dialog box images: speaker portrait (`icons\\<spriteFile>.spr`; HQ —
/// "Head Quarters", Lamare — "Lamare", 0x459180) and `dialog_box.spr`.
pub fn dialogArt(self: *Gui, w: *og.state.world.World) @import("../level/overlay.zig").DialogArt {
    const st = w.scene.subtitle orelse return .{};
    var art: @import("../level/overlay.zig").DialogArt = .{ .box = &self.dialog_box };
    if (w.actorObject(st.speaker)) |o| {
        art.portrait = self.portrait(o);
    } else if (std.ascii.eqlIgnoreCase(st.speaker, "HQ")) {
        art.portrait = self.icon("Head Quarters");
    } else if (std.ascii.startsWithIgnoreCase(st.speaker, "Lamar")) {
        art.portrait = self.icon("Lamare");
    }
    return art;
}

/// Caption (0x45a960): frame at (0, 440); fades in at 2–3 s, visible until 7 s,
/// fades out at 7–8 s.
pub fn drawSignature(self: *Gui, r: *c.SDL_Renderer, w: *og.state.world.World) !void {
    const sg = w.scene.signature orelse return;
    if (sg.frame >= self.intro.len()) return;
    const t = og.num.toF32(w.ticks -% sg.start) / @as(f32, og.state.world.tick_hz);
    if (t < 2 or t > 8) return;
    const a: f32 = if (t < 3) t - 2 else if (t > 7) 8 - t else 1;
    const tex = self.intro.textures.items[sg.frame];
    _ = c.SDL_SetTextureAlphaModFloat(tex, a);
    defer _ = c.SDL_SetTextureAlphaModFloat(tex, 1);
    try self.intro.draw(r, sg.frame, 0, 440);
}

/// Panel click: the hero's name if a portrait was hit.
pub fn heroAt(w: *og.state.world.World, x: f32, y: f32) ?*og.script.object.Object {
    const btn = buttonAt(x, y) orelse return null;
    const i = @backingInt(btn);
    if (i < 6 or i > 10) return null;
    const heroes = w.party();
    const party = heroes.slice();
    if (i - 6 >= party.len) return null;
    return party[i - 6];
}

/// Bitmap font text with a (10,10,10) shadow at (x, y) or centred on x.
pub fn label(self: *Gui, r: *c.SDL_Renderer, font: ?og.formats.font.Font, x: f32, y: f32, s: []const u8, col: [3]u8, centered: bool) !void {
    return labelImpl(self, r, font, x, y, s, col, centered, true);
}

/// Panel weapon slot (0x4b20f3, coordinates 0x52b3a8: 85,5–153,60): the selected
/// hero's hand weapon icon; if it needs ammo, a backing (panel frame 44) and the
/// count (0x6c624c).
pub fn drawWeapon(self: *Gui, r: *c.SDL_Renderer, w: *og.state.world.World) !void {
    const hero = w.selectedHero() orelse return;
    const slot: c.SDL_FRect = .{ .x = 85, .y = panel_y + 5, .w = 68, .h = 55 };
    const wpn = og.inventory.equipment.equipped(w, hero, .hand) orelse {
        // In battle with no weapon (not Medusa): the fist, frame 1 centred in the slot.
        if (w.battle != null and !og.fields.isMedusa(hero) and self.panel.len() > 1) {
            const sz = self.panel.sizes.items[1];
            try self.panel.drawShadowed(r, 1, gfx.Frames.center(slot.x, slot.w, sz[0]), gfx.Frames.center(slot.y, slot.h, sz[1]));
        }
        return;
    };
    defer if (!og.inventory.equipment.weaponVisible(og.fields.nameId(hero), og.fields.nameId(wpn)) and self.panel.len() > 43) {
        // Unusable by the hero (0x481f50): crossed out, frame 43 at (slot.x − 1,
        // slot.y + 3) = (84, 420) (0x4b22ee).
        self.panel.draw(r, 43, slot.x - 1, slot.y + 3) catch {};
    };
    // Icon frame 1 centred in the slot with its shadow (0x47d6e0, 0x4b212a).
    if (self.icon(wpn.getString("spriteFile"))) |fr| if (fr.len() > 0) {
        const k: usize = if (fr.len() > 1) 1 else 0;
        const size = fr.sizes.items[k];
        try fr.drawShadowed(r, k, gfx.Frames.center(slot.x, slot.w, size[0]), gfx.Frames.center(slot.y, slot.h, size[1]));
    };
    // Rechargeable (0x4b21f4): red battery (frame 45) and the turns left, or green
    // (46) when ready; at (88, 451), the number in font 2 centred at (109, 460).
    const rt = og.battle.rules.rechargeTurns(wpn.getInt("classType"));
    if (rt > 0) {
        const left = og.state.world.World.nativeOf(wpn).fight.recharge;
        if (left > 0) {
            if (self.panel.len() > 45) try self.panel.draw(r, 45, 85 + 3, panel_y + 5 + 0x22);
            var rb: [16]u8 = undefined;
            const rs = std.fmt.bufPrint(&rb, "{d}", .{left}) catch return;
            try labelImpl(self, r, self.font, 85 + 24, 460, rs, gui_mod.text_light, true, false); // no shadow (0x4b22a9)
        } else if (self.panel.len() > 46) try self.panel.draw(r, 46, 85 + 3, panel_y + 5 + 0x22);
        return;
    }
    const id = wpn.getInt("ammoUsed");
    if (id <= 0) return;
    const n = og.inventory.ammo.ammoCount(w, hero.name, id);
    if (self.panel.len() > 44) try self.panel.draw(r, 44, 85 + 3, panel_y + 5 + 0x22);
    var buf: [16]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    // Font 2 centred at (109, 460), no shadow (0x4b21e8: flag 0).
    try labelImpl(self, r, self.font, 85 + 24, 460, t, gui_mod.text_light, true, false);
}

/// Selected hero frame outside battle (0x45b920): border.spr corners on the model's
/// screen rect — 0 (left, top + 5), 2 (right − 7, top + 5), 1 (left, bottom − 5),
/// 3 (right − 7, bottom − 5).
pub fn drawHeroFrame(self: *Gui, r: *c.SDL_Renderer, box: [4]f32) !void {
    if (self.border.len() < 4) return;
    try self.border.draw(r, 0, box[0], box[1] + 5);
    try self.border.draw(r, 2, box[2] - 7, box[1] + 5);
    try self.border.draw(r, 1, box[0], box[3] - 5);
    try self.border.draw(r, 3, box[2] - 7, box[3] - 5);
}

pub fn drawCursor(self: *Gui, r: *c.SDL_Renderer, x0: f32, y: f32) !void {
    if (self.cursor.len() == 0) return;
    // Over the whole frame: the pointer can be over the wide frame's sides.
    gfx.wholeView(r);
    defer gfx.middleView(r);
    const x = x0 + gfx.wide;
    const k = if (self.cursor_frame < self.cursor.len()) self.cursor_frame else 0;
    self.cursor_frame = 0;
    if (self.cursor_anchor == .push and self.cursor.len() > 2) {
        const sz = self.cursor.sizes.items[2];
        return self.cursor.draw(r, k, x - og.num.toF32(sz[0] / 5), y - og.num.toF32(sz[1] / 5));
    }
    if (self.cursor_anchor == .center2 and self.cursor.len() > 2) {
        const sz = self.cursor.sizes.items[2];
        return self.cursor.draw(r, k, x - og.num.toF32(sz[0] / 2), y - og.num.toF32(sz[1] / 2));
    }
    // Crosshair (frames 1, 7–16) and exit (4) centred on the cursor (0x4527b8).
    if (k == Cursor.crosshair or k == Cursor.exit or k >= Cursor.aim_empty) {
        const sz = self.cursor.sizes.items[k];
        return self.cursor.draw(r, k, x - og.num.toF32(sz[0]) / 2, y - og.num.toF32(sz[1]) / 2);
    }
    try self.cursor.draw(r, k, x, y);
}

fn labelImpl(self: *Gui, r: *c.SDL_Renderer, font: ?og.formats.font.Font, x: f32, y: f32, s: []const u8, col: [3]u8, centered: bool, shadow: bool) !void {
    const f = font orelse return;
    const tw: u32 = f.measure(s) + 2;
    const th: u32 = f.height + 2;
    var h = std.hash.Wyhash.init(2);
    h.update(s);
    h.update(&col);
    h.update(std.mem.asBytes(&gui_text.fontId(f)));
    h.update(&.{@intFromBool(shadow)});
    const tex = self.texts.get(h.final()) orelse blk: {
        var img = try og.formats.image.Image.init(self.gpa, tw, th);
        defer img.deinit(self.gpa);
        @memset(img.pixels, 0);
        if (shadow) gui_mod.textShadow(f, img, 0, 0, s, col) else f.draw(img, 0, 0, s, col);
        break :blk try self.texts.put(r, h.final(), img);
    };
    // Centred by an integer shift x − (w >> 1) (0x47b640).
    const fx: f32 = if (centered) x - og.num.toF32((tw - 2) >> 1) else x;
    try gfx.check(c.SDL_RenderTexture(r, tex, null, &.{ .x = @round(fx), .y = y, .w = @floatFromInt(tw), .h = @floatFromInt(th) }));
}

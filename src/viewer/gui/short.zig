//! Hero quick list (0x4b1510): rows, scrolling, tooltip. Gui methods (see gui.zig).

const std = @import("std");
const gui_mod = @import("../gui.zig");
const Gui = gui_mod.Gui;
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");
const ShortItem = Gui.ShortItem;
const short_rows = Gui.short_rows;

/// Quick list contents (0x4b1510), see inventory.shortList.
pub fn shortItems(w: *og.state.world.World, hero: *og.script.object.Object, out: []ShortItem) []ShortItem {
    return og.inventory.list.shortList(w, hero, out);
}

pub fn shortRowAt(self: *Gui, x: f32, y: f32) ?usize {
    if (!self.short_open) return null;
    for (short_rows, 0..) |rc, i| {
        if (x >= 83 + rc[0] and x <= 83 + rc[2] and y >= 185 + rc[1] and y <= 185 + rc[3]) return self.short_scroll + i;
    }
    return null;
}

pub fn shortContains(self: *Gui, x: f32, y: f32) bool {
    return self.short_open and x >= 83 and x < 83 + 101 and y >= 185 and y < 185 + 227;
}

/// Quick list scrollbar (0x4ae790(12, 175, 15, 29, 16, 1)): thumb is `item_list.spr`
/// frame 1 at (163, 211 + offset).
const bar: gui_mod.Scrollbar = .{ .y = 211, .len = 175, .rows = 4 };

/// The thumb is drawn (0x4aece0 → 0x4ae980) at the bar origin (83 + 0x51, 185 + 0x1a) =
/// (164, 211), shifted by (track width 12 − frame width 15) / 2 = −1
/// (cdq/sar 0x4ae9af…0x4ae9b4): x = 163, so the frame's own edges sit on the track.
fn drawShortScroll(self: *Gui, r: *c.SDL_Renderer, n: usize) !void {
    if (n <= 4 or self.item_list.len() < 2) return;
    try self.item_list.draw(r, 1, 163, @trunc(211 + bar.thumb(self.short_scroll, n)));
}

fn shortCount(w: *og.state.world.World) usize {
    const hero = w.selectedHero() orelse return 0;
    var buf: [og.inventory.list.max_entries]ShortItem = undefined;
    return shortItems(w, hero, &buf).len;
}

/// Press on the scrollbar (0x4aea50, track (164, 210)–(176, 387)): on the thumb —
/// drag; above or below — ±16 (a page).
pub fn shortScrollPress(self: *Gui, w: *og.state.world.World, x: f32, y: f32) bool {
    if (!self.short_open or x < 164 or x > 176 or y < 210 or y > 387) return false;
    if (bar.click(&self.short_scroll, shortCount(w), y)) self.short_drag = true;
    saveShortScroll(self, w);
    return true;
}

/// Thumb follows the mouse: top = y − 14.
pub fn shortDrag(self: *Gui, w: *og.state.world.World, y: f32) void {
    bar.drag(&self.short_scroll, shortCount(w), y);
    saveShortScroll(self, w);
}

/// Scrolls by `d` rows (wheel, arrows).
pub fn shortScrollBy(self: *Gui, w: *og.state.world.World, d: i32) void {
    const n = shortCount(w);
    if (d < 0) self.short_scroll -|= 1 else self.short_scroll = @min(n -| 4, self.short_scroll + 1);
    saveShortScroll(self, w);
}

/// The scroll position is stored on the hero (+0x32c4).
fn saveShortScroll(self: *Gui, w: *og.state.world.World) void {
    if (w.selectedHero()) |h| og.inventory.list.setShortScroll(h, self.short_scroll);
}

pub fn loadShortScroll(self: *Gui, w: *og.state.world.World) void {
    self.short_scroll = if (w.selectedHero()) |h| og.inventory.list.shortScroll(h) else 0;
}

/// Quick list tooltip (0x45c6b0): name; "+N HP" for medicine, "Lv.N" for a weapon
/// with a skill.
pub fn shortTooltip(self: *Gui, w: *og.state.world.World, x: f32, y: f32, strings: ?*const og.formats.strtab.Table) ?[]const u8 {
    const k = shortRowAt(self, x, y) orelse return null;
    const hero = w.selectedHero() orelse return null;
    var buf: [og.inventory.list.max_entries]ShortItem = undefined;
    const items = shortItems(w, hero, &buf);
    if (k >= items.len) return null;
    return itemTooltip(self, hero, items[k].item, strings);
}

/// Item tooltip (0x45c6b0): name; "+N HP" for medicine, the hero's "Lv.N" for a
/// weapon (suffix in `tip_extra`). The hand button shows it too (0x4b26e8).
pub fn itemTooltip(self: *Gui, hero: *og.script.object.Object, o: *og.script.object.Object, strings: ?*const og.formats.strtab.Table) ?[]const u8 {
    const st = strings orelse return null;
    const name = st.get(og.fields.nameId(o)) orelse o.name;
    self.tip_extra = "";
    if (o.getInt("type") == og.inventory.item.type_medicine) {
        self.tip_extra = std.fmt.bufPrint(&self.tip_extra_buf, " +{d}{s}", .{ og.fields.hp(o), st.get(576) orelse "HP" }) catch "";
        self.tip_extra_col = .{ 0, 255, 255 };
    } else if (og.state.world.World.nativeOf(o).kind == .weapon) {
        // Hero skill level (0x45c712 → 0x48fdb0): missing from the list — 1; > 0 — "Lv.N".
        const lv = for (og.state.world.World.nativeOf(hero).growth.skills.items) |sk| {
            if (sk.id == og.fields.nameId(o)) break sk.level;
        } else 1;
        if (lv > 0) {
            self.tip_extra = std.fmt.bufPrint(&self.tip_extra_buf, " {s}{d}", .{ st.get(577) orelse "Lv.", lv }) catch "";
            self.tip_extra_col = .{ 255, 255, 0 };
        }
    }
    return name;
}

/// Quick list (0x4b12f0): background; per row a centred icon (frame 1) and a count
/// (ammo or more than one); crossed out with panel frame 43 if unusable.
pub fn drawShortList(self: *Gui, r: *c.SDL_Renderer, w: *og.state.world.World) !void {
    if (!self.short_open or self.item_list.len() == 0) return;
    const hero = w.selectedHero() orelse return;
    try self.item_list.draw(r, 0, 83, 185);
    var buf: [og.inventory.list.max_entries]ShortItem = undefined;
    const items = shortItems(w, hero, &buf);
    self.short_scroll = @min(self.short_scroll, items.len -| 4);
    og.inventory.list.setShortScroll(hero, self.short_scroll);
    try drawShortScroll(self, r, items.len);
    const t = &(self.win_text orelse return);
    @memset(t.pixels, 0);
    for (short_rows, 0..) |rc, i| {
        const k = self.short_scroll + i;
        if (k >= items.len) break;
        const it = items[k];
        if (self.icon(it.item.getString("spriteFile"))) |fr| if (fr.len() > 1) {
            const sz = fr.sizes.items[1];
            try fr.drawShadowed(r, 1, gfx.Frames.center(83 + rc[0], rc[2] - rc[0], sz[0]), gfx.Frames.center(185 + rc[1], rc[3] - rc[1], sz[1]));
        };
        if (!og.inventory.equipment.weaponVisible(og.fields.nameId(hero), og.fields.nameId(it.item)) and self.panel.len() > 43)
            try self.panel.draw(r, 43, 83 + rc[0], 185 + rc[1]);
        if (og.inventory.item.typeOf(it.item) == .ammo or it.count > 1) if (self.sys_font orelse self.font) |f3| {
            var nb: [12]u8 = undefined;
            const s2 = std.fmt.bufPrint(&nb, "{d}", .{it.count}) catch continue;
            gui_mod.textShadow(f3, t.*, @as(i32, @intFromFloat(83 + rc[2])) - 14, @as(i32, @intFromFloat(185 + rc[1])) + 7, s2, gui_mod.text_light);
        };
    }
    try gfx.drawImage(r, &self.win_tex, t.*);
}

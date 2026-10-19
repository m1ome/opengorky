//! Inventory screen drawing: tabs, item grid, text, tooltip. InventoryView methods (see viewer/inventory.zig).

const std = @import("std");
const inventory_give = @import("give.zig");
const gui_stats = @import("../gui/stats.zig");
const gui_short = @import("../gui/short.zig");
const inventory_mod = @import("../inventory.zig");
const InventoryView = inventory_mod.InventoryView;
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");
const gui_mod = @import("../gui.zig");
const Image = og.formats.image.Image;
const Font = og.formats.font.Font;
const World = @import("opengorky").state.world.World;
const Object = @import("opengorky").script.object.Object;
const inv = @import("opengorky").inventory;
const Rect = inventory_mod.Rect;
const torso_rect = inventory_mod.torso_rect;
const hand_rect = inventory_mod.hand_rect;
const picture_rect = inventory_mod.picture_rect;
const tab_rects = inventory_mod.tab_rects;
const portrait_l = inventory_mod.portrait_l;
const exit_rect = inventory_mod.exit_rect;
const skill_rect = inventory_mod.skill_rect;
const cells = inventory_mod.cells;
const bar_x = inventory_mod.bar_x;
const bar = inventory_mod.bar;

pub fn shadowText(self: *InventoryView, img: Image, x: i32, y: i32, t: []const u8, col: [3]u8) void {
    gui_mod.textShadow(self.font, img, x, y, t, col);
}

fn drawIconCentered(self: *InventoryView, r: *c.SDL_Renderer, o: *Object, frame: usize, rc: Rect) !void {
    const f = self.icon(o.getString("spriteFile")) orelse return;
    if (f.len() <= frame) return;
    const sz = f.sizes.items[frame];
    try f.drawShadowed(r, frame, gfx.Frames.center(rc.l, rc.r - rc.l, sz[0]), gfx.Frames.center(rc.t, rc.b - rc.t, sz[1]));
}

pub fn draw(self: *InventoryView, r: *c.SDL_Renderer, w: *World, gui: ?*gui_mod.Gui, mouse: [2]f32) !void {
    self.sync(w);
    if (self.bg.len() > 0) try self.bg.draw(r, 0, 0, 0);
    const hero = self.heroObj(w) orelse return;
    if (gui) |g| try gui_stats.drawInventoryStats(g, r, w, hero.name, &self.strings);
    var lbuf: [inv.list.max_entries]inv.list.Entry = undefined;
    const items = self.bagList(w, hero, &lbuf);
    if (self.scroll + cells > items.len) self.scroll = items.len -| cells;
    if (gui) |g| try bar.draw(r, &g.scrollbar, bar_x, self.scroll, items.len);
    // Portraits: frame 2 (in battle after acting, 3 plus inventory mark frame 3);
    // the selected one gets the inventory frame 2 border.
    const heroes = w.party();
    for (heroes.slice(), 0..) |h, i| {
        if (i >= portrait_l.len) break;
        const rc = inventory_mod.portraitRect(i);
        // Frame 3 — acted and less than 1 move left (0x42edf8…0x42ee1b); the
        // inventory mark — just acted (0x42ee38).
        const acted = if (w.battle) |*b| b.hasActed(h) else false;
        const spent = if (w.battle) |*b| (if (b.fighterOf(h)) |fi| b.fighters.items[fi].acted and b.fighters.items[fi].budget() < 1.0 else false) else false;
        if (self.portrait(h)) |p| if (p.len() > 3) try p.draw(r, if (spent) 3 else 2, rc.l, rc.t);
        if (acted and self.bg.len() > 3) try self.bg.draw(r, 3, rc.l - 1, rc.t);
        if (i == self.hero and self.bg.len() > 2) try self.bg.draw(r, 2, rc.l - 1, rc.t + 1);
    }
    if (inv.equipment.equipped(w, hero, .hand)) |o| try drawIconCentered(self, r, o, 1, hand_rect);
    if (inv.equipment.equipped(w, hero, .armor)) |o| try drawIconCentered(self, r, o, 1, torso_rect);
    const cur = if (self.current) |o| (if (World.nativeOf(o).deleted) null else o) else null;
    if (cur) |o| try drawIconCentered(self, r, o, 0, picture_rect);
    const t: usize = @backingInt(self.tab);
    if (self.bg.len() > 9) {
        try self.bg.draw(r, 4 + t, tab_rects[t].l, tab_rects[t].t);
        if (self.tab == .other) try self.bg.draw(r, 9, 14, 68);
    }
    for (0..cells) |k| {
        const i = self.scroll + k;
        if (i >= items.len) break;
        try drawIconCentered(self, r, items[i].item, 1, inventory_mod.cellRect(k));
    }
    // Pressed button only while the cursor is over it (0x42f15b).
    const over = InventoryView.hitAt(w, mouse[0], mouse[1]);
    if (self.pressed == .exit and over == .exit and self.bg.len() > 7) try self.bg.draw(r, 7, exit_rect.l, exit_rect.t);
    if (self.pressed == .skills and over == .skills and self.bg.len() > 8) try self.bg.draw(r, 8, skill_rect.l, skill_rect.t);
    try drawText(self, r, items, cur);
    // Cursor item with its shadow (0x42f2d3): frame 1 centred on the mouse (w>>1, h>>1).
    if (self.carried) |o| if (self.icon(o.getString("spriteFile"))) |f| if (f.len() > 1) {
        const sz = f.sizes.items[1];
        try f.drawShadowed(r, 1, @trunc(mouse[0]) - og.num.toF32(sz[0] >> 1), @trunc(mouse[1]) - og.num.toF32(sz[1] >> 1));
    };
    try inventory_give.drawGive(self, r, mouse);
    if (gui) |g| try drawHint(self, r, g, w, hero, mouse);
}

/// Screen text: current item info (0x42e790), cell counts, description, button labels.
fn drawText(self: *InventoryView, r: *c.SDL_Renderer, items: []inv.list.Entry, cur: ?*Object) !void {
    @memset(self.text.pixels, 0);
    const label: [3]u8 = gui_mod.text_dim;
    const white: [3]u8 = .{ 255, 255, 255 };
    const light: [3]u8 = gui_mod.text_light;
    var buf: [64]u8 = undefined;
    if (cur) |o| {
        const name = self.itemName(o);
        gui_mod.textShadow(self.sys, self.text, 320 - @divTrunc(@as(i32, @intCast(self.sys.measure(name))), 2), 350, name, white);
        var y: i32 = 365;
        if (inv.item.typeOf(o) == .ammo) {
            gui_mod.textShadow(self.sys, self.text, 210, y, self.strings.get(569) orelse "Counter", label);
            gui_mod.textShadow(self.sys, self.text, 290, y, std.fmt.bufPrint(&buf, "{d}", .{og.fields.counter(o)}) catch "", white);
        } else if (World.nativeOf(o).kind == .weapon) {
            // Damage and penetration of three armour classes (100 − protection).
            const fields = [3][]const u8{ "lightArmor", "mediumArmor", "heavyArmor" };
            for (0..4) |i| {
                gui_mod.textShadow(self.sys, self.text, 210, y, self.strings.get(570 + @as(i32, @intCast(i))) orelse "", label);
                const v = if (i == 0)
                    std.fmt.bufPrint(&buf, "{d}", .{o.getInt("max_damage")}) catch ""
                else
                    std.fmt.bufPrint(&buf, "{d} %", .{100 - o.getIntDyn(fields[i - 1])}) catch "";
                gui_mod.textShadow(self.sys, self.text, 360, y, v, white);
                y += 15;
            }
        } else if (inv.item.typeOf(o) == .medicine or inv.item.typeOf(o) == .armor) {
            // Health, armour, then the names of present protections.
            for ([2][]const u8{ "hp", "armor" }, 0..) |f, i| {
                gui_mod.textShadow(self.sys, self.text, 210, y, self.strings.get(560 + @as(i32, @intCast(i))) orelse "", label);
                gui_mod.textShadow(self.sys, self.text, 290, y, std.fmt.bufPrint(&buf, "{d}", .{o.getIntDyn(f)}) catch "", white);
                y += 15;
            }
            const pr = og.battle.immunity.pr_fields;
            for (0..7) |k| if (o.getIntDyn(pr[k]) == 1) { // 0x42ead0: only == 1
                gui_mod.textShadow(self.sys, self.text, 210, y, self.strings.get(562 + @as(i32, @intCast(k))) orelse "", label);
                y += 15;
            };
        }
        if (self.examine.get(og.fields.nameId(o))) |desc| _ = textWrappedShadow(self, self.sys, 458, 370, desc, light, 160, 470);
    }
    // Cell counts: ammo or more than one unit (0x42ed90).
    for (0..cells) |k| {
        const i = self.scroll + k;
        if (i >= items.len) break;
        const e = items[i];
        if (inv.item.typeOf(e.item) != .ammo and e.count <= 1) continue;
        const rc = inventory_mod.cellRect(k);
        gui_mod.textShadow(self.sys, self.text, @as(i32, @intFromFloat(rc.r)) - 10 - @as(i32, @intCast(self.sys.measure(std.fmt.bufPrint(&buf, "{d}", .{e.count}) catch ""))), @as(i32, @intFromFloat(rc.t)) + 7, std.fmt.bufPrint(&buf, "{d}", .{e.count}) catch "", light);
    }
    const ex = self.strings.get(556) orelse "Exit";
    const ws = self.strings.get(557) orelse "Weapons Skill";
    // Font 3 with shadow, centred on x, row top y = 460 (0x42f1eb, 0x47b640).
    gui_mod.textShadow(self.sys, self.text, 250 - @divTrunc(@as(i32, @intCast(self.sys.measure(ex))), 2), 460, ex, light);
    gui_mod.textShadow(self.sys, self.text, 565 - @divTrunc(@as(i32, @intCast(self.sys.measure(ws))), 2), 460, ws, light);
    try gfx.drawImage(r, &self.text_tex, self.text);
}

/// Cursor tooltip (0x45bef0): (mouse + (40, 20)), font 2, white; for an item —
/// name, "+N HP" in blue for medicine, "Lv.N" in yellow for a weapon (0x45c6b0).
fn drawHint(self: *InventoryView, r: *c.SDL_Renderer, g: *gui_mod.Gui, w: *World, hero: *Object, mouse: [2]f32) !void {
    if (self.give != null) return;
    var main_text: []const u8 = "";
    var extra: []const u8 = "";
    var extra_col: [3]u8 = .{ 0, 255, 255 };
    const item: ?*Object = switch (InventoryView.hitAt(w, mouse[0], mouse[1])) {
        .cell => |k| self.cellItem(w, hero, k),
        .torso => inv.equipment.equipped(w, hero, .armor) orelse blk: {
            main_text = self.strings.get(550) orelse "Torso";
            break :blk null;
        },
        .hand => inv.equipment.equipped(w, hero, .hand) orelse blk: {
            main_text = self.strings.get(551) orelse "Hand";
            break :blk null;
        },
        .picture => blk: {
            main_text = self.strings.get(552) orelse "";
            break :blk null;
        },
        .tab => |i| blk: {
            main_text = self.strings.get(553 + @as(i32, @intCast(i))) orelse "";
            break :blk null;
        },
        .portrait => |i| blk: {
            const heroes = w.party();
            const party = heroes.slice();
            if (i < party.len) main_text = self.strings.get(og.fields.nameId(party[i])) orelse party[i].name;
            break :blk null;
        },
        else => null,
    };
    if (item) |o| {
        // Item tooltip, shared with the panel and the quick list (0x45c6b0).
        main_text = gui_short.itemTooltip(g, hero, o, &self.strings) orelse self.itemName(o);
        extra = g.tip_extra;
        extra_col = g.tip_extra_col;
    }
    if (main_text.len == 0) return;
    try gui_mod.drawHint(g, r, mouse[0], mouse[1], main_text, extra, extra_col);
}

/// Same with a (10,10,10) shadow at (x+1, y+1) (0x47b4e0, shadow flag).
pub fn textWrappedShadow(self: *InventoryView, f: Font, x: i32, y0: i32, text: []const u8, color: [3]u8, max_w: u32, bottom: i32) i32 {
    _ = textWrapped(self, f, x + 1, y0 + 1, text, .{ 10, 10, 10 }, max_w, bottom + 1);
    return textWrapped(self, f, x, y0, text, color, max_w, bottom);
}

fn textWrapped(self: *InventoryView, f: Font, x: i32, y0: i32, text: []const u8, color: [3]u8, max_w: u32, bottom: i32) i32 {
    var y = y0;
    var rest = text;
    while (rest.len > 0 and y + @as(i32, @intCast(f.height)) <= bottom) {
        const cut = f.lineCut(rest, max_w);
        f.draw(self.text, x, y, rest[0..cut], color);
        rest = std.mem.trimStart(u8, rest[cut..], " ");
        y += @intCast(f.height + 1);
    }
    return y;
}

//! In-game cursor and mouse hints: mouse.spr frame by mode and hovered object, two-line labels (take, heal, give, push, fighter info), idle hero chatter.

const std = @import("std");
const panel_actions = @import("actions.zig");
const gui_stats = @import("stats.zig");
const gui_short = @import("short.zig");
const gui_panel = @import("panel.zig");
const camera_view = @import("../level/camera.zig");
const battle_view = @import("../battle/view.zig");
const control_mod = og.combat.control;
const walk_mod = og.world.walk;
const viewer_mod = @import("../app/viewer.zig");
const Viewer = viewer_mod.Viewer;
const gui_file = @import("../gui.zig");
const Cursor = gui_file.Cursor;
const LevelView = @import("../level.zig").LevelView;
const gui_mod = @import("../gui.zig");
const og = @import("opengorky");
const c = @import("sdl");

/// Cursor frame: hand in give/use modes, crosshair over a target in battle, door
/// over an exit (`isLevelSwitch` > 0, funcID ≠ 1).
pub fn cursorFrame(self: *Viewer, l: *LevelView, g: *gui_mod.Gui) usize {
    const w = l.world;
    // "Use/Heal X on …" outside battle (0x450d8f) and in battle (0x45402a): frame 6
    // (red ring with a cross) for medicine, 2 otherwise, centred on frame 2's size;
    // give mode — 3.
    g.cursor_anchor = .corner;
    // Push mode (draw 0x452bf0): always frame 5, a hand, no crosshair.
    switch (w.mouse.mode(w.battle != null, false)) {
        .push => {
            g.cursor_anchor = .push;
            return Cursor.push;
        },
        .use => {
            g.cursor_anchor = .center2;
            return if (w.mouse.use.?.getInt("type") == og.inventory.item.type_medicine) Cursor.heal else Cursor.use;
        },
        .give => return Cursor.give,
        .normal, .facing, .aim => {},
    }
    if (w.scene.cutscene or self.mouse[1] >= gui_mod.panel_hit_y or g.short_open) return Cursor.arrow;
    const bg = camera_view.bgMouse(self, self.mouse);
    if (w.battle) |*b| {
        // Crosshair (0x4527b1): frame 6 + cell range percent / 10 — the red ring
        // fills by percent (7 empty, 16 full); outside attack cells — 7. Aim mode
        // only; normal mode (0x4556b0) shows the arrow.
        if (!w.mouse.aim) return Cursor.arrow;
        const t = battle_view.tileAt(l, bg) orelse return Cursor.aim_empty;
        for (control_mod.targetList(b)) |aim| if (aim.tile[0] == t[0] and aim.tile[1] == t[1]) return Cursor.aim(aim.pct);
        return Cursor.aim_empty;
    }
    if (og.world.areas.activeAreaAt(w, bg)) |o| if (o.getInt("isLevelSwitch") > 0 and o.getInt("funcID") != 1) return Cursor.exit;
    return Cursor.arrow;
}
/// Name of the area or item under the cursor, the "Use … on …" item at the cursor,
/// world messages (Cannot use).
pub fn drawHints(self: *Viewer, r: *c.SDL_Renderer, l: *LevelView) !void {
    const w = l.world;
    const inv = self.inventory orelse return;
    if (w.out.message) |m| {
        self.message = m;
        self.message_until = c.SDL_GetTicks() + 2000;
        w.out.message = null;
    }
    // The message draws on top, on every exit path.
    defer if (self.message) |m| if (c.SDL_GetTicks() < self.message_until) viewer_mod.debugText(r, 320 - og.num.toF32(m.len) * 4, 380, m) catch {};
    var buf: [128]u8 = undefined;
    const bg = camera_view.bgMouse(self, self.mouse);
    var hint: ?[]const u8 = null;
    if (w.battle == null and !w.scene.cutscene) {
        // Object under the cursor (0x450fa0): ground item, then area, then actor;
        // in use mode a panel portrait comes first (0x4b1a20).
        if (w.mouse.use != null and self.gui != null) if (gui_panel.heroAt(w, self.mouse[0], self.mouse[1])) |h| {
            hint = inv.strings.get(og.fields.nameId(h)) orelse h.name;
        };
        if (hint != null) {} else if (og.world.areas.itemAt(w, bg)) |o| {
            hint = inv.itemName(o);
        } else if (og.world.areas.activeAreaAt(w, bg)) |o| {
            if (o.getInt("noHint") == 0) hint = inv.strings.get(og.fields.nameId(o));
        } else if (walk_mod.heroAt(w, bg)) |h| {
            // Actor under the cursor: its name (0x450fa0: item, area, actor).
            hint = inv.strings.get(og.fields.nameId(h)) orelse h.name;
        }
    } else if (w.battle) |*b| if (w.mouse.use != null) {
        // Use mode in battle (0x453cf5): the target is the portrait's hero (0x4b1a20),
        // else the fighter under the cursor (0x454eb0); "on <name>" for heroes only
        // (+0x64, 0x453df4).
        var target: ?*og.script.object.Object = null;
        if (self.gui != null) target = gui_panel.heroAt(w, self.mouse[0], self.mouse[1]);
        if (target == null and self.mouse[1] < gui_mod.panel_hit_y) {
            if (battle_view.tileAt(l, camera_view.bgMouse(self, self.mouse))) |t| {
                const who = b.grid().at(t);
                if (who != og.battle.grid.Grid.none and b.fighters.items[who].side == .hero) target = b.fighters.items[who].obj;
            }
        }
        if (target) |h| hint = inv.strings.get(og.fields.nameId(h)) orelse h.name;
    };
    // Push mode (0x452bf0): lang 506 "Push" at (mouse + (30, 0)) in (210, 210, 192)
    // and the fighter's name under the cursor (0x454eb0 → [0x6519e8], +0x58) at
    // (mouse + (35, 15)) in (177, 177, 149), both shadowed (0x47b4e0).
    if (w.battle) |*b| if (self.gui) |g| if (w.mouse.push) {
        try gui_panel.label(g, r, g.font, self.mouse[0] + 30, self.mouse[1], inv.strings.get(506) orelse "Push", gui_file.text_light, false);
        if (self.mouse[1] < gui_mod.panel_hit_y) {
            if (battle_view.tileAt(l, camera_view.bgMouse(self, self.mouse))) |t| {
                const who = b.grid().at(t);
                if (who != og.battle.grid.Grid.none) {
                    const o = b.fighters.items[who].obj;
                    try gui_panel.label(g, r, g.font, self.mouse[0] + 35, self.mouse[1] + 15, inv.strings.get(og.fields.nameId(o)) orelse o.name, gui_file.text_dim, false);
                }
            }
        }
        return;
    };
    // Give mode (draw 0x4539e0 in battle, 0x450900 outside): shadowed item icon at
    // (mouse + (25, 15)), "Give <item>" (lang 503) and "to <hero>" (lang 522);
    // recipient: the portrait (0x4b1a20), else the hero under the cursor (0x454eb0 / 0x450fa0).
    if (self.gui) |g| if (w.mouse.give) |o| {
        try drawItemIcon(self, r, inv, o);
        const line1 = std.fmt.bufPrint(&buf, "{s} {s}", .{ inv.strings.get(503) orelse "Give", inv.itemName(o) }) catch "";
        try gui_panel.label(g, r, g.font, self.mouse[0] + 20, self.mouse[1], line1, gui_file.text_light, false);
        var to: ?*og.script.object.Object = gui_panel.heroAt(w, self.mouse[0], self.mouse[1]);
        if (to == null and self.mouse[1] < gui_mod.panel_hit_y) to = panel_actions.heroUnderMouse(self, l);
        if (to) |h| {
            var buf2: [128]u8 = undefined;
            const line2 = std.fmt.bufPrint(&buf2, "{s} {s}", .{ inv.strings.get(522) orelse "to", inv.strings.get(og.fields.nameId(h)) orelse h.name }) catch "";
            try gui_panel.label(g, r, g.font, self.mouse[0] + 25, self.mouse[1] + 15, line2, gui_file.text_dim, false);
        }
        return;
    };
    if (w.mouse.use) |o| {
        // Use mode (draw 0x450ce0, in battle 0x453f80, same): item icon frame 1 at
        // (mouse + (25, 15)) with its shadow (0x41bdb0); "Heal|Use <item>" in font 2
        // at (mouse + (20, 0)) in (210, 210, 192) and "on <target>" at (mouse +
        // (25, 15)) in (177, 177, 149), both shadowed (0x450af0: lang 18 "Heal" for
        // medicine, else lang 4 "Use"; "on" is lang 523).
        try drawItemIcon(self, r, inv, o);
        const verb = if (o.getInt("type") == og.inventory.item.type_medicine) inv.strings.get(18) orelse "Heal" else inv.strings.get(4) orelse "Use";
        const line1 = std.fmt.bufPrint(&buf, "{s} {s}", .{ verb, inv.itemName(o) }) catch "";
        if (self.gui) |g| {
            try gui_panel.label(g, r, g.font, self.mouse[0] + 20, self.mouse[1], line1, gui_file.text_light, false);
            if (hint) |target| {
                var buf2: [128]u8 = undefined;
                const line2 = std.fmt.bufPrint(&buf2, "{s} {s}", .{ inv.strings.get(523) orelse "on", target }) catch "";
                try gui_panel.label(g, r, g.font, self.mouse[0] + 25, self.mouse[1] + 15, line2, gui_file.text_dim, false);
            }
        }
        hint = null;
        return;
    }
    var extra: []const u8 = "";
    var extra_col: [3]u8 = .{ 0, 255, 255 };
    if (hint == null) if (self.gui) |g| {
        hint = gui_stats.skillTooltip(g, l.world, self.mouse[0], self.mouse[1], &inv.strings);
        if (hint == null) {
            hint = gui_short.shortTooltip(g, l.world, self.mouse[0], self.mouse[1], &inv.strings);
            if (hint != null) {
                extra = g.tip_extra;
                extra_col = g.tip_extra_col;
            }
        }
    };
    if (hint == null) if (self.gui) |g| if (!g.panel_hidden and self.mouse[1] >= gui_mod.panel_y) {
        hint = gui_panel.tooltip(g, l.world, &inv.strings);
        if (hint != null) {
            extra = g.tip_extra;
            extra_col = g.tip_extra_col;
        }
    };
    // Hint (0x45bef0): font 2, white, no backing, at mouse + (40, 20).
    if (hint) |t| if (self.gui) |g| try gui_mod.drawHint(g, r, self.mouse[0], self.mouse[1], t, extra, extra_col);
}
/// Item icon at the cursor: frame 1 at (mouse + (25, 15)) with its shadow (0x450938).
fn drawItemIcon(self: *Viewer, r: *c.SDL_Renderer, inv: *@import("../inventory.zig").InventoryView, o: *og.script.object.Object) !void {
    const f = inv.icon(o.getString("spriteFile")) orelse return;
    if (f.len() <= 1) return;
    try f.drawShadowed(r, 1, @trunc(self.mouse[0]) + 25, @trunc(self.mouse[1]) + 15);
}

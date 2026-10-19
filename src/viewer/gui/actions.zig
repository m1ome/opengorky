//! Panel and quick list actions: battle and map buttons, portraits (select, double click, heal and give via portrait), hand, quick list, inventory window actions.

const inventory_give = @import("../inventory/give.zig");
const gui_short = @import("short.zig");
const gui_panel = @import("panel.zig");
const camera_view = @import("../level/camera.zig");
const battle_view = @import("../battle/view.zig");
const control_mod = og.combat.control;
const turns_mod = og.combat.turns;
const walk_mod = og.world.walk;
const viewer_mod = @import("../app/viewer.zig");
const Viewer = viewer_mod.Viewer;
const gui_mod = @import("../gui.zig");
const og = @import("opengorky");
const level_mod = @import("../level.zig");
const LevelView = level_mod.LevelView;

/// Mouse release over the panel (0x4b2440): the pressed button's action if the
/// cursor is still over it.
/// During a counterattack the panel and hero selection do nothing (0x4524d0).
pub fn counterLock(self: *Viewer) bool {
    const l = &(self.level orelse return false);
    const b = &(l.world.battle orelse return false);
    return b.phase == .counter;
}
/// Double click on a portrait (0x4b279a…0x4b27f9): stats window open ([0x6c624a])
/// — close it (0x4afcd0), else open it for the selected hero at (450, 60)
/// (0x4af780, which also plays the slide sounds). In Heal/Use and give modes the
/// portrait is a target, no window.
pub fn portraitDouble(self: *Viewer) !void {
    const g = self.gui orelse return;
    const l = &(self.level orelse return);
    const w = l.world;
    if (w.mouse.use != null or w.mouse.give != null or g.stats.modal) return;
    const name = if (g.stats.open) "battle_menuslide_out" else "battle_menuslide_in";
    if (g.stats.open) g.stats.close() else g.stats.show(450, 60, w.selected_hero, true, 0);
    w.out.sound(w.gpa, name, null);
}
pub fn panelClick(self: *Viewer, mx: f32, my: f32) !void {
    const g = self.gui orelse return;
    const l = &(self.level orelse return);
    const w = l.world;
    if (counterLock(self)) return;
    const btn = gui_panel.buttonAt(mx, my) orelse return;
    defer g.pressed_btn = null;
    if (g.pressed_btn != btn or !gui_panel.enabled(w, btn)) return;
    if (btn == .hand) return; // acts on press (handButton)
    w.out.sound(w.gpa, "selecthero", null);
    switch (btn) {
        .inventory => if (self.inventory) |inv| inv.show(w),
        // Quick list (button 3), also in give mode (button 1, not Medusa).
        .short_list, .give => {
            const give = btn == .give;
            if (give) if (w.selectedHero()) |h| if (og.fields.isMedusa(h)) return;
            if (g.short_open and g.short_give == give) {
                g.short_open = false;
            } else {
                g.short_open = true;
                g.short_give = give;
                // Skills and stats windows vanish at once (0x4b2a6b).
                g.stats = .{ .tick = g.stats.tick };
                gui_short.loadShortScroll(g, w);
                g.skills.close();
            }
        },
        .defend => if (w.battle) |*b| control_mod.defend(b, w),
        .push => w.mouse.push = !w.mouse.push,
        .end_turn => if (w.battle) |*b| try turns_mod.endTurn(b, w),
        // Stats (button 14): the window slides to (450, 50); again — close.
        .stats => {
            const name = if (g.stats.open) "battle_menuslide_out" else "battle_menuslide_in";
            if (g.stats.open) g.stats.close() else g.stats.show(450, 60, w.selected_hero, true, 0);
            w.out.sound(w.gpa, name, null);
        },
        // Skills (button 13): window at (5, 40) for the selected hero; again — close.
        .skills => {
            const name = if (g.skills.open) "battle_menuslide_out" else "battle_menuslide_in";
            if (g.skills.open) g.skills.close() else g.skills.show(5, 40, w.selected_hero);
            w.out.sound(w.gpa, name, null);
        },
        .hero0, .hero1, .hero2, .hero3, .hero4 => if (gui_panel.heroAt(w, mx, my)) |hero| {
            // Heal/Use mode: the target is this portrait's hero (0x4b1a20 → 0x450c6c).
            if (w.mouse.use) |item| if (w.selectedHero()) |from| {
                if (w.battle) |*b| {
                    if (b.fighterOf(hero)) |fi| {
                        if (try control_mod.useItemOn(b, w, item, b.fighters.items[fi].tile) == .used) w.mouse.use = null;
                    }
                } else try og.inventory.medicine.healWith(w, from, hero, item);
                return;
            };
            // An item to give is picked: the portrait's hero receives it (0x4b1a20).
            if (w.mouse.give != null) {
                try giveTo(self, hero);
                return;
            }
            if (!w.playerCanSelect(hero)) return;
            og.game.selectHero(w, hero.name);
            // Skills and stats windows follow the new hero (0x4b2c71, 0x4b2c30).
            if (g.skills.open) g.skills.show(5, 40, hero.name);
            if (g.stats.open and !g.stats.upgrade) g.stats.show(450, 60, hero.name, true, 0);
            l.follow = true;
        },
        else => {},
    }
}
/// Give mode (0x4536e0 in battle, 0x450770 outside): the recipient is the portrait's
/// hero or the hero under the cursor. Self and Medusa (nameID 119): nothing, the
/// mode stays; in battle beyond the adjacent cell (0x481ec0 > 1.0) "Out of range"
/// over the giver, the mode stays; more than one unit (0x47d810) — the count window
/// (0x4b2fb0), mode off; otherwise the item goes to the recipient's backpack
/// (0x42b2d0, place 1, 0x4adad0), mode off. No move or points spent.
pub fn giveTo(self: *Viewer, to: *og.script.object.Object) !void {
    if (self.gui == null) return;
    const l = &(self.level orelse return);
    const w = l.world;
    const item = w.mouse.give orelse return;
    const from = w.selectedHero() orelse return;
    // Out of reach in battle: the refusal message (0x4536e0); other refusals are silent.
    if (to != from and !og.fields.isMedusa(to)) if (w.battle) |*b| if (!b.adjacent(from, to)) {
        try control_mod.outOfRange(b, w, from);
        return;
    };
    if (!og.inventory.give.canGive(w, from, to)) return;
    w.mouse.give = null;
    if (self.inventory) |inv| if (inventory_give.openGive(inv, w, from, to, item)) return;
    og.inventory.give.handOver(w, from, to, item);
    w.out.sound(w.gpa, "invgive", null);
}
/// Hero under the cursor on the field: in battle the hero fighter in the cell
/// (0x454eb0), outside battle a party actor (0x450fa0).
pub fn heroUnderMouse(self: *Viewer, l: *LevelView) ?*og.script.object.Object {
    const w = l.world;
    const bg = camera_view.bgMouse(self, self.mouse);
    if (w.battle) |*b| {
        const t = battle_view.tileAt(l, bg) orelse return null;
        const who = b.grid().at(t);
        if (who == og.battle.grid.Grid.none or b.fighters.items[who].side != .hero) return null;
        return b.fighters.items[who].obj;
    }
    return walk_mod.heroAt(w, bg);
}
/// Inventory release outcome: closed — close the skills window and refresh the
/// battle selection; "Weapons Skill" (0x42e1c3) — skills window at (16, 75).
pub fn inventoryAction(self: *Viewer, a: @import("../inventory.zig").Action) void {
    const g = self.gui orelse return;
    const l = &(self.level orelse return);
    switch (a) {
        .none => {},
        .close => {
            g.skills.close();
            if (l.world.battle) |*b| control_mod.refreshSelection(b, l.world);
        },
        .skills => if (g.skills.open) g.skills.close() else if (self.inventory.?.heroObj(l.world)) |h| g.skills.show(16, 75, h.name),
    }
}
/// Hand button (panel button 2), on press: "selecthero", "Itemchoose" if the hand
/// holds something or in battle; in give mode give the hand item (0x45b380);
/// outside battle "Use X on …" (0x45b390); in battle a non-weapon is used
/// (0x45b3d0), a weapon enters aim mode (0x45b3e0).
pub fn handButton(self: *Viewer) !void {
    const g = self.gui orelse return;
    const l = &(self.level orelse return);
    const w = l.world;
    const hero = w.selectedHero() orelse return;
    w.out.sound(w.gpa, "selecthero", null);
    const item = og.inventory.equipment.equipped(w, hero, .hand);
    if (item != null or w.battle != null) w.out.sound(w.gpa, "Itemchoose", null);
    // Empty hand in battle: aim with the fist (0x4b299f…0x4b29ba), except hero 0x77.
    const it = item orelse {
        if (w.battle) |*b| if (og.fields.nameId(hero) != 0x77) {
            w.mouse.aim = true;
            control_mod.refreshSelection(b, w);
        };
        return;
    };
    if (g.short_open and g.short_give) {
        g.short_open = false;
        w.mouse.give = it;
        return;
    }
    g.short_open = false;
    if (!og.inventory.equipment.weaponVisible(og.fields.nameId(hero), og.fields.nameId(it))) return;
    if (w.battle) |*b| {
        // A weapon enters aim mode at once (0x4b295d → 0x45b3e0 → 0x4524d0); without
        // it a click on a barrel or box does nothing (normal battle mode 0x455200
        // doesn't attack); anything else is used (0x45b3d0).
        control_mod.chooseItem(b, w, it);
    } else w.mouse.use = it;
}
/// Quick list row (0x4b0f90): "Itemchoose"; in give mode the item waits for the
/// recipient portrait; otherwise a weapon goes to the hand, anything else is "Use … on …".
pub fn shortListClick(self: *Viewer, k: usize) !void {
    const g = self.gui orelse return;
    const l = &(self.level orelse return);
    const w = l.world;
    const hero = w.selectedHero() orelse return;
    var buf: [og.inventory.list.max_entries]gui_mod.Gui.ShortItem = undefined;
    const items = gui_short.shortItems(w, hero, &buf);
    if (k >= items.len) return;
    const item = items[k].item;
    w.out.sound(w.gpa, "Itemchoose", null);
    g.short_open = false;
    if (g.short_give) {
        w.mouse.give = item;
        return;
    }
    // Any item goes to the hand (quick list 0x4b0f90); in battle a weapon attacks, anything else
    // is used; outside battle the "Use/Heal …" cursor for any item.
    og.inventory.equipment.toHand(w, hero, item);
    const usable = og.inventory.equipment.weaponVisible(og.fields.nameId(hero), og.fields.nameId(item));
    if (w.battle) |*b| {
        // Weapon: aim mode (0x4b1146 → 0x45b3e0); anything else is used (0x45b3d0).
        if (usable) control_mod.chooseItem(b, w, item) else control_mod.refreshSelection(b, w);
    } else if (usable) w.mouse.use = item;
}

/// Field click in the level view: battle tile action, game click, or the debug action menu.
pub fn clickWalk(self: *LevelView, bg: [2]f32) !void {
    if (self.world.battle) |*b| {
        const t = battle_view.tileAt(self, bg) orelse return;
        // "Use … on …" mode (0x453cf5): a click targets the hero in the cell; the
        // mode closes only after use (0x454230), a miss keeps it.
        if (self.world.mouse.use) |item| {
            if (try control_mod.useItemOn(b, self.world, item, t) == .used) self.world.mouse.use = null;
            return;
        }
        return control_mod.clickTileMode(b, self.world, t, self.world.mouse.aim);
    }
    // Game (examine menus on): clicks as in the exe.
    if (self.world.examine_menus) {
        if (try og.world.actions.clickPlay(self.world, bg, false)) {
            self.follow = true;
            self.clickMarker(bg);
        }
        return;
    }
    // Action menu open: pick an item (a miss closes it).
    if (self.action_menu) |m| {
        self.action_menu = null;
        if (m.hit(bg)) |k| {
            if (try og.world.actions.clickAction(self.world, m.at, m.items[k].action)) self.follow = true;
        }
        return;
    }
    // An area with several actions (lift button: up/down) opens a menu.
    var items: [og.state.world.World.max_actions]level_mod.ActionMenu.Item = undefined;
    const n = og.world.actions.actionsAt(self.world, bg, &items);
    if (n > 1 and !self.world.scene.cutscene and !self.world.examine_menus) {
        self.action_menu = .{ .at = bg, .items = items, .len = n };
        return;
    }
    if (try og.world.actions.click(self.world, bg)) self.follow = true;
}

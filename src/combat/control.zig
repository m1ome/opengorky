//! Player actions: hero selection, facing, defend, tile clicks, item use, walking, turning.

const std = @import("std");
const weapon_class = @import("../battle.zig").weapon_class;
const fields = @import("../fields.zig");
const weapons = @import("weapons.zig");
const states = @import("states.zig");
const strike = @import("strike.zig");
const battle = @import("../battle.zig").battle;
const anim = @import("anim.zig");
const Battle = battle.Battle;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const Object = @import("../script.zig").object.Object;
const grid = @import("../battle.zig").grid;
const ai = @import("ai.zig");
const inventory = @import("../inventory.zig");
const Tile = @import("../battle.zig").grid.Tile;
const Fighter = @import("../battle.zig").fighter.Fighter;
const Class = @import("../battle.zig").fighter.Class;
const face = anim.face;

/// Facing arrow tiles (0x453380): side neighbours of the hero, inside the grid and
/// walkable (`.cm` bit 0); directions 0 y−1, 1 x+1, 2 y+1, 3 x−1.
pub fn facingCells(self: *Battle, out: *[4]?Tile) void {
    out.* = .{ null, null, null, null };
    const f = self.current() orelse return;
    const d = [4]Tile{ .{ 0, -1 }, .{ 1, 0 }, .{ 0, 1 }, .{ -1, 0 } };
    for (d, 0..) |dd, k| {
        const t: Tile = .{ f.tile[0] + dd[0], f.tile[1] + dd[1] };
        if (!self.grid().inside(t)) continue;
        if (self.blocked[grid.tileIndex(self.width, t)]) continue;
        out[k] = t;
    }
}

/// Click in facing mode (0x452ec0): on an arrow tile the hero turns to it
/// (vtable +0xd4 = 0x48f110) and the mode closes; selection sound (0x455490).
/// Doesn't spend the hero's turn.
fn chooseFacing(self: *Battle, w: *World, t: Tile) void {
    var cells: [4]?Tile = undefined;
    facingCells(self, &cells);
    const f = self.current() orelse return;
    for (cells) |ct| if (ct) |c| if (c[0] == t[0] and c[1] == t[1]) {
        face(w, f.*, t);
        self.facing_mode = false;
        refreshSelection(self, w);
        // 0x452fde: after turning, 0x455490(hero, 1), as on selection.
        if (self.selected) |i| selectFx(self, w, i, true);
        return;
    };
}

/// Leave facing selection (right button, 0x453680).
pub fn cancelFacing(self: *Battle) void {
    self.facing_mode = false;
}

/// Defend with the selected hero (0x48f7e0): damage ×0.5 until its next turn; the
/// turn ends.
pub fn defend(self: *Battle, w: *World) void {
    if (self.phase != .player or self.pending != .none) return;
    const f = self.current() orelse return;
    if (f.acted or !f.alive() or f.disabled()) return;
    f.defending = true;
    f.acted = true;
    f.spendRage(); // 0x48f790
    self.facing_mode = false;
    f.used = @floatFromInt(fields.walkRange(f.obj));
    const a = world_mod.actorOf(f.*.obj);
    a.state = 4;
    a.forced_idle = null;
    a.pickIdle(w.crt());
    refreshSelection(self, w);
}

/// Hero selection (portrait click or click on the hero on the field).
pub fn select(self: *Battle, w: *World, o: *Object) void {
    // Selection is locked during a counter-attack (aim mode 0x4524d0).
    if (self.phase == .counter) return;
    const i = self.fighterOf(o) orelse return;
    const f = self.fighters.items[i];
    if (!f.controllable() or !f.alive()) return;
    if (self.selected != i) self.facing_mode = false;
    self.selected = i;
    w.selected_hero = o.name;
    refreshSelection(self, w);
    selectFx(self, w, i, true);
}

/// Hero selection in battle (0x45acb0 → 0x455490(hero, 1)): camera pans to it
/// (0x4c9100), "selecthero" sound (0x45551c), "fightlook" or "g_fightlook" with a
/// two-handed weapon (+0x350 of the weapon, 0x455569) unless defending (+0x248f0),
/// one-shot (0x4230c0(name, 0, 1, 0)); it holds neither the turn nor the queue.
/// `sound` = false: player turn start (0x454e40 → 0x455490(hero, 0)), no sound;
/// the camera pan to the selected hero is done there by 0x45b2c3 → 0x4c9100.
pub fn selectFx(self: *Battle, w: *World, i: u16, sound: bool) void {
    const f = self.fighters.items[i];
    w.out.pan_to = f.obj;
    if (sound) w.out.sound(w.gpa, "selecthero", null);
    if (f.defending) return;
    const hand = inventory.equipment.equipped(w, f.obj, .hand);
    const two = if (hand) |h| h.getInt("two_handed") == 1 else false;
    const a = world_mod.actorOf(f.obj);
    if (a.path_index < a.path.items.len) return; // walking: don't break the step
    a.play(if (two) "g_fightlook" else "fightlook", false, true);
    a.detached = true;
}

/// Item chosen in battle (hand button 0x45b3d0/0x45b3e0, quick list 0x4b1146): a
/// weapon enters aiming, anything else "Use … on …".
pub fn chooseItem(self: *Battle, w: *World, item: *Object) void {
    if (World.nativeOf(item).kind != .weapon) w.mouse.use = item else w.mouse.aim = true;
    refreshSelection(self, w);
}

/// Recompute reachable tiles and targets of the selected fighter.
pub fn refreshSelection(self: *Battle, w: *World) void {
    @memset(self.reach_left, -1);
    self.target_len = 0;
    if (self.phase != .player and self.phase != .counter) return;
    const f = self.current() orelse return;
    if (!f.alive()) return;
    if (f.disabled()) return;
    // Walking by the remaining budget, also after a strike (0x2460c isn't reset by it).
    if (self.phase == .player) {
        grid.reach(self.grid(), self.reach_left, f.tile, f.size, self.selected.?, f.budget());
        // One strike per turn (+0x24610).
        if (f.acted) return;
    }
    // For a hero, the weapon in hand (it may have changed in the inventory).
    if (f.side == .hero or f.weapon == null or !weapons.hasAmmo(w, f.*, f.weapon.?)) f.weapon = weapons.defaultWeapon(w, f.*);
    const wpn = f.weapon orelse return;
    const pat = weapon_class.pattern(wpn) orelse return;
    self.target_len = grid.targets(self.grid(), pat, f.tile, self.selected.?, true, false, &self.target_buf).len;
}

pub fn targetList(self: *Battle) []const grid.Target {
    return self.target_buf[0..self.target_len];
}

fn reachable(self: *Battle, t: Tile) bool {
    const g = self.grid();
    return g.inside(t) and self.reach_left[grid.tileIndex(self.width, t)] >= 0;
}

/// Strike attempt with the weapon in hand (0x47c2a6): if it can't fire (+0xcc), a
/// popup over the hero and battle_noammo sound, no strike. Recharging (+0xd0)
/// shows "Recharging" (string 525, 0x47c321), otherwise "No ammo" (513,
/// 0x47c3b1); both one popup: scale 0.6 (0x47c3fa), same colour and sound
/// (0x47c418), in the shared popup queue over the fighter.
fn tryAttack(self: *Battle, w: *World, me: u16, wpn: *Object, aim: grid.Target) !void {
    const f = &self.fighters.items[me];
    const refusal: ?[]const u8 = if (World.nativeOf(wpn).fight.recharge > 0)
        w.stringOr(525, "Recharging")
    else if (!weapons.hasAmmo(w, f.*, wpn)) w.stringOr(513, "No ammo") else null;
    if (refusal) |text| {
        try battle.popup(self, f.*, text, .range);
        w.out.sound(w.gpa, "battle_noammo", null);
        return;
    }
    try strike.startAttack(self, w, me, wpn, aim);
}

/// Aim tile on fighter `who` (up to 4 for 2×2 fighters) / exactly tile `t`.
fn aimOn(self: *Battle, who: u16) ?grid.Target {
    for (targetList(self)) |aim| if (self.grid().at(aim.tile) == who) return aim;
    return null;
}
fn aimAt(self: *Battle, t: Tile) ?grid.Target {
    for (targetList(self)) |aim| if (aim.tile[0] == t[0] and aim.tile[1] == t[1]) return aim;
    return null;
}

/// Tile click; `aiming` is aim mode (right button, 0x4524d0): a strike on any tile
/// in the attack area, empty ones included (0x452660 → 0x47c120 needs no fighter
/// on the tile).
pub fn clickTileMode(self: *Battle, w: *World, t: Tile, aiming: bool) !void {
    if (self.phase != .player and self.phase != .counter) return;
    if (self.pending != .none) return;
    const g = self.grid();
    const who = g.at(t);
    // Facing selection (0x452ec0): only a click on a neighbouring arrow tile.
    if (self.facing_mode) {
        chooseFacing(self, w, t);
        return;
    }
    // Click on the selected hero itself before a facing was chosen (0x45523a).
    if (self.phase == .player and who != grid.Grid.none and self.selected == who and self.fighters.items[who].alive() and !self.fighters.items[who].disabled()) {
        self.facing_mode = true;
        return;
    }
    if (self.phase == .counter) {
        // Strike by the selected hero only.
        const me = self.selected orelse return;
        const aim = (if (who != grid.Grid.none) aimOn(self, who) else null) orelse
            (if (aiming) aimAt(self, t) else null) orelse return;
        try tryAttack(self, w, me, self.fighters.items[me].weapon.?, aim);
        return;
    }
    if (who != grid.Grid.none and self.fighters.items[who].side == .hero) {
        select(self, w, self.fighters.items[who].obj);
        return;
    }
    const me = self.selected orelse return;
    const f = &self.fighters.items[me];
    if (!f.alive() or f.disabled()) return;
    // Already struck: only walking with the remaining budget.
    if (f.acted) {
        if (who == grid.Grid.none and reachable(self, t) and !(t[0] == f.tile[0] and t[1] == f.tile[1]))
            try startWalk(self, w, me, t);
        return;
    }
    // Item box (`.obs_i`, funcID: Open/Explore/Close) next to the hero: its action,
    // as for items outside battle (0x45b026).
    if (who != grid.Grid.none and boxAction(self, who)) {
        const ob = self.fighters.items[who];
        anim.faceNow(w, f.*, ob.tile);
        try inventory.box.itemOperation(w, ob.obj, f.obj);
        // Open and not empty: the item window opens by itself after the lid animation,
        // as outside battle (examineChoose).
        if (w.act.exploring == null and ob.obj.getInt("funcID") == 7 and ob.obj.getInt("cnt_itm") > 0)
            w.act.pending_explore = .{ .box = ob.obj, .hero = f.obj, .ticks = 8 };
        return;
    }
    // Aim mode: any tile of the attack area means strike, decoy throw or bomb.
    if (aiming) {
        if (aimAt(self, t)) |aim| try tryAttack(self, w, me, f.weapon.?, aim);
        return;
    }
    // Normal mode (0x455200): clicking an enemy does nothing (0x455650 is an empty
    // `ret 4`); a hero strikes only from aim mode (right button, 0x4563e0 → 0x4524d0
    // → 0x452660 → 0x47c120); clicking an empty tile walks (0x4555b0).
    if (who == grid.Grid.none and reachable(self, t) and !(t[0] == f.tile[0] and t[1] == f.tile[1])) {
        try startWalk(self, w, me, t);
    }
}

/// "Use … on …" in battle (0x453cc0, 0x47ba50): the selected hero's medicine (type
/// 20) on a hero at most 1.0 away (else "Out of range", string.tab 514): 0x48ff50
/// on the target (`inventory.medicine.medicine` and fighter states), the item is spent,
/// the giver's action ends (0x48f790). The "Use … on …" mode (0x453cf5) closes
/// (0x454230) only after use: a miss or "Out of range" keeps it.
const UseResult = enum { none, out_of_range, used };

pub fn useItemOn(self: *Battle, w: *World, item: *Object, t: Tile) !UseResult {
    if (self.phase != .player or self.pending != .none) return .none;
    const me = self.selected orelse return .none;
    const f = &self.fighters.items[me];
    if (f.acted or !f.alive() or f.disabled()) return .none;
    const who = self.grid().at(t);
    if (who == grid.Grid.none) return .none;
    const target = &self.fighters.items[who];
    if (target.side != .hero) return .none;
    if (!self.adjacent(f.obj, target.obj)) {
        try battle.popup(self, f.*, w.stringOr(514, "Out of range"), .range);
        return .out_of_range;
    }
    if (inventory.item.typeOf(item) != .medicine) return .none;
    // 0x48ff50 on the target, then the item is destroyed (+0x60), even with no effect.
    if (try inventory.medicine.medicine(w, f.obj, target.obj, item)) |h| {
        switch (h.kind) {
            .heal => {},
            .rage => target.berserk = 2, // 0x48ffcc
            .calm => target.berserk = 0, // 0x49003c
            .ungas => target.gassed = 0, // 0x490048
            .wake => states.wake(w, target), // 0x49006d
        }
        var buf: [24]u8 = undefined;
        if (h.hp > 0) try battle.popup(self, target.*, inventory.medicine.healText(&buf, h), .heal);
        battle.note(self, "turn {d}: {s} gives {s} {s}: {s} +{d}+{d}", .{ self.turn, f.obj.name, target.obj.name, item.name, @tagName(h.kind), h.hp, h.bonus });
    }
    inventory.item.consume(item);
    const a = world_mod.actorOf(f.*.obj);
    a.play(a.resolve("use_medicine"), false, true);
    // 0x47bcd0 → 0x48f790: only "acted"; the walk budget stays.
    f.acted = true;
    f.spendRage(); // 0x48f790
    refreshSelection(self, w);
    return .used;
}

/// Next weapon of the selected hero.
pub fn cycleWeapon(self: *Battle, w: *World) void {
    if (self.phase == .counter) return;
    const f = self.current() orelse return;
    var list: [16]*Object = undefined;
    const ws = weapons.weaponsOf(w, f.*, &list);
    if (ws.len == 0) return;
    var next: usize = 0;
    for (ws, 0..) |o, i| if (o == f.weapon) {
        next = (i + 1) % ws.len;
    };
    f.weapon = ws[next];
    inventory.equipment.equip(w, f.obj, ws[next]);
    refreshSelection(self, w);
}

// ---------------------------------------------------------------- actions

fn startWalk(self: *Battle, w: *World, who: u16, to: Tile) !void {
    const f = &self.fighters.items[who];
    // Path is the exe's depth-first search (0x48f610 → 0x48f400 → 0x494720); walked
    // is the budget minus what remains on the chosen path.
    var buf: [100]Tile = undefined;
    const r = grid.walkPath(self.grid(), f.tile, to, f.budget(), &buf) orelse return;
    if (r.path.len < 2) return;
    f.used += f.budget() - r.left;
    try startWalkPath(self, w, who, r.path);
}

/// Walk a ready tile path (the first tile is the current one).
pub fn startWalkPath(self: *Battle, w: *World, who: u16, path: []const Tile) !void {
    const f = &self.fighters.items[who];
    if (path.len < 2) return;
    const g = self.grid();
    g.remove(f.tile, f.size);
    f.tile = path[path.len - 1];
    g.place(f.tile, f.size, who);
    const a = world_mod.actorOf(f.*.obj);
    a.clearPath();
    const cm = w.combat_map.?;
    for (path[1..]) |t| {
        const p = cm.tileCenter(t, f.size);
        try a.path.append(w.gpa, .{ p[0], p[1] });
    }
    a.move_speed = a.speedOf("walk") * w.speedScale();
    a.on_track = false;
    a.one_shot = false;
    // Each tile: turn in place, then step (0x48f4bc…0x48f592: 0x425150 and command
    // 0x11); the walk animation starts after the first turn.
    // A turn queued earlier (0x12 before the path) the exe would finish before
    // walking; the turn to the first tile overrides it.
    a.turn_to = null;
    const here = fields.pos(f.obj);
    a.battle_walk = .{ .origin = .{ here[0], here[1] }, .anim = a.resolve("walk") };
    self.pending = .{ .walk = who };
}

/// End of an enemy's turn. Puppet (0x4e17b0) and Messiah (own command 2, 0x4dfdd4)
/// stand properly (+0xd0(0), smoothly); Messiah does "atakB" if both hands are
/// blocked by boxes. Others turn at the end of their walk (`faceAfterWalk`), not
/// after a strike.
pub fn afterMove(self: *Battle, w: *World, f: *Fighter) void {
    const ct = Class.of(f.obj);
    if ((ct == .puppet or ct == .messiah) and f.side == .enemy and f.obj.getInt("attackLock") == 0 and !f.disabled())
        if (self.fighterOf(f.obj)) |i| faceDefault(self, w, i, true);
    if (ct == .messiah and ai.obstacleAt(self, .{ 10, 17 }) and ai.obstacleAt(self, .{ 10, 19 })) {
        const a = world_mod.actorOf(f.*.obj);
        a.play("atakB", false, true);
    }
}

/// End of a battle walk, command 2 in the queue (0x48f5b0, 0x499c09 → 0x423ce5):
/// a non-hero (+0xd8) acting this enemy turn (+0x24908 = 1) that can strike
/// (0x48f990: no attackLock, not frozen, not asleep) does +0xd0(0), a smooth turn
/// to the nearest opponent. There is no such command after a strike or a hit
/// reaction: the enemy keeps facing where it struck.
pub fn faceAfterWalk(self: *Battle, w: *World, who: u16) void {
    const f = self.fighters.items[who];
    if (f.side != .enemy or self.phase != .enemy) return;
    if (f.obj.getInt("attackLock") != 0 or f.disabled()) return;
    faceDefault(self, w, who, true);
}

/// Fighter +0xd0, "stand properly". Puppet (0x4e1b80) angle −1.57, Messiah
/// (0x4df8d0) 3.14. Others (0x48ef10) face the nearest (x, y, z) fighter of the
/// other side (hero to non-hero, enemy to hero; obstacles, +0x2c 4/5, don't
/// count), atan2 from the grid axis rounded to π/2 (remainder > π/4 rounds up).
/// Obstacles and Messiah (nameID 139) don't turn. With argument 1 (battle start,
/// 0x4b4a51) at once, with 0 smoothly via command 0x12 at rotSpeed (0x48f0f3).
pub fn faceDefault(self: *Battle, w: *World, i: usize, smooth: bool) void {
    const f = self.fighters.items[i];
    const set = struct {
        fn angle(fi: Fighter, v: f32, sm: bool) void {
            if (sm) world_mod.actorOf(fi.obj).turnTo(fi.obj, v) else fields.setAngle(fi.obj, v);
        }
    }.angle;
    switch (Class.of(f.obj)) {
        .puppet => return set(f, -1.57, smooth),
        .messiah => return set(f, 3.14, smooth),
        else => {},
    }
    if (f.side == .neutral or fields.nameId(f.obj) == 139) return;
    const cm = w.combat_map orelse return;
    const me = fields.pos(f.obj);
    var best: f32 = std.math.floatMax(f32);
    var near: ?[3]f32 = null;
    for (self.fighters.items) |o| {
        if (o.side == .neutral or o.side == f.side or o.appear_to != null) continue;
        const p = fields.pos(o.obj);
        const d = (p[0] - me[0]) * (p[0] - me[0]) + (p[1] - me[1]) * (p[1] - me[1]) + (p[2] - me[2]) * (p[2] - me[2]);
        if (d < best) {
            best = d;
            near = p;
        }
    }
    const p = near orelse return;
    set(f, anim.snapAngle(std.math.atan2(@as(f64, p[1]) - me[1], @as(f64, p[0]) - me[0]), cm.rotation), smooth);
}

/// "Out of range" (lang 514) over hero `o`: an item can't be handed over beyond
/// a neighbouring tile ("give" mode, 0x45389c → 0x4c8830, scale 0.6).
pub fn outOfRange(self: *Battle, w: *World, o: *Object) !void {
    const i = self.fighterOf(o) orelse return;
    try battle.popup(self, self.fighters.items[i], w.stringOr(514, "Out of range"), .range);
}

/// Box with an action (`.obs_i`, funcID > 0) next to the selected hero who hasn't
/// struck yet: clicking it runs the box action, not a strike.
fn boxAction(self: *Battle, who: u16) bool {
    if (self.phase != .player) return false;
    const me = self.selected orelse return false;
    const f = self.fighters.items[me];
    const ob = self.fighters.items[who];
    if (f.acted or ob.side != .neutral or ob.obj.getInt("funcID") <= 0) return false;
    return @abs(ob.tile[0] - f.tile[0]) <= 1 and @abs(ob.tile[1] - f.tile[1]) <= 1;
}

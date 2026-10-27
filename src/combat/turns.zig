//! Turn phases: side turn start and end, fire/gas damage, counter-attack, end of turn,
//! victory/defeat check.

const std = @import("std");
const fields = @import("../fields.zig");
const weapons = @import("weapons.zig");
const control = @import("control.zig");
const bombs = @import("bombs.zig");
const devices = @import("devices.zig");
const states = @import("states.zig");
const strike = @import("strike.zig");
const scenes = @import("../scene.zig").scenes;
const battle = @import("../battle.zig").battle;
const anim = @import("anim.zig");
const popup_mod = @import("../popup.zig");
const Battle = battle.Battle;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const rules = @import("../battle.zig").rules;
const grid = @import("../battle.zig").grid;
const Fighter = @import("../battle.zig").fighter.Fighter;
const Side = @import("../battle.zig").fighter.Side;
const roster = @import("roster.zig");

pub fn enemyTurnOver(self: *Battle, w: *World) !void {
    _ = self;
    const l = w.level orelse return;
    _ = try w.rt.callIfExists(l, "CombatEnemiesAppear", &.{});
    // Mid-battle dialogs are hard-coded in the exe: levelMode 7 after the first enemy
    // turn (McFadden's death), 10 after the second (helicopter in the museum).
    const mode = l.getInt("levelMode");
    const turn_no = l.getInt("turnNo");
    const dlg: ?[2][]const u8 = if (mode == 7 and turn_no == 1)
        .{ "04__city_mfd", "04__city_mfd.dlg" }
    else if (mode == 10 and turn_no == 2)
        .{ "03__museum_chopper_2", "03__museum_chopper2.dlg" }
    else
        null;
    if (dlg) |d| try scenes.startDialog(w, d[0], d[1]);
}

/// Popups over fighters (TextEffect 0x4c8830) are world objects ([0x63bcb8],
/// 0x431c10): they tick even while the battle mode is stopped, e.g. under the level-up window.
pub fn tickPopups(self: *Battle) void {
    popup_mod.tickAll(&self.popups);
}

/// Victory when all enemies are dead; defeat when any hero dies (all of them with `lenient_loss`).
pub fn checkEnd(self: *Battle) bool {
    var heroes: usize = 0;
    var dead_heroes: usize = 0;
    var enemies: usize = 0;
    for (self.fighters.items) |f| switch (f.side) {
        .hero => if (f.alive()) {
            if (f.controllable()) heroes += 1;
        } else {
            dead_heroes += 1;
        },
        .enemy => if (f.alive()) {
            enemies += 1;
        },
        .neutral => {},
    };
    // Any hero's death ends the game (0x490620 → GUI_GameOver); in the playthrough
    // (`lenient_loss`) only the whole party's. Defeat is checked before victory (bomb).
    const lost = if (self.lenient_loss) heroes == 0 else dead_heroes > 0 or heroes == 0;
    if (lost) self.phase = .lost else if (enemies == 0) self.phase = .won;
    return self.phase == .won or self.phase == .lost;
}

/// Before the player turn, heroes' states one by one (0x498650 step 5), then the turn.
pub fn beginPlayerTurn(self: *Battle, w: *World) !void {
    _ = w;
    self.seq = .{ .side = .hero };
}

fn startPlayerPhase(self: *Battle, w: *World) !void {
    self.phase = .player;
    self.cam_pair = null;
    self.enemy_period = false;
    for (self.fighters.items) |*f| {
        resetTurn(f);
    }
    if (w.level) |l| l.setInt("turnNo", self.turn);
    if (self.selected == null or !self.fighters.items[self.selected.?].alive() or !self.fighters.items[self.selected.?].controllable()) {
        // The hero selected in the UI first, else the first one alive.
        self.selected = null;
        for (self.fighters.items, 0..) |f, i| if (f.controllable() and f.alive()) {
            if (self.selected == null or std.ascii.eqlIgnoreCase(f.obj.name, w.selected_hero)) self.selected = @intCast(i);
        };
    }
    if (self.selected) |i| w.selected_hero = self.fighters.items[i].obj.name;
    control.refreshSelection(self, w);
    // Player turn start (0x498550 → 0x45b1b0): "fightlook" of the selected hero
    // (0x45b2be → 0x454e40) and the camera flies to it (0x45b2c3 → 0x4c9100),
    // rather than staying on the last enemy.
    if (self.selected) |i| control.selectFx(self, w, i, false);
    if (self.skip_turn) {
        self.skip_turn = false;
        try endTurn(self, w);
    }
}

/// Turn start sequence step: pause, bombs (90 ticks after a blast), fighters'
/// states one by one (60 ticks after a wounded one, then until idle).
pub fn stepSeq(self: *Battle, w: *World) !void {
    const s = &self.seq.?;
    if (s.delay > 0) {
        s.delay -= 1;
        return;
    }
    // Bombs one at a time (0x498650): after a blast the camera stays on its tile for
    // 90 ticks, then the rest.
    if (s.bombs) {
        if (try bombs.tickDevices(self, w)) {
            s.delay = 90;
            return;
        }
        s.bombs = false;
        self.bomb_cam = null;
    }
    if (s.wait > 0) {
        s.wait -= 1;
        return;
    }
    for (self.fighters.items) |f| if (world_mod.actorOf(f.obj).busy()) return;
    while (s.next < self.fighters.items.len) {
        const i = s.next;
        s.next += 1;
        const f = &self.fighters.items[i];
        // A burning barrel explodes at the heroes' turn start (0x4903d0).
        const barrel = s.side == .hero and f.side == .neutral and f.explosive;
        if ((f.side != s.side and !barrel) or !f.alive()) continue;
        if (try sideStartOne(self, w, f, @intCast(i))) {
            s.wait = 60;
            return;
        }
    }
    const side = s.side;
    self.seq = null;
    if (checkEnd(self)) {
        if (self.phase == .won) roster.unlockAll(w);
        return;
    }
    if (side == .hero) try startPlayerPhase(self, w);
}

/// Fighter turn start (0x48f6f0, 0x4903d0 with 1): defence ends, fire and gas
/// burn 15/10/5 for the remaining 3/2/1 turns, effect 8 deals 20; true if damaged.
fn sideStartOne(self: *Battle, w: *World, f: *Fighter, i: u16) !bool {
    {
        f.attracted = true; // 0x48f72c
        states.hazardCheck(self, w, f); // 0x48f779
        if (f.defending) {
            f.defending = false;
            anim.restoreHold(w, f.*);
            world_mod.actorOf(f.*.obj).pickIdle(w.crt());
        }
        // Each state is its own +0xcc strike without attacker or weapon (0x4903d0: fire
        // +0x248dc, gas +0x248e4, 5/10/15 by counter; Invisible's poison +0x248e8, 20),
        // each with its own popup; never on the dead (0x490e83).
        var hits: [3]i32 = undefined;
        for ([_]i32{ f.burning, f.gassed }, 0..) |turns, k| hits[k] = hazardDamage(turns);
        hits[2] = if (f.bitten) 20 else 0;
        var hurt_any = false;
        for (hits) |dmg| if (dmg > 0 and f.alive()) {
            battle.note(self, "turn {d}: {s} burning/poisoned: {d}", .{ self.turn, f.obj.name, dmg });
            try strike.hurt(self, w, i, dmg);
            hurt_any = true;
        };
        if (hurt_any) return true;
    }
    return false;
}

/// Turn reset (0x48f6f0): walked 0, not acted, turn not over; a fighter that can
/// neither walk (0x48f960) nor strike (0x48f990) loses the turn at once — acted, turn
/// over, whole walk_range used (0x48f755…0x48f771), so its portrait is grey (0x4922d0).
pub fn resetTurn(f: *Fighter) void {
    f.used = 0;
    f.acted = false;
    const can_walk = !fields.moveLock(f.obj) and !f.disabled();
    const can_strike = f.obj.getInt("attackLock") == 0 and !f.disabled();
    if (!can_walk and !can_strike) {
        f.used = @floatFromInt(fields.walkRange(f.obj));
        f.acted = true;
    }
}

/// Fire or gas damage by turns left (0x4903d0): 3/2/1 → 15/10/5.
fn hazardDamage(turns: i32) i32 {
    return switch (turns) {
        3 => 15,
        2 => 10,
        1 => 5,
        else => 0,
    };
}

/// Side turn end (0x4903d0 with 2): state counters decrease.
pub fn sideTurnEnd(self: *Battle, w: *World, side: Side) void {
    for (self.fighters.items) |*f| {
        if (f.side != side or !f.alive()) continue;
        f.soaked = @max(0, f.soaked - 1);
        if (f.asleep > 0) {
            f.asleep -= 1;
            if (f.asleep == 0) {
                battle.note(self, "  {s}: woke up", .{f.obj.name});
                // 0x490504…0x490510: stance and weapon back (0x42b300) unless defending; when
                // defending, sleep never touched them (0x490391).
                if (!f.defending) anim.restoreHold(w, f.*);
            }
        }
        f.gassed = @max(0, f.gassed - 1);
        f.frozen = @max(0, f.frozen - 1);
        f.burning = @max(0, f.burning - 1);
    }
}

/// Hero with a counter-attack roll (0x498a96 → 0x45bd70): selected with sound,
/// popup 516 over him, "defend_end", aiming with the weapon in hand (a non-weapon
/// or empty hand means the fist GS_fist_all, 0x45be97…0x45bed4); only he strikes.
pub fn startCounter(self: *Battle, w: *World) bool {
    for (self.fighters.items, 0..) |*f, i| {
        if (!f.counter) continue;
        f.counter = false;
        if (!f.alive()) continue;
        const wpn = weapons.defaultWeapon(w, f.*) orelse continue;
        f.weapon = wpn;
        self.phase = .counter;
        self.selected = @intCast(i);
        w.selected_hero = f.obj.name;
        // "Counterattack" over the hero is an ordinary TextEffect popup (0x45be2b).
        battle.popup(self, f.*, w.stringOr(516, "Counterattack"), .counter) catch {};
        w.out.sound(w.gpa, "selecthero", null);
        const a = world_mod.actorOf(f.*.obj);
        a.play(a.resolve("defend_end"), false, true);
        // 0x45be60..0x45be92: after "defend_end" the battle stance by weapon (0x427c70),
        // 0x42b300; the new stance's idle starts when defend_end finishes.
        anim.restoreHold(w, f.*);
        battle.note(self, "  {s}: counterattack", .{f.obj.name});
        control.refreshSelection(self, w);
        return true;
    }
    return false;
}

/// Counter-attack without a player: best strike from the current tile, else skip.
/// Recharging or out of ammo means skip: the player couldn't strike with it (0x47c2a6).
pub fn autoCounter(self: *Battle, w: *World) !void {
    const me = self.selected orelse {
        self.phase = .enemy;
        return;
    };
    const f = self.fighters.items[me];
    if (World.nativeOf(f.weapon.?).fight.recharge > 0 or !weapons.hasAmmo(w, f, f.weapon.?)) {
        self.phase = .enemy;
        return;
    }
    var best: ?grid.Target = null;
    var best_dmg: i32 = 0;
    for (control.targetList(self)) |aim| {
        const o = self.grid().at(aim.tile);
        if (o == grid.Grid.none or self.fighters.items[o].side == f.side or self.fighters.items[o].side == .neutral) continue;
        const d = @as(i32, aim.pct) * f.weapon.?.getInt("max_damage");
        if (best == null or d > best_dmg) {
            best = aim;
            best_dmg = d;
        }
    }
    if (best) |aim| try strike.startAttack(self, w, me, f.weapon.?, aim) else self.phase = .enemy;
}

/// Right click in battle (0x4563e0): during a counterattack decline it (0x452a00); in the
/// facing choice exit it (0x452edb); otherwise toggle aim mode.
pub fn rightClick(self: *Battle, w: *World) !void {
    if (self.phase == .counter) return endTurn(self, w);
    if (self.facing_mode) return control.cancelFacing(self);
    w.mouse.aim = !w.mouse.aim;
}

/// Player turn end (EndTurnGlobal / button): the enemies act. During a counter-
/// attack, decline it.
pub fn endTurn(self: *Battle, w: *World) !void {
    self.facing_mode = false;
    if (self.phase == .counter and self.pending == .none) {
        self.phase = .enemy;
        control.refreshSelection(self, w);
        return;
    }
    if (self.phase == .appear) {
        self.skip_turn = true;
        return;
    }
    if (self.phase != .player or self.pending != .none) return;
    sideTurnEnd(self, w, .hero);
    // Heroes' turn end (0x454d97 → 0x48f790 for the party): rage −1.
    for (self.fighters.items) |*f| if (f.side == .hero) f.spendRage();
    // Enemy turn start (0x49844c): every weapon's recharge −1.
    for (w.rt.objects.items) |o| {
        const nat = World.nativeOf(o);
        if (nat.kind == .weapon) nat.fight.recharge = rules.rechargeTick(nat.fight.recharge);
    }
    // A departed Invisible is removed (0x49839f: +0x60 = 1): not a death, no exp;
    // then the victory check (0x4983d0): are enemies left (two Garcias).
    if (self.invisible_leaving) {
        self.invisible_leaving = false;
        if (self.invisibleMfd()) |i| {
            const f = &self.fighters.items[i];
            f.dead = true;
            World.nativeOf(f.obj).deleted = true;
            f.obj.enabled = false;
            battle.note(self, "  {s} removed", .{f.obj.name});
        }
    }
    // Enemy turn (0x498310 with 0): 80 ticks of the banner, bombs, enemies' states.
    self.enemy_period = true;
    self.seq = .{ .side = .enemy, .delay = 80, .bombs = true };
    for (self.bombs.items) |*bomb| bomb.ticked = false;
    bombs.chargeTurn(self);
    devices.refreshDecoys(self);
    self.phase = .enemy;
    self.enemy_cursor = 0;
    self.ai_stage = .plan;
    for (self.fighters.items) |*f| {
        resetTurn(f);
    }
    @memset(self.reach_left, -1);
    self.target_len = 0;
}

// ---------------------------------------------------------------- tests

test "fire and gas damage by turns left: 15/10/5 (0x4903d0)" {
    try std.testing.expectEqual([5]i32{ 15, 10, 5, 0, 0 }, [5]i32{ hazardDamage(3), hazardDamage(2), hazardDamage(1), hazardDamage(0), hazardDamage(4) });
}

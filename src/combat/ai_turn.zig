//! Turn of an AI-controlled fighter (enemies, and heroes in autobattle): attack
//! preview, plan (combat/ai.zig), path to the strike tile, strike, rest of the
//! path, end of the enemy round. Turn order is `turnOrder` (0x498288).

const weapon_class = @import("../battle.zig").weapon_class;
const control = @import("control.zig");
const states = @import("states.zig");
const strike = @import("strike.zig");
const battle = @import("../battle.zig").battle;
const anim = @import("anim.zig");
const Battle = battle.Battle;
const World = @import("../state.zig").world.World;
const grid = @import("../battle.zig").grid;
const ai = @import("ai.zig");
const Side = @import("../battle.zig").fighter.Side;
const Class = @import("../battle.zig").fighter.Class;
const max_fighters = battle.max_fighters;

const turns = @import("turns.zig");
const roster = @import("roster.zig");

/// Index of the fighter acting `k`-th: list order; in a battle with `levelMode` 2
/// enemies with `classType` 7 (Grandma in the citadel) go first (0x498288).
fn turnOrder(self: *Battle, w: *World, side: Side, k: usize) usize {
    const l = w.level orelse return k;
    if (side != .enemy or l.getInt("levelMode") != 2) return k;
    var order: [max_fighters]usize = undefined;
    var n: usize = 0;
    for (self.fighters.items, 0..) |f, i| if (Class.of(f.obj) == .grandma) {
        order[n] = i;
        n += 1;
    };
    for (self.fighters.items, 0..) |f, i| if (Class.of(f.obj) != .grandma) {
        order[n] = i;
        n += 1;
    };
    return order[k];
}

/// Enemy attack tiles shown before the strike.
pub fn aiTargets(self: *Battle) []const grid.Target {
    return self.ai_target_buf[0..self.ai_target_len];
}

/// Turn of the next AI fighter of `side` (combat/ai.zig): plan, path to the
/// strike tile, strike, rest of the path.
pub fn stepAI(self: *Battle, w: *World, side: Side) !void {
    // Enemy attack preview: commands 0x32 (0x42447f, counter 15) and 0x33 (0x4244ae,
    // 45); the check 0x424f45/0x424f5e decrements first and ends at ≤ 0, and the next
    // command starts the same tick (0x4265d7…0x4265ef): attack tiles for 14 ticks,
    // with effect tiles 44, strike at T+58.
    if (self.ai_show) |*sh| switch (sh.stage) {
        .walk => {},
        .area, .effect => {
            sh.ticks -= 1;
            if (sh.ticks > 0) return;
            if (sh.stage == .area) {
                sh.stage = .effect;
                sh.ticks = 44;
                return;
            }
            self.ai_show = null;
        },
    };
    while (self.enemy_cursor < self.fighters.items.len) {
        const i = turnOrder(self, w, side, self.enemy_cursor);
        const f = &self.fighters.items[i];
        const who: u16 = @intCast(i);
        // The turn list (0x498b8e…0x498bce) doesn't check sleep or freeze: a sleeper also
        // gets an AI turn (0x498d30), but the normal scoring without "can strike"
        // (0x48f990) and "can walk" (0x48f960) does nothing. Smoke Rider (class 6, own
        // scoring 0x4de890) scans targets even asleep, within ±π/4 of its gaze
        // (0x4de918…0x4dea1e), and shoots without moving. Everyone else is skipped:
        // a turn without action.
        const sleeper_acts = f.disabled() and ai.evalOf(f.*) == .smokerider;
        if (f.side != side or !f.alive() or f.appear_to != null or (f.disabled() and !sleeper_acts)) {
            // The fighter dropped out mid-turn (killed by a hero's counter-attack, a blast
            // etc.): the rest of its plan (path after the strike, second strike) goes with
            // it. In the exe that rest is the fighter's own queue (0x499baf…0x499bf7 →
            // 0x428a80), death clears it (0x4905c2 → 0x48ed20), and the next fighter starts
            // with move scoring (0x498d30). Before, the stage (walk2, attack2) leaked to the
            // next fighter, which then walked the dead one's path.
            if (self.ai_stage != .plan) {
                self.ai_stage = .plan;
                self.ai_show = null;
                self.schizo_second = null;
            }
            self.enemy_cursor += 1;
            continue;
        }
        switch (self.ai_stage) {
            .plan => {
                self.cam_pair = null; // 0x498b51: next fighter, camera follows it again
                if (f.obj.getInt("aiMode") == 2) {
                    self.enemy_cursor += 1;
                    continue;
                }
                self.ai_plan = try ai.plan(self, w, who);
                battle.note(self, "  AI {s} at {d},{d}: path {d}, strike {s}, score {d}, to foe {d:.1}, move {d:.1}", .{ f.obj.name, f.tile[0], f.tile[1], self.ai_plan.len, if (self.ai_plan.attack_at != null) "yes" else "no", self.ai_plan.score, self.ai_plan.foe_dist, f.budget() });
                self.ai_shown = false;
                if (side == .enemy) {
                    grid.reachCost(self.grid(), self.ai_reach, f.tile, f.size, who, f.budget(), grid.diagonal_cost_ai);
                    self.ai_show = .{ .who = who, .stage = .walk };
                }
                self.ai_stage = .walk1;
                if (self.ai_plan.len == 0) {
                    self.ai_stage = .plan;
                    self.enemy_cursor += 1;
                }
            },
            .walk1 => {
                self.ai_stage = .attack;
                const p = &self.ai_plan;
                const end = p.attack_at orelse p.len - 1;
                if (end > 0) {
                    try control.startWalkPath(self, w, who, p.path[0 .. end + 1]);
                    return;
                }
            },
            .attack => {
                const p = &self.ai_plan;
                // Enemy attack preview before the strike (0x499770).
                if (side == .enemy and p.attack_at != null and !self.ai_shown) {
                    self.ai_shown = true;
                    self.ai_target_len = 0;
                    if (weapon_class.pattern(p.weapon.?)) |pat|
                        self.ai_target_len = grid.targets(self.grid(), pat, f.tile, who, true, true, &self.ai_target_buf).len;
                    self.ai_show = .{ .who = who, .stage = .area, .ticks = 14 }; // 15, decremented by the same tick's check
                    return;
                }
                if (self.ai_show) |sh| if (sh.stage == .walk) {
                    self.ai_show = null;
                };
                self.ai_stage = .walk2;
                if (p.attack_at != null) {
                    var wpn = p.weapon.?;
                    // Schizo (0x4e0d70): two strikes into one tile with weapon pairs by counter:
                    // (1077, 1078), (1077, 1079), (1078, 1079).
                    if (Class.of(f.obj) == .schizo) if (anim.schizoPair(w, f.*)) |pair| {
                        wpn = pair[0];
                        self.schizo_second = pair[1];
                        f.schizo_turn +|= 1;
                        self.ai_stage = .attack2;
                    } else {
                        self.schizo_second = wpn;
                        self.ai_stage = .attack2;
                    };
                    if (side == .enemy) self.cam_pair = .{ .who = who, .tile = p.aim.tile };
                    try strike.startAttack(self, w, who, wpn, p.aim);
                    return;
                }
            },
            .attack2 => {
                self.ai_stage = .walk2;
                if (self.schizo_second) |wpn| if (f.alive()) {
                    self.schizo_second = null;
                    try strike.startAttack(self, w, who, wpn, self.ai_plan.aim);
                    return;
                };
            },
            .walk2 => {
                self.ai_stage = .plan;
                self.ai_show = null;
                // Incubus and Cripple (11, 12) act twice in a row with a full walk budget.
                const ct = Class.of(f.obj);
                if ((ct == .incubus or ct == .cripple) and !f.second and f.alive()) {
                    f.second = true;
                    f.used = 0;
                } else {
                    f.second = false;
                    self.enemy_cursor += 1;
                    battle.note(self, "  AI final {s}: {d},{d}", .{ f.obj.name, f.tile[0], f.tile[1] });
                    control.afterMove(self, w, f);
                }
                const p = &self.ai_plan;
                if (p.attack_at) |at| if (p.len - 1 > at and f.alive()) {
                    try control.startWalkPath(self, w, who, p.path[at..p.len]);
                    return;
                };
            },
        }
    }
    self.enemy_cursor = 0;
    self.ai_stage = .plan;
    self.ai_show = null;
    if (side == .hero) {
        try turns.endTurn(self, w);
        return;
    }
    // All enemies have acted (0x498c37): CombatEnemiesAppear on the level, dialogs
    // by levelMode, then a new turn; summoned enemies walk in first.
    turns.sideTurnEnd(self, w, .enemy);
    try turns.enemyTurnOver(self, w);
    self.turn += 1;
    // Log: weapons still recharging at the heroes' turn (the battery number).
    if (self.log != null) for (w.rt.objects.items) |o| {
        const nat = World.nativeOf(o);
        if (nat.kind == .weapon and nat.fight.recharge > 0) battle.note(self, "turn {d}: {s} recharging {d}", .{ self.turn, o.name, nat.fight.recharge });
    };
    // New round (0x4985f6 → 0x495310): fire and gas on tiles decay.
    for (self.fire) |*v| v.* -|= 1;
    for (self.gas) |*v| v.* -|= 1;
    // The Invisible that bit McFadden leaves the battle (0x4985fb): the exe looks
    // the object up by the hard-coded name `04mf_invisible1`, the level script does
    // not do it. Tiles are freed (0x48ed20), removal at the enemy turn start (0x49839f).
    if (self.invisibleMfd()) |i| {
        const f = self.fighters.items[i];
        self.grid().remove(f.tile, f.size);
        self.invisible_leaving = true;
        battle.note(self, "  {s} leaves the grid", .{f.obj.name});
    }
    // Schizo's gas clouds fade when no gas is left on their tile.
    if (w.combat_map) |cm| for (w.effects.clouds.items) |*cl| {
        if (cl.fading == 0 and states.hazardAt(self, self.gas, cm.tileOf(cl.pos, 1)) == 0) cl.fading = 30;
    };
    if (try roster.addNewcomers(self, w)) {
        self.phase = .appear;
        roster.startAppear(self, w);
        return;
    }
    try turns.beginPlayerTurn(self, w);
}

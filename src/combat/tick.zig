//! Battle tick: phases, strike choreography, barrel blasts and the AI turn. Top of
//! combat: calls turn phases (combat/turns.zig) and the AI turn (combat/ai_turn.zig), never the reverse.

const std = @import("std");
const fields = @import("../fields.zig");
const crt_rand = @import("../crt_rand.zig");
const scenes = @import("../scene.zig").scenes;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const battle = @import("../battle.zig").battle;
const Battle = battle.Battle;
const turns = @import("turns.zig");
const attack = @import("attack.zig");
const roster = @import("roster.zig");
const ai_turn = @import("ai_turn.zig");
const states = @import("states.zig");
const strike = @import("strike.zig");
const anim = @import("anim.zig");

pub fn tick(self: *Battle, w: *World) !void {
    if (self.push_sound) |*ps| {
        if (ps.ticks > 0) ps.ticks -= 1 else {
            w.out.sound(w.gpa, ps.name, null);
            self.push_sound = null;
        }
    }
    try tickPhase(self, w);
    tickFirePhases(self, w.crt());
    try tickBlasts(self, w);
}

/// Fire object tick (+0x24 = 0x4a6970): over the 32×32 tiles row by row, a tile
/// that catches fire gets phase rand() % 31 + 1, a non-burning one 0. The object is
/// created after the barrels, so it updates before them.
fn tickFirePhases(self: *Battle, rand: *crt_rand.Rand) void {
    for (&self.fire_phase, 0..) |*row, y| for (row, 0..) |*p, x| {
        const burning = x < self.width and y < self.height and self.fire[y * self.width + x] != 0;
        if (!burning) p.* = 0 else if (p.* == 0) p.* = @intCast(rand.below(31) + 1);
    };
}

/// Barrel blasts: barrel weapon tick (+0x24 = 0x4ce1b0): −1, at zero a strike on
/// the 8 neighbours. Objects update (0x420303) after the battle mode (0x45a870),
/// from the head of list 0x63bcb8, newest first; a barrel blown up in this pass
/// ticks in it too only if its weapon is further down the list. `blasts` keeps
/// the list order.
fn tickBlasts(self: *Battle, w: *World) !void {
    var i: usize = 0;
    while (i < self.blasts.items.len) {
        const b = &self.blasts.items[i];
        b.ticks -= 1;
        if (b.ticks > 0) {
            i += 1;
            continue;
        }
        const blast = self.blasts.orderedRemove(i);
        battle.note(self, "  tick {d}: blast {s}", .{ w.ticks, blast.weapon.name });
        // On behalf of whoever blew it up (0x4ce1cd…0x4ce217): +5 exp before the strike
        // even if already dead; the exe forgets the attacker only when it is removed
        // (0x4ce230), more than 115 ticks after death, while the fuse is 15.
        const by: ?u16 = blast.credit;
        if (by) |c| if (self.fighters.items[c].side == .hero) {
            self.fighters.items[c].pending_exp += 5;
        };
        self.blast_credit = by;
        defer self.blast_credit = null;
        try strike.resolveAttack(self, w, blast.barrel, blast.weapon, .{ .tile = blast.tile, .effect = 0, .pct = 100 }, null, false);
        i = 0;
        while (i < self.blasts.items.len and self.blasts.items[i].order > blast.order) i += 1;
    }
}

fn tickPhase(self: *Battle, w: *World) !void {
    turns.tickPopups(self);
    try states.tickLilith(self, w);
    if (self.seq != null and self.phase != .won and self.phase != .lost) return turns.stepSeq(self, w);
    switch (self.phase) {
        .appear => {
            // One at a time (0x498650 step 4): the next starts when the previous arrived;
            // tiles are taken at once (0x48eb70).
            if (self.appear_walker) |k| {
                const f = self.fighters.items[k];
                if (world_mod.actorOf(f.obj).busy()) return;
                anim.snap(w, f);
                self.appear_walker = null;
            }
            for (self.fighters.items, 0..) |*f, k| if (f.appear_to) |to| {
                // 0x48f240: turn to the target at once (command 0x10), walk straight (0x11),
                // then a one-shot "appearEnd" if the class has it (0x13).
                anim.walkStraight(w, f, to);
                if (w.combat_map) |cm| {
                    const p0 = cm.tileCenter(f.tile, f.size);
                    const p1 = cm.tileCenter(to, f.size);
                    fields.setAngle(f.obj, fields.facing(p1[0] - p0[0], p1[1] - p0[1]));
                }
                const fa = world_mod.actorOf(f.*.obj);
                if (fa.hasMapping("appearEnd")) try fa.queue.append(w.gpa, .{ .anim = "appearEnd" });
                f.tile = to;
                f.appear_to = null;
                self.grid().place(f.tile, f.size, @intCast(k));
                self.appear_walker = @intCast(k);
                return;
            };
            // Pre-battle dialog after the appearance (deployment mode sits above dialogs in
            // the GUI stack); the player turn starts after the dialog.
            if (w.scene.pending_dialog) |pd| {
                w.scene.pending_dialog = null;
                self.wait_dialog = true;
                try scenes.startDialog(w, pd[0], pd[1]);
                return;
            }
            if (self.wait_dialog) {
                if (w.scene.runner != null) return;
                self.wait_dialog = false;
            }
            if (!self.started) {
                self.started = true;
                if (w.level) |l| _ = try w.rt.callIfExists(l, "CombatEnemiesAppear", &.{});
            }
            try turns.beginPlayerTurn(self, w);
        },
        .player, .enemy, .counter => {
            try attack.stepPending(self, w);
            if (self.pending != .none) return;
            if (turns.checkEnd(self)) {
                if (self.phase == .won) roster.unlockAll(w);
                return;
            }
            switch (self.phase) {
                .enemy => {
                    if (turns.startCounter(self, w)) return;
                    try ai_turn.stepAI(self, w, .enemy);
                },
                .counter => if (self.auto_heroes) try turns.autoCounter(self, w),
                else => if (self.auto_heroes) try ai_turn.stepAI(self, w, .hero),
            }
        },
        .won, .lost => {
            self.over_ticks += 1;
            // Victory (0x454880) and defeat (0x454350): the jingle 90 ticks after the end.
            if (self.over_ticks == 90) w.out.music_events.append(w.gpa, .{ .name = if (self.phase == .won) "victory" else "gameover", .once = true }) catch {};
        },
    }
}

test "tile fire phases (0x4a6970): rand() % 31 + 1 on ignition, 0 when out" {
    var fire = [_]u8{ 0, 3, 0, 0, 0, 0 };
    var t: struct { b: Battle } = .{ .b = .{ .gpa = std.testing.allocator, .blocked = &.{}, .occupant = &.{}, .reach_left = &.{}, .fire = &fire, .gas = &.{}, .width = 3, .height = 2 } };
    var r: crt_rand.Rand = .{};
    tickFirePhases(&t.b, &r);
    // First MSVC rand() is 41: 41 % 31 + 1 = 11; other tiles aren't burning.
    try std.testing.expectEqual(@as(u8, 11), t.b.fire_phase[0][1]);
    try std.testing.expectEqual(@as(u8, 0), t.b.fire_phase[0][0]);
    // Still burning: same phase, no rand() spent; extinguished: 0.
    tickFirePhases(&t.b, &r);
    try std.testing.expectEqual(@as(u8, 11), t.b.fire_phase[0][1]);
    try std.testing.expectEqual(@as(i32, 18467), r.next());
    fire[1] = 0;
    tickFirePhases(&t.b, &r);
    try std.testing.expectEqual(@as(u8, 0), t.b.fire_phase[0][1]);
}

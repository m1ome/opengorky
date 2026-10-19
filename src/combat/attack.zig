//! Strike choreography: the pending attack's countdowns from the animation start to the
//! hit, projectile flight, second hits and the return to idle.

const fields = @import("../fields.zig");
const control = @import("control.zig");
const states = @import("states.zig");
const strike = @import("strike.zig");
const battle = @import("../battle.zig").battle;
const anim = @import("anim.zig");
const Battle = battle.Battle;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const generic = @import("../battle.zig").generic;
const fx = @import("../fx.zig");

/// Strike choreography countdown: null = none, >0 = wait (−1), 0 = now (reset).
fn countdown(n: *?u32) enum { idle, wait, fire } {
    const v = n.* orelse return .idle;
    if (v > 0) {
        n.* = v - 1;
        return .wait;
    }
    n.* = null;
    return .fire;
}

pub fn stepPending(self: *Battle, w: *World) !void {
    switch (self.pending) {
        .none => {},
        .walk => |who| {
            if (world_mod.actorOf(self.fighters.items[who].obj).busy()) return;
            anim.snap(w, self.fighters.items[who]);
            self.pending = .none;
            control.faceAfterWalk(self, w, who);
            // After moving (0x48f790): fire and gas underfoot.
            states.hazardCheck(self, w, &self.fighters.items[who]);
            control.refreshSelection(self, w);
        },
        .attack => |*at| {
            if (at.turning) {
                if (world_mod.actorOf(self.fighters.items[at.who].obj).turn_to != null) return;
                at.turning = false;
                anim.beginAttackAnim(w, self.fighters.items[at.who], at.weapon);
            }
            at.tick += 1;
            // Headnail (0x48a72b): the saws spin "obrot" (0x48d760 → 0x44f910), the left
            // after attack_headnail_delay1 (30), the right delay2 (5) later; the hit after
            // delay3 (8), at tick wait + 1.
            if (fields.nameId(self.fighters.items[at.who].obj) == 118) {
                if (at.tick == 30 + 1) anim.spinLink(w, self.fighters.items[at.who].obj, "pila lewa");
                if (at.tick == 35 + 1) anim.spinLink(w, self.fighters.items[at.who].obj, "pila prawa");
            }
            // Flash before the hit (Garcia, Schizo's gas) on the same countdown as the hit
            // (hit at tick wait + 1).
            if (at.pre) |p| if (at.tick == p + 1) {
                at.pre = null;
                if (w.combat_map) |cm| fx.hits.preFlash(w, self.fighters.items[at.who].obj, generic.fxId(at.weapon), cm.tileCenter(at.aim.tile, 1));
            };
            // Victim lift onto the link point (state 3, 0x496f1f): attach, its idle is "delirium".
            if (at.lift) |lf_| if (at.tick == lf_.bind_at) if (at.victim) |vi| {
                const v = &self.fighters.items[vi];
                if (v.alive()) {
                    world_mod.actorOf(self.fighters.items[at.who].obj).bind = .{ .victim = v.obj, .link = lf_.link, .z = lf_.z * w.actorScale() };
                    const va = world_mod.actorOf(v.*.obj);
                    va.forced_idle = va.resolve("delirium");
                    va.play(va.forced_idle.?, true, false);
                }
            };
            if (at.delay > 0) {
                at.delay -= 1;
                return;
            }
            if (at.until_end and world_mod.actorOf(self.fighters.items[at.who].obj).one_shot) return;
            // Projectile (rocket, grenade, bottle, knife): damage on arrival (0x49b920).
            if (!at.launched) if (w.combat_map) |cm| {
                at.launched = true;
                const id = fx.launch.launch(w, self.fighters.items[at.who].obj, at.weapon, cm.tileCenter(at.aim.tile, 1));
                if (id != 0) {
                    at.flight = id;
                    if (at.second > 0) at.second_in = at.second;
                    return;
                }
            };
            if (countdown(&at.second_in) == .fire) {
                if (w.combat_map) |cm| at.flight2 = fx.launch.launchSecond(w, self.fighters.items[at.who].obj, at.weapon, cm.tileCenter(at.aim.tile, 1));
            }
            if (!at.hit1) {
                if (at.flight != 0 and w.effects.projectileAlive(at.flight)) return;
                at.hit1 = true;
                try strike.resolveAttack(self, w, at.who, at.weapon, at.aim, &at.strike, false);
                // Second hit without a projectile (Headnail, 0x48a72b: the right saw
                // attack_headnail_delay4 + delay5 after the first): damage again.
                if (at.flight == 0 and at.second > 0) at.melee2_in = at.second;
                if (at.react > 0) at.react_in = at.react;
                if (at.vanish > 0) at.vanish_in = at.vanish;
            }
            switch (countdown(&at.vanish_in)) {
                .wait => return,
                .fire => world_mod.actorOf(self.fighters.items[at.who].obj).materialize(false),
                .idle => {},
            }
            switch (countdown(&at.react_in)) {
                .wait => return,
                .fire => strike.reactAgain(self, w, at.who),
                .idle => {},
            }
            switch (countdown(&at.melee2_in)) {
                .wait => return,
                .fire => try strike.resolveAttack(self, w, at.who, at.weapon, at.aim, &at.strike, true),
                .idle => {},
            }
            if (at.second_in != null) return;
            if (at.flight2 != 0) {
                if (w.effects.projectileAlive(at.flight2)) return;
                at.flight2 = 0;
                try strike.resolveAttack(self, w, at.who, at.weapon, at.aim, &at.strike, false);
            }
            // After the hit the attacker still waits (exe choreography); a lift is released
            // release_after ticks later.
            const aa = world_mod.actorOf(self.fighters.items[at.who].obj);
            if (at.then) |t| aa.play(aa.resolve(t), false, true);
            if (at.after > 0) try aa.queue.append(w.gpa, .{ .delay = at.after });
            if (at.lift) |lf_| if (aa.bind) |*bd| {
                bd.release_in = lf_.release_after;
            };
            self.pending = .settle;
        },
        .push => |*p| {
            const f = &self.fighters.items[p.hero];
            const ob = &self.fighters.items[p.obstacle];
            const ha = world_mod.actorOf(f.*.obj);
            const oa = world_mod.actorOf(ob.*.obj);
            if (!p.begun) {
                if (ha.turn_to != null) return;
                p.begun = true;
                ha.play(ha.resolve("push_start"), false, true);
                self.push_sound = .{ .name = p.sound, .ticks = p.sound_ticks };
                return;
            }
            switch (p.stage) {
                0 => {
                    if (ha.one_shot) return;
                    // Hero into the obstacle's tile, the obstacle further on at the same speed.
                    p.anim = oa.anim;
                    anim.walkStraight(w, f, ob.tile);
                    ha.walk_anim = "push_walk";
                    ha.play(ha.resolve("push_walk"), true, false);
                    anim.walkStraight(w, ob, p.to);
                    // In the exe the obstacle follows the hero attached to him (command 0x2d(5,
                    // obstacle) in the hero's queue, 0x48d97c); its angle doesn't change. Without
                    // this the box first turned along the move.
                    oa.no_rotation = true;
                    oa.move_speed = ha.move_speed;
                    oa.play(p.anim, false, false);
                    p.stage = 1;
                },
                1 => {
                    if (ha.path_index < ha.path.items.len or oa.path_index < oa.path.items.len) return;
                    const g = self.grid();
                    g.remove(f.tile, f.size);
                    f.tile = ob.tile;
                    ob.tile = p.to;
                    g.place(f.tile, f.size, p.hero);
                    g.place(ob.tile, ob.size, p.obstacle);
                    anim.snap(w, f.*);
                    anim.snap(w, ob.*);
                    ha.walk_anim = "walk";
                    ha.play(ha.resolve("push_end"), false, true);
                    p.stage = 2;
                },
                else => {
                    if (ha.one_shot) return;
                    ha.pickIdle(w.crt());
                    self.pending = .settle;
                },
            }
        },
        .settle => {
            if (self.blasts.items.len > 0) return;
            for (self.fighters.items) |f| if (world_mod.actorOf(f.obj).busy()) return;
            self.pending = .none;
            // Counter-attack done: the enemy turn continues.
            if (self.phase == .counter) self.phase = .enemy;
            control.refreshSelection(self, w);
            // The exe never enters facing mode after an action itself: 0x455080 only calls
            // 0x45c790, which has no callers or data references. Arrows appear only on a
            // click on the selected hero (0x45523a).
        },
    }
}

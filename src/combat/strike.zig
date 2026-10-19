//! Strike: attack start, hit roll (0x4ced30), damage (+0xcc), side bonus, armour, exp, popups.

const std = @import("std");
const weapon_class = @import("../battle.zig").weapon_class;
const value = @import("../script.zig").value;
const fields = @import("../fields.zig");
const weapons = @import("weapons.zig");
const attacks = @import("../battle.zig").attacks;
const devices = @import("devices.zig");
const states = @import("states.zig");
const battle = @import("../battle.zig").battle;
const anim = @import("anim.zig");
const Battle = battle.Battle;
const WeaponClass = @import("../battle.zig").weapon_class.WeaponClass;
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;
const floatToInt = @import("../script.zig").value.floatToInt;
const rules = @import("../battle.zig").rules;
const grid = @import("../battle.zig").grid;
const immunity = @import("../battle.zig").immunity;
const generic = @import("../battle.zig").generic;
const fx = @import("../fx.zig");
const patterns = @import("../battle.zig").patterns;
const inventory = @import("../inventory.zig");
const HeroAttack = @import("../battle.zig").attacks.HeroAttack;
const Tile = @import("../battle.zig").grid.Tile;
const Fighter = @import("../battle.zig").fighter.Fighter;
const Class = @import("../battle.zig").fighter.Class;
const Strike = @import("../battle.zig").rules.Strike;
const max_fighters = battle.max_fighters;

pub fn startAttack(self: *Battle, w: *World, who: u16, wpn: *Object, aim: grid.Target) !void {
    const f = &self.fighters.items[who];
    // Strike (0x47c6ba → 0x48f790): only the "attacked" flag (+0x24610); the remaining
    // walk budget (+0x2460c) stays, so the hero may step away after shooting.
    if (self.phase != .counter) f.acted = true;
    // Strike roll (+0xec, 0x47c58a) at the attack start, before the animation: hit,
    // damage with skill, luck, rage; "Luck" over the attacker right here (0x4cf0cf).
    // The strike camera reads the luck flag +0x1a98 (0x47c5b2).
    const strike = try rollStrike(self, w, who, wpn, aim);
    f.spendRage(); // 0x48f790 right after the strike roll (0x47c6ba)
    // Strike camera (0x47c120, commands 0x29/0x2a): only a hero in rage or with a
    // critical hit on a neighbouring tile, and both fit on screen: pan to the centre
    // of their box with 2× zoom.
    if (w.combat_map) |cm| if (f.side == .hero and (strike.rage or strike.crit) and
        @abs(aim.tile[0] - f.tile[0]) < 2 and @abs(aim.tile[1] - f.tile[1]) < 2)
    {
        // Centre is the middle of the union of the attacker's and target's model screen
        // boxes (0x47c5f2…0x47c675: +0x64…+0x70, head included so popups are in frame);
        // the union is at most 640 wide and 480 high.
        const tv = self.grid().at(aim.tile);
        const tbox = if (tv != grid.Grid.none and tv != who) world.actorOf(self.fighters.items[tv].obj).screen_box else null;
        if (world.actorOf(f.*.obj).screen_box) |ab| {
            var u = ab;
            if (tbox) |tb| u = .{ @min(u[0], tb[0]), @min(u[1], tb[1]), @max(u[2], tb[2]), @max(u[3], tb[3]) };
            if (u[2] - u[0] < world.screen_w and u[3] - u[1] < world.screen_h)
                w.out.attack_cam = .{ .center = .{ (u[0] + u[2]) / 2, (u[1] + u[3]) / 2 } };
        } else {
            const a0 = w.screenPos(f.obj);
            const t1 = w.cam.project(cm.tileCenter(aim.tile, 1));
            if (@abs(a0[0] - t1.x) < world.screen_w and @abs(a0[1] - t1.y) < world.screen_h)
                w.out.attack_cam = .{ .center = .{ (a0[0] + t1.x) / 2, (a0[1] + t1.y) / 2 } };
        }
    };
    // Before the strike a smooth turn to the target (0x4896b0: atan2 → 0x425150,
    // command 0x12, first in the attack queue) for everyone, the Puppet included: it
    // turns back to −1.57 at its turn end (0x4e17b0, +0xd0). Strike animation after the turn.
    anim.face(w, f.*, aim.tile);
    messiahDodge(self, who, wpn, aim);
    const turning = world.actorOf(f.*.obj).turn_to != null;
    if (!turning) anim.beginAttackAnim(w, f.*, wpn);
    // The hit comes n ticks after the animation starts: heroes by the exe table
    // (adjust.kdt, 0x48bda2), monsters by theirs (0x48d618). nameID picks the table
    // (0x4896b0), not the side: Medusa (119) uses her branch even in the party.
    // Port-only generic fighter (classType 100): strike from weapon fields.
    const gen = generic.is(f.obj);
    const hero_table = !gen and attacks.heroTable(fields.nameId(f.obj));
    const mon: ?attacks.MonsterAttack = if (gen) generic.attack(wpn) else if (!hero_table) attacks.monsterAttack(fields.nameId(f.obj), fields.nameId(wpn)) else null;
    const ha: ?HeroAttack = if (hero_table) attacks.heroAttack(fields.nameId(f.obj), fields.nameId(wpn)) else null;
    const delay: i32 = if (ha) |h| @as(i32, @intCast(h.wait)) + h.extra else @intCast(mon.?.wait);
    self.pending = .{ .attack = .{
        .who = who,
        .weapon = wpn,
        .aim = aim,
        .delay = @intCast(@max(0, delay)),
        .after = if (mon) |m| m.after else if (ha) |h| h.after else 0,
        .lift = if (mon) |m| m.lift else null,
        .second = if (mon) |m| m.second else 0,
        .react = if (mon) |m| m.react else 0,
        .vanish = if (mon) |m| m.vanish else 0,
        .pre = if (mon) |m| m.pre else if (ha) |h| h.pre else null,
        .until_end = if (ha) |h| h.until_end else false,
        .then = if (ha) |h| h.then else null,
        .turning = turning,
        .strike = strike,
    } };
    // The lifted victim turns to the attacker.
    if (mon) |m| if (m.lift != null) {
        const o = self.grid().at(aim.tile);
        if (o != grid.Grid.none and o != who) {
            self.pending.attack.victim = o;
            const vp = fields.pos(self.fighters.items[o].obj);
            const ap = fields.pos(f.obj);
            fields.setAngle(self.fighters.items[o].obj, fields.facing(ap[0] - vp[0], ap[1] - vp[1]));
        }
    };
    @memset(self.reach_left, -1);
    self.target_len = 0;
}

/// Repeat of the hit reaction without damage (callback 7: +0xf0 with flag 0, on
/// the target 0x490e80 without 0x490f10): a live one plays the hit animation
/// (0x491920), blood and red flash (0x491510). Garcia and Sphinx 20 ticks after the hit.
pub fn reactAgain(self: *Battle, w: *World, who: u16) void {
    const v = self.last_hit orelse return;
    const t = &self.fighters.items[v];
    if (!t.alive()) return;
    const a = world.actorOf(t.*.obj);
    a.play(a.resolve("hit"), false, true);
    fx.blood.onDamage(w, t.obj, self.fighters.items[who].obj);
}

/// Messiah (classType 18, battle 04__elevator_messiah, tile 11,18, facing 3.14)
/// is open to strikes only from tile (10,18) right in front of him.
pub fn messiahOpen(tile: Tile) bool {
    return tile[0] == 10 and tile[1] == 18;
}

/// Attack start (0x47c120 → 0x47c4c0…0x47c50e): if the Messiah is among the
/// fighters on the hit tiles (+0xe8) and the attacker isn't at (10,18), the Messiah
/// plays the dodge "unik" at once, before the shot (0x526d74 → 0x4230c0).
fn messiahDodge(self: *Battle, who: u16, wpn: *Object, aim: grid.Target) void {
    const pat = weapon_class.pattern(wpn) orelse return;
    if (messiahOpen(self.fighters.items[who].tile)) return;
    var tiles_buf: [128]Tile = undefined;
    for (grid.effectTiles(self.grid(), pat, aim, &tiles_buf)) |t| {
        const o = self.grid().at(t);
        if (o == grid.Grid.none or o == who) continue;
        const v = self.fighters.items[o];
        if (Class.of(v.obj) != .messiah) continue;
        world.actorOf(v.obj).play("unik", false, true);
    }
}

/// Strike roll (0x4ced30, weapon slot +0xec) in exe order with the same shared RNG
/// use: fighters on hit tiles (+0xe8; none means nothing is rolled); hit roll on
/// the first (+0xc4 → 0x4cedc2, rand % 101 > chance = miss +0x1a94); Messiah
/// outside tile (10,18) is a miss (0x4cee33); damage pct·max/100 (0x4cee66); on a
/// hit with a shooter and not bomb 9 / decoy 18, skill (rand % 101, sign rand & 1,
/// 0x4ceeee); damage > 3 and a hero shooter (+0x64): two luck rolls rand % 101 <
/// luck (0x4cefab…0x4cf00f): flag +0x1a98, damage ×1.2, "Luck" over the shooter
/// (0x4cf02c…0x4cf0cf); rage ×2 (0x4cf0d7). A bomb blast has no shooter
/// (0x4ce1f4: +0xec with 0).
fn rollStrike(self: *Battle, w: *World, who: u16, wpn: *Object, aim: grid.Target) !Strike {
    const rand = w.crt();
    const attacker = &self.fighters.items[who];
    const cls = wpn.getInt("classType");
    const base = @divTrunc(aim.pct * wpn.getInt("max_damage"), 100);
    var st: Strike = .{ .dmg = base };
    const pat = patterns.find(cls) orelse return st;
    var tiles_buf: [128]Tile = undefined;
    var first: ?u16 = null;
    var messiah = false;
    for (grid.effectTiles(self.grid(), pat, aim, &tiles_buf)) |t| {
        const o = self.grid().at(t);
        if (o == grid.Grid.none or o == who) continue;
        if (first == null) first = o;
        if (Class.of(self.fighters.items[o].obj) == .messiah) messiah = true;
    }
    const f0 = first orelse return st;
    const shooter = WeaponClass.from(cls) != .time_bomb and !self.bomb_blast;
    st = rules.strike(rand, .{
        .shooter = shooter,
        .rolls_to_hit = rules.rollsToHit(cls),
        .chance = rules.hitChance(fields.getF(attacker.obj, "accuracy"), fields.charSize(self.fighters.items[f0].obj), attacker.enraged()),
        .blocked = messiah and !messiahOpen(attacker.tile),
        .skill = if (WeaponClass.from(cls) == .decoy) null else weapons.skillOf(attacker.*, wpn),
        .max_damage = wpn.getInt("max_damage"),
        .pct = aim.pct,
        .luck = if (attacker.side == .hero) floatToInt(fields.getF(attacker.obj, "luck")) else null,
        .rage = attacker.enraged(),
    });
    // "Luck" popup (string 519) over the attacker, cfcCriticalhit, 0.75 (0x4cf02c…0x4cf0cf).
    if (st.crit) try battle.popup(self, attacker.*, w.stringOr(519, "Luck"), .crit);
    return st;
}

/// Strike: targets on hit tiles, hit roll on the first (0x4ced30), damage to each
/// with armour (0x49123e). `second`: second hit of a series (effects, fx.onHit).
pub fn resolveAttack(self: *Battle, w: *World, who: u16, wpn: *Object, aim: grid.Target, strike: ?*Strike, second: bool) !void {
    self.last_hit = null;
    const attacker = &self.fighters.items[who];
    const pat = weapon_class.pattern(wpn) orelse return;
    var tiles_buf: [128]Tile = undefined;
    const tiles = grid.effectTiles(self.grid(), pat, aim, &tiles_buf);
    var victims: [max_fighters]u16 = undefined;
    var nv: usize = 0;
    for (tiles) |t| {
        const o = self.grid().at(t);
        if (o == grid.Grid.none or o == who) continue;
        if (std.mem.indexOfScalar(u16, victims[0..nv], o) != null) continue;
        victims[nv] = o;
        nv += 1;
    }
    const cls = wpn.getInt("classType");
    // Hit landed: the camera pulls back 40 ticks later (command 0x2a).
    if (w.out.attack_cam) |*ac| if (ac.release == null) {
        ac.release = 40;
    };
    weapons.consumeAmmo(w, attacker, wpn);
    if (w.combat_map) |cm| fx.hits.onHit(w, attacker.obj, wpn, cm.tileCenter(aim.tile, 1), second);
    // Napalm launcher (+0xf4 → 0x4cf7a0) sets every hit tile on fire for 3 turns.
    // Gas on tiles (+6 of a grid tile) is set only by callback 49 (0x4885a8 →
    // 0x4aa360): the aimed tile and its 8 neighbours, cloud "gas2" (0x4a95d0); that's
    // Schizo's second attack (1078). The gas grenade (+0xdc 0x4bc640) and the
    // Invisible only poison those hit (0x4900f0(3)) and don't touch tiles.
    if (WeaponClass.from(cls) == .napalm) {
        for (tiles) |t| states.setHazard(self, self.fire, t, 3);
        battle.note(self, "  fire on {d} tiles", .{tiles.len});
    }
    if (fields.nameId(attacker.obj) == 136 and fields.nameId(wpn) == 1078) {
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) states.setHazard(self, self.gas, .{ aim.tile[0] + dx, aim.tile[1] + dy }, 1);
        }
    }
    // A time bomb is placed, it doesn't strike (its blast is bomb_blast).
    if (WeaponClass.from(cls) == .time_bomb and !self.bomb_blast) {
        try devices.placeTimeBomb(self, w, aim.tile);
        return;
    }
    // Decoy onto a free tile (0x4b9750): placed and spent.
    if (WeaponClass.from(cls) == .decoy and self.grid().at(aim.tile) == grid.Grid.none and self.grid().open(aim.tile)) {
        try devices.placeDecoy(self, w, aim.tile);
        World.nativeOf(wpn).deleted = true;
        wpn.enabled = false;
        if (inventory.equipment.equipped(w, attacker.obj, .hand) == wpn) inventory.equipment.setHoldState(w, attacker.obj, null);
        attacker.weapon = weapons.defaultWeapon(w, attacker.*);
        return;
    }
    // No victims: 0x4cf2af → 0x4cf48a still reaches the exp transfer and the
    // end-of-strike roll (+0xe8 returns the aimed tile count, not the victims).
    if (nv == 0) {
        _ = try transferExp(self, w, self.blast_credit orelse who, wpn, if (strike) |s| s.missed else false);
        return endRoll(w, strike);
    }
    const first = self.fighters.items[victims[0]];
    if (attacker.side == .hero and first.side != .hero and self.lilith_ticks == -10) if (w.level) |l| {
        if (l.getInt("levelMode") == 8) self.lilith_ticks = 100;
    };
    // Strike roll: from the attack start (both hits of one attack, Jet Elmer and
    // Headnail, use it; +0xf0 reads +0x1a94/+0x1a9c), otherwise now (barrel
    // 0x4bde11, bomb 0x4ce1f4: +0xec right before +0xf0).
    var rolled: Strike = undefined;
    const sp: *Strike = strike orelse blk: {
        rolled = try rollStrike(self, w, who, wpn, aim);
        break :blk &rolled;
    };
    const st = sp.*;
    const missed = st.missed;
    const chance = st.chance;
    battle.note(self, "turn {d}: {s} hits {s} with {s} ({d}%, chance {d}%): {s}", .{ self.turn, attacker.obj.name, first.obj.name, wpn.name, aim.pct, chance, if (missed) "miss" else "hit" });
    // A barrel blast strikes on behalf of whoever blew it up (`blast_credit`).
    const by = self.blast_credit orelse who;
    for (victims[0..nv]) |v| try hitVictim(self, w, by, wpn, v, st);
    const gained = try transferExp(self, w, by, wpn, missed);
    // Weapon skill (0x4cf5f2 → 0x48fea0): every successful use by a hero (except
    // class 17) adds 1 to the counter; at the threshold, a level and a popup.
    if (attacker.side == .hero and !missed and gained and WeaponClass.from(cls) != .barrel and attacker.alive()) {
        if (try weapons.growSkill(w, attacker.obj, fields.nameId(wpn))) {
            try battle.popup(self, attacker.*, w.stringOr(521, "Weapon skill increased"), .skill);
        }
    }
    endRoll(w, sp);
}

/// Hero exp (0x4cf490): the weapon bonus; on a hit it moves to `experience` with
/// a level-up check (0x48fa30). Returns whether exp was pending.
fn transferExp(self: *Battle, w: *World, by: u16, wpn: *Object, missed: bool) !bool {
    const ex = &self.fighters.items[by];
    const gained = ex.pending_exp > 0;
    if (ex.side == .hero and gained) {
        ex.pending_exp += wpn.getInt("extraExperience");
        if (!missed and ex.alive()) try awardExp(self, w, ex);
    }
    return gained;
}

/// End of the strike (0x4cf71c…0x4cf76f): weapon damage +0x1a9c +=
/// ·{10, −10, 17, −17}[rand() % 4] / 100; the next hit of the same attack uses it
/// (second rocket, second saw).
fn endRoll(w: *World, sp: ?*Strike) void {
    const ks = [4]i32{ 10, -10, 17, -17 };
    const k = ks[w.crt().below(4)];
    if (sp) |s| s.dmg += @divTrunc(s.dmg * k, 100);
}

/// Strike on one target (target +0xcc): miss, obstacle, armour, resistance,
/// damage, exp, weapon effect, counter-attack roll.
fn hitVictim(self: *Battle, w: *World, who: u16, wpn: *Object, v: u16, st: Strike) !void {
    const rand = w.crt();
    const attacker = &self.fighters.items[who];
    const t = &self.fighters.items[v];
    const cls = wpn.getInt("classType");
    const wc = WeaponClass.from(cls);
    const missed = st.missed;
    const dmg = st.dmg;
    if (missed) {
        try battle.popup(self, t.*, w.stringOr(520, "Miss"), .miss);
        // Miss (0x4cf392): miss01 or miss02 12 ticks later.
        try w.out.delayed_sounds.append(w.gpa, .{ .name = if (rand.below(2) != 0) "miss01" else "miss02", .pos = w.screenPos(t.obj), .ticks = 12 });
        return;
    }
    // Obstacle (+0xcc): boxes are invulnerable; a barrel explodes from fire (1),
    // bullets (6), energy (11), blasts (13), another barrel (17) and bombs (9).
    if (t.side == .neutral) {
        t.last_attacker = who;
        const ty = immunity.DamageType.from(wpn.getInt("type"));
        if (t.explosive and (ty == .fire or ty == .bullet or ty == .energy or ty == .explosion or wc == .barrel or wc == .time_bomb)) try devices.destroyBarrel(self, w, v);
        return;
    }
    // Stinger's ball (class 1005, +0xdc 0x4d87a0): the target's +0xcc isn't called,
    // no damage, no reaction, only sleep (0x4900f0, 6).
    if (wc == .stinger_long) {
        t.last_attacker = who;
        if (t.alive()) states.applyEffect(self, w, t, .sleep);
        return;
    }
    // Ion rifle and blaster (+0xdc 0x4b84f0, 0x4b8a40): with resistance to code 4
    // (0x4caa80) the target's +0xcc isn't called, whatever the damage kind.
    if ((wc == .ion_rifle or wc == .blaster) and states.resistsDiscover(self, w, t.*, .energy)) return;
    const armor = [3]i32{ wpn.getInt("lightArmor"), wpn.getInt("mediumArmor"), wpn.getInt("heavyArmor") };
    // Hero armour is the larger of its own and the worn one (0x49125f); a monster's
    // is the class from the resistance table or its own variable (0x4912a1).
    var own_armor = t.obj.getInt("armor");
    if (t.side == .hero) if (inventory.equipment.armorItem(w, t.obj)) |it| {
        own_armor = @max(own_armor, it.getInt("armor"));
    };
    if (t.side != .hero) if (w.immunity.armorClass(fields.nameId(t.obj))) |c| {
        own_armor = @max(own_armor, c);
        // The armour class is revealed on the first hit (0x4caaf7: string.tab 570 + class).
        if (w.immunity.discover(fields.nameId(t.obj), .armor)) {
            const cls_i: usize = @intCast(std.math.clamp(c, 0, 2));
            battle.popup(self, t.*, w.stringOr(571 + @as(i32, @intCast(cls_i)), immunity.armor_text[cls_i]), .info) catch {};
        }
    };
    // Puppet (+0xcc 0x4e1bb0): from the front and sides (angle to the attacker under
    // 0.7125π from its gaze) damage /10, at least 4, before 0x490f10, i.e. before the
    // side bonus, armour and defence; from behind, full.
    var base: i32 = @max(0, dmg);
    if (Class.of(t.obj) == .puppet) {
        const want = fields.facing(fields.pos(attacker.obj)[0] - fields.pos(t.obj)[0], fields.pos(attacker.obj)[1] - fields.pos(t.obj)[1]);
        if (@abs(fields.angleDiff(want, fields.angle(t.obj))) < 0.7125 * std.math.pi) base = @max(@divTrunc(dmg, 10), 4);
    }
    // Side / back strike (0x490f10): +2 / +4 damage before armour.
    const side_bonus = sideBonus(attacker.*, t.*, base);
    base += side_bonus;
    var d = rules.afterArmor(base, t.side == .hero, own_armor, armor);
    // Resistance to the damage kind (0x491056…): 0x490f10 returns 0, no damage, no
    // popup, no reaction (0x490eb9 → 0x490ee4).
    var immune = false;
    if (immunity.damageCode(.from(wpn.getInt("type")))) |code| if (states.resistsDiscover(self, w, t.*, code)) {
        d = 0;
        immune = true;
    };
    // Defending: damage ×0.5, frozen: ×1.5 (0x49132c, 0x49134b).
    if (t.defending) d = value.scaleInt(d, 0.5);
    if (t.frozen > 0) d = value.scaleInt(d, 1.5);
    // Monitors (class 5, +0xcc = 0x4bcff0): only damage 0x490f10, without the last
    // attacker (+0x24aec), reaction (0x491920, which includes the shocker's
    // "current") and blood (0x491510).
    const monitor = Class.of(t.obj) == .monitor;
    if (!monitor) t.last_attacker = who;
    const hp_before = @max(0, t.hp());
    // Damage popup (0x492170) only for non-zero damage (0x491366); a hit fully
    // absorbed by armour has no popup but still a reaction (0x491920).
    if (d != 0) {
        try hurtBonus(self, w, v, d, side_bonus);
    } else if (!immune and !monitor and t.alive()) {
        const ta = world.actorOf(t.*.obj);
        ta.play(ta.resolve("hit"), false, true);
    }
    // Reaction by weapon nameID (0x491c76): shocker and dischargers (0x491c91: 52,
    // 55, 92) put "current" on the fighter for attack_shocker_shocked_timeout (30)
    // ticks; the flare gun (0x491e5e: 46) gives sparks.
    if (!monitor) switch (fields.nameId(wpn)) {
        52, 55, 92 => if (t.alive()) world.actorOf(t.*.obj).shock(),
        46 => if (t.alive()) fx.blood.flare(w, t.obj, attacker.obj),
        else => {},
    };
    // The Judge's child heals the Judge by the damage dealt (0x4dd010).
    if (Class.of(attacker.obj) == .judge_child and d > 0) healJudge(self, w, hp_before - @max(0, t.hp()));
    // Blood and red flash (0x491510) when the strike strength before armour is > 0
    // (0x490ed6) and not resisted.
    if (!immune and !monitor and base > 0) {
        fx.blood.onDamage(w, t.obj, attacker.obj);
        if (self.last_hit == null) self.last_hit = v;
    }
    // Exp (0x4cf3b1): 1.75 × health removed, plus 0.2 × max_hp for a kill. The exe
    // (0x4cf3b1) doesn't check the target's side. The kill bonus and the report line
    // (0x48fd40) only if the target's +0xd8 is non-zero (0x4cf433): 0 for heroes,
    // monitors and Lamar (0x492420) and for `movable` / `explosive` obstacles (0x48e7f0).
    if (attacker.side == .hero) {
        const lost = hp_before - @max(0, t.hp());
        attacker.pending_exp += value.scaleInt(lost, 1.75);
        if (t.dead and killCredit(t.*)) {
            attacker.pending_exp += value.scaleInt(fields.maxHp(t.obj), 0.2);
            attacker.addKill(fields.nameId(t.obj));
        }
    }
    // Weapon effect on a live target (subclass methods +0xf0).
    if (t.alive()) {
        // Nitrogen gun (+0xdc 0x4bbcb0): fire is put out (+0x248dc = 0) before the cold
        // resistance check, resistant targets included.
        if (wc == .nitrogen) t.burning = 0;
        if (rules.weaponEffect(cls)) |k| states.applyEffect(self, w, t, k);
        if (t.soaked > 0 and rules.ignitesSoaked(cls)) {
            t.soaked = 0;
            states.applyEffect(self, w, t, .burn);
        }
    }
    // Counter-attack roll (0x491444–0x4914d0), only for non-zero damage (0x491366): a
    // hero hit on the enemy turn ([0x6c4ee8]), weapon in hand (+0x3250, vfunc +0x6c; not
    // from the exclusion list), no attackLock, not frozen or asleep (0x48f990);
    // `rand() % 1000 ≤ counterAttack × 10`. No alive check: a killed hero still draws
    // (startCounter skips the dead). An empty hand or a non-weapon never rolls.
    const hand = if (t.side == .hero) inventory.equipment.equipped(w, t.obj, .hand) else null;
    const hand_ok = if (hand) |h| switch (fields.nameId(h)) {
        1031, 33, 45, 1025, 52, 34, 55 => false,
        else => World.nativeOf(h).kind == .weapon,
    } else false;
    if (d != 0 and self.phase == .enemy and t.side == .hero and attacker.side == .enemy and
        t.obj.getInt("attackLock") == 0 and hand_ok and t.frozen == 0 and t.asleep == 0)
    {
        const ca = floatToInt(fields.getF(t.obj, "counterAttack") * 10);
        if (@as(i32, @intCast(rand.below(1000))) <= ca) t.counter = true;
    }
}

fn awardExp(self: *Battle, w: *World, f: *Fighter) !void {
    const gain = f.pending_exp;
    battle.note(self, "  {s}: +{d} exp", .{ f.obj.name, gain });
    f.exp_gained += gain;
    f.pending_exp = 0;
    // "N exp" (string 578) over the hero 40 ticks later (0x4cf4e5).
    var buf: [32]u8 = undefined;
    try battle.popup(self, f.*, std.fmt.bufPrint(&buf, "{d} {s}", .{ gain, w.stringOr(578, "exp") }) catch "exp", .exp);
    const exp = fields.experience(f.obj) + gain;
    fields.setExperience(f.obj, exp);
    var level = f.obj.getInt("level");
    var points: i32 = 0;
    while (exp > rules.levelThreshold(level) and level < 19) {
        level += 1;
        points += 5;
    }
    if (points > 0) {
        f.obj.setInt("level", level);
        World.nativeOf(f.obj).growth.stat_points += points;
        try battle.popup(self, f.*, w.stringOr(524, "Level up"), .level);
        battle.note(self, "  {s}: level {d}, points {d}", .{ f.obj.name, level, World.nativeOf(f.obj).growth.stat_points });
    }
}

fn healJudge(self: *Battle, w: *World, dealt: i32) void {
    _ = w;
    if (dealt <= 0) return;
    for (self.fighters.items) |*j| {
        if (!j.alive() or !std.ascii.eqlIgnoreCase(j.obj.name, "01_judge")) continue;
        const add = @min(dealt, fields.maxHp(j.obj) - j.hp());
        if (add <= 0) return;
        fields.setHp(j.obj, j.hp() + add);
        var buf: [16]u8 = undefined;
        battle.popup(self, j.*, std.fmt.bufPrint(&buf, "{d}", .{add}) catch "", .heal) catch {};
        return;
    }
}

const PopupText = struct { text: []const u8, heal: bool };

/// Damage popup text (0x492170). Without a bonus, "N" in the damage colour. With a
/// bonus the argument is bonus − damage: below 0, damage colour and
/// "(damage−bonus)+bonus"; otherwise (armour ate more than the bonus) the exe uses the heal colour and "(bonus−damage)+bonus".
fn popupText(buf: []u8, dmg: i32, bonus: i32) PopupText {
    if (bonus <= 0) return .{ .text = std.fmt.bufPrint(buf, "{d}", .{@abs(dmg)}) catch "", .heal = false };
    const v = bonus - dmg;
    return .{ .text = std.fmt.bufPrint(buf, "{d}+{d}", .{ @abs(v), bonus }) catch "", .heal = v >= 0 };
}

/// Side or back bonus (0x490f10, 0x490f3d…0x491042). Only with an attacker and
/// damage before armour > 0, not for monitors (classType 5). The angle to the
/// attacker atan2(dy, dx) vs the target's current angle +0x2457c, difference mod
/// 2π reduced to [0, π]: at least 0.7125π (0x50a230) back, +4; at least 0.2375π
/// (0x50a228) side, +2; else front, 0.
fn sideBonus(attacker: Fighter, t: Fighter, base: i32) i32 {
    if (base <= 0 or Class.of(t.obj) == .monitor) return 0;
    const ap = fields.pos(attacker.obj);
    const tp = fields.pos(t.obj);
    return rules.sideBonus(fields.facing(ap[0] - tp[0], ap[1] - tp[1]), fields.angle(t.obj));
}

pub fn hurt(self: *Battle, w: *World, v: u16, dmg: i32) !void {
    return hurtBonus(self, w, v, dmg, 0);
}

/// Damage with popup 0x492170(bonus − damage, bonus): with a side or back bonus
/// (> 0), "N+M" (0x529080), N the damage without the bonus, M the bonus.
fn hurtBonus(self: *Battle, w: *World, v: u16, dmg: i32, bonus: i32) !void {
    const t = &self.fighters.items[v];
    // Obstacles take no damage; a burning barrel explodes.
    if (t.side == .neutral) {
        if (t.explosive and dmg > 0) try devices.destroyBarrel(self, w, v);
        return;
    }
    var buf: [24]u8 = undefined;
    const text = popupText(&buf, dmg, bonus);
    try battle.popup(self, t.*, text.text, if (text.heal) .heal else .damage);
    if (dmg <= 0) return;
    if (w.debug.god and t.side == .hero) return;
    fields.setHp(t.obj, t.hp() - dmg);
    // Rage (0x49140c): every hit accumulates rage up to max_rage.
    if (t.obj.getInt("max_rage") > 0) {
        const r = t.obj.getInt("rage") + 1;
        if (r >= t.obj.getInt("max_rage")) {
            t.berserk = 1; // 0x491434
            t.obj.setInt("rage", 0);
        } else t.obj.setInt("rage", r);
    }
    const a = world.actorOf(t.*.obj);
    battle.note(self, "  {s}: -{d} (label {s}), left {d}", .{ t.obj.name, dmg, text.text, t.hp() });
    if (t.hp() <= 0) {
        battle.note(self, "  {s} dies", .{t.obj.name});
        t.dead = true;
        self.grid().remove(t.tile, t.size);
        a.play(a.resolve("death"), false, true);
        a.hold_last = true;
        a.startCorpseFade();
        // Grandma's child dies (0x4e08d0): her target is whoever hit it last. Burning
        // and gas (0x4903d0) strike without an attacker (0x490e9a), so after a death by
        // fire it's the one who set it alight; walked into fire on its own, nobody.
        if (Class.of(t.obj) == .grandma_child) for (self.fighters.items) |*g| {
            if (std.ascii.eqlIgnoreCase(g.obj.name, "grandma")) g.grandma_target = t.last_attacker;
        };
        if (t.side == .enemy) if (w.level) |l| l.setInt("killedEnemies", l.getInt("killedEnemies") + 1);
    } else if (Class.of(t.obj) != .monitor) {
        // Hit reaction (0x491920); monitors have none (0x4bcff0).
        a.play(a.resolve("hit"), false, true);
    }
}

// ---------------------------------------------------------------- enemies

/// Fighter +0xd8: whether the kill counts. For an ordinary fighter (0x48e7f0), if
/// it is neither `movable` nor `explosive`; for heroes (0x492340, vtable 0x50a244:
/// heroes and the `.hro` ally), monitors (classType 5) and ally Lamar (19)
/// 0x492420 = 0. Enemy Lamar in 05__lab_lamare (`.ftr`, classType −5) is ordinary: it counts.
fn killCredit(t: Fighter) bool {
    if (t.side == .hero) return false;
    switch (Class.of(t.obj)) {
        .hero, .hero3, .hero4, .monitor, .lamare => return false,
        else => {},
    }
    return !t.movable and !t.explosive;
}

test "damage popup with a side bonus: N+M, as 0x492170" {
    var buf: [24]u8 = undefined;
    const plain = popupText(&buf, 7, 0);
    try std.testing.expectEqualStrings("7", plain.text);
    try std.testing.expect(!plain.heal);
    const back = popupText(&buf, 10, 4);
    try std.testing.expectEqualStrings("6+4", back.text);
    try std.testing.expect(!back.heal);
    // Armour ate more than the bonus: the exe uses the heal colour.
    const eaten = popupText(&buf, 3, 4);
    try std.testing.expectEqualStrings("1+4", eaten.text);
    try std.testing.expect(eaten.heal);
}

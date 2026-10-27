//! Attack visuals at the hit (callback 0x4863c0): muzzle flashes, smoke, beams, streams,
//! special monster attacks and weapon sounds.

const std = @import("std");
const weapon_class = @import("../battle.zig").weapon_class;
const vec = @import("../vec.zig");
const fields = @import("../fields.zig");
const World = @import("../state.zig").world.World;
const Object = @import("../script.zig").object.Object;
const effects = @import("../effects.zig");
const grid = @import("../battle.zig").grid;
const generic = @import("../battle.zig").generic;
const camera = @import("../actor.zig").camera;
const place = @import("place.zig");
const explosion = @import("explosion.zig");
// Values named after adjust.kdt globals are read from it (shipped values as the fallback).
const adjust = @import("../formats.zig").adjust;
const F = adjust.getFloat;

fn T(name: []const u8, d: i32) u32 {
    return @intCast(@max(0, adjust.getInt(name, d)));
}

/// Muzzle flash (kind 1, chaingun.msh + chaingun.dsc, 0x48bda2) by weapon nameID.
const Flash = struct { link: []const u8, offset: [3]f32, scale: f32 = 0.5, ticks: u32 = 5, effect: []const u8 = "chaingun", rot: [9]f32 = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 } };

/// Pistol flash rotation (0x482010): Rx(−0.3)·Ry(−0.6)·Rz(−2.1).
fn pistolRot() [9]f32 {
    return camera.rotationXYZ(.{ -0.3, -0.6, -2.1 });
}

/// Flash rotation (chaingun 0x48ca21…0x48cb0b; rifle and shotgun only Ry):
/// Rz(z)·Ry(y), exe row-major matrices (as in rotationXYZ), product 0x47cd30(out, Rz, Ry).
fn zyRot(z: f32, y: f32) [9]f32 {
    const cz = @cos(z);
    const sz = @sin(z);
    const cy = @cos(y);
    const sy = @sin(y);
    const rz = [9]f32{ cz, -sz, 0, sz, cz, 0, 0, 0, 1 };
    const ry = [9]f32{ cy, 0, -sy, 0, 1, 0, sy, 0, cy };
    var o: [9]f32 = undefined;
    for (0..3) |i| for (0..3) |j| {
        o[i * 3 + j] = rz[i * 3] * ry[j] + rz[i * 3 + 1] * ry[3 + j] + rz[i * 3 + 2] * ry[6 + j];
    };
    return o;
}

/// Medusa beam mesh rotation: Rz(π)·Rx(π/2) (0x47cd30, row-major, like zyRot).
const medusa_beam_rot = [9]f32{ -1, 0, 0, 0, 0, 1, 0, 1, 0 };

pub fn flashFor(weapon: i32, attacker: i32) ?Flash {
    return switch (weapon) {
        // Pistol and revolver (revolver x ×1.5), rifle, shotgun, chaingun.
        49 => .{ .link = "one_hand", .offset = .{ -30, -40, 50 }, .rot = pistolRot() },
        50 => .{ .link = "one_hand", .offset = .{ -45, -40, 50 }, .rot = pistolRot() },
        // Rifle (0x48c6fa) and shotgun (0x48cc06): rotation Ry(−0.2) and Ry(−0.1).
        98 => .{ .link = "two_hands", .offset = .{ 150, 10, -40 }, .rot = zyRot(0, -0.2) },
        1023 => .{ .link = "two_hands", .offset = .{ 140, 17, -20 }, .rot = zyRot(0, -0.1) },
        // Chaingun (uzi, 0x48c8b5): on two_hands, attack_chaingun_flash_disp (−8, −40,
        // 44), rotation Rz(−1.82)·Ry(0.3); Slavsky (26) uses (7, −21, −35),
        // Rz(−0.32)·Ry(−0.2). Without the rotation the flash pointed back into the chest.
        1022 => if (attacker == 26)
            .{ .link = "two_hands", .offset = .{ 7, -21, -35 }, .ticks = 80, .rot = zyRot(-0.32, -0.2) }
        else
            .{ .link = "two_hands", .offset = .{ -8, -40, 44 }, .ticks = 80, .rot = zyRot(-1.82, 0.3) },
        // Nitrogen gun: "nitro" for 80 ticks (nitro_timeout).
        // Rotation Ry(π − 0.1) (0x48ce33…0x48cebe): the mesh points backwards, so the jet
        // goes from point attack_nitro_disp to the barrel, not further away.
        1025 => .{ .link = "two_hands", .offset = .{ 490, 20, -50 }, .scale = 1, .ticks = 80, .effect = "nitro", .rot = zyRot(0, std.math.pi - 0.1) },
        else => null,
    };
}

/// Floor direction from `from` to `to`; if equal, forward by the actor's angle.
fn dirTo(who: *Object, from: [3]f32, to: [3]f32) [2]f32 {
    const d = [2]f32{ to[0] - from[0], to[1] - from[1] };
    const l = @sqrt(d[0] * d[0] + d[1] * d[1]);
    return if (l > 0) .{ d[0] / l, d[1] / l } else place.forward(who);
}

/// Muzzle light colour (shot_light_color 255,128,64).
fn shotColor() [3]f32 {
    const c = adjust.getRgb("shot_light_color", .{ 255, 128, 64 });
    return .{ @as(f32, @floatFromInt(c[0])) / 255.0, @as(f32, @floatFromInt(c[1])) / 255.0, @as(f32, @floatFromInt(c[2])) / 255.0 };
}

/// Muzzle light (kind 6, 0x4885fc): in front of the actor at shot_light_displacement
/// (200)·aS, at height shot_light_level (400)·aS, range 350, 3 ticks.
fn shotLight(w: *World, who: *Object) void {
    w.effects.addLight(w.gpa, .{ .pos = place.offsetPoint(who, w.actorScale(), .{ F("shot_light_displacement", 200), 0, F("shot_light_level", 400) }), .color = shotColor(), .range = 350, .left = 3 });
}

/// Point at the barrel (callback 11, 0x4863c0): position + aS·(10 right, 220 forward, 530 up).
fn muzzle(o: *Object, as: f32) [3]f32 {
    return place.offsetPoint(o, as, .{ 220, 10, 530 });
}

/// Strike of `who` with weapon `wpn` at point `target` (aim tile centre on the floor).
/// `second`: second hit of a series (Headnail's right saw).
pub fn onHit(w: *World, who: *Object, wpn: *Object, target: [3]f32, second: bool) void {
    onHitAs(w, who, generic.fxId(wpn), target, second);
}

/// Same by weapon nameID.
pub fn onHitAs(w: *World, who: *Object, id: i32, target: [3]f32, second: bool) void {
    const e = &w.effects;
    const gpa = w.gpa;
    const as = w.actorScale();
    // Monster shot (branches 0x48d618): flash "chaingun" on its own point (0x427ce0)
    // at the shot, and the shot is callback 11 or 50 (0x486ae6, 0x486bf1): smoke2
    // puff at the barrel (attack_dartgun_*: 10 right, 220 forward, 530 up;
    // attack_dartgun_smoke_scale 200), the hit and the muzzle light (0x486794).
    if (monsterShot(id)) |sh| {
        e.attach(gpa, .{ .actor = who, .effect = "chaingun", .link = sh.link, .offset = .{ 0, 0, 0 }, .scale = 0.5, .start = 0, .left = sh.ticks });
        explosion.bitmap(w, .{ .effect = "smoke2", .pos = muzzle(who, as), .size = F("attack_dartgun_smoke_scale", 200), .step = 1 });
        shotLight(w, who);
    }
    // Special monster attacks (0x48d618): Medusa's mouth gas, Headnail's saw sparks,
    // Reverend Insect's "nitro", Schizo's gas cloud on the target.
    switch (fields.nameId(who)) {
        // Medusa (0x48a465): weapon 1021 is the mouth gas, otherwise current (0x4a3960).
        119 => if (id == 1021) {
            // Mouth beam (0x48a498…0x48a615): chaingun mesh with the gas texture on
            // "paszcza", offset attack_medusa_s_disp (700, 40, −10), scale 2, rotation
            // 0x47cd30(Rz(π), Rx(π/2)), lasts attack_medusa_s_timeout 72.
            e.attach(gpa, .{ .actor = who, .effect = "gas", .link = "paszcza", .offset = .{ 700, 40, -10 }, .rot = medusa_beam_rot, .scale = 2, .start = 0, .left = T("attack_medusa_s_timeout", 72) });
        } else current(w, who),
        // Guard (0x48afae): weapon 1063 fires eye lasers before the hit (preFlash, code
        // 0x23); with damage (code 0x24 → 0x48809c) smoke2 200 on the target + 120·aS.
        131 => if (id == 1063) {
            explosion.bitmap(w, .{ .effect = "smoke2", .pos = .{ target[0], target[1], target[2] + 120 * as }, .size = 200, .step = 1 });
        },
        // Headnail (0x48a8c9, 0x48aab9): sparks on the left saw on the first hit, on the
        // right on the second. Command 0x20 (0x427ce0): offset (549, 137, 0) left and
        // (575, 112, 0) right, rotation 0x47cd30(Rx(π/2), Rz(π)) like the Medusa beam,
        // scale 2; removed by the same command without an effect attack_headnail_delay4
        // / delay6 (5) after the hit (0x48a976, 0x48ab78).
        118 => e.attach(gpa, .{ .actor = who, .effect = "sparks", .link = if (second) "pila prawa" else "pila lewa", .offset = if (second) .{ 575, 112, 0 } else .{ 549, 137, 0 }, .rot = medusa_beam_rot, .scale = 2, .start = 0, .left = T("attack_headnail_delay4", 5) }),
        // Reverend Insect (0x48ab82): the "nitro" jet comes before the hit (preFlash);
        // here the freezer (kind 24, 0x49f670): weapons\zamrazacz sound at the target.
        126 => w.out.delayed_sounds.append(gpa, .{ .name = "weapons\\zamrazacz", .pos = w.screenPos(who), .ticks = 20 }) catch {},
        // Schizo (0x48b914): cloud "gas2" on the target for 1078 (code 49 → 0x4aa360,
        // kind 49, 0x4a95d0), lasts while the tile has gas; bell gas before the hit
        // (preFlash). 1077 and 1079 have no own effects.
        136 => if (id == 1078) {
            e.clouds.append(gpa, .{ .pos = .{ target[0], target[1], target[2] + 130 * as }, .size = 1.3 * 600 }) catch {};
            // Cloud constructor (0x4a9685): (rand() % 10) · 0.1 into +0x2f8, shared stream.
            _ = w.crt().next();
        },
        // Pain God (kind 30, callback 0x1e 0x487bd1 → 0x4a1430 → class 0x4a0900, table
        // 0x50a938, tick 0x4a0bf0, draw 0x4a0fb0): from pos + aS·(80 right, 600 up)
        // (attack_paingod_x_disp, _start_level) to the target; a particle at 250·aS along
        // the direction (+0xab8), speed attack_flame_pg_speed (35)·aS, one per tick
        // (attack_flame_pg_int 1) for 30 ticks (+0xaa8), at most 70, life
        // attack_flame_pg_life (10); light (1, 0.3, 0.3) at 600·aS along the direction
        // (0x50a934), range 700·aS (0x50a86c) while the stream runs. Target is the tile
        // centre + 300·aS (0x4863c0, [0x508760]).
        121 => {
            const src = place.offsetPoint(who, as, .{ 0, F("attack_paingod_x_disp", 80), 600 });
            _ = flameStream(w, src, target, 250, .{ .timer = 31, .max = 70, .life = T("attack_flame_pg_life", 10), .aim_z = 300, .speed = F("attack_flame_pg_speed", 35) });
            const d = vec.normalize(.{ target[0] - src[0], target[1] - src[1], target[2] + 300 * as - src[2] });
            e.addLight(gpa, .{ .pos = .{ src[0] + d[0] * 600 * as, src[1] + d[1] * 600 * as, src[2] + d[2] * 600 * as }, .color = .{ 1, 0.3, 0.3 }, .range = 700 * as, .left = 30 });
        },
        // Stinger (127): melee (weapon 1071) is a flame jet (kind 43, 0x4a06f0) from
        // model point t1 toward t2, forward by attack_stinger_d (30)·aS. Its time shift
        // ftol(attack_stinger_dtime) (−55, 0x487cb9) goes into both the object timer
        // (attack_flame_time + shift = 35) and the particle limit (attack_flame_tab +
        // shift = 19, at most 180; 0x4a0764…0x4a0789).
        127 => if (id == 1071) {
            const dt: i32 = @intFromFloat(F("attack_stinger_dtime", -55));
            const timer = @as(i32, @intCast(T("attack_flame_time", 90))) + dt;
            const max: u32 = @intCast(std.math.clamp(@as(i32, @intCast(T("attack_flame_tab", 74))) + dt, 0, 180));
            if (flameStream(w, place.offsetPoint(who, as, .{ 0, 0, 360 }), target, F("attack_stinger_d", 30), .{ .timer = timer, .max = max })) |fl| {
                fl.actor = who;
                fl.link = "t1";
                fl.link2 = "t2";
            }
        },
        // Squeaker (kind 27, 0x4205a0): screen shake attack_sq_life = 30.
        133 => w.out.earthquake = T("attack_sq_life", 30),
        else => {},
    }
    onHitId(w, who, id, target);
}

/// Monster muzzle flash by weapon nameID: link point and duration (between the
/// two 0x427ce0 calls in branch 0x4896b0).
const MonsterShot = struct { link: []const u8, ticks: u32 };

fn monsterShot(wpn_id: i32) ?MonsterShot {
    return switch (wpn_id) {
        // Fatman (1076, 0x48aed0) and Lucy (1058, 0x48ad0f): attack_rifle_flash_timeout 5.
        1076, 1058 => .{ .link = "chaingun", .ticks = T("attack_rifle_flash_timeout", 5) },
        // Cripple (0x48b12c): on "chaingun1", 5 ticks.
        1065 => .{ .link = "chaingun1", .ticks = 5 },
        // Puppet (0x48b50a): attack_puppet_l_timeout 16.
        1068 => .{ .link = "chaingun", .ticks = T("attack_puppet_l_timeout", 16) },
        // Schizo, attack_3 (0x48bb5f): until attack_schizo_r_delay2 (35) ends.
        1079 => .{ .link = "chaingun", .ticks = T("attack_schizo_r_delay2", 35) },
        else => null,
    };
}

/// Flash before the hit (MonsterAttack.pre): Garcia (67, 0x489823…0x489881),
/// "chaingun" and state 1 (barrel light, 0x496e1a) at garcia_attack_long_delay1
/// (41), removed delay2 + delay3 (10 + 20) later; Schizo (1078, 0x48b9df…0x48baba),
/// gas "gas3" from the bell "dmuchawa" (attack_schizo_g_disp 460, scale g_scale
/// 1.5) at g_delay (78) until g_delay2 + g_delay3 (98 + 30); the hero's ion rifle
/// beam and blaster stream come before the damage (HeroAttack.pre).
pub fn preFlash(w: *World, who: *Object, wpn_id: i32, target: [3]f32) void {
    const e = &w.effects;
    const gpa = w.gpa;
    const as = w.actorScale();
    const hi = [3]f32{ target[0], target[1], target[2] + 250 * as };
    // Reverend Insect (branch 26 of table 0x48d618, no weapon check): after
    // attack_revinsect_delay (45), "nitro" on the chaingun point with offset (320, 0,
    // 0) (0x43a00000) and rotation Ry(π) (0x48aba1…0x48ac43: cos π, 0, −sin π; 0, 1,
    // 0; sin π, 0, cos π): jet from the point to the barrel, like the hero's nitrogen
    // gun; the hit (freezer, code 24) delay2 (20) later, the jet removed delay3 (64)
    // after it (0x48b5e3…0x48b604).
    if (fields.nameId(who) == 126) {
        e.attach(gpa, .{ .actor = who, .effect = "nitro", .link = "chaingun", .offset = .{ 320, 0, 0 }, .rot = zyRot(0, std.math.pi), .scale = 1, .start = 0, .left = 20 + 64 });
        return;
    }
    // Guard, 1063 (code 0x23 → 0x488025, 0x4a5580): "ray" lasers from eyes oko1/oko2
    // to the target + 120·aS (attack_laser_life 54, attack_laser_scale 50), no
    // damage; the hit (code 0x24) 5 ticks later.
    if (fields.nameId(who) == 131 and wpn_id == 1063) {
        const to = [3]f32{ target[0], target[1], target[2] + 120 * as };
        for ([_][]const u8{ "oko1", "oko2" }) |l|
            e.beams.append(gpa, .{ .kind = .laser, .effect = "ray", .from = to, .to = to, .size = F("attack_laser_scale", 50), .left = T("attack_laser_life", 54), .actor = who, .link = l }) catch {};
        return;
    }
    switch (wpn_id) {
        // Ion rifle (0x4a1600): "ion" ribbon from the hands along the barrel turned by
        // −0.09 rad (0.4 for Slavsky), 27 ticks, half-width attack_ion_size 30.
        1029 => {
            const d = dirTo(who, muzzle(who, as), hi);
            const a: f32 = if (fields.nameId(who) == 26) 0.4 else -0.09;
            const dir = [3]f32{ d[0] * @cos(a) - d[1] * @sin(a), d[0] * @sin(a) + d[1] * @cos(a), 0 };
            // Beam height is the barrel level: pos.z + attack_ion_start_level (465)·aS
            // (callback 0x1a, 0x487a69), not the target's height.
            // Start is the actor's centre (0x487a69: pos, no shift to the barrel); the beam
            // is drawn from 155·aS forward (attack_ion_vs −155 against the direction to the actor).
            const pp = fields.pos(who);
            // Each frame (0x4a18d0) start and axis come from the two_hands point (0x429ca0):
            // the beam leaves the rifle's ends and sways with it; here, a fallback without a model.
            e.beams.append(gpa, .{ .kind = .ion, .effect = "ion", .from = .{ pp[0], pp[1], pp[2] + F("attack_ion_start_level", 465) * as }, .to = hi, .size = F("attack_ion_size", 30), .left = T("attack_ion_life", 27), .dir = dir, .turn = a, .actor = who, .link = "two_hands" }) catch {};
        },
        // Blaster (0x4a37c0): a "blaster" stream to each fighter on the strike's hit
        // tiles (weapon +0xe8 = 0x4cebe0: +0x108 → the set's tiles, fighters there once
        // each: enemies, allies, boxes), to pos + (0, 0, 300·aS) (0x4a3876: aS·300,
        // [0x51e24c]·[0x508760]). No fighters, no streams.
        1037 => {
            // Start (callback 0x1c, 0x487aee): the actor's centre at height
            // attack_blaster_start_level (450)·aS, moved toward the target by
            // attack_blaster_r (120)·aS: at the barrel, not above it.
            const pp = fields.pos(who);
            const fd = dirTo(who, pp, hi);
            const r = F("attack_blaster_r", 120);
            const m = [3]f32{ pp[0] + fd[0] * r * as, pp[1] + fd[1] * r * as, pp[2] + F("attack_blaster_start_level", 450) * as };
            const b = &(w.battle orelse return);
            const at = switch (b.pending) {
                .attack => |a| a,
                else => return,
            };
            const pat = weapon_class.pattern(at.weapon) orelse return;
            const g = b.grid();
            var tiles: [128]grid.Tile = undefined;
            var seen: [128]u16 = undefined;
            var n: usize = 0;
            for (grid.effectTiles(g, pat, at.aim, &tiles)) |t| {
                const k = g.at(t);
                if (k == grid.Grid.none) continue;
                if (std.mem.indexOfScalar(u16, seen[0..n], k) != null) continue;
                seen[n] = k;
                n += 1;
                const p = fields.pos(b.fighters.items[k].obj);
                stream(w, m, .{ p[0], p[1], p[2] + 300 * as });
            }
        },
        67 => {
            e.attach(gpa, .{ .actor = who, .effect = "chaingun", .link = "chaingun", .offset = .{ 0, 0, 0 }, .scale = 0.5, .start = 0, .left = 30 });
            // Barrel light during the burst (state 1, 0x496e1a): offset (100 right, 200
            // forward)·aS, height 400·aS, range 1000.
            e.addLight(gpa, .{
                .pos = place.offsetPoint(who, as, .{ 200, 100, 400 }),
                .color = shotColor(),
                .range = 1000,
                .left = 30,
            });
        },
        // Matrix of command 0x20 (0x48b9e4…0x48ba67): Rz(π) from [0x50a000]; the mesh
        // nozzle is turned from the bell forward.
        1078 => e.attach(gpa, .{ .actor = who, .effect = "gas3", .link = "dmuchawa", .offset = .{ 460, 0, 0 }, .rot = .{ -1, 0, 0, 0, -1, 0, 0, 0, 1 }, .scale = 1.5, .start = 0, .left = 98 + 30 }),
        else => {},
    }
}

/// Hit effects by weapon nameID (monster flashes excluded).
pub fn onHitId(w: *World, who: *Object, id: i32, target: [3]f32) void {
    const e = &w.effects;
    const gpa = w.gpa;
    const as = w.actorScale();
    if (flashFor(id, fields.nameId(who))) |f| {
        shotLight(w, who);
        e.attach(gpa, .{ .actor = who, .effect = f.effect, .link = f.link, .offset = f.offset, .rot = f.rot, .scale = f.scale, .start = 0, .left = f.ticks });
        // Pistols: after the flash a smoke2 puff (size 200) at the barrel.
        if (id == 49 or id == 50 or id == 98 or id == 1023)
            explosion.bitmap(w, .{ .effect = "smoke2", .pos = muzzle(who, as), .size = F("attack_dartgun_smoke_scale", 200), .step = 1, .delay = f.ticks });
    }
    const hi = [3]f32{ target[0], target[1], target[2] + 250 * as };
    if (weaponSound(id)) |snd| {
        const q = w.cam.project(target);
        w.out.sound(gpa, snd, .{ q.x, q.y });
    }
    switch (id) {
        // Darts and the flare gun: puff at the barrel (callbacks 39, 12). The dartgun
        // (code 39, 0x48813f) also gets the muzzle light after the hit (0x4882c8 →
        // 0x486794), like the pistols (code 11).
        45 => {
            explosion.bitmap(w, .{ .effect = "smoke2", .pos = muzzle(who, as), .size = F("attack_dartgun_smoke_scale", 200), .step = 1 });
            shotLight(w, who);
        },
        // Ball: "KulaExpl" explosion (0x4d0780), no lift, no delay.
        1070, 1072 => explosion.bitmap(w, .{ .effect = "KulaExpl", .pos = hi, .size = 1000, .step = 0.5 }),
        // Grenade (0x49cc30): explosion 0x4d0610 at the landing point (floor) +
        // attack_grenade_exp (250)·aS, sound "granat". The Sister's brain (0x4a4b20) uses the same blast.
        1051, 35 => explosion.explosion(w, .{ target[0], target[1], target[2] + F("attack_grenade_exp", 250) * as }),
        // Rockets (0x49c720; launcher, Jet Elmer, Fang, Smoke Rider): explosion right at
        // the arrival point, the target, tile centre + 300·aS (0x48643d), sound "granat".
        57, 91, 1003, 1004, 1024 => explosion.explosion(w, .{ target[0], target[1], target[2] + 300 * as }),
        // Stun grenade: "stun" flash 900 (rate 0.2), 5 ticks later smoke1 600.
        33 => {
            explosion.bitmap(w, .{ .effect = "stun", .pos = hi, .size = 900, .step = 0, .alpha = 0, .flash_rate = 0.2 });
            explosion.bitmap(w, .{ .effect = "smoke1", .pos = hi, .size = 600, .step = 1, .delay = 5 });
        },
        // Gas grenade: green smoke1 600 (attack_gasgr_col 100,255,0).
        1027 => explosion.bitmap(w, .{ .effect = "smoke1", .pos = hi, .size = 600, .step = 1, .rgb = gasColor() }),
        // Molotov (0x49d7d0): "molotov" attack_molotov_scale 800 at the landing point +
        // 800·aS, step 0.5, colour (1, 0.9, 0.9). Vodka, petrol and stone use the bottle
        // class (0x49e7c0): only the bottle sound, no fire.
        86 => explosion.bitmap(w, .{ .effect = "molotov", .pos = .{ target[0], target[1], target[2] + 800 * as }, .size = F("attack_molotov_scale", 800), .step = 0.5, .rgb = .{ 1, 0.9, 0.9 } }),
        // Satellite energy beam (0x4a74a0): "beam" mesh at the target.
        1038 => e.spins.append(gpa, .{ .pos = target }) catch {},
        // Satellite lightning (0x4a7710): vertical strip "LStrike" above the target, 4
        // segments of 1400·aS, half-width 130, 8 ticks.
        1039 => e.beams.append(gpa, .{ .kind = .lightning, .effect = "LStrike", .from = target, .to = target, .size = 130, .left = 8, .div = 1 }) catch {},
        // Orbital rocket (0x4a8c70): explosion at the arrival point, target + 300·aS.
        1040 => explosion.explosion(w, .{ target[0], target[1], target[2] + 300 * as }),
        // Flamethrower (kind 25, 0x4a06f0 → tick 0x49fdc0): a point at the fighter at
        // height attack_flameth_start_level (360)·aS; each tick the direction points at
        // the two_hands point of the current animation frame, turned by −0.8 rad; a
        // particle at 250·aS along it, speed attack_flame_speed (35)·aS.
        1026 => {
            if (flameStream(w, place.offsetPoint(who, as, .{ 0, 0, F("attack_flameth_start_level", 360) }), target, 250, .{ .timer = @intCast(T("attack_flame_time", 90)), .max = T("attack_flame_tab", 74), .speed = F("attack_flame_speed", 35) })) |fl| {
                fl.actor = who;
                fl.link = "two_hands";
                fl.rot = -0.8;
                fl.ends_attack = true;
            }
        },
        // Flare gun: smoke at the barrel; sparks come in the target's reaction (fx.flare).
        46 => explosion.bitmap(w, .{ .effect = "smoke2", .pos = muzzle(who, as), .size = F("attack_dartgun_smoke_scale", 200), .step = 1 }),
        else => {},
    }
}

/// Blaster stream from `from` to `to` (0x4a28e0), 120 ticks.
fn stream(w: *World, from: [3]f32, to: [3]f32) void {
    const d = [3]f32{ to[0] - from[0], to[1] - from[1], to[2] - from[2] };
    const len = vec.len(d);
    if (len <= 0) return;
    w.effects.streams.append(w.gpa, .{
        .start = from,
        .v = .{ d[0] / len, d[1] / len, d[2] / len },
        .len = len,
        .as = w.actorScale(),
    }) catch {};
}

/// Medusa's current (0x4a44e0, also VOLTAGE): two "blaster" arcs current1→current3
/// and current2→current4, 45 ticks, half-width attack_luk_scale 300.
pub fn current(w: *World, who: *Object) void {
    w.effects.beams.append(w.gpa, .{ .kind = .current, .effect = "blaster", .from = .{ 0, 0, 0 }, .to = .{ 0, 0, 0 }, .size = F("attack_luk_scale", 300), .left = 45, .actor = who }) catch {};
}

/// Flame jet (0x4a06f0): from `src` to the target (+130·aS), start `ahead`·aS
/// along the direction, particle speed 35·aS, 16 ticks, 74 particles over 90 ticks.
/// Stream parameters: object timer, particle limit, particle life, aim point lift
/// above the target floor (in aS). Defaults are the flamethrower's
/// (attack_flame_time 90, attack_flame_tab 74, life 16).
const StreamOpt = struct { timer: i32 = 90, max: u32 = 74, life: u32 = 16, aim_z: f32 = 130, speed: f32 = 35 };

/// Returns the added stream (null if out of memory).
fn flameStream(w: *World, src: [3]f32, target: [3]f32, ahead: f32, o: StreamOpt) ?*effects.flame.Flame {
    const as = w.actorScale();
    const d = vec.normalize(.{ target[0] - src[0], target[1] - src[1], target[2] + o.aim_z * as - src[2] });
    const start = [3]f32{ src[0] + d[0] * ahead * as, src[1] + d[1] * ahead * as, src[2] + d[2] * ahead * as };
    w.effects.flames.append(w.gpa, .{
        .src = start,
        .dir = .{ d[0] * o.speed * as, d[1] * o.speed * as, d[2] * o.speed * as },
        .timer = o.timer,
        .max = o.max,
        .life = o.life,
        .base = src,
        .ahead = ahead * as,
        .speed = o.speed * as,
    }) catch return null;
    return &w.effects.flames.items[w.effects.flames.items.len - 1];
}

/// Gas grenade cloud colour (attack_gasgr_col 100,255,0).
fn gasColor() [3]f32 {
    const c = adjust.getRgb("attack_gasgr_col", .{ 100, 255, 0 });
    return .{ @as(f32, @floatFromInt(c[0])) / 255.0, @as(f32, @floatFromInt(c[1])) / 255.0, @as(f32, @floatFromInt(c[2])) / 255.0 };
}

/// Weapon sound on hit (0x4327f0 calls in weapon effects, 0x487afd…0x4a8e31).
fn weaponSound(id: i32) ?[]const u8 {
    return switch (id) {
        1037 => "weapons\\energy_blaster",
        1028 => "weapons\\napalm_launcher",
        1027 => "weapons\\gas_grenade",
        86 => "weapons\\molotov_expl",
        // Stone, vodka, petrol: the bottle class (0x49e7c0).
        41, 1030, 1032 => "weapons\\bottle",
        1025 => "weapons\\zamrazacz",
        1038 => "weapons\\satelite_laser",
        1039 => "weapons\\satelite_lighting",
        1040 => "weapons\\satelite_rocket",
        33 => "grenade_deaf",
        45 => "dartsgun",
        1070, 1072 => "kula_explo",
        else => null,
    };
}

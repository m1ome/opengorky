//! Weapon projectiles: launch points and per-weapon flight parameters.

const vec = @import("../vec.zig");
const fields = @import("../fields.zig");
const World = @import("../state.zig").world.World;
const Object = @import("../script.zig").object.Object;
const effects = @import("../effects.zig");
const generic = @import("../battle.zig").generic;
const place = @import("place.zig");

/// Weapon projectile (0x49b0a0, 0x49c840, choreography 0x48bda2): rocket,
/// grenades, bottles, knife, flare, napalm. 0 means the weapon has no projectile.
/// Battle speedScale = 0.02·xSize = 7·actorScale (0x4b49f0).
pub fn launch(w: *World, who: *Object, wpn: *Object, target_floor: [3]f32) u32 {
    return launchId(w, who, generic.fxId(wpn), target_floor, false);
}

/// Jet Elmer's second rocket (callback 2, 0x486599): from attack_jetelmer_rocket2_*.
pub fn launchSecond(w: *World, who: *Object, wpn: *Object, target_floor: [3]f32) u32 {
    return launchId(w, who, generic.fxId(wpn), target_floor, true);
}

pub fn launchId(w: *World, who: *Object, weapon_id: i32, target_floor: [3]f32, second: bool) u32 {
    const as = w.actorScale();
    const p = fields.pos(who);
    const start = place.offsetPoint(who, as, .{ 100, 0, 400 });
    const target = [3]f32{ target_floor[0], target_floor[1], target_floor[2] + 300 * as };
    var pr: effects.projectile.Projectile = .{ .pos = start, .start = start, .target = target, .speed_scale = 7 * as, .floor = target_floor[2] };
    // Hero projectile launch points (callbacks 0x4863c0): pos + aS·(x right, y
    // forward, z up), attack_*_x_disp, _y_disp, _start_level. Effects.launch sets
    // pos = start itself.
    if (heroLaunch(weapon_id)) |o| pr.start = place.offsetPoint(who, as, o);
    switch (weapon_id) {
        // Launcher: 7 → 15 (acceleration 0.7 after 10 ticks), "Rocket1" and exhaust
        // "Rocket", trail "Trail1" length 20, size 50.
        // attack_rocketl_scale 2 (+0x358, rocket and flame scale, 0x48790b).
        1024 => {
            pr = rocket(pr, 120);
            pr.mesh_scale = 2;
        },
        // Grenades, stun and gas: along an arc without spin (0x49e220, 0x49e2f0,
        // 0x49e3c0: +0x344 = 0; attack_grenade_scale 1).
        35 => pr = arc(pr, "grenade", 1, 0),
        33, 1027 => pr = arc(pr, "bomb_stun", 1, 0),
        // Molotov (0x49e8b0): flame and light behind the bottle (0x4321b0), range
        // 800·aS, colour (1, 0.3, 0.3); spin 0.2. Vodka, petrol, stone (0x49e7f0, meshes
        // vodka / butlagas / stone; the stone mesh is missing from the data, so invisible): spin 0.2.
        86 => {
            pr = arc(pr, "molotov", 1, 0.2);
            pr.flame = true;
            pr.light_range = 800 * as;
            pr.light_rgb = .{ 1, 0.3, 0.3 };
        },
        1032 => pr = arc(pr, "vodka", 1, 0.2),
        1030 => pr = arc(pr, "butlagas", 1, 0.2),
        41 => pr = arc(pr, "stone", 1, 0.2),
        // Napalm launcher (callback 0x2d, 0x488447…0x4884b1): from pos + aS·(70 forward,
        // 0 right, 300 up), attack_napalmth_y_disp / x_disp / start_level.
        1028 => {
            pr = arc(pr, "napalmcan", 0.4, 0.2);
            pr.start = place.offsetPoint(who, as, .{ 70, 0, 300 });
        },
        // Cutter Pill bullet (kind 13, 0x49e070 → 0x49dd70): from pos + aS·(400 forward,
        // −60 right, 500 up), speed 15 (attack_cutterpillbullet_speed), scale 0.6;
        // damage on arrival.
        89 => {
            pr.start = place.offsetPoint(who, as, .{ 400, -60, 500 });
            pr.speed = 15;
            pr.max_speed = 15;
            pr.effect = "arrows";
            pr.mesh_scale = 0.6;
            pr.bullet = true;
        },
        // Throwing knife: speed 15, scale 1.2, spin 0.6.
        40 => {
            pr.speed = 15;
            pr.max_speed = 15;
            pr.mesh = "knife_throwing";
            pr.mesh_scale = 1.2;
            pr.spin = 0.6;
        },
        // Incubus and Stinger ball (0x4a5840): "kula" and "poswiata" glow. Hangs at the
        // fighter for `hold` ticks, grows from 0.1 by attack_ball_ds (0.08) per tick to
        // scale ms, then flies at speed·aS (0x4a60f7). Incubus (code 42, 0x4a63d0):
        // attack_ball_life 88, speed 70, ms 0.8; Stinger (code 44, 0x4a6460):
        // attack_stinger_ball_life 70, speed 130, ms 1.
        1070, 1072 => {
            const sp: f32 = if (weapon_id == 1072) 130 else 70;
            const ms: f32 = if (weapon_id == 1072) 1 else 0.8;
            pr.speed = sp / 7;
            pr.max_speed = sp / 7;
            // No mesh drawn (vtable 0x50adf8 +0x50 is `ret`): only the glow billboards.
            pr.mesh_scale = ms;
            pr.effect = "kula";
            pr.ball = .{};
            pr.size = 130;
            pr.hold = if (weapon_id == 1072) 70 else 88;
            pr.k = 0.1 / ms;
            pr.grow = 0.08 / ms;
        },
        // Jet Elmer, Fang and Smoke Rider rockets (0x49d8d0): like the launcher's.
        57, 91, 1003, 1004 => {
            pr = rocket(pr, 160);
            // Own launch points (0x48736b and neighbouring branches): Fang 500 forward, −150
            // right, 360 up, scale 2; Jet Elmer (attack_jetelmer_rocket1_*) 100 forward, 100
            // right, 670 up; Smoke Rider (smokerider_attack_rocket1_*) 700 forward, 175 right,
            // 400 up, scale 2. Every 0x49d8d0 rocket uses rocket1_trail_* (size 50); the exe
            // only registers *_rocket_trail_* for Fang and Smoke Rider (0x4834f0…0x483a90).
            pr.start = place.offsetPoint(who, as, switch (weapon_id) {
                // Second rocket uses rocket2_*: x_disp −144 (right), y_disp 100.
                57 => if (second) .{ 100, -144, 670 } else .{ 100, 100, 670 },
                1003 => .{ 700, 175, 400 },
                // Smoke Rider, second kind (code 20, 0x487589):
                // smokerider_attack2_rocket1_*: 235 forward, −100 right, 900 up.
                1004 => .{ 235, -100, 900 },
                else => .{ 500, -150, 360 },
            });
            if (weapon_id != 57) pr.mesh_scale = 2;
        },
        // Grandma's poison (0x49eac0, 0x49efc0): chaingun mesh with the "trucizna"
        // texture ×attack_grandma_scale (1.3)·aS at pos − dir·240·aS (like the bullet,
        // 0x49ed60), speed 12, trail "Trail1" rocket1_trail_len 20 / size 50 coloured
        // attack_grandma_col (80, 255, 80). With grandma_mad_gun (1006) a spit via
        // command 0x16 (0x487729 → 0x49efc0) from attack_grandma_*: 550 forward, −55
        // right, 240 up (×aS).
        1005, 1006 => {
            if (weapon_id == 1006) pr.start = place.offsetPoint(who, as, .{ 550, -55, 240 });
            pr.speed = 12;
            pr.max_speed = 12;
            pr.effect = "trucizna";
            // Trail 0x49eac0/0x49efc0: rocket1_trail_* (length 20, size 50), colour
            // attack_grandma_col (80,255,80)/255, period 2, brightness ×0.8.
            pr.bullet = true;
            pr.mesh_scale = 1.3;
            pr.trail = "Trail1";
            pr.trail_len = 20;
            pr.trail_size = 50;
            pr.trail_rgb = .{ 80.0 / 255.0, 1, 80.0 / 255.0 };
        },
        // Sister of Mercy's brain (code 32, 0x487d11 → 0x4a4b50 → 0x4a4650): from pos +
        // aS·(390 forward, −30 right, 300 up) (attack_sister_y_disp, x_disp,
        // start_level), speed attack_brain_speed (80)·aS, brain mesh ×0.7, spin 0.5.
        1051 => {
            pr.start = place.offsetPoint(who, as, .{ 390, -30, 300 });
            pr.speed = 80.0 / 7.0;
            pr.max_speed = 80.0 / 7.0;
            pr.mesh = "brain";
            pr.mesh_scale = 0.7;
            pr.spin = 0.5;
        },
        // Orbital rocket (0x4a8ca0 → 0x4a8450): starts at the target + unit vector
        // (attacker − target in x + 0.1·aS, in y; rv2_h·aS − target z) × attack_rv2_dist
        // (6000)·aS; speed 24, trail 200.
        1040 => {
            var v = [3]f32{ p[0] - target[0] + 0.1 * as, p[1] - target[1], 1400 * as - target[2] };
            const vl = vec.len(v);
            if (vl > 0) for (&v) |*c| {
                c.* *= 6000 * as / vl;
            };
            pr.start = .{ target[0] + v[0], target[1] + v[1], target[2] + v[2] };
            pr.speed = 24;
            pr.max_speed = 24;
            pr.mesh = "pocisk";
            // Trail 0x4a84cb: rv2_trail_size 200, period rv2_trail_update_speed 1, brightness
            // ×rv2_trail_fade_factor 0.8, point rv2_trail_disp (800)·aS behind.
            pr.trail = "Trail1";
            pr.trail_len = 20;
            pr.trail_size = 200;
            pr.trail_period = 1;
            pr.trail_back = 800;
        },
        // Flare gun: "flare1" plane 300, speed 10.
        46 => {
            pr.speed = 10;
            pr.max_speed = 10;
            pr.effect = "flare1";
            pr.size = 300;
        },
        else => return 0,
    }
    pr.trail_as = as;
    return w.effects.launch(w.gpa, pr);
}

/// Rocket of the ROCKET scene command (0x476e9f): from pos + aS·attack_rocketl_*
/// (0, 300 forward, 270 up) by the actor's angle to world point `target`
/// (0x49d8d0), scale attack_rocketl_scale 2 (+0x358, 0x47708e). Outside battle
/// speedScale is a level variable, or 1 if it isn't above 0 (0x421911…0x421930).
pub fn sceneRocket(w: *World, who: *Object, target: [3]f32) u32 {
    const as = w.actorScale();
    const start = place.offsetPoint(who, as, heroLaunch(1024).?);
    const level_scale: f32 = if (w.level) |l| fields.getF(l, "speedScale") else 0;
    const ss: f32 = if (w.isCombat()) 7 * as else if (level_scale > 0) level_scale else 1;
    var pr = rocket(.{ .pos = start, .start = start, .target = target, .speed_scale = ss }, 120);
    pr.mesh_scale = 2;
    pr.trail_as = as;
    return w.effects.launch(w.gpa, pr);
}

/// Launch offset (forward, right, up) of a hero projectile by weapon nameID; in
/// parentheses the variables in x_disp (right), y_disp (forward), start_level order: knife code 4 (0x4867f6, attack_knife_*: −100, 200, 500); grenades codes 9, 10, 40
/// (0x4868f8, 0x4869fb, 0x4882cd, attack_grenade_*: 0, 0, 400); stone, molotov,
/// vodka, petrol codes 17, 18, 33, 34 (0x486f64…0x487f1e, attack_stone_*: −100, 0,
/// 400); launcher code 23 (0x48781c, attack_rocketl_*: 0, 300, 270).
fn heroLaunch(weapon_id: i32) ?[3]f32 {
    return switch (weapon_id) {
        40 => .{ 200, -100, 500 },
        33, 35, 1027 => .{ 0, 0, 400 },
        41, 86, 1030, 1032 => .{ 0, -100, 400 },
        1024 => .{ 300, 0, 270 },
        else => null,
    };
}

/// Rocket: speed 7 → 15 (acceleration 0.7 after 10 ticks), "Rocket1" and exhaust,
/// trail "Trail1" rocket1_trail_* (length 20, size 50, growth −0.3, brightness
/// ×0.8, period 2, jitter −0.004, point 140·aS behind; 0x49bfb0, 0x49d987).
fn rocket(p: effects.projectile.Projectile, size: f32) effects.projectile.Projectile {
    var x = p;
    x.speed = 7;
    x.max_speed = 15;
    x.accel = 0.7;
    x.accel_delay = 10;
    x.effect = "Rocket1";
    x.size = size;
    x.rocket = true;
    x.trail = "Trail1";
    x.trail_len = 20;
    x.trail_size = 50;
    return x;
}

fn arc(p: effects.projectile.Projectile, mesh: []const u8, scale: f32, spin: f32) effects.projectile.Projectile {
    var x = p;
    x.arc = true;
    x.mesh = mesh;
    x.mesh_scale = scale;
    x.spin = spin;
    return x;
}

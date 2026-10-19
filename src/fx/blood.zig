//! Fighter reactions: blood on damage, flare gun sparks (constructor 0x4ccbe0).

const vec = @import("../vec.zig");
const fields = @import("../fields.zig");
const World = @import("../state.zig").world.World;
const Object = @import("../script.zig").object.Object;
const effects = @import("../effects.zig");

/// Damage to fighter `victim` from `from`: blood (0x4ccbe0).
pub fn onDamage(w: *World, victim: *Object, from: *Object) void {
    // Exploding obstacles (barrels) don't bleed (0x49152e: explosive).
    if (victim.getInt("explosive") != 0) return;
    // 0x49158c…0x49165b: start 5 units from the fighter toward the attacker.
    const vp0 = fields.pos(victim);
    const ap = fields.pos(from);
    particles(w, victim, toward(vp0, ap), ap, .blood_drops);
    // Red light flash (0x491709…0x4918ee): colour (1, 0.2, 0.2), above the fighter at
    // attack_redlight_flash_level (300)·aS, range attack_redlight_flash_range
    // (600)·aS, attack_redlight_flash_timeout (10) ticks. The shift toward the camera
    // by attack_redlight_flash_displacement (300)·aS ignores the camera height here.
    const as = w.actorScale();
    const vp = fields.pos(victim);
    w.effects.addLight(w.gpa, .{ .pos = .{ vp[0], vp[1], vp[2] + 300 * as }, .color = .{ 1, 0.2, 0.2 }, .range = 600 * as, .left = 10 });
}

/// Flare gun sparks (reaction 0x491920, nameID 46 → 0x491e5e) on live target
/// `victim` from `from`: both points raised by blood_start_level·aS; start 10
/// behind the target by its angle and 5 toward the attacker (0x4919a0…0x491ad0).
pub fn flare(w: *World, victim: *Object, from: *Object) void {
    const lift = effects.particles.blood_start_level * w.actorScale();
    const vp = fields.pos(victim);
    const f = fields.angle(victim);
    const back = [3]f32{ vp[0] - @cos(f) * 10, vp[1] - @sin(f) * 10, vp[2] + lift };
    const ap = fields.pos(from);
    const to = [3]f32{ ap[0], ap[1], ap[2] + lift };
    particles(w, victim, toward(back, to), to, .flare_sparks);
}

/// Particle constructor 0x4ccbe0 with its sound: blood1/2/3 at random (0x4ccdd1).
fn particles(w: *World, victim: *Object, origin: [3]f32, from: [3]f32, p: effects.particles.Particles) void {
    w.effects.spawnParticles(w.gpa, w.crt(), origin, from, p);
    const names = [_][]const u8{ "blood1", "blood2", "blood3" };
    // shortcut: the exe passes the sound an address past the last particle (0x4ccdd1
    // → 0x4327f0), 12 bytes of heap, so the position is undefined; we use the fighter's point.
    w.out.sound(w.gpa, names[w.crt().below(3)], w.screenPos(victim));
}

/// `a` + 5·unit vector toward `b` (0x419850, 0x50a240 = 5).
fn toward(a: [3]f32, b: [3]f32) [3]f32 {
    const k = 5;
    const n = vec.normalize(vec.sub(b, a));
    return .{ a[0] + n[0] * k, a[1] + n[1] * k, a[2] + n[2] * k };
}

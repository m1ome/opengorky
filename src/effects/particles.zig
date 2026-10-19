//! Blood drops and flare sparks: particles of the shared constructor 0x4ccbe0.

const std = @import("std");
const Rand = @import("../crt_rand.zig").Rand;

/// Particle of 0x4ccbe0 (0x2c bytes): `rest` +0x1c, `blend` +0x20 (fade), `shrink` +0x24,
/// `dead` +0x28.
const Drop = struct {
    pos: [3]f32,
    vel: [3]f32,
    size: f32,
    rest: u32 = 0,
    blend: u32 = 0,
    shrink: u32 = 0,
    dead: bool = false,
};

/// particle_rest_time (0x6d2aec): particle counter limit.
pub const particle_rest_time = 40;
/// particle_blend_start (0x6d2ad4): `blend` from which a particle fades.
pub const particle_blend_start = 10;

/// One blood drop unit in world space per aS: 1/0.171 (double 0x50f4a8).
pub const drop_unit = 1.0 / 0.171;
/// blood_start_level (adjust.kdt, 0x6b67d4): initial drop height.
pub const blood_start_level = 51.0;

/// 0x4ccbe0 parameters (adjust.kdt): blood_* for blood (0x4916b7), flare_* for sparks
/// (0x491ea3); both fan over π·1.2 (0x50a120·0x50a238).
pub const Particles = struct {
    count: u8,
    size: f32 = 70,
    spread: f32 = std.math.pi * 1.2,
    vz: f32,
    dvz: f32,
    sp: f32,
    dsp: f32,
    flare: bool = false,

    pub const blood_drops: Particles = .{ .count = 15, .vz = 4, .dvz = 2, .sp = 1, .dsp = 0.2 };
    pub const flare_sparks: Particles = .{ .count = 40, .vz = 1.5, .dvz = 3, .sp = 1.4, .dsp = 2, .flare = true };
};

pub const Blood = struct {
    origin: [3]f32,
    drops: [40]Drop,
    n: u8,
    /// Flare sparks "flare1" (0x491ec2), otherwise blood "RedCircle" (0x4916bb).
    flare: bool = false,
    /// `shrink` step per tick (+0x2d8): flare_particle_fade_speed = 3 for sparks (0x491eef), else 1.
    shrink_rate: u32 = 1,

    /// 0x4cc8b0: a live particle's `blend`/`shrink` grow (dies at particle_rest_time), `rest`
    /// counts to 40 without motion, otherwise pos += v + G/2, v += G, size ·= 0.98; on the
    /// ground blend = rest = 1. A particle dying this tick still counts as alive.
    pub fn tick(bl: *Blood, _: void) bool {
        var alive = false;
        for (bl.drops[0..bl.n]) |*d| {
            if (d.dead) continue;
            alive = true;
            if (d.blend != 0) {
                d.blend += 1;
                if (d.blend >= particle_rest_time) d.dead = true;
            }
            if (d.shrink != 0) {
                d.shrink += bl.shrink_rate;
                if (d.shrink >= particle_rest_time) d.dead = true;
            }
            if (d.rest != 0) {
                if (d.rest < particle_rest_time) d.rest += 1 else d.dead = true;
                continue;
            }
            for (0..3) |k| d.pos[k] += d.vel[k];
            d.pos[2] -= 0.4;
            d.vel[2] -= 0.8;
            d.size *= 0.98;
            if (d.pos[2] <= 0) {
                d.blend = 1;
                d.rest = 1;
                d.pos[2] = 0;
            }
        }
        return alive;
    }
};

/// Blood drops and flare sparks (constructor 0x4ccbe0, shared by 0x4916ee and 0x491ed9):
/// `count` particles in drop units (×aS·`drop_unit` in the world, 0x4cce53) from height
/// blood_start_level (0x4ccc97), fanned by `spread` toward `from` (0x4ccd0e: atan2 +
/// rnd·spread − spread/2); vz = vz0 + rnd·dvz; speed sp = sp0 + rnd·dsp scales vx, vy and
/// vz (0x4ccd93…0x4ccdbf). rand() order: angle, vz, sp.
pub fn spawn(rand: *Rand, origin: [3]f32, from: [3]f32, p: Particles) Blood {
    var bl: Blood = .{ .origin = origin, .drops = undefined, .n = p.count, .flare = p.flare, .shrink_rate = if (p.flare) 3 else 1 };
    const base = std.math.atan2(from[1] - origin[1], from[0] - origin[0]);
    for (bl.drops[0..p.count]) |*d| {
        const a = base + rand.pct() * p.spread - p.spread * 0.5;
        const vz = p.vz + rand.pct() * p.dvz;
        const sp = p.sp + rand.pct() * p.dsp;
        d.* = .{
            .pos = .{ 0, 0, blood_start_level },
            .vel = .{ @cos(a) * sp, @sin(a) * sp, vz * sp },
            .size = p.size,
            .shrink = @intFromBool(p.flare),
        };
    }
    return bl;
}

test "spawn: rand() order angle → vz → sp, vz ×sp, height blood_start_level" {
    var r: Rand = .{};
    const bl = spawn(&r, .{ 0, 0, 0 }, .{ 1, 0, 0 }, .blood_drops);
    var q: Rand = .{};
    const a = q.pct() * std.math.pi * 1.2 - std.math.pi * 1.2 * 0.5;
    const vz = 4 + q.pct() * 2;
    const sp = 1 + q.pct() * 0.2;
    const d = bl.drops[0];
    try std.testing.expectEqual(@as(u8, 15), bl.n);
    try std.testing.expectEqual(@as(f32, blood_start_level), d.pos[2]);
    try std.testing.expectApproxEqAbs(@cos(a) * sp, d.vel[0], 1e-6);
    try std.testing.expectApproxEqAbs(vz * sp, d.vel[2], 1e-6);
}

test "Blood.tick: a spark dies on tick 13, a drop 40 ticks after landing (0x4cc8b0)" {
    var f: Blood = .{ .origin = @splat(0), .drops = undefined, .n = 1, .flare = true, .shrink_rate = 3 };
    f.drops[0] = .{ .pos = .{ 0, 0, 1e6 }, .vel = @splat(0), .size = 70, .shrink = 1 };
    var n: u32 = 0;
    while (!f.drops[0].dead) : (n += 1) _ = f.tick({});
    try std.testing.expectEqual(13, n);
    try std.testing.expect(!f.tick({}));

    var b: Blood = .{ .origin = @splat(0), .drops = undefined, .n = 1 };
    b.drops[0] = .{ .pos = .{ 0, 0, 0.1 }, .vel = @splat(0), .size = 70 };
    try std.testing.expect(b.tick({})); // landed: blend = rest = 1
    try std.testing.expectEqual(1, b.drops[0].blend);
    var alive: u32 = 0;
    while (b.tick({})) alive += 1;
    try std.testing.expectEqual(39, alive);
}

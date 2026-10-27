//! Projectiles (straight and arc), their trails and the blaster stream.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vec = @import("../vec.zig");
const num = @import("../num.zig");
const Rand = @import("../crt_rand.zig").Rand;
const light = @import("light.zig");
const adjust = @import("../formats.zig").adjust;
const Object = @import("../script.zig").object.Object;

/// Grenade (0x49c840): attack_grenade_angle and gravity from adjust.kdt.
fn grenadeAngle() f32 {
    return adjust.getFloat("attack_grenade_angle", 0.9);
}
fn gravity() f32 {
    return adjust.getFloat("gravity", 700);
}

/// What a projectile tick touches besides itself: its trail and the light pool.
pub const Ctx = struct {
    trails: *std.ArrayList(Trail),
    lights: *std.ArrayList(light.Light),
    gpa: Allocator,
    now: u64,
};

/// Projectile (0x49b0a0 straight, 0x49c840 arc): mesh and/or quad, trail, `done` on
/// arrival.
pub const Projectile = struct {
    id: u32 = 0,
    pos: [3]f32,
    start: [3]f32,
    target: [3]f32,
    /// Straight: unit direction, speed, limit, acceleration after `accel_delay` ticks.
    dir: [3]f32 = .{ 0, 0, 0 },
    speed: f32 = 0,
    max_speed: f32 = 0,
    accel: f32 = 0,
    accel_delay: u32 = 0,
    /// Arc: flight time T (s), speeds vh, vz, t.
    arc: bool = false,
    /// Arc: floor height (0x592764 — battle grid/level floor); the projectile lands on it at
    /// the target's x, y (0x49c840).
    floor: f32 = 0,
    /// Light following the projectile (0x4321b0, +0x380; molotov 0x49e914): range (already
    /// ×aS) and colour; 0 = no light.
    light_range: f32 = 0,
    light_rgb: [3]f32 = .{ 1, 1, 1 },
    t: f32 = 0,
    flight: f32 = 0,
    vh: f32 = 0,
    vz: f32 = 0,
    /// Battle speedScale (0x51e250).
    speed_scale: f32 = 1,
    ticks: u32 = 0,
    /// Mesh (`gfx_3d\<mesh>.msh`) with scale and spin, or an effect quad.
    mesh: []const u8 = "",
    mesh_scale: f32 = 1,
    spin: f32 = 0,
    roll: f32 = 0,
    effect: []const u8 = "",
    size: f32 = 0,
    /// Bottle flame (molotov): "flame" above the projectile.
    flame: bool = false,
    /// Trail (class 0x4cd0b0, a separate object that outlives arrival): effect, length
    /// (+0x2e8), size (+0x300), size loss per point (+0x2fc), brightness factor per point
    /// (+0x304), jitter (+0x30c), point period (+0x2f8), colour (+0x310…0x318); points are
    /// placed `trail_back`·aS behind the projectile. Defaults: rocket1_trail_* (0x49d8d0).
    trail: []const u8 = "",
    trail_len: u8 = 0,
    trail_size: f32 = 0,
    trail_size_fade: f32 = -0.3,
    trail_fade: f32 = 0.8,
    trail_disp: f32 = -0.004,
    trail_period: u32 = 2,
    trail_rgb: [3]f32 = .{ 1, 1, 1 },
    trail_back: f32 = 140,
    /// aS at launch (for `trail_back`).
    trail_as: f32 = 0.15,
    rocket: bool = false,
    /// Cutter Pill bullet (0x49dd70): chaingun.msh with "arrows" (mode 2) ×mesh_scale·aS
    /// along the flight direction, at pos − dir·240·aS.
    bullet: bool = false,
    /// Ball (0x4a5840): hangs at the owner's hands for `hold` ticks (+0x3b4, to 0 — 0x4a5f35), grows from
    /// 0.1 by `grow` per tick to mesh_scale (+0x3cc, +0x3d0; attack_ball_ds 0.08); `k` is the
    /// current scale fraction.
    hold: u32 = 0,
    grow: f32 = 0,
    k: f32 = 1,
    /// Ball glow pulse (0x4a5d79…0x4a5e4d); null for other projectiles.
    ball: ?Ball = null,
    /// Ball: the fighter (+0x384) whose "kula1"/"kula2" midpoint it sits at while held
    /// (0x4a5cac, `spawn.aimBalls`); null once the fighter is removed (0x4a5c50).
    owner: ?*Object = null,
    /// Incubus ball (kind 0, +0x3bc): on arrival it lies there glowing as a charge
    /// (`lying`, countdown +0x3b8 set at 0x4a6056) until the battle blows it up (0x4a61d0).
    charge: bool = false,
    lying: bool = false,
    done: bool = false,

    pub fn tick(p: *Projectile, c: Ctx) bool {
        if (p.done) return false;
        // Ball light (+0x3d8, 0x4a5d12): at the ball's position before this tick's flight;
        // brightens by (0.02, 0.025, 1/30) a tick while blue < 0.9 (0x4a5d39).
        const before = p.pos;
        if (p.ball != null and p.light_rgb[2] < 0.9) p.light_rgb = .{ p.light_rgb[0] + 0.02, p.light_rgb[1] + 0.025, p.light_rgb[2] + 1.0 / 30.0 };
        fly(p);
        // The projectile feeds its trail a point trail_back·aS behind it (0x49c639,
        // 0x4a8ba2); on arrival the trail detaches (0x49c6d0).
        if (p.trail_len > 0) for (c.trails.items) |*t| if (t.id == p.id and !t.detached) {
            const b = p.trail_back * p.trail_as;
            _ = t.add(.{ p.pos[0] - p.dir[0] * b, p.pos[1] - p.dir[1] * b, p.pos[2] - p.dir[2] * b }, c.now);
            if (p.done) t.detached = true;
            break;
        };
        // Light follows the projectile (0x49cbb8: light position = projectile position).
        if (p.light_range > 0) light.add(c.lights, c.gpa, .{ .pos = if (p.ball != null) before else p.pos, .color = p.light_rgb, .range = p.light_range, .left = 1 });
        return true;
    }
};

/// attack_ball_ms (0x6c520c): the ball draw (0x4a6280) divides its scale by it for
/// both the Incubus and the Stinger ball.
pub fn attackBallMs() f32 {
    return adjust.getFloat("attack_ball_ms", 0.8);
}

/// Ball (0x4a5840) glow state: two triangle waves `a`, `b` in ±0.2 (steps 0.024 and
/// 0.018, +0x3dc…+0x3e8) and two "kula" frames (+0x3f0, +0x3f4) that advance mod 3
/// when `a` hits −0.2 or +0.2. Drawn without a mesh (vtable +0x50 is `ret`).
const Ball = struct {
    a: f32 = 0,
    da: f32 = 0.024,
    b: f32 = 0,
    db: f32 = 0.018,
    f1: u32 = 0,
    f2: u32 = 1,

    fn wave(v: *f32, dv: *f32) void {
        v.* += dv.*;
        if (v.* > 0.2 or v.* < -0.2) {
            v.* = std.math.clamp(v.*, -0.2, 0.2);
            dv.* = -dv.*;
        }
    }

    pub fn tick(s: *Ball) void {
        wave(&s.a, &s.da);
        if (s.a == 0.2) s.f2 = (s.f2 + 1) % 3 else if (s.a == -0.2) s.f1 = (s.f1 + 1) % 3;
        wave(&s.b, &s.db);
    }
};

test "ball light (0x4a5d12): where the ball was before the tick, brightening to blue 0.9" {
    const gpa = std.testing.allocator;
    var trails: std.ArrayList(Trail) = .empty;
    var lights: std.ArrayList(light.Light) = .empty;
    defer lights.deinit(gpa);
    var p: Projectile = .{ .pos = .{ 0, 0, 0 }, .start = .{ 0, 0, 0 }, .target = .{ 1e6, 0, 0 }, .dir = .{ 1, 0, 0 }, .speed = 10, .max_speed = 10, .ball = .{}, .light_range = 165, .light_rgb = @splat(0.1) };
    const c: Ctx = .{ .trails = &trails, .lights = &lights, .gpa = gpa, .now = 0 };
    _ = p.tick(c);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, lights.items[0].pos);
    try std.testing.expectApproxEqAbs(@as(f32, 0.12), lights.items[0].color[0], 1e-6);
    for (0..40) |_| _ = p.tick(c);
    try std.testing.expect(p.light_rgb[2] >= 0.9 and p.light_rgb[2] < 0.94);
}

test "Ball.tick: a clamps at ±0.2 and flips, f2 steps at +0.2, f1 at −0.2" {
    var b: Ball = .{};
    for (0..9) |_| b.tick();
    try std.testing.expectEqual(@as(f32, 0.2), b.a);
    try std.testing.expectEqual(@as(f32, -0.024), b.da);
    try std.testing.expectEqual([2]u32{ 0, 2 }, [2]u32{ b.f1, b.f2 });
    for (0..17) |_| b.tick();
    try std.testing.expectEqual(@as(f32, -0.2), b.a);
    try std.testing.expectEqual([2]u32{ 1, 2 }, [2]u32{ b.f1, b.f2 });
}

/// Launch setup: position at the start and the flight parameters (0x49c840 arc, 0x49b0a0
/// straight).
pub fn prepare(p: Projectile) Projectile {
    var x = p;
    x.pos = p.start;
    if (x.arc) {
        // 0x49c840: θ = attack_grenade_angle 0.9, g = gravity 700, no air drag. D is the
        // full 3D distance to the target and H the start height above the floor
        // (0x592764), both in speedScale units: T = √(2(tgθ·D + H)/g), vz = gT/2 − H/T,
        // vh = vz/tgθ. Direction +0x39c is the unit 3D vector to the target with z zeroed
        // (0x49c9c0): in x, y it covers exactly Dxy and lands at floor height.
        const theta = grenadeAngle();
        const g = gravity();
        const d = [3]f32{ p.target[0] - p.start[0], p.target[1] - p.start[1], p.target[2] - p.start[2] };
        const l = vec.len(d);
        const dd = l / x.speed_scale;
        const hh = (p.start[2] - p.floor) / x.speed_scale;
        const tt = @sqrt(@max(0.0001, 2 * (@tan(theta) * dd + hh) / g));
        x.flight = tt;
        x.vz = g * tt / 2 - hh / tt;
        x.vh = x.vz / @tan(theta);
        // Mesh orientation (+0x2f8, 0x49b0a0) follows the 3D direction at launch; x, y
        // flight uses the same components (z zeroed).
        x.dir = if (l > 0.001) .{ d[0] / l, d[1] / l, d[2] / l } else .{ 1, 0, 0 };
    } else {
        const d = [3]f32{ p.target[0] - p.start[0], p.target[1] - p.start[1], p.target[2] - p.start[2] };
        const l = vec.len(d);
        x.dir = if (l > 0) .{ d[0] / l, d[1] / l, d[2] / l } else .{ 1, 0, 0 };
    }
    return x;
}

fn fly(p: *Projectile) void {
    p.ticks += 1;
    p.roll += p.spin;
    if (p.ball) |*b| b.tick();
    if (p.grow > 0) p.k = @min(1, p.k + p.grow);
    // Lying charge: only the glow moves (0x4a5ee6: +0x3b8 ≠ 0 skips the flight).
    if (p.lying) return;
    if (p.hold > 0) {
        p.hold -= 1;
        // Released (0x4a6087): flies from where it hangs (the hands) to the target.
        if (p.hold == 0 and p.ball != null) {
            p.start = p.pos;
            const d = [3]f32{ p.target[0] - p.pos[0], p.target[1] - p.pos[1], p.target[2] - p.pos[2] };
            const l = vec.len(d);
            if (l > 0) p.dir = .{ d[0] / l, d[1] / l, d[2] / l };
        }
        return;
    }
    if (p.arc) {
        p.t += 1.0 / 30.0;
        const t = @min(p.t, p.flight);
        p.pos = .{
            p.start[0] + p.dir[0] * p.vh * t * p.speed_scale,
            p.start[1] + p.dir[1] * p.vh * t * p.speed_scale,
            p.start[2] + (p.vz * t - gravity() / 2.0 * t * t) * p.speed_scale,
        };
        if (p.t >= p.flight) p.done = true;
    } else {
        for (0..3) |k| p.pos[k] += p.dir[k] * p.speed * p.speed_scale;
        if (p.ticks > p.accel_delay) p.speed = @min(p.speed + p.accel, @max(p.max_speed, p.speed));
        const d = [3]f32{ p.pos[0] - p.start[0], p.pos[1] - p.start[1], p.pos[2] - p.start[2] };
        const full = [3]f32{ p.target[0] - p.start[0], p.target[1] - p.start[1], p.target[2] - p.start[2] };
        const along = d[0] * p.dir[0] + d[1] * p.dir[1] + d[2] * p.dir[2];
        if (along * along >= full[0] * full[0] + full[1] * full[1] + full[2] * full[2]) {
            p.pos = p.target;
            if (p.charge) p.lying = true else p.done = true;
        }
    }
}

/// What a trail tick needs: the global tick counter and the shared rand.
pub const TrailCtx = struct {
    now: u64,
    rand: *Rand,
};

/// Projectile trail (class 0x4cd0b0, vtable 0x5094b0): a ring of 32 points, newest at the
/// head (`head`, +0x2e4). A point is added (0x4cd3d0) only when the global tick counter is
/// divisible by `period`. While flying the projectile feeds a point every tick; 35 ticks
/// without one end it. Once it arrives (`detached`, +0x2f0) the trail feeds itself the last
/// point and eats one from the tail per tick (+0x2f4) until `len` are gone (0x4cd2b0). Each
/// tick all `len` points jitter by (rand & 255 − 128)·`disp`·speedScale per axis (shared
/// rand, 0x4cd32e). Drawing (0x4cd4a0): from the newest point with s = 1, a = 1, c = 1;
/// point i (if i ≥ eaten) uses frame i, size s·size, brightness a, colour c·rgb; then
/// s −= size_fade, a ·= fade, c −= color_fade (≥ 0); stop when s or a ≤ 0.01.
pub const Trail = struct {
    pub const ring = 32;
    id: u32,
    effect: []const u8,
    len: u8,
    size: f32,
    size_fade: f32,
    fade: f32,
    disp: f32,
    period: u32,
    rgb: [3]f32,
    speed_scale: f32,
    pts: [ring][3]f32 = @splat(.{ 0, 0, 0 }),
    head: u8 = 0,
    count: u8 = 0,
    eaten: u8 = 0,
    idle: u32 = 0,
    last: [3]f32 = .{ 0, 0, 0 },
    detached: bool = false,
    done: bool = false,

    /// 0x4cd3d0: add a point if `now` is a multiple of the period.
    fn add(self: *Trail, pos: [3]f32, now: u64) bool {
        self.idle = 0;
        if (now % @max(1, self.period) != 0) return false;
        self.last = pos;
        self.head = if (self.head == 0) ring - 1 else self.head - 1;
        self.pts[self.head] = pos;
        if (self.count < self.len) self.count += 1;
        return true;
    }

    /// 0x4cd2b0.
    pub fn tick(self: *Trail, c: TrailCtx) bool {
        if (self.detached) {
            if (self.add(self.last, c.now)) {
                self.eaten += 1;
                if (self.eaten >= self.len) self.done = true;
            }
        } else {
            self.idle += 1;
            if (self.idle > 35) self.done = true;
        }
        const k = self.disp * self.speed_scale;
        var idx: usize = self.head;
        for (0..self.len) |_| {
            const z: f32 = @floatFromInt((c.rand.next() & 0xff) - 128);
            const y: f32 = @floatFromInt((c.rand.next() & 0xff) - 128);
            const x: f32 = @floatFromInt((c.rand.next() & 0xff) - 128);
            self.pts[idx][0] += x * k;
            self.pts[idx][1] += y * k;
            self.pts[idx][2] += z * k;
            idx = (idx + 1) % ring;
        }
        return !self.done;
    }
};

/// Blaster stream (0x4a28e0): every tick adds a point at the muzzle (with jitter); point i,
/// recorded i ticks after start, has moved (n − i)·60·aS along `v`; segments draw until a
/// point reaches the target (`len`).
pub const Stream = struct {
    const max_points = 100;
    start: [3]f32,
    v: [3]f32,
    len: f32,
    /// Actor scale at the shot.
    as: f32,
    pts: [max_points][3]f32 = undefined,
    n: u32 = 0,
    left: u32 = 120,

    /// Offset of point `i` along `v`.
    pub fn dist(self: Stream, i: u32) f32 {
        return num.toF32(self.n - i) * 60 * self.as;
    }

    pub fn tick(self: *Stream, rand: *Rand) bool {
        if (self.left > 0) self.left -= 1;
        if (self.n < max_points) {
            // Shared rand(): z % 10, then x % 4, y % 4 (0x4a2f22).
            const jz: f32 = @floatFromInt(rand.below(10));
            const jx: f32 = @floatFromInt(rand.below(4));
            const jy: f32 = @floatFromInt(rand.below(4));
            self.pts[self.n] = .{ self.start[0] + jx * self.as, self.start[1] + jy * self.as, self.start[2] + jz * self.as };
            self.n += 1;
        }
        return self.left != 0;
    }
};

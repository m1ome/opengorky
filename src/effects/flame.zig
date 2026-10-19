//! Fire and gas: flamethrower streams (`Flame`) and Schizo's gas cloud (`Cloud`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Object = @import("../script.zig").object.Object;
const retain = @import("retain.zig");

/// Schizo's gas cloud (0x4a95d0 "gas2", kind 49): lasts while its cell has gas (cleared by
/// combat), frames loop.
pub const Cloud = struct {
    effect: []const u8 = "gas2",
    pos: [3]f32,
    size: f32,
    ticks: u32 = 0,
    /// Fading out (the cell's gas ended): alpha drops over 30 ticks.
    fading: u32 = 0,

    pub fn tick(cl: *Cloud, _: void) bool {
        cl.ticks += 1;
        if (cl.fading == 0) return true;
        cl.fading -= 1;
        return cl.fading != 0;
    }
};

const FlameParticle = struct {
    pos: [3]f32,
    vel: [3]f32,
    age: u32,

    pub fn tick(p: *FlameParticle, life: u32) bool {
        for (0..3) |k| p.pos[k] += p.vel[k];
        p.age += 1;
        return p.age < life;
    }
};

pub const Flame = struct {
    /// Particle spawn point and velocity (world units per tick); with `actor` the world
    /// recomputes them every tick (`spawn.aimFlames`).
    src: [3]f32,
    dir: [3]f32,
    /// Stream behind a weapon (0x49fdc0): `base` is a fixed point at the fighter (position +
    /// start_level·aS up). Without `link2` the direction is normal(link point − base) rotated
    /// by `rot` around the vertical; particles spawn at base + dir·`ahead`. With `link2`
    /// (Sting: t1 → t2) base is the `link` point and the direction goes to `link2`.
    actor: ?*Object = null,
    link: []const u8 = "",
    link2: []const u8 = "",
    base: [3]f32 = .{ 0, 0, 0 },
    rot: f32 = 0,
    ahead: f32 = 0,
    speed: f32 = 0,
    timer: i32,
    spawned: u32 = 0,
    max: u32,
    life: u32 = 16,
    parts: std.ArrayList(FlameParticle) = .empty,

    /// 0x49faa0: one particle per tick until `max`; object timer.
    pub fn tick(fl: *Flame, a: Allocator) bool {
        fl.timer -= 1;
        if (fl.timer > 0 and fl.spawned < fl.max) {
            fl.parts.append(a, .{ .pos = fl.src, .vel = fl.dir, .age = 0 }) catch {};
            fl.spawned += 1;
        }
        retain.retain(&fl.parts, fl.life);
        if (fl.timer > 0 or fl.parts.items.len > 0) return true;
        fl.parts.deinit(a);
        return false;
    }
};

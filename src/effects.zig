//! Battle and scene visual effects (exe: `gfx_3d\Effects\<name>\<name>.dsc` resources,
//! scene objects 0x4cb600 etc.). Only state and the 30 Hz tick live here; the viewer draws
//! them.
//!
//! Kinds:
//! - `Bitmap` (0x4cb600): one quad, frames played once with step `step`;
//! - `Flash` (0x4cb950): a quad that brightens and fades, size = max·brightness;
//! - `Attached` (actor command 0x20, 0x42ac30): `chaingun.msh` on a model link point,
//!   textured with the effect's current frame (muzzle flash), additive;
//! - `Blood` (0x4ccbe0): particles under gravity −0.8 that rest 40 ticks on the ground;
//! - `Flame` (0x49faa0): flamethrower stream, one particle per tick, straight flight;
//! - `Beam` (0x4a1600, 0x4a3960, 0x4a4c70, 0x4a7710): ribbon beams — ion, Medusa's current,
//!   Guard lasers, satellite lightning; `Morph` (0x4259f0): morph glow;
//! - `Stream` (0x4a28e0): blaster stream; `Spin` (0x4a7020): satellite energy beam.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rand = @import("crt_rand.zig").Rand;

pub const dsc = @import("effects/dsc.zig");
pub const bitmap = @import("effects/bitmap.zig");
pub const particles = @import("effects/particles.zig");
pub const flame = @import("effects/flame.zig");
pub const projectile = @import("effects/projectile.zig");
pub const beam = @import("effects/beam.zig");
pub const light = @import("effects/light.zig");
pub const batch = @import("effects/batch.zig");
const retain = @import("effects/retain.zig").retain;

pub const Effects = struct {
    beams: std.ArrayList(beam.Beam) = .empty,
    streams: std.ArrayList(projectile.Stream) = .empty,
    spins: std.ArrayList(beam.Spin) = .empty,
    morphs: std.ArrayList(bitmap.Morph) = .empty,
    lights: std.ArrayList(light.Light) = .empty,
    projectiles: std.ArrayList(projectile.Projectile) = .empty,
    next_id: u32 = 1,
    bitmaps: std.ArrayList(bitmap.Bitmap) = .empty,
    attached: std.ArrayList(bitmap.Attached) = .empty,
    blood: std.ArrayList(particles.Blood) = .empty,
    trails: std.ArrayList(projectile.Trail) = .empty,
    flames: std.ArrayList(flame.Flame) = .empty,
    clouds: std.ArrayList(flame.Cloud) = .empty,
    ticks: u64 = 0,

    pub fn deinit(self: *Effects, gpa: Allocator) void {
        self.beams.deinit(gpa);
        self.streams.deinit(gpa);
        self.spins.deinit(gpa);
        self.morphs.deinit(gpa);
        self.lights.deinit(gpa);
        self.projectiles.deinit(gpa);
        self.bitmaps.deinit(gpa);
        self.attached.deinit(gpa);
        self.blood.deinit(gpa);
        self.trails.deinit(gpa);
        self.clouds.deinit(gpa);
        for (self.flames.items) |*f| f.parts.deinit(gpa);
        self.flames.deinit(gpa);
    }

    /// Launch a projectile; returns its id.
    pub fn launch(self: *Effects, gpa: Allocator, p: projectile.Projectile) u32 {
        var x = projectile.prepare(p);
        x.id = self.next_id;
        self.next_id += 1;
        self.projectiles.append(gpa, x) catch return 0;
        if (x.trail.len > 0 and x.trail_len > 0) self.trails.append(gpa, .{
            .id = x.id,
            .effect = x.trail,
            .len = @min(x.trail_len, projectile.Trail.ring),
            .size = x.trail_size,
            .size_fade = x.trail_size_fade,
            .fade = x.trail_fade,
            .disp = x.trail_disp,
            .period = x.trail_period,
            .rgb = x.trail_rgb,
            .speed_scale = x.speed_scale,
        }) catch {};
        return x.id;
    }

    pub fn projectileAlive(self: *Effects, id: u32) bool {
        for (self.projectiles.items) |p| if (p.id == id) return !p.done and !p.lying;
        return false;
    }

    /// The projectile arrived and lies as a charge (Incubus ball).
    pub fn projectileLying(self: *Effects, id: u32) bool {
        for (self.projectiles.items) |p| if (p.id == id) return p.lying;
        return false;
    }

    /// Remove a projectile (a charge that blew up).
    pub fn endProjectile(self: *Effects, id: u32) void {
        for (self.projectiles.items) |*p| if (p.id == id) {
            p.done = true;
        };
    }

    pub fn addLight(self: *Effects, gpa: Allocator, l: light.Light) void {
        light.add(&self.lights, gpa, l);
    }

    /// One tick.
    pub fn tick(self: *Effects, gpa: Allocator, rand: *Rand) void {
        self.ticks += 1;
        retain(&self.lights, {});
        retain(&self.beams, {});
        retain(&self.streams, rand);
        retain(&self.morphs, {});
        retain(&self.spins, {});
        retain(&self.projectiles, projectile.Ctx{ .trails = &self.trails, .lights = &self.lights, .gpa = gpa, .now = self.ticks });
        retain(&self.trails, projectile.TrailCtx{ .now = self.ticks, .rand = rand });
        retain(&self.bitmaps, {});
        retain(&self.attached, self.ticks);
        retain(&self.blood, {});
        retain(&self.clouds, {});
        retain(&self.flames, gpa);
    }

    pub fn addBitmap(self: *Effects, gpa: Allocator, b: bitmap.Bitmap) void {
        self.bitmaps.append(gpa, b) catch {};
    }

    pub fn attach(self: *Effects, gpa: Allocator, a: bitmap.Attached) void {
        var x = a;
        x.start = self.ticks;
        self.attached.append(gpa, x) catch {};
    }

    /// Blood drops and flare sparks (`particles.spawn`).
    pub fn spawnParticles(self: *Effects, gpa: Allocator, rand: *Rand, origin: [3]f32, from: [3]f32, p: particles.Particles) void {
        self.blood.append(gpa, particles.spawn(rand, origin, from, p)) catch {};
    }
};

test {
    _ = dsc;
    _ = particles;
    _ = flame;
    _ = @import("effects/retain.zig");
}

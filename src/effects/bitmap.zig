//! Sprite effects: animated quads (`Bitmap`), muzzle flashes on link points (`Attached`)
//! and the morph glow (`Morph`).

const std = @import("std");
const Rand = @import("../crt_rand.zig").Rand;
const Object = @import("../script.zig").object.Object;

pub const Bitmap = struct {
    effect: []const u8,
    pos: [3]f32,
    size: f32,
    step: f32,
    acc: f32 = 0,
    alpha: f32 = 1,
    rgb: [3]f32 = .{ 1, 1, 1 },
    /// Delayer (0x4cd7b0): appears after this many ticks.
    delay: u32 = 0,
    /// Flash (0x4cb950): brightness rises by `rate` to 1, then fades; size = size·alpha.
    flash_rate: f32 = 0,
    flash_down: bool = false,
    /// Frames of the effect animation; resolved at spawn (`fx.bitmap`).
    frames: u32 = 20,

    /// `_ftol(acc)` (0x4cb815): truncated, not rounded.
    pub fn frame(self: Bitmap) u32 {
        return @intFromFloat(self.acc);
    }

    pub fn drawSize(self: Bitmap) f32 {
        return if (self.flash_rate > 0) self.size * self.alpha else self.size;
    }

    pub fn tick(b: *Bitmap, _: void) bool {
        if (b.delay > 0) {
            b.delay -= 1;
            return true;
        }
        if (b.flash_rate > 0) {
            if (!b.flash_down) {
                b.alpha += b.flash_rate;
                if (b.alpha > 1) b.flash_down = true;
                return true;
            }
            b.alpha -= b.flash_rate;
            return b.alpha >= 0;
        }
        b.acc += @max(0.01, b.step);
        return b.frame() < b.frames;
    }
};

pub const Attached = struct {
    actor: *Object,
    effect: []const u8,
    /// Effect mesh (`gfx_3d\<mesh>.msh`), usually "chaingun" — two crossed quads.
    mesh: []const u8 = "chaingun",
    link: []const u8,
    /// Offset from the link point in actor model units (already mesh-scaled, as in the exe).
    offset: [3]f32,
    /// Effect mesh rotation (3×3 row-major, row-vector convention) and scale.
    rot: [9]f32 = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 },
    scale: f32 = 1,
    /// Start tick: frame = (tick − start) % frames.
    start: u64,
    /// Ticks left; delay before it appears.
    left: u32,
    delay: u32 = 0,

    pub fn tick(a: *Attached, now: u64) bool {
        if (a.delay > 0) {
            a.delay -= 1;
            if (a.delay == 0) a.start = now;
            return true;
        }
        if (a.left == 0) return false;
        a.left -= 1;
        return true;
    }
};

/// Morph (ACTOR_MORPH, 0x4259f0): glow — mesh "nowy" ×(3, 3, 4)·aS, additive at 0.5·p
/// brightness (p swings 0.6…1 in 0.03 steps), 10 "poswiata" sparks on a 200·aS circle rising
/// with acceleration; after morf_delay (30) the new model fades in from alpha 50 (+14 per
/// tick) for morf_life (30) ticks.
pub const Morph = struct {
    const Particle = struct { phi: f32, w: f32, h: f32 = 0, v: f32, active: bool = false };
    pos: [3]f32,
    angle: f32,
    /// New model and its animation.
    mesh: []const u8,
    anim: []const u8,
    as: f32,
    p: f32 = 0.6,
    dr: f32 = 0.03,
    delay: u32 = 30,
    life: i32 = 30,
    alpha: u32 = 50,
    counter: u32 = 0,
    anim_ticks: f32 = 0,
    parts: [10]Particle,
    done: bool = false,
    /// The morphing actor. Deviation: the glow dies with it (DELETEOBJECT), otherwise a scene
    /// skipped before LOADLEVEL leaves it in the left level and it plays again on return.
    owner: ?*Object = null,

    /// Sparks (0x425b29): phase (rand%32)·π/16, speed (rand%32)/290 (0x508798) + 0.2, rising
    /// from 4·aS.
    pub fn init(pos: [3]f32, angle: f32, mesh: []const u8, anim: []const u8, as: f32, rand: *Rand) Morph {
        var m: Morph = .{ .pos = pos, .angle = angle, .mesh = mesh, .anim = anim, .as = as, .parts = undefined };
        for (&m.parts) |*pt| {
            const a: f32 = @floatFromInt(rand.below(32));
            const b: f32 = @floatFromInt(rand.below(32));
            pt.* = .{ .phi = a * 0.0625 * std.math.pi, .w = b * (1.0 / 290.0) + 0.2, .v = 4 * as };
        }
        return m;
    }

    /// Position of spark `i` (radius 200·aS).
    pub fn particlePos(self: Morph, i: usize) [3]f32 {
        const pt = self.parts[i];
        const r = 200 * self.as;
        return .{ self.pos[0] + r * @cos(pt.phi), self.pos[1] + r * @sin(pt.phi), self.pos[2] + pt.h };
    }

    /// Tick 0x425f10.
    pub fn tick(self: *Morph, _: void) bool {
        self.p += self.dr;
        if (self.p > 1) {
            self.p = 1;
            self.dr = -self.dr;
        } else if (self.p < 0.6) {
            self.p = 0.6;
            self.dr = -self.dr;
        }
        if (self.counter % 4 == 0) for (&self.parts) |*pt| if (!pt.active) {
            pt.active = true;
            break;
        };
        self.counter += 1;
        for (&self.parts) |*pt| if (pt.active) {
            pt.phi = @mod(pt.phi + pt.w, 2 * std.math.pi);
            pt.h += pt.v;
            pt.v += self.as;
        };
        if (self.delay > 0) {
            self.delay -= 1;
            return true;
        }
        self.life -= 1;
        if (self.life < 0) self.done = true;
        self.alpha = @min(255, self.alpha + 14);
        self.anim_ticks += 1;
        return !self.done;
    }
};

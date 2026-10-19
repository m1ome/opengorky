//! Beams: ion, Medusa's current, Guard lasers, satellite lightning (`Beam`) and the
//! satellite energy beam (`Spin`).

const std = @import("std");
const Object = @import("../script.zig").object.Object;

/// Beam kind (0x4a1600, 0x4a3960, 0x4a4c70, 0x4a7710); all additive, texture frame
/// (T>>1)%n (lightning T%n).
const BeamKind = enum {
    /// Quads along the segment, half a size apart.
    billboards,
    /// Ion rifle: two passes of 25 segments as a ribbon along `dir`; fixed length
    /// (independent of the target).
    ion,
    /// Guard eye laser: ribbon from the actor's `link` point to `to`.
    laser,
    /// Medusa's current: two arcs current1→current3 and current2→current4 of the actor.
    current,
    /// Satellite lightning: a camera-facing vertical strip, 4 parts above `to`.
    lightning,
};

/// Beam (ion 0x4a1600, lightning 0x4a7710): a chain of quads from `from` to `to`, frame
/// (tick / div) % frames, lives `left` ticks.
pub const Beam = struct {
    kind: BeamKind = .billboards,
    effect: []const u8,
    from: [3]f32,
    to: [3]f32,
    /// Half width (in aS units).
    size: f32,
    left: u32,
    div: u32 = 2,
    ticks: u32 = 0,
    /// For `.laser` and `.current`: whose link points.
    actor: ?*Object = null,
    link: []const u8 = "",
    /// For `.ion`: horizontal beam direction (unit) at the shot; with `actor` and `link` the
    /// start and direction follow the weapon point every frame.
    dir: [3]f32 = .{ 1, 0, 0 },
    /// For `.ion`: direction rotation around the vertical (−0.09, Slavsky 0.4).
    turn: f32 = 0,

    pub fn tick(b: *Beam, _: void) bool {
        b.ticks += 1;
        return b.ticks < b.left;
    }
};

/// Satellite energy beam (0x4a7020): mesh "beam" at a point, spinning 0.05 rad per tick;
/// brightness rises 0.2 per tick to 1, starts falling 60 ticks before the end of its life,
/// and the object vanishes below 0.
pub const Spin = struct {
    mesh: []const u8 = "beam",
    pos: [3]f32,
    phase: f32 = 0,
    k: f32 = 0,
    dw: f32 = 0.2,
    left: u32 = 200,
    done: bool = false,

    pub fn tick(self: *Spin, _: void) bool {
        self.phase = @mod(self.phase + 0.05, 2 * std.math.pi);
        self.k = @min(1, self.k + self.dw);
        if (self.left > 0) self.left -= 1;
        if (self.left == 60) self.dw = -self.dw;
        if (self.k < 0 or self.left == 0) self.done = true;
        return !self.done;
    }
};

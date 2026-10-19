//! Short point lights (explosions, molotov, projectiles).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Short point light (pool 0x6c6290 via 0x4321b0, up to 16): lights actors like `.lts`
/// lamps (0x47e1f0: colour · cosθ · (1 − d²/range²)).
pub const Light = struct {
    pos: [3]f32,
    color: [3]f32,
    range: f32,
    left: u32,

    pub fn tick(l: *Light, _: void) bool {
        if (l.left <= 1) return false;
        l.left -= 1;
        return true;
    }
};

const max_lights = 16;

/// Add a light flash; the exe pool holds 16, extras are dropped.
pub fn add(lights: *std.ArrayList(Light), gpa: Allocator, l: Light) void {
    if (lights.items.len >= max_lights) return;
    lights.append(gpa, l) catch {};
}

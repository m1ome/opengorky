//! Skeletal animation: model vertex positions at a `.bfr` frame.
//!
//! Each vertex depends on one or more bones with weights (linear blending).
//! A bone matrix in a frame is a 3×3 rotation and a translation; in the rest
//! frame the matrices are identity, i.e. they take a vertex from the bind pose
//! straight to the current pose (no hierarchy). Multiplication order: `Convention`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mesh_fmt = @import("../formats.zig").mesh;
const anim = @import("../formats.zig").anim;

pub const Convention = enum {
    /// v' = R·v + t, R by rows.
    column,
    /// v' = v·R + t (row vector), i.e. R by columns.
    row,
};

pub fn transform(m: *const [12]f32, v: [3]f32, conv: Convention) [3]f32 {
    return switch (conv) {
        .column => .{
            m[0] * v[0] + m[1] * v[1] + m[2] * v[2] + m[9],
            m[3] * v[0] + m[4] * v[1] + m[5] * v[2] + m[10],
            m[6] * v[0] + m[7] * v[1] + m[8] * v[2] + m[11],
        },
        .row => .{
            m[0] * v[0] + m[3] * v[1] + m[6] * v[2] + m[9],
            m[1] * v[0] + m[4] * v[1] + m[7] * v[2] + m[10],
            m[2] * v[0] + m[5] * v[1] + m[8] * v[2] + m[11],
        },
    };
}

/// Vertex positions of all parts at `frame` (global .bfr number).
/// One array per part, in `arena`.
pub fn pose(arena: Allocator, mesh: mesh_fmt.Mesh, frames: anim.BoneFrames, frame: u32, conv: Convention) Allocator.Error![][][3]f32 {
    const out = try arena.alloc([][3]f32, mesh.parts.len);
    for (mesh.parts, out) |part, *dst| {
        dst.* = try arena.alloc([3]f32, part.vertices.len);
        for (part.vertices, part.ranges, dst.*) |v, rg, *p| {
            if (frames.bones == 0 or rg[0] == rg[1]) {
                p.* = v.pos;
                continue;
            }
            // The weight the bones leave stays on the bind pose: the exe stores
            // 1 − Σweights per vertex after loading (0x44d1b8) and starts the sum
            // from it (0x4c679f) — Medusa's collar has vertices weighted 59%.
            var rest: f32 = 1;
            for (part.influences[rg[0]..rg[1]]) |inf| rest -= inf.weight;
            var acc: [3]f32 = .{ v.pos[0] * rest, v.pos[1] * rest, v.pos[2] * rest };
            for (part.influences[rg[0]..rg[1]]) |inf| {
                const q = transform(frames.matrix(frame, inf.bone), v.pos, conv);
                for (&acc, q) |*a, c| a.* += c * inf.weight;
            }
            p.* = acc;
        }
    }
    return out;
}

test "pose: weight the bones leave stays on the bind pose" {
    // One bone moving +10 x with 60% weight: 40% of the vertex stays put.
    var infl = [_]mesh_fmt.Influence{.{ .bone = 0, .weight = 0.6 }};
    var verts = [_]mesh_fmt.Vertex{.{ .pos = .{ 1, 2, 3 }, .uv = .{ 0, 0 } }};
    var ranges = [_][2]u32{.{ 0, 1 }};
    var parts = [_]mesh_fmt.Part{.{ .name = "", .vertices = &verts, .ranges = &ranges, .influences = &infl, .triangles = &.{} }};
    const m: mesh_fmt.Mesh = .{ .arena = undefined, .parts = &parts };
    var mats = [_][12]f32{.{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 10, 0, 0 }};
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const out = try pose(arena.allocator(), m, .{ .frames = 1, .bones = 1, .matrices = &mats, .extra = &.{} }, 0, .column);
    try std.testing.expectApproxEqAbs(@as(f32, 7), out[0][0][0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2), out[0][0][1], 1e-5);
}

test transform {
    // 90° around Z (by rows: x' = -y, y' = x) plus translation.
    const m = [12]f32{ 0, -1, 0, 1, 0, 0, 0, 0, 1, 10, 0, 0 };
    try std.testing.expectEqual([3]f32{ 10, 1, 0 }, transform(&m, .{ 1, 0, 0 }, .column));
    try std.testing.expectEqual([3]f32{ 10, -1, 0 }, transform(&m, .{ 1, 0, 0 }, .row));
}

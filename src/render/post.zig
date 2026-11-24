//! A project's frame post-processing (OpenGorky rules `PostChain`, core/effect.zig `Post`):
//! built-in programs over an RGBA picture, in order. Classic has none. The editor's preview
//! and the reference of the viewer's shader (viewer/gpu/shaders/post.frag), which runs them
//! in the game (GPU renderer only).

const std = @import("std");
const num = @import("../num.zig");
const Post = @import("../effects.zig").material.Post;

/// `steps` over `px` (`w`×`h` RGBA, rows `pitch` bytes apart).
pub fn apply(steps: []const Post, px: []u8, w: usize, h: usize, pitch: usize) void {
    const fw = num.toF32(w);
    const fh = num.toF32(h);
    for (steps) |s| for (0..h) |y| {
        const row = px[y * pitch ..][0 .. w * 4];
        const fy = (num.toF32(y) + 0.5) / fh * 2 - 1;
        // A 480-line screen's odd lines, whatever the detail.
        const odd = (y * 480 / h) % 2 == 1;
        for (0..w) |x| {
            const p = row[x * 4 ..][0..3];
            var c = [3]f32{ num.toF32(p[0]), num.toF32(p[1]), num.toF32(p[2]) };
            switch (s.program) {
                // Colour ×rgb, then saturation ×k around the luminance.
                .grade => {
                    for (&c, s.rgb) |*ch, g| ch.* *= g;
                    const l = 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];
                    for (&c) |*ch| ch.* = l + (ch.* - l) * s.k;
                },
                // Darker by k toward the corners (the square of the distance from the centre).
                .vignette => {
                    const fx = (num.toF32(x) + 0.5) / fw * 2 - 1;
                    const d = 1 - s.k * (fx * fx + fy * fy) / 2;
                    for (&c) |*ch| ch.* *= d;
                },
                .scanlines => if (odd) for (&c) |*ch| {
                    ch.* *= 1 - s.k;
                },
                // Hue turned by (r − 1)·180°, saturation ×g, lightness ×b; mixed in by k.
                .hsl => {
                    const o = hsl(.{ c[0] / 255, c[1] / 255, c[2] / 255 }, (s.rgb[0] - 1) / 2, s.rgb[1], s.rgb[2]);
                    for (&c, o) |*ch, v| ch.* += (v * 255 - ch.*) * s.k;
                },
            }
            for (p, c) |*o, v| o.* = @intFromFloat(std.math.clamp(@round(v), 0, 255));
        }
    };
}

/// `c` (0…1) in HSL: hue turned by `turn` (of a full circle), saturation ×`sat` and
/// lightness ×`light` (clamped), back to RGB. gpu/shaders/post.frag does the same.
fn hsl(c: [3]f32, turn: f32, sat: f32, light: f32) [3]f32 {
    const mx = @max(c[0], c[1], c[2]);
    const mn = @min(c[0], c[1], c[2]);
    var l = (mx + mn) / 2;
    const d = mx - mn;
    var h: f32 = 0;
    var s: f32 = 0;
    if (d > 0) {
        s = if (l > 0.5) d / (2 - mx - mn) else d / (mx + mn);
        h = if (mx == c[0]) (c[1] - c[2]) / d + @as(f32, if (c[1] < c[2]) 6 else 0) else if (mx == c[1]) (c[2] - c[0]) / d + 2 else (c[0] - c[1]) / d + 4;
        h /= 6;
    }
    h += turn;
    h -= @floor(h);
    s = std.math.clamp(s * sat, 0, 1);
    l = std.math.clamp(l * light, 0, 1);
    if (s == 0) return .{ l, l, l };
    const q = if (l < 0.5) l * (1 + s) else l + s - l * s;
    const p = 2 * l - q;
    return .{ hue(p, q, h + 1.0 / 3.0), hue(p, q, h), hue(p, q, h - 1.0 / 3.0) };
}

fn hue(p: f32, q: f32, t0: f32) f32 {
    const t = t0 - @floor(t0);
    if (t < 1.0 / 6.0) return p + (q - p) * 6 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6;
    return p;
}

test "hsl" {
    // (1, 1, 1): as it is.
    var px = [4]u8{ 200, 80, 40, 255 };
    apply(&.{.{ .program = .hsl }}, &px, 1, 1, 4);
    try std.testing.expectEqualSlices(u8, &.{ 200, 80, 40 }, px[0..3]);
    // A half turn (r = 2, +180°): red-orange to its blue-cyan opposite.
    apply(&.{.{ .program = .hsl, .rgb = .{ 2, 1, 1 } }}, &px, 1, 1, 4);
    try std.testing.expectEqualSlices(u8, &.{ 40, 160, 200 }, px[0..3]);
    // Saturation 0: grey; k 0: nothing changes.
    var g = [4]u8{ 200, 80, 40, 255 };
    apply(&.{.{ .program = .hsl, .k = 0, .rgb = .{ 1, 0, 1 } }}, &g, 1, 1, 4);
    try std.testing.expectEqualSlices(u8, &.{ 200, 80, 40 }, g[0..3]);
    apply(&.{.{ .program = .hsl, .rgb = .{ 1, 0, 1 } }}, &g, 1, 1, 4);
    try std.testing.expect(g[0] == g[1] and g[1] == g[2]);
}

test "grade, vignette and scanlines" {
    var px: [2 * 4 * 4]u8 = @splat(200);
    // Grade: red ×0.5, saturation unchanged (k = 1).
    apply(&.{.{ .program = .grade, .rgb = .{ 0.5, 1, 1 } }}, &px, 2, 4, 8);
    try std.testing.expectEqual(@as(u8, 100), px[0]);
    try std.testing.expectEqual(@as(u8, 200), px[1]);
    // Saturation 0: grey.
    apply(&.{.{ .program = .grade, .k = 0 }}, &px, 2, 4, 8);
    try std.testing.expectEqual(px[1], px[0]);
    // Scanlines: screen line 1 darker by half, line 0 kept.
    var tall: [1 * 480 * 4]u8 = @splat(200);
    apply(&.{.{ .program = .scanlines, .k = 0.5 }}, &tall, 1, 480, 4);
    try std.testing.expectEqual(@as(u8, 200), tall[0]);
    try std.testing.expectEqual(@as(u8, 100), tall[4]);
    // Vignette: the corners darker than the centre.
    var sq: [9 * 9 * 4]u8 = @splat(200);
    apply(&.{.{ .program = .vignette, .k = 0.8 }}, &sq, 9, 9, 36);
    try std.testing.expect(sq[0] < sq[(4 * 9 + 4) * 4]);
    try std.testing.expectEqual(@as(u8, 200), sq[3]);
}

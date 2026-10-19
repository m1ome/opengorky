//! Integer 2D upscaling (2–4) with level-2 xBR
//! (Hyllian, as the xbr-lv2 shader). Own implementation from the algorithm description.
//!
//! For each of the four corners of pixel E, weighted differences across and along a
//! possible edge are compared over the 5×5 neighbourhood; on an edge, subpixels past
//! the smoothed line (45°, or 30° and 60° for shallow and steep edges) blend with the
//! neighbour along the edge. Sharp one-color edges become smooth while inner detail
//! stays crisp, unlike bilinear scaling.
//!
//! Transparency (color key on sprites, alpha 0) is compared like brightness, and
//! blending is premultiplied — no halos of the transparent pixels' color at edges.

const std = @import("std");
const num = @import("../num.zig");
const Allocator = std.mem.Allocator;
const Image = @import("image.zig").Image;

/// Neighbour offsets of the bottom-right corner (x, y); other corners rotate by 90°.
const Off = struct { dx: i32, dy: i32 };
const base = struct {
    const b: Off = .{ .dx = 0, .dy = -1 };
    const c: Off = .{ .dx = 1, .dy = -1 };
    const d: Off = .{ .dx = -1, .dy = 0 };
    const f: Off = .{ .dx = 1, .dy = 0 };
    const g: Off = .{ .dx = -1, .dy = 1 };
    const h: Off = .{ .dx = 0, .dy = 1 };
    const i: Off = .{ .dx = 1, .dy = 1 };
    const f4: Off = .{ .dx = 2, .dy = 0 };
    const fi4: Off = .{ .dx = 2, .dy = 1 };
    const h5: Off = .{ .dx = 0, .dy = 2 };
    const hi5: Off = .{ .dx = 1, .dy = 2 };
};

/// Corner rotation: (dx, dy) → (dy, −dx) — bottom-right → top-right → …
fn rot(o: Off, n: u2) Off {
    var r = o;
    var k: u2 = 0;
    while (k < n) : (k += 1) {
        const t = r;
        r = .{ .dx = t.dy, .dy = -t.dx };
    }
    return r;
}

/// Line constants per corner (x bottom-right, y top-right, z top-left,
/// w bottom-left), as in xbr-lv2.
const Ao = [4]f32{ 1, -1, -1, 1 };
const Bo = [4]f32{ 1, 1, -1, -1 };
const Co = [4]f32{ 1.5, 0.5, -0.5, 0.5 };
const Bx = [4]f32{ 0.5, 2, -0.5, -2 };
const Cx = [4]f32{ 1, 1, -0.5, 0 };
const By = [4]f32{ 2, 0.5, -2, -0.5 };
const Cy = [4]f32{ 2, 0, -1, 0.5 };
const Ci: f32 = 0.25;

/// "Nearly equal" threshold for the weighted difference (brightness scale 0..48).
const eq_threshold: f32 = 15;

const Px = struct {
    /// Source bytes (transparent ones zeroed) for exact comparison.
    raw: u32,
    /// premultiplied RGBA 0..1 for blending.
    pm: [4]f32,
    /// Luma, chroma and alpha for the differences.
    yuva: [4]f32,
};

fn df(a: Px, b: Px) f32 {
    return 48 * @abs(a.yuva[0] - b.yuva[0]) + 7 * @abs(a.yuva[1] - b.yuva[1]) + 6 * @abs(a.yuva[2] - b.yuva[2]) + 48 * @abs(a.yuva[3] - b.yuva[3]);
}

fn eq(a: Px, b: Px) bool {
    return df(a, b) < eq_threshold;
}

/// Edges of one pixel corner: which lines are on and the neighbour color.
const Corner = struct {
    e45i: bool = false,
    e45: bool = false,
    left: bool = false,
    up: bool = false,
    col: [4]f32 = .{ 0, 0, 0, 0 },
};

fn sat(v: f32) f32 {
    return std.math.clamp(v, 0, 1);
}

fn lerp(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    var r: [4]f32 = undefined;
    for (0..4) |j| r[j] = a[j] + (b[j] - a[j]) * t;
    return r;
}

fn cdf(a: [4]f32, b: [4]f32) f32 {
    return @abs(a[0] - b[0]) + @abs(a[1] - b[1]) + @abs(a[2] - b[2]) + @abs(a[3] - b[3]);
}

/// Upscale `src` by `k` (1…4); `k` = 1 copies.
pub fn upscale(gpa: Allocator, src: Image, k: u32) Allocator.Error!Image {
    std.debug.assert(k >= 1 and k <= 4);
    const w = src.width;
    const h = src.height;
    var out = try Image.init(gpa, w * k, h * k);
    errdefer out.deinit(gpa);
    if (w == 0 or h == 0) return out;

    const px = try gpa.alloc(Px, @as(usize, w) * h);
    defer gpa.free(px);
    for (px, 0..) |*p, n| {
        const s = src.pixels[n * 4 ..][0..4];
        const a: f32 = num.toF32(s[3]) / 255;
        const rgb = [3]f32{ num.toF32(s[0]) / 255, num.toF32(s[1]) / 255, num.toF32(s[2]) / 255 };
        const y = 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2];
        p.* = .{
            .raw = if (s[3] == 0) 0 else std.mem.readInt(u32, s, .little),
            .pm = .{ rgb[0] * a, rgb[1] * a, rgb[2] * a, a },
            // The color of a transparent pixel does not matter, only alpha.
            .yuva = if (s[3] == 0) .{ 0, 0, 0, 0 } else .{ y * a, (rgb[2] - y) * 0.564 * a, (rgb[0] - y) * 0.713 * a, a },
        };
    }

    const corners = try gpa.alloc([4]Corner, @as(usize, w) * h);
    defer gpa.free(corners);
    for (0..h) |yy| for (0..w) |xx| {
        const at = struct {
            fn get(p: []const Px, ww: u32, hh: u32, x: usize, y: usize, o: Off) Px {
                const cx = std.math.clamp(@as(i32, @intCast(x)) + o.dx, 0, @as(i32, @intCast(ww)) - 1);
                const cy = std.math.clamp(@as(i32, @intCast(y)) + o.dy, 0, @as(i32, @intCast(hh)) - 1);
                return p[@as(usize, @intCast(cy)) * ww + @as(usize, @intCast(cx))];
            }
        }.get;
        const e = px[yy * w + xx];
        for (0..4) |cn| {
            const n: u2 = @intCast(cn);
            const b = at(px, w, h, xx, yy, rot(base.b, n));
            const c = at(px, w, h, xx, yy, rot(base.c, n));
            const d = at(px, w, h, xx, yy, rot(base.d, n));
            const f = at(px, w, h, xx, yy, rot(base.f, n));
            const g = at(px, w, h, xx, yy, rot(base.g, n));
            const hh = at(px, w, h, xx, yy, rot(base.h, n));
            const i = at(px, w, h, xx, yy, rot(base.i, n));
            const f4 = at(px, w, h, xx, yy, rot(base.f4, n));
            const fi4 = at(px, w, h, xx, yy, rot(base.fi4, n));
            const h5 = at(px, w, h, xx, yy, rot(base.h5, n));
            const hi5 = at(px, w, h, xx, yy, rot(base.hi5, n));

            const wd1 = df(e, c) + df(e, g) + df(i, h5) + df(i, f4) + 4 * df(hh, f);
            const wd2 = df(hh, d) + df(hh, hi5) + df(f, fi4) + df(f, b) + 4 * df(e, i);
            const lv0 = e.raw != f.raw and e.raw != hh.raw;
            const lv1 = lv0 and ((!eq(f, b) and !eq(hh, d)) or (eq(e, i) and !eq(f, fi4) and !eq(hh, hi5)) or eq(e, g) or eq(e, c));
            const lv2_left = e.raw != g.raw and d.raw != g.raw;
            const lv2_up = e.raw != c.raw and b.raw != c.raw;
            const edr = wd1 < wd2 and lv1;
            corners[yy * w + xx][cn] = .{
                .e45i = wd1 <= wd2 and lv0,
                .e45 = edr,
                .left = 2 * df(f, g) <= df(hh, c) and lv2_left and edr,
                .up = df(f, g) >= 2 * df(hh, c) and lv2_up and edr,
                .col = if (df(e, f) <= df(e, hh)) f.pm else hh.pm,
            };
        }
    };

    const kf: f32 = @floatFromInt(k);
    const delta = 1 / kf;
    const dl = [4]f32{ 0.5 / kf, 1 / kf, 0.5 / kf, 1 / kf };
    const du = [4]f32{ 1 / kf, 0.5 / kf, 1 / kf, 0.5 / kf };
    for (0..h) |yy| for (0..w) |xx| {
        const e = px[yy * w + xx].pm;
        const cs = corners[yy * w + xx];
        for (0..k) |sy| for (0..k) |sx| {
            const fpx = (num.toF32(sx) + 0.5) / kf;
            const fpy = (num.toF32(sy) + 0.5) / kf;
            var m: [4]f32 = undefined;
            for (0..4) |j| {
                const fx = Ao[j] * fpy + Bo[j] * fpx;
                const fx_left = Ao[j] * fpy + Bx[j] * fpx;
                const fx_up = Ao[j] * fpy + By[j] * fpx;
                const cr = cs[j];
                const a45i: f32 = if (cr.e45i) sat((fx + delta - Co[j] - Ci) / (2 * delta)) else 0;
                const a45: f32 = if (cr.e45) sat((fx + delta - Co[j]) / (2 * delta)) else 0;
                const a30: f32 = if (cr.left) sat((fx_left + dl[j] - Cx[j]) / (2 * dl[j])) else 0;
                const a60: f32 = if (cr.up) sat((fx_up + du[j] - Cy[j]) / (2 * du[j])) else 0;
                m[j] = @max(@max(a30, a60), @max(a45, a45i));
            }
            var res1 = lerp(e, cs[0].col, m[0]);
            res1 = lerp(res1, lerp(e, cs[1].col, m[1]), m[1]);
            var res2 = lerp(e, cs[2].col, m[2]);
            res2 = lerp(res2, lerp(e, cs[3].col, m[3]), m[3]);
            const res = if (cdf(e, res2) >= cdf(e, res1)) res2 else res1;
            const o = out.pixels[((yy * k + sy) * out.width + xx * k + sx) * 4 ..][0..4];
            const a = res[3];
            if (a <= 0.5 / 255.0) {
                o.* = .{ 0, 0, 0, 0 };
            } else {
                for (0..3) |j| o[j] = @intFromFloat(@round(std.math.clamp(res[j] / a, 0, 1) * 255));
                o[3] = @intFromFloat(@round(std.math.clamp(a, 0, 1) * 255));
            }
        };
    };
    return out;
}

test "xbr: size and solid colour" {
    const gpa = std.testing.allocator;
    var img = try Image.init(gpa, 3, 2);
    defer img.deinit(gpa);
    for (0..6) |n| img.pixels[n * 4 ..][0..4].* = .{ 10, 200, 30, 255 };
    var out = try upscale(gpa, img, 3);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 9), out.width);
    try std.testing.expectEqual(@as(u32, 6), out.height);
    for (0..54) |n| try std.testing.expectEqualSlices(u8, &.{ 10, 200, 30, 255 }, out.pixels[n * 4 ..][0..4]);
}

test "xbr: diagonal edge smoothed, transparency without halo" {
    const gpa = std.testing.allocator;
    // A white triangle below the diagonal on transparency (transparent color is red).
    var img = try Image.init(gpa, 8, 8);
    defer img.deinit(gpa);
    for (0..8) |y| for (0..8) |x| {
        img.pixels[(y * 8 + x) * 4 ..][0..4].* = if (x <= y) .{ 255, 255, 255, 255 } else .{ 255, 0, 0, 0 };
    };
    var out = try upscale(gpa, img, 4);
    defer out.deinit(gpa);
    var partial = false;
    for (0..out.width * out.height) |n| {
        const p = out.pixels[n * 4 ..][0..4];
        // Red from transparent pixels does not leak.
        if (p[3] > 0) try std.testing.expect(p[1] == p[0] and p[2] == p[0]);
        if (p[3] > 0 and p[3] < 255) partial = true;
    }
    try std.testing.expect(partial);
}

//! Fits perspective-level background depth to our camera. Not in the exe:
//! it compensates for our camera differing from the one that rendered the background.

const std = @import("std");
const num = @import("../num.zig");
const zbuffer = @import("../formats.zig").zbuffer;
const level_files = @import("../formats.zig").level_files;
const level = @import("../formats.zig").level;
const camera = @import("../actor.zig").camera;

/// W-buffer `z = far − v·tl/65536` (0x41cf07) fitted on free battle-grid cells
/// (floor is visible there) so background depth agrees with our camera.
/// Returns (far, tl, tolerance).
pub fn fitPersp(cam: camera.Persp, cm: level_files.CombatMap, z: zbuffer.ZBuffer) ?[3]f32 {
    var pts: [fit.max_points][3]f32 = undefined;
    return fitPerspPoints(cam, gridPoints(cm, &pts), z);
}

/// Floor points of a battle grid: centres of the free cells.
pub fn gridPoints(cm: level_files.CombatMap, pts: [][3]f32) [][3]f32 {
    var n: usize = 0;
    for (0..cm.height) |j| for (0..cm.width) |i| {
        if (cm.blocked[j * cm.width + i] or n == pts.len) continue;
        pts[n] = cm.toWorld(num.toF32(i) + 0.5, num.toF32(j) + 0.5);
        n += 1;
    };
    return pts[0..n];
}

/// Background depth fit to our camera — our own compensation with no exe counterpart
/// (there the background was drawn by the same camera as the actors): our camera is
/// reconstructed from level data and does not match the rendered background exactly
/// (on 01__port_trabant feet sink ~0.1 "under" the floor at a .zbf step of 0.04);
/// without a tolerance legs and lower body get cut in stripes. Values tuned on the game levels.
pub const fit = struct {
    /// Max floor points.
    const max_points = 4096;
    /// Fewer points — no fit.
    const min_points = 5;
    /// Fit passes with rejection.
    const iterations = 6;
    /// Outlier: residual above this many medians (objects and awnings over the floor).
    const outlier_medians = 3;
    const outlier_eps = 1e-6;
    /// .zbf value step that background depth cannot resolve: 256 of 65536
    /// (the low byte of the 16-bit buffer); the tolerance is at least this.
    const zbf_step = 256;

    /// `.zbf` value under the projection of world point `wp` and its depth; null outside.
    fn sample(cam: camera.Persp, wp: [3]f32, z: zbuffer.ZBuffer) ?struct { v: u16, depth: f32 } {
        const p = cam.project(wp);
        if (p.x < 0 or p.y < 0 or p.x >= num.toF32(z.width) or p.y >= num.toF32(z.height)) return null;
        return .{ .v = z.depth[@as(usize, @intFromFloat(p.y)) * z.width + @as(usize, @intFromFloat(p.x))], .depth = -p.depth };
    }
    /// Shift of ground items toward the camera (`DrawParams.depth_bias`): the fit is
    /// accurate to ~2%, without it an item on a bed or table sinks into the background.
    pub const ground_item_bias = 0.03;

    /// Outlier threshold from the sorted residuals.
    fn limit(sorted: []const f32) f32 {
        return outlier_medians * sorted[sorted.len / 2] + outlier_eps;
    }
};

/// Same from world floor points (exploration levels without `.cfg`: centers of
/// walkable `.wm` cells at floor height). Tolerance is the 90th percentile of floor
/// residuals, at least one .zbf step (see `fit`).
pub fn fitPerspPoints(cam: camera.Persp, pts: []const [3]f32, z: zbuffer.ZBuffer) ?[3]f32 {
    // (v, depth) pairs at floor points; where the background is not floor (objects,
    // awnings) they are outliers, hence fitting with rejection.
    var vs: [fit.max_points]f32 = undefined;
    var zs: [fit.max_points]f32 = undefined;
    var n: usize = 0;
    for (pts) |wp| {
        if (n == vs.len) break;
        const sm = fit.sample(cam, wp, z) orelse continue;
        vs[n] = @floatFromInt(sm.v);
        zs[n] = sm.depth;
        n += 1;
    }
    if (n < fit.min_points) return null;
    var keep: [fit.max_points]bool = undefined;
    @memset(keep[0..n], true);
    var a: f32 = 0;
    var b: f32 = 0;
    var res: [fit.max_points]f32 = undefined;
    for (0..fit.iterations) |_| {
        var m: f32 = 0;
        var sx: f32 = 0;
        var sy: f32 = 0;
        var sxx: f32 = 0;
        var sxy: f32 = 0;
        for (0..n) |k| if (keep[k]) {
            m += 1;
            sx += vs[k];
            sy += zs[k];
            sxx += vs[k] * vs[k];
            sxy += vs[k] * zs[k];
        };
        if (m < fit.min_points) return null;
        const den = m * sxx - sx * sx;
        if (@abs(den) < 1e-12) return null;
        b = (m * sxy - sx * sy) / den;
        a = (sy - b * sx) / m;
        var sorted: [fit.max_points]f32 = undefined;
        var ns: usize = 0;
        for (0..n) |k| {
            res[k] = @abs(zs[k] - (a + b * vs[k]));
            if (keep[k]) {
                sorted[ns] = res[k];
                ns += 1;
            }
        }
        std.mem.sort(f32, sorted[0..ns], {}, std.sort.asc(f32));
        const lim = fit.limit(sorted[0..ns]);
        for (0..n) |k| keep[k] = res[k] <= lim;
    }
    if (b >= 0) return null;
    std.mem.sort(f32, res[0..n], {}, std.sort.asc(f32));
    return .{ a, -b * 65536, @max(res[n * 9 / 10], -b * fit.zbf_step) };
}

/// Background depth tolerance for given far and tl (exe formula without fitting):
/// 90th percentile of floor residuals after outlier rejection, at least one
/// .zbf step (see `fit`). null when fewer than `fit.min_points` points.
pub fn perspTolerance(cam: camera.Persp, pts: []const [3]f32, z: zbuffer.ZBuffer, far: f32, tl: f32) ?f32 {
    var res: [fit.max_points]f32 = undefined;
    const n = residuals(cam, pts, z, far, tl, &res);
    if (n < fit.min_points) return null;
    std.mem.sort(f32, res[0..n], {}, std.sort.asc(f32));
    const lim = fit.limit(res[0..n]);
    var m: usize = 0;
    while (m < n and res[m] <= lim) m += 1;
    return @max(res[m * 9 / 10], tl * fit.zbf_step / 65536);
}

/// Largest floor residual up to 2·`tol` for given far and tl: how far the background
/// floor strays from our camera's beyond the tolerance (a raised platform, rejected
/// as an outlier against a flat floor's median, still lies within it; residuals
/// beyond are objects). Shadow planes need it, see the viewer's depth.shadowBias.
pub fn perspSpread(cam: camera.Persp, pts: []const [3]f32, z: zbuffer.ZBuffer, far: f32, tl: f32, tol: f32) f32 {
    var res: [fit.max_points]f32 = undefined;
    var m: f32 = 0;
    for (res[0..residuals(cam, pts, z, far, tl, &res)]) |r| if (r <= 2 * tol) {
        m = @max(m, r);
    };
    return m;
}

/// Floor residuals |depth − W(v)| into `res`; their count.
fn residuals(cam: camera.Persp, pts: []const [3]f32, z: zbuffer.ZBuffer, far: f32, tl: f32, res: *[fit.max_points]f32) usize {
    var n: usize = 0;
    for (pts) |wp| {
        if (n == res.len) break;
        const sm = fit.sample(cam, wp, z) orelse continue;
        res[n] = @abs(sm.depth - level.perspDepth(far, tl, sm.v));
        n += 1;
    }
    return n;
}

/// Line y = a·x + b through points (x, y) by least squares, refitted once without
/// the fifth of points farthest from the first line (objects standing on the floor).
/// The editor maps a painted depth onto the exe's W-buffer with it. null: under 3
/// points or all x equal.
pub fn lineFit(pts: [][2]f32) ?[2]f32 {
    var ab = lineOnce(pts) orelse return null;
    const Ctx = struct { ab: [2]f32 };
    std.mem.sort([2]f32, pts, Ctx{ .ab = ab }, struct {
        fn lt(c: Ctx, p: [2]f32, q: [2]f32) bool {
            return @abs(c.ab[0] * p[0] + c.ab[1] - p[1]) < @abs(c.ab[0] * q[0] + c.ab[1] - q[1]);
        }
    }.lt);
    ab = lineOnce(pts[0 .. pts.len - pts.len / 5]) orelse ab;
    return ab;
}

fn lineOnce(pts: []const [2]f32) ?[2]f32 {
    if (pts.len < 3) return null;
    var sx: f64 = 0;
    var sy: f64 = 0;
    var sxx: f64 = 0;
    var sxy: f64 = 0;
    for (pts) |p| {
        sx += p[0];
        sy += p[1];
        sxx += @as(f64, p[0]) * p[0];
        sxy += @as(f64, p[0]) * p[1];
    }
    const n: f64 = @floatFromInt(pts.len);
    const den = n * sxx - sx * sx;
    if (@abs(den) < 1e-9) return null;
    const a = (n * sxy - sx * sy) / den;
    return .{ @floatCast(a), @floatCast((sy - a * sx) / n) };
}

test lineFit {
    var pts: [10][2]f32 = undefined;
    for (&pts, 0..) |*p, i| {
        const x: f32 = @floatFromInt(i);
        p.* = .{ x, 2 * x + 1 };
    }
    pts[3][1] = 100; // a crate on the floor
    const ab = lineFit(&pts).?;
    try std.testing.expectApproxEqAbs(@as(f32, 2), ab[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 1), ab[1], 1e-3);
}

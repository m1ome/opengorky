//! Orthographic camera of large levels (perspective=0): isometry reconstructed
//! from gorky17.exe (0x496790 background → world, 0x496860 world → background).
//!
//! World: X, Y — ground plane, Z — up; unit is a background pixel. The camera is
//! rotated around Z by π·(−1/6) = −30° (constants 0x50a3f8, 0x50a400) and tilted 45°:
//! depth and height shrink by √2 (constant 1.4121 at 0x50a408).

const std = @import("std");
const vec = @import("../vec.zig");

pub const angle: f32 = -std.math.pi / 6.0;
pub const k: f32 = 1.4121;

const c = @cos(angle);
const s = @sin(angle);

/// Ground point at height `h` under background pixel (x, y) (0x496790).
fn screenToWorld(x: f32, y: f32, h: f32) [3]f32 {
    const yy = y * k + h;
    return .{ c * x - s * yy, s * x + c * yy, h };
}

const Projected = struct {
    x: f32,
    y: f32,
    /// Larger is closer to the viewer (sorting and z-test).
    depth: f32,
};

/// Background pixel of a world point — inverse of `screenToWorld`.
fn worldToScreen(p: [3]f32) Projected {
    const x = c * p[0] + s * p[1];
    const yy = -s * p[0] + c * p[1];
    return .{ .x = x, .y = (yy - p[2]) / k, .depth = (yy + p[2]) / k };
}

test "round trip" {
    const w = screenToWorld(1500, 1200, 0);
    const p = worldToScreen(w);
    try std.testing.expectApproxEqAbs(@as(f32, 1500), p.x, 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 1200), p.y, 1e-2);
    // Raising a point by h lifts it on screen by h/k pixels.
    const up = worldToScreen(.{ w[0], w[1], 10 });
    try std.testing.expectApproxEqAbs(p.y - 10 / k, up.y, 1e-2);
}

/// Perspective camera (battles and small rooms, perspective=1). Parameters are
/// level variables from `initCamera()`. Conventions fitted to game data:
/// world → camera `(X·s, Z·s, Y·s)`,
/// where `s = cameraScale` (default 0.0057), the camera up axis is Y, the right axis
/// `up × forward`, the view angle `angle` (degrees) spans the background width,
/// the projection center is the background center.
pub const Persp = struct {
    eye: [3]f32,
    fwd: [3]f32,
    right: [3]f32,
    up: [3]f32,
    focal: f32,
    /// Vertical focal length: focal / the level's aspectRatio (0x42182a → 0x51ecc4,
    /// default 1). The exe multiplies the vertical size of the view frustum by
    /// aspectRatio·H/W (0x42d297…0x42d2a9, 0x42d38a…0x42d396); at 1 pixels are
    /// square. aspectRatio is set by 04__city_hotelentrance (1.5),
    /// 04__city_trapatthetruck (0.97), 05__lab_group3 (0.98), 05_laboratory_duty (0.88).
    focal_y: f32,
    cx: f32,
    cy: f32,
    scale: f32,
    /// Floor height in camera coordinates (`zLevel`).
    zlevel: f32,

    /// With bank `camBan` (degrees, 0x421170 → 0x42d49f): the up vector for the
    /// view is (−sin b, cos b, 0) instead of (0, 1, 0).
    pub fn initBank(eye: [3]f32, aim: [3]f32, angle_deg: f32, camera_scale: f32, zlevel: f32, bg_w: f32, bg_h: f32, bank_deg: f32) ?Persp {
        const d = vec.sub(aim, eye);
        if (vec.dot(d, d) < 1e-12 or angle_deg <= 0) return null;
        const f = vec.normalize(d);
        const b = bank_deg * 0.017453292;
        const up0 = [3]f32{ -@sin(b), @cos(b), 0 };
        // Right axis f × up, up r × f: the view (together with the world → camera
        // (X, Z, Y) swap) then has the isometry's orientation and battle cells land as
        // in the exe (first battle: sphinx left by the bulldozer, heroes right by the
        // pipe; .zbf depth fits better in every battle).
        const rc = vec.cross(f, up0);
        // Looking along up leaves no right axis (otherwise NaN in the whole projection).
        if (vec.dot(rc, rc) < 1e-12) return null;
        const r = vec.normalize(rc);
        return .{
            .eye = eye,
            .fwd = f,
            .right = r,
            .up = vec.cross(r, f),
            // The view angle spans the BACKGROUND width (0x42d28d–0x42d31f: the frame
            // half-width 640 in fractions is t·640/W, W the background width [0x54c168]),
            // i.e. focal W/2 / tan(angle/2); for 960×720 backgrounds 1.5× larger than 320/tan.
            .focal = bg_w / 2 / @tan(angle_deg * std.math.pi / 360.0),
            .focal_y = bg_w / 2 / @tan(angle_deg * std.math.pi / 360.0),
            .cx = bg_w / 2,
            .cy = bg_h / 2,
            .scale = if (camera_scale > 0) camera_scale else 0.0057,
            .zlevel = zlevel,
        };
    }

    /// The level's aspectRatio (≤ 0 means 1, 0x421811…0x42182a).
    pub fn withAspect(self: Persp, aspect: f32) Persp {
        var x = self;
        x.focal_y = self.focal / (if (aspect > 0) aspect else 1);
        return x;
    }

    pub fn project(self: Persp, p: [3]f32) Projected {
        const q = [3]f32{ p[0] * self.scale, p[2] * self.scale, p[1] * self.scale };
        const d = vec.sub(q, self.eye);
        const zc = @max(1e-4, vec.dot(d, self.fwd));
        return .{
            .x = self.cx + vec.dot(d, self.right) / zc * self.focal,
            .y = self.cy - vec.dot(d, self.up) / zc * self.focal_y,
            .depth = -zc,
        };
    }

    /// Depth (as `project`) of the plane Z = `z` point under a background pixel.
    fn planeDepth(self: Persp, x: f32, y: f32, z: f32) f32 {
        const a = (x - self.cx) / self.focal;
        const b = (self.cy - y) / self.focal_y;
        // Ray fwd + right·a + up·b: its projection on fwd is 1, so t = zc.
        const dy = self.fwd[1] + self.right[1] * a + self.up[1] * b;
        if (@abs(dy) < 1e-6) return -std.math.inf(f32);
        return -((z * self.scale - self.eye[1]) / dy);
    }

    /// Floor point (plus height `h` in world units) under a background pixel.
    fn unproject(self: Persp, x: f32, y: f32, h: f32) [3]f32 {
        const a = (x - self.cx) / self.focal;
        const b = (self.cy - y) / self.focal_y;
        const dir = [3]f32{
            self.fwd[0] + self.right[0] * a + self.up[0] * b,
            self.fwd[1] + self.right[1] * a + self.up[1] * b,
            self.fwd[2] + self.right[2] * a + self.up[2] * b,
        };
        const plane = self.zlevel + h * self.scale;
        const t = if (@abs(dir[1]) > 1e-6) (plane - self.eye[1]) / dir[1] else 0;
        const q = [3]f32{ self.eye[0] + dir[0] * t, self.eye[1] + dir[1] * t, self.eye[2] + dir[2] * t };
        return .{ q[0] / self.scale, q[2] / self.scale, q[1] / self.scale };
    }
};

pub const Camera = union(enum) {
    ortho,
    persp: Persp,

    pub fn project(self: Camera, p: [3]f32) Projected {
        return switch (self) {
            .ortho => worldToScreen(p),
            .persp => |pc| pc.project(p),
        };
    }

    /// Depth (as `project`) of the plane Z = `z` point under background pixel (x, y).
    pub fn planeDepth(self: Camera, x: f32, y: f32, z: f32) f32 {
        return switch (self) {
            // y = (yy − z)/k, depth = (yy + z)/k.
            .ortho => y + 2 * z / k,
            .persp => |pc| pc.planeDepth(x, y, z),
        };
    }

    /// The level's aspectRatio (1 for isometry): the exe stretches actor models
    /// vertically by it (model matrix m22, 0x44f604) so the vertically squeezed frame
    /// does not flatten figures.
    pub fn aspect(self: Camera) f32 {
        return switch (self) {
            .ortho => 1,
            .persp => |pc| pc.focal / pc.focal_y,
        };
    }

    pub fn unproject(self: Camera, x: f32, y: f32, h: f32) [3]f32 {
        return switch (self) {
            .ortho => screenToWorld(x, y, h),
            .persp => |pc| pc.unproject(x, y, h),
        };
    }
};

test "looking along the up axis gives no camera" {
    try std.testing.expect(Persp.initBank(.{ 0, 5, 0 }, .{ 0, 0, 0 }, 50, 0, 0, 640, 480, 0) == null);
}

test "persp round trip" {
    // Barge camera (01__port_barge).
    const pc = Persp.initBank(.{ -10.851, 3.44, -0.057 }, .{ -6.708, -1.168, 0.161 }, 50, 0, -0.45, 1400, 550, 0).?;
    const w = pc.unproject(700, 400, 0);
    const p = pc.project(w);
    try std.testing.expectApproxEqAbs(@as(f32, 700), p.x, 0.05);
    try std.testing.expectApproxEqAbs(@as(f32, 400), p.y, 0.05);
    // Floor at height zLevel/s.
    try std.testing.expectApproxEqAbs(@as(f32, -0.45 / 0.0057), w[2], 0.01);
}

test "aspectRatio squeezes vertical" {
    const pc = Persp.initBank(.{ 0, 3, -6 }, .{ 0, 0, 0 }, 50, 0.0057, 0, 1280, 960, 0).?;
    const pa = pc.withAspect(1.5);
    const p = [3]f32{ 200, -150, 40 };
    const a = pc.project(p);
    const b = pa.project(p);
    try std.testing.expectApproxEqAbs(a.x, b.x, 1e-3);
    try std.testing.expectApproxEqAbs((a.y - pc.cy) / 1.5, b.y - pa.cy, 1e-3);
    const w = pa.unproject(b.x, b.y, 0);
    const back = pa.project(w);
    try std.testing.expectApproxEqAbs(b.x, back.x, 0.05);
    try std.testing.expectApproxEqAbs(b.y, back.y, 0.05);
}

test "plane depth matches projection" {
    const p = [3]f32{ 120, -340, -79 };
    const q = worldToScreen(p);
    const ortho: Camera = .ortho;
    try std.testing.expectApproxEqAbs(q.depth, ortho.planeDepth(q.x, q.y, p[2]), 1e-3);
    const pc = Persp.initBank(.{ 0, 3, -6 }, .{ 0, 0, 0 }, 50, 0.0057, 0, 1280, 960, 0) orelse return error.NoCamera;
    const cam: Camera = .{ .persp = pc };
    const r = cam.project(p);
    try std.testing.expectApproxEqRel(r.depth, cam.planeDepth(r.x, r.y, p[2]), 1e-3);
}

/// R = Rx(a)·Ry(b)·Rz(c), by rows, for a column vector (0x429340/80/c0, 0x47cd30).
pub fn rotationXYZ(a: [3]f32) [9]f32 {
    const cx = @cos(a[0]);
    const sx = @sin(a[0]);
    const cy = @cos(a[1]);
    const sy = @sin(a[1]);
    const cz = @cos(a[2]);
    const sz = @sin(a[2]);
    const rx = [9]f32{ 1, 0, 0, 0, cx, -sx, 0, sx, cx };
    const ry = [9]f32{ cy, 0, -sy, 0, 1, 0, sy, 0, cy };
    const rz = [9]f32{ cz, -sz, 0, sz, cz, 0, 0, 0, 1 };
    return mulMat(rx, mulMat(ry, rz));
}

fn mulMat(a: [9]f32, b: [9]f32) [9]f32 {
    var o: [9]f32 = undefined;
    for (0..3) |i| for (0..3) |j| {
        o[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j];
    };
    return o;
}

/// Bone rotation without translation, B·v.
pub fn mulVecT(m: [9]f32, v: [3]f32) [3]f32 {
    return .{
        m[0] * v[0] + m[3] * v[1] + m[6] * v[2],
        m[1] * v[0] + m[4] * v[1] + m[7] * v[2],
        m[2] * v[0] + m[5] * v[1] + m[8] * v[2],
    };
}

pub fn mulVec(m: [9]f32, v: [3]f32) [3]f32 {
    return .{
        m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
        m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
        m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
    };
}

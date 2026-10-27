//! Background depth for the actor layer: floor plane fit to .zbf, depth tolerance,
//! shadow offset (our compensation for the camera mismatch; numbers in `render_layer.fit`).

const floor_mod = og.world.floor;
const level_view = @import("../level.zig");
const LevelView = level_view.LevelView;
const og = @import("opengorky");
const lf = og.formats.level_files;
const render_layer = og.render.layer;

/// Floor points for the depth fit: centres of every other walkable `.wm` cell
/// at floor height.
fn walkPoints(self: *LevelView, pts: *[4096][3]f32) [][3]f32 {
    const wm = self.world.walk_map orelse return pts[0..0];
    var n: usize = 0;
    const cs = lf.WalkMap.cell_size;
    var y: usize = 0;
    while (y < wm.height) : (y += 2) {
        var x: usize = 0;
        while (x < wm.width) : (x += 2) {
            if (n == pts.len) break;
            if (!wm.at(x, y).walkable()) continue;
            const bg = [2]f32{ og.num.toF32(x * cs) + cs / 2, og.num.toF32(y * cs) + cs / 2 };
            pts[n] = floor_mod.groundAt(self.world, bg);
            n += 1;
        }
    }
    return pts[0..n];
}

/// Background depth tolerance for levels with a `.cfg` but no battle grid
/// (01_port_silos, 01_port_chief, 05_laboratory_duty, _reactor): 90th percentile
/// of floor residuals, at least one `.zbf` step (once per level). The camera
/// matches the exe, but `.wm` and the background floor disagree slightly: on the
/// round platform in 01_port_silos the background floor is 1–3 `.zbf` steps
/// closer than the actor floor plane, and shadows (shifted toward the camera by
/// only 0.002·tl, half a step) were torn into stripes by the depth test.
fn cfgTol(self: *LevelView, cam: og.actor.camera.Persp, z: og.formats.zbuffer.ZBuffer, far: f32, tl: f32) f32 {
    if (self.cfg_tol) |t| return t;
    var pts: [4096][3]f32 = undefined;
    const t = og.render.depth_fit.perspTolerance(cam, walkPoints(self, &pts), z, far, tl) orelse 0;
    self.cfg_tol = t;
    return t;
}

/// Depth fit over walkable `.wm` cells (once per level).
fn walkFit(self: *LevelView, cam: og.actor.camera.Persp, z: og.formats.zbuffer.ZBuffer) ?[3]f32 {
    if (self.walk_fit_done) return self.walk_fit;
    self.walk_fit_done = true;
    if (self.world.walk_map == null) return null;
    var buf: [4096][3]f32 = undefined;
    const pts = walkPoints(self, &buf);
    const n = pts.len;
    self.walk_fit = og.render.depth_fit.fitPerspPoints(cam, pts[0..n], z);
    // The exe formula (far = tl = frontPlane − backPlane) matches the floor
    // better almost everywhere: with few floor cells near walls (04_city_shop,
    // 04_city_tenement) a fitted line skews distant depth and a crate deep in the
    // shop hid behind the background. The model with the smaller floor
    // tolerance wins; the fit stays where the formula fails (01_port_worker).
    const tl = planeSpan(self) orelse return self.walk_fit;
    if (tl > 0) if (og.render.depth_fit.perspTolerance(cam, pts[0..n], z, tl, tl)) |et| {
        if (self.walk_fit == null or et <= self.walk_fit.?[2]) self.walk_fit = .{ tl, tl, et };
    };
    return self.walk_fit;
}

/// The level's frontPlane − backPlane; null without a level.
fn planeSpan(self: *LevelView) ?f32 {
    const l = self.world.level orelse return null;
    return og.fields.getF(l, "frontPlane") - og.fields.getF(l, "backPlane");
}

pub fn depthSource(self: *LevelView) render_layer.DepthSource {
    if (self.debug.no_depth) return .none;
    const z = self.level.heights orelse return .none;
    switch (self.world.cam) {
        .ortho => {
            const cfg = self.level.ortho orelse return .none;
            return .{ .heights = .{ .z = z, .cfg = cfg } };
        },
        // Background depth (0x41cf07) is a W-buffer: on battle maps far and tl
        // are fitted to the grid, otherwise from `.cfg`, without it far = tl =
        // frontPlane − backPlane (initCamera).
        .persp => |cam| {
            if (self.world.combat_map) |cm| if (og.render.depth_fit.fitPersp(cam, cm, z)) |ft| return .{ .persp = .{ .z = z, .far = ft[0], .tl = ft[1], .tol = ft[2] } };
            if (self.level.persp) |pc| return .{ .persp = .{ .z = z, .far = pc.far(), .tl = pc.tl, .tol = cfgTol(self, cam, z, pc.far(), pc.tl) } };
            // No `.cfg`: fit to walkable `.wm` cells (the fallback far = tl
            // from the planes hides actors in 01_port_worker).
            if (walkFit(self, cam, z)) |ft| return .{ .persp = .{ .z = z, .far = ft[0], .tl = ft[1], .tol = ft[2] } };
            const tl = planeSpan(self) orelse return .none;
            if (tl <= 0) return .none;
            return .{ .persp = .{ .z = z, .far = tl, .tl = tl } };
        },
    }
}

/// Shadow plane offset toward the camera (0x419910: −0.002 of normalised depth,
/// constant 0x508560) in layer depth units: isometric — 0.002·(frontPlane −
/// backPlane) (layer depth unit = world unit along the view); perspective —
/// 0.002 of the W-buffer range, plus our compensation: the floor's largest
/// residual beyond `tol`. The shadow plane is the floor itself, and `tol` (90th
/// percentile) leaves the rest of the floor torn into stripes by the depth test (the
/// raised platform of 01__port_silos: 1–2 .zbf steps beyond it).
pub fn shadowBias(self: *LevelView, src: render_layer.DepthSource) f32 {
    return switch (src) {
        .persp => |pz| 0.002 * pz.tl + @max(0, floorSpread(self, pz) - pz.tol),
        else => 0.002 * @abs(planeSpan(self) orelse 0),
    };
}

/// Largest floor residual for this depth source (battle grid or walkable `.wm`
/// cells; once per level).
fn floorSpread(self: *LevelView, pz: @FieldType(render_layer.DepthSource, "persp")) f32 {
    if (self.floor_spread) |t| return t;
    const cam = switch (self.world.cam) {
        .persp => |p| p,
        else => return 0,
    };
    var pts: [4096][3]f32 = undefined;
    const fp = if (self.world.combat_map) |cm| og.render.depth_fit.gridPoints(cm, &pts) else walkPoints(self, &pts);
    const t = og.render.depth_fit.perspSpread(cam, fp, pz.z, pz.far, pz.tl, pz.tol);
    self.floor_spread = t;
    return t;
}

//! Draws 3D actors over an orthographic level background: a software rasterizer
//! into a 640×480 layer with a depth test against the background height map (`.zbf`).

const std = @import("std");
const vec = @import("../vec.zig");
const num = @import("../num.zig");
const Allocator = std.mem.Allocator;
const mesh = @import("../formats.zig").mesh;
const Image = @import("../formats.zig").image.Image;
const zbuffer = @import("../formats.zig").zbuffer;
const sprite = @import("../formats.zig").sprite;
const level_mod = @import("../formats.zig").level;
const skin = @import("../actor.zig").skin;
const camera = @import("../actor.zig").camera;
const model_cache = @import("../actor.zig").model_cache;
const Model = model_cache.Model;
const raster = @import("raster.zig");
const level_files = @import("../formats.zig").level_files;

/// Where the background surface depth for actor occlusion comes from.
pub const DepthSource = union(enum) {
    none,
    /// Orthographic levels: `.zbf` is a height map.
    heights: struct { z: zbuffer.ZBuffer, cfg: level_mod.OrthoCfg },
    /// Perspective levels: `.zbf` is a W-buffer, depth `far − v·tl/65536` (level.PerspCfg).
    /// `tol`: the background counts as this much farther (our camera's error against
    /// the rendered background, see depth_fit.fitPerspPoints).
    persp: struct { z: zbuffer.ZBuffer, far: f32, tl: f32, tol: f32 = 0 },
};

/// Level light (`.lts`): ambient, directional (direction (1, 0.3, 0.7) hard-coded
/// in the exe) and point lamps; defaults 0.3 and 0.5 (0x47f5d0).
const Lighting = struct {
    ambient: [3]f32 = .{ 0.3, 0.3, 0.3 },
    directional: [3]f32 = .{ 0.5, 0.5, 0.5 },
    omni: []const level_files.Omni = &.{},

    /// Vertex color (0x47e1f0): ambient + lamps (color · cosθ · (1 − d²/range²)) +
    /// directional · max(0, N·D); channels capped at 1. `n` is a unit normal.
    fn color(self: Lighting, pos: [3]f32, n: [3]f32) [3]f32 {
        var c = self.ambient;
        for (self.omni) |o| {
            const l = [3]f32{ o.pos[0] - pos[0], o.pos[1] - pos[1], o.pos[2] - pos[2] };
            const dot = n[0] * l[0] + n[1] * l[1] + n[2] * l[2];
            if (dot <= 0) continue;
            const d2 = l[0] * l[0] + l[1] * l[1] + l[2] * l[2];
            const att = 1 - d2 / (o.range * o.range);
            if (att <= 0) continue;
            const k = att * dot / @sqrt(d2);
            for (&c, o.color) |*ch, oc| ch.* += oc * k;
        }
        const dir = comptime vec.normalize(.{ 1, 0.3, 0.7 });
        const nd = n[0] * dir[0] + n[1] * dir[1] + n[2] * dir[2];
        if (nd > 0) for (&c, self.directional) |*ch, dc| {
            ch.* += dc * nd;
        };
        for (&c) |*ch| ch.* = @min(ch.*, 1);
        return c;
    }
};

/// Actor layer for a `w×h` window with top-left `origin` (background pixels).
pub const Layer = struct {
    canvas: raster.Canvas,
    /// Debug: shadow pixels rejected by the depth test are drawn red.
    shadow_debug: bool = false,
    origin: [2]f32 = .{ 0, 0 },
    /// Actor lighting from `.lts` (0x47f070, 0x47e1f0).
    light: Lighting = .{},
    /// 512×512 shadow mask over the whole layer (0x56f2e8, buffer 0x40d570): 1 — shadowed.
    shadow: []u8,
    /// 8×8 layer tiles (0x54b200): floor height of the first actor whose shadow touched
    /// them (its floor plane is the depth of the tile quad's four corners, 0x419e44).
    shadow_tiles: [shadow_grid * shadow_grid]?f32 = @splat(null),
    /// Additive passes (ice, shock, materialization glow): drawn over the layer
    /// additively; `glow_used` — whether anything was drawn.
    glow: Image,
    glow_used: bool = false,
    /// Screen-blended billboards (ONE / INVSRCCOLOR), drawn over the layer with that blend.
    screen: Image,
    screen_used: bool = false,
    /// Screen bounds of the last drawn model (left, top, right, bottom; layer
    /// coordinates) — for the selected-hero frame (+0x64..+0x70, 0x45b920).
    bbox: [4]f32 = .{ 0, 0, 0, 0 },
    /// Canvas pixels per 640×480 screen pixel (port: models at window resolution;
    /// 1 in the exe). External coordinates (`origin`, `bbox`, depth) are screen pixels.
    ss: u32 = 1,
    /// Background depth per screen pixel (with `ss` > 1; the canvas reads it through NaN).
    base_depth: []f32 = &.{},
    /// The canvas is fully cleared (from now on `begin` clears only what was drawn).
    fresh: bool = false,
    /// Background depth without object z-frames for `base_key` — with the same camera
    /// and background `begin` copies it instead of recomputing.
    base_cache: []f32 = &.{},
    base_key: ?BaseKey = null,
    /// Last shadow composite (viewer command `shadowstat`): canvas pixels with
    /// coverage and, of those, the ones cut by the background depth test (only
    /// with `ss` > 1, where background depth is separate from the models).
    shadow_stat: struct { lit: u32 = 0, cut_bg: u32 = 0 } = .{},

    const BaseKey = struct { origin: [2]f32, src: DepthSource };

    const mask_size = 512;
    /// Side of the layer tile grid for the shadow plane (8×8, 0x54b200).
    const shadow_grid = 8;

    /// Layer of `w×h` screen pixels with a canvas `ss` times finer.
    pub fn initScaled(gpa: Allocator, w: u32, h: u32, ss: u32) !Layer {
        var canvas = try raster.Canvas.init(gpa, w * ss, h * ss, .{ 0, 0, 0, 0 });
        errdefer canvas.deinit(gpa);
        var glow = try Image.init(gpa, w * ss, h * ss);
        errdefer glow.deinit(gpa);
        @memset(glow.pixels, 0);
        canvas.glow_px = glow.pixels;
        var screen = try Image.init(gpa, w * ss, h * ss);
        errdefer screen.deinit(gpa);
        @memset(screen.pixels, 0);
        const shadow = try gpa.alloc(u8, mask_size * mask_size);
        errdefer gpa.free(shadow);
        const base: []f32 = if (ss > 1) try gpa.alloc(f32, @as(usize, w) * h) else &.{};
        errdefer if (ss > 1) gpa.free(base);
        const cache = try gpa.alloc(f32, @as(usize, w) * h);
        if (ss > 1) canvas.base = .{ .depth = base, .w = w, .ss = ss };
        return .{ .canvas = canvas, .glow = glow, .screen = screen, .shadow = shadow, .ss = ss, .base_depth = base, .base_cache = cache };
    }

    pub fn deinit(self: *Layer, gpa: Allocator) void {
        if (self.base_depth.len > 0) gpa.free(self.base_depth);
        gpa.free(self.base_cache);
        gpa.free(self.shadow);
        self.glow.deinit(gpa);
        self.screen.deinit(gpa);
        self.canvas.deinit(gpa);
    }

    /// Actor shadow (0x419970, 0x41a8c0): triangles of the mesh's main part
    /// (all of them for rura and fang) are projected from light point `light` onto the
    /// actor's floor plane (z of its position) into the 512×512 mask without a depth test;
    /// 80×60 tiles touched by the shadow remember the floor height (the first actor wins).
    pub fn castShadow(self: *Layer, arena: Allocator, cam: camera.Camera, model: *const Model, p: Placement, light: [3]f32, all_parts: bool) !void {
        // Zeroed planes (`.2s`): no triangle faces the light (0x41aa3a, s ≤ 1e-4).
        if (model.two_sided) return;
        const zg = p.pos[2];
        if (light[2] <= zg + 1) return;
        const frame = @min(p.frame, model.frames.frames -| 1);
        const pts = try skin.pose(arena, model.mesh, model.frames, frame, .row);
        var main: usize = 0;
        for (model.mesh.parts, 0..) |part, i| {
            if (part.triangles.len > model.mesh.parts[main].triangles.len) main = i;
        }
        const s = p.scale * model.unitScale();
        const ca = @cos(p.angle);
        const sa = @sin(p.angle);
        const w: f32 = @floatFromInt(self.canvas.img.width);
        const h: f32 = @floatFromInt(self.canvas.img.height);
        const ssf: f32 = @floatFromInt(self.ss);
        // Screen → mask (0x40d810): bx = 256 + 255·ndc.x, by = 256 − 255·ndc.y.
        const kx = 2 * 255 / w;
        const ky = 2 * 255 / h;
        var lo = [2]f32{ std.math.inf(f32), std.math.inf(f32) };
        var hi = [2]f32{ -std.math.inf(f32), -std.math.inf(f32) };
        for (model.mesh.parts, pts, 0..) |part, ppts, pi| {
            if (!all_parts and pi != main) continue;
            const proj = try arena.alloc([2]f32, ppts.len);
            for (ppts, proj) |v, *o| {
                var wv = model_cache.toWorld(model, v, s, p.pos, ca, sa);
                // Above the light — no shadow (the ray never reaches the floor).
                if (wv[2] >= light[2] - 0.5) wv[2] = light[2] - 0.5;
                const t = (zg - light[2]) / (wv[2] - light[2]);
                const g = [3]f32{ light[0] + (wv[0] - light[0]) * t, light[1] + (wv[1] - light[1]) * t, zg };
                const q = cam.project(g);
                const sx = (q.x - self.origin[0]) * ssf;
                const sy = (q.y - self.origin[1]) * ssf;
                lo = .{ @min(lo[0], sx), @min(lo[1], sy) };
                hi = .{ @max(hi[0], sx), @max(hi[1], sy) };
                o.* = .{ 1 + sx * kx, 1 + sy * ky };
            }
            for (part.triangles) |tri| self.shadowTri(.{ proj[tri[0]], proj[tri[1]], proj[tri[2]] });
        }
        if (hi[0] < 0 or hi[1] < 0 or lo[0] >= w or lo[1] >= h) return;
        const g = shadow_grid;
        const tw = w / g;
        const th = h / g;
        const c0: usize = @intFromFloat(std.math.clamp(@floor(lo[0] / tw), 0, g - 1));
        const c1: usize = @intFromFloat(std.math.clamp(@floor(hi[0] / tw), 0, g - 1));
        const r0: usize = @intFromFloat(std.math.clamp(@floor(lo[1] / th), 0, g - 1));
        const r1: usize = @intFromFloat(std.math.clamp(@floor(hi[1] / th), 0, g - 1));
        for (r0..r1 + 1) |r| for (c0..c1 + 1) |col| {
            if (self.shadow_tiles[r * g + col] == null) self.shadow_tiles[r * g + col] = zg;
        };
    }

    /// Fills a mask triangle with ones (0x43e100): pixel centers.
    fn shadowTri(self: *Layer, v: [3][2]f32) void {
        const n: i32 = mask_size;
        // In float before the cast: a point behind a perspective camera goes beyond i32.
        const x0: i32 = @intFromFloat(std.math.clamp(@floor(@min(v[0][0], v[1][0], v[2][0])), 0, mask_size));
        const x1: i32 = @intFromFloat(std.math.clamp(@ceil(@max(v[0][0], v[1][0], v[2][0])), -1, mask_size - 1));
        const y0: i32 = @intFromFloat(std.math.clamp(@floor(@min(v[0][1], v[1][1], v[2][1])), 0, mask_size));
        const y1: i32 = @intFromFloat(std.math.clamp(@ceil(@max(v[0][1], v[1][1], v[2][1])), -1, mask_size - 1));
        if (x0 > x1 or y0 > y1) return;
        const area = (v[1][0] - v[0][0]) * (v[2][1] - v[0][1]) - (v[2][0] - v[0][0]) * (v[1][1] - v[0][1]);
        if (@abs(area) < 1e-6) return;
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) {
                const px = num.toF32(x) + 0.5;
                const py = num.toF32(y) + 0.5;
                const w0 = ((v[1][0] - px) * (v[2][1] - py) - (v[2][0] - px) * (v[1][1] - py)) / area;
                const w1 = ((v[2][0] - px) * (v[0][1] - py) - (v[0][0] - px) * (v[2][1] - py)) / area;
                if (w0 < 0 or w1 < 0 or 1 - w0 - w1 < 0) continue;
                self.shadow[@intCast(y * n + x)] = 1;
            }
        }
    }

    /// Shadow composite after the actors (0x40d150, called at 0x4209c6 after all
    /// models and the battle grid): the mask shrinks into a 256×256 texture (texel is
    /// a 2×2 sum, 0…4) and is drawn as the 80×60 tile quads the shadow touched, with
    /// bilinear sampling (0x406da6). Color is `dst·(1 − I·coverage)`
    /// (mode 3 at 0x408ad0: ZERO, INVSRCCOLOR; texture × vertex color I). The depth
    /// test is LESSEQUAL without writes (0x408930, 0x408a40): the quad depth is the
    /// floor plane of the first actor touching the tile, moved toward the camera by
    /// 0.002 of the depth range (0x419910, constant 0x508560) — `bias` in layer depth
    /// buffer units. Empty layer pixels (background) get black with
    /// alpha I·coverage.
    pub fn compositeShadow(self: *Layer, cam: camera.Camera, intensity: f32, bias: f32) void {
        const ss = self.ss;
        const cw = self.canvas.img.width;
        // Tiles are in 640×480 screen pixels; coverage (bilinear sampling of the
        // 256×256 texture), the floor plane and the depth test are evaluated at the
        // center of each fine canvas pixel, like the exe's quad drawn at this
        // resolution. With K = 1 this is the same as screen pixels.
        const w = cw / ss;
        const h = self.canvas.img.height / ss;
        const px = self.canvas.img.pixels;
        const n = mask_size;
        const tn = n / 2;
        const g = shadow_grid;
        const tw = @max(1, w / g);
        const th = @max(1, h / g);
        var cov: [tn * tn]u8 = undefined;
        for (0..tn) |ty| for (0..tn) |tx| {
            const m = self.shadow[2 * ty * n + 2 * tx ..];
            cov[ty * tn + tx] = m[0] + m[1] + m[n] + m[n + 1];
        };
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        const ssf: f32 = @floatFromInt(ss);
        // Darkened screen pixels go into the canvas "drawn" area per tile (shadows of
        // different actors do not merge into one bounding box).
        self.shadow_stat = .{};
        var lo: [g * g][2]usize = @splat(.{ w, h });
        var hi: [g * g][2]usize = @splat(.{ 0, 0 });
        defer for (lo, hi) |l, hh| if (l[0] < hh[0]) {
            self.canvas.beginRegion();
            self.canvas.addDirty(.{ .x0 = @intCast(l[0] * ss), .y0 = @intCast(l[1] * ss), .x1 = @intCast(hh[0] * ss), .y1 = @intCast(hh[1] * ss) });
        };
        // Only tiles the shadow touched (the last one reaches the layer edge).
        for (0..g) |tr| for (tr * th..if (tr == g - 1) h else (tr + 1) * th) |y| {
            if (std.mem.allEqual(?f32, self.shadow_tiles[tr * g ..][0..g], null)) break;
            for (0..g) |tc| for (tc * tw..if (tc == g - 1) w else (tc + 1) * tw) |x| {
                const zg = self.shadow_tiles[tr * g + tc] orelse break;
                var any = false;
                for (y * ss..y * ss + ss) |hy| {
                    // Canvas pixel center in screen pixels.
                    const ey = (num.toF32(hy) + 0.5) / ssf;
                    // Texture coordinate: screen → mask (bx = 1 + x·510/w), texel = bx/2.
                    const vy = (1 + ey * 2 * 255 / fh) / 2 - 0.5;
                    const iy = @floor(vy);
                    const fy = vy - iy;
                    const y0: usize = @intFromFloat(std.math.clamp(iy, 0, tn - 1));
                    const y1: usize = @intFromFloat(std.math.clamp(iy + 1, 0, tn - 1));
                    for (x * ss..x * ss + ss) |hx| {
                        const ex = (num.toF32(hx) + 0.5) / ssf;
                        const vx = (1 + ex * 2 * 255 / fw) / 2 - 0.5;
                        const ix = @floor(vx);
                        const fx = vx - ix;
                        const x0: usize = @intFromFloat(std.math.clamp(ix, 0, tn - 1));
                        const x1: usize = @intFromFloat(std.math.clamp(ix + 1, 0, tn - 1));
                        const c00: f32 = @floatFromInt(cov[y0 * tn + x0]);
                        const c10: f32 = @floatFromInt(cov[y0 * tn + x1]);
                        const c01: f32 = @floatFromInt(cov[y1 * tn + x0]);
                        const c11: f32 = @floatFromInt(cov[y1 * tn + x1]);
                        const sum = (c00 * (1 - fx) + c10 * fx) * (1 - fy) + (c01 * (1 - fx) + c11 * fx) * fy;
                        if (sum <= 0) continue;
                        any = true;
                        self.shadow_stat.lit += 1;
                        const plane = -cam.planeDepth(ex + self.origin[0], ey + self.origin[1], zg) - bias;
                        const i = (hy * cw + hx) * 4;
                        if (plane > self.canvas.depthAt(hy * cw + hx, hx, hy)) {
                            if (ss > 1 and std.math.isNan(self.canvas.depth[hy * cw + hx])) self.shadow_stat.cut_bg += 1;
                            if (self.shadow_debug) px[i..][0..4].* = .{ 255, 0, 0, 255 };
                            continue;
                        }
                        const a = std.math.clamp(intensity * sum / 4, 0, 1);
                        if (px[i + 3] == 0) {
                            px[i..][0..4].* = .{ 0, 0, 0, @intFromFloat(a * 255) };
                        } else for (px[i..][0..3]) |*ch| {
                            ch.* = @intFromFloat(num.toF32(ch.*) * (1 - a));
                        }
                    }
                }
                if (!any) continue;
                const ti = tr * g + tc;
                lo[ti] = .{ @min(lo[ti][0], x), @min(lo[ti][1], y) };
                hi[ti] = .{ @max(hi[ti][0], x + 1), @max(hi[ti][1], y + 1) };
            };
        };
    }

    /// Clears the layer and fills the depth buffer with the background surface: pixel
    /// (x, y) with height H lies at depth y + 2H/k (see camera.worldToScreen).
    pub fn begin(self: *Layer, origin: [2]f32, src: DepthSource) void {
        self.origin = origin;
        const ss = self.ss;
        const w = self.canvas.img.width;
        const h = self.canvas.img.height;
        // Only what was drawn last frame is cleared (the rest is already empty); the
        // fine depth buffer becomes NaN (0xff bytes): background depth comes from the coarse one.
        if (!self.fresh) {
            @memset(self.canvas.img.pixels, 0);
            if (ss > 1) @memset(std.mem.sliceAsBytes(self.canvas.depth), 0xff);
            self.fresh = true;
        } else {
            // Whole drawn rows as one memory block.
            const d = self.canvas.dirty;
            if (!d.isEmpty()) {
                @memset(self.canvas.img.pixels[d.y0 * w * 4 .. d.y1 * w * 4], 0);
                if (ss > 1) @memset(std.mem.sliceAsBytes(self.canvas.depth[d.y0 * w .. d.y1 * w]), 0xff);
            }
        }
        self.canvas.dirty = .empty;
        self.canvas.n_regions = 0;
        if (self.glow_used) @memset(self.glow.pixels, 0);
        self.glow_used = false;
        if (self.screen_used) @memset(self.screen.pixels, 0);
        self.screen_used = false;
        @memset(self.shadow, 0);
        self.shadow_tiles = @splat(null);
        // Background depth by screen rows: the source kind is resolved once per frame.
        const sw = w / ss;
        const ox: i64 = @intFromFloat(origin[0]);
        const oy: i64 = @intFromFloat(origin[1]);
        const out = if (ss == 1) self.canvas.depth else self.base_depth;
        const key: BaseKey = .{ .origin = origin, .src = src };
        if (self.base_key) |k| if (std.meta.eql(k, key)) {
            @memcpy(out[0..self.base_cache.len], self.base_cache);
            return;
        };
        defer {
            @memcpy(self.base_cache, out[0..self.base_cache.len]);
            self.base_key = key;
        }
        for (0..h / ss) |yy| {
            const by: i64 = oy + @as(i64, @intCast(yy));
            const row = out[yy * sw ..][0..sw];
            switch (src) {
                .none => @memset(row, std.math.inf(f32)),
                .heights => |hm| {
                    const byf: f32 = @floatFromInt(by);
                    for (row, 0..) |*d, xx| {
                        const bx = ox + @as(i64, @intCast(xx));
                        var height: f32 = 0;
                        if (bx >= 0 and by >= 0 and bx < hm.z.width and by < hm.z.height) {
                            height = hm.cfg.height(hm.z.depth[@as(usize, @intCast(by)) * hm.z.width + @as(usize, @intCast(bx))]);
                        }
                        d.* = -(byf + 2 * height / camera.k);
                    }
                },
                .persp => |pz| for (row, 0..) |*d, xx| {
                    const bx = ox + @as(i64, @intCast(xx));
                    d.* = if (bx >= 0 and by >= 0 and bx < pz.z.width and by < pz.z.height)
                        level_mod.perspDepth(pz.far, pz.tl, pz.z.depth[@as(usize, @intCast(by)) * pz.z.width + @as(usize, @intCast(bx))]) + pz.tol
                    else
                        std.math.inf(f32);
                },
            }
        }
    }

    /// Background depth of screen pixel (x, y).
    fn setDepth(self: *Layer, x: usize, y: usize, d: f32) void {
        if (self.ss == 1) {
            self.canvas.depth[y * self.canvas.img.width + x] = d;
            return;
        }
        self.base_depth[y * (self.canvas.img.width / self.ss) + x] = d;
        // Already drawn on top (z-frames go before the models) — leave it.
    }

    /// Background pixel depth (by is the background row) for z-buffer value `v` in
    /// `.zbf` space (as in begin).
    fn depthOf(src: DepthSource, by: i64, v: u16) f32 {
        return switch (src) {
            .none => std.math.inf(f32),
            .heights => |hm| -(num.toF32(by) + 2 * hm.cfg.height(v) / camera.k),
            .persp => |pz| level_mod.perspDepth(pz.far, pz.tl, v) + pz.tol,
        };
    }

    /// Object z-frame (`.spz`, raw spr1 with `.zbf` values) over the background depth
    /// at background point (x0, y0) (z pass 0x4b3ff0: a copy without a depth test).
    pub fn overlayDepth(self: *Layer, frame: sprite.Frame, x0: i64, y0: i64, src: DepthSource) void {
        if (src == .none or !frame.raw) return;
        const fw: usize = frame.width;
        if (frame.data.len < 4 + fw * frame.height * 2) return;
        const w: i64 = @intCast(self.canvas.img.width / self.ss);
        const h: i64 = @intCast(self.canvas.img.height / self.ss);
        const ox: i64 = @intFromFloat(self.origin[0]);
        const oy: i64 = @intFromFloat(self.origin[1]);
        for (0..frame.height) |yy| {
            const by = y0 + @as(i64, @intCast(yy));
            const ly = by - oy;
            if (ly < 0 or ly >= h) continue;
            for (0..fw) |xx| {
                const lx = x0 + @as(i64, @intCast(xx)) - ox;
                if (lx < 0 or lx >= w) continue;
                const v = std.mem.readInt(u16, frame.data[4 + (yy * fw + xx) * 2 ..][0..2], .little);
                self.setDepth(@intCast(lx), @intCast(ly), depthOf(src, by, v));
            }
        }
    }

    /// Weapon in hand: model and attachment point on the actor model (0x42b300).
    pub const Attachment = struct {
        model: *const Model,
        link: mesh.HoldMode,
        /// Command 0x20 (0x42ac30): offset from the point (exe units — mesh × actor
        /// model scale), rotation (for a row vector) and mesh scale.
        offset: [3]f32 = .{ 0, 0, 0 },
        rot: [9]f32 = .{ 1, 0, 0, 0, 1, 0, 0, 0, 1 },
        scale: f32 = 1,
        /// Model frame at the point (Headnail's saws spin, "obrot", 0x48d760).
        frame: u32 = 0,
    };

    pub const Placement = struct {
        pos: [3]f32,
        angle: f32,
        scale: f32,
        frame: u32,
        attach: ?Attachment = null,
        /// More attached meshes (ActivateLink: Headnail's saws, the bat).
        extra: []const Attachment = &.{},
        /// Alpha (+0x311c, 0x42a620: alpha v/255) and depth write (off during the
        /// transformation).
        alpha: f32 = 1,
        depth_write: bool = true,
        /// Shift toward the camera as a fraction of depth, in the depth test only
        /// (items on surfaces — bed, table: the background depth fit is accurate to
        /// ~2%, otherwise the item sinks). Draw such models before the ones they
        /// must sort against: their true depth is written.
        depth_bias: f32 = 0,
        /// The model itself is not drawn (materialization at v < 0.6), only the passes.
        hidden: bool = false,
        /// Materialization glow (0x42a620): additive color without a texture.
        tint: ?[3]f32 = null,
        /// Additive passes over the model: ice on a frozen fighter (0x4dc700),
        /// "current" on a shocked one.
        overlays: [2]?Overlay = .{ null, null },
    };

    const Overlay = struct {
        tex: Image,
        uv_scale: f32 = 1,
        uv_offset: [2]f32 = .{ 0, 0 },
        wrap: bool = false,
    };

    pub fn draw(self: *Layer, arena: Allocator, cam: camera.Camera, model: *const Model, p: Placement) !void {
        self.canvas.beginRegion();
        const frame = @min(p.frame, model.frames.frames -| 1);
        const pts = try skin.pose(arena, model.mesh, model.frames, frame, .row);
        const s = p.scale * model.unitScale();
        self.bbox = .{ std.math.inf(f32), std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
        try self.drawParts(arena, cam, model, pts, s, p, null);
        if (p.attach) |at| try self.drawAttached(arena, cam, model, frame, s, p, at);
        for (p.extra) |at| try self.drawAttached(arena, cam, model, frame, s, p, at);
    }

    /// Effect mesh at an actor attachment point (0x4294f0, type 1): additive, with a
    /// depth test and no depth write (ZWRITE off at 0x408a40(0), default D3D z-test) —
    /// whatever is closer to the camera (the shooter, the target, neighbours) covers the
    /// nitro stream and muzzle flashes, as in the exe.
    pub fn drawEffect(self: *Layer, arena: Allocator, cam: camera.Camera, owner: *const Model, p: Placement, at: Attachment, tex: Image) !void {
        const frame = @min(p.frame, owner.frames.frames -| 1);
        const pts = try attachedPoints(arena, owner, frame, at) orelse return;
        const s = p.scale * owner.unitScale();
        const ca = @cos(p.angle);
        const sa = @sin(p.angle);
        const aspect = cam.aspect();
        const ssf: f32 = @floatFromInt(self.ss);
        for (at.model.mesh.parts, pts) |part, ppts| {
            for (part.triangles) |t| {
                var sp: [3][3]f32 = undefined;
                var uv: [3][2]f32 = undefined;
                for (0..3) |i| {
                    var wv = model_cache.toWorld(owner, ppts[t[i]], s, p.pos, ca, sa);
                    wv[2] = p.pos[2] + (wv[2] - p.pos[2]) * aspect;
                    const q = cam.project(wv);
                    sp[i] = .{ (q.x - self.origin[0]) * ssf, (q.y - self.origin[1]) * ssf, -q.depth };
                    uv[i] = part.vertices[t[i]].uv;
                }
                self.canvas.triangleShaded(sp, uv, tex, raster.gray(1), .{ .add = &self.glow });
                self.glow_used = true;
            }
        }
    }

    /// Billboard of the particle batch (0x45e150, flushed at 0x45d8d0 after the models
    /// and shadows): depth-tested against the scene, no depth write, blended per `.dsc`.
    /// The flush turns ZWRITE off and ZENABLE off only off combat levels
    /// ([0x696ea0] == 0), so this is the combat-level path. `corners` are world
    /// points, clockwise from top-left. Vertex colour (0x45e150): alpha mode (r, g, b, a),
    /// otherwise (a·r, a·g, a·b).
    pub fn billboard(self: *Layer, cam: camera.Camera, corners: [4][3]f32, tex: Image, alpha: f32, rgb: [3]f32, blend: BillboardBlend) void {
        const ssf: f32 = @floatFromInt(self.ss);
        var sp: [4][3]f32 = undefined;
        for (corners, &sp) |p, *s| {
            const q = cam.project(p);
            s.* = .{ (q.x - self.origin[0]) * ssf, (q.y - self.origin[1]) * ssf, -q.depth };
        }
        const uv = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
        const k = std.math.clamp(alpha, 0, 1);
        const lit: [3]f32 = if (blend == .alpha) rgb else .{ rgb[0] * k, rgb[1] * k, rgb[2] * k };
        const col = [3][3]f32{ lit, lit, lit };
        const sh: raster.Canvas.Shade = switch (blend) {
            .alpha => .{ .alpha = alpha, .depth_write = false, .tex_alpha = true },
            .add => .{ .add = &self.glow, .depth_write = false },
            .screen => .{ .add = &self.screen, .screen = true, .depth_write = false },
        };
        switch (blend) {
            .alpha => {},
            .add => self.glow_used = true,
            .screen => self.screen_used = true,
        }
        self.canvas.triangleShaded(.{ sp[0], sp[1], sp[2] }, .{ uv[0], uv[1], uv[2] }, tex, col, sh);
        self.canvas.triangleShaded(.{ sp[0], sp[2], sp[3] }, .{ uv[0], uv[2], uv[3] }, tex, col, sh);
    }

    /// Batch billboard blend (0x408ad0 modes 2, 1, 4).
    pub const BillboardBlend = enum { alpha, add, screen };

    fn drawAttached(self: *Layer, arena: Allocator, cam: camera.Camera, model: *const Model, frame: u32, s: f32, p: Placement, at: Attachment) !void {
        const wpts = try attachedPoints(arena, model, frame, at) orelse return;
        // Points are already in actor mesh units: drawParts applies the actor rotation and shift.
        try self.drawParts(arena, cam, at.model, wpts, s, .{ .pos = p.pos, .angle = p.angle, .scale = p.scale, .frame = 0, .alpha = p.alpha, .depth_write = p.depth_write, .hidden = p.hidden }, model);
    }

    /// Back face skipped as the exe does (0x447460, 0x446f20): plane n = (P0−P1)×(P2−P1)
    /// with n·E + d > 0 for the eye E (n·dir for an orthographic view) — the same as
    /// the projected triangle's winding (screen y down; checked on both cameras: the
    /// other sign turns closed models inside out).
    fn backFacing(sp: [3][3]f32) bool {
        return (sp[1][0] - sp[0][0]) * (sp[2][1] - sp[0][1]) - (sp[1][1] - sp[0][1]) * (sp[2][0] - sp[0][0]) > 0;
    }

    /// Model triangles from points `pts` (mesh units). `frame_of` — whose local
    /// transform (rotation and shift, 0x44c060) applies: the actor's for weapons.
    /// Lighting (0x4c6bc0, 0x47e1f0): the vertex normal is minus the sum of face normals
    /// (A − B) × (C − B) over welded vertices, in mesh units; the color comes from the
    /// level light in world coordinates; triangles use vertex colors.
    fn drawParts(self: *Layer, arena: Allocator, cam: camera.Camera, model: *const Model, pts: []const []const [3]f32, s: f32, p: Placement, frame_of: ?*const Model) !void {
        const owner = frame_of orelse model;
        const ca = @cos(p.angle);
        const sa = @sin(p.angle);
        const aspect = cam.aspect();
        const ssf: f32 = @floatFromInt(self.ss);
        for (model.mesh.parts, pts, 0..) |part, ppts, pi| {
            const weld = if (pi < model.weld.len) model.weld[pi] else &.{};
            const acc = try arena.alloc([3]f32, ppts.len);
            @memset(acc, .{ 0, 0, 0 });
            for (part.triangles) |t| {
                const nf = vec.normalize(vec.cross(vec.sub(ppts[t[0]], ppts[t[1]]), vec.sub(ppts[t[2]], ppts[t[1]])));
                for (t) |vi| {
                    const k = if (vi < weld.len) weld[vi] else vi;
                    acc[k] = .{ acc[k][0] + nf[0], acc[k][1] + nf[1], acc[k][2] + nf[2] };
                }
            }
            const world = try arena.alloc([3]f32, ppts.len);
            const cols = try arena.alloc([3]f32, ppts.len);
            for (ppts, world, cols, 0..) |pt, *wv, *cv, i| {
                wv.* = model_cache.toWorld(owner, pt, s, p.pos, ca, sa);
                wv[2] = p.pos[2] + (wv[2] - p.pos[2]) * aspect;
                const k = if (i < weld.len) weld[i] else i;
                const nm = vec.normalize(acc[k]);
                // Outward normal (−sum), into world axes like a point in toWorld, without scale.
                const n1 = camera.mulVec(owner.local, .{ -nm[0], -nm[1], -nm[2] });
                const nw = [3]f32{ n1[0] * ca - n1[2] * sa, n1[0] * sa + n1[2] * ca, n1[1] };
                cv.* = self.light.color(wv.*, nw);
            }
            for (part.triangles) |t| {
                var sp: [3][3]f32 = undefined;
                var uv: [3][2]f32 = undefined;
                var col: [3][3]f32 = undefined;
                for (0..3) |i| {
                    const q = cam.project(world[t[i]]);
                    const lx = q.x - self.origin[0];
                    const ly = q.y - self.origin[1];
                    sp[i] = .{ lx * ssf, ly * ssf, -q.depth };
                    if (frame_of == null) self.bbox = .{ @min(self.bbox[0], lx), @min(self.bbox[1], ly), @max(self.bbox[2], lx), @max(self.bbox[3], ly) };
                    uv[i] = part.vertices[t[i]].uv;
                    col[i] = cols[t[i]];
                }
                if (!model.two_sided and backFacing(sp)) continue;
                if (!p.hidden) self.canvas.triangleShaded(sp, uv, model.partTexture(pi), col, .{ .alpha = p.alpha, .depth_write = p.depth_write, .mips = model.partMips(pi), .test_bias = p.depth_bias });
                if (frame_of != null) continue;
                for (p.overlays) |ov| if (ov) |o| {
                    self.canvas.triangleShaded(sp, uv, o.tex, raster.gray(1), .{ .add = &self.glow, .uv_scale = o.uv_scale, .uv_offset = o.uv_offset, .wrap = o.wrap });
                    self.glow_used = true;
                };
                if (p.tint) |tc| {
                    self.canvas.triangleShaded(sp, uv, null, .{ tc, tc, tc }, .{ .add = &self.glow });
                    self.glow_used = true;
                }
            }
        }
    }
};

/// Weapon `at` vertices in actor mesh units (before its chunk 14 and 11 rotation and shift).
/// The attachment point (0x4290f0) is the bone joint with an offset, like a vertex. For a
/// column vector: w' = Rlinkᵀ·B·X·(Rw·w + shift_w), X mirrors the X axis (so the
/// chaingun.msh flash, extended along +X, sits at the muzzle with the exe offset and the
/// weapon lies in the hand; checked by rendering the rifle, pistol and NATO captain).
pub fn attachedPoints(arena: Allocator, model: *const Model, frame: u32, at: Layer.Attachment) !?[][][3]f32 {
    if (model.frames.bones == 0 or at.link.bone >= model.frames.bones) return null;
    const b = model.frames.matrix(frame, at.link.bone);
    const j = model.mesh.joints[at.link.bone];
    const lp = skin.transform(b, .{ j[0] + at.link.params[0], j[1] + at.link.params[1], j[2] + at.link.params[2] }, .row);
    const lr = camera.rotationXYZ(at.link.params[3..6].*);
    const wm = at.model;
    const wpts = try skin.pose(arena, wm.mesh, wm.frames, at.frame, .row);
    const k = wm.unitScale() / model.unitScale() * at.scale;
    // Point matrix (0x4290f0) M = Bᵀ·R: R = Rx·Ry·Rz from the point angles (+0x2c…+0x34,
    // 0x4293c0/0x429380/0x429340, product 0x47cd30 — A·B), Bᵀ is the bone matrix
    // transposed by 0x47c930. Applied to a column (0x42955f: offset M·o;
    // mesh M·X·v, X the flash rotation): point rotation in weapon axes first, then the
    // bone. Heroes have zero angles; spetsnaz and NATO two_hands (3, 3.5, 0.5) —
    // with the rotation after the bone the rifle pointed backwards.
    const off = camera.mulVecT(b[0..9].*, camera.mulVec(lr, at.offset));
    const ha = model.unitScale();
    const base = [3]f32{ lp[0] + off[0] / ha, lp[1] + off[1] / ha, lp[2] + off[2] / ha };
    for (wpts) |part| for (part) |*v| {
        // Flash rotation (command 0x20 matrix, 0x482010 = Rx·Ry·Rz via 0x47cd30)
        // — R·v in mesh axes: pistol, uzi and rifle flashes along the barrel at the
        // shot (with v·R they pointed up or backwards).
        const wl = camera.mulVec(at.rot, vec.add(camera.mulVec(wm.local, v.*), wm.mesh.center));
        const f = camera.mulVecT(b[0..9].*, camera.mulVec(lr, wl));
        v.* = .{ base[0] + f[0] * k, base[1] + f[1] * k, base[2] + f[2] * k };
    };
    return wpts;
}

test "shadow is solid with soft edges and skips what is above the floor plane" {
    const gpa = std.testing.allocator;
    var layer = try Layer.initScaled(gpa, 640, 480, 1);
    defer layer.deinit(gpa);
    layer.begin(.{ 0, 0 }, .none);
    // Isometric floor at height 0: layer depth of pixel (x, y) is −y.
    for (0..480) |y| for (0..640) |x| {
        layer.canvas.depth[y * 640 + x] = -(num.toF32(y) + 0.5);
    };
    // An actor closer than the floor (a 20×20 pillar in the middle of the shadow).
    for (200..220) |y| for (300..320) |x| {
        layer.canvas.img.pixels[(y * 640 + x) * 4 ..][0..4].* = .{ 200, 200, 200, 255 };
        layer.canvas.depth[y * 640 + x] = -(num.toF32(y) + 0.5) - 40;
    };
    // The shadow is a 120×100 mask-texel square (≈150×94 layer pixels).
    const a = [2]f32{ 200, 180 };
    const b = [2]f32{ 320, 280 };
    layer.shadowTri(.{ a, .{ b[0], a[1] }, b });
    layer.shadowTri(.{ a, b, .{ a[0], b[1] } });
    for (&layer.shadow_tiles) |*t| t.* = 0;
    layer.compositeShadow(.ortho, 0.5, 2.8);
    // Inside without holes: every floor pixel is darkened by half.
    const x0: usize = @as(usize, @intFromFloat(@ceil((a[0] - 1) * 640 / 510))) + 2;
    const x1: usize = @as(usize, @intFromFloat(@floor((b[0] - 1) * 640 / 510))) - 2;
    const y0: usize = @as(usize, @intFromFloat(@ceil((a[1] - 1) * 480 / 510))) + 2;
    const y1: usize = @as(usize, @intFromFloat(@floor((b[1] - 1) * 480 / 510))) - 2;
    var holes: usize = 0;
    for (y0..y1) |y| for (x0..x1) |x| {
        if (y >= 200 and y < 220 and x >= 300 and x < 320) continue;
        if (layer.canvas.img.pixels[(y * 640 + x) * 4 + 3] != 127) holes += 1;
    };
    try std.testing.expectEqual(@as(usize, 0), holes);
    // An actor closer than the plane is not darkened.
    try std.testing.expectEqual(@as(u8, 200), layer.canvas.img.pixels[(210 * 640 + 310) * 4]);
    // The edge is soft: there is an intermediate alpha between empty and full.
    var soft = false;
    for (x0 - 6..x0) |x| {
        const al = layer.canvas.img.pixels[((y0 + y1) / 2 * 640 + x) * 4 + 3];
        if (al > 0 and al < 127) soft = true;
    }
    try std.testing.expect(soft);
}

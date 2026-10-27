//! Software model rasterizer: triangles with a z-buffer, texture (bilinear,
//! mip levels — like LINEAR/MIPLINEAR in the exe, 0x406d50) and vertex color
//! (Gouraud lighting: texel × color, like MODULATE in the exe); transparency and
//! additive passes; triangle recording and drawing in bands on a thread pool
//! (`record`, `flush`).

const std = @import("std");
const num = @import("../num.zig");
const Allocator = std.mem.Allocator;
const Image = @import("../formats.zig").image.Image;

pub const Canvas = struct {
    img: Image,
    depth: []f32,
    /// Background depth `ss` times coarser than the canvas: used where `depth` is NaN
    /// (nothing drawn), so the detailed buffer is not filled every frame.
    base: ?Base = null,

    /// Record triangles instead of drawing (`record`): `flush` then draws them in screen
    /// bands on several threads. Each pixel gets the same triangles in the same order,
    /// so the image equals unrecorded drawing.
    recorded: std.ArrayList(Tri) = .empty,
    rec_gpa: ?Allocator = null,
    /// Owner of the `recorded` list (freed in deinit).
    list_gpa: ?Allocator = null,
    /// Canvas rectangle drawn since `dirty` was last reset (pixels or depth):
    /// clearing and texture upload touch only it.
    dirty: Rect = .empty,
    /// Same per part (`beginRegion` — each model, shadows): the texture upload covers
    /// only these rectangles, not their joint bounds.
    regions: [max_regions]Rect = undefined,
    n_regions: usize = 0,
    /// Additive pass buffer (ice, shock, glow), same size as the canvas.
    /// In the exe the pass lies in the frame, and a model drawn later closer to the
    /// camera covers it (D3D z-test). Ours is separate, so a pixel covered by a closer
    /// surface is cleared here too (dimmed by its alpha if translucent); otherwise a far
    /// fighter's ice showed through the hero standing in front.
    glow_px: ?[]u8 = null,

    pub const max_regions = 64;

    const Base = struct { depth: []f32, w: usize, ss: usize };

    /// Pixels [x0, x1) × [y0, y1); empty if x0 ≥ x1 or y0 ≥ y1.
    pub const Rect = struct {
        x0: u32,
        y0: u32,
        x1: u32,
        y1: u32,

        pub const empty: Rect = .{ .x0 = std.math.maxInt(u32), .y0 = std.math.maxInt(u32), .x1 = 0, .y1 = 0 };

        pub fn isEmpty(r: Rect) bool {
            return r.x0 >= r.x1 or r.y0 >= r.y1;
        }

        pub fn join(a: Rect, b: Rect) Rect {
            return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
        }
    };

    /// Mark [x0, x1] × [y0, y1] as drawn (inclusive, canvas pixels).
    fn markDirty(self: *Canvas, x0: f32, y0: f32, x1: f32, y1: f32) void {
        self.addDirty(.{ .x0 = @intFromFloat(x0), .y0 = @intFromFloat(y0), .x1 = @as(u32, @intFromFloat(x1)) + 1, .y1 = @as(u32, @intFromFloat(y1)) + 1 });
    }

    pub fn addDirty(self: *Canvas, r: Rect) void {
        self.dirty = self.dirty.join(r);
        if (self.n_regions == 0) self.beginRegion();
        self.regions[self.n_regions - 1] = self.regions[self.n_regions - 1].join(r);
    }

    /// Start a new drawn part (when out of slots the last one grows).
    pub fn beginRegion(self: *Canvas) void {
        if (self.n_regions > 0 and self.regions[self.n_regions - 1].isEmpty()) return;
        if (self.n_regions == max_regions) return;
        self.regions[self.n_regions] = .empty;
        self.n_regions += 1;
    }

    /// Drawn parts (non-empty).
    pub fn dirtyRegions(self: *const Canvas) []const Rect {
        var n = self.n_regions;
        if (n > 0 and self.regions[n - 1].isEmpty()) n -= 1;
        return self.regions[0..n];
    }

    const Tri = struct { p: [3][3]f32, uv: [3][2]f32, tex: ?Image, col: [3][3]f32, sh: Shade };

    /// Depth of canvas pixel (x, y) at index `idx`.
    pub inline fn depthAt(self: *const Canvas, idx: usize, x: usize, y: usize) f32 {
        const d = self.depth[idx];
        if (d == d) return d;
        const b = self.base orelse return d;
        return b.depth[(y / b.ss) * b.w + x / b.ss];
    }

    pub fn init(gpa: Allocator, w: u32, h: u32, bg: [4]u8) Allocator.Error!Canvas {
        var img = try Image.init(gpa, w, h);
        errdefer img.deinit(gpa);
        var i: usize = 0;
        while (i < img.pixels.len) : (i += 4) img.pixels[i..][0..4].* = bg;
        const depth = try gpa.alloc(f32, @as(usize, w) * h);
        @memset(depth, std.math.inf(f32));
        return .{ .img = img, .depth = depth };
    }

    pub fn deinit(self: *Canvas, gpa: Allocator) void {
        if (self.list_gpa) |g| self.recorded.deinit(g);
        gpa.free(self.depth);
        self.img.deinit(gpa);
    }

    /// Vertices in screen coordinates: x, y pixels, z depth (smaller is closer).
    pub fn triangle(self: *Canvas, p: [3][3]f32, uv: [3][2]f32, tex: ?Image, col: [3][3]f32) void {
        self.triangleShaded(p, uv, tex, col, .{});
    }

    /// How to draw a triangle: opaque, alpha-blended over the canvas, or added into a
    /// separate image `add` (effect passes: ice, shock, materialization glow) with the
    /// canvas depth test and no depth write.
    pub const Shade = struct {
        alpha: f32 = 1,
        depth_write: bool = true,
        add: ?*Image = null,
        /// Texture coordinates: uv·scale + offset, wrapped (otherwise clamped).
        uv_scale: f32 = 1,
        uv_offset: [2]f32 = .{ 0, 0 },
        wrap: bool = false,
        /// Blend by alpha × texel alpha (SRCALPHA / INVSRCALPHA billboards).
        tex_alpha: bool = false,
        /// With `add`: screen (ONE / INVSRCCOLOR) into `add` instead of a saturating sum.
        screen: bool = false,
        /// Texture mip levels (`[0]` is the texture itself): one level per triangle by the
        /// texel/pixel area ratio, nearest (MIPLINEAR, 0x406d90).
        mips: []const Image = &.{},
        /// Depth test only: the triangle counts this fraction of its depth closer
        /// (ground items over the background fit); the true depth is written, so
        /// models drawn later sort against it.
        test_bias: f32 = 0,
    };

    /// Start recording triangles (`gpa` for the list; memory is reused).
    pub fn record(self: *Canvas, gpa: Allocator) void {
        self.rec_gpa = gpa;
        self.list_gpa = gpa;
        self.recorded.clearRetainingCapacity();
    }

    /// Draw the recording in row bands on `pool` threads (null — this thread)
    /// and stop recording.
    pub fn flush(self: *Canvas, pool: ?*Pool) void {
        if (self.rec_gpa == null) return;
        self.rec_gpa = null;
        defer self.recorded.clearRetainingCapacity();
        const tris = self.recorded.items;
        if (tris.len == 0) return;
        var job: Job = .{ .canvas = self, .tris = tris, .chunks = (self.img.height + chunk - 1) / chunk };
        if (pool) |p| p.run(&job) else job.run();
    }

    /// Render threads: `std.Io.Group` tasks on the viewer's Io.
    pub const Pool = struct {
        io: std.Io,
        workers: u32 = 0,

        /// `threads` — total including the caller.
        pub fn init(p: *Pool, threads: usize) void {
            p.workers = @intCast(std.math.clamp(threads, 1, max_threads) - 1);
        }

        fn run(p: *Pool, job: *Job) void {
            var g: std.Io.Group = .init;
            for (0..p.workers) |_| g.async(p.io, Job.run, .{job});
            job.run();
            g.await(p.io) catch {};
        }
    };

    pub const max_threads = 16;
    /// Rows per band: bands go to threads in turn (models cover part of the screen,
    /// so equal shares per thread would load them unevenly).
    const chunk = 32;

    const Job = struct {
        canvas: *Canvas,
        tris: []const Tri,
        chunks: usize,
        next: std.atomic.Value(usize) = .init(0),

        fn run(job: *Job) void {
            const h = job.canvas.img.height;
            while (true) {
                const i = job.next.fetchAdd(1, .monotonic);
                if (i >= job.chunks) return;
                const y_lo = i * chunk;
                const y_hi = @min(h, y_lo + chunk);
                const flo: f32 = @floatFromInt(y_lo);
                const fhi: f32 = @floatFromInt(y_hi);
                const dfr = Deferred.get(job.canvas.img.width);
                for (job.tris, 0..) |t, ti| {
                    // Quick reject of triangles outside the band.
                    if (@max(t.p[0][1], t.p[1][1], t.p[2][1]) < flo - 1 or @min(t.p[0][1], t.p[1][1], t.p[2][1]) > fhi + 1) continue;
                    if (dfr) |d| {
                        // Consecutive opaque ones: depth and pixel owner first, color once per
                        // pixel (see Deferred).
                        if (t.sh.add == null and !t.sh.tex_alpha and std.math.clamp(t.sh.alpha, 0, 1) >= 1) {
                            job.canvas.rasterSpan(.depth, t.p, t.uv, t.tex, t.col, t.sh, y_lo, y_hi, d, @intCast(ti));
                            continue;
                        }
                        d.resolve(job.canvas, job.tris, y_lo);
                    }
                    job.canvas.raster(t.p, t.uv, t.tex, t.col, t.sh, y_lo, y_hi);
                }
                if (dfr) |d| d.resolve(job.canvas, job.tris, y_lo);
            }
        }
    };

    /// Pixel color from weights: texel (or grey 200, white for additive) × Gouraud lighting.
    inline fn shade(comptime white: bool, tex_l: ?Image, uv: [3][2]f32, c0: @Vector(3, f32), c1: @Vector(3, f32), c2: @Vector(3, f32), sh: Shade, w0: f32, w1: f32, w2: f32) [4]u8 {
        const V3 = @Vector(3, f32);
        var color: [4]u8 = if (white) .{ 255, 255, 255, 255 } else .{ 200, 200, 200, 255 };
        if (tex_l) |t| {
            var u = (w0 * uv[0][0] + w1 * uv[1][0] + w2 * uv[2][0]) * sh.uv_scale + sh.uv_offset[0];
            var v = (w0 * uv[0][1] + w1 * uv[1][1] + w2 * uv[2][1]) * sh.uv_scale + sh.uv_offset[1];
            if (sh.wrap) {
                u -= @floor(u);
                v -= @floor(v);
            }
            color = sampleBilinear(t, std.math.clamp(u, 0, 1), std.math.clamp(v, 0, 1));
        }
        const light = @as(V3, @splat(w0)) * c0 + @as(V3, @splat(w1)) * c1 + @as(V3, @splat(w2)) * c2;
        const cf: V3 = @floatFromInt(@as(@Vector(3, u8), color[0..3].*));
        const lit = std.math.clamp(cf * light, @as(V3, @splat(0)), @as(V3, @splat(255)));
        const c8: [3]u8 = @as(@Vector(3, u8), @intFromFloat(lit));
        color[0..3].* = c8;
        return color;
    }

    /// Deferred color for consecutive opaque triangles of a band: the final pixel
    /// color comes from the last triangle that passed the depth test, so only depth
    /// runs first (remembering the owner triangle and weights), and texture and light
    /// are computed once per pixel. Before a transparent or additive triangle the
    /// pending pixels are resolved — same order and result as drawing one by one.
    const Deferred = struct {
        const Win = struct { tri: u32, w: [3]f32 };
        const none = std.math.maxInt(u32);
        win: []Win,
        list: []u32,
        n: usize = 0,

        threadlocal var tl: ?Deferred = null;

        /// Thread buffer for a band of `width`; null when out of memory (draw one by
        /// one).
        fn get(width: usize) ?*Deferred {
            const need = chunk * width;
            if (tl) |*d| if (d.win.len >= need) return d;
            if (tl) |*d| {
                std.heap.page_allocator.free(d.win);
                std.heap.page_allocator.free(d.list);
                tl = null;
            }
            const win = std.heap.page_allocator.alloc(Win, need) catch return null;
            const list = std.heap.page_allocator.alloc(u32, need) catch {
                std.heap.page_allocator.free(win);
                return null;
            };
            for (win) |*x| x.tri = none;
            tl = .{ .win = win, .list = list };
            return &tl.?;
        }

        inline fn note(d: *Deferred, local: usize, tri: u32, w: [3]f32) void {
            if (d.win[local].tri == none) {
                d.list[d.n] = @intCast(local);
                d.n += 1;
            }
            d.win[local] = .{ .tri = tri, .w = w };
        }

        fn resolve(d: *Deferred, canvas: *Canvas, tris: []const Tri, y_lo: usize) void {
            const off = y_lo * canvas.img.width;
            for (d.list[0..d.n]) |local| {
                const wv = d.win[local];
                d.win[local].tri = none;
                const t = tris[wv.tri];
                var color = shade(false, t.tex, t.uv, t.col[0], t.col[1], t.col[2], t.sh, wv.w[0], wv.w[1], wv.w[2]);
                color[3] = 255;
                canvas.img.pixels[(off + local) * 4 ..][0..4].* = color;
            }
            d.n = 0;
        }
    };

    pub fn triangleShaded(self: *Canvas, p: [3][3]f32, uv: [3][2]f32, tex: ?Image, col: [3][3]f32, sh: Shade) void {
        const w: f32 = @floatFromInt(self.img.width);
        const h: f32 = @floatFromInt(self.img.height);
        const min_x = @max(0, @floor(@min(p[0][0], p[1][0], p[2][0])));
        const max_x = @min(w - 1, @ceil(@max(p[0][0], p[1][0], p[2][0])));
        const min_y = @max(0, @floor(@min(p[0][1], p[1][1], p[2][1])));
        const max_y = @min(h - 1, @ceil(@max(p[0][1], p[1][1], p[2][1])));
        if (min_x > max_x or min_y > max_y) return;
        const area = edge(p[0], p[1], p[2]);
        if (@abs(area) < 1e-6) return;
        // Additive writes into its own image and leaves the canvas alone.
        if (sh.add == null) self.markDirty(min_x, min_y, max_x, max_y);
        const tex_l = if (tex) |t| mipFor(t, sh.mips, uv, area * sh.uv_scale * sh.uv_scale) else null;
        if (self.rec_gpa) |gpa| {
            var s2 = sh;
            s2.mips = &.{};
            if (self.recorded.append(gpa, .{ .p = p, .uv = uv, .tex = tex_l, .col = col, .sh = s2 })) return else |_| {}
        }
        self.raster(p, uv, tex_l, col, sh, 0, self.img.height);
    }

    /// Triangle in rows [y_lo, y_hi); `tex_l` is the already chosen mip level.
    fn raster(self: *Canvas, p: [3][3]f32, uv: [3][2]f32, tex_l: ?Image, col: [3][3]f32, sh: Shade, y_lo: usize, y_hi: usize) void {
        // The inner loop is a separate copy per pass kind: no per-pixel branching on the
        // mode. The computation order is the same, so the result is bit-identical.
        if (sh.add != null) return self.rasterSpan(.add, p, uv, tex_l, col, sh, y_lo, y_hi, null, 0);
        if (sh.tex_alpha or std.math.clamp(sh.alpha, 0, 1) < 1) return self.rasterSpan(.blend, p, uv, tex_l, col, sh, y_lo, y_hi, null, 0);
        return self.rasterSpan(.solid, p, uv, tex_l, col, sh, y_lo, y_hi, null, 0);
    }

    /// `depth` is like `solid` but stores the triangle and pixel weights in `dfr`
    /// instead of a color; `Deferred.resolve` computes the color later.
    const Pass = enum { solid, blend, add, depth };

    fn rasterSpan(self: *Canvas, comptime pass: Pass, p: [3][3]f32, uv: [3][2]f32, tex_l: ?Image, col: [3][3]f32, sh: Shade, y_lo: usize, y_hi: usize, dfr: ?*Deferred, tri_id: u32) void {
        const w: f32 = @floatFromInt(self.img.width);
        const h: f32 = @floatFromInt(self.img.height);
        const min_x = @max(0, @floor(@min(p[0][0], p[1][0], p[2][0])));
        const max_x = @min(w - 1, @ceil(@max(p[0][0], p[1][0], p[2][0])));
        const min_y = @max(num.toF32(y_lo), @max(0, @floor(@min(p[0][1], p[1][1], p[2][1]))));
        const max_y = @min(num.toF32(y_hi) - 1, @min(h - 1, @ceil(@max(p[0][1], p[1][1], p[2][1]))));
        if (min_x > max_x or min_y > max_y) return;
        const area = edge(p[0], p[1], p[2]);
        const a = std.math.clamp(sh.alpha, 0, 1);
        const write_depth = pass != .add and sh.depth_write;
        const V3 = @Vector(3, f32);
        const c0: V3 = col[0];
        const c1: V3 = col[1];
        const c2: V3 = col[2];
        const width = self.img.width;
        const ux0: usize = @intFromFloat(min_x);
        const base = self.base;

        // Barycentric weights stepped along x (edge functions are linear).
        const inv = 1 / area;
        const dx0 = -(p[2][1] - p[1][1]) * inv;
        const dx1 = -(p[0][1] - p[2][1]) * inv;
        const dx2 = -(p[1][1] - p[0][1]) * inv;
        var y = min_y;
        while (y <= max_y) : (y += 1) {
            const q0: [3]f32 = .{ min_x + 0.5, y + 0.5, 0 };
            var w0 = edge(p[1], p[2], q0) * inv - dx0;
            var w1 = edge(p[2], p[0], q0) * inv - dx1;
            var w2 = edge(p[0], p[1], q0) * inv - dx2;
            const uy: usize = @intFromFloat(y);
            const row = uy * width;
            // Background depth (ss times coarser): one row per triangle row.
            const brow = if (base) |b| (uy / b.ss) * b.w else 0;
            var inside = false;
            var x = min_x;
            var ux = ux0;
            while (x <= max_x) : ({
                x += 1;
                ux += 1;
            }) {
                w0 += dx0;
                w1 += dx1;
                w2 += dx2;
                if (w0 < 0 or w1 < 0 or w2 < 0) {
                    // The triangle is convex: once out of it the row is done.
                    if (inside) break;
                    continue;
                }
                inside = true;
                const z = w0 * p[0][2] + w1 * p[1][2] + w2 * p[2][2];
                const zt = z - sh.test_bias * @abs(z);
                const idx = row + ux;
                var dz = self.depth[idx];
                if (dz != dz) if (base) |b| {
                    dz = b.depth[brow + ux / b.ss];
                };
                // Passes over an already drawn surface of the same model use a tolerance.
                if (pass == .add) {
                    if (zt > dz + @abs(dz) * 1e-4 + 1e-3) continue;
                } else if (zt >= dz) continue;
                var color: [4]u8 = undefined;
                if (pass != .depth) color = shade(pass == .add, tex_l, uv, c0, c1, c2, sh, w0, w1, w2);
                var pa = a;
                if (pass == .blend and sh.tex_alpha) {
                    pa = a * num.toF32(color[3]) / 255;
                    if (pa <= 0) continue;
                }
                if (write_depth) self.depth[idx] = z;
                if (pass != .add) if (self.glow_px) |g| {
                    const gd = g[idx * 4 ..][0..4];
                    if (gd[3] != 0) {
                        if (pass == .blend) {
                            for (0..3) |k| gd[k] = @intFromFloat(num.toF32(gd[k]) * (1 - pa));
                        } else gd.* = .{ 0, 0, 0, 0 };
                    }
                };
                if (pass == .depth) {
                    dfr.?.note(idx - y_lo * width, tri_id, .{ w0, w1, w2 });
                    continue;
                }
                switch (pass) {
                    .add => {
                        const d = sh.add.?.pixels[idx * 4 ..][0..4];
                        if (sh.screen) {
                            for (0..3) |k| d[k] = @intCast(@as(u32, color[k]) + @as(u32, d[k]) * (255 - @as(u32, color[k])) / 255);
                        } else for (0..3) |k| d[k] = @intCast(@min(255, @as(u32, d[k]) + color[k]));
                        d[3] = 255;
                    },
                    .blend => {
                        // "Over" in the layer's non-premultiplied alpha.
                        const d = self.img.pixels[idx * 4 ..][0..4];
                        const da = num.toF32(d[3]) / 255;
                        const oa = pa + da * (1 - pa);
                        if (oa <= 0) continue;
                        for (0..3) |k| {
                            const cv = num.toF32(color[k]) * pa + num.toF32(d[k]) * da * (1 - pa);
                            d[k] = @intFromFloat(std.math.clamp(cv / oa, 0, 255));
                        }
                        d[3] = @intFromFloat(oa * 255);
                    },
                    .solid => {
                        color[3] = 255;
                        self.img.pixels[idx * 4 ..][0..4].* = color;
                    },
                    .depth => unreachable,
                }
            }
        }
    }
};

/// Mip level for a triangle: LOD = ½·log2(texels per pixel), the nearest
/// level (D3DFILTER_MIPLINEAR — bilinear within one level).
fn mipFor(t: Image, mips: []const Image, uv: [3][2]f32, screen_area: f32) Image {
    if (mips.len < 2) return t;
    const du1 = uv[1][0] - uv[0][0];
    const dv1 = uv[1][1] - uv[0][1];
    const du2 = uv[2][0] - uv[0][0];
    const dv2 = uv[2][1] - uv[0][1];
    const uv_area = @abs(du1 * dv2 - du2 * dv1) * num.toF32(t.width) * num.toF32(t.height);
    const px = @abs(screen_area);
    if (px <= 0 or uv_area <= px) return t;
    const lod = 0.5 * std.math.log2(uv_area / px);
    const level: usize = @intFromFloat(@min(num.toF32(mips.len - 1), @floor(lod + 0.5)));
    return mips[level];
}

/// Texture sample with bilinear filtering (like D3D in the exe — model textures
/// are smooth, no nearest-texel steps).
fn sampleBilinear(t: Image, u: f32, v: f32) [4]u8 {
    const fx = u * num.toF32(t.width) - 0.5;
    const fy = v * num.toF32(t.height) - 0.5;
    const x0f = @floor(fx);
    const y0f = @floor(fy);
    const ax: f32 = fx - x0f;
    const ay: f32 = fy - y0f;
    const w: i32 = @intCast(t.width);
    const h: i32 = @intCast(t.height);
    const x0: usize = @intCast(@max(0, @min(w - 1, @as(i32, @intFromFloat(x0f)))));
    const y0: usize = @intCast(@max(0, @min(h - 1, @as(i32, @intFromFloat(y0f)))));
    const x1 = @min(x0 + 1, t.width - 1);
    const y1 = @min(y0 + 1, t.height - 1);
    const V = @Vector(4, f32);
    const r0 = y0 * t.width * 4;
    const r1 = y1 * t.width * 4;
    const c00: V = @floatFromInt(@as(@Vector(4, u8), t.pixels[r0 + x0 * 4 ..][0..4].*));
    const c10: V = @floatFromInt(@as(@Vector(4, u8), t.pixels[r0 + x1 * 4 ..][0..4].*));
    const c01: V = @floatFromInt(@as(@Vector(4, u8), t.pixels[r1 + x0 * 4 ..][0..4].*));
    const c11: V = @floatFromInt(@as(@Vector(4, u8), t.pixels[r1 + x1 * 4 ..][0..4].*));
    const bx: V = @splat(ax);
    const by: V = @splat(ay);
    const one: V = @splat(1);
    const top = c00 * (one - bx) + c10 * bx;
    const bot = c01 * (one - bx) + c11 * bx;
    const out: @Vector(4, u8) = @intFromFloat(@round(top * (one - by) + bot * by));
    return out;
}

/// The same grey for all three vertices.
pub fn gray(v: f32) [3][3]f32 {
    return @splat(@splat(v));
}

fn edge(a: [3]f32, b: [3]f32, c: [3]f32) f32 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

test "triangle covers pixels and respects depth" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4, .{ 0, 0, 0, 255 });
    defer c.deinit(gpa);
    const uv: [3][2]f32 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } };
    c.triangle(.{ .{ 0, 0, 5 }, .{ 4, 0, 5 }, .{ 0, 4, 5 } }, uv, null, gray(1));
    try std.testing.expectEqual(200, c.img.pixels[0]);
    // A far triangle does not cover a near one.
    c.triangle(.{ .{ 0, 0, 9 }, .{ 4, 0, 9 }, .{ 0, 4, 9 } }, uv, null, gray(0.5));
    try std.testing.expectEqual(200, c.img.pixels[0]);
}

test "test bias passes the depth test but writes the true depth" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4, .{ 0, 0, 0, 255 });
    defer c.deinit(gpa);
    @memset(c.depth, 10); // background slightly in front of the item
    const uv: [3][2]f32 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } };
    const tri = [3][3]f32{ .{ 0, 0, 10.2 }, .{ 4, 0, 10.2 }, .{ 0, 4, 10.2 } };
    c.triangleShaded(tri, uv, null, gray(1), .{ .test_bias = 0.03 });
    try std.testing.expectEqual(200, c.img.pixels[0]);
    try std.testing.expectApproxEqAbs(10.2, c.depth[0], 1e-4);
    // An actor just in front of the item's true depth covers it.
    c.triangle(.{ .{ 0, 0, 10.1 }, .{ 4, 0, 10.1 }, .{ 0, 4, 10.1 } }, uv, null, gray(0.5));
    try std.testing.expectEqual(100, c.img.pixels[0]);
}

test "alpha blends and additive pass keeps depth" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4, .{ 0, 0, 0, 0 });
    defer c.deinit(gpa);
    var add = try Image.init(gpa, 4, 4);
    defer add.deinit(gpa);
    @memset(add.pixels, 0);
    const uv: [3][2]f32 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } };
    const tri: [3][3]f32 = .{ .{ 0, 0, 5 }, .{ 4, 0, 5 }, .{ 0, 4, 5 } };
    c.triangleShaded(tri, uv, null, gray(1), .{ .alpha = 0.5 });
    try std.testing.expectEqual(200, c.img.pixels[0]);
    try std.testing.expectEqual(127, c.img.pixels[3]);
    // Additive at the same depth passes and leaves depth unchanged.
    c.triangleShaded(tri, uv, null, gray(0.2), .{ .add = &add });
    try std.testing.expectEqual(51, add.pixels[0]);
    try std.testing.expectEqual(5, c.depth[0]);
    // Screen: 51 + 51·(255 − 51)/255 = 91, not the sum 102.
    c.triangleShaded(tri, uv, null, gray(0.2), .{ .add = &add, .screen = true });
    try std.testing.expectEqual(91, add.pixels[0]);
}

test "texel-alpha billboard is hidden behind nearer depth" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 4, 4, .{ 0, 0, 0, 0 });
    defer c.deinit(gpa);
    var tex = try Image.init(gpa, 1, 1);
    defer tex.deinit(gpa);
    tex.pixels[0..4].* = .{ 255, 0, 0, 128 };
    const uv: [3][2]f32 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } };
    const near: [3][3]f32 = .{ .{ 0, 0, 2 }, .{ 4, 0, 2 }, .{ 0, 4, 2 } };
    const far: [3][3]f32 = .{ .{ 0, 0, 9 }, .{ 4, 0, 9 }, .{ 0, 4, 9 } };
    c.triangleShaded(near, uv, null, gray(1), .{});
    const before = c.img.pixels[0..4].*;
    c.triangleShaded(far, uv, tex, gray(1), .{ .depth_write = false, .tex_alpha = true });
    try std.testing.expectEqual(before, c.img.pixels[0..4].*);
    // In front: blended by texel alpha (128/255), depth not written.
    const front: [3][3]f32 = .{ .{ 0, 0, 1 }, .{ 4, 0, 1 }, .{ 0, 4, 1 } };
    c.triangleShaded(front, uv, tex, gray(1), .{ .depth_write = false, .tex_alpha = true });
    try std.testing.expect(c.img.pixels[0] > before[0]);
    try std.testing.expectEqual(2, c.depth[0]);
}

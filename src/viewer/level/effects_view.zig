//! Effect drawing (`og.effects`): planes (`EffectRes::draw`, 0x45e150), flash mesh
//! on a link point (0x4294f0), blood, flamethrower, fire on cells and on burning
//! fighters. Textures are `.3df` frames from `gfx_3d\effects\<name>\`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");
const model_cache = og.actor.model_cache;
const camera = og.actor.camera;
const fx = og.effects;

const Res = struct {
    blend: fx.dsc.Blend,
    tex: []*c.SDL_Texture,
};

/// Per-frame drawing context shared by every effect call.
pub const Frame = struct { arena: Allocator, cam: camera.Camera, scroll: [2]f32 };

/// Billboard quad corners (0x45e150), clockwise from top-left: faces the camera in
/// perspective, lies along the screen axes in the orthographic camera.
pub fn billboardCorners(cam: camera.Camera, pos: [3]f32, half: f32) [4][3]f32 {
    var ax: [3]f32 = undefined;
    var bx: [3]f32 = undefined;
    switch (cam) {
        .ortho => {
            const cs = @cos(camera.angle);
            const sn = @sin(camera.angle);
            ax = .{ cs * half, sn * half, 0 };
            bx = .{ -sn * half, cs * half, 0 };
        },
        .persp => |p| {
            const eye = [3]f32{ p.eye[0] / p.scale, p.eye[2] / p.scale, p.eye[1] / p.scale };
            const d = og.vec.normalize(og.vec.sub(eye, pos));
            const a2 = og.vec.normalize(.{ d[1], -d[0], 0 });
            ax = .{ a2[0] * half, a2[1] * half, 0 };
            const b2 = og.vec.normalize(og.vec.cross(a2, d));
            // B points down the screen.
            bx = .{ -b2[0] * half, -b2[1] * half, -b2[2] * half };
        },
    }
    return .{
        .{ pos[0] - ax[0] - bx[0], pos[1] - ax[1] - bx[1], pos[2] - ax[2] - bx[2] },
        .{ pos[0] + ax[0] - bx[0], pos[1] + ax[1] - bx[1], pos[2] + ax[2] - bx[2] },
        .{ pos[0] + ax[0] + bx[0], pos[1] + ax[1] + bx[1], pos[2] + ax[2] + bx[2] },
        .{ pos[0] - ax[0] + bx[0], pos[1] - ax[1] + bx[1], pos[2] - ax[2] + bx[2] },
    };
}

pub const EffectsView = struct {
    gpa: Allocator,
    renderer: *c.SDL_Renderer,
    models: *model_cache.Cache,
    cache: std.StringHashMapUnmanaged(?Res) = .empty,
    /// Projectile mesh textures by model.
    mesh_tex: std.AutoHashMapUnmanaged(*const model_cache.Model, ?*c.SDL_Texture) = .empty,
    /// Exe blend modes (0x408ad0) for SDL.
    modes: [6]c.SDL_BlendMode,
    /// Textures `gfx_3d\textures\<name>` by name (disturb.3df etc.).
    named_tex: std.StringHashMapUnmanaged(?*c.SDL_Texture) = .empty,

    pub fn init(gpa: Allocator, r: *c.SDL_Renderer, models: *model_cache.Cache) EffectsView {
        const F = c.SDL_BLENDFACTOR_ONE;
        const Z = c.SDL_BLENDFACTOR_ZERO;
        const add = c.SDL_BLENDOPERATION_ADD;
        return .{
            .gpa = gpa,
            .renderer = r,
            .models = models,
            .modes = .{
                c.SDL_BLENDMODE_NONE,
                c.SDL_ComposeCustomBlendMode(F, F, add, Z, F, add),
                c.SDL_BLENDMODE_BLEND,
                c.SDL_ComposeCustomBlendMode(Z, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_COLOR, add, Z, F, add),
                c.SDL_ComposeCustomBlendMode(F, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_COLOR, add, Z, F, add),
                c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_DST_COLOR, Z, add, Z, F, add),
            },
        };
    }

    pub fn deinit(self: *EffectsView) void {
        var it = self.cache.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*) |rs| {
                for (rs.tex) |t| c.SDL_DestroyTexture(t);
                self.gpa.free(rs.tex);
            }
            self.gpa.free(e.key_ptr.*);
        }
        self.cache.deinit(self.gpa);
        var mt = self.mesh_tex.valueIterator();
        while (mt.next()) |t| if (t.*) |tex| c.SDL_DestroyTexture(tex);
        self.mesh_tex.deinit(self.gpa);
        var nt = self.named_tex.iterator();
        while (nt.next()) |e| {
            if (e.value_ptr.*) |tex| c.SDL_DestroyTexture(tex);
            self.gpa.free(e.key_ptr.*);
        }
        self.named_tex.deinit(self.gpa);
    }

    fn textureOf(self: *EffectsView, m: *const model_cache.Model) ?*c.SDL_Texture {
        if (self.mesh_tex.get(m)) |t| return t;
        const t: ?*c.SDL_Texture = if (m.texture) |img| gfx.textureLinear(self.renderer, img) catch null else null;
        self.mesh_tex.put(self.gpa, m, t) catch {};
        return t;
    }

    /// Projectile mesh (0x44f400): tumble `roll` about the transverse axis, turned
    /// along the flight; no depth.
    pub fn drawMesh(self: *EffectsView, f: Frame, name: []const u8, pos: [3]f32, dir: [3]f32, roll: f32, scale: f32) !void {
        const m = self.models.get(name) orelse return;
        return self.drawMeshWith(f, name, self.textureOf(m), pos, dir, roll, scale, 1, .{ 1, 1, 1, 1 });
    }

    /// Texture `gfx_3d\textures\<file>` (cached by name).
    pub fn namedTexture(self: *EffectsView, file: []const u8) ?*c.SDL_Texture {
        if (self.named_tex.get(file)) |t| return t;
        var buf: [96]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "gfx_3d\\textures\\{s}", .{file}) catch return null;
        const t: ?*c.SDL_Texture = blk: {
            const bytes = self.models.readFile(path) catch break :blk null;
            var img = og.formats.tex3df.decode(self.gpa, bytes) catch break :blk null;
            defer img.deinit(self.gpa);
            break :blk gfx.textureLinear(self.renderer, img) catch null;
        };
        const k = self.gpa.dupe(u8, file) catch return t;
        self.named_tex.put(self.gpa, k, t) catch self.gpa.free(k);
        return t;
    }

    /// Mesh `name` with texture `tex_file` instead of its own, additive, colour `rgba`
    /// (0x4c7c30: kwadrat + disturb.3df — click and speaker markers).
    /// Ground decal (click marker, speaker ring, selection snakes): the exe
    /// (0x4c7c30 → 0x44ef00) sets `kwadrat` angles (0, π/2, −π/2), which with the
    /// scene rotation 0x6b6b18 lays its XY plane on the ground. Without it the quad
    /// stood upright and the ring became an "egg" in perspective.
    pub fn drawMeshTexAdd(self: *EffectsView, f: Frame, tex_file: []const u8, pos: [3]f32, dir: [3]f32, scale: f32, rgba: [4]f32) !void {
        const name = "kwadrat";
        const flat = std.math.pi / 2.0;
        const tex = self.namedTexture(tex_file) orelse {
            // Unlit mesh with its own texture and vertex colour `rgba`.
            const m = self.models.get(name) orelse return;
            return self.drawMeshWith(f, name, self.textureOf(m), pos, dir, flat, scale, 1, rgba);
        };
        _ = c.SDL_SetTextureBlendMode(tex, self.modes[@backingInt(fx.dsc.Blend.add)]);
        return self.drawMeshWith(f, name, tex, pos, dir, flat, scale, 1, rgba);
    }

    /// Point `v` in units of mesh `name` (projectile: tumble `roll`, direction `dir`,
    /// scale `scale`, as in `drawMeshWith`) in the world. Molotov flame (0x49d537):
    /// 0x47c960 puts the translation (25, 45, 45) into the tumble matrix, 0x442900
    /// applies it over the bottle's world matrix (0x44f400: position, +0x2f8, scale
    /// aS·+0x358), so the offset is in mesh units, with its rotation and scale.
    pub fn meshPoint(self: *EffectsView, name: []const u8, pos: [3]f32, dir: [3]f32, roll: f32, scale: f32, v: [3]f32) ?[3]f32 {
        const m = self.models.get(name) orelse return null;
        const u = m.unitScale();
        const s = scale * u;
        const yaw = og.fields.modelAngle(og.fields.facing(dir[0], dir[1]));
        const pitch = std.math.atan2(dir[2], og.vec.len2(dir));
        const n = [3]f32{ v[0] / u, v[1] / u, v[2] / u };
        const r = [3]f32{ n[0], n[1] * @cos(roll) - n[2] * @sin(roll), n[1] * @sin(roll) + n[2] * @cos(roll) };
        const l = og.actor.model_cache.localPoint(m, r);
        const lp = [3]f32{ l[0], l[2] * @sin(pitch) + l[1] * @cos(pitch), l[2] * @cos(pitch) - l[1] * @sin(pitch) };
        return og.actor.model_cache.toWorldLocal(lp, s, pos, @cos(yaw), @sin(yaw));
    }

    fn drawMeshWith(self: *EffectsView, f: Frame, name: []const u8, tex: ?*c.SDL_Texture, pos: [3]f32, dir: [3]f32, roll: f32, scale: f32, stretch: f32, rgba: [4]f32) !void {
        const m = self.models.get(name) orelse return;
        const pts = try og.actor.skin.pose(f.arena, m.mesh, m.frames, 0, .row);
        const s = scale * m.unitScale();
        const yaw = og.fields.modelAngle(og.fields.facing(dir[0], dir[1]));
        const cr = @cos(roll);
        const sr = @sin(roll);
        // Projectile (0x49b0a0): matrix +0x2f8 is built from the whole flight
        // direction including pitch — the mesh's "forward" (+Z) looks along dir, and
        // the orbital rocket (pocisk, 0x4a8450) falls nose down. Pitch is in the mesh's
        // (Z, Y) plane after its local axes, then the heading turn.
        const pitch = std.math.atan2(dir[2], og.vec.len2(dir));
        const cp = @cos(pitch);
        const sp = @sin(pitch);
        // Each triangle splits into n² small ones before projection: SDL interpolates
        // textures affinely, and a large flat quad in perspective (the marker ring)
        // would skew otherwise.
        const n: usize = 8;
        for (m.mesh.parts, pts) |part, ppts| {
            const world = try f.arena.alloc([3]f32, ppts.len);
            for (ppts, world) |p, *wv| {
                const v = [3]f32{ p[0], (p[1] * cr - p[2] * sr) * stretch, p[1] * sr + p[2] * cr };
                const l = og.actor.model_cache.localPoint(m, v);
                const lp = [3]f32{ l[0], l[2] * sp + l[1] * cp, l[2] * cp - l[1] * sp };
                wv.* = og.actor.model_cache.toWorldLocal(lp, s, pos, @cos(yaw), @sin(yaw));
            }
            const per = (n + 1) * (n + 2) / 2;
            const verts = try f.arena.alloc(c.SDL_Vertex, part.triangles.len * per);
            const idx = try f.arena.alloc(c_int, part.triangles.len * n * n * 3);
            var vi: usize = 0;
            var ii: usize = 0;
            for (part.triangles) |t| {
                const base = vi;
                // Barycentric grid: row i (0..n), column j (0..n−i).
                for (0..n + 1) |i| for (0..n + 1 - i) |j| {
                    const b1 = og.num.toF32(i) / og.num.toF32(n);
                    const b2 = og.num.toF32(j) / og.num.toF32(n);
                    const b0 = 1 - b1 - b2;
                    const a = world[t[0]];
                    const b = world[t[1]];
                    const cc = world[t[2]];
                    const wp = [3]f32{ a[0] * b0 + b[0] * b1 + cc[0] * b2, a[1] * b0 + b[1] * b1 + cc[1] * b2, a[2] * b0 + b[2] * b1 + cc[2] * b2 };
                    const ua = part.vertices[t[0]].uv;
                    const ub = part.vertices[t[1]].uv;
                    const uc = part.vertices[t[2]].uv;
                    const q = f.cam.project(wp);
                    verts[vi] = vertex(q.x - f.scroll[0], q.y - f.scroll[1], ua[0] * b0 + ub[0] * b1 + uc[0] * b2, ua[1] * b0 + ub[1] * b1 + uc[1] * b2, rgba);
                    vi += 1;
                };
                const at = struct {
                    fn g(nn: usize, i: usize, j: usize) usize {
                        // row i offset: Σ_{r<i}(nn+1−r)
                        return (i * (2 * nn + 3 - i)) / 2 + j;
                    }
                }.g;
                for (0..n) |i| for (0..n - i) |j| {
                    const v00: c_int = @intCast(base + at(n, i, j));
                    const v01: c_int = @intCast(base + at(n, i, j + 1));
                    const v10: c_int = @intCast(base + at(n, i + 1, j));
                    idx[ii] = v00;
                    idx[ii + 1] = v10;
                    idx[ii + 2] = v01;
                    ii += 3;
                    if (j + 1 < n - i) {
                        const v11: c_int = @intCast(base + at(n, i + 1, j + 1));
                        idx[ii] = v01;
                        idx[ii + 1] = v10;
                        idx[ii + 2] = v11;
                        ii += 3;
                    }
                };
            }
            _ = c.SDL_RenderGeometry(self.renderer, tex, verts.ptr, @intCast(vi), idx.ptr, @intCast(ii));
        }
    }

    /// Effect mesh (`chaingun.msh`, two crossed planes along +X) textured with an
    /// effect frame, +X along `dir` (rocket body and exhaust, 0x49bfb0).
    pub fn drawEffectMesh(self: *EffectsView, f: Frame, effect: []const u8, frame: u32, pos: [3]f32, dir: [3]f32, scale: f32, blend: fx.dsc.Blend) !void {
        const rs = self.res(effect) orelse return;
        const m = self.models.get("chaingun") orelse return;
        const tex = rs.tex[frame % rs.tex.len];
        _ = c.SDL_SetTextureBlendMode(tex, self.modes[@backingInt(blend)]);
        defer _ = c.SDL_SetTextureBlendMode(tex, self.modes[@backingInt(rs.blend)]);
        const pts = try og.actor.skin.pose(f.arena, m.mesh, m.frames, 0, .row);
        const s = scale * m.unitScale();
        const hl = og.vec.len2(dir);
        const pitch = std.math.atan2(dir[2], hl);
        const yaw = std.math.atan2(dir[1], dir[0]);
        const cp = @cos(pitch);
        const sp = @sin(pitch);
        for (m.mesh.parts, pts) |part, ppts| {
            const verts = try f.arena.alloc(c.SDL_Vertex, ppts.len);
            for (ppts, part.vertices, verts) |p, mv, *out| {
                // Pitch about the mesh Z axis (mesh Y is up), then the heading turn.
                const v = [3]f32{ p[0] * cp - p[1] * sp, p[0] * sp + p[1] * cp, p[2] };
                const q = f.cam.project(og.actor.model_cache.toWorld(m, v, s, pos, @cos(yaw), @sin(yaw)));
                out.* = vertex(q.x - f.scroll[0], q.y - f.scroll[1], mv.uv[0], mv.uv[1], .{ 1, 1, 1, 1 });
            }
            const idx = try f.arena.alloc(c_int, part.triangles.len * 3);
            for (part.triangles, 0..) |t, i| for (0..3) |k| {
                idx[i * 3 + k] = t[k];
            };
            _ = c.SDL_RenderGeometry(self.renderer, tex, verts.ptr, @intCast(verts.len), idx.ptr, @intCast(idx.len));
        }
    }

    /// Mesh with its own texture, additive at brightness `k` (0x44d310, satellite beam),
    /// stretched vertically by `stretch` (morph glow: 3, 3, 4).
    pub fn drawMeshAdd(self: *EffectsView, f: Frame, name: []const u8, pos: [3]f32, dir: [3]f32, scale: f32, stretch: f32, k: f32) !void {
        const m = self.models.get(name) orelse return;
        const tex = self.textureOf(m) orelse return;
        var mode: c.SDL_BlendMode = undefined;
        _ = c.SDL_GetTextureBlendMode(tex, &mode);
        _ = c.SDL_SetTextureBlendMode(tex, self.modes[@backingInt(fx.dsc.Blend.add)]);
        defer _ = c.SDL_SetTextureBlendMode(tex, mode);
        try self.drawMeshWith(f, name, tex, pos, dir, 0, scale, stretch, .{ k, k, k, 1 });
    }

    fn res(self: *EffectsView, name: []const u8) ?Res {
        var key_buf: [64]u8 = undefined;
        if (name.len == 0 or name.len > key_buf.len) return null;
        const key = std.ascii.lowerString(&key_buf, name);
        if (self.cache.get(key)) |r| return r;
        const loaded = self.load(name) catch null;
        const k = self.gpa.dupe(u8, key) catch return loaded;
        self.cache.put(self.gpa, k, loaded) catch self.gpa.free(k);
        return loaded;
    }

    fn load(self: *EffectsView, name: []const u8) !?Res {
        const d = self.models.effect(name) orelse return null;
        var list: std.ArrayList(*c.SDL_Texture) = .empty;
        errdefer {
            for (list.items) |t| c.SDL_DestroyTexture(t);
            list.deinit(self.gpa);
        }
        for (d.frames.items) |f| {
            var buf: [160]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "gfx_3d\\effects\\{s}\\{s}", .{ name, f }) catch continue;
            const bytes = self.models.readFile(path) catch continue;
            var img = og.formats.tex3df.decode(self.gpa, bytes) catch continue;
            defer img.deinit(self.gpa);
            const t = try gfx.textureLinear(self.renderer, img);
            _ = c.SDL_SetTextureBlendMode(t, self.modes[@backingInt(d.blend)]);
            try list.append(self.gpa, t);
        }
        if (list.items.len == 0) return null;
        return .{ .blend = d.blend, .tex = try list.toOwnedSlice(self.gpa) };
    }

    fn vertex(x: f32, y: f32, u: f32, v: f32, col: [4]f32) c.SDL_Vertex {
        return .{ .position = .{ .x = x, .y = y }, .color = .{ .r = col[0], .g = col[1], .b = col[2], .a = col[3] }, .tex_coord = .{ .x = u, .y = v } };
    }

    /// Vertex colour (0x45e150): mode 2 — (r, g, b, a), else (a·r, a·g, a·b, 1).
    fn color(blend: fx.dsc.Blend, a: f32, rgb: [3]f32) [4]f32 {
        const k = std.math.clamp(a, 0, 1);
        return if (blend == .alpha) .{ rgb[0], rgb[1], rgb[2], k } else .{ rgb[0] * k, rgb[1] * k, rgb[2] * k, 1 };
    }

    /// Effect plane (0x45e150): half-size h = actorScale·size; in perspective it faces
    /// the camera, in isometric it lies on the ground (screen right and down).
    /// `blend` overrides the `.dsc` header (rocket body: mode 2).
    pub fn billboard(self: *EffectsView, f: Frame, name: []const u8, frame: u32, pos: [3]f32, half: f32, a: f32, rgb: [3]f32, blend: ?fx.dsc.Blend) !void {
        var rs = self.res(name) orelse return;
        const tex = rs.tex[frame % rs.tex.len];
        if (blend) |bl| {
            rs.blend = bl;
            _ = c.SDL_SetTextureBlendMode(tex, self.modes[@backingInt(bl)]);
        }
        defer if (blend != null) {
            _ = c.SDL_SetTextureBlendMode(tex, self.modes[@backingInt((self.res(name) orelse rs).blend)]);
        };
        const col = color(rs.blend, a, rgb);
        const corners = billboardCorners(f.cam, pos, half);
        const uv = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
        self.quad(f, tex, corners, uv, col);
    }

    /// A textured quad: world corners `corners` (in order around it), texture
    /// coordinates `uv`, colour `col`.
    fn quad(self: *EffectsView, f: Frame, tex: *c.SDL_Texture, corners: [4][3]f32, uv: [4][2]f32, col: [4]f32) void {
        var v: [4]c.SDL_Vertex = undefined;
        for (corners, uv, &v) |p, t, *out| {
            const q = f.cam.project(p);
            out.* = vertex(q.x - f.scroll[0], q.y - f.scroll[1], t[0], t[1], col);
        }
        const idx = [6]c_int{ 0, 1, 2, 0, 2, 3 };
        _ = c.SDL_RenderGeometry(self.renderer, tex, &v, 4, &idx, 6);
    }

    /// Ribbon beam (0x4a3c30, 0x4a4f80): strip A→B offset ±`side` across, texture
    /// coordinate `t0`…`t1` along, 0…1 across; additive.
    pub fn ribbon(self: *EffectsView, f: Frame, name: []const u8, frame: u32, a: [3]f32, b: [3]f32, side: [3]f32, t0: f32, t1: f32, k: f32) !void {
        const rs = self.res(name) orelse return;
        const tex = rs.tex[frame % rs.tex.len];
        _ = c.SDL_SetTextureBlendMode(tex, self.modes[@backingInt(fx.dsc.Blend.add)]);
        defer _ = c.SDL_SetTextureBlendMode(tex, self.modes[@backingInt(rs.blend)]);
        const corners = [4][3]f32{
            .{ a[0] + side[0], a[1] + side[1], a[2] + side[2] },
            .{ b[0] + side[0], b[1] + side[1], b[2] + side[2] },
            og.vec.sub(b, side),
            og.vec.sub(a, side),
        };
        const uv = [4][2]f32{ .{ t0, 0 }, .{ t1, 0 }, .{ t1, 1 }, .{ t0, 1 } };
        const col = [4]f32{ k, k, k, 1 };
        self.quad(f, tex, corners, uv, col);
    }

    /// Horizontal "screen right" axis in the world (for camera-facing strips).
    pub fn screenRight(cam: camera.Camera, pos: [3]f32) [3]f32 {
        return switch (cam) {
            .ortho => .{ @cos(camera.angle), @sin(camera.angle), 0 },
            .persp => |p| blk: {
                const eye = [3]f32{ p.eye[0] / p.scale, p.eye[2] / p.scale, p.eye[1] / p.scale };
                const d = og.vec.normalize(.{ eye[0] - pos[0], eye[1] - pos[1], 0 });
                break :blk .{ d[1], -d[0], 0 };
            },
        };
    }

    /// Plane in screen coordinates (flamethrower 0x40c0d0, burning fighter 0x4dc700).
    pub fn screenQuad(self: *EffectsView, name: []const u8, frame: u32, rect: [4]f32, a: f32, rgb: [3]f32, blend: ?fx.dsc.Blend) !void {
        const rs = self.res(name) orelse return;
        const tex = rs.tex[frame % rs.tex.len];
        const bl = blend orelse rs.blend;
        _ = c.SDL_SetTextureBlendMode(tex, self.modes[@backingInt(bl)]);
        defer _ = c.SDL_SetTextureBlendMode(tex, self.modes[@backingInt(rs.blend)]);
        const col = color(bl, a, rgb);
        const v = [4]c.SDL_Vertex{
            vertex(rect[0], rect[1], 0, 0, col),
            vertex(rect[0] + rect[2], rect[1], 1, 0, col),
            vertex(rect[0] + rect[2], rect[1] + rect[3], 1, 1, col),
            vertex(rect[0], rect[1] + rect[3], 0, 1, col),
        };
        const idx = [6]c_int{ 0, 1, 2, 0, 2, 3 };
        _ = c.SDL_RenderGeometry(self.renderer, tex, &v, 4, &idx, 6);
    }
};

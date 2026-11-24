//! Enemy preview: its model (the look's `meshFile`) posed in an animation at the
//! game's 30 frames a second, drawn into a texture: on the GPU renderer by the game's
//! model pass (viewer/gpu/models.zig), else by the engine's rasterizer (as `gorky-tool
//! model`, src/tool/models.zig); edges only (`wire`) always by the latter.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const lay = @import("layout.zig");
const Cache = og.actor.model_cache.Cache;
const fx = @import("preview_fx.zig");
const GpuModels = @import("viewer").gpu_models.GpuModels;

/// A weapon in the actor's hand: its model and the actor model's hold point
/// (`two_hands` for a two-handed item, else `one_hand`; actors.zig in the viewer).
pub const Held = struct {
    mesh: []const u8,
    link: []const u8,
    /// The strike's effects (flash, projectile, hit), the game's by weapon classic_id.
    strike: ?fx.Strike = null,
};

/// A fighter riding the model at its link point (catalog.Rider), in its own animation
/// `anim`; `act`: one played once from the model's first frame, then `anim` again.
pub const Rider = struct { mesh: []const u8, link: []const u8, anim: []const u8, act: []const u8 = "" };

/// A rider's animation and frames shown (now and the draw before: its frame sounds).
const RiderShown = struct { mesh: []const u8 = "", anim: []const u8 = "", key: u64 = 0, prev: ?u32 = null, now: u32 = 0 };

pub const Preview = struct {
    cache: ?Cache = null,
    /// The models' textures (renderer side, over the cache's files).
    textures: ?og.render.textures.Textures = null,
    tex: ?*c.SDL_Texture = null,
    /// What is shown: model and animation file name (for the fixed framing).
    key_buf: [128]u8 = undefined,
    key_len: usize = 0,
    /// Vertical centre and height for the whole animation (no jumping between frames).
    frame_y: f32 = 0,
    frame_h: f32 = 1,
    /// The wheel's zoom over the framing and the picture moved by a drag (pixels).
    zoom: f32 = 1,
    shift: [2]f32 = .{ 0, 0 },
    /// The texture's size in pixels.
    tex_w: u32 = 0,
    tex_h: u32 = 0,
    start_ms: u64 = 0,
    yaw: f32 = 210,
    /// Tilt (degrees): positive looks from above.
    pitch: f32 = 0,
    /// Effect frames by name; the strike's effects and the sounds they asked for.
    fx_frames: fx.Frames = .{},
    sim: ?*fx.Sim = null,
    fx_sound_buf: [8][]const u8 = undefined,
    fx_sounds: []const []const u8 = &.{},
    /// Riders as drawn last (their frame sounds).
    riders_buf: [4]RiderShown = @splat(.{}),
    riders_shown: []const RiderShown = &.{},
    /// Edges only (the concept's Wireframe), no texture.
    wire: bool = false,
    /// The GPU renderer's model pass (made on the first draw; null on another renderer)
    /// and the picture it composes into.
    gpu: ?*GpuModels = null,
    gpu_tried: bool = false,
    out: ?*c.SDL_Texture = null,
    /// Global frame shown and the one before it (null: the animation just started),
    /// for its frame sounds.
    frame: u32 = 0,
    prev: ?u32 = null,
    drawn_ms: u64 = 0,
    /// Stopped on this frame of the animation (from its first); null — playing.
    paused: ?u32 = 0,
    /// Playing when last drawn: stopping (any way: the button, a step, the timeline) stops its sounds.
    was_playing: bool = false,
    /// The shown animation's frame count and the shown frame's place in it.
    frames: u32 = 1,
    at: u32 = 0,
    /// The model's attach points as drawn last (the Model page's handles).
    points_buf: [32]Point = undefined,
    points: []const Point = &.{},

    /// Playing ↔ stopped on the frame shown.
    pub fn togglePause(self: *Preview) void {
        if (self.paused) |p| {
            // Play on from the frame it stopped at.
            self.start_ms = c.SDL_GetTicks() -| @as(u64, p) * 1000 / 30;
            self.paused = null;
        } else self.paused = self.at;
    }

    /// One frame back (-1) or on (+1), stopped there.
    pub fn step(self: *Preview, d: i32) void {
        const n: i32 = @intCast(@max(self.frames, 1));
        const from: i32 = @intCast(self.paused orelse self.at);
        self.paused = @intCast(@mod(from + d, n));
    }

    pub fn deinit(self: *Preview) void {
        self.reload();
        if (self.tex) |t| c.SDL_DestroyTexture(t);
        if (self.out) |t| c.SDL_DestroyTexture(t);
        if (self.gpu) |g| g.deinit();
    }

    /// Models read again on the next draw (a model edited, undone or saved).
    pub fn reload(self: *Preview) void {
        if (self.sim) |sm| sm.destroy();
        self.sim = null;
        // Its uploads are keyed by the models' and textures' memory, freed here.
        if (self.gpu) |g| g.forget();
        if (self.cache) |*cc| {
            self.fx_frames.deinit(cc.gpa);
            self.fx_frames = .{};
            if (self.textures) |*t| t.deinit();
            self.textures = null;
            cc.deinit();
        }
        self.cache = null;
        self.key_len = 0;
    }

    /// Model `mesh` of the preview's cache (the core's model records over the game's files,
    /// `overlay`'s unsaved ones first); null — no such model.
    pub fn modelOf(self: *Preview, gpa: Allocator, io: std.Io, dat: std.Io.Dir, overlay: og.compose.models.Overlay, mesh: []const u8) ?*og.actor.model_cache.Model {
        if (self.cache == null) {
            self.cache = og.compose.models.open(io, gpa, dat, overlay) catch return null;
            self.textures = og.compose.models.textures(gpa, &self.cache.?);
        }
        return self.cache.?.get(mesh);
    }

    /// Model `mesh` in animation `anim` (a file animation name) at the current time;
    /// null — no such model.
    /// `overlay` gives unsaved model files (new looks); `px`: the picture's size.
    pub fn draw(self: *Preview, gpa: Allocator, io: std.Io, dat: std.Io.Dir, r: *c.SDL_Renderer, overlay: og.compose.models.Overlay, mesh: []const u8, anim: []const u8, held: ?Held, riders: []const Rider, px: [2]u32) ?*c.SDL_Texture {
        const model = self.modelOf(gpa, io, dat, overlay, mesh) orelse return null;
        // A model without animations (a prop: chaingun, a crate) in its one pose.
        const rest: og.core.model.Animation = .{ .name = "", .first = 0, .last = 0, .speed = 0, .sounds = &.{} };
        const a = model.anims.find(anim) orelse if (model.anims.items.len > 0) &model.anims.items[0] else &rest;
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var key_buf: [128]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}/{s}", .{ mesh, a.name }) catch return null;
        const started = !std.mem.eql(u8, key, self.key_buf[0..self.key_len]);
        if (started) {
            @memcpy(self.key_buf[0..key.len], key);
            self.key_len = key.len;
            self.start_ms = c.SDL_GetTicks();
            // Framing over every frame of the animation.
            var lo: f32 = std.math.inf(f32);
            var hi: f32 = -std.math.inf(f32);
            var f = a.first;
            while (f <= a.last) : (f += 1) {
                const pts = og.actor.skin.pose(arena, model.mesh, model.frames, f, .row) catch return null;
                for (pts) |pp| for (pp) |p| {
                    const q = og.actor.model_cache.localPoint(model, p);
                    lo = @min(lo, q[1]);
                    hi = @max(hi, q[1]);
                };
            }
            self.frame_y = (lo + hi) / 2;
            self.frame_h = @max(hi - lo, 1);
        }
        // The strike's effects (preview_fx.zig), made again for another model, animation or strike.
        const want: ?fx.Strike = if (held) |h| h.strike else null;
        if (started or !std.meta.eql(want, if (self.sim) |sm| @as(?fx.Strike, sm.strike) else null)) {
            if (self.sim) |sm| sm.destroy();
            self.sim = if (want) |st| fx.Sim.create(gpa, io, &self.cache.?, st, mesh, a.name) catch null else null;
        }
        const n = a.last - a.first + 1;
        // Played on past the animation's end (its last frame held) while the effects last.
        const shown = if (self.sim) |sm| @max(n, sm.len) else n;
        // A new animation starts stopped on its first frame if stopped.
        if (started and self.paused != null) self.paused = 0;
        self.frames = shown;
        self.at = if (self.paused) |p| p % shown else @intCast((c.SDL_GetTicks() - self.start_ms) * 30 / 1000 % shown);
        const frame = a.first + @min(self.at, n - 1);
        // Not shown for a while (another page): no burst of the frames missed.
        // Stopped: a model opened shows its first frame, its sound not played.
        const stale = c.SDL_GetTicks() - self.drawn_ms > 200;
        self.prev = if (started) (if (self.paused != null) frame else null) else if (stale) frame else self.frame;
        self.frame = frame;
        self.drawn_ms = c.SDL_GetTicks();
        self.fx_sounds = &.{};
        if (self.sim) |sm| {
            sm.run(self.at);
            const snd = sm.sounds(&self.fx_sound_buf);
            if (self.paused == null and !started and !stale) self.fx_sounds = snd;
        }

        const pts = og.actor.skin.pose(arena, model.mesh, model.frames, frame, .row) catch return null;
        // The weapon at the hold point, posed with the hand (render/layer.zig).
        var weapon: ?Part = null;
        if (held) |h| if (model.mesh.holdMode(h.link)) |link| {
            const wm_opt = self.cache.?.get(h.mesh);
            if (wm_opt) |wm| if (og.render.layer.attachedPoints(arena, model, frame, .{ .model = wm, .link = link }) catch null) |wp| {
                weapon = .{ .m = wm, .pts = wp };
            };
        };
        // Riders on their link points (viewer/level/actors.zig linkedMeshes, 0x4297b4),
        // their animation as far in as the model's; `act` once from the first frame.
        var drawn: std.ArrayList(?Part) = .empty;
        drawn.append(arena, .{ .m = model, .pts = pts }) catch return null;
        drawn.append(arena, weapon) catch return null;
        var nr: usize = 0;
        for (riders) |rd| if (model.mesh.holdMode(rd.link)) |link| if (self.cache.?.get(rd.mesh)) |rm| {
            const act = if (rd.act.len > 0) rm.anims.find(rd.act) else null;
            const acting = if (act) |ra| self.at <= ra.last - ra.first else false;
            const name = if (acting) rd.act else rd.anim;
            const rf = if (acting) act.?.first + self.at else if (rm.anims.find(rd.anim)) |ra| ra.first + self.at % (ra.last - ra.first + 1) else 0;
            if (nr < self.riders_buf.len) {
                // Its sounds from the frame after the one drawn last (the same animation).
                const rk = std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, rd.mesh), name);
                const old = self.riders_buf[nr];
                const prev: ?u32 = if (self.prev == null) null else if (self.prev.? == self.frame) rf else if (old.key == rk) old.now else null;
                self.riders_buf[nr] = .{ .mesh = rd.mesh, .anim = name, .key = rk, .prev = prev, .now = rf };
                nr += 1;
            }
            if (og.render.layer.attachedPoints(arena, model, frame, .{ .model = rm, .link = link, .frame = rf }) catch null) |rp|
                drawn.append(arena, .{ .m = rm, .pts = rp }) catch return null;
        };
        self.riders_shown = self.riders_buf[0..nr];
        const yaw = self.yaw * std.math.pi / 180.0;
        const cy = @cos(yaw);
        const sy = @sin(yaw);
        const pitch = self.pitch * std.math.pi / 180.0;
        const cp = @cos(pitch);
        const sp_ = @sin(pitch);
        // Framing: with effects, the box they reach too (in the model's axes: world
        // (x, y, z)/(aS·unit) is (x, z, y)).
        const w: f32 = @floatFromInt(px[0]);
        const h: f32 = @floatFromInt(px[1]);
        var k = @min(w, h) * 0.8 / self.frame_h;
        var cx: f32 = w / 2;
        var ym = self.frame_y;
        const height = self.frame_h;
        if (self.sim) |sm| if (sm.box[0][0] <= sm.box[1][0]) {
            const u = og.actor.model_cache.default_actor_scale * model.unitScale();
            var lo = [2]f32{ -height * 0.3, self.frame_y - height / 2 };
            var hi = [2]f32{ height * 0.3, self.frame_y + height / 2 };
            for (0..8) |i| {
                const q = [3]f32{ sm.box[i & 1][0], sm.box[(i >> 1) & 1][1], sm.box[i >> 2][2] };
                const sx = (q[0] * cy + q[1] * sy) / u;
                lo = .{ @min(lo[0], sx), @min(lo[1], q[2] / u) };
                hi = .{ @max(hi[0], sx), @max(hi[1], q[2] / u) };
            }
            k = @min(k, 0.9 * @min(w / @max(hi[0] - lo[0], 1e-3), h / @max(hi[1] - lo[1], 1e-3)));
            cx = w / 2 - (lo[0] + hi[0]) / 2 * k;
            ym = (lo[1] + hi[1]) / 2;
        };
        // Zoomed about the picture's centre.
        cx = w / 2 + (cx - w / 2) * self.zoom + self.shift[0];
        const cyp = h / 2 + self.shift[1];
        k *= self.zoom;
        // The engine's camera for the effects, the preview's view: orthographic but for
        // an eye `far` away; scale 1/(aS·unit) takes world points to the model's axes.
        const far = 1e4 * @max(height, 1);
        const cam: og.actor.camera.Camera = .{ .persp = .{
            .eye = .{ sy * cp * far, ym - sp_ * far, -cy * cp * far },
            .fwd = .{ -sy * cp, sp_, cy * cp },
            .right = .{ cy, 0, sy },
            .up = .{ sy * sp_, cp, -cy * sp_ },
            .focal = k * far,
            .focal_y = k * far,
            .cx = cx,
            .cy = cyp,
            .scale = 1 / (og.actor.model_cache.default_actor_scale * model.unitScale()),
            .zlevel = 0,
        } };
        const view: View = .{ .cx = cx, .cy = cyp, .k = k, .ym = ym, .yaw = .{ cy, sy }, .pitch = .{ cp, sp_ }, .far = far };
        // The attach points where drawn, and how a unit of offset moves each.
        var np: usize = 0;
        for (model.mesh.hold_modes, 0..) |hm, hi| {
            if (np == self.points_buf.len) break;
            const at = holdPoint(model, frame, hm, .{ 0, 0, 0 }) orelse continue;
            const p0 = view.project(og.actor.model_cache.localPoint(model, at));
            var pt: Point = .{ .i = hi, .at = .{ p0[0], p0[1] }, .d = undefined };
            for (0..3) |ax| {
                var off: [3]f32 = @splat(0);
                off[ax] = 1;
                const p1 = view.project(og.actor.model_cache.localPoint(model, holdPoint(model, frame, hm, off).?));
                pt.d[ax] = .{ p1[0] - p0[0], p1[1] - p0[1] };
            }
            self.points_buf[np] = pt;
            np += 1;
        }
        self.points = self.points_buf[0..np];
        if (!self.wire) if (self.gpuOf(gpa, r)) |g| return self.drawGpu(g, gpa, arena, r, drawn.items, model, view, cam, .{ cy, sy, 0 }, frame, px);
        var layer = og.render.layer.Layer.initScaled(gpa, px[0], px[1], 1) catch return null;
        defer layer.deinit(gpa);
        layer.textures = &self.textures.?;
        const canvas = &layer.canvas;
        var o: usize = 0;
        while (o < canvas.img.pixels.len) : (o += 4) canvas.img.pixels[o..][0..4].* = lay.canvas.preview_bg;
        const light = [3]f32{ 0.4, 0.7, -0.6 };
        for (drawn.items) |dd| if (dd) |d| for (d.m.mesh.parts, d.pts, 0..) |part, ppts, pi| {
            // Points in the actor model's axes (the weapon's are in its units already).
            for (ppts) |*p| p.* = og.actor.model_cache.localPoint(model, p.*);
            for (part.triangles) |t| {
                var sp: [3][3]f32 = undefined;
                var uv: [3][2]f32 = undefined;
                for (0..3) |i| {
                    sp[i] = view.project(ppts[t[i]]);
                    uv[i] = part.vertices[t[i]].uv;
                }
                const nrm = og.vec.cross(og.vec.sub(ppts[t[1]], ppts[t[0]]), og.vec.sub(ppts[t[2]], ppts[t[0]]));
                const len = og.vec.len(nrm);
                const shade = if (len > 0) 0.45 + 0.55 * @abs((nrm[0] * light[0] + nrm[1] * light[1] + nrm[2] * light[2]) / len) else 1;
                if (self.wire) wireTriangle(&canvas.img, sp, shade) else canvas.triangle(sp, uv, self.textures.?.partTexture(d.m, pi), og.render.raster.gray(shade));
            }
        };
        if (self.sim) |sm| if (!self.wire) {
            sm.draw(arena, &layer, cam, .{ cy, sy, 0 }, &self.cache.?, &self.fx_frames, model, frame);
            // Additive and screen passes over the picture (viewer: their own textures on top).
            for (canvas.img.pixels, layer.glow.pixels, layer.screen.pixels, 0..) |*p, g, sc, i| if (i % 4 != 3) {
                const v: u16 = @min(255, @as(u16, p.*) + g);
                p.* = @intCast(@as(u16, sc) + v * (255 - @as(u16, sc)) / 255);
            };
        };
        if (self.tex != null and (self.tex_w != px[0] or self.tex_h != px[1])) {
            c.SDL_DestroyTexture(self.tex);
            self.tex = null;
        }
        if (self.tex == null) {
            self.tex = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STREAMING, @intCast(px[0]), @intCast(px[1]));
            self.tex_w = px[0];
            self.tex_h = px[1];
        }
        const t = self.tex orelse return null;
        _ = c.SDL_UpdateTexture(t, null, layer.canvas.img.pixels.ptr, @intCast(px[0] * 4));
        return t;
    }

    fn gpuOf(self: *Preview, gpa: Allocator, r: *c.SDL_Renderer) ?*GpuModels {
        if (!self.gpu_tried) {
            self.gpu_tried = true;
            self.gpu = GpuModels.init(gpa, r);
            if (self.gpu) |g| {
                const bg = lay.canvas.preview_bg;
                g.clear = .{ og.num.toF32(bg[0]) / 255, og.num.toF32(bg[1]) / 255, og.num.toF32(bg[2]) / 255, 1 };
            }
        }
        return self.gpu;
    }

    /// The picture by the GPU's model pass: the models' triangles as the canvas path draws
    /// them (the preview's view, one shade per face), the strike's effects through the
    /// layer's sink; the colour, glow and screen targets composed into `out`.
    fn drawGpu(self: *Preview, g: *GpuModels, gpa: Allocator, arena: Allocator, r: *c.SDL_Renderer, drawn: []const ?Part, model: *const og.actor.model_cache.Model, view: View, cam: og.actor.camera.Camera, right: [3]f32, frame: u32, px: [2]u32) ?*c.SDL_Texture {
        g.begin(px[0], px[1], 1) catch return null;
        const sk = g.sink();
        const light = [3]f32{ 0.4, 0.7, -0.6 };
        for (drawn) |dd| if (dd) |d| for (d.m.mesh.parts, d.pts, 0..) |part, ppts, pi| {
            if (part.triangles.len == 0) continue;
            for (ppts) |*p| p.* = og.actor.model_cache.localPoint(model, p.*);
            // A vertex per corner: the shade is the face's.
            const n = part.triangles.len * 3;
            const pos = arena.alloc([3]f32, n) catch return null;
            const verts = arena.alloc(og.core.model.Vertex, n) catch return null;
            const col = arena.alloc([3]f32, n) catch return null;
            const tris = arena.alloc([3]u32, part.triangles.len) catch return null;
            for (part.triangles, 0..) |t, ti| {
                const nrm = og.vec.cross(og.vec.sub(ppts[t[1]], ppts[t[0]]), og.vec.sub(ppts[t[2]], ppts[t[0]]));
                const len = og.vec.len(nrm);
                const shade: f32 = if (len > 0) 0.45 + 0.55 * @abs((nrm[0] * light[0] + nrm[1] * light[1] + nrm[2] * light[2]) / len) else 1;
                for (0..3) |i| {
                    const k = ti * 3 + i;
                    pos[k] = view.project(ppts[t[i]]);
                    verts[k] = part.vertices[t[i]];
                    col[k] = .{ shade, shade, shade };
                }
                const b: u32 = @intCast(ti * 3);
                tris[ti] = .{ b, b + 1, b + 2 };
            }
            sk.part(sk.ctx, .{ .pos = pos, .verts = verts, .col = col, .tris = tris, .two_sided = true, .mips = self.textures.?.partMips(d.m, pi), .alpha = 1, .depth_write = true, .test_bias = 0 });
        };
        if (self.sim) |sm| {
            // The layer only routes the effects to the sink: no canvas of the picture's size.
            var layer = og.render.layer.Layer.initScaled(gpa, 1, 1, 1) catch return null;
            defer layer.deinit(gpa);
            layer.textures = &self.textures.?;
            layer.sink = sk;
            sm.draw(arena, &layer, cam, right, &self.cache.?, &self.fx_frames, model, frame);
        }
        const bg_depth = arena.alloc(f32, px[0] * px[1]) catch return null;
        @memset(bg_depth, std.math.inf(f32));
        const any = g.finish(bg_depth, px[0], px[1], cam, .{ 0, 0 }, null) catch false;
        if (self.out != null and (self.tex_w != px[0] or self.tex_h != px[1])) {
            c.SDL_DestroyTexture(self.out);
            self.out = null;
        }
        if (self.out == null) {
            self.out = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_TARGET, @intCast(px[0]), @intCast(px[1]));
            self.tex_w = px[0];
            self.tex_h = px[1];
        }
        const out = self.out orelse return null;
        const old = c.SDL_GetRenderTarget(r);
        var dc: [4]u8 = undefined;
        _ = c.SDL_GetRenderDrawColor(r, &dc[0], &dc[1], &dc[2], &dc[3]);
        _ = c.SDL_SetRenderTarget(r, out);
        const bg = lay.canvas.preview_bg;
        _ = c.SDL_SetRenderDrawColor(r, bg[0], bg[1], bg[2], 255);
        _ = c.SDL_RenderClear(r);
        if (any) for ([_]?*c.SDL_Texture{ g.tex, if (g.glow_used) g.glow_tex else null, if (g.screen_used) g.screen_tex else null }) |t| if (t) |x| {
            _ = c.SDL_RenderTexture(r, x, null, null);
        };
        _ = c.SDL_SetRenderTarget(r, old);
        _ = c.SDL_SetRenderDrawColor(r, dc[0], dc[1], dc[2], dc[3]);
        // Run now: the next preview's pass (a thumbnail) reuses the targets read here.
        _ = c.SDL_FlushRenderer(r);
        return out;
    }
};

/// A model drawn in the preview and its posed points (the weapon's, a rider's at the link).
const Part = struct { m: *const og.actor.model_cache.Model, pts: [][][3]f32 };

/// Attach point `i` of the model on the picture (pixels) and how far a unit of its offset
/// x, y, z moves it there (`d`).
pub const Point = struct { i: usize, at: [2]f32, d: [3][2]f32 };

/// The preview's view: the picture's centre `cx, cy`, pixels per model unit `k` about
/// height `ym`, the turn and tilt (cos, sin) and the eye's distance.
pub const View = struct {
    cx: f32,
    cy: f32,
    k: f32,
    ym: f32,
    yaw: [2]f32,
    pitch: [2]f32,
    far: f32,

    /// A point in the model's axes on the picture: x, y and depth.
    pub fn project(v: View, p: [3]f32) [3]f32 {
        const x = p[0] * v.yaw[0] + p[2] * v.yaw[1];
        const z = -p[0] * v.yaw[1] + p[2] * v.yaw[0];
        // The tilt about the screen's horizontal axis through the framing centre.
        const y = (p[1] - v.ym) * v.pitch[0] - z * v.pitch[1];
        return .{ v.cx + x * v.k, v.cy - y * v.k, v.far + (p[1] - v.ym) * v.pitch[1] + z * v.pitch[0] };
    }
};

/// Attach point `h` of the model at `frame` with `off` added to its offset (mesh units,
/// before the local axes): on its bone (model_cache.linkPointOff), or `no_bone`'s in the
/// model's own space.
fn holdPoint(model: *const og.actor.model_cache.Model, frame: u32, h: og.core.model.HoldMode, off: [3]f32) ?[3]f32 {
    const p: [3]f32 = .{ h.params[0] + off[0], h.params[1] + off[1], h.params[2] + off[2] };
    if (h.bone == og.formats.mesh.no_bone) return p;
    if (model.frames.bones == 0 or h.bone >= model.frames.bones or h.bone >= model.mesh.joints.len) return null;
    const j = model.mesh.joints[h.bone];
    return og.actor.skin.transform(model.frames.matrix(@min(frame, model.frames.frames -| 1), h.bone), .{ j[0] + p[0], j[1] + p[1], j[2] + p[2] }, .row);
}

/// The offset change moving a point `d` pixels on the picture, `j[k]` being how far a unit
/// of offset k moves it there: the smallest one doing it (Jᵀ(J·Jᵀ)⁻¹·d; none when the
/// three move it along one line).
pub fn offsetFor(j: [3][2]f32, d: [2]f32) [3]f32 {
    var m: [3]f32 = @splat(0);
    for (j) |r| m = .{ m[0] + r[0] * r[0], m[1] + r[0] * r[1], m[2] + r[1] * r[1] };
    const det = m[0] * m[2] - m[1] * m[1];
    if (@abs(det) < 1e-9) return @splat(0);
    const l = [2]f32{ (m[2] * d[0] - m[1] * d[1]) / det, (m[0] * d[1] - m[1] * d[0]) / det };
    var out: [3]f32 = undefined;
    for (j, &out) |r, *o| o.* = r[0] * l[0] + r[1] * l[1];
    return out;
}

test offsetFor {
    // Turned and tilted: the change found moves the point by the drag, in the picture's plane.
    const v: View = .{ .cx = 100, .cy = 80, .k = 3, .ym = 2, .yaw = .{ @cos(0.7), @sin(0.7) }, .pitch = .{ @cos(0.3), @sin(0.3) }, .far = 1e4 };
    const p = [3]f32{ 1, 5, -2 };
    const p0 = v.project(p);
    var j: [3][2]f32 = undefined;
    for (0..3) |ax| {
        var q = p;
        q[ax] += 1;
        const p1 = v.project(q);
        j[ax] = .{ p1[0] - p0[0], p1[1] - p0[1] };
    }
    const d = offsetFor(j, .{ 12, -7 });
    const moved = v.project(.{ p[0] + d[0], p[1] + d[1], p[2] + d[2] });
    try std.testing.expectApproxEqAbs(@as(f32, 12), moved[0] - p0[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, -7), moved[1] - p0[1], 1e-3);
    try std.testing.expectApproxEqAbs(p0[2], moved[2], 1e-3);
    // Straight on, unturned: pixels over k along x and up y.
    const s = offsetFor(.{ .{ 2, 0 }, .{ 0, -2 }, .{ 0, 0 } }, .{ 4, 6 });
    try std.testing.expectApproxEqAbs(@as(f32, 2), s[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -3), s[1], 1e-6);
    try std.testing.expectEqual(@as(f32, 0), s[2]);
    try std.testing.expectEqual([3]f32{ 0, 0, 0 }, offsetFor(.{ .{ 1, 1 }, .{ 2, 2 }, .{ 0, 0 } }, .{ 1, 0 }));
}

/// A triangle's edges on `img` (lit by `shade`; no depth test: every edge shows).
fn wireTriangle(img: *og.image.Image, p: [3][3]f32, shade: f32) void {
    const v: u8 = @intFromFloat(std.math.clamp(90 + 165 * shade, 0, 255));
    const col = [4]u8{ v / 2, @intCast(@min(255, @as(u32, v) * 3 / 4)), v, 255 };
    for (0..3) |k| {
        const a = p[k];
        const b = p[(k + 1) % 3];
        const n: usize = @intFromFloat(@max(1, @ceil(@max(@abs(b[0] - a[0]), @abs(b[1] - a[1])))));
        for (0..n + 1) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const x = a[0] + (b[0] - a[0]) * t;
            const y = a[1] + (b[1] - a[1]) * t;
            if (x < 0 or y < 0 or x >= @as(f32, @floatFromInt(img.width)) or y >= @as(f32, @floatFromInt(img.height))) continue;
            const at = (@as(usize, @intFromFloat(y)) * img.width + @as(usize, @intFromFloat(x))) * 4;
            img.pixels[at..][0..4].* = col;
        }
    }
}

/// Animations an actor script registers: logical name (`long_attack`) and file
/// animation (`atakgun`); idle ones under their file name. Stances other than 0 (1 —
/// a weapon in both hands: `attack_flame`) get theirs as `name/stance`.
pub const Anim = struct { slot: []const u8, file: []const u8 };

/// `name = "x"` of a line's call (OG Script), its string.
fn namedStr(l: []const u8, name: []const u8) ?[]const u8 {
    var buf: [40]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s} = \"", .{name}) catch return null;
    const at = std.mem.indexOf(u8, l, key) orelse return null;
    const from = at + key.len;
    const to = std.mem.indexOfScalarPos(u8, l, from, '"') orelse return null;
    return l[from..to];
}

/// `name = 3` of a line's call, its number.
fn namedInt(l: []const u8, name: []const u8) ?i32 {
    var buf: [40]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s} = ", .{name}) catch return null;
    const at = std.mem.indexOf(u8, l, key) orelse return null;
    var e = at + key.len;
    while (e < l.len and (std.ascii.isDigit(l[e]) or l[e] == '-')) e += 1;
    return std.fmt.parseInt(i32, l[at + key.len .. e], 10) catch null;
}

pub fn anims(a: Allocator, act: []const u8) []const Anim {
    var list: std.ArrayList(Anim) = .empty;
    var lines = std.mem.splitScalar(u8, act, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        // An OpenGorky look block's `Slot(state = 0, name = "walk", anim = "walk")`,
        // `Idle(state = 0, anim = "ryk", …)` (one a line, as the writer puts them).
        if (std.mem.indexOf(u8, l, "Slot(") != null or std.mem.indexOf(u8, l, "Idle(") != null) {
            const is_idle = std.mem.indexOf(u8, l, "Idle(") != null;
            const st = namedInt(l, "state") orelse 0;
            const file = namedStr(l, "anim") orelse continue;
            const name = if (is_idle) file else namedStr(l, "name") orelse continue;
            const slot = if (st == 0) name else std.fmt.allocPrint(a, "{s}/{d}", .{ name, st }) catch continue;
            for (list.items) |x| {
                if (std.mem.eql(u8, x.slot, slot)) break;
            } else list.append(a, .{ .slot = slot, .file = file }) catch {};
            continue;
        }
        const idle = std.mem.startsWith(u8, l, "RegisterIdleAnimation(");
        if (!idle and !std.mem.startsWith(u8, l, "RegisterAnimation(")) continue;
        const open = std.mem.indexOfScalar(u8, l, '(').? + 1;
        const comma = std.mem.indexOfScalarPos(u8, l, open, ',') orelse continue;
        const stance = std.mem.trim(u8, l[open..comma], " ");
        var it = std.mem.splitScalar(u8, l, '"');
        _ = it.next();
        const name = it.next() orelse continue;
        _ = it.next();
        const file = if (idle) name else it.next() orelse continue;
        const slot = if (std.mem.eql(u8, stance, "0")) name else std.fmt.allocPrint(a, "{s}/{s}", .{ name, stance }) catch continue;
        for (list.items) |x| {
            if (std.mem.eql(u8, x.slot, slot)) break;
        } else list.append(a, .{ .slot = slot, .file = file }) catch {};
    }
    std.mem.sort(Anim, list.items, {}, struct {
        fn f(_: void, x: Anim, y: Anim) bool {
            return std.ascii.lessThanIgnoreCase(x.slot, y.slot);
        }
    }.f);
    return list.items;
}

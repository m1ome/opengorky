//! Enemy preview: its model (the look's `meshFile`) posed in an animation at the
//! game's 30 frames a second, drawn by the engine's rasterizer into a texture
//! (as `gorky-tool model`, src/tool/models.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const Cache = og.actor.model_cache.Cache;
const fx = @import("preview_fx.zig");

pub const size = 512;

/// A weapon in the actor's hand: its model and the actor model's hold point
/// (`two_hands` for a two-handed item, else `one_hand`; actors.zig in the viewer).
pub const Held = struct {
    mesh: []const u8,
    link: []const u8,
    /// The strike's effects (flash, projectile, hit), the game's by weapon nameID.
    strike: ?fx.Strike = null,
};

/// A fighter riding the model at its link point (catalog.Rider), in its own animation
/// `anim`; `act`: one played once from the model's first frame, then `anim` again.
pub const Rider = struct { mesh: []const u8, link: []const u8, anim: []const u8, act: []const u8 = "" };

/// A rider's animation and frames shown (now and the draw before: its frame sounds).
const RiderShown = struct { mesh: []const u8 = "", anim: []const u8 = "", key: u64 = 0, prev: ?u32 = null, now: u32 = 0 };

pub const Preview = struct {
    cache: ?Cache = null,
    tex: ?*c.SDL_Texture = null,
    /// What is shown: model and animation file name (for the fixed framing).
    key_buf: [128]u8 = undefined,
    key_len: usize = 0,
    /// Vertical centre and scale for the whole animation (no jumping between frames).
    frame_y: f32 = 0,
    frame_k: f32 = 1,
    start_ms: u64 = 0,
    yaw: f32 = 210,
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
    /// Global frame shown and the one before it (null: the animation just started),
    /// for its frame sounds.
    frame: u32 = 0,
    prev: ?u32 = null,
    drawn_ms: u64 = 0,
    /// Stopped on this frame of the animation (from its first); null — playing.
    paused: ?u32 = null,
    /// The shown animation's frame count and the shown frame's place in it.
    frames: u32 = 1,
    at: u32 = 0,

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
    }

    /// Models read again on the next draw (a model edited, undone or saved).
    pub fn reload(self: *Preview) void {
        if (self.sim) |sm| sm.destroy();
        self.sim = null;
        if (self.cache) |*cc| {
            self.fx_frames.deinit(cc.gpa);
            self.fx_frames = .{};
            cc.deinit();
        }
        self.cache = null;
        self.key_len = 0;
    }

    /// Model `mesh` in animation `anim` (a file animation name) at the current time;
    /// null — no such model.
    /// `overlay` gives unsaved model files (new looks).
    pub fn draw(self: *Preview, gpa: Allocator, io: std.Io, dat: std.Io.Dir, r: *c.SDL_Renderer, overlay: og.actor.model_cache.Overlay, mesh: []const u8, anim: []const u8, held: ?Held, riders: []const Rider) ?*c.SDL_Texture {
        if (self.cache == null) {
            self.cache = Cache.open(io, gpa, dat) catch return null;
            self.cache.?.overlay = overlay;
        }
        const model = self.cache.?.get(mesh) orelse return null;
        // A model without animations (a prop: chaingun, a crate) in its one pose.
        const rest: og.formats.anim.Animation = .{ .name = "", .first = 0, .last = 0, .speed = 0, .sounds = &.{} };
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
            self.frame_k = @as(f32, size) * 0.8 / @max(hi - lo, 1);
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
        const Part = struct { m: *const og.actor.model_cache.Model, pts: [][][3]f32 };
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
        // Framing: with effects, the box they reach too (in the model's axes: world
        // (x, y, z)/(aS·unit) is (x, z, y)).
        var k = self.frame_k;
        var cx: f32 = size / 2;
        var ym = self.frame_y;
        const height = @as(f32, size) * 0.8 / self.frame_k;
        if (self.sim) |sm| if (sm.box[0][0] <= sm.box[1][0]) {
            const u = og.actor.model_cache.default_actor_scale * model.unitScale();
            var lo = [2]f32{ -height * 0.3, self.frame_y - height / 2 };
            var hi = [2]f32{ height * 0.3, self.frame_y + height / 2 };
            for (0..8) |i| {
                const w = [3]f32{ sm.box[i & 1][0], sm.box[(i >> 1) & 1][1], sm.box[i >> 2][2] };
                const sx = (w[0] * cy + w[1] * sy) / u;
                lo = .{ @min(lo[0], sx), @min(lo[1], w[2] / u) };
                hi = .{ @max(hi[0], sx), @max(hi[1], w[2] / u) };
            }
            k = @min(k, @as(f32, size) * 0.9 / @max(hi[0] - lo[0], hi[1] - lo[1]));
            cx = size / 2 - (lo[0] + hi[0]) / 2 * k;
            ym = (lo[1] + hi[1]) / 2;
        };
        // The engine's camera for the effects, the preview's view: orthographic but for
        // an eye `far` away; scale 1/(aS·unit) takes world points to the model's axes.
        const far = 1e4 * @max(height, 1);
        const cam: og.actor.camera.Camera = .{ .persp = .{
            .eye = .{ sy * far, ym, -cy * far },
            .fwd = .{ -sy, 0, cy },
            .right = .{ cy, 0, sy },
            .up = .{ 0, 1, 0 },
            .focal = k * far,
            .focal_y = k * far,
            .cx = cx,
            .cy = size / 2,
            .scale = 1 / (og.actor.model_cache.default_actor_scale * model.unitScale()),
            .zlevel = 0,
        } };
        var layer = og.render.layer.Layer.initScaled(gpa, size, size, 1) catch return null;
        defer layer.deinit(gpa);
        const canvas = &layer.canvas;
        var px: usize = 0;
        while (px < canvas.img.pixels.len) : (px += 4) canvas.img.pixels[px..][0..4].* = .{ 17, 18, 20, 255 };
        const light = [3]f32{ 0.4, 0.7, -0.6 };
        for (drawn.items) |dd| if (dd) |d| for (d.m.mesh.parts, d.pts, 0..) |part, ppts, pi| {
            // Points in the actor model's axes (the weapon's are in its units already).
            for (ppts) |*p| p.* = og.actor.model_cache.localPoint(model, p.*);
            for (part.triangles) |t| {
                var sp: [3][3]f32 = undefined;
                var uv: [3][2]f32 = undefined;
                for (0..3) |i| {
                    const p = ppts[t[i]];
                    const x = p[0] * cy + p[2] * sy;
                    const z = -p[0] * sy + p[2] * cy;
                    sp[i] = .{ cx + x * k, size / 2 - (p[1] - ym) * k, far + z };
                    uv[i] = part.vertices[t[i]].uv;
                }
                const nrm = og.vec.cross(og.vec.sub(ppts[t[1]], ppts[t[0]]), og.vec.sub(ppts[t[2]], ppts[t[0]]));
                const len = og.vec.len(nrm);
                const shade = if (len > 0) 0.45 + 0.55 * @abs((nrm[0] * light[0] + nrm[1] * light[1] + nrm[2] * light[2]) / len) else 1;
                if (self.wire) wireTriangle(&canvas.img, sp, shade) else canvas.triangle(sp, uv, d.m.partTexture(pi), og.render.raster.gray(shade));
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
        if (self.tex == null) self.tex = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STREAMING, size, size);
        const t = self.tex orelse return null;
        _ = c.SDL_UpdateTexture(t, null, layer.canvas.img.pixels.ptr, size * 4);
        return t;
    }
};

/// A triangle's edges on `img` (lit by `shade`; no depth test: every edge shows).
fn wireTriangle(img: *og.formats.image.Image, p: [3][3]f32, shade: f32) void {
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

pub fn anims(a: Allocator, act: []const u8) []const Anim {
    var list: std.ArrayList(Anim) = .empty;
    var lines = std.mem.splitScalar(u8, act, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
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

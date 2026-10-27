//! A weapon's attack effects in the model preview: the game's own calls (fx/launch.zig
//! projectile, fx/hits.zig flash before the hit and the hit itself) on a world holding
//! only the effects, on the strike's countdown (combat/attack.zig), aimed two battle cells
//! ahead of the attacker; drawn by the engine's layer rasterizer (render/layer.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const World = og.state.world.World;
const Object = og.script.object.Object;
const Layer = og.render.layer.Layer;
const Model = og.actor.model_cache.Model;
const Cache = og.actor.model_cache.Cache;
const Camera = og.actor.camera.Camera;
const Image = og.formats.image.Image;
const F = og.formats.adjust.getFloat;

/// What strikes: the weapon's effects id (battle/generic.zig fxId), the attacker's nameID,
/// the frames (from the animation's first) of the hit and of the flash before it.
pub const Strike = struct { fx: i32, hero: i32, hit: u32, pre: ?u32 = null };

/// The aim on the floor: two battle cells ahead (a cell is xSize = 350·aS: speedScale
/// 0.02·xSize = 7·aS, 0x4b49f0).
pub const ahead = 700;
/// Frames simulated at most after the hit when finding the effects' end.
const max_tail = 300;

/// The weapon's effects id as the battle takes it (generic.fxId: `fx_as`, `projectile`,
/// else its nameID).
pub fn fxId(gpa: Allocator, name_id: i32, fx_as: i32, projectile: ?[]const u8) i32 {
    var o: Object = .{ .name = "", .class = undefined };
    defer o.vars.deinit(gpa);
    o.declare(gpa, "nameid", .{ .type = .int, .value = .{ .int = name_id } }) catch return name_id;
    o.declare(gpa, "fx_as", .{ .type = .int, .value = .{ .int = fx_as } }) catch return name_id;
    if (projectile) |p| o.declare(gpa, "projectile", .{ .type = .string, .value = .{ .string = p } }) catch return name_id;
    return og.battle.generic.fxId(&o);
}

pub const Sim = struct {
    /// Only what the fx code touches is set: effects, the outbox, models and the level
    /// (a battle level of default actorScale: explosions lifted as in battle).
    w: World,
    who: Object,
    /// The attacker's engine part: its model and animation, for the effects that follow
    /// its link points (world/spawn.zig aimFlames, aimBalls).
    native: og.state.object.Native = og.state.object.nativeFor(".act"),
    names: [2][]u8 = .{ &.{}, &.{} },
    level: Object,
    level_class: og.script.object.Class = .{ .name = "combatlevel", .parent = null },
    strike: Strike,
    /// Frames to show: the animation's or longer while the effects last.
    len: u32 = 0,
    /// World box the effects reach over the whole strike (the preview's framing).
    box: [2][3]f32 = .{ @splat(std.math.inf(f32)), @splat(-std.math.inf(f32)) },
    /// Last frame simulated.
    at: ?u32 = null,
    launched: bool = false,
    hit: bool = false,
    flight: u32 = 0,

    /// `mesh` in file animation `anim` strikes.
    pub fn create(gpa: Allocator, io: std.Io, models: *Cache, s: Strike, mesh: []const u8, anim: []const u8) !*Sim {
        const self = try gpa.create(Sim);
        errdefer gpa.destroy(self);
        self.* = .{
            .w = .{
                .gpa = gpa,
                .io = io,
                .arena_state = .init(gpa),
                .rt = undefined,
                .level_name = "",
                .res = .{ .other = undefined, .sprites = undefined, .common = undefined, .lang = undefined, .dat = undefined, .models = models },
                .immunity = undefined,
            },
            .who = .{ .name = "", .class = undefined },
            .level = .{ .name = "", .class = undefined },
            .strike = s,
        };
        self.level.class = &self.level_class;
        self.who.host = &self.native;
        errdefer for (self.names) |n| gpa.free(n);
        self.names = .{ try gpa.dupe(u8, mesh), try gpa.dupe(u8, anim) };
        self.native.actor.anim = self.names[1];
        self.native.actor.loop = false;
        self.w.level = &self.level;
        errdefer self.who.vars.deinit(gpa);
        // At the origin facing +y: the preview model's angle 0 (fields.modelAngle).
        inline for (.{ "x", "y", "z" }) |n| try self.who.declare(gpa, n, .{ .type = .float, .value = .{ .float = 0 } });
        try self.who.declare(gpa, "angle", .{ .type = .float, .value = .{ .float = std.math.pi / 2.0 } });
        try self.who.declare(gpa, "nameid", .{ .type = .int, .value = .{ .int = s.hero } });
        try self.who.declare(gpa, "meshfile", .{ .type = .string, .value = .{ .string = self.names[0] } });
        // The length: until the hit is done and the effects are gone.
        var f: u32 = 0;
        while (f < s.hit + max_tail) : (f += 1) {
            self.run(f);
            self.grow();
            if (self.hit and !self.busy()) break;
        }
        self.len = f + 1;
        self.reset();
        return self;
    }

    pub fn destroy(self: *Sim) void {
        const gpa = self.w.gpa;
        self.reset();
        self.who.vars.deinit(gpa);
        for (self.names) |n| gpa.free(n);
        self.w.arena_state.deinit();
        gpa.destroy(self);
    }

    fn reset(self: *Sim) void {
        const gpa = self.w.gpa;
        self.w.effects.deinit(gpa);
        self.w.effects = .{};
        self.w.out.deinit(gpa);
        self.w.out = .{};
        self.at = null;
        self.launched = false;
        self.hit = false;
        self.flight = 0;
    }

    /// The box over the effects drawn now (billboards by half their half size: an
    /// explosion is several fighters tall, the fighter stays readable).
    fn grow(self: *Sim) void {
        const Box = struct {
            s: *Sim,
            pub fn put(b: @This(), bb: og.effects.batch.Billboard) !void {
                b.add(bb.pos, bb.half / 2);
            }
            fn add(b: @This(), p: [3]f32, h: f32) void {
                for (0..3) |k| {
                    b.s.box[0][k] = @min(b.s.box[0][k], p[k] - h);
                    b.s.box[1][k] = @max(b.s.box[1][k], p[k] + h);
                }
            }
        };
        const e = &self.w.effects;
        const as = self.w.actorScale();
        const b: Box = .{ .s = self };
        og.effects.batch.bitmaps(e.bitmaps.items, as, b) catch {};
        og.effects.batch.trails(e.trails.items, as, b) catch {};
        og.effects.batch.projectilePlanes(e.projectiles.items, as, b) catch {};
        for (e.projectiles.items) |pr| b.add(pr.pos, 0);
        for (e.beams.items) |bm| if (bm.kind == .lightning) {
            b.add(bm.to, 0);
            b.add(.{ bm.to[0], bm.to[1], bm.to[2] + 4 * 1400 * as }, 0);
        };
        for (e.flames.items) |fl| for (fl.parts.items) |p| b.add(p.pos, 0);
    }

    fn busy(self: *Sim) bool {
        const e = &self.w.effects;
        return e.bitmaps.items.len + e.attached.items.len + e.projectiles.items.len + e.trails.items.len + e.beams.items.len + e.flames.items.len + e.streams.items.len + e.spins.items.len > 0;
    }

    fn target(self: *Sim) [3]f32 {
        return .{ 0, ahead * self.w.actorScale(), 0 };
    }

    /// Effects as at frame `to`: on from the last frame, or again from the start.
    pub fn run(self: *Sim, to: u32) void {
        if (self.at) |a| if (to < a) self.reset();
        var f: u32 = if (self.at) |a| a + 1 else 0;
        while (f <= to) : (f += 1) {
            // The attacker one frame on per tick (the preview's frame), streams aimed from it.
            self.native.actor.anim_ticks = @floatFromInt(f);
            og.world.spawn.aimFlames(&self.w);
            og.world.spawn.aimBalls(&self.w);
            if (f > 0) self.w.effects.tick(self.w.gpa, self.w.crt());
            self.events(f);
            self.at = f;
        }
    }

    /// The strike's countdown (combat/attack.zig stepPending): the flash before the hit,
    /// the projectile at the hit, the hit when it lands (or at once without one).
    fn events(self: *Sim, f: u32) void {
        const w = &self.w;
        const id = self.strike.fx;
        if (self.strike.pre) |p| if (f == p) og.fx.hits.preFlash(w, &self.who, id, self.target());
        if (f == self.strike.hit and !self.launched) {
            self.launched = true;
            self.flight = og.fx.launch.launchId(w, &self.who, id, self.target(), false);
        }
        if (self.launched and !self.hit and (self.flight == 0 or !w.effects.projectileAlive(self.flight))) {
            self.hit = true;
            // An Incubus ball would lie for two rounds: the preview blows it up at once.
            w.effects.endProjectile(self.flight);
            og.fx.hits.onHitAs(w, &self.who, id, self.target(), false);
        }
    }

    /// Sound names the effects asked for since the last call.
    pub fn sounds(self: *Sim, out: []([]const u8)) []const []const u8 {
        var n: usize = 0;
        for (self.w.out.drainSounds()) |ev| if (n < out.len) {
            out[n] = ev.name;
            n += 1;
        };
        return out[0..n];
    }

    /// The effects over `layer` (camera `cam`, screen-right axis `right`), the attacker
    /// being `model` in frame `frame` at the origin.
    pub fn draw(self: *Sim, arena: Allocator, layer: *Layer, cam: Camera, right: [3]f32, cache: *Cache, frames: *Frames, model: *const Model, frame: u32) void {
        const e = &self.w.effects;
        const as = self.w.actorScale();
        const pl: Layer.Placement = .{ .pos = .{ 0, 0, 0 }, .angle = 0, .scale = as, .frame = frame };
        // Flashes on link points (viewer/level/actors.zig attachedEffects).
        for (e.attached.items) |at| {
            if (at.delay > 0) continue;
            const mesh = cache.get(at.mesh) orelse continue;
            const link = model.mesh.holdMode(at.link) orelse continue;
            const tex = frames.get(cache, at.effect);
            if (tex.len == 0) continue;
            layer.drawEffect(arena, cam, model, pl, .{ .model = mesh, .link = link, .offset = at.offset, .rot = at.rot, .scale = at.scale }, tex[@intCast((e.ticks -% at.start) % tex.len)]) catch {};
        }
        const d: Draw = .{ .arena = arena, .layer = layer, .cam = cam, .right = right, .cache = cache, .frames = frames };
        for (e.projectiles.items) |pr| d.projectile(pr, as);
        for (e.beams.items) |bm| d.beam(bm, e.ticks, as, model, frame);
        // Flamethrower particles (viewer/level/effects.zig): additive "flame2", half-size
        // min(age·attack_flame_scale + attack_flame_add, attack_flame_range) screen pixels
        // (a world unit is a pixel in the game's view).
        for (e.flames.items) |fl| for (fl.parts.items, 0..) |p, i| {
            const t = 1 - og.num.toF32(p.age) / og.num.toF32(fl.life);
            const half = @min(og.num.toF32(p.age) * F("attack_flame_scale", 1.6) + 8, 160);
            const old = og.formats.adjust.getRgb("attack_flame_col", .{ 255, 160, 0 });
            const new = og.formats.adjust.getRgb("attack_flame_col2", .{ 60, 60, 255 });
            var rgb: [3]f32 = undefined;
            for (&rgb, old, new) |*c, o, n| c.* = (og.num.toF32(o) + (og.num.toF32(n) - og.num.toF32(o)) * t) / 255;
            d.put(.{ .name = "flame2", .frame = @intCast((e.ticks + i) % 15), .pos = p.pos, .half = half, .rgb = rgb }) catch {};
        };
        og.effects.batch.bitmaps(e.bitmaps.items, as, d) catch {};
        og.effects.batch.trails(e.trails.items, as, d) catch {};
        og.effects.batch.projectilePlanes(e.projectiles.items, as, d) catch {};
    }
};

/// Effect frames (`gfx_3d\effects\<name>` per its `.dsc`), decoded once per name.
pub const Frames = struct {
    map: std.StringHashMapUnmanaged([]Image) = .empty,

    pub fn get(self: *Frames, cache: *Cache, name: []const u8) []const Image {
        const gpa = cache.gpa;
        var key_buf: [64]u8 = undefined;
        if (name.len == 0 or name.len > key_buf.len) return &.{};
        const key = std.ascii.lowerString(&key_buf, name);
        if (self.map.get(key)) |f| return f;
        var list: std.ArrayList(Image) = .empty;
        if (cache.effect(name)) |d| for (d.frames.items) |f| {
            var buf: [160]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "gfx_3d\\effects\\{s}\\{s}", .{ name, f }) catch continue;
            const bytes = cache.readFile(path) catch continue;
            const img = og.formats.tex3df.decode(gpa, bytes) catch continue;
            list.append(gpa, img) catch break;
        };
        const owned = list.toOwnedSlice(gpa) catch return &.{};
        const k = gpa.dupe(u8, key) catch return owned;
        self.map.put(gpa, k, owned) catch gpa.free(k);
        return owned;
    }

    pub fn deinit(self: *Frames, gpa: Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.*) |*img| img.deinit(gpa);
            gpa.free(e.value_ptr.*);
            gpa.free(e.key_ptr.*);
        }
        self.map.deinit(gpa);
    }
};

/// Drawing onto the preview layer (the viewer's effects_view.zig on SDL, here rasterized).
const Draw = struct {
    arena: Allocator,
    layer: *Layer,
    cam: Camera,
    right: [3]f32,
    cache: *Cache,
    frames: *Frames,

    /// A batch billboard facing the camera (og.effects.batch sink; blend by its `.dsc`).
    pub fn put(d: Draw, b: og.effects.batch.Billboard) !void {
        const fr = d.frames.get(d.cache, b.name);
        if (fr.len == 0) return;
        const dsc = d.cache.effect(b.name) orelse return;
        const blend: Layer.BillboardBlend = switch (dsc.blend) {
            .add => .add,
            .alpha, .opaque_ => .alpha,
            else => .screen,
        };
        const ax = scaled(d.right, b.half);
        const p = b.pos;
        const h = b.half;
        const corners = [4][3]f32{
            .{ p[0] - ax[0], p[1] - ax[1], p[2] + h },
            .{ p[0] + ax[0], p[1] + ax[1], p[2] + h },
            .{ p[0] + ax[0], p[1] + ax[1], p[2] - h },
            .{ p[0] - ax[0], p[1] - ax[1], p[2] - h },
        };
        d.layer.billboard(d.cam, corners, fr[b.frame % fr.len], b.alpha, b.rgb, blend);
    }

    fn screen(d: Draw, p: [3]f32) [3]f32 {
        const q = d.cam.project(p);
        return .{ q.x, q.y, -q.depth };
    }

    /// One projectile (viewer/level/effects.zig drawProjectile): its mesh, the Cutter
    /// Pill bullet, a rocket's body and exhaust.
    fn projectile(d: Draw, pr: og.effects.projectile.Projectile, as: f32) void {
        if (pr.done) return;
        if (pr.mesh.len > 0) d.mesh(pr.mesh, pr.pos, .{ -pr.dir[0], -pr.dir[1], -pr.dir[2] }, pr.roll, as * pr.mesh_scale * pr.k);
        if (pr.bullet) {
            const at = og.vec.sub(pr.pos, scaled(pr.dir, 240 * as));
            return d.effectMesh(pr.effect, 0, at, pr.dir, pr.mesh_scale * as, .alpha);
        }
        if (pr.rocket) {
            const back = og.vec.sub(pr.pos, scaled(pr.dir, 220 * as));
            d.effectMesh("Rocket", @intCast((pr.ticks / 2) % 2), back, pr.dir, 0.4 * as, .screen);
            d.effectMesh(pr.effect, 0, pr.pos, pr.dir, 0.3 * as * pr.mesh_scale, .alpha);
        }
    }

    /// Projectile mesh with its texture (effects_view.zig drawMeshWith: tumble `roll`,
    /// pitch, then the heading turn).
    fn mesh(d: Draw, name: []const u8, pos: [3]f32, dir: [3]f32, roll: f32, scale: f32) void {
        const m = d.cache.get(name) orelse return;
        const pts = og.actor.skin.pose(d.arena, m.mesh, m.frames, 0, .row) catch return;
        const s = scale * m.unitScale();
        const yaw = og.fields.modelAngle(og.fields.facing(dir[0], dir[1]));
        const pitch = std.math.atan2(dir[2], og.vec.len2(dir));
        const cr = @cos(roll);
        const sr = @sin(roll);
        for (m.mesh.parts, pts, 0..) |part, ppts, pi| for (part.triangles) |t| {
            var sp: [3][3]f32 = undefined;
            var uv: [3][2]f32 = undefined;
            for (0..3) |k| {
                const p = ppts[t[k]];
                const l = og.actor.model_cache.localPoint(m, .{ p[0], p[1] * cr - p[2] * sr, p[1] * sr + p[2] * cr });
                const lp = [3]f32{ l[0], l[2] * @sin(pitch) + l[1] * @cos(pitch), l[2] * @cos(pitch) - l[1] * @sin(pitch) };
                sp[k] = d.screen(og.actor.model_cache.toWorldLocal(lp, s, pos, @cos(yaw), @sin(yaw)));
                uv[k] = part.vertices[t[k]].uv;
            }
            d.layer.canvas.triangle(sp, uv, m.partTexture(pi), og.render.raster.gray(1));
        };
    }

    /// Effect mesh (`chaingun.msh`, crossed planes along +X) with an effect frame, +X
    /// along `dir` (effects_view.zig drawEffectMesh: rocket body and exhaust).
    fn effectMesh(d: Draw, effect: []const u8, frame: u32, pos: [3]f32, dir: [3]f32, scale: f32, blend: og.effects.dsc.Blend) void {
        const fr = d.frames.get(d.cache, effect);
        if (fr.len == 0) return;
        const m = d.cache.get("chaingun") orelse return;
        const pts = og.actor.skin.pose(d.arena, m.mesh, m.frames, 0, .row) catch return;
        const s = scale * m.unitScale();
        const pitch = std.math.atan2(dir[2], og.vec.len2(dir));
        const yaw = std.math.atan2(dir[1], dir[0]);
        const cp = @cos(pitch);
        const sp_ = @sin(pitch);
        for (m.mesh.parts, pts) |part, ppts| for (part.triangles) |t| {
            var sp: [3][3]f32 = undefined;
            var uv: [3][2]f32 = undefined;
            for (0..3) |k| {
                const p = ppts[t[k]];
                sp[k] = d.screen(og.actor.model_cache.toWorld(m, .{ p[0] * cp - p[1] * sp_, p[0] * sp_ + p[1] * cp, p[2] }, s, pos, @cos(yaw), @sin(yaw)));
                uv[k] = part.vertices[t[k]].uv;
            }
            d.shaded(sp, uv, fr[frame % fr.len], blend);
        };
    }

    fn shaded(d: Draw, sp: [3][3]f32, uv: [3][2]f32, tex: Image, blend: og.effects.dsc.Blend) void {
        const sh: og.render.raster.Canvas.Shade = switch (blend) {
            .alpha => .{ .depth_write = false, .tex_alpha = true },
            .add => .{ .add = &d.layer.glow, .depth_write = false },
            else => .{ .add = &d.layer.screen, .screen = true, .depth_write = false },
        };
        d.layer.canvas.triangleShaded(sp, uv, tex, og.render.raster.gray(1), sh);
    }

    /// Ribbon A→B offset ±`side` across (effects_view.zig ribbon), additive. The game
    /// looks down on a flat ribbon; the preview looks level, so it is turned to face the
    /// view, the same width.
    fn ribbon(d: Draw, name: []const u8, frame: u32, a: [3]f32, b: [3]f32, flat: [3]f32) void {
        const fr = d.frames.get(d.cache, name);
        if (fr.len == 0) return;
        const across = og.vec.cross(og.vec.sub(b, a), .{ -d.right[1], d.right[0], 0 });
        const l = og.vec.len(across);
        const side = if (l > 1e-6) scaled(across, og.vec.len(flat) / l) else flat;
        const c = [4][3]f32{ og.vec.add(a, side), og.vec.add(b, side), og.vec.sub(b, side), og.vec.sub(a, side) };
        const uv = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
        const s = [4][3]f32{ d.screen(c[0]), d.screen(c[1]), d.screen(c[2]), d.screen(c[3]) };
        d.shaded(.{ s[0], s[1], s[2] }, .{ uv[0], uv[1], uv[2] }, fr[frame % fr.len], .add);
        d.shaded(.{ s[0], s[2], s[3] }, .{ uv[0], uv[2], uv[3] }, fr[frame % fr.len], .add);
    }

    /// Beams a hero's weapon makes (viewer/level/effects.zig drawBeam): the ion rifle's,
    /// from the attacker's link point both ways, and the satellite's lightning.
    fn beam(d: Draw, bm: og.effects.beam.Beam, ticks: u64, as: f32, model: *const Model, frame: u32) void {
        const fr: u32 = @intCast((ticks / bm.div) % 4096);
        const half = as * bm.size;
        switch (bm.kind) {
            .ion => {
                var o = bm.from;
                var dir = bm.dir;
                // The link point and its x axis (0x429ca0) on the attacker at the origin.
                const mc = og.actor.model_cache;
                const s = as * model.unitScale();
                if (mc.linkPoint(model, frame, bm.link)) |l0| if (mc.linkPointOff(model, frame, bm.link, .{ 1, 0, 0 })) |l1| {
                    const p0 = mc.toWorld(model, l0, s, .{ 0, 0, 0 }, 1, 0);
                    const p1 = mc.toWorld(model, l1, s, .{ 0, 0, 0 }, 1, 0);
                    const ax = og.vec.normalize(.{ p1[0] - p0[0], p1[1] - p0[1], 0 });
                    o = .{ p0[0], p0[1], bm.from[2] };
                    dir = .{ ax[0] * @cos(bm.turn) - ax[1] * @sin(bm.turn), ax[0] * @sin(bm.turn) + ax[1] * @cos(bm.turn), 0 };
                };
                const side = [3]f32{ -dir[1] * half, dir[0] * half, 0 };
                const vs = F("attack_ion_vs", -155);
                const vk = F("attack_ion_vk", 5922);
                for ([_]f32{ -vs, -vs + 25 * 220 - vk }, [_]f32{ 220, -220 }) |start, step| {
                    var p = [3]f32{ o[0] + dir[0] * start * as, o[1] + dir[1] * start * as, o[2] };
                    for (0..25) |_| {
                        const q = [3]f32{ p[0] + dir[0] * step * as, p[1] + dir[1] * step * as, p[2] };
                        d.ribbon(bm.effect, fr, p, q, side);
                        p = q;
                    }
                }
            },
            .lightning => for (0..4) |k| {
                const z0 = og.num.toF32(k) * 1400 * as;
                d.ribbon(bm.effect, fr, .{ bm.to[0], bm.to[1], bm.to[2] + z0 }, .{ bm.to[0], bm.to[1], bm.to[2] + z0 + 1400 * as }, scaled(d.right, half));
            },
            // Monsters' beams (lasers, Medusa's current) and plain chains: not a weapon's.
            else => {},
        }
    }
};

fn scaled(v: [3]f32, k: f32) [3]f32 {
    return .{ v[0] * k, v[1] * k, v[2] * k };
}

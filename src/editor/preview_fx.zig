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
const Image = og.image.Image;

/// What strikes: the strike's effects (battle/generic.zig fxOf; its `weapon` null: the
/// simulation makes its own, Sim), the attacker's classic_id, the frames (from the
/// animation's first) of the hit and of the flash before it, and who strikes with what.
pub const Strike = struct { fx: og.battle.generic.Fx, hero: i32, hit: u32, pre: ?u32 = null, src: Src = .{} };

/// Who strikes with which weapon (classes: rules.classOf, `cw_riffle`), the weapon's
/// `effects_from` and `projectile`.
pub const Src = struct { who: og.rules.Who = .{ .id = 0 }, weapon: og.rules.Who = .{ .id = 0 }, fx_as: i32 = 0, projectile: ?[]const u8 = null };

/// Strike `src` with its hit and flash frames, its effects as the battle takes them.
pub fn strikeOf(gpa: Allocator, src: Src, hit: u32, pre: ?u32) Strike {
    return .{ .fx = fxOf(gpa, src), .hero = src.who.id, .hit = hit, .pre = pre, .src = src };
}

/// The aim on the floor: two battle cells ahead (a cell is xSize = 350·aS: speedScale
/// 0.02·xSize = 7·aS, 0x4b49f0).
const ahead = 700;
/// Frames simulated at most after the hit when finding the effects' end.
const max_tail = 300;

/// The strike's effects as the battle takes them (generic.fxOf: the weapon's `fx_as`,
/// `projectile`, else its classic_id; the rules' stages over them). Its `weapon` null:
/// the objects here live only for this call.
fn fxOf(gpa: Allocator, src: Src) og.battle.generic.Fx {
    const none: og.battle.generic.Fx = .same(src.weapon.id, src.who.id);
    var wcls: og.script.object.Class = undefined;
    var o: Object = .{ .name = "", .class = undefined };
    defer o.vars.deinit(gpa);
    var hcls: og.script.object.Class = undefined;
    var h: Object = .{ .name = "", .class = undefined };
    defer h.vars.deinit(gpa);
    standIn(gpa, &h, &hcls, src.who) catch return none;
    weaponObject(gpa, &o, &wcls, src, src.projectile) catch return none;
    var f = og.battle.generic.fxOf(&h, &o);
    f.weapon = null;
    return f;
}

/// `o` stands in for a game object of `w`: class `cls` of its class's ident, its nameid and
/// classic_id as a game object has them (world/start.zig) — what the rules (rules.who)
/// and the fx code read of it.
fn standIn(gpa: Allocator, o: *Object, cls: *og.script.object.Class, w: og.rules.Who) !void {
    cls.* = .{ .name = "", .parent = null, .ident = w.class };
    o.class = cls;
    try o.declare(gpa, "nameid", .{ .type = .int, .value = .{ .int = w.id } });
    try o.declare(gpa, "classic_id", .{ .type = .int, .value = .{ .int = w.id } });
}

/// `o` the striking weapon of `src` (`projectile`: its copy living as long as `o`).
fn weaponObject(gpa: Allocator, o: *Object, cls: *og.script.object.Class, src: Src, projectile: ?[]const u8) !void {
    try standIn(gpa, o, cls, src.weapon);
    try o.declare(gpa, "effects_from", .{ .type = .int, .value = .{ .int = src.fx_as } });
    if (projectile) |p| try o.declare(gpa, "projectile", .{ .type = .string, .value = .{ .string = p } });
}

pub const Sim = struct {
    /// Only what the fx code touches is set: effects, the outbox, models and the level
    /// (a battle level of default actorScale: explosions lifted as in battle).
    w: World,
    who: Object,
    who_class: og.script.object.Class = undefined,
    /// The striking weapon (the fx code reads its own effect values: fx.weapon).
    weapon: Object = .{ .name = "", .class = undefined },
    weapon_class: og.script.object.Class = undefined,
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
    /// Frame the strike landed (its hit's effects started) when last run.
    landed: u32 = 0,

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
                .res = .{ .models = models },
                .immunity = undefined,
            },
            .who = .{ .name = "", .class = undefined },
            .level = .{ .name = "", .class = undefined },
            .strike = s,
        };
        self.level.class = &self.level_class;
        self.w.fx_alone = true;
        self.who.host = &self.native;
        errdefer for (self.names) |n| gpa.free(n);
        self.names = .{ try gpa.dupe(u8, mesh), try gpa.dupe(u8, anim) };
        self.native.actor.anim = self.names[1];
        self.native.actor.loop = false;
        self.w.level = &self.level;
        errdefer self.who.vars.deinit(gpa);
        errdefer self.weapon.vars.deinit(gpa);
        try standIn(gpa, &self.who, &self.who_class, s.src.who);
        try weaponObject(gpa, &self.weapon, &self.weapon_class, s.src, if (s.src.projectile) |p| try self.w.arena_state.allocator().dupe(u8, p) else null);
        // At the origin facing +y: the preview model's angle 0 (fields.modelAngle).
        inline for (.{ "x", "y", "z" }) |n| try self.who.declare(gpa, n, .{ .type = .float, .value = .{ .float = 0 } });
        try self.who.declare(gpa, "angle", .{ .type = .float, .value = .{ .float = std.math.pi / 2.0 } });
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
        self.weapon.vars.deinit(gpa);
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
            pub fn particle(b: @This(), bb: og.effects.batch.Billboard) !void {
                b.add(bb.pos, 0);
            }
            pub fn ribbon(b: @This(), q: og.effects.batch.RibbonQuad) !void {
                b.add(q.a, 0);
                b.add(q.b, 0);
            }
            pub fn mesh(b: @This(), m: og.effects.batch.MeshAt) !void {
                b.add(m.pos, 0);
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
        // Not the ion's: 11000·aS long, it would shrink the rest.
        for (e.beams.items) |bm| if (bm.kind != .ion) og.effects.batch.beams(&.{bm}, e.ticks, as, self.links(), b) catch {};
        og.effects.batch.streams(e.streams.items, e.ticks, as, b) catch {};
        og.effects.batch.spins(e.spins.items, as, b) catch {};
        og.effects.batch.clouds(e.clouds.items, as, b) catch {};
        for (e.flames.items) |fl| for (fl.parts.items) |p| b.add(p.pos, 0);
    }

    /// The attacker's model points (at the origin, the shown frame; og.effects.batch links).
    fn links(self: *Sim) Links {
        const m = if (self.w.res.models) |c| c.get(self.names[0]) else null;
        return .{ .model = m, .as = self.w.actorScale(), .frame = if (self.at) |f| f else 0 };
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
        var fx = self.strike.fx;
        fx.weapon = &self.weapon;
        if (self.strike.pre) |p| if (f == p) og.fx.hits.preFlash(w, &self.who, fx, self.target());
        if (f == self.strike.hit and !self.launched) {
            self.launched = true;
            self.flight = og.fx.launch.launchId(w, &self.who, fx.launch, self.target(), false);
        }
        if (self.launched and !self.hit and (self.flight == 0 or !w.effects.projectileAlive(self.flight))) {
            self.hit = true;
            self.landed = f;
            // An Incubus ball would lie for two rounds: the preview blows it up at once.
            w.effects.endProjectile(self.flight);
            og.fx.hits.onHitFx(w, &self.who, fx, self.target(), false);
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
            const tex = frames.get(cache, layer.textures.?, at.effect);
            if (tex.len == 0) continue;
            layer.drawEffect(arena, cam, model, pl, .{ .model = mesh, .link = link, .offset = at.offset, .rot = at.rot, .scale = at.scale }, tex[@intCast((e.ticks -% at.start) % tex.len)]) catch {};
        }
        const d: Draw = .{ .arena = arena, .layer = layer, .cam = cam, .right = right, .cache = cache, .frames = frames };
        for (e.projectiles.items) |pr| d.projectile(pr, as);
        // What the viewer draws (og.effects.batch), the attacker at the origin in `frame`.
        const ln: Links = .{ .model = model, .as = as, .frame = frame };
        og.effects.batch.beams(e.beams.items, e.ticks, as, ln, d) catch {};
        og.effects.batch.streams(e.streams.items, e.ticks, as, d) catch {};
        og.effects.batch.spins(e.spins.items, as, d) catch {};
        og.effects.batch.clouds(e.clouds.items, as, d) catch {};
        // Flame particles: half-size in screen pixels (a world unit is a pixel in the
        // game's view).
        og.effects.batch.flames(e.flames.items, e.ticks, as, d) catch {};
        og.effects.batch.bitmaps(e.bitmaps.items, as, d) catch {};
        og.effects.batch.trails(e.trails.items, as, d) catch {};
        og.effects.batch.projectilePlanes(e.projectiles.items, as, d) catch {};
    }
};

/// Model points of the attacker at the origin facing +y (og.effects.batch links).
const Links = struct {
    model: ?*const Model,
    as: f32,
    frame: u32,

    pub fn point(l: Links, _: *Object, name: []const u8) ?[3]f32 {
        const m = l.model orelse return null;
        const mc = og.actor.model_cache;
        const p = mc.linkPoint(m, @min(l.frame, m.frames.frames -| 1), name) orelse return null;
        return mc.toWorld(m, p, l.as * m.unitScale(), .{ 0, 0, 0 }, 1, 0);
    }

    /// The point and its x axis (0x429ca0) on the floor.
    pub fn axis(l: Links, o: *Object, name: []const u8) ?[2][3]f32 {
        const m = l.model orelse return null;
        const mc = og.actor.model_cache;
        const fr = @min(l.frame, m.frames.frames -| 1);
        const p0 = l.point(o, name) orelse return null;
        const l1 = mc.linkPointOff(m, fr, name, .{ 1, 0, 0 }) orelse return null;
        const p1 = mc.toWorld(m, l1, l.as * m.unitScale(), .{ 0, 0, 0 }, 1, 0);
        return .{ p0, og.vec.normalize(.{ p1[0] - p0[0], p1[1] - p0[1], 0 }) };
    }
};

/// Effect frames (`gfx_3d\effects\<name>` per its `.dsc`), decoded once per name.
pub const Frames = struct {
    map: std.StringHashMapUnmanaged([]Image) = .empty,

    pub fn get(self: *Frames, cache: *Cache, textures: *og.render.textures.Textures, name: []const u8) []const Image {
        const gpa = cache.gpa;
        var key_buf: [64]u8 = undefined;
        if (name.len == 0 or name.len > key_buf.len) return &.{};
        const key = std.ascii.lowerString(&key_buf, name);
        if (self.map.get(key)) |f| return f;
        var list: std.ArrayList(Image) = .empty;
        if (cache.effect(name)) |d| for (d.frames) |f| {
            var buf: [160]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "effects/{s}/{s}", .{ name, f }) catch continue;
            const img = textures.texture(gpa, path) orelse continue;
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
        const fr = d.frames.get(d.cache, d.layer.textures.?, b.name);
        if (fr.len == 0) return;
        const dsc = d.cache.effect(b.name) orelse return;
        const blend: Layer.BillboardBlend = if (b.blend) |m| m else if (b.add) .add else switch (dsc.blend) {
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
        d.layer.billboard(d.cam, corners, fr[b.frame % fr.len], b.alpha, b.rgb, blend, b.program, b.k);
    }

    fn screen(d: Draw, p: [3]f32) [3]f32 {
        const q = d.cam.project(p);
        return .{ q.x, q.y, -q.depth };
    }

    /// One projectile (viewer/level/effects.zig drawProjectile): its mesh, the Cutter
    /// Pill bullet, a rocket's body and exhaust.
    fn projectile(d: Draw, pr: og.effects.projectile.Projectile, as: f32) void {
        if (pr.done) return;
        if (pr.mesh.len > 0) d.bodyMesh(pr.mesh, pr.pos, .{ -pr.dir[0], -pr.dir[1], -pr.dir[2] }, pr.roll, as * pr.mesh_scale * pr.k);
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
    fn bodyMesh(d: Draw, name: []const u8, pos: [3]f32, dir: [3]f32, roll: f32, scale: f32) void {
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
            d.solid(sp, uv, d.layer.textures.?.partTexture(m, pi));
        };
    }

    /// Effect mesh (`chaingun.msh`, crossed planes along +X) with an effect frame, +X
    /// along `dir` (effects_view.zig drawEffectMesh: rocket body and exhaust).
    fn effectMesh(d: Draw, effect: []const u8, frame: u32, pos: [3]f32, dir: [3]f32, scale: f32, blend: og.effects.dsc.Blend) void {
        const fr = d.frames.get(d.cache, d.layer.textures.?, effect);
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
        d.glowTri(sp, uv, tex, .{ 1, 1, 1 }, switch (blend) {
            .alpha => .alpha,
            .add => .add,
            else => .screen,
        }, .none, 0);
    }

    /// An opaque textured triangle (depth written): to the layer's sink (the GPU preview)
    /// when it has one, else the canvas.
    fn solid(d: Draw, sp: [3][3]f32, uv: [3][2]f32, tex: ?Image) void {
        const sk = d.layer.sink orelse return d.layer.canvas.triangle(sp, uv, tex, og.render.raster.gray(1));
        const a = d.arena;
        const pos = a.dupe([3]f32, &sp) catch return;
        const verts = a.alloc(og.core.model.Vertex, 3) catch return;
        for (verts, uv) |*v, t| v.* = .{ .pos = .{ 0, 0, 0 }, .uv = t };
        const col = a.alloc([3]f32, 3) catch return;
        @memset(col, .{ 1, 1, 1 });
        const tris = a.dupe([3]u32, &.{.{ 0, 1, 2 }}) catch return;
        const mips: []const Image = if (tex) |t| a.dupe(Image, &.{t}) catch return else &.{};
        sk.part(sk.ctx, .{ .pos = pos, .verts = verts, .col = col, .tris = tris, .two_sided = true, .mips = mips, .alpha = 1, .depth_write = true, .test_bias = 0 });
    }

    /// An effect triangle, depth-tested, not written: `tex` (none: white) × `col`, blended
    /// as `blend` with a material program; to the layer's sink when it takes effects, else
    /// the canvas (its glow and screen images for add and screen).
    fn glowTri(d: Draw, sp: [3][3]f32, uv: [3][2]f32, tex: ?Image, col: [3]f32, blend: Layer.BillboardBlend, program: og.render.raster.Canvas.Program, k: f32) void {
        if (d.layer.sink) |sk| if (sk.effect) |fx_| return fx_(sk.ctx, .{ .p = sp, .uv = uv, .tex = tex, .col = col, .blend = blend, .program = program, .k = k });
        const sh: og.render.raster.Canvas.Shade = switch (blend) {
            .alpha => .{ .depth_write = false, .tex_alpha = true, .program = program, .k = k },
            .add => .{ .add = &d.layer.glow, .depth_write = false, .program = program, .k = k },
            .screen => .{ .add = &d.layer.screen, .screen = true, .depth_write = false, .program = program, .k = k },
        };
        d.layer.canvas.triangleShaded(sp, uv, tex, .{ col, col, col }, sh);
    }

    /// Ribbon A→B offset ±`side` across (effects_view.zig ribbon), additive. The game
    /// looks down on a flat ribbon; the preview looks level, so it is turned to face the
    /// view, the same width.
    pub fn ribbon(d: Draw, q: og.effects.batch.RibbonQuad) !void {
        const a = q.a;
        const b = q.b;
        const flat = if (q.facing != null) scaled(d.right, q.half) else q.side;
        const fr = d.frames.get(d.cache, d.layer.textures.?, q.name);
        if (fr.len == 0) return;
        const frame = q.frame;
        const across = og.vec.cross(og.vec.sub(b, a), .{ -d.right[1], d.right[0], 0 });
        const l = og.vec.len(across);
        const side = if (l > 1e-6) scaled(across, og.vec.len(flat) / l) else flat;
        const c = [4][3]f32{ og.vec.add(a, side), og.vec.add(b, side), og.vec.sub(b, side), og.vec.sub(a, side) };
        const uv = [4][2]f32{ .{ q.uv[0], 0 }, .{ q.uv[1], 0 }, .{ q.uv[1], 1 }, .{ q.uv[0], 1 } };
        const s = [4][3]f32{ d.screen(c[0]), d.screen(c[1]), d.screen(c[2]), d.screen(c[3]) };
        const cv = [3]f32{ q.rgb[0] * q.alpha, q.rgb[1] * q.alpha, q.rgb[2] * q.alpha };
        d.glowTri(.{ s[0], s[1], s[2] }, .{ uv[0], uv[1], uv[2] }, fr[frame % fr.len], cv, .add, q.program, q.k);
        d.glowTri(.{ s[0], s[2], s[3] }, .{ uv[0], uv[2], uv[3] }, fr[frame % fr.len], cv, .add, q.program, q.k);
    }

    /// A flame particle (og.effects.batch): a billboard, a world unit a screen pixel.
    pub fn particle(d: Draw, b: og.effects.batch.Billboard) !void {
        return d.put(b);
    }

    /// Mesh with its own texture, additive at brightness `k` (effects_view.zig
    /// drawMeshAdd: turned to `dir`, stretched vertically).
    pub fn mesh(d: Draw, ma: og.effects.batch.MeshAt) !void {
        const m = d.cache.get(ma.name) orelse return;
        const pts = og.actor.skin.pose(d.arena, m.mesh, m.frames, 0, .row) catch return;
        const s = ma.scale * m.unitScale();
        const yaw = og.fields.modelAngle(og.fields.facing(ma.dir[0], ma.dir[1]));
        const pitch = std.math.atan2(ma.dir[2], og.vec.len2(ma.dir));
        for (m.mesh.parts, pts, 0..) |part, ppts, pi| for (part.triangles) |t| {
            var sp: [3][3]f32 = undefined;
            var uv: [3][2]f32 = undefined;
            for (0..3) |k| {
                const p = ppts[t[k]];
                const l = og.actor.model_cache.localPoint(m, .{ p[0], p[1] * ma.stretch, p[2] });
                const lp = [3]f32{ l[0], l[2] * @sin(pitch) + l[1] * @cos(pitch), l[2] * @cos(pitch) - l[1] * @sin(pitch) };
                sp[k] = d.screen(og.actor.model_cache.toWorldLocal(lp, s, ma.pos, @cos(yaw), @sin(yaw)));
                uv[k] = part.vertices[t[k]].uv;
            }
            d.glowTri(sp, uv, d.layer.textures.?.partTexture(m, pi), .{ ma.k, ma.k, ma.k }, .add, ma.program, ma.pk);
        };
    }
};

fn scaled(v: [3]f32, k: f32) [3]f32 {
    return .{ v[0] * k, v[1] * k, v[2] * k };
}

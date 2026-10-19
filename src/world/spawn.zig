//! Morphs, flames, binds (bombs and decoys: combat/devices.zig; scene rocket: scene/scenes.zig).

const std = @import("std");
const vec = @import("../vec.zig");
const actor_mod = @import("../actor.zig");
const fields = @import("../fields.zig");
const object = @import("../script.zig").object;
const effects_mod = @import("../effects.zig");
const Object = object.Object;
const world = @import("../state.zig").world;
const World = world.World;
const model_cache = actor_mod.model_cache;

/// Morph (0x42b5a0): the actor fades and after morf_life2 (50) ticks gets the new class
/// (`applyMorph`); glow and fade-in are `effects.Morph`.
pub fn morphActor(self: *World, o: *Object, class_file: []const u8, mesh: []const u8, idle: []const u8) !void {
    const a = world.actorOf(o);
    const ar = self.rt.arena();
    a.morph = .{ .class = try ar.dupe(u8, class_file), .mesh = try ar.dupe(u8, mesh), .idle = try ar.dupe(u8, idle) };
    a.morph_left = 50;
    a.morph_due = false;
    const p = fields.pos(o);
    const ang = fields.modelAngle(fields.angle(o)) + a.angle_offset;
    try self.effects.morphs.append(self.gpa, effects_mod.bitmap.Morph.init(
        .{ p[0] + a.render_offset[0], p[1] + a.render_offset[1], p[2] + a.render_offset[2] },
        ang,
        a.morph.?.mesh,
        a.morph.?.idle,
        self.actorScale(),
        self.crt(),
    ));
    self.effects.morphs.items[self.effects.morphs.items.len - 1].owner = o;
}

/// Object references of effects to removed objects (the exe's +0x30 pass, 0x420349): a beam
/// whose actor is gone dies (Medusa's current, 0x4a3b70 → 0x4a3ba0), an attached effect
/// with it, other effects drop the link and stay where they are.
pub fn releaseRemoved(self: *World) void {
    const gone = struct {
        fn f(o: ?*Object) bool {
            const x = o orelse return false;
            const n = World.nativeOf(x);
            return n.deleted or (n.kind == .actor and n.actor.gone);
        }
    }.f;
    const e = &self.effects;
    var i: usize = 0;
    while (i < e.beams.items.len) {
        const b = &e.beams.items[i];
        if (gone(b.actor)) switch (b.kind) {
            .current, .laser => {
                _ = e.beams.orderedRemove(i);
                continue;
            },
            else => b.actor = null,
        };
        i += 1;
    }
    i = 0;
    while (i < e.attached.items.len) {
        if (gone(e.attached.items[i].actor)) _ = e.attached.orderedRemove(i) else i += 1;
    }
    for (e.flames.items) |*f| if (gone(f.actor)) {
        f.actor = null;
    };
    i = 0;
    while (i < e.morphs.items.len) {
        if (gone(e.morphs.items[i].owner)) _ = e.morphs.orderedRemove(i) else i += 1;
    }
}

/// Change an actor's class (`.mtm` = fighter class): animations and vars from its init(),
/// model `mesh`, idle `idle`.
pub fn applyMorph(self: *World, o: *Object, class_file: []const u8, mesh: []const u8, idle: []const u8) !void {
    const cls = self.rt.loadClass(class_file) catch |err| {
        std.log.warn("morph {s}: {t}", .{ class_file, err });
        return;
    };
    const a = world.actorOf(o);
    a.mappings.clearRetainingCapacity();
    try self.rt.morph(o, cls);
    _ = try self.rt.callIfExists(o, "init", &.{});
    if (mesh.len > 0) if (o.getVar("meshFile")) |v| {
        v.value = .{ .string = try self.rt.arena().dupe(u8, mesh) };
    };
    a.forced_idle = if (idle.len > 0) a.resolve(idle) else null;
    a.pickIdle(self.crt());
}

/// Flame streams behind a weapon (0x49fdc0): each tick a new direction from a fixed point
/// to the link point (rotated by rot around the vertical) or from t1 to t2; spawn point is
/// base + dir·ahead.
pub fn aimFlames(self: *World) void {
    for (self.effects.flames.items) |*fl| {
        const o = fl.actor orelse continue;
        if (!o.enabled or World.nativeOf(o).deleted) continue;
        const l1 = linkWorld(self, o, fl.link) orelse continue;
        var base = fl.base;
        var to = l1;
        if (fl.link2.len > 0) {
            base = l1;
            to = linkWorld(self, o, fl.link2) orelse continue;
        }
        var d = [3]f32{ to[0] - base[0], to[1] - base[1], to[2] - base[2] };
        const len = vec.len(d);
        if (len < 1e-4) continue;
        for (&d) |*c| c.* /= len;
        if (fl.rot != 0) {
            const cs = @cos(fl.rot);
            const sn = @sin(fl.rot);
            const x = d[0];
            const y = d[1];
            d[0] = x * cs - y * sn;
            d[1] = x * sn + y * cs;
        }
        fl.src = .{ base[0] + d[0] * fl.ahead, base[1] + d[1] * fl.ahead, base[2] + d[2] * fl.ahead };
        fl.dir = .{ d[0] * fl.speed, d[1] * fl.speed, d[2] * fl.speed };
    }
}

/// Victim lift (0x497150, 0x42a4ac): weight ±0.1 per tick pulls the victim toward the
/// attacker's link point; after release the offset returns to 0 and the idle resumes.
pub fn tickBind(self: *World, o: *Object, a: *actor_mod.Actor, bd: *actor_mod.Actor.Bind, model: ?*const model_cache.Model) !void {
    const va = world.actorOf(bd.victim);
    if (bd.release_in) |*ri| {
        if (ri.* > 0) ri.* -= 1 else bd.releasing = true;
    }
    bd.w = std.math.clamp(bd.w + @as(f32, if (bd.releasing) -0.1 else 0.1), 0, 1);
    if (bd.releasing and bd.w <= 0) {
        va.render_offset = .{ 0, 0, 0 };
        va.forced_idle = null;
        if (!va.hold_last) va.pickIdle(self.crt());
        a.bind = null;
        return;
    }
    const m = model orelse return;
    const lp = actor_mod.model_cache.linkPoint(m, a.frameIn(m), bd.link) orelse return;
    const ang = fields.modelAngle(fields.angle(o)) + a.angle_offset;
    const lw = actor_mod.model_cache.toWorld(m, lp, self.actorScale() * a.scale_mul * m.unitScale(), fields.pos(o), @cos(ang), @sin(ang));
    const vp = fields.pos(bd.victim);
    va.render_offset = .{ (lw[0] - vp[0]) * bd.w, (lw[1] - vp[1]) * bd.w, (lw[2] - vp[2] + bd.z) * bd.w };
}

/// World position of an actor's `link` point in the current frame.
fn linkWorld(w: *World, o: *Object, link: []const u8) ?[3]f32 {
    const models = w.res.models orelse return null;
    const m = models.get(fields.meshFile(o)) orelse return null;
    const a = world.actorOf(o);
    const lp = model_cache.linkPoint(m, a.frameIn(m), link) orelse return null;
    const ang = fields.modelAngle(fields.angle(o)) + a.angle_offset;
    return model_cache.toWorld(m, lp, w.actorScale() * a.scale_mul * m.unitScale(), fields.pos(o), @cos(ang), @sin(ang));
}

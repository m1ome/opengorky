//! Field effects: projectiles, beams, flashes, fire, gas, explosions, trails — attached to model points and drawn.

const std = @import("std");
const actors_view = @import("actors.zig");
const billboards = @import("billboards.zig");
const place = @import("place.zig");
const level_view = @import("../level.zig");
const LevelView = level_view.LevelView;
const og = @import("opengorky");
const World = og.state.world.World;
const EffectsView = @import("effects_view.zig").EffectsView;

/// World position of actor link point `link` (current frame), if it has a model.
fn linkWorld(self: *LevelView, o: *og.script.object.Object, link: []const u8) ?[3]f32 {
    const m = (self.models orelse return null).get(og.fields.meshFile(o)) orelse return null;
    const pl = place.placement(self, o, m) orelse return null;
    const lp = og.actor.model_cache.linkPoint(m, @min(pl.frame, m.frames.frames -| 1), link) orelse return null;
    return og.actor.model_cache.toWorld(m, lp, pl.scale * m.unitScale(), pl.pos, @cos(pl.angle), @sin(pl.angle));
}
/// Link point `link` and the horizontal unit axis of its x (0x429ca0: the same
/// point with x + 1; the exe takes p0 − p1 and draws along −(p0 − p1)).
fn ionAxis(self: *LevelView, o: *og.script.object.Object, link: []const u8) ?[2][3]f32 {
    const m = (self.models orelse return null).get(og.fields.meshFile(o)) orelse return null;
    const pl = place.placement(self, o, m) orelse return null;
    const frame = @min(pl.frame, m.frames.frames -| 1);
    const l0 = og.actor.model_cache.linkPoint(m, frame, link) orelse return null;
    const l1 = og.actor.model_cache.linkPointOff(m, frame, link, .{ 1, 0, 0 }) orelse return null;
    const s = pl.scale * m.unitScale();
    const ca = @cos(pl.angle);
    const sa = @sin(pl.angle);
    const p0 = og.actor.model_cache.toWorld(m, l0, s, pl.pos, ca, sa);
    const p1 = og.actor.model_cache.toWorld(m, l1, s, pl.pos, ca, sa);
    const dx = p1[0] - p0[0];
    const dy = p1[1] - p0[1];
    const l = @sqrt(dx * dx + dy * dy);
    if (l < 1e-6) return null;
    return .{ p0, .{ dx / l, dy / l, 0 } };
}
/// Batch billboards drawn on screen (off combat levels: the flush turns the z-test off).
const ViewSink = struct {
    v: *EffectsView,
    ctx: @import("effects_view.zig").Frame,
    pub fn put(s: ViewSink, b: billboards.Billboard) !void {
        try s.v.billboard(s.ctx, b.name, b.frame, b.pos, b.half, b.alpha, b.rgb, null);
    }
};

/// World effects: planes, flashes on link points, blood, flamethrower, fire.
pub fn drawEffects(self: *LevelView, scroll: [2]f32) !void {
    const v = self.fx_view orelse return;
    const w = self.world;
    const e = &w.effects;
    const cam = w.cam;
    const as = w.actorScale();
    const ticks = e.ticks;
    const ctx: @import("effects_view.zig").Frame = .{ .arena = self.frame_arena.allocator(), .cam = cam, .scroll = scroll };
    // Batch billboards (billboards.zig) go to the actor layer on combat levels.
    const combat = w.isCombat();
    const view: ViewSink = .{ .v = v, .ctx = ctx };
    if (!combat) try billboards.fireCells(self, view);
    if (w.battle) |*b| {
        // Burning fighter (0x4dc700): "Flame" additive over its rectangle.
        for (b.fighters.items, 0..) |f, i| {
            if (!f.alive() or f.burning <= 0) continue;
            const tall = actors_view.modelHeight(self, f.obj) orelse continue;
            const foot = cam.project(og.fields.pos(f.obj));
            const head = cam.project(level_view.addZ(og.fields.pos(f.obj), tall));
            const h = @max(8, foot.y - head.y);
            const wdt = h * 0.6;
            try v.screenQuad("flame", @intCast((ticks + i * 5) % 15), .{ foot.x - scroll[0] - wdt / 2, head.y - scroll[1] - h / 8, wdt, h }, 1, .{ 1, 1, 1 }, .add);
        }
    }
    _ = self.frame_arena.reset(.retain_capacity);
    // Effects on link points go into the model layer with depth testing
    // (actors_view.attachedEffects).
    if (!combat) try billboards.incubusGlow(self, view);
    // Morph (0x4260a0): mesh "nowy" ×(3, 3, 4)·aS additive at brightness 0.5·p.
    for (e.morphs.items) |mo| try v.drawMeshAdd(ctx, "nowy", mo.pos, .{ 0, 1, 0 }, as * 3, 4.0 / 3.0, 0.5 * mo.p);
    if (!combat) try billboards.morphSparks(self, view);
    // Schizo gas cloud (0x4a95d0): "gas2" in a circle, fades over 30 ticks.
    for (e.clouds.items) |cl| {
        const a: f32 = if (cl.fading > 0) og.num.toF32(cl.fading) / 30 else @min(1, og.num.toF32(cl.ticks) / 15);
        try v.billboard(ctx, cl.effect, cl.ticks / 2, cl.pos, as * cl.size, a, .{ 1, 1, 1 }, null);
    }
    if (!combat) {
        try billboards.bitmaps(self, view);
        try billboards.blood(self, view);
    }
    // Beams (texture frame (T>>1)%n, lightning T%n), additive.
    for (e.beams.items) |bm| try drawBeam(self, v, ctx, bm, ticks, as);
    // Blaster stream (0x4a3000): point i moved along v by (n − i)·60·aS; a segment
    // draws until its point reaches the target; half-width 80·aS, the texture
    // shifts by 0.08 per segment, the last 6 segments narrow.
    for (e.streams.items) |st| {
        if (st.n < 2) continue;
        const frame: u32 = @intCast((ticks / 2) % 4096);
        var acc: f32 = 0;
        var i: u32 = 0;
        while (i + 1 < st.n) : (i += 1) {
            const d0 = st.dist(i);
            if (d0 >= st.len) continue;
            const d1 = @min(st.dist(i + 1), st.len);
            const a = [3]f32{ st.pts[i][0] + st.v[0] * d0, st.pts[i][1] + st.v[1] * d0, st.pts[i][2] + st.v[2] * d0 };
            const b2 = [3]f32{ st.pts[i + 1][0] + st.v[0] * d1, st.pts[i + 1][1] + st.v[1] * d1, st.pts[i + 1][2] + st.v[2] * d1 };
            const tail = st.n - 1 - i;
            const taper: f32 = if (tail <= 6) @max(0.1, 1 - 0.15 * og.num.toF32(6 - tail + 1)) else 1;
            try v.ribbon(ctx, "blaster", frame, a, b2, sideOf(a, b2, as * 80 * taper), acc, acc + 0.08, 1);
            acc = @mod(acc + 0.08, 1);
        }
    }
    // Satellite energy beam (0x4a7350): mesh "beam", Rz(phase), scale 8·aS,
    // colour = brightness, additive.
    for (e.spins.items) |sp| {
        if (sp.k <= 0) continue;
        try v.drawMeshAdd(ctx, sp.mesh, sp.pos, .{ @cos(sp.phase), @sin(sp.phase), 0 }, as * 8, 1, sp.k);
    }
    // Projectiles: mesh or plane; a rocket is "Rocket1" with exhaust "Rocket" behind
    // (220·aS); molotov flame.
    if (!combat) try billboards.trails(self, view);
    for (e.projectiles.items) |pr| try drawProjectile(v, ctx, pr, ticks, as);
    if (!combat) try billboards.projectilePlanes(self, view);
    // Flamethrower (0x4a0270): a particle is an additive screen quad with half-size
    // min(age·attack_flame_scale 1.6 + attack_flame_add 8, attack_flame_range 160);
    // colour from attack_flame_col2 (60,60,255) when new to attack_flame_col
    // (255,160,0) when old (t = remaining life / 16); random flame2 frame, ±5·aS
    // jitter on x, y.
    for (e.flames.items, 0..) |fl, fi| for (fl.parts.items, 0..) |p, i| {
        const h = std.hash.Murmur2_32.hashUint64(ticks *% 2654435761 +% i *% 40503 +% fi);
        const jx = (og.num.toF32(h % 10) - 5) * as;
        const jy = (og.num.toF32((h / 10) % 10) - 5) * as;
        const q = cam.project(.{ p.pos[0] + jx, p.pos[1] + jy, p.pos[2] });
        const t = 1 - og.num.toF32(p.age) / og.num.toF32(fl.life);
        const half = @min(og.num.toF32(p.age) * 1.6 + 8, 160);
        const rgb = [3]f32{ (255 + (60 - 255) * t) / 255, (160 + (60 - 160) * t) / 255, (255 * t) / 255 };
        const fr: u32 = @intCast((h / 100) % 15);
        try v.screenQuad("flame2", fr, .{ q.x - scroll[0] - half, q.y - scroll[1] - half, 2 * half, 2 * half }, 1, rgb, .add);
    };
}

/// One beam: billboard chain, ion rifle, guard laser, Medusa current or lightning.
fn drawBeam(self: *LevelView, v: *EffectsView, ctx: @import("effects_view.zig").Frame, bm: og.effects.beam.Beam, ticks: u64, as: f32) !void {
    const cam = ctx.cam;
    const frame: u32 = @intCast((ticks / bm.div) % 4096);
    const half = as * bm.size;
    switch (bm.kind) {
        // Planes along the segment at half-size steps.
        .billboards => {
            const d = og.vec.sub(bm.to, bm.from);
            const len = og.vec.len(d);
            const n: usize = @intFromFloat(@min(200, @max(1, len / @max(1, half))));
            for (0..n + 1) |k| {
                const t = og.num.toF32(k) / og.num.toF32(n);
                const p = [3]f32{ bm.from[0] + d[0] * t, bm.from[1] + d[1] * t, bm.from[2] + d[2] * t };
                try v.billboard(ctx, bm.effect, frame, p, half, 1, .{ 1, 1, 1 }, .add);
            }
        },
        // Ion (0x4a18d0): the beam goes both ways from the shooter, like the hit
        // area (class 6 sets: a line of −40…40 cells, 0x4b8192). Forward: 25
        // segments of 220·aS (0x50aac0) starting 155·aS ahead of the actor
        // (attack_ion_vs −155, loop 0x4a2172); backward: 25 more with a reversed
        // step (0x4a233d) from the end of the first, shifted back by attack_ion_vk
        // 5922·aS (0x4a235b), i.e. from 267·aS behind the actor (loop 0x4a2490).
        // The exe recomputes start and direction each frame (0x4a1919): the
        // actor's two_hands point and the same point with x + 1 in bone axes
        // (0x429ca0); the height is the one stored at the shot (+0x2ec); the barrel
        // axis turns by −0.09 (0.4 for Slavsky, 0x4a19c3/0x4a19e4). So the beam
        // leaves the muzzle and behind the stock and sways with the rifle's recoil.
        .ion => {
            var o = bm.from;
            var d = bm.dir;
            if (bm.actor) |a| if (ionAxis(self, a, bm.link)) |ax| {
                o = .{ ax[0][0], ax[0][1], bm.from[2] };
                const tc = @cos(bm.turn);
                const ts = @sin(bm.turn);
                d = .{ ax[1][0] * tc - ax[1][1] * ts, ax[1][0] * ts + ax[1][1] * tc, 0 };
            };
            const side = [3]f32{ -d[1] * half, d[0] * half, 0 };
            for ([_]f32{ 155, -267 }, [_]f32{ 220, -220 }) |start, step| {
                var p = [3]f32{ o[0] + d[0] * start * as, o[1] + d[1] * start * as, o[2] };
                for (0..25) |_| {
                    const q = [3]f32{ p[0] + d[0] * step * as, p[1] + d[1] * step * as, p[2] };
                    try v.ribbon(ctx, bm.effect, frame, p, q, side, 0, 1, 1);
                    p = q;
                }
            }
        },
        // Guard laser (0x4a4f80): from the eye (recomputed each frame) to the target.
        .laser => {
            const a = linkWorld(self, bm.actor orelse return, bm.link) orelse return;
            try v.ribbon(ctx, bm.effect, frame, a, bm.to, sideOf(a, bm.to, half), 0, 1, 1);
        },
        // Medusa current (0x4a3c30): current1→current3, current2→current4.
        .current => {
            const o = bm.actor orelse return;
            for ([_][2][]const u8{ .{ "current1", "current3" }, .{ "current2", "current4" } }) |pair| {
                const a = linkWorld(self, o, pair[0]) orelse continue;
                const b2 = linkWorld(self, o, pair[1]) orelse continue;
                try v.ribbon(ctx, bm.effect, frame, a, b2, sideOf(a, b2, half), 0, 1, 1);
            }
        },
        // Lightning (0x4a7ac0): 4 parts of 1400·aS upward from the target, facing the camera.
        .lightning => {
            const r0 = EffectsView.screenRight(cam, bm.to);
            const side = [3]f32{ r0[0] * half, r0[1] * half, 0 };
            for (0..4) |k| {
                const z0 = og.num.toF32(k) * 1400 * as;
                const a = [3]f32{ bm.to[0], bm.to[1], bm.to[2] + z0 };
                const b2 = [3]f32{ bm.to[0], bm.to[1], bm.to[2] + z0 + 1400 * as };
                try v.ribbon(ctx, bm.effect, frame, a, b2, side, 0, 1, 1);
            }
        },
    }
}

/// One projectile: mesh or plane, Cutter Pill bullet, rocket with exhaust, molotov flame.
fn drawProjectile(v: *EffectsView, ctx: @import("effects_view.zig").Frame, pr: og.effects.projectile.Projectile, ticks: u64, as: f32) !void {
    const cam = ctx.cam;
    const scroll = ctx.scroll;
    if (pr.done) return;
    // The projectile nose in the exe is the −Y axis of its frame (0x49b0a0: basis
    // S, U, d and Rx(−π/2)); ours is the mesh's −Z, so draw reversed or the
    // orbital rocket (pocisk) falls tail first.
    if (pr.mesh.len > 0) try v.drawMesh(ctx, pr.mesh, pr.pos, .{ -pr.dir[0], -pr.dir[1], -pr.dir[2] }, pr.roll, as * pr.mesh_scale * pr.k);
    if (pr.bullet) {
        // Cutter Pill bullet (0x49df20): chaingun.msh with "arrows" (mode 2) along
        // the direction, at pos − dir·240·aS, scale 0.6·aS.
        const at = [3]f32{ pr.pos[0] - pr.dir[0] * 240 * as, pr.pos[1] - pr.dir[1] * 240 * as, pr.pos[2] - pr.dir[2] * 240 * as };
        try v.drawEffectMesh(ctx, pr.effect, 0, at, pr.dir, pr.mesh_scale * as, .alpha);
        return;
    }
    if (pr.rocket) {
        // Rocket (0x49bfb0): body chaingun.msh with "Rocket1" (mode 2) ×0.3·aS·scale
        // along the flight; exhaust "Rocket" (frame (t/2)%2, mode 4) ×0.4·aS
        // 220·aS behind.
        const back = [3]f32{ pr.pos[0] - pr.dir[0] * 220 * as, pr.pos[1] - pr.dir[1] * 220 * as, pr.pos[2] - pr.dir[2] * 220 * as };
        try v.drawEffectMesh(ctx, "Rocket", @intCast((pr.ticks / 2) % 2), back, pr.dir, 0.4 * as, .screen);
        try v.drawEffectMesh(ctx, pr.effect, 0, pr.pos, pr.dir, 0.3 * as * pr.mesh_scale, .alpha);
    }
    if (pr.flame) {
        // Flame (0x49d440): point (25, 45, 45) in bottle axes (tumble +0x320 and
        // flight matrix +0x2f8), a 10×14 screen quad with its corner at the point
        // − (5, 6) (0x49d6a4…0x49d74b), "flame" frame (tick/2) cycling.
        const d = [3]f32{ -pr.dir[0], -pr.dir[1], -pr.dir[2] };
        const at = v.meshPoint(pr.mesh, pr.pos, d, pr.roll, as * pr.mesh_scale * pr.k, .{ 25, 45, 45 }) orelse pr.pos;
        const q = cam.project(at);
        try v.screenQuad("flame", @intCast((ticks / 2) % 15), .{ q.x - scroll[0] - 5, q.y - scroll[1] - 6, 10, 14 }, 1, .{ 1, 1, 1 }, null);
    }
}

/// Offset across ribbon A→B (0x4a3c30): the direction rotated 90° in XY, ·`half`;
/// for a vertical ribbon — right along X.
fn sideOf(a: [3]f32, b: [3]f32, half: f32) [3]f32 {
    const d = og.vec.sub(b, a);
    const l = og.vec.len2(d);
    if (l < 1e-4) return .{ half, 0, 0 };
    return .{ -d[1] / l * half, d[0] / l * half, 0 };
}

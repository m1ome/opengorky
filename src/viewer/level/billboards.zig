//! Effects drawn through the exe's particle batch (0x45e150, flushed at 0x45d8d0 after
//! models and shadows): fire on cells, Incubus glow, morph sparks, bitmaps, blood and
//! flare drops, trails, projectile planes. Each enumerator hands billboards to a sink
//! (`put(Billboard)`): the screen pass off combat levels, the depth-tested layer on them.

const og = @import("opengorky");
const LevelView = @import("../level.zig").LevelView;
const place = @import("place.zig");
const World = og.state.world.World;

/// One batch billboard: `.dsc` effect `name`, half size `half`, colour `rgb`, alpha.
pub const Billboard = struct { name: []const u8, frame: u32, pos: [3]f32, half: f32, alpha: f32 = 1, rgb: [3]f32 = .{ 1, 1, 1 } };

/// All batch billboards, in the screen pass order.
pub fn all(self: *LevelView, sink: anytype) !void {
    try fireCells(self, sink);
    try incubusGlow(self, sink);
    try morphSparks(self, sink);
    try bitmaps(self, sink);
    try blood(self, sink);
    try trails(self, sink);
    try projectilePlanes(self, sink);
}

/// Fire on cells (0x4a66a0, draw 0x4a6a70): "flame" at the cell, 130·aS higher, size
/// 200 + p, frame (tick + p) % 15; p is the cell phase 1..31.
pub fn fireCells(self: *LevelView, sink: anytype) !void {
    const w = self.world;
    const b = &(w.battle orelse return);
    const cm = w.combat_map orelse return;
    const as = w.actorScale();
    for (0..cm.height) |y| for (0..cm.width) |x| {
        const t: og.battle.grid.Tile = .{ @intCast(x), @intCast(y) };
        if (og.combat.states.hazardAt(b, b.fire, t) == 0) continue;
        // Phases of the cell and its transpose (0x4a6adf, 0x4a6af0); the frame
        // comes from the process frame counter (0x4a6b44).
        const p: u32 = if (x < 32 and y < 32) b.fire_phase[y][x] else 1;
        const q: u32 = if (x < 32 and y < 32) b.fire_phase[x][y] else 1;
        var pos = cm.tileCenter(t, 1);
        pos[0] += (og.num.toF32(q) / 150 - 0.1) * cm.cell_size[0];
        pos[1] += (og.num.toF32(p) / 150 - 0.1) * cm.cell_size[1];
        pos[2] += 130 * as;
        try sink.put(.{ .name = "flame", .frame = @intCast((w.effects.ticks + p) % 15), .pos = pos, .half = as * og.num.toF32(200 + p) });
    };
}

/// Incubus glow (0x42a620): "poswiata" on points t1–t6, size 46, colour (0.5, 0.4, 1.0).
pub fn incubusGlow(self: *LevelView, sink: anytype) !void {
    const w = self.world;
    const ms = self.models orelse return;
    const as = w.actorScale();
    for (w.rt.objects.items) |o| {
        const n = World.nativeOf(o);
        if (n.kind != .actor or !o.enabled or n.deleted or !n.actor.placed) continue;
        if (og.fields.nameId(o) != 138) continue;
        const m = ms.get(og.fields.meshFile(o)) orelse continue;
        const pl = place.placement(self, o, m) orelse continue;
        const fr = @min(pl.frame, m.frames.frames -| 1);
        const sc = pl.scale * m.unitScale();
        for ([_][]const u8{ "t1", "t2", "t3", "t4", "t5", "t6" }, 0..) |ln, k| {
            const lp = og.actor.model_cache.linkPoint(m, fr, ln) orelse continue;
            const wp = og.actor.model_cache.toWorld(m, lp, sc, pl.pos, @cos(pl.angle), @sin(pl.angle));
            try sink.put(.{ .name = "poswiata", .frame = @intCast((w.effects.ticks + k * 3) % 64), .pos = wp, .half = as * 46, .rgb = .{ 0.5, 0.4, 1.0 } });
        }
    }
}

/// Morph sparks (0x4260a0): "poswiata" 80, colour (0.5, 0.5, 0.8).
pub fn morphSparks(self: *LevelView, sink: anytype) !void {
    const as = self.world.actorScale();
    for (self.world.effects.morphs.items) |mo| for (mo.parts, 0..) |pt, i| if (pt.active)
        try sink.put(.{ .name = "poswiata", .frame = 0, .pos = mo.particlePos(i), .half = as * 80, .rgb = .{ 0.5, 0.5, 0.8 } });
}

/// Bitmaps and flashes (0x4cb600, draw 0x4cb8b0).
pub fn bitmaps(self: *LevelView, sink: anytype) !void {
    const as = self.world.actorScale();
    for (self.world.effects.bitmaps.items) |bm| {
        if (bm.delay > 0) continue;
        try sink.put(.{ .name = bm.effect, .frame = if (bm.flash_rate > 0) 0 else bm.frame(), .pos = bm.pos, .half = as * bm.drawSize(), .alpha = bm.alpha, .rgb = bm.rgb });
    }
}

/// Blood and flare drops (0x4cce20): a drop in the world is origin + p·aS·drop_unit
/// (0x4cce53); frame 3 after landing, else 1–2; alpha (40 − blend)/30 after
/// particle_blend_start; size (1 − shrink/40)·size·(1 | 0.7 in flight).
pub fn blood(self: *LevelView, sink: anytype) !void {
    const pt = og.effects.particles;
    const as = self.world.actorScale();
    const k = as * pt.drop_unit;
    const rt: f32 = pt.particle_rest_time;
    for (self.world.effects.blood.items) |bl| for (0..bl.n) |i| {
        const d = bl.drops[i];
        if (d.dead) continue;
        const sz = (1 - og.num.toF32(d.shrink) / rt) * d.size * @as(f32, if (d.blend != 0) 1 else 0.7);
        try sink.put(.{
            .name = if (bl.flare) "flare1" else "redcircle",
            .frame = if (d.blend != 0) 3 else @intCast((i & 1) + 1),
            .pos = .{ bl.origin[0] + d.pos[0] * k, bl.origin[1] + d.pos[1] * k, bl.origin[2] + d.pos[2] * k },
            .half = as * sz,
            .alpha = if (d.blend > pt.particle_blend_start) (rt - og.num.toF32(d.blend)) / (rt - pt.particle_blend_start) else 1,
        });
    };
}

/// Trails (0x4cd4a0): separate objects that outlive the projectile; size and
/// brightness fall toward the tail.
pub fn trails(self: *LevelView, sink: anytype) !void {
    const as = self.world.actorScale();
    for (self.world.effects.trails.items) |t| {
        var s: f32 = 1;
        var a: f32 = 1;
        var idx: usize = t.head;
        for (0..t.count) |k| {
            if (s <= 0.01 or a <= 0.01) break;
            if (k >= t.eaten) try sink.put(.{ .name = t.effect, .frame = @intCast(k), .pos = t.pts[idx], .half = as * s * t.size, .alpha = a, .rgb = t.rgb });
            s -= t.size_fade;
            a *= t.fade;
            idx = (idx + 1) % og.effects.projectile.Trail.ring;
        }
    }
}

/// Projectile planes (0x49bab0): a projectile without a body mesh, bullet or rocket.
pub fn projectilePlanes(self: *LevelView, sink: anytype) !void {
    const as = self.world.actorScale();
    for (self.world.effects.projectiles.items) |pr| {
        if (pr.done or pr.bullet or pr.rocket or pr.effect.len == 0) continue;
        if (pr.ball) |b| {
            // Ball (0x4a6280): two "kula" frames cross-fading by wave a, sizes ±40·b,
            // then "poswiata" 400 tinted (0.2 + 0.08a, 0.2, 0.4); scale / attack_ball_ms.
            const s = pr.k * pr.mesh_scale / og.effects.projectile.attack_ball_ms;
            const fade = 2.5 * b.a + 0.5;
            try sink.put(.{ .name = "kula", .frame = b.f1, .pos = pr.pos, .half = as * (130 * s + 40 * b.b), .alpha = fade });
            try sink.put(.{ .name = "kula", .frame = b.f2, .pos = pr.pos, .half = as * (130 * s + 8 - 40 * b.b), .alpha = 1 - fade });
            try sink.put(.{ .name = "poswiata", .frame = 0, .pos = pr.pos, .half = as * 400 * s, .rgb = .{ 0.2 + 0.08 * b.a, 0.2, 0.4 } });
            continue;
        }
        try sink.put(.{ .name = pr.effect, .frame = pr.ticks, .pos = pr.pos, .half = as * pr.size * pr.k });
    }
}

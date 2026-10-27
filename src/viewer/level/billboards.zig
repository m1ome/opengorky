//! Effects drawn through the exe's particle batch (0x45e150, flushed at 0x45d8d0 after
//! models and shadows): fire on cells, Incubus glow, morph sparks, bitmaps, blood and
//! flare drops, trails, projectile planes. Each enumerator hands billboards to a sink
//! (`put(Billboard)`): the screen pass off combat levels, the depth-tested layer on them.

const og = @import("opengorky");
const LevelView = @import("../level.zig").LevelView;
const place = @import("place.zig");
const World = og.state.world.World;

pub const Billboard = og.effects.batch.Billboard;

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
        // A faded corpse is removed (+0x60 at 0x426950), so its glow goes with it.
        if (n.kind != .actor or !o.enabled or n.deleted or n.actor.gone or !n.actor.placed) continue;
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

/// Bitmaps and flashes (og.effects.batch).
pub fn bitmaps(self: *LevelView, sink: anytype) !void {
    try og.effects.batch.bitmaps(self.world.effects.bitmaps.items, self.world.actorScale(), sink);
}

/// Blood and flare drops (0x4cce20): a drop in the world is origin + p·aS·drop_unit
/// (0x4cce53); frame 3 after landing, else 1–2; alpha (40 − blend)/30 after
/// particle_blend_start; size (1 − shrink/40)·size·(1 | 0.7 in flight).
pub fn blood(self: *LevelView, sink: anytype) !void {
    const pt = og.effects.particles;
    const as = self.world.actorScale();
    const k = as * pt.drop_unit;
    const rt: f32 = @floatFromInt(pt.restTime());
    const bs: f32 = @floatFromInt(pt.blendStart());
    for (self.world.effects.blood.items) |bl| for (0..bl.n) |i| {
        const d = bl.drops[i];
        if (d.dead) continue;
        const sz = (1 - og.num.toF32(d.shrink) / rt) * d.size * @as(f32, if (d.blend != 0) 1 else 0.7);
        try sink.put(.{
            .name = if (bl.flare) "flare1" else "redcircle",
            .frame = if (d.blend != 0) 3 else @intCast((i & 1) + 1),
            .pos = .{ bl.origin[0] + d.pos[0] * k, bl.origin[1] + d.pos[1] * k, bl.origin[2] + d.pos[2] * k },
            .half = as * sz,
            .alpha = if (og.num.toF32(d.blend) > bs) (rt - og.num.toF32(d.blend)) / (rt - bs) else 1,
        });
    };
}

/// Trails (og.effects.batch).
pub fn trails(self: *LevelView, sink: anytype) !void {
    try og.effects.batch.trails(self.world.effects.trails.items, self.world.actorScale(), sink);
}

/// Projectile planes (og.effects.batch).
pub fn projectilePlanes(self: *LevelView, sink: anytype) !void {
    try og.effects.batch.projectilePlanes(self.world.effects.projectiles.items, self.world.actorScale(), sink);
}

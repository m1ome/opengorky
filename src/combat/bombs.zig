//! Bomb clocks and blasts (hero bomb and large bomb). Sits above combat/strike.zig
//! because a blast strikes with a weapon; combat/devices.zig places the bombs.

const fields = @import("../fields.zig");
const strike_mod = @import("strike.zig");
const devices = @import("devices.zig");
const fx = @import("../fx.zig");
const battle = @import("../battle.zig").battle;
const Battle = battle.Battle;
const Bomb = battle.Bomb;
const World = @import("../state.zig").world.World;

/// Enemy turn start (0x498650 → +0xe8 of bomb fighters): each bomb clock −1, once
/// per turn (+0x24908). At zero it explodes and the rest wait for the next call.
/// The exe walks the object list with no HP check (0x4986b2…0x4986e8): a killed bomb
/// keeps ticking, and can still explode, until its corpse fades out and is removed.
pub fn tickBombs(self: *Battle, w: *World) !bool {
    var i: usize = 0;
    while (i < self.bombs.items.len) {
        const bomb = &self.bombs.items[i];
        if (World.nativeOf(bomb.obj).actor.gone) {
            _ = self.bombs.orderedRemove(i);
            continue;
        }
        i += 1;
        if (bomb.ticked) continue;
        bomb.ticked = true;
        const n = World.nativeOf(bomb.obj);
        n.fight.bomb_timer = n.fight.bomb_timer.? - 1;
        if (n.fight.bomb_timer.? > 0) continue;
        try explodeBomb(self, w, self.bombs.orderedRemove(i - 1));
        return true;
    }
    return false;
}

/// Bomb blast. Hero bomb (0x4bdd30): strike with `TimeBombExplode<N>` (+0xec,
/// +0xf0 with +0x1ab4 = 1) on the 8 neighbouring tiles, damage 40, on behalf of
/// the bomb. Large bomb (0x4bdfd0): every fighter of the level dies (+0xc8 each).
/// Then explosion 0x4d0610 at the tile + attack_grenade_exp (250)·aS, sound
/// "granat" there (0x4327f0), and the bomb disappears (0x48ed20).
fn explodeBomb(self: *Battle, w: *World, bomb: Bomb) !void {
    battle.note(self, "  {s}: blast", .{bomb.obj.name});
    const fi = bomb.fighter orelse return error.BombWithoutFighter;
    if (bomb.large) {
        removeDevice(self, fi);
        for (self.fighters.items) |*f| if (f.alive()) {
            fields.setHp(f.obj, 0);
            try strike_mod.hurt(self, w, @intCast(f - self.fighters.items.ptr), 1);
        };
    } else {
        if (try devices.spawnBombBlast(w)) |wpn| {
            self.bomb_blast = true;
            defer self.bomb_blast = false;
            try strike_mod.resolveAttack(self, w, fi, wpn, .{ .tile = bomb.tile, .effect = 0, .pct = 100 }, null, false);
            World.nativeOf(wpn).deleted = true;
            wpn.enabled = false;
        }
        removeDevice(self, fi);
    }
    if (w.combat_map) |cm| {
        const c = cm.tileCenter(bomb.tile, 1);
        const p = [3]f32{ c[0], c[1], c[2] + 250 * w.actorScale() };
        fx.explosion.explosion(w, p);
        const q = w.cam.project(p);
        w.out.sound(w.gpa, "granat", .{ q.x, q.y });
    }
    World.nativeOf(bomb.obj).deleted = true;
    bomb.obj.enabled = false;
    self.bomb_cam = bomb.tile;
}

fn removeDevice(self: *Battle, fi: u16) void {
    const f = &self.fighters.items[fi];
    if (f.dead) return; // killed earlier: its tile was freed then (0x490570)
    f.dead = true;
    self.grid().remove(f.tile, f.size);
}

test "bomb clock moves once per enemy turn (+0x24908, 0x498650)" {
    const std = @import("std");
    const script = @import("../script.zig");
    const gpa = std.testing.allocator;
    var rt: script.runtime.Runtime = .init(gpa, .{ .ctx = undefined, .fetch = undefined });
    defer rt.deinit();
    var cls: script.object.Class = .{ .name = "t.bomb", .parent = null };
    var b: Battle = .{ .gpa = gpa, .blocked = &.{}, .occupant = &.{}, .reach_left = &.{}, .fire = &.{}, .gas = &.{}, .width = 0, .height = 0 };
    defer b.bombs.deinit(gpa);
    var n1: @import("../state.zig").object.Native = .{ .kind = .level, .fight = .{ .bomb_timer = 2 } };
    var n2: @import("../state.zig").object.Native = .{ .kind = .level, .fight = .{ .bomb_timer = 3 } };
    const o1 = try rt.createObject("b1", &cls);
    const o2 = try rt.createObject("b2", &cls);
    o1.host = &n1;
    o2.host = &n2;
    try b.bombs.append(gpa, .{ .obj = o1, .tile = .{ 0, 0 } });
    try b.bombs.append(gpa, .{ .obj = o2, .tile = .{ 1, 0 } });
    var w: World = undefined; // no world needed before the blast
    try std.testing.expect(!try tickBombs(&b, &w));
    try std.testing.expectEqual([2]i32{ 1, 2 }, [2]i32{ n1.fight.bomb_timer.?, n2.fight.bomb_timer.? });
    // A second step in the same turn doesn't move the clock.
    try std.testing.expect(!try tickBombs(&b, &w));
    try std.testing.expectEqual([2]i32{ 1, 2 }, [2]i32{ n1.fight.bomb_timer.?, n2.fight.bomb_timer.? });
}

test "a killed bomb ticks until its corpse is gone (0x4986b2, +0x60 at 0x426950)" {
    const std = @import("std");
    const script = @import("../script.zig");
    const gpa = std.testing.allocator;
    var rt: script.runtime.Runtime = .init(gpa, .{ .ctx = undefined, .fetch = undefined });
    defer rt.deinit();
    var cls: script.object.Class = .{ .name = "t.bomb", .parent = null };
    var b: Battle = .{ .gpa = gpa, .blocked = &.{}, .occupant = &.{}, .reach_left = &.{}, .fire = &.{}, .gas = &.{}, .width = 0, .height = 0 };
    defer b.bombs.deinit(gpa);
    var n: @import("../state.zig").object.Native = .{ .kind = .actor, .fight = .{ .bomb_timer = 3 } };
    const o = try rt.createObject("b", &cls);
    o.host = &n;
    try b.bombs.append(gpa, .{ .obj = o, .tile = .{ 0, 0 } });
    var w: World = undefined;
    _ = try tickBombs(&b, &w);
    try std.testing.expectEqual(@as(?i32, 2), n.fight.bomb_timer);
    n.actor.gone = true;
    b.bombs.items[0].ticked = false;
    _ = try tickBombs(&b, &w);
    try std.testing.expectEqual(@as(usize, 0), b.bombs.items.len);
    try std.testing.expectEqual(@as(?i32, 2), n.fight.bomb_timer);
}

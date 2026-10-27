//! Bomb clocks and blasts (hero bomb and large bomb) and the Incubus ball charges.
//! Sits above combat/strike.zig because a blast strikes with a weapon;
//! combat/devices.zig places the bombs.

const adjust = @import("../formats.zig").adjust;
const fields = @import("../fields.zig");
const strike_mod = @import("strike.zig");
const devices = @import("devices.zig");
const fx = @import("../fx.zig");
const battle = @import("../battle.zig").battle;
const Battle = battle.Battle;
const Bomb = battle.Bomb;
const Charge = battle.Charge;
const World = @import("../state.zig").world.World;

/// Enemy turn start (0x498650): one walk of the object list from its head, newest first
/// (`seq`): each bomb fighter (type 0x1c) once (+0x24908) gets its clock −1 (+0xe8) and
/// explodes at zero; each Incubus ball (type 3) once (+0x3f8) blows up at countdown 1
/// (+0xc4 = 0x4a61d0). A blast ends the walk (+0x60); the rest wait for the next call.
/// No HP check (0x4986b2…0x4986e8): a killed bomb keeps ticking, and can still explode,
/// until its corpse fades out and is removed.
pub fn tickDevices(self: *Battle, w: *World) !bool {
    var i: usize = 0;
    while (i < self.bombs.items.len) {
        if (World.nativeOf(self.bombs.items[i].obj).actor.gone) _ = self.bombs.orderedRemove(i) else i += 1;
    }
    while (nextDevice(self)) |next| switch (next) {
        .bomb => |k| {
            const bomb = &self.bombs.items[k];
            bomb.ticked = true;
            const n = World.nativeOf(bomb.obj);
            n.fight.bomb_timer = n.fight.bomb_timer.? - 1;
            if (n.fight.bomb_timer.? > 0) continue;
            try explodeBomb(self, w, self.bombs.orderedRemove(k));
            return true;
        },
        .charge => |k| {
            const c = &self.charges.items[k];
            c.ticked = true;
            if (c.left != 1) continue;
            try explodeCharge(self, w, self.charges.orderedRemove(k));
            return true;
        },
    };
    return false;
}

/// The newest bomb or ball not yet walked this turn.
fn nextDevice(self: *Battle) ?union(enum) { bomb: usize, charge: usize } {
    var bi: ?usize = null;
    for (self.bombs.items, 0..) |b, k| if (!b.ticked and (bi == null or b.seq > self.bombs.items[bi.?].seq)) {
        bi = k;
    };
    var ci: ?usize = null;
    for (self.charges.items, 0..) |c, k| if (!c.ticked and (ci == null or c.seq > self.charges.items[ci.?].seq)) {
        ci = k;
    };
    if (bi) |k| if (ci == null or self.bombs.items[k].seq > self.charges.items[ci.?].seq) return .{ .bomb = k };
    return .{ .charge = ci orelse return null };
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
        const p = [3]f32{ c[0], c[1], c[2] + adjust.getFloat("attack_grenade_exp", 250) * w.actorScale() };
        fx.explosion.explosion(w, p);
        const q = w.cam.project(p);
        w.out.sound(w.gpa, "granat", .{ q.x, q.y });
    }
    World.nativeOf(bomb.obj).deleted = true;
    bomb.obj.enabled = false;
    self.bomb_cam = bomb.tile;
}

/// Incubus ball arrived (0x4a6056): no strike now, it lies with countdown
/// attack_ball_exp + 3 (at least 2) and the attack ends. Its weapon's stored roll
/// is this attack's.
pub fn placeCharge(self: *Battle, c: Charge) !void {
    var x = c;
    x.left = @max(2, adjust.getInt("attack_ball_exp", 0) + 3);
    for (self.charges.items) |*o| if (o.weapon == x.weapon) {
        o.strike = x.strike;
    };
    x.seq = self.nextSeq();
    try self.charges.append(self.gpa, x);
    battle.note(self, "turn {d}: ball of {s} lies at {d},{d}, countdown {d}", .{ self.turn, self.fighters.items[x.who].obj.name, x.aim.tile[0], x.aim.tile[1], x.left });
}

/// Enemy turn start (0x498310): +0x3f8 cleared (0x49841e), countdown −1 down to 1
/// (+0xc0 = 0x4a6260, 0x49844c).
pub fn chargeTurn(self: *Battle) void {
    for (self.charges.items) |*c| {
        c.ticked = false;
        if (c.left > 1) c.left -= 1;
    }
}

/// Ball blast (0x4a61d0): its weapon strikes the aimed tile (+0xf0 with the stored
/// roll, on behalf of the Incubus; whoever stands there now), then explosion
/// "KulaExpl" and "kula_explo" (fx/hits.zig onHit); the camera stays on the tile.
fn explodeCharge(self: *Battle, w: *World, c: Charge) !void {
    battle.note(self, "turn {d}: ball of {s} blasts at {d},{d}", .{ self.turn, self.fighters.items[c.who].obj.name, c.aim.tile[0], c.aim.tile[1] });
    w.effects.endProjectile(c.proj);
    var st = c.strike;
    try strike_mod.resolveAttack(self, w, c.who, c.weapon, c.aim, &st, false);
    // The end-of-strike roll changed the weapon's stored damage (0x4cf76f).
    for (self.charges.items) |*o| if (o.weapon == c.weapon) {
        o.strike = st;
    };
    self.bomb_cam = c.aim.tile;
}

fn removeDevice(self: *Battle, fi: u16) void {
    const f = &self.fighters.items[fi];
    if (f.dead) return; // killed earlier: its tile was freed then (0x490570)
    f.dead = true;
    self.grid().remove(f.tile, f.size);
}

/// Bombs on an empty battle, for the tests: `add` puts one (its engine data `n`).
const TestBombs = struct {
    const std = @import("std");
    const script = @import("../script.zig");
    const Native = @import("../state.zig").object.Native;
    const gpa = std.testing.allocator;

    rt: script.runtime.Runtime,
    cls: script.object.Class = .{ .name = "t.bomb", .parent = null },
    b: Battle = .{ .gpa = gpa, .blocked = &.{}, .occupant = &.{}, .reach_left = &.{}, .fire = &.{}, .gas = &.{}, .width = 0, .height = 0 },

    fn init() TestBombs {
        return .{ .rt = .init(gpa, .{ .ctx = undefined, .fetch = undefined }) };
    }

    fn deinit(self: *TestBombs) void {
        self.b.bombs.deinit(gpa);
        self.b.charges.deinit(gpa);
        self.rt.deinit();
    }

    fn add(self: *TestBombs, name: []const u8, n: *Native, x: i32) !void {
        const o = try self.rt.createObject(name, &self.cls);
        o.host = n;
        try self.b.bombs.append(gpa, .{ .obj = o, .tile = .{ x, 0 }, .seq = self.b.nextSeq() });
    }
};

test "bomb clock moves once per enemy turn (+0x24908, 0x498650)" {
    const std = @import("std");
    var t: TestBombs = .init();
    defer t.deinit();
    var n1: TestBombs.Native = .{ .kind = .level, .fight = .{ .bomb_timer = 2 } };
    var n2: TestBombs.Native = .{ .kind = .level, .fight = .{ .bomb_timer = 3 } };
    try t.add("b1", &n1, 0);
    try t.add("b2", &n2, 1);
    var w: World = undefined; // no world needed before the blast
    try std.testing.expect(!try tickDevices(&t.b, &w));
    try std.testing.expectEqual([2]i32{ 1, 2 }, [2]i32{ n1.fight.bomb_timer.?, n2.fight.bomb_timer.? });
    // A second step in the same turn doesn't move the clock.
    try std.testing.expect(!try tickDevices(&t.b, &w));
    try std.testing.expectEqual([2]i32{ 1, 2 }, [2]i32{ n1.fight.bomb_timer.?, n2.fight.bomb_timer.? });
}

test "a killed bomb ticks until its corpse is gone (0x4986b2, +0x60 at 0x426950)" {
    const std = @import("std");
    var t: TestBombs = .init();
    defer t.deinit();
    var n: TestBombs.Native = .{ .kind = .actor, .fight = .{ .bomb_timer = 3 } };
    try t.add("b", &n, 0);
    var w: World = undefined;
    _ = try tickDevices(&t.b, &w);
    try std.testing.expectEqual(@as(?i32, 2), n.fight.bomb_timer);
    n.actor.gone = true;
    t.b.bombs.items[0].ticked = false;
    _ = try tickDevices(&t.b, &w);
    try std.testing.expectEqual(@as(usize, 0), t.b.bombs.items.len);
    try std.testing.expectEqual(@as(?i32, 2), n.fight.bomb_timer);
}

test "bombs and balls in one walk, newest first (0x498650)" {
    const std = @import("std");
    var t: TestBombs = .init();
    defer t.deinit();
    var n1: TestBombs.Native = .{ .kind = .level, .fight = .{ .bomb_timer = 5 } };
    var n2: TestBombs.Native = .{ .kind = .level, .fight = .{ .bomb_timer = 5 } };
    try t.add("old", &n1, 0);
    try t.b.charges.append(TestBombs.gpa, .{ .proj = 0, .who = 0, .weapon = undefined, .aim = undefined, .strike = undefined, .left = 3, .seq = t.b.nextSeq() });
    try t.add("new", &n2, 1);
    try std.testing.expectEqual(@as(usize, 1), nextDevice(&t.b).?.bomb);
    t.b.bombs.items[1].ticked = true;
    try std.testing.expectEqual(@as(usize, 0), nextDevice(&t.b).?.charge);
    t.b.charges.items[0].ticked = true;
    try std.testing.expectEqual(@as(usize, 0), nextDevice(&t.b).?.bomb);
    t.b.bombs.items[0].ticked = true;
    try std.testing.expect(nextDevice(&t.b) == null);
}

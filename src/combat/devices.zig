//! Pushing, barrels, time bombs, decoys.

const std = @import("std");
const state_object = @import("../state.zig").object;
const fields = @import("../fields.zig");
const world = @import("../state.zig").world;
const Object = @import("../script.zig").object.Object;
const battle = @import("../battle.zig").battle;
const anim = @import("anim.zig");
const Battle = battle.Battle;
const World = @import("../state.zig").world.World;
const grid = @import("../battle.zig").grid;
const fx = @import("../fx.zig");
const inventory = @import("../inventory.zig");
const Tile = @import("../battle.zig").grid.Tile;
const max_fighters = battle.max_fighters;

/// Push an obstacle (0x47bb60): side neighbour (not diagonal) with `movable`; the
/// tile behind it must be inside, open and free. Ends the hero's turn.
pub fn push(self: *Battle, w: *World, t: Tile) !bool {
    if (self.phase != .player or self.pending != .none) return false;
    const me = self.selected orelse return false;
    const f = &self.fighters.items[me];
    if (f.acted or !f.alive() or f.disabled() or f.size != 1) return false;
    // Push button (0x4b1907): not Medusa (119) and not a woman (`sex` 1, +0x24580).
    if (fields.isMedusa(f.obj) or f.obj.getInt("sex") == 1) return false;
    const g = self.grid();
    const o = g.at(t);
    if (o == grid.Grid.none) return false;
    const ob = &self.fighters.items[o];
    if (!ob.movable or !ob.alive()) return false;
    const d: Tile = .{ t[0] - f.tile[0], t[1] - f.tile[1] };
    if (@abs(d[0]) + @abs(d[1]) != 1) return false;
    const to: Tile = .{ ob.tile[0] + d[0], ob.tile[1] + d[1] };
    for (0..ob.size) |dy| for (0..ob.size) |dx| {
        const c: Tile = .{ to[0] + @as(i32, @intCast(dx)), to[1] + @as(i32, @intCast(dy)) };
        if (!g.inside(c) or !g.open(c)) return false;
        const who = g.at(c);
        if (who != grid.Grid.none and who != o) return false;
    };
    const two = if (inventory.equipment.equipped(w, f.obj, .hand)) |h| h.getInt("two_handed") != 0 else false;
    // Turn smoothly to the obstacle first (0x48d95f → 0x425150), then push_start.
    anim.face(w, f.*, t);
    g.remove(ob.tile, ob.size);
    f.acted = true;
    f.spendRage(); // 0x48f790
    f.used = @floatFromInt(fields.walkRange(f.obj));
    @memset(self.reach_left, -1);
    self.target_len = 0;
    self.pending = .{ .push = .{ .hero = me, .obstacle = o, .to = to, .sound = if (ob.explosive) "pull_barell" else "pull_wood_box", .sound_ticks = if (two) 110 else 47 } };
    // Successful push (0x452bc4): 0x455490(hero, 1), i.e. camera pan and
    // selecthero; fightlook is replaced right away by the push queue (push_start).
    w.out.pan_to = f.obj;
    w.out.sound(w.gpa, "selecthero", null);
    battle.note(self, "turn {d}: {s} pushes {s}", .{ self.turn, f.obj.name, ob.obj.name });
    return true;
}

/// Barrel death (0x490570, 0x491f60): off the grid, disappears at once,
/// `killedEnemies` +1 (no exp); explosion and "granat" at the tile; ~15 ticks
/// later its `explodeWeapon` (class 17) strikes the neighbours, chaining blasts.
pub fn destroyBarrel(self: *Battle, w: *World, v: u16) !void {
    const t = &self.fighters.items[v];
    if (t.dead) return;
    t.dead = true;
    self.grid().remove(t.tile, t.size);
    World.nativeOf(t.obj).deleted = true;
    t.obj.enabled = false;
    if (w.level) |l| l.setInt("killedEnemies", l.getInt("killedEnemies") + 1);
    const wpn = w.rt.findObject(t.obj.getString("explodeWeapon"));
    // The visual blast comes now, from the weapon's +0xe4 (0x492067 → 0x4ceb40): explosion
    // and "granat" at the tile + attack_grenade_exp (250)·aS, only for weapon nameID 1002
    // (0x4ceb72; every barrel in the game). The damage 15 ticks later has no visual (the
    // class-17 hit 0x4bb990 only calls the target's reaction).
    const visual = if (wpn) |o| fields.nameId(o) == 1002 else false;
    battle.note(self, "  {s} explodes{s}", .{ t.obj.name, if (visual) " (explosion)" else "" });
    if (visual) if (w.combat_map) |cm| {
        const c = cm.tileCenter(t.tile, 1);
        const p = [3]f32{ c[0], c[1], c[2] + 250 * w.actorScale() };
        fx.explosion.explosion(w, p);
        const q = w.cam.project(p);
        w.out.sound(w.gpa, "granat", .{ q.x, q.y });
    };
    const weapon = wpn orelse return;
    const order = std.mem.indexOfScalar(*Object, w.rt.objects.items, weapon) orelse 0;
    var at: usize = 0;
    while (at < self.blasts.items.len and self.blasts.items[at].order > order) at += 1;
    try self.blasts.insert(self.gpa, at, .{ .barrel = v, .weapon = weapon, .tile = t.tile, .ticks = 15, .order = order, .credit = t.last_attacker });
}

pub fn placeDecoy(self: *Battle, w: *World, t: Tile) !void {
    if (self.fighters.items.len == max_fighters) return;
    const o = try spawnDecoy(w, w.combat_map.?.tileCenter(t, 1)) orelse return;
    try self.decoys.append(w.gpa, .{ .obj = o, .tile = t, .fighter = try addDevice(self, o, t) });
    battle.note(self, "  decoy at {d},{d}", .{ t[0], t[1] });
}

/// Enemy turn start (0x4984c7 → 0x495170): the decoy list is rebuilt from the grid,
/// row by row, decoys (class 0x1d) still on their tile. A decoy killed later this
/// turn still attracts until the next rebuild.
pub fn refreshDecoys(self: *Battle) void {
    var n: usize = 0;
    for (self.decoys.items) |d| {
        if (d.fighter) |fi| if (self.fighters.items[fi].dead) continue;
        self.decoys.items[n] = d;
        n += 1;
    }
    self.decoys.shrinkRetainingCapacity(n);
    std.mem.sort(battle.Bomb, self.decoys.items, {}, struct {
        fn lt(_: void, a: battle.Bomb, b: battle.Bomb) bool {
            return a.tile[1] < b.tile[1] or (a.tile[1] == b.tile[1] and a.tile[0] < b.tile[0]);
        }
    }.lt);
}

/// Hero bomb (callback 37, 0x488128 → 0x4b9490 → 0x4bd8c0): fighter
/// `TimeBomb<N>` on the aimed tile if it is open and free.
pub fn placeTimeBomb(self: *Battle, w: *World, t: Tile) !void {
    const cm = w.combat_map orelse return;
    if (!self.grid().open(t) or self.grid().at(t) != grid.Grid.none) return;
    if (self.fighters.items.len == max_fighters) return;
    const o = try spawnTimeBomb(w, cm.tileCenter(t, 1)) orelse return;
    try self.bombs.append(w.gpa, .{ .obj = o, .tile = t, .fighter = try addDevice(self, o, t) });
    battle.note(self, "  bomb at {d},{d}", .{ t[0], t[1] });
}

/// Device on the grid (0x48e890 → 0x48eb70 → 0x494fe0): bomb, large bomb and decoy
/// are Fighter.s objects occupying their tile, so a ray stops there and the tile
/// itself is an aim (0x4ce575). Neutral, size 1; caller checks `max_fighters`.
pub fn addDevice(self: *Battle, o: *Object, t: Tile) !u16 {
    const fi: u16 = @intCast(self.fighters.items.len);
    try self.fighters.append(self.gpa, .{ .obj = o, .side = .neutral, .tile = t, .size = 1 });
    self.grid().place(t, 1, fi);
    return fi;
}

/// Hero bomb (0x4bd8c0): fighter `TimeBomb<N>` of class `ft_time_bomb.ss`,
/// clock set to 2 enemy turns (0x4bdc93).
fn spawnTimeBomb(self: *World, pos: [3]f32) !?*Object {
    return placeDevice(self, "TimeBomb", "ft_time_bomb.ss", .{ .kind = .actor, .fight = .{ .bomb_timer = 2 } }, pos);
}

/// Device fighter `<prefix><N>` of class `class_file` at `pos`: init, post_init, idle.
fn placeDevice(self: *World, prefix: []const u8, class_file: []const u8, init: state_object.Native, pos: [3]f32) !?*Object {
    self.bombs_placed += 1;
    var buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "{s}{d}", .{ prefix, self.bombs_placed });
    const cls = self.rt.loadClass(class_file) catch return null;
    const o = try self.addObject(name, cls, init);
    _ = try self.rt.callIfExists(o, "init", &.{});
    _ = try self.rt.callIfExists(o, "post_init", &.{});
    fields.setPos(o, pos);
    const a = world.actorOf(o);
    a.placed = true;
    a.pickIdle(self.crt());
    return o;
}

/// Hero bomb blast weapon (0x4bdd7b): `TimeBombExplode<N>` of class
/// `wp_timebomb_explode.s` (nameID 1002, class 9, damage 40).
pub fn spawnBombBlast(self: *World) !?*Object {
    self.bombs_placed += 1;
    var buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "TimeBombExplode{d}", .{self.bombs_placed});
    const cls = self.rt.loadClass("wp_timebomb_explode.s") catch return null;
    const o = try self.addObject(name, cls, .{ .kind = .weapon });
    _ = try self.rt.callIfExists(o, "class_init", &.{});
    _ = try self.rt.callIfExists(o, "init", &.{});
    return o;
}

/// Decoy (0x4bdb40): "fighter" `Distractor<N>` of class `ft_distractor.ss` at a point.
fn spawnDecoy(self: *World, pos: [3]f32) !?*Object {
    return placeDevice(self, "Distractor", "ft_distractor.ss", .{ .kind = .actor, .fight = .{ .decoy = true } }, pos);
}

//! Console debug actions: attack, teleport, fighter spawn, medicine.

const std = @import("std");
const weapon_class = @import("../battle.zig").weapon_class;
const fields = @import("../fields.zig");
const control = @import("control.zig");
const strike = @import("strike.zig");
const roster = @import("roster.zig");
const battle = @import("../battle.zig").battle;
const anim = @import("anim.zig");
const Battle = battle.Battle;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const Object = @import("../script.zig").object.Object;
const WeaponClass = @import("../battle.zig").weapon_class.WeaponClass;
const grid = @import("../battle.zig").grid;
const patterns = @import("../battle.zig").patterns;
const inventory = @import("../inventory.zig");
const Tile = @import("../battle.zig").grid.Tile;

/// Console `win`. The exe has no such cheat, so an honest end: the 04__city_mfd Invisible
/// never dies but leaves (0x4985fb → 0x49839f: not a death); every other enemy dies as in
/// a fight (strike.hurt: grid, death, corpse, killedEnemies); the usual victory follows
/// (turns.checkEnd).
pub fn debugWin(self: *Battle, w: *World) !void {
    if (self.invisibleMfd()) |i| {
        const f = &self.fighters.items[i];
        if (!self.invisible_leaving) self.grid().remove(f.tile, f.size);
        self.invisible_leaving = false;
        f.dead = true;
        World.nativeOf(f.obj).deleted = true;
        f.obj.enabled = false;
    }
    for (0..self.fighters.items.len) |i| {
        const f = self.fighters.items[i];
        if (f.side == .enemy and f.alive()) try strike.hurt(self, w, @intCast(i), @max(1, f.hp()));
    }
}

/// Player turn forced before the enemies finished appearing (console on the first
/// battle tick): finish the walk-in at once, otherwise an enemy left off-grid is
/// not a fighter yet alive, and the battle never ends.
fn skipAppear(self: *Battle, w: *World) void {
    if (self.phase != .appear) return;
    self.appear_walker = null;
    for (self.fighters.items, 0..) |*f, k| if (f.appear_to) |to| {
        f.tile = to;
        f.appear_to = null;
        self.grid().place(to, f.size, @intCast(k));
        world_mod.actorOf(f.*.obj).placed = true;
        anim.snap(w, f.*);
    };
}

/// Debug (console `attack`): hero `hero` strikes `target` (null = nearest live
/// enemy) with `wpn` as in battle (animation, effects, damage) without turn
/// checks. The hero is moved to a free tile from which the target is hit (the
/// farthest, at most 4 tiles away, so the projectile is visible). false on failure.
pub fn debugAttack(self: *Battle, w: *World, hero: *Object, wpn: *Object, target: ?*Object, here: bool) !bool {
    if (self.pending != .none) return false;
    const me = self.fighterOf(hero) orelse return false;
    const cm = w.combat_map orelse return false;
    const g = self.grid();
    const f0 = self.fighters.items[me];
    var tv: u16 = grid.Grid.none;
    if (target) |t| tv = self.fighterOf(t) orelse return false else {
        var best: i32 = std.math.maxInt(i32);
        for (self.fighters.items, 0..) |o, i| {
            if (o.side != .enemy or !o.alive()) continue;
            const d: i32 = @intCast(@max(@abs(o.tile[0] - f0.tile[0]), @abs(o.tile[1] - f0.tile[1])));
            if (d < best) {
                best = d;
                tv = @intCast(i);
            }
        }
    }
    if (tv == grid.Grid.none) return false;
    const pat = weapon_class.pattern(wpn) orelse return false;
    const tt = self.fighters.items[tv].tile;
    var best_tile: ?Tile = null;
    var best_aim: grid.Target = undefined;
    var best_d: i32 = -1;
    var buf: [256]grid.Target = undefined;
    var y: i32 = tt[1] - 4;
    while (y <= tt[1] + 4) : (y += 1) {
        var x: i32 = tt[0] - 4;
        while (x <= tt[0] + 4) : (x += 1) {
            const t: Tile = .{ x, y };
            // `here`: only from its own tile (no move).
            if (here and (x != f0.tile[0] or y != f0.tile[1])) continue;
            if (!g.fits(t, f0.size, me)) continue;
            const d: i32 = @intCast(@max(@abs(x - tt[0]), @abs(y - tt[1])));
            if (d <= best_d) continue;
            for (grid.targets(g, pat, t, me, true, false, &buf)) |aim| if (aimCovers(g, pat, aim, tv)) {
                best_tile = t;
                best_aim = aim;
                best_d = d;
                break;
            };
        }
    }
    const t = best_tile orelse return false;
    const f = &self.fighters.items[me];
    g.remove(f.tile, f.size);
    f.tile = t;
    g.place(t, f.size, me);
    world_mod.actorOf(f.*.obj).stopWalking(w.crt());
    fields.setPos(f.obj, cm.tileCenter(t, f.size));
    inventory.equipment.toHand(w, hero, wpn);
    World.nativeOf(wpn).fight.recharge = 0;
    f.weapon = wpn;
    f.acted = false;
    // Walk budget spent, so no walk-range highlight after the strike.
    f.used = @floatFromInt(fields.walkRange(f.obj));
    skipAppear(self, w);
    self.phase = .player;
    self.selected = me;
    w.selected_hero = hero.name;
    try strike.startAttack(self, w, me, wpn, best_aim);
    return true;
}

/// Debug (console `put`): move a fighter to tile `t` if it is free.
pub fn debugPut(self: *Battle, w: *World, o: *Object, t: Tile) bool {
    const cm = w.combat_map orelse return false;
    const who = self.fighterOf(o) orelse return false;
    const g = self.grid();
    const f = &self.fighters.items[who];
    if (!g.fits(t, f.size, who)) return false;
    g.remove(f.tile, f.size);
    f.tile = t;
    g.place(t, f.size, who);
    world_mod.actorOf(f.*.obj).stopWalking(w.crt());
    fields.setPos(f.obj, cm.tileCenter(t, f.size));
    return true;
}

/// A fighter created mid-battle (console `spawn`, `spawnFile`): at the centre of
/// tile `t`, into the battle and the grid, facing the nearest opponent (+0xd0).
/// false if the tile is outside the grid or taken.
fn spawnFighter(self: *Battle, w: *World, o: *Object, t: Tile) !bool {
    const cm = w.combat_map orelse return false;
    const size = roster.fighterSize(o);
    if (!self.grid().fits(t, size, grid.Grid.none)) return false;
    fields.setPos(o, cm.tileCenter(t, size));
    world_mod.actorOf(o).placed = true;
    const first = self.fighters.items.len;
    _ = try roster.addNewcomers(self, w);
    for (self.fighters.items[first..], first..) |_, i| control.faceDefault(self, w, i, false);
    return self.fighterOf(o) != null;
}

/// Debug (console `medicine`): hero `hero` gives `item` to `target` as in battle
/// (`useItemOn`) without turn checks; if not adjacent, it is moved to a free
/// neighbouring tile.
pub fn debugMedicine(self: *Battle, w: *World, hero: *Object, item: *Object, target: *Object) !bool {
    if (self.pending != .none) return false;
    const me = self.fighterOf(hero) orelse return false;
    const tv = self.fighterOf(target) orelse return false;
    const tt = self.fighters.items[tv].tile;
    const f = &self.fighters.items[me];
    if (me != tv and (@abs(f.tile[0] - tt[0]) + @abs(f.tile[1] - tt[1]) > 1)) {
        for ([_]Tile{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } }) |d| {
            if (debugPut(self, w, hero, .{ tt[0] + d[0], tt[1] + d[1] })) break;
        } else return false;
    }
    f.acted = false;
    skipAppear(self, w);
    self.phase = .player;
    self.selected = me;
    w.selected_hero = hero.name;
    return try control.useItemOn(self, w, item, tt) == .used;
}

/// Put a fighter from file `file` (`.ftr`, usually a mod) into the battle at
/// `tile` (console `spawn`). The object is named after the file (numbered if
/// taken). Weapons are the files listed in the fighter's `weapons` field
/// ("a.wpn, b.wpn"), owned by the new fighter, the first in hand. Returns the
/// fighter or null (no file, no battle, tile taken).
pub fn spawnFile(self: *World, file: []const u8, tile: [2]i32) !?*Object {
    const b = &(self.battle orelse return null);
    const ext = std.fs.path.extension(file);
    const stem = file[0 .. file.len - ext.len];
    var name_buf: [64]u8 = undefined;
    var name: []const u8 = stem;
    var k: u32 = 2;
    while (self.rt.findObject(name) != null) : (k += 1) {
        name = std.fmt.bufPrint(&name_buf, "{s}_{d}", .{ stem, k }) catch return null;
    }
    const cls = self.rt.loadClass(file) catch |err| {
        std.log.warn("spawn {s}: {t}", .{ file, err });
        return null;
    };
    const o = try self.addObject(name, cls, @import("../state.zig").object.nativeFor(".ftr"));
    _ = try self.rt.callIfExists(o, "init", &.{});
    try @import("../world.zig").start.actorHooks(self, o);
    var first = true;
    var it = std.mem.tokenizeAny(u8, o.getString("weapons"), ", ;\t");
    while (it.next()) |wf| {
        const wext = std.fs.path.extension(wf);
        var wname_buf: [96]u8 = undefined;
        const wname = std.fmt.bufPrint(&wname_buf, "{s}_{s}", .{ name, wf[0 .. wf.len - wext.len] }) catch continue;
        if (self.rt.findObject(wname) != null) continue;
        const wcls = self.rt.loadClass(wf) catch |err| {
            std.log.warn("spawn {s}: {s}: {t}", .{ name, wf, err });
            continue;
        };
        const wo = try self.addObject(wname, wcls, .{ .kind = .weapon });
        _ = try self.rt.callIfExists(wo, "class_init", &.{});
        _ = try self.rt.callIfExists(wo, "init", &.{});
        fields.setOwner(wo, try self.rt.arena().dupe(u8, name));
        wo.setInt("place", if (first) 11 else 10);
        first = false;
    }
    _ = try self.rt.callIfExists(o, "post_init", &.{});
    if (!try spawnFighter(b, self, o, tile)) {
        o.enabled = false;
        World.nativeOf(o).deleted = true;
        return null;
    }
    return o;
}

/// The aim hits fighter `tv`: it stands on it, or for a bomb (class 9, placed on
/// an empty tile) the effect area covers it.
fn aimCovers(g: grid.Grid, pat: *const patterns.Weapon, aim: grid.Target, tv: u16) bool {
    // Bomb and wide ray (Jet Elmer, two tiles wide): the target is in the effect area.
    if (WeaponClass.from(pat.class) != .time_bomb and !pat.wide) return g.at(aim.tile) == tv;
    var eff: [128]Tile = undefined;
    for (grid.effectTiles(g, pat, aim, &eff)) |t| if (g.at(t) == tv) return true;
    return false;
}

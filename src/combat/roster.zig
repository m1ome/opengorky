//! Battle roster: who takes part, newcomers walking in, battle setup on a battle level
//! and the victory unlock.

const std = @import("std");
const fields = @import("../fields.zig");
const weapons = @import("weapons.zig");
const control = @import("control.zig");
const anim = @import("anim.zig");
const devices = @import("devices.zig");
const Object = @import("../script.zig").object.Object;
const battle = @import("../battle.zig").battle;
const Battle = battle.Battle;
const World = @import("../state.zig").world.World;
const grid = @import("../battle.zig").grid;
const generic = @import("../battle.zig").generic;
const Fighter = @import("../battle.zig").fighter.Fighter;
const max_fighters = battle.max_fighters;

/// A battle participant is only a fighter on the battle grid (or walking onto it
/// via AIEnemyAppear). A party hero the battle script didn't place (Slavsky in
/// 03__museum_child stays at the level coordinates outside the grid) doesn't take
/// part: not a fighter, target or AI opponent, doesn't act, doesn't count for
/// victory or defeat, isn't shown on the field (player's decision; in the exe such
/// a hero stays in the AI opponent list 0x498da0 with an old tile +0x24600).
fn participates(self: *Battle, f: Fighter) bool {
    return self.grid().inside(f.tile);
}

/// Fighter size in tiles by `charSize`: ≥ 9 is 3×3, ≥ 4 is 2×2, else 1.
pub fn fighterSize(o: *Object) u32 {
    const cs = fields.charSize(o);
    return if (cs >= 9) 3 else if (cs >= 4) 2 else 1;
}

/// Fighters not yet in the battle: placed by restore() or walking in
/// (AIEnemyAppear, also between turns). Returns whether any are walking in.
pub fn addNewcomers(self: *Battle, w: *World) !bool {
    const cm = w.combat_map.?;
    const first = self.fighters.items.len;
    for (w.rt.objects.items) |o| {
        const nat = World.nativeOf(o);
        if (nat.kind != .actor or !o.enabled or nat.deleted) continue;
        if (!fields.isFighter(o)) continue; // not a fighter
        if (nat.fight.bomb_timer != null or nat.fight.decoy) continue; // bomb and decoy have their own records
        if (!nat.actor.placed and nat.fight.appear == null) continue;
        if (self.fighterOf(o) != null) continue;
        const size = fighterSize(o);
        var f: Fighter = .{
            .obj = o,
            // An extra hero (`.hro` with avoidEnumerate, the singer on the barge) is on the
            // hero side too: enemies hit him and his death ends the game (0x490620).
            .side = if (nat.hero or (nat.hro and o.getInt("avoidEnumerate") != 0)) .hero else if (nat.obstacle) .neutral else .enemy,
            .tile = cm.tileOf(fields.pos(o), size),
            .size = size,
            .explosive = nat.obstacle and o.getInt("explosive") != 0,
            .movable = nat.obstacle and o.getInt("movable") != 0,
        };
        if (nat.fight.appear) |ap| {
            f.tile = ap.from;
            f.appear_to = ap.to;
        } else if (!participates(self, f)) continue;
        if (self.fighters.items.len == max_fighters) break;
        // An invisible monster (0x48e890) starts the battle invisible.
        if (fields.isInvisibleMonster(o)) {
            nat.actor.invisible = true;
            nat.actor.alpha = 0;
        }
        generic.registerFighter(w.immunity, o);
        try self.fighters.append(w.gpa, f);
    }
    var appearing = false;
    for (self.fighters.items[first..], first..) |*f, i| {
        if (f.side != .neutral) f.weapon = weapons.defaultWeapon(w, f.*);
        if (f.appear_to == null) self.grid().place(f.tile, f.size, @intCast(i)) else appearing = true;
        anim.snap(w, f.*);
    }
    return appearing;
}

/// Enemy appearance (AIEnemyAppear); the `appear` phase ends on the first tick when
/// everyone arrived (or nobody walks in).
pub fn startAppear(self: *Battle, w: *World) void {
    _ = w;
    // At battle start the flag is set by GUI_Staging (after_select_gui after init).
    self.enemy_period = self.started or self.staging;
    self.appear_walker = null;
}

/// Battle on an already started battle level: heroes and enemies placed by restore().
pub fn init(w: *World) !Battle {
    const cm = w.combat_map orelse return error.NoCombatMap;
    const n = @as(usize, cm.width) * cm.height;
    var b: Battle = .{
        .gpa = w.gpa,
        .blocked = try w.gpa.dupe(bool, cm.blocked),
        .occupant = try w.gpa.alloc(u16, n),
        .reach_left = try w.gpa.alloc(f32, n),
        .ai_reach = try w.gpa.alloc(f32, n),
        .fire = try w.gpa.alloc(u8, n),
        .gas = try w.gpa.alloc(u8, n),
        .width = cm.width,
        .height = cm.height,
    };
    errdefer b.deinit();
    @memset(b.occupant, grid.Grid.none);
    @memset(b.reach_left, -1);
    @memset(b.fire, 0);
    @memset(b.gas, 0);
    // The fighter list never moves: *Fighter pointers survive additions.
    try b.fighters.ensureTotalCapacity(w.gpa, max_fighters);
    _ = try addNewcomers(&b, w);
    // Battle level restore (0x4b49f0 → 0x4b4a51): every fighter gets +0xd0(1), an
    // instant turn (to the nearest opponent; Puppet −1.57, Messiah 3.14).
    for (b.fighters.items, 0..) |f, i| if (f.appear_to == null) control.faceDefault(&b, w, i, false);
    for (w.rt.objects.items) |o| {
        if (World.nativeOf(o).fight.bomb_timer == null or World.nativeOf(o).deleted) continue;
        const t = cm.tileOf(fields.pos(o), 1);
        if (!b.grid().inside(t) or b.fighters.items.len == max_fighters) continue;
        try b.bombs.append(w.gpa, .{ .obj = o, .tile = t, .fighter = try devices.addDevice(&b, o, t), .large = true });
    }
    // Between battles weapons are always recharged.
    for (w.rt.objects.items) |o| {
        const nat = World.nativeOf(o);
        if (nat.kind == .weapon) nat.fight.recharge = 0;
    }
    startAppear(&b, w);
    return b;
}

/// Victory (0x4562c0): moveLock and attackLock are cleared for every fighter of the
/// level, so Medusa, chained in the museum corner during the battle, leaves it free.
pub fn unlockAll(w: *World) void {
    for (w.rt.objects.items) |o| {
        if (World.nativeOf(o).kind != .actor or !fields.isFighter(o)) continue;
        fields.clearMoveLock(o);
        o.setInt("attackLock", 0);
    }
}

test "battle participant is only a fighter on the grid" {
    var blocked: [12]bool = @splat(false);
    var occ: [12]u16 = @splat(0);
    var b: Battle = .{ .gpa = std.testing.allocator, .blocked = &blocked, .occupant = &occ, .reach_left = &.{}, .fire = &.{}, .gas = &.{}, .width = 4, .height = 3 };
    var f: Fighter = .{ .obj = undefined, .side = .hero, .tile = .{ 3, 2 }, .size = 1 };
    try std.testing.expect(participates(&b, f));
    f.tile = .{ 91, 19 }; // Slavsky at the level coordinates, outside the battle grid
    try std.testing.expect(!participates(&b, f));
    f.tile = .{ -1, 0 };
    try std.testing.expect(!participates(&b, f));
}

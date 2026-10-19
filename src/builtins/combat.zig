//! Script builtins: combat (AI*, Fighter*, PlaceCombatActor, bombs).

const std = @import("std");
const num = @import("../num.zig");
const fields = @import("../fields.zig");
const turns = @import("../combat.zig").turns;
const runtime = @import("../script.zig").runtime;
const rules = @import("../battle.zig").rules;
const grid = @import("../battle.zig").grid;
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;
const Runtime = runtime.Runtime;
const Value = @import("../script.zig").value.Value;
const args_mod = @import("args.zig");

/// PlaceCombatActor(name, x, y, angle°) (0x4bf240): a battle prop (machine gun,
/// log) at a fractional grid tile, not snapped to the tile centre (0x497a80).
pub fn biPlaceCombatActor(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    if (World.nativeOf(o).kind != .actor or args.len < 4) return .zero;
    const cm = w.combat_map orelse return .zero;
    const wp = cm.toWorld(args[1].toFloat(), args[2].toFloat());
    fields.setPos(o, .{ wp[0], wp[1], cm.center[2] });
    fields.setAngle(o, args[3].toFloat() * std.math.pi / 180.0);
    world.actorOf(o).placed = true;
    return .{ .int = 1 };
}

/// AIFreeTile(x, y) (0x4bed00): tile inside the grid, open and unoccupied.
pub fn biAIFreeTile(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const b = &(w.battle orelse return .zero);
    if (args.len < 2) return .zero;
    const t: [2]i32 = .{ args[0].toInt(), args[1].toInt() };
    const g = b.grid();
    return .{ .int = @intFromBool(g.open(t) and g.at(t) == grid.Grid.none) };
}

/// PutLargeTimeBomb(x, y) (0x4bea30 → 0x4bda10/0x4bdf70): bomb fighter
/// `TimeBombLarge<N>` of class `ft_time_bomb_large.ss` on a free tile; after 6
/// enemy turns it explodes and everyone dies (museum battle behind the red card).
pub fn biPutLargeTimeBomb(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const cm = w.combat_map orelse return .zero;
    if (args.len < 2) return .zero;
    const x = args[0].toInt();
    const y = args[1].toInt();
    if (x < 0 or y < 0 or x >= cm.width or y >= cm.height) return .zero;
    w.bombs_placed += 1;
    var buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "TimeBombLarge{d}", .{w.bombs_placed});
    const cls = try rt.loadClass("ft_time_bomb_large.ss");
    const o = try w.addObject(name, cls, .{ .kind = .actor, .fight = .{ .bomb_timer = 6 } });
    const n = World.nativeOf(o);
    _ = try rt.callIfExists(o, "init", &.{});
    _ = try rt.callIfExists(o, "post_init", &.{});
    const wp = cm.toWorld(num.toF32(x) + 0.5, num.toF32(y) + 0.5);
    fields.setPos(o, .{ wp[0], wp[1], cm.center[2] });
    n.actor.placed = true;
    n.actor.pickIdle(w.crt());
    return .{ .int = 1 };
}

/// AIEnemyAppear(name, x0, y0, x1, y1) (0x4bebe0): the enemy stands at (x0, y0)
/// (often outside the grid) and walks to (x1, y1) at battle start.
pub fn biAIEnemyAppear(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    if (!world.isActor(o) or args.len < 5) return .zero;
    // 0x4bebe0: the actor is placed at once at the centre of (x0, y0), adjusted for size.
    if (args_mod.worldOf(ctx).combat_map) |cm| {
        const cs = fields.charSize(o);
        const size: u32 = if (cs >= 9) 3 else if (cs >= 4) 2 else 1;
        const p = cm.tileCenter(.{ args[1].toInt(), args[2].toInt() }, size);
        fields.setPos(o, p);
        world.actorOf(o).placed = true;
    }
    World.nativeOf(o).fight.appear = .{
        .from = .{ args[1].toInt(), args[2].toInt() },
        .to = .{ args[3].toInt(), args[4].toInt() },
    };
    return .zero;
}

pub fn biFighterGetHp(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    return .{ .int = fields.hp(o) };
}

/// FighterSetHp("fighter", hp) (0x4be8e0): integer hp only, no upper clamp.
pub fn biFighterSetHp(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    if (args.len > 1 and args[1] == .int) fields.setHp(o, args[1].int);
    return .zero;
}

/// FighterSetLevel(name, level) (0x4be930): level, and exp = that level's
/// threshold (0x48f9c0). Heroes who join come at level five.
pub fn biFighterSetLevel(_: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    if (args.len < 2) return .zero;
    const o = rt.findObject(args_mod.argString(args, 0)) orelse return .zero;
    const level = args[1].toInt();
    fields.setExperience(o, rules.levelThreshold(level));
    o.setInt("level", level);
    return .zero;
}

/// HERO_EnableEnumerate(name, on) (0x4c1970): a hero from the global list joins
/// or leaves the party (`avoidEnumerate` = !on). Slavsky after the stun grenade,
/// McFadden in the sewers; BT and Medusa leaving.
pub fn biHeroEnableEnumerate(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    _ = ctx;
    const o = rt.findObject(args_mod.argString(args, 0)) orelse return .zero;
    const n = World.nativeOf(o);
    if (!n.hro or args.len < 2) return .zero;
    const on = args[1].toInt() != 0;
    o.setInt("avoidEnumerate", @intFromBool(!on));
    n.hero = on;
    return .zero;
}

/// GUI_IsHero(name): hero is in the party (on the panel).
pub fn biGuiIsHero(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.worldOf(ctx).actorObject(args_mod.argString(args, 0)) orelse return .zero;
    return .{ .int = @intFromBool(World.nativeOf(o).hero and o.enabled) };
}

/// AITargetLock(fighter, target) (0x4beae0): strike only this target (aiMode 1).
pub fn biAITargetLock(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    if (!world.isActor(o)) return .zero;
    World.nativeOf(o).fight.target_lock = try rt.arena().dupe(u8, args_mod.argString(args, 1));
    o.setInt("aiMode", 1);
    return .zero;
}

/// AIGuardPoint(fighter, x, y) (0x4beb60): hold the tile (aiMode 3).
pub fn biAIGuardPoint(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    if (!world.isActor(o) or args.len < 3) return .zero;
    World.nativeOf(o).fight.guard_point = .{ args[1].toInt(), args[2].toInt() };
    o.setInt("aiMode", 3);
    return .zero;
}

pub fn biAIGetTurnNo(ctx: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    return .{ .int = if (w.battle) |b| b.turn else 0 };
}

/// EndTurnGlobal() (0x4bea10 → 0x45b490): ends the side's turn.
pub fn biEndTurnGlobal(ctx: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    if (w.battle) |*b| try turns.endTurn(b, w);
    return .zero;
}

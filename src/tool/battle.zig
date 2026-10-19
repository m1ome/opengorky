//! gorky-tool `battle` (`--sounds`), `decoytest`: AI-driven auto-battle on a level.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const common = @import("common.zig");

/// Headless battle: heroes and enemies move by AI until one side wins.
/// Battles in sequence (`a,b,c`): heroes, their health, exp and items carry over.
pub fn autoBattle(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8, levels: []const u8, turns: i32, seed: u64) !void {
    var dat = try common.openDat(io, game_dir, .{});
    defer dat.close(io);
    var models = try og.actor.model_cache.Cache.open(io, gpa, dat);
    defer models.deinit();
    var party: ?og.world.party.Party = null;
    defer if (party) |*p| p.deinit();
    var it = std.mem.splitScalar(u8, levels, ',');
    while (it.next()) |level| {
        try out.print("=== {s}\n", .{level});
        const world = try og.game.life.create(io, gpa, dat, level, &models, .{ .party = if (party) |*p| p else null });
        defer world.destroy();
        try battleOne(out, world, level, turns, seed);
        if (party) |*p| p.deinit();
        party = try og.world.party.Party.capture(gpa, world);
    }
}

/// `battle --sounds`: print the sounds started on each battle tick (tick, name).
pub var log_sounds = false;

pub fn battleOne(out: *Io.Writer, world: *og.state.world.World, level: []const u8, turns: i32, seed: u64) !void {
    world.crt().seed(@truncate(seed));
    const b = if (world.battle) |*b| b else return out.print("{s}: not a battle level\n", .{level});
    b.auto_heroes = true;
    b.lenient_loss = true;
    b.log = out;
    for (b.fighters.items) |f| {
        const wpn = if (f.weapon) |o| o.name else "-";
        try out.print("{s:<12} {t:<5} tile {d},{d} size {d} hp {d} move {d} weapon {s}", .{
            f.obj.name, f.side, f.tile[0], f.tile[1], f.size, f.hp(), og.fields.walkRange(f.obj), wpn,
        });
        if (f.appear_to) |t| try out.print(" → enters at {d},{d}", .{ t[0], t[1] });
        try out.writeByte('\n');
    }
    var ticks: u32 = 0;
    while (b.phase != .won and b.phase != .lost and b.turn <= turns and ticks < 200_000) : (ticks += 1) {
        try og.game.tick(world);
        if (log_sounds) {
            for (world.out.sound_events.items) |se| try out.print("  [{d}] sound {s}\n", .{ ticks, se.name });
            world.out.sound_events.clearRetainingCapacity();
        }
    }
    try out.print("result: {t} on turn {d} ({d} ticks)\n", .{ b.phase, b.turn, ticks });
    for (b.fighters.items) |f| {
        const sp = world.screenPos(f.obj);
        try out.print("  {s:<12} hp {d}{s}  tile {d},{d}  bg {d:.0},{d:.0}\n", .{ f.obj.name, f.hp(), if (f.dead) " (dead)" else "", f.tile[0], f.tile[1], sp[0], sp[1] });
        if (f.side == .hero) {
            try out.print("      exp {d}, level {d}, points {d}\n", .{ og.fields.experience(f.obj), f.obj.getInt("level"), og.state.world.World.nativeOf(f.obj).growth.stat_points });
            var list: [16]*og.script.object.Object = undefined;
            for (og.combat.weapons.weaponsOf(world, f, &list)) |wpn| {
                if (og.combat.weapons.ammoLeft(world, f, wpn)) |n| try out.print("      {s}: ammo {d}\n", .{ wpn.name, n });
            }
        }
    }
}

//! Integration tests of combat: turn phases, states and bombs on a bare battle with
//! runtime objects, and generic fighters loaded from scripts.

const std = @import("std");
const battle_dir = @import("../battle.zig");
const generic = battle_dir.generic;
const combat = @import("../combat.zig");
const turns = combat.turns;
const states = combat.states;
const World = @import("../state.zig").world.World;
const fixture = @import("fixture.zig");
const TestBattle = fixture.TestBattle;
const Runtime = @import("../script.zig").runtime.Runtime;

test "checkEnd: any hero's death is a defeat (0x490620), before victory" {
    var t: TestBattle = .init();
    defer t.deinit();
    try t.b.fighters.ensureTotalCapacity(std.testing.allocator, 4);
    _ = try t.add(.hero, true);
    _ = try t.add(.hero, false);
    const e = try t.add(.enemy, false);
    try std.testing.expect(turns.checkEnd(&t.b));
    try std.testing.expectEqual(.lost, t.b.phase);
    // Playthrough mode: only the whole party; one live hero doesn't end the battle.
    t.b.phase = .player;
    t.b.lenient_loss = true;
    try std.testing.expect(!turns.checkEnd(&t.b));
    // Enemies dead but a hero died too: defeat, not victory.
    e.dead = true;
    t.b.lenient_loss = false;
    try std.testing.expect(turns.checkEnd(&t.b));
    try std.testing.expectEqual(.lost, t.b.phase);
    t.b.fighters.items[0].dead = false;
    t.b.phase = .player;
    try std.testing.expect(turns.checkEnd(&t.b));
    try std.testing.expectEqual(.won, t.b.phase);
}

test "applyEffect: one turn longer on the enemy turn, soaked burning gets 3 again (0x4900f0)" {
    var t: TestBattle = .init();
    defer t.deinit();
    const f = try t.add(.enemy, false);
    var w: World = undefined; // only the immunity table is read
    var known: battle_dir.immunity.Known = .{};
    w.immunity = &known;
    states.applyEffect(&t.b, &w, f, .burn);
    try std.testing.expectEqual(3, f.burning);
    states.applyEffect(&t.b, &w, f, .freeze);
    try std.testing.expectEqual([2]i32{ 0, 2 }, [2]i32{ f.burning, f.frozen });
    t.b.enemy_period = true;
    states.applyEffect(&t.b, &w, f, .gas);
    states.applyEffect(&t.b, &w, f, .burn);
    try std.testing.expectEqual([3]i32{ 4, 4, 0 }, [3]i32{ f.gassed, f.burning, f.frozen });
    states.applyEffect(&t.b, &w, f, .soak);
    try std.testing.expectEqual([2]i32{ 3, 0 }, [2]i32{ f.burning, f.soaked });
    f.burning = 0;
    states.applyEffect(&t.b, &w, f, .soak);
    try std.testing.expectEqual(4, f.soaked);
}

test "sideTurnEnd: side counters −1 down to zero, others and the dead untouched (0x4903d0)" {
    var t: TestBattle = .init();
    defer t.deinit();
    try t.b.fighters.ensureTotalCapacity(std.testing.allocator, 4);
    const f = try t.add(.enemy, false);
    f.burning = 3;
    f.gassed = 1;
    f.frozen = 2;
    f.asleep = 2;
    const h = try t.add(.hero, false);
    h.burning = 3;
    const d = try t.add(.enemy, true);
    d.gassed = 2;
    var w: World = undefined; // sleep doesn't end: stance not restored
    var known: battle_dir.immunity.Known = .{};
    w.immunity = &known;
    turns.sideTurnEnd(&t.b, &w, .enemy);
    try std.testing.expectEqual([5]i32{ 2, 0, 1, 0, 1 }, [5]i32{ f.burning, f.gassed, f.frozen, f.soaked, f.asleep });
    try std.testing.expectEqual(3, h.burning);
    try std.testing.expectEqual(2, d.gassed);
}

const TestFiles = struct {
    files: []const [2][]const u8,
    fn fetch(ctx: *anyopaque, name: []const u8) anyerror!?[]const u8 {
        const self: *TestFiles = @ptrCast(@alignCast(ctx));
        for (self.files) |f| if (std.ascii.eqlIgnoreCase(f[0], name)) return f[1];
        return null;
    }
};

test "generic fighter: attack, effects, AI and resistances from fields" {
    var files: TestFiles = .{ .files = &.{
        .{
            "drone.ftr",
            \\int classType; int nameID; string ai; string resist; int armor_class;
            \\function init() { classType = 100; nameID = 2001; ai = "Focused"; resist = "fire gas"; armor_class = 1; };
        },
        .{
            "gun.wpn",
            \\int nameID; int longAttack; int attackEffectDelay; string attack_anim; string projectile; int hit_delay; int after_delay; int flash_delay;
            \\function init() { nameID = 2101; longAttack = 1; attack_anim = "atak"; projectile = "rocket"; hit_delay = 40; after_delay = 0; flash_delay = 12; };
        },
        .{
            "plain.wpn",
            \\int nameID; int longAttack; int attackEffectDelay;
            \\function init() { nameID = 67; longAttack = 0; attackEffectDelay = 0; };
        },
        .{
            "garcia.ftr",
            \\int classType; int nameID;
            \\function init() { classType = 1; nameID = 101; };
        },
    } };
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = &files, .fetch = TestFiles.fetch });
    defer rt.deinit();
    const drone = try rt.createObject("drone", try rt.loadClass("drone.ftr"));
    _ = try rt.callIfExists(drone, "init", &.{});
    const gun = try rt.createObject("gun", try rt.loadClass("gun.wpn"));
    _ = try rt.callIfExists(gun, "init", &.{});
    const plain = try rt.createObject("plain", try rt.loadClass("plain.wpn"));
    _ = try rt.callIfExists(plain, "init", &.{});
    const garcia = try rt.createObject("garcia", try rt.loadClass("garcia.ftr"));
    _ = try rt.callIfExists(garcia, "init", &.{});

    try std.testing.expect(generic.is(drone) and !generic.is(garcia));
    const a = generic.attack(gun);
    try std.testing.expectEqualStrings("atak", a.anim);
    try std.testing.expectEqual(@as(u32, 40), a.wait);
    try std.testing.expectEqual(@as(u32, 0), a.after); // after_delay = 0 set explicitly
    try std.testing.expectEqual(@as(?u32, 12), a.pre);
    try std.testing.expectEqual(@as(i32, 1024), generic.fxId(gun));
    // No fields: ordinary monster defaults, effects by own nameID.
    const d = generic.attack(plain);
    try std.testing.expectEqualStrings("short_attack", d.anim);
    try std.testing.expectEqual(@as(u32, 15), d.wait);
    try std.testing.expectEqual(@as(u32, 30), d.after);
    try std.testing.expectEqual(@as(i32, 67), generic.fxId(plain));
    try std.testing.expectEqual(.focused, generic.aiOf(drone));

    var k: battle_dir.immunity.Known = .{};
    generic.registerFighter(&k, drone);
    generic.registerFighter(&k, garcia); // game fighter: the exe table is unchanged
    try std.testing.expect(k.immune(2001, .fire) and k.immune(2001, .gas) and !k.immune(2001, .electricity));
    try std.testing.expectEqual(@as(?i32, 0), k.armorClass(2001));
    try std.testing.expectEqual(@as(usize, 1), k.n);
}

test "decoy and bombs occupy their tile: a ray stops there and the tile is an aim (0x4ce575)" {
    var t = TestBattle.init();
    defer t.deinit();
    var occ: [8]u16 = @splat(battle_dir.grid.Grid.none);
    var blk: [8]bool = @splat(false);
    t.b.occupant = &occ;
    t.b.blocked = &blk;
    t.b.width = 8;
    t.b.height = 1;
    _ = try t.add(.hero, false);
    t.b.grid().place(.{ 0, 0 }, 1, 0);
    const decoy = try t.rt.createObject("decoy", &t.cls);
    const fi = try combat.devices.addDevice(&t.b, decoy, .{ 3, 0 });
    try std.testing.expectEqual(.neutral, t.b.fighters.items[fi].side);
    var buf: [64]battle_dir.grid.Target = undefined;
    const aims = battle_dir.grid.targets(t.b.grid(), battle_dir.patterns.find(1).?, .{ 0, 0 }, 0, true, false, &buf);
    var last: i32 = 0;
    for (aims) |a| last = @max(last, a.tile[0]);
    try std.testing.expectEqual(3, last);
}

test "decoy list is rebuilt on the enemy turn: dead decoys drop out, row-major order (0x495170)" {
    var t = TestBattle.init();
    defer t.deinit();
    defer t.b.decoys.deinit(std.testing.allocator);
    const a = try t.add(.neutral, false);
    a.tile = .{ 5, 2 };
    _ = try t.add(.neutral, true);
    const c = try t.add(.neutral, false);
    c.tile = .{ 1, 1 };
    for (0..3) |i| try t.b.decoys.append(std.testing.allocator, .{ .obj = t.b.fighters.items[i].obj, .tile = t.b.fighters.items[i].tile, .fighter = @intCast(i) });
    combat.devices.refreshDecoys(&t.b);
    try std.testing.expectEqual(@as(usize, 2), t.b.decoys.items.len);
    try std.testing.expectEqual([2]i32{ 1, 1 }, t.b.decoys.items[0].tile);
    try std.testing.expectEqual([2]i32{ 5, 2 }, t.b.decoys.items[1].tile);
}

test "turn reset: an asleep or frozen fighter loses the turn at once (0x48f6f0)" {
    var t: TestBattle = .init();
    defer t.deinit();
    try t.b.fighters.ensureTotalCapacity(std.testing.allocator, 2);
    const awake = try t.add(.hero, false);
    const asleep = try t.add(.hero, false);
    asleep.asleep = 2;
    awake.acted = true;
    turns.resetTurn(awake);
    turns.resetTurn(asleep);
    try std.testing.expect(!awake.acted);
    try std.testing.expect(asleep.acted);
    asleep.asleep = 0;
    asleep.frozen = 1;
    turns.resetTurn(asleep);
    try std.testing.expect(asleep.acted);
}

//! A fighter in the world: tile ↔ point, snapping to a tile, grid turns, strike
//! animations and links (Schizo, Puppet), restoring the held pose.

const std = @import("std");
const fields = @import("../fields.zig");
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const Object = @import("../script.zig").object.Object;
const generic = @import("../battle.zig").generic;
const inventory = @import("../inventory.zig");
const attacks = @import("../battle.zig").attacks;
const Tile = @import("../battle.zig").grid.Tile;
const Fighter = @import("../battle.zig").fighter.Fighter;
const weapons = @import("weapons.zig");

/// Put the model exactly at the tile centre.
pub fn snap(w: *World, f: Fighter) void {
    const cm = w.combat_map orelse return;
    fields.setPos(f.obj, cm.tileCenter(f.tile, f.size));
}

pub fn walkStraight(w: *World, f: *Fighter, to: Tile) void {
    const cm = w.combat_map orelse return;
    fields.setPos(f.obj, cm.tileCenter(f.tile, f.size));
    const a = world_mod.actorOf(f.obj);
    a.placed = true;
    a.clearPath();
    const p = cm.tileCenter(to, f.size);
    a.path.append(w.gpa, .{ p[0], p[1] }) catch return;
    a.move_speed = a.speedOf("walk") * w.speedScale();
    a.play(a.resolve("walk"), true, false);
}

/// Angle to the opponent (0x48f02e…0x48f0d1): from grid axis `rot`, a = atan2 +
/// 2π − rot; a remainder mod π/2 above π/4 goes to the next multiple, else down;
/// mod 2π, plus `rot`. In the exe's precision: `raw` from x87 fpatan (here f64), `a`
/// stored as a float (0x48f06b), fmod and the π/4 test in double. A placement on an
/// exact diagonal lands on π/4 and only that rounding decides the quarter (all-f32
/// math turned 04__city_trapatthetruck's needle3 sideways).
pub fn snapAngle(raw: f64, rot: f32) f32 {
    const pi = std.math.pi;
    const step = pi * 0.5;
    const a: f32 = @floatCast(raw + 2 * pi - @as(f64, rot));
    // `a` > 0, so @mod is fmod (0x4f741a).
    const r = @mod(@as(f64, a), step);
    const s: f32 = @floatCast(if (r > pi * 0.25) (step - r) + a else a - r);
    return @floatCast(@mod(@as(f64, s), 2 * pi) + @as(f64, rot));
}

test "snapAngle: a placement on the exact diagonal rounds as the exe does" {
    // 04__city_trapatthetruck: needle3 (2×2 at 0,13) and Trantigne at 5,18 — (5, 5) tiles apart.
    const lf = @import("../formats.zig").level_files;
    const cm: lf.CombatMap = .{ .center = .{ 3323.302979, -7874.714844, -365 }, .rotation = 0.02, .cell_size = .{ 387.5, 387.5 }, .width = 8, .height = 24, .blocked = &.{}, .heights = &.{} };
    const me = cm.toWorld(1, 14);
    const to = cm.toWorld(5.5, 18.5);
    const raw = std.math.atan2(@as(f64, to[1]) - me[1], @as(f64, to[0]) - me[0]);
    try std.testing.expectApproxEqAbs(@as(f32, std.math.pi / 2.0 + 0.02), snapAngle(raw, 0.02), 1e-5);
}

test "snapAngle rounds to the grid's quarter turns" {
    const pi = std.math.pi;
    try std.testing.expectApproxEqAbs(@as(f32, pi / 2.0), snapAngle(pi / 2.0 - 0.3, 0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), snapAngle(0.7, 0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, pi / 2.0), snapAngle(0.8, 0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 3 * pi / 2.0), snapAngle(-pi / 2.0 + 0.1, 0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), snapAngle(0.3, 0.2), 1e-5);
}

/// Smooth turn to a tile (command 0x12, 0x425150: rotSpeed per tick).
pub fn face(w: *World, f: Fighter, t: Tile) void {
    const cm = w.combat_map orelse return;
    const from = cm.tileCenter(f.tile, f.size);
    const to = cm.tileCenter(t, 1);
    world_mod.actorOf(f.obj).turnTo(f.obj, fields.facing(to[0] - from[0], to[1] - from[1]));
}

/// Instant turn (item box: the item action happens right away, as outside battle).
pub fn faceNow(w: *World, f: Fighter, t: Tile) void {
    const cm = w.combat_map orelse return;
    const from = cm.tileCenter(f.tile, f.size);
    const to = cm.tileCenter(t, 1);
    fields.setAngle(f.obj, fields.facing(to[0] - from[0], to[1] - from[1]));
}

/// Strike animation starts after turning to the target (attack queue 0x4896b0:
/// 0x12, then the animation).
pub fn beginAttackAnim(w: *World, f: Fighter, wpn: *Object) void {
    const a = world_mod.actorOf(f.obj);
    // An invisible monster (0x48a2a6) appears before the strike.
    if (a.invisible) a.materialize(true);
    const anim = attackAnim(f, wpn);
    // Smoke Rider with weapon 1004 (0x489ec2): it plays ladder_start, and callback 21
    // (0x487698) after attack_smokerider_shot2_delay makes its second linked actor
    // (+0x3534, LinkActor 0x4c1c50 → 0x42ab60: the gunner smoke_pilot_2) play
    // long_attack if more than one is linked (+0x30d4 > 1).
    // shortcut: played at the start, as the shipped shot2_delay is 0; schedule it if a mod sets more.
    if (fields.nameId(f.obj) == 110 and fields.nameId(wpn) == 1004) {
        var linked: u32 = 0;
        for (w.rt.objects.items) |o| {
            const n = World.nativeOf(o);
            if (n.kind != .actor or n.actor.attached_to != f.obj) continue;
            linked += 1;
            if (linked == 2) n.actor.play(n.actor.resolve("long_attack"), false, true);
        }
    }
    a.play(a.resolve(anim), false, true);
    // Queued as async command 0x14 (0x428980): the strike's waits and "attack over"
    // (0x425630) run alongside it, nothing waits for its last frame.
    a.async_anim = true;
    // Dartgun (0x48c1cb): 0x428980("attack_gun", 0, 1, 1); the 4th argument mutes
    // frame sounds (0x4230c0 → 0x44f910 → [anim+0x30]); instead of the pistol shot,
    // dartsgun.wav plays at the shot (callback 0x27).
    if (f.side == .hero and fields.nameId(wpn) == 45) a.mute_cues = true;
    // `play` blends into the strike: 10 ticks on the first frame (0x44f910, length 8);
    // strike delays (adjust.kdt) count from the start including this blend.
}

/// Blend ticks into a strike animation: length 8 → +0x1c from −1/9 in steps of 1/9 to 1.
const attack_blend_ticks = @import("../actor.zig").Actor.blend_ticks;

/// Strike animation frame (from its first) shown when the hit and its muzzle flash come
/// `wait` ticks after the start: the hit fires on tick wait + 1 (stepPending runs before
/// the actors' frame step), the frame moves once a tick (0x4266da → 0x44fae0, `.ani`
/// speed unused) after the blend.
pub fn hitFrame(wait: u32) u32 {
    return (wait + 1) -| attack_blend_ticks;
}

/// Logical attack animation name: heroes by weapon nameID (0x48bda2), monsters
/// by their own branch (0x48d618).
fn attackAnim(f: Fighter, wpn: *Object) []const u8 {
    if (generic.is(f.obj)) return generic.attack(wpn).anim;
    if (attacks.heroTable(fields.nameId(f.obj))) return attacks.heroAttack(fields.nameId(f.obj), fields.nameId(wpn)).anim;
    return attacks.monsterAttack(fields.nameId(f.obj), fields.nameId(wpn)).anim;
}

/// Schizo's weapon pair by counter (if he has exactly 1077, 1078, 1079).
pub fn schizoPair(w: *World, f: Fighter) ?[2]*Object {
    var list: [16]*Object = undefined;
    const ws = weapons.weaponsOf(w, f, &list);
    var by: [3]?*Object = .{ null, null, null };
    for (ws) |o| switch (fields.nameId(o)) {
        1077 => by[0] = o,
        1078 => by[1] = o,
        1079 => by[2] = o,
        else => {},
    };
    const a = by[0] orelse return null;
    const b = by[1] orelse return null;
    const c = by[2] orelse return null;
    return switch (f.schizo_turn) {
        0 => .{ a, b },
        1 => .{ a, c },
        2 => .{ b, c },
        else => null,
    };
}

/// One-shot animation of the mesh on a link point (0x48d760: 0x48d7b0 finds the
/// mesh by the point name, 0x44f910 plays it); the saw's "obrot" is the only use.
pub fn spinLink(w: *World, o: *Object, link: []const u8) void {
    for (world_mod.actorOf(o).links.items) |*l| if (std.ascii.eqlIgnoreCase(l.link, link)) {
        l.blend = l.anim.len == 0;
        l.anim = "obrot";
        l.anim_from = w.ticks;
    };
}

/// Stance after defending or sleeping (0x42b300): 0, or 1 for a hero with a two-handed weapon.
pub fn restoreHold(w: *World, f: Fighter) void {
    world_mod.actorOf(f.obj).setState(0, true);
    inventory.equipment.refreshHold(w, f.obj);
}

test "strike hit frame: Fatman's sound frame 58 meets the hit on tick 68" {
    try @import("std").testing.expectEqual(@as(u32, 58), hitFrame(67));
    try @import("std").testing.expectEqual(@as(u32, 31), hitFrame(40)); // pistol, attack_dartgun_delay
}

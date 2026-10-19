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
/// mod 2π, plus `rot`.
pub fn snapAngle(raw: f32, rot: f32) f32 {
    const pi = std.math.pi;
    const step = pi * 0.5;
    var a = raw + 2 * pi - rot;
    const r = @mod(a, step);
    a = if (r > pi * 0.25) a - r + step else a - r;
    return @mod(a, 2 * pi) + rot;
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
    var anim = attackAnim(f, wpn);
    // Smoke Rider with weapon 1004 (0x489ec2, callback 21 = 0x487698): long_attack
    // right after ladder_start if at least two actors are linked to it (+0x30d4 > 1:
    // pilots, LinkActor 0x4c1c50 → 0x42ab60); otherwise ladder_start.
    if (fields.nameId(f.obj) == 110 and fields.nameId(wpn) == 1004) {
        var linked: u32 = 0;
        for (w.rt.objects.items) |o| {
            const n = World.nativeOf(o);
            if (n.kind == .actor and n.actor.attached_to == f.obj) linked += 1;
        }
        if (linked < 2) anim = "ladder_start";
    }
    a.play(a.resolve(anim), false, true);
    // Queued as async command 0x14 (0x428980): the strike's waits and "attack over"
    // (0x425630) run alongside it, nothing waits for its last frame.
    a.async_anim = true;
    // Dartgun (0x48c1cb): 0x428980("attack_gun", 0, 1, 1); the 4th argument mutes
    // frame sounds (0x4230c0 → 0x44f910 → [anim+0x30]); instead of the pistol shot,
    // dartsgun.wav plays at the shot (callback 0x27).
    if (f.side == .hero and fields.nameId(wpn) == 45) a.mute_cues = true;
    // Blend into the strike animation: 10 ticks on the first frame (0x44f910, length
    // 8); strike delays (adjust.kdt) count from the start including this blend.
    a.anim_hold = attack_blend_ticks;
}

/// Blend ticks into a strike animation: length 8 → +0x1c from −1/9 in steps of 1/9 to 1.
const attack_blend_ticks = 10;

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
        l.anim = "obrot";
        l.anim_from = w.ticks;
    };
}

/// Stance after defending or sleeping (0x42b300): 0, or 1 for a hero with a two-handed weapon.
pub fn restoreHold(w: *World, f: Fighter) void {
    world_mod.actorOf(f.obj).setState(0, true);
    inventory.equipment.refreshHold(w, f.obj);
}

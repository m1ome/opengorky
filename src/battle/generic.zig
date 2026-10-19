//! Generic fighter (`classType = 100` in `.ftr`; no such class in the exe) for
//! custom fighters. Everything the exe hard-codes by nameID and
//! class (attack branches 0x4896b0, move scoring +0xe0, resistance table
//! 0x6d2070) comes from the fighter's and weapon's script fields here. Game
//! fighters don't use this code and behave as in the exe.

const std = @import("std");
const fields = @import("../fields.zig");
const Object = @import("../script.zig").object.Object;
const attacks = @import("attacks.zig");
const Class = @import("fighter.zig").Class;
const immunity = @import("immunity.zig");

pub fn is(o: *Object) bool {
    return Class.of(o) == .generic;
}

/// Generic fighter's strike from weapon fields:
/// - `attack_anim`: logical animation (default long_attack / short_attack by
///   `longAttack`);
/// - `hit_delay`: ticks until the hit (default `attackEffectDelay`, else 15);
/// - `after_delay`: wait after the hit until the attack ends (default 30, like the
///   common tail 0x48b864);
/// - `second_delay`: second projectile that many ticks later (0 = none);
/// - `react_delay`: repeat the target's reaction without damage after that many ticks (0 = none);
/// - `flash_delay`: muzzle flash before the hit at that tick (0 = none).
pub fn attack(wpn: *Object) attacks.MonsterAttack {
    const anim_field = wpn.getString("attack_anim");
    const anim = if (anim_field.len > 0) anim_field else if (wpn.getInt("longAttack") != 0) "long_attack" else "short_attack";
    const hit = wpn.getInt("hit_delay");
    const eff = wpn.getInt("attackEffectDelay");
    const wait: i32 = if (hit > 0) hit else if (eff > 0) eff else 15;
    const after: i32 = if (wpn.getVar("after_delay")) |v| v.value.toInt() else 30;
    const flash = wpn.getInt("flash_delay");
    return .{
        .anim = anim,
        .wait = @intCast(wait),
        .after = @intCast(@max(0, after)),
        .second = @intCast(@max(0, wpn.getInt("second_delay"))),
        .react = @intCast(@max(0, wpn.getInt("react_delay"))),
        .pre = if (flash > 0) @intCast(flash) else null,
    };
}

/// Whose effects the weapon uses (projectile, flash, hit trail; src/fx.zig picks
/// them by weapon nameID): `fx_as` is a game weapon's nameID, `projectile` a
/// projectile name; otherwise its own nameID (game weapons lack these fields).
pub fn fxId(wpn: *Object) i32 {
    const as = wpn.getInt("fx_as");
    if (as > 0) return as;
    const p = wpn.getString("projectile");
    if (p.len > 0) if (projectileId(p)) |id| return id;
    return fields.nameId(wpn);
}

/// Projectile name → nameID of the game weapon with that projectile.
fn projectileId(name: []const u8) ?i32 {
    const names = [_]struct { []const u8, i32 }{
        .{ "rocket", 1024 }, .{ "grenade", 35 }, .{ "stun_grenade", 33 }, .{ "gas_grenade", 1027 },
        .{ "molotov", 86 },  .{ "knife", 40 },   .{ "stone", 41 },        .{ "napalm", 1028 },
        .{ "bullet", 89 },   .{ "ball", 1072 },  .{ "small_ball", 1070 },
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(name, n[0])) return n[1];
    return null;
}

/// Register the fighter's resistances and armour (`resist`, `armor_class`) by
/// its nameID on battle entry.
pub fn registerFighter(k: *immunity.Known, o: *Object) void {
    if (!is(o)) return;
    k.register(fields.nameId(o), o.getString("resist"), o.getInt("armor_class"));
}

/// AI strategy from the `ai` field:
/// - `standard`: an ordinary exe monster (default scoring: damage to the enemy,
///   tile threat, distance; attracted by decoys);
/// - `focused`: "scoring A" of special fighters (0x4dcb40): damage only, no decoys;
/// - `sleep_hunter`: like the Guard (0x4e2260): melee (`secondaryWeapon`) only on
///   sleepers, the other weapon on those awake;
/// - `stationary`: never walks (like `moveLock`), strikes from its tile.
const Ai = enum { standard, focused, sleep_hunter, stationary };

pub fn aiOf(o: *Object) Ai {
    const v = o.getString("ai");
    var buf: [32]u8 = undefined;
    if (v.len > buf.len) return .standard;
    return std.meta.stringToEnum(Ai, std.ascii.lowerString(&buf, v)) orelse .standard;
}

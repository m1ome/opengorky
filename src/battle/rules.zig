//! Turn-based battle rules recovered from gorky17.exe: hit, damage, armour,
//! recharge, exp. Pure functions without the world or scripts; grid, walking and
//! aiming are in `grid.zig`.

const std = @import("std");
const value = @import("../script.zig").value;
const num = @import("../num.zig");
const Rand = @import("../crt_rand.zig").Rand;
const WeaponClass = @import("weapon_class.zig").WeaponClass;

/// Hit chance in percent (0x4cedc2): shooter accuracy plus a tenth of the miss
/// for each tile of the target's size; halved in rage.
pub fn hitChance(accuracy: f32, target_size: i32, berserk: bool) i32 {
    const v = accuracy + (100 - accuracy) * num.toF32(target_size) * 0.1;
    var c = value.floatToInt(v);
    if (berserk) c = value.scaleInt(c, 0.5);
    return c;
}

/// Only firearms roll to hit (weapon method +0xc4: 1 for subclasses 1, 2, 3, 12,
/// 14, 126, 127); everything else always hits.
pub fn rollsToHit(class: i32) bool {
    return switch (WeaponClass.from(class)) {
        .pistol, .rifle, .dartgun, .knife_throwing, .shotgun, .ally_pistol, .ally_rifle => true,
        else => false,
    };
}

/// Fighter state applied by 0x4900f0 (the number is the call argument).
pub const Effect = enum(u8) {
    burn = 1,
    freeze = 2,
    gas = 3,
    /// Soaked with fuel (if burning, 3 more turns of fire).
    soak = 4,
    defend = 5,
    sleep = 6,
    /// Invisible's poison in 04__city_mfd (+0x248e8), incurable.
    bite = 8,
};

/// State a weapon class applies to a live target on hit (subclass methods +0xf0 →
/// 0x4900f0).
pub fn weaponEffect(class: i32) ?Effect {
    return switch (WeaponClass.from(class)) {
        // Flamethrower (0x4b76a0): always ignites; damage only if the fire took.
        // Molotov (+0xdc 0x4bb6e0) and napalm launcher (0x4b8120) ignite any hit target
        // by the strike flag (6th argument of +0xf0, 1 for hits and projectiles,
        // 0x49b93e), not by soaking; matches (21) only a soaked one.
        .flame_thrower, .molotov, .napalm => .burn,
        .dartgun, .shocker, .stun_bomb, .needle, .medusa_short, .stinger_long, .guard2, .schizo1 => .sleep,
        .nitrogen, .reverend_insect => .freeze,
        .bottle, .hornet => .soak,
        .gas_grenade, .invisible => .gas,
        .invisible_mfd => .bite,
        else => null,
    };
}

/// Recharge turns after a shot (+0xc8 of subclasses: 0x4b7640 flamethrower 3,
/// 0x4b8490 ion rifle 4, 0x4b89e0 blaster 3, 0x4b9ca0 shocker 4, 0x4bbc50
/// nitrogen gun 3); 0 = no recharge. Firing is allowed at counter ≤ 0 (+0xcc).
pub fn rechargeTurns(class: i32) i32 {
    return switch (WeaponClass.from(class)) {
        .flame_thrower, .blaster, .nitrogen => 3,
        // Medusa's short strike (wp_medusashort, class 123: +0xc8 0x4d6570, check
        // 0x4d6560) has 4 turns; the long one (124) has none (base methods).
        .ion_rifle, .shocker, .medusa_short => 4,
        else => 0,
    };
}

/// Enemy turn start (0x49843e…0x49845a): every weapon's +0xc0 decrements the
/// counter if above zero (0x4b7680 etc.). Once per round, heroes and monsters alike.
pub fn rechargeTick(left: i32) i32 {
    return if (left > 0) left - 1 else left;
}

/// Weapon that ignites a fuel-soaked target (clears "soaked" and applies fire).
pub fn ignitesSoaked(class: i32) bool {
    return switch (WeaponClass.from(class)) {
        .pistol, .rifle, .flame_thrower, .rocket_launcher, .time_bomb, .grenade, .chaingun, .shotgun, .molotov, .napalm, .barrel, .matches, .garcia_long, .headnail, .ally_pistol, .ally_rifle => true,
        else => false,
    };
}

/// Exp threshold per level (table 0x528c3c, 0x48f9c0): the level grows while exp
/// exceeds the current level's threshold.
pub fn levelThreshold(level: i32) i32 {
    const t = [20]i32{ 0, 220, 450, 705, 1010, 1385, 1910, 2720, 4260, 8745, 17490, 34980, 69960, 139920, 279840, 559680, 1119360, 2238720, 4477440, 8954880 };
    return if (level < 0 or level > 19) 0 else t[@intCast(level)];
}

/// Miss: `rand() % 101 > chance`.
fn rollMiss(r: *Rand, chance: i32) bool {
    return @rem(r.next(), 101) > chance;
}

/// Weapon skill in percent (0x48fe10 ← 0x48fdb0): hero level from the skill list
/// (no entry = 1), non-heroes 10; level ≤ 0 gives 100, else level × 10.
pub fn skillPercent(level: ?i32, hero: bool) i32 {
    const lv: i32 = if (!hero) 10 else level orelse 1;
    return if (lv > 0) lv * 10 else 100;
}

/// Skill damage factor (0x4ceeee): k = clamp(skill/100 ± (roll/100)^8, 0, 1),
/// damage = value.floatToInt((k + 1) · base · 0.5); `roll` = rand % 101, `negative` = rand odd.
fn skillDamage(base: i32, skill: i32, roll: i32, negative: bool) i32 {
    const s = std.math.clamp(skill, 0, 100);
    var noise = std.math.pow(f64, @floatFromInt(roll), 8) / std.math.pow(f64, 100, 8);
    if (negative) noise = -noise;
    const k = std.math.clamp(noise + @as(f64, @floatFromInt(s)) * 0.01, 0, 1);
    return value.floatToInt(@as(f32, @floatCast((k + 1) * @as(f64, @floatFromInt(base)) * 0.5)));
}

/// Weapon damage on a tile with range percent `pct` (0x4cee66): `pct × max_damage
/// / 100`, then by skill: `(1 + clamp(skill/100 ± (r/100)^8, 0, 1)) / 2`.
/// Skill is level × 10 (0x48fe10), 100 without a skill (monsters). `null` = no
/// adjustment (no shooter, bomb `classType` 9, 18).
fn damage(r: *Rand, max_damage: i32, pct: i32, skill: ?i32) i32 {
    const base = @divTrunc(pct * max_damage, 100);
    const s = skill orelse return base;
    const roll = @rem(r.next(), 101);
    const negative = @rem(r.next(), 2) != 0;
    return skillDamage(base, s, roll, negative);
}

/// Strike result (0x4ced30): miss (+0x1a94), damage (+0x1a9c), luck (+0x1a98).
pub const Strike = struct { missed: bool = false, dmg: i32 = 0, crit: bool = false, chance: i32 = 100, rage: bool = false };

const StrikeParams = struct {
    /// There is a shooter (not a bomb blast 0x4ce1f4 and not a class 9 bomb).
    shooter: bool,
    /// Weapon +0xc4 (roll to hit).
    rolls_to_hit: bool,
    chance: i32,
    /// Miss without a roll (Messiah outside tile (10,18), 0x4cee33).
    blocked: bool = false,
    /// Skill; null = none (decoy 18).
    skill: ?i32,
    max_damage: i32,
    pct: i32,
    /// Hero luck (+0x64 of the shooter); null = not a hero, no rolls.
    luck: ?i32,
    /// Rage (+0x248fc > 0): damage ×2 (0x4cf0d7).
    rage: bool,
};

/// Strike roll in exe order (0x4ced30) with the same RNG use: hit roll
/// (rand % 101 > chance = miss, 0x4cee08), Messiah; damage pct·max/100 (0x4cee66);
/// on a hit with a shooter and skill, skill damage (rand % 101, rand & 1, 0x4ceeee);
/// damage > 3 for a hero, two luck rolls (rand % 101 < luck, 0x4cefab…0x4cf00f):
/// ×1.2 (0x4cf015); rage ×2 (0x4cf0d7). No damage roll on a miss.
pub fn strike(r: *Rand, p: StrikeParams) Strike {
    var st: Strike = .{ .dmg = @divTrunc(p.pct * p.max_damage, 100), .chance = p.chance, .rage = p.rage };
    if (p.shooter and p.rolls_to_hit) st.missed = rollMiss(r, p.chance);
    if (p.blocked) st.missed = true;
    if (st.missed or !p.shooter) return st;
    const s = p.skill orelse return st;
    st.dmg = damage(r, p.max_damage, p.pct, s);
    if (st.dmg > 3) if (p.luck) |l| {
        if (@rem(r.next(), 101) < l and @rem(r.next(), 101) < l) {
            st.crit = true;
            st.dmg = value.scaleInt(st.dmg, 1.2);
        }
    };
    if (p.rage) st.dmg *= 2;
    return st;
}

test "strike: rand order — hit roll, skill roll and sign, then two luck rolls" {
    const params: StrikeParams = .{ .shooter = true, .rolls_to_hit = true, .chance = 100, .skill = 100, .max_damage = 50, .pct = 100, .luck = 100, .rage = false };
    var a: Rand = .{ .state = 7 };
    const st = strike(&a, params);
    var b: Rand = .{ .state = 7 };
    const r = &b;
    const miss = rollMiss(r, 100);
    const d = damage(r, 50, 100, 100);
    const l1 = @rem(r.next(), 101) < 100;
    const l2 = @rem(r.next(), 101) < 100;
    try std.testing.expectEqual(miss, st.missed);
    try std.testing.expect(l1 and l2 and st.crit);
    try std.testing.expectEqual(value.scaleInt(d, 1.2), st.dmg);
    // The same RNG continues identically: the strike roll used exactly 5 numbers.
    try std.testing.expectEqual(a.next(), r.next());
}

test "strike: miss spends only the hit roll, no damage or luck rolls" {
    var a: Rand = .{ .state = 3 };
    const st = strike(&a, .{ .shooter = true, .rolls_to_hit = true, .chance = -1, .skill = 100, .max_damage = 50, .pct = 100, .luck = 100, .rage = true });
    try std.testing.expect(st.missed and !st.crit);
    var b: Rand = .{ .state = 3 };
    _ = b.next();
    try std.testing.expectEqual(a.next(), b.next());
}

test "strike: no luck rolls when damage after skill is 3 or less, monsters never roll luck" {
    var a: Rand = .{ .state = 11 };
    const st = strike(&a, .{ .shooter = true, .rolls_to_hit = false, .chance = 100, .skill = 100, .max_damage = 3, .pct = 100, .luck = 100, .rage = false });
    try std.testing.expect(!st.crit and st.dmg <= 3);
    var b: Rand = .{ .state = 11 };
    _ = damage(&b, 3, 100, 100);
    try std.testing.expectEqual(a.next(), b.next());
}

/// Damage after the target's armour (0x49123e). Hero: armour is subtracted.
/// Monster: armour class picks the weapon's percent (`lightArmor` etc.), damage × (100 − percent) / 100.
pub fn afterArmor(dmg: i32, hero: bool, armor: i32, weapon_armor_pct: [3]i32) i32 {
    if (hero) return @max(0, dmg - armor);
    // Class 0–2 picks the percent; any other value means no reduction (0x4912dc).
    if (armor < 0 or armor > 2) return dmg;
    return @divTrunc((100 - weapon_armor_pct[@intCast(armor)]) * dmg, 100);
}

/// Side bonus (0x490f9e…0x491042): `want` is the angle from the target to the
/// attacker (atan2), `facing` the target's angle. |want − facing| mod 2π
/// (0x4f741a) reduced to the smaller arc; ≥ 0.7125π back +4, ≥ 0.2375π side +2.
pub fn sideBonus(want: f32, facing: f32) i32 {
    const two_pi = 2.0 * std.math.pi;
    const r = @mod(@abs(@as(f64, want) - @as(f64, facing)), two_pi);
    const delta = @min(r, two_pi - r);
    if (delta >= std.math.pi * 0.7125) return 4;
    if (delta >= std.math.pi * 0.2375) return 2;
    return 0;
}

test "sideBonus: front 0, side +2, back +4" {
    const pi = std.math.pi;
    try std.testing.expectEqual(@as(i32, 0), sideBonus(0, 0));
    try std.testing.expectEqual(@as(i32, 0), sideBonus(0.2 * pi, 0));
    try std.testing.expectEqual(@as(i32, 2), sideBonus(0.25 * pi, 0)); // front diagonal
    try std.testing.expectEqual(@as(i32, 2), sideBonus(0.5 * pi, 0));
    try std.testing.expectEqual(@as(i32, 2), sideBonus(-0.5 * pi, 0));
    try std.testing.expectEqual(@as(i32, 4), sideBonus(0.75 * pi, 0)); // back diagonal
    try std.testing.expectEqual(@as(i32, 4), sideBonus(pi, 0));
    // Across ±π: gaze 0.9π, attacker at −0.9π, difference 0.2π.
    try std.testing.expectEqual(@as(i32, 0), sideBonus(-0.9 * pi, 0.9 * pi));
}

test "hit and armour formulas" {
    try std.testing.expectEqual(91, hitChance(90, 1, false));
    try std.testing.expectEqual(45, hitChance(90, 1, true));
    try std.testing.expectEqual(88, hitChance(80, 4, false));
    try std.testing.expectEqual(5, afterArmor(15, true, 10, .{ 0, 0, 0 }));
    try std.testing.expectEqual(0, afterArmor(5, true, 10, .{ 0, 0, 0 }));
    try std.testing.expectEqual(12, afterArmor(15, false, 1, .{ 0, 15, 25 }));
}

test "damage: skill 100 gives almost full damage" {
    var prng: Rand = .{};
    for (0..50) |_| {
        const d = damage(&prng, 15, 100, 100);
        try std.testing.expect(d >= 7 and d <= 15);
        const low = damage(&prng, 15, 100, 0);
        try std.testing.expect(low >= 7 and low <= 15);
    }
    try std.testing.expectEqual(10, damage(&prng, 10, 100, null));
}

test "skill percent (0x48fe10)" {
    try std.testing.expectEqual(10, skillPercent(null, true)); // hero without an entry: level 1
    try std.testing.expectEqual(30, skillPercent(3, true));
    try std.testing.expectEqual(100, skillPercent(0, true));
    try std.testing.expectEqual(100, skillPercent(null, false)); // monster: level 10
}

test "skill damage (0x4ceeee)" {
    // base 20, skill 10%: k = 0.1 → (1.1)·20·0.5 = 11.
    try std.testing.expectEqual(11, skillDamage(20, 10, 0, false));
    // skill 100%: full damage; noise doesn't push past 1.
    try std.testing.expectEqual(20, skillDamage(20, 100, 100, false));
    // roll 100, minus: k = clamp(0.5 − 1) = 0 → half.
    try std.testing.expectEqual(10, skillDamage(20, 50, 100, true));
    // roll 90: 0.9^8 ≈ 0.43 → k = 0.53 → value.floatToInt(1.53·10) = 15.
    try std.testing.expectEqual(15, skillDamage(20, 10, 90, false));
}

test "hit chance (0x4cedc2)" {
    try std.testing.expectEqual(91, hitChance(90, 1, false));
    try std.testing.expectEqual(45, hitChance(90, 1, true));
    try std.testing.expectEqual(94, hitChance(90, 4, false));
}

test "level threshold (0x528c3c)" {
    try std.testing.expectEqual(220, levelThreshold(1));
    try std.testing.expectEqual(8954880, levelThreshold(19));
}

test "molotov and napalm set targets on fire" {
    try std.testing.expectEqual(@as(?Effect, .burn), weaponEffect(15));
    try std.testing.expectEqual(@as(?Effect, .burn), weaponEffect(16));
    try std.testing.expectEqual(@as(?Effect, .burn), weaponEffect(4));
    try std.testing.expectEqual(@as(?Effect, null), weaponEffect(21));
}

test "recharge: fired on turn T, ready again on T+N, panel N…1 (0x4cf778, 0x49844c)" {
    const cases = [_]struct { class: i32, n: i32 }{
        .{ .class = 4, .n = 3 }, // flamethrower 0x4b7640
        .{ .class = 6, .n = 4 }, // ion rifle 0x4b8490
        .{ .class = 7, .n = 3 }, // blaster 0x4b89e0
        .{ .class = 19, .n = 3 }, // nitrogen gun 0x4bbc50
        .{ .class = 24, .n = 4 }, // shocker 0x4b9ca0
        .{ .class = 123, .n = 4 }, // Medusa's short strike 0x4d6570
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.n, rechargeTurns(c.class));
        // Hero: fires on turn 1 (the strike sets full N), −1 at each enemy turn start.
        // Heroes' turn t: ready at counter ≤ 0 (+0xcc).
        var left = rechargeTurns(c.class);
        var turn: i32 = 1;
        try std.testing.expectEqual(c.n, left); // panel right after the shot
        while (true) {
            left = rechargeTick(left); // enemy turn after `turn`
            turn += 1;
            if (left <= 0) break;
            try std.testing.expectEqual(c.n + 1 - turn, left); // panel: N−1 … 1
        }
        try std.testing.expectEqual(1 + c.n, turn);
        // Monster: −1 at the enemy turn start, then a strike; ready again after N enemy turns.
        left = rechargeTurns(c.class);
        var enemy_turns: i32 = 0;
        while (left > 0) : (enemy_turns += 1) left = rechargeTick(left);
        try std.testing.expectEqual(c.n, enemy_turns);
    }
    try std.testing.expectEqual(0, rechargeTick(0));
}

test "medusa short attack recharges, long does not" {
    try std.testing.expectEqual(4, rechargeTurns(123));
    try std.testing.expectEqual(0, rechargeTurns(124));
    try std.testing.expectEqual(Effect.sleep, weaponEffect(123).?);
}

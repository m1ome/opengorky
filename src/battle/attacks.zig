//! Attack tables: heroes by weapon nameID (branches 0x48bda2), monsters by
//! fighter nameID (0x4896b0, table 0x48d618).

/// Hero-table strike (0x48bda2): nameIDs outside 100…139 (0x4896b0: nameID − 0x64
/// ≤ 0x27 takes its own branch from table 0x48d618, even for a party hero, Medusa)
/// and 103, 104, 111, 112, 134, whose 0x48d618 cells lead to 0x48bda2.
pub fn heroTable(name_id: i32) bool {
    return switch (name_id) {
        103, 104, 111, 112, 134 => true,
        100...102, 105...110, 113...133, 135...139 => false,
        else => true,
    };
}

/// Hero attack (0x48bda2): animation and hit wait by weapon nameID (the exe ignores
/// `useAnim`). McFadden (24) and Hutchens (29) have waits shifted by wdelay_*
/// (0x4896f4…0x48973c): `+` for bayonet knife, pistol (49), shocker (52), shotgun,
/// rifle (98) and grenades, `−` for fist and bat; other weapons have no shift
/// (revolver 50, shocker 55, default rifle).
/// `until_end`: the hit comes after the animation ends (0x428800 queues it, the
/// callback follows), then animation `then`.
/// `after`: wait after the hit until the attack ends (0x428c00 before 0x425630):
/// pistol, rifle and shotgun flash attack_rifle_flash_timeout (5), chaingun
/// attack_chaingun_flash_timeout (80), nitrogen gun attack_nitro_timeout (80).
/// `pre`: beam tick before the hit. For the ion rifle and blaster the callback sets
/// the beam (0x1a → 0x4a2680, 0x1c → 0x4a37c0) and damage comes later: ion when
/// less than 5 ticks of the beam's life (attack_ion_life 27) remain (0x4a1840),
/// blaster with the next callback 5 after attack_blaster_delay2 (14).
pub const HeroAttack = struct { anim: []const u8, wait: u32, extra: i32 = 0, until_end: bool = false, then: ?[]const u8 = null, after: u32 = 0, pre: ?u32 = null };

pub fn heroAttack(attacker_id: i32, weapon_id: i32) HeroAttack {
    const mh = attacker_id == 24 or attacker_id == 29;
    return switch (weapon_id) {
        // Fists: attack_fist_hit_delay (50) − wdelay_fist (12), callback 5.
        48, 70 => .{ .anim = "attack_boxing", .wait = 50, .extra = if (mh) -12 else 0 },
        // Bayonet: attack_bayonet_hit_delay (22) + wdelay_bayonet (10); dagger 28.
        43 => .{ .anim = "attack_butcher", .wait = 22, .extra = if (mh) 10 else 0 },
        54 => .{ .anim = "attack_butcher", .wait = 28 },
        42, 47 => .{ .anim = "attack_axe", .wait = 30 },
        // Bat: attack_baseball_hit_delay (65) − wdelay_baseball (10) (0x48c416).
        44, 76 => .{ .anim = "attack_baseball", .wait = 65, .extra = if (mh) -10 else 0 },
        // Shocker 52: + wdelay_shocker (30); 55 has no shift (0x48c287).
        52 => .{ .anim = "attack_shocker", .wait = 20, .extra = if (mh) 30 else 0 },
        55 => .{ .anim = "attack_shocker", .wait = 20 },
        80 => .{ .anim = "attack_syringe", .wait = 30 },
        40 => .{ .anim = "attack_knife", .wait = 25 },
        41 => .{ .anim = "attack_stone", .wait = 32 },
        // Grenades: attack_grenade_start_delay (37) + wdelay_grenade (36) (0x48c359,
        // 0x48c398, 0x48cdb1).
        33, 35, 1027 => .{ .anim = "attack_grenade", .wait = 37, .extra = if (mh) 36 else 0 },
        // Molotov, vodka, petrol: "molotov" (75) only for Hutchens, "stone" for others.
        86, 1030, 1032 => if (attacker_id == 29) .{ .anim = "attack_molotov", .wait = 75 } else .{ .anim = "attack_stone", .wait = 32 },
        // Time bomb (0x48c507) and decoy (0x48d261): McFadden and Hutchens use
        // attack_timebomb and 50 ticks (0x48c5c9, 0x48d31f), others pickup_start to the
        // end, callback (37 / 5), pickup_end.
        34, 1031 => if (mh) .{ .anim = "attack_timebomb", .wait = 50 } else .{ .anim = "pickup_start", .wait = 0, .until_end = true, .then = "pickup_end" },
        45 => .{ .anim = "attack_gun", .wait = 40 },
        46 => .{ .anim = "attack_gun", .wait = 35 },
        // Pistol: attack_dartgun_delay (40) + wdelay_pistol (3); the revolver (50) has
        // no shift (0x48c0be). After the shot, a 5-tick flash.
        49 => .{ .anim = "attack_gun", .wait = 40, .extra = if (mh) 3 else 0, .after = 5 },
        50 => .{ .anim = "attack_gun", .wait = 40, .after = 5 },
        98 => .{ .anim = "attack_sniper", .wait = 59, .extra = if (mh) 35 else 0, .after = 5 },
        1023 => .{ .anim = "attack_rifle", .wait = 40, .extra = if (mh) 15 else 0, .after = 5 },
        1022 => .{ .anim = "attack_chaingun", .wait = 40, .after = 80 },
        1024 => .{ .anim = "attack_bazooka", .wait = 47 },
        1028 => .{ .anim = "attack_bazooka", .wait = 50 },
        1026 => .{ .anim = "attack_flame", .wait = 20 },
        1025 => .{ .anim = "attack_flame", .wait = 34, .after = 80 },
        // Ion: beam at tick 35, damage 23 later (27 − 4), end attack_ion_life + 10 (37)
        // after the beam (0x48d078).
        1029 => .{ .anim = "attack_ionrifle", .wait = 35 + 23, .pre = 35, .after = 37 - 23 },
        // Blaster (0x48d0a5): stream at tick 45 (delay1), damage after delay2 (14), end
        // after delay3 (100).
        1037 => .{ .anim = "attack_blaster", .wait = 45 + 14, .pre = 45, .after = 100 },
        // Satellite: the exe passes "ude_radio" (a typo, no such animation).
        1038, 1039 => .{ .anim = "ude_radio", .wait = 0 },
        1040 => .{ .anim = "use_radio", .wait = 0 },
        // Everything else (0x48d57c): attack_rifle, attack_rifle_hit_delay (59), no shift.
        else => .{ .anim = "attack_rifle", .wait = 59 },
    };
}

pub const Lift = struct { link: []const u8 = "hand", z: f32 = -400, bind_at: u32, release_after: u32 };

/// Monster strike (0x4896b0, table 0x48d618): logical animation, ticks until the
/// hit, wait after it, victim lift. Only for nameIDs where `heroTable` is false.
/// The exe branches pick the strike by weapon nameID (+0x58), not by longAttack:
/// Fatman, Stinger, Puppet and Messiah don't set it in data.
/// A branch queues the fighter's animation (0x428980), waits (0x428c00) and hit
/// callbacks (0x428b90 → 0x4863c0), ending with 0x425630 (attack over).
/// `wait`: ticks until the damage callback (code 5: weapon +0xf0 with flag 1);
/// `after`: waits after the last callback until 0x425630 (often sf_delay 30 or
/// a constant 30).
/// `react`: that many ticks later the target's reaction repeats without damage
/// (code 7: +0xf0 with flag 0 → 0x490e80 without 0x490f10: hit and blood, 0x491920 and 0x491510).
/// `pre`: flash tick before the hit (0x427ce0 on the "chaingun" point before the callback).
pub const MonsterAttack = struct { anim: []const u8, wait: u32, after: u32 = 0, lift: ?Lift = null, second: u32 = 0, react: u32 = 0, pre: ?u32 = null, vanish: u32 = 0 };

pub fn monsterAttack(id: i32, wpn_id: i32) MonsterAttack {
    const S = "short_attack";
    const L = "long_attack";
    return switch (id) {
        // Jet Elmer (0x48a05d): with rockets (57) long_attack, first rocket after
        // attack_jetelmer_delay1 (43), the second delay2 (28) later, then 30 ticks;
        // 56 short_attack (0x48a152): hit (code 5) after attack_jetelmer_delay (36), a
        // second hit after ftol(attack_jetelmer_scr) (12.0), tail 0x48b864 (30).
        100 => if (wpn_id == 57) .{ .anim = L, .wait = 43, .second = 28, .after = 30 } else .{ .anim = S, .wait = 36, .second = 12, .after = 30 },
        // Garcia (0x4897fc): 67 long_attack, chaingun flash and light at
        // garcia_attack_long_delay1 (41), hit delay2 (10) later, then delay3 (20) and
        // sf_delay (30); 66 short_attack, hit after short_delay + delay2 (25 + 20),
        // reaction without damage (code 7) delay3 (20) later, sf_delay (30).
        101 => if (wpn_id == 67) .{ .anim = L, .wait = 51, .after = 50, .pre = 41 } else .{ .anim = S, .wait = 45, .react = 20, .after = 30 },
        // Sphinx (0x489a2e, weapon 73): hit after sphinx_attack_short_delay (28),
        // reaction without damage (code 7) delay2 (20) later, then sf_delay (30).
        102 => .{ .anim = S, .wait = 28, .react = 20, .after = 30 },
        // Cutter Pill (0x489afd): weapon 88 lifts on the claw ("hand"), hit at tick 52
        // (short_delay1 + delay2: 37 + 15), then delay3 (50), release, and 80 more
        // (0x489d40); 89 long_attack, bullet (code 13) after long_start_delay 35.
        105 => if (wpn_id == 88) .{ .anim = S, .wait = 37 + 15, .after = 50 + 80, .lift = .{ .bind_at = 37, .release_after = 50 } } else .{ .anim = L, .wait = 35 },
        // RC-28 (0x489d5d, weapon 92): rc28_attack_short_delay (25), then sf_delay (30).
        106 => .{ .anim = S, .wait = 25, .after = 30 },
        // Fang (0x489dd5): 91 long_attack, rocket (code 16) after long_delay1 + delay2
        // (22 + 35), then 30; 90 short_attack after short_delay (28).
        107 => if (wpn_id == 91) .{ .anim = L, .wait = 22 + 35, .after = 30 } else .{ .anim = S, .wait = 28 },
        // Hound (0x48b46e), Siner (0x48a372): hit after their own delay, then 30
        // (common tail 0x48b864).
        108 => .{ .anim = S, .wait = 23, .after = 30 },
        109 => .{ .anim = S, .wait = 40, .after = 30 },
        // Smoke Rider (0x489e9d): 1003 (smokeridergun) long_attack, rocket (code 19)
        // after attack_smokerider_shot_delay (51), then 30; 1004 ladder_start and
        // callback 21 (0x487698): long_attack if both pilots are linked to it, and after
        // attack_smokerider_shot3_delay (20) a rocket of the second kind
        // (code 20, smokerider_attack2_rocket1_*).
        110 => if (wpn_id == 1003) .{ .anim = L, .wait = 51, .after = 30 } else .{ .anim = L, .wait = 20, .after = 30 },
        // Grandma (0x489f71): by weapon, not longAttack: 1006 (grandma_mad_gun, poison
        // spit "atak", code 22) long_attack, 1005 (grandma_std) short_attack; both after
        // attack_grandma_delay (70), then 30.
        113 => .{ .anim = if (wpn_id == 1006) L else S, .wait = 70, .after = 30 },
        // Grandma's grandson (0x489f55): long_attack, attack_grandson_delay (30), then 30.
        114 => .{ .anim = L, .wait = 30, .after = 30 },
        // Judge (0x48bc72) and his child (0x48bd0a): judge_delay/delay2 (42/30),
        // judgechild_delay/delay2 (30/40).
        115 => .{ .anim = S, .wait = 42, .after = 30 },
        116 => .{ .anim = S, .wait = 30, .after = 40 },
        // Shoggoth (0x489fe2, weapon 1015): tail after attack_shogoth_tail_delay (30).
        117 => .{ .anim = S, .wait = 30 },
        // Headnail (0x48a72b): two saw strikes, left after delay1+2+3 (30+5+8), right
        // delay4+5 (5+32) later, then delay6 (5); each with sparks and damage.
        118 => .{ .anim = S, .wait = 43, .second = 5 + 32, .after = 5 },
        // Medusa (0x48a465): 1021 short_attack, hit after attack_medusa_s_delay 47, the
        // mouth beam lasts attack_medusa_s_timeout 72; otherwise long_attack, current
        // (callback 0x1f → 0x4a44e0) after attack_medusa_l_delay 32, then delay2 30 and
        // 20 more ticks.
        119 => if (wpn_id == 1021) .{ .anim = S, .wait = 47, .after = 72 } else .{ .anim = L, .wait = 32, .after = 50 },
        // Invisible (0x48a2a6, any weapon): short_attack ("atak", 76 frames, hit sounds
        // at 32–34), visible at once (+0x311c = 255) and fading in (command 0x2d, state
        // 6 "o", in_fadein); hit after attack_invisible_delay (40); 40 later it vanishes
        // (0x2d, "i", in_fadeout), 80 more and done (0x2e, +0x311c = 0).
        120 => .{ .anim = S, .wait = 40, .vanish = 40, .after = 80 },
        // Pain God (0x48a20e): stream (code 30) after paingod_delay (20), then delay2 (30).
        121 => .{ .anim = L, .wait = 20, .after = 30 },
        // Harvester (0x48a390): attack_harvester_delay (32), then 30.
        122 => .{ .anim = S, .wait = 32, .after = 30 },
        // Sister of Mercy (0x48ae0c): brain (code 32) after sister_delay (83), delay2 (30).
        123 => .{ .anim = S, .wait = 83, .after = 30 },
        // Fatman (0x48aea4): fatmanshort (1075) long_attack "atak1", hit at tick 40
        // (attack_fatman_s_delay), then 30; fatmanlong (1076) short_attack "atak2",
        // flash and shot (code 50) at 68 (attack_fatman_l_delay), flash
        // attack_rifle_flash_timeout (5), then 30 (tail 0x48b5e3).
        124 => if (wpn_id == 1075) .{ .anim = L, .wait = 40, .after = 30 } else .{ .anim = S, .wait = 68, .after = 5 + 30 },
        // Cripple (0x48b12c): flash on "chaingun1" and shot (code 11) after
        // cripple_delay1 (50), 5-tick flash, then delay2 (40).
        125 => .{ .anim = L, .wait = 50, .after = 5 + 40 },
        // Reverend Insect (0x48ab82): "nitro" stream after attack_revinsect_delay (45),
        // hit delay2 (20) later, then delay3 (64).
        126 => .{ .anim = L, .wait = 45 + 20, .after = 64, .pre = 45 },
        // Stinger (0x48b6be): 1071 short_attack, stream (code 43) after stinger_s_delay
        // (50), then s_delay2 (30); otherwise long_attack, ball (code 44) after l_delay
        // (4), then l_delay2 (80).
        127 => if (wpn_id == 1071) .{ .anim = S, .wait = 50, .after = 30 } else .{ .anim = L, .wait = 4, .after = 80 },
        // Hornet (0x48b256): lift at hornet_delay1 (40), hit delay2 (5) later, release
        // delay3 (30) later, 30 more.
        128 => .{ .anim = L, .wait = 40 + 5, .after = 30 + 30, .lift = .{ .bind_at = 40, .release_after = 30 } },
        // Lilith and child (0x48b3ff), Needle (0x48a3ae): own delay, then 30.
        129, 135 => .{ .anim = S, .wait = 41, .after = 30 },
        130 => .{ .anim = S, .wait = 43, .after = 30 },
        // Guard (0x48afae): 1062 short_attack, hit after attack_guard_1_delay (45);
        // otherwise attack_3 after guard_3_delay (40); both tail 0x48b81a → 0x48b864
        // (code 5, then 30). 1063 long_attack: after guard_2_delay (43) eye beams
        // (code 0x23 → 0x488025, "oko1"/"oko2", no damage), 5 later "smoke2" and
        // damage (code 0x24 → 0x48809c), then guard_2_delay2 (75).
        131 => switch (wpn_id) {
            1062 => .{ .anim = S, .wait = 45, .after = 30 },
            1063 => .{ .anim = L, .wait = 43 + 5, .after = 75, .pre = 43 },
            else => .{ .anim = "attack_3", .wait = 40, .after = 30 },
        },
        // Puppet (0x48b4dc): 1067 short_attack after puppet_s_delay (32), then 30;
        // otherwise long_attack: flash and shot (code 11) after l_delay (53), flash
        // held l_timeout (16), then 30.
        132 => if (wpn_id == 1067) .{ .anim = S, .wait = 32, .after = 30 } else .{ .anim = L, .wait = 53, .after = 16 + 30 },
        // Squeaker (0x48a3cc): shake (code 27) after sq_delay (50), then delay2 (30).
        133 => .{ .anim = L, .wait = 50, .after = 30 },
        // Schizo (0x48b914): 1077 short_attack, hit after schizo_t_delay (50), then
        // t_delay2 (40); 1078 long_attack, gas from the bell after g_delay (78), cloud
        // (code 49) g_delay2 (98) later, then g_delay3 (30); 1079 attack_3, flash and
        // shot (code 11) after r_delay (60), flash until r_delay2 (35).
        136 => switch (wpn_id) {
            1077 => .{ .anim = S, .wait = 50, .after = 40 },
            1078 => .{ .anim = L, .wait = 78 + 98, .after = 30, .pre = 78 },
            else => .{ .anim = "attack_3", .wait = 60, .after = 35 },
        },
        // Lucy (0x48ace3): 1057 short_attack after lucy_s_delay (35), then 30;
        // otherwise long_attack: flash and shot (code 11) after l_delay (74), flash
        // attack_rifle_flash_timeout (5), then 20.
        137 => if (wpn_id == 1057) .{ .anim = S, .wait = 35, .after = 30 } else .{ .anim = L, .wait = 74, .after = 5 + 20 },
        // Incubus (0x48b626): ball (code 42) after incubus_delay (15), then delay2 (90).
        138 => .{ .anim = L, .wait = 15, .after = 90 },
        // Messiah (0x48b7ee): 1073 short_attack after messiah_s_delay (50), then 30;
        // otherwise long_attack after l_delay (48), then 60.
        139 => if (wpn_id == 1073) .{ .anim = S, .wait = 50, .after = 30 } else .{ .anim = L, .wait = 48, .after = 60 },
        else => unreachable, // other nameIDs use heroTable
    };
}

test "table 0x48d618: hero branches, Guard and Jet Elmer" {
    const t = @import("std").testing;
    for ([_]i32{ 103, 104, 111, 112, 134, 99, 140 }) |id| try t.expect(heroTable(id));
    // Every nameID 100…139 outside the hero branches has its own entry (no unreachable).
    for (100..140) |i| if (!heroTable(@intCast(i))) {
        _ = monsterAttack(@intCast(i), 0);
    };
    // Jet Elmer 56: two hits (36, then 12 later), tail 30 (0x48a152).
    const je = monsterAttack(100, 56);
    try t.expectEqual(@as(u32, 36), je.wait);
    try t.expectEqual(@as(u32, 12), je.second);
    try t.expectEqual(@as(u32, 30), je.after);
    // Guard: short strike and attack_3 have tail 30 (0x48b864); beam damage at 43 + 5.
    try t.expectEqual(@as(u32, 30), monsterAttack(131, 1062).after);
    try t.expectEqual(@as(u32, 30), monsterAttack(131, 1).after);
    try t.expectEqual(@as(u32, 48), monsterAttack(131, 1063).wait);
    // Lasers (code 0x23) at tick 43, smoke and damage (code 0x24) 5 later.
    try t.expectEqual(@as(?u32, 43), monsterAttack(131, 1063).pre);
}

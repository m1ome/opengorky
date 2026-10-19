//! Logical animation slots of the exe (0x4280e0): per-state animation and walk speed tables.

const std = @import("std");

/// Logical animation names (0x4280e0, case-insensitive): the slot number in the
/// actor's tables — per-state animations (+0x2cc) and walk speeds (+0x2fbc).
/// In the exe "stair_up" lands in the "stair_down" slot (13; 14 stays empty), an unknown
/// name in slot 0, "appearEnd" in 1.
const logical_names = [_]struct { []const u8, u8 }{
    .{ "death", 23 },             .{ "push_start", 6 },       .{ "push_end", 8 },         .{ "push_walk", 7 },
    .{ "walk", 2 },               .{ "stepping", 3 },         .{ "run", 4 },              .{ "ladder_start", 9 },
    .{ "ladder_end", 11 },        .{ "ladder_walk", 10 },     .{ "strafe", 12 },          .{ "stair_down", 13 },
    .{ "stair_up", 13 },          .{ "walk_footbridge", 15 }, .{ "jump_start", 16 },      .{ "jump_end", 17 },
    .{ "jump_hang", 18 },         .{ "crouch", 19 },          .{ "defend", 5 },           .{ "defend_start", 65 },
    .{ "defend_end", 66 },        .{ "scary", 20 },           .{ "dodge", 21 },           .{ "hit", 22 },
    .{ "delirium", 24 },          .{ "delirium_up", 25 },     .{ "hide", 26 },            .{ "hide_back", 27 },
    .{ "take_out", 28 },          .{ "pickup_start", 29 },    .{ "pickup_end", 30 },      .{ "pickup_wait", 31 },
    .{ "use_aid", 32 },           .{ "use_medicine", 33 },    .{ "use_radio", 34 },       .{ "kneel_down", 35 },
    .{ "kneel_idle", 36 },        .{ "kneel_up", 37 },        .{ "attack_axe", 38 },      .{ "attack_baseball", 39 },
    .{ "attack_boxing", 40 },     .{ "attack_knife", 41 },    .{ "attack_butcher", 42 },  .{ "attack_dynamit", 43 },
    .{ "attack_fireworks", 44 },  .{ "attack_grenade", 45 },  .{ "attack_bazooka", 46 },  .{ "attack_flame", 47 },
    .{ "attack_machinegun", 48 }, .{ "attack_rifle", 49 },    .{ "attack_sniper", 50 },   .{ "attack_molotov", 51 },
    .{ "attack_gun", 52 },        .{ "attack_shocker", 53 },  .{ "attack_stone", 54 },    .{ "attack_syringe", 55 },
    .{ "attack_sabre", 56 },      .{ "attack_timebomb", 57 }, .{ "attack_chaingun", 58 }, .{ "attack_blaster", 59 },
    .{ "attack_ionrifle", 60 },   .{ "short_attack", 61 },    .{ "long_attack", 62 },     .{ "attack_3", 63 },
    .{ "ponton_out", 64 },        .{ "appearEnd", 1 },
};
/// Logical animation slots (the constructor fills 0x43 speeds, 0x42261b).
pub const logical_count = 0x43;

pub fn logicalIndex(name: []const u8) u8 {
    for (logical_names) |e| if (std.ascii.eqlIgnoreCase(e[0], name)) return e[1];
    return 0;
}

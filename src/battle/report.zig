//! The after-battle report's kill icons: the exe picks a monster's by its nameID
//! from a fixed table (0x523f00) — not by the fighter's `spriteFile`, so a nameID
//! missing here (the shoggoth's 117) shows no icon.

pub const monster_icons = [_]struct { id: i32, name: []const u8 }{
    .{ .id = 125, .name = "cripple" },         .{ .id = 105, .name = "cutterpil" },       .{ .id = 107, .name = "fang" },
    .{ .id = 124, .name = "fatman" },          .{ .id = 101, .name = "garcia" },          .{ .id = 113, .name = "grandma" },
    .{ .id = 131, .name = "guard" },           .{ .id = 122, .name = "harvester" },       .{ .id = 118, .name = "headnail" },
    .{ .id = 128, .name = "hornet" },          .{ .id = 108, .name = "hound" },           .{ .id = 138, .name = "incubus" },
    .{ .id = 120, .name = "invisible" },       .{ .id = 100, .name = "jet elmer" },       .{ .id = 115, .name = "judge" },
    .{ .id = 116, .name = "judgeslave" },      .{ .id = 129, .name = "lillith" },         .{ .id = 135, .name = "lillith" },
    .{ .id = 137, .name = "lucy" },            .{ .id = 119, .name = "medusa_rap" },      .{ .id = 139, .name = "messiah" },
    .{ .id = 130, .name = "needle" },          .{ .id = 121, .name = "paingod" },         .{ .id = 132, .name = "puppet" },
    .{ .id = 106, .name = "rc28" },            .{ .id = 126, .name = "reverend insect" }, .{ .id = 136, .name = "schizo family" },
    .{ .id = 109, .name = "sinner" },          .{ .id = 123, .name = "sister of mercy" }, .{ .id = 110, .name = "smoke" },
    .{ .id = 102, .name = "sphinks" },         .{ .id = 133, .name = "squeaker" },        .{ .id = 127, .name = "stinger" },
    .{ .id = 114, .name = "wnuczek" },         .{ .id = 27, .name = "kozow_rap" },        .{ .id = 141, .name = "nato_capitan_rap" },
    .{ .id = 25, .name = "nato_soldier_rap" }, .{ .id = 28, .name = "specnaz_rap" },      .{ .id = 142, .name = "Lamare" },
};

pub fn iconOf(id: i32) ?[]const u8 {
    for (monster_icons) |mi| if (mi.id == id) return mi.name;
    return null;
}

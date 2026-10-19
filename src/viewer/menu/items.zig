//! Menu screens and their items (0x4134e0): pure data, no SDL.

/// Save slots (0x4134e0): 30, 5 visible.
pub const slot_count = 30;
pub const visible_slots = 5;

pub const Screen = enum { main, ingame, load, save, credits, options, sound, graphics };

pub const Action = union(enum) {
    none,
    new_game,
    resume_game,
    main_menu,
    exit,
    save: usize,
    load: usize,
    /// Defeat: retry the battle (0x4542c0 — LEVEL_Load of the same battle).
    retry_battle,
};

/// What an item does: host action, screen change, mixer group volume, shadows.
const Kind = union(enum) {
    action: Action,
    open: Screen,
    back,
    gain: usize,
    shadows,
    gamma,
    slot: usize,
};

pub const Item = struct { text_id: i32, fallback: []const u8, kind: Kind };

pub const main_items = [_]Item{
    .{ .text_id = 300, .fallback = "new game", .kind = .{ .action = .new_game } },
    .{ .text_id = 307, .fallback = "load", .kind = .{ .open = .load } },
    .{ .text_id = 302, .fallback = "options", .kind = .{ .open = .options } },
    .{ .text_id = 304, .fallback = "exit game", .kind = .{ .action = .exit } },
};

/// In the game "resume" (first) and "save" (after "load") are added.
pub const ingame_items = [_]Item{
    .{ .text_id = 323, .fallback = "resume", .kind = .{ .action = .resume_game } },
    .{ .text_id = 300, .fallback = "new game", .kind = .{ .action = .new_game } },
    .{ .text_id = 307, .fallback = "load", .kind = .{ .open = .load } },
    .{ .text_id = 301, .fallback = "save", .kind = .{ .open = .save } },
    .{ .text_id = 302, .fallback = "options", .kind = .{ .open = .options } },
    .{ .text_id = 304, .fallback = "exit game", .kind = .{ .action = .exit } },
};

pub const options_items = [_]Item{
    .{ .text_id = 310, .fallback = "graphics options", .kind = .{ .open = .graphics } },
    .{ .text_id = 309, .fallback = "sound options", .kind = .{ .open = .sound } },
    .{ .text_id = 303, .fallback = "credits", .kind = .{ .open = .credits } },
    .{ .text_id = 306, .fallback = "back", .kind = .back },
};

/// Mixer group volumes (effects 0, music 1, speech 2).
pub const sound_items = [_]Item{
    .{ .text_id = 316, .fallback = "music volume", .kind = .{ .gain = 1 } },
    .{ .text_id = 317, .fallback = "sfx volume", .kind = .{ .gain = 0 } },
    .{ .text_id = 328, .fallback = "voice volume", .kind = .{ .gain = 2 } },
    .{ .text_id = 306, .fallback = "back", .kind = .back },
};

pub const graphics_items = [_]Item{
    .{ .text_id = 312, .fallback = "shadows", .kind = .shadows },
    .{ .text_id = 322, .fallback = "gamma", .kind = .gamma },
    .{ .text_id = 306, .fallback = "back", .kind = .back },
};

/// "save" is hidden in battle and during a scene or dialog (0x4138a4).
pub const ingame_items_nosave = ingame_items[0..3].* ++ ingame_items[4..].*;

/// Slots page: 30 slots and "back".
pub const slot_items = blk: {
    var a: [slot_count + 1]Item = undefined;
    for (0..slot_count) |i| a[i] = .{ .text_id = -2, .fallback = "", .kind = .{ .slot = i } };
    a[slot_count] = .{ .text_id = 306, .fallback = "back", .kind = .back };
    break :blk a;
};

//! OpenGorky: a free reimplementation of the Gorky 17 (Odium) engine.
//! Module `og`: one export per subsystem, through its folder entry file.

pub const formats = @import("formats.zig");
pub const script = @import("script.zig");
pub const fields = @import("fields.zig");
pub const num = @import("num.zig");
pub const vec = @import("vec.zig");
pub const effects = @import("effects.zig");
pub const popup = @import("popup.zig");
pub const outbox = @import("outbox.zig");
pub const actor = @import("actor.zig");
pub const render = @import("render.zig");
pub const audio = @import("audio.zig");
pub const battle = @import("battle.zig");
pub const state = @import("state.zig");
pub const inventory = @import("inventory.zig");
pub const world = @import("world.zig");
pub const scene = @import("scene.zig");
pub const combat = @import("combat.zig");
pub const save = @import("save.zig");
pub const game = @import("game.zig");
pub const console = @import("console.zig");

test {
    _ = formats;
    _ = script;
    _ = fields;
    _ = effects;
    _ = popup;
    _ = actor;
    _ = render;
    _ = @import("actor/motion.zig");
    _ = @import("crt_rand.zig");
    _ = audio;
    _ = battle;
    _ = state;
    _ = inventory;
    _ = world;
    _ = scene;
    _ = combat;
    _ = @import("builtins.zig");
    _ = save;
    _ = game;
    _ = console;
    _ = @import("tests/combat.zig");
    _ = @import("tests/game.zig");
    _ = @import("tests/script.zig");
}

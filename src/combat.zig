//! Entry point of `combat/` for other engine folders. Combat turn logic on top of the battle model and the world.
//! Files not exported here are internal to the folder.

pub const ai = @import("combat/ai.zig");
pub const ai_turn = @import("combat/ai_turn.zig");
pub const anim = @import("combat/anim.zig");
pub const control = @import("combat/control.zig");
pub const debug = @import("combat/debug.zig");
pub const devices = @import("combat/devices.zig");
pub const roster = @import("combat/roster.zig");
pub const states = @import("combat/states.zig");
pub const tick = @import("combat/tick.zig");
pub const turns = @import("combat/turns.zig");
pub const weapons = @import("combat/weapons.zig");

test {
    _ = anim;
    _ = @import("combat/strike.zig");
    _ = @import("combat/bombs.zig");
    _ = tick;
    _ = turns;
    _ = roster;
}

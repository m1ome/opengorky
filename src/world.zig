//! Entry point of `world/` for other engine folders. Location behaviour: walking, areas, level changes, party.
//! Files not exported here are internal to the folder.

pub const actions = @import("world/actions.zig");
pub const areas = @import("world/areas.zig");
pub const bitmap_anim = @import("world/bitmap_anim.zig");
pub const floor = @import("world/floor.zig");
pub const levels = @import("world/levels.zig");
pub const mods = @import("world/mods.zig");
pub const nav = @import("world/nav.zig");
pub const party = @import("world/party.zig");
pub const queue = @import("world/queue.zig");
pub const route = @import("world/route.zig");
pub const snapshot = @import("world/snapshot.zig");
pub const sources = @import("world/sources.zig");
pub const spawn = @import("world/spawn.zig");
pub const start = @import("world/start.zig");
pub const walk = @import("world/walk.zig");

test {
    _ = bitmap_anim;
    _ = floor;
    _ = nav;
    _ = queue;
}

//! Entry point of `state/` for other engine folders. World state data: World and scene state.
//! Files not exported here are internal to the folder.

pub const groups = @import("state/groups.zig");
pub const object = @import("state/object.zig");
pub const scene = @import("state/scene.zig");
pub const world = @import("state/world.zig");

test {
    _ = groups;
    _ = object;
    _ = scene;
    _ = world;
}

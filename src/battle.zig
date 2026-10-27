//! Entry point of `battle/` for other engine folders. Battle model without the world: grid, rules, fighters, attack tables.
//! Files not exported here are internal to the folder.

pub const attacks = @import("battle/attacks.zig");
pub const battle = @import("battle/battle.zig");
pub const fighter = @import("battle/fighter.zig");
pub const generic = @import("battle/generic.zig");
pub const grid = @import("battle/grid.zig");
pub const immunity = @import("battle/immunity.zig");
pub const obj = @import("battle/obj.zig");
pub const patterns = @import("battle/patterns.zig");
pub const report = @import("battle/report.zig");
pub const rules = @import("battle/rules.zig");
pub const weapon_class = @import("battle/weapon_class.zig");

test {
    _ = attacks;
    _ = generic;
    _ = grid;
    _ = immunity;
    _ = rules;
}

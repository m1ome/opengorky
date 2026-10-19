//! Battle attack effects following the exe choreography (0x4896b0, hit callback
//! 0x4863c0): muzzle flash on a link point, smoke, explosions, gas, flamethrower, blood.
//! Numbers are adjust.kdt variables (attack_*).

pub const hits = @import("fx/hits.zig");
pub const launch = @import("fx/launch.zig");
pub const blood = @import("fx/blood.zig");
pub const explosion = @import("fx/explosion.zig");

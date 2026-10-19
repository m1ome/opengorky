//! Heroes' items: tab lists, equipment, healing.
//!
//! An item belongs to whoever is named in `Owner`. `place` (+0x344): 0 on the ground,
//! 1 backpack, 10–13 fighter slots (+0x324c…+0x3258, 0x4add00): 11 hand, 13 armour
//! (10 and 12 monsters only). `type`: 10 ammo, 20 medicine (`hp` = amount), 30 armour
//! (`armor`, resistances `pr*`), 0 keys and the rest; weapons store their damage kind.

pub const item = @import("inventory/item.zig");
pub const list = @import("inventory/list.zig");
pub const equipment = @import("inventory/equipment.zig");
pub const ammo = @import("inventory/ammo.zig");
pub const give = @import("inventory/give.zig");
pub const box = @import("inventory/box.zig");
pub const medicine = @import("inventory/medicine.zig");
pub const create = @import("inventory/create.zig");
pub const points = @import("inventory/points.zig");

test {
    _ = medicine;
}

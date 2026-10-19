//! Giving items between heroes (0x42e3f0, 0x4b3630).

const fields = @import("../fields.zig");
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;
const item_mod = @import("item.zig");
const equipment = @import("equipment.zig");
const ammo = @import("ammo.zig");

/// Whether the carried item may be dropped on portrait `to` (0x42e3f0): not to self, not
/// to or from Medusa (nameID 119; 0x42e485/0x42e495), in battle only to a neighbour.
/// Give mode never starts for Medusa (0x4b23dc) and refuses her as recipient (0x450872).
pub fn canGive(self: *World, from: *Object, to: *Object) bool {
    if (to == from or fields.isMedusa(to) or fields.isMedusa(from)) return false;
    if (self.battle) |*b| if (!b.adjacent(from, to)) return false;
    return true;
}

/// Give a single item: out of the giver's hand into the receiver's backpack; ammo
/// merges into the receiver's pack.
pub fn handOver(self: *World, from: *Object, to: *Object, item: *Object) void {
    if (item_mod.placeOf(item) == .hand) equipment.setHoldState(self, from, null);
    item_mod.setPlace(item, .backpack);
    fields.setOwner(item, to.name);
    item_mod.mergeAmmo(self, item);
}

/// Give `amount` units (0x4b3630): ammo moves between packs of the same kind (0x47d880 by
/// nameID and owner); other items move `amount` equal items to the backpack. With no
/// receiving pack the exe does nothing (0x4b367e/0x4b3686) because every hero has all
/// packs; we create an empty one (`ammo.ammoPackOf`) instead of handing over the giver's pack.
pub fn transfer(self: *World, from: *Object, to: *Object, item: *Object, amount: i32) void {
    if (amount <= 0) return;
    if (item_mod.typeOf(item) == .ammo) {
        if (ammo.ammoPackOf(self, to, item)) |t| {
            const n = @min(amount, fields.counter(item));
            fields.setCounter(item, fields.counter(item) - n);
            fields.setCounter(t, fields.counter(t) + n);
        }
        if (fields.counter(item) < 1 and item_mod.placeOf(item) == .hand) {
            item_mod.setPlace(item, .backpack);
            equipment.setHoldState(self, from, null);
        }
        return;
    }
    var left = amount;
    var i: usize = 0;
    while (left > 0 and i < self.rt.objects.items.len) : (i += 1) {
        const o = self.rt.objects.items[i];
        if (!world.isItem(o)) continue;
        if (fields.nameId(o) != fields.nameId(item) or !fields.ownerIs(o, from.name) or o.getInt("place") <= 0) continue;
        if (item_mod.placeOf(o) == .hand) equipment.setHoldState(self, from, null);
        item_mod.setPlace(o, .backpack);
        fields.setOwner(o, to.name);
        left -= 1;
    }
}

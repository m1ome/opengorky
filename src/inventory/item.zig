//! Item basics: place and type fields, using up a unit, merging ammo stacks.

const fields = @import("../fields.zig");
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;

/// Item place (`place`, +0x344, 0x4add00); other values are kept as-is.
pub const Place = enum(i32) {
    /// Dropped or used up (inventory window).
    gone = -1,
    ground = 0,
    backpack = 1,
    hand = 11,
    armor = 13,
    /// Party item without owner (fist; 0x4adcd0).
    party = 200,
    _,
};

/// Item kind (`type`); weapons hold a damage kind, so other values are valid.
const ItemType = enum(i32) {
    other = 0,
    ammo = 10,
    medicine = 20,
    armor = 30,
    _,
};

pub fn placeOf(o: *Object) Place {
    return @fromBackingInt(@intCast(o.getInt("place")));
}

pub fn setPlace(o: *Object, p: Place) void {
    o.setInt("place", @backingInt(p));
}

pub fn typeOf(o: *Object) ItemType {
    return @fromBackingInt(@intCast(o.getInt("type")));
}

pub const place_hand = @backingInt(Place.hand);

pub const type_medicine = @backingInt(ItemType.medicine);

/// Remove one unit (from a stack, or the whole item).
pub fn consume(item: *Object) void {
    if (fields.counter(item) > 1) {
        fields.setCounter(item, fields.counter(item) - 1);
        return;
    }
    World.nativeOf(item).deleted = true;
    item.enabled = false;
}

/// A hero's ammo (type 10) merges into his first pack of the same `nameID` (0x457164 →
/// 0x47d880); heroes start with empty packs of every kind and use the first (0x4ce358).
pub fn mergeAmmo(self: *World, item: *Object) void {
    if (typeOf(item) != .ammo or World.nativeOf(item).deleted) return;
    const owner = fields.owner(item);
    const h = self.rt.findObject(owner) orelse return;
    if (!World.nativeOf(h).hero) return;
    for (self.rt.objects.items) |o| {
        if (o == item) return; // it is the first pack itself
        if (!world.isItem(o)) continue;
        if (typeOf(o) != .ammo or fields.nameId(o) != fields.nameId(item)) continue;
        if (!fields.ownerIs(o, owner)) continue;
        fields.setCounter(o, fields.counter(o) + fields.counter(item));
        World.nativeOf(item).deleted = true;
        item.enabled = false;
        return;
    }
}

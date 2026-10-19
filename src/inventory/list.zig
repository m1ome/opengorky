//! Tab lists and the quick list (0x42f370, 0x4b1510): rows of equal items with counts.

const fields = @import("../fields.zig");
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;
const item_mod = @import("item.zig");

/// Inventory tabs (0x42f370): weapons and ammo; medicine and armour; other (keys,
/// transmitter), shared by the party.
pub const Tab = enum { weapons, medicine, other };

fn tabOf(o: *Object) Tab {
    if (World.nativeOf(o).kind == .weapon) return .weapons;
    return switch (item_mod.typeOf(o)) {
        .ammo => .weapons,
        .medicine, .armor => .medicine,
        else => .other,
    };
}

/// List row: first item with this nameID and its count (ammo: sum of `counter`).
pub const Entry = struct { item: *Object, count: i32 };

/// Row limit. The exe lists are unbounded (0xc-byte heap nodes, 0x4b15b6 → 0x402950);
/// a smaller limit used to drop late items (the lab blaster) from the quick list.
pub const max_entries = 512;

/// Add an item, merging equal nameIDs (0x42f340, 0x4b14e0).
fn add(out: []Entry, n: *usize, o: *Object) void {
    const k: i32 = if (item_mod.typeOf(o) == .ammo) fields.counter(o) else 1;
    for (out[0..n.*]) |*e| if (fields.nameId(e.item) == fields.nameId(o)) {
        e.count += k;
        return;
    };
    if (n.* == out.len) return;
    out[n.*] = .{ .item = o, .count = k };
    n.* += 1;
}

/// Exe order: each weapon followed by its ammo (`ammoUsed`), then other ammo, then the
/// rest in original order.
fn weaponOrder(items: []Entry) void {
    var buf: [max_entries]Entry = undefined;
    if (items.len > buf.len) return;
    var used: [max_entries]bool = @splat(false);
    var n: usize = 0;
    for (items, 0..) |e, i| {
        if (World.nativeOf(e.item).kind != .weapon) continue;
        buf[n] = e;
        n += 1;
        used[i] = true;
        const ammo = e.item.getInt("ammoUsed");
        if (ammo <= 0) continue;
        for (items, 0..) |a, j| if (!used[j] and item_mod.typeOf(a.item) == .ammo and fields.nameId(a.item) == ammo) {
            buf[n] = a;
            n += 1;
            used[j] = true;
            break;
        };
    }
    for (items, 0..) |e, i| if (!used[i] and item_mod.typeOf(e.item) == .ammo) {
        buf[n] = e;
        n += 1;
        used[i] = true;
    };
    for (items, 0..) |e, i| if (!used[i]) {
        buf[n] = e;
        n += 1;
    };
    @memcpy(items, buf[0..n]);
}

/// Backpack items of a tab (0x42f370): `place` 1 only. Weapons/ammo (non-empty) and
/// medicine/armour are the hero's; "other" is the whole party's (owner not checked).
pub fn list(w: *World, hero: *Object, tab: Tab, out: []Entry) []Entry {
    var n: usize = 0;
    for (w.rt.objects.items) |o| {
        if (!world.isItem(o) or item_mod.placeOf(o) != .backpack or tabOf(o) != tab) continue;
        if (tab != .other and !fields.ownerIs(o, hero.name)) continue;
        if (item_mod.typeOf(o) == .ammo and fields.counter(o) <= 0) continue;
        add(out, &n, o);
    }
    if (tab == .weapons) weaponOrder(out[0..n]);
    return out[0..n];
}

/// Quick list (0x4b1510): the hero's backpack weapons, medicine and non-empty ammo, in
/// weapon-tab order. Deviation (player request): the exe also lists vests (`type` 30,
/// 0x4b1582) which can't be used from the list; we hide them.
pub fn shortList(w: *World, hero: *Object, out: []Entry) []Entry {
    var n: usize = 0;
    for (w.rt.objects.items) |o| {
        if (!world.isItem(o) or item_mod.placeOf(o) != .backpack) continue;
        if (!fields.ownerIs(o, hero.name)) continue;
        const t = item_mod.typeOf(o);
        const ok = t == .medicine or (t == .ammo and fields.counter(o) > 0) or World.nativeOf(o).kind == .weapon;
        if (ok) add(out, &n, o);
    }
    weaponOrder(out[0..n]);
    return out[0..n];
}

/// Quick-list scroll of `hero` (+0x32c4); the list window uses only these.
pub fn shortScroll(hero: *Object) usize {
    return World.nativeOf(hero).short_scroll;
}

pub fn setShortScroll(hero: *Object, v: usize) void {
    World.nativeOf(hero).short_scroll = v;
}

/// More than one unit at the hero (0x47d810): ammo, or another item with the same nameID
/// and owner — then giving asks for a count.
pub fn severalUnits(w: *World, item: *Object) bool {
    if (item_mod.typeOf(item) == .ammo) return true;
    for (w.rt.objects.items) |o| {
        if (o == item or !world.isItem(o) or fields.nameId(o) != fields.nameId(item)) continue;
        if (fields.ownerIs(o, fields.owner(item)) and o.getInt("place") > 0) return true;
    }
    return false;
}

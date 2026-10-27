//! Hand and armour slots, actor stance from the wielded weapon, armour protection.

const std = @import("std");
const fields = @import("../fields.zig");
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;
const item_mod = @import("item.zig");

fn ownedBy(o: *Object, hero: *Object) bool {
    return world.isItem(o) and fields.ownerIs(o, hero.name) and item_mod.placeOf(o) != .ground;
}

/// Put any item in the hand (quick list 0x4b1510, inventory 0x42dec0): the old one goes
/// to the backpack; stance follows the weapon.
pub fn toHand(w: *World, hero: *Object, item: *Object) void {
    if (equipped(w, hero, .hand)) |old| if (old != item) item_mod.setPlace(old, .backpack);
    item_mod.setPlace(item, .hand);
    setHoldState(w, hero, if (World.nativeOf(item).kind == .weapon) item else null);
}

/// Item in the hero's `place` slot.
pub fn equipped(w: *World, hero: *Object, place: item_mod.Place) ?*Object {
    for (w.rt.objects.items) |o| {
        if (ownedBy(o, hero) and item_mod.placeOf(o) == place) return o;
    }
    return null;
}

pub fn canEquip(o: *Object) bool {
    return World.nativeOf(o).kind == .weapon or item_mod.typeOf(o) == .armor;
}

/// Wield (weapon) or wear (armour); the previous item goes to the backpack.
pub fn equip(w: *World, hero: *Object, item: *Object) void {
    if (!canEquip(item)) return;
    const slot: item_mod.Place = if (World.nativeOf(item).kind == .weapon) .hand else .armor;
    if (equipped(w, hero, slot)) |old| item_mod.setPlace(old, .backpack);
    item_mod.setPlace(item, slot);
    if (slot == .hand) setHoldState(w, hero, item);
}

/// Actor stance (0x42b300): 0 by default; the weapon stance (1: `g_*` animations) only in
/// battle (combat level flag 0x696ea0) with a two-handed weapon this actor draws
/// (0x481f50). In battle 0/1 become 7/8 (0x42b450). Outside battle heroes walk unarmed.
pub fn setHoldState(w: *World, hero: *Object, weapon: ?*Object) void {
    const a = world.actorOf(hero);
    const combat = w.isCombat();
    const two = if (weapon) |wp| wp.getInt("two_handed") != 0 and
        weaponVisible(fields.nameId(hero), fields.nameId(wp)) else false;
    if (!a.holdState()) return; // keep special states (boat, defend, sleep)
    a.weapon_detached = false; // 0x42b305/0x42ac30: reattach
    const was = a.state;
    a.setState(@intFromBool(two and combat), combat);
    // Empty queue: switch to the new stance's idle at once, no blend (0x42b3a4 → 0x42b3af,
    // 0x422f90).
    if (a.state != was and !a.busy()) {
        a.instant = true;
        a.pickIdle(w.crt());
    }
}

/// Hero stance from the weapon in hand.
pub fn refreshHold(w: *World, hero: *Object) void {
    const hand = equipped(w, hero, .hand);
    setHoldState(w, hero, if (hand) |h| (if (World.nativeOf(h).kind == .weapon) h else null) else null);
}

/// The inventory leaves its hero (0x42dd40: closing, 0x42dd70, or showing another,
/// 0x42e27c): unless defending (+0x248f0), +0x31e8 = 1, stance (0x42b300: 0, the weapon's,
/// with an empty queue its idle at once, 0x42b3a4), then idle again (0x422f90) — that one
/// blends unless the stance's idle didn't play.
pub fn leaveInventory(w: *World, hero: *Object) void {
    if (w.battle) |*b| if (b.fighterOf(hero)) |i| if (b.fighters.items[i].defending) return;
    const a = world.actorOf(hero);
    a.instant = true;
    if (a.holdState()) a.setState(0, w.isCombat());
    refreshHold(w, hero);
    if (a.instant and a.queue.items.len == 0) a.pickIdle(w.crt());
    a.pickIdle(w.crt());
}

/// Stance of all heroes (level entry, load), and in battle of any actor holding a weapon
/// model: the exe sets it when an item goes into a non-hero owner's hand (0x4ad5df →
/// +0x3250; vtable +0x64 is 0 for fighters 0x421330, 1 for heroes 0x4923f0) and the item
/// has `meshFile` (+0x2ec, 0x4ad608 → 0x42b300). Monster weapons have no model.
pub fn refreshHoldStates(w: *World) void {
    const combat = w.isCombat();
    for (w.rt.objects.items) |o| {
        const n = World.nativeOf(o);
        if (n.kind != .actor) continue;
        if (n.hro) {
            refreshHold(w, o);
        } else if (combat) if (equipped(w, o, .hand)) |wp| {
            if (World.nativeOf(wp).kind == .weapon and fields.meshFile(wp).len > 0) setHoldState(w, o, wp);
        };
    }
}

/// The hero's worn armour (0x49125f).
pub fn armorItem(w: *World, hero: *Object) ?*Object {
    return equipped(w, hero, .armor);
}

/// Whether worn armour resists `code` (1–8, `battle/immunity`): the item's `pr*` field
/// (+0x378…+0x394).
pub fn armorProtects(w: *World, hero: *Object, code: @import("../battle.zig").immunity.Resist) bool {
    if (code == .armor) return false;
    const a = armorItem(w, hero) orelse return false;
    return a.getIntDyn(@import("../battle.zig").immunity.pr_fields[code.index()]) != 0;
}

/// Weapons a fighter doesn't draw in hand (table 0x5270a0, 0x481f50): fighter nameID →
/// weapon nameIDs.
const hidden_weapons = [_]struct { actor: i32, weapons: []const i32 }{
    .{ .actor = 29, .weapons = &.{ 34, 98, 1022, 1023, 1024, 1025, 1026, 1037, 1028, 1029 } },
    .{ .actor = 24, .weapons = &.{ 34, 1022, 1024, 1025, 1026, 1037, 1028, 1029 } },
};

pub fn weaponVisible(actor: i32, weapon: i32) bool {
    for (hidden_weapons) |h| if (h.actor == actor) {
        return std.mem.indexOfScalar(i32, h.weapons, weapon) == null;
    };
    return true;
}

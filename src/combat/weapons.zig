//! Fighter weapons: available list, ammo, default weapon, skill.

const std = @import("std");
const weapon_class = @import("../battle.zig").weapon_class;
const fields = @import("../fields.zig");
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;
const inventory = @import("../inventory.zig");
const rules = @import("../battle.zig").rules;
const Fighter = @import("../battle.zig").fighter.Fighter;

/// Fighter weapons: `.wpn`/Weapon_New objects with `Owner` = name; every hero
/// also has the fist (`place` 200, no owner).
pub fn weaponsOf(w: *World, f: Fighter, out: []*Object) []*Object {
    var n: usize = 0;
    for (w.rt.objects.items) |o| {
        if (World.nativeOf(o).kind != .weapon or World.nativeOf(o).deleted) continue;
        if (weapon_class.pattern(o) == null) continue;
        // Cheap owner check first, then ammo (scans every item).
        const owner = fields.owner(o);
        const mine = std.ascii.eqlIgnoreCase(owner, f.obj.name) or
            (f.side == .hero and owner.len == 0 and inventory.item.placeOf(o) == .party);
        if (!mine or n == out.len) continue;
        if (!hasAmmo(w, f, o)) continue;
        out[n] = o;
        n += 1;
    }
    return out[0..n];
}

/// Fighter weapons for the threat map (0x49af80, 0x49aff4…0x49b053): every enabled
/// weapon object (+0x6c) owned by exactly this fighter (+0x354, by name), wherever
/// it lies. The exe checks neither ammo nor recharge here, and the party's shared
/// fist (no owner, place 200) is not included.
pub fn threatWeaponsOf(w: *World, f: Fighter, out: []*Object) []*Object {
    var n: usize = 0;
    for (w.rt.objects.items) |o| {
        if (World.nativeOf(o).kind != .weapon or World.nativeOf(o).deleted) continue;
        if (weapon_class.pattern(o) == null) continue;
        if (!std.ascii.eqlIgnoreCase(fields.owner(o), f.obj.name) or n == out.len) continue;
        out[n] = o;
        n += 1;
    }
    return out[0..n];
}

/// Ammo (0x4ce250): `ammoUsed` 0 = none needed, −1 = thrown (the weapon itself is
/// spent), else the sum of `counter` of the owner's items with `nameID = ammoUsed`.
pub fn ammoLeft(w: *World, f: Fighter, wpn: *Object) ?i32 {
    const id = wpn.getInt("ammoUsed");
    if (id == 0 or id == -1) return null;
    return inventory.ammo.ammoCount(w, f.obj.name, id);
}

pub fn hasAmmo(w: *World, f: Fighter, wpn: *Object) bool {
    if (World.nativeOf(wpn).fight.recharge > 0) return false;
    return (ammoLeft(w, f, wpn) orelse 1) > 0;
}

/// Shot (0x4ce2c0): −1 round from the first pack; a thrown weapon disappears and
/// an identical one from the backpack takes its place.
pub fn consumeAmmo(w: *World, f: *Fighter, wpn: *Object) void {
    // Recharging weapons (0x4b7640 etc.) count turns instead of ammo. A strike
    // (0x4cf210, call +0xc8 at 0x4cf778) sets the full N; −1 only at the enemy turn
    // start (0x49844c), so a weapon fired on turn T is ready again on turn T+N and
    // the panel shows N, N−1 … 1.
    const rt = rules.rechargeTurns(wpn.getInt("classType"));
    if (rt > 0) World.nativeOf(wpn).fight.recharge = rt;
    const id = wpn.getInt("ammoUsed");
    if (id == 0) return;
    if (id == -1) {
        World.nativeOf(wpn).deleted = true;
        wpn.enabled = false;
        f.weapon = null;
        for (w.rt.objects.items) |o| {
            const nat = World.nativeOf(o);
            if (nat.kind != .weapon or nat.deleted or o == wpn) continue;
            if (fields.nameId(o) == fields.nameId(wpn) and fields.ownerIs(o, f.obj.name)) {
                f.weapon = o;
                if (f.side == .hero) inventory.equipment.equip(w, f.obj, o);
                return;
            }
        }
        f.weapon = defaultWeapon(w, f.*);
        return;
    }
    for (w.rt.objects.items) |o| {
        if (!world.isItem(o)) continue;
        if (fields.nameId(o) != id or !fields.ownerIs(o, f.obj.name)) continue;
        if (fields.counter(o) <= 0) continue;
        fields.setCounter(o, fields.counter(o) - 1);
        return;
    }
}

/// Default weapon: for a hero the one in hand or the fist; otherwise the one with the longest ray.
pub fn defaultWeapon(w: *World, f: Fighter) ?*Object {
    var list: [16]*Object = undefined;
    const ws = weaponsOf(w, f, &list);
    // Hero: the weapon in hand (place 11) if it has ammo; empty hand (or a non-weapon)
    // means the fist `gs_fist_all` (place 200). Nothing is put in the hand here: only
    // the inventory and the quick list change it.
    if (f.side == .hero) {
        if (inventory.equipment.equipped(w, f.obj, .hand)) |o| {
            if (std.mem.indexOfScalar(*Object, ws, o) != null) return o;
            // Recharging or out of ammo: stays in hand and the strike says "recharging" or
            // "No ammo" (0x47c2a2…0x47c3e5); the fist is not substituted.
            if (World.nativeOf(o).kind == .weapon and weapon_class.pattern(o) != null) return o;
        }
        for (ws) |o| if (inventory.item.placeOf(o) == .party and fields.owner(o).len == 0) return o;
    }
    var best: ?*Object = null;
    var best_len: usize = 0;
    for (ws) |o| {
        const pat = weapon_class.pattern(o).?;
        if (best == null or pat.rays.len > best_len) {
            best = o;
            best_len = pat.rays.len;
        }
    }
    return best;
}

/// Uses until the next skill level (0x528c8c, levels 0..10).
const skill_thresholds = [_]i32{ 0, 2, 4, 6, 9, 12, 15, 19, 23, 28, 1000000 };

/// A hero uses a weapon (0x48fea0): no entry means level 1, count 0; then count
/// +1, and reaching the level threshold gives level +1 (true).
pub fn growSkill(w: *World, hero: *Object, id: i32) !bool {
    const skills = &World.nativeOf(hero).growth.skills;
    const sk = for (skills.items) |*s| {
        if (s.id == id) break s;
    } else blk: {
        try skills.append(w.gpa, .{ .id = id, .level = 1 });
        break :blk &skills.items[skills.items.len - 1];
    };
    if (sk.level <= 0) return false;
    sk.count += 1;
    const lvl: usize = @intCast(@min(sk.level, skill_thresholds.len - 1));
    if (sk.count < skill_thresholds[lvl]) return false;
    sk.level += 1;
    return true;
}

/// Weapon skill in percent (0x48fe10): level × 10, 100 without a skill.
pub fn skillOf(f: Fighter, wpn: *Object) i32 {
    const id = fields.nameId(wpn);
    if (f.side != .hero) return rules.skillPercent(null, false);
    for (World.nativeOf(f.obj).growth.skills.items) |s| if (s.id == id) return rules.skillPercent(s.level, true);
    return rules.skillPercent(null, true);
}

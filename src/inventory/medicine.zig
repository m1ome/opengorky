//! Medicine (0x48ff50): effects by nameID, MacFadden's bonus, out-of-battle heal.

const std = @import("std");
const fields = @import("../fields.zig");
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;
const Rand = @import("../crt_rand.zig").Rand;
const popup_mod = @import("../popup.zig");
const item_mod = @import("item.zig");

/// Medicine effect (0x48ff50) by nameID: 1043 Drugs = rage + heal, 83 Painkiller = calm +
/// heal, 1044 = cure gas only, 1047 = wake only, others heal. Unknown drugs (1049) act as
/// one of {1045, 1047, 1044, 1043} (0x48ff76: rand & 3).
const Medicine = enum { heal, rage, calm, ungas, wake };

fn medicineKind(name_id: i32, rand: *Rand) Medicine {
    const id = if (name_id == 1049) ([_]i32{ 1045, 1047, 1044, 1043 })[rand.below(4)] else name_id;
    return switch (id) {
        1043 => .rage,
        83 => .calm,
        1044 => .ungas,
        1047 => .wake,
        else => .heal,
    };
}

/// Heal bonus (0x48ffee): when MacFadden (nameID 24) heals, ⌊hp × 0.15⌋ (0x50a218).
fn healBonus(healer_id: i32, hp: i32) i32 {
    if (healer_id != 24) return 0;
    return @intFromFloat(@floor(@as(f64, @floatFromInt(hp)) * 0.15));
}

/// Plain heal: item `hp`, capped at `max_hp`; consumes the item. False if not medicine.
/// No special effects — for gorky-tool `heal`; the game uses `medicine`.
pub fn use(hero: *Object, item: *Object) bool {
    if (item_mod.typeOf(item) != .medicine) return false;
    const hp = @min(fields.maxHp(hero), fields.hp(hero) + fields.hp(item));
    fields.setHp(hero, hp);
    item_mod.consume(item);
    return true;
}

/// Medicine `item` used by `healer` on `target` (0x48ff50). Item `hp` 0 only plays the
/// sound (gas antidote, 0x48ff66); otherwise the effect by nameID (`medicineKind`)
/// and, for rage, Painkiller and plain heals, hp + MacFadden's bonus (0x48ffee) capped at
/// max_hp (0x4900b5). health2 plays only for males (`sex` 0, +0x24580; 0x4900cb). Battle
/// states (rage, gas, sleep) are handled by combat. The item is not consumed.
pub fn medicine(self: *World, healer: ?*Object, target: *Object, item: *Object) !?Healed {
    defer if (target.getInt("sex") == 0)
        self.out.sound(self.gpa, "health2", self.screenPos(target));
    const hp = fields.hp(item);
    if (hp == 0) return null;
    var h: Healed = .{ .kind = medicineKind(fields.nameId(item), self.crt()) };
    if (h.kind == .ungas or h.kind == .wake or hp < 0) return h;
    h.hp = hp;
    h.bonus = healBonus(if (healer) |o| fields.nameId(o) else -1, hp);
    fields.setHp(target, @min(fields.maxHp(target), fields.hp(target) + hp + h.bonus));
    return h;
}

/// Heal popup (0x492170): "hp" or "hp+bonus" ("%d+%d"), colour cfcHpGain.
pub fn healText(buf: []u8, h: Healed) []const u8 {
    return (if (h.bonus > 0) std.fmt.bufPrint(buf, "{d}+{d}", .{ h.hp, h.bonus }) else std.fmt.bufPrint(buf, "{d}", .{h.hp})) catch "";
}

/// Out-of-battle heal (0x450c6c → 0x47b900): `hero` uses medicine `item` (type 20) on
/// `target` by clicking the hero or his portrait. Runs 0x48ff50 (`medicine`) with a popup
/// if it healed; then the item leaves the hand (0x42b2d0) and is destroyed (+0x60) even
/// without effect, and the mode closes (0x450cc4 → 0x450e80). No animation. Rage, sleep
/// and gas need a battle fighter (recreated per battle, 0x48e0a0).
pub fn healWith(self: *World, hero: *Object, target: *Object, item: *Object) !void {
    if (item_mod.typeOf(item) != .medicine) return;
    if (try medicine(self, hero, target, item)) |h| if (h.hp > 0) {
        var buf: [24]u8 = undefined;
        try self.popups.append(self.gpa, popup_mod.Popup.make(fields.pos(target), healText(&buf, h), .heal));
    };
    item_mod.consume(item);
    self.mouse.use = null;
}

/// Medicine result (0x48ff50): effect, item `hp` and MacFadden's bonus (0 = no heal).
const Healed = struct { kind: Medicine, hp: i32 = 0, bonus: i32 = 0 };

test "medicine kinds and MacFadden's bonus follow 0x48ff50" {
    var rr: Rand = .{};
    const r = &rr;
    try std.testing.expectEqual(Medicine.rage, medicineKind(1043, r));
    try std.testing.expectEqual(Medicine.calm, medicineKind(83, r));
    try std.testing.expectEqual(Medicine.ungas, medicineKind(1044, r));
    try std.testing.expectEqual(Medicine.wake, medicineKind(1047, r));
    try std.testing.expectEqual(Medicine.heal, medicineKind(1045, r));
    try std.testing.expectEqual(Medicine.heal, medicineKind(71, r));
    // Unknown drugs: exactly four outcomes, all seen.
    var seen: [5]bool = @splat(false);
    for (0..64) |_| seen[@backingInt(medicineKind(1049, r))] = true;
    try std.testing.expect(seen[@backingInt(Medicine.heal)] and seen[@backingInt(Medicine.rage)] and
        seen[@backingInt(Medicine.ungas)] and seen[@backingInt(Medicine.wake)] and !seen[@backingInt(Medicine.calm)]);
    try std.testing.expectEqual(@as(i32, 6), healBonus(24, 40));
    try std.testing.expectEqual(@as(i32, 15), healBonus(24, 100));
    try std.testing.expectEqual(@as(i32, 0), healBonus(1, 100));
}

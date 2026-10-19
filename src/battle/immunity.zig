//! Monster resistances (table 0x6d2070, filled at 0x4c91c0; check 0x4caa80): by
//! fighter `nameID`, immunity to codes 1–8 and armour class (code 9).
//! Codes: 1 fire, 2 electricity, 3 decoy (Dist), 4 energy, 5 cold,
//! 6 tranquilizer, 7 gas, 8 fuel, same as the hero armour `pr*` fields.
//! The table was extracted by emulating 0x4c91c0 (35 entries).

const std = @import("std");

const Entry = struct { id: i32, flags: [8]u1, armor: i32 };

/// Resistance code (table 0x6d2070 flag; 9 is armour class, discovery bit only).
pub const Resist = enum(u4) {
    fire = 1,
    electricity = 2,
    /// Decoy (Dist).
    attract = 3,
    energy = 4,
    freeze = 5,
    tranq = 6,
    gas = 7,
    flammable = 8,
    /// Armour class (0x4caaf7): discovery bit only.
    armor = 9,

    pub fn index(r: Resist) usize {
        return @backingInt(r) - 1;
    }
};

/// Weapon damage kind, the .wpn `type` field (parsed at 0x491056…0x49120f).
/// Kinds without a resistance (bullets, blades, blast) hit everyone.
pub const DamageType = enum(i32) {
    fire = 1,
    freeze = 2,
    electricity = 3,
    gas = 5,
    bullet = 6,
    melee = 7,
    tranq = 9,
    energy = 11,
    attract = 12,
    explosion = 13,
    flammable = 14,
    _,

    pub fn from(t: i32) DamageType {
        return @fromBackingInt(@intCast(t));
    }
};

pub const table = [_]Entry{
    .{ .id = 125, .flags = .{ 0, 0, 1, 0, 0, 1, 1, 0 }, .armor = -2 },
    .{ .id = 105, .flags = .{ 1, 0, 0, 0, 0, 0, 0, 0 }, .armor = -2 },
    .{ .id = 107, .flags = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .armor = -3 },
    .{ .id = 124, .flags = .{ 0, 1, 1, 1, 1, 0, 1, 1 }, .armor = -3 },
    .{ .id = 101, .flags = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .armor = -2 },
    .{ .id = 113, .flags = .{ 0, 0, 1, 0, 0, 0, 1, 0 }, .armor = -2 },
    .{ .id = 114, .flags = .{ 0, 0, 1, 0, 0, 0, 0, 0 }, .armor = -1 },
    .{ .id = 131, .flags = .{ 0, 0, 1, 1, 0, 1, 0, 0 }, .armor = -3 },
    .{ .id = 122, .flags = .{ 0, 0, 1, 1, 0, 1, 0, 0 }, .armor = -3 },
    .{ .id = 118, .flags = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .armor = -2 },
    .{ .id = 128, .flags = .{ 0, 0, 0, 0, 0, 0, 1, 0 }, .armor = -2 },
    .{ .id = 108, .flags = .{ 0, 0, 0, 1, 0, 0, 0, 0 }, .armor = -1 },
    .{ .id = 138, .flags = .{ 0, 0, 1, 1, 0, 1, 1, 0 }, .armor = -3 },
    .{ .id = 120, .flags = .{ 1, 1, 1, 1, 1, 1, 1, 1 }, .armor = -2 },
    .{ .id = 100, .flags = .{ 1, 0, 0, 1, 0, 0, 0, 0 }, .armor = -2 },
    .{ .id = 115, .flags = .{ 0, 0, 1, 0, 0, 0, 0, 0 }, .armor = -2 },
    .{ .id = 116, .flags = .{ 0, 0, 1, 0, 0, 0, 0, 0 }, .armor = -1 },
    .{ .id = 129, .flags = .{ 0, 0, 1, 0, 0, 1, 0, 0 }, .armor = -2 },
    .{ .id = 135, .flags = .{ 0, 0, 1, 0, 0, 1, 0, 0 }, .armor = -2 },
    .{ .id = 137, .flags = .{ 0, 0, 1, 0, 0, 1, 0, 0 }, .armor = -2 },
    .{ .id = 119, .flags = .{ 0, 0, 1, 1, 0, 1, 0, 0 }, .armor = -2 },
    .{ .id = 139, .flags = .{ 1, 0, 1, 0, 1, 1, 1, 0 }, .armor = -2 },
    .{ .id = 130, .flags = .{ 0, 1, 0, 1, 0, 0, 0, 0 }, .armor = -2 },
    .{ .id = 121, .flags = .{ 1, 0, 0, 0, 1, 0, 1, 1 }, .armor = -1 },
    .{ .id = 132, .flags = .{ 1, 0, 1, 0, 0, 0, 0, 0 }, .armor = -3 },
    .{ .id = 106, .flags = .{ 0, 1, 0, 0, 0, 0, 0, 0 }, .armor = -1 },
    .{ .id = 126, .flags = .{ 0, 0, 0, 1, 1, 1, 0, 0 }, .armor = -3 },
    .{ .id = 136, .flags = .{ 0, 0, 1, 0, 1, 0, 1, 1 }, .armor = -3 },
    .{ .id = 117, .flags = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .armor = -2 },
    .{ .id = 109, .flags = .{ 0, 1, 0, 0, 0, 0, 0, 0 }, .armor = -1 },
    .{ .id = 123, .flags = .{ 1, 1, 0, 0, 0, 0, 0, 1 }, .armor = -3 },
    .{ .id = 110, .flags = .{ 1, 1, 1, 1, 1, 0, 1, 1 }, .armor = -2 },
    .{ .id = 102, .flags = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .armor = -1 },
    .{ .id = 133, .flags = .{ 0, 0, 1, 0, 0, 1, 1, 0 }, .armor = -3 },
    .{ .id = 127, .flags = .{ 1, 0, 1, 1, 0, 0, 0, 0 }, .armor = -2 },
};

/// Hero armour `pr*` fields by code (item offsets +0x378…+0x394).
pub const pr_fields = [8][]const u8{ "prFire", "prElect", "prDist", "prEnergy", "prFreeze", "prTranq", "prGas", "prFlam" };

/// Discovered resistances (the exe stores 2 in the same table, 0x4caa80): bit
/// `code` (1–9) per `table` entry, plus the generic fighters' entries (`extra`,
/// mods only, registered on battle entry). One per game (game.Game); `table`
/// bits go into saves.
pub const Known = struct {
    table: [table.len]u16 = @splat(0),
    extra: [32]u16 = @splat(0),
    entries: [32]Entry = undefined,
    n: usize = 0,

    fn extraIndex(self: *const Known, name_id: i32) ?usize {
        for (self.entries[0..self.n], 0..) |e, i| if (e.id == name_id) return i;
        return null;
    }

    fn slot(self: *Known, name_id: i32) ?*u16 {
        if (index(name_id)) |i| return &self.table[i];
        if (self.extraIndex(name_id)) |i| return &self.extra[i];
        return null;
    }

    /// Mark a code discovered; true the first time (show the popup).
    pub fn discover(self: *Known, name_id: i32, code: Resist) bool {
        const k = self.slot(name_id) orelse return false;
        const bit = @as(u16, 1) << @backingInt(code);
        if (k.* & bit != 0) return false;
        k.* |= bit;
        return true;
    }

    pub fn isKnown(self: *Known, name_id: i32, code: Resist) bool {
        const k = self.slot(name_id) orelse return false;
        return k.* & (@as(u16, 1) << @backingInt(code)) != 0;
    }

    fn find(self: *const Known, name_id: i32) ?Entry {
        for (table) |e| if (e.id == name_id) return e;
        for (self.entries[0..self.n]) |e| if (e.id == name_id) return e;
        return null;
    }

    /// Generic fighter entry (classType 100): `resist` — words
    /// separated by commas or spaces ("fire, gas"); `armor_class`: 0 none,
    /// 1 light, 2 medium, 3 heavy. Re-registering a nameID replaces its entry;
    /// exe table ids are left alone.
    pub fn register(self: *Known, name_id: i32, resist: []const u8, armor_class: i32) void {
        if (index(name_id) != null) return;
        var e: Entry = .{ .id = name_id, .flags = @splat(0), .armor = -std.math.clamp(armor_class, 0, 3) };
        var it = std.mem.tokenizeAny(u8, resist, ", ;\t");
        while (it.next()) |w| if (codeOfWord(w)) |c| {
            e.flags[c.index()] = 1;
        };
        if (self.extraIndex(name_id)) |i| {
            self.entries[i] = e;
            return;
        }
        if (self.n == self.entries.len) return;
        self.entries[self.n] = e;
        self.n += 1;
    }

    /// Monster `name_id` resists `code` (armour class `.armor` is not a resistance).
    pub fn immune(self: *const Known, name_id: i32, code: Resist) bool {
        const e = self.find(name_id) orelse return false;
        return code != .armor and e.flags[code.index()] != 0;
    }

    /// Armour class by table: 0 light, 1 medium, 2 heavy (|value| − 1).
    pub fn armorClass(self: *const Known, name_id: i32) ?i32 {
        const e = self.find(name_id) orelse return null;
        if (e.armor == 0) return null;
        return @as(i32, @intCast(@abs(e.armor))) - 1;
    }
};

/// Popups on discovery: string.tab 801–808 and 571–573 (armour class).
pub const protection_text = [8][]const u8{ "Fire protection", "Electricity protection", "Attracting protection", "Energy protection", "Freezing protection", "Tranquilizing protection", "Poison protection", "Flammable protection" };
pub const armor_text = [3][]const u8{ "Light Armor", "Medium Armor", "Heavy Armor" };

fn index(name_id: i32) ?usize {
    for (table, 0..) |e, i| if (e.id == name_id) return i;
    return null;
}

/// `resist` word → resistance code (1–8).
fn codeOfWord(word: []const u8) ?Resist {
    const names = [_]struct { []const u8, Resist }{
        .{ "fire", .fire },     .{ "electricity", .electricity }, .{ "elect", .electricity }, .{ "shock", .electricity },
        .{ "decoy", .attract }, .{ "attract", .attract },         .{ "energy", .energy },     .{ "freeze", .freeze },
        .{ "cold", .freeze },   .{ "tranq", .tranq },             .{ "sleep", .tranq },       .{ "gas", .gas },
        .{ "poison", .gas },    .{ "flammable", .flammable },     .{ "flame", .flammable },
    };
    for (names) |n| if (std.ascii.eqlIgnoreCase(word, n[0])) return n[1];
    return null;
}

/// Resistance to the weapon damage kind (`type`, 0x491056…0x49120f).
pub fn damageCode(t: DamageType) ?Resist {
    return switch (t) {
        .fire => .fire,
        .electricity => .electricity,
        .attract => .attract,
        .energy => .energy,
        .freeze => .freeze,
        .tranq => .tranq,
        .gas => .gas,
        .flammable => .flammable,
        else => null,
    };
}

/// Resistance code for the weapon's state effect (0x4900f0): fire, cold, gas, fuel, sleep.
pub fn effectCode(kind: @import("rules.zig").Effect) ?Resist {
    return switch (kind) {
        .burn => .fire,
        .freeze => .freeze,
        .gas => .gas,
        .soak => .flammable,
        .sleep => .tranq,
        else => null,
    };
}

test "generic fighter resistances" {
    var k: Known = .{};
    k.register(2001, "fire, gas", 2);
    try std.testing.expect(k.immune(2001, .fire) and k.immune(2001, .gas) and !k.immune(2001, .freeze));
    try std.testing.expectEqual(@as(?i32, 1), k.armorClass(2001));
    try std.testing.expect(k.discover(2001, .fire) and !k.discover(2001, .fire));
    k.register(120, "", 0); // exe entries are not replaced
    try std.testing.expect(k.immune(120, .fire));
}

test "invisible is immune to everything, incubus wears heavy armor" {
    const k: Known = .{};
    try std.testing.expect(k.immune(120, .fire) and k.immune(120, .flammable));
    try std.testing.expectEqual(@as(?i32, 2), k.armorClass(138));
    try std.testing.expect(!k.immune(100, .freeze));
}

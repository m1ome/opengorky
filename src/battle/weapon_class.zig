//! Weapon class (`classType` in .wpn and cw_*.s / wp_*.ss classes): the factory
//! 0x4b4c00 picks the weapon subclass by it (tables 0x4b5d24 for 1…25, 0x4b5d84
//! for 101…, 0x4b5dec for 1001…). Tile patterns are in `patterns.zig`, subclass
//! properties in `rules.zig`. Values outside the list are allowed (`_`).

const Object = @import("../script.zig").object.Object;
const patterns = @import("patterns.zig");

/// Tile pattern of a weapon object (by its `classType`).
pub fn pattern(o: *Object) ?*const patterns.Weapon {
    return patterns.find(o.getInt("classType"));
}

pub const WeaponClass = enum(i32) {
    // Hero weapons (0x4b5d24).
    pistol = 1,
    rifle = 2,
    dartgun = 3,
    flame_thrower = 4,
    rocket_launcher = 5,
    ion_rifle = 6,
    /// Blaster; Grandma's and the NATO captain's weapons share this subclass.
    blaster = 7,
    /// Satellite: beam, lightning, rocket (1038–1040); any tile of the field.
    satellite = 8,
    time_bomb = 9,
    /// Melee: axe, bat, bayonet, crowbar, hammer, knuckles, stiletto.
    melee = 10,
    /// Grenade, explosives.
    grenade = 11,
    knife_throwing = 12,
    chaingun = 13,
    shotgun = 14,
    molotov = 15,
    napalm = 16,
    /// Barrel blast (wp_barrel_explode).
    barrel = 17,
    /// Decoy (attracting device, distractor).
    decoy = 18,
    nitrogen = 19,
    /// Petrol and vodka.
    bottle = 20,
    matches = 21,
    stun_bomb = 22,
    gas_grenade = 23,
    shocker = 24,
    // Monster weapons (0x4b5d84).
    garcia_short = 101,
    garcia_long = 102,
    hound_short = 103,
    invisible = 104,
    jetelmer_short = 105,
    jetelmer_long = 106,
    needle = 107,
    rc28_short = 108,
    sphinx_short = 109,
    siner_short = 110,
    squeaker = 111,
    cutterpill_short = 112,
    fang_long = 113,
    harvester = 114,
    headnail = 115,
    hornet = 116,
    lilith = 117,
    lucy_short = 118,
    lucy_long = 119,
    paingod = 120,
    reverend_insect = 121,
    sister_of_mercy = 122,
    medusa_short = 123,
    medusa_long = 124,
    /// Invisible's bite in 04__city_mfd (04mf_invisible1_a): incurable poison.
    invisible_mfd = 125,
    /// Allies' pistol (Kozov, Lamar).
    ally_pistol = 126,
    /// NATO and special forces rifle.
    ally_rifle = 127,
    // Special fighters' weapons (0x4b5dec).
    smokerider_gun = 1001,
    grandma_mad = 1002,
    grandma_child = 1003,
    stinger_short = 1004,
    stinger_long = 1005,
    fatman_short = 1006,
    fatman_long = 1007,
    incubus = 1008,
    cripple = 1009,
    puppet = 1010,
    guard3 = 1011,
    guard1 = 1012,
    guard2 = 1013,
    judge_short = 1014,
    judge_child = 1015,
    schizo1 = 1016,
    schizo2 = 1017,
    schizo3 = 1018,
    messiah_left = 1019,
    messiah_right = 1020,
    _,

    pub fn of(o: *Object) WeaponClass {
        return @fromBackingInt(@intCast(o.getInt("classType")));
    }

    pub fn from(class: i32) WeaponClass {
        return @fromBackingInt(@intCast(class));
    }
};

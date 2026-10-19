//! Native part of location objects (what the exe keeps in its C++ class) and its kind,
//! chosen by the script file extension.

const std = @import("std");
const actor_mod = @import("../actor.zig");
const fight_obj = @import("../battle.zig").obj;

/// Native part of a location object by file extension.
pub fn nativeFor(ext: []const u8) Native {
    const ieq = std.ascii.eqlIgnoreCase;
    return .{
        .kind = kindOf(ext),
        .hro = ieq(ext, ".hro"),
        .fighter = ieq(ext, ".hro") or ieq(ext, ".ftr"),
        .obstacle = ieq(ext, ".obs") or ieq(ext, ".obs_i"),
    };
}

pub const Kind = enum {
    level,
    animation,
    active_animation,
    area,
    item,
    actor,
    /// Weapon (`.wpn`, Weapon_New); owner in the `Owner` variable.
    weapon,
    /// Looping positional sound created by `Ambient_New`.
    ambient,
    other,

    /// Script hooks the engine calls for this kind. level/animation checked against the
    /// exe vtables; the rest inferred from which functions scripts define (unverified).
    pub fn hooks(self: Kind) struct { update: bool, restore: bool, post_init: bool } {
        return switch (self) {
            .level => .{ .update = true, .restore = true, .post_init = true },
            .animation, .active_animation => .{ .update = true, .restore = true, .post_init = false },
            .actor => .{ .update = true, .restore = false, .post_init = true },
            .area, .item, .weapon, .other => .{ .update = false, .restore = false, .post_init = true },
            .ambient => .{ .update = false, .restore = false, .post_init = false },
        };
    }
};

/// Weapon skill (+0x24644, 12-byte records): weapon nameID, level, use count (0x48fea0).
pub const Skill = struct { id: i32, level: i32, count: i32 = 0 };

/// Native part of an object (what the exe keeps in its C++ class).
pub const Native = struct {
    kind: Kind,
    /// Animation accumulator (`acc` in 0x4b3c50).
    acc: i32 = 0,
    /// `allowRender()` result after the last tick.
    visible: bool = true,
    deleted: bool = false,
    /// Battle obstacle (`.obs` barrels/crates, `.obs_i` item crates; 0x4bd780, 0x4bd830):
    /// a fighter actor that never moves and is not an enemy.
    obstacle: bool = false,
    /// Party hero (from `gamestart`), shared by all locations.
    hero: bool = false,
    /// Hero object (`.hro`): in the exe's global hero list, alive across locations even
    /// outside the party (Medusa, Slavsky, Hutchens).
    hro: bool = false,
    /// Fighter (`.hro`, `.ftr`, `gamestart` heroes): made by the fighter factory (0x4bc6c0),
    /// `+0x80` = 1 (0x4923e0). On leaving it is not stored with the location (0x411c40) but
    /// moves on in the global list; its queue is reset (0x427c50) and its position kept as a
    /// shadow (0x42af20).
    fighter: bool = false,
    /// Came from the party when the location was created (+0x74, global-list object);
    /// post_init is not called (0x4319c4…0x4319cf).
    from_party: bool = false,
    /// ABA_MOVE (0x4b4470, 0x4b4510): smooth background-animation move (lift): start,
    /// target, step and path parameter t (0…1).
    aba_move: ?struct { from: [2]i32, to: [2]i32, step: f32, t: f32 } = null,
    /// `.ambient`: sound file and background point.
    ambient: ?struct { wav: []const u8, pos: [2]f32 } = null,
    /// Actors (`.act`, `gamestart\*.hro` heroes).
    actor: actor_mod.Actor = .{},
    /// Per-object battle fields (battle/obj.zig).
    fight: fight_obj.Fight = .{},
    /// Hero development (weapon skills, unspent level points).
    growth: Growth = .{},
    /// Hero quick-list scroll (+0x32c4).
    short_scroll: usize = 0,
};

/// Hero development, written by level-up and skill code.
const Growth = struct {
    /// Weapon skills (FighterSetWeaponSkillLevel): weapon nameID → level.
    skills: std.ArrayList(Skill) = .empty,
    /// Unspent level-up points (5 per level, 0x48fa30).
    stat_points: i32 = 0,
};

/// Kind comes from the script extension (base classes are often `#include`d rather
/// than `#inherit`ed).
pub fn kindOf(ext: []const u8) Kind {
    const table = .{
        .{ ".lev", Kind.level },   .{ ".ba", Kind.animation }, .{ ".aba", Kind.active_animation },
        .{ ".are", Kind.area },    .{ ".itm", Kind.item },     .{ ".obs", Kind.actor },
        .{ ".obs_i", Kind.actor }, .{ ".act", Kind.actor },    .{ ".ftr", Kind.actor },
        .{ ".hro", Kind.actor },   .{ ".wpn", Kind.weapon },
    };
    inline for (table) |t| if (std.ascii.eqlIgnoreCase(ext, t[0])) return t[1];
    return .other;
}

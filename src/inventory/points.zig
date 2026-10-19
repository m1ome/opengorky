//! Level points window (0x48fa30, 0x4b0bc0).

const num = @import("../num.zig");
const fields = @import("../fields.zig");
const World = @import("../state.zig").world.World;
const Object = @import("../script.zig").object.Object;

/// Takes the hero's unspent level points for the points window (0x48fa30).
pub fn takeLevelPoints(hero: *Object) i32 {
    const nat = World.nativeOf(hero);
    const n = nat.growth.stat_points;
    nat.growth.stat_points = 0;
    return n;
}

/// Accept in the points window (0x4b0bc0): rows 1 max_hp, 3 luck, 4 accuracy,
/// 5 counterattack, 6 max_rage get their points; hp itself is unchanged (the
/// getters 0x48fbc0… scale the max only).
pub fn applyLevelPoints(hero: *Object, pts: [7]i32) void {
    const f = fields.getF;
    hero.setInt("max_hp", fields.maxHp(hero) + pts[1]);
    fields.setF(hero, "luck", f(hero, "luck") + num.toF32(pts[3]));
    fields.setF(hero, "accuracy", f(hero, "accuracy") + num.toF32(pts[4]));
    fields.setF(hero, "counterAttack", f(hero, "counterAttack") + num.toF32(pts[5]));
    hero.setInt("max_rage", hero.getInt("max_rage") + pts[6]);
}

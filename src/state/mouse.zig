//! Mouse mode: what a field/portrait click does and which cursor shows. In the exe
//! these are separate GUI modes: "Use/Heal … on …" (0x450ce0, battle 0x453cf5),
//! give (0x450770, battle 0x4536e0), push (0x452aa0), aim (0x4524d0) and facing
//! (0x452ea0). Several can be set at once; `mode` picks the active one in the same
//! order as click handling and the cursor.

const Object = @import("../script.zig").object.Object;

const Mode = enum { normal, push, use, give, facing, aim };

pub const Mouse = struct {
    /// Item for "Use/Heal … on …" (quick list, inventory, console `pick`).
    use: ?*Object = null,
    /// Item to give (Give button, quick list).
    give: ?*Object = null,
    /// Push (button 4, key P): click an obstacle cell.
    push: bool = false,
    /// Battle aim (right button): attack and effect cells.
    aim: bool = false,

    /// Active mode. Same order as the cursor: push (battle only), use, give, facing
    /// (Battle.facing_mode), aim.
    pub fn mode(self: Mouse, in_battle: bool, facing: bool) Mode {
        if (self.push and in_battle) return .push;
        if (self.use != null) return .use;
        if (self.give != null) return .give;
        if (facing) return .facing;
        if (self.aim) return .aim;
        return .normal;
    }

    /// Item or push mode: cross of cells around the hero instead of the walk range (0x453b70).
    pub fn cross(self: Mouse) bool {
        return self.use != null or self.push or self.give != null;
    }
};

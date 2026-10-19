//! Per-object battle fields (`state.object.Native.fight`). Pure data: the world stores
//! them on every object, combat reads and writes them.

pub const Fight = struct {
    /// Time bomb: turns until it explodes (large PutLargeTimeBomb 6, hero bomb 2:
    /// 0x4bdf83, 0x4bdc93).
    bomb_timer: ?i32 = null,
    /// Weapon recharge (+0x1ab4 of WeaponFlameThrower etc.): turns until ready. Set to
    /// the full `rules.rechargeTurns` after a strike (0x4cf778), −1 at the start of the
    /// enemy turn, 0 at battle start.
    recharge: i32 = 0,
    /// Decoy (Distractor): a neutral device fighter on its tile (`Battle.decoys`).
    decoy: bool = false,
    /// AIEnemyAppear: the fighter walks from `from` (may be off-grid) to `to`.
    appear: ?struct { from: [2]i32, to: [2]i32 } = null,
    /// AITargetLock: name of the only target (aiMode 1).
    target_lock: []const u8 = "",
    /// AIGuardPoint: tile to guard (aiMode 3).
    guard_point: ?[2]i32 = null,
};

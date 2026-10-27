//! Actor command queue and walking data: queued commands, battle walk, path node events,
//! meshes on link points.

/// An `.ap` path node: call `NodeResponse(no, dir)` of the `<path>.pth` script.
pub const NodeEvent = struct { path: u16, no: u16, dir: u8 };

/// Battle walking (`Actor.battle_walk`).
pub const BattleWalk = struct {
    /// Actor position when the path was set (+0x2456c at 0x48f4e8): turn angles are
    /// measured from it, not from the previous cell.
    origin: [2]f32,
    /// Walk animation: starts after the first turn (0x422ea0).
    anim: []const u8,
    /// Walking started (+0x30dc): further turns without "stepping".
    started: bool = false,
    /// A turn in place before the current segment is running.
    turning: bool = false,
};

/// Mesh on an attachment point (ActivateLink); `anim` is the mesh's one-shot animation
/// (0x48d760 → 0x44f910: "obrot" of Headnail's saw), from world tick `anim_from`;
/// `blend`: it began with the transition from the mesh's frame 0 (the player's first
/// animation; a replay of the ended one restarts without it, 0x44f989).
pub const Link = struct { link: []const u8, mesh: []const u8, anim: []const u8 = "", anim_from: u64 = 0, blend: bool = false };

pub const Command = union(enum) {
    /// One-shot animation (logical name), then idle.
    anim: []const u8,
    /// Idle of the current state.
    idle,
    /// Pause in ticks.
    delay: u32,
    /// Object function with the actor name as the argument.
    call: struct { object: []const u8, func: []const u8 },
    /// Async animation (command 0x14): the queue moves on at once.
    async_anim: struct { name: []const u8, reverse: bool },
    /// Scene animation (ANIMATION, command 0x13 with a raw name): `count` times,
    /// `reverse` plays it backwards; the queue waits for it to end.
    /// `logical`: the name resolves by RegisterAnimation when the command runs (command
    /// 0x13 with flag +0x24, 0x423d88: SYSTEMANIMATION, USEANIMATION).
    scene_anim: struct { name: []const u8, count: u8 = 1, reverse: bool = false, logical: bool = false },
    /// Idle (IDLE_ANIMATION, command 0x27).
    idle_anim: []const u8,
    /// Walk animation and speed (WALK_ANIMATION, command 0x28); null — normal.
    walk_anim: struct { name: []const u8, speed: ?f32 },
    /// Walk to a background point (WALKTO); the queue waits for arrival.
    walk: [2]f32,
    /// Turn to an angle (command 0x12, 0x427340 after a path with angle ≥ 0) — immediate.
    angle: f32,
    /// The next animation without the blend (command 0x18, 0x424256 → +0x31e8).
    no_blend,
    /// Actor_QueueJustifyPosition (command 0x24, 0x4240b7): shift the position by the drawn
    /// root bone minus the current animation's last frame, then no blend.
    justify,
    /// Actor_QueuePlace (command 0x25, 0x42421e → 0x422b70): onto area point `index`
    /// (floor 0), then no blend.
    place: struct { area: []const u8, index: i32 },
    /// Hold state (command 0x22, 0x424044): state 4 first drops the links (+0x30d0 = 0),
    /// then 0x42b450 (4 also picks the idle).
    state: u8,
    /// All links off (command 0x21, 0x424033: +0x30d0 = 0) — the weapon leaves the hand.
    unlink,
    /// Mesh on a link point (command 0x20, 0x424009 → 0x42ac30).
    link: struct { link: []const u8, mesh: []const u8 },
    /// Wait until the animation blend ends (command 0x1d, 0x424e5f: +0x245a1 != 2).
    wait_blend,
    /// IDLE_ON / IDLE_OFF (command 0x26, 0x424264: +0x30ec = arg == 0): idle picks on/off.
    idle_enable: bool,
};

pub const Fx = enum { none, shock, appear, vanish };

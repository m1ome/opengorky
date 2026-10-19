//! Actor command queue and walking data: queued commands, battle walk, path node events,
//! meshes on link points.

const std = @import("std");

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
/// (0x48d760 → 0x44f910: "obrot" of Headnail's saw), from world tick `anim_from`.
pub const Link = struct { link: []const u8, mesh: []const u8, anim: []const u8 = "", anim_from: u64 = 0 };

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
    scene_anim: struct { name: []const u8, count: u8 = 1, reverse: bool = false },
    /// Idle (IDLE_ANIMATION, command 0x27).
    idle_anim: []const u8,
    /// Walk animation and speed (WALK_ANIMATION, command 0x28); null — normal.
    walk_anim: struct { name: []const u8, speed: ?f32 },
    /// Walk to a background point (WALKTO); the queue waits for arrival.
    walk: [2]f32,
    /// Turn to an angle (command 0x12, 0x427340 after a path with angle ≥ 0) — immediate.
    angle: f32,
};

pub const Fx = enum { none, shock, appear, vanish };

//! Background pause rule (no SDL, so it is unit-tested).

pub const State = struct {
    /// World and audio stop (`pause_background`).
    paused: bool,
    /// Window can't be seen: no frame is drawn.
    unseen: bool,
};

/// The exe pauses only while the app is inactive (WM_ACTIVATEAPP 0x404124 sets
/// [0x53506c]). Focus decides: on macOS the minimised/occluded flags lag behind
/// restoring the window, so a focused window always runs and draws.
pub fn state(pause_background: bool, focused: bool, hidden: bool) State {
    return .{ .paused = pause_background and !focused, .unseen = !focused and hidden };
}

test "focused window runs even while still flagged hidden" {
    const t = @import("std").testing;
    try t.expectEqual(State{ .paused = false, .unseen = false }, state(true, true, true));
    try t.expectEqual(State{ .paused = true, .unseen = true }, state(true, false, true));
    try t.expectEqual(State{ .paused = true, .unseen = false }, state(true, false, false));
    try t.expectEqual(State{ .paused = false, .unseen = true }, state(false, false, true));
}

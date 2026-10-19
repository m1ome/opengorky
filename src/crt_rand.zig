//! MSVC CRT rand()/srand() (0x4f8119 / 0x4f810f): one state [0x530050] for the whole
//! game; every exe random is `rand() % n` of it. The exe seeds it with the time at
//! startup (0x45a1c1); we use a fixed seed for repeatability.

/// Shared state, like [0x530050]: one per process, carried across locations.
pub var global: Rand = .{};

/// Process frame counter [0x54c46c]: +1 before every main-loop frame (0x405d77…0x405d83),
/// never reset. Ours counts world ticks only; the exe also counts menu and video frames.
pub var frames: u32 = 0;

const num = @import("num.zig");
pub const Rand = struct {
    state: u32 = 1,

    /// srand.
    pub fn seed(self: *Rand, s: u32) void {
        self.state = s;
    }

    /// rand(): 0..32767.
    pub fn next(self: *Rand) i32 {
        self.state = self.state *% 214013 +% 2531011;
        return @intCast((self.state >> 16) & 0x7fff);
    }

    /// `rand() % n`, n > 0.
    pub fn below(self: *Rand, n: u32) u32 {
        return @as(u32, @intCast(self.next())) % n;
    }

    /// `(rand() % 100) * 0.01`, 0..0.99 (0x4cccf3).
    pub fn pct(self: *Rand) f32 {
        return num.toF32(self.below(100)) * 0.01;
    }
};

test Rand {
    var r: Rand = .{};
    // First MSVC rand() values without srand.
    try @import("std").testing.expectEqual(@as(i32, 41), r.next());
    try @import("std").testing.expectEqual(@as(i32, 18467), r.next());
    try @import("std").testing.expectEqual(@as(i32, 6334), r.next());
}

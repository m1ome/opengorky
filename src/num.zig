//! Numeric conversions used across the engine and viewer.

/// Integer to f32 (exact for |x| < 2^24).
pub fn toF32(x: anytype) f32 {
    return @floatFromInt(x);
}

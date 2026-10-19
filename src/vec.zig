//! Small vector math on `[3]f32`; sums keep the left-to-right order `a0 + a1 + a2`.

pub fn add(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

pub fn sub(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

pub fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

pub fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

/// Unit vector; a zero vector is returned as is.
pub fn normalize(a: [3]f32) [3]f32 {
    const l = len(a);
    return if (l > 0) .{ a[0] / l, a[1] / l, a[2] / l } else a;
}

pub fn len(a: [3]f32) f32 {
    return @sqrt(dot(a, a));
}

/// Length in the XY plane.
pub fn len2(a: [3]f32) f32 {
    return @sqrt(a[0] * a[0] + a[1] * a[1]);
}

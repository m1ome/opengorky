//! Points relative to an actor (position + aS·offset by its angle).

const fields = @import("../fields.zig");
const Object = @import("../script.zig").object.Object;

/// Forward by the actor's angle (exe convention, see fields.facing): (cos, sin).
pub fn forward(o: *Object) [2]f32 {
    return fields.forwardOf(fields.angle(o));
}

/// Point pos + aS·(forward, right, up) by the actor's angle.
pub fn offsetPoint(o: *Object, as: f32, d: [3]f32) [3]f32 {
    const p = fields.pos(o);
    const f = forward(o);
    const side = [2]f32{ f[1], -f[0] };
    return .{ p[0] + (d[0] * f[0] + d[1] * side[0]) * as, p[1] + (d[0] * f[1] + d[1] * side[1]) * as, p[2] + d[2] * as };
}

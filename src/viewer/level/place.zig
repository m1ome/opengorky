//! Actor model placement for drawing: position, angle, scale and frame.

const og = @import("opengorky");
const LevelView = @import("../level.zig").LevelView;
const World = og.state.world.World;

/// Actor model placement for drawing (as in drawActors).
pub fn placement(self: *LevelView, o: *og.script.object.Object, model: *const og.actor.model_cache.Model) ?og.render.layer.Layer.Placement {
    const n = World.nativeOf(o);
    const angle = og.fields.modelAngle((o.getVar("angle") orelse return null).value.toFloat()) + n.actor.angle_offset;
    return .{
        .pos = og.vec.add(og.fields.pos(o), n.actor.render_offset),
        .angle = angle,
        .scale = self.world.actorScale() * n.actor.scale_mul * self.debug.scale_tweak,
        .frame = n.actor.frameIn(model),
    };
}

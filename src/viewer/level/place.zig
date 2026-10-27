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

/// The model in the pose drawn this tick: during a transition one blended frame (with the
/// placement's frame set to it), otherwise the model itself. The pose is kept in the
/// actor's buffer not being blended from (0x44fe00), for a transition that interrupts it.
pub fn posed(self: *LevelView, o: *og.script.object.Object, model: *const og.actor.model_cache.Model, pl: *og.render.layer.Layer.Placement) !*const og.actor.model_cache.Model {
    const a = &World.nativeOf(o).actor;
    return posedState(self, a, a.blendWeight(), a.frameIn(model), model, pl);
}

/// `posed` for a player state `st` (the actor or an extra body: `blend_from`, `pose_from`,
/// `poses`, `pose_drawn`), weight `w` and target frame `to`.
pub fn posedState(self: *LevelView, st: anytype, w: ?f32, to: u32, model: *const og.actor.model_cache.Model, pl: *og.render.layer.Layer.Placement) !*const og.actor.model_cache.Model {
    const out: *const og.actor.model_cache.Model = if (w) |wt|
        try og.actor.model_cache.blended(self.frame_arena.allocator(), model, st.blend_from, if (st.pose_from) |f| st.poses[f].items else null, if (@hasField(@TypeOf(st.*), "blend_shift")) st.blend_shift else @splat(0), to, wt)
    else
        model;
    const fr = out.frames;
    const i: u1 = if (st.pose_from) |f| 1 - f else st.pose_drawn;
    const buf = &st.poses[i];
    buf.clearRetainingCapacity();
    if (fr.bones > 0 and fr.frames > 0) {
        const f = if (out == model) @min(pl.frame, fr.frames - 1) else 0;
        try buf.appendSlice(self.world.gpa, fr.matrices[@as(usize, f) * fr.bones ..][0..fr.bones]);
    }
    st.pose_drawn = i;
    if (out != model) pl.frame = 0;
    return out;
}

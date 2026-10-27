//! Script builtins: actors (animations, walking, model links, queue).

const std = @import("std");
const fields = @import("../fields.zig");
const popup_mod = @import("../popup.zig");
const areas = @import("../world.zig").areas;
const queue = @import("../world.zig").queue;
const walk = @import("../world.zig").walk;
const bitmap_anim = @import("../world.zig").bitmap_anim;
const level_files = @import("../formats.zig").level_files;
const actor_mod = @import("../actor.zig");
const runtime = @import("../script.zig").runtime;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const Object = @import("../script.zig").object.Object;
const Runtime = runtime.Runtime;
const Value = @import("../script.zig").value.Value;
const args_mod = @import("args.zig");
const inventory = @import("../inventory.zig");

/// ABA_Impulse("object") (0x4c03b0 → 0x4b4400(0)): the script passes no lock.
pub fn biAbaImpulse(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    if (args_mod.targetObject(ctx, rt, args)) |o| {
        if (World.nativeOf(o).kind == .active_animation) bitmap_anim.impulse(o, 0);
    }
    return .zero;
}

/// PlaceActor(name, "area", index[, floor]) (0x4bf0e0 → 0x422b70): put the actor
/// at an area point; angle is the point's third coordinate (radians).
/// PlaceActor(name, x, y[, direction]) (→ 0x48e890): onto a battle grid tile.
/// Enabled actors only (+0x5c); returns 1 if the call reached the placement
/// (01__port_bulldozer2: `if(PlaceActor("BT",-30,-30))`, BT in the party arrives
/// on turn 6).
pub fn biPlaceActor(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    if (try args_mod.deferAfterLoad(w, .place_actor, args)) return .{ .int = 1 };
    // Every exit goes through 0x4bf218 → 0x45ba90: camera snaps to the selected hero.
    defer w.out.camera_snap = true;
    if (args.len == 0 or args[0] != .string) return .zero; // 0x4bf0f3
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    if (!o.enabled or World.nativeOf(o).kind != .actor or args.len < 3) return .zero;
    if (args[1] == .int) {
        if (args[2] != .int) return .zero;
        // Battle grid tile: tile corner at (centerX, centerY), tiles of xSize×ySize
        // along world X and Y, floor at centerZ. The queue is not reset.
        const cm = w.combat_map orelse return .{ .int = 1 };
        const cx = args[1].toFloat();
        const cy = args[2].toFloat();
        // Shift to the block centre by charSize (0x499ce0): 1 → 0.5, 4 → 1, 9 → 1.5.
        const off: f32 = switch (fields.charSize(o)) {
            1 => 0.5,
            4 => 1.0,
            9 => 1.5,
            else => 0,
        };
        const wp = cm.toWorld(cx + off, cy + off);
        fields.setPos(o, .{ wp[0], wp[1], cm.center[2] });
        // Direction in eighths of a turn: dir·π/4 (0x48e90a); without a fourth argument
        // it is 0 (0x4bf1dd).
        const dir: f32 = if (args.len > 3 and args[3] == .int) args[3].toFloat() else 0;
        fields.setAngle(o, dir * std.math.pi / 4.0);
        world_mod.actorOf(o).placed = true;
        return .{ .int = 1 };
    }
    if (args[1] != .string or args[2] != .int) return .zero;
    // The fourth argument is the floor (0x422c00): height from the `.wm`/`.wm2` cell.
    queue.placeAtPoint(w, o, args[1].string, args[2].int, if (args.len > 3 and args[3] == .int) args[3].int else 0);
    return .{ .int = 1 };
}

/// RegisterIdleAnimation(state, "anim", weight) (0x4bf2f0 → 0x4229b0): types are
/// strictly int, string, int; without a weight (ft_nato, act_c_nato,
/// act_c_specnaz: `(3,"pickupB_still")`) the exe registers nothing.
pub fn biRegisterIdleAnimation(_: *anyopaque, _: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    if (!world_mod.isActor(self) or args.len < 3 or args[1] != .string or args[2] != .int) return .zero;
    const st = args_mod.animState(args[0]) orelse return .zero;
    world_mod.actorOf(self).registerIdle(st, args[1].string, @intCast(@max(0, args[2].int)));
    return .zero;
}

/// RegisterAnimation(state, "logical", "anim") (0x4bf370 → 0x422960): types
/// strictly int, string, string.
pub fn biRegisterAnimation(ctx: *anyopaque, _: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    if (!world_mod.isActor(self) or args.len < 3 or args[1] != .string or args[2] != .string) return .zero;
    const st = args_mod.animState(args[0]) orelse return .zero;
    try world_mod.actorOf(self).registerMapping(args_mod.worldOf(ctx).gpa, st, args[1].string, args[2].string);
    return .zero;
}

/// Actor_TextEffect(actor, string) (0x4c0700): a string.tab popup over the actor,
/// like "No ammo" in battle: colour cfcNoammo, sound `battle_noammo`.
pub fn biActorTextEffect(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const o = w.actorObject(args_mod.argString(args, 0)) orelse return .zero;
    if (!world_mod.actorOf(o).placed or args.len < 2) return .zero;
    try textEffect(w, o, w.stringOr(args[1].toInt(), "No ammo"));
    return .zero;
}

/// Actor_SetAsyncAnimation(actor, anim[, noBlend[, reverse]]) (0x4c0bc0): like
/// Actor_SetAnimation but the queue doesn't wait for the end (command 0x14);
/// reverse plays from the last frame (the box lid closes with the same "box").
pub fn biActorSetAsyncAnimation(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    if (!world_mod.isActor(o) or args.len < 2 or args[1] != .string) return .zero;
    const a = world_mod.actorOf(o);
    // Reverse only with an integer fourth argument (0x4c0c0a); the third 1 queues
    // command 0x18 (no blend) before it (0x4c0c16 → 0x428b00).
    if (flagArg(args, 2)) try a.queue.append(w.gpa, .no_blend);
    try a.queue.append(w.gpa, .{ .async_anim = .{ .name = args[1].string, .reverse = args.len > 3 and args[3] == .int and args[3].int != 0 } });
    try queue.runQueue(w, o, a);
    return .zero;
}

/// ActivateLink(point, mesh, …) (0x4bf650): mesh on a link point of the current
/// actor (Headnail's saws on "pila prawa" / "pila lewa").
pub fn biActivateLink(ctx: *anyopaque, _: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    if (!world_mod.isActor(self) or args.len < 2 or args[0] != .string or args[1] != .string) return .zero;
    try args_mod.setLink(args_mod.worldOf(ctx), world_mod.actorOf(self), args[0].string, args[1].string);
    return .zero;
}

/// Actor_ActivateLink(actor, item) (0x4c08f0): the item's mesh in hand, on the
/// hold point (two_hands for two-handed, else one_hand; the bat in 04_city_factory).
pub fn biActorActivateLink(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    const item = rt.findObject(args_mod.argString(args, 1)) orelse return .zero;
    if (!world_mod.isActor(o)) return .zero;
    try args_mod.setLink(w, world_mod.actorOf(o), if (item.getInt("two_handed") == 1) "two_hands" else "one_hand", fields.meshFile(item));
    return .zero;
}

pub fn biActorDeactivateAllLinks(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    if (world_mod.isActor(o)) world_mod.actorOf(o).links.clearRetainingCapacity();
    return .zero;
}

/// DeactivateLink("point") (0x4bf740 → 0x42aea0 with no mesh → 0x42ac30): the point of
/// the current actor loses its mesh.
pub fn biDeactivateLink(_: *anyopaque, _: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    if (!world_mod.isActor(self) or args.len < 1 or args[0] != .string) return .zero;
    const links = &world_mod.actorOf(self).links;
    for (links.items, 0..) |l, i| if (std.ascii.eqlIgnoreCase(l.link, args[0].string)) {
        _ = links.orderedRemove(i);
        break;
    };
    return .zero;
}

/// RegisterExtraBody(slot, flag, "mesh") (0x4bf400 → 0x422a50): types strictly int, int,
/// string; slot 0..3 of the current actor gets the mesh (the old one is released), flag
/// ≠ 0 keeps it out of the actor's animation.
pub fn biRegisterExtraBody(ctx: *anyopaque, _: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    if (!world_mod.isActor(self) or args.len < 3 or args[0] != .int or args[1] != .int or args[2] != .string) return .zero;
    if (args[0].int < 0 or args[0].int >= 4) return .zero; // 0x422a56
    const w = args_mod.worldOf(ctx);
    const mesh = try w.arena_state.allocator().dupe(u8, args[2].string);
    const slot = &world_mod.actorOf(self).extra_bodies[@intCast(args[0].int)];
    if (slot.*) |*old| for (&old.poses) |*p| p.deinit(w.gpa);
    slot.* = .{ .mesh = mesh, .still = args[1].int != 0 };
    return .zero;
}

/// Actor_QueueState(actor, state) (0x4c0a60 → 0x427c70, command 0x22): only (string,
/// int); in battle 0/1 become 7/8.
pub fn biActorQueueState(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    if (args.len < 2 or args[0] != .string or args[1] != .int) return .zero;
    const o = w.actorObject(args[0].string) orelse return .zero;
    try world_mod.actorOf(o).queue.append(w.gpa, .{ .state = args_mod.clampState(args[1]) });
    return .zero;
}

/// ActorPutBackItem(actor) (0x4c0330 → 0x42b050): a two-handed item in hand (+0x3250,
/// +0x350 == 1) goes on the back: "hide_back", links off, its mesh on "back", state 0.
/// ActorPutFrontItem(actor) (0x4c0370 → 0x42b0c0) takes it back: after the blend, links
/// off, state 1, "hide_back" backwards without waiting, 30 ticks, mesh on "two_hands".
pub fn biActorPutBackItem(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    return putItem(args_mod.worldOf(ctx), args, false);
}

pub fn biActorPutFrontItem(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    return putItem(args_mod.worldOf(ctx), args, true);
}

fn putItem(w: *World, args: []const Value, front: bool) !Value {
    if (args.len < 1 or args[0] != .string) return .zero;
    const o = w.actorObject(args[0].string) orelse return .zero;
    const item = inventory.equipment.equipped(w, o, .hand) orelse return .zero;
    if (item.getInt("two_handed") != 1) return .zero;
    const mesh = try w.arena_state.allocator().dupe(u8, fields.meshFile(item));
    const cmds: []const actor_mod.command.Command = if (front) &.{
        .wait_blend,
        .unlink,
        .{ .state = 1 },
        .{ .async_anim = .{ .name = "hide_back", .reverse = true } },
        .{ .delay = 30 },
        .{ .link = .{ .link = "two_hands", .mesh = mesh } },
    } else &.{
        .{ .anim = "hide_back" },
        .unlink,
        .{ .link = .{ .link = "back", .mesh = mesh } },
        .{ .state = 0 },
    };
    try world_mod.actorOf(o).queue.appendSlice(w.gpa, cmds);
    return .zero;
}

/// SetActorAddVariables(actor, x, y, z) (0x4bed80): model offset from the position
/// (only float arguments change it).
pub fn biSetActorAddVariables(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    if (!world_mod.isActor(o)) return .zero;
    const a = world_mod.actorOf(o);
    for (0..3) |k| if (args.len > k + 1 and args[k + 1] == .float) {
        a.render_offset[k] = args[k + 1].float;
    };
    return .zero;
}

/// Disable() (0x4bf030): disable the current actor.
pub fn biDisable(_: *anyopaque, _: *Runtime, self: *Object, _: []const Value) anyerror!Value {
    if (world_mod.isActor(self)) self.enabled = false;
    return .zero;
}

/// SetActorState(state) (0x4bf610): hold state of the current actor.
pub fn biSetActorState(ctx: *anyopaque, _: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    if (!world_mod.isActor(self) or args.len < 1) return .zero;
    world_mod.actorOf(self).setState(args_mod.clampState(args[0]), args_mod.worldOf(ctx).isCombat());
    return .zero;
}

/// ActorInArea(actor, area) (0x4bf480): the actor's background point is inside the area.
pub fn biActorInArea(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const o = w.actorObject(args_mod.argString(args, 0)) orelse return .zero;
    const area = areas.findArea(w, args_mod.argString(args, 1)) orelse return .zero;
    const p = w.screenPos(o);
    return .{ .int = @intFromBool(level_files.areaContains(area, p[0], p[1])) };
}

/// ReferenceAnimation(anim) (0x4c16a0): the actor's reference animation; offsets
/// of non-in-place animations count from its first frame (0x44fe90).
pub fn biReferenceAnimation(_: *anyopaque, _: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    if (!world_mod.isActor(self) or args.len < 1 or args[0] != .string) return .zero;
    world_mod.actorOf(self).reference = args[0].string;
    return .zero;
}

pub fn biNotInPlaceAnimation(ctx: *anyopaque, _: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    if (!world_mod.isActor(self) or args.len < 1 or args[0] != .string) return .zero;
    try world_mod.actorOf(self).not_in_place.append(args_mod.worldOf(ctx).gpa, args[0].string);
    return .zero;
}

/// ActorSetWalkSpeed("anim", speed) (0x4bfda0 → 0x422b50): world pixels per tick
/// (0x424636), per logical name slot; speed must be a float.
pub fn biActorSetWalkSpeed(_: *anyopaque, _: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    if (!world_mod.isActor(self) or args.len < 2 or args[0] != .string or args[1] != .float) return .zero;
    world_mod.actorOf(self).setSpeed(args[0].string, args[1].toFloat());
    return .zero;
}

/// Actor_SetAnimation(name, "anim"[, noBlend]) (0x427e40): the third argument 1
/// queues command 0x18 before it (0x4c0d28): no blending into it.
pub fn biActorSetAnimation(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    if (!world_mod.isActor(o) or args.len < 2 or args[1] != .string) return .zero;
    const a = world_mod.actorOf(o);
    const w = args_mod.worldOf(ctx);
    // Into the actor's queue (0x4c0cd0 → 0x427e40): a one-shot animation after the
    // current commands; "idle" means the current state's idle.
    const cmd: actor_mod.command.Command = if (std.ascii.eqlIgnoreCase(args[1].string, "idle"))
        .idle
    else
        .{ .anim = try w.arena_state.allocator().dupe(u8, args[1].string) };
    if (flagArg(args, 2)) try a.queue.append(w.gpa, .no_blend);
    try a.queue.append(w.gpa, cmd);
    try queue.runQueue(w, o, a);
    return .zero;
}

/// Actor_SetState(name, state[, instant]) (0x4c09f0).
pub fn biActorSetState(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    if (!world_mod.isActor(o) or args.len < 2) return .zero;
    const a = world_mod.actorOf(o);
    // Third argument 1: the idle below without the blend (0x4c0a3b).
    if (flagArg(args, 2)) a.instant = true;
    a.setState(args_mod.clampState(args[1]), args_mod.worldOf(ctx).isCombat()); // 0x42b450
    a.forced_idle = null;
    if (!a.busy()) a.pickIdle(args_mod.worldOf(ctx).crt());
    return .zero;
}

/// AttachActorsByLink(parent, actor, "point"): link point from the parent mesh's chunk 13.
pub fn biAttachActorsByLink(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    if (args.len < 3) return .zero;
    const parent = w.actorObject(args_mod.argString(args, 0)) orelse return .zero;
    const child = w.actorObject(args_mod.argString(args, 1)) orelse return .zero;
    // 0x4bf8e0: point not found (0x44c660 < 0) means no attach; the offset is the
    // mesh shift (chunk 11, +0x28) plus the point (+0x20), angle is the point's +0x30.
    var off: [3]f32 = .{ 0, 0, 0 };
    var ang: f32 = 0;
    if (w.res.models) |m| if (m.get(fields.meshFile(parent))) |model| {
        const h = model.mesh.holdMode(args_mod.argString(args, 2)) orelse return .zero;
        for (0..3) |k| off[k] = model.mesh.center[k] + h.params[k];
        ang = h.params[4];
    };
    const a = world_mod.actorOf(child);
    a.attached_to = parent;
    a.link_offset = off;
    a.link_angle = ang;
    a.placed = true;
    return .zero;
}

/// AttachActors(parent, actor, a, b, c, angle) (0x4bf800): AttachActorsByLink with the
/// offset and angle given (four floats, 0x4bf821…): a, b horizontal in the parent's
/// axes (the order ByLink stores the mesh z, x in, 0x4bf9e2), c height, in world units.
pub fn biAttachActors(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    if (args.len < 6 or args[0] != .string or args[1] != .string) return .zero;
    for (args[2..6]) |v| if (v != .float) return .zero;
    const parent = w.actorObject(args[0].string) orelse return .zero;
    const child = w.actorObject(args[1].string) orelse return .zero;
    // followParent scales the offset by the parent's mesh scale × actorScale (life.zig).
    const pm = if (w.res.models) |m| m.get(fields.meshFile(parent)) else null;
    const s = w.actorScale() * if (pm) |m| m.unitScale() else 24;
    const a = world_mod.actorOf(child);
    a.attached_to = parent;
    a.link_offset = .{ args[3].float / s, args[4].float / s, args[2].float / s };
    a.link_angle = args[5].float;
    a.placed = true;
    return .zero;
}

/// LinkActor("point", actor) (0x4c1c50 → 0x42ab60(point, actor)): the actor rides
/// the calling object at that point of its mesh — the Smoke Rider's two pilots
/// (01cy_smokerider.ftr: LinkActor("pilot1","smoke_pilot_1")). No point: no link.
pub fn biLinkActor(ctx: *anyopaque, _: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    if (args.len < 2 or !world_mod.isActor(self)) return .zero;
    const w = args_mod.worldOf(ctx);
    const child = w.actorObject(args_mod.argString(args, 1)) orelse return .zero;
    const models = w.res.models orelse return .zero;
    const model = models.get(fields.meshFile(self)) orelse return .zero;
    const a = world_mod.actorOf(child);
    a.link_point = model.mesh.holdMode(args_mod.argString(args, 0)) orelse return .zero;
    a.attached_to = self;
    return .zero;
}

/// ActorModifyScale(k) (0x4bf5c0): the calling actor's model scale ×k.
pub fn biActorModifyScale(_: *anyopaque, _: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    if (!world_mod.isActor(self) or args.len < 1) return .zero;
    world_mod.actorOf(self).scale_mul *= args[0].toFloat();
    return .zero;
}

pub fn biDetachActorsFrom(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const parent = w.actorObject(args_mod.argString(args, 0)) orelse return .zero;
    for (w.rt.objects.items) |o| {
        if (world_mod.isActor(o) and world_mod.actorOf(o).attached_to == parent) {
            world_mod.actorOf(o).attached_to = null;
            world_mod.actorOf(o).render_offset = .{ 0, 0, 0 };
        }
    }
    return .zero;
}

/// WalkOnSceneryTrack(actor, "track", height, start) (0x4bff80): the area points
/// at height `height`; the actor stands at point `start` with its angle (third
/// coordinate) and floats along the rest at walk speed (0x422ea0), turning as it goes.
pub fn biWalkOnSceneryTrack(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    if (args.len < 2) return .zero;
    const o = w.actorObject(args_mod.argString(args, 0)) orelse return .zero;
    try walk.sceneryTrack(w, o, args_mod.argString(args, 1), if (args.len > 2) args[2].toFloat() else 0, if (args.len > 3 and args[3] == .int) args[3].int else 0);
    return .zero;
}

/// StopActor(actor) (0x4c0570 → 0x427c10): reset the queue, path and command.
pub fn biStopActor(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const o = w.actorObject(args_mod.argString(args, 0)) orelse return .zero;
    world_mod.actorOf(o).dropCommands(w.crt());
    return .zero;
}

/// Vibrato("actor", amplitude, phase step) (0x4c01d0 → object 0x4cd9c0): both
/// numbers must be floats.
pub fn biVibrato(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.worldOf(ctx).actorObject(args_mod.argString(args, 0)) orelse return .zero;
    if (args.len >= 3 and args[1] == .float and args[2] == .float) world_mod.actorOf(o).vibrato = .{ args[1].toFloat(), args[2].toFloat() };
    return .zero;
}

/// ActorSetWalkAnimation("anim"[, reverse]) (0x4bfc70 → command 0x17, 0x423eca):
/// walk the rest of the path with this animation and its speed; reverse plays it
/// backwards (going down a ladder).
pub fn biActorSetWalkAnimation(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const a = args_mod.nodeActor(ctx) orelse return .zero;
    const name = args_mod.argString(args, 0);
    a.walk_anim = name;
    a.walk_reverse = args.len > 1 and args[1].toInt() != 0;
    a.move_speed = a.speedOf(name) * args_mod.worldOf(ctx).speedScale();
    if (!a.one_shot) {
        a.play(a.resolve(name), true, false);
        a.reverse = a.walk_reverse;
    }
    return .zero;
}

/// ActorAnimation("anim", a, b, reverse) (0x4bfa70 → command 0x13): one-shot
/// animation, movement waits for its end; 4th argument 1 plays it backwards. Flags
/// a and b = 1 queue command 0x18 (no blend) before and after it (0x4bfab3, 0x4bfb10).
pub fn biActorAnimation(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const a = args_mod.nodeActor(ctx) orelse return .zero;
    if (flagArg(args, 1)) a.instant = true;
    a.play(a.resolve(args_mod.argString(args, 0)), false, true);
    if (flagArg(args, 2)) a.instant = true;
    a.reverse = args_mod.reverseFlag(args);
    a.hold_move = true;
    return .zero;
}

/// Int argument `i` equal to 1 (0x4c6510 == 1 after the type check).
fn flagArg(args: []const Value, i: usize) bool {
    return args.len > i and args[i] == .int and args[i].int == 1;
}

/// ActorAsyncAnimation("anim", a, b, reverse) (0x4bfb20 → command 0x14, 0x428980):
/// one-shot animation without stopping; flags as in ActorAnimation.
pub fn biActorAsyncAnimation(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const a = args_mod.nodeActor(ctx) orelse return .zero;
    if (flagArg(args, 1)) a.instant = true;
    a.play(a.resolve(args_mod.argString(args, 0)), false, true);
    if (flagArg(args, 2)) a.instant = true;
    a.reverse = args_mod.reverseFlag(args);
    a.hold_move = false;
    return .zero;
}

/// ActorQueueWalkAnimation("anim", a, b, reverse) (0x4bfce0 → command 0x1a):
/// one-shot animation on the next path segment; 2nd argument 1 plays it without the
/// blend, 4th plays it backwards.
pub fn biActorQueueWalkAnimation(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const a = args_mod.nodeActor(ctx) orelse return .zero;
    a.queued_anim = args_mod.argString(args, 0);
    a.queued_instant = flagArg(args, 1);
    a.queued_reverse = args_mod.reverseFlag(args);
    return .zero;
}

/// ActorAdjustAngle() (0x4bfc40 → 0x429080, command 0x12): turn the actor to the
/// path node's angle (`.ap`, the point's third field, radians, +0xa0[node]); at
/// the path end, the last point's angle.
pub fn biActorAdjustAngle(ctx: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const o = w.node_actor orelse return .zero;
    const ev = w.node_cur orelse return .zero;
    if (ev.path >= w.paths.len) return .zero;
    const pts = w.paths[ev.path].points;
    if (pts.len == 0) return .zero;
    fields.setAngle(o, pts[@min(ev.no, pts.len - 1)][2]);
    return .zero;
}

/// ActorEnableRotation(0/1) (0x4bfe10 → command 0x19, +0x31e9): 0 = don't turn
/// toward path points.
pub fn biActorEnableRotation(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const a = args_mod.nodeActor(ctx) orelse return .zero;
    if (args.len > 0 and args[0] == .int) a.no_rotation = args[0].int == 0;
    return .zero;
}

/// ActorDisableInterpolation() (0x4bff50 → command 0x18, 0x424256: +0x31e8): the next
/// animation without blending from the previous one (0x44f910).
pub fn biActorDisableInterpolation(ctx: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
    const a = args_mod.nodeActor(ctx) orelse return .zero;
    a.instant = true;
    return .zero;
}

/// ActorQueueWaitForInterpolation() (0x4bfee0 → command 0x1d): movement waits for
/// the animation blend to finish (0x424e5f: +0x19 != 2).
pub fn biActorQueueWaitForInterpolation(ctx: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
    const a = args_mod.nodeActor(ctx) orelse return .zero;
    if (a.anim_hold > 0) a.hold_blend = true;
    return .zero;
}

/// ActorQueueWaitForAnimation(["anim"]) (0x4bfe50 → commands 0x1b/0x1c): path
/// movement waits for the current one-shot animation to end. The name changes nothing
/// but a tick: 0x1c is done at the animation end like 0x1b (0x424e4f); with the name's
/// slot (0x4280e0) equal to the last slot played (+0x30e4) the queue goes on in that
/// same tick (0x4268b6), otherwise on the next.
pub fn biActorQueueWaitForAnimation(ctx: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
    const a = args_mod.nodeActor(ctx) orelse return .zero;
    if (a.one_shot) a.hold_move = true;
    return .zero;
}

/// ActorAsyncWalkAnimation(a, b) (0x4bfbd0 → command 0x15, 0x422ea0): start the
/// walk animation at once, the queued one-shot (ActorQueueWalkAnimation) if any,
/// else the current walk; movement doesn't wait. a, b = 1 queue command 0x18 (no
/// blend) before and after it (0x4bfc02, 0x4bfc2e).
pub fn biActorAsyncWalkAnimation(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const a = args_mod.nodeActor(ctx) orelse return .zero;
    if (flagArg(args, 0)) a.instant = true;
    if (a.playQueued()) {
        a.hold_move = false;
    } else {
        a.play(a.resolve(a.walk_anim), true, false);
        a.reverse = a.walk_reverse;
    }
    if (flagArg(args, 1)) a.instant = true;
    return .zero;
}

/// ActorDelay(ticks) (0x4bfa30 → command 0x16): pause of the path node's actor.
pub fn biActorDelay(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const a = args_mod.nodeActor(ctx) orelse return .zero;
    if (args.len > 0 and args[0] == .int) a.delay = @intCast(@max(0, args[0].int));
    return .zero;
}

/// Actor_QueueGOScriptFunc(actor, object, "function") (0x4c0eb0): call the
/// object's function with the actor's name when the actor's queue reaches it.
pub fn biActorQueueGOScriptFunc(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const o = w.actorObject(args_mod.argString(args, 0)) orelse return .zero;
    _ = rt.findObject(args_mod.argString(args, 1)) orelse return .zero;
    const a = world_mod.actorOf(o);
    const ar = w.arena_state.allocator();
    try a.queue.append(w.gpa, .{ .call = .{ .object = try ar.dupe(u8, args_mod.argString(args, 1)), .func = try ar.dupe(u8, args_mod.argString(args, 2)) } });
    try queue.runQueue(w, o, a);
    return .zero;
}

/// Actor_QueueDelay(actor, ticks) (0x4c0b80 → command 0x16): only (string, int).
pub fn biActorQueueDelay(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    if (args.len < 2 or args[0] != .string or args[1] != .int) return .zero;
    const o = w.actorObject(args[0].string) orelse return .zero;
    const n: u32 = @intCast(@max(0, args[1].int));
    try world_mod.actorOf(o).queue.append(w.gpa, .{ .delay = n });
    return .zero;
}

/// Actor_QueueJustifyPosition(actor) (0x4c0ac0 → 0x4253c0, command 0x24): only (string).
pub fn biActorQueueJustifyPosition(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    if (args.len < 1 or args[0] != .string) return .zero;
    const o = w.actorObject(args[0].string) orelse return .zero;
    try world_mod.actorOf(o).queue.append(w.gpa, .justify);
    return .zero;
}

/// Actor_QueuePlace(actor, "area", index) (0x4c0b00 → 0x425400, command 0x25): only
/// (string, string, int); the area name is kept to 32 characters (strncpy 0x20).
pub fn biActorQueuePlace(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    if (args.len < 3 or args[0] != .string or args[1] != .string or args[2] != .int) return .zero;
    const o = w.actorObject(args[0].string) orelse return .zero;
    const name = args[1].string[0..@min(args[1].string.len, 32)];
    try world_mod.actorOf(o).queue.append(w.gpa, .{ .place = .{ .area = try w.arena_state.allocator().dupe(u8, name), .index = args[2].int } });
    return .zero;
}

/// Actor_GORunFun(actor, object, "function") (0x4c0df0): call the object's
/// function with the actor's name at once (unlike Actor_QueueGOScriptFunc, not via
/// the queue: PrivateTake of the plank and gas bottle takes the item before pickup_end).
pub fn biActorGORunFun(_: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    if (args.len < 3 or args[0] != .string or args[1] != .string or args[2] != .string) return .zero;
    const obj = rt.findObject(args[1].string) orelse return .zero;
    _ = try rt.callIfExists(obj, args[2].string, &.{.{ .string = args[0].string }});
    return .zero;
}

/// AdjustAngle(degrees) (0x4c1650): model orientation correction of the current
/// actor ([0x64ea24] is the object whose script runs, +0x3200 = degrees·π/180); float only.
pub fn biAdjustAngle(_: *anyopaque, _: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    if (args.len < 1 or args[0] != .float or World.nativeOf(self).kind != .actor) return .zero;
    world_mod.actorOf(self).angle_offset = args[0].toFloat() * std.math.pi / 180.0;
    return .zero;
}

/// Popup over an actor (TextEffect 0x4c8830): cfcNoammo, scale 0.6, sound `battle_noammo`.
fn textEffect(w: *World, o: *Object, text: []const u8) !void {
    try w.popups.append(w.gpa, popup_mod.Popup.make(fields.pos(o), text, .notice));
    w.out.sound(w.gpa, "battle_noammo", null);
}

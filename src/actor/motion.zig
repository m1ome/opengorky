//! Actor tick (0x424d30, 0x44fae0): turning, path walking, animation frames,
//! root motion, attachment to a parent. State and commands live in `actor.zig`.

const std = @import("std");
const Rand = @import("../crt_rand.zig").Rand;
const Object = @import("../script.zig").object.Object;
const model_cache = @import("model_cache.zig");
const fields = @import("../fields.zig");
const actor = @import("../actor.zig");
const Actor = actor.Actor;

/// One actor tick: animation, path movement, attachment.
/// `model` gives animation lengths and root motion; may be null.
pub fn tick(a: *Actor, o: *Object, model: ?*const model_cache.Model, scale_px: f32, rand: *Rand) void {
    if (a.anim_paused) {} else if (a.anim_hold > 0) a.anim_hold -= 1 else a.anim_ticks += 1;
    a.tickFx();

    // Turn in place (0x424d30): if the rest is within one step, snap to the target and end
    // the command; "stepping" switches to idle (empty queue, 0x4265fb → 0x422f90).
    if (a.turn_to) |t| if (a.path_index >= a.path.items.len) {
        if (turnTowards(o, t) == 0) {
            a.turn_to = null;
            if (a.turn_step) {
                a.turn_step = false;
                if (!a.one_shot) a.pickIdle(rand);
            }
        }
    };

    // A queue pause (ActorDelay on a path node, command 0x16) also holds movement.
    // Point walking is queue command 0 (start 0x423993, tick 0x4245e0): each tick a
    // move_speed step toward the point and a rotSpeed turn toward the segment angle
    // (0x424d30), without stopping to turn. A point is reached within √1.5 steps
    // (0x424665, 0x508780 = 1.5): the actor is not pulled onto it, the next segment
    // starts at once and steps in the same tick (loop 0x4265d7…0x4265ef).
    var guard: usize = 0;
    while (a.path_index < a.path.items.len and !(a.hold_move and a.one_shot) and a.delay == 0) : (guard += 1) {
        if (guard > a.path.items.len) break;
        const target = a.path.items[a.path_index];
        const p = fields.pos(o);
        const dx = target[0] - p[0];
        const dy = target[1] - p[1];
        if (a.battle_walk) |*bw| {
            if (a.seg_index != a.path_index) {
                // Turn in place (command 0x12 before each cell, 0x423702): a difference over
                // 0.1 rad (0x508768) before walking started means "stepping".
                a.seg_index = a.path_index;
                const ta = fields.facing(target[0] - bw.origin[0], target[1] - bw.origin[1]);
                a.walk_turn = ta;
                bw.turning = true;
                if (!bw.started and @abs(fields.angleDiff(ta, fields.angle(o))) > 0.1 and a.hasMapping("stepping")) {
                    a.play(a.resolve("stepping"), true, false);
                }
            }
            if (bw.turning) {
                // A turn step (0x424d30); once done, walking (0x11, loop 0x4265d7) starts in the
                // same tick with the angle to the point (0x4238db).
                if (turnTowards(o, a.walk_turn) != 0) break;
                bw.turning = false;
                a.walk_turn = fields.facing(dx, dy);
                if (!bw.started) {
                    bw.started = true;
                    a.play(bw.anim, true, false);
                }
            }
        } else if (a.seg_index != a.path_index) {
            // Segment start (0x423993): the angle to the point or along the next segment,
            // whichever is closer to the current angle (0x423a3a…0x423b47).
            a.seg_index = a.path_index;
            const cur = fields.angle(o);
            var want = fields.facing(dx, dy);
            if (a.path_index + 1 < a.path.items.len) {
                const nx = a.path.items[a.path_index + 1];
                const next = fields.facing(nx[0] - target[0], nx[1] - target[1]);
                if (@abs(fields.angleDiff(next, cur)) <= @abs(fields.angleDiff(want, cur))) want = next;
            }
            a.walk_turn = want;
        }
        const d2 = dx * dx + dy * dy;
        const tz = if (a.path_index < a.path_z.items.len) a.path_z.items[a.path_index] else std.math.nan(f32);
        if (d2 >= 1.5 * a.move_speed * a.move_speed) {
            const d = @sqrt(d2);
            // Height moves toward the path point's height in proportion to the step.
            const z = if (std.math.isNan(tz)) p[2] else p[2] + (tz - p[2]) * (a.move_speed / d);
            fields.setPos(o, .{ p[0] + dx / d * a.move_speed, p[1] + dy / d * a.move_speed, z });
            // The AdjustAngle offset (+0x3200) is not part of the turn target, only of drawing.
            if (!a.no_rotation) _ = turnTowards(o, a.walk_turn);
            break;
        }
        // Point reached without snapping: the remainder (height too) carries into the
        // next segment, whose step vector starts from the current position.
        if (a.path_index < a.path_events.items.len) if (a.path_events.items[a.path_index]) |ev| {
            a.node_event = ev;
        };
        a.path_index += 1;
        // Queued animation (ActorQueueWalkAnimation) at the next point.
        if (a.path_index < a.path.items.len and a.playQueued()) a.hold_move = true;
        if (a.path_index == a.path.items.len) {
            a.clearPath();
            a.walk_anim = "walk";
            a.walk_reverse = false;
            a.no_rotation = false;
            if (!a.playQueued() and !a.on_track) a.pickIdle(rand);
            a.on_track = false;
            break;
        }
        // The world takes the node event before the next step.
        if (a.node_event != null) break;
    }

    tickAnim(a, o, model, scale_px, rand);
}

/// Turn `angle` toward `want` by rotSpeed; return the remaining difference (rad).
fn turnTowards(o: *Object, want: f32) f32 {
    var rs = fields.getF(o, "rotSpeed");
    if (rs <= 0) rs = 0.1;
    const cur = fields.angle(o);
    const diff = std.math.atan2(@sin(want - cur), @cos(want - cur));
    if (@abs(diff) <= rs) {
        fields.setAngle(o, want);
        return 0;
    }
    fields.setAngle(o, cur + std.math.sign(diff) * rs);
    return @abs(diff) - rs;
}

fn tickAnim(a: *Actor, o: *Object, model: ?*const model_cache.Model, scale_px: f32, rand: *Rand) void {
    // End of a non-looping animation; a frozen one (death) no longer changes.
    if (a.hold_last and !a.one_shot) return;
    if (a.frozen or a.anim_paused) return;
    if (model) |m| if (!a.loop and a.anim.len > 0) {
        if (m.anims.find(a.anim)) |an| {
            const len: f32 = @floatFromInt(an.last - an.first + 1);
            if (a.anim_ticks >= len) {
                // Async without an idle for the state: stay on the last frame.
                if (a.async_anim) {
                    a.async_anim = false;
                    if (a.idle_count[a.state] == 0 and a.forced_idle == null) {
                        a.one_shot = false;
                        a.frozen = true;
                        return;
                    }
                }
                if (a.isNotInPlace(a.anim)) {
                    const ref_first = if (m.anims.find(a.reference)) |r| r.first else an.first;
                    applyRootMotion(o, m, ref_first, an.last, scale_px);
                }
                // Scene animation repeat.
                if (a.repeat_left > 0) {
                    a.repeat_left -= 1;
                    a.anim_ticks = 0;
                    a.cue_fresh = true;
                    return;
                }
                a.one_shot = false;
                a.hold_move = false;
                if (a.hold_last) return;
                // Mid-path: walk again (in its own direction).
                if (a.path_index < a.path.items.len) {
                    a.play(a.resolve(a.walk_anim), true, false);
                    a.reverse = a.walk_reverse;
                    return;
                }
                a.pickIdle(rand);
            }
        } else {
            a.one_shot = false;
            if (!a.hold_last) a.pickIdle(rand);
        }
    };
}

/// Moves the actor by the body shift of an "off-place" animation (0x44fe90): bounds
/// center of the last frame minus the reference animation's first frame, horizontally.
fn applyRootMotion(o: *Object, m: *const model_cache.Model, first: u32, last: u32, scale_px: f32) void {
    if (last >= m.frames.extra.len) return;
    const b0 = m.frames.extra[first];
    const b1 = m.frames.extra[last];
    const mx = ((b1[0] + b1[3]) - (b0[0] + b0[3])) / 2 * scale_px;
    const mz = ((b1[2] + b1[5]) - (b0[2] + b0[5])) / 2 * scale_px;
    const ang = fields.modelAngle(fields.angle(o));
    const ca = @cos(ang);
    const sa = @sin(ang);
    const p = fields.pos(o);
    fields.setPos(o, .{ p[0] + mx * ca - mz * sa, p[1] + mx * sa + mz * ca, p[2] });
}

/// Attached actor position: the parent's attachment point in the world.
/// `parent_offset` is the parent's AdjustAngle (+0x3200): the attachment points and
/// the attached actor's rotation are in the drawn parent model's axes (boat in 01_port: 180°).
pub fn followParent(a: *Actor, o: *Object, scale_px: f32, parent_offset: f32) void {
    const parent = a.attached_to orelse return;
    // Attachment tick 0x4cdbd0: mesh offset (z, x, y) × mesh height × aS (0x4bf9ab…
    // 0x4bf9e2) rotated by the parent angle (+0x2457c plus AdjustAngle +0x3200):
    // mesh z is forward, y is height; actor angle = parent angle plus point angle.
    // Axes match mesh drawing (toWorldLocal) so the position matches the model.
    // The parent's draw offset (+0x31f4…, bobbing) is added in tickPresentation.
    const ang = fields.angle(parent) + parent_offset;
    const m = fields.modelAngle(ang);
    const off = a.link_offset;
    const pp = fields.pos(parent);
    const mx = off[0] * scale_px;
    const mz = off[2] * scale_px;
    fields.setPos(o, .{ pp[0] + mx * @cos(m) - mz * @sin(m), pp[1] + mx * @sin(m) + mz * @cos(m), pp[2] + off[1] * scale_px });
    fields.setAngle(o, ang + a.link_angle);
}

test "battle walk turns in place before stepping onto the next cell" {
    // 0x48f400: per cell a turn 0x12 (stepping in place), then walking 0x11.
    const gpa = std.testing.allocator;
    var o: Object = .{ .name = "t", .class = undefined };
    defer o.vars.deinit(gpa);
    inline for (.{ "x", "y", "z", "angle", "rotspeed" }) |n|
        try o.declare(gpa, n, .{ .type = .float, .value = .{ .float = 0 } });
    fields.setF(&o, "rotSpeed", 0.1);
    var a: Actor = .{};
    defer a.path.deinit(gpa);
    var prng: Rand = .{};
    // Target behind (angle π): stands still until it has turned.
    try a.path.append(gpa, .{ -100, 0 });
    a.move_speed = 4;
    a.battle_walk = .{ .origin = .{ 0, 0 }, .anim = "walk" };
    var ticks: u32 = 0;
    while (@abs(fields.angleDiff(fields.angle(&o), std.math.pi)) > 1e-4) : (ticks += 1) {
        try std.testing.expectEqual(@as(f32, 0), fields.getF(&o, "x"));
        tick(&a, &o, null, 1, &prng);
        if (ticks > 100) return error.TestUnexpectedResult;
    }
    // 31 steps of 0.1 rad; the last turn step and the first walk step share a tick.
    try std.testing.expect(ticks >= 31);
    tick(&a, &o, null, 1, &prng);
    try std.testing.expect(fields.getF(&o, "x") < 0);
    try std.testing.expectEqualStrings("walk", a.anim);
}

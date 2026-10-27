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
    // A name the model lacks leaves the player as it was (0x44f960 → 0x44fa62): no transition.
    if (model) |m| if (m.anims.find(a.anim) == null) {
        a.anim_hold = 0;
    };
    if (a.anim_paused) {} else if (a.anim_hold > 0) a.anim_hold -= 1 else a.anim_ticks += 1;
    if (a.anim_hold == 0) a.hold_blend = false;
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
    while (a.path_index < a.path.items.len and !(a.hold_move and a.one_shot) and !a.hold_blend and a.delay == 0) : (guard += 1) {
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
            // Segment start: a route cell (command 0, 0x423993) faces the point or along the
            // next segment, whichever is closer to the current angle (0x423a3a…0x423b47) —
            // the next only if it is a cell too (same command type, 0x4239dd). A `.ap` path
            // node (command 0x11, 0x426ff8) faces its point straight (0x4237df → 0x4238db):
            // a stair's last node and the link's end cell share a point, and a zero next
            // segment would turn the climber to angle 0 (sideways or backwards).
            a.seg_index = a.path_index;
            const cur = fields.angle(o);
            var want = fields.facing(dx, dy);
            const isNode = struct {
                fn f(ac: *const Actor, k: usize) bool {
                    return k < ac.path_events.items.len and ac.path_events.items[k] != null;
                }
            }.f;
            if (!isNode(a, a.path_index) and a.path_index + 1 < a.path.items.len and !isNode(a, a.path_index + 1)) {
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
    if (model) |m| a.noteShown(m);
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
                    applyRootMotion(a, o, m, ref_first, an.last, scale_px);
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
                // Queued commands first (an IDLE_ANIMATION behind FAST_ANIMATION: no blend
                // through the old idle, city-kozov_dead); the world runs them right after.
                if (a.queue.items.len > 0) {
                    a.idle_due = true;
                    return;
                }
                // IDLE_OFF: no idle (0x422fa2), the last frame stays.
                if (a.idle_off) a.frozen = true else a.pickIdle(rand);
            }
        } else {
            a.one_shot = false;
            if (!a.hold_last) a.pickIdle(rand);
        }
    };
}

/// Moves and turns the actor by an "off-place" animation (0x44fe90): bone 0 of its last
/// frame against the reference animation's first frame — the translation without height,
/// and the turn of elements 0/6 (acos, negative when 6·0' − 0·6' < 0); reversed, both
/// negated (0x426733). The move is in the drawn model's axes (angle plus AdjustAngle, 0x4267c5).
fn applyRootMotion(a: *Actor, o: *Object, m: *const model_cache.Model, first: u32, last: u32, scale_px: f32) void {
    const fr = m.frames;
    if (fr.bones == 0 or first >= fr.frames or last >= fr.frames) return;
    const b0 = fr.matrix(first, 0);
    const b1 = fr.matrix(last, 0);
    const l0 = std.math.hypot(b0[0], b0[6]);
    const l1 = std.math.hypot(b1[0], b1[6]);
    var turn = std.math.acos(std.math.clamp((b0[0] * b1[0] + b0[6] * b1[6]) / (l0 * l1), -1, 1));
    if (b0[6] * b1[0] - b1[6] * b0[0] < 0) turn = -turn;
    const s: f32 = if (a.reverse) -1 else 1;
    a.off_place = .{ s * (b1[9] - b0[9]), 0, s * (b1[11] - b0[11]), s * turn };
    const mx = a.off_place[0] * scale_px;
    const mz = a.off_place[2] * scale_px;
    const ang = fields.modelAngle(fields.angle(o) + a.angle_offset);
    const ca = @cos(ang);
    const sa = @sin(ang);
    const p = fields.pos(o);
    fields.setPos(o, .{ p[0] + mx * ca - mz * sa, p[1] + mx * sa + mz * ca, p[2] });
    fields.setAngle(o, fields.angle(o) + a.off_place[3]); // 0x4233bc
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

test "a one-shot ending behind queued commands leaves the idle to the queue (0x4265d7)" {
    // city-kozov_dead: FAST_ANIMATION("Specnaz1","dead_B") + IDLE_ANIMATION(…,"dead_B")
    // with the old scene's g_idle still forced; picking it first blended through standing.
    const gpa = std.testing.allocator;
    var o: Object = .{ .name = "t", .class = undefined };
    defer o.vars.deinit(gpa);
    inline for (.{ "x", "y", "z", "angle", "rotspeed" }) |n|
        try o.declare(gpa, n, .{ .type = .float, .value = .{ .float = 0 } });
    var items = [_]@import("../formats.zig").anim.Animation{
        .{ .name = "dead_B", .first = 0, .last = 0, .speed = 1, .sounds = &.{} },
        .{ .name = "g_idle", .first = 1, .last = 9, .speed = 1, .sounds = &.{} },
    };
    var m: model_cache.Model = undefined;
    m.anims = .{ .arena = undefined, .items = &items };
    var a: Actor = .{};
    defer a.queue.deinit(gpa);
    var prng: Rand = .{};
    a.forced_idle = "g_idle";
    a.instant = true;
    a.play("dead_B", false, true);
    try a.queue.append(gpa, .{ .idle_anim = "dead_B" });
    for (0..3) |_| tick(&a, &o, &m, 1, &prng);
    try std.testing.expect(!a.one_shot and a.idle_due);
    try std.testing.expectEqualStrings("dead_B", a.anim);
    try std.testing.expectEqual(@as(u32, 0), a.anim_hold);
}

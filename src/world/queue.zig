//! Actor command queue (animation, delay, call, path, turn) and animation frame sounds
//! (0x44fb74…0x44fbe8).

const std = @import("std");
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;
const actor_mod = @import("../actor.zig");
const fields = @import("../fields.zig");
const model_cache = @import("../actor.zig").model_cache;
const Model = model_cache.Model;
const route = @import("route.zig");
const crt_rand = @import("../crt_rand.zig");
const runtime = @import("../script.zig").runtime;
const Runtime = runtime.Runtime;

/// Animation frame sounds (0x44fb74…0x44fbe8): reaching a marked frame plays the sound at
/// the actor; several marks on one frame pick one at random.
pub fn animCues(self: *World, o: *Object, a: *actor_mod.Actor, m: *const Model) !void {
    const an = m.anims.find(a.anim) orelse {
        a.cue_anim = "";
        return;
    };
    if (an.sounds.len == 0) {
        a.cue_anim = a.anim;
        return;
    }
    // A stopped animation (freeze, anim flag +0x34) neither steps nor sounds: 0x44faf1 exits
    // before frame sounds. A transition to a new animation (+0x19 = 2, our anim_hold) is
    // silent too; first-frame sounds play once it ends (0x44fb28 → 0x44fb74).
    if (a.anim_paused or a.anim_hold > 0) return;
    const f = m.frameOf(a.anim, a.anim_ticks, a.loop);
    if (a.mute_cues) {
        a.cue_anim = a.anim;
        a.cue_frame = f;
        a.cue_fresh = false;
        return;
    }
    const fresh = !std.mem.eql(u8, a.cue_anim, a.anim) or a.cue_fresh;
    a.cue_fresh = false;
    const from: u32 = if (fresh) an.first else a.cue_frame + 1;
    defer {
        a.cue_anim = a.anim;
        a.cue_frame = f;
    }
    if (!fresh and f == a.cue_frame) return;
    // Frames (from..f], wrapping for looping animations.
    var ranges: [2][2]u32 = undefined;
    var nr: usize = 0;
    if (f >= from) {
        ranges[0] = .{ from, f };
        nr = 1;
    } else {
        ranges[0] = .{ from, an.last };
        ranges[1] = .{ an.first, f };
        nr = 2;
    }
    const rand = self.crt();
    for (ranges[0..nr]) |rg| {
        var fr = rg[0];
        while (fr <= rg[1]) : (fr += 1) {
            const at = an.shown(fr, a.reverse);
            var n: u32 = 0;
            for (an.sounds) |cue| if (cue.frame == at) {
                n += 1;
            };
            if (n == 0) continue;
            var pick = rand.below(n);
            for (an.sounds) |cue| if (cue.frame == at) {
                if (pick == 0) {
                    const name = std.fs.path.stem(cue.name);
                    if (!std.ascii.eqlIgnoreCase(name, "silents")) self.out.sound(self.gpa, name, self.screenPos(o));
                    break;
                }
                pick -= 1;
            };
        }
    }
}

/// Actor command queue: the next command runs once the one-shot animation, path and delay
/// are done. Calls run back to back; animations and delays wait.
pub fn runQueue(self: *World, o: *Object, a: *actor_mod.Actor) !void {
    if (a.delay > 0) {
        a.delay -= 1;
        return;
    }
    // Commands behind a detached animation ran and the queue is empty: idle (0x4265f1 →
    // 0x422f90; without commands the exe lets the animation finish).
    var ran = false;
    defer if (ran and a.detached and a.one_shot and a.queue.items.len == 0 and a.delay == 0 and a.path_index >= a.path.items.len) a.pickIdle(self.crt());
    while (a.queue.items.len > 0 and (!a.one_shot or a.async_anim or a.detached) and a.path_index >= a.path.items.len) {
        const cmd = a.queue.orderedRemove(0);
        ran = true;
        switch (cmd) {
            .anim => |name| return a.play(a.resolve(name), false, true),
            .idle => {
                a.forced_idle = null;
                a.pickIdle(self.crt());
            },
            .delay => |n| {
                a.delay = n;
                return;
            },
            .call => |c| if (self.rt.findObject(c.object)) |obj| {
                _ = try self.rt.callIfExists(obj, c.func, &.{.{ .string = o.name }});
            },
            .async_anim => |aa| {
                a.play(a.resolve(aa.name), false, true);
                a.reverse = aa.reverse;
                a.async_anim = true;
            },
            .scene_anim => |sa| {
                a.play(sa.name, false, true);
                a.reverse = sa.reverse;
                a.repeat_left = sa.count -| 1;
                return;
            },
            // Empty name resets (scene end, 0x479075…0x47908a).
            .idle_anim => |name| {
                a.forced_idle = if (name.len == 0) null else a.resolve(name);
                if (!a.one_shot) a.pickIdle(self.crt());
            },
            .walk_anim => |wa| a.scene_walk = if (wa.name.len == 0) null else .{ .anim = wa.name, .speed = wa.speed },
            .walk => |bg| {
                try route.walkTo(self, o, bg);
                return;
            },
            .angle => |ang| fields.setAngle(o, ang),
        }
    }
}

test "reversed animation sounds follow the shown frame (0x44fb92)" {
    const anim = @import("../formats.zig").anim;
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = undefined, .fetch = undefined });
    defer rt.deinit();
    var cls: @import("../script.zig").object.Class = .{ .name = "a.aba", .parent = null };
    try cls.vars.appendSlice(rt.arena(), &.{
        .{ .type = .float, .name = "x", .line = 0 },
        .{ .type = .float, .name = "y", .line = 0 },
        .{ .type = .float, .name = "z", .line = 0 },
    });
    const o = try rt.createObject("a", &cls);
    var cues = [_]anim.SoundCue{.{ .name = "step.wav", .frame = 13, .volume = 0 }};
    var anims = [_]anim.Animation{.{ .name = "go", .first = 10, .last = 13, .speed = 0, .sounds = &cues }};
    var m: model_cache.Model = undefined;
    m.anims = .{ .arena = undefined, .items = &anims };
    var w: World = undefined;
    w.gpa = std.testing.allocator;
    crt_rand.global = .{};
    w.out.sound_events = .empty;
    w.cam = .ortho;
    defer w.out.sound_events.deinit(w.gpa);
    // Reversed, the first shown frame is last (13), which has the sound.
    var a: actor_mod.Actor = .{ .anim = "go", .reverse = true, .loop = false };
    try animCues(&w, o, &a, &m);
    try std.testing.expectEqual(1, w.out.sound_events.items.len);
    // Then 12, 11, 10 — silent.
    for (1..4) |t| {
        a.anim_ticks = @floatFromInt(t);
        try animCues(&w, o, &a, &m);
    }
    try std.testing.expectEqual(1, w.out.sound_events.items.len);
}

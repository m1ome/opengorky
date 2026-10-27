//! Actors: per-state animations, path walking, attachment to another actor.
//! An actor's position is the script variables `x, y, z, angle` (world, background pixels).

const std = @import("std");
const num = @import("num.zig");
const Rand = @import("crt_rand.zig").Rand;
const Allocator = std.mem.Allocator;
const object_mod = @import("script.zig").object;
const Object = object_mod.Object;
pub const model_cache = @import("actor/model_cache.zig");
pub const skin = @import("actor/skin.zig");
pub const camera = @import("actor/camera.zig");
pub const gltf = @import("actor/gltf.zig");
pub const slots = @import("actor/slots.zig");
pub const command = @import("actor/command.zig");
const fields = @import("fields.zig");
const adjust = @import("formats.zig").adjust;

pub const max_states = 10;
/// The exe has 9 states with animation sets (0..8): RegisterAnimation (0x422960) and
/// RegisterIdleAnimation (0x4229b0) skip other numbers.
pub const exe_states = 9;
/// Up to 8 idle animations per state (0x4229dc).
const max_idle = 8;

/// `broken`: a name of 16+ letters — the exe copies 16 bytes without a terminator (0x4229ff),
/// the weight sticks to the name and the animation is not found (0x44f910) — the idle does not change.
const Idle = struct { anim: []const u8, weight: u32, broken: bool = false };

const Mapping = struct { logical: []const u8, actual: []const u8 };

/// RegisterExtraBody slot (+0x2e64: still flag, +0x2e68 mesh, +0x2e6c its player): the
/// player's transition state like the actor's `last_frame`, `blend_from` and `poses`.
const ExtraBody = struct {
    mesh: []const u8,
    still: bool,
    last_frame: u32 = 0,
    blend_from: u32 = 0,
    poses: [2]std.ArrayList([12]f32) = .{ .empty, .empty },
    pose_drawn: u1 = 0,
    pose_from: ?u1 = null,
};

pub const Actor = struct {
    /// A victim held at this actor's link point (SetBind…): z/w offsets, release countdown.
    pub const Bind = struct { victim: *Object, link: []const u8, z: f32, w: f32 = 0, release_in: ?u32 = null, releasing: bool = false };

    placed: bool = false,
    /// State (0 normal, 2 in a boat, etc.): its own idle set.
    state: u8 = 0,
    /// Weapon detached from the hand point (+0x30d0 = 0 — no links): a sleeping
    /// fighter is not defending (0x490397). Only stance 0x42b300 (`setHoldState`)
    /// restores it: waking at the end of the turn (0x490510) does, the antidote (0x49006d,
    /// only 0x42b450) does not.
    weapon_detached: bool = false,
    idle: [max_states][max_idle]Idle = undefined,
    idle_count: [max_states]u8 = @splat(0),
    /// `RegisterAnimation(state, logical, file)`.
    mappings: std.ArrayList(struct { state: u8, m: Mapping }) = .empty,
    /// Reference animation (`ReferenceAnimation`): the "off-place" shift runs from its
    /// first frame to the animation's last frame.
    reference: []const u8 = "",
    /// Animations that move the actor (`NotInPlaceAnimation`).
    not_in_place: std.ArrayList([]const u8) = .empty,
    /// ActorSetWalkSpeed (0x422b50): speed per walk-animation logical slot (+0x2fbc),
    /// default 1 (0x42261b).
    speeds: [slots.logical_count]f32 = @splat(1.0),
    /// Current walk animation (logical name; ActorSetWalkAnimation changes it on paths).
    walk_anim: []const u8 = "walk",
    /// Floor: 0 — `.wm`, 1 — `.wm2` (TestActorMapChange).
    map: u1 = 0,
    /// Path point heights (NaN — keep), parallel to `path`.
    path_z: std.ArrayList(f32) = .empty,
    /// Path node events, parallel to `path`.
    path_events: std.ArrayList(?command.NodeEvent) = .empty,
    /// A node event that fired (the world takes it).
    node_event: ?command.NodeEvent = null,
    /// A one-shot animation holds movement (ActorAnimation on a ladder).
    hold_move: bool = false,
    /// One-shot animation at the next path point (ActorQueueWalkAnimation) and its
    /// direction (4th argument, bit 29 of the walk queue entry, 0x423f10).
    queued_anim: ?[]const u8 = null,
    queued_reverse: bool = false,
    /// Its 2nd argument (bit 30, 0x423f78 → 0x422f2b): played without the transition.
    queued_instant: bool = false,
    /// Walk animation reversed (ActorSetWalkAnimation(name, 1): +0x30d8 < 0).
    walk_reverse: bool = false,
    /// Turning toward path points disabled (ActorEnableRotation(0): +0x31e9, 0x424ce2) —
    /// on a ladder the actor faces the ladder.
    no_rotation: bool = false,
    /// Turn in place (queue command 0x12, 0x425150 → 0x423702, step 0x424d30):
    /// target angle; each tick rotSpeed along the shortest arc while the rest exceeds a
    /// step. While turning the actor is busy (attack and push wait for it).
    turn_to: ?f32 = null,
    /// "stepping" plays during the turn (slot 3, 0x4237d3 → 0x423620(3, …)).
    turn_step: bool = false,
    /// Path segment the walk angle was chosen for (0x423993) and the angle: at each
    /// segment start, whichever of "to the point" and "next segment" is closer to the
    /// current angle; the actor turns toward it while walking (0x424d30).
    seg_index: usize = std.math.maxInt(usize),
    walk_turn: f32 = 0,
    /// Battle walking by cells (0x48f400 hero, 0x499834 AI): per cell the queue gets
    /// a turn in place (command 0x12, 0x425150 — atan2 angle from where the actor
    /// stood when the path was set to the cell center) and then a walk
    /// (command 0x11, 0x4237df). The actor does not move until the turn ends; the
    /// first turn uses "stepping" (walking not started, +0x30dc), then the walk
    /// animation (0x422ea0 at the start of 0x11). null — normal walking (command 0).
    battle_walk: ?command.BattleWalk = null,

    anim: []const u8 = "",
    anim_ticks: f32 = 0,
    /// The last animation the model had (0x44f910: a name the model lacks leaves the model
    /// on the animation it was showing; `noteShown`, `frameIn`).
    shown: struct { anim: []const u8 = "", ticks: f32 = 0, loop: bool = true, reverse: bool = false } = .{},
    /// Transition into a new animation (player 0x44f910 with length 8, 0x423389): every
    /// `play` of another animation; the frame holds for the first ticks (+0x1c grows by
    /// 1/9 to 1 — 10 ticks), then one frame per tick. Strike and flash count from the start
    /// including it (Fatman — sound at frame 58, hit at tick 68).
    anim_hold: u32 = 0,
    /// The next `play` switches without the transition (+0x31e8, 0x4233c6; cleared by it,
    /// 0x4235f6): DisableInterpolation, hit reaction, stance idle and others.
    instant: bool = false,
    /// A one-shot ended with commands queued: the queue runs first and the idle is picked
    /// after it only if no command became current (0x4265d7…0x4265fb; `runQueue`).
    idle_due: bool = false,
    /// Movement waits for the transition to end (ActorQueueWaitForInterpolation, command
    /// 0x1d: done once +0x19 != 2, 0x424e5f).
    hold_blend: bool = false,
    /// Model frame drawn before the last `play` (+0x8, the transition's start pose) and
    /// the frame drawn last (set each tick by `noteShown`).
    blend_from: u32 = 0,
    last_frame: u32 = 0,
    /// Shift (model axes) and turn of the off-place animation that just ended (+0x2fb0,
    /// +0x2fa0, 0x42671d): position and angle already took them, so the next `play` takes
    /// them out of the start pose (`blend_shift`, 0x423439…0x4235c3) — else the body jumps
    /// ahead and the matrix lerp across the turn squashes the model.
    off_place: [4]f32 = @splat(0),
    blend_shift: [4]f32 = @splat(0),
    /// The drawn bone matrices, two buffers like the player's +0x10/+0x14: the viewer
    /// writes each drawn pose into `poses[pose_drawn]` (+0x4); a `play` mid-transition
    /// starts the next one from that pose (`pose_from`, +0x8 = +0x4, 0x44f9e2) instead
    /// of `blend_from`, and the next draw writes the other buffer (0x44fe00).
    poses: [2]std.ArrayList([12]f32) = .{ .empty, .empty },
    pose_drawn: u1 = 0,
    pose_from: ?u1 = null,
    loop: bool = true,
    /// One-shot animation: return to idle when it ends.
    one_shot: bool = false,
    /// Stay on the last frame after a one-shot animation (death in battle).
    hold_last: bool = false,
    /// Meshes on attachment points (ActivateLink / Actor_ActivateLink, 0x42ae00).
    links: std.ArrayList(command.Link) = .empty,
    /// Model offset from the position (SetActorAddVariables, +0x31f4): drawing and
    /// attachment points only; logic uses the normal position.
    render_offset: [3]f32 = .{ 0, 0, 0 },
    /// Frame sounds (0x44fb74): the animation and last frame whose sounds already played.
    /// Frame sounds of the current animation are off ([anim+0x30], 0x44fb7f): the
    /// dartgun has no pistol shot sound. Reset by a new animation.
    mute_cues: bool = false,
    cue_anim: []const u8 = "",
    cue_frame: u32 = 0,
    /// The animation was just (re)started — sounds from its first frame (play, repeat).
    cue_fresh: bool = true,
    /// Scene animation repeats left (ANIMATION, 3rd argument).
    repeat_left: u8 = 0,
    /// Scene walking (WALK_ANIMATION): animation and speed for the next paths.
    scene_walk: ?struct { anim: []const u8, speed: ?f32 } = null,
    /// Reversed animation (Actor_SetAsyncAnimation, 4th argument).
    reverse: bool = false,
    /// Async animation (+0x30de): the queue does not wait for it; without an idle for
    /// the state the model stays on the last frame (`frozen`).
    async_anim: bool = false,
    /// The one-shot animation plays on but its queue command is gone: 0x427c10
    /// (PLACE, PlaceHeroes) dropped it. Neither the queue nor WAITFORACTOR wait for it
    /// (0x42b020 checks only the command and the queue); an empty queue means idle
    /// (0x4265f1 → 0x422f90). Reset by a new animation.
    detached: bool = false,
    frozen: bool = false,
    /// Frozen fighter (+0x248e0 ≠ 0): every tick 0x48e940 sets animation flag +0x34
    /// (+0x245bc), and animation step 0x44fae0 stays on the current frame and never
    /// reaches the end. The world sets it from the battle before the tick.
    anim_paused: bool = false,
    /// IDLE_ANIMATION set by a scene, instead of a random pick.
    forced_idle: ?[]const u8 = null,
    /// IDLE_OFF (+0x30ec, command 0x26): no idle is picked (0x422fa2); an ended
    /// animation stays on its last frame.
    idle_off: bool = false,
    /// RegisterExtraBody (0x422a50, slots +0x2e64, 0x44 each): more meshes drawn in the
    /// actor's place; `still` (flag ≠ 0) — they don't play its animation (0x4233ec).
    extra_bodies: [4]?ExtraBody = @splat(null),

    angle_offset: f32 = 0,
    /// Model screen bounds in background pixels (last drawn frame; +0x64…+0x70).
    screen_box: ?[4]f32 = null,
    /// Command queue (ring +0x3568 in the exe): Actor_SetAnimation, Actor_QueueDelay,
    /// Actor_QueueGOScriptFunc run one by one after the current animation and path.
    queue: std.ArrayList(command.Command) = .empty,
    /// Actor_QueueDelay ticks left.
    delay: u32 = 0,
    /// Weapon in hand from a scene (WEAPON, 0x478500): mesh and point `two_hands`/`one_hand`.
    scene_weapon: ?struct { mesh: []const u8, two_hands: bool } = null,

    /// ActorModifyScale (0x4bf5c0): this actor's model scale multiplier.
    scale_mul: f32 = 1,
    /// Path in world coordinates (x, y) the actor walks.
    path: std.ArrayList([2]f32) = .empty,
    path_index: usize = 0,
    move_speed: f32 = 0,
    /// Walking a scenery track (WalkOnSceneryTrack) — no walk animation.
    on_track: bool = false,
    /// Attached to another actor (AttachActorsByLink, 0x4bf8e0): offset in the parent's
    /// mesh axes (chunk 11 shift + attachment point, mesh units) and the point angle (+0x30).
    attached_to: ?*Object = null,
    /// LinkActor (0x42ab60): the parent draws this actor at its mesh point (0x4297b4 —
    /// point matrix 0x4290f0, then this actor's mesh in its own animation), the actor
    /// itself is not drawn or shadowed (link count +0x2f7c: 0x42b210, 0x42a080).
    link_point: ?@import("formats.zig").mesh.HoldMode = null,
    link_offset: [3]f32 = .{ 0, 0, 0 },
    link_angle: f32 = 0,
    /// Vibrato(actor, amplitude, speed) (0x4cd9c0, tick 0x4cda90): vertical draw offset
    /// = sin(phase)·amplitude, phase += speed per tick.
    vibrato: [2]f32 = .{ 0, 0 },
    vibrato_phase: f32 = 0,
    /// Alpha (+0x311c, 0x42a620): 255 normal drawing, 1–254 blended,
    /// 0 invisible.
    alpha: u8 = 255,
    /// Effect state (+0x3120, 0x496d10): shock (2) or materialization (6).
    fx: command.Fx = .none,
    /// Materialization ticks (+0x3260) / shock ticks left.
    fx_ticks: u32 = 0,
    /// Invisible monster (nameID 120): visible while walking, when hit, dying and
    /// attacking; disappears when idle (0x4230c0).
    invisible: bool = false,
    /// Materialization start sound ("in_fadein" / "in_fadeout") for the world.
    fx_sound: ?[]const u8 = null,
    /// Transformation (ACTOR_MORPH, 0x42b5a0): ticks until the class and model change
    /// (morf_life2 = 50); the actor fades by 14 alpha per tick (0x426342).
    morph_left: u32 = 0,
    morph: ?struct { class: []const u8, mesh: []const u8, idle: []const u8 } = null,
    /// Time to change the class (the world calls applyMorph).
    morph_due: bool = false,
    /// Lifted victim (exe states 3/4): weight w grows by 0.1 per tick to 1, after
    /// `release_in` ticks it shrinks; victim offset = (attachment point − its position
    /// + (0, 0, z))·w.
    bind: ?Bind = null,
    /// Corpse (fighter death 0x425340: "death", animation end, pause
    /// actor_fade_delay = 30, then the fade flag): ticks after the death animation ended;
    /// then alpha −fighter_fade_speed (3) per tick until invisible (0x426919).
    corpse: ?u32 = null,
    /// The corpse faded out: the exe removes the object (+0x60 at 0x426950, alpha < 0).
    gone: bool = false,

    pub fn deinit(self: *Actor, gpa: Allocator) void {
        self.queue.deinit(gpa);
        self.mappings.deinit(gpa);
        self.not_in_place.deinit(gpa);
        self.links.deinit(gpa);
        self.path.deinit(gpa);
        self.path_events.deinit(gpa);
        self.path_z.deinit(gpa);
        for (&self.poses) |*p| p.deinit(gpa);
        for (&self.extra_bodies) |*eb| if (eb.*) |*b| for (&b.poses) |*p| p.deinit(gpa);
    }

    /// Walk speed with animation `anim` (0x422f58): its logical name's slot —
    /// "walk_footbridge" without ActorSetWalkSpeed gets 1, not the "walk" speed.
    pub fn speedOf(self: Actor, anim: []const u8) f32 {
        return self.speeds[slots.logicalIndex(anim)];
    }

    pub fn setSpeed(self: *Actor, anim: []const u8, v: f32) void {
        self.speeds[slots.logicalIndex(anim)] = v;
    }

    /// Stop walking: the path is cleared; if a walk animation was playing, go idle.
    pub fn stopWalking(self: *Actor, rand: *Rand) void {
        const walking = self.path_index < self.path.items.len or
            (self.loop and std.mem.eql(u8, self.anim, self.resolve(self.walk_anim)));
        self.clearPath();
        self.on_track = false;
        self.walk_anim = "walk";
        if (walking and !self.one_shot and !self.hold_last) self.pickIdle(rand);
    }

    /// Before applying a save: the path is reset; links and track movement come from
    /// the new load's init() (the boat at the start of 01_port: AttachActorsByLink,
    /// WalkOnSceneryTrack), not from the save.
    pub fn resetForLoad(self: *Actor) void {
        self.clearPath();
        self.attached_to = null;
        self.on_track = false;
        self.render_offset = .{ 0, 0, 0 };
        self.bind = null;
    }

    /// Animation shown at its last frame right away (an opened box after loading).
    pub fn holdLast(self: *Actor, anim: []const u8, reverse: bool) void {
        self.play(anim, false, false);
        self.hold_last = true;
        self.reverse = reverse;
        self.anim_ticks = 1e6;
    }

    pub fn clearPath(self: *Actor) void {
        self.path.clearRetainingCapacity();
        self.path_events.clearRetainingCapacity();
        self.path_z.clearRetainingCapacity();
        self.path_index = 0;
        self.seg_index = std.math.maxInt(usize);
        self.battle_walk = null;
    }

    pub fn addWaypoint(self: *Actor, gpa: Allocator, p: [3]f32, ev: ?command.NodeEvent) !void {
        // Events and heights are padded to the points (points may have been added without them).
        while (self.path_events.items.len < self.path.items.len) try self.path_events.append(gpa, null);
        while (self.path_z.items.len < self.path.items.len) try self.path_z.append(gpa, std.math.nan(f32));
        try self.path.append(gpa, .{ p[0], p[1] });
        try self.path_events.append(gpa, ev);
        try self.path_z.append(gpa, p[2]);
    }

    /// Walking an `.ap` path (ladder, plank): passed its node with more nodes ahead.
    /// The exe does not interrupt such a transition — otherwise the actor would stay on
    /// ladder cells with no way out.
    pub fn onPortal(self: Actor) bool {
        const i = self.path_index;
        if (i == 0 or i >= self.path.items.len or i >= self.path_events.items.len) return false;
        return self.path_events.items[i - 1] != null and self.path_events.items[i] != null;
    }

    /// End of the `.ap` transition the actor is on (`onPortal`): the last of the
    /// consecutive node points ahead (in the exe the target of queue command 3, +0x31b4/+0x31b8).
    /// Height is NaN if the point has none.
    pub fn portalEnd(self: Actor) ?[3]f32 {
        if (!self.onPortal()) return null;
        var j = self.path_index;
        while (j + 1 < self.path.items.len and j + 1 < self.path_events.items.len and self.path_events.items[j + 1] != null) j += 1;
        const z = if (j < self.path_z.items.len) self.path_z.items[j] else std.math.nan(f32);
        return .{ self.path.items[j][0], self.path.items[j][1], z };
    }

    /// RegisterIdleAnimation (0x4229b0): state 0..8, up to 8 animations.
    pub fn registerIdle(self: *Actor, state: u8, anim: []const u8, weight: u32) void {
        if (state >= exe_states or self.idle_count[state] == max_idle) return;
        self.idle[state][self.idle_count[state]] = .{ .anim = anim, .weight = weight, .broken = anim.len >= 16 };
        self.idle_count[state] += 1;
    }

    /// Copy state `src`'s set (animations and idles) into `dst` (0x42b6f0).
    pub fn copyState(self: *Actor, gpa: Allocator, src: u8, dst: u8) !void {
        var i: usize = 0;
        while (i < self.mappings.items.len) {
            if (self.mappings.items[i].state == dst) _ = self.mappings.orderedRemove(i) else i += 1;
        }
        const n = self.mappings.items.len;
        for (0..n) |k| {
            const e = self.mappings.items[k];
            if (e.state == src) try self.mappings.append(gpa, .{ .state = dst, .m = e.m });
        }
        self.idle[dst] = self.idle[src];
        self.idle_count[dst] = self.idle_count[src];
    }

    /// Hold state (0x42b450): in battle 0 and 1 become 7 and 8 — their sets
    /// are copies of 0 and 1 with extra idles (additionalIdleAnims).
    pub fn setState(self: *Actor, state: u8, combat: bool) void {
        self.state = if (combat and state <= 1) state + 7 else state;
    }

    /// Stance without a special state: 0/1 out of battle, 7/8 in battle.
    pub fn holdState(self: Actor) bool {
        return self.state <= 1 or self.state == 7 or self.state == 8;
    }

    /// RegisterAnimation (0x422960): slot [state][logical name number]
    /// (0x4280e0) — a repeated write overwrites ("stair_up" takes the "stair_down" slot).
    /// The exe writes unknown names into shared slot 0, which it never reads: we keep
    /// them by name (in the data all such names map to themselves).
    pub fn registerMapping(self: *Actor, gpa: Allocator, state: u8, logical: []const u8, actual: []const u8) !void {
        const idx = slots.logicalIndex(logical);
        if (idx != 0) for (self.mappings.items) |*e| if (e.state == state and slots.logicalIndex(e.m.logical) == idx) {
            e.m = .{ .logical = logical, .actual = actual };
            return;
        };
        try self.mappings.append(gpa, .{ .state = state, .m = .{ .logical = logical, .actual = actual } });
    }

    /// The .ani animation name for a logical name in the current state (command
    /// 0x13 with a flag, 0x423d88: slot [+0x31cc][number]). Deviation: if the slot is
    /// empty in the current state the exe plays nothing, while we take another state's
    /// mapping or the name as is (only happens to heroes whose weapon is not in hand
    /// in gorky-tool auto-battles).
    pub fn resolve(self: Actor, name: []const u8) []const u8 {
        const idx = slots.logicalIndex(name);
        const same = struct {
            fn f(e: Mapping, n: []const u8, i: u8) bool {
                return if (i != 0) slots.logicalIndex(e.logical) == i else std.ascii.eqlIgnoreCase(e.logical, n);
            }
        }.f;
        for (self.mappings.items) |e| if (e.state == self.state and same(e.m, name, idx)) return e.m.actual;
        for (self.mappings.items) |e| if (same(e.m, name, idx)) return e.m.actual;
        return name;
    }

    /// Whether the class has logical name `name` (RegisterAnimation).
    pub fn hasMapping(self: Actor, name: []const u8) bool {
        for (self.mappings.items) |e| if (std.ascii.eqlIgnoreCase(e.m.logical, name)) return true;
        return false;
    }

    pub fn isNotInPlace(self: Actor, anim: []const u8) bool {
        for (self.not_in_place.items) |a| if (std.ascii.eqlIgnoreCase(a, anim)) return true;
        return false;
    }

    pub fn play(self: *Actor, anim: []const u8, loop: bool, one_shot: bool) void {
        self.turn_step = false;
        if (self.invisible) {
            // 0x4230c0: "sm", "traf" and a new "chod" appear; others except attacks
            // disappear (unless appearing is running and the monster is visible).
            const eq = std.ascii.eqlIgnoreCase;
            if (eq(anim, "sm") or eq(anim, "traf") or (eq(anim, "chod") and !eq(self.anim, "chod"))) {
                self.materialize(true);
            } else if (!eq(anim, "chod") and !std.ascii.startsWithIgnoreCase(anim, "atak") and self.fx != .appear and self.alpha != 0 and self.fx != .vanish) {
                self.materialize(false);
            }
        }
        self.mute_cues = false;
        self.idle_due = false;
        // 0x44f910: the same animation still running goes on (+0x19 == 1; the actor
        // restarts a looping one itself when it ends); ended or mid-transition it restarts
        // without one. Shortcut: only looping ones count as running here, a non-looping
        // replay restarts (no model length at hand).
        const same = std.ascii.eqlIgnoreCase(anim, self.anim);
        if (!(same and loop and self.loop and self.anim_hold == 0)) {
            self.anim_ticks = 0;
            self.cue_fresh = true;
        }
        self.anim = anim;
        // 0x44f9dc: mid-transition (+0x19 == 2) the new one starts from the drawn pose.
        self.pose_from = if (self.anim_hold > 0 and self.poses[self.pose_drawn].items.len > 0) self.pose_drawn else null;
        // A moving extra body's player gets the same call (0x423409): its own start pose.
        for (&self.extra_bodies) |*eb| if (eb.*) |*b| if (!b.still) {
            b.pose_from = if (self.anim_hold > 0 and b.poses[b.pose_drawn].items.len > 0) b.pose_drawn else null;
            b.blend_from = b.last_frame;
        };
        self.anim_hold = if (same or self.instant) 0 else blend_ticks;
        self.instant = false;
        self.blend_from = self.last_frame;
        self.blend_shift = self.off_place;
        self.off_place = @splat(0);
        self.loop = loop;
        self.one_shot = one_shot;
        self.reverse = false;
        self.repeat_left = 0;
        self.async_anim = false;
        self.detached = false;
        self.frozen = false;
    }

    /// Clears the queue, pause and path (0x427c10): the current command is dropped, its
    /// one-shot animation plays out by itself (ANIMATION repeats too, counter +0x3184
    /// untouched) but no longer holds anything.
    pub fn dropCommands(self: *Actor, rand: *Rand) void {
        self.queue.clearRetainingCapacity();
        self.delay = 0;
        self.turn_to = null;
        self.stopWalking(rand);
        if (self.one_shot) self.detached = true;
    }

    /// Materialization (state 6, 0x496d10): appear or vanish over ≈17 ticks;
    /// sound in_fadein / in_fadeout.
    pub fn materialize(self: *Actor, appear: bool) void {
        self.fx = if (appear) .appear else .vanish;
        self.fx_ticks = 0;
        self.alpha = 255;
        self.fx_sound = if (appear) "in_fadein" else "in_fadeout";
    }

    /// Shock (state 2, 0x491c91): a "current" pass for `ticks` ticks.
    /// Shock shake, 30 ticks.
    pub fn shock(self: *Actor) void {
        const ticks: u32 = @intCast(@max(0, adjust.getInt("attack_shocker_shocked_timeout", 30)));
        if (self.fx == .appear or self.fx == .vanish) return;
        self.fx = .shock;
        self.fx_ticks = ticks;
    }

    /// Visibility during materialization (0x42a2e0): v = min(1, 0.06·ticks), vanishing
    /// 1 − v; null when not materializing.
    pub fn fxLevel(self: Actor) ?f32 {
        const v = @min(1, 0.06 * num.toF32(self.fx_ticks));
        return switch (self.fx) {
            .appear => v,
            .vanish => 1 - v,
            else => null,
        };
    }

    /// Start the corpse fade after the death animation.
    pub fn startCorpseFade(self: *Actor) void {
        self.corpse = 0;
    }

    pub fn tickFx(self: *Actor) void {
        if (self.corpse) |*t| if (!self.one_shot) {
            if (t.* < adjust.getInt("actor_fade_delay", 30)) t.* += 1 else {
                // An invisible monster fades without materialization.
                if (self.invisible) self.fx = .none;
                const speed: u8 = @intCast(std.math.clamp(adjust.getInt("fighter_fade_speed", 3), 0, 255));
                if (self.alpha < speed) self.gone = true;
                self.alpha -|= speed;
            }
        };
        if (self.morph_left > 0) {
            self.morph_left -= 1;
            self.alpha -|= @intCast(std.math.clamp(adjust.getInt("morf_add", 14), 0, 255));
            if (self.morph_left == 0) {
                self.alpha = 255;
                self.morph_due = true;
            }
        }
        switch (self.fx) {
            .none => {},
            .shock => {
                if (self.fx_ticks > 0) self.fx_ticks -= 1;
                if (self.fx_ticks == 0) self.fx = .none;
            },
            // 0x49716c: counter +1; when 0.06·counter ≥ 1 it ends, a vanished one
            // becomes transparent.
            .appear, .vanish => {
                self.fx_ticks += 1;
                if (0.06 * num.toF32(self.fx_ticks) >= 1) {
                    if (self.fx == .vanish) self.alpha = 0;
                    self.fx = .none;
                }
            },
        }
    }

    /// Model frame for the current animation (reversed: from the last frame to the first).
    pub fn frameIn(self: Actor, m: *const model_cache.Model) u32 {
        // A name the model lacks (Mac Fadden's idle "jo_g_idle"): the animation shown before.
        // The player never loops by itself (+0x18 = 0 in every 0x44f910 call): a looping
        // one is restarted by the actor replaying its name, which now misses — so it runs
        // to its last frame and stays there (0x44fce8; Slavsky's walk before "su_idle").
        if (self.anim.len > 0 and m.anims.find(self.anim) == null) if (m.anims.find(self.shown.anim)) |a| {
            const len: f32 = @floatFromInt(a.last - a.first + 1);
            const t = if (self.shown.loop) @mod(@floor(self.shown.ticks), len) else self.shown.ticks;
            return a.shown(m.frameOf(self.shown.anim, t + self.anim_ticks, false), self.shown.reverse);
        };
        const f = m.frameOf(self.anim, self.anim_ticks, self.loop);
        const a = m.anims.find(self.anim) orelse return f;
        return a.shown(f, self.reverse);
    }

    /// Each tick: the animation, if the model has it, is the one it shows (drawn on when a
    /// later name isn't in the model; the actor's own logic still treats that one as ended).
    pub fn noteShown(self: *Actor, m: *const model_cache.Model) void {
        self.last_frame = self.frameIn(m);
        if (self.anim.len == 0 or m.anims.find(self.anim) == null) return;
        self.shown = .{ .anim = self.anim, .ticks = self.anim_ticks, .loop = self.loop, .reverse = self.reverse };
    }

    /// Transition ticks (0x44f910 with length 8: +0x20 = 1/9, +0x1c from −1/9).
    pub const blend_ticks: u32 = 10;

    /// Weight of the new animation's frame over `blend_from` while a transition runs
    /// (0x44fdc0: +0x1c + +0x20, capped at 1 — 0, 1/9 … 1 after each tick); null after it.
    pub fn blendWeight(self: Actor) ?f32 {
        if (self.anim_hold == 0) return null;
        return @min(1, @as(f32, @floatFromInt(blend_ticks -| self.anim_hold)) / @as(f32, @floatFromInt(blend_ticks - 1)));
    }

    /// Animation from the queue (ActorQueueWalkAnimation); false if the queue is empty.
    pub fn playQueued(self: *Actor) bool {
        const q = self.queued_anim orelse return false;
        self.queued_anim = null;
        if (self.queued_instant) self.instant = true;
        self.play(self.resolve(q), false, true);
        self.reverse = self.queued_reverse;
        return true;
    }

    /// Random idle animation of the current state (weighted).
    pub fn pickIdle(self: *Actor, rand: *Rand) void {
        self.idle_due = false;
        if (self.idle_off) return; // 0x422fa2: before the forced idle too
        if (self.forced_idle) |a| return self.play(a, true, false);
        const n = self.idle_count[self.state];
        if (n == 0) {
            if (self.anim.len == 0 or self.one_shot) self.play("", true, false);
            return;
        }
        var total: u32 = 0;
        for (self.idle[self.state][0..n]) |e| total += e.weight;
        // Weight sum 0 — the exe picks no idle (0x423000).
        if (total == 0) return;
        // Weighted pick (0x423019: rand % sum, first with cumulative weight > r).
        // If a "broken" one (16+ letter name) comes up, the exe plays nothing and picks
        // again when the animation ends; we pick again at once.
        var tries: u32 = 0;
        while (tries < 16) : (tries += 1) {
            var r = rand.below(total);
            for (self.idle[self.state][0..n]) |e| {
                if (r < e.weight) {
                    if (e.broken) break;
                    return self.play(e.anim, false, false);
                }
                r -= e.weight;
            }
        }
    }

    pub fn busy(self: Actor) bool {
        // A frozen fighter's standing animation never ends and is not waited for (the exe
        // queue waits for commands, not another animation's frames).
        // An async animation (command 0x14) holds nothing either: an empty queue is idle.
        return (self.one_shot and !self.detached and !self.async_anim and !self.anim_paused) or self.path_index < self.path.items.len or self.queue.items.len > 0 or self.delay > 0 or self.turn_to != null;
    }

    /// Smooth turn to `angle` (command 0x12, 0x423702): shortest-arc difference;
    /// over 0.1 rad (0x508768) before walking started (+0x30dc) means "stepping"
    /// in place if the actor has it. The turn itself happens in `tick`.
    pub fn turnTo(self: *Actor, o: *Object, angle: f32) void {
        const cur = fields.angle(o);
        const diff = std.math.atan2(@sin(angle - cur), @cos(angle - cur));
        if (@abs(diff) < 1e-4) {
            fields.setAngle(o, angle);
            self.turn_to = null;
            return;
        }
        self.turn_to = angle;
        if (@abs(diff) > 0.1 and self.path_index >= self.path.items.len and !self.one_shot and self.hasMapping("stepping")) {
            self.play(self.resolve("stepping"), true, false);
            self.turn_step = true;
        }
    }
};

test "dropCommands leaves the one-shot playing but frees the actor" {
    // museum-slavsky, skipped: knee_idle ×20 runs, WALKTO on skip becomes PLACE
    // (0x427c10); the command is dropped, neither WAITFORACTOR nor the queue wait for it.
    const gpa = std.testing.allocator;
    var prng: Rand = .{};
    var a: Actor = .{};
    defer a.queue.deinit(gpa);
    a.play("knee_idle", false, true);
    a.repeat_left = 19;
    try a.queue.append(gpa, .idle);
    try std.testing.expect(a.busy());
    a.dropCommands(&prng);
    try std.testing.expect(!a.busy());
    try std.testing.expect(a.one_shot and a.detached);
    try std.testing.expectEqualStrings("knee_idle", a.anim);
    a.play("idle", false, false);
    try std.testing.expect(!a.detached);
}

test "animation slots and walk speeds follow the exe logical-name table" {
    const gpa = std.testing.allocator;
    var a: Actor = .{};
    defer a.mappings.deinit(gpa);
    // "stair_up" writes into the "stair_down" slot (0x4280e0 → 13 for both).
    try a.registerMapping(gpa, 0, "stair_down", "stair_dwn");
    try a.registerMapping(gpa, 0, "stair_up", "stair_up");
    try std.testing.expectEqualStrings("stair_up", a.resolve("stair_down"));
    // Speed per slot: walk_footbridge without its own speed gets 1, not the walk speed.
    a.setSpeed("walk", 5.2);
    try std.testing.expectEqual(@as(f32, 5.2), a.speedOf("walk"));
    try std.testing.expectEqual(@as(f32, 1.0), a.speedOf("walk_footbridge"));
    // An idle with a 16+ letter name does not play (0x4229ff → 0x44f910).
    var prng: Rand = .{ .state = 3 };
    a.registerIdle(0, "oddychanieszybkie", 1);
    a.registerIdle(0, "drapanie", 1);
    for (0..20) |_| {
        a.pickIdle(&prng);
        try std.testing.expectEqualStrings("drapanie", a.anim);
    }
    // The exe skips states 9 and above.
    a.registerIdle(9, "x", 1);
    try std.testing.expectEqual(@as(u8, 0), a.idle_count[9]);
}

test "play blends into another animation unless instant; the same looping one runs on (0x44f910)" {
    var a: Actor = .{};
    a.play("walk", true, false);
    try std.testing.expectEqual(Actor.blend_ticks, a.anim_hold);
    a.anim_hold = 0;
    a.anim_ticks = 5;
    a.play("walk", true, false);
    try std.testing.expectEqual(@as(f32, 5), a.anim_ticks);
    try std.testing.expectEqual(@as(u32, 0), a.anim_hold);
    a.instant = true;
    a.play("idle", false, false);
    try std.testing.expect(a.anim_hold == 0 and !a.instant and a.anim_ticks == 0);
    a.play("hit", false, true);
    a.play("hit", false, true); // mid-blend into the same one: restart without it
    try std.testing.expectEqual(@as(u32, 0), a.anim_hold);
    // Interrupted transition: the next starts from the pose drawn (0x44f9e2), else a frame.
    defer a.deinit(std.testing.allocator);
    try a.poses[1].append(std.testing.allocator, @splat(1));
    a.pose_drawn = 1;
    a.play("walk", true, false);
    try std.testing.expectEqual(@as(?u1, null), a.pose_from);
    a.play("idle", false, false);
    try std.testing.expectEqual(@as(?u1, 1), a.pose_from);
    // An off-place end's shift goes to the next transition only (0x423439, cleared 0x4235cb).
    a.off_place = .{ 3, 0, 4, 1 };
    a.play("look", false, true);
    try std.testing.expectEqual([4]f32{ 3, 0, 4, 1 }, a.blend_shift);
    a.play("idle", false, false);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, a.blend_shift);
}

test "an animation the model lacks leaves the one shown running (0x44f910)" {
    var items = [_]@import("formats.zig").anim.Animation{.{ .name = "g_idle", .first = 10, .last = 19, .speed = 1, .sounds = &.{} }};
    var m: model_cache.Model = undefined;
    m.anims = .{ .arena = undefined, .items = &items };
    var a: Actor = .{};
    a.play("g_idle", false, false);
    a.anim_ticks = 4;
    a.noteShown(&m);
    a.play("jo_g_idle", false, false); // Mac Fadden's idle her model doesn't have
    a.noteShown(&m);
    try std.testing.expectEqual(@as(u32, 14), a.frameIn(&m));
    a.play("jo_g_look", false, false); // picked again: still the last frame shown
    try std.testing.expectEqual(@as(u32, 14), a.frameIn(&m));

    // A looping one (walk) plays out its cycle, then holds its last frame (0x44fce8).
    a.play("g_idle", true, false);
    a.anim_ticks = 23; // third cycle, frame 3
    a.noteShown(&m);
    a.play("su_idle", true, false); // Slavsky's IDLE_ANIMATION his model doesn't have
    a.anim_ticks = 2;
    try std.testing.expectEqual(@as(u32, 15), a.frameIn(&m));
    a.anim_ticks = 100;
    try std.testing.expectEqual(@as(u32, 19), a.frameIn(&m));
}

test {
    _ = camera;
    _ = gltf;
}

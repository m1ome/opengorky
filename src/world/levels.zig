//! Location changes: leaving, returning, deferred steps after LEVEL_Load.

const std = @import("std");
const state_groups = @import("../state.zig").groups;
const fields = @import("../fields.zig");
const world = @import("../state.zig").world;
const World = world.World;

/// Leave the location before it is stored (0x41f6c8…0x41f729, then 0x41fe50 → 0x411e60).
/// Exe order:
/// 1. An actor standing on a `.ap` transition (ladder, plank: +0x31b0, queue command 3) is
///    put at its end (0x421c70 → 0x422c90), except in battle.
/// 2. Fighters (`.hro`, `.ftr`, heroes; +0x2c == 6) lose queue, command and path and get a
///    random idle (0x427c50: 0x427c10, 0x422f90). The exe moves them on in the global
///    list; our hero copy stays in this world and must look the same on return.
/// 3. Shadows (0x411f35): with `shadowActive`, positions of enabled fighters.
/// Plain actors (`.act`) and other objects stay as they are; their queue, path and
/// animation continue on return (0x411c40).
pub fn leave(self: *World, next: []const u8) !void {
    const combat = self.isCombat();
    const rand = self.crt();
    // Entering battle from a non-battle location (0x41f219 = 1): 480 × (rand % 2, % 8, % 2)
    // for the transition stripes (0x41f25b…0x41f2ba), before the fighters' idles.
    if (!combat and std.mem.indexOf(u8, next, "__") != null) for (0..480 * 3) |_| {
        _ = rand.next();
    };
    for (self.actorObjects()) |o| {
        const n = World.nativeOf(o);
        if (n.kind != .actor) continue;
        const a = &n.actor;
        if (!combat) if (a.portalEnd()) |e| {
            const z = if (std.math.isNan(e[2])) fields.pos(o)[2] else e[2];
            a.dropCommands(rand);
            fields.setPos(o, .{ e[0], e[1], z });
        };
        if (!n.fighter) continue;
        a.dropCommands(rand);
        // Also drop an unfinished scene animation (Ovitz in knee_idle ×10 after
        // museum-medusa_crazy into battle): 0x422f90 restarts the idle.
        a.repeat_left = 0;
        a.one_shot = false;
        a.hold_last = false;
        a.async_anim = false;
        a.reverse = false;
        a.detached = false;
        a.forced_idle = null;
        a.scene_walk = null;
        a.pickIdle(rand);
        a.anim_hold = 0; // 0x427c5f: +0x1c = 1, the blend is over
    }
    self.shadows.clearRetainingCapacity();
    const l = self.level orelse return;
    if (combat or l.getInt("shadowActive") == 0) return;
    for (self.actorObjects()) |o| {
        const n = World.nativeOf(o);
        if (n.kind != .actor or !n.fighter or n.deleted or !o.enabled or !n.actor.placed) continue;
        try self.shadows.append(self.gpa, .{ .name = o.name, .pos = fields.pos(o), .angle = fields.angle(o), .map = n.actor.map });
    }
}

/// Re-enter a stored location (0x411cd0): same objects as on leaving, no init() or
/// post_init(). The level's restore(), then fighter shadows (with `shadowActive`), then the
/// other restore()s — shadows override PlaceHeroes from the level's restore() (after the
/// hotel roof battle heroes stay on the roof, not at capt_start). A hero without a shadow
/// (disabled, or arrived from elsewhere) stays where restore() put him.
pub fn reenter(self: *World) !void {
    self.flow.pending_level = null;
    self.act.interaction = null;
    // A scene may have left via LOADLEVEL without GUI_NORMAL…
    self.scene.cutscene = false;
    self.scene.panorama = false;
    // …or without AUTOCAMERA_ON (port-meet_bt goes into battle 01__port_trabant): on return
    // the camera follows the party again and the mouse scrolls.
    if (self.scene.runner == null) self.scene.autocamera = true;
    self.out.attack_cam = null;
    self.scene.fade = 0;
    self.scene.fade_target = 0;
    // Enable every party hero first; the level's restore() disables extras again
    // (DisableHeroes in the tunnel and the worker's room: only the selected hero inside).
    for (self.rt.objects.items) |o| if (World.nativeOf(o).hero) {
        o.enabled = true;
    };
    if (self.level) |l| _ = try self.rt.callIfExists(l, "restore", &.{});
    for (self.shadows.items) |sh| {
        const o = self.actorObject(sh.name) orelse continue;
        const a = world.actorOf(o);
        a.map = sh.map;
        fields.setPos(o, sh.pos);
        fields.setAngle(o, sh.angle);
        a.placed = true;
    }
    self.shadows.clearRetainingCapacity();
    for (self.rt.objects.items) |o| {
        if (World.nativeOf(o).kind == .level or !World.nativeOf(o).kind.hooks().restore) continue;
        _ = try self.rt.callIfExists(o, "restore", &.{});
    }
    try afterSelectGui(self);
}

/// Deferred calls from the previous location (ownership passes to the caller).
pub fn takeLoadSteps(self: *World) ![]state_groups.LoadStep {
    return self.flow.load_steps.toOwnedSlice(self.gpa);
}

/// The level's after_select_gui(), at the end of every load (0x41f8f4). Battles put the
/// pre-battle dialogue (StartDialog), a video or EndTurnGlobal there.
pub fn afterSelectGui(self: *World) !void {
    const first = self.out.video_requests.items.len;
    if (self.level) |l| _ = try self.rt.callIfExists(l, "after_select_gui", &.{});
    for (self.out.video_requests.items[first..]) |*rq| rq.level_music = true;
}

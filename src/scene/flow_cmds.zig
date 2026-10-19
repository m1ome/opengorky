//! Scene commands: waits, level changes, add-on scenes, GUI modes, the party.

const std = @import("std");
const num = @import("../num.zig");
const fields = @import("../fields.zig");
const inventory = @import("../inventory.zig");
const walk = @import("../world.zig").walk;
const scriptlet = @import("../formats.zig").scriptlet;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const Runner = @import("../state.zig").scene.Runner;

/// Scene flow: waits, level changes, add-on scenes, GUI modes, the party.
pub fn execFlow(self: *Runner, w: *World, c: scriptlet.Command, n: []const u8) !bool {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(n, "DELAY")) {
        self.wait = .{ .ticks = @intCast(@max(0, c.arg(0).int())) };
        return true;
    }
    if (eq(n, "WAITFORACTOR")) {
        if (w.rt.findObject(c.arg(0).str())) |o| self.wait = .{ .actor = o };
        return true;
    }
    if (eq(n, "GUI_CUTSCENE") or eq(n, "GUI_NORMAL") or eq(n, "GUI_ENABLE")) {
        // GUI_CUTSCENE also enables the autocamera (0x450ec5); GUI_NORMAL puts the camera on the hero.
        w.scene.cutscene = eq(n, "GUI_CUTSCENE");
        if (w.scene.cutscene) w.scene.autocamera = true else w.out.camera_snap = true;
        return true;
    }
    if (eq(n, "LOADLEVEL")) {
        w.scene.mp3 = false;
        w.flow.pending_level = try w.arena_state.allocator().dupe(u8, c.arg(0).str());
        self.wait = .moving;
        return true;
    }
    if (eq(n, "PREVLEVEL")) {
        w.scene.mp3 = false;
        w.flow.want_prev_level = true;
        self.wait = .moving;
        return true;
    }
    if (eq(n, "WAITFORANIMATION")) {
        if (w.rt.findObject(c.arg(0).str())) |o| self.wait = .{ .aba = o };
        return true;
    }
    if (eq(n, "SETHERO")) {
        const o = w.actorObject(c.arg(0).str()) orelse return true;
        World.nativeOf(o).hero = c.arg(1).num() != 0;
        World.nativeOf(o).hro = true;
        o.setInt("avoidEnumerate", @intFromBool(c.arg(1).num() == 0));
        return true;
    }
    if (eq(n, "PLACEHEROES")) {
        walk.placeHeroes(w, c.arg(0).str(), c.arg(1).int());
        return true;
    }
    if (eq(n, "STOP_HEROES")) {
        // The party stands and looks around at once ("fightlook", 0x47885a).
        for (w.rt.objects.items) |o| if (World.nativeOf(o).hero) {
            const a = world_mod.actorOf(o);
            a.clearPath();
            a.play("fightlook", false, true);
        };
        return true;
    }
    if (eq(n, "ADDONSCRIPTLET")) {
        // ADDONSCRIPTLET("scene") (0x47875d): into the deferred slot (0x5266a8).
        if (c.args.len >= 1 and c.args[0] == .string) w.scene.addon = try w.arena_state.allocator().dupe(u8, c.arg(0).str());
        return true;
    }
    if (eq(n, "GUI_CREDITS")) {
        // End of the game (`lab-the_end`): on this flag the host shows the credits, then
        // the main menu. (GUI_ENDDEMO in `gateopen` ends the demo; no-op in the full game.)
        w.flow.game_over = true;
        return true;
    }
    if (eq(n, "GO_RUNFUN")) {
        const o = w.rt.findObject(c.arg(0).str()) orelse return true;
        _ = try w.rt.callIfExists(o, c.arg(1).str(), &.{});
        return true;
    }
    if (eq(n, "PLAYAVI")) {
        try w.out.video_requests.append(w.gpa, .{
            .name = try w.arena_state.allocator().dupe(u8, c.arg(0).str()),
            .x = c.arg(1).int(),
            .y = c.arg(2).int(),
            .double = c.arg(3).num() != 0,
        });
        return true;
    }
    if (eq(n, "NO_SKIP")) {
        self.no_skip = true;
        return true;
    }
    if (eq(n, "GUI_DISABLE")) {
        // 0x45a3f0: panorama off, panel windows closed.
        w.scene.panorama = false;
        return true;
    }
    if (eq(n, "GUI_MENU") or eq(n, "GUI_ENDDEMO")) {
        // After GUI_CREDITS (game end) the host switches to the menu.
        return true;
    }
    return false;
}

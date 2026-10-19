//! Scene runner for `.scr` (StartScriptlet).
//!
//! Commands run one after another until a wait (DELAY, WAITFORACTOR,
//! DIALOG_DISPLAY, FADE_*). Meanings come from their use in scenes and dialog
//! comments, checked against the exe (addresses on the commands).

const std = @import("std");
const num = @import("../num.zig");
const fields = @import("../fields.zig");
const inventory = @import("../inventory.zig");
const scriptlet = @import("../formats.zig").scriptlet;
const dialog = @import("../formats.zig").dialog;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const Runner = @import("../state.zig").scene.Runner;
const Object = @import("../script.zig").object.Object;
const flow_cmds = @import("flow_cmds.zig");
const actor_cmds = @import("actor_cmds.zig");
const show_cmds = @import("show_cmds.zig");

/// Deliberate deviation from the exe (player's request): in museum-slavsky after
/// two lines Slavsky stays on his knees for a sway or two, not every repeat of
/// `ANIMATION("Slavsky","knee_idle",20)`; in the exe that is ≈53 s of silence
/// (20 × 80 frames, 0x4266e7) and the scene looked stuck. While the scene waits
/// for the actor (WAITFORACTOR), repeats of this animation are cut: the current
/// loop finishes (no frame jump), then the next command (knee_up).
const RepeatTrim = struct { scene: []const u8, actor: []const u8, anim: []const u8 };
const repeat_trims = [_]RepeatTrim{
    .{ .scene = "museum-slavsky", .actor = "Slavsky", .anim = "knee_idle" },
};

fn trimRepeats(scene: []const u8, o: *Object) void {
    for (repeat_trims) |t| {
        if (!std.ascii.eqlIgnoreCase(scene, t.scene) or !std.ascii.eqlIgnoreCase(o.name, t.actor)) continue;
        const a = world_mod.actorOf(o);
        if (std.ascii.eqlIgnoreCase(a.anim, t.anim)) a.repeat_left = 0;
        // Not started yet (knee still playing): one loop instead of all repeats.
        for (a.queue.items) |*c| switch (c.*) {
            .scene_anim => |*sa| if (std.ascii.eqlIgnoreCase(sa.name, t.anim)) {
                sa.count = 1;
            },
            else => {},
        };
    }
}

/// One scene tick.
pub fn step(self: *Runner, w: *World) !void {
    switch (self.wait) {
        .none => {},
        .ticks => |*t| {
            if (t.* > 0) {
                t.* -= 1;
                return;
            }
            self.wait = .none;
        },
        .actor => |o| {
            trimRepeats(self.name, o);
            // A disabled or deleted actor doesn't tick: nothing to wait for.
            if (o.enabled and !World.nativeOf(o).deleted and world_mod.actorOf(o).busy()) return;
            self.wait = .none;
        },
        .aba => |o| {
            const st = o.getInt("state");
            if (o.enabled and (st == 1 or st == 3 or World.nativeOf(o).aba_move != null)) return;
            self.wait = .none;
        },
        .moving => return,
        .panorama => {
            w.scene.panorama_h -= 2;
            if (w.scene.panorama_h >= 0) return;
            w.scene.panorama = false;
            w.scene.panorama_h = 42;
            self.wait = .none;
        },
        .goindown => |g| {
            const p = fields.pos(g.o);
            const d = g.z - p[2];
            if (@abs(d) > g.step) {
                fields.setPos(g.o, .{ p[0], p[1], p[2] + std.math.sign(d) * g.step });
                return;
            }
            fields.setPos(g.o, .{ p[0], p[1], g.z });
            self.wait = .none;
        },
        .dialog => {
            if (w.scene.line_open) return;
            w.scene.subtitle = null;
            self.wait = .none;
        },
    }
    while (self.pc < self.commands.len and self.wait == .none) {
        const c = self.commands[self.pc];
        self.pc += 1;
        try exec(self, w, c);
        // Skip (0x478950): a line counts as done at once (except a level change).
        if (self.skip and self.wait != .moving) self.wait = .none;
    }
}

fn exec(self: *Runner, w: *World, raw: scriptlet.Command) !void {
    const eq = std.ascii.eqlIgnoreCase;
    // `#NAME` arguments read the exe's global string table (0x476561); the game's scenes
    // use only #HERO_SELECTED and #LAST_ACTION_HERO, kept here as world state.
    var args_buf: [8]scriptlet.Arg = undefined;
    var c = raw;
    if (raw.args.len <= args_buf.len) {
        for (raw.args, 0..) |a, i| args_buf[i] = switch (a) {
            .string => |s| .{ .string = if (eq(s, "#HERO_SELECTED")) w.selected_hero else if (eq(s, "#LAST_ACTION_HERO")) w.scene.last_action_hero else s },
            else => a,
        };
        c.args = args_buf[0..raw.args.len];
    }
    const n = exeName(c.name);
    if (try flow_cmds.execFlow(self, w, c, n)) return;
    if (try actor_cmds.execActor(self, w, c, n)) return;
    if (try show_cmds.execShow(self, w, c, n)) return;
    // Not in the exe table: "Syntax error" (0x477abe), the line doesn't run. No
    // scene the game starts has any (full playthrough: list empty);
    // DIALOG_WAITFORCHANGE and DIALOG_CLOSE exist only in the unused corpses,
    // gateopen1 and dialog_test.
    try w.countMissing("scr:", n);
}

/// Command order of the exe table (0x4763f0): a name matches by the command's
/// length (strncmp), first match wins. So the glued typo
/// `FADE_INDIALOG_DISPLAY(0)` in `port-deska.scr` runs as FADE_IN.
const exe_order = [_][]const u8{
    "PLACEHEROES",    "WALKTO",       "PLACE",            "NO_SKIP",        "ACTOR_MORPH",    "EARTHQUAKE",         "MP3_PLAY",            "MP3_FADE",
    "GUI_DISABLE",    "GUI_CREDITS",  "GUI_MENU",         "GUI_ENABLE",     "GUI_CUTSCENE",   "GUI_ENDDEMO",        "GUI_GAMEOVER",        "GUI_NORMAL",
    "ACTORSETSTATE",  "PLAYAVI",      "WAITFORACTOR",     "FX_WEAPON",      "VOLTAGE",        "ROCKET",             "ATTACK",              "USEANIMATION",
    "FAST_ANIMATION", "ANIMATION",    "SYSTEMANIMATION",  "GO_RUNFUN",      "SIGNATURE_ON",   "SIGNATURE_OFF",      "IMPULSEOBJECT",       "ABA_MOVE",
    "ABA_POS",        "ABA_STATE",    "WAITFORANIMATION", "DELAY",          "LOADLEVEL",      "PREVLEVEL",          "DIALOG_INIT",         "DIALOG_DISPLAY",
    "DIALOG_SHOW",    "PANORAMA_OFF", "PANORAMA_ON",      "AUTOCAMERA_ON",  "AUTOCAMERA_OFF", "DISABLEOBJECT",      "DELETEOBJECT",        "IDLE_OFF",
    "ASSIGN_ITEM",    "IDLE_ON",      "IDLE_ANIMATION",   "WALK_ANIMATION", "FADE_IN",        "FADE_BLACK",         "FADE_OUT",            "WALK_ON_SCENERY_TRACK",
    "ACTOR_GOINDOWN", "ZOOM",         "DOLLY",            "WEAPON",         "SOUND",          "ALLOW_WALK_IN_AREA", "FORBID_WALK_IN_AREA", "ADDONSCRIPTLET",
    "SETHERO",        "STOP_HEROES",  "WALKAREA",
};

/// Command name as the exe reads it (the first table command the line starts
/// with); otherwise as is.
pub fn exeName(name: []const u8) []const u8 {
    for (exe_order) |cmd| if (std.ascii.startsWithIgnoreCase(name, cmd)) return cmd;
    return name;
}

test exeName {
    try std.testing.expectEqualStrings("FADE_IN", exeName("FADE_INDIALOG_DISPLAY"));
    try std.testing.expectEqualStrings("PLACEHEROES", exeName("PLACEHEROES"));
    try std.testing.expectEqualStrings("SIGNATURE", exeName("SIGNATURE"));
}

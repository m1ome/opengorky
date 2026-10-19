//! Cutscenes and dialogues: start, abort, deferred, skip, speaker name.

const std = @import("std");
const show_cmds = @import("show_cmds.zig");
const fields = @import("../fields.zig");
const archive = @import("../formats.zig").archive;
const scriptlet = @import("../formats.zig").scriptlet;
const world = @import("../state.zig").world;
const World = world.World;
const fx_mod = @import("../fx.zig");
const MovingScene = World.MovingScene;
const scenario = @import("scenario.zig");

/// Scene step. At the end (0x478fd0, 0x4790b5): autocamera, music back to before
/// MP3_PLAY, zoom back to 1 (0x4790ad), next scene from pause, ADDONSCRIPTLET, queue.
pub fn tick(self: *World) !void {
    const s = &self.scene;
    const sc = &(s.runner orelse return);
    try scenario.step(sc, self);
    if (!sc.done()) return;
    s.runner = null;
    s.autocamera = true;
    // Every actor's queue (0x479060…0x479093): the scene's idle and walk are reset
    // (commands 0x27 and 0x28 with an empty name).
    for (self.actorObjects()) |o| {
        const n = World.nativeOf(o);
        if (n.kind != .actor or n.deleted) continue;
        try n.actor.queue.append(self.gpa, .{ .idle_anim = "" });
        try n.actor.queue.append(self.gpa, .{ .walk_anim = .{ .name = "", .speed = null } });
    }
    self.out.zoom_reset = true;
    if (s.mp3) {
        s.mp3 = false;
        self.out.music_restore = true;
    }
    if (s.paused) |p| {
        s.runner = p;
        s.paused = null;
    } else if (s.addon) |next| {
        // Deferred scene (0x4791a9…0x4791ca): name longer than two letters.
        s.addon = null;
        if (next.len > 2) startScriptlet(self, next) catch |err| std.log.warn("scriptlet {s}: {t}", .{ next, err });
    } else if (s.queue.items.len > 0) {
        const next = s.queue.orderedRemove(0);
        startScriptlet(self, next) catch |err| std.log.warn("scriptlet {s}: {t}", .{ next, err });
    }
}

/// Fade step (0x420110), before the battle tick.
pub fn tickFade(self: *World) void {
    const s = &self.scene;
    const step: f32 = 1.0 / @as(f32, show_cmds.fade_ticks);
    if (s.fade < s.fade_target) s.fade = @min(s.fade_target, s.fade + step);
    if (s.fade > s.fade_target) s.fade = @max(s.fade_target, s.fade - step);
}

/// ROCKET reached its target (0x49c720): no weapon, so no strike (0x49b920);
/// explosion at its point (0x4d0610) and "granat".
pub fn tickRockets(self: *World) !void {
    const rockets = &self.scene.rockets;
    var pi: usize = 0;
    while (pi < rockets.items.len) {
        const sr = rockets.items[pi];
        if (self.effects.projectileAlive(sr.id)) {
            pi += 1;
            continue;
        }
        _ = rockets.orderedRemove(pi);
        fx_mod.explosion.explosion(self, sr.target);
        const q = self.cam.project(sr.target);
        self.out.sound(self.gpa, "granat", .{ q.x, q.y });
    }
}

/// The host started voicing a line: `bytes` is its file size in `voice.dat`, 0 =
/// voice off (the line waits for a click). Duration (0x4597d0 → 0x40f260) is
/// size / 8192 s, not the sound length. Without an audio host (gorky-tool) the
/// text estimate from DIALOG_DISPLAY stays.
pub fn voiceStarted(self: *World, bytes: u32) void {
    const s = &self.scene;
    const sub = s.subtitle orelse return;
    s.timeLine(sub.text.len, @as(f64, @floatFromInt(bytes)) / 8192);
}

/// Skip the whole scene (0x479220; Space in the exe, Esc here): the voice fades,
/// the dialog box hides, remaining commands run at once; NO_SKIP forbids it.
pub fn skipScene(self: *World) bool {
    const sc = &(self.scene.runner orelse return false);
    if (sc.no_skip or sc.skip) return false;
    sc.skip = true;
    self.scene.subtitle = null;
    self.scene.line_open = false;
    self.out.voice_cut = true;
    // 0x479220: the next line runs at once; the current wait (pause, actor,
    // animation, line) is dropped; level change, panorama bars and descent finish
    // by themselves.
    switch (sc.wait) {
        .ticks, .actor, .aba, .dialog => sc.wait = .none,
        else => {},
    }
    return true;
}

/// Skip the current scene line (click, 0x459b22 → 0x4593c0): next page, or the
/// line ends; the page counter runs on. A mid-line page turn keeps the voice.
/// Ending the line cuts it: in the exe the player's skip is held Space (0x459b16
/// cuts the voice), ours is Space/click here — deviation, else a skipped battle
/// dialogue keeps talking after its box is gone. false if there is no line.
pub fn skipLine(self: *World) bool {
    if (self.scene.subtitle == null or !self.scene.line_open) return false;
    self.scene.nextPage();
    if (!self.scene.line_open) self.out.voice_cut = true;
    return true;
}

/// Take the scene that continues on the next level.
pub fn takeMovingScene(self: *World) !?MovingScene {
    const sc = self.scene.runner orelse return null;
    if (sc.wait != .moving) return null;
    // Copy first: an allocation failure must not lose the scene.
    const name = try self.gpa.dupe(u8, sc.name);
    errdefer self.gpa.free(name);
    const dialog_file = try self.gpa.dupe(u8, sc.dialog_file);
    self.scene.runner = self.scene.paused;
    self.scene.paused = null;
    self.scene.cutscene = false;
    return .{ .name = name, .pc = sc.pc, .dialog_file = dialog_file };
}

/// Continue an incoming scene here (the level's own scene runs after it).
pub fn resumeScene(self: *World, m: MovingScene) !void {
    defer {
        self.gpa.free(m.name);
        self.gpa.free(m.dialog_file);
    }
    const a = self.arena_state.allocator();
    if (self.scene.runner) |cur| {
        self.scene.paused = cur;
        self.scene.runner = null;
    }
    try startScriptlet(self, m.name);
    const sc = &(self.scene.runner orelse return);
    sc.pc = m.pc;
    if (m.dialog_file.len > 0) {
        sc.dialog_file = try a.dupe(u8, m.dialog_file);
        sc.dialog = show_cmds.loadDialog(self, sc.dialog_file) catch |err| blk: {
            if (err == error.OutOfMemory) return err;
            std.log.warn("dialog {s}: {t}", .{ sc.dialog_file, err });
            break :blk null;
        };
    }
}

/// StartScriptlet (0x478e20): the running scene is aborted, its lines dropped
/// without the scene end (0x478fd0 not called), skip cleared; the new one starts
/// from its first line on the next tick.
pub fn startScriptlet(self: *World, name: []const u8) !void {
    if (self.scene_host) |h| return startScriptlet(h, name);
    const a = self.arena_state.allocator();
    if (self.scene.runner) |cur| {
        // DialogInit is a GUI window in the exe (0x45b400), not a scene: wait for it.
        if (std.mem.eql(u8, cur.name, "dialog")) {
            for (self.scene.queue.items) |q| if (std.ascii.eqlIgnoreCase(q, name)) return;
            try self.scene.queue.append(a, try a.dupe(u8, name));
            return;
        }
        // Same scene: the port and city ladders call it from update() every tick while
        // the hero is in the area. The exe restarts it, but FADE_OUT doesn't reset the
        // fade (0x4200b0 sets only the target) and PLACEHEROES moves the hero on the same
        // tick as without a restart; our FADE waits in ticks, so we don't restart.
        if (std.ascii.eqlIgnoreCase(cur.name, name)) return;
    }
    const gop = try self.scene.scriptlet_cache.getOrPut(a, name);
    if (!gop.found_existing) {
        errdefer self.scene.scriptlet_cache.removeByPtr(gop.key_ptr);
        gop.key_ptr.* = try a.dupe(u8, name);
        var buf: [archive.name_size]u8 = undefined;
        const scr = self.res.common.find(try std.fmt.bufPrint(&buf, "scriptlets\\{s}.scr", .{name})) orelse return error.NotFound;
        const cmds = try scriptlet.parse(a, try self.res.common.readAlloc(self.io, a, scr));
        const pts = if (self.res.common.find(try std.fmt.bufPrint(&buf, "scriptlets\\{s}.pts", .{name}))) |e|
            try scriptlet.parsePoints(a, try self.res.common.readAlloc(self.io, a, e))
        else
            &.{};
        gop.value_ptr.* = .{ .cmds = cmds, .pts = pts };
    }
    self.scene.runner = .{ .name = gop.key_ptr.*, .commands = gop.value_ptr.cmds, .points = gop.value_ptr.pts };
}

/// Defer a scene until the current one ends (SetAddonScriptlet 0x4791e0,
/// ADDONSCRIPTLET 0x47875d): one slot; with no scene running it starts at once.
pub fn setAddonScriptlet(self: *World, name: []const u8) !void {
    if (self.scene_host) |h| return setAddonScriptlet(h, name);
    if (self.scene.runner == null) return startScriptlet(self, name);
    self.scene.addon = try self.arena_state.allocator().dupe(u8, name);
}

/// A whole dialog (DialogInit): lines one by one, like a scene named "dialog".
pub fn startDialog(self: *World, name: []const u8, file: []const u8) !void {
    // While enemies are appearing the dialog waits (deployment mode is above it in the GUI stack).
    if (self.battle) |*b| if (b.phase == .appear and !b.wait_dialog) {
        self.scene.pending_dialog = .{ name, file };
        return;
    };
    const d = show_cmds.loadDialog(self, file) catch return;
    const a = self.arena_state.allocator();
    const cmds = try a.alloc(scriptlet.Command, d.lines.len + 1);
    const init_args = try a.dupe(scriptlet.Arg, &.{ .{ .string = try a.dupe(u8, name) }, .{ .string = try a.dupe(u8, file) } });
    cmds[0] = .{ .name = "DIALOG_INIT", .args = init_args, .line = 0 };
    for (cmds[1..], 0..) |*c, i| {
        c.* = .{ .name = "DIALOG_DISPLAY", .args = try a.dupe(scriptlet.Arg, &.{.{ .number = @floatFromInt(i) }}), .line = 0 };
    }
    if (self.scene.runner == null) self.scene.runner = .{ .name = "dialog", .commands = cmds, .points = &.{} };
}

/// Speaker name in the line box (0x459b93…0x459c3c): if the world has an actor
/// with that name (0x431b40, first object, case-insensitive; +0x60 actor,
/// 0x459249), the `string.tab` line by its nameID (+0x58, 0x40f370; "Not
/// Defined" if missing), else the `.dlg` name as is (HQ, Lamar on the radio).
pub fn speakerName(self: *World, speaker: []const u8) []const u8 {
    const o = self.actorObject(speaker) orelse return speaker;
    return self.stringOr(fields.nameId(o), "Not Defined");
}

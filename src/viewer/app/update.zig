//! Viewer tick: level-up points, menu music, videos, world, transitions, camera.

const std = @import("std");
const flow = @import("flow.zig");
const viewer = @import("viewer.zig");
const og = @import("opengorky");
const c = @import("sdl");
const Viewer = viewer.Viewer;
const camera_view = @import("../level/camera.zig");
/// Frame delay in resource view mode (in level mode the speed comes from .var).
const frame_ms = 100;

/// Level-up points (0x48fa30): allocation window at (250, 40) with music
/// upgradeparameters; on Accept the previous music.
pub fn checkLevelUp(v: *Viewer) void {
    const g = v.gui orelse return;
    const l = &(v.level orelse return);
    const w = l.world;
    w.gui_hold = g.stats.modal;
    if (g.stats.modal) return;
    if (v.upgrade_music) |m| {
        v.upgrade_music = null;
        w.out.music_events.append(w.gpa, .{ .name = m }) catch {};
    }
    if (w.scene.cutscene or w.scene.panorama) return;
    const heroes = w.party();
    for (heroes.slice()) |hero| {
        if (og.state.world.World.nativeOf(hero).growth.stat_points <= 0) continue;
        g.stats.show(250, 40, hero.name, true, og.inventory.points.takeLevelPoints(hero));
        w.gui_hold = true;
        w.out.sound(w.gpa, "battle_menuslide_in", null);
        if (l.scene) |*sc| v.upgrade_music = sc.music_name;
        w.out.music_events.append(w.gpa, .{ .name = "upgradeparameters", .once = true }) catch {};
        return;
    }
}

/// Main menu music (`menu.mp3`, 0x4146d1) while the menu is open without a level
/// and no video plays; stops when the game starts.
pub fn menuMusic(v: *Viewer) void {
    const snd = v.sound orelse return;
    const m = v.menu orelse return;
    // Credits (GUI_CREDITS, 0x42c5e0) — "credits"; main menu without a level — "menu".
    const name: ?[]const u8 = if (v.video != null or !m.open)
        null
    else if (m.screen == .credits)
        "credits"
    else if (v.level == null) "menu" else null;
    if (v.menu_music) |id| {
        const same = if (name) |n| std.mem.eql(u8, n, v.menu_music_name) else false;
        if (same and snd.mixer.find(id) != null) return;
        snd.mixer.stop(id);
        v.menu_music = null;
    }
    const n = name orelse return;
    const music = snd.bank.music(n) orelse return;
    v.menu_music = snd.mixer.playAs(v.gpa, .music, music, 1, 0, true) catch null;
    v.menu_music_name = n;
}

/// The world skipped this frame (menu, video, frozen frame): re-anchor its clock so
/// it does not catch up on the missed ticks afterwards.
pub fn hold(v: *Viewer) void {
    if (v.level) |*l| l.last_tick_ms = 0;
}

pub fn update(v: *Viewer) void {
    // --input: one world tick per frame (repeatable shots, independent of frame rate).
    const now = if (v.input_mode) blk: {
        v.virt_ms += 1000 / og.state.world.tick_hz;
        break :blk v.virt_ms;
    } else c.SDL_GetTicks();
    checkLevelUp(v);
    // World videos (AVI_Play, PLAYAVI) go to the queue.
    if (v.level) |*l| if (l.world.out.video_requests.items.len > 0) {
        // Videos run on the SDL clock; under `--input` they would eat a varying number of world ticks.
        if (!v.input_mode) v.video_queue.appendSlice(v.gpa, l.world.out.video_requests.items) catch {};
        l.world.out.video_requests.clearRetainingCapacity();
        v.nextVideo();
    };
    if (v.video) |vd| {
        vd.update();
        if (vd.done) v.stopVideo(false);
        hold(v);
        return;
    }
    // Frozen game over frame: the world stands.
    if (v.gui) |g| if (g.go_frame != null) return hold(v);
    if (v.transition) |*tr| {
        tr.ticks += 1;
        // Transition sound (screenoff4) now, not after returning to the level.
        if (v.level) |*l| l.updateSound(v.scroll) catch {};
        // Exe 0x41f0b0: 9 ticks of squeeze, then the saw turns one frame per tick; the
        // level loads after ≥ 10 saw ticks on a whole turn (no saw sprite: exactly 10).
        const saw = tr.ticks -| 8;
        const frames: u32 = if (v.gui) |g| @intCast(g.spinner.len()) else 0;
        if (saw < 10 or (if (frames > 0) saw % frames != 0 else saw != 10)) return;
    }
    if (v.level) |*l| {
        if (v.transition == null) l.update(now) catch |err| {
            std.log.err("world tick failed, game stopped: {t}", .{err});
            l.failed = true;
        };
        // Defeat (0x454350): after 90 ticks (the engine queues the music), a frozen frame
        // with the "Repeat Battle" choice.
        if (l.world.battle) |*b| if (b.phase == .lost and b.over_ticks >= 90) if (v.gui) |g| if (g.go_frame == null and !g.go_capture) {
            g.go_capture = true;
        };
        // The same screen from a scene's GUI_GAMEOVER.
        if ((l.world.flow.defeat_ticks orelse 0) >= 90) if (v.gui) |g| if (g.go_frame == null and !g.go_capture) {
            g.go_capture = true;
        };
        // Victory (0x454880): the engine queues the jingle at 90 ticks; after
        // another 150, back to the level where the battle began (AfterBattle).
        // The report (0x451d70) opens after the banner; once closed, go back.
        if (l.world.battle) |b| if (b.phase == .won and b.over_ticks > 240 and (v.gui == null or v.gui.?.report_done)) if (v.game.leaveBattle()) {
            if (v.gui) |g| g.report_done = false;
        };
        // Game end: the scene finished — credits, then the main menu.
        if (v.game.takeGameOver()) {
            if (v.menu) |m| {
                v.closeAll();
                // No game any more: after the credits, the main menu without "resume"/"save".
                m.show(.main);
                m.show(.credits);
                return;
            }
        }
        if (!l.failed) if (v.game.pendingLevel()) |next| {
            // Entering battle from a regular level: the saw transition first.
            if (v.transition == null and !v.shot_run and std.mem.indexOf(u8, next, "__") != null and !l.world.isCombat()) {
                v.transition = .{};
                l.world.out.music_events.append(l.world.gpa, .{ .name = "screenoff4", .once = true }) catch {};
                return;
            }
            if (v.transition) |tr| {
                if (tr.snap) |t| c.SDL_DestroyTexture(t);
                v.transition = null;
            }
            // Game-state errors stop the game, as a failed tick does.
            flow.switchLevel(v, next) catch |err| {
                std.log.err("level switch failed, game stopped: {t}", .{err});
                if (v.level) |*nl| nl.failed = true;
            };
            return;
        };
        // Camera on world ticks. After a level switch the world counter differs
        // (battle and cached levels count their own ticks), so no jump.
        const ticks = if (l.world.ticks >= v.cam_tick) @min(l.world.ticks - v.cam_tick, 30) else 0;
        if (v.play) og.game.idleChatter(l.world, &v.idle_ticks, ticks) catch |err| {
            std.log.err("idle chatter failed, game stopped: {t}", .{err});
            l.failed = true;
        };
        v.cam_tick = l.world.ticks;
        for (0..@min(ticks, 30)) |_| camera_view.cameraTick(v, l);
        l.updateSound(v.scroll) catch |err| std.log.warn("sound: {t}", .{err});
    }
    if (v.playing and now - v.last_tick >= frame_ms and v.frames.len() > 1) {
        v.frame = (v.frame + 1) % v.frames.len();
        v.last_tick = now;
    }
}

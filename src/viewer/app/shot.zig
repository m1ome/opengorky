//! `--shot` and `--frames`: prepare the scene without a player window (console,
//! world ticks, camera) and write PNGs. Interactive steps go through `--input`.

const std = @import("std");
const flow = @import("flow.zig");
const debug_layers = @import("../level/debug_layers.zig");
const frame = @import("frame.zig");
const update = @import("update.zig");
const render = @import("render.zig");
const commands = @import("commands.zig");
const camera_view = @import("../level/camera.zig");
const og = @import("opengorky");
const c = @import("sdl");
const viewer = @import("viewer.zig");
const Viewer = viewer.Viewer;
const Options = @import("options.zig").Options;
const Video = @import("../media/video.zig").Video;

pub fn run(v: *Viewer, opts: *const Options, io: std.Io, gpa: std.mem.Allocator, renderer: *c.SDL_Renderer, path: []const u8) !void {
    // Game mode: slot load.
    if (opts.load_slot) |k| {
        try flow.loadGame(v, k - 1);
        if (v.menu) |m| m.open = false;
    }
    // Credits shot: --time is how long they have been running.
    if (v.menu) |m| if (m.open and m.screen == .credits) {
        m.credits_skip_ms = opts.time_ms;
    };
    if (v.level) |*l| {
        if (opts.heroes) debug_layers.placeHeroes(l, v.scroll);
        // Ticks by time without real waiting.
        const ticks = opts.time_ms * og.state.world.tick_hz / 1000;
        for (0..ticks) |_| try og.game.tick(l.world);
        for (opts.console_cmds[0..opts.n_console]) |cmd| commands.consoleRun(v, cmd);
        if (opts.n_console > 0 and !std.ascii.eqlIgnoreCase(opts.console_cmds[opts.n_console - 1], "close")) v.console.open = true;
        update.checkLevelUp(v);
        if (opts.scroll[0] == 0 and opts.scroll[1] == 0) if (v.level.?.cameraGoal()) |goal| {
            v.scroll = .{ 0, 0 };
            camera_view.scrollBy(v, goal[0], goal[1]);
        };
        // Shot camera: play out its ticks (DOLLY, zoom, scene autocamera).
        if (opts.scroll[0] == 0 and opts.scroll[1] == 0) if (v.level) |*lv| {
            for (0..300) |_| camera_view.cameraTick(v, lv);
            v.cam_tick = lv.world.ticks;
        };
    }
    if (opts.video) |name| {
        var buf: [600]u8 = undefined;
        const vpath = Video.find(&buf, io, opts.game_dir, name) orelse return error.NoVideo;
        const vd = Video.open(gpa, io, renderer, vpath, 0, 60, true) orelse return error.NoFfmpeg;
        v.video = vd;
        vd.seek(@as(f64, @floatFromInt(opts.time_ms)) / 1000);
        std.log.info("video {s}: {d}x{d}, frame {d}, audio {d} samples", .{ name, vd.w, vd.h, vd.shown, if (vd.sound) |snd| snd.samples.len else 0 });
    }
    if (opts.frames > 0) if (opts.frames_dir) |dir| if (v.level != null) {
        var pb: [600]u8 = undefined;
        for (0..opts.frames) |k| {
            frame.beginFrame(v);
            try render.render(v);
            try v.screenshot(try std.fmt.bufPrint(&pb, "{s}/{d:0>3}.png", .{ dir, k }));
            const cur = &v.level.?;
            try og.game.tick(cur.world);
            camera_view.cameraTick(v, cur);
            v.cam_tick = cur.world.ticks;
        }
        return;
    };
    frame.beginFrame(v);
    try render.render(v);
    return v.screenshot(path);
}

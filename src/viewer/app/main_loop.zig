//! Viewer main loop: input script, events, background pause, world tick,
//! drawing, gamma, present and frame cap.

const std = @import("std");
const viewer = @import("viewer.zig");
const og = @import("opengorky");
const c = @import("sdl");
const Viewer = viewer.Viewer;
const events = @import("events.zig");
const input_ctx = @import("input_ctx.zig");
const frame = @import("frame.zig");
const update = @import("update.zig");
const pause = @import("pause.zig");
const render = @import("render.zig");
const perf = @import("perf.zig");
const InputScript = @import("input_script.zig").InputScript;
const AudioOut = @import("../media/audio.zig").AudioOut;

pub fn run(v: *Viewer, ctx: *input_ctx.Ctx, script: *?InputScript, audio_out: *?AudioOut, quit_at: ?u64) !void {
    while (true) {
        const frame_start = c.SDL_GetTicksNS();
        if (quit_at) |t| if (c.SDL_GetTicks() >= t) return;
        if (script.*) |*sc| if (try sc.step(v, ctx.window, ctx.renderer) == .quit) return;
        var ev: c.SDL_Event = undefined;
        var had_event = false;
        while (c.SDL_PollEvent(&ev)) {
            had_event = true;
            if (try events.handle(v, ctx, ev) == .quit) return;
        }
        if (v.quit) return;
        // Save name entry uses SDL text input (the console enables its own).
        if (v.menu) |m| if (!v.console.open) {
            const want = m.open and m.editing != null;
            if (want != c.SDL_TextInputActive(ctx.window)) {
                _ = if (want) c.SDL_StartTextInput(ctx.window) else c.SDL_StopTextInput(ctx.window);
            }
        };
        // Videos play even with the menu open (intro videos before the main menu).
        // Unfocused: `fps_background` cap (no frame if also minimised/occluded), and
        // with `pause_background` the world and audio stop (update.hold re-anchors
        // the world clock); focused: `fps_limit`. --input,
        // --frames and shots run uncapped and unpaused.
        const flags = c.SDL_GetWindowFlags(ctx.window);
        const free_run = v.input_mode or ctx.opts.frames > 0 or ctx.opts.shot != null;
        const always_on = free_run or ctx.opts.active;
        const unfocused = !always_on and flags & c.SDL_WINDOW_INPUT_FOCUS == 0;
        const bg = pause.state(v.cfg.pause_background, !unfocused, flags & (c.SDL_WINDOW_MINIMIZED | c.SDL_WINDOW_OCCLUDED | c.SDL_WINDOW_HIDDEN) != 0);
        const unseen = bg.unseen;
        const paused = bg.paused;
        if (paused and v.pause_start == null) {
            v.pause_start = c.SDL_GetTicks();
            if (audio_out.*) |*a| a.setPaused(true);
        } else if (!paused) if (v.pause_start) |ps| {
            // Video audio was paused with the device, so its clock is too.
            if (v.video) |vd| vd.start_ms +%= c.SDL_GetTicks() -% ps;
            v.pause_start = null;
            if (audio_out.*) |*a| a.setPaused(false);
        };
        if (!paused) update.menuMusic(v);
        const pt_update = perf.now();
        if (!paused and (v.video != null or v.menu == null or !v.menu.?.open)) update.update(v) else update.hold(v);
        perf.add(.update, pt_update);
        const fps_cap: u32 = if (free_run) 0 else if (unseen) og.state.world.tick_hz else if (unfocused and v.cfg.fps_background > 0) v.cfg.fps_background else v.cfg.fps_limit;
        if (!paused) if (audio_out.*) |*a| a.pump(ctx.mixer, if (fps_cap > 0) 1000 / fps_cap else 0);
        if (unseen) {
            limitFrame(frame_start, fps_cap);
            continue;
        }
        // Same frame as on screen (no events, no world tick, camera and mouse
        // still, no animated windows): skip drawing and present; at 60 fps and a
        // 30 Hz world that is every other frame.
        if (!free_run and !had_event and !(if (script.*) |sc| sc.shot != null else false) and !v.show_perf and frame.frameSame(v)) {
            limitFrame(frame_start, if (fps_cap > 0) fps_cap else 120);
            continue;
        }
        // Hide the system cursor (macOS restores it on focus and fullscreen
        // changes); we draw our own.
        if (c.SDL_CursorVisible()) _ = c.SDL_HideCursor();
        const pt_render = perf.now();
        frame.beginFrame(v);
        try render.render(v);
        frame.applyGamma(v);
        if (v.show_perf) {
            var pb: [256]u8 = undefined;
            viewer.debugText(v.renderer, 2, 2, perf.line(&pb)) catch {};
        }
        perf.add(.rest, pt_render);
        if (script.*) |*sc| if (sc.shot) |path| {
            sc.shot = null;
            v.screenshot(path) catch |err| std.log.warn("shot {s}: {t}", .{ path, err });
        };
        if (v.record_dir) |dir| {
            var pb: [600]u8 = undefined;
            const path = try std.fmt.bufPrint(&pb, "{s}/{d:0>5}.png", .{ dir, v.record_n });
            v.screenshot(path) catch |err| std.log.warn("record {s}: {t}", .{ path, err });
            v.record_n += 1;
        }
        const pt_present = perf.now();
        try frame.presentFrame(v);
        perf.add(.present, pt_present);
        perf.endFrame();
        frame.adaptDetail(v);
        limitFrame(frame_start, fps_cap);
    }
}

/// Frame cap: sleeps the rest of the frame since `start` (SDL ns) when `fps` > 0.
fn limitFrame(start: u64, fps: u32) void {
    if (fps == 0) return;
    const period: u64 = 1_000_000_000 / fps;
    const spent = c.SDL_GetTicksNS() -% start;
    if (spent < period) c.SDL_DelayPrecise(period - spent);
}

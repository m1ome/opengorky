//! Viewer frame: transition, defeat, video, menu, safe, inventory, level with UI
//! or image view, debug line, hints, cursor.

const std = @import("std");
const level_compose = @import("../level/compose.zig");
const viewer = @import("viewer.zig");
const og = @import("opengorky");
const c = @import("sdl");
const Viewer = viewer.Viewer;
const menu_draw = @import("../menu/draw.zig");
const inventory_draw = @import("../inventory/draw.zig");
const inventory_give = @import("../inventory/give.zig");
const inventory_box = @import("../inventory/box.zig");
const gui_stats = @import("../gui/stats.zig");
const gui_short = @import("../gui/short.zig");
const gui_panel = @import("../gui/panel.zig");
const gui_battle = @import("../battle/gui.zig");
const battle_hud = @import("../battle/hud.zig");
const hints = @import("../gui/hints.zig");
const overlay = @import("../level/overlay.zig");
const camera_view = @import("../level/camera.zig");
const gfx = @import("../media/gfx.zig");
const LevelView = @import("../level.zig").LevelView;
const screen_w = viewer.screen_w;
const screen_h = viewer.screen_h;

/// Level drawing settings from the viewer, before every frame.
fn prepLevel(v: *Viewer, l: *LevelView) void {
    l.fx_view = v.fx;
    l.shadows = v.shadows;
    level_compose.setDetail(l, worldDetail(v), @intFromFloat(640 + 2 * gfx.wide));
    l.debug_hud = v.show_debug;
    l.debug = v.debug;
    l.gui = v.gui;
    l.ui_modal = (if (v.inventory) |inv| inv.open else false) or (if (v.menu) |m| m.open else false) or v.safeOpen();
}

/// The world's detail: the frame's, or zoomed in a hires frame ⌈k·z⌉ (≤ 4) — the world
/// drawn at the zoom's pixels, so stretching it about the centre shrinks it and the
/// models stay sharp; a 1× frame is stretched as the exe's.
fn worldDetail(v: *Viewer) u32 {
    const k = v.detail.k;
    if (k <= 1) return k;
    const kz = @ceil(og.num.toF32(k) * camera_view.viewZoom(v) - 0.01);
    return @intFromFloat(std.math.clamp(kz, og.num.toF32(k), 4));
}

pub fn render(v: *Viewer) !void {
    const r = v.renderer;
    try viewer.check(c.SDL_SetRenderDrawColor(r, 0, 0, 0, 255));
    try viewer.check(c.SDL_RenderClear(r));
    const strings = if (v.inventory) |inv| &inv.strings else null;

    var buf: [256]u8 = undefined;
    var line2: [:0]const u8 = undefined;
    if (v.transition) |*tr| if (tr.snap) |snap| {
        // The frame shrinks to the centre over 8 ticks, then black with the saw (its frame
        // counter runs from the 9th tick, 0x41f401).
        const k: f32 = @floatFromInt(tr.ticks);
        const h = @max(0, 480 - 60 * k);
        gfx.wholeView(r);
        if (h > 0) try viewer.check(c.SDL_RenderTexture(r, snap, null, &.{ .x = 0, .y = (480 - h) / 2, .w = 640 + 2 * gfx.wide, .h = h }));
        gfx.middleView(r);
        if (v.gui) |g| if (g.spinner.len() > 0) {
            const fr = (tr.ticks -| 8) % @as(u32, @intCast(g.spinner.len()));
            const sz = g.spinner.sizes.items[fr];
            try g.spinner.draw(r, fr, @floor((640 - og.num.toF32(sz[0])) / 2), @floor((480 - og.num.toF32(sz[1])) / 2));
        };
        return;
    };
    defer if (v.transition) |*tr| if (tr.snap == null) {
        tr.snap = captureFrame(r);
    };
    if (v.gui) |g| if (g.go_frame != null) {
        try gui_battle.drawGameOver(g, r, strings);
        try gui_panel.drawCursor(g, r, v.mouse[0], v.mouse[1]);
        return;
    };
    defer if (v.gui) |g| if (g.go_capture) {
        g.go_capture = false;
        g.go_frame = captureFrame(r);
    };
    if (v.video) |vd| {
        try vd.draw(r);
        // "somewhere in Russia…" caption over introkon: fades in at 2–3 s,
        // visible until 7 s, fades out at 7–8 s.
        if (vd.caption) if (v.gui) |g| if (g.intro.len() > 0) {
            const t = vd.seconds();
            if (t >= 2 and t <= 8) {
                const a: f32 = if (t < 3) t - 2 else if (t > 7) 8 - t else 1;
                _ = c.SDL_SetTextureAlphaModFloat(g.intro.textures.items[0], a);
                try g.intro.draw(r, 0, 0, 440);
                _ = c.SDL_SetTextureAlphaModFloat(g.intro.textures.items[0], 1);
            }
        };
        return;
    }
    if (v.menu) |m| if (m.open) {
        try menu_draw.draw(m, r, v.mouse);
        v.menuSound();
        // In the menu the cursor is a flare (drawFlares), no arrow.
        return;
    };
    if (v.safeOpen()) {
        const l = &v.level.?;
        prepLevel(v, l);
        gfx.wholeView(r);
        try level_compose.draw(l, r, wideScroll(v.scroll), wideMouse(v.mouse));
        gfx.middleView(r);
        try v.safe.?.draw(r, v.mouse);
        if (v.gui) |g| try gui_panel.drawCursor(g, r, v.mouse[0], v.mouse[1]);
        return;
    }
    if (v.level != null and v.inventory != null and v.inventory.?.open) {
        const inv = v.inventory.?;
        try inventory_draw.draw(inv, r, v.level.?.world, v.gui, v.mouse);
        if (v.gui) |g| try gui_stats.drawSkills(g, r, v.level.?.world, &inv.strings);
        if (v.gui) |g| if (!inv.hidesCursor()) try gui_panel.drawCursor(g, r, v.mouse[0], v.mouse[1]);
        return;
    }
    if (v.level) |*l| {
        const scroll = [2]f32{ v.scroll[0] + l.world.out.shake[0], v.scroll[1] + l.world.out.shake[1] };
        prepLevel(v, l);
        l.window_top = if (v.inventory) |inv| inv.give != null else false;
        // Give, use and push modes in battle: the cell cross at the hero.
        l.cross_mode = l.world.mouse.cross();
        // Zoom (0x41fe80): the world is drawn into a texture and stretched about the
        // screen centre; the UI goes on top unzoomed.
        const zoomed = @abs(camera_view.viewZoom(v) - 1) > 0.001;
        const z = camera_view.viewZoom(v);
        const zk = worldDetail(v);
        if (zoomed) {
            const zw: f32 = (640 + 2 * gfx.wide) * og.num.toF32(zk);
            if (v.zoom_tex) |t| {
                var tw: f32 = 0;
                var th: f32 = 0;
                _ = c.SDL_GetTextureSize(t, &tw, &th);
                if (tw != zw) {
                    c.SDL_DestroyTexture(t);
                    v.zoom_tex = null;
                }
            }
            if (v.zoom_tex == null) v.zoom_tex = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_TARGET, @intFromFloat(zw), @intCast(480 * zk));
            if (v.zoom_tex) |t| {
                try viewer.check(c.SDL_SetRenderTarget(r, t));
                const f: f32 = @floatFromInt(zk);
                try viewer.check(c.SDL_SetRenderScale(r, f, f));
                try viewer.check(c.SDL_SetRenderDrawColor(r, 0, 0, 0, 255));
                try viewer.check(c.SDL_RenderClear(r));
            }
        }
        // The world over the whole (maybe wide) frame, the UI in its middle 640.
        gfx.wholeView(r);
        try level_compose.draw(l, r, wideScroll(scroll), wideMouse(camera_view.worldMouse(v)));
        try battle_hud.drawBattleHud(l, r, wideScroll(scroll), v.gui);
        // Selected hero frame outside battle and scenes (0x45b920).
        // The level-up points window is the top GUI mode (0x4af7c2): only it draws
        // (0x45ac1c → 0x4afe00); the panel, report and mode windows below do not.
        const stats_modal = if (v.gui) |g| g.stats.modal else false;
        if (v.gui) |g| if (l.hero_box) |hb| if (!stats_modal and l.world.battle == null and !l.world.scene.cutscene and !l.world.scene.panorama) try gui_panel.drawHeroFrame(g, r, hb);
        if (zoomed) if (v.zoom_tex) |t| {
            try viewer.check(c.SDL_SetRenderTarget(r, v.frame_tex));
            gfx.wholeView(r);
            const hw = 320 + gfx.wide;
            const f: f32 = @floatFromInt(zk);
            const src: c.SDL_FRect = .{ .x = (hw - hw / z) * f, .y = (240 - 240 / z) * f, .w = 2 * hw / z * f, .h = 480 / z * f };
            try viewer.check(c.SDL_RenderTexture(r, t, &src, null));
        };
        gfx.middleView(r);
        // Fighter info (0x455d90) is drawn by battle modes 0x4526ca and 0x455704,
        // not by "Use … on …" (0x453f80), which shows only its two lines at the cursor.
        // Push (0x452bf0) and give (0x4539e0) don't draw fighter info either.
        // The count window over battle (0x4b2fb0): the battle mode below is not drawn.
        if (v.gui) |g| if (!stats_modal and !l.window_top and l.world.mouse.use == null and l.world.mouse.give == null and !(l.world.mouse.push and l.world.battle != null)) try battle_hud.drawFighterInfo(l, r, g, camera_view.bgMouse(v, v.mouse), v.mouse);
        try overlay.drawOverlay(l, r, if (v.gui) |g| gui_panel.dialogArt(g, l.world) else .{});
        if (v.gui) |g| try gui_panel.drawSignature(g, r, l.world);
        if (v.gui) |g| try gui_battle.drawBattleBanner(g, r, l.world, strings);
        // Exploration UI: outside scenes.
        if (v.gui) |g| if (stats_modal) {
            g.hover_btn = null;
            try gui_stats.drawStats(g, r, l.world, strings);
        } else if (!l.world.scene.cutscene and !l.world.scene.panorama) {
            g.hover_btn = gui_panel.buttonAt(v.mouse[0], v.mouse[1]);
            try gui_stats.drawSkills(g, r, l.world, strings);
            try gui_stats.drawStats(g, r, l.world, strings);
            try gui_short.drawShortList(g, r, l.world);
            if (!g.panel_hidden) {
                try gui_panel.drawPanel(g, r, l.world);
                try gui_panel.drawWeapon(g, r, l.world);
                try gui_panel.drawShutters(g, r);
            }
            try gui_battle.drawReport(g, r, l.world, strings);
        };
        // Give mode count window (0x4b2fb0) over the field.
        if (v.inventory) |inv| if (inv.give != null) try inventory_give.drawGive(inv, r, v.mouse);
        line2 = try printZ(&buf, "level {s}: tick {d}{s}{s}  scroll {d},{d}  model scale {d}%  hero {s}", .{
            l.level.name,                                       l.world.ticks,
            if (l.paused) " (paused)" else "",                  if (l.speed > 1) " >>" else "",
            @as(i32, @intFromFloat(v.scroll[0])),               @as(i32, @intFromFloat(v.scroll[1])),
            @as(i32, @intFromFloat(v.debug.scale_tweak * 100)), l.world.selected_hero,
        });
    } else {
        drawChecker(r);
        if (v.frames.len() > 0) {
            const size = v.frames.sizes.items[v.frame];
            const w: f32 = @floatFromInt(size[0]);
            const h: f32 = @floatFromInt(size[1]);
            // Small images centred, large ones scroll.
            try v.frames.draw(
                r,
                v.frame,
                if (w < screen_w) (screen_w - w) / 2 else -v.scroll[0],
                if (h < screen_h) (screen_h - h) / 2 else -v.scroll[1],
            );
        }
        line2 = if (v.images.items.len == 0)
            try printZ(&buf, "no images", .{})
        else if (v.load_err) |err|
            try printZ(&buf, "({d}/{d}) {s}: error {t}", .{ v.img_index + 1, v.images.items.len, v.currentName(), err })
        else blk: {
            const size = v.frames.sizes.items[v.frame];
            break :blk try printZ(&buf, "({d}/{d}) {s}  frame {d}/{d}  {d}x{d}{s}", .{
                v.img_index + 1, v.images.items.len,           v.currentName(),
                v.frame + 1,     v.frames.len(),               size[0],
                size[1],         if (v.playing) "  >" else "",
            });
        };
    }

    // Debug line: in the viewer; in the game (--play) on F1.
    if (v.show_debug) {
        var buf1: [256]u8 = undefined;
        try gfx.fillRect(r, .{ 0, 0, 0, 180 }, .{ .x = 0, .y = 0, .w = screen_w, .h = 22 });
        try viewer.check(c.SDL_SetRenderDrawColor(r, 255, 220, 120, 255));
        try viewer.check(c.SDL_RenderDebugText(r, 4, 2, try printZ(&buf1, "[{d}/{d}] {s}", .{
            v.arc_index + 1, v.archives.len, v.archives[v.arc_index],
        })));
        try viewer.check(c.SDL_RenderDebugText(r, 4, 12, line2));
    }
    if (v.level) |*l| {
        if (v.inventory) |inv| if (l.world.act.exploring != null) try inventory_box.drawBox(inv, r, l.world, v.scroll, v.mouse);
        if (v.inventory) |inv| if (l.world.act.examining != null) try inventory_box.drawExamine(inv, r, l.world, v.scroll, v.mouse) else {
            inv.exam_anchor = null; // menu closed: X recomputed on next open
        };
        try hints.drawHints(v, r, l);
    }
    try v.console.draw(r);
    if (v.level) |*l| if (v.gui) |g| {
        // Cutscene mode (GUI_CUTSCENE, object 0x651ad0) draws nothing (0x42cb90)
        // and has no cursor; the dialog box doesn't draw one either.
        if (l.world.scene.cutscene and !v.console.open) return;
        g.cursor_frame = hints.cursorFrame(v, l, g);
        try gui_panel.drawCursor(g, r, v.mouse[0], v.mouse[1]);
    };
}

/// Scroll of the whole frame's left edge (the middle 640 starts at `scroll`).
fn wideScroll(s: [2]f32) [2]f32 {
    return .{ s[0] - gfx.wide, s[1] };
}

/// A middle-640 point in whole-frame coordinates.
fn wideMouse(m: [2]f32) [2]f32 {
    return .{ m[0] + gfx.wide, m[1] };
}

/// Screen frame into a texture (frozen battle under the defeat text).
fn captureFrame(r: *c.SDL_Renderer) ?*c.SDL_Texture {
    const surf = gfx.readFrame(r) orelse return null;
    defer c.SDL_DestroySurface(surf);
    return c.SDL_CreateTextureFromSurface(r, surf);
}

fn printZ(buf: []u8, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, fmt, args, 0);
}

fn drawChecker(r: *c.SDL_Renderer) void {
    const cell = 16;
    var y: f32 = 0;
    while (y < screen_h) : (y += cell) {
        var x: f32 = 0;
        while (x < screen_w) : (x += cell) {
            const odd = @as(u32, @intFromFloat(x / cell + y / cell)) % 2 == 1;
            const v: u8 = if (odd) 48 else 64;
            _ = c.SDL_SetRenderDrawColor(r, v, v, v, 255);
            _ = c.SDL_RenderFillRect(r, &.{ .x = x, .y = y, .w = cell, .h = cell });
        }
    }
}

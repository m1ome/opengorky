//! Viewer camera: background scrolling (screen edge, drag, wheel), following the hero and scenes, pans, zoom, mouse in background coordinates.

const std = @import("std");
const viewer_mod = @import("../app/viewer.zig");
const Viewer = viewer_mod.Viewer;
const LevelView = @import("../level.zig").LevelView;
const og = @import("opengorky");
const c = @import("sdl");
const screen_w = viewer_mod.screen_w;
const screen_h = viewer_mod.screen_h;
const cx = og.state.world.screen_cx;
const cy = og.state.world.screen_cy;
const level = @import("../level.zig");
const gfx = @import("../media/gfx.zig");

/// Size of what is on screen (for scrolling).
fn contentSize(self: *Viewer) [2]u32 {
    if (self.level) |l| return l.size();
    if (self.frames.len() == 0) return .{ 0, 0 };
    return self.frames.sizes.items[self.frame];
}
/// Camera step (0x45c540, 0x45c5f0, 0x41ff0f): exploration — toward the hero's head by
/// 1/6 and a 25 px edge scroll; battle — no following, edge 1.7 × overshoot; scene
/// with autocamera — toward the party centre by 1/6, without it DOLLY; arrows 10 px (Ctrl 1).
pub fn cameraTick(self: *Viewer, l: *LevelView) void {
    const w = l.world;
    if (w.out.dolly) |d| {
        w.out.dolly = null;
        const speed: f32 = if (d.time > 0) 1 / (d.time * 0.3) else 1;
        self.dolly = .{ .from = self.scroll, .to = .{ d.to[0] - cx, d.to[1] - cy }, .speed = speed };
        if (d.zoom) |z| {
            self.zoom_target = z;
            self.zoom_rate = @abs(z - self.zoom) * speed;
        }
    }
    // ZOOM (0x478220 → 0x420030): rate as DOLLY's zoom, or zoom_speed (0x5927f4).
    if (w.out.zoom) |z| {
        w.out.zoom = null;
        self.zoom_target = z.to;
        self.zoom_rate = if (z.time) |t| (if (t != 0) @abs(z.to - self.zoom) / (t * 0.3) else 1) else og.formats.adjust.getFloat("zoom_speed", 0.1);
    }
    // Scene end (0x4790ad): zoom back to 1 at zoom_speed 0.1, after the same tick's
    // DOLLY (the scene's last command must not leave 2×).
    if (w.out.zoom_reset) {
        w.out.zoom_reset = false;
        self.zoom_target = 1;
        self.zoom_rate = og.formats.adjust.getFloat("zoom_speed", 0.1);
    }
    if (w.out.camera_snap) {
        w.out.camera_snap = false;
        // 0x45ba90 → 0x430200: integer scroll (`_ftol`).
        if (l.cameraGoal()) |g| self.scroll = .{ @trunc(g[0]), @trunc(g[1]) };
    }
    // Attack camera (0x47c120): toward the attacker/target centre over 10 ticks (0.1),
    // zoom 2× by 0.05; 40 ticks after the hit back to 1×.
    if (w.out.attack_cam) |*ac| {
        if (self.dolly == null and ac.release == null) {
            self.dolly = .{ .from = self.scroll, .to = .{ ac.center[0] - cx, ac.center[1] - cy }, .speed = 0.1 };
            self.zoom_target = 2;
            self.zoom_rate = 0.05;
        }
        if (ac.release) |*rl| {
            if (rl.* > 0) rl.* -= 1 else {
                self.zoom_target = 1;
                self.zoom_rate = 0.05;
                w.out.attack_cam = null;
            }
        }
    }
    if (self.zoom != self.zoom_target) {
        const zs = if (self.zoom_rate > 0) self.zoom_rate else 1;
        self.zoom = if (self.zoom < self.zoom_target) @min(self.zoom_target, self.zoom + zs) else @max(self.zoom_target, self.zoom - zs);
    }
    const scene_cam = !w.scene.autocamera or w.out.attack_cam != null;
    if (scene_cam) {
        if (self.dolly) |*d| {
            d.t = @min(1, d.t + d.speed);
            self.scroll = .{ d.from[0] + (d.to[0] - d.from[0]) * d.t, d.from[1] + (d.to[1] - d.from[1]) * d.t };
            if (d.t >= 1) self.dolly = null;
        }
    } else if (w.scene.cutscene or w.scene.subtitle != null) {
        self.dolly = null;
        // A combat level's own dialogue (the window's tick 0x45a050, +0x218 = 0): a
        // line's `#CAM x,y` is the scroll it glides to by 1/6 (0x45c220) — the meeting
        // with Medusa in 03__museum_corner shows her, then the fighters.
        const cam = if (w.battle != null and w.scene.subtitle != null) w.scene.dialog_cam else null;
        if (cam) |xy| {
            for (0..2) |k| self.scroll[k] = @trunc(self.scroll[k] + (og.num.toF32(xy[k]) - self.scroll[k]) * (1.0 / 6.0));
        } else if (l.partyGoal()) |g| glide(self, g);
    } else if (w.battle != null) {
        self.dolly = null;
        // Hero select (0x455490 → 0x4c9100): from the current scroll to the hero's
        // point (+160·aS) − (320, 240); within 2 px no pan (0x4c8fdf).
        if (w.out.pan_to) |o| {
            w.out.pan_to = null;
            if (og.state.world.actorOf(o).placed) {
                const q = level.headAt(w, og.fields.pos(o));
                const to = [2]f32{ @trunc(q[0]) - cx, @trunc(q[1]) - cy };
                const from = [2]f32{ @trunc(self.scroll[0]), @trunc(self.scroll[1]) };
                if (std.math.hypot(to[0] - from[0], to[1] - from[1]) >= 2) self.select_pan = .{ .from = from, .to = to };
            }
        }
        // 0x4c9050: position by t, then t += 1/15; t > 1 — to the target and stop.
        if (self.select_pan) |*sp| {
            const k = @sin(sp.t * std.math.pi / 2);
            var pos = [2]f32{ @trunc(sp.from[0] + (sp.to[0] - sp.from[0]) * k), @trunc(sp.from[1] + (sp.to[1] - sp.from[1]) * k) };
            sp.t += 1.0 / 15.0;
            if (sp.t > 1) {
                pos = sp.to;
                self.select_pan = null;
            }
            self.scroll = pos;
        }
        // Enemy turn and appearing (0x454cb0): the camera follows the current actor, 1/6 per tick.
        // Enemy attack (0x454cf1 → 0x45c270): to the midpoint between it and the target.
        // Bomb blast (0x45c160): cell centre + 160·aS at (320, 240).
        if (w.battle.?.cameraTile()) |t| {
            if (w.combat_map) |cm| {
                const tc = cm.tileCenter(t, 1);
                const q = level.headAt(w, tc);
                glide(self, .{ q[0] - cx, q[1] - cy });
            }
        } else if (w.battle.?.cameraPair()) |cp| {
            if (l.actorGoal(cp.obj)) |g| if (w.combat_map) |cm| {
                const tc = cm.tileCenter(cp.tile, 1);
                const q = level.headAt(w, tc);
                glide(self, .{ (g[0] + q[0] - level.head_focus[0]) / 2, (g[1] + q[1] - level.head_focus[1]) / 2 });
            };
        } else if (w.battle.?.cameraActor()) |o| if (l.actorGoal(o)) |g| glide(self, g);
        if (!self.shot_run) {
            const m = self.mouse;
            if (m[0] < 15 - gfx.wide) self.scroll[0] -= (15 - gfx.wide - m[0]) * 1.7;
            if (m[0] > 625 + gfx.wide) self.scroll[0] += (m[0] - 625 - gfx.wide) * 1.7;
            if (m[1] < 10) self.scroll[1] -= (10 - m[1]) * 1.7;
            if (m[1] > 470) self.scroll[1] += (m[1] - 470) * 1.7;
        }
    } else {
        self.dolly = null;
        if (l.follow) if (l.cameraGoal()) |g| glide(self, g);
        if (!self.shot_run) {
            const m = self.mouse;
            if (m[0] < 20 - gfx.wide) self.scroll[0] -= 25;
            if (m[0] > 620 + gfx.wide) self.scroll[0] += 25;
            if (m[1] < 15) self.scroll[1] -= 25;
            if (m[1] > 465) self.scroll[1] += 25;
        }
    }
    // Arrows (0x42d870): 10 px, 1 with Ctrl; not in a scene and not with left Shift.
    if (w.scene.runner == null and !self.console.open) {
        const keys = c.SDL_GetKeyboardState(null);
        const mods = c.SDL_GetModState();
        if (mods & c.SDL_KMOD_LSHIFT == 0) {
            const st: f32 = if (mods & c.SDL_KMOD_CTRL != 0) 1 else 10;
            if (keys[c.SDL_SCANCODE_LEFT]) self.scroll[0] -= st;
            if (keys[c.SDL_SCANCODE_RIGHT]) self.scroll[0] += st;
            if (keys[c.SDL_SCANCODE_UP]) self.scroll[1] -= st;
            if (keys[c.SDL_SCANCODE_DOWN]) self.scroll[1] += st;
        }
    }
    clampScroll(self, l);
}
/// Mouse in screen coordinates without zoom (0x451630: (m − 320)/zoom + 320).
pub fn worldMouse(self: *Viewer) [2]f32 {
    return unzoom(self, self.mouse);
}
fn unzoom(self: *Viewer, pt: [2]f32) [2]f32 {
    const z = viewZoom(self);
    return .{ (pt[0] - cx) / z + cx, (pt[1] - cy) / z + cy };
}
/// Screen point → background coordinates: unzoomed (0x451630) plus scroll.
pub fn bgMouse(self: *Viewer, pt: [2]f32) [2]f32 {
    const u = unzoom(self, pt);
    return .{ u[0] + self.scroll[0], u[1] + self.scroll[1] };
}
/// The world's zoom on screen: the game's (scenes, attacks) times `scaling = adaptive`'s.
pub fn viewZoom(self: *Viewer) f32 {
    return self.zoom * gfx.fill;
}
/// Toward the target by 1/6 per tick, truncating (ftol).
fn glide(self: *Viewer, g: [2]f32) void {
    for (0..2) |k| self.scroll[k] += @trunc((g[k] - self.scroll[k]) / 6);
}
/// Scroll limits (0x430200): with zoom a margin m = 320 − 320/zoom; with the panel
/// visible another 50/zoom down.
fn clampScroll(self: *Viewer, l: *LevelView) void {
    const size = l.size();
    const z = viewZoom(self);
    // Half the world width on screen (the wide frame's, zoomed): the view keeps on the background.
    const half = (cx + gfx.wide) / z;
    const my = cy - cy / z;
    const panel_shown = self.gui != null and !self.gui.?.panel_hidden and !l.world.scene.cutscene and !l.world.scene.panorama;
    // `scaling = adaptive` too, so the bottom cells clear the panel (its sides: `drawPanelSides`).
    const panel: f32 = if (panel_shown) 50 / z else 0;
    // A wide frame (`scaling = adaptive`) keeps its sides on the background too.
    const min_x = half - cx;
    const max_x = @max(min_x, og.num.toF32(size[0]) - cx - half);
    const max_y = @max(-my, og.num.toF32(size[1]) - screen_h + my + panel);
    self.scroll[0] = std.math.clamp(self.scroll[0], min_x, max_x);
    self.scroll[1] = std.math.clamp(self.scroll[1], -my, max_y);
}
/// Wheel step: touchpads and high-precision wheels send many small events, and
/// horizontal ones with y = 0. A step once a whole notch accumulates (|y| ≥ 1),
/// at most every 80 ms; true — up, null — no step.
pub fn wheelStep(self: *Viewer, y: f32) ?bool {
    if (y == 0) return null;
    if ((y > 0) != (self.wheel_acc > 0)) self.wheel_acc = 0;
    self.wheel_acc += y;
    if (@abs(self.wheel_acc) < 1) return null;
    const now = c.SDL_GetTicks();
    if (now -% self.wheel_last_ms < 80) return null;
    self.wheel_last_ms = now;
    const up = self.wheel_acc > 0;
    self.wheel_acc = 0;
    return up;
}
pub fn scrollBy(self: *Viewer, dx: f32, dy: f32) void {
    const size = contentSize(self);
    const max_x = @max(0, og.num.toF32(size[0]) - screen_w);
    const max_y = @max(0, og.num.toF32(size[1]) - screen_h);
    self.scroll[0] = std.math.clamp(self.scroll[0] + dx, 0, max_x);
    self.scroll[1] = std.math.clamp(self.scroll[1] + dy, 0, max_y);
}

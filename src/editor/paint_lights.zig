//! The Lights tool of the level edit mode: the location's lamps (`.lts`) added, dragged,
//! their colour and reach set.

const std = @import("std");
const screen = @import("paint.zig").screen;
const Paint = @import("paint.zig").Paint;
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const ui = @import("ui");
const og = @import("opengorky");
const lf = og.formats.level_files;
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;
const Doc = @import("level.zig").Doc;
const paint = @import("paint.zig");

/// The level's `.lts` (Store index), if it has one.
fn lightsFile(app: *App, d: *const Doc) ?usize {
    var eb: [96]u8 = undefined;
    return app.store.file(d.level_archive, std.fmt.bufPrint(&eb, "{s}.lts", .{d.name}) catch return null) catch null;
}

/// The lamps as the Store has them now (frame memory).
pub fn lights(app: *App, d: *const Doc) ?lf.Lights {
    const f = lightsFile(app, d) orelse return null;
    return lf.parseLights(app.frame.allocator(), app.store.text(f)) catch null;
}

/// Lamp `i` taken out (one history step).
pub fn dropLight(app: *App, i: usize) void {
    const d = app.doc orelse return;
    var l = lights(app, d) orelse return;
    if (i >= l.omni.len) return;
    const fewer = app.frame.allocator().alloc(lf.Omni, l.omni.len - 1) catch return;
    @memcpy(fewer[0..i], l.omni[0..i]);
    @memcpy(fewer[i..], l.omni[i + 1 ..]);
    l.omni = fewer;
    if (app.paint) |p| p.light = null;
    putLights(app, d, l);
}

/// `l` written back into the level's `.lts`, one history step.
fn putLights(app: *App, d: *const Doc, l: lf.Lights) void {
    const f = lightsFile(app, d) orelse return;
    const t = lf.encodeLights(app.gpa, l) catch return;
    app.store.replaceLabeled(f, t, tx.alloc(app.frame.allocator(), tx.lp_step_light, .{d.name})) catch |err| {
        app.gpa.free(t);
        app.setStatus(tx.st_set_failed, .{err});
    };
}

/// Lamp `i`'s place on the background (the dragged one where it is being dragged to).
fn lampAt(p: *const Paint, d: *const Doc, l: lf.Lights, i: usize) [2]f32 {
    const pos = if (p.light == i) p.light_drag orelse l.omni[i].pos else l.omni[i].pos;
    const q = d.world.cam.project(pos);
    return .{ q.x, q.y };
}

/// Each lamp: a dot of its colour, its range a circle (the picked one brighter).
pub fn drawLights(app: *App, p: *const Paint, d: *const Doc, rect: c.SDL_FRect) void {
    const l = lights(app, d) orelse return;
    for (l.omni, 0..) |o, i| {
        const s = screen(d, rect, lampAt(p, d, l, i));
        const pos = if (p.light == i) p.light_drag orelse o.pos else o.pos;
        const e = d.world.cam.project(.{ pos[0] + o.range, pos[1], pos[2] });
        const q = d.world.cam.project(pos);
        const rad = @max(4, @sqrt((e.x - q.x) * (e.x - q.x) + (e.y - q.y) * (e.y - q.y)) * d.zoom);
        const rgb: [3]u8 = .{ @intFromFloat(std.math.clamp(o.color[0], 0, 1) * 255), @intFromFloat(std.math.clamp(o.color[1], 0, 1) * 255), @intFromFloat(std.math.clamp(o.color[2], 0, 1) * 255) };
        const sel = p.light == i;
        _ = c.SDL_SetRenderDrawColor(app.r, rgb[0], rgb[1], rgb[2], if (sel) 255 else 120);
        var prev: [2]f32 = .{ s[0] + rad, s[1] };
        for (1..41) |k| {
            const t = @as(f32, @floatFromInt(k)) / 40 * std.math.tau;
            const nx: [2]f32 = .{ s[0] + rad * @cos(t), s[1] + rad * @sin(t) };
            _ = c.SDL_RenderLine(app.r, prev[0], prev[1], nx[0], nx[1]);
            prev = nx;
        }
        _ = c.SDL_SetRenderDrawColor(app.r, 0, 0, 0, 220);
        _ = c.SDL_RenderFillRect(app.r, &.{ .x = s[0] - 7, .y = s[1] - 7, .w = 14, .h = 14 });
        _ = c.SDL_SetRenderDrawColor(app.r, rgb[0], rgb[1], rgb[2], 255);
        _ = c.SDL_RenderFillRect(app.r, &.{ .x = s[0] - 5, .y = s[1] - 5, .w = 10, .h = 10 });
        if (sel) {
            _ = c.SDL_SetRenderDrawColor(app.r, 255, 255, 255, 255);
            _ = c.SDL_RenderRect(app.r, &.{ .x = s[0] - 9, .y = s[1] - 9, .w = 18, .h = 18 });
        }
    }
}

/// A press of the light tool at background point `b`: a lamp there picked (and dragged
/// from now), else a new white one over the floor under it.
pub fn lightPress(app: *App, p: *Paint, d: *Doc, b: [2]f32) void {
    var l = lights(app, d) orelse return app.setStatus(tx.st_set_failed, .{error.NoLights});
    p.light_drag = null;
    for (0..l.omni.len) |k| {
        const i = l.omni.len - 1 - k; // the one drawn on top first
        const s = lampAt(p, d, l, i);
        if (@abs(s[0] - b[0]) * d.zoom <= 9 and @abs(s[1] - b[1]) * d.zoom <= 9) {
            p.light = i;
            p.light_drag = l.omni[i].pos;
            return;
        }
    }
    const g = og.world.floor.groundAt(d.world, b);
    const a = app.frame.allocator();
    const more = a.alloc(lf.Omni, l.omni.len + 1) catch return;
    @memcpy(more[0..l.omni.len], l.omni);
    // The level's scale: its lamps' mean range (rooms use tens, the port hundreds).
    var range: f32 = 0;
    for (l.omni) |o| range += o.range;
    range = if (l.omni.len > 0) range / @as(f32, @floatFromInt(l.omni.len)) else 200;
    more[l.omni.len] = .{ .pos = .{ g[0], g[1], g[2] + range / 2 }, .color = .{ 1, 1, 1 }, .range = range };
    l.omni = more;
    p.light = l.omni.len - 1;
    putLights(app, d, l);
}

/// The picked lamp dragged under background point `b`, at its own height.
pub fn lightDrag(p: *Paint, d: *const Doc, b: [2]f32) void {
    const z = (p.light_drag orelse return)[2];
    p.light_drag = d.world.cam.unproject(b[0], b[1], z);
    p.light_drag.?[2] = z;
}

/// Released: the dragged lamp written where it is (nothing if it did not move).
pub fn lightRelease(app: *App, p: *Paint) void {
    const to = p.light_drag orelse return;
    p.light_drag = null;
    const d = app.doc orelse return;
    const l = lights(app, d) orelse return;
    const i = p.light orelse return;
    if (i >= l.omni.len or std.mem.eql(f32, &l.omni[i].pos, &to)) return;
    l.omni[i].pos = to;
    putLights(app, d, l);
}

/// A `-`/`+` pair for a value; returns the step taken (0: none).
pub fn stepper(app: *App, a: Allocator, id: []const u8, label: []const u8, cur: f32, step: f32) f32 {
    clay.open(.{ .layout = .{ .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    defer clay.close();
    var out: f32 = 0;
    if (main.button(app, std.fmt.allocPrint(a, "{s}_m", .{id}) catch id, "-", false)) out = -step;
    if (main.button(app, std.fmt.allocPrint(a, "{s}_p", .{id}) catch id, "+", false)) out = step;
    // The label clicked: a field for the number (the step taken is new − current).
    const h = std.hash.Wyhash.hash(0, id);
    const fid = clay.id(std.fmt.allocPrint(a, "{s}_n", .{id}) catch id);
    if (app.num_edit) |*e| if (e.id == h) {
        app.num_seen = true;
        clay.open(.{ .id = fid, .layout = .{ .sizing = .{ .width = clay.fixed(110), .height = clay.fixed(24) }, .padding = .{ .left = 6, .right = 6 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.field, .cornerRadius = clay.radius(theme.radius), .border = .{ .color = theme.accent, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } } });
        const over = clay.hovered();
        txt(std.fmt.allocPrint(a, "{s}|", .{e.text()}) catch "", 13, theme.text, font_mod.regular);
        clay.close();
        if (e.done or (app.clicked and !over)) {
            const v = std.fmt.parseFloat(f32, e.text()) catch null;
            app.num_edit = null;
            if (v) |x| if (std.math.isFinite(x)) return std.math.clamp(x, -1e5, 1e5) - cur;
        }
        return out;
    };
    if (main.clickable(app, .{ .id = fid, .layout = .{ .padding = .{ .left = 4, .right = 4, .top = 2, .bottom = 2 } }, .backgroundColor = theme.panel, .cornerRadius = clay.radius(theme.radius) }, false)) {
        var e: main.NumEdit = .{ .id = h };
        e.len = if (std.fmt.bufPrint(&e.buf, "{d}", .{cur})) |t| t.len else |_| 0;
        app.num_edit = e;
        app.num_seen = true;
    }
    txt(label, 13, theme.text, font_mod.regular);
    clay.close();
    return out;
}

/// The light tool's panel: the level's ambient, sun and shadow; the picked lamp's
/// colour, range, height, delete.
pub fn lightsPanel(app: *App, a: Allocator, p: *Paint) void {
    clay.text(tx.get(tx.lp_lights_hint), .{ .textColor = theme.dim, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    const d = app.doc orelse return;
    var l = lights(app, d) orelse {
        clay.text(tx.get(tx.lp_lights_none), .{ .textColor = theme.warn, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
        return;
    };
    var touched = false;
    const clamp01 = struct {
        fn f(v: f32) f32 {
            return std.math.clamp(v, 0, 1);
        }
    }.f;
    // The game's levels have grey ambient and sun: one value for the three channels.
    const amb = stepper(app, a, "lp_amb", tx.alloc(a, tx.lp_ambient, .{l.ambient[0]}), l.ambient[0], 0.05);
    if (amb != 0) {
        for (&l.ambient) |*v| v.* = clamp01(v.* + amb);
        touched = true;
    }
    const sun = stepper(app, a, "lp_sun", tx.alloc(a, tx.lp_directional, .{l.directional_color[0]}), l.directional_color[0], 0.05);
    if (sun != 0) {
        for (&l.directional_color) |*v| v.* = clamp01(v.* + sun);
        touched = true;
    }
    const sh = stepper(app, a, "lp_shadow", tx.alloc(a, tx.lp_shadow, .{l.shadow_intensity}), l.shadow_intensity, 0.1);
    if (sh != 0) {
        l.shadow_intensity = clamp01(l.shadow_intensity + sh);
        touched = true;
    }
    if (p.light) |i| if (i < l.omni.len) {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 6, .padding = .{ .top = 6, .bottom = 6 } }, .border = .{ .color = theme.line, .width = .{ .top = 1, .bottom = 1 } } });
        txt(tx.alloc(a, tx.lp_light_n, .{ i + 1, l.omni.len }), 13, theme.text, font_mod.bold);
        const o = &l.omni[i];
        for ([_][]const u8{ "R", "G", "B" }, 0..) |ch, k| {
            const v = stepper(app, a, std.fmt.allocPrint(a, "lp_col{d}", .{k}) catch "c", tx.alloc(a, tx.lp_light_color, .{ ch, o.color[k] }), o.color[k], 0.1);
            if (v != 0) {
                o.color[k] = clamp01(o.color[k] + v);
                touched = true;
            }
        }
        const rg = stepper(app, a, "lp_range", tx.alloc(a, tx.lp_light_range, .{o.range}), o.range, 25);
        if (rg != 0) {
            o.range = @max(5, o.range + rg);
            touched = true;
        }
        const hz = stepper(app, a, "lp_height", tx.alloc(a, tx.lp_light_height, .{o.pos[2]}), o.pos[2], 25);
        if (hz != 0) {
            o.pos[2] += hz;
            touched = true;
        }
        if (main.button(app, "lp_light_del", tx.get(tx.vo_remove), false)) app.askDelete(.light, i, std.fmt.allocPrint(a, "{s} {d}", .{ tx.get(tx.lp_lamp_word), i + 1 }) catch "");
        clay.close();
    };
    if (touched) putLights(app, d, l);
}

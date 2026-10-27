//! The Points tool of the level edit mode: a scene's points (`<scene>.pnt`) placed,
//! dragged and taken out on the map, the scene chosen.

const std = @import("std");
const screen = @import("paint.zig").screen;
const Paint = @import("paint.zig").Paint;
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const ui = @import("ui");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;
const Doc = @import("level.zig").Doc;
const common_archive = @import("store.zig").common_archive;
const scenes_mod = @import("scenes.zig");
const paint = @import("paint.zig");

/// The points file of the scene picked in the Scenes tab (Store index).
fn pointsFile(app: *App) ?usize {
    const name = app.sceneName() orelse return null;
    var eb: [96]u8 = undefined;
    return app.store.file(common_archive, std.fmt.bufPrint(&eb, "scriptlets\\{s}.pts", .{name}) catch return null) catch null;
}

pub const Point = struct { name: []const u8, x: f32, y: f32 };

/// `name,x,y,angle` lines of a `.pts` (background pixels).
pub fn points(a: Allocator, text: []const u8) []Point {
    var out: std.ArrayList(Point) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        var f = std.mem.splitScalar(u8, std.mem.trim(u8, raw, " \t\r"), ',');
        const n = f.next() orelse continue;
        const x = std.fmt.parseFloat(f32, f.next() orelse continue) catch continue;
        const y = std.fmt.parseFloat(f32, f.next() orelse continue) catch continue;
        out.append(a, .{ .name = n, .x = x, .y = y }) catch {};
    }
    return out.items;
}

pub fn drawPoints(app: *App, d: *const Doc, rect: c.SDL_FRect) void {
    const f = pointsFile(app) orelse return;
    for (points(app.frame.allocator(), app.store.text(f))) |pt| {
        const s = screen(d, rect, .{ pt.x, pt.y });
        _ = c.SDL_SetRenderDrawColor(app.r, 255, 220, 60, 255);
        _ = c.SDL_RenderLine(app.r, s[0] - 7, s[1], s[0] + 7, s[1]);
        _ = c.SDL_RenderLine(app.r, s[0], s[1] - 7, s[0], s[1] + 7);
        const w = app.font.measure(pt.name, font_mod.bold, 13)[0];
        _ = c.SDL_SetRenderDrawColor(app.r, 0, 0, 0, 170);
        _ = c.SDL_RenderFillRect(app.r, &.{ .x = s[0] + 8, .y = s[1] - 20, .w = w + 6, .h = 18 });
        app.font.draw(app.r, pt.name, font_mod.bold, 13, s[0] + 11, s[1] - 20, .{ 255, 220, 60, 255 });
    }
}

/// A click of the points tool: a new point `p<n>` of the picked scene at `b`.
pub fn pointClick(app: *App, b: [2]f32) void {
    const f = pointsFile(app) orelse return app.setStatus(tx.st_no_scene, .{});
    const a = app.frame.allocator();
    const text = app.store.text(f);
    const have = points(a, text);
    var nb: [16]u8 = undefined;
    const name = for (1..1000) |n| {
        const s = std.fmt.bufPrint(&nb, "p{d}", .{n}) catch unreachable;
        for (have) |pt| {
            if (std.ascii.eqlIgnoreCase(pt.name, s)) break;
        } else break s;
    } else return;
    const sep = if (text.len > 0 and text[text.len - 1] != '\n') "\r\n" else "";
    const t = std.fmt.allocPrint(app.gpa, "{s}{s}{s},{d},{d},0.000000\r\n", .{ text, sep, name, @round(b[0]), @round(b[1]) }) catch return;
    app.store.replaceLabeled(f, t, std.fmt.allocPrint(a, "+ {s} ({s}.pts)", .{ name, app.sceneName().? }) catch null) catch |err| {
        app.gpa.free(t);
        return app.setStatus(tx.st_set_failed, .{err});
    };
    app.setStatus(tx.st_point_added, .{ name, app.sceneName().? });
}

/// Point `name` taken out of the picked scene's `.pts`.
pub fn dropPoint(app: *App, name: []const u8) void {
    const f = pointsFile(app) orelse return;
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, app.store.text(f), '\n');
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        var fl = std.mem.splitScalar(u8, std.mem.trim(u8, raw, " \t\r"), ',');
        if (std.ascii.eqlIgnoreCase(fl.next() orelse "", name)) continue;
        out.appendSlice(app.gpa, raw) catch return;
        out.append(app.gpa, '\n') catch return;
    }
    const t = out.toOwnedSlice(app.gpa) catch return;
    app.store.replaceLabeled(f, t, std.fmt.allocPrint(app.frame.allocator(), "- {s}", .{name}) catch null) catch app.gpa.free(t);
}

/// Scene `name` started by a script of level `level` (StartScriptlet/SetAddonScriptlet).
fn sceneOfLevel(app: *App, a: Allocator, name: []const u8, level: []const u8) bool {
    for (app.catalog.scene_files.items) |sf| {
        if (!std.ascii.eqlIgnoreCase(sf.level, level)) continue;
        const f = app.store.file(sf.archive, sf.entry) catch continue;
        const cs = scenes_mod.calls(a, app.store.text(f), name) catch continue;
        if (cs.len > 0) return true;
    }
    return false;
}

/// The scenes to pick from: this level's (its scripts start them), or all.
fn sceneChoice(app: *App, a: Allocator, p: *Paint) void {
    const d = app.doc orelse return;
    clay.openScroll(.{ .id = clay.id("lp_scenes"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = .{ .type = ui.CLAY__SIZING_TYPE_FIT, .size = .{ .minMax = .{ .min = 0, .max = 220 } } } }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    for (app.catalog.scenes.items, 0..) |sc, i| {
        if (!p.all_scenes and !sceneOfLevel(app, a, sc.name, d.name)) continue;
        const sel = app.scene != null and app.scene.? == i;
        const rid = clay.idi("lp_scene", @intCast(i));
        if (main.clickable(app, .{ .id = rid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(24) }, .padding = .{ .left = 8 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.field }, sel)) {
            app.scene = i;
            app.scenes.dlg.len = 0;
        }
        txt(sc.name, 13, theme.text, if (sel) font_mod.bold else font_mod.regular);
        clay.close();
    }
    clay.close();
    if (main.button(app, "lp_all_scenes", tx.get(if (p.all_scenes) tx.lp_scenes_level else tx.lp_scenes_all), false)) p.all_scenes = !p.all_scenes;
}

/// The points tool's panel: the scene (picked here), its points (delete each).
pub fn pointsPanel(app: *App, a: Allocator, p: *Paint) void {
    sceneChoice(app, a, p);
    const name = app.sceneName() orelse {
        clay.text(tx.get(tx.lp_points_none), .{ .textColor = theme.warn, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
        return;
    };
    txt(tx.alloc(a, tx.lp_points_of, .{name}), 13, theme.text, font_mod.bold);
    clay.text(tx.get(tx.lp_points_hint), .{ .textColor = theme.dim, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    const f = pointsFile(app) orelse return;
    for (points(a, app.store.text(f)), 0..) |pt, k| {
        clay.open(.{ .layout = .{ .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
        txt(std.fmt.allocPrint(a, "{s}  {d},{d}", .{ pt.name, pt.x, pt.y }) catch "", 13, theme.text, font_mod.regular);
        if (main.button(app, std.fmt.allocPrint(a, "lp_pt_del{d}", .{k}) catch "p", tx.get(tx.vo_remove), false)) app.askDelete(.point, 0, pt.name);
        clay.close();
    }
}

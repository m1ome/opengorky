//! The Area and Exit tools of the level edit mode: an outline drawn and finished as a
//! trigger area or a level exit (its target and label chosen), areas' panel.

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
const scenes_mod = @import("scenes.zig");
const trigger = @import("trigger.zig");
const paint = @import("paint.zig");

/// The area being drawn: its edges, to the pointer, the first point larger (a click
/// there closes it).
pub fn drawPoly(r: *c.SDL_Renderer, p: *const Paint, d: *const Doc, rect: c.SDL_FRect) void {
    const pts = p.poly.items;
    if (pts.len == 0) return;
    _ = c.SDL_SetRenderDrawColor(r, 90, 200, 255, 255);
    var prev = screen(d, rect, .{ @floatFromInt(pts[0][0]), @floatFromInt(pts[0][1]) });
    for (pts, 0..) |pt, k| {
        const s = screen(d, rect, .{ @floatFromInt(pt[0]), @floatFromInt(pt[1]) });
        if (k > 0) _ = c.SDL_RenderLine(r, prev[0], prev[1], s[0], s[1]);
        const h: f32 = if (k == 0) 6 else 3;
        _ = c.SDL_RenderFillRect(r, &.{ .x = s[0] - h, .y = s[1] - h, .w = 2 * h, .h = 2 * h });
        prev = s;
    }
    const to = if (p.poly_closed) screen(d, rect, .{ @floatFromInt(pts[0][0]), @floatFromInt(pts[0][1]) }) else screen(d, rect, p.hover orelse return);
    _ = c.SDL_RenderLine(r, prev[0], prev[1], to[0], to[1]);
}

/// A click of the area tool at `b`: a point, or (on the first point, 3 and more) the
/// area done.
pub fn areaClick(app: *App, p: *Paint, d: *const Doc, b: [2]f32) void {
    if (p.poly_closed) return;
    if (p.poly.items.len >= 3) {
        const f = p.poly.items[0];
        const dx = (@as(f32, @floatFromInt(f[0])) - b[0]) * d.zoom;
        const dy = (@as(f32, @floatFromInt(f[1])) - b[1]) * d.zoom;
        if (dx * dx + dy * dy < 100) return finishArea(app, p);
    }
    p.poly.append(app.gpa, .{ @intFromFloat(@round(b[0])), @intFromFloat(@round(b[1])) }) catch {};
}

/// The drawn polygon as a new trigger, or with the exit tool an exit (3 points at
/// least; the level reloads after, this Paint with it).
pub fn finishArea(app: *App, p: *Paint) void {
    if (p.poly.items.len < 3) return;
    // An exit closed first, its hint and level picked after (the panel's button).
    if (p.tool == .exit and p.exit_to_len == 0) {
        p.poly_closed = true;
        return;
    }
    const pts = app.gpa.dupe([2]i32, p.poly.items) catch return;
    defer app.gpa.free(pts);
    p.poly.clearRetainingCapacity();
    p.poly_closed = false;
    if (p.tool != .exit) return app.addTriggerArea(pts);
    var tb: [64]u8 = undefined;
    const to = tb[0..p.exit_to_len];
    @memcpy(to, p.exit_to[0..p.exit_to_len]);
    app.addExitArea(pts, to, p.exit_label);
}

/// The game's locations to pick from (the open one left out), `current` marked;
/// the one clicked, if any.
fn levelChoice(app: *App, id: []const u8, current: []const u8) ?[]const u8 {
    var hit: ?[]const u8 = null;
    clay.openScroll(.{ .id = clay.id(id), .layout = .{ .sizing = .{ .width = clay.grow(), .height = .{ .type = ui.CLAY__SIZING_TYPE_FIT, .size = .{ .minMax = .{ .min = 0, .max = 200 } } } }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    for (app.levels, 0..) |lv, i| {
        if (lv.battle) continue;
        if (app.doc) |d| if (std.ascii.eqlIgnoreCase(d.name, lv.name)) continue;
        const sel = std.ascii.eqlIgnoreCase(lv.name, current);
        const rid = clay.idi(id, @intCast(i + 1));
        if (main.clickable(app, .{ .id = rid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(22) }, .padding = .{ .left = 8 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.field }, sel)) hit = lv.name;
        txt(lv.name, 13, theme.text, if (sel) font_mod.bold else font_mod.regular);
        clay.close();
    }
    clay.close();
    return hit;
}

/// The hint choice: the game's own texts for exits; the one clicked, if any.
fn labelChoice(app: *App, a: Allocator, current: u16) ?u16 {
    var hit: ?u16 = null;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 4, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    for ([_][2]usize{ .{ 0, 4 }, .{ 4, trigger.exit_labels.len } }) |row| {
        clay.open(.{ .layout = .{ .childGap = 4 } });
        for (trigger.exit_labels[row[0]..row[1]], row[0]..) |id, k| {
            const t = app.catalog.exit_labels[k];
            const label = if (t.len > 0) t else std.fmt.allocPrint(a, "#{d}", .{id}) catch "?";
            if (main.button(app, std.fmt.allocPrint(a, "lp_lbl{d}", .{k}) catch "l", label, id == current)) hit = id;
        }
        clay.close();
    }
    clay.close();
    return hit;
}

/// The exit tool's panel: the hint over it and the level it loads.
pub fn exitPanel(app: *App, a: Allocator, p: *Paint) void {
    clay.text(tx.get(tx.lp_exit_hint), .{ .textColor = theme.text, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    if (labelChoice(app, a, p.exit_label)) |id| p.exit_label = id;
    const to = p.exit_to[0..p.exit_to_len];
    txt(if (to.len > 0) tx.alloc(a, tx.lp_exit_to, .{to}) else tx.get(tx.lp_exit_pick), 13, if (to.len > 0) theme.text else theme.warn, font_mod.bold);
    if (levelChoice(app, "lp_exit_lv", to)) |name| {
        p.exit_to_len = @min(name.len, p.exit_to.len);
        @memcpy(p.exit_to[0..p.exit_to_len], name[0..p.exit_to_len]);
    }
    if (p.poly_closed and p.exit_to_len == 0) clay.text(tx.get(tx.lp_exit_closed), .{ .textColor = theme.warn, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    if (p.poly.items.len >= 3 and p.exit_to_len > 0) if (main.button(app, "lp_exit_done", tx.get(tx.lp_exit_make), true)) {
        p.pending = .finish;
    };
}

/// The picked area: its name (click to type a new one), rename, delete (asked twice).
pub fn areaPanel(app: *App, a: Allocator, p: *Paint) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 6, .padding = .{ .top = 6, .bottom = 6 } }, .border = .{ .color = theme.line, .width = .{ .top = 1, .bottom = 1 } } });
    txt(tx.alloc(a, tx.lp_area_picked, .{p.area[0..p.area_len]}), 13, theme.text, font_mod.bold);
    clay.open(.{ .layout = .{ .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    const fid = clay.id("lp_area_name");
    clay.open(.{ .id = fid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(26) }, .padding = .{ .left = 8, .right = 8 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.field, .cornerRadius = clay.radius(theme.radius), .border = .{ .color = if (p.renaming) theme.accent else theme.field_border, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } } });
    if (clay.hovered() and app.clicked) p.renaming = true;
    txt(std.fmt.allocPrint(a, "{s}{s}", .{ p.name[0..p.name_len], if (p.renaming) "|" else "" }) catch "", 13, theme.text, font_mod.regular);
    clay.close();
    if (main.button(app, "lp_area_rename", tx.get(tx.lp_area_rename), false)) p.pending = .rename;
    clay.close();
    // An exit: where it leads (open it, or pick another level).
    if (app.doc) |d| if (app.exitOf(d, p.area[0..p.area_len])) |f| {
        const to = trigger.exitTarget(app.store.text(f)) orelse "";
        txt(tx.alloc(a, tx.lp_exit_to, .{to}), 13, theme.text, font_mod.bold);
        if (d.areaControl(p.area[0..p.area_len])) |cp| if (!d.reachable(cp)) {
            clay.text(tx.get(tx.lp_exit_unreachable), .{ .textColor = theme.warn, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
        };
        if (to.len > 0) if (main.button(app, "lp_exit_go", tx.alloc(a, tx.lp_exit_go, .{to}), false)) app.link(false, to, null);
        if (levelChoice(app, "lp_exit_re", to)) |name| app.setExitTarget(f, name);
    };
    // What entering it starts (the blocks of the level's scripts naming it).
    if (app.doc) |d| {
        var k: u32 = 0;
        for (d.levelFiles(a) catch &.{}) |f| {
            const text = app.store.text(f);
            for (scenes_mod.refs(a, text, p.area[0..p.area_len]) catch &.{}) |call| for (scenes_mod.startedIn(a, text, call.at)) |sc| {
                k += 1;
                if (main.button(app, std.fmt.allocPrint(a, "lp_area_sc{d}", .{k}) catch "s", tx.alloc(a, tx.ln_scene, .{sc}), false)) app.link(true, sc, null);
            };
        }
        if (k == 0) txt(tx.get(tx.lp_area_no_scene), 12, theme.dim, font_mod.regular);
    }
    if (main.button(app, "lp_area_delete", tx.get(tx.lp_area_delete), false)) app.askDelete(.area, 0, p.area[0..p.area_len]);
    clay.close();
}

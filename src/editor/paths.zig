//! The level edit mode's Paths tool: a location's walk paths (`<level>.ap`: stairs,
//! ladders, footbridges, a route the walk takes between two cells of the walk grid —
//! `link` its start and end cell — through its nodes) drawn on the map, nodes dragged,
//! added by clicks, a path's cells set, paths made and deleted; each path's `.pth` script
//! (NodeResponse: the walk animation at a node) opened or made. The file is written in
//! the game's layout (level_files.encodePaths, every game file round-trips).

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const ui = @import("ui");
const lf = og.formats.level_files;
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const textedit = @import("textedit.zig");
const codeview = @import("codeview.zig");
const level = @import("level.zig");
const Doc = level.Doc;
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;

/// The Paths tool (`app.paths`): the picked path, what a click does, a node dragged.
pub const State = struct {
    sel: main.Name(64) = .{},
    mode: Mode = .pick,
    drag: ?struct { node: usize, at: [2]f32 } = null,
};

const Mode = enum { pick, add, start, end };

fn apEntry(a: Allocator, d: *Doc) []const u8 {
    return std.fmt.allocPrint(a, "{s}.ap", .{d.name}) catch "";
}

/// The paths as the Store has them (frame memory; names copied).
pub fn load(app: *App, d: *Doc) []lf.Path {
    const a = app.frame.allocator();
    const f = app.store.file(d.level_archive, apEntry(a, d)) catch return &.{};
    const ps = lf.parsePaths(a, app.store.text(f)) catch return &.{};
    return ps;
}

fn save(app: *App, d: *Doc, ps: []const lf.Path, what: []const u8) void {
    const a = app.frame.allocator();
    const entry = apEntry(a, d);
    const t = lf.encodePaths(app.gpa, ps) catch return;
    if (app.store.file(d.level_archive, entry)) |f| {
        app.store.replaceLabeled(f, t, std.fmt.allocPrint(a, "{s}: {s}", .{ entry, what }) catch entry) catch |err| {
            app.gpa.free(t);
            app.setStatus(tx.st_set_failed, .{err});
        };
    } else |_| {
        _ = app.store.addNew(&.{.{ .archive = d.level_archive, .entry = entry, .text = t }}) catch |err| app.setStatus(tx.st_set_failed, .{err});
    }
}

fn selIndex(app: *App, ps: []const lf.Path) ?usize {
    for (ps, 0..) |p, k| if (std.mem.eql(u8, p.name, app.paths.sel.get())) return k;
    return null;
}

/// Paths over the map: each a line through its nodes, the picked one bright with its
/// nodes numbered and its start and end cells marked.
pub fn draw(app: *App, d: *Doc, rect: c.SDL_FRect) void {
    const ps = load(app, d);
    const cs = lf.WalkMap.cell_size;
    for (ps, 0..) |p, k| {
        const sel = selIndex(app, ps) == k;
        const a: u8 = if (sel) 255 else 120;
        _ = c.SDL_SetRenderDrawColor(app.r, 120, 220, 255, a);
        var prev: ?[2]f32 = null;
        for (p.points, 0..) |pt0, i| {
            var pt: [2]f32 = .{ pt0[0], pt0[1] };
            if (app.paths.drag) |dr| if (sel and dr.node == i) {
                pt = dr.at;
            };
            const s = d.toScreen(rect, pt);
            if (prev) |q| _ = c.SDL_RenderLine(app.r, q[0], q[1], s[0], s[1]);
            const r: f32 = if (sel) 5 else 3;
            _ = c.SDL_RenderFillRect(app.r, &.{ .x = s[0] - r, .y = s[1] - r, .w = r * 2, .h = r * 2 });
            if (sel) app.font.draw(app.r, std.fmt.allocPrint(app.frame.allocator(), "{d}", .{i}) catch "", font_mod.regular, 13, s[0] + 7, s[1] - 8, .{ 160, 235, 255, 255 });
            prev = s;
        }
        if (p.points.len > 0) {
            const s = d.toScreen(rect, .{ p.points[0][0], p.points[0][1] });
            app.font.draw(app.r, p.name, font_mod.bold, 13, s[0] + 7, s[1] + 6, .{ 160, 235, 255, a });
        }
        if (!sel) continue;
        // The start (green) and end (orange) cells of the walk grid.
        for ([_][2]f32{ .{ p.link[0], p.link[1] }, .{ p.link[2], p.link[3] } }, 0..) |cell, i| {
            const s = d.toScreen(rect, .{ cell[0] * cs, cell[1] * cs });
            if (i == 0) _ = c.SDL_SetRenderDrawColor(app.r, 90, 230, 120, 255) else _ = c.SDL_SetRenderDrawColor(app.r, 255, 160, 60, 255);
            _ = c.SDL_RenderRect(app.r, &.{ .x = s[0], .y = s[1], .w = cs * d.zoom, .h = cs * d.zoom });
            _ = c.SDL_RenderRect(app.r, &.{ .x = s[0] - 1, .y = s[1] - 1, .w = cs * d.zoom + 2, .h = cs * d.zoom + 2 });
        }
    }
}

/// Pressed on the map: a node added or a cell set (the panel's mode), else a node of the
/// picked path (or any) taken to drag, a path picked.
pub fn press(app: *App, d: *Doc, rect: c.SDL_FRect, m: [2]f32) void {
    const ps = load(app, d);
    const bg = d.toBackground(rect, m);
    if (selIndex(app, ps)) |k| switch (app.paths.mode) {
        .add => {
            const a = app.frame.allocator();
            var more = a.alloc([4]f32, ps[k].points.len + 1) catch return;
            @memcpy(more[0..ps[k].points.len], ps[k].points);
            more[ps[k].points.len] = .{ @round(bg[0]), @round(bg[1]), 0, 0 };
            ps[k].points = more;
            return save(app, d, ps, "node");
        },
        .start, .end => {
            const cs = lf.WalkMap.cell_size;
            const cell: [2]f32 = .{ @floor(bg[0] / cs), @floor(bg[1] / cs) };
            if (app.paths.mode == .start) {
                ps[k].link[0] = cell[0];
                ps[k].link[1] = cell[1];
            } else {
                ps[k].link[2] = cell[0];
                ps[k].link[3] = cell[1];
            }
            app.paths.mode = .pick;
            return save(app, d, ps, "link");
        },
        .pick => {},
    };
    // A node within 8 points: the picked path's first.
    var best: ?struct { path: usize, node: usize } = null;
    const sk = selIndex(app, ps);
    for (ps, 0..) |p, k| for (p.points, 0..) |pt, i| {
        const s = d.toScreen(rect, .{ pt[0], pt[1] });
        if (@abs(s[0] - m[0]) > 8 or @abs(s[1] - m[1]) > 8) continue;
        if (best == null or k == sk) best = .{ .path = k, .node = i };
    };
    if (best) |b| {
        app.paths.sel.set(ps[b.path].name);
        app.paths.drag = .{ .node = b.node, .at = .{ ps[b.path].points[b.node][0], ps[b.path].points[b.node][1] } };
        return;
    }
    app.pan = m;
}

pub fn drag(app: *App, d: *Doc, rect: c.SDL_FRect, m: [2]f32) void {
    const dr = &(app.paths.drag orelse return);
    const bg = d.toBackground(rect, m);
    dr.at = .{ @round(bg[0]), @round(bg[1]) };
}

pub fn release(app: *App, d: *Doc) void {
    const dr = app.paths.drag orelse return;
    app.paths.drag = null;
    const ps = load(app, d);
    const k = selIndex(app, ps) orelse return;
    if (dr.node >= ps[k].points.len) return;
    if (ps[k].points[dr.node][0] == dr.at[0] and ps[k].points[dr.node][1] == dr.at[1]) return;
    ps[k].points[dr.node][0] = dr.at[0];
    ps[k].points[dr.node][1] = dr.at[1];
    save(app, d, ps, "node moved");
}

/// The tool's panel: the paths (one picked), its nodes (typed: x, y, angle, the last
/// number), the click modes, its script, a new path, delete.
pub fn panel(app: *App, a: Allocator, d: *Doc) void {
    clay.text(tx.get(tx.pa_hint), .{ .textColor = theme.text, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    const ps = load(app, d);
    for (ps, 0..) |p, k| {
        const sel = selIndex(app, ps) == k;
        const rid = clay.idi("path_row", @intCast(k));
        if (main.clickable(app, .{ .id = rid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(28) }, .padding = .{ .left = 8, .right = 8 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel, .cornerRadius = clay.radius(4) }, sel)) {
            app.paths.sel.set(p.name);
            app.paths.mode = .pick;
        }
        txt(p.name, 14, theme.text, if (sel) font_mod.bold else font_mod.regular);
        txt(tx.alloc(a, tx.pa_nodes, .{p.points.len}), 12, theme.dim, font_mod.regular);
        clay.close();
    }
    if (main.toolButton(app, "path_new", .plus, tx.get(tx.pa_new), false, false)) newPath(app, d, ps);
    const k = selIndex(app, ps) orelse return;
    const p = ps[k];
    main.panelHeader(p.name);
    clay.open(.{ .layout = .{ .childGap = 6 } });
    if (main.toolButton(app, "path_add", .plus, tx.get(tx.pa_add), app.paths.mode == .add, false)) app.paths.mode = if (app.paths.mode == .add) .pick else .add;
    if (main.toolButton(app, "path_start", .crosshair, tx.get(tx.pa_start), app.paths.mode == .start, false)) app.paths.mode = .start;
    if (main.toolButton(app, "path_end", .crosshair, tx.get(tx.pa_end), app.paths.mode == .end, false)) app.paths.mode = .end;
    clay.close();
    txt(tx.alloc(a, tx.pa_link, .{ p.link[0], p.link[1], p.link[2], p.link[3] }), 12, theme.dim, font_mod.regular);
    for (p.points, 0..) |pt, i| {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 4, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(20) } } });
        txt(std.fmt.allocPrint(a, "{d}", .{i}) catch "", 12, theme.dim, font_mod.regular);
        clay.close();
        inline for (0..4) |j| {
            const shown = if (j == 2) std.fmt.allocPrint(a, "{d:.2}", .{pt[j]}) catch "" else std.fmt.allocPrint(a, "{d}", .{@as(i32, @intFromFloat(pt[j]))}) catch "";
            if (textedit.field(app, std.fmt.allocPrint(a, "pn{d}_{d}_{d}", .{ k, i, j }) catch "pn", shown, 64, "")) |v| {
                if (std.fmt.parseFloat(f32, std.mem.trim(u8, v, " "))) |num| {
                    ps[k].points[i][j] = num;
                    save(app, d, ps, "node");
                } else |_| {}
            }
        }
        if (main.toolButton(app, std.fmt.allocPrint(a, "pn_del{d}", .{i}) catch "pd", .trash_2, "", false, false)) {
            var fewer = a.alloc([4]f32, p.points.len - 1) catch return clay.close();
            @memcpy(fewer[0..i], p.points[0..i]);
            @memcpy(fewer[i..], p.points[i + 1 ..]);
            ps[k].points = fewer;
            save(app, d, ps, "node deleted");
        }
        clay.close();
    }
    clay.open(.{ .layout = .{ .childGap = 6 } });
    if (main.toolButton(app, "path_script", .code, tx.get(tx.pa_script), false, false)) openScript(app, d, p.name);
    if (main.toolButton(app, "path_del", .trash_2, tx.get(tx.cm_delete), false, false)) app.askDelete(.path, 0, p.name);
    clay.close();
}

fn newPath(app: *App, d: *Doc, ps: []lf.Path) void {
    const a = app.frame.allocator();
    const name = for (1..1000) |n| {
        const s = std.fmt.allocPrint(a, "path{d}", .{n}) catch return;
        for (ps) |p| {
            if (std.ascii.eqlIgnoreCase(p.name, s)) break;
        } else break s;
    } else return;
    var more = a.alloc(lf.Path, ps.len + 1) catch return;
    @memcpy(more[0..ps.len], ps);
    more[ps.len] = .{ .name = name, .link = .{ 0, 0, 0, 0 }, .points = &.{} };
    save(app, d, more, "new path");
    app.paths.sel.set(name);
    app.paths.mode = .add;
    app.setStatus(tx.st_path_added, .{name});
}

/// Path `name` deleted (its `.pth` stays: a script nothing names is harmless).
pub fn remove(app: *App, d: *Doc, name: []const u8) void {
    const ps = load(app, d);
    var out: std.ArrayList(lf.Path) = .empty;
    for (ps) |p| if (!std.ascii.eqlIgnoreCase(p.name, name)) out.append(app.frame.allocator(), p) catch return;
    save(app, d, out.items, "path deleted");
    app.paths.sel.set("");
}

/// Path `name`'s `.pth` in the code editor (made first with NodeResponse if missing).
fn openScript(app: *App, d: *Doc, name: []const u8) void {
    const a = app.frame.allocator();
    const entry = std.fmt.allocPrint(a, "{s}.pth", .{name}) catch return;
    if (app.store.file(d.level_archive, entry)) |f| return codeview.open(app, f, null) else |_| {}
    const t = app.gpa.dupe(u8, "// The walk along this path: node `no` reached, `dir` 1 forward, 0 back.\r\nfunction NodeResponse(int no, int dir)\r\n{\r\n};\r\n") catch return;
    const f = app.store.addNew(&.{.{ .archive = d.level_archive, .entry = entry, .text = t }}) catch |err| return app.setStatus(tx.st_set_failed, .{err});
    codeview.open(app, f, null);
}

//! Scenes tab: the cutscenes, what each changes in the game, where level scripts start
//! it; a scene can skip itself (its changes still happen) or a start can be turned off.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const scenes = @import("scenes.zig");
const info = @import("info.zig");
const common_archive = @import("store.zig").common_archive;
const codeview = @import("codeview.zig");
const code = @import("code.zig");
const og = @import("opengorky");
const voices = @import("voices.zig");
const main = @import("app.zig");
const icons = @import("icons.zig");
const level_mod = @import("level.zig");
const treemenu = @import("treemenu.zig");
const ui_main = @import("main.zig");
const c = @import("sdl");
const App = main.App;
const theme = main.theme;
const txt = main.txt;

/// The Scenes tab's state (`app.scenes`; the picked scene is `app.scene`).
pub const State = struct {
    /// A dialogue shown instead of a scene: a battle's (`<battle>.dlg`) or an idle one.
    dlg: main.Name(64) = .{},
    /// The scene's new name being typed.
    name: main.Name(48) = .{},
    naming: bool = false,
    /// The page's view and its map preview's shown layers (areas, objects, entry).
    view: enum { overview, lines, debug } = .overview,
    show: [3]bool = .{ true, false, true },
    preview: main.ScenePreview = .{},
    /// The last test run of a scene (its name owned) — the Debug view.
    report: ?struct { name: []u8, level: []u8, report: og.scene_check.Report } = null,
};

/// Scene commands that change the game rather than show it.
const lasting = [_][]const u8{ "SETHERO", "DELETEOBJECT", "DISABLEOBJECT", "LOADLEVEL", "PREVLEVEL", "GO_RUNFUN", "ALLOW_WALK_IN_AREA", "FORBID_WALK_IN_AREA", "ASSIGN_ITEM", "ADDONSCRIPTLET", "PLACEHEROES", "GUI_GAMEOVER", "GUI_ENDDEMO", "GUI_CREDITS" };

fn sceneFile(app: *App, name: []const u8) ?usize {
    var buf: [128]u8 = undefined;
    return app.store.file(common_archive, std.fmt.bufPrint(&buf, "scriptlets\\{s}.scr", .{name}) catch return null) catch null;
}

fn skipped(app: *App, name: []const u8) bool {
    const f = sceneFile(app, name) orelse return false;
    return scenes.isShort(app.store.text(f));
}

pub fn page(app: *App, a: Allocator) void {
    if (app.scenes.dlg.len == 0) if (app.scene) |i| return scenePage(app, a, app.catalog.scenes.items[i].name);
    clay.openScroll(.{ .id = clay.id("scene_detail"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 20, .right = 20, .top = 16, .bottom = 16 }, .childGap = 8 } });
    if (app.scenes.dlg.len > 0) dialogPage(app, a, app.scenes.dlg.get()) else txt(tx.get(tx.pick_entry), 15, theme.dim, font_mod.regular);
    clay.close();
}

/// A battle's or idle dialogue on its own; a battle without one gets a new file.
fn dialogPage(app: *App, a: Allocator, name: []const u8) void {
    txt(name, 20, theme.text, font_mod.bold);
    txt(tx.get(if (std.ascii.startsWithIgnoreCase(name, "idle_")) tx.sc_idle_hint else tx.sc_battle_hint), 12, theme.dim, font_mod.regular);
    if (app.store.file(lang_archive, name)) |f| return dialogBlock(app, a, f, name, 1) else |_| {}
    if (main.button(app, "dlg_new", tx.get(tx.sc_new_lines), true)) {
        // The game's layout: `DIALOG <name>`, a speaker, the text indented (Windows lines).
        const t = std.fmt.allocPrint(app.gpa, "DIALOG {s}\r\n\r\nSullivan:\r\n  ...\r\n", .{name[0 .. name.len - 4]}) catch return;
        const f = app.store.addNew(&.{.{ .archive = lang_archive, .entry = name, .text = t }}) catch |err| {
            app.gpa.free(t);
            return app.setStatus(tx.st_set_failed, .{err});
        };
        codeview.open(app, f, null);
    }
}

/// A place a level script starts the scene: its file, level and the call.
const Entry = struct { file: usize, level: []const u8, entry: []const u8, call: scenes.Call };

fn entriesOf(app: *App, a: Allocator, name: []const u8) []const Entry {
    var out: std.ArrayList(Entry) = .empty;
    for (app.catalog.scene_files.items) |sfile| {
        const fi = app.store.file(sfile.archive, sfile.entry) catch continue;
        const cs = scenes.calls(a, app.store.text(fi), name) catch continue;
        for (cs) |call| out.append(a, .{ .file = fi, .level = sfile.level, .entry = sfile.entry, .call = call }) catch {};
    }
    return out.items;
}

/// The scene as the concept's page: its header and views (overview, lines, code, debug)
/// on the left, its properties, utilities and Info on the right.
fn scenePage(app: *App, a: Allocator, name: []const u8) void {
    const sf = sceneFile(app, name);
    const entries = entriesOf(app, a, name);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } } });
    clay.openScroll(.{ .id = clay.id("scene_detail"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 20, .right = 20, .top = 16, .bottom = 16 }, .childGap = 12 } });
    if (header(app, a, name)) {
        clay.close();
        clay.close();
        return;
    }
    viewTabs(app, sf);
    if (sf) |f| switch (app.scenes.view) {
        .overview => {
            entryTable(app, a, entries);
            effectTable(app, a, f);
            mapPreview(app, a, f, entries);
        },
        .lines => {
            dialogs(app, a, app.store.text(f));
            if (std.ascii.findIgnoreCase(app.store.text(f), "DIALOG_INIT(") == null) txt(tx.get(tx.sc_no_lines), 13, theme.dim, font_mod.regular);
        },
        .debug => debugView(app, a, name, f, entries),
    } else txt(tx.get(tx.sc_none), 13, theme.dim, font_mod.regular);
    clay.close();
    inspector(app, a, name, sf, entries);
    clay.close();
}

/// The icon, the name (a click renames), "Scene scriptlet" and Play in the port; true when renamed.
fn header(app: *App, a: Allocator, name: []const u8) bool {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 14, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    icons.leaf(app.r, app.gpa, .clapperboard, 34, theme.accent_hover);
    clay.open(.{ .layout = .{ .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 2 } });
    const fid = clay.id("scene_name");
    clay.open(.{ .id = fid, .layout = .{ .sizing = .{ .width = clay.fixed(340), .height = clay.fixed(32) }, .padding = .{ .left = 8, .right = 8 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = if (app.scenes.naming) theme.field else if (clay.pointerOver(fid)) theme.row_hover else theme.bg, .cornerRadius = clay.radius(theme.radius), .border = .{ .color = if (app.scenes.naming) theme.accent else theme.bg, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } } });
    if (clay.hovered() and app.clicked and !app.scenes.naming) {
        app.scenes.naming = true;
        app.scenes.name.set(name);
    }
    txt(if (app.scenes.naming) std.fmt.allocPrint(a, "{s}|", .{app.scenes.name.get()}) catch "" else name, 20, theme.text, font_mod.bold);
    clay.close();
    txt(tx.get(if (app.scenes.naming) tx.sc_rename_hint else tx.sc_kind), 12, theme.dim, font_mod.regular);
    clay.close();
    const rename = app.scenes.naming and main.button(app, "scene_rename", tx.get(tx.lp_area_rename), true);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    if (sceneLevel(app, a, name)) |lvl| if (main.toolButton(app, "scene_play", .play, tx.alloc(a, tx.sc_play_port, .{lvl}), false, true)) app.playIn(lvl, name);
    clay.close();
    if (rename) {
        app.scenes.naming = false;
        app.renameScene(name, app.scenes.name.get());
        return true;
    }
    return false;
}

/// The views; Code is the script in the code editor (its own tab, as a level's script).
fn viewTabs(app: *App, sf: ?usize) void {
    clay.open(.{ .layout = .{ .childGap = 6 } });
    const views = [_]struct { @TypeOf(app.scenes.view), tx.Msg }{ .{ .overview, tx.sc_v_overview }, .{ .lines, tx.sc_v_lines }, .{ .debug, tx.sc_v_debug } };
    for (views[0..2]) |v| if (main.button(app, @tagName(v[0]), tx.get(v[1]), app.scenes.view == v[0])) {
        app.scenes.view = v[0];
    };
    if (sf) |f| if (main.button(app, "sc_code", tx.get(tx.sc_v_code), false)) codeview.open(app, f, null);
    for (views[2..]) |v| if (main.button(app, @tagName(v[0]), tx.get(v[1]), app.scenes.view == v[0])) {
        app.scenes.view = v[0];
    };
    clay.close();
}

/// A section title with its dim note.
fn section(title: tx.Msg, note: tx.Msg) void {
    clay.open(.{ .layout = .{ .childGap = 12, .padding = .{ .top = 6 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    txt(tx.get(title), 16, theme.text, font_mod.bold);
    txt(tx.get(note), 12, theme.dim, font_mod.regular);
    clay.close();
}

/// A table: a bordered box whose rows are `tableRow` + cells.
fn tableOpen() void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM }, .backgroundColor = theme.panel, .cornerRadius = clay.radius(theme.radius), .border = .{ .color = theme.line, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } } });
}

fn tableRow(head: bool) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(if (head) 32 else 40) }, .padding = .{ .left = 14, .right = 14 }, .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = if (head) theme.header else theme.panel, .border = .{ .color = theme.line, .width = .{ .bottom = 1 } } });
}

/// A cell `w` wide (0: the rest).
fn cell(w: f32) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = if (w == 0) clay.grow() else clay.fixed(w) }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
}

fn headCells(cols: []const struct { tx.Msg, f32 }) void {
    tableRow(true);
    for (cols) |col| {
        cell(col[1]);
        txt(tx.get(col[0]), 12, theme.dim, font_mod.regular);
        clay.close();
    }
    clay.close();
}

/// A script excerpt under a row, as code.
fn codeBlock(a: Allocator, text: []const u8, start: usize, end: usize) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 8, .right = 16, .top = 8, .bottom = 8 }, .childGap = 2 }, .backgroundColor = theme.viewport });
    codeview.excerpt(a, text, start, end);
    clay.close();
}

const entry_cols = [_]struct { tx.Msg, f32 }{ .{ tx.sc_c_where, 0 }, .{ tx.sc_c_event, 190 }, .{ tx.sc_c_enabled, 80 }, .{ tx.sc_c_actions, 170 } };

/// Where it starts: each level script call as a row (where, what event, a switch
/// turning the start off, show on the map) with its block below.
fn entryTable(app: *App, a: Allocator, entries: []const Entry) void {
    section(tx.sc_entries, tx.sc_entries_note);
    if (entries.len == 0) return txt(tx.get(tx.sc_none), 13, theme.dim, font_mod.regular);
    tableOpen();
    headCells(&entry_cols);
    for (entries, 0..) |en, k| {
        const text = app.store.text(en.file);
        const area = scenes.areaOf(a, text, en.call.at);
        tableRow(false);
        cell(0);
        icons.leaf(app.r, app.gpa, .map_pin, 15, theme.accent_hover);
        txt(en.level, 14, theme.text, font_mod.regular);
        if (area) |ar| {
            icons.leaf(app.r, app.gpa, .chevron_right, 12, theme.dim);
            txt(ar, 14, theme.text, font_mod.regular);
        }
        clay.close();
        cell(190);
        txt(tx.get(if (en.call.addon) tx.sc_ev_addon else if (area != null) tx.sc_ev_area else tx.sc_ev_script), 13, theme.text, font_mod.regular);
        clay.close();
        cell(80);
        const id: u32 = @intCast(k);
        switch (en.call.state) {
            .game_off => txt(tx.get(tx.sc_game_off_short), 12, theme.dim, font_mod.regular),
            .on, .off => {
                const on = en.call.state == .on;
                const span = if (on) scenes.block(text, en.call.at) else scenes.offRun(text, en.call.at);
                if (!on or scenes.safe(text, en.call.at)) {
                    if (switchBox(app, clay.idi("sc_en", id), on)) change(app, en.file, if (on) scenes.turnOff(app.gpa, text, span) else scenes.turnOn(app.gpa, text, en.call.at));
                } else txt(tx.get(tx.sc_unsafe_short), 12, theme.warn, font_mod.regular);
            },
        }
        clay.close();
        cell(170);
        if (area) |ar| {
            if (main.toolButton(app, std.fmt.allocPrint(a, "sc_map{d}", .{k}) catch "m", .crosshair, tx.get(tx.sc_show_map), false, false)) app.link(false, en.level, ar);
        } else if (main.toolButton(app, std.fmt.allocPrint(a, "sc_ecode{d}", .{k}) catch "m", .code, tx.get(tx.sc_view_code), false, false)) codeview.open(app, en.file, en.call.at);
        clay.close();
        clay.close();
        const span = if (en.call.state == .off) scenes.offRun(text, en.call.at) else scenes.block(text, en.call.at);
        codeBlock(a, text, span.start, span.end);
    }
    clay.close();
}

/// An on/off switch (as the concept's); true when clicked.
fn switchBox(app: *App, id: ui.Clay_ElementId, on: bool) bool {
    clay.open(.{ .id = id, .layout = .{ .sizing = .{ .width = clay.fixed(36), .height = clay.fixed(20) }, .padding = .{ .left = 3, .right = 3 }, .childAlignment = .{ .x = if (on) ui.CLAY_ALIGN_X_RIGHT else ui.CLAY_ALIGN_X_LEFT, .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = if (on) theme.accent else theme.field_border, .cornerRadius = clay.radius(10) });
    const hit = clay.hovered() and app.clicked;
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(14), .height = clay.fixed(14) } }, .backgroundColor = theme.text, .cornerRadius = clay.radius(7) });
    clay.close();
    return hit;
}

const effect_cols = [_]struct { tx.Msg, f32 }{ .{ tx.sc_c_type, 200 }, .{ tx.sc_c_target, 0 }, .{ tx.sc_c_arg, 140 }, .{ tx.sc_c_actions, 170 } };

/// What it changes in the game: each lasting command as a row (what, on what, the rest
/// of its arguments, its line in the code), the line below.
fn effectTable(app: *App, a: Allocator, f: usize) void {
    section(tx.sc_effects, tx.sc_effects_note);
    const text = app.store.text(f);
    var rows: usize = 0;
    var pos: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| : (pos += raw.len + 1) {
        const l = std.mem.trim(u8, raw, " \t\r");
        const k = for (lasting, 0..) |cmd, i| {
            if (std.ascii.startsWithIgnoreCase(l, cmd) and l.len > cmd.len and l[cmd.len] == '(') break i;
        } else continue;
        if (rows == 0) {
            tableOpen();
            headCells(&effect_cols);
        }
        rows += 1;
        const args = l[lasting[k].len + 1 .. std.mem.lastIndexOfScalar(u8, l, ')') orelse l.len];
        const comma = std.mem.indexOfScalar(u8, args, ',');
        const target = std.mem.trim(u8, args[0 .. comma orelse args.len], " \"");
        const rest = if (comma) |ci| std.mem.trim(u8, args[ci + 1 ..], " ") else "";
        tableRow(false);
        cell(200);
        icons.leaf(app.r, app.gpa, effectIcon(lasting[k]), 15, theme.dim);
        txt(tx.get(effect_names[k]), 14, theme.text, font_mod.regular);
        clay.close();
        cell(0);
        txt(target, 14, theme.text, font_mod.regular);
        clay.close();
        cell(140);
        txt(rest, 13, theme.dim, font_mod.regular);
        clay.close();
        cell(170);
        const id = std.fmt.allocPrint(a, "sc_eff{d}", .{rows}) catch "e";
        if (std.ascii.eqlIgnoreCase(lasting[k], "ADDONSCRIPTLET")) {
            if (main.toolButton(app, id, .clapperboard, tx.alloc(a, tx.ln_scene, .{target}), false, false)) app.link(true, target, null);
        } else if (std.ascii.eqlIgnoreCase(lasting[k], "LOADLEVEL")) {
            if (main.toolButton(app, id, .map_pin, tx.alloc(a, tx.ln_level, .{target}), false, false)) app.link(false, target, null);
        } else if (main.toolButton(app, id, .code, tx.get(tx.sc_view_code), false, false)) codeview.open(app, f, pos);
        clay.close();
        clay.close();
        codeBlock(a, text, pos, pos + raw.len);
    }
    if (rows == 0) txt(tx.get(tx.sc_no_changes), 13, theme.dim, font_mod.regular) else clay.close();
}

const effect_names = [_]tx.Msg{ tx.ef_sethero, tx.ef_delete, tx.ef_disable, tx.ef_loadlevel, tx.ef_prevlevel, tx.ef_runfun, tx.ef_allow_walk, tx.ef_forbid_walk, tx.ef_item, tx.ef_next, tx.ef_place, tx.ef_gameover, tx.ef_enddemo, tx.ef_credits };

fn effectIcon(cmd: []const u8) icons.Icon {
    if (std.ascii.eqlIgnoreCase(cmd, "PLACEHEROES") or std.ascii.eqlIgnoreCase(cmd, "SETHERO")) return .user;
    if (std.ascii.eqlIgnoreCase(cmd, "LOADLEVEL") or std.ascii.eqlIgnoreCase(cmd, "PREVLEVEL")) return .log_out;
    if (std.ascii.eqlIgnoreCase(cmd, "ASSIGN_ITEM")) return .package;
    if (std.ascii.eqlIgnoreCase(cmd, "ADDONSCRIPTLET")) return .clapperboard;
    if (std.ascii.endsWithIgnoreCase(cmd, "OBJECT")) return .eye_off;
    if (std.ascii.findIgnoreCase(cmd, "WALK") != null) return .square_dashed;
    return .play;
}

/// The scene's location (its first start's level) drawn small: its areas, objects and
/// the area that starts it, with what the scene names picked out.
fn mapPreview(app: *App, a: Allocator, f: usize, entries: []const Entry) void {
    if (entries.len == 0) return;
    const lvl = entries[0].level;
    const d = app.levelDoc(lvl) orelse return;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 14, .padding = .{ .top = 6 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    txt(tx.get(tx.sc_map), 16, theme.text, font_mod.bold);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    txt(tx.get(tx.sc_show), 13, theme.dim, font_mod.regular);
    const names = [_]tx.Msg{ tx.sc_show_areas, tx.sc_show_objects, tx.sc_show_entries };
    for (names, 0..) |n, k| {
        const cid = clay.idi("sc_show", @intCast(k));
        clay.open(.{ .id = cid, .layout = .{ .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
        if (clay.hovered() and app.clicked) app.scenes.show[k] = !app.scenes.show[k];
        ui_main.checkbox(app, app.scenes.show[k]);
        txt(tx.get(n), 13, theme.text, font_mod.regular);
        clay.close();
    }
    clay.close();
    // What it uses: the starting area and the places the scene names.
    const pv = &app.scenes.preview;
    pv.doc = d;
    pv.sel = null;
    pv.focus = null;
    pv.names.clearRetainingCapacity();
    const text = app.store.text(entries[0].file);
    if (scenes.areaOf(a, text, entries[0].call.at)) |ar| for (d.objects.items, 0..) |o, i| if (std.ascii.eqlIgnoreCase(o.name, ar)) {
        pv.sel = i;
    };
    for (usedNames(app, a, d, app.store.text(f))) |i| pv.names.append(app.gpa, i) catch {};
    pv.show = app.scenes.show;
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(380) } }, .backgroundColor = theme.viewport, .cornerRadius = clay.radius(theme.radius), .custom = .{ .customData = pv } });
}

/// Objects of level `d` the scene text names in quotes.
fn usedNames(app: *App, a: Allocator, d: *level_mod.Doc, text: []const u8) []const usize {
    _ = app;
    var out: std.ArrayList(usize) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, pos, '"')) |q| {
        const e = std.mem.indexOfScalarPos(u8, text, q + 1, '"') orelse break;
        pos = e + 1;
        const n = text[q + 1 .. e];
        for (d.objects.items, 0..) |o, i| if (std.ascii.eqlIgnoreCase(o.name, n) and std.mem.indexOfScalar(usize, out.items, i) == null) out.append(a, i) catch {};
    }
    return out.items;
}

/// Draws the preview (the viewport callback): the level fitted around what the scene
/// uses, the doc's own view kept.
pub fn drawPreview(app: *App, rect: c.SDL_FRect) void {
    const pv = &app.scenes.preview;
    const d = pv.doc orelse return;
    const keep = .{ d.origin, d.zoom, d.fitted, d.view_hidden };
    defer {
        d.origin = keep[0];
        d.zoom = keep[1];
        d.fitted = keep[2];
        d.view_hidden = keep[3];
    }
    // Hidden kinds: areas or every object (the checkboxes).
    var hidden: std.StringHashMapUnmanaged(void) = .empty;
    defer hidden.deinit(app.gpa);
    if (!pv.show[0]) hidden.put(app.gpa, "kind:area", {}) catch {};
    if (!pv.show[1]) for ([_][]const u8{ "kind:enemy", "kind:hero", "kind:neutral", "kind:prop", "kind:item", "kind:actor" }) |k| hidden.put(app.gpa, k, {}) catch {};
    d.view_hidden = &hidden;
    // Around the used places (the whole level if none), with room about them.
    var lo: [2]f32 = .{ std.math.floatMax(f32), std.math.floatMax(f32) };
    var hi: [2]f32 = .{ -std.math.floatMax(f32), -std.math.floatMax(f32) };
    for (pv.names.items) |i| {
        const p = d.objects.items[i].pos;
        lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
        hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
    }
    if (pv.sel) |i| {
        const p = d.objects.items[i].pos;
        lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
        hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
    }
    d.fit(rect);
    if (lo[0] <= hi[0]) {
        const w = @max(hi[0] - lo[0] + 500, 700);
        const h = @max(hi[1] - lo[1] + 400, 500);
        d.zoom = @max(d.zoom, @min(rect.w / w, rect.h / h));
        const mid: [2]f32 = .{ (lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2 };
        d.origin = .{ mid[0] - rect.w / 2 / d.zoom, mid[1] - rect.h / 2 / d.zoom };
    }
    const clip: c.SDL_Rect = .{ .x = @intFromFloat(rect.x), .y = @intFromFloat(rect.y), .w = @intFromFloat(rect.w), .h = @intFromFloat(rect.h) };
    _ = c.SDL_SetRenderClipRect(app.r, &clip);
    d.draw(app.r, app.font, rect, if (pv.show[2]) pv.sel else null, true, true);
    _ = c.SDL_SetRenderClipRect(app.r, null);
}

/// Where the scene is tried: the level of its first start.
fn sceneLevel(app: *App, a: Allocator, name: []const u8) ?[]const u8 {
    const es = entriesOf(app, a, name);
    return if (es.len > 0) es[0].level else null;
}

/// A test run: the scene on its level to the end without a window — whether it ends,
/// when each command starts (a click: its line in the code), what looks wrong.
fn debugView(app: *App, a: Allocator, name: []const u8, f: usize, entries: []const Entry) void {
    section(tx.sc_v_debug, tx.sc_debug_note);
    if (entries.len == 0) return txt(tx.get(tx.sc_debug_nolevel), 13, theme.warn, font_mod.regular);
    const lvl = entries[0].level;
    clay.open(.{ .layout = .{ .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    if (main.toolButton(app, "sc_run", .check, tx.get(tx.sc_run), false, true)) app.testScene(lvl, name);
    if (main.toolButton(app, "sc_run_port", .play, tx.alloc(a, tx.sc_play_port, .{lvl}), false, false)) app.playIn(lvl, name);
    txt(tx.alloc(a, tx.sc_run_on, .{lvl}), 12, theme.dim, font_mod.regular);
    clay.close();
    const r = app.scenes.report orelse return;
    if (!std.ascii.eqlIgnoreCase(r.name, name)) return;
    const rep = r.report;
    const ok = std.mem.eql(u8, rep.result, "ok");
    clay.open(.{ .layout = .{ .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    icons.leaf(app.r, app.gpa, if (ok) .check else .x, 16, if (ok) theme.ok else theme.warn);
    txt(tx.alloc(a, tx.sc_run_result, .{ rep.result, rep.ticks, @as(f32, @floatFromInt(rep.ticks)) / 30.0 }), 14, if (ok) theme.text else theme.warn, font_mod.bold);
    clay.close();
    txt(tx.get(if (ok) tx.sc_r_ok else if (std.mem.eql(u8, rep.result, "HUNG")) tx.sc_r_hung else if (std.mem.eql(u8, rep.result, "moves")) tx.sc_r_moves else tx.sc_r_level), 12, theme.dim, font_mod.regular);
    // What looks wrong, one per line.
    var it = std.mem.splitSequence(u8, rep.issues, "; ");
    while (it.next()) |is| if (is.len > 0) txt(is, 13, theme.warn, font_mod.regular);
    if (rep.issues.len == 0) txt(tx.get(tx.sc_run_clean), 13, theme.dim, font_mod.regular);
    // The commands as they ran.
    tableOpen();
    headCells(&.{ .{ tx.sc_c_tick, 90 }, .{ tx.sc_c_line, 60 }, .{ tx.sc_c_cmd, 0 }, .{ tx.sc_c_took, 110 } });
    const text = app.store.text(f);
    for (rep.trace, 0..) |st, k| {
        const rid = clay.idi("sc_step", @intCast(k));
        if (main.clickable(app, .{ .id = rid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(30) }, .padding = .{ .left = 14, .right = 14 }, .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel, .border = .{ .color = theme.line, .width = .{ .bottom = 1 } } }, false)) codeview.open(app, f, lineOffset(text, st.line));
        cell(90);
        txt(std.fmt.allocPrint(a, "{d}", .{st.start}) catch "", 13, theme.dim, font_mod.regular);
        clay.close();
        cell(60);
        txt(std.fmt.allocPrint(a, "{d}", .{st.line}) catch "", 13, theme.dim, font_mod.regular);
        clay.close();
        cell(0);
        txt(lineText(text, st.line), 13, theme.text, font_mod.regular);
        clay.close();
        cell(110);
        const took = st.end - st.start;
        txt(std.fmt.allocPrint(a, "{d} ({d:.1} s)", .{ took, @as(f32, @floatFromInt(took)) / 30.0 }) catch "", 13, if (took > 300) theme.warn else theme.dim, font_mod.regular);
        clay.close();
        clay.close();
    }
    clay.close();
}

/// Byte offset of line `line` (1-based) of `text`.
fn lineOffset(text: []const u8, line: u32) usize {
    var n: u32 = 1;
    var i: usize = 0;
    while (i < text.len and n < line) : (i += 1) n += @intFromBool(text[i] == '\n');
    return i;
}

fn lineText(text: []const u8, line: u32) []const u8 {
    const s0 = lineOffset(text, line);
    const e = std.mem.indexOfScalarPos(u8, text, s0, '\n') orelse text.len;
    return std.mem.trim(u8, text[s0..e], " \t\r");
}

/// The scene's Info: its file and location, the areas and objects of the location it
/// names, the level scripts starting it (each call), the scenes naming it.
fn sceneInfo(name: []const u8, app: *App, list: *info.List) void {
    const a = list.a;
    const entry = list.fmt("scriptlets\\{s}.scr", .{name});
    info.defined(list, common_archive, entry, true);
    const entries = entriesOf(app, a, name);
    if (entries.len > 0) list.add(.{ .group = .level, .text = entries[0].level, .to = .{ .level = .{ .name = entries[0].level } }, .icon = .map_pin });
    if (sceneFile(app, name)) |f| if (entries.len > 0) if (app.levelDoc(entries[0].level)) |d| {
        for (usedNames(app, a, d, app.store.text(f))) |i| {
            const o = d.objects.items[i];
            list.add(.{ .group = .refs, .text = o.name, .to = .{ .level = .{ .name = entries[0].level, .obj = o.name } }, .icon = if (o.kind == .area) .square_dashed else .box });
        }
    };
    for (entries) |en| list.add(.{ .group = .used, .text = list.fmt("{s} · {s}", .{ en.level, en.entry }), .to = .{ .code = .{ .archive = app.store.files.items[en.file].archive, .entry = en.entry, .at = en.call.at } }, .icon = .code });
    info.scenesNaming(app, list, list.fmt("\"{s}\"", .{name}), name);
}

/// The right column: ID, entry points; a shortened copy, skipping it; its Info.
fn inspector(app: *App, a: Allocator, name: []const u8, sf: ?usize, entries: []const Entry) void {
    main.propsOpen(app, "scene_inspector");
    txt(tx.get(tx.sc_props), 15, theme.text, font_mod.bold);
    propRow(tx.sc_p_id, name);
    propRow(tx.sc_entries, std.fmt.allocPrint(a, "{d}", .{entries.len}) catch "");
    divider();
    txt(tx.get(tx.sc_utils), 15, theme.text, font_mod.bold);
    if (main.toolButton(app, "sc_short_copy", .copy, tx.get(tx.sc_short_copy), false, false)) shortCopy(app, name);
    dimNote(tx.get(tx.sc_short_copy_hint));
    if (sf) |f| {
        const on = skipped(app, name);
        if (main.toolButton(app, "scene_skip", .eye_off, tx.get(if (on) tx.sc_unskip else tx.sc_skip), on, false)) toggleSkip(app, f, on);
        dimNote(tx.get(tx.sc_skip_hint));
    }
    main.propsTitle(tx.get(tx.info_title), false);
    info.show(app, info.rows(app, std.fmt.allocPrint(a, "scene:{s}", .{name}) catch name, name, sceneInfo));
    clay.close();
}

/// A dim note wrapped to the column.
fn dimNote(s: []const u8) void {
    clay.text(s, .{ .textColor = theme.dim, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
}

fn divider() void {
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(1) } }, .backgroundColor = theme.line });
}

fn propRow(label: tx.Msg, value: []const u8) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(100) } } });
    txt(tx.get(label), 13, theme.dim, font_mod.regular);
    clay.close();
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(30) }, .padding = .{ .left = 10, .right = 10 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.field, .cornerRadius = clay.radius(theme.radius), .border = .{ .color = theme.field_border, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } } });
    txt(value, 13, theme.text, font_mod.regular);
    clay.close();
    clay.close();
}

/// A copy of the scene with its presentation commented out (its changes stay).
fn shortCopy(app: *App, name: []const u8) void {
    treemenu.duplicate(app, treemenu.Item.of(.scene, name));
    const i = app.scene orelse return;
    const copy = app.catalog.scenes.items[i].name;
    if (std.ascii.eqlIgnoreCase(copy, name)) return;
    const f = sceneFile(app, copy) orelse return;
    if (!skipped(app, copy)) toggleSkip(app, f, false);
}

/// What the scene's characters say: each `DIALOG_INIT(name, "file.dlg")` file of
/// `common/lang.dat`, its lines numbered as `DIALOG_DISPLAY(n)` shows them; the text
/// opens in the code editor (the original reads lang.dat from the game folder).
fn dialogs(app: *App, a: Allocator, scr: []const u8) void {
    var it = std.mem.splitScalar(u8, scr, '\n');
    var k: u32 = 0;
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (!std.ascii.startsWithIgnoreCase(l, "DIALOG_INIT(")) continue;
        // The file: the last quoted argument.
        const q1 = std.mem.lastIndexOfScalar(u8, l, '"') orelse continue;
        const q0 = std.mem.lastIndexOfScalar(u8, l[0..q1], '"') orelse continue;
        const name = l[q0 + 1 .. q1];
        const f = app.store.file(lang_archive, name) catch continue;
        if (k == 0) main.panelHeader(tx.get(tx.sc_lines));
        k += 1;
        dialogBlock(app, a, f, name, k);
    }
}

/// One dialogue file `name` (Store file `f`): its lines with their voice files, the
/// recordings no line plays; `k` keeps the element ids apart.
fn dialogBlock(app: *App, a: Allocator, f: usize, name: []const u8, k: u32) void {
    clay.open(.{ .layout = .{ .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    txt(name, 14, theme.text, font_mod.bold);
    if (main.button(app, std.fmt.allocPrint(a, "dlg_code{d}", .{k}) catch "d", tx.get(tx.sc_edit_lines), false)) codeview.open(app, f, null);
    clay.close();
    const utf8 = code.fromGame(a, app.store.text(f), app.catalog.cyrillic) catch return;
    const dlg = og.formats.dialog.parse(a, utf8) catch return;
    // Voice files: the lines' own, and the dialogue's no line names (left over from
    // a shift, or not yet given to a line).
    var used: std.ArrayList([]const u8) = .empty;
    for (dlg.lines, 0..) |ln, n| {
        var vb: [64]u8 = undefined;
        const vn = a.dupe(u8, og.formats.dialog.voiceName(&vb, name, ln.code, n) catch "") catch "";
        used.append(a, vn) catch {};
        // The line typed in place: who says it, what; moved, added after, deleted.
        if (lineRow(app, a, f, name, k, n, ln.speaker, ln.text)) return;
        voiceRow(app, a, vn, k * 1000 + @as(u32, @intCast(n)), stemOf(name, a));
    }
    const all = voices.names(app, a, stemOf(name, a));
    var spare: usize = 0;
    for (all) |vn| {
        for (used.items) |u| {
            if (std.ascii.eqlIgnoreCase(u, vn)) break;
        } else {
            if (spare == 0) txt(tx.get(tx.vo_spare), 12, theme.warn, font_mod.bold);
            spare += 1;
            clay.open(.{ .layout = .{ .childGap = 8, .padding = .{ .left = 16 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
            txt(vn, 12, theme.dim, font_mod.regular);
            if (main.button(app, std.fmt.allocPrint(a, "vs_play{d}_{d}", .{ k, spare }) catch "v", tx.get(tx.vo_play), false)) voices.play(app, vn);
            if (main.button(app, std.fmt.allocPrint(a, "vs_del{d}_{d}", .{ k, spare }) catch "v", tx.get(tx.vo_remove), false)) app.askDelete(.voice, 0, vn);
            clay.close();
        }
    }
}

/// Line `n` of dialogue file `f`: its number (DIALOG_DISPLAY's), speaker and text fields,
/// up, down, a new line after it, delete. True when it changed the file (the caller stops
/// drawing the old lines).
fn lineRow(app: *App, a: Allocator, f: usize, name: []const u8, k: u32, n: usize, speaker: []const u8, text: []const u8) bool {
    const dlgedit = @import("dlgedit.zig");
    const textedit = @import("textedit.zig");
    const id = k * 1000 + @as(u32, @intCast(n));
    var op: ?dlgedit.Op = null;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_TOP } } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(28) }, .padding = .{ .top = 7 } } });
    txt(std.fmt.allocPrint(a, "{d}.", .{n}) catch "", 13, theme.dim, font_mod.regular);
    clay.close();
    if (textedit.field(app, std.fmt.allocPrint(a, "dl_sp{d}", .{id}) catch "s", speaker, 130, "")) |v| {
        if (!std.mem.eql(u8, v, speaker)) op = .{ .speaker = v };
    }
    if (textedit.field(app, std.fmt.allocPrint(a, "dl_tx{d}", .{id}) catch "t", text, 0, "")) |v| {
        if (!std.mem.eql(u8, v, text)) op = .{ .text = v };
    }
    if (main.toolButton(app, std.fmt.allocPrint(a, "dl_up{d}", .{id}) catch "u", .chevron_down, "", false, false)) op = .down;
    if (main.toolButton(app, std.fmt.allocPrint(a, "dl_add{d}", .{id}) catch "p", .plus, "", false, false)) op = .add_after;
    if (main.toolButton(app, std.fmt.allocPrint(a, "dl_del{d}", .{id}) catch "d", .trash_2, "", false, false)) op = .delete;
    clay.close();
    const o = op orelse return false;
    dlgedit.apply(app, f, name, n, o) catch |err| app.setStatus(tx.st_set_failed, .{err});
    return true;
}

/// The voice file prefix of dialogue `dlg` (`port-arriving.dlg` → `port_arriving_`).
fn stemOf(dlg: []const u8, a: Allocator) []const u8 {
    const stem = if (std.ascii.endsWithIgnoreCase(dlg, ".dlg")) dlg[0 .. dlg.len - 4] else dlg;
    const out = a.alloc(u8, stem.len + 1) catch return "";
    for (stem, 0..) |ch, i| out[i] = if (ch == '-') '_' else std.ascii.toLower(ch);
    out[stem.len] = '_';
    return out;
}

/// Under a line: its voice file, there or not; listen, a file of one's own, out to a
/// file, or one of the dialogue's recordings given to it (the chooser).
fn voiceRow(app: *App, a: Allocator, vn: []const u8, id: u32, prefix: []const u8) void {
    const there = voices.has(app, vn);
    clay.open(.{ .layout = .{ .childGap = 8, .padding = .{ .left = 16, .bottom = 4 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    txt(vn, 12, if (there) theme.dim else theme.warn, font_mod.regular);
    if (!there) txt(tx.get(tx.vo_missing), 12, theme.warn, font_mod.bold);
    if (there) if (main.button(app, std.fmt.allocPrint(a, "vo_play{d}", .{id}) catch "v", tx.get(tx.vo_play), false)) voices.play(app, vn);
    if (main.button(app, std.fmt.allocPrint(a, "vo_set{d}", .{id}) catch "v", tx.get(tx.vo_replace), false)) {
        app.voice_for.set(vn);
        app.askFile(.{ .kind = .sound, .run = voices.onVoiceIn });
    }
    if (there) if (main.button(app, std.fmt.allocPrint(a, "vo_out{d}", .{id}) catch "v", tx.get(tx.vo_export), false)) {
        app.voice_for.set(vn);
        app.askFile(.{ .kind = .wav_out, .run = voices.onVoiceOut });
    };
    const open = app.voice_choosing and std.ascii.eqlIgnoreCase(app.voice_for.get(), vn);
    if (main.button(app, std.fmt.allocPrint(a, "vo_pick{d}", .{id}) catch "v", tx.get(tx.vo_pick), open)) {
        app.voice_choosing = !open;
        app.voice_for.set(vn);
    }
    clay.close();
    if (!open) return;
    // The chooser: every recording of this dialogue.
    for (voices.names(app, a, prefix), 0..) |cand, j| {
        if (std.ascii.eqlIgnoreCase(cand, vn)) continue;
        clay.open(.{ .layout = .{ .childGap = 8, .padding = .{ .left = 32 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
        txt(cand, 12, theme.text, font_mod.regular);
        if (main.button(app, std.fmt.allocPrint(a, "vc_play{d}_{d}", .{ id, j }) catch "v", tx.get(tx.vo_play), false)) voices.play(app, cand);
        if (main.button(app, std.fmt.allocPrint(a, "vc_take{d}_{d}", .{ id, j }) catch "v", tx.get(tx.vo_take), true)) {
            app.voice_choosing = false;
            if (voices.copyTo(app, cand, vn)) app.setStatus(tx.st_voice_set, .{vn}) else |err| app.setStatus(tx.st_set_failed, .{err});
        }
        clay.close();
    }
}

const lang_archive = "common/lang.dat";

/// A script place as a card: where (`title`), its block and the button turning it
/// off (`off`) or on again.
pub fn card(app: *App, a: Allocator, file: usize, level: []const u8, title: []const u8, call: scenes.Call, id: u32, off: tx.Msg) void {
    const text = app.store.text(file);
    const span = if (call.state == .off) scenes.offRun(text, call.at) else scenes.block(text, call.at);
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fit() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 }, .childGap = 4 },
        .backgroundColor = theme.panel,
        .border = .{ .color = if (call.state == .off) theme.warn else theme.line, .width = .{ .left = 3 } },
    });
    clay.open(.{ .layout = .{ .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    txt(title, 14, theme.text, font_mod.bold);
    if (main.button(app, std.fmt.allocPrint(a, "trig_code{d}", .{id}) catch "c", tx.get(tx.code_in_editor), false)) codeview.open(app, file, call.at);
    switch (call.state) {
        .game_off => txt(tx.get(tx.sc_game_off), 12, theme.dim, font_mod.regular),
        .on => if (!scenes.safe(text, call.at)) {
            txt(tx.get(tx.sc_unsafe), 12, theme.warn, font_mod.regular);
        } else if (main.button(app, std.fmt.allocPrint(a, "trig_off{d}", .{id}) catch "t", tx.get(off), false)) change(app, file, scenes.turnOff(app.gpa, text, span)),
        .off => if (main.button(app, std.fmt.allocPrint(a, "trig_on{d}", .{id}) catch "t", tx.get(tx.sc_turn_on), true)) change(app, file, scenes.turnOn(app.gpa, text, call.at)),
    }
    clay.close();
    // Links: the area whose entering runs this block, the scenes it starts.
    clay.open(.{ .layout = .{ .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    if (scenes.areaOf(a, text, call.at)) |ar| if (main.button(app, std.fmt.allocPrint(a, "lnk_area{d}", .{id}) catch "l", tx.alloc(a, tx.ln_area, .{ ar, level }), false)) app.link(false, level, ar);
    for (scenes.startedIn(a, text, call.at), 0..) |sc, k| {
        if (app.sceneName()) |cur| if (app.tab == .scenes and std.ascii.eqlIgnoreCase(cur, sc)) continue;
        if (main.button(app, std.fmt.allocPrint(a, "lnk_scene{d}_{d}", .{ id, k }) catch "l", tx.alloc(a, tx.ln_scene, .{sc}), false)) app.link(true, sc, null);
    }
    clay.close();
    // The lines turning it off takes (or took) out.
    var lines = std.mem.splitScalar(u8, text[span.start..span.end], '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, " \t\r");
        if (l.len == 0) continue;
        txt(l, 12, if (call.state == .off) theme.dim else theme.text, font_mod.regular);
    }
    clay.close();
}

fn change(app: *App, file: usize, r: anyerror![]u8) void {
    const t = r catch |err| return app.setStatus(tx.st_set_failed, .{err});
    app.store.replace(file, t) catch |err| {
        app.gpa.free(t);
        app.setStatus(tx.st_set_failed, .{err});
    };
}

fn toggleSkip(app: *App, f: usize, on: bool) void {
    const text = app.store.text(f);
    change(app, f, if (on) scenes.unshorten(app.gpa, text) else scenes.shorten(app.gpa, text));
}

/// CLI `--scene-skip NAME` / `--scene-off NAME` (every start that is on).
pub fn scripted(app: *App, a: Allocator, skip: bool, name: []const u8) !void {
    if (skip) {
        const f = sceneFile(app, name) orelse return error.NoSuchScene;
        if (!skipped(app, name)) toggleSkip(app, f, false);
        return;
    }
    for (app.catalog.scene_files.items) |sfile| {
        const fi = app.store.file(sfile.archive, sfile.entry) catch continue;
        while (true) {
            const cs = try scenes.calls(a, app.store.text(fi), name);
            const call = for (cs) |cl| {
                if (cl.state == .on and scenes.safe(app.store.text(fi), cl.at)) break cl;
            } else break;
            change(app, fi, scenes.turnOff(app.gpa, app.store.text(fi), scenes.block(app.store.text(fi), call.at)));
        }
    }
}

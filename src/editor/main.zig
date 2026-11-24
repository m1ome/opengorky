//! opengorky-editor: level editor working directly on a game folder. A Classic folder's
//! `.dat` archives are rewritten on save (work on a copy); an OpenGorky project of OG
//! Script opens read-only (App.ogLayout).
//!   opengorky-editor <game dir> [--level NAME] [edits]... [--save] [--shot out.png] [--size WxH] [--lowdpi]
//!   --lowdpi: a window of pixel density 1 (as Linux/Windows without HiDPI) on a HiDPI screen.
//!   edits: the scripted ops (scripted.zig `ops`; an unknown option prints them all).
//! The centre shows one document kind per tab (kinds.zig: levels, entities, scenes, media,
//! rules, history, settings…), opened from the asset tree; Ctrl+Z undoes, Ctrl+S saves
//! (the shown tab's edits; in the code view every tab's).
//! The edits and `--save` apply edits without the mouse (checks and scripts).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const render = @import("render.zig");
const font_mod = @import("font.zig");
const Font = font_mod.Font;
const level = @import("level.zig");
const tx = @import("text.zig");
const Settings = @import("settings.zig").Settings;
const config = @import("config");
const catalog = @import("catalog.zig");
const boxpanel = @import("boxpanel.zig");
const paint = @import("paint.zig");
const paint_panel = @import("paint_panel.zig");
const search = @import("search.zig");
const triggerpanel = @import("triggerpanel.zig");
const checkpanel = @import("checkpanel.zig");
const assettree = @import("assettree.zig");
const icons = @import("icons.zig");
const doctabs = @import("doctabs.zig");
const kinds = @import("kinds.zig");
const scripted = @import("scripted.zig");
const treemenu = @import("treemenu.zig");
const textedit = @import("textedit.zig");
const levelanims = @import("levelanims.zig");
const logicview = @import("logicview.zig");
const paths = @import("paths.zig");
const codeview = @import("codeview.zig");
const history = @import("history.zig");
const levelpanel = @import("levelpanel.zig");
const viewport = @import("viewport.zig");
const events = @import("events.zig");
const kit = @import("kit.zig");
const project_mod = @import("project.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const levelops = @import("levelops.zig");
const Tab = app_mod.Tab;
const Menu = app_mod.Menu;
const theme = app_mod.theme;
const enemyTitle = app_mod.enemyTitle;

fn layout(app: *App) void {
    const a = app.frame.allocator();
    clay.open(.{
        .id = clay.id("root"),
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM },
        .backgroundColor = theme.bg,
    });
    {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } } });
        assettree.panel(app, a);
        app.splitter(.levels, false, 1, 0);
        // The centre: the open documents' tabs over the one shown.
        doctabs.sync(app);
        // Code open: it is the centre's document (over the tab's own).
        const level_tab = app.levelShown();
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
        doctabs.bar(app, a);
        if (level_tab) if (app.doc) |d| levelpanel.levelToolbar(app, a, d);
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } }, .backgroundColor = theme.panel });
        if (app.code) |v| codeview.page(app, a, v) else if (kinds.of(app.tab).page) |pg| pg(app, a) else clay.leaf(.{
            .id = clay.id("viewport"),
            .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } },
            .backgroundColor = theme.viewport,
            .custom = .{ .customData = app },
        });
        clay.close();
        if (level_tab and app.paint == null) if (logicview.of(app)) |v| logicview.strip(app, a, v);
        clay.close();
        // The level's inspector beside the centre, top to bottom; none without a level.
        if (level_tab and app.doc != null) {
            // The view mode's constructor is a page's (gui.propsPanel, its splitter its own).
            if (app.paint == null and logicview.of(app) == null) levelpanel.objectList(app, a) else app.splitter(.objects, false, -1, 0);
            if (app.paint) |p| paint_panel.panel(app, a, p) else if (logicview.of(app)) |v| levelpanel.logicPanel(app, a, v);
        }
        clay.close();
        statusBar(app, a);
        if (app.menu) |m| menu(app, a, m);
        treemenu.draw(app, a);
        if (app.confirm) |*cf| confirmWindow(app, cf);
        if (app.alert) |al| alertWindow(app, al.title, al.text);
        if (app.proj_convert) |w| @import("projconvert.zig").window(app, a, w);
        if (app.box) |b| boxpanel.panel(app, a, b);
        if (app.trigger) |t| triggerpanel.panel(app, a, t);
        if (app.check) |r| if (r.shown) checkpanel.panel(app, a, r);
    }
    clay.close();
}

/// A row opening submenu `which` beside it on hover; the submenu follows (caller closes
/// it with `clay.close()` twice) when open.
fn subRow(app: *App, id: []const u8, ic: icons.Icon, label: []const u8, which: @TypeOf(@as(Menu, undefined).open), w: f32) bool {
    const rid = clay.id(id);
    const m = &app.menu.?;
    // Another submenu opens after a short rest on its row (or a click), so the pointer
    // can cross rows on its way into the open one.
    if (clay.pointerOver(rid) and m.open != which) {
        const now = c.SDL_GetTicks();
        if (m.hover != which) {
            m.hover = which;
            m.hover_since = now;
        }
        if (app.clicked or m.open == .none or now - m.hover_since >= 300) m.open = which;
    }
    const open = m.open == which;
    gui.submenuRow(app, rid, ic, label, open);
    if (!open) {
        clay.close();
        return false;
    }
    gui.submenuPanel(clay.idi("submenu", @backingInt(which)), w);
    return true;
}

/// Right-click menu, one for locations and battles: on an object what can be done with
/// it; on the floor what can be added there, paste and centring.
fn menu(app: *App, a: Allocator, m: Menu) void {
    const d = app.doc orelse return;
    gui.menuPanel(clay.id("menu"), lay.width.menu, .{ .offset = .{ .x = m.at[0], .y = m.at[1] }, .zIndex = 100, .attachTo = ui.CLAY_ATTACH_TO_ROOT });
    if (m.obj) |i| if (i < d.objects.items.len) {
        objectMenu(app, a, d, i);
        clay.close();
        return;
    };
    if (d.isBattle()) {
        if (m.grid) |g| gui.menuTitle(a, tx.alloc(a, tx.menu_add_at, .{ @as(i32, @intFromFloat(@floor(g[0]))), @as(i32, @intFromFloat(@floor(g[1]))) }), "") else gui.menuTitle(a, tx.get(tx.cm_canvas), "");
    } else gui.menuTitle(a, tx.get(tx.cm_canvas), "");
    gui.menuLine();
    const g = m.grid;
    if (subRow(app, "menu_add", .box, tx.get(tx.cm_add_object), .add, lay.width.menu)) {
        if (d.isBattle()) {
            if (g) |gp| {
                if (gui.menuRow(app, "menu_add_box", .box, tx.get(tx.cm_container), "", theme.text, true)) app.addObstacle(.box, gp);
                const obs = [_]struct { level.Obstacle, tx.Msg }{ .{ .wcrate, tx.ob_wcrate }, .{ .mcrate, tx.ob_mcrate }, .{ .barrel, tx.ob_barrel } };
                for (obs) |k| if (gui.menuRow(app, @tagName(k[0]), .package, tx.get(k[1]), "", theme.text, true)) app.addObstacle(k[0], gp);
                gui.menuLine();
                const props = [_]struct { level.Prop, tx.Msg }{
                    .{ .barrier, tx.pr_barrier }, .{ .pipe, tx.pr_pipe },     .{ .logs, tx.pr_logs },       .{ .fcrate, tx.pr_fcrate },
                    .{ .bathtub, tx.pr_bathtub }, .{ .corpse, tx.pr_corpse }, .{ .automat, tx.pr_automat },
                };
                for (props) |k| if (gui.menuRow(app, @tagName(k[0]), .image, tx.get(k[1]), "", theme.text, true)) app.addProp(k[0], gp);
            } else gui.menuNote(tx.get(tx.st_no_tile));
        } else if (gui.menuRow(app, "menu_box", .box, tx.get(tx.cm_container), "", theme.text, true)) app.addBox(m.bg);
        clay.close();
        clay.close();
    }
    if (!d.isBattle()) if (subRow(app, "menu_model", .box, tx.get(tx.cm_add_model), .model, lay.width.menu)) {
        modelChoice(app, a, m.bg);
        clay.close();
        clay.close();
    };
    if (d.isBattle()) {
        if (g) |gp| {
            if (subRow(app, "menu_enemy", .user, tx.get(tx.menu_add_enemy), .enemy, lay.width.menu)) {
                enemyChoice(app, a, gp);
                clay.close();
                clay.close();
            }
            if (subRow(app, "menu_own", .user, tx.get(tx.menu_add_own), .own, lay.width.menu)) {
                ownChoice(app, a, d, gp);
                clay.close();
                clay.close();
            }
        }
    } else {
        if (subRow(app, "menu_hero", .user, tx.get(tx.menu_add_hero), .hero, lay.width.menu)) {
            heroChoice(app, a, d, m.bg);
            clay.close();
            clay.close();
        }
        if (gui.menuRow(app, "menu_trigger_new", .square_dashed, tx.get(tx.cm_add_trigger), "", theme.text, true)) levelpanel.paintTool(app, .area);
        if (gui.menuRow(app, "menu_exit_new", .log_out, tx.get(tx.cm_add_exit), "", theme.text, true)) levelpanel.paintTool(app, .exit);
    }
    gui.menuLine();
    if (gui.menuRow(app, "menu_paste", .copy, tx.get(tx.cm_paste), cmdKey(a, "V"), theme.text, app.clip != null)) app.paste(m.bg, g);
    if (gui.menuRow(app, "menu_center", .crosshair, tx.get(tx.cm_center), "", theme.text, true)) app.centreOn(m.bg);
    clay.close();
}

/// The confirmation window: what will be deleted, Delete (Enter) or Cancel (Esc).
/// `cf` by pointer: its text is drawn after this returns (a copy would be gone).
fn confirmWindow(app: *App, cf: *const app_mod.Confirm) void {
    // Over a dimmed editor (clicks outside cancel).
    _ = gui.modal(app, "confirm", .{ .w = lay.width.dialog, .title = tx.get(tx.cf_title), .icon = .trash_2, .icon_color = theme.warn, .close = false, .shade = true });
    gui.modalBody(lay.space.md);
    gui.txtWrap(cf.text(), .body, theme.text, font_mod.regular);
    gui.note(tx.get(tx.cf_undo));
    gui.row(lay.space.sm);
    gui.spacer();
    if (gui.toolButton(app, "confirm_no", .x, tx.get(tx.cancel), false, false)) app.confirm = null;
    if (gui.toolButton(app, "confirm_yes", .trash_2, tx.get(tx.cm_delete), false, true)) app.confirmed();
    clay.close();
    clay.close();
    clay.close();
}

/// A refusal (`App.setAlert`): its text and Close (Enter, Esc, a click outside).
fn alertWindow(app: *App, title: []const u8, text: []const u8) void {
    _ = gui.modal(app, "alert", .{ .w = lay.width.dialog, .title = title, .icon = .box, .icon_color = theme.warn, .close = false, .shade = true });
    gui.modalBody(lay.space.md);
    gui.txtWrap(text, .body, theme.text, font_mod.regular);
    gui.row(lay.space.sm);
    gui.spacer();
    if (gui.toolButton(app, "alert_ok", .check, tx.get(tx.close), false, true)) app.alert = null;
    clay.close();
    clay.close();
    clay.close();
}

/// `Cmd X` on macOS, `Ctrl+X` elsewhere.
pub fn cmdKey(a: Allocator, k: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}{s}", .{ if (@import("builtin").os.tag == .macos) "Cmd " else "Ctrl+", k }) catch k;
}

fn objectMenu(app: *App, a: Allocator, d: *level.Doc, i: usize) void {
    const o = d.objects.items[i];
    gui.menuTitle(a, o.name, levelpanel.kindName(d, o));
    gui.menuLine();
    if (d.boxFile(o.name) != null) if (gui.menuRow(app, "menu_contents", .box, tx.get(tx.cm_edit_contents), "Enter", theme.text, true)) {
        app.selected = i;
        _ = app.openBox(o.name);
    };
    if (o.kind == .area and gui.menuRow(app, "menu_trigger", .square_dashed, tx.get(tx.menu_trigger), "", theme.text, true)) app.trigger = o.name;
    // What it is one of (its class: the enemy, the item; the hero), in a tab of its own.
    if (levelpanel.entryOfObject(app, d, o)) |ei| {
        const e = app.catalog.entries.items[ei];
        if (gui.menuRow(app, "menu_entry", .user, tx.alloc(a, tx.cm_open_entry, .{if (e.title.len > 0) e.title else e.id}), "", theme.text, true)) {
            doctabs.openKept(app, kinds.tabOf(e.kind), @import("entries.zig").keyOf(a, e) orelse "");
            app.menu = null;
        }
    }
    // Its placement call in the level script, or its own script.
    // (A file added here and not saved yet is the object's own.)
    const own: ?usize = o.file orelse if (levelpanel.scriptOf(d, o.name)) |entry| app.store.file(d.level_archive, entry) catch null else null;
    if (gui.menuRow(app, "menu_code", .code, tx.get(tx.cm_reveal), "", theme.text, o.call != null or own != null)) {
        if (o.call) |ci| doctabs.showCode(app, d.lev, d.script.calls[ci].stmt.start) else if (own) |f| doctabs.showCode(app, f, null);
    }
    if (subRow(app, "menu_refs", .search, tx.get(tx.cm_refs), .refs, lay.width.dialog)) {
        if (app.menu_refs.items.len == 0) gui.menuNote(tx.get(tx.cm_no_refs));
        for (app.menu_refs.items, 0..) |r, k| if (gui.menuRow(app, std.fmt.allocPrint(a, "menu_ref{d}", .{k}) catch "r", .file_text, r.label, "", theme.text, true)) {
            if (app.store.file(r.path, r.entry)) |f| doctabs.showCode(app, f, r.at) else |_| {}
        };
        clay.close();
        clay.close();
    }
    if (d.facing(i)) |deg| {
        if (gui.menuRow(app, "menu_turn_left", .undo_2, tx.alloc(a, tx.menu_turn, .{ @as(i32, @intFromFloat(deg)), "-45" }), "", theme.text, true)) d.rotate(i, -45) catch |err| app.setStatus(tx.st_move_failed, .{err});
        if (gui.menuRow(app, "menu_turn_right", .redo_2, tx.alloc(a, tx.menu_turn, .{ @as(i32, @intFromFloat(deg)), "+45" }), "", theme.text, true)) d.rotate(i, 45) catch |err| app.setStatus(tx.st_move_failed, .{err});
    }
    if (d.canWalkIn(i)) |walks| if (gui.menuRow(app, "menu_walk_in", .log_out, tx.get(if (walks) tx.menu_place_now else tx.menu_walk_in), "", theme.text, true)) d.toggleWalkIn(i) catch |err| app.setStatus(tx.st_move_failed, .{err});
    gui.menuLine();
    if (gui.menuRow(app, "menu_dup", .copy, tx.get(tx.cm_duplicate), cmdKey(a, "D"), theme.text, o.call != null or d.boxFile(o.name) != null)) app.duplicate(i);
    if (gui.menuRow(app, "menu_copy", .copy, tx.get(tx.cm_copy), cmdKey(a, "C"), theme.text, true)) app.copyObject(i);
    if (gui.menuRow(app, "menu_rename", .pencil, tx.get(tx.cm_rename), "F2", theme.text, o.kind == .area)) levelpanel.renameArea(app, o.name);
    if (gui.menuRow(app, "menu_focus", .crosshair, tx.get(tx.cm_focus), "F", theme.text, true)) app.centreOn(o.pos);
    gui.menuLine();
    const hidden = app.view_hidden.contains(o.name);
    if (gui.menuRow(app, "menu_hide", if (hidden) .eye else .eye_off, tx.get(if (hidden) tx.cm_show else tx.cm_hide), "", theme.text, true)) app.toggleHidden(o.name);
    const locked = app.locked.contains(o.name);
    if (gui.menuRow(app, "menu_lock", if (locked) .lock_open else .lock, tx.get(if (locked) tx.cm_unlock else tx.cm_lock), "", theme.text, true)) app.toggleLocked(o.name);
    gui.menuLine();
    // Delete: a box made in the editor (its files), a hero brought in, a placed object.
    if (d.boxFile(o.name) != null and d.deletableBox(o.name) != null) {
        if (gui.menuRow(app, "menu_delete_box", .trash_2, tx.get(tx.menu_delete_box), "Delete", theme.warn, true)) app.askDelete(.box, i, o.name);
    } else if (o.kind == .actor and d.deletableActor(o.name) != null) {
        // A model stood here (its `.act`): the file goes, as a box's.
        if (gui.menuRow(app, "menu_delete_act", .trash_2, tx.get(tx.cm_delete), "Delete", theme.warn, true)) app.askDelete(.box, i, o.name);
    } else if (o.kind == .hero and d.heroFile(o.name) != null) {
        if (gui.menuRow(app, "menu_hero_drop", .trash_2, tx.get(tx.menu_hero_drop), "Delete", theme.warn, true)) app.askDelete(.hero, i, o.name);
    } else if (gui.menuRow(app, "menu_remove", .trash_2, tx.get(tx.cm_delete), "Delete", theme.warn, o.call != null and o.later == null)) app.askDelete(.object, i, o.name);
}

/// The player's side to add at grid point `g`: the starting three and the heroes joining.
fn ownChoice(app: *App, a: Allocator, d: *level.Doc, g: [2]f32) void {
    var seen: std.ArrayList([]const u8) = .empty;
    for (app.catalog.entries.items, 0..) |e, k| {
        if (e.kind != .hero) continue;
        const id = e.id;
        if (std.ascii.startsWithIgnoreCase(id, "0") or std.ascii.eqlIgnoreCase(id, "girl")) continue; // level props (the singer, the monitor), not party heroes
        for (seen.items) |x| {
            if (std.ascii.eqlIgnoreCase(x, id)) break;
        } else {
            seen.append(a, id) catch {};
            const name = a.dupe(u8, id) catch continue;
            name[0] = std.ascii.toUpper(name[0]);
            var placed = false;
            for (d.script.calls) |call| placed = placed or std.ascii.eqlIgnoreCase(call.name, name);
            const label = std.fmt.allocPrint(a, "{s}{s}", .{ if (e.title.len > 0) e.title else name, if (placed) tx.get(tx.menu_own_there) else "" }) catch name;
            if (gui.menuRow(app, std.fmt.allocPrint(a, "menu_own{d}", .{k}) catch "o", .user, label, "", theme.text, !placed)) levelops.addOwn(app, name, g);
        }
    }
}

/// A submenu's long list scrolls past this height (as tall as a dialog is wide).
const list_most: ui.Clay_SizingAxis = .{ .type = ui.CLAY__SIZING_TYPE_FIT, .size = .{ .minMax = .{ .min = 0, .max = lay.width.dialog } } };

/// The game's 3D models (gfx_3d\\*.msh), with search, to stand at background point `bg`.
fn modelChoice(app: *App, a: Allocator, bg: [2]f32) void {
    gui.searchField(app, a, "window_search", &app.query_name, true, tx.get(tx.search_hint), "");
    clay.openScroll(.{ .id = clay.id("menu_models"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = list_most }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    for (app.modelNames(), 0..) |mn, k| {
        if (!search.matches(app.query(), &.{mn})) continue;
        if (gui.menuRow(app, std.fmt.allocPrint(a, "menu_mdl{d}", .{k}) catch "m", .box, mn, "", theme.text, true)) app.addActor(mn, bg);
    }
    clay.close();
}

/// Heroes joining in other levels (Medusa, Bt…), each once, to bring to background point `bg`.
fn heroChoice(app: *App, a: Allocator, d: *level.Doc, bg: [2]f32) void {
    var seen: std.ArrayList([]const u8) = .empty;
    for (app.catalog.entries.items, 0..) |e, k| {
        if (e.kind != .hero or std.mem.eql(u8, e.archive, d.level_archive) or std.mem.startsWith(u8, e.archive, "common")) continue;
        for (seen.items) |x| {
            if (std.ascii.eqlIgnoreCase(x, e.id)) break;
        } else {
            seen.append(a, e.id) catch {};
            const label = std.fmt.allocPrint(a, "{s} ({s})", .{ if (e.title.len > 0) e.title else e.id, e.archive[0 .. e.archive.len - "/other.dat".len] }) catch e.id;
            if (gui.menuRow(app, std.fmt.allocPrint(a, "menu_hero{d}", .{k}) catch "h", .user, label, "", theme.text, true)) levelops.addHero(app, k, bg);
        }
    }
}

/// Enemy classes to add at grid point `g`, with search.
fn enemyChoice(app: *App, a: Allocator, g: [2]f32) void {
    gui.searchField(app, a, "window_search", &app.query_name, true, tx.get(tx.search_hint), "");
    clay.openScroll(.{ .id = clay.id("menu_list"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = list_most }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    for (app.allTemplates(a), 0..) |t, i| {
        const title = enemyTitle(app, t.class);
        if (!search.matches(app.query(), &.{ t.class, title })) continue;
        const rid = clay.idi("menu_tpl", @intCast(i));
        if (gui.listRow(app, rid, .{ .indent = lay.space.md, .h = lay.height.small, .rounded = false })) {
            app.menu = null;
            app.addEnemy(t, g);
        }
        if (title.len > 0) gui.txt(title, .label, theme.text, font_mod.regular);
        gui.txt(t.class, if (title.len > 0) .caption else .label, if (title.len > 0) theme.dim else theme.text, font_mod.regular);
        if (t.base != null) gui.txt(tx.get(tx.new), .caption, theme.accent_hover, font_mod.regular);
        if (t.weapon != null) gui.txt(tx.get(tx.built), .caption, theme.warn, font_mod.regular);
        clay.close();
    }
    clay.close();
}

/// The status bar: what happened last (or what to do), the project on the right.
fn statusBar(app: *App, a: Allocator) void {
    clay.open(.{
        // Not clipped: its texts give way (txtClip) instead of the icons on the right.
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(lay.height.control) }, .padding = gui.pad(lay.space.md, 0), .childGap = lay.space.md, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = theme.bg,
        .border = .{ .color = theme.line, .width = .{ .top = lay.border.line } },
    });
    if (app.store.dirty()) {
        gui.dot(theme.warn);
        gui.txt(tx.get(tx.unsaved), .caption, theme.warn, font_mod.regular);
    } else {
        gui.dot(theme.ok);
        gui.txt(tx.get(tx.sb_saved), .caption, theme.dim, font_mod.regular);
    }
    // The message and the mouse hint give way first (cut), the icons on the right stay.
    gui.txtClip(if (app.status.len > 0) app.status else if (app.levelShown()) tx.get(tx.pick_level) else "", .caption, theme.dim, font_mod.regular);
    // The mod check of the last save: its problems open the window again.
    if (app.check) |r| if (r.failed != null or r.problems.len > 0) {
        if (gui.link(app, clay.id("check_status"), if (r.build) tx.alloc(a, tx.bd_title, .{r.problems.len}) else tx.alloc(a, tx.sb_problems, .{r.problems.len}), theme.warn, theme.accent_hover)) r.shown = true;
    };
    // An import converting: Cancel beside its progress.
    if (app.convert != null and gui.link(app, clay.id("convert_cancel"), tx.get(tx.cancel), theme.accent, theme.accent_hover)) @import("convert.zig").cancel(app);
    gui.spacer();
    // A level: what the mouse does now, where it is on the background, the zoom.
    if (app.levelShown()) if (app.doc) |d| {
        const mouse_hint: tx.Msg = if (app.paint) |p| switch (p.tool) {
            .objects => tx.sb_objects,
            .move => tx.sb_hand,
            .brush, .picker => tx.sb_brush,
            .light => tx.sb_light,
            .area, .exit => tx.sb_area,
            .points => tx.sb_points,
            .paths => tx.sb_paths,
            .camera => tx.sb_camera,
        } else tx.sb_view;
        gui.txtClip(tx.get(mouse_hint), .caption, theme.dim, font_mod.regular);
        if (App.viewportRect()) |v| if (app.overViewport()) {
            const b = d.toBackground(v, app.mouse);
            gui.txt(tx.alloc(a, tx.sb_pos, .{ @as(i32, @intFromFloat(b[0])), @as(i32, @intFromFloat(b[1])) }), .caption, theme.dim, font_mod.regular);
        };
        gui.txt(tx.alloc(a, tx.sb_zoom, .{d.zoom * 100}), .caption, theme.dim, font_mod.regular);
        gui.txt(std.fmt.allocPrint(a, "{d}×{d}", .{ @as(u32, @intFromFloat(d.bg_size[0])), @as(u32, @intFromFloat(d.bg_size[1])) }) catch "", .caption, theme.dim, font_mod.regular);
    };
    if (app.game_dir.len > 0) {
        const folder = std.fs.path.basename(app.game_dir);
        // What the folder is: the original's archives or an OpenGorky project.
        if (app.project.format == .ogs) {
            const t = app.project.title();
            gui.chipOf(tx.alloc(a, tx.sb_mode_og, .{if (t.len > 0) t else folder}), theme.accent_hover, theme.accent);
        } else gui.chipOf(tx.get(tx.sb_mode_classic), theme.text, theme.button_edge);
        gui.txt(folder, .caption, theme.dim, font_mod.regular);
    }
    gui.txt("OpenGorky Editor", .caption, theme.dim, font_mod.regular);
    if (gui.iconButton(app, clay.id("history"), .history, doctabs.isShown(app, .history, ""))) doctabs.show(app, .history, "");
    if (gui.iconButton(app, clay.id("settings"), .settings, doctabs.isShown(app, .settings, ""))) doctabs.show(app, .settings, "");
    clay.close();
}

pub fn frame(app: *App, size: [2]f32, wheel: [2]f32) clay.Commands {
    _ = app.frame.reset(.retain_capacity);
    @import("model_og.zig").release();
    // The window as it is now (resized, full screen): the confirmation's shade covers it.
    app.size = size;
    @import("convert.zig").poll(app);
    @import("projconvert.zig").poll(app);
    // The rules in force follow every change of the rules files (an edit, Apply, undo).
    @import("entry_rules.zig").sync(app);
    if (app.paint) |p| paint.runPending(app, p);
    app.followLink();
    if (app.hero_drop.len > 0) {
        var nb: [48]u8 = undefined;
        const n = nb[0..app.hero_drop.len];
        @memcpy(n, app.hero_drop.get());
        app.hero_drop.len = 0;
        levelops.removeHero(app, n);
    }
    if (app.level_make) {
        app.level_make = false;
        levelops.newLevel(app, app.level_name.get());
    }
    if (app.stale_catalog) |*old| {
        old.deinit();
        app.stale_catalog = null;
    }
    if (app.tab_close) |k| {
        app.tab_close = null;
        doctabs.close(app, k, !app.tab_close_quiet);
        app.tab_close_quiet = false;
    }
    if (app.history_go) {
        app.history_go = false;
        history.historyGo(app);
    }
    app.dragSplit();
    if (app.clicked and clay.pointerOver(clay.id("preview_img")) and !clay.pointerOver(clay.id("preview_bar"))) app.turning = app.mouse;
    // The menu and the box window take clicks on them; one elsewhere only closes them.
    // The conversion's window is answered (its shade takes clicks elsewhere).
    if (app.proj_convert != null and app.clicked and !clay.pointerOver(clay.id("projconvert"))) app.clicked = false;
    if (app.alert != null and app.clicked and !clay.pointerOver(clay.id("alert"))) {
        app.alert = null;
        app.clicked = false;
    }
    if (app.confirm != null and app.clicked and !clay.pointerOver(clay.id("confirm"))) {
        app.confirm = null;
        app.clicked = false;
    }
    if (app.code) |v| if (v.menu != null and app.clicked and !clay.pointerOver(clay.id("code_menu"))) {
        v.menu = null;
        app.clicked = false;
    };
    if (app.tree_menu != null and (app.clicked or app.right_clicked) and !clay.pointerOver(clay.id("tree_menu"))) {
        app.tree_menu = null;
        app.clicked = false;
    }
    // Its submenu floats outside the menu's box: a click there is the menu's too.
    if (app.menu) |m| if (app.clicked and !clay.pointerOver(clay.id("menu")) and !clay.pointerOver(clay.idi("submenu", @backingInt(m.open)))) {
        app.menu = null;
        app.clicked = false;
    };
    if (app.box != null and app.clicked and !clay.pointerOver(clay.id("boxpanel"))) {
        app.box = null;
        app.clicked = false;
    }
    if (app.trigger != null and app.clicked and !clay.pointerOver(clay.id("triggerpanel"))) {
        app.trigger = null;
        app.clicked = false;
    }
    // Viewport input by last frame's layout: wheel zooms; a press on an editable
    // object starts moving it, elsewhere selects/pans.
    var ui_wheel = wheel;
    // Over the tab strip the wheel scrolls it sideways.
    if (clay.pointerOver(clay.id("doc_tabs")) and wheel[0] == 0) ui_wheel = .{ wheel[1], 0 };
    if (clay.pointerOver(clay.id("preview_img")) and wheel[1] != 0) {
        app.preview.zoom = std.math.clamp(app.preview.zoom * std.math.pow(f32, 1.15, wheel[1]), 0.25, 8);
        ui_wheel = .{ 0, 0 };
    }
    if (app.levelShown() and !app.modal()) if (app.doc) |d| if (App.viewportRect()) |v| if (app.overViewport()) viewport: {
        const cam_wheel = if (app.paint) |p| p.tool == .camera and wheel[1] != 0 and paint.cameraWheel(p, d, v, app.mouse, wheel[1], (c.SDL_GetModState() & c.SDL_KMOD_SHIFT) != 0) else false;
        if (wheel[1] != 0 and !cam_wheel) d.zoomAt(v, app.mouse, std.math.pow(f32, 1.15, wheel[1]));
        ui_wheel = .{ 0, 0 };
        // The preview: nothing to pick, a drag moves the picture.
        if (app.paint == null and app.rendered.on) {
            if (app.clicked) app.pan = app.mouse;
            break :viewport;
        }
        // The level edit mode: the left button paints, nothing is picked (the Objects
        // tool: as below, with moving).
        if (app.paint) |p| if (p.tool != .objects) {
            // The hand (default): a drag moves the map; brush and eyedropper paint.
            if (app.clicked) switch (p.tool) {
                // On an area: picked and dragged; elsewhere the map moves.
                .move => if (!paint.pickAt(p, d, v, app.mouse)) {
                    app.pan = app.mouse;
                },
                .area, .exit => paint.areaClick(app, p, d, d.toBackground(v, app.mouse)),
                .points => paint.pointClick(app, d.toBackground(v, app.mouse)),
                .paths => paths.press(app, d, v, app.mouse),
                .light => paint.lightPress(app, p, d, d.toBackground(v, app.mouse)),
                .camera => if (!paint.cameraPress(p, v, app.mouse)) {
                    app.pan = app.mouse;
                },
                else => paint.press(app, p, d.toBackground(v, app.mouse)),
            };
            break :viewport;
        };
        // The view mode only picks (and pans); editing is the edit mode's Objects tool.
        const edit = app.editingObjects();
        // A selected prop's turn handles first.
        const turn: ?f32 = if (app.clicked and edit) if (app.selected) |s| if (d.turnHandles(v, s)) |hs| for (hs, [_]f32{ -45, 45 }) |h, deg| {
            if (@abs(app.mouse[0] - h[0]) <= 12 and @abs(app.mouse[1] - h[1]) <= 12) break deg;
        } else null else null else null else null;
        if (turn) |deg| {
            d.rotate(app.selected.?, deg) catch |err| app.setStatus(tx.st_move_failed, .{err});
        } else if (app.clicked and levelanims.hit(app, d, v, app.mouse) != null and d.pickMarker(v, app.mouse) == null) {
            // An animation (over areas, not markers): picked, in the edit mode dragged by its frame.
            const h = levelanims.hit(app, d, v, app.mouse).?;
            app.anims.sel.set(h.name);
            app.selected = null;
            if (!app.tree_open.contains("objopen/anims")) @import("assettree.zig").toggleKey(app, "objopen/anims");
            if (!edit) break :viewport;
            const bg = d.toBackground(v, app.mouse);
            var dr: app_mod.AnimDrag = .{ .at = h.pos, .off = .{ bg[0] - h.pos[0], bg[1] - h.pos[1] } };
            dr.len = @min(h.name.len, dr.buf.len);
            @memcpy(dr.buf[0..dr.len], h.name[0..dr.len]);
            app.anims.drag = dr;
        } else if (app.clicked) {
            app.selected = d.pick(v, app.mouse);
            if (app.selected) |i| {
                const o = d.objects.items[i];
                // Battles: placed objects; locations: items with a position file.
                if (edit and app.locked.contains(o.name)) {
                    app.setStatus(tx.st_locked, .{o.name});
                } else if (edit and !d.isBattle() and o.kind == .actor and !d.actorMovable(o.name)) {
                    // Placed at an area (PlaceActor): that point moves it.
                    app.setStatus(tx.st_actor_at_area, .{o.name});
                } else if (edit and (o.call != null or (!d.isBattle() and (o.kind == .actor or (o.kind == .item and d.varFile(o.name) != null))))) {
                    app.moving = i;
                    d.drag(v, i, app.mouse);
                }
            } else app.pan = app.mouse;
        }
    };
    if (app.paint) |p| p.hover = if (app.doc) |d| if (App.viewportRect()) |v| if (app.overViewport()) d.toBackground(v, app.mouse) else null else null else null;
    // Clay scrolls 10 points per unit: about 40 per wheel notch.
    clay.begin(.{ .size = size, .mouse = app.mouse, .down = app.down, .wheel = .{ ui_wheel[0] * 4, ui_wheel[1] * 4 }, .dt = 1.0 / 60.0 });
    // A press on a scroll bar is the bar's, not the row's under it.
    if (clay.bar_pressed) app.clicked = false;
    textedit.clickAway(app);
    layout(app);
    textedit.afterLayout(app);
    app.text_given = null;
    app.applyCursor();
    return clay.end();
}

pub fn present(app: *App, cmds: clay.Commands) void {
    _ = c.SDL_SetRenderDrawColor(app.r, 0, 0, 0, 255);
    _ = c.SDL_RenderClear(app.r);
    render.draw(app.r, app.font, cmds, viewport.drawViewport, app);
}

fn shot(app: *App, path: []const u8) !void {
    const raw = c.SDL_RenderReadPixels(app.r, null) orelse return error.ReadPixels;
    defer c.SDL_DestroySurface(raw);
    const surf = c.SDL_ConvertSurface(raw, c.SDL_PIXELFORMAT_ABGR8888) orelse return error.Convert;
    defer c.SDL_DestroySurface(surf);
    var img = try og.image.Image.init(app.gpa, @intCast(surf.*.w), @intCast(surf.*.h));
    defer img.deinit(app.gpa);
    const src: [*]const u8 = @ptrCast(surf.*.pixels.?);
    const stride = img.width * 4;
    for (0..img.height) |y| @memcpy(img.pixels[y * stride ..][0..stride], src[y * @as(usize, @intCast(surf.*.pitch)) ..][0..stride]);
    var out: Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();
    try og.formats.png.write(app.gpa, &out.writer, img);
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = out.written() });
}

/// The manifest of game folder `path` when it asks a newer engine than this one.
fn tooNew(io: Io, path: []const u8) ?og.formats.manifest.Manifest {
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return null;
    defer d.close(io);
    const m = og.formats.manifest.load(io, d) catch return null;
    return if (m.supported()) null else m;
}

/// The editor's own checking allocator in a debug build: std's records 7 stack frames on
/// every allocation (a fifth of a frame's time with a level open); this one checks and
/// counts leaks without them (OPENGORKY_ALLOC_TRACES=1: std's, with the traces).
var quick_safe: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{ .stack_trace_frames = 0 });

pub fn main(init: std.process.Init) !void {
    const quick = @import("builtin").mode == .debug and init.environ_map.get("OPENGORKY_ALLOC_TRACES") == null;
    defer if (quick) {
        _ = quick_safe.deinit();
    };
    const gpa = if (quick) quick_safe.allocator() else init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var game_dir: ?[]const u8 = null;
    var start_level: ?[]const u8 = null;
    var shot_path: ?[]const u8 = null;
    var win_size: [2]c_int = .{ 1400, 880 };
    var save_after = false;
    var high_dpi: c.SDL_WindowFlags = c.SDL_WINDOW_HIGH_PIXEL_DENSITY;
    var lang_arg: ?tx.Lang = null;
    var tab_arg: ?Tab = null;
    var edits: std.ArrayList([]const []const u8) = .empty;
    defer edits.deinit(gpa);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--level") and i + 1 < args.len) {
            i += 1;
            start_level = args[i];
        } else if (std.mem.eql(u8, a, "--shot") and i + 1 < args.len) {
            i += 1;
            shot_path = args[i];
        } else if (std.mem.eql(u8, a, "--size") and i + 1 < args.len) {
            i += 1;
            var it = std.mem.splitScalar(u8, args[i], 'x');
            win_size = .{ std.fmt.parseInt(c_int, it.first(), 10) catch return error.BadSize, std.fmt.parseInt(c_int, it.next() orelse "", 10) catch return error.BadSize };
        } else if (std.mem.eql(u8, a, "--lang") and i + 1 < args.len) {
            i += 1;
            lang_arg = std.meta.stringToEnum(tx.Lang, args[i]) orelse return error.BadLanguage;
        } else if (std.mem.eql(u8, a, "--tab") and i + 1 < args.len) {
            i += 1;
            tab_arg = @import("doctab.zig").parse(args[i]) orelse return error.BadTab;
        } else if (scripted.find(a)) |o| {
            if (i + o.arity >= args.len) return scripted.fail("{s}: {d} value(s) missing", .{ a, o.arity });
            try edits.append(gpa, args[i .. i + 1 + o.arity]);
            i += o.arity;
        } else if (std.mem.eql(u8, a, "--save")) {
            save_after = true;
        } else if (std.mem.eql(u8, a, "--lowdpi")) {
            high_dpi = 0;
        } else if (std.mem.eql(u8, a, "--help")) {
            return scripted.fail("", .{});
        } else if (std.mem.startsWith(u8, a, "--")) {
            return scripted.fail("unknown option {s}", .{a});
        } else game_dir = a;
    }
    // An OpenGorky project's installed game ($OPENGORKY_GAME over its manifest's).
    og.loaders.ogs.game_env = init.environ_map.get("OPENGORKY_GAME");
    var settings: Settings = .{};
    var cfg_buf: [1024]u8 = undefined;
    const settings_path: ?[]const u8 = if (config.configDir(&cfg_buf, init.environ_map)) |d|
        std.fmt.allocPrint(init.arena.allocator(), "{s}/{s}", .{ d, @import("settings.zig").file_name }) catch null
    else
        null;
    if (settings_path) |sp| if (Io.Dir.cwd().readFileAlloc(io, sp, gpa, .limited(1 << 16))) |data| {
        defer gpa.free(data);
        settings = Settings.parse(data);
    } else |_| {};
    tx.lang = lang_arg orelse settings.lang;
    const headless = shot_path != null or edits.items.len > 0 or save_after;
    // The folder given or chosen in the settings before; none (or no dat in it) — the
    // editor opens empty and the settings ask for one. Checks and scripts need one.
    var game: ?[]const u8 = game_dir orelse settings.gamePath();
    if (game) |g| if (!og.loaders.isGameDir(io, g)) {
        game = null;
    };
    if (game == null and (edits.items.len > 0 or save_after)) {
        std.debug.print("usage: opengorky-editor [game dir] [--level NAME] [--lang en|ru] [--tab battles|locations|settings]\n" ++
            "  [--move NAME X Y | --add CLASS | --set[-class] NAME FIELD VALUE]... [--save] [--shot out.png]\n", .{});
        return error.NoGameDir;
    }

    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;
    defer c.SDL_Quit();
    var window: ?*c.SDL_Window = null;
    var renderer: ?*c.SDL_Renderer = null;
    const flags = c.SDL_WINDOW_RESIZABLE | high_dpi | (if (headless) c.SDL_WINDOW_HIDDEN else 0);
    window = c.SDL_CreateWindow(tx.get(tx.title).ptr, win_size[0], win_size[1], flags) orelse return error.SdlWindow;
    // The GPU renderer where there is a Vulkan or Metal device (the model preview and the
    // post-processing preview draw on it: viewer/gpu), else the default one (the CPU's).
    // The device is released after the renderer.
    const gpu_device = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_MSL, false, null);
    defer if (gpu_device) |d| c.SDL_DestroyGPUDevice(d);
    if (gpu_device) |d| renderer = c.SDL_CreateGPURenderer(d, window);
    if (renderer == null) renderer = c.SDL_CreateRenderer(window, null);
    if (renderer == null) {
        c.SDL_DestroyWindow(window);
        return error.SdlWindow;
    }
    // Window (and macOS Dock) icon: assets/icon-editor-256.png, embedded in the binary.
    kit.setWindowIcon(gpa, window.?, @embedFile("icon_png"));
    defer c.SDL_DestroyWindow(window);
    defer c.SDL_DestroyRenderer(renderer);
    const r = renderer.?;
    _ = c.SDL_SetRenderDrawBlendMode(r, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderVSync(r, 1);
    const density = @max(1, c.SDL_GetWindowPixelDensity(window));
    _ = c.SDL_SetRenderScale(r, density, density);
    const font = try Font.init(gpa, r, density);
    defer font.deinit(gpa);
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSize(window, &w, &h);
    try clay.init(gpa, font, @floatFromInt(w), @floatFromInt(h));
    defer clay.deinit(gpa);

    var start: Start = .{ .level = start_level, .tab = tab_arg, .edits = edits.items, .save = save_after, .shot = shot_path, .headless = headless, .remember = game_dir != null and game != null };
    var game_buf: [1024]u8 = undefined;
    while (try session(gpa, io, window.?, r, font, &settings, settings_path, game, start)) |next| {
        const n = @min(next.len, game_buf.len);
        @memcpy(game_buf[0..n], next[0..n]);
        game = game_buf[0..n];
        // A script's conversion (--convert-to) goes on in the new project: its shot taken there.
        start = if (start.headless) .{ .headless = true, .shot = start.shot, .tab = start.tab } else .{ .remember = true };
    }
}

/// The renderer and the font at the settings' UI scale (points × scale × pixel density).
fn applyScale(app: *App) void {
    const s = app.settings.ui_scale;
    if (s == app.scale_on) return;
    const d = @max(1, c.SDL_GetWindowPixelDensity(app.window)) * s;
    app.font.rebake(app.gpa, app.r, d) catch return;
    _ = c.SDL_SetRenderScale(app.r, d, d);
    app.scale_on = s;
}

/// What the first session does on start (command line); later ones only remember the folder.
const Start = struct {
    level: ?[]const u8 = null,
    tab: ?Tab = null,
    edits: []const []const []const u8 = &.{},
    save: bool = false,
    shot: ?[]const u8 = null,
    headless: bool = false,
    /// Store the folder as game_path.
    remember: bool = false,
};

/// The editor on one game folder, or on none (empty lists, only the settings work).
/// Returns the folder picked in the settings to reopen with; null on quit.
fn session(gpa: Allocator, io: Io, window: *c.SDL_Window, r: *c.SDL_Renderer, font: *Font, settings: *Settings, settings_path: ?[]const u8, asked: ?[]const u8, start: Start) !?[]const u8 {
    // A project for a newer engine isn't opened (the editor would write what it can't read).
    const too_new: ?og.formats.manifest.Manifest = if (asked) |g| tooNew(io, g) else null;
    const game = if (too_new == null) asked else null;
    var opened = try project_mod.open(io, gpa, game);
    defer if (opened.game) |*g| g.close(io);
    const dat = opened.dat();
    var level_names: std.ArrayList([]const u8) = .empty;
    defer level_names.deinit(gpa);
    for (opened.levels) |e| try level_names.append(gpa, e.name);
    var app: App = .{
        .gpa = gpa,
        .window = window,
        .io = io,
        .r = r,
        .font = font,
        .dat = dat,
        .game_dir = game orelse "",
        .project = if (opened.game) |g| g.manifest else .{},
        .levels = opened.levels,
        .templates = opened.templates,
        // An OpenGorky project: its `src/` is what the editor writes (store.og_src).
        .store = .{ .gpa = gpa, .io = io, .dat = dat, .root = if (opened.game) |g| (if (g.manifest.format == .ogs) g.root else null) else null },
        .catalog = if (opened.game != null) try catalog.Catalog.build(io, gpa, dat, level_names.items) else .{ .arena = .init(gpa) },
        .sprites = if (opened.game != null) og.formats.archive.Archive.open(io, gpa, dat, "common/sprite.dat") catch null else null,
        .frame = .init(gpa),
    };
    defer app.deinit();
    if (app.store.root != null) {
        catalog.useOg(&app.catalog, &app.store);
        app.refreshTitles();
    }
    if (opened.game != null) app.store.loadPast();
    app.settings = settings.*;
    app.settings_path = settings_path;
    defer settings.* = app.settings;
    if (game == null) app.tab = .settings;
    if (too_new) |m| app.setStatus(tx.st_engine_too_new, .{ asked.?, m.engine[0], m.engine[1] });
    @import("projconvert.zig").adopt(&app);
    // Remember a folder given on the command line or picked (not by checks and scripts).
    if (start.remember and !start.headless) if (opened.game) |g| {
        var real_buf: [1024]u8 = undefined;
        const n = g.root.realPath(io, &real_buf) catch 0;
        app.settings.setGamePath(if (n > 0) real_buf[0..n] else game.?);
        app.saveSettings();
    };

    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSize(window, &w, &h);
    applyScale(&app);
    app.size = .{ @as(f32, @floatFromInt(w)) / app.scale_on, @as(f32, @floatFromInt(h)) / app.scale_on };

    if (start.level) |name| if (app.levelIndex(name)) |k| {
        app.open(k, false);
        app.tab = if (app.levels[k].battle) .battles else .locations;
    };
    if (start.tab) |t| app.tab = t;

    if (start.headless) {
        for (start.edits) |op| {
            try scripted.run(&app, op);
            doctabs.sync(&app);
        }
        if (start.save) app.save();
        std.debug.print("{s}\n", .{app.status});
        // Converted (--convert-to): the editor anew on the new project.
        if (app.takeGame()) |g| return g;
        if (start.shot) |path| {
            // Layout needs a previous frame for element boxes (viewport fit, hover).
            for (0..3) |_| present(&app, frame(&app, app.size, .{ 0, 0 }));
            try shot(&app, path);
        }
        return null;
    }

    // What the code editor's hover reads (every archive's entries, the sound bank), now
    // rather than on the first hover.
    @import("codenav.zig").warm(&app);
    var running = true;
    while (running) {
        app.clicked = false;
        app.right_clicked = false;
        var wheel: [2]f32 = .{ 0, 0 };
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) switch (ev.type) {
            c.SDL_EVENT_QUIT => running = events.closeKeyHeld() or !events.confirmQuit(&app),
            c.SDL_EVENT_MOUSE_MOTION => events.motion(&app, .{ ev.motion.x / app.scale_on, ev.motion.y / app.scale_on }),
            // The press at its own point: a slow frame (Debug) or the window's focus click
            // brings it without the motion before it, and the stale pointer missed.
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => {
                events.motion(&app, .{ ev.button.x / app.scale_on, ev.button.y / app.scale_on });
                events.buttonDown(&app, ev.button);
            },
            // Not moved to the release's point: a drag (the code's double-click word
            // selection) would end there.
            c.SDL_EVENT_MOUSE_BUTTON_UP => events.buttonUp(&app, ev.button.button),
            c.SDL_EVENT_MOUSE_WHEEL => events.wheel(&app, ev.wheel, &wheel),
            c.SDL_EVENT_TEXT_INPUT => events.textInput(&app, std.mem.span(ev.text.text)),
            c.SDL_EVENT_KEY_DOWN => events.keyDown(&app, ev.key),
            c.SDL_EVENT_WINDOW_RESIZED => _ = c.SDL_GetWindowSize(window, &w, &h),
            else => {},
        };
        if (app.takeDialog()) |d| app.fileChosen(d.ask, d.path);
        if (app.takeGame()) |g| {
            if (og.loaders.isGameDir(io, g)) return g;
            app.setStatus(tx.st_no_dat, .{});
        }
        applyScale(&app);
        // What the last frame's reloads let go of (its texts were drawn by now).
        og.core.entity.release();
        present(&app, frame(&app, .{ @as(f32, @floatFromInt(w)) / app.scale_on, @as(f32, @floatFromInt(h)) / app.scale_on }, wheel));
        app.syncTextInput();
        _ = c.SDL_RenderPresent(r);
    }
    return null;
}

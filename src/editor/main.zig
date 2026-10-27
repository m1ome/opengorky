//! opengorky-editor: level editor working directly on a game folder (its `.dat`
//! archives are rewritten on save, so work on a copy).
//!   opengorky-editor <game dir> [--level NAME] [edits]... [--save] [--shot out.png]
//!   edits: --move NAME X Y, --add CLASS, --set NAME FIELD VALUE, --set-class NAME FIELD VALUE,
//!   --copy ID (a class), --entry ID FIELD VALUE (an enemy class, item or hero),
//!   --sound ID ANIM ACTION (frame sounds: +NAME, K=NAME, K>D, -K; "" only shows ANIM),
//!   --import-sound FILE, --export-sound NAME FILE, --weapon FIGHTER CLASS NEWCLASS,
//!   --walk-in NAME (placed ↔ walking in at the battle start), --class-weapon CLASS CUR NEW,
//!   --remove NAME, --purge (files of fighters nobody places)
//! Tabs: battles and locations (left: levels; centre: the level — wheel zooms, drag an
//! object moves it, drag elsewhere pans, F fits, Delete removes; right: objects and the
//! selected enemy's parameters, its own `.ftr` overrides or its whole class); enemies,
//! items and heroes (pages.zig); settings. Ctrl+Z undoes and Ctrl+S saves every edit.
//! The edit flags and `--save` apply edits without the mouse (checks and scripts).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const ui = @import("ui");
const clay = @import("clay.zig");
const render = @import("render.zig");
const font_mod = @import("font.zig");
const Font = font_mod.Font;
const level = @import("level.zig");
const Doc = level.Doc;
const vars = @import("vars.zig");
const tx = @import("text.zig");
const Settings = @import("settings.zig").Settings;
const config = @import("config");
const Store = @import("store.zig").Store;
const savelog = @import("savelog.zig");
const catalog = @import("catalog.zig");
const pages = @import("pages.zig");
const boxpanel = @import("boxpanel.zig");
const preview = @import("preview.zig");
const entry_model = @import("entry_model.zig");
const sprview = @import("sprview.zig");
const paint = @import("paint.zig");
const search = @import("search.zig");
const scenepage = @import("scenepage.zig");
const triggerpanel = @import("triggerpanel.zig");
const checkpanel = @import("checkpanel.zig");
const assettree = @import("assettree.zig");
const icons = @import("icons.zig");
const doctabs = @import("doctabs.zig");
const kinds = @import("kinds.zig");
const scripted = @import("scripted.zig");
const treemenu = @import("treemenu.zig");
const cli = @import("cli.zig");
const textedit = @import("textedit.zig");
const levelanims = @import("levelanims.zig");
const logicview = @import("logicview.zig");
const paths = @import("paths.zig");
const codeview = @import("codeview.zig");
const infoblock = @import("info.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Tab = app_mod.Tab;
const Menu = app_mod.Menu;
const Stat = app_mod.Stat;
const theme = app_mod.theme;
const txt = app_mod.txt;
const panelHeader = app_mod.panelHeader;
const valueCell = app_mod.valueCell;
const searchField = app_mod.searchField;
const enemyTitle = app_mod.enemyTitle;
const fighter_stats = app_mod.fighter_stats;
const damage_stat = app_mod.damage_stat;

fn layout(app: *App) void {
    const a = app.frame.allocator();
    clay.open(.{
        .id = clay.id("root"),
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM },
        .backgroundColor = theme.bg,
    });
    {
        topBar(app, a);
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } } });
        assettree.panel(app, a);
        app.splitter(.levels, false, 1, 0);
        // The centre: the open documents' tabs over the one shown.
        doctabs.sync(app);
        // Code open: it is the centre's document (over the tab's own).
        const level_tab = (app.tab == .battles or app.tab == .locations) and app.code == null;
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
        doctabs.bar(app, a);
        if (level_tab) if (app.doc) |d| levelToolbar(app, a, d);
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
        // The level's inspector beside the centre, top to bottom.
        if (level_tab) {
            app.splitter(.objects, false, -1, 0);
            if (app.paint) |p| paint.panel(app, a, p) else if (logicview.of(app)) |v| logicPanel(app, a, v) else objectList(app, a);
        }
        clay.close();
        statusBar(app, a);
        if (app.menu) |m| menu(app, a, m);
        treemenu.draw(app, a);
        if (app.confirm) |cf| confirmWindow(app, cf);
        if (app.box) |b| boxpanel.panel(app, a, b);
        if (app.trigger) |t| triggerpanel.panel(app, a, t);
        if (app.check) |r| if (r.shown) checkpanel.panel(app, a, r);
    }
    clay.close();
}

/// Right-click menu on a battle: add an enemy of the picked class there.
/// History tab: every edit of the session, newest first, the last save marked, then
/// the saves of earlier sessions and the original. A click on a row shows what it
/// changed (nothing changes); "Return to this point" goes back to it.
pub fn historyPage(app: *App, a: Allocator) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(app.split(.history)), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM }, .backgroundColor = theme.panel });
    panelHeader(tx.alloc(a, tx.history_n_title, .{app.store.undo.items.len}));
    clay.openScroll(.{ .id = clay.id("history_list"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    historyRows(app, a);
    clay.close();
    clay.close();
    app.splitter(.history, false, 1, 0);

    // The picked row: what it changed, and going back to it.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 20, .right = 20, .top = 16 }, .childGap = 10 } });
    const past = pastSteps(app);
    var diff: []const u8 = "";
    switch (historyPick(app)) {
        .none => wrapped(tx.get(tx.history_pick), 14, theme.dim),
        .session => |k| if (k > 0) {
            txt(std.fmt.allocPrint(a, "{d}. {s}", .{ k, app.store.undo.items[k - 1].label }) catch "", 18, theme.text, font_mod.bold);
            if (k <= app.store.saved_at) txt(tx.get(tx.history_was_saved), 12, theme.accent_hover, font_mod.regular);
            diff = app.store.stepDiff(k - 1);
        } else historyOriginal(),
        .past => |j| if (j > 0) {
            txt(std.fmt.allocPrint(a, "{s} · {s}", .{ dateText(a, past[j - 1].time), past[j - 1].label }) catch "", 18, theme.text, font_mod.bold);
            diff = past[j - 1].diff;
        } else historyOriginal(),
    }
    historyReturn(app, a);
    if (diff.len > 0) {
        clay.openScroll(.{ .id = clay.id("history_diff"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 2 }, .backgroundColor = theme.viewport });
        // What the step changed: lines gone in red, new ones in green.
        var lines = std.mem.splitScalar(u8, diff, '\n');
        var n: usize = 0;
        while (lines.next()) |l| {
            if (l.len == 0) continue;
            n += 1;
            if (n > 400) break;
            const col = if (l[0] == '-') clay.rgb(0xe06c75) else clay.rgb(0x98c379);
            clay.open(.{ .layout = .{ .padding = .{ .left = 10, .right = 10 } } });
            txt(std.fmt.allocPrint(a, "{c} {s}", .{ l[0], std.mem.replaceOwned(u8, a, l[1..], "\t", "    ") catch l[1..] }) catch l, 13, col, font_mod.regular);
            clay.close();
        }
        clay.close();
    }
    clay.close();
}

fn historyOriginal() void {
    txt(tx.get(tx.history_original), 18, theme.text, font_mod.bold);
    wrapped(tx.get(tx.history_original_info), 13, theme.dim);
}

fn wrapped(s: []const u8, pt: u16, col: clay.Color) void {
    clay.text(s, .{ .textColor = col, .fontSize = pt, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
}

/// The saves of earlier sessions, oldest first.
fn pastSteps(app: *const App) []const savelog.Step {
    return if (app.store.past) |p| p.steps else &.{};
}

/// The row picked: a step of this session (0: the original when no earlier session
/// saved), a save of an earlier one (0: the original).
const Pick = union(enum) { none, session: usize, past: usize };

fn historyPick(app: *const App) Pick {
    if (app.history_open) |k| if (k <= app.store.undo.items.len) return .{ .session = k };
    if (app.history_old) |j| if (j <= pastSteps(app).len) return .{ .past = j };
    return .none;
}

/// "2026-10-26 14:03 UTC" for unix time `secs`.
fn dateText(a: Allocator, secs: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, secs)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(a, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour() }) catch "";
}

/// The steps, newest first, with where the last save was, then the earlier sessions'
/// saves and the original; a click picks one.
fn historyRows(app: *App, a: Allocator) void {
    var buf: [512][]const u8 = undefined;
    const labels = app.store.labels(&buf);
    const skipped = app.store.undo.items.len - labels.len;
    const past = pastSteps(app);
    if (labels.len == 0 and past.len == 0) {
        clay.open(.{ .layout = .{ .padding = .{ .left = 12, .top = 8 } } });
        txt(tx.get(tx.history_empty), 13, theme.dim, font_mod.regular);
        clay.close();
        return;
    }
    var k = labels.len;
    while (k > 0) {
        k -= 1;
        const step = skipped + k + 1;
        // The last save between the steps after it and those before.
        if (step == app.store.saved_at and step < app.store.undo.items.len) historyMark(tx.get(tx.history_saved), theme.accent_hover);
        if (historyRow(app, clay.idi("history", @intCast(step)), std.fmt.allocPrint(a, "{d}", .{step}) catch "", labels[k], app.history_open == step)) {
            app.history_open = step;
            app.history_old = null;
        }
    }
    if (past.len > 0) historyMark(tx.get(tx.history_earlier), theme.dim);
    var j = past.len;
    while (j > 0) : (j -= 1) if (historyRow(app, clay.idi("history_old", @intCast(j)), dateText(a, past[j - 1].time), past[j - 1].label, app.history_old == j)) {
        app.history_old = j;
        app.history_open = null;
    };
    // The original: before the earliest save kept, else as the editor opened the files.
    const orig_sel = if (past.len > 0) app.history_old == 0 else app.history_open == 0;
    if (historyRow(app, clay.id("history_original"), "", tx.get(tx.history_original), orig_sel)) {
        app.history_open = if (past.len > 0) null else 0;
        app.history_old = if (past.len > 0) 0 else null;
    }
}

fn historyMark(s: []const u8, col: clay.Color) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(22) }, .padding = .{ .left = 12 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.bg });
    txt(s, 12, col, font_mod.bold);
    clay.close();
}

/// One row: its number or date, its label; true when clicked.
fn historyRow(app: *App, rid: ui.Clay_ElementId, num: []const u8, label: []const u8, sel: bool) bool {
    const hit = app_mod.clickable(app, .{
        .id = rid,
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(28) }, .padding = .{ .left = 12, .right = 8 }, .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = theme.panel,
    }, sel);
    if (num.len > 0) txt(num, 12, if (sel) theme.text else theme.dim, font_mod.regular);
    txt(label, 13, theme.text, if (sel) font_mod.bold else font_mod.regular);
    clay.close();
    return hit;
}

/// The right panel's tabs (as the concept's inspector): the panel itself, the history.
/// True when the history is shown (the caller draws it with `inspectorHistory`).
pub fn inspectorTabs(app: *App) bool {
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(40) }, .padding = .{ .left = 8, .right = 8 }, .childGap = 4, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_BOTTOM } },
        .backgroundColor = theme.panel,
        .border = .{ .color = theme.line, .width = .{ .bottom = 1 } },
    });
    for ([_]app_mod.Inspector{ .inspector, .history }, [_]tx.Msg{ tx.in_inspector, tx.in_history }, 0..) |t, label, k| {
        const on = app.inspector == t;
        const tid = clay.idi("insp_tab", @intCast(k));
        clay.open(.{
            .id = tid,
            .layout = .{ .sizing = .{ .height = clay.fixed(36) }, .padding = .{ .left = 12, .right = 12 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
            .border = .{ .color = theme.accent, .width = .{ .bottom = if (on) 2 else 0 } },
        });
        if (clay.hovered() and app.clicked) app.inspector = t;
        txt(tx.get(label), 14, if (on) theme.accent_hover else theme.dim, if (on) font_mod.bold else font_mod.regular);
        clay.close();
    }
    clay.close();
    return app.inspector == .history;
}

/// The history in the right panel: its rows, and going back to the picked one.
pub fn inspectorHistory(app: *App, a: Allocator) void {
    clay.openScroll(.{ .id = clay.id("insp_history"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .top = 4 } } });
    historyRows(app, a);
    clay.close();
    if (historyPick(app) == .none) return;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 10 }, .childGap = 8 }, .border = .{ .color = theme.line, .width = .{ .top = 1 } } });
    historyReturn(app, a);
    clay.close();
}

/// What returning to the picked row does, and the button that does it (none: the
/// files are as it left them).
fn historyReturn(app: *App, a: Allocator) void {
    const n = app.store.undo.items.len;
    const past = pastSteps(app).len;
    const pick = historyPick(app);
    const info = switch (pick) {
        .none => return,
        .session => |k| if (k == n) null else tx.alloc(a, tx.history_back_session, .{n - k}),
        .past => |j| if (j == past and n == 0) null else tx.get(tx.history_back_past),
    };
    if (pick == .past and info != null and n > 0) wrapped(tx.alloc(a, tx.history_back_past_n, .{n}), 13, theme.text);
    wrapped(info orelse tx.get(tx.history_here), 13, if (info == null) theme.dim else theme.text);
    if (info == null) return;
    if (!app_mod.toolButton(app, "history_return", .undo_2, tx.get(tx.history_return), false, true)) return;
    switch (pick) {
        .none => {},
        .session => |k| app.rollBack(k),
        .past => |j| if (j == past) app.rollBack(0) else app.returnToPast(j),
    }
    app.history_open = null;
    app.history_old = null;
}

/// The level's script file of object `name` (`name.itm`, `.are`, `.ftr`…).
fn scriptOf(d: *level.Doc, name: []const u8) ?[]const u8 {
    for (d.scripts.items) |e| {
        const dot = std.mem.lastIndexOfScalar(u8, e, '.') orelse continue;
        if (std.ascii.eqlIgnoreCase(e[0..dot], name)) return e;
    }
    return null;
}

/// Closing with edits not saved (or not applied in the code editor): save them, drop
/// them, or stay; true — close.
fn confirmQuit(app: *App) bool {
    const code_open = codeview.anyChanged(app);
    if (!app.store.dirty() and !code_open) return true;
    const buttons = [_]c.SDL_MessageBoxButtonData{
        .{ .flags = c.SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, .buttonID = 1, .text = tx.get(tx.q_save).ptr },
        .{ .flags = 0, .buttonID = 2, .text = tx.get(tx.q_discard).ptr },
        .{ .flags = c.SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, .buttonID = 0, .text = tx.get(tx.cancel).ptr },
    };
    const data: c.SDL_MessageBoxData = .{
        .flags = c.SDL_MESSAGEBOX_WARNING,
        .window = app.window,
        .title = tx.get(tx.title).ptr,
        .message = tx.get(tx.q_unsaved).ptr,
        .numbuttons = buttons.len,
        .buttons = &buttons,
        .colorScheme = null,
    };
    var hit: c_int = 0;
    if (!c.SDL_ShowMessageBox(&data, &hit)) return true;
    switch (hit) {
        1 => {
            app.save();
            return !app.store.dirty() and !codeview.anyChanged(app);
        },
        2 => return true,
        else => return false,
    }
}

/// The menu's shape: a rounded panel; `sub`: a submenu beside row `parent_id`.
pub fn menuPanel(id: ui.Clay_ElementId, w: f32, float: ui.Clay_FloatingElementConfig) void {
    clay.open(.{
        .id = id,
        .layout = .{ .sizing = .{ .width = clay.fixed(w), .height = clay.fit() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 } },
        .backgroundColor = theme.panel,
        .cornerRadius = clay.radius(theme.radius),
        .border = .{ .color = theme.button_edge, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } },
        .floating = float,
    });
}

/// One menu row: icon, label, the key on the right; true when clicked (the menu closes).
/// A disabled row is dim and takes no click.
pub fn menuRow(app: *App, id: []const u8, ic: ?icons.Icon, label: []const u8, key: []const u8, col: clay.Color, enabled: bool) bool {
    const rid = clay.id(id);
    const over = enabled and clay.pointerOver(rid);
    clay.open(.{
        .id = rid,
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(30) }, .padding = .{ .left = 8, .right = 10 }, .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = if (over) theme.row_hover else theme.panel,
        .cornerRadius = clay.radius(4),
    });
    const hit = over and app.clicked;
    const fg = if (enabled) col else theme.dim;
    if (ic) |i| icons.leaf(app.r, app.gpa, i, 15, if (enabled) (if (col.r == theme.warn.r and col.g == theme.warn.g) col else theme.dim) else theme.line) else clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(15) } } });
    txt(label, 14, fg, font_mod.regular);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    if (key.len > 0) txt(key, 12, theme.dim, font_mod.regular);
    clay.close();
    if (hit) {
        app.menu = null;
        app.tree_menu = null;
    }
    return hit;
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
    clay.open(.{
        .id = rid,
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(30) }, .padding = .{ .left = 8, .right = 8 }, .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = if (open) theme.accent else theme.panel,
        .cornerRadius = clay.radius(4),
    });
    icons.leaf(app.r, app.gpa, ic, 15, if (open) theme.text else theme.dim);
    txt(label, 14, theme.text, font_mod.regular);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    icons.leaf(app.r, app.gpa, .chevron_right, 13, if (open) theme.text else theme.dim);
    if (!open) {
        clay.close();
        return false;
    }
    menuPanel(clay.idi("submenu", @backingInt(which)), w, .{ .attachTo = ui.CLAY_ATTACH_TO_PARENT, .attachPoints = .{ .element = ui.CLAY_ATTACH_POINT_LEFT_TOP, .parent = ui.CLAY_ATTACH_POINT_RIGHT_TOP }, .offset = .{ .x = 6, .y = -4 }, .zIndex = 110 });
    return true;
}

pub fn menuLine() void {
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(1) } }, .backgroundColor = theme.line });
}

pub fn menuTitle(a: Allocator, name: []const u8, kind: []const u8) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(30) }, .padding = .{ .left = 8, .right = 8 }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    txt(name, 13, theme.text, font_mod.bold);
    if (kind.len > 0) txt(std.fmt.allocPrint(a, "/  {s}", .{kind}) catch kind, 13, theme.dim, font_mod.regular);
    clay.close();
}

fn kindName(d: *level.Doc, o: level.Obj) []const u8 {
    if (d.boxFile(o.name) != null) return tx.get(tx.cm_k_box);
    return tx.get(switch (o.kind) {
        .enemy => tx.cm_k_enemy,
        .hero => tx.cm_k_hero,
        .neutral => tx.cm_k_neutral,
        .prop => tx.cm_k_prop,
        .item => tx.cm_k_item,
        .actor => tx.cm_k_actor,
        .area => tx.cm_k_area,
    });
}

/// Right-click menu, one for locations and battles: on an object what can be done with
/// it; on the floor what can be added there, paste and centring.
fn menu(app: *App, a: Allocator, m: Menu) void {
    const d = app.doc orelse return;
    menuPanel(clay.id("menu"), 270, .{ .offset = .{ .x = m.at[0], .y = m.at[1] }, .zIndex = 100, .attachTo = ui.CLAY_ATTACH_TO_ROOT });
    if (m.obj) |i| if (i < d.objects.items.len) {
        objectMenu(app, a, d, i);
        clay.close();
        return;
    };
    if (d.isBattle()) {
        if (m.grid) |g| menuTitle(a, tx.alloc(a, tx.menu_add_at, .{ @as(i32, @intFromFloat(@floor(g[0]))), @as(i32, @intFromFloat(@floor(g[1]))) }), "") else menuTitle(a, tx.get(tx.cm_canvas), "");
    } else menuTitle(a, tx.get(tx.cm_canvas), "");
    menuLine();
    const g = m.grid;
    if (subRow(app, "menu_add", .box, tx.get(tx.cm_add_object), .add, 230)) {
        if (d.isBattle()) {
            if (g) |gp| {
                if (menuRow(app, "menu_add_box", .box, tx.get(tx.cm_container), "", theme.text, true)) app.addObstacle(.box, gp);
                const obs = [_]struct { level.Obstacle, tx.Msg }{ .{ .wcrate, tx.ob_wcrate }, .{ .mcrate, tx.ob_mcrate }, .{ .barrel, tx.ob_barrel } };
                for (obs) |k| if (menuRow(app, @tagName(k[0]), .package, tx.get(k[1]), "", theme.text, true)) app.addObstacle(k[0], gp);
                menuLine();
                const props = [_]struct { level.Prop, tx.Msg }{
                    .{ .barrier, tx.pr_barrier }, .{ .pipe, tx.pr_pipe },     .{ .logs, tx.pr_logs },       .{ .fcrate, tx.pr_fcrate },
                    .{ .bathtub, tx.pr_bathtub }, .{ .corpse, tx.pr_corpse }, .{ .automat, tx.pr_automat },
                };
                for (props) |k| if (menuRow(app, @tagName(k[0]), .image, tx.get(k[1]), "", theme.text, true)) app.addProp(k[0], gp);
            } else txtRow(tx.get(tx.st_no_tile));
        } else if (menuRow(app, "menu_box", .box, tx.get(tx.cm_container), "", theme.text, true)) app.addBox(m.bg);
        clay.close();
        clay.close();
    }
    if (!d.isBattle()) if (subRow(app, "menu_model", .box, tx.get(tx.cm_add_model), .model, 300)) {
        modelChoice(app, a, m.bg);
        clay.close();
        clay.close();
    };
    if (d.isBattle()) {
        if (g) |gp| {
            if (subRow(app, "menu_enemy", .user, tx.get(tx.menu_add_enemy), .enemy, 300)) {
                enemyChoice(app, a, gp);
                clay.close();
                clay.close();
            }
            if (subRow(app, "menu_own", .user, tx.get(tx.menu_add_own), .own, 260)) {
                ownChoice(app, a, d, gp);
                clay.close();
                clay.close();
            }
        }
    } else {
        if (subRow(app, "menu_hero", .user, tx.get(tx.menu_add_hero), .hero, 280)) {
            heroChoice(app, a, d, m.bg);
            clay.close();
            clay.close();
        }
        if (menuRow(app, "menu_trigger_new", .square_dashed, tx.get(tx.cm_add_trigger), "", theme.text, true)) paintTool(app, .area);
        if (menuRow(app, "menu_exit_new", .log_out, tx.get(tx.cm_add_exit), "", theme.text, true)) paintTool(app, .exit);
    }
    menuLine();
    if (menuRow(app, "menu_paste", .copy, tx.get(tx.cm_paste), cmdKey(a, "V"), theme.text, app.clip != null)) app.paste(m.bg, g);
    if (menuRow(app, "menu_center", .crosshair, tx.get(tx.cm_center), "", theme.text, true)) app.centreOn(m.bg);
    clay.close();
}

/// Delete on the picked object: asked first (as the menu's Delete).
fn askRemoveSelected(app: *App) void {
    const d = app.doc orelse return;
    const i = app.selected orelse return;
    const o = d.objects.items[i];
    // A box or a model stood here goes with its file.
    if (d.deletableBox(o.name) != null or (o.kind == .actor and d.deletableActor(o.name) != null)) return app.askDelete(.box, i, o.name);
    if (o.call == null or o.later != null) return;
    app.askDelete(.object, i, o.name);
}

/// The confirmation window: what will be deleted, Delete (Enter) or Cancel (Esc).
fn confirmWindow(app: *App, cf: app_mod.Confirm) void {
    // A dimmed screen under it (clicks outside cancel).
    clay.open(.{ .id = clay.id("confirm_shade"), .layout = .{ .sizing = .{ .width = clay.fixed(app.size[0]), .height = clay.fixed(app.size[1]) }, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = .{ .r = 0, .g = 0, .b = 0, .a = 120 }, .floating = .{ .zIndex = 200, .attachTo = ui.CLAY_ATTACH_TO_ROOT } });
    clay.open(.{ .id = clay.id("confirm"), .layout = .{ .sizing = .{ .width = clay.fixed(420) }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 20, .right = 20, .top = 18, .bottom = 16 }, .childGap = 14 }, .backgroundColor = theme.panel, .cornerRadius = clay.radius(theme.radius), .border = .{ .color = theme.button_edge, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } } });
    clay.open(.{ .layout = .{ .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    icons.leaf(app.r, app.gpa, .trash_2, 18, theme.warn);
    txt(tx.get(tx.cf_title), 16, theme.text, font_mod.bold);
    clay.close();
    clay.text(cf.text(), .{ .textColor = theme.text, .fontSize = 13, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    clay.text(tx.get(tx.cf_undo), .{ .textColor = theme.dim, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 8 } });
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    if (app_mod.toolButton(app, "confirm_no", .x, tx.get(tx.cancel), false, false)) app.confirm = null;
    if (app_mod.toolButton(app, "confirm_yes", .trash_2, tx.get(tx.cm_delete), false, true)) app.confirmed();
    clay.close();
    clay.close();
    clay.close();
}

/// Object keys (copy, paste, duplicate, rename) act on the level: its edit mode's
/// Objects tool, nothing over it.
fn levelKeys(app: *App) bool {
    return (app.tab == .battles or app.tab == .locations) and app.editingObjects() and !app.overlay();
}

/// `Cmd X` on macOS, `Ctrl+X` elsewhere.
pub fn cmdKey(a: Allocator, k: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}{s}", .{ if (@import("builtin").os.tag == .macos) "Cmd " else "Ctrl+", k }) catch k;
}

fn txtRow(s: []const u8) void {
    clay.open(.{ .layout = .{ .padding = .{ .left = 10, .top = 6, .bottom = 6 } } });
    txt(s, 13, theme.dim, font_mod.regular);
    clay.close();
}

/// The level edit mode on tool `t` (a new trigger area or exit is drawn with it).
fn paintTool(app: *App, t: paint.Tool) void {
    if (app.paint == null) app.openPaint();
    if (app.paint) |p| p.tool = t;
}

fn objectMenu(app: *App, a: Allocator, d: *level.Doc, i: usize) void {
    const o = d.objects.items[i];
    menuTitle(a, o.name, kindName(d, o));
    menuLine();
    if (d.boxFile(o.name)) |f| if (menuRow(app, "menu_contents", .box, tx.get(tx.cm_edit_contents), "Enter", theme.text, true)) {
        app.selected = i;
        app.box = .{ .file = f, .name = o.name };
    };
    if (o.kind == .area and menuRow(app, "menu_trigger", .square_dashed, tx.get(tx.menu_trigger), "", theme.text, true)) app.trigger = o.name;
    // What it is one of (its class: the enemy, the item; the hero), in a tab of its own.
    if (entryOfObject(app, d, o)) |ei| {
        const e = app.catalog.entries.items[ei];
        if (menuRow(app, "menu_entry", .user, tx.alloc(a, tx.cm_open_entry, .{if (e.title.len > 0) e.title else e.id}), "", theme.text, true)) {
            doctabs.keepCurrent(app);
            @import("treemenu.zig").openItem(app, .of(.entry, e.id));
            app.menu = null;
        }
    }
    // Its placement call in the level script, or its own script.
    // (A file added here and not saved yet is the object's own.)
    const own: ?usize = o.file orelse if (scriptOf(d, o.name)) |entry| app.store.file(d.level_archive, entry) catch null else null;
    if (menuRow(app, "menu_code", .code, tx.get(tx.cm_reveal), "", theme.text, o.call != null or own != null)) {
        if (o.call) |ci| codeview.open(app, d.lev, d.script.calls[ci].stmt.start) else if (own) |f| codeview.open(app, f, null);
    }
    if (subRow(app, "menu_refs", .search, tx.get(tx.cm_refs), .refs, 420)) {
        if (app.menu_refs.items.len == 0) txtRow(tx.get(tx.cm_no_refs));
        for (app.menu_refs.items, 0..) |r, k| if (menuRow(app, std.fmt.allocPrint(a, "menu_ref{d}", .{k}) catch "r", .file_text, r.label, "", theme.text, true)) {
            if (app.store.file(r.path, r.entry)) |f| codeview.open(app, f, r.at) else |_| {}
        };
        clay.close();
        clay.close();
    }
    if (d.facing(i)) |deg| {
        if (menuRow(app, "menu_turn_left", .undo_2, tx.alloc(a, tx.menu_turn, .{ @as(i32, @intFromFloat(deg)), "-45" }), "", theme.text, true)) d.rotate(i, -45) catch |err| app.setStatus(tx.st_move_failed, .{err});
        if (menuRow(app, "menu_turn_right", .redo_2, tx.alloc(a, tx.menu_turn, .{ @as(i32, @intFromFloat(deg)), "+45" }), "", theme.text, true)) d.rotate(i, 45) catch |err| app.setStatus(tx.st_move_failed, .{err});
    }
    if (d.canWalkIn(i)) |walks| if (menuRow(app, "menu_walk_in", .log_out, tx.get(if (walks) tx.menu_place_now else tx.menu_walk_in), "", theme.text, true)) d.toggleWalkIn(i) catch |err| app.setStatus(tx.st_move_failed, .{err});
    menuLine();
    if (menuRow(app, "menu_dup", .copy, tx.get(tx.cm_duplicate), cmdKey(a, "D"), theme.text, o.call != null or d.boxFile(o.name) != null)) app.duplicate(i);
    if (menuRow(app, "menu_copy", .copy, tx.get(tx.cm_copy), cmdKey(a, "C"), theme.text, true)) app.copyObject(i);
    if (menuRow(app, "menu_rename", .pencil, tx.get(tx.cm_rename), "F2", theme.text, o.kind == .area)) renameArea(app, o.name);
    if (menuRow(app, "menu_focus", .crosshair, tx.get(tx.cm_focus), "F", theme.text, true)) app.centreOn(o.pos);
    menuLine();
    const hidden = app.view_hidden.contains(o.name);
    if (menuRow(app, "menu_hide", if (hidden) .eye else .eye_off, tx.get(if (hidden) tx.cm_show else tx.cm_hide), "", theme.text, true)) app.toggleHidden(o.name);
    const locked = app.locked.contains(o.name);
    if (menuRow(app, "menu_lock", if (locked) .lock_open else .lock, tx.get(if (locked) tx.cm_unlock else tx.cm_lock), "", theme.text, true)) app.toggleLocked(o.name);
    menuLine();
    // Delete: a box made in the editor (its files), a hero brought in, a placed object.
    if (d.boxFile(o.name) != null and d.deletableBox(o.name) != null) {
        if (menuRow(app, "menu_delete_box", .trash_2, tx.get(tx.menu_delete_box), "Delete", theme.warn, true)) app.askDelete(.box, i, o.name);
    } else if (o.kind == .actor and d.deletableActor(o.name) != null) {
        // A model stood here (its `.act`): the file goes, as a box's.
        if (menuRow(app, "menu_delete_act", .trash_2, tx.get(tx.cm_delete), "Delete", theme.warn, true)) app.askDelete(.box, i, o.name);
    } else if (o.kind == .hero and d.heroFile(o.name) != null) {
        if (menuRow(app, "menu_hero_drop", .trash_2, tx.get(tx.menu_hero_drop), "Delete", theme.warn, true)) app.askDelete(.hero, i, o.name);
    } else if (menuRow(app, "menu_remove", .trash_2, tx.get(tx.cm_delete), "Delete", theme.warn, o.call != null and o.later == null)) app.askDelete(.object, i, o.name);
}

/// The catalog entry object `o` is one of: the class its script includes (an enemy's
/// `ft_`, an item's `ca_`/`ci_`/`cw_`), else a hero of its name.
fn entryOfObject(app: *App, d: *level.Doc, o: level.Obj) ?usize {
    const es = app.catalog.entries.items;
    if (scriptOf(d, o.name)) |entry| if (app.store.file(d.level_archive, entry)) |f| {
        var it = std.mem.tokenizeAny(u8, app.store.text(f), "\r\n");
        while (it.next()) |ln| {
            const l = std.mem.trim(u8, ln, " \t");
            if (!std.ascii.startsWithIgnoreCase(l, "#include") and !std.ascii.startsWithIgnoreCase(l, "#inherit")) continue;
            const cls = std.mem.trim(u8, l["#include".len..], " \t\"");
            for (es, 0..) |e, i| {
                const base = e.entry[if (std.mem.lastIndexOfScalar(u8, e.entry, '\\')) |k| k + 1 else 0..];
                if (std.ascii.eqlIgnoreCase(base, cls)) return i;
            }
        }
    } else |_| {};
    for (es, 0..) |e, i| if (e.kind == .hero and std.ascii.eqlIgnoreCase(e.id, o.name)) return i;
    return null;
}

/// Area `name` being renamed: the edit mode's area tool with it picked, its name typed.
fn renameArea(app: *App, name: []const u8) void {
    paintTool(app, .area);
    const p = app.paint orelse return;
    paint.pickName(p, name);
    p.renaming = true;
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
            if (menuRow(app, std.fmt.allocPrint(a, "menu_own{d}", .{k}) catch "o", .user, label, "", theme.text, !placed)) app.addOwn(name, g);
        }
    }
}

/// The game's 3D models (gfx_3d\\*.msh), with search, to stand at background point `bg`.
fn modelChoice(app: *App, a: Allocator, bg: [2]f32) void {
    searchField(app, a);
    clay.openScroll(.{ .id = clay.id("menu_models"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = .{ .type = ui.CLAY__SIZING_TYPE_FIT, .size = .{ .minMax = .{ .min = 0, .max = 420 } } } }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    for (app.modelNames(), 0..) |mn, k| {
        if (!search.matches(app.query(), &.{mn})) continue;
        if (menuRow(app, std.fmt.allocPrint(a, "menu_mdl{d}", .{k}) catch "m", .box, mn, "", theme.text, true)) app.addActor(mn, bg);
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
            if (menuRow(app, std.fmt.allocPrint(a, "menu_hero{d}", .{k}) catch "h", .user, label, "", theme.text, true)) app.addHero(k, bg);
        }
    }
}

/// Enemy classes to add at grid point `g`, with search.
fn enemyChoice(app: *App, a: Allocator, g: [2]f32) void {
    searchField(app, a);
    clay.openScroll(.{ .id = clay.id("menu_list"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = .{ .type = ui.CLAY__SIZING_TYPE_FIT, .size = .{ .minMax = .{ .min = 0, .max = 420 } } } }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    for (app.allTemplates(a), 0..) |t, i| {
        const title = enemyTitle(app, t.class);
        if (!search.matches(app.query(), &.{ t.class, title })) continue;
        const rid = clay.idi("menu_tpl", @intCast(i));
        if (app_mod.clickable(app, .{
            .id = rid,
            .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(24) }, .padding = .{ .left = 12, .right = 8 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
            .backgroundColor = theme.panel,
        }, false)) {
            app.menu = null;
            app.addEnemy(t, g);
        }
        if (title.len > 0) txt(title, 14, theme.text, font_mod.regular);
        txt(t.class, if (title.len > 0) 12 else 14, if (title.len > 0) theme.dim else theme.text, font_mod.regular);
        if (t.base != null) txt(tx.get(tx.new), 12, theme.accent_hover, font_mod.regular);
        if (t.weapon != null) txt(tx.get(tx.built), 12, theme.warn, font_mod.regular);
        clay.close();
    }
    clay.close();
}

pub fn settingsPage(app: *App, a: Allocator) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 24, .right = 24, .top = 12 }, .childGap = 14 } });
    settingRow(tx.get(tx.s_language));
    for (tx.langs, 0..) |l, k| {
        const sel = tx.lang == l.lang;
        const bid = clay.idi("lang", @intCast(k));
        if (app_mod.clickable(app, .{
            .id = bid,
            .layout = .{ .sizing = .{ .height = clay.fixed(28) }, .padding = .{ .left = 14, .right = 14 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
            .backgroundColor = theme.panel,
        }, sel)) app.setLang(l.lang);
        txt(l.name, 14, if (sel) theme.text else theme.dim, if (sel) font_mod.bold else font_mod.regular);
        clay.close();
    }
    clay.close();
    settingRow(tx.get(tx.s_game));
    txt(if (app.game_dir.len > 0) app.game_dir else tx.get(tx.s_no_game), 14, if (app.game_dir.len > 0) theme.text else theme.warn, font_mod.regular);
    const gid = clay.id("pick_game");
    clay.open(.{ .id = gid, .layout = .{ .sizing = .{ .height = clay.fixed(28) }, .padding = .{ .left = 14, .right = 14 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = if (clay.pointerOver(gid)) theme.accent_hover else theme.accent });
    if (clay.hovered() and app.clicked) app.askGame();
    txt(tx.get(tx.s_pick_game), 14, theme.text, font_mod.bold);
    clay.close();
    clay.close();
    hint(tx.get(tx.s_game_hint));
    settingRow(tx.get(tx.s_original));
    const orig = app.settings.originalPath();
    txt(orig orelse tx.get(tx.s_no_original), 14, if (orig != null) theme.text else theme.warn, font_mod.regular);
    if (app_mod.button(app, "pick_original", tx.get(tx.s_pick_original), false)) app.askFile(.{ .kind = .folder, .run = App.onOriginal });
    if (orig != null) if (app_mod.button(app, "package_mod", tx.get(tx.s_package), true)) app.askFile(.{ .kind = .folder, .run = App.onPackage });
    clay.close();
    hint(tx.get(tx.s_original_hint));
    hint(tx.get(tx.s_package_hint));
    settingRow(tx.get(tx.s_viewer));
    const viewer = app.settings.viewerPath();
    txt(viewer orelse tx.get(tx.s_viewer_auto), 14, if (viewer != null) theme.text else theme.dim, font_mod.regular);
    if (app_mod.button(app, "pick_viewer", tx.get(tx.s_pick_original), false)) app.askFile(.{ .kind = .program, .run = App.onViewer });
    if (viewer != null) if (app_mod.button(app, "viewer_auto", tx.get(tx.s_viewer_clear), false)) {
        app.settings.setViewerPath("");
        app.saveSettings();
    };
    clay.close();
    hint(tx.get(tx.s_viewer_hint));
    settingRow(tx.get(tx.s_file));
    txt(app.settings_path orelse tx.get(tx.s_no_file), 14, theme.text, font_mod.regular);
    clay.close();
    var battles: usize = 0;
    for (app.levels) |e| battles += @intFromBool(e.battle);
    settingRow(tx.get(tx.s_levels));
    txt(tx.alloc(a, tx.s_levels_n, .{ battles, app.levels.len - battles, app.templates.len }), 14, theme.text, font_mod.regular);
    clay.close();
    clay.close();
}

/// Opens a settings row with its label; the caller adds the value and closes it.
fn settingRow(label: []const u8) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fit() }, .padding = .{ .left = 12 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(160) } } });
    txt(label, 14, theme.dim, font_mod.regular);
    clay.close();
}

fn hint(s: []const u8) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fit() }, .padding = .{ .left = 180 } } });
    clay.text(s, .{ .textColor = theme.warn, .fontSize = 13, .fontId = font_mod.regular });
    clay.close();
}

/// The top bar: the project (the game folder), the search over every asset (⌘K),
/// Save (runs the mod check), Play (the open level in the port), History, Settings.
fn topBar(app: *App, a: Allocator) void {
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(52) }, .padding = .{ .left = 18, .right = 12 }, .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = theme.bg,
        .border = .{ .color = theme.line, .width = .{ .bottom = 1 } },
    });
    txt("OpenGorky", 17, theme.text, font_mod.bold);
    if (app.game_dir.len > 0) {
        txt("/", 15, theme.dim, font_mod.regular);
        txt(std.fs.path.basename(app.game_dir), 14, theme.dim, font_mod.regular);
    }
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    assettree.searchBox(app, a, "top_search", tx.get(tx.at_search_all), true);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    const dirty = app.store.dirty();
    if (topButton(app, "save", .save, tx.get(tx.tb_save), false, dirty, if (dirty) theme.warn else null) and dirty) app.save();
    if (topButton(app, "play", .play, tx.get(tx.tb_play), true, app.doc != null, null) and app.doc != null) app.playLevel();
    if (iconButton(app, "history", .history, app.tab == .history)) app.setTab(.history);
    if (iconButton(app, "settings", .settings, app.tab == .settings)) app.setTab(.settings);
    clay.close();
}

/// A top bar button: icon and label (`primary`: the accent; dim when not `enabled`; a
/// coloured dot when `mark`).
fn topButton(app: *App, id: []const u8, ic: icons.Icon, label: []const u8, primary: bool, enabled: bool, mark: ?clay.Color) bool {
    const bid = clay.id(id);
    const over = enabled and clay.pointerOver(bid);
    clay.open(.{
        .id = bid,
        .layout = .{ .sizing = .{ .height = clay.fixed(34) }, .padding = .{ .left = 14, .right = 16 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = if (primary) (if (over) theme.accent_hover else theme.accent) else if (over) theme.button_hover else theme.button,
        .cornerRadius = clay.radius(theme.radius),
        .border = .{ .color = if (primary) theme.accent else theme.button_edge, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } },
    });
    const hit = clay.hovered() and app.clicked;
    const col = if (enabled) theme.text else theme.dim;
    icons.leaf(app.r, app.gpa, ic, 17, col);
    txt(label, 14, col, if (primary) font_mod.bold else font_mod.regular);
    if (mark) |m| clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(7), .height = clay.fixed(7) } }, .backgroundColor = m, .cornerRadius = clay.radius(4) });
    clay.close();
    return hit;
}

/// A square icon button (`on`: its page is shown).
fn iconButton(app: *App, id: []const u8, ic: icons.Icon, on: bool) bool {
    const bid = clay.id(id);
    clay.open(.{
        .id = bid,
        .layout = .{ .sizing = .{ .width = clay.fixed(34), .height = clay.fixed(34) }, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = if (on) theme.row_selected else if (clay.pointerOver(bid)) theme.button_hover else theme.bg,
        .cornerRadius = clay.radius(theme.radius),
    });
    const hit = clay.hovered() and app.clicked;
    icons.leaf(app.r, app.gpa, ic, 18, if (on) theme.text else theme.dim);
    clay.close();
    return hit;
}

/// The status bar: what happened last (or what to do), the project on the right.
fn statusBar(app: *App, a: Allocator) void {
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(28) }, .padding = .{ .left = 14, .right = 14 }, .childGap = 14, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .clip = .{ .horizontal = true },
        .backgroundColor = theme.bg,
        .border = .{ .color = theme.line, .width = .{ .top = 1 } },
    });
    if (app.store.dirty()) {
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(8), .height = clay.fixed(8) } }, .backgroundColor = theme.warn, .cornerRadius = clay.radius(4) });
        txt(tx.get(tx.unsaved), 12, theme.warn, font_mod.regular);
    } else {
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(8), .height = clay.fixed(8) } }, .backgroundColor = theme.ok, .cornerRadius = clay.radius(4) });
        txt(tx.get(tx.sb_saved), 12, theme.dim, font_mod.regular);
    }
    txt(if (app.status.len > 0) app.status else if (app.tab == .battles or app.tab == .locations) tx.get(tx.pick_level) else "", 12, theme.dim, font_mod.regular);
    // The mod check of the last save: its problems open the window again.
    if (app.check) |r| if (r.failed != null or r.problems.len > 0) {
        const pid = clay.id("check_status");
        clay.open(.{ .id = pid, .layout = .{ .padding = .{ .left = 4, .right = 4 } } });
        if (clay.hovered() and app.clicked) r.shown = true;
        txt(tx.alloc(a, tx.sb_problems, .{r.problems.len}), 12, if (clay.pointerOver(pid)) theme.accent_hover else theme.warn, font_mod.regular);
        clay.close();
    };
    // An import converting: Cancel beside its progress.
    if (app.convert != null) {
        const cid = clay.id("convert_cancel");
        clay.open(.{ .id = cid, .layout = .{ .padding = .{ .left = 4, .right = 4 } } });
        if (clay.hovered() and app.clicked) @import("convert.zig").cancel(app);
        txt(tx.get(tx.cancel), 12, if (clay.pointerOver(cid)) theme.accent_hover else theme.accent, font_mod.regular);
        clay.close();
    }
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    // A level: what the mouse does now, where it is on the background, the zoom.
    if ((app.tab == .battles or app.tab == .locations) and app.code == null) if (app.doc) |d| {
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
        txt(tx.get(mouse_hint), 12, theme.dim, font_mod.regular);
        if (App.viewportRect()) |v| if (app.overViewport()) {
            const b = d.toBackground(v, app.mouse);
            txt(tx.alloc(a, tx.sb_pos, .{ @as(i32, @intFromFloat(b[0])), @as(i32, @intFromFloat(b[1])) }), 12, theme.dim, font_mod.regular);
        };
        txt(tx.alloc(a, tx.sb_zoom, .{d.zoom * 100}), 12, theme.dim, font_mod.regular);
        txt(std.fmt.allocPrint(a, "{d}×{d}", .{ @as(u32, @intFromFloat(d.bg_size[0])), @as(u32, @intFromFloat(d.bg_size[1])) }) catch "", 12, theme.dim, font_mod.regular);
    };
    if (app.game_dir.len > 0) txt(std.fs.path.basename(app.game_dir), 12, theme.dim, font_mod.regular);
    txt(std.fmt.allocPrint(a, "OpenGorky Editor", .{}) catch "", 12, theme.dim, font_mod.regular);
    clay.close();
}

/// "New location / battle from this one": opens a name field, its hint and the Make button.
fn newLevelRow(app: *App, a: Allocator, battle: bool) void {
    if (app_mod.buttonWide(app, "level_new", tx.get(if (battle) tx.lv_new_battle else tx.lv_new), false)) app.level_naming = !app.level_naming;
    if (!app.level_naming) return;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .top = 2 }, .childGap = 6 } });
    clay.text(tx.get(if (battle) tx.lv_new_battle_hint else tx.lv_new_hint), .{ .textColor = theme.dim, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(26) }, .padding = .{ .left = 8, .right = 8 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.field, .cornerRadius = clay.radius(theme.radius), .border = .{ .color = theme.accent, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } } });
    txt(std.fmt.allocPrint(a, "{s}|", .{app.level_name[0..app.level_name_len]}) catch "", 13, theme.text, font_mod.regular);
    clay.close();
    if (app_mod.button(app, "level_make", tx.get(tx.lv_make), true)) app.level_make = true;
    clay.close();
    clay.close();
}

/// The view mode's right panel: the level's objects (shown and picked only), its Info,
/// and a new level made from this one.
fn objectList(app: *App, a: Allocator) void {
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.fixed(app.split(.objects)), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM },
        .backgroundColor = theme.panel,
        .border = .{ .color = theme.line, .width = .{ .left = 1 } },
    });
    if (inspectorTabs(app)) {
        inspectorHistory(app, a);
        return clay.close();
    }
    const objs: []const level.Obj = if (app.doc) |d| d.objects.items else &.{};
    panelHeader(tx.alloc(a, tx.objects_n, .{objs.len}));
    clay.openScroll(.{ .id = clay.id("objects"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 8 } } });
    objectRows(app, a, false);
    clay.close();
    if (app.doc) |d| {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 10 }, .childGap = 6 }, .border = .{ .color = theme.line, .width = .{ .top = 1 } } });
        txt(tx.get(tx.info_title), 14, theme.text, font_mod.bold);
        infoblock.show(app, infoblock.rows(app, std.fmt.allocPrint(a, "level:{s}", .{d.name}) catch d.name, d, levelInfo));
        newLevelRow(app, a, d.isBattle());
        clay.close();
    }
    clay.close();
}

/// The level's Info: its script, what it includes, the other levels' scripts and the
/// scenes naming it (an exit, LOADLEVEL).
fn levelInfo(d: *level.Doc, app: *App, list: *infoblock.List) void {
    const entry = app.store.files.items[d.lev].entry;
    list.add(.{ .group = .file, .text = list.fmt("{s} · {s}", .{ d.level_archive, entry }), .to = .{ .code = .{ .archive = d.level_archive, .entry = entry } }, .icon = .code });
    infoblock.includes(app, list, d.level_archive, app.store.text(d.lev), 4);
    const needle = list.fmt("\"{s}\"", .{d.name});
    const n = list.rows.items.len;
    infoblock.levelsNaming(app, list, needle);
    // Its own scripts name it too (not a use).
    for (list.rows.items[n..], n..) |r, k| if (r.to == .level and std.ascii.eqlIgnoreCase(r.to.level.name, d.name)) {
        _ = list.rows.orderedRemove(k);
        break;
    };
    infoblock.scenesNaming(app, list, needle, "");
}

/// The Debug run's panel in the inspector's place.
fn logicPanel(app: *App, a: Allocator, v: *logicview.View) void {
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.fixed(app.split(.objects)), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM },
        .backgroundColor = theme.panel,
        .border = .{ .color = theme.line, .width = .{ .left = 1 } },
    });
    logicview.panel(app, a, v);
    clay.close();
}

/// Over the level: in the view mode its actions (edit it, its script, its battle lines)
/// and what is shown; in the edit mode the tools and Done. Fit and the zoom on the right.
fn levelToolbar(app: *App, a: Allocator, d: *level.Doc) void {
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(44) }, .padding = .{ .left = 8, .right = 8 }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        // Clipped: a narrow window cuts the bar rather than widening the window.
        .clip = .{ .horizontal = true },
        .backgroundColor = theme.header,
        .border = .{ .color = theme.line, .width = .{ .bottom = 1 } },
    });
    // The level's script in a tab of its own (the level's tab kept, not replaced).
    var script = false;
    if (app.paint) |p| {
        paint.toolbar(app, p);
        script = app_mod.toolButton(app, "level_code", .code, tx.get(tx.code_level), false, false);
    } else {
        if (app_mod.toolButton(app, "level_paint", .pencil, tx.get(tx.lp_open), false, true)) app.openPaint();
        script = app_mod.toolButton(app, "level_code", .code, tx.get(tx.code_level), false, false);
        if (app_mod.toolButton(app, "level_debug", .play, tx.get(tx.lt_open), logicview.of(app) != null, false)) {
            if (logicview.of(app) != null) logicview.close(app) else logicview.run(app);
            app.rendered.on = false;
        }
        // The level as the game draws it (models, light, depth), nothing of the editor's over it.
        if (app_mod.toolButton(app, "level_preview", .eye, tx.get(tx.show_rendered), app.rendered.on, false)) {
            app.rendered.on = !app.rendered.on;
            if (app.rendered.on) {
                if (logicview.of(app) != null) logicview.close(app);
                app.selected = null;
                app.menu = null;
            }
        }
        if (d.isBattle()) if (app_mod.toolButton(app, "battle_lines", .message_square, tx.get(tx.sc_battle_open), false, false)) app.showDialog(std.fmt.allocPrint(a, "{s}.dlg", .{d.name}) catch "");
    }
    if (script) {
        doctabs.keepCurrent(app);
        codeview.open(app, d.lev, null);
    }
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    if (app.paint == null and !d.isBattle() and !app.rendered.on) {
        // Where heroes can walk (a box put there can be reached).
        const wid = clay.id("show_walk");
        clay.open(.{ .id = wid, .layout = .{ .padding = .{ .left = 6, .right = 8 }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
        if (clay.hovered() and app.clicked) app.show_walk = !app.show_walk;
        checkbox(app, app.show_walk);
        txt(tx.get(tx.show_walk), 13, theme.text, font_mod.regular);
        clay.close();
    }
    if (app_mod.toolButton(app, "view_fit", .maximize, tx.get(tx.tb_fit), false, false)) d.fitted = false;
    txt(std.fmt.allocPrint(a, "{d:.0}%", .{d.zoom * 100}) catch "", 13, theme.dim, font_mod.regular);
    if (app.paint != null) if (app_mod.toolButton(app, "lp_done", .check, tx.get(tx.lp_done), false, true)) app.closePaint();
    clay.close();
}

/// A tick box (drawn; the row around it takes the click).
pub fn checkbox(app: *App, on: bool) void {
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.fixed(16), .height = clay.fixed(16) }, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = if (on) theme.accent else theme.field,
        .cornerRadius = clay.radius(4),
        .border = .{ .color = if (on) theme.accent else theme.field_border, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } },
    });
    if (on) icons.leaf(app.r, app.gpa, .check, 12, theme.text);
    clay.close();
}

/// The edit mode's Objects tool panel: how to edit, the level's objects (a right
/// click on a row: its menu), the picked enemy's values, fighters nobody places.
pub fn objectsBlock(app: *App, a: Allocator) void {
    const d = app.doc orelse return;
    clay.text(tx.get(if (d.isBattle()) tx.lp_objects_hint_battle else tx.lp_objects_hint), .{ .textColor = theme.text, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    // Files of fighters nobody places (an older editor's removals): offered for deletion.
    const orphans = d.orphans(a) catch &.{};
    if (orphans.len > 0) {
        clay.text(tx.alloc(a, tx.orphans, .{std.mem.join(a, ", ", orphans) catch ""}), .{ .textColor = theme.warn, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
        if (app_mod.button(app, "purge", tx.get(tx.orphans_drop), false)) app.askDelete(.purge, 0, std.mem.join(a, ", ", orphans) catch "");
    }
    if (app.selected) |i| if (i < d.objects.items.len) selectedCard(app, a, d, i);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM }, .border = .{ .color = theme.line, .width = .{ .top = 1, .bottom = 1 } } });
    objectRows(app, a, true);
    clay.close();
    if (app.selectedEnemy()) |en| params(app, a, en);
}

/// The picked object (as the concept's inspector): name, kind, lock; where it is; a
/// box's contents; its script.
fn selectedCard(app: *App, a: Allocator, d: *level.Doc, i: usize) void {
    const o = d.objects.items[i];
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 10, .right = 10, .top = 10, .bottom = 10 }, .childGap = 8 }, .backgroundColor = theme.header, .cornerRadius = clay.radius(theme.radius) });
    txt(tx.get(tx.so_title), 13, theme.dim, font_mod.bold);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    const col = level.Doc.kindColor(o.kind);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(14), .height = clay.fixed(14) } }, .backgroundColor = .{ .r = @floatFromInt(col[0]), .g = @floatFromInt(col[1]), .b = @floatFromInt(col[2]), .a = 255 }, .cornerRadius = clay.radius(3) });
    txt(o.name, 15, theme.text, font_mod.bold);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    txt(kindName(d, o), 12, theme.dim, font_mod.regular);
    const locked = app.locked.contains(o.name);
    const lid = clay.id("so_lock");
    clay.open(.{ .id = lid, .layout = .{ .sizing = .{ .width = clay.fixed(24), .height = clay.fixed(24) }, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = if (clay.pointerOver(lid)) theme.button_hover else theme.header, .cornerRadius = clay.radius(4) });
    if (clay.hovered() and app.clicked) app.toggleLocked(o.name);
    icons.leaf(app.r, app.gpa, if (locked) .lock else .lock_open, 15, if (locked) theme.warn else theme.dim);
    clay.close();
    clay.close();
    const where = if (o.tile) |t| tx.alloc(a, tx.so_tile, .{ t[0], t[1] }) else if (o.grid) |g| tx.alloc(a, tx.so_grid, .{ g[0], g[1] }) else tx.alloc(a, tx.so_pos, .{ o.pos[0], o.pos[1] });
    txt(where, 13, theme.text, font_mod.regular);
    // The model it stands as (an actor's `meshFile`; the map shows only its marker).
    const own_file: ?usize = o.file orelse if (scriptOf(d, o.name)) |entry| app.store.file(d.level_archive, entry) catch null else null;
    if (own_file) |f| if (vars.getStr(app.store.text(f), "meshFile")) |mesh| {
        if (app.preview.draw(app.gpa, app.io, app.dat, app.r, .{ .ctx = app, .get = pages.overlayGet }, mesh, "", null, entry_model.ridersOn(app, a, if (app.catalog.classOf(app.store.text(f))) |e| e.riders.items else &.{}, ""))) |tex| {
            clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(220), .height = clay.fixed(220) } }, .image = .{ .imageData = tex } });
        } else txt(tx.get(tx.no_model), 13, theme.warn, font_mod.regular);
    };
    // A box: what is in it.
    if (d.boxFile(o.name)) |f| {
        const items = @import("box.zig").parse(a, app.store.text(f)) catch &.{};
        txt(tx.alloc(a, tx.so_contents, .{items.len}), 13, theme.dim, font_mod.bold);
        for (items) |it| {
            const n = if (it.count) |cn| cn else @as(i32, @intCast(it.names.items.len));
            // The item's name in the game where the catalog knows it.
            const title = for (app.catalog.entries.items) |e| {
                if (e.title.len > 0 and std.ascii.endsWithIgnoreCase(e.entry, it.class)) break e.title;
            } else std.fs.path.stem(it.class);
            txt(std.fmt.allocPrint(a, "{s}  ×{d}", .{ title, n }) catch it.class, 13, theme.text, font_mod.regular);
        }
        if (app_mod.toolButton(app, "so_contents", .box, tx.get(tx.cm_edit_contents), false, false)) app.box = .{ .file = f, .name = o.name };
    }
    // Its script: its own file, or the level script's line placing it.
    if (scriptOf(d, o.name)) |entry| {
        if (app_mod.toolButton(app, "so_script", .code, entry, false, false)) if (app.store.file(d.level_archive, entry)) |f| codeview.open(app, f, null) else |_| {};
    } else if (o.call) |ci| if (app_mod.toolButton(app, "so_script", .code, tx.get(tx.cm_reveal), false, false)) codeview.open(app, d.lev, d.script.calls[ci].stmt.start);
    clay.close();
}

/// The level's objects by kind (as the concept's scene tree): a group per kind, its
/// rows by name; the eyes hide them in the view; a click picks one, in the edit mode a
/// right click opens its menu.
fn objectRows(app: *App, a: Allocator, edit: bool) void {
    const d = app.doc orelse return;
    const objs = d.objects.items;
    // Allies first, then enemies, the rest after.
    const order = [_]level.Kind{ .hero, .enemy, .neutral, .actor, .item, .prop, .area };
    const names = [_]tx.Msg{ tx.ok_heroes, tx.ok_enemies, tx.ok_neutral, tx.ok_actors, tx.ok_items, tx.ok_props, tx.ok_areas };
    for (order, names) |kind, title| {
        var n: usize = 0;
        for (objs) |o| n += @intFromBool(o.kind == kind);
        if (n == 0) continue;
        const kkey = std.fmt.allocPrint(a, "kind:{t}", .{kind}) catch continue;
        const ckey = std.fmt.allocPrint(a, "objclosed/{t}", .{kind}) catch continue;
        const open = !app.tree_open.contains(ckey);
        const kind_shown = !app.view_hidden.contains(kkey);
        const gid = clay.idi("obj_group", @backingInt(kind));
        _ = app_mod.clickable(app, .{ .id = gid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(28) }, .padding = .{ .left = 8, .right = 8 }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel }, false);
        const g_over = clay.hovered();
        icons.leaf(app.r, app.gpa, if (open) .chevron_down else .chevron_right, 13, theme.dim);
        icons.leaf(app.r, app.gpa, .folder, 15, theme.dim);
        txt(tx.get(title), 13, theme.text, font_mod.bold);
        txt(std.fmt.allocPrint(a, "({d})", .{n}) catch "", 12, theme.dim, font_mod.regular);
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
        const g_eye = eyeToggle(app, clay.idi("obj_geye", @backingInt(kind)), kind_shown);
        clay.close();
        // The eye hides the kind; the row folds it (`objclosed/<kind>` kept while folded).
        if (g_eye) app.toggleHidden(kkey) else if (g_over and app.clicked) @import("assettree.zig").toggleKey(app, ckey);
        if (!open) continue;
        // Rows by name; reinforcements after the starting ones.
        var rows: std.ArrayList(usize) = .empty;
        for (objs, 0..) |o, i| if (o.kind == kind) rows.append(a, i) catch {};
        std.mem.sort(usize, rows.items, objs, struct {
            fn f(os: []const level.Obj, x: usize, y: usize) bool {
                if ((os[x].later == null) != (os[y].later == null)) return os[x].later == null;
                return std.ascii.lessThanIgnoreCase(os[x].name, os[y].name);
            }
        }.f);
        for (rows.items) |i| {
            const o = objs[i];
            const sel = app.selected != null and app.selected.? == i;
            const rid = clay.idi("obj", @intCast(i));
            _ = app_mod.clickable(app, .{
                .id = rid,
                .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(28) }, .padding = .{ .left = 34, .right = 8 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
                .backgroundColor = theme.panel,
                .cornerRadius = clay.radius(4),
            }, sel);
            const over = clay.hovered();
            const col: [3]u8 = if (o.later != null) .{ 150, 150, 150 } else Doc.kindColor(o.kind);
            clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(10), .height = clay.fixed(10) } }, .backgroundColor = .{ .r = @floatFromInt(col[0]), .g = @floatFromInt(col[1]), .b = @floatFromInt(col[2]), .a = 255 }, .cornerRadius = clay.radius(2) });
            const locked = d.isBattle() and o.call == null;
            txt(o.name, 14, if (locked or o.later != null) theme.dim else theme.text, if (sel) font_mod.bold else font_mod.regular);
            if (locked) txt(tx.get(tx.scripted), 12, theme.dim, font_mod.regular);
            if (o.later) |m| txt(if (m == 0) tx.get(tx.later) else tx.get(tx.later_alt), 12, theme.dim, font_mod.regular);
            if (o.added) txt(tx.get(tx.new), 12, theme.accent_hover, font_mod.regular);
            if (o.hidden) txt(tx.get(tx.hero_hidden), 12, theme.dim, font_mod.regular);
            clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
            const eye = eyeToggle(app, clay.idi("obj_eye", @intCast(i)), kind_shown and !app.view_hidden.contains(o.name));
            clay.close();
            if (eye) app.toggleHidden(o.name) else if (over and app.clicked) app.selected = i;
            if (edit and over and app.right_clicked) app.openMenuFor(i);
        }
    }
    // The level's sprites and the sounds it plays (folded at first).
    levelanims.group(app, a, d);
    @import("levelvars.zig").group(app, a, d);
    @import("levelmedia.zig").groups(app, a, d);
}

/// An eye at the end of a row (shown or not); true when clicked.
fn eyeToggle(app: *App, eid: ui.Clay_ElementId, shown: bool) bool {
    clay.open(.{ .id = eid, .layout = .{ .sizing = .{ .width = clay.fixed(24), .height = clay.fixed(24) }, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } } });
    const hit = clay.hovered() and app.clicked;
    icons.leaf(app.r, app.gpa, if (shown) .eye else .eye_off, 16, if (shown) theme.accent_hover else theme.dim);
    clay.close();
    return hit;
}

fn params(app: *App, a: Allocator, en: level.Enemy) void {
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM },
        .border = .{ .color = theme.line, .width = .{ .top = 1 } },
    });
    panelHeader(tx.alloc(a, tx.params_of, .{en.name}));
    // This enemy's own values; its class (every such enemy) is edited on its page.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fit() }, .padding = .{ .left = 12, .right = 12, .top = 4, .bottom = 4 } } });
    txt(tx.get(tx.scope_one_hint), 12, theme.dim, font_mod.regular);
    clay.close();
    // No scroll of its own: the edit mode's panel scrolls (nested, the wheel went to this one).
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .bottom = 8 } } });
    var row: u32 = 0;
    for (fighter_stats) |st| {
        statRow(app, a, row, tx.get(st.label), st, en.ftr, en.class, "#include ft_");
        row += 1;
    }
    {
        const id: i32 = if (app.doc) |d| (if (d.world.rt.findObject(en.name)) |o| o.getInt("nameID") else 0) else 0;
        pages.resistBlock(id, 2);
    }
    for (0..en.n_wpn) |k| {
        const w = app.store.files.items[en.wpn[k]].entry;
        const label = tx.alloc(a, damage_stat.label, .{w[0 .. w.len - 4]});
        statRow(app, a, row, label, damage_stat, en.wpn[k], en.wpn_class[k], "#include wp_");
        pages.weaponChoice(app, a, en.wpn[k], en.wpn_class[k]);
        row += 1;
    }
    clay.close();
    clay.close();
}

/// One parameter: this enemy's value (its class's until set; click to type a new one)
/// and, for an own value, × to drop it.
fn statRow(app: *App, a: Allocator, row: u32, label: []const u8, st: Stat, own: usize, class: ?usize, include: []const u8) void {
    const own_v = vars.get(app.store.text(own), st.names[0]);
    const class_v = if (class) |ci| vars.get(app.store.text(ci), st.names[0]) else null;
    const v = own_v orelse class_v;
    const strong = own_v != null;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(24) }, .padding = .{ .left = 12, .right = 8 }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    txt(label, 13, theme.dim, font_mod.regular);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    valueCell(app, a, row, own, st.names, include, v, strong, strong);
    const rid = clay.idi("reset", row);
    clay.open(.{ .id = rid, .layout = .{ .sizing = .{ .width = clay.fixed(16), .height = clay.fixed(20) }, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } } });
    if (own_v != null) {
        if (clay.hovered() and app.clicked) app.store.unsetVar(own, st.names) catch |err| app.setStatus(tx.st_set_failed, .{err});
        txt("×", 15, if (clay.pointerOver(rid)) theme.warn else theme.dim, font_mod.bold);
    }
    clay.close();
    clay.close();
}

fn drawViewport(ctx: *anyopaque, data: ?*anyopaque, rect: c.SDL_FRect) void {
    const app: *App = @ptrCast(@alignCast(ctx));
    // The sprite page's canvas carries its Edit, the code editor's text area its View.
    if (data) |p| if (app.spr) |e| if (p == @as(*anyopaque, e)) return sprview.draw(app, e, rect);
    if (data) |p| if (p == @as(*anyopaque, &app.scenes.preview)) return scenepage.drawPreview(app, rect);
    if (data) |p| if (p == @as(*anyopaque, &app.video)) return @import("videopage.zig").draw(app, rect);
    if (data) |p| if (p != ctx) return codeview.draw(app, @ptrCast(@alignCast(p)), rect);
    const d = app.doc orelse {
        const msg = tx.get(tx.no_level);
        const w = app.font.measure(msg, font_mod.regular, 18)[0];
        app.font.draw(app.r, msg, font_mod.regular, 18, rect.x + (rect.w - w) / 2, rect.y + rect.h / 2 - 10, .{ 120, 124, 132, 255 });
        return;
    };
    d.view_hidden = &app.view_hidden;
    const clip: c.SDL_Rect = .{ .x = @intFromFloat(rect.x), .y = @intFromFloat(rect.y), .w = @intFromFloat(rect.w), .h = @intFromFloat(rect.h) };
    if (app.paint) |p| paint.draw(app, p, d, rect) else {
        // Made before the clip: it draws into textures of its own.
        const game_look = if (app.rendered.on) renderedLevel(app, d) else null;
        _ = c.SDL_SetRenderClipRect(app.r, &clip);
        if (game_look) |t| {
            // The preview: the game's picture alone.
            if (!d.fitted) d.fit(rect);
            const o = d.toScreen(rect, .{ 0, 0 });
            _ = c.SDL_RenderTexture(app.r, t, null, &.{ .x = o[0], .y = o[1], .w = d.bg_size[0] * d.zoom, .h = d.bg_size[1] * d.zoom });
            if (renderedDetail(app, d, rect)) |dt| {
                const p = d.toScreen(rect, .{ @floatFromInt(dt.key[0]), @floatFromInt(dt.key[1]) });
                _ = c.SDL_RenderTexture(app.r, dt.tex, null, &.{ .x = p[0], .y = p[1], .w = @as(f32, @floatFromInt(dt.key[2])) * d.zoom, .h = @as(f32, @floatFromInt(dt.key[3])) * d.zoom });
            }
            _ = c.SDL_SetRenderClipRect(app.r, null);
            return;
        }
        d.grid_hidden = false;
        d.draw(app.r, app.font, rect, app.selected, app.show_walk, true);
        if (logicview.of(app)) |v| logicview.draw(app, d, v, rect);
    }
    // The bitmap animations over it (outlines, the picked one's frame).
    _ = c.SDL_SetRenderClipRect(app.r, &clip);
    levelanims.draw(app, d, rect);
    _ = c.SDL_SetRenderClipRect(app.r, null);
}

/// The open level as the game draws it a second after it starts (its world read from
/// the saved files): made once per load of the level; null if it can't be.
fn renderedLevel(app: *App, d: *level.Doc) ?*c.SDL_Texture {
    const rd = &app.rendered;
    if (rd.of == d.serial) return rd.tex;
    dropRendered(app);
    rd.of = d.serial;
    if (rd.models == null) rd.models = og.actor.model_cache.Cache.open(app.io, app.gpa, app.dat) catch |err| {
        app.setStatus(tx.st_render_failed, .{err});
        return null;
    };
    const sc = @import("viewer").Scene.init(app.io, app.gpa, app.r, app.dat, &rd.models.?, d.name, 30) catch |err| {
        app.setStatus(tx.st_render_failed, .{err});
        return null;
    };
    rd.scene = sc;
    const bs = sc.size();
    rd.tex = sc.draw(app.r, 0, 0, bs[0], bs[1], 1) catch |err| {
        app.setStatus(tx.st_render_failed, .{err});
        return null;
    };
    return rd.tex;
}

/// The preview's pictures and scene gone (another level, the editor closing).
fn dropRendered(app: *App) void {
    const rd = &app.rendered;
    if (rd.tex) |t| c.SDL_DestroyTexture(t);
    if (rd.detail) |t| c.SDL_DestroyTexture(t);
    if (rd.scene) |sc| sc.deinit();
    rd.tex = null;
    rd.detail = null;
    rd.scene = null;
    rd.detail_key = .{ 0, 0, 0, 0, 0 };
}

/// Zoomed in past the whole picture's pixels: the visible part drawn again with the
/// models at the window's pixels (once the view has rested: a pan or zoom in progress
/// shows the whole picture scaled). Its texture and background rectangle, or null.
fn renderedDetail(app: *App, d: *level.Doc, rect: c.SDL_FRect) ?struct { tex: *c.SDL_Texture, key: [5]u32 } {
    const rd = &app.rendered;
    const sc = rd.scene orelse return null;
    var sx: f32 = 1;
    var sy: f32 = 1;
    _ = c.SDL_GetRenderScale(app.r, &sx, &sy);
    // Window pixels per background pixel; the layer's detail is a whole number (≤ 4, the viewer's).
    const k: u32 = @intFromFloat(std.math.clamp(@ceil(d.zoom * sx - 0.05), 1, 4));
    if (k <= 1) return null;
    const bs = sc.size();
    const a = d.toBackground(rect, .{ rect.x, rect.y });
    const b = d.toBackground(rect, .{ rect.x + rect.w, rect.y + rect.h });
    const clampTo = struct {
        fn f(v: f32, hi: u32) u32 {
            return @intFromFloat(std.math.clamp(v, 0, @as(f32, @floatFromInt(hi))));
        }
    }.f;
    const x0 = clampTo(@floor(a[0]), bs[0]);
    const y0 = clampTo(@floor(a[1]), bs[1]);
    const x1 = clampTo(@ceil(b[0]), bs[0]);
    const y1 = clampTo(@ceil(b[1]), bs[1]);
    if (x1 <= x0 or y1 <= y0) return null;
    const key: [5]u32 = .{ x0, y0, x1 - x0, y1 - y0, k };
    const now = c.SDL_GetTicks();
    if (!std.mem.eql(u32, &key, &rd.view_key)) {
        rd.view_key = key;
        rd.moved_ms = now;
        rd.still_frames = 0;
    } else rd.still_frames +|= 1;
    // Rested: 150 ms, or 30 frames (a scripted run's frames take no time).
    if (!std.mem.eql(u32, &key, &rd.detail_key) and (now - rd.moved_ms > 150 or rd.still_frames >= 30)) {
        if (rd.detail) |t| c.SDL_DestroyTexture(t);
        rd.detail = sc.draw(app.r, key[0], key[1], key[2], key[3], k) catch null;
        rd.detail_key = key;
    }
    // A finer picture made for another detail is not shown (zoomed out since).
    if (rd.detail_key[4] != k) return null;
    return .{ .tex = rd.detail orelse return null, .key = rd.detail_key };
}

pub fn frame(app: *App, size: [2]f32, wheel: [2]f32) clay.Commands {
    _ = app.frame.reset(.retain_capacity);
    // The window as it is now (resized, full screen): the confirmation's shade covers it.
    app.size = size;
    @import("convert.zig").poll(app);
    if (app.paint) |p| paint.runPending(app, p);
    app.followLink();
    if (app.hero_drop.len > 0) {
        var nb: [48]u8 = undefined;
        const n = nb[0..app.hero_drop.len];
        @memcpy(n, app.hero_drop.get());
        app.hero_drop.len = 0;
        app.removeHero(n);
    }
    if (app.level_make) {
        app.level_make = false;
        app.newLevel(app.level_name[0..app.level_name_len]);
    }
    // A click anywhere commits the number being typed (a click on a value starts the next).
    if (app.clicked) app.commitEditing();
    // A click off the asset search leaves it (its text stays).
    if (app.clicked and !clay.pointerOver(clay.id("tree_search")) and !clay.pointerOver(clay.id("top_search"))) app.tree_focus = false;
    if (app.clicked and !clay.pointerOver(clay.id("anim_search"))) app.anim_focus = false;
    app.dragSplit();
    if (app.clicked and clay.pointerOver(clay.id("preview_img"))) app.turning = app.mouse[0];
    // The menu and the box window take clicks on them; one elsewhere only closes them.
    if (app.confirm != null and app.clicked and !clay.pointerOver(clay.id("confirm"))) {
        app.confirm = null;
        app.clicked = false;
    }
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
    if (!app.overlay() and (app.tab == .battles or app.tab == .locations)) if (app.doc) |d| if (App.viewportRect()) |v| if (app.overViewport()) viewport: {
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
    app.num_seen = false;
    textedit.clickAway(app);
    layout(app);
    textedit.afterLayout(app);
    app.text_given = null;
    if (!app.num_seen) app.num_edit = null;
    app.applyCursor();
    return clay.end();
}

pub fn present(app: *App, cmds: clay.Commands) void {
    _ = c.SDL_SetRenderDrawColor(app.r, 0, 0, 0, 255);
    _ = c.SDL_RenderClear(app.r);
    render.draw(app.r, app.font, cmds, drawViewport, app);
}

fn shot(app: *App, path: []const u8) !void {
    const raw = c.SDL_RenderReadPixels(app.r, null) orelse return error.ReadPixels;
    defer c.SDL_DestroySurface(raw);
    const surf = c.SDL_ConvertSurface(raw, c.SDL_PIXELFORMAT_ABGR8888) orelse return error.Convert;
    defer c.SDL_DestroySurface(surf);
    var img = try og.formats.image.Image.init(app.gpa, @intCast(surf.*.w), @intCast(surf.*.h));
    defer img.deinit(app.gpa);
    const src: [*]const u8 = @ptrCast(surf.*.pixels.?);
    const stride = img.width * 4;
    for (0..img.height) |y| @memcpy(img.pixels[y * stride ..][0..stride], src[y * @as(usize, @intCast(surf.*.pitch)) ..][0..stride]);
    var out: Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();
    try og.formats.png.write(app.gpa, &out.writer, img);
    try Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = out.written() });
}

/// One edit flag with its arguments (`--move NAME X Y`: the object to corner tile
/// (X, Y), or grid point for a prop; `--set[-class] NAME FIELD VALUE`: an enemy's own
/// value or its class's).
/// Window (and macOS Dock) icon: assets/icon-editor-256.png, embedded in the binary.
fn setWindowIcon(gpa: Allocator, window: *c.SDL_Window) void {
    var img = og.formats.jpeg.decode(gpa, @embedFile("icon_png")) catch return;
    defer img.deinit(gpa);
    const surf = c.SDL_CreateSurfaceFrom(@intCast(img.width), @intCast(img.height), c.SDL_PIXELFORMAT_ABGR8888, img.pixels.ptr, @intCast(img.width * 4)) orelse return;
    defer c.SDL_DestroySurface(surf);
    _ = c.SDL_SetWindowIcon(window, surf);
}

/// The directory has a dat folder, so it looks like a game directory.
fn isGameDir(io: Io, path: []const u8) bool {
    if (path.len == 0) return false;
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    defer d.close(io);
    var dat = d.openDir(io, "dat", .{}) catch return false;
    dat.close(io);
    return true;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var game_dir: ?[]const u8 = null;
    var start_level: ?[]const u8 = null;
    var shot_path: ?[]const u8 = null;
    var save_after = false;
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
        } else if (std.mem.eql(u8, a, "--lang") and i + 1 < args.len) {
            i += 1;
            lang_arg = std.meta.stringToEnum(tx.Lang, args[i]) orelse return error.BadLanguage;
        } else if (std.mem.eql(u8, a, "--tab") and i + 1 < args.len) {
            i += 1;
            tab_arg = std.meta.stringToEnum(Tab, args[i]) orelse return error.BadTab;
        } else if (cli.find(a)) |o| {
            if (i + o.arity >= args.len) return cli.fail("{s}: {d} value(s) missing", .{ a, o.arity });
            try edits.append(gpa, args[i .. i + 1 + o.arity]);
            i += o.arity;
        } else if (std.mem.eql(u8, a, "--save")) {
            save_after = true;
        } else if (std.mem.eql(u8, a, "--help")) {
            return cli.fail("", .{});
        } else if (std.mem.startsWith(u8, a, "--")) {
            return cli.fail("unknown option {s}", .{a});
        } else game_dir = a;
    }
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
    if (game) |g| if (!isGameDir(io, g)) {
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
    const flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | (if (headless) c.SDL_WINDOW_HIDDEN else 0);
    if (!c.SDL_CreateWindowAndRenderer(tx.get(tx.title).ptr, 1400, 880, flags, &window, &renderer)) return error.SdlWindow;
    setWindowIcon(gpa, window.?);
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
        start = .{ .remember = true };
    }
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
fn session(gpa: Allocator, io: Io, window: *c.SDL_Window, r: *c.SDL_Renderer, font: *Font, settings: *Settings, settings_path: ?[]const u8, game: ?[]const u8, start: Start) !?[]const u8 {
    var game_root: ?Io.Dir = if (game) |g| try Io.Dir.cwd().openDir(io, g, .{}) else null;
    defer if (game_root) |*d| d.close(io);
    if (game_root) |d| og.formats.adjust.load(io, d);
    var dat_dir: ?Io.Dir = if (game_root) |d| try d.openDir(io, "dat", .{ .iterate = true }) else null;
    defer if (dat_dir) |*d| d.close(io);
    // Without a game nothing reads it: no levels, an empty catalog.
    const dat = dat_dir orelse Io.Dir.cwd();
    const levels = if (dat_dir != null) try level.listLevels(io, gpa, dat) else try gpa.alloc(level.LevelEntry, 0);
    defer {
        for (levels) |e| gpa.free(e.name);
        gpa.free(levels);
    }
    const templates = if (dat_dir != null) try level.listTemplates(io, gpa, dat, levels) else try gpa.alloc(level.Template, 0);
    defer {
        level.freeTemplates(gpa, templates);
        gpa.free(templates);
    }
    var level_names: std.ArrayList([]const u8) = .empty;
    defer level_names.deinit(gpa);
    for (levels) |e| try level_names.append(gpa, e.name);
    var app: App = .{
        .gpa = gpa,
        .window = window,
        .io = io,
        .r = r,
        .font = font,
        .dat = dat,
        .game_dir = game orelse "",
        .levels = levels,
        .templates = templates,
        .store = .{ .gpa = gpa, .io = io, .dat = dat },
        .catalog = if (dat_dir != null) try catalog.Catalog.build(io, gpa, dat, level_names.items) else .{ .arena = .init(gpa) },
        .sprites = if (dat_dir != null) og.formats.archive.Archive.open(io, gpa, dat, "common/sprite.dat") catch null else null,
        .frame = .init(gpa),
    };
    defer app.frame.deinit();
    defer app.store.deinit();
    if (dat_dir != null) app.store.loadPast();
    defer app.catalog.deinit();
    defer app.preview.deinit();
    defer {
        dropRendered(&app);
        if (app.rendered.models) |*m| m.deinit();
    }
    defer app.player.deinit(gpa);
    defer if (app.fonts.edit) |*fe| fe.deinit(gpa);
    defer {
        var it = app.effect.tex.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            if (kv.value_ptr.*) |t| c.SDL_DestroyTexture(t);
        }
        app.effect.tex.deinit(gpa);
    }
    defer {
        for (app.models.items) |m| gpa.free(m);
        app.models.deinit(gpa);
    }
    defer {
        var it = app.anims.tex.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            if (kv.value_ptr.*) |t| c.SDL_DestroyTexture(t);
        }
        app.anims.tex.deinit(gpa);
    }
    defer {
        for (app.music.list.items) |m| gpa.free(m);
        app.music.list.deinit(gpa);
    }
    defer app.dropReport();
    defer {
        logicview.close(&app);
        app.logic.cmds.deinit(gpa);
    }
    defer if (app.level_media) |*m| m.deinit();
    defer {
        if (app.code) |v| v.destroy(gpa);
        for (app.code_parked.items) |v| v.destroy(gpa);
        app.code_parked.deinit(gpa);
        app.scenes.preview.names.deinit(gpa);
        @import("videopage.zig").stop(&app);
        @import("convert.zig").wait(&app);
    }
    defer {
        for (app.menu_refs.items) |ref| gpa.free(ref.label);
        app.menu_refs.deinit(gpa);
        app.setClip(null);
        var it = app.locked.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        app.locked.deinit(gpa);
    }
    defer {
        for (app.video.list.items) |v| gpa.free(v);
        app.video.list.deinit(gpa);
    }
    defer checkpanel.close(&app);
    defer assettree.deinit(&app);
    defer infoblock.deinit();
    defer {
        var it = app.view_hidden.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        app.view_hidden.deinit(gpa);
    }
    defer for (app.cursors) |cur| if (cur) |k| c.SDL_DestroyCursor(k);
    defer if (app.sprites) |*ar| ar.close(io, gpa);
    defer {
        var it = app.icons.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            if (kv.value_ptr.*) |t| c.SDL_DestroyTexture(t);
        }
        app.icons.deinit(gpa);
    }
    defer if (app.doc) |d| d.deinit();
    defer {
        for (app.parked.items) |pk| if (pk.doc) |d| d.deinit();
        app.parked.deinit(gpa);
        app.paint_left.deinit(gpa);
    }
    defer if (app.spr) |e| e.destroy(gpa);
    defer if (app.paint) |p| p.destroy(gpa);
    app.settings = settings.*;
    app.settings_path = settings_path;
    defer settings.* = app.settings;
    if (game == null) app.tab = .settings;
    // Remember a folder given on the command line or picked (not by checks and scripts).
    if (start.remember and !start.headless) if (game_root) |gr| {
        var real_buf: [1024]u8 = undefined;
        const n = gr.realPath(io, &real_buf) catch 0;
        app.settings.setGamePath(if (n > 0) real_buf[0..n] else game.?);
        app.saveSettings();
    };

    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSize(window, &w, &h);
    app.size = .{ @floatFromInt(w), @floatFromInt(h) };

    if (start.level) |name| for (levels, 0..) |e, k| {
        if (!std.ascii.eqlIgnoreCase(e.name, name)) continue;
        app.open(k, false);
        app.tab = if (e.battle) .battles else .locations;
    };
    if (start.tab) |t| app.tab = t;

    if (start.headless) {
        for (start.edits) |op| {
            try scripted.run(&app, op);
            doctabs.sync(&app);
        }
        if (start.save) app.save();
        std.debug.print("{s}\n", .{app.status});
        if (start.shot) |path| {
            // Layout needs a previous frame for element boxes (viewport fit, hover).
            for (0..3) |_| present(&app, frame(&app, .{ @floatFromInt(w), @floatFromInt(h) }, .{ 0, 0 }));
            try shot(&app, path);
        }
        return null;
    }

    var running = true;
    while (running) {
        app.clicked = false;
        app.right_clicked = false;
        var wheel: [2]f32 = .{ 0, 0 };
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) {
            switch (ev.type) {
                c.SDL_EVENT_QUIT => running = !confirmQuit(&app),
                c.SDL_EVENT_MOUSE_MOTION => {
                    const m: [2]f32 = .{ ev.motion.x, ev.motion.y };
                    if (app.code) |v| if (v.dragging) codeview.pointer(&app, v, m, true);
                    if (app.sprShown()) |e| if (e.painting) sprview.pointer(e, m, false);
                    if (app.paint) |p| if (p.painting) if (app.doc) |d| if (App.viewportRect()) |v| paint.drag(&app, p, d.toBackground(v, m));
                    if (app.paint) |p| if (p.light_drag != null) if (app.doc) |d| if (App.viewportRect()) |v| paint.lightDrag(p, d, d.toBackground(v, m));
                    if (app.paint) |p| if (p.area_from != null) if (app.doc) |d| if (App.viewportRect()) |v| paint.areaDrag(p, d.toBackground(v, m));
                    if (app.paint) |p| if (p.cam_ring != null) if (app.doc) |d| if (App.viewportRect()) |v| paint.cameraDrag(p, d, v, m);
                    if (app.turning) |*x| {
                        app.preview.yaw -= (m[0] - x.*) * 0.6;
                        x.* = m[0];
                    }
                    if (app.doc) |d| {
                        if (app.paths.drag != null) {
                            if (App.viewportRect()) |v| paths.drag(&app, d, v, m);
                        } else if (app.anims.drag) |*dr| {
                            if (App.viewportRect()) |v| {
                                const bg = d.toBackground(v, m);
                                dr.at = .{ @round(bg[0] - dr.off[0]), @round(bg[1] - dr.off[1]) };
                            }
                        } else if (app.moving) |mi| {
                            if (App.viewportRect()) |v| d.drag(v, mi, m);
                        } else if (app.pan) |*last| {
                            d.origin[0] -= (m[0] - last[0]) / d.zoom;
                            d.origin[1] -= (m[1] - last[1]) / d.zoom;
                            last.* = m;
                        }
                    }
                    app.mouse = m;
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => if (ev.button.button == c.SDL_BUTTON_LEFT) {
                    app.down = true;
                    app.clicked = true;
                    if (app.code) |v| if (codeview.over(v, app.mouse)) {
                        codeview.press(&app, v, app.mouse, ev.button.clicks, c.SDL_GetModState());
                        v.dragging = true;
                    };
                    if (app.sprShown()) |e| if (sprview.over(e, app.mouse)) {
                        e.painting = true;
                        sprview.pointer(e, app.mouse, false);
                    };
                } else if (app.sprShown()) |e| {
                    // The right button on the icon: the eyedropper.
                    if (sprview.over(e, app.mouse)) sprview.pointer(e, app.mouse, true);
                } else if (!app.overlay() and (app.tab == .battles or app.tab == .locations)) {
                    // Right or middle drag pans the level; a right click opens the menu
                    // (on the level, or on a row of the object list).
                    if (app.overViewport()) app.pan = app.mouse;
                    if (ev.button.button == c.SDL_BUTTON_RIGHT) app.right_down = app.mouse;
                },
                c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    if (ev.button.button == c.SDL_BUTTON_LEFT) {
                        app.down = false;
                        app.turning = null;
                        if (app.code) |v| {
                            v.dragging = false;
                        }
                        if (app.spr) |e| if (e.painting) sprview.release(&app, e);
                        if (app.paint) |p| paint.release(&app, p);
                        if (app.paint) |p| paint.lightRelease(&app, p);
                        if (app.paint) |p| paint.cameraRelease(&app, p);
                        // Last: a moved area reloads the level, this Paint with it.
                        if (app.paint) |p| paint.areaRelease(&app, p);
                    }
                    if (ev.button.button == c.SDL_BUTTON_RIGHT) if (app.right_down) |p| {
                        app.right_down = null;
                        if (@abs(p[0] - app.mouse[0]) + @abs(p[1] - app.mouse[1]) < 4) {
                            if (app.overViewport()) {
                                if (app.editingObjects()) app.openMenu();
                            } else app.right_clicked = true;
                        }
                    };
                    app.pan = null;
                    if (app.paths.drag != null) if (app.doc) |d| paths.release(&app, d);
                    if (app.anims.drag) |dr| {
                        app.anims.drag = null;
                        if (app.doc) |d| levelanims.place(&app, d, dr.name(), dr.at);
                    }
                    if (app.moving != null) {
                        app.moving = null;
                        if (app.doc) |d| d.drop() catch |err| switch (err) {
                            error.NotWalkable => app.setStatus(tx.st_not_walkable, .{}),
                            error.TileNotFree => app.setStatus(tx.st_no_tile, .{}),
                            else => app.setStatus(tx.st_move_failed, .{err}),
                        };
                    }
                },
                c.SDL_EVENT_MOUSE_WHEEL => if (app.code != null and codeview.over(app.code.?, app.mouse)) {
                    codeview.wheel(app.code.?, ev.wheel.y);
                } else {
                    wheel = .{ wheel[0] + ev.wheel.x, wheel[1] + ev.wheel.y };
                },
                c.SDL_EVENT_TEXT_INPUT => if (app.editing == null and app.text_edit == null and app.code != null and !app.tree_focus) {
                    codeview.typed(app.code.?, std.mem.span(ev.text.text));
                } else app.typed(std.mem.span(ev.text.text)),
                c.SDL_EVENT_KEY_DOWN => if (app.confirm != null and (ev.key.key == c.SDLK_RETURN or ev.key.key == c.SDLK_KP_ENTER or ev.key.key == c.SDLK_ESCAPE)) {
                    // The confirmation window: Enter deletes, Esc keeps.
                    if (ev.key.key == c.SDLK_ESCAPE) app.confirm = null else app.confirmed();
                } else if (app.text_edit != null and (ev.key.key == c.SDLK_BACKSPACE or ev.key.key == c.SDLK_RETURN or ev.key.key == c.SDLK_KP_ENTER or ev.key.key == c.SDLK_ESCAPE or (ev.key.key == c.SDLK_V and (ev.key.mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI)) != 0))) {
                    // The text field typed into.
                    switch (ev.key.key) {
                        c.SDLK_BACKSPACE => textedit.backspace(&app),
                        c.SDLK_ESCAPE => app.text_edit = null,
                        c.SDLK_V => if (c.SDL_GetClipboardText()) |p| {
                            defer c.SDL_free(p);
                            textedit.typed(&app, std.mem.span(p));
                        },
                        else => textedit.enter(&app),
                    }
                } else if (app.editing) |*e| switch (ev.key.key) {
                    c.SDLK_RETURN, c.SDLK_KP_ENTER, c.SDLK_TAB => app.commitEditing(),
                    c.SDLK_ESCAPE => app.stopEditing(),
                    c.SDLK_BACKSPACE => e.len = search.dropLast(e.buf[0..e.len]).len,
                    else => {},
                } else if (app.code != null and !app.tree_focus and codeview.key(&app, app.code.?, ev.key.key, ev.key.mod)) {
                    // The code editor took it.
                } else if (app.scenes.naming and (ev.key.key == c.SDLK_BACKSPACE or ev.key.key == c.SDLK_RETURN or ev.key.key == c.SDLK_KP_ENTER or ev.key.key == c.SDLK_ESCAPE)) {
                    switch (ev.key.key) {
                        c.SDLK_BACKSPACE => app.scenes.name.len -|= 1,
                        c.SDLK_ESCAPE => app.scenes.naming = false,
                        else => {
                            app.scenes.naming = false;
                            if (app.sceneName()) |old| app.renameScene(old, app.scenes.name.get());
                        },
                    }
                } else if (app.anim_focus and (ev.key.key == c.SDLK_BACKSPACE or ev.key.key == c.SDLK_RETURN or ev.key.key == c.SDLK_KP_ENTER or ev.key.key == c.SDLK_ESCAPE)) {
                    switch (ev.key.key) {
                        c.SDLK_BACKSPACE => app.anim_query.len = search.dropLast(app.anim_query.get()).len,
                        c.SDLK_ESCAPE => {
                            app.anim_query.len = 0;
                            app.anim_focus = false;
                        },
                        else => app.anim_focus = false,
                    }
                } else if (app.tree_focus and (ev.key.key == c.SDLK_BACKSPACE or ev.key.key == c.SDLK_RETURN or ev.key.key == c.SDLK_KP_ENTER or ev.key.key == c.SDLK_ESCAPE)) {
                    // The asset search: Esc empties it (and leaves), Enter leaves.
                    switch (ev.key.key) {
                        c.SDLK_BACKSPACE => app.tree_query.len = search.dropLast(app.treeQuery()).len,
                        c.SDLK_ESCAPE => {
                            app.tree_query.len = 0;
                            app.tree_focus = false;
                        },
                        else => app.tree_focus = false,
                    }
                } else if (app.num_edit != null and (ev.key.key == c.SDLK_BACKSPACE or ev.key.key == c.SDLK_RETURN or ev.key.key == c.SDLK_KP_ENTER or ev.key.key == c.SDLK_ESCAPE or ev.key.key == c.SDLK_TAB)) {
                    const e = &app.num_edit.?;
                    switch (ev.key.key) {
                        c.SDLK_BACKSPACE => e.len -|= 1,
                        c.SDLK_ESCAPE => app.num_edit = null,
                        else => e.done = true,
                    }
                } else if (app.level_naming and (ev.key.key == c.SDLK_BACKSPACE or ev.key.key == c.SDLK_RETURN or ev.key.key == c.SDLK_KP_ENTER or ev.key.key == c.SDLK_ESCAPE)) {
                    switch (ev.key.key) {
                        c.SDLK_BACKSPACE => app.level_name_len -|= 1,
                        c.SDLK_ESCAPE => app.level_naming = false,
                        else => app.level_make = true,
                    }
                } else if (app.paint != null and app.paint.?.renaming and (ev.key.key == c.SDLK_BACKSPACE or ev.key.key == c.SDLK_RETURN or ev.key.key == c.SDLK_KP_ENTER or ev.key.key == c.SDLK_ESCAPE)) {
                    paint.nameKey(&app, app.paint.?, ev.key.key);
                } else if (app.searching() and (ev.key.key == c.SDLK_BACKSPACE or ev.key.key == c.SDLK_DELETE)) {
                    // Keys of the search field.
                    if (ev.key.key == c.SDLK_BACKSPACE) app.query_len = search.dropLast(app.query()).len;
                } else if (app.text_edit != null and (ev.key.mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI)) == 0) {
                    // Typing in a text field: plain keys are letters, not shortcuts.
                } else {
                    const cmd = (ev.key.mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI)) != 0;
                    switch (ev.key.key) {
                        c.SDLK_S => if (cmd) app.save(),
                        c.SDLK_K => if (cmd) {
                            app.tree_focus = true;
                        },
                        // In the edit mode: its strokes, then (none left) the edits before
                        // it, the level read again.
                        c.SDLK_Z => if (cmd) if (app.paint) |p| {
                            if (!paint.undo(&app, p)) {
                                app.undo();
                                app.reloadLevel();
                            }
                        } else app.undo(),
                        // Enter: a drawn area finished, else the picked box's contents opened.
                        c.SDLK_RETURN, c.SDLK_KP_ENTER => if (app.paint) |p| if (p.poly.items.len > 0 or !levelKeys(&app)) paint.finishArea(&app, p) else if (app.doc) |d| if (app.selected) |i| if (d.boxFile(d.objects.items[i].name)) |f| {
                            app.box = .{ .file = f, .name = d.objects.items[i].name };
                        },
                        c.SDLK_DELETE, c.SDLK_BACKSPACE => if (app.paint) |p| {
                            // A closed outline opens again first; the Objects tool removes the picked.
                            if (p.tool == .objects) askRemoveSelected(&app) else if (p.poly_closed) p.poly_closed = false else _ = p.poly.pop();
                        },
                        c.SDLK_ESCAPE => if (app.paint != null and app.paint.?.poly.items.len > 0) {
                            app.paint.?.poly.clearRetainingCapacity();
                            app.paint.?.poly_closed = false;
                        } else {
                            app.menu = null;
                            app.box = null;
                            app.trigger = null;
                            app.moving = null;
                            if (app.doc) |d| d.preview = null;
                        },
                        // F: the picked object centred (none: the whole level fitted).
                        c.SDLK_F => if (app.doc) |d| if (App.viewportRect()) |v| if (app.selected) |i| app.centreOn(d.objects.items[i].pos) else d.fit(v),
                        // Copy, duplicate, paste: the picked object while editing the level's
                        // objects, else the open document (a tree row's copy).
                        c.SDLK_C => if (cmd) if (levelKeys(&app)) (if (app.selected) |i| app.copyObject(i)) else if (treemenu.current(&app)) |it| treemenu.copy(&app, it),
                        c.SDLK_D => if (cmd) if (levelKeys(&app)) (if (app.selected) |i| app.duplicate(i)) else if (treemenu.current(&app)) |it| treemenu.duplicate(&app, it),
                        c.SDLK_V => if (cmd) if (levelKeys(&app)) (if (app.doc) |d| if (App.viewportRect()) |v| app.paste(d.toBackground(v, app.mouse), d.gridAt(v, app.mouse))) else if (app.tree_clip) |it| treemenu.duplicate(&app, it),
                        c.SDLK_F2 => if (levelKeys(&app)) if (app.doc) |d| if (app.selected) |i| if (d.objects.items[i].kind == .area) renameArea(&app, d.objects.items[i].name),
                        else => {},
                    }
                },
                c.SDL_EVENT_WINDOW_RESIZED => _ = c.SDL_GetWindowSize(window, &w, &h),
                else => {},
            }
        }
        if (app.takeDialog()) |d| app.fileChosen(d.ask, d.path);
        if (app.takeGame()) |g| {
            if (isGameDir(io, g)) return g;
            app.setStatus(tx.st_no_dat, .{});
        }
        present(&app, frame(&app, .{ @floatFromInt(w), @floatFromInt(h) }, wheel));
        app.syncTextInput();
        _ = c.SDL_RenderPresent(r);
    }
    return null;
}

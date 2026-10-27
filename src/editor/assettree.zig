//! The project's assets on the left, a tree for every editor: locations and battles
//! (by chapter), characters (heroes, enemies), items (weapons, ammo, items), scenes
//! with the dialogues no scene starts and the shared scripts, media (sounds, videos). Folders open and close; the search
//! keeps the matching rows (their folders open). A row opens its editor.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const icons = @import("icons.zig");
const search = @import("search.zig");
const pages = @import("pages.zig");
const catalog = @import("catalog.zig");
const videopage = @import("videopage.zig");
const codeview = @import("codeview.zig");
const refs = @import("refs.zig");
const treemenu = @import("treemenu.zig");
const sprview = @import("sprview.zig");
const sprite_archive = @import("store.zig").sprite_archive;
const common_archive = @import("store.zig").common_archive;
const main = @import("app.zig");
const App = main.App;
const Tab = main.Tab;
const theme = main.theme;
const txt = main.txt;

const row_h = 26;

/// Folder `key` open (search: every folder with a match is).
fn isOpen(app: *App, key: []const u8) bool {
    if (app.treeQuery().len > 0) return true;
    return app.tree_open.contains(key);
}

/// Key `key` in the open set (folders) on or off.
pub fn toggleKey(app: *App, key: []const u8) void {
    toggle(app, key);
}

fn toggle(app: *App, key: []const u8) void {
    if (app.tree_open.fetchRemove(key)) |kv| return app.gpa.free(kv.key);
    const k = app.gpa.dupe(u8, key) catch return;
    app.tree_open.put(app.gpa, k, {}) catch app.gpa.free(k);
}

/// A folder `key` opened (the selection inside it shown).
fn reveal(app: *App, key: []const u8) void {
    if (!app.tree_open.contains(key)) toggle(app, key);
}

pub fn deinit(app: *App) void {
    var it = app.tree_open.keyIterator();
    while (it.next()) |k| app.gpa.free(k.*);
    app.tree_open.deinit(app.gpa);
}

var row_n: u32 = 0;

/// A folder row: chevron, icon, title, count; true when clicked (it toggles itself).
fn folder(app: *App, a: Allocator, key: []const u8, depth: u32, ic: ?icons.Icon, title: []const u8, n: usize) bool {
    row_n += 1;
    const rid = clay.idi("tree_row", row_n);
    const open = isOpen(app, key);
    _ = main.clickable(app, .{
        .id = rid,
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(row_h) }, .padding = .{ .left = @intCast(8 + depth * 16), .right = 10 }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = theme.panel,
    }, false);
    const hit = clay.hovered() and app.clicked;
    icons.leaf(app.r, app.gpa, if (open) .chevron_down else .chevron_right, 14, theme.dim);
    icons.leaf(app.r, app.gpa, ic orelse .folder, 16, if (ic == null) theme.dim else theme.accent_hover);
    txt(title, 14, theme.text, if (depth == 0) font_mod.bold else font_mod.regular);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    // maxInt: not counted (its archive is read only when open).
    if (n != std.math.maxInt(usize)) txt(std.fmt.allocPrint(a, "({d})", .{n}) catch "", 12, theme.dim, font_mod.regular);
    clay.close();
    if (hit and app.treeQuery().len == 0) toggle(app, key);
    return open;
}

/// A leaf row: an icon (a sprite or a UI icon), its name and a dim second name.
/// `item`: what its right-click menu acts on (none: no menu).
fn leaf(app: *App, depth: u32, img: ?*anyopaque, ic: icons.Icon, name: []const u8, sub: []const u8, selected: bool, item: ?treemenu.Item) bool {
    row_n += 1;
    const rid = clay.idi("tree_row", row_n);
    _ = main.clickable(app, .{
        .id = rid,
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(if (img != null) 30 else row_h) }, .padding = .{ .left = @intCast(8 + depth * 16 + 20), .right = 10 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = theme.panel,
        .cornerRadius = clay.radius(4),
    }, selected);
    const hit = clay.hovered() and app.clicked;
    if (clay.hovered() and app.right_clicked) if (item) |it| {
        treemenu.open(app, it);
        app.right_clicked = false;
    };
    if (img) |t| clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(24), .height = clay.fixed(24) } }, .image = .{ .imageData = t } }) else icons.leaf(app.r, app.gpa, ic, 15, if (selected) theme.text else theme.dim);
    txt(name, 14, theme.text, if (selected) font_mod.bold else font_mod.regular);
    if (sub.len > 0) txt(sub, 12, if (selected) theme.text else theme.dim, font_mod.regular);
    clay.close();
    return hit;
}

/// Chapter of a level name: `01_port_castle` → `01_port`, `01__port_park` → `01_port`.
pub fn chapter(name: []const u8) []const u8 {
    var parts: u32 = 0;
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        if (name[i] != '_') continue;
        // `01__port`: the double underscore of battles counts once.
        if (i + 1 < name.len and name[i + 1] == '_') continue;
        parts += 1;
        if (parts == 2) return name[0..i];
    }
    return name;
}

test chapter {
    try std.testing.expectEqualStrings("01_port", chapter("01_port_castle"));
    try std.testing.expectEqualStrings("01_port", chapter("01_port"));
    try std.testing.expectEqualStrings("01__port", chapter("01__port_park"));
    try std.testing.expectEqualStrings("05_laboratory", chapter("05_laboratory_duty"));
}

fn matches(app: *App, names: []const []const u8) bool {
    return search.matches(app.treeQuery(), names);
}

pub fn panel(app: *App, a: Allocator) void {
    row_n = 0;
    revealSelection(app, a);
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.fixed(app.split(.levels)), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM },
        .backgroundColor = theme.panel,
        .border = .{ .color = theme.line, .width = .{ .right = 1 } },
    });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(40) }, .padding = .{ .left = 14, .right = 10 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    txt(tx.get(tx.at_title), 15, theme.text, font_mod.bold);
    clay.close();
    searchBox(app, a, "tree_search", tx.get(tx.at_search), false);
    clay.openScroll(.{ .id = clay.id("assets"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 8 } } });
    levels(app, a, false);
    levels(app, a, true);
    entries(app, a, "chars", .user, tx.get(tx.at_characters), &.{ .{ "hero", tx.at_heroes }, .{ "enemy", tx.at_enemies } });
    entries(app, a, "items", .package, tx.get(tx.at_items), &.{ .{ "weapon", tx.at_weapons }, .{ "ammo", tx.at_ammo }, .{ "item", tx.at_things }, .{ "attack", tx.at_attacks } });
    scenes(app, a);
    scripts(app, a);
    media(app, a);
    sprites(app, a);
    textsFolder(app, a);
    clay.close();
    clay.close();
}

/// A new selection (a level opened from a link, an entry, a scene): its folders open.
fn revealSelection(app: *App, a: Allocator) void {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&app.tab));
    h.update(std.mem.asBytes(&app.current));
    h.update(std.mem.asBytes(&app.entry));
    h.update(std.mem.asBytes(&app.scene));
    h.update(app.scenes.dlg.get());
    const k = h.final();
    if (k == app.tree_seen) return;
    app.tree_seen = k;
    switch (app.tab) {
        .battles, .locations => if (app.current) |i| {
            const top = if (app.levels[i].battle) "battles" else "locations";
            reveal(app, top);
            reveal(app, std.fmt.allocPrint(a, "{s}/{s}", .{ top, chapter(app.levels[i].name) }) catch return);
        },
        .enemies, .heroes, .items => if (app.entry) |i| {
            const e = app.catalog.entries.items[i];
            const top = if (e.kind == .enemy or e.kind == .hero) "chars" else "items";
            reveal(app, top);
            reveal(app, std.fmt.allocPrint(a, "{s}/{s}", .{ top, group(e) }) catch return);
        },
        .scenes => {
            reveal(app, "scenes");
            if (app.scenes.dlg.len > 0) reveal(app, if (isIdle(app.scenes.dlg.get())) "scenes/idle" else "scenes/lines");
        },
        .sounds, .videos => {
            reveal(app, "media");
            reveal(app, if (app.tab == .sounds) "media/sounds" else "media/videos");
        },
        else => {},
    }
}

/// The search field (`top`: the top bar's, ⌘K); both type into the tree's query.
pub fn searchBox(app: *App, a: Allocator, id: []const u8, hint: []const u8, top: bool) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = if (top) clay.fixed(460) else clay.grow() }, .padding = if (top) .{} else .{ .left = 10, .right = 10, .bottom = 8 } } });
    const fid = clay.id(id);
    const focus = app.tree_focus;
    clay.open(.{
        .id = fid,
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(32) }, .padding = .{ .left = 10, .right = 8 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = theme.field,
        .cornerRadius = clay.radius(theme.radius),
        .border = .{ .color = if (focus) theme.accent else theme.field_border, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } },
    });
    if (clay.hovered() and app.clicked) app.tree_focus = true;
    icons.leaf(app.r, app.gpa, .search, 16, theme.dim);
    const q = app.treeQuery();
    if (q.len > 0 or focus) txt(std.fmt.allocPrint(a, "{s}{s}", .{ q, if (focus) "|" else "" }) catch q, 14, theme.text, font_mod.regular) else txt(hint, 14, theme.dim, font_mod.regular);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    if (top) {
        clay.open(.{ .layout = .{ .padding = .{ .left = 6, .right = 6, .top = 2, .bottom = 2 } }, .backgroundColor = theme.button, .cornerRadius = clay.radius(4), .border = .{ .color = theme.button_edge, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } } });
        txt(if (@import("builtin").os.tag == .macos) "Cmd K" else "Ctrl K", 11, theme.dim, font_mod.regular);
        clay.close();
    }
    clay.close();
    clay.close();
}

fn levels(app: *App, a: Allocator, battle: bool) void {
    var n: usize = 0;
    for (app.levels) |lv| n += @intFromBool(lv.battle == battle and matches(app, &.{lv.name}));
    if (n == 0 and app.treeQuery().len > 0) return;
    const top = if (battle) "battles" else "locations";
    if (!folder(app, a, top, 0, if (battle) .swords else .map_pin, tx.get(if (battle) tx.at_battles else tx.at_locations), n)) return;
    var i: usize = 0;
    while (i < app.levels.len) {
        const ch = chapter(app.levels[i].name);
        // This chapter's levels of this kind (the list is sorted by name).
        var j = i;
        var count: usize = 0;
        while (j < app.levels.len and std.mem.eql(u8, chapter(app.levels[j].name), ch)) : (j += 1) {
            count += @intFromBool(app.levels[j].battle == battle and matches(app, &.{app.levels[j].name}));
        }
        defer i = j;
        if (count == 0) continue;
        const key = std.fmt.allocPrint(a, "{s}/{s}", .{ top, ch }) catch continue;
        const shown = std.mem.replaceOwned(u8, a, ch, "__", "_") catch ch;
        if (!folder(app, a, key, 1, null, shown, count)) continue;
        for (app.levels[i..j], i..) |lv, k| {
            if (lv.battle != battle or !matches(app, &.{lv.name})) continue;
            const sel = app.current != null and app.current.? == k and (app.tab == .battles) == battle;
            if (leaf(app, 2, null, if (battle) .swords else .file_text, lv.name, "", sel, .of(.level, lv.name))) {
                app.setTab(if (battle) .battles else .locations);
                if (!sel) app.requestOpen(k);
            }
        }
    }
}

fn tabOf(k: catalog.Kind) Tab {
    return switch (k) {
        .enemy => .enemies,
        .hero => .heroes,
        else => .items,
    };
}

/// An entry's tree group (`chars/<group>`): its kind; heroes that never join the party
/// (battle allies) go with the enemies, the other non-party characters.
fn group(e: catalog.Entry) []const u8 {
    return if (e.ally) "enemy" else @tagName(e.kind);
}

fn entries(app: *App, a: Allocator, key: []const u8, ic: icons.Icon, title: []const u8, groups: []const struct { []const u8, tx.Msg }) void {
    const all = app.catalog.entries.items;
    var n: usize = 0;
    for (all) |e| {
        for (groups) |g| n += @intFromBool(std.mem.eql(u8, group(e), g[0]) and matches(app, &.{ e.title, e.id }));
    }
    if (n == 0 and app.treeQuery().len > 0) return;
    if (!folder(app, a, key, 0, ic, title, n)) return;
    for (groups) |g| {
        var c: usize = 0;
        for (all) |e| c += @intFromBool(std.mem.eql(u8, group(e), g[0]) and matches(app, &.{ e.title, e.id }));
        if (c == 0) continue;
        const sub = std.fmt.allocPrint(a, "{s}/{s}", .{ key, g[0] }) catch continue;
        if (!folder(app, a, sub, 1, null, tx.get(g[1]), c)) continue;
        for (all, 0..) |e, i| {
            if (!std.mem.eql(u8, group(e), g[0]) or !matches(app, &.{ e.title, e.id })) continue;
            const sel = app.tab == tabOf(e.kind) and app.entry != null and app.entry.? == i;
            const img: ?*anyopaque = if (e.kind == .hero) null else app.icon(pages.iconOf(app, e));
            // Its name in the game and in scripts only (where it is defined: its Info).
            if (leaf(app, 2, img, if (e.kind == .attack) .swords else .user, if (e.title.len > 0) e.title else e.id, if (e.title.len > 0) e.id else "", sel, .of(.entry, e.id))) {
                app.setTab(tabOf(e.kind));
                app.entry = i;
                app.picker = null;
            }
        }
    }
}

fn scenes(app: *App, a: Allocator) void {
    const list = app.catalog.scenes.items;
    var n: usize = 0;
    for (list) |sc| n += @intFromBool(matches(app, &.{sc.name}));
    var lines: usize = 0;
    for (app.levels) |lv| lines += @intFromBool(lv.battle and matches(app, &.{lv.name}));
    if (n + lines == 0 and app.treeQuery().len > 0) return;
    if (!folder(app, a, "scenes", 0, .clapperboard, tx.get(tx.at_scenes), list.len)) return;
    if (addRow(app, 1, tx.sc_new)) app.newScene();
    for (list, 0..) |sc, i| {
        if (!matches(app, &.{sc.name})) continue;
        const sel = app.tab == .scenes and app.scenes.dlg.len == 0 and app.scene != null and app.scene.? == i;
        if (leaf(app, 1, null, .clapperboard, sc.name, "", sel, .of(.scene, sc.name))) {
            app.setTab(.scenes);
            app.scene = i;
            app.scenes.dlg.len = 0;
            app.scenes.naming = false;
        }
    }
    // Dialogues no scene starts: before each battle (`<battle>.dlg`).
    if (lines > 0 and folder(app, a, "scenes/lines", 1, null, tx.get(tx.sc_battle_lines), lines)) for (app.levels) |lv| {
        if (!lv.battle or !matches(app, &.{lv.name})) continue;
        const name = std.fmt.allocPrint(a, "{s}.dlg", .{lv.name}) catch continue;
        const sel = app.tab == .scenes and std.ascii.eqlIgnoreCase(app.scenes.dlg.get(), name);
        if (leaf(app, 2, null, .file_text, name, "", sel, null)) app.showDialog(name);
    };
    // The heroes' idle remarks (the exe's `idle_<code>_01`).
    var ar = og.formats.archive.Archive.open(app.io, app.gpa, app.dat, "common/lang.dat") catch return;
    defer ar.close(app.io, app.gpa);
    var idle: usize = 0;
    for (ar.entries) |e| idle += @intFromBool(isIdle(e.name) and matches(app, &.{e.name}));
    if (idle == 0 or !folder(app, a, "scenes/idle", 1, null, tx.get(tx.sc_idle_lines), idle)) return;
    for (ar.entries) |e| {
        if (!isIdle(e.name) or !matches(app, &.{e.name})) continue;
        const sel = app.tab == .scenes and std.ascii.eqlIgnoreCase(app.scenes.dlg.get(), e.name);
        if (leaf(app, 2, null, .file_text, e.name, "", sel, null)) app.showDialog(a.dupe(u8, e.name) catch continue);
    }
}

/// A "+ new …" row (none while searching); true when clicked.
fn addRow(app: *App, depth: u32, label: tx.Msg) bool {
    if (app.treeQuery().len > 0) return false;
    row_n += 1;
    const rid = clay.idi("tree_row", row_n);
    _ = main.clickable(app, .{ .id = rid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(row_h) }, .padding = .{ .left = @intCast(8 + depth * 16 + 20) }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel }, false);
    const hit = clay.hovered() and app.clicked;
    icons.leaf(app.r, app.gpa, .plus, 14, theme.accent_hover);
    txt(tx.get(label), 13, theme.accent_hover, font_mod.regular);
    clay.close();
    return hit;
}

/// Every script, each opening in the code editor: the shared ones levels and classes
/// include (`classes\*.s`, the game's and new ones), the items' and weapons' classes
/// (`ca_`, `ci_`, `cw_`), each level's own (its `other.dat`: `.lev`, `.are`, `.ba`…).
fn scripts(app: *App, a: Allocator) void {
    const shared = classList(app, a, isShared);
    const items = classList(app, a, isItemClass);
    var n: usize = 0;
    for (shared) |e| n += @intFromBool(matches(app, &.{e}));
    for (items) |e| n += @intFromBool(matches(app, &.{e}));
    const searching = app.treeQuery().len > 0;
    if (n == 0 and searching) return;
    if (!folder(app, a, "scripts", 0, .code, tx.get(tx.at_scripts), n)) return;
    if (addRow(app, 1, tx.sc_new_script)) app.newScript();
    if (items.len > 0 and folder(app, a, "scripts/items", 1, null, tx.get(tx.at_items), items.len)) for (items) |e| classRow(app, 2, e);
    // Levels' own: an archive read only when its folder is open (not searched).
    if (!searching and folder(app, a, "scripts/levels", 1, null, tx.get(tx.at_spr_levels), app.levels.len)) for (app.levels) |lv| {
        const key = std.fmt.allocPrint(a, "scripts/levels/{s}", .{lv.name}) catch continue;
        if (!folder(app, a, key, 2, null, lv.name, std.math.maxInt(usize))) continue;
        const archive = std.fmt.allocPrint(a, "{s}/other.dat", .{lv.name}) catch continue;
        for (refs.files(app, a, archive, refs.script)) |f| {
            const open = if (app.code) |v| std.mem.eql(u8, app.store.files.items[v.file].archive, archive) and std.ascii.eqlIgnoreCase(app.store.files.items[v.file].entry, f.name) else false;
            if (leaf(app, 3, null, .code, f.name, "", open, null)) if (app.store.file(archive, f.name)) |i| codeview.open(app, i, null) else |err| app.setStatus(tx.st_open_failed, .{ f.name, err });
        }
    };
    for (shared) |e| classRow(app, 1, e);
}

fn classRow(app: *App, depth: u32, e: []const u8) void {
    if (!matches(app, &.{e})) return;
    const shown = e["classes\\".len..];
    const open = if (app.code) |v| std.mem.eql(u8, app.store.files.items[v.file].archive, common_archive) and std.ascii.eqlIgnoreCase(app.store.files.items[v.file].entry, e) else false;
    if (leaf(app, depth, null, .code, shown, "", open, .of(.script, e))) if (app.store.file(common_archive, e)) |f| codeview.open(app, f, null) else |err| app.setStatus(tx.st_open_failed, .{ shown, err });
}

/// The class scripts `keep` takes: the archive's, then new ones in the Store.
fn classList(app: *App, a: Allocator, keep: *const fn ([]const u8) bool) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var ar = og.formats.archive.Archive.open(app.io, app.gpa, app.dat, common_archive) catch return list.items;
    defer ar.close(app.io, app.gpa);
    for (ar.entries) |e| if (keep(e.name)) list.append(a, a.dupe(u8, e.name) catch continue) catch {};
    for (app.store.files.items, 0..) |f, i| {
        if (!std.mem.eql(u8, f.archive, common_archive) or !keep(f.entry) or app.store.gone(i) or ar.find(f.entry) != null) continue;
        list.append(a, f.entry) catch {};
    }
    return list.items;
}

fn isClass(entry: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(entry, "classes\\") and std.ascii.endsWithIgnoreCase(entry, ".s");
}

fn isItemClass(entry: []const u8) bool {
    if (!isClass(entry)) return false;
    const base = entry["classes\\".len..];
    for ([_][]const u8{ "ca_", "ci_", "cw_" }) |p| if (std.ascii.startsWithIgnoreCase(base, p)) return true;
    return false;
}

fn isShared(entry: []const u8) bool {
    return isClass(entry) and !isItemClass(entry);
}

fn isIdle(name: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(name, "idle_") and std.ascii.endsWithIgnoreCase(name, ".dlg");
}

/// Sounds (common/sound.dat) and videos (avi\\), each with its import row.
fn media(app: *App, a: Allocator) void {
    const snd = app.player.names(app, a);
    const vid = videopage.names(app);
    var ns: usize = 0;
    for (snd) |s| ns += @intFromBool(matches(app, &.{s}));
    var nv: usize = 0;
    for (vid) |v| nv += @intFromBool(matches(app, &.{v}));
    if (ns + nv == 0 and app.treeQuery().len > 0) return;
    if (!folder(app, a, "media", 0, .image, tx.get(tx.at_media), ns + nv)) return;
    if ((ns > 0 or app.treeQuery().len == 0) and folder(app, a, "media/sounds", 1, null, tx.get(tx.at_sounds), ns)) {
        if (addRow(app, 2, tx.snd_import)) {
            app.setTab(.sounds);
            app.askFile(.{ .kind = .sound, .run = @import("soundpage.zig").onSoundIn });
        }
        var shown: usize = 0;
        for (snd) |s| {
            if (!matches(app, &.{s})) continue;
            // shortcut: 400 rows at most; the search narrows the rest.
            shown += 1;
            if (shown > 400) break;
            const sel = app.tab == .sounds and std.ascii.eqlIgnoreCase(s, app.sound_sel.get());
            if (leaf(app, 2, null, .volume_2, s, "", sel, .of(.sound, s))) {
                app.setTab(.sounds);
                app.sound_sel.set(s);
                app.player.playEffect(app, s, true);
            }
        }
    }
    // Weapon and spell effects (their frames).
    const effs = @import("effectpage.zig").names(app, a);
    var ne: usize = 0;
    for (effs) |ef| ne += @intFromBool(matches(app, &.{ef}));
    if ((ne > 0 or app.treeQuery().len == 0) and folder(app, a, "media/effects", 1, null, tx.get(tx.at_effects), ne)) for (effs) |ef| {
        if (!matches(app, &.{ef})) continue;
        const sel = app.tab == .effects and std.ascii.eqlIgnoreCase(app.effect.sel.get(), ef);
        if (leaf(app, 2, null, .image, ef, "", sel, null)) {
            app.setTab(.effects);
            app.effect.sel.set(ef);
        }
    };
    // Music (voice.dat's `.mp3`).
    const mus = @import("musicpage.zig").names(app);
    var nm: usize = 0;
    for (mus) |m| nm += @intFromBool(matches(app, &.{m}));
    if ((nm > 0 or app.treeQuery().len == 0) and folder(app, a, "media/music", 1, null, tx.get(tx.at_music), nm)) {
        if (addRow(app, 2, tx.mus_import)) {
            app.setTab(.music);
            app.askMusic(null);
        }
        for (mus) |m| {
            if (!matches(app, &.{m})) continue;
            const sel = app.tab == .music and std.ascii.eqlIgnoreCase(m, app.music.sel.get());
            if (leaf(app, 2, null, .volume_2, m, "", sel, null)) {
                app.setTab(.music);
                app.music.sel.set(m);
            }
        }
    }
    if ((nv > 0 or app.treeQuery().len == 0) and folder(app, a, "media/videos", 1, null, tx.get(tx.at_videos), nv)) {
        if (addRow(app, 2, tx.vid_import)) {
            app.setTab(.videos);
            app.askFile(.{ .kind = .video, .run = @import("videopage.zig").onVideoIn });
        }
        for (vid) |v| {
            if (!matches(app, &.{v})) continue;
            const sel = app.tab == .videos and std.ascii.eqlIgnoreCase(v, app.video.sel.get());
            if (leaf(app, 2, null, .play, v, "", sel, .of(.video, v))) {
                app.setTab(.videos);
                app.video.sel.set(v);
            }
        }
    }
}

/// 2D pictures (`.spr`): the interface's and the icons (common/sprite.dat), each level's
/// animations (`<level>/sprite.dat`, read when its folder opens); import of new ones.
fn sprites(app: *App, a: Allocator) void {
    const searching = app.treeQuery().len > 0;
    // While searching only common's are looked through (levels' archives stay closed).
    if (!searching and !folder(app, a, "sprites", 0, .image, tx.get(tx.at_sprites), spriteTotal(app, a))) return;
    const common = sprview.entries(app, a, sprite_archive);
    var ui_n: usize = 0;
    var ic_n: usize = 0;
    for (common) |e| {
        if (!matches(app, &.{e})) continue;
        if (std.ascii.startsWithIgnoreCase(e, "icons\\")) ic_n += 1 else ui_n += 1;
    }
    if (searching and ui_n + ic_n == 0) return;
    if (searching and !folder(app, a, "sprites", 0, .image, tx.get(tx.at_sprites), ui_n + ic_n)) return;
    for ([_]bool{ false, true }) |icon_dir| {
        const n = if (icon_dir) ic_n else ui_n;
        if (n == 0 and searching) continue;
        if (!folder(app, a, if (icon_dir) "sprites/icons" else "sprites/ui", 1, null, tx.get(if (icon_dir) tx.at_spr_icons else tx.at_spr_ui), n)) continue;
        if (addRow(app, 2, tx.spr_import_new)) app.askNewSprite(sprite_archive, icon_dir);
        for (common) |e| {
            if (std.ascii.startsWithIgnoreCase(e, "icons\\") != icon_dir or !matches(app, &.{e})) continue;
            const open = if (app.spr) |ed| std.mem.eql(u8, app.store.files.items[ed.file].archive, sprite_archive) and std.ascii.eqlIgnoreCase(ed.name, e) else false;
            const shown = if (icon_dir) e["icons\\".len..] else e;
            if (leaf(app, 2, null, .image, shown, "", open, null)) sprview.openEntry(app, sprite_archive, e) catch |err| app.setStatus(tx.st_open_failed, .{ e, err });
        }
    }
    if (searching or !folder(app, a, "sprites/levels", 1, null, tx.get(tx.at_spr_levels), app.levels.len)) return;
    for (app.levels) |lv| {
        const key = std.fmt.allocPrint(a, "sprites/levels/{s}", .{lv.name}) catch continue;
        if (!folder(app, a, key, 2, null, lv.name, std.math.maxInt(usize))) continue;
        levelSprites(app, a, lv.name, 3);
    }
}

var sprite_total: usize = 0;
var sprite_total_key: [3]usize = .{ std.math.maxInt(usize), 0, 0 };

/// Every sprite (common's and each level's), counted again only when the edits change.
fn spriteTotal(app: *App, a: Allocator) usize {
    // The levels' address: another game folder opened in the same run.
    const now: [3]usize = .{ app.store.undo.items.len, app.store.files.items.len, @intFromPtr(app.levels.ptr) };
    if (std.mem.eql(usize, &now, &sprite_total_key)) return sprite_total;
    sprite_total_key = now;
    sprite_total = sprview.entries(app, a, sprite_archive).len;
    for (app.levels) |lv| {
        const archive = std.fmt.allocPrint(a, "{s}/sprite.dat", .{lv.name}) catch continue;
        sprite_total += sprview.entries(app, a, archive).len;
    }
    return sprite_total;
}

/// Level `name`'s sprites as rows at `depth` (the tree, the level's object list).
fn levelSprites(app: *App, a: Allocator, name: []const u8, depth: u32) void {
    const archive = std.fmt.allocPrint(a, "{s}/sprite.dat", .{name}) catch return;
    if (addRow(app, depth, tx.spr_import_new)) app.askNewSprite(archive, false);
    for (sprview.entries(app, a, archive)) |e| {
        const open = if (app.spr) |ed| std.mem.eql(u8, app.store.files.items[ed.file].archive, archive) and std.ascii.eqlIgnoreCase(ed.name, e) else false;
        if (leaf(app, depth, null, .image, e, "", open, null)) sprview.openEntry(app, archive, e) catch |err| app.setStatus(tx.st_open_failed, .{ e, err });
    }
}

/// The game's texts (common/lang.dat): names and words, item and area descriptions,
/// the credits (opened in the code editor).
fn textsFolder(app: *App, a: Allocator) void {
    const texts = @import("texts.zig");
    const files = [_]struct { ?texts.File, tx.Msg }{ .{ .strings, tx.at_tx_strings }, .{ .items, tx.at_tx_items }, .{ .areas, tx.at_tx_areas }, .{ null, tx.at_tx_credits } };
    var n: usize = 0;
    for (files) |f| n += @intFromBool(matches(app, &.{tx.get(f[1])}));
    if (n == 0 and app.treeQuery().len > 0) return;
    if (!folder(app, a, "texts", 0, .file_text, tx.get(tx.at_texts), files.len)) return;
    // The bitmap fonts (letters of every language).
    const fonts = @import("fontpage.zig").names(app, a);
    if (folder(app, a, "texts/fonts", 1, null, tx.get(tx.at_fonts), fonts.len)) for (fonts) |fname| {
        if (!matches(app, &.{fname})) continue;
        const sel = app.tab == .fonts and std.ascii.eqlIgnoreCase(app.fonts.sel.get(), fname);
        if (leaf(app, 2, null, .file_text, fname, "", sel, null)) {
            app.setTab(.fonts);
            app.fonts.sel.set(fname);
        }
    };
    for (files) |f| {
        if (!matches(app, &.{tx.get(f[1])})) continue;
        const sel = if (f[0]) |tf| app.tab == .texts and app.texts.file == tf else false;
        const sub = if (f[0]) |tf| tf.entry() else "credits.inf";
        if (leaf(app, 1, null, .file_text, tx.get(f[1]), sub, sel, null)) {
            if (f[0]) |tf| {
                app.setTab(.texts);
                app.texts.file = tf;
            } else if (app.store.file(texts.archive, "credits.inf")) |fi| codeview.open(app, fi, null) else |_| {}
        }
    }
    // The engine's tuning values (adjust.kdt in the game root).
    if (matches(app, &.{tx.get(tx.adj_title)}) and leaf(app, 1, null, .settings, tx.get(tx.adj_title), "adjust.kdt", app.tab == .adjust, null)) app.setTab(.adjust);
}

//! The project's assets on the left, a tree for every editor, grouped by tier
//! (kinds.Tier): the assemblies (locations and battles by chapter, characters), the
//! components (items: weapons, ammo, items, attacks; the AI profiles), the assets (scenes
//! with the dialogues no scene starts, scripts, media, sprites, texts), the project's
//! pages (the campaign, rules tables, engine settings; the rules files). Folders open and
//! close; the search keeps the matching rows (their folders open). A row opens its editor.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const icons = @import("icons.zig");
const search = @import("search.zig");
const entries = @import("entries.zig");
const catalog = @import("catalog.zig");
const videopage = @import("videopage.zig");
const doctabs = @import("doctabs.zig");
const kinds = @import("kinds.zig");
const refs = @import("refs.zig");
const treemenu = @import("treemenu.zig");
const sprview = @import("sprview.zig");
const sprite_archive = @import("store.zig").sprite_archive;
const common_archive = @import("store.zig").common_archive;
const app_mod = @import("app.zig");
const App = app_mod.App;
const levelops = @import("levelops.zig");
const Tab = app_mod.Tab;
const theme = app_mod.theme;

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
pub fn reveal(app: *App, key: []const u8) void {
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
    const open = isOpen(app, key);
    // maxInt: not counted (its archive is read only when open).
    const hit = gui.folderRow(app, clay.idi("tree_row", row_n), depth, open, ic orelse .folder, ic != null, title, depth == 0, n, a);
    clay.close();
    if (hit and app.treeQuery().len == 0) toggle(app, key);
    return open;
}

/// A leaf row: an icon (a sprite or a UI icon), its name and a dim second name.
/// `item`: what its right-click menu acts on (none: no menu).
fn leaf(app: *App, depth: u32, img: ?*anyopaque, ic: icons.Icon, name: []const u8, sub: []const u8, selected: bool, item: ?treemenu.Item) bool {
    row_n += 1;
    // A sprite's picture needs a taller row than an icon.
    const hit = gui.listRow(app, clay.idi("tree_row", row_n), .{ .selected = selected, .indent = gui.leafIndent(depth), .h = if (img != null) lay.height.tool else lay.height.control });
    if (clay.hovered() and app.right_clicked) if (item) |it| {
        treemenu.open(app, it);
        app.right_clicked = false;
    };
    if (img) |t| clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lay.icon.lg), .height = clay.fixed(lay.icon.lg) } }, .image = .{ .imageData = t } }) else gui.icon(app, ic, lay.icon.md, if (selected) theme.text else theme.dim);
    gui.openClip(lay.space.sm);
    gui.txt(name, .label, theme.text, if (selected) font_mod.bold else font_mod.regular);
    if (sub.len > 0) gui.txt(sub, .caption, if (selected) theme.text else theme.dim, font_mod.regular);
    clay.close();
    clay.close();
    return hit;
}

/// File `entry` of `archive` is the document shown (code or a sprite: `archive|entry`).
fn fileShown(app: *const App, a: Allocator, tab: Tab, archive: []const u8, entry: []const u8) bool {
    return doctabs.isShown(app, tab, @import("doctab.zig").join(a, archive, entry) catch return false);
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
    gui.sidePanel(app.pane(.levels), .{ .edge = .right });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(lay.height.tab) }, .padding = gui.pad(lay.space.md, 0), .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    gui.txt(tx.get(tx.at_title), .title, theme.text, font_mod.bold);
    clay.close();
    // ⌘K focuses it too.
    gui.searchField(app, a, "tree_search", &app.tree_query, false, tx.get(tx.at_search), if (@import("builtin").os.tag == .macos) "Cmd K" else "Ctrl K");
    clay.openScroll(.{ .id = clay.id("assets"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = lay.space.xs, .right = lay.space.xs, .top = lay.space.xs, .bottom = lay.space.sm } } });
    // The Reference (F1): the scripts' functions, callbacks, hooks, rules, settings.
    if (matches(app, &.{tx.get(tx.ref_title)}) and leaf(app, 0, null, .search, tx.get(tx.ref_title), "F1", doctabs.isShown(app, .reference, ""), null)) doctabs.show(app, .reference, "");
    // The test kit (OpenGorky): the test room's equipment, one for every In battle.
    if (app.ogLayout() and matches(app, &.{tx.get(tx.sec_testkit)}) and leaf(app, 0, null, .package, tx.get(tx.sec_testkit), "", doctabs.isShown(app, .testkit, ""), null)) doctabs.show(app, .testkit, "");
    for (std.enums.values(kinds.Tier)) |t| {
        tierHead(t);
        switch (t) {
            .assembly => {
                levels(app, a, false);
                levels(app, a, true);
                entryFolder(app, a, "chars", .user, tx.get(tx.at_characters), &.{.{ "char", tx.at_characters }});
            },
            .component => {
                entryFolder(app, a, "items", .package, tx.get(tx.at_items), &.{ .{ "weapon", tx.at_weapons }, .{ "ammo", tx.at_ammo }, .{ "item", tx.at_things }, .{ "attack", tx.at_attacks } });
                aiFolder(app, a);
                if (app.ogLayout()) codeFolders(app, a);
                pageRows(app, t);
            },
            .asset => {
                scenes(app, a);
                scripts(app, a);
                media(app, a);
                // OpenGorky: a look is its character's (the character's page shows it, its
                // model a click away).
                looks(app, a);
                sprites(app, a);
                textsFolder(app, a);
            },
            .project => pageRows(app, t),
        }
    }
    filesSection(app, a);
    clay.close();
    clay.close();
}

/// A tier's title over its folders (shown while searching too).
fn tierHead(t: kinds.Tier) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = lay.space.sm, .right = lay.space.sm, .top = lay.space.sm } } });
    gui.subhead(tx.get(t.title()));
    clay.close();
}

/// The pages of their own of tier `t` (kinds with a title: the AI profiles, the campaign,
/// the rules tables, the engine settings), each with the file it edits.
fn pageRows(app: *App, t: kinds.Tier) void {
    for (std.enums.values(Tab)) |tab| {
        const k = kinds.of(tab);
        const title = tx.get(k.title orelse continue);
        if (k.tier != t or !matches(app, &.{title})) continue;
        // OpenGorky's own pages: a Classic project has no game, interface or post-processing
        // page; its experience levels and special values are the game page's.
        if ((tab == .campaign or tab == .ui or tab == .post) and !app.ogLayout()) continue;
        // …and no engine settings page: each one is edited where it lives (ownedpage.zig).
        if ((tab == .exp_levels or tab == .values or tab == .adjust) and app.ogLayout()) continue;
        const file = switch (tab) {
            .campaign => "game.ogs",
            .ui => "ui.ogs",
            .exp_levels, .values => "party.ss",
            .actions => if (app.ogLayout()) "actions.ogs" else "actions.ss",
            .post => "rules/fx.ogs",
            .adjust => if (app.ogLayout()) "rules/settings.ogs" else "adjust.kdt",
            else => "",
        };
        if (leaf(app, 0, null, k.icon, title, file, doctabs.isShown(app, tab, ""), null)) doctabs.show(app, tab, "");
    }
    // OpenGorky: "Build package" — dist/<id>.ogp for players, not played.
    if (t != .project or app.project.format != .ogs) return;
    const title = tx.get(tx.s_build_pkg);
    if (!matches(app, &.{title})) return;
    // Clay draws it after this frame's layout: the frame's memory.
    const pkg = std.fmt.allocPrint(app.frame.allocator(), "dist/{s}.ogp", .{app.project.id()}) catch "dist/";
    if (leaf(app, 0, null, .package, title, pkg, false, null)) @import("play.zig").buildPackage(app);
}

/// A new document shown (a level opened from a link, an entry, a scene): its folders open.
fn revealSelection(app: *App, a: Allocator) void {
    const cur = app.active orelse return;
    const k = std.hash.Wyhash.hash(@backingInt(cur.tab), cur.key());
    if (k == app.tree_seen) return;
    app.tree_seen = k;
    switch (cur.tab) {
        .battles, .locations => if (app.current) |i| {
            const top = if (app.levels[i].battle) "battles" else "locations";
            reveal(app, top);
            reveal(app, std.fmt.allocPrint(a, "{s}/{s}", .{ top, chapter(app.levels[i].name) }) catch return);
        },
        .characters, .items => if (app.entry) |i| {
            const e = app.catalog.entries.items[i];
            const top = if (e.kind == .enemy or e.kind == .hero) "chars" else "items";
            reveal(app, top);
            if (e.kind != .enemy and e.kind != .hero) reveal(app, std.fmt.allocPrint(a, "{s}/{s}", .{ top, group(e) }) catch return);
        },
        .scenes => {
            reveal(app, "scenes");
            if (app.dialogName()) |n| reveal(app, if (isIdle(n)) "scenes/idle" else "scenes/lines");
        },
        .models, .anims, .textures => {
            reveal(app, "looks");
            reveal(app, std.fmt.allocPrint(a, "looks/{s}", .{@tagName(cur.tab)}) catch return);
        },
        .ai_profiles => reveal(app, "ai"),
        .sounds, .videos => {
            reveal(app, "media");
            reveal(app, if (cur.tab == .sounds) "media/sounds" else "media/videos");
        },
        else => {},
    }
}

fn levels(app: *App, a: Allocator, battle: bool) void {
    var n: usize = 0;
    for (app.levels) |lv| n += @intFromBool(lv.battle == battle and matches(app, &.{lv.name}));
    if (n == 0 and app.treeQuery().len > 0) return;
    const top = if (battle) "battles" else "locations";
    const tab: Tab = if (battle) .battles else .locations;
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
        for (app.levels[i..j]) |lv| {
            if (lv.battle != battle or !matches(app, &.{lv.name})) continue;
            const sel = doctabs.isShown(app, tab, lv.name);
            if (leaf(app, 2, null, if (battle) .swords else .file_text, lv.name, "", sel, .of(.level, lv.name))) doctabs.show(app, tab, lv.name);
        }
    }
}

/// `x` before `y` by their letters, case aside (ASCII and Cyrillic: А…Я as а…я, Ё as Е
/// after it), then by their bytes.
fn nameLess(x: []const u8, y: []const u8) bool {
    var ix = std.unicode.Utf8View.initUnchecked(x).iterator();
    var iy = std.unicode.Utf8View.initUnchecked(y).iterator();
    while (true) {
        const cx = ix.nextCodepoint() orelse return iy.nextCodepoint() != null;
        const cy = iy.nextCodepoint() orelse return false;
        const kx = letterKey(cx);
        const ky = letterKey(cy);
        if (kx != ky) return kx < ky;
    }
}

/// A letter's place, case aside: ё/Ё right after е.
fn letterKey(c: u21) u32 {
    var k: u32 = c;
    if (k >= 'A' and k <= 'Z') k += 32;
    if (k >= 0x410 and k <= 0x42F) k += 0x20;
    if (k == 0x401 or k == 0x451) return 0x435 * 2 + 1;
    return k * 2;
}

fn entryName(e: catalog.Entry) []const u8 {
    return if (e.title.len > 0) e.title else e.id;
}

/// An entry's tree group (`items/<group>`): its kind; heroes and enemies are one list.
fn group(e: catalog.Entry) []const u8 {
    return if (e.kind == .hero or e.kind == .enemy) "char" else @tagName(e.kind);
}

fn entryFolder(app: *App, a: Allocator, key: []const u8, ic: icons.Icon, title: []const u8, groups: []const struct { []const u8, tx.Msg }) void {
    const all = app.catalog.entries.items;
    var n: usize = 0;
    for (all) |e| {
        for (groups) |g| n += @intFromBool(std.mem.eql(u8, group(e), g[0]) and matches(app, &.{ e.title, e.id }));
    }
    if (n == 0 and app.treeQuery().len > 0) return;
    if (!folder(app, a, key, 0, ic, title, n)) return;
    // OpenGorky: a character from scratch (Classic: copies only, on a character's page).
    if (std.mem.eql(u8, key, "chars") and app.ogLayout() and addRow(app, 1, tx.new_character)) entries.newCharacter(app) catch |err| app.setStatus(tx.st_copy_failed, .{err});
    // One group: its entries right in the folder.
    const flat = groups.len == 1;
    for (groups) |g| {
        var c: usize = 0;
        for (all) |e| c += @intFromBool(std.mem.eql(u8, group(e), g[0]) and matches(app, &.{ e.title, e.id }));
        if (c == 0) continue;
        const sub = std.fmt.allocPrint(a, "{s}/{s}", .{ key, g[0] }) catch continue;
        if (!flat and !folder(app, a, sub, 1, null, tx.get(g[1]), c)) continue;
        var order: std.ArrayList(usize) = .empty;
        for (all, 0..) |e, i| if (std.mem.eql(u8, group(e), g[0]) and matches(app, &.{ e.title, e.id })) order.append(a, i) catch {};
        // By the name in the game (heroes and enemies mixed in one list), letters by letter
        // whatever their case (Cyrillic too); the ones without a name after, by their id.
        std.mem.sort(usize, order.items, all, struct {
            fn f(es: []const catalog.Entry, x: usize, y: usize) bool {
                const ex = es[x].title.len == 0;
                const ey = es[y].title.len == 0;
                if (ex != ey) return ey;
                return nameLess(entryName(es[x]), entryName(es[y]));
            }
        }.f);
        for (order.items) |i| {
            const e = all[i];
            const k = entries.keyOf(a, e) orelse continue;
            const sel = doctabs.isShown(app, kinds.tabOf(e.kind), k);
            const img: ?*anyopaque = if (e.kind == .hero) null else app.icon(entries.iconOf(app, e));
            // Its name in the game and in scripts only (where it is defined: its Info).
            if (leaf(app, if (flat) 1 else 2, img, if (e.kind == .attack) .swords else .user, entryName(e), if (e.title.len > 0) e.id else "", sel, .of(.entry, k))) doctabs.show(app, kinds.tabOf(e.kind), k);
        }
    }
}

/// The AI profiles (rules ai.ss in force, the exe's in Classic): one document each.
fn aiFolder(app: *App, a: Allocator) void {
    // OpenGorky: the profile blocks (src/ai/*.ogs), each to its page (aipage.zig).
    if (app.ogLayout()) {
        const ps = @import("aipage.zig").profiles(app, a);
        var c: usize = 0;
        for (ps) |p| c += @intFromBool(matches(app, &.{p}));
        if (c == 0 and app.treeQuery().len > 0) return;
        if (!folder(app, a, "ai", 0, .swords, tx.get(tx.aip_title), c)) return;
        for (ps) |p| if (matches(app, &.{p}) and leaf(app, 1, null, .swords, p["ai::".len..], "", doctabs.isShown(app, .ai_profiles, p), null)) doctabs.show(app, .ai_profiles, p);
        return;
    }
    const ea = @import("entry_attacks.zig");
    const list = og.rules.active.ai_profiles;
    var n: usize = 0;
    for (list) |r| n += @intFromBool(matches(app, &.{ea.profileName(a, r)}));
    if (n == 0 and app.treeQuery().len > 0) return;
    if (!folder(app, a, "ai", 0, .swords, tx.get(tx.aip_title), n)) return;
    for (list, 0..) |r, k| {
        const name = ea.profileName(a, r);
        if (!matches(app, &.{name})) continue;
        const key = std.fmt.allocPrint(a, "{d}", .{k}) catch continue;
        if (leaf(app, 1, null, .swords, name, if (r.profile.len > 0) r.profile else r.scoring orelse "", doctabs.isShown(app, .ai_profiles, key), null)) doctabs.show(app, .ai_profiles, key);
    }
}

/// OpenGorky: the project's own traits (the engine's, foundation's, are in the Reference
/// and code navigation) and the components (the project's code's, then the natives), each
/// to its page (traitpage.zig).
fn codeFolders(app: *App, a: Allocator) void {
    const ti = @import("traitinfo.zig");
    const baseName = @import("doctab.zig").baseName;
    const p = ti.load(a);
    var n: usize = 0;
    for (p.traits) |t| n += @intFromBool(matches(app, &.{t.path}));
    if (!(n == 0 and app.treeQuery().len > 0) and folder(app, a, "traits", 0, .layers, tx.get(tx.at_traits), n)) {
        for (p.traits) |t| if (matches(app, &.{t.path}) and leaf(app, 1, null, .layers, t.path, baseName(t.file), doctabs.isShown(app, .traits, t.path), null)) doctabs.show(app, .traits, t.path);
    }
    const natives = og.core.natives.components();
    n = 0;
    for (p.comps) |c| n += @intFromBool(matches(app, &.{c.path}));
    for (natives) |c| n += @intFromBool(matches(app, &.{c.name}));
    if (n == 0 and app.treeQuery().len > 0) return;
    if (!folder(app, a, "code_comps", 0, .code, tx.get(tx.at_code_comps), n)) return;
    // A level's own (the level's and its objects' behaviours, hundreds): under Levels, by level.
    var lvs: std.ArrayList([]const u8) = .empty;
    var in_levels: usize = 0;
    for (p.comps) |c| if (levelOf(c.file)) |l| if (matches(app, &.{c.path})) {
        in_levels += 1;
        for (lvs.items) |x| (if (std.mem.eql(u8, x, l)) break) else lvs.append(a, l) catch {};
    };
    if (in_levels > 0 and folder(app, a, "code_comps/levels", 1, null, tx.get(tx.at_spr_levels), in_levels)) for (lvs.items) |l| {
        var k: usize = 0;
        for (p.comps) |c| k += @intFromBool(isOf(c.file, l) and matches(app, &.{c.path}));
        if (!folder(app, a, std.fmt.allocPrint(a, "code_comps/{s}", .{l}) catch continue, 2, null, l, k)) continue;
        for (p.comps) |c| if (isOf(c.file, l) and matches(app, &.{c.path}) and leaf(app, 3, null, .code, c.path[if (std.mem.lastIndexOf(u8, c.path, "::")) |x| x + 2 else 0..], baseName(c.file), doctabs.isShown(app, .components, c.path), null)) doctabs.show(app, .components, c.path);
    };
    for (p.comps) |c| if (levelOf(c.file) == null and matches(app, &.{c.path}) and leaf(app, 1, null, .code, c.path, baseName(c.file), doctabs.isShown(app, .components, c.path), null)) doctabs.show(app, .components, c.path);
    for (natives) |c| if (matches(app, &.{c.name}) and leaf(app, 1, null, .settings, c.name, tx.get(tx.tr_native), doctabs.isShown(app, .components, c.name), null)) doctabs.show(app, .components, c.name);
}

/// The level whose folder holds `file`: `01_port_store` of
/// `locations/01_port_store/matrix.ogs` (its objects' components, its own block's code).
fn levelOf(file: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, file, '/');
    const top = it.next() orelse return null;
    if (!std.mem.eql(u8, top, "locations") and !std.mem.eql(u8, top, "battles")) return null;
    const name = it.next() orelse return null;
    return if (it.peek() == null) null else name;
}

fn isOf(file: []const u8, level: []const u8) bool {
    return if (levelOf(file)) |x| std.mem.eql(u8, x, level) else false;
}

fn scenes(app: *App, a: Allocator) void {
    const list = app.catalog.scenes.items;
    var n: usize = 0;
    for (list) |sc| n += @intFromBool(matches(app, &.{sc.name}));
    var lines: usize = 0;
    for (app.levels) |lv| lines += @intFromBool(lv.battle and matches(app, &.{lv.name}));
    if (n + lines == 0 and app.treeQuery().len > 0) return;
    if (!folder(app, a, "scenes", 0, .clapperboard, tx.get(tx.at_scenes), list.len)) return;
    if (addRow(app, 1, tx.sc_new)) levelops.newScene(app);
    for (list) |sc| {
        if (!matches(app, &.{sc.name})) continue;
        if (leaf(app, 1, null, .clapperboard, sc.name, "", doctabs.isShown(app, .scenes, sc.name), .of(.scene, sc.name))) doctabs.show(app, .scenes, sc.name);
    }
    // Dialogues no scene starts: before each battle (`<battle>.dlg`).
    if (lines > 0 and folder(app, a, "scenes/lines", 1, null, tx.get(tx.sc_battle_lines), lines)) for (app.levels) |lv| {
        if (!lv.battle or !matches(app, &.{lv.name})) continue;
        const name = std.fmt.allocPrint(a, "{s}.dlg", .{lv.name}) catch continue;
        if (leaf(app, 2, null, .file_text, name, "", doctabs.isShown(app, .scenes, name), null)) doctabs.show(app, .scenes, name);
    };
    // The heroes' idle remarks (the exe's `idle_<code>_01`).
    var ar = og.formats.archive.Archive.open(app.io, app.gpa, app.dat, "common/lang.dat") catch return;
    defer ar.close(app.io, app.gpa);
    var idle: usize = 0;
    for (ar.entries) |e| idle += @intFromBool(isIdle(e.name) and matches(app, &.{e.name}));
    if (idle == 0 or !folder(app, a, "scenes/idle", 1, null, tx.get(tx.sc_idle_lines), idle)) return;
    for (ar.entries) |e| {
        if (!isIdle(e.name) or !matches(app, &.{e.name})) continue;
        if (leaf(app, 2, null, .file_text, e.name, "", doctabs.isShown(app, .scenes, e.name), null)) doctabs.show(app, .scenes, e.name);
    }
}

/// A "+ new …" row (none while searching); true when clicked.
fn addRow(app: *App, depth: u32, label: tx.Msg) bool {
    if (app.treeQuery().len > 0) return false;
    row_n += 1;
    const rid = clay.idi("tree_row", row_n);
    const hit = gui.listRow(app, rid, .{ .indent = gui.leafIndent(depth), .rounded = false });
    gui.icon(app, .plus, lay.icon.md, theme.accent_hover);
    gui.txt(tx.get(label), .body, theme.accent_hover, font_mod.regular);
    clay.close();
    return hit;
}

/// Every script, each opening in the code editor: the shared ones levels and classes
/// include (`classes\*.s`, the game's and new ones), the items' and weapons' classes
/// (`ca_`, `ci_`, `cw_`), each level's own (its `other.dat`: `.lev`, `.are`, `.ba`…).
fn scripts(app: *App, a: Allocator) void {
    // OpenGorky: the classes are the project's components (codeFolders) and its src/ texts;
    // the installed game's `.s` are neither read nor saved there.
    if (app.ogLayout()) return;
    const shared = classList(app, a, isShared);
    const items = classList(app, a, isItemClass);
    var n: usize = 0;
    for (shared) |e| n += @intFromBool(matches(app, &.{e}));
    for (items) |e| n += @intFromBool(matches(app, &.{e}));
    const searching = app.treeQuery().len > 0;
    if (n == 0 and searching) return;
    if (!folder(app, a, "scripts", 0, .code, tx.get(tx.at_scripts), n)) return;
    if (addRow(app, 1, tx.sc_new_script)) app.newScript();
    if (items.len > 0 and folder(app, a, "scripts/items", 1, null, tx.get(tx.at_items), items.len)) for (items) |e| classRow(app, a, 2, e);
    // Levels' own: an archive read only when its folder is open (not searched).
    if (!searching and folder(app, a, "scripts/levels", 1, null, tx.get(tx.at_spr_levels), app.levels.len)) for (app.levels) |lv| {
        const key = std.fmt.allocPrint(a, "scripts/levels/{s}", .{lv.name}) catch continue;
        if (!folder(app, a, key, 2, null, lv.name, std.math.maxInt(usize))) continue;
        const archive = std.fmt.allocPrint(a, "{s}/other.dat", .{lv.name}) catch continue;
        for (refs.files(app, a, archive, refs.script)) |f| {
            if (leaf(app, 3, null, .code, f.name, "", fileShown(app, a, .code, archive, f.name), null)) showFile(app, a, .code, archive, f.name);
        }
    };
    for (shared) |e| classRow(app, a, 1, e);
}

/// An OpenGorky project's texts (every `.ogs` of its `src/`: rows, code, data blocks) in
/// the code editor, a section of their own as the folders of `src/` (`locations/01_port/`
/// …); their pages are the project's rows (pageRows) and blocks (og_page.zig). A Classic
/// project has no such files: no section.
fn filesSection(app: *App, a: Allocator) void {
    if (!app.ogLayout()) return;
    var list: std.ArrayList([]const u8) = .empty;
    for (app.store.listing(a, @import("store.zig").og_src, null, false)) |e| if (matches(app, &.{e})) list.append(a, e) catch {};
    if (list.items.len == 0) return;
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(x, y);
        }
    }.lt);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = lay.space.sm, .right = lay.space.sm, .top = lay.space.sm } } });
    gui.subhead(tx.get(tx.at_src));
    clay.close();
    filesDir(app, a, list.items, "", 0);
}

/// The files of `list` (sorted, `/`-separated) under folder `dir` (`""`: src/ itself, else
/// ending in `/`): its folders first, each with how many files it holds, then its files.
fn filesDir(app: *App, a: Allocator, list: []const []const u8, dir: []const u8, depth: u32) void {
    const path = @import("store.zig").og_src;
    var last: []const u8 = "";
    for (list, 0..) |e, i| {
        if (!std.mem.startsWith(u8, e, dir)) continue;
        const rest = e[dir.len..];
        const k = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        const sub = rest[0 .. k + 1];
        if (std.mem.eql(u8, sub, last)) continue;
        last = sub;
        const full = std.mem.concat(a, u8, &.{ dir, sub }) catch continue;
        var n: usize = 0;
        for (list[i..]) |x| {
            if (!std.mem.startsWith(u8, x, full)) break;
            n += 1;
        }
        const key = std.fmt.allocPrint(a, "files/{s}", .{full}) catch continue;
        if (folder(app, a, key, depth, null, sub[0..k], n)) filesDir(app, a, list[i .. i + n], full, depth + 1);
    }
    for (list) |e| {
        if (!std.mem.startsWith(u8, e, dir) or std.mem.indexOfScalar(u8, e[dir.len..], '/') != null) continue;
        if (leaf(app, depth, null, .code, e[dir.len..], "", fileShown(app, a, .code, path, e), null)) showFile(app, a, .code, path, e);
    }
}

fn classRow(app: *App, a: Allocator, depth: u32, e: []const u8) void {
    if (!matches(app, &.{e})) return;
    const shown = e["classes\\".len..];
    if (leaf(app, depth, null, .code, shown, "", fileShown(app, a, .code, common_archive, e), .of(.script, e))) showFile(app, a, .code, common_archive, e);
}

/// The class scripts `keep` takes: the archive's, then new ones in the Store.
fn classList(app: *App, a: Allocator, keep: *const fn ([]const u8) bool) []const []const u8 {
    return app.store.listing(a, common_archive, keep, false);
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
            doctabs.showPage(app, .sounds);
            app.askFile(.{ .kind = .sound, .run = @import("soundpage.zig").onSoundIn });
        }
        var shown: usize = 0;
        for (snd) |s| {
            if (!matches(app, &.{s})) continue;
            // shortcut: 400 rows at most; the search narrows the rest.
            shown += 1;
            if (shown > 400) break;
            if (leaf(app, 2, null, .volume_2, s, "", doctabs.isShown(app, .sounds, s), .of(.sound, s))) {
                doctabs.show(app, .sounds, s);
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
        if (leaf(app, 2, null, .image, ef, "", doctabs.isShown(app, .effects, ef), null)) doctabs.show(app, .effects, ef);
    };
    // Music (voice.dat's `.mp3`).
    const mus = @import("musicpage.zig").names(app);
    var nm: usize = 0;
    for (mus) |m| nm += @intFromBool(matches(app, &.{m}));
    if ((nm > 0 or app.treeQuery().len == 0) and folder(app, a, "media/music", 1, null, tx.get(tx.at_music), nm)) {
        if (addRow(app, 2, tx.mus_import)) {
            doctabs.showPage(app, .music);
            app.askMusic(null);
        }
        for (mus) |m| {
            if (!matches(app, &.{m})) continue;
            if (leaf(app, 2, null, .volume_2, m, "", doctabs.isShown(app, .music, m), null)) doctabs.show(app, .music, m);
        }
    }
    if ((nv > 0 or app.treeQuery().len == 0) and folder(app, a, "media/videos", 1, null, tx.get(tx.at_videos), nv)) {
        if (addRow(app, 2, tx.vid_import)) {
            doctabs.showPage(app, .videos);
            app.askFile(.{ .kind = .video, .run = @import("videopage.zig").onVideoIn });
        }
        for (vid) |v| {
            if (!matches(app, &.{v})) continue;
            if (leaf(app, 2, null, .play, v, "", doctabs.isShown(app, .videos, v), .of(.video, v))) doctabs.show(app, .videos, v);
        }
    }
}

/// The fighters' and items' looks (look_pages.zig): models, the look scripts binding their
/// animations (`act_*.ss`), the models' textures. Listed only while open (common's archive
/// read for them), not counted.
fn looks(app: *App, a: Allocator) void {
    const lp = @import("look_pages.zig");
    const searching = app.treeQuery().len > 0;
    // While searching (every folder open) only those with a match.
    const acts = if (app.ogLayout()) &.{} else app.catalog.acts.items;
    if (searching and matching(app, lp.models(app, a)) + matching(app, acts) + matching(app, lp.textures(app, a)) == 0) return;
    if (!folder(app, a, "looks", 0, .box, tx.get(tx.at_looks), std.math.maxInt(usize))) return;
    const ms = lp.models(app, a);
    if (!(searching and matching(app, ms) == 0) and folder(app, a, "looks/models", 1, null, tx.get(tx.at_models), ms.len)) {
        // OpenGorky: a model added first, worn later (a look's Model picks it; the old one stays).
        if (app.ogLayout() and addRow(app, 2, tx.mdl_import_new)) app.askFile(.{ .kind = .glb, .run = lp.onGlbNew });
        lookRows(app, .models, .box, ms);
    }
    // The look scripts (`act_*.ss`) are Classic's: an OpenGorky look is a block of src/looks/.
    if (!app.ogLayout() and !(searching and matching(app, app.catalog.acts.items) == 0) and folder(app, a, "looks/anims", 1, null, tx.get(tx.sec_anims), app.catalog.acts.items.len)) for (app.catalog.acts.items) |act| {
        if (!matches(app, &.{act})) continue;
        const key = std.fmt.allocPrint(a, "{s}|classes\\{s}", .{ common_archive, act }) catch continue;
        if (leaf(app, 2, null, .play, act, "", doctabs.isShown(app, .anims, key), null)) doctabs.show(app, .anims, key);
    };
    const ts = lp.textures(app, a);
    if (!(searching and matching(app, ts) == 0) and folder(app, a, "looks/textures", 1, null, tx.get(tx.sec_textures), ts.len)) lookRows(app, .textures, .image, ts);
}

fn matching(app: *App, names: []const []const u8) usize {
    var n: usize = 0;
    for (names) |x| n += @intFromBool(matches(app, &.{x}));
    return n;
}

fn lookRows(app: *App, tab: Tab, ic: icons.Icon, names: []const []const u8) void {
    var shown: usize = 0;
    for (names) |n| {
        if (!matches(app, &.{n})) continue;
        // shortcut: 400 rows at most; the search narrows the rest.
        shown += 1;
        if (shown > 400) break;
        const note = if (tab == .models and app.ogLayout()) @import("look_pages.zig").modelNote(app, n) else "";
        const item: ?treemenu.Item = if (tab == .models) .of(.model, n) else null;
        if (leaf(app, 2, null, ic, n, note, doctabs.isShown(app, tab, n), item)) doctabs.show(app, tab, n);
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
            const shown = if (icon_dir) e["icons\\".len..] else e;
            if (leaf(app, 2, null, .image, shown, "", fileShown(app, a, .sprites, sprite_archive, e), null)) showFile(app, a, .sprites, sprite_archive, e);
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
var sprite_total_key: [2]u64 = .{ std.math.maxInt(u64), 0 };

/// Every sprite (common's and each level's), counted again only when the edits change.
fn spriteTotal(app: *App, a: Allocator) usize {
    // The catalog's gen: another game folder opened in the same run (its levels).
    const now: [2]u64 = .{ app.store.rev, app.catalog.gen };
    if (std.mem.eql(u64, &now, &sprite_total_key)) return sprite_total;
    sprite_total_key = now;
    sprite_total = sprview.entries(app, a, sprite_archive).len;
    for (app.levels) |lv| {
        const archive = std.fmt.allocPrint(a, "{s}/sprite.dat", .{lv.name}) catch continue;
        sprite_total += sprview.entries(app, a, archive).len;
    }
    return sprite_total;
}

/// File `entry` of `archive` shown as a document of kind `tab` (a script, a sprite).
fn showFile(app: *App, a: Allocator, tab: Tab, archive: []const u8, entry: []const u8) void {
    doctabs.show(app, tab, @import("doctab.zig").join(a, archive, entry) catch return);
}

/// Level `name`'s sprites as rows at `depth` (the tree, the level's object list).
fn levelSprites(app: *App, a: Allocator, name: []const u8, depth: u32) void {
    const archive = std.fmt.allocPrint(a, "{s}/sprite.dat", .{name}) catch return;
    if (addRow(app, depth, tx.spr_import_new)) app.askNewSprite(archive, false);
    for (sprview.entries(app, a, archive)) |e| {
        if (leaf(app, depth, null, .image, e, "", fileShown(app, a, .sprites, archive, e), null)) showFile(app, a, .sprites, archive, e);
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
        if (leaf(app, 2, null, .file_text, fname, "", doctabs.isShown(app, .fonts, fname), null)) doctabs.show(app, .fonts, fname);
    };
    for (files) |f| {
        if (!matches(app, &.{tx.get(f[1])})) continue;
        const sub = if (f[0]) |tf| tf.entry() else "credits.inf";
        const sel = if (f[0]) |tf| doctabs.isShown(app, .texts, tf.entry()) else fileShown(app, a, .code, texts.archive, sub);
        if (leaf(app, 1, null, .file_text, tx.get(f[1]), sub, sel, null)) {
            if (f[0]) |tf| doctabs.show(app, .texts, tf.entry()) else showFile(app, a, .code, texts.archive, sub);
        }
    }
}

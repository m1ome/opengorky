//! Enemies, items and heroes tabs, in the frame (frame.zig): the model over its
//! animations, a weapon's damage zone or an item's icon on the stage; in the constructor
//! the head (name, kind, copies), texts, the kind's blocks (char_page.zig, item_page.zig),
//! rules and Info. "Make a copy" makes a new class from a game one (entry_copy.zig).

const std = @import("std");
const baseName = @import("doctab.zig").baseName;
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const c = @import("sdl");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const model = @import("model.zig");
const catalog = @import("catalog.zig");
const Kind = catalog.Kind;
const Entry = catalog.Entry;
const info = @import("info.zig");
const common_archive = @import("store.zig").common_archive;
const sprview = @import("sprview.zig");
const doctabs = @import("doctabs.zig");
const entry_rules = @import("entry_rules.zig");
const art = @import("art.zig");
const og = @import("opengorky");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;

const entry_copy = @import("entry_copy.zig");

pub const CopyMode = entry_copy.CopyMode;
pub const copyEntry = entry_copy.copyEntry;
pub const copyEntryAs = entry_copy.copyEntryAs;
pub const newWeapon = entry_copy.newWeapon;
pub const newCharacter = entry_copy.newCharacter;
pub const ownPortraits = entry_copy.ownPortraits;

/// Model of an entry: an item's `meshFile`, an enemy's through its look.
pub fn meshOf(app: *App, e: Entry, text: []const u8) ?[]const u8 {
    if (app.ogLayout()) return @import("og_page.zig").meshOf(app, fileOf(app, e) orelse return null);
    if (e.kind == .hero) return model.getStr(lookOf(app, text), "mesh");
    if (e.kind != .enemy) return model.getStr(text, "mesh");
    var buf: [128]u8 = undefined;
    const f = app.store.file(common_archive, std.fmt.bufPrint(&buf, "classes\\{s}", .{actOf(text) orelse return null}) catch return null) catch return null;
    return model.getStr(app.store.text(f), "mesh");
}

/// A PNG chosen in a dialog (or given on the command line) for entry `ask.entry`.
// File dialog answers (app.askFile) for catalog entry `ask.entry`: its icon or model
// texture (`ask.slot`) from a PNG, or out to one.
pub fn onIconIn(app: *App, ask: app_mod.FileAsk, path: []const u8) !void {
    const e = app.catalog.entries.items[ask.entry];
    const file = fileOf(app, e) orelse return;
    const text = app.store.text(file);
    if (e.kind == .enemy) {
        try art.replaceIcon(app, og.battle.report.iconOf(enemyWho(app, e, text)) orelse "", path);
        return app.setStatus(tx.st_icon_added, .{e.id});
    }
    app.setStatus(tx.st_icon_added, .{try art.importIcon(app, file, e.id, path)});
}
pub fn onIconOut(app: *App, ask: app_mod.FileAsk, path: []const u8) !void {
    const e = app.catalog.entries.items[ask.entry];
    const text = app.store.text(fileOf(app, e) orelse return);
    try art.exportIcon(app, (if (e.kind == .enemy) og.battle.report.iconOf(enemyWho(app, e, text)) else model.textStr(app, text, "icon")) orelse "", path);
    app.setStatus(tx.st_exported, .{path});
}
pub fn onTextureOut(app: *App, ask: app_mod.FileAsk, path: []const u8) !void {
    const e = app.catalog.entries.items[ask.entry];
    const text = app.store.text(fileOf(app, e) orelse return);
    try art.exportTexture(app, meshOf(app, e, text) orelse "", path, ask.slot);
    app.setStatus(tx.st_exported, .{path});
}
pub fn onTextureIn(app: *App, ask: app_mod.FileAsk, path: []const u8) !void {
    const e = app.catalog.entries.items[ask.entry];
    const file = fileOf(app, e) orelse return;
    const text = app.store.text(file);
    // A model the editor made: its texture replaced, no new look.
    const mesh = meshOf(app, e, text) orelse return error.NoModel;
    const target = app.importTarget();
    if (try art.replaceOwnTexture(app, mesh, path, ask.slot, target)) |tex| return app.setStatusPort(tx.st_tex_replaced, .{ mesh, tex }, tx.st_og_art);
    if (e.kind == .enemy) {
        const act = try art.newLook(app, actOf(text) orelse return error.NoLook, path, ask.slot, target);
        try setAct(app, file, act);
        return app.setStatusPort(tx.st_look_added, .{act}, tx.st_og_art);
    }
    const new_mesh = try art.newModel(app, model.textStr(app, text, "mesh") orelse return error.NoModel, path, ask.slot, target);
    try setString(app, file, "mesh", new_mesh);
    app.setStatusPort(tx.st_look_added, .{new_mesh}, tx.st_og_art);
}

/// Unsaved common/other.dat files for the model preview.
pub fn overlayGet(ctx: *anyopaque, name: []const u8) ?[]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const i = app.store.find(common_archive, name) orelse own: {
        // OpenGorky: a file of the project's own src/assets/ the game has none of (a model
        // imported and saved) — not read into the Store until asked.
        var b: [512]u8 = undefined;
        const sub = @import("store.zig").ownAsset(&b, app.store.root, common_archive, name) orelse return null;
        _ = app.store.root.?.statFile(app.io, sub, .{}) catch return null;
        break :own app.store.file(common_archive, name) catch return null;
    };
    return app.store.text(i);
}
/// Where a missing value goes: class `.ss` files are included into init() whole, item
/// classes and heroes keep values inside their first function. Attacks are either
/// (`wp_timebomb_explode.s` has its init()); without a `{` the value goes at the end.
fn afterFor(k: Kind) ?[]const u8 {
    return if (k == .enemy) null else "{";
}

pub fn fileOf(app: *App, e: Entry) ?usize {
    return app.store.file(e.archive, e.entry) catch null;
}

pub fn entryById(app: *App, id: []const u8) !usize {
    for (app.catalog.entries.items, 0..) |e, i| if (std.ascii.eqlIgnoreCase(e.id, id)) return i;
    return error.NoSuchEntry;
}

/// An entry's unique name, `archive|entry` (its tab's and its tree row's).
pub fn keyOf(a: Allocator, e: catalog.Entry) ?[]const u8 {
    return @import("doctab.zig").join(a, e.archive, e.entry) catch null;
}

/// Entry `i` shown on its kind's tab (as its tree row opens it).
pub fn showEntry(app: *App, i: usize) void {
    const e = app.catalog.entries.items[i];
    @import("doctabs.zig").show(app, @import("kinds.zig").tabOf(e.kind), keyOf(app.frame.allocator(), e) orelse return);
}

/// Entry by `archive|entry`, or by id (scripted checks: the first with it).
pub fn entryByKey(app: *App, key: []const u8) !usize {
    const p = @import("doctab.zig").split(key) orelse return entryById(app, key);
    return app.catalog.byKey(p[0], p[1]) orelse error.NoSuchEntry;
}

pub fn page(app: *App, a: Allocator) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    if (app.entry) |i| detail(app, a, i) else {
        clay.open(.{ .layout = .{ .padding = gui.pad(lay.space.xl, lay.space.xl) } });
        gui.txt(tx.get(tx.pick_entry), .title, theme.dim, font_mod.regular);
        clay.close();
    }
    clay.close();
}

/// Current icon of an item: from the edited file when it is open, else as listed.
pub fn iconOf(app: *App, e: Entry) []const u8 {
    if (e.kind == .enemy) return og.battle.report.iconOf(enemyWho(app, e, app.store.text(fileOf(app, e) orelse return ""))) orelse "";
    const i = app.store.find(e.archive, e.entry) orelse return e.icon;
    return model.getStr(app.store.text(i), "icon") orelse e.icon;
}

/// The right panel's top: the name, its kind as a chip, its id and file, what its values
/// change, and its actions (script, a hero's inventory, the copies: one button, or a
/// menu of those the exe tells apart).
fn head(app: *App, a: Allocator, e: Entry, idx: usize, text: []const u8) void {
    gui.headCard();
    gui.row(lay.space.sm);
    if (e.kind != .enemy and e.kind != .hero and (e.kind != .attack or model.getStr(text, "icon") != null)) clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lay.height.tab), .height = clay.fixed(lay.height.tab) } }, .image = .{ .imageData = app.icon(model.getStr(text, "spriteFile") orelse "") } });
    gui.txtWrap(if (e.title.len > 0) e.title else e.id, .heading, theme.text, font_mod.bold);
    clay.close();
    gui.row(lay.space.sm);
    gui.chip(tx.get(switch (e.kind) {
        .enemy => tx.chip_enemy,
        .hero => tx.chip_hero,
        .weapon => tx.chip_weapon,
        .ammo => tx.chip_ammo,
        .item => tx.chip_item,
        .attack => tx.chip_attack,
    }));
    // What the exe names and rules it by (read-only: a copy's own comes with the copy).
    gui.txt(if (e.name_id) |n| std.fmt.allocPrint(a, "{s} · classic_id {d}", .{ e.id, n }) catch e.id else e.id, .body, theme.dim, font_mod.regular);
    gui.spacer();
    gui.txtClip(if (e.base) |b| tx.alloc(a, tx.copy_of, .{b}) else e.entry, .caption, theme.dim, font_mod.regular);
    clay.close();
    const n = e.name_id orelse 0;
    const hint = if (e.base != null and app.ogLayout()) tx.alloc(a, tx.hint_copy_og, .{n}) else if (e.base) |b| switch (e.kind) {
        .enemy => tx.alloc(a, tx.hint_copy_enemy, .{n}),
        .hero => if (std.mem.eql(u8, e.archive, common_archive)) tx.alloc(a, tx.hint_copy_hero_party, .{n}) else tx.alloc(a, tx.hint_copy_hero_level, .{n}),
        else => if (baseClassicId(app, e.kind, b) == e.name_id) tx.alloc(a, tx.hint_copy_same, .{n}) else switch (e.kind) {
            .weapon => tx.alloc(a, tx.hint_copy_new_weapon, .{n}),
            .ammo => tx.alloc(a, tx.hint_copy_new_ammo, .{n}),
            else => tx.alloc(a, tx.hint_copy_new_item, .{n}),
        },
    } else tx.get(switch (e.kind) {
        .enemy => tx.hint_enemy,
        .hero => tx.hint_hero,
        .attack => tx.hint_attack,
        else => tx.hint_item,
    });
    gui.txtWrap(hint, .caption, if (e.kind == .hero and e.base == null) theme.dim else theme.warn, font_mod.regular);
    // The copies the exe tells apart (and a hero copy's own portraits): one primary
    // button, or a menu of them.
    const Act = enum { code, inventory, battle, copy_enemy, portraits, copy, copy_new, copy_party, copy_level, blank, menu };
    const Copy = struct { act: Act, label: tx.Msg };
    var copies: [3]Copy = undefined;
    var n_copies: usize = 0;
    const own_portraits = e.kind == .hero and e.base != null and !std.ascii.eqlIgnoreCase(model.textStr(app, text, "portrait") orelse e.id, e.id);
    switch (e.kind) {
        .enemy => {
            copies[0] = .{ .act = .copy_enemy, .label = tx.make_copy };
            n_copies = 1;
        },
        // OpenGorky: a copy is always its own (entry_rules: its class's rules).
        .weapon, .item, .ammo => {
            if (app.ogLayout()) {
                copies[0] = .{ .act = .copy_new, .label = tx.make_copy };
                n_copies = 1;
            } else {
                copies[0] = .{ .act = .copy, .label = tx.copy_same };
                copies[1] = .{ .act = .copy_new, .label = tx.copy_new };
                n_copies = 2;
            }
            if (e.kind == .weapon) {
                copies[n_copies] = .{ .act = .blank, .label = tx.new_weapon };
                n_copies += 1;
            }
        },
        .hero => {
            // A hero copy's portraits are its base's until copied.
            if (own_portraits) {
                copies[n_copies] = .{ .act = .portraits, .label = tx.own_portraits };
                n_copies += 1;
            }
            copies[n_copies] = .{ .act = .copy_party, .label = tx.copy_party };
            n_copies += 1;
            if (!std.mem.eql(u8, e.archive, common_archive)) {
                copies[n_copies] = .{ .act = .copy_level, .label = tx.copy_level };
                n_copies += 1;
            }
        },
        .attack => {},
    }
    var acts: [3]Act = undefined;
    var items: [3]gui.Item = undefined;
    var k_items: usize = 0;
    const add = struct {
        fn f(it: []gui.Item, ac: []Act, k: *usize, act: Act, id: []const u8, ic: @import("icons.zig").Icon, label: []const u8, primary: bool) void {
            it[k.*] = .{ .id = clay.id(id), .b = .{ .label = label, .icon = ic, .style = if (primary) .primary else .secondary, .size = .tool } };
            ac[k.*] = act;
            k.* += 1;
        }
    }.f;
    add(&items, &acts, &k_items, .code, "code", .code, tx.get(tx.code_open), false);
    if (e.kind == .hero) add(&items, &acts, &k_items, .inventory, "inventory", .package, tx.get(tx.inv_open), false);
    // OpenGorky: the character (an attack's: the first enemy striking with it, holding
    // it) tried in the test room (testroom.zig).
    if ((e.kind == .enemy or e.kind == .attack) and app.ogLayout()) add(&items, &acts, &k_items, .battle, "in_battle", .play, tx.get(tx.b_in_battle), false);
    // A hero's always a menu (its one copy's name is long).
    const menu = n_copies > 1 or e.kind == .hero;
    if (n_copies == 1 and !menu) add(&items, &acts, &k_items, copies[0].act, "copy", .copy, tx.get(copies[0].label), true);
    if (menu) add(&items, &acts, &k_items, .menu, "copy", .copy, tx.get(tx.copy_menu), true);
    var act: ?Act = if (gui.buttonRow(app, clay.id("entry_actions"), items[0..k_items])) |k| acts[k] else null;
    // The menu: the shared picker's list under the actions, as wide as they are (picker.zig).
    const copy_id = clay.id("entry_actions");
    if (act == .menu) {
        picker.toggle(app, copy_id);
        act = null;
    }
    if (menu and picker.isOpen(app, copy_id)) {
        var rows: [3]picker.Opt = undefined;
        for (copies[0..n_copies], rows[0..n_copies]) |cp, *o| o.* = .{ .label = tx.get(cp.label) };
        if (picker.list(app, a, rows[0..n_copies])) |k| act = copies[k].act;
    }
    if (act) |ac| switch (ac) {
        .code => openCode(app, idx),
        .inventory => openInventory(app, idx),
        .battle => if (e.kind == .enemy) @import("testroom.zig").play(app, idx, null) else if (entry_attacks.struckBy(app, a, og.rules.stem(e.entry))) |by|
            @import("testroom.zig").play(app, by.enemy, og.rules.stem(e.entry))
        else
            app.setStatus(tx.st_test_room_failed, .{error.NoEnemyStrikesWithIt}),
        .copy_enemy, .copy => copyClicked(app, idx, .same),
        .portraits => ownPortraits(app, idx) catch |err| app.setStatus(tx.st_copy_failed, .{err}),
        .copy_new => copyClicked(app, idx, .new_id),
        .copy_party => copyClicked(app, idx, .party),
        .copy_level => copyClicked(app, idx, .level),
        .blank => newWeapon(app) catch |err| app.setStatus(tx.st_copy_failed, .{err}),
        .menu => {},
    };
    gui.blockEnd();
}

/// classic_id of the game entry `base` of kind `k` (what a copy may share).
fn baseClassicId(app: *App, k: Kind, base: []const u8) ?i32 {
    for (app.catalog.entries.items) |x| if (x.kind == k and x.base == null and std.ascii.eqlIgnoreCase(x.id, base)) return x.name_id;
    return null;
}

fn detail(app: *App, a: Allocator, idx: usize) void {
    const e = app.catalog.entries.items[idx];
    // An OpenGorky project's block: its OG layout (og_page.zig).
    if (e.class.len > 0) return @import("og_page.zig").detail(app, a, idx);
    const file = fileOf(app, e) orelse return;
    const text = app.store.text(file);

    // An attack: the first enemy striking with it (its look and strike on the stage).
    const by = if (e.kind == .attack) entry_attacks.struckBy(app, a, og.rules.stem(e.entry)) else null;
    // Enemies and heroes: data | model over animations | sounds, the edges dragged.
    // The look's script, and its Store index where this page edits it (a hero's class: its own page).
    var act_file: ?usize = null;
    const act_text: ?[]const u8 = switch (e.kind) {
        .hero => blk: {
            const own = lookOf(app, text);
            if (own.ptr == text.ptr) act_file = file;
            break :blk own;
        },
        .enemy => blk: {
            act_file = actFileOf(app, text) orelse break :blk null;
            break :blk app.store.text(act_file.?);
        },
        .attack => blk: {
            const b = by orelse break :blk null;
            const hf = fileOf(app, app.catalog.entries.items[b.enemy]) orelse break :blk null;
            break :blk app.store.text(actFileOf(app, app.store.text(hf)) orelse break :blk null);
        },
        else => null,
    };
    // A weapon: a hero striking with it (the exe's strike by classic_id, two-handed ones in
    // the two-handed stance), the weapon in hand.
    var strike: ?Strike = null;
    if (e.kind == .weapon) strike = strikeOf(app, a, text, og.rules.stem(e.entry));
    // An enemy's attack struck (its "Attacks" section, an attack's page): its slot and effects.
    const enemy_strike = if (e.kind == .enemy) entry_attacks.strikeShown(app, a, e, enemyWho(app, e, text)) else if (by) |b| b.struck else null;
    const view = app.entry_view;
    // What the stage shows: a look (a fighter, a strike), a weapon's model alone, a damage zone.
    const zone = (e.kind == .attack and (by == null or view == .zone)) or (e.kind == .weapon and view == .zone);
    const striking = !zone and switch (e.kind) {
        .weapon => view == .strike,
        .enemy, .hero, .attack => true,
        else => false,
    };
    const lk: ?Look = if (!striking) null else if (act_text) |t| (if (enemy_strike) |es| look(app, a, t, es.slot, es.held, if (by) |b| app.catalog.entries.items[b.enemy].riders.items else e.riders.items) else look(app, a, t, null, null, e.riders.items)) else if (strike) |s| look(app, a, s.hero_text, s.slot, s.held, &.{}) else null;
    // As the concept's: the model over its animations and their sounds on the stage,
    // the values in the constructor (frame.zig).
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } } });
    frame.stage(app);
    // A weapon: its model, a hero striking with it or its damage zone; an attack: an
    // enemy striking with it or its zone.
    if (e.kind == .weapon or e.kind == .attack) {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = lay.space.md, .top = lay.space.sm, .bottom = lay.space.sm }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.viewport });
        if (e.kind == .weapon) {
            if (gui.segmented(app, "entry_view", &.{ tx.get(tx.view_model), tx.get(tx.view_strike), tx.get(tx.view_zone) }, @backingInt(view))) |k| app.entry_view = @fromBackingInt(@intCast(k));
        } else if (by != null) {
            if (gui.segmented(app, "entry_view", &.{ tx.get(tx.view_strike), tx.get(tx.view_zone) }, @intFromBool(zone))) |k| app.entry_view = if (k == 1) .zone else .strike;
        } else gui.txtWrap(tx.get(tx.atk_nobody), .body, theme.dim, font_mod.regular);
        clay.close();
    }
    if (zone) {
        // Both ways: the grid stays its size and scrolls in a narrow pane.
        clay.openScrollXY(.{ .id = clay.id("zone"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
        @import("zone_edit.zig").page(app, a, model.textNum(app, text, "class"));
        clay.close();
    } else if (lk) |l| {
        // A strike's effects over its frames (OpenGorky), then the model's sounds.
        const fx = if (strike) |st| (if (st.held) |h| h.strike else null) else if (enemy_strike) |es| es.held.strike else null;
        const by_line = if (by) |b| tx.alloc(a, tx.atk_by, .{ entryTitle(app.catalog.entries.items[b.enemy]), b.struck.slot }) else null;
        @import("entry_model.zig").lookStage(app, a, l, if (strike != null) null else act_text, if (strike) |st| st.info else by_line, fx, &.{});
    } else if (e.kind == .weapon and model.textStr(app, text, "mesh") != null) {
        // The weapon's model alone (as the model's page shows it).
        const m = model.textStr(app, text, "mesh").?;
        entry_model.modelPane(app, look(app, a, std.fmt.allocPrint(a, "meshFile=\"{s}\";", .{m}) catch "", null, null, &.{}), null, tx.model_hint);
    } else if (e.kind == .ammo or e.kind == .item) {
        item_page.inventoryStage(app, iconOf(app, e));
    } else {
        // No model: its icon large in the centre (as the game draws it, pixels kept).
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.viewport });
        if (app.icon(iconOf(app, e))) |t| {
            var w: f32 = 0;
            var h: f32 = 0;
            _ = c.SDL_GetTextureSize(t, &w, &h);
            // Whole pixels, up to 6×, about a slider's width.
            const k = @floor(@min(6, lay.width.slider / @max(1, @max(w, h))));
            clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(w * @max(1, k)), .height = clay.fixed(h * @max(1, k)) } }, .image = .{ .imageData = t } });
        }
        clay.close();
    }
    // Its blocks close themselves: the constructor is closed at the end, not by propsEnd.
    frame.props(app, "fields");
    head(app, a, e, idx, text);
    const name_id: i32 = if (e.kind == .enemy) enemyClassicId(app, text) else if (model.textNum(app, text, "classic_id")) |v| @intFromFloat(v) else e.name_id orelse 0;
    entry_rules.syncClassicId(app, idx, name_id);
    textsBlock(app, a, e, text, idx, file, name_id);
    switch (e.kind) {
        .enemy => char_page.enemy(app, a, idx, file, text, act_file, act_text),
        .hero => char_page.hero(app, a, idx, file, text, act_file, act_text),
        else => item_page.props(app, a, idx, file, text, name_id, if (strike) |st| (if (st.held) |h| h.strike else null) else if (by) |b| b.struck.held.strike else null, if (by) |b| .{ .special = b.struck.special, .enemy = b.enemy, .slot = b.struck.slot } else null),
    }
    entry_rules.section(app, a, e, name_id);
    const info_rows = info.rows(app, std.fmt.allocPrint(a, "entry:{d}:{s}", .{ idx, e.entry }) catch e.entry, idx, entryInfo);
    if (gui.block(app, "info", tx.get(tx.info_title), .{ .folded = true, .summary = info.summary(a, e.archive, info_rows) })) {
        info.show(app, info_rows);
        gui.blockEnd();
    }
    clay.closeScrollColumn();
    clay.close();
}

const Look = @import("entry_model.zig").Look;
const look = @import("entry_model.zig").look;
const Strike = @import("entry_model.zig").Strike;
const strikeOf = @import("entry_model.zig").strikeOf;
const entry_model = @import("entry_model.zig");
const entry_attacks = @import("entry_attacks.zig");

pub const soundOp = @import("entry_model.zig").soundOp;
/// The entry's Info: its file (and level), what it includes, its classic_id and the others
/// with it, the identity fields, what it names, the scripts making it a party hero, the
/// levels whose scripts name its class (`#include ft_sphinx.ss`, `cw_pistol`…).
fn entryInfo(idx: usize, app: *App, list: *info.List) void {
    const e = app.catalog.entries.items[idx];
    const text = app.store.text(fileOf(app, e) orelse return);
    info.defined(list, e.archive, e.entry, true);
    info.includes(app, list, e.archive, text, 4);
    // A hero may name itself in a class it includes (the catalog read it there).
    const id: i32 = if (e.kind == .enemy) enemyClassicId(app, text) else if (model.textNum(app, text, "classic_id")) |v| @intFromFloat(v) else e.name_id orelse 0;
    if (id > 0) {
        info.classicId(app, list, id);
        info.sameName(app, list, id, idx);
    }
    switch (e.kind) {
        // Its attacks' pages (`wp_x.ss` → entry `wp_x`).
        .enemy => for (e.weapons.items) |w| list.add(.{ .group = .refs, .text = w, .to = if (entryById(app, std.fs.path.stem(w))) |i| .{ .entry = i } else |_| .{ .code = .{ .archive = common_archive, .entry = list.fmt("classes\\{s}", .{w}) } }, .icon = .swords }),
        .hero => if (std.mem.eql(u8, e.archive, common_archive)) list.add(.{ .group = .party, .text = tx.get(tx.info_party_start) }) else {
            const n = list.rows.items.len;
            info.joins(app, list, e.id);
            if (list.rows.items.len == n) list.add(.{ .group = .party, .text = tx.get(tx.info_party_never) });
        },
        else => {
            for (item_page.hidden) |n| {
                // classic_id has its row; a weapon picks these from lists above.
                if (std.ascii.eqlIgnoreCase(n, "classic_id") or ((e.kind == .weapon or e.kind == .attack) and (std.ascii.eqlIgnoreCase(n, "damage_kind") or std.ascii.eqlIgnoreCase(n, "class"))) or (e.kind == .weapon and std.ascii.eqlIgnoreCase(n, "ammo"))) continue;
                const v = model.textNum(app, text, n) orelse continue;
                list.add(.{ .group = .fields, .text = list.fmt("{s} {s}", .{ n, app_mod.fmtNum(list.a, v) }) });
            }
            // OpenGorky: its Hero strikes block shows it.
            if (e.kind == .weapon and id > 0 and !app.ogLayout()) list.add(.{ .group = .fields, .text = tx.alloc(list.a, tx.info_strike, .{og.battle.attacks.heroAttack(.{ .id = 20 }, .{ .id = id }).anim}) });
            // A weapon names its ammo by classic_id (-1: itself), weapons name an ammo.
            const ammo: i32 = @intFromFloat(model.textNum(app, text, "ammo") orelse 0);
            for (app.catalog.entries.items, 0..) |x, i| {
                if (e.kind == .weapon and ammo > 0 and x.kind == .ammo and x.name_id == ammo) list.add(.{ .group = .refs, .text = info.entryText(list, x), .to = .{ .entry = i }, .icon = .package });
                if (e.kind != .ammo or x.kind != .weapon or id <= 0) continue;
                const f = fileOf(app, x) orelse continue;
                if (model.get(app.store.text(f), "ammo") == @as(f32, @floatFromInt(id))) list.add(.{ .group = .used, .text = info.entryText(list, x), .to = .{ .entry = i }, .icon = .package });
            }
            if (ammo == -1) list.add(.{ .group = .refs, .text = tx.get(tx.a_self) });
            // The characters holding it: the enemy classes whose fighters hold it in the
            // battles, the heroes starting with it (`Weapon_New("…", "cw_pistol.s")`).
            const file_name = list.fmt("\"{s}\"", .{baseName(e.entry)});
            for (app.catalog.entries.items, 0..) |x, i| {
                if (x.kind != .enemy and x.kind != .hero) continue;
                const holds = for (x.weapons.items) |w| {
                    if (std.ascii.eqlIgnoreCase(std.fs.path.stem(w), og.rules.stem(e.entry))) break true;
                } else if (x.kind == .hero) if (fileOf(app, x)) |f| std.ascii.findIgnoreCase(app.store.text(f), file_name) != null else false else false;
                if (holds) list.add(.{ .group = .used, .text = info.entryText(list, x), .to = .{ .entry = i }, .icon = .user });
            }
        },
    }
    const stem = std.fs.path.stem(baseName(e.entry));
    const before = list.rows.items.len;
    info.levelsNaming(app, list, stem);
    if (list.rows.items.len == before and e.kind != .ammo) list.add(.{ .group = .used, .text = tx.get(tx.info_used_none) });
}

pub fn idName(a: Allocator, base: []const u8, k: usize) []const u8 {
    return std.fmt.allocPrint(a, "{s}{d}", .{ base, k }) catch base;
}

pub const weaponChoice = @import("entry_weapons.zig").weaponChoice;
pub const swapClassWeapon = @import("entry_weapons.zig").swapClassWeapon;
pub const swapWeapon = @import("entry_weapons.zig").swapWeapon;
pub const resistBlock = @import("entry_weapons.zig").resistBlock;
/// The entry's texts: its classic_id (an OpenGorky project's field), its name in the game
/// (string.tab by classic_id: a row chosen, OpenGorky; edited on the Texts page) and, for
/// items, what examining it says (items.inf) — typed in place (the classes sharing the
/// number: Info).
fn textsBlock(app: *App, a: Allocator, e: Entry, text: []const u8, idx: usize, file: usize, name_id: i32) void {
    const texts = @import("texts.zig");
    const char = e.kind == .enemy or e.kind == .hero;
    if (!gui.block(app, "texts", tx.get(if (char) tx.sec_identity else tx.sec_texts), .{})) return;
    defer gui.blockEnd();
    if (char) {
        identityRows(app, a, e, idx);
        char_page.classTypeRow(app, a, file, text, afterFor(e.kind));
    }
    // OpenGorky: one with no field of its own (a hero naming itself in its class) gets one picked.
    const id: i32 = if (app.ogLayout()) (if (model.textNum(app, text, "classic_id")) |v| @intFromFloat(v) else name_id) else if (e.kind == .enemy) enemyClassicId(app, text) else if (model.textNum(app, text, "classic_id")) |v| @intFromFloat(v) else return;
    if (id <= 0 and !app.ogLayout()) return;
    // OpenGorky (no classic_id): the block's `name`, typed in
    // place (texts.set: on every block of its identity).
    if (app.ogLayout()) {
        gui.fieldRow(tx.get(tx.c_name_og));
        if (gui.textField(app, "ent_name", texts.get(app, a, .strings, id) orelse "", 0, tx.get(tx.c_name_og_none))) |v| texts.set(app, .strings, id, v) catch |err| app.failed(err);
        clay.close();
        if (e.kind == .weapon or e.kind == .ammo or e.kind == .item) {
            gui.fieldRow(tx.get(tx.c_examine));
            if (gui.textField(app, "ent_examine", texts.get(app, a, .items, id) orelse "", 0, tx.get(tx.c_examine_none))) |v| texts.set(app, .items, id, v) catch |err| app.failed(err);
            clay.close();
        }
        entry_rules.sameAsRow(app, a, idx, file, id);
        return;
    }
    // The row chosen from string.tab (OpenGorky: it sets the classic_id; first a free number
    // for a new text), edited on the Texts page. One row: classic_id is only this number.
    gui.fieldRow(tx.alloc(a, tx.c_name_game, .{id}));
    const name = std.fmt.allocPrint(a, "{d} · {s}", .{ id, texts.get(app, a, .strings, id) orelse tx.get(tx.c_name_none) }) catch "";
    if (app.ogLayout()) {
        if (picker.field(app, clay.idi("choice", 7), name, texts.get(app, a, .strings, id) == null)) nm: {
            const strs = texts.rows(app, a, .strings);
            const rows = a.alloc(picker.Opt, strs.len + 1) catch break :nm;
            const free = entry_rules.freshClassicId(app);
            const free_key = std.fmt.allocPrint(a, "{d}", .{free}) catch "";
            rows[0] = .{ .key = free_key, .label = tx.alloc(a, tx.nameid_new, .{free}) };
            for (strs, rows[1..]) |r, *o| o.* = .{ .key = std.fmt.allocPrint(a, "{d}", .{r.id}) catch "", .label = std.fmt.allocPrint(a, "{d} · {s}", .{ r.id, r.text }) catch "", .selected = r.id == id };
            if (picker.listKey(app, a, rows)) |v| entry_rules.setClassicId(app, file, v) catch |err| app.failed(err);
        }
    } else gui.txtWrap(name, .label, theme.text, font_mod.regular);
    clay.close();
    // Under the value: beside a long name a narrow panel cut its label.
    gui.valueLine();
    if (id > 0 and gui.smallButton(app, clay.idi("name_goto", 0), tx.get(tx.c_name_goto))) {
        var nb: [16]u8 = undefined;
        app.texts.filter.set(std.fmt.bufPrint(&nb, "{d}", .{id}) catch "");
        @import("doctabs.zig").show(app, .texts, texts.File.strings.entry());
    }
    clay.close();
    if (e.kind == .weapon or e.kind == .ammo or e.kind == .item) {
        gui.fieldRow(tx.get(tx.c_examine));
        if (gui.textField(app, "ent_examine", texts.get(app, a, .items, id) orelse "", 0, tx.get(tx.c_examine_none))) |v| texts.set(app, .items, id, v) catch |err| app.failed(err);
        clay.close();
    }
}

/// A character's class (what its rules are keyed by), its script (› the code) and its
/// roles: enemy (a `.ftr` fighter class) and hero (a `.hro`); one class may be both, a
/// hero including the enemy's class script (read-only facts, as the files have them).
fn identityRows(app: *App, a: Allocator, e: Entry, idx: usize) void {
    gui.fieldRow(tx.get(tx.c_class));
    gui.txtWrap(entry_rules.classOf(e), .label, theme.text, font_mod.regular);
    clay.close();
    gui.fieldRow(tx.get(tx.c_script));
    gui.txtWrap(e.entry, .label, theme.text, font_mod.regular);
    gui.spacer();
    if (gui.goButton(app, clay.id("ident_code"))) openCode(app, idx);
    clay.close();
    const other = otherRole(app, e);
    const class = entry_rules.classOf(e);
    // OpenGorky: its roles row (rules Character), else its files' roles; ticked on a class
    // script's page (a .hro is a hero by its file).
    const row = if (app.ogLayout()) og.rules.character(.{ .id = e.name_id orelse 0, .class = class }) else null;
    const on: [2]bool = if (row) |r| .{ r.as_enemy, r.as_hero } else .{ e.kind == .enemy or other != null, e.kind == .hero or other != null };
    const edit = app.ogLayout() and e.kind == .enemy;
    gui.fieldRow(tx.get(tx.c_roles));
    for ([_]tx.Msg{ tx.chip_enemy, tx.chip_hero }, on, 0..) |m, has, k| if (edit) {
        if (gui.check(app, clay.idi("ident_role_on", @intCast(k)), has, tx.get(m))) {
            var x = on;
            x[k] = !has;
            @import("rules_rows.zig").put(app, og.rules.Character, .{ .fighter_class = class, .as_enemy = x[0], .as_hero = x[1] }) catch |err| app.failed(err);
        }
    } else gui.chipOf(if (has) tx.get(m) else std.fmt.allocPrint(a, "{s} —", .{tx.get(m)}) catch "", if (has) theme.text else theme.dim, if (has) theme.accent else theme.button_edge);
    gui.spacer();
    if (other) |i| if (gui.goButton(app, clay.id("ident_role"))) showEntry(app, i);
    clay.close();
    gui.fieldNote(tx.get(if (edit) tx.roles_og else if (other != null) tx.roles_both else tx.roles_note), theme.dim);
}

/// `--roles ID enemy|hero|both|none` (scripted.zig): an enemy class's roles row (OpenGorky).
pub fn setRoles(app: *App, idx: usize, roles: []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const e = app.catalog.entries.items[idx];
    if (e.kind != .enemy) return error.NotForThisKind;
    const eq = std.mem.eql;
    if (!eq(u8, roles, "enemy") and !eq(u8, roles, "hero") and !eq(u8, roles, "both") and !eq(u8, roles, "none")) return error.BadMode;
    try @import("rules_rows.zig").put(app, og.rules.Character, .{ .fighter_class = entry_rules.classOf(e), .as_enemy = eq(u8, roles, "enemy") or eq(u8, roles, "both"), .as_hero = eq(u8, roles, "hero") or eq(u8, roles, "both") });
}

/// The entry of a character's other role: an enemy's hero including its class script,
/// a hero's enemy class it includes.
fn otherRole(app: *App, e: Entry) ?usize {
    if (e.kind != .enemy and e.kind != .hero) return null;
    const own = app.store.text(fileOf(app, e) orelse return null);
    for (app.catalog.entries.items, 0..) |x, i| {
        if (x.kind == e.kind or (x.kind != .enemy and x.kind != .hero)) continue;
        const hero = if (e.kind == .hero) own else app.store.text(fileOf(app, x) orelse continue);
        const enemy = if (e.kind == .enemy) e else x;
        const name = baseName(enemy.entry);
        if (std.ascii.findIgnoreCase(hero, name) != null) return i;
    }
    return null;
}

/// Scripts `#include`d by name, as the game finds them (common `classes\`).
const Classes = struct {
    app: *App,
    pub fn read(self: Classes, name: []const u8) ?[]const u8 {
        var buf: [128]u8 = undefined;
        const f = self.app.store.file(common_archive, std.fmt.bufPrint(&buf, "classes\\{s}", .{name}) catch return null) catch return null;
        return self.app.store.text(f);
    }
};

/// A hero's look (model, portraits, animations): its own file's, or the class's it
/// `#include`s (03__museum_corner's medusa.hro → ft_medusa.ss → act_medusa.ss).
pub fn lookOf(app: *App, text: []const u8) []const u8 {
    return model.definer(Classes{ .app = app }, text, "mesh", 4) orelse text;
}

/// Who an enemy's rows name: its classic_id and (OpenGorky) its class.
pub fn enemyWho(app: *App, e: Entry, text: []const u8) og.rules.Who {
    return .{ .id = enemyClassicId(app, text), .class = if (app.ogLayout()) entry_rules.classOf(e) else "" };
}

/// Its classic_id, its own or its class's (an enemy's act_*.ss, a battle extra's class).
pub fn enemyClassicId(app: *App, text: []const u8) i32 {
    return @intFromFloat(inheritedVar(app, text, "classic_id") orelse 0);
}

/// Number field `name` of a script, its own or from the class scripts it includes.
pub fn inheritedVar(app: *App, text: []const u8, name: []const u8) ?f32 {
    return model.inherited(Classes{ .app = app }, text, name, 4);
}

/// An enemy class's look script (`classes\act_*.ss`), its Store index.
fn actFileOf(app: *App, text: []const u8) ?usize {
    var buf: [128]u8 = undefined;
    const entry = std.fmt.bufPrint(&buf, "classes\\{s}", .{actOf(text) orelse return null}) catch return null;
    return app.store.file(common_archive, entry) catch null;
}

fn entryTitle(e: Entry) []const u8 {
    return if (e.title.len > 0) e.title else e.id;
}

/// `act_x.ss` an enemy class includes.
pub fn actOf(text: []const u8) ?[]const u8 {
    const p = std.ascii.findIgnoreCase(text, "#include act_") orelse return null;
    const s = p + "#include ".len;
    var e = s;
    while (e < text.len and !std.ascii.isWhitespace(text[e])) e += 1;
    return text[s..e];
}
pub fn numRow(app: *App, a: Allocator, row: u32, label: []const u8, file: usize, names: []const []const u8, after: ?[]const u8, show_missing: bool) void {
    _ = @import("inspector.zig").row(app, a, row, label, file, names, .{ .after = after, .show_missing = show_missing });
}

/// A block's file buttons (a look's icon, textures, the model, animations); `icon` set:
/// "Edit…" after them opens it in the sprite page.
pub fn artButtons(app: *App, idx: usize, buttons: []const struct { tx.Msg, app_mod.FileKind, *const fn (*App, app_mod.FileAsk, []const u8) anyerror!void }, icon: ?[]const u8) void {
    var labels: [8][]const u8 = undefined;
    var n: usize = 0;
    for (buttons[0..@min(buttons.len, labels.len - 1)]) |b| {
        labels[n] = tx.get(b[0]);
        n += 1;
    }
    if (icon != null) {
        labels[n] = tx.get(tx.b_edit_icon);
        n += 1;
    }
    if (n == 0) return;
    // Buttons apart by the first one's text (a page has several rows of them).
    var ib: [24]u8 = undefined;
    const id = std.fmt.bufPrint(&ib, "art{x}", .{@as(u32, @truncate(std.hash.Wyhash.hash(0, labels[0])))}) catch "art";
    const k = gui.footer(app, id, labels[0..n], null) orelse return;
    if (k < buttons.len) return app.askFile(.{ .kind = buttons[k][1], .run = buttons[k][2], .entry = idx });
    if (icon) |nm| sprview.open(app, nm) catch |err| app.setStatus(tx.st_import_failed, .{err});
}

/// A choice row (key `k`); true while its list is open (picker.row).
pub fn choiceRow(app: *App, k: u32, label: []const u8, value: []const u8) bool {
    return picker.row(app, clay.idi("choice", k), label, value);
}
/// The model (`meshFile`) of `file` labelled `label`, picked from the game's models.
pub fn meshRow(app: *App, a: Allocator, label: tx.Msg, file: usize, mesh: ?[]const u8) void {
    if (choiceRow(app, 1, tx.get(label), mesh orelse "—")) if (picker.listKey(app, a, picker.names(a, app.catalog.meshes.items))) |v| setString(app, file, "mesh", v) catch |err| app.failed(err);
}

/// The item icons of sprite.dat, each shown.
pub fn iconRows(app: *App, a: Allocator) []picker.Opt {
    const rows = picker.names(a, app.catalog.icons.items);
    for (rows) |*o| o.icon = o.key;
    return rows;
}

/// The hero's starting inventory in the box window: owner as its calls name it.
pub fn openInventory(app: *App, idx: usize) void {
    const e = app.catalog.entries.items[idx];
    const f = fileOf(app, e) orelse return;
    // The owner in the hero's own calls ("Bt"), else the script's name.
    const owner = @import("box.zig").ownerOf(app, app.frame.allocator(), f) orelse e.id;
    app.box = .{ .file = f, .name = if (e.title.len > 0) e.title else e.id, .owner = owner };
}

fn openCode(app: *App, idx: usize) void {
    const f = fileOf(app, app.catalog.entries.items[idx]) orelse return;
    doctabs.showCode(app, f, null);
}

fn copyClicked(app: *App, idx: usize, mode: CopyMode) void {
    copyEntryAs(app, idx, mode) catch |err| app.setStatus(tx.st_copy_failed, .{err});
}

/// Sets field `name` of entry `e` (CLI `--entry`): `act` (enemy look),
/// `spriteFile`, `meshFile` (strings) or a number (`hp` of a fighter sets max_hp too).
pub fn setField(app: *App, e: Entry, name: []const u8, value: []const u8) !void {
    const file = fileOf(app, e) orelse return error.NotFound;
    if (std.mem.eql(u8, name, "act")) return setAct(app, file, value);
    if (std.mem.eql(u8, name, "icon") or std.mem.eql(u8, name, "portrait") or std.mem.eql(u8, name, "mesh")) return setString(app, file, name, value);
    // Only fighters declare max_hp: in an item (Item.s) the exe logs "Cannot find variable".
    const pair = (e.kind == .enemy or e.kind == .hero) and std.mem.eql(u8, name, "hp");
    const names: []const []const u8 = if (pair) &.{ "hp", "max_hp" } else &.{name};
    return model.set(app, file, names, value, afterFor(e.kind));
}

/// A new look (`act_*.ss`: model, animations). The look also carries the fighter's
/// classic_id (name, resistances, special rules), so the class keeps its own after it.
pub fn setAct(app: *App, file: usize, act: []const u8) !void {
    const text = app.store.text(file);
    const old = actOf(text) orelse return error.NoLook;
    var ob: [128]u8 = undefined;
    var nb: [128]u8 = undefined;
    const id: ?f32 = model.ownNum(app, file, "classic_id") orelse blk: {
        const ai = app.store.file(common_archive, try std.fmt.bufPrint(&ob, "classes\\{s}", .{old})) catch break :blk null;
        break :blk model.ownNum(app, ai, "classic_id");
    };
    try app.store.replaceText(file, try std.fmt.bufPrint(&ob, "#include {s}", .{old}), try std.fmt.bufPrint(&nb, "#include {s}", .{act}));
    if (id) |v| try model.set(app, file, &.{"classic_id"}, try std.fmt.bufPrint(&nb, "{d}", .{v}), "#include act_");
}

pub fn setString(app: *App, file: usize, name: []const u8, v: []const u8) !void {
    var buf: [128]u8 = undefined;
    try model.set(app, file, &.{name}, try std.fmt.bufPrint(&buf, "\"{s}\"", .{v}), "{");
}

const picker = @import("picker.zig");
const frame = @import("frame.zig");
const char_page = @import("char_page.zig");
const item_page = @import("item_page.zig");

//! Every kind of document the centre shows (a `Tab`), one row each: its tier, its page,
//! its tab's icon, and how its open document is named, shown again and closed. A new kind
//! of page is a row here (and its `Tab`), not edits across main.zig and doctabs.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tx = @import("text.zig");
const icons = @import("icons.zig");
const entries = @import("entries.zig");
const sprview = @import("sprview.zig");
const look_pages = @import("look_pages.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Tab = app_mod.Tab;

/// Where a kind stands (the asset tree's groups): an assembly (a level, a battle, a
/// character) only picks and attaches components and assets, a component (a weapon, an
/// item, an AI profile) assets; assets (models, sounds, scripts, texts…) are edited on
/// their own page; the project's pages (the campaign, rules tables, engine settings).
pub const Tier = enum {
    assembly,
    component,
    asset,
    project,

    pub fn title(t: Tier) tx.Msg {
        return switch (t) {
            .assembly => tx.tier_assembly,
            .component => tx.tier_component,
            .asset => tx.tier_asset,
            .project => tx.tier_project,
        };
    }
};

pub const Kind = struct {
    icon: icons.Icon,
    /// Null: the editor's own (the Reference, the history, the settings).
    tier: ?Tier,
    /// The centre (null: the level's map).
    page: ?*const fn (*App, Allocator) void = null,
    /// The open document's key (doctabs.DocTab); null when none is.
    current: *const fn (*App, Allocator) ?[]const u8,
    /// Document `key` shown (the only writer of its page's document field).
    open: *const fn (*App, Tab, []const u8) void,
    /// Its tab closed while shown, no other tab left.
    close: *const fn (*App, Tab) void,
    /// The tab's label instead of the document's name.
    title: ?tx.Msg = null,
};

pub fn of(t: Tab) Kind {
    return table.get(t);
}

/// Tab label of document `key`: its kind's title, else its name (an entry's id, a
/// file's entry without its archive).
pub fn label(app: *App, t: Tab, key: []const u8) []const u8 {
    if (of(t).title) |m| return tx.get(m);
    return switch (t) {
        .characters, .items => if (entries.entryByKey(app, key)) |i| blk: {
            const e = app.catalog.entries.items[i];
            break :blk if (e.title.len > 0) e.title else e.id;
        } else |_| key,
        .sprites, .anims => key[if (std.mem.lastIndexOfAny(u8, key, "|\\")) |k| k + 1 else 0..],
        .code => key[if (std.mem.indexOfScalar(u8, key, '|')) |k| k + 1 else 0..],
        .ai_profiles => if (std.mem.startsWith(u8, key, "ai::")) key else if (aiRow(key)) |r| @import("entry_attacks.zig").profileName(app.frame.allocator(), r) else tx.get(tx.aip_title),
        else => key,
    };
}

const table: std.EnumArray(Tab, Kind) = .init(.{
    .battles = level(.swords),
    .locations = level(.map_pin),
    .characters = entry(.user, .assembly),
    .items = entry(.package, .component),
    .scenes = .{ .icon = .clapperboard, .tier = .asset, .page = @import("scenepage.zig").page, .current = sceneName, .open = sceneOpen, .close = sceneClose },
    .sounds = named(.volume_2, @import("soundpage.zig").page, soundSel),
    .videos = named(.play, @import("videopage.zig").page, videoSel),
    .music = named(.volume_2, @import("musicpage.zig").page, musicSel),
    .fonts = named(.file_text, @import("fontpage.zig").page, fontSel),
    .effects = named(.image, @import("effectpage.zig").page, effectSel),
    .texts = .{ .icon = .file_text, .tier = .asset, .page = @import("textpage.zig").page, .current = textName, .open = textOpen, .close = backToLocations },
    .sprites = .{ .icon = .image, .tier = .asset, .page = sprview.page, .current = spriteName, .open = spriteOpen, .close = spriteClose },
    .adjust = single(.settings, .project, @import("adjustpage.zig").page, tx.adj_title),
    .campaign = single(.play, .project, @import("campaignpage.zig").page, tx.camp_title),
    .ui = single(.maximize, .project, @import("campaignpage.zig").uiPage, tx.ui_title),
    .exp_levels = single(.layers, .project, @import("rulespages.zig").expPage, tx.xp_title),
    .values = single(.crosshair, .project, @import("rulespages.zig").valuesPage, tx.val_title),
    .ai_profiles = .{ .icon = .swords, .tier = .component, .page = @import("rulespages.zig").aiPage, .current = aiName, .open = aiOpen, .close = aiClose },
    .actions = single(.hand, .project, @import("rulespages.zig").actionsPage, tx.act_title),
    .post = single(.image, .project, @import("postpage.zig").page, tx.post_title),
    .reference = single(.search, null, @import("reference.zig").page, tx.ref_title),
    .testkit = single(.package, null, @import("testkit.zig").page, tx.sec_testkit),
    .history = single(.history, null, @import("history.zig").historyPage, tx.tab_history),
    .settings = single(.settings, null, @import("settingspage.zig").settingsPage, tx.tab_settings),
    // Code is over any kind (`app.code`); its tabs are handled by codeview.
    .code = .{ .icon = .code, .tier = .asset, .current = none, .open = noOpen, .close = noClose },
    .models = named(.box, look_pages.modelPage, modelSel),
    .anims = named(.play, look_pages.animsPage, animsSel),
    .textures = named(.image, look_pages.texturePage, textureSel),
    .traits = tiered(named(.layers, @import("traitpage.zig").traitPage, traitSel), .component),
    .components = tiered(named(.code, @import("traitpage.zig").compPage, compSel), .component),
});

fn tiered(k: Kind, t: Tier) Kind {
    var out = k;
    out.tier = t;
    return out;
}

fn none(_: *App, _: Allocator) ?[]const u8 {
    return null;
}
fn noOpen(_: *App, _: Tab, _: []const u8) void {}
fn noClose(_: *App, _: Tab) void {}
fn backToLocations(app: *App, _: Tab) void {
    app.setTab(.locations);
}

/// A level (a location or a battle): the map in the centre.
fn level(icon: icons.Icon) Kind {
    return .{ .icon = icon, .tier = .assembly, .current = levelName, .open = levelOpen, .close = levelClose };
}
fn levelName(app: *App, _: Allocator) ?[]const u8 {
    return if (app.current) |i| app.levels[i].name else null;
}
fn levelOpen(app: *App, t: Tab, n: []const u8) void {
    const i = app.levelIndex(n) orelse return;
    app.setTab(t);
    // Read through the Store: the unsaved edits of every tab stay.
    if (app.current == null or app.current.? != i) app.open(i, false);
}
fn levelClose(app: *App, _: Tab) void {
    app.closeLevel();
}

/// The tab of a catalog entry of kind `k`.
pub fn tabOf(k: @import("catalog.zig").Kind) Tab {
    return switch (k) {
        .enemy, .hero => .characters,
        else => .items,
    };
}

/// An enemy, an item or a hero of the catalog.
fn entry(icon: icons.Icon, tier: Tier) Kind {
    return .{ .icon = icon, .tier = tier, .page = entries.page, .current = entryName, .open = entryOpen, .close = entryClose };
}
/// "archive|entry" (ids are not unique: heroes of two levels share one).
fn entryName(app: *App, a: Allocator) ?[]const u8 {
    return if (app.entry) |i| entries.keyOf(a, app.catalog.entries.items[i]) else null;
}
fn entryOpen(app: *App, t: Tab, n: []const u8) void {
    app.setTab(t);
    app.entry = entries.entryByKey(app, n) catch null;
    app.pick = null;
}
fn entryClose(app: *App, _: Tab) void {
    app.entry = null;
}

/// A page showing the file picked by name (a sound, a track, a font…).
fn named(icon: icons.Icon, page: *const fn (*App, Allocator) void, comptime sel: anytype) Kind {
    const S = struct {
        fn current(app: *App, _: Allocator) ?[]const u8 {
            const n = sel(app).get();
            return if (n.len > 0) n else null;
        }
        fn open(app: *App, t: Tab, n: []const u8) void {
            app.setTab(t);
            sel(app).set(n);
        }
        fn close(app: *App, _: Tab) void {
            sel(app).set("");
        }
    };
    return .{ .icon = icon, .tier = .asset, .page = page, .current = S.current, .open = S.open, .close = S.close };
}

/// A page of its own, no document in it (the history, the settings).
fn single(icon: icons.Icon, tier: ?Tier, page: *const fn (*App, Allocator) void, title: tx.Msg) Kind {
    const S = struct {
        fn current(_: *App, _: Allocator) ?[]const u8 {
            return "";
        }
        fn open(app: *App, t: Tab, _: []const u8) void {
            app.setTab(t);
        }
    };
    return .{ .icon = icon, .tier = tier, .page = page, .current = S.current, .open = S.open, .close = backToLocations, .title = title };
}

/// An AI profile: its row's index in the rules in force ("": the list, none shown).
fn aiName(app: *App, a: Allocator) ?[]const u8 {
    // OpenGorky: a profile block by its path (aipage.zig).
    if (app.ogLayout()) return app.rules_page.aiPath();
    return if (app.rules_page.ai) |k| std.fmt.allocPrint(a, "{d}", .{k}) catch null else "";
}
fn aiOpen(app: *App, t: Tab, n: []const u8) void {
    app.setTab(t);
    if (app.ogLayout()) return app.rules_page.setAiPath(n);
    app.rules_page.ai = if (aiRow(n) != null) std.fmt.parseInt(usize, n, 10) catch null else null;
}
fn aiClose(app: *App, _: Tab) void {
    app.rules_page.ai = null;
    app.rules_page.setAiPath("");
    backToLocations(app, .ai_profiles);
}
fn aiRow(key: []const u8) ?@import("opengorky").rules.AiProfile {
    const k = std.fmt.parseInt(usize, key, 10) catch return null;
    const list = @import("opengorky").rules.active.ai_profiles;
    return if (k < list.len) list[k] else null;
}

/// A scene or a dialogue (`.dlg`), by name.
fn sceneName(app: *App, _: Allocator) ?[]const u8 {
    return app.dialogName() orelse app.sceneName();
}
fn sceneOpen(app: *App, _: Tab, n: []const u8) void {
    app.setTab(.scenes);
    app.scene.set(if (std.ascii.endsWithIgnoreCase(n, ".dlg") or app.sceneIndex(n) != null) n else "");
}
fn sceneClose(app: *App, _: Tab) void {
    app.scene.len = 0;
}

fn textName(app: *App, _: Allocator) ?[]const u8 {
    return app.texts.file.entry();
}
fn textOpen(app: *App, _: Tab, n: []const u8) void {
    app.setTab(.texts);
    for (std.enums.values(@import("texts.zig").File)) |v| if (std.mem.eql(u8, v.entry(), n)) {
        app.texts.file = v;
    };
}

/// "archive|entry".
fn spriteName(app: *App, a: Allocator) ?[]const u8 {
    const e = app.spr orelse return null;
    return @import("doctab.zig").join(a, app.store.files.items[e.file].archive, e.name) catch null;
}
fn spriteOpen(app: *App, _: Tab, n: []const u8) void {
    const p = @import("doctab.zig").split(n) orelse return;
    sprview.openEntry(app, p[0], p[1]) catch |err| app.failed(err);
}
fn spriteClose(app: *App, _: Tab) void {
    sprview.close(app);
}

fn soundSel(app: *App) *app_mod.Name(64) {
    return &app.sound_sel;
}
fn videoSel(app: *App) *app_mod.Name(64) {
    return &app.video.sel;
}
fn musicSel(app: *App) *app_mod.Name(64) {
    return &app.music.sel;
}
fn fontSel(app: *App) *app_mod.Name(64) {
    return &app.fonts.sel;
}
fn effectSel(app: *App) *app_mod.Name(64) {
    return &app.effect.sel;
}
fn modelSel(app: *App) *app_mod.Name(64) {
    return &app.model_sel;
}
fn animsSel(app: *App) *app_mod.Name(160) {
    return &app.anims_sel;
}
fn textureSel(app: *App) *app_mod.Name(64) {
    return &app.texture_sel;
}
fn traitSel(app: *App) *app_mod.Name(64) {
    return &app.trait_sel;
}
fn compSel(app: *App) *app_mod.Name(64) {
    return &app.comp_sel;
}

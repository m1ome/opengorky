//! Every kind of document the centre shows (a `Tab`), one row each: its page, its tab's
//! icon, and how its open document is named, shown again and closed. A new kind of page
//! is a row here (and its `Tab`), not edits across main.zig and doctabs.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tx = @import("text.zig");
const icons = @import("icons.zig");
const pages = @import("pages.zig");
const sprview = @import("sprview.zig");
const main = @import("app.zig");
const App = main.App;
const Tab = main.Tab;

pub const Kind = struct {
    icon: icons.Icon,
    /// The centre (null: the level's map).
    page: ?*const fn (*App, Allocator) void = null,
    /// The open document's name; null when none is.
    current: *const fn (*App, Allocator) ?[]const u8,
    /// Document `name` shown again (its tab clicked).
    open: *const fn (*App, Tab, []const u8) void,
    /// Its tab closed while shown, no other tab left.
    close: *const fn (*App, Tab) void,
    /// The tab's label instead of the document's name.
    title: ?tx.Msg = null,
};

pub fn of(t: Tab) Kind {
    return table.get(t);
}

const table: std.EnumArray(Tab, Kind) = .init(.{
    .battles = level(.swords),
    .locations = level(.map_pin),
    .enemies = entry(.user),
    .items = entry(.package),
    .heroes = entry(.user),
    .scenes = .{ .icon = .clapperboard, .page = @import("scenepage.zig").page, .current = sceneName, .open = sceneOpen, .close = sceneClose },
    .sounds = named(.volume_2, @import("soundpage.zig").page, soundSel),
    .videos = named(.play, @import("videopage.zig").page, videoSel),
    .music = named(.volume_2, @import("musicpage.zig").page, musicSel),
    .fonts = named(.file_text, @import("fontpage.zig").page, fontSel),
    .effects = named(.image, @import("effectpage.zig").page, effectSel),
    .texts = .{ .icon = .file_text, .page = @import("textpage.zig").page, .current = textName, .open = textOpen, .close = backToLocations },
    .sprites = .{ .icon = .image, .page = sprview.page, .current = spriteName, .open = spriteOpen, .close = spriteClose },
    .adjust = single(.settings, @import("adjustpage.zig").page, tx.adj_title),
    .history = single(.history, @import("main.zig").historyPage, tx.tab_history),
    .settings = single(.settings, @import("main.zig").settingsPage, tx.tab_settings),
    // Code is over any kind (`app.code`); its tabs are handled by codeview.
    .code = .{ .icon = .code, .current = none, .open = noOpen, .close = noClose },
});

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
    return .{ .icon = icon, .current = levelName, .open = levelOpen, .close = levelClose };
}
fn levelName(app: *App, _: Allocator) ?[]const u8 {
    return if (app.current) |i| app.levels[i].name else null;
}
fn levelOpen(app: *App, t: Tab, n: []const u8) void {
    for (app.levels, 0..) |lv, i| if (std.ascii.eqlIgnoreCase(lv.name, n)) {
        app.setTab(t);
        if (app.current == null or app.current.? != i) app.requestOpen(i);
        return;
    };
}
fn levelClose(app: *App, _: Tab) void {
    app.closeLevel();
}

/// An enemy, an item or a hero of the catalog.
fn entry(icon: icons.Icon) Kind {
    return .{ .icon = icon, .page = pages.page, .current = entryName, .open = entryOpen, .close = entryClose };
}
fn entryName(app: *App, _: Allocator) ?[]const u8 {
    return if (app.entry) |i| app.catalog.entries.items[i].id else null;
}
fn entryOpen(app: *App, t: Tab, n: []const u8) void {
    app.setTab(t);
    app.entry = pages.entryById(app, n) catch null;
    app.picker = null;
}
fn entryClose(app: *App, _: Tab) void {
    app.entry = null;
}

/// A page showing the file picked by name (a sound, a track, a font…).
fn named(icon: icons.Icon, page: *const fn (*App, Allocator) void, comptime sel: fn (*App) *main.Name(64)) Kind {
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
    return .{ .icon = icon, .page = page, .current = S.current, .open = S.open, .close = S.close };
}

/// A page of its own, no document in it (the history, the settings).
fn single(icon: icons.Icon, page: *const fn (*App, Allocator) void, title: tx.Msg) Kind {
    const S = struct {
        fn current(_: *App, _: Allocator) ?[]const u8 {
            return "";
        }
        fn open(app: *App, t: Tab, _: []const u8) void {
            app.setTab(t);
        }
    };
    return .{ .icon = icon, .page = page, .current = S.current, .open = S.open, .close = backToLocations, .title = title };
}

fn sceneName(app: *App, _: Allocator) ?[]const u8 {
    if (app.scenes.dlg.len > 0) return app.scenes.dlg.get();
    return if (app.scene) |i| app.catalog.scenes.items[i].name else null;
}
fn sceneOpen(app: *App, _: Tab, n: []const u8) void {
    if (std.ascii.endsWithIgnoreCase(n, ".dlg")) return app.showDialog(n);
    app.setTab(.scenes);
    app.scenes.dlg.len = 0;
    app.scene = for (app.catalog.scenes.items, 0..) |sc, i| {
        if (std.ascii.eqlIgnoreCase(sc.name, n)) break i;
    } else null;
}
fn sceneClose(app: *App, _: Tab) void {
    app.scene = null;
    app.scenes.dlg.len = 0;
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
    return std.fmt.allocPrint(a, "{s}|{s}", .{ app.store.files.items[e.file].archive, e.name }) catch null;
}
fn spriteOpen(app: *App, _: Tab, n: []const u8) void {
    const bar = std.mem.indexOfScalar(u8, n, '|') orelse return;
    sprview.openEntry(app, n[0..bar], n[bar + 1 ..]) catch |err| app.setStatus(tx.st_set_failed, .{err});
}
fn spriteClose(app: *App, _: Tab) void {
    sprview.close(app);
}

fn soundSel(app: *App) *main.Name(64) {
    return &app.sound_sel;
}
fn videoSel(app: *App) *main.Name(64) {
    return &app.video.sel;
}
fn musicSel(app: *App) *main.Name(64) {
    return &app.music.sel;
}
fn fontSel(app: *App) *main.Name(64) {
    return &app.fonts.sel;
}
fn effectSel(app: *App) *main.Name(64) {
    return &app.effect.sel;
}

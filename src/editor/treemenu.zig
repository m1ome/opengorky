//! The asset tree's right-click menu and its clipboard: open, copy, paste, duplicate,
//! rename (scenes). A copy is a new asset of the same kind beside the original: a scene
//! with its own points and lines, a class, a script, a sound, a video, a level made
//! from the level (as "New level from this one").

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tx = @import("text.zig");
const pages = @import("pages.zig");
const codeview = @import("codeview.zig");
const videopage = @import("videopage.zig");
const soundpage = @import("soundpage.zig");
const ui_main = @import("main.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const store_mod = @import("store.zig");
const common_archive = store_mod.common_archive;
const voices = @import("voices.zig");
const clay = @import("clay.zig");

pub const Kind = enum { level, entry, scene, script, sound, video };

/// A tree row: its kind and name (level, entry id, scene, script entry, sound, video).
pub const Item = struct {
    kind: Kind,
    buf: [64]u8 = undefined,
    len: usize = 0,

    pub fn of(kind: Kind, n: []const u8) Item {
        var it: Item = .{ .kind = kind };
        it.len = @min(n.len, it.buf.len);
        @memcpy(it.buf[0..it.len], n[0..it.len]);
        return it;
    }

    pub fn name(self: *const Item) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Menu = struct { at: [2]f32, item: Item };

/// The document shown now as a tree item (what Cmd+C copies outside the level's objects).
pub fn current(app: *App) ?Item {
    return switch (app.tab) {
        .battles, .locations => if (app.current) |i| Item.of(.level, app.levels[i].name) else null,
        .enemies, .items, .heroes => if (app.entry) |i| Item.of(.entry, app.catalog.entries.items[i].id) else null,
        .scenes => if (app.scenes.dlg.len == 0) if (app.scene) |i| Item.of(.scene, app.catalog.scenes.items[i].name) else null else null,
        .sounds => if (app.sound_sel.get().len > 0) Item.of(.sound, app.sound_sel.get()) else null,
        .videos => if (app.video.sel.get().len > 0) Item.of(.video, app.video.sel.get()) else null,
        else => null,
    };
}

pub fn copy(app: *App, it: Item) void {
    app.tree_clip = it;
    app.setStatus(tx.st_tree_copied, .{it.name()});
}

/// The menu for row `it` at the pointer.
pub fn open(app: *App, it: Item) void {
    app.tree_menu = .{ .at = .{ app.mouse[0] + 2, @min(app.mouse[1], app.size[1] - 260) }, .item = it };
}

pub fn draw(app: *App, a: Allocator) void {
    const m = app.tree_menu orelse return;
    const it = m.item;
    ui_main.menuPanel(clay.id("tree_menu"), 250, .{ .offset = .{ .x = m.at[0], .y = m.at[1] }, .zIndex = 100, .attachTo = ui.CLAY_ATTACH_TO_ROOT });
    // Its name lives in this frame (clay draws after this returns).
    ui_main.menuTitle(a, a.dupe(u8, it.name()) catch "", tx.get(kindName(it.kind)));
    ui_main.menuLine();
    if (ui_main.menuRow(app, "tm_open", .file_text, tx.get(tx.tm_open), "", theme.text, true)) openItem(app, it);
    ui_main.menuLine();
    if (ui_main.menuRow(app, "tm_copy", .copy, tx.get(tx.cm_copy), ui_main.cmdKey(a, "C"), theme.text, true)) copy(app, it);
    const can_paste = app.tree_clip != null;
    if (ui_main.menuRow(app, "tm_paste", .copy, tx.get(tx.tm_paste), ui_main.cmdKey(a, "V"), theme.text, can_paste)) duplicate(app, app.tree_clip.?);
    if (ui_main.menuRow(app, "tm_dup", .copy, tx.get(tx.cm_duplicate), ui_main.cmdKey(a, "D"), theme.text, true)) duplicate(app, it);
    if (ui_main.menuRow(app, "tm_rename", .pencil, tx.get(tx.cm_rename), "", theme.text, it.kind == .scene)) renameScene(app, it.name());
    clay.close();
}

const ui = @import("ui");

fn kindName(k: Kind) tx.Msg {
    return switch (k) {
        .level => tx.tm_k_level,
        .entry => tx.tm_k_entry,
        .scene => tx.tm_k_scene,
        .script => tx.tm_k_script,
        .sound => tx.tm_k_sound,
        .video => tx.tm_k_video,
    };
}

/// Row `it` opened as a click on it does.
pub fn openItem(app: *App, it: Item) void {
    const n = it.name();
    switch (it.kind) {
        .level => app.showLevel(n, null),
        .entry => if (pages.entryById(app, n)) |i| {
            app.setTab(switch (app.catalog.entries.items[i].kind) {
                .enemy => .enemies,
                .hero => .heroes,
                else => .items,
            });
            app.entry = i;
        } else |_| {},
        .scene => app.showScene(n),
        .script => if (app.store.file(common_archive, n)) |f| codeview.open(app, f, null) else |_| {},
        .sound => {
            app.setTab(.sounds);
            app.sound_sel.set(n);
        },
        .video => {
            app.setTab(.videos);
            app.video.sel.set(n);
        },
    }
}

fn renameScene(app: *App, n: []const u8) void {
    app.showScene(n);
    app.scenes.naming = true;
    app.scenes.name.set(n);
}

/// A copy of `it` beside it, opened (Paste and Duplicate).
pub fn duplicate(app: *App, it: Item) void {
    const r = switch (it.kind) {
        .level => copyLevel(app, it.name()),
        .entry => if (pages.entryById(app, it.name())) |i| pages.copyEntry(app, i) else |e| e,
        .scene => copyScene(app, it.name()),
        .script => copyScript(app, it.name()),
        .sound => copySound(app, it.name()),
        .video => copyVideo(app, it.name()),
    };
    r catch |err| app.setStatus(tx.st_tree_copy_failed, .{ it.name(), err });
}

/// `base` with `_copy`, `_copy2`… — the first that `taken` does not have (`ext` after it).
fn freeName(buf: []u8, base: []const u8, ext: []const u8, ctx: anytype, taken: fn (@TypeOf(ctx), []const u8) bool) ![]const u8 {
    for (1..1000) |n| {
        const s = if (n == 1) try std.fmt.bufPrint(buf, "{s}_copy{s}", .{ base, ext }) else try std.fmt.bufPrint(buf, "{s}_copy{d}{s}", .{ base, n, ext });
        if (!taken(ctx, s)) return s;
    }
    return error.NoFreeName;
}

/// A level made from level `n` (opened first): the editor's "new level from this one".
fn copyLevel(app: *App, n: []const u8) !void {
    const i = for (app.levels, 0..) |lv, k| {
        if (std.ascii.eqlIgnoreCase(lv.name, n)) break k;
    } else return error.NotFound;
    const battle = app.levels[i].battle;
    if (app.current == null or app.current.? != i) {
        app.setTab(if (battle) .battles else .locations);
        app.requestOpen(i);
        // Unsaved edits: the first request only warns.
        if (app.current == null or app.current.? != i) return;
    }
    var nb: [32]u8 = undefined;
    // Level names are 24 letters at most: the original's name shortened to fit.
    const base = n[0..@min(n.len, 15)];
    const name = for (2..100) |k| {
        const s = try std.fmt.bufPrint(&nb, "{s}_c{d}", .{ base, k });
        for (app.levels) |lv| {
            if (std.ascii.eqlIgnoreCase(lv.name, s)) break;
        } else break s;
    } else return error.NoFreeName;
    app.newLevel(app.frame.allocator().dupe(u8, name) catch return);
}

/// Scene `n` copied: its script, points and each dialogue it starts (the copy's lines
/// are its own), one undo step.
fn copyScene(app: *App, n: []const u8) !void {
    const a = app.frame.allocator();
    var eb: [96]u8 = undefined;
    const scr = try app.store.file(common_archive, try std.fmt.bufPrint(&eb, "scriptlets\\{s}.scr", .{n}));
    var nb: [64]u8 = undefined;
    const new = try freeName(&nb, n, "", app, struct {
        fn taken(ap: *App, s: []const u8) bool {
            for (ap.catalog.scenes.items) |sc| if (std.ascii.eqlIgnoreCase(sc.name, s)) return true;
            return false;
        }
    }.taken);
    var text = try a.dupe(u8, app.store.text(scr));
    var files: std.ArrayList(store_mod.NewFile) = .empty;
    // DIALOG_INIT("id","file.dlg"): each file copied as <new>.dlg, <new>_2.dlg…
    var k: usize = 0;
    var from: usize = 0;
    while (std.ascii.findIgnoreCasePos(text, from, "DIALOG_INIT(")) |at| {
        from = at + 12;
        const q1 = std.mem.indexOfScalarPos(u8, text, from, ',') orelse break;
        const s = std.mem.indexOfScalarPos(u8, text, q1, '"') orelse break;
        const e = std.mem.indexOfScalarPos(u8, text, s + 1, '"') orelse break;
        const dlg = text[s + 1 .. e];
        const df = app.store.file("common/lang.dat", dlg) catch continue;
        k += 1;
        const nd = if (k == 1) try std.fmt.allocPrint(a, "{s}.dlg", .{new}) else try std.fmt.allocPrint(a, "{s}_{d}.dlg", .{ new, k });
        try files.append(a, .{ .archive = "common/lang.dat", .entry = nd, .text = try app.gpa.dupe(u8, app.store.text(df)) });
        try copyVoices(app, a, &files, dlg, nd);
        text = try std.mem.concat(a, u8, &.{ text[0 .. s + 1], nd, text[e..] });
        from = s + 1 + nd.len;
    }
    try files.insert(a, 0, .{ .archive = common_archive, .entry = try std.fmt.allocPrint(a, "scriptlets\\{s}.scr", .{new}), .text = try app.gpa.dupe(u8, text) });
    if (app.store.file(common_archive, try std.fmt.bufPrint(&eb, "scriptlets\\{s}.pts", .{n}))) |pf| {
        try files.append(a, .{ .archive = common_archive, .entry = try std.fmt.allocPrint(a, "scriptlets\\{s}.pts", .{new}), .text = try app.gpa.dupe(u8, app.store.text(pf)) });
    } else |_| {}
    _ = try app.store.addNew(files.items);
    const ca = app.catalog.arena.allocator();
    try app.catalog.scenes.append(ca, .{ .name = try ca.dupe(u8, new) });
    app.showScene(new);
    app.setStatus(tx.st_tree_made, .{ new, n });
}

/// Speech of dialogue `old` (`<stem>_<code>_<NN>.wav`) under dialogue `new`'s stem.
fn copyVoices(app: *App, a: Allocator, files: *std.ArrayList(store_mod.NewFile), old: []const u8, new: []const u8) !void {
    const os = try voiceStem(a, old);
    const ns = try voiceStem(a, new);
    for (voices.names(app, a, os)) |v| {
        // `su_02.wav` after the stem (not a longer dialogue's that starts alike).
        const rest = v[os.len..];
        if (rest.len != "su_02.wav".len or rest[2] != '_') continue;
        const bytes = voices.bytesOf(app, a, v) orelse continue;
        try files.append(a, .{ .archive = voices.archive_path, .entry = try std.fmt.allocPrint(a, "{s}{s}", .{ ns, rest }), .text = try app.gpa.dupe(u8, bytes) });
    }
}

/// `city-x.dlg` → `city_x_` (formats/dialog.zig voiceName).
fn voiceStem(a: Allocator, dlg: []const u8) ![]const u8 {
    const stem = dlg[0 .. std.mem.lastIndexOfScalar(u8, dlg, '.') orelse dlg.len];
    const s = try std.fmt.allocPrint(a, "{s}_", .{stem});
    std.mem.replaceScalar(u8, s, '-', '_');
    _ = std.ascii.lowerString(s, s);
    return s;
}

fn copyScript(app: *App, entry: []const u8) !void {
    const f = try app.store.file(common_archive, entry);
    const stem = entry[0 .. std.mem.lastIndexOfScalar(u8, entry, '.') orelse entry.len];
    var nb: [96]u8 = undefined;
    const new = try freeName(&nb, stem, ".s", app, struct {
        fn taken(ap: *App, s: []const u8) bool {
            return ap.store.find(common_archive, s) != null or (ap.store.file(common_archive, s) catch null) != null;
        }
    }.taken);
    const nf = try app.store.addNew(&.{.{ .archive = common_archive, .entry = new, .text = try app.gpa.dupe(u8, app.store.text(f)) }});
    codeview.open(app, nf, null);
    app.setStatus(tx.st_tree_made, .{ new, entry });
}

fn copySound(app: *App, n: []const u8) !void {
    const bytes = soundpage.bytesOf(app, app.frame.allocator(), n) orelse return error.NotFound;
    var nb: [64]u8 = undefined;
    const new = try freeName(&nb, std.fs.path.stem(n), ".wav", app, struct {
        fn taken(ap: *App, s: []const u8) bool {
            for (ap.player.names(ap, ap.frame.allocator())) |x| if (std.ascii.eqlIgnoreCase(x, s)) return true;
            return false;
        }
    }.taken);
    _ = try app.store.addNew(&.{.{ .archive = soundpage.archive_path, .entry = new, .text = try app.gpa.dupe(u8, bytes) }});
    app.setTab(.sounds);
    app.sound_sel.set(new);
    app.setStatus(tx.st_tree_made, .{ new, n });
}

fn copyVideo(app: *App, n: []const u8) !void {
    var nb: [48]u8 = undefined;
    const new = try freeName(&nb, std.fs.path.stem(n), ".asf", app, struct {
        fn taken(ap: *App, s: []const u8) bool {
            for (videopage.names(ap)) |x| if (std.ascii.eqlIgnoreCase(x, s)) return true;
            return false;
        }
    }.taken);
    const a = app.frame.allocator();
    var root = try Io.Dir.cwd().openDir(app.io, app.game_dir, .{});
    defer root.close(app.io);
    try root.copyFile(try std.fmt.allocPrint(a, "avi/{s}", .{n}), root, try std.fmt.allocPrint(a, "avi/{s}", .{new}), app.io, .{});
    app.video.read = false;
    app.setTab(.videos);
    app.video.sel.set(new);
    app.setStatus(tx.st_tree_made, .{ new, n });
}

test freeName {
    var buf: [32]u8 = undefined;
    const taken = struct {
        fn f(_: void, s: []const u8) bool {
            return std.mem.eql(u8, s, "a_copy.s");
        }
    }.f;
    try std.testing.expectEqualStrings("a_copy2.s", try freeName(&buf, "a", ".s", {}, taken));
}

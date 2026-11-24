//! The asset tree's right-click menu and its clipboard: open, copy, paste, duplicate,
//! rename (scenes). A copy is a new asset of the same kind beside the original: a scene
//! with its own points and lines, a class, a script, a sound, a video, a level made
//! from the level (as "New level from this one").

const std = @import("std");
const Allocator = std.mem.Allocator;
const tx = @import("text.zig");
const entries = @import("entries.zig");
const doctabs = @import("doctabs.zig");
const kinds = @import("kinds.zig");
const videopage = @import("videopage.zig");
const soundpage = @import("soundpage.zig");
const main = @import("main.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const levelops = @import("levelops.zig");
const theme = app_mod.theme;
const store_mod = @import("store.zig");
const common_archive = store_mod.common_archive;
const voices = @import("voices.zig");
const dialog = @import("opengorky").formats.dialog;
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");

pub const Kind = enum { level, entry, scene, script, sound, video, model };

/// A tree row: its kind and name (level, entry `archive|entry` or id, scene, script entry,
/// sound, video).
pub const Item = struct {
    kind: Kind,
    buf: [160]u8 = undefined,
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

/// The document shown now as a tree item (what Cmd+C copies outside the level's objects;
/// none over code).
pub fn current(app: *App) ?Item {
    doctabs.refresh(app);
    const d = app.active orelse return null;
    const k = d.key();
    return switch (d.tab) {
        .battles, .locations => Item.of(.level, k),
        .characters, .items => Item.of(.entry, k),
        .scenes => if (std.ascii.endsWithIgnoreCase(k, ".dlg")) null else Item.of(.scene, k),
        .sounds => Item.of(.sound, k),
        .videos => Item.of(.video, k),
        else => null,
    };
}

pub fn copy(app: *App, it: Item) void {
    app.tree_clip = it;
    app.setStatus(tx.st_tree_copied, .{it.name()});
}

/// The menu for row `it` at the pointer.
pub fn open(app: *App, it: Item) void {
    app.tree_menu = .{ .at = .{ app.mouse[0] + 2, @min(app.mouse[1], app.size[1] - lay.width.menu) }, .item = it };
}

pub fn draw(app: *App, a: Allocator) void {
    const m = app.tree_menu orelse return;
    const it = m.item;
    gui.menuPanel(clay.id("tree_menu"), lay.width.menu, .{ .offset = .{ .x = m.at[0], .y = m.at[1] }, .zIndex = 100, .attachTo = ui.CLAY_ATTACH_TO_ROOT });
    // Its name lives in this frame (clay draws after this returns).
    const title = if (it.kind == .entry) kinds.label(app, .items, it.name()) else it.name();
    gui.menuTitle(a, a.dupe(u8, title) catch "", tx.get(kindName(it.kind)));
    gui.menuLine();
    if (gui.menuRow(app, "tm_open", .file_text, tx.get(tx.tm_open), "", theme.text, true)) openItem(app, it);
    gui.menuLine();
    // A model: no copy of its own (a new one comes from a .glb); its export instead.
    const copies = it.kind != .model;
    if (gui.menuRow(app, "tm_copy", .copy, tx.get(tx.cm_copy), main.cmdKey(a, "C"), theme.text, copies)) copy(app, it);
    const can_paste = app.tree_clip != null;
    if (gui.menuRow(app, "tm_paste", .copy, tx.get(tx.tm_paste), main.cmdKey(a, "V"), theme.text, can_paste)) duplicate(app, app.tree_clip.?);
    if (gui.menuRow(app, "tm_dup", .copy, tx.get(tx.cm_duplicate), main.cmdKey(a, "D"), theme.text, copies)) duplicate(app, it);
    if (gui.menuRow(app, "tm_rename", .pencil, tx.get(tx.cm_rename), "", theme.text, it.kind == .scene)) renameScene(app, it.name());
    if (it.kind == .model and gui.menuRow(app, "tm_glb", .log_out, tx.get(tx.b_glb_out), "", theme.text, true)) {
        doctabs.show(app, .models, it.name());
        app.askFile(.{ .kind = .glb_out, .run = @import("look_pages.zig").onGlbOut, .name = it.name() });
    }
    // OpenGorky: an entry's block or a model of the project's own, asked first.
    if (app.ogLayout() and (it.kind == .entry or it.kind == .model)) {
        gui.menuLine();
        if (gui.menuRow(app, "tm_delete", .trash_2, tx.get(tx.cm_delete), "", theme.warn, true)) askDelete(app, it, title);
    }
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
        .model => tx.tm_k_model,
    };
}

/// Row `it` opened as a click on it does.
fn openItem(app: *App, it: Item) void {
    const n = it.name();
    switch (it.kind) {
        .level => app.showLevel(n, null),
        .entry => if (entries.entryByKey(app, n)) |i| doctabs.show(app, kinds.tabOf(app.catalog.entries.items[i].kind), n) else |_| {},
        .scene => app.showScene(n),
        .script => if (app.store.file(common_archive, n)) |f| doctabs.showCode(app, f, null) else |_| {},
        .sound => doctabs.show(app, .sounds, n),
        .video => doctabs.show(app, .videos, n),
        .model => doctabs.show(app, .models, n),
    }
}

/// Delete for row `it` (`title` its name): the confirmation, or a window saying why not
/// (an entry the project names elsewhere, a model worn or the game's).
fn askDelete(app: *App, it: Item, title: []const u8) void {
    app.tree_menu = null;
    switch (it.kind) {
        .model => {
            if (!@import("look_pages.zig").modelFree(app, it.name())) return app.setAlert(tx.tm_delete_used, tx.tm_model_used, .{});
            app.askDelete(.model, 0, it.name());
        },
        .entry => {
            if (@import("entry_copy.zig").ogUsedIn(app, it.name())) |p| return app.setAlert(tx.tm_delete_used, tx.tm_used_in, .{p});
            app.askDelete(.entry, 0, it.name());
            // The question names it as the tree does, not by its key.
            const cf = &app.confirm.?;
            cf.text_len = tx.print(&cf.text_buf, tx.cf_delete, .{title}).len;
        },
        else => {},
    }
}

fn renameScene(app: *App, n: []const u8) void {
    app.showScene(n);
    @import("scenepage.zig").rename(app, n);
}

/// A copy of `it` beside it, opened (Paste and Duplicate).
pub fn duplicate(app: *App, it: Item) void {
    const r = switch (it.kind) {
        .level => copyLevel(app, it.name()),
        .entry => if (entries.entryByKey(app, it.name())) |i| entries.copyEntry(app, i) else |e| e,
        .scene => copyScene(app, it.name()),
        .script => copyScript(app, it.name()),
        .sound => copySound(app, it.name()),
        .video => copyVideo(app, it.name()),
        .model => return,
    };
    r catch |err| app.setStatus(tx.st_tree_copy_failed, .{ it.name(), err });
}

/// `base` with `_copy`, `_copy2`… — the first that `taken` does not have (`ext` after it).
fn freeName(buf: []u8, base: []const u8, ext: []const u8, ctx: anytype, comptime taken: fn (@TypeOf(ctx), []const u8) bool) ![]const u8 {
    var bb: [96]u8 = undefined;
    return @import("freename.zig").freeName(buf, try std.fmt.bufPrint(&bb, "{s}_copy", .{base}), .{ .sep = "", .ext = ext }, ctx, taken);
}

/// Level `n` copied whole beside it (levelops.copyLevel), opened.
fn copyLevel(app: *App, n: []const u8) !void {
    var nb: [32]u8 = undefined;
    // Level names are 24 letters at most: the original's name shortened to fit.
    const base = n[0..@min(n.len, 15)];
    const name = for (2..100) |k| {
        const s = try std.fmt.bufPrint(&nb, "{s}_c{d}", .{ base, k });
        if (app.levelIndex(s) == null) break s;
    } else return error.NoFreeName;
    return levelops.copyLevel(app, n, try app.frame.allocator().dupe(u8, name));
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
            return ap.sceneIndex(s) != null;
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

/// `city-x.dlg` → `city_x_` (formats/dialog.zig voicePrefix).
fn voiceStem(a: Allocator, dlg: []const u8) ![]const u8 {
    return dialog.voicePrefix(try a.alloc(u8, dlg.len + 1), dlg);
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
    doctabs.showCode(app, nf, null);
    app.setStatus(tx.st_tree_made, .{ new, entry });
}

fn copySound(app: *App, n: []const u8) !void {
    const bytes = soundpage.bytesOf(app, app.frame.allocator(), n) orelse return error.NotFound;
    var nb: [64]u8 = undefined;
    const new = try freeName(&nb, std.fs.path.stem(n), ".wav", app, soundpage.soundTaken);
    _ = try app.store.addNew(&.{.{ .archive = soundpage.archive_path, .entry = new, .text = try app.gpa.dupe(u8, bytes) }});
    doctabs.show(app, .sounds, new);
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
    // Through the store (saved, in the history), as an imported video.
    const f = try app.store.file(store_mod.video_dir, n);
    _ = try app.store.addNew(&.{.{ .archive = store_mod.video_dir, .entry = new, .text = try app.gpa.dupe(u8, app.store.text(f)) }});
    app.video.read = false;
    doctabs.show(app, .videos, new);
    app.setStatus(tx.st_tree_made, .{ new, n });
}

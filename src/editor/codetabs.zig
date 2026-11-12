//! The code window's open files (codeview.zig): one View per script file, shown,
//! parked, closed; Apply puts a View's text into the Store (one undo step).

const std = @import("std");
const og = @import("opengorky");
const tx = @import("text.zig");
const code = @import("code.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const View = code.View;
const codecheck = @import("codecheck.zig");
const model = @import("model.zig");

const check = codecheck.check;

/// Opens Store file `file` (its cursor at byte `at` of the game text, if given).
pub fn open(app: *App, file: usize, at: ?usize) void {
    // Open already (shown or in another tab): shown, the cursor moved.
    const have = if (app.code) |v| v.file == file else false;
    if (!have) {
        park(app);
        for (app.code_parked.items, 0..) |pv, k| if (pv.file == file) {
            app.code = app.code_parked.orderedRemove(k);
            break;
        };
    }
    if (app.code) |v| {
        if (at) |g| moveTo(app, v, g);
        return;
    }
    const bytes = app.store.text(file);
    const utf8 = code.fromFile(app.gpa, bytes, isUtf8(app, file), app.catalog.cyrillic) catch return;
    defer app.gpa.free(utf8);
    const v = app.gpa.create(View) catch return;
    v.* = .{ .buf = code.Buffer.init(app.gpa, utf8) catch return app.gpa.destroy(v), .file = file, .title = app.gpa.dupe(u8, app.store.files.items[file].entry) catch "", .store_hash = std.hash.Wyhash.hash(0, bytes) };
    v.buf.read_only = std.mem.eql(u8, app.store.files.items[file].archive, @import("store.zig").engine_dir);
    app.code = v;
    if (at) |g| moveTo(app, v, g);
}

/// The text read again from the Store when it changed there (a page's edit, undo).
pub fn refresh(app: *App, v: *View) void {
    if (!v.ogs_view) return v.follow(app.store.text(v.file), isUtf8(app, v.file), app.catalog.cyrillic) catch {};
    // The OG Script view: printed again from the Store's new text.
    const h = std.hash.Wyhash.hash(0, app.store.text(v.file));
    if (h == v.store_hash) return;
    if (v.buf.changed) {
        v.stale = true;
        return;
    }
    var tmp: std.heap.ArenaAllocator = .init(app.gpa);
    defer tmp.deinit();
    const t = model.ogsText(app, tmp.allocator(), v.file) orelse {
        // No longer shown as OG Script (it does not parse now): its own text.
        v.ogs_view = false;
        v.store_hash = 0;
        return refresh(app, v);
    };
    v.reread(code.fromGame(tmp.allocator(), t, app.catalog.cyrillic) catch return, h) catch {};
}

/// The view's text as OG Script (`ogs`: model.ogsText of the Classic script) or as its
/// own Classic text; unapplied edits are applied first (a refusal keeps the view as it is).
pub fn setView(app: *App, v: *View, ogs: bool) void {
    if (v.ogs_view == ogs) return;
    if (v.buf.changed) apply(app, v);
    if (v.buf.changed) return;
    if (ogs and model.ogsText(app, app.frame.allocator(), v.file) == null) return app.setStatus(tx.st_code_view_none, .{v.title});
    v.ogs_view = ogs;
    // Read anew at the next refresh, from its start.
    v.store_hash = 0;
    v.buf.cursor = 0;
    v.scroll = 0;
    v.checked = null;
    refresh(app, v);
}

/// Store file `file` is an OpenGorky one (OGS: rules\*.ss, the hooks, abilities, in
/// common/rules.dat): UTF-8, not the edition's bytes (the game's scripts).
pub fn isUtf8(app: *const App, file: usize) bool {
    const ar = app.store.files.items[file].archive;
    return std.mem.eql(u8, ar, @import("store.zig").og_src) or std.mem.eql(u8, ar, @import("store.zig").engine_dir);
}

/// The cursor to byte `g` of the game text (its line: UTF-8 and game text count lines alike).
fn moveTo(app: *App, v: *View, g: usize) void {
    const bytes = app.store.text(v.file);
    var line: usize = 0;
    for (bytes[0..@min(g, bytes.len)]) |ch| line += @intFromBool(ch == '\n');
    // A UTF-8 text is the buffer byte for byte: the very place; a game text's line.
    v.buf.cursor = if (isUtf8(app, v.file) and std.mem.eql(u8, bytes, v.buf.str())) @min(g, bytes.len) else code.lineOffset(v.buf.str(), line + 1);
    v.buf.anchor = null;
    // The line in the middle of the view (not drawn yet: as the editor's usual height).
    const vis: usize = if (v.rect.h > 0) @import("codedraw.zig").visibleLines(v) else 30;
    v.scroll = line -| vis / 2;
    v.follow_x = true;
}

/// The shown code kept in its tab (another document comes to the centre).
pub fn park(app: *App) void {
    const v = app.code orelse return;
    app.code = null;
    app.code_parked.append(app.gpa, v) catch v.destroy(app.gpa);
}

/// A view's tab key: `archive|entry` of its file (entry names repeat across levels).
pub fn keyOf(app: *App, v: *const View) []const u8 {
    const f = app.store.files.items[v.file];
    return @import("doctab.zig").join(app.frame.allocator(), f.archive, f.entry) catch f.entry;
}

/// The view of code tab `tk` (shown or in a tab), by its file; null when none.
fn viewOf(app: *App, tk: []const u8) ?*View {
    const p = @import("doctab.zig").split(tk) orelse return null;
    const f = app.store.find(p[0], p[1]) orelse return null;
    if (app.code) |v| if (v.file == f) return v;
    for (app.code_parked.items) |v| if (v.file == f) return v;
    return null;
}

/// Code tab `tk` has its view open.
pub fn has(app: *App, tk: []const u8) bool {
    return viewOf(app, tk) != null;
}

/// Code tab `tk` shown again, its file opened when no view has it.
pub fn show(app: *App, tk: []const u8) void {
    const v = viewOf(app, tk) orelse {
        const p = @import("doctab.zig").split(tk) orelse return;
        const f = app.store.file(p[0], p[1]) catch |err| return app.setStatus(tx.st_open_failed, .{ p[1], err });
        return open(app, f, null);
    };
    if (app.code == v) return;
    for (app.code_parked.items, 0..) |pv, k| if (pv == v) {
        _ = app.code_parked.orderedRemove(k);
        break;
    };
    park(app);
    app.code = v;
}

/// Views of files no longer there (their making undone, or deleted) closed, unapplied.
pub fn dropGone(app: *App) void {
    if (app.code) |v| if (app.store.gone(v.file)) {
        app.code = null;
        v.destroy(app.gpa);
    };
    var k: usize = 0;
    while (k < app.code_parked.items.len) {
        const v = app.code_parked.items[k];
        if (!app.store.gone(v.file)) {
            k += 1;
            continue;
        }
        _ = app.code_parked.orderedRemove(k);
        v.destroy(app.gpa);
    }
}

/// Code tab `tk` closed: its edits into the Store first (a syntax error keeps it open,
/// as Apply's first press). False if kept.
pub fn close(app: *App, tk: []const u8) bool {
    const v = viewOf(app, tk) orelse return true;
    const shown = app.code == v;
    if (v.buf.changed) apply(app, v);
    if (v.buf.changed) return false;
    if (shown) app.code = null else for (app.code_parked.items, 0..) |pv, k| if (pv == v) {
        _ = app.code_parked.orderedRemove(k);
        break;
    };
    v.destroy(app.gpa);
    return true;
}

/// Code tab `tk`'s unapplied edits applied; false if a syntax error holds them.
pub fn applyOne(app: *App, tk: []const u8) bool {
    const view = viewOf(app, tk) orelse return true;
    if (view.buf.changed) apply(app, view);
    return !view.buf.changed;
}

/// Every open code view (shown and in tabs) with unapplied edits applied; false if one
/// is held by a syntax error (its first warning).
pub fn applyAll(app: *App) bool {
    var ok = true;
    if (app.code) |v| if (v.buf.changed) {
        apply(app, v);
        ok = ok and !v.buf.changed;
    };
    for (app.code_parked.items) |v| if (v.buf.changed) {
        apply(app, v);
        ok = ok and !v.buf.changed;
    };
    return ok;
}

pub fn anyChanged(app: *const App) bool {
    if (app.code) |v| if (v.buf.changed) return true;
    for (app.code_parked.items) |v| if (v.buf.changed) return true;
    return false;
}

/// Writes the text into the Store (one undo step). With a syntax error the first
/// press only warns, the second applies as it is.
pub fn apply(app: *App, v: *View) void {
    refresh(app, v);
    // Changed elsewhere since its edits began: the first press only warns.
    if (v.stale) {
        v.stale = false;
        v.store_hash = std.hash.Wyhash.hash(0, app.store.text(v.file));
        return app.setStatus(tx.st_code_stale, .{v.title});
    }
    if (v.ogs_view) return applyOgs(app, v);
    check(app, v);
    if (v.err_line > 0 and !v.force) {
        v.force = true;
        return app.setStatus(tx.st_code_error, .{ v.err_line, v.err() });
    }
    const bytes = code.toFile(app.gpa, v.buf.str(), isUtf8(app, v.file), app.catalog.cyrillic) catch |err| return app.failed(err);
    if (std.mem.eql(u8, bytes, app.store.text(v.file))) {
        app.gpa.free(bytes);
        v.buf.changed = false;
        return;
    }
    const h = std.hash.Wyhash.hash(0, bytes);
    app.store.replace(v.file, bytes) catch |err| {
        app.gpa.free(bytes);
        return app.failed(err);
    };
    v.store_hash = h;
    v.buf.changed = false;
    // The views of the file (the open level's placements, the titles…) read again.
    app.afterStoreChange(v.file);
    app.setStatus(tx.st_code_applied, .{v.title});
}

/// Apply in the OG Script view: the Classic exporter writes the functions back
/// (model.setCode); a text that is no OG Script or has no Classic text is refused, a
/// re-print losing comments only after a second press.
fn applyOgs(app: *App, v: *View) void {
    check(app, v);
    if (v.err_line > 0) return app.setStatus(tx.st_code_ogs_error, .{ v.err_line, v.err() });
    const src = code.toGame(app.gpa, v.buf.str(), app.catalog.cyrillic) catch |err| return app.failed(err);
    defer app.gpa.free(src);
    var d: model.CodeDiag = .{};
    const bytes = model.setCode(app, app.gpa, v.file, src, v.force, &d) catch |err| {
        if (err == error.DropsComments) {
            v.force = true;
            return app.setStatus(tx.st_code_comments, .{ v.title, d.comments });
        }
        return app.setStatus(tx.st_code_not_applied, .{ v.title, if (d.message.len > 0) d.message else @errorName(err) });
    };
    v.force = false;
    v.buf.changed = false;
    if (std.mem.eql(u8, bytes, app.store.text(v.file))) return app.gpa.free(bytes);
    app.store.replace(v.file, bytes) catch |err| {
        app.gpa.free(bytes);
        return app.failed(err);
    };
    // Printed again from what was written.
    v.store_hash = 0;
    refresh(app, v);
    app.afterStoreChange(v.file);
    app.setStatus(tx.st_code_applied, .{v.title});
}

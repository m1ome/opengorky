//! Reloading and undo (App methods, app.zig): the views read again after the Store's
//! files change under them (undo, discard, a return in History), Save, and the catalog
//! rebuilt after them.

const std = @import("std");
const tx = @import("text.zig");
const catalog = @import("catalog.zig");
const sprview = @import("sprview.zig");
const codeview = @import("codeview.zig");
const entries = @import("entries.zig");
const store_mod = @import("store.zig");
const common_archive = store_mod.common_archive;
const Doc = @import("level.zig").Doc;
const App = @import("app.zig").App;

/// Document tab `doc`'s unsaved edits taken back (undoable steps); the level and the
/// catalog read again as after a save.
pub fn discardDoc(self: *App, doc: u64) void {
    self.commitEditing();
    _ = self.endPaint();
    self.store.discard(doc) catch |err| return self.setStatus(tx.st_save_failed, .{err});
    self.afterStoreChange(null);
}

/// After the Store's files changed under what shows them — file `f` (undo, code
/// applied), or any (null: a discard, a return in History) — each view of them read
/// again by the file's archive and entry: icons, the 3D preview, the sprite and font
/// pages, code views, the levels' objects, the catalog (titles from string.tab; after
/// a whole undo step, entries, icon and scene names it no longer has).
pub fn afterStoreChange(self: *App, f: ?usize) void {
    codeview.dropGone(self);
    const one = f orelse {
        // Everything read again, as after a save.
        for (self.store.files.items, 0..) |_, i| fileViews(self, i);
        if (self.doc) |d| d.deinit();
        self.doc = null;
        self.dropParked();
        self.dropMissingLevels();
        self.player.reload();
        self.preview.reload();
        rebuildCatalog(self);
        self.refreshTitles();
        if (self.current) |i| self.open(i, true);
        return;
    };
    fileViews(self, one);
    if (std.ascii.startsWithIgnoreCase(self.store.files.items[one].entry, "gfx_3d\\")) self.preview.reload();
    const docs_buf = self.frame.allocator().alloc(*Doc, self.parked.items.len + 1) catch return;
    for (self.eachDoc(docs_buf)) |d| {
        d.dropGone(one);
        d.restoreDeleted(one);
        d.refreshPos(one);
        if (one == d.lev) d.afterUndo() catch |err| self.setStatus(tx.st_undo_failed, .{err});
    }
    if (self.doc) |d| if (self.selected) |i| if (i >= d.objects.items.len) {
        self.selected = null;
    };
    // A group's later parts still to come: the catalog once they are all back.
    if (!self.store.midGroup()) dropUnmade(self);
    // OpenGorky: an entry's block back (its deletion undone): listed again.
    const back = self.store.files.items[one];
    if (self.store.root != null and !self.store.gone(one) and std.mem.eql(u8, back.archive, store_mod.og_src) and self.catalog.byKey(back.archive, back.entry) == null and entryDir(back.entry)) rebuildCatalog(self);
}

/// An OpenGorky text the catalog lists entries from (catalog.useOg's folders).
fn entryDir(entry: []const u8) bool {
    for ([_][]const u8{ "characters/", "weapons/", "items/" }) |d| if (std.mem.startsWith(u8, entry, d) and std.mem.indexOfScalar(u8, entry, '#') == null) return true;
    return false;
}

/// File `f`'s own views: its icon drawn anew, the sprite and font pages showing it,
/// the catalog's titles (string.tab).
fn fileViews(self: *App, f: usize) void {
    const entry = self.store.files.items[f].entry;
    if (catalog.isIcon(entry)) self.forgetIcon(entry["icons\\".len .. entry.len - 4]);
    if (self.spr) |e| if (e.file == f) sprview.load(self, e) catch {};
    if (self.fonts.edit) |*fe| if (fe.file == f) @import("fontpage.zig").load(self, fe) catch {};
    if (std.ascii.eqlIgnoreCase(entry, "string.tab")) self.refreshTitles();
}

/// Reads the catalog again (after save or discard: new classes are on disk or gone);
/// the entry shown stays shown (by its unique key: a new class sorts in), unless it
/// is gone. The scene shown is kept by name (`scene`).
pub fn rebuildCatalog(self: *App) void {
    const entry_key = if (self.entry) |e| entries.keyOf(self.gpa, self.catalog.entries.items[e]) else null;
    defer if (entry_key) |s| self.gpa.free(s);
    self.entry = null;
    self.pick = null;
    defer if (entry_key) |k| {
        self.entry = entries.entryByKey(self, k) catch null;
    };
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.gpa);
    for (self.levels) |e| names.append(self.gpa, e.name) catch return;
    var fresh = catalog.Catalog.build(self.io, self.gpa, self.dat, names.items) catch |err| return std.log.warn("catalog: {t}", .{err});
    if (self.store.root != null) catalog.useOg(&fresh, &self.store);
    if (self.stale_catalog) |*old| old.deinit();
    self.stale_catalog = self.catalog;
    self.catalog = fresh;
    // OpenGorky: names as src/texts/ has them now (a new archetype's too).
    if (self.store.root != null) self.refreshTitles();
}

/// The one Save: the open code editor's text and the value being typed go in first.
pub fn save(self: *App) void {
    self.saveOnly(null);
}

/// Every edit saved before something reads the game's files (a run, a package);
/// false: not saved (the save failed, or waits on a script error).
pub fn saveFirst(self: *App) bool {
    if (self.store.dirty()) self.save();
    return !self.store.dirty();
}

/// `save` of document tab `only`'s files (null: all); false — not saved (a syntax error).
pub fn saveOnly(self: *App, only: ?u64) void {
    self.commitEditing();
    // The tab's code typing (every code tab's for a full save); a syntax error: the first press only warns.
    const applied = if (only) |d| for (self.doc_tabs.items) |*t| {
        if (t.tab == .code and t.mark() == d) break codeview.applyOne(self, t.key());
    } else true else codeview.applyAll(self);
    if (!applied) return;
    _ = self.endPaint();
    if (if (only) |d| !self.store.dirtyDoc(d) else !self.store.dirty()) return;
    // An OpenGorky project writes its `src/` texts only: the installed game stays as it is.
    if (self.ogLayout()) if (self.store.outsideSrc(only)) |e| return self.setStatus(tx.st_og_read_only, .{e});
    const n = self.store.pending();
    // OpenGorky: where they go (the texts in src/, the editor's own in .og/).
    const n_src = self.store.pendingIn(store_mod.og_src);
    const n_meta = self.store.pendingIn(store_mod.og_meta);
    self.store.save(only) catch |err| return self.setStatus(tx.st_save_failed, .{err});
    // The archives now hold the edits: start from them again (the level's scripts
    // run on the saved files, new classes come into the catalog).
    if (self.doc) |d| d.deinit();
    self.doc = null;
    self.dropParked();
    self.player.reload();
    self.preview.reload();
    rebuildCatalog(self);
    if (self.current) |i| self.open(i, true);
    if (self.ogLayout()) self.setStatus(tx.st_saved_og, .{ n_src, n_meta }) else self.setStatus(tx.st_saved, .{n});
    // What the original exe would stumble on: the window opens only on problems.
    if (!self.ogLayout()) @import("checkpanel.zig").run(self);
}

pub fn undo(self: *App) void {
    // A group step (Store.group) comes back a part at a time, each file refreshed.
    undoPart(self);
    while (self.store.midGroup()) undoPart(self);
}

/// Entries made in the editor (a copy, a new weapon) whose file undo took away; icon
/// names (copied portraits) and scenes (new, copied, renamed) likewise — a renamed
/// scene gets its old name back.
fn dropUnmade(self: *App) void {
    // The names the Store has (an undone new file has none).
    const fa = self.frame.allocator();
    const icons_now = self.store.listing(fa, store_mod.sprite_archive, catalog.isIcon, false);
    var ic: usize = 0;
    while (ic < self.catalog.icons.items.len) {
        if (named(icons_now, "icons\\", self.catalog.icons.items[ic])) ic += 1 else _ = self.catalog.icons.orderedRemove(ic);
    }
    const scenes_now = self.store.listing(fa, common_archive, catalog.isSceneEntry, false);
    var sc: usize = 0;
    while (sc < self.catalog.scenes.items.len) {
        if (named(scenes_now, "scriptlets\\", self.catalog.scenes.items[sc].name)) {
            sc += 1;
            continue;
        }
        if (sceneBack(self, scenes_now)) |old| {
            // The scene shown follows its name back.
            if (std.ascii.eqlIgnoreCase(self.scene.get(), self.catalog.scenes.items[sc].name)) self.scene.set(old);
            self.catalog.scenes.items[sc].name = old;
            sc += 1;
            continue;
        }
        _ = self.catalog.scenes.orderedRemove(sc);
    }
    var k = self.catalog.built;
    while (k < self.catalog.entries.items.len) {
        const e = self.catalog.entries.items[k];
        if (self.store.find(e.archive, e.entry)) |i| if (!self.store.gone(i)) {
            k += 1;
            continue;
        };
        _ = self.catalog.entries.orderedRemove(k);
        if (self.entry) |s| self.entry = if (s == k) null else if (s > k) s - 1 else s;
    }
}

fn undoPart(self: *App) void {
    const f = self.store.undoLast() orelse return self.dropMissingLevels();
    self.setStatus(tx.st_undone, .{});
    self.afterStoreChange(f);
}

/// `list` (dir + name + a 4-character extension) has `name`.
fn named(list: []const []const u8, dir: []const u8, name: []const u8) bool {
    for (list) |e| if (e.len == dir.len + name.len + 4 and std.ascii.eqlIgnoreCase(e[dir.len..][0..name.len], name)) return true;
    return false;
}

/// The one scene script of `scenes_now` the catalog does not list (a renamed scene's
/// old name, back by undo); null: none, or several.
fn sceneBack(self: *App, scenes_now: []const []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (scenes_now) |e| {
        const name = e["scriptlets\\".len .. e.len - 4];
        if (self.sceneIndex(name) != null) continue;
        if (found != null) return null;
        found = name;
    }
    const n = found orelse return null;
    return self.catalog.arena.allocator().dupe(u8, n) catch null;
}

/// Undoes the edits after step `keep` (0 — every edit).
pub fn rollBack(self: *App, keep: usize) void {
    var n: usize = 0;
    while (self.store.undo.items.len > keep) : (n += 1) self.undo();
    self.setStatus(tx.st_rolled_back, .{n});
}

/// Back to the files as an earlier session's save `keep` left them (0: the
/// original): this session's edits undone, then the files put back as unsaved
/// edits (Undo takes them back, Save writes them).
pub fn returnToPast(self: *App, keep: usize) void {
    self.commitEditing();
    _ = self.endPaint();
    while (self.store.undo.items.len > 0) self.undo();
    const n = self.store.restorePast(keep) catch |err| return self.setStatus(tx.st_undo_failed, .{err});
    // The documents shown from the files as they are now.
    self.afterStoreChange(null);
    self.setStatus(tx.st_returned, .{n});
}

test "named: a catalog name in the Store's entries" {
    const es = [_][]const u8{ "scriptlets\\Medusa_ZZ.scr", "scriptlets\\a.pts" };
    try std.testing.expect(named(&es, "scriptlets\\", "medusa_zz"));
    try std.testing.expect(!named(&es, "scriptlets\\", "medusa"));
    try std.testing.expect(!named(&es, "scriptlets\\", "b"));
}

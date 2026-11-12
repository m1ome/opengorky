//! Script files being edited, from any archive of the game folder: level scripts,
//! fighters, weapons, classes, heroes. One undo stack for all of them, kept across
//! saves (a step before the save can be undone too); `save` writes every file that
//! differs from its archive.

const std = @import("std");
const baseName = @import("doctab.zig").baseName;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const archive = og.formats.archive;
const savelog = @import("savelog.zig");
const tx = @import("text.zig");

pub const common_archive = "common/other.dat";
pub const sprite_archive = "common/sprite.dat";
/// The exe's converted copy of `sprite_archive` (lower case on disk).
const sprite_cache = "common/sprite.kdt";
/// The engine's tuning file in the game root, not an archive (its "archive" and entry
/// both): kept as its decrypted text, written back encrypted (formats/adjust.zig).
/// Classic only: an OpenGorky project's tuning values are rules\adjust.ss rows.
pub const adjust_file = "adjust.kdt";
const adjust_path = "../" ++ adjust_file;
/// The game's `avi` folder (loose `.asf` videos, not an archive): its "archive", the
/// file names its entries; saving writes and deletes the files themselves.
pub const video_dir = "avi";
const history_path = "../" ++ savelog.dir_name;
/// An OpenGorky project's save history: in its folder, outside `src/` (never built nor
/// packed: the build reads `src/` only) and outside `dist/`.
const og_history = ".og/history";
/// An OpenGorky project's `src/` folder as the Store's "archive" (the
/// project's texts, not the installed game's archives): its entries are paths under it
/// (`characters/grandma.ogs`), saving writes and deletes the files themselves. An entry
/// `<file>#<block>/<inner>` is a block of that file (editor/model_og.zig): no text of its
/// own, never written.
pub const og_src = "src";
/// The engine's own OG Script, read-only: `engine.ogs` (its traits and types, as the
/// linker reads them: script/ogs/link.zig prelude) and `hosts.ogs` (the data blocks'
/// fields). Shown by the code editor (Go to), never written.
pub const engine_dir = "engine";
/// An OpenGorky project's editor files (`.og/`: the test kit, beside `.og/history`) as an
/// "archive" like `og_src`: in the project's folder, never built nor packed.
pub const og_meta = ".og";

/// `path` is a folder of the OpenGorky project (`og_src`, `og_meta`), not an archive.
fn projectFolder(path: []const u8) bool {
    return std.mem.eql(u8, path, og_src) or std.mem.eql(u8, path, og_meta);
}

/// OpenGorky: an installed game's asset entry — what the asset table maps
/// (loaders/assets.zig fromEntry: a level's walk maps, grid, areas, paths; sounds,
/// sprites…), no script or other text the converter makes OG Script of — is the project's
/// own asset `src/assets/<logical path>` under `root`: read from there when the project
/// has it, saved there; the installed game is never written. Null: no such entry.
pub fn ownAsset(buf: []u8, root: ?Io.Dir, path: []const u8, entry: []const u8) ?[]const u8 {
    if (root == null or projectFolder(path) or std.mem.eql(u8, path, adjust_file) or std.mem.eql(u8, path, video_dir)) return null;
    if (og.formats.resource.isScript(entry)) return null;
    for ([_][]const u8{ ".var", ".scr", ".pts", ".dlg", ".tab", ".inf" }) |x| if (std.ascii.endsWithIgnoreCase(entry, x)) return null;
    var lb: [og.loaders.assets.max_path]u8 = undefined;
    const logical = og.loaders.assets.fromEntry(&lb, path, entry) orelse return null;
    return std.fmt.bufPrint(buf, og_src ++ "/assets/{s}", .{logical}) catch null;
}

test "an installed game's asset entry is the OpenGorky project's own asset" {
    var buf: [512]u8 = undefined;
    const root: ?Io.Dir = Io.Dir.cwd();
    try std.testing.expectEqualStrings("src/assets/levels/01_port/walk.wm", ownAsset(&buf, root, "01_port/other.dat", "01_port.wm").?);
    try std.testing.expectEqualStrings("src/assets/sounds/door.wav", ownAsset(&buf, root, "common/sound.dat", "door.wav").?);
    try std.testing.expect(ownAsset(&buf, root, "01_port/other.dat", "01_port.lev") == null);
    try std.testing.expect(ownAsset(&buf, root, "common/other.dat", "variables\\x.var") == null);
    try std.testing.expect(ownAsset(&buf, null, "01_port/other.dat", "01_port.wm") == null);
}

const SFile = struct {
    /// Archive path under `dat` (interned in `archives`).
    archive: []const u8,
    entry: []u8,
    text: []u8,
    /// New file of an added fighter: written only while its level script places it.
    owner: ?[]u8 = null,
    /// Removed: deleted from its archive on save.
    deleted: bool = false,
    /// In its archive (read from it, or saved).
    on_disk: bool = false,
    /// The archive's text while `text` was edited (null: never edited since read or saved).
    base: ?[]u8 = null,
    /// The document tab it was last changed in (Store.doc then): its tab saves or
    /// discards it.
    doc: u64 = 0,
};

/// `created`: undo removes the files `file..file+created` made by `addNew` (their
/// texts stay unused); `deleted`: undo brings back the files `delete` removed.
const Undo = struct {
    file: usize,
    text: []u8,
    created: usize = 0,
    deleted: []usize = &.{},
    /// What the step did, for the history list, and its changed lines ("-old", "+new").
    label: []u8 = &.{},
    diff: []u8 = &.{},
    /// A level folder the editor made (`dat/<level>`; OpenGorky: its folders of the
    /// project's `src/`): undo deletes it.
    level: ?[]u8 = null,
    /// A group step (Store.group): its steps, undone last first.
    parts: std.ArrayList(Undo) = .empty,
};

/// The last Store.rev given (every Store's, so a new game folder's starts past the old).
var revs: u64 = 0;

pub const NewFile = struct { archive: []const u8, entry: []const u8, text: []u8 };

pub const Store = struct {
    gpa: Allocator,
    io: Io,
    dat: Io.Dir,
    /// An OpenGorky project's folder (its `src/` is `og_src`); null: a Classic game.
    root: ?Io.Dir = null,
    files: std.ArrayList(SFile) = .empty,
    undo: std.ArrayList(Undo) = .empty,
    archives: std.ArrayList([]u8) = .empty,
    /// Undo steps when last saved (the history marks it).
    saved_at: usize = 0,
    /// The saves of earlier sessions (`loadPast`); this session's go to disk only.
    past: ?savelog.Log = null,
    /// The document tab shown: files changed now are its (SFile.doc).
    doc: u64 = 0,
    /// Open `group` calls and the step the outermost began at.
    group_depth: u32 = 0,
    group_from: usize = 0,
    /// Another value after every change the editor's caches see (an edit, undo, discard,
    /// restore, a new or removed file, a save, reset); unique across Stores of a run, so a
    /// cache keyed on it never matches after undo then another edit (same step count). A
    /// file only read into the Store keeps it: its text is the archive's, as before.
    rev: u64 = 0,
    /// `srcFiles` as read at `src_rev`: walking src/ on disk took most of a frame when
    /// views asked for it many times a frame (each exit in the objects list).
    src_cache: std.ArrayList([]u8) = .empty,
    /// Another value after every write to disk (a save, a new level's files): caches of
    /// what the archives hold read them again (codenav's index).
    disk: u64 = 0,
    src_rev: ?u64 = null,
    /// `find`'s index (archive, entry in lower case → the first file of it), made again when
    /// `rev` or the file count changes (a read adds a file without a new rev).
    find_index: std.StringHashMapUnmanaged(usize) = .empty,
    find_arena: ?std.heap.ArenaAllocator = null,
    find_key: [2]u64 = .{ std.math.maxInt(u64), 0 },
    /// `listing`'s answers at `list_key` (rev, disk): the panels ask for the
    /// same lists every frame (each answer copied into the caller's allocator).
    list_cache: std.StringHashMapUnmanaged([]const []const u8) = .empty,
    list_arenas: [2]?std.heap.ArenaAllocator = .{ null, null },
    list_key: [3]u64 = .{ std.math.maxInt(u64), 0, 0 },
    /// `file`'s names not there at `missing_key` (rev, disk).
    missing: std.StringHashMapUnmanaged(void) = .empty,
    missing_arena: ?std.heap.ArenaAllocator = null,
    missing_key: [2]u64 = .{ std.math.maxInt(u64), 0 },

    pub fn deinit(self: *Store) void {
        if (self.past) |*p| p.deinit();
        if (self.find_arena) |*x| x.deinit();
        if (self.missing_arena) |*x| x.deinit();
        for (&self.list_arenas) |*x| if (x.*) |*y| y.deinit();
        self.reset();
        for (self.src_cache.items) |p| self.gpa.free(p);
        self.src_cache.deinit(self.gpa);
        self.files.deinit(self.gpa);
        self.undo.deinit(self.gpa);
        for (self.archives.items) |a| self.gpa.free(a);
        self.archives.deinit(self.gpa);
    }

    fn bump(self: *Store) void {
        revs += 1;
        self.rev = revs;
    }

    /// Forgets every file and edit (after saving, or to discard edits).
    pub fn reset(self: *Store) void {
        self.bump();
        for (self.undo.items) |*u| self.freeStep(u);
        self.undo.clearRetainingCapacity();
        for (self.files.items) |f| {
            self.gpa.free(f.entry);
            self.gpa.free(f.text);
            if (f.owner) |o| self.gpa.free(o);
            if (f.base) |b| self.gpa.free(b);
        }
        self.files.clearRetainingCapacity();
        self.saved_at = 0;
    }

    /// Edits to save: undoable ones, or an added fighter's file while a level places it
    /// (its placement is the step). An edited file undone back is not one.
    pub fn dirty(self: *const Store) bool {
        for (self.files.items, 0..) |_, i| if (self.toWrite(i) != .none) return true;
        return false;
    }

    /// Files a save would write or delete.
    pub fn pending(self: *const Store) usize {
        var n: usize = 0;
        for (self.files.items, 0..) |_, i| n += @intFromBool(self.toWrite(i) != .none);
        return n;
    }

    /// Files to write into archive (or project folder) `path`: an OpenGorky save's count
    /// by where it goes (`og_src`, `og_meta`); a block's entry (`file#block`) is no file.
    pub fn pendingIn(self: *const Store, path: []const u8) usize {
        var n: usize = 0;
        for (self.files.items, 0..) |f, i| {
            var ab: [512]u8 = undefined;
            // An own asset goes to src/ too (ownAsset).
            const into = std.mem.eql(u8, f.archive, path) or (std.mem.eql(u8, path, og_src) and ownAsset(&ab, self.root, f.archive, f.entry) != null);
            if (!into or std.mem.indexOfScalar(u8, f.entry, '#') != null) continue;
            n += @intFromBool(self.toWrite(i) != .none);
        }
        return n;
    }

    /// Unsaved edits made in document tab `doc`.
    pub fn dirtyDoc(self: *const Store, doc: u64) bool {
        for (self.files.items, 0..) |f, i| if (f.doc == doc and self.toWrite(i) != .none) return true;
        return false;
    }

    /// File `i` in a save of `only` (null: every file).
    /// An edit to save outside an OpenGorky project's `src/` (the installed game's
    /// archives, which an OpenGorky project never writes); null: none.
    pub fn outsideSrc(self: *const Store, only: ?u64) ?[]const u8 {
        var ab: [512]u8 = undefined;
        for (self.files.items, 0..) |f, i| if (self.inScope(i, only) and self.toWrite(i) != .none and !projectFolder(f.archive) and ownAsset(&ab, self.root, f.archive, f.entry) == null) return f.entry;
        return null;
    }

    fn inScope(self: *const Store, i: usize, only: ?u64) bool {
        return if (only) |d| self.files.items[i].doc == d else true;
    }

    /// Document tab `doc`'s unsaved edits taken back as one step each (undoable): edited
    /// files to their saved text, new ones removed, removed ones back.
    pub fn discard(self: *Store, doc: u64) !void {
        self.bump();
        var made: std.ArrayList(usize) = .empty;
        defer made.deinit(self.gpa);
        for (self.files.items, 0..) |f, i| {
            if (f.doc != doc) continue;
            switch (self.toWrite(i)) {
                .none => {},
                .write => if (f.on_disk) {
                    const label = tx.both(self.gpa, tx.step_discarded, .{f.entry});
                    defer self.gpa.free(label);
                    try self.replaceLabeled(i, try self.gpa.dupe(u8, self.saved(i)), label);
                } else try made.append(self.gpa, i),
                .delete => self.files.items[i].deleted = false,
            }
        }
        if (made.items.len > 0) try self.delete(made.items);
    }

    /// What saving does with file `i`: a new or edited one written, one deleted (or an
    /// added fighter's no level places any more) removed from its archive, else nothing.
    fn toWrite(self: *const Store, i: usize) enum { none, write, delete } {
        const f = self.files.items[i];
        if (f.entry.len == 0) return .none; // made and undone before any save
        const out = f.deleted or (if (f.owner) |o| !self.placed(f.archive, o) else false);
        if (out) return if (f.on_disk) .delete else .none;
        if (!f.on_disk) return .write;
        const b = f.base orelse return .none;
        return if (std.mem.eql(u8, b, f.text)) .none else .write;
    }

    pub fn text(self: *const Store, i: usize) []const u8 {
        return self.files.items[i].text;
    }

    /// File `i`'s text as its archive holds it (before the unsaved edits).
    pub fn saved(self: *const Store, i: usize) []const u8 {
        const f = self.files.items[i];
        return f.base orelse f.text;
    }

    fn intern(self: *Store, path: []const u8) ![]const u8 {
        for (self.archives.items) |a| if (std.mem.eql(u8, a, path)) return a;
        const p = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(p);
        try self.archives.append(self.gpa, p);
        return p;
    }

    /// Index of `entry` of archive `path`, read on first use.
    pub fn file(self: *Store, path: []const u8, entry: []const u8) !usize {
        if (self.find(path, entry)) |i| return if (self.files.items[i].deleted) error.NotFound else i;
        // Asked again for one that is not there (a panel each frame: `<obj>.itm`): not read again.
        const mk: [2]u64 = .{ self.rev, self.disk };
        if (!std.mem.eql(u64, &mk, &self.missing_key)) {
            if (self.missing_arena) |*x| _ = x.reset(.retain_capacity) else self.missing_arena = .init(self.gpa);
            self.missing = .empty;
            self.missing_key = mk;
        }
        var kb: [512]u8 = undefined;
        const k = findKey(&kb, path, entry);
        if (k) |x| if (self.missing.contains(x)) return error.NotFound;
        return self.fileRead(path, entry) catch |err| {
            if (err == error.NotFound) if (k) |x| {
                const ma = self.missing_arena.?.allocator();
                self.missing.put(ma, ma.dupe(u8, x) catch return err, {}) catch {};
            };
            return err;
        };
    }

    fn fileRead(self: *Store, path: []const u8, entry: []const u8) !usize {
        if (std.mem.eql(u8, path, engine_dir)) {
            const src = if (std.mem.eql(u8, entry, "engine.ogs")) og.script.traits.prelude else if (std.mem.eql(u8, entry, "hosts.ogs")) og.script.hosts.text else return error.NotFound;
            const t = try self.gpa.dupe(u8, src);
            errdefer self.gpa.free(t);
            const i = try self.add(path, entry, t, null);
            self.files.items[i].on_disk = true;
            return i;
        }
        if (std.mem.eql(u8, path, adjust_file)) {
            const raw = try self.dat.readFileAlloc(self.io, adjust_path, self.gpa, .limited(1 << 20));
            defer self.gpa.free(raw);
            const t = try og.formats.adjust.decrypt(self.gpa, raw);
            errdefer self.gpa.free(t);
            const i = try self.add(path, adjust_file, t, null);
            self.files.items[i].on_disk = true;
            return i;
        }
        if (projectFolder(path)) {
            const root = self.root orelse return error.NotFound;
            const t = if (std.mem.indexOfScalar(u8, entry, '#') != null) try self.gpa.dupe(u8, "") else blk: {
                var pb: [512]u8 = undefined;
                const sub = std.fmt.bufPrint(&pb, "{s}/{s}", .{ path, entry }) catch return error.NotFound;
                break :blk root.readFileAlloc(self.io, sub, self.gpa, .limited(64 << 20)) catch |err| switch (err) {
                    error.FileNotFound => return error.NotFound,
                    else => return err,
                };
            };
            errdefer self.gpa.free(t);
            const i = try self.add(path, entry, t, null);
            self.files.items[i].on_disk = true;
            return i;
        }
        if (std.mem.eql(u8, path, video_dir)) {
            const t = self.readVideo(entry) catch |err| switch (err) {
                error.FileNotFound => return error.NotFound,
                else => return err,
            };
            errdefer self.gpa.free(t);
            const i = try self.add(path, entry, t, null);
            self.files.items[i].on_disk = true;
            return i;
        }
        var ab: [512]u8 = undefined;
        if (ownAsset(&ab, self.root, path, entry)) |sub| if (self.root.?.readFileAlloc(self.io, sub, self.gpa, .limited(64 << 20))) |t| {
            errdefer self.gpa.free(t);
            const i = try self.add(path, entry, t, null);
            self.files.items[i].on_disk = true;
            return i;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        var ar = try archive.Archive.open(self.io, self.gpa, self.dat, path);
        defer ar.close(self.io, self.gpa);
        const e = ar.find(entry) orelse return error.NotFound;
        const t = try ar.readAlloc(self.io, self.gpa, e);
        errdefer self.gpa.free(t);
        const i = try self.add(path, e.name, t, null);
        self.files.items[i].on_disk = true;
        return i;
    }

    /// Video `name` (`avi/<name>`).
    fn readVideo(self: *Store, name: []const u8) ![]u8 {
        var pb: [300]u8 = undefined;
        return self.dat.readFileAlloc(self.io, try videoPath(&pb, name), self.gpa, .unlimited);
    }

    pub fn find(self: *const Store, path: []const u8, entry: []const u8) ?usize {
        const me = @constCast(self);
        const key: [2]u64 = .{ self.rev, self.files.items.len };
        if (!std.mem.eql(u64, &key, &self.find_key)) me.indexFiles(key) catch return self.findSlow(path, entry);
        var buf: [512]u8 = undefined;
        const k = findKey(&buf, path, entry) orelse return self.findSlow(path, entry);
        return self.find_index.get(k);
    }

    fn findSlow(self: *const Store, path: []const u8, entry: []const u8) ?usize {
        for (self.files.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.archive, path) and std.ascii.eqlIgnoreCase(f.entry, entry)) return i;
        }
        return null;
    }

    /// `find`'s key: `<archive>\x00<entry lower case>` in `buf` (null: too long).
    fn findKey(buf: []u8, path: []const u8, entry: []const u8) ?[]const u8 {
        if (path.len + 1 + entry.len > buf.len) return null;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        _ = std.ascii.lowerString(buf[path.len + 1 ..][0..entry.len], entry);
        return buf[0 .. path.len + 1 + entry.len];
    }

    fn indexFiles(self: *Store, key: [2]u64) !void {
        if (self.find_arena) |*x| _ = x.reset(.retain_capacity) else self.find_arena = .init(self.gpa);
        self.find_index = .empty;
        self.find_key = .{ std.math.maxInt(u64), 0 };
        const a = self.find_arena.?.allocator();
        var buf: [512]u8 = undefined;
        for (self.files.items, 0..) |f, i| {
            const k = findKey(&buf, f.archive, f.entry) orelse return error.TooLong;
            const g = try self.find_index.getOrPut(a, k);
            // The first file of a name, as the linear search found it.
            if (!g.found_existing) {
                g.key_ptr.* = try a.dupe(u8, k);
                g.value_ptr.* = i;
            }
        }
        self.find_key = key;
    }

    /// Entry names of archive `path` as the Store has them: the archive's less the
    /// removed ones, then the new files; those `keep` takes (null: all), in `a`;
    /// `sorted` by name (case aside), else in archive order.
    pub fn listing(self: *Store, a: Allocator, path: []const u8, keep: ?*const fn ([]const u8) bool, sorted: bool) []const []const u8 {
        return self.cachedListing(a, path, null, keep, sorted);
    }

    /// `listing` without the copy: valid this frame (until the Store changes twice), for a
    /// caller that reads it and lets go (the panels' each frame).
    pub fn listingFrame(self: *Store, path: []const u8, keep: ?*const fn ([]const u8) bool, sorted: bool) []const []const u8 {
        return self.cachedList(path, null, keep, sorted);
    }

    /// `listingOver` of entries `base` that stay the same while the Store does (a sound
    /// bank's), kept as `listing` keeps its answers.
    pub fn listingOf(self: *Store, a: Allocator, path: []const u8, base: []const archive.Entry, keep: ?*const fn ([]const u8) bool, sorted: bool) []const []const u8 {
        return self.cachedListing(a, path, base, keep, sorted);
    }

    fn cachedListing(self: *Store, a: Allocator, path: []const u8, base: ?[]const archive.Entry, keep: ?*const fn ([]const u8) bool, sorted: bool) []const []const u8 {
        const l = self.cachedList(path, base, keep, sorted);
        // In `a`, as the callers keep it (the catalog: past this generation).
        const out = a.alloc([]const u8, l.len) catch return &.{};
        for (out, l) |*o, x| o.* = a.dupe(u8, x) catch "";
        return out;
    }

    fn cachedList(self: *Store, path: []const u8, base: ?[]const archive.Entry, keep: ?*const fn ([]const u8) bool, sorted: bool) []const []const u8 {
        // Not the file count: a file read into the Store (an entry already listed) changes
        // no listing, and a reader walking one may read files.
        const key: [3]u64 = .{ self.rev, 0, self.disk };
        if (!std.mem.eql(u64, &key, &self.list_key)) {
            // A new generation: the one before the last goes.
            if (self.list_arenas[1]) |*x| x.deinit();
            self.list_arenas[1] = self.list_arenas[0];
            self.list_arenas[0] = .init(self.gpa);
            self.list_cache = .empty;
            self.list_key = key;
        }
        const ca = self.list_arenas[0].?.allocator();
        var kb: [600]u8 = undefined;
        const ck = std.fmt.bufPrint(&kb, "{s}\x00{x}\x00{}\x00{}", .{ path, if (keep) |k| @intFromPtr(k) else 0, sorted, base != null }) catch return self.listingNow(ca, path, base, keep, sorted);
        if (self.list_cache.get(ck)) |l| return l;
        const made = self.listingNow(ca, path, base, keep, sorted);
        self.list_cache.put(ca, ca.dupe(u8, ck) catch return made, made) catch {};
        return made;
    }

    fn listingNow(self: *Store, a: Allocator, path: []const u8, base: ?[]const archive.Entry, keep: ?*const fn ([]const u8) bool, sorted: bool) []const []const u8 {
        if (base) |b| return self.listingOver(a, path, b, keep, sorted);
        if (std.mem.eql(u8, path, og_src)) return self.listingOver(a, path, self.srcFiles(), keep, sorted);
        var names: std.ArrayList([]const u8) = .empty;
        if (archive.Archive.open(self.io, self.gpa, self.dat, path)) |ar_| {
            var ar = ar_;
            defer ar.close(self.io, self.gpa);
            for (ar.entries) |e| names.append(a, a.dupe(u8, e.name) catch continue) catch {};
        } else |_| {}
        // An OpenGorky project's own assets the game has none of (a model imported, saved).
        const game = names.items.len;
        for (self.ownEntries(a, path)) |n| {
            for (names.items[0..game]) |x| {
                if (std.ascii.eqlIgnoreCase(x, n)) break;
            } else names.append(a, n) catch {};
        }
        return self.listingOver(a, path, names.items, keep, sorted);
    }

    /// Whether the installed game's archive `path` holds `entry` (a project's own asset it
    /// does not is the project's alone).
    pub fn inGame(self: *Store, path: []const u8, entry: []const u8) bool {
        var ar = archive.Archive.open(self.io, self.gpa, self.dat, path) catch return false;
        defer ar.close(self.io, self.gpa);
        for (ar.entries) |e| if (std.ascii.eqlIgnoreCase(e.name, entry)) return true;
        return false;
    }

    /// The entries of archive `path` the project's `src/assets/` holds (loaders/assets.zig
    /// toEntry: `models/x.msh` is `gfx_3d\x.msh` of common/other.dat); none without a project.
    fn ownEntries(self: *Store, a: Allocator, path: []const u8) []const []const u8 {
        const root = self.root orelse return &.{};
        var dir = root.openDir(self.io, og_src ++ "/assets", .{ .iterate = true }) catch return &.{};
        defer dir.close(self.io);
        var walker = dir.walk(self.gpa) catch return &.{};
        defer walker.deinit();
        var out: std.ArrayList([]const u8) = .empty;
        while (walker.next(self.io) catch null) |e| if (e.kind == .file) {
            var lb: [og.loaders.assets.max_path]u8 = undefined;
            const logical = lb[0..@min(lb.len, e.path.len)];
            @memcpy(logical, e.path[0..logical.len]);
            std.mem.replaceScalar(u8, logical, '\\', '/');
            var bufs: [2][og.loaders.assets.max_path]u8 = undefined;
            const en = og.loaders.assets.toEntry(&bufs, logical) orelse continue;
            if (std.ascii.eqlIgnoreCase(en.archive, path)) out.append(a, a.dupe(u8, en.name) catch continue) catch {};
        };
        return out.items;
    }

    /// The `.ogs` files under the project's `src/` (not `src/assets/`), `/`-separated,
    /// sorted by path (as loaders/ogs.zig readTexts); read again after the Store's rev
    /// changes (shortcut: a file added to src/ outside the editor shows after its next
    /// change; add a disk watch if that matters).
    fn srcFiles(self: *Store) []const []u8 {
        if (self.src_rev == self.rev) return self.src_cache.items;
        for (self.src_cache.items) |p| self.gpa.free(p);
        self.src_cache.clearRetainingCapacity();
        self.src_rev = self.rev;
        const root = self.root orelse return &.{};
        var src = root.openDir(self.io, og_src, .{ .iterate = true }) catch return &.{};
        defer src.close(self.io);
        var walker = src.walk(self.gpa) catch return &.{};
        defer walker.deinit();
        while (walker.next(self.io) catch null) |e| if (e.kind == .file and std.mem.endsWith(u8, e.path, ".ogs") and !std.mem.startsWith(u8, e.path, "assets" ++ std.fs.path.sep_str)) {
            const p = self.gpa.dupe(u8, e.path) catch continue;
            std.mem.replaceScalar(u8, p, '\\', '/');
            self.src_cache.append(self.gpa, p) catch self.gpa.free(p);
        };
        std.mem.sort([]u8, self.src_cache.items, {}, struct {
            fn lt(_: void, x: []u8, y: []u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.lt);
        return self.src_cache.items;
    }

    /// `listing` over `base`, the archive's entries or names read already.
    pub fn listingOver(self: *const Store, a: Allocator, path: []const u8, base: anytype, keep: ?*const fn ([]const u8) bool, sorted: bool) []const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (base) |x| {
            const n: []const u8 = if (@TypeOf(x) == archive.Entry) x.name else x;
            if (keep) |k| if (!k(n)) continue;
            if (self.find(path, n)) |i| if (self.gone(i)) continue;
            out.append(a, a.dupe(u8, n) catch continue) catch {};
        }
        const read = out.items.len;
        for (self.files.items, 0..) |f, i| {
            if (!std.mem.eql(u8, f.archive, path) or self.gone(i)) continue;
            // A block's entry (og_src `<file>#<block>`) is no file.
            if (std.mem.eql(u8, path, og_src) and std.mem.indexOfScalar(u8, f.entry, '#') != null) continue;
            if (keep) |k| if (!k(f.entry)) continue;
            for (out.items[0..read]) |n| {
                if (std.ascii.eqlIgnoreCase(n, f.entry)) break;
            } else out.append(a, f.entry) catch {};
        }
        if (sorted) std.mem.sort([]const u8, out.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.ascii.lessThanIgnoreCase(x, y);
            }
        }.lt);
        return out.items;
    }

    /// Takes `t`; no undo step (a file read, or an added fighter's: its placement is the
    /// step). Written on save unless read from its archive; `owner` — see SFile.
    pub fn add(self: *Store, path: []const u8, entry: []const u8, t: []u8, owner: ?[]const u8) !usize {
        const ap = try self.intern(path);
        const e = try self.gpa.dupe(u8, entry);
        errdefer self.gpa.free(e);
        const o = if (owner) |n| try self.gpa.dupe(u8, n) else null;
        errdefer if (o) |n| self.gpa.free(n);
        try self.files.append(self.gpa, .{ .archive = ap, .entry = e, .text = t, .owner = o, .doc = self.doc });
        // A read (file) has no owner and changes nothing; an added fighter's file is new.
        if (owner != null) self.bump();
        return self.files.items.len - 1;
    }

    /// New files (takes their texts) that one undo takes away again; returns the first.
    pub fn addNew(self: *Store, files: []const NewFile) !usize {
        const first = self.files.items.len;
        for (files) |f| _ = try self.add(f.archive, f.entry, f.text, null);
        const label = try std.fmt.allocPrint(self.gpa, "+ {s}", .{files[0].entry});
        errdefer self.gpa.free(label);
        var diff: std.ArrayList(u8) = .empty;
        errdefer diff.deinit(self.gpa);
        for (files) |f| try diff.print(self.gpa, "+{s} ({s})\n", .{ f.entry, f.archive });
        const d = try diff.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(d);
        try self.undo.append(self.gpa, .{ .file = first, .text = try self.gpa.dupe(u8, ""), .created = files.len, .label = label, .diff = d });
        self.bump();
        return first;
    }

    /// Removes files `files` (one undo step); saving deletes them from their archives.
    pub fn delete(self: *Store, files: []const usize) !void {
        const list = try self.gpa.dupe(usize, files);
        errdefer self.gpa.free(list);
        const label = try std.fmt.allocPrint(self.gpa, "− {s}", .{self.files.items[files[0]].entry});
        errdefer self.gpa.free(label);
        var diff: std.ArrayList(u8) = .empty;
        errdefer diff.deinit(self.gpa);
        for (files) |i| try diff.print(self.gpa, "-{s} ({s})\n", .{ self.files.items[i].entry, self.files.items[i].archive });
        const d = try diff.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(d);
        try self.undo.append(self.gpa, .{ .file = files[0], .text = try self.gpa.dupe(u8, ""), .deleted = list, .label = label, .diff = d });
        for (files) |i| {
            self.files.items[i].deleted = true;
            self.files.items[i].doc = self.doc;
        }
        self.bump();
    }

    pub fn isDeleted(self: *const Store, i: usize) bool {
        return self.files.items[i].deleted;
    }

    /// File `i` is no more: taken away by undo (`addNew`) or deleted.
    pub fn gone(self: *const Store, i: usize) bool {
        return self.files.items[i].entry.len == 0 or self.files.items[i].deleted;
    }

    /// New text of file `i` (takes `t`); one undo step.
    pub fn replace(self: *Store, i: usize, t: []u8) !void {
        return self.replaceLabeled(i, t, null);
    }

    /// `replace` for a binary file: `what` is the step's label and its changed lines
    /// (first line the label, the rest "-old" / "+new").
    pub fn replaceLabeled(self: *Store, i: usize, t: []u8, what: ?[]const u8) !void {
        const f = &self.files.items[i];
        // The same text (a value typed again): no step.
        if (std.mem.eql(u8, f.text, t)) return self.gpa.free(t);
        const label = if (what) |w| try self.gpa.dupe(u8, w[0 .. std.mem.indexOfScalar(u8, w, '\n') orelse w.len]) else try changeLabel(self.gpa, f.entry, f.text, t);
        errdefer self.gpa.free(label);
        const diff = if (what) |w| try self.gpa.dupe(u8, if (std.mem.indexOfScalar(u8, w, '\n')) |k| w[k + 1 ..] else "") else try lineDiff(self.gpa, f.text, t);
        errdefer self.gpa.free(diff);
        if (f.on_disk and f.base == null) f.base = try self.gpa.dupe(u8, f.text);
        try self.undo.append(self.gpa, .{ .file = i, .text = f.text, .label = label, .diff = diff });
        f.text = t;
        f.doc = self.doc;
        self.bump();
    }

    /// Steps back one edit; returns the file it restored.
    /// Level `name` made on disk (`dat/<name>`, written at once: the editor opens
    /// levels from their archives; OpenGorky: `src/<locations|battles>/<name>/` and
    /// `src/assets/levels/<name>/`, and `extra`, its files of `src/` beside them): one
    /// step, undone by deleting the folder (and those files).
    pub fn levelMade(self: *Store, name: []const u8, label: []const u8, extra: []const []const u8) !void {
        // The exe's cache is the installed game's: an OpenGorky project never touches it.
        if (self.root == null) self.dropLevelCache(name);
        const l = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(l);
        const lb = try self.gpa.dupe(u8, label);
        errdefer self.gpa.free(lb);
        // The step's text: `extra`, a path a line.
        const files = try std.mem.join(self.gpa, "\n", extra);
        errdefer self.gpa.free(files);
        try self.undo.append(self.gpa, .{ .file = 0, .text = files, .label = lb, .level = l });
        self.bump();
    }

    /// OpenGorky level `name` the editor made taken away: its folders of `src/` and its
    /// files `extra` (paths under `src/`, a line each) deleted, the Store's files of them
    /// (its texts, its assets) gone (never found or saved again).
    fn unmakeOg(self: *Store, r: Io.Dir, name: []const u8, extra: []const u8) ?usize {
        var pb: [3][256]u8 = undefined;
        const dirs = [_][]const u8{
            std.fmt.bufPrint(&pb[0], "locations/{s}/", .{name}) catch return null,
            std.fmt.bufPrint(&pb[1], "battles/{s}/", .{name}) catch return null,
            std.fmt.bufPrint(&pb[2], "assets/levels/{s}/", .{name}) catch return null,
        };
        for (dirs) |d| {
            var sb: [300]u8 = undefined;
            const sub = std.fmt.bufPrint(&sb, og_src ++ "/{s}", .{d[0 .. d.len - 1]}) catch continue;
            r.deleteTree(self.io, sub) catch |err| std.log.warn("{s}: {t}", .{ sub, err });
        }
        var it = std.mem.tokenizeScalar(u8, extra, '\n');
        while (it.next()) |p| {
            var sb: [300]u8 = undefined;
            const sub = std.fmt.bufPrint(&sb, og_src ++ "/{s}", .{p}) catch continue;
            r.deleteFile(self.io, sub) catch |err| std.log.warn("{s}: {t}", .{ sub, err });
        }
        for (self.files.items) |*f| {
            const of_it = if (std.mem.eql(u8, f.archive, og_src)) for (dirs) |d| {
                if (std.ascii.startsWithIgnoreCase(f.entry, d)) break true;
            } else inExtra(extra, f.entry) else f.archive.len > name.len and std.ascii.startsWithIgnoreCase(f.archive, name) and f.archive[name.len] == '/';
            if (!of_it or f.entry.len == 0) continue;
            self.gpa.free(f.entry);
            f.entry = &.{};
        }
        return null;
    }

    fn inExtra(extra: []const u8, entry: []const u8) bool {
        var it = std.mem.tokenizeScalar(u8, extra, '\n');
        while (it.next()) |p| if (std.ascii.eqlIgnoreCase(p, entry)) return true;
        return false;
    }

    /// The exe's cached picture of level `name` (rN.dat, archive.dropCached) forgotten:
    /// a level made again under that name (another template) must not show the old one.
    fn dropLevelCache(self: *Store, name: []const u8) void {
        var pb: [300]u8 = undefined;
        const path = std.fmt.bufPrint(&pb, "{s}/sprite.dat", .{name}) catch return;
        _ = archive.dropCached(self.io, self.dat, path) catch |err| std.log.warn("{s}: {t}", .{ path, err });
    }

    /// One user action over several files (a copy, a new entity, a level made) as one
    /// undo step and one history row: the steps until the matching `endGroup` join
    /// (`label` names them; a lone step keeps its own). Nested groups join the outer one.
    pub fn group(self: *Store) void {
        if (self.group_depth == 0) self.group_from = self.undo.items.len;
        self.group_depth += 1;
    }

    pub fn endGroup(self: *Store, comptime fmt: []const u8, args: anytype) void {
        var buf: [200]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
        self.group_depth -= 1;
        if (self.group_depth > 0 or self.undo.items.len < self.group_from + 2) return;
        // Out of memory: the steps stay apart (each still undoes).
        self.join(self.group_from, label) catch |err| std.log.warn("undo group: {t}", .{err});
    }

    fn join(self: *Store, from: usize, label: []const u8) !void {
        var parts: std.ArrayList(Undo) = .empty;
        errdefer parts.deinit(self.gpa);
        try parts.appendSlice(self.gpa, self.undo.items[from..]);
        var diff: std.ArrayList(u8) = .empty;
        errdefer diff.deinit(self.gpa);
        for (parts.items) |p| try diff.appendSlice(self.gpa, p.diff);
        const lb = try self.gpa.dupe(u8, label);
        errdefer self.gpa.free(lb);
        const d = try diff.toOwnedSlice(self.gpa);
        self.undo.shrinkRetainingCapacity(from);
        self.undo.appendAssumeCapacity(.{ .file = parts.items[0].file, .text = &.{}, .label = lb, .diff = d, .parts = parts });
    }

    fn freeStep(self: *Store, u: *Undo) void {
        for (u.parts.items) |*p| self.freeStep(p);
        u.parts.deinit(self.gpa);
        self.gpa.free(u.text);
        self.gpa.free(u.deleted);
        self.gpa.free(u.label);
        self.gpa.free(u.diff);
        if (u.level) |l| self.gpa.free(l);
    }

    /// The last step is a group partly undone (`undoLast` again takes its next part).
    pub fn midGroup(self: *const Store) bool {
        const n = self.undo.items.len;
        return n > 0 and self.undo.items[n - 1].parts.items.len > 0;
    }

    /// Undoes the last step (of a group: its last part left); returns the file it
    /// restored (null: none, or a level folder was deleted — the caller drops levels
    /// gone from disk).
    pub fn undoLast(self: *Store) ?usize {
        if (self.midGroup()) {
            const top = &self.undo.items[self.undo.items.len - 1];
            const part = top.parts.pop().?;
            if (top.parts.items.len == 0) {
                var g = self.undo.pop().?;
                self.freeStep(&g);
            }
            return self.undoStep(part);
        }
        return self.undoStep(self.undo.pop() orelse return null);
    }

    fn undoStep(self: *Store, u: Undo) ?usize {
        self.bump();
        defer self.gpa.free(u.label);
        defer self.gpa.free(u.diff);
        if (u.level) |l| {
            defer self.gpa.free(l);
            defer self.gpa.free(u.text);
            if (self.root) |r| return self.unmakeOg(r, l, u.text);
            self.dat.deleteTree(self.io, l) catch |err| std.log.warn("{s}: {t}", .{ l, err });
            self.dropLevelCache(l);
            return null;
        }
        if (u.deleted.len > 0) {
            for (u.deleted) |i| self.files.items[i].deleted = false;
            self.gpa.free(u.deleted);
            self.gpa.free(u.text);
            return u.file;
        }
        if (u.created > 0) {
            self.gpa.free(u.text);
            for (self.files.items[u.file..][0..u.created]) |*f| {
                // Saved since: deleted from the archive on the next save.
                if (f.on_disk) {
                    f.deleted = true;
                    continue;
                }
                // No name: never found or saved again.
                self.gpa.free(f.entry);
                f.entry = &.{};
            }
            return u.file;
        }
        const f = &self.files.items[u.file];
        if (f.on_disk and f.base == null) f.base = f.text else self.gpa.free(f.text);
        f.text = u.text;
        return u.file;
    }

    /// Labels of the steps, oldest first (the history list).
    pub fn labels(self: *const Store, out: [][]const u8) [][]const u8 {
        const n = @min(out.len, self.undo.items.len);
        for (self.undo.items[self.undo.items.len - n ..], 0..) |u, k| out[k] = u.label;
        return out[0..n];
    }

    /// Changed lines of step `k` (0-based, oldest first): "-old" / "+new", one per line.
    pub fn stepDiff(self: *const Store, k: usize) []const u8 {
        return self.undo.items[k].diff;
    }

    /// Replaces the first `old` in file `i` with `new` (an `#include` line).
    pub fn replaceText(self: *Store, i: usize, old: []const u8, new: []const u8) !void {
        const t = self.text(i);
        const p = std.ascii.findIgnoreCase(t, old) orelse return error.NotFound;
        const out = try std.mem.concat(self.gpa, u8, &.{ t[0..p], new, t[p + old.len ..] });
        errdefer self.gpa.free(out);
        try self.replace(i, out);
    }

    /// Reads the saves of earlier sessions (none: an empty history).
    pub fn loadPast(self: *Store) void {
        var dir = self.historyDir(false) catch return;
        defer dir.close(self.io);
        self.past = savelog.load(self.io, self.gpa, dir) catch |err| return std.log.warn("{s}: {t}", .{ savelog.dir_name, err });
    }

    /// Puts the files back as they were after the first `keep` saves of earlier
    /// sessions (0: before any, the original): one undo step per file, unsaved.
    /// Returns the files changed.
    pub fn restorePast(self: *Store, keep: usize) !usize {
        const log = &(self.past orelse return 0);
        var dir = try self.historyDir(false);
        defer dir.close(self.io);
        const back = try log.targets(self.gpa, keep);
        defer self.gpa.free(back);
        var n: usize = 0;
        for (back) |t| {
            _ = self.file(t.archive, t.entry) catch {};
            const i = self.find(t.archive, t.entry);
            // Taken out by this session's undo (made and saved in it): left as it is.
            if (i != null and self.files.items[i.?].deleted) {
                std.log.warn("{s}: deleted, not restored", .{t.entry});
                continue;
            }
            if (t.before) |h| {
                const data = try savelog.blob(self.io, self.gpa, dir, h);
                if (i) |k| {
                    if (std.mem.eql(u8, self.text(k), data)) {
                        self.gpa.free(data);
                        continue;
                    }
                    var lb: [300]u8 = undefined;
                    var fba: std.heap.FixedBufferAllocator = .init(&lb);
                    const label = tx.both(fba.allocator(), tx.step_restored, .{t.entry});
                    self.replaceLabeled(k, data, label) catch |err| {
                        self.gpa.free(data);
                        return err;
                    };
                } else _ = self.addNew(&.{.{ .archive = t.archive, .entry = t.entry, .text = data }}) catch |err| {
                    self.gpa.free(data);
                    return err;
                };
            } else if (i) |k| try self.delete(&.{k}) else continue;
            n += 1;
        }
        return n;
    }

    /// The save about to be written, kept in the game's history folder: each file
    /// before and after, the steps' labels and changed lines.
    fn record(self: *Store, only: ?u64) !void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var changes: std.ArrayList(savelog.File) = .empty;
        for (self.files.items, 0..) |f, i| {
            const w = self.toWrite(i);
            if (w == .none or !self.inScope(i, only)) continue;
            // A block's entry (og_src `<file>#<block>`) is no file.
            if (std.mem.eql(u8, f.archive, og_src) and std.mem.indexOfScalar(u8, f.entry, '#') != null) continue;
            try changes.append(a, .{ .archive = f.archive, .entry = f.entry, .before = if (f.on_disk) self.saved(i) else null, .after = if (w == .write) f.text else null });
        }
        if (changes.items.len == 0) return;
        var label: std.ArrayList(u8) = .empty;
        var diff: std.ArrayList(u8) = .empty;
        for (self.undo.items[@min(self.saved_at, self.undo.items.len)..]) |u| {
            if (label.items.len > 0) try label.appendSlice(a, "; ");
            if (label.items.len < 300) try label.appendSlice(a, u.label);
            try diff.appendSlice(a, u.diff);
        }
        // Files made without a step (an added fighter's): their names.
        if (label.items.len == 0) for (changes.items) |c| try label.print(a, "{s} ", .{c.entry});
        try self.appendLog(label.items, diff.items, changes.items);
    }

    /// Files written at once, not by `save` (a level made), kept in the history as a
    /// save of their own (Package mod takes what it lists).
    pub fn logWritten(self: *Store, label: []const u8, files: []const savelog.File) void {
        // Files written past the Store (a new level's): caches keyed on rev read again.
        self.bump();
        self.disk +%= 1;
        self.appendLog(label, "", files) catch |err| std.log.warn("{s}: {t}", .{ savelog.dir_name, err });
    }

    /// The history folder: the game folder's `.opengorky-history`, an OpenGorky
    /// project's `.og/history` (`create`: made when not there).
    fn historyDir(self: *Store, create: bool) !Io.Dir {
        if (self.root) |r| {
            if (create) {
                try r.createDirPath(self.io, og_history);
                ignoreOg(self.io, r);
            }
            return r.openDir(self.io, og_history, .{});
        }
        if (!create) return self.dat.openDir(self.io, history_path, .{});
        var dir = try self.dat.openDir(self.io, "..", .{});
        defer dir.close(self.io);
        try dir.createDirPath(self.io, savelog.dir_name);
        return dir.openDir(self.io, savelog.dir_name, .{});
    }

    /// The project's `.gitignore` names `.og/` (the editor's files):
    /// added when missing, a project without one gets the writer's.
    fn ignoreOg(io: Io, r: Io.Dir) void {
        var buf: [4096]u8 = undefined;
        const t = r.readFile(io, ".gitignore", &buf) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return,
        };
        // shortcut: a .gitignore of 4 KiB or more is left as it is (never cut by a rewrite).
        if (t.len == buf.len) return;
        var it = std.mem.tokenizeAny(u8, t, "\r\n");
        while (it.next()) |l| if (std.mem.eql(u8, std.mem.trim(u8, l, " \t/"), ".og")) return;
        var out: [4100]u8 = undefined;
        const nl = if (t.len > 0 and t[t.len - 1] != '\n') "\n" else "";
        const data = if (t.len == 0) og.compose.og_write.gitignore else std.fmt.bufPrint(&out, "{s}{s}.og/\n", .{ t, nl }) catch return;
        r.writeFile(io, .{ .sub_path = ".gitignore", .data = data }) catch |err| std.log.warn(".gitignore: {t}", .{err});
    }

    fn appendLog(self: *Store, label: []const u8, diff: []const u8, changes: []const savelog.File) !void {
        var h = try self.historyDir(true);
        defer h.close(self.io);
        const now = Io.Timestamp.now(self.io, .real).toSeconds();
        try savelog.append(self.io, self.gpa, h, now, label, diff, changes);
    }

    /// Writes every changed file into its archive (the game folder itself); `only`: just
    /// the files of that document tab (SFile.doc), the others' edits stay unsaved.
    pub fn save(self: *Store, only: ?u64) !void {
        defer self.bump();
        defer self.disk +%= 1;
        // Before any write: adjust.kdt past the exe's limits would crash the original.
        for (self.files.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.archive, adjust_file) and self.toWrite(i) == .write and self.inScope(i, only)) try og.formats.adjust.checkLimits(f.text);
        }
        // First, while the contents before it are at hand; a save that fails after
        // shows in the history too (its "before" stays right).
        self.record(only) catch |err| std.log.warn("{s}: {t}", .{ savelog.dir_name, err });
        for (self.archives.items) |path| {
            var list: std.ArrayList(archive.File) = .empty;
            defer list.deinit(self.gpa);
            for (self.files.items, 0..) |f, i| {
                if (f.archive.ptr != path.ptr or !self.inScope(i, only)) continue;
                switch (self.toWrite(i)) {
                    .none => {},
                    .write => try list.append(self.gpa, .{ .name = f.entry, .data = f.text }),
                    .delete => try list.append(self.gpa, .{ .name = f.entry, .data = "", .delete = true }),
                }
            }
            if (list.items.len == 0) continue;
            if (self.root != null and !projectFolder(path)) {
                // OpenGorky: the installed game's assets edited, the project's own (ownAsset);
                // nothing else of the installed game is saved (App.save refuses it first).
                const root = self.root.?;
                for (list.items) |f| {
                    var ab: [512]u8 = undefined;
                    const sub = ownAsset(&ab, self.root, path, f.name) orelse continue;
                    if (f.delete) {
                        root.deleteFile(self.io, sub) catch |err| switch (err) {
                            error.FileNotFound => {},
                            else => return err,
                        };
                        continue;
                    }
                    if (std.fs.path.dirname(sub)) |d| try root.createDirPath(self.io, d);
                    try root.writeFile(self.io, .{ .sub_path = sub, .data = f.data });
                }
            } else if (projectFolder(path)) {
                // The project's own texts, file by file (a block's entry has none).
                const root = self.root orelse return error.NotFound;
                for (list.items) |f| {
                    if (std.mem.indexOfScalar(u8, f.name, '#') != null) continue;
                    var pb: [512]u8 = undefined;
                    const sub = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ path, f.name });
                    if (f.delete) {
                        root.deleteFile(self.io, sub) catch |err| switch (err) {
                            error.FileNotFound => {},
                            else => return err,
                        };
                        continue;
                    }
                    if (std.fs.path.dirname(sub)) |d| try root.createDirPath(self.io, d);
                    try root.writeFile(self.io, .{ .sub_path = sub, .data = f.data });
                }
            } else if (std.mem.eql(u8, path, adjust_file)) {
                const enc = try og.formats.adjust.encode(self.gpa, list.items[0].data);
                defer self.gpa.free(enc);
                try self.dat.writeFile(self.io, .{ .sub_path = adjust_path, .data = enc });
            } else if (std.mem.eql(u8, path, video_dir)) {
                try self.dat.createDirPath(self.io, "../" ++ video_dir);
                for (list.items) |f| {
                    var pb: [300]u8 = undefined;
                    const sub = try videoPath(&pb, f.name);
                    if (!f.delete) try self.dat.writeFile(self.io, .{ .sub_path = sub, .data = f.data }) else self.dat.deleteFile(self.io, sub) catch |err| switch (err) {
                        error.FileNotFound => {},
                        else => return err,
                    };
                }
            } else {
                try archive.rewrite(self.io, self.gpa, self.dat, path, list.items);
                // The original would keep drawing its cached copy of the old one.
                _ = try archive.dropCached(self.io, self.dat, path);
                // Its converted common/sprite.kdt is used unless the size or first 200 bytes
                // differ (0x41cc70 → 0x41d720); a missing one is rebuilt (0x41cd16).
                if (std.ascii.eqlIgnoreCase(path, sprite_archive)) self.dat.deleteFile(self.io, sprite_cache) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                };
            }
            // The archive is as the files now: they differ from it no more.
            for (self.files.items, 0..) |*f, i| {
                if (f.archive.ptr != path.ptr or !self.inScope(i, only)) continue;
                switch (self.toWrite(i)) {
                    .none => {},
                    .write => f.on_disk = true,
                    .delete => f.on_disk = false,
                }
                if (f.base) |b| self.gpa.free(b);
                f.base = null;
            }
        }
        // The history's save mark: once nothing is left unsaved.
        if (!self.dirty()) self.saved_at = self.undo.items.len;
    }

    /// Fighter `name` appears in a level script of archive `path`.
    fn placed(self: *const Store, path: []const u8, name: []const u8) bool {
        var buf: [128]u8 = undefined;
        const q = std.fmt.bufPrint(&buf, "\"{s}\"", .{name}) catch return true;
        for (self.files.items) |f| {
            if (f.archive.ptr != path.ptr or !std.ascii.endsWithIgnoreCase(f.entry, ".lev")) continue;
            if (std.ascii.findIgnoreCase(f.text, q) != null) return true;
        }
        return false;
    }
};

/// Video `name`'s path from `dat`.
fn videoPath(buf: []u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "../" ++ video_dir ++ "/{s}", .{name});
}

/// "<file>: <first changed line of the new text>" (or of the old one, struck out).
fn changeLabel(gpa: Allocator, entry: []const u8, old: []const u8, new: []const u8) ![]u8 {
    const short = baseName(entry);
    // New lines of `new` not in `old`, by position: a value beats a declaration.
    var found: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, new, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0 or std.mem.indexOf(u8, old, l) != null) continue;
        const decl = std.mem.startsWith(u8, l, "string ") or std.mem.startsWith(u8, l, "int ") or std.mem.startsWith(u8, l, "float ");
        if (found == null or !decl) found = l;
        if (!decl) break;
    }
    if (found) |l| return std.fmt.allocPrint(gpa, "{s}: {s}", .{ short, l[0..@min(l.len, 90)] });
    // Only removals: the first line gone.
    var ot = std.mem.splitScalar(u8, old, '\n');
    while (ot.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len > 0 and std.mem.indexOf(u8, new, l) == null) return std.fmt.allocPrint(gpa, "{s}: − {s}", .{ short, l[0..@min(l.len, 90)] });
    }
    return std.fmt.allocPrint(gpa, "{s}", .{short});
}

/// Lines of `new` not in `old` ("+") and of `old` not in `new` ("-"), counting repeats,
/// in file order: removed first, then added (trimmed, at most 200 of each).
fn lineDiff(gpa: Allocator, old: []const u8, new: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var counts: std.StringHashMapUnmanaged(i32) = .empty;
    var it = std.mem.splitScalar(u8, old, '\n');
    while (it.next()) |l| (try counts.getOrPutValue(a, std.mem.trim(u8, l, " \t\r"), 0)).value_ptr.* += 1;
    it = std.mem.splitScalar(u8, new, '\n');
    while (it.next()) |l| (try counts.getOrPutValue(a, std.mem.trim(u8, l, " \t\r"), 0)).value_ptr.* -= 1;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    // Removed: old lines whose count stays positive.
    for ([_]struct { []const u8, u8, i32 }{ .{ old, '-', 1 }, .{ new, '+', -1 } }) |side| {
        var shown: usize = 0;
        var left = try counts.clone(a);
        var lines = std.mem.splitScalar(u8, side[0], '\n');
        while (lines.next()) |raw| {
            const l = std.mem.trim(u8, raw, " \t\r");
            if (l.len == 0) continue;
            const c = left.getPtr(l) orelse continue;
            if (c.* * side[2] <= 0) continue;
            c.* -= side[2];
            shown += 1;
            if (shown > 200) continue;
            try out.append(gpa, side[1]);
            try out.appendSlice(gpa, l[0..@min(l.len, 160)]);
            try out.append(gpa, '\n');
        }
    }
    return out.toOwnedSlice(gpa);
}

test "save and discard one document tab's files: the other tab's edits stay" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dat/x");
    const orig = try archive.build(gpa, &.{ .{ .name = "a.s", .data = "A" }, .{ .name = "b.s", .data = "B" }, .{ .name = "", .data = "" } });
    defer gpa.free(orig);
    try tmp.dir.writeFile(io, .{ .sub_path = "dat/x/other.dat", .data = orig });
    var dat = try tmp.dir.openDir(io, "dat", .{});
    defer dat.close(io);
    var s: Store = .{ .gpa = gpa, .io = io, .dat = dat };
    defer s.deinit();
    s.doc = 1;
    const a = try s.file("x/other.dat", "a.s");
    try s.replace(a, try gpa.dupe(u8, "A2"));
    s.doc = 2;
    const b = try s.file("x/other.dat", "b.s");
    try s.replace(b, try gpa.dupe(u8, "B2"));
    try s.save(1);
    try std.testing.expect(!s.dirtyDoc(1));
    try std.testing.expect(s.dirtyDoc(2));
    var ar = try archive.Archive.open(io, gpa, dat, "x/other.dat");
    defer ar.close(io, gpa);
    for ([_][2][]const u8{ .{ "a.s", "A2" }, .{ "b.s", "B" } }) |want| {
        const got = try ar.readAlloc(io, gpa, ar.find(want[0]).?);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(want[1], got);
    }
    try s.discard(2);
    try std.testing.expectEqualStrings("B", s.text(b));
    try std.testing.expect(!s.dirty());
    // Taken back as a step: undo brings the edit again.
    _ = s.undoLast();
    try std.testing.expectEqualStrings("B2", s.text(b));
}

test "save: a video into the avi folder and out after its undo; sprite.kdt dropped" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dat/common");
    const orig = try archive.build(gpa, &.{ .{ .name = "a.spr", .data = "A" }, .{ .name = "", .data = "" } });
    defer gpa.free(orig);
    try tmp.dir.writeFile(io, .{ .sub_path = "dat/common/sprite.dat", .data = orig });
    try tmp.dir.writeFile(io, .{ .sub_path = "dat/common/sprite.kdt", .data = "converted" });
    var dat = try tmp.dir.openDir(io, "dat", .{});
    defer dat.close(io);
    var s: Store = .{ .gpa = gpa, .io = io, .dat = dat };
    defer s.deinit();
    _ = try s.addNew(&.{.{ .archive = video_dir, .entry = "clip.asf", .text = try gpa.dupe(u8, "video") }});
    // Staged: nothing in avi before the save.
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "avi/clip.asf", .{}));
    try s.replace(try s.file(sprite_archive, "a.spr"), try gpa.dupe(u8, "B"));
    try s.save(null);
    const got = try tmp.dir.readFileAlloc(io, "avi/clip.asf", gpa, .unlimited);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("video", got);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "dat/common/sprite.kdt", .{}));
    _ = s.undoLast();
    _ = s.undoLast();
    try s.save(null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "avi/clip.asf", .{}));
}

test "group: one action over several files is one undo step and one history row" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dat/x");
    const orig = try archive.build(gpa, &.{ .{ .name = "a.s", .data = "A" }, .{ .name = "", .data = "" } });
    defer gpa.free(orig);
    try tmp.dir.writeFile(io, .{ .sub_path = "dat/x/other.dat", .data = orig });
    var dat = try tmp.dir.openDir(io, "dat", .{});
    defer dat.close(io);
    var s: Store = .{ .gpa = gpa, .io = io, .dat = dat };
    defer s.deinit();
    const a = try s.file("x/other.dat", "a.s");
    try s.replace(a, try gpa.dupe(u8, "A1"));
    {
        s.group();
        defer s.endGroup("+ {s}", .{"b.s"});
        const b = try s.addNew(&.{.{ .archive = "x/other.dat", .entry = "b.s", .text = try gpa.dupe(u8, "B") }});
        // Nested: joins the outer one.
        s.group();
        try s.replace(a, try gpa.dupe(u8, "A2"));
        try s.replace(b, try gpa.dupe(u8, "B2"));
        s.endGroup("inner", .{});
    }
    try std.testing.expectEqual(2, s.undo.items.len);
    try std.testing.expectEqualStrings("+ b.s", s.undo.items[1].label);
    try std.testing.expect(std.mem.indexOf(u8, s.stepDiff(1), "+b.s (x/other.dat)") != null);
    // Undone a part at a time, the group left until its last part.
    try std.testing.expectEqual(1, s.undoLast());
    try std.testing.expect(s.midGroup());
    _ = s.undoLast();
    try std.testing.expectEqual(1, s.undoLast());
    try std.testing.expect(!s.midGroup());
    try std.testing.expectEqual(1, s.undo.items.len);
    try std.testing.expect(s.gone(1));
    try std.testing.expectEqualStrings("A1", s.text(a));
    // A lone step keeps its own label.
    s.group();
    try s.replace(a, try gpa.dupe(u8, "A3"));
    s.endGroup("unused", .{});
    try std.testing.expectEqualStrings("a.s: A3", s.undo.items[1].label);
    // reset frees a group never undone.
    s.group();
    _ = try s.addNew(&.{.{ .archive = "x/other.dat", .entry = "c.s", .text = try gpa.dupe(u8, "C") }});
    try s.replace(a, try gpa.dupe(u8, "A4"));
    s.endGroup("+ c.s", .{});
}

test "rev: undo then another edit is a new rev (same step count); a read is none" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "dat/x");
    const orig = try archive.build(gpa, &.{ .{ .name = "a.s", .data = "A" }, .{ .name = "b.s", .data = "B" } });
    defer gpa.free(orig);
    try tmp.dir.writeFile(io, .{ .sub_path = "dat/x/other.dat", .data = orig });
    var dat = try tmp.dir.openDir(io, "dat", .{});
    defer dat.close(io);
    var s: Store = .{ .gpa = gpa, .io = io, .dat = dat };
    defer s.deinit();
    const a = try s.file("x/other.dat", "a.s");
    const r0 = s.rev;
    try s.replace(a, try gpa.dupe(u8, "A1"));
    const r1 = s.rev;
    try std.testing.expect(r1 != r0);
    _ = s.undoLast();
    try s.replace(a, try gpa.dupe(u8, "A2"));
    // One step as before, other text: another rev.
    try std.testing.expectEqual(1, s.undo.items.len);
    try std.testing.expect(s.rev != r1);
    const r2 = s.rev;
    _ = try s.file("x/other.dat", "b.s");
    try std.testing.expectEqual(r2, s.rev);
    // The same text again: no step, no change.
    try s.replace(a, try gpa.dupe(u8, "A2"));
    try std.testing.expectEqual(r2, s.rev);
}

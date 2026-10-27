//! Script files being edited, from any archive of the game folder: level scripts,
//! fighters, weapons, classes, heroes. One undo stack for all of them, kept across
//! saves (a step before the save can be undone too); `save` writes every file that
//! differs from its archive.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const archive = og.formats.archive;
const vars = @import("vars.zig");
const savelog = @import("savelog.zig");

pub const common_archive = "common/other.dat";
pub const sprite_archive = "common/sprite.dat";
/// The engine's tuning file in the game root, not an archive (its "archive" and entry
/// both): kept as its decrypted text, written back encrypted (formats/adjust.zig).
pub const adjust_file = "adjust.kdt";
const adjust_path = "../" ++ adjust_file;
const history_path = "../" ++ savelog.dir_name;

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
    /// A level folder the editor made (`dat/<level>`): undo deletes it.
    level: ?[]u8 = null,
};

pub const NewFile = struct { archive: []const u8, entry: []const u8, text: []u8 };

pub const Store = struct {
    gpa: Allocator,
    io: Io,
    dat: Io.Dir,
    files: std.ArrayList(SFile) = .empty,
    undo: std.ArrayList(Undo) = .empty,
    archives: std.ArrayList([]u8) = .empty,
    /// Undo steps when last saved (the history marks it).
    saved_at: usize = 0,
    /// The saves of earlier sessions (`loadPast`); this session's go to disk only.
    past: ?savelog.Log = null,

    pub fn deinit(self: *Store) void {
        if (self.past) |*p| p.deinit();
        self.reset();
        self.files.deinit(self.gpa);
        self.undo.deinit(self.gpa);
        for (self.archives.items) |a| self.gpa.free(a);
        self.archives.deinit(self.gpa);
    }

    /// Forgets every file and edit (after saving, or to discard edits).
    pub fn reset(self: *Store) void {
        for (self.undo.items) |u| {
            self.gpa.free(u.text);
            self.gpa.free(u.deleted);
            self.gpa.free(u.label);
            self.gpa.free(u.diff);
            if (u.level) |l| self.gpa.free(l);
        }
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

    /// Edits to save: undoable ones, or files made without a step (a class copy, an
    /// imported icon or model). An edited file undone back is not one, nor an added
    /// fighter's file (its placement is the step).
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
        if (std.mem.eql(u8, path, adjust_file)) {
            const raw = try self.dat.readFileAlloc(self.io, adjust_path, self.gpa, .limited(1 << 20));
            defer self.gpa.free(raw);
            const t = try og.formats.adjust.decrypt(self.gpa, raw);
            errdefer self.gpa.free(t);
            const i = try self.add(path, adjust_file, t, null, false);
            self.files.items[i].on_disk = true;
            return i;
        }
        var ar = try archive.Archive.open(self.io, self.gpa, self.dat, path);
        defer ar.close(self.io, self.gpa);
        const e = ar.find(entry) orelse return error.NotFound;
        const t = try ar.readAlloc(self.io, self.gpa, e);
        errdefer self.gpa.free(t);
        const i = try self.add(path, e.name, t, null, false);
        self.files.items[i].on_disk = true;
        return i;
    }

    pub fn find(self: *const Store, path: []const u8, entry: []const u8) ?usize {
        for (self.files.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.archive, path) and std.ascii.eqlIgnoreCase(f.entry, entry)) return i;
        }
        return null;
    }

    /// Takes `t`. A new file (`changed`) is written on save; `owner` — see SFile.
    pub fn add(self: *Store, path: []const u8, entry: []const u8, t: []u8, owner: ?[]const u8, changed: bool) !usize {
        const ap = try self.intern(path);
        const e = try self.gpa.dupe(u8, entry);
        errdefer self.gpa.free(e);
        const o = if (owner) |n| try self.gpa.dupe(u8, n) else null;
        errdefer if (o) |n| self.gpa.free(n);
        _ = changed;
        try self.files.append(self.gpa, .{ .archive = ap, .entry = e, .text = t, .owner = o });
        return self.files.items.len - 1;
    }

    /// New files (takes their texts) that one undo takes away again; returns the first.
    pub fn addNew(self: *Store, files: []const NewFile) !usize {
        const first = self.files.items.len;
        for (files) |f| _ = try self.add(f.archive, f.entry, f.text, null, true);
        const label = try std.fmt.allocPrint(self.gpa, "+ {s}", .{files[0].entry});
        errdefer self.gpa.free(label);
        var diff: std.ArrayList(u8) = .empty;
        errdefer diff.deinit(self.gpa);
        for (files) |f| try diff.print(self.gpa, "+{s} ({s})\n", .{ f.entry, f.archive });
        const d = try diff.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(d);
        try self.undo.append(self.gpa, .{ .file = first, .text = try self.gpa.dupe(u8, ""), .created = files.len, .label = label, .diff = d });
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
        for (files) |i| self.files.items[i].deleted = true;
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
    }

    /// Back to the last save: later steps undone, files made since without a step
    /// (a class copy, an import) dropped.
    pub fn revert(self: *Store) void {
        while (self.undo.items.len > self.saved_at) _ = self.undoLast();
        for (self.files.items, 0..) |*f, i| {
            if (f.on_disk or f.entry.len == 0 or self.toWrite(i) != .write) continue;
            self.gpa.free(f.entry);
            f.entry = &.{};
        }
    }

    /// Steps back one edit; returns the file it restored.
    /// Level `name` made on disk (`dat/<name>`, written at once: the editor opens
    /// levels from their archives): one step, undone by deleting the folder.
    pub fn levelMade(self: *Store, name: []const u8, label: []const u8) !void {
        const l = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(l);
        const lb = try self.gpa.dupe(u8, label);
        errdefer self.gpa.free(lb);
        try self.undo.append(self.gpa, .{ .file = 0, .text = try self.gpa.dupe(u8, ""), .label = lb, .level = l });
    }

    /// Undoes the last step; returns the file it restored (null: none, or a level
    /// folder was deleted — the caller drops levels gone from disk).
    pub fn undoLast(self: *Store) ?usize {
        const u = self.undo.pop() orelse return null;
        defer self.gpa.free(u.label);
        defer self.gpa.free(u.diff);
        if (u.level) |l| {
            defer self.gpa.free(l);
            self.gpa.free(u.text);
            self.dat.deleteTree(self.io, l) catch |err| std.log.warn("{s}: {t}", .{ l, err });
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

    /// Sets `names` to `v` in file `i` (one undo step): the last assignment, or a
    /// new line after the line holding `after`.
    pub fn setVar(self: *Store, i: usize, names: []const []const u8, v: []const u8, after: ?[]const u8) !void {
        var t = try self.gpa.dupe(u8, self.text(i));
        errdefer self.gpa.free(t);
        for (names) |n| {
            const next = try vars.set(self.gpa, t, n, v, after);
            self.gpa.free(t);
            t = next;
        }
        try self.replace(i, t);
    }

    /// Removes the overrides of `names` from file `i`.
    pub fn unsetVar(self: *Store, i: usize, names: []const []const u8) !void {
        var t = try self.gpa.dupe(u8, self.text(i));
        errdefer self.gpa.free(t);
        for (names) |n| if (try vars.unset(self.gpa, t, n)) |next| {
            self.gpa.free(t);
            t = next;
        };
        try self.replace(i, t);
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
        var dir = self.dat.openDir(self.io, history_path, .{}) catch return;
        defer dir.close(self.io);
        self.past = savelog.load(self.io, self.gpa, dir) catch |err| return std.log.warn("{s}: {t}", .{ savelog.dir_name, err });
    }

    /// Puts the files back as they were after the first `keep` saves of earlier
    /// sessions (0: before any, the original): one undo step per file, unsaved.
    /// Returns the files changed.
    pub fn restorePast(self: *Store, keep: usize) !usize {
        const log = &(self.past orelse return 0);
        var dir = try self.dat.openDir(self.io, history_path, .{});
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
                    var buf: [300]u8 = undefined;
                    const label = std.fmt.bufPrint(&buf, "restored {s}\n", .{t.entry}) catch "restored\n";
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
    fn record(self: *Store) !void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var changes: std.ArrayList(savelog.File) = .empty;
        for (self.files.items, 0..) |f, i| {
            const w = self.toWrite(i);
            if (w == .none) continue;
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
        // Files made without a step (an import): their names.
        if (label.items.len == 0) for (changes.items) |c| try label.print(a, "{s} ", .{c.entry});
        var dir = try self.dat.openDir(self.io, "..", .{});
        defer dir.close(self.io);
        try dir.createDirPath(self.io, savelog.dir_name);
        var h = try dir.openDir(self.io, savelog.dir_name, .{});
        defer h.close(self.io);
        const now = Io.Timestamp.now(self.io, .real).toSeconds();
        try savelog.append(self.io, self.gpa, h, now, label.items, diff.items, changes.items);
    }

    /// Writes every changed file into its archive (the game folder itself).
    pub fn save(self: *Store) !void {
        // Before any write: adjust.kdt past the exe's limits would crash the original.
        for (self.files.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.archive, adjust_file) and self.toWrite(i) == .write) try og.formats.adjust.checkLimits(f.text);
        }
        // First, while the contents before it are at hand; a save that fails after
        // shows in the history too (its "before" stays right).
        self.record() catch |err| std.log.warn("{s}: {t}", .{ savelog.dir_name, err });
        for (self.archives.items) |path| {
            var list: std.ArrayList(archive.File) = .empty;
            defer list.deinit(self.gpa);
            for (self.files.items, 0..) |f, i| {
                if (f.archive.ptr != path.ptr) continue;
                switch (self.toWrite(i)) {
                    .none => {},
                    .write => try list.append(self.gpa, .{ .name = f.entry, .data = f.text }),
                    .delete => try list.append(self.gpa, .{ .name = f.entry, .data = "", .delete = true }),
                }
            }
            if (list.items.len == 0) continue;
            if (std.mem.eql(u8, path, adjust_file)) {
                const enc = try og.formats.adjust.encode(self.gpa, list.items[0].data);
                defer self.gpa.free(enc);
                try self.dat.writeFile(self.io, .{ .sub_path = adjust_path, .data = enc });
            } else {
                try archive.rewrite(self.io, self.gpa, self.dat, path, list.items);
                // The original would keep drawing its cached copy of the old one.
                _ = try archive.dropCached(self.io, self.dat, path);
            }
            // The archive is as the files now: they differ from it no more.
            for (self.files.items, 0..) |*f, i| {
                if (f.archive.ptr != path.ptr) continue;
                switch (self.toWrite(i)) {
                    .none => {},
                    .write => f.on_disk = true,
                    .delete => f.on_disk = false,
                }
                if (f.base) |b| self.gpa.free(b);
                f.base = null;
            }
        }
        self.saved_at = self.undo.items.len;
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

/// "<file>: <first changed line of the new text>" (or of the old one, struck out).
fn changeLabel(gpa: Allocator, entry: []const u8, old: []const u8, new: []const u8) ![]u8 {
    const short = entry[if (std.mem.lastIndexOfScalar(u8, entry, '\\')) |k| k + 1 else 0..];
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

//! The editor's saves kept across sessions, in the game folder's `.opengorky-history/`:
//! `log.txt` holds one block per save, `blobs/<hash>` every file content once (by its
//! SHA-256). A block:
//!   @<unix seconds>\t<label>
//!   =<archive>\t<entry>\t<hash before>\t<hash after>   ("-": the file not there)
//!   -old line / +new line                             (what the save changed)

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const dir_name = ".opengorky-history";
const log_name = "log.txt";
const Hash = [32]u8;

/// A file a save changed: before and after it (null: not in the archive) — the
/// contents given to `append`, their hashes in a loaded log.
pub const File = struct { archive: []const u8, entry: []const u8, before: ?[]const u8, after: ?[]const u8 };
pub const Step = struct { time: i64, label: []const u8, diff: []const u8, files: []File };

/// The saves of earlier sessions, oldest first.
pub const Log = struct {
    arena: std.heap.ArenaAllocator,
    steps: []Step = &.{},

    pub fn deinit(self: *Log) void {
        self.arena.deinit();
    }

    /// Files changed by the saves after the first `keep`, each with its content
    /// before the first of them (null: it was not there): what returning puts back.
    pub fn targets(self: *const Log, gpa: Allocator, keep: usize) ![]File {
        var out: std.ArrayList(File) = .empty;
        errdefer out.deinit(gpa);
        for (self.steps[@min(keep, self.steps.len)..]) |s| for (s.files) |f| {
            for (out.items) |o| {
                if (std.mem.eql(u8, o.archive, f.archive) and std.ascii.eqlIgnoreCase(o.entry, f.entry)) break;
            } else try out.append(gpa, f);
        };
        return out.toOwnedSlice(gpa);
    }
};

/// The log of history folder `dir` (none yet: empty); a bad line is skipped.
pub fn load(io: Io, gpa: Allocator, dir: Io.Dir) !Log {
    var log: Log = .{ .arena = .init(gpa) };
    errdefer log.deinit();
    const a = log.arena.allocator();
    const data = dir.readFileAlloc(io, log_name, a, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => return log,
        else => return err,
    };
    var steps: std.ArrayList(Step) = .empty;
    var files: std.ArrayList(File) = .empty;
    var diff_start: usize = 0;
    var pos: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| : (pos = it.index orelse data.len) {
        if (line.len == 0) continue;
        switch (line[0]) {
            '@' => {
                try closeStep(a, &steps, &files, data[diff_start..pos]);
                var f = std.mem.splitScalar(u8, line[1..], '\t');
                const time = std.fmt.parseInt(i64, f.first(), 10) catch 0;
                try steps.append(a, .{ .time = time, .label = f.rest(), .diff = "", .files = &.{} });
                diff_start = it.index orelse data.len;
            },
            '=' => {
                if (steps.items.len == 0) continue;
                var f = std.mem.splitScalar(u8, line[1..], '\t');
                const ar = f.next() orelse continue;
                const entry = f.next() orelse continue;
                const before = f.next() orelse continue;
                const after = f.next() orelse continue;
                try files.append(a, .{ .archive = ar, .entry = entry, .before = hashOrNull(before), .after = hashOrNull(after) });
                diff_start = it.index orelse data.len;
            },
            else => {},
        }
    }
    try closeStep(a, &steps, &files, data[diff_start..]);
    log.steps = try steps.toOwnedSlice(a);
    return log;
}

fn closeStep(a: Allocator, steps: *std.ArrayList(Step), files: *std.ArrayList(File), diff: []const u8) !void {
    if (steps.items.len == 0) return;
    const s = &steps.items[steps.items.len - 1];
    if (s.files.len > 0 or files.items.len > 0) {
        s.files = try files.toOwnedSlice(a);
        s.diff = diff;
    }
}

fn hashOrNull(h: []const u8) ?[]const u8 {
    return if (h.len == 64) h else null;
}

/// Appends one save to history folder `dir`: the contents first (each kept once), then
/// its block.
pub fn append(io: Io, gpa: Allocator, dir: Io.Dir, time: i64, label: []const u8, diff: []const u8, changes: []const File) !void {
    try dir.createDirPath(io, "blobs");
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(gpa);
    try block.print(gpa, "@{d}\t", .{time});
    for (label) |ch| try block.append(gpa, if (ch == '\n' or ch == '\t') ' ' else ch);
    try block.append(gpa, '\n');
    for (changes) |c| {
        var hb: [64]u8 = undefined;
        var ha: [64]u8 = undefined;
        try block.print(gpa, "={s}\t{s}\t{s}\t{s}\n", .{ c.archive, c.entry, try put(io, dir, c.before, &hb), try put(io, dir, c.after, &ha) });
    }
    // Only "-…" / "+…" lines: anything else would read as a block of its own.
    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |l| if (l.len > 0 and (l[0] == '-' or l[0] == '+')) {
        try block.appendSlice(gpa, l);
        try block.append(gpa, '\n');
    };
    var f = try dir.createFile(io, log_name, .{ .truncate = false });
    defer f.close(io);
    try f.writePositionalAll(io, block.items, try f.length(io));
}

/// Content `data` stored (once) under its hash, which goes in `buf`; null: "-".
fn put(io: Io, dir: Io.Dir, data: ?[]const u8, buf: *[64]u8) ![]const u8 {
    const d = data orelse return "-";
    var h: Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(d, &h, .{});
    buf.* = std.fmt.bytesToHex(h, .lower);
    var path: [80]u8 = undefined;
    const p = try std.fmt.bufPrint(&path, "blobs/{s}", .{buf});
    dir.writeFile(io, .{ .sub_path = p, .data = d, .flags = .{ .exclusive = true } }) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return buf;
}

/// The content stored under `hash`; error.BadBlob if it is not that content (a cut write).
pub fn blob(io: Io, gpa: Allocator, dir: Io.Dir, hash: []const u8) ![]u8 {
    var path: [80]u8 = undefined;
    const data = try dir.readFileAlloc(io, try std.fmt.bufPrint(&path, "blobs/{s}", .{hash}), gpa, .limited(1 << 30));
    errdefer gpa.free(data);
    var h: Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &h, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(h, .lower), hash)) return error.BadBlob;
    return data;
}

test "savelog: two saves back, the original from the first" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try append(io, gpa, tmp.dir, 100, "a.lev: x = 1", "-x = 0\n+x = 1\n", &.{
        .{ .archive = "common/other.dat", .entry = "a.lev", .before = "x = 0", .after = "x = 1" },
        .{ .archive = "common/other.dat", .entry = "new.ftr", .before = null, .after = "n" },
    });
    try append(io, gpa, tmp.dir, 200, "two\tedits", "+y\n", &.{
        .{ .archive = "common/other.dat", .entry = "A.LEV", .before = "x = 1", .after = "x = 2" },
        .{ .archive = "adjust.kdt", .entry = "adjust.kdt", .before = "x = 1", .after = "k" },
    });
    var log = try load(io, gpa, tmp.dir);
    defer log.deinit();
    try std.testing.expectEqual(2, log.steps.len);
    try std.testing.expectEqual(200, log.steps[1].time);
    try std.testing.expectEqualStrings("two edits", log.steps[1].label);
    try std.testing.expectEqualStrings("-x = 0\n+x = 1\n", log.steps[0].diff);
    try std.testing.expectEqualStrings("+y\n", log.steps[1].diff);
    // Back to after the first save: a.lev as it saved, adjust.kdt before the second.
    const back = try log.targets(gpa, 1);
    defer gpa.free(back);
    try std.testing.expectEqual(2, back.len);
    const one = try blob(io, gpa, tmp.dir, back[0].before.?);
    defer gpa.free(one);
    try std.testing.expectEqualStrings("x = 1", one);
    // The original: a.lev before any save, new.ftr not there; "x = 1" kept once.
    const orig = try log.targets(gpa, 0);
    defer gpa.free(orig);
    try std.testing.expectEqual(3, orig.len);
    const zero = try blob(io, gpa, tmp.dir, orig[0].before.?);
    defer gpa.free(zero);
    try std.testing.expectEqualStrings("x = 0", zero);
    try std.testing.expect(orig[1].before == null);
    var blobs = try tmp.dir.openDir(io, "blobs", .{ .iterate = true });
    defer blobs.close(io);
    var n: usize = 0;
    var bi = blobs.iterate();
    while (try bi.next(io)) |_| n += 1;
    try std.testing.expectEqual(5, n);
    // A cut blob is refused, not put back.
    var path: [80]u8 = undefined;
    try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path, "blobs/{s}", .{orig[0].before.?}), .data = "x =" });
    try std.testing.expectError(error.BadBlob, blob(io, gpa, tmp.dir, orig[0].before.?));
}

//! Gorky 17 resource archive (`dat/*/sprite.dat`, `other.dat`, `common/*.dat`, `sprite.kdt`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const header_size = 32;
/// The time the game's own archive files carry (1999), for an archive with none.
const game_filetime: u64 = 0x01bf10c45677f600;
const entry_size = 128;
pub const name_size = entry_size - 16;

pub const Entry = struct {
    offset: u32,
    size: u32,
    /// Windows FILETIME (100 ns intervals since 1601-01-01).
    filetime: u64,
    name: []const u8,
};

const ParseError = error{ Truncated, EntryOutOfBounds };

/// Parses the archive index. `index` is the bytes from offset zero, at least
/// `indexSize(count)` long. Result names point into `index`.
fn parseIndex(gpa: Allocator, index: []const u8, file_size: u64) (ParseError || Allocator.Error)![]Entry {
    if (index.len < header_size) return error.Truncated;
    const count = std.mem.readInt(u32, index[0..4], .little);
    if (index.len < indexSize(count)) return error.Truncated;

    const entries = try gpa.alloc(Entry, count);
    errdefer gpa.free(entries);
    for (entries, 0..) |*e, i| {
        const raw = index[header_size + i * entry_size ..][0..entry_size];
        const name_raw = raw[16..][0..name_size];
        e.* = .{
            .offset = std.mem.readInt(u32, raw[0..4], .little),
            .size = std.mem.readInt(u32, raw[4..8], .little),
            .filetime = std.mem.readInt(u64, raw[8..16], .little),
            .name = name_raw[0 .. std.mem.indexOfScalar(u8, name_raw, 0) orelse name_size],
        };
        if (@as(u64, e.offset) + e.size > file_size) return error.EntryOutOfBounds;
    }
    return entries;
}

fn indexSize(count: u32) usize {
    return header_size + @as(usize, count) * entry_size;
}

/// Opens a file ignoring name case (the game targets Windows: editions ship both
/// `common/sprite.dat` and `common/SPRITE.DAT`). Tries the path as is first
/// (case-insensitive on macOS); otherwise each path component is looked up
/// case-insensitively in its directory (Linux).
fn openFileAnyCase(io: Io, dir: Io.Dir, path: []const u8) Io.File.OpenError!Io.File {
    if (dir.openFile(io, path, .{})) |f| return f else |err| if (err != error.FileNotFound) return err;
    var buf: [512]u8 = undefined;
    return dir.openFile(io, try resolveAnyCase(io, dir, path, &buf), .{});
}

/// `path` with each part spelled as on disk (matched case-insensitively).
fn resolveAnyCase(io: Io, dir: Io.Dir, path: []const u8, buf: *[512]u8) error{ FileNotFound, NameTooLong }![]const u8 {
    var len: usize = 0;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        const parent = if (len == 0) "." else buf[0..len];
        var d = dir.openDir(io, parent, .{ .iterate = true }) catch return error.FileNotFound;
        defer d.close(io);
        var di = d.iterate();
        const name = while (di.next(io) catch null) |e| {
            if (std.ascii.eqlIgnoreCase(e.name, part)) break e.name;
        } else return error.FileNotFound;
        const sep: usize = if (len == 0) 0 else 1;
        if (len + sep + name.len > buf.len) return error.NameTooLong;
        if (sep == 1) buf[len] = '/';
        @memcpy(buf[len + sep ..][0..name.len], name);
        len += sep + name.len;
    }
    return buf[0..len];
}

pub const Archive = struct {
    file: Io.File,
    index: []u8,
    entries: []Entry,

    const OpenError = Io.File.OpenError || Io.File.LengthError || Io.File.ReadPositionalError ||
        ParseError || Allocator.Error;

    pub fn open(io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8) OpenError!Archive {
        const file = try openFileAnyCase(io, dir, path);
        errdefer file.close(io);
        const file_size = try file.length(io);

        var head: [header_size]u8 = undefined;
        if (try file.readPositionalAll(io, &head, 0) != head.len) return error.Truncated;
        const count = std.mem.readInt(u32, head[0..4], .little);
        if (indexSize(count) > file_size) return error.Truncated;

        const index = try gpa.alloc(u8, indexSize(count));
        errdefer gpa.free(index);
        if (try file.readPositionalAll(io, index, 0) != index.len) return error.Truncated;

        return .{
            .file = file,
            .index = index,
            .entries = try parseIndex(gpa, index, file_size),
        };
    }

    pub fn close(self: *Archive, io: Io, gpa: Allocator) void {
        gpa.free(self.entries);
        gpa.free(self.index);
        self.file.close(io);
        self.* = undefined;
    }

    /// Case-insensitive lookup: the game targets Windows.
    /// As the exe needs it: entries by name ignoring case (the empty one last), each
    /// with a time, script files marked (`isScript`). Older editors wrote otherwise.
    pub fn wellFormed(self: Archive) bool {
        var prev: []const u8 = "";
        for (self.entries, 0..) |e, i| {
            if (e.name.len == 0) continue;
            if (std.ascii.lessThanIgnoreCase(e.name, prev) or e.filetime == 0) return false;
            if (isScript(e.name) and e.name.len + 1 < name_size and self.index[header_size + i * entry_size + 16 + e.name.len + 1] != 's') return false;
            prev = e.name;
        }
        return true;
    }

    pub fn find(self: Archive, name: []const u8) ?*const Entry {
        for (self.entries) |*e| {
            if (std.ascii.eqlIgnoreCase(e.name, name)) return e;
        }
        return null;
    }

    pub fn readAlloc(self: Archive, io: Io, gpa: Allocator, entry: *const Entry) (Io.File.ReadPositionalError || Allocator.Error || ParseError)![]u8 {
        const buf = try gpa.alloc(u8, entry.size);
        errdefer gpa.free(buf);
        if (try self.file.readPositionalAll(io, buf, entry.offset) != buf.len) return error.Truncated;
        return buf;
    }
};

/// A file to store with `build`.
pub const File = struct {
    name: []const u8,
    data: []const u8,
    filetime: u64 = 0,
    /// The original name field (name, NUL, then leftover buffer bytes), kept so an
    /// unchanged archive rewrites byte for byte.
    name_field: ?*const [name_size]u8 = null,
    /// In `rewrite` changes: remove the same-named entry (`data` unused).
    delete: bool = false,
};

/// Script files carry an `s` right after their name's NUL in the index: the location
/// start (0x431600, `cmp byte [name + len + 1], 's'`) makes objects only of those, so
/// a script file without it is never loaded. Every game archive marks exactly these.
const script_exts = [_][]const u8{ ".aba", ".act", ".are", ".ba", ".ftr", ".hro", ".itm", ".lev", ".obs", ".obs_i", ".pth", ".wpn", ".s", ".ss", ".scr", ".pts", ".var" };

pub fn isScript(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    for (script_exts) |x| if (std.ascii.eqlIgnoreCase(ext, x)) return true;
    return false;
}

/// Offset of the file after one ending at `end`: the game's archives start it at
/// the next 32-byte boundary, a whole 32 bytes on when `end` is already aligned.
fn nextOffset(end: usize) usize {
    return end / 32 * 32 + 32;
}

/// Archive bytes for `files` in this order: header, index, data.
pub fn build(gpa: Allocator, files: []const File) (Allocator.Error || error{ NameTooLong, TooLarge })![]u8 {
    var size = indexSize(@intCast(files.len));
    for (files, 0..) |f, i| {
        if (f.name.len >= name_size) return error.NameTooLong;
        if (i > 0) size = nextOffset(size);
        size += f.data.len;
    }
    if (size > std.math.maxInt(u32)) return error.TooLarge;
    const buf = try gpa.alloc(u8, size);
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], @intCast(files.len), .little);
    var at = indexSize(@intCast(files.len));
    for (files, 0..) |f, i| {
        if (i > 0) at = nextOffset(at);
        const raw = buf[header_size + i * entry_size ..][0..entry_size];
        std.mem.writeInt(u32, raw[0..4], @intCast(at), .little);
        std.mem.writeInt(u32, raw[4..8], @intCast(f.data.len), .little);
        std.mem.writeInt(u64, raw[8..16], f.filetime, .little);
        if (f.name_field) |nf| raw[16..][0..name_size].* = nf.* else @memcpy(raw[16..][0..f.name.len], f.name);
        if (isScript(f.name) and f.name.len + 1 < name_size) raw[16 + f.name.len + 1] = 's';
        @memcpy(buf[at..][0..f.data.len], f.data);
        at += f.data.len;
    }
    return buf;
}

/// Rewrites archive `path` in place: files in `changes` replace same-named entries
/// (case-insensitive) or are added, or with `delete` remove them; the rest is copied
/// as is. Entries stay sorted by name ignoring case, the empty one last: every game
/// archive is, and the exe finds files by that order — a file added at the end is
/// never found (the battle's enemy missing, the script placing it crashing). Written through `<path>.tmp` and renamed, so a failed write keeps
/// the old archive.
pub fn rewrite(io: Io, gpa: Allocator, dir: Io.Dir, path: []const u8, changes: []const File) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var files: std.ArrayList(File) = .empty;
    {
        var ar = try Archive.open(io, gpa, dir, path);
        defer ar.close(io, gpa);
        for (ar.entries, 0..) |*e, i| try files.append(arena, .{
            .name = try arena.dupe(u8, e.name),
            .data = try ar.readAlloc(io, arena, e),
            .filetime = e.filetime,
            .name_field = (try arena.dupe(u8, ar.index[header_size + i * entry_size + 16 ..][0..name_size]))[0..name_size],
        });
    }
    // The game's archives end with an empty-named, empty entry; new files go before it.
    const tail = files.items.len > 0 and files.items[files.items.len - 1].name.len == 0;
    for (changes) |c| {
        if (c.delete) {
            for (files.items, 0..) |f, i| if (std.ascii.eqlIgnoreCase(f.name, c.name)) {
                _ = files.orderedRemove(i);
                break;
            };
            continue;
        }
        for (files.items) |*f| {
            if (std.ascii.eqlIgnoreCase(f.name, c.name)) {
                f.data = c.data;
                break;
            }
        } else try files.insert(arena, files.items.len - @intFromBool(tail), c);
    }
    // Every game file has a time; new ones (and ones written before without) get the
    // archive's newest, so they don't stand out as empty entries.
    var stamp: u64 = 0;
    for (files.items) |f| stamp = @max(stamp, f.filetime);
    if (stamp == 0) stamp = game_filetime;
    for (files.items) |*f| if (f.filetime == 0 and f.name.len > 0) {
        f.filetime = stamp;
    };
    // Stable: same-named entries (the two vssver.scc) keep their order.
    std.mem.sort(File, files.items[0 .. files.items.len - @intFromBool(tail)], {}, struct {
        fn lt(_: void, a: File, b: File) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lt);
    const bytes = try build(arena, files.items);
    // The name on disk (common/OTHER.DAT), so a case-sensitive file system gets no second copy.
    var real_buf: [512]u8 = undefined;
    const real = try resolveAnyCase(io, dir, path, &real_buf);
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{real});
    try dir.writeFile(io, .{ .sub_path = tmp, .data = bytes });
    try Io.Dir.rename(dir, tmp, dir, real, io);
}

/// Archive paths relative to `<game>/dat`, sorted by name.
/// Top-level `dat/*.dat` (`r1/r2/r3.dat`) are engine work files and are skipped.
pub fn listArchives(io: Io, gpa: Allocator, dat: Io.Dir) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer freeList(gpa, list.items);
    defer list.deinit(gpa);

    var walker = try dat.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file or !std.ascii.eqlIgnoreCase(std.fs.path.extension(e.basename), ".dat")) continue;
        if (e.depth() == 1) continue;
        const p = try gpa.dupe(u8, e.path);
        errdefer gpa.free(p);
        try list.append(gpa, p);
    }
    std.mem.sort([]const u8, list.items, {}, lessThan);
    return list.toOwnedSlice(gpa);
}

pub fn freeList(gpa: Allocator, items: []const []const u8) void {
    for (items) |p| gpa.free(p);
    gpa.free(items);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn writeTestEntry(buf: []u8, i: usize, offset: u32, size: u32, name: []const u8) void {
    const raw = buf[header_size + i * entry_size ..][0..entry_size];
    std.mem.writeInt(u32, raw[0..4], offset, .little);
    std.mem.writeInt(u32, raw[4..8], size, .little);
    std.mem.writeInt(u64, raw[8..16], 0x01bf13d567cb4600, .little);
    @memcpy(raw[16..][0..name.len], name);
}

test "parseIndex reads entries" {
    const gpa = std.testing.allocator;
    var buf: [header_size + 2 * entry_size + 5]u8 = @splat(0);
    std.mem.writeInt(u32, buf[0..4], 2, .little);
    const data_start: u32 = header_size + 2 * entry_size;
    writeTestEntry(&buf, 0, data_start, 3, "a.bin");
    writeTestEntry(&buf, 1, data_start + 3, 2, "01_port.ap");

    const entries = try parseIndex(gpa, &buf, buf.len);
    defer gpa.free(entries);
    try std.testing.expectEqual(2, entries.len);
    try std.testing.expectEqualStrings("a.bin", entries[0].name);
    try std.testing.expectEqualStrings("01_port.ap", entries[1].name);
    try std.testing.expectEqual(data_start + 3, entries[1].offset);
    try std.testing.expectEqual(0x01bf13d567cb4600, entries[0].filetime);
}

test "parseIndex rejects out-of-bounds entry" {
    const gpa = std.testing.allocator;
    var buf: [header_size + entry_size]u8 = @splat(0);
    std.mem.writeInt(u32, buf[0..4], 1, .little);
    writeTestEntry(&buf, 0, header_size + entry_size, 10, "x");
    try std.testing.expectError(error.EntryOutOfBounds, parseIndex(gpa, &buf, buf.len));
}

test "build: index parses back, data aligned" {
    const gpa = std.testing.allocator;
    const bytes = try build(gpa, &.{
        .{ .name = "a.lev", .data = "abc", .filetime = 7 },
        .{ .name = "b.ftr", .data = "hello" },
        .{ .name = "", .data = "" },
    });
    defer gpa.free(bytes);
    const entries = try parseIndex(gpa, bytes, bytes.len);
    defer gpa.free(entries);
    try std.testing.expectEqual(3, entries.len);
    try std.testing.expectEqualStrings("b.ftr", entries[1].name);
    try std.testing.expectEqual(7, entries[0].filetime);
    try std.testing.expectEqual(header_size + 3 * entry_size, entries[0].offset);
    try std.testing.expectEqual(entries[0].offset + 32, entries[1].offset);
    for (entries) |e| try std.testing.expectEqual(0, e.offset % 32);
    try std.testing.expectEqualStrings("hello", bytes[entries[1].offset..][0..entries[1].size]);
}

test "rewrite: replaces, adds before the empty tail, keeps the rest" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const orig = try build(gpa, &.{
        .{ .name = "x.lev", .data = "old", .filetime = 5 },
        .{ .name = "y.wpn", .data = "keep" },
        .{ .name = "", .data = "" },
    });
    defer gpa.free(orig);
    try tmp.dir.writeFile(io, .{ .sub_path = "other.dat", .data = orig });

    try rewrite(io, gpa, tmp.dir, "other.dat", &.{
        .{ .name = "X.LEV", .data = "new level" },
        .{ .name = "z.ftr", .data = "added" },
        .{ .name = "a_1.ftr", .data = "first" },
    });

    var ar = try Archive.open(io, gpa, tmp.dir, "other.dat");
    defer ar.close(io, gpa);
    try std.testing.expectEqual(5, ar.entries.len);
    // Sorted ignoring case, the empty entry last; new files take the newest time.
    try std.testing.expectEqualStrings("a_1.ftr", ar.entries[0].name);
    try std.testing.expectEqual(5, ar.entries[0].filetime);
    try std.testing.expectEqual(0, ar.entries[4].filetime);
    // Script files marked for the exe's object loader.
    try std.testing.expectEqual('s', ar.index[header_size + 16 + "a_1.ftr".len + 1]);
    try std.testing.expect(ar.wellFormed());
    try std.testing.expectEqualStrings("z.ftr", ar.entries[3].name);
    try std.testing.expectEqualStrings("", ar.entries[4].name);
    try std.testing.expectEqual(5, ar.entries[1].filetime);
    const x = try ar.readAlloc(io, gpa, ar.find("x.lev").?);
    defer gpa.free(x);
    try std.testing.expectEqualStrings("new level", x);
    const y = try ar.readAlloc(io, gpa, ar.find("y.wpn").?);
    defer gpa.free(y);
    try std.testing.expectEqualStrings("keep", y);

    try rewrite(io, gpa, tmp.dir, "other.dat", &.{ .{ .name = "Y.WPN", .data = "", .delete = true }, .{ .name = "none", .data = "", .delete = true } });
    var ar2 = try Archive.open(io, gpa, tmp.dir, "other.dat");
    defer ar2.close(io, gpa);
    try std.testing.expectEqual(4, ar2.entries.len);
    try std.testing.expectEqual(null, ar2.find("y.wpn"));
}

test "parseIndex rejects truncated index" {
    const gpa = std.testing.allocator;
    var buf: [header_size]u8 = @splat(0);
    std.mem.writeInt(u32, buf[0..4], 1, .little);
    try std.testing.expectError(error.Truncated, parseIndex(gpa, &buf, buf.len));
}

/// The exe's level cache: `dat\r1.dat`…`r7.dat`, each a level's `sprite.dat` converted to
/// the screen's pixel format, named by a 300-byte tail ("dat\01_port\sprite.kdt",
/// compared at 0x41ddad). The exe trusts the name alone — a changed `sprite.dat` keeps
/// showing the old copy. A slot naming archive `path` (or any, `path` null) loses its
/// name: the exe converts the archive again. Returns how many slots were dropped.
pub fn dropCached(io: Io, dir: Io.Dir, path: ?[]const u8) !usize {
    var dropped: usize = 0;
    for (1..8) |k| {
        var nb: [8]u8 = undefined;
        const file = dir.openFile(io, std.fmt.bufPrint(&nb, "r{d}.dat", .{k}) catch unreachable, .{ .mode = .read_write }) catch continue;
        defer file.close(io);
        const len = try file.length(io);
        if (len < cache_tail) continue;
        var tail: [cache_tail]u8 = undefined;
        if (try file.readPositionalAll(io, &tail, len - cache_tail) != tail.len) continue;
        const name = std.mem.sliceTo(&tail, 0);
        if (name.len == 0) continue;
        if (path) |p| if (!cachedIs(name, p)) continue;
        try file.writePositionalAll(io, &(@as([cache_tail]u8, @splat(0))), len - cache_tail);
        dropped += 1;
    }
    return dropped;
}

const cache_tail = 300;

/// `dat\<level>\sprite.kdt` names archive `<level>/sprite.dat` (case, slashes and the
/// extension aside).
fn cachedIs(name: []const u8, path: []const u8) bool {
    const n = if (std.ascii.startsWithIgnoreCase(name, "dat\\")) name[4..] else name;
    const a = n[0 .. std.mem.lastIndexOfScalar(u8, n, '.') orelse n.len];
    const b = path[0 .. std.mem.lastIndexOfScalar(u8, path, '.') orelse path.len];
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const sx = x == '\\' or x == '/';
        const sy = y == '\\' or y == '/';
        if (sx != sy or (!sx and std.ascii.toLower(x) != std.ascii.toLower(y))) return false;
    }
    return true;
}

test "cachedIs: the cache's names for archives" {
    try std.testing.expect(cachedIs("dat\\01_port\\sprite.kdt", "01_port/sprite.dat"));
    try std.testing.expect(cachedIs("dat\\01__Port_bulldozer\\sprite.kdt", "01__port_bulldozer/sprite.dat"));
    try std.testing.expect(!cachedIs("dat\\01_port\\sprite.kdt", "01_port_chief/sprite.dat"));
    try std.testing.expect(!cachedIs("dat\\01_port\\sprite.kdt", "01_port/other.dat"));
}

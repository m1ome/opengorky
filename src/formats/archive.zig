//! Gorky 17 resource archive (`dat/*/sprite.dat`, `other.dat`, `common/*.dat`, `sprite.kdt`).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const header_size = 32;
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
    return dir.openFile(io, buf[0..len], .{});
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

test "parseIndex rejects truncated index" {
    const gpa = std.testing.allocator;
    var buf: [header_size]u8 = @splat(0);
    std.mem.writeInt(u32, buf[0..4], 1, .little);
    try std.testing.expectError(error.Truncated, parseIndex(gpa, &buf, buf.len));
}

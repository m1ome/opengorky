//! A mod packed for the original game: the files of the edited game folder that are new
//! or differ from an untouched copy of the game (`dat/**`, `avi/*`), copied into a folder
//! with the same layout, with a README and `clear-cache.bat` (the exe keeps drawing its
//! `dat\r1..r7.dat` copies of changed sprite archives until they are gone).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// What the game folder holds besides the original's files (not part of a mod).
fn skipped(rel: []const u8) bool {
    // The exe's level cache (dat/r1.dat…r7.dat) and converted copies (.kdt), Visual
    // SourceSafe leftovers.
    if (rel.len == "dat/r1.dat".len and std.ascii.startsWithIgnoreCase(rel, "dat/r") and
        rel[5] >= '1' and rel[5] <= '7' and std.ascii.endsWithIgnoreCase(rel, ".dat")) return true;
    return std.ascii.endsWithIgnoreCase(rel, ".scc") or std.ascii.endsWithIgnoreCase(rel, ".kdt");
}

/// Paths (relative to the game folder, `/`) of `dat/` and `avi/` files (and adjust.kdt) of `game` that the
/// original folder lacks or holds with other bytes; sorted.
pub fn changed(io: Io, gpa: Allocator, game: Io.Dir, original: Io.Dir) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    for ([_][]const u8{ "dat", "avi" }) |top| {
        var dir = game.openDir(io, top, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |e| {
            if (e.kind != .file) continue;
            const rel = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ top, e.path });
            if (skipped(rel) or try same(io, gpa, game, original, rel)) {
                gpa.free(rel);
                continue;
            }
            try out.append(gpa, rel);
        }
    }
    // The engine's tuning file in the root (the editor's Engine settings).
    if (!try same(io, gpa, game, original, "adjust.kdt") and (game.statFile(io, "adjust.kdt", .{}) catch null) != null)
        try out.append(gpa, try gpa.dupe(u8, "adjust.kdt"));
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(gpa);
}

/// File `rel` has the same bytes in both folders.
fn same(io: Io, gpa: Allocator, a: Io.Dir, b: Io.Dir, rel: []const u8) !bool {
    const x = a.readFileAlloc(io, rel, gpa, .unlimited) catch return false;
    defer gpa.free(x);
    const y = b.readFileAlloc(io, rel, gpa, .unlimited) catch return false;
    defer gpa.free(y);
    return std.mem.eql(u8, x, y);
}

pub fn freeList(gpa: Allocator, items: []const []const u8) void {
    for (items) |p| gpa.free(p);
    gpa.free(items);
}

/// The changed files of `game` copied into `out` (made if missing) under their paths,
/// with README.txt and clear-cache.bat; the files packed.
pub fn pack(io: Io, gpa: Allocator, game: Io.Dir, original: Io.Dir, out: Io.Dir) ![][]const u8 {
    const files = try changed(io, gpa, game, original);
    errdefer freeList(gpa, files);
    for (files) |rel| {
        if (std.fs.path.dirname(rel)) |d| try out.createDirPath(io, d);
        const data = try game.readFileAlloc(io, rel, gpa, .unlimited);
        defer gpa.free(data);
        try out.writeFile(io, .{ .sub_path = rel, .data = data });
    }
    var readme: std.ArrayList(u8) = .empty;
    defer readme.deinit(gpa);
    try readme.appendSlice(gpa,
        \\Gorky 17 mod (made with the OpenGorky editor)
        \\
        \\Install: copy everything in this folder over the game folder (replace files),
        \\then run clear-cache.bat there once. The game keeps converted copies of level
        \\pictures in dat\r1.dat ... r7.dat and would go on showing the old ones.
        \\
        \\Pictures and animations are read from the folder in the registry value
        \\HKLM\SOFTWARE\Metropolis\G17 "src" (GOG sets it to the game folder). If it
        \\points elsewhere, copy the dat folder there too.
        \\
        \\Files:
        \\
    );
    for (files) |rel| {
        try readme.appendSlice(gpa, "  ");
        for (rel) |ch| try readme.append(gpa, if (ch == '/') '\\' else ch);
        try readme.appendSlice(gpa, "\r\n");
    }
    // Windows line ends: the readme and the batch file are for the original's machine.
    const text = try std.mem.replaceOwned(u8, gpa, readme.items, "\n", "\r\n");
    defer gpa.free(text);
    const fixed = try std.mem.replaceOwned(u8, gpa, text, "\r\r\n", "\r\n");
    defer gpa.free(fixed);
    try out.writeFile(io, .{ .sub_path = "README.txt", .data = fixed });
    try out.writeFile(io, .{ .sub_path = "clear-cache.bat", .data = "@echo off\r\ncd /d \"%~dp0\"\r\nfor %%i in (1 2 3 4 5 6 7) do if exist dat\\r%%i.dat del dat\\r%%i.dat\r\necho Level picture cache cleared.\r\npause\r\n" });
    return files;
}

test "changed: new and edited files, not equal ones, not the cache" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = tmp.dir;
    for ([_][]const u8{ "orig/dat/common", "mod/dat/common", "mod/avi" }) |p| try root.createDirPath(io, p);
    try root.writeFile(io, .{ .sub_path = "orig/dat/common/other.dat", .data = "a" });
    try root.writeFile(io, .{ .sub_path = "mod/dat/common/other.dat", .data = "b" });
    try root.writeFile(io, .{ .sub_path = "orig/dat/common/lang.dat", .data = "same" });
    try root.writeFile(io, .{ .sub_path = "mod/dat/common/lang.dat", .data = "same" });
    try root.writeFile(io, .{ .sub_path = "mod/dat/r1.dat", .data = "cache" });
    try root.writeFile(io, .{ .sub_path = "mod/dat/common/sprite.kdt", .data = "converted" });
    try root.writeFile(io, .{ .sub_path = "mod/avi/clip.asf", .data = "v" });
    try root.writeFile(io, .{ .sub_path = "orig/adjust.kdt", .data = "a" });
    try root.writeFile(io, .{ .sub_path = "mod/adjust.kdt", .data = "b" });
    var orig = try root.openDir(io, "orig", .{});
    defer orig.close(io);
    var mod = try root.openDir(io, "mod", .{});
    defer mod.close(io);
    const files = try changed(io, gpa, mod, orig);
    defer freeList(gpa, files);
    try std.testing.expectEqual(3, files.len);
    try std.testing.expectEqualStrings("adjust.kdt", files[0]);
    try std.testing.expectEqualStrings("avi/clip.asf", files[1]);
    try std.testing.expectEqualStrings("dat/common/other.dat", files[2]);
}

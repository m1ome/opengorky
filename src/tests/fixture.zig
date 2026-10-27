//! Test fixture: a tiny game directory (`dat/`) in a temp dir — archives with
//! hand-written scripts, no real game files. Used by the integration tests here.

const std = @import("std");
const Io = std.Io;
const battle_dir = @import("../battle.zig");
const Battle = battle_dir.battle.Battle;
const Fighter = battle_dir.fighter.Fighter;
const Side = battle_dir.fighter.Side;

const File = struct { []const u8, []const u8 };

/// Archive in the game's format: 32-byte header with
/// the entry count, 128-byte entries (offset, size, filetime, name), then data.
fn archiveBytes(gpa: std.mem.Allocator, files: []const File) ![]u8 {
    var size: usize = 32 + files.len * 128;
    for (files) |f| size += f[1].len;
    const buf = try gpa.alloc(u8, size);
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], @intCast(files.len), .little);
    var off: usize = 32 + files.len * 128;
    for (files, 0..) |f, i| {
        const e = buf[32 + i * 128 ..][0..128];
        std.mem.writeInt(u32, e[0..4], @intCast(off), .little);
        std.mem.writeInt(u32, e[4..8], @intCast(f[1].len), .little);
        @memcpy(e[16..][0..f[0].len], f[0]);
        @memcpy(buf[off..][0..f[1].len], f[1]);
        off += f[1].len;
    }
    return buf;
}

pub fn writeArchive(dir: Io.Dir, path: []const u8, files: []const File) !void {
    const io = std.testing.io;
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(io, d);
    const bytes = try archiveBytes(std.testing.allocator, files);
    defer std.testing.allocator.free(bytes);
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// Common archives: hero Sullivan (`gamestart\`), the CombatLevel base class, scene `move`.
pub fn writeCommon(dir: Io.Dir) !void {
    try writeArchive(dir, "common/other.dat", &.{
        .{ "gamestart\\Sullivan.hro", "int hp; int nameID; int avoidEnumerate;\nfunction init() { hp = 100; };" },
        .{ "classes\\combatlevel.s", "string backLevel;" },
        .{ "classes\\vest.s", "int nameID; int place; string Owner;\nfunction init() { nameID = 77; };" },
        // A scene that moves to 01_b (LOADLEVEL) and continues there.
        .{ "scriptlets\\move.scr", "LOADLEVEL(\"01_b\")\nFADE_OUT()\n" },
        // Mod-only scene commands (no shipped scene uses them).
        .{ "scriptlets\\modcmds.scr", "IDLE_OFF(\"Sullivan\")\nZOOM(250,10)\nGUI_GAMEOVER()\nDELAY(5)\n" },
    });
    try writeArchive(dir, "common/lang.dat", &.{});
}

/// Location `name` with one level script `<name>.lev`.
pub fn writeLevel(dir: Io.Dir, name: []const u8, script: []const u8) !void {
    var pb: [64]u8 = undefined;
    var nb: [64]u8 = undefined;
    try writeArchive(dir, try std.fmt.bufPrint(&pb, "{s}/other.dat", .{name}), &.{.{ try std.fmt.bufPrint(&nb, "{s}.lev", .{name}), script }});
    try writeArchive(dir, try std.fmt.bufPrint(&pb, "{s}/sprite.dat", .{name}), &.{});
}

/// Battle without a level for rule tests: bare objects without game files.
pub const TestBattle = struct {
    const runtime = @import("../script.zig").runtime;
    rt: runtime.Runtime,
    cls: @import("../script.zig").object.Class = .{ .name = "t.ftr", .parent = null },
    b: Battle = .{ .gpa = std.testing.allocator, .blocked = &.{}, .occupant = &.{}, .reach_left = &.{}, .fire = &.{}, .gas = &.{}, .width = 0, .height = 0 },

    pub fn init() TestBattle {
        return .{ .rt = .init(std.testing.allocator, .{ .ctx = undefined, .fetch = undefined }) };
    }
    pub fn deinit(self: *TestBattle) void {
        self.b.fighters.deinit(std.testing.allocator);
        self.b.bombs.deinit(std.testing.allocator);
        self.rt.deinit();
    }
    pub fn add(self: *TestBattle, side: Side, dead: bool) !*Fighter {
        const o = try self.rt.createObject("f", &self.cls);
        try self.b.fighters.append(std.testing.allocator, .{ .obj = o, .side = side, .tile = .{ 0, 0 }, .size = 1, .dead = dead });
        return &self.b.fighters.items[self.b.fighters.items.len - 1];
    }
};

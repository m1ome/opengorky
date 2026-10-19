//! Mods (not in the exe): directories of scripts over the game archives.
//! Sources are looked up in mods first, `<mod>/<location>/<name>` then `<mod>/<name>`.
//! Location objects (`.ftr`, `.wpn`, `.act`, …) in `<mod>/<location>/` are created with
//! the archive's. Custom fighters use the generic class (`classType = 100`,
//! battle/generic.zig).

const std = @import("std");
const Io = std.Io;
const world = @import("../state.zig").world;
const World = world.World;

/// Mod directories set at startup (`<game>/mods`, data dir); empty = no mods.
/// Process-wide setting.
pub var dirs: [2]?Io.Dir = .{ null, null };

fn any() bool {
    return dirs[0] != null or dirs[1] != null;
}

/// Mod file `name` (`<location>/name` then `name`; as given and lowercase), in the world arena.
pub fn read(self: *World, name: []const u8) ?[]const u8 {
    if (!any()) return null;
    var low_buf: [256]u8 = undefined;
    if (name.len > low_buf.len) return null;
    const low = std.ascii.lowerString(&low_buf, name);
    var path_buf: [512]u8 = undefined;
    const a = self.arena_state.allocator();
    for (dirs) |dir_opt| {
        const dir = dir_opt orelse continue;
        for ([_]?[]const u8{ self.level_name, null }) |sub| {
            for ([_][]const u8{ name, low }) |n| {
                const path = if (sub) |s| std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ s, n }) catch continue else n;
                if (dir.readFileAlloc(self.io, path, a, .limited(1 << 20))) |text| return text else |_| {}
            }
        }
    }
    return null;
}

/// Location objects from `<mod>/<location>/`: creates those missing from the archive;
/// same-named archive objects already exist and `read` swaps their sources.
pub fn createLevelObjects(self: *World) !void {
    for (dirs) |dir_opt| {
        const dir = dir_opt orelse continue;
        var sub = dir.openDir(self.io, self.level_name, .{ .iterate = true }) catch continue;
        defer sub.close(self.io);
        var it = sub.iterate();
        while (it.next(self.io) catch null) |e| {
            if (e.kind != .file) continue;
            const stem = e.name[0 .. e.name.len - std.fs.path.extension(e.name).len];
            if (self.rt.findObject(stem) != null) continue;
            _ = try self.addScriptObject(e.name);
        }
    }
}

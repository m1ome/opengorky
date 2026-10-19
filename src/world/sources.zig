//! Location script sources: level archive, mods, the common archive, and classes brought
//! from other locations (`extra_sources`).

const std = @import("std");
const World = @import("../state.zig").world.World;
const archive = @import("../formats.zig").archive;
const mods = @import("mods.zig");

/// Script source lookup: extra sources, mods, the level archive, then `common/other.dat`
/// `classes\`, `scriptlets\`, `gamestart\`.
pub fn fetchSource(ctx: *anyopaque, name: []const u8) anyerror!?[]const u8 {
    const self: *World = @ptrCast(@alignCast(ctx));
    const a = self.arena_state.allocator();
    if (self.res.extra_sources.get(name)) |src| return src;
    if (mods.read(self, name)) |src| return src;
    if (self.res.other.find(name)) |e| return try self.res.other.readAlloc(self.io, a, e);
    var buf: [archive.name_size]u8 = undefined;
    const in_classes = try std.fmt.bufPrint(&buf, "classes\\{s}", .{name});
    if (self.res.common.find(in_classes)) |e| return try self.res.common.readAlloc(self.io, a, e);
    const in_scriptlets = try std.fmt.bufPrint(&buf, "scriptlets\\{s}", .{name});
    if (self.res.common.find(in_scriptlets)) |e| return try self.res.common.readAlloc(self.io, a, e);
    const in_gamestart = try std.fmt.bufPrint(&buf, "gamestart\\{s}", .{name});
    if (self.res.common.find(in_gamestart)) |e| return try self.res.common.readAlloc(self.io, a, e);
    return null;
}

/// Script source from this location's archive (to carry a class elsewhere).
pub fn localSource(self: *World, name: []const u8) ?[]const u8 {
    // A class the party brought from another location isn't in common either.
    if (self.res.extra_sources.get(name)) |src| return src;
    const e = self.res.other.find(name) orelse return null;
    return self.res.other.readAlloc(self.io, self.arena_state.allocator(), e) catch null;
}

/// Class of an item picked up elsewhere (`gloves.itm`, the matrix, notes): source from that
/// location's `other.dat`. Exe objects are global; our saves only keep the class name.
pub fn addForeignSource(self: *World, name: []const u8) !bool {
    var it = self.res.dat.iterate();
    while (try it.next(self.io)) |d| {
        if (d.kind != .directory) continue;
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/other.dat", .{d.name}) catch continue;
        var ar = archive.Archive.open(self.io, self.gpa, self.res.dat, path) catch continue;
        defer ar.close(self.io, self.gpa);
        const e = ar.find(name) orelse continue;
        const src = try ar.readAlloc(self.io, self.arena_state.allocator(), e);
        try addSource(self, name, src);
        return true;
    }
    return false;
}

/// Add a script source (name case-insensitive).
pub fn addSource(self: *World, name: []const u8, src: []const u8) !void {
    const a = self.arena_state.allocator();
    try self.res.extra_sources.put(a, try a.dupe(u8, name), try a.dupe(u8, src));
}

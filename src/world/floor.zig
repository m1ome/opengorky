//! Location floor: floor grid (`.wm`, `.wm2`), cell height under a background point,
//! world point on the floor, heights of cells opened by `WALKAREA`.

const std = @import("std");
const level_files = @import("../formats.zig").level_files;
const nav = @import("nav.zig");
const World = @import("../state.zig").world.World;

/// Floor point under a background pixel on floor `map` (0 `.wm`, 1 `.wm2`); height 0
/// without a grid.
pub fn groundOn(self: *World, map: u1, bg: [2]f32) [3]f32 {
    const m = floorMap(self, map) orelse return self.cam.unproject(bg[0], bg[1], 0);
    return groundPoint(self, m, bg);
}

pub fn groundAt(self: *World, bg: [2]f32) [3]f32 {
    return groundOn(self, 0, bg);
}

/// Floor grid: the exe reads `[0x6b4c68 + 4·floor]` (0x427800, 0x422c06), null without
/// `.wm2` (0x481b81), which party walking would dereference. Deviation: without `.wm2`
/// floor 1 uses `.wm` like a single-floor location.
pub fn floorMap(self: *const World, map: u1) ?level_files.WalkMap {
    return if (map == 1) self.walk_map2 orelse self.walk_map else self.walk_map;
}

/// Height of the walkable cell under a background point; null if blocked or off-grid.
pub fn cellHeight(m: level_files.WalkMap, bg: [2]f32) ?f32 {
    const c = nav.cellAt(m, nav.cellOf(bg)) orelse return null;
    return if (!c.walkable()) null else @floatFromInt(c.height);
}

/// Height of any cell under a background point (blocked too); 0 off-grid.
pub fn floorHeight(m: level_files.WalkMap, bg: [2]f32) f32 {
    const c = nav.cellAt(m, nav.cellOf(bg)) orelse return 0;
    return @floatFromInt(c.height);
}

/// World point under a background pixel on grid `m` (cell height).
pub fn groundPoint(self: *World, m: level_files.WalkMap, bg: [2]f32) [3]f32 {
    return self.cam.unproject(bg[0], bg[1], floorHeight(m, bg));
}

/// Heights for cells an area opened that have none in `.wm` (0): the most common height of
/// walkable neighbours, or 0 if any neighbour is floor at 0. Deviation (0x479990 changes
/// only bits): in the lab `WALKAREA("ciuch_blokada")` opens cell 65,89 at height 0 between
/// the platform (304) and the rails (327); the hero dropped under the bridge for a step.
pub fn fillHoleHeights(m: level_files.WalkMap, holes: []const usize) void {
    const w: isize = @intCast(m.width);
    const n: isize = @intCast(m.cells.len);
    for (holes) |i| {
        var hs: [8]i16 = undefined;
        var k: usize = 0;
        var ground = false;
        const x: isize = @mod(@as(isize, @intCast(i)), w);
        var dy: isize = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: isize = -1;
            while (dx <= 1) : (dx += 1) {
                if (dx == 0 and dy == 0) continue;
                if (x + dx < 0 or x + dx >= w) continue;
                const j = @as(isize, @intCast(i)) + dy * w + dx;
                if (j < 0 or j >= n) continue;
                const ju: usize = @intCast(j);
                if (!m.cells[ju].walkable() or std.mem.indexOfScalar(usize, holes, ju) != null) continue;
                if (m.cells[ju].height == 0) ground = true;
                hs[k] = m.cells[ju].height;
                k += 1;
            }
        }
        if (ground or k == 0) continue;
        var best = hs[0];
        var best_n: usize = 0;
        for (hs[0..k]) |h| {
            const c = std.mem.count(i16, hs[0..k], &.{h});
            if (c > best_n) {
                best = h;
                best_n = c;
            }
        }
        m.cells[i].height = best;
    }
}

test "floor 1 without .wm2 uses .wm like a single-floor location" {
    var c0 = [_]level_files.WalkMap.Cell{.{ .kind = 1, .height = 0 }};
    var c1 = [_]level_files.WalkMap.Cell{.{ .kind = 1, .height = 7 }};
    var w: World = undefined;
    w.walk_map = .{ .width = 1, .height = 1, .cells = &c0 };
    w.walk_map2 = null;
    try std.testing.expectEqual(@as(usize, 1), floorMap(&w, @as(u1, 1)).?.cells.len);
    try std.testing.expect(floorMap(&w, @as(u1, 1)).?.cells.ptr == &c0);
    w.walk_map2 = .{ .width = 1, .height = 1, .cells = &c1 };
    try std.testing.expect(floorMap(&w, @as(u1, 1)).?.cells.ptr == &c1);
    try std.testing.expect(floorMap(&w, @as(i32, 0)).?.cells.ptr == &c0);
}

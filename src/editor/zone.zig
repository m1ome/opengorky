//! A weapon class's damage zone on the entry pages: the exe's reach pattern
//! (battle/patterns.zig) as tiles around the shooter, as battle/grid.zig targets()
//! reads it on an open field.

const std = @import("std");
const Allocator = std.mem.Allocator;
const patterns = @import("opengorky").battle.patterns;

pub const Cell = struct {
    /// Best damage percent of the ray entries reaching the tile.
    pct: u8 = 0,
    /// Hit tile set (Weapon.effects index) of the first entry reaching it.
    effect: u8 = 0,
    /// Reached only along a ray: an obstacle on a tile before it cuts it.
    chain: bool = false,
    /// Only the second tile of a wide ray (2×2 fighters): struck, not aimed at.
    side: bool = false,
};

const Zone = struct {
    cells: std.AutoArrayHashMapUnmanaged([2]i32, Cell) = .empty,
    /// Bounds of the cells and the shooter.
    lo: [2]i32 = .{ 0, 0 },
    hi: [2]i32 = .{ 0, 0 },
    /// The shooter's side in tiles from (0, 0).
    size: i32 = 1,
    /// Hit tile sets the rays use.
    used: [4]bool = @splat(false),
};

pub fn build(a: Allocator, w: *const patterns.Weapon) !Zone {
    var z: Zone = .{};
    var side: [2]i32 = .{ 0, 0 };
    for (w.rays) |r| {
        switch (r.kind) {
            .side_x => side = .{ 1, 0 },
            .side_y => side = .{ 0, 1 },
            .start, .chain => {
                const t: [2]i32 = .{ r.dx, r.dy };
                try put(a, &z, t, .{ .pct = r.pct, .effect = r.effect, .chain = r.kind == .chain });
                if (w.wide and (side[0] != 0 or side[1] != 0)) try put(a, &z, .{ t[0] + side[0], t[1] + side[1] }, .{ .pct = r.pct, .effect = r.effect, .chain = r.kind == .chain, .side = true });
                if (r.effect < z.used.len) z.used[r.effect] = true;
            },
        }
    }
    // shortcut: the pattern does not name the shooter's size; a wide ray's, or rays
    // starting a tile off (wp_incubus' 1008), are a 2×2 fighter's. Upgrade if a
    // pattern of a 1×1 fighter ever skips its neighbours.
    const near = [_][2]i32{ .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } };
    var touches = false;
    for (near) |t| touches = touches or z.cells.contains(t);
    if (w.wide or (z.cells.count() > 0 and !touches and (z.cells.contains(.{ 2, 0 }) or z.cells.contains(.{ 0, 2 })))) z.size = 2;
    z.hi = .{ @max(z.hi[0], z.size - 1), @max(z.hi[1], z.size - 1) };
    return z;
}

/// Tile `t` reached by entry `c`: a start beats a chain and an aim a side tile there;
/// the first entry's hit set stays.
fn put(a: Allocator, z: *Zone, t: [2]i32, c: Cell) !void {
    const g = try z.cells.getOrPut(a, t);
    if (!g.found_existing) {
        g.value_ptr.* = c;
        z.lo = .{ @min(z.lo[0], t[0]), @min(z.lo[1], t[1]) };
        z.hi = .{ @max(z.hi[0], t[0]), @max(z.hi[1], t[1]) };
        return;
    }
    const v = g.value_ptr;
    v.pct = @max(v.pct, c.pct);
    v.chain = v.chain and c.chain;
    v.side = v.side and c.side;
}

/// Bounds of hit set `set` around the target (0, 0).
pub fn setBounds(set: []const [2]i8) [2][2]i32 {
    var b: [2][2]i32 = .{ .{ 0, 0 }, .{ 0, 0 } };
    for (set) |d| for (0..2) |k| {
        b[0][k] = @min(b[0][k], d[k]);
        b[1][k] = @max(b[1][k], d[k]);
    };
    return b;
}

test build {
    const a = std.testing.allocator;
    // Pistol (1): four rays, 100 % near, 25 % at 6 tiles; past the first tile chained.
    var p = try build(a, patterns.find(1).?);
    defer p.cells.deinit(a);
    try std.testing.expectEqual(1, p.size);
    try std.testing.expectEqual(Cell{ .pct = 100 }, p.cells.get(.{ 1, 0 }).?);
    try std.testing.expectEqual(Cell{ .pct = 25, .chain = true }, p.cells.get(.{ 0, -6 }).?);
    try std.testing.expect(p.cells.get(.{ 1, 1 }) == null);
    try std.testing.expectEqual([2]i32{ -6, -6 }, p.lo);
    // Flamethrower (4): a hit set per side.
    var f = try build(a, patterns.find(4).?);
    defer f.cells.deinit(a);
    try std.testing.expectEqual(3, f.cells.get(.{ 0, -1 }).?.effect);
    try std.testing.expectEqual([4]bool{ true, true, true, true }, f.used);
    // A 2×2 fighter's wide rays (102): the side tile after a marker, the shooter 2×2.
    var w = try build(a, patterns.find(102).?);
    defer w.cells.deinit(a);
    try std.testing.expectEqual(2, w.size);
    try std.testing.expect(!w.cells.get(.{ 0, -1 }).?.side);
    try std.testing.expect(w.cells.get(.{ 1, -1 }).?.side);
    try std.testing.expectEqual(1, w.cells.get(.{ 2, 0 }).?.effect);
    // wp_incubus (1008): not wide, but its rays start past a 2×2 body.
    var inc = try build(a, patterns.find(1008).?);
    defer inc.cells.deinit(a);
    try std.testing.expectEqual(2, inc.size);
    try std.testing.expectEqual([2][2]i32{ .{ -1, -1 }, .{ 1, 1 } }, setBounds(patterns.find(17).?.effects[0]));
}

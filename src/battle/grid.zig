//! Battle grid: obstacles and fighters, walk budget (0x494cb0), hero click path
//! (0x494810), aim and hit tiles from the weapon pattern (0x4ce3f0, 0x4ce7b0),
//! AI wave to a target (0x49a630). Pure functions over the grid.

const std = @import("std");
const patterns = @import("patterns.zig");
const WeaponClass = @import("weapon_class.zig").WeaponClass;

pub const Tile = [2]i32;

/// Row-major cell index of an in-grid tile.
pub fn tileIndex(width: usize, t: Tile) usize {
    return @as(usize, @intCast(t[1])) * width + @as(usize, @intCast(t[0]));
}

/// Battle grid: `.cm` obstacles and tile occupancy by fighters.
pub const Grid = struct {
    width: u32,
    height: u32,
    /// Obstacle (`O` in `.cm`): can't stand on it or shoot through it.
    blocked: []const bool,
    /// Fighter index on the tile, or `none`.
    occupant: []u16,

    pub const none = std.math.maxInt(u16);

    pub fn inside(self: Grid, t: Tile) bool {
        return t[0] >= 0 and t[1] >= 0 and t[0] < self.width and t[1] < self.height;
    }

    fn index(self: Grid, t: Tile) usize {
        return tileIndex(self.width, t);
    }

    /// Tile inside the grid and not an obstacle (tile bit 0 at 0x4ce515).
    pub fn open(self: Grid, t: Tile) bool {
        return self.inside(t) and !self.blocked[self.index(t)];
    }

    pub fn at(self: Grid, t: Tile) u16 {
        return if (self.inside(t)) self.occupant[self.index(t)] else none;
    }

    /// Whether fighter `who` of size `size`×`size` can stand with its corner on `t`.
    pub fn fits(self: Grid, t: Tile, size: u32, who: u16) bool {
        for (0..size) |dy| for (0..size) |dx| {
            const c: Tile = .{ t[0] + @as(i32, @intCast(dx)), t[1] + @as(i32, @intCast(dy)) };
            if (!self.open(c)) return false;
            const o = self.at(c);
            if (o != none and o != who) return false;
        };
        return true;
    }

    pub fn place(self: Grid, t: Tile, size: u32, who: u16) void {
        self.mark(t, size, who);
    }

    pub fn remove(self: Grid, t: Tile, size: u32) void {
        self.mark(t, size, none);
    }

    fn mark(self: Grid, t: Tile, size: u32, v: u16) void {
        for (0..size) |dy| for (0..size) |dx| {
            const c: Tile = .{ t[0] + @as(i32, @intCast(dx)), t[1] + @as(i32, @intCast(dy)) };
            if (self.inside(c)) self.occupant[self.index(c)] = v;
        };
    }
};

/// Step cost (0x494cb0): straight 1, diagonal 1.51 (qword 0x50a3d0; the reach
/// fill computes in float, hence `@floatCast`).
const diagonal_cost: f64 = 1.51;

/// Tiles the fighter can reach with walk budget `budget` (0x494cb0): an 8-way
/// fill, a tile is reachable if the budget along the path stays ≥ 0. Returns the
/// remaining budget per tile (`-1` = unreachable); the start tile is reachable.
pub fn reach(grid: Grid, out: []f32, start: Tile, size: u32, who: u16, budget: f32) void {
    reachCost(grid, out, start, size, who, budget, @floatCast(diagonal_cost));
}

/// Diagonal for AI and the enemy walk preview (0x498ed0, 0x49ac20): 1.5 (0x508780).
pub const diagonal_cost_ai: f32 = 1.5;

/// Same with a given diagonal cost.
pub fn reachCost(grid: Grid, out: []f32, start: Tile, size: u32, who: u16, budget: f32, diag: f32) void {
    @memset(out, -1);
    if (!grid.inside(start) or budget < 0) return;
    out[grid.index(start)] = budget;
    // Best remainder per tile; repeat while anything improves (grids are small).
    var changed = true;
    while (changed) {
        changed = false;
        for (0..grid.height) |y| for (0..grid.width) |x| {
            const here = out[y * grid.width + x];
            if (here < 0) continue;
            for (neighbours) |d| {
                const t: Tile = .{ @as(i32, @intCast(x)) + d[0], @as(i32, @intCast(y)) + d[1] };
                const cost: f32 = if (d[0] != 0 and d[1] != 0) diag else 1;
                const left = here - cost;
                if (left < 0 or !grid.inside(t)) continue;
                if (!grid.fits(t, size, who)) continue;
                const i = grid.index(t);
                if (left > out[i] + 1e-4) {
                    out[i] = left;
                    changed = true;
                }
            }
        };
    }
}

const neighbours = [_][2]i32{ .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 }, .{ -1, 0 }, .{ 1, 0 }, .{ -1, 1 }, .{ 0, 1 }, .{ 1, 1 } };

/// Hero click path (0x48f400 → 0x494720): depth-first search 0x494810 from `start`
/// to `goal` with budget `budget`. Neighbours in `neighbours` order, straight step
/// 1 (0x508330), diagonal 1.51 (0x50a3d0), budget as float (fsub qword, fstp dword).
/// A tile is enterable if inside, not an obstacle, without a fighter (flag 1 in
/// 0x4946a0) and not already on the current path; diagonal corners aren't checked.
/// A branch stops when the budget < 0 or not better than the best; the first path
/// with the largest remainder wins. The goal is checked too (0x4947b0). The path
/// includes the start tile; null = no path (+0x6f0 = −1).
pub fn walkPath(grid: Grid, start: Tile, goal: Tile, budget: f32, buf: []Tile) ?struct { path: []Tile, left: f32 } {
    if (!grid.inside(start) or !grid.inside(goal)) return null;
    var visited: [max_cells]bool = undefined;
    const n = @as(usize, grid.width) * grid.height;
    if (n > max_cells) return null;
    @memset(visited[0..n], false);
    var s: Search = .{ .grid = grid, .goal = goal, .visited = visited[0..n], .cur = buf, .best = buf };
    // The path is copied into `best` on every improvement, hence a second buffer.
    var cur: [100]Tile = undefined;
    s.cur = &cur;
    if (!s.passable(goal)) return null;
    s.dfs(0, start, budget);
    if (s.best_left < 0) return null;
    return .{ .path = buf[0..s.best_len], .left = s.best_left };
}

/// The largest grid in the data is 28×35 (`05__lab_incubus`).
const max_cells = 2048;

const Search = struct {
    grid: Grid,
    goal: Tile,
    visited: []bool,
    cur: []Tile,
    best: []Tile,
    best_len: usize = 0,
    best_left: f32 = -1,

    fn passable(self: *Search, t: Tile) bool {
        if (!self.grid.open(t)) return false;
        if (self.grid.at(t) != Grid.none) return false;
        return !self.visited[self.grid.index(t)];
    }

    fn dfs(self: *Search, i: usize, t: Tile, left: f32) void {
        if (left < 0 or left <= self.best_left) return;
        if (i >= self.cur.len or i >= self.best.len) return;
        const k = self.grid.index(t);
        self.visited[k] = true;
        defer self.visited[k] = false;
        self.cur[i] = t;
        if (t[0] == self.goal[0] and t[1] == self.goal[1]) {
            @memcpy(self.best[0 .. i + 1], self.cur[0 .. i + 1]);
            self.best_len = i + 1;
            self.best_left = left;
            return;
        }
        for (neighbours) |d| {
            const nt: Tile = .{ t[0] + d[0], t[1] + d[1] };
            if (!self.passable(nt)) continue;
            const cost: f64 = if (d[0] != 0 and d[1] != 0) diagonal_cost else 1.0;
            self.dfs(i + 1, nt, @floatCast(@as(f64, left) - cost));
        }
    }
};

/// Tile that can be struck.
pub const Target = struct {
    tile: Tile,
    /// Hit tile set index.
    effect: u8,
    /// Damage percent at this range.
    pct: u8,
};

/// Aim tiles of a weapon from tile `from` (0x4ce3f0). A ray stops at an obstacle
/// or the grid edge; with `stop_at_fighter` also at the first fighter (except the
/// shooter `who`).
///
/// A wide ray (2×2 fighters) is a two-tile band: the ray tile and its neighbour on
/// the side of the last marker (before any marker there's no side, one tile).
/// Only the ray tile is an aim; striking it covers both (the hit set is relative
/// to it); the neighbour is added only with `with_side`, for highlighting the area
/// (wrapper 0x4ce3c0); aims are searched without it (0x4ce710).
pub fn targets(grid: Grid, w: *const patterns.Weapon, from: Tile, who: u16, stop_at_fighter: bool, with_side: bool, out: []Target) []Target {
    var n: usize = 0;
    // Satellite (class 8: laser 1038, lightning 1039, rocket 1040): tile check
    // +0x104 = 0x4b8e90 is always 0, so any tile of the field, 100 % (+0x108 =
    // 0x4b8ea0); the hit area is 7×7 around it.
    if (WeaponClass.from(w.class) == .satellite) {
        var y: i32 = 0;
        while (y < grid.height) : (y += 1) {
            var x: i32 = 0;
            while (x < grid.width) : (x += 1) {
                const t: Tile = .{ x, y };
                if (!grid.open(t) or n == out.len) continue;
                out[n] = .{ .tile = t, .effect = 0, .pct = 100 };
                n += 1;
            }
        }
        return out[0..n];
    }
    // Time bomb (class 9, +0x100 = 0x4b9200): placed on a neighbouring tile (below,
    // above, right, left) that is walkable and free, 100 %.
    if (WeaponClass.from(w.class) == .time_bomb) {
        for ([_]Tile{ .{ 0, 1 }, .{ 0, -1 }, .{ 1, 0 }, .{ -1, 0 } }) |d| {
            const t: Tile = .{ from[0] + d[0], from[1] + d[1] };
            if (!grid.open(t) or grid.at(t) != Grid.none or n == out.len) continue;
            out[n] = .{ .tile = t, .effect = 0, .pct = 100 };
            n += 1;
        }
        return out[0..n];
    }
    var cut = false;
    var side: Tile = .{ 0, 0 };
    for (w.rays) |r| {
        switch (r.kind) {
            .side_x => {
                side = .{ 1, 0 };
                continue;
            },
            .side_y => {
                side = .{ 0, 1 };
                continue;
            },
            .start => cut = false,
            .chain => if (cut) continue,
        }
        const t: Tile = .{ from[0] + r.dx, from[1] + r.dy };
        if (!grid.open(t)) {
            cut = true;
            continue;
        }
        var hit = occupiedByOther(grid, t, who);
        const t2: Tile = .{ t[0] + side[0], t[1] + side[1] };
        if (w.wide) {
            // Wide ray: the second tile next to it must be free too.
            if (!grid.open(t2)) {
                cut = true;
                continue;
            }
            hit = hit or occupiedByOther(grid, t2, who);
        }
        if (n < out.len) {
            out[n] = .{ .tile = t, .effect = r.effect, .pct = r.pct };
            n += 1;
        }
        // Without a side marker the second tile equals the first (the exe adds it twice).
        if (w.wide and with_side and (side[0] != 0 or side[1] != 0) and n < out.len) {
            out[n] = .{ .tile = t2, .effect = r.effect, .pct = r.pct };
            n += 1;
        }
        if (stop_at_fighter and hit) cut = true;
    }
    return out[0..n];
}

fn occupiedByOther(grid: Grid, t: Tile, who: u16) bool {
    const o = grid.at(t);
    return o != Grid.none and o != who;
}

/// Hit tiles of a strike on `target` (0x4ce7b0): the set from the ray entry that
/// hit this tile, shifted onto it; open tiles only.
pub fn effectTiles(grid: Grid, w: *const patterns.Weapon, aim: Target, out: []Tile) []Tile {
    var n: usize = 0;
    if (aim.effect >= w.effects.len) return out[0..0];
    for (w.effects[aim.effect]) |d| {
        const t: Tile = .{ aim.tile[0] + d[0], aim.tile[1] + d[1] };
        if (!grid.open(t) or n == out.len) continue;
        out[n] = t;
        n += 1;
    }
    return out[0..n];
}

pub const QEntry = struct { t: Tile, cost: f32 };

/// Wave 0x49a630 on grid `g`: buffers `visited` (one per grid tile) and `queue`
/// (≥ 8 × tiles + 1) come from the caller.
pub fn waveLen(g: Grid, visited: []u8, queue: []QEntry, size: u32, from: Tile, to: Tile) f32 {
    const span: i32 = @as(i32, @intCast(size)) - 1;
    @memset(visited, 0);
    queue[0] = .{ .t = from, .cost = 0 };
    var n: usize = 1;
    var i: usize = 0;
    const order = [8]struct { d: Tile, cost: f32 }{
        .{ .d = .{ 0, -1 }, .cost = 1 },                 .{ .d = .{ 1, 0 }, .cost = 1 },
        .{ .d = .{ 0, 1 }, .cost = 1 },                  .{ .d = .{ -1, 0 }, .cost = 1 },
        .{ .d = .{ -1, -1 }, .cost = diagonal_cost_ai }, .{ .d = .{ 1, -1 }, .cost = diagonal_cost_ai },
        .{ .d = .{ 1, 1 }, .cost = diagonal_cost_ai },   .{ .d = .{ -1, 1 }, .cost = diagonal_cost_ai },
    };
    while (i < n) : (i += 1) {
        const e = queue[i];
        const k = @as(usize, @intCast(e.t[1])) * g.width + @as(usize, @intCast(e.t[0]));
        if (visited[k] != 0) continue;
        if (to[0] >= e.t[0] - 1 and to[0] <= e.t[0] + span + 1 and to[1] >= e.t[1] - 1 and to[1] <= e.t[1] + span + 1) return e.cost;
        for (order) |o| {
            const nt: Tile = .{ e.t[0] + o.d[0], e.t[1] + o.d[1] };
            if (!stepFree(g, e.t, nt, size) or n == queue.len) continue;
            queue[n] = .{ .t = nt, .cost = e.cost + o.cost };
            n += 1;
        }
        visited[k] = 1;
    }
    return -1;
}

/// 0x49a110/0x49a0a0: a step of a fighter of `size` from `t` to `nt`: every tile
/// it enters is free (inside the field, walkable, no fighter of any side).
fn stepFree(g: Grid, t: Tile, nt: Tile, size: u32) bool {
    const sz: i32 = @intCast(size);
    var dy: i32 = 0;
    while (dy < sz) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < sz) : (dx += 1) {
            const c: Tile = .{ nt[0] + dx, nt[1] + dy };
            if (c[0] >= t[0] and c[0] < t[0] + sz and c[1] >= t[1] and c[1] < t[1] + sz) continue;
            if (!g.inside(c) or !g.open(c) or g.at(c) != Grid.none) return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------- tests

fn testGrid(comptime rows: []const []const u8, occ: []u16, blocked: []bool) Grid {
    for (rows, 0..) |row, y| for (row, 0..) |ch, x| {
        blocked[y * row.len + x] = ch == 'O';
    };
    @memset(occ, Grid.none);
    return .{ .width = @intCast(rows[0].len), .height = @intCast(rows.len), .blocked = blocked, .occupant = occ };
}

test "reach: a diagonal costs more than a straight step" {
    var occ: [25]u16 = undefined;
    var blk: [25]bool = undefined;
    const g = testGrid(&.{ ".....", ".....", ".....", ".....", "....." }, &occ, &blk);
    var left: [25]f32 = undefined;
    reach(g, &left, .{ 0, 0 }, 1, 0, 3);
    try std.testing.expect(left[0 * 5 + 3] >= 0); // three steps right
    try std.testing.expect(left[1 * 5 + 2] >= 0); // diagonal + straight: 2.51
    try std.testing.expect(left[2 * 5 + 2] < 0); // two diagonals: 3.02 > 3
}

test "walkPath: the first path in neighbour order with the largest remainder (0x494810)" {
    var occ: [25]u16 = undefined;
    var blk: [25]bool = undefined;
    const g = testGrid(&.{ ".....", ".....", ".....", ".....", "....." }, &occ, &blk);
    g.place(.{ 2, 2 }, 1, 0);
    var buf: [100]Tile = undefined;
    // From the centre two tiles right-down: diagonal + straight = 2.51; straight right
    // (+1, 0) comes before the diagonal (+1, +1) in neighbour order.
    const r = walkPath(g, .{ 2, 2 }, .{ 4, 3 }, 5, &buf).?;
    try std.testing.expectEqual(3, r.path.len);
    try std.testing.expectEqual(Tile{ 3, 2 }, r.path[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 2.49), r.left, 1e-5);
    // An occupied goal or too little budget: no path.
    g.place(.{ 0, 0 }, 1, 3);
    try std.testing.expect(walkPath(g, .{ 2, 2 }, .{ 0, 0 }, 5, &buf) == null);
    try std.testing.expect(walkPath(g, .{ 2, 2 }, .{ 4, 4 }, 3, &buf) == null);
}

test "reach: obstacles and fighters" {
    var occ: [9]u16 = undefined;
    var blk: [9]bool = undefined;
    const g = testGrid(&.{ ".O.", ".O.", "..." }, &occ, &blk);
    g.place(.{ 0, 2 }, 1, 7);
    var left: [9]f32 = undefined;
    reach(g, &left, .{ 0, 0 }, 1, 0, 10);
    try std.testing.expect(left[2] >= 0); // right behind the wall: around from below
    try std.testing.expect(left[1] < 0); // wall
    try std.testing.expect(left[6] < 0); // tile with another fighter
}

test "targets: a pistol ray stops at a fighter and an obstacle" {
    var occ: [8]u16 = undefined;
    var blk: [8]bool = undefined;
    const g = testGrid(&.{"........"}, &occ, &blk);
    g.place(.{ 3, 0 }, 1, 5);
    var buf: [64]Target = undefined;
    const pistol = patterns.find(1).?;
    const t = targets(g, pistol, .{ 0, 0 }, 0, true, false, &buf);
    // Right: tiles 1, 2, 3 (fighter), then the ray stops.
    var last: i32 = 0;
    for (t) |x| last = @max(last, x.tile[0]);
    try std.testing.expectEqual(3, last);
}

test "grenade: any tile in a 7×7 square, through obstacles" {
    var occ: [81]u16 = undefined;
    var blk: [81]bool = undefined;
    const g = testGrid(&.{ ".........", ".........", ".........", "...OOO...", "...O.O...", "...OOO...", ".........", ".........", "........." }, &occ, &blk);
    var buf: [64]Target = undefined;
    const t = targets(g, patterns.find(11).?, .{ 4, 4 }, 0, true, false, &buf);
    // 49 tiles minus 8 taken by the wall.
    try std.testing.expectEqual(41, t.len);
    const rollsToHit = @import("rules.zig").rollsToHit;
    try std.testing.expect(rollsToHit(1) and !rollsToHit(11) and !rollsToHit(10));
}

fn hasTile(ts: []const Tile, t: Tile) bool {
    for (ts) |x| if (x[0] == t[0] and x[1] == t[1]) return true;
    return false;
}

fn findAim(ts: []const Target, t: Tile) ?Target {
    for (ts) |x| if (x.tile[0] == t[0] and x.tile[1] == t[1]) return x;
    return null;
}

test "Garcia's wide chaingun ray (102) from a 2×2 fighter: a band as wide as the fighter" {
    var occ: [144]u16 = undefined;
    var blk: [144]bool = undefined;
    const rows = [_][]const u8{ "............", "............", "............", "............", "............", "............", "............", "............", "............", "............", "............", "............" };
    const g = testGrid(&rows, &occ, &blk);
    // Garcia 2×2 at (5,5)..(6,6), the hero above in column 6, in the band's second tile.
    g.place(.{ 5, 5 }, 2, 1);
    g.place(.{ 6, 2 }, 1, 2);
    const w = patterns.find(102).?;
    var buf: [64]Target = undefined;
    const aims = targets(g, w, .{ 5, 5 }, 1, true, false, &buf);
    // Aims are only ray tiles (column 5 up, row 5 right, etc.).
    try std.testing.expect(findAim(aims, .{ 6, 2 }) == null);
    try std.testing.expect(findAim(aims, .{ 7, 6 }) == null);
    const up = findAim(aims, .{ 5, 2 }).?;
    var eff: [8]Tile = undefined;
    const hit = effectTiles(g, w, up, &eff);
    // Striking up covers both tiles of the fighter's width: (5,2) and (6,2) with the hero.
    try std.testing.expectEqual(2, hit.len);
    try std.testing.expect(hasTile(hit, .{ 5, 2 }) and hasTile(hit, .{ 6, 2 }));
    // The ray stops behind the hero.
    try std.testing.expect(findAim(aims, .{ 5, 1 }) == null);
    // Right: band of rows 5 and 6.
    const right = findAim(aims, .{ 8, 5 }).?;
    const hr = effectTiles(g, w, right, &eff);
    try std.testing.expect(hasTile(hr, .{ 8, 5 }) and hasTile(hr, .{ 8, 6 }) and hr.len == 2);
    // Down (2..6 in y) and left (−1..−5 in x), from the top-left corner.
    try std.testing.expect(findAim(aims, .{ 5, 7 }) != null and findAim(aims, .{ 4, 5 }) != null);
    try std.testing.expect(findAim(aims, .{ 6, 7 }) == null and findAim(aims, .{ 4, 6 }) == null);
    // Area highlight (with_side): both tiles of the band.
    const area = targets(g, w, .{ 5, 5 }, 1, true, true, &buf);
    try std.testing.expect(findAim(area, .{ 6, 2 }) != null and findAim(area, .{ 8, 6 }) != null);
}

test "wide ray: an obstacle in the band's second tile stops the ray" {
    var occ: [64]u16 = undefined;
    var blk: [64]bool = undefined;
    const g = testGrid(&.{ "........", "........", "......O.", "........", "........", "........", "........", "........" }, &occ, &blk);
    g.place(.{ 2, 4 }, 2, 1);
    var buf: [64]Target = undefined;
    // Right from (2,4): rows 4 and 5 are free, the band runs to the edge.
    const aims = targets(g, patterns.find(102).?, .{ 2, 4 }, 1, true, false, &buf);
    try std.testing.expect(findAim(aims, .{ 7, 4 }) != null);
    // Up: columns 2 and 3 are free; obstacle (6,2) doesn't block.
    try std.testing.expect(findAim(aims, .{ 2, 0 }) != null);
    // Move the fighter so wall (6,2) falls into the band's second tile going up.
    g.remove(.{ 2, 4 }, 2);
    g.place(.{ 5, 4 }, 2, 1);
    const a2 = targets(g, patterns.find(102).?, .{ 5, 4 }, 1, true, false, &buf);
    try std.testing.expect(findAim(a2, .{ 5, 3 }) != null);
    try std.testing.expect(findAim(a2, .{ 5, 2 }) == null and findAim(a2, .{ 5, 1 }) == null);
}

test "Garcia's melee (101): tiles around 2×2 without a second tile" {
    var occ: [64]u16 = undefined;
    var blk: [64]bool = undefined;
    const rows = [_][]const u8{ "........", "........", "........", "........", "........", "........", "........", "........" };
    const g = testGrid(&rows, &occ, &blk);
    g.place(.{ 3, 3 }, 2, 1);
    var buf: [64]Target = undefined;
    const w = patterns.find(101).?;
    const aims = targets(g, w, .{ 3, 3 }, 1, true, true, &buf);
    // Eight side neighbours, none of our own and none diagonal.
    try std.testing.expectEqual(8, aims.len);
    for ([_]Tile{ .{ 5, 3 }, .{ 5, 4 }, .{ 2, 3 }, .{ 2, 4 }, .{ 3, 5 }, .{ 4, 5 }, .{ 3, 2 }, .{ 4, 2 } }) |t|
        try std.testing.expect(findAim(aims, t) != null);
    var eff: [8]Tile = undefined;
    const hit = effectTiles(g, w, findAim(aims, .{ 2, 4 }).?, &eff);
    try std.testing.expectEqual(1, hit.len);
}

test "waveLen: wave 0x49a630 returns the first matching tile's cost, allies block" {
    var occ: [35]u16 = undefined;
    var blk: [35]bool = undefined;
    for (&blk) |*v| v.* = false;
    @memset(&occ, Grid.none);
    const g: Grid = .{ .width = 7, .height = 5, .blocked = &blk, .occupant = &occ };
    var visited: [35]u8 = undefined;
    var queue: [8 * 35 + 1]QEntry = undefined;
    // Empty: from (0,2) to the target at (5,2), three straight steps ((4,2) is adjacent).
    g.place(.{ 0, 2 }, 1, 0);
    g.place(.{ 5, 2 }, 1, 1);
    try std.testing.expectEqual(@as(f32, 4), waveLen(g, &visited, &queue, 1, .{ 0, 2 }, .{ 5, 2 }));
    // Target adjacent: 0.
    try std.testing.expectEqual(@as(f32, 0), waveLen(g, &visited, &queue, 1, .{ 4, 3 }, .{ 5, 2 }));
    // A wall of allies along the whole column x = 2: unreachable (−1).
    for (0..5) |y| g.place(.{ 2, @intCast(y) }, 1, 2);
    try std.testing.expectEqual(@as(f32, -1), waveLen(g, &visited, &queue, 1, .{ 0, 2 }, .{ 5, 2 }));
}

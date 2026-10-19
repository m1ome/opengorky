//! Pathfinding on the `.wm` walk grid (8×8 background-pixel cells) like the exe
//! (0x4abdd0 → 0x4ac000, expansion 0x4ac200): a cell is walkable with `kind` bit 0; 8
//! neighbours, corner cutting allowed; an unreachable goal snaps to the nearest walkable
//! cell within 5; `.ap` path transitions use cell marks (bit 1 start, bit 2 end). The route
//! is the centre of every cell, as in 0x426a80.

const std = @import("std");
const value = @import("../script.zig").value;
const num = @import("../num.zig");
const Allocator = std.mem.Allocator;
const WalkMap = @import("../formats.zig").level_files.WalkMap;

const cell: f32 = WalkMap.cell_size;

pub fn walkable(m: WalkMap, x: i32, y: i32) bool {
    return if (cellAt(m, .{ x, y })) |c| c.walkable() else false;
}

/// Cell under a background point; huge script coordinates fall off the map instead of panicking.
pub fn cellOf(p: [2]f32) [2]i32 {
    return .{ @intFromFloat(std.math.clamp(@floor(p[0] / cell), -1e9, 1e9)), @intFromFloat(std.math.clamp(@floor(p[1] / cell), -1e9, 1e9)) };
}

/// Grid cell, or null off the map.
pub fn cellAt(m: WalkMap, c: [2]i32) ?WalkMap.Cell {
    if (c[0] < 0 or c[1] < 0 or c[0] >= m.width or c[1] >= m.height) return null;
    return m.at(@intCast(c[0]), @intCast(c[1]));
}

pub fn center(c: [2]i32) [2]f32 {
    return .{ (num.toF32(c[0]) + 0.5) * cell, (num.toF32(c[1]) + 0.5) * cell };
}

/// Nearest walkable cell (growing squares).
fn nearestWalkable(m: WalkMap, c: [2]i32, max_r: i32) ?[2]i32 {
    if (walkable(m, c[0], c[1])) return c;
    var r: i32 = 1;
    while (r <= max_r) : (r += 1) {
        var best: ?[2]i32 = null;
        var best_d: i32 = std.math.maxInt(i32);
        var dy: i32 = -r;
        while (dy <= r) : (dy += 1) {
            var dx: i32 = -r;
            while (dx <= r) : (dx += 1) {
                if (@max(@abs(dx), @abs(dy)) != r) continue;
                if (!walkable(m, c[0] + dx, c[1] + dy)) continue;
                const d = dx * dx + dy * dy;
                if (d < best_d) {
                    best_d = d;
                    best = .{ c[0] + dx, c[1] + dy };
                }
            }
        }
        if (best) |b| return b;
    }
    return null;
}

/// Whether a walkable cell lies within 2 cells of a background point (route start).
pub fn walkableNear(m: WalkMap, p: [2]f32) bool {
    return nearestWalkable(m, cellOf(p), 2) != null;
}

/// Walkable cell within `max_r` minimising (distance to it + distance to the goal): for an
/// actor stuck mid-ladder, the end toward the goal rather than just the nearest cell.
fn walkableToward(m: WalkMap, c: [2]i32, goal: [2]i32, max_r: i32) ?[2]i32 {
    var best: ?[2]i32 = null;
    var best_d: f32 = std.math.inf(f32);
    var dy: i32 = -max_r;
    while (dy <= max_r) : (dy += 1) {
        var dx: i32 = -max_r;
        while (dx <= max_r) : (dx += 1) {
            const x = c[0] + dx;
            const y = c[1] + dy;
            if (!walkable(m, x, y)) continue;
            const gx: f32 = @floatFromInt(goal[0] - x);
            const gy: f32 = @floatFromInt(goal[1] - y);
            const d = @sqrt(num.toF32(dx * dx + dy * dy)) + @sqrt(gx * gx + gy * gy);
            if (d < best_d) {
                best_d = d;
                best = .{ x, y };
            }
        }
    }
    return best;
}

/// `.ap` link for the search: start cell `a` (link sx, sy) and end `b` (dx, dy), in file
/// order. Usable both ways (0x4ac454…0x4ac5aa): from a cell marked end (`kind` bit 2) to the
/// start, from a start mark (bit 1) to the end; the exit cell must be walkable.
pub const Portal = struct { a: [2]i32, b: [2]i32 };

/// Route step: walk to a background point or take path `portal` (from its end if `reverse`).
const Step = union(enum) {
    walk: [2]f32,
    portal: struct { index: u16, reverse: bool },
};

/// Route from `from` to `to` (background pixels) as points only; null if unreachable.
fn findPath(gpa: Allocator, m: WalkMap, from: [2]f32, to: [2]f32) !?[][2]f32 {
    var cells: []?u32 = &.{};
    defer gpa.free(cells);
    const steps = (try findRoute(gpa, &cells, m, &.{}, from, to)) orelse return null;
    defer gpa.free(steps);
    var out: std.ArrayList([2]f32) = .empty;
    errdefer out.deinit(gpa);
    for (steps) |st| try out.append(gpa, st.walk);
    return try out.toOwnedSlice(gpa);
}

/// Cell of a background point: truncating integer division, like `idiv` in 0x4abdd0.
fn cellTrunc(p: [2]f32) [2]i32 {
    const cs: i32 = @intFromFloat(cell);
    const x = value.floatToInt(p[0]);
    const y = value.floatToInt(p[1]);
    return .{ @divTrunc(x, cs), @divTrunc(y, cs) };
}

/// Blocked goal (0x4abe4f…0x4abf5e): the cell within `r` with the smallest dx² + dy²; ties go
/// to the first in row order, top to bottom, left to right.
fn goalNear(m: WalkMap, c: [2]i32, r: i32) ?[2]i32 {
    if (walkable(m, c[0], c[1])) return c;
    var best: ?[2]i32 = null;
    var best_d: i32 = std.math.maxInt(i32);
    var y = @max(c[1] - r, 0);
    const y_end = @min(@as(i32, @intCast(m.height)) - 1, c[1] + r);
    while (y <= y_end) : (y += 1) {
        var x = @max(c[0] - r, 0);
        const x_end = @min(@as(i32, @intCast(m.width)) - 1, c[0] + r);
        while (x <= x_end) : (x += 1) {
            if (!walkable(m, x, y)) continue;
            const d = (c[1] - y) * (c[1] - y) + (c[0] - x) * (c[0] - x);
            if (d < best_d) {
                best_d = d;
                best = .{ x, y };
            }
        }
    }
    return best;
}

pub fn kindAt(m: WalkMap, x: i32, y: i32) u8 {
    return if (cellAt(m, .{ x, y })) |c| c.kind else 0;
}

/// Route with `.ap` transitions, the exe search (0x4abdd0 → 0x4ac000):
/// - integer cells; straight step 5, diagonal 7, path transition 5; heuristic is the integer
///   part of the Euclidean cell distance (0x4ac6b9);
/// - searches from goal to start; the open list is sorted by f and a new cell goes before
///   equals (0x4ac700); improving an open cell changes f without re-sorting, improving a
///   closed one passes g + 1 to its children (0x4ac750, LIFO stack);
/// - neighbours in exe order (0x4ac200): ↖ ↑ ↗ → ↘ ↓ ↙ ←, corner cutting allowed;
/// - every route cell's centre is a point, start and goal included (0x426a80).
/// Difference: the exe refuses a blocked start; we pull it to a walkable cell (an actor may
/// stand on an edge after a path or a scene).
/// `cells`: reusable open/closed index buffer (grown to 2 × cells of `m`, owned by the caller).
pub fn findRoute(gpa: Allocator, cells: *[]?u32, m: WalkMap, portals: []const Portal, from: [2]f32, to: [2]f32) !?[]Step {
    const goal = goalNear(m, cellTrunc(to), 5) orelse return null;
    const fc = cellTrunc(from);
    const start = if (walkable(m, fc[0], fc[1])) fc else nearestWalkable(m, cellOf(from), 2) orelse walkableToward(m, cellOf(from), goal, 16) orelse return null;
    var s: Search = try .init(gpa, cells, m, portals, start);
    defer s.deinit();
    const first = (try s.run(goal)) orelse return null;

    var out: std.ArrayList(Step) = .empty;
    errdefer out.deinit(gpa);
    var cur: ?u32 = first;
    var last: ?u16 = null;
    while (cur) |ni| {
        const n = s.nodes.items[ni];
        try out.append(gpa, .{ .walk = center(.{ n.x, n.y }) });
        // Take a transition when this and the next cell share a link (0x426d00…0x426dc5), or
        // when the linked cell is the last of the route (0x426da5 → 0x426dc5): clicking a
        // ladder (WalkPath to the link start, 0x427170) climbs it. Direction comes from the
        // start mark (0x426d76). The link just taken is not taken again (0x426d25: the pair's
        // second cell is the transition end).
        if (n.link) |l| if (last != l) {
            const pass = if (n.parent) |nx| s.nodes.items[nx].link == l else true;
            if (pass) {
                try out.append(gpa, .{ .portal = .{ .index = l, .reverse = kindAt(m, n.x, n.y) & 2 == 0 } });
                last = l;
            }
        };
        cur = n.parent;
    }
    return try out.toOwnedSlice(gpa);
}

/// Exe A*: nodes with integer f, h, g, a parent and up to 9 children (0x4ac5c0).
const Search = struct {
    gpa: Allocator,
    m: WalkMap,
    portals: []const Portal,
    /// Search target: the route's start cell (the search runs from the route goal).
    target: [2]i32,
    nodes: std.ArrayList(Node) = .empty,
    open_of: []?u32,
    closed_of: []?u32,
    open_head: ?u32 = null,
    stack: std.ArrayList(u32) = .empty,

    const no_child = std.math.maxInt(u32);
    const Node = struct {
        f: i32,
        h: i32,
        g: i32,
        x: i32,
        y: i32,
        parent: ?u32 = null,
        next: ?u32 = null,
        children: [9]u32 = @splat(no_child),
        link: ?u16 = null,
    };

    fn init(gpa: Allocator, cells: *[]?u32, m: WalkMap, portals: []const Portal, target: [2]i32) !Search {
        const n = @as(usize, m.width) * m.height;
        if (cells.len < 2 * n) {
            gpa.free(cells.*);
            cells.* = &.{};
            cells.* = try gpa.alloc(?u32, 2 * n);
        }
        const open_of = cells.*[0..n];
        const closed_of = cells.*[n .. 2 * n];
        @memset(open_of, null);
        @memset(closed_of, null);
        return .{ .gpa = gpa, .m = m, .portals = portals, .target = target, .open_of = open_of, .closed_of = closed_of };
    }

    fn deinit(self: *Search) void {
        self.nodes.deinit(self.gpa);
        self.stack.deinit(self.gpa);
    }

    fn idx(self: *const Search, x: i32, y: i32) usize {
        return @as(usize, @intCast(y)) * self.m.width + @as(usize, @intCast(x));
    }

    /// Integer part of the distance to the search target (0x4ac69d…0x4ac6b9).
    fn heur(self: *const Search, x: i32, y: i32) i32 {
        const dx = x - self.target[0];
        const dy = y - self.target[1];
        return @intFromFloat(@sqrt(@as(f64, @floatFromInt(dx * dx + dy * dy))));
    }

    /// Insert into the open list before the first node with f ≥ its own (0x4ac700).
    fn insert(self: *Search, ni: u32) void {
        const n = &self.nodes.items[ni];
        self.open_of[self.idx(n.x, n.y)] = ni;
        var prev: ?u32 = null;
        var cur = self.open_head;
        while (cur) |c| : (cur = self.nodes.items[c].next) {
            if (self.nodes.items[c].f >= n.f) break;
            prev = c;
        }
        n.next = cur;
        if (prev) |p| self.nodes.items[p].next = ni else self.open_head = ni;
    }

    fn addChild(self: *Search, parent: u32, child: u32) void {
        for (&self.nodes.items[parent].children) |*c| if (c.* == no_child) {
            c.* = child;
            return;
        };
    }

    /// Neighbour `x, y` with step cost `cost` (0x4ac5c0).
    fn visit(self: *Search, parent: u32, x: i32, y: i32, cost: i32) !void {
        const g = self.nodes.items[parent].g + cost;
        const ci = self.idx(x, y);
        if (self.open_of[ci]) |o| {
            self.addChild(parent, o);
            const n = &self.nodes.items[o];
            if (g < n.g) {
                n.g = g;
                n.f = n.h + g;
                n.parent = parent;
            }
            return;
        }
        if (self.closed_of[ci]) |c| {
            self.addChild(parent, c);
            const n = &self.nodes.items[c];
            if (g < n.g) {
                n.parent = parent;
                n.g = g;
                n.f = n.h + g;
                try self.propagate(c);
            }
            return;
        }
        const h = self.heur(x, y);
        const ni: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.gpa, .{ .f = h + g, .h = h, .g = g, .x = x, .y = y, .parent = parent });
        self.insert(ni);
        self.addChild(parent, ni);
    }

    /// Improved closed cell: children get g + 1, continuing via the stack (0x4ac750).
    fn propagate(self: *Search, from: u32) !void {
        try self.relaxChildren(from);
        while (self.stack.pop()) |p| try self.relaxChildren(p);
    }

    fn relaxChildren(self: *Search, pi: u32) !void {
        const p = self.nodes.items[pi];
        for (p.children) |c| {
            if (c == no_child) break;
            const n = &self.nodes.items[c];
            if (p.g + 1 < n.g) {
                n.g = p.g + 1;
                n.f = n.h + n.g;
                n.parent = pi;
                try self.stack.append(self.gpa, c);
            }
        }
    }

    /// First link whose end (`end`) or start cell is `x, y`. The exe's link list is in reverse
    /// file order (0x4ab1f1…0x4ab21b).
    fn linkAt(self: *const Search, x: i32, y: i32, end: bool) ?u16 {
        var k = self.portals.len;
        while (k > 0) {
            k -= 1;
            const c = if (end) self.portals[k].b else self.portals[k].a;
            if (c[0] == x and c[1] == y) return @intCast(k);
        }
        return null;
    }

    /// Links of a cell from its marks: end, then start (0x4ac454…0x4ac5aa).
    fn markLinks(self: *Search, ni: u32, visit_other: bool) !void {
        const x = self.nodes.items[ni].x;
        const y = self.nodes.items[ni].y;
        const kind = kindAt(self.m, x, y);
        if (kind & 4 != 0) if (self.linkAt(x, y, true)) |l| {
            const s = self.portals[l].a;
            if (visit_other and walkable(self.m, s[0], s[1])) try self.visit(ni, s[0], s[1], 5);
            self.nodes.items[ni].link = l;
        };
        if (kind & 2 != 0) if (self.linkAt(x, y, false)) |l| {
            const e = self.portals[l].b;
            if (visit_other and walkable(self.m, e[0], e[1])) try self.visit(ni, e[0], e[1], 5);
            self.nodes.items[ni].link = l;
        };
    }

    /// Expand a node (0x4ac200): 8 neighbours, then transitions.
    fn expand(self: *Search, ni: u32) !void {
        const x = self.nodes.items[ni].x;
        const y = self.nodes.items[ni].y;
        const dirs = [_][3]i32{ .{ -1, -1, 7 }, .{ 0, -1, 5 }, .{ 1, -1, 7 }, .{ 1, 0, 5 }, .{ 1, 1, 7 }, .{ 0, 1, 5 }, .{ -1, 1, 7 }, .{ -1, 0, 5 } };
        for (dirs) |d| if (walkable(self.m, x + d[0], y + d[1])) try self.visit(ni, x + d[0], y + d[1], d[2]);
        self.nodes.items[ni].link = null;
        try self.markLinks(ni, true);
    }

    /// Search from `goal` toward the search target (0x4ac000): its node or null.
    fn run(self: *Search, goal: [2]i32) !?u32 {
        const h = self.heur(goal[0], goal[1]);
        try self.nodes.append(self.gpa, .{ .f = h, .h = h, .g = 0, .x = goal[0], .y = goal[1] });
        self.insert(0);
        while (self.open_head) |ni| {
            // Open → closed (0x4ac1a0).
            const n = self.nodes.items[ni];
            self.open_head = n.next;
            const ci = self.idx(n.x, n.y);
            self.open_of[ci] = null;
            self.closed_of[ci] = ni;
            if (n.x == self.target[0] and n.y == self.target[1]) {
                // The start cell's link from its marks, without a transition (0x4ac0e6…0x4ac191).
                try self.markLinks(ni, false);
                return ni;
            }
            try self.expand(ni);
        }
        return null;
    }
};

test "route through a portal" {
    const gpa = std.testing.allocator;
    // Two 3×5 rooms behind a wall; a transition from (1,1) to (5,1).
    var cells: [35]WalkMap.Cell = undefined;
    for (&cells, 0..) |*c, i| c.* = .{ .kind = if (i % 7 == 3) 0 else 1, .height = 0 };
    // Marks: start (bit 1) at (1,1), end (bit 2) at (5,1).
    cells[1 * 7 + 1].kind = 3;
    cells[1 * 7 + 5].kind = 5;
    const m: WalkMap = .{ .width = 7, .height = 5, .cells = &cells };
    const portals = [_]Portal{.{ .a = .{ 1, 1 }, .b = .{ 5, 1 } }};
    var buf: []?u32 = &.{};
    defer gpa.free(buf);
    const r = (try findRoute(gpa, &buf, m, &portals, .{ 4, 4 }, .{ 52, 36 })).?;
    defer gpa.free(r);
    var used = false;
    for (r, 0..) |st, k| if (st == .portal) {
        used = true;
        try std.testing.expect(!st.portal.reverse);
        // Before the transition: start cell centre; after: end cell centre.
        try std.testing.expectEqual([2]f32{ 12, 12 }, r[k - 1].walk);
        try std.testing.expectEqual([2]f32{ 44, 12 }, r[k + 1].walk);
    };
    try std.testing.expect(used);
    // First point is the start cell centre (0x426a80), last the goal's.
    try std.testing.expectEqual([2]f32{ 4, 4 }, r[0].walk);
    try std.testing.expectEqual([2]f32{ 52, 36 }, r[r.len - 1].walk);
    // Back: the same transition from its end.
    const back = (try findRoute(gpa, &buf, m, &portals, .{ 52, 36 }, .{ 4, 4 })).?;
    defer gpa.free(back);
    for (back) |st| if (st == .portal) try std.testing.expect(st.portal.reverse);
}

test "path around a wall" {
    const gpa = std.testing.allocator;
    // 5×5 with a wall in column 2 except the bottom row.
    var cells: [25]WalkMap.Cell = undefined;
    for (&cells, 0..) |*c, i| c.* = .{ .kind = if (i % 5 == 2 and i / 5 < 4) 0 else 1, .height = 0 };
    const m: WalkMap = .{ .width = 5, .height = 5, .cells = &cells };
    const path = (try findPath(gpa, m, .{ 4, 4 }, .{ 36, 4 })).?;
    defer gpa.free(path);
    // Must go down to the gap and out to the goal.
    var went_down = false;
    for (path) |p| if (p[1] > 32) {
        went_down = true;
    };
    try std.testing.expect(went_down);
    try std.testing.expectEqual([2]f32{ 36, 4 }, path[path.len - 1]);
    try std.testing.expectEqual(null, try findPath(gpa, .{ .width = 1, .height = 1, .cells = cells[2..3] }, .{ 0, 0 }, .{ 4, 4 }));
}

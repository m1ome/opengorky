//! A location's map as core records: walk grids (`.wm`/`.wm2`), battle grid (`.cm`),
//! areas (`.ar`), paths (`.ap`), and what the exe computes on them (area test 0x4797f0,
//! grid ↔ world 0x497a80, battle grid edges 0x495530). The core reads no files:
//! composition (loaders/map.zig) parses the level's files at level entry into a `Map`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value = @import("../script.zig").value;
const num = @import("../num.zig");
const vec = @import("../vec.zig");

/// What a location keeps of its level files (the world's `map`), in the world's arena.
/// Its look (background, depth, lights) is a `Backdrop` the client asks the world's
/// source for; the `.pts` of scenes are core/scene.zig, `.are`/`.var` are script objects
/// and their variables (the world's source).
pub const Map = struct {
    /// Ground-floor walk grid `.wm`.
    walk: ?WalkMap = null,
    /// Second floor `.wm2` (roofs, platforms); an actor's floor is `Actor.map`.
    walk2: ?WalkMap = null,
    /// Battle grid `.cm` (PlaceActor by cell).
    combat: ?CombatMap = null,
    /// Location areas (`.ar`, PlaceActor).
    areas: []Area = &.{},
    /// `.ap` paths (ladders, planks, steps).
    paths: []Path = &.{},
};

pub const Path = struct {
    name: []const u8,
    /// `link: sx, sy, dx, dy`: anchor points (grid cells? unverified).
    link: [4]f32,
    /// x, y (background pixels), node angle (rad, +0xa0 — ActorAdjustAngle), an int (+0xe0).
    points: [][4]f32,
};

pub fn freePaths(gpa: Allocator, paths: []Path) void {
    for (paths) |p| gpa.free(p.points);
    gpa.free(paths);
}

pub const Area = struct {
    name: []const u8,
    /// Polygon: x, y (background pixels), z.
    points: [][3]f32,
    /// Area "entry" point.
    control: [2]f32,
};

pub fn freeAreas(gpa: Allocator, areas: []Area) void {
    for (areas) |a| gpa.free(a.points);
    gpa.free(areas);
}

/// Point inside an area (0x4797f0): vertices and the point are integers (`_ftol`),
/// inclusive bounding-box reject, rays to the right with their own rules at vertices
/// and horizontal edges, result `crossings & 1`.
pub fn areaContains(area: Area, x: f32, y: f32) bool {
    const n = area.points.len;
    if (n == 0) return false;
    const X = value.floatToInt(x);
    const Y = value.floatToInt(y);
    const P = struct {
        fn at(pts: [][3]f32, i: usize) [2]i32 {
            return .{ value.floatToInt(pts[i][0]), value.floatToInt(pts[i][1]) };
        }
    };
    var lo: [2]i32 = P.at(area.points, 0);
    var hi = lo;
    for (0..n) |i| {
        const p = P.at(area.points, i);
        lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
        hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
    }
    if (X < lo[0] or Y < lo[1] or X > hi[0] or Y > hi[1]) return false;
    var count: u32 = 0;
    for (0..n) |k| {
        const a = P.at(area.points, k);
        const b = P.at(area.points, (k + 1) % n);
        if (a[1] == b[1]) continue;
        if (b[1] == Y) {
            // A ray through vertex b counts if b's neighbours lie on different sides.
            if (b[0] <= X) continue;
            const c = P.at(area.points, (k + 2) % n);
            if ((a[1] < Y) != (c[1] < Y)) count += 1;
            continue;
        }
        if (@min(a[1], b[1]) >= Y or @max(a[1], b[1]) <= Y) continue;
        const s = @as(f64, @floatFromInt(b[0] - a[0])) / @as(f64, @floatFromInt(b[1] - a[1]));
        const xi = value.floatToInt(@as(f32, @floatCast(@as(f64, @floatFromInt(a[0])) - @as(f64, @floatFromInt(a[1])) * s + @as(f64, @floatFromInt(Y)) * s)));
        const mn = @min(a[0], b[0]);
        const mx = @max(a[0], b[0]);
        if (xi <= X) continue;
        if (if (mn < mx) (xi < mx and mn <= xi) else xi == mn) count += 1;
    }
    return count & 1 == 1;
}

/// Exploration level grid, 8×8 background-pixel cells.
/// `.wm` is the main floor, `.wm2` the second (bridges, roofs; switched by
/// `TestActorMapChange` in the level script).
pub const WalkMap = struct {
    pub const cell_size = 8;

    width: u32,
    height: u32,
    cells: []Cell,

    pub const Cell = struct {
        /// Bit 0 — walkable; bit 1 — start cell of an `.ap` path (link sx, sy),
        /// bit 2 — end cell (dx, dy); bits 3–5 the exe puts into the grid word
        /// (0x4abae1), they are zero in the data (0x4ab8b0).
        kind: u8,
        /// Floor height; the exe takes 12 signed bits (0x4abafd), the data never exceeds that.
        height: i16,

        pub fn walkable(self: Cell) bool {
            return self.kind & 1 != 0;
        }
    };

    pub fn deinit(self: *WalkMap, gpa: Allocator) void {
        gpa.free(self.cells);
        self.* = undefined;
    }

    pub fn at(self: WalkMap, x: usize, y: usize) Cell {
        return self.cells[y * self.width + x];
    }
};

/// Battle grid. Cells are in world 3D coordinates and projected by the level's
/// `initCamera()` camera.
pub const CombatMap = struct {
    center: [3]f32,
    rotation: f32,
    /// Cell size in world units.
    cell_size: [2]f32,
    width: u32,
    height: u32,
    /// true — cell blocked (`O`), rows top to bottom as in the file.
    blocked: []bool,
    /// Cells with height: x, y, height.
    heights: [][3]i32,

    /// Grid point (gx, gy in cells from the corner) in the world (0x497a80, axes 0x493b50):
    /// center + gx·xSize·(cos r, sin r) + gy·ySize·(−sin r, cos r), z = centerZ.
    pub fn toWorld(self: CombatMap, gx: f32, gy: f32) [3]f32 {
        const c = @cos(self.rotation);
        const s = @sin(self.rotation);
        const ax = gx * self.cell_size[0];
        const ay = gy * self.cell_size[1];
        return .{ self.center[0] + ax * c - ay * s, self.center[1] + ax * s + ay * c, self.center[2] };
    }

    /// Inverse: world point → (gx, gy) in cells.
    pub fn toGrid(self: CombatMap, x: f32, y: f32) [2]f32 {
        const c = @cos(self.rotation);
        const s = @sin(self.rotation);
        const dx = x - self.center[0];
        const dy = y - self.center[1];
        return .{ (dx * c + dy * s) / self.cell_size[0], (-dx * s + dy * c) / self.cell_size[1] };
    }

    /// Corner tile of a fighter of `size` cells whose centre is at world point `p`.
    /// Rounds half up: a large fighter put by PlaceActor at tile 0's centre lands with its
    /// corner in tile 0, not −1 (@round would take −0.5 to −1).
    pub fn tileOf(self: CombatMap, p: [3]f32, size: u32) [2]i32 {
        const half: f32 = @as(f32, @floatFromInt(size)) / 2;
        const g = self.toGrid(p[0], p[1]);
        return .{ value.floatToInt(@floor(g[0] - half + 0.5)), value.floatToInt(@floor(g[1] - half + 0.5)) };
    }

    /// Centre of a fighter of `size` standing with its corner in tile `t`.
    pub fn tileCenter(self: CombatMap, t: [2]i32, size: u32) [3]f32 {
        const half: f32 = @as(f32, @floatFromInt(size)) / 2;
        return self.toWorld(@as(f32, @floatFromInt(t[0])) + half, @as(f32, @floatFromInt(t[1])) + half);
    }

    /// Battle grid edge: cell, side (1 top, y−1; 2 right; 3 bottom; 4 left)
    /// and brightness 0…16 (+0x818).
    pub const GridEdge = struct { x: u8, y: u8, side: u8, level: i32 = 0 };

    /// Battle grid edges (0x495530, on `.cm` load): breadth-first over sides from the
    /// walkable cell closest to the grid corner (√(x² + y²) < √20000, first in row
    /// order). Each cell checks top, right, bottom, left: a missing or blocked neighbour
    /// gives an edge; a free unvisited one gives an edge and is queued (a visited one
    /// already gave it). Each edge once; list order is visit order (the appearance
    /// wave follows it, 0x495f80). Cells are u8: composition keeps width and height ≤ 255.
    pub fn gridEdges(self: CombatMap, gpa: Allocator) Allocator.Error![]GridEdge {
        var best: ?[2]u32 = null;
        var best_d: f64 = @sqrt(20000.0);
        for (0..self.height) |y| for (0..self.width) |x| {
            if (self.blocked[y * self.width + x]) continue;
            const d = @sqrt(@as(f64, @floatFromInt(x * x + y * y)));
            if (d < best_d) {
                best_d = d;
                best = .{ @intCast(x), @intCast(y) };
            }
        };
        var edges: std.ArrayList(GridEdge) = .empty;
        errdefer edges.deinit(gpa);
        const start = best orelse return edges.toOwnedSlice(gpa);
        const n = @as(usize, self.width) * self.height;
        // 0 unseen, 1 queued, 2 done.
        const state = try gpa.alloc(u8, n);
        defer gpa.free(state);
        @memset(state, 0);
        const queue = try gpa.alloc([2]u32, n);
        defer gpa.free(queue);
        queue[0] = start;
        state[start[1] * self.width + start[0]] = 1;
        var len: usize = 1;
        var head: usize = 0;
        const dirs = [4][2]i32{ .{ 0, -1 }, .{ 1, 0 }, .{ 0, 1 }, .{ -1, 0 } };
        while (head < len) : (head += 1) {
            const c = queue[head];
            for (dirs, 1..) |d, side| {
                const nx = @as(i32, @intCast(c[0])) + d[0];
                const ny = @as(i32, @intCast(c[1])) + d[1];
                if (nx >= 0 and ny >= 0 and nx < self.width and ny < self.height) {
                    const k = @as(usize, @intCast(ny)) * self.width + @as(usize, @intCast(nx));
                    if (!self.blocked[k]) {
                        if (state[k] == 0) {
                            state[k] = 1;
                            queue[len] = .{ @intCast(nx), @intCast(ny) };
                            len += 1;
                        }
                        if (state[k] >= 2) continue;
                    }
                }
                try edges.append(gpa, .{ .x = @intCast(c[0]), .y = @intCast(c[1]), .side = @intCast(side) });
            }
            state[c[1] * self.width + c[0]] = 2;
        }
        return edges.toOwnedSlice(gpa);
    }

    pub fn deinit(self: *CombatMap, gpa: Allocator) void {
        gpa.free(self.blocked);
        gpa.free(self.heights);
        self.* = undefined;
    }
};

// ---------------------------------------------------------------- backdrop

/// What a location is drawn with (the `.lev` data the exe loads with it, 0x41cc70,
/// 0x41cf07, 0x47f070): its background picture, the background's depth (`.zbf` and
/// `.cfg` of `background\<level>`) and its lights (`<level>.lts`). The core doesn't use
/// it: the world's source reads it for the client (core/source.zig `backdrop`).
pub const Backdrop = struct {
    /// Background asset path (loaders/assets.zig: `levels/<level>/background.bkg` or
    /// `.jpg`; Classic: `background\<level>.*` of the location's sprite.dat).
    background: ?[]const u8 = null,
    lights: ?Lights = null,
    /// Orthographic levels only (no `tl` in `.cfg`).
    ortho: ?OrthoCfg = null,
    /// `.cfg` of a perspective level (14 levels lack it — then tl comes from initCamera).
    persp: ?PerspCfg = null,
    /// Background height map (`.zbf`).
    heights: ?Heights = null,
};

/// Background pixels per level unit: k when the picture (`w`×`h`) is k ≥ 2 times the
/// depth map (`.zbf`, `z`: the level's own size) on both sides — a project's
/// high-resolution background, drawn k times smaller — else 1.
pub fn bgScale(w: u32, h: u32, z: ?[2]u32) u32 {
    const zz = z orelse return 1;
    if (zz[0] == 0 or zz[1] == 0 or w % zz[0] != 0) return 1;
    const k = w / zz[0];
    return if (k >= 2 and h == zz[1] * k) k else 1;
}

test "bgScale: a picture k times its depth map" {
    try std.testing.expectEqual(@as(u32, 1), bgScale(1280, 1140, .{ 1280, 1140 }));
    try std.testing.expectEqual(@as(u32, 2), bgScale(2560, 2280, .{ 1280, 1140 }));
    try std.testing.expectEqual(@as(u32, 1), bgScale(2560, 2200, .{ 1280, 1140 }));
    try std.testing.expectEqual(@as(u32, 1), bgScale(2560, 2280, null));
}

/// Background depth per pixel (`.zbf`), rows top to bottom.
pub const Heights = struct { width: u32, height: u32, depth: []u16 };

/// `.lts`: point lights, ambient, the directional light's colour and the shadow light.
pub const Omni = struct { pos: [3]f32, color: [3]f32, range: f32 };

pub const Lights = struct {
    omni: []Omni,
    ambient: [3]f32,
    directional_color: [3]f32,
    shadow_light: [3]f32,
    shadow_intensity: f32,
};

/// Background `.cfg` of an orthographic level: what height-map value `g1` maps to.
pub const OrthoCfg = struct {
    /// Height (world px) that height-map value `g1` maps to.
    gscale: f32 = 200,
    /// Height-map value at ground level.
    g0: f32 = 57088,
    g1: f32 = 27904,

    /// Background surface height for a `.zbf` value.
    pub fn height(self: OrthoCfg, v: u16) f32 {
        return (self.g0 - num.toF32(v)) / (self.g0 - self.g1) * self.gscale;
    }
};

/// `.cfg` of a perspective level (0x41cf07): eye, target and scene depth `tl`. A `.zbf`
/// value v is depth `far − v·tl/65536`, where far = |eye − target| + tl (W-buffer;
/// v = 0 is the far plane).
const PerspCfg = struct {
    eye: [3]f32 = .{ 0, 0, 0 },
    target: [3]f32 = .{ 0, 0, 0 },
    tl: f32 = -1,

    pub fn far(self: PerspCfg) f32 {
        const d = [3]f32{ self.eye[0] - self.target[0], self.eye[1] - self.target[1], self.eye[2] - self.target[2] };
        return vec.len(d) + self.tl;
    }
};

/// Background point depth for a `.zbf` value (perspective, see PerspCfg).
pub fn perspDepth(far: f32, tl: f32, v: u16) f32 {
    return far - num.toF32(v) * tl / 65536;
}

test "areaContains follows 0x4797f0" {
    var sq = [_][3]f32{ .{ 0, 0, 0 }, .{ 10, 0, 0 }, .{ 10, 10, 0 }, .{ 0, 10, 0 } };
    const a: Area = .{ .name = "", .points = &sq, .control = .{ 0, 0 } };
    try std.testing.expect(areaContains(a, 5, 5));
    // A fractional point truncates: 9.9 → 9 inside, −0.5 → 0 on the edge.
    try std.testing.expect(areaContains(a, 9.9, 5));
    // Left edge: at x = 0 the right edge crossing (10 > 0) counts → inside.
    try std.testing.expect(areaContains(a, 0, 5));
    try std.testing.expect(areaContains(a, -0.5, 5));
    // Right edge: at x = 10 no crossings further right → outside.
    try std.testing.expect(!areaContains(a, 10, 5));
    // A ray at vertex height: y = 0 outside, y = 10 inside (vertex (10,10) with
    // neighbours (10,0) and (0,10): one below, the other not — the crossing counts).
    try std.testing.expect(!areaContains(a, 5, 0));
    try std.testing.expect(areaContains(a, 5, 10));
    // Diamond: a ray through vertex (10,5) with neighbours on different sides — one crossing.
    var di = [_][3]f32{ .{ 5, 0, 0 }, .{ 10, 5, 0 }, .{ 5, 10, 0 }, .{ 0, 5, 0 } };
    const d: Area = .{ .name = "", .points = &di, .control = .{ 0, 0 } };
    try std.testing.expect(areaContains(d, 5, 5));
    try std.testing.expect(!areaContains(d, 11, 5));
    try std.testing.expect(!areaContains(.{ .name = "", .points = &.{}, .control = .{ 0, 0 } }, 0, 0));
}

test "battle grid edges (0x495530)" {
    const gpa = std.testing.allocator;
    // OO.
    // ...
    var blocked = [_]bool{ true, true, false, false, false, false };
    const m: CombatMap = .{ .center = .{ 0, 0, 0 }, .rotation = 0, .cell_size = .{ 1, 1 }, .width = 3, .height = 2, .blocked = &blocked, .heights = &.{} };
    // Starts at (0, 1), the free cell closest to the corner.
    const edges = try m.gridEdges(gpa);
    defer gpa.free(edges);
    // Four cells: (0,1), (1,1), (2,1), (2,0). Edges: 4 × 4 minus 3 shared.
    try std.testing.expectEqual(13, edges.len);
    try std.testing.expectEqual(CombatMap.GridEdge{ .x = 0, .y = 1, .side = 1 }, edges[0]);
    try std.testing.expectEqual(CombatMap.GridEdge{ .x = 0, .y = 1, .side = 2 }, edges[1]);
    // The shared edge (2,1)–(2,0) gives (2,1) a top; (2,0) has no bottom.
    for (edges) |e| try std.testing.expect(!(e.x == 2 and e.y == 0 and e.side == 3));
}

test "backdrop depth: perspective and orthographic" {
    const c: PerspCfg = .{ .eye = .{ 0, 3, -4 }, .tl = 2 };
    try std.testing.expectEqual(7, c.far());
    try std.testing.expectEqual(6, perspDepth(c.far(), c.tl, 32768));
    try std.testing.expectEqual(253, (OrthoCfg{ .gscale = 253 }).height(27904));
}

test "tile <-> world" {
    const cm: CombatMap = .{ .center = .{ -100, 50, -10 }, .rotation = 0, .cell_size = .{ 40, 40 }, .width = 9, .height = 9, .blocked = &.{}, .heights = &.{} };
    for ([_]u32{ 1, 2 }) |s| {
        const t: [2]i32 = .{ 3, 5 };
        try std.testing.expectEqual(t, cm.tileOf(cm.tileCenter(t, s), s));
    }
}

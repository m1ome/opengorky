//! Actor route to a background point: path over the floor's `.wm` grid with `.ap` path
//! transitions and their waypoints (0x426a80, 0x4ac200). Shared by the command queue
//! (world/queue.zig) and party walking (world/walk.zig).

const std = @import("std");
const value = @import("../script.zig").value;
const num = @import("../num.zig");
const level_files = @import("../formats.zig").level_files;
const actor_mod = @import("../actor.zig");
const fields = @import("../fields.zig");
const nav = @import("nav.zig");
const floor = @import("floor.zig");
const Object = @import("../script.zig").object.Object;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;

/// The level's `.ap` links (start sx, sy → end dx, dy) in file order, for the route search.
pub fn levelPortals(self: *const World, gpa: std.mem.Allocator) ![]nav.Portal {
    const out = try gpa.alloc(nav.Portal, self.paths.len);
    for (self.paths, out) |pa, *p| p.* = .{
        .a = .{ value.floatToInt(pa.link[0]), value.floatToInt(pa.link[1]) },
        .b = .{ value.floatToInt(pa.link[2]), value.floatToInt(pa.link[3]) },
    };
    return out;
}

/// Walk to a background point over the walk grid (straight line without one).
pub fn walkTo(self: *World, o: *Object, target_bg: [2]f32) !void {
    const a = world_mod.actorOf(o);
    a.attached_to = null;
    const here = self.cam.project(fields.pos(o));
    a.clearPath();
    if (floor.floorMap(self, a.map)) |m| {
        // Transitions use the `.ap` end marks on this floor (0x4ac200): start (bit 1)
        // leads to the end, end (bit 2) back to the start.
        const portals = try levelPortals(self, self.gpa);
        defer self.gpa.free(portals);
        const route = (try nav.findRoute(self.gpa, &self.nav_cells, m, portals, .{ here.x, here.y }, target_bg)) orelse {
            // No route: stand rather than step in place.
            a.stopWalking(self.crt());
            return;
        };
        defer self.gpa.free(route);
        // The exe gives every route cell its own height: straight runs are split per cell.
        var prev = [2]f32{ here.x, here.y };
        // A run cutting a corner through a blocked cell (height 0 in .wm) keeps the
        // previous step's height; otherwise the hero hopped to 0 (museum stairs, −286).
        var last_h: f32 = floor.cellHeight(m, .{ here.x, here.y }) orelse for (route) |st| switch (st) {
            .walk => |bg| if (floor.cellHeight(m, bg)) |h| break h,
            .portal => {},
        } else 0;
        var first = true;
        for (route) |st| switch (st) {
            .walk => |bg| {
                // Route = one point per cell centre at its own height (0x426a80). Only
                // our pulled-in start (nav.findRoute) can be farther than its own cell
                // (> 1 cell from the centre): that run is split per cell.
                const len = std.math.hypot(bg[0] - prev[0], bg[1] - prev[1]);
                const cs = level_files.WalkMap.cell_size;
                const n: usize = if (first and len > cs) @intFromFloat(@ceil(len / cs)) else 1;
                first = false;
                for (1..n + 1) |k| {
                    const t = num.toF32(k) / num.toF32(n);
                    const q = [2]f32{ prev[0] + (bg[0] - prev[0]) * t, prev[1] + (bg[1] - prev[1]) * t };
                    if (floor.cellHeight(m, q)) |h| last_h = h;
                    try a.addWaypoint(self.gpa, self.cam.unproject(q[0], q[1], last_h), null);
                }
                prev = bg;
            },
            .portal => |pt| {
                first = false;
                try addPathWaypoints(self, a, m, pt.index, pt.reverse);
                // Continue from the arrival point on the background (reverse: first .ap
                // point; forward: link end cell). Projecting the world point at z = 0
                // pushed it up by the floor height (museum −171) and the hero walked
                // back over blocked cells.
                const pa = self.paths[pt.index];
                prev = if (pt.reverse and pa.points.len > 0)
                    .{ pa.points[0][0], pa.points[0][1] }
                else
                    .{ (pa.link[2] + 0.5) * level_files.WalkMap.cell_size, (pa.link[3] + 0.5) * level_files.WalkMap.cell_size };
            },
        };
    } else {
        const wp = self.cam.unproject(target_bg[0], target_bg[1], 0);
        try a.path.append(self.gpa, .{ wp[0], wp[1] });
    }
    // Target is the own cell (or no path): stand, don't step in place.
    if (a.path.items.len == 0) {
        a.stopWalking(self.crt());
        return;
    }
    a.walk_anim = "walk";
    a.move_speed = a.speedOf("walk") * self.speedScale();
    // Scene WALK_ANIMATION (command 0x28): its own animation and speed.
    if (a.scene_walk) |sw| {
        a.walk_anim = sw.anim;
        if (sw.speed) |sp| a.move_speed = sp * self.speedScale();
    }
    a.on_track = false;
    a.one_shot = false;
    a.hold_move = false;
    a.play(a.resolve(a.walk_anim), true, false);
}

/// `.ap` path waypoints with NodeResponse(no, dir) events (0x426a80): points are nodes
/// 0…n−1, the link end cell (dx, dy) is n; forward dir 1, backward dir 0 in reverse order.
/// Numbering matches the port ladder and plank scripts (`drabinka.pth`, `deska.pth`); the
/// city ladder (`04_city/drabinka.pth`) is off by one — apparently a data bug.
fn addPathWaypoints(self: *World, a: *actor_mod.Actor, m: level_files.WalkMap, index: u16, reverse: bool) !void {
    const pa = self.paths[index];
    const cs = level_files.WalkMap.cell_size;
    // The exe stores 16 points: x,y +0x20, angle +0xa0, int +0xe0 (0x4ab306…0x4ab31a, no
    // length check); the game uses at most 13. Plus the end cell.
    var nodes: [17][3]f32 = undefined;
    const n = @min(pa.points.len, nodes.len - 1);
    // Node height is the `.ap` point's 4th number (0x426f65: + zLevel), not the height
    // map: ladder middles hang over blocked cells.
    for (pa.points[0..n], 0..) |pt, k| {
        const p = self.cam.unproject(pt[0], pt[1], pt[3]);
        nodes[k] = p;
    }
    nodes[n] = floor.groundPoint(self, m, .{ (pa.link[2] + 0.5) * cs, (pa.link[3] + 0.5) * cs });
    const count = n + 1;
    for (0..count) |k| {
        const no = if (reverse) count - 1 - k else k;
        try a.addWaypoint(self.gpa, nodes[no], .{ .path = index, .no = @intCast(no), .dir = if (reverse) 0 else 1 });
    }
}

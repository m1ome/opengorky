//! Hero and party walking: paths, placement, area walkability.

const std = @import("std");
const num = @import("../num.zig");
const level_files = @import("../formats.zig").level_files;
const fields = @import("../fields.zig");
const nav = @import("nav.zig");
const floor_mod = @import("floor.zig");
const queue = @import("queue.zig");
const route = @import("route.zig");
const areas = @import("areas.zig");
const object = @import("../script.zig").object;
const Object = object.Object;
const world = @import("../state.zig").world;
const World = world.World;

/// Party hero under a background point (click selection).
pub fn heroAt(self: *World, bg: [2]f32) ?*Object {
    const members = self.party();
    for (members.slice()) |h| {
        if (!h.enabled or !world.actorOf(h).placed) continue;
        const p = self.screenPos(h);
        if (@abs(bg[0] - p[0]) < 18 and bg[1] < p[1] + 6 and bg[1] > p[1] - 90) return h;
    }
    return null;
}

/// Area with WalkPath (0x451790 → 0x427170): every party hero (0x4517fe…0x451825, list
/// 0x6b4e78) routes on his own (0x427340, with .ap transitions) to the same cell — the link
/// start (`sx, sy`, +0x12e/+0x130). The linked cell is the route's last, so the route takes
/// the link (0x426da5 → 0x426dc5) and the whole party goes down the ladder and stops at its
/// end, with no delays or spreading (only party walk 0x427780 does that). A companion
/// already on the ladder is left alone, or he would get stuck on its cells.
pub fn walkPath(self: *World, hero: *Object, name: []const u8) !void {
    for (self.paths) |pa| {
        if (!std.ascii.eqlIgnoreCase(pa.name, name)) continue;
        const cs = level_files.WalkMap.cell_size;
        const link_start = [2]f32{ (pa.link[0] + 0.5) * cs, (pa.link[1] + 0.5) * cs };
        self.walk_ok = try walkToReach(self, hero, link_start);
        if (!self.walk_ok) return;
        const members = self.party();
        for (members.slice()) |h| {
            if (h == hero or !h.enabled or h.getInt("avoidEnumerate") != 0) continue;
            const ha = world.actorOf(h);
            if (!ha.placed or ha.onPortal()) continue;
            ha.queue.clearRetainingCapacity();
            try route.walkTo(self, h, link_start);
        }
        return;
    }
}

/// Party walk (0x427780): the selected hero to the goal; the others to random free cells
/// in a ±15-cell window around it, at least ~4 cells apart; those already 5..14 cells away
/// stay; those nearby leave after 15..49 ticks.
pub fn partyWalk(self: *World, hero: *Object, goal_in: [2]f32) !bool {
    const a_hero = world.actorOf(hero);
    var goal = goal_in;
    var tc = nav.cellOf(goal);
    // 0x427828: a blocked goal cell snaps to the nearest walkable cell within -4..3
    // (by squared distance) on the selected hero's floor, at its centre.
    if (floor_mod.floorMap(self, a_hero.map)) |m0| if (!nav.walkable(m0, tc[0], tc[1])) {
        var best: ?[2]i32 = null;
        var bd: i32 = std.math.maxInt(i32);
        var dy: i32 = -4;
        while (dy < 4) : (dy += 1) {
            var dx: i32 = -4;
            while (dx < 4) : (dx += 1) {
                const c = [2]i32{ tc[0] + dx, tc[1] + dy };
                if (!nav.walkable(m0, c[0], c[1])) continue;
                const d2 = dx * dx + dy * dy;
                if (d2 < bd) {
                    bd = d2;
                    best = c;
                }
            }
        }
        if (best) |b| {
            tc = b;
            goal = nav.center(b);
        }
    };
    self.walk_ok = try walkToReach(self, hero, goal);
    if (!self.walk_ok) return false;
    const m = floor_mod.floorMap(self, a_hero.map) orelse return true;
    // Blocked goal with no walkable cell nearby: the hero still gets there (the route search
    // looks wider) but companions have nowhere to stand, so use the cell where his route ends
    // (deviation: in the exe companions would stay put).
    if (!nav.walkable(m, tc[0], tc[1]) and a_hero.path.items.len > 0) {
        const last = a_hero.path.items[a_hero.path.items.len - 1];
        const z = if (a_hero.path_z.items.len > 0) a_hero.path_z.items[a_hero.path_z.items.len - 1] else 0;
        const q = self.cam.project(.{ last[0], last[1], if (std.math.isNan(z)) 0 else z });
        tc = nav.cellOf(.{ q.x, q.y });
    }
    const win = 30;
    var free: [win][win]bool = @splat(@splat(false));
    // Flood-fill walkable window cells from the goal (4-neighbour).
    var stack: [win * win][2]i32 = undefined;
    var n: usize = 0;
    const inWin = struct {
        fn f(t: [2]i32, c: [2]i32) ?[2]usize {
            const x = c[0] - t[0] + 15;
            const y = c[1] - t[1] + 15;
            if (x < 0 or y < 0 or x >= 30 or y >= 30) return null;
            return .{ @intCast(x), @intCast(y) };
        }
    }.f;
    if (nav.walkable(m, tc[0], tc[1])) {
        free[15][15] = true;
        stack[0] = tc;
        n = 1;
    }
    while (n > 0) {
        n -= 1;
        const c = stack[n];
        for ([_][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } }) |d| {
            const nc = [2]i32{ c[0] + d[0], c[1] + d[1] };
            const wi = inWin(tc, nc) orelse continue;
            if (free[wi[1]][wi[0]] or !nav.walkable(m, nc[0], nc[1])) continue;
            free[wi[1]][wi[0]] = true;
            stack[n] = nc;
            n += 1;
        }
    }
    const stamp = struct {
        fn f(fr: *[30][30]bool, t: [2]i32, c: [2]i32) void {
            var dy: i32 = -4;
            while (dy <= 4) : (dy += 1) {
                var dx: i32 = -4;
                while (dx <= 4) : (dx += 1) {
                    if (dx * dx + dy * dy > 16) continue;
                    const wi = inWin(t, .{ c[0] + dx, c[1] + dy }) orelse continue;
                    fr[wi[1]][wi[0]] = false;
                }
            }
        }
    }.f;
    stamp(&free, tc, tc);
    const rand = self.crt();
    const members = self.party();
    for (members.slice()) |h| {
        if (h == hero or !h.enabled or h.getInt("avoidEnumerate") != 0) continue;
        const ha = world.actorOf(h);
        // The companion's floor is not compared (0x4279a9); he routes on his own (0x427340).
        if (!ha.placed) continue;
        // Climbing a ladder: leave him alone or he gets stuck on its cells.
        if (ha.onPortal()) continue;
        const hp = self.screenPos(h);
        const hc = nav.cellOf(hp);
        const dx: f32 = @floatFromInt(hc[0] - tc[0]);
        const dy: f32 = @floatFromInt(hc[1] - tc[1]);
        const d = @sqrt(dx * dx + dy * dy);
        const limit: f32 = @floatFromInt(rand.below(10) + 5);
        if (inWin(tc, hc)) |wi| if (d <= limit and free[wi[1]][wi[0]]) {
            stamp(&free, tc, hc);
            continue;
        };
        var pick: ?[2]i32 = null;
        for (0..1000) |_| {
            const x = rand.below(win);
            const y = rand.below(win);
            if (!free[y][x]) continue;
            pick = .{ tc[0] + @as(i32, @intCast(x)) - 15, tc[1] + @as(i32, @intCast(y)) - 15 };
            break;
        }
        const pc = pick orelse continue;
        stamp(&free, tc, pc);
        const target = nav.center(pc);
        ha.queue.clearRetainingCapacity();
        // A new walk replaces the current one at once (0x427b7c → 0x427340 → 0x426a80 with
        // 0x427c10), routing from where the companion is now, on his floor.
        const was_busy = ha.busy();
        if (ha.path_index < ha.path.items.len) ha.clearPath();
        if (d <= 15 and !was_busy) try ha.queue.append(self.gpa, .{ .delay = rand.below(35) + 15 });
        try ha.queue.append(self.gpa, .{ .walk = target });
        try queue.runQueue(self, h, ha);
    }
    return true;
}

/// Walk-to point of an item: `walk_x`, `walk_y` (background pixels) or the item itself.
pub fn itemGoal(self: *World, item: *Object) [2]f32 {
    const wx = fields.getF(item, "walk_x");
    const wy = fields.getF(item, "walk_y");
    return if (wx != 0 or wy != 0) .{ wx, wy } else self.screenPos(item);
}

/// Hero saved mid-ladder (old builds could interrupt a `.ap` transition), standing on
/// blocked cells next to the path: move him to the nearer path end.
pub fn unstickHeroes(self: *World) void {
    const cs = level_files.WalkMap.cell_size;
    const members = self.party();
    for (members.slice()) |h| {
        const a = world.actorOf(h);
        if (!a.placed) continue;
        const m = floor_mod.floorMap(self, a.map) orelse continue;
        const p = self.screenPos(h);
        if (nav.walkableNear(m, p)) continue;
        // Old saves: PLACE without a floor didn't reset the hero to floor 0 (BT after
        // port-deska → port-meet_bt stayed on .wm2 by the trabant). If only the other grid
        // has floor under him, switch to it.
        if (self.walk_map2) |m2| {
            const other = if (a.map == 1) self.walk_map orelse m2 else m2;
            if (nav.walkableNear(other, p)) {
                a.map = if (a.map == 1) 0 else 1;
                a.clearPath();
                continue;
            }
        }
        var best: ?[2]f32 = null;
        var best_d: f32 = 32;
        for (self.paths) |pa| {
            const ends = [2][2]f32{
                .{ (pa.link[0] + 0.5) * cs, (pa.link[1] + 0.5) * cs },
                .{ (pa.link[2] + 0.5) * cs, (pa.link[3] + 0.5) * cs },
            };
            // Path polyline: link start, nodes, link end.
            var prev = ends[0];
            var near = std.math.inf(f32);
            for (pa.points) |pt| {
                near = @min(near, segDist(p, prev, .{ pt[0], pt[1] }));
                prev = .{ pt[0], pt[1] };
            }
            near = @min(near, segDist(p, prev, ends[1]));
            if (near >= best_d) continue;
            best_d = near;
            const d0 = std.math.hypot(p[0] - ends[0][0], p[1] - ends[0][1]);
            const d1 = std.math.hypot(p[0] - ends[1][0], p[1] - ends[1][1]);
            best = if (d0 <= d1) ends[0] else ends[1];
        }
        const e = best orelse continue;
        a.clearPath();
        fields.setPos(h, floor_mod.groundPoint(self, m, e));
    }
}

/// A hero who joined elsewhere (Slavsky) hasn't stood here: restore()'s PlaceHeroes ran
/// before he was carried over. In the exe he is a global object entering with the party;
/// we put him next to the selected hero on a free walkable cell 2…6 cells away.
pub fn placeBesideLead(self: *World, o: *Object) void {
    const a = world.actorOf(o);
    if (a.placed) return;
    const members = self.party();
    const party = members.slice();
    var lead: ?*Object = self.selectedHero();
    if (lead) |l| if (l == o or !world.actorOf(l).placed) {
        lead = null;
    };
    if (lead == null) for (party) |h| if (h != o and h.enabled and world.actorOf(h).placed) {
        lead = h;
        break;
    };
    const l = lead orelse return;
    const la = world.actorOf(l);
    const m = floor_mod.floorMap(self, la.map) orelse return;
    const cs = level_files.WalkMap.cell_size;
    const lp = self.screenPos(l);
    const lc = nav.cellOf(lp);
    var r: i32 = 2;
    while (r <= 6) : (r += 1) {
        var dy: i32 = -r;
        while (dy <= r) : (dy += 1) {
            var dx: i32 = -r;
            while (dx <= r) : (dx += 1) {
                if (@max(@abs(dx), @abs(dy)) != r) continue;
                const c = [2]i32{ lc[0] + dx, lc[1] + dy };
                if (!nav.walkable(m, c[0], c[1])) continue;
                const bg = nav.center(c);
                // Not on a companion: more than two cells from each one standing.
                var busy = false;
                for (party) |h| if (h != o and world.actorOf(h).placed) {
                    const hp = self.screenPos(h);
                    if (std.math.hypot(hp[0] - bg[0], hp[1] - bg[1]) < 2 * cs) busy = true;
                };
                if (busy) continue;
                a.map = la.map;
                a.placed = true;
                fields.setPos(o, floor_mod.groundPoint(self, m, bg));
                fields.setAngle(o, fields.angle(l));
                a.pickIdle(self.crt());
                return;
            }
        }
    }
}

fn segDist(p: [2]f32, a: [2]f32, b: [2]f32) f32 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const l2 = dx * dx + dy * dy;
    const t = if (l2 == 0) 0 else std.math.clamp(((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / l2, 0, 1);
    return std.math.hypot(p[0] - (a[0] + dx * t), p[1] - (a[1] + dy * t));
}

/// WalkOnSceneryTrack / WALK_ON_SCENERY_TRACK (0x4bff80): the area points at height `h`;
/// the actor stands at point `start` with its angle (third coordinate) and floats along
/// the rest at walk speed (0x422ea0), turning as it goes.
pub fn sceneryTrack(self: *World, o: *Object, track: []const u8, h: f32, start_arg: i32) !void {
    const area = areas.findArea(self, track) orelse return;
    if (area.points.len == 0) return;
    const a = world.actorOf(o);
    a.clearPath();
    const start: usize = @min(@as(usize, @intCast(@max(0, start_arg))), area.points.len - 1);
    const p0 = area.points[start];
    fields.setPos(o, self.cam.unproject(p0[0], p0[1], h));
    fields.setAngle(o, p0[2]);
    for (area.points[start + 1 ..]) |p| {
        const wp = self.cam.unproject(p[0], p[1], h);
        try a.path.append(self.gpa, .{ wp[0], wp[1] });
    }
    a.move_speed = a.speedOf("walk") * self.speedScale();
    // The exe queues the points as commands 0x11; the first actor tick only starts the
    // queue (0x4265bc → 0x423680, no step), so the track moves from the second tick.
    a.delay = 1;
    a.on_track = true;
    a.placed = true;
}

/// PlaceHeroes / PLACEHEROES("area", floor) (0x4bf050): party hero i (panel order) to area
/// point i (0x422b70). Queues and paths are reset first (0x427c10); otherwise a companion
/// sent to the top of a ladder would walk back there after the move.
pub fn placeHeroes(self: *World, area_name: []const u8, floor: i32) void {
    const area = areas.findArea(self, area_name) orelse return;
    const members = self.party();
    for (members.slice(), 0..) |o, k| {
        // avoidEnumerate (unselectable hero — Medusa before joining) doesn't matter here:
        // every enabled party hero is placed.
        if (!o.enabled) continue;
        const n = World.nativeOf(o);
        n.actor.dropCommands(self.crt());
        // More heroes than points: the extra one goes to the area control point (else he
        // would keep the previous location's coordinates, off the map).
        const p = if (k < area.points.len) area.points[k] else [3]f32{ area.control[0], area.control[1], if (area.points.len > 0) area.points[0][2] else 0 };
        n.actor.attached_to = null;
        n.actor.placed = true;
        n.actor.map = if (floor == 1) 1 else 0;
        fields.setPos(o, floor_mod.groundOn(self, n.actor.map, .{ p[0], p[1] }));
        fields.setAngle(o, p[2]);
    }
}

/// Walk to a point; false if unreachable (no route and the goal is far).
pub fn walkToReach(self: *World, hero: *Object, goal: [2]f32) !bool {
    try route.walkTo(self, hero, goal);
    if (world.actorOf(hero).path.items.len > 0) return true;
    const p = self.screenPos(hero);
    return std.math.hypot(p[0] - goal[0], p[1] - goal[1]) < 40;
}

/// Forbid/AllowWalkInArea (0x4bee50 / 0x4bee00): floor cells whose centre is in the area
/// lose or gain the walkable bit.
pub fn setWalkInArea(self: *World, name: []const u8, allow: bool, floor: i32) !void {
    const m = (if (floor == 1) self.walk_map2 else self.walk_map) orelse return;
    const area = areas.findArea(self, name) orelse return;
    const cs: f32 = level_files.WalkMap.cell_size;
    // Opened cells without a height (blocked cells have height 0 in .wm).
    var holes: std.ArrayList(usize) = .empty;
    defer holes.deinit(self.gpa);
    for (0..m.height) |y| for (0..m.width) |x| {
        const px = (num.toF32(x) + 0.5) * cs;
        const py = (num.toF32(y) + 0.5) * cs;
        if (!level_files.areaContains(area, px, py)) continue;
        const i = y * m.width + x;
        if (allow and !m.cells[i].walkable() and m.cells[i].height == 0) try holes.append(self.gpa, i);
        // Only the walkable bit (0x479990); path marks stay.
        if (allow) m.cells[i].kind |= 1 else m.cells[i].kind &= ~@as(@TypeOf(m.cells[i].kind), 1);
    };
    floor_mod.fillHoleHeights(m, holes.items);
    // Area state goes into saves (0x411fa3) and is replayed on load.
    for (self.walk_areas.items) |*wa| if (std.ascii.eqlIgnoreCase(wa.name, area.name) and wa.floor == floor) {
        wa.allow = allow;
        return;
    };
    const a = self.arena_state.allocator();
    try self.walk_areas.append(a, .{ .name = try a.dupe(u8, area.name), .allow = allow, .floor = floor });
}

/// Input gate (0x45bf90): a scene runs (list 0x68b154 not empty), the GUI is in scene
/// mode, or a line is shown — field clicks are ignored.
pub fn playerLocked(self: *const World) bool {
    return self.scene.cutscene or self.scene.runner != null or self.scene.subtitle != null;
}

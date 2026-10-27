//! A scene run to its end on a fresh level, as the game would (its load scene skipped):
//! whether it ends, when each command starts, and what looks wrong — actors and
//! points it names that are not there, placement after PLACE, unknown commands, what it
//! leaves on (fade, panorama, scene mode, looping sounds). gorky-tool `scenes` prints it;
//! the editor's scene page shows it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const game = @import("../game.zig");
const life = @import("life.zig");
const scenes_mod = @import("../scene.zig").scenes;
const scenario = @import("../scene.zig").scenario;
const floor_mod = @import("../world.zig").floor;
const sources = @import("../world.zig").sources;
const start = @import("../world.zig").start;
const archive = @import("../formats.zig").archive;
const fields = @import("../fields.zig");
const World = @import("../state.zig").world.World;
const Object = @import("../script.zig").object.Object;
const model_cache = @import("../actor.zig").model_cache;

/// A command of the scene: its line, name and the ticks it ran (start to the next one's).
const Step = struct { line: u32, name: []const u8, start: u32, end: u32 };

pub const Report = struct {
    /// "ok", "HUNG", "moves" (a WALKTO with nowhere to go), "loadlevel".
    result: []const u8,
    ticks: u32,
    /// "; "-joined.
    issues: []u8,
    trace: []Step,

    pub fn deinit(self: *Report, gpa: Allocator) void {
        gpa.free(self.issues);
        gpa.free(self.trace);
    }
};

/// Scene `name` on level `level`.
pub fn run(io: Io, gpa: Allocator, dat: Io.Dir, models: *model_cache.Cache, level: []const u8, name: []const u8) !Report {
    const eq = std.ascii.eqlIgnoreCase;
    const w = try life.create(io, gpa, dat, level, models, .{});
    defer w.destroy();
    // Skip the level's load scene.
    for (0..3) |_| try game.tick(w);
    var guard: u32 = 0;
    while ((w.scene.runner != null or w.scene.queue.items.len > 0) and guard < 4000) : (guard += 1) {
        if (w.scene.runner) |*sc| sc.skip = true;
        if (w.scene.runner) |sc| if (sc.wait == .moving) {
            w.scene.runner = null;
        };
        try game.tick(w);
    }
    scenes_mod.dropStart(w);
    w.rt.missing_builtins.clearRetainingCapacity();
    w.out.sound_events.clearRetainingCapacity();
    w.out.music_events.clearRetainingCapacity();
    try scenes_mod.startScriptlet(w, name);
    const sc0 = w.scene.runner orelse return error.NotStarted;
    const cmds = sc0.commands;
    const pts = sc0.points;
    // Heroes joining during the game come from their own levels if the scene mentions
    // them (a fresh level has no party).
    const joiners = [_][3][]const u8{
        .{ "MacFadden", "02_serwers", "macfadden.hro" },
        .{ "Medusa", "03__museum_corner", "medusa.hro" },
        .{ "Slavsky", "03_museum_observator", "slavsky.hro" },
        .{ "Hutchens", "04__city_factoryentrance", "hutchens.hro" },
        .{ "BT", "01_port", "bt.hro" },
    };
    for (joiners) |jn| {
        if (w.rt.findObject(jn[0]) != null) continue;
        const used = for (cmds) |c| {
            if (eq(c.arg(0).str(), jn[0])) break true;
        } else false;
        if (!used) continue;
        var pb: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&pb, "{s}/other.dat", .{jn[1]});
        var arc = archive.Archive.open(io, gpa, dat, path) catch continue;
        defer arc.close(io, gpa);
        const e = arc.find(jn[2]) orelse continue;
        const src = try arc.readAlloc(io, gpa, e);
        defer gpa.free(src);
        try sources.addSource(w, jn[2], src);
        const cls = w.rt.loadClass(jn[2]) catch continue;
        const o = try w.addObject(jn[0], cls, .{ .kind = .actor, .hero = true, .hro = true });
        _ = try w.rt.callIfExists(o, "init", &.{});
        try start.actorHooks(w, o);
        o.enabled = true;
    }
    var issues: std.ArrayList(u8) = .empty;
    errdefer issues.deinit(gpa);
    const iw = struct {
        fn add(list: *std.ArrayList(u8), a: Allocator, comptime fmt: []const u8, args: anytype) void {
            if (list.items.len > 0) list.appendSlice(a, "; ") catch {};
            list.print(a, fmt, args) catch {};
        }
    }.add;
    // Actor and point references.
    var placed: std.ArrayList(*Object) = .empty;
    defer placed.deinit(gpa);
    for (cmds) |c| {
        const n = scenario.exeName(c.name);
        const actor_cmds = [_][]const u8{ "PLACE", "WALKTO", "WAITFORACTOR", "ANIMATION", "FAST_ANIMATION", "IDLE_ANIMATION", "WALK_ANIMATION", "ACTORSETSTATE", "ACTOR_GOINDOWN", "WEAPON", "FX_WEAPON", "ATTACK", "VOLTAGE", "ACTOR_MORPH", "ROCKET" };
        for (actor_cmds) |ac| if (eq(n, ac)) {
            const an = c.arg(0).str();
            if (an.len > 0 and an[0] != '#' and w.actorObject(an) == null and w.rt.findObject(an) == null)
                iw(&issues, gpa, "no actor {s} ({s}, line {d})", .{ an, n, c.line });
            break;
        };
        if (eq(n, "PLACE") or eq(n, "WALKTO") or eq(n, "DOLLY")) {
            const pn = if (eq(n, "DOLLY")) c.arg(0).str() else c.arg(1).str();
            const found = for (pts) |p| {
                if (eq(p.name, pn)) break true;
            } else false;
            if (!found) iw(&issues, gpa, "no point {s} ({s}, line {d})", .{ pn, n, c.line });
        }
        if (eq(n, "PLACE")) if (w.actorObject(c.arg(0).str())) |o| {
            for (placed.items) |q| {
                if (q == o) break;
            } else try placed.append(gpa, o);
        };
    }
    // Run, noting when each command starts (the runner's pc passes it).
    var trace: std.ArrayList(Step) = .empty;
    errdefer trace.deinit(gpa);
    var seen_pc: usize = 0;
    var t: u32 = 0;
    var result: []const u8 = "ok";
    var loops: usize = 0;
    var blinks: usize = 0;
    while (t < 20000) : (t += 1) {
        try game.tick(w);
        if (w.scene.runner) |sc| if (std.ascii.eqlIgnoreCase(sc.name, name)) while (seen_pc < sc.pc and seen_pc < cmds.len) : (seen_pc += 1) {
            if (trace.items.len > 0) trace.items[trace.items.len - 1].end = t;
            try trace.append(gpa, .{ .line = cmds[seen_pc].line, .name = scenario.exeName(cmds[seen_pc].name), .start = t, .end = t });
        };
        // A shown actor with no animation is drawn in its rest pose for that tick
        // (a "blink" between two poses).
        for (placed.items) |o| {
            const n = World.nativeOf(o);
            if (!o.enabled or n.deleted or !n.actor.placed or n.actor.anim.len > 0) continue;
            if (blinks < 5) iw(&issues, gpa, "{s} without animation at tick {d}", .{ o.name, t });
            blinks += 1;
        }
        for (w.out.sound_events.items) |se| if (se.loop) {
            loops += 1;
        };
        w.out.sound_events.clearRetainingCapacity();
        if (w.scene.runner) |sc| if (sc.wait == .moving) {
            result = "moves";
            break;
        };
        if (w.flow.pending_level != null and w.scene.runner == null) {
            result = "loadlevel";
            break;
        }
        if (w.scene.runner == null and w.scene.queue.items.len == 0) break;
    }
    if (w.scene.runner) |sc| if (t >= 20000) {
        result = "HUNG";
        const c = if (sc.pc > 0 and sc.pc <= sc.commands.len) sc.commands[sc.pc - 1] else cmds[0];
        const wt: []const u8 = switch (sc.wait) {
            .none => "none",
            .ticks => "ticks",
            .actor => |o| o.name,
            .dialog => "dialog",
            .aba => |o| o.name,
            .moving => "moving",
            .panorama => "panorama",
            .goindown => "goindown",
        };
        iw(&issues, gpa, "stuck in {s} at line {d} {s} wait {s}", .{ sc.name, c.line, c.name, wt });
    };
    // Actors after PLACE.
    for (placed.items) |o| {
        const n = World.nativeOf(o);
        if (!o.enabled or n.deleted) continue;
        if (!n.actor.placed) {
            iw(&issues, gpa, "{s} not placed", .{o.name});
            continue;
        }
        const sp = w.screenPos(o);
        if (start.backgroundSize(w)) |bs| {
            const bw: f32 = @floatFromInt(bs[0]);
            const bh: f32 = @floatFromInt(bs[1]);
            if (sp[0] < 0 or sp[1] < 0 or sp[0] >= bw or sp[1] >= bh) iw(&issues, gpa, "{s} off background at {d:.0},{d:.0}", .{ o.name, sp[0], sp[1] });
        }
        if (floor_mod.floorMap(w, n.actor.map)) |m| {
            const cx: i64 = @intFromFloat(@floor(sp[0] / 8));
            const cy: i64 = @intFromFloat(@floor(sp[1] / 8));
            if (cx >= 0 and cy >= 0 and cx < m.width and cy < m.height) {
                if (!m.at(@intCast(cx), @intCast(cy)).walkable()) iw(&issues, gpa, "{s} on unwalkable cell {d:.0},{d:.0} (map {d})", .{ o.name, sp[0], sp[1], n.actor.map });
            }
            const g = floor_mod.groundOn(w, n.actor.map, sp);
            const z = fields.pos(o)[2];
            if (@abs(z - g[2]) > 30) iw(&issues, gpa, "{s} z {d:.0} vs floor {d:.0}", .{ o.name, z, g[2] });
        }
    }
    var it = w.rt.missing_builtins.iterator();
    while (it.next()) |e| iw(&issues, gpa, "missing {s}", .{e.key_ptr.*});
    if (w.scene.fade_target > 0.5 and result.len == 2) iw(&issues, gpa, "screen left black", .{});
    if (w.scene.panorama) iw(&issues, gpa, "panorama left on", .{});
    if (w.scene.cutscene and result.len == 2) iw(&issues, gpa, "cutscene mode left on", .{});
    if (loops > 0) iw(&issues, gpa, "{d} looping sounds started", .{loops});
    for (w.out.music_events.items) |m| iw(&issues, gpa, "music {s}", .{m.name});
    if (trace.items.len > 0) trace.items[trace.items.len - 1].end = t;
    return .{ .result = result, .ticks = t, .issues = try issues.toOwnedSlice(gpa), .trace = try trace.toOwnedSlice(gpa) };
}

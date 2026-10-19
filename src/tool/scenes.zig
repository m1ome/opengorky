//! gorky-tool `scenes`: each scene to the end, actor placement after PLACE.

const std = @import("std");
const scenes_mod = og.scene.scenes;
const floor_mod = og.world.floor;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const common = @import("common.zig");

/// Scene check: for each "level:scene" pair — a fresh level, the level's load
/// scene is skipped, then the scene runs to the end (at most 20000 ticks).
/// Report: whether it finished (else the command and its wait), actors and points
/// from commands, actor placement after PLACE (off the background, on a blocked cell,
/// z not on the floor), unknown commands, state after the scene (fade, panorama,
/// scene mode, looping sounds).
pub fn checkScenes(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8, pairs: []const []const u8) !void {
    var dat = try common.openDat(io, game_dir, .{});
    defer dat.close(io);
    var models = try og.actor.model_cache.Cache.open(io, gpa, dat);
    defer models.deinit();
    const eq = std.ascii.eqlIgnoreCase;
    for (pairs) |pair| {
        const colon = std.mem.indexOfScalar(u8, pair, ':') orelse continue;
        const level = pair[0..colon];
        const name = pair[colon + 1 ..];
        const w = og.game.life.create(io, gpa, dat, level, &models, .{}) catch |err| {
            try out.print("SCENE {s} {s} | LOADFAIL {t}\n", .{ level, name, err });
            continue;
        };
        defer w.destroy();
        // Skip the level's load scene.
        for (0..3) |_| try og.game.tick(w);
        var guard: u32 = 0;
        while ((w.scene.runner != null or w.scene.queue.items.len > 0) and guard < 4000) : (guard += 1) {
            if (w.scene.runner) |*sc| sc.skip = true;
            if (w.scene.runner) |sc| if (sc.wait == .moving) {
                w.scene.runner = null;
            };
            try og.game.tick(w);
        }
        w.scene.runner = null;
        w.scene.queue.clearRetainingCapacity();
        w.flow.pending_level = null;
        w.scene.cutscene = false;
        w.scene.fade_target = 0;
        w.scene.panorama = false;
        w.rt.missing_builtins.clearRetainingCapacity();
        w.out.sound_events.clearRetainingCapacity();
        w.out.music_events.clearRetainingCapacity();
        scenes_mod.startScriptlet(w, name) catch |err| {
            try out.print("SCENE {s} {s} | NOTFOUND {t}\n", .{ level, name, err });
            continue;
        };
        const sc0 = w.scene.runner orelse {
            try out.print("SCENE {s} {s} | NOTSTARTED\n", .{ level, name });
            continue;
        };
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
            var arc = og.formats.archive.Archive.open(io, gpa, dat, path) catch continue;
            defer arc.close(io, gpa);
            const e = arc.find(jn[2]) orelse continue;
            const src = try arc.readAlloc(io, gpa, e);
            defer gpa.free(src);
            try og.world.sources.addSource(w, jn[2], src);
            const cls = w.rt.loadClass(jn[2]) catch continue;
            const o = try w.addObject(jn[0], cls, .{ .kind = .actor, .hero = true, .hro = true });
            _ = try w.rt.callIfExists(o, "init", &.{});
            try og.world.start.actorHooks(w, o);
            o.enabled = true;
        }
        var issues: std.ArrayList(u8) = .empty;
        defer issues.deinit(gpa);
        const iw = struct {
            fn add(list: *std.ArrayList(u8), a: Allocator, comptime fmt: []const u8, args: anytype) void {
                if (list.items.len > 0) list.appendSlice(a, "; ") catch {};
                list.print(a, fmt, args) catch {};
            }
        }.add;
        // Actor and point references.
        var placed: std.ArrayList(*og.script.object.Object) = .empty;
        defer placed.deinit(gpa);
        for (cmds) |c| {
            const n = og.scene.scenario.exeName(c.name);
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
        // Run.
        var t: u32 = 0;
        var result: []const u8 = "ok";
        var loops: usize = 0;
        while (t < 20000) : (t += 1) {
            try og.game.tick(w);
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
            const n = og.state.world.World.nativeOf(o);
            if (!o.enabled or n.deleted) continue;
            if (!n.actor.placed) {
                iw(&issues, gpa, "{s} not placed", .{o.name});
                continue;
            }
            const sp = w.screenPos(o);
            if (og.world.start.backgroundSize(w)) |bs| {
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
                const z = og.fields.pos(o)[2];
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
        try out.print("SCENE {s} {s} | {s} {d} ticks | {s}\n", .{ level, name, result, t, issues.items });
        try out.flush();
    }
}

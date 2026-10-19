//! gorky-tool `play` inspection commands: read-only dumps of the world (cells, paths,
//! party, variables, hashes) printed between playthrough steps.

const std = @import("std");
const og = @import("opengorky");
const world_mod = og.state.world;
const common = @import("common.zig");
const play = @import("play.zig");
const floor_mod = og.world.floor;

/// Runs an inspection command; null when `cmd` is not one. The bool says whether the
/// hero status line follows (false = the command bailed out early).
pub fn run(g: *play.PlayGame, w: *og.state.world.World, cmd: []const u8, out: *std.Io.Writer) !?bool {
    if (std.mem.startsWith(u8, cmd, "trace:")) {
        // trace:N — N ticks: background point and angle of the selected hero every tick.
        const n = try std.fmt.parseInt(u64, cmd[6..], 10);
        for (0..n) |_| {
            try g.step();
            // g.cur(): a step may switch worlds (battle retry, leaving a battle).
            const ww = g.cur();
            const o = ww.selectedHero() orelse break;
            const p = ww.screenPos(o);
            try out.print("  T {d} {d:.2} {d:.2} {d:.3}\n", .{ ww.ticks, p[0], p[1], og.fields.angle(o) });
        }
        return true;
    }
    if (std.mem.eql(u8, cmd, "cells") or std.mem.startsWith(u8, cmd, "cells:")) {
        // Walkability of cells ±8 around the selected hero (or background point "cells:X,Y")
        // on both floors (# walkable, @ center).
        const hero = w.selectedHero() orelse return false;
        const hp: [2]f32 = if (std.mem.startsWith(u8, cmd, "cells:")) common.parseXY(cmd[6..]) catch .{ 0, 0 } else w.screenPos(hero);
        const hx, const hy = og.world.nav.cellOf(hp);
        for ([_]?og.formats.level_files.WalkMap{ w.walk_map, w.walk_map2 }, 0..) |mm, k| if (mm) |m| {
            try out.print("  floor {d}:\n", .{k});
            var y = hy - 8;
            while (y <= hy + 8) : (y += 1) {
                try out.print("   ", .{});
                var x = hx - 8;
                while (x <= hx + 8) : (x += 1) {
                    const kd = og.world.nav.kindAt(m, x, y);
                    // Link marks (bits 1–2): S start, E end (lowercase on a blocked cell).
                    const ch: u8 = if (x == hx and y == hy) '@' else if (og.world.nav.cellAt(m, .{ x, y }) == null) ' ' else if (kd & 2 != 0) (if (kd & 1 != 0) @as(u8, 'S') else 's') else if (kd & 4 != 0) (if (kd & 1 != 0) @as(u8, 'E') else 'e') else if (kd & 1 != 0) '#' else '.';
                    try out.print("{c}", .{ch});
                }
                try out.print("\n", .{});
            }
        };
        return true;
    }
    if (std.mem.eql(u8, cmd, "reach")) {
        // Which areas are reachable from the selected hero (route to the control point).
        const hero = w.selectedHero() orelse return false;
        const a = world_mod.actorOf(hero);
        const hp = w.screenPos(hero);
        {
            const cx, const cy = og.world.nav.cellOf(hp);
            for ([_]?og.formats.level_files.WalkMap{ w.walk_map, w.walk_map2 }, 0..) |mm, k| if (mm) |m| if (og.world.nav.cellAt(m, .{ cx, cy })) |cell| {
                try out.print("  floor {d}: tile {d},{d} kind {d} height {d}{s}\n", .{ k, cx, cy, cell.kind, cell.height, if (og.state.world.actorOf(hero).map == k) " (current)" else "" });
            };
        }
        for (w.areas) |ar| {
            try og.world.route.walkTo(w, hero, ar.control);
            const ok = a.path.items.len > 0 or std.math.hypot(hp[0] - ar.control[0], hp[1] - ar.control[1]) < 40;
            try out.print("  {s} {s} ({d:.0},{d:.0})\n", .{ if (ok) "+" else "-", ar.name, ar.control[0], ar.control[1] });
            a.clearPath();
        }
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "var:")) {
        // var:OBJECT.VAR — a script variable value.
        const spec = cmd[4..];
        const sep = std.mem.indexOfScalar(u8, spec, '.') orelse return false;
        const o = w.rt.findObject(spec[0..sep]) orelse {
            try out.print("  no object {s}\n", .{spec[0..sep]});
            return false;
        };
        if (o.getVarDyn(spec[sep + 1 ..])) |v| try out.print("  {s} = {any}\n", .{ spec, v.value }) else try out.print("  no variable {s}\n", .{spec});
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "obj:")) {
        // Objects whose name contains the substring: kind, enabled, owner, place.
        for (w.rt.objects.items) |o| {
            if (std.ascii.findIgnoreCase(o.name, cmd[4..]) == null) continue;
            const n = og.state.world.World.nativeOf(o);
            const p = w.screenPos(o);
            try out.print("  {s}: {t} en {} deleted {} hero {} hro {} Owner '{s}' place {d} at {d:.0},{d:.0}\n", .{ o.name, n.kind, o.enabled, n.deleted, n.hero, n.hro, if (o.getVar("Owner") != null) og.fields.owner(o) else "", o.getInt("place"), p[0], p[1] });
        }
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "actor:")) {
        // actor:NAME — animation (frame, repeats, one-shot/detached), queue, background
        // point, angle; scene line and wait.
        const o = w.actorObject(cmd[6..]) orelse return false;
        const a = world_mod.actorOf(o);
        const p = w.screenPos(o);
        try out.print("  [{d}] {s}: anim {s} t {d:.0} repeats {d} oneshot {} detached {} q {d} path {d}/{d} at {d:.0},{d:.0} z {d:.0} floor {d} angle {d:.2} idle '{s}'", .{ w.ticks, o.name, a.anim, a.anim_ticks, a.repeat_left, a.one_shot, a.detached, a.queue.items.len, a.path_index, a.path.items.len, p[0], p[1], og.fields.getF(o, "z"), a.map, og.fields.angle(o), a.forced_idle orelse "" });
        if (w.scene.runner) |sc| try out.print(" | scene {s} {d}/{d} {t}{s}", .{ sc.name, sc.pc, sc.commands.len, sc.wait, if (sc.skip) " skip" else "" });
        try out.print("\n", .{});
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "short:")) {
        // short:HERO — quick-list rows (item, count).
        const hero = w.actorObject(cmd[6..]) orelse return false;
        var buf: [og.inventory.list.max_entries]og.inventory.list.Entry = undefined;
        for (og.inventory.list.shortList(w, hero, &buf), 0..) |e, i| try out.print("  {d}: {s} x{d} owner '{s}'\n", .{ i, e.item.name, e.count, og.fields.owner(e.item) });
        return true;
    }
    if (std.mem.eql(u8, cmd, "inv")) {
        // Hero items: name, owner, place.
        for (w.rt.objects.items) |o| {
            const n = og.state.world.World.nativeOf(o);
            if (n.kind != .item and n.kind != .weapon) continue;
            const owner = w.rt.findObject(og.fields.owner(o)) orelse continue;
            if (!og.state.world.World.nativeOf(owner).hero) continue;
            try out.print("  {s}: {s}, place {d}\n", .{ o.name, owner.name, o.getInt("place") });
        }
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "path:") or std.mem.startsWith(u8, cmd, "route:")) {
        // path:HERO — path points on the background (z, .ap node event); route:X,Y — the
        // selected hero's path to a background point (walkTo without ticking) — same points.
        const o = if (std.mem.startsWith(u8, cmd, "route:")) blk: {
            const h = w.selectedHero() orelse return false;
            try og.world.route.walkTo(w, h, try common.parseXY(cmd[6..]));
            break :blk h;
        } else w.actorObject(cmd[5..]) orelse return false;
        const a = world_mod.actorOf(o);
        for (a.path.items, 0..) |pp, k| {
            const z = if (k < a.path_z.items.len) a.path_z.items[k] else std.math.nan(f32);
            const q = w.cam.project(.{ pp[0], pp[1], if (std.math.isNan(z)) 0 else z });
            const ev = if (k < a.path_events.items.len) a.path_events.items[k] else null;
            try out.print("  {d}{s} {d:.0},{d:.0} z {d:.1}", .{ k, if (k == a.path_index) "*" else "", q.x, q.y, z });
            if (ev) |e| try out.print(" node {s} {d} dir {d}", .{ w.paths[e.path].name, e.no, e.dir });
            try out.print("\n", .{});
        }
        return true;
    }
    if (std.mem.eql(u8, cmd, "party")) {
        const members = w.party();
        const lead = w.selectedHero();
        const lp = if (lead) |l| w.screenPos(l) else [2]f32{ 0, 0 };
        for (members.slice()) |h| {
            const a = world_mod.actorOf(h);
            const p = w.screenPos(h);
            const pc = og.world.nav.cellOf(p);
            try out.print("  cell {d},{d} kind {d}\n", .{ pc[0], pc[1], og.world.nav.kindAt(floor_mod.floorMap(w, a.map).?, pc[0], pc[1]) });
            try out.print("  {s}: en {} placed {} map {d} at {d:.0},{d:.0} dist {d:.0} path {d}/{d} q {d} busy {} anim {s}\n", .{ h.name, h.enabled, a.placed, a.map, p[0], p[1], std.math.hypot(p[0] - lp[0], p[1] - lp[1]), a.path_index, a.path.items.len, a.queue.items.len, a.busy(), a.anim });
        }
        return true;
    }
    if (std.mem.eql(u8, cmd, "statehash")) {
        // Hash of every variable of every object (floats by bits): compare the game run
        // across builds (Debug / ReleaseSafe / ReleaseSmall).
        var h = std.hash.Wyhash.init(0);
        for (w.rt.objects.items) |o| {
            h.update(o.name);
            var it = o.vars.iterator();
            while (it.next()) |e| {
                h.update(og.script.object.nameOf(e.key_ptr.*));
                switch (e.value_ptr.value) {
                    .int => |v| h.update(std.mem.asBytes(&v)),
                    .float => |v| h.update(std.mem.asBytes(&v)),
                    .string => |v| h.update(v),
                }
            }
        }
        try out.print("  [{d}] statehash {x:0>16} ({d} objects)\n", .{ w.ticks, h.final(), w.rt.objects.items.len });
        return true;
    }
    if (std.mem.eql(u8, cmd, "hp")) {
        // Party heroes' health (no healing).
        for (w.rt.objects.items) |h| {
            if (!og.state.world.isHeroActor(h)) continue;
            try out.print("  {s}: hp {d}/{d}\n", .{ h.name, og.fields.hp(h), og.fields.maxHp(h) });
        }
        return true;
    }
    return null;
}

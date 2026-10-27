//! Console commands for the location: travel, scenes, scripts, variables, actor effects.

const std = @import("std");
const game = @import("../game.zig");
const scenes = @import("../scene.zig").scenes;
const spawn_mod = @import("../world.zig").spawn;
const actions = @import("../world.zig").actions;
const areas = @import("../world.zig").areas;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const og_value = @import("../script.zig").value.Value;
const common = @import("common.zig");
const Cmd = common.Cmd;
const Effect = common.Effect;

pub fn run(c: Cmd, w: *World, cmd: []const u8, it: *common.Args, out: *std.Io.Writer) !Effect {
    const eq = std.ascii.eqlIgnoreCase;
    switch (c) {
        .map, .whereami => {
            // Current level: name, battle, scene, selected hero and position.
            try out.print("level {s}{s}, tick {d}\n", .{ w.level_name, if (w.isCombat()) " (battle)" else "", w.ticks });
            if (w.battle) |*b| try out.print("battle: phase {t}, turn {d}\n", .{ b.phase, b.turn });
            if (w.scene.runner) |*s| try out.print("scene {s} (command {d}/{d})\n", .{ s.name, s.pc, s.commands.len });
            if (w.out.dolly) |d| try out.print("camera: DOLLY pending (zoom {d:.2})\n", .{d.zoom orelse 1});
            if (w.flow.pending_level) |pl| try out.print("pending level {s}\n", .{pl});
            if (w.selectedHero()) |h| {
                const p = w.screenPos(h);
                try out.print("hero {s}: bg {d:.0},{d:.0}, floor {d}\n", .{ h.name, p[0], p[1], world_mod.actorOf(h).map });
            }
        },
        .level => {
            const name = it.next() orelse {
                try out.print("level {s}\n", .{w.level_name});
                return common.usage(out, "level <name>");
            };
            w.flow.pending_level = try w.arena_state.allocator().dupe(u8, name);
            try out.print("going to {s}\n", .{name});
        },
        .morph => {
            const o = w.rt.findObject(it.next() orelse "") orelse return common.say(out, "no object\n", .{});
            const cls = it.next() orelse return common.usage(out, "morph <object> <class.mtm> <mesh> [idle]");
            const mesh = it.next() orelse return common.usage(out, "morph <object> <class.mtm> <mesh> [idle]");
            try spawn_mod.morphActor(w, o, cls, mesh, it.next() orelse "");
            try out.print("{s} morphs\n", .{o.name});
        },
        .fxstate => {
            const o = w.rt.findObject(it.next() orelse "") orelse return common.say(out, "no object\n", .{});
            const a = world_mod.actorOf(o);
            const st = it.next() orelse "";
            if (eq(st, "shock")) a.shock() else if (eq(st, "appear")) a.materialize(true) else if (eq(st, "vanish")) a.materialize(false) else if (eq(st, "alpha")) {
                a.alpha = std.fmt.parseInt(u8, it.next() orelse "255", 10) catch 255;
            } else return common.usage(out, "fxstate <object> shock|appear|vanish|alpha N");
            try out.print("{s}: {s}\n", .{ o.name, st });
        },
        .wait => {
            const n = std.fmt.parseInt(u32, it.next() orelse "", 10) catch return common.usage(out, "wait <ticks>");
            for (0..n) |_| try game.tick(w);
            try out.print("{d} ticks\n", .{n});
        },
        .skipscene => {
            try out.print("{s}\n", .{if (scenes.skipScene(w)) "scene skipped" else "cannot skip"});
        },
        .skip => {
            try out.print("{s}\n", .{if (scenes.skipLine(w)) "line skipped" else "no line"});
        },
        .call => {
            const o = w.rt.findObject(it.next() orelse "") orelse return common.say(out, "no object\n", .{});
            const func = it.next() orelse return common.usage(out, "call <obj> <func> [args...]");
            var args: [4]og_value = undefined;
            var n: usize = 0;
            while (it.next()) |a| {
                if (n == args.len) break;
                args[n] = if (std.fmt.parseInt(i32, a, 10)) |v| .{ .int = v } else |_| .{ .string = a };
                n += 1;
            }
            const r = try w.rt.callIfExists(o, func, args[0..n]);
            try out.print("{s}.{s}: {s}\n", .{ o.name, func, if (r == null) "no such function" else "ok" });
        },
        .scene => {
            const name = it.next() orelse return common.usage(out, "scene <name>");
            try scenes.startScriptlet(w, name);
            try out.print("scene {s}\n", .{name});
        },
        .playscene => {
            const name = it.next() orelse return common.usage(out, "playscene <name>");
            // As gorky-tool scenes: the level's start runs (its load scene queued), then
            // that scene and what it left (fade, panorama, a level change) are dropped.
            for (0..3) |_| try game.tick(w);
            scenes.dropStart(w);
            try scenes.startScriptlet(w, name);
            try out.print("scene {s} (the level's own dropped)\n", .{name});
        },
        .click => {
            const x = std.fmt.parseFloat(f32, it.next() orelse "") catch return common.usage(out, "click <x> <y>");
            const y = std.fmt.parseFloat(f32, it.next() orelse "") catch return common.usage(out, "click <x> <y>");
            const ok = try actions.clickPlay(w, .{ x, y }, false);
            try out.print("click {d:.0},{d:.0}: {s}\n", .{ x, y, if (ok) "ok" else "ignored" });
        },
        .get, .set => {
            const o = w.rt.findObject(it.next() orelse "") orelse return common.say(out, "no object\n", .{});
            const vname = it.next() orelse return common.usage(out, "get <object> <var>");
            const v = o.getVarDyn(vname) orelse return common.say(out, "no variable {s}\n", .{vname});
            if (eq(cmd, "set")) {
                const text = it.rest();
                v.value = switch (v.value) {
                    .int => .{ .int = std.fmt.parseInt(i32, text, 10) catch return common.say(out, "integer expected\n", .{}) },
                    .float => .{ .float = std.fmt.parseFloat(f32, text) catch return common.say(out, "number expected\n", .{}) },
                    .string => .{ .string = try w.rt.arena().dupe(u8, text) },
                };
            }
            switch (v.value) {
                .int => |i| try out.print("{s}.{s} = {d}\n", .{ o.name, vname, i }),
                .float => |f| try out.print("{s}.{s} = {d}\n", .{ o.name, vname, f }),
                .string => |t| try out.print("{s}.{s} = \"{s}\"\n", .{ o.name, vname, t }),
            }
        },
        .where => {
            const o = w.rt.findObject(it.next() orelse "") orelse return common.say(out, "no object\n", .{});
            const p = w.screenPos(o);
            if (w.battle) |*b| if (b.fighterOf(o)) |i| {
                const f = b.fighters.items[i];
                try out.print("{s}: tile {d},{d} ", .{ o.name, f.tile[0], f.tile[1] });
            };
            const n = World.nativeOf(o);
            const pick = areas.itemAt(w, p) == o or areas.activeAreaAt(w, p) == o;
            const sw = if (n.actor.scene_weapon) |sw| sw.mesh else "";
            try out.print("bg {d:.0},{d:.0} enabled {} placed {} floor {d} state {d} anim '{s}' pick {} weapon '{s}'\n", .{ p[0], p[1], o.enabled, n.actor.placed, n.actor.map, n.actor.state, n.actor.anim, pick, sw });
        },
        .immunities => {
            w.immunity.table = @splat(0x3fe);
            try out.writeAll("all immunities revealed\n");
        },
        else => unreachable,
    }
    return .none;
}

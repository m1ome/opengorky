//! gorky-tool level probes: `voices`, `items`, `use`, `paths`, `walk`, `world`
//! (run the world), `listen` (level audio to WAV).

const std = @import("std");
const actions_mod = og.world.actions;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const world_mod = og.state.world;
const common = @import("common.zig");

/// Voiced lines: how many lines of all `.dlg` have a file in voice.dat.
pub fn voices(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8) !void {
    var dat = try common.openDat(io, game_dir, .{});
    defer dat.close(io);
    var lang = try og.formats.archive.Archive.open(io, gpa, dat, "common/lang.dat");
    defer lang.close(io, gpa);
    var voice = try og.formats.archive.Archive.open(io, gpa, dat, "common/voice.dat");
    defer voice.close(io, gpa);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var total: usize = 0;
    var found: usize = 0;
    for (lang.entries) |*e| {
        if (!std.ascii.endsWithIgnoreCase(e.name, ".dlg")) continue;
        const d = try og.formats.dialog.parse(a, try lang.readAlloc(io, a, e));
        for (d.lines, 0..) |l, i| {
            var buf: [128]u8 = undefined;
            const name = og.formats.dialog.voiceName(&buf, e.name, l.code, i) catch continue;
            total += 1;
            if (voice.find(name) != null) found += 1 else try out.print("missing {s} ({s})\n", .{ name, l.speaker });
        }
    }
    try out.print("lines {d}, voiced {d}\n", .{ total, found });
}

pub fn levelItems(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8, level: []const u8) !void {
    var dat = try common.openDat(io, game_dir, .{});
    defer dat.close(io);
    const world = try og.game.life.create(io, gpa, dat, level, null, .{});
    defer world.destroy();
    const hero = world.actorObject("Sullivan") orelse return;
    var ground: std.ArrayList(*og.script.object.Object) = .empty;
    defer ground.deinit(gpa);
    for (world.rt.objects.items) |o| if (og.state.world.isGroundItem(o)) try ground.append(gpa, o);
    for (ground.items) |o| {
        try out.print("{s:<24} funcID {d} mesh {s}\n", .{ o.name, o.getInt("funcID"), og.fields.meshFile(o) });
        for (0..2) |_| try og.inventory.box.itemOperation(world, o, hero);
        if (world.act.exploring) |ex| {
            try og.inventory.box.takeAllFromBox(world, ex.box, hero);
            world.act.exploring = null;
        }
    }
    try out.print("Sullivan's backpack:\n", .{});
    var buf: [og.inventory.list.max_entries]og.inventory.list.Entry = undefined;
    for ([_]og.inventory.list.Tab{ .weapons, .medicine, .other }) |t| {
        for (og.inventory.list.list(world, hero, t, &buf)) |e| try out.print("  {t:<8} {s} ×{d} (nameID {d})\n", .{ t, e.item.name, e.count, og.fields.nameId(e.item) });
    }
    try out.print("not implemented: ", .{});
    var it = world.rt.missing_builtins.iterator();
    while (it.next()) |e| try out.print("{s}x{d} ", .{ e.key_ptr.*, e.value_ptr.* });
    try out.print("\n", .{});
}

/// Take an item and use it on an area/item (UseItem), as "Use … on …".
pub fn useItemOn(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8, level: []const u8, item_name: []const u8, target_name: []const u8) !void {
    var dat = try common.openDat(io, game_dir, .{});
    defer dat.close(io);
    const world = try og.game.life.create(io, gpa, dat, level, null, .{});
    defer world.destroy();
    const hero = world.actorObject("Sullivan") orelse return;
    const item = world.rt.findObject(item_name) orelse return out.print("no item {s}\n", .{item_name});
    const target = world.rt.findObject(target_name) orelse return out.print("no object {s}\n", .{target_name});
    if (og.state.world.isGroundItem(item)) try og.inventory.box.itemOperation(world, item, hero);
    try out.print("{s}: owner {s}, place {d}\n", .{ item.name, og.fields.owner(item), item.getInt("place") });
    try out.print("accepts: {}\n", .{actions_mod.accepts(world, target, item)});
    world.act.interaction = .{ .hero = hero, .area = target, .use = item };
    for (0..3) |_| try og.game.tick(world);
    try out.print("scene: {s}\n", .{if (world.scene.runner) |sc| sc.name else "-"});
    var it = world.rt.missing_builtins.iterator();
    try out.print("not implemented: ", .{});
    while (it.next()) |e| try out.print("{s}x{d} ", .{ e.key_ptr.*, e.value_ptr.* });
    try out.print("\n", .{});
}

/// `.ap` paths: walkability of the ends on `.wm`/`.wm2`; floor-change areas.
pub fn levelPaths(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8, name: []const u8) !void {
    var dat = try common.openDat(io, game_dir, .{});
    defer dat.close(io);
    const w = try og.game.life.create(io, gpa, dat, name, null, .{});
    defer w.destroy();
    const walk_maps = [2]?og.formats.level_files.WalkMap{ w.walk_map, w.walk_map2 };
    const kind = struct {
        fn f(m: ?og.formats.level_files.WalkMap, x: f32, y: f32) i32 {
            const mm = m orelse return -1;
            const xi: usize = @intFromFloat(x);
            const yi: usize = @intFromFloat(y);
            if (xi >= mm.width or yi >= mm.height) return -2;
            return mm.at(xi, yi).kind;
        }
    }.f;
    for (w.paths) |p| {
        const l = p.link;
        try out.print("{s:<12} start {d},{d} wm {d} wm2 {d} | end {d},{d} wm {d} wm2 {d} | {d} points, z {d:.1}..{d:.1}\n", .{
            p.name,         l[0],                          l[1],                           kind(walk_maps[0], l[0], l[1]), kind(walk_maps[1], l[0], l[1]),
            l[2],           l[3],                          kind(walk_maps[0], l[2], l[3]), kind(walk_maps[1], l[2], l[3]), p.points.len,
            p.points[0][2], p.points[p.points.len - 1][2],
        });
    }
    for (w.areas) |a| {
        if (std.mem.indexOf(u8, a.name, "Go") == null) continue;
        try out.print("area {s}: control point {d:.0},{d:.0}\n", .{ a.name, a.control[0], a.control[1] });
    }
}

/// Put Sullivan at a background point and send him to the target; movement log.
pub fn walkTest(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8, level: []const u8, from: [2]f32, to: [2]f32, party: bool) !void {
    var dat = try common.openDat(io, game_dir, .{});
    defer dat.close(io);
    var models = try og.actor.model_cache.Cache.open(io, gpa, dat);
    defer models.deinit();
    const world = try og.game.life.create(io, gpa, dat, level, &models, .{});
    defer world.destroy();
    world.scene.cutscene = false;
    world.scene.runner = null;
    const hero = world.actorObject("Sullivan") orelse return;
    const a = world_mod.actorOf(hero);
    og.fields.setPos(hero, world.cam.unproject(from[0], from[1], 0));
    a.placed = true;
    a.attached_to = null;
    {
        const here = world.cam.project(og.fields.pos(hero));
        try out.print("start bg {d:.0},{d:.0}; paths {d}; map {}\n", .{ here.x, here.y, world.paths.len, world.walk_map != null });
        if (world.walk_map) |m| {
            var cells: []?u32 = &.{};
            defer gpa.free(cells);
            const r0 = try og.world.nav.findRoute(gpa, &cells, m, &.{}, .{ here.x, here.y }, to);
            try out.print("no transitions: {}\n", .{r0 != null});
            if (r0) |r| gpa.free(r);
        }
    }
    if (party) {
        _ = try og.world.walk.partyWalk(world, hero, to);
    } else try og.world.route.walkTo(world, hero, to);
    try out.print("path: {d} points\n", .{a.path.items.len});
    for (a.path.items, 0..) |pt, k| {
        const z = if (k < a.path_z.items.len) a.path_z.items[k] else -999;
        const q = world.cam.project(.{ pt[0], pt[1], z });
        if (k < a.path_events.items.len) if (a.path_events.items[k]) |ev| {
            try out.print("  {d}: bg {d:.0},{d:.0} z {d:.0} node {d} dir {d}\n", .{ k, q.x, q.y, z, ev.no, ev.dir });
            continue;
        };
        try out.print("  {d}: bg {d:.0},{d:.0} z {d:.0}\n", .{ k, q.x, q.y, z });
    }
    // Who is measured: the hero, or the whole party walking with it.
    const members = world.party();
    const walkers: []const *og.script.object.Object = if (party) members.slice() else &.{hero};
    // Per walker: ticks moved, and of them with the facing more than 90° off the step —
    // in the world (XY) and on the screen (walking backwards as seen).
    var moved: [8]u32 = @splat(0);
    var backwards: [8]u32 = @splat(0);
    var screen_back: [8]u32 = @splat(0);
    var last_anim: []const u8 = "";
    var last_map: u1 = 0;
    for (0..3000) |t| {
        var before: [8][3]f32 = undefined;
        for (walkers[0..@min(walkers.len, 8)], 0..) |h, k| before[k] = og.fields.pos(h);
        try og.game.tick(world);
        var busy = false;
        for (walkers[0..@min(walkers.len, 8)], 0..) |h, k| {
            busy = busy or world_mod.actorOf(h).busy();
            const after = og.fields.pos(h);
            if (after[0] == before[k][0] and after[1] == before[k][1]) continue;
            moved[k] += 1;
            const ang = og.fields.angle(h);
            const step = og.fields.facing(after[0] - before[k][0], after[1] - before[k][1]);
            if (@abs(og.fields.angleDiff(step, ang)) > std.math.pi / 2.0) backwards[k] += 1;
            const f = og.fields.forwardOf(ang);
            const q0 = world.cam.project(after);
            const q1 = world.cam.project(.{ after[0] + f[0] * 20, after[1] + f[1] * 20, after[2] });
            const qb = world.cam.project(before[k]);
            const mx = q0.x - qb.x;
            const my = q0.y - qb.y;
            if (mx * mx + my * my > 0.01 and mx * (q1.x - q0.x) + my * (q1.y - q0.y) < 0) {
                screen_back[k] += 1;
                try out.print("[{d:>4}] {s} walks backwards on screen: at bg {d:.0},{d:.0} z {d:.0}, facing {d:.2}\n", .{ t, h.name, q0.x, q0.y, after[2], ang });
            }
        }
        const sp = world.screenPos(hero);
        if (!std.mem.eql(u8, a.anim, last_anim) or a.map != last_map or t % 60 == 0) {
            try out.print("[{d:>4}] bg {d:.0},{d:.0} z {d:.1} anim {s} floor {d} point {d}/{d}\n", .{ t, sp[0], sp[1], og.fields.getF(hero, "z"), a.anim, a.map, a.path_index, a.path.items.len });
            last_anim = a.anim;
            last_map = a.map;
        }
        if (!busy and t > 5) break;
    }
    for (walkers[0..@min(walkers.len, 8)], 0..) |h, k| try out.print("{s}: moved {d} ticks, backwards {d} (world), {d} (screen)\n", .{ h.name, moved[k], backwards[k], screen_back[k] });
}

pub fn runWorld(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8, level: []const u8, ticks: u32) !void {
    var dat = try common.openDat(io, game_dir, .{});
    defer dat.close(io);

    var models = try og.actor.model_cache.Cache.open(io, gpa, dat);
    defer models.deinit();
    const world = try og.game.life.create(io, gpa, dat, level, &models, .{});
    defer world.destroy();
    var bank = try og.audio.sound.Bank.open(io, gpa, dat);
    defer bank.deinit();

    // Sounds over all ticks: name → start count; also checks that each sound resolves.
    var sounds: std.StringArrayHashMapUnmanaged(u32) = .empty;
    defer sounds.deinit(gpa);
    var missing_sounds: usize = 0;
    var last_scene: []const u8 = "";
    var last_sub: ?[]const u8 = null;
    for (0..ticks + 1) |t| {
        if (t > 0) try og.game.tick(world);
        // Log: scene changes, new subtitles, hero positions every 5 s.
        const scene_name = if (world.scene.runner) |sc| sc.name else "";
        if (!std.mem.eql(u8, scene_name, last_scene)) {
            try out.print("[{d:>5}] scene '{s}'\n", .{ t, scene_name });
            last_scene = scene_name;
        }
        const sub_text = if (world.scene.subtitle) |st| st.text else null;
        if (sub_text != null and (last_sub == null or sub_text.?.ptr != last_sub.?.ptr)) {
            try out.print("[{d:>5}] {s}: {s}\n", .{ t, world.scene.subtitle.?.speaker, sub_text.? });
        }
        last_sub = sub_text;
        for (world.out.voice_events.items) |v| {
            if (bank.voice(v) == null) try out.print("[{d:>5}] voice not found: {s}\n", .{ t, v });
        }
        world.out.voice_events.clearRetainingCapacity();
        world.out.music_events.clearRetainingCapacity();
        if (t % 150 == 0) {
            for ([_][]const u8{ "ponton", "Sullivan", "Ovitz", "Trantigne" }) |name| {
                const o = world.actorObject(name) orelse continue;
                const n = og.state.world.World.nativeOf(o);
                const sp = world.screenPos(o);
                try out.print("[{d:>5}]   {s:<10} bg {d:>5.0},{d:>5.0} anim '{s}' state {d}{s}{s}\n", .{
                    t,                                                    name,                                        sp[0], sp[1], n.actor.anim, n.actor.state,
                    if (n.actor.attached_to != null) " attached" else "", if (n.actor.placed) "" else " (not placed)",
                });
            }
        }
        for (world.out.drainSounds()) |ev| {
            const gop = try sounds.getOrPut(gpa, ev.name);
            if (!gop.found_existing) {
                gop.value_ptr.* = 0;
                if (bank.effect(ev.name) == null) missing_sounds += 1;
            }
            gop.value_ptr.* += 1;
        }
    }
    var ambients: usize = 0;
    for (world.rt.objects.items) |o| {
        const n = og.state.world.World.nativeOf(o);
        if (n.ambient) |amb| {
            ambients += 1;
            if (bank.effect(amb.wav) == null) missing_sounds += 1;
        }
    }

    try out.print("{s}: {d} objects, {d} ticks\n", .{ level, world.rt.objects.items.len, ticks });
    for (world.rt.objects.items) |o| {
        const n = og.state.world.World.nativeOf(o);
        try out.print("  {s:<28} {t:<17} {s}", .{ o.name, n.kind, if (o.enabled) "on " else "off" });
        if (n.kind == .actor) {
            try out.print("  mesh {s} {s} at {d:.0},{d:.0},{d:.0} angle {d:.2} anim '{s}'", .{
                og.fields.meshFile(o),           if (n.actor.placed) "placed" else "not placed",
                o.getVar("x").?.value.toFloat(), o.getVar("y").?.value.toFloat(),
                o.getVar("z").?.value.toFloat(), o.getVar("angle").?.value.toFloat(),
                n.actor.anim,
            });
        }
        if (n.kind == .animation or n.kind == .active_animation) {
            try out.print("  sprite {s} at {d},{d} frame {d} state {d}{s}", .{
                o.getString("spriteFile"), o.getInt("pos_x"), o.getInt("pos_y"),
                o.getInt("cur_frame"),     o.getInt("state"), if (n.visible) "" else " hidden",
            });
        }
        try out.writeByte('\n');
    }
    try printCounts(out, "not implemented builtins", &world.rt.missing_builtins);
    try printCounts(out, "unknown names", &world.rt.unknown_names);
    try printCounts(out, "objects not in level", &world.debug.missing_objects);
    try printCounts(out, "sounds played", &sounds);
    try out.print("ambients {d}, sounds not found {d}\n", .{ ambients, missing_sounds });
}

fn printCounts(out: *Io.Writer, title: []const u8, map: *const std.StringArrayHashMapUnmanaged(u32)) !void {
    if (map.count() == 0) return;
    try out.print("{s}:", .{title});
    for (map.keys(), map.values()) |k, v| try out.print(" {s}x{d}", .{ k, v });
    try out.writeByte('\n');
}

/// Renders level audio to WAV (16 bit, stereo, 44100 Hz) without an output device.
pub fn listen(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8, level: []const u8, seconds: u32, path: []const u8, center: [2]f32) !void {
    const rate = 44100;
    const tick_hz = og.state.world.tick_hz;
    var dat = try common.openDat(io, game_dir, .{});
    defer dat.close(io);

    const world = try og.game.life.create(io, gpa, dat, level, null, .{});
    defer world.destroy();
    var bank = try og.audio.sound.Bank.open(io, gpa, dat);
    defer bank.deinit();
    var mixer: og.audio.mixer.Mixer = .init(rate);
    defer mixer.deinit(gpa);
    var scene: og.audio.scene.Scene = .init(gpa, &bank, &mixer, .{});
    defer scene.deinit();
    try scene.startMusic(og.game.levelMusic(world));

    const frames_per_tick = rate / tick_hz;
    const total_ticks = seconds * tick_hz;
    var pcm: std.ArrayList(i16) = .empty;
    defer pcm.deinit(gpa);
    var chunk: [frames_per_tick * 2]f32 = undefined;
    var peak: f32 = 0;
    var sum_sq: f64 = 0;
    for (0..total_ticks) |_| {
        try og.game.tick(world);
        if (try scene.update(try og.game.audioInput(world), center)) |bytes| og.scene.scenes.voiceStarted(world, bytes);
        mixer.mix(&chunk);
        for (chunk) |x| {
            peak = @max(peak, @abs(x));
            sum_sq += x * x;
            try pcm.append(gpa, @intFromFloat(x * 32767));
        }
    }

    var wav: Io.Writer.Allocating = .init(gpa);
    defer wav.deinit();
    const w = &wav.writer;
    const data_len: u32 = @intCast(pcm.items.len * 2);
    try w.writeAll("RIFF");
    try w.writeInt(u32, 36 + data_len, .little);
    try w.writeAll("WAVEfmt ");
    try w.writeInt(u32, 16, .little);
    try w.writeInt(u16, 1, .little); // PCM
    try w.writeInt(u16, 2, .little);
    try w.writeInt(u32, rate, .little);
    try w.writeInt(u32, rate * 4, .little);
    try w.writeInt(u16, 4, .little);
    try w.writeInt(u16, 16, .little);
    try w.writeAll("data");
    try w.writeInt(u32, data_len, .little);
    for (pcm.items) |x| try w.writeInt(i16, x, .little);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = wav.written() });

    const rms = @sqrt(sum_sq / @as(f64, @floatFromInt(@max(1, pcm.items.len))));
    try out.print("{s}: {d} s, music '{s}', voices now {d}, peak {d:.3}, rms {d:.3} -> {s}\n", .{
        level, seconds, scene.music_name, mixer.voices.items.len, peak, rms, path,
    });
}

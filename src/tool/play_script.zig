//! gorky-tool `play`: a playthrough script — `;`-separated commands (moves, clicks,
//! battles, transitions, saves, checks); runs on top of `play.PlayGame`.

const std = @import("std");
const actions_mod = og.world.actions;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const common = @import("common.zig");
const play = @import("play.zig");
const inspect = @import("play_inspect.zig");

/// `runUntil` stop conditions.
const Never = struct {
    fn f(_: *play.PlayGame, _: u64) bool {
        return false;
    }
};
const SceneDone = struct {
    fn f(gg: *play.PlayGame, t: u64) bool {
        // A battle started by the scene (LOADLEVEL) belongs to it: wait for it and for
        // the AfterBattle scenes after returning.
        const w = gg.cur();
        return t > 2 and w.scene.runner == null and !w.scene.cutscene and w.battle == null and w.scene.queue.items.len == 0;
    }
};
const Idle = struct {
    fn f(gg: *play.PlayGame, t: u64) bool {
        return t > 2 and gg.heroIdle();
    }
};

fn areaCenter(area: og.formats.level_files.Area) [2]f32 {
    var c: [2]f32 = .{ 0, 0 };
    for (area.points) |p| c = .{ c[0] + p[0], c[1] + p[1] };
    const n: f32 = @floatFromInt(@max(1, area.points.len));
    return .{ c[0] / n, c[1] / n };
}

/// World message ("No ammo" …) — to the log, then cleared.
fn printMessage(w: *og.state.world.World, out: *Io.Writer) !void {
    if (w.out.message) |m| {
        try out.print("  message: {s}\n", .{m});
        w.out.message = null;
    }
}

pub fn playScript(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8, start: []const u8, cmds: []const []const u8) !void {
    var dat = try common.openDat(io, game_dir, .{ .iterate = true });
    defer dat.close(io);
    var models = try og.actor.model_cache.Cache.open(io, gpa, dat);
    defer models.deinit();
    var g: play.PlayGame = .{
        .io = io,
        .gpa = gpa,
        .dat = dat,
        .out = out,
        .game = .{ .io = io, .gpa = gpa, .dat = dat, .models = &models },
        .names = .init(gpa),
    };
    defer g.deinit();
    g.game.loadDialogFont();
    try g.game.setPrev(start);
    _ = try g.game.open(start, .{}, null);
    for (cmds) |cmd| {
        if (g.lost) break;
        if (g.want_saveload) try g.saveLoad();
        g.idle_ticks = 0;
        try out.print("> {s}\n", .{cmd});
        const w = g.cur();
        if (!try runCommand(&g, w, cmd)) continue;
        if (g.cur().selectedHero()) |h| {
            const p = g.cur().screenPos(h);
            try out.print("  ({s}, tick {d}: {s} at {d:.0},{d:.0})\n", .{ g.cur().level_name, g.ticks, h.name, p[0], p[1] });
        }
    }
    try g.collectMissing(g.cur());
    var it = g.missing.iterator();
    try out.print("not implemented: ", .{});
    while (it.next()) |e| try out.print("{s}x{d} ", .{ e.key_ptr.*, e.value_ptr.* });
    try out.print("\n", .{});
    if (g.loop) {
        try out.flush();
        return error.Loop;
    }
    if (g.once and try g.reportTwice()) {
        try out.flush();
        return error.SceneTwice;
    }
}

/// One playthrough command; false skips the hero status line.
fn runCommand(g: *play.PlayGame, w: *og.state.world.World, cmd: []const u8) !bool {
    const out = g.out;
    const io = g.io;
    const gpa = g.gpa;
    if (g.setFlag(cmd)) return true;
    if (try inspect.run(g, w, cmd, out)) |shown| return shown;
    if (std.mem.startsWith(u8, cmd, "wait:")) {
        try g.runUntil(try std.fmt.parseInt(u64, cmd[5..], 10), Never.f);
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "safe:")) {
        // safe:CODE — type the code on the open safe keypad; take what the safe shows.
        if (w.act.safe_box == null) try out.print("  no safe keypad open\n", .{});
        try og.world.actions.enterSafeCode(w, try std.fmt.parseInt(i32, cmd[5..], 10));
        // The door swings, then the window opens (pending_explore).
        try g.runUntil(120, Never.f);
        if (g.cur().act.exploring) |ex| {
            try og.inventory.box.takeAllFromBox(g.cur(), ex.box, ex.hero);
            g.cur().act.exploring = null;
            try out.print("  safe: took all\n", .{});
        } else try out.print("  safe: nothing shown\n", .{});
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "tap:")) {
        // tap:X,Y — a background click without waiting (the selected hero starts moving).
        _ = try actions_mod.click(w, try common.parseXY(cmd[4..]));
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "esc:")) {
        // esc:SCENE — run until the scene starts, then skip it as a player would (Esc).
        var t: u32 = 0;
        while (if (g.cur().scene.runner) |sc| !std.mem.eql(u8, sc.name, cmd[4..]) else true) : (t += 1) {
            if (g.lost or t > 200_000) return true;
            try g.step();
        }
        try out.print("  {s}\n", .{if (og.scene.scenes.skipScene(g.cur())) "skipped" else "cannot skip"});
        return true;
    }
    if (std.mem.eql(u8, cmd, "scene")) {
        try g.runUntil(300_000, SceneDone.f);
        return true;
    }
    if (std.mem.eql(u8, cmd, "loot")) {
        // All ground items go to the selected hero (as a player would collect them).
        const hero = w.selectedHero() orelse return false;
        var n: usize = 0;
        // By index: boxes create their items (Weapon_New) during the walk.
        var i: usize = 0;
        while (i < w.rt.objects.items.len) : (i += 1) {
            const o = w.rt.objects.items[i];
            if (o.host == null or !og.state.world.isGroundItem(o) or o.getInt("funcID") <= 0) continue;
            for (0..2) |_| try og.inventory.box.itemOperation(w, o, hero);
            if (w.act.exploring) |ex| {
                try og.inventory.box.takeAllFromBox(w, ex.box, hero);
                w.act.exploring = null;
            }
            n += 1;
        }
        try out.print("  items: {d}\n", .{n});
        // Finish the hero's queue (Take: animation, then GO functions like BattleFatman
        // at the matrix) — the player waits for it in place; otherwise the next
        // PlaceHeroes (0x427c10) would drop it.
        if (og.state.world.actorOf(hero).queue.items.len > 0) try g.runUntil(3000, Idle.f);
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "loadsave:")) {
        // loadsave:FILE — load a save (its current level).
        const data = try Io.Dir.cwd().readFileAlloc(io, cmd[9..], gpa, .unlimited);
        defer gpa.free(data);
        const nw = try g.game.load(try og.save.Save.parse(gpa, data));
        try out.print("  loaded {s}, hero {s}\n", .{ nw.level_name, nw.selected_hero });
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "level:")) {
        // level:NAME — go to a level with the party (like LEVEL_Load). This is a bare
        // LEVEL_Load without the exit area's PlaceHeroes: the new level's restore()
        // places the party (03_museum_oldship: PlaceHeroes("capt_start") on floor 0,
        // those in MapGoUp on 1), like exit 03m_exit2ships; via
        // 03mob_exit2old_ship (PlaceHeroes("capt_back",1)) — goto:exit2old_ship.
        w.flow.pending_level = try g.names.allocator().dupe(u8, cmd[6..]);
        try g.step();
        return true;
    }
    if (std.mem.eql(u8, cmd, "saveload")) {
        // Save the current level and load it into a fresh world (as the viewer does).
        var sv: og.save.Save = .init(gpa);
        defer sv.deinit();
        sv.current = w.level_name;
        try sv.addWorld(w);
        var text: Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        try sv.write(&text.writer);
        var back = try og.save.Save.parse(gpa, text.written());
        defer back.deinit();
        const hero = try g.names.allocator().dupe(u8, w.selected_hero);
        const name = try g.names.allocator().dupe(u8, w.level_name);
        _ = try g.game.open(name, .{ .hero = hero }, back.find(name).?);
        try out.print("  loaded {s}\n", .{name});
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "savefile:")) {
        // Write the game to a save file (for viewer --load-slot and loadsave:):
        // the current level and the remembered ones, as the viewer does.
        var sv: og.save.Save = .init(gpa);
        defer sv.deinit();
        try g.game.snapshot(&sv);
        var text: Io.Writer.Allocating = .init(gpa);
        defer text.deinit();
        try sv.write(&text.writer);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = cmd[9..], .data = text.written() });
        try out.print("  saved {s}\n", .{cmd[9..]});
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "pclick:")) {
        const t = try common.parseXY(cmd[7..]);
        const tc = og.world.nav.cellOf(t);
        try out.print("  target cell {d},{d} kind {d}\n", .{ tc[0], tc[1], og.world.nav.kindAt(w.walk_map.?, tc[0], tc[1]) });
        const ok = try actions_mod.clickPlay(w, t, false);
        try out.print("  pclick {d:.0},{d:.0}: {} walk_ok {}\n", .{ t[0], t[1], ok, w.walk_ok });
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "cmd:")) {
        // cmd:console line (`console.zig`), "+" is a space: cmd:give+cw_grenade.s+3.
        var line_buf: [256]u8 = undefined;
        const line = line_buf[0..@min(line_buf.len, cmd.len - 4)];
        @memcpy(line, cmd[4..][0..line.len]);
        std.mem.replaceScalar(u8, line, '+', ' ');
        _ = try og.console.run(w, line, out);
        return true;
    }
    if (std.mem.eql(u8, cmd, "refill")) {
        // Debug: full health and +30 ammo in every hero pack.
        og.console.hero.healHeroes(w, null);
        _ = og.console.hero.addAmmo(w, 30, false);
        return true;
    }
    if (std.mem.eql(u8, cmd, "heal")) {
        // Use medicine from backpacks while wounds exceed 15.
        for (w.rt.objects.items) |h| {
            if (!og.state.world.isHeroActor(h)) continue;
            var buf: [og.inventory.list.max_entries]og.inventory.list.Entry = undefined;
            heal: while (og.fields.hp(h) + 15 < og.fields.maxHp(h)) {
                for (og.inventory.list.list(w, h, .medicine, &buf)) |e| {
                    if (og.inventory.medicine.use(h, e.item)) continue :heal;
                }
                break;
            }
            try out.print("  {s}: hp {d}/{d}\n", .{ h.name, og.fields.hp(h), og.fields.maxHp(h) });
        }
        return true;
    }
    if (std.mem.eql(u8, cmd, "heroes")) {
        // Party heroes: shown (enabled, placed), where, which one is selected.
        for (w.rt.objects.items) |h| {
            if (!og.state.world.isHeroActor(h)) continue;
            const p = w.screenPos(h);
            try out.print("  {s}{s}: {s}{s} bg {d:.0},{d:.0}\n", .{ h.name, if (std.ascii.eqlIgnoreCase(h.name, w.selected_hero)) " (selected)" else "", if (h.enabled) "on" else "off", if (og.state.world.actorOf(h).placed) "" else " unplaced", p[0], p[1] });
        }
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "hero:")) {
        og.game.selectHero(w, cmd[5..]);
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "op:")) {
        // op:AREA:N — area action N (1 is funcID1: the elevator "down" button).
        const spec = cmd[3..];
        const sep = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return false;
        const area = og.world.areas.findArea(w, spec[0..sep]) orelse {
            try out.print("  no area {s}\n", .{spec[0..sep]});
            return false;
        };
        const n = try std.fmt.parseInt(u8, spec[sep + 1 ..], 10);
        if (!try actions_mod.clickAction(w, areaCenter(area), n)) try out.print("  no action {d}\n", .{n});
        try g.runUntil(3000, Idle.f);
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "goto:") or std.mem.startsWith(u8, cmd, "click:") or std.mem.startsWith(u8, cmd, "use:")) {
        var target: [2]f32 = undefined;
        var use_item: ?*og.script.object.Object = null;
        var arg = cmd[std.mem.indexOfScalar(u8, cmd, ':').? + 1 ..];
        if (std.mem.startsWith(u8, cmd, "use:")) {
            // use:ITEM:AREA — "Use … on …".
            const sep = std.mem.indexOfScalar(u8, arg, ':') orelse return false;
            w.mouse.use = w.rt.findObject(arg[0..sep]);
            use_item = w.mouse.use;
            if (w.mouse.use == null) try out.print("  no item {s}\n", .{arg[0..sep]});
            arg = arg[sep + 1 ..];
        }
        if (std.mem.startsWith(u8, cmd, "click:")) {
            target = try common.parseXY(arg);
        } else {
            const area = og.world.areas.findArea(w, arg) orelse {
                // Target is a ground item (shooting a canister): its background point.
                if (w.rt.findObject(arg)) |o| if (og.state.world.isGroundItem(o) or og.state.world.World.nativeOf(o).hero) {
                    target = w.screenPos(o);
                    try out.print("  item {s} at {d:.0},{d:.0}\n", .{ o.name, target[0], target[1] });
                    _ = try actions_mod.click(w, target);
                    try printMessage(w, out);
                    try g.runUntil(3000, Idle.f);
                    return false;
                };
                try out.print("  no area {s}\n", .{arg});
                return false;
            };
            target = areaCenter(area);
        }
        const level_before = w.level_name;
        const battles_before = g.battles;
        if (og.world.areas.activeAreaAt(w, target)) |ao| {
            try out.print("  area {s}: funcID {d}, isLevelSwitch {d}\n", .{ ao.name, ao.getInt("funcID"), ao.getInt("isLevelSwitch") });
        } else try out.print("  no active area at point\n", .{});
        if (!try actions_mod.click(w, target)) try out.print("  click rejected (scene)\n", .{});
        if (w.selectedHero()) |h| {
            const hp = w.screenPos(h);
            try out.print("  goal {d:.0},{d:.0} from {d:.0},{d:.0}: path points {d}, floor {d}\n", .{ target[0], target[1], hp[0], hp[1], og.state.world.actorOf(h).path.items.len, og.state.world.actorOf(h).map });
        }
        try printMessage(w, out);
        try g.runUntil(3000, Idle.f);
        // A battle on the way put the heroes back at the level start — walk again.
        var again: u32 = 0;
        while (again < 3 and g.battles != battles_before and !g.lost and std.mem.eql(u8, g.cur().level_name, level_before)) : (again += 1) {
            const bb = g.battles;
            // The item may have come from another level — look it up by name again.
            if (use_item) |it| {
                const again_item = g.cur().rt.findObject(it.name) orelse break;
                // The item is already used up (the battle started UseItem itself) — do not repeat.
                if (og.state.world.World.nativeOf(again_item).deleted) break;
                // Or used up by the script (nameID −1: not pickable, 0x450fa0) — a retry
                // would only leave the use mode on.
                if (og.world.areas.activeAreaAt(g.cur(), target) == null and og.world.areas.itemAt(g.cur(), target) == null) break;
                g.cur().mouse.use = again_item;
            }
            if (!try actions_mod.click(g.cur(), target)) break;
            try g.runUntil(3000, Idle.f);
            if (g.battles == bb) break;
        }
        if (g.cur().act.exploring) |ex| {
            try og.inventory.box.takeAllFromBox(g.cur(), ex.box, ex.hero);
            g.cur().act.exploring = null;
            try out.print("  box: took all\n", .{});
        }
        return true;
    }
    try out.print("  unknown command\n", .{});
    return false;
}

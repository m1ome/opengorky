//! The level's Debug view: the level run without a window from its load
//! (og.logic_trace), with the player's commands if given, and watched tick by
//! tick — a timeline to scrub and play, what its code did up to the tick (variables,
//! objects on and off, scenes and their commands, lines, sounds), its variables'
//! values at the tick, and the actors where they stand on the map.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const c = @import("sdl");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const textedit = @import("textedit.zig");
const Doc = @import("level.zig").Doc;
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;
const Trace = og.logic_trace.Trace;

/// The game's ticks a second.
const rate = 15;

/// The level's Debug run (`app.logic.run`) and the player's commands for the next one.
pub const State = struct {
    run: ?View = null,
    cmds: std.ArrayList(u8) = .empty,
};

pub const View = struct {
    level: []u8,
    tr: Trace,
    tick: u32 = 0,
    playing: bool = false,
    /// When playback last moved a tick.
    last_ms: u64 = 0,
};

/// The run of the open level shown, if any.
pub fn of(app: *App) ?*View {
    const v = &(app.logic.run orelse return null);
    const d = app.doc orelse return null;
    return if (std.mem.eql(u8, v.level, d.name)) v else null;
}

/// The open level run again (saved first: the run reads the game's files).
pub fn run(app: *App) void {
    const d = app.doc orelse return;
    if (app.store.dirty()) {
        app.save();
        if (app.store.dirty()) return;
    }
    var models = og.actor.model_cache.Cache.open(app.io, app.gpa, app.dat) catch |err| return app.setStatus(tx.st_set_failed, .{err});
    defer models.deinit();
    // A battle runs to its end (up to half an hour of play); a location 5 minutes.
    const tr = og.logic_trace.run(app.io, app.gpa, app.dat, &models, d.name, if (d.isBattle()) "" else app.logic.cmds.items, @as(u32, if (d.isBattle()) 30 else 5) * 60 * rate) catch |err| return app.setStatus(tx.st_set_failed, .{err});
    close(app);
    app.logic.run = .{ .level = app.gpa.dupe(u8, d.name) catch return, .tr = tr };
    app.setStatus(tx.lt_done, .{ tr.ticks, tr.events.len });
}

pub fn close(app: *App) void {
    const v = &(app.logic.run orelse return);
    app.gpa.free(v.level);
    v.tr.deinit();
    app.logic.run = null;
}

fn seconds(a: Allocator, t: u32) []const u8 {
    return std.fmt.allocPrint(a, "{d}:{d:0>2}.{d}", .{ t / rate / 60, t / rate % 60, t % rate * 10 / rate }) catch "";
}

/// Under the map: playback, the timeline with its events marked, the commands.
pub fn strip(app: *App, a: Allocator, v: *View) void {
    const last = v.tr.ticks -| 1;
    if (v.playing) {
        const now = c.SDL_GetTicks();
        const n: u32 = @intCast(@min(last, (now -| v.last_ms) * rate / 1000));
        if (n > 0) {
            v.tick = @min(last, v.tick + n);
            v.last_ms = now;
        }
        if (v.tick >= last) v.playing = false;
    }
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 }, .childGap = 8 }, .backgroundColor = theme.header, .border = .{ .color = theme.line, .width = .{ .top = 1 } } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    if (main.toolButton(app, "lt_back", .skip_back, "", false, false)) v.tick -|= 1;
    if (main.toolButton(app, "lt_play", if (v.playing) .pause else .play, "", v.playing, false)) {
        v.playing = !v.playing;
        if (v.tick >= last) v.tick = 0;
        v.last_ms = c.SDL_GetTicks();
    }
    if (main.toolButton(app, "lt_next", .skip_forward, "", false, false)) v.tick = @min(last, v.tick + 1);
    txt(std.fmt.allocPrint(a, "{d} / {d}   {s}", .{ v.tick, last, seconds(a, v.tick) }) catch "", 13, theme.text, font_mod.regular);
    // The timeline: a click or a drag sets the tick.
    const bid = clay.id("lt_bar");
    const bb = clay.box(bid);
    const bw: f32 = if (bb) |b| b.width else 0;
    clay.open(.{ .id = bid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(22) } }, .backgroundColor = theme.field, .cornerRadius = clay.radius(4) });
    if (bb) |b| if (app.down and clay.pointerOver(bid) and b.width > 0) {
        v.tick = @intFromFloat(std.math.clamp((app.mouse[0] - b.x) / b.width, 0, 1) * @as(f32, @floatFromInt(last)));
        v.playing = false;
    };
    const scale = if (last > 0) bw / @as(f32, @floatFromInt(last)) else 0;
    var prev_x: f32 = -10;
    for (v.tr.events) |e| {
        const col = switch (e.kind) {
            .scene, .level, .turn => theme.accent,
            .variable => theme.warn,
            .input => theme.text,
            else => continue,
        };
        const x = @as(f32, @floatFromInt(e.tick)) * scale;
        if (x - prev_x < 3) continue;
        prev_x = x;
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(2), .height = clay.fixed(10) } }, .backgroundColor = col, .floating = .{ .offset = .{ .x = x, .y = 12 }, .attachTo = ui.CLAY_ATTACH_TO_PARENT } });
    }
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(2), .height = clay.fixed(22) } }, .backgroundColor = theme.text, .floating = .{ .offset = .{ .x = @as(f32, @floatFromInt(v.tick)) * scale, .y = 0 }, .attachTo = ui.CLAY_ATTACH_TO_PARENT } });
    clay.close();
    if (main.toolButton(app, "lt_close", .x, "", false, false)) close(app);
    clay.close();
    // The player's commands for the next run (a battle plays itself).
    const battle = if (app.doc) |d| d.isBattle() else false;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    if (battle) {
        txt(tx.get(tx.lt_battle_auto), 12, theme.dim, font_mod.regular);
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    } else {
        txt(tx.get(tx.lt_cmds), 12, theme.dim, font_mod.regular);
        if (textedit.field(app, "lt_cmds", app.logic.cmds.items, 520, "wait:300 goto:trupy click:640,480 hero:Cole op:lift:1")) |nv| {
            app.logic.cmds.clearRetainingCapacity();
            app.logic.cmds.appendSlice(app.gpa, std.mem.trim(u8, nv, " ")) catch {};
        }
    }
    if (main.toolButton(app, "lt_run", .play, tx.get(tx.lt_run), false, true)) run(app);
    clay.close();
    clay.close();
}

/// Beside the map: the variables at the tick (changed ones bright), then what happened
/// up to it, newest first (a click on a row goes to its tick).
pub fn panel(app: *App, a: Allocator, v: *View) void {
    main.panelHeader(tx.alloc(a, tx.lt_title, .{v.tr.events.len}));
    clay.openScroll(.{ .id = clay.id("lt_panel"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 10, .right = 10, .top = 6, .bottom = 10 }, .childGap = 2 } });
    txt(tx.get(tx.lv_title), 13, theme.text, font_mod.bold);
    const vals = v.tr.valuesAt(a, v.tick) catch &.{};
    for (v.tr.vars, vals) |vr, val| {
        const changed = !std.mem.eql(u8, val, vr.start);
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 8 } });
        txt(vr.name, 12, if (changed) theme.text else theme.dim, font_mod.regular);
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
        txt(val, 12, if (changed) theme.warn else theme.dim, if (changed) font_mod.bold else font_mod.regular);
        clay.close();
    }
    clay.leaf(.{ .layout = .{ .sizing = .{ .height = clay.fixed(8) } } });
    txt(tx.get(tx.lt_events), 13, theme.text, font_mod.bold);
    var shown: usize = 0;
    var i = v.tr.events.len;
    while (i > 0 and shown < 300) {
        i -= 1;
        const e = v.tr.events[i];
        if (e.tick > v.tick) continue;
        shown += 1;
        const rid = clay.idi("lt_ev", @intCast(i));
        if (main.clickable(app, .{ .id = rid, .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = 4, .right = 4, .top = 2, .bottom = 2 }, .childGap = 8 }, .backgroundColor = theme.panel }, e.tick == v.tick)) {
            v.tick = e.tick;
            v.playing = false;
        }
        txt(std.fmt.allocPrint(a, "{d}", .{e.tick}) catch "", 11, theme.dim, font_mod.regular);
        const col = switch (e.kind) {
            .scene, .level, .turn => theme.accent_hover,
            .variable => theme.warn,
            .input => theme.text,
            else => theme.dim,
        };
        const body = switch (e.kind) {
            .variable => std.fmt.allocPrint(a, "{s} = {s}", .{ v.tr.vars[e.index].name, e.text }) catch e.text,
            .command => std.fmt.allocPrint(a, "{s}  ({d})", .{ e.text, e.index }) catch e.text,
            .level => std.fmt.allocPrint(a, "-> {s}", .{e.text}) catch e.text,
            else => e.text,
        };
        clay.text(std.fmt.allocPrint(a, "{s}  {s}", .{ tx.get(kindMsg(e.kind)), body }) catch body, .{ .textColor = col, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
        clay.close();
    }
    clay.close();
}

fn kindMsg(k: og.logic_trace.Kind) tx.Msg {
    return switch (k) {
        .input => tx.lt_k_input,
        .variable => tx.lt_k_var,
        .object => tx.lt_k_object,
        .scene => tx.lt_k_scene,
        .command => tx.lt_k_command,
        .line => tx.lt_k_line,
        .sound => tx.lt_k_sound,
        .music => tx.lt_k_music,
        .level => tx.lt_k_level,
        .turn => tx.lt_k_turn,
        .battle => tx.lt_k_battle,
    };
}

/// The actors at the tick on the map, with the last two seconds of their walk.
pub fn draw(app: *App, d: *Doc, v: *const View, rect: c.SDL_FRect) void {
    const n = v.tr.actors.len;
    if (n == 0) return;
    for (v.tr.actors, 0..) |name, k| {
        const p = v.tr.pos[v.tick * n + k];
        if (std.math.isNan(p[0])) continue;
        _ = c.SDL_SetRenderDrawColor(app.r, 255, 90, 200, 230);
        var t = v.tick -| 2 * rate;
        var prev: ?[2]f32 = null;
        while (t <= v.tick) : (t += 1) {
            const q = v.tr.pos[t * n + k];
            if (std.math.isNan(q[0])) {
                prev = null;
                continue;
            }
            const s = d.toScreen(rect, q);
            if (prev) |pp| _ = c.SDL_RenderLine(app.r, pp[0], pp[1], s[0], s[1]);
            prev = s;
        }
        const s = d.toScreen(rect, p);
        _ = c.SDL_RenderFillRect(app.r, &.{ .x = s[0] - 5, .y = s[1] - 5, .w = 10, .h = 10 });
        app.font.draw(app.r, name, font_mod.bold, 13, s[0] + 8, s[1] - 8, .{ 255, 140, 220, 255 });
    }
}

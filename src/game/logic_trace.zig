//! A level run headlessly from its load, tick by tick, with optional player commands,
//! recorded for watching what its code does: every change of the level's variables,
//! objects turned on and off, scenes and their commands, dialogue lines, sounds, music,
//! a level switch — and where each actor stands every tick. The editor's level Debug
//! view scrubs through it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const game = @import("../game.zig");
const life = @import("life.zig");
const scenes_mod = @import("../scene.zig").scenes;
const scenario = @import("../scene.zig").scenario;
const areas = @import("../world.zig").areas;
const actions = @import("../world.zig").actions;
const World = @import("../state.zig").world.World;
const Value = @import("../script.zig").value.Value;
const model_cache = @import("../actor.zig").model_cache;

pub const Kind = enum { input, variable, object, scene, command, line, sound, music, level, turn, battle };

/// `index`: the variable (`vars`) for `.variable`, the command's line for `.command`.
const Event = struct { tick: u32, kind: Kind, index: u32 = 0, text: []const u8 };

/// A level variable and its value after init().
pub const Var = struct { name: []const u8, start: []const u8 };

pub const Trace = struct {
    arena: std.heap.ArenaAllocator,
    ticks: u32,
    vars: []Var,
    events: []Event,
    /// Actors with a position; `pos[t * actors.len + i]`, NaN while not shown.
    actors: [][]const u8,
    pos: [][2]f32,

    pub fn deinit(self: *Trace) void {
        self.arena.deinit();
    }

    /// Variable values after tick `t`.
    pub fn valuesAt(self: *const Trace, a: Allocator, t: u32) ![][]const u8 {
        const out = try a.alloc([]const u8, self.vars.len);
        for (self.vars, out) |v, *o| o.* = v.start;
        for (self.events) |e| {
            if (e.tick > t) break;
            if (e.kind == .variable) out[e.index] = e.text;
        }
        return out;
    }
};

/// Level `level` for `max_ticks` ticks (a battle: until it is won or lost); `commands` (space separated, as gorky-tool play):
/// `wait:N`, `click:X,Y`, `goto:AREA`, `op:AREA:N`, `hero:NAME` (`scene` and other
/// play commands do nothing: every command already waits) — each after the
/// previous one settles (no scene, the hero standing).
pub fn run(io: Io, gpa: Allocator, dat: Io.Dir, models: *model_cache.Cache, level: []const u8, commands: []const u8, max_ticks: u32) !Trace {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const w = try life.create(io, gpa, dat, level, models, .{});
    defer w.destroy();

    var vars: std.ArrayList(Var) = .empty;
    var ids: std.ArrayList(u32) = .empty;
    // The level's own variables: not those of the classes it inherits (engine fields).
    if (w.level) |l| for (l.class.vars.items) |d| {
        const id = d.id orelse continue;
        if (inherited(l.class.parent, id)) continue;
        const v = l.getVarId(id) orelse continue;
        try vars.append(a, .{ .name = try a.dupe(u8, d.name), .start = try show(a, v.value) });
        try ids.append(a, id);
    };
    const last = try a.alloc([]const u8, vars.items.len);
    for (vars.items, last) |v, *o| o.* = v.start;
    var enabled: std.ArrayList(bool) = .empty;
    for (w.rt.objects.items) |o| try enabled.append(a, o.enabled);

    var events: std.ArrayList(Event) = .empty;
    var actors: std.ArrayList([]const u8) = .empty;
    for (w.actorObjects()) |o| try actors.append(a, try a.dupe(u8, o.name));
    var pos: std.ArrayList([2]f32) = .empty;

    // A battle plays itself (both sides by the AI, as gorky-tool battle) and its log —
    // moves, strikes, damage, deaths — becomes events.
    var log: std.Io.Writer.Allocating = .init(a);
    var log_seen: usize = 0;
    var turn: i32 = 0;
    if (w.battle) |*b| {
        w.crt().seed(1);
        b.auto_heroes = true;
        b.lenient_loss = true;
        b.log = &log.writer;
    }

    var it = std.mem.tokenizeAny(u8, commands, " \t\r\n");
    var waiting: u32 = 0;
    var scene: []const u8 = "";
    var pc: usize = 0;
    var line_ticks: u32 = 0;
    var line: ?[*]const u8 = null;
    var t: u32 = 0;
    while (t < max_ticks) : (t += 1) {
        // The next command once the last one has settled.
        w.act.exploring = null; // an opened box is closed at once
        const busy = w.act.interaction != null or w.scene.runner != null or heroBusy(w);
        if (waiting > 0) waiting -= 1 else if (!busy) if (it.next()) |cmd| {
            try events.append(a, .{ .tick = t, .kind = .input, .text = try a.dupe(u8, cmd) });
            waiting = try input(w, cmd);
        };
        try game.tick(w);
        // No one clicks: a line waiting for a click goes after 5 s.
        const text: ?[*]const u8 = if (w.scene.subtitle) |sub| sub.text.ptr else null;
        line_ticks = if (w.scene.line_open and text == line) line_ticks + 1 else 0;
        line = text;
        if (line_ticks > 75) _ = scenes_mod.skipLine(w);

        for (ids.items, 0..) |id, k| {
            const v = (w.level orelse break).getVarId(id) orelse continue;
            const s = try show(a, v.value);
            if (std.mem.eql(u8, s, last[k])) continue;
            last[k] = s;
            try events.append(a, .{ .tick = t, .kind = .variable, .index = @intCast(k), .text = s });
        }
        for (w.rt.objects.items, 0..) |o, k| {
            if (k >= enabled.items.len) try enabled.append(a, o.enabled) else if (enabled.items[k] == o.enabled) continue;
            enabled.items[k] = o.enabled;
            try events.append(a, .{ .tick = t, .kind = .object, .text = try std.fmt.allocPrint(a, "{s} {s}", .{ o.name, if (o.enabled) "on" else "off" }) });
        }
        const now: []const u8 = if (w.scene.runner) |sc| sc.name else "";
        if (!std.mem.eql(u8, now, scene)) {
            if (scene.len > 0) try events.append(a, .{ .tick = t, .kind = .scene, .text = try std.fmt.allocPrint(a, "{s} end", .{scene}) });
            scene = try a.dupe(u8, now);
            pc = 0;
            if (now.len > 0) try events.append(a, .{ .tick = t, .kind = .scene, .text = scene });
        }
        if (w.scene.runner) |sc| while (pc < sc.pc and pc < sc.commands.len) : (pc += 1) {
            const c = sc.commands[pc];
            try events.append(a, .{ .tick = t, .kind = .command, .index = c.line, .text = try a.dupe(u8, scenario.exeName(c.name)) });
        };
        if (w.scene.subtitle) |sub| if (line_ticks == 0 and w.scene.line_open)
            try events.append(a, .{ .tick = t, .kind = .line, .text = try std.fmt.allocPrint(a, "{s}: {s}", .{ sub.speaker, sub.text }) });
        for (w.out.sound_events.items) |se| try events.append(a, .{ .tick = t, .kind = .sound, .text = try a.dupe(u8, se.name) });
        w.out.sound_events.clearRetainingCapacity();
        for (w.out.music_events.items) |m| try events.append(a, .{ .tick = t, .kind = .music, .text = try a.dupe(u8, m.name) });
        w.out.music_events.clearRetainingCapacity();

        for (actors.items) |n| {
            const o = w.actorObject(n);
            const shown = if (o) |ob| ob.enabled and !World.nativeOf(ob).deleted and World.nativeOf(ob).actor.placed else false;
            try pos.append(a, if (shown) w.screenPos(o.?) else .{ std.math.nan(f32), std.math.nan(f32) });
        }
        if (w.battle) |*b| {
            if (b.turn != turn) {
                turn = b.turn;
                try events.append(a, .{ .tick = t, .kind = .turn, .index = @intCast(@max(turn, 0)), .text = try std.fmt.allocPrint(a, "{d}", .{turn}) });
            }
            const written = log.written();
            var lines = std.mem.splitScalar(u8, written[log_seen..], '\n');
            while (lines.next()) |l| if (std.mem.trim(u8, l, " \r").len > 0)
                try events.append(a, .{ .tick = t, .kind = .battle, .text = try a.dupe(u8, std.mem.trim(u8, l, " \r")) });
            log_seen = written.len;
            if (b.phase == .won or b.phase == .lost) {
                try events.append(a, .{ .tick = t, .kind = .level, .text = try std.fmt.allocPrint(a, "battle {t}", .{b.phase}) });
                t += 1;
                break;
            }
        }
        if (w.flow.pending_level) |pl| {
            try events.append(a, .{ .tick = t, .kind = .level, .text = try a.dupe(u8, pl) });
            t += 1;
            break;
        }
    }
    return .{ .arena = arena, .ticks = t, .vars = vars.items, .events = events.items, .actors = actors.items, .pos = pos.items };
}

fn inherited(class: ?*const @import("../script.zig").object.Class, id: u32) bool {
    var cl = class;
    while (cl) |k| : (cl = k.parent) for (k.vars.items) |d| if (d.id == id) return true;
    return false;
}

fn heroBusy(w: *World) bool {
    const h = w.selectedHero() orelse return false;
    return @import("../state.zig").world.actorOf(h).busy();
}

/// One player command; the ticks to wait after it.
fn input(w: *World, cmd: []const u8) !u32 {
    if (std.mem.startsWith(u8, cmd, "wait:")) return std.fmt.parseInt(u32, cmd[5..], 10) catch 0;
    if (std.mem.startsWith(u8, cmd, "hero:")) game.selectHero(w, cmd[5..]);
    if (std.mem.startsWith(u8, cmd, "click:")) {
        const xy = cmd[6..];
        const comma = std.mem.indexOfScalar(u8, xy, ',') orelse return 0;
        const x = std.fmt.parseFloat(f32, xy[0..comma]) catch return 0;
        const y = std.fmt.parseFloat(f32, xy[comma + 1 ..]) catch return 0;
        _ = try actions.click(w, .{ x, y });
    }
    if (std.mem.startsWith(u8, cmd, "goto:")) if (areas.findArea(w, cmd[5..])) |ar| {
        _ = try actions.click(w, center(ar.points));
    };
    if (std.mem.startsWith(u8, cmd, "op:")) {
        const spec = cmd[3..];
        const sep = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return 0;
        const ar = areas.findArea(w, spec[0..sep]) orelse return 0;
        _ = try actions.clickAction(w, center(ar.points), std.fmt.parseInt(u8, spec[sep + 1 ..], 10) catch return 0);
    }
    // The click starts the walk on the next tick.
    return 2;
}

fn center(points: []const [3]f32) [2]f32 {
    var c: [2]f32 = .{ 0, 0 };
    for (points) |p| c = .{ c[0] + p[0], c[1] + p[1] };
    const n: f32 = @floatFromInt(@max(1, points.len));
    return .{ c[0] / n, c[1] / n };
}

fn show(a: Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .int => |i| std.fmt.allocPrint(a, "{d}", .{i}),
        .float => |f| std.fmt.allocPrint(a, "{d}", .{f}),
        .string => |s| std.fmt.allocPrint(a, "\"{s}\"", .{s}),
    };
}

test "valuesAt applies variable events up to the tick" {
    var vars = [_]Var{ .{ .name = "a", .start = "0" }, .{ .name = "b", .start = "1" } };
    var events = [_]Event{ .{ .tick = 3, .kind = .variable, .index = 0, .text = "5" }, .{ .tick = 7, .kind = .variable, .index = 1, .text = "9" } };
    const tr: Trace = .{ .arena = undefined, .ticks = 10, .vars = &vars, .events = &events, .actors = &.{}, .pos = &.{} };
    const at5 = try tr.valuesAt(std.testing.allocator, 5);
    defer std.testing.allocator.free(at5);
    try std.testing.expectEqualStrings("5", at5[0]);
    try std.testing.expectEqualStrings("1", at5[1]);
}

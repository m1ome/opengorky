//! gorky-tool `scenes`: each scene to the end, actor placement after PLACE.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const common = @import("common.zig");

/// Scene check (og.scene_check) for each "level:scene" pair, one line each.
pub fn checkScenes(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8, pairs: []const []const u8) !void {
    var dat = try common.openDat(io, game_dir, .{});
    defer dat.close(io);
    var models = try og.actor.model_cache.Cache.open(io, gpa, dat);
    defer models.deinit();
    for (pairs) |pair| {
        const colon = std.mem.indexOfScalar(u8, pair, ':') orelse continue;
        const level = pair[0..colon];
        const name = pair[colon + 1 ..];
        var rep = og.scene_check.run(io, gpa, dat, &models, level, name) catch |err| {
            try out.print("SCENE {s} {s} | FAIL {t}\n", .{ level, name, err });
            continue;
        };
        defer rep.deinit(gpa);
        try out.print("SCENE {s} {s} | {s} {d} ticks | {s}\n", .{ level, name, rep.result, rep.ticks, rep.issues });
        try out.flush();
    }
}

/// gorky-tool trace: what level `level`'s code does over `ticks` ticks with `commands`.
pub fn trace(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8, level: []const u8, ticks: u32, commands: []const []const u8) !void {
    var dat = try common.openDat(io, game_dir, .{});
    defer dat.close(io);
    var models = try og.actor.model_cache.Cache.open(io, gpa, dat);
    defer models.deinit();
    const cmds = try std.mem.join(gpa, " ", commands);
    defer gpa.free(cmds);
    var tr = try og.logic_trace.run(io, gpa, dat, &models, level, cmds, ticks);
    defer tr.deinit();
    for (tr.events) |e| {
        const name = if (e.kind == .variable) tr.vars[e.index].name else "";
        try out.print("{d:>5} {s:<8} {s}{s}{s}\n", .{ e.tick, @tagName(e.kind), name, if (name.len > 0) " = " else "", e.text });
    }
    try out.print("{d} ticks, {d} events, {d} variables, {d} actors\n", .{ tr.ticks, tr.events.len, tr.vars.len, tr.actors.len });
}

//! opengorky-viewer: the game (`--play`) and a viewer for sprites, backgrounds and levels.
//! Keys: app/keys.zig.
const std = @import("std");
const viewer = @import("app/viewer.zig");
const run = @import("app/run.zig");

pub const std_options: std.Options = .{ .logFn = logFn };

fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    const allowed = switch (viewer.log_level) {
        .none => false,
        .warn => @backingInt(level) <= @backingInt(std.log.Level.warn),
        .info => @backingInt(level) <= @backingInt(std.log.Level.info),
    };
    if (allowed) std.log.defaultLog(level, scope, format, args);
}

pub fn main(init: std.process.Init) !void {
    return run.run(init);
}

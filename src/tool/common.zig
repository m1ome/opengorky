//! Shared bits of gorky-tool commands.

const std = @import("std");
const Io = std.Io;

/// `<game>/dat`; the game dir is closed right away.
pub fn openDat(io: Io, game_dir: []const u8, opts: Io.Dir.OpenOptions) !Io.Dir {
    var game = try Io.Dir.cwd().openDir(io, game_dir, .{});
    defer game.close(io);
    return game.openDir(io, "dat", opts);
}

/// "X,Y" — a background point.
pub fn parseXY(s: []const u8) ![2]f32 {
    var it = std.mem.splitScalar(u8, s, ',');
    return .{ try std.fmt.parseFloat(f32, it.next() orelse "0"), try std.fmt.parseFloat(f32, it.next() orelse "0") };
}

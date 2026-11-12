//! Sounds from their files: `sounds/…` (effects), `music/…` and `voice/…` (speech) by
//! the bank's Classic names (loaders/assets.zig; `common/sound.dat`, `common/voice.dat`),
//! decoded (formats/sound.zig) into the core's sounds for its bank
//! (audio/sound.zig `Bank`) and for clients that play their own (video, the editor).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const archive = @import("../formats.zig").archive;
const assets = @import("../loaders.zig").assets;
const decode_fmt = @import("../formats.zig").sound;
const sound = @import("../audio.zig").sound;

const Files = struct {
    gpa: Allocator,
    assets: assets.Stack,

    /// The bank's name `name` of `which` as its asset path (in `buf`).
    fn path(buf: []u8, which: sound.Which, name: []const u8) ?[]const u8 {
        return assets.fromEntry(buf, archive_of[@backingInt(which)], name);
    }
};

const archive_of = [_][]const u8{ "common/sound.dat", "common/voice.dat" };

/// The core's sound bank over `dat`'s sounds (its deinit closes them).
pub fn open(io: Io, gpa: Allocator, dat: Io.Dir) !sound.Bank {
    var s: assets.Stack = try @import("../loaders.zig").assetStack(io, gpa, dat);
    errdefer s.deinit();
    // Both archives or no bank (as before the stack).
    for (archive_of) |p| _ = try s.archiveOf(p);
    const f = try gpa.create(Files);
    f.* = .{ .gpa = gpa, .assets = s };
    return .init(gpa, .{ .ctx = f, .size = sizeOf, .load = load, .close = close });
}

/// A sound file's bytes (WAV, MP3) as the core's sound, samples in `gpa`.
pub fn decode(gpa: Allocator, bytes: []const u8) !sound.Sound {
    const s = try decode_fmt.decode(gpa, bytes);
    return .{ .channels = s.channels, .rate = s.rate, .samples = s.samples };
}

/// The index of archive `which` of a bank `open` made (the editor's sound lists).
pub fn archiveOf(b: *const sound.Bank, which: sound.Which) *const archive.Archive {
    // `open` opened both.
    return filesOf(b.source.ctx).assets.archiveOf(archive_of[@backingInt(which)]) catch unreachable;
}

fn filesOf(ctx: ?*anyopaque) *Files {
    return @ptrCast(@alignCast(ctx.?));
}

fn sizeOf(ctx: ?*anyopaque, which: sound.Which, name: []const u8) ?u32 {
    var buf: [assets.max_path]u8 = undefined;
    const size = filesOf(ctx).assets.size(Files.path(&buf, which, name) orelse return null) orelse return null;
    return std.math.cast(u32, size);
}

fn load(ctx: ?*anyopaque, gpa: Allocator, which: sound.Which, name: []const u8) anyerror!sound.Sound {
    const f = filesOf(ctx);
    var buf: [assets.max_path]u8 = undefined;
    const data = try f.assets.read(gpa, Files.path(&buf, which, name) orelse return error.NotFound);
    defer gpa.free(data);
    return decode(gpa, data);
}

fn close(ctx: ?*anyopaque) void {
    const f = filesOf(ctx);
    f.assets.deinit();
    f.gpa.destroy(f);
}

//! Engine sound logic (no output device): sound bank, volume and pan by screen
//! position, ambients, music choice. Reconstructed from gorky17.exe.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const archive = @import("../formats.zig").archive;
const decode = @import("decode.zig");

/// Parameters from adjust.kdt (defaults from the game file).
pub const Params = struct {
    volume_start: f32 = 320,
    volume_falloff: f32 = 0.004,
    pan_start: f32 = 320,
    pan_factor: f32 = 0.0008,
    /// adjust.kdt `dialog_sound_control`: 0 — no voice, lines advance by click.
    dialog_sound: bool = true,
};

/// Sounds quieter than this do not start (0x432608, constant 0.1).
pub const min_volume = 0.1;

pub const Positional = struct { volume: f32, pan: f32 };

/// Volume and pan of a sound at `pos` (background pixels) for a screen centred at
/// `center` (0x432a70). The original projects the point with the 3D camera; on
/// exploration levels these are background coordinates.
pub fn positional(pos: [2]f32, center: [2]f32, p: Params) Positional {
    const dx = pos[0] - center[0];
    const dy = pos[1] - center[1];
    const d = @max(0, @sqrt(dx * dx + dy * dy) - p.volume_start);
    const volume = std.math.clamp(1 - d * p.volume_falloff, 0, 1);
    var pan: f32 = 0;
    if (@abs(dx) > p.pan_start) {
        pan = (if (dx < 0) dx + p.pan_start else dx - p.pan_start) * p.pan_factor;
        pan = std.math.clamp(pan, -0.8, 0.8);
    }
    return .{ .volume = volume, .pan = pan };
}

/// Music candidates for a level in check order (0x41f9b0):
/// `<level>.mp3`, then the district's shared music for sublevels.
pub fn musicCandidates(level: []const u8, buf: *[2][]const u8) [][]const u8 {
    buf[0] = level;
    var n: usize = 1;
    if (std.mem.indexOf(u8, level, "03_museum_") != null) {
        buf[1] = "03_museum";
        n = 2;
    } else if (std.mem.indexOf(u8, level, "01_port_") != null) {
        buf[1] = "01_port";
        n = 2;
    }
    return buf[0..n];
}

/// Sounds by name from `common/sound.dat` (effects) and `common/voice.dat` (music, speech).
pub const Bank = struct {
    gpa: Allocator,
    io: Io,
    sounds: archive.Archive,
    voices: archive.Archive,
    /// Name (lowercase) → sound; null if missing or undecodable.
    cache: std.StringHashMapUnmanaged(?*decode.Sound) = .empty,

    pub fn open(io: Io, gpa: Allocator, dat: Io.Dir) !Bank {
        var sounds = try archive.Archive.open(io, gpa, dat, "common/sound.dat");
        errdefer sounds.close(io, gpa);
        const voices = try archive.Archive.open(io, gpa, dat, "common/voice.dat");
        return .{ .gpa = gpa, .io = io, .sounds = sounds, .voices = voices };
    }

    pub fn deinit(self: *Bank) void {
        var it = self.cache.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.*) |s| {
                s.deinit(self.gpa);
                self.gpa.destroy(s);
            }
            self.gpa.free(e.key_ptr.*);
        }
        self.cache.deinit(self.gpa);
        self.voices.close(self.io, self.gpa);
        self.sounds.close(self.io, self.gpa);
    }

    /// Effect: `name` or `name.wav` (as the engine looks it up, 0x432627).
    pub fn effect(self: *Bank, name: []const u8) ?*const decode.Sound {
        return self.get(self.sounds, name, ".wav");
    }

    pub fn music(self: *Bank, name: []const u8) ?*const decode.Sound {
        return self.get(self.voices, name, ".mp3");
    }

    /// Speech: a `voice.dat` file by full name (`port_arriving_ov_00.wav`).
    pub fn voice(self: *Bank, name: []const u8) ?*const decode.Sound {
        return self.get(self.voices, name, "");
    }

    /// Voice file size in `voice.dat` (bytes; 0 if missing).
    pub fn voiceBytes(self: *Bank, name: []const u8) u32 {
        return if (self.voices.find(name)) |e| e.size else 0;
    }

    pub fn hasMusic(self: *Bank, name: []const u8) bool {
        var buf: [archive.name_size]u8 = undefined;
        const file = std.fmt.bufPrint(&buf, "{s}.mp3", .{name}) catch return false;
        return self.voices.find(file) != null;
    }

    fn get(self: *Bank, arc: archive.Archive, name: []const u8, ext: []const u8) ?*const decode.Sound {
        var key_buf: [archive.name_size]u8 = undefined;
        if (name.len + ext.len > key_buf.len) return null;
        const key = std.ascii.lowerString(&key_buf, name);
        if (self.cache.get(key)) |s| return s;

        var file_buf: [archive.name_size]u8 = undefined;
        const entry = arc.find(name) orelse arc.find(std.fmt.bufPrint(&file_buf, "{s}{s}", .{ name, ext }) catch return null);
        const snd: ?*decode.Sound = if (entry) |e| self.load(arc, e) catch |err| blk: {
            std.log.warn("sound {s}: {t}", .{ name, err });
            break :blk null;
        } else blk: {
            std.log.warn("sound {s}: not found", .{name});
            break :blk null;
        };
        const owned = self.gpa.dupe(u8, key) catch return snd;
        self.cache.put(self.gpa, owned, snd) catch self.gpa.free(owned);
        return snd;
    }

    fn load(self: *Bank, arc: archive.Archive, e: *const archive.Entry) !*decode.Sound {
        const data = try arc.readAlloc(self.io, self.gpa, e);
        defer self.gpa.free(data);
        const s = try self.gpa.create(decode.Sound);
        errdefer self.gpa.destroy(s);
        s.* = try decode.decode(self.gpa, data);
        return s;
    }
};

test positional {
    const p: Params = .{};
    // Within volume_start: full volume; inside the pan dead zone: center.
    try std.testing.expectEqual(Positional{ .volume = 1, .pan = 0 }, positional(.{ 100, 100 }, .{ 0, 0 }, p));
    // 570 px right: d = 250 → 1 - 250*0.004 = 0; pan (570-320)*0.0008 = 0.2.
    const r = positional(.{ 570, 0 }, .{ 0, 0 }, p);
    try std.testing.expectApproxEqAbs(@as(f32, 0), r.volume, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), r.pan, 1e-5);
    // Far left: pan clamps at -0.8.
    try std.testing.expectEqual(@as(f32, -0.8), positional(.{ -5000, 0 }, .{ 0, 0 }, p).pan);
}

test musicCandidates {
    var buf: [2][]const u8 = undefined;
    const a = musicCandidates("01_port_silos", &buf);
    try std.testing.expectEqual(2, a.len);
    try std.testing.expectEqualStrings("01_port", a[1]);
    try std.testing.expectEqual(1, musicCandidates("04_city", &buf).len);
}

//! Decodes game sounds to s16 PCM: WAV (PCM, MS ADPCM) via dr_wav and MP3 via
//! dr_mp3. Voices in `voice.dat` are MP3 under a `.wav` name, so the format is
//! detected from the content.

const std = @import("std");
const Allocator = std.mem.Allocator;

extern fn drwav_open_memory_and_read_pcm_frames_s16(data: *const anyopaque, size: usize, channels: *c_uint, rate: *c_uint, frames: *u64, alloc: ?*const anyopaque) ?[*]i16;
extern fn drwav_free(p: ?*anyopaque, alloc: ?*const anyopaque) void;

const Mp3Config = extern struct { channels: u32, sample_rate: u32 };
extern fn drmp3_open_memory_and_read_pcm_frames_s16(data: *const anyopaque, size: usize, config: *Mp3Config, frames: *u64, alloc: ?*const anyopaque) ?[*]i16;
extern fn drmp3_free(p: ?*anyopaque, alloc: ?*const anyopaque) void;

pub const Sound = struct {
    channels: u32,
    rate: u32,
    /// Interleaved samples, `frames * channels` of them.
    samples: []i16,

    pub fn frames(self: Sound) usize {
        return self.samples.len / self.channels;
    }

    pub fn deinit(self: *Sound, gpa: Allocator) void {
        gpa.free(self.samples);
        self.* = undefined;
    }
};

const Error = error{ BadAudio, UnsupportedChannels } || Allocator.Error;

pub fn decode(gpa: Allocator, bytes: []const u8) Error!Sound {
    if (bytes.len < 4) return error.BadAudio;
    var channels: u32 = 0;
    var rate: u32 = 0;
    var count: u64 = 0;
    const is_riff = std.mem.eql(u8, bytes[0..4], "RIFF");
    const pcm: [*]i16 = if (is_riff) blk: {
        var ch: c_uint = 0;
        var r: c_uint = 0;
        const p = drwav_open_memory_and_read_pcm_frames_s16(bytes.ptr, bytes.len, &ch, &r, &count, null) orelse return error.BadAudio;
        channels = ch;
        rate = r;
        break :blk p;
    } else blk: {
        var cfg: Mp3Config = .{ .channels = 0, .sample_rate = 0 };
        const p = drmp3_open_memory_and_read_pcm_frames_s16(bytes.ptr, bytes.len, &cfg, &count, null) orelse return error.BadAudio;
        channels = cfg.channels;
        rate = cfg.sample_rate;
        break :blk p;
    };
    defer if (is_riff) drwav_free(pcm, null) else drmp3_free(pcm, null);
    if (channels != 1 and channels != 2) return error.UnsupportedChannels;
    if (rate == 0) return error.BadAudio;
    const n: usize = @intCast(count * channels);
    return .{ .channels = channels, .rate = rate, .samples = try gpa.dupe(i16, pcm[0..n]) };
}

test "decode tiny pcm wav" {
    const gpa = std.testing.allocator;
    // RIFF/WAVE, PCM, mono, 8000 Hz, 16 bit, 2 samples.
    const wav = "RIFF" ++ le32(36 + 4) ++ "WAVE" ++ "fmt " ++ le32(16) ++
        le16(1) ++ le16(1) ++ le32(8000) ++ le32(16000) ++ le16(2) ++ le16(16) ++
        "data" ++ le32(4) ++ le16(0x1234) ++ le16(0xfedc);
    var s = try decode(gpa, wav);
    defer s.deinit(gpa);
    try std.testing.expectEqual(1, s.channels);
    try std.testing.expectEqual(8000, s.rate);
    try std.testing.expectEqualSlices(i16, &.{ 0x1234, @bitCast(@as(u16, 0xfedc)) }, s.samples);
}

fn le16(comptime v: u16) [2]u8 {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    return b;
}

fn le32(comptime v: u32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    return b;
}

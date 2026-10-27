//! Decodes game sounds to s16 PCM: WAV (PCM, MS ADPCM) via dr_wav and MP3 via
//! dr_mp3. Voices in `voice.dat` are MP3 under a `.wav` name, so the format is
//! detected from the content. `toPcmWav` writes a sound back as PCM WAV (the editor's
//! imports, in the game's own format).

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

/// RIFF PCM 16-bit mono at `rate`: channels averaged, resampled linearly.
pub fn toPcmWav(gpa: Allocator, s: Sound, rate: u32) Error![]u8 {
    const frames = s.frames();
    if (frames == 0) return error.BadAudio;
    const out_n: usize = @intCast(@as(u64, frames) * rate / s.rate);
    const out = try gpa.alloc(u8, 44 + out_n * 2);
    errdefer gpa.free(out);
    const mono = struct {
        fn at(sm: Sound, i: usize) f32 {
            var sum: f32 = 0;
            for (0..sm.channels) |k| sum += @floatFromInt(sm.samples[i * sm.channels + k]);
            return sum / @as(f32, @floatFromInt(sm.channels));
        }
    };
    for (0..out_n) |i| {
        const pos = @as(f64, @floatFromInt(i)) * @as(f64, @floatFromInt(s.rate)) / @as(f64, @floatFromInt(rate));
        const k: usize = @intFromFloat(pos);
        const f: f32 = @floatCast(pos - @as(f64, @floatFromInt(k)));
        const v0 = mono.at(s, @min(k, frames - 1));
        const v1 = mono.at(s, @min(k + 1, frames - 1));
        const v: i16 = @intFromFloat(std.math.clamp(@round(v0 + (v1 - v0) * f), -32768, 32767));
        std.mem.writeInt(i16, out[44 + i * 2 ..][0..2], v, .little);
    }
    const h = out[0..44];
    @memcpy(h[0..4], "RIFF");
    std.mem.writeInt(u32, h[4..8], @intCast(36 + out_n * 2), .little);
    @memcpy(h[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, h[16..20], 16, .little);
    std.mem.writeInt(u16, h[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, h[22..24], 1, .little); // mono
    std.mem.writeInt(u32, h[24..28], rate, .little);
    std.mem.writeInt(u32, h[28..32], rate * 2, .little);
    std.mem.writeInt(u16, h[32..34], 2, .little);
    std.mem.writeInt(u16, h[34..36], 16, .little);
    @memcpy(h[36..40], "data");
    std.mem.writeInt(u32, h[40..44], @intCast(out_n * 2), .little);
    return out;
}

test "toPcmWav: stereo 44100 to mono 22050 the decoder reads back" {
    const gpa = std.testing.allocator;
    var samples = [_]i16{ 100, 300, 100, 300, 1000, 1000, 1000, 1000 };
    const wav = try toPcmWav(gpa, .{ .channels = 2, .rate = 44100, .samples = &samples }, 22050);
    defer gpa.free(wav);
    var back = try decode(gpa, wav);
    defer back.deinit(gpa);
    try std.testing.expectEqual(1, back.channels);
    try std.testing.expectEqual(22050, back.rate);
    try std.testing.expectEqualSlices(i16, &.{ 200, 1000 }, back.samples);
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

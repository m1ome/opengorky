//! Software mixer: voices with volume, pan and looping, stereo f32 output.
//! No SDL — the output device only pulls ready samples.
//!
//! The original sends volume and pan to Miles `AIL_quick_set_volume`
//! (0..127, pan 0..126, center 63); here they are linear 0..1 and -1..1.
//! shortcut: Miles' volume curve (in the DLL, not the exe) is unknown, linear is
//! used; refine from a recording of the original if the difference is audible.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sound = @import("decode.zig").Sound;

pub const VoiceId = u32;

/// Volume group (settings menu: sfx / music / voice volume).
pub const Category = enum(u2) { sfx, music, voice };

const Voice = struct {
    id: VoiceId,
    sound: *const Sound,
    /// Position in source frames (fractional, for resampling).
    pos: f64 = 0,
    volume: f32 = 1,
    /// -1 left, 0 center, 1 right.
    pan: f32 = 0,
    loop: bool = false,
    category: Category = .sfx,
};

pub const Mixer = struct {
    rate: u32,
    voices: std.ArrayList(Voice) = .empty,
    next_id: VoiceId = 1,
    /// Master volume of effects and music.
    master: f32 = 1,
    /// Group volumes (settings), by `Category`.
    gains: [3]f32 = .{ 1, 1, 1 },
    /// Muted groups (viewer flag --no-sfx); not saved to the settings.
    muted: [3]bool = .{ false, false, false },

    pub fn init(rate: u32) Mixer {
        return .{ .rate = rate };
    }

    pub fn deinit(self: *Mixer, gpa: Allocator) void {
        self.voices.deinit(gpa);
    }

    /// `sound` must outlive the voice.
    /// Effect channels in the exe (0x63bd28): when all are busy a new sound does not play.
    const max_sfx = 16;

    pub fn play(self: *Mixer, gpa: Allocator, sound: *const Sound, volume: f32, pan: f32, loop: bool) Allocator.Error!VoiceId {
        return self.playAs(gpa, .sfx, sound, volume, pan, loop);
    }

    /// Whether an effect channel is free (0x4327f0).
    pub fn sfxFree(self: *const Mixer) bool {
        var n: usize = 0;
        for (self.voices.items) |v| {
            if (v.category == .sfx) n += 1;
        }
        return n < max_sfx;
    }

    pub fn playAs(self: *Mixer, gpa: Allocator, category: Category, sound: *const Sound, volume: f32, pan: f32, loop: bool) Allocator.Error!VoiceId {
        // Speech in the exe is one MP3 channel (0x40eed0 mutes it first, 0x40ec70): a new
        // line cuts the previous one, even one started before a level change.
        if (category == .voice) self.stopCategory(.voice);
        const id = self.next_id;
        self.next_id +%= 1;
        try self.voices.append(gpa, .{ .id = id, .sound = sound, .volume = volume, .pan = pan, .loop = loop, .category = category });
        return id;
    }

    pub fn find(self: *Mixer, id: VoiceId) ?*Voice {
        for (self.voices.items) |*v| if (v.id == id) return v;
        return null;
    }

    /// Stop all voices of a category.
    pub fn stopCategory(self: *Mixer, category: Category) void {
        var i: usize = 0;
        while (i < self.voices.items.len) {
            if (self.voices.items[i].category == category) _ = self.voices.swapRemove(i) else i += 1;
        }
    }

    pub fn stop(self: *Mixer, id: VoiceId) void {
        for (self.voices.items, 0..) |v, i| if (v.id == id) {
            _ = self.voices.swapRemove(i);
            return;
        };
    }

    /// Mixes into `out` (stereo, interleaved L R) and advances the voices.
    pub fn mix(self: *Mixer, out: []f32) void {
        @memset(out, 0);
        const frames = out.len / 2;
        var i: usize = 0;
        while (i < self.voices.items.len) {
            const v = &self.voices.items[i];
            const c = @backingInt(v.category);
            const gain: f32 = if (self.muted[c]) 0 else self.master * self.gains[c];
            const finished = mixVoice(v, out[0 .. frames * 2], self.rate, gain);
            if (finished) _ = self.voices.swapRemove(i) else i += 1;
        }
        for (out) |*s| s.* = std.math.clamp(s.*, -1, 1);
    }

    /// Returns true when the voice has finished.
    fn mixVoice(v: *Voice, out: []f32, out_rate: u32, master: f32) bool {
        const snd = v.sound;
        const total = snd.frames();
        if (total == 0) return true;
        const step = @as(f64, @floatFromInt(snd.rate)) / @as(f64, @floatFromInt(out_rate));
        // Linear pan law: center gives 1.0 to both channels, as in Miles.
        const gain = v.volume * master / 32768.0;
        const left = gain * @min(1, 1 - v.pan);
        const right = gain * @min(1, 1 + v.pan);
        var f: usize = 0;
        while (f < out.len / 2) : (f += 1) {
            if (v.pos >= @as(f64, @floatFromInt(total))) {
                if (!v.loop) return true;
                // The step may exceed the length (short sound, rate above the output).
                v.pos = @mod(v.pos, @as(f64, @floatFromInt(total)));
            }
            const idx: usize = @intFromFloat(v.pos);
            const frac: f32 = @floatCast(v.pos - @as(f64, @floatFromInt(idx)));
            const next = if (idx + 1 < total) idx + 1 else if (v.loop) 0 else idx;
            const l0, const r0 = frameAt(snd, idx);
            const l1, const r1 = frameAt(snd, next);
            out[f * 2] += (l0 + (l1 - l0) * frac) * left;
            out[f * 2 + 1] += (r0 + (r1 - r0) * frac) * right;
            v.pos += step;
        }
        return false;
    }

    fn frameAt(snd: *const Sound, idx: usize) struct { f32, f32 } {
        if (snd.channels == 1) {
            const s: f32 = @floatFromInt(snd.samples[idx]);
            return .{ s, s };
        }
        return .{ @floatFromInt(snd.samples[idx * 2]), @floatFromInt(snd.samples[idx * 2 + 1]) };
    }
};

test "mix mono voice with pan and finish" {
    const gpa = std.testing.allocator;
    var samples = [_]i16{ 16384, 16384 };
    const snd: Sound = .{ .channels = 1, .rate = 100, .samples = &samples };
    var m: Mixer = .init(100);
    defer m.deinit(gpa);
    _ = try m.play(gpa, &snd, 1, 1, false); // full right
    var out: [8]f32 = undefined;
    m.mix(&out);
    try std.testing.expectEqual(@as(f32, 0), out[0]);
    try std.testing.expectEqual(@as(f32, 0.5), out[1]);
    try std.testing.expectEqual(@as(f32, 0.5), out[3]);
    try std.testing.expectEqual(@as(f32, 0), out[5]); // sound ended
    try std.testing.expectEqual(0, m.voices.items.len);
}

test "looping voice keeps playing; resampling halves step" {
    const gpa = std.testing.allocator;
    var samples = [_]i16{ 0, 32767 };
    const snd: Sound = .{ .channels = 1, .rate = 50, .samples = &samples };
    var m: Mixer = .init(100);
    defer m.deinit(gpa);
    const id = try m.play(gpa, &snd, 1, 0, true);
    var out: [16]f32 = undefined;
    m.mix(&out);
    try std.testing.expect(m.find(id) != null);
    // Frame 1 is halfway between 0 and 32767.
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[2], 0.01);
    m.stop(id);
    try std.testing.expect(m.find(id) == null);
}

test "looping voice with step longer than the sound" {
    const gpa = std.testing.allocator;
    var samples = [_]i16{1000};
    const snd: Sound = .{ .channels = 1, .rate = 300, .samples = &samples };
    var m: Mixer = .init(100);
    defer m.deinit(gpa);
    _ = try m.play(gpa, &snd, 1, 0, true);
    var out: [8]f32 = undefined;
    m.mix(&out); // step 3 with length 1: without @mod this reads past the end
    try std.testing.expect(out[2] > 0);
}

test "new speech replaces the previous one" {
    const gpa = std.testing.allocator;
    var samples = [_]i16{ 1, 2, 3 };
    const snd: Sound = .{ .channels = 1, .rate = 100, .samples = &samples };
    var m: Mixer = .init(100);
    defer m.deinit(gpa);
    const a = try m.playAs(gpa, .voice, &snd, 1, 0, false);
    const b = try m.playAs(gpa, .voice, &snd, 1, 0, false);
    try std.testing.expect(m.find(a) == null);
    try std.testing.expect(m.find(b) != null);
}

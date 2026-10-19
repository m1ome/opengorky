//! SDL3 audio output: the main loop fills the stream queue from the mixer.

const std = @import("std");
const og = @import("opengorky");
const c = @import("sdl");
const Mixer = og.audio.mixer.Mixer;

pub const rate = 44100;
/// Queue target: ~60 ms (low latency, slack for an uneven frame); two frames
/// when frames are rare (background, frame cap).
const min_ms = 60;

pub const AudioOut = struct {
    stream: *c.SDL_AudioStream,

    /// null — no audio device; the game runs silently.
    pub fn open() ?AudioOut {
        if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) {
            std.log.warn("audio: {s}", .{c.SDL_GetError()});
            return null;
        }
        const spec: c.SDL_AudioSpec = .{ .format = c.SDL_AUDIO_F32, .channels = 2, .freq = rate };
        const stream = c.SDL_OpenAudioDeviceStream(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, null, null) orelse {
            std.log.warn("audio: {s}", .{c.SDL_GetError()});
            return null;
        };
        _ = c.SDL_ResumeAudioStreamDevice(stream);
        return .{ .stream = stream };
    }

    /// Pause the device (window unfocused): the queue stops until resumed.
    pub fn setPaused(self: *AudioOut, paused: bool) void {
        _ = if (paused) c.SDL_PauseAudioStreamDevice(self.stream) else c.SDL_ResumeAudioStreamDevice(self.stream);
    }

    pub fn close(self: *AudioOut) void {
        c.SDL_DestroyAudioStream(self.stream);
    }

    /// Tops the queue up with mixed audio; `frame_ms` is the time to the next
    /// call (the target is at least two such intervals).
    pub fn pump(self: *AudioOut, mixer: *Mixer, frame_ms: u32) void {
        const target_frames: usize = rate * @as(usize, @max(min_ms, 2 * frame_ms)) / 1000;
        var buf: [1024 * 2]f32 = undefined;
        while (true) {
            const queued_bytes = c.SDL_GetAudioStreamQueued(self.stream);
            if (queued_bytes < 0) return;
            const queued: usize = @as(usize, @intCast(queued_bytes)) / (2 * @sizeOf(f32));
            if (queued >= target_frames) return;
            const frames: usize = @min(buf.len / 2, target_frames - queued);
            const chunk = buf[0 .. frames * 2];
            mixer.mix(chunk);
            if (!c.SDL_PutAudioStreamData(self.stream, chunk.ptr, @intCast(chunk.len * @sizeOf(f32)))) return;
        }
    }
};

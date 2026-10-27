//! World → host requests (viewer, playthrough): sounds, voice, music, videos, camera
//! and player message. The world only writes here; the host drains it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Object = @import("script.zig").object.Object;

/// Video request (AVI_Play, PLAYAVI): name, position, line doubling.
pub const VideoRequest = struct {
    name: []const u8,
    x: i32,
    y: i32,
    double: bool,
    /// Video from after_select_gui (boss fight intro): the exe plays it inside the call
    /// and starts level music afterwards (0x41f973 → 0x40edc0).
    level_music: bool = false,
};

/// Sound requested during a tick; played by the host.
const SoundEvent = struct {
    /// Name in `common/sound.dat`, with or without `.wav`.
    name: []const u8,
    /// Background point; null = unpositioned (volume 1, centred).
    pos: ?[2]f32 = null,
    loop: bool = false,
};

const Music = struct { name: []const u8, once: bool = false };

pub const Outbox = struct {
    sound_events: std.ArrayList(SoundEvent) = .empty,
    /// Delayed sounds (0x4dc490): name, point, ticks left.
    delayed_sounds: std.ArrayList(struct { name: []const u8, pos: ?[2]f32, ticks: u32 }) = .empty,
    /// Dialogue voice lines requested by scenes.
    voice_events: std.ArrayList([]const u8) = .empty,
    /// Music to play; `once` is the 0x40eed0 call flag (+0x48): jingles play once,
    /// MP3_PLAY, menu and credits loop.
    music_events: std.ArrayList(Music) = .empty,
    /// Scene MP3_FADE: fade the music out.
    music_fade: bool = false,
    /// A scene with MP3_PLAY ended: restore the previous music.
    music_restore: bool = false,
    video_requests: std.ArrayList(VideoRequest) = .empty,
    /// Screen shake (EARTHQUAKE): frames left and this frame's offset.
    earthquake: u32 = 0,
    shake: [2]f32 = .{ 0, 0 },
    /// DOLLY(point, time, zoom%): target, time in 1/100 s (0 = instant), zoom.
    dolly: ?struct { to: [2]f32, time: f32, zoom: ?f32 } = null,
    /// ZOOM(percent, time) (0x478220): zoom target; time in 1/100 s as DOLLY's (0 = at
    /// once), null — zoom_speed.
    zoom: ?struct { to: f32, time: ?f32 } = null,
    /// Scene ended: return zoom to 1 (0x4790ad, zoom_speed 0.1).
    zoom_reset: bool = false,
    /// Snap the camera to the selected hero without easing (GUI_NORMAL, PLACEHEROES).
    camera_snap: bool = false,
    /// Battle attack camera (0x47c120): centre of attacker+target box; `release` =
    /// ticks until the zoom returns after the hit.
    attack_cam: ?struct { center: [2]f32, release: ?u32 = null } = null,
    /// Camera pan to the selected hero (0x455490 flag 1 → 0x4c9100): 0x4c8f40 eases the
    /// scroll (0x430200) over 15 ticks (sin(t·π/2)) to its point (+160·aS) minus (320, 240);
    /// skipped when closer than 2 px.
    pan_to: ?*Object = null,
    /// Line or scene skipped: fade the voice (0x40f170, only from 0x459b16 and 0x47922e).
    /// A line ending on its own leaves the voice alone.
    voice_cut: bool = false,
    /// Player message ("Cannot use" etc.).
    message: ?[]const u8 = null,
    /// Ambient emitters, refilled by `game.audioInput` before each audio update.
    ambients: std.ArrayList(Ambient) = .empty,

    const Ambient = struct { obj: *Object, wav: []const u8, pos: [2]f32, active: bool };

    pub fn deinit(self: *Outbox, gpa: Allocator) void {
        self.ambients.deinit(gpa);
        self.sound_events.deinit(gpa);
        self.delayed_sounds.deinit(gpa);
        self.voice_events.deinit(gpa);
        self.music_events.deinit(gpa);
        self.video_requests.deinit(gpa);
    }

    /// Queue a one-shot sound (presentation: a failed append is dropped).
    pub fn sound(self: *Outbox, gpa: Allocator, name: []const u8, pos: ?[2]f32) void {
        self.sound_events.append(gpa, .{ .name = name, .pos = pos }) catch {};
    }

    pub fn drainSounds(self: *Outbox) []SoundEvent {
        const items = self.sound_events.items;
        self.sound_events.items.len = 0;
        return items;
    }
};

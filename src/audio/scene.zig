//! Level audio: music, ambients and script sounds mixed together.
//! The output device belongs to the host (viewer, game).

const std = @import("std");
const num = @import("../num.zig");
const Allocator = std.mem.Allocator;
const sound = @import("sound.zig");
const Mixer = @import("mixer.zig").Mixer;
const VoiceId = @import("mixer.zig").VoiceId;
const Object = @import("../script.zig").object.Object;
const Outbox = @import("../outbox.zig").Outbox;

/// Level music choice, built by `game.levelMusic`.
pub const LevelMusic = struct {
    name: []const u8,
    /// Battle music drawn at level load (`World.battle_music`); null outside battle.
    combat: ?[]const u8,
};

/// Per-update input, built by `game.audioInput`.
pub const Input = struct {
    out: *Outbox,
    ticks: u64,
    /// Null outside battle; else `Battle.enemyMusic()`.
    enemy_music: ?bool,
};

pub const Scene = struct {
    gpa: Allocator,
    bank: *sound.Bank,
    mixer: *Mixer,
    params: sound.Params,
    /// Ambients and their channels; `ttl` — repeat ticks left after fading (+0x1c).
    ambients: std.AutoHashMapUnmanaged(*Object, struct { id: VoiceId, ttl: u8 }) = .empty,
    music: ?VoiceId = null,
    music_name: []const u8 = "",
    /// The current music plays once (a jingle).
    music_once: bool = false,
    /// Level music and whether the enemy battle track is playing.
    level_music: []const u8 = "",
    enemy_track: bool = false,
    /// MP3_FADE (0x40efc0(3, 1)): silence after 90 ticks, no fade.
    fade_end: u64 = 0,
    /// Music before the last MP3_PLAY.
    prev_music: []const u8 = "",
    /// A fade is running (MP3_FADE).
    fading: bool = false,
    /// Start of the voice fade after a skipped line.
    speech_fade: ?u64 = null,
    /// Voice of the current scene line.
    speech: ?VoiceId = null,

    pub fn init(gpa: Allocator, bank: *sound.Bank, mixer: *Mixer, params: sound.Params) Scene {
        return .{ .gpa = gpa, .bank = bank, .mixer = mixer, .params = params };
    }

    /// Stops everything the scene started.
    pub fn deinit(self: *Scene) void {
        var it = self.ambients.valueIterator();
        while (it.next()) |a| self.mixer.stop(a.id);
        self.ambients.deinit(self.gpa);
        if (self.music) |id| self.mixer.stop(id);
        // Speech is not muted: in the exe a level change leaves the speech channel alone;
        // the next line cuts it (Mixer.playAs .voice).
        self.* = undefined;
    }

    /// Level music by the engine rules (see sound.musicCandidates).
    pub fn startMusic(self: *Scene, lm: LevelMusic) !void {
        var buf: [2][]const u8 = undefined;
        const candidates = sound.musicCandidates(lm.name, &buf);
        const name = for (candidates, 0..) |c, i| {
            // The first candidate must exist; the district's shared music is not checked.
            if (i > 0 or self.bank.hasMusic(c)) break c;
        } else lm.combat orelse return;
        try self.switchMusic(self.bank.music(name) orelse return, name, true);
        self.level_music = name;
        self.enemy_track = false;
    }

    /// Switch music: the previous one stops.
    fn switchMusic(self: *Scene, snd: *const @import("decode.zig").Sound, name: []const u8, loop: bool) !void {
        if (self.music) |id| self.mixer.stop(id);
        self.music = try self.mixer.playAs(self.gpa, .music, snd, 1, 0, loop);
        self.music_name = name;
        self.music_once = !loop;
    }

    /// Battle music (0x40edc0): during the enemy turn and their entry `<name>_enemy`
    /// (slot 1), during the player turn `<name>` again (slot 0); switches abruptly.
    fn battleMusic(self: *Scene, enemy_music: ?bool) !void {
        const want = enemy_music orelse return;
        if (!std.mem.startsWith(u8, self.level_music, "battle")) return;
        if (!std.mem.eql(u8, self.music_name, self.level_music) and !self.enemy_track) return;
        if (want == self.enemy_track) return;
        var buf: [32]u8 = undefined;
        const name = if (want) std.fmt.bufPrint(&buf, "{s}_enemy", .{self.level_music}) catch return else self.level_music;
        try self.switchMusic(self.bank.music(name) orelse return, if (want) "" else self.level_music, true);
        self.enemy_track = want;
    }

    /// Script sounds of the elapsed ticks and ambient volumes for a camera centred at
    /// `center` (background pixels). Returns the voice file size of a started line
    /// (0 — voice off) for `scenes.voiceStarted`; null if no line started.
    pub fn update(self: *Scene, in: Input, center: [2]f32) !?u32 {
        const out = in.out;
        // Scene speech has no position. A skipped line fades by 6 % per tick
        // (0x40f170, ≈ 17 ticks); otherwise it plays to the end.
        if (out.voice_cut) if (self.speech) |id| {
            if (self.speech_fade == null) self.speech_fade = in.ticks;
            const k = 1 - 0.06 * num.toF32(in.ticks -| self.speech_fade.?);
            if (self.mixer.find(id)) |v| v.volume = @max(0, k);
            if (k <= 0 or self.mixer.find(id) == null) {
                self.mixer.stop(id);
                self.speech = null;
                self.speech_fade = null;
                out.voice_cut = false;
            }
        } else {
            out.voice_cut = false;
        };
        var voice_bytes: ?u32 = null;
        for (out.voice_events.items) |name| {
            // Without voice the line waits for a click.
            if (!self.params.dialog_sound) {
                voice_bytes = 0;
                continue;
            }
            // Missing file: 0x40f260 gives 0 s, the line waits for a click. The previous
            // voice keeps playing: 0x40f180 stops the old stream only once the new file is
            // found (0x44a690 → 0x40f1b3).
            if (self.bank.voiceBytes(name) == 0) {
                voice_bytes = 0;
                continue;
            }
            const snd = self.bank.voice(name) orelse continue;
            self.speech_fade = null;
            out.voice_cut = false;
            if (self.speech) |id| self.mixer.stop(id);
            self.speech = try self.mixer.playAs(self.gpa, .voice, snd, 1, 0, false);
            voice_bytes = self.bank.voiceBytes(name);
        }
        out.voice_events.clearRetainingCapacity();
        try self.battleMusic(in.enemy_music);
        // MP3_PLAY and jingles (victory, defeat) replace the music (the previous one is
        // remembered); MP3_PLAY loops, jingles play once.
        for (out.music_events.items) |m| {
            const snd = self.bank.music(m.name) orelse continue;
            self.fading = false;
            self.enemy_track = false;
            // A jingle (play-once) never becomes the "previous music", or the end of
            // a scene with MP3_PLAY would loop it.
            if (self.music_name.len > 0 and !self.music_once) self.prev_music = self.music_name;
            try self.switchMusic(snd, m.name, !m.once);
        }
        out.music_events.clearRetainingCapacity();
        // End of a scene with MP3_PLAY (0x478fd0): restore the previous music.
        if (out.music_restore) {
            out.music_restore = false;
            if (self.prev_music.len > 0) if (self.bank.music(self.prev_music)) |snd| {
                self.fading = false;
                try self.switchMusic(snd, self.prev_music, true);
            };
        }
        // MP3_FADE (0x40efc0(3, 1), 0x40eff0): the exe does not apply the fade level to the
        // volume — the music just stops after 90 ticks.
        if (out.music_fade) {
            out.music_fade = false;
            self.fading = true;
            self.fade_end = in.ticks + 90;
        }
        if (self.fading) {
            if (in.ticks >= self.fade_end) {
                if (self.music) |id| self.mixer.stop(id);
                self.music = null;
                self.music_name = "";
                self.fading = false;
            }
        }
        for (out.drainSounds()) |ev| {
            const snd = self.bank.effect(ev.name) orelse continue;
            var p: sound.Positional = .{ .volume = 1, .pan = 0 };
            if (ev.pos) |pos| p = sound.positional(pos, center, self.params);
            if (p.volume <= sound.min_volume) continue;
            if (!self.mixer.sfxFree()) continue;
            _ = try self.mixer.play(self.gpa, snd, p.volume, p.pan, ev.loop);
        }

        for (out.ambients.items) |amb| {
            const o = amb.obj;
            const existing = self.ambients.getPtr(o);
            if (!amb.active) {
                if (existing) |a| {
                    self.mixer.stop(a.id);
                    _ = self.ambients.remove(o);
                }
                continue;
            }
            // Ambient (tick 0x432df0 → 0x432840): own channel with volume and pan;
            // above 0.1 the repeat is extended by 3 ticks (+0x1c = 3); quieter, the repeat
            // is dropped after 3 ticks (0x43277d), the sound finishes and frees the channel.
            // Without a channel: a new one if one of the 16 is free and louder than 0.1 (0x4325b0).
            const p = sound.positional(amb.pos, center, self.params);
            if (existing) |a| {
                if (self.mixer.find(a.id)) |v| {
                    v.volume = p.volume;
                    v.pan = p.pan;
                    if (p.volume > sound.min_volume) {
                        a.ttl = 3;
                    } else if (a.ttl > 0) {
                        a.ttl -= 1;
                        if (a.ttl == 0) v.loop = false;
                    }
                    continue;
                }
                _ = self.ambients.remove(o);
            }
            if (p.volume <= sound.min_volume or !self.mixer.sfxFree()) continue;
            const snd = self.bank.effect(amb.wav) orelse continue;
            const id = try self.mixer.play(self.gpa, snd, p.volume, p.pan, true);
            try self.ambients.put(self.gpa, o, .{ .id = id, .ttl = 3 });
        }
        return voice_bytes;
    }
};

test "a missing voice file gives 0 s: the line waits for a click" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Empty archives: 32-byte header, 0 entries.
    try tmp.dir.createDirPath(io, "common");
    const empty: [32]u8 = @splat(0);
    try tmp.dir.writeFile(io, .{ .sub_path = "common/sound.dat", .data = &empty });
    try tmp.dir.writeFile(io, .{ .sub_path = "common/voice.dat", .data = &empty });
    var bank = try sound.Bank.open(io, gpa, tmp.dir);
    defer bank.deinit();
    var mixer: Mixer = .init(44100);
    defer mixer.deinit(gpa);
    var scene: Scene = .init(gpa, &bank, &mixer, .{});
    defer scene.deinit();
    var out: Outbox = .{};
    defer out.deinit(gpa);
    try out.voice_events.append(gpa, "nofile_00.wav");
    try std.testing.expectEqual(@as(?u32, 0), try scene.update(.{ .out = &out, .ticks = 1, .enemy_music = null }, .{ 0, 0 }));
}

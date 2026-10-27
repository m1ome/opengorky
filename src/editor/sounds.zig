//! Animation frame sounds of a model (`gfx_3d\<mesh>.ani`, every model sharing it):
//! the preview plays them as the game does (a marked frame reached plays its sound,
//! several on one frame — one at random; world/queue.zig), and edits write the `.ani`
//! back in the game's format (formats/anim.zig `writeAni`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const og = @import("opengorky");
const anim = og.formats.anim;
const main = @import("app.zig");
const App = main.App;
const common_archive = @import("store.zig").common_archive;
const sound_archive = "common/sound.dat";

/// Plays effects from `common/sound.dat`, each on its own stream mixed by SDL.
pub const Player = struct {
    bank: ?og.audio.sound.Bank = null,
    dev: c.SDL_AudioDeviceID = 0,
    /// No audio (no device or no sound.dat): stays silent.
    failed: bool = false,
    muted: bool = false,
    streams: std.ArrayList(*c.SDL_AudioStream) = .empty,
    rng: std.Random.DefaultPrng = .init(17),
    /// The last track played alone (music, a line, a video's sound): its stream and
    /// length, for the position shown (null after Stop).
    track: ?struct { name: main.Name(64), stream: *c.SDL_AudioStream, start_ms: u64, len: f32 } = null,

    /// After a save or discard: `sound.dat` changed, its index is read again on next use.
    pub fn reload(self: *Player) void {
        if (self.bank) |*b| b.deinit();
        self.bank = null;
        self.failed = false;
    }

    pub fn deinit(self: *Player, gpa: Allocator) void {
        for (self.streams.items) |s| c.SDL_DestroyAudioStream(s);
        self.streams.deinit(gpa);
        if (self.dev != 0) c.SDL_CloseAudioDevice(self.dev);
        if (self.bank) |*b| b.deinit();
    }

    fn ready(self: *Player, app: *App) bool {
        if (self.failed) return false;
        if (self.bank == null) {
            self.bank = og.audio.sound.Bank.open(app.io, app.gpa, app.dat) catch {
                self.failed = true;
                return false;
            };
        }
        if (self.dev == 0) {
            if (!c.SDL_InitSubSystem(c.SDL_INIT_AUDIO)) {
                self.failed = true;
                return false;
            }
            self.dev = c.SDL_OpenAudioDevice(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, null);
            if (self.dev == 0) self.failed = true;
        }
        return !self.failed;
    }

    /// Everything playing stopped (a long music track).
    pub fn stopAll(self: *Player) void {
        for (self.streams.items) |st| c.SDL_DestroyAudioStream(st);
        self.streams.clearRetainingCapacity();
        self.track = null;
    }

    /// Where the track `name` is (s) and its length; null if it is not the one playing.
    /// Past its end (the stream drained) the position is its length.
    pub fn trackPos(self: *Player, name: []const u8) ?[2]f32 {
        const t = self.track orelse return null;
        if (!std.ascii.eqlIgnoreCase(t.name.get(), name)) return null;
        // Finished streams get destroyed by start(): gone from the list means done.
        const live = std.mem.indexOfScalar(*c.SDL_AudioStream, self.streams.items, t.stream) != null and c.SDL_GetAudioStreamQueued(t.stream) > 0;
        const at: f32 = @as(f32, @floatFromInt(c.SDL_GetTicks() - t.start_ms)) / 1000;
        return .{ if (live) @min(at, t.len) else t.len, t.len };
    }

    /// Effect `name` (`Sfhit.wav` or `Sfhit`) now; `alone`: the others stop and it is
    /// the track (its position shown).
    pub fn play(self: *Player, app: *App, name: []const u8) void {
        self.playEffect(app, name, false);
    }

    pub fn playEffect(self: *Player, app: *App, name: []const u8, alone: bool) void {
        if (!self.ready(app)) return;
        // An imported sound (unsaved) first, then the archive's.
        var own: ?og.audio.decode.Sound = null;
        defer if (own) |*o| o.deinit(app.gpa);
        if (app.store.find(sound_archive, name)) |i| if (!app.store.gone(i)) {
            own = og.audio.decode.decode(app.gpa, app.store.text(i)) catch null;
        };
        const snd = if (own) |*o| o else self.bank.?.effect(std.fs.path.stem(name)) orelse return;
        if (alone) self.playSound(app, name, snd) else self.start(app.gpa, snd);
    }

    /// A sound file's bytes (WAV or MP3) now, alone (a line of speech: the one before stops).
    pub fn playBytes(self: *Player, app: *App, name: []const u8, bytes: []const u8) void {
        if (!self.ready(app)) return;
        var s = og.audio.decode.decode(app.gpa, bytes) catch return;
        defer s.deinit(app.gpa);
        self.playSound(app, name, &s);
    }

    /// Decoded sound `snd` now, alone, as track `name` (its position kept).
    pub fn playSound(self: *Player, app: *App, name: []const u8, snd: *const og.audio.decode.Sound) void {
        if (!self.ready(app)) return;
        self.stopAll();
        self.start(app.gpa, snd);
        if (self.streams.items.len == 0) return;
        var n: main.Name(64) = .{};
        n.set(name);
        self.track = .{ .name = n, .stream = self.streams.items[0], .start_ms = c.SDL_GetTicks(), .len = @as(f32, @floatFromInt(snd.frames())) / @as(f32, @floatFromInt(@max(1, snd.rate))) };
    }

    /// `voice.dat`'s index (null: no audio files).
    pub fn voiceIndex(self: *Player, app: *App) ?*const og.formats.archive.Archive {
        if (self.bank == null) _ = self.ready(app);
        return if (self.bank) |*b| &b.voices else null;
    }

    fn start(self: *Player, gpa: Allocator, snd: *const og.audio.decode.Sound) void {
        // Finished streams go.
        var k = self.streams.items.len;
        while (k > 0) {
            k -= 1;
            if (c.SDL_GetAudioStreamQueued(self.streams.items[k]) > 0) continue;
            c.SDL_DestroyAudioStream(self.streams.swapRemove(k));
        }
        const src: c.SDL_AudioSpec = .{ .format = c.SDL_AUDIO_S16, .channels = @intCast(snd.channels), .freq = @intCast(snd.rate) };
        var dst: c.SDL_AudioSpec = undefined;
        if (!c.SDL_GetAudioDeviceFormat(self.dev, &dst, null)) return;
        const s = c.SDL_CreateAudioStream(&src, &dst) orelse return;
        _ = c.SDL_PutAudioStreamData(s, snd.samples.ptr, @intCast(snd.samples.len * 2));
        _ = c.SDL_FlushAudioStream(s);
        if (!c.SDL_BindAudioStream(self.dev, s)) return c.SDL_DestroyAudioStream(s);
        self.streams.append(gpa, s) catch c.SDL_DestroyAudioStream(s);
    }

    /// The `.wav` names of `common/sound.dat` with the imported ones, sorted.
    pub fn names(self: *Player, app: *App, a: Allocator) []const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        // The bank only: listing needs no audio device (opening one can block).
        if (self.bank == null and !self.failed) self.bank = og.audio.sound.Bank.open(app.io, app.gpa, app.dat) catch blk: {
            self.failed = true;
            break :blk null;
        };
        if (self.bank) |*b| for (b.sounds.entries) |e| {
            if (std.ascii.endsWithIgnoreCase(e.name, ".wav")) out.append(a, e.name) catch {};
        };
        for (app.store.files.items, 0..) |f, i| {
            if (!std.mem.eql(u8, f.archive, sound_archive) or app.store.gone(i)) continue;
            if (self.bank != null and self.bank.?.sounds.find(f.entry) != null) continue;
            out.append(a, f.entry) catch {};
        }
        std.mem.sort([]const u8, out.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.ascii.lessThanIgnoreCase(x, y);
            }
        }.lt);
        return out.items;
    }

    /// The preview went from frame `prev` (null: the animation just started) to `now`
    /// (global frames): the sounds of the frames passed, as the game picks them.
    pub fn frames(self: *Player, app: *App, an: anim.Animation, prev: ?u32, now: u32) void {
        if (self.muted or an.sounds.len == 0) return;
        const from = if (prev) |p| p + 1 else an.first;
        if (prev != null and prev.? == now) return;
        var ranges: [2][2]u32 = .{ .{ from, now }, .{ 1, 0 } };
        if (now < from) ranges = .{ .{ from, an.last }, .{ an.first, now } };
        for (ranges) |rg| {
            var fr = rg[0];
            while (fr <= rg[1]) : (fr += 1) {
                var n: u32 = 0;
                for (an.sounds) |cue| n += @intFromBool(cue.frame == fr);
                if (n == 0) continue;
                var pick = self.rng.random().uintLessThan(u32, n);
                for (an.sounds) |cue| if (cue.frame == fr) {
                    if (pick == 0) {
                        if (!std.ascii.eqlIgnoreCase(std.fs.path.stem(cue.name), "silents")) self.play(app, cue.name);
                        break;
                    }
                    pick -= 1;
                };
            }
        }
    }
};

/// The `.ani` of model `mesh` (Store index) and its animations (caller deinits).
pub fn load(app: *App, mesh: []const u8) ?struct { file: usize, list: anim.AnimList } {
    var buf: [96]u8 = undefined;
    const f = app.store.file(common_archive, std.fmt.bufPrint(&buf, "gfx_3d\\{s}.ani", .{mesh}) catch return null) catch return null;
    const list = anim.parseAni(app.gpa, app.store.text(f)) catch return null;
    return .{ .file = f, .list = list };
}

pub const Op = union(enum) {
    /// Cue `i` moves by `d` frames (kept in the animation).
    move: struct { i: usize, d: i32 },
    remove: usize,
    /// Cue `i` gets sound `name`; null — a new cue at the first frame.
    set: struct { i: ?usize, name: []const u8 },
};

/// Applies `op` to the sounds of animation `ai` of `.ani` file `file` (one undo step).
pub fn edit(app: *App, file: usize, ai: usize, op: Op) !void {
    var list = try anim.parseAni(app.gpa, app.store.text(file));
    defer list.deinit();
    if (ai >= list.items.len) return error.NoAnimation;
    const a = list.arena.allocator();
    const an = &list.items[ai];
    var cues: std.ArrayList(anim.SoundCue) = .empty;
    try cues.appendSlice(a, an.sounds);
    const n = switch (op) {
        .move => |m| m.i,
        .remove => |i| i,
        .set => |s| s.i orelse cues.items.len,
    };
    if (n > cues.items.len or (n == cues.items.len and !(op == .set and op.set.i == null))) return error.NoCue;
    const old: ?anim.SoundCue = if (n < cues.items.len) cues.items[n] else null;
    switch (op) {
        .move => |m| {
            const f: i64 = @as(i64, cues.items[n].frame) + m.d;
            cues.items[n].frame = @intCast(std.math.clamp(f, an.first, an.last));
        },
        .remove => _ = cues.orderedRemove(n),
        .set => |s| if (s.i == null) {
            // As every cue of the game's models: volume 100.
            try cues.append(a, .{ .name = s.name, .frame = an.first, .volume = 100 });
        } else {
            cues.items[n].name = s.name;
        },
    }
    an.sounds = cues.items;
    const new: ?anim.SoundCue = if (op == .remove) null else cues.items[n];
    const bytes = try anim.writeAni(app.gpa, list.items);
    errdefer app.gpa.free(bytes);
    // History: "sfinks.ani: atak, кадр 2 Sfattack1.wav" and the changed cue.
    const entry = app.store.files.items[file].entry;
    const short = entry[if (std.mem.lastIndexOfScalar(u8, entry, '\\')) |k| k + 1 else 0..];
    const shown = new orelse old.?;
    var what: std.ArrayList(u8) = .empty;
    defer what.deinit(app.gpa);
    try what.print(app.gpa, "{s}: {s} {d} {s}{s}", .{ short, an.name, shown.frame - an.first, if (new == null) "− " else "", shown.name });
    if (old) |o| try what.print(app.gpa, "\n-{s} {d}: {s}", .{ an.name, o.frame - an.first, o.name });
    if (new) |w| try what.print(app.gpa, "\n+{s} {d}: {s}", .{ an.name, w.frame - an.first, w.name });
    try app.store.replaceLabeled(file, bytes, what.items);
}

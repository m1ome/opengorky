//! Speech of dialogue lines: `common/voice.dat` files named after the line,
//! `<dlg without .dlg, '-' → '_'>_<speaker code>_<line number, 2 digits>.wav`
//! (formats/dialog.zig `voiceName`). The game's are MP3 under a `.wav` name; one put
//! in is PCM WAV (16 bit, mono, 22050 Hz) — the exe plays both through Miles'
//! `AIL_quick_load_mem`, which tells them by content. The original reads voice.dat
//! from the registry `src` folder.

const std = @import("std");
const tx = @import("text.zig");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const main = @import("app.zig");
const App = main.App;

pub const archive_path = "common/voice.dat";
const rate = 22050;
const max_import = 32 << 20;

/// The bytes of voice file `name`: put in or changed here (unsaved), else the archive's.
pub fn bytesOf(app: *App, a: Allocator, name: []const u8) ?[]const u8 {
    return @import("refs.zig").read(app, a, archive_path, name);
}

/// Voice file names starting with `prefix` (the archive's and the ones put in, not the
/// removed ones), sorted.
pub fn names(app: *App, a: Allocator, prefix: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (app.player.voiceIndex(app)) |ar| for (ar.entries) |e| {
        if (!std.ascii.startsWithIgnoreCase(e.name, prefix)) continue;
        if (app.store.find(archive_path, e.name)) |i| if (app.store.gone(i)) continue;
        out.append(a, e.name) catch {};
    };
    for (app.store.files.items, 0..) |f, i| {
        if (!std.mem.eql(u8, f.archive, archive_path) or app.store.gone(i) or !std.ascii.startsWithIgnoreCase(f.entry, prefix)) continue;
        if (app.player.voiceIndex(app)) |ar| if (ar.find(f.entry) != null) continue;
        out.append(a, f.entry) catch {};
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(x, y);
        }
    }.lt);
    return out.items;
}

pub fn has(app: *App, name: []const u8) bool {
    if (app.store.find(archive_path, name)) |i| return !app.store.gone(i);
    const ar = app.player.voiceIndex(app) orelse return false;
    return ar.find(name) != null;
}

pub fn play(app: *App, name: []const u8) void {
    const bytes = bytesOf(app, app.frame.allocator(), name) orelse return;
    app.player.playBytes(app, name, bytes);
}

/// Voice file `name` with `bytes` (taken): replaced if it exists, else added; a step.
pub fn put(app: *App, name: []const u8, bytes: []u8) !void {
    if (app.store.find(archive_path, name)) |i| if (!app.store.gone(i)) return app.store.replaceLabeled(i, bytes, name);
    if (app.store.file(archive_path, name)) |i| return app.store.replaceLabeled(i, bytes, name) else |_| {}
    _ = try app.store.addNew(&.{.{ .archive = archive_path, .entry = name, .text = bytes }});
}

/// A WAV or MP3 chosen for line file `name`: converted, put in.
pub fn importTo(app: *App, name: []const u8, path: []const u8) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(app.io, path, app.frame.allocator(), .limited(max_import));
    var s = try og.audio.decode.decode(app.gpa, data);
    defer s.deinit(app.gpa);
    const wav = try og.audio.decode.toPcmWav(app.gpa, s, rate);
    errdefer app.gpa.free(wav);
    try put(app, name, wav);
}

/// The file `from` as line file `to` too (the markup: which recording a line says).
pub fn copyTo(app: *App, from: []const u8, to: []const u8) !void {
    if (std.ascii.eqlIgnoreCase(from, to)) return;
    const bytes = bytesOf(app, app.frame.allocator(), from) orelse return error.NoVoice;
    try put(app, to, try app.gpa.dupe(u8, bytes));
}

/// Voice file `name` taken out of voice.dat (a step).
pub fn remove(app: *App, name: []const u8) !void {
    const i = try app.store.file(archive_path, name);
    try app.store.delete(&.{i});
}

fn exportTo(app: *App, name: []const u8, path: []const u8) !void {
    const bytes = bytesOf(app, app.frame.allocator(), name) orelse return error.NoVoice;
    try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = bytes });
}

// File dialog answers (app.askFile): the voice is `app.voice_for`.
pub fn onVoiceIn(app: *App, _: @import("app.zig").FileAsk, path: []const u8) !void {
    try importTo(app, app.voice_for.get(), path);
    app.setStatus(tx.st_voice_set, .{app.voice_for.get()});
}
pub fn onVoiceOut(app: *App, _: @import("app.zig").FileAsk, path: []const u8) !void {
    try exportTo(app, app.voice_for.get(), path);
    app.setStatus(tx.st_sound_saved, .{path});
}

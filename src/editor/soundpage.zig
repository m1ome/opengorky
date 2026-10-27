//! Sounds tab: the effects of `common/sound.dat` with search, listening, where models'
//! animations use each (frame sounds, `.ani`), export to WAV and import of new ones —
//! converted to the game's own format (PCM 16-bit mono 22050 Hz, as 775 of its 797).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const search = @import("search.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;
const sounds = @import("sounds.zig");
const refs = @import("refs.zig");
const info = @import("info.zig");
const common_archive = @import("store.zig").common_archive;

pub const archive_path = "common/sound.dat";
const rate = 22050;
/// Larger files are not sounds for the game (its longest effect is about 1 MB).
const max_import = 32 << 20;

/// A sound (picked in the asset tree): import, its format, play, export, where used.
pub fn page(app: *App, a: Allocator) void {
    const name = app.sound_sel.get();
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 20, .right = 20, .top = 16 }, .childGap = 12 } });
    if (name.len == 0) {
        if (main.button(app, "snd_import", tx.get(tx.snd_import), true)) app.askFile(.{ .kind = .sound, .run = onSoundIn });
        clay.text(tx.get(tx.snd_import_hint), .{ .textColor = theme.dim, .fontSize = 13, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
        return clay.close();
    }
    txt(name, 20, theme.text, font_mod.bold);
    clay.open(.{ .layout = .{ .childGap = 8 } });
    if (main.toolButton(app, "snd_play_sel", .play, tx.get(tx.snd_play), false, true)) app.player.playEffect(app, name, true);
    if (main.toolButton(app, "snd_stop", .pause, tx.get(tx.mus_stop), false, false)) app.player.stopAll();
    clay.close();
    const pos = app.player.trackPos(name);
    main.timeBar(a, if (pos) |p| p[0] else 0, if (pos) |p| p[1] else null);
    clay.close();
    props(app, a, name);
}

/// The right column: the format, where it sounds, export; importing another.
fn props(app: *App, a: Allocator, name: []const u8) void {
    main.propsOpen(app, "snd_props");
    main.propsTitle(tx.get(tx.props), true);
    main.propRow(tx.get(tx.p_name), name);
    if (bytesOf(app, a, name)) |bytes| if (og.audio.decode.decode(a, bytes)) |s| {
        const secs = @as(f32, @floatFromInt(s.frames())) / @as(f32, @floatFromInt(s.rate));
        main.propRow(tx.get(tx.p_format), tx.alloc(a, tx.snd_format, .{ s.channels, s.rate, secs, bytes.len / 1024 }));
    } else |_| {};
    if (main.button(app, "snd_export", tx.get(tx.snd_export), false)) app.askFile(.{ .kind = .wav_out, .run = onSoundOut });
    main.propsTitle(tx.get(tx.info_title), false);
    info.show(app, info.rows(app, std.fmt.allocPrint(a, "sound:{s}", .{name}) catch name, name, soundInfo));
    main.propsTitle(tx.get(tx.p_new), false);
    if (main.button(app, "snd_import", tx.get(tx.snd_import), false)) app.askFile(.{ .kind = .sound, .run = onSoundIn });
    main.propNote(tx.get(tx.snd_import_hint));
    clay.close();
}

/// The file of sound `name`: an imported one (unsaved) or the archive's.
pub fn bytesOf(app: *App, a: Allocator, name: []const u8) ?[]const u8 {
    return @import("refs.zig").read(app, a, archive_path, name);
}

/// The sound's Info: its file; "model.ani: anim, frame N" for each frame sound naming
/// it (the edited `.ani` files as they are now), each opening that list.
fn soundInfo(name: []const u8, app: *App, list: *info.List) void {
    info.defined(list, archive_path, name, false);
    const stem = std.fs.path.stem(name);
    for (refs.files(app, list.a, common_archive, refs.anim)) |f| {
        const anims = og.formats.anim.parseAni(list.a, f.text) catch continue;
        for (anims.items) |an| for (an.sounds) |cue| {
            if (!std.ascii.eqlIgnoreCase(std.fs.path.stem(cue.name), stem)) continue;
            list.add(.{ .group = .used, .text = list.fmt("{s}: {s}, {s} {d}", .{ f.name["gfx_3d\\".len..], an.name, tx.get(tx.snd_frame_word), cue.frame - an.first }), .to = .{ .code = .{ .archive = common_archive, .entry = f.name } }, .icon = .code });
        };
    }
    if (list.rows.items.len == 1) list.add(.{ .group = .used, .text = tx.get(tx.snd_unused) });
}

/// A sound file chosen to import (WAV or MP3): converted to the game's format under
/// a free name from its file name; one undo step.
pub fn import(app: *App, path: []const u8) ![]const u8 {
    const a = app.frame.allocator();
    const data = try std.Io.Dir.cwd().readFileAlloc(app.io, path, a, .limited(max_import));
    var s = try og.audio.decode.decode(app.gpa, data);
    defer s.deinit(app.gpa);
    const wav = try og.audio.decode.toPcmWav(app.gpa, s, rate);
    errdefer app.gpa.free(wav);
    var nb: [64]u8 = undefined;
    const name = try freeName(app, a, std.fs.path.stem(path), &nb);
    _ = try app.store.addNew(&.{.{ .archive = archive_path, .entry = name, .text = wav }});
    app.sound_sel.set(name);
    return name;
}

fn exportTo(app: *App, name: []const u8, path: []const u8) !void {
    const bytes = bytesOf(app, app.frame.allocator(), name) orelse return error.NoSound;
    try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = bytes });
}

/// `stem` as an archive name: lowercase letters, digits and `_`, `.wav`, not taken.
fn freeName(app: *App, a: Allocator, stem: []const u8, buf: *[64]u8) ![]const u8 {
    var base: [40]u8 = undefined;
    var n: usize = 0;
    for (stem) |ch| {
        if (n == base.len) break;
        base[n] = if (std.ascii.isAlphanumeric(ch)) std.ascii.toLower(ch) else '_';
        n += 1;
    }
    if (n == 0) {
        base[0] = 's';
        n = 1;
    }
    const names = app.player.names(app, a);
    for (1..1000) |k| {
        const s = if (k == 1) try std.fmt.bufPrint(buf, "{s}.wav", .{base[0..n]}) else try std.fmt.bufPrint(buf, "{s}_{d}.wav", .{ base[0..n], k });
        for (names) |x| {
            if (std.ascii.eqlIgnoreCase(x, s)) break;
        } else return s;
    }
    return error.NoFreeName;
}

// File dialog answers (app.askFile).
pub fn onSoundIn(app: *App, _: main.FileAsk, path: []const u8) !void {
    app.setStatus(tx.st_sound_added, .{try import(app, path)});
}
pub fn onSoundOut(app: *App, _: main.FileAsk, path: []const u8) !void {
    try exportTo(app, app.sound_sel.get(), path);
    app.setStatus(tx.st_sound_saved, .{path});
}

//! Music: the game's tracks in common/voice.dat (`<name>.mp3`, MP3 44100 Hz stereo
//! 128 kbit/s). A location plays `<level>.mp3`, else its district's (01_port, 03_museum);
//! a battle without its own plays battle / battle2 / battle3 and `_enemy` in the enemies'
//! turn; scenes start one with MP3_PLAY("name"). A file imported is converted to the
//! game's format (ffmpeg), so the original plays it too.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const icons = @import("icons.zig");
const voices = @import("voices.zig");
const convert = @import("convert.zig");
const textedit = @import("textedit.zig");
const info = @import("info.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;

/// The Music tab's state (`app.music`): the chosen track, the tracks (owned; read again
/// after a change), the name an import takes (a level's own track; empty: the file's).
pub const State = struct {
    sel: main.Name(64) = .{},
    list: std.ArrayList([]u8) = .empty,
    read: bool = false,
    target: main.Name(64) = .{},
};

/// The tracks (`.mp3` of voice.dat and new ones), read once and after a change.
pub fn names(app: *App) []const []u8 {
    if (!app.music.read) {
        app.music.read = true;
        for (app.music.list.items) |n| app.gpa.free(n);
        app.music.list.clearRetainingCapacity();
        if (og.formats.archive.Archive.open(app.io, app.gpa, app.dat, voices.archive_path)) |ar_| {
            var ar = ar_;
            defer ar.close(app.io, app.gpa);
            for (ar.entries) |e| if (std.ascii.endsWithIgnoreCase(e.name, ".mp3")) {
                if (app.store.find(voices.archive_path, e.name)) |i| if (app.store.gone(i)) continue;
                app.music.list.append(app.gpa, app.gpa.dupe(u8, e.name) catch continue) catch {};
            };
            for (app.store.files.items, 0..) |f, i| {
                if (!std.mem.eql(u8, f.archive, voices.archive_path) or !std.ascii.endsWithIgnoreCase(f.entry, ".mp3") or app.store.gone(i) or ar.find(f.entry) != null) continue;
                app.music.list.append(app.gpa, app.gpa.dupe(u8, f.entry) catch continue) catch {};
            }
        } else |_| {}
        std.mem.sort([]u8, app.music.list.items, {}, struct {
            fn lt(_: void, x: []u8, y: []u8) bool {
                return std.ascii.lessThanIgnoreCase(x, y);
            }
        }.lt);
    }
    return app.music.list.items;
}

pub fn page(app: *App, a: Allocator) void {
    const name = app.music.sel.get();
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 20, .right = 20, .top = 16, .bottom = 16 }, .childGap = 12 } });
    if (name.len == 0) {
        if (main.toolButton(app, "mus_import", .plus, tx.get(tx.mus_import), false, true)) app.askMusic(null);
        clay.text(tx.get(tx.mus_hint), .{ .textColor = theme.dim, .fontSize = 13, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
        return clay.close();
    }
    clay.open(.{ .layout = .{ .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    icons.leaf(app.r, app.gpa, .volume_2, 20, theme.accent_hover);
    txt(name, 20, theme.text, font_mod.bold);
    clay.close();
    clay.open(.{ .layout = .{ .childGap = 8 } });
    if (main.toolButton(app, "mus_play", .play, tx.get(tx.vo_play), false, true)) voices.play(app, name);
    if (main.toolButton(app, "mus_stop", .pause, tx.get(tx.mus_stop), false, false)) app.player.stopAll();
    clay.close();
    const pos = app.player.trackPos(name);
    main.timeBar(a, if (pos) |p| p[0] else 0, if (pos) |p| p[1] else null);
    clay.close();
    main.propsOpen(app, "mus_props");
    main.propsTitle(tx.get(tx.props), true);
    // The name typed anew: the track renamed (where it plays follows its name).
    clay.open(.{ .layout = .{ .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(100) } } });
    txt(tx.get(tx.p_name), 13, theme.dim, font_mod.regular);
    clay.close();
    if (textedit.field(app, "mus_name", name, 220, "")) |v| rename(app, name, v);
    clay.close();
    if (voices.bytesOf(app, a, name)) |bytes| main.propRow(tx.get(tx.p_size), tx.alloc(a, tx.vid_size, .{bytes.len / 1024}));
    main.propsTitle(tx.get(tx.info_title), false);
    info.show(app, info.rows(app, std.fmt.allocPrint(a, "music:{s}", .{name}) catch name, name, musicInfo));
    main.propsTitle(tx.get(tx.p_new), false);
    if (main.toolButton(app, "mus_import", .plus, tx.get(tx.mus_import), false, false)) app.askMusic(null);
    main.propNote(tx.get(tx.mus_hint));
    clay.close();
}

/// The track's Info: its file; where it plays: a level of that name or its district,
/// the battles, scenes naming it.
fn musicInfo(name: []const u8, app: *App, list: *info.List) void {
    info.defined(list, voices.archive_path, name, false);
    const stem = std.fs.path.stem(name);
    for (app.levels) |lv| {
        var cb: [2][]const u8 = undefined;
        const cands = og.audio.sound.musicCandidates(lv.name, &cb);
        for (cands, 0..) |cn, k| if (std.ascii.eqlIgnoreCase(cn, stem)) {
            list.add(.{ .group = .used, .text = list.fmt("{s}{s}", .{ lv.name, if (k > 0) tx.get(tx.mus_district) else "" }), .to = .{ .level = .{ .name = lv.name } }, .icon = if (lv.battle) .swords else .map_pin });
            break;
        };
    }
    if (std.ascii.startsWithIgnoreCase(stem, "battle")) list.add(.{ .group = .used, .text = tx.get(if (std.ascii.endsWithIgnoreCase(stem, "_enemy")) tx.lm_music_enemy else tx.mus_battles) });
    info.scenesNaming(app, list, list.fmt("\"{s}\"", .{stem}), "");
    if (list.rows.items.len == 1) list.add(.{ .group = .used, .text = tx.get(tx.mus_unused) });
}

fn rename(app: *App, old: []const u8, typed: []const u8) void {
    var nb: [64]u8 = undefined;
    const new = musicName(&nb, typed) orelse return app.setStatus(tx.st_scene_bad_name, .{typed});
    if (std.ascii.eqlIgnoreCase(new, old)) return;
    if (voices.has(app, new)) return app.setStatus(tx.st_text_taken_name, .{new});
    voices.copyTo(app, old, new) catch |err| return app.setStatus(tx.st_set_failed, .{err});
    voices.remove(app, old) catch {};
    app.music.read = false;
    app.music.sel.set(new);
}

/// `typed` as a track name: letters, digits, `_`, `.mp3` after (null: nothing left).
fn musicName(buf: []u8, typed: []const u8) ?[]const u8 {
    const stem = if (std.ascii.endsWithIgnoreCase(typed, ".mp3")) typed[0 .. typed.len - 4] else typed;
    var n: usize = 0;
    for (std.mem.trim(u8, stem, " ")) |ch| {
        if (n + 4 >= buf.len) break;
        buf[n] = if (std.ascii.isAlphanumeric(ch)) std.ascii.toLower(ch) else '_';
        n += 1;
    }
    if (n == 0) return null;
    @memcpy(buf[n..][0..4], ".mp3");
    return buf[0 .. n + 4];
}

/// A file chosen: converted (in the background, `convert.zig`) to the game's MP3 into
/// voice.dat as `target` (a level's own track) or its file name; one undo step.
pub fn import(app: *App, path: []const u8, target: ?[]const u8) !void {
    var nb: [64]u8 = undefined;
    const name = musicName(&nb, target orelse std.fs.path.stem(path)) orelse return error.BadName;
    try convert.start(app, .music, path, name, "", converted);
}

/// The run done (main thread): the track into voice.dat and picked.
fn converted(app: *App, job: *convert.Job) void {
    const mp3 = job.result catch |err| return convert.failed(app, job, err);
    const data = app.gpa.dupe(u8, mp3) catch |err| return app.setStatus(tx.st_video_failed, .{err});
    voices.put(app, job.name, data) catch |err| return app.setStatus(tx.st_video_failed, .{err});
    app.music.read = false;
    app.music.sel.set(job.name);
    app.setStatus(tx.st_music_added, .{job.name});
}

test musicName {
    var b: [64]u8 = undefined;
    try std.testing.expectEqualStrings("my_song.mp3", musicName(&b, "My Song").?);
    try std.testing.expectEqualStrings("01_port.mp3", musicName(&b, "01_port.mp3").?);
}

/// File dialog answer (app.askFile): named `app.music.target` if set.
pub fn onMusicIn(app: *App, _: main.FileAsk, path: []const u8) !void {
    import(app, path, if (app.music.target.len > 0) app.music.target.get() else null) catch |err| app.setStatus(tx.st_video_failed, .{err});
}

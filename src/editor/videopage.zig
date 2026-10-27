//! Videos tab: the game's `avi\*.asf` (scripts play them as `AVI_Play("name.avi",x,y,1)`),
//! the call to paste, the scripts playing each, and import of new ones — converted by
//! ffmpeg to the game's own format so the original exe plays them too.

const std = @import("std");
const Io = std.Io;
const c = @import("sdl");
const Video = @import("viewer").Video;
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;
const refs = @import("refs.zig");
const info = @import("info.zig");
const common_archive = @import("store.zig").common_archive;
const convert = @import("convert.zig");

/// The Videos tab's state (`app.video`): the selected video (`gradma.asf`), the avi
/// folder's videos (owned).
pub const State = struct {
    sel: main.Name(64) = .{},
    list: std.ArrayList([]u8) = .empty,
    read: bool = false,
    /// The centre player: the video open (`for` names it), playing or on its frame.
    player: ?*Video = null,
    @"for": main.Name(64) = .{},
    playing: bool = false,
};

/// The player on video `name`'s first frame (null: no decoder or no file).
fn load(app: *App, name: []const u8) void {
    stop(app);
    app.video.@"for".set(name);
    var pb: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}/avi/{s}", .{ app.game_dir, name }) catch return;
    app.video.player = Video.open(app.gpa, app.io, app.r, path, 0, 0, false);
    if (app.video.player) |v| v.seek(0);
}

/// The player closed (its sound too).
pub fn stop(app: *App) void {
    if (app.video.playing) app.player.stopAll();
    app.video.playing = false;
    if (app.video.player) |v| v.close(null);
    app.video.player = null;
}

/// The viewport callback: the frame fitted into `rect`, black around it.
pub fn draw(app: *App, rect: c.SDL_FRect) void {
    _ = c.SDL_SetRenderDrawColor(app.r, 0, 0, 0, 255);
    _ = c.SDL_RenderFillRect(app.r, &rect);
    const v = app.video.player orelse return;
    if (v.shown == 0) return;
    const w: f32 = @floatFromInt(v.w);
    // Doubled lines, as the game shows it with the call above (its last argument 1).
    const h: f32 = @floatFromInt(v.h * 2);
    const k = @min(rect.w / w, rect.h / h);
    _ = c.SDL_RenderTexture(app.r, v.tex, null, &.{ .x = rect.x + (rect.w - w * k) / 2, .y = rect.y + (rect.h - h * k) / 2, .w = w * k, .h = h * k });
}

/// Play / Stop, the frame, where it is.
fn playerPane(app: *App, a: Allocator, name: []const u8) void {
    if (!std.mem.eql(u8, app.video.@"for".get(), name)) load(app, name);
    clay.open(.{ .layout = .{ .childGap = 8 } });
    if (main.toolButton(app, "vid_play", .play, tx.get(tx.vid_play), false, true)) {
        load(app, name);
        if (app.video.player) |v| {
            app.video.playing = true;
            if (v.sound) |*snd| app.player.playSound(app, name, snd);
            v.start_ms = c.SDL_GetTicks();
        }
    }
    if (main.toolButton(app, "vid_stop", .pause, tx.get(tx.mus_stop), false, false)) load(app, name);
    clay.close();
    if (app.video.player) |v| {
        if (app.video.playing) {
            v.update();
            if (v.done) app.video.playing = false;
        }
        const len: ?f32 = if (v.sound) |snd| @as(f32, @floatFromInt(snd.frames())) / @as(f32, @floatFromInt(snd.rate)) else null;
        const at: f32 = if (app.video.playing) v.seconds() else if (v.done) len orelse 0 else 0;
        main.timeBar(a, if (len) |l| @min(at, l) else at, len);
    } else main.propNote(tx.get(tx.vid_no_player));
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } }, .cornerRadius = clay.radius(theme.radius), .custom = .{ .customData = &app.video } });
}

/// Video names (`gradma.asf`) of the game's avi folder, read once (and after an import).
pub fn names(app: *App) []const []u8 {
    if (!app.video.read) {
        app.video.read = true;
        read(app) catch |err| std.log.warn("avi: {t}", .{err});
    }
    return app.video.list.items;
}

fn read(app: *App) !void {
    for (app.video.list.items) |s| app.gpa.free(s);
    app.video.list.clearRetainingCapacity();
    var root = try Io.Dir.cwd().openDir(app.io, app.game_dir, .{});
    defer root.close(app.io);
    var dir = try root.openDir(app.io, "avi", .{ .iterate = true });
    defer dir.close(app.io);
    var it = dir.iterate();
    while (try it.next(app.io)) |e| {
        if (e.kind != .file or !std.ascii.endsWithIgnoreCase(e.name, ".asf")) continue;
        try app.video.list.append(app.gpa, try std.ascii.allocLowerString(app.gpa, e.name));
    }
    std.mem.sort([]u8, app.video.list.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
}

/// A video (picked in the asset tree): import, its size, the script call, where played.
pub fn page(app: *App, a: Allocator) void {
    const name = app.video.sel.get();
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 20, .right = 20, .top = 16 }, .childGap = 12 } });
    if (name.len == 0) {
        if (main.button(app, "vid_import", tx.get(tx.vid_import), true)) app.askFile(.{ .kind = .video, .run = onVideoIn });
        clay.text(tx.get(tx.vid_import_hint), .{ .textColor = theme.dim, .fontSize = 13, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
        return clay.close();
    }
    txt(name, 20, theme.text, font_mod.bold);
    // How scripts play it: level scripts call AVI_Play, scenes PLAYAVI (the exe plays
    // avi\<name>.asf for "<name>.avi").
    txt(tx.get(tx.vid_call), 13, theme.dim, font_mod.regular);
    txt(std.fmt.allocPrint(a, "AVI_Play(\"{s}.avi\",0,60,1);   // .lev", .{std.fs.path.stem(name)}) catch "", 14, theme.text, font_mod.regular);
    txt(std.fmt.allocPrint(a, "PLAYAVI(\"{s}.avi\",0,60,1)   // scene .scr", .{std.fs.path.stem(name)}) catch "", 14, theme.text, font_mod.regular);
    playerPane(app, a, name);
    clay.close();
    main.propsOpen(app, "vid_props");
    main.propsTitle(tx.get(tx.props), true);
    main.propRow(tx.get(tx.p_name), name);
    var pb: [1024]u8 = undefined;
    if (std.fmt.bufPrint(&pb, "{s}/avi/{s}", .{ app.game_dir, name })) |p| if (Io.Dir.cwd().statFile(app.io, p, .{})) |st| {
        main.propRow(tx.get(tx.p_size), tx.alloc(a, tx.vid_size, .{st.size / 1024}));
    } else |_| {} else |_| {}
    main.propsTitle(tx.get(tx.info_title), false);
    info.show(app, info.rows(app, std.fmt.allocPrint(a, "video:{s}", .{name}) catch name, name, videoInfo));
    main.propsTitle(tx.get(tx.p_new), false);
    if (main.button(app, "vid_import", tx.get(tx.vid_import), false)) app.askFile(.{ .kind = .video, .run = onVideoIn });
    main.propNote(tx.get(tx.vid_import_hint));
    clay.close();
}

/// The video's Info: its file; the scripts naming `<stem>.avi`: levels' (by level) and
/// common's (scenes, classes), as edited.
fn videoInfo(name: []const u8, app: *App, list: *info.List) void {
    info.defined(list, "avi", name, false);
    const needle = list.fmt("\"{s}.avi\"", .{std.fs.path.stem(name)});
    info.levelsNaming(app, list, needle);
    for (refs.naming(app, list.a, common_archive, refs.script, needle)) |e| list.add(.{ .group = .used, .text = e, .to = .{ .code = .{ .archive = common_archive, .entry = e } }, .icon = .code });
    if (list.rows.items.len == 1) list.add(.{ .group = .used, .text = tx.get(tx.vid_unused) });
}

/// A video file chosen to import: converted into `avi\<name>.asf` under a free name from
/// its file name, in the background (`convert.zig`; not an undo step: the folder is not
/// an archive).
pub fn import(app: *App, path: []const u8) !void {
    const a = app.frame.allocator();
    var nb: [48]u8 = undefined;
    const name = try freeName(app, std.fs.path.stem(path), &nb);
    const out = try std.fmt.allocPrint(a, "{s}/avi/{s}", .{ app.game_dir, name });
    // The game's own format (transcode.video).
    try convert.start(app, .video, path, name, out, converted);
}

/// The run done (main thread): the video listed and picked, or the file dropped.
fn converted(app: *App, job: *convert.Job) void {
    _ = job.result catch |err| {
        Io.Dir.cwd().deleteFile(app.io, job.out) catch {};
        return convert.failed(app, job, err);
    };
    app.video.read = false;
    app.video.sel.set(job.name);
    app.setStatus(tx.st_video_added, .{job.name});
}

/// `stem` as a video name: lowercase letters, digits and `_`, `.asf`, not taken.
fn freeName(app: *App, stem: []const u8, buf: *[48]u8) ![]const u8 {
    var base: [32]u8 = undefined;
    var n: usize = 0;
    for (stem) |ch| {
        if (n == base.len) break;
        base[n] = if (std.ascii.isAlphanumeric(ch)) std.ascii.toLower(ch) else '_';
        n += 1;
    }
    if (n == 0) {
        base[0] = 'v';
        n = 1;
    }
    const have = names(app);
    for (1..1000) |k| {
        const s = if (k == 1) try std.fmt.bufPrint(buf, "{s}.asf", .{base[0..n]}) else try std.fmt.bufPrint(buf, "{s}_{d}.asf", .{ base[0..n], k });
        for (have) |x| {
            if (std.ascii.eqlIgnoreCase(x, s)) break;
        } else return s;
    }
    return error.NoFreeName;
}

/// File dialog answer (app.askFile).
pub fn onVideoIn(app: *App, _: main.FileAsk, path: []const u8) !void {
    import(app, path) catch |err| app.setStatus(tx.st_video_failed, .{err});
}

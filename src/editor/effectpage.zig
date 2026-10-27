//! Effects tab: a weapon or spell effect (`gfx_3d\effects\<name>\<name>.dsc`: the list of
//! its frames, each a texture `.3df` beside it — flame, smoke, explosions) as its frames
//! with a looping preview; a frame replaced from a PNG (at the frame's size), one added
//! after the last (the next number), one taken out of the list. One undo step each.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const c = @import("sdl");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const icons = @import("icons.zig");
const art = @import("art.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;
const common_archive = @import("store.zig").common_archive;

/// The Effects tab's state (`app.effect`): the effect shown, its frames' textures
/// (entry → texture).
pub const State = struct {
    sel: main.Name(64) = .{},
    tex: std.StringHashMapUnmanaged(?*c.SDL_Texture) = .empty,
};

const prefix = "gfx_3d\\effects\\";

/// The effects (folders with a `.dsc`).
pub fn names(app: *App, a: Allocator) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var ar = og.formats.archive.Archive.open(app.io, app.gpa, app.dat, common_archive) catch return out.items;
    defer ar.close(app.io, app.gpa);
    for (ar.entries) |e| {
        if (!std.ascii.startsWithIgnoreCase(e.name, prefix) or !std.ascii.endsWithIgnoreCase(e.name, ".dsc")) continue;
        const rest = e.name[prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '\\') orelse continue;
        out.append(a, a.dupe(u8, rest[0..slash]) catch continue) catch {};
    }
    return out.items;
}

fn dscEntry(a: Allocator, name: []const u8) []const u8 {
    return std.fmt.allocPrint(a, prefix ++ "{s}\\{s}.dsc", .{ name, name }) catch "";
}

/// The frame file names the `.dsc` lists, in order (as the game reads it: no `[alpha]`
/// header, up to an empty line).
fn frames(app: *App, a: Allocator, name: []const u8) []const []const u8 {
    const f = app.store.file(common_archive, dscEntry(a, name)) catch return &.{};
    const d = og.effects.dsc.parseDsc(a, app.store.text(f)) catch return &.{};
    return d.frames.items;
}

/// Frame `frame` of effect `name` as a texture (kept per frame; dropped when replaced).
fn texture(app: *App, a: Allocator, name: []const u8, frame: []const u8) ?struct { tex: *c.SDL_Texture, w: f32, h: f32 } {
    const entry = std.fmt.allocPrint(a, prefix ++ "{s}\\{s}", .{ name, frame }) catch return null;
    var kb: [160]u8 = undefined;
    const key = std.ascii.lowerString(&kb, entry[0..@min(entry.len, kb.len)]);
    const t = app.effect.tex.get(key) orelse blk: {
        const made = make(app, entry);
        const k = app.gpa.dupe(u8, key) catch return null;
        app.effect.tex.put(app.gpa, k, made) catch app.gpa.free(k);
        break :blk made;
    };
    const tex = t orelse return null;
    var w: f32 = 0;
    var h: f32 = 0;
    _ = c.SDL_GetTextureSize(tex, &w, &h);
    return .{ .tex = tex, .w = w, .h = h };
}

fn make(app: *App, entry: []const u8) ?*c.SDL_Texture {
    const f = app.store.file(common_archive, entry) catch return null;
    var img = og.formats.tex3df.decode(app.gpa, app.store.text(f)) catch return null;
    defer img.deinit(app.gpa);
    const t = c.SDL_CreateTexture(app.r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, @intCast(img.width), @intCast(img.height)) orelse return null;
    _ = c.SDL_UpdateTexture(t, null, img.pixels.ptr, @intCast(img.width * 4));
    _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_BLEND);
    return t;
}

fn forget(app: *App, entry: []const u8) void {
    var kb: [160]u8 = undefined;
    const key = std.ascii.lowerString(&kb, entry[0..@min(entry.len, kb.len)]);
    const kv = app.effect.tex.fetchRemove(key) orelse return;
    if (kv.value) |t| c.SDL_DestroyTexture(t);
    app.gpa.free(kv.key);
}

pub fn page(app: *App, a: Allocator) void {
    const name = app.effect.sel.get();
    if (name.len == 0) return;
    const fs = frames(app, a, name);
    clay.openScroll(.{ .id = clay.id("effect_page"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 20, .right = 20, .top = 16, .bottom = 16 }, .childGap = 12 } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 12, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    icons.leaf(app.r, app.gpa, .image, 28, theme.accent_hover);
    txt(name, 20, theme.text, font_mod.bold);
    clay.close();
    // The preview: the frames in turn, 15 a second.
    if (fs.len > 0) {
        const k: usize = @intCast((c.SDL_GetTicks() / 66) % fs.len);
        if (texture(app, a, name, fs[k])) |t| {
            const s = @min(2, 256 / @max(t.w, t.h));
            clay.open(.{ .layout = .{ .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 } }, .backgroundColor = theme.viewport, .cornerRadius = clay.radius(theme.radius) });
            clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(t.w * s), .height = clay.fixed(t.h * s) } }, .image = .{ .imageData = t.tex } });
            clay.close();
        }
    }
    // The frames: each with its name, from a PNG, out of the list.
    var i: usize = 0;
    while (i < fs.len) : (i += 6) {
        clay.open(.{ .layout = .{ .childGap = 10 } });
        for (fs[i..@min(fs.len, i + 6)], i..) |fr, k| {
            clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(150) }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 6, .right = 6, .top = 6, .bottom = 6 }, .childGap = 4 }, .backgroundColor = theme.field, .cornerRadius = clay.radius(theme.radius) });
            txt(std.fmt.allocPrint(a, "{d}. {s}", .{ k + 1, fr }) catch fr, 12, theme.text, font_mod.regular);
            if (texture(app, a, name, fr)) |t| {
                const s = @min(1, 128 / @max(t.w, t.h));
                clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(t.w * s), .height = clay.fixed(t.h * s) } }, .image = .{ .imageData = t.tex } });
            }
            clay.open(.{ .layout = .{ .childGap = 4 } });
            if (main.toolButton(app, std.fmt.allocPrint(a, "ef_png{d}", .{k}) catch "p", .image, "", false, false)) app.askFile(.{ .kind = .png, .run = onFrameIn, .entry = k });
            if (main.toolButton(app, std.fmt.allocPrint(a, "ef_del{d}", .{k}) catch "d", .trash_2, "", false, false)) app.askDelete(.effect_frame, k, fr);
            clay.close();
            clay.close();
        }
        clay.close();
    }
    clay.close();
    main.propsOpen(app, "effect_props");
    main.propsTitle(tx.get(tx.props), true);
    main.propRow(tx.get(tx.p_file), dscEntry(a, name));
    main.propRow(tx.get(tx.p_frames), std.fmt.allocPrint(a, "{d}", .{fs.len}) catch "");
    main.propNote(tx.alloc(a, tx.ef_hint, .{fs.len}));
    main.propsTitle(tx.get(tx.p_actions), false);
    if (main.toolButton(app, "ef_add", .plus, tx.get(tx.ef_add), false, false)) app.askFile(.{ .kind = .png, .run = onFrameAdd });
    clay.close();
}

/// Frame `k` from PNG `path` (resized to the frame's size: the effect's sprites keep it).
fn replaceFrame(app: *App, k: usize, path: []const u8) !void {
    const a = app.frame.allocator();
    const name = app.effect.sel.get();
    const fs = frames(app, a, name);
    if (k >= fs.len) return error.NoFrame;
    const entry = try std.fmt.allocPrint(a, prefix ++ "{s}\\{s}", .{ name, fs[k] });
    const f = try app.store.file(common_archive, entry);
    var orig = try og.formats.tex3df.decode(app.gpa, app.store.text(f));
    defer orig.deinit(app.gpa);
    var img = try art.readPng(app, path);
    defer img.deinit(app.gpa);
    var sized = try art.resize(app.gpa, img, orig.width, orig.height);
    defer sized.deinit(app.gpa);
    const bytes = try og.formats.tex3df.encodeArgb4444(app.gpa, sized);
    try app.store.replaceLabeled(f, bytes, entry);
    forget(app, entry);
}

/// A frame from PNG `path` after the last (named as the last with the next number; the
/// size of the others).
pub fn addFrame(app: *App, path: []const u8) !void {
    const a = app.frame.allocator();
    const name = app.effect.sel.get();
    const fs = frames(app, a, name);
    if (fs.len == 0) return error.NoFrame;
    const last = fs[fs.len - 1];
    const stem = last[0 .. std.mem.lastIndexOfScalar(u8, last, '.') orelse last.len];
    var ds = stem.len;
    while (ds > 0 and std.ascii.isDigit(stem[ds - 1])) ds -= 1;
    const digits = stem.len - ds;
    var n = (std.fmt.parseInt(u32, stem[ds..], 10) catch 0) + 1;
    const new = while (n < 100000) : (n += 1) {
        const s = if (digits > 0) try std.fmt.allocPrint(a, "{s}{d:0>4}.3df", .{ stem[0..ds], n }) else try std.fmt.allocPrint(a, "{s}{d}.3df", .{ stem, n });
        if ((app.store.file(common_archive, try std.fmt.allocPrint(a, prefix ++ "{s}\\{s}", .{ name, s })) catch null) == null) break s;
    } else return error.NoFreeName;
    var orig = try og.formats.tex3df.decode(app.gpa, app.store.text(try app.store.file(common_archive, try std.fmt.allocPrint(a, prefix ++ "{s}\\{s}", .{ name, last }))));
    defer orig.deinit(app.gpa);
    var img = try art.readPng(app, path);
    defer img.deinit(app.gpa);
    var sized = try art.resize(app.gpa, img, orig.width, orig.height);
    defer sized.deinit(app.gpa);
    const tex = try og.formats.tex3df.encodeArgb4444(app.gpa, sized);
    const df = try app.store.file(common_archive, dscEntry(a, name));
    const t = app.store.text(df);
    const nl = if (t.len == 0 or std.mem.endsWith(u8, t, "\n")) "" else "\r\n";
    const dsc = try std.mem.concat(app.gpa, u8, &.{ t, nl, new, "\r\n" });
    _ = try app.store.addNew(&.{.{ .archive = common_archive, .entry = try std.fmt.allocPrint(a, prefix ++ "{s}\\{s}", .{ name, new }), .text = tex }});
    try app.store.replaceLabeled(df, dsc, dscEntry(a, name));
}

/// Frame `k` out of the effect's list (its texture stays; the blend header kept).
pub fn removeFrame(app: *App, k: usize) !void {
    const a = app.frame.allocator();
    const name = app.effect.sel.get();
    const df = try app.store.file(common_archive, dscEntry(a, name));
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, app.store.text(df), '\n');
    var i: usize = 0;
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0) continue;
        if (l[0] != '[') {
            defer i += 1;
            if (i == k) continue;
        }
        try out.appendSlice(a, l);
        try out.appendSlice(a, "\r\n");
    }
    try app.store.replaceLabeled(df, try app.gpa.dupe(u8, out.items), dscEntry(a, name));
}

// File dialog answers (app.askFile).
fn onFrameIn(app: *App, ask: main.FileAsk, path: []const u8) !void {
    try replaceFrame(app, ask.entry, path);
    app.setStatus(tx.st_frame_set, .{ask.entry + 1});
}
fn onFrameAdd(app: *App, _: main.FileAsk, path: []const u8) !void {
    try addFrame(app, path);
    app.setStatus(tx.st_frame_added, .{});
}

//! Icon window: an `icons\<name>.spr` sprite (items: big and small frame; enemies: the
//! portrait; heroes: four) frame by frame — a frame from a PNG or to one, and pixel
//! editing zoomed in (pencil, eraser, eyedropper, the sprite's own colours). A stroke
//! is one undo step; the sprite is written back in the game's format (sprite.encode).

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const ui = @import("ui");
const og = @import("opengorky");
const Image = og.formats.image.Image;
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;
const art = @import("art.zig");
const info = @import("info.zig");
const refs = @import("refs.zig");
const sprite_archive = @import("store.zig").sprite_archive;

pub const Tool = enum { pencil, eraser, picker };

pub const Edit = struct {
    /// Store index of the sprite and its entry (`icons\\knife.spr`, `woda1.spr`).
    file: usize,
    name: []u8,
    frames: std.ArrayList(Image) = .empty,
    textures: std.ArrayList(*c.SDL_Texture) = .empty,
    frame: usize = 0,
    color: [4]u8 = .{ 255, 255, 255, 255 },
    tool: Tool = .pencil,
    /// A stroke in progress (written as one step on release) and whether it changed a pixel.
    painting: bool = false,
    stroked: bool = false,
    /// Where the canvas was drawn last and its zoom (points per pixel).
    rect: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    zoom: f32 = 1,
    origin: [2]f32 = .{ 0, 0 },
    /// Frames shown one after another (15 a second, looping), from `play_ms` on.
    playing: bool = false,
    play_ms: u64 = 0,

    pub fn destroy(self: *Edit, gpa: Allocator) void {
        self.clear(gpa);
        self.frames.deinit(gpa);
        self.textures.deinit(gpa);
        gpa.free(self.name);
        gpa.destroy(self);
    }

    fn clear(self: *Edit, gpa: Allocator) void {
        for (self.frames.items) |*f| f.deinit(gpa);
        self.frames.clearRetainingCapacity();
        for (self.textures.items) |t| c.SDL_DestroyTexture(t);
        self.textures.clearRetainingCapacity();
    }
};

/// The `.spr` and `.spz` entries of `archive` (its own and new ones not saved yet), by name.
pub fn entries(app: *App, a: Allocator, archive: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var ar = og.formats.archive.Archive.open(app.io, app.gpa, app.dat, archive) catch null;
    defer if (ar) |*x| x.close(app.io, app.gpa);
    if (ar) |x| for (x.entries) |e| if (isSprite(e.name)) out.append(a, a.dupe(u8, e.name) catch continue) catch {};
    for (app.store.files.items, 0..) |f, i| {
        if (!std.mem.eql(u8, f.archive, archive) or !isSprite(f.entry) or app.store.gone(i)) continue;
        if (ar) |x| if (x.find(f.entry) != null) continue;
        out.append(a, f.entry) catch {};
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(x, y);
        }
    }.lt);
    return out.items;
}

fn isSprite(entry: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(entry, ".spr") or std.ascii.endsWithIgnoreCase(entry, ".spz");
}

/// Opens icon `name` (edited or from common/sprite.dat).
pub fn open(app: *App, name: []const u8) !void {
    var buf: [96]u8 = undefined;
    return openEntry(app, sprite_archive, try std.fmt.bufPrint(&buf, "icons\\{s}.spr", .{name}));
}

/// Opens sprite `entry` of archive `archive` (`common/sprite.dat`, `<level>/sprite.dat`).
pub fn openEntry(app: *App, archive: []const u8, entry: []const u8) !void {
    @import("codeview.zig").park(app);
    app.setTab(.sprites);
    if (app.spr) |e| if (std.mem.eql(u8, app.store.files.items[e.file].archive, archive) and std.ascii.eqlIgnoreCase(e.name, entry)) return;
    if (app.spr) |e| e.destroy(app.gpa);
    app.spr = null;
    const f = app.store.find(archive, entry) orelse try app.store.file(archive, entry);
    const e = try app.gpa.create(Edit);
    e.* = .{ .file = f, .name = try app.gpa.dupe(u8, entry) };
    errdefer e.destroy(app.gpa);
    try load(app, e);
    app.spr = e;
}

/// Frames decoded from the Store's sprite (after opening, and after an undo of it).
pub fn load(app: *App, e: *Edit) !void {
    e.clear(app.gpa);
    var spr = try og.formats.sprite.parse(app.gpa, app.store.text(e.file));
    defer spr.deinit(app.gpa);
    for (spr.frames) |fr| try e.frames.append(app.gpa, if (isDepth(e)) try depthImage(app.gpa, fr) else try og.formats.sprite.decodeFrame(app.gpa, fr));
    e.frame = @min(e.frame, e.frames.items.len -| 1);
    try textures(app, e);
}

fn textures(app: *App, e: *Edit) !void {
    for (e.textures.items) |t| c.SDL_DestroyTexture(t);
    e.textures.clearRetainingCapacity();
    for (e.frames.items) |img| {
        const t = c.SDL_CreateTexture(app.r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, @intCast(img.width), @intCast(img.height)) orelse return error.Texture;
        _ = c.SDL_UpdateTexture(t, null, img.pixels.ptr, @intCast(img.width * 4));
        _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetTextureScaleMode(t, c.SDL_SCALEMODE_NEAREST);
        try e.textures.append(app.gpa, t);
    }
}

/// The frames written into the Store as one step; the cached icon is drawn anew.
fn commit(app: *App, e: *Edit, what: []const u8) !void {
    const bytes = try og.formats.sprite.encode(app.gpa, e.frames.items);
    var lb: [160]u8 = undefined;
    const label = std.fmt.bufPrint(&lb, "{s}: {s}", .{ e.name, what }) catch "sprite";
    try app.store.replaceLabeled(e.file, bytes, label);
    // An icon: the cached picture drawn anew.
    if (std.ascii.startsWithIgnoreCase(e.name, "icons\\")) app.forgetIcon(std.fs.path.stem(e.name["icons\\".len..]));
}

/// A frame from a PNG at its own size after the others (an animation's next frame).
pub fn addFrame(app: *App, path: []const u8) !void {
    const e = app.spr orelse return error.NoIcon;
    if (isDepth(e)) return error.DepthFramesFixed;
    var img = try art.readPng(app, path);
    errdefer img.deinit(app.gpa);
    if (img.width > 4096 or img.height > 4096) return error.TooBig;
    try e.frames.append(app.gpa, img);
    e.frame = e.frames.items.len - 1;
    try textures(app, e);
    try commit(app, e, tx.get(tx.spr_frame_added));
}

/// Frame `k` taken out (a sprite keeps one at least).
pub fn removeFrame(app: *App, k: usize) !void {
    const e = app.spr orelse return error.NoIcon;
    if (isDepth(e)) return error.DepthFramesFixed;
    if (e.frames.items.len < 2 or k >= e.frames.items.len) return error.LastFrame;
    var img = e.frames.orderedRemove(k);
    img.deinit(app.gpa);
    e.frame = @min(e.frame, e.frames.items.len - 1);
    try textures(app, e);
    try commit(app, e, tx.get(tx.spr_frame_removed));
}

/// A new sprite `<dir>\\<png name>.spr` (dir: `icons` or none) in `archive` from a PNG,
/// one frame, opened; one undo step.
pub fn importNew(app: *App, archive: []const u8, dir: []const u8, path: []const u8) ![]const u8 {
    var img = try art.readPng(app, path);
    defer img.deinit(app.gpa);
    if (img.width > 4096 or img.height > 4096) return error.TooBig;
    const bytes = try og.formats.sprite.encode(app.gpa, &.{img});
    errdefer app.gpa.free(bytes);
    const a = app.frame.allocator();
    var base: [40]u8 = undefined;
    var n: usize = 0;
    for (std.fs.path.stem(path)) |ch| {
        if (n == base.len) break;
        base[n] = if (std.ascii.isAlphanumeric(ch)) std.ascii.toLower(ch) else '_';
        n += 1;
    }
    if (n == 0) {
        base[0] = 's';
        n = 1;
    }
    const sep = if (dir.len > 0) "\\" else "";
    const entry = for (1..1000) |k| {
        const s = if (k == 1) try std.fmt.allocPrint(a, "{s}{s}{s}.spr", .{ dir, sep, base[0..n] }) else try std.fmt.allocPrint(a, "{s}{s}{s}_{d}.spr", .{ dir, sep, base[0..n], k });
        if (app.store.find(archive, s) == null and (app.store.file(archive, s) catch null) == null) break s;
    } else return error.NoFreeName;
    _ = try app.store.addNew(&.{.{ .archive = archive, .entry = entry, .text = bytes }});
    try openEntry(app, archive, entry);
    return entry;
}

/// A depth sprite (`.spz`: an animation's depth, 16 bits a pixel in raw frames): no
/// drawing, frames out to and in from PNG only — grey by the high byte (R, G), the low
/// byte in blue, so it comes back exact.
fn isDepth(e: *const Edit) bool {
    return std.ascii.endsWithIgnoreCase(e.name, ".spz");
}

fn depthImage(gpa: Allocator, fr: og.formats.sprite.Frame) !Image {
    var img = try Image.init(gpa, fr.width, fr.height);
    errdefer img.deinit(gpa);
    const n = @as(usize, fr.width) * fr.height;
    if (!fr.raw or fr.data.len < 4 + n * 2) {
        @memset(img.pixels, 0);
        return img;
    }
    for (0..n) |i| {
        const v = std.mem.readInt(u16, fr.data[4 + i * 2 ..][0..2], .little);
        const hi: u8 = @intCast(v >> 8);
        img.pixels[i * 4 ..][0..4].* = .{ hi, hi, @truncate(v), 255 };
    }
    return img;
}

/// Depth frame `k` from image `img` (its size): the frame's bytes replaced in place.
fn putDepth(app: *App, e: *Edit, k: usize, img: Image) !void {
    const bytes = app.store.text(e.file);
    var spr = try og.formats.sprite.parse(app.gpa, bytes);
    defer spr.deinit(app.gpa);
    const fr = spr.frames[k];
    const n = @as(usize, fr.width) * fr.height;
    if (!fr.raw or fr.data.len < 4 + n * 2) return error.NotDepth;
    const start = @intFromPtr(fr.data.ptr) - @intFromPtr(bytes.ptr);
    const out = try app.gpa.dupe(u8, bytes);
    errdefer app.gpa.free(out);
    for (0..n) |i| {
        const p = img.pixels[i * 4 ..][0..4];
        std.mem.writeInt(u16, out[start + 4 + i * 2 ..][0..2], @as(u16, p[1]) << 8 | p[2], .little);
    }
    var lb: [160]u8 = undefined;
    try app.store.replaceLabeled(e.file, out, std.fmt.bufPrint(&lb, "{s}: {s} {d}", .{ e.name, tx.get(tx.spr_frame_word), k + 1 }) catch e.name);
    try load(app, e);
}

/// Frame `k` from a PNG, fitted to the frame's size (the game draws it there).
pub fn importFrame(app: *App, k: usize, path: []const u8) !void {
    const e = app.spr orelse return error.NoIcon;
    if (k >= e.frames.items.len) return error.NoFrame;
    var img = try art.readPng(app, path);
    defer img.deinit(app.gpa);
    if (isDepth(e)) {
        var sized = try art.resize(app.gpa, img, e.frames.items[k].width, e.frames.items[k].height);
        defer sized.deinit(app.gpa);
        return putDepth(app, e, k, sized);
    }
    const old = &e.frames.items[k];
    const fresh = try art.resize(app.gpa, img, old.width, old.height);
    old.deinit(app.gpa);
    old.* = fresh;
    try textures(app, e);
    var wb: [32]u8 = undefined;
    try commit(app, e, std.fmt.bufPrint(&wb, "{s} {d}", .{ tx.get(tx.spr_frame_word), k + 1 }) catch "frame");
}

pub fn exportFrame(app: *App, k: usize, path: []const u8) !void {
    const e = app.spr orelse return error.NoIcon;
    if (k >= e.frames.items.len) return error.NoFrame;
    try art.writePng(app, e.frames.items[k], path);
}

/// The sprite closed (its tab gone).
pub fn close(app: *App) void {
    if (app.spr) |e| e.destroy(app.gpa);
    app.spr = null;
}

/// The Sprites tab's page: the open sprite's frames and the chosen one zoomed.
pub fn page(app: *App, a: Allocator) void {
    const e = app.spr orelse return;
    clay.open(.{
        .id = clay.id("sprpanel"),
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM },
        .backgroundColor = theme.panel,
    });

    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } } });
    // Frames: a picture of each, its size, from / to PNG.
    clay.openScroll(.{ .id = clay.id("spr_frames"), .layout = .{ .sizing = .{ .width = clay.fixed(240), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 10, .right = 10, .top = 10 }, .childGap = 8 }, .border = .{ .color = theme.line, .width = .{ .right = 1 } } });
    for (e.frames.items, 0..) |img, k| {
        const sel = k == e.frame;
        const fid = clay.idi("spr_fr", @intCast(k));
        if (main.clickable(app, .{ .id = fid, .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 }, .childGap = 6 }, .backgroundColor = theme.field, .cornerRadius = clay.radius(theme.radius) }, sel)) e.frame = k;
        txt(tx.alloc(a, tx.spr_frame, .{ k + 1, img.width, img.height }), 13, theme.text, font_mod.bold);
        const s: f32 = @min(1.0, 200 / @as(f32, @floatFromInt(@max(img.width, img.height))));
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(@as(f32, @floatFromInt(img.width)) * s), .height = clay.fixed(@as(f32, @floatFromInt(img.height)) * s) } }, .image = .{ .imageData = e.textures.items[k] } });
        clay.close();
    }
    clay.close();

    // The chosen frame zoomed: tools, colours, the canvas.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    // Clipped: a narrow window cuts the palette rather than pushing the right column out.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(40) }, .padding = .{ .left = 10, .right = 10 }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.header, .clip = .{ .horizontal = true } });
    if (e.frames.items.len > 1) playback(app, a, e);
    if (!isDepth(e)) {
        const tools = [_]struct { Tool, tx.Msg }{ .{ .pencil, tx.spr_pencil }, .{ .eraser, tx.spr_eraser }, .{ .picker, tx.spr_picker } };
        for (tools) |t| if (main.button(app, @tagName(t[0]), tx.get(t[1]), e.tool == t[0])) {
            e.tool = t[0];
        };
        // The colour drawn with, then the sprite's most used ones.
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(12) } } });
        swatch(app, "spr_cur", e.color, 24, null);
        for (palette(a, e), 0..) |col, k| swatch(app, std.fmt.allocPrint(a, "spr_pal{d}", .{k}) catch "pal", col, 18, e);
    }
    clay.close();
    clay.leaf(.{ .id = clay.id("spr_canvas"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } }, .backgroundColor = theme.viewport, .custom = .{ .customData = e } });
    clay.close();
    clay.close();
    clay.close();
    props(app, a, e);
}

/// Several frames: a frame back, play / pause, a frame on, where it is. Playing only
/// changes the frame shown (nothing is edited); 15 frames a second, looping.
fn playback(app: *App, a: Allocator, e: *Edit) void {
    const n = e.frames.items.len;
    const now = c.SDL_GetTicks();
    // shortcut: 15 fps for every sprite, the game's `speed` of the animation using it is not looked up.
    if (e.playing and now - e.play_ms >= 1000 / 15) {
        e.frame = (e.frame + 1) % n;
        e.play_ms = now;
    }
    if (main.toolButton(app, "spr_back", .skip_back, "", false, false)) {
        e.playing = false;
        e.frame = (e.frame + n - 1) % n;
    }
    if (main.toolButton(app, "spr_play", if (e.playing) .pause else .play, "", e.playing, false)) {
        e.playing = !e.playing;
        e.play_ms = now;
    }
    if (main.toolButton(app, "spr_next", .skip_forward, "", false, false)) {
        e.playing = false;
        e.frame = (e.frame + 1) % n;
    }
    txt(std.fmt.allocPrint(a, "{d} / {d}", .{ e.frame + 1, n }) catch "", 12, theme.dim, font_mod.regular);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(12) } } });
}

/// The right column: the file, the picked frame (PNG out and in, out of the sprite),
/// a frame added; its Info.
fn props(app: *App, a: Allocator, e: *Edit) void {
    main.propsOpen(app, "spr_props");
    main.propsTitle(tx.get(tx.props), true);
    main.propRow(tx.get(tx.p_file), app.store.files.items[e.file].archive);
    main.propRow(tx.get(tx.p_name), e.name);
    main.propRow(tx.get(tx.p_frames), std.fmt.allocPrint(a, "{d}", .{e.frames.items.len}) catch "");
    main.propNote(tx.get(if (isDepth(e)) tx.spr_depth_hint else tx.spr_hint));
    const k = e.frame;
    if (k < e.frames.items.len) {
        const img = e.frames.items[k];
        main.propsTitle(tx.alloc(a, tx.spr_frame, .{ k + 1, img.width, img.height }), false);
        if (main.button(app, "spr_in", tx.get(tx.spr_from_png), false)) app.askFile(.{ .kind = .png, .run = onFrameIn, .entry = k });
        if (main.button(app, "spr_out", tx.get(tx.spr_to_png), false)) app.askFile(.{ .kind = .png_out, .run = onFrameOut, .entry = k });
        if (e.frames.items.len > 1 and !isDepth(e)) if (main.button(app, "spr_del", tx.get(tx.spr_remove), false)) app.askDelete(.frame, k, e.name);
    }
    if (!isDepth(e)) {
        main.propsTitle(tx.get(tx.p_actions), false);
        if (main.button(app, "spr_add", tx.get(tx.spr_add_frame), false)) app.askFile(.{ .kind = .png, .run = onFrameAdd });
    }
    main.propsTitle(tx.get(tx.info_title), false);
    const archive = app.store.files.items[e.file].archive;
    info.show(app, info.rows(app, std.fmt.allocPrint(a, "sprite:{s}|{s}", .{ archive, e.name }) catch e.name, e, spriteInfo));
    clay.close();
}

/// The sprite's Info: its file (and level); the items with it as their icon, the scripts
/// of its level naming it (`spriteFile="woda1"`).
fn spriteInfo(e: *Edit, app: *App, list: *info.List) void {
    const archive = app.store.files.items[e.file].archive;
    info.defined(list, archive, e.name, false);
    const stem = std.fs.path.stem(e.name[if (std.mem.lastIndexOfScalar(u8, e.name, '\\')) |k| k + 1 else 0..]);
    if (std.mem.eql(u8, archive, sprite_archive)) for (app.catalog.entries.items, 0..) |x, i| {
        if (x.icon.len > 0 and std.ascii.eqlIgnoreCase(x.icon, stem)) list.add(.{ .group = .used, .text = info.entryText(list, x), .to = .{ .entry = i }, .icon = .package });
    };
    if (info.levelOf(archive)) |lv| {
        const other = list.fmt("{s}/other.dat", .{lv});
        for (refs.naming(app, list.a, other, refs.script, list.fmt("\"{s}\"", .{stem}))) |n| list.add(.{ .group = .used, .text = n, .to = .{ .code = .{ .archive = other, .entry = n } }, .icon = .code });
    }
}

/// A colour square; a click on one of the palette (`e`) takes it.
fn swatch(app: *App, id: []const u8, col: [4]u8, size: f32, e: ?*Edit) void {
    const sid = clay.id(id);
    clay.leaf(.{
        .id = sid,
        .layout = .{ .sizing = .{ .width = clay.fixed(size), .height = clay.fixed(size) } },
        .backgroundColor = .{ .r = @floatFromInt(col[0]), .g = @floatFromInt(col[1]), .b = @floatFromInt(col[2]), .a = 255 },
        .cornerRadius = clay.radius(3),
        .border = .{ .color = if (clay.pointerOver(sid)) theme.text else theme.field_border, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } },
    });
    if (e) |ed| if (clay.pointerOver(sid) and app.clicked) {
        ed.color = col;
        if (ed.tool != .pencil) ed.tool = .pencil;
    };
}

/// The sprite's colours: of each group of near ones (3 bits a channel) its mean,
/// the 20 largest groups, dark to light.
fn palette(a: Allocator, e: *const Edit) []const [4]u8 {
    const Sum = struct { n: u32 = 0, rgb: [3]u32 = .{ 0, 0, 0 } };
    var groups: std.AutoHashMapUnmanaged(u16, Sum) = .empty;
    for (e.frames.items) |img| {
        var i: usize = 0;
        while (i < img.pixels.len) : (i += 4) {
            if (img.pixels[i + 3] < 128) continue;
            const p = img.pixels[i..][0..3];
            const key = (@as(u16, p[0] >> 5) << 6) | (@as(u16, p[1] >> 5) << 3) | (p[2] >> 5);
            const g = groups.getOrPut(a, key) catch return &.{};
            if (!g.found_existing) g.value_ptr.* = .{};
            g.value_ptr.n += 1;
            for (0..3) |k| g.value_ptr.rgb[k] += p[k];
        }
    }
    var list: std.ArrayList(Sum) = .empty;
    var it = groups.valueIterator();
    while (it.next()) |v| list.append(a, v.*) catch return &.{};
    std.mem.sort(Sum, list.items, {}, struct {
        fn gt(_: void, x: Sum, y: Sum) bool {
            return x.n > y.n;
        }
    }.gt);
    const top = list.items[0..@min(20, list.items.len)];
    var out: std.ArrayList([4]u8) = .empty;
    for (top) |g| out.append(a, .{ @intCast(g.rgb[0] / g.n), @intCast(g.rgb[1] / g.n), @intCast(g.rgb[2] / g.n), 255 }) catch break;
    std.mem.sort([4]u8, out.items, {}, struct {
        fn dark(_: void, x: [4]u8, y: [4]u8) bool {
            return @as(u32, x[0]) * 3 + @as(u32, x[1]) * 6 + x[2] < @as(u32, y[0]) * 3 + @as(u32, y[1]) * 6 + y[2];
        }
    }.dark);
    return out.items;
}

/// The chosen frame at a whole zoom, centred on a checkerboard; a pixel grid when large.
pub fn draw(app: *App, e: *Edit, rect: c.SDL_FRect) void {
    e.rect = rect;
    if (e.frames.items.len == 0) return;
    const img = e.frames.items[e.frame];
    const fw: f32 = @floatFromInt(img.width);
    const fh: f32 = @floatFromInt(img.height);
    e.zoom = @max(1, @floor(@min((rect.w - 20) / fw, (rect.h - 20) / fh)));
    e.origin = .{ rect.x + (rect.w - fw * e.zoom) / 2, rect.y + (rect.h - fh * e.zoom) / 2 };
    const r = app.r;
    const clip: c.SDL_Rect = .{ .x = @intFromFloat(rect.x), .y = @intFromFloat(rect.y), .w = @intFromFloat(rect.w), .h = @intFromFloat(rect.h) };
    _ = c.SDL_SetRenderClipRect(r, &clip);
    defer _ = c.SDL_SetRenderClipRect(r, null);
    // Transparent pixels show as a checkerboard.
    const cell = @max(e.zoom, 8);
    var y: f32 = 0;
    while (y < fh * e.zoom) : (y += cell) {
        var x: f32 = 0;
        while (x < fw * e.zoom) : (x += cell) {
            const odd = @as(u32, @intFromFloat(x / cell + y / cell)) % 2 == 1;
            _ = if (odd) c.SDL_SetRenderDrawColor(r, 58, 58, 58, 255) else c.SDL_SetRenderDrawColor(r, 44, 44, 44, 255);
            _ = c.SDL_RenderFillRect(r, &.{ .x = e.origin[0] + x, .y = e.origin[1] + y, .w = @min(cell, fw * e.zoom - x), .h = @min(cell, fh * e.zoom - y) });
        }
    }
    _ = c.SDL_RenderTexture(r, e.textures.items[e.frame], null, &.{ .x = e.origin[0], .y = e.origin[1], .w = fw * e.zoom, .h = fh * e.zoom });
    if (e.zoom >= 8) {
        _ = c.SDL_SetRenderDrawColor(r, 0, 0, 0, 60);
        var gx: f32 = 0;
        while (gx <= fw) : (gx += 1) _ = c.SDL_RenderLine(r, e.origin[0] + gx * e.zoom, e.origin[1], e.origin[0] + gx * e.zoom, e.origin[1] + fh * e.zoom);
        var gy: f32 = 0;
        while (gy <= fh) : (gy += 1) _ = c.SDL_RenderLine(r, e.origin[0], e.origin[1] + gy * e.zoom, e.origin[0] + fw * e.zoom, e.origin[1] + gy * e.zoom);
    }
}

pub fn over(e: *const Edit, p: [2]f32) bool {
    return p[0] >= e.rect.x and p[0] < e.rect.x + e.rect.w and p[1] >= e.rect.y and p[1] < e.rect.y + e.rect.h;
}

/// The tool at point `p` (pressed or dragged; `pick` — the right button, eyedropper).
pub fn pointer(e: *Edit, p: [2]f32, pick: bool) void {
    if (e.frames.items.len == 0 or isDepth(e)) return;
    // Painting stops the playback on the frame shown.
    e.playing = false;
    const img = &e.frames.items[e.frame];
    const fx = (p[0] - e.origin[0]) / e.zoom;
    const fy = (p[1] - e.origin[1]) / e.zoom;
    if (fx < 0 or fy < 0) return;
    const x: usize = @intFromFloat(fx);
    const y: usize = @intFromFloat(fy);
    if (x >= img.width or y >= img.height) return;
    const px = img.pixels[(y * img.width + x) * 4 ..][0..4];
    if (pick or e.tool == .picker) {
        if (px[3] >= 128) e.color = px.*;
        if (e.tool == .picker) e.tool = .pencil;
        return;
    }
    const want: [4]u8 = if (e.tool == .eraser) .{ 0, 0, 0, 0 } else e.color;
    if (std.mem.eql(u8, px, &want)) return;
    px.* = want;
    e.stroked = true;
    _ = c.SDL_UpdateTexture(e.textures.items[e.frame], null, img.pixels.ptr, @intCast(img.width * 4));
}

/// The stroke done: written as one step.
pub fn release(app: *App, e: *Edit) void {
    e.painting = false;
    if (!e.stroked) return;
    e.stroked = false;
    var wb: [32]u8 = undefined;
    commit(app, e, std.fmt.bufPrint(&wb, "{s} {d}", .{ tx.get(tx.spr_frame_word), e.frame + 1 }) catch "frame") catch |err| app.setStatus(tx.st_set_failed, .{err});
}

// File dialog answers (app.askFile).
fn onFrameIn(app: *App, ask: main.FileAsk, path: []const u8) !void {
    try importFrame(app, ask.entry, path);
    app.setStatus(tx.st_frame_set, .{ask.entry + 1});
}
fn onFrameOut(app: *App, ask: main.FileAsk, path: []const u8) !void {
    try exportFrame(app, ask.entry, path);
    app.setStatus(tx.st_exported, .{path});
}
fn onFrameAdd(app: *App, _: main.FileAsk, path: []const u8) !void {
    try addFrame(app, path);
    app.setStatus(tx.st_frame_set, .{app.spr.?.frames.items.len});
}
pub fn onNew(app: *App, _: main.FileAsk, path: []const u8) !void {
    const e = try importNew(app, app.spr_new.get(), if (app.spr_new_icons) "icons" else "", path);
    app.setStatus(tx.st_sprite_added, .{e});
}

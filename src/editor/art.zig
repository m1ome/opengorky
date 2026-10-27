//! New art from PNG files: item icons (`icons\<name>.spr` in common/sprite.dat) and
//! model textures. A texture gives a new look: a copy of the model (`gfx_3d\<new>.msh`
//! naming the new `.3df`, its `.ani`/`.bfr` copied) that an item takes as `meshFile`
//! and an enemy through a new `act_*.ss`; the original model stays as it is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const Image = og.formats.image.Image;
const vars = @import("vars.zig");
const common_archive = @import("store.zig").common_archive;
const main = @import("app.zig");
const App = main.App;

const sprite_archive = @import("store.zig").sprite_archive;

/// Icon frames of the game: big (inventory, up to 160×100) and small (51×40).
const big = [2]u32{ 160, 100 };
const small = [2]u32{ 51, 40 };

pub fn readPng(app: *App, path: []const u8) !Image {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(64 << 20));
    defer app.gpa.free(bytes);
    return og.formats.jpeg.decode(app.gpa, bytes);
}

/// `img` resampled to w×h, each pixel the mean of the source pixels under it.
pub fn resize(gpa: Allocator, img: Image, w: u32, h: u32) !Image {
    var out = try Image.init(gpa, w, h);
    const fx = @as(f32, @floatFromInt(img.width)) / @as(f32, @floatFromInt(w));
    const fy = @as(f32, @floatFromInt(img.height)) / @as(f32, @floatFromInt(h));
    for (0..h) |y| for (0..w) |x| {
        const x0: usize = @intFromFloat(@as(f32, @floatFromInt(x)) * fx);
        const y0: usize = @intFromFloat(@as(f32, @floatFromInt(y)) * fy);
        const x1 = @max(x0 + 1, @min(img.width, @as(usize, @intFromFloat(@ceil(@as(f32, @floatFromInt(x + 1)) * fx)))));
        const y1 = @max(y0 + 1, @min(img.height, @as(usize, @intFromFloat(@ceil(@as(f32, @floatFromInt(y + 1)) * fy)))));
        var sum: [4]u32 = .{ 0, 0, 0, 0 };
        for (y0..y1) |sy| for (x0..x1) |sx| for (0..4) |ch| {
            sum[ch] += img.pixels[(sy * img.width + sx) * 4 + ch];
        };
        const n: u32 = @intCast((x1 - x0) * (y1 - y0));
        for (0..4) |ch| out.pixels[(y * w + x) * 4 + ch] = @intCast(sum[ch] / n);
    };
    return out;
}

/// Downscaled to fit `box` keeping the aspect (never enlarged).
fn fit(gpa: Allocator, img: Image, box: [2]u32) !Image {
    const k = @min(1.0, @min(@as(f32, @floatFromInt(box[0])) / @as(f32, @floatFromInt(img.width)), @as(f32, @floatFromInt(box[1])) / @as(f32, @floatFromInt(img.height))));
    return resize(gpa, img, @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(img.width)) * k)))), @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(img.height)) * k)))));
}

/// A free name `<base>_<n>` for which `taken` is false.
fn freeName(a: Allocator, base: []const u8, ctx: anytype, comptime taken: fn (@TypeOf(ctx), []const u8) bool) ![]const u8 {
    for (2..1000) |n| {
        const s = try std.fmt.allocPrint(a, "{s}_{d}", .{ base, n });
        if (!taken(ctx, s)) return s;
    }
    return error.NoFreeName;
}

fn inList(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.ascii.eqlIgnoreCase(x, s)) return true;
    return false;
}

/// New icon from `png` for item class file `file`; returns its name.
pub fn importIcon(app: *App, file: usize, id: []const u8, png: []const u8) ![]const u8 {
    var img = try readPng(app, png);
    defer img.deinit(app.gpa);
    var b = try fit(app.gpa, img, big);
    defer b.deinit(app.gpa);
    var s = try fit(app.gpa, img, small);
    defer s.deinit(app.gpa);
    const bytes = try og.formats.sprite.encode(app.gpa, &.{ b, s });
    errdefer app.gpa.free(bytes);
    const a = app.catalog.arena.allocator();
    const name = try freeName(a, id, app.catalog.icons.items, inList);
    var eb: [96]u8 = undefined;
    _ = try app.store.add(sprite_archive, try std.fmt.bufPrint(&eb, "icons\\{s}.spr", .{name}), bytes, null, true);
    try app.catalog.icons.append(a, name);
    var vb: [96]u8 = undefined;
    try app.store.setVar(file, &.{"spriteFile"}, try std.fmt.bufPrint(&vb, "\"{s}\"", .{name}), "{");
    return name;
}

/// Icon `name` (`icons\\<name>.spr`) gets `png` as its first frame, at that frame's
/// size (a report icon, whose name the exe fixes); one undo step.
pub fn replaceIcon(app: *App, name: []const u8, png: []const u8) !void {
    if (name.len == 0) return error.NoIcon;
    var eb: [96]u8 = undefined;
    const entry = try std.fmt.bufPrint(&eb, "icons\\{s}.spr", .{name});
    const f = app.store.find(sprite_archive, entry) orelse try app.store.file(sprite_archive, entry);
    var spr = try og.formats.sprite.parse(app.gpa, app.store.text(f));
    defer spr.deinit(app.gpa);
    var frames: std.ArrayList(Image) = .empty;
    defer {
        for (frames.items) |*fr| fr.deinit(app.gpa);
        frames.deinit(app.gpa);
    }
    for (spr.frames) |fr| try frames.append(app.gpa, try og.formats.sprite.decodeFrame(app.gpa, fr));
    if (frames.items.len == 0) return error.NoFrame;
    var img = try readPng(app, png);
    defer img.deinit(app.gpa);
    const fresh = try resize(app.gpa, img, frames.items[0].width, frames.items[0].height);
    frames.items[0].deinit(app.gpa);
    frames.items[0] = fresh;
    const bytes = try og.formats.sprite.encode(app.gpa, frames.items);
    errdefer app.gpa.free(bytes);
    var lb: [128]u8 = undefined;
    try app.store.replaceLabeled(f, bytes, std.fmt.bufPrint(&lb, "{s}: PNG", .{entry}) catch entry);
    app.forgetIcon(name);
}

/// A common/other.dat file, edited or from the archive.
fn commonFile(app: *App, comptime fmt: []const u8, args: anytype) ![]const u8 {
    var buf: [128]u8 = undefined;
    const i = try app.store.file(common_archive, try std.fmt.bufPrint(&buf, fmt, args));
    return app.store.text(i);
}

fn modelTaken(app: *App, name: []const u8) bool {
    var buf: [128]u8 = undefined;
    const e = std.fmt.bufPrint(&buf, "gfx_3d\\{s}.msh", .{name}) catch return true;
    if (app.store.find(common_archive, e) != null) return true;
    _ = app.store.file(common_archive, e) catch return false;
    return true;
}

/// Texture `slot` of a parsed model (`mesh.textureNames` order).
fn textureAt(app: *App, m: og.formats.mesh.Mesh, slot: u8) ![]const u8 {
    const names = try og.formats.mesh.textureNames(app.frame.allocator(), m);
    return if (slot < names.len) names[slot] else error.NoTexture;
}

/// Model `mesh` with its texture `slot` from `png` (resized to the original's size)
/// under a new name; the other textures stay. Returns the name.
pub fn newModel(app: *App, mesh: []const u8, png: []const u8, slot: u8) ![]const u8 {
    const a = app.catalog.arena.allocator();
    const msh = try commonFile(app, "gfx_3d\\{s}.msh", .{mesh});
    var m = try og.formats.mesh.parse(app.gpa, msh);
    defer m.deinit();
    const old = try textureAt(app, m, slot);
    var orig = try og.formats.tex3df.decode(app.gpa, try commonFile(app, "gfx_3d\\textures\\{s}", .{old}));
    defer orig.deinit(app.gpa);
    var img = try readPng(app, png);
    defer img.deinit(app.gpa);
    // The model's UVs stay: the texture keeps the original's size and layout.
    var sized = try resize(app.gpa, img, orig.width, orig.height);
    defer sized.deinit(app.gpa);

    const name = try freeName(a, mesh, app, modelTaken);
    var tb: [128]u8 = undefined;
    const tex_name = try std.fmt.bufPrint(&tb, "{s}.3df", .{name});
    var eb: [160]u8 = undefined;
    const tex = try og.formats.tex3df.encodeArgb4444(app.gpa, sized);
    _ = try app.store.add(common_archive, try std.fmt.bufPrint(&eb, "gfx_3d\\textures\\{s}", .{tex_name}), tex, null, true);
    const new_msh = try og.formats.mesh.withTexture(app.gpa, msh, old, tex_name);
    _ = try app.store.add(common_archive, try std.fmt.bufPrint(&eb, "gfx_3d\\{s}.msh", .{name}), new_msh, null, true);
    for ([_][]const u8{ "ani", "bfr" }) |ext| {
        const src = try app.gpa.dupe(u8, try commonFile(app, "gfx_3d\\{s}.{s}", .{ mesh, ext }));
        _ = try app.store.add(common_archive, try std.fmt.bufPrint(&eb, "gfx_3d\\{s}.{s}", .{ name, ext }), src, null, true);
    }
    try app.catalog.meshes.append(a, name);
    return name;
}

/// A new look for an enemy class: its `act_*.ss` copied with a model wearing `png`.
pub fn newLook(app: *App, act: []const u8, png: []const u8, slot: u8) ![]const u8 {
    const mesh = vars.getStr(try commonFile(app, "classes\\{s}", .{act}), "meshFile") orelse return error.NoModel;
    return newAct(app, act, try newModel(app, mesh, png, slot));
}

/// Enemy look `act` (`act_*.ss`) copied with `model` as its `meshFile`; returns the copy's name.
pub fn newAct(app: *App, act: []const u8, model: []const u8) ![]const u8 {
    const a = app.catalog.arena.allocator();
    const act_text = try commonFile(app, "classes\\{s}", .{act});
    const base = act[0 .. std.mem.lastIndexOfScalar(u8, act, '.') orelse act.len];
    const new_base = try freeName(a, base, app.catalog.acts.items, struct {
        fn f(list: []const []const u8, s: []const u8) bool {
            for (list) |x| if (std.ascii.startsWithIgnoreCase(x, s) and x.len == s.len + 3) return true;
            return false;
        }
    }.f);
    const new_act = try std.fmt.allocPrint(a, "{s}.ss", .{new_base});
    var vb: [128]u8 = undefined;
    const text = try vars.set(app.gpa, act_text, "meshFile", try std.fmt.bufPrint(&vb, "\"{s}\"", .{model}), null);
    var eb: [128]u8 = undefined;
    _ = try app.store.add(common_archive, try std.fmt.bufPrint(&eb, "classes\\{s}", .{new_act}), text, null, true);
    try app.catalog.acts.append(a, new_act);
    return new_act;
}

/// The model cache over the archive and the unsaved files (as the preview's).
fn openCache(app: *App) !og.actor.model_cache.Cache {
    var cache = try og.actor.model_cache.Cache.open(app.io, app.gpa, app.dat);
    cache.overlay = .{ .ctx = app, .get = @import("pages.zig").overlayGet };
    return cache;
}

/// Model `mesh` (textures, skeleton, animations, attach points) as a `.glb` at `path`.
pub fn exportGlb(app: *App, mesh: []const u8, path: []const u8) !void {
    var cache = try openCache(app);
    defer cache.deinit();
    const model = cache.get(mesh) orelse return error.NoModel;
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const names = try og.formats.mesh.textureNames(a, model.mesh);
    const images = try a.alloc(?Image, names.len);
    var buf: [160]u8 = undefined;
    for (names, images) |n, *img| {
        const bytes = cache.readFile(try std.fmt.bufPrint(&buf, "gfx_3d\\textures\\{s}", .{n})) catch null;
        img.* = if (bytes) |b| og.formats.tex3df.decode(a, b) catch null else null;
    }
    const glb = try og.actor.gltf.exportGlb(app.gpa, mesh, model.mesh, model.anims.items, model.frames, images);
    defer app.gpa.free(glb);
    try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = glb });
}

fn textureTaken(app: *App, name: []const u8) bool {
    var buf: [160]u8 = undefined;
    const e = std.fmt.bufPrint(&buf, "gfx_3d\\textures\\{s}", .{name}) catch return true;
    if (app.store.find(common_archive, e) != null) return true;
    _ = app.store.file(common_archive, e) catch return false;
    return true;
}

/// A new model `<base>_<n>` from the `.glb` at `path` (the exe's limits checked): its
/// `.msh`, `.ani`, `.bfr` and textures; a texture name the game has already (an exported
/// model's own) gets a free `<model>_<n>.3df`, so no game texture changes.
pub fn importGlb(app: *App, base: []const u8, path: []const u8) !struct { name: []const u8, textures: usize } {
    const glb = try std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(1 << 30));
    defer app.gpa.free(glb);
    const name = try freeName(app.catalog.arena.allocator(), base, app, modelTaken);
    var files = try og.actor.gltf.importGlb(app.gpa, glb, name);
    defer files.deinit();
    const fa = files.arena.allocator();
    var msh: []const u8 = files.msh;
    const tex_names = try fa.alloc([]const u8, files.textures.len);
    for (files.textures, tex_names, 0..) |t, *tn, i| {
        tn.* = t.name;
        var n: usize = 1;
        // Not one the game has, nor one this import names (else withTexture renames both).
        while (textureTaken(app, tn.*) or inList(tex_names[0..i], tn.*) or (tn.*.ptr != t.name.ptr and for (files.textures) |o| {
            if (std.ascii.eqlIgnoreCase(o.name, tn.*)) break true;
        } else false)) : (n += 1) tn.* = try std.fmt.allocPrint(fa, "{s}_{d}.3df", .{ name, n });
        if (tn.*.ptr != t.name.ptr) msh = try og.formats.mesh.withTexture(fa, msh, t.name, tn.*);
    }
    var m = try og.formats.mesh.parse(app.gpa, msh);
    defer m.deinit();
    try og.formats.mesh.checkLimits(m);
    var eb: [160]u8 = undefined;
    for (files.textures, tex_names) |t, tn| _ = try app.store.add(common_archive, try std.fmt.bufPrint(&eb, "gfx_3d\\textures\\{s}", .{tn}), try app.gpa.dupe(u8, t.data), null, true);
    for ([_][]const u8{ "msh", "ani", "bfr" }, [_][]const u8{ msh, files.ani, files.bfr }) |ext, data| {
        _ = try app.store.add(common_archive, try std.fmt.bufPrint(&eb, "gfx_3d\\{s}.{s}", .{ name, ext }), try app.gpa.dupe(u8, data), null, true);
    }
    try app.catalog.meshes.append(app.catalog.arena.allocator(), name);
    return .{ .name = name, .textures = files.textures.len };
}

/// The animations of the `.glb` at `path` into model `mesh` (same skeleton): one of the
/// same name replaced, new ones added, unused frames dropped. Names added and replaced.
pub fn importAnims(app: *App, a: Allocator, mesh: []const u8, path: []const u8) !struct { added: []const []const u8, replaced: []const []const u8 } {
    const glb = try std.Io.Dir.cwd().readFileAlloc(app.io, path, app.gpa, .limited(1 << 30));
    defer app.gpa.free(glb);
    var cache = try openCache(app);
    defer cache.deinit();
    const model = cache.get(mesh) orelse return error.NoModel;
    var files = try og.actor.gltf.importAnimationsInto(app.gpa, glb, model.mesh, model.anims.items, model.frames);
    defer files.deinit();
    var list = try og.formats.anim.parseAni(app.gpa, files.ani);
    defer list.deinit();
    var bf = try og.formats.anim.parseBfr(app.gpa, files.bfr, model.frames.bones);
    defer bf.deinit(app.gpa);
    const B = model.frames.bones;
    var added: std.ArrayList([]const u8) = .empty;
    var replaced: std.ArrayList([]const u8) = .empty;
    for (list.items) |an| {
        // A replaced one has other frames (the kept ones may have moved down).
        const old = model.anims.find(an.name) orelse {
            try added.append(a, try a.dupe(u8, an.name));
            continue;
        };
        const was = std.mem.sliceAsBytes(model.frames.matrices[old.first * B .. (old.last + 1) * B]);
        if (!std.mem.eql(u8, was, std.mem.sliceAsBytes(bf.matrices[an.first * B .. (an.last + 1) * B]))) try replaced.append(a, try a.dupe(u8, an.name));
    }
    var eb: [160]u8 = undefined;
    var lb: [160]u8 = undefined;
    const label = std.fmt.bufPrint(&lb, "{s}: .glb animations", .{mesh}) catch null;
    // The frames first: the old .ani still fits them (no fewer frames; undo takes the .ani back first).
    const bfr = try app.store.file(common_archive, try std.fmt.bufPrint(&eb, "gfx_3d\\{s}.bfr", .{mesh}));
    const ani = try app.store.file(common_archive, try std.fmt.bufPrint(&eb, "gfx_3d\\{s}.ani", .{mesh}));
    try app.store.replaceLabeled(bfr, try app.gpa.dupe(u8, files.bfr), label);
    try app.store.replaceLabeled(ani, try app.gpa.dupe(u8, files.ani), label);
    app.preview.reload();
    return .{ .added = added.items, .replaced = replaced.items };
}

/// A model field (`.msh` chunks 11 centre, 12 height, 13 attach points).
pub const MeshField = union(enum) {
    height: f32,
    center: struct { k: usize, v: f32 },
    hold_name: struct { i: usize, v: []const u8 },
    hold_bone: struct { i: usize, v: u32 },
    /// Offset x, y, z (k 0–2) or angles around X, Y, Z (k 3–5).
    hold_param: struct { i: usize, k: usize, v: f32 },
};

/// Field `f` of model `mesh` set (one undo step; the exe's limits checked); `what` names it.
pub fn setMeshField(app: *App, mesh: []const u8, f: MeshField, what: []const u8) !void {
    var eb: [160]u8 = undefined;
    const file = try app.store.file(common_archive, try std.fmt.bufPrint(&eb, "gfx_3d\\{s}.msh", .{mesh}));
    var m = try og.formats.mesh.parse(app.gpa, app.store.text(file));
    defer m.deinit();
    const n = m.hold_modes.len;
    switch (f) {
        .height => |v| m.height = v,
        .center => |c| m.center[c.k] = c.v,
        .hold_name => |h| if (h.i < n) {
            m.hold_modes[h.i].name = h.v;
        } else return error.NoAttachPoint,
        .hold_bone => |h| if (h.i < n) {
            m.hold_modes[h.i].bone = h.v;
        } else return error.NoAttachPoint,
        .hold_param => |h| if (h.i < n) {
            m.hold_modes[h.i].params[h.k] = h.v;
        } else return error.NoAttachPoint,
    }
    try og.formats.mesh.checkLimits(m);
    const bytes = try og.formats.mesh.encode(app.gpa, m);
    errdefer app.gpa.free(bytes);
    var lb: [160]u8 = undefined;
    try app.store.replaceLabeled(file, bytes, std.fmt.bufPrint(&lb, "{s}.msh: {s}", .{ mesh, what }) catch null);
    app.preview.reload();
}

/// Texture `slot` of model `mesh` as a PNG at `path` (to paint a new one over).
pub fn exportTexture(app: *App, mesh: []const u8, path: []const u8, slot: u8) !void {
    var m = try og.formats.mesh.parse(app.gpa, try commonFile(app, "gfx_3d\\{s}.msh", .{mesh}));
    defer m.deinit();
    var img = try og.formats.tex3df.decode(app.gpa, try commonFile(app, "gfx_3d\\textures\\{s}", .{try textureAt(app, m, slot)}));
    defer img.deinit(app.gpa);
    try writePng(app, img, path);
}

/// The textures of model `mesh` (`mesh.textureNames` order); none if it can't be read.
pub fn textures(app: *App, a: std.mem.Allocator, mesh: []const u8) []const []const u8 {
    var m = og.formats.mesh.parse(app.gpa, commonFile(app, "gfx_3d\\{s}.msh", .{mesh}) catch return &.{}) catch return &.{};
    defer m.deinit();
    // The names point into the mesh bytes: copied before it goes.
    const names = og.formats.mesh.textureNames(a, m) catch return &.{};
    const out = a.alloc([]const u8, names.len) catch return &.{};
    for (names, out) |n, *o| o.* = a.dupe(u8, n) catch return &.{};
    return out;
}

/// Icon `name` (its big frame) as a PNG at `path`.
pub fn exportIcon(app: *App, name: []const u8, path: []const u8) !void {
    var buf: [96]u8 = undefined;
    const entry = try std.fmt.bufPrint(&buf, "icons\\{s}.spr", .{name});
    const i = app.store.find(sprite_archive, entry) orelse try app.store.file(sprite_archive, entry);
    var spr = try og.formats.sprite.parse(app.gpa, app.store.text(i));
    defer spr.deinit(app.gpa);
    var img = try og.formats.sprite.decodeFrame(app.gpa, spr.frames[0]);
    defer img.deinit(app.gpa);
    try writePng(app, img, path);
}

pub fn writePng(app: *App, img: Image, path: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();
    try og.formats.png.write(app.gpa, &out.writer, img);
    try std.Io.Dir.cwd().writeFile(app.io, .{ .sub_path = path, .data = out.written() });
}

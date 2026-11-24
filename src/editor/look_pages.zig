//! A look's asset pages (the Assets tier; a character only picks them, char_page.zig):
//! a model (`gfx_3d\<name>.msh`: its height, centre, rotation and attach points, to
//! glTF), the animations a look script binds (an enemy's `act_*.ss`, a hero's file: the
//! model's animations and their sounds on the stage, the bindings in the constructor), a
//! texture (`gfx_3d\textures\<name>`: to PNG, from one in place when the editor made it).
//! Each with where it is used.

const std = @import("std");
const baseName = @import("doctab.zig").baseName;
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const doctabs = @import("doctabs.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const model = @import("model.zig");
const info = @import("info.zig");
const art = @import("art.zig");
const frame = @import("frame.zig");
const entries = @import("entries.zig");
const entry_model = @import("entry_model.zig");
const entry_anims = @import("entry_anims.zig");
const effectpage = @import("effectpage.zig");
const store_mod = @import("store.zig");
const common_archive = store_mod.common_archive;
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;

const models_dir = "gfx_3d\\";
const textures_dir = "gfx_3d\\textures\\";

/// The models (`gfx_3d\*.msh`, new ones too), by name.
pub fn models(app: *App, a: Allocator) []const []const u8 {
    return stems(a, app.store.listing(a, common_archive, struct {
        fn f(e: []const u8) bool {
            return std.ascii.startsWithIgnoreCase(e, models_dir) and std.mem.indexOfScalarPos(u8, e, models_dir.len, '\\') == null and std.ascii.endsWithIgnoreCase(e, ".msh");
        }
    }.f, true), models_dir.len, ".msh".len);
}

/// The model textures (`gfx_3d\textures\*.3df`, new ones too), by file name.
pub fn textures(app: *App, a: Allocator) []const []const u8 {
    return stems(a, app.store.listing(a, common_archive, struct {
        fn f(e: []const u8) bool {
            return std.ascii.startsWithIgnoreCase(e, textures_dir) and std.ascii.endsWithIgnoreCase(e, ".3df");
        }
    }.f, true), textures_dir.len, 0);
}

fn stems(a: Allocator, es: []const []const u8, dir: usize, ext: usize) []const []const u8 {
    const out = a.alloc([]const u8, es.len) catch return &.{};
    for (es, out) |e, *o| o.* = e[dir .. e.len - ext];
    return out;
}

/// Look script `file`'s key (`archive|entry`: its animations' page).
pub fn scriptKey(app: *App, a: Allocator, file: usize) []const u8 {
    const f = app.store.files.items[file];
    return @import("doctab.zig").join(a, f.archive, f.entry) catch "";
}

/// The look script of key `key` (`archive|entry`).
fn scriptFile(app: *App, key: []const u8) ?usize {
    const p = @import("doctab.zig").split(key) orelse return null;
    return app.store.file(p[0], p[1]) catch null;
}

/// A page's head: its name, what it is, its file.
fn head(name: []const u8, kind: tx.Msg, file: []const u8) void {
    gui.headCard();
    gui.txtWrap(name, .heading, theme.text, font_mod.bold);
    gui.row(lay.space.sm);
    gui.chip(tx.get(kind));
    gui.txtClip(file, .caption, theme.dim, font_mod.regular);
    clay.close();
    gui.blockEnd();
}

/// The Info block (folded at first) of page `key`: where it is used.
pub fn infoBlock(app: *App, a: Allocator, key: []const u8, ctx: []const u8, comptime build: fn ([]const u8, *App, *info.List) void) void {
    const rows = info.rows(app, key, ctx, build);
    if (gui.block(app, "info", tx.get(tx.info_title), .{ .folded = true, .summary = tx.alloc(a, tx.sum_used, .{used(rows)}) })) {
        info.show(app, rows);
        gui.blockEnd();
    }
}

fn used(rows: []const info.Row) usize {
    var n: usize = 0;
    for (rows) |r| n += @intFromBool(r.group == .used and r.to != .none);
    return n;
}

pub fn modelPage(app: *App, a: Allocator) void {
    const mesh = app.model_sel.get();
    if (mesh.len == 0) return;
    // The model alone: its animation picked on a look's page, else its first.
    const l = entry_model.look(app, a, std.fmt.allocPrint(a, "meshFile=\"{s}\";", .{mesh}) catch "", null, null, &.{});
    frame.stage(app);
    entry_model.modelPane(app, l, entry_model.pointInfo(app, a, mesh), tx.model_hint);
    entry_model.pointHandles(app, mesh);
    frame.props(app, "model_props");
    head(mesh, tx.sec_model, std.fmt.allocPrint(a, models_dir ++ "{s}.msh", .{mesh}) catch mesh);
    if (gui.block(app, "model", tx.alloc(a, tx.tag_proto, .{tx.get(tx.sec_model)}), .{ .summary = entry_model.modelSummary(app, a, mesh) })) {
        entry_model.modelFields(app, a, null, mesh);
        if (app.ogLayout() and modelFree(app, mesh)) {
            if (gui.footer(app, "model_delete", &.{tx.get(tx.mdl_delete)}, null) != null) app.askDelete(.model, 0, mesh);
            gui.fieldNote(tx.get(tx.mdl_delete_note), theme.dim);
        }
        gui.blockEnd();
    }
    infoBlock(app, a, std.fmt.allocPrint(a, "model:{s}", .{mesh}) catch mesh, mesh, modelInfo);
    clay.closeScrollColumn();
}

/// A model's Info: its file, its textures, the looks and entries wearing it.
fn modelInfo(mesh: []const u8, app: *App, list: *info.List) void {
    info.defined(list, common_archive, list.fmt(models_dir ++ "{s}.msh", .{mesh}), false);
    for (art.textures(app, list.a, mesh)) |t| list.add(.{ .group = .refs, .text = t, .to = .{ .doc = .{ .tab = .textures, .name = t } }, .icon = .image });
    const n = list.rows.items.len;
    // OpenGorky: the blocks naming it (`mesh = "…"`: a look's, a weapon's), each at its line.
    if (app.ogLayout()) {
        for (app.store.listing(list.a, store_mod.og_src, null, true)) |path| {
            const t = app.store.text(app.store.file(store_mod.og_src, path) catch continue);
            if (meshAt(t, mesh)) |at| list.add(.{ .group = .used, .text = path, .to = .{ .code = .{ .archive = store_mod.og_src, .entry = path, .at = at } }, .icon = .code });
        }
        return info.usedNone(list, n, tx.look_used_none);
    }
    for (app.catalog.acts.items) |act| {
        const f = actFile(app, act) orelse continue;
        if (std.ascii.eqlIgnoreCase(model.getStr(app.store.text(f), "mesh") orelse "", mesh)) list.add(.{ .group = .used, .text = act, .to = .{ .doc = .{ .tab = .anims, .name = scriptKey(app, list.a, f) } }, .icon = .play });
    }
    for (app.catalog.entries.items, 0..) |e, i| {
        const f = entries.fileOf(app, e) orelse continue;
        if (std.ascii.eqlIgnoreCase(entries.meshOf(app, e, app.store.text(f)) orelse "", mesh)) list.add(.{ .group = .used, .text = info.entryText(list, e), .to = .{ .entry = i }, .icon = if (e.kind == .enemy or e.kind == .hero) .user else .package });
    }
    info.usedNone(list, n, tx.look_used_none);
}

/// Where text `t` names model `mesh` (`mesh = "grandma"`, `effect_mesh = "…"`), else null.
fn meshAt(t: []const u8, mesh: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, t, from, "mesh = \"")) |k| : (from = k + 1) {
        const v = t[k + 8 ..];
        if (std.mem.startsWith(u8, v, mesh) and v.len > mesh.len and v[mesh.len] == '"') return k;
    }
    return null;
}

/// OpenGorky: the models the project has of its own (`src/assets/models/`, new ones not
/// saved yet too) and those its blocks name, kept while the Store stays the same.
var og_models: struct {
    rev: usize = std.math.maxInt(usize),
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    own: std.StringHashMapUnmanaged(void) = .empty,
    /// Of `own`, those the game has none of.
    alone: std.StringHashMapUnmanaged(void) = .empty,
    used: std.StringHashMapUnmanaged(void) = .empty,
} = .{};

/// What the tree says beside model `name` of an OpenGorky project: the project's own,
/// and whether nothing wears it (a game model unused is the game's business: "").
pub fn modelNote(app: *App, name: []const u8) []const u8 {
    const m = &og_models;
    if (m.rev != app.store.rev) {
        m.rev = app.store.rev;
        _ = m.arena.reset(.retain_capacity);
        m.own = .empty;
        m.alone = .empty;
        m.used = .empty;
        const a = m.arena.allocator();
        for (models(app, a)) |x| {
            var eb: [160]u8 = undefined;
            var pb: [512]u8 = undefined;
            const entry = std.fmt.bufPrint(&eb, models_dir ++ "{s}.msh", .{x}) catch continue;
            const sub = store_mod.ownAsset(&pb, app.store.root, common_archive, entry) orelse continue;
            const on_disk = if (app.store.root) |r| if (r.statFile(app.io, sub, .{})) |_| true else |_| false else false;
            if (!on_disk and !art.editorMade(app, entry)) continue;
            m.own.put(a, x, {}) catch {};
            if (!app.store.inGame(common_archive, entry)) m.alone.put(a, x, {}) catch {};
        }
        for (app.store.listing(a, store_mod.og_src, null, false)) |path| {
            const t = app.store.text(app.store.file(store_mod.og_src, path) catch continue);
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, t, from, "mesh = \"")) |k| : (from = k + 1) {
                const v = t[k + 8 ..];
                const q = std.mem.indexOfScalar(u8, v, '"') orelse break;
                m.used.put(a, a.dupe(u8, v[0..q]) catch continue, {}) catch {};
            }
        }
    }
    if (!m.own.contains(name)) return "";
    return tx.get(if (m.used.contains(name)) tx.mdl_own else tx.mdl_own_unused);
}

/// OpenGorky: model `name` is the project's alone (the game has none) and nothing wears it.
pub fn modelFree(app: *App, name: []const u8) bool {
    _ = modelNote(app, name);
    return og_models.alone.contains(name) and !og_models.used.contains(name);
}

/// Model `name` taken out of the project (OpenGorky; one undo step, saving deletes the
/// files from src/assets/): its .msh, .ani, .bfr and the textures of its that neither the
/// game nor another model of the project has.
pub fn deleteModel(app: *App, name: []const u8) !void {
    if (!modelFree(app, name)) return error.ModelNotFree;
    const a = app.frame.allocator();
    var files: std.ArrayList(usize) = .empty;
    // Its textures read before the .msh naming them goes.
    for (art.textures(app, a, name)) |t| {
        const e = try std.fmt.allocPrint(a, textures_dir ++ "{s}", .{t});
        if (app.store.inGame(common_archive, e)) continue;
        // A game model names only the game's textures: the project's other models are enough.
        var it = og_models.own.keyIterator();
        const shared = find: while (it.next()) |m| {
            if (std.mem.eql(u8, m.*, name)) continue;
            for (art.textures(app, a, m.*)) |u| if (std.ascii.eqlIgnoreCase(u, t)) break :find true;
        } else false;
        if (!shared) if (app.store.file(common_archive, e)) |i| try files.append(a, i) else |_| {};
    }
    for ([_][]const u8{ "msh", "ani", "bfr" }) |ext| {
        const e = try std.fmt.allocPrint(a, models_dir ++ "{s}.{s}", .{ name, ext });
        if (app.store.file(common_archive, e)) |i| try files.append(a, i) else |_| {}
    }
    if (files.items.len == 0) return error.NoModelFiles;
    if (doctabs.isShown(app, .models, name)) doctabs.dropActive(app);
    try app.store.delete(files.items);
    app.setStatus(tx.st_mdl_deleted, .{ name, files.items.len });
}

/// A new model from a `.glb` (OpenGorky, the tree's Models): only added — named after the
/// file, nothing wears it until a look's or weapon's Model picks it.
pub fn onGlbNew(app: *App, _: app_mod.FileAsk, path: []const u8) !void {
    var buf: [24]u8 = undefined;
    var n: usize = 0;
    const stem = std.fs.path.stem(path);
    for (stem) |ch| if (n < buf.len and (std.ascii.isAlphanumeric(ch) or ch == '_')) {
        buf[n] = std.ascii.toLower(ch);
        n += 1;
    };
    const r = art.importGlb(app, if (n > 0) buf[0..n] else "model", path, app.importTarget()) catch |err| return entry_model.glbFailed(app, err);
    @import("doctabs.zig").show(app, .models, r.name);
    app.setStatusPort(tx.st_glb_new, .{ r.name, r.textures }, tx.st_og_art);
}

fn actFile(app: *App, act: []const u8) ?usize {
    var buf: [128]u8 = undefined;
    return app.store.file(common_archive, std.fmt.bufPrint(&buf, "classes\\{s}", .{act}) catch return null) catch null;
}

pub fn animsPage(app: *App, a: Allocator) void {
    const key = app.anims_sel.get();
    const file = scriptFile(app, key) orelse return;
    const act = app.store.text(file);
    const l = entry_model.look(app, a, act, null, null, &.{});
    frame.stage(app);
    entry_model.lookStage(app, a, l, act, null, null, @import("entry_attacks.zig").spinLanes(app, a, file, act, l.file));
    frame.props(app, "anims_props");
    const f = app.store.files.items[file];
    head(baseName(f.entry), tx.sec_anims, f.archive);
    entry_anims.section(app, a, file, act, l.mesh, l.file);
    infoBlock(app, a, std.fmt.allocPrint(a, "anims:{s}", .{key}) catch key, key, animsInfo);
    clay.closeScrollColumn();
}

/// A look script's Info: its file, its model, the characters it gives their look.
fn animsInfo(key: []const u8, app: *App, list: *info.List) void {
    const file = scriptFile(app, key) orelse return;
    const f = app.store.files.items[file];
    info.defined(list, f.archive, f.entry, true);
    const text = app.store.text(file);
    if (model.textStr(app, text, "mesh")) |m| list.add(.{ .group = .refs, .text = m, .to = .{ .doc = .{ .tab = .models, .name = list.a.dupe(u8, m) catch m } }, .icon = .box });
    const n = list.rows.items.len;
    for (app.catalog.entries.items, 0..) |e, i| {
        if (e.kind != .enemy and e.kind != .hero) continue;
        const ef = entries.fileOf(app, e) orelse continue;
        if (lookFile(app, e, app.store.text(ef)) == file) list.add(.{ .group = .used, .text = info.entryText(list, e), .to = .{ .entry = i }, .icon = .user });
    }
    info.usedNone(list, n, tx.look_used_none);
}

/// The script with a fighter's look (model, animation bindings): an enemy's `act_*.ss`, a
/// hero's own file or the class's it includes; null: none.
pub fn lookFile(app: *App, e: @import("catalog.zig").Entry, text: []const u8) ?usize {
    if (e.kind == .enemy) return actFile(app, entries.actOf(text) orelse return null);
    // The file whose text it is (lookOf reads it through the Store).
    return model.fileOf(app, entries.lookOf(app, text));
}

pub fn texturePage(app: *App, a: Allocator) void {
    const name = app.texture_sel.get();
    if (name.len == 0) return;
    const entry = std.fmt.allocPrint(a, textures_dir ++ "{s}", .{name}) catch return;
    const t = effectpage.cached(app, entry);
    frame.stage(app);
    // As large as the stage allows (whole times when it fits), pixels kept.
    const sid = clay.id("tex_stage");
    clay.open(.{ .id = sid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.viewport });
    if (t) |tt| {
        // Last frame's room (none yet: its own size).
        const room: [2]f32 = if (clay.box(sid)) |b| .{ b.width - 2 * lay.space.xl, b.height - 2 * lay.space.xl } else .{ tt.w, tt.h };
        const fit = @min(4, @min(room[0] / tt.w, room[1] / tt.h));
        const k = if (fit >= 1) @floor(fit) else @max(0.05, fit);
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(tt.w * k), .height = clay.fixed(tt.h * k) } }, .image = .{ .imageData = tt.tex } });
    } else gui.txt(tx.get(tx.tex_none), .body, theme.warn, font_mod.regular);
    clay.close();
    frame.props(app, "tex_props");
    head(name, tx.chip_texture, entry);
    if (gui.block(app, "texture", tx.get(tx.chip_texture), .{})) {
        if (t) |tt| gui.propRow(tx.get(tx.p_size), std.fmt.allocPrint(a, "{d} × {d}", .{ tt.w, tt.h }) catch "");
        // A game texture is shared: replaced only where the editor made it.
        const own = art.editorMade(app, entry);
        var labels: [2][]const u8 = .{ tx.get(tx.b_export_texture), tx.get(tx.b_tex_in) };
        if (gui.footer(app, "tex_foot", labels[0..if (own) 2 else 1], null)) |k| app.askFile(if (k == 0) .{ .kind = .png_out, .run = onTexOut, .name = name } else .{ .kind = .png, .run = onTexIn });
        if (!own) gui.note(tx.get(tx.tex_shared));
        gui.blockEnd();
    }
    infoBlock(app, a, std.fmt.allocPrint(a, "texture:{s}", .{name}) catch name, name, textureInfo);
    clay.closeScrollColumn();
}

/// A texture's Info: its file, the models wearing it.
fn textureInfo(name: []const u8, app: *App, list: *info.List) void {
    info.defined(list, common_archive, list.fmt(textures_dir ++ "{s}", .{name}), false);
    const n = list.rows.items.len;
    for (models(app, list.a)) |m| for (art.textures(app, list.a, m)) |t| if (std.ascii.eqlIgnoreCase(t, name)) {
        list.add(.{ .group = .used, .text = m, .to = .{ .doc = .{ .tab = .models, .name = m } }, .icon = .box });
        break;
    };
    info.usedNone(list, n, tx.look_used_none);
}

// File dialog answers of the pages (app.askFile), on the document shown.
pub fn onGlbOut(app: *App, _: app_mod.FileAsk, path: []const u8) !void {
    try art.exportGlb(app, app.model_sel.get(), path);
    app.setStatus(tx.st_glb_out, .{path});
}
pub fn onAnimsIn(app: *App, _: app_mod.FileAsk, path: []const u8) !void {
    const file = scriptFile(app, app.anims_sel.get()) orelse return error.NoLook;
    return entry_model.animsIn(app, model.ownStr(app, file, "mesh") orelse return error.NoModel, path);
}
fn onTexOut(app: *App, _: app_mod.FileAsk, path: []const u8) !void {
    const f = try app.store.file(common_archive, try std.fmt.allocPrint(app.frame.allocator(), textures_dir ++ "{s}", .{app.texture_sel.get()}));
    var img = try og.formats.tex3df.decode(app.gpa, app.store.text(f));
    defer img.deinit(app.gpa);
    try art.writePng(app, img, path);
    app.setStatus(tx.st_exported, .{path});
}
/// The texture from a PNG in place (one the editor made: no game model wears it).
fn onTexIn(app: *App, _: app_mod.FileAsk, path: []const u8) !void {
    const name = app.texture_sel.get();
    const entry = try std.fmt.allocPrint(app.frame.allocator(), textures_dir ++ "{s}", .{name});
    if (!art.editorMade(app, entry)) return error.GameTexture;
    const f = try app.store.file(common_archive, entry);
    var orig = try og.formats.tex3df.decode(app.gpa, app.store.text(f));
    defer orig.deinit(app.gpa);
    var img = try art.readPng(app, path);
    defer img.deinit(app.gpa);
    try app.store.replaceLabeled(f, try art.modelTexture(app.gpa, img, orig, app.importTarget()), entry);
    effectpage.forget(app, entry);
    app.preview.reload();
    app.setStatusPort(tx.st_tex_in, .{name}, tx.st_og_art);
}

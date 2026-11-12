//! The loaders: what reads a game into the core, one per kind of project. `ogs`: an
//! OpenGorky project (its OG Script sources, or their package `dist/<id>.ogp`); `classic`:
//! the original game's files (the dat archives, the Classic scripts, adjust.kdt). The
//! client asks which a path is (`kindOf`: the OGS loader's `probe` first), opens it
//! (`openGame`, the one loader it is) and fills the core (`loadCore`). The readers both
//! use: assets by logical path, maps, a level's assets, the rules as text and their codec,
//! the worlds' factory. Its clients: the viewer (viewer/app/run.zig), gorky-tool
//! (tool/common.zig), the editor; compose (the converter, the OG writer, the build) works
//! over them.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const font = @import("formats.zig").font;
const lang = @import("formats.zig").lang;
const manifest = @import("formats.zig").manifest;
const entity = @import("core.zig").entity;
const modules = @import("core.zig").modules;

/// An OpenGorky project (OG Script).
pub const ogs = @import("loaders/ogs.zig");
/// The original game's files.
pub const classic = @import("loaders/classic.zig");
/// Rules as text: the `rules\*.ss` files over the core's tables, and back.
pub const rules_text = @import("loaders/rules_text.zig");
pub const codec = @import("loaders/codec.zig");
/// A world's files, scenes and dialogs, mods (the game's world factory `world.Opener`;
/// an OpenGorky project's through `world.reader`).
pub const world = @import("loaders/world.zig");
/// A location's map from its level files (a world's source at level entry; the editor).
pub const map = @import("loaders/map.zig");
const level_assets = @import("loaders/level_assets.zig");
/// Assets by logical path (`models/…`, `sprites/…`, `levels/<level>/…`) over the
/// game's archives and folders: what every reader of models, sprites, sounds, fonts,
/// backgrounds, maps and videos asks.
pub const assets = @import("loaders/assets.zig");

/// The kinds of game a path holds.
pub const Kind = enum { classic, ogs };

/// What `path` holds: an OpenGorky project or its package (`ogs.probe`), a game folder
/// with `dat` (`classic.probe`); null: neither.
pub fn kindOf(io: Io, path: []const u8) ?Kind {
    if (path.len == 0) return null;
    if (ogs.probe(io, path)) return .ogs;
    if (classic.probe(io, path)) return .classic;
    return null;
}

/// `path` is a game a loader opens (kindOf).
pub fn isGameDir(io: Io, path: []const u8) bool {
    return kindOf(io, path) != null;
}

/// A game folder opened for reading (openGame): the folder, its `dat` and its manifest.
pub const Game = struct {
    root: Io.Dir,
    dat: Io.Dir,
    manifest: manifest.Manifest,

    pub fn close(self: *Game, io: Io) void {
        self.dat.close(io);
        self.root.close(io);
    }
};

/// Game `path` opened by its loader, in the order every client reads it: the manifest
/// first (error.EngineTooNew: a project for a newer OpenGorky), then an OpenGorky project
/// through the OGS loader (its rules, records and locations; `dat` the installed game's;
/// the worlds open its locations through world.reader), else the original's files through
/// the Classic one (the built-in rules, adjust.kdt, `dat` iterable).
pub fn openGame(io: Io, path: []const u8) !Game {
    if (ogs.isPackage(path)) return openPackage(io, path);
    var root = try Io.Dir.cwd().openDir(io, path, .{});
    errdefer root.close(io);
    const m = try manifest.apply(io, root);
    world.reader = null;
    if (m.format == .ogs) {
        // The project's battle starts: the OG reader's (ogs.scanStarts).
        const dat = try ogs.open(io, root);
        world.reader = ogs.factory();
        modules.battle_named = ogs.isBattle;
        return .{ .root = root, .dat = dat, .manifest = m };
    }
    return .{ .root = root, .dat = try classic.open(io, root), .manifest = m };
}

/// An OpenGorky project's package (`<project>/dist/<id>.ogp`, what the viewer plays) opened
/// as openGame opens its folder: `root` is the project (the package's folder's parent).
fn openPackage(io: Io, path: []const u8) !Game {
    var dist = try Io.Dir.cwd().openDir(io, std.fs.path.dirname(path) orelse ".", .{});
    defer dist.close(io);
    var root = try dist.openDir(io, "..", .{});
    errdefer root.close(io);
    const dat = try ogs.openPackage(io, root, path);
    errdefer dat.close(io);
    const m = manifest.Manifest.parse(ogs.manifestText());
    if (!m.supported()) return error.EngineTooNew;
    world.reader = ogs.factory();
    modules.battle_named = ogs.isBattle;
    return .{ .root = root, .dat = dat, .manifest = m };
}

/// The assets a client reads: an open OpenGorky project's own (src/assets/, its
/// package) over the installed game's archives under `dat`; the game's alone otherwise.
pub fn assetStack(io: Io, gpa: Allocator, dat: Io.Dir) !assets.Stack {
    return .og(io, gpa, ogs.ownAssets(), dat);
}

/// The core every client starts with after openGame, from the loader that opened it: an
/// OpenGorky project's archetypes and texts (ogs.loadCore), else the original's
/// classic_id texts and its classes and heroes as the core's records (classic.loadCore).
/// The viewer and gorky-tool; the editor reads the texts with its catalog.
pub fn loadCore(io: Io, dat: Io.Dir) void {
    if (world.reader != null) return ogs.loadCore();
    classic.loadCore(io, dat);
}

/// The examine texts (entity.texts): an OpenGorky project's Examine rows (read with the
/// core), else the original's `items.inf`/`activeareas.inf` (classic.loadExamine);
/// false: none.
pub fn loadExamine(io: Io, dat: Io.Dir) bool {
    if (world.reader != null) return entity.texts.examine.count() > 0;
    return classic.loadExamine(io, dat);
}

pub const loadTexts = classic.loadTexts;

/// The classic_id texts as a table (the viewer's UI texts too): an OpenGorky project's
/// UiText rows, else classic.loadTexts' string.tab; null: none yet.
pub fn textTable() ?*const @import("formats.zig").strtab.Table {
    if (world.reader != null) {
        og_table = .{ .map = entity.texts.map };
        return &og_table;
    }
    return classic.textTable();
}

/// textTable's view of an OpenGorky project's texts (the OG reader owns them).
var og_table: @import("formats.zig").strtab.Table = .{};

/// The dialog font (`02_dialog` + the language's letters, `common/other.dat`; the
/// language of loadTexts) as the core's (entity.dialog_font: subtitle pages), read once;
/// the parsed font for drawing
/// (the viewer), null when missing (one page per line).
pub fn loadDialogFont(io: Io, dat: Io.Dir) ?*const font.Font {
    const gpa = std.heap.page_allocator;
    var s = assetStack(io, gpa, dat) catch return null;
    defer s.deinit();
    const bytes = readFont(&s, gpa, modules.ui().assets.dialog_font, entity.texts.language) orelse return null;
    dialog_font = font.parse(bytes) catch {
        gpa.free(bytes);
        return null;
    };
    entity.dialog_font = widthsOf(dialog_font.?);
    return &dialog_font.?;
}

/// loadDialogFont's font; its glyphs point into the file's bytes (kept, never freed).
var dialog_font: ?font.Font = null;

const UiFonts = struct { small: ?*const font.Font, system: ?*const font.Font };

/// The interface fonts (`03_small`, `04_system` + the language's letters,
/// `common/other.dat`; the language of loadTexts) as the core's (entity.small_font, system_font), read at the first
/// call and kept; the parsed fonts for drawing (the viewer's panel and inventory).
pub fn loadUiFonts(io: Io, dat: Io.Dir) UiFonts {
    if (!ui_fonts_read) {
        ui_fonts_read = true;
        const gpa = std.heap.page_allocator;
        var s = assetStack(io, gpa, dat) catch return .{ .small = null, .system = null };
        defer s.deinit();
        const ua = modules.ui().assets;
        for ([_][]const u8{ ua.small_font, ua.system_font }, &ui_fonts) |name, *dst| {
            const bytes = readFont(&s, gpa, name, entity.texts.language) orelse continue;
            dst.* = font.parse(bytes) catch {
                gpa.free(bytes);
                continue;
            };
        }
        entity.small_font = if (ui_fonts[0]) |f| widthsOf(f) else null;
        entity.system_font = if (ui_fonts[1]) |f| widthsOf(f) else null;
    }
    return .{ .small = if (ui_fonts[0]) |*f| f else null, .system = if (ui_fonts[1]) |*f| f else null };
}

var ui_fonts: [2]?font.Font = .{ null, null };
var ui_fonts_read = false;

/// Bitmap font `fonts/<base>_1.fnt` with language `n`'s set `fonts/<base>_N<suffix>.fnt`
/// overlaid (0x45a1d0; `CZC1` bytes, owned by the caller). null if the base file is missing.
fn readFont(s: *assets.Stack, gpa: Allocator, base: []const u8, n: u8) ?[]u8 {
    var buf: [assets.max_path]u8 = undefined;
    const main = s.read(gpa, std.fmt.bufPrint(&buf, "fonts/{s}_1.fnt", .{base}) catch return null) catch return null;
    var sbuf: [64]u8 = undefined;
    const set = lang.setName(&sbuf, base, n) orelse return main;
    const extra = s.read(gpa, std.fmt.bufPrint(&buf, "fonts/{s}.fnt", .{set}) catch return main) catch return main;
    defer gpa.free(extra);
    const merged = font.merge(gpa, main, extra) catch return main;
    gpa.free(main);
    return merged;
}

fn widthsOf(f: font.Font) entity.Font {
    var out: entity.Font = .{};
    for (&out.widths, f.glyphs) |*w, g| w.* = if (g) |x| x.width else 0;
    return out;
}

test {
    _ = ogs;
    _ = classic;
    _ = rules_text;
    _ = codec;
    _ = map;
    _ = world;
    _ = assets;
    _ = level_assets;
}

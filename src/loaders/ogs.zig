//! The OG reader: an OpenGorky project (`opengorky.mod` with
//! `format = ogs`, its `src/*.ogs`) into the core. The texts' rows are the rules over empty
//! tables, every text is the worlds' one program (state/hooks.zig links it), the
//! archetypes are the core's records, a location is its `level`/`battle` block
//! (world/start.zig makes its objects), scenes and dialogs are their blocks; assets are
//! the project's `src/assets/` over the installed game's archives (loaders/assets.zig).
//! Sees only OG Script, the core and the assets (scripts/layercheck.sh): no Classic file.
//! loaders.openGame opens a project through it: the editor its `src/` (`open`), the viewer
//! and gorky-tool its package `dist/<id>.ogp` too (`openPackage`, compose/og/build.zig
//! writes it): one reader, the same model from both.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const script = @import("../script.zig");
const ir = script.ir;
const parser = script.ogs.parser;
const rules = @import("../rules.zig");
const core = @import("../core.zig");
const entity = core.entity;
const modules = core.modules;
const rules_text = @import("rules_text.zig");
const assets = @import("assets.zig");
const map = @import("map.zig");
const level_assets = @import("level_assets.zig");
const levels = script.ogs.levels;
const cp1251 = @import("../formats.zig").cp1251;
pub const manifest = @import("ogs/manifest.zig");
pub const package = @import("ogs/package.zig");

/// `path` is an OpenGorky project: a folder with a manifest and `src/` (its texts of OG
/// Script; its game elsewhere), or such a project's package (`dist/<id>.ogp`).
pub fn probe(io: std.Io, path: []const u8) bool {
    if (isPackage(path)) return if (std.Io.Dir.cwd().access(io, path, .{})) |_| true else |_| false;
    var d = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    defer d.close(io);
    _ = d.access(io, manifest.file_name, .{}) catch return false;
    _ = d.access(io, "src", .{}) catch return false;
    return true;
}

/// The text of `path`'s `opengorky.mod` (a project folder's or its package's), in `a`;
/// "": none (what a client says of a project it cannot open: its engine, its game).
pub fn manifestAt(io: std.Io, a: std.mem.Allocator, path: []const u8) []const u8 {
    if (isPackage(path)) {
        var pkg = package.Package.open(io, a, std.Io.Dir.cwd(), path) catch return "";
        defer pkg.close(io);
        return pkg.read(io, a, pkg.find(manifest.file_name, false) orelse return "") catch "";
    }
    var g = std.Io.Dir.cwd().openDir(io, path, .{}) catch return "";
    defer g.close(io);
    return g.readFileAlloc(io, manifest.file_name, a, .limited(1 << 16)) catch "";
}

/// `path` names a package (`.ogp`).
pub fn isPackage(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".ogp");
}

/// The installed game's folder from `$OPENGORKY_GAME` (set by the client at startup:
/// gorky-tool, the viewer, the editor; the viewer's settings' game folder without it);
/// null: the manifest's `game`.
pub var game_env: ?[]const u8 = null;

/// One text of `src/`: its path there (`/`-separated) and its bytes.
pub const Text = struct { path: []const u8, data: []const u8 };

/// The texts of package `pkg` (its `src/*.ogs` but `src/assets/`), by path in `src/`.
fn packageTexts(io: Io, a: Allocator, pkg: *const package.Package) ![]Text {
    var out: std.ArrayList(Text) = .empty;
    for (pkg.entries) |*e| if (std.mem.startsWith(u8, e.path, "src/") and std.mem.endsWith(u8, e.path, ".ogs") and !std.mem.startsWith(u8, e.path, "src/assets/"))
        try out.append(a, .{ .path = e.path["src/".len..], .data = try pkg.read(io, a, e) });
    return out.items;
}

/// The single-record tables every project gives one row of (the campaign, the shell's
/// windows, menu, music, sounds, animations): no Classic default stands in, so a project without one is refused, by its name.
const single_rows = [_][]const u8{ rules.Campaign.call, core.ui.Windows.call, core.ui.Menu.call, core.ui.Music.call, core.ui.Sounds.call, core.ui.Anims.call, core.ui.Holds.call };

/// The first of `single_rows` no text of `units` has a row of; null: all there.
pub fn missingRow(units: []const parser.Unit) ?[]const u8 {
    for (single_rows) |want| if (!hasRow(units, want)) return want;
    return null;
}

fn hasRow(units: []const parser.Unit, name: []const u8) bool {
    for (units) |u| for (u.modules) |m| for (m.rows) |r| if (r.kind == .call and std.ascii.eqlIgnoreCase(r.kind.call.text, name)) return true;
    // The campaign: the game block's `start` (loaders/rules_text.zig gameRows).
    // The campaign and the exe's music: the game block's `start`, `music` (loaders/rules_text.zig gameRows).
    const field: []const u8 = if (std.mem.eql(u8, name, rules.Campaign.call)) "start" else if (std.mem.eql(u8, name, core.ui.Music.call)) "music" else if (std.mem.eql(u8, name, core.ui.Anims.call)) "anims" else if (std.mem.eql(u8, name, core.ui.Holds.call)) "holds" else return false;
    for (units) |u| for (u.modules) |m| for (m.entities) |e| if (std.mem.eql(u8, e.kind, "game")) for (e.fields) |f| if (std.mem.eql(u8, f.name, field)) return true;
    return false;
}

/// What a project lacking single row `row` (`missingRow`) is told.
pub fn missingText(a: Allocator, row: []const u8) ![]const u8 {
    if (std.mem.eql(u8, row, rules.Campaign.call)) return "no game start: the game block needs start = ~l\"…\" (the level a new game opens)";
    if (std.mem.eql(u8, row, core.ui.Music.call)) return "no game music: the game block needs music = Music(level_up = \"…\", battle_enter = \"…\", …)";
    if (std.mem.eql(u8, row, core.ui.Anims.call)) return "no game anims: the game block needs anims = Anims(fight_look = \"…\", fight_look_two_handed = \"…\", hide_back = \"…\")";
    if (std.mem.eql(u8, row, core.ui.Holds.call)) return "no game holds: the game block needs holds = Holds(one_hand = \"…\", two_hands = \"…\", back = \"…\")";
    return std.fmt.allocPrint(a, "no {s}(…) row: a project needs one (no Classic default stands in)", .{row});
}

/// Every `.ogs` of `<project>/src` but `src/assets/`, sorted by path (the file system's
/// order differs between machines), in `a`.
pub fn readTexts(io: Io, a: Allocator, dir: Io.Dir) ![]Text {
    var src = try dir.openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    var out: std.ArrayList(Text) = .empty;
    var walker = try src.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |e| if (e.kind == .file and std.mem.endsWith(u8, e.path, ".ogs") and !std.mem.startsWith(u8, e.path, "assets" ++ std.fs.path.sep_str)) {
        const path = try a.dupe(u8, e.path);
        std.mem.replaceScalar(u8, path, '\\', '/');
        try out.append(a, .{ .path = path, .data = try src.readFileAlloc(io, e.path, a, .limited(64 << 20)) });
    };
    std.mem.sort(Text, out.items, {}, struct {
        fn lt(_: void, x: Text, y: Text) bool {
            return std.mem.order(u8, x.path, y.path) == .lt;
        }
    }.lt);
    return out.items;
}

/// The project open (process-wide, like the rules it set); `open` replaces it.
const Project = struct {
    io: Io,
    manifest: manifest.Manifest,
    /// `opengorky.mod`'s text (`manifest` points into it).
    manifest_text: []const u8,
    /// The installed game's `dat` (loaders.Game owns it) and the own assets (owned here):
    /// `src/assets/`, or the package read.
    dat: Io.Dir,
    own_dir: ?Io.Dir = null,
    /// `src/` (owned): `src/assets/` made after the open (the editor's first own asset
    /// saved) is opened from it when looked for (ownAssets).
    src_dir: ?Io.Dir = null,
    pkg: ?package.Package = null,
    /// The texts parsed (those that parse; rules_text warned of the others).
    units: []const parser.Unit,
};

var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var project: ?Project = null;

/// OpenGorky project folder `root` (its manifest says `format = ogs`) read: the rules
/// (`rules.og` on, its rows over empty tables, its texts the worlds' program), the texts
/// kept for its locations, scenes and dialogs. The installed game's `dat` (iterable, the
/// caller's): `$OPENGORKY_GAME`, else the manifest's `game` (relative: to the project).
/// error.MissingRow: a single-record table has no row (logged by name).
pub fn open(io: Io, root: Io.Dir) !Io.Dir {
    close();
    const a = arena_state.allocator();
    const mod = try root.readFileAlloc(io, manifest.file_name, a, .limited(1 << 16));
    const texts = try readTexts(io, a, root);
    return load(io, root, .{ .io = io, .manifest = manifest.parse(mod), .manifest_text = mod, .dat = undefined, .own_dir = root.openDir(io, "src/assets", .{ .iterate = true }) catch null, .src_dir = root.openDir(io, "src", .{}) catch null, .units = &.{} }, texts);
}

/// Package `path` (`<project>/dist/<id>.ogp`) read as `open` reads `src/`: its manifest,
/// texts and own assets; a relative `game` is the project's, `root` (the folder holding
/// `dist/`). shortcut: a package moved out of its project needs `$OPENGORKY_GAME`.
pub fn openPackage(io: Io, root: Io.Dir, path: []const u8) !Io.Dir {
    close();
    const a = arena_state.allocator();
    var pkg = try package.Package.open(io, a, Io.Dir.cwd(), path);
    const mod, const texts = blk: {
        errdefer pkg.close(io);
        const m = pkg.find(manifest.file_name, false) orelse return error.BadPackage;
        break :blk .{ try pkg.read(io, a, m), try packageTexts(io, a, &pkg) };
    };
    return load(io, root, .{ .io = io, .manifest = manifest.parse(mod), .manifest_text = mod, .dat = undefined, .pkg = pkg, .units = &.{} }, texts);
}

/// The open project's `opengorky.mod` text ("" none).
pub fn manifestText() []const u8 {
    return if (project) |p| p.manifest_text else "";
}

/// `path` if it is an installed game (a `dat` folder, no project's manifest): the viewer's
/// settings' game folder, where a package handed to a player finds its game; else null.
pub fn installedGame(io: Io, path: []const u8) ?[]const u8 {
    if (path.len == 0 or std.ascii.endsWithIgnoreCase(path, ".ogp")) return null;
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return null;
    defer d.close(io);
    d.access(io, manifest.file_name, .{}) catch {
        var dat = d.openDir(io, "dat", .{}) catch return null;
        dat.close(io);
        return path;
    };
    return null;
}

/// The installed game's folder of the open project (its videos, `avi/`, are read from there):
/// `$OPENGORKY_GAME` or the player's game folder (`game_env`), else the manifest's `game`,
/// relative to the project's folder `root_path` (a package's: the folder holding it);
/// null: no project open, or no game named.
pub fn gameFolder(buf: []u8, root_path: []const u8) ?[]const u8 {
    const p = project orelse return null;
    if (game_env) |g| return g;
    const g = p.manifest.game;
    if (g.len == 0) return null;
    if (std.fs.path.isAbsolute(g)) return g;
    const base = if (isPackage(root_path)) std.fs.path.dirname(root_path) orelse "." else root_path;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ base, g }) catch null;
}

/// The first `battle` block of the open project, its texts by path (a test room's battle
/// when it names none, compose/og/build.zig `testRoom`); null: none.
pub fn firstBattle() ?[]const u8 {
    const p = project orelse return null;
    for (p.units) |u| for (u.modules) |m| for (m.entities) |e| if (std.mem.eql(u8, e.kind, "battle")) return e.name;
    return null;
}

/// The installed game's `dat` of manifest `m` (`$OPENGORKY_GAME` over its `game`,
/// relative to `root`), iterable.
pub fn gameDat(io: Io, root: Io.Dir, m: manifest.Manifest) !Io.Dir {
    const game = game_env orelse m.game;
    if (game.len == 0) return error.NoGame;
    var game_dir = try root.openDir(io, game, .{});
    defer game_dir.close(io);
    return game_dir.openDir(io, "dat", .{ .iterate = true });
}

/// `p` (its own assets open) with `texts` read into the rules, the project open.
fn load(io: Io, root: Io.Dir, p: Project, texts: []const Text) !Io.Dir {
    var q = p;
    errdefer {
        if (q.own_dir) |*d| d.close(io);
        if (q.src_dir) |*d| d.close(io);
        if (q.pkg) |*k| k.close(io);
    }
    const a = arena_state.allocator();
    q.dat = try gameDat(io, root, p.manifest);
    errdefer q.dat.close(io);
    const rows = try a.alloc(rules_text.Text, texts.len);
    for (rows, texts) |*r, t| r.* = .{ .name = t.path, .data = t.data };
    rules.reset();
    rules.og = true;
    try rules_text.applyOg(rows);
    var units: std.ArrayList(parser.Unit) = .empty;
    for (texts) |t| {
        var diag: parser.Diagnostic = .{};
        try units.append(a, parser.parse(a, t.data, t.path, &diag) catch continue);
    }
    try mergeLevels(a, units.items);
    if (missingRow(units.items)) |row| {
        std.log.warn("rules: {s}", .{try missingText(a, row)});
        return error.MissingRow;
    }
    q.units = units.items;
    project = q;
    modules.starts = try scanStarts(a, texts);
    return q.dat;
}

/// The battles the project's locations start (core/modules.zig `starts`: a battle without
/// a post-processing chain of its own takes its location's): `level::Load(~l"b")` in a
/// location's texts, or `scene::Start(~e"s")` / `StartNext` of a scene that
/// `LOADLEVEL("b")`s; a battle started from a battle: that one's location. Texts in path
/// order, the first location wins (as compose's Classic scan did by level order).
/// shortcut: the texts scanned for the calls, not the linked code; walk the IR when calls
/// get built in other ways.
fn scanStarts(a: Allocator, texts: []const Text) ![]const modules.Start {
    // The scenes' battles: `.location` the scene's name.
    var scenes: std.ArrayList(modules.Start) = .empty;
    for (texts) |t| if (std.mem.startsWith(u8, t.path, "scenes/")) {
        const name = quotedAfter(t.data, "scene ", 0) orelse continue;
        for ([_][]const u8{ "LOADLEVEL(", "level::Load(" }) |call| {
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, t.data, at, call)) |k| : (at = k + 1) if (quotedAfter(t.data, call, k)) |lv| if (isBattle(lv)) try scenes.append(a, .{ .battle = lv, .location = name });
        }
    };
    var out: std.ArrayList(modules.Start) = .empty;
    for (texts) |t| {
        const dir = for ([_][]const u8{ "locations/", "battles/" }) |d| {
            if (std.mem.startsWith(u8, t.path, d)) break d;
        } else continue;
        const rest = t.path[dir.len..];
        const lvl = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse continue];
        for ([_][]const u8{ "level::Load(", "level::LoadAB(" }) |key| {
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, t.data, at, key)) |k| : (at = k + 1) if (quotedAfter(t.data, key, k)) |lv| if (isBattle(lv)) try addStart(a, &out, lv, lvl);
        }
        for ([_][]const u8{ "scene::Start(", "scene::StartNext(" }) |key| {
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, t.data, at, key)) |k| : (at = k + 1) if (quotedAfter(t.data, key, k)) |sc| for (scenes.items) |x| if (std.ascii.eqlIgnoreCase(x.location, sc)) try addStart(a, &out, x.battle, lvl);
        }
    }
    // A battle's battle (01__port_bulldozer2 from 01__port_bulldozer): its location.
    for (out.items) |*x| for (0..8) |_| {
        if (!isBattle(x.location)) break;
        x.location = for (out.items) |o| {
            if (std.ascii.eqlIgnoreCase(o.battle, x.location) and !isBattle(o.location)) break o.location;
        } else break;
    };
    return out.items;
}

fn addStart(a: Allocator, out: *std.ArrayList(modules.Start), battle: []const u8, location: []const u8) !void {
    for (out.items) |x| if (std.ascii.eqlIgnoreCase(x.battle, battle) and std.ascii.eqlIgnoreCase(x.location, location)) return;
    try out.append(a, .{ .battle = battle, .location = location });
}

/// The first "string" after `key` at `from` (on its line); null: none there.
fn quotedAfter(src: []const u8, key: []const u8, from: usize) ?[]const u8 {
    const k = std.mem.indexOfPos(u8, src, from, key) orelse return null;
    const eol = std.mem.indexOfScalarPos(u8, src, k, '\n') orelse src.len;
    const q = std.mem.indexOfScalarPos(u8, src[0..eol], k + key.len, '"') orelse return null;
    const e = std.mem.indexOfScalarPos(u8, src[0..eol], q + 1, '"') orelse return null;
    return src[q + 1 .. e];
}

/// The open project's texts as the editor has them now (its unsaved edits): its blocks,
/// scenes and dialogs as the worlds open them next (the rules: rules_text.reloadOg).
/// shortcut: the texts read before stay in the project's arena until the next `open`.
pub fn reparse(texts: []const rules_text.Text) Allocator.Error!void {
    const p = if (project) |*x| x else return;
    const a = arena_state.allocator();
    var units: std.ArrayList(parser.Unit) = .empty;
    for (texts) |t| {
        var diag: parser.Diagnostic = .{};
        try units.append(a, parser.parse(a, try a.dupe(u8, t.data), try a.dupe(u8, t.name), &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        });
    }
    try mergeLevels(a, units.items);
    p.units = units.items;
    const ts = try a.alloc(Text, texts.len);
    for (ts, texts) |*x, t| x.* = .{ .path = t.name, .data = t.data };
    modules.starts = try scanStarts(a, ts);
    // The numbers made for the blocks (and their texts) follow the edit (the editor's).
    loadCore();
}

/// A level's block in several texts of its folder made one (script/ogs/levels.zig); a
/// clash is said (that part stays out, as a text that does not link).
fn mergeLevels(a: Allocator, units: []parser.Unit) Allocator.Error!void {
    if (try levels.merge(a, units)) |x| std.log.warn("{s}:{d}: {s}", .{ x.file, x.line, x.message });
}

/// UTF-8 `s` as the fonts' bytes, in the project's edition's code page.
fn fontBytes(a: Allocator, s: []const u8) ![]const u8 {
    const n = if (project) |p| manifest.languageNumber(p.manifest.language) else 0;
    return cp1251.fromUtf8(a, s, cp1251.forLanguage(n));
}

/// The project closed (its own assets; the rules stay until the next open).
pub fn close() void {
    if (project) |*p| {
        if (p.own_dir) |*d| d.close(p.io);
        if (p.src_dir) |*d| d.close(p.io);
        if (p.pkg) |*k| k.close(p.io);
    }
    project = null;
    _ = arena_state.reset(.free_all);
}

/// The open project as text, to compare two reads of it (src/ and its package): each text
/// printed back by path, then the count of every rules table's rows.
pub fn modelText(a: Allocator) ![]u8 {
    const p = project orelse return error.NoProject;
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    const us = try a.dupe(parser.Unit, p.units);
    std.mem.sort(parser.Unit, us, {}, struct {
        fn lt(_: void, x: parser.Unit, y: parser.Unit) bool {
            return std.mem.order(u8, x.file, y.file) == .lt;
        }
    }.lt);
    for (us) |u| {
        try w.print("== {s}\n", .{u.file});
        try script.ogs.print.unit(w, u);
    }
    inline for (@typeInfo(rules.Set).@"struct".field_names) |f| try w.print("{s} {d}\n", .{ f, @field(rules.active.*, f).len });
    const t = core.modules.tables();
    inline for (@typeInfo(core.modules.Tables).@"struct".field_names) |f| try w.print("{s} {d}\n", .{ f, @field(t, f).len });
    return out.written();
}

/// Level `name` is a `battle` block of the open project (modules.battleNamed).
pub fn isBattle(name: []const u8) bool {
    return find(&.{"battle"}, name) != null;
}

/// A block of the program: its module and itself.
const Found = struct { m: *const ir.Module, e: *const ir.Entity };

/// The top-level block of one of `kinds` named `name` (case aside: the exe's level
/// names are), else null.
fn find(kinds: []const []const u8, name: []const u8) ?Found {
    const p = project orelse return null;
    for (p.units) |u| for (u.modules) |*m| for (m.entities) |*e| {
        for (kinds) |k| if (std.mem.eql(u8, e.kind, k) and std.ascii.eqlIgnoreCase(e.name, name)) return .{ .m = m, .e = e };
    };
    return null;
}

/// The archetypes (top-level blocks of `id_kinds`) as the core's records: each
/// by its path (`Who.class`) and its number (`idOf`); a fighter in the `game` party is a
/// hero, a block of no record's kind `other` (its number only).
/// No `string.tab`: the texts are the project's rows (`loadTexts`).
pub fn loadCore() void {
    fillEntities() catch |err| std.log.warn("entities: {t}", .{err});
    loadTexts() catch |err| std.log.warn("texts: {t}", .{err});
}

/// The project's texts as the core's (entity.texts): `UiText(id, text)` the classic_id and
/// interface texts (the edition's `string.tab` lines), `Examine(id, text)` the items' and
/// `AreaExamine(id, text)` the areas' examine texts, each in the fonts' cp1251 (the
/// project's one UTF-8 language); the language the manifest's. A row without an
/// `id` or `text` is warned about and skipped. Then the texts on the entities: a block's `name` is the text of its classic_id (its own or its
/// archetype's), its `examine` the examine text (an area's: `AreaExamine`'s), over a row of
/// that number; blocks inside blocks too.
fn loadTexts() !void {
    const p = project orelse return;
    const a = arena_state.allocator();
    var t: @TypeOf(entity.texts) = .{ .language = manifest.languageNumber(p.manifest.language) };
    for (p.units) |u| for (u.modules) |m| for (m.rows) |r| {
        if (r.kind != .call) continue;
        const c = r.kind.call;
        const into = if (std.mem.eql(u8, c.text, rules_text.text_rows[0])) &t.map else if (std.mem.eql(u8, c.text, rules_text.text_rows[1])) &t.examine else if (std.mem.eql(u8, c.text, rules_text.text_rows[2])) &t.areas else continue;
        // `id`: a number, or the block whose number it is (`"01_port_silos/01ps_trup1"`, a
        // level's own object; `"items::x"`).
        const id: ?i32 = if (named(c, "id")) |v| (if (number(v)) |n| @as(i32, @intFromFloat(n)) else if (text(v)) |path| textId(path) else null) else if (named(c, "key")) |v| keyId(v) else null;
        const s = if (named(c, "text")) |v| text(v) else null;
        if (id == null or s == null) {
            std.log.warn("{s}:{d}: {s} needs id and text", .{ u.file, r.line, c.text });
            continue;
        }
        try into.put(a, id.?, try fontBytes(a, s.?));
    };
    for (p.units) |u| for (u.modules) |*m| for (m.entities) |*e| try entityTexts(a, &t, m, e, null, 0);
    entity.useTexts(t);
}

/// The core's number of an interface text's key (`UiText(key = miss, …)`, core/ui_text.zig).
fn keyId(v: *const ir.Expr) ?i32 {
    const name = if (v.kind == .word) v.kind.word else text(v) orelse return null;
    return core.ui_text.id(core.ui_text.named(name) orelse return null);
}

/// The number of the block a text row's `id` names by path.
fn textId(path: []const u8) ?i32 {
    if (std.mem.indexOf(u8, path, "::") != null) return idIn(byPath(path, "", null) orelse return null, null, 0);
    const t = byLevelKey(path) orelse return null;
    return idIn(t.b, t.level, 0);
}

/// Block `e`'s (module `m`'s; `level`: the level's it stands in) `name` and `examine` into
/// `t` by its number (`idIn`); its inner blocks' too.
fn entityTexts(a: Allocator, t: *@TypeOf(entity.texts), m: *const ir.Module, e: *const ir.Entity, level: ?[]const u8, depth: u32) !void {
    if (depth > 16) return;
    const inner: ?[]const u8 = if (isLevelKind(e.kind)) e.name else level;
    for (e.children) |*c| try entityTexts(a, t, m, c, inner, depth + 1);
    for (e.fields) |f| {
        const into = if (std.mem.eql(u8, f.name, "name")) &t.map else if (std.mem.eql(u8, f.name, "examine")) (if (std.mem.eql(u8, e.kind, "area")) &t.areas else &t.examine) else continue;
        const s = text(f.value) orelse continue;
        const id = idIn(.{ .m = m, .e = e }, level, 0) orelse continue;
        try into.put(a, id, try fontBytes(a, s));
    }
}

fn isLevelKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "level") or std.mem.eql(u8, kind, "battle");
}

/// A level's own object's key (`01_port/grandhand`): its number's and the core's identity.
fn levelKey(buf: []u8, level: []const u8, name: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ level, name }) catch null;
}

fn fillEntities() !void {
    const p = project orelse return;
    var tmp: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer tmp.deinit();
    const a = tmp.allocator();
    const party = partyPaths(a);
    try makeAutoIds(a);
    var list: std.ArrayList(entity.Listed) = .empty;
    for (p.units) |u| for (u.modules) |*m| for (m.entities) |*e| {
        if (!idKind(e.kind)) continue;
        const kind: entity.Kind = if (std.mem.eql(u8, e.kind, "weapon")) .weapon else if (std.mem.eql(u8, e.kind, "item")) .item else if (std.mem.eql(u8, e.kind, "fighter")) .enemy else .other;
        const path = try blockPath(a, m, e);
        const id = idOf(.{ .m = m, .e = e }, 0) orelse continue;
        // The party's: a fighter or hero block (`hero sullivan`).
        const hero = (kind == .enemy or std.mem.eql(u8, e.kind, "hero")) and for (party) |x| {
            if (std.mem.eql(u8, x, path)) break true;
        } else false;
        try list.append(a, .{ .kind = if (hero) .hero else kind, .who = .{ .id = id, .class = path } });
    };
    // The `same_as` blocks → their main one (rules.mains: a row by one names them all).
    rules.mains = .empty;
    _ = mains_arena.reset(.retain_capacity);
    const ma = mains_arena.allocator();
    for (p.units) |u| for (u.modules) |*m| for (m.entities) |*e| if (fieldValue(e, "same_as")) |v| if (v.kind == .word) {
        try rules.mains.put(ma, try ma.dupe(u8, try blockPath(a, m, e)), try ma.dupe(u8, script.ir.Import.of(v.kind.word).path));
    };
    // The levels' own objects of no archetype by `<level>/<name>` (world/start.zig's identity).
    for (p.units) |u| for (u.modules) |*m| for (m.entities) |*lv| if (isLevelKind(lv.kind)) for (lv.children) |*c| {
        if (c.base.len > 0 or !idKind(c.kind)) continue;
        var kb: [256]u8 = undefined;
        const key = levelKey(&kb, lv.name, c.name) orelse continue;
        // `import "03_museum/card";` (another level's object) or `import weapons::shotgun;` (an
        // archetype: the scene's shotgun is the weapon's own, its rows, HeroAttack and fx, too).
        if (fieldValue(c, "same_as")) |v| {
            const main: ?[]const u8 = if (v.kind == .lit and v.kind.lit == .string) v.kind.lit.string else if (v.kind == .word) script.ir.Import.of(v.kind.word).path else null;
            if (main) |x| try rules.mains.put(ma, try ma.dupe(u8, key), try ma.dupe(u8, x));
        }
        const id = idIn(.{ .m = m, .e = c }, lv.name, 0) orelse continue;
        try list.append(a, .{ .kind = .other, .who = .{ .id = id, .class = try a.dupe(u8, key) } });
    };
    try entity.fill(list.items);
    // The heroes' order in the party (game.zig keepSelectable): the game block's list.
    for (p.units) |u| for (u.modules) |m| for (m.entities) |e| if (std.mem.eql(u8, e.kind, "game")) if (fieldValue(&e, "party_order")) |v| if (v.kind == .list) {
        var order: std.ArrayList([]const u8) = .empty;
        for (v.kind.list) |x| if (x.kind == .word) try order.append(a, x.kind.word);
        try entity.setPartyOrder(order.items);
    };
}

/// Kinds of block with an identity (a number for the core: its texts, its rules rows).
const id_kinds = [_][]const u8{ "fighter", "hero", "weapon", "item", "actor", "obstacle", "area", "anim", "active_anim" };

fn idKind(kind: []const u8) bool {
    for (id_kinds) |k| if (std.mem.eql(u8, kind, k)) return true;
    return false;
}

fn blockPath(a: Allocator, m: *const ir.Module, e: *const ir.Entity) ![]const u8 {
    return if (m.path.len > 0) std.fmt.allocPrint(a, "{s}::{s}", .{ m.path, e.name }) else a.dupe(u8, e.name);
}

/// The numbers made for the top-level blocks with no number of their own, no `same_as`
/// and no archetype (`makeAutoIds`), by path.
var auto_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var mains_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var auto_ids: std.StringHashMapUnmanaged(i32) = .empty;

/// The first number made for a block (past the Classic games' own, which stay below).
const auto_base: i32 = 1_000_000;

/// `auto_ids`: each such block's number from its path (FNV-1a, lower case), the next free
/// one on a clash, the blocks in path order: the same project gives the same numbers, a
/// block added or removed moves no other's (a save keeps them).
fn makeAutoIds(a: Allocator) !void {
    const p = project orelse return;
    _ = auto_arena.reset(.retain_capacity);
    auto_ids = .empty;
    const aa = auto_arena.allocator();
    var taken: std.AutoHashMapUnmanaged(i32, void) = .empty;
    var want: std.ArrayList([]const u8) = .empty;
    for (p.units) |u| for (u.modules) |*m| for (m.entities) |*e| {
        if (fieldValue(e, "classic_id")) |v| if (number(v)) |n| try taken.put(a, @intFromFloat(n), {});
        // A level's own objects keep their numbers out of the made ones' way.
        for (e.children) |*c| if (fieldValue(c, "classic_id")) |v| if (number(v)) |n| try taken.put(a, @intFromFloat(n), {});
        if (isLevelKind(e.kind)) for (e.children) |*c| {
            if (!idKind(c.kind) or c.base.len > 0 or fieldValue(c, "classic_id") != null or fieldValue(c, "same_as") != null) continue;
            // Named (its hint, its examine text) or no number at all (Classic's 0: an anim, a door).
            if (!named_(c)) continue;
            var kb: [256]u8 = undefined;
            try want.append(a, try a.dupe(u8, levelKey(&kb, e.name, c.name) orelse continue));
        };
        if (!idKind(e.kind) or e.base.len > 0 or fieldValue(e, "classic_id") != null or fieldValue(e, "same_as") != null) continue;
        try want.append(a, try blockPath(a, m, e));
    };
    std.mem.sort([]const u8, want.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(x, y);
        }
    }.lt);
    for (want.items) |path| {
        var h: u32 = 2166136261;
        for (path) |ch| h = (h ^ std.ascii.toLower(ch)) *% 16777619;
        var n: i32 = auto_base + @as(i32, @intCast(h % 900_000_000));
        while (taken.contains(n)) n = if (n == std.math.maxInt(i32)) auto_base else n + 1;
        try taken.put(a, n, {});
        try auto_ids.put(aa, try aa.dupe(u8, path), n);
    }
}

/// A level's own object that has a text of its own: one with an identity (a number made for it).
fn named_(e: *const ir.Entity) bool {
    return fieldValue(e, "name") != null or fieldValue(e, "examine") != null;
}

fn fieldValue(e: *const ir.Entity, name: []const u8) ?*const ir.Expr {
    for (e.fields) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
    return null;
}

/// Block `b`'s number for the core: its `classic_id`, else its `same_as` block's, else its
/// archetype's, else the one made for its path (`auto_ids`); null: none (not a top-level
/// block of `id_kinds`, the project not loaded).
pub fn idOf(b: Found, depth: u32) ?i32 {
    return idIn(b, null, depth);
}

/// `idOf` of a block standing in level `level` (a level's own object: its key `level/name`).
fn idIn(b: Found, level: ?[]const u8, depth: u32) ?i32 {
    if (depth > 16) return null;
    if (fieldValue(b.e, "classic_id")) |v| if (number(v)) |n| return @intFromFloat(n);
    if (fieldValue(b.e, "same_as")) |v| {
        if (v.kind == .word) {
            const t = script.ir.Import.of(v.kind.word);
            return idIn(byPath(t.path, t.kind, b.e) orelse return null, null, depth + 1);
        }
        if (v.kind == .lit and v.kind.lit == .string) {
            const t = byLevelKey(v.kind.lit.string) orelse return null;
            return idIn(t.b, t.level, depth + 1);
        }
    }
    if (b.e.base.len > 0) return idIn(archetype(b, b.e.base) orelse return null, null, depth + 1);
    var buf: [256]u8 = undefined;
    const path = if (level) |l| levelKey(&buf, l, b.e.name) orelse return null else if (b.m.path.len > 0) std.fmt.bufPrint(&buf, "{s}::{s}", .{ b.m.path, b.e.name }) catch return null else b.e.name;
    return auto_ids.get(path);
}

/// The top-level block at `path` (`characters::c_nato`) of `kind` ("": any), not `not`
/// (the block importing it, at its path too: `hero medusa` and `fighter medusa`).
fn byPath(path: []const u8, kind: []const u8, not: ?*const ir.Entity) ?Found {
    const p = project orelse return null;
    const k = std.mem.lastIndexOf(u8, path, "::") orelse return null;
    for (p.units) |u| for (u.modules) |*m| if (std.mem.eql(u8, m.path, path[0..k])) for (m.entities) |*e| {
        if (not != null and e == not.?) continue;
        if (kind.len > 0 and !std.mem.eql(u8, e.kind, kind)) continue;
        if (std.mem.eql(u8, e.name, path[k + 2 ..])) return .{ .m = m, .e = e };
    };
    return null;
}

/// The level's own object at `key` (`03_museum_forgotten/03mf_cardyellow`) and its level.
fn byLevelKey(key: []const u8) ?struct { b: Found, level: []const u8 } {
    const p = project orelse return null;
    const k = std.mem.indexOfScalar(u8, key, '/') orelse return null;
    for (p.units) |u| for (u.modules) |*m| for (m.entities) |*lv| if (isLevelKind(lv.kind) and std.mem.eql(u8, lv.name, key[0..k])) for (lv.children) |*c| {
        if (std.mem.eql(u8, c.name, key[k + 1 ..])) return .{ .b = .{ .m = m, .e = c }, .level = lv.name };
    };
    return null;
}

/// The `game` block's `party` paths (`[characters::sullivan, …]`), in `a`.
fn partyPaths(a: Allocator) []const []const u8 {
    const p = project orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (p.units) |u| for (u.modules) |m| for (m.entities) |e| if (std.mem.eql(u8, e.kind, "game")) for (e.fields) |f| {
        if (!std.mem.eql(u8, f.name, "party") or f.value.kind != .list) continue;
        for (f.value.kind.list) |x| if (x.kind == .word) out.append(a, x.kind.word) catch {};
    };
    return out.items;
}

/// The `b.e.kind` block `path` names from `b`'s module: in its namespace, else from the root
/// (a fighter's may be a hero: `fighter x: characters::sullivan`).
fn archetype(b: Found, path: []const u8) ?Found {
    const kind = b.e.kind;
    if (std.mem.eql(u8, kind, "fighter")) return archetypeOf(b, path, "fighter") orelse archetypeOf(b, path, "hero");
    return archetypeOf(b, path, kind);
}

fn archetypeOf(b: Found, path: []const u8, kind: []const u8) ?Found {
    const p = project orelse return null;
    var buf: [256]u8 = undefined;
    const own = if (b.m.path.len > 0) std.fmt.bufPrint(&buf, "{s}::{s}", .{ b.m.path, path }) catch return null else path;
    for ([_][]const u8{ own, path }) |want| for (p.units) |u| for (u.modules) |*m| for (m.entities) |*e| {
        if (!std.mem.eql(u8, e.kind, kind)) continue;
        const ns = std.mem.lastIndexOf(u8, want, "::");
        const in_ns = if (ns) |k| want[0..k] else "";
        const name = if (ns) |k| want[k + 2 ..] else want;
        if (std.mem.eql(u8, m.path, in_ns) and std.mem.eql(u8, e.name, name)) return .{ .m = m, .e = e };
    };
    return null;
}

/// A number literal (`-1` too).
fn number(e: *const ir.Expr) ?f32 {
    return switch (e.kind) {
        .lit => |v| switch (v) {
            .int => |i| @floatFromInt(i),
            .float => |x| x,
            else => null,
        },
        .unary => |u| if (u.op == .neg) if (number(u.operand)) |n| -n else null else null,
        else => null,
    };
}

/// A string literal, or the name an `@obj` reference, a word or a path ends in.
fn text(e: *const ir.Expr) ?[]const u8 {
    return switch (e.kind) {
        .lit => |v| if (v == .string) v.string else null,
        .ref => |r| r,
        .word => |w| if (std.mem.lastIndexOf(u8, w, "::")) |k| w[k + 2 ..] else w,
        else => null,
    };
}

fn named(c: ir.Call, name: []const u8) ?*const ir.Expr {
    for (c.named) |n| if (std.mem.eql(u8, n.name, name)) return n.value;
    return null;
}

// ---------------------------------------------------------------- a location

/// The reader as the game's world factory (loaders/world.zig `reader`).
pub fn factory() core.source.Factory {
    return .{ .open = openLevel };
}

/// What a location's source holds until the world's destroy.
const Level = struct {
    gpa: Allocator,
    /// The block's name (its assets' `levels/<name>/…`) and key (`battle 01__port_citadel`).
    name: []const u8,
    key: []const u8,
    assets: assets.Stack,
};

fn openLevel(_: ?*anyopaque, gpa: Allocator, name: []const u8) anyerror!core.source.Source {
    const p = project orelse return error.NoProject;
    const b = find(&.{ "level", "battle" }, name) orelse return error.NoSuchLevel;
    const l = try gpa.create(Level);
    errdefer gpa.destroy(l);
    const key = if (b.m.path.len > 0) try std.fmt.allocPrint(gpa, "{s} {s}::{s}", .{ b.e.kind, b.m.path, b.e.name }) else try std.fmt.allocPrint(gpa, "{s} {s}", .{ b.e.kind, b.e.name });
    errdefer gpa.free(key);
    l.* = .{ .gpa = gpa, .name = b.e.name, .key = key, .assets = try .og(p.io, gpa, ownAssets(), p.dat) };
    return .{
        .ctx = l,
        .level_block = key,
        .frame_count = frameCount,
        .background_size = backgroundSize,
        .map = mapOf,
        .has_voice = hasVoice,
        .backdrop = backdropOf,
        .scenes = .{ .scene = sceneOf, .dialog = dialogOf },
        .close = closeLevel,
    };
}

/// The open project's own assets (its folder or its package).
fn ownAssets() ?assets.Stack.Own {
    const p = if (project) |*x| x else return null;
    if (p.pkg) |*k| return .{ .package = k };
    if (p.own_dir == null) if (p.src_dir) |sd| {
        p.own_dir = sd.openDir(p.io, "assets", .{ .iterate = true }) catch null;
    };
    if (p.own_dir) |d| return .{ .folder = d };
    return null;
}

fn levelOf(ctx: ?*anyopaque) *Level {
    return @ptrCast(@alignCast(ctx.?));
}

fn closeLevel(ctx: ?*anyopaque) void {
    const l = levelOf(ctx);
    l.assets.deinit();
    l.gpa.free(l.key);
    l.gpa.destroy(l);
}

fn frameCount(ctx: ?*anyopaque, name: []const u8) u32 {
    const l = levelOf(ctx);
    return level_assets.frameCount(&l.assets, l.name, name);
}

fn backgroundSize(ctx: ?*anyopaque) ?[2]u32 {
    const l = levelOf(ctx);
    return level_assets.backgroundSize(&l.assets, l.gpa, l.name);
}

fn mapOf(ctx: ?*anyopaque, a: Allocator) anyerror!core.map.Map {
    const l = levelOf(ctx);
    var m = try map.load(&l.assets, a, l.name);
    // Its walk paths are its `path` blocks (paths.ogs), never the game's `.ap`.
    if (project != null) m.paths = try pathsOf(a, l.name);
    return m;
}

/// Level `level`'s walk paths: its `path` blocks (`path deska { link = [182, 22, 189, 11];
/// points = [PathPoint(x = 1460, y = 180, angle = 0.0, z = 135), …]; }`), in `a`.
fn pathsOf(a: Allocator, level: []const u8) ![]core.map.Path {
    const p = project orelse return &.{};
    return pathsIn(a, p.units, level);
}

/// `pathsOf` of texts `units` (the editor's: a level's `paths.ogs`).
pub fn pathsIn(a: Allocator, units: []const parser.Unit, level: []const u8) ![]core.map.Path {
    var out: std.ArrayList(core.map.Path) = .empty;
    for (units) |u| for (u.modules) |m| for (m.entities) |*lv| if (isLevelKind(lv.kind) and std.mem.eql(u8, lv.name, level)) for (lv.children) |*c| {
        if (!std.mem.eql(u8, c.kind, "path")) continue;
        var link: [4]f32 = @splat(0);
        if (fieldValue(c, "link")) |v| if (v.kind == .list) for (v.kind.list[0..@min(4, v.kind.list.len)], 0..) |x, k| {
            link[k] = number(x) orelse 0;
        };
        var pts: std.ArrayList([4]f32) = .empty;
        if (fieldValue(c, "points")) |v| if (v.kind == .list) for (v.kind.list) |x| if (x.kind == .call) {
            var pt: [4]f32 = @splat(0);
            for ([_][]const u8{ "x", "y", "angle", "z" }, 0..) |n, k| if (named(x.kind.call, n)) |e| {
                pt[k] = number(e) orelse 0;
            };
            try pts.append(a, pt);
        };
        try out.append(a, .{ .name = c.name, .link = link, .points = pts.items });
    };
    return out.items;
}

fn backdropOf(ctx: ?*anyopaque, a: Allocator) anyerror!core.map.Backdrop {
    const l = levelOf(ctx);
    return level_assets.backdrop(&l.assets, a, l.name);
}

fn hasVoice(ctx: ?*anyopaque, name: []const u8) bool {
    return level_assets.hasVoice(&levelOf(ctx).assets, name);
}

// ---------------------------------------------------------------- scenes and dialogs

/// Block `scene "<name>"`: its commands (`actor::WalkTo(@Sullivan, "p1");` as the exe's
/// WALKTO, `sceneCommand`) and its `points` (`[Point(name, x, y, angle), …]`).
fn sceneOf(_: ?*anyopaque, a: Allocator, name: []const u8) anyerror!core.scene.Scene {
    return sceneFrom(a, (find(&.{"scene"}, name) orelse return error.NotFound).e);
}

fn sceneFrom(a: Allocator, e: *const ir.Entity) !core.scene.Scene {
    var cmds: std.ArrayList(core.scene.Command) = .empty;
    for (e.rows) |r| {
        if (r.kind != .call) continue;
        try cmds.append(a, try sceneCommand(a, r.kind.call, r.line));
    }
    var pts: std.ArrayList(core.scene.Point) = .empty;
    for (e.fields) |f| if (std.mem.eql(u8, f.name, "points") and f.value.kind == .list) for (f.value.kind.list) |x| {
        if (x.kind != .call) continue;
        const c = x.kind.call;
        const num = struct {
            fn of(cl: ir.Call, n: []const u8) f32 {
                return if (named(cl, n)) |v| number(v) orelse 0 else 0;
            }
        }.of;
        try pts.append(a, .{ .name = if (named(c, "name")) |v| text(v) orelse "" else "", .x = num(c, "x"), .y = num(c, "y"), .angle = num(c, "angle") });
    };
    var off = false;
    for (e.fields) |f| if (std.mem.eql(u8, f.name, "enabled") and f.value.kind == .lit and f.value.kind.lit == .bool) {
        off = !f.value.kind.lit.bool;
    };
    return .{ .commands = cmds.items, .points = pts.items, .off = off };
}

/// Scene command `c` as the exe's (core/scene.zig `commands`): `actor::WalkTo` its WALKTO,
/// a pair's by its last argument (`camera::Panorama(true)`: PANORAMA_ON), each argument by
/// its kind (`@Sullivan` "Sullivan", `@hero::selected` "#HERO_SELECTED", seconds ticks,
/// `true` 1, `~d"x"` "x.dlg", a dropped one ""); named arguments after the rest in order.
/// An exe name (`WALKTO(…)`) or an unknown one: its arguments as written.
fn sceneCommand(a: Allocator, c: ir.Call, line: u32) !core.scene.Command {
    var xs: std.ArrayList(*const ir.Expr) = .empty;
    try xs.appendSlice(a, c.args);
    for (c.named) |n| try xs.append(a, n.value);
    var cmd: ?*const core.scene.Cmd = null;
    if (std.mem.indexOf(u8, c.text, "::") != null) if (core.scene.ofOgs(c.text, null)) |p| {
        cmd = p;
        if (p.flag != null) if (xs.pop()) |last| {
            cmd = core.scene.ofOgs(c.text, if (last.kind == .lit and last.kind.lit == .bool) last.kind.lit.bool else null) orelse p;
        };
    };
    const kinds = if (cmd) |p| p.args else "";
    var args: std.ArrayList(core.scene.Arg) = .empty;
    var k: usize = 0;
    for (xs.items) |x| {
        while (k < kinds.len and kinds[k] == '_') : (k += 1) try args.append(a, .{ .string = "" });
        const kind: ?core.scene.Kind = if (k < kinds.len) .of(kinds[k]) else null;
        k += 1;
        if (x.kind == .lit and x.kind.lit == .bool) {
            const on = x.kind.lit.bool;
            if (kind == .given) {
                if (on) try args.append(a, .{ .number = 1 });
                continue;
            }
            try args.append(a, .{ .number = if (on != (kind == .not)) 1 else 0 });
            continue;
        }
        if (number(x)) |n| {
            const sc = if (kind) |kd| kd.scale() else null;
            const v = if (sc) |m| @as(f64, n) * m else n;
            // Ticks are whole (`scene::Wait(0.33)`: 10); 1.3 s is 130, not 130.00001.
            const whole = kind == .ticks or (sc != null and @abs(v - @round(v)) < 1e-3);
            try args.append(a, .{ .number = @floatCast(if (whole) @round(v) else v) });
            continue;
        }
        if (x.kind == .ref) {
            try args.append(a, .{ .string = try fontBytes(a, core.scene.exeActor(x.kind.ref)) });
            continue;
        }
        const t = text(x) orelse "";
        if (kind == .dialog and !std.ascii.endsWithIgnoreCase(t, ".dlg")) {
            try args.append(a, .{ .string = try std.fmt.allocPrint(a, "{s}.dlg", .{try fontBytes(a, t)}) });
            continue;
        }
        try args.append(a, .{ .string = try fontBytes(a, t) });
    }
    return .{ .name = if (cmd) |p| p.exe else c.text, .args = args.items, .line = line };
}

test "sceneCommand: OG Script's arguments as the exe's" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\scene s {
        \\    camera::Panorama(false);
        \\    scene::Wait(0.33);
        \\    actor::Animation(@hero::selected, "use", 2, true);
        \\    dialog::Open(~d"port");
        \\    object::Enable(@gate, true);
        \\    actor::Weapon(@Ovitz, "riffle", true);
        \\    actor::Weapon(@Ovitz, "riffle", false);
        \\    camera::Move("cam_1", 1.3, 1.5);
        \\    DELAY(7);
        \\}
    ;
    var diag: @import("../script/ogs/parser.zig").Diagnostic = .{};
    const u = try @import("../script/ogs/parser.zig").parse(a, src, "t.ogs", &diag);
    const sc = try sceneFrom(a, &u.modules[0].entities[0]);
    const want = [_]struct { []const u8, []const core.scene.Arg }{
        .{ "PANORAMA_OFF", &.{} },
        .{ "DELAY", &.{.{ .number = 10 }} },
        .{ "ANIMATION", &.{ .{ .string = "#HERO_SELECTED" }, .{ .string = "use" }, .{ .number = 2 }, .{ .number = 1 } } },
        .{ "DIALOG_INIT", &.{ .{ .string = "" }, .{ .string = "port.dlg" } } },
        .{ "DISABLEOBJECT", &.{ .{ .string = "gate" }, .{ .number = 0 } } },
        .{ "WEAPON", &.{ .{ .string = "Ovitz" }, .{ .string = "riffle" }, .{ .number = 1 } } },
        .{ "WEAPON", &.{ .{ .string = "Ovitz" }, .{ .string = "riffle" } } },
        .{ "DOLLY", &.{ .{ .string = "cam_1" }, .{ .number = 130 }, .{ .number = 150 } } },
        .{ "DELAY", &.{.{ .number = 7 }} },
    };
    try std.testing.expectEqual(want.len, sc.commands.len);
    for (want, sc.commands) |w, got| {
        try std.testing.expectEqualStrings(w[0], got.name);
        try std.testing.expectEqualDeep(w[1], @as([]const core.scene.Arg, got.args));
    }
}

/// Block `dialog "<file>"` (the name without `.dlg`): its `Line(who, text, voice, cam)`
/// rows; the speaker is the name `who` ends in (`speakers::HQ`: `HQ`), the voice its
/// `voice.dat` entry (`voice/x.wav`: `x.wav`), its text in the fonts' bytes. The project's
/// one language: `language` aside.
fn dialogOf(_: ?*anyopaque, a: Allocator, file: []const u8, language: u8) anyerror!core.scene.Dialog {
    _ = language;
    const name = if (std.ascii.endsWithIgnoreCase(file, ".dlg")) file[0 .. file.len - 4] else file;
    return dialogFrom(a, (find(&.{"dialog"}, name) orelse return error.NotFound).e);
}

fn dialogFrom(a: Allocator, e: *const ir.Entity) !core.scene.Dialog {
    var lines: std.ArrayList(core.scene.Line) = .empty;
    for (e.rows) |r| {
        if (r.kind != .call or !std.mem.eql(u8, r.kind.call.text, "Line")) continue;
        const c = r.kind.call;
        const voice: ?[]const u8 = if (named(c, "voice")) |v| if (text(v)) |s| (if (std.mem.startsWith(u8, s, "voice/")) s["voice/".len..] else s) else null else null;
        var cam: ?[2]i32 = null;
        if (named(c, "cam")) |v| if (v.kind == .list and v.kind.list.len == 2) {
            cam = .{ @intFromFloat(number(v.kind.list[0]) orelse 0), @intFromFloat(number(v.kind.list[1]) orelse 0) };
        };
        try lines.append(a, .{
            .speaker = if (named(c, "who")) |v| text(v) orelse "" else "",
            // The font's bytes (the project's UTF-8 back to the edition's code page).
            .text = try fontBytes(a, if (named(c, "text")) |v| text(v) orelse "" else ""),
            .cam = cam,
            .voice = voice,
        });
    }
    return .{ .lines = lines.items };
}

test "OG reader: a scene's commands and points, a dialog's lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: parser.Diagnostic = .{};
    const u = try parser.parse(a,
        \\scene "s" { points = [Point(name = "p1", x = 512, y = -3, angle = 1.5)]; WALKTO(@Sullivan, "p1"); CALL(@"01pr_garcia1", "Arrived"); WAIT(10); }
        \\dialog "d" { Line(who = speakers::HQ, text = "Over.", voice = ~s"voice/d_hq01.wav", cam = [3, 4]); Line(who = speakers::Sullivan, text = "Hi"); }
    , "t.ogs", &diag);
    const s = try sceneFrom(a, &u.modules[0].entities[0]);
    try std.testing.expectEqual(3, s.commands.len);
    try std.testing.expectEqualStrings("WALKTO", s.commands[0].name);
    try std.testing.expectEqualStrings("Sullivan", s.commands[0].args[0].string);
    try std.testing.expectEqualStrings("01pr_garcia1", s.commands[1].args[0].string);
    try std.testing.expectEqual(10, s.commands[2].args[0].number);
    try std.testing.expectEqualStrings("p1", s.points[0].name);
    try std.testing.expectEqual(-3, s.points[0].y);
    const d = try dialogFrom(a, &u.modules[0].entities[1]);
    try std.testing.expectEqual(2, d.lines.len);
    try std.testing.expectEqualStrings("HQ", d.lines[0].speaker);
    try std.testing.expectEqualStrings("d_hq01.wav", d.lines[0].voice.?);
    try std.testing.expectEqual([2]i32{ 3, 4 }, d.lines[0].cam.?);
    try std.testing.expect(d.lines[1].voice == null);
}

test {
    _ = manifest;
    _ = package;
}

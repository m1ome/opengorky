//! The OG build: an OpenGorky project's `src/` checked before
//! any play, then packed as `dist/<id>.ogp` (loaders/ogs/package.zig), what the viewer plays
//! (loaders/ogs.zig openPackage). `gorky-tool build`, `gorky-tool play --start …` and the
//! editor's «Play» run it. The checks, each a problem at `file:line`:
//!   1. every text parses;
//!   2. the whole program links (functions, components, `use`, named arguments) and
//!   3. its data blocks match the schema (core/schema.zig: no such field, not that type);
//!   4. references resolve: archetypes, `@obj` and sigil names (`~l"…"`, `~d"…"`: a block of
//!      the program), a `CALL`'s method;
//!   5. assets resolve in `src/assets/` or the installed game (`~a"…"`, a sound's path, each
//!      level's and battle's background, each look's model and the animations it names);
//!   6. events match the engine's (script/traits.zig: names, parameters) — 2–6 are the
//!      link's (script/ogs/link.zig), the hosts' answers given here;
//!   7. scenes: each command is the engine's, its arguments of their kinds; what it names
//!      (an actor, a point, a dialog's line, an animation) a warning (scenecheck.zig);
//!   and every single-record rules row is there (loaders/ogs.zig `missingRow`), the start
//!   (Play) is a level or battle block. Warnings (a method named close to an event) don't
//!   stop it; an error writes no package.
//! Incremental: `dist/.cache/<package>.txt` keeps each packed file's hash, size and time
//! under a key of the engine's data version and the schema's hash (a newer engine or schema
//! drops it): an asset whose size and time are the cached ones is not read again (its bytes
//! come from the old package), and the report counts the entries whose content changed.
//! shortcut: every text is parsed and linked again each build (fast at a project's size);
//! cache the IR when it is not ("only as a cache").
//! Sees only OG Script, the core and the assets (scripts/layercheck.sh).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const script = @import("../../script.zig");
const ir = script.ir;
const parser = script.ogs.parser;
const link = script.ogs.link;
const core = @import("../../core.zig");
const builtins = @import("../../builtins.zig");
const assets = @import("../../loaders.zig").assets;
const reader = @import("../../loaders.zig").ogs;
const write = @import("write.zig");
const levels = script.ogs.levels;
const package = @import("../../loaders.zig").ogs.package;
const manifest = @import("../../loaders.zig").ogs.manifest;
const anim = @import("../../formats.zig").anim;
const scenecheck = @import("scenecheck.zig");

/// Where Play starts (`--start location:<level>[@<area>] | battle:<battle> | test-room:<character>[@<battle>]`):
/// gorky-tool play and the editor build with it, the viewer opens it (viewer/app/run.zig).
pub const Start = union(enum) {
    /// Level `level`, the party at area `area`'s points ("": where the level puts it).
    location: struct { level: []const u8, area: []const u8 = "" },
    battle: []const u8,
    /// Battle `battle` ("": the project's first) with one fighter of archetype `character`
    /// (`characters::grandma`) instead of its own, in `dist/play.ogp` only (never in `src/`):
    /// a bare room — none of the battle's own code, dialogue, heroes or other fighters; the
    /// party on its heroes' tiles.
    test_room: struct { character: []const u8, battle: []const u8 = "" },

    /// error.BadStart: none of the forms.
    pub fn parse(s: []const u8) error{BadStart}!Start {
        const colon = std.mem.indexOfScalar(u8, s, ':') orelse return error.BadStart;
        const kind = s[0..colon];
        const rest = s[colon + 1 ..];
        if (rest.len == 0) return error.BadStart;
        if (std.mem.eql(u8, kind, "location")) {
            const at = std.mem.indexOfScalar(u8, rest, '@') orelse return .{ .location = .{ .level = rest } };
            if (at == 0 or at + 1 == rest.len) return error.BadStart;
            return .{ .location = .{ .level = rest[0..at], .area = rest[at + 1 ..] } };
        }
        if (std.mem.eql(u8, kind, "battle")) return .{ .battle = rest };
        if (std.mem.eql(u8, kind, "test-room")) {
            const at = std.mem.indexOfScalar(u8, rest, '@') orelse return .{ .test_room = .{ .character = rest } };
            return .{ .test_room = .{ .character = rest[0..at], .battle = rest[at + 1 ..] } };
        }
        return error.BadStart;
    }

    /// As `parse` reads it, in `buf`.
    pub fn text(self: Start, buf: []u8) error{NoSpaceLeft}![]const u8 {
        return switch (self) {
            .location => |l| if (l.area.len > 0) std.fmt.bufPrint(buf, "location:{s}@{s}", .{ l.level, l.area }) else std.fmt.bufPrint(buf, "location:{s}", .{l.level}),
            .battle => |n| std.fmt.bufPrint(buf, "battle:{s}", .{n}),
            .test_room => |r| if (r.battle.len > 0) std.fmt.bufPrint(buf, "test-room:{s}@{s}", .{ r.character, r.battle }) else std.fmt.bufPrint(buf, "test-room:{s}", .{r.character}),
        };
    }
};

pub const Options = struct {
    /// The engine's data version ("0.1", formats/manifest.zig engine_version): the cache key's.
    engine: []const u8,
    start: ?Start = null,
    /// The editor's test kit (editor/testkit.zig): applied when the start opens a battle (a
    /// test room too); the package is then `dist/play.ogp`.
    kit: ?Kit = null,
};

/// What the heroes go into a test battle with: `blocks`, the battle's blocks of their
/// things (`weapon og_tk_1: weapons::pistol { owner = "sullivan"; … }`), in place of
/// the things `heroes` (archetype paths) get at the start (their OnStart's: the game
/// block's `test_kit`, world/start.zig testKit). `party`: a test room's heroes.
pub const Kit = struct { blocks: []const u8 = "", heroes: []const []const u8 = &.{}, party: []const []const u8 = &.{} };

/// A problem: its file (in the project: `src/…`, `opengorky.mod`), line (0: the file) and why.
pub const Problem = struct { file: []const u8, line: u32 = 0, message: []const u8, warning: bool = false };

pub const Report = struct {
    problems: []const Problem,
    /// The package written (`dist/<id>.ogp`, the test room's `dist/play.ogp`; relative to the
    /// project); "": none (errors).
    package: []const u8 = "",
    /// The level the start opens (a test room: its battle); "": no start.
    level: []const u8 = "",
    /// The package's entries; of them, those whose content is new or changed.
    entries: usize = 0,
    rebuilt: usize = 0,

    pub fn errors(self: Report) usize {
        var n: usize = 0;
        for (self.problems) |p| n += @intFromBool(!p.warning);
        return n;
    }
};

const cache_dir = "dist/.cache";

/// The project in `root` checked and, without errors, packed (`a`: an arena, it holds the
/// report). Fails only on what is no problem of the project (out of memory, a write).
pub fn build(io: Io, a: Allocator, root: Io.Dir, opts: Options) !Report {
    var b: Builder = .{ .io = io, .a = a };
    const text = root.readFileAlloc(io, manifest.file_name, a, .limited(1 << 16)) catch |err|
        return b.only(manifest.file_name, "can't read it: {t}", .{err});
    const m = manifest.parse(text);
    if (!m.isOgs()) return b.only(manifest.file_name, "format = {s}: not an OpenGorky project of OG Script (format = ogs)", .{m.format});
    if (!validId(m.id)) return b.only(manifest.file_name, "id = {s}: the package's name needs letters, digits, `_`, `-`", .{m.id});
    var dat = reader.gameDat(io, root, m) catch |err| blk: {
        try b.err(manifest.file_name, 0, "game = {s}: no installed game's dat ({t}; $OPENGORKY_GAME overrides it)", .{ m.game, err });
        break :blk null;
    };
    defer if (dat) |*d| d.close(io);
    var own = root.openDir(io, "src/assets", .{ .iterate = true }) catch null;
    defer if (own) |*d| d.close(io);
    var stack: ?assets.Stack = if (dat) |d| try .og(io, a, if (own) |o| .{ .folder = o } else null, d) else null;
    defer if (stack) |*s| s.deinit();

    // 1. Parse.
    const texts = try reader.readTexts(io, a, root);
    var units: std.ArrayList(parser.Unit) = .empty;
    var unit_of: std.ArrayList(?usize) = .empty;
    for (texts) |t| {
        var diag: parser.Diagnostic = .{};
        const u = parser.parse(a, t.data, t.path, &diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try b.err(t.path, diag.line, "{s}", .{diag.message});
                try unit_of.append(a, null);
                continue;
            },
        };
        try unit_of.append(a, units.items.len);
        try units.append(a, u);
    }
    var level: []const u8 = "";
    // The kit taken (a battle opened): the package is the test one.
    var kit_used = false;
    if (opts.start) |st| switch (st) {
        .location => |l| level = l.level,
        .battle => |n| level = n,
        .test_room => |r| if (try testRoom(&b, texts, unit_of.items, units.items, r, opts.kit orelse .{})) |n| {
            level = n;
            kit_used = true;
        },
    };
    if (opts.kit) |k| if (opts.start) |st| if (st != .test_room) if (battleNamed(units.items, level)) |n| {
        try addKit(&b, texts, unit_of.items, units.items, n, k);
        kit_used = true;
    };
    if (kit_used) try kitGame(&b, texts, unit_of.items, units.items, opts.kit orelse .{}, opts.start.? == .test_room);
    // A level in several texts: one block (script/ogs/levels.zig), as the reader makes it.
    if (try levels.merge(a, units.items)) |x| try b.err(x.file, x.line, "{s}", .{x.message});
    if (reader.missingRow(units.items)) |row| try b.err(if (std.mem.eql(u8, row, "Campaign") or std.mem.eql(u8, row, "ExeMusic")) "src/game.ogs" else "src/rules", 0, "{s}", .{try reader.missingText(a, row)});
    // FxAs is Classic's: the weapon's fields in OpenGorky (rules_text.applyOver skips it).
    for (texts, unit_of.items) |t, k| if (k) |i| for (units.items[i].modules) |um| for (um.rows) |r| if (r.kind == .call and std.mem.eql(u8, r.kind.call.text, "FxAs"))
        try b.err(t.path, r.line, "FxAs: no such row in OpenGorky: the weapon's effects_from, flash_from, launch_from, hit_from, hit_sound", .{});
    {
        var known = try effectIds(a, &.{});
        for (units.items) |u| try knownIds(a, &known, u);
        for (units.items) |u| for (try strayFx(a, u, &known)) |x|
            try b.warn(u.file, x.line, "{s} = {d}: no block has that classic_id, nor is it a built-in effect (WeaponFx): the stage shows nothing", .{ x.field, x.id });
    }

    // 2–6. Link the whole program against the engine's builtins, the schema and the assets.
    var prog: link.Program = .{};
    for (units.items) |u| {
        var ld: link.Diagnostic = .{};
        prog.add(a, u, &ld) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LinkError => try b.err(ld.file, ld.line, "{s}", .{ld.message}),
        };
    }
    var host: Host = .{ .stack = if (stack) |*s| s else null };
    const env: link.Env = .{ .ctx = &host, .builtin = builtin, .exists = Host.exists, .schema = core.schema.blockField, .natives = core.natives.components() };
    while (true) {
        var ld: link.Diagnostic = .{};
        prog.link(a, env, &ld) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // The failing text is dropped: the rest link again without it.
            error.LinkError => {
                try b.err(ld.file, ld.line, "{s}", .{ld.message});
                continue;
            },
        };
        break;
    }
    for (prog.warnings.items) |w| try b.problems.append(a, .{ .file = try src(a, w.file), .line = w.line, .message = w.message, .warning = true });
    // 5. Each location's own assets: its background (the map and the rest may be missing).
    for (units.items) |u| for (u.modules) |mod| for (mod.entities) |e| {
        if (!std.mem.eql(u8, e.kind, "level") and !std.mem.eql(u8, e.kind, "battle")) continue;
        const s = &(stack orelse break);
        var buf: [assets.max_path]u8 = undefined;
        const has = for ([_][]const u8{ "bkg", "jpg" }) |ext| {
            if (s.exists(std.fmt.bufPrint(&buf, "levels/{s}/background.{s}", .{ e.name, ext }) catch continue)) break true;
        } else false;
        if (!has) try b.err(u.file, e.line, "{s} {s}: no levels/{s}/background.jpg (or .bkg) in src/assets or the game", .{ e.kind, e.name, e.name });
    };
    if (stack) |*s| for (units.items) |u| for (u.modules) |mod| for (mod.entities) |e| {
        if (std.mem.eql(u8, e.kind, "look")) try checkLook(&b, a, s, u.file, e);
    };
    // Objects' actions (`action = Take`): an `action` block or Action row of that name, `walk`, `none`.
    try checkActions(&b, a, units.items);
    // Scenes: their commands' arguments, what they name (compose/og/scenecheck.zig).
    var code: std.ArrayList([]const u8) = .empty;
    for (texts) |t| if (!std.mem.startsWith(u8, t.path, "scenes/") and !std.mem.startsWith(u8, t.path, "dialogs/")) try code.append(a, t.data);
    for (try scenecheck.run(a, if (stack) |*s| s else null, units.items, code.items)) |p|
        try b.problems.append(a, .{ .file = try src(a, p.file), .line = p.line, .message = p.message, .warning = p.warning });
    if (level.len > 0 and findLevel(units.items, level) == null) try b.err("--start", 0, "no level or battle {s} in the project", .{level});

    var report: Report = .{ .problems = b.problems.items, .level = level };
    if (report.errors() > 0) return report;

    // The package: the manifest, the texts, the own assets.
    const name = if (kit_used) "play.ogp" else try std.fmt.allocPrint(a, "{s}.ogp", .{m.id});
    try root.createDirPath(io, cache_dir);
    var dist = try root.openDir(io, "dist", .{});
    defer dist.close(io);
    var old: ?package.Package = package.Package.open(io, a, dist, name) catch null;
    defer if (old) |*o| o.close(io);
    const key = try cacheKey(a, opts.engine);
    const cache_name = try std.fmt.allocPrint(a, ".cache/{s}.txt", .{name});
    const cached = loadCache(io, a, dist, cache_name, key);
    // Each file and its size and time (texts: none, they are read anyway).
    var items: std.ArrayList(Item) = .empty;
    for (texts) |t| try items.append(a, .{ .file = .{ .path = try std.fmt.allocPrint(a, "src/{s}", .{t.path}), .data = t.data } });
    if (own) |d| {
        var walker = try d.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |e| if (e.kind == .file) {
            const path = try std.fmt.allocPrint(a, "src/assets/{s}", .{e.path});
            std.mem.replaceScalar(u8, path, '\\', '/');
            const st = try d.statFile(io, e.path, .{});
            const c: Cached = .{ .size = st.size, .mtime = st.mtime.nanoseconds };
            // The same size and time as cached: the bytes are the old package's, not read again.
            const kept = if (old) |*o| try unchanged(io, a, o, cached.get(path), path, c) else null;
            try items.append(a, .{ .file = kept orelse .{ .path = path, .data = try d.readFileAlloc(io, e.path, a, .unlimited) }, .stat = c });
        };
    }
    std.mem.sort(Item, items.items, {}, struct {
        fn lt(_: void, x: Item, y: Item) bool {
            return std.mem.order(u8, x.file.path, y.file.path) == .lt;
        }
    }.lt);
    try items.insert(a, 0, .{ .file = .{ .path = manifest.file_name, .data = text } });
    const files = try a.alloc(package.File, items.items.len);
    for (items.items, files) |*it, *f| {
        it.stat.sha = it.file.sha orelse package.hash(it.file.data);
        it.file.sha = it.stat.sha;
        f.* = it.file;
        const was = cached.get(f.path);
        if (was == null or !std.mem.eql(u8, &was.?.sha, &it.stat.sha)) report.rebuilt += 1;
    }
    if (old) |*o| {
        o.close(io);
        old = null;
    }
    try package.write(io, a, dist, name, files);
    try saveCache(io, a, dist, cache_name, key, items.items);
    report.entries = files.len;
    report.package = try std.fmt.allocPrint(a, "dist/{s}", .{name});
    return report;
}

/// Look `e`'s model (`models/<mesh>.ani`; no `mesh`: not checked) is there; an
/// animation its idles and slots name that it lacks is a warning.
fn checkLook(b: *Builder, a: Allocator, s: *assets.Stack, file: []const u8, e: ir.Entity) !void {
    const mesh = for (e.fields) |f| {
        if (std.mem.eql(u8, f.name, "mesh")) break core.schema.text(f.value) orelse return;
    } else return;
    const path = try std.fmt.allocPrint(a, "models/{s}.ani", .{mesh});
    const bytes = s.read(a, path) catch return b.err(file, e.line, "look {s}: no {s} in src/assets or the game", .{ e.name, path });
    const list = anim.parseAni(a, bytes) catch return b.err(file, e.line, "look {s}: {s} does not read", .{ e.name, path });
    for (e.fields) |f| if (f.value.kind == .list and (std.mem.eql(u8, f.name, "idles") or std.mem.eql(u8, f.name, "slots"))) for (f.value.kind.list) |x| {
        if (x.kind != .call) continue;
        const n = core.schema.text(core.schema.recordField(x.kind.call, "anim") orelse continue) orelse continue;
        // Classic registers it too and plays nothing: a warning (the converter keeps them).
        if (list.find(n) == null) try b.warn(file, x.line, "look {s}: no animation {s} in {s}", .{ e.name, n, path });
    };
}

/// Each `action`…`action9` word of a block (any depth) names an action: an `action` block, an
/// Action row (lower case aside, as the reader takes it), `walk` or `none`.
fn checkActions(b: *Builder, a: Allocator, units: []const parser.Unit) !void {
    var known: std.StringHashMapUnmanaged(void) = .empty;
    for (units) |u| for (u.modules) |m| {
        for (m.entities) |e| if (std.mem.eql(u8, e.kind, "action")) try known.put(a, try std.ascii.allocLowerString(a, e.name), {});
        for (m.rows) |r| if (r.kind == .call and std.mem.eql(u8, r.kind.call.text, "Action")) for (r.kind.call.named) |n|
            if (std.mem.eql(u8, n.name, "name")) if (core.schema.text(n.value)) |t| try known.put(a, try std.ascii.allocLowerString(a, t), {});
    };
    const Walk = struct {
        fn each(bb: *Builder, al: Allocator, k: *const std.StringHashMapUnmanaged(void), file: []const u8, es: []const ir.Entity) !void {
            for (es) |e| {
                for (e.fields) |f| {
                    const is_action = std.mem.startsWith(u8, f.name, "action") and (f.name.len == 6 or (f.name.len == 7 and std.ascii.isDigit(f.name[6])));
                    if (!is_action or f.value.kind != .word) continue;
                    const w = f.value.kind.word;
                    if (core.schema.noAction(w) != null or k.contains(try std.ascii.allocLowerString(al, w))) continue;
                    try bb.err(file, f.value.line, "{s} {s}: {s} = {s}: no action {s} (an action block, walk, none)", .{ e.kind, e.name, f.name, w, w });
                }
                try each(bb, al, k, file, e.children);
            }
        }
    };
    for (units) |u| for (u.modules) |m| try Walk.each(b, a, &known, u.file, m.entities);
}

const Builder = struct {
    io: Io,
    a: Allocator,
    problems: std.ArrayList(Problem) = .empty,

    fn err(self: *Builder, file: []const u8, line: u32, comptime fmt: []const u8, args: anytype) !void {
        try self.problems.append(self.a, .{ .file = try src(self.a, file), .line = line, .message = try std.fmt.allocPrint(self.a, fmt, args) });
    }

    fn warn(self: *Builder, file: []const u8, line: u32, comptime fmt: []const u8, args: anytype) !void {
        try self.problems.append(self.a, .{ .file = try src(self.a, file), .line = line, .message = try std.fmt.allocPrint(self.a, fmt, args), .warning = true });
    }

    /// A report of that one problem.
    fn only(self: *Builder, file: []const u8, comptime fmt: []const u8, args: anytype) !Report {
        try self.err(file, 0, fmt, args);
        return .{ .problems = self.problems.items };
    }
};

/// A text's path in `src/` as the project's (`src/rules/ui.ogs`); other files as given.
/// A stage field given as a number (`effects_from`, `flash_from`, `launch_from`,
/// `hit_from`: a weapon block's, a MonsterAttack row's) that names nothing: N > 0 neither
/// a block's classic_id nor an effect record's id (`known`: knownIds, effectIds). The core
/// looks the stage's record up by N (battle/generic.zig fxOf): none, so it shows nothing
/// (a warning, the editor's Problems tab too).
const StrayFx = struct { line: u32, field: []const u8, id: i32 };

const stage_fields = [_][]const u8{ "effects_from", "flash_from", "launch_from", "hit_from" };

pub fn isStage(name: []const u8) bool {
    for (stage_fields) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

pub fn strayFx(a: Allocator, u: parser.Unit, known: *const std.AutoHashMapUnmanaged(i32, void)) ![]const StrayFx {
    var out: std.ArrayList(StrayFx) = .empty;
    for (u.modules) |m| {
        for (m.entities) |e| try strayIn(a, e, known, &out);
        for (m.rows) |r| if (r.kind == .call and std.mem.eql(u8, r.kind.call.text, "MonsterAttack")) for (r.kind.call.named) |n|
            try stray(a, n.name, n.value, known, &out);
    }
    return out.items;
}

fn strayIn(a: Allocator, e: ir.Entity, known: *const std.AutoHashMapUnmanaged(i32, void), out: *std.ArrayList(StrayFx)) !void {
    if (std.mem.eql(u8, e.kind, "weapon")) for (e.fields) |f| try stray(a, f.name, f.value, known, out);
    for (e.children) |c| try strayIn(a, c, known, out);
}

fn stray(a: Allocator, name: []const u8, v: *const ir.Expr, known: *const std.AutoHashMapUnmanaged(i32, void), out: *std.ArrayList(StrayFx)) !void {
    if (!isStage(name)) return;
    const n = core.schema.int(v) orelse return;
    if (n > 0 and !known.contains(n)) try out.append(a, .{ .line = v.line, .field = name, .id = n });
}

/// The built-in effect records' ids (core/classic.zig `weapon_fx`) and those of `more`
/// (the records in force), with the WeaponFx rows' of the units knownIds adds.
pub fn effectIds(a: Allocator, more: []const core.effect.Weapon) !std.AutoHashMapUnmanaged(i32, void) {
    var set: std.AutoHashMapUnmanaged(i32, void) = .empty;
    for ([_][]const core.effect.Weapon{ &core.classic.weapon_fx, more }) |ws| for (ws) |w| try set.put(a, w.id, {});
    return set;
}

/// Into `set`: unit `u`'s blocks' classic_ids (nested ones too) and its WeaponFx rows' ids.
pub fn knownIds(a: Allocator, set: *std.AutoHashMapUnmanaged(i32, void), u: parser.Unit) !void {
    const Walk = struct {
        fn in(x: Allocator, s: *std.AutoHashMapUnmanaged(i32, void), e: ir.Entity) !void {
            for (e.fields) |f| if (std.mem.eql(u8, f.name, "classic_id")) if (core.schema.int(f.value)) |n| try s.put(x, n, {});
            for (e.children) |c| try in(x, s, c);
        }
    };
    for (u.modules) |m| {
        for (m.entities) |e| try Walk.in(a, set, e);
        for (m.rows) |r| if (r.kind == .call and std.mem.eql(u8, r.kind.call.text, "WeaponFx")) for (r.kind.call.named) |n| if (std.mem.eql(u8, n.name, "id")) if (core.schema.int(n.value)) |k| try set.put(a, k, {});
    }
}

test strayFx {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\module weapons {
        \\    weapon gun {
        \\        classic_id = 7001;
        \\        effects_from = 7001;
        \\        flash_from = 98;
        \\        launch_from = 6999;
        \\        hit_from = -1;
        \\    }
        \\}
        \\WeaponFx(id = 6998);
        \\MonsterAttack(fighter = 1, weapon = 0, hit_from = 6997, flash_from = 6998);
        \\
    ;
    var diag: parser.Diagnostic = .{};
    const u = try parser.parse(a, text, "t.ogs", &diag);
    var known = try effectIds(a, &.{});
    try testing.expect(known.contains(98));
    try knownIds(a, &known, u);
    const got = try strayFx(a, u, &known);
    try testing.expectEqual(2, got.len);
    // The top-level rows' module first, then the weapons'.
    try testing.expectEqual(6997, got[0].id);
    try testing.expectEqualStrings("launch_from", got[1].field);
    try testing.expectEqual(6, got[1].line);
}

fn src(a: Allocator, file: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, file, ".ogs") and !std.mem.startsWith(u8, file, "src/")) return std.fmt.allocPrint(a, "src/{s}", .{file});
    return file;
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or std.mem.eql(u8, id, "play")) return false;
    for (id) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    return true;
}

/// The top-level `level`/`battle` block named `name` (case aside, as the reader finds it).
fn findLevel(units: []const parser.Unit, name: []const u8) ?*const ir.Entity {
    for (units) |u| for (u.modules) |m| for (m.entities) |*e| {
        if ((std.mem.eql(u8, e.kind, "level") or std.mem.eql(u8, e.kind, "battle")) and std.ascii.eqlIgnoreCase(e.name, name)) return e;
    };
    return null;
}

/// The test room in `texts`: battle `battle` ("": the first) keeps its fields, its
/// logic and its other blocks, its first fighter becomes one of archetype `character` (its
/// name and `tile` kept: it stands where that one stood; its weapon is the archetype's
/// nested one) and its other fighters go. The
/// battle's text is replaced (and parsed again) in `texts` and `units`; its name, or null:
/// a problem said.
fn testRoom(b: *Builder, texts: []reader.Text, unit_of: []const ?usize, units: []parser.Unit, r: @FieldType(Start, "test_room"), the_kit: Kit) !?[]const u8 {
    const character = r.character;
    const battle = r.battle;
    const kit = try kitBlocks(b, the_kit) orelse return null;
    // The battle: the first (texts' order) of that name; its parts (a battle in several
    // texts of its folder, script/ogs/levels.zig) in their paths' order.
    const name = battleNamed(units, battle) orelse {
        try b.err("--start", 0, "test room: no battle {s} in the project", .{if (battle.len > 0) battle else "(any)"});
        return null;
    };
    const Part = struct { t: usize, ns: []const u8, e: ir.Entity };
    var parts: std.ArrayList(Part) = .empty;
    for (texts, unit_of, 0..) |t, ui, ti| {
        _ = t;
        const u = units[ui orelse continue];
        for (u.modules) |m| for (m.entities) |e| if (std.mem.eql(u8, e.kind, "battle") and std.mem.eql(u8, e.name, name)) try parts.append(b.a, .{ .t = ti, .ns = m.path, .e = e });
    }
    std.mem.sort(Part, parts.items, texts, struct {
        fn lt(ts: []reader.Text, x: Part, y: Part) bool {
            return std.mem.order(u8, ts[x.t].path, ts[y.t].path) == .lt;
        }
    }.lt);
    var kids: std.ArrayList(ir.Entity) = .empty;
    var first = true;
    // The replaced fighter's name (its placement stays).
    var replaced: []const u8 = "";
    for (parts.items) |p| for (p.e.children) |c| if (std.mem.eql(u8, c.kind, "fighter")) {
        replaced = c.name;
        break;
    };
    for (parts.items) |p| for (p.e.children) |c| {
        // The battle's own heroes go (the party is the kit's), its other fighters too.
        if (std.mem.eql(u8, c.kind, "hero")) continue;
        if (!std.mem.eql(u8, c.kind, "fighter")) {
            // The replaced fighter's things (`owner`) go with it: the enemy keeps its own.
            if (ownedBy(c, replaced)) continue;
            try kids.append(b.a, c);
        } else if (first) {
            first = false;
            // Its tile stays: the battle's placement is the instance's.
            var tile: std.ArrayList(ir.Named) = .empty;
            for (c.fields) |f| if (std.mem.eql(u8, f.name, "tile")) try tile.append(b.a, f);
            try kids.append(b.a, .{ .kind = "fighter", .name = c.name, .base = character, .fields = tile.items, .attach = &.{}, .line = c.line });
        }
    };
    if (first) {
        try b.err(texts[parts.items[0].t].path, parts.items[0].e.line, "test room: battle {s} has no fighter to replace", .{name});
        return null;
    }
    try kids.appendSlice(b.a, kit);
    // A bare room: none of the battle's code (its dialogue, videos), dialogue or boss music;
    // the placement of what stays, the party on its heroes' tiles in order.
    var heroes: std.StringHashMapUnmanaged(void) = .empty;
    for (units) |u| for (u.modules) |m| for (m.entities) |e| if (std.mem.eql(u8, e.kind, "hero")) try heroes.put(b.a, e.name, {});
    for (parts.items, 0..) |p, k| {
        var room = p.e;
        // Its code gone, what it injects (classes::CombatLevel) kept.
        if (room.own) |o| {
            const c = try b.a.create(ir.Component);
            c.* = o.*;
            c.methods = &.{};
            room.own = c;
        }
        var fields: std.ArrayList(ir.Named) = .empty;
        for (room.fields) |f| {
            if (std.mem.eql(u8, f.name, "dialog") or std.mem.eql(u8, f.name, "boss")) continue;
            if (std.mem.eql(u8, f.name, "placement")) {
                try fields.append(b.a, .{ .name = f.name, .value = try roomPlacement(b.a, f.value, kids.items, replaced, &heroes, the_kit.party) });
                continue;
            }
            try fields.append(b.a, f);
        }
        room.fields = fields.items;
        room.children = if (k == 0) kids.items else &.{};
        const t = &texts[p.t];
        var diag: parser.Diagnostic = .{};
        t.data = try write.replaceBlock(b.a, t.data, t.path, p.ns, &.{name}, room, &diag);
        units[unit_of[p.t].?] = try parser.parse(b.a, t.data, t.path, &diag);
    }
    return name;
}

/// The kit's blocks, read as the inside of a battle; null: a problem said.
fn kitBlocks(b: *Builder, k: Kit) !?[]const ir.Entity {
    if (k.blocks.len == 0) return &.{};
    var diag: parser.Diagnostic = .{};
    const ku = parser.parse(b.a, try std.fmt.allocPrint(b.a, "battle kit {{\n{s}}}\n", .{k.blocks}), "test kit", &diag) catch {
        try b.err("test kit", diag.line, "the test kit does not read: {s}", .{diag.message});
        return null;
    };
    return ku.modules[0].entities[0].children;
}

/// Battle `name`'s first part (its texts' order) with the kit's blocks after its own.
fn addKit(b: *Builder, texts: []reader.Text, unit_of: []const ?usize, units: []parser.Unit, name: []const u8, k: Kit) !void {
    const kit = try kitBlocks(b, k) orelse return;
    if (kit.len == 0) return;
    for (texts, unit_of) |*t, ui| {
        const u = units[ui orelse continue];
        for (u.modules) |m| for (m.entities) |e| if (std.mem.eql(u8, e.kind, "battle") and std.mem.eql(u8, e.name, name)) {
            var room = e;
            room.children = try std.mem.concat(b.a, ir.Entity, &.{ e.children, kit });
            var diag: parser.Diagnostic = .{};
            t.data = try write.replaceBlock(b.a, t.data, t.path, m.path, &.{name}, room, &diag);
            units[ui.?] = try parser.parse(b.a, t.data, t.path, &diag);
            return;
        };
    }
}

/// The game block's `test_kit` (the kit's heroes: their start things are the kit's) and,
/// in a test room, its `party` (the heroes ticked).
fn kitGame(b: *Builder, texts: []reader.Text, unit_of: []const ?usize, units: []parser.Unit, k: Kit, room: bool) !void {
    for (texts, unit_of) |*t, ui| {
        const u = units[ui orelse continue];
        for (u.modules) |m| for (m.entities) |e| if (std.mem.eql(u8, e.kind, "game")) {
            var fields: std.ArrayList(ir.Named) = .empty;
            for (e.fields) |f| if (!(std.mem.eql(u8, f.name, "test_kit") or std.mem.eql(u8, f.name, "test_room") or (room and std.mem.eql(u8, f.name, "party")))) try fields.append(b.a, f);
            try fields.append(b.a, .{ .name = "test_kit", .value = try wordList(b.a, k.heroes) });
            if (room) {
                try fields.append(b.a, .{ .name = "party", .value = try wordList(b.a, k.party) });
                // The room's heroes play free of their story locks (world/start.zig testKit).
                try fields.append(b.a, .{ .name = "test_room", .value = try intLit(b.a, 1) });
            }
            var g = e;
            g.fields = fields.items;
            var diag: parser.Diagnostic = .{};
            t.data = try write.replaceBlock(b.a, t.data, t.path, m.path, &.{e.name}, g, &diag);
            units[ui.?] = try parser.parse(b.a, t.data, t.path, &diag);
            return;
        };
    }
}

fn wordList(a: Allocator, words: []const []const u8) !*const ir.Expr {
    const items = try a.alloc(*const ir.Expr, words.len);
    for (words, items) |w, *x| x.* = try word(a, w);
    const x = try a.create(ir.Expr);
    x.* = .{ .line = 0, .kind = .{ .list = items } };
    return x;
}

/// A test room's `placement`: the entries of what stays in it (`kids`, the replaced
/// fighter), the heroes' (an entry naming a `hero` block) tiles given in order to the
/// party (`characters::sullivan` → `@sullivan`).
fn roomPlacement(a: Allocator, old: *const ir.Expr, kids: []const ir.Entity, replaced: []const u8, heroes: *const std.StringHashMapUnmanaged(void), party: []const []const u8) !*const ir.Expr {
    if (old.kind != .list) return old;
    var keep: std.ArrayList(*const ir.Expr) = .empty;
    var slots: std.ArrayList(*const ir.Expr) = .empty;
    for (old.kind.list) |x| {
        if (x.kind != .call) continue;
        const who: []const u8 = for (x.kind.call.named) |n| {
            if (std.mem.eql(u8, n.name, "who")) break if (n.value.kind == .ref) n.value.kind.ref else (core.schema.text(n.value) orelse "");
        } else "";
        var hero = false;
        var it = heroes.keyIterator();
        while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.*, who)) {
            hero = true;
        };
        if (hero) {
            try slots.append(a, x);
            continue;
        }
        const stays = std.ascii.eqlIgnoreCase(who, replaced) or for (kids) |c| {
            if (std.ascii.eqlIgnoreCase(c.name, who)) break true;
        } else false;
        if (stays) try keep.append(a, x);
    }
    for (party, 0..) |p, i| {
        if (i >= slots.items.len) break;
        const s = slots.items[i].kind.call;
        const named = try a.dupe(ir.Named, s.named);
        for (named) |*n| if (std.mem.eql(u8, n.name, "who")) {
            const r = try a.create(ir.Expr);
            r.* = .{ .line = 0, .kind = .{ .ref = p[if (std.mem.lastIndexOf(u8, p, "::")) |k| k + 2 else 0..] } };
            n.value = r;
        };
        const e = try a.create(ir.Expr);
        e.* = .{ .line = slots.items[i].line, .kind = .{ .call = .{ .id = s.id, .text = s.text, .args = s.args, .named = named } } };
        try keep.append(a, e);
    }
    const x = try a.create(ir.Expr);
    x.* = .{ .line = old.line, .kind = .{ .list = keep.items } };
    return x;
}

/// Block `e`'s `owner` is `name`.
fn ownedBy(e: ir.Entity, name: []const u8) bool {
    for (e.fields) |f| if (std.mem.eql(u8, f.name, "owner") and f.value.kind == .lit and f.value.kind.lit == .string) return std.ascii.eqlIgnoreCase(f.value.kind.lit.string, name);
    return false;
}

fn archetype(units: []const parser.Unit, path: []const u8) ?struct { e: ir.Entity } {
    const k = std.mem.lastIndexOf(u8, path, "::");
    const ns = if (k) |x| path[0..x] else "";
    const name = if (k) |x| path[x + 2 ..] else path;
    for (units) |u| for (u.modules) |m| if (std.mem.eql(u8, m.path, ns)) for (m.entities) |e| if (std.mem.eql(u8, e.name, name)) return .{ .e = e };
    return null;
}

fn word(a: Allocator, w: []const u8) !*const ir.Expr {
    const x = try a.create(ir.Expr);
    x.* = .{ .line = 0, .kind = .{ .word = w } };
    return x;
}

fn intLit(a: Allocator, n: i32) !*const ir.Expr {
    const x = try a.create(ir.Expr);
    x.* = .{ .line = 0, .kind = .{ .lit = .{ .int = n } } };
    return x;
}

/// The first battle of `units` named `name` (any case; "": any), as its block spells it.
fn battleNamed(units: []const parser.Unit, name: []const u8) ?[]const u8 {
    for (units) |u| for (u.modules) |m| for (m.entities) |e| {
        if (std.mem.eql(u8, e.kind, "battle") and (name.len == 0 or std.ascii.eqlIgnoreCase(e.name, name))) return e.name;
    };
    return null;
}

/// Builtin `name` as the engine registers it (builtins.zig `table`; script/runtime.zig
/// envBuiltin): by its OGS name, or by its Classic one where OGS has it elsewhere.
fn builtin(_: *anyopaque, name: []const u8) ?link.Builtin {
    inline for (builtins.table) |e| {
        const sig = e[2];
        if (std.mem.eql(u8, if (sig.ogs.len > 0) sig.ogs else e[0], name)) return .{ .id = 0, .sig = sig.text };
        if (std.mem.eql(u8, e[0], name)) return .{ .id = 0, .sig = sig.text, .moved = if (sig.classic) "" else sig.ogs };
    }
    return null;
}

/// The link's host: what no block of the program declares (a level, a scene… — then
/// none: the project has only its blocks) and the assets (in `src/assets/` or the game).
const Host = struct {
    stack: ?*assets.Stack,

    fn exists(ctx: *anyopaque, kind: ir.Sigil, name: []const u8) ?bool {
        const h: *Host = @ptrCast(@alignCast(ctx));
        const s = h.stack orelse return null;
        return switch (kind) {
            .level, .scene, .dialog, .character, .item, .weapon, .look => false,
            .asset => s.exists(name),
            // shortcut: a bare sound name (`~s"axe"`) is the bank's to find: not checked.
            .sound => if (std.mem.indexOfScalar(u8, name, '/') != null) s.exists(name) else null,
            .text, .none => null,
        };
    }
};

// ---------------------------------------------------------------- the cache

/// A cached file: its hash, size and modification time (texts: the hash only).
const Cached = struct { sha: [32]u8 = @splat(0), size: u64 = 0, mtime: i96 = 0 };

/// A file going into the package and what the cache keeps of it.
const Item = struct { file: package.File, stat: Cached = .{} };

/// Asset `path` (now of size and time `now`) from the old package `old` when the cache
/// says it has not changed (`was`: its cached size, time and hash, which the old entry has).
fn unchanged(io: Io, a: Allocator, old: *const package.Package, was: ?Cached, path: []const u8, now: Cached) !?package.File {
    const w = was orelse return null;
    if (w.size != now.size or w.mtime != now.mtime) return null;
    const e = old.find(path, false) orelse return null;
    if (!std.mem.eql(u8, &e.sha, &w.sha)) return null;
    return .{ .path = path, .data = try old.read(io, a, e), .sha = w.sha };
}

/// The cache's key: the engine's data version and the schema's hash (the hosts, their
/// fields, types and words: what the checks read).
fn cacheKey(a: Allocator, engine: []const u8) ![]const u8 {
    var h: std.hash.Wyhash = .init(0);
    for (core.schema.hosts) |host| {
        h.update(host.name);
        h.update(host.parent orelse "-");
        for (host.fields) |f| {
            h.update(f.name);
            h.update(@tagName(f.type));
            h.update(f.type_name);
        }
    }
    // The prelude's types the fields name.
    h.update(@import("../../script.zig").traits.types);
    return std.fmt.allocPrint(a, "opengorky-build engine {s} schema {x:0>16}", .{ engine, h.final() });
}

/// The cache `name` of `dist`: path → hash, size, time; empty if missing or of another key.
fn loadCache(io: Io, a: Allocator, dist: Io.Dir, name: []const u8, key: []const u8) std.StringHashMapUnmanaged(Cached) {
    var map: std.StringHashMapUnmanaged(Cached) = .empty;
    const text = dist.readFileAlloc(io, name, a, .limited(64 << 20)) catch return map;
    var lines = std.mem.splitScalar(u8, text, '\n');
    if (!std.mem.eql(u8, lines.next() orelse "", key)) return map;
    while (lines.next()) |line| {
        var f = std.mem.splitScalar(u8, line, ' ');
        var c: Cached = .{};
        _ = std.fmt.hexToBytes(&c.sha, f.next() orelse continue) catch continue;
        c.size = std.fmt.parseInt(u64, f.next() orelse continue, 10) catch continue;
        c.mtime = std.fmt.parseInt(i96, f.next() orelse continue, 10) catch continue;
        map.put(a, f.rest(), c) catch return map;
    }
    return map;
}

fn saveCache(io: Io, a: Allocator, dist: Io.Dir, name: []const u8, key: []const u8, items: []const Item) !void {
    var out: Io.Writer.Allocating = .init(a);
    try out.writer.print("{s}\n", .{key});
    for (items) |it| try out.writer.print("{x} {d} {d} {s}\n", .{ &it.stat.sha, it.stat.size, it.stat.mtime, it.file.path });
    try dist.writeFile(io, .{ .sub_path = name, .data = out.written() });
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// The files of a small project: its manifest (game `game`, an empty `dat`), the single
/// rows, a battle of two fighters with its background, an archetype.
const base_files = [_][2][]const u8{
    .{ "opengorky.mod", "format = ogs\nid = t\ngame = game\n" },
    .{ "src/rules/shell.ogs", "Campaign();\nWindows();\nMainMenu();\nExeMusic();\nUiSounds();\nExeAnims();\nHoldPoints();\n" },
    .{ "src/battles/b/battle.ogs", "battle b {\n    grid_columns = 4;\n    fighter f: characters::kid {\n        hp = 9;\n    }\n    fighter g: characters::kid {\n    }\n}\n" },
    .{ "src/characters/kid.ogs", "module characters {\n    fighter kid {\n        hp = 5;\n    }\n}\n" },
    .{ "src/assets/levels/b/background.jpg", "jpeg" },
};

/// `base_files`, then `more` over them ("" data: the file left out), in `dir`.
fn testProject(io: Io, dir: Io.Dir, more: []const [2][]const u8) !void {
    try dir.createDirPath(io, "game/dat");
    for (base_files) |f| {
        const over = for (more) |m| {
            if (std.mem.eql(u8, m[0], f[0])) break true;
        } else false;
        if (!over) try put(io, dir, f[0], f[1]);
    }
    for (more) |m| if (m[1].len > 0) try put(io, dir, m[0], m[1]);
}

fn put(io: Io, dir: Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.createDirPath(io, d);
    try dir.writeFile(io, .{ .sub_path = path, .data = data });
}

/// The build of `base_files` with `more`, in `a`.
fn testBuild(a: Allocator, tmp: *testing.TmpDir, more: []const [2][]const u8, start: ?Start) !Report {
    try testProject(testing.io, tmp.dir, more);
    return build(testing.io, a, tmp.dir, .{ .engine = "0.1", .start = start });
}

/// `r` has an error at `file:line` saying `part`, and no package.
fn expectError(r: Report, file: []const u8, line: u32, part: []const u8) !void {
    for (r.problems) |p| if (!p.warning and std.mem.eql(u8, p.file, file) and p.line == line and std.mem.indexOf(u8, p.message, part) != null) {
        try testing.expectEqualStrings("", r.package);
        return;
    };
    for (r.problems) |p| std.debug.print("{s}:{d}: {s}\n", .{ p.file, p.line, p.message });
    return error.TestExpectedError;
}

test "build: a clean project packs; again nothing is rebuilt; one file edited, one entry; a newer engine, all" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try testBuild(a, &tmp, &.{}, null);
    try testing.expectEqual(0, r.errors());
    try testing.expectEqualStrings("dist/t.ogp", r.package);
    try testing.expectEqual(5, r.entries);
    try testing.expectEqual(5, r.rebuilt);
    var pkg = try package.Package.open(io, a, tmp.dir, "dist/t.ogp");
    try testing.expectEqualStrings(base_files[2][1], try pkg.read(io, a, pkg.find("src/battles/b/battle.ogs", false).?));
    try testing.expectEqualStrings("jpeg", try pkg.read(io, a, pkg.find("src/assets/levels/b/background.jpg", false).?));
    pkg.close(io);
    try testing.expectEqual(0, (try build(io, a, tmp.dir, .{ .engine = "0.1" })).rebuilt);
    try put(io, tmp.dir, "src/characters/kid.ogs", "module characters {\n    fighter kid {\n        hp = 6;\n    }\n}\n");
    const one = try build(io, a, tmp.dir, .{ .engine = "0.1" });
    try testing.expectEqual(1, one.rebuilt);
    try testing.expectEqual(5, one.entries);
    // An asset of another size: read again (and counted); the cache key of another engine: all.
    try put(io, tmp.dir, "src/assets/levels/b/background.jpg", "jpeg2");
    try testing.expectEqual(1, (try build(io, a, tmp.dir, .{ .engine = "0.1" })).rebuilt);
    try testing.expectEqual(5, (try build(io, a, tmp.dir, .{ .engine = "0.2" })).rebuilt);
}

test "build check 1: a text that does not parse, at its line" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try expectError(try testBuild(arena.allocator(), &tmp, &.{.{ "src/game.ogs", "fn f() {\n    return 1 +;\n}\n" }}, null), "src/game.ogs", 2, "");
}

test "build check 2: the program links (an unknown function, a component's parameter)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try testBuild(arena.allocator(), &tmp, &.{
        .{ "src/game.ogs", "fn f() {\n    return nope(1);\n}\n" },
        .{ "src/characters/kid.ogs", "module characters {\n    fighter kid {\n        attach Calm(by = 1);\n    }\n    component Calm for fighter {\n    }\n}\n" },
    }, null);
    try expectError(r, "src/game.ogs", 2, "nope");
    try expectError(r, "src/characters/kid.ogs", 3, "by");
}

test "build check 3: data blocks against the schema (no such field, not its type)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try expectError(try testBuild(arena.allocator(), &tmp, &.{.{ "src/characters/kid.ogs", "module characters {\n    fighter kid {\n        nope = 5;\n    }\n}\n" }}, null), "src/characters/kid.ogs", 3, "fighter has no field nope");
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    try expectError(try testBuild(arena.allocator(), &tmp2, &.{.{ "src/characters/kid.ogs", "module characters {\n    fighter kid {\n        hp = \"many\";\n    }\n}\n" }}, null), "src/characters/kid.ogs", 3, "hp");
    // The OG reader's structured fields: a tile, a camera record, a placement, a look.
    for ([_]struct { []const u8, []const u8 }{
        .{ "tile = [2];", "tile: expected [x, y]" },
        .{ "tile = [2, \"x\"];", "tile: expected [x, y] or [x, y, direction]: ints" },
        .{ "look = characters::kid;", "look: no look characters::kid" },
    }) |c| {
        var t: testing.TmpDir = testing.tmpDir(.{});
        defer t.cleanup();
        const text = try std.fmt.allocPrint(arena.allocator(), "battle b {{\n    fighter f: characters::kid {{\n        {s}\n    }}\n}}\n", .{c[0]});
        try expectError(try testBuild(arena.allocator(), &t, &.{.{ "src/battles/b/battle.ogs", text }}, null), "src/battles/b/battle.ogs", 3, c[1]);
    }
    for ([_]struct { []const u8, []const u8 }{
        .{ "camera = Camera(viewQ = 1);", "camera: Camera takes perspective, near_plane" },
        .{ "camera = Camera(eye_x = \"far\");", "camera: Camera.eye_x: expected float" },
        .{ "placement = [Place(who = @f, tile = [1, 1]), Place(tile = [2, 2])];", "placement: Place needs who" },
        .{ "placement = Place(who = @f);", "placement: expected list<Place>, not Place" },
    }) |c| {
        var t: testing.TmpDir = testing.tmpDir(.{});
        defer t.cleanup();
        const text = try std.fmt.allocPrint(arena.allocator(), "battle b {{\n    {s}\n}}\n", .{c[0]});
        try expectError(try testBuild(arena.allocator(), &t, &.{.{ "src/battles/b/battle.ogs", text }}, null), "src/battles/b/battle.ogs", 2, c[1]);
    }
}

test "build check 4: references resolve (an archetype, a level by its sigil)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try testBuild(arena.allocator(), &tmp, &.{
        .{ "src/battles/b/battle.ogs", "battle b {\n    fighter f: characters::nobody {\n    }\n}\n" },
        .{ "src/game.ogs", "fn go() {\n    level::Load(~l\"nowhere\");\n}\n" },
    }, null);
    try expectError(r, "src/battles/b/battle.ogs", 2, "no fighter characters::nobody");
    try expectError(r, "src/game.ogs", 2, "no level nowhere");
}

test "build check 5: assets resolve in src/assets or the game (a sigil's, a level's background)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try testBuild(arena.allocator(), &tmp, &.{
        .{ "src/game.ogs", "fn m() {\n    return ~a\"models/none.msh\";\n}\nfn n() {\n    return ~a\"sprites/mine.spr\";\n}\n" },
        .{ "src/assets/sprites/mine.spr", "spr" },
        .{ "src/assets/levels/b/background.jpg", "" },
    }, null);
    try expectError(r, "src/game.ogs", 2, "no asset models/none.msh");
    try expectError(r, "src/battles/b/battle.ogs", 1, "no levels/b/background.jpg");
    for (r.problems) |p| try testing.expect(std.mem.indexOf(u8, p.message, "mine.spr") == null);
    // A look's model and the animations its idles and slots name.
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    const ani = try anim.writeAni(arena.allocator(), &.{ .{ .name = "idle1", .first = 0, .last = 1, .speed = 1, .sounds = &.{} }, .{ .name = "hit", .first = 0, .last = 1, .speed = 1, .sounds = &.{} } });
    const r2 = try testBuild(arena.allocator(), &tmp2, &.{
        .{ "src/looks/kid.ogs", "module looks {\n    look kid {\n        mesh = \"kid\";\n        idles = [Idle(anim = \"idle1\", weight = 100)];\n        slots = [Slot(name = \"hit\", anim = \"HIT\"), Slot(name = \"death\", anim = \"die\")];\n    }\n    look nobody {\n        mesh = \"nobody\";\n    }\n}\n" },
        .{ "src/assets/models/kid.ani", ani },
    }, null);
    // A missing animation is a warning: Classic registers it too.
    try testing.expect(for (r2.problems) |p| {
        if (p.warning and p.line == 5 and std.mem.eql(u8, p.message, "look kid: no animation die in models/kid.ani")) break true;
    } else false);
    try expectError(r2, "src/looks/kid.ogs", 7, "look nobody: no models/nobody.ani");
    try testing.expectEqual(1, r2.errors());
}

test "build check 6: events by the engine's table (parameters)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try expectError(try testBuild(arena.allocator(), &tmp, &.{.{ "src/battles/b/logic.ogs", "module battles::b {\n    component Logic for battle {\n        fn OnTurnStart(side) {\n        }\n    }\n}\n" }}, null), "src/battles/b/logic.ogs", 3, "OnTurnStart takes 2 parameters");
}

test "build: a single-record row missing is an error naming it; a start that is no block" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try testBuild(arena.allocator(), &tmp, &.{.{ "src/rules/shell.ogs", "Campaign();\nWindows();\nMainMenu();\nUiSounds();\nExeAnims();\nHoldPoints();\n" }}, .{ .location = .{ .level = "nowhere" } });
    try expectError(r, "src/game.ogs", 0, "no game music");
    try expectError(r, "--start", 0, "no level or battle nowhere");
    try testing.expectEqualStrings("capt_start1", (try Start.parse("location:01_port@capt_start1")).location.area);
    try testing.expectError(error.BadStart, Start.parse("location:@x"));
    var tb: [64]u8 = undefined;
    for ([_][]const u8{ "location:01_port", "location:01_port@capt_start1", "battle:b", "test-room:characters::kid", "test-room:characters::kid@b" }) |t|
        try testing.expectEqualStrings(t, try (try Start.parse(t)).text(&tb));
    try testing.expectEqualStrings("b", (try Start.parse("test-room:characters::kid@b")).test_room.battle);
}

test "build: the test room is the battle with one fighter of the character, in play.ogp only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try testBuild(a, &tmp, &.{.{ "src/characters/boss.ogs", "module characters {\n    fighter boss {\n        hp = 99;\n    }\n}\n" }}, .{ .test_room = .{ .character = "characters::boss" } });
    try testing.expectEqual(0, r.errors());
    try testing.expectEqualStrings("dist/play.ogp", r.package);
    try testing.expectEqualStrings("b", r.level);
    var pkg = try package.Package.open(io, a, tmp.dir, "dist/play.ogp");
    defer pkg.close(io);
    try testing.expectEqualStrings("battle b {\n    grid_columns = 4;\n    fighter f: characters::boss {\n    }\n}\n", try pkg.read(io, a, pkg.find("src/battles/b/battle.ogs", false).?));
    // src/ is untouched.
    try testing.expectEqualStrings(base_files[2][1], try tmp.dir.readFileAlloc(io, "src/battles/b/battle.ogs", a, .unlimited));
    var tmp2 = testing.tmpDir(.{});
    defer tmp2.cleanup();
    try expectError(try testBuild(a, &tmp2, &.{}, .{ .test_room = .{ .character = "characters::nobody" } }), "src/battles/b/battle.ogs", 3, "no fighter characters::nobody");
}

test "build: the test kit — a bare room with the ticked heroes on the heroes' tiles; a battle: the kit's things added" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const more = [_][2][]const u8{
        .{ "src/game.ogs", "game g {\n    party = [characters::su, characters::ov];\n}\n" },
        .{ "src/characters/heroes.ogs", "module characters {\n    hero su {\n    }\n    hero ov {\n    }\n}\n" },
        .{ "src/weapons/pistol.ogs", "module weapons {\n    weapon pistol {\n    }\n}\n" },
        .{ "src/assets/levels/r/background.jpg", "jpeg" },
        .{ "src/battles/r/battle.ogs", "battle r {\n    placement = [Place(who = @su, tile = [1, 1]), Place(who = @ov, tile = [2, 1]), Place(who = @f, tile = [3, 3])];\n    dialog = \"r\";\n    fighter f: characters::kid {\n    }\n    hero own: characters::su {\n    }\n    fn OnShown() {\n        return 1;\n    }\n}\n" },
    };
    try testProject(io, tmp.dir, &more);
    const kit: Kit = .{ .blocks = "weapon og_tk_1: weapons::pistol {\n    owner = \"ov\";\n    place = hand;\n}\n", .heroes = &.{ "characters::su", "characters::ov" }, .party = &.{"characters::ov"} };
    const r = try build(io, a, tmp.dir, .{ .engine = "0.1", .start = .{ .test_room = .{ .character = "characters::kid", .battle = "r" } }, .kit = kit });
    try testing.expectEqual(0, r.errors());
    try testing.expectEqualStrings("dist/play.ogp", r.package);
    var pkg = try package.Package.open(io, a, tmp.dir, "dist/play.ogp");
    const room = try pkg.read(io, a, pkg.find("src/battles/r/battle.ogs", false).?);
    const game = try pkg.read(io, a, pkg.find("src/game.ogs", false).?);
    pkg.close(io);
    // No code, dialogue nor own hero; Ovitz on the first hero tile; the kit's pistol his.
    for ([_][]const u8{ "OnShown", "dialog", "hero own", "@su" }) |gone| try testing.expect(std.mem.indexOf(u8, room, gone) == null);
    try testing.expect(std.mem.indexOf(u8, room, "Place(who = @ov, tile = [1, 1])") != null);
    try testing.expect(std.mem.indexOf(u8, room, "Place(who = @f, tile = [3, 3])") != null);
    try testing.expect(std.mem.indexOf(u8, room, "weapon og_tk_1: weapons::pistol") != null);
    try testing.expect(std.mem.indexOf(u8, game, "test_kit = [characters::su, characters::ov]") != null);
    try testing.expect(std.mem.indexOf(u8, game, "party = [characters::ov]") != null);
    try testing.expect(std.mem.indexOf(u8, game, "test_room = 1") != null);
    // A battle played: its own, the kit's things added; the party the game's.
    const r2 = try build(io, a, tmp.dir, .{ .engine = "0.1", .start = .{ .location = .{ .level = "r" } }, .kit = kit });
    try testing.expectEqual(0, r2.errors());
    try testing.expectEqualStrings("dist/play.ogp", r2.package);
    pkg = try package.Package.open(io, a, tmp.dir, "dist/play.ogp");
    defer pkg.close(io);
    const b2 = try pkg.read(io, a, pkg.find("src/battles/r/battle.ogs", false).?);
    try testing.expect(std.mem.indexOf(u8, b2, "OnShown") != null and std.mem.indexOf(u8, b2, "og_tk_1") != null);
    const g2 = try pkg.read(io, a, pkg.find("src/game.ogs", false).?);
    try testing.expect(std.mem.indexOf(u8, g2, "party = [characters::su, characters::ov]") != null);
    // Only the room frees its heroes: a story battle keeps its locks.
    try testing.expect(std.mem.indexOf(u8, g2, "test_room") == null);
}

test "build: the reader gives the same model from src/ and from the package" {
    // The script faults (and missing rows) this test makes on purpose log warnings: not
    // shown, as `zig build test` prints a test binary's stderr under "failed command".
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try testBuild(a, &tmp, &.{.{ "src/game.ogs", "game g {\n    party = [characters::kid];\n}\n" }}, null);
    try testing.expectEqual(0, r.errors());
    defer {
        reader.close();
        @import("../../rules.zig").reset();
    }
    var d1 = try reader.open(io, tmp.dir);
    d1.close(io);
    const from_src = try reader.modelText(a);
    var pb: [1024]u8 = undefined;
    const path = try std.fmt.allocPrint(a, "{s}/dist/t.ogp", .{pb[0..try tmp.dir.realPath(io, &pb)]});
    var d2 = try reader.openPackage(io, tmp.dir, path);
    d2.close(io);
    try testing.expectEqualStrings(from_src, try reader.modelText(a));
    try testing.expect(std.mem.indexOf(u8, from_src, "== characters/kid.ogs\n") != null);
    // A single-record row missing: the reader refuses the project, it does not fall over.
    try put(io, tmp.dir, "src/rules/shell.ogs", "Windows();\n");
    try testing.expectError(error.MissingRow, reader.open(io, tmp.dir));
}

test {
    _ = scenecheck;
}

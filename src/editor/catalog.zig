//! Game objects edited outside levels: enemy classes (`classes\ft_*.ss`), item
//! classes (`cw_*` weapons, `ca_*` ammo, `ci_*` items) and enemy attacks (`wp_*.ss`, `.s`) of
//! common/other.dat, and the heroes (`.hro` of any archive) — the core's records as
//! composition lists them (loaders/classic/entities.zig), their names the records' (string.tab by
//! `classic_id`), with what only the editor knows (archive entry, copies, allies, weapons, riders).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const archive = og.formats.archive;
const model = @import("model.zig");
const store_mod = @import("store.zig");
const common_archive = store_mod.common_archive;
const entities = og.loaders.classic.entities;

/// `attack`: an enemy's weapon class (`wp_*.ss`, what a battle's `.wpn` includes).
pub const Kind = entities.Kind;

pub const Entry = struct {
    kind: Kind,
    /// Archive path under `dat` (common_archive or owned).
    archive: []const u8,
    entry: []const u8,
    /// Class without prefix and extension (`garcia`, `stilleto`), or the hero file name;
    /// an attack keeps its `wp_` (`wp_incubus`: enemy classes have the same names).
    id: []const u8,
    /// Its record's name, UTF-8 ("" — unknown), and its string.tab number.
    title: []const u8,
    name_id: ?i32 = null,
    /// Inventory icon (`spriteFile`) as in the archive.
    icon: []const u8 = "",
    /// Hero never joining the party: `avoidEnumerate` 1 and no game script makes it a
    /// hero (SETHERO/HERO_EnableEnumerate) — the barge singer, the monitors, Lamare.
    ally: bool = false,
    /// A class made in the editor: the id of the game class it copies.
    base: ?[]const u8 = null,
    /// Enemy class: weapon classes (`wp_*.ss`) its fighters in the battles hold.
    weapons: std.ArrayList([]const u8) = .empty,
    /// Enemy class: fighters riding its fighters in the battles.
    riders: std.ArrayList(Rider) = .empty,
    /// An OpenGorky project's block (archive store.og_src): its path, the class its objects
    /// are of and its rows name (`characters::grandma`, rules.who).
    class: []const u8 = "",
    /// OpenGorky: its file's block is a `fighter` (a hero by the party, or the enemy beside
    /// a hero block of its class).
    fighter_block: bool = false,
};

/// LinkActor("point", actor) in a level fighter's script (01cy_smokerider.ftr's
/// post_init; builtins/actors.zig): the parent mesh's link point and the rider's `act_*.ss`.
pub const Rider = struct { point: []const u8, act: []const u8 };

pub const Scene = struct { name: []const u8, uses: u32 = 0 };
const ScriptFile = struct { archive: []const u8, entry: []const u8, level: []const u8 };

/// Script extensions of level archives (objects with code): the one list (the code
/// checks, the level's scripts).
pub const script_exts = [_][]const u8{ ".lev", ".are", ".itm", ".ftr", ".hro", ".obs", ".obs_i", ".wpn" };

/// First line of a class made in the editor; names the class it copies.
pub const copy_mark = "// opengorky-editor: copy of ";

const exit_ids = @import("trigger.zig").exit_labels;

/// The last Catalog.gen given.
var gens: u64 = 0;

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Enemy visuals (`act_*.ss`), item icons (`icons\*.spr`), item models (meshFile values).
    acts: std.ArrayList([]const u8) = .empty,
    icons: std.ArrayList([]const u8) = .empty,
    meshes: std.ArrayList([]const u8) = .empty,
    /// The edition's texts are Windows-1251 (Russian "Горький-18"), else ASCII.
    cyrillic: bool = false,
    /// The game's texts of the exit hints (trigger.exit_labels), in its language.
    exit_labels: [exit_ids.len][]const u8 = @splat(""),
    /// Cutscenes (`scriptlets\<name>.scr` of common/other.dat) and how many level
    /// script calls start each.
    scenes: std.ArrayList(Scene) = .empty,
    /// Level scripts starting scenes (where turning one off goes).
    scene_files: std.ArrayList(ScriptFile) = .empty,
    /// Every function and scene command the game's scripts call, with a call as an
    /// example (completion in the code editor); sorted by name.
    calls: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// Objects the game's scripts make party heroes (`SETHERO("x",1)`,
    /// `HERO_EnableEnumerate("x",1)`): McFadden, Slavsky, BT, Medusa, Hutchens.
    joins: std.ArrayList([]const u8) = .empty,
    /// Entries read from the game (the ones after it are made in the editor, addCopy).
    built: usize = 0,
    /// Another value for every catalog built and every entry added (unique across the
    /// run, unlike the entries' address): caches over the catalog key on it.
    gen: u64 = 0,

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
    }

    pub fn build(io: Io, gpa: Allocator, dat: Io.Dir, level_names: []const []const u8) !Catalog {
        gens += 1;
        var self: Catalog = .{ .arena = .init(gpa), .gen = gens };
        errdefer self.deinit();
        const a = self.arena.allocator();

        // The core's texts and records (composition), the entities named from them.
        og.loaders.loadTexts(io, dat);
        const cyrillic = og.core.entity.texts.language == 5;
        self.cyrillic = cyrillic;
        for (exit_ids, &self.exit_labels) |id, *t| t.* = try title(a, og.core.entity.texts.get(id), cyrillic);
        const list = try entities.scan(io, a, dat, level_names);
        try entities.fill(list);

        {
            var ar = try archive.Archive.open(io, gpa, dat, common_archive);
            defer ar.close(io, gpa);
            for (ar.entries) |*e| {
                if (!isSceneEntry(e.name)) continue;
                try self.scenes.append(a, .{ .name = try a.dupe(u8, e.name["scriptlets\\".len .. e.name.len - 4]) });
                const text = try ar.readAlloc(io, a, e);
                try self.noteCalls(a, text);
                try self.noteJoins(a, text);
            }
            for (ar.entries) |*e| {
                const base = classBase(e.name) orelse continue;
                if (entities.classify(base) == null and entities.prefixed(base, "act_", ".ss")) try self.acts.append(a, try a.dupe(u8, base));
            }
        }
        for (list) |x| {
            if (x.kind == .hero) continue;
            try self.noteCalls(a, x.text);
            if (x.kind != .enemy) if (model.getStr(x.text, "mesh")) |m| if (m.len > 0) try addUnique(a, &self.meshes, m);
            try self.entries.append(a, .{
                .kind = x.kind,
                .archive = x.archive,
                .entry = x.entry,
                .id = x.id,
                .title = if (x.name_id != null) try title(a, recordName(x), cyrillic) else "",
                .name_id = x.name_id,
                .icon = if (x.kind == .enemy) "" else try a.dupe(u8, model.getStr(x.text, "icon") orelse ""),
                .base = copyBase(x.text),
            });
        }
        if (archive.Archive.open(io, gpa, dat, "common/sprite.dat")) |ar_| {
            var ar = ar_;
            defer ar.close(io, gpa);
            for (ar.entries) |e| {
                if (!isIcon(e.name)) continue;
                try self.icons.append(a, try a.dupe(u8, e.name["icons\\".len .. e.name.len - 4]));
            }
        } else |_| {}

        // Heroes (the starting three of common gamestart\ and those joining in levels, from
        // the list) and the levels' scenes and fighters' weapons.
        var common = try archive.Archive.open(io, gpa, dat, common_archive);
        defer common.close(io, gpa);
        const classes: entities.Classes = .{ .io = io, .a = a, .ar = common };
        for (list) |x| if (x.kind == .hero) try self.entries.append(a, .{
            .kind = .hero,
            .archive = x.archive,
            .entry = x.entry,
            .id = x.id,
            .title = if (x.name_id != null) try title(a, recordName(x), cyrillic) else "",
            .name_id = x.name_id,
            .ally = model.inherited(classes, x.text, "outside_party", 4) == 1,
            .base = copyBase(x.text),
        });
        for (common.entries) |*e| if (std.ascii.endsWithIgnoreCase(e.name, ".ftr")) try self.noteWeapons(io, a, common, e);
        for (level_names) |n| {
            const p = try std.fmt.allocPrint(a, "{s}/other.dat", .{n});
            var ar = archive.Archive.open(io, gpa, dat, p) catch continue;
            defer ar.close(io, gpa);
            for (ar.entries) |*e| {
                try self.noteScenes(io, a, ar, e, p);
                if (std.ascii.endsWithIgnoreCase(e.name, ".ftr")) try self.noteWeapons(io, a, ar, e);
            }
        }
        for (self.entries.items) |*e| if (e.ally) for (self.joins.items) |j| {
            if (std.ascii.eqlIgnoreCase(j, e.id)) e.ally = false;
        };
        const lt = struct {
            fn entry(_: void, x: Entry, y: Entry) bool {
                if (x.kind != y.kind) return @backingInt(x.kind) < @backingInt(y.kind);
                return std.ascii.lessThanIgnoreCase(x.id, y.id);
            }
            fn str(_: void, x: []const u8, y: []const u8) bool {
                return std.ascii.lessThanIgnoreCase(x, y);
            }
        };
        std.mem.sort(Entry, self.entries.items, {}, lt.entry);
        for (self.entries.items) |*e| std.mem.sort([]const u8, e.weapons.items, {}, lt.str);
        std.mem.sort([]const u8, self.acts.items, {}, lt.str);
        std.mem.sort([]const u8, self.icons.items, {}, lt.str);
        std.mem.sort([]const u8, self.meshes.items, {}, lt.str);
        self.calls.sort(struct {
            keys: [][]const u8,
            pub fn lessThan(ctx: @This(), x: usize, y: usize) bool {
                return std.ascii.lessThanIgnoreCase(ctx.keys[x], ctx.keys[y]);
            }
        }{ .keys = self.calls.keys() });
        std.mem.sort(Scene, self.scenes.items, {}, struct {
            fn f(_: void, x: Scene, y: Scene) bool {
                return std.ascii.lessThanIgnoreCase(x.name, y.name);
            }
        }.f);
        self.built = self.entries.items.len;
        return self;
    }

    /// Records the functions `text` calls, the first call of each as its example.
    fn noteCalls(self: *Catalog, a: Allocator, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (std.mem.startsWith(u8, line, "//")) continue;
            var i: usize = 0;
            while (i < line.len) {
                if (line[i] == '"') {
                    i = if (std.mem.indexOfScalarPos(u8, line, i + 1, '"')) |e| e + 1 else line.len;
                    continue;
                }
                if (!(std.ascii.isAlphabetic(line[i]) or line[i] == '_') or (i > 0 and (std.ascii.isAlphanumeric(line[i - 1]) or line[i - 1] == '_'))) {
                    i += 1;
                    continue;
                }
                const s = i;
                while (i < line.len and (std.ascii.isAlphanumeric(line[i]) or line[i] == '_')) i += 1;
                var k = i;
                while (k < line.len and line[k] == ' ') k += 1;
                const name = line[s..i];
                if (k >= line.len or line[k] != '(' or name.len < 3) continue;
                if (std.mem.eql(u8, name, "function") or std.mem.eql(u8, name, "while")) continue;
                if (self.calls.contains(name)) continue;
                const close = std.mem.indexOfScalarPos(u8, line, k, ')') orelse line.len - 1;
                try self.calls.put(a, try a.dupe(u8, name), try a.dupe(u8, line[s..@min(close + 1, s + 100)]));
            }
        }
    }

    /// Records the objects script `text` makes party heroes (`joins`).
    fn noteJoins(self: *Catalog, a: Allocator, text: []const u8) !void {
        for (try model.joins(a, text)) |n| try addUnique(a, &self.joins, n);
    }

    /// Records level script `e` if it starts scenes, counting the calls per scene.
    fn noteScenes(self: *Catalog, io: Io, a: Allocator, ar: archive.Archive, e: *const archive.Entry, path: []const u8) !void {
        for (script_exts) |x| {
            if (std.ascii.endsWithIgnoreCase(e.name, x)) break;
        } else return;
        const text = try ar.readAlloc(io, a, e);
        try self.noteCalls(a, text);
        try self.noteJoins(a, text);
        if (std.mem.indexOf(u8, text, "Scriptlet") == null) return;
        try self.scene_files.append(a, .{ .archive = path, .entry = try a.dupe(u8, e.name), .level = path[0 .. path.len - "/other.dat".len] });
        for (self.scenes.items) |*sc| {
            var q: [96]u8 = undefined;
            const needle = std.fmt.bufPrint(&q, "\"{s}\"", .{sc.name}) catch continue;
            var pos: usize = 0;
            while (std.ascii.findIgnoreCasePos(text, pos, needle)) |i| : (pos = i + 1) sc.uses += 1;
        }
    }

    /// Records the weapon classes of fighter `e` (its `.wpn` with Owner) for its class.
    fn noteWeapons(self: *Catalog, io: Io, a: Allocator, ar: archive.Archive, e: *const archive.Entry) !void {
        const text = try ar.readAlloc(io, a, e);
        const class = self.classOf(text) orelse return;
        try noteRiders(io, a, ar, text, class);
        var qb: [128]u8 = undefined;
        const q = std.fmt.bufPrint(&qb, "\"{s}\"", .{e.name[0 .. e.name.len - 4]}) catch return;
        for (ar.entries) |*w| {
            if (!std.ascii.endsWithIgnoreCase(w.name, ".wpn")) continue;
            const wt = ar.readAlloc(io, a, w) catch continue;
            if (std.ascii.findIgnoreCase(wt, q) == null) continue;
            const wp = std.ascii.findIgnoreCase(wt, "#include wp_") orelse continue;
            const ws = wp + "#include ".len;
            var we = ws;
            while (we < wt.len and !std.ascii.isWhitespace(wt[we])) we += 1;
            try addUnique(a, &class.weapons, wt[ws..we]);
        }
    }

    /// The enemy class fighter script `text` includes (`#include ft_<id>.ss`).
    pub fn classOf(self: *Catalog, text: []const u8) ?*Entry {
        const p = std.ascii.findIgnoreCase(text, "#include ft_") orelse return null;
        const s = p + "#include ft_".len;
        const end = std.ascii.findIgnoreCasePos(text, s, ".ss") orelse return null;
        for (self.entries.items) |*x| if (x.kind == .enemy and std.ascii.eqlIgnoreCase(x.id, text[s..end])) return x;
        return null;
    }

    /// Records the LinkActor riders of fighter script `text` (the rider is the
    /// archive's `<actor>.act`, its look the `act_*.ss` it includes) for its class.
    fn noteRiders(io: Io, a: Allocator, ar: archive.Archive, text: []const u8, class: *Entry) !void {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, text, pos, "LinkActor(")) |i| : (pos = i + 1) {
            var it = std.mem.splitScalar(u8, text[i .. std.mem.indexOfScalarPos(u8, text, i, ')') orelse text.len], '"');
            _ = it.next();
            const point = it.next() orelse continue;
            _ = it.next();
            const actor = it.next() orelse continue;
            for (class.riders.items) |r| {
                if (std.ascii.eqlIgnoreCase(r.point, point)) break;
            } else {
                var nb: [128]u8 = undefined;
                const re = ar.find(std.fmt.bufPrint(&nb, "{s}.act", .{actor}) catch continue) orelse continue;
                const rt = ar.readAlloc(io, a, re) catch continue;
                const ap = std.ascii.findIgnoreCase(rt, "#include act_") orelse continue;
                const as = ap + "#include ".len;
                var ae = as;
                while (ae < rt.len and !std.ascii.isWhitespace(rt[ae])) ae += 1;
                try class.riders.append(a, .{ .point = try a.dupe(u8, point), .act = rt[as..ae] });
            }
        }
    }

    /// Adds an entry made in the editor copying `of`: a class (`classes\<prefix><id><ext>`)
    /// or a hero (`<id>.hro` of level archive `into`, or common's `gamestart\`).
    pub fn addCopy(self: *Catalog, of: Entry, id: []const u8, into: []const u8, name_id: ?i32) !Entry {
        const a = self.arena.allocator();
        const entry = if (of.kind != .hero)
            try std.fmt.allocPrint(a, "classes\\{s}{s}{s}", .{ prefix(of.kind), id, ext(of.kind) })
        else
            try std.fmt.allocPrint(a, "{s}{s}.hro", .{ if (std.mem.eql(u8, into, common_archive)) "gamestart\\" else "", id });
        const e: Entry = .{ .kind = of.kind, .archive = into, .entry = entry, .id = try a.dupe(u8, id), .title = of.title, .name_id = name_id, .icon = of.icon, .base = of.base orelse of.id, .weapons = of.weapons, .riders = of.riders };
        try self.entries.append(a, e);
        gens += 1;
        self.gen = gens;
        return e;
    }

    /// The entry of file `entry` of archive `path` (the entry name any case; the first).
    pub fn byKey(self: *const Catalog, path: []const u8, entry: []const u8) ?usize {
        for (self.entries.items, 0..) |e, i| if (std.mem.eql(u8, e.archive, path) and std.ascii.eqlIgnoreCase(e.entry, entry)) return i;
        return null;
    }

    pub fn has(self: *const Catalog, kind: Kind, id: []const u8) bool {
        for (self.entries.items) |e| if (e.kind == kind and std.ascii.eqlIgnoreCase(e.id, id)) return true;
        return false;
    }
};

/// An icon sprite of sprite.dat (`icons\<name>.spr`).
pub fn isIcon(entry: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(entry, "icons\\") and std.ascii.endsWithIgnoreCase(entry, ".spr");
}

/// A scene file of common.dat (`scriptlets\<name>.scr`); not codecheck.isScene (a
/// code view's title).
pub fn isSceneEntry(entry: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(entry, "scriptlets\\") and std.ascii.endsWithIgnoreCase(entry, ".scr");
}

pub fn prefix(k: Kind) []const u8 {
    return switch (k) {
        .enemy => "ft_",
        .weapon => "cw_",
        .ammo => "ca_",
        .item => "ci_",
        // Attacks are not copied (entries.copyEntry); their id has it.
        .attack, .hero => "",
    };
}

pub fn ext(k: Kind) []const u8 {
    return if (k == .enemy) ".ss" else if (k == .hero) ".hro" else ".s";
}

/// `classes\x` → `x`.
fn classBase(name: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(name, "classes\\")) return null;
    return name["classes\\".len..];
}

fn copyBase(text: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, copy_mark)) return null;
    const rest = text[copy_mark.len..];
    const end = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
    const name = rest[0..end];
    // A hero's mark names its file (`bt.hro`), a class's has its prefix (`ft_garcia.ss`).
    if (std.ascii.endsWithIgnoreCase(name, ".hro")) return name[0 .. name.len - 4];
    const u = std.mem.indexOfScalar(u8, name, '_') orelse return null;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    return if (dot > u) name[u + 1 .. dot] else null;
}

test copyBase {
    try std.testing.expectEqualStrings("garcia", copyBase(copy_mark ++ "ft_garcia.ss\r\n#include act_garcia.ss").?);
    try std.testing.expectEqualStrings("bt", copyBase(copy_mark ++ "bt.hro\r\n#include Fighter.s").?);
    try std.testing.expect(copyBase("#include Fighter.s") == null);
}

fn addUnique(a: Allocator, list: *std.ArrayList([]const u8), s: []const u8) !void {
    for (list.items) |x| if (std.ascii.eqlIgnoreCase(x, s)) return;
    try list.append(a, try a.dupe(u8, s));
}

/// The core record's name of `x`.
fn recordName(x: entities.Entity) ?[]const u8 {
    const e = og.core.entity;
    const n = switch (entities.coreKind(x.kind)) {
        .hero => e.heroOf(x.who).name,
        .enemy => e.enemyOf(x.who).name,
        .weapon => e.weaponOf(x.who).name,
        .item => e.itemOf(x.who).name,
        .other => "",
    };
    return if (n.len > 0) n else null;
}

/// An OpenGorky project's blocks as the catalog's entries:
/// the archetypes of `src/characters/`, `weapons/`, `items/` (a file's main block; a
/// `fighter` a hero when the game's `party` names it), in path order, instead of the
/// installed game's classes; named by their classic_id's text.
pub fn useOg(self: *Catalog, st: *store_mod.Store) void {
    const a = self.arena.allocator();
    self.entries.clearRetainingCapacity();
    gens += 1;
    self.gen = gens;
    defer self.built = self.entries.items.len;
    const og_src = store_mod.og_src;
    const party = if (st.file(og_src, "game.ogs")) |g| st.text(g) else |_| "";
    for (st.listing(a, og_src, null, false)) |path| {
        const dir = path[0 .. std.mem.indexOfScalar(u8, path, '/') orelse continue];
        if (!std.mem.eql(u8, dir, "characters") and !std.mem.eql(u8, dir, "weapons") and !std.mem.eql(u8, dir, "items")) continue;
        const f = st.file(og_src, path) catch continue;
        var diag: og.script.ogs.parser.Diagnostic = .{};
        const u = og.script.ogs.parser.parse(a, a.dupe(u8, st.text(f)) catch continue, path, &diag) catch continue;
        const m, const e = for (u.modules) |*m| {
            if (m.entities.len > 0) break .{ m, &m.entities[0] };
        } else continue;
        const class = if (m.path.len > 0) std.fmt.allocPrint(a, "{s}::{s}", .{ m.path, e.name }) catch continue else e.name;
        const in_party = std.mem.indexOf(u8, party, class) != null;
        // A hero block (`hero sullivan`) is the party's; a location's (`hero bt`) none here.
        const kind: Kind = if (std.mem.eql(u8, e.kind, "fighter") or (std.mem.eql(u8, e.kind, "hero") and in_party))
            (if (in_party) .hero else .enemy)
        else if (std.mem.eql(u8, e.kind, "weapon")) .weapon else if (std.mem.eql(u8, e.kind, "item")) (if (isAmmo(e)) .ammo else .item) else continue;
        var id: ?i32 = null;
        for (e.fields) |x| if (std.mem.eql(u8, x.name, "classic_id") and x.value.kind == .lit and x.value.kind.lit == .int) {
            id = x.value.kind.lit.int;
        };
        // No classic_id (a converted project's): the number the OG reader made it (its path).
        if (id == null) id = og.core.entity.idOf(class);
        const t = if (id) |n| title(a, og.core.entity.texts.get(n), self.cyrillic) catch "" else "";
        // A fighter's weapons: the blocks inside it (`weapon la: weapons::fanglong`), by class.
        // shortcut: not the battles' fighters' own weapons; read them too if a battle arms one otherwise.
        var weapons: std.ArrayList([]const u8) = .empty;
        for (e.children) |ch| if (std.mem.eql(u8, ch.kind, "weapon") and ch.base.len > 0) addUnique(a, &weapons, ch.base) catch {};
        self.entries.append(a, .{ .kind = kind, .archive = og_src, .entry = path, .id = e.name, .title = t, .name_id = id, .class = class, .fighter_block = std.mem.eql(u8, e.kind, "fighter"), .weapons = weapons }) catch {};
    }
    // A fighter with a hero block of its class (Medusa: `fighter medusa` and, in its own
    // file, `hero medusa`) is the enemy; the hero block the party's.
    for (self.entries.items) |*x| if (x.fighter_block and x.kind == .hero) for (self.entries.items) |y| {
        if (y.kind == .hero and !y.fighter_block and std.mem.eql(u8, x.class, y.class)) {
            x.kind = .enemy;
            break;
        }
    };
}

/// An item block of ammo (`type = ammo`, its own; what a weapon's `ammo` names).
fn isAmmo(e: *const og.script.ir.Entity) bool {
    for (e.fields) |x| if (std.mem.eql(u8, x.name, "kind") and x.value.kind == .word) return std.mem.eql(u8, x.value.kind.word, "ammo");
    return false;
}

fn title(a: Allocator, name: ?[]const u8, cyrillic: bool) ![]const u8 {
    const raw = name orelse return "";
    return if (cyrillic) cp1251(a, raw) else a.dupe(u8, std.mem.trim(u8, raw, " \t\r"));
}

/// Windows-1251 → UTF-8 (letters; other high bytes become '?').
fn cp1251(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (std.mem.trim(u8, s, " \t\r")) |ch| {
        const cp: u21 = switch (ch) {
            0...0x7f => ch,
            0xc0...0xff => @as(u21, ch) - 0xc0 + 0x410,
            0xa8 => 0x401,
            0xb8 => 0x451,
            else => '?',
        };
        var buf: [4]u8 = undefined;
        try out.appendSlice(a, buf[0 .. std.unicode.utf8Encode(cp, &buf) catch 1]);
    }
    return out.items;
}

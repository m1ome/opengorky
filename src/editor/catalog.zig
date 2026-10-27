//! Game objects edited outside levels: enemy classes (`classes\ft_*.ss`), item
//! classes (`cw_*` weapons, `ca_*` ammo, `ci_*` items) and enemy attacks (`wp_*.ss`, `.s`) of
//! common/other.dat, and the heroes (`.hro` of any archive). Game names come by
//! `nameID` from string.tab.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const archive = og.formats.archive;
const vars = @import("vars.zig");
const common_archive = @import("store.zig").common_archive;

/// `attack`: an enemy's weapon class (`wp_*.ss`, what a battle's `.wpn` includes).
pub const Kind = enum { enemy, weapon, ammo, item, attack, hero };

pub const Entry = struct {
    kind: Kind,
    /// Archive path under `dat` (common_archive or owned).
    archive: []const u8,
    entry: []const u8,
    /// Class without prefix and extension (`garcia`, `stilleto`), or the hero file name;
    /// an attack keeps its `wp_` (`wp_incubus`: enemy classes have the same names).
    id: []const u8,
    /// Name in the game, UTF-8 ("" — unknown), and its string.tab number.
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
};

/// LinkActor("point", actor) in a level fighter's script (01cy_smokerider.ftr's
/// post_init; builtins/actors.zig): the parent mesh's link point and the rider's `act_*.ss`.
pub const Rider = struct { point: []const u8, act: []const u8 };

pub const Scene = struct { name: []const u8, uses: u32 = 0 };
const ScriptFile = struct { archive: []const u8, entry: []const u8, level: []const u8 };

/// Script extensions of level archives (objects with code).
const script_exts = [_][]const u8{ ".lev", ".are", ".itm", ".ftr", ".hro", ".obs", ".obs_i", ".wpn" };

/// First line of a class made in the editor; names the class it copies.
pub const copy_mark = "// opengorky-editor: copy of ";

const exit_ids = @import("trigger.zig").exit_labels;

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

    pub fn deinit(self: *Catalog) void {
        self.arena.deinit();
    }

    pub fn build(io: Io, gpa: Allocator, dat: Io.Dir, level_names: []const []const u8) !Catalog {
        var self: Catalog = .{ .arena = .init(gpa) };
        errdefer self.deinit();
        const a = self.arena.allocator();

        var strings_bytes: []u8 = &.{};
        var strings: og.formats.strtab.Table = .{};
        defer strings.deinit(gpa);
        if (archive.Archive.open(io, gpa, dat, "common/lang.dat")) |ar_| {
            var ar = ar_;
            defer ar.close(io, gpa);
            if (ar.find("string.tab")) |e| {
                strings_bytes = try ar.readAlloc(io, a, e);
                strings = try og.formats.strtab.parseStrings(gpa, strings_bytes);
            }
        } else |_| {}
        const cyrillic = og.formats.strtab.language(strings) == 5;
        self.cyrillic = cyrillic;
        for (exit_ids, &self.exit_labels) |id, *t| t.* = try title(a, strings, @floatFromInt(id), cyrillic);

        {
            var ar = try archive.Archive.open(io, gpa, dat, common_archive);
            defer ar.close(io, gpa);
            for (ar.entries) |*e| {
                if (!std.ascii.startsWithIgnoreCase(e.name, "scriptlets\\") or !std.ascii.endsWithIgnoreCase(e.name, ".scr")) continue;
                try self.scenes.append(a, .{ .name = try a.dupe(u8, e.name["scriptlets\\".len .. e.name.len - 4]) });
                const text = try ar.readAlloc(io, a, e);
                try self.noteCalls(a, text);
                try self.noteJoins(a, text);
            }
            for (ar.entries) |*e| {
                const base = classBase(e.name) orelse continue;
                const kind, const id = classify(base) orelse {
                    if (prefixed(base, "act_", ".ss")) try self.acts.append(a, try a.dupe(u8, base));
                    continue;
                };
                const text = try ar.readAlloc(io, a, e);
                try self.noteCalls(a, text);
                // An enemy class names itself only after a look change (pages.setAct).
                const name_id = if (kind == .enemy or kind == .attack) vars.inherited(Classes{ .io = io, .a = a, .ar = ar }, text, "nameID", 4) else vars.get(text, "nameID");
                if (kind != .enemy) if (vars.getStr(text, "meshFile")) |m| if (m.len > 0) try addUnique(a, &self.meshes, m);
                try self.entries.append(a, .{
                    .kind = kind,
                    .archive = common_archive,
                    .entry = try a.dupe(u8, e.name),
                    .id = try a.dupe(u8, id),
                    .title = try title(a, strings, name_id, cyrillic),
                    .name_id = if (name_id) |v| @intFromFloat(v) else null,
                    .icon = if (kind == .enemy) "" else try a.dupe(u8, vars.getStr(text, "spriteFile") orelse ""),
                    .base = copyBase(text),
                });
            }
        }
        if (archive.Archive.open(io, gpa, dat, "common/sprite.dat")) |ar_| {
            var ar = ar_;
            defer ar.close(io, gpa);
            for (ar.entries) |e| {
                if (!std.ascii.startsWithIgnoreCase(e.name, "icons\\") or !std.ascii.endsWithIgnoreCase(e.name, ".spr")) continue;
                try self.icons.append(a, try a.dupe(u8, e.name["icons\\".len .. e.name.len - 4]));
            }
        } else |_| {}

        // Heroes: the starting three (common gamestart\) and those joining in levels.
        var common = try archive.Archive.open(io, gpa, dat, common_archive);
        defer common.close(io, gpa);
        const classes: Classes = .{ .io = io, .a = a, .ar = common };
        var paths: std.ArrayList([]const u8) = .empty;
        try paths.append(a, common_archive);
        for (level_names) |n| try paths.append(a, try std.fmt.allocPrint(a, "{s}/other.dat", .{n}));
        for (paths.items) |p| {
            var ar = archive.Archive.open(io, gpa, dat, p) catch continue;
            defer ar.close(io, gpa);
            for (ar.entries) |*e| {
                if (p.ptr != common_archive.ptr) try self.noteScenes(io, a, ar, e, p);
                if (std.ascii.endsWithIgnoreCase(e.name, ".ftr")) try self.noteWeapons(io, a, ar, e);
                if (!std.ascii.endsWithIgnoreCase(e.name, ".hro")) continue;
                const text = try ar.readAlloc(io, a, e);
                const file = e.name[if (std.mem.lastIndexOfScalar(u8, e.name, '\\')) |k| k + 1 else 0..];
                // Battle extras name themselves in their class (medusa.hro → ft_medusa.ss → act_medusa.ss).
                const name_id = vars.inherited(classes, text, "nameID", 4);
                try self.entries.append(a, .{
                    .kind = .hero,
                    .archive = p,
                    .entry = try a.dupe(u8, e.name),
                    .id = try a.dupe(u8, file[0 .. file.len - 4]),
                    .title = try title(a, strings, name_id, cyrillic),
                    .name_id = if (name_id) |v| @intFromFloat(v) else null,
                    .ally = vars.inherited(classes, text, "avoidEnumerate", 4) == 1,
                });
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
        for (try vars.joins(a, text)) |n| try addUnique(a, &self.joins, n);
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

    /// Adds a class made in the editor (`classes\<prefix><id><ext>` copying `base`).
    pub fn addCopy(self: *Catalog, of: Entry, id: []const u8) !Entry {
        const a = self.arena.allocator();
        const entry = try std.fmt.allocPrint(a, "classes\\{s}{s}{s}", .{ prefix(of.kind), id, ext(of.kind) });
        const e: Entry = .{ .kind = of.kind, .archive = of.archive, .entry = entry, .id = try a.dupe(u8, id), .title = of.title, .name_id = of.name_id, .icon = of.icon, .base = of.base orelse of.id, .weapons = of.weapons, .riders = of.riders };
        try self.entries.append(a, e);
        return e;
    }

    pub fn has(self: *const Catalog, kind: Kind, id: []const u8) bool {
        for (self.entries.items) |e| if (e.kind == kind and std.ascii.eqlIgnoreCase(e.id, id)) return true;
        return false;
    }
};

pub fn prefix(k: Kind) []const u8 {
    return switch (k) {
        .enemy => "ft_",
        .weapon => "cw_",
        .ammo => "ca_",
        .item => "ci_",
        // Attacks are not copied (pages.copyEntry); their id has it.
        .attack, .hero => "",
    };
}

pub fn ext(k: Kind) []const u8 {
    return if (k == .enemy) ".ss" else if (k == .hero) ".hro" else ".s";
}

/// Kind and id of class file `base` (`ft_garcia.ss` → enemy `garcia`); null — not an entry.
fn classify(base: []const u8) ?struct { Kind, []const u8 } {
    const kind: Kind = if (prefixed(base, "ft_", ".ss")) .enemy else if (prefixed(base, "cw_", ".s")) .weapon else if (prefixed(base, "ca_", ".s")) .ammo else if (prefixed(base, "ci_", ".s")) .item else if (prefixed(base, "wp_", ".ss") or prefixed(base, "wp_", ".s")) .attack else return null;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.').?;
    return .{ kind, if (kind == .attack) base[0..dot] else base[std.mem.indexOfScalar(u8, base, '_').? + 1 .. dot] };
}

test classify {
    const t = std.testing;
    try t.expectEqual(Kind.attack, classify("wp_incubus.ss").?[0]);
    try t.expectEqualStrings("wp_incubus", classify("wp_incubus.ss").?[1]);
    try t.expectEqualStrings("incubus", classify("ft_incubus.ss").?[1]);
    try t.expectEqualStrings("pistol", classify("cw_pistol.s").?[1]);
    try t.expectEqualStrings("wp_timebomb_explode", classify("wp_timebomb_explode.s").?[1]);
    try t.expect(classify("act_incubus.ss") == null);
    try t.expect(classify("wp_.ss") == null);
    // wp_incubus.ss as the game has it: its name and class, no function around them.
    const text = "  nameID=1070;\r\n  funcID=3; // Take\r\n\r\n    two_handed=2;\r\n\r\n    classType = 1008;\r\n    max_damage = 50;\r\n    type = 6;\r\n";
    try t.expectEqual(1070, vars.get(text, "nameID").?);
    try t.expectEqual(1008, vars.get(text, "classType").?);
}

/// `classes\x` → `x`.
fn classBase(name: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(name, "classes\\")) return null;
    return name["classes\\".len..];
}

fn prefixed(s: []const u8, pre: []const u8, suffix: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(s, pre) and std.ascii.endsWithIgnoreCase(s, suffix) and s.len > pre.len + suffix.len;
}

fn copyBase(text: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, copy_mark)) return null;
    const rest = text[copy_mark.len..];
    const end = std.mem.indexOfAny(u8, rest, "\r\n") orelse rest.len;
    const name = rest[0..end];
    const u = std.mem.indexOfScalar(u8, name, '_') orelse return null;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    return if (dot > u) name[u + 1 .. dot] else null;
}

/// common/other.dat's `classes\\` as `vars.inherited` reads them.
const Classes = struct {
    io: Io,
    a: Allocator,
    ar: archive.Archive,
    pub fn read(self: Classes, name: []const u8) ?[]const u8 {
        var buf: [128]u8 = undefined;
        const e = self.ar.find(std.fmt.bufPrint(&buf, "classes\\{s}", .{name}) catch return null) orelse return null;
        return self.ar.readAlloc(self.io, self.a, e) catch null;
    }
};

fn addUnique(a: Allocator, list: *std.ArrayList([]const u8), s: []const u8) !void {
    for (list.items) |x| if (std.ascii.eqlIgnoreCase(x, s)) return;
    try list.append(a, try a.dupe(u8, s));
}

fn title(a: Allocator, strings: og.formats.strtab.Table, id: ?f32, cyrillic: bool) ![]const u8 {
    const raw = strings.get(@intFromFloat(id orelse return "")) orelse return "";
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

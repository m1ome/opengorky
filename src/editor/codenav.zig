//! The code editor's links: what a word or a string of a script names — a file of the
//! game (a model, a sound, a video, a picture, a script), a hero, a class, a level, a
//! scene, an object of a level (open or not), a classic_id — as Info targets (info.follow opens
//! them), and where a word is used across the game's scripts and rules files.

const std = @import("std");
const baseName = @import("doctab.zig").baseName;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const info = @import("info.zig");
const code = @import("code.zig");
const refs_mod = @import("refs.zig");
const entries = @import("entries.zig");
const tx = @import("text.zig");
const rulesapi = @import("rulesapi.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;

/// A target and how a pick list names it; `.none`: a file the editor has no page for.
pub const Hit = struct { label: []const u8, to: info.Target };

/// A game file: its archive and entry.
pub const File = struct { archive: []const u8, entry: []const u8 };

/// Every archive's entries and the models of the catalog's entries (lower-case mesh
/// name → entry index), read again after a Store or catalog change (Store.rev, Catalog.gen).
var index_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var index_files: []const File = &.{};
var index_meshes: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
var index_key: [2]u64 = .{ std.math.maxInt(u64), 0 };
/// The archives' entries alone, read again only after a write to disk (Store.disk): an
/// edit (Store.rev) does not change them, and reading every archive took a hover's frame.
var archive_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var archive_files: []const File = &.{};
var archive_key: ?u64 = null;

/// The index and the sound bank made now (a project opened), not on the first hover.
pub fn warm(app: *App) void {
    index(app);
    var tmp: std.heap.ArenaAllocator = .init(app.gpa);
    defer tmp.deinit();
    _ = app.player.names(app, tmp.allocator());
}

fn index(app: *App) void {
    const now: [2]u64 = .{ app.store.rev, app.catalog.gen };
    if (std.mem.eql(u64, &now, &index_key)) return;
    index_key = now;
    _ = index_arena.reset(.retain_capacity);
    index_meshes = .empty;
    const a = index_arena.allocator();
    if (archive_key != app.store.disk) {
        archive_key = app.store.disk;
        _ = archive_arena.reset(.retain_capacity);
        const aa = archive_arena.allocator();
        var list: std.ArrayList(File) = .empty;
        if (og.formats.archive.listArchives(app.io, app.gpa, app.dat)) |paths| {
            defer og.formats.archive.freeList(app.gpa, paths);
            for (paths) |p| {
                var ar = og.formats.archive.Archive.open(app.io, app.gpa, app.dat, p) catch continue;
                defer ar.close(app.io, app.gpa);
                const pa = aa.dupe(u8, p) catch continue;
                for (ar.entries) |e| list.append(aa, .{ .archive = pa, .entry = aa.dupe(u8, e.name) catch continue }) catch {};
            }
        } else |_| {}
        archive_files = list.items;
    }
    var out: std.ArrayList(File) = .empty;
    out.appendSlice(a, archive_files) catch {};
    for (app.store.files.items, 0..) |f, i| if (!f.on_disk and !app.store.gone(i)) out.append(a, .{ .archive = f.archive, .entry = f.entry }) catch {};
    index_files = out.items;
    for (app.catalog.entries.items, 0..) |e, i| {
        const f = entries.fileOf(app, e) orelse continue;
        const m = entries.meshOf(app, e, app.store.text(f)) orelse continue;
        if (m.len == 0) continue;
        const key = std.ascii.allocLowerString(a, m) catch continue;
        const gop = index_meshes.getOrPut(a, key) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.append(a, i) catch {};
    }
}

/// Every script and rules file of the game, as edited (the code probe).
pub fn texts(app: *App, a: Allocator) []const File {
    index(app);
    var out: std.ArrayList(File) = .empty;
    if (app.ogLayout()) for (app.store.listing(a, @import("store.zig").og_src, null, true)) |p| {
        if (std.ascii.endsWithIgnoreCase(p, ".ogs")) out.append(a, .{ .archive = @import("store.zig").og_src, .entry = p }) catch {};
    };
    for (index_files) |f| if (text(f.entry)) out.append(a, f) catch {};
    return out.items;
}

/// Base names of the game's files under folder `dir` (`classes\\`, "" for any) ending in
/// `suffix`, each once (completion).
pub fn fileNames(app: *App, a: Allocator, dir: []const u8, suffix: []const u8) []const []const u8 {
    index(app);
    var out: std.ArrayList([]const u8) = .empty;
    for (index_files) |f| {
        if (!std.ascii.startsWithIgnoreCase(f.entry, dir) or !std.ascii.endsWithIgnoreCase(f.entry, suffix)) continue;
        const n = baseName(f.entry);
        for (out.items) |x| {
            if (std.ascii.eqlIgnoreCase(x, n)) break;
        } else out.append(a, n) catch {};
    }
    return out.items;
}

/// Whether some archive has a file named `name` (its base name, case aside).
pub fn fileExists(app: *App, name: []const u8) bool {
    index(app);
    for (index_files) |f| if (std.ascii.eqlIgnoreCase(baseName(f.entry), baseName(name))) return true;
    return false;
}

fn stem(name: []const u8) []const u8 {
    return name[0 .. std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len];
}

fn ext(name: []const u8) []const u8 {
    const k = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    return name[k + 1 ..];
}

const Out = struct {
    a: Allocator,
    list: std.ArrayList(Hit) = .empty,

    fn add(o: *Out, to: info.Target, comptime fmt: []const u8, args: anytype) void {
        // Each target once (a class found by its file and by its id).
        for (o.list.items) |h| if (std.meta.eql(h.to, to)) return;
        o.list.append(o.a, .{ .label = std.fmt.allocPrint(o.a, fmt, args) catch return, .to = to }) catch {};
    }

    fn entry(o: *Out, app: *App, i: usize) void {
        const e = app.catalog.entries.items[i];
        o.add(.{ .entry = i }, "{s} · {s}", .{ e.id, if (e.title.len > 0) e.title else e.entry });
    }
};

/// Everything `tok` (a string's text or a word) names, as the pages open them. `deep`
/// (a go-to): a level not read yet is read for its objects (a world made: seconds in a
/// debug build for every level); else (a hover tip, each frame) only the levels open or
/// read already.
pub fn resolve(app: *App, a: Allocator, tok: []const u8, deep: bool) []const Hit {
    var o: Out = .{ .a = a };
    if (tok.len == 0 or tok.len > 128) return &.{};
    index(app);
    const all = app.catalog.entries.items;
    // A classic_id: the one entry that has it (several: ambiguous, left alone).
    if (std.fmt.parseInt(i32, tok, 10)) |n| {
        var found: ?usize = null;
        for (all, 0..) |e, i| if (e.name_id == n) {
            if (found != null) return &.{};
            found = i;
        };
        if (found) |i| o.entry(app, i);
        return o.list.items;
    } else |_| {}
    const x = ext(tok);
    const name = baseName(tok);
    // Sounds and videos come from their own banks; a sound is also named without `.wav`.
    for (app.player.names(app, a)) |s| if (std.ascii.eqlIgnoreCase(s, name) or (x.len == 0 and std.ascii.eqlIgnoreCase(stem(s), name))) o.add(.{ .doc = .{ .tab = .sounds, .name = s } }, "{s}", .{s});
    // The scripts name videos `.avi`, the game has them as `.asf` (the engine plays either).
    const video = std.ascii.eqlIgnoreCase(x, "avi") or std.ascii.eqlIgnoreCase(x, "asf");
    for (@import("videopage.zig").names(app)) |s| if (std.ascii.eqlIgnoreCase(s, name) or (video and std.ascii.eqlIgnoreCase(stem(s), stem(name)))) o.add(.{ .doc = .{ .tab = .videos, .name = s } }, "{s}", .{s});
    for (@import("musicpage.zig").names(app)) |s| if (std.ascii.eqlIgnoreCase(s, name)) o.add(.{ .doc = .{ .tab = .music, .name = s } }, "{s}", .{s});
    // Classes and heroes: by id (`riffle`), by file (`cw_riffle.s`, `cw_riffle`), by the
    // name the scripts use (`Sullivan`).
    for (all, 0..) |e, i| {
        if (std.ascii.eqlIgnoreCase(e.id, name) or std.ascii.eqlIgnoreCase(baseName(e.entry), name) or std.ascii.eqlIgnoreCase(stem(baseName(e.entry)), name) or (e.kind == .hero and std.ascii.eqlIgnoreCase(e.title, name))) o.entry(app, i);
    }
    // Models (`pila`, `pila.msh`, its `.ani`, `.bfr`, `.3df`): the entries wearing them.
    const model = x.len == 0 or std.ascii.eqlIgnoreCase(x, "msh") or std.ascii.eqlIgnoreCase(x, "ani") or std.ascii.eqlIgnoreCase(x, "bfr") or std.ascii.eqlIgnoreCase(x, "3df");
    if (model) {
        var lb: [128]u8 = undefined;
        if (index_meshes.get(std.ascii.lowerString(&lb, stem(name)))) |list| for (list.items) |i| o.entry(app, i);
    }
    for (app.levels) |lv| if (std.ascii.eqlIgnoreCase(lv.name, name)) o.add(.{ .level = .{ .name = lv.name } }, "{s}", .{lv.name});
    if (app.ogLayout()) traitHits(a, &o, tok);
    for (app.catalog.scenes.items) |sc| if (std.ascii.eqlIgnoreCase(sc.name, name) or (std.ascii.eqlIgnoreCase(x, "scr") and std.ascii.eqlIgnoreCase(sc.name, stem(name)))) o.add(.{ .scene = sc.name }, "{s}", .{sc.name});
    // An object of the level the code belongs to (else of the open one), open or not;
    // nothing else named so: of any level having one.
    const own: ?usize = if (app.code) |v| (if (info.levelOf(app.store.files.items[v.file].archive)) |ln| app.levelIndex(ln) else app.current) else app.current;
    if (own) |li| objectIn(app, a, &o, li, name, deep);
    if (o.list.items.len == 0) for (0..app.levels.len) |li| if (li != own) objectIn(app, a, &o, li, name, deep);
    // A file of an archive, if nothing above is it.
    if (x.len > 0 and o.list.items.len == 0) for (index_files) |f| {
        if (!std.ascii.eqlIgnoreCase(baseName(f.entry), name) and !std.ascii.eqlIgnoreCase(f.entry, tok)) continue;
        if (std.ascii.eqlIgnoreCase(x, "spr") or std.ascii.eqlIgnoreCase(x, "spz")) {
            o.add(.{ .doc = .{ .tab = .sprites, .name = @import("doctab.zig").join(a, f.archive, f.entry) catch continue } }, "{s} · {s}", .{ f.archive, f.entry });
        } else if (std.ascii.eqlIgnoreCase(x, "dlg")) {
            o.add(.{ .doc = .{ .tab = .scenes, .name = baseName(f.entry) } }, "{s} · {s}", .{ f.archive, f.entry });
        } else if (text(f.entry)) {
            o.add(.{ .code = .{ .archive = f.archive, .entry = f.entry } }, "{s} · {s}", .{ f.archive, f.entry });
        } else o.add(.none, "{s} · {s}", .{ f.archive, f.entry });
    };
    return o.list.items;
}

/// OpenGorky code: a trait or a component to its page (traitpage.zig);
/// a method (`absorb`, `OnHit`, `super.absorb`, `Shielded::absorb`) to each trait that
/// declares it — a built-in one's (`foundation::Fighter`, read-only) page shows its text
/// in engine.ogs.
fn traitHits(a: Allocator, o: *Out, tok: []const u8) void {
    const ti = @import("traitinfo.zig");
    const traits = @import("opengorky").script.traits;
    const p = ti.load(a);
    const fnd = ti.foundation;
    if (p.trait(tok) != null) o.add(.{ .doc = .{ .tab = .traits, .name = tok } }, "trait {s}", .{tok});
    if (traits.find(ti.engineName(tok) orelse tok)) |t| o.add(.{ .doc = .{ .tab = .traits, .name = std.fmt.allocPrint(a, fnd ++ "::{s}", .{t.name}) catch t.name } }, "trait " ++ fnd ++ "::{s}", .{t.name});
    if (p.comp(tok) != null or ti.native(tok) != null) o.add(.{ .doc = .{ .tab = .components, .name = tok } }, "component {s}", .{tok});
    // `T::f`: only T's (a trait path or its last part); `f`: any trait's.
    const cut = std.mem.lastIndexOf(u8, tok, "::");
    const m = if (cut) |k| tok[k + 2 ..] else tok;
    const of = if (cut) |k| ti.engineName(tok[0..k]) orelse tok[0..k] else "";
    if (m.len == 0) return;
    for (p.traits) |t| {
        if (of.len > 0 and !std.mem.eql(u8, t.path, of) and !std.mem.endsWith(u8, t.path, std.fmt.allocPrint(a, "::{s}", .{of}) catch continue)) continue;
        for (t.it.methods) |f| if (std.mem.eql(u8, f.f.name, m)) o.add(.{ .doc = .{ .tab = .traits, .name = t.path } }, "{s}.{s}", .{ t.path, m });
    }
    for (traits.all()) |*t| {
        if (of.len > 0 and !std.mem.eql(u8, t.name, of)) continue;
        if (t.own(m) != null) o.add(.{ .doc = .{ .tab = .traits, .name = std.fmt.allocPrint(a, fnd ++ "::{s}", .{t.name}) catch t.name } }, fnd ++ "::{s}.{s} · engine.ogs", .{ t.name, m });
    }
}

/// Level `li`'s object `name` into `o` (labelled "level · object").
fn objectIn(app: *App, a: Allocator, o: *Out, li: usize, name: []const u8, load: bool) void {
    const lv = app.levels[li].name;
    for (levelObjects(app, a, li, load)) |n| if (std.ascii.eqlIgnoreCase(n, name)) return o.add(.{ .level = .{ .name = lv, .obj = n } }, "{s} · {s}", .{ lv, n });
}

/// Each level's object names, read as opening it reads them (without its picture, no
/// tab), kept until the Store or the catalog changes (Store.rev, Catalog.gen).
var objs_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var objs: std.AutoHashMapUnmanaged(usize, []const []const u8) = .empty;
var objs_key: [2]u64 = .{ std.math.maxInt(u64), 0 };

fn levelObjects(app: *App, a: Allocator, li: usize, load: bool) []const []const u8 {
    // Open or parked: its objects as edited now.
    const live: ?*const @import("level.zig").Doc = if (app.current == li) app.doc else for (app.parked.items) |pk| {
        if (pk.current == li) break pk.doc;
    } else null;
    if (live) |d| return namesOf(a, d);
    const key: [2]u64 = .{ app.store.rev, app.catalog.gen };
    if (!std.mem.eql(u64, &key, &objs_key)) {
        _ = objs_arena.reset(.retain_capacity);
        objs = .empty;
        objs_key = key;
    }
    if (objs.get(li)) |n| return n;
    const oa = objs_arena.allocator();
    // OpenGorky: the level's block's objects as its texts write them (parsed, no world made).
    if (app.ogLayout()) {
        const name = app.levels[li].name;
        var buf: [256]u8 = undefined;
        var list: std.ArrayList([]const u8) = .empty;
        for ([_][2][]const u8{ .{ "locations", "level.ogs" }, .{ "battles", "battle.ogs" } }) |k| {
            const path = std.fmt.bufPrint(&buf, "{s}/{s}/{s}", .{ k[0], name, k[1] }) catch continue;
            const f = app.store.file(@import("store.zig").og_src, path) catch continue;
            for (@import("model_og.zig").levelObjects(app, a, f)) |o| list.append(oa, oa.dupe(u8, o.name) catch continue) catch {};
            break;
        }
        objs.put(oa, li, list.items) catch {};
        return list.items;
    }
    if (!load) return &.{};
    const n: []const []const u8 = if (@import("level.zig").Doc.load(&app.store, null, app.levels[li].name)) |d| blk: {
        defer d.deinit();
        const list = namesOf(oa, d);
        for (list) |*x| x.* = oa.dupe(u8, x.*) catch "";
        break :blk list;
    } else |_| &.{};
    objs.put(oa, li, n) catch {};
    return n;
}

fn namesOf(a: Allocator, d: *const @import("level.zig").Doc) [][]const u8 {
    const out = a.alloc([]const u8, d.objects.items.len) catch return &.{};
    for (d.objects.items, out) |ob, *x| x.* = ob.name;
    return out;
}

/// Files the code editor opens.
fn text(entry: []const u8) bool {
    if (refs_mod.script(entry)) return true;
    for ([_][]const u8{ ".ss", ".s", ".scr", ".inf", ".txt", ".kdt" }) |e| if (std.ascii.endsWithIgnoreCase(entry, e)) return true;
    return false;
}

/// Go to's pick list (a name with several targets): its hits, kept until the next.
pub var picks_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
pub var picks: []const Hit = &.{};

/// Whether `tok` names anything (the hover underline): the last answer kept.
pub fn resolvable(app: *App, tok: []const u8) bool {
    const S = struct {
        var buf: [128]u8 = undefined;
        var len: usize = std.math.maxInt(usize);
        var yes = false;
    };
    // shortcut: kept across Store edits (a file added under the pointer underlines on the next word); key it on the Store if that matters.
    if (S.len <= S.buf.len and std.mem.eql(u8, S.buf[0..S.len], tok)) return S.yes;
    var tmp: std.heap.ArenaAllocator = .init(app.gpa);
    defer tmp.deinit();
    S.yes = resolve(app, tmp.allocator(), tok, false).len > 0;
    S.len = @min(tok.len, S.buf.len);
    @memcpy(S.buf[0..S.len], tok[0..S.len]);
    return S.yes;
}

/// Hit `h` opened; a file without a page: where it is, on the status bar.
pub fn go(app: *App, h: Hit) void {
    if (h.to == .none) return app.setStatus(tx.st_goto_file, .{h.label});
    // The target opens in a tab (the code kept in its own, unless a jump opened it).
    const hist = @import("codehist.zig");
    hist.leave(app);
    info.follow(app, h.to);
    app.followLink();
    hist.arrived(app);
}

/// A use of a word: where (its line's text, trimmed).
pub const Use = struct { archive: []const u8, entry: []const u8, at: usize, line: u32, text: []const u8 };

var uses_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
/// The last search (Find usages): the word and what was found.
pub var uses_word: []const u8 = "";
pub var uses: []const Use = &.{};
const uses_max = 300;

fn scriptOrRules(name: []const u8) bool {
    return text(name);
}

/// Every whole-word use of `w` (case aside) in the game's scripts, scenes and rules files,
/// as edited; the first `uses_max`. A name an OpenGorky project declares (at offset `i`
/// of `v`): only the uses naming that declaration (codesym.sameDecl), not its namesakes.
pub fn findUses(app: *App, w: []const u8, v: *const code.View, i: usize) void {
    _ = uses_arena.reset(.retain_capacity);
    const a = uses_arena.allocator();
    uses_word = a.dupe(u8, w) catch "";
    // shortcut: namesakes past 20000 text uses are not looked at, raise it if a project gets there.
    const all = collect(app, a, w, 20000);
    const kept = @import("codesym.zig").sameDecl(app, v, a, i, all) orelse all;
    uses = kept[0..@min(kept.len, uses_max)];
}

/// The first `max` whole-word uses of `w` (findUses; the Reference's examples).
pub fn collect(app: *App, a: Allocator, w: []const u8, max: usize) []const Use {
    var out: std.ArrayList(Use) = .empty;
    if (w.len == 0) return &.{};
    // An OpenGorky project's own code first (`src/`, as edited).
    const og_src = @import("store.zig").og_src;
    if (app.ogLayout()) for (app.store.listing(a, og_src, null, true)) |e| {
        if (!std.ascii.endsWithIgnoreCase(e, ".ogs")) continue;
        const i = app.store.file(og_src, e) catch continue;
        if (!usesIn(a, &out, og_src, e, app.store.text(i), w, max)) return out.items;
    };
    const paths = og.formats.archive.listArchives(app.io, app.gpa, app.dat) catch return out.items;
    defer og.formats.archive.freeList(app.gpa, paths);
    var tmp: std.heap.ArenaAllocator = .init(app.gpa);
    defer tmp.deinit();
    for (paths) |p| for (refs_mod.files(app, tmp.allocator(), p, scriptOrRules)) |f| {
        if (!usesIn(a, &out, p, f.name, f.text, w, max)) return out.items;
    };
    return out.items;
}

/// The whole-word uses of `w` in `text` (entry `entry` of `archive`) onto `out`; false
/// once it holds `max`.
fn usesIn(a: Allocator, out: *std.ArrayList(Use), archive: []const u8, entry: []const u8, src: []const u8, w: []const u8, max: usize) bool {
    var it = code.wordUses(src, w);
    while (it.next()) |at| {
        if (out.items.len == max) return false;
        const ls = std.mem.lastIndexOfScalar(u8, src[0..at], '\n');
        const le = std.mem.indexOfScalarPos(u8, src, at, '\n') orelse src.len;
        const line = std.mem.trim(u8, src[if (ls) |k| k + 1 else 0..le], " \t\r");
        out.append(a, .{
            .archive = a.dupe(u8, archive) catch return false,
            .entry = a.dupe(u8, entry) catch return false,
            .at = at,
            .line = @intCast(std.mem.count(u8, src[0..at], "\n") + 1),
            .text = a.dupe(u8, line[0..@min(line.len, 160)]) catch return false,
        }) catch return false;
    }
    return true;
}

/// What value `value` of rules field `f` (rulesapi.zig) means here: its word's meaning,
/// the classes and heroes of its classic_ids, a fighter or weapon classType's name with this
/// game's fighters or weapons of it, a string.tab text; "" when nothing is known.
pub fn rulesMeaning(app: *App, a: Allocator, f: *const rulesapi.Field, value: []const u8) []const u8 {
    if (rulesapi.word(f, value)) |w| return tx.get(w.doc);
    const v = std.mem.trim(u8, value, "\" ");
    const n = std.fmt.parseInt(i32, v, 10) catch null;
    switch (f.ref) {
        .none => return "",
        .name_id => {
            var out: std.ArrayList(u8) = .empty;
            var it = std.mem.tokenizeAny(u8, v, " ,()");
            while (it.next()) |tok| {
                const id = std.fmt.parseInt(i32, tok, 10) catch {
                    // A class key: "ft_wasp".
                    for (app.catalog.entries.items) |e| if (std.ascii.eqlIgnoreCase(stem(baseName(e.entry)), tok) or std.ascii.eqlIgnoreCase(e.id, tok)) {
                        out.print(a, "{s}{s}", .{ if (out.items.len > 0) ", " else "", if (e.title.len > 0) e.title else e.id }) catch {};
                        break;
                    };
                    continue;
                };
                for (app.catalog.entries.items) |e| if (e.name_id == id) {
                    out.print(a, "{s}{d} · {s}", .{ if (out.items.len > 0) ", " else "", id, if (e.title.len > 0) e.title else e.id }) catch {};
                    break;
                };
            }
            return out.items;
        },
        .fighter_class => {
            const c = n orelse return "";
            if (c == 0) return tx.get(tx.code_class_other);
            const name = std.enums.tagName(og.battle.fighter.Class, @fromBackingInt(@intCast(c))) orelse std.fmt.allocPrint(a, "{d}", .{c}) catch "";
            return tx.alloc(a, tx.code_in_game, .{ name, ofClass(app, a, c, &.{ .enemy, .hero }) });
        },
        .weapon_class => {
            const c = n orelse return "";
            return tx.alloc(a, tx.code_in_game, .{ @import("item_page.zig").classLabel(a, @floatFromInt(c)), ofClass(app, a, c, &.{ .weapon, .attack }) });
        },
        .text => return if (n) |id| (@import("texts.zig").get(app, a, .strings, id) orelse "") else "",
    }
}

/// The entries value `value` of rules field `f` names (Go to): its classic_ids and class keys
/// (as `resolve` finds them), a fighter or weapon classType's entries.
pub fn rulesHits(app: *App, a: Allocator, f: *const rulesapi.Field, value: []const u8) []const Hit {
    var o: Out = .{ .a = a };
    const v = std.mem.trim(u8, value, "\" ");
    switch (f.ref) {
        .name_id => {
            var it = std.mem.tokenizeAny(u8, v, " ,()\"");
            while (it.next()) |tok| for (resolve(app, a, tok, false)) |h| if (h.to == .entry) o.add(h.to, "{s}", .{h.label});
        },
        .fighter_class, .weapon_class => {
            const c = std.fmt.parseInt(i32, v, 10) catch return &.{};
            const kinds: []const og.loaders.classic.entities.Kind = if (f.ref == .fighter_class) &.{ .enemy, .hero } else &.{ .weapon, .attack };
            for (app.catalog.entries.items, 0..) |e, i| if (isOfClass(app, e, c, kinds)) o.entry(app, i);
        },
        else => {},
    }
    return o.list.items;
}

/// Entry `e` is of `kinds` and its script's classType is `c`.
fn isOfClass(app: *App, e: anytype, c: i32, kinds: []const og.loaders.classic.entities.Kind) bool {
    if (std.mem.indexOfScalar(og.loaders.classic.entities.Kind, kinds, e.kind) == null) return false;
    const fi = entries.fileOf(app, e) orelse return false;
    const ct = @import("model.zig").classOf(app.store.text(fi)) orelse return false;
    return @as(i32, @intFromFloat(ct)) == c;
}

/// This game's entries of `kinds` whose script's classType is `c` (their names, once each).
fn ofClass(app: *App, a: Allocator, c: i32, kinds: []const og.loaders.classic.entities.Kind) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    for (app.catalog.entries.items) |e| {
        if (!isOfClass(app, e, c, kinds)) continue;
        const name = if (e.title.len > 0) e.title else e.id;
        for (seen.items) |s| {
            if (std.ascii.eqlIgnoreCase(s, name)) break;
        } else {
            seen.append(a, name) catch {};
            out.print(a, "{s}{s}", .{ if (out.items.len > 0) ", " else "", name }) catch {};
        }
    }
    return if (out.items.len > 0) out.items else tx.get(tx.code_none_in_game);
}

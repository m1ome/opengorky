//! Where a name of an OpenGorky project's code is declared: one answer for Go to (and the
//! code probe). By the whole project's program — every text of `src/`, a level's parts as
//! one block, the view's own text as typed — names resolved as the linker resolves them
//! (script/ogs/link.zig): a qualified `a::b::f` as written, else from the caller's
//! component and module, the namespaces it `use`s, the root. Functions, components,
//! traits (and their methods), structs, enums, data blocks and modules lead to their
//! declaration's line. The engine's own names (builtins, foundation) are not here: the
//! Reference and the pages have them (codeview.defsAt).

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const ir = og.script.ir;
const link = og.script.ogs.link;
const parser = og.script.ogs.parser;
const code = @import("code.zig");
const codecheck = @import("codecheck.zig");
const og_src = @import("store.zig").og_src;
const App = @import("app.zig").App;
const View = code.View;

/// A declaration: its text (an entry of `src/`, or of the engine's read-only texts,
/// Store.engine_dir) and the offset of its name there.
pub const Def = struct { archive: []const u8, entry: []const u8, at: usize, label: []const u8 };

const engine_dir = @import("store.zig").engine_dir;
/// The prelude's file as the linker names it (the engine's traits and types).
const prelude_file = "engine.ogs";

/// The program of the last view asked, kept until its text or the project changes.
var cache: struct {
    key: [5]usize = @splat(std.math.maxInt(usize)),
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    p: link.Program = .{},
    own: parser.Unit = .{ .modules = &.{} },
    file: usize = std.math.maxInt(usize),
} = .{};

/// The project's program as view `v` sees it (null: not a project text, or its text does
/// not parse and none was made for it before).
fn program(app: *App, v: *const View) ?*const link.Program {
    if (!std.mem.eql(u8, app.store.files.items[v.file].archive, og_src)) return null;
    const sk = codecheck.storeKey(app);
    const key: [5]usize = .{ v.file, v.buf.version, sk[0], sk[1], sk[2] };
    if (std.mem.eql(usize, &key, &cache.key)) return &cache.p;
    const own_name = app.store.files.items[v.file].entry;
    // Typing breaks the text now and then: the last program made for it stands meanwhile.
    var tmp: std.heap.ArenaAllocator = .init(app.gpa);
    defer tmp.deinit();
    var pd: parser.Diagnostic = .{};
    const parses = if (parser.parse(tmp.allocator(), v.buf.str(), own_name, &pd)) |_| true else |_| false;
    if (!parses and cache.file == v.file) return &cache.p;
    _ = cache.arena.reset(.retain_capacity);
    const a = cache.arena.allocator();
    cache.key = key;
    cache.file = v.file;
    cache.p = .{};
    // Opened broken (typing): the other texts' program, until the text parses again.
    cache.own = if (parses) parser.parse(a, a.dupe(u8, v.buf.str()) catch return null, own_name, &pd) catch return null else .{ .modules = &.{} };
    var units: std.ArrayList(parser.Unit) = .empty;
    for (og.rules.scripts) |t| if (!std.ascii.eqlIgnoreCase(t.name, own_name)) if (codecheck.other(a, t.name, t.data, cache.own)) |x| units.append(a, x) catch {};
    units.append(a, cache.own) catch {};
    _ = og.script.ogs.levels.merge(a, units.items) catch {};
    for (units.items) |u| {
        var d: link.Diagnostic = .{};
        cache.p.add(a, u, &d) catch {};
    }
    return &cache.p;
}

/// Where the name at offset `i` of `v` is declared (none: not a project text, or not a
/// name the project declares).
pub fn defsAt(app: *App, v: *const View, a: Allocator, i: usize) []const Def {
    const p = program(app, v) orelse return &.{};
    return defsIn(app, v, a, p, v.buf.str(), app.store.files.items[v.file].entry, cache.own, i);
}

/// `defsAt` for offset `i` of text `t` (`src/` entry `entry`; parsed: `u`, its modules and
/// blocks the context).
fn defsIn(app: *App, v: *const View, a: Allocator, p: *const link.Program, t: []const u8, entry: []const u8, u: parser.Unit, i: usize) []const Def {
    const tok = code.tokenAt(t, i) orelse return &.{};
    var out: Out = .{ .a = a, .app = app, .p = p, .v = v };
    if (tok.string) {
        stringDefs(&out, t, entry, tok.start, tok.end);
        return out.list.items;
    }
    // `x.f`: a member of a value whose type is not known here.
    if (tok.start > 0 and t[tok.start - 1] == '.') return &.{};
    // The whole path the word is part of (`characters` of `characters::grandma`: grandma).
    const name = t[qualifiedStart(t, tok.start)..qualifiedEnd(t, tok.end)];
    const cx = context(u, i);
    // A named argument of a struct's value (`Place(who = …)`): the struct's field.
    if (std.mem.indexOf(u8, name, "::") == null) if (callBefore(t, tok.start, tok.end)) |callee| {
        for (keys(a, cx, callee)) |k| if (p.types.get(k)) |ty| if (ty == .@"struct") if (ty.@"struct".field(name)) |f| {
            out.add(ty.@"struct".file, ty.@"struct", name, f.line, "field");
            return out.list.items;
        };
    };
    // A data block's field statement (`hp = 40;`): the field's declaration (hosts.ogs);
    // a word in its value (`place = hand;`): its enum's value.
    if (std.mem.indexOf(u8, name, "::") == null) if (fieldAt(t, tok.start, tok.end, i)) |fa| if (blockKind(u, i)) |kind| {
        hostField(&out, kind, if (fa.value) fa.field else name, if (fa.value) name else null);
        if (out.list.items.len > 0) return out.list.items;
    };
    resolve(&out, cx, name);
    return out.list.items;
}

/// Of `uses` (the word's uses by text, codenav.collect), the ones naming what the name at
/// offset `i` of `v` names, each resolved in its own text as the linker would; null: not a
/// project declaration there (the uses by text stand).
pub fn sameDecl(app: *App, v: *const View, a: Allocator, i: usize, uses: []const Use) ?[]const Use {
    const want = defsAt(app, v, a, i);
    if (want.len == 0) return null;
    const p = &cache.p;
    const own = app.store.files.items[v.file];
    var out: std.ArrayList(Use) = .empty;
    for (uses) |u| {
        if (!std.mem.eql(u8, u.archive, og_src)) continue;
        const mine = std.ascii.eqlIgnoreCase(u.entry, own.entry);
        const t = if (mine) v.buf.str() else app.store.text(app.store.file(og_src, u.entry) catch continue);
        const unit = if (mine) cache.own else codecheck.other(a, u.entry, t, cache.own) orelse continue;
        const got = if (pathString(t, u.at)) |name| blk: {
            // `"weapons::c_nato"`, `~w"weapons::c_nato"`: a whole path names it from the root.
            var o: Out = .{ .a = a, .app = app, .p = p, .v = v };
            resolve(&o, .{}, name);
            break :blk o.list.items;
        } else defsIn(app, v, a, p, t, u.entry, unit, u.at + 1);
        if (for (got) |g| {
            if (for (want) |w| {
                if (w.at == g.at and std.mem.eql(u8, w.entry, g.entry)) break true;
            } else false) break true;
        } else false) out.append(a, u) catch {};
    }
    return out.items;
}

const Use = @import("codenav.zig").Use;

/// The whole path the string at offset `at` of `t` holds (`"a::b"`), else null.
fn pathString(t: []const u8, at: usize) ?[]const u8 {
    const tok = code.tokenAt(t, at + 1) orelse return null;
    if (!tok.string) return null;
    const s = std.mem.trim(u8, t[tok.start..tok.end], "\"");
    if (std.mem.indexOf(u8, s, "::") == null) return null;
    for (s) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == ':')) return null;
    return s;
}

/// The names the project declares as view `v` may write them at its cursor (completion):
/// each whole path (`items::ItemClass`, a namespace `_01_port`) and its short forms, from
/// its own module, a `use`d namespace or the engine's (`foundation::Wait` → `Wait`).
pub fn names(app: *App, v: *const View, a: Allocator) []const []const u8 {
    const p = program(app, v) orelse return &.{};
    const cx = context(cache.own, v.buf.cursor);
    var out: std.ArrayList([]const u8) = .empty;
    const Add = struct {
        fn one(o: *std.ArrayList([]const u8), al: Allocator, m: ?*const ir.Module, k: []const u8) void {
            o.append(al, k) catch {};
            if (cut(k, link.foundation)) |s| o.append(al, s) catch {};
            const mod = m orelse return;
            if (cut(k, mod.path)) |s| o.append(al, s) catch {};
            for (mod.uses) |u| if (cut(k, u)) |s| o.append(al, s) catch {};
        }
        /// `k` without namespace `ns::` before it.
        fn cut(k: []const u8, ns: []const u8) ?[]const u8 {
            if (ns.len == 0 or k.len <= ns.len + 2 or !std.mem.startsWith(u8, k, ns) or !std.mem.eql(u8, k[ns.len .. ns.len + 2], "::")) return null;
            return k[ns.len + 2 ..];
        }
    };
    inline for (.{ &p.fns, &p.components, &p.traits, &p.types, &p.namespaces }) |map| {
        var it = map.keyIterator();
        while (it.next()) |k| Add.one(&out, a, cx.m, k.*);
    }
    var it = p.blocks.keyIterator();
    while (it.next()) |k| if (std.mem.indexOfScalar(u8, k.*, ' ')) |sp| Add.one(&out, a, cx.m, k.*[sp + 1 ..]);
    return out.items;
}

/// Where the path going on after the word ending at `e` ends (`a::b::f` from `a`'s end).
pub fn qualifiedEnd(t: []const u8, e0: usize) usize {
    var e = e0;
    while (e + 2 < t.len and t[e] == ':' and t[e + 1] == ':' and (std.ascii.isAlphabetic(t[e + 2]) or t[e + 2] == '_')) {
        e += 2;
        while (e < t.len and (std.ascii.isAlphanumeric(t[e]) or t[e] == '_')) e += 1;
    }
    return e;
}

/// Where the path ending at the word starting at `s` starts (`a::b::f` from `f`'s start).
pub fn qualifiedStart(t: []const u8, s0: usize) usize {
    var s = s0;
    while (s >= 2 and t[s - 1] == ':' and t[s - 2] == ':') {
        var k = s - 2;
        while (k > 0 and (std.ascii.isAlphanumeric(t[k - 1]) or t[k - 1] == '_')) k -= 1;
        if (k == s - 2) break;
        s = k;
    }
    return s;
}

/// Where offset `i` is: the module block (the one of the nearest declaration before it)
/// and the component it is in (its own methods first).
const Ctx = struct { m: ?*const ir.Module = null, comp: ?*const ir.Component = null, ent: ?*const ir.Entity = null };

fn context(u: parser.Unit, i: usize) Ctx {
    var cx: Ctx = .{};
    var best: u32 = 0;
    for (u.modules) |*m| {
        for (m.fns) |f| near(&cx, &best, m, f.span, i);
        for (m.components) |c| {
            near(&cx, &best, m, c.span, i);
            if (inside(c.span, i)) cx.comp = c;
        }
        for (m.entities) |*e| {
            near(&cx, &best, m, e.span, i);
            ownComp(e, i, &cx);
        }
    }
    if (cx.m == null and u.modules.len > 0) cx.m = &u.modules[0];
    return cx;
}

fn near(cx: *Ctx, best: *u32, m: *const ir.Module, s: ir.Span, i: usize) void {
    if (s.none() or s.start > i or s.start < best.*) return;
    best.* = s.start;
    cx.m = m;
}

fn inside(s: ir.Span, i: usize) bool {
    return !s.none() and s.start <= i and i <= s.end;
}

fn ownComp(e: *const ir.Entity, i: usize, cx: *Ctx) void {
    if (!inside(e.span, i)) return;
    if (e.own) |c| if (inside(c.span, i)) {
        cx.comp = c;
        cx.ent = e;
    };
    for (e.children) |*ch| ownComp(ch, i, cx);
}

const Out = struct {
    a: Allocator,
    app: *App,
    p: *const link.Program,
    v: *const View,
    list: std.ArrayList(Def) = .empty,

    /// Declaration `name` at line `line` of text `file` (null: the text holding `ptr`,
    /// one of the program's).
    fn add(o: *Out, file: ?[]const u8, ptr: *const anyopaque, name: []const u8, line: u32, what: []const u8) void {
        const entry = (if (file) |f| o.entryNamed(f) else o.fileOf(ptr)) orelse return;
        o.putLine(archiveOf(entry), entry, line, name, what);
    }

    /// Name `name` on line `line` of text `entry` of `archive`.
    fn putLine(o: *Out, archive: []const u8, entry: []const u8, line: u32, name: []const u8, what: []const u8) void {
        const text = o.textOf(archive, entry) orelse return;
        const ls = code.lineOffset(text, line);
        const le = code.lineEnd(text, ls);
        o.put(archive, entry, if (wordIn(text[ls..le], name)) |k| ls + k else ls, what, name, line);
    }

    fn put(o: *Out, archive: []const u8, entry: []const u8, at: usize, what: []const u8, name: []const u8, line: u32) void {
        for (o.list.items) |d| if (std.mem.eql(u8, d.entry, entry) and d.at == at) return;
        const label = std.fmt.allocPrint(o.a, "{s} {s} · {s}:{d}", .{ what, name, entry, line }) catch return;
        o.list.append(o.a, .{ .archive = archive, .entry = entry, .at = at, .label = label }) catch {};
    }

    /// The program's text named `f` (a declaration's `file`, maybe lower-cased).
    fn entryNamed(o: *Out, f: []const u8) ?[]const u8 {
        for (o.p.texts.items) |u| if (std.ascii.eqlIgnoreCase(u.file, f)) return u.file;
        return null;
    }

    /// The text (its `src/` entry) whose IR holds `ptr`.
    fn fileOf(o: *Out, ptr: *const anyopaque) ?[]const u8 {
        for (o.p.texts.items) |u| for (u.modules) |*m| {
            for (m.components) |c| if (@as(*const anyopaque, c) == ptr) return u.file;
            for (m.entities) |*e| if (@as(*const anyopaque, e) == ptr) return u.file;
        };
        return null;
    }

    /// Text `entry` of `archive` as edited (the view's own: its buffer).
    fn textOf(o: *Out, archive: []const u8, entry: []const u8) ?[]const u8 {
        const own = o.app.store.files.items[o.v.file];
        if (std.mem.eql(u8, archive, own.archive) and std.ascii.eqlIgnoreCase(entry, own.entry)) return o.v.buf.str();
        return o.app.store.text(o.app.store.file(archive, entry) catch return null);
    }
};

/// The archive of a program's text: the prelude is the engine's.
fn archiveOf(entry: []const u8) []const u8 {
    return if (std.mem.eql(u8, entry, prelude_file)) engine_dir else og_src;
}

/// Where whole word `w` starts in `line`.
fn wordIn(line: []const u8, w: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, w)) |k| : (from = k + 1) {
        const before = k == 0 or !(std.ascii.isAlphanumeric(line[k - 1]) or line[k - 1] == '_');
        const after = k + w.len >= line.len or !(std.ascii.isAlphanumeric(line[k + w.len]) or line[k + w.len] == '_');
        if (before and after) return k;
    }
    return null;
}

fn last(path: []const u8) []const u8 {
    return if (std.mem.lastIndexOf(u8, path, "::")) |k| path[k + 2 ..] else path;
}

/// The keys `name` may stand for from `cx`, as the linker tries them: qualified as
/// written (and from the module), else the module's, the `use`d namespaces', the root's.
fn keys(a: Allocator, cx: Ctx, name: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const m = cx.m;
    if (std.mem.indexOf(u8, name, "::") != null) out.append(a, name) catch {};
    if (m) |mod| {
        if (mod.path.len > 0) out.append(a, std.fmt.allocPrint(a, "{s}::{s}", .{ mod.path, name }) catch name) catch {};
        for (mod.uses) |u| out.append(a, std.fmt.allocPrint(a, "{s}::{s}", .{ u, name }) catch name) catch {};
    }
    if (std.mem.indexOf(u8, name, "::") == null) {
        out.append(a, name) catch {};
        // The engine's types last (`Place(…)`, `Camera(…)` in data).
        out.append(a, std.fmt.allocPrint(a, link.foundation ++ "::{s}", .{name}) catch name) catch {};
    }
    return out.items;
}

fn resolve(o: *Out, cx: Ctx, name: []const u8) void {
    const p = o.p;
    const n = last(name);
    // The caller's component's own method (a plain name only).
    if (std.mem.indexOf(u8, name, "::") == null) if (cx.comp) |c| {
        for (c.methods) |f| if (std.mem.eql(u8, f.name, n)) o.add(f.file, f, n, f.line, "fn");
        // Its own fields, its block's vars, the fields of the kinds it is `for` (hosts.ogs).
        if (o.list.items.len == 0) for (c.fields) |f| if (std.mem.eql(u8, f.name, n)) o.add(null, c, n, f.line, "var");
        if (o.list.items.len == 0) if (cx.ent) |e| for (e.vars) |f| if (std.mem.eql(u8, f.name, n)) o.add(null, e, n, f.line, "var");
        if (o.list.items.len == 0) for (c.hosts) |h| if (og.script.hosts.field(h, n)) |fd| {
            o.putLine(engine_dir, "hosts.ogs", fd.field.line, n, fd.host.name);
            break;
        };
    };
    // The first place that has the name wins, as in the linker (not every place having it).
    if (o.list.items.len > 0) return;
    for (keys(o.a, cx, name)) |k| {
        if (p.fns.get(k)) |f| o.add(f.file, f, n, f.line, "fn");
        if (p.components.get(k)) |c| o.add(null, c, n, c.line, "component");
        if (p.traits.get(k)) |x| o.add(x.file, x, n, x.line, "trait");
        if (p.types.get(k)) |x| switch (x) {
            .@"struct" => |s| o.add(s.file, s, n, s.line, "struct"),
            .@"enum" => |e| o.add(e.file, e, n, e.line, "enum"),
        };
        var it = p.blocks.iterator();
        while (it.next()) |b| {
            const sp = std.mem.indexOfScalar(u8, b.key_ptr.*, ' ') orelse continue;
            if (std.mem.eql(u8, b.key_ptr.*[sp + 1 ..], k)) o.add(null, b.value_ptr.*, n, b.value_ptr.*.line, b.key_ptr.*[0..sp]);
        }
        if (p.namespaces.contains(k)) moduleDecl(o, k);
        if (o.list.items.len > 0) return;
    }
    if (o.list.items.len > 0) return;
    // `T::f`: method `f` of trait or component `T` (a default body, an own method); `E::v`:
    // enum `E`.
    const cut = std.mem.lastIndexOf(u8, name, "::") orelse return;
    const owner = name[0..cut];
    for (keys(o.a, cx, owner)) |k| {
        if (p.traits.get(k)) |x| for (x.methods) |f| if (std.mem.eql(u8, f.f.name, n)) o.add(f.f.file, f.f, n, f.f.line, "fn");
        if (p.components.get(k)) |c| for (c.methods) |f| if (std.mem.eql(u8, f.name, n)) o.add(f.file, f, n, f.line, "fn");
        if (p.types.get(k)) |x| if (x == .@"enum") o.add(x.@"enum".file, x.@"enum", last(owner), x.@"enum".line, "enum");
    }
}

/// What string `t[s..e]` names: a whole path (`"weapons::c_nato"`) from the root; a data
/// block of that name (`~d"lab-nato_group3"`, any kind); else a row named so (`Point(name =
/// "cam_1")` of the scene, `Slot(name = "walk")` of the looks), in its own text first.
fn stringDefs(o: *Out, t: []const u8, entry: []const u8, s: usize, e: usize) void {
    const str = t[s..e];
    if (str.len == 0) return;
    for (str) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-' or ch == ':')) return;
    // The row's own name: it is the declaration.
    if (std.mem.endsWith(u8, std.mem.trimEnd(u8, t[code.lineStart(t, s) .. s - 1], " \t="), "name")) return;
    if (std.mem.indexOf(u8, str, "::") != null) return resolve(o, .{}, str);
    var it = o.p.blocks.iterator();
    while (it.next()) |b| {
        const sp = std.mem.indexOfScalar(u8, b.key_ptr.*, ' ') orelse continue;
        if (std.mem.eql(u8, last(b.key_ptr.*[sp + 1 ..]), str)) o.add(null, b.value_ptr.*, str, b.value_ptr.*.line, b.key_ptr.*[0..sp]);
    }
    if (o.list.items.len > 0) return;
    const pat = std.fmt.allocPrint(o.a, "name = \"{s}\"", .{str}) catch return;
    rowsNamed(o, og_src, entry, t, pat);
    if (o.list.items.len > 0) return;
    for (og.rules.scripts) |x| {
        if (std.ascii.eqlIgnoreCase(x.name, entry)) continue;
        rowsNamed(o, og_src, x.name, o.textOf(og_src, x.name) orelse continue, pat);
        // shortcut: the first 20 texts having it (`"walk"`: most looks), until the call's actor's look is known.
        if (o.list.items.len >= 20) return;
    }
}

/// Each `name = "…"` (`pat`) of text `entry` (`text`) of `archive`.
fn rowsNamed(o: *Out, archive: []const u8, entry: []const u8, text: []const u8, pat: []const u8) void {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, pat)) |k| : (from = k + pat.len) {
        const ls = code.lineStart(text, k);
        const name = text[ls..code.lineEnd(text, ls)];
        const row = std.mem.trim(u8, name[0 .. std.mem.indexOfScalar(u8, name, '(') orelse 0], " \t");
        o.put(archive, entry, k + "name = \"".len, if (row.len > 0) row else "row", pat[8 .. pat.len - 1], @intCast(std.mem.count(u8, text[0..k], "\n") + 1));
    }
}

/// Module `path`: each `module path {` block of it.
fn moduleDecl(o: *Out, path: []const u8) void {
    const head = std.fmt.allocPrint(o.a, "module {s}", .{path}) catch return;
    for (o.p.texts.items) |u| for (u.modules) |m| {
        if (!std.mem.eql(u8, m.path, path)) continue;
        const text = o.textOf(archiveOf(u.file), u.file) orelse continue;
        const k = wordIn(text, head) orelse continue;
        // A namespace in many texts (`characters`): its first block stands for it.
        return o.put(archiveOf(u.file), u.file, k + "module ".len, "module", path, @intCast(std.mem.count(u8, text[0..k], "\n") + 1));
    };
}

/// The field statement the word `t[s..e]` (at offset `i`) is in: the field's name, and
/// whether the word is in its value (`place = hand;`) or is the field itself (`place =`).
fn fieldAt(t: []const u8, s: usize, e: usize, i: usize) ?struct { field: []const u8, value: bool } {
    _ = i;
    // The word itself followed by `=` (not `==`).
    var k = e;
    while (k < t.len and (t[k] == ' ' or t[k] == '\t')) k += 1;
    if (k < t.len and t[k] == '=' and !(k + 1 < t.len and t[k + 1] == '=')) return .{ .field = t[s..e], .value = false };
    // In a value: the statement's start on this line, `name = …word`.
    const ls = code.lineStart(t, s);
    const line = t[ls..s];
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;
    if (eq + 1 < line.len and line[eq + 1] == '=') return null;
    if (std.mem.indexOfAny(u8, line[eq + 1 ..], "(\"") != null) return null;
    const lhs = std.mem.trim(u8, line[0..eq], " \t");
    if (lhs.len == 0) return null;
    for (lhs) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return null;
    return .{ .field = lhs, .value = true };
}

/// The call whose named argument the word `t[s..e]` is (`who` of `Place(who = …)`): its
/// name as written, else null.
fn callBefore(t: []const u8, s: usize, e: usize) ?[]const u8 {
    var k = e;
    while (k < t.len and (t[k] == ' ' or t[k] == '\t')) k += 1;
    if (!(k < t.len and t[k] == '=' and !(k + 1 < t.len and t[k + 1] == '='))) return null;
    // Back to the `(` this argument list opened with.
    var depth: usize = 0;
    var j = s;
    while (j > 0) {
        j -= 1;
        switch (t[j]) {
            ')', ']' => depth += 1,
            '(', '[' => {
                if (depth == 0) {
                    if (t[j] == '[') return null;
                    var ne = j;
                    while (ne > 0 and (t[ne - 1] == ' ' or t[ne - 1] == '\t')) ne -= 1;
                    const ns = qualifiedStart(t, code.nameStart(t, ne));
                    return if (ns < ne) t[ns..ne] else null;
                }
                depth -= 1;
            },
            ';', '{', '}' => return null,
            else => {},
        }
    }
    return null;
}

/// The kind of the innermost data block holding offset `i` outside its own code (`fighter`,
/// `weapon` of a fighter's `weapon a: …`).
fn blockKind(u: parser.Unit, i: usize) ?[]const u8 {
    var kind: ?[]const u8 = null;
    for (u.modules) |m| for (m.entities) |*e| innermost(e, i, &kind);
    return kind;
}

fn innermost(e: *const ir.Entity, i: usize, kind: *?[]const u8) void {
    if (!inside(e.span, i)) return;
    // In its own code: one of its methods (the own component's span is the whole block's).
    if (e.own) |c| for (c.methods) |f| if (inside(f.span, i)) {
        kind.* = null;
        return;
    };
    kind.* = e.kind;
    for (e.children) |*ch| innermost(ch, i, kind);
}

/// Field `field` of block kind `kind` (its host's or an ancestor's, hosts.ogs); with
/// `value`, that word of the field's enum type (types.ogs, or the project's enum).
fn hostField(o: *Out, kind: []const u8, field: []const u8, value: ?[]const u8) void {
    const h = og.core.schema.blockHost(kind) orelse return;
    const fd = og.script.hosts.field(h.name, field) orelse return;
    const v = value orelse return o.putLine(engine_dir, "hosts.ogs", fd.field.line, field, fd.host.name);
    // `list<ItemPlace>`: its element's type.
    var tn = fd.field.type_name;
    if (std.mem.startsWith(u8, tn, "list<") and std.mem.endsWith(u8, tn, ">")) tn = tn[5 .. tn.len - 1];
    for ([_][]const u8{ tn, std.fmt.allocPrint(o.a, link.foundation ++ "::{s}", .{tn}) catch tn }) |k| {
        const ty = o.p.types.get(k) orelse continue;
        if (ty != .@"enum") continue;
        const en = ty.@"enum";
        const entry = o.entryNamed(en.file) orelse return;
        const archive = archiveOf(entry);
        const text = o.textOf(archive, entry) orelse return;
        // The value's own line inside the enum's braces, else the enum's.
        const from = code.lineOffset(text, en.line);
        const close = std.mem.indexOfScalarPos(u8, text, from, '}') orelse text.len;
        if (wordIn(text[from..close], v)) |at| return o.put(archive, entry, from + at, "enum value", v, @intCast(std.mem.count(u8, text[0 .. from + at], "\n") + 1));
        return o.putLine(archive, entry, en.line, en.name, "enum");
    }
}

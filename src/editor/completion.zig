//! Code completion's logic (no window): what the list offers at the cursor (the values
//! an argument, a rules field or a data block's field takes, a declaration's parameters,
//! the words for the word before it, the ready-made tasks) and what taking one puts in
//! the text. The project's names come through a `Source` (codecomplete.zig gives the
//! editor's; the tests a table); codecomplete.zig draws the list.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const code = @import("code.zig");
const rulesapi = @import("rulesapi.zig");
const api = @import("api.zig");
const callbacks = @import("callbacks.zig");
const tx = @import("text.zig");
const traitinfo = @import("traitinfo.zig");

/// What text the cursor is in (codecomplete.where: by its file).
pub const Where = struct {
    /// A rules file (the OG project's sources): its tables' calls.
    rules: bool = false,
    /// OG Script: a rules file, or a Classic script in its OG Script view.
    ogs: bool = false,
    /// The rules' hooks file (functions the engine calls).
    hooks: bool = false,
    /// A level's script of the OG layout: hooks of its own.
    level_hooks: bool = false,
    /// A scene (`.scr`): the exe's commands.
    scene: bool = false,
};

/// The names of the project a list can take (`Source`): `areas`, `actors`, `objects`
/// (all but areas), `level_names` (all) are the open level's; `sounds` the sound files
/// (`opentreasure.wav`), `dialogs` the `.dlg` files with their extension; `anims` the
/// animations of `actor`'s look (none: of the text's own); `files` the project's source
/// paths (`weapons/pistol.ogs`); `name_ids` the catalog's `id · title`; `weapon_classes`
/// the classTypes' `n · name`; `calls` the catalog's call examples' names.
pub const Names = enum { levels, scenes, areas, actors, objects, level_names, sounds, dialogs, videos, meshes, classes, anims, functions, files, name_ids, weapon_classes, calls, components, program };

/// Where the project's names come from.
pub const Source = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, a: Allocator, what: Names, actor: []const u8, text: []const u8) []const []const u8,
    /// What value `value` of rules field `f` means in this project ("": nothing known).
    meaning: *const fn (ctx: *anyopaque, a: Allocator, f: *const rulesapi.Field, value: []const u8) []const u8 = noMeaning,
    /// The catalog's example of call `name` (a game script's line); null: none.
    example: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8 = noExample,

    fn noMeaning(_: *anyopaque, _: Allocator, f: *const rulesapi.Field, value: []const u8) []const u8 {
        return if (rulesapi.word(f, value)) |w| tx.get(w.doc) else "";
    }

    fn noExample(_: *anyopaque, _: []const u8) ?[]const u8 {
        return null;
    }

    fn names(self: Source, a: Allocator, what: Names) []const []const u8 {
        return self.get(self.ctx, a, what, "", "");
    }
};

/// Common things a level script does, as code to put in (Ctrl+Space on an empty spot):
/// `""` marks where values go; the cursor lands in the first, its list open.
const Task = struct { label: tx.Msg, code: []const u8 };
pub const tasks = [_]Task{
    .{ .label = tx.ct_place, .code = "PlaceActor(\"\", \"capt_start\", 0);" },
    .{ .label = tx.ct_level, .code = "LEVEL_Load(\"\");" },
    .{ .label = tx.ct_scene, .code = "StartScriptlet(\"\");" },
    .{ .label = tx.ct_join, .code = "EnableObject(\"\");\nHERO_EnableEnumerate(\"\", 1);" },
    .{ .label = tx.ct_area, .code = "if(HeroInArea(\"\"))\n{\n};" },
    .{ .label = tx.ct_heroes, .code = "PlaceHeroes(\"\");" },
    .{ .label = tx.ct_show, .code = "EnableObject(\"\");" },
    .{ .label = tx.ct_hide, .code = "DisableObject(\"\");" },
    .{ .label = tx.ct_delete, .code = "DeleteObject(\"\");" },
    .{ .label = tx.ct_sound, .code = "PlaySound(\"\");" },
};

/// The party's heroes as the scripts name them (some join later in the game).
const party = [_][]const u8{ "Sullivan", "Ovitz", "Trantigne", "MacFadden", "Medusa", "Slavsky", "Hutchens", "BT" };

/// `name.ext` without `.ext`.
fn stem(s: []const u8) []const u8 {
    return s[0 .. std.mem.lastIndexOfScalar(u8, s, '.') orelse s.len];
}

fn stems(a: Allocator, ns: []const []const u8) []const []const u8 {
    const out = a.alloc([]const u8, ns.len) catch return &.{};
    for (ns, out) |n, *o| o.* = stem(n);
    return out;
}

/// What goes in the argument of call `cp` being typed, by its parameter's name (api.zig):
/// actors, objects, areas of the open level, levels, scenes, sounds, videos, dialogs,
/// models, classes, the actor's animations, script functions; null — nothing known.
fn values(a: Allocator, t: []const u8, cp: code.CallPos, src: Source) ?[]const []const u8 {
    const f = api.find(cp.name) orelse return null;
    var pb: [12]api.Param = undefined;
    const ps = api.params(f, &pb);
    if (cp.arg >= ps.len) return null;
    const decl = ps[cp.arg].decl;
    // A string, or a kind of one (`level level`: a sigil's, ir.Sigil.ofType).
    const sp = std.mem.indexOfScalar(u8, decl, ' ') orelse return null;
    if (!std.mem.eql(u8, decl[0..sp], "string") and og.script.ir.Sigil.ofType(decl[0..sp]) == null) return null;
    const name = decl[sp + 1 ..];
    const eq = std.mem.eql;
    if (eq(u8, name, "level")) return src.names(a, .levels);
    if (eq(u8, name, "scene")) return src.names(a, .scenes);
    if (eq(u8, name, "area") or eq(u8, name, "track")) return src.names(a, .areas);
    if (eq(u8, name, "actor") or eq(u8, name, "hero") or eq(u8, name, "fighter") or eq(u8, name, "name"))
        return std.mem.concat(a, []const u8, &.{ &party, src.names(a, .actors) }) catch null;
    if (eq(u8, name, "object") or eq(u8, name, "target") or eq(u8, name, "parent") or eq(u8, name, "owner") or eq(u8, name, "item") or eq(u8, name, "weapon")) return src.names(a, .objects);
    // PlaySound("opentreasure"): the name without `.wav`.
    if (eq(u8, name, "sound") or eq(u8, name, "sounds")) return stems(a, src.names(a, .sounds));
    if (eq(u8, name, "wav")) return src.names(a, .sounds);
    if (eq(u8, name, "file")) return src.names(a, if (std.ascii.eqlIgnoreCase(f.name, "DialogInit")) .dialogs else .videos);
    if (eq(u8, name, "mesh")) return src.names(a, .meshes);
    if (eq(u8, name, "class")) return src.names(a, .classes);
    if (eq(u8, name, "anim") or eq(u8, name, "logical")) {
        // The animations the actor's look registers (the call's actor, else the script's own).
        const who = for (ps, 0..) |p, k| {
            if (k != cp.arg and std.mem.eql(u8, p.decl, "string actor")) break code.argValue(t, cp.open, k) orelse "";
        } else "";
        return src.get(src.ctx, a, .anims, who, t);
    }
    if (eq(u8, name, "function")) return src.names(a, .functions);
    if (eq(u8, name, "mode")) return &.{ "GUI_Staging", "GUI_SafeBox" };
    return null;
}

/// The names a sigil of `kind` takes that the editor lists whole; null — none known.
fn sigilValues(a: Allocator, kind: og.script.ir.Sigil, src: Source) ?[]const []const u8 {
    return switch (kind) {
        .level => src.names(a, .levels),
        .scene => src.names(a, .scenes),
        .sound => stems(a, src.names(a, .sounds)),
        .dialog => stems(a, src.names(a, .dialogs)),
        else => null,
    };
}

/// The values for the value at offset `i` of text `t`: a rules field's (its words and
/// the names its reference takes), a data block field's, a call argument's (after a
/// sigil `~l"`: its kind's names); null: none known.
pub fn slot(a: Allocator, t: []const u8, i: usize, where: Where, src: Source) ?Slot {
    // The hooks file is a rules file of functions: builtins' values there too.
    if (where.rules) if (rulesValues(a, t, i, src)) |s| return s;
    if (where.ogs) if (blockSlot(a, t, i)) |s| {
        if (s.block_dir.len == 0) return s;
        var r = s;
        r.vals = blockNames(a, s.block_dir, src.names(a, .files));
        if (r.vals.len > 0) return r;
    };
    const sl = code.argSlot(t, i) orelse return null;
    if (sl.quoted and sl.start >= 3 and t[sl.start - 3] == '~') if (og.script.ir.Sigil.of(t[sl.start - 2])) |k|
        return .{ .start = sl.start, .end = i, .quoted = true, .vals = sigilValues(a, k, src) orelse return null };
    return .{ .start = sl.start, .end = i, .quoted = sl.quoted, .vals = values(a, t, sl.call, src) orelse return null };
}

/// The rules field's value at `i` (rulesSlot) with the names its reference takes: the
/// classTypes with their names, the game's classic_ids with theirs (one per id).
fn rulesValues(a: Allocator, t: []const u8, i: usize, src: Source) ?Slot {
    var s = rulesSlot(a, t, i) orelse return null;
    if (s.ref == .none or s.ref == .text) return s;
    var out: std.ArrayList([]const u8) = .empty;
    out.appendSlice(a, s.vals) catch {};
    switch (s.ref) {
        .fighter_class => {
            out.append(a, std.fmt.allocPrint(a, "0 · {s}", .{tx.get(tx.code_class_other)}) catch "0") catch {};
            inline for (@typeInfo(og.battle.fighter.Class).@"enum".field_names, @typeInfo(og.battle.fighter.Class).@"enum".field_values) |n, x| out.append(a, std.fmt.allocPrint(a, "{d} · {s}", .{ x, n }) catch n) catch {};
        },
        .weapon_class => out.appendSlice(a, src.names(a, .weapon_classes)) catch {},
        .name_id => for (src.names(a, .name_ids)) |n| {
            const id = if (std.mem.indexOf(u8, n, " · ")) |k| n[0 .. k + " · ".len] else n;
            for (out.items) |o| {
                if (std.mem.startsWith(u8, o, id)) break;
            } else out.append(a, n) catch {};
        },
        .none, .text => {},
    }
    if (out.items.len == 0) return null;
    s.vals = out.items;
    return s;
}

/// The declaration header holding offset `i` (its name or parameters): the function's
/// name and the parameter at `i` (null on the name).
pub fn declAt(a: Allocator, t: []const u8, i: usize) ?struct { name: []const u8, arg: ?usize } {
    const fns = code.functions(a, t);
    const k = code.currentFn(fns, i) orelse return null;
    const h = code.header(a, t, fns[k].at) orelse return null;
    if (i > h.close or (h.close == t.len and i > code.lineEnd(t, h.open))) return null;
    if (i <= h.open) return .{ .name = h.name, .arg = null };
    return .{ .name = h.name, .arg = std.mem.count(u8, t[h.open + 1 .. i], ",") };
}

/// In the parameters of an engine callback's (or hook's) declaration at `i`: the ones
/// the engine passes from the cursor's on, each and all of the rest together
/// (`string item, string hero`).
fn headerParams(a: Allocator, t: []const u8, i: usize, where: Where) ?[]const []const u8 {
    const da = declAt(a, t, i) orelse return null;
    const arg = da.arg orelse return null;
    const buf = a.alloc(callbacks.Param, 8) catch return null;
    const cb = (if (where.hooks) callbacks.hook(buf, da.name) else if (where.rules) null else if (callbacks.find(da.name)) |x| x.* else if (where.level_hooks) callbacks.hook(buf, da.name) else null) orelse return null;
    if (arg >= cb.params.len) return null;
    var out: std.ArrayList([]const u8) = .empty;
    for (cb.params[arg..]) |p| out.append(a, p.decl) catch {};
    if (cb.params.len - arg > 1) {
        var all: std.ArrayList(u8) = .empty;
        for (cb.params[arg..], 0..) |p, k| all.print(a, "{s}{s}", .{ if (k > 0) ", " else "", p.decl }) catch {};
        out.append(a, all.items) catch {};
    }
    return out.items;
}

/// The list at offset `i` of `t` (`tasks`: the ready-made tasks' labels): a
/// declaration's parameters, the values of the value there, after `x.` its type's
/// members, a data block's fields at a statement's start, else the words for the word
/// before it (in a rules file its tables' calls and the call's fields, the builtins, the
/// game's functions, the level's names, the language's words, the text's identifiers).
pub fn candidates(a: Allocator, t: []const u8, i: usize, show_tasks: bool, where: Where, src: Source) []const []const u8 {
    if (show_tasks) {
        const out = a.alloc([]const u8, tasks.len) catch return &.{};
        for (tasks, out) |k, *o| o.* = tx.get(k.label);
        return out;
    }
    const prefix = t[code.nameStart(t, i)..i];
    if (headerParams(a, t, i, where)) |ps| return pick(a, prefix, ps, 12);
    if (slot(a, t, i, where, src)) |sv| return pick(a, t[sv.start..i], sv.vals, 12);
    // OG Script after `host.`, `self.`, `x.as(T).`: the receiver's static type's words.
    const dot = i -| prefix.len;
    if (where.ogs and dot > 0 and t[dot - 1] == '.') {
        const p = traitinfo.load(a);
        const ms = traitinfo.members(&p, a, t, dot - 1);
        if (ms.len > 0) return pick(a, prefix, ms, 12);
    }
    // OG Script, a statement started in a data block: its kind's fields (foundation/hosts.ogs).
    if (where.ogs) if (blockFields(a, t, dot)) |fs| {
        const got = pick(a, prefix, fs, 12);
        if (got.len > 0) return got;
    };
    var words: std.ArrayList([]const u8) = .empty;
    if (where.rules) {
        if (rulesAt(t, i)) |r| for (r.call.fields) |f| words.append(a, f.name) catch {};
        words.appendSlice(a, og.loaders.rules_text.calls) catch {};
    }
    // The builtins as this text's language calls them (OG Script: `fighter::SetHp`).
    if (where.scene) words.appendSlice(a, &og.scene.scenario.exe_order) catch {} else for (&api.all) |*f| if (api.shown(f, where.ogs).len > 0) words.append(a, api.shown(f, where.ogs)) catch {};
    words.appendSlice(a, src.names(a, .calls)) catch {};
    if (!where.scene) words.appendSlice(a, src.names(a, .functions)) catch {};
    // Names of the open level's objects (for the strings calls take).
    words.appendSlice(a, src.names(a, .level_names)) catch {};
    if (where.ogs) {
        // OG Script's words, the fighter events (component methods), the components.
        words.appendSlice(a, &code.ogs_keywords) catch {};
        for (og.script.traits.events()) |e| words.append(a, e.name) catch {};
        words.appendSlice(a, src.names(a, .components)) catch {};
        // The project's declarations (codesym.names): `ns::` paths, its enums, structs, blocks.
        words.appendSlice(a, src.names(a, .program)) catch {};
    } else words.appendSlice(a, &.{ "function", "if", "else", "while", "return", "int", "float", "string" }) catch {};
    words.appendSlice(a, code.identifiers(a, t) catch &.{}) catch {};
    return code.matches(a, prefix, words.items, 10) catch &.{};
}

/// The first `max` of `vals` (no prefix), else those `prefix` matches.
fn pick(a: Allocator, prefix: []const u8, vals: []const []const u8, max: usize) []const []const u8 {
    if (prefix.len == 0) return vals[0..@min(vals.len, max)];
    return code.matches(a, prefix, vals, max) catch &.{};
}

/// Whether typing `typed` (now before offset `i`) opens the list: a word of two letters,
/// OG Script's `x.` (its type's words at once), a value with known values.
pub fn opensOnType(a: Allocator, t: []const u8, i: usize, typed: []const u8, where: Where, src: Source) bool {
    if (i - code.nameStart(t, i) >= 2) return true;
    if (std.mem.eql(u8, typed, ".") and where.ogs) return true;
    return if (slot(a, t, i, where, src)) |sv| sv.vals.len > 0 else false;
}

/// Whether Ctrl+Space at `i` lists the tasks: no word before it, not in a string
/// argument nor a declaration's parameters, not in a rules file (tasks are level script code).
pub fn tasksAt(a: Allocator, t: []const u8, i: usize, where: Where) bool {
    return code.nameStart(t, i) == i and code.stringArgAt(t, i) == null and !where.rules and headerParams(a, t, i, where) == null;
}

/// Takes the list's selected item into `v` (its popup open; `a` for the list): a task's
/// code, a value over the value typed (a bare one in quotes; `8 · grandma_child` as 8), a
/// builtin as its call, any other word over the word before the cursor. False: no list.
pub fn accept(a: Allocator, v: *code.View, where: Where, src: Source) bool {
    if (!v.popup) return false;
    const list = candidates(a, v.buf.str(), v.buf.cursor, v.tasks, where, src);
    v.popup = false;
    if (list.len == 0) return false;
    const word = list[@min(v.popup_sel, list.len - 1)];
    if (v.tasks) {
        v.tasks = false;
        putTask(v, tasks[@min(v.popup_sel, tasks.len - 1)].code) catch {};
        return true;
    }
    if (slot(a, v.buf.str(), v.buf.cursor, where, src)) |sv| {
        const val = word[0 .. std.mem.indexOf(u8, word, " · ") orelse word.len];
        const put = if (sv.quoted or sv.bare) val else std.fmt.allocPrint(a, "\"{s}\"", .{val}) catch return true;
        // A number typed over a class key's string (`fighter = "ft_x"`) goes in without its quotes.
        if (sv.bare and sv.quoted and sv.end < v.buf.str().len) v.buf.replaceSpan(sv.start - 1, sv.end + 1, put) catch {} else v.buf.replaceSpan(sv.start, sv.end, put) catch {};
        return true;
    }
    if (api.find(word)) |f| {
        v.buf.insertCall(if (where.ogs) api.ogsName(f) else f.name, api.sampleArgs(a, f) catch "") catch {};
    } else v.buf.complete(word) catch {};
    return true;
}

/// Task code at the cursor: its lines at the cursor line's indent (CRLF as the text),
/// the cursor in its first `""` with the value list open.
fn putTask(v: *code.View, snippet: []const u8) !void {
    const t = v.buf.str();
    const ls = code.lineStart(t, v.buf.cursor);
    var e = ls;
    while (e < t.len and (t[e] == ' ' or t[e] == '\t')) e += 1;
    const indent = t[ls..@min(e, v.buf.cursor)];
    const nl: []const u8 = if (std.mem.indexOf(u8, t, "\r\n") != null) "\r\n" else "\n";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(v.buf.gpa);
    var it = std.mem.splitScalar(u8, snippet, '\n');
    var first = true;
    while (it.next()) |l| {
        if (!first) {
            try out.appendSlice(v.buf.gpa, nl);
            try out.appendSlice(v.buf.gpa, indent);
        }
        first = false;
        try out.appendSlice(v.buf.gpa, l);
    }
    const at = v.buf.cursor;
    try v.buf.replaceSpan(at, at, out.items);
    if (std.mem.indexOf(u8, out.items, "\"\"")) |q| v.buf.cursor = at + q + 1;
    v.popup = true;
    v.popup_sel = 0;
}

/// The values for the value at the cursor: where its text starts (and ends: what a value
/// taken replaces), whether it is in quotes, whether a value goes in bare (a rules number);
/// a rules value's items are `value · what`. `ref`: a rules field's references the project
/// knows (codecomplete adds them); `block_dir`: a block field's reference, the project's
/// blocks of that folder (`weapons`).
const Slot = struct {
    start: usize,
    end: usize,
    quoted: bool,
    bare: bool = false,
    vals: []const []const u8,
    ref: rulesapi.Ref = .none,
    block_dir: []const u8 = "",
};

/// A rules call around offset `i` (the table's: a nested `list(…)` or `Type(…)` belongs
/// to it), its `(`, and the `field = value` argument at `i` with its doc.
pub const RulesAt = struct { call: *const rulesapi.Call, open: usize, arg: ?code.NamedArg, field: ?*const rulesapi.Field };

pub fn rulesAt(t: []const u8, i: usize) ?RulesAt {
    const s = code.scanTo(t, i);
    if (s.in == .comment) return null;
    var d = s.n;
    while (d > 0) : (d -= 1) {
        const cp = s.call(t, d) orelse return null;
        if (rulesapi.find(cp.name)) |rc| {
            const arg = code.namedArg(t, cp.open, i);
            return .{ .call = rc, .open = cp.open, .arg = arg, .field = if (arg) |x| rulesapi.field(rc, x.name) else null };
        }
    }
    return null;
}

/// The value of the rules field at `i` being typed: its words (an item of a list of
/// them: `resist = [fire, |]`), its `ref` for the project's names; null: nothing to offer.
fn rulesSlot(a: Allocator, t: []const u8, i: usize) ?Slot {
    const r = rulesAt(t, i) orelse return null;
    const f = r.field orelse return null;
    var start = r.arg.?.value_start;
    while (start < t.len and (t[start] == ' ' or t[start] == '\t')) start += 1;
    const quoted = start < t.len and t[start] == '"';
    if (quoted) start += 1;
    if (i < start) return null;
    var words: std.ArrayList([]const u8) = .empty;
    for (f.words) |w| words.append(a, w.name) catch {};
    if (!quoted and start < t.len and t[start] == '[') {
        const ws, const we = wordAround(t, i);
        if (ws <= start or words.items.len == 0) return null;
        return .{ .start = ws, .end = we, .quoted = false, .bare = true, .vals = words.items };
    }
    if (words.items.len == 0 and (f.ref == .none or f.ref == .text)) return null;
    // The value is a slice of `t`: where it ends.
    const vend = @intFromPtr(r.arg.?.value.ptr) - @intFromPtr(t.ptr) + r.arg.?.value.len;
    const end = if (quoted) @max(i, vend -| 1) else @max(i, vend);
    return .{ .start = start, .end = end, .quoted = quoted, .bare = f.words.len == 0, .vals = words.items, .ref = f.ref };
}

/// The identifier around `i`: its start and end.
fn wordAround(t: []const u8, i: usize) struct { usize, usize } {
    var ws = i;
    while (ws > 0 and code.isIdent(t[ws - 1])) ws -= 1;
    var we = i;
    while (we < t.len and code.isIdent(t[we])) we += 1;
    return .{ ws, we };
}

/// At `at`, the start of a statement (only blanks before it on its line) inside a data
/// block (`fighter c_nato {`, found by its braces: the text being typed need not parse):
/// the fields its kind takes (its host's and ancestors', foundation/hosts.ogs) not set in
/// it yet; null: no such place.
fn blockFields(a: Allocator, t: []const u8, at: usize) ?[]const []const u8 {
    var ls = at;
    while (ls > 0 and t[ls - 1] != '\n') ls -= 1;
    if (std.mem.trim(u8, t[ls..at], " \t").len > 0) return null;
    const kind, const open = blockAt(t, ls) orelse return null;
    var h = og.script.hosts.host((og.core.schema.blockHost(kind) orelse return null).name);
    // The block's own text so far: the fields it sets already.
    const body = t[open..at];
    var out: std.ArrayList([]const u8) = .empty;
    while (h) |x| : (h = if (x.parent.len > 0) og.script.hosts.host(x.parent) else null) for (x.fields) |f| {
        var nb: [80]u8 = undefined;
        const stmt = std.fmt.bufPrint(&nb, "{s} =", .{f.name}) catch continue;
        if (std.mem.indexOf(u8, body, stmt) != null) continue;
        for (out.items) |o| {
            if (std.mem.eql(u8, o, f.name)) break;
        } else out.append(a, f.name) catch {};
    };
    return out.items;
}

/// The data block whose `{` line `ls` (a line's start) is inside: its kind (a schema
/// block kind's word, `weapon`) and its `{`; null: none (found by braces: the text being
/// typed need not parse).
fn blockAt(t: []const u8, ls: usize) ?struct { []const u8, usize } {
    var depth: usize = 0;
    var k = ls;
    const open = while (k > 0) {
        k -= 1;
        if (t[k] == '}') depth += 1 else if (t[k] == '{') {
            if (depth == 0) break k;
            depth -= 1;
        }
    } else return null;
    var hs = open;
    while (hs > 0 and t[hs - 1] != '\n') hs -= 1;
    var it = std.mem.tokenizeAny(u8, t[hs..open], " \t");
    const kind = it.next() orelse return null;
    if (og.core.schema.blockHost(kind) == null) return null;
    return .{ kind, open };
}

/// In a data block, the value of `field = …` being typed at `i` (a word, bare; an item of
/// a list: `resist = [fire, |`): what its type takes (foundation/hosts.ogs): an enum's names
/// (`place`: ItemPlace's), `true`/`false`, a weapon's `class`/`attack_zone` the weapon
/// classes of the rules in force; a reference (`weapon`, `item`…) its `block_dir`.
fn blockSlot(a: Allocator, t: []const u8, i: usize) ?Slot {
    var ws = i;
    while (ws > 0 and (code.isIdent(t[ws - 1]) or t[ws - 1] == ':')) ws -= 1;
    var k = ws;
    // In a list (`resist = [fire, |`): back over its items to `[`.
    while (k > 0 and (code.isIdent(t[k - 1]) or t[k - 1] == ' ' or t[k - 1] == ',' or t[k - 1] == ':')) k -= 1;
    const in_list = k > 0 and t[k - 1] == '[';
    if (in_list) k -= 1 else k = ws;
    while (k > 0 and t[k - 1] == ' ') k -= 1;
    if (k < 2 or t[k - 1] != '=' or std.mem.indexOfScalar(u8, "=!<>", t[k - 2]) != null) return null;
    k -= 1;
    while (k > 0 and t[k - 1] == ' ') k -= 1;
    var ns = k;
    while (ns > 0 and code.isIdent(t[ns - 1])) ns -= 1;
    const field = t[ns..k];
    var ls = ns;
    while (ls > 0 and t[ls - 1] != '\n') ls -= 1;
    if (field.len == 0 or std.mem.trim(u8, t[ls..ns], " \t").len > 0) return null;
    const kind, _ = blockAt(t, ls) orelse return null;
    const fd = og.script.hosts.field((og.core.schema.blockHost(kind) orelse return null).name, field) orelse return null;
    const ty = if (in_list and std.mem.startsWith(u8, fd.field.type_name, "list<")) fd.field.type_name[5 .. fd.field.type_name.len - 1] else if (in_list) return null else fd.field.type_name;
    const base: Slot = .{ .start = ws, .end = i, .quoted = false, .bare = true, .vals = &.{} };
    var out: std.ArrayList([]const u8) = .empty;
    if (std.mem.eql(u8, field, "class") or std.mem.eql(u8, field, "attack_zone")) {
        for (og.rules.active.weapon_classes) |r| out.append(a, r.name) catch {};
        for (og.rules.active.patterns) |r| for (out.items) |x| {
            if (std.mem.eql(u8, x, r.name)) break;
        } else out.append(a, r.name) catch {};
    } else if (std.mem.eql(u8, ty, "bool")) {
        out.appendSlice(a, &.{ "true", "false" }) catch {};
    } else if (preludeEnum(ty)) |en| {
        for (en.values) |v| out.append(a, v.name) catch {};
    } else {
        var s = base;
        s.block_dir = if (std.mem.eql(u8, ty, "weapon")) "weapons" else if (std.mem.eql(u8, ty, "item")) "items" else if (std.mem.eql(u8, ty, "character")) "characters" else if (std.mem.eql(u8, ty, "look")) "looks" else return null;
        return s;
    }
    if (out.items.len == 0) return null;
    var s = base;
    s.vals = out.items;
    return s;
}

/// The blocks of folder `dir` among project paths `paths` (`weapons/pistol.ogs`), as
/// data names them (`weapons::pistol`); a subfolder's are not.
fn blockNames(a: Allocator, dir: []const u8, paths: []const []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (paths) |p| {
        if (!std.mem.startsWith(u8, p, dir) or p.len <= dir.len + 1 or p[dir.len] != '/' or !std.mem.endsWith(u8, p, ".ogs")) continue;
        const name = p[dir.len + 1 .. p.len - ".ogs".len];
        if (std.mem.indexOfScalar(u8, name, '/') != null) continue;
        out.append(a, std.fmt.allocPrint(a, "{s}::{s}", .{ dir, name }) catch continue) catch {};
    }
    return out.items;
}

var prelude_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var prelude_unit: ?og.script.ogs.parser.Unit = null;

/// The prelude's enum `name` (engine.ogs: ItemPlace, WeaponKind…, also as
/// `foundation::Side`); null: none.
pub fn preludeEnum(full: []const u8) ?*const og.script.ir.Enum {
    const name = @import("traitinfo.zig").engineName(full) orelse full;
    if (prelude_unit == null) {
        var diag: og.script.ogs.parser.Diagnostic = .{};
        prelude_unit = og.script.ogs.parser.parse(prelude_arena.allocator(), og.script.traits.types, "engine.ogs", &diag) catch return null;
    }
    for (prelude_unit.?.modules) |m| for (m.enums) |e| if (std.mem.eql(u8, e.name, name)) return e;
    return null;
}

// ---------------------------------------------------------------- beside the list

/// A line beside the list: code (a signature, a field) or what it means.
pub const Line = struct { s: []const u8, kind: enum { code, desc } };

/// What goes beside the list for its item `sel`: the declaration the cursor is in
/// (`header`: its parameters, codetips.hintDecl), the builtin whose argument is typed
/// (`arg`: which), lines of their own (a rules call, field or value), the selected
/// builtin's signature and what it does, a game script's example of the selected call.
const Beside = union(enum) {
    none,
    header,
    arg: struct { f: *const api.Fn, arg: usize },
    lines: []const Line,
    builtin: struct { sig: []const u8, desc: []const u8 },
    example: []const u8,
};

pub fn beside(a: Allocator, t: []const u8, i: usize, sel: []const u8, where: Where, src: Source) Beside {
    if (headerParams(a, t, i, where) != null) return .header;
    if (!where.rules and slot(a, t, i, where, src) != null) if (code.argSlot(t, i)) |sl| if (api.find(sl.call.name)) |fp|
        return .{ .arg = .{ .f = fp, .arg = sl.call.arg } };
    if (where.rules) {
        var lines: std.ArrayList(Line) = .empty;
        if (rulesapi.find(sel)) |rc| {
            lines.append(a, .{ .s = signatureOf(a, rc), .kind = .code }) catch {};
            lines.append(a, .{ .s = tx.get(rc.doc), .kind = .desc }) catch {};
        } else if (rulesAt(t, i)) |ra| {
            if (rulesSlot(a, t, i) != null) {
                if (ra.field) |fd| {
                    const val = sel[0 .. std.mem.indexOf(u8, sel, " · ") orelse sel.len];
                    lines.append(a, .{ .s = fieldLine(a, ra.call, fd), .kind = .code }) catch {};
                    const means = src.meaning(src.ctx, a, fd, val);
                    if (means.len > 0) lines.append(a, .{ .s = std.fmt.allocPrint(a, "{s}: {s}", .{ val, means }) catch "", .kind = .desc }) catch {};
                }
            } else if (rulesapi.field(ra.call, sel)) |fd| lines.append(a, .{ .s = fieldLine(a, ra.call, fd), .kind = .code }) catch {};
        }
        if (lines.items.len > 0) return .{ .lines = lines.items };
    }
    if (api.find(sel)) |fp| return .{ .builtin = .{ .sig = std.fmt.allocPrint(a, "{s}{s}", .{ sel, signature(a, fp) }) catch sel, .desc = fnDesc(a, fp, where.ogs) } };
    if (src.example(src.ctx, sel)) |x| return .{ .example = x };
    return .none;
}

/// `Name(field, field, …)`.
pub fn signatureOf(a: Allocator, rc: *const rulesapi.Call) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.print(a, "{s}(", .{rc.name}) catch {};
    for (rc.fields, 0..) |f, k| out.print(a, "{s}{s}", .{ if (k > 0) ", " else "", f.name }) catch {};
    out.append(a, ')') catch {};
    return out.items;
}

/// `name: type = default — what it is` of field `f` of call `rc`.
pub fn fieldLine(a: Allocator, rc: *const rulesapi.Call, f: *const rulesapi.Field) []const u8 {
    const sh = rulesapi.shape(a, rc.name, f.name);
    const doc = tx.get(f.doc);
    if (sh.optional) return tx.alloc(a, tx.code_field_opt, .{ f.name, sh.ty, doc });
    return tx.alloc(a, tx.code_field_line, .{ f.name, sh.ty, if (sh.default.len > 0) sh.default else tx.get(tx.code_required), doc });
}

/// What `f` does (builtins named as `ogs` code calls them, `api.text`), "port only" before it when the original exe lacks it.
pub fn fnDesc(a: Allocator, f: *const api.Fn, ogs: bool) []const u8 {
    const d = api.docText(a, tx.get(f.doc), ogs);
    if (!api.portOnly(f)) return d;
    return std.fmt.allocPrint(a, "[{s}] {s}", .{ tx.get(tx.code_port_only), d }) catch d;
}

/// `(string name, int x, [int dir])`.
pub fn signature(a: Allocator, f: *const api.Fn) []const u8 {
    var buf: [12]api.Param = undefined;
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '(') catch {};
    for (api.params(f, &buf), 0..) |p, k| {
        if (k > 0) out.appendSlice(a, ", ") catch {};
        if (p.optional) out.print(a, "[{s}]", .{p.decl}) catch {} else out.appendSlice(a, p.decl) catch {};
    }
    out.append(a, ')') catch {};
    return out.items;
}

const testing = std.testing;

fn has(vals: []const []const u8, v: []const u8) bool {
    for (vals) |x| if (std.mem.eql(u8, x, v)) return true;
    return false;
}

test "completion: an item of a word list in a rules row" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const t = "Resist(fighter = 1, resist = [fire, ga]);";
    const s = rulesSlot(arena.allocator(), t, std.mem.indexOf(u8, t, "ga]").? + 1).?;
    try testing.expectEqualStrings("ga", t[s.start..s.end]);
    try testing.expectEqual(8, s.vals.len);
    try testing.expect(has(s.vals, "gas") and s.bare);
    // The list's `[` itself: no item.
    try testing.expect(rulesSlot(arena.allocator(), t, std.mem.indexOf(u8, t, "[").?) == null);
}

test "completion: a rules field's words, a reference left to the project" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const t = "WeaponClass(name = \"x\", kind = \"en\");";
    const s = rulesSlot(arena.allocator(), t, std.mem.indexOf(u8, t, "en\"").? + 2).?;
    try testing.expect(s.quoted and has(s.vals, "energy"));
    try testing.expectEqualStrings("en", t[s.start..s.end]);
    const r = "Resist(fighter = 1);";
    const f = rulesSlot(arena.allocator(), r, std.mem.indexOf(u8, r, "1").?).?;
    try testing.expect(f.ref != .none and f.vals.len == 0);
}

test "completion: a block field's values: enum, bool, reference" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const w = "weapon x {\n    place = ha\n}";
    const p = blockSlot(a, w, std.mem.indexOf(u8, w, "ha\n").? + 2).?;
    try testing.expectEqualStrings("ha", w[p.start..p.end]);
    try testing.expect(has(p.vals, "hand"));
    const b = "fighter x {\n    movable = \n}";
    try testing.expect(has(blockSlot(a, b, std.mem.indexOf(u8, b, "= ").? + 2).?.vals, "true"));
    const e = "fighter x {\n    blast_weapon = \n}";
    const rf = blockSlot(a, e, std.mem.indexOf(u8, e, "= ").? + 2).?;
    try testing.expect(rf.vals.len == 0);
    try testing.expectEqualStrings("weapons", rf.block_dir);
    // Not a field's value: a comparison, a line of code.
    const c = "fighter x {\n    fn f() { if (place == ha\n}";
    try testing.expect(blockSlot(a, c, c.len - 2) == null);
}

test "completion: a block's fields not set yet, the blocks of a folder" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = "weapon x {\n    place = hand;\n    \n}";
    const fs = blockFields(a, t, std.mem.lastIndexOf(u8, t, "    ").? + 4).?;
    try testing.expect(!has(fs, "place") and has(fs, "class"));
    const names = blockNames(a, "weapons", &.{ "weapons/pistol.ogs", "weapons/sub/x.ogs", "items/box.ogs", "weapons.ogs" });
    try testing.expectEqual(1, names.len);
    try testing.expectEqualStrings("weapons::pistol", names[0]);
}

/// A project of fixed names for the tests: each kind's list, the anims query kept.
const Fake = struct {
    lists: std.EnumArray(Names, []const []const u8) = .initFill(&.{}),
    actor: []const u8 = "",

    fn src(self: *Fake) Source {
        return .{ .ctx = self, .get = get };
    }

    fn get(ctx: *anyopaque, a: Allocator, what: Names, actor: []const u8, text: []const u8) []const []const u8 {
        _ = a;
        _ = text;
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (what == .anims) self.actor = actor;
        return self.lists.get(what);
    }
};

fn fake() Fake {
    var f: Fake = .{};
    f.lists.set(.levels, &.{ "01__start", "02__lab" });
    f.lists.set(.sounds, &.{ "opentreasure.wav", "door.wav" });
    f.lists.set(.dialogs, &.{"intro.dlg"});
    f.lists.set(.actors, &.{"guard1"});
    f.lists.set(.anims, &.{ "idle", "walk" });
    f.lists.set(.files, &.{ "weapons/pistol.ogs", "items/box.ogs" });
    f.lists.set(.name_ids, &.{ "107 · Grandma", "107 · Grandma again", "108 · Lucy" });
    f.lists.set(.functions, &.{"MyFunc"});
    f.lists.set(.level_names, &.{"door_1"});
    return f;
}

test "completion: a call argument's values by its parameter, a sigil's names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = fake();
    // A sound without its `.wav`, in quotes.
    const t = "PlaySound(\"op";
    const s = slot(a, t, t.len, .{}, f.src()).?;
    try testing.expect(s.quoted and has(s.vals, "opentreasure") and !has(s.vals, "door.wav"));
    try testing.expectEqualStrings("op", t[s.start..s.end]);
    // An actor: the party, then the level's.
    const p = "PlaceActor(\"";
    const ps = slot(a, p, p.len, .{}, f.src()).?;
    try testing.expect(has(ps.vals, "Sullivan") and has(ps.vals, "guard1"));
    // The second argument of an unknown call: nothing.
    try testing.expect(slot(a, "Nope(\"", 6, .{}, f.src()) == null);
    // `~d"`: the dialogs without `.dlg`; `~l"`: the levels.
    const d = "Say(~d\"in";
    try testing.expect(has(slot(a, d, d.len, .{ .ogs = true }, f.src()).?.vals, "intro"));
    const l = "Go(~l\"";
    try testing.expect(has(slot(a, l, l.len, .{ .ogs = true }, f.src()).?.vals, "02__lab"));
}

test "completion: a rules reference's names (one per classic_id), a block reference's blocks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = fake();
    const r = "Resist(fighter = 1";
    const s = slot(a, r, r.len, .{ .rules = true, .ogs = true }, f.src()).?;
    try testing.expectEqual(2, s.vals.len);
    try testing.expectEqualStrings("107 · Grandma", s.vals[0]);
    const b = "fighter x {\n    blast_weapon = \n}";
    const bs = slot(a, b, std.mem.indexOf(u8, b, "= ").? + 2, .{ .ogs = true }, f.src()).?;
    try testing.expectEqual(1, bs.vals.len);
    try testing.expectEqualStrings("weapons::pistol", bs.vals[0]);
}

test "completion: an animation's actor is the call's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = fake();
    const t = "Actor_SetAnimation(\"Ovitz\", \"\");";
    try testing.expect(has(slot(a, t, t.len - 3, .{}, f.src()).?.vals, "walk"));
    try testing.expectEqualStrings("Ovitz", f.actor);
}

test "completion: a callback declaration's parameters from the cursor's on" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cb = for (callbacks.exe) |x| {
        if (x.params.len >= 2) break x;
    } else return error.SkipZigTest;
    const t = try std.fmt.allocPrint(a, "function {s}(", .{cb.name});
    const ps = headerParams(a, t, t.len, .{}).?;
    try testing.expectEqualStrings(cb.params[0].decl, ps[0]);
    // Each, then all of them together.
    try testing.expectEqual(cb.params.len + 1, ps.len);
    try testing.expect(std.mem.indexOf(u8, ps[ps.len - 1], ", ") != null);
    // In a rules file a function is no callback.
    try testing.expect(headerParams(a, t, t.len, .{ .rules = true }) == null);
}

test "completion: the words for a word, by the text's language" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = fake();
    // Classic: the builtin, the game's function, the level's name, the text's own.
    const t = "function MyLocal() {}\nLEVEL_";
    try testing.expect(has(candidates(a, t, t.len, false, .{}, f.src()), "LEVEL_Load"));
    try testing.expect(has(candidates(a, "x = My", 6, false, .{}, f.src()), "MyFunc"));
    try testing.expect(has(candidates(a, "x = door", 8, false, .{}, f.src()), "door_1"));
    try testing.expect(has(candidates(a, t ++ "\nMyL", t.len + 4, false, .{}, f.src()), "MyLocal"));
    // OG Script's keywords; not in Classic.
    try testing.expect(has(candidates(a, "inj", 3, false, .{ .ogs = true }, f.src()), "injects"));
    try testing.expect(!has(candidates(a, "inj", 3, false, .{}, f.src()), "injects"));
    // A rules file: its tables' calls.
    try testing.expect(has(candidates(a, "Resi", 4, false, .{ .rules = true, .ogs = true }, f.src()), "Resist"));
    // The tasks.
    try testing.expectEqual(tasks.len, candidates(a, "", 0, true, .{}, f.src()).len);
    // A data block's statement start: its fields.
    const w = "weapon x {\n    pla\n}";
    try testing.expect(has(candidates(a, w, std.mem.indexOf(u8, w, "pla").? + 3, false, .{ .ogs = true }, f.src()), "place"));
}

fn view(text: []const u8, cursor: usize) !code.View {
    var v: code.View = .{ .buf = try code.Buffer.init(testing.allocator, text), .file = 0, .title = &.{} };
    v.buf.cursor = cursor;
    v.popup = true;
    return v;
}

test "completion: taking a value: in quotes or bare, a number of `n · what`" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = fake();
    // A quoted value replaces what is typed inside the quotes.
    var v = try view("PlaySound(\"op\");", 13);
    defer v.buf.deinit();
    try testing.expect(accept(a, &v, .{}, f.src()));
    try testing.expectEqualStrings("PlaySound(\"opentreasure\");", v.buf.str());
    try testing.expect(!v.popup);
    // A rules reference: the number alone.
    var r = try view("Resist(fighter = 10);", 19);
    defer r.buf.deinit();
    r.popup_sel = 1;
    try testing.expect(accept(a, &r, .{ .rules = true, .ogs = true }, f.src()));
    try testing.expectEqualStrings("Resist(fighter = 108);", r.buf.str());
    // A list item of words.
    var l = try view("Resist(resist = [fire, ga]);", 25);
    defer l.buf.deinit();
    try testing.expect(accept(a, &l, .{ .rules = true, .ogs = true }, f.src()));
    try testing.expectEqualStrings("Resist(resist = [fire, gas]);", l.buf.str());
    // No list open: nothing taken.
    var n = try view("x", 1);
    defer n.buf.deinit();
    n.popup = false;
    try testing.expect(!accept(a, &n, .{}, f.src()));
}

test "completion: taking a builtin puts its call, a task its code at the line's indent" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = fake();
    var v = try view("LEVEL_Lo", 8);
    defer v.buf.deinit();
    try testing.expect(accept(a, &v, .{}, f.src()));
    try testing.expect(std.mem.startsWith(u8, v.buf.str(), "LEVEL_Load(") and std.mem.endsWith(u8, v.buf.str(), ");"));
    // OG Script: its name there.
    const on = api.ogsName(api.find("LEVEL_Load").?);
    var o = try view(on[0 .. on.len - 1], on.len - 1);
    defer o.buf.deinit();
    try testing.expect(accept(a, &o, .{ .ogs = true }, f.src()));
    try testing.expect(std.mem.startsWith(u8, o.buf.str(), on) and o.buf.str()[on.len] == '(');
    // The second task (two lines, CRLF text): indented, the cursor in its first "", the list open.
    var t = try view("{\r\n    \r\n}", 7);
    defer t.buf.deinit();
    t.tasks = true;
    t.popup_sel = 3;
    try testing.expect(accept(a, &t, .{}, f.src()));
    try testing.expectEqualStrings("{\r\n    EnableObject(\"\");\r\n    HERO_EnableEnumerate(\"\", 1);\r\n}", t.buf.str());
    try testing.expectEqual(@as(usize, 7 + "EnableObject(\"".len), t.buf.cursor);
    try testing.expect(t.popup and !t.tasks and t.popup_sel == 0);
}

test "completion: what goes beside the list" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = fake();
    // A builtin's argument: that builtin, the argument at the cursor.
    const p = "PlaySound(\"op";
    const ar = beside(a, p, p.len, "opentreasure", .{}, f.src());
    try testing.expectEqualStrings("PlaySound", ar.arg.f.name);
    try testing.expectEqual(0, ar.arg.arg);
    // The selected builtin: its signature and what it does.
    const b = beside(a, "LEVEL_", 6, "LEVEL_Load", .{}, f.src());
    try testing.expect(std.mem.startsWith(u8, b.builtin.sig, "LEVEL_Load(") and b.builtin.desc.len > 0);
    // A rules call, a rules field's value (a word with its meaning).
    try testing.expect(beside(a, "Resi", 4, "Resist", .{ .rules = true, .ogs = true }, f.src()).lines.len == 2);
    const r = "Resist(resist = [fire, ga]);";
    const rl = beside(a, r, 25, "gas", .{ .rules = true, .ogs = true }, f.src()).lines;
    try testing.expectEqual(.code, rl[0].kind);
    try testing.expect(std.mem.startsWith(u8, rl[1].s, "gas: "));
    // A callback's declaration: its header.
    const cb = callbacks.exe[0];
    const h = try std.fmt.allocPrint(a, "function {s}(", .{cb.name});
    if (cb.params.len > 0) try testing.expect(beside(a, h, h.len, "x", .{}, f.src()) == .header);
    // Nothing known.
    try testing.expect(beside(a, "zz", 2, "zzz", .{}, f.src()) == .none);
}

test "completion: when the list opens as one types, when Ctrl+Space lists the tasks" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = fake();
    try testing.expect(opensOnType(a, "ab", 2, "b", .{}, f.src()));
    try testing.expect(!opensOnType(a, "a", 1, "a", .{}, f.src()));
    try testing.expect(opensOnType(a, "host.", 5, ".", .{ .ogs = true }, f.src()));
    try testing.expect(!opensOnType(a, "host.", 5, ".", .{}, f.src()));
    // A value with known values, nothing typed yet.
    try testing.expect(opensOnType(a, "PlaySound(\"", 11, "\"", .{}, f.src()));
    try testing.expect(tasksAt(a, "\n", 1, .{}));
    try testing.expect(!tasksAt(a, "ab", 2, .{}));
    try testing.expect(!tasksAt(a, "\n", 1, .{ .rules = true }));
    try testing.expect(!tasksAt(a, "PlaySound(\"", 11, .{}));
}

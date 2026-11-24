//! The OG writer: the model of an OpenGorky project — its
//! OG Script items by namespace (`ir.Module`: data blocks, rules rows, components, traits,
//! functions) and its manifest — written as the `src/` layout, one `.ogs` text a
//! file, by `script/ogs/print.zig`. The layout is the writer's convention, not the
//! reader's rule: a block's kind and name pick its file (`characters/<name>.ogs`,
//! `battles/<name>/battle.ogs`…), a row's table its rules file, code its namespace; the
//! reader loads every text into one `ogs/link.zig Program` whatever the file. A
//! location's block goes to `level.ogs`, its objects to `objects.ogs` beside it (its walk
//! paths to `paths.ogs`), its own
//! code (`fn`s, `injects`) to `logic.ogs` (the same block in several texts:
//! script/ogs/levels.zig makes them one); a battle is one `battle.ogs`: its block whole
//! (fields, objects, code) and its namespace's components.
//! An edit of one block rewrites only that block's range in its text (`replaceBlock`):
//! the rest of the file, its comments too, stays byte for byte. Never writes `dist/`.
//! Sees only OG Script and the core's tables (scripts/layercheck.sh: no Classic reader).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const ir = @import("../../script.zig").ir;
const parser = @import("../../script.zig").ogs.parser;
const print = @import("../../script.zig").ogs.print;
const rules = @import("../../rules.zig");
const modules = @import("../../core.zig").modules;

/// `opengorky.mod` of an OpenGorky project; `game`: the installed game's folder
/// (`$OPENGORKY_GAME` overrides it, the reader's business).
pub const Manifest = struct {
    id: []const u8,
    title: []const u8 = "",
    engine: []const u8 = "0.1",
    /// The edition the converted texts came from: `en`, `ru`.
    base: []const u8 = "en",
    /// The one language of the texts on the entities.
    language: []const u8 = "en",
    game: []const u8 = "",
};

const manifest_file = "opengorky.mod";

/// What the writer writes: every item of the project, by namespace (module blocks of any
/// texts, in any order; two with one path are one namespace).
pub const Project = struct { manifest: Manifest, modules: []const ir.Module };

/// One text of `src/`: its path there and what it holds.
pub const File = struct { path: []const u8, unit: parser.Unit };

pub const Error = Allocator.Error || error{BadName};

/// The files of `src/` the items go to, in the order each first gets an item;
/// in a file, a namespace's items keep the model's order.
pub fn layout(a: Allocator, p: Project) Error![]File {
    var b: Builder = .{ .a = a };
    // Levels read with a part of no objects (their `level.ogs`/`battle.ogs`): their
    // objects' part writes no head of its own.
    var heads: std.StringHashMapUnmanaged(void) = .empty;
    // Each top-level block's file by namespace and lower-case name: an archetype's component
    // and its class's trait go beside it (`items/box.ogs`: `item box`, `component box`,
    // `trait Box`).
    var owners: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (p.modules) |m| for (m.entities) |e| if (!isLevel(e.kind)) {
        const k = try ownerKey(a, m.path, e.name);
        if (!owners.contains(k)) try owners.put(a, k, try blockPath(a, e));
    };
    // A hero with a fighter of its name (Medusa: an enemy and a party member) in a file of
    // its own: the editor edits a file's first block.
    var fighters: std.StringHashMapUnmanaged(void) = .empty;
    for (p.modules) |m| for (m.entities) |e| if (std.mem.eql(u8, e.kind, "fighter")) try fighters.put(a, try ownerKey(a, m.path, e.name), {});
    for (p.modules) |m| for (m.entities) |e| if (isLevel(e.kind) and e.children.len == 0) try heads.put(a, try std.fmt.allocPrint(a, "{s} {s}", .{ e.kind, e.name }), {});
    // A level's own code: its `logic.ogs` (its own component there too, not printed apart).
    var level_code: std.StringHashMapUnmanaged([]const u8) = .empty;
    // A level's nested blocks' own code: the file their block went to.
    var nested_own: std.AutoHashMapUnmanaged(*const ir.Component, []const u8) = .empty;
    for (p.modules) |m| for (m.entities) |e| if (isLevel(e.kind) and e.own != null)
        try level_code.put(a, try ownerKey(a, m.path, e.name), if (isBattle(e.kind)) try blockPath(a, e) else try std.fmt.allocPrint(a, "{s}/logic.ogs", .{std.fs.path.dirname(try blockPath(a, e)).?}));
    for (p.modules) |m| {
        for (m.entities) |e| {
            const path = if (std.mem.eql(u8, e.kind, "hero") and fighters.contains(try ownerKey(a, m.path, e.name)))
                try std.fmt.allocPrint(a, "characters/{s}_hero.ogs", .{try fileName(e.name)})
            else
                try blockPath(a, e);
            // A battle whole in its battle.ogs.
            if (!isLevel(e.kind) or isBattle(e.kind)) {
                for (e.children) |c| try nestedOwn(a, &nested_own, c, path);
                try (try b.mod(path, m)).ents.append(a, e);
                continue;
            }
            // Its own code in `logic.ogs` beside its block (script/ogs/levels.zig).
            if (e.own) |o| try (try b.mod(level_code.get(try ownerKey(a, m.path, e.name)).?, m)).ents.append(a, .{ .kind = e.kind, .name = e.name, .fields = &.{}, .attach = &.{}, .own = o, .line = e.line });
            var head = e;
            head.own = null;
            // A level's objects in `objects.ogs` beside its block.
            if (e.children.len == 0) {
                if (e.own == null or e.fields.len + e.vars.len + e.attach.len > 0 or e.base.len > 0) try (try b.mod(path, m)).ents.append(a, head);
                continue;
            }
            head.children = &.{};
            const own = e.fields.len + e.vars.len + e.attach.len > 0 or e.base.len > 0;
            if (own or !heads.contains(try std.fmt.allocPrint(a, "{s} {s}", .{ e.kind, e.name }))) try (try b.mod(path, m)).ents.append(a, head);
            // Its walk paths (`path deska { … }`) in `paths.ogs`, the other objects in `objects.ogs`.
            var objs: std.ArrayList(ir.Entity) = .empty;
            var paths: std.ArrayList(ir.Entity) = .empty;
            for (e.children) |c| try (if (std.mem.eql(u8, c.kind, "path")) &paths else &objs).append(a, c);
            for ([_]struct { []const u8, []const ir.Entity }{ .{ "objects.ogs", objs.items }, .{ "paths.ogs", paths.items } }) |part| if (part[1].len > 0) {
                const file = try std.fmt.allocPrint(a, "{s}/{s}", .{ std.fs.path.dirname(path).?, part[0] });
                for (part[1]) |c| try nestedOwn(a, &nested_own, c, file);
                try (try b.mod(file, m)).ents.append(a, .{ .kind = e.kind, .name = e.name, .fields = &.{}, .attach = &.{}, .children = part[1], .line = e.line });
            };
        }
        for (m.rows) |r| try (try b.mod(rowPath(r), m)).rows.append(a, r);
        for (m.traits) |t| try (try b.mod(owners.get(try ownerKey(a, m.path, t.name)) orelse try codePath(a, m.path, null), m)).traits.append(a, t);
        for (m.enums) |e| try (try b.mod(try codePath(a, m.path, null), m)).enums.append(a, e);
        for (m.structs) |x| try (try b.mod(try codePath(a, m.path, null), m)).structs.append(a, x);
        for (m.components) |c| {
            // A nested block's own code (`04_city/drabinka`, parser block_path): its block's
            // file (printed in the block).
            if (c.own) if (nested_own.get(c)) |file| {
                try (try b.mod(file, m)).comps.append(a, c);
                continue;
            };
            // A block's own code goes to its block's file (the printer writes it in the block).
            const game = for (c.hosts) |h| {
                if (std.mem.eql(u8, h, "game")) break true;
            } else false;
            // A level's own first: a dialog or another block of its name may stand at the root too.
            const owner = (if (c.own) level_code.get(try ownerKey(a, m.path, c.name)) else null) orelse owners.get(try ownerKey(a, m.path, c.name));
            try (try b.mod(if (game) "game.ogs" else owner orelse try codePath(a, m.path, c.name), m)).comps.append(a, c);
        }
        for (m.fns) |f| try (try b.mod(try codePath(a, m.path, null), m)).fns.append(a, f);
    }
    const out = try a.alloc(File, b.files.items.len);
    for (out, b.files.items) |*o, f| {
        const ms = try a.alloc(ir.Module, f.mods.items.len);
        for (ms, f.mods.items) |*x, m| x.* = .{ .path = m.path, .uses = m.uses.items, .fns = m.fns.items, .components = m.comps.items, .traits = m.traits.items, .structs = m.structs.items, .enums = m.enums.items, .entities = m.ents.items, .rows = m.rows.items };
        o.* = .{ .path = f.path, .unit = .{ .modules = ms, .file = f.path } };
    }
    return out;
}

const Builder = struct {
    a: Allocator,
    files: std.ArrayList(FileB) = .empty,

    const FileB = struct { path: []const u8, mods: std.ArrayList(ModB) = .empty };
    const ModB = struct {
        path: []const u8,
        uses: std.ArrayList([]const u8) = .empty,
        fns: std.ArrayList(*const ir.Fn) = .empty,
        comps: std.ArrayList(*const ir.Component) = .empty,
        traits: std.ArrayList(*const ir.Trait) = .empty,
        structs: std.ArrayList(*const ir.Struct) = .empty,
        enums: std.ArrayList(*const ir.Enum) = .empty,
        ents: std.ArrayList(ir.Entity) = .empty,
        rows: std.ArrayList(*const ir.Expr) = .empty,
    };

    /// Namespace `m.path`'s block in file `path`, made on first use; it `use`s what every
    /// module block of that path put there `use`s.
    /// shortcut: the union of the `use`s can make a plain name ambiguous where two blocks of one
    /// namespace with different `use`s land in one file; upgrade if a converted project does that.
    fn mod(self: *Builder, path: []const u8, m: ir.Module) Allocator.Error!*ModB {
        const f = for (self.files.items) |*f| {
            // Any case: `Lock.ogs` and `lock.ogs` are one file on macOS and Windows.
            if (std.ascii.eqlIgnoreCase(f.path, path)) break f;
        } else blk: {
            try self.files.append(self.a, .{ .path = path });
            const f = &self.files.items[self.files.items.len - 1];
            // A text's root namespace is its first module, items or not (`parser.Unit`).
            try f.mods.append(self.a, .{ .path = "" });
            break :blk f;
        };
        const mb = for (f.mods.items) |*x| {
            if (std.mem.eql(u8, x.path, m.path)) break x;
        } else blk: {
            try f.mods.append(self.a, .{ .path = m.path });
            break :blk &f.mods.items[f.mods.items.len - 1];
        };
        for (m.uses) |u| for (mb.uses.items) |x| {
            if (std.mem.eql(u8, x, u)) break;
        } else try mb.uses.append(self.a, u);
        return mb;
    }
};

/// A block name as a file or folder name: no separator, no `.`/`..` (a name is the
/// project's data: it must not write outside `src/`).
fn fileName(n: []const u8) Error![]const u8 {
    if (n.len == 0 or std.mem.eql(u8, n, ".") or std.mem.eql(u8, n, "..")) return error.BadName;
    for (n) |c| if (c == '/' or c == '\\' or c == ':' or c < ' ') return error.BadName;
    return n;
}

fn isLevel(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "level") or std.mem.eql(u8, kind, "battle");
}

fn isBattle(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "battle");
}

/// By the block's kind (a top-level block; the ones inside a level or battle are in its file).
fn blockPath(a: Allocator, e: ir.Entity) Error![]const u8 {
    const n = try fileName(e.name);
    const dirs = [_]struct { []const u8, []const u8 }{
        .{ "fighter", "characters" }, .{ "hero", "characters" }, .{ "look", "looks" },     .{ "weapon", "weapons" },
        .{ "item", "items" },         .{ "scene", "scenes" },    .{ "dialog", "dialogs" }, .{ "obstacle", "obstacles" },
        .{ "actor", "actors" },       .{ "area", "areas" },      .{ "ai_profile", "ai" },
    };
    for (dirs) |d| if (std.mem.eql(u8, e.kind, d[0])) return std.fmt.allocPrint(a, "{s}/{s}.ogs", .{ d[1], n });
    if (std.mem.eql(u8, e.kind, "level")) return std.fmt.allocPrint(a, "locations/{s}/level.ogs", .{n});
    if (std.mem.eql(u8, e.kind, "battle")) return std.fmt.allocPrint(a, "battles/{s}/battle.ogs", .{n});
    if (std.mem.eql(u8, e.kind, "speaker")) return "speakers.ogs";
    if (std.mem.eql(u8, e.kind, "action")) return "actions.ogs";
    if (std.mem.eql(u8, e.kind, "game")) return "game.ogs";
    // A world object outside a level (the layout has none): one file.
    return "other.ogs";
}

/// A rules row's file: its table's (`rules\<file>.ss` as `rules/<file>.ogs`), the interface
/// texts' `texts/ui.ogs`, the examine texts' `texts/examine.ogs`, a row of no table
/// `rules/other.ogs` (the reader reports it).
fn rowPath(r: *const ir.Expr) []const u8 {
    const call = if (r.kind == .call) r.kind.call.text else "";
    if (std.mem.eql(u8, call, "UiText")) return "texts/ui.ogs";
    // The interface's engine settings (`PopupColors(…)`): the interface's text.
    if (rules.adjust_owners.isRecord(.ui, call)) return "ui.ogs";
    if (std.mem.eql(u8, call, "Examine") or std.mem.eql(u8, call, "AreaExamine")) return "texts/examine.ogs";
    // The game-wide AI profile (no fighter, no class): a setting (rules.rowFile).
    if (std.mem.eql(u8, call, rules.AiProfile.call)) {
        const keyed = for (r.kind.call.named) |n| {
            if (std.mem.eql(u8, n.name, "fighter") or std.mem.eql(u8, n.name, "class") or std.mem.eql(u8, n.name, "class_name")) break true;
        } else false;
        if (!keyed) return "rules/settings.ogs";
    }
    inline for (.{ rules.Set, modules.Tables }) |Set| inline for (@typeInfo(Set).@"struct".field_names) |f| {
        const Row = @typeInfo(@FieldType(Set, f)).pointer.child;
        if (std.ascii.eqlIgnoreCase(call, Row.call)) return comptime rules.ogPath(Row.file);
    };
    return "rules/other.ogs";
}

/// Code by namespace: a location's or battle's (`locations::_01_port`: `_` before a
/// leading digit) in its `logic.ogs` (beside the level's own code, its block's part there; every component, an object's or an
/// area trigger's, in `<Name>.ogs` beside it); else a component in `components/<namespace>/<Name>.ogs`
/// (root: `components/<Name>.ogs`), functions, traits, structs and enums in `components/<namespace>.ogs`
/// (root: `components/base.ogs`).
fn codePath(a: Allocator, ns: []const u8, component: ?[]const u8) Error![]const u8 {
    for ([_][]const u8{ "locations", "battles" }) |top| if (std.mem.startsWith(u8, ns, top) and std.mem.startsWith(u8, ns[top.len..], "::")) {
        const rest = ns[top.len + 2 ..];
        var place = rest[0 .. std.mem.indexOf(u8, rest, "::") orelse rest.len];
        if (place.len > 1 and place[0] == '_' and std.ascii.isDigit(place[1])) place = place[1..];
        // An object's component in its own text beside the level's (`box_01_itm.ogs`: the
        // object in objects.ogs attaches it); the level's functions in logic.ogs.
        // The blocks stay in objects.ogs: the parts merge in path order, the objects' order
        // is the exe's.
        // A battle's code all in its battle.ogs.
        if (std.mem.eql(u8, top, "battles")) return std.fmt.allocPrint(a, "{s}/{s}/battle.ogs", .{ top, try fileName(place) });
        if (component) |c| if (!reservedLevelFile(c)) return std.fmt.allocPrint(a, "{s}/{s}/{s}.ogs", .{ top, try fileName(place), try fileName(c) });
        return std.fmt.allocPrint(a, "{s}/{s}/logic.ogs", .{ top, try fileName(place) });
    };
    var dir: std.ArrayList(u8) = .empty;
    try dir.appendSlice(a, "components");
    var it = std.mem.splitSequence(u8, ns, "::");
    if (ns.len > 0) while (it.next()) |part| {
        try dir.append(a, '/');
        try dir.appendSlice(a, try fileName(part));
    };
    if (component) |c| return std.fmt.allocPrint(a, "{s}/{s}.ogs", .{ dir.items, try fileName(c) });
    if (ns.len == 0) return "components/base.ogs";
    return std.fmt.allocPrint(a, "{s}.ogs", .{dir.items});
}

fn ownerKey(a: Allocator, ns: []const u8, name: []const u8) Allocator.Error![]const u8 {
    return std.ascii.allocLowerString(a, try std.fmt.allocPrint(a, "{s}\x00{s}", .{ ns, name }));
}

/// Block `e`'s own code and its nested blocks', in `file` (where `e` is written).
fn nestedOwn(a: Allocator, map: *std.AutoHashMapUnmanaged(*const ir.Component, []const u8), e: ir.Entity, file: []const u8) Allocator.Error!void {
    if (e.own) |o| try map.put(a, o, file);
    for (e.children) |c| try nestedOwn(a, map, c, file);
}

/// A component name whose own file would be one of the level's (`Logic` of an older project, an object named
/// `objects`): it stays in logic.ogs.
fn reservedLevelFile(c: []const u8) bool {
    for ([_][]const u8{ "Logic", "level", "battle", "objects", "logic" }) |r| if (std.ascii.eqlIgnoreCase(c, r)) return true;
    return false;
}

/// File `f` as OG Script text (the printer's format: what reading it back and writing it
/// again gives byte for byte).
pub fn text(a: Allocator, f: File) print.Error![]u8 {
    var aw: Writer.Allocating = .init(a);
    try print.unit(&aw.writer, f.unit);
    return aw.written();
}

pub fn manifest(w: *Writer, m: Manifest) Writer.Error!void {
    try w.print(
        \\# OpenGorky project: OG Script texts in src/ over the installed game's assets.
        \\format = ogs
        \\# The oldest OpenGorky that runs it
        \\engine = {s}
        \\id = {s}
        \\title = {s}
        \\# The edition it was converted from: en, ru
        \\base = {s}
        \\# The texts' language
        \\language = {s}
        \\# The installed game it reads (OPENGORKY_GAME overrides)
        \\game ={s}{s}
        \\
    , .{ m.engine, m.id, m.title, m.base, m.language, if (m.game.len > 0) " " else "", m.game });
}

/// The whole project into folder `dir`: `.gitignore` (`dist/`, the editor's `.og/`), every file of
/// `layout` under `src/`, then `opengorky.mod`. Files there that the model no longer has stay (the
/// converter writes into an empty folder).
pub fn write(io: Io, a: Allocator, dir: Io.Dir, p: Project) !void {
    try dir.writeFile(io, .{ .sub_path = ".gitignore", .data = gitignore });
    for (try layout(a, p)) |f| {
        const path = try std.fmt.allocPrint(a, "src/{s}", .{f.path});
        if (std.fs.path.dirname(path)) |d| try dir.createDirPath(io, d);
        try dir.writeFile(io, .{ .sub_path = path, .data = try text(a, f) });
    }
    // The manifest last: a failure leaves no project, not half of one.
    var mw: Writer.Allocating = .init(a);
    try manifest(&mw.writer, p.manifest);
    try dir.writeFile(io, .{ .sub_path = manifest_file, .data = mw.written() });
}

/// A project's `.gitignore`: the build (`dist/`) and the editor's own files (`.og/`: its
/// save history, the test kit) stay out of git.
pub const gitignore = "dist/\n.og/\n";

// ---------------------------------------------------------------- one block's edit

/// Block `names` (a top-level block, then blocks inside it) of namespace `ns` in `u`; the
/// last one of kind `kind` ("": any kind).
pub fn findBlock(u: parser.Unit, ns: []const u8, names: []const []const u8, kind: []const u8) ?*const ir.Entity {
    for (u.modules) |m| if (std.mem.eql(u8, m.path, ns)) {
        var list = m.entities;
        var found: ?*const ir.Entity = null;
        for (names, 0..) |n, i| {
            found = for (list) |*e| {
                if (std.mem.eql(u8, e.name, n) and (i + 1 < names.len or kind.len == 0 or std.mem.eql(u8, e.kind, kind))) break e;
            } else null;
            list = (found orelse break).children;
        }
        if (found) |e| return e;
    };
    return null;
}

/// Text `src` (file `file`) with block `names` of namespace `ns` replaced by `new` (of
/// its kind), printed at the old one's indentation; everything outside the old block's
/// range is kept byte for byte. A text that does not parse, or has no such block: the error.
pub fn replaceBlock(a: Allocator, src: []const u8, file: []const u8, ns: []const u8, names: []const []const u8, new: ir.Entity, diag: *parser.Diagnostic) (parser.Error || print.Error || error{NoSuchBlock})![]u8 {
    const u = try parser.parse(a, src, file, diag);
    const old = findBlock(u, ns, names, new.kind) orelse return error.NoSuchBlock;
    const line_start = if (std.mem.lastIndexOfScalar(u8, src[0..old.span.start], '\n')) |k| k + 1 else 0;
    const depth = (old.span.start - line_start) / 4;
    var block: Writer.Allocating = .init(a);
    try print.entity(&block.writer, new, depth);
    const printed = block.written();
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, src[0..old.span.start]);
    try out.appendSlice(a, printed[depth * 4 .. printed.len - 1]);
    try out.appendSlice(a, src[old.span.end..]);
    return out.items;
}

/// One statement-sized change inside a block (the editor's OG backend, editor/model_og.zig):
/// only that statement's bytes change (a new one is a line of its own at the block's
/// indentation); the rest of the text, comments inside the block too, stays byte for byte.
pub const Edit = union(enum) {
    /// Field `name` made `value` (a new statement after the last field when it has none),
    /// or dropped (null).
    field: struct { name: []const u8, value: ?*const ir.Expr },
    /// Attach `index` (null: a new one after the last attach) made `new`, or dropped (null).
    attach: struct { index: ?usize, new: ?ir.Attach },
    /// Block `name` inside it (null: a new one, before its `}`) made `new` (printed whole), or
    /// dropped (null).
    child: struct { name: ?[]const u8, new: ?ir.Entity },
};

/// Text `src` (file `file`) with `edit` made in block `names` of namespace `ns`.
/// error.NoSuchBlock: no such block (or field, attach, child to change or drop).
pub fn editBlock(a: Allocator, src: []const u8, file: []const u8, ns: []const u8, names: []const []const u8, edit: Edit, diag: *parser.Diagnostic) (parser.Error || print.Error || error{NoSuchBlock})![]u8 {
    const u = try parser.parse(a, src, file, diag);
    const b = findBlock(u, ns, names, "") orelse return error.NoSuchBlock;
    const line_start = if (std.mem.lastIndexOfScalar(u8, src[0..b.span.start], '\n')) |k| k + 1 else 0;
    const depth = (b.span.start - line_start) / 4;
    var w: Writer.Allocating = .init(a);
    switch (edit) {
        .field => |f| {
            const old: ?ir.Named = for (b.fields) |x| {
                if (std.mem.eql(u8, x.name, f.name)) break x;
            } else null;
            const v = f.value orelse return cut(a, src, (old orelse return error.NoSuchBlock).span);
            try print.fieldStmtAt(&w.writer, .{ .name = f.name, .value = v }, depth + 1);
            if (old) |o| return splice(a, src, o.span.start, o.span.end, w.written());
            const after = if (b.fields.len > 0) b.fields[b.fields.len - 1].span.end else openEnd(src, b.*);
            return insertLine(a, src, after, depth + 1, w.written(), b.*);
        },
        .attach => |x| {
            if (x.new) |n| try print.attachStmt(&w.writer, n);
            if (x.index) |k| {
                if (k >= b.attach.len) return error.NoSuchBlock;
                const sp = b.attach[k].span;
                return if (x.new != null) splice(a, src, sp.start, sp.end, w.written()) else cut(a, src, sp);
            }
            if (x.new == null) return error.NoSuchBlock;
            const after = if (b.attach.len > 0) b.attach[b.attach.len - 1].span.end else if (b.fields.len > 0) b.fields[b.fields.len - 1].span.end else openEnd(src, b.*);
            return insertLine(a, src, after, depth + 1, w.written(), b.*);
        },
        .child => |c| {
            if (c.name) |n| {
                const old = for (b.children) |*x| {
                    if (std.mem.eql(u8, x.name, n)) break x;
                } else return error.NoSuchBlock;
                const new = c.new orelse return cut(a, src, old.span);
                try print.entity(&w.writer, new, depth + 1);
                const p = w.written();
                return splice(a, src, old.span.start, old.span.end, p[(depth + 1) * 4 .. p.len - 1]);
            }
            try print.entity(&w.writer, c.new orelse return error.NoSuchBlock, depth + 1);
            // Before the line of its `}` (its own indentation kept).
            const close = b.span.end - 1;
            const ls = if (std.mem.lastIndexOfScalar(u8, src[0..close], '\n')) |k| k + 1 else 0;
            if (std.mem.trim(u8, src[ls..close], " \t").len == 0) return splice(a, src, ls, ls, w.written());
            return splice(a, src, close, close, try std.mem.concat(a, u8, &.{ "\n", w.written(), src[ls..][0..@min(depth * 4, close - ls)] }));
        },
    }
}

/// Just past block `b`'s `{`.
fn openEnd(src: []const u8, b: ir.Entity) u32 {
    return @intCast((std.mem.indexOfScalarPos(u8, src, b.span.start, '{') orelse b.span.start) + 1);
}

/// `src` with `text` as a new line at `depth` after byte `after` (a statement's end, or a
/// block's `{`); an empty block `{}` opens up.
fn insertLine(a: Allocator, src: []const u8, end: u32, depth: usize, stmt: []const u8, b: ir.Entity) Allocator.Error![]u8 {
    // After a comment ending that line too (it stays with its statement).
    var after = end;
    const le: u32 = @intCast(std.mem.indexOfScalarPos(u8, src, end, '\n') orelse src.len);
    const rest = std.mem.trim(u8, src[end..le], " \t");
    if (rest.len == 0 or std.mem.startsWith(u8, rest, "//")) after = le;
    const pad = try a.alloc(u8, depth * 4);
    @memset(pad, ' ');
    const close = after < src.len and src[after] == '}' and after + 1 == b.span.end;
    const tail: []const u8 = if (close) pad[0 .. (depth - 1) * 4] else "";
    return splice(a, src, after, after, try std.mem.concat(a, u8, &.{ "\n", pad, stmt, if (close) "\n" else "", tail }));
}

/// `src` without span `sp`: its whole line(s) when nothing else is on them.
fn cut(a: Allocator, src: []const u8, sp: ir.Span) Allocator.Error![]u8 {
    var s: usize = sp.start;
    var e: usize = sp.end;
    const ls = if (std.mem.lastIndexOfScalar(u8, src[0..s], '\n')) |k| k + 1 else 0;
    const le = std.mem.indexOfScalarPos(u8, src, e, '\n') orelse src.len;
    if (std.mem.trim(u8, src[ls..s], " \t").len == 0 and std.mem.trim(u8, src[e..le], " \t\r").len == 0) {
        s = ls;
        e = @min(src.len, le + 1);
    }
    return splice(a, src, s, e, "");
}

fn splice(a: Allocator, src: []const u8, s: usize, e: usize, put: []const u8) Allocator.Error![]u8 {
    return std.mem.concat(a, u8, &.{ src[0..s], put, src[e..] });
}

// ---------------------------------------------------------------- og-roundtrip

pub const Text = struct { path: []const u8, data: []const u8 };

/// Why `roundtrip` failed: the file and what.
pub const Mismatch = struct { path: []const u8 = "", what: []const u8 = "", line: u32 = 0 };

/// `og-roundtrip`: the texts of a project's `src/` (paths relative to
/// it, `src/assets/` left out) read as one model and written back without edits give the
/// same files, byte for byte, and each file read back is the IR it was written from.
/// false: `m` says the first file that differs, or the parse error.
pub fn roundtrip(a: Allocator, texts: []const Text, m: *Mismatch) !bool {
    const sorted = try a.dupe(Text, texts);
    std.mem.sort(Text, sorted, {}, struct {
        fn lt(_: void, x: Text, y: Text) bool {
            return std.mem.order(u8, x.path, y.path) == .lt;
        }
    }.lt);
    var all: std.ArrayList(ir.Module) = .empty;
    for (sorted) |t| {
        var diag: parser.Diagnostic = .{};
        const u = parser.parse(a, t.data, t.path, &diag) catch |err| {
            m.* = .{ .path = t.path, .what = @errorName(err), .line = diag.line };
            if (diag.message.len > 0) m.what = diag.message;
            return false;
        };
        try all.appendSlice(a, u.modules);
    }
    const files = try layout(a, .{ .manifest = .{ .id = "" }, .modules = all.items });
    for (files) |f| {
        const data = try text(a, f);
        const orig = for (sorted) |t| {
            if (std.mem.eql(u8, t.path, f.path)) break t.data;
        } else {
            m.* = .{ .path = f.path, .what = "written, but not in the project (an item in a file the layout does not give it)" };
            return false;
        };
        if (!std.mem.eql(u8, orig, data)) {
            const at = std.mem.indexOfDiff(u8, orig, data) orelse 0;
            m.* = .{ .path = f.path, .what = "written back differently", .line = @intCast(1 + std.mem.count(u8, orig[0..@min(at, orig.len)], "\n")) };
            return false;
        }
        var diag: parser.Diagnostic = .{};
        if (!print.same(parser.Unit, f.unit, try parser.parse(a, data, f.path, &diag))) {
            m.* = .{ .path = f.path, .what = "read back as another IR" };
            return false;
        }
    }
    for (sorted) |t| if (for (files) |f| {
        if (std.mem.eql(u8, f.path, t.path)) break false;
    } else true) {
        m.* = .{ .path = t.path, .what = "not written back (empty, or its items belong in other files)" };
        return false;
    };
    return true;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const schema = @import("../../core.zig").schema;
const link = @import("../../script.zig").ogs.link;

/// A hand-written project in that layout (src/tests/og/port): what the OG reader plays.
const test_project = struct {
    const root = "../../tests/og/port/";
    const paths = [_][]const u8{
        "game.ogs",
        "characters/grandma.ogs",
        "characters/grandma_child.ogs",
        "characters/Sullivan.ogs",
        "looks/grandma.ogs",
        "looks/grandma_child.ogs",
        "looks/Sullivan.ogs",
        "weapons/grandma_mad.ogs",
        "weapons/grandma_child.ogs",
        "weapons/fist.ogs",
        "items/bandage.ogs",
        "rules/actions.ogs",
        "rules/ai.ogs",
        "rules/attacks.ogs",
        "rules/battle.ogs",
        "rules/fighters.ogs",
        "rules/fx.ogs",
        "rules/items.ogs",
        "rules/settings.ogs",
        "rules/patterns.ogs",
        "rules/resist.ogs",
        "ui.ogs",
        "rules/weapon_classes.ogs",
        "texts/ui.ogs",
        "speakers.ogs",
        "components/base.ogs",
        "components/Reinforcements.ogs",
        "components/abilities/Calm.ogs",
        "locations/01_port/level.ogs",
        "locations/01_port/logic.ogs",
        "locations/01_port/objects.ogs",
        "battles/01__port_citadel/battle.ogs",
        "scenes/port-arriv_at_port.ogs",
        "dialogs/01__port_citadel.ogs",
    };
    const manifest_text = @embedFile(root ++ manifest_file);
    const texts = blk: {
        var out: [paths.len]Text = undefined;
        for (paths, &out) |p, *o| o.* = .{ .path = p, .data = @embedFile(root ++ "src/" ++ p) };
        break :blk out;
    };
};

/// Any call names a builtin (the engine's are the runtime's: `actor::Place` in a level's
/// logic links in the world, state/hooks.zig).
const AnyBuiltin = struct {
    fn builtin(_: *anyopaque, _: []const u8) ?link.Builtin {
        return .{ .id = 0 };
    }
};

/// Every text of `texts` parsed into one program and linked against the schema
/// (core/schema.zig), as the reader does.
fn linkAll(a: Allocator, texts: []const Text) !void {
    var p: link.Program = .{};
    var ld: link.Diagnostic = .{};
    var units: std.ArrayList(parser.Unit) = .empty;
    for (texts) |t| {
        var diag: parser.Diagnostic = .{};
        try units.append(a, parser.parse(a, t.data, t.path, &diag) catch |err| {
            std.debug.print("{s}:{d}: {s}\n", .{ t.path, diag.line, diag.message });
            return err;
        });
    }
    if (try @import("../../script.zig").ogs.levels.merge(a, units.items)) |x| {
        std.debug.print("{s}:{d}: {s}\n", .{ x.file, x.line, x.message });
        return error.TestUnexpectedResult;
    }
    for (units.items) |u| {
        p.add(a, u, &ld) catch |err| {
            std.debug.print("{s}:{d}: {s}\n", .{ ld.file, ld.line, ld.message });
            return err;
        };
    }
    var dummy: u8 = 0;
    p.link(a, .{ .ctx = &dummy, .builtin = AnyBuiltin.builtin, .schema = schema.blockField }, &ld) catch |err| {
        std.debug.print("{s}:{d}: {s}\n", .{ ld.file, ld.line, ld.message });
        return err;
    };
}

fn expectRoundtrip(a: Allocator, texts: []const Text) !void {
    var m: Mismatch = .{};
    if (!try roundtrip(a, texts, &m)) {
        std.debug.print("og-roundtrip: {s}:{d}: {s}\n", .{ m.path, m.line, m.what });
        return error.TestUnexpectedResult;
    }
}

test "og-roundtrip: the hand-written project reads, links against the schema and is written back byte for byte" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const texts = &test_project.texts;
    try linkAll(a, texts);
    try expectRoundtrip(a, texts);
    var mw: Writer.Allocating = .init(a);
    try manifest(&mw.writer, .{ .id = "port", .title = "Port (test project)" });
    try testing.expectEqualStrings(test_project.manifest_text, mw.written());
    // A file the layout would not give an item: found.
    var moved = texts.*;
    moved[1].path = "characters/granny.ogs";
    var m: Mismatch = .{};
    try testing.expect(!try roundtrip(a, &moved, &m));
    try testing.expectEqualStrings("characters/grandma.ogs", m.path);
}

test "OG writer: a model written into a folder in the project layout, read back the same" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The model as one text: the layout splits it.
    var diag: parser.Diagnostic = .{};
    const u = try parser.parse(a,
        \\module characters { use abilities; fighter grandma { hp = 200; attach Calm(by = 1); } fighter kid { hp = 50; } }
        \\module abilities { component Calm for fighter { param int by = 0; } fn half(x) { return x / 2; } }
        \\Resist(fighter = 125, resist = "fire gas");
        \\Speaker(name = "HQ", portrait = "Head Quarters");
        \\UiText(key = "counter_attack", text = "Контратака");
        \\Nope(x = 1);
        \\level "01_port" { area exit { classic_id = 212; } }
        \\battle "01__port_citadel" { grid_columns = 10; fighter g: characters::grandma { weapon gun: weapons::pistol { place = hand; } } }
        \\module weapons { weapon pistol { place = hand; } }
        \\module locations::_01_port { component PortLogic for level { var int ponton = 1; } }
        \\component Hooks for game { }
        \\fn helper() { return 1; }
        \\speaker HQ { }
    , "model.ogs", &diag);
    const p: Project = .{ .manifest = .{ .id = "port", .title = "Порт", .base = "ru", .language = "ru", .game = "/games/Gorky" }, .modules = u.modules };
    const files = try layout(a, p);
    var got: std.ArrayList(u8) = .empty;
    for (files) |f| try got.print(a, "{s}\n", .{f.path});
    try testing.expectEqualStrings(
        \\locations/01_port/level.ogs
        \\locations/01_port/objects.ogs
        \\battles/01__port_citadel/battle.ogs
        \\speakers.ogs
        \\rules/resist.ogs
        \\ui.ogs
        \\texts/ui.ogs
        \\rules/other.ogs
        \\game.ogs
        \\components/base.ogs
        \\characters/grandma.ogs
        \\characters/kid.ogs
        \\components/abilities/Calm.ogs
        \\components/abilities.ogs
        \\weapons/pistol.ogs
        \\locations/01_port/PortLogic.ogs
        \\
    , got.items);
    // Each namespace keeps its `use`s.
    try testing.expectEqualStrings("module characters {\n    use abilities;\n    fighter grandma {\n        hp = 200;\n        attach Calm(by = 1);\n    }\n}\n", try text(a, files[10]));
    // A location's block and its objects apart; a battle whole in one text.
    try testing.expectEqualStrings("level \"01_port\" {\n    area exit {\n        classic_id = 212;\n    }\n}\n", try text(a, files[1]));
    try testing.expectEqualStrings("battle \"01__port_citadel\" {\n    grid_columns = 10;\n    fighter g: characters::grandma {\n        weapon gun: weapons::pistol {\n            place = hand;\n        }\n    }\n}\n", try text(a, files[2]));
    try testing.expectError(error.BadName, layout(a, .{ .manifest = p.manifest, .modules = (try parser.parse(a, "scene \"../x\" { }", "t", &diag)).modules }));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try write(io, a, tmp.dir, p);
    var buf: [1024]u8 = undefined;
    const mod = try tmp.dir.readFile(io, manifest_file, &buf);
    try testing.expect(std.mem.indexOf(u8, mod, "format = ogs\n") != null);
    try testing.expect(std.mem.indexOf(u8, mod, "game = /games/Gorky\n") != null);
    var texts: std.ArrayList(Text) = .empty;
    for (files) |f| {
        var b2: [4096]u8 = undefined;
        const data = try tmp.dir.readFile(io, try std.fmt.allocPrint(a, "src/{s}", .{f.path}), &b2);
        try texts.append(a, .{ .path = f.path, .data = try a.dupe(u8, data) });
    }
    try expectRoundtrip(a, texts.items);
}

test "OG writer: an edited block rewrites only its range, comments around it stay" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\// The citadel's boss fight. Comments outside the edited block stay.
        \\battle "01__port_citadel" {
        \\    grid_columns = 10;   // the grid
        \\    // Grandma's children.
        \\    fighter grandma_child1: characters::grandma_child {
        \\        hp = 50;    // dies first
        \\        weapon grandma_child1_gun: weapons::grandma_mad { place = hand; }
        \\    }
        \\    fighter grandma_child2: characters::grandma_child { hp = 50; }   // the other
        \\}
        \\
    ;
    var diag: parser.Diagnostic = .{};
    const u = try parser.parse(a, src, "battle.ogs", &diag);
    const old = findBlock(u, "", &.{ "01__port_citadel", "grandma_child1" }, "fighter").?;
    // The model's mutation: hp 50 → 75.
    var fields = try a.dupe(ir.Named, old.fields);
    const v = try a.create(ir.Expr);
    v.* = .{ .line = 0, .kind = .{ .lit = .{ .int = 75 } } };
    fields[0].value = v;
    var new = old.*;
    new.fields = fields;
    const out = try replaceBlock(a, src, "battle.ogs", "", &.{ "01__port_citadel", "grandma_child1" }, new, &diag);
    try testing.expectEqualStrings(
        \\// The citadel's boss fight. Comments outside the edited block stay.
        \\battle "01__port_citadel" {
        \\    grid_columns = 10;   // the grid
        \\    // Grandma's children.
        \\    fighter grandma_child1: characters::grandma_child {
        \\        hp = 75;
        \\        weapon grandma_child1_gun: weapons::grandma_mad {
        \\            place = hand;
        \\        }
        \\    }
        \\    fighter grandma_child2: characters::grandma_child { hp = 50; }   // the other
        \\}
        \\
    , out);
    // Read back: the edited block is the new one, the rest the same model.
    const back = try parser.parse(a, out, "battle.ogs", &diag);
    try testing.expect(print.same(ir.Entity, new, findBlock(back, "", &.{ "01__port_citadel", "grandma_child1" }, "fighter").?.*));
    try testing.expect(print.same(ir.Entity, findBlock(u, "", &.{ "01__port_citadel", "grandma_child2" }, "fighter").?.*, findBlock(back, "", &.{ "01__port_citadel", "grandma_child2" }, "fighter").?.*));
    try testing.expectEqual(old.span.start, findBlock(back, "", &.{ "01__port_citadel", "grandma_child1" }, "fighter").?.span.start);
    try testing.expectError(error.NoSuchBlock, replaceBlock(a, src, "battle.ogs", "", &.{"nope"}, new, &diag));
    // A top-level block of a namespace; the whole text read back is the edited model.
    const src2 = "module characters {\n    // kept\n    fighter grandma { hp = 200; }\n}\n";
    const unit2 = try parser.parse(a, src2, "c.ogs", &diag);
    var g = findBlock(unit2, "characters", &.{"grandma"}, "fighter").?.*;
    g.base = "base";
    try testing.expectEqualStrings("module characters {\n    // kept\n    fighter grandma: base {\n        hp = 200;\n    }\n}\n", try replaceBlock(a, src2, "c.ogs", "characters", &.{"grandma"}, g, &diag));
}

test "OG writer: a statement's edit changes only its bytes (field, attach, inner block)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\battle "b" {
        \\    grid_columns = 10;   // the grid
        \\    attach Waves(n = 1);   // first
        \\    fighter kid: characters::kid {
        \\        hp = 50;    // dies first
        \\    }
        \\    fighter other {}
        \\}
        \\
    ;
    var diag: parser.Diagnostic = .{};
    const T = struct {
        fn lit(al: Allocator, v: i32) !*const ir.Expr {
            const e = try al.create(ir.Expr);
            e.* = .{ .line = 0, .kind = .{ .lit = .{ .int = v } } };
            return e;
        }
    };
    const b: []const []const u8 = &.{"b"};
    // A field set: only its statement; its comment stays.
    try testing.expectEqualStrings(try std.mem.replaceOwned(u8, a, src, "hp = 50;", "hp = 7;"), try editBlock(a, src, "f", "", &.{ "b", "kid" }, .{ .field = .{ .name = "hp", .value = try T.lit(a, 7) } }, &diag));
    // A new field: a line after the last; a field dropped: its line.
    const added = try editBlock(a, src, "f", "", b, .{ .field = .{ .name = "grid_rows", .value = try T.lit(a, 4) } }, &diag);
    try testing.expect(std.mem.indexOf(u8, added, "    grid_columns = 10;   // the grid\n    grid_rows = 4;\n    attach") != null);
    try testing.expectEqualStrings(src, try editBlock(a, added, "f", "", b, .{ .field = .{ .name = "grid_rows", .value = null } }, &diag));
    // An empty block opens up.
    try testing.expect(std.mem.indexOf(u8, try editBlock(a, src, "f", "", &.{ "b", "other" }, .{ .field = .{ .name = "hp", .value = try T.lit(a, 1) } }, &diag), "    fighter other {\n        hp = 1;\n    }\n}\n") != null);
    // An attach's params, a new attach, one dropped.
    const n2 = [_]ir.Named{.{ .name = "n", .value = try T.lit(a, 2) }};
    try testing.expect(std.mem.indexOf(u8, try editBlock(a, src, "f", "", b, .{ .attach = .{ .index = 0, .new = .{ .component = "Waves", .params = &n2, .line = 0 } } }, &diag), "    attach Waves(n = 2);   // first\n") != null);
    const more = try editBlock(a, src, "f", "", b, .{ .attach = .{ .index = null, .new = .{ .component = "Calm", .params = &.{}, .line = 0 } } }, &diag);
    try testing.expect(std.mem.indexOf(u8, more, "// first\n    attach Calm();\n    fighter kid") != null);
    try testing.expectEqualStrings(src, try editBlock(a, more, "f", "", b, .{ .attach = .{ .index = 1, .new = null } }, &diag));
    // An inner block added before the `}`, then dropped.
    const kid2: ir.Entity = .{ .kind = "fighter", .name = "kid2", .base = "characters::kid", .fields = &.{}, .attach = &.{}, .line = 0 };
    const with = try editBlock(a, src, "f", "", b, .{ .child = .{ .name = null, .new = kid2 } }, &diag);
    try testing.expect(std.mem.endsWith(u8, with, "    fighter other {}\n    fighter kid2: characters::kid {\n    }\n}\n"));
    try testing.expectEqualStrings(src, try editBlock(a, with, "f", "", b, .{ .child = .{ .name = "kid2", .new = null } }, &diag));
    try testing.expectError(error.NoSuchBlock, editBlock(a, src, "f", "", b, .{ .field = .{ .name = "nope", .value = null } }, &diag));
}

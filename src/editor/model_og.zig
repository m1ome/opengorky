//! The OG backend of the editor's model: an entity of an
//! OpenGorky project is a data block of a `src/` text (store.og_src). A Store file of
//! `og_src` is its file's main block (the first block of the text: `fighter grandma`,
//! `battle "01__port_citadel"`); an entry `<file>#<inner>/<inner>` is a block inside it
//! (a battle's fighter, its weapon). `model.zig`'s `field`/`set`/`unset`/`setEach` come
//! here for such a file: one API, two backends.
//!
//! Every change goes through the OG writer (compose/og/write.zig `editBlock`): only the
//! statement changed (a field, an attach, an inner block) is written, the rest of the text
//! — comments too — stays byte for byte; each change is one undo step of the text's file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const ir = og.script.ir;
const parser = og.script.ogs.parser;
const print = og.script.ogs.print;
const write = og.compose.og_write;
const schema = og.core.schema;
const Value = og.script.value.Value;
const store_mod = @import("store.zig");
const og_src = store_mod.og_src;
const App = @import("app.zig").App;
const model = @import("model.zig");

/// Store file `file` is an OpenGorky project's block.
pub fn isOg(app: *App, file: usize) bool {
    return file < app.store.files.items.len and std.mem.eql(u8, app.store.files.items[file].archive, og_src);
}

/// A block as the backend finds it: the Store file of its text, its namespace and path of
/// names (`["01__port_citadel", "grandma_child2"]`), the block parsed.
pub const Block = struct {
    text_file: usize,
    path: []const u8,
    ns: []const u8,
    names: []const []const u8,
    e: *const ir.Entity,
    /// Its module's `use`s (its types' names are found from there).
    uses: []const []const u8,
};

/// Parsed texts kept while their text is the same (pages read a block every frame).
/// One pushed out lives to the frame's end (`release`): the frame's layout still holds
/// its names (an edit mid-frame makes a page read more texts than kept).
const Parsed = struct { file: usize, hash: u64, arena: std.heap.ArenaAllocator, unit: ?parser.Unit, next: ?*Parsed = null };
var parsed: [128]?*Parsed = @splat(null);
var parsed_next: usize = 0;
var retired: ?*Parsed = null;

/// The parses pushed out during the last frame freed (its layout is drawn by now).
pub fn release() void {
    while (retired) |p| {
        retired = p.next;
        p.arena.deinit();
        std.heap.page_allocator.destroy(p);
    }
}

/// Store text file `f` parsed (null: it does not parse).
fn unitOf(app: *App, f: usize) ?parser.Unit {
    const t = app.store.text(f);
    const h = std.hash.Wyhash.hash(0, t);
    for (parsed) |p| if (p) |x| if (x.file == f and x.hash == h) return x.unit;
    const p = std.heap.page_allocator.create(Parsed) catch return null;
    p.* = .{ .file = f, .hash = h, .arena = .init(std.heap.page_allocator), .unit = null };
    var diag: parser.Diagnostic = .{};
    const a = p.arena.allocator();
    p.unit = parser.parse(a, a.dupe(u8, t) catch return null, app.store.files.items[f].entry, &diag) catch null;
    if (parsed[parsed_next]) |old| {
        old.next = retired;
        retired = old;
    }
    parsed[parsed_next] = p;
    parsed_next = (parsed_next + 1) % parsed.len;
    return p.unit;
}

/// Block of Store file `file` (an `og_src` entry); null: its text does not parse or has no
/// such block. `a` holds the names.
pub fn blockOf(app: *App, a: Allocator, file: usize) ?Block {
    const entry = app.store.files.items[file].entry;
    const hash = std.mem.indexOfScalar(u8, entry, '#');
    const path = entry[0 .. hash orelse entry.len];
    const tf = if (hash == null) file else app.store.file(og_src, path) catch return null;
    const u = unitOf(app, tf) orelse return null;
    // Its main block: the text's first.
    const m, const main = for (u.modules) |*m| {
        if (m.entities.len > 0) break .{ m, &m.entities[0] };
    } else return null;
    // Its name and kind copied: looking through the folder's other texts below parses them
    // into unitOf's few slots, which may free this text's unit.
    const main_name = a.dupe(u8, main.name) catch return null;
    const main_kind = a.dupe(u8, main.kind) catch return null;
    var names: std.ArrayList([]const u8) = .empty;
    names.append(a, main_name) catch return null;
    if (hash) |k| {
        var it = std.mem.splitScalar(u8, entry[k + 1 ..], '/');
        while (it.next()) |n| if (n.len > 0) names.append(a, n) catch return null;
    }
    if (write.findBlock(u, m.path, names.items, "")) |e| return .{ .text_file = tf, .path = path, .ns = m.path, .names = names.items, .e = e, .uses = m.uses };
    // An object of a level in another text of its folder (`objects.ogs`, the same
    // block: script/ogs/levels.zig): edited where it is written.
    if (names.items.len < 2 or !isLevel(main_kind)) return null;
    const dir = path[0 .. (std.mem.lastIndexOfScalar(u8, path, '/') orelse return null) + 1];
    for (app.store.listing(a, og_src, null, false)) |p| {
        if (!std.mem.startsWith(u8, p, dir) or std.mem.indexOfScalarPos(u8, p, dir.len, '/') != null or std.mem.eql(u8, p, path)) continue;
        const of = app.store.file(og_src, p) catch continue;
        const ou = unitOf(app, of) orelse continue;
        for (ou.modules) |*om| for (om.entities) |*x| if (std.mem.eql(u8, x.kind, main_kind) and std.mem.eql(u8, x.name, main_name)) {
            if (write.findBlock(ou, om.path, names.items, "")) |e| return .{ .text_file = of, .path = p, .ns = om.path, .names = names.items, .e = e, .uses = om.uses };
        };
    }
    return null;
}

/// The objects of level block file `file` (a main `level`/`battle` block) in all its
/// texts (`objects.ogs` too: script/ogs/levels.zig), in their files' path order, in `a`.
pub fn levelObjects(app: *App, a: Allocator, file: usize) []const ir.Entity {
    const b = blockOf(app, a, file) orelse return &.{};
    if (b.names.len > 1 or !isLevel(b.e.kind)) return b.e.children;
    const dir = b.path[0 .. (std.mem.lastIndexOfScalar(u8, b.path, '/') orelse return b.e.children) + 1];
    var out: std.ArrayList(ir.Entity) = .empty;
    for (app.store.listingFrame(og_src, null, true)) |p| {
        if (!std.mem.startsWith(u8, p, dir) or std.mem.indexOfScalarPos(u8, p, dir.len, '/') != null) continue;
        const of = app.store.file(og_src, p) catch continue;
        if (!holdsBlock(app.store.text(of), b.e.kind)) continue;
        const u = unitOf(app, of) orelse continue;
        for (u.modules) |m| for (m.entities) |x| if (std.mem.eql(u8, x.kind, b.e.kind) and std.mem.eql(u8, x.name, b.e.name)) out.appendSlice(a, x.children) catch {};
    }
    return out.items;
}

/// Text `t` has a line opening a `kind` block (`level "01_port" {`): an object's component
/// text beside the level's (`box_01_itm.ogs`) has none, and is not parsed for its objects.
fn holdsBlock(t: []const u8, kind: []const u8) bool {
    var it = std.mem.splitScalar(u8, t, '\n');
    while (it.next()) |line| {
        const l = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, l, kind) and l.len > kind.len and l[kind.len] == ' ') return true;
    }
    return false;
}

fn isLevel(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "level") or std.mem.eql(u8, kind, "battle");
}

/// The Store file of level block `b`'s objects text (a location's `objects.ogs` beside its
/// block's, a battle's its `battle.ogs`): made (`<kind> "<name>" { }`) when the project has none.
fn objectsFile(app: *App, b: Block) !usize {
    const a = app.frame.allocator();
    const dir = b.path[0 .. (std.mem.lastIndexOfScalar(u8, b.path, '/') orelse return error.NoSuchBlock) + 1];
    const path = try std.fmt.allocPrint(a, "{s}{s}", .{ dir, if (std.mem.eql(u8, b.e.kind, "battle")) "battle.ogs" else "objects.ogs" });
    if (app.store.find(og_src, path)) |f| if (!app.store.files.items[f].deleted) return f;
    if (app.store.file(og_src, path)) |f| return f else |_| {}
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.print("{s} ", .{b.e.kind});
    try og.script.ogs.lexer.writeString(&w.writer, b.e.name);
    try w.writer.writeAll(" {\n}\n");
    return app.store.addNew(&.{.{ .archive = og_src, .entry = path, .text = try app.gpa.dupe(u8, w.written()) }});
}

/// The Store file of block `inner` (a name, or `a/b`) inside block file `file`.
pub fn innerFile(app: *App, file: usize, inner: []const u8) !usize {
    const entry = app.store.files.items[file].entry;
    var buf: [512]u8 = undefined;
    const e = if (std.mem.indexOfScalar(u8, entry, '#') != null)
        try std.fmt.bufPrint(&buf, "{s}/{s}", .{ entry, inner })
    else
        try std.fmt.bufPrint(&buf, "{s}#{s}", .{ entry, inner });
    return app.store.file(og_src, e);
}

/// The block's host schema (null: a kind with no object: `look`, `scene`).
pub fn hostOf(b: Block) ?*const schema.Host {
    return schema.blockHost(b.e.kind);
}

/// The file an archetype path names, by the writer's layout (`characters::grandma` →
/// `characters/grandma.ogs`, compose/og/write.zig); null: not in the Store's project.
pub fn archetypeFile(app: *App, base: []const u8) ?usize {
    var buf: [256]u8 = undefined;
    const k = std.mem.lastIndexOf(u8, base, "::") orelse return null;
    const p = std.fmt.bufPrint(&buf, "{s}/{s}.ogs", .{ base[0..k], base[k + 2 ..] }) catch return null;
    std.mem.replaceScalar(u8, p[0..k], ':', '/');
    return app.store.file(og_src, p) catch null;
}

/// A literal's value (`40`, `-2`, `0.5`, `"x"`, `true`); null: a value of another shape
/// (a list, a record, a word: `og_expr` of the view has it).
pub fn litValue(e: *const ir.Expr) ?Value {
    return switch (e.kind) {
        .lit => |v| switch (v) {
            .int, .float, .string => v,
            .bool => |x| .{ .int = @intFromBool(x) },
            else => null,
        },
        .unary => |u| if (u.op == .neg and u.operand.kind == .lit) switch (u.operand.kind.lit) {
            .int => |x| .{ .int = -%x },
            .float => |x| .{ .float = -x },
            else => null,
        } else null,
        else => null,
    };
}

fn fieldOf(e: *const ir.Entity, name: []const u8) ?ir.Named {
    for (e.fields) |f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

/// Field `name` of block file `file` (model.field's OG half): its own value (layer
/// `instance`), else its archetype's (`archetype`), else the schema's default.
pub fn field(app: *App, file: usize, name: []const u8) model.View {
    var v: model.View = .{ .name = name };
    const a = app.frame.allocator();
    const b = blockOf(app, a, file) orelse return v;
    var type_name: []const u8 = "";
    if (hostOf(b)) |h| if (schema.ogField(h, name)) |s| {
        v.type = s.type;
        v.only_og = s.only_og;
        v.value = s.default();
        type_name = s.type_name;
    };
    v.below = v.value;
    if (b.e.base.len > 0) if (archetypeFile(app, b.e.base)) |af| {
        const up = field(app, af, name);
        if (up.og_expr != null) {
            v.value = up.value;
            v.og_expr = up.og_expr;
            v.layer = .archetype;
            v.below = up.value;
            v.below_layer = .archetype;
        }
    };
    if (fieldOf(b.e, name)) |f| {
        // An engine enum's word (`battle_class = grandma`): the number the object holds.
        v.value = litValue(f.value) orelse if (f.value.kind == .word) enumNumber(type_name, f.value.kind.word) orelse wordNumber(name, f.value.kind.word) else null;
        v.og_expr = f.value;
        v.layer = .instance;
        v.own = true;
        v.span = f.span;
    }
    return v;
}

/// The number the object holds for word `word` of field `name` that is no enum's: a
/// weapon class's name (`class = pistol`: its rules'), `action = walk` (−1, none 0).
fn wordNumber(name: []const u8, word: []const u8) ?Value {
    if (std.mem.eql(u8, name, "class") or std.mem.eql(u8, name, "attack_zone")) return .{ .int = og.rules.weaponClassId(word) orelse return null };
    if (std.mem.eql(u8, name, "battle_class")) return .{ .int = og.rules.fighterClassId(word) orelse return null };
    if (std.mem.startsWith(u8, name, "action")) return .{ .int = schema.noAction(word) orelse (og.rules.actionNamed(word) orelse return null).classic_id };
    return null;
}

/// The number of word `word` of the prelude's enum `type_name` (`BattleClass`); null: none.
pub fn enumNumber(type_name: []const u8, word: []const u8) ?Value {
    if (type_name.len == 0) return null;
    const S = struct {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    };
    // shortcut: the prelude parsed for each enum read (a page's few fields per frame).
    defer _ = S.arena.reset(.retain_capacity);
    const e = (schema.engineEnum(S.arena.allocator(), type_name) catch return null) orelse return null;
    return .{ .int = (e.value(word) orelse return null).number orelse return null };
}

/// Text `text` (as typed: `40`, `"x"`, `[1, 2]`, `hand`, `Wave(turn = 3)`) as an OG Script
/// value, in `a`. error.BadValue: not one.
pub fn parseValue(a: Allocator, text: []const u8) !*const ir.Expr {
    const src = try std.fmt.allocPrint(a, "x v {{ v = {s}; }}", .{text});
    var diag: parser.Diagnostic = .{};
    const u = parser.parse(a, src, "value", &diag) catch return error.BadValue;
    if (u.modules.len == 0 or u.modules[0].entities.len == 0 or u.modules[0].entities[0].fields.len != 1) return error.BadValue;
    return u.modules[0].entities[0].fields[0].value;
}

/// `e` as OG Script text, in `a`.
pub fn exprText(a: Allocator, e: *const ir.Expr) []const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    print.expression(&w.writer, e) catch return "?";
    return w.written();
}

/// Block file `file` with `edit` made (one undo step of its text's file).
pub fn edit(app: *App, file: usize, e: write.Edit) !void {
    const a = app.frame.allocator();
    const b = blockOf(app, a, file) orelse return error.NoSuchBlock;
    var diag: parser.Diagnostic = .{};
    const new = try write.editBlock(a, app.store.text(b.text_file), b.path, b.ns, b.names, e, &diag);
    try app.store.replace(b.text_file, try app.gpa.dupe(u8, new));
}

/// Fields `names` of block file `file` made `v` (as typed, `parseValue`): one undo step.
pub fn set(app: *App, file: usize, names: []const []const u8, v: []const u8) !void {
    const a = app.frame.allocator();
    const value = try parseValue(a, v);
    const b = blockOf(app, a, file) orelse return error.NoSuchBlock;
    var text: []const u8 = app.store.text(b.text_file);
    var diag: parser.Diagnostic = .{};
    for (names) |n| text = try write.editBlock(a, text, b.path, b.ns, b.names, .{ .field = .{ .name = n, .value = value } }, &diag);
    try app.store.replace(b.text_file, try app.gpa.dupe(u8, text));
}

/// Field `name` of block file `file` made the value `e` (a record or list built by a page).
pub fn setExpr(app: *App, file: usize, name: []const u8, e: *const ir.Expr) !void {
    return edit(app, file, .{ .field = .{ .name = name, .value = e } });
}

/// `set` of several fields, each its own value: one undo step.
pub fn setEach(app: *App, file: usize, pairs: []const [2][]const u8) !void {
    const a = app.frame.allocator();
    const b = blockOf(app, a, file) orelse return error.NoSuchBlock;
    var text: []const u8 = app.store.text(b.text_file);
    var diag: parser.Diagnostic = .{};
    for (pairs) |p| text = try write.editBlock(a, text, b.path, b.ns, b.names, .{ .field = .{ .name = p[0], .value = try parseValue(a, p[1]) } }, &diag);
    try app.store.replace(b.text_file, try app.gpa.dupe(u8, text));
}

/// A weapon's ammo picked: item archetype `pick` (`items::x`)
/// as `ammo = ~i"…"`, `thrown` as `thrown = true`, `none` as neither (`thrown = false`
/// where its archetype gives it ammo, the reader's 0 over it). One undo step.
pub fn setAmmo(app: *App, file: usize, pick: []const u8) !void {
    const a = app.frame.allocator();
    const b = blockOf(app, a, file) orelse return error.NoSuchBlock;
    const item = std.mem.indexOf(u8, pick, "::") != null;
    const ammo: ?*const ir.Expr = if (item) try parseValue(a, try std.fmt.allocPrint(a, "~i\"{s}\"", .{pick})) else null;
    const inherited = if (archetypeFile(app, b.e.base)) |af| model.field(app, af, "ammo").og_expr != null or thrownOf(app, af) else false;
    const thrown: ?*const ir.Expr = if (std.mem.eql(u8, pick, "thrown")) try parseValue(a, "true") else if (!item and inherited) try parseValue(a, "false") else null;
    var diag: parser.Diagnostic = .{};
    var text: []const u8 = app.store.text(b.text_file);
    // A field taken out that the block does not set: skipped (as `unset`).
    for ([_]struct { []const u8, ?*const ir.Expr }{ .{ "ammo", ammo }, .{ "thrown", thrown } }) |x| {
        text = write.editBlock(a, text, b.path, b.ns, b.names, .{ .field = .{ .name = x[0], .value = x[1] } }, &diag) catch |err| switch (err) {
            error.NoSuchBlock => if (x[1] == null) continue else return err,
            else => return err,
        };
    }
    try app.store.replace(b.text_file, try app.gpa.dupe(u8, text));
}

/// Weapon block file `file` is thrown (`thrown = true`, its own or its archetype's).
fn thrownOf(app: *App, file: usize) bool {
    const e = model.field(app, file, "thrown").og_expr orelse return false;
    return e.kind == .lit and e.kind.lit == .bool and e.kind.lit.bool;
}

/// The own fields `names` of block file `file` dropped (back to its archetype's or the
/// schema's): one undo step; a name it does not set is skipped.
pub fn unset(app: *App, file: usize, names: []const []const u8) !void {
    const a = app.frame.allocator();
    const b = blockOf(app, a, file) orelse return error.NoSuchBlock;
    var text: []const u8 = app.store.text(b.text_file);
    var diag: parser.Diagnostic = .{};
    for (names) |n| text = write.editBlock(a, text, b.path, b.ns, b.names, .{ .field = .{ .name = n, .value = null } }, &diag) catch |err| switch (err) {
        error.NoSuchBlock => continue,
        else => return err,
    };
    if (text.ptr != app.store.text(b.text_file).ptr) try app.store.replace(b.text_file, try app.gpa.dupe(u8, text));
}

/// Block file `file` deleted: an inner block's statement removed from its parent, a main
/// block's file deleted from `src/` on save. One undo step.
pub fn remove(app: *App, file: usize) !void {
    const a = app.frame.allocator();
    const b = blockOf(app, a, file) orelse return error.NoSuchBlock;
    if (b.names.len == 1) return app.store.delete(&.{b.text_file});
    var diag: parser.Diagnostic = .{};
    const new = try write.editBlock(a, app.store.text(b.text_file), b.path, b.ns, b.names[0 .. b.names.len - 1], .{ .child = .{ .name = b.names[b.names.len - 1], .new = null } }, &diag);
    try app.store.replace(b.text_file, try app.gpa.dupe(u8, new));
}

/// A new block `kind name: base { }` inside block file `file`, before its `}`; a level's
/// object goes to its objects text (`objects.ogs`, made when missing), as the writer
/// lays a level out. One undo step.
pub fn addInner(app: *App, file: usize, kind: []const u8, name: []const u8, base: []const u8) !void {
    return addInnerBlock(app, file, .{ .kind = kind, .name = name, .base = base, .fields = &.{}, .attach = &.{}, .line = 0 });
}

/// `addInner` of block `new` as given (its fields and attaches too).
pub fn addInnerBlock(app: *App, file: usize, new: ir.Entity) !void {
    const e: write.Edit = .{ .child = .{ .name = null, .new = new } };
    const b = blockOf(app, app.frame.allocator(), file) orelse return error.NoSuchBlock;
    if (b.names.len > 1 or !isLevel(b.e.kind)) return edit(app, file, e);
    app.store.group();
    defer app.store.endGroup("+ {s}", .{new.name});
    return edit(app, try objectsFile(app, b), e);
}

/// A name for a new inner block of block `b`: `stem`, else `stem_2`, `stem_3`…
pub fn freeInner(a: Allocator, b: Block, stem: []const u8) []const u8 {
    var k: usize = 1;
    while (true) : (k += 1) {
        const n = if (k == 1) stem else std.fmt.allocPrint(a, "{s}_{d}", .{ stem, k }) catch return stem;
        for (b.e.children) |c| {
            if (std.mem.eql(u8, c.name, n)) break;
        } else return n;
    }
}

// ---------------------------------------------------------------- tests

test "OG values: literals as the model shows them, typed text read as OG Script" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Value{ .int = -2 }, litValue(try parseValue(a, "-2")).?);
    try std.testing.expectEqualStrings("x", litValue(try parseValue(a, "\"x\"")).?.string);
    try std.testing.expect(litValue(try parseValue(a, "[1, 2]")) == null);
    try std.testing.expectEqualStrings("Wave(turn = 3, side = enemy)", exprText(a, try parseValue(a, "Wave(turn = 3, side = enemy)")));
    try std.testing.expectError(error.BadValue, parseValue(a, "1; y = 2"));
    try std.testing.expectError(error.BadValue, parseValue(a, "(("));
}

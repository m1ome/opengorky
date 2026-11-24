//! An entry's identity on its page (og.rules): in an OpenGorky project its classic_id is a
//! field (only the number of its texts), and the "Rules" section lists the rule rows
//! naming it (by its class or its classic_id), each opening its rules file at that row;
//! "Make own rules" (and every copy) writes rows by its class, cloned from the rows in
//! force. In Classic both are locked: the exe keys everything by classic_id.

const std = @import("std");
const Allocator = std.mem.Allocator;
const clay = @import("clay.zig");
const model = @import("model.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const Entry = @import("catalog.zig").Entry;
const doctabs = @import("doctabs.zig");
const og = @import("opengorky");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const rules = og.rules;
const rules_text = og.loaders.rules_text;
const rules_rows = @import("rules_rows.zig");
const store_mod = @import("store.zig");

/// The class its rows are keyed by: its script's stem (`ft_hornet`, `cw_riffle_2`, `ovitz`),
/// what a level's object includes (rules.classOf).
pub fn classOf(e: Entry) []const u8 {
    if (e.class.len > 0) return e.class;
    return rules.stem(e.entry);
}

/// A class without its file path or module (`weapons::medusalong` → `medusalong`,
/// `wp_fang.ss` → `wp_fang`): the catalog entry's id it names.
pub fn bareClass(class: []const u8) []const u8 {
    const s = rules.stem(class);
    return if (std.mem.lastIndexOf(u8, s, "::")) |k| s[k + 2 ..] else s;
}

/// Store indices of an OpenGorky project's texts: every `.ogs` of its `src/` (rows, code
/// and data blocks: the OG reader reads them all, loaders/ogs.zig), then those made this session.
fn files(app: *App, a: Allocator) []usize {
    var out: std.ArrayList(usize) = .empty;
    for (app.store.listing(a, store_mod.og_src, null, false)) |n| out.append(a, app.store.file(store_mod.og_src, n) catch continue) catch break;
    return out.items;
}

/// Hash of the rules files the rules in force were last read from.
var synced: u64 = 0;
/// Store.rev when the rules files were last hashed (no change since: not hashed again).
var synced_rev: u64 = std.math.maxInt(u64);

/// The editor's rules in force (previews, the rows here, copies) follow the rules files'
/// unsaved edits: at each frame's start (app_mod.frame) and scripted edit's, and after each
/// row written (rules_rows), so code Apply, undo, discard and history are followed too.
/// Hashed again only after a Store change (Store.rev): one edit elsewhere keeps them.
pub fn sync(app: *App) void {
    if (!app.ogLayout() or app.store.rev == synced_rev) return;
    synced_rev = app.store.rev;
    const fs = files(app, app.frame.allocator());
    var h = std.hash.Wyhash.init(0);
    for (fs) |f| {
        h.update(app.store.files.items[f].entry);
        h.update(app.store.text(f));
    }
    if (h.final() == synced) return;
    synced = h.final();
    const texts = app.frame.allocator().alloc(rules_text.Text, fs.len) catch return;
    for (fs, texts) |f, *t| t.* = .{ .name = app.store.files.items[f].entry, .data = app.store.text(f) };
    rules_text.reloadOg(texts) catch {};
    og.loaders.ogs.reparse(texts) catch {};
    // The catalog's numbers the OG reader's (a block of no classic_id has its path's).
    for (app.catalog.entries.items) |*e| if (std.mem.indexOf(u8, e.class, "::") != null) if (og.core.entity.idOf(e.class)) |n| {
        e.name_id = n;
    };
    // The open levels' actors follow: their native components read anew.
    if (app.doc) |d| reattachNatives(d.world);
    for (app.parked.items) |p| if (p.doc) |d| reattachNatives(d.world);
}

/// World `w`'s actors' native components from the rules in force (core/natives.zig
/// reattach); out of memory leaves the rest as they were.
fn reattachNatives(w: *og.state.world.World) void {
    for (w.rt.objects.items) |o| if (og.state.world.World.nativeOf(o).kind == .actor) og.core.natives.reattach(&w.rt, o) catch return;
}

/// Rows of `to`'s own, cloned from `from`'s in force, put by their keys into their rules
/// files (rules_rows: a row of the same key replaced, never a second one; a file missing
/// is made; one undo step per file changed). `only_id`: `from` is `to` making its own (its classic_id
/// rows only; a row it has by that key already stays as it is).
pub fn writeOwn(app: *App, from: rules.Who, to: rules.Who, only_id: bool) !void {
    // Own rules are the layer's (common/rules.dat): the exe reads none (the page locks it too).
    if (!app.ogLayout()) return error.ClassicProject;
    app.store.group();
    defer app.store.endGroup("{s}: own rules", .{to.class});
    var sink: OwnRows = .{ .app = app, .keep = only_id, .id = from.id, .unique = rules_rows.idOnlyOf(app, to) };
    try rules_text.cloneRows(from, to, only_id, &sink);
    for (rules.files, sink.texts) |name, text| if (text) |t| try rules_rows.putIn(app, name, try app.gpa.dupe(u8, t));
    // A weapon's effects are the exe's code by classic_id: the copy keeps its original's
    // (its block's `effects_from` when it has none of its own: the original's, else its
    // classic_id).
    // (Not a Classic-layout copy's `classes\cw_x.s`: no block, its classic_id is its effects.)
    if (from.id > 0 and from.id != to.id) if (weaponFile(app, to.class)) |f| if (model.model_og.isOg(app, f) and !model.field(app, f, "effects_from").own) {
        const own = if (weaponFile(app, from.class)) |ff| model.field(app, ff, "effects_from").og_expr else null;
        const v = if (own) |x| og.core.schema.text(x) orelse try std.fmt.allocPrint(app.frame.allocator(), "{d}", .{og.core.schema.int(x) orelse from.id}) else try std.fmt.allocPrint(app.frame.allocator(), "{d}", .{from.id});
        try @import("entry_attacks.zig").setFx(app, to.class, "effects_from", v);
    };
    sync(app);
}

/// The block file of weapon class `class` (an OpenGorky archetype's); null: none.
pub fn weaponFile(app: *App, class: []const u8) ?usize {
    for (app.catalog.entries.items) |e| if (e.kind == .weapon and std.ascii.eqlIgnoreCase(classOf(e), class)) return app.store.file(e.archive, e.entry) catch null;
    return null;
}

/// writeOwn's rows put into its rules files' texts (null: not changed).
const OwnRows = struct {
    app: *App,
    /// A row of the key already there stays.
    keep: bool = false,
    texts: [rules.files.len]?[]const u8 = @splat(null),
    /// Making its own (`keep`): its classic_id, whose project row is re-keyed in place.
    id: i32 = 0,
    /// No other class has that classic_id: re-keyed in place; else copied (the others keep it).
    unique: bool = true,

    pub fn row(self: *OwnRows, comptime Row: type, r: Row) !void {
        const k = comptime for (rules.files, 0..) |n, i| {
            // One text per project file (party's and adjust's rows share settings.ogs).
            if (std.mem.eql(u8, rules.ogFile(n), rules.ogFile(Row.file))) break i;
        } else unreachable;
        const a = self.app.frame.allocator();
        const old = self.texts[k] orelse if (self.app.store.file(store_mod.og_src, rules_rows.entryOf(Row))) |f| self.app.store.text(f) else |_| "";
        if (self.keep and rules_rows.span(a, Row, old, r) != null) return;
        // The row it was cloned from, by classic_id (a converted project's): re-keyed where it stands.
        var at = r;
        if (self.keep and self.id > 0 and self.unique) inline for (rules.entity_keys) |key| if (@hasField(Row, key ++ "_class")) {
            if (@field(r, key ++ "_class").len > 0 and @field(r, key) == 0) {
                @field(at, key) = self.id;
                @field(at, key ++ "_class") = "";
            }
        };
        self.texts[k] = try rules_rows.putTextAt(a, a, Row, old, at, r);
    }
};

/// The catalog's number of entry `idx` in step with its classic_id field (OpenGorky, where
/// the field changes it; shown or folded).
pub fn syncClassicId(app: *App, idx: usize, id: i32) void {
    if (app.ogLayout()) app.catalog.entries.items[idx].name_id = if (id > 0) id else null;
}

/// OpenGorky: the block's `same_as` (the block it is one thing with: a path word, a level
/// object's "level/name"), typed in place; under it the entries that are one with it (the
/// reader gave them one number, `id`).
pub fn sameAsRow(app: *App, a: Allocator, idx: usize, file: usize, id: i32) void {
    const own = model.field(app, file, "same_as");
    const shown = if (own.own) if (own.og_expr) |x| model.model_og.exprText(a, x) else "" else "";
    gui.fieldRow(tx.get(tx.c_same_as));
    if (gui.textField(app, "ent_same_as", shown, 0, tx.get(tx.c_same_as_none))) |v| setSameAs(app, a, file, v) catch |err| app.failed(err);
    clay.close();
    var names: std.ArrayList(u8) = .empty;
    for (app.catalog.entries.items, 0..) |x, i| if (i != idx and id > 0 and x.name_id == id) {
        if (names.items.len > 0) names.appendSlice(a, ", ") catch {};
        names.appendSlice(a, if (x.title.len > 0) x.title else x.id) catch {};
    };
    if (names.items.len > 0) gui.fieldNote(tx.alloc(a, tx.same_as_with, .{names.items}), theme.dim);
}

/// `same_as` made `v`: "" unsets it, a "level/name" is a string, a path a word.
fn setSameAs(app: *App, a: Allocator, file: usize, v: []const u8) !void {
    const t = std.mem.trim(u8, v, " \t\"");
    if (t.len == 0) try model.model_og.unset(app, file, &.{"same_as"}) else if (std.mem.indexOfScalar(u8, t, '/') != null)
        try model.model_og.set(app, file, &.{"same_as"}, try std.fmt.allocPrint(a, "\"{s}\"", .{t}))
    else
        try model.model_og.set(app, file, &.{"same_as"}, t);
    app.catalog.gen +%= 1;
    sync(app);
}

/// The shown entry's classic_id made `v` (the string.tab row chosen): OpenGorky only, where it
/// is only the number of its texts; written where its field writes it.
pub fn setClassicId(app: *App, file: usize, v: []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const e = app.catalog.entries.items[app.entry orelse return error.NoEntry];
    try model.set(app, file, &.{"classic_id"}, v, if (e.kind == .enemy) "#include act_" else "{");
    app.refreshTitles();
}

/// A classic_id no text row, class nor hero has, past the game's (its largest is 1081; the
/// exe sizes its tables by the largest, 0x40f5ce). Above 139: never a monster's rules.
pub fn freshClassicId(app: *App) i32 {
    const texts = @import("texts.zig");
    var id = texts.freeId(app, .strings, 2000);
    while (texts.get(app, app.frame.allocator(), .items, id) != null or taken(app, id)) id = texts.freeId(app, .strings, id + 1);
    return id;
}

fn taken(app: *App, id: i32) bool {
    for (app.catalog.entries.items) |x| if (x.name_id == id) return true;
    return false;
}

/// A rule row naming an entry: its file, line and text, and whether by class.
const RuleRow = struct { file: usize, at: usize, line_no: u32, text: []const u8, by_class: bool };

/// The rows naming `w` (its class's first), read again when the rules files change (the
/// header's count reads them folded too).
fn ruleRows(app: *App, w: rules.Who) []const RuleRow {
    var h = std.hash.Wyhash.init(app.store.rev);
    h.update(std.mem.asBytes(&app.catalog.gen));
    h.update(w.class);
    h.update(std.mem.asBytes(&w.id));
    if (row_cache.arena != null and row_cache.key == h.final()) return row_cache.rows;
    if (row_cache.arena) |*ar| _ = ar.reset(.retain_capacity) else row_cache.arena = .init(app.gpa);
    const a = row_cache.arena.?.allocator();
    var out: std.ArrayList(RuleRow) = .empty;
    for ([_]rules_text.Match{ .class, .id }) |want| for (files(app, a)) |f| {
        const text = app.store.text(f);
        var diag: og.script.ogs.parser.Diagnostic = .{};
        for (og.loaders.codec.parseRows(a, text, &diag) orelse continue) |ex| {
            if (rules_text.rowFor(a, ex.kind.call, w) != want) continue;
            const at = @import("code.zig").lineOffset(text, ex.line);
            const line = std.mem.trim(u8, text[at .. std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len], " \t\r");
            out.append(a, .{ .file = f, .at = at, .line_no = ex.line, .text = a.dupe(u8, line) catch "", .by_class = want == .class }) catch {};
        }
    };
    row_cache.key = h.final();
    row_cache.rows = out.items;
    return row_cache.rows;
}

var row_cache: struct { arena: ?std.heap.ArenaAllocator = null, key: u64 = 0, rows: []const RuleRow = &.{} } = .{};

pub fn deinit() void {
    if (row_cache.arena) |*ar| ar.deinit();
    row_cache = .{};
    synced_rev = std.math.maxInt(u64);
}

/// The "Rules" block: whether its values are its own rows (by its class) or shared (by its
/// classic_id, with the other classes having it), switched to own by copying them (writeOwn);
/// the rows naming it (its class's first), each own or shared, opening its file at the row.
/// Classic: locked.
pub fn section(app: *App, a: Allocator, e: Entry, id: i32) void {
    const w: rules.Who = .{ .id = id, .class = classOf(e) };
    const rows: []const RuleRow = if (app.ogLayout()) ruleRows(app, w) else &.{};
    var n_own: usize = 0;
    for (rows) |r| n_own += @intFromBool(r.by_class);
    if (!gui.block(app, "rules", tx.get(tx.at_rules), .{ .folded = true, .og = true, .summary = tx.alloc(a, tx.sum_own_rows, .{ n_own, rows.len - n_own }) })) return;
    defer gui.blockEnd();
    // Own: a copy by class (copy-on-write); back to shared only in the rules code.
    gui.fieldRow(tx.get(tx.rules_values));
    if (gui.segmented(app, "rules_own", &.{ tx.get(tx.rules_shared), tx.get(tx.rules_own) }, @intFromBool(n_own > 0))) |k| {
        if (k == 1 and n_own == 0) {
            writeOwn(app, w, w, true) catch |err| app.failed(err);
            app.setStatus(tx.st_rules_own, .{w.class});
        } else if (k == 0 and n_own > 0) app.setStatus(tx.st_rules_keep_own, .{w.class});
    }
    clay.close();
    var others: std.ArrayList(u8) = .empty;
    for (app.catalog.entries.items) |x| if (id > 0 and x.name_id == id and !std.ascii.eqlIgnoreCase(classOf(x), w.class)) {
        if (others.items.len > 0) others.appendSlice(a, ", ") catch {};
        others.appendSlice(a, if (x.title.len > 0) x.title else x.id) catch {};
    };
    gui.fieldNote(tx.alloc(a, tx.rules_share_note, .{ id, if (others.items.len > 0) others.items else "—", w.class }), theme.dim);
    for (rows, 0..) |r, k| {
        const where = std.fmt.allocPrint(a, "{s}:{d}", .{ app.store.files.items[r.file].entry, r.line_no }) catch "";
        if (gui.listRow(app, clay.idi("rule_row", @intCast(k)), .{ .fit = true, .indent = lay.space.xs })) doctabs.showCode(app, r.file, r.at);
        gui.stack(0);
        gui.txtWrap(r.text, .body, theme.text, font_mod.regular);
        gui.row(lay.space.sm);
        gui.chip(tx.get(if (r.by_class) tx.rules_own else tx.rules_shared));
        gui.txt(where, .caption, theme.dim, font_mod.regular);
        clay.close();
        clay.close();
        clay.close();
    }
    if (rows.len == 0) gui.note(tx.get(tx.rules_none));
}

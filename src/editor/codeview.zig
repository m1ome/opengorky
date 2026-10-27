//! Code window: any script file (level, area, class, hero, scene) as editable text with
//! highlighting and completion of the functions the game's scripts call (an example
//! call of each beside the list). A function taken from the list comes with sample
//! arguments, Tab going through them; inside a call its parameters show above the line,
//! and F1 opens the functions' help (api.zig). Saving (the editor's one Save) puts the text into the Store as one undo
//! step; the game's encoding is kept (code.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const ui = @import("ui");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const code = @import("code.zig");
const api = @import("api.zig");
const refs_mod = @import("refs.zig");
const og = @import("opengorky");
const main = @import("app.zig");
const icons = @import("icons.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;

const pt: u16 = 15;
const line_h: f32 = 21;
const gutter: f32 = 56;

const View = code.View;

/// Opens Store file `file` (its cursor at byte `at` of the game text, if given).
pub fn open(app: *App, file: usize, at: ?usize) void {
    // Open already (shown or in another tab): shown, the cursor moved.
    const have = if (app.code) |v| v.file == file else false;
    if (!have) {
        park(app);
        for (app.code_parked.items, 0..) |pv, k| if (pv.file == file) {
            app.code = app.code_parked.orderedRemove(k);
            break;
        };
    }
    if (app.code) |v| {
        if (at) |g| moveTo(app, v, g);
        return;
    }
    const bytes = app.store.text(file);
    const utf8 = code.fromGame(app.gpa, bytes, app.catalog.cyrillic) catch return;
    defer app.gpa.free(utf8);
    const v = app.gpa.create(View) catch return;
    v.* = .{ .buf = code.Buffer.init(app.gpa, utf8) catch return app.gpa.destroy(v), .file = file, .title = app.gpa.dupe(u8, app.store.files.items[file].entry) catch "" };
    app.code = v;
    if (at) |g| moveTo(app, v, g);
}

/// The cursor to byte `g` of the game text (its line: UTF-8 and game text count lines alike).
fn moveTo(app: *App, v: *View, g: usize) void {
    const bytes = app.store.text(v.file);
    var line: usize = 0;
    for (bytes[0..@min(g, bytes.len)]) |ch| line += @intFromBool(ch == '\n');
    var i: usize = 0;
    var n: usize = 0;
    while (i < v.buf.str().len and n < line) : (i += 1) n += @intFromBool(v.buf.str()[i] == '\n');
    v.buf.cursor = i;
    v.scroll = line -| 4;
}

/// The shown code kept in its tab (another document comes to the centre).
pub fn park(app: *App) void {
    const v = app.code orelse return;
    app.code = null;
    app.code_parked.append(app.gpa, v) catch v.destroy(app.gpa);
}

/// Code tab `title` shown again.
pub fn show(app: *App, title: []const u8) void {
    for (app.code_parked.items, 0..) |pv, k| if (std.mem.eql(u8, pv.title, title)) {
        const v = app.code_parked.orderedRemove(k);
        park(app);
        app.code = v;
        return;
    };
}

/// Code tab `title` closed: its edits into the Store first (a syntax error keeps it open,
/// as Apply's first press). False if kept.
pub fn close(app: *App, title: []const u8) bool {
    const shown = if (app.code) |v| std.mem.eql(u8, v.title, title) else false;
    const v = if (shown) app.code.? else for (app.code_parked.items) |pv| {
        if (std.mem.eql(u8, pv.title, title)) break pv;
    } else return true;
    if (v.buf.changed) apply(app, v);
    if (v.buf.changed) return false;
    if (shown) app.code = null else for (app.code_parked.items, 0..) |pv, k| if (pv == v) {
        _ = app.code_parked.orderedRemove(k);
        break;
    };
    v.destroy(app.gpa);
    return true;
}

/// Every open code view (shown and in tabs) with unapplied edits applied; false if one
/// is held by a syntax error (its first warning).
pub fn applyAll(app: *App) bool {
    var ok = true;
    if (app.code) |v| if (v.buf.changed) {
        apply(app, v);
        ok = ok and !v.buf.changed;
    };
    for (app.code_parked.items) |v| if (v.buf.changed) {
        apply(app, v);
        ok = ok and !v.buf.changed;
    };
    return ok;
}

pub fn anyChanged(app: *const App) bool {
    if (app.code) |v| if (v.buf.changed) return true;
    for (app.code_parked.items) |v| if (v.buf.changed) return true;
    return false;
}

/// Object scripts the engine's parser reads (scene `.scr` files are another language).
fn checkable(title: []const u8) bool {
    for ([_][]const u8{ ".lev", ".are", ".itm", ".ftr", ".hro", ".obs", ".obs_i", ".wpn", ".s", ".ss" }) |x| {
        if (std.ascii.endsWithIgnoreCase(title, x)) return true;
    }
    return false;
}

/// Parses the text again if it changed (the game's own parser, as the engine loads it).
fn check(app: *App, v: *View) void {
    if (v.checked == v.buf.version) return;
    v.checked = v.buf.version;
    v.err_line = 0;
    v.err_len = 0;
    v.force = false;
    v.unknown_n = 0;
    if (isScene(v.title)) return checkScene(v);
    if (!checkable(v.title)) return;
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    var diag: og.script.parser.Diagnostic = .{};
    const unit = og.script.parser.parse(arena.allocator(), v.buf.str(), &diag) catch {
        v.err_line = @max(1, diag.line);
        const m = std.fmt.bufPrint(&v.err_buf, "{s}", .{diag.message}) catch v.err_buf[0..0];
        v.err_len = m.len;
        return;
    };
    // Calls nothing registers: not a builtin of the port or the exe, no function of this
    // script or of any game script (an inherited class's) by that name.
    const fns = gameFns(app);
    var own: std.StringHashMapUnmanaged(void) = .empty;
    for (unit.items) |it| if (it == .function) own.put(arena.allocator(), it.function.name, {}) catch {};
    var calls: std.ArrayList(Call) = .empty;
    for (unit.items) |*it| switch (it.*) {
        .function => |f| for (f.body) |*st| callsIn(arena.allocator(), st, &calls),
        .stmt => |*st| callsIn(arena.allocator(), st, &calls),
        else => {},
    };
    var lower: [128]u8 = undefined;
    for (calls.items) |cl| {
        if (api.known(cl.name) or own.contains(cl.name) or cl.name.len > lower.len) continue;
        if (fns.contains(std.ascii.lowerString(&lower, cl.name))) continue;
        noteUnknown(v, cl.line, cl.name);
    }
}

fn isScene(title: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(title, ".scr");
}

/// A scene's lines whose command is not in the exe's table (0x4763f0, matched by the
/// command's length as the exe does): the exe reports "Syntax error" and the port skips them.
fn checkScene(v: *View) void {
    var it = std.mem.splitScalar(u8, v.buf.str(), '\n');
    var line: u32 = 0;
    while (it.next()) |raw| {
        line += 1;
        const l = std.mem.trim(u8, raw[0 .. std.mem.indexOf(u8, raw, "//") orelse raw.len], " \t\r;");
        var e: usize = 0;
        while (e < l.len and code.isIdent(l[e])) e += 1;
        if (e == 0) continue;
        for (og.scene.scenario.exe_order) |cmd| {
            if (std.ascii.startsWithIgnoreCase(l, cmd)) break;
        } else noteUnknown(v, line, l[0..e]);
    }
}

fn sceneCmd(w: []const u8) bool {
    for (og.scene.scenario.exe_order) |cmd| if (std.ascii.eqlIgnoreCase(cmd, w)) return true;
    return false;
}

fn noteUnknown(v: *View, line: u32, name: []const u8) void {
    if (v.unknown_n == v.unknown.len) return;
    const u = &v.unknown[v.unknown_n];
    u.len = @intCast(@min(name.len, u.name.len));
    @memcpy(u.name[0..u.len], name[0..u.len]);
    u.line = line;
    v.unknown_n += 1;
}

const Call = struct { line: u32, name: []const u8 };

fn callsIn(a: Allocator, st: *const og.script.ast.Stmt, out: *std.ArrayList(Call)) void {
    switch (st.*) {
        .expr => |e| callsInExpr(a, e, out),
        .block => |b| for (b) |*x| callsIn(a, x, out),
        .@"if" => |i| {
            callsInExpr(a, i.cond, out);
            callsIn(a, i.then, out);
            if (i.@"else") |e| callsIn(a, e, out);
        },
        .@"return" => |r| if (r) |e| callsInExpr(a, e, out),
        .var_decl, .include, .empty => {},
    }
}

fn callsInExpr(a: Allocator, e: *const og.script.ast.Expr, out: *std.ArrayList(Call)) void {
    switch (e.kind) {
        .call => |c_| {
            out.append(a, .{ .line = e.line, .name = c_.name }) catch {};
            for (c_.args) |x| callsInExpr(a, x, out);
        },
        .unary => |u| callsInExpr(a, u.operand, out),
        .binary => |b| {
            callsInExpr(a, b.lhs, out);
            callsInExpr(a, b.rhs, out);
        },
        .assign => |x| callsInExpr(a, x.value, out),
        .int, .float, .string, .ident => {},
    }
}

/// A function a game script defines: as written, its parameters (`int x`), where
/// (`archive|entry`, its line's byte in the text).
const GameFn = struct { name: []const u8, params: []const []const u8, file: []const u8, at: usize };

/// Every function the game's scripts define (by lower-case name), read again after any
/// Store change (a function added to another script is known at once).
var game_fns: ?std.StringHashMapUnmanaged(GameFn) = null;
var game_fns_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var game_fns_key: [3]usize = .{ 0, 0, 0 };

fn gameFns(app: *App) *const std.StringHashMapUnmanaged(GameFn) {
    // A new step has a new text, so undo then another edit gives another key too.
    const st = &app.store;
    const now: [3]usize = .{ st.undo.items.len, st.files.items.len, if (st.undo.items.len > 0) @intFromPtr(st.undo.items[st.undo.items.len - 1].text.ptr) else 0 };
    if (game_fns) |*g| if (std.mem.eql(usize, &now, &game_fns_key)) return g;
    game_fns_key = now;
    _ = game_fns_arena.reset(.retain_capacity);
    game_fns = .empty;
    const a = game_fns_arena.allocator();
    const paths = og.formats.archive.listArchives(app.io, app.gpa, app.dat) catch return &game_fns.?;
    defer og.formats.archive.freeList(app.gpa, paths);
    var tmp: std.heap.ArenaAllocator = .init(app.gpa);
    defer tmp.deinit();
    for (paths) |p| for (refs_mod.files(app, tmp.allocator(), p, refs_mod.script)) |f| {
        var diag: og.script.parser.Diagnostic = .{};
        const unit = og.script.parser.parse(tmp.allocator(), f.text, &diag) catch continue;
        const file = std.fmt.allocPrint(a, "{s}|{s}", .{ p, f.name }) catch continue;
        for (unit.items) |it| if (it == .function) {
            const fun = it.function;
            const params = a.alloc([]const u8, fun.params.len) catch continue;
            for (params, fun.params) |*d, q| d.* = std.fmt.allocPrint(a, "{t} {s}", .{ q.type, q.name }) catch "";
            const name = a.dupe(u8, fun.name) catch continue;
            var at: usize = 0;
            for (1..fun.line) |_| at = if (std.mem.indexOfScalarPos(u8, f.text, at, '\n')) |k| k + 1 else at;
            game_fns.?.put(a, std.ascii.allocLowerString(a, name) catch continue, .{ .name = name, .params = params, .file = file, .at = at }) catch {};
        };
    };
    return &game_fns.?;
}

/// The game script function named `w` (case aside), if any.
fn gameFn(app: *App, w: []const u8) ?GameFn {
    var lower: [128]u8 = undefined;
    if (w.len > lower.len) return null;
    return gameFns(app).get(std.ascii.lowerString(&lower, w));
}

/// Writes the text into the Store (one undo step). With a syntax error the first
/// press only warns, the second applies as it is.
pub fn apply(app: *App, v: *View) void {
    check(app, v);
    if (v.err_line > 0 and !v.force) {
        v.force = true;
        return app.setStatus(tx.st_code_error, .{ v.err_line, v.err() });
    }
    const bytes = code.toGame(app.gpa, v.buf.str(), app.catalog.cyrillic) catch |err| return app.setStatus(tx.st_set_failed, .{err});
    if (std.mem.eql(u8, bytes, app.store.text(v.file))) {
        app.gpa.free(bytes);
        v.buf.changed = false;
        return;
    }
    app.store.replace(v.file, bytes) catch |err| {
        app.gpa.free(bytes);
        return app.setStatus(tx.st_set_failed, .{err});
    };
    v.buf.changed = false;
    // The open level's script: its placements read again.
    if (app.doc) |d| if (v.file == d.lev) d.afterUndo() catch {};
    app.setStatus(tx.st_code_applied, .{v.title});
}

/// The open code as the centre's document: where it is (file, function), its tools;
/// the text with the outline and what the word at the cursor is beside it; problems and
/// the word's uses below.
pub fn page(app: *App, a: Allocator, v: *View) void {
    check(app, v);
    const t = v.buf.str();
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM }, .backgroundColor = theme.bg });
    // Breadcrumbs and tools.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(44) }, .padding = .{ .left = 14, .right = 10 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.header, .border = .{ .color = theme.line, .width = .{ .bottom = 1 } }, .clip = .{ .horizontal = true } });
    const archive = app.store.files.items[v.file].archive;
    const place = if (std.mem.endsWith(u8, archive, "/other.dat")) archive[0 .. archive.len - "/other.dat".len] else archive;
    // Battles › 01_port › 01__port_barge.lev (a level's), or the archive (common files).
    const lvl = for (app.levels) |lv| {
        if (std.mem.eql(u8, lv.name, place)) break lv;
    } else null;
    if (lvl) |lv| {
        crumb(app, tx.get(if (lv.battle) tx.at_battles else tx.at_locations), false);
        crumb(app, std.mem.replaceOwned(u8, a, @import("assettree.zig").chapter(lv.name), "__", "_") catch lv.name, true);
    } else crumb(app, place, false);
    crumb(app, v.title, true);
    const fns = functions(a, t);
    if (currentFn(fns, v.buf.cursor)) |fi| crumb(app, std.fmt.allocPrint(a, "{s}()", .{fns[fi].name}) catch "", true);
    if (v.buf.changed) txt(tx.get(tx.code_changed), 13, theme.warn, font_mod.regular);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    if (main.toolButton(app, "code_tasks", .plus, tx.get(tx.code_tasks), v.tasks, false)) {
        v.tasks = true;
        v.popup = true;
        v.popup_sel = 0;
    }
    if (main.toolButton(app, "code_format", .file_text, tx.get(tx.code_format), false, false)) formatText(app, v);
    if (main.toolButton(app, "code_help", .search, tx.get(tx.code_help), v.help, false)) v.help = !v.help;
    clay.close();
    if (v.find_open) findBar(app, a, v);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } } });
    clay.leaf(.{ .id = clay.id("code_area"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } }, .backgroundColor = theme.viewport, .custom = .{ .customData = v } });
    if (v.help) helpColumn(app, a, v) else side(app, a, v, fns);
    clay.close();
    bottom(app, a, v);
    var line: usize = 1;
    for (t[0..v.buf.cursor]) |ch| line += @intFromBool(ch == '\n');
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(24) }, .padding = .{ .left = 14 }, .childGap = 16, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel, .border = .{ .color = theme.line, .width = .{ .top = 1 } } });
    txt(tx.alloc(a, tx.code_pos, .{ line, v.buf.cursor - code.lineStart(t, v.buf.cursor) + 1 }), 12, theme.dim, font_mod.regular);
    txt(tx.get(tx.code_keys), 12, theme.dim, font_mod.regular);
    clay.close();
    clay.close();
}

/// Cmd+F's bar: the text (Enter: the next match), how many, previous / next, close.
fn findBar(app: *App, a: Allocator, v: *View) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(40) }, .padding = .{ .left = 14, .right = 10 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel, .border = .{ .color = theme.line, .width = .{ .bottom = 1 } } });
    icons.leaf(app.r, app.gpa, .search, 15, theme.dim);
    if (@import("textedit.zig").field(app, "code_find", v.findText(), 280, tx.get(tx.code_find))) |q| {
        v.setFind(q);
        findNext(v, true);
        // Enter again: the next one.
        @import("textedit.zig").focus(app, "code_find", q);
    }
    const q = v.findText();
    var n: usize = 0;
    if (q.len > 0) {
        var i: usize = 0;
        while (findFrom(v.buf.str(), q, i)) |k| : (i = k + q.len) n += 1;
    }
    txt(tx.alloc(a, tx.code_matches, .{n}), 12, theme.dim, font_mod.regular);
    if (main.toolButton(app, "code_find_prev", .skip_back, "", false, false)) findNext(v, false);
    if (main.toolButton(app, "code_find_next", .skip_forward, "", false, false)) findNext(v, true);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    if (main.toolButton(app, "code_find_close", .x, "", false, false)) v.find_open = false;
    clay.close();
}

fn crumb(app: *App, s: []const u8, chevron: bool) void {
    if (chevron) icons.leaf(app.r, app.gpa, .chevron_right, 13, theme.dim);
    txt(s, 13, if (chevron) theme.text else theme.dim, if (chevron) font_mod.bold else font_mod.regular);
}

const Func = struct { name: []const u8, at: usize };

/// `function name(` headers of the text, in order.
fn functions(a: Allocator, t: []const u8) []const Func {
    var out: std.ArrayList(Func) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, t, pos, "function")) |i| {
        pos = i + 8;
        if (i > 0 and code.isIdent(t[i - 1])) continue;
        var j = pos;
        while (j < t.len and (t[j] == ' ' or t[j] == '\t')) j += 1;
        const s0 = j;
        while (j < t.len and code.isIdent(t[j])) j += 1;
        if (j == s0 or j >= t.len or t[j] != '(') continue;
        out.append(a, .{ .name = t[s0..j], .at = i }) catch {};
    }
    return out.items;
}

fn currentFn(fns: []const Func, cursor: usize) ?usize {
    var cur: ?usize = null;
    for (fns, 0..) |f, k| if (f.at <= cursor) {
        cur = k;
    };
    return cur;
}

/// The identifier around the cursor.
fn wordAt(t: []const u8, i: usize) []const u8 {
    var a = @min(i, t.len);
    var b = a;
    while (a > 0 and code.isIdent(t[a - 1])) a -= 1;
    while (b < t.len and code.isIdent(t[b])) b += 1;
    return t[a..b];
}

/// Uses of `w` as a whole word: their offsets.
fn uses(a: Allocator, t: []const u8, w: []const u8) []const usize {
    var out: std.ArrayList(usize) = .empty;
    if (w.len == 0) return out.items;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, t, pos, w)) |i| {
        pos = i + w.len;
        if (i > 0 and code.isIdent(t[i - 1])) continue;
        if (pos < t.len and code.isIdent(t[pos])) continue;
        out.append(a, i) catch {};
    }
    return out.items;
}

/// The outline (functions; a click goes there) and the word at the cursor: what it is
/// (engine function, variable and its type), its value set here, its uses.
fn side(app: *App, a: Allocator, v: *View, fns: []const Func) void {
    const t = v.buf.str();
    clay.openScroll(.{ .id = clay.id("code_side"), .layout = .{ .sizing = .{ .width = clay.fixed(300), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 12, .right = 12, .top = 12, .bottom = 12 }, .childGap = 6 }, .backgroundColor = theme.panel, .border = .{ .color = theme.line, .width = .{ .left = 1 } } });
    txt(tx.get(tx.code_outline), 14, theme.text, font_mod.bold);
    if (fns.len == 0) txt(tx.get(tx.code_no_fns), 12, theme.dim, font_mod.regular);
    const cur = currentFn(fns, v.buf.cursor);
    for (fns, 0..) |f, k| {
        const rid = clay.idi("code_fn", @intCast(k));
        const on = cur != null and cur.? == k;
        clay.open(.{ .id = rid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(28) }, .padding = .{ .left = 8 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = if (on) theme.accent else if (clay.pointerOver(rid)) theme.row_hover else theme.panel, .cornerRadius = clay.radius(4) });
        if (clay.hovered() and app.clicked) {
            v.buf.cursor = f.at;
            follow(v);
        }
        icons.leaf(app.r, app.gpa, .code, 14, if (on) theme.text else theme.accent_hover);
        txt(std.fmt.allocPrint(a, "{s}()", .{f.name}) catch f.name, 13, theme.text, font_mod.regular);
        clay.close();
    }
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(1) } }, .backgroundColor = theme.line });
    txt(tx.get(tx.code_context), 14, theme.text, font_mod.bold);
    const w = wordAt(t, v.buf.cursor);
    if (w.len == 0) {
        wrapped(tx.get(tx.code_context_none), 12, theme.dim);
    } else {
        kv(a, tx.code_k_name, w);
        var file: []const u8 = v.title;
        if (api.find(w)) |f| {
            kv(a, tx.code_k_type, tx.get(tx.code_t_fn));
            wrapped(signature(a, f), 12, theme.accent_hover);
            wrapped(fnDesc(a, f), 12, theme.dim);
        } else if (gameFn(app, w)) |g| {
            kv(a, tx.code_k_type, tx.get(tx.code_t_game_fn));
            file = g.file;
            wrapped(std.fmt.allocPrint(a, "{s}({s})", .{ g.name, std.mem.join(a, ", ", g.params) catch "" }) catch "", 12, theme.accent_hover);
        } else if (isUnknown(v, w)) {
            kv(a, tx.code_k_type, tx.get(tx.code_t_unknown));
        } else if (isScene(v.title) and std.mem.eql(u8, og.scene.scenario.exeName(w), w) and sceneCmd(w)) {
            kv(a, tx.code_k_type, tx.get(tx.code_t_scene));
        } else if (declType(t, w)) |ty| kv(a, tx.code_k_type, ty);
        if (valueOf(t, w)) |val| kv(a, tx.code_k_value, val);
        kv(a, tx.code_k_uses, std.fmt.allocPrint(a, "{d}", .{uses(a, t, w).len}) catch "");
        kv(a, tx.code_k_file, file);
    }
    clay.close();
}

fn kv(a: Allocator, k: tx.Msg, value: []const u8) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 8 } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(90) } } });
    txt(tx.get(k), 12, theme.dim, font_mod.regular);
    clay.close();
    txt(a.dupe(u8, value) catch value, 12, theme.text, font_mod.regular);
    clay.close();
}

/// `int w;` / `float w;` / `string w;`: its type.
fn declType(t: []const u8, w: []const u8) ?[]const u8 {
    for ([_][]const u8{ "int", "float", "string" }) |ty| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, t, pos, ty)) |i| {
            pos = i + ty.len;
            if (i > 0 and code.isIdent(t[i - 1])) continue;
            var j = pos;
            while (j < t.len and (t[j] == ' ' or t[j] == '\t')) j += 1;
            if (std.mem.startsWith(u8, t[j..], w) and (j + w.len >= t.len or !code.isIdent(t[j + w.len]))) return ty;
        }
    }
    return null;
}

/// `w = value;` (the first): its value.
fn valueOf(t: []const u8, w: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, t, pos, w)) |i| {
        pos = i + w.len;
        if (i > 0 and code.isIdent(t[i - 1])) continue;
        var j = pos;
        while (j < t.len and (t[j] == ' ' or t[j] == '\t')) j += 1;
        if (j >= t.len or t[j] != '=' or (j + 1 < t.len and t[j + 1] == '=')) continue;
        const e = std.mem.indexOfScalarPos(u8, t, j, ';') orelse continue;
        return std.mem.trim(u8, t[j + 1 .. e], " \t");
    }
    return null;
}

/// Problems (the parser's error; a click goes to its line) or the word's uses.
fn bottom(app: *App, a: Allocator, v: *View) void {
    const t = v.buf.str();
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(150) }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM }, .backgroundColor = theme.panel, .border = .{ .color = theme.line, .width = .{ .top = 1 } } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(36) }, .padding = .{ .left = 10 }, .childGap = 4, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    const w = wordAt(t, v.buf.cursor);
    const refs = uses(a, t, w);
    if (main.toolButton(app, "code_problems", .check, tx.alloc(a, tx.code_problems, .{@as(u32, @intFromBool(v.err_line > 0)) + @as(u32, @intCast(v.unknown_n))}), app.code_bottom == .problems, false)) app.code_bottom = .problems;
    if (main.toolButton(app, "code_refs", .search, tx.alloc(a, tx.code_refs, .{refs.len}), app.code_bottom == .refs, false)) app.code_bottom = .refs;
    clay.close();
    clay.openScroll(.{ .id = clay.id("code_bottom"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 16, .right = 16, .top = 4, .bottom = 8 }, .childGap = 4 } });
    switch (app.code_bottom) {
        .problems => if (v.err_line > 0 or v.unknown_n > 0) {
            if (v.err_line > 0) {
                const rid = clay.id("code_err");
                if (main.clickable(app, .{ .id = rid, .layout = .{ .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel }, false)) goLine(v, v.err_line);
                const msg = if (v.force) tx.alloc(a, tx.code_error_force, .{ v.err_line, v.err() }) else tx.alloc(a, tx.code_error, .{ v.err_line, v.err() });
                txt(msg, 13, theme.warn, font_mod.regular);
                clay.close();
            }
            for (v.unknown[0..v.unknown_n], 0..) |*u, k| {
                if (main.clickable(app, .{ .id = clay.idi("code_unk", @intCast(k)), .layout = .{ .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel }, false)) goLine(v, u.line);
                const name = u.name[0..u.len];
                txt(if (isScene(v.title)) tx.alloc(a, tx.code_unknown_scene, .{ u.line, name }) else tx.alloc(a, tx.code_unknown, .{ u.line, name }), 13, theme.warn, font_mod.regular);
                clay.close();
            }
        } else {
            clay.open(.{ .layout = .{ .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
            icons.leaf(app.r, app.gpa, .check, 16, theme.ok);
            txt(tx.get(if (checkable(v.title) or isScene(v.title)) tx.code_no_issues else tx.code_not_checked), 13, theme.text, font_mod.regular);
            clay.close();
        },
        .refs => for (refs, 0..) |at, k| {
            if (k >= 60) break;
            const ls = code.lineStart(t, at);
            const le = code.lineEnd(t, at);
            var ln: u32 = 1;
            for (t[0..at]) |ch| ln += @intFromBool(ch == '\n');
            const rid = clay.idi("code_ref", @intCast(k));
            if (main.clickable(app, .{ .id = rid, .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 10 }, .backgroundColor = theme.panel }, false)) {
                v.buf.cursor = at;
                follow(v);
            }
            txt(std.fmt.allocPrint(a, "{d}", .{ln}) catch "", 12, theme.dim, font_mod.regular);
            txt(std.mem.trim(u8, t[ls..le], " \t\r\n"), 12, theme.text, font_mod.regular);
            clay.close();
        },
    }
    clay.close();
    clay.close();
}

fn goLine(v: *View, line: u32) void {
    const t = v.buf.str();
    var i: usize = 0;
    var n: u32 = 1;
    while (i < t.len and n < line) : (i += 1) n += @intFromBool(t[i] == '\n');
    v.buf.cursor = i;
    follow(v);
}

/// The functions the engine runs, those matching the call or word at the cursor first
/// (all when there is none); a click puts one in at the cursor.
fn helpColumn(app: *App, a: Allocator, v: *View) void {
    const t = v.buf.str();
    const filter = if (code.callAt(t, v.buf.cursor)) |cp| cp.name else v.buf.wordBefore();
    clay.openScroll(.{
        .id = clay.id("code_help_list"),
        .layout = .{ .sizing = .{ .width = clay.fixed(420), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 }, .childGap = 10 },
        .backgroundColor = theme.panel,
        .border = .{ .color = theme.line, .width = .{ .left = 1 } },
    });
    wrapped(tx.alloc(a, tx.code_help_count, .{api.all.len}), 12, theme.dim);
    var shown: usize = 0;
    for (&api.all, 0..) |*f, i| {
        if (filter.len > 0 and std.ascii.findIgnoreCase(f.name, filter) == null) continue;
        shown += 1;
        const rid = clay.idi("api", @intCast(i));
        if (main.clickable(app, .{
            .id = rid,
            .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 6, .right = 6, .top = 4, .bottom = 4 }, .childGap = 3 },
            .backgroundColor = theme.panel,
        }, false)) {
            v.buf.insertCall(f.name, api.sampleArgs(a, f) catch "") catch {};
            follow(v);
        }
        txt(f.name, 14, theme.text, font_mod.bold);
        wrapped(signature(a, f), 12, theme.accent_hover);
        wrapped(fnDesc(a, f), 12, theme.dim);
        clay.close();
    }
    if (shown == 0) txt(tx.get(tx.code_help_none), 12, theme.dim, font_mod.regular);
    clay.close();
}

/// What `f` does, "port only" before it when the original exe lacks it.
fn fnDesc(a: Allocator, f: *const api.Fn) []const u8 {
    const d = tx.get(.{ .en = f.en, .ru = f.ru });
    if (!api.portOnly(f)) return d;
    return std.fmt.allocPrint(a, "[{s}] {s}", .{ tx.get(tx.code_port_only), d }) catch d;
}

/// `w` is one of the view's unknown calls (or scene commands).
fn isUnknown(v: *const View, w: []const u8) bool {
    for (v.unknown[0..v.unknown_n]) |*u| if (std.ascii.eqlIgnoreCase(u.name[0..u.len], w)) return true;
    return false;
}

fn wrapped(s: []const u8, size: u16, col: clay.Color) void {
    clay.text(s, .{ .textColor = col, .fontSize = size, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
}

/// `(string name, int x, [int dir])`.
fn signature(a: Allocator, f: *const api.Fn) []const u8 {
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

/// Width of `s` drawn: a tab as four spaces (the font has no tab glyph).
fn width(app: *App, s: []const u8) f32 {
    var w: f32 = 0;
    var it = std.mem.splitScalar(u8, s, '\t');
    var first = true;
    while (it.next()) |part| {
        if (!first) w += app.font.measure("    ", font_mod.regular, pt)[0];
        first = false;
        w += app.font.measure(part, font_mod.regular, pt)[0];
    }
    return w;
}

/// Draws `s` at x, tabs as spaces; returns the x after it.
fn drawText(app: *App, s: []const u8, x: f32, y: f32, col: [4]u8) f32 {
    var cx = x;
    var it = std.mem.splitScalar(u8, s, '\t');
    var first = true;
    while (it.next()) |part| {
        if (!first) cx += app.font.measure("    ", font_mod.regular, pt)[0];
        first = false;
        app.font.draw(app.r, part, font_mod.regular, pt, cx, y, col);
        cx += app.font.measure(part, font_mod.regular, pt)[0];
    }
    return cx;
}

fn kindColor(k: code.Kind) [4]u8 {
    return switch (k) {
        .plain => .{ 220, 223, 228, 255 },
        .keyword => .{ 198, 120, 221, 255 },
        .call => .{ 97, 175, 239, 255 },
        .string => .{ 152, 195, 121, 255 },
        .number => .{ 209, 154, 102, 255 },
        .comment => .{ 110, 118, 129, 255 },
        .directive => .{ 229, 192, 123, 255 },
    };
}

/// `text[start..end]` as a code excerpt on a page: each non-empty line with its line
/// number in `text`, highlighted as in the window, tabs as four spaces.
pub fn excerpt(a: Allocator, text: []const u8, start: usize, end: usize) void {
    // The indent all its lines share is left out.
    var indent: usize = std.math.maxInt(usize);
    var it = std.mem.splitScalar(u8, text[start..end], '\n');
    while (it.next()) |raw| if (std.mem.trim(u8, raw, " \t\r").len > 0) {
        indent = @min(indent, raw.len - std.mem.trimStart(u8, raw, " \t").len);
    };
    var n = std.mem.count(u8, text[0..start], "\n") + 1;
    var lines = std.mem.splitScalar(u8, text[start..end], '\n');
    while (lines.next()) |raw| : (n += 1) {
        const full = std.mem.trimEnd(u8, raw, " \t\r");
        if (full.len == 0) continue;
        const l = full[indent..];
        clay.open(.{ .layout = .{} });
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(44) } } });
        txt(std.fmt.allocPrint(a, "{d}", .{n}) catch "", 13, clay.rgb(0x5a606a), font_mod.regular);
        clay.close();
        for (code.highlight(a, l) catch &.{}) |sp| {
            const k = kindColor(sp.kind);
            txt(std.mem.replaceOwned(u8, a, l[sp.start..sp.end], "\t", "    ") catch "", 13, .{ .r = @floatFromInt(k[0]), .g = @floatFromInt(k[1]), .b = @floatFromInt(k[2]), .a = 255 }, font_mod.regular);
        }
        clay.close();
    }
}

fn visibleLines(v: *const View) usize {
    return @intFromFloat(@max(1, @floor((v.rect.h - 8) / line_h)));
}

/// Text, cursor, selection and the completion list into `rect`.
pub fn draw(app: *App, v: *View, rect: c.SDL_FRect) void {
    v.rect = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h };
    const r = app.r;
    const f = app.font;
    const t = v.buf.str();
    const clip: c.SDL_Rect = .{ .x = @intFromFloat(rect.x), .y = @intFromFloat(rect.y), .w = @intFromFloat(rect.w), .h = @intFromFloat(rect.h) };
    _ = c.SDL_SetRenderClipRect(r, &clip);
    defer _ = c.SDL_SetRenderClipRect(r, null);
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const sel = v.buf.selection();
    const q = if (v.find_open) v.findText() else "";
    const pair = bracketPair(t, v.buf.cursor);
    var ls: usize = 0;
    var n: usize = 0;
    while (n < v.scroll and ls < t.len) : (n += 1) ls = next(t, ls);
    var cursor_xy: ?[2]f32 = null;
    var y = rect.y + 4;
    while (ls <= t.len and y < rect.y + rect.h) : (n += 1) {
        const le = code.lineEnd(t, ls);
        const line = t[ls..le];
        f.draw(r, std.fmt.allocPrint(a, "{d}", .{n + 1}) catch "", font_mod.regular, 13, rect.x + 8, y + 2, .{ 90, 96, 106, 255 });
        const x0 = rect.x + gutter;
        if (v.err_line == n + 1) {
            _ = c.SDL_SetRenderDrawColor(r, 160, 40, 40, 90);
            _ = c.SDL_RenderFillRect(r, &.{ .x = rect.x, .y = y, .w = rect.w, .h = line_h });
        }
        for (v.unknown[0..v.unknown_n]) |*u| if (u.line == n + 1) {
            _ = c.SDL_SetRenderDrawColor(r, 200, 140, 30, 60);
            _ = c.SDL_RenderFillRect(r, &.{ .x = rect.x, .y = y, .w = rect.w, .h = line_h });
            break;
        };
        if (sel) |s| if (s[0] <= le and s[1] >= ls) {
            const a0 = @max(s[0], ls);
            const a1 = @min(s[1], le);
            const sx = x0 + width(app, t[ls..a0]);
            const sw = width(app, t[a0..a1]) + if (s[1] > le) @as(f32, 6) else 0;
            _ = c.SDL_SetRenderDrawColor(r, 59, 91, 219, 110);
            _ = c.SDL_RenderFillRect(r, &.{ .x = sx, .y = y, .w = sw, .h = line_h });
        };
        // Find matches on the line; the bracket at the cursor and its pair.
        if (q.len > 0) {
            var i: usize = 0;
            while (findFrom(line, q, i)) |k| : (i = k + q.len) {
                _ = c.SDL_SetRenderDrawColor(r, 230, 170, 40, 70);
                _ = c.SDL_RenderFillRect(r, &.{ .x = x0 + width(app, line[0..k]), .y = y, .w = width(app, line[k .. k + q.len]), .h = line_h });
            }
        }
        if (pair) |pp| for (pp) |bi| if (bi >= ls and bi < le) {
            _ = c.SDL_SetRenderDrawColor(r, 150, 160, 180, 160);
            _ = c.SDL_RenderRect(r, &.{ .x = x0 + width(app, t[ls..bi]), .y = y + 1, .w = width(app, t[bi .. bi + 1]), .h = line_h - 2 });
        };
        var x = x0;
        for (code.highlight(a, line) catch &.{}) |sp| {
            x = drawText(app, line[sp.start..sp.end], x, y, kindColor(sp.kind));
        }
        if (v.buf.cursor >= ls and v.buf.cursor <= le) cursor_xy = .{ x0 + width(app, t[ls..v.buf.cursor]), y };
        y += line_h;
        if (le >= t.len) break;
        ls = next(t, le);
    }
    const cxy = cursor_xy orelse return;
    // A blinking bar.
    if ((c.SDL_GetTicks() / 500) % 2 == 0 or v.popup) {
        _ = c.SDL_SetRenderDrawColor(r, 240, 240, 240, 255);
        _ = c.SDL_RenderFillRect(r, &.{ .x = cxy[0], .y = cxy[1] + 2, .w = 2, .h = line_h - 4 });
    }
    if (v.popup) drawPopup(app, v, a, .{ cxy[0], cxy[1] + line_h }) else drawHint(app, v, a, cxy, rect);
}

/// The bracket just before or at offset `i` and the one closing (opening) it.
fn bracketPair(t: []const u8, i: usize) ?[2]usize {
    for ([_]usize{ i, i -% 1 }) |p| {
        if (p >= t.len) continue;
        const opener = std.mem.indexOfScalar(u8, "([{", t[p]);
        const k = opener orelse std.mem.indexOfScalar(u8, ")]}", t[p]) orelse continue;
        const o = "([{"[k];
        const cl = ")]}"[k];
        var depth: usize = 0;
        if (opener != null) {
            var j = p;
            while (j < t.len) : (j += 1) {
                if (t[j] == o) depth += 1 else if (t[j] == cl) {
                    depth -= 1;
                    if (depth == 0) return .{ p, j };
                }
            }
        } else {
            var j = p + 1;
            while (j > 0) {
                j -= 1;
                if (t[j] == cl) depth += 1 else if (t[j] == o) {
                    depth -= 1;
                    if (depth == 0) return .{ j, p };
                }
            }
        }
        return null;
    }
    return null;
}

/// Inside a known call: its parameters above the line, the current one marked, and
/// what the function does.
fn drawHint(app: *App, v: *View, a: Allocator, cxy: [2]f32, rect: c.SDL_FRect) void {
    const cp = code.callAt(v.buf.str(), if (v.buf.selection()) |s| s[0] else v.buf.cursor) orelse return;
    const r = app.r;
    const fo = app.font;
    // A builtin's parameters and doc, or a game script function's and its file.
    var decls: std.ArrayList([]const u8) = .empty;
    var fname: []const u8 = undefined;
    var desc: []const u8 = undefined;
    if (api.find(cp.name)) |f| {
        var buf: [12]api.Param = undefined;
        for (api.params(f, &buf)) |p| decls.append(a, if (p.optional) std.fmt.allocPrint(a, "[{s}]", .{p.decl}) catch "" else p.decl) catch {};
        fname = f.name;
        desc = fnDesc(a, f);
    } else if (gameFn(app, cp.name)) |g| {
        decls.appendSlice(a, g.params) catch {};
        fname = g.name;
        desc = g.file;
    } else return;
    // Pieces of `Name(type a, [type b])`, the current parameter in bold yellow.
    var pieces: [32]struct { s: []const u8, cur: bool } = undefined;
    var n: usize = 0;
    pieces[n] = .{ .s = std.fmt.allocPrint(a, "{s}(", .{fname}) catch return, .cur = false };
    n += 1;
    for (decls.items, 0..) |p, k| {
        if (n + 2 > pieces.len) break;
        if (k > 0) {
            pieces[n] = .{ .s = ", ", .cur = false };
            n += 1;
        }
        pieces[n] = .{ .s = p, .cur = k == cp.arg };
        n += 1;
    }
    pieces[n] = .{ .s = ")", .cur = false };
    n += 1;
    var w: f32 = 0;
    for (pieces[0..n]) |p| w += fo.measure(p.s, if (p.cur) font_mod.bold else font_mod.regular, 13)[0];
    w = @max(w, fo.measure(desc, font_mod.regular, 12)[0]) + 16;
    const h: f32 = 42;
    const x = @min(cxy[0], rect.x + rect.w - w - 4);
    const y = if (cxy[1] - h - 2 >= rect.y) cxy[1] - h - 2 else cxy[1] + line_h + 2;
    _ = c.SDL_SetRenderDrawColor(r, 30, 31, 34, 245);
    _ = c.SDL_RenderFillRect(r, &.{ .x = x, .y = y, .w = w, .h = h });
    _ = c.SDL_SetRenderDrawColor(r, 70, 74, 82, 255);
    _ = c.SDL_RenderRect(r, &.{ .x = x, .y = y, .w = w, .h = h });
    var px = x + 8;
    for (pieces[0..n]) |p| {
        const fid: u16 = if (p.cur) font_mod.bold else font_mod.regular;
        fo.draw(r, p.s, fid, 13, px, y + 3, if (p.cur) .{ 255, 215, 90, 255 } else .{ 220, 223, 228, 255 });
        px += fo.measure(p.s, fid, 13)[0];
    }
    fo.draw(r, desc, font_mod.regular, 12, x + 8, y + 22, .{ 150, 156, 166, 255 });
}

fn next(t: []const u8, i: usize) usize {
    var k = code.lineEnd(t, i);
    if (k < t.len and t[k] == '\r') k += 1;
    if (k < t.len and t[k] == '\n') k += 1;
    return k;
}

/// Common things a level script does, as code to put in (Ctrl+Space on an empty spot):
/// `""` marks where values go; the cursor lands in the first, its list open.
const Task = struct { label: tx.Msg, code: []const u8 };
const tasks = [_]Task{
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

/// What goes in string argument `sa`, by its parameter's name (api.zig): actors,
/// objects, areas of the open level, levels, scenes; null — nothing known.
fn values(app: *App, a: Allocator, sa: code.StringArg) ?[]const []const u8 {
    const f = api.find(sa.call.name) orelse return null;
    var pb: [12]api.Param = undefined;
    const ps = api.params(f, &pb);
    if (sa.call.arg >= ps.len) return null;
    const decl = ps[sa.call.arg].decl;
    if (!std.mem.startsWith(u8, decl, "string ")) return null;
    const name = decl["string ".len..];
    const eq = std.mem.eql;
    var out: std.ArrayList([]const u8) = .empty;
    if (eq(u8, name, "level")) {
        for (app.levels) |l| out.append(a, l.name) catch {};
    } else if (eq(u8, name, "scene")) {
        for (app.catalog.scenes.items) |sc| out.append(a, sc.name) catch {};
    } else if (eq(u8, name, "area")) {
        if (app.doc) |d| for (d.objects.items) |o| if (o.kind == .area) out.append(a, o.name) catch {};
    } else if (eq(u8, name, "actor") or eq(u8, name, "hero") or eq(u8, name, "fighter") or eq(u8, name, "name")) {
        out.appendSlice(a, &party) catch {};
        if (app.doc) |d| for (d.objects.items) |o| switch (o.kind) {
            .enemy, .actor, .neutral, .hero => out.append(a, o.name) catch {},
            else => {},
        };
    } else if (eq(u8, name, "object") or eq(u8, name, "target") or eq(u8, name, "parent") or eq(u8, name, "owner") or eq(u8, name, "item")) {
        if (app.doc) |d| for (d.objects.items) |o| if (o.kind != .area) out.append(a, o.name) catch {};
    } else return null;
    return out.items;
}

/// The list for the cursor: values inside a known string argument, the tasks, or the
/// words for the word before it (the game's functions, the file's names).
fn candidates(app: *App, v: *View, a: Allocator) []const []const u8 {
    if (v.tasks) {
        const out = a.alloc([]const u8, tasks.len) catch return &.{};
        for (tasks, out) |t, *o| o.* = tx.get(t.label);
        return out;
    }
    const t = v.buf.str();
    if (code.stringArgAt(t, v.buf.cursor)) |sa| if (values(app, a, sa)) |vals| {
        const prefix = t[sa.start..v.buf.cursor];
        if (prefix.len == 0) return vals[0..@min(vals.len, 12)];
        return code.matches(a, prefix, vals, 12) catch &.{};
    };
    const prefix = v.buf.wordBefore();
    var words: std.ArrayList([]const u8) = .empty;
    if (isScene(v.title)) words.appendSlice(a, &og.scene.scenario.exe_order) catch {} else for (&api.all) |f| words.append(a, f.name) catch {};
    words.appendSlice(a, app.catalog.calls.keys()) catch {};
    if (!isScene(v.title)) {
        var it = gameFns(app).valueIterator();
        while (it.next()) |g| words.append(a, g.name) catch {};
    }
    // Names of the open level's objects (for the strings calls take).
    if (app.doc) |d| for (d.objects.items) |o| words.append(a, o.name) catch {};
    words.appendSlice(a, &.{ "function", "if", "else", "while", "return", "int", "float", "string" }) catch {};
    words.appendSlice(a, code.identifiers(a, v.buf.str()) catch &.{}) catch {};
    return code.matches(a, prefix, words.items, 10) catch &.{};
}

fn drawPopup(app: *App, v: *View, a: Allocator, at: [2]f32) void {
    const r = app.r;
    const f = app.font;
    const list = candidates(app, v, a);
    if (list.len == 0) return;
    v.popup_sel = @min(v.popup_sel, list.len - 1);
    const w: f32 = 320;
    const h = @as(f32, @floatFromInt(list.len)) * line_h + 6;
    _ = c.SDL_SetRenderDrawColor(r, 43, 45, 49, 250);
    _ = c.SDL_RenderFillRect(r, &.{ .x = at[0], .y = at[1], .w = w, .h = h });
    _ = c.SDL_SetRenderDrawColor(r, 59, 91, 219, 255);
    _ = c.SDL_RenderRect(r, &.{ .x = at[0], .y = at[1], .w = w, .h = h });
    for (list, 0..) |word, i| {
        const y = at[1] + 3 + @as(f32, @floatFromInt(i)) * line_h;
        if (i == v.popup_sel) {
            _ = c.SDL_SetRenderDrawColor(r, 59, 91, 219, 200);
            _ = c.SDL_RenderFillRect(r, &.{ .x = at[0] + 1, .y = y, .w = w - 2, .h = line_h });
        }
        f.draw(r, word, font_mod.regular, pt, at[0] + 8, y, .{ 230, 232, 236, 255 });
    }
    // The selected function's parameters and what it does, or how the game calls it.
    if (api.find(list[v.popup_sel])) |fp| {
        const sig = std.fmt.allocPrint(a, "{s}{s}", .{ fp.name, signature(a, fp) }) catch return;
        const desc = fnDesc(a, fp);
        const ew = @max(f.measure(sig, font_mod.regular, 13)[0], f.measure(desc, font_mod.regular, 12)[0]) + 16;
        _ = c.SDL_SetRenderDrawColor(r, 30, 31, 34, 250);
        _ = c.SDL_RenderFillRect(r, &.{ .x = at[0] + w + 4, .y = at[1], .w = ew, .h = 44 });
        f.draw(r, sig, font_mod.regular, 13, at[0] + w + 12, at[1] + 3, .{ 152, 195, 121, 255 });
        f.draw(r, desc, font_mod.regular, 12, at[0] + w + 12, at[1] + 23, .{ 150, 156, 166, 255 });
    } else if (app.catalog.calls.get(list[v.popup_sel])) |example| {
        const ew = f.measure(example, font_mod.regular, 13)[0] + 16;
        _ = c.SDL_SetRenderDrawColor(r, 30, 31, 34, 250);
        _ = c.SDL_RenderFillRect(r, &.{ .x = at[0] + w + 4, .y = at[1], .w = ew, .h = line_h + 4 });
        f.draw(r, example, font_mod.regular, 13, at[0] + w + 12, at[1] + 3, .{ 152, 195, 121, 255 });
    }
}

fn accept(app: *App, v: *View) bool {
    if (!v.popup) return false;
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const list = candidates(app, v, arena.allocator());
    v.popup = false;
    if (list.len == 0) return false;
    const word = list[@min(v.popup_sel, list.len - 1)];
    if (v.tasks) {
        v.tasks = false;
        putTask(v, tasks[@min(v.popup_sel, tasks.len - 1)].code) catch {};
        return true;
    }
    if (code.stringArgAt(v.buf.str(), v.buf.cursor)) |sa| {
        v.buf.replaceSpan(sa.start, v.buf.cursor, word) catch {};
        return true;
    }
    if (api.find(word)) |f| {
        v.buf.insertCall(f.name, api.sampleArgs(arena.allocator(), f) catch "") catch {};
    } else v.buf.complete(word) catch {};
    return true;
}

/// Task code at the cursor: its lines at the cursor line's indent (CRLF as the text),
/// the cursor in its first `""` with the value list open.
fn putTask(v: *View, snippet: []const u8) !void {
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

/// Typed text; inside a string argument with known values the list stays open.
pub fn typed(v: *View, s: []const u8) void {
    v.buf.typeText(s) catch {};
    v.tasks = false;
    const w = v.buf.wordBefore();
    v.popup = w.len >= 2 or code.stringArgAt(v.buf.str(), v.buf.cursor) != null;
    if (v.popup) v.popup_sel = 0;
    follow(v);
}

/// The whole text formatted (code.format, two spaces a level): one undo step.
pub fn formatText(app: *App, v: *View) void {
    const t = code.format(app.gpa, v.buf.str(), "  ") catch return;
    defer app.gpa.free(t);
    if (std.mem.eql(u8, t, v.buf.str())) return;
    const cur = v.buf.cursor;
    v.buf.replaceSpan(0, v.buf.str().len, t) catch return;
    v.buf.cursor = @min(cur, t.len);
}

/// A key in the code editor; true when it took it. As VS Code and Zed on the Mac: Alt
/// moves by words, Cmd to the line's or the text's ends (Ctrl by words elsewhere).
pub fn key(app: *App, v: *View, k: c.SDL_Keycode, mod: c.SDL_Keymod) bool {
    const mac = @import("builtin").os.tag == .macos;
    const cmd = (mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI)) != 0;
    const shift = (mod & c.SDL_KMOD_SHIFT) != 0;
    const alt = (mod & c.SDL_KMOD_ALT) != 0;
    const word = if (mac) alt else (mod & c.SDL_KMOD_CTRL) != 0;
    const edge = mac and (mod & c.SDL_KMOD_GUI) != 0;
    const b = &v.buf;
    // Moves and deletes first: their modifiers differ by platform.
    switch (k) {
        c.SDLK_LEFT => if (word) b.wordLeft(shift) else if (edge) b.home(shift) else b.left(shift),
        c.SDLK_RIGHT => if (word) b.wordRight(shift) else if (edge) b.end(shift) else b.right(shift),
        c.SDLK_HOME => if (cmd) b.docEdge(false, shift) else b.home(shift),
        c.SDLK_END => if (cmd) b.docEdge(true, shift) else b.end(shift),
        c.SDLK_UP, c.SDLK_DOWN => {
            const down = k == c.SDLK_DOWN;
            if (v.popup and !alt and !cmd) {
                if (down) v.popup_sel += 1 else v.popup_sel -|= 1;
                return true;
            }
            if (alt and shift) b.duplicateLines() catch {} else if (alt) b.moveLines(down) catch {} else if (edge) b.docEdge(down, shift) else b.vertical(if (down) 1 else -1, shift);
        },
        c.SDLK_BACKSPACE => {
            if (word or edge) b.deleteBack(edge) catch {} else b.backspace() catch {};
            v.popup = v.popup and (b.wordBefore().len >= 1 or code.stringArgAt(b.str(), b.cursor) != null);
            follow(v);
            return true;
        },
        c.SDLK_DELETE => if (word) b.deleteWordForward() catch {} else b.deleteForward() catch {},
        else => return keyRest(app, v, k, cmd, shift),
    }
    v.popup = false;
    v.tasks = false;
    follow(v);
    return true;
}

fn keyRest(app: *App, v: *View, k: c.SDL_Keycode, cmd: bool, shift: bool) bool {
    const b = &v.buf;
    if (cmd) switch (k) {
        c.SDLK_S => app.save(),
        c.SDLK_Z => if (shift) b.redoLast() catch {} else b.undoLast() catch {},
        c.SDLK_Y => b.redoLast() catch {},
        c.SDLK_A => b.selectAll(),
        c.SDLK_C, c.SDLK_X => {
            // No selection: the whole line (as VS Code).
            const s = b.selection() orelse line: {
                b.selectLine(b.cursor, false);
                break :line b.selection() orelse return true;
            };
            const z = app.gpa.dupeSentinel(u8, b.str()[s[0]..s[1]], 0) catch return true;
            defer app.gpa.free(z);
            _ = c.SDL_SetClipboardText(z.ptr);
            if (k == c.SDLK_X) b.backspace() catch {} else b.anchor = if (b.selection() != null and s[1] == b.cursor and std.mem.endsWith(u8, z, "\n")) null else b.anchor;
        },
        c.SDLK_V => if (c.SDL_GetClipboardText()) |p| {
            defer c.SDL_free(p);
            b.insert(std.mem.span(p)) catch {};
        },
        // Ctrl+Space: values in a string argument, words after a word, else the tasks.
        c.SDLK_SPACE => {
            v.popup = true;
            v.popup_sel = 0;
            v.tasks = b.wordBefore().len == 0 and code.stringArgAt(b.str(), b.cursor) == null;
            return true;
        },
        c.SDLK_SLASH => b.lines(.comment) catch {},
        c.SDLK_RIGHTBRACKET => b.lines(.indent) catch {},
        c.SDLK_LEFTBRACKET => b.lines(.outdent) catch {},
        c.SDLK_L => b.selectLine(b.cursor, true),
        c.SDLK_K => if (shift) b.deleteLines() catch {} else return false,
        c.SDLK_D => if (shift) b.duplicateLines() catch {} else return false,
        c.SDLK_RETURN, c.SDLK_KP_ENTER => b.openLine(shift) catch {},
        c.SDLK_F => if (shift) formatText(app, v) else openFind(app, v),
        c.SDLK_G => findNext(v, !shift),
        else => return false,
    } else switch (k) {
        c.SDLK_ESCAPE => if (v.popup) {
            v.popup = false;
            v.tasks = false;
        } else if (v.find_open) {
            v.find_open = false;
        } else {
            b.anchor = null;
        },
        c.SDLK_RETURN, c.SDLK_KP_ENTER => if (!accept(app, v)) b.newline() catch {},
        // Tab: the chosen word, the next argument, or two spaces; over lines, them in.
        c.SDLK_TAB => if (shift) {
            b.lines(.outdent) catch {};
        } else if (!accept(app, v)) {
            if (multiLine(b)) b.lines(.indent) catch {} else if (!b.nextArg()) b.insert("  ") catch {};
        },
        c.SDLK_F1 => v.help = !v.help,
        c.SDLK_F3 => findNext(v, !shift),
        c.SDLK_F12 => goDefinition(app, v),
        c.SDLK_PAGEUP => b.vertical(-@as(i32, @intCast(visibleLines(v))), shift),
        c.SDLK_PAGEDOWN => b.vertical(@intCast(visibleLines(v)), shift),
        else => return true,
    }
    if (!(cmd and k == c.SDLK_SPACE) and !((k == c.SDLK_RETURN or k == c.SDLK_KP_ENTER or k == c.SDLK_TAB) and v.popup)) {
        v.popup = false;
        v.tasks = false;
    }
    follow(v);
    return true;
}

fn multiLine(b: *const code.Buffer) bool {
    const s = b.selection() orelse return false;
    return std.mem.indexOfScalar(u8, b.str()[s[0]..s[1]], '\n') != null;
}

/// Cmd+F: the find field, the selection (one line) in it.
fn openFind(app: *App, v: *View) void {
    v.find_open = true;
    if (v.buf.selection()) |s| {
        const w = v.buf.str()[s[0]..s[1]];
        if (std.mem.indexOfScalar(u8, w, '\n') == null) v.setFind(w);
    }
    // The field takes the typing at once.
    @import("textedit.zig").focus(app, "code_find", v.findText());
}

/// The next (`forward`) or previous match of the find text, selected.
fn findNext(v: *View, forward: bool) void {
    const q = v.findText();
    const t = v.buf.str();
    if (q.len == 0 or q.len > t.len) return;
    const from = if (v.buf.selection()) |s| (if (forward) s[1] else s[0]) else v.buf.cursor;
    const at = if (forward)
        (findFrom(t, q, from) orelse findFrom(t, q, 0))
    else
        (findBefore(t, q, from) orelse findBefore(t, q, t.len));
    const i = at orelse return;
    v.buf.anchor = i;
    v.buf.cursor = i + q.len;
    v.buf.want_col = null;
    follow(v);
}

fn findFrom(t: []const u8, q: []const u8, from: usize) ?usize {
    if (from > t.len) return null;
    const i = std.ascii.findIgnoreCase(t[from..], q) orelse return null;
    return from + i;
}

fn findBefore(t: []const u8, q: []const u8, before: usize) ?usize {
    var best: ?usize = null;
    var i: usize = 0;
    while (findFrom(t, q, i)) |k| : (i = k + 1) {
        if (k + q.len > before) break;
        best = k;
    }
    return best;
}

/// F12, Cmd+click: the function named at the cursor, in this file or another game script.
fn goDefinition(app: *App, v: *View) void {
    const t = v.buf.str();
    const w = wordAt(t, v.buf.cursor);
    if (w.len == 0) return;
    var fa: std.heap.FixedBufferAllocator = .init(&def_buf);
    for (functions(fa.allocator(), t)) |f| if (std.mem.eql(u8, f.name, w)) {
        v.buf.anchor = null;
        v.buf.cursor = f.at;
        follow(v);
        return;
    };
    const g = gameFn(app, w) orelse return;
    const bar = std.mem.indexOfScalar(u8, g.file, '|') orelse return;
    open(app, app.store.file(g.file[0..bar], g.file[bar + 1 ..]) catch return, g.at);
}

var def_buf: [16 * 1024]u8 = undefined;

/// Scrolls so the cursor's line is shown.
fn follow(v: *View) void {
    const t = v.buf.str();
    var line: usize = 0;
    for (t[0..v.buf.cursor]) |ch| line += @intFromBool(ch == '\n');
    const vis = visibleLines(v);
    if (line < v.scroll) v.scroll = line;
    if (line >= v.scroll + vis) v.scroll = line + 1 - vis;
}

pub fn wheel(v: *View, dy: f32) void {
    const step: i64 = @intFromFloat(-dy * 3);
    v.scroll = @intCast(@max(0, @as(i64, @intCast(v.scroll)) + step));
}

pub fn over(v: *const View, p: [2]f32) bool {
    return p[0] >= v.rect.x and p[0] < v.rect.x + v.rect.w and p[1] >= v.rect.y and p[1] < v.rect.y + v.rect.h;
}

/// A press with `clicks` (2: the word, 3: the line); Cmd+click goes to the function.
pub fn press(app: *App, v: *View, p: [2]f32, clicks: u8, mod: c.SDL_Keymod) void {
    pointer(app, v, p, (mod & c.SDL_KMOD_SHIFT) != 0);
    if (clicks == 2) v.buf.selectWord(v.buf.cursor) else if (clicks >= 3) v.buf.selectLine(v.buf.cursor, false);
    if (clicks == 1 and (mod & (c.SDL_KMOD_GUI | c.SDL_KMOD_CTRL)) != 0) goDefinition(app, v);
}

/// Pointer at `p` (press: cursor there; drag: select up to there).
pub fn pointer(app: *App, v: *View, p: [2]f32, drag: bool) void {
    const t = v.buf.str();
    const row: usize = @intFromFloat(@max(0, (p[1] - v.rect.y - 4) / line_h));
    var ls: usize = 0;
    var n: usize = 0;
    while (n < v.scroll + row and ls < t.len) : (n += 1) {
        const e = code.lineEnd(t, ls);
        if (e >= t.len) break;
        ls = next(t, ls);
    }
    const le = code.lineEnd(t, ls);
    // The character boundary nearest the pointer.
    var i = ls;
    const x0 = v.rect.x + gutter;
    while (i < le) {
        var k = i + 1;
        while (k < le and t[k] & 0xc0 == 0x80) k += 1;
        const mid = x0 + (width(app, t[ls..i]) + width(app, t[ls..k])) / 2;
        if (p[0] < mid) break;
        i = k;
    }
    if (drag) {
        if (v.buf.anchor == null) v.buf.anchor = v.buf.cursor;
    } else v.buf.anchor = null;
    v.buf.cursor = i;
    v.buf.want_col = null;
    v.buf.typing = false;
    v.popup = false;
}

//! The code window's checks (codeview.zig): unknown functions and hooks, bad values,
//! missing files, scene commands; the game's own functions (script headers).

const std = @import("std");
const Allocator = std.mem.Allocator;
const tx = @import("text.zig");
const code = @import("code.zig");
const api = @import("api.zig");
const callbacks = @import("callbacks.zig");
const rulescheck = @import("rulescheck.zig");
const refs_mod = @import("refs.zig");
const codenav = @import("codenav.zig");
const model = @import("model.zig");
const og = @import("opengorky");
const app_mod = @import("app.zig");
const App = app_mod.App;
const View = code.View;
const codetips = @import("codetips.zig");
const codecomplete = @import("codecomplete.zig");

const problem = codetips.problem;
const hooksFile = codecomplete.hooksFile;
const levelFile = codecomplete.levelFile;

/// Object scripts the engine's parser reads (scene `.scr` files are another language).
pub fn checkable(title: []const u8) bool {
    for (@import("catalog.zig").script_exts ++ [_][]const u8{ ".s", ".ss" }) |x| {
        if (std.ascii.endsWithIgnoreCase(title, x)) return true;
    }
    return false;
}

/// An OpenGorky project's own text (`src/**.ogs`): checked by the OG Script parser and
/// linker (checkOgs), never by the Classic parser.
pub fn ogsText(title: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(title, ".ogs");
}

/// Parses the text again if it changed (the game's own parser, as the engine loads it).
pub fn check(app: *App, v: *View) void {
    // Again after the text, the language or the game changed (another file edited, an
    // entity added: what the values name).
    if (v.checked == v.buf.version and v.checked_lang == tx.lang and std.mem.eql(usize, &v.checked_store, &storeKey(app))) return;
    v.checked = v.buf.version;
    v.checked_lang = tx.lang;
    v.checked_store = storeKey(app);
    v.err_line = 0;
    v.err_len = 0;
    v.force = false;
    v.unknown_n = 0;
    if (v.ogs_view) return checkView(app, v);
    if (isScene(v.title)) return checkScene(v);
    if (!checkable(v.title) and !ogsText(v.title)) return;
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    // Rules files (og.rules) are OGS: the rows of the rules' tables; the hooks file's
    // game components. An OpenGorky project's every text too.
    if (std.mem.eql(u8, app.store.files.items[v.file].archive, @import("store.zig").og_src)) return checkOgs(app, v, arena.allocator());
    if (ogsText(v.title)) return;
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
    // A level script's On… functions are its own hooks in OpenGorky; Classic never calls them.
    if (levelFile(app, v)) for (unit.items) |it| if (it == .function) {
        const f = it.function;
        if (og.script.traits.hook(f.name)) |h| {
            if (!app.ogLayout()) noteMsg(v, f.line, h.name, false, tx.alloc(arena.allocator(), tx.code_hook_classic, .{h.name})) else if (h.arity() != f.params.len) noteHook(v, f.line, h.name, .hook_args);
        }
    };
    // Functions the engine calls: as many parameters as it passes at most, of its types
    // (more get 0 or "", another type is converted: script/runtime.zig callScript).
    for (unit.items) |it| if (it == .function) {
        const f = it.function;
        const cb = callbacks.find(f.name) orelse continue;
        const fits = f.params.len <= cb.params.len and for (f.params, cb.params[0..f.params.len]) |p, q| {
            if (!std.ascii.startsWithIgnoreCase(q.decl, @tagName(p.type))) break false;
        } else true;
        if (fits) continue;
        var sig: std.ArrayList(u8) = .empty;
        sig.print(arena.allocator(), "{s}(", .{cb.name}) catch {};
        for (cb.params, 0..) |q, k| sig.print(arena.allocator(), "{s}{s}", .{ if (k > 0) ", " else "", q.decl }) catch {};
        sig.append(arena.allocator(), ')') catch {};
        noteMsg(v, f.line, f.name, false, tx.alloc(arena.allocator(), tx.code_engine_calls, .{sig.items}));
    };
    var lower: [128]u8 = undefined;
    for (calls.items) |cl| {
        // Classic: the exe has no port-only builtin (GetClass): its call does nothing there.
        if (!app.ogLayout() and !own.contains(cl.name)) if (api.find(cl.name)) |f| if (api.portOnly(f)) {
            noteHook(v, cl.line, f.name, .port_only);
            continue;
        };
        if (api.known(cl.name) or own.contains(cl.name) or cl.name.len > lower.len) continue;
        if (fns.contains(std.ascii.lowerString(&lower, cl.name))) continue;
        noteUnknown(v, cl.line, cl.name);
    }
    // Builtins called with fewer arguments than they need (more are ignored, as the
    // game's own scripts pass at times).
    for (calls.items) |cl| if (!own.contains(cl.name)) if (api.find(cl.name)) |f| {
        var pb: [12]api.Param = undefined;
        var need: usize = 0;
        for (api.params(f, &pb)) |p| need += @intFromBool(!p.optional);
        if (cl.args.len < need) noteHook(v, cl.line, cl.name, .args);
        badValues(app, v, arena.allocator(), f, cl);
    };
    missingFiles(app, v);
}

/// A Classic script in its OG Script view: an OG Script parse error, or what the Classic
/// exporter refuses (no text of the original's language, a change in an included file),
/// at its line of the view.
fn checkView(app: *App, v: *View) void {
    const src = code.toGame(app.gpa, v.buf.str(), app.catalog.cyrillic) catch return;
    defer app.gpa.free(src);
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    var d: model.CodeDiag = .{};
    const t = model.setCode(app, app.gpa, v.file, src, true, &d) catch |err| return switch (err) {
        error.Parse => ogsError(v, d.line, d.message),
        error.NotClassic => ogsError(v, d.line, tx.alloc(arena.allocator(), tx.code_not_classic, .{d.message})),
        error.OtherFile => ogsError(v, 1, tx.alloc(arena.allocator(), tx.code_other_file, .{d.message})),
        else => {},
    };
    app.gpa.free(t);
}

/// A rules file (OGS): a parse or link error; the hooks file's game components' On…
/// methods against the hooks the engine calls; another file's code (rules\abilities.ss)
/// linked too, its link warnings as notes (an On…/Can… method named close to an event of
/// its traits, script/traits.zig); its rows: their fields and values.
fn checkOgs(app: *App, v: *View, a: Allocator) void {
    var diag: og.script.ogs.parser.Diagnostic = .{};
    const u = og.script.ogs.parser.parse(a, v.buf.str(), v.title, &diag) catch return ogsError(v, diag.line, diag.message);
    const code_file = for (u.modules) |m| {
        if (m.fns.len + m.components.len > 0) break true;
    } else false;
    if (code_file and !hooksFile(app, v)) {
        if (!linkOwn(app, v, a, u)) return;
        sigilHints(v, a, u);
    }
    if (hooksFile(app, v)) {
        // Linked as the engine links it (state/hooks.zig): unknown functions, arguments.
        if (!linkOwn(app, v, a, u)) return;
        sigilHints(v, a, u);
        for (u.modules) |m| for (m.components) |c| for (c.methods) |f| {
            const h = og.script.traits.hook(f.name);
            if (h != null and std.mem.eql(u8, h.?.name, f.name)) {
                if (h.?.arity() != f.params.len) noteHook(v, f.line, h.?.name, .hook_args);
            } else if (std.ascii.startsWithIgnoreCase(f.name, "on")) noteHook(v, f.line, f.name, .hook);
        };
        return missingFiles(app, v);
    }
    var list: std.ArrayList(*const og.script.ir.Expr) = .empty;
    for (u.modules) |m| list.appendSlice(a, m.rows) catch {};
    var issues: std.ArrayList(rulescheck.Issue) = .empty;
    rulescheck.unarmed(app, a, u, &issues);
    rulescheck.rows(a, list.items, &issues);
    _ = gameFns(app);
    rulescheck.values(app, a, list.items, &game_ids, &issues);
    rulescheck.stray(a, u, &game_ids, &issues);
    var class_ids: rulescheck.ClassIds = .empty;
    for (app.catalog.entries.items) |e| if (e.name_id) |id| {
        const cl = og.rules.stem(e.entry);
        class_ids.put(a, std.ascii.allocLowerString(a, cl) catch continue, id) catch {};
    };
    rulescheck.overridden(a, list.items, &class_ids, &issues);
    for (issues.items) |is| noteMsg(v, is.line, is.name, is.quoted, is.msg);
    // shortcut: an OpenGorky project's own texts name files as its reader finds them (voice/…,
    // a dialog block for x.dlg, the installed game's avi/), which missingFiles does not;
    // `gorky-tool build` (Play) checks its assets. Upgrade: an OG-aware lookup.
    if (app.store.root == null) missingFiles(app, v);
}

/// Code `u` (the view's text) linked as the engine links it (state/hooks.zig): against
/// the whole loaded program — the hooks and the rules' other code files (another file's
/// function or component is known) — only its own calls checked; false: an error noted.
fn linkOwn(app: *App, v: *View, a: Allocator, u: og.script.ogs.parser.Unit) bool {
    var p: og.script.ogs.link.Program = .{};
    var ld: og.script.ogs.link.Diagnostic = .{};
    const own = app.store.files.items[v.file].entry;
    var others: std.ArrayList(og.script.ogs.parser.Unit) = .empty;
    for (og.rules.scripts) |t| if (!std.ascii.eqlIgnoreCase(t.name, own)) if (other(a, t.name, t.data, u)) |x| others.append(a, x) catch {};
    // A level in several texts: one block, as every reader makes it (else each part after
    // the first defined it twice and was dropped, its names unknown).
    _ = og.script.ogs.levels.merge(a, others.items) catch {};
    for (others.items) |x| {
        var od: og.script.ogs.link.Diagnostic = .{};
        p.add(a, x, &od) catch {};
    }
    // The others' own calls are theirs to check (their views).
    p.linked = p.texts.items.len;
    var has: Has = .{ .app = app, .a = a };
    const env: og.script.ogs.link.Env = .{ .ctx = &has, .builtin = apiBuiltin, .exists = Has.exists, .schema = og.core.schema.blockField, .natives = og.core.natives.components() };
    p.add(a, u, &ld) catch {
        ogsError(v, ld.line, ld.message);
        return false;
    };
    p.link(a, env, &ld) catch {
        ogsError(v, ld.line, ld.message);
        return false;
    };
    // Only its own text was linked: the warnings are its (the hooks file notes its own).
    if (!hooksFile(app, v)) for (p.warnings.items) |w| noteMsg(v, w.line, w.parts[0], false, tx.alloc(a, tx.code_near_event, .{ w.parts[0], w.parts[1], w.parts[2] }));
    return true;
}

/// A plain string where a linked builtin takes a level, a scene, a sound…: a note to
/// write it with its sigil (`~l"01_port"`), checked when the code loads.
fn sigilHints(v: *View, a: Allocator, u: og.script.ogs.parser.Unit) void {
    const ir = og.script.ir;
    const W = struct {
        v: *View,
        a: Allocator,
        fn stmts(w: @This(), list: []const ir.Stmt) void {
            for (list) |s| switch (s.kind) {
                .expr, .@"return" => |e| w.expr(e),
                .assign => |x| w.expr(x.value),
                .@"if" => |x| {
                    w.expr(x.cond);
                    w.stmts(x.then);
                    w.stmts(x.@"else");
                },
                .@"while" => |x| {
                    w.expr(x.cond);
                    w.stmts(x.body);
                },
                .for_in => |x| {
                    w.expr(x.iter);
                    w.stmts(x.body);
                },
                else => {},
            };
        }
        fn expr(w: @This(), e: *const ir.Expr) void {
            switch (e.kind) {
                .call => |c| {
                    for (c.args) |x| w.expr(x);
                    const t = c.target orelse return;
                    if (t.* != .builtin) return;
                    const sig = (apiBuiltin(undefined, c.text) orelse return).sig;
                    for (c.args, 0..) |x, k| {
                        if (x.sigil != .none or x.kind != .lit or x.kind.lit != .string) continue;
                        const kind = ir.Sigil.ofType(og.script.ogs.link.sigType(sig, k)) orelse continue;
                        noteMsg(w.v, x.line, x.kind.lit.string, true, tx.alloc(w.a, tx.code_use_sigil, .{ c.text, @tagName(kind), kind.letter(), x.kind.lit.string }));
                    }
                },
                .binary => |b| {
                    w.expr(b.lhs);
                    w.expr(b.rhs);
                },
                .logic => |b| {
                    w.expr(b.lhs);
                    w.expr(b.rhs);
                },
                .unary => |x| w.expr(x.operand),
                else => {},
            }
        }
    };
    const w: W = .{ .v = v, .a = a };
    for (u.modules) |m| {
        for (m.fns) |f| w.stmts(f.body);
        for (m.components) |c| for (c.methods) |f| w.stmts(f.body);
    }
}

/// Another loaded text, to add to the program (null: it does not parse, left out as the
/// engine leaves it), without the parts of a level `own` writes too (a level in several
/// texts, script/ogs/levels.zig: the view's part is checked as its own).
pub fn other(a: Allocator, name: []const u8, src: []const u8, own: og.script.ogs.parser.Unit) ?og.script.ogs.parser.Unit {
    var u = parsedOther(name, src) orelse return null;
    const ms = a.dupe(og.script.ir.Module, u.modules) catch return null;
    for (ms) |*m| {
        var keep: std.ArrayList(og.script.ir.Entity) = .empty;
        for (m.entities) |e| if (!ownsLevel(own, m.path, e)) keep.append(a, e) catch return null;
        m.entities = keep.items;
    }
    u.modules = ms;
    return u;
}

/// The other texts parsed, by name, parsed again only when their text changes: a check
/// parsed all of a project's texts (~800) at every keystroke. Null: it does not parse.
var parsed_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var parsed: std.StringHashMapUnmanaged(struct { hash: u64, unit: ?og.script.ogs.parser.Unit }) = .empty;
var parsed_stale: usize = 0;

fn parsedOther(name: []const u8, src: []const u8) ?og.script.ogs.parser.Unit {
    const h = std.hash.Wyhash.hash(0, src);
    if (parsed.get(name)) |e| if (e.hash == h) return e.unit;
    // Replaced parses stay in the arena: start over once many have.
    if (parsed.contains(name)) parsed_stale += 1;
    if (parsed_stale > 64) {
        parsed_stale = 0;
        parsed = .empty;
        _ = parsed_arena.reset(.retain_capacity);
    }
    const pa = parsed_arena.allocator();
    var diag: og.script.ogs.parser.Diagnostic = .{};
    const u = og.script.ogs.parser.parse(pa, src, name, &diag) catch null;
    const key = if (parsed.getKey(name)) |k| k else pa.dupe(u8, name) catch return u;
    parsed.put(pa, key, .{ .hash = h, .unit = u }) catch {};
    return u;
}

/// `u` has level block `e` (of module `path`) too.
fn ownsLevel(u: og.script.ogs.parser.Unit, path: []const u8, e: og.script.ir.Entity) bool {
    if (!std.mem.eql(u8, e.kind, "level") and !std.mem.eql(u8, e.kind, "battle")) return false;
    for (u.modules) |m| if (std.mem.eql(u8, m.path, path)) for (m.entities) |x| if (std.mem.eql(u8, x.kind, e.kind) and std.mem.eql(u8, x.name, e.name)) return true;
    return false;
}

fn ogsError(v: *View, line: u32, message: []const u8) void {
    v.err_line = @max(1, line);
    const m = std.fmt.bufPrint(&v.err_buf, "{s}", .{message}) catch v.err_buf[0..0];
    v.err_len = m.len;
}

/// Whether the game has a `kind` named `name` (a sigil's string): the levels, scenes and
/// sounds the editor lists whole; other kinds unknown (null: not checked).
const Has = struct {
    app: *App,
    a: Allocator,

    fn exists(ctx: *anyopaque, kind: og.script.ir.Sigil, name: []const u8) ?bool {
        const h: *Has = @ptrCast(@alignCast(ctx));
        return switch (kind) {
            .level => h.app.levelIndex(name) != null,
            .scene => h.app.sceneIndex(name) != null,
            .sound => for (h.app.player.names(h.app, h.a)) |n| {
                if (std.ascii.eqlIgnoreCase(n[0 .. std.mem.lastIndexOfScalar(u8, n, '.') orelse n.len], name) or std.ascii.eqlIgnoreCase(n, name)) break true;
            } else false,
            else => null,
        };
    }
};

/// A builtin of the engine's (api.zig) in its exact case: what OGS may call, with the
/// engine's signature (its parameter names: named arguments link as in the engine).
/// Builtin `name` as OG Script calls it (`fighter::SetHp`); its exe name: where OG Script
/// has it (`moved`), as the engine's link says (script/runtime.zig envBuiltin).
fn apiBuiltin(_: *anyopaque, name: []const u8) ?og.script.ogs.link.Builtin {
    const f = api.find(name) orelse return null;
    const sig = inline for (og.builtins.table) |e| {
        if (std.mem.eql(u8, e[0], f.name)) break e[2].text;
    } else "";
    if (std.mem.eql(u8, api.ogsName(f), name)) return .{ .id = 0, .sig = sig };
    if (std.mem.eql(u8, f.name, name)) return .{ .id = 0, .sig = sig, .moved = api.ogsName(f) };
    return null;
}

/// String arguments naming a level, a scene or a sound the game lacks (lists the editor
/// holds whole: the levels' folders, the scenes, the sound banks; other names are not
/// checked: objects come and go as scripts run).
fn badValues(app: *App, v: *View, a: Allocator, f: *const api.Fn, cl: Call) void {
    var pb: [12]api.Param = undefined;
    for (api.params(f, &pb), 0..) |p, k| {
        if (k >= cl.args.len or cl.args[k].kind != .string) continue;
        const s = cl.args[k].kind.string;
        const kind = p.decl[(std.mem.indexOfScalar(u8, p.decl, ' ') orelse continue) + 1 ..];
        const found = if (std.mem.eql(u8, kind, "level")) app.levelIndex(s) != null else if (std.mem.eql(u8, kind, "scene")) app.sceneIndex(s) != null else if (std.mem.eql(u8, kind, "sound") and std.mem.indexOfScalar(u8, s, '.') == null) for (app.player.names(app, a)) |n| {
            if (std.ascii.eqlIgnoreCase(n[0 .. std.mem.lastIndexOfScalar(u8, n, '.') orelse n.len], s)) break true;
        } else false else true;
        if (!found and s.len > 0) noteMsg(v, cl.line, s, true, tx.alloc(a, tx.code_no_value, .{ f.name, kind, s }));
    }
}

/// Every script and rules file of the game checked as the code view does: its problems
/// printed (`archive|entry:line: message`), then their count (scripted `--code-check-all`).
pub fn checkAll(app: *App) !void {
    var tmp: std.heap.ArenaAllocator = .init(app.gpa);
    defer tmp.deinit();
    const a = tmp.allocator();
    var paths: std.ArrayList([]const u8) = .empty;
    const list = try og.formats.archive.listArchives(app.io, app.gpa, app.dat);
    defer og.formats.archive.freeList(app.gpa, list);
    try paths.appendSlice(a, list);
    for (paths.items) |x| {
        if (std.mem.eql(u8, x, @import("store.zig").og_src)) break;
    } else try paths.append(a, @import("store.zig").og_src);
    var files: usize = 0;
    var hits: usize = 0;
    const keep = struct {
        fn f(n: []const u8) bool {
            return refs_mod.script(n) or std.ascii.endsWithIgnoreCase(n, ".scr") or ogsText(n);
        }
    }.f;
    for (paths.items) |p| for (refs_mod.files(app, a, p, keep)) |f| {
        const fi = app.store.file(p, f.name) catch continue;
        const utf8 = code.fromFile(app.gpa, app.store.text(fi), @import("codetabs.zig").isUtf8(app, fi), app.catalog.cyrillic) catch continue;
        defer app.gpa.free(utf8);
        var v: View = .{ .buf = try code.Buffer.init(app.gpa, utf8), .file = fi, .title = try a.dupe(u8, f.name) };
        defer v.buf.deinit();
        check(app, &v);
        files += 1;
        if (v.err_line > 0) {
            hits += 1;
            std.debug.print("{s}|{s}:{d}: {s}\n", .{ p, f.name, v.err_line, v.err() });
        }
        for (v.unknown[0..v.unknown_n]) |*u| {
            hits += 1;
            std.debug.print("{s}|{s}: {s}\n", .{ p, f.name, problem(a, u) });
        }
    };
    std.debug.print("code check: {d} files, {d} problems\n", .{ files, hits });
}

/// Strings naming a file (by its extension) that no archive, sound bank or video
/// folder has.
fn missingFiles(app: *App, v: *View) void {
    const t = v.buf.str();
    var tmp: std.heap.ArenaAllocator = .init(app.gpa);
    defer tmp.deinit();
    var line: u32 = 1;
    var i: usize = 0;
    while (i < t.len) : (i += 1) switch (t[i]) {
        '\n' => line += 1,
        '/' => if (i + 1 < t.len and t[i + 1] == '/') {
            i = code.lineEnd(t, i) -| 1;
        },
        '"' => {
            const e = std.mem.indexOfAnyPos(u8, t, i + 1, "\"\n") orelse break;
            if (t[e] == '\n') continue;
            const str = t[i + 1 .. e];
            i = e;
            const dot = std.mem.lastIndexOfScalar(u8, str, '.') orelse continue;
            const ext = str[dot..];
            const known = for ([_][]const u8{ ".wav", ".avi", ".asf", ".3df", ".msh", ".ani", ".spr", ".dlg", ".s", ".ss", ".scr", ".mp3" }) |x| {
                if (std.ascii.eqlIgnoreCase(ext, x)) break true;
            } else false;
            if (!known or std.mem.indexOfAny(u8, str, " ,") != null) continue;
            const found = if (std.ascii.eqlIgnoreCase(ext, ".wav")) inList(app.player.names(app, tmp.allocator()), str, false) else if (std.ascii.eqlIgnoreCase(ext, ".avi") or std.ascii.eqlIgnoreCase(ext, ".asf")) inList(@import("videopage.zig").names(app), str, true) else if (std.ascii.eqlIgnoreCase(ext, ".mp3")) inList(@import("musicpage.zig").names(app), str, false) else codenav.fileExists(app, str);
            if (!found) noteHook(v, line, str, .missing);
        },
        else => {},
    };
}

/// `name` in `list` (case aside; `any_ext`: by the name before its extension, as a
/// video named `.avi` plays its `.asf`).
fn inList(list: anytype, name: []const u8, any_ext: bool) bool {
    const stem = name[0 .. std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len];
    for (list) |x| {
        if (std.ascii.eqlIgnoreCase(x, name)) return true;
        if (any_ext and std.ascii.eqlIgnoreCase(x[0 .. std.mem.lastIndexOfScalar(u8, x, '.') orelse x.len], stem)) return true;
    }
    return false;
}

pub fn isScene(title: []const u8) bool {
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

fn noteUnknown(v: *View, line: u32, name: []const u8) void {
    if (v.unknown_n == v.unknown.len) return;
    const u = &v.unknown[v.unknown_n];
    u.kind = .call;
    u.len = @intCast(@min(name.len, u.name.len));
    @memcpy(u.name[0..u.len], name[0..u.len]);
    u.line = line;
    v.unknown_n += 1;
}

/// A problem with a message of its own (cut to fit, at a character's start).
fn noteMsg(v: *View, line: u32, name: []const u8, quoted: bool, msg: []const u8) void {
    if (v.unknown_n == v.unknown.len) return;
    noteUnknown(v, line, name);
    const u = &v.unknown[v.unknown_n - 1];
    u.kind = .note;
    u.quoted = quoted;
    var n = @min(msg.len, u.msg.len);
    while (n < msg.len and n > 0 and (msg[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(u.msg[0..n], msg[0..n]);
    u.msg_len = @intCast(n);
}

fn noteHook(v: *View, line: u32, name: []const u8, kind: @FieldType(@TypeOf(v.unknown[0]), "kind")) void {
    if (v.unknown_n == v.unknown.len) return;
    noteUnknown(v, line, name);
    v.unknown[v.unknown_n - 1].kind = kind;
}

const Call = struct { line: u32, name: []const u8, args: []const *const og.script.ast.Expr };

fn callsIn(a: Allocator, st: *const og.script.ast.Stmt, out: *std.ArrayList(Call)) void {
    switch (st.*) {
        .expr => |e| callsInExpr(a, e, out),
        .block => |b| for (b) |*x| callsIn(a, x, out),
        .@"if" => |i| {
            callsInExpr(a, i.cond, out);
            callsIn(a, i.then, out);
            if (i.@"else") |e| callsIn(a, e, out);
        },
        .@"return" => |r| if (r.value) |e| callsInExpr(a, e, out),
        .var_decl, .include, .empty => {},
    }
}

fn callsInExpr(a: Allocator, e: *const og.script.ast.Expr, out: *std.ArrayList(Call)) void {
    switch (e.kind) {
        .call => |c_| {
            out.append(a, .{ .line = e.line, .name = c_.name, .args = c_.args }) catch {};
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

/// A function a game script defines: as written, its parameters (`int x`) with their
/// comments and the comment above it (UTF-8), where (`archive|entry`, its line's byte in
/// the text).
const GameFn = struct { name: []const u8, params: []const code.HeaderParam, doc: []const u8, file: []const u8, at: usize };

/// Every function the game's scripts define (by lower-case name), read again after any
/// Store change (a function added to another script is known at once).
var game_fns: ?std.StringHashMapUnmanaged(GameFn) = null;
var game_fns_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var game_fns_key: [3]usize = .{ 0, 0, 0 };
/// Every classic_id the game's scripts declare (gamestart weapons, level actors too), named
/// by the entity's title or the script; read with `game_fns`.
var game_ids: rulescheck.Known = .empty;

/// What the Store and the catalog hold, as a key (Store.rev, Catalog.gen; the third
/// slot is unused, code.View.checked_store's shape).
pub fn storeKey(app: *const App) [3]usize {
    return .{ @intCast(app.store.rev), @intCast(app.catalog.gen), 0 };
}

pub fn gameFns(app: *App) *const std.StringHashMapUnmanaged(GameFn) {
    const now = storeKey(app);
    if (game_fns) |*g| if (std.mem.eql(usize, &now, &game_fns_key)) return g;
    game_fns_key = now;
    _ = game_fns_arena.reset(.retain_capacity);
    game_fns = .empty;
    game_ids = .empty;
    const a = game_fns_arena.allocator();
    // OpenGorky: the installed game's Classic scripts are not the project's code; parsing
    // them all (a thousand texts, seconds) after every edit froze the editor.
    if (app.ogLayout()) {
        // Every number a block of the project has (`classic_id = 23;`), named by the catalog
        // where it has the block, else by its text.
        const og_src = @import("store.zig").og_src;
        var tmp: std.heap.ArenaAllocator = .init(app.gpa);
        defer tmp.deinit();
        // An effect record's own number a weapon's stage names (`effects_from = 2000;` and
        // `WeaponFx(id = 2000, …)`, the editor's new effect): a number of the project too.
        var staged: std.AutoHashMapUnmanaged(i32, void) = .empty;
        var records: std.AutoHashMapUnmanaged(i32, []const u8) = .empty;
        for (app.store.listing(tmp.allocator(), og_src, null, false)) |p| {
            const t = app.store.text(app.store.file(og_src, p) catch continue);
            for ([_][]const u8{ "classic_id = ", "effects_from = ", "flash_from = ", "launch_from = ", "hit_from = ", "WeaponFx(id = " }, 0..) |needle, w| {
                var at: usize = 0;
                while (std.mem.indexOfPos(u8, t, at, if (w == 5) "WeaponFx(" else needle)) |k| : (at = k + 1) {
                    // A record's `id = ` after its `(`, on the next line too (a long row
                    // is on several: the OG printer).
                    var s0 = k + needle.len;
                    if (w == 5) {
                        var q = k + "WeaponFx(".len;
                        while (q < t.len and std.ascii.isWhitespace(t[q])) q += 1;
                        if (!std.mem.startsWith(u8, t[q..], "id = ")) continue;
                        s0 = q + "id = ".len;
                    }
                    var e = s0;
                    while (e < t.len and std.ascii.isDigit(t[e])) e += 1;
                    const id = std.fmt.parseInt(i32, t[s0..e], 10) catch continue;
                    const stem = a.dupe(u8, std.fs.path.stem(p)) catch "";
                    switch (w) {
                        0 => _ = game_ids.getOrPutValue(a, id, stem) catch {},
                        5 => records.put(tmp.allocator(), id, stem) catch {},
                        else => staged.put(tmp.allocator(), id, {}) catch {},
                    }
                }
            }
        }
        var rit = records.iterator();
        while (rit.next()) |r| if (staged.contains(r.key_ptr.*)) {
            _ = game_ids.getOrPutValue(a, r.key_ptr.*, r.value_ptr.*) catch {};
        };
        for (app.catalog.entries.items) |e| if (e.name_id) |id| if (e.title.len > 0) {
            game_ids.put(a, id, e.title) catch {};
        };
        return &game_fns.?;
    }
    const paths = og.formats.archive.listArchives(app.io, app.gpa, app.dat) catch return &game_fns.?;
    defer og.formats.archive.freeList(app.gpa, paths);
    var tmp: std.heap.ArenaAllocator = .init(app.gpa);
    defer tmp.deinit();
    for (paths) |p| for (refs_mod.files(app, tmp.allocator(), p, refs_mod.script)) |f| {
        var diag: og.script.parser.Diagnostic = .{};
        const unit = og.script.parser.parse(tmp.allocator(), f.text, &diag) catch continue;
        const file = @import("doctab.zig").join(a, p, f.name) catch continue;
        if (@import("model.zig").get(f.text, "classic_id")) |id| _ = game_ids.getOrPutValue(a, @intFromFloat(id), a.dupe(u8, f.name) catch "") catch {};
        for (unit.items) |it| if (it == .function) {
            const fun = it.function;
            const name = a.dupe(u8, fun.name) catch continue;
            var at: usize = 0;
            for (1..fun.line) |_| at = if (std.mem.indexOfScalarPos(u8, f.text, at, '\n')) |k| k + 1 else at;
            const h = code.header(tmp.allocator(), f.text, std.mem.indexOfPos(u8, f.text, at, "function") orelse at) orelse continue;
            const params = a.alloc(code.HeaderParam, h.params.len) catch continue;
            for (params, h.params) |*d, q| d.* = .{ .decl = code.fromGame(a, q.decl, app.catalog.cyrillic) catch "", .doc = code.fromGame(a, q.doc, app.catalog.cyrillic) catch "" };
            const doc = code.fromGame(a, h.doc, app.catalog.cyrillic) catch "";
            game_fns.?.put(a, std.ascii.allocLowerString(a, name) catch continue, .{ .name = name, .params = params, .doc = doc, .file = file, .at = at }) catch {};
        };
    };
    for (app.catalog.entries.items) |e| if (e.name_id) |id| if (e.title.len > 0) {
        game_ids.put(a, id, e.title) catch {};
    };
    return &game_fns.?;
}

/// The game script function named `w` (case aside), if any.
pub fn gameFn(app: *App, w: []const u8) ?GameFn {
    // OpenGorky: the installed game's Classic scripts are not the project's code (their
    // shared functions are its traits', codenav).
    if (app.ogLayout()) return null;
    var lower: [128]u8 = undefined;
    if (w.len > lower.len) return null;
    return gameFns(app).get(std.ascii.lowerString(&lower, w));
}

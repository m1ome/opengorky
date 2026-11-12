//! The code window's tips (codeview.zig): what the word under the pointer is, the
//! call's parameters above the line typed (declarations of functions, hooks, rules).

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const lay = @import("layout.zig");
const render = @import("render.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const code = @import("code.zig");
const api = @import("api.zig");
const callbacks = @import("callbacks.zig");
const codenav = @import("codenav.zig");
const og = @import("opengorky");
const app_mod = @import("app.zig");
const App = app_mod.App;
const View = code.View;
const codeview = @import("codeview.zig");
const codecheck = @import("codecheck.zig");
const codeside = @import("codeside.zig");
const codecomplete = @import("codecomplete.zig");

const line_h = codeview.line_h;
const offsetAt = codeview.offsetAt;
const overText = codeview.overText;
const ownFn = codeview.ownFn;
const rulesRow = codeview.rulesRow;
const gameFn = codecheck.gameFn;
const RulesAt = codeside.RulesAt;
const callName = codeside.callName;
const currentFn = codeside.currentFn;
const fieldLine = codeside.fieldLine;
const fnDesc = codeside.fnDesc;
const functions = codeside.functions;
const paramLine = codeside.paramLine;
const rulesAt = codeside.rulesAt;
const signatureOf = codeside.signatureOf;
const hooksFile = codecomplete.hooksFile;
const levelHooks = codecomplete.levelHooks;
const rulesFile = codecomplete.rulesFile;

/// The token at `i` if it leads somewhere (Go to): a function of the scripts, or what
/// codenav resolves.
pub fn linkAt(app: *App, v: *View, i: usize) ?code.Token {
    const t = v.buf.str();
    const tok = qualified(t, code.tokenAt(t, i) orelse return null);
    const w = t[tok.start..tok.end];
    if (!tok.string and (ownFn(t, w) != null or gameFn(app, w) != null)) return tok;
    return if (codenav.resolvable(app, w)) tok else null;
}

/// The pointer resting over the text: what the word there is (a function: what it does,
/// its parameters; a problem: its message; a name: where Go to leads).
pub fn hoverTip(app: *App, v: *View, a: Allocator) void {
    const now = c.SDL_GetTicks();
    if (@abs(app.mouse[0] - v.rest[0]) + @abs(app.mouse[1] - v.rest[1]) > 2) {
        v.rest = app.mouse;
        v.rest_since = now;
        return;
    }
    if (now -% v.rest_since < 600 or !overText(v, app.mouse) or v.dragging) return;
    const t = v.buf.str();
    const i = offsetAt(app, v, app.mouse);
    const tok = qualified(t, code.tokenAt(t, i) orelse return);
    const w = t[tok.start..tok.end];
    // Made once per word under the pointer: resolving it reads the game's banks and the
    // level's objects, too much for every frame it rests there.
    const key: [5]u64 = .{ v.file, tok.start, tok.end, app.store.rev, app.catalog.gen };
    if (!std.mem.eql(u64, &key, &tip_cache.key)) {
        tip_cache.key = key;
        _ = tip_cache.arena.reset(.retain_capacity);
        tip_cache.lines = tipLines(app, v, tip_cache.arena.allocator(), t, i, tok, w);
    }
    if (tip_cache.lines.len == 0) return;
    drawTip(app, a, tip_cache.lines, .{ app.mouse[0], app.mouse[1] + line_h });
}

/// Word `tok` with the namespace before it (`Load` of `level::Load` → `level::Load`): a
/// builtin's name is the whole path; the bare word named a sound `load.wav` instead.
fn qualified(t: []const u8, tok: code.Token) code.Token {
    if (tok.string) return tok;
    var s = tok.start;
    while (s >= 2 and t[s - 1] == ':' and t[s - 2] == ':') {
        var k = s - 2;
        while (k > 0 and (std.ascii.isAlphanumeric(t[k - 1]) or t[k - 1] == '_')) k -= 1;
        if (k == s - 2) break;
        s = k;
    }
    var out = tok;
    out.start = s;
    return out;
}

/// The last hover's tip lines and the word and text state they are for.
var tip_cache: struct { key: [5]u64 = @splat(std.math.maxInt(u64)), arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator), lines: []const Tip = &.{} } = .{};

fn tipLines(app: *App, v: *View, a: Allocator, t: []const u8, i: usize, tok: code.Token, w: []const u8) []const Tip {
    var lines: std.ArrayList(Tip) = .empty;
    var ln: u32 = 1;
    for (t[0..i]) |ch| ln += @intFromBool(ch == '\n');
    for (v.unknown[0..v.unknown_n]) |*u| if (u.line == ln and std.mem.eql(u8, u.name[0..u.len], w)) {
        lines.append(a, .{ .s = problem(a, u), .col = lay.canvas.code.squiggle }) catch {};
    };
    const before = lines.items.len;
    if (rulesFile(app, v)) rulesTip(app, a, t, i, &lines);
    if (lines.items.len == before and !tok.string) blockFieldTip(a, v, t, i, w, &lines);
    if (lines.items.len == before and !tok.string) blockKindTip(a, v, t, i, w, &lines);
    // A function: its declaration (on a declaration's name or parameter, that one's).
    if (lines.items.len > before) {} else if (!tok.string) {
        const da = declAt(a, t, i);
        const d = if (da) |x| declOf(app, v, a, x.name, true) else declOf(app, v, a, w, false);
        if (d) |x| declTips(a, .{ .name = x.name, .params = x.params, .cur = if (da) |y| y.arg else null, .desc = x.desc, .notes = x.notes }, &lines);
    }
    // A project declaration (codesym): its line and the `///` lines above it.
    if (lines.items.len == 0) for (@import("codesym.zig").defsAt(app, v, a, i), 0..) |d, k| {
        if (k == 3) break;
        symTip(app, v, a, d, &lines);
    };
    if (lines.items.len == 0 or (tok.string and lines.items.len == before)) for (codenav.resolve(app, a, w, false), 0..) |h, k| {
        if (k == 6) break;
        lines.append(a, .{ .s = std.fmt.allocPrint(a, "→ {s}", .{h.label}) catch "", .col = lay.canvas.code.string }) catch {};
    };
    return lines.items;
}

/// Declaration `d`'s tip: its line (to the body's `{`), its doc lines, where it is.
fn symTip(app: *App, v: *View, a: Allocator, d: @import("codesym.zig").Def, lines: *std.ArrayList(Tip)) void {
    const own = app.store.files.items[v.file];
    const text = if (std.mem.eql(u8, d.archive, own.archive) and std.ascii.eqlIgnoreCase(d.entry, own.entry)) v.buf.str() else app.store.text(app.store.file(d.archive, d.entry) catch return);
    if (d.at > text.len) return;
    const ls = code.lineStart(text, d.at);
    const line = std.mem.trim(u8, text[ls..code.lineEnd(text, ls)], " \t{");
    lines.append(a, .{ .s = line, .col = lay.canvas.code.string }) catch {};
    // The `///` lines right above, in order.
    var docs: std.ArrayList([]const u8) = .empty;
    var p = ls;
    while (p > 0) {
        const ps = code.lineStart(text, p - 1);
        const l = std.mem.trim(u8, text[ps .. p - 1], " \t\r");
        if (!std.mem.startsWith(u8, l, "///")) break;
        docs.append(a, std.mem.trim(u8, l[3..], " ")) catch {};
        p = ps;
    }
    var k = docs.items.len;
    while (k > 0) : (k -= 1) lines.append(a, .{ .s = docs.items[k - 1], .col = lay.canvas.code.tip_desc }) catch {};
    lines.append(a, .{ .s = d.label, .col = lay.canvas.code.tip_desc }) catch {};
}

/// The hover tip's lines for offset `i` (hoverTip draws them; the code probe counts them).
pub fn tipsAt(app: *App, v: *View, a: Allocator, i: usize) []const Tip {
    const t = v.buf.str();
    const tok = qualified(t, code.tokenAt(t, i) orelse return &.{});
    return tipLines(app, v, a, t, i, tok, t[tok.start..tok.end]);
}

pub const Tip = struct { s: []const u8, col: [4]u8 };

/// A data block's field statement at `i` (`accuracy = 80.0;`, word `w`): its declaration
/// (`float accuracy = 0.0 · host fighter`) and what it means, as foundation/hosts.ogs
/// declares them (script/hosts.zig), in the interface language.
fn blockFieldTip(a: Allocator, v: *View, t: []const u8, i: usize, w: []const u8, lines: *std.ArrayList(Tip)) void {
    if (!std.mem.endsWith(u8, v.title, ".ogs")) return;
    // `w =` (not `==`): a field statement.
    var k = i;
    while (k < t.len and (std.ascii.isAlphanumeric(t[k]) or t[k] == '_')) k += 1;
    while (k < t.len and (t[k] == ' ' or t[k] == '\t')) k += 1;
    if (k >= t.len or t[k] != '=' or (k + 1 < t.len and t[k + 1] == '=')) return;
    var diag: og.script.ogs.parser.Diagnostic = .{};
    const u = og.script.ogs.parser.parse(a, t, v.title, &diag) catch return;
    var kind: []const u8 = "";
    for (u.modules) |m| for (m.entities) |*e| innermost(e, i, &kind);
    if (kind.len == 0) return;
    const h = og.core.schema.blockHost(kind) orelse return;
    const fd = og.script.hosts.field(h.name, w) orelse return;
    lines.append(a, .{ .s = std.fmt.allocPrint(a, "{s} · host {s}", .{ og.script.hosts.decl(a, fd.field), fd.host.name }) catch return, .col = lay.canvas.code.call }) catch {};
    const f = fd.field;
    if (f.doc.len > 0) lines.append(a, .{ .s = f.doc, .col = lay.canvas.code.popup_text }) catch {};
}

/// A data block's kind word in its header (`weapon` of `weapon pistol {`): every variable
/// it has — its fields set here and their values, its own `var`s, then the fields of its
/// kind (foundation/hosts.ogs, its host's and parents') it does not set.
fn blockKindTip(a: Allocator, v: *View, t: []const u8, i: usize, w: []const u8, lines: *std.ArrayList(Tip)) void {
    if (!std.mem.endsWith(u8, v.title, ".ogs")) return;
    const sh = og.core.schema.blockHost(w) orelse return;
    var diag: og.script.ogs.parser.Diagnostic = .{};
    const u = og.script.ogs.parser.parse(a, t, v.title, &diag) catch return;
    var hit: ?*const og.script.ir.Entity = null;
    for (u.modules) |m| for (m.entities) |*e| headerAt(e, i, &hit);
    const e = hit orelse return;
    // Its kind word, before its `{`.
    if (!std.mem.eql(u8, e.kind, w) or std.mem.indexOfScalar(u8, t[e.span.start..i], '{') != null) return;
    lines.append(a, .{ .s = std.fmt.allocPrint(a, "{s} {s}{s}{s} · host {s}", .{ e.kind, e.name, if (e.base.len > 0) " : " else "", e.base, sh.name }) catch return, .col = lay.canvas.code.call }) catch {};
    for (e.fields) |f| lines.append(a, .{ .s = std.fmt.allocPrint(a, "  {s} = {s}", .{ f.name, @import("model_og.zig").exprText(a, f.value) }) catch continue, .col = lay.canvas.code.popup_text }) catch {};
    for (e.vars) |f| lines.append(a, .{ .s = std.fmt.allocPrint(a, "  var {s}", .{og.script.hosts.decl(a, &f)}) catch continue, .col = lay.canvas.code.popup_text }) catch {};
    // The rest its kind takes, by name: what it can set.
    var rest: std.ArrayList(u8) = .empty;
    var h = og.script.hosts.host(sh.name);
    while (h) |x| : (h = if (x.parent.len > 0) og.script.hosts.host(x.parent) else null) for (x.fields) |f| {
        const set = for (e.fields) |g| {
            if (std.mem.eql(u8, g.name, f.name)) break true;
        } else false;
        if (set) continue;
        rest.print(a, "{s}{s}", .{ if (rest.items.len > 0) ", " else "", f.name }) catch {};
    };
    if (rest.items.len > 0) lines.append(a, .{ .s = tx.alloc(a, tx.tip_block_rest, .{rest.items}), .col = lay.canvas.code.comment }) catch {};
}

/// The innermost block of `e` whose text holds offset `i`.
fn headerAt(e: *const og.script.ir.Entity, i: usize, hit: *?*const og.script.ir.Entity) void {
    if (e.span.none() or i < e.span.start or i >= e.span.end) return;
    hit.* = e;
    for (e.children) |*ch| headerAt(ch, i, hit);
}

/// The kind of the innermost block of `e` whose text holds offset `i`.
fn innermost(e: *const og.script.ir.Entity, i: usize, kind: *[]const u8) void {
    if (e.span.none() or i < e.span.start or i >= e.span.end) return;
    kind.* = e.kind;
    for (e.children) |*ch| innermost(ch, i, kind);
}

/// A rules file's tip at offset `i`: a call's fields and what it is, or a field's line
/// and what its value means.
fn rulesTip(app: *App, a: Allocator, t: []const u8, i: usize, lines: *std.ArrayList(Tip)) void {
    if (callName(t, i)) |rc| {
        lines.append(a, .{ .s = signatureOf(a, rc), .col = lay.canvas.code.call }) catch {};
        lines.append(a, .{ .s = tx.get(rc.doc), .col = lay.canvas.code.plain }) catch {};
        for (rc.fields) |*f| lines.append(a, .{ .s = fieldLine(a, rc, f), .col = lay.canvas.code.tip_desc }) catch {};
        return;
    }
    const r = rulesAt(t, i) orelse return;
    const f = r.field orelse return;
    lines.append(a, .{ .s = std.fmt.allocPrint(a, "{s}.{s}", .{ r.call.name, fieldLine(a, r.call, f) }) catch "", .col = lay.canvas.code.call }) catch {};
    const means = codenav.rulesMeaning(app, a, f, r.arg.?.value);
    if (means.len > 0) lines.append(a, .{ .s = std.fmt.allocPrint(a, "{s}: {s}", .{ r.arg.?.value, means }) catch "", .col = lay.canvas.code.string }) catch {};
    // A number conversion wrote out of a tuning value: which one.
    if (rulesRow(t, i)) |row| {
        const o = og.loaders.rules_text.adjustOrigin(a, og.loaders.codec.oneRow(a, row.src) orelse return, f.name) orelse return;
        const about = if (@import("adjustdoc.zig").get(o.name)) |m| tx.get(m) else "";
        lines.append(a, .{ .s = tx.alloc(a, tx.code_adjust_origin, .{ o.text, about }), .col = lay.canvas.code.tip_desc }) catch {};
    }
}

/// `s` (a caption) broken at spaces into lines at most `max_w` wide.
fn wrap(app: *App, a: Allocator, s: []const u8, max_w: f32) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var rest = s;
    while (rest.len > 0) {
        var cut = rest.len;
        while (app.font.measure(rest[0..cut], font_mod.regular, lay.Type.caption.pt())[0] > max_w) {
            cut = std.mem.lastIndexOfScalar(u8, rest[0 .. cut - 1], ' ') orelse break;
        }
        out.append(a, rest[0..cut]) catch break;
        rest = std.mem.trimStart(u8, rest[cut..], " ");
    }
    return out.items;
}

/// A box of lines at `at` (kept inside the code view), each wrapped at 560 points.
fn drawTip(app: *App, a: Allocator, lines: []const Tip, at: [2]f32) void {
    drawTipBeside(app, a, lines, at, null);
}

/// `drawTip` next to a list spanning `beside` (its left and right x): to its right,
/// narrower to fit, else to its left — never over it.
pub fn drawTipBeside(app: *App, a: Allocator, lines: []const Tip, at_: [2]f32, beside: ?[2]f32) void {
    const fo = app.font;
    const pt_c = lay.Type.caption.pt();
    const v = app.code orelse return;
    var at = at_;
    var max_w: f32 = 560;
    var left = false;
    if (beside) |b| {
        const right_room = v.rect.x + v.rect.w - (b[1] + 4) - 4 - 16;
        const left_room = b[0] - 4 - v.rect.x - 16;
        left = right_room < 240 and left_room > right_room;
        max_w = @max(120, @min(max_w, if (left) left_room else right_room));
        at[0] = b[1] + 4;
    }
    var rows: std.ArrayList(Tip) = .empty;
    for (lines) |l| for (wrap(app, a, l.s, max_w)) |part| rows.append(a, .{ .s = part, .col = l.col }) catch return;
    // As many as the view holds (the rest cut with "…").
    const fit: usize = @intFromFloat(@max(2, @floor((v.rect.h - 8) / 18)));
    if (rows.items.len > fit) {
        rows.items.len = fit - 1;
        rows.append(a, .{ .s = "…", .col = lay.canvas.code.tip_desc }) catch {};
    }
    var w: f32 = 0;
    for (rows.items) |l| w = @max(w, fo.measure(l.s, font_mod.regular, pt_c)[0]);
    w += 16;
    const h = @as(f32, @floatFromInt(rows.items.len)) * 18 + 8;
    if (left) at[0] = beside.?[0] - 4 - w;
    const x = std.math.clamp(at[0], v.rect.x, @max(v.rect.x, v.rect.x + v.rect.w - w - 4));
    const y = if (at[1] + h > v.rect.y + v.rect.h) @max(v.rect.y, at[1] - h - line_h - 4) else at[1];
    render.ink(app.r, lay.canvas.alpha(lay.canvas.code.tip_bg, 245));
    _ = c.SDL_RenderFillRect(app.r, &.{ .x = x, .y = y, .w = w, .h = h });
    render.ink(app.r, lay.canvas.code.tip_edge);
    _ = c.SDL_RenderRect(app.r, &.{ .x = x, .y = y, .w = w, .h = h });
    for (rows.items, 0..) |l, k| fo.draw(app.r, l.s, font_mod.regular, pt_c, x + 8, y + 4 + @as(f32, @floatFromInt(k)) * 18, l.col);
}

/// A problem's message (bad argument count, a file the archives lack, a port-only call in
/// a Classic project — api.portOnly decided it), in the Problems list and the hover tip.
pub fn problem(a: Allocator, u: anytype) []const u8 {
    const name = u.name[0..u.len];
    return switch (u.kind) {
        .args => tx.alloc(a, tx.code_bad_args, .{ u.line, name }),
        .missing => tx.alloc(a, tx.code_missing, .{ u.line, name }),
        .call => tx.alloc(a, tx.code_unknown, .{ u.line, name }),
        .port_only => tx.alloc(a, tx.code_port_only_call, .{ u.line, name }),
        .hook => tx.alloc(a, tx.code_hook_unknown, .{ u.line, name }),
        .hook_args => tx.alloc(a, tx.code_hook_args, .{ u.line, if (og.script.traits.hook(name)) |h| std.fmt.allocPrint(a, "{s}({s})", .{ h.name, h.params }) catch name else name }),
        .note => tx.alloc(a, tx.code_note, .{ u.line, u.msg[0..u.msg_len] }),
    };
}

/// The bracket just before or at offset `i` and the one closing (opening) it.
pub fn bracketPair(t: []const u8, i: usize) ?[2]usize {
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

/// A function as the big hint and the hover show it: `Name(…)`, a line per parameter
/// (the one at the cursor marked), what it does, lines after (a value's meaning, where
/// it is defined).
pub const Decl = struct {
    name: []const u8,
    params: []const DeclParam = &.{},
    cur: ?usize = null,
    desc: []const u8 = "",
    notes: []const []const u8 = &.{},
};
/// As the signature writes it, and its line (`int x — what it is`).
const DeclParam = struct { sig: []const u8, line: []const u8 };

/// `decl — doc` (the decl alone without a doc).
pub fn docLine(a: Allocator, decl: []const u8, doc: []const u8) []const u8 {
    if (doc.len == 0) return decl;
    return std.fmt.allocPrint(a, "{s} — {s}", .{ decl, doc }) catch decl;
}

pub fn apiDecl(a: Allocator, f: *const api.Fn, ogs: bool) Decl {
    var pb: [12]api.Param = undefined;
    const ps = api.params(f, &pb);
    const out = a.alloc(DeclParam, ps.len) catch return .{ .name = f.name };
    for (out, ps) |*o, p| o.* = .{ .sig = if (p.optional) std.fmt.allocPrint(a, "[{s}]", .{p.decl}) catch p.decl else p.decl, .line = paramLine(a, p, ogs) };
    return .{ .name = f.name, .params = out, .desc = fnDesc(a, f, ogs) };
}

fn callbackDecl(a: Allocator, cb: callbacks.Callback) Decl {
    const out = a.alloc(DeclParam, cb.params.len) catch return .{ .name = cb.name };
    for (out, cb.params) |*o, p| o.* = .{ .sig = p.decl, .line = docLine(a, p.decl, tx.get(p.doc)) };
    return .{ .name = cb.name, .params = out, .desc = tx.alloc(a, tx.code_engine_calls_it, .{tx.get(cb.doc)}) };
}

/// An engine method of the enclosing component's traits (script/traits.zig; the
/// fighter's events where it names no host): its parameters, when the engine calls it,
/// its rule and what the engine does without an answer.
fn eventDecl(a: Allocator, e: og.script.traits.Method) Decl {
    var ps: std.ArrayList(DeclParam) = .empty;
    var it = std.mem.tokenizeSequence(u8, e.params, ", ");
    while (it.next()) |p| ps.append(a, .{ .sig = p, .line = p }) catch {};
    var notes: std.ArrayList([]const u8) = .empty;
    notes.append(a, tx.alloc(a, tx.tr_rule, .{tx.get(e.combine.label())})) catch {};
    if (e.default) |d| notes.append(a, tx.alloc(a, tx.tr_no_answer, .{tx.get(d)})) catch {};
    return .{ .name = e.name, .params = ps.items, .desc = tx.alloc(a, tx.code_event_calls_it, .{tx.get(e.when)}), .notes = notes.items };
}

fn engineMethod(a: Allocator, t: []const u8, at: usize, name: []const u8) ?*const og.script.traits.Method {
    const ti = @import("traitinfo.zig");
    const p = ti.load(a);
    return ti.engineMethodAt(&p, a, t, at, name);
}

/// A component of the project's rules code named `name`: its params (`int pct = 30 —
/// its label`), its hosts and file.
fn componentDecl(a: Allocator, name: []const u8) ?Decl {
    for (@import("char_abilities.zig").components(a)) |cp| if (std.mem.eql(u8, cp.c.name, name) or std.mem.eql(u8, cp.path, name)) {
        var ps: std.ArrayList(DeclParam) = .empty;
        for (cp.c.fields) |f| if (f.kind == .param) {
            var sig: std.Io.Writer.Allocating = .init(a);
            sig.writer.print("{s}{s}{s}", .{ f.type_name, if (f.type_name.len > 0) " " else "", f.name }) catch {};
            if (f.default) |d| {
                sig.writer.writeAll(" = ") catch {};
                og.script.ogs.print.expression(&sig.writer, d) catch {};
            }
            ps.append(a, .{ .sig = f.name, .line = docLine(a, sig.written(), f.doc) }) catch {};
        };
        const hosts = if (cp.c.hosts.len == 0) tx.get(tx.code_any_host) else std.mem.join(a, ", ", cp.c.hosts) catch "";
        return .{ .name = cp.path, .params = ps.items, .desc = tx.alloc(a, tx.code_component, .{ hosts, cp.file }) };
    };
    return null;
}

/// A script's own function: its parameters with their comments, the comment above it.
pub fn headerDecl(a: Allocator, name: []const u8, params: []const code.HeaderParam, doc: []const u8, where: []const u8) Decl {
    const out = a.alloc(DeclParam, params.len) catch return .{ .name = name };
    for (out, params) |*o, p| o.* = .{ .sig = p.decl, .line = docLine(a, p.decl, p.doc) };
    const notes = a.dupe([]const u8, &.{where}) catch &.{};
    return .{ .name = name, .params = out, .desc = doc, .notes = if (where.len > 0) notes else &.{} };
}

/// A rules call: a line per field (the field at the cursor marked, its value's meaning after).
fn rulesDecl(app: *App, a: Allocator, r: RulesAt) Decl {
    const fs = r.call.fields;
    const out = a.alloc(DeclParam, fs.len) catch return .{ .name = r.call.name };
    for (out, fs) |*o, *f| o.* = .{ .sig = f.name, .line = fieldLine(a, r.call, f) };
    var notes: std.ArrayList([]const u8) = .empty;
    if (r.field) |f| {
        const means = codenav.rulesMeaning(app, a, f, r.arg.?.value);
        if (means.len > 0) notes.append(a, std.fmt.allocPrint(a, "{s}: {s}", .{ r.arg.?.value, means }) catch "") catch {};
    }
    return .{ .name = r.call.name, .params = out, .cur = if (r.field) |f| f - fs.ptr else null, .desc = tx.get(r.call.doc), .notes = notes.items };
}

/// The function named `name` as the hint shows it: in a hooks file a hook, at a
/// declaration (`header`) an engine callback, else a builtin, a function of this text or
/// of the game's scripts (the declaration's own comments).
fn declOf(app: *App, v: *const View, a: Allocator, name: []const u8, header: bool) ?Decl {
    const t = v.buf.str();
    // A scene's command first: `actor::Place` there is PLACE(actor, point), not the builtin.
    if (!header and sceneText(app, v)) if (@import("scenedoc.zig").find(name)) |sd| {
        const out = a.alloc(DeclParam, sd.params.len) catch return null;
        for (out, sd.params) |*o, p| o.* = .{ .sig = p, .line = "" };
        return .{ .name = name, .params = out, .desc = tx.get(sd.what) };
    };
    // OG Script: a fighter component's event method, a component (its params).
    if (header and !hooksFile(app, v) and codecomplete.isOgs(app, v)) if (engineMethod(a, t, v.buf.cursor, name)) |e| {
        var d = eventDecl(a, e.*);
        if (ownFn(t, name)) |at| if (code.header(a, t, at)) |h| if (h.doc.len > 0) {
            d.notes = std.mem.concat(a, []const u8, &.{ d.notes, &.{h.doc} }) catch d.notes;
        };
        return d;
    };
    if (!header and codecomplete.isOgs(app, v)) if (componentDecl(a, name)) |d| return d;
    if (header) {
        const buf = a.alloc(callbacks.Param, 8) catch return null;
        const cb = if (hooksFile(app, v)) callbacks.hook(buf, name) else if (callbacks.find(name)) |x| x.* else if (levelHooks(app, v)) callbacks.hook(buf, name) else null;
        if (cb) |x| {
            var d = callbackDecl(a, x);
            // Its own comment after what the engine does.
            if (ownFn(t, name)) |at| if (code.header(a, t, at)) |h| if (h.doc.len > 0) {
                d.notes = a.dupe([]const u8, &.{h.doc}) catch &.{};
            };
            return d;
        }
    }
    if (!header) if (api.find(name)) |f| {
        var d = apiDecl(a, f, codecomplete.isOgs(app, v));
        d.name = name;
        return d;
    };
    if (ownFn(t, name)) |at| if (code.header(a, t, at)) |h| return headerDecl(a, h.name, h.params, h.doc, if (header) "" else v.title);
    // OpenGorky: a method of the project's traits (the classes' shared code); the installed
    // game's Classic files are not the project's code.
    if (app.ogLayout()) return traitMethodDecl(a, name);
    if (gameFn(app, name)) |g| return headerDecl(a, g.name, g.params, g.doc, g.file);
    return null;
}

/// The view shows a scene: an OpenGorky project's `scenes/*.ogs`, a Classic `.scr`.
pub fn sceneText(app: *App, v: *const View) bool {
    const f = app.store.files.items[v.file];
    if (std.mem.eql(u8, f.archive, @import("store.zig").og_src)) return std.mem.startsWith(u8, f.entry, "scenes/");
    return std.ascii.endsWithIgnoreCase(f.entry, ".scr");
}

/// Method `name` of a trait of the project (`StartDialog` of `classes::CombatLevel`): its
/// parameters, the trait and its file.
fn traitMethodDecl(a: Allocator, name: []const u8) ?Decl {
    const p = @import("traitinfo.zig").load(a);
    for (p.traits) |t| for (t.it.methods) |m| if (std.mem.eql(u8, m.f.name, name)) {
        const out = a.alloc(DeclParam, m.f.params.len) catch return null;
        for (out, m.f.params) |*o, x| o.* = .{ .sig = x.name, .line = "" };
        const where = std.fmt.allocPrint(a, "trait {s} · {s}", .{ t.path, t.file }) catch "";
        return .{ .name = name, .params = out, .notes = a.dupe([]const u8, &.{where}) catch &.{} };
    };
    return null;
}

const declAt = @import("completion.zig").declAt;

/// What the hint shows at offset `at`: the declaration it is in, the rules call, the call.
pub fn hintDecl(app: *App, v: *View, a: Allocator, at: usize) ?Decl {
    const t = v.buf.str();
    if (declAt(a, t, at)) |da| {
        var d = declOf(app, v, a, da.name, true) orelse return null;
        d.cur = da.arg;
        return d;
    }
    if (rulesFile(app, v)) if (rulesAt(t, at)) |r| return rulesDecl(app, a, r);
    const cp = code.callAt(t, at) orelse return null;
    var d = declOf(app, v, a, cp.name, false) orelse return null;
    d.cur = cp.arg;
    return d;
}

/// The parameters shown of `d`: all, or (many) the nine around the current one.
fn declWindow(d: Decl) [2]usize {
    if (d.params.len <= 9) return .{ 0, d.params.len };
    const from = @min(if (d.cur) |x| x -| 4 else 0, d.params.len - 9);
    return .{ from, from + 9 };
}

/// `d` as tip lines: its signature, its parameters' lines, what it does, the rest.
pub fn declTips(a: Allocator, d: Decl, lines: *std.ArrayList(Tip)) void {
    const win = declWindow(d);
    var sig: std.ArrayList(u8) = .empty;
    sig.print(a, "{s}(", .{d.name}) catch {};
    if (win[0] > 0) sig.appendSlice(a, "…, ") catch {};
    for (d.params[win[0]..win[1]], win[0]..) |p, k| sig.print(a, "{s}{s}", .{ if (k > win[0]) ", " else "", p.sig }) catch {};
    if (win[1] < d.params.len) sig.appendSlice(a, ", …") catch {};
    sig.append(a, ')') catch {};
    lines.append(a, .{ .s = sig.items, .col = lay.canvas.code.call }) catch {};
    for (d.params[win[0]..win[1]], win[0]..) |p, k| lines.append(a, .{ .s = p.line, .col = if (d.cur != null and d.cur.? == k) lay.canvas.code.tip_cur else lay.canvas.code.plain }) catch {};
    if (d.desc.len > 0) lines.append(a, .{ .s = d.desc, .col = lay.canvas.code.tip_desc }) catch {};
    for (d.notes) |n| lines.append(a, .{ .s = n, .col = lay.canvas.code.string }) catch {};
}

/// Inside a known call or a declaration: the function's signature above the line (the
/// current parameter in bold), a line per parameter (the current one marked), what it does.
pub fn drawHint(app: *App, v: *View, a: Allocator, cxy: [2]f32, rect: c.SDL_FRect) void {
    const at = if (v.buf.selection()) |s| s[0] else v.buf.cursor;
    const d = hintDecl(app, v, a, at) orelse return;
    const r = app.r;
    const fo = app.font;
    const body = lay.Type.body.pt();
    const cap = lay.Type.caption.pt();
    const max_w = @min(@as(f32, 640), rect.w - 24);
    // Pieces of `Name(type a, [type b])`, the current parameter in bold yellow; cut at the width.
    const win = declWindow(d);
    var pieces: [40]struct { s: []const u8, cur: bool } = undefined;
    var n: usize = 0;
    var w: f32 = 0;
    const add = struct {
        fn f(ps: anytype, np: *usize, wp: *f32, fo_: anytype, s: []const u8, cur: bool) void {
            if (np.* == ps.len) return;
            ps[np.*] = .{ .s = s, .cur = cur };
            np.* += 1;
            wp.* += fo_.measure(s, if (cur) font_mod.bold else font_mod.regular, lay.Type.body.pt())[0];
        }
    }.f;
    add(&pieces, &n, &w, fo, std.fmt.allocPrint(a, "{s}(", .{d.name}) catch return, false);
    if (win[0] > 0) add(&pieces, &n, &w, fo, "…, ", false);
    for (d.params[win[0]..win[1]], win[0]..) |p, k| {
        if (w > max_w - 40 or n + 3 > pieces.len) {
            add(&pieces, &n, &w, fo, ", …", false);
            break;
        }
        if (k > win[0]) add(&pieces, &n, &w, fo, ", ", false);
        add(&pieces, &n, &w, fo, p.sig, d.cur != null and k == d.cur.?);
    } else if (win[1] < d.params.len) add(&pieces, &n, &w, fo, ", …", false);
    add(&pieces, &n, &w, fo, ")", false);
    // The rows: the parameters' lines, what it does, the notes, each wrapped to the view.
    var tips: std.ArrayList(Tip) = .empty;
    declTips(a, d, &tips);
    var rows: std.ArrayList(struct { s: []const u8, col: [4]u8, bold: bool }) = .empty;
    for (tips.items[1..], 0..) |l, k| for (wrap(app, a, l.s, max_w - 12)) |part| {
        rows.append(a, .{ .s = part, .col = l.col, .bold = k < win[1] - win[0] and d.cur != null and k + win[0] == d.cur.? }) catch {};
    };
    // As many rows as fit above or below the line (the rest cut with "…").
    const above = cxy[1] - 2 - rect.y;
    const below = rect.y + rect.h - (cxy[1] + line_h + 2);
    const fit: usize = @intFromFloat(@max(1, @floor((@max(above, below) - 26) / 18)));
    if (rows.items.len > fit) {
        rows.items.len = fit - 1;
        rows.append(a, .{ .s = "…", .col = lay.canvas.code.tip_desc, .bold = false }) catch {};
    }
    for (rows.items) |l| w = @max(w, fo.measure(l.s, if (l.bold) font_mod.bold else font_mod.regular, cap)[0]);
    w += 16;
    const h: f32 = 22 + @as(f32, @floatFromInt(rows.items.len)) * 18 + 4;
    const x = @max(rect.x, @min(cxy[0], rect.x + rect.w - w - 4));
    const y = if (h <= above or above >= below) @max(rect.y, cxy[1] - h - 2) else cxy[1] + line_h + 2;
    render.ink(r, lay.canvas.alpha(lay.canvas.code.tip_bg, 245));
    _ = c.SDL_RenderFillRect(r, &.{ .x = x, .y = y, .w = w, .h = h });
    render.ink(r, lay.canvas.code.tip_edge);
    _ = c.SDL_RenderRect(r, &.{ .x = x, .y = y, .w = w, .h = h });
    var px = x + 8;
    for (pieces[0..n]) |p| {
        const fid: u16 = if (p.cur) font_mod.bold else font_mod.regular;
        fo.draw(r, p.s, fid, body, px, y + 3, if (p.cur) lay.canvas.code.tip_cur else lay.canvas.code.plain);
        px += fo.measure(p.s, fid, body)[0];
    }
    for (rows.items, 0..) |l, k| fo.draw(r, l.s, if (l.bold) font_mod.bold else font_mod.regular, cap, x + 8, y + 22 + 18 * @as(f32, @floatFromInt(k)), l.col);
}

//! The code window's completion, its window side (codeview.zig): the popup drawn and
//! what is beside it, the editor's names (completion.Source) and what text a view is.
//! What the list offers and what taking one does: completion.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const lay = @import("layout.zig");
const render = @import("render.zig");
const font_mod = @import("font.zig");
const code = @import("code.zig");
const rulesapi = @import("rulesapi.zig");
const entries = @import("entries.zig");
const refs_mod = @import("refs.zig");
const codenav = @import("codenav.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const View = code.View;
const codeview = @import("codeview.zig");
const codecheck = @import("codecheck.zig");
const codetips = @import("codetips.zig");
const completion = @import("completion.zig");

const line_h = codeview.line_h;
const pt = codeview.pt;
const gameFns = codecheck.gameFns;
const isScene = codecheck.isScene;
const Decl = codetips.Decl;
const Tip = codetips.Tip;
const apiDecl = codetips.apiDecl;
const declTips = codetips.declTips;
const drawTipBeside = codetips.drawTipBeside;
const hintDecl = codetips.hintDecl;

pub fn next(t: []const u8, i: usize) usize {
    var k = code.lineEnd(t, i);
    if (k < t.len and t[k] == '\r') k += 1;
    if (k < t.len and t[k] == '\n') k += 1;
    return k;
}

/// The list's words at offset `i` of `t`, a text of `v`'s kind (the code probe types into a copy).
pub fn wordsAt(app: *App, v: *const View, a: Allocator, t: []const u8, i: usize) []const []const u8 {
    return completion.candidates(a, t, i, false, where(app, v), source(app));
}

/// What text `v` is (completion.Where).
fn where(app: *App, v: *const View) completion.Where {
    return .{ .rules = rulesFile(app, v), .ogs = isOgs(app, v), .hooks = hooksFile(app, v), .level_hooks = levelHooks(app, v), .scene = isScene(v.title) };
}

/// The editor's names for completion: the project's, the open level's, the game's.
fn source(app: *App) completion.Source {
    return .{ .ctx = app, .get = appNames, .meaning = appMeaning, .example = appExample };
}

fn appNames(ctx: *anyopaque, a: Allocator, what: completion.Names, actor: []const u8, text: []const u8) []const []const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    var out: std.ArrayList([]const u8) = .empty;
    switch (what) {
        .levels => for (app.levels) |l| out.append(a, l.name) catch {},
        .scenes => for (app.catalog.scenes.items) |sc| out.append(a, sc.name) catch {},
        .areas, .actors, .objects, .level_names => if (app.doc) |d| for (d.objects.items) |o| {
            const take = switch (what) {
                .areas => o.kind == .area,
                .actors => switch (o.kind) {
                    .enemy, .actor, .neutral, .hero => true,
                    else => false,
                },
                .objects => o.kind != .area,
                else => true,
            };
            if (take) out.append(a, o.name) catch {};
        },
        .sounds => return app.player.names(app, a),
        .dialogs => return codenav.fileNames(app, a, "", ".dlg"),
        .videos => return @import("videopage.zig").names(app),
        .meshes => return @import("look_pages.zig").models(app, a),
        .classes => return codenav.fileNames(app, a, "classes\\", ".s"),
        .anims => return animNames(app, a, actor, text),
        .functions => {
            var it = gameFns(app).valueIterator();
            while (it.next()) |g| out.append(a, g.name) catch {};
        },
        .files => return app.store.listing(a, @import("store.zig").og_src, null, true),
        .name_ids => for (app.catalog.entries.items) |e| if (e.name_id) |id| {
            out.append(a, std.fmt.allocPrint(a, "{d} · {s}", .{ id, if (e.title.len > 0) e.title else e.id }) catch continue) catch {};
        },
        .weapon_classes => for (@import("item_page.zig").class_values) |x| out.append(a, @import("item_page.zig").classLabel(a, @floatFromInt(x))) catch {},
        .calls => return app.catalog.calls.keys(),
        .components => for (@import("char_abilities.zig").components(a)) |cp| out.append(a, cp.path) catch {},
        .program => return @import("codesym.zig").names(app, app.code orelse return &.{}, a),
    }
    return out.items;
}

fn appMeaning(ctx: *anyopaque, a: Allocator, f: *const rulesapi.Field, value: []const u8) []const u8 {
    return codenav.rulesMeaning(@ptrCast(@alignCast(ctx)), a, f, value);
}

fn appExample(ctx: *anyopaque, name: []const u8) ?[]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    return app.catalog.calls.get(name);
}

/// Logical animation names the look of `actor` registers (a hero's class, a level
/// fighter's `act_*.ss`); with no actor, those of `own` (the script itself).
fn animNames(app: *App, a: Allocator, actor: []const u8, own: []const u8) []const []const u8 {
    const look: []const u8 = look: {
        if (actor.len == 0) break :look own;
        for (app.catalog.entries.items) |e| if (e.kind == .hero and (std.ascii.eqlIgnoreCase(e.title, actor) or std.ascii.eqlIgnoreCase(e.id, actor))) {
            const fi = entries.fileOf(app, e) orelse continue;
            break :look entries.lookOf(app, app.store.text(fi));
        };
        // A level's fighter: its `.ftr` includes the class, the class its look.
        const d = app.doc orelse break :look "";
        var nb: [128]u8 = undefined;
        const ftr = refs_mod.read(app, a, d.level_archive, std.fmt.bufPrint(&nb, "{s}.ftr", .{actor}) catch break :look "") orelse break :look "";
        const p = std.ascii.findIgnoreCase(ftr, "#include ft_") orelse break :look "";
        var e = p + "#include ".len;
        while (e < ftr.len and !std.ascii.isWhitespace(ftr[e])) e += 1;
        const cls = refs_mod.read(app, a, @import("store.zig").common_archive, std.fmt.bufPrint(&nb, "classes\\{s}", .{ftr[p + "#include ".len .. e]}) catch break :look "") orelse break :look "";
        const act = entries.actOf(cls) orelse break :look cls;
        break :look refs_mod.read(app, a, @import("store.zig").common_archive, std.fmt.bufPrint(&nb, "classes\\{s}", .{act}) catch break :look "") orelse "";
    };
    var out: std.ArrayList([]const u8) = .empty;
    out.append(a, "idle") catch {};
    for (@import("preview.zig").anims(a, look)) |an| {
        const slot = an.slot[0 .. std.mem.indexOfScalar(u8, an.slot, '/') orelse an.slot.len];
        for (out.items) |x| {
            if (std.mem.eql(u8, x, slot)) break;
        } else out.append(a, slot) catch {};
    }
    return out.items;
}

pub fn opensOnType(app: *App, v: *View, typed: []const u8) bool {
    var tmp: std.heap.ArenaAllocator = .init(app.gpa);
    defer tmp.deinit();
    return completion.opensOnType(tmp.allocator(), v.buf.str(), v.buf.cursor, typed, where(app, v), source(app));
}

pub fn tasksAt(app: *App, v: *View) bool {
    return completion.tasksAt(app.frame.allocator(), v.buf.str(), v.buf.cursor, where(app, v));
}

/// The OG layout's hooks file (`src/game.ogs`: its `component … for game`, App.ogLayout).
pub const hooks_file = "game.ogs";

/// Whether file `v` is the rules' hooks file (functions the engine calls).
pub fn hooksFile(app: *App, v: *const View) bool {
    return rulesFile(app, v) and std.ascii.endsWithIgnoreCase(app.store.files.items[v.file].entry, hooks_file);
}

/// Whether file `v` is a level's script (its .lev: hooks of its own in OpenGorky).
pub fn levelFile(app: *App, v: *const View) bool {
    return std.ascii.endsWithIgnoreCase(app.store.files.items[v.file].entry, ".lev");
}

pub fn levelHooks(app: *App, v: *const View) bool {
    return app.ogLayout() and levelFile(app, v);
}

/// Whether file `v` is one of the rules files (calls of the rules' tables).
pub fn rulesFile(app: *App, v: *const View) bool {
    return std.mem.eql(u8, app.store.files.items[v.file].archive, @import("store.zig").og_src);
}

/// Whether the text of `v` is OG Script: a rules file's, or a Classic script in its OG
/// Script view (code.View.ogs_view).
pub fn isOgs(app: *App, v: *const View) bool {
    return v.ogs_view or rulesFile(app, v);
}

fn candidates(app: *App, v: *View, a: Allocator) []const []const u8 {
    return completion.candidates(a, v.buf.str(), v.buf.cursor, v.tasks, where(app, v), source(app));
}

pub fn drawPopup(app: *App, v: *View, a: Allocator, under: [2]f32) void {
    const r = app.r;
    const f = app.font;
    const list = candidates(app, v, a);
    if (list.len == 0) return;
    v.popup_sel = @min(v.popup_sel, list.len - 1);
    const w: f32 = 320;
    const h = @as(f32, @floatFromInt(list.len)) * line_h + 6;
    // Above the cursor's line when it does not fit below.
    const at: [2]f32 = if (under[1] + h > v.rect.y + v.rect.h) .{ under[0], @max(v.rect.y, under[1] - line_h - h) } else under;
    render.ink(r, lay.canvas.code.popup_bg);
    _ = c.SDL_RenderFillRect(r, &.{ .x = at[0], .y = at[1], .w = w, .h = h });
    render.ink(r, lay.canvas.code.accent);
    _ = c.SDL_RenderRect(r, &.{ .x = at[0], .y = at[1], .w = w, .h = h });
    for (list, 0..) |word, i| {
        const y = at[1] + 3 + @as(f32, @floatFromInt(i)) * line_h;
        if (i == v.popup_sel) {
            render.ink(r, lay.canvas.alpha(lay.canvas.code.accent, 200));
            _ = c.SDL_RenderFillRect(r, &.{ .x = at[0] + 1, .y = y, .w = w - 2, .h = line_h });
        }
        f.draw(r, word, font_mod.regular, pt, at[0] + 8, y, lay.canvas.code.popup_text);
    }
    // Beside it: what completion.beside says, drawn.
    const beside: [2]f32 = .{ at[0], at[0] + w };
    switch (completion.beside(a, v.buf.str(), v.buf.cursor, list[v.popup_sel], where(app, v), source(app))) {
        .none => {},
        .header => if (hintDecl(app, v, a, v.buf.cursor)) |d| drawDecl(app, a, d, at, beside),
        .arg => |x| {
            var d = apiDecl(a, x.f, isOgs(app, v));
            d.cur = x.arg;
            drawDecl(app, a, d, at, beside);
        },
        .lines => |ls| {
            var lines: std.ArrayList(Tip) = .empty;
            for (ls) |l| lines.append(a, .{ .s = l.s, .col = if (l.kind == .code) lay.canvas.code.string else lay.canvas.code.tip_desc }) catch {};
            drawTipBeside(app, a, lines.items, at, beside);
        },
        .builtin => |b| {
            const ew = @max(f.measure(b.sig, font_mod.regular, lay.Type.body.pt())[0], f.measure(b.desc, font_mod.regular, lay.Type.caption.pt())[0]) + 16;
            render.ink(r, lay.canvas.code.tip_bg);
            _ = c.SDL_RenderFillRect(r, &.{ .x = at[0] + w + 4, .y = at[1], .w = ew, .h = 44 });
            f.draw(r, b.sig, font_mod.regular, lay.Type.body.pt(), at[0] + w + 12, at[1] + 3, lay.canvas.code.string);
            f.draw(r, b.desc, font_mod.regular, lay.Type.caption.pt(), at[0] + w + 12, at[1] + 23, lay.canvas.code.tip_desc);
        },
        .example => |example| {
            const ew = f.measure(example, font_mod.regular, lay.Type.body.pt())[0] + 16;
            render.ink(r, lay.canvas.code.tip_bg);
            _ = c.SDL_RenderFillRect(r, &.{ .x = at[0] + w + 4, .y = at[1], .w = ew, .h = line_h + 4 });
            f.draw(r, example, font_mod.regular, lay.Type.body.pt(), at[0] + w + 12, at[1] + 3, lay.canvas.code.string);
        },
    }
}

fn drawDecl(app: *App, a: Allocator, d: Decl, at: [2]f32, beside: [2]f32) void {
    var lines: std.ArrayList(Tip) = .empty;
    declTips(a, d, &lines);
    drawTipBeside(app, a, lines.items, at, beside);
}

pub fn accept(app: *App, v: *View) bool {
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    return completion.accept(arena.allocator(), v, where(app, v), source(app));
}

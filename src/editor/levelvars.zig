//! A level's own variables — its quest flags and counters (`int readyF01;   // battle 1`
//! in the `.lev`) — with their comments, where they are named, and their starting values:
//! `variables\<level>.var` in common/other.dat, which the exe applies before init()
//! (start.zig loadVars), so a value init() assigns wins and is shown instead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const icons = @import("icons.zig");
const textedit = @import("textedit.zig");
const level = @import("level.zig");
const Doc = level.Doc;
const box = @import("box.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;
const common_archive = @import("store.zig").common_archive;

/// `at`: the declaration's offset in the `.lev`.
pub const Var = struct { name: []const u8, ty: []const u8, comment: []const u8, start: ?[]const u8, in_init: ?[]const u8, uses: usize, at: usize };

/// The variables the `.lev` declares (outside its functions); `uses` counted
/// only when asked (it reads every script of the level).
pub fn list(app: *App, a: Allocator, d: *Doc, uses: bool) []const Var {
    const scripts = if (uses) levelTexts(app, a, d) else &.{};
    var out: std.ArrayList(Var) = .empty;
    const lev = app.store.text(d.lev);
    const vt = if (varFile(app, a, d)) |f| app.store.text(f) else "";
    const init_body = if (box.funcBody(lev, "init")) |b| lev[b.start..b.end] else "";
    var it = std.mem.splitScalar(u8, lev, '\n');
    // Declarations are outside functions (between them too): braces counted.
    var depth: i32 = 0;
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const outside = depth == 0;
        for (line) |ch| depth += @as(i32, @intFromBool(ch == '{')) - @as(i32, @intFromBool(ch == '}'));
        if (!outside) continue;
        const ty = for ([_][]const u8{ "int ", "float ", "string " }) |t| {
            if (std.mem.startsWith(u8, line, t)) break t;
        } else continue;
        const semi = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        const name = std.mem.trim(u8, line[ty.len..semi], " \t");
        if (name.len == 0 or std.mem.indexOfAny(u8, name, " ,=[") != null) continue;
        const cm = if (std.mem.indexOf(u8, line[semi..], "//")) |k| std.mem.trim(u8, line[semi + k + 2 ..], " \t") else "";
        out.append(a, .{
            .name = name,
            .ty = std.mem.trim(u8, ty, " "),
            .comment = cm,
            .start = startValue(vt, name),
            .in_init = assigned(init_body, name),
            .uses = count(scripts, name),
            .at = @intFromPtr(name.ptr) - @intFromPtr(lev.ptr),
        }) catch {};
    }
    return out.items;
}

fn varFile(app: *App, a: Allocator, d: *Doc) ?usize {
    return app.store.file(common_archive, std.fmt.allocPrint(a, "variables\\{s}.var", .{d.name}) catch return null) catch null;
}

fn startValue(vt: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, vt, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \r");
        if (l.len > name.len and std.mem.startsWith(u8, l, name) and l[name.len] == '=') return l[name.len + 1 ..];
    }
    return null;
}

/// `name = value;` in init()'s body: its value.
fn assigned(body: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, name)) |i| {
        pos = i + name.len;
        if (i > 0 and isIdent(body[i - 1])) continue;
        var j = pos;
        while (j < body.len and (body[j] == ' ' or body[j] == '\t')) j += 1;
        if (j >= body.len or body[j] != '=' or (j + 1 < body.len and body[j + 1] == '=')) continue;
        const e = std.mem.indexOfScalarPos(u8, body, j, ';') orelse continue;
        return std.mem.trim(u8, body[j + 1 .. e], " \t");
    }
    return null;
}

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// The level's script texts (edited ones as edited).
fn levelTexts(app: *App, a: Allocator, d: *Doc) []const []const u8 {
    const fs = @import("refs.zig").files(app, a, d.level_archive, @import("refs.zig").script);
    const out = a.alloc([]const u8, fs.len) catch return &.{};
    for (fs, out) |f, *t| t.* = f.text;
    return out;
}

/// Mentions of `name` in `scripts` (the declaration is one).
fn count(scripts: []const []const u8, name: []const u8) usize {
    var n: usize = 0;
    for (scripts) |t| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, t, pos, name)) |i| {
            pos = i + name.len;
            if ((i > 0 and isIdent(t[i - 1])) or (pos < t.len and isIdent(t[pos]))) continue;
            n += 1;
        }
    }
    return n;
}

/// Variable `name` starts at `v` (its line in the level's `.var`, the file made if
/// missing; one undo step).
fn setStart(app: *App, a: Allocator, d: *Doc, name: []const u8, v: []const u8) !void {
    if (varFile(app, a, d)) |f| {
        const t = try level.setVarLine(app.gpa, app.store.text(f), name, v);
        return app.store.replaceLabeled(f, t, name);
    }
    const t = try std.fmt.allocPrint(app.gpa, "{s}={s}\r\n", .{ name, v });
    _ = try app.store.addNew(&.{.{ .archive = common_archive, .entry = try std.fmt.allocPrint(a, "variables\\{s}.var", .{d.name}), .text = t }});
}

/// The folded group under the level's objects.
pub fn group(app: *App, a: Allocator, d: *Doc) void {
    const okey = "objopen/vars";
    const open = app.tree_open.contains(okey);
    const vs = list(app, a, d, open);
    if (vs.len == 0) return;
    const gid = clay.id(okey);
    if (main.clickable(app, .{ .id = gid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(28) }, .padding = .{ .left = 8, .right = 8 }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel }, false)) @import("assettree.zig").toggleKey(app, okey);
    icons.leaf(app.r, app.gpa, if (open) .chevron_down else .chevron_right, 13, theme.dim);
    icons.leaf(app.r, app.gpa, .code, 15, theme.dim);
    txt(tx.get(tx.lv_title), 13, theme.text, font_mod.bold);
    txt(std.fmt.allocPrint(a, "({d})", .{vs.len}) catch "", 12, theme.dim, font_mod.regular);
    clay.close();
    if (!open) return;
    clay.text(tx.get(tx.lv_hint), .{ .textColor = theme.dim, .fontSize = 11, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    for (vs, 0..) |v, k| {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = 34, .right = 8, .top = 3, .bottom = 3 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 1 } });
        txt(std.fmt.allocPrint(a, "{s} {s}", .{ v.ty, v.name }) catch v.name, 13, theme.text, font_mod.regular);
        const note = if (v.in_init) |iv| tx.alloc(a, tx.lv_in_init, .{ iv, v.uses }) else if (v.comment.len > 0) std.fmt.allocPrint(a, "{s} · {d}×", .{ v.comment, v.uses }) catch "" else std.fmt.allocPrint(a, "{d}×", .{v.uses}) catch "";
        clay.text(note, .{ .textColor = theme.dim, .fontSize = 11, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
        clay.close();
        if (textedit.field(app, std.fmt.allocPrint(a, "lv_{d}", .{k}) catch "lv", v.start orelse "0", 90, "")) |nv| {
            setStart(app, a, d, v.name, std.mem.trim(u8, nv, " ")) catch |err| app.setStatus(tx.st_set_failed, .{err});
        }
        // Its declaration in the level script, in a tab of its own.
        if (main.toolButton(app, std.fmt.allocPrint(a, "lv_open{d}", .{k}) catch "lvo", .code, "", false, false)) {
            @import("doctabs.zig").keepCurrent(app);
            @import("codeview.zig").open(app, d.lev, v.at);
        }
        clay.close();
    }
}

//! Engine settings: `adjust.kdt` in the game root — ~600 tuning values (`int`, `float`,
//! `rgba` lines: attacks, explosions, particles, monsters, menus, sound) the original
//! exe reads at start (0x418120), so an edit here works in the original too. Listed by
//! group (the name's first word; `attack_` by its second), searched, picked; the right
//! column edits the value (the line's text keeps the exe's form, "1.300000").

const std = @import("std");
const og = @import("opengorky");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const icons = @import("icons.zig");
const textedit = @import("textedit.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;
const store = @import("store.zig");
const lines = @import("adjusttext.zig");
const Param = lines.Param;
const params = lines.params;
const group = lines.group;
const normalize = lines.normalize;
const doc = @import("adjustdoc.zig");
const limits = og.formats.adjust;

/// The page's state (`app.adjust`): the picked value and the search.
pub const State = struct {
    sel: main.Name(64) = .{},
    filter: main.Name(64) = .{},
    /// adjust.dat in the game folder (looked for once): the exe reads it instead (0x4181a0).
    dat: ?bool = null,
};

/// Value `p` of file `f` set to `v` (one undo step).
fn set(app: *App, f: usize, p: Param, v: []const u8) void {
    const t = app.store.text(f);
    const out = std.mem.concat(app.gpa, u8, &.{ t[0..p.at], v, t[p.at + p.value.len ..] }) catch return;
    const label = std.fmt.allocPrint(app.frame.allocator(), "adjust.kdt: {s} = {s}", .{ p.name, v }) catch p.name;
    app.store.replaceLabeled(f, out, label) catch |err| {
        app.gpa.free(out);
        app.setStatus(tx.st_set_failed, .{err});
    };
}

/// Value `name` set to `v` as the page's field does (`--adjust NAME VALUE`).
pub fn setByName(app: *App, name: []const u8, v: []const u8) !void {
    const a = app.frame.allocator();
    const f = try app.store.file(store.adjust_file, store.adjust_file);
    const p = for (params(a, app.store.text(f))) |p| {
        if (std.mem.eql(u8, p.name, name)) break p;
    } else return error.NoSuchValue;
    set(app, f, p, normalize(a, p.kind, v) orelse return error.BadValue);
    app.adjust.sel.set(name);
}

pub fn page(app: *App, a: Allocator) void {
    const f = app.store.file(store.adjust_file, store.adjust_file) catch {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .padding = .{ .left = 20, .top = 16 } } });
        txt(tx.get(tx.adj_none), 14, theme.warn, font_mod.regular);
        return clay.close();
    };
    const ps = params(a, app.store.text(f));
    const was = params(a, app.store.saved(f));
    var saved: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (was) |p| saved.put(a, p.name, p.value) catch {};
    const q = app.adjust.filter.get();
    clay.openScroll(.{ .id = clay.id("adjust_page"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 20, .right = 20, .top = 16, .bottom = 16 }, .childGap = 2 } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 4, .padding = .{ .bottom = 8 } } });
    txt(tx.get(tx.adj_title), 20, theme.text, font_mod.bold);
    clay.text(tx.get(tx.adj_hint), .{ .textColor = theme.dim, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    const n_lines = std.mem.count(u8, std.mem.trimEnd(u8, app.store.text(f), "\n"), "\n") + 1;
    const bad = if (limits.checkLimits(app.store.text(f))) |_| false else |_| true;
    clay.text(tx.alloc(a, tx.adj_limits, .{n_lines}), .{ .textColor = if (bad) theme.warn else theme.dim, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    if (app.adjust.dat == null) app.adjust.dat = if (app.store.dat.statFile(app.store.io, "../adjust.dat", .{})) |_| true else |_| false;
    if (app.adjust.dat.?) clay.text(tx.get(tx.adj_dat_warn), .{ .textColor = theme.warn, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    clay.open(.{ .layout = .{ .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    icons.leaf(app.r, app.gpa, .search, 16, theme.dim);
    if (textedit.field(app, "adjust_search", q, 360, tx.get(tx.adj_search))) |s| app.adjust.filter.set(s);
    if (q.len > 0 and main.toolButton(app, "adjust_clear", .x, "", false, false)) app.adjust.filter.set("");
    clay.close();
    clay.close();
    var last: []const u8 = "";
    for (ps, 0..) |p, k| {
        if (q.len > 0 and std.ascii.findIgnoreCase(p.name, q) == null) continue;
        const g = group(p.name);
        if (!std.mem.eql(u8, g, last)) {
            last = g;
            clay.open(.{ .layout = .{ .padding = .{ .top = 10, .bottom = 2 } } });
            txt(g, 12, theme.dim, font_mod.bold);
            clay.close();
        }
        const sel = std.mem.eql(u8, app.adjust.sel.get(), p.name);
        const changed = if (saved.get(p.name)) |v| !std.mem.eql(u8, v, p.value) else true;
        if (main.clickable(app, .{ .id = clay.idi("adj_row", @intCast(k)), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(26) }, .padding = .{ .left = 10, .right = 10 }, .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel, .cornerRadius = clay.radius(4) }, sel)) app.adjust.sel.set(p.name);
        txt(p.name, 13, theme.text, if (sel) font_mod.bold else font_mod.regular);
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
        if (doc.get(p.name) == null) txt(tx.get(tx.adj_exe_only), 11, theme.dim, font_mod.regular);
        if (changed) txt(tx.get(tx.adj_changed), 12, theme.warn, font_mod.regular);
        txt(p.value, 13, if (changed) theme.warn else theme.dim, font_mod.regular);
        clay.close();
    }
    clay.close();
    props(app, a, f, ps, &saved);
}

/// The picked value: its type, the value typed anew, the saved one, back to it.
fn props(app: *App, a: Allocator, f: usize, ps: []const Param, saved: *const std.StringHashMapUnmanaged([]const u8)) void {
    main.propsOpen(app, "adjust_props");
    defer clay.close();
    main.propsTitle(tx.get(tx.props), true);
    const p = for (ps) |p| {
        if (std.mem.eql(u8, p.name, app.adjust.sel.get())) break p;
    } else return main.propNote(tx.get(tx.adj_pick));
    main.propRow(tx.get(tx.p_name), p.name);
    main.propRow(tx.get(tx.adj_type), p.kind);
    main.propRow(tx.get(tx.adj_about), if (doc.get(p.name)) |m| tx.get(m) else tx.get(tx.adj_not_port));
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(100) } } });
    txt(tx.get(tx.adj_value), 13, theme.dim, font_mod.regular);
    clay.close();
    if (textedit.field(app, "adjust_value", p.value, 0, "")) |v| {
        if (normalize(a, p.kind, v)) |nv| {
            if (!std.mem.eql(u8, nv, p.value)) set(app, f, p, nv);
        } else app.setStatus(tx.st_adj_bad, .{ v, p.kind });
    }
    clay.close();
    // A colour: its swatch.
    if (std.mem.eql(u8, p.kind, "rgba")) {
        var c: [3]f32 = .{ 0, 0, 0 };
        var it = std.mem.splitScalar(u8, p.value, ',');
        for (&c) |*ch| ch.* = @floatFromInt(std.fmt.parseInt(u8, std.mem.trim(u8, it.next() orelse "0", " "), 10) catch 0);
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(48), .height = clay.fixed(24) } }, .backgroundColor = .{ .r = c[0], .g = c[1], .b = c[2], .a = 255 }, .cornerRadius = clay.radius(4) });
    }
    const was = saved.get(p.name) orelse "";
    main.propRow(tx.get(tx.adj_saved), was);
    if (!std.mem.eql(u8, was, p.value) and was.len > 0 and main.button(app, "adjust_reset", tx.get(tx.adj_reset), false)) set(app, f, p, was);
    main.propNote(tx.get(tx.adj_note));
}

//! Mod check window (run by every save; opens itself when there are problems, the
//! status bar opens it again): what the original exe would stumble on in the game
//! folder as saved — `og.modcheck`. A script's row opens it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const codeview = @import("codeview.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;

/// The check's result, shown until closed.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    problems: []og.modcheck.Problem = &.{},
    /// Unsaved edits when it ran (they aren't on disk, so not checked).
    unsaved: bool,
    failed: ?anyerror = null,
    /// The window is open (closed, the status bar still counts the problems).
    shown: bool = true,
};

/// Runs the check on the game folder (the saved state).
pub fn run(app: *App) void {
    close(app);
    const r = app.gpa.create(Result) catch return;
    r.* = .{ .arena = .init(app.gpa), .unsaved = app.store.dirty() };
    r.problems = og.modcheck.run(app.io, r.arena.allocator(), app.dat) catch |err| blk: {
        r.failed = err;
        break :blk &.{};
    };
    r.shown = r.failed != null or r.problems.len > 0;
    app.check = r;
}

pub fn close(app: *App) void {
    const r = app.check orelse return;
    r.arena.deinit();
    app.gpa.destroy(r);
    app.check = null;
}

pub fn panel(app: *App, a: Allocator, r: *Result) void {
    const hit = main.modal(app, "checkpanel", 900, 640, theme.bg, tx.alloc(a, tx.ck_title, .{r.problems.len}), tx.get(tx.ck_again));
    const rerun = hit == .extra;
    const shut = hit == .close;
    clay.openScroll(.{ .id = clay.id("check_body"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 16, .right = 16, .bottom = 16 }, .childGap = 6 } });
    const wrap = ui.CLAY_TEXT_WRAP_WORDS;
    if (r.unsaved) clay.text(tx.get(tx.ck_unsaved), .{ .textColor = theme.warn, .fontSize = 13, .fontId = font_mod.regular, .wrapMode = wrap });
    if (r.failed) |err| clay.text(tx.alloc(a, tx.ck_failed, .{err}), .{ .textColor = theme.warn, .fontSize = 13, .fontId = font_mod.regular, .wrapMode = wrap });
    if (r.failed == null and r.problems.len == 0) clay.text(tx.get(tx.ck_ok), .{ .textColor = theme.text, .fontSize = 14, .fontId = font_mod.regular, .wrapMode = wrap });
    var open_at: ?usize = null;
    for (r.problems, 0..) |p, k| {
        const rid = clay.idi("check_row", @intCast(k));
        const script = og.formats.resource.isScript(p.entry);
        clay.open(.{ .id = rid, .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 } }, .backgroundColor = if (script and clay.pointerOver(rid)) theme.row_hover else theme.panel, .cornerRadius = clay.radius(theme.radius) });
        if (script and clay.hovered() and app.clicked) open_at = k;
        txt(if (p.entry.len > 0) std.fmt.allocPrint(a, "{s}: {s}", .{ p.archive, p.entry }) catch p.archive else p.archive, 13, if (script) theme.accent_hover else theme.text, font_mod.bold);
        clay.text(p.what, .{ .textColor = theme.dim, .fontSize = 13, .fontId = font_mod.regular, .wrapMode = wrap });
        clay.close();
    }
    clay.close();
    clay.close();
    // After the layout: these replace or drop `r`.
    if (open_at) |k| {
        const p = r.problems[k];
        if (app.store.file(p.archive, p.entry)) |f| {
            r.shown = false;
            codeview.open(app, f, null);
        } else |err| app.setStatus(tx.st_import_failed, .{err});
    } else if (rerun) run(app) else if (shut) {
        r.shown = false;
    }
}

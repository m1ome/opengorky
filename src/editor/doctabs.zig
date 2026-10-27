//! Open documents as tabs over the centre (as the concept's editor tabs): whatever is
//! picked in the asset tree (a level, an enemy, an item, a scene or dialogue, a sound,
//! the history, the settings) gets a tab; a click goes back to it, × closes it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const icons = @import("icons.zig");
const codeview = @import("codeview.zig");
const kinds = @import("kinds.zig");
const main = @import("app.zig");
const App = main.App;
const Tab = main.Tab;
const theme = main.theme;
const txt = main.txt;

pub const DocTab = struct {
    tab: Tab,
    /// Kept (edited in, or its tab clicked again); else a preview the next document
    /// opened replaces, as in Zed and VS Code (browsing does not pile up tabs).
    keep: bool = false,
    name_buf: [72]u8 = undefined,
    len: usize = 0,

    pub fn name(self: *const DocTab) []const u8 {
        return self.name_buf[0..self.len];
    }

    fn of(tab: Tab, s: []const u8) DocTab {
        var d: DocTab = .{ .tab = tab };
        d.len = @min(s.len, d.name_buf.len);
        @memcpy(d.name_buf[0..d.len], s[0..d.len]);
        return d;
    }

    fn same(self: *const DocTab, o: DocTab) bool {
        return self.tab == o.tab and std.ascii.eqlIgnoreCase(self.name(), o.name());
    }
};

pub const max = 16;

/// What is open now, as a tab (null: nothing).
fn current(app: *App) ?DocTab {
    if (app.code) |v| return DocTab.of(.code, v.title);
    const n = kinds.of(app.tab).current(app, app.frame.allocator()) orelse return null;
    return DocTab.of(app.tab, n);
}

/// The open document gets a tab: the preview one's place, else a new one (the oldest
/// other goes past `max`). An edit keeps the shown tab.
pub fn sync(app: *App) void {
    const cur = current(app) orelse return;
    // The level's edit mode keeps its tab too (it comes back in the mode).
    const edited = app.store.undo.items.len != app.tab_steps or (if (app.code) |v| v.buf.changed else false) or (app.paint != null and app.code == null);
    app.tab_steps = app.store.undo.items.len;
    for (app.doc_tabs[0..app.doc_tabs_n]) |*d| if (d.same(cur)) {
        if (edited) d.keep = true;
        return;
    };
    for (app.doc_tabs[0..app.doc_tabs_n]) |*d| if (!d.keep) {
        // Code with a syntax error stays (its edits are not applied): kept, a new tab after.
        if (d.tab == .code and !codeview.close(app, d.name())) {
            d.keep = true;
            break;
        }
        forget(app, d.*);
        d.* = cur;
        return;
    };
    if (app.doc_tabs_n == max) {
        forget(app, app.doc_tabs[0]);
        std.mem.copyForwards(DocTab, app.doc_tabs[0 .. max - 1], app.doc_tabs[1..max]);
        app.doc_tabs_n -= 1;
    }
    app.doc_tabs[app.doc_tabs_n] = cur;
    app.doc_tabs_n += 1;
}

/// The shown document's tab kept (the next one opened gets a tab of its own).
pub fn keepCurrent(app: *App) void {
    const cur = current(app) orelse return;
    for (app.doc_tabs[0..app.doc_tabs_n]) |*d| if (d.same(cur)) {
        d.keep = true;
    };
}

fn isActive(app: *App, d: *const DocTab) bool {
    const cur = current(app) orelse return false;
    return d.same(cur);
}

/// Document `name` of kind `tab` shown (as its tab clicked).
pub fn openDoc(app: *App, tab: Tab, name: []const u8) void {
    activate(app, DocTab.of(tab, name));
}

/// Back to the document of tab `d`.
fn activate(app: *App, d: DocTab) void {
    const n = d.name();
    if (d.tab == .code) return codeview.show(app, n);
    // Another document: the shown code stays in its tab.
    codeview.park(app);
    kinds.of(d.tab).open(app, d.tab, n);
}

/// A level tab gone: its level no longer kept loaded.
fn forget(app: *App, d: DocTab) void {
    if (d.tab != .battles and d.tab != .locations) return;
    for (app.levels, 0..) |lv, i| if (std.ascii.eqlIgnoreCase(lv.name, d.name())) return app.forgetLevel(i);
}

/// Tab `k` closed: the active one hands over to its neighbour, or nothing stays open.
fn close(app: *App, k: usize) void {
    const was_active = isActive(app, &app.doc_tabs[k]);
    const gone = app.doc_tabs[k];
    // Code with a syntax error stays open (its edits are not applied yet).
    if (gone.tab == .code and !codeview.close(app, gone.name())) return;
    std.mem.copyForwards(DocTab, app.doc_tabs[k .. app.doc_tabs_n - 1], app.doc_tabs[k + 1 .. app.doc_tabs_n]);
    app.doc_tabs_n -= 1;
    if (!was_active) return forget(app, gone);
    if (app.doc_tabs_n > 0) return activate(app, app.doc_tabs[@min(k, app.doc_tabs_n - 1)]);
    kinds.of(gone.tab).close(app, gone.tab);
}

/// A newly active tab scrolled into the strip (by last frame's layout); the strip's own
/// scrolling is left alone otherwise.
fn revealActive(app: *App) void {
    const cur = current(app) orelse return;
    const k = for (app.doc_tabs[0..app.doc_tabs_n], 0..) |*d, i| {
        if (d.same(cur)) break i;
    } else return;
    const h = std.hash.Wyhash.hash(0, cur.name()) +% @backingInt(cur.tab);
    const strip = clay.box(clay.id("doc_tabs")) orelse return;
    const tb = clay.box(clay.idi("doc_tab", @intCast(k))) orelse return;
    if (h == app.tab_seen) return;
    app.tab_seen = h;
    const sc = ui.Clay_GetScrollContainerData(clay.id("doc_tabs"));
    if (!sc.found) return;
    const pos = sc.scrollPosition;
    if (tb.x + tb.width > strip.x + strip.width) pos.*.x -= tb.x + tb.width - (strip.x + strip.width) + 8 else if (tb.x < strip.x) pos.*.x += strip.x - tb.x + 8;
}

/// The tab strip.
pub fn bar(app: *App, a: Allocator) void {
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(40) }, .padding = .{ .left = 8, .top = 6 }, .childGap = 2, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_BOTTOM } },
        .backgroundColor = theme.bg,
        .border = .{ .color = theme.line, .width = .{ .bottom = 1 } },
    });
    revealActive(app);
    // The tabs scroll sideways when more than fit (clipped: they no longer widen the window).
    clay.openScrollX(.{
        .id = clay.id("doc_tabs"),
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(34) }, .childGap = 2, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_BOTTOM } },
    });
    var act: ?usize = null;
    var shut: ?usize = null;
    for (app.doc_tabs[0..app.doc_tabs_n], 0..) |*d, k| {
        const on = isActive(app, d);
        const tid = clay.idi("doc_tab", @intCast(k));
        const top: ui.Clay_CornerRadius = .{ .topLeft = theme.radius, .topRight = theme.radius, .bottomLeft = 0, .bottomRight = 0 };
        clay.open(.{
            .id = tid,
            .layout = .{ .sizing = .{ .height = clay.fixed(34) }, .padding = .{ .left = 12, .right = 6 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
            .backgroundColor = if (on) theme.panel else if (clay.pointerOver(tid)) theme.row_hover else theme.bg,
            .cornerRadius = top,
            .border = .{ .color = theme.accent, .width = .{ .top = if (on) 2 else 0 } },
        });
        const over_tab = clay.hovered();
        icons.leaf(app.r, app.gpa, kinds.of(d.tab).icon, 15, if (on) theme.accent_hover else theme.dim);
        const label = if (kinds.of(d.tab).title) |m| tx.get(m) else if (d.tab == .sprites) d.name()[if (std.mem.lastIndexOfAny(u8, d.name(), "|\\")) |cut_at| cut_at + 1 else 0..] else d.name();
        txt(label, 13, if (on) theme.text else theme.dim, if (!d.keep) font_mod.italic else if (on) font_mod.bold else font_mod.regular);
        const xid = clay.idi("doc_tab_x", @intCast(k));
        clay.open(.{ .id = xid, .layout = .{ .sizing = .{ .width = clay.fixed(20), .height = clay.fixed(20) }, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = if (clay.pointerOver(xid)) theme.button_hover else .{ .r = 0, .g = 0, .b = 0, .a = 0 }, .cornerRadius = clay.radius(4) });
        const over_x = clay.hovered();
        icons.leaf(app.r, app.gpa, .x, 13, theme.dim);
        clay.close();
        clay.close();
        if (app.clicked and over_x) shut = k else if (app.clicked and over_tab and !on) act = k else if (app.clicked and over_tab) d.keep = true;
    }
    clay.close();
    // "+": find something to open (the asset search).
    const pid = clay.id("doc_tab_new");
    if (main.clickable(app, .{ .id = pid, .layout = .{ .sizing = .{ .width = clay.fixed(32), .height = clay.fixed(32) }, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.bg, .cornerRadius = clay.radius(theme.radius) }, false)) app.tree_focus = true;
    icons.leaf(app.r, app.gpa, .plus, 16, theme.dim);
    clay.close();
    clay.close();
    _ = a;
    if (shut) |k| close(app, k) else if (act) |k| activate(app, app.doc_tabs[k]);
}

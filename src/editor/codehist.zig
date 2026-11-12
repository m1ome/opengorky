//! The code editor's jumps: where each Go to (and a link from the code) left from, for
//! Back and Forward (Ctrl+- / Ctrl+Shift+-, Alt+Left/Right off the Mac, the mouse's side
//! buttons), and the tab a jump opened. That tab is the jumps' preview: the next jump from
//! it replaces it instead of keeping it, so following a chain of definitions keeps one tab
//! (an edit keeps it, as any preview tab; Back finds every place again).

const std = @import("std");
const doctabs = @import("doctabs.zig");
const DocTab = @import("doctab.zig").DocTab;
const App = @import("app.zig").App;

/// A place in the code: the file (Store index), its cursor and first line shown.
const Place = struct { file: usize, cursor: usize, scroll: usize };

const max = 100;
var back: std.ArrayList(Place) = .empty;
var forward: std.ArrayList(Place) = .empty;
/// The tab the last jump opened.
var jumped: ?DocTab = null;

fn here(app: *App) ?Place {
    const v = app.code orelse return null;
    return .{ .file = v.file, .cursor = v.buf.cursor, .scroll = v.scroll };
}

fn push(list: *std.ArrayList(Place), p: Place) void {
    if (list.items.len > 0) {
        const top = list.items[list.items.len - 1];
        if (top.file == p.file and top.cursor == p.cursor) return;
    }
    if (list.items.len == max) _ = list.orderedRemove(0);
    list.append(std.heap.page_allocator, p) catch {};
}

/// The shown tab is the last jump's and nothing kept it (an edit, a pick in the tree).
pub fn onJumped(app: *App) bool {
    doctabs.refresh(app);
    const cur = app.active orelse return false;
    const j = jumped orelse return false;
    if (!cur.same(j)) return false;
    for (app.doc_tabs.items) |d| if (d.same(cur)) return !d.keep;
    return false;
}

/// Before a jump: the place left remembered (a new jump forgets the places gone back
/// from); the shown tab kept, unless it is the last jump's own.
pub fn leave(app: *App) void {
    if (here(app)) |p| push(&back, p);
    forward.clearRetainingCapacity();
    if (!onJumped(app)) doctabs.keepCurrent(app);
}

/// After a jump: the tab it opened is the jumps' preview.
pub fn arrived(app: *App) void {
    doctabs.refresh(app);
    jumped = app.active;
}

/// Back (`fwd` false) or Forward: the place remembered shown again; false when none.
pub fn step(app: *App, fwd: bool) bool {
    const from = if (fwd) &forward else &back;
    const to = if (fwd) &back else &forward;
    while (from.pop()) |p| {
        if (p.file >= app.store.files.items.len or app.store.gone(p.file)) continue;
        if (here(app)) |cur| push(to, cur);
        if (!onJumped(app)) doctabs.keepCurrent(app);
        doctabs.showCode(app, p.file, null);
        const v = app.code orelse return false;
        v.buf.cursor = @min(p.cursor, v.buf.str().len);
        v.buf.anchor = null;
        v.scroll = p.scroll;
        v.follow_x = true;
        arrived(app);
        return true;
    }
    return false;
}

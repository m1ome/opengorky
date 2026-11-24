//! Open documents as tabs over the centre (as the concept's editor tabs): whatever is
//! picked in the asset tree (a level, an enemy, an item, a scene or dialogue, a sound,
//! the history, the settings) gets a tab; a click goes back to it, × closes it.
//! Links (`link`, `followLink`: a scene, a level and its object) open theirs (App methods).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const codeview = @import("codeview.zig");
const kinds = @import("kinds.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Tab = app_mod.Tab;
const theme = app_mod.theme;
const viewportRect = App.viewportRect;

pub const DocTab = @import("doctab.zig").DocTab;

/// The document shown now (app.active), worked out from the centre: the code over the
/// page, else the page's document. Everything that asks "what is open" reads app.active.
pub fn refresh(app: *App) void {
    app.active = if (app.code) |v| DocTab.of(.code, codeview.keyOf(app, v)) else if (kinds.of(app.tab).current(app, app.frame.allocator())) |n| DocTab.of(app.tab, n) else null;
    // Debug builds: the active tab is its kind's open document (one source of truth).
    if (@import("builtin").mode == .debug) if (app.active) |*d| if (d.tab != .code) {
        std.debug.assert(d.tab == app.tab and std.mem.eql(u8, kinds.of(d.tab).current(app, app.frame.allocator()) orelse "", d.key()));
    };
}

/// Document `key` of kind `tab` is the one shown (a tree row's highlight).
pub fn isShown(app: *const App, tab: Tab, key: []const u8) bool {
    return if (app.active) |*d| d.is(tab, key) else false;
}

/// The open document gets a tab: the preview one's place, else a new one (the list grows;
/// the strip scrolls). An edit keeps the shown tab.
pub fn sync(app: *App) void {
    dropClosedCode(app);
    refresh(app);
    const cur = app.active orelse return;
    // Edits from now on are this tab's (it saves or discards them when closed).
    app.store.doc = cur.mark();
    // The level's edit mode keeps its tab too (it comes back in the mode).
    const edited = app.store.undo.items.len != app.tab_steps or (if (app.code) |v| v.buf.changed else false) or (app.paint != null and app.code == null);
    app.tab_steps = app.store.undo.items.len;
    for (app.doc_tabs.items) |*d| if (d.same(cur)) {
        if (edited) d.keep = true;
        return;
    };
    for (app.doc_tabs.items) |*d| if (!d.keep) {
        // Unsaved edits it got before its first sync (a scripted edit): kept, not dropped.
        if (app.store.dirtyDoc(d.mark())) {
            d.keep = true;
            continue;
        }
        // Code with a syntax error stays (its edits are not applied): kept, a new tab after.
        if (d.tab == .code and !codeview.close(app, d.key())) {
            d.keep = true;
            break;
        }
        forget(app, d.*);
        d.* = cur;
        return;
    };
    app.doc_tabs.append(app.gpa, cur) catch {};
}

/// Code tabs whose view is gone (its file's making undone) closed.
fn dropClosedCode(app: *App) void {
    var k: usize = 0;
    while (k < app.doc_tabs.items.len) {
        if (app.doc_tabs.items[k].tab == .code and !codeview.has(app, app.doc_tabs.items[k].key())) {
            _ = app.doc_tabs.orderedRemove(k);
        } else k += 1;
    }
}

/// The shown document's tab kept (the next one opened gets a tab of its own).
pub fn keepCurrent(app: *App) void {
    refresh(app);
    const cur = app.active orelse return;
    for (app.doc_tabs.items) |*d| if (d.same(cur)) {
        d.keep = true;
    };
}

fn isActive(app: *App, d: *const DocTab) bool {
    const cur = app.active orelse return false;
    return d.same(cur);
}

/// Document `key` of kind `tab` shown (a tree row, a link, its tab clicked): the one way
/// documents open. Code is `archive|entry` (opened if no view has it yet).
pub fn show(app: *App, tab: Tab, key: []const u8) void {
    if (tab == .code) codeview.show(app, key) else {
        // Another document: the shown code stays in its tab.
        codeview.park(app);
        kinds.of(tab).open(app, tab, key);
    }
    refresh(app);
}

/// Store file `file` shown as code (the cursor at byte `at` of the game text, if
/// given): `show` of `.code` for a caller that has the file, not its key.
pub fn showCode(app: *App, file: usize, at: ?usize) void {
    codeview.open(app, file, at);
    refresh(app);
}

/// The page of `tab` shown on the document it has (none: as `show` of none), e.g. the
/// sounds page before an import, its picked sound kept.
pub fn showPage(app: *App, tab: Tab) void {
    const a = app.frame.allocator();
    // A copy: the key is the page's own name buffer, set again by `show`.
    show(app, tab, a.dupe(u8, kinds.of(tab).current(app, a) orelse "") catch "");
}

/// `show` in a tab of its own: the shown one kept (links that open "beside").
pub fn openKept(app: *App, tab: Tab, key: []const u8) void {
    keepCurrent(app);
    show(app, tab, key);
}

/// Back to the document of tab `d`.
fn activate(app: *App, d: DocTab) void {
    show(app, d.tab, d.key());
}

/// A level tab gone: its level no longer kept loaded.
fn forget(app: *App, d: DocTab) void {
    if (d.tab != .battles and d.tab != .locations) return;
    if (app.levelIndex(d.key())) |i| app.forgetLevel(i);
}

/// Level `i` has a tab (kept loaded while away).
pub fn hasLevel(app: *const App, i: usize) bool {
    for (app.doc_tabs.items) |*d| if ((d.tab == .battles or d.tab == .locations) and std.ascii.eqlIgnoreCase(app.levels[i].name, d.key())) return true;
    return false;
}

/// Tab `k` closed: the active one hands over to its neighbour, or nothing stays open.
/// `ask`: its unsaved edits saved or taken back as answered (else they stay, unsaved).
pub fn close(app: *App, k: usize, ask: bool) void {
    if (k >= app.doc_tabs.items.len) return;
    const was_active = isActive(app, &app.doc_tabs.items[k]);
    const gone = app.doc_tabs.items[k];
    // Its unsaved edits: saved or taken back (code: its typing applied first, as its tab's).
    const doc = gone.mark();
    if (gone.tab == .code) {
        const shown = app.store.doc;
        app.store.doc = doc;
        defer app.store.doc = shown;
        if (!codeview.applyOne(app, gone.key())) return;
    }
    if (ask and app.store.dirtyDoc(doc)) switch (askSave(app, gone)) {
        .save => {
            app.saveOnly(doc);
            if (app.store.dirtyDoc(doc)) return;
        },
        .discard => app.discardDoc(doc),
        .cancel => return,
    };
    // Code with a syntax error stays open (its edits are not applied yet).
    if (gone.tab == .code and !codeview.close(app, gone.key())) return;
    _ = app.doc_tabs.orderedRemove(k);
    const n = app.doc_tabs.items.len;
    if (!was_active) return forget(app, gone);
    if (n > 0) return activate(app, app.doc_tabs.items[@min(k, n - 1)]);
    kinds.of(gone.tab).close(app, gone.tab);
    refresh(app);
}

pub const Answer = enum { save, discard, cancel };
/// Scripted checks (`--tab-close`): the answer given instead of asking.
pub var scripted_answer: ?Answer = null;

/// The shown tab's × clicked (scripted checks): closed at the next frame's start.
pub fn closeActive(app: *App) void {
    refresh(app);
    for (app.doc_tabs.items, 0..) |*d, k| if (isActive(app, d)) {
        app.tab_close = k;
        return;
    };
}

/// The shown tab closed without asking: what it showed was just deleted (its deletion
/// is an unsaved edit of its own, which "don't save" would take back).
pub fn dropActive(app: *App) void {
    closeActive(app);
    app.tab_close_quiet = app.tab_close != null;
}

/// Save, don't save or keep the tab open: the system's question box.
fn askSave(app: *App, d: DocTab) Answer {
    if (scripted_answer) |x| return x;
    const c = @import("sdl");
    // Zeroed: the text printed into all but its last byte ends in a 0.
    var buf: [256]u8 = @splat(0);
    _ = tx.print(buf[0 .. buf.len - 1], tx.q_unsaved_tab, .{kinds.label(app, d.tab, d.key())});
    const buttons = [_]c.SDL_MessageBoxButtonData{
        .{ .flags = c.SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, .buttonID = 1, .text = tx.get(tx.q_save).ptr },
        .{ .flags = 0, .buttonID = 2, .text = tx.get(tx.q_discard).ptr },
        .{ .flags = c.SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, .buttonID = 0, .text = tx.get(tx.cancel).ptr },
    };
    const data: c.SDL_MessageBoxData = .{ .flags = c.SDL_MESSAGEBOX_WARNING, .window = app.window, .title = tx.get(tx.title).ptr, .message = @ptrCast(&buf), .numbuttons = buttons.len, .buttons = &buttons, .colorScheme = null };
    var hit: c_int = 0;
    if (!c.SDL_ShowMessageBox(&data, &hit)) return .cancel;
    return switch (hit) {
        1 => .save,
        2 => .discard,
        else => .cancel,
    };
}

/// A newly active tab scrolled into the strip (by last frame's layout); the strip's own
/// scrolling is left alone otherwise.
fn revealActive(app: *App) void {
    const cur = app.active orelse return;
    const k = for (app.doc_tabs.items, 0..) |*d, i| {
        if (d.same(cur)) break i;
    } else return;
    const h = cur.mark();
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
/// A tab's height: the strip's, less a gap above it.
const tab_h = lay.height.tab - lay.space.xs - lay.border.mark;

pub fn bar(app: *App, a: Allocator) void {
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(lay.height.tab) }, .padding = .{ .left = lay.space.sm }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_BOTTOM } },
        .backgroundColor = theme.bg,
        .border = .{ .color = theme.line, .width = .{ .bottom = lay.border.line } },
    });
    revealActive(app);
    // The tabs scroll sideways when more than fit (clipped: they no longer widen the window).
    clay.openScrollX(.{
        .id = clay.id("doc_tabs"),
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(tab_h) }, .childGap = lay.border.mark, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_BOTTOM } },
    });
    var act: ?usize = null;
    var shut: ?usize = null;
    for (app.doc_tabs.items, 0..) |*d, k| {
        const on = isActive(app, d);
        const tid = clay.idi("doc_tab", @intCast(k));
        const top: ui.Clay_CornerRadius = .{ .topLeft = lay.radius.md, .topRight = lay.radius.md, .bottomLeft = 0, .bottomRight = 0 };
        clay.open(.{
            .id = tid,
            .layout = .{ .sizing = .{ .height = clay.fixed(tab_h) }, .padding = .{ .left = lay.space.md, .right = lay.space.xs }, .childGap = lay.space.sm, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
            .backgroundColor = if (on) theme.panel else if (clay.pointerOver(tid)) theme.row_hover else theme.bg,
            .cornerRadius = top,
            .border = .{ .color = theme.accent, .width = .{ .top = if (on) lay.border.mark else 0 } },
        });
        const over_tab = clay.hovered();
        gui.icon(app, kinds.of(d.tab).icon, lay.icon.md, if (on) theme.accent_hover else theme.dim);
        const label = kinds.label(app, d.tab, d.key());
        gui.txt(label, .body, if (on) theme.text else theme.dim, if (!d.keep) font_mod.italic else if (on) font_mod.bold else font_mod.regular);
        // Unsaved edits made in it: asked about when it closes.
        if (app.store.dirtyDoc(d.mark())) gui.dot(theme.warn);
        const hit_x = gui.iconButton(app, clay.idi("doc_tab_x", @intCast(k)), .x, false);
        clay.close();
        if (hit_x) shut = k else if (app.clicked and over_tab and !on) act = k else if (app.clicked and over_tab) d.keep = true;
    }
    clay.close();
    // "+": find something to open (the asset search).
    if (gui.buttonOf(app, clay.id("doc_tab_new"), .{ .icon = .plus, .style = .quiet, .size = .tool })) app.focusTree();
    clay.close();
    _ = a;
    if (shut) |k| app.tab_close = k else if (act) |k| activate(app, app.doc_tabs.items[k]);
}

/// A link to follow once this frame is laid out: scene `name`, or level `name`
/// with object `obj`.
pub fn link(self: *App, scene: bool, name: []const u8, obj: ?[]const u8) void {
    var n: @FieldType(@typeInfo(@FieldType(App, "nav")).optional.child, "name") = undefined;
    var o: @FieldType(@typeInfo(@FieldType(App, "nav")).optional.child, "obj") = undefined;
    const nl = @min(name.len, n.len);
    @memcpy(n[0..nl], name[0..nl]);
    const ob = obj orelse "";
    const ol = @min(ob.len, o.len);
    @memcpy(o[0..ol], ob[0..ol]);
    self.nav = .{ .scene = scene, .name = n, .name_len = nl, .obj = o, .obj_len = ol };
}

pub fn followLink(self: *App) void {
    const l = self.nav orelse return;
    self.nav = null;
    self.trigger = null;
    if (l.scene) return self.showScene(l.name[0..l.name_len]);
    self.showLevel(l.name[0..l.name_len], if (l.obj_len > 0) l.obj[0..l.obj_len] else null);
}

/// The Scenes tab on scene `name` (a link from a trigger or another scene).
pub fn showScene(self: *App, name: []const u8) void {
    if (self.sceneIndex(name) != null) return show(self, .scenes, name);
    self.setStatus(tx.st_no_such_scene, .{name});
}

/// Level `level` open on its tab; area or object `obj` (if given) picked and centred.
pub fn showLevel(self: *App, level_name: []const u8, obj: ?[]const u8) void {
    if (self.levelIndex(level_name)) |i| {
        show(self, if (self.levels[i].battle) .battles else .locations, self.levels[i].name);
        const d = self.doc orelse return;
        const name = obj orelse return;
        for (d.objects.items, 0..) |o, k| if (std.ascii.eqlIgnoreCase(o.name, name)) {
            self.selected = k;
            if (viewportRect()) |v| {
                if (!d.fitted) d.fit(v);
                d.origin = .{ o.pos[0] - v.w / 2 / d.zoom, o.pos[1] - v.h / 2 / d.zoom };
            }
            return;
        };
        return;
    }
    self.setStatus(tx.st_no_such_level, .{level_name});
}

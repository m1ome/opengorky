//! Code tab: any script file (level, area, class, hero, scene) as editable text with
//! highlighting and completion of the functions the game's scripts call (an example
//! call of each beside the list). A function taken from the list comes with sample
//! arguments, Tab going through them; inside a call its parameters show above the line,
//! and F1 opens the functions' help (api.zig). Saving (Cmd+S: its tab's edits) puts the text into the Store as one undo
//! step; the game's encoding is kept (code.zig). Long lines scroll sideways; the pointer
//! resting on a word tells what it is; Cmd+click, F12 or the right-click menu go to what
//! a word or string names (codenav.zig), Shift+F12 lists its uses across the game.
//! This file takes the input; its parts: codetabs (open files), codecheck, codeside
//! (the page around the text), codedraw, codetips, codecomplete.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const tx = @import("text.zig");
const code = @import("code.zig");
const rulesapi = @import("rulesapi.zig");
const codenav = @import("codenav.zig");
const doctabs = @import("doctabs.zig");
const app_mod = @import("app.zig");
const main = @import("main.zig");
const App = app_mod.App;
const theme = app_mod.theme;

pub const pt: u16 = 15;
pub const line_h: f32 = 21;
pub const gutter: f32 = 56;

const View = code.View;
const codetabs = @import("codetabs.zig");
const codecheck = @import("codecheck.zig");
const codeside = @import("codeside.zig");
const codedraw = @import("codedraw.zig");
const codecomplete = @import("codecomplete.zig");
const codesym = @import("codesym.zig");
const codehist = @import("codehist.zig");

pub const anyChanged = codetabs.anyChanged;
pub const apply = codetabs.apply;
pub const applyAll = codetabs.applyAll;
pub const applyOne = codetabs.applyOne;
pub const close = codetabs.close;
pub const dropGone = codetabs.dropGone;
pub const has = codetabs.has;
pub const keyOf = codetabs.keyOf;
pub const open = codetabs.open;
pub const park = codetabs.park;
pub const show = codetabs.show;
pub const checkAll = codecheck.checkAll;
pub const page = codeside.page;
pub const signature = codeside.signature;
pub const draw = codedraw.draw;
pub const excerpt = codedraw.excerpt;

/// Typed text; in an argument with known values (after `(`, `,` or in its string) the
/// list opens and filters as it is typed.
pub fn typed(app: *App, v: *View, s: []const u8) void {
    v.buf.typeText(s) catch {};
    v.tasks = false;
    v.popup = codecomplete.opensOnType(app, v, s);
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
    // Back and Forward through the jumps (codehist): Ctrl+- / Ctrl+Shift+- (VS Code), and
    // off the Mac Alt+Left/Right (there Alt moves by words).
    if ((k == c.SDLK_MINUS and (mod & c.SDL_KMOD_CTRL) != 0) or (!mac and alt and (k == c.SDLK_LEFT or k == c.SDLK_RIGHT))) {
        const fwd = if (k == c.SDLK_MINUS) shift else k == c.SDLK_RIGHT;
        if (!codehist.step(app, fwd)) {
            if (fwd) app.setStatus(tx.st_hist_forward, .{}) else app.setStatus(tx.st_hist_back, .{});
        }
        return true;
    }
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
        c.SDLK_S => if (doctabs.DocTab.of(.code, keyOf(app, v))) |d| app.saveOnly(d.mark()), // this tab's edits (as a page's, events.zig)
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
            v.tasks = codecomplete.tasksAt(app, v);
            return true;
        },
        c.SDLK_SLASH => b.lines(.comment) catch {},
        c.SDLK_RIGHTBRACKET => b.lines(.indent) catch {},
        c.SDLK_LEFTBRACKET => b.lines(.outdent) catch {},
        c.SDLK_L => b.selectLine(b.cursor, true),
        c.SDLK_K => if (shift) b.deleteLines() catch {} else return false,
        // Plain Cmd+D is no tree shortcut here (it would copy the document under the code).
        c.SDLK_D => if (shift) b.duplicateLines() catch {},
        c.SDLK_RETURN, c.SDLK_KP_ENTER => b.openLine(shift) catch {},
        c.SDLK_F => if (shift) formatText(app, v) else openFind(app, v),
        c.SDLK_G => findNext(v, !shift),
        else => return false,
    } else switch (k) {
        c.SDLK_ESCAPE => if (v.menu != null) {
            v.menu = null;
        } else if (v.popup) {
            v.popup = false;
            v.tasks = false;
        } else if (v.find_open) {
            v.find_open = false;
        } else {
            b.anchor = null;
        },
        c.SDLK_RETURN, c.SDLK_KP_ENTER => if (!codecomplete.accept(app, v)) b.newline() catch {},
        // Tab: the chosen word, the next argument, or two spaces; over lines, them in.
        c.SDLK_TAB => if (shift) {
            b.lines(.outdent) catch {};
        } else if (!codecomplete.accept(app, v)) {
            if (multiLine(b)) b.lines(.indent) catch {} else if (!b.nextArg()) b.insert("  ") catch {};
        },
        // On a word with an article: the Reference on it; else the help column.
        c.SDLK_F1 => if (!helpWord(app, v)) {
            v.help = !v.help;
        },
        c.SDLK_F3 => findNext(v, !shift),
        c.SDLK_F12 => if (shift) findUsages(app, v) else goTo(app, v),
        c.SDLK_PAGEUP => b.vertical(-@as(i32, @intCast(codedraw.visibleLines(v))), shift),
        c.SDLK_PAGEDOWN => b.vertical(@intCast(codedraw.visibleLines(v)), shift),
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

/// The find bar closed, its field no longer typed into.
pub fn closeFind(app: *App, v: *View) void {
    v.find_open = false;
    if (app.text_edit) |e| if (e.id.id == clay.id("code_find").id) {
        app.text_edit = null;
    };
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
pub fn findNext(v: *View, forward: bool) void {
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

pub fn findFrom(t: []const u8, q: []const u8, from: usize) ?usize {
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

/// F12, Cmd+click, the menu's Jump to definition: the function named at the cursor (in
/// this file or another game script), else what the word or string there names
/// (codenav): opened, a pick list when it is several, a status line when nothing.
pub fn goTo(app: *App, v: *View) void {
    _ = codenav.picks_arena.reset(.retain_capacity);
    const pa = codenav.picks_arena.allocator();
    switch (defsAt(app, v, pa, v.buf.cursor)) {
        .none => {},
        .here => |at| {
            codehist.leave(app);
            v.buf.anchor = null;
            v.buf.cursor = at;
            centre(v);
        },
        .file => |g| {
            // Another file: in a tab (this one kept, unless a jump opened it: codehist).
            const f = app.store.file(g.archive, g.entry) catch return;
            codehist.leave(app);
            open(app, f, g.at);
            codehist.arrived(app);
        },
        .rules_doc => |rc| app.setStatus(tx.st_rules_call, .{ codeside.signatureOf(pa, rc), tx.get(rc.doc) }),
        .help => |w| _ = @import("reference.zig").openWord(app, w),
        .hits => |hits| switch (hits.len) {
            0 => {
                const t = v.buf.str();
                const tok = code.tokenAt(t, v.buf.cursor) orelse return;
                app.setStatus(tx.st_goto_none, .{t[tok.start..tok.end]});
            },
            1 => codenav.go(app, hits[0]),
            else => {
                codenav.picks = hits;
                v.picks = true;
                v.menu = menuAt(app, v);
            },
        },
    }
}

/// Where Go to at offset `i` leads, nothing done (goTo acts on it; the code probe counts it).
const Defs = union(enum) {
    /// No token at `i`.
    none,
    /// A function of this text, at that offset.
    here: usize,
    /// A game script's function: its file and offset.
    file: struct { archive: []const u8, entry: []const u8, at: usize },
    /// A rules row naming nothing: the call's doc instead.
    rules_doc: *const rulesapi.Call,
    /// The engine's own name (a builtin): its Reference article.
    help: []const u8,
    /// What the word or string names (none: nothing).
    hits: []const codenav.Hit,
};

pub fn defsAt(app: *App, v: *View, a: Allocator, i: usize) Defs {
    const t = v.buf.str();
    const tok = code.tokenAt(t, i) orelse return .none;
    const w = t[tok.start..tok.end];
    // `a::b::f` up to the word: the whole path is the name.
    const qw = if (tok.string) w else t[codesym.qualifiedStart(t, tok.start)..codesym.qualifiedEnd(t, tok.end)];
    if (!tok.string) {
        // A project's own declaration: its code.
        const ds = codesym.defsAt(app, v, a, i);
        const own = app.store.files.items[v.file];
        if (ds.len == 1 and std.mem.eql(u8, ds[0].archive, own.archive) and std.ascii.eqlIgnoreCase(ds[0].entry, own.entry)) return .{ .here = ds[0].at };
        if (ds.len > 0) {
            const hits = a.alloc(codenav.Hit, ds.len) catch return .none;
            for (ds, hits) |d, *h| h.* = .{ .label = d.label, .to = .{ .code = .{ .archive = d.archive, .entry = d.entry, .at = d.at } } };
            return .{ .hits = hits };
        }
        if (ownFn(t, w)) |at| return .{ .here = at };
        if (codecheck.gameFn(app, w)) |g| {
            const bar = std.mem.indexOfScalar(u8, g.file, '|') orelse return .none;
            return .{ .file = .{ .archive = g.file[0..bar], .entry = g.file[bar + 1 ..], .at = g.at } };
        }
    }
    var list: std.ArrayList(codenav.Hit) = .empty;
    list.appendSlice(a, codenav.resolve(app, a, qw, true)) catch {};
    if (list.items.len == 0 and qw.len != w.len) list.appendSlice(a, codenav.resolve(app, a, w, true)) catch {};
    // A string naming a block or a row of the project (`"cam_1"`: the scene's point).
    if (list.items.len == 0 and tok.string) for (codesym.defsAt(app, v, a, i)) |d| list.append(a, .{ .label = d.label, .to = .{ .code = .{ .archive = d.archive, .entry = d.entry, .at = d.at } } }) catch {};
    // A rules call's name, field or value: the campaign's page; the entity the value or
    // the row's key names; else the call's doc.
    if (codecomplete.rulesFile(app, v)) if (rulesRow(t, i)) |row| {
        if (std.ascii.eqlIgnoreCase(row.name, "Campaign")) {
            list.append(a, .{ .label = tx.alloc(a, tx.code_rules_row, .{row.name}), .to = .{ .doc = .{ .tab = .campaign, .name = "" } } }) catch {};
        } else if (rowHits(app, a, t, i, row.src, &list)) {
            return if (rulesapi.find(row.name)) |rc| .{ .rules_doc = rc } else .none;
        }
    };
    // Nothing of the game's: an engine builtin's article.
    if (list.items.len == 0 and !tok.string) if (@import("reference.zig").find(qw) != null) return .{ .help = qw };
    return .{ .hits = list.items };
}

/// Go to on rules row `src` (a slice of `t`) at offset `i`: what the value there names
/// (codenav.rulesHits; a number of a field naming none dropped), else what the row's
/// first entity field (its key) names. True: the doc is wanted instead (on the call's
/// name, or nothing named).
fn rowHits(app: *App, a: Allocator, t: []const u8, i: usize, src: []const u8, list: *std.ArrayList(codenav.Hit)) bool {
    if (codeside.callName(t, i) != null) return true;
    const r = codeside.rulesAt(t, i) orelse return true;
    if (r.field) |f| if (i >= r.arg.?.value_start) {
        if (f.ref != .name_id and (std.fmt.parseInt(i32, std.mem.trim(u8, r.arg.?.value, "\" "), 10) catch null) != null) list.clearRetainingCapacity();
        if (list.items.len == 0) list.appendSlice(a, codenav.rulesHits(app, a, f, r.arg.?.value)) catch {};
        if (list.items.len > 0) return false;
    };
    list.clearRetainingCapacity();
    const base = @intFromPtr(src.ptr) - @intFromPtr(t.ptr);
    for (r.call.fields) |*f| {
        if (f.ref == .none or f.ref == .text) continue;
        var it = code.wordUses(src, f.name);
        while (it.next()) |k| {
            const arg = code.namedArg(t, r.open, base + k) orelse continue;
            if (!std.ascii.eqlIgnoreCase(arg.name, f.name)) continue;
            list.appendSlice(a, codenav.rulesHits(app, a, f, arg.value)) catch {};
            if (list.items.len > 0) return false;
        }
    }
    return true;
}

/// The table row call at offset `i` (on its name or in its arguments): its name and text
/// `Name(…);`; null for none (or `adjust`).
pub fn rulesRow(t: []const u8, i: usize) ?struct { name: []const u8, src: []const u8 } {
    const rc, const paren = if (codeside.callName(t, i)) |x| .{ x, std.mem.indexOfScalarPos(u8, t, i, '(') orelse return null } else if (codeside.rulesAt(t, i)) |r| .{ r.call, r.open } else return null;
    if (std.ascii.eqlIgnoreCase(rc.name, "adjust")) return null;
    const end = code.argsEnd(t, paren) orelse return null;
    // The call's statement: from its name to its `;`.
    const from = std.mem.lastIndexOf(u8, t[0..paren], rc.name) orelse return null;
    return .{ .name = rc.name, .src = t[from..@min(t.len, end + 2)] };
}

/// Offset of function `w`'s header in `t`.
pub fn ownFn(t: []const u8, w: []const u8) ?usize {
    if (w.len == 0) return null;
    var fa: std.heap.FixedBufferAllocator = .init(&def_buf);
    for (codeside.functions(fa.allocator(), t)) |f| if (std.mem.eql(u8, f.name, w)) return f.at;
    return null;
}

var def_buf: [16 * 1024]u8 = undefined;

/// Where a menu opens: at the pointer over the text, else under the cursor.
fn menuAt(app: *App, v: *const View) [2]f32 {
    const t = v.buf.str();
    var line: usize = 0;
    for (t[0..v.buf.cursor]) |ch| line += @intFromBool(ch == '\n');
    const p: [2]f32 = if (overText(v, app.mouse)) app.mouse else .{
        v.rect.x + gutter + codedraw.width(app, t[code.lineStart(t, v.buf.cursor)..v.buf.cursor]) - v.hscroll,
        v.rect.y + 4 + @as(f32, @floatFromInt(line -| v.scroll + 1)) * line_h,
    };
    return .{ @min(p[0] + 2, app.size[0] - menu_w - 8), @min(p[1], app.size[1] - 280) };
}

/// The Reference opened on the word or string at the cursor; false when it has no article.
fn helpWord(app: *App, v: *View) bool {
    const t = v.buf.str();
    const tok = code.tokenAt(t, v.buf.cursor) orelse return false;
    return @import("reference.zig").openWord(app, std.mem.trim(u8, t[tok.start..tok.end], "\""));
}

/// Shift+F12, the menu's Find usages: the word or string at the cursor across the
/// game's scripts and rules files, in the bottom's Usages tab.
pub fn findUsages(app: *App, v: *View) void {
    const t = v.buf.str();
    const tok = code.tokenAt(t, v.buf.cursor) orelse return;
    codenav.findUses(app, t[tok.start..tok.end], v, v.buf.cursor);
    app.code_bottom = .usages;
}

/// The right button over the text: the cursor there (unless in the selection) and the menu.
pub fn openMenu(app: *App, v: *View) void {
    const i = offsetAt(app, v, app.mouse);
    const in_sel = if (v.buf.selection()) |s| i >= s[0] and i <= s[1] else false;
    if (!in_sel) pointer(app, v, app.mouse, false);
    v.picks = false;
    v.menu = menuAt(app, v);
}

const menu_w = lay.width.menu * 1.5;

/// The right-click menu (Jump to definition, Find usages, Copy, Paste, Format) or Go
/// to's pick list.
pub fn menu(app: *App, a: Allocator, v: *View) void {
    const at = v.menu orelse return;
    gui.menuPanel(clay.id("code_menu"), menu_w, .{ .offset = .{ .x = at[0], .y = at[1] }, .zIndex = 100, .attachTo = ui.CLAY_ATTACH_TO_ROOT });
    if (v.picks) {
        gui.menuTitle(a, tx.get(tx.code_goto_pick), "");
        gui.menuLine();
        for (codenav.picks, 0..) |h, k| if (gui.menuRow(app, std.fmt.allocPrint(a, "code_pick{d}", .{k}) catch "code_pick", .chevron_right, h.label, "", theme.text, true)) {
            v.menu = null;
            codenav.go(app, h);
        };
    } else {
        const has_tok = code.tokenAt(v.buf.str(), v.buf.cursor) != null;
        if (gui.menuRow(app, "code_m_goto", .chevron_right, tx.get(tx.code_m_goto), "F12", theme.text, has_tok)) {
            v.menu = null;
            goTo(app, v);
        }
        if (gui.menuRow(app, "code_m_uses", .search, tx.get(tx.code_m_uses), "Shift+F12", theme.text, has_tok)) {
            v.menu = null;
            findUsages(app, v);
        }
        gui.menuLine();
        if (gui.menuRow(app, "code_m_copy", .copy, tx.get(tx.cm_copy), main.cmdKey(a, "C"), theme.text, true)) {
            v.menu = null;
            _ = key(app, v, c.SDLK_C, c.SDL_KMOD_GUI);
        }
        if (gui.menuRow(app, "code_m_paste", .copy, tx.get(tx.code_m_paste), main.cmdKey(a, "V"), theme.text, true)) {
            v.menu = null;
            _ = key(app, v, c.SDLK_V, c.SDL_KMOD_GUI);
        }
        if (gui.menuRow(app, "code_m_format", .file_text, tx.get(tx.code_format), main.cmdKey(a, "Shift+F"), theme.text, true)) {
            v.menu = null;
            formatText(app, v);
        }
    }
    clay.close();
}

/// The cursor to line `line`, column `col` (both from 1, bytes), shown.
pub fn cursorTo(v: *View, line: u32, col: u32) void {
    codeside.goLine(v, line);
    const t = v.buf.str();
    v.buf.cursor = @min(v.buf.cursor + (col -| 1), code.lineEnd(t, v.buf.cursor));
    follow(v);
}

/// Where text offset `i` is drawn (its line shown): the middle of the character there.
pub fn pointOf(app: *App, v: *const View, i: usize) [2]f32 {
    const t = v.buf.str();
    var line: usize = 0;
    for (t[0..i]) |ch| line += @intFromBool(ch == '\n');
    const ls = code.lineStart(t, i);
    const half = if (i < t.len) codedraw.width(app, t[i .. i + 1]) / 2 else 0;
    return .{ v.rect.x + gutter - v.hscroll + codedraw.width(app, t[ls..i]) + half, v.rect.y + 4 + @as(f32, @floatFromInt(line -| v.scroll)) * line_h + line_h / 2 };
}

/// The cursor's line in the middle of the view (a jump's target).
fn centre(v: *View) void {
    const t = v.buf.str();
    const line = std.mem.count(u8, t[0..v.buf.cursor], "\n");
    v.scroll = line -| codedraw.visibleLines(v) / 2;
    v.follow_x = true;
}

/// Scrolls so the cursor's line is shown (and its column, at the next draw).
pub fn follow(v: *View) void {
    const t = v.buf.str();
    var line: usize = 0;
    for (t[0..v.buf.cursor]) |ch| line += @intFromBool(ch == '\n');
    const vis = codedraw.visibleLines(v);
    if (line < v.scroll) v.scroll = line;
    if (line >= v.scroll + vis) v.scroll = line + 1 - vis;
    v.follow_x = true;
}

/// The wheel over the text: lines up and down; sideways (a trackpad's swipe, Shift with
/// the wheel) the long lines, by the gesture's main axis as the other scroll areas.
pub fn wheel(v: *View, dx: f32, dy: f32, shift: bool) void {
    // The words pass under a still pointer: its tip waits until the text rests (else each
    // word's tip was worked out while scrolling).
    v.rest_since = c.SDL_GetTicks();
    const sx = if (shift and dx == 0) dy else dx;
    if (@abs(sx) > @abs(dy) or (shift and sx != 0)) {
        v.hscroll -= sx * 3 * line_h;
        codedraw.clampH(v);
        return;
    }
    const step: i64 = @intFromFloat(-dy * 3);
    v.scroll = @intCast(std.math.clamp(@as(i64, @intCast(v.scroll)) + step, 0, @as(i64, @intCast(codedraw.maxScroll(v)))));
}

pub fn over(v: *const View, p: [2]f32) bool {
    return p[0] >= v.rect.x and p[0] < v.rect.x + v.rect.w and p[1] >= v.rect.y and p[1] < v.rect.y + v.rect.h;
}

/// Over the text itself (not the line numbers, not the bar).
pub fn overText(v: *const View, p: [2]f32) bool {
    const bar_top = if (codedraw.hbar(v)) |b| b.track.y - 2 else v.rect.y + v.rect.h;
    const bar_left = if (codedraw.vbar(v)) |b| b.track.x - 2 else v.rect.x + v.rect.w;
    return over(v, p) and p[0] >= v.rect.x + gutter and p[1] < bar_top and p[0] < bar_left;
}

/// A press with `clicks` (2: the word, 3: the line); Cmd+click goes to what is there;
/// on a bar, its thumb taken (on its track: the thumb jumps there).
pub fn press(app: *App, v: *View, p: [2]f32, clicks: u8, mod: c.SDL_Keymod) void {
    // An open menu takes the click (clay); one off it only closes it.
    if (v.menu != null) return;
    if (codedraw.hbar(v)) |b| if (p[1] >= b.track.y - 3 and p[0] >= b.track.x) {
        v.hbar = if (p[0] >= b.thumb.x and p[0] < b.thumb.x + b.thumb.w) p[0] - b.thumb.x else b.thumb.w / 2;
        return pointer(app, v, p, true);
    };
    if (codedraw.vbar(v)) |b| if (p[0] >= b.track.x - 3 and p[1] < b.track.y + b.track.h) {
        v.vbar = if (p[1] >= b.thumb.y and p[1] < b.thumb.y + b.thumb.h) p[1] - b.thumb.y else b.thumb.h / 2;
        return pointer(app, v, p, true);
    };
    pointer(app, v, p, (mod & c.SDL_KMOD_SHIFT) != 0);
    if (clicks == 2) v.buf.selectWord(v.buf.cursor) else if (clicks >= 3) v.buf.selectLine(v.buf.cursor, false);
    if (clicks == 1 and (mod & (c.SDL_KMOD_GUI | c.SDL_KMOD_CTRL)) != 0) goTo(app, v);
}

/// The text offset under point `p`: its line, the character boundary nearest.
pub fn offsetAt(app: *App, v: *const View, p: [2]f32) usize {
    const t = v.buf.str();
    const row: usize = @intFromFloat(@max(0, (p[1] - v.rect.y - 4) / line_h));
    var ls: usize = 0;
    var n: usize = 0;
    while (n < v.scroll + row and ls < t.len) : (n += 1) {
        const e = code.lineEnd(t, ls);
        if (e >= t.len) break;
        ls = codecomplete.next(t, ls);
    }
    const le = code.lineEnd(t, ls);
    var i = ls;
    const x0 = v.rect.x + gutter - v.hscroll;
    while (i < le) {
        var k = i + 1;
        while (k < le and t[k] & 0xc0 == 0x80) k += 1;
        const mid = x0 + (codedraw.width(app, t[ls..i]) + codedraw.width(app, t[ls..k])) / 2;
        if (p[0] < mid) break;
        i = k;
    }
    return i;
}

/// Pointer at `p` (press: cursor there; drag: select up to there, or a bar's thumb
/// moved). Dragging past the text's edges scrolls it sideways.
pub fn pointer(app: *App, v: *View, p: [2]f32, drag: bool) void {
    if (v.hbar) |grab| {
        const b = codedraw.hbar(v) orelse return;
        const frac = std.math.clamp((p[0] - grab - b.track.x) / @max(1, b.track.w - b.thumb.w), 0, 1);
        v.hscroll = frac * @max(0, v.wide + codedraw.h_margin - codedraw.textW(v));
        return;
    }
    if (v.vbar) |grab| {
        const b = codedraw.vbar(v) orelse return;
        const frac = std.math.clamp((p[1] - grab - b.track.y) / @max(1, b.track.h - b.thumb.h), 0, 1);
        v.scroll = @intFromFloat(@round(frac * @as(f32, @floatFromInt(codedraw.maxScroll(v)))));
        return;
    }
    const i = offsetAt(app, v, p);
    if (drag) {
        if (v.buf.anchor == null) v.buf.anchor = v.buf.cursor;
        v.follow_x = true;
    } else v.buf.anchor = null;
    v.buf.cursor = i;
    v.buf.want_col = null;
    v.buf.typing = false;
    v.popup = false;
}

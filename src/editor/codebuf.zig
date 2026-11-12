//! The code editor's text (code.zig): a UTF-8 buffer with cursor, selection, line
//! moves, auto-indent, call snippets and its own undo.

const std = @import("std");
const Allocator = std.mem.Allocator;
const code = @import("code.zig");
const callscan = @import("callscan.zig");

const class = code.class;
const closerOf = code.closerOf;
const colOf = code.colOf;
const inString = code.inString;
const isIdent = code.isIdent;
const lineEnd = code.lineEnd;
const lineStart = code.lineStart;
const nextChar = code.nextChar;
const nextLine = code.nextLine;
const posAtCol = code.posAtCol;
const prevChar = code.prevChar;
const wordLeftPos = code.wordLeftPos;
const wordRightPos = code.wordRightPos;
const argSpan = callscan.argSpan;
const argsEnd = callscan.argsEnd;
const callAt = callscan.callAt;

pub const Buffer = struct {
    gpa: Allocator,
    text: std.ArrayList(u8) = .empty,
    /// Byte offsets; `anchor` ≠ null: a selection between it and `cursor`.
    cursor: usize = 0,
    anchor: ?usize = null,
    /// Column kept by up/down moves (in characters).
    want_col: ?usize = null,
    undo: std.ArrayList(Snap) = .empty,
    /// Steps undone (Cmd+Shift+Z puts them back); any new change drops them.
    redo: std.ArrayList(Snap) = .empty,
    /// Where the closing brackets and quotes typed with their openers are (innermost
    /// last): typing one there steps over it.
    closers: [16]usize = undefined,
    n_closers: usize = 0,
    /// Typing letters joins one undo step until something else happens.
    typing: bool = false,
    changed: bool = false,
    /// Grows with every change (the code editor checks the text again).
    version: u32 = 0,
    /// Shown, not edited (the engine's own texts, Store.engine_dir).
    read_only: bool = false,

    const Snap = struct { text: []u8, cursor: usize };

    pub fn init(gpa: Allocator, text: []const u8) !Buffer {
        var b: Buffer = .{ .gpa = gpa };
        try b.text.appendSlice(gpa, text);
        return b;
    }

    pub fn deinit(self: *Buffer) void {
        for (self.undo.items) |s| self.gpa.free(s.text);
        self.undo.deinit(self.gpa);
        dropAll(self.gpa, &self.redo);
        self.text.deinit(self.gpa);
    }

    pub fn str(self: *const Buffer) []const u8 {
        return self.text.items;
    }

    fn snap(self: *Buffer, typing: bool) !void {
        // Every change snaps first: a read-only text (the engine's) takes none.
        if (self.read_only) return error.ReadOnly;
        if (typing and self.typing) return;
        self.typing = typing;
        try self.undo.append(self.gpa, .{ .text = try self.gpa.dupe(u8, self.text.items), .cursor = self.cursor });
        dropAll(self.gpa, &self.redo);
        self.version +%= 1;
    }

    fn dropAll(gpa: Allocator, list: *std.ArrayList(Snap)) void {
        for (list.items) |x| gpa.free(x.text);
        list.clearAndFree(gpa);
    }

    pub fn undoLast(self: *Buffer) !void {
        try self.step(&self.undo, &self.redo);
    }

    pub fn redoLast(self: *Buffer) !void {
        try self.step(&self.redo, &self.undo);
    }

    /// The text back to the last snapshot of `from`; the current one kept in `to`.
    fn step(self: *Buffer, from: *std.ArrayList(Snap), to: *std.ArrayList(Snap)) !void {
        const s = from.pop() orelse return;
        defer self.gpa.free(s.text);
        try to.append(self.gpa, .{ .text = try self.gpa.dupe(u8, self.text.items), .cursor = self.cursor });
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.gpa, s.text);
        self.cursor = @min(s.cursor, self.text.items.len);
        self.anchor = null;
        self.n_closers = 0;
        self.typing = false;
        self.changed = true;
        self.version +%= 1;
    }

    pub fn selection(self: *const Buffer) ?[2]usize {
        const a = self.anchor orelse return null;
        if (a == self.cursor) return null;
        return .{ @min(a, self.cursor), @max(a, self.cursor) };
    }

    fn deleteSelection(self: *Buffer) bool {
        const s = self.selection() orelse return false;
        self.text.replaceRangeAssumeCapacity(s[0], s[1] - s[0], &.{});
        self.cursor = s[0];
        self.anchor = null;
        self.n_closers = 0;
        return true;
    }

    /// Types `s` (replacing the selection).
    pub fn insert(self: *Buffer, s: []const u8) !void {
        const word = s.len == 1 and isIdent(s[0]);
        try self.snap(word);
        _ = self.deleteSelection();
        try self.text.insertSlice(self.gpa, self.cursor, s);
        self.shiftClosers(self.cursor, self.cursor, @intCast(s.len));
        self.cursor += s.len;
        self.want_col = null;
        self.changed = true;
        self.version +%= 1;
    }

    /// Enter: the new line keeps the indent, one level more after `{`.
    pub fn newline(self: *Buffer) !void {
        const t = self.text.items;
        const ls = lineStart(t, self.cursor);
        var e = ls;
        while (e < t.len and (t[e] == ' ' or t[e] == '\t')) e += 1;
        var buf: [128]u8 = undefined;
        const indent = t[ls..@min(e, self.cursor)];
        var n = @min(indent.len, buf.len - 3);
        @memcpy(buf[0..n], indent[0..n]);
        const before = std.mem.trimEnd(u8, t[ls..self.cursor], " \t");
        if (before.len > 0 and before[before.len - 1] == '{') {
            @memcpy(buf[n..][0..2], "  ");
            n += 2;
        }
        // The game's scripts end lines with CRLF.
        const crlf = std.mem.indexOf(u8, t, "\r\n") != null;
        var line: [280]u8 = undefined;
        const nl: []const u8 = if (crlf) "\r\n" else "\n";
        @memcpy(line[0..nl.len], nl);
        @memcpy(line[nl.len..][0..n], buf[0..n]);
        var len = nl.len + n;
        // `{|}`: the closer on a line of its own under the opener's indent.
        const between = before.len > 0 and before[before.len - 1] == '{' and self.cursor < t.len and t[self.cursor] == '}';
        if (between) {
            @memcpy(line[len..][0..nl.len], nl);
            @memcpy(line[len + nl.len ..][0..indent.len], indent[0..@min(indent.len, 128)]);
            len += nl.len + indent.len;
        }
        try self.insert(line[0..len]);
        if (between) self.cursor -= nl.len + indent.len;
        self.typing = false;
        self.n_closers = 0;
    }

    pub fn backspace(self: *Buffer) !void {
        try self.snap(false);
        if (self.deleteSelection()) return;
        if (self.cursor == 0) return;
        const t = self.text.items;
        const p = prevChar(t, self.cursor);
        // CRLF goes as one; an opener with the closer typed with it, both.
        const from = if (p > 0 and t[p] == '\n' and t[p - 1] == '\r') p - 1 else p;
        const pair = self.closerAt() == self.cursor and closerOf(t[from]) == t[self.cursor];
        self.cut(from, if (pair) self.cursor + 1 else self.cursor);
    }

    /// Bytes `a..b` removed, the cursor at `a` (after a snapshot).
    fn cut(self: *Buffer, a: usize, b: usize) void {
        self.text.replaceRangeAssumeCapacity(a, b - a, &.{});
        self.shiftClosers(a, b, -@as(isize, @intCast(b - a)));
        self.cursor = a;
        self.anchor = null;
        self.changed = true;
        self.version +%= 1;
    }

    /// Alt+Backspace: the word before the cursor; Cmd+Backspace (`line`): the line up to it.
    pub fn deleteBack(self: *Buffer, line: bool) !void {
        if (self.selection() != null or self.cursor == 0) return self.backspace();
        const t = self.text.items;
        const from = if (line) lineStart(t, self.cursor) else wordLeftPos(t, self.cursor);
        if (from == self.cursor) return self.backspace();
        try self.snap(false);
        self.cut(from, self.cursor);
    }

    /// Alt+Delete: the word after the cursor.
    pub fn deleteWordForward(self: *Buffer) !void {
        if (self.selection() != null) return self.deleteForward();
        const to = wordRightPos(self.text.items, self.cursor);
        if (to == self.cursor) return;
        try self.snap(false);
        self.cut(self.cursor, to);
    }

    /// Typed text: a bracket or quote comes with its closer (or wraps the selection), a
    /// closer typed where its own pair put one steps over it.
    pub fn typeText(self: *Buffer, s: []const u8) !void {
        if (s.len != 1) return self.insert(s);
        const ch = s[0];
        const t = self.text.items;
        if (self.selection() == null) if (self.closerAt()) |p| if (p == self.cursor and p < t.len and t[p] == ch) {
            self.cursor += 1;
            self.n_closers -= 1;
            self.typing = false;
            return;
        };
        const cl = closerOf(ch) orelse return self.insert(s);
        if (self.selection()) |sel| {
            try self.snap(false);
            try self.text.insert(self.gpa, sel[1], cl);
            try self.text.insert(self.gpa, sel[0], ch);
            self.anchor = sel[0] + 1;
            self.cursor = sel[1] + 1;
            self.changed = true;
            self.version +%= 1;
            return;
        }
        const nx: u8 = if (self.cursor < t.len) t[self.cursor] else '\n';
        const quote_ok = ch != '"' or ((self.cursor == 0 or !isIdent(t[self.cursor - 1])) and !inString(t, self.cursor));
        if (isIdent(nx) or nx == '"' or !quote_ok) return self.insert(s);
        try self.insert(&.{ ch, cl });
        self.cursor -= 1;
        // The oldest forgotten when full (stepping over it is only a convenience).
        if (self.n_closers == self.closers.len) {
            std.mem.copyForwards(usize, self.closers[0 .. self.closers.len - 1], self.closers[1..]);
            self.n_closers -= 1;
        }
        self.closers[self.n_closers] = self.cursor;
        self.n_closers += 1;
    }

    fn closerAt(self: *const Buffer) ?usize {
        return if (self.n_closers > 0) self.closers[self.n_closers - 1] else null;
    }

    /// Bytes `a..b` changed by `d` (inserted at `a` = `b`, or removed): closers after
    /// move, ones inside go.
    fn shiftClosers(self: *Buffer, a: usize, b: usize, d: isize) void {
        var k: usize = 0;
        for (self.closers[0..self.n_closers]) |p| {
            if (p >= a and p < b) continue;
            self.closers[k] = if (p >= b) @intCast(@as(isize, @intCast(p)) + d) else p;
            k += 1;
        }
        self.n_closers = k;
    }

    pub fn wordLeft(self: *Buffer, select: bool) void {
        self.moveTo(wordLeftPos(self.text.items, self.cursor), select);
        self.want_col = null;
    }

    pub fn wordRight(self: *Buffer, select: bool) void {
        self.moveTo(wordRightPos(self.text.items, self.cursor), select);
        self.want_col = null;
    }

    /// Cmd+Up/Down: the text's start or end.
    pub fn docEdge(self: *Buffer, to_end: bool, select: bool) void {
        self.moveTo(if (to_end) self.text.items.len else 0, select);
        self.want_col = null;
    }

    /// Double click: the word (or run of spaces or signs) at `i` selected.
    pub fn selectWord(self: *Buffer, i: usize) void {
        const t = self.text.items;
        var a = @min(i, t.len);
        if (a == t.len or t[a] == '\r' or t[a] == '\n') {
            if (a == 0 or t[a - 1] == '\n') return;
            a -= 1;
        }
        const k = class(t[a]);
        var b = a;
        while (a > 0 and class(t[a - 1]) == k) a -= 1;
        while (b < t.len and class(t[b]) == k) b += 1;
        self.anchor = a;
        self.cursor = b;
        self.want_col = null;
        self.typing = false;
    }

    /// Triple click, Cmd+L: line `i` is on selected with its line end (Cmd+L again: the
    /// next one too).
    pub fn selectLine(self: *Buffer, i: usize, extend: bool) void {
        const t = self.text.items;
        const from = if (extend and self.selection() != null) self.selection().?[0] else lineStart(t, i);
        const at = if (extend and self.selection() != null) self.cursor else i;
        self.anchor = from;
        self.cursor = nextLine(t, lineEnd(t, at));
        self.want_col = null;
        self.typing = false;
    }

    /// The lines the selection (or the cursor) touches: start of the first, past the
    /// last one's line end.
    fn lineRange(self: *const Buffer) [2]usize {
        const t = self.text.items;
        const s = self.selection() orelse [2]usize{ self.cursor, self.cursor };
        // A selection ending at a line's start leaves that line out.
        const last = if (s[1] > s[0] and s[1] == lineStart(t, s[1])) s[1] - 1 else s[1];
        return .{ lineStart(t, s[0]), nextLine(t, lineEnd(t, last)) };
    }

    fn eol(self: *const Buffer) []const u8 {
        return if (std.mem.indexOf(u8, self.text.items, "\r\n") != null) "\r\n" else "\n";
    }

    /// Bytes `a..b` replaced by `s` with the selection (or the cursor) kept on the same
    /// text: offsets inside move by `shift`, a selection then covers the new lines whole.
    fn replaceLines(self: *Buffer, a: usize, b: usize, s: []const u8, shift: isize) !void {
        const had = self.selection() != null;
        try self.snap(false);
        self.text.replaceRangeAssumeCapacity(a, b - a, &.{});
        try self.text.insertSlice(self.gpa, a, s);
        const len = self.text.items.len;
        const move = struct {
            fn f(p: usize, d: isize, lo: usize, hi: usize) usize {
                return @intCast(std.math.clamp(@as(isize, @intCast(p)) + d, @as(isize, @intCast(lo)), @as(isize, @intCast(hi))));
            }
        }.f;
        self.cursor = move(self.cursor, shift, 0, len);
        if (had) self.anchor = move(self.anchor.?, shift, 0, len) else self.anchor = null;
        self.n_closers = 0;
        self.want_col = null;
        self.changed = true;
        self.version +%= 1;
    }

    const LineOp = enum { comment, indent, outdent };

    /// Cmd+/ (`//` on the lines, or off when all have it), Tab / Shift+Tab over a
    /// selection (two spaces in or out).
    pub fn lines(self: *Buffer, op: LineOp) !void {
        const t = self.text.items;
        const r = self.lineRange();
        var all = true;
        var it = std.mem.splitScalar(u8, t[r[0]..r[1]], '\n');
        while (it.next()) |ln| {
            const body = std.mem.trim(u8, ln, " \t\r");
            if (body.len > 0 and !std.mem.startsWith(u8, body, "//")) all = false;
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        var ls = r[0];
        var shift: isize = 0;
        const cur_line = lineStart(t, self.cursor);
        while (ls < r[1]) {
            const le = lineEnd(t, ls);
            const nl = nextLine(t, le);
            const ln = t[ls..le];
            var ind: usize = 0;
            while (ind < ln.len and (ln[ind] == ' ' or ln[ind] == '\t')) ind += 1;
            const blank = ind == ln.len;
            const before = out.items.len;
            switch (op) {
                .comment => if (blank) {
                    try out.appendSlice(self.gpa, ln);
                } else if (all) {
                    const rest = ln[ind + 2 ..];
                    try out.appendSlice(self.gpa, ln[0..ind]);
                    try out.appendSlice(self.gpa, if (rest.len > 0 and rest[0] == ' ') rest[1..] else rest);
                } else {
                    try out.appendSlice(self.gpa, ln[0..ind]);
                    try out.appendSlice(self.gpa, "// ");
                    try out.appendSlice(self.gpa, ln[ind..]);
                },
                .indent => {
                    if (!blank) try out.appendSlice(self.gpa, "  ");
                    try out.appendSlice(self.gpa, ln);
                },
                .outdent => {
                    const n: usize = if (ind > 0 and ln[0] == '\t') 1 else @min(ind, 2);
                    try out.appendSlice(self.gpa, ln[n..]);
                },
            }
            if (ls == cur_line) shift = @as(isize, @intCast(out.items.len - before)) - @as(isize, @intCast(ln.len));
            try out.appendSlice(self.gpa, t[le..nl]);
            ls = nl;
            if (nl == le) break;
        }
        if (self.selection()) |_| {
            try self.replaceLines(r[0], r[1], out.items, 0);
            // The lines whole, selected.
            self.anchor = r[0];
            self.cursor = r[0] + out.items.len;
        } else try self.replaceLines(r[0], r[1], out.items, shift);
    }

    /// The lines (as normalised: each with its line end) of `a..b`, the last one's line
    /// end left off when the text ends there without one.
    fn withEol(self: *Buffer, out: *std.ArrayList(u8), a: usize, b: usize) !void {
        try out.appendSlice(self.gpa, self.text.items[a..b]);
        if (b == a or (self.text.items[b - 1] != '\n')) try out.appendSlice(self.gpa, self.eol());
    }

    /// Alt+Up/Down: the lines swapped with the one above or below.
    pub fn moveLines(self: *Buffer, down: bool) !void {
        const t = self.text.items;
        const r = self.lineRange();
        if (if (down) r[1] >= t.len else r[0] == 0) return;
        const o: [2]usize = if (down) .{ r[1], nextLine(t, lineEnd(t, r[1])) } else .{ lineStart(t, r[0] - 1), r[0] };
        const lo = @min(r[0], o[0]);
        const hi = @max(r[1], o[1]);
        const ends_open = hi == t.len and t[hi - 1] != '\n';
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        if (down) {
            try self.withEol(&out, o[0], o[1]);
            try self.withEol(&out, r[0], r[1]);
        } else {
            try self.withEol(&out, r[0], r[1]);
            try self.withEol(&out, o[0], o[1]);
        }
        if (ends_open) out.shrinkRetainingCapacity(out.items.len - self.eol().len);
        var other_len: isize = @intCast(o[1] - o[0]);
        if (o[1] == t.len and t[o[1] - 1] != '\n') other_len += @intCast(self.eol().len);
        try self.replaceLines(lo, hi, out.items, if (down) other_len else -other_len);
    }

    /// Shift+Alt+Down, Cmd+Shift+D: the lines copied under themselves, the cursor on the copy.
    pub fn duplicateLines(self: *Buffer) !void {
        const t = self.text.items;
        const r = self.lineRange();
        const ends_open = r[1] == t.len and (r[1] == r[0] or t[r[1] - 1] != '\n');
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        try self.withEol(&out, r[0], r[1]);
        const one = out.items.len;
        try self.withEol(&out, r[0], r[1]);
        if (ends_open) out.shrinkRetainingCapacity(out.items.len - self.eol().len);
        try self.replaceLines(r[0], r[1], out.items, @intCast(one));
    }

    /// Cmd+Shift+K: the lines gone, the cursor's column kept on the line now there.
    pub fn deleteLines(self: *Buffer) !void {
        const t = self.text.items;
        var r = self.lineRange();
        // The last line has no line end of its own: the one before it goes instead.
        if (r[1] == t.len and r[0] > 0 and (r[1] == r[0] or t[r[1] - 1] != '\n')) {
            r[0] -= 1;
            if (r[0] > 0 and t[r[0] - 1] == '\r') r[0] -= 1;
        }
        const col = colOf(t, self.cursor);
        try self.snap(false);
        self.cut(r[0], r[1]);
        const nt = self.text.items;
        self.cursor = posAtCol(nt, lineStart(nt, r[0]), col);
    }

    /// Cmd+Enter (`above`: Cmd+Shift+Enter): a new line under (over) this one, the cursor there.
    pub fn openLine(self: *Buffer, above: bool) !void {
        const t = self.text.items;
        if (above) {
            const ls = lineStart(t, self.cursor);
            self.moveTo(ls, false);
            var e = ls;
            while (e < t.len and (t[e] == ' ' or t[e] == '\t')) e += 1;
            var buf: [256]u8 = undefined;
            const ind = t[ls..@min(e, ls + 128)];
            const nl = self.eol();
            @memcpy(buf[0..ind.len], ind);
            @memcpy(buf[ind.len..][0..nl.len], nl);
            const k = ind.len;
            try self.insert(buf[0 .. ind.len + nl.len]);
            self.cursor = ls + k;
        } else {
            self.moveTo(lineEnd(t, self.cursor), false);
            try self.newline();
        }
    }

    pub fn deleteForward(self: *Buffer) !void {
        try self.snap(false);
        self.n_closers = 0;
        if (self.deleteSelection()) return;
        if (self.cursor >= self.text.items.len) return;
        var n = nextChar(self.text.items, self.cursor);
        if (self.text.items[self.cursor] == '\r' and n < self.text.items.len and self.text.items[n] == '\n') n += 1;
        self.text.replaceRangeAssumeCapacity(self.cursor, n - self.cursor, &.{});
        self.changed = true;
    }

    fn moveTo(self: *Buffer, pos: usize, select: bool) void {
        if (select) {
            if (self.anchor == null) self.anchor = self.cursor;
        } else self.anchor = null;
        self.cursor = pos;
        self.typing = false;
        self.n_closers = 0;
    }

    pub fn left(self: *Buffer, select: bool) void {
        if (!select) if (self.selection()) |s| return self.moveTo(s[0], false);
        var p = prevChar(self.text.items, self.cursor);
        if (p > 0 and self.text.items[p] == '\n' and self.text.items[p - 1] == '\r') p -= 1;
        self.moveTo(p, select);
        self.want_col = null;
    }

    pub fn right(self: *Buffer, select: bool) void {
        if (!select) if (self.selection()) |s| return self.moveTo(s[1], false);
        var n = nextChar(self.text.items, self.cursor);
        if (self.cursor < self.text.items.len and self.text.items[self.cursor] == '\r' and n < self.text.items.len and self.text.items[n] == '\n') n += 1;
        self.moveTo(n, select);
        self.want_col = null;
    }

    pub fn home(self: *Buffer, select: bool) void {
        const t = self.text.items;
        const ls = lineStart(t, self.cursor);
        var e = ls;
        while (e < t.len and (t[e] == ' ' or t[e] == '\t')) e += 1;
        // First the indent's end, then the line's start.
        self.moveTo(if (self.cursor == e) ls else e, select);
        self.want_col = null;
    }

    pub fn end(self: *Buffer, select: bool) void {
        self.moveTo(lineEnd(self.text.items, self.cursor), select);
        self.want_col = null;
    }

    /// Up (`dl` < 0) or down by lines, keeping the column.
    pub fn vertical(self: *Buffer, dl: i32, select: bool) void {
        const t = self.text.items;
        const col = self.want_col orelse colOf(t, self.cursor);
        var ls = lineStart(t, self.cursor);
        var k = dl;
        while (k < 0) : (k += 1) {
            if (ls == 0) break;
            ls = lineStart(t, ls - 1);
        }
        while (k > 0) : (k -= 1) {
            const e = lineEnd(t, ls);
            if (e >= t.len) break;
            ls = nextLine(t, e);
        }
        self.moveTo(posAtCol(t, ls, col), select);
        self.want_col = col;
    }

    pub fn selectAll(self: *Buffer) void {
        self.anchor = 0;
        self.cursor = self.text.items.len;
    }

    /// The identifier being typed before the cursor (with its path: `fighter::Se`).
    pub fn wordBefore(self: *const Buffer) []const u8 {
        return self.text.items[callscan.nameStart(self.text.items, self.cursor)..self.cursor];
    }

    /// Bytes `a..b` replaced with `s`, the cursor after it (one undo step).
    pub fn replaceSpan(self: *Buffer, a: usize, b: usize, s: []const u8) !void {
        try self.snap(false);
        self.text.replaceRangeAssumeCapacity(a, b - a, &.{});
        try self.text.insertSlice(self.gpa, a, s);
        self.cursor = a + s.len;
        self.anchor = null;
        self.changed = true;
        self.version +%= 1;
    }

    /// Replaces the word before the cursor with `w` (a chosen completion).
    pub fn complete(self: *Buffer, w: []const u8) !void {
        try self.snap(false);
        const n = self.wordBefore().len;
        self.text.replaceRangeAssumeCapacity(self.cursor - n, n, &.{});
        self.cursor -= n;
        try self.text.insertSlice(self.gpa, self.cursor, w);
        self.cursor += w.len;
        self.anchor = null;
        self.changed = true;
    }

    /// Replaces the word before the cursor with call `name(args)` (`;` too at a line's
    /// end) and selects its first argument, to type over.
    pub fn insertCall(self: *Buffer, name: []const u8, args: []const u8) !void {
        try self.complete(name);
        const t = self.text.items;
        const tail = std.mem.trim(u8, t[self.cursor..lineEnd(t, self.cursor)], " \t").len == 0;
        if (self.cursor < t.len and t[self.cursor] == '(') return;
        const open = self.cursor;
        try self.text.insert(self.gpa, self.cursor, '(');
        try self.text.insertSlice(self.gpa, self.cursor + 1, args);
        try self.text.insertSlice(self.gpa, self.cursor + 1 + args.len, if (tail) ");" else ")");
        self.cursor += 1;
        if (!self.selectArg(open, 0)) self.cursor = open + 2 + args.len;
    }

    /// Selects argument `k` of the call whose `(` is at `open`; false if it has none.
    fn selectArg(self: *Buffer, open: usize, k: usize) bool {
        const s = argSpan(self.text.items, open, k) orelse return false;
        self.anchor = s[0];
        self.cursor = s[1];
        self.typing = false;
        return true;
    }

    /// Tab inside a call's arguments: selects the next one, or goes past `)` (and
    /// its `;`) after the last. False outside a call.
    pub fn nextArg(self: *Buffer) bool {
        const t = self.text.items;
        const from = if (self.selection()) |s| s[0] else self.cursor;
        const cp = callAt(t, from) orelse return false;
        if (self.selectArg(cp.open, cp.arg + 1)) return true;
        const close = argsEnd(t, cp.open) orelse return false;
        self.anchor = null;
        self.cursor = close + 1;
        if (self.cursor < t.len and t[self.cursor] == ';') self.cursor += 1;
        return true;
    }
};

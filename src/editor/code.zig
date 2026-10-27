//! Script text editing for the code editor: a UTF-8 buffer with cursor, selection,
//! line moves, auto-indent and its own undo; line highlighting; the word before the
//! cursor and completion candidates. The game's bytes (Windows-1251 in the Russian
//! edition) convert to UTF-8 and back without loss.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Game bytes → UTF-8: Cyrillic letters of Windows-1251 (Russian edition) to their
/// letters, every other high byte to U+0080…U+00FF, so `toGame` gives the bytes back.
pub fn fromGame(gpa: Allocator, bytes: []const u8, cyrillic: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (bytes) |b| {
        const cp: u21 = if (b < 0x80) b else if (cyrillic and b >= 0xc0) @as(u21, b) - 0xc0 + 0x410 else if (cyrillic and b == 0xa8) 0x401 else if (cyrillic and b == 0xb8) 0x451 else b;
        var buf: [4]u8 = undefined;
        try out.appendSlice(gpa, buf[0 .. std.unicode.utf8Encode(cp, &buf) catch unreachable]);
    }
    return out.toOwnedSlice(gpa);
}

/// UTF-8 → game bytes; characters the edition can't hold become '?'.
pub fn toGame(gpa: Allocator, text: []const u8, cyrillic: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = (std.unicode.Utf8View.init(text) catch return error.BadText).iterator();
    while (it.nextCodepoint()) |cp| try out.append(gpa, switch (cp) {
        0...0xff => @intCast(cp),
        0x410...0x44f => if (cyrillic) @intCast(cp - 0x410 + 0xc0) else '?',
        0x401 => if (cyrillic) 0xa8 else '?',
        0x451 => if (cyrillic) 0xb8 else '?',
        else => '?',
    });
    return out.toOwnedSlice(gpa);
}

pub fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

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

    /// The identifier being typed before the cursor.
    pub fn wordBefore(self: *const Buffer) []const u8 {
        const t = self.text.items;
        var a = self.cursor;
        while (a > 0 and isIdent(t[a - 1])) a -= 1;
        return t[a..self.cursor];
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

/// A call around a text offset: its name, the offset of its `(` and which argument
/// (from 0) the offset is in.
const CallPos = struct { name: []const u8, open: usize, arg: usize };

/// The innermost call whose arguments hold offset `i` (within the statement).
pub fn callAt(t: []const u8, i: usize) ?CallPos {
    var depth: usize = 0;
    var commas: usize = 0;
    var k = @min(i, t.len);
    while (k > 0) {
        k -= 1;
        switch (t[k]) {
            ')' => depth += 1,
            ',' => if (depth == 0) {
                commas += 1;
            },
            ';', '{', '}' => return null,
            '(' => {
                if (depth > 0) {
                    depth -= 1;
                    continue;
                }
                var a = k;
                while (a > 0 and t[a - 1] == ' ') a -= 1;
                const e = a;
                while (a > 0 and isIdent(t[a - 1])) a -= 1;
                const name = t[a..e];
                if (name.len == 0 or std.mem.eql(u8, name, "if") or std.mem.eql(u8, name, "while")) return null;
                return .{ .name = name, .open = k, .arg = commas };
            },
            else => {},
        }
    }
    return null;
}

/// Offset of the `)` closing the call opened at `open`.
fn argsEnd(t: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var k = open + 1;
    while (k < t.len) : (k += 1) switch (t[k]) {
        '"' => k = std.mem.indexOfScalarPos(u8, t, k + 1, '"') orelse return null,
        '(' => depth += 1,
        ')' => {
            if (depth == 0) return k;
            depth -= 1;
        },
        ';', '{', '}' => return null,
        else => {},
    };
    return null;
}

/// Start and end (spaces trimmed) of argument `n` of the call opened at `open`.
fn argSpan(t: []const u8, open: usize, n: usize) ?[2]usize {
    const close = argsEnd(t, open) orelse return null;
    var depth: usize = 0;
    var start = open + 1;
    var idx: usize = 0;
    var k = open + 1;
    while (k <= close) : (k += 1) {
        const ch = t[k];
        if (ch == '"') {
            k = std.mem.indexOfScalarPos(u8, t, k + 1, '"') orelse return null;
            continue;
        }
        if (ch == '(') depth += 1;
        if (ch == ')' and k < close) depth -= 1;
        if ((ch == ',' and depth == 0) or k == close) {
            if (idx == n) {
                var a = start;
                var e = k;
                while (a < e and t[a] == ' ') a += 1;
                while (e > a and t[e - 1] == ' ') e -= 1;
                if (a == e and k == close and n == 0) return null;
                return .{ a, e };
            }
            idx += 1;
            start = k + 1;
        }
    }
    return null;
}

/// A string argument the cursor is in: its call and where the string's text starts
/// (after the opening `"`), the call need not be closed yet.
pub const StringArg = struct { call: CallPos, start: usize };

pub fn stringArgAt(t: []const u8, i: usize) ?StringArg {
    const cp = callAt(t, i) orelse return null;
    var quotes: usize = 0;
    var last: usize = 0;
    var k = cp.open + 1;
    while (k < i) : (k += 1) if (t[k] == '"') {
        quotes += 1;
        last = k;
    };
    if (quotes % 2 == 0) return null;
    return .{ .call = cp, .start = last + 1 };
}

/// `text` re-indented by its braces (`indent` a level) with trailing spaces gone;
/// line endings, blank lines and the lines of `/* */` comments kept. Braces in
/// strings and comments don't count; a line starting with `}` steps back first.
pub fn format(gpa: Allocator, text: []const u8, indent: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var depth: usize = 0;
    var in_block = false;
    var i: usize = 0;
    while (i < text.len) {
        var e = i;
        while (e < text.len and text[e] != '\n') e += 1;
        const nl_end = if (e < text.len) e + 1 else e;
        const raw = text[i..e];
        const cr = raw.len > 0 and raw[raw.len - 1] == '\r';
        const line = raw[0 .. raw.len - @intFromBool(cr)];
        const body = std.mem.trim(u8, line, " \t");
        if (in_block) {
            try out.appendSlice(gpa, std.mem.trimEnd(u8, line, " \t"));
        } else if (body.len > 0) {
            const lead = body[0] == '}';
            for (0..(if (lead) depth -| 1 else depth)) |_| try out.appendSlice(gpa, indent);
            try out.appendSlice(gpa, body);
        }
        // Braces of the line (outside strings and comments) set the next lines' depth.
        var k: usize = 0;
        var str = false;
        while (k < line.len) : (k += 1) {
            const ch = line[k];
            if (in_block) {
                if (ch == '*' and k + 1 < line.len and line[k + 1] == '/') {
                    in_block = false;
                    k += 1;
                }
            } else if (str) {
                if (ch == '"') str = false;
            } else switch (ch) {
                '"' => str = true,
                '/' => if (k + 1 < line.len and line[k + 1] == '/') break else if (k + 1 < line.len and line[k + 1] == '*') {
                    in_block = true;
                    k += 1;
                },
                '{' => depth += 1,
                '}' => depth -|= 1,
                else => {},
            }
        }
        if (cr) try out.append(gpa, '\r');
        if (nl_end > e) try out.append(gpa, '\n');
        i = nl_end;
    }
    return out.toOwnedSlice(gpa);
}

/// An open code editor (codeview.zig).
pub const View = struct {
    buf: Buffer,
    /// Store index of the file and its name.
    file: usize,
    title: []u8,
    /// First line shown.
    scroll: usize = 0,
    /// Completion list open and its selected line.
    popup: bool = false,
    popup_sel: usize = 0,
    /// The list holds tasks (Ctrl+Space on an empty spot), not words.
    tasks: bool = false,
    /// The functions' help column shown (F1).
    help: bool = false,
    /// Where the text was drawn last (pointer → cursor): x, y, w, h.
    rect: struct { x: f32, y: f32, w: f32, h: f32 } = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    dragging: bool = false,
    /// Syntax check of the text at `checked` (buffer version): the error's line (1-based,
    /// 0 — none) and message; `force` — Apply pressed once despite it.
    checked: ?u32 = null,
    err_line: u32 = 0,
    err_buf: [160]u8 = undefined,
    err_len: usize = 0,
    force: bool = false,
    /// Calls (scene commands in a `.scr`) that nothing registers: line and name, the
    /// first `unknown.len` (warnings, they do not hold Apply back).
    unknown: [16]struct { line: u32, name: [48]u8, len: u8 } = undefined,
    unknown_n: usize = 0,
    /// The find field (Cmd+F) shown and its text; its matches are marked.
    find_open: bool = false,
    find_buf: [64]u8 = undefined,
    find_len: usize = 0,

    pub fn err(self: *const View) []const u8 {
        return self.err_buf[0..self.err_len];
    }

    pub fn findText(self: *const View) []const u8 {
        return self.find_buf[0..self.find_len];
    }

    pub fn setFind(self: *View, q: []const u8) void {
        self.find_len = @min(q.len, self.find_buf.len);
        @memcpy(self.find_buf[0..self.find_len], q[0..self.find_len]);
    }

    pub fn destroy(self: *View, gpa: Allocator) void {
        self.buf.deinit();
        gpa.free(self.title);
        gpa.destroy(self);
    }
};

pub fn lineStart(t: []const u8, i: usize) usize {
    var a = @min(i, t.len);
    while (a > 0 and t[a - 1] != '\n') a -= 1;
    return a;
}

/// Offset of the line's end (before CR LF).
pub fn lineEnd(t: []const u8, i: usize) usize {
    var e = @min(i, t.len);
    while (e < t.len and t[e] != '\n' and t[e] != '\r') e += 1;
    return e;
}

fn nextLine(t: []const u8, e: usize) usize {
    var n = e;
    if (n < t.len and t[n] == '\r') n += 1;
    if (n < t.len and t[n] == '\n') n += 1;
    return n;
}

fn prevChar(t: []const u8, i: usize) usize {
    var p = i -| 1;
    while (p > 0 and t[p] & 0xc0 == 0x80) p -= 1;
    return p;
}

fn nextChar(t: []const u8, i: usize) usize {
    var n = @min(i + 1, t.len);
    while (n < t.len and t[n] & 0xc0 == 0x80) n += 1;
    return n;
}

fn colOf(t: []const u8, i: usize) usize {
    var n: usize = 0;
    for (t[lineStart(t, i)..i]) |ch| n += @intFromBool(ch & 0xc0 != 0x80);
    return n;
}

/// Offset of column `col` (characters) on the line starting at `ls`, or its end.
fn posAtCol(t: []const u8, ls: usize, col: usize) usize {
    const e = lineEnd(t, ls);
    var i = ls;
    var n: usize = 0;
    while (i < e and n < col) : (n += 1) i = nextChar(t, i);
    return i;
}

/// What a character is for word moves: spaces, a word (letters, digits, `_`, any
/// non-ASCII), signs, a line end.
fn class(ch: u8) u2 {
    if (ch == ' ' or ch == '\t') return 0;
    if (ch == '\n' or ch == '\r') return 3;
    if (isIdent(ch) or ch >= 0x80) return 1;
    return 2;
}

/// Alt+Left: past the spaces, then the word (or the signs) before `i`; at a line's start,
/// to the line before's end.
fn wordLeftPos(t: []const u8, i: usize) usize {
    var p = i;
    while (p > 0 and class(t[p - 1]) == 0) p -= 1;
    if (p == 0) return 0;
    const k = class(t[p - 1]);
    if (k == 3) return if (p == i) lineEnd(t, lineStart(t, p - 1)) else p;
    while (p > 0 and class(t[p - 1]) == k) p -= 1;
    return p;
}

fn wordRightPos(t: []const u8, i: usize) usize {
    var p = i;
    while (p < t.len and class(t[p]) == 0) p += 1;
    if (p == t.len) return p;
    const k = class(t[p]);
    if (k == 3) return if (p == i) nextLine(t, p) else p;
    while (p < t.len and class(t[p]) == k) p += 1;
    return p;
}

fn closerOf(ch: u8) ?u8 {
    return switch (ch) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '"' => '"',
        else => null,
    };
}

/// Offset `i` is inside a string on its line (an odd number of quotes before it).
fn inString(t: []const u8, i: usize) bool {
    var n: usize = 0;
    var k = lineStart(t, i);
    while (k < i) : (k += 1) {
        if (t[k] == '\\') k += 1 else n += @intFromBool(t[k] == '"');
    }
    return n % 2 == 1;
}

/// Highlight kinds.
pub const Kind = enum { plain, keyword, call, string, number, comment, directive };

pub const Span = struct { kind: Kind, start: usize, end: usize };

const keywords = [_][]const u8{ "function", "if", "else", "while", "for", "return", "int", "float", "string", "break", "continue" };

/// Highlight spans of `line` (no newline).
pub fn highlight(a: Allocator, line: []const u8) ![]Span {
    var out: std.ArrayList(Span) = .empty;
    var i: usize = 0;
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (std.mem.startsWith(u8, trimmed, "#")) {
        try out.append(a, .{ .kind = .directive, .start = 0, .end = line.len });
        return out.items;
    }
    while (i < line.len) {
        const ch = line[i];
        const s = i;
        var kind: Kind = .plain;
        if (ch == '/' and i + 1 < line.len and line[i + 1] == '/') {
            i = line.len;
            kind = .comment;
        } else if (ch == '"') {
            i = if (std.mem.indexOfScalarPos(u8, line, i + 1, '"')) |e| e + 1 else line.len;
            kind = .string;
        } else if (std.ascii.isDigit(ch) or (ch == '-' and i + 1 < line.len and std.ascii.isDigit(line[i + 1]) and (i == 0 or !isIdent(line[i - 1])))) {
            i += 1;
            while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == '.')) i += 1;
            kind = .number;
        } else if (isIdent(ch)) {
            while (i < line.len and isIdent(line[i])) i += 1;
            const w = line[s..i];
            var k = i;
            while (k < line.len and line[k] == ' ') k += 1;
            kind = for (keywords) |kw| {
                if (std.mem.eql(u8, w, kw)) break .keyword;
            } else if ((k < line.len and line[k] == '(') or (s == line.len - trimmed.len and isCommand(w))) .call else .plain;
        } else {
            i = nextChar(line, i);
        }
        if (out.items.len > 0 and out.items[out.items.len - 1].kind == kind and out.items[out.items.len - 1].end == s) {
            out.items[out.items.len - 1].end = i;
        } else try out.append(a, .{ .kind = kind, .start = s, .end = i });
    }
    return out.items;
}

/// A scene command without arguments (`FADE_OUT`): an all-caps word.
fn isCommand(w: []const u8) bool {
    if (w.len < 2) return false;
    for (w) |ch| if (!std.ascii.isUpper(ch) and ch != '_' and !std.ascii.isDigit(ch)) return false;
    return true;
}

test "scene command without arguments is a call" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const spans = try highlight(arena.allocator(), "  FADE_OUT");
    try std.testing.expectEqual(Kind.call, spans[spans.len - 1].kind);
}

/// Candidates for `prefix` (case-insensitive): starting with it first, then containing it.
pub fn matches(a: Allocator, prefix: []const u8, words: []const []const u8, max: usize) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (prefix.len == 0) return out.items;
    for ([_]bool{ true, false }) |starts| for (words) |w| {
        if (out.items.len == max) return out.items;
        if (w.len <= prefix.len and std.ascii.eqlIgnoreCase(w, prefix)) continue;
        const hit = if (starts) std.ascii.startsWithIgnoreCase(w, prefix) else !std.ascii.startsWithIgnoreCase(w, prefix) and std.ascii.findIgnoreCase(w, prefix) != null;
        if (!hit) continue;
        for (out.items) |o| {
            if (std.mem.eql(u8, o, w)) break;
        } else try out.append(a, w);
    };
    return out.items;
}

/// Identifiers of `text` (for completion with the file's own names).
pub fn identifiers(a: Allocator, text: []const u8) ![]const []const u8 {
    var set: std.StringArrayHashMapUnmanaged(void) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (isIdent(text[i]) and !std.ascii.isDigit(text[i])) {
            const s = i;
            while (i < text.len and isIdent(text[i])) i += 1;
            if (i - s >= 3) try set.put(a, text[s..i], {});
        } else i += 1;
    }
    return set.keys();
}

test "code: encoding round trip" {
    const gpa = std.testing.allocator;
    const bytes = "x = \"\xcf\xf0\xe8\xe2\xe5\xf2\xa8\x96\xff\";\r\n";
    const u = try fromGame(gpa, bytes, true);
    defer gpa.free(u);
    try std.testing.expect(std.mem.indexOf(u8, u, "Привет") != null);
    const back = try toGame(gpa, u, true);
    defer gpa.free(back);
    try std.testing.expectEqualSlices(u8, bytes, back);
}

test "code: typing, CRLF, indent, moves, undo" {
    const gpa = std.testing.allocator;
    var b = try Buffer.init(gpa, "function init()\r\n{\r\n  x = 1;\r\n};\r\n");
    defer b.deinit();
    b.cursor = 18; // after "{"
    try b.newline();
    try std.testing.expectEqualStrings("function init()\r\n{\r\n  \r\n  x = 1;\r\n};\r\n", b.str());
    try b.insert("H");
    try b.insert("P");
    try std.testing.expectEqualStrings("  HP", b.str()[20..24]);
    try b.complete("HERO_EnableEnumerate");
    try std.testing.expect(std.mem.indexOf(u8, b.str(), "  HERO_EnableEnumerate\r\n") != null);
    try b.undoLast();
    try std.testing.expect(std.mem.indexOf(u8, b.str(), "  HP\r\n") != null);
    b.vertical(1, false);
    try std.testing.expectEqual(@as(u8, 'x'), b.str()[b.cursor - 2]);
    b.end(false);
    try b.backspace();
    try std.testing.expect(std.mem.indexOf(u8, b.str(), "x = 1\r\n") != null);
    b.cursor = lineStart(b.str(), b.cursor);
    try b.backspace(); // joins the line with the previous one, CRLF as one
    try std.testing.expect(std.mem.indexOf(u8, b.str(), "  HP  x = 1") != null);
}

test "code: brackets, words, redo" {
    const gpa = std.testing.allocator;
    var b = try Buffer.init(gpa, "");
    defer b.deinit();
    for ("Say(") |ch| try b.typeText(&.{ch});
    try std.testing.expectEqualStrings("Say()", b.str());
    try b.typeText("\"");
    try b.typeText("a");
    try b.typeText("\""); // steps over the closing quote
    try b.typeText(")"); // and over the bracket
    try std.testing.expectEqualStrings("Say(\"a\")", b.str());
    try std.testing.expectEqual(@as(usize, 8), b.cursor);
    b.cursor = 4;
    try b.typeText("(");
    try b.backspace(); // the pair goes together
    try std.testing.expectEqualStrings("Say(\"a\")", b.str());
    b.selectWord(1);
    try std.testing.expectEqualStrings("Say", b.str()[b.selection().?[0]..b.selection().?[1]]);
    try b.typeText("["); // wraps the selection
    try std.testing.expectEqualStrings("[Say](\"a\")", b.str());
    try b.undoLast();
    try std.testing.expectEqualStrings("Say(\"a\")", b.str());
    try b.redoLast();
    try std.testing.expectEqualStrings("[Say](\"a\")", b.str());
    b.cursor = b.str().len;
    b.wordLeft(false);
    try std.testing.expectEqual(@as(usize, 8), b.cursor); // before `")`
    try b.deleteBack(false);
    try std.testing.expectEqualStrings("[Say](\"\")", b.str());
}

test "code: line operations" {
    const gpa = std.testing.allocator;
    var b = try Buffer.init(gpa, "a();\r\n  b();\r\nc();");
    defer b.deinit();
    b.cursor = 8; // in b();
    try b.lines(.comment);
    try std.testing.expectEqualStrings("a();\r\n  // b();\r\nc();", b.str());
    try std.testing.expectEqual(@as(usize, 11), b.cursor);
    try b.lines(.comment);
    try std.testing.expectEqualStrings("a();\r\n  b();\r\nc();", b.str());
    try b.moveLines(false);
    try std.testing.expectEqualStrings("  b();\r\na();\r\nc();", b.str());
    try std.testing.expectEqual(@as(usize, 2), b.cursor);
    try b.moveLines(true);
    try b.moveLines(true); // to the end: the last line keeps no line end
    try std.testing.expectEqualStrings("a();\r\nc();\r\n  b();", b.str());
    try b.duplicateLines();
    try std.testing.expectEqualStrings("a();\r\nc();\r\n  b();\r\n  b();", b.str());
    try b.deleteLines();
    try b.deleteLines();
    try std.testing.expectEqualStrings("a();\r\nc();", b.str());
    b.selectAll();
    try b.lines(.indent);
    try std.testing.expectEqualStrings("  a();\r\n  c();", b.str());
    try b.lines(.outdent);
    try std.testing.expectEqualStrings("a();\r\nc();", b.str());
    b.selectLine(0, false);
    try std.testing.expectEqualStrings("a();\r\n", b.str()[b.selection().?[0]..b.selection().?[1]]);
}

test "code: call snippets and argument moves" {
    const gpa = std.testing.allocator;
    var b = try Buffer.init(gpa, "  Plac\r\n");
    defer b.deinit();
    b.cursor = 6;
    try b.insertCall("PlaceActor", "\"Sullivan\", 1, 4");
    try std.testing.expectEqualStrings("  PlaceActor(\"Sullivan\", 1, 4);\r\n", b.str());
    try std.testing.expectEqualStrings("\"Sullivan\"", b.str()[b.selection().?[0]..b.selection().?[1]]);
    const cp = callAt(b.str(), b.cursor).?;
    try std.testing.expectEqualStrings("PlaceActor", cp.name);
    try std.testing.expect(b.nextArg());
    try std.testing.expectEqualStrings("1", b.str()[b.selection().?[0]..b.selection().?[1]]);
    try std.testing.expectEqual(1, callAt(b.str(), b.cursor).?.arg);
    try std.testing.expect(b.nextArg());
    try std.testing.expect(b.nextArg());
    try std.testing.expectEqual(b.str().len - 2, b.cursor); // past `);`
    try std.testing.expect(!b.nextArg());
    try std.testing.expect(callAt("if(AIFreeTile(3, 9", 18).?.arg == 1);
    try std.testing.expect(callAt("if(x", 4) == null);
}

test "code: highlight and completion" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sp = try highlight(a, "  if (x) StartScriptlet(\"a\", 12); // go");
    try std.testing.expectEqual(Kind.keyword, sp[1].kind);
    var kinds: [32]Kind = undefined;
    for (sp, 0..) |s, i| kinds[i] = s.kind;
    try std.testing.expect(std.mem.indexOfScalar(Kind, kinds[0..sp.len], .call) != null);
    try std.testing.expectEqual(Kind.comment, sp[sp.len - 1].kind);
    const m = try matches(a, "start", &.{ "PlaceActor", "StartScriptlet", "SetAddonScriptlet", "MyStart" }, 8);
    try std.testing.expectEqualStrings("StartScriptlet", m[0]);
    try std.testing.expectEqualStrings("MyStart", m[1]);
}

test stringArgAt {
    const t = "  PlaceActor(\"Sul";
    const sa = stringArgAt(t, t.len).?;
    try std.testing.expectEqualStrings("PlaceActor", sa.call.name);
    try std.testing.expectEqual(0, sa.call.arg);
    try std.testing.expectEqualStrings("Sul", t[sa.start..]);
    const u = "PlaceActor(\"Sullivan\", \"capt";
    try std.testing.expectEqual(1, stringArgAt(u, u.len).?.call.arg);
    try std.testing.expect(stringArgAt("PlaceActor(\"Sullivan\", ", 23) == null);
}

test format {
    const gpa = std.testing.allocator;
    const src = "function init()\r\n{\r\n if(a){\r\n\tb = \"{\"; // }\r\n   }   \r\n\r\n/* {\r\n   kept */\r\n};\r\n";
    const out = try format(gpa, src, "  ");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("function init()\r\n{\r\n  if(a){\r\n    b = \"{\"; // }\r\n  }\r\n\r\n  /* {\r\n   kept */\r\n};\r\n", out);
}

//! Placement calls in a level script (`.lev`): PlaceActor(name, x, y[, dir]),
//! AIEnemyAppear(name, x0, y0, x1, y1), PlaceCombatActor(name, x, y, angle).
//! Edits change the call text in place, so the rest of the script (comments,
//! formatting, CRLF) stays byte for byte.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Func = enum { place_actor, enemy_appear, place_combat };

pub const Span = struct { start: usize, end: usize };

pub const Call = struct {
    func: Func,
    name: []const u8,
    /// Numeric arguments after the name.
    args: [4]Span = undefined,
    n_args: usize = 0,
    /// The statement, `Name(` to `;` inclusive.
    stmt: Span,
    /// Inside `function restore()` and not nested in a condition (depth 1).
    in_restore: bool,
    /// Inside `function CombatEnemiesAppear()` (any depth): reinforcements the game
    /// runs at the end of each enemy turn.
    in_appear: bool = false,
    /// Reinforcement: the `if(AIFreeTile(x, y))` chain guarding its block, the x and y
    /// of each (the battles check the tiles it stops on).
    guards: [9][2]Span = undefined,
    n_guards: usize = 0,

    pub fn arg(self: Call, text: []const u8, i: usize) ?f32 {
        if (i >= self.n_args) return null;
        return std.fmt.parseFloat(f32, text[self.args[i].start..self.args[i].end]) catch null;
    }
};

pub const Script = struct {
    calls: []Call,
    /// Offset of restore()'s closing brace.
    restore_close: ?usize,

    pub fn deinit(self: *Script, gpa: Allocator) void {
        gpa.free(self.calls);
    }
};

const names = [_]struct { s: []const u8, f: Func }{
    .{ .s = "PlaceActor", .f = .place_actor },
    .{ .s = "AIEnemyAppear", .f = .enemy_appear },
    .{ .s = "PlaceCombatActor", .f = .place_combat },
};

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn skipSpace(text: []const u8, i: usize) usize {
    var k = i;
    while (k < text.len and std.ascii.isWhitespace(text[k])) k += 1;
    return k;
}

/// Calls whose arguments are a string then numeric literals; other forms
/// (`PlaceActor(name, "area", 0)`, expressions) are skipped.
pub fn scan(gpa: Allocator, text: []const u8) !Script {
    var calls: std.ArrayList(Call) = .empty;
    errdefer calls.deinit(gpa);
    var restore_close: ?usize = null;
    var depth: usize = 0;
    var pending: ?[]const u8 = null;
    var current: ?[]const u8 = null;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '/' and i + 1 < text.len and text[i + 1] == '/') {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        } else if (ch == '/' and i + 1 < text.len and text[i + 1] == '*') {
            i = if (std.mem.indexOfPos(u8, text, i + 2, "*/")) |e| e + 2 else text.len;
        } else if (ch == '"') {
            i = if (std.mem.indexOfScalarPos(u8, text, i + 1, '"')) |e| e + 1 else text.len;
        } else if (ch == '{') {
            if (depth == 0) current = pending;
            depth += 1;
            i += 1;
        } else if (ch == '}') {
            if (depth > 0) depth -= 1;
            if (depth == 0) {
                if (current) |f| if (std.ascii.eqlIgnoreCase(f, "restore")) {
                    restore_close = i;
                };
                current = null;
            }
            i += 1;
        } else if (isIdent(ch) and (i == 0 or !isIdent(text[i - 1]))) {
            var e = i;
            while (e < text.len and isIdent(text[e])) e += 1;
            const word = text[i..e];
            if (std.mem.eql(u8, word, "function")) {
                const s = skipSpace(text, e);
                var k = s;
                while (k < text.len and isIdent(text[k])) k += 1;
                pending = text[s..k];
                i = k;
                continue;
            }
            for (names) |n| if (std.mem.eql(u8, word, n.s)) {
                if (parseCall(text, i, e, n.f)) |call_| {
                    var call = call_;
                    call.in_restore = depth == 1 and current != null and std.ascii.eqlIgnoreCase(current.?, "restore");
                    call.in_appear = current != null and std.ascii.eqlIgnoreCase(current.?, "CombatEnemiesAppear");
                    if (call.in_appear and call.func == .enemy_appear) guardsOf(text, &call);
                    try calls.append(gpa, call);
                }
            };
            i = e;
        } else i += 1;
    }
    return .{ .calls = try calls.toOwnedSlice(gpa), .restore_close = restore_close };
}

/// The `AIFreeTile(x, y)` calls between the statement before the block holding
/// `call` and that block's `{`.
fn guardsOf(text: []const u8, call: *Call) void {
    var depth: usize = 0;
    var open = call.stmt.start;
    while (open > 0) : (open -= 1) {
        const ch = text[open - 1];
        if (ch == '}') depth += 1;
        if (ch == '{') {
            if (depth == 0) break;
            depth -= 1;
        }
    } else return;
    open -= 1;
    var from = open;
    while (from > 0 and text[from - 1] != ';' and text[from - 1] != '{' and text[from - 1] != '}') from -= 1;
    var k = from;
    while (std.mem.indexOfPos(u8, text[0..open], k, "AIFreeTile")) |at| {
        k = at + "AIFreeTile".len;
        if (call.n_guards == call.guards.len) return;
        var g: [2]Span = undefined;
        for (&g, 0..) |*sp, n| {
            k = skipSpace(text, k);
            if (k >= open or text[k] != (if (n == 0) @as(u8, '(') else ',')) return;
            k = skipSpace(text, k + 1);
            const a = k;
            if (k < open and text[k] == '-') k += 1;
            while (k < open and std.ascii.isDigit(text[k])) k += 1;
            if (k == a) return;
            sp.* = .{ .start = a, .end = k };
        }
        call.guards[call.n_guards] = g;
        call.n_guards += 1;
    }
}

fn parseCall(text: []const u8, start: usize, name_end: usize, f: Func) ?Call {
    var k = skipSpace(text, name_end);
    if (k >= text.len or text[k] != '(') return null;
    k = skipSpace(text, k + 1);
    if (k >= text.len or text[k] != '"') return null;
    const q = std.mem.indexOfScalarPos(u8, text, k + 1, '"') orelse return null;
    var call: Call = .{ .func = f, .name = text[k + 1 .. q], .stmt = undefined, .in_restore = false };
    k = q + 1;
    while (true) {
        k = skipSpace(text, k);
        if (k >= text.len) return null;
        if (text[k] == ')') break;
        if (text[k] != ',' or call.n_args == call.args.len) return null;
        k = skipSpace(text, k + 1);
        const a = k;
        if (k < text.len and (text[k] == '-' or text[k] == '+')) k += 1;
        while (k < text.len and (std.ascii.isDigit(text[k]) or text[k] == '.')) k += 1;
        if (k == a or std.fmt.parseFloat(f32, text[a..k]) == error.InvalidCharacter) return null;
        call.args[call.n_args] = .{ .start = a, .end = k };
        call.n_args += 1;
    }
    const semi = skipSpace(text, k + 1);
    const end = if (semi < text.len and text[semi] == ';') semi + 1 else k + 1;
    call.stmt = .{ .start = start, .end = end };
    const want: usize = switch (f) {
        .place_actor => 2,
        .enemy_appear => 4,
        .place_combat => 3,
    };
    return if (call.n_args >= want) call else null;
}

/// `text` without its `//` and `/* */` comments (a name only in a comment is no use).
pub fn uncommented(a: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '"') {
            const e = if (std.mem.indexOfScalarPos(u8, text, i + 1, '"')) |k| k + 1 else text.len;
            try out.appendSlice(a, text[i..e]);
            i = e;
        } else if (std.mem.startsWith(u8, text[i..], "//")) {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        } else if (std.mem.startsWith(u8, text[i..], "/*")) {
            i = if (std.mem.indexOfPos(u8, text, i + 2, "*/")) |k| k + 2 else text.len;
        } else {
            try out.append(a, text[i]);
            i += 1;
        }
    }
    return out.items;
}

test "uncommented: strings kept, comments gone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = try uncommented(arena.allocator(), "a(\"x//y\"); // PlaceActor(\"s\")\n/* \"t\" */b;");
    try std.testing.expectEqualStrings("a(\"x//y\"); \nb;", t);
}

/// One text replacement.
pub const Edit = struct {
    span: Span,
    text: []const u8,
};

/// `text` with `edits` applied (spans of the original text, not overlapping).
pub fn apply(gpa: Allocator, text: []const u8, edits: []Edit) ![]u8 {
    std.mem.sort(Edit, edits, {}, struct {
        fn lt(_: void, a: Edit, b: Edit) bool {
            return a.span.start < b.span.start;
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var at: usize = 0;
    for (edits) |e| {
        try out.appendSlice(gpa, text[at..e.span.start]);
        try out.appendSlice(gpa, e.text);
        at = e.span.end;
    }
    try out.appendSlice(gpa, text[at..]);
    return out.toOwnedSlice(gpa);
}

/// Span removing statement `s` with its line when nothing else is on it.
pub fn lineOf(text: []const u8, s: Span) Span {
    var a = s.start;
    while (a > 0 and (text[a - 1] == ' ' or text[a - 1] == '\t')) a -= 1;
    var b = s.end;
    while (b < text.len and (text[b] == ' ' or text[b] == '\t')) b += 1;
    const own_line = (a == 0 or text[a - 1] == '\n') and (b == text.len or text[b] == '\r' or text[b] == '\n');
    if (!own_line) return s;
    if (b < text.len and text[b] == '\r') b += 1;
    if (b < text.len and text[b] == '\n') b += 1;
    return .{ .start = a, .end = b };
}

/// Line ending used by the script.
pub fn newline(text: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, text, "\r\n") != null) "\r\n" else "\n";
}

/// Offset of the start of the line holding restore()'s closing brace (new calls go there).
pub fn insertPoint(text: []const u8, restore_close: usize) usize {
    var a = restore_close;
    while (a > 0 and text[a - 1] != '\n') a -= 1;
    return a;
}

const sample =
    "#inherit CombatLevel\r\n" ++
    "function restore()\r\n" ++
    "{\r\n" ++
    "    PlaceActor(\"Sullivan\",4,3);\r\n" ++
    "    //PlaceActor(\"01h_sfinks\",1,6,5);\r\n" ++
    "    AIEnemyAppear(\"01h_sfinks\", 2, 10, 2, 6);\r\n" ++
    "    PlaceActor(\"01h_sfinks2\",10,9,5);\r\n" ++
    "    PlaceCombatActor(\"01h_pipe1\", 5.5, 7.0, -15);\r\n" ++
    "    if (x) { PlaceActor(\"late\",1,1); }\r\n" ++
    "    PlaceActor(\"Sullivan\", \"start\", 0);\r\n" ++
    "};\r\n" ++
    "function update()\r\n" ++
    "{\r\n" ++
    "    PlaceActor(\"wave\",3,3);\r\n" ++
    "};\r\n" ++
    "function CombatEnemiesAppear()\r\n" ++
    "{\r\n" ++
    "    if (killedEnemies >= 1) { AIEnemyAppear(\"late\", 3, 11, 3, 9); };\r\n" ++
    "    else\r\n" ++
    "    if(AIFreeTile(4,9))\r\n" ++
    "    if(AIFreeTile( 5, 10))\r\n" ++
    "    {\r\n" ++
    "        EnableObject(\"late\");\r\n" ++
    "        AIEnemyAppear(\"late\", 4, 11, 4, 9);\r\n" ++
    "    };\r\n" ++
    "};\r\n";

test "scan: calls, comments, restore depth" {
    const gpa = std.testing.allocator;
    var s = try scan(gpa, sample);
    defer s.deinit(gpa);
    try std.testing.expectEqual(8, s.calls.len);
    try std.testing.expect(s.calls[6].in_appear and !s.calls[5].in_appear);
    try std.testing.expectEqual(0, s.calls[6].n_guards);
    try std.testing.expectEqual(2, s.calls[7].n_guards);
    try std.testing.expectEqualStrings("10", sample[s.calls[7].guards[1][1].start..s.calls[7].guards[1][1].end]);
    try std.testing.expectEqualStrings("Sullivan", s.calls[0].name);
    try std.testing.expectEqual(Func.enemy_appear, s.calls[1].func);
    try std.testing.expectEqual(10, s.calls[1].arg(sample, 1).?);
    try std.testing.expectEqual(-15, s.calls[3].arg(sample, 2).?);
    try std.testing.expect(s.calls[3].in_restore);
    try std.testing.expect(!s.calls[4].in_restore); // inside if
    try std.testing.expect(!s.calls[5].in_restore); // update()
    try std.testing.expectEqual('}', sample[s.restore_close.?]);
}

test "apply: move, delete, insert keep the rest" {
    const gpa = std.testing.allocator;
    var s = try scan(gpa, sample);
    defer s.deinit(gpa);
    const sf2 = s.calls[2];
    var edits = [_]Edit{
        .{ .span = sf2.args[0], .text = "7" },
        .{ .span = sf2.args[1], .text = "8" },
        .{ .span = lineOf(sample, s.calls[0].stmt), .text = "" },
        .{ .span = .{ .start = insertPoint(sample, s.restore_close.?), .end = insertPoint(sample, s.restore_close.?) }, .text = "    PlaceActor(\"new\", 1, 2, 0);\r\n" },
    };
    const out = try apply(gpa, sample, &edits);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "PlaceActor(\"01h_sfinks2\",7,8,5);") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"Sullivan\",4,3") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "    PlaceActor(\"new\", 1, 2, 0);\r\n};\r\nfunction update") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "{\r\n    //PlaceActor") != null);
}

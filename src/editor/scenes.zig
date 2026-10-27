//! Cutscene triggers in level scripts: `StartScriptlet("name")` and
//! `SetAddonScriptlet("name")` calls. Turning one off comments out the call's
//! statement — the whole `if (…) { … };` around it when there is one (the condition's
//! other lines, like taking a hero out of the party, belong to the scene) — with an
//! editor mark, so turning it on again removes exactly those comments.

const std = @import("std");
const Allocator = std.mem.Allocator;
const placement = @import("placement.zig");
const Span = placement.Span;

/// Prefix of the lines the editor commented out.
const off_mark = "//#ed ";

pub const State = enum { on, off, game_off };

pub const Call = struct {
    /// Offset of the call name.
    at: usize,
    addon: bool,
    state: State,
};

fn lineStart(text: []const u8, i: usize) usize {
    var a = i;
    while (a > 0 and text[a - 1] != '\n') a -= 1;
    return a;
}

fn lineEnd(text: []const u8, i: usize) usize {
    return if (std.mem.indexOfScalarPos(u8, text, i, '\n')) |e| e + 1 else text.len;
}

/// Places naming `name` in quotes (an area in `HeroInArea("name")`, an object…),
/// commented ones too; `at` is the opening quote.
pub fn refs(a: Allocator, text: []const u8, name: []const u8) ![]Call {
    var out: std.ArrayList(Call) = .empty;
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, pos, '"')) |q| {
        const e = std.mem.indexOfScalarPos(u8, text, q + 1, '"') orelse break;
        pos = e + 1;
        if (!std.ascii.eqlIgnoreCase(text[q + 1 .. e], name)) continue;
        try out.append(a, .{ .at = q, .addon = false, .state = stateAt(text, q) });
    }
    return out.items;
}

fn stateAt(text: []const u8, i: usize) State {
    const ls = lineStart(text, i);
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, text[ls..], " \t"), off_mark)) return .off;
    return if (std.mem.indexOf(u8, text[ls..i], "//") != null) .game_off else .on;
}

/// Calls starting scene `scene` (name case-insensitive), commented ones too.
pub fn calls(a: Allocator, text: []const u8, scene: []const u8) ![]Call {
    var out: std.ArrayList(Call) = .empty;
    for ([_][]const u8{ "StartScriptlet", "SetAddonScriptlet" }, 0..) |f, k| {
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, text, pos, f)) |i| {
            pos = i + f.len;
            // SetAddonScriptlet contains "Scriptlet" but not "StartScriptlet": no overlap.
            if (i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_')) continue;
            var q = pos;
            while (q < text.len and (text[q] == ' ' or text[q] == '\t' or text[q] == '(')) q += 1;
            if (q >= text.len or text[q] != '"') continue;
            const e = std.mem.indexOfScalarPos(u8, text, q + 1, '"') orelse continue;
            if (!std.ascii.eqlIgnoreCase(text[q + 1 .. e], scene)) continue;
            try out.append(a, .{ .at = i, .addon = k == 1, .state = stateAt(text, i) });
        }
    }
    std.mem.sort(Call, out.items, {}, struct {
        fn lt(_: void, x: Call, y: Call) bool {
            return x.at < y.at;
        }
    }.lt);
    return out.items;
}

/// The first quoted argument of each call `f(` in `text` (any case; `f` not part of a
/// longer name).
fn quotedArgs(a: Allocator, text: []const u8, fs: []const []const u8, out: *std.ArrayList([]const u8)) !void {
    for (fs) |f| {
        var pos: usize = 0;
        while (std.ascii.findIgnoreCasePos(text, pos, f)) |i| {
            pos = i + f.len;
            if (i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_')) continue;
            var q = pos;
            while (q < text.len and (text[q] == ' ' or text[q] == '\t')) q += 1;
            if (q >= text.len or text[q] != '(') continue;
            q += 1;
            // ActorInArea(actor, "area"): the area is the last quoted argument.
            const close = std.mem.indexOfScalarPos(u8, text, q, ')') orelse continue;
            const args = text[q..close];
            const e = std.mem.lastIndexOfScalar(u8, args, '"') orelse continue;
            const s0 = std.mem.lastIndexOfScalar(u8, args[0..e], '"') orelse continue;
            try out.append(a, args[s0 + 1 .. e]);
        }
    }
}

/// Scenes the block of the call at `at` starts (StartScriptlet, SetAddonScriptlet,
/// ADDONSCRIPTLET) — what a trigger leads to.
pub fn startedIn(a: Allocator, text: []const u8, at: usize) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const sp = block(text, at);
    quotedArgs(a, text[sp.start..sp.end], &.{ "StartScriptlet", "SetAddonScriptlet", "ADDONSCRIPTLET" }, &out) catch {};
    return out.items;
}

/// The area whose entering runs the block of the call at `at` (HeroInArea, ActorInArea).
pub fn areaOf(a: Allocator, text: []const u8, at: usize) ?[]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const sp = block(text, at);
    quotedArgs(a, text[sp.start..sp.end], &.{ "HeroInArea", "ActorInArea" }, &out) catch {};
    return if (out.items.len > 0) out.items[0] else null;
}

/// Whole lines turning the call at `at` off: its `if (…) { … };` (from the line of
/// `if` through the `};`), else the call's own lines.
pub fn block(text: []const u8, at: usize) Span {
    // Inside an `if (…)` condition: that if and its body.
    if (condIf(text, at)) |c| return ifSpan(text, c.if_at, c.open) orelse .{ .start = lineStart(text, at), .end = lineEnd(text, at) };
    // The innermost unclosed `{` before the call.
    var depth: usize = 0;
    var i = at;
    const open: ?usize = while (i > 0) {
        i -= 1;
        switch (text[i]) {
            '}' => depth += 1,
            '{' => if (depth == 0) break i else {
                depth -= 1;
            },
            else => {},
        }
    } else null;
    if (open) |o| if (ifBefore(text, o)) |if_at| if (ifSpan(text, if_at, o)) |sp| return sp;
    const semi = std.mem.indexOfScalarPos(u8, text, at, ';') orelse at;
    return .{ .start = lineStart(text, at), .end = lineEnd(text, semi) };
}

/// Turning the call at `at` off comments out nothing else: the block's first line
/// starts with it and its last line ends with it (no other statement shares them).
pub fn safe(text: []const u8, at: usize) bool {
    const span = block(text, at);
    const first_end = lineEnd(text, span.start);
    const head = std.mem.trim(u8, text[span.start..first_end], " \t\r\n");
    // The block starts a statement: `if`, or a call (not the middle of an expression).
    if (head.len == 0 or !(std.ascii.isAlphabetic(head[0]) or head[0] == '_')) return false;
    // Nothing a function needs: its own head or end.
    if (std.mem.startsWith(u8, head, "function")) return false;
    // Inside the block, a `}` closing something opened before it would cut a function.
    var depth: i32 = 0;
    for (text[span.start..span.end]) |ch| switch (ch) {
        '{' => depth += 1,
        '}' => {
            depth -= 1;
            if (depth < 0) return false;
        },
        else => {},
    };
    return depth == 0;
}

/// From the line of `if` at `if_at` to the end of the line of the `}` matching `{` at `open`.
fn ifSpan(text: []const u8, if_at: usize, open: usize) ?Span {
    var d: usize = 0;
    var k = open;
    while (k < text.len) : (k += 1) switch (text[k]) {
        '{' => d += 1,
        '}' => {
            d -= 1;
            if (d == 0) return .{ .start = lineStart(text, if_at), .end = lineEnd(text, k) };
        },
        else => {},
    };
    return null;
}

/// `at` inside the condition of `if (…) {`: the `if` and its body's `{`.
fn condIf(text: []const u8, at: usize) ?struct { if_at: usize, open: usize } {
    var depth: usize = 0;
    var i = at;
    while (i > 0) {
        i -= 1;
        switch (text[i]) {
            ')' => depth += 1,
            '(' => if (depth > 0) {
                depth -= 1;
            } else {
                // An unclosed `(` around `at`: the condition's own, or a call's in it.
                var k = i;
                while (k > 0 and std.ascii.isWhitespace(text[k - 1])) k -= 1;
                if (k >= 2 and std.mem.eql(u8, text[k - 2 .. k], "if") and (k == 2 or !(std.ascii.isAlphanumeric(text[k - 3]) or text[k - 3] == '_'))) {
                    // Its `)`, then the body's `{`.
                    var d: usize = 0;
                    var j = i;
                    while (j < text.len) : (j += 1) switch (text[j]) {
                        '(' => d += 1,
                        ')' => {
                            d -= 1;
                            if (d == 0) break;
                        },
                        else => {},
                    };
                    j += 1;
                    while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
                    if (j < text.len and text[j] == '{') return .{ .if_at = k - 2, .open = j };
                    return null;
                }
            },
            ';', '{', '}' => if (depth == 0) return null,
            else => {},
        }
    }
    return null;
}

/// Offset of `if` when `{` at `o` opens `if (…) {`.
fn ifBefore(text: []const u8, o: usize) ?usize {
    var k = o;
    while (k > 0 and std.ascii.isWhitespace(text[k - 1])) k -= 1;
    if (k == 0 or text[k - 1] != ')') return null;
    var depth: usize = 0;
    while (k > 0) {
        k -= 1;
        switch (text[k]) {
            ')' => depth += 1,
            '(' => {
                depth -= 1;
                if (depth == 0) break;
            },
            else => {},
        }
    }
    while (k > 0 and std.ascii.isWhitespace(text[k - 1])) k -= 1;
    if (k < 2 or !std.mem.eql(u8, text[k - 2 .. k], "if")) return null;
    if (k > 2 and (std.ascii.isAlphanumeric(text[k - 3]) or text[k - 3] == '_')) return null;
    return k - 2;
}

/// `text` with the lines of `span` commented out by the editor.
pub fn turnOff(gpa: Allocator, text: []const u8, span: Span) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, text[0..span.start]);
    var i = span.start;
    while (i < span.end) {
        const e = lineEnd(text, i);
        try out.appendSlice(gpa, off_mark);
        try out.appendSlice(gpa, text[i..e]);
        i = e;
    }
    try out.appendSlice(gpa, text[span.end..]);
    return out.toOwnedSlice(gpa);
}

/// The run of lines the editor commented out around `at`.
pub fn offRun(text: []const u8, at: usize) Span {
    const marked = struct {
        fn f(t: []const u8, ls: usize) bool {
            return std.mem.startsWith(u8, t[ls..], off_mark);
        }
    }.f;
    var a = lineStart(text, at);
    while (a > 0 and marked(text, lineStart(text, a - 1))) a = lineStart(text, a - 1);
    var b = a;
    while (b < text.len and marked(text, b)) b = lineEnd(text, b);
    return .{ .start = a, .end = b };
}

/// `text` with the editor's comments taken off the run of marked lines around `at`.
pub fn turnOn(gpa: Allocator, text: []const u8, at: usize) ![]u8 {
    const run = offRun(text, at);
    const a = run.start;
    const b = run.end;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, text[0..a]);
    var i = a;
    while (i < b) {
        const e = lineEnd(text, i);
        try out.appendSlice(gpa, text[i + off_mark.len .. e]);
        i = e;
    }
    try out.appendSlice(gpa, text[b..]);
    return out.toOwnedSlice(gpa);
}

/// First line of a scene the editor shortened.
const short_mark = "//#ed short: dialogue, waits and show commented out";

/// Scene commands that only show or wait: a skip in the exe (0x478950) runs none of
/// their effect — dialogue, pauses, waits, fades, bars, scene animations, camera,
/// sound, video. A shortened scene keeps the rest (heroes joining or leaving,
/// objects, positions, level loads), the same in the port and the original.
const show_only = [_][]const u8{
    "DELAY",    "DIALOG_INIT",   "DIALOG_DISPLAY", "DIALOG_SHOW", "FADE_INDIALOG_DISPLAY", "WAITFORACTOR",  "WAITFORANIMATION",
    "FADE_OUT", "FADE_IN",       "FADE_BLACK",     "PANORAMA_ON", "PANORAMA_OFF",          "ANIMATION",     "ACTOR_GOINDOWN",
    "SOUND",    "PLAYAVI",       "EARTHQUAKE",     "SIGNATURE",   "SIGNATURE_ON",          "SIGNATURE_OFF", "DOLLY",
    "ZOOM",     "AUTOCAMERA_ON", "AUTOCAMERA_OFF",
};

pub fn isShort(text: []const u8) bool {
    return std.mem.startsWith(u8, text, short_mark);
}

fn showOnly(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r\n");
    const end = std.mem.indexOfAny(u8, t, "( \t") orelse t.len;
    for (show_only) |c| if (std.ascii.eqlIgnoreCase(t[0..end], c)) return true;
    return false;
}

/// Scene text with its show-only lines commented out by the editor (and a first-line mark).
pub fn shorten(gpa: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "{s}{s}", .{ short_mark, placement.newline(text) });
    var i: usize = 0;
    while (i < text.len) {
        const e = lineEnd(text, i);
        if (showOnly(text[i..e])) try out.appendSlice(gpa, off_mark);
        try out.appendSlice(gpa, text[i..e]);
        i = e;
    }
    return out.toOwnedSlice(gpa);
}

/// The scene as it was before `shorten`.
pub fn unshorten(gpa: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = if (isShort(text)) lineEnd(text, 0) else 0;
    while (i < text.len) {
        const e = lineEnd(text, i);
        const l = text[i..e];
        try out.appendSlice(gpa, if (std.mem.startsWith(u8, l, off_mark)) l[off_mark.len..] else l);
        i = e;
    }
    return out.toOwnedSlice(gpa);
}

test "scenes: shorten keeps what changes the game, and comes back" {
    const gpa = std.testing.allocator;
    const scr = "GUI_CUTSCENE\r\nDIALOG_INIT(\"x\",\"a.dlg\")\r\nDIALOG_DISPLAY(0)\r\nDELAY(30)\r\n" ++
        "WALKTO(\"Medusa\",\"p1\")\r\nWAITFORACTOR(\"Medusa\")\r\nSETHERO(\"Medusa\",1)\r\nGUI_NORMAL\r\n";
    const short = try shorten(gpa, scr);
    defer gpa.free(short);
    try std.testing.expect(isShort(short));
    try std.testing.expect(std.mem.indexOf(u8, short, "\r\n//#ed DIALOG_DISPLAY(0)\r\n//#ed DELAY(30)\r\nWALKTO") != null);
    try std.testing.expect(std.mem.indexOf(u8, short, "\r\nSETHERO(\"Medusa\",1)\r\nGUI_NORMAL") != null);
    const back = try unshorten(gpa, short);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(scr, back);
}

const sample =
    "function update()\r\n" ++
    "{\r\n" ++
    "  if (CutsceneCrazyMedusa && GUI_IsHero(\"Medusa\") && HeroInArea(\"cutscene_crazy\"))\r\n" ++
    "  { HERO_EnableEnumerate(\"Medusa\",0); StartScriptlet(\"museum-medusa_crazy\"); };\r\n" ++
    "  //StartScriptlet(\"old\");\r\n" ++
    "  SetAddonScriptlet(\"lab-enter\");\r\n" ++
    "};\r\n";

test "scenes: calls, block, off and on again" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cs = try calls(a, sample, "museum-medusa_crazy");
    try std.testing.expectEqual(1, cs.len);
    try std.testing.expectEqual(State.on, cs[0].state);
    try std.testing.expectEqual(State.game_off, (try calls(a, sample, "old"))[0].state);
    const lab = try calls(a, sample, "LAB-ENTER");
    try std.testing.expect(lab[0].addon);

    // The whole if (the hero leaving the party goes with the scene).
    const span = block(sample, cs[0].at);
    try std.testing.expect(std.mem.startsWith(u8, sample[span.start..], "  if (CutsceneCrazyMedusa"));
    try std.testing.expect(std.mem.endsWith(u8, sample[0..span.end], "\"museum-medusa_crazy\"); };\r\n"));
    const off = try turnOff(gpa, sample, span);
    defer gpa.free(off);
    try std.testing.expectEqual(State.off, (try calls(a, off, "museum-medusa_crazy"))[0].state);
    const on = try turnOn(gpa, off, (try calls(a, off, "museum-medusa_crazy"))[0].at);
    defer gpa.free(on);
    try std.testing.expectEqualStrings(sample, on);

    try std.testing.expect(safe(sample, cs[0].at) and safe(sample, lab[0].at));
    try std.testing.expect(!safe("function f() { x = 1; StartScriptlet(\"a\"); };\n", 20));

    // An area named in a condition: the same if.
    const ar = try refs(a, sample, "cutscene_crazy");
    try std.testing.expectEqual(1, ar.len);
    try std.testing.expectEqual(span, block(sample, ar[0].at));

    // A bare call: its own line.
    const ls = block(sample, lab[0].at);
    try std.testing.expectEqualStrings("  SetAddonScriptlet(\"lab-enter\");\r\n", sample[ls.start..ls.end]);
}

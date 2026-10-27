//! New trigger areas: a polygon appended to the level's `.ar` and a block in its `.lev`
//! update() that runs once when a hero walks in — the game's own pattern
//! (`if(trupy && HeroInArea("trupy")) { trupy = 0; … };` in 01_port.lev). The `.ar` is
//! data (no 's' flag); the exe finds the area by name, ignoring case.

const std = @import("std");
const Allocator = std.mem.Allocator;
const placement = @import("placement.zig");
const funcBody = @import("box.zig").funcBody;

/// A free area name `<prefix><n>` in `ar` (the text of `<level>.ar`).
pub fn freeName(buf: []u8, ar: []const u8, prefix: []const u8) []const u8 {
    var n: usize = 1;
    while (true) : (n += 1) {
        const name = std.fmt.bufPrint(buf, "{s}{d}", .{ prefix, n }) catch unreachable;
        if (!hasArea(ar, name)) return name;
    }
}

pub fn hasArea(ar: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, ar, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, l, "areaName:") and std.ascii.eqlIgnoreCase(std.mem.trim(u8, l["areaName:".len..], " \t"), name)) return true;
    }
    return false;
}

/// `ar` with area `name` (points in background pixels) added and `areaCnt` raised;
/// its control point (where a hero walks to use it) `control`, else the middle.
pub fn addArea(gpa: Allocator, ar: []const u8, name: []const u8, pts: []const [2]i32, control: ?[2]i32) ![]u8 {
    const nl = placement.newline(ar);
    const key = "areaCnt=";
    const k = std.mem.indexOf(u8, ar, key) orelse return error.NoAreaCount;
    var e = k + key.len;
    while (e < ar.len and std.ascii.isDigit(ar[e])) e += 1;
    const cnt = try std.fmt.parseInt(u32, ar[k + key.len .. e], 10);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "{s}{s}{d}", .{ ar[0..k], key, cnt + 1 });
    try out.appendSlice(gpa, std.mem.trimEnd(u8, ar[e..], " \t\r\n"));
    try out.print(gpa, "{s}areaName: {s}{s}pointCnt={d}{s}", .{ nl, name, nl, pts.len, nl });
    var c: [2]i64 = .{ 0, 0 };
    for (pts) |p| {
        try out.print(gpa, "{d},{d},0.000000{s}", .{ p[0], p[1], nl });
        c = .{ c[0] + p[0], c[1] + p[1] };
    }
    const n: i64 = @intCast(@max(1, pts.len));
    const cp: [2]i64 = if (control) |q| .{ q[0], q[1] } else .{ @divTrunc(c[0], n), @divTrunc(c[1], n) };
    try out.print(gpa, "controlPoint: {d},{d},0.000000{s}", .{ cp[0], cp[1], nl });
    return out.toOwnedSlice(gpa);
}

/// `lev` with a one-shot trigger on area `name`: `int ready_<name>;` declared before
/// init(), set to 1 first in init(), and the block at the end of update() (a new
/// update() if there is none). `at`: where the block's body line is, for the cursor.
pub fn addTrigger(gpa: Allocator, lev: []const u8, name: []const u8) !struct { text: []u8, at: usize } {
    const nl = placement.newline(lev);
    const init_head = std.mem.indexOf(u8, lev, "function init(") orelse return error.NoInit;
    const init_body = funcBody(lev, "init") orelse return error.NoInit;
    const after_open = lineEnd(lev, init_body.start - 1);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, lev[0..init_head]);
    try out.print(gpa, "int ready_{s};   // trigger made in the editor{s}{s}", .{ name, nl, nl });
    try out.appendSlice(gpa, lev[init_head..after_open]);
    try out.print(gpa, "  ready_{s} = 1;{s}", .{ name, nl });
    var at: usize = 0;
    if (funcBody(lev, "update")) |ub| {
        // Before update()'s closing brace.
        try out.appendSlice(gpa, lev[after_open..ub.end]);
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.appendSlice(gpa, nl);
        at = try block(gpa, &out, name, nl);
        try out.appendSlice(gpa, lev[ub.end..]);
    } else {
        try out.appendSlice(gpa, std.mem.trimEnd(u8, lev[after_open..], " \t\r\n"));
        try out.print(gpa, "{s}{s}function update(){s}{{{s}", .{ nl, nl, nl, nl });
        at = try block(gpa, &out, name, nl);
        try out.print(gpa, "}};{s}", .{nl});
    }
    return .{ .text = try out.toOwnedSlice(gpa), .at = at };
}

/// A name the scripts and `.ar` take as is: letters, digits, `_`.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 40) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}

/// Where area `name`'s block is in `ar`: its `areaName:` line up to the next one (or the end).
fn areaSpan(ar: []const u8, name: []const u8) ?[2]usize {
    var i: usize = 0;
    var start: ?usize = null;
    while (i < ar.len) {
        const e = lineEnd(ar, i);
        const l = std.mem.trim(u8, ar[i..e], " \t\r\n");
        if (std.mem.startsWith(u8, l, "areaName:")) {
            if (start) |st| return .{ st, i };
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, l["areaName:".len..], " \t"), name)) start = i;
        }
        i = e;
    }
    return if (start) |st| .{ st, ar.len } else null;
}

/// `ar` with `areaCnt` changed by `delta` and `mid` put over `span`.
fn rebuild(gpa: Allocator, ar: []const u8, span: [2]usize, mid: []const u8, delta: i32) ![]u8 {
    const key = "areaCnt=";
    const k = std.mem.indexOf(u8, ar, key) orelse return error.NoAreaCount;
    var e = k + key.len;
    while (e < ar.len and std.ascii.isDigit(ar[e])) e += 1;
    const cnt = try std.fmt.parseInt(i32, ar[k + key.len .. e], 10);
    return std.fmt.allocPrint(gpa, "{s}{s}{d}{s}{s}{s}", .{ ar[0..k], key, cnt + delta, ar[e..span[0]], mid, ar[span[1]..] });
}

/// `ar` without area `name`.
pub fn removeArea(gpa: Allocator, ar: []const u8, name: []const u8) ![]u8 {
    return rebuild(gpa, ar, areaSpan(ar, name) orelse return error.NoArea, "", -1);
}

/// `ar` with area `name`'s points moved by `d` (background pixels) and its control
/// point at `control`; the heights stay as written.
pub fn moveArea(gpa: Allocator, ar: []const u8, name: []const u8, d: [2]i32, control: [2]i32) ![]u8 {
    const sp = areaSpan(ar, name) orelse return error.NoArea;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, ar[0..sp[0]]);
    var i = sp[0];
    while (i < sp[1]) {
        const e = lineEnd(ar, i);
        const line = ar[i..e];
        const body = std.mem.trimEnd(u8, line, "\r\n");
        const tail = line[body.len..];
        const cp = "controlPoint:";
        const is_cp = std.mem.startsWith(u8, std.mem.trim(u8, body, " \t"), cp);
        var f = std.mem.splitScalar(u8, if (is_cp) std.mem.trim(u8, std.mem.trim(u8, body, " \t")[cp.len..], " \t") else body, ',');
        const xs = f.next() orelse "";
        const ys = f.next() orelse "";
        const rest = f.rest();
        const x = std.fmt.parseFloat(f32, std.mem.trim(u8, xs, " \t")) catch null;
        const y = std.fmt.parseFloat(f32, std.mem.trim(u8, ys, " \t")) catch null;
        if (x == null or y == null or std.mem.indexOfScalar(u8, body, '=') != null) {
            try out.appendSlice(gpa, line);
        } else if (is_cp) {
            try out.print(gpa, "controlPoint: {d},{d},{s}{s}", .{ control[0], control[1], rest, tail });
        } else {
            const nx: i32 = @as(i32, @intFromFloat(@round(x.?))) + d[0];
            const ny: i32 = @as(i32, @intFromFloat(@round(y.?))) + d[1];
            try out.print(gpa, "{d},{d},{s}{s}", .{ nx, ny, rest, tail });
        }
        i = e;
    }
    try out.appendSlice(gpa, ar[sp[1]..]);
    return out.toOwnedSlice(gpa);
}

/// `ar` with area `old` named `new`.
pub fn renameArea(gpa: Allocator, ar: []const u8, old: []const u8, new: []const u8) ![]u8 {
    const sp = areaSpan(ar, old) orelse return error.NoArea;
    const e = lineEnd(ar, sp[0]);
    const nl = if (std.mem.endsWith(u8, ar[sp[0]..e], "\r\n")) "\r\n" else "\n";
    const line = try std.fmt.allocPrint(gpa, "areaName: {s}{s}", .{ new, nl });
    defer gpa.free(line);
    return rebuild(gpa, ar, .{ sp[0], e }, line, 0);
}

/// `lev` without the trigger `addTrigger` made for `name` (its variable, arming line
/// and block); the same text if there is none.
pub fn removeTrigger(gpa: Allocator, lev: []const u8, name: []const u8) ![]u8 {
    var out = try gpa.dupe(u8, lev);
    errdefer gpa.free(out);
    var vb: [64]u8 = undefined;
    const v = try std.fmt.bufPrint(&vb, "ready_{s}", .{name});
    // The block: from its `if(ready_<name> && …` line to its closing `};`.
    var ib: [80]u8 = undefined;
    if (std.mem.indexOf(u8, out, try std.fmt.bufPrint(&ib, "if({s} &&", .{v}))) |at| {
        const ls = lineStart(out, at);
        var i = std.mem.indexOfScalarPos(u8, out, at, '{') orelse return out;
        var depth: usize = 0;
        while (i < out.len) : (i += 1) switch (out[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) break;
            },
            '"' => i = std.mem.indexOfScalarPos(u8, out, i + 1, '"') orelse out.len - 1,
            else => {},
        };
        const end = lineEnd(out, i);
        out = try cut(gpa, out, ls, end);
    }
    // `ready_<name> = 1;` and `int ready_<name>;` lines (with the blank line after it).
    var k: usize = 0;
    while (k < out.len) {
        const e = lineEnd(out, k);
        const l = std.mem.trim(u8, out[k..e], " \t\r\n");
        const assign = std.mem.startsWith(u8, l, v) and std.mem.endsWith(u8, std.mem.trim(u8, l[v.len..], " "), "= 1;");
        const rest = if (std.mem.startsWith(u8, l, "int ")) std.mem.trimStart(u8, l[4..], " \t") else "";
        const decl = std.mem.startsWith(u8, rest, v) and rest.len > v.len and rest[v.len] == ';';
        if (assign or decl) {
            var to = e;
            if (decl and to < out.len and std.mem.trim(u8, out[to..lineEnd(out, to)], " \t\r\n").len == 0) to = lineEnd(out, to);
            out = try cut(gpa, out, k, to);
            continue;
        }
        k = e;
    }
    return out;
}

/// `text` with `"old"` (any case) as `"new"` and the variable `ready_old` as `ready_new`.
pub fn renameRefs(gpa: Allocator, text: []const u8, old: []const u8, new: []const u8) ![]u8 {
    return rename(gpa, text, old, new, true);
}

/// `text` with `"old"` (any case) as `"new"` only (a scene's name in the scripts).
pub fn renameQuoted(gpa: Allocator, text: []const u8, old: []const u8, new: []const u8) ![]u8 {
    return rename(gpa, text, old, new, false);
}

fn rename(gpa: Allocator, text: []const u8, old: []const u8, new: []const u8, vars: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var ob: [64]u8 = undefined;
    const ov = try std.fmt.bufPrint(&ob, "ready_{s}", .{old});
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '"' and i + old.len + 1 < text.len and text[i + old.len + 1] == '"' and std.ascii.eqlIgnoreCase(text[i + 1 .. i + 1 + old.len], old)) {
            try out.print(gpa, "\"{s}\"", .{new});
            i += old.len + 2;
            continue;
        }
        const ident_before = i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '_');
        const after = i + ov.len;
        if (vars and !ident_before and std.mem.startsWith(u8, text[i..], ov) and (after >= text.len or !(std.ascii.isAlphanumeric(text[after]) or text[after] == '_'))) {
            try out.print(gpa, "ready_{s}", .{new});
            i = after;
            continue;
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn cut(gpa: Allocator, text: []u8, a: usize, b: usize) ![]u8 {
    const r = try std.mem.concat(gpa, u8, &.{ text[0..a], text[b..] });
    gpa.free(text);
    return r;
}

fn lineStart(text: []const u8, i: usize) usize {
    return if (std.mem.lastIndexOfScalar(u8, text[0..i], '\n')) |k| k + 1 else 0;
}

fn block(gpa: Allocator, out: *std.ArrayList(u8), name: []const u8, nl: []const u8) !usize {
    try out.print(gpa, "  if(ready_{s} && HeroInArea(\"{s}\")){s}  {{{s}    ready_{s} = 0;{s}", .{ name, name, nl, nl, name, nl });
    const at = out.items.len;
    try out.print(gpa, "    // what happens, e.g. a hero joins (02_serwers.lev): EnableObject(\"Medusa\"); HERO_EnableEnumerate(\"Medusa\",1); StartScriptlet(\"scene1\");{s}  }};{s}", .{ nl, nl });
    return at;
}

fn lineEnd(text: []const u8, i: usize) usize {
    return if (std.mem.indexOfScalarPos(u8, text, i, '\n')) |e| e + 1 else text.len;
}

// ------------------------------------------------------------ exits

/// Hints an exit can show over it (string.tab ids of the game's active areas).
pub const exit_labels = [_]u16{ 218, 243, 200, 202, 205, 214, 267 };

/// Script of a clickable exit on area `area`, as the game's (`store_enter_are.are`):
/// clicked, the hero walks to the area's control point, then LevelSwitch() loads
/// `target`. `enable`: heroes the level disabled come back first (a small room's
/// DisableHeroes(), as 01_port_worker's exit). isLevelSwitch only needs to be > 0: the
/// exe's exit cursor is one (0x45135e).
pub fn exitScript(gpa: Allocator, area: []const u8, label: u16, target: []const u8, enable: bool) ![]u8 {
    return std.fmt.allocPrint(gpa, "#include ActiveArea.s\r\n\r\n\r\nfunction init()\r\n{{\r\n  nameID={d};\r\n  areaName=\"{s}\";\r\n\r\n  funcID = -1;\r\n  isLevelSwitch = 1;\r\n}};\r\n\r\nfunction LevelSwitch()\r\n{{\r\n{s}  LEVEL_Load(\"{s}\");\r\n}};\r\n", .{ label, area, if (enable) "  EnableHeroes();\r\n" else "", target });
}

/// Script `text` is the exit of area `area` (its `areaName` and a LevelSwitch()).
pub fn isExitOf(text: []const u8, area: []const u8) bool {
    if (std.mem.indexOf(u8, text, "function LevelSwitch") == null) return false;
    const k = std.mem.indexOf(u8, text, "areaName") orelse return false;
    const q = std.mem.indexOfScalarPos(u8, text, k, '"') orelse return false;
    const e = std.mem.indexOfScalarPos(u8, text, q + 1, '"') orelse return false;
    return std.ascii.eqlIgnoreCase(text[q + 1 .. e], area);
}

/// The level an exit script loads (its first LEVEL_Load), if any.
pub fn exitTarget(text: []const u8) ?[]const u8 {
    const k = std.mem.indexOf(u8, text, "LEVEL_Load(\"") orelse return null;
    const s = k + "LEVEL_Load(\"".len;
    const e = std.mem.indexOfScalarPos(u8, text, s, '"') orelse return null;
    return text[s..e];
}

/// The exit script loading `target` instead.
pub fn setExitTarget(gpa: Allocator, text: []const u8, target: []const u8) ![]u8 {
    const old = exitTarget(text) orelse return error.NoTarget;
    const at = @intFromPtr(old.ptr) - @intFromPtr(text.ptr);
    return std.mem.concat(gpa, u8, &.{ text[0..at], target, text[at + old.len ..] });
}

/// `text` without the lines that are a single call naming `name` first
/// (`EnableObject("Medusa");`, `HERO_EnableEnumerate("Medusa",1);   // …`); every
/// other line as it is.
pub fn dropCallsOf(gpa: Allocator, text: []const u8, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) {
        const e = lineEnd(text, i);
        if (!isCallOf(text[i..e], name)) try out.appendSlice(gpa, text[i..e]);
        i = e;
    }
    return out.toOwnedSlice(gpa);
}

fn isCallOf(line: []const u8, name: []const u8) bool {
    var l = std.mem.trim(u8, line, " \t\r\n");
    if (std.mem.indexOf(u8, l, "//")) |k| l = std.mem.trimEnd(u8, l[0..k], " \t");
    if (!std.mem.endsWith(u8, l, ");")) return false;
    const open = std.mem.indexOfScalar(u8, l, '(') orelse return false;
    for (l[0..open]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    const arg = std.mem.trimStart(u8, l[open + 1 ..], " \t");
    return arg.len > name.len + 1 and arg[0] == '"' and std.ascii.eqlIgnoreCase(arg[1 .. name.len + 1], name) and arg[name.len + 1] == '"';
}

test dropCallsOf {
    const gpa = std.testing.allocator;
    const t = "a();\r\n  EnableObject(\"Medusa\");\r\n  HERO_EnableEnumerate( \"medusa\",1);   // x\r\n  if(HeroInArea(\"Medusa\")){\r\n  Foo(\"MedusaX\");\r\n";
    const out = try dropCallsOf(gpa, t, "Medusa");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a();\r\n  if(HeroInArea(\"Medusa\")){\r\n  Foo(\"MedusaX\");\r\n", out);
}

test exitScript {
    const gpa = std.testing.allocator;
    const t = try exitScript(gpa, "exit1", 218, "01_port", true);
    defer gpa.free(t);
    try std.testing.expect(isExitOf(t, "EXIT1"));
    try std.testing.expect(!isExitOf(t, "exit2"));
    try std.testing.expectEqualStrings("01_port", exitTarget(t).?);
    try std.testing.expect(std.mem.indexOf(u8, t, "  EnableHeroes();\r\n  LEVEL_Load") != null);
    const u = try setExitTarget(gpa, t, "my_room");
    defer gpa.free(u);
    try std.testing.expectEqualStrings("my_room", exitTarget(u).?);
    try std.testing.expectEqual(t.len - "01_port".len + "my_room".len, u.len);
}

test "addArea: counted, appended as the game writes them" {
    const gpa = std.testing.allocator;
    const ar = "areaCnt=1\r\nareaName: a\r\npointCnt=1\r\n1,2,0.000000\r\ncontrolPoint: 1,2,0.000000\r\n";
    var buf: [32]u8 = undefined;
    const name = freeName(&buf, ar, "trigger");
    try std.testing.expectEqualStrings("trigger1", name);
    const out = try addArea(gpa, ar, name, &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 20 } }, null);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("areaCnt=2\r\nareaName: a\r\npointCnt=1\r\n1,2,0.000000\r\ncontrolPoint: 1,2,0.000000\r\n" ++
        "areaName: trigger1\r\npointCnt=3\r\n0,0,0.000000\r\n10,0,0.000000\r\n10,20,0.000000\r\ncontrolPoint: 6,6,0.000000\r\n", out);
    try std.testing.expect(hasArea(out, "TRIGGER1"));
}

test "addTrigger: declared, armed in init, checked in update" {
    const gpa = std.testing.allocator;
    const lev = "int a;\r\nfunction init()\r\n{\r\n  a = 1;\r\n};\r\nfunction update()\r\n{\r\n  if(a) { a = 0; };\r\n};\r\n";
    const r = try addTrigger(gpa, lev, "t1");
    defer gpa.free(r.text);
    try std.testing.expectEqualStrings("int a;\r\nint ready_t1;   // trigger made in the editor\r\n\r\nfunction init()\r\n{\r\n  ready_t1 = 1;\r\n  a = 1;\r\n};\r\nfunction update()\r\n{\r\n  if(a) { a = 0; };\r\n" ++
        "  if(ready_t1 && HeroInArea(\"t1\"))\r\n  {\r\n    ready_t1 = 0;\r\n    // what happens, e.g. a hero joins (02_serwers.lev): EnableObject(\"Medusa\"); HERO_EnableEnumerate(\"Medusa\",1); StartScriptlet(\"scene1\");\r\n  };\r\n};\r\n", r.text);
    try std.testing.expect(std.mem.startsWith(u8, r.text[r.at..], "    // what happens"));
}

test "removeArea, renameArea: the block and the count" {
    const gpa = std.testing.allocator;
    const ar = "areaCnt=2\r\nareaName: a\r\npointCnt=1\r\n1,2,0.000000\r\ncontrolPoint: 1,2,0.000000\r\nareaName: t1\r\npointCnt=1\r\n3,4,0.000000\r\ncontrolPoint: 3,4,0.000000\r\n";
    const r = try removeArea(gpa, ar, "T1");
    defer gpa.free(r);
    try std.testing.expectEqualStrings("areaCnt=1\r\nareaName: a\r\npointCnt=1\r\n1,2,0.000000\r\ncontrolPoint: 1,2,0.000000\r\n", r);
    const r2 = try removeArea(gpa, ar, "a");
    defer gpa.free(r2);
    try std.testing.expectEqualStrings("areaCnt=1\r\nareaName: t1\r\npointCnt=1\r\n3,4,0.000000\r\ncontrolPoint: 3,4,0.000000\r\n", r2);
    const n = try renameArea(gpa, ar, "t1", "gate2");
    defer gpa.free(n);
    try std.testing.expect(hasArea(n, "gate2") and !hasArea(n, "t1"));
    try std.testing.expectEqual(ar.len + 3, n.len);
}

test "removeTrigger takes back addTrigger; renameRefs" {
    const gpa = std.testing.allocator;
    const lev = "int a;\r\nfunction init()\r\n{\r\n  a = 1;\r\n};\r\nfunction update()\r\n{\r\n  if(a) { a = 0; };\r\n};\r\n";
    const added = try addTrigger(gpa, lev, "t1");
    defer gpa.free(added.text);
    const renamed = try renameRefs(gpa, added.text, "t1", "door");
    defer gpa.free(renamed);
    try std.testing.expect(std.mem.indexOf(u8, renamed, "ready_door && HeroInArea(\"door\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, renamed, "t1") == null);
    const back = try removeTrigger(gpa, renamed, "door");
    defer gpa.free(back);
    try std.testing.expectEqualStrings(lev, back);
    const none = try removeTrigger(gpa, lev, "zz");
    defer gpa.free(none);
    try std.testing.expectEqualStrings(lev, none);
}

test moveArea {
    const gpa = std.testing.allocator;
    const ar = "areaCnt=2\r\nareaName: a\r\npointCnt=2\r\n1,2,0.000000\r\n3,4,3.059999\r\ncontrolPoint: 1,2,0.000000\r\nareaName: b\r\npointCnt=1\r\n5,6,0.000000\r\ncontrolPoint: 5,6,0.000000\r\n";
    const out = try moveArea(gpa, ar, "A", .{ 10, -1 }, .{ 7, 8 });
    defer gpa.free(out);
    try std.testing.expectEqualStrings("areaCnt=2\r\nareaName: a\r\npointCnt=2\r\n11,1,0.000000\r\n13,3,3.059999\r\ncontrolPoint: 7,8,0.000000\r\nareaName: b\r\npointCnt=1\r\n5,6,0.000000\r\ncontrolPoint: 5,6,0.000000\r\n", out);
}

//! Numeric assignments `name = value;` in object scripts: class files (`ft_*.ss`,
//! `wp_*.ss`) and object files (`.ftr`, `.wpn`), whose lines after the class
//! `#include` override the class. The last assignment wins, as when the script runs.
//! Values are numbers or quoted strings.

const std = @import("std");
const Allocator = std.mem.Allocator;
const placement = @import("placement.zig");
const Span = placement.Span;

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Value span of the last `name = <number or "string">` outside comments (name
/// case-insensitive); a string's span includes the quotes.
pub fn find(text: []const u8, name: []const u8) ?Span {
    var found: ?Span = null;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '/' and i + 1 < text.len and text[i + 1] == '/') {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        } else if (ch == '/' and i + 1 < text.len and text[i + 1] == '*') {
            i = if (std.mem.indexOfPos(u8, text, i + 2, "*/")) |e| e + 2 else text.len;
        } else if (ch == '"') {
            i = if (std.mem.indexOfScalarPos(u8, text, i + 1, '"')) |e| e + 1 else text.len;
        } else if (isIdent(ch) and (i == 0 or !isIdent(text[i - 1]))) {
            var e = i;
            while (e < text.len and isIdent(text[e])) e += 1;
            if (std.ascii.eqlIgnoreCase(text[i..e], name)) if (value(text, e)) |v| {
                found = v;
            };
            i = e;
        } else i += 1;
    }
    return found;
}

fn value(text: []const u8, name_end: usize) ?Span {
    var k = name_end;
    while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
    if (k >= text.len or text[k] != '=' or (k + 1 < text.len and text[k + 1] == '=')) return null;
    k += 1;
    while (k < text.len and (text[k] == ' ' or text[k] == '\t')) k += 1;
    const a = k;
    if (k < text.len and text[k] == '"') {
        const e = std.mem.indexOfScalarPos(u8, text, k + 1, '"') orelse return null;
        return .{ .start = a, .end = e + 1 };
    }
    if (k < text.len and text[k] == '-') k += 1;
    while (k < text.len and (std.ascii.isDigit(text[k]) or text[k] == '.')) k += 1;
    if (k == a or std.fmt.parseFloat(f32, text[a..k]) == error.InvalidCharacter) return null;
    return .{ .start = a, .end = k };
}

/// A string value without its quotes.
pub fn getStr(text: []const u8, name: []const u8) ?[]const u8 {
    const s = find(text, name) orelse return null;
    if (text[s.start] != '"') return null;
    return text[s.start + 1 .. s.end - 1];
}

/// Names of the numeric assignments, first-seen order, at most `out.len`.
pub fn numericNames(text: []const u8, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len and n < out.len) {
        const ch = text[i];
        if (ch == '/' and i + 1 < text.len and text[i + 1] == '/') {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        } else if (ch == '"') {
            i = if (std.mem.indexOfScalarPos(u8, text, i + 1, '"')) |e| e + 1 else text.len;
        } else if (isIdent(ch) and (i == 0 or !isIdent(text[i - 1]))) {
            var e = i;
            while (e < text.len and isIdent(text[e])) e += 1;
            if (value(text, e)) |v| if (text[v.start] != '"') {
                const name = text[i..e];
                for (out[0..n]) |o| {
                    if (std.ascii.eqlIgnoreCase(o, name)) break;
                } else {
                    out[n] = name;
                    n += 1;
                }
            };
            i = e;
        } else i += 1;
    }
    return out[0..n];
}

/// `text` with declaration `decl` ("string effect;") after its leading directives
/// (`#include Weapon.s`, `#inherit …`, past comments), unless it already declares
/// that variable; null — nothing to add.
pub fn declare(gpa: Allocator, text: []const u8, decl: []const u8) !?[]u8 {
    var words = std.mem.tokenizeAny(u8, decl, " \t;");
    const ty = words.next() orelse return null;
    const name = words.next() orelse return null;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n;,");
    var prev: []const u8 = "";
    while (it.next()) |w| {
        if (std.mem.eql(u8, prev, ty) and std.ascii.eqlIgnoreCase(w, name)) return null;
        prev = w;
    }
    const nl = placement.newline(text);
    var at: usize = if (std.mem.indexOfScalar(u8, text, '\n')) |e| e + 1 else text.len;
    var pos: usize = 0;
    while (pos < text.len) {
        const e = if (std.mem.indexOfScalarPos(u8, text, pos, '\n')) |x| x + 1 else text.len;
        const t = std.mem.trim(u8, text[pos..e], " \t\r\n");
        if (t.len > 0 and t[0] == '#') {
            at = e;
        } else if (!(t.len == 0 or std.mem.startsWith(u8, t, "//"))) break;
        pos = e;
    }
    const line = try std.fmt.allocPrint(gpa, "{s}{s}", .{ decl, nl });
    defer gpa.free(line);
    var edits = [_]placement.Edit{.{ .span = .{ .start = at, .end = at }, .text = line }};
    return try placement.apply(gpa, text, &edits);
}

pub fn get(text: []const u8, name: []const u8) ?f32 {
    const s = find(text, name) orelse return null;
    return std.fmt.parseFloat(f32, text[s.start..s.end]) catch null;
}

/// `text` with `name` set to `v`: the last assignment changed, or a new line after
/// the line holding `after` (the class `#include`; null or missing — at the end).
pub fn set(gpa: Allocator, text: []const u8, name: []const u8, v: []const u8, after: ?[]const u8) ![]u8 {
    if (find(text, name)) |s| {
        var edits = [_]placement.Edit{.{ .span = s, .text = v }};
        return placement.apply(gpa, text, &edits);
    }
    const nl = placement.newline(text);
    const at: usize = blk: {
        const a = after orelse break :blk text.len;
        const p = std.ascii.findIgnoreCase(text, a) orelse break :blk text.len;
        break :blk if (std.mem.indexOfScalarPos(u8, text, p, '\n')) |e| e + 1 else text.len;
    };
    const lead = if (at == text.len and text.len > 0 and text[text.len - 1] != '\n') nl else "";
    const line = try std.fmt.allocPrint(gpa, "{s}    {s} = {s};{s}", .{ lead, name, v, nl });
    defer gpa.free(line);
    var edits = [_]placement.Edit{.{ .span = .{ .start = at, .end = at }, .text = line }};
    return placement.apply(gpa, text, &edits);
}

/// `text` without the line of the last assignment to `name`; null — none.
pub fn unset(gpa: Allocator, text: []const u8, name: []const u8) !?[]u8 {
    const s = find(text, name) orelse return null;
    var a = s.start;
    while (a > 0 and text[a - 1] != '\n') a -= 1;
    var b = s.end;
    while (b < text.len and text[b] != '\n') b += 1;
    if (b < text.len) b += 1;
    var edits = [_]placement.Edit{.{ .span = .{ .start = a, .end = b }, .text = "" }};
    return try placement.apply(gpa, text, &edits);
}

const ftr =
    "#include Fighter.s\r\n" ++
    "function init()\r\n" ++
    "{\r\n" ++
    "#include ft_garcia.ss\r\n" ++
    "};\r\n" ++
    "function post_init()\r\n" ++
    "{\r\n" ++
    "  //hp = 5;\r\n" ++
    "};\r\n";

test "find: last assignment, comments and == skipped" {
    const t = "armor = 0;\n  hp=40; // hp = 9\n if (armor == 2) {}\n  armor = 1;\n";
    try std.testing.expectEqual(1, get(t, "armor").?);
    try std.testing.expectEqual(40, get(t, "HP").?);
    try std.testing.expectEqual(null, get(t, "max_hp"));
}

test "strings, declarations, numeric names" {
    const gpa = std.testing.allocator;
    const t = "#include Weapon.s\nfunction class_init()\n{\n  spriteFile=\"axe\";\n  max_damage = 20;\n  type = 7;\n};\n";
    try std.testing.expectEqualStrings("axe", getStr(t, "spriteFile").?);
    var buf: [8][]const u8 = undefined;
    const names = numericNames(t, &buf);
    try std.testing.expectEqual(2, names.len);
    try std.testing.expectEqualStrings("type", names[1]);
    const a = try set(gpa, t, "spriteFile", "\"knife\"", null);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("knife", getStr(a, "spriteFile").?);
    const b = (try declare(gpa, a, "string effect;")).?;
    defer gpa.free(b);
    try std.testing.expect(std.mem.startsWith(u8, b, "#include Weapon.s\nstring effect;\nfunction"));
    try std.testing.expectEqual(null, try declare(gpa, b, "string effect;"));
    // A copy's mark comes first: declarations still go after the include.
    const c = (try declare(gpa, "// copy\n#include Weapon.s\n\nfunction f() {};", "string title;")).?;
    defer gpa.free(c);
    try std.testing.expectEqualStrings("// copy\n#include Weapon.s\nstring title;\n\nfunction f() {};", c);
}

test "set and unset an override after the include" {
    const gpa = std.testing.allocator;
    const a = try set(gpa, ftr, "hp", "80", "#include ft_");
    defer gpa.free(a);
    try std.testing.expect(std.mem.indexOf(u8, a, "#include ft_garcia.ss\r\n    hp = 80;\r\n};") != null);
    const b = try set(gpa, a, "hp", "95", "#include ft_");
    defer gpa.free(b);
    try std.testing.expectEqual(95, get(b, "hp").?);
    const c = (try unset(gpa, b, "hp")).?;
    defer gpa.free(c);
    try std.testing.expectEqualStrings(ftr, c);
    const d = try set(gpa, "x = 1;", "y", "2", null);
    defer gpa.free(d);
    try std.testing.expectEqualStrings("x = 1;\n    y = 2;\n", d);
}

/// `name`'s value in script `text` or, when it has none, in the files it `#include`s
/// (`lib.read(file)`), nested up to `depth` levels (a cycle ends there): an enemy class
/// is named in its `act_*.ss`, a battle extra's `.hro` in its class's.
pub fn inherited(lib: anytype, text: []const u8, name: []const u8, depth: u8) ?f32 {
    if (get(text, name)) |v| return v;
    if (depth == 0) return null;
    var pos: usize = 0;
    while (std.ascii.findIgnoreCasePos(text, pos, "#include ")) |p| : (pos = p + 1) {
        const s = p + "#include ".len;
        var e = s;
        while (e < text.len and !std.ascii.isWhitespace(text[e])) e += 1;
        const inc = lib.read(text[s..e]) orelse continue;
        if (inherited(lib, inc, name, depth - 1)) |v| return v;
    }
    return null;
}

/// Objects script `text` makes party heroes: `SETHERO("x",1)` (scenes),
/// `HERO_EnableEnumerate("x",1)` (level scripts); slices of `text`.
pub fn joins(a: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(a);
    for ([_][]const u8{ "SETHERO(\"", "HERO_EnableEnumerate(\"" }) |needle| {
        var pos: usize = 0;
        while (std.ascii.findIgnoreCasePos(text, pos, needle)) |i| : (pos = i + 1) {
            const s = i + needle.len;
            const q = std.mem.indexOfScalarPos(u8, text, s, '"') orelse continue;
            var k = q + 1;
            while (k < text.len and (text[k] == ',' or text[k] == ' ')) k += 1;
            if (k < text.len and std.ascii.isDigit(text[k]) and text[k] != '0' and q > s) try out.append(a, text[s..q]);
        }
    }
    return out.toOwnedSlice(a);
}

/// The files `#include NAME` and `#inherit NAME` lines of `text` name (an `#inherit`
/// without an extension is `NAME.s`, as the engine loads it), in `a`.
pub fn directives(a: Allocator, text: []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t");
        const inherit = std.ascii.startsWithIgnoreCase(l, "#inherit");
        if (!inherit and !std.ascii.startsWithIgnoreCase(l, "#include")) continue;
        var words = std.mem.tokenizeAny(u8, l["#include".len..], " \t\";");
        const n = words.next() orelse continue;
        const name = if (inherit and std.fs.path.extension(n).len == 0) std.fmt.allocPrint(a, "{s}.s", .{n}) catch continue else n;
        out.append(a, name) catch {};
    }
    return out.items;
}

test directives {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const d = directives(arena.allocator(), "#inherit Level\r\nint a;\r\nfunction init()\r\n{\r\n\t#include ft_fang.ss\r\n#inherit Weapon.s\r\n};");
    try std.testing.expectEqual(@as(usize, 3), d.len);
    try std.testing.expectEqualStrings("Level.s", d[0]);
    try std.testing.expectEqualStrings("ft_fang.ss", d[1]);
    try std.testing.expectEqualStrings("Weapon.s", d[2]);
}

test "inherited: nameID through nested includes, own value first, cycles end" {
    const Lib = struct {
        pub fn read(_: @This(), n: []const u8) ?[]const u8 {
            const files = [_][2][]const u8{
                .{ "Fighter.s", "int nameID; int avoidEnumerate;" },
                .{ "ft_medusa.ss", "#include act_medusa.ss\n hp = 1;" },
                .{ "act_medusa.ss", "  nameID=119;" },
                .{ "loop.ss", "#include loop.ss" },
            };
            for (files) |f| if (std.mem.eql(u8, f[0], n)) return f[1];
            return null;
        }
    };
    const medusa = "#include Fighter.s\nfunction init()\n{\n#include ft_medusa.ss\n moveLock = 1;\n avoidEnumerate = 1;\n};";
    try std.testing.expectEqual(@as(?f32, 119), inherited(Lib{}, medusa, "nameID", 4));
    try std.testing.expectEqual(@as(?f32, 1), inherited(Lib{}, medusa, "avoidEnumerate", 4));
    try std.testing.expectEqual(@as(?f32, 24), inherited(Lib{}, "#include ft_medusa.ss\n nameID=24;", "nameID", 4));
    try std.testing.expectEqual(@as(?f32, null), inherited(Lib{}, "#include loop.ss", "nameID", 4));
}

test "joins: SETHERO/HERO_EnableEnumerate with 1 join, with 0 leave" {
    const j = try joins(std.testing.allocator, "SETHERO(\"Medusa\",1);\nHERO_EnableEnumerate(\"MacFadden\", 1);\nHERO_EnableEnumerate(\"Bt\",0);");
    defer std.testing.allocator.free(j);
    try std.testing.expectEqual(@as(usize, 2), j.len);
    try std.testing.expectEqualStrings("Medusa", j[0]);
    try std.testing.expectEqualStrings("MacFadden", j[1]);
}

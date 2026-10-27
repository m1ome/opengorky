//! Texts of a new location or battle made from another (App.newLevel): its name, its
//! clean script (a location's party at area `capt_start`; a battle's heroes where the
//! template placed them, no enemies), a location's entry area.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A folder name the exe takes as `dat\%s\…` and in LEVEL_Load: lower-case letters,
/// digits and `_`; as the game names them, a battle has `__` (`01__port_heavy`), a
/// location not.
pub fn validName(name: []const u8, battle: bool) bool {
    if (name.len < 3 or name.len > 24) return false;
    if ((std.mem.indexOf(u8, name, "__") != null) != battle) return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    return true;
}

/// Function `name` of script `text` (header to its closing `};` line), if there.
fn function(text: []const u8, name: []const u8) ?[]const u8 {
    var hb: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&hb, "function {s}()", .{name}) catch return null;
    const at = std.mem.indexOf(u8, text, head) orelse return null;
    const end = std.mem.indexOfPos(u8, text, at, "\n};") orelse return null;
    return text[at .. end + 3];
}

/// The new level's script: the template's camera, its shadows on or not, the party
/// placed at `capt_start`; init/post_init/update empty for triggers to fill.
pub fn levText(gpa: Allocator, template: []const u8, back_to: []const u8) ![]u8 {
    const cam = function(template, "initCamera") orelse "";
    const shadows = if (function(template, "init")) |f| std.mem.indexOf(u8, f, "shadowActive=1") != null else false;
    const t = try std.fmt.allocPrint(gpa,
        \\#inherit Level
        \\
        \\{s}
        \\
        \\function init()
        \\{{
        \\{s}}};
        \\
        \\function post_init()
        \\{{
        \\}};
        \\
        \\function restore()
        \\{{
        \\  PlaceHeroes("capt_start");
        \\}};
        \\
        \\// A way out: a trigger area (level edit mode) whose block does LEVEL_Load("{s}");
        \\// the way in: one in {s} with LEVEL_Load("<this level>").
        \\function update()
        \\{{
        \\}};
        \\
    , .{ cam, if (shadows) "  shadowActive=1;\n" else "", back_to, back_to });
    defer gpa.free(t);
    // The game's scripts are CRLF (the template's camera may be already).
    const lf_only = try std.mem.replaceOwned(u8, gpa, t, "\r\n", "\n");
    defer gpa.free(lf_only);
    return std.mem.replaceOwned(u8, gpa, lf_only, "\n", "\r\n");
}

/// A new battle's script: the template's camera, its heroes' PlaceActor lines in
/// restore() (not the ones naming `enemies`, its fighters), no enemies (the editor
/// adds them), the staging GUI the game's battles start with.
pub fn battleLevText(gpa: Allocator, template: []const u8, enemies: []const []const u8) ![]u8 {
    const cam = function(template, "initCamera") orelse "";
    var heroes: std.ArrayList(u8) = .empty;
    defer heroes.deinit(gpa);
    if (function(template, "restore")) |body| {
        var it = std.mem.splitScalar(u8, body, '\n');
        while (it.next()) |raw| {
            const l = std.mem.trim(u8, raw, " \t\r");
            const head = "PlaceActor(\"";
            if (!std.mem.startsWith(u8, l, head)) continue;
            const end = std.mem.indexOfScalarPos(u8, l, head.len, '"') orelse continue;
            const who = l[head.len..end];
            for (enemies) |e| {
                if (std.ascii.eqlIgnoreCase(e, who)) break;
            } else try heroes.print(gpa, "    {s}\n", .{l});
        }
    }
    const t = try std.fmt.allocPrint(gpa,
        \\#inherit CombatLevel
        \\
        \\{s}
        \\
        \\function init()
        \\{{
        \\}};
        \\
        \\// A battle's lines before the fight: StartDialog() here plays <this battle>.dlg.
        \\function after_select_gui()
        \\{{
        \\  GUI_SelectMode("GUI_Staging");
        \\}};
        \\
        \\// Started by a location's trigger with LEVEL_Load("<this battle>"); the game
        \\// returns there after it and calls that level's AfterBattle(level).
        \\function restore()
        \\{{
        \\{s}}};
        \\
        \\function update()
        \\{{
        \\}};
        \\
        \\function CombatEnemiesAppear()
        \\{{
        \\}};
        \\
    , .{ cam, heroes.items });
    defer gpa.free(t);
    const lf_only = try std.mem.replaceOwned(u8, gpa, t, "\r\n", "\n");
    defer gpa.free(lf_only);
    return std.mem.replaceOwned(u8, gpa, lf_only, "\n", "\r\n");
}

/// `.ar` with the entry area `capt_start`: a small triangle around `at`.
pub fn arText(gpa: Allocator, at: [2]f32) ![]u8 {
    const x: i32 = @intFromFloat(@round(at[0]));
    const y: i32 = @intFromFloat(@round(at[1]));
    return std.fmt.allocPrint(gpa, "areaCnt=1\r\nareaName: capt_start\r\npointCnt=3\r\n{d},{d},0.000000\r\n{d},{d},0.000000\r\n{d},{d},0.000000\r\ncontrolPoint: {d},{d},0.000000\r\n", .{ x - 12, y - 8, x + 12, y - 8, x, y + 10, x, y });
}

test validName {
    try std.testing.expect(validName("01_port_bar", false));
    try std.testing.expect(!validName("01__port_bar", false));
    try std.testing.expect(validName("01__port_bar", true));
    try std.testing.expect(!validName("01_port_bar", true));
    try std.testing.expect(!validName("Port", false));
    try std.testing.expect(!validName("a b", false));
}

test battleLevText {
    const gpa = std.testing.allocator;
    const tpl = "#inherit CombatLevel\r\n\r\nfunction initCamera()\r\n{\r\n    perspective=1;\r\n    cameraScale = 0;\r\n};\r\n\r\nfunction restore()\r\n{\r\n    //PlaceActor(\"Sullivan\",\"capt_start\",0);\r\n    PlaceActor(\"Trantigne\",4,1,2);\r\n    PlaceActor(\"Sullivan\",6,4,4);\r\n    PlaceActor(\"01b_sfinks\",1,5);\r\n    AIEnemyAppear(\"01b_sfinks\", -2, 5, 1, 5);\r\n};\r\n";
    const t = try battleLevText(gpa, tpl, &.{"01B_sfinks"});
    defer gpa.free(t);
    try std.testing.expect(std.mem.indexOf(u8, t, "    cameraScale = 0;\r\n};") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "{\r\n    PlaceActor(\"Trantigne\",4,1,2);\r\n    PlaceActor(\"Sullivan\",6,4,4);\r\n};") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "sfinks") == null);
    try std.testing.expect(std.mem.indexOf(u8, t, "\n\n") == null);
}

test levText {
    const gpa = std.testing.allocator;
    const tpl = "#inherit Level\r\n\r\nfunction initCamera()\r\n{\r\n\tperspective=1;\r\n};\r\n\r\nfunction init()\r\n{\r\n\tshadowActive=1;\r\n  x = 1;\r\n};\r\n";
    const t = try levText(gpa, tpl, "01_port");
    defer gpa.free(t);
    try std.testing.expect(std.mem.indexOf(u8, t, "function initCamera()\r\n{\r\n\tperspective=1;\r\n};") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "  shadowActive=1;\r\n};") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "x = 1") == null);
    try std.testing.expect(std.mem.indexOf(u8, t, "PlaceHeroes(\"capt_start\");") != null);
    try std.testing.expect(std.mem.indexOf(u8, t, "\n\n") == null);
}

/// The value of `key = <number>;` in the level script's initCamera(), if set there.
pub fn cameraVar(lev: []const u8, key: []const u8) ?f32 {
    const cam = function(lev, "initCamera") orelse return null;
    const at = assignment(cam, key) orelse return null;
    return std.fmt.parseFloat(f32, std.mem.trim(u8, cam[at[0]..at[1]], " \t")) catch null;
}

/// Where the value of `key = …;` is in `text` (a whole-word key, not in a comment).
fn assignment(text: []const u8, key: []const u8) ?[2]usize {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var off: usize = 0;
    while (lines.next()) |l| : (off += l.len + 1) {
        const t = std.mem.trimStart(u8, l, " \t");
        if (!std.mem.startsWith(u8, t, key)) continue;
        const rest = std.mem.trimStart(u8, t[key.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        const v0 = off + (l.len - rest.len) + 1;
        const semi = std.mem.indexOfScalarPos(u8, text, v0, ';') orelse continue;
        if (semi > off + l.len) continue;
        return .{ v0, semi };
    }
    return null;
}

/// `lev` with `key = value;` in initCamera(): the value replaced, or a line added
/// before its closing `};` (the camera vars the exe reads right after it, 0x4218e9).
pub fn setCameraVar(gpa: Allocator, lev: []const u8, key: []const u8, value: f32) ![]u8 {
    const cam = function(lev, "initCamera") orelse return error.NoCamera;
    const base = @intFromPtr(cam.ptr) - @intFromPtr(lev.ptr);
    var vb: [32]u8 = undefined;
    const v = try std.fmt.bufPrint(&vb, "{d:.3}", .{value});
    if (assignment(cam, key)) |at| return std.mem.concat(gpa, u8, &.{ lev[0 .. base + at[0]], " ", v, lev[base + at[1] ..] });
    const close = base + cam.len - 2; // the `};` line
    const nl = if (std.mem.indexOf(u8, lev, "\r\n") != null) "\r\n" else "\n";
    const line = try std.fmt.allocPrint(gpa, "\t{s} = {s};{s}", .{ key, v, nl });
    defer gpa.free(line);
    return std.mem.concat(gpa, u8, &.{ lev[0..close], line, lev[close..] });
}

test setCameraVar {
    const gpa = std.testing.allocator;
    const lev = "function initCamera()\r\n{\r\n\tzLevel=-0.6;\r\n};\r\n\r\nfunction init()\r\n{\r\n};\r\n";
    const a = try setCameraVar(gpa, lev, "actorScale", 0.2);
    defer gpa.free(a);
    try std.testing.expectEqualStrings("function initCamera()\r\n{\r\n\tzLevel=-0.6;\r\n\tactorScale = 0.200;\r\n};\r\n\r\nfunction init()\r\n{\r\n};\r\n", a);
    try std.testing.expectEqual(@as(f32, 0.2), cameraVar(a, "actorScale").?);
    const b = try setCameraVar(gpa, a, "actorScale", 0.25);
    defer gpa.free(b);
    try std.testing.expectEqual(@as(f32, 0.25), cameraVar(b, "actorScale").?);
    try std.testing.expectEqual(a.len, b.len);
    try std.testing.expect(cameraVar(lev, "actorScale") == null);
}

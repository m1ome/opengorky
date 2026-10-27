//! Editor settings (`editor.cfg` next to the game's `opengorky.cfg`): "key = value"
//! lines, `#` comments. The editor rewrites the whole file when a setting changes.

const std = @import("std");
const text = @import("text.zig");

pub const file_name = "editor.cfg";

/// Panes the user drags to size (points): list widths, the side panel, and on the
/// enemy/hero page the left column and the top row.
pub const Split = enum {
    levels,
    objects,
    entries,
    scenes,
    sounds,
    entry_x,
    entry_y,
    history,

    const defaults = [_]f32{ 280, 380, 320, 320, 420, 440, 460, 560 };
};

pub const Settings = struct {
    lang: text.Lang = .en,
    /// The game folder last opened from the command line, used when none is given.
    game_path_buf: [1024]u8 = undefined,
    game_path_len: usize = 0,
    /// An untouched copy of the game: a packed mod is what differs from it.
    original_path_buf: [1024]u8 = undefined,
    original_path_len: usize = 0,
    /// The port's program (or on macOS its `.app`) Play runs; none: looked for beside the editor.
    viewer_path_buf: [1024]u8 = undefined,
    viewer_path_len: usize = 0,
    splits: [Split.defaults.len]f32 = Split.defaults,

    pub fn split(self: *const Settings, k: Split) f32 {
        return self.splits[@backingInt(k)];
    }

    pub fn gamePath(self: *const Settings) ?[]const u8 {
        return if (self.game_path_len > 0) self.game_path_buf[0..self.game_path_len] else null;
    }

    pub fn setGamePath(self: *Settings, p: []const u8) void {
        const n = @min(p.len, self.game_path_buf.len);
        @memcpy(self.game_path_buf[0..n], p[0..n]);
        self.game_path_len = n;
    }

    pub fn originalPath(self: *const Settings) ?[]const u8 {
        return if (self.original_path_len > 0) self.original_path_buf[0..self.original_path_len] else null;
    }

    pub fn setOriginalPath(self: *Settings, p: []const u8) void {
        const n = @min(p.len, self.original_path_buf.len);
        @memcpy(self.original_path_buf[0..n], p[0..n]);
        self.original_path_len = n;
    }

    pub fn viewerPath(self: *const Settings) ?[]const u8 {
        return if (self.viewer_path_len > 0) self.viewer_path_buf[0..self.viewer_path_len] else null;
    }

    /// `""` clears it (back to the lookup beside the editor).
    pub fn setViewerPath(self: *Settings, p: []const u8) void {
        const n = @min(p.len, self.viewer_path_buf.len);
        @memcpy(self.viewer_path_buf[0..n], p[0..n]);
        self.viewer_path_len = n;
    }

    /// Unknown keys and bad values are ignored.
    pub fn parse(data: []const u8) Settings {
        var s: Settings = .{};
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0 or t[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
            const key = std.mem.trim(u8, t[0..eq], " \t");
            const val = std.mem.trim(u8, t[eq + 1 ..], " \t");
            if (std.mem.eql(u8, key, "language")) {
                s.lang = std.meta.stringToEnum(text.Lang, val) orelse s.lang;
            } else if (std.mem.eql(u8, key, "game_path")) {
                s.setGamePath(val);
            } else if (std.mem.eql(u8, key, "original_path")) {
                s.setOriginalPath(val);
            } else if (std.mem.eql(u8, key, "viewer_path")) {
                s.setViewerPath(val);
            } else if (std.mem.startsWith(u8, key, "split.")) {
                const k = std.meta.stringToEnum(Split, key["split.".len..]) orelse continue;
                const v = std.fmt.parseFloat(f32, val) catch continue;
                if (v >= 80 and v <= 4000) s.splits[@backingInt(k)] = v;
            }
        }
        return s;
    }

    pub fn format(self: *const Settings, buf: []u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        try w.print(
            \\# OpenGorky level editor settings.
            \\# Interface language: en, ru
            \\language = {t}
            \\# Game folder used when the editor starts without one (it edits this folder's archives)
            \\game_path = {s}
            \\# An untouched copy of the game: Package mod takes what differs from it
            \\original_path = {s}
            \\# The port's program or OpenGorky.app that Play runs (empty: the one beside the editor)
            \\viewer_path = {s}
            \\# Pane sizes (points), as dragged
            \\
        , .{ self.lang, self.gamePath() orelse "", self.originalPath() orelse "", self.viewerPath() orelse "" });
        for (self.splits, 0..) |v, k| try w.print("split.{t} = {d}\n", .{ @as(Split, @fromBackingInt(@intCast(k))), @round(v) });
        return w.buffered();
    }
};

/// The program to run for viewer path `p`: a macOS `.app` bundle's binary inside it, else `p` itself.
pub fn viewerProgram(buf: []u8, p: []const u8, exe: []const u8) []const u8 {
    const t = std.mem.trimEnd(u8, p, "/");
    if (!std.ascii.endsWithIgnoreCase(t, ".app")) return p;
    return std.fmt.bufPrint(buf, "{s}/Contents/MacOS/{s}", .{ t, exe }) catch p;
}

test "settings: viewer path, .app to its binary" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/A/OpenGorky.app/Contents/MacOS/opengorky-viewer", viewerProgram(&buf, "/A/OpenGorky.app/", "opengorky-viewer"));
    try std.testing.expectEqualStrings("/b/opengorky-viewer", viewerProgram(&buf, "/b/opengorky-viewer", "opengorky-viewer"));
    var s = Settings.parse("viewer_path = /A/OpenGorky.app\n");
    var fb: [2048]u8 = undefined;
    try std.testing.expectEqualStrings("/A/OpenGorky.app", Settings.parse(try s.format(&fb)).viewerPath().?);
    s.setViewerPath("");
    try std.testing.expect(Settings.parse(try s.format(&fb)).viewerPath() == null);
}

test "settings: parse, format back" {
    const s = Settings.parse("# x\nlanguage = ru\ngame_path = /a b/Gorky\noriginal_path = /o\nbad\n");
    try std.testing.expectEqual(text.Lang.ru, s.lang);
    try std.testing.expectEqualStrings("/a b/Gorky", s.gamePath().?);
    var buf: [2048]u8 = undefined;
    const back = Settings.parse(try s.format(&buf));
    try std.testing.expectEqual(s.lang, back.lang);
    try std.testing.expectEqualStrings(s.gamePath().?, back.gamePath().?);
    try std.testing.expectEqualStrings("/o", back.originalPath().?);
    try std.testing.expectEqual(text.Lang.en, Settings.parse("language = xx\n").lang);
    var sp = Settings.parse("split.entry_x = 610\nsplit.nope = 3\nsplit.levels = 5\n");
    try std.testing.expectEqual(610, sp.split(.entry_x));
    try std.testing.expectEqual(Split.defaults[0], sp.split(.levels));
    sp = Settings.parse(try sp.format(&buf));
    try std.testing.expectEqual(610, sp.split(.entry_x));
}

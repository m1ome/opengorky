//! Scene data: world state `w.scene` and the `Runner` player, without logic
//! (steps/commands in scene/scenario.zig, start/tick in scene/scenes.zig).

const std = @import("std");
const scriptlet = @import("../formats.zig").scriptlet;
const dialog_fmt = @import("../formats.zig").dialog;
const Object = @import("../script.zig").object.Object;
const Font = @import("../formats.zig").font.Font;

const Subtitle = struct { speaker: []const u8, text: []const u8 };

/// One subtitle page: up to 2 lines (byte ranges of the text) and where the next page starts.
const Page = struct { lines: [2][2]u32 = @splat(.{ 0, 0 }), n: u8 = 0, to: u32 = 0 };

/// Scene ROCKET missile (0x476e9f).
const Rocket = struct { id: u32, target: [3]f32 };

/// Scenes, dialogues and their display: world state `w.scene`.
pub const State = struct {
    runner: ?Runner = null,
    /// The location's own scene (pre-battle dialogue) paused by an incoming scene;
    /// resumes after it.
    paused: ?Runner = null,
    /// Scenes waiting for a DialogInit dialogue to end (a GUI window in the exe, which
    /// StartScriptlet does not interrupt).
    queue: std.ArrayList([]const u8) = .empty,
    /// Deferred scene (SetAddonScriptlet / ADDONSCRIPTLET; 0x5266a8): one slot, the newest
    /// wins; starts when the current one ends (0x4791a9).
    addon: ?[]const u8 = null,
    /// Parsed scenes and dialogues by name: ladders and DIALOG_INIT reuse them and the
    /// location arena lives all session (commands are read-only).
    scriptlet_cache: std.StringHashMapUnmanaged(struct { cmds: []const scriptlet.Command, pts: []const scriptlet.Point }) = .empty,
    dialog_cache: std.StringHashMapUnmanaged(dialog_fmt.Dialog) = .empty,
    /// ROCKET missiles: effect projectile id and blast point.
    rockets: std.ArrayList(Rocket) = .empty,
    /// The scene used MP3_PLAY: restore the previous music when it ends.
    mp3: bool = false,
    subtitle: ?Subtitle = null,
    /// The shown line's `#CAM` scroll in a level's own dialogue (StartDialog / DialogInit:
    /// loader flag +0x218 = 0); a scene's DIALOG_INIT (flag 1) has none.
    dialog_cam: ?[2]i32 = null,
    /// A line is shown (the DIALOG_DISPLAY wait holds while it is).
    line_open: bool = false,
    /// Pages of the current line (`splitPages`) and the one shown (+0x2c4).
    pages: [16]Page = @splat(.{}),
    subtitle_pages: u32 = 1,
    subtitle_page: u32 = 0,
    /// Line duration in seconds (+0x220; 0 = waits for a click), per-page times
    /// (+0x230) and the page counter (+0x228).
    line_secs: f64 = 0,
    page_secs: [16]f32 = @splat(0),
    page_t: f64 = 0,
    /// Panorama bar height (gui_panorama_height = 42; slides out on PANORAMA_OFF).
    panorama_h: f32 = 42,
    /// Screen fade 0..1 and its target.
    fade: f32 = 0,
    fade_target: f32 = 0,
    /// Letterbox bars, and a scene without player control.
    panorama: bool = false,
    cutscene: bool = false,
    /// Scene camera mode (AUTOCAMERA_OFF, `[0x651cac]`): false = DOLLY drives it; true =
    /// it follows the party centre.
    autocamera: bool = true,
    /// Signature(n) caption: `intro.spr` frame and start tick.
    signature: ?struct { frame: u32, start: u64 } = null,
    /// Hero of the last action (#LAST_ACTION_HERO in scenes).
    last_action_hero: []const u8 = "Sullivan",
    /// Pre-battle dialogue deferred until enemies have appeared (name, file).
    pending_dialog: ?[2][]const u8 = null,

    /// Drops scenes started by post_init while recreating a location for a load. The exe
    /// load (0x472400) also recreates it via 0x41f090 → 0x431830 with init() vars, and
    /// scripts don't reset "first visit" flags (cutsceneStart in 05_laboratory stays 1,
    /// "winda" in 04_city_elevator is unconditional). We keep the saved state on top, so
    /// a first-visit scene after loading would be wrong (lab-enter replayed the Lamar talk,
    /// winda re-enabled heroes). Saves are written outside scenes, so nothing is lost.
    /// Deviation: the exe apparently keeps such a scene (load doesn't touch list 0x68b154).
    pub fn dropForLoad(self: *State) void {
        self.runner = null;
        self.paused = null;
        self.addon = null;
        self.queue.clearRetainingCapacity();
        self.cutscene = false;
        self.panorama = false;
        self.autocamera = true;
    }

    /// Split `text` into pages exactly as the dialog box draws them (0x459b40):
    /// 2 lines of width 395, spaces after a cut skipped. No font: one page.
    pub fn splitPages(self: *State, font: ?*const Font, text: []const u8) void {
        self.subtitle_page = 0;
        const f = font orelse {
            self.pages[0] = .{ .lines = .{ .{ 0, @intCast(text.len) }, undefined }, .n = 1, .to = @intCast(text.len) };
            self.subtitle_pages = 1;
            return;
        };
        var np: usize = 0;
        var from: usize = 0;
        while (from < text.len and np < self.pages.len) : (np += 1) {
            const pg = &self.pages[np];
            pg.n = 0;
            while (pg.n < 2 and from < text.len) : (pg.n += 1) {
                const to = from + f.lineCut(text[from..], 395);
                pg.lines[pg.n] = .{ @intCast(from), @intCast(to) };
                from = to;
                while (from < text.len and text[from] == ' ') from += 1;
            }
            pg.to = @intCast(from);
        }
        self.subtitle_pages = @intCast(np);
    }

    /// Line timing (0x4597d0): each page but the last gets its share of characters
    /// of `secs`; the last gets the rest + 0.5 s. `secs` 0 = no timing.
    pub fn timeLine(self: *State, text_len: usize, secs: f64) void {
        self.line_secs = secs;
        self.page_t = 0;
        if (secs <= 0) return;
        const len: f64 = @as(f32, @floatFromInt(text_len));
        var rest: f32 = @floatCast(secs);
        for (0..self.subtitle_pages) |i| {
            if (i + 1 == self.subtitle_pages) {
                self.page_secs[i] = rest + 0.5;
                break;
            }
            const pg = self.pages[i];
            const t = @as(f64, @floatFromInt(pg.to - pg.lines[0][0])) / len * secs;
            self.page_secs[i] = @floatCast(t);
            rest = @floatCast(@as(f64, rest) - t);
        }
    }

    /// Next page, or the line ends (0x4593c0).
    pub fn nextPage(self: *State) void {
        if (self.subtitle_page + 1 < self.subtitle_pages) self.subtitle_page += 1 else self.line_open = false;
    }

    /// Per tick (0x459a7a): +0.033333 s; the page turns once its time is reached.
    pub fn tickLine(self: *State) void {
        if (!self.line_open or self.line_secs <= 0) return;
        self.page_t += 0.033333;
        if (self.page_t < self.page_secs[self.subtitle_page]) return;
        self.page_t = 0;
        self.nextPage();
    }
};

test "timeLine: pages share the time by characters, the last gets +0.5 s" {
    var st: State = .{ .line_open = true, .subtitle_pages = 2 };
    st.pages[0] = .{ .n = 2, .to = 30 };
    st.pages[1] = .{ .lines = .{ .{ 30, 40 }, undefined }, .n = 1, .to = 40 };
    st.timeLine(40, 2.0);
    try std.testing.expectEqual(@as(f32, 1.5), st.page_secs[0]);
    try std.testing.expectEqual(@as(f32, 1.0), st.page_secs[1]);
    var ticks: u32 = 0;
    while (st.line_open) : (ticks += 1) st.tickLine();
    try std.testing.expectEqual(46 + 31, ticks);
}

test "splitPages: 2 lines per page, one page without a font" {
    var st: State = .{};
    st.splitPages(null, "abc def");
    try std.testing.expectEqual(1, st.subtitle_pages);
    try std.testing.expectEqual(7, st.pages[0].to);
    // Glyphs 2 px wide advance 1 px: 100 words of 10 chars → lines of 390, 3 lines, 2 pages.
    const px = [_]u8{ 1, 1 };
    var f: Font = .{ .glyphs = @splat(null), .height = 1, .max_level = 1 };
    f.glyphs['a'] = .{ .width = 2, .height = 1, .pixels = &px };
    f.glyphs[' '] = .{ .width = 2, .height = 1, .pixels = &px };
    var buf: [999]u8 = undefined;
    for (&buf, 0..) |*ch, i| ch.* = if (i % 10 == 9) ' ' else 'a';
    const text: []const u8 = &buf;
    st.subtitle_page = 5;
    st.splitPages(&f, text);
    try std.testing.expectEqual(0, st.subtitle_page);
    try std.testing.expectEqual(2, st.subtitle_pages);
    try std.testing.expectEqual(2, st.pages[0].n);
    try std.testing.expectEqual(390, st.pages[0].lines[1][0]);
    try std.testing.expectEqual(1, st.pages[1].n);
    try std.testing.expectEqual(999, st.pages[1].to);
}

pub const Runner = struct {
    name: []const u8,
    commands: []const scriptlet.Command,
    points: []const scriptlet.Point,
    pc: usize = 0,
    wait: union(enum) {
        none,
        ticks: u32,
        actor: *Object,
        dialog,
        /// WAITFORANIMATION: the ABA animation finished (state 0 or 2).
        aba: *Object,
        /// LOADLEVEL / PREVLEVEL: the scene continues on the new location (one scene
        /// player in the exe); moved by `scenes.takeMovingScene`.
        moving,
        /// PANORAMA_OFF: bars slide out 2 px per tick.
        panorama,
        /// ACTOR_GOINDOWN: actor z moves to the target by one step per tick.
        goindown: struct { o: *Object, z: f32, step: f32 },
    } = .none,
    /// Scene skip (0x479220): run the remaining commands without waits.
    skip: bool = false,
    /// NO_SKIP: the scene can't be skipped.
    no_skip: bool = false,
    dialog: ?dialog_fmt.Dialog = null,
    dialog_file: []const u8 = "",

    pub fn done(self: Runner) bool {
        return self.pc >= self.commands.len and self.wait == .none;
    }

    pub fn point(self: Runner, name: []const u8) ?scriptlet.Point {
        for (self.points) |p| if (std.ascii.eqlIgnoreCase(p.name, name)) return p;
        return null;
    }
};

/// gui_panorama_height (adjust.kdt, 42): the panorama bar's height.
pub fn panoramaHeight() f32 {
    return @floatFromInt(@import("../formats.zig").adjust.getInt("gui_panorama_height", 42));
}

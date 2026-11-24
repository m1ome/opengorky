//! Port settings (`opengorky.cfg`) that the exe lacks: window output and debugging.
//! Text file, "key = value", `#` lines are comments. If missing, it is created
//! with defaults and explanations.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const Scaling = enum {
    /// Integer 640×480 zoom: crisp pixels, possible borders.
    integer,
    /// Whole window, sharp pixels (SDL 3.4 PIXELART, else smoothing).
    sharp,
    /// Whole window, smoothed.
    smooth,
    /// Whole window/screen, smoothed, 4:3 stretched to its shape (no borders, distorted).
    stretch,
    /// Wide window: large locations show more of the background at the sides,
    /// narrower levels (battles, rooms) are zoomed in to fill the width (top and
    /// bottom scroll); the UI stays the middle 640×480. Screens without the world
    /// (menu, inventory, video) stand over a blurred copy, as `stretch-blur`.
    adaptive,
    /// `smooth` with the borders filled by a blurred, darkened copy of the frame
    /// stretched over the whole window.
    @"stretch-blur",
};

pub const Log = enum { none, warn, info };

/// Who draws the models, shadows and effects.
pub const Renderer = enum {
    /// The software rasterizer (on the CPU threads).
    cpu,
    /// SDL GPU (Metal, Vulkan); without such a device, the CPU.
    gpu,
};

/// 2D upscaling (icons, portraits, panels, cursor) with `hires`.
pub const Upscale = enum {
    /// Smoothing xBR: smooth edges without blur.
    xbr,
    /// As in the original: the same pixels, upscaled without smoothing.
    off,
};

/// A path in a fixed buffer (the settings files' folders; the editor's too).
pub const PathBuf = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn get(self: *const PathBuf) []const u8 {
        return self.buf[0..self.len];
    }

    /// A path longer than the buffer is dropped (left unset): a cut path would point elsewhere.
    pub fn set(self: *PathBuf, p: []const u8) void {
        if (p.len > self.buf.len) {
            std.log.warn("path longer than {d} bytes ignored: {s}...", .{ self.buf.len, p[0..64] });
            self.len = 0;
            return;
        }
        self.len = p.len;
        @memcpy(self.buf[0..self.len], p);
    }
};

pub const Config = struct {
    scaling: Scaling = .integer,
    /// Models, shadows and effects at window resolution (the frame is drawn an
    /// integer times larger than 640×480; background and UI keep their pixels). The exe draws 640×480.
    hires: bool = true,
    /// UI and icons with `hires`: smoothing upscale or the original pixels.
    upscale: Upscale = .xbr,
    renderer: Renderer = .cpu,
    fullscreen: bool = false,
    /// Debug text: battle status line, health bars, F1 line.
    debug: bool = false,
    /// Messages to the terminal.
    log: Log = .warn,
    /// Frame cap in the focused window; 0 — display rate (vsync). The world runs
    /// at 30 ticks per second regardless.
    fps_limit: u32 = 60,
    /// Frame cap when unfocused; 0 — same as focused. A minimised or fully covered
    /// window is not drawn at all.
    fps_background: u32 = 15,
    /// Unfocused (or minimised) window pauses the world and audio.
    pause_background: bool = true,
    /// Developer console (` or F2) in the game: 0 — unavailable (clean game without
    /// debug commands), 1 — available. Launch options (--console, --input, --dev) and
    /// the resource viewer (without --play) work regardless.
    console: bool = false,
    /// The launcher window (game folder and these settings) when the game is started
    /// without arguments; with 0 it is skipped (Shift at startup shows it anyway).
    launcher: bool = true,
    /// Game directory (with dat and avi): used when no path is given at launch;
    /// empty — unset. The first launch with a path stores it here.
    game_path: PathBuf = .{},
    /// The OpenGorky package Play starts (its file name in a `mods/` folder: app/packages.zig);
    /// empty — the original game.
    package: PathBuf = .{},

    pub fn gamePath(self: *const Config) []const u8 {
        return self.game_path.get();
    }

    pub fn setGamePath(self: *Config, path: []const u8) void {
        self.game_path.set(path);
    }

    /// Parses the file text; unknown keys and errors are skipped (no file is touched:
    /// the editor reads the viewer's `game_path` with it).
    pub fn parse(text: []const u8) Config {
        var cfg: Config = .{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (std.mem.eql(u8, key, "scaling")) {
                // adaptive-blur / adaptive-fill of earlier builds: now adaptive.
                cfg.scaling = std.meta.stringToEnum(Scaling, val) orelse if (std.mem.startsWith(u8, val, "adaptive")) .adaptive else cfg.scaling;
            } else if (std.mem.eql(u8, key, "hires")) {
                cfg.hires = flag(val) orelse cfg.hires;
            } else if (std.mem.eql(u8, key, "upscale")) {
                cfg.upscale = std.meta.stringToEnum(Upscale, val) orelse cfg.upscale;
            } else if (std.mem.eql(u8, key, "renderer")) {
                cfg.renderer = std.meta.stringToEnum(Renderer, val) orelse cfg.renderer;
            } else if (std.mem.eql(u8, key, "fullscreen")) {
                cfg.fullscreen = flag(val) orelse cfg.fullscreen;
            } else if (std.mem.eql(u8, key, "debug")) {
                cfg.debug = flag(val) orelse cfg.debug;
            } else if (std.mem.eql(u8, key, "log")) {
                cfg.log = std.meta.stringToEnum(Log, val) orelse cfg.log;
            } else if (std.mem.eql(u8, key, "fps_limit")) {
                cfg.fps_limit = std.fmt.parseInt(u32, val, 10) catch cfg.fps_limit;
            } else if (std.mem.eql(u8, key, "game_path")) {
                cfg.setGamePath(val);
            } else if (std.mem.eql(u8, key, "package")) {
                cfg.package.set(val);
            } else if (std.mem.eql(u8, key, "console")) {
                cfg.console = flag(val) orelse cfg.console;
            } else if (std.mem.eql(u8, key, "launcher")) {
                cfg.launcher = flag(val) orelse cfg.launcher;
            } else if (std.mem.eql(u8, key, "pause_background")) {
                cfg.pause_background = flag(val) orelse cfg.pause_background;
            } else if (std.mem.eql(u8, key, "fps_background")) {
                cfg.fps_background = std.fmt.parseInt(u32, val, 10) catch cfg.fps_background;
            }
        }
        return cfg;
    }

    fn flag(v: []const u8) ?bool {
        if (std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "on") or std.ascii.eqlIgnoreCase(v, "true")) return true;
        if (std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "off") or std.ascii.eqlIgnoreCase(v, "false")) return false;
        return null;
    }

    /// File text with explanations.
    pub fn format(self: Config, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf,
            \\# OpenGorky port settings (not in the original). Applied at startup;
            \\# F10 and fullscreen toggles during play are saved here too.
            \\
            \\# Scaling of the 640×480 frame:
            \\#   integer — integer scaling (crisp pixels, may leave borders)
            \\#   sharp   — fill the window, sharp pixels
            \\#   smooth  — fill the window, smoothed
            \\#   stretch — stretch to the whole window/screen, no borders (4:3 distorted on 16:9)
            \\#   adaptive — wide window: large locations show more at the sides, battles
            \\#              and rooms zoomed in to fill the width (top and bottom scroll
            \\#              with the mouse at the edges); the UI stays in the middle;
            \\#              menu and inventory over a blurred copy
            \\#   stretch-blur — 4:3 in the middle over a blurred stretched copy (no black borders)
            \\scaling = {t}
            \\
            \\# Models, shadows and effects at window resolution: 1 — yes, 0 — 640×480 as the original
            \\hires = {d}
            \\
            \\# UI, icons and portraits with hires: xbr — smoothed edges (xBR),
            \\# off — original pixels, just larger
            \\upscale = {t}
            \\
            \\# Models, shadows and effects drawn by: cpu — the processor (works everywhere),
            \\# gpu — the video card (faster with detailed models; cpu where there is none)
            \\renderer = {t}
            \\
            \\# Fullscreen: 1 — yes, 0 — window (in game: F11, Alt+Enter, Cmd+Enter, Ctrl+Cmd+F)
            \\fullscreen = {d}
            \\
            \\# Debug overlays: battle status line, health bars, F1 line
            \\debug = {d}
            \\
            \\# Terminal messages: none, warn, info
            \\log = {t}
            \\
            \\# Frames per second in the active window: 0 — display rate; 60 or 30 save battery
            \\# (the world still runs at 30 ticks per second, as the original)
            \\fps_limit = {d}
            \\
            \\# Frames per second when the window is not focused: 0 — same as active.
            \\# A minimized or fully covered window is not drawn at all
            \\fps_background = {d}
            \\
            \\# Window unfocused or minimized: game and sound pause (1) or keep running (0)
            \\pause_background = {d}
            \\
            \\# Developer console (` or F2): 0 — off, 1 — on (debug commands: heal,
            \\# win the battle, give items, etc.)
            \\console = {d}
            \\
            \\# Launcher window at startup (game folder and these settings): 1 — show,
            \\# 0 — start the game at once (hold Shift while starting to show it anyway)
            \\launcher = {d}
            \\
            \\# Game directory (with dat and avi), used when no path is given at startup
            \\game_path = {s}
            \\
            \\# OpenGorky package to play (a .ogp file in the game's or this folder's mods/):
            \\# empty — the original game
            \\package = {s}
            \\
        , .{ self.scaling, @intFromBool(self.hires), self.upscale, self.renderer, @intFromBool(self.fullscreen), @intFromBool(self.debug), self.log, self.fps_limit, self.fps_background, @intFromBool(self.pause_background), @intFromBool(self.console), @intFromBool(self.launcher), self.gamePath(), self.package.get() });
    }

    /// Reads `path`; creates it with defaults only if the file does not exist.
    pub fn load(io: Io, gpa: std.mem.Allocator, dir: []const u8, path: []const u8) Config {
        const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 16)) catch |e| {
            const cfg: Config = .{};
            // Only when missing: otherwise (too big, no access) we'd overwrite the player's settings.
            if (e == error.FileNotFound) cfg.save(io, dir, path);
            return cfg;
        };
        defer gpa.free(data);
        const cfg = parse(data);
        // Old file without new keys: append them (the player's values are kept).
        for (keys) |k| {
            if (!hasKey(data, k)) {
                cfg.save(io, dir, path);
                break;
            }
        }
        return cfg;
    }

    const keys = [_][]const u8{ "scaling", "hires", "upscale", "renderer", "fullscreen", "debug", "log", "fps_limit", "fps_background", "pause_background", "console", "launcher", "game_path", "package" };

    fn hasKey(data: []const u8, key: []const u8) bool {
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0 or t[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
            if (std.mem.eql(u8, std.mem.trim(u8, t[0..eq], " \t"), key)) return true;
        }
        return false;
    }

    /// `format` buffer: the ~2.7 KB template plus the longest `game_path`, with room
    /// for new options (the test "format fits" fails before saving silently would).
    const text_max = 8192;

    /// Writes the file; a failure is logged (the settings stay in memory).
    pub fn save(self: Config, io: Io, dir: []const u8, path: []const u8) void {
        self.trySave(io, dir, path) catch |err| std.log.warn("{s}: not saved: {t}", .{ path, err });
    }

    fn trySave(self: Config, io: Io, dir: []const u8, path: []const u8) !void {
        var buf: [text_max]u8 = undefined;
        const text = try self.format(&buf);
        try Io.Dir.cwd().createDirPath(io, dir);
        try writeAtomic(io, path, text);
    }
};

/// Write through `<path>.tmp` and rename, so an interrupted write keeps the old file.
pub fn writeAtomic(io: Io, path: []const u8, data: []const u8) !void {
    var tb: [600]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tb, "{s}.tmp", .{path});
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data });
    try Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), path, io);
}

test "hasKey" {
    try std.testing.expect(Config.hasKey("# hires = 1\nscaling = smooth\n", "scaling"));
    try std.testing.expect(!Config.hasKey("# hires = 1\nscaling = smooth\n", "hires"));
}

test "parse config" {
    const cfg = Config.parse("# x\nscaling = smooth\nfullscreen=1\ndebug = on\nlog = none\nupscale = off\nfps_limit = 60\nfps_background = 0\nbad\n");
    try std.testing.expectEqual(Scaling.smooth, cfg.scaling);
    try std.testing.expectEqual(Scaling.stretch, Config.parse("scaling = stretch\n").scaling);
    try std.testing.expectEqual(Scaling.adaptive, Config.parse("scaling = adaptive-fill\n").scaling);
    try std.testing.expect(cfg.fullscreen);
    try std.testing.expect(cfg.debug);
    try std.testing.expectEqual(Log.none, cfg.log);
    try std.testing.expectEqual(Upscale.off, cfg.upscale);
    try std.testing.expectEqual(Renderer.gpu, Config.parse("renderer = gpu\n").renderer);
    try std.testing.expectEqual(Renderer.cpu, Config.parse("renderer = vulkan\n").renderer);
    try std.testing.expectEqual(@as(u32, 60), cfg.fps_limit);
    try std.testing.expectEqual(@as(u32, 0), cfg.fps_background);
    var buf: [4096]u8 = undefined;
    const back = Config.parse(try cfg.format(&buf));
    try std.testing.expectEqual(cfg, back);
    try std.testing.expect(!Config.parse("pause_background = false\n").pause_background);
    try std.testing.expect(Config.parse("pause_background = junk\n").pause_background);
    try std.testing.expect(!Config.parse("launcher = 0\n").launcher);
    try std.testing.expect(Config.parse("").launcher);
}

test "format fits with the longest path and room to grow" {
    var cfg: Config = .{ .scaling = .@"stretch-blur", .fps_limit = std.math.maxInt(u32), .fps_background = std.math.maxInt(u32) };
    const longest: [1024]u8 = @splat('p');
    cfg.setGamePath(&longest);
    try std.testing.expectEqual(@as(usize, 1024), cfg.gamePath().len);
    var buf: [Config.text_max]u8 = undefined;
    const text = try cfg.format(&buf);
    // Half the buffer stays free: a few new options must not reach the limit.
    try std.testing.expect(text.len < Config.text_max / 2);
    try std.testing.expectEqual(cfg, Config.parse(text));
}

test "save round-trip; a write error is returned, not lost" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var db: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&db, ".zig-cache/tmp/{s}/sub", .{tmp.sub_path});
    var pb: [160]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/opengorky.cfg", .{dir});
    var cfg: Config = .{ .scaling = .sharp, .debug = true, .fps_limit = 0, .launcher = false };
    cfg.setGamePath("/games/Gorky 17");
    try cfg.trySave(io, dir, path);
    try std.testing.expectEqual(cfg, Config.load(io, std.testing.allocator, dir, path));
    var mb: [160]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, cfg.trySave(io, dir, try std.fmt.bufPrint(&mb, "{s}/missing/opengorky.cfg", .{dir})));
}

/// Saves directory: macOS ~/Library/Application Support/OpenGorky/saves,
/// Windows %APPDATA%\OpenGorky\saves, else $XDG_DATA_HOME/opengorky/saves or
/// ~/.local/share/opengorky/saves; $OPENGORKY_SAVES overrides them.
/// Config directory: macOS ~/Library/Application Support/OpenGorky, Windows
/// %APPDATA%\OpenGorky, else $XDG_CONFIG_HOME/opengorky or ~/.config/opengorky.
pub fn configDir(buf: []u8, env: *std.process.Environ.Map) ?[]const u8 {
    if (builtin.os.tag == .windows) return std.fmt.bufPrint(buf, "{s}/OpenGorky", .{env.get("APPDATA") orelse return null}) catch null;
    const home = env.get("HOME") orelse return null;
    if (builtin.os.tag == .macos) return std.fmt.bufPrint(buf, "{s}/Library/Application Support/OpenGorky", .{home}) catch null;
    if (env.get("XDG_CONFIG_HOME")) |x| return std.fmt.bufPrint(buf, "{s}/opengorky", .{x}) catch null;
    return std.fmt.bufPrint(buf, "{s}/.config/opengorky", .{home}) catch null;
}

pub fn savesDir(buf: []u8, env: *std.process.Environ.Map) ?[]const u8 {
    // Own directory (shots on save copies, without touching the game's).
    if (env.get("OPENGORKY_SAVES")) |x| return std.fmt.bufPrint(buf, "{s}", .{x}) catch null;
    if (builtin.os.tag == .windows) return std.fmt.bufPrint(buf, "{s}/OpenGorky/saves", .{env.get("APPDATA") orelse return null}) catch null;
    const home = env.get("HOME") orelse return null;
    if (builtin.os.tag == .macos) return std.fmt.bufPrint(buf, "{s}/Library/Application Support/OpenGorky/saves", .{home}) catch null;
    if (env.get("XDG_DATA_HOME")) |x| return std.fmt.bufPrint(buf, "{s}/opengorky/saves", .{x}) catch null;
    return std.fmt.bufPrint(buf, "{s}/.local/share/opengorky/saves", .{home}) catch null;
}

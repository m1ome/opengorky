//! Viewer command line options (`opengorky-viewer <game> [archive] [options]`).

const std = @import("std");
const og = @import("opengorky");
const config = @import("config.zig");
const level_view = @import("../level.zig");

const screen_w = og.state.world.screen_w;
const screen_h = og.state.world.screen_h;

pub const Options = struct {
    game_dir: []const u8,
    archive: ?[]const u8 = null,
    image: usize = 0,
    level: bool = false,
    hide_objects: bool = false,
    /// For --shot: enable layers (like the M and R keys).
    walk_layer: u2 = 0,
    areas: bool = false,
    /// Game mode: main menu, new game, saves.
    play: bool = false,
    /// --no-sfx: no sound effects or voices (music plays); --mute: no sound.
    no_sfx: bool = false,
    /// Frame detail (1–4); 0 — by window in the game, 1 in shots and runs.
    hires: u32 = 0,
    /// --upscale xbr|off: UI upscaling instead of the `upscale` setting.
    upscale: ?config.Upscale = null,
    /// Window size in points (`--window W,H`).
    window: [2]c_int = .{ screen_w * 2, screen_h * 2 },
    mute: bool = false,
    /// --perf: print average frame part times on exit.
    perf: bool = false,
    /// --active: treat the window as focused (measurements: a terminal-launched window isn't).
    active: bool = false,
    /// --fps N: frame cap instead of `fps_limit` (0 — by display).
    fps: ?u32 = null,
    /// --quit-after N: quit after N seconds (CPU and energy measurements in a visible window).
    quit_after: ?u64 = null,
    /// --auto-detail: window-based detail in --input runs too (speed measurement).
    auto_detail: bool = false,
    load_slot: ?usize = null,
    /// Debug: input script in the interactive loop (hidden window), see app/input_script.zig.
    input: ?[]const u8 = null,
    heroes: bool = false,
    debug: level_view.Debug = .{},
    /// For --shot: console commands (after the level loads).
    console_cmds: [24][]const u8 = undefined,
    n_console: usize = 0,
    /// --dev: the developer console is available with `console = 0` in the settings.
    dev: bool = false,
    /// For --shot: frame of video avi\<name> at --time.
    video: ?[]const u8 = null,
    /// Frame series (`--frames N --frames-dir DIR`): N frames by world and camera tick
    /// into DIR/000.png… — for attack and effect GIFs.
    frames: u32 = 0,
    frames_dir: ?[]const u8 = null,
    scroll: [2]f32 = .{ 0, 0 },
    shot: ?[]const u8 = null,
    /// For --shot: how many ms of animation to run before the shot.
    time_ms: u64 = 0,
};

pub const usage = "usage: opengorky-viewer <game-dir> [archive, e.g. 01_port/sprite.dat] [--image N] [--level] [--hide-objects] [--walk 1|2] [--areas] [--heroes] [--play] [--load-slot N] [--console CMD] [--scroll X,Y] [--time MS] [--shot out.png] [--frames N --frames-dir DIR] [--input SCRIPT]";

pub fn parseArgs(args: []const [:0]const u8) !Options {
    var opts: Options = .{ .game_dir = undefined };
    var game_dir: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const has_value = i + 1 < args.len;
        if (std.mem.eql(u8, a, "--image") and has_value) {
            i += 1;
            opts.image = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, a, "--shot") and has_value) {
            i += 1;
            opts.shot = args[i];
        } else if (std.mem.eql(u8, a, "--time") and has_value) {
            i += 1;
            opts.time_ms = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--scroll") and has_value) {
            i += 1;
            opts.scroll = try pair(args[i]);
        } else if (std.mem.eql(u8, a, "--walk") and has_value) {
            i += 1;
            opts.walk_layer = try std.fmt.parseInt(u2, args[i], 10);
            if (opts.walk_layer > 2) return error.BadArgs;
        } else if (std.mem.eql(u8, a, "--video") and has_value) {
            i += 1;
            opts.video = args[i];
        } else if (std.mem.eql(u8, a, "--dev")) {
            opts.dev = true;
        } else if (std.mem.eql(u8, a, "--console") and has_value) {
            i += 1;
            if (opts.n_console < opts.console_cmds.len) {
                opts.console_cmds[opts.n_console] = args[i];
                opts.n_console += 1;
            }
        } else if (std.mem.eql(u8, a, "--model-scale") and has_value) {
            i += 1;
            opts.debug.scale_tweak = try std.fmt.parseFloat(f32, args[i]);
        } else if (std.mem.eql(u8, a, "--heroes")) {
            opts.heroes = true;
        } else if (std.mem.eql(u8, a, "--load-slot") and has_value) {
            i += 1;
            opts.load_slot = try std.fmt.parseInt(usize, args[i], 10);
            if (opts.load_slot == 0) return error.BadArgs; // slots start at 1
        } else if (std.mem.eql(u8, a, "--shadow-debug")) {
            opts.debug.shadow_debug = true;
        } else if (std.mem.eql(u8, a, "--no-depth")) {
            opts.debug.no_depth = true;
        } else if (std.mem.eql(u8, a, "--no-layer-cache")) {
            opts.debug.layer_cache = false;
        } else if (std.mem.eql(u8, a, "--play")) {
            opts.play = true;
        } else if (std.mem.eql(u8, a, "--window") and has_value) {
            i += 1;
            var it = std.mem.splitScalar(u8, args[i], ',');
            opts.window = .{ try std.fmt.parseInt(c_int, it.next() orelse "1280", 10), try std.fmt.parseInt(c_int, it.next() orelse "960", 10) };
        } else if (std.mem.eql(u8, a, "--upscale") and has_value) {
            i += 1;
            opts.upscale = std.meta.stringToEnum(config.Upscale, args[i]);
        } else if (std.mem.eql(u8, a, "--hires") and has_value) {
            i += 1;
            opts.hires = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--no-sfx")) {
            opts.no_sfx = true;
        } else if (std.mem.eql(u8, a, "--mute")) {
            opts.mute = true;
        } else if (std.mem.eql(u8, a, "--perf")) {
            opts.perf = true;
        } else if (std.mem.eql(u8, a, "--active")) {
            opts.active = true;
        } else if (std.mem.eql(u8, a, "--fps") and has_value) {
            i += 1;
            opts.fps = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--quit-after") and has_value) {
            i += 1;
            opts.quit_after = try std.fmt.parseInt(u64, args[i], 10);
        } else if (std.mem.eql(u8, a, "--auto-detail")) {
            opts.auto_detail = true;
        } else if (std.mem.eql(u8, a, "--frames") and has_value) {
            i += 1;
            opts.frames = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, a, "--frames-dir") and has_value) {
            i += 1;
            opts.frames_dir = args[i];
        } else if (std.mem.eql(u8, a, "--input") and has_value) {
            i += 1;
            opts.input = args[i];
        } else if (std.mem.eql(u8, a, "--areas")) {
            opts.areas = true;
        } else if (std.mem.eql(u8, a, "--hide-objects")) {
            opts.hide_objects = true;
        } else if (std.mem.eql(u8, a, "--level")) {
            opts.level = true;
        } else if (game_dir == null) {
            game_dir = a;
        } else {
            opts.archive = a;
        }
    }
    // No path: main takes it from opengorky.cfg (game_path).
    opts.game_dir = game_dir orelse "";
    return opts;
}

/// "X,Y" → a pair of numbers; missing parts are 0.
fn pair(arg: []const u8) ![2]f32 {
    var it = std.mem.splitScalar(u8, arg, ',');
    return .{ try std.fmt.parseFloat(f32, it.next() orelse "0"), try std.fmt.parseFloat(f32, it.next() orelse "0") };
}

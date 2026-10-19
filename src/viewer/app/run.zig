//! Viewer startup: settings, window, archives, subsystems, then the loop.

const std = @import("std");
const builtin = @import("builtin");
const flow = @import("flow.zig");
const viewer_mod = @import("viewer.zig");
const og = @import("opengorky");
const c = @import("sdl");
const Viewer = viewer_mod.Viewer;
const Io = std.Io;
const archive = og.formats.archive;
const perf = @import("perf.zig");
const AudioOut = @import("../media/audio.zig").AudioOut;
const Gui = @import("../gui.zig").Gui;
const InventoryView = @import("../inventory.zig").InventoryView;
const SafeView = @import("../gui/safe.zig").SafeView;
const EffectsView = @import("../level/effects_view.zig").EffectsView;
const Menu = @import("../menu.zig").Menu;
const config = @import("config.zig");
const options = @import("options.zig");
const startup = @import("startup.zig");
const InputScript = @import("input_script.zig").InputScript;
const input_ctx = @import("input_ctx.zig");
const main_loop = @import("main_loop.zig");
const shot = @import("shot.zig");
const camera_view = @import("../level/camera.zig");
const saves_ui = @import("../menu/saves.zig");
const screen_w = viewer_mod.screen_w;
const screen_h = viewer_mod.screen_h;

/// Optional UI part: on failure warn and continue without it.
fn orWarn(comptime what: []const u8, r: anytype) ?@typeInfo(@TypeOf(r)).error_union.payload {
    return r catch |err| {
        std.log.warn(what ++ ": {t}", .{err});
        return null;
    };
}

/// The directory has a dat folder, so it looks like a game directory.
fn isGameDir(io: Io, path: []const u8) bool {
    if (path.len == 0) return false;
    var d = Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    defer d.close(io);
    var dat = d.openDir(io, "dat", .{}) catch return false;
    dat.close(io);
    return true;
}

/// Windows folder prompt (the macOS bundle asks in its launcher script); null on cancel.
fn askGameDir(buf: []u8) ?[]const u8 {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return null;
    defer c.SDL_Quit();
    const Pick = struct {
        buf: []u8,
        len: usize = 0,
        done: std.atomic.Value(bool) = .init(false),
        // May run on another thread (SDL docs).
        fn picked(ud: ?*anyopaque, list: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
            const p: *@This() = @ptrCast(@alignCast(ud));
            if (list != null and list[0] != null) {
                const path = std.mem.span(list[0]);
                p.len = @min(path.len, p.buf.len);
                @memcpy(p.buf[0..p.len], path[0..p.len]);
            }
            p.done.store(true, .release);
        }
    };
    var pick: Pick = .{ .buf = buf };
    c.SDL_ShowOpenFolderDialog(Pick.picked, &pick, null, null, false);
    while (!pick.done.load(.acquire)) {
        c.SDL_PumpEvents();
        c.SDL_Delay(10);
    }
    return if (pick.len > 0) buf[0..pick.len] else null;
}

/// Game directory: from the argument, else from the settings (game_path). The old
/// separate game_path file (macOS bundle) migrates into the settings once.
fn resolveGameDir(io: Io, gpa: std.mem.Allocator, opts: *options.Options, cfg: *config.Config, cfg_dir: ?[]const u8, cfg_path: ?[]const u8) !void {
    if (cfg.game_path_len == 0) if (cfg_dir) |d| {
        var old_buf: [600]u8 = undefined;
        if (std.fmt.bufPrint(&old_buf, "{s}/game_path", .{d})) |old| {
            if (Io.Dir.cwd().readFileAlloc(io, old, gpa, .limited(4096))) |data| {
                defer gpa.free(data);
                cfg.setGamePath(std.mem.trim(u8, data, " \t\r\n"));
                if (cfg_path) |cp| cfg.save(io, d, cp);
                Io.Dir.cwd().deleteFile(io, old) catch {};
            } else |_| {}
        } else |_| {}
    };
    if (opts.game_dir.len == 0) {
        if (builtin.os.tag == .windows and opts.play and !isGameDir(io, cfg.gamePath())) {
            var buf: [1024]u8 = undefined;
            const dir = askGameDir(&buf) orelse return error.NoGameDir;
            if (!isGameDir(io, dir)) {
                _ = c.SDL_ShowSimpleMessageBox(c.SDL_MESSAGEBOX_ERROR, "OpenGorky", "The selected folder has no dat folder.", null);
                return error.NoGameDir;
            }
            cfg.setGamePath(dir);
            if (cfg_dir != null and cfg_path != null) cfg.save(io, cfg_dir.?, cfg_path.?);
        }
        if (cfg.game_path_len == 0) {
            std.log.err(options.usage, .{});
            std.log.err("game directory not set: pass it as the first argument or set game_path in {s}", .{cfg_path orelse "opengorky.cfg"});
            return error.Usage;
        }
        opts.game_dir = cfg.gamePath();
    } else if (opts.play and cfg_dir != null and cfg_path != null and !isGameDir(io, cfg.gamePath()) and isGameDir(io, opts.game_dir)) {
        // First game launch with a path (or the old path no longer works): remember it.
        cfg.setGamePath(opts.game_dir);
        cfg.save(io, cfg_dir.?, cfg_path.?);
    }
}

/// Archives that have something to show.
fn archivesWithImages(io: Io, gpa: std.mem.Allocator, dat: Io.Dir, all: []const []const u8) !std.ArrayList([]const u8) {
    var with_images: std.ArrayList([]const u8) = .empty;
    errdefer with_images.deinit(gpa);
    for (all) |p| {
        var arc = archive.Archive.open(io, gpa, dat, p) catch continue;
        defer arc.close(io, gpa);
        for (arc.entries) |e| {
            if (og.formats.resource.kindOf(e.name) != .other) break;
        } else continue;
        try with_images.append(gpa, p);
    }
    return with_images;
}

pub fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var opts = try options.parseArgs(args);
    // Windows: a double click (no arguments) starts the game, like the macOS and Linux launchers.
    if (builtin.os.tag == .windows and args.len == 1) opts.play = true;

    // Port settings (opengorky.cfg): window output, debugging, messages, game directory.
    var cfg_dir_buf: [512]u8 = undefined;
    var cfg_path_buf: [600]u8 = undefined;
    const cfg_dir = config.configDir(&cfg_dir_buf, init.environ_map);
    const cfg_path = if (cfg_dir) |d| std.fmt.bufPrint(&cfg_path_buf, "{s}/opengorky.cfg", .{d}) catch null else null;
    var cfg: config.Config = if (cfg_dir != null and cfg_path != null) config.Config.load(io, gpa, cfg_dir.?, cfg_path.?) else .{};
    try resolveGameDir(io, gpa, &opts, &cfg, cfg_dir, cfg_path);

    var game = try Io.Dir.cwd().openDir(io, opts.game_dir, .{});
    defer game.close(io);
    var dat = try game.openDir(io, "dat", .{ .iterate = true });
    defer dat.close(io);
    const all_archives = try og.formats.archive.listArchives(io, gpa, dat);
    defer og.formats.archive.freeList(gpa, all_archives);
    var with_images = try archivesWithImages(io, gpa, dat, all_archives);
    defer with_images.deinit(gpa);
    const archives = with_images.items;
    if (archives.len == 0) return error.NoArchives;

    // Mods: `<game>/mods` and `<config dir>/mods`;
    // $OPENGORKY_MODS replaces the second. Without them everything is as in the exe.
    const mods = og.world.mods;
    mods.dirs[0] = game.openDir(io, "mods", .{ .iterate = true }) catch null;
    var mods_buf: [600]u8 = undefined;
    const mods_path = init.environ_map.get("OPENGORKY_MODS") orelse if (cfg_dir) |d| std.fmt.bufPrint(&mods_buf, "{s}/mods", .{d}) catch null else null;
    if (mods_path) |mp| mods.dirs[1] = Io.Dir.cwd().openDir(io, mp, .{ .iterate = true }) catch null;
    defer for (&mods.dirs) |*d| if (d.*) |*dd| {
        dd.close(io);
        d.* = null;
    };
    // Shots (--shot) are a dev tool: info messages always.
    viewer_mod.log_level = if (opts.shot != null or opts.input != null) .info else cfg.log;

    try viewer_mod.check(c.SDL_Init(c.SDL_INIT_VIDEO));
    defer c.SDL_Quit();
    var window: ?*c.SDL_Window = null;
    var renderer: ?*c.SDL_Renderer = null;
    // HIGH_PIXEL_DENSITY: on Retina the window buffer is in real pixels; without it
    // SDL draws in points and the system stretches the frame 2× again (blurry).
    try viewer_mod.check(c.SDL_CreateWindowAndRenderer("OpenGorky viewer", opts.window[0], opts.window[1], c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | (if (opts.input != null or opts.shot != null or opts.frames > 0) c.SDL_WINDOW_HIDDEN else 0), &window, &renderer));
    defer c.SDL_DestroyWindow(window);
    defer c.SDL_DestroyRenderer(renderer);
    startup.setWindowIcon(gpa, window.?);
    try viewer_mod.check(c.SDL_SetRenderLogicalPresentation(renderer, screen_w, screen_h, c.SDL_LOGICAL_PRESENTATION_INTEGER_SCALE));
    try viewer_mod.check(c.SDL_SetRenderDrawBlendMode(renderer, c.SDL_BLENDMODE_BLEND));
    _ = c.SDL_SetRenderVSync(renderer, 1);

    // Audio: interactive mode only. The bank and mixer outlive levels.
    var mixer: og.audio.mixer.Mixer = .init(@import("../media/audio.zig").rate);
    defer mixer.deinit(gpa);
    var bank: ?og.audio.sound.Bank = null;
    defer if (bank) |*b| b.deinit();
    // Frame runs (--frames) and input scripts (--input) are silent; $OPENGORKY_MUTE=1 is --mute,
    // $OPENGORKY_NO_SFX=1 is --no-sfx (background tests stay quiet).
    const env_mute = init.environ_map.get("OPENGORKY_MUTE") != null;
    const env_no_sfx = init.environ_map.get("OPENGORKY_NO_SFX") != null;
    const silent = opts.mute or env_mute or opts.frames > 0 or opts.input != null;
    if (opts.no_sfx or env_no_sfx) {
        mixer.muted[@backingInt(og.audio.mixer.Category.sfx)] = true;
        mixer.muted[@backingInt(og.audio.mixer.Category.voice)] = true;
    }
    var audio_out: ?AudioOut = if (opts.shot == null and !silent) AudioOut.open() else null;
    defer if (audio_out) |*a| a.close();
    if (audio_out != null) bank = og.audio.sound.Bank.open(io, gpa, dat) catch null;

    var v: Viewer = .{ .io = io, .gpa = gpa, .renderer = renderer.?, .dat = dat, .archives = archives, .game_dir = opts.game_dir, .play = opts.play, .shot_run = opts.shot != null, .game = .{ .io = io, .gpa = gpa, .dat = dat, .models = null } };
    v.cfg = cfg;
    if (opts.upscale) |u| v.cfg.upscale = u;
    if (opts.fps) |f| v.cfg.fps_limit = f;
    v.detail.force = opts.hires;
    v.detail.auto = (opts.shot == null and opts.input == null and opts.frames == 0) or opts.auto_detail;
    v.cfg_dir = cfg_dir;
    v.cfg_path = cfg_path;
    if (cfg.fullscreen and opts.shot == null) _ = c.SDL_SetWindowFullscreen(window, true);
    if (bank) |*b| v.sound = .{ .bank = b, .mixer = &mixer, .params = startup.loadSoundParams(io, gpa, game) };
    v.shadows = startup.loadShadows(io, gpa, game);
    v.debug = opts.debug;
    var models: ?og.actor.model_cache.Cache = og.actor.model_cache.Cache.open(io, gpa, dat) catch null;
    defer if (models) |*m| m.deinit();
    if (models) |*m| {
        v.models = m;
        v.game.models = m;
    }
    var fx_view: ?EffectsView = if (models) |*m| EffectsView.init(gpa, renderer.?, m) else null;
    defer if (fx_view) |*f| f.deinit();
    if (fx_view) |*f| v.fx = f;
    // Dialog font: the engine's (subtitle pages), drawn by the viewer.
    v.game.loadDialogFont();
    if (v.game.dialog_font) |*f| v.font = f;
    var gui: ?Gui = Gui.load(io, gpa, renderer.?, dat) catch null;
    defer if (gui) |*g| g.deinit();
    if (gui) |*g| v.gui = g;
    var inventory: ?InventoryView = orWarn("inventory", InventoryView.load(io, gpa, renderer.?, dat));
    defer if (inventory) |*i| i.deinit();
    if (inventory) |*i| v.inventory = i;
    var safe: ?SafeView = orWarn("safe", SafeView.load(io, gpa, renderer.?, dat));
    defer if (safe) |*sv| sv.deinit();
    if (safe) |*sv| v.safe = sv;
    // Game mode: menu, saves in the user directory.
    var menu: ?Menu = if (opts.play) orWarn("menu", Menu.load(io, gpa, renderer.?, dat)) else null;
    defer if (menu) |*m| m.deinit();
    var saves_buf: [512]u8 = undefined;
    if (menu) |*m| {
        v.menu = m;
        if (inventory) |*i| m.strings = &i.strings;
        if (v.font) |f| m.text_font = f;
        v.saves_dir = config.savesDir(&saves_buf, init.environ_map);
        v.show_debug = v.cfg.debug;
        m.gains = &mixer.gains;
        m.shadows = &v.shadows;
        m.gamma = &v.gamma;
        m.models = v.models;
        saves_ui.loadOptions(&v, &mixer.gains);
        saves_ui.refreshSlots(&v);
        m.show(.main);
        // Intro videos before the menu (0x40fd06): logo1, monolith, topware, logo,
        // presents, intro — whichever exist; Esc skips all.
        if (opts.shot == null) {
            const intro = [_]og.outbox.VideoRequest{
                .{ .name = "logo1.avi", .x = -1000, .y = 0, .double = false },
                .{ .name = "monolith.avi", .x = 0, .y = 0x43, .double = false },
                .{ .name = "topware.avi", .x = 0, .y = 0x50, .double = false },
                .{ .name = "logo.avi", .x = 0x50, .y = 0x64, .double = false },
                .{ .name = "presents.avi", .x = 0xa0, .y = 0xa0, .double = false },
                .{ .name = "intro.avi", .x = 0, .y = 0x3c, .double = true },
            };
            v.video_queue.appendSlice(gpa, &intro) catch {};
            v.nextVideo();
        }
    }
    if (opts.shot == null) _ = c.SDL_HideCursor();
    defer v.deinit();
    var start: usize = 0;
    if (opts.archive) |name| {
        start = for (archives, 0..) |p, ai| {
            if (std.mem.eql(u8, p, name)) break ai;
        } else {
            std.log.err("archive not found: {s}", .{name});
            return error.ArchiveNotFound;
        };
    }
    try v.openArchive(start);
    if (opts.image > 0) try v.step(.image, @intCast(opts.image));
    if (opts.level) v.toggleLevel();
    // --play with a level and --level: straight into the game (UI shots).
    if (opts.play and opts.level and opts.archive != null) if (v.menu) |m| {
        m.open = false;
        v.video_queue.clearRetainingCapacity();
        v.stopVideo(true);
    };
    if (v.level) |*l| {
        l.show_objects = !opts.hide_objects;
        l.show_areas = opts.areas;
        if (opts.walk_layer > 0 and l.walk_textures[opts.walk_layer - 1] != null) l.walk_layer = opts.walk_layer;
        if (opts.walk_layer > 0 and l.world.combat_map != null and l.walk_textures[0] == null) l.show_grid = true;
    }
    camera_view.scrollBy(&v, opts.scroll[0], opts.scroll[1]);

    if (opts.shot) |path| return shot.run(&v, &opts, io, gpa, renderer.?, path);

    // Input script (--input): slot load and per-frame steps.
    var script: ?InputScript = null;
    if (opts.input) |arg| {
        // --input @FILE reads the script from a file (long shot series).
        const text = if (std.mem.startsWith(u8, arg, "@"))
            std.mem.trim(u8, try Io.Dir.cwd().readFileAlloc(io, arg[1..], init.arena.allocator(), .limited(1 << 20)), " \r\n")
        else
            arg;
        script = .{ .it = std.mem.splitScalar(u8, text, ';') };
        v.input_mode = true;
    }
    // Script and measurements (--quit-after): no intros; with a slot straight into the game.
    if (opts.input != null or opts.quit_after != null) {
        v.video_queue.clearRetainingCapacity();
        v.stopVideo(true);
        if (opts.load_slot) |k| {
            try flow.loadGame(&v, k - 1);
            if (v.menu) |m| m.open = false;
        }
    }
    var ev_ctx: input_ctx.Ctx = .{ .window = window.?, .renderer = renderer.?, .io = io, .mixer = &mixer, .opts = &opts };
    defer if (opts.perf) {
        var pb: [512]u8 = undefined;
        std.debug.print("{s}\n", .{perf.summary(&pb)});
    };
    const quit_at: ?u64 = if (opts.quit_after) |sec| c.SDL_GetTicks() + sec * 1000 else null;
    try main_loop.run(&v, &ev_ctx, &script, &audio_out, quit_at);
}

//! Viewer startup: settings, window, archives, subsystems, then the loop.

const std = @import("std");
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
const launcher = @import("launcher.zig");
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

/// The old separate game_path file (macOS bundle) migrates into the settings once.
fn migrateGamePath(io: Io, gpa: std.mem.Allocator, cfg: *config.Config, cfg_dir: ?[]const u8, cfg_path: ?[]const u8) void {
    if (cfg.gamePath().len == 0) if (cfg_dir) |d| {
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
}

/// Game directory: from the argument, else from the settings (game_path).
fn resolveGameDir(io: Io, a: std.mem.Allocator, opts: *options.Options, cfg: *config.Config, cfg_dir: ?[]const u8, cfg_path: ?[]const u8) !void {
    if (opts.game_dir.len == 0) {
        if (cfg.gamePath().len == 0) {
            std.log.err(options.usage, .{});
            std.log.err("game directory not set: pass it as the first argument or set game_path in {s}", .{cfg_path orelse "opengorky.cfg"});
            return error.Usage;
        }
        opts.game_dir = cfg.gamePath();
        // The package chosen in the launcher (its game: this game folder).
        if (cfg.package.get().len > 0) {
            if (@import("packages.zig").resolve(io, a, cfg.gamePath(), cfg_dir, cfg.package.get())) |p| {
                opts.game_dir = p;
            } else std.log.warn("package {s}: not in the game's or the settings' mods/ folder, the original game starts", .{cfg.package.get()});
        }
    } else if (opts.play and cfg_dir != null and cfg_path != null and !og.loaders.isGameDir(io, cfg.gamePath()) and og.loaders.isGameDir(io, opts.game_dir)) {
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

/// Project `path`'s manifest (a folder's or a package's, the OGS loader reads it); in `a`.
fn projectManifest(io: Io, a: std.mem.Allocator, path: []const u8) og.formats.manifest.Manifest {
    return .parse(og.loaders.ogs.manifestAt(io, a, path));
}

/// A project (a folder or a package) made for a newer OpenGorky: said (in a window for the
/// player) and not run.
fn refuseProject(io: Io, a: std.mem.Allocator, path: []const u8, window: bool) error{EngineTooNew} {
    const m = projectManifest(io, a, path);
    const have = og.formats.manifest.engine_version;
    var buf: [400]u8 = undefined;
    const msg = std.fmt.bufPrintSentinel(&buf, "This game folder is an OpenGorky project that needs OpenGorky {d}.{d} or newer (this one reads {d}.{d}). Update OpenGorky to play it.", .{ m.engine[0], m.engine[1], have[0], have[1] }, 0) catch "This game folder needs a newer OpenGorky.";
    std.log.err("{s}", .{msg});
    if (window) _ = c.SDL_ShowSimpleMessageBox(c.SDL_MESSAGEBOX_ERROR, "OpenGorky", msg.ptr, null);
    return error.EngineTooNew;
}

/// An OpenGorky project or package whose installed game is not there (a package handed to a
/// player names its author's folder): said, with where it was looked for and how to give
/// it (in a window for the player); null: `path` is no project, the error is another's.
fn refuseNoGame(io: Io, a: std.mem.Allocator, path: []const u8, window: bool) ?error{NoGame} {
    if (projectManifest(io, a, path).format != .ogs) return null;
    const tried = og.loaders.ogs.game_env orelse og.loaders.ogs.manifest.parse(og.loaders.ogs.manifestAt(io, a, path)).game;
    var buf: [1000]u8 = undefined;
    const args = .{ std.fs.path.basename(path), tried };
    const msg = if (systemRussian())
        std.fmt.bufPrintSentinel(&buf, "Для {s} нужна установленная Gorky 17, а в «{s}» её нет. Укажите папку Gorky 17 в окне запуска (удерживайте Shift при запуске OpenGorky) или задайте её в OPENGORKY_GAME.", args, 0) catch "Для этой игры OpenGorky нужна установленная Gorky 17: укажите её папку в окне запуска."
    else
        std.fmt.bufPrintSentinel(&buf, "{s} needs the installed Gorky 17, which is not in \"{s}\". Choose your Gorky 17 folder in the launcher (hold Shift when starting OpenGorky) or set OPENGORKY_GAME to it.", args, 0) catch "This OpenGorky game needs the installed Gorky 17: choose its folder in the launcher.";
    std.log.err("{s}", .{msg});
    if (window) _ = c.SDL_ShowSimpleMessageBox(c.SDL_MESSAGEBOX_ERROR, "OpenGorky", msg.ptr, null);
    return error.NoGame;
}

/// The player's system language is Russian (SDL's first preferred locale; SDL_PREFERRED_LOCALES
/// overrides it): refusals before a game is open say it so — there are no game texts yet
/// to take the edition's language from.
fn systemRussian() bool {
    var n: c_int = 0;
    const locs = c.SDL_GetPreferredLocales(&n) orelse return false;
    defer c.SDL_free(@ptrCast(locs));
    return n > 0 and std.mem.eql(u8, std.mem.span(locs[0].*.language), "ru");
}

/// `--start` (the game open: a test room's battle may be the project's first) as the level's
/// archive straight in, `--level --heroes --play`; the area to start at ("" none).
fn startLevel(a: std.mem.Allocator, opts: *options.Options) ![]const u8 {
    const s = opts.start orelse return "";
    const st = og.compose.og_build.Start.parse(s) catch {
        std.log.err("--start {s}: location:<level>[@<area>] | battle:<battle> | test-room:<character>[@<battle>]", .{s});
        return error.Usage;
    };
    const level = switch (st) {
        .location => |l| l.level,
        .battle => |b| b,
        .test_room => |r| if (r.battle.len > 0) r.battle else og.loaders.ogs.firstBattle() orelse {
            std.log.err("--start {s}: the project has no battle", .{s});
            return error.Usage;
        },
    };
    opts.archive = try std.fmt.allocPrint(a, "{s}/sprite.dat", .{level});
    opts.level = true;
    opts.heroes = true;
    opts.play = true;
    return if (st == .location) st.location.area else "";
}

/// The party on area `area`'s points in order (PlaceActor(hero, area, i) each), the camera
/// on the selected hero; no such area: warned, they stay where the level put them.
fn startAt(w: *og.state.world.World, area: []const u8) void {
    if (og.world.areas.findArea(w, area) == null) return std.log.warn("--start: no area {s} in {s}", .{ area, w.level_name });
    const heroes = w.party();
    for (heroes.slice(), 0..) |h, i| og.world.queue.placeAtPoint(w, h, area, @intCast(i), 0);
    w.out.camera_snap = true;
}

pub fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var opts = try options.parseArgs(args);
    // No arguments (a double click, the macOS app, `opengorky` on Linux without a path):
    // the game, through the launcher window. Any argument (tests, scripts) skips it.
    const player = args.len == 1;
    if (player) opts.play = true;

    // Port settings (opengorky.cfg): window output, debugging, messages, game directory.
    var cfg_dir_buf: [512]u8 = undefined;
    var cfg_path_buf: [600]u8 = undefined;
    const cfg_dir = config.configDir(&cfg_dir_buf, init.environ_map);
    const cfg_path = if (cfg_dir) |d| std.fmt.bufPrint(&cfg_path_buf, "{s}/opengorky.cfg", .{d}) catch null else null;
    var cfg: config.Config = if (cfg_dir != null and cfg_path != null) config.Config.load(io, gpa, cfg_dir.?, cfg_path.?) else .{};
    migrateGamePath(io, gpa, &cfg, cfg_dir, cfg_path);
    // Launcher: with `launcher = 1`, Shift held, or no usable game folder.
    if (opts.launcher_shot != null or (player and (cfg.launcher or launcher.shiftHeld() or !og.loaders.isGameDir(io, cfg.gamePath())))) {
        const start: launcher.Start = .{ .tab = opts.launcher_tab, .folder = if (opts.game_dir.len > 0) opts.game_dir else null, .shot = opts.launcher_shot };
        if (try launcher.run(io, gpa, &cfg, cfg_dir, cfg_path, start) == .exit) return;
    }
    try resolveGameDir(io, init.arena.allocator(), &opts, &cfg, cfg_dir, cfg_path);

    // The manifest, adjust.kdt and the rules, then dat (an OpenGorky project: its reader).
    // An OpenGorky project's installed game: $OPENGORKY_GAME, else the settings' game folder
    // (a player's), else its manifest's `game`.
    og.loaders.ogs.game_env = init.environ_map.get("OPENGORKY_GAME") orelse og.loaders.ogs.installedGame(io, cfg.gamePath());
    var opened = og.loaders.openGame(io, opts.game_dir) catch |err| switch (err) {
        error.EngineTooNew => return refuseProject(io, init.arena.allocator(), opts.game_dir, player),
        error.FileNotFound, error.NotDir, error.NoGame => return refuseNoGame(io, init.arena.allocator(), opts.game_dir, player) orelse err,
        else => return err,
    };
    defer opened.close(io);
    const game = opened.root;
    const dat = opened.dat;
    const manifest = opened.manifest;
    const start_area = try startLevel(init.arena.allocator(), &opts);
    const all_archives = try og.formats.archive.listArchives(io, gpa, dat);
    defer og.formats.archive.freeList(gpa, all_archives);
    var with_images = try archivesWithImages(io, gpa, dat, all_archives);
    defer with_images.deinit(gpa);
    const archives = with_images.items;
    if (archives.len == 0) return error.NoArchives;

    // Mods: `<game>/mods` and `<config dir>/mods`;
    // $OPENGORKY_MODS replaces the second. Without them everything is as in the exe.
    const mods = og.loaders.world;
    mods.mod_dirs[0] = game.openDir(io, "mods", .{ .iterate = true }) catch null;
    var mods_buf: [600]u8 = undefined;
    const mods_path = init.environ_map.get("OPENGORKY_MODS") orelse if (cfg_dir) |d| std.fmt.bufPrint(&mods_buf, "{s}/mods", .{d}) catch null else null;
    if (mods_path) |mp| mods.mod_dirs[1] = Io.Dir.cwd().openDir(io, mp, .{ .iterate = true }) catch null;
    defer for (&mods.mod_dirs) |*d| if (d.*) |*dd| {
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
    window = c.SDL_CreateWindow("OpenGorky viewer", opts.window[0], opts.window[1], c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | (if (opts.input != null or opts.shot != null or opts.frames > 0) c.SDL_WINDOW_HIDDEN else 0));
    try viewer_mod.check(window != null);
    // `renderer = gpu` (--renderer): the 2D renderer over an SDL GPU device (models then
    // drawn on it); without one, the default renderer and the software models.
    const want_gpu = (opts.renderer orelse cfg.renderer) == .gpu;
    // The device only of a driver our shaders are for (gpu/shaders: SPIR-V, MSL): Vulkan or
    // Metal — on Windows not Direct3D 12, which would take DXIL. Released after the renderer.
    const gpu_device: ?*c.SDL_GPUDevice = if (want_gpu) c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_MSL, false, null) else null;
    defer if (gpu_device) |d| c.SDL_DestroyGPUDevice(d);
    if (gpu_device) |d| {
        renderer = c.SDL_CreateGPURenderer(d, window);
        if (renderer == null) std.log.warn("no GPU renderer ({s}): models on the CPU", .{c.SDL_GetError()});
    } else if (want_gpu) std.log.warn("no Vulkan or Metal GPU device ({s}): models on the CPU", .{c.SDL_GetError()});
    if (renderer == null) renderer = c.SDL_CreateRenderer(window, null);
    try viewer_mod.check(renderer != null);
    std.log.info("renderer: {s}", .{std.mem.span(c.SDL_GetRendererName(renderer))});
    if (gpu_device) |d| std.log.info("GPU driver: {s}", .{std.mem.span(c.SDL_GetGPUDeviceDriver(d))});
    defer c.SDL_DestroyWindow(window);
    defer c.SDL_DestroyRenderer(renderer);
    // After the renderer's defer: released before its device goes.
    const gpu_models = @import("../gpu/models.zig");
    if (want_gpu) gpu_models.active = gpu_models.GpuModels.init(gpa, renderer.?);
    defer if (gpu_models.active) |g| {
        g.deinit();
        gpu_models.active = null;
    };
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
    // $OPENGORKY_RENDER_THREADS=N: model raster threads (a weak machine's, or to measure one).
    if (init.environ_map.get("OPENGORKY_RENDER_THREADS")) |t| @import("../level/layer.zig").render_threads = std.fmt.parseInt(usize, t, 10) catch null;
    const silent = opts.mute or env_mute or opts.frames > 0 or opts.input != null;
    if (opts.no_sfx or env_no_sfx) {
        mixer.muted[@backingInt(og.audio.mixer.Category.sfx)] = true;
        mixer.muted[@backingInt(og.audio.mixer.Category.voice)] = true;
    }
    var audio_out: ?AudioOut = if (opts.shot == null and !silent) AudioOut.open() else null;
    defer if (audio_out) |*a| a.close();
    if (audio_out != null or opts.mix_dump != null) bank = og.compose.sounds.open(io, gpa, dat) catch null;

    const opener: og.loaders.world.Opener = .{ .io = io, .dat = dat };
    var v: Viewer = .{ .io = io, .gpa = gpa, .renderer = renderer.?, .dat = dat, .archives = archives, .game_dir = opts.game_dir, .play = opts.play, .shot_run = opts.shot != null or opts.frames > 0, .game = .{ .io = io, .gpa = gpa, .worlds = opener.factory(), .models = null } };
    v.cfg = cfg;
    if (opts.upscale) |u| v.cfg.upscale = u;
    if (opts.fps) |f| v.cfg.fps_limit = f;
    v.detail.force = opts.hires;
    v.detail.auto = (opts.shot == null and opts.input == null and opts.frames == 0) or opts.auto_detail;
    v.cfg_dir = cfg_dir;
    v.cfg_path = cfg_path;
    if (cfg.fullscreen and opts.shot == null) _ = c.SDL_SetWindowFullscreen(window, true);
    @import("../level.zig").grid_mode = @intCast(std.math.clamp(og.rules.adjust.int("grid_mode"), 0, 2));
    if (bank) |*b| v.sound = .{ .bank = b, .mixer = &mixer, .params = startup.loadSoundParams() };
    v.shadows = startup.loadShadows();
    v.debug = opts.debug;
    var models: ?og.actor.model_cache.Cache = og.compose.models.open(io, gpa, dat, null) catch null;
    defer if (models) |*m| m.deinit();
    if (models) |*m| {
        v.models = m;
        v.game.models = m;
    }
    var textures: ?og.render.textures.Textures = if (models) |*m| og.compose.models.textures(gpa, m) else null;
    defer if (textures) |*t| t.deinit();
    if (textures) |*t| v.textures = t;
    var fx_view: ?EffectsView = if (models) |*m| EffectsView.init(gpa, renderer.?, m, &textures.?) else null;
    defer if (fx_view) |*f| f.deinit();
    if (fx_view) |*f| v.fx = f;
    // The core's classic_id texts (the UI's too) and the game's classes and heroes as its
    // records up front; the fonts below take the texts' language.
    og.loaders.loadCore(io, dat);
    // Dialog font: the engine's (subtitle pages), drawn by the viewer.
    v.font = og.loaders.loadDialogFont(io, dat);
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
        m.strings = og.loaders.textTable();
        if (v.font) |f| m.text_font = f;
        if (manifest.format == .ogs) m.mod_title = manifest.title();
        v.saves_dir = config.savesDir(&saves_buf, init.environ_map);
        v.show_debug = v.cfg.debug;
        m.gains = &mixer.gains;
        m.shadows = &v.shadows;
        m.gamma = &v.gamma;
        m.models = v.models;
        saves_ui.loadOptions(&v, &mixer.gains);
        saves_ui.refreshSlots(&v);
        m.show(.main);
        // Intro videos before the menu (0x40fd06; the campaign's startup): logo1,
        // monolith, topware, logo, presents, intro — whichever exist; Esc skips all.
        if (opts.shot == null) {
            flow.queueVideos(&v, og.rules.campaign().startup);
            v.nextVideo();
        }
    }
    if (opts.shot == null) _ = c.SDL_HideCursor();
    defer v.deinit();
    var start: usize = 0;
    if (opts.archive) |name| {
        start = for (archives, 0..) |p, ai| {
            if (og.formats.archive.samePath(p, name)) break ai;
        } else {
            std.log.err("archive not found: {s}", .{name});
            return error.ArchiveNotFound;
        };
    }
    try v.openArchive(start);
    if (opts.image > 0) try v.step(.image, @intCast(opts.image));
    if (opts.level) v.toggleLevel();
    if (start_area.len > 0) if (v.level) |*l| startAt(l.world, start_area);
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
        if (opts.walk_layer > 0 and l.world.map.combat != null and l.walk_textures[0] == null) l.show_grid = true;
    }
    camera_view.scrollBy(&v, opts.scroll[0], opts.scroll[1]);

    // --frames is a shot run of its own (it used to need --shot; without it the
    // interactive loop ran forever on the hidden window).
    if (opts.frames > 0 and v.level == null) {
        std.log.err("--frames needs a level: pass an archive and --level", .{});
        return error.Usage;
    }
    if (v.shot_run) return shot.run(&v, &opts, io, gpa, renderer.?, opts.shot orelse "");

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
    // Console commands given (`--console "scene name"`): run once the level is up, as in shots.
    for (opts.console_cmds[0..opts.n_console]) |cmd| @import("commands.zig").consoleRun(&v, cmd);
    var mix_out: std.ArrayList(f32) = .empty;
    defer {
        if (opts.mix_dump) |p| Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = std.mem.sliceAsBytes(mix_out.items) }) catch |err| std.log.warn("mix dump: {t}", .{err});
        mix_out.deinit(gpa);
    }
    var ev_ctx: input_ctx.Ctx = .{ .window = window.?, .renderer = renderer.?, .io = io, .mixer = &mixer, .opts = &opts, .mix_out = if (opts.mix_dump != null) &mix_out else null };
    defer if (opts.perf) {
        var pb: [512]u8 = undefined;
        std.debug.print("{s}\n", .{perf.summary(&pb)});
    };
    const quit_at: ?u64 = if (opts.quit_after) |sec| c.SDL_GetTicks() + sec * 1000 else null;
    try main_loop.run(&v, &ev_ctx, &script, &audio_out, quit_at);
}

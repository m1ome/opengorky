//! Viewer state (Viewer) and small methods. Level transitions, menu actions and
//! screenshots: app/flow.zig; loop, events, frame: the other app/ files. Program
//! root: viewer/main.zig.

const std = @import("std");
const gui_battle = @import("../battle/gui.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");
const level_view = @import("../level.zig");
const level_compose = @import("../level/compose.zig");
const LevelView = level_view.LevelView;
const Gui = @import("../gui.zig").Gui;
const InventoryView = @import("../inventory.zig").InventoryView;
const SafeView = @import("../gui/safe.zig").SafeView;
const EffectsView = @import("../level/effects_view.zig").EffectsView;
const Video = @import("../media/video.zig").Video;
const menu_mod = @import("../menu.zig");
const Menu = menu_mod.Menu;
const config = @import("config.zig");
const DevConsole = @import("dev_console.zig").DevConsole;

/// Terminal messages per `log` in opengorky.cfg (filter: logFn in main.zig).
/// Global because std's logFn has no context to read it from.
pub var log_level: config.Log = .warn;

const archive = og.formats.archive;
const Image = og.formats.image.Image;

pub const screen_w = og.state.world.screen_w;
pub const screen_h = og.state.world.screen_h;

/// Viewer commands for `help` (after the world commands in `console.zig`).
pub const viewer_help =
    \\show [layer] / hide <layer>   debug layers (no arg - list): walk walk2 cells
    \\                              areas objects hud depth shadows
    \\impulse                       ABA_Impulse to all doors and active animations
    \\placeheroes                   put the party at the camera centre
    \\fast [n]                      world speed x n (toggle 1/8)
    \\scale <percent>               model scale tweak (100)
    \\back                          go back to the previous location
    \\mute / pause                  sound on/off, world pause
    \\shadowstat                    shadow pixels of the last frame, cut by background depth
    \\keys: Up/Down history, Shift+Up/Down, PgUp/PgDn, wheel - scroll, Home/End
    \\
;

pub fn onOff(b: bool) []const u8 {
    return if (b) "on" else "off";
}

pub const check = gfx.check;

/// Frame detail (hires): current, requested and the auto-lowering limit.
const Detail = struct {
    /// Current factor over 640×480.
    k: u32 = 1,
    /// 0 — by window (`hires` setting), else this number (`--hires N`; shots and
    /// runs without it use 1, as the exe).
    force: u32 = 0,
    /// Pick by window and lower when frames are slow (`adaptDetail`).
    auto: bool = false,
    /// Detail limit (lowered when frames are slow).
    cap: u32 = 4,
    /// `perf` window of the last decision and the slow window count.
    perf_window: u32 = 0,
    perf_bad: u32 = 0,
};

pub const Viewer = struct {
    io: Io,
    gpa: Allocator,
    renderer: *c.SDL_Renderer,
    dat: Io.Dir,
    archives: []const []const u8,
    arc_index: usize = 0,
    arc: ?archive.Archive = null,
    /// Indices of the current archive's entries we can show.
    images: std.ArrayList(usize) = .empty,
    img_index: usize = 0,
    frames: gfx.Frames = .{},
    load_err: ?anyerror = null,
    frame: usize = 0,
    playing: bool = false,
    last_tick: u64 = 0,
    scroll: [2]f32 = .{ 0, 0 },
    /// Camera: last processed world tick, DOLLY move, zoom.
    cam_tick: u64 = 0,
    dolly: ?struct { from: [2]f32, to: [2]f32, t: f32 = 0, speed: f32 } = null,
    /// Pan to the hero selected in battle (0x4c8f40/0x4c9050): t grows by 1/15 per tick.
    select_pan: ?struct { from: [2]f32, to: [2]f32, t: f32 = 1.0 / 15.0 } = null,
    zoom: f32 = 1,
    zoom_target: f32 = 1,
    zoom_rate: f32 = 0,
    zoom_tex: ?*c.SDL_Texture = null,
    /// Level sound stopped for the duration of a video.
    video_silenced: bool = false,
    /// After videos: the level music (video from after_select_gui).
    video_music: bool = false,
    /// Ticks without input (idle line).
    idle_ticks: u64 = 0,
    /// Game mode (`--play`); otherwise the resource viewer.
    play: bool = false,
    /// A `--shot` run: no edge scroll, no battle transition, console replies to the log.
    shot_run: bool = false,
    level: ?LevelView = null,
    sound: ?level_view.SoundContext = null,
    menu_music: ?og.audio.mixer.VoiceId = null,
    menu_music_name: []const u8 = "",
    /// Actor shadows: adjust.kdt disable_shadows == 0 (settings take priority).
    shadows: bool = true,
    /// Gamma × 100 (0x4065e0): the frame goes through the table (i/255)^(1/g).
    gamma: f32 = 100,
    gamma_lut: [256]u8 = undefined,
    gamma_lut_for: f32 = -1,
    gamma_tex: ?*c.SDL_Texture = null,
    /// `*-blur` scaling: the frame shrunk twice (the blurred borders).
    blur_tex: [2]?*c.SDL_Texture = .{ null, null },
    /// 640×480 frame: everything draws here, then stretches to the window per `scaling`.
    /// The frame texture is `ss` times larger (draw scale ss): UI and background keep
    /// their pixels larger, models and effects render at window resolution.
    frame_tex: ?*c.SDL_Texture = null,
    /// Frame detail (hires): factor over 640×480.
    detail: Detail = .{},
    /// Input script `S file` step: a window shot, frame already stretched as on screen.
    window_shot: ?[]const u8 = null,
    /// Input script `o DIR`: every presented frame (one world tick, 1/30 s) goes to
    /// DIR/00000.png… at frame size (640×480 × detail), until `O` (video clips, scripts/record-demo.sh).
    record_dir: ?[]const u8 = null,
    record_n: u32 = 0,
    /// Port settings (opengorky.cfg) and the file path.
    cfg: config.Config = .{},
    cfg_dir: ?[]const u8 = null,
    cfg_path: ?[]const u8 = null,
    models: ?*og.actor.model_cache.Cache = null,
    /// Effect drawing (frame textures), shared by levels.
    fx: ?*EffectsView = null,
    /// Music before the points allocation window.
    upgrade_music: ?[]const u8 = null,
    /// Save thumbnail (snapshot taken when the menu opens).
    thumb: ?Image = null,
    /// Video (ffmpeg) and the queue; the world stands while a video plays.
    video: ?*Video = null,
    video_queue: std.ArrayList(og.outbox.VideoRequest) = .empty,
    game_dir: []const u8 = "",
    font: ?*const og.formats.font.Font = null,
    gui: ?*Gui = null,
    inventory: ?*InventoryView = null,
    /// Safe keypad (GUI_SafeBox).
    safe: ?*SafeView = null,
    /// Menu and saves (game mode --play).
    menu: ?*Menu = null,
    saves_dir: ?[]const u8 = null,
    /// Level worlds, transitions, the party entering battle, the save (game.Game).
    game: og.game.Game,
    quit: bool = false,
    /// Debug console (` or F2).
    console: DevConsole = .{},
    /// --input script: console replies go to the log too.
    input_mode: bool = false,
    /// World clock in --input mode (ms).
    virt_ms: u64 = 1,
    /// Background pause (`pause_background`): when it started.
    pause_start: ?u64 = null,
    /// Mouse wheel: accumulated delta and the last step time (ms).
    wheel_acc: f32 = 0,
    wheel_last_ms: u64 = 0,
    /// Debug line at the top (off in game mode, F1).
    show_debug: bool = true,
    debug: level_view.Debug = .{},
    /// `perf` console: fps and frame part times at the top of the screen.
    show_perf: bool = false,
    mouse: [2]f32 = .{ 320, 240 },
    /// Views of left levels (their worlds are in game.cache, same keys).
    level_cache: std.StringHashMapUnmanaged(LevelView) = .empty,
    /// Message to the player and until when to show it.
    message: ?[]const u8 = null,
    message_until: u64 = 0,
    /// Features of the last drawn field frame (frameSame).
    last_sig: ?FrameSig = null,
    /// Battle transition (0x41f0b0): screenoff4 sound, after 8 ticks the frozen frame
    /// shrinks vertically by 16 px per tick, the "saw" on top (frame tick % 20); the
    /// level switches no earlier than 18 ticks and on a whole turn.
    transition: ?struct { snap: ?*c.SDL_Texture = null, ticks: u32 = 0 } = null,

    pub fn deinit(self: *Viewer) void {
        if (self.video) |vd| vd.close(if (self.sound) |snd| snd.mixer else null);
        self.video = null;
        self.video_queue.deinit(self.gpa);
        if (self.zoom_tex) |t| c.SDL_DestroyTexture(t);
        if (self.gamma_tex) |t| c.SDL_DestroyTexture(t);
        for (self.blur_tex) |b| if (b) |t| c.SDL_DestroyTexture(t);
        if (self.thumb) |*t| t.deinit(self.gpa);
        self.console.deinit(self.gpa);
        self.closeAll();
        self.level_cache.deinit(self.gpa);
        self.game.deinit();
        self.frames.deinit(self.gpa);
        self.images.deinit(self.gpa);
        if (self.arc) |*a| a.close(self.io, self.gpa);
    }

    pub fn openArchive(self: *Viewer, index: usize) !void {
        const was_level = self.level != null;
        self.closeLevel();
        self.frames.deinit(self.gpa);
        if (self.arc) |*a| a.close(self.io, self.gpa);
        self.arc = null;
        self.images.clearRetainingCapacity();
        self.arc_index = index;
        self.arc = try archive.Archive.open(self.io, self.gpa, self.dat, self.archives[index]);
        for (self.arc.?.entries, 0..) |e, i| {
            if (og.formats.resource.kindOf(e.name) != .other) try self.images.append(self.gpa, i);
        }
        self.img_index = 0;
        self.loadImage();
        if (was_level) self.toggleLevel();
    }

    fn loadImage(self: *Viewer) void {
        self.frames.deinit(self.gpa);
        self.load_err = null;
        self.frame = 0;
        self.scroll = .{ 0, 0 };
        if (self.images.items.len == 0) return;
        const arc = self.arc.?;
        const entry = &arc.entries[self.images.items[self.img_index]];
        const data = arc.readAlloc(self.io, self.gpa, entry) catch |err| {
            self.load_err = err;
            return;
        };
        defer self.gpa.free(data);
        self.frames = gfx.loadFrames(self.gpa, self.renderer, entry.name, data) catch |err| {
            self.load_err = err;
            return;
        };
    }

    /// Level name of the current archive: `01_port/sprite.dat` → `01_port`.
    fn levelName(self: *Viewer) ?[]const u8 {
        const dir = std.fs.path.dirname(self.archives[self.arc_index]) orelse return null;
        if (std.mem.eql(u8, dir, "common")) return null;
        return dir;
    }

    pub fn toggleLevel(self: *Viewer) void {
        if (self.level != null) {
            self.closeLevel();
            return;
        }
        const name = self.levelName() orelse return;
        const w = self.game.open(name, .{}, null) catch |err| {
            std.log.err("level {s}: {t}", .{ name, err });
            return;
        };
        self.level = level_compose.load(self.io, self.gpa, self.renderer, self.dat, w, self.sound, self.models) catch |err| {
            std.log.err("level {s}: {t}", .{ name, err });
            self.game.closeWorld();
            return;
        };
        self.level.?.font = self.font;
        if (self.inventory) |inv| self.level.?.world.strings = &inv.strings;
        self.level.?.world.examine_menus = self.inventory != null;
        self.scroll = .{ 0, 0 };
    }

    /// Sounds the menu requested this frame: selection change ("menu1") and action.
    pub fn menuSound(self: *Viewer) void {
        const m = self.menu orelse return;
        if (m.select_sound) {
            m.select_sound = false;
            self.uiSound("menu1");
        }
        if (m.sound) |name| {
            m.sound = null;
            self.uiSound(name);
        }
    }

    /// UI sound without a position (menu).
    pub fn uiSound(self: *Viewer, name: []const u8) void {
        const snd = self.sound orelse return;
        const sample = snd.bank.effect(name) orelse return;
        _ = snd.mixer.playAs(self.gpa, .sfx, sample, 1, 0, false) catch {};
    }

    /// Next video from the queue (no file or ffmpeg — skip).
    pub fn nextVideo(self: *Viewer) void {
        while (self.video == null and self.video_queue.items.len > 0) {
            const rq = self.video_queue.orderedRemove(0);
            if (rq.level_music) self.video_music = true;
            var buf: [600]u8 = undefined;
            const path = Video.find(&buf, self.io, self.game_dir, rq.name) orelse continue;
            self.video = Video.open(self.gpa, self.io, self.renderer, path, rq.x, rq.y, rq.double);
            // Video (0x45d620): music and all effects stop.
            if (self.video != null) if (self.level) |*l| {
                l.suspendSound();
                if (self.sound) |snd| snd.mixer.stopCategory(.sfx);
                self.video_silenced = true;
            };
            if (self.video) |vd| if (self.sound) |snd| vd.startSound(snd.mixer);
        }
    }

    pub fn stopVideo(self: *Viewer, all: bool) void {
        if (self.video) |vd| vd.close(if (self.sound) |snd| snd.mixer else null);
        self.video = null;
        if (all) self.video_queue.clearRetainingCapacity();
        self.nextVideo();
        if (self.video == null and self.video_silenced) {
            self.video_silenced = false;
            if (self.level) |*l| l.resumeSoundOpt(self.video_music);
        }
        if (self.video == null) self.video_music = false;
    }

    /// What determines the field frame between world ticks: if unchanged, the frame
    /// is the same as on screen. Windows with their own time (menu, video, console,
    /// transition, message, inventory, safe, defeat) draw every frame.
    pub const FrameSig = struct {
        level: usize,
        ticks: u64,
        scroll: [2]f32,
        mouse: [2]f32,
        zoom: f32,
        ss: u32,
        wide: f32,
    };

    pub fn safeOpen(self: *Viewer) bool {
        const l = &(self.level orelse return false);
        return self.safe != null and l.world.act.safe_box != null;
    }

    // ------------------------------------------------------------ game: menu and saves

    pub const Layer = enum { walk, walk2, cells, areas, objects, hud, depth, shadows };

    /// New game, load, main menu: all level views dropped and game.reset.
    pub fn closeAll(self: *Viewer) void {
        self.closeLevel();
        var it = self.level_cache.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit();
            self.gpa.free(e.key_ptr.*);
        }
        self.level_cache.clearRetainingCapacity();
        self.game.reset();
        // Per-game GUI state must not leak into the next game.
        if (self.transition) |tr| if (tr.snap) |t| c.SDL_DestroyTexture(t);
        self.transition = null;
        self.upgrade_music = null;
        if (self.gui) |g| {
            g.stats = .{ .tick = g.stats.tick };
            g.report_open = false;
            g.report_done = false;
            gui_battle.clearGameOver(g);
            g.go_capture = false;
        }
    }

    fn closeLevel(self: *Viewer) void {
        if (self.level) |*l| l.deinit();
        self.level = null;
        self.game.closeWorld();
    }

    pub fn step(self: *Viewer, comptime field: enum { archive, image, frame }, delta: isize) !void {
        switch (field) {
            .archive => try self.openArchive(wrap(self.arc_index, delta, self.archives.len)),
            .image => if (self.images.items.len > 0) {
                self.img_index = wrap(self.img_index, delta, self.images.items.len);
                self.loadImage();
            },
            .frame => if (self.frames.len() > 0) {
                self.frame = wrap(self.frame, delta, self.frames.len());
            },
        }
    }

    /// Short message at the screen bottom for 2 seconds (debug font, ASCII).
    pub fn showMessage(self: *Viewer, m: []const u8) void {
        self.message = m;
        self.message_until = c.SDL_GetTicks() + 2000;
    }

    pub fn currentName(self: *Viewer) []const u8 {
        return self.arc.?.entries[self.images.items[self.img_index]].name;
    }

    /// Saves the current drawn frame (before SDL_RenderPresent) as PNG.
    pub fn screenshot(self: *Viewer, path: []const u8) !void {
        const surf = gfx.readFrame(self.renderer) orelse return check(false);
        defer c.SDL_DestroySurface(surf);

        var img = try Image.init(self.gpa, @intCast(surf.*.w), @intCast(surf.*.h));
        defer img.deinit(self.gpa);
        const src: [*]const u8 = @ptrCast(surf.*.pixels.?);
        const stride = img.width * 4;
        for (0..img.height) |y| {
            @memcpy(img.pixels[y * stride ..][0..stride], src[y * @as(usize, @intCast(surf.*.pitch)) ..][0..stride]);
        }
        var out: Io.Writer.Allocating = .init(self.gpa);
        defer out.deinit();
        try og.formats.png.write(self.gpa, &out.writer, img);
        try Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = out.written() });
    }
};

fn wrap(i: usize, delta: isize, len: usize) usize {
    const l: isize = @intCast(len);
    return @intCast(@mod(@as(isize, @intCast(i)) + delta, l));
}

pub fn debugText(r: *c.SDL_Renderer, x: f32, y: f32, text: []const u8) !void {
    var buf: [160]u8 = undefined;
    const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch return;
    const w: f32 = @floatFromInt(text.len * 8 + 6);
    try gfx.fillRect(r, .{ 0, 0, 0, 170 }, .{ .x = x - 3, .y = y - 2, .w = w, .h = 12 });
    try check(c.SDL_SetRenderDrawColor(r, 255, 230, 160, 255));
    try check(c.SDL_RenderDebugText(r, x, y, z));
}

//! Level mode: background, script objects (World) and debug layers.

const std = @import("std");
const floor_mod = og.world.floor;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("media/gfx.zig");
const archive = og.formats.archive;
const level = og.formats.level;
const lf = og.formats.level_files;
const Image = og.formats.image.Image;
const world_mod = og.state.world;
const World = world_mod.World;
const Scene = og.audio.scene.Scene;
const render_layer = og.render.layer;
const model_cache = og.actor.model_cache;
const Canvas = og.render.raster.Canvas;
const EffectsView = @import("level/effects_view.zig").EffectsView;

/// Tab battle grid, shared by all battles as in the exe: mode 0x6b6a98 (0 off,
/// 1 appearing, 2 fading) and wave budget 0x6b6a9c.
/// Kept global on purpose: the exe keeps it in globals, so it survives between battles.
pub var grid_mode: u8 = 0;
pub var grid_wave: i32 = 0;

/// Object z-frames: file bytes and parse (frames reference the bytes).
const Spz = struct {
    bytes: []u8,
    sprite: og.formats.sprite.Sprite,

    fn deinit(self: *Spz, gpa: std.mem.Allocator) void {
        self.sprite.deinit(gpa);
        gpa.free(self.bytes);
    }
};

pub const SoundContext = struct {
    bank: *og.audio.sound.Bank,
    mixer: *og.audio.mixer.Mixer,
    params: og.audio.sound.Params,
};

/// Viewer debug switches, owned by `Viewer.debug` and copied into each
/// LevelView before drawing.
pub const Debug = struct {
    /// `--no-layer-cache`: redraw the actor layer every frame.
    layer_cache: bool = true,
    /// `--no-depth`: do not hide models behind the background depth map.
    no_depth: bool = false,
    /// Model scale factor (1 = exe), keys `-`/`=`; drawing only, the engine never sees it.
    scale_tweak: f32 = 1,
    /// Shadow pixels rejected by the depth test drawn red (render_layer.Layer).
    shadow_debug: bool = false,

    pub const scale_min = 0.2;
    pub const scale_max = 4;
    pub const scale_step = 0.05;
};

/// Area action menu (0x4574a3: items from funcID, funcID1, …) at the click point.
pub const ActionMenu = struct {
    pub const Item = World.AreaAction;
    const item_w: f32 = 70;
    const item_h: f32 = 14;
    at: [2]f32,
    items: [World.max_actions]Item,
    len: usize,

    pub fn rect(self: ActionMenu, k: usize) c.SDL_FRect {
        return .{ .x = self.at[0] + 8, .y = self.at[1] + og.num.toF32(k) * item_h, .w = item_w, .h = item_h };
    }

    pub fn hit(self: ActionMenu, bg: [2]f32) ?usize {
        for (0..self.len) |k| {
            const rc = self.rect(k);
            if (bg[0] >= rc.x and bg[0] < rc.x + rc.w and bg[1] >= rc.y and bg[1] < rc.y + rc.h) return k;
        }
        return null;
    }
};

pub const LevelView = struct {
    gpa: Allocator,
    action_menu: ?ActionMenu = null,
    io: Io,
    renderer: *c.SDL_Renderer,
    level: level.Level,
    world: *World,
    sprites: archive.Archive,
    background: gfx.Frames = .{},
    /// Sprite frames by name (lowercase), loaded on first draw.
    sprite_cache: std.StringHashMapUnmanaged(gfx.Frames) = .empty,
    /// Object z-frames (`<zbufFile>.spz`); null if there is no file.
    spz_cache: std.StringHashMapUnmanaged(?Spz) = .empty,
    last_tick_ms: u64 = 0,
    /// Viewer clock (ms) at the last `update`: clock 0x402c00 (seconds from
    /// QueryPerformanceCounter, not world ticks) for the markers' breathing.
    now_ms: u64 = 0,
    paused: bool = false,
    /// A tick returned an error: the world is stopped for good (pause can't resume it).
    failed: bool = false,
    show_objects: bool = true,
    /// .wm/.wm2 grid textures: a pixel per cell.
    walk_textures: [2]?*c.SDL_Texture = .{ null, null },
    /// 0 — grid hidden, 1 — .wm, 2 — .wm2.
    walk_layer: u2 = 0,
    show_areas: bool = false,
    scene: ?Scene = null,
    sound_ctx: ?SoundContext = null,
    /// Dialog font (02_dialog_1.fnt, owned by game.Game) and the current subtitle texture.
    font: ?*const og.formats.font.Font = null,
    subtitle_tex: ?*c.SDL_Texture = null,
    dialog_page_key: usize = 0,
    /// Actor models (host cache).
    models: ?*model_cache.Cache = null,
    /// Effect drawing (shared by levels, set by the host).
    fx_view: ?*EffectsView = null,
    /// Click marker (0x451630, `kwadrat`): point, start tick, whether walking succeeded.
    marker: ?struct { pos: [3]f32, start: u64, ok: bool } = null,
    /// Debug view of the `.cm` battle grid (key M).
    show_grid: bool = false,
    /// Tab battle grid edges (0x495530) for the current `.cm` and the last wave step
    /// tick (0x495f80).
    grid_edges: []lf.CombatMap.GridEdge = &.{},
    grid_edges_of: ?[*]const bool = null,
    grid_tick: u64 = 0,
    /// Actor shadows (adjust.kdt disable_shadows = 0).
    shadows: bool = true,
    /// Ice (`gfx_3d\\textures\\1..4.3df`) and fighter freeze levels (0..4, 0.5 per tick).
    ice: [4]?Image = .{ null, null, null, null },
    ice_loaded: bool = false,
    ice_level: std.AutoHashMapUnmanaged(*og.script.object.Object, f32) = .empty,
    ice_tick: u64 = 0,
    /// Effect frames on link points (flashes, "nitro") for the model layer, drawn
    /// there with depth testing (actors_view.attachedEffects).
    effect_frames: std.StringHashMapUnmanaged([]Image) = .empty,
    /// Debug battle text: health bars and the status line (F1, `debug` in
    /// opengorky.cfg); the exe has none.
    debug_hud: bool = true,
    debug: Debug = .{},
    /// UI (3d_msg font for text); set by the host every frame.
    gui: ?*@import("gui.zig").Gui = null,
    /// Selected hero model's screen rect this frame (for border.spr).
    hero_box: ?[4]f32 = null,
    /// Floor depth fit for perspective levels without `.cfg`.
    walk_fit: ?[3]f32 = null,
    walk_fit_done: bool = false,
    /// Background depth tolerance along the floor for levels with `.cfg` and no battle grid.
    cfg_tol: ?f32 = null,
    /// Largest floor depth residual on perspective levels (shadow plane offset).
    floor_spread: ?f32 = null,
    /// A window is open (inventory, menu, safe…): items don't blink (0x45bf90).
    ui_modal: bool = false,
    /// A window over the battle (give mode count, 0x4b2fb0): frame and tick go only
    /// to the top of the stack [0x651cbc] (0x45ac70/80/95); the battle mode below
    /// draws no cells, frame or fighter info.
    window_top: bool = false,
    /// Fighter under the cursor (0x454eb0) and how many ticks it has been there; an
    /// enemy's move shows after 15 ticks (0x4550d0).
    hover: ?u16 = null,
    hover_ticks: u64 = 0,
    hover_since: u64 = 0,
    /// Reach of the hovered enemy (full walk_range, 0x49aeb0).
    enemy_reach: []f32 = &.{},
    enemy_reach_for: ?u16 = null,
    /// Give / use / push mode (0x453b70, 0x454120, 0x452d50): a cell cross at the
    /// hero instead of moves (cftTilePGCross 178,178,50).
    cross_mode: bool = false,
    /// Facing arrows (`gfx_3d\textures\facingArrow.3df`, 0x4533b3).
    arrow_tex: ?*c.SDL_Texture = null,
    arrow_loaded: bool = false,
    /// Active area marker (`gfx_3d\textures\strzalki.3df`, 0x4bd450).
    arrows_tex: ?*c.SDL_Texture = null,
    arrows_loaded: bool = false,
    /// 3D actor layer and its texture (orthographic levels only).
    layer: ?render_layer.Layer = null,
    /// Actor layer detail: pixels per screen pixel (set by the viewer from the
    /// window size; the layer is recreated on change).
    ss: u32 = 1,
    /// Actor layer width in screen pixels (wider than 640 with `scaling = adaptive`).
    layer_w: u32 = 640,
    layer_tex: ?*c.SDL_Texture = null,
    /// Where `layer_tex` may be non-empty (uploaded by previous frames).
    /// Layer parts uploaded last time (they must be erased there too).
    tex_regions: [Canvas.max_regions]Canvas.Rect = undefined,
    n_tex_regions: usize = 0,
    /// Previous frame's actor layer: the world changes only on ticks (30 Hz) while
    /// frames draw more often (up to the display rate); the same tick, scroll and
    /// layer size give the same image, so raster, shadows and upload are skipped.
    layer_key: ?LayerKey = null,
    layer_any: bool = false,
    /// Additive actor layer passes (ice, current, materialisation glow).
    glow_tex: ?*c.SDL_Texture = null,
    /// Screen-blended batch billboards over the frame (Layer.screen).
    screen_tex: ?*c.SDL_Texture = null,
    /// Current texture on a shocked fighter (gfx_3d\textures\current.3df).
    current_tex: ?Image = null,
    current_loaded: bool = false,
    frame_arena: std.heap.ArenaAllocator,
    /// The camera follows the selected hero (manual scrolling turns it off, F turns it on).
    follow: bool = true,
    /// Camera scroll when leaving the level (entry 0x411f76); restored on return
    /// (0x411da9).
    left_scroll: ?[2]f32 = null,
    /// Time speed-up (Tab ×8) to skip through scenes.
    speed: u32 = 1,

    pub fn deinit(self: *LevelView) void {
        if (self.scene) |*s| s.deinit();
        if (self.subtitle_tex) |t| c.SDL_DestroyTexture(t);
        for (&self.ice) |*im| if (im.*) |*x| x.deinit(self.gpa);
        self.ice_level.deinit(self.gpa);
        {
            var it = self.effect_frames.iterator();
            while (it.next()) |e| {
                for (e.value_ptr.*) |*im| im.deinit(self.gpa);
                self.gpa.free(e.value_ptr.*);
                self.gpa.free(e.key_ptr.*);
            }
            self.effect_frames.deinit(self.gpa);
        }
        if (self.layer_tex) |t| c.SDL_DestroyTexture(t);
        if (self.glow_tex) |t| c.SDL_DestroyTexture(t);
        if (self.screen_tex) |t| c.SDL_DestroyTexture(t);
        if (self.arrow_tex) |t| c.SDL_DestroyTexture(t);
        if (self.arrows_tex) |t| c.SDL_DestroyTexture(t);
        if (self.enemy_reach.len > 0) self.gpa.free(self.enemy_reach);
        if (self.grid_edges.len > 0) self.gpa.free(self.grid_edges);
        if (self.current_tex) |*x| x.deinit(self.gpa);
        if (self.layer) |*l| l.deinit(self.gpa);
        self.frame_arena.deinit();
        var it = self.sprite_cache.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.sprite_cache.deinit(self.gpa);
        var zit = self.spz_cache.iterator();
        while (zit.next()) |e| {
            if (e.value_ptr.*) |*z| z.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.spz_cache.deinit(self.gpa);
        for (self.walk_textures) |t| if (t) |tex| c.SDL_DestroyTexture(tex);
        self.background.deinit(self.gpa);
        self.sprites.close(self.io, self.gpa);
        self.level.deinit();
    }

    pub fn size(self: LevelView) [2]u32 {
        if (self.background.len() == 0) return .{ 0, 0 };
        return self.background.sizes.items[0];
    }

    /// Runs as many game ticks as have passed since the last call.
    pub fn update(self: *LevelView, now_ms: u64) !void {
        self.now_ms = now_ms;
        if (self.last_tick_ms == 0 or self.paused or self.failed) {
            self.last_tick_ms = now_ms;
            return;
        }
        const tick_ms = 1000 / og.state.world.tick_hz;
        while (now_ms - self.last_tick_ms >= tick_ms) : (self.last_tick_ms += tick_ms) {
            for (0..self.speed) |_| try og.game.tick(self.world);
        }
    }

    /// Sound for a camera whose top-left screen corner is at `scroll`.
    pub fn updateSound(self: *LevelView, scroll: [2]f32) !void {
        const s = &(self.scene orelse return);
        if (try s.update(try og.game.audioInput(self.world), .{ scroll[0] + og.state.world.screen_cx, scroll[1] + og.state.world.screen_cy })) |bytes| og.scene.scenes.voiceStarted(self.world, bytes);
    }

    /// Actor `o`'s head at `head_focus` (0x45bfc0).
    pub fn actorGoal(self: *LevelView, o: *og.script.object.Object) ?[2]f32 {
        if (!world_mod.actorOf(o).placed) return null;
        const q = headAt(self.world, og.fields.pos(o));
        return .{ q[0] - head_focus[0], q[1] - head_focus[1] };
    }

    /// Camera on the selected hero (0x45bfc0).
    pub fn cameraGoal(self: *LevelView) ?[2]f32 {
        return self.actorGoal(self.world.selectedHero() orelse return null);
    }

    /// Scene camera with autocamera (0x45bb50): centre of the party's screen rect.
    pub fn partyGoal(self: *LevelView) ?[2]f32 {
        const w = self.world;
        const heroes = w.party();
        var lo = [2]f32{ std.math.inf(f32), std.math.inf(f32) };
        var hi = [2]f32{ -std.math.inf(f32), -std.math.inf(f32) };
        var any = false;
        for (heroes.slice()) |h| {
            if (!h.enabled or !world_mod.actorOf(h).placed) continue;
            const p = w.screenPos(h);
            lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
            hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
            any = true;
        }
        if (!any) return null;
        return .{ (lo[0] + hi[0]) / 2 - og.state.world.screen_cx, (lo[1] + hi[1]) / 2 - og.state.world.screen_cy };
    }

    /// Background click: the selected hero walks there; in battle — a cell action.
    /// A marker at the click point and the `setway` / `setway-wrong` sound.
    pub fn clickMarker(self: *LevelView, bg: [2]f32) void {
        const w = self.world;
        self.marker = .{ .pos = floor_mod.groundAt(w, bg), .start = w.ticks, .ok = w.walk_ok };
        w.out.sound(w.gpa, if (w.walk_ok) "setway" else "setway-wrong", null);
    }

    /// Stops the level sound (when moving to the cache).
    pub fn suspendSound(self: *LevelView) void {
        if (self.scene) |*s| s.deinit();
        self.scene = null;
        // Pending music events (jingles) are not needed on return.
        self.world.out.music_events.clearRetainingCapacity();
    }

    /// Restarts the level sound (on return).
    pub fn resumeSound(self: *LevelView) void {
        self.resumeSoundOpt(true);
    }

    /// After a video (0x45d620 kills all music slots) there is no music until the
    /// next level loads, only ambients and sounds; except a video from
    /// after_select_gui (`music`): after it the exe starts the level music.
    pub fn resumeSoundOpt(self: *LevelView, music: bool) void {
        const s = self.sound_ctx orelse return;
        if (self.scene != null) return;
        self.scene = Scene.init(self.gpa, s.bank, s.mixer, s.params);
        if (music) self.scene.?.startMusic(og.game.levelMusic(self.world)) catch {};
    }

    pub const LayerKey = struct {
        world: usize,
        ticks: u64,
        scroll: [2]f32,
        pixels: usize,
        width: usize,
        height: usize,
        shadows: bool,
        ui_modal: bool,
    };

    /// Z-frames `<name>.spz` from the level's sprite.dat.
    pub fn spzFrames(self: *LevelView, name: []const u8) ?*Spz {
        var buf: [archive.name_size]u8 = undefined;
        if (name.len == 0 or name.len + 4 > buf.len or std.mem.eql(u8, name, "(null)")) return null;
        const key = std.ascii.lowerString(&buf, name);
        if (self.spz_cache.getPtr(key)) |z| return if (z.*) |*x| x else null;
        var name_buf: [archive.name_size]u8 = undefined;
        const file = std.fmt.bufPrint(&name_buf, "{s}.spz", .{name}) catch return null;
        const spz: ?Spz = blk: {
            const e = self.sprites.find(file) orelse break :blk null;
            const bytes = self.sprites.readAlloc(self.io, self.gpa, e) catch break :blk null;
            const spr = og.formats.sprite.parse(self.gpa, bytes) catch {
                self.gpa.free(bytes);
                break :blk null;
            };
            break :blk .{ .bytes = bytes, .sprite = spr };
        };
        const owned = self.gpa.dupe(u8, key) catch return null;
        self.spz_cache.put(self.gpa, owned, spz) catch {
            self.gpa.free(owned);
            return null;
        };
        const z = self.spz_cache.getPtr(key).?;
        return if (z.*) |*x| x else null;
    }

    pub fn spriteFrames(self: *LevelView, name: []const u8) ?*gfx.Frames {
        var buf: [archive.name_size]u8 = undefined;
        if (name.len == 0 or name.len + 4 > buf.len) return null;
        const key = std.ascii.lowerString(&buf, name);
        if (self.sprite_cache.getPtr(key)) |f| return f;
        var name_buf: [archive.name_size]u8 = undefined;
        const file = std.fmt.bufPrint(&name_buf, "{s}.spr", .{name}) catch return null;
        const frames = loadEntry(self.io, self.gpa, self.renderer, self.sprites, file) catch |err| blk: {
            std.log.warn("sprite {s}: {t}", .{ file, err });
            break :blk gfx.Frames{};
        };
        const owned = self.gpa.dupe(u8, key) catch return null;
        self.sprite_cache.put(self.gpa, owned, frames) catch {
            self.gpa.free(owned);
            return null;
        };
        return self.sprite_cache.getPtr(key);
    }
};

pub fn addZ(p: [3]f32, dz: f32) [3]f32 {
    return .{ p[0], p[1], p[2] + dz };
}

/// Head height above a world point (0x45bfc0, 0x45c160): 160·actorScale.
const head_z = 160;
/// Where the camera puts the hero's head (0x45bfc0).
pub const head_focus = [2]f32{ 320, 230 };
/// Screen point of the world above `p` at head height.
pub fn headAt(w: *World, p: [3]f32) [2]f32 {
    const q = w.cam.project(addZ(p, head_z * w.actorScale()));
    return .{ q.x, q.y };
}

pub fn loadEntry(io: Io, gpa: Allocator, r: *c.SDL_Renderer, arc: archive.Archive, name: []const u8) !gfx.Frames {
    const entry = arc.find(name) orelse return error.NotFound;
    const data = try arc.readAlloc(io, gpa, entry);
    defer gpa.free(data);
    return gfx.loadFrames(gpa, r, name, data);
}

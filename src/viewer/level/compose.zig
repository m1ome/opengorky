//! Level mode assembly: view load, frame (background and objects, battle tiles and
//! grid, markers, actors, effects, debug layers, text), field clicks, actor layer
//! detail. LevelView functions (view first), called through the module;
//! viewer/level.zig does not import this file.

const std = @import("std");
const level_file = @import("../level.zig");
const level_effects = @import("effects.zig");
const actors_view = @import("actors.zig");
const actor_layer = @import("layer.zig");
const markers = @import("markers.zig");
const debug_layers = @import("debug_layers.zig");
const battle_view = @import("../battle/view.zig");
const battle_grid = @import("../battle/grid.zig");
const gui_battle = @import("../battle/gui.zig");
const Gui = @import("../gui.zig").Gui;
const og = @import("opengorky");
const c = @import("sdl");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const LevelView = level_file.LevelView;
const SoundContext = level_file.SoundContext;
const World = og.state.world.World;
const lf = og.formats.level_files;
const archive = og.formats.archive;
const level = og.formats.level;
const Scene = og.audio.scene.Scene;
const model_cache = og.actor.model_cache;

/// Draws the level world `world` (owned by game.Game).
pub fn load(io: Io, gpa: Allocator, r: *c.SDL_Renderer, dat: Io.Dir, world: *World, snd: ?SoundContext, models: ?*model_cache.Cache) !LevelView {
    const name = world.level_name;
    var lvl = try level.load(io, gpa, dat, name);
    errdefer lvl.deinit();
    var path_buf: [256]u8 = undefined;
    var sprites = try archive.Archive.open(io, gpa, dat, try std.fmt.bufPrint(&path_buf, "{s}/sprite.dat", .{name}));
    errdefer sprites.close(io, gpa);

    var view: LevelView = .{
        .gpa = gpa,
        .io = io,
        .renderer = r,
        .level = lvl,
        .world = world,
        .sprites = sprites,
        .models = models,
        .frame_arena = .init(gpa),
        .sound_ctx = snd,
    };
    errdefer {
        view.background.deinit(gpa);
        for (view.walk_textures) |t| if (t) |tex| c.SDL_DestroyTexture(tex);
    }
    if (lvl.background) |bg| view.background = try level_file.loadEntry(io, gpa, r, sprites, bg);
    if (models != null) try actor_layer.makeLayer(&view, 1, 640);
    if (snd) |s| {
        view.scene = Scene.init(gpa, s.bank, s.mixer, s.params);
        view.scene.?.startMusic(og.game.levelMusic(world)) catch |err| std.log.warn("music: {t}", .{err});
    }
    for ([2]?lf.WalkMap{ world.walk_map, world.walk_map2 }, &view.walk_textures) |wm, *tex| {
        if (wm) |m| tex.* = try debug_layers.walkMapTexture(gpa, r, m);
    }
    return view;
}

/// Actor layer detail (pixels per screen pixel); the layer is recreated.
pub fn setDetail(self: *LevelView, ss: u32, lw: u32) void {
    if (self.layer == null or (ss == self.ss and lw == self.layer_w)) return;
    actor_layer.makeLayer(self, ss, lw) catch |err| {
        std.log.warn("actor layer ×{d}: {t}", .{ ss, err });
        actor_layer.makeLayer(self, 1, 640) catch {};
    };
}

pub fn draw(self: *LevelView, r: *c.SDL_Renderer, scroll: [2]f32, mouse: [2]f32) !void {
    if (self.background.len() > 0) try self.background.draw(r, 0, -scroll[0], -scroll[1]);
    if (self.show_objects) {
        // The exe object list (0x63bcb8) grows at the head (0x4316da…0x431700,
        // 0x431c2b) and is drawn from the head (0x420892…0x4208b0): newer objects
        // draw earlier and below. The castle gate (gate1) once open is over the lock.
        var i = self.world.rt.objects.items.len;
        while (i > 0) {
            i -= 1;
            const o = self.world.rt.objects.items[i];
            const n = World.nativeOf(o);
            if (n.kind != .animation and n.kind != .active_animation) continue;
            if (!o.enabled or n.deleted or !n.visible) continue;
            const frames = self.spriteFrames(o.getString("spriteFile")) orelse continue;
            if (frames.len() == 0) continue;
            const frame: usize = @intCast(std.math.clamp(o.getInt("cur_frame"), 0, @as(i32, @intCast(frames.len() - 1))));
            const x: f32 = @floatFromInt(o.getInt("pos_x"));
            const y: f32 = @floatFromInt(o.getInt("pos_y"));
            try frames.draw(r, frame, x - scroll[0], y - scroll[1]);
        }
    }
    try battle_grid.drawCombatGrid(self, r, scroll);
    try battle_grid.drawGrid(self, r, scroll);
    try battle_view.drawBattleTiles(self, r, scroll, .{ mouse[0] + scroll[0], mouse[1] + scroll[1] });
    try markers.drawMarker(self, scroll);
    try markers.drawSpeakerMarker(self, scroll);
    try actors_view.drawActors(self, r, scroll);
    try level_effects.drawEffects(self, scroll);
    try markers.drawAreaMarkers(self, r, scroll);
    try debug_layers.drawActionMenu(self, r, scroll, mouse);
    try debug_layers.drawLayers(self, r, scroll);
    // Text over actors outside battle (Actor_TextEffect).
    if (self.gui) |g| for (self.world.popups.items) |*pp| try drawPopup(self, r, g, pp, scroll);
}

/// TextEffect (0x4c8d50): above the point + 650·aS; higher than 80 px from the
/// screen top — from y = 50 downward, otherwise upward.
pub fn drawPopup(self: *LevelView, r: *c.SDL_Renderer, g: *Gui, pp: *const og.popup.Popup, scroll: [2]f32) !void {
    const lk = pp.look() orelse return;
    const q = self.world.cam.project(level_file.addZ(pp.pos, og.popup.teffHeight() * self.world.actorScale()));
    const sx = q.x - scroll[0];
    var sy = q.y - scroll[1];
    sy = if (sy < 80) 50 + pp.dy else sy - pp.dy;
    try gui_battle.msgTextAlpha(g, r, pp.text(), sx, sy, pp.scale, lk.rgb, lk.a);
}

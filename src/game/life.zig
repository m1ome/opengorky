//! World lifecycle: location creation (archives, grids, objects, heroes, party,
//! init/restore, battle) and its ticks. Sits above state/world.zig, which holds only data
//! and small helpers, and calls the world, scene, inventory and combat subsystems.

const std = @import("std");
const num = @import("../num.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const Object = @import("../script.zig").object.Object;
const fields = @import("../fields.zig");
const archive = @import("../formats.zig").archive;
const audio_sound = @import("../audio.zig").sound;
const level_files = @import("../formats.zig").level_files;
const actor_mod = @import("../actor.zig");
const model_cache = @import("../actor.zig").model_cache;
const motion = @import("../actor/motion.zig");
const popup_mod = @import("../popup.zig");
const immunity_mod = @import("../battle.zig").immunity;
const roster = @import("../combat.zig").roster;
const party_mod = @import("../world.zig").party;
const inventory = @import("../inventory.zig");
const scenes = @import("../scene.zig").scenes;
const sources = @import("../world.zig").sources;
const start = @import("../world.zig").start;
const levels = @import("../world.zig").levels;
const actions = @import("../world.zig").actions;
const spawn = @import("../world.zig").spawn;
const queue = @import("../world.zig").queue;
const bitmap_anim = @import("../world.zig").bitmap_anim;

pub const Options = struct {
    /// Heroes and their items from the party (coming from another location).
    party: ?*const party_mod.Party = null,
    /// Needed at start already: a factory post_init calls GO_RunFun("04_city", …).
    resolver: ?World.Resolver = null,
    /// Selected hero, already during init/restore (GUI_GetSelectedHero: only he enters
    /// 01_port_worker; DisableHeroes hides the rest).
    hero: ?[]const u8 = null,
    /// The game's discovered immunities (game.Game); null = the world's own (gorky-tool runs).
    immunity: ?*immunity_mod.Known = null,
    /// Dialog font for subtitle pages (game.Game).
    dialog_font: ?*const @import("../formats.zig").font.Font = null,
};

/// New world for location `level_name`.
pub fn create(io: Io, gpa: Allocator, dat: Io.Dir, level_name: []const u8, models: ?*model_cache.Cache, opts: Options) !*World {
    const party = opts.party;
    const w = try gpa.create(World);
    errdefer gpa.destroy(w);
    var path_buf: [256]u8 = undefined;
    var other = try archive.Archive.open(io, gpa, dat, try std.fmt.bufPrint(&path_buf, "{s}/other.dat", .{level_name}));
    errdefer other.close(io, gpa);
    var sprites = try archive.Archive.open(io, gpa, dat, try std.fmt.bufPrint(&path_buf, "{s}/sprite.dat", .{level_name}));
    errdefer sprites.close(io, gpa);
    var common = try archive.Archive.open(io, gpa, dat, "common/other.dat");
    errdefer common.close(io, gpa);
    var lang = try archive.Archive.open(io, gpa, dat, "common/lang.dat");
    errdefer lang.close(io, gpa);

    w.* = .{
        .gpa = gpa,
        .io = io,
        .arena_state = .init(gpa),
        .rt = .init(gpa, .{ .ctx = w, .fetch = sources.fetchSource }),
        .level_name = undefined,
        .res = .{ .other = other, .sprites = sprites, .common = common, .lang = lang, .dat = dat, .models = models, .dialog_font = opts.dialog_font },
        .immunity = opts.immunity orelse &w.own_immunity,
    };
    // The archives belong to w and close via the errdefers above; free only what follows.
    errdefer w.deinitScripts();
    w.level_name = try w.arena_state.allocator().dupe(u8, level_name);
    try @import("../builtins.zig").registerBuiltins(w);
    const a = w.arena_state.allocator();
    if (try levelFile(w, io, "ar")) |t| w.areas = try level_files.parseAreas(a, t);
    if (try levelFile(w, io, "cm")) |t| w.combat_map = try level_files.parseCombatMap(a, t);
    if (try levelFile(w, io, "wm")) |t| w.walk_map = try level_files.parseWalkMap(a, t);
    // Bad .wm2/.ap: go on without them (the exe reports via 0x401f20 and continues);
    // .wm and .cm are required, their errors fail the load.
    if (try levelFile(w, io, "wm2")) |t| w.walk_map2 = level_files.parseWalkMap(a, t) catch |err| blk: {
        std.log.warn("{s}.wm2: {t}", .{ level_name, err });
        break :blk null;
    };
    if (try levelFile(w, io, "ap")) |t| {
        w.paths = level_files.parsePaths(a, t) catch |err| blk: {
            std.log.warn("{s}.ap: {t}", .{ level_name, err });
            break :blk &.{};
        };
        w.path_scripts = try a.alloc(?*Object, w.paths.len);
        @memset(w.path_scripts, null);
    }
    w.resolver = opts.resolver;
    try start.createObjects(w);
    try start.createHeroes(w);
    if (party) |p| try p.createMissingHeroes(w);
    if (opts.hero) |h| w.setSelectedHero(h);
    // As in the exe (0x431830): party heroes are global objects with current fields
    // already during the new location's restore(); restore() changes to heroes
    // (05__lab_group3: FighterSetHp("Sullivan", hp/2)) persist. So the party is applied
    // between init() and restore().
    try start.startInit(w);
    if (party) |p| try p.apply(w, true);
    try start.startRestore(w);
    inventory.equipment.refreshHoldStates(w);
    if (w.isCombat() and w.combat_map != null) w.battle = try roster.init(w);
    try levels.afterSelectGui(w);
    w.battle_music = battleMusic(w);
    return w;
}

/// Battle music, drawn at level load like the exe (0x41f9b0…0x41fab3) so every host
/// consumes the same rand(): the level's own `<name>.mp3` or a district's shared music
/// means no draw; a boss level plays `battle3`; else `rand() % 2` — 0 `battle`,
/// 1 `battle2`. (The exe's [0x54c465] flag, never set by the game, forces `battle`.)
fn battleMusic(w: *World) ?[]const u8 {
    var buf: [2][]const u8 = undefined;
    if (!w.isCombat() or audio_sound.musicCandidates(w.level_name, &buf).len > 1) return null;
    own: {
        var voices = archive.Archive.open(w.io, w.gpa, w.res.dat, "common/voice.dat") catch break :own;
        defer voices.close(w.io, w.gpa);
        var name_buf: [archive.name_size]u8 = undefined;
        const file = std.fmt.bufPrint(&name_buf, "{s}.mp3", .{w.level_name}) catch break :own;
        if (voices.find(file) != null) return null;
    }
    if (w.level.?.getInt("bossmonsterLevel") != 0) return "battle3";
    return if (w.crt().below(2) == 0) "battle" else "battle2";
}

/// The item's animation (box lid) reached its last frame.
fn itemAnimDone(self: *World, o: *Object) bool {
    const a = world_mod.actorOf(o);
    const ms = self.res.models orelse return true;
    const m = ms.get(fields.meshFile(o)) orelse return true;
    const an = m.anims.find(a.anim) orelse return true;
    return a.anim_ticks >= num.toF32(an.last - an.first + 1);
}

/// Object tick, after battle and scenes (whole tick: game.tick).
pub fn tickObjects(self: *World) !void {
    if (self.act.pending_explore) |*pe| {
        if (pe.ticks > 0) pe.ticks -= 1 else if (itemAnimDone(self, pe.box)) {
            const box = pe.box;
            const hero = pe.hero;
            self.act.pending_explore = null;
            if (box.enabled and !World.nativeOf(box).deleted and self.act.exploring == null) try inventory.box.exploreBox(self, box, hero);
        }
    }
    spawn.aimFlames(self);
    spawn.releaseRemoved(self);
    spawn.aimBalls(self);
    self.effects.tick(self.gpa, self.crt());
    // EARTHQUAKE (0x4205b0, 0x420b62): screen offset 0..5 px when strength > 10, else 0..3;
    // strength drops by 1 per frame.
    if (self.out.earthquake > 0) {
        const r = self.crt();
        const m: u32 = if (self.out.earthquake > 10) 6 else 4;
        self.out.shake = .{ @floatFromInt(r.below(m)), @floatFromInt(r.below(m)) };
        self.out.earthquake -= 1;
    } else self.out.shake = .{ 0, 0 };
    var i: usize = 0;
    while (i < self.rt.objects.items.len) : (i += 1) {
        const o = self.rt.objects.items[i];
        const n = World.nativeOf(o);
        if (!o.enabled or n.deleted) continue;
        switch (n.kind) {
            .animation => bitmap_anim.updateAnimation(self, o, n),
            .active_animation => bitmap_anim.updateActiveAnimation(self, o, n),
            .actor => {
                const model = if (self.res.models) |m| m.get(fields.meshFile(o)) else null;
                // Frozen: animation stops (0x48e940 → +0x245bc, 0x44fae0).
                n.actor.anim_paused = if (self.battle) |*b| b.isFrozen(o) else false;
                motion.tick(&n.actor, o, model, self.actorScale() * if (model) |m| m.unitScale() else 24, self.crt());
                if (model) |m| if (n.actor.placed) try queue.animCues(self, o, &n.actor, m);
                if (n.actor.bind) |*bd| try spawn.tickBind(self, o, &n.actor, bd, model);
                // An idle hero outside scenes doesn't step in place (paths are reset by floor
                // changes, path nodes and stops).
                if (n.hero and !self.scene.cutscene and self.scene.runner == null and self.battle == null and !n.actor.busy() and
                    n.actor.loop and n.actor.anim.len > 0 and std.mem.eql(u8, n.actor.anim, n.actor.resolve(n.actor.walk_anim)))
                    n.actor.stopWalking(self.crt());
                if (n.actor.morph_due) {
                    n.actor.morph_due = false;
                    if (n.actor.morph) |mp| try spawn.applyMorph(self, o, mp.class, mp.mesh, mp.idle);
                    n.actor.morph = null;
                }
                if (n.actor.fx_sound) |snd| {
                    n.actor.fx_sound = null;
                    self.out.sound(self.gpa, snd, self.screenPos(o));
                }
                if (n.actor.node_event) |ev| {
                    n.actor.node_event = null;
                    try nodeEvent(self, o, ev);
                }
                try queue.runQueue(self, o, &n.actor);
            },
            else => {},
        }
        if (n.kind.hooks().update) _ = try self.rt.callIfExistsC(o, "update", &.{});
        try start.updateVisibility(self, o);
    }
}

/// Scene, fade, subtitles, attached actors — after the object tick.
pub fn tickPresentation(self: *World) !void {
    for (self.actorObjects()) |o| {
        const n = World.nativeOf(o);
        if (n.kind != .actor) continue;
        if (n.actor.vibrato[0] != 0) {
            n.actor.render_offset[2] = @sin(n.actor.vibrato_phase) * n.actor.vibrato[0];
            n.actor.vibrato_phase += n.actor.vibrato[1];
        }
    }
    for (self.actorObjects()) |o| {
        const n = World.nativeOf(o);
        if (n.kind != .actor) continue;
        const parent = n.actor.attached_to orelse continue;
        const pm = if (self.res.models) |m| m.get(fields.meshFile(parent)) else null;
        motion.followParent(&n.actor, o, self.actorScale() * if (pm) |m| m.unitScale() else 24, world_mod.actorOf(parent).angle_offset);
        // Attached actors sway with their parent (0x4cdbd0: + parent offset).
        n.actor.render_offset = world_mod.actorOf(parent).render_offset;
    }
    try actions.runInteraction(self);
    // Item animations (Item_Animation).
    for (self.rt.objects.items) |o| {
        const n = World.nativeOf(o);
        if ((n.kind == .item or n.kind == .weapon) and n.actor.anim.len > 0) n.actor.anim_ticks += 1;
    }
    self.scene.tickLine();
    {
        var i: usize = 0;
        while (i < self.out.delayed_sounds.items.len) {
            const d = &self.out.delayed_sounds.items[i];
            if (d.ticks > 0) {
                d.ticks -= 1;
                i += 1;
                continue;
            }
            self.out.sound(self.gpa, d.name, d.pos);
            _ = self.out.delayed_sounds.orderedRemove(i);
        }
    }
    popup_mod.tickAll(&self.popups);
    try scenes.tickRockets(self);
}

/// Path script `<name>.pth`, loaded at the first node.
fn pathScript(self: *World, index: u16) !?*Object {
    if (index >= self.paths.len) return null;
    if (self.path_scripts[index]) |o| return o;
    var buf: [archive.name_size]u8 = undefined;
    const file = std.fmt.bufPrint(&buf, "{s}.pth", .{self.paths[index].name}) catch return null;
    if (self.res.other.find(file) == null) return null;
    const cls = self.rt.loadClass(file) catch |err| {
        try self.classMissing(file, err);
        return null;
    };
    const o = try self.addObject(file, cls, .{ .kind = .other });
    self.path_scripts[index] = o;
    return o;
}

/// A path node was passed: NodeResponse(no, dir) with this actor.
fn nodeEvent(self: *World, o: *Object, ev: actor_mod.command.NodeEvent) !void {
    const script = try pathScript(self, ev.path) orelse return;
    self.node_actor = o;
    self.node_cur = ev;
    defer self.node_actor = null;
    defer self.node_cur = null;
    _ = try self.rt.callIfExists(script, "NodeResponse", &.{ .{ .int = ev.no }, .{ .int = ev.dir } });
}

/// The level's own `<level>.<ext>` (areas, grids, paths) in the world's arena; null if
/// the level has none.
fn levelFile(w: *World, io: Io, ext: []const u8) !?[]const u8 {
    var buf: [archive.name_size]u8 = undefined;
    const e = w.res.other.find(try std.fmt.bufPrint(&buf, "{s}.{s}", .{ w.level_name, ext })) orelse return null;
    return try w.res.other.readAlloc(io, w.arena_state.allocator(), e);
}

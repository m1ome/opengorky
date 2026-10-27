//! Location world data: script objects, grids, scene/battle state and host requests,
//! plus small helpers without subsystem logic.
//!
//! Data layer: imports only data and leaf modules (formats, script objects, fields,
//! actor). Creation and ticks live in game/life.zig; behaviour is free functions in
//! `src/world/*.zig` and the subsystems taking `self: *World` (`walk.partyWalk(w, …)`).

const std = @import("std");
const fields = @import("../fields.zig");
const mouse_mod = @import("mouse.zig");
const scene_state = @import("scene.zig");
const object = @import("object.zig");
const groups = @import("groups.zig");
const outbox = @import("../outbox.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const level_files = @import("../formats.zig").level_files;
const camera = @import("../actor.zig").camera;
const actor_mod = @import("../actor.zig");
const model_cache = @import("../actor.zig").model_cache;
const runtime = @import("../script.zig").runtime;
const battle_mod = @import("../battle.zig").battle;
const effects_mod = @import("../effects.zig");
const popup_mod = @import("../popup.zig");
const crt_rand = @import("../crt_rand.zig");
const immunity_mod = @import("../battle.zig").immunity;
const Runtime = runtime.Runtime;
const Object = @import("../script.zig").object.Object;
const Value = @import("../script.zig").value.Value;

/// Game tick rate: fixed 30 Hz step (main loop 0x405ca0, QueryPerformanceCounter,
/// `[0x51c7c0]` = 30.0); BitmapAnimation `speed` is frames per second.
pub const tick_hz = 30;
/// Game screen 640×480 and its centre.
pub const screen_w = 640;
pub const screen_h = 480;
pub const screen_cx = screen_w / 2;
pub const screen_cy = screen_h / 2;
/// `acc += speed` per tick; the frame advances at `acc >= 30` (0x51c7bc).
pub const speed_divisor = 30;
pub const default_speed = 15;

/// Script builtin (builtins.zig).
pub const Builtin = *const fn (*anyopaque, *Runtime, *Object, []const Value) anyerror!Value;

pub const World = struct {
    gpa: Allocator,
    io: Io,
    arena_state: std.heap.ArenaAllocator,
    rt: Runtime,
    level_name: []const u8,
    level: ?*Object = null,
    /// Actor objects in creation order (`actorObjects`); runtime objects are only appended
    /// and their kind never changes.
    actor_objs: std.ArrayList(*Object) = .empty,
    actor_scanned: usize = 0,
    ambient_class: ?*@import("../script.zig").object.Class = null,
    /// Ground-floor walk grid `.wm`.
    walk_map: ?level_files.WalkMap = null,
    /// Second floor `.wm2` (roofs, platforms); an actor's floor is `Actor.map`.
    walk_map2: ?level_files.WalkMap = null,
    /// `.ap` paths (ladders, planks, steps) and their `<path>.pth` script objects.
    paths: []level_files.Path = &.{},
    path_scripts: []?*Object = &.{},
    /// Actor running NodeResponse (implicit argument of Actor* builtins).
    node_actor: ?*Object = null,
    /// Node of the current NodeResponse (ActorAdjustAngle uses its angle).
    node_cur: ?actor_mod.command.NodeEvent = null,
    /// Forbid/AllowWalkInArea calls in order (+0x358, +0x35c); saved and replayed on
    /// load (0x411fa3, 0x47a040).
    walk_areas: std.ArrayList(groups.WalkArea) = .empty,
    /// Popups over actors outside battle (Actor_TextEffect, 0x4c8830).
    popups: std.ArrayList(popup_mod.Popup) = .empty,
    /// Visual effects (explosions, muzzle flashes, blood, flamethrower).
    effects: effects_mod.Effects = .{},
    /// Scenes, dialogues, subtitles, fade, panorama (state/scene.zig).
    scene: scene_state.State = .{},
    /// World whose scene player is borrowed (GO_RunFun into another location's object);
    /// the exe has one scene list per game (0x68b154).
    scene_host: ?*World = null,
    /// Host requests: sounds, music, videos, camera, message (outbox.zig).
    out: outbox.Outbox = .{},
    res: groups.Res,
    flow: groups.Flow = .{},
    act: groups.Act = .{},
    debug: groups.Debug = .{},
    selected_hero: []const u8 = "Sullivan",
    /// Location camera, chosen after the level's initCamera().
    cam: camera.Camera = .ortho,
    /// string.tab, set by the host.
    strings: ?*const @import("../formats.zig").strtab.Table = null,
    /// Name counter for TimeBombLarge<N>, TimeBomb<N>, TimeBombExplode<N>, Distractor<N>.
    bombs_placed: u32 = 0,
    /// Fighter shadows (`__shadows__`, 0x411f35…0x411f74): hero positions here when
    /// leaving, if the level has `shadowActive`; reapplied after restore() (0x411d57).
    shadows: std.ArrayList(groups.Shadow) = .empty,
    /// Whether the last party walk click succeeded (green/red marker).
    walk_ok: bool = true,
    /// Pathfinding scratch (world/nav.zig): open/closed node per walk-map cell, reused.
    nav_cells: []?u32 = &.{},
    /// Battle music drawn at load (`life.battleMusic`); null: none or the level's own.
    battle_music: ?[]const u8 = null,
    /// Examine menu (0x457340) instead of an immediate action; enabled by a host with a GUI.
    examine_menus: bool = false,
    /// Another GUI mode is above battle (level-up window, 0x4af7c2): battle pauses.
    gui_hold: bool = false,
    /// Mouse mode: use/give item, push, aim (state/mouse.zig).
    mouse: mouse_mod.Mouse = .{},
    /// Lookup of other loaded locations for GO_RunFun("01_port", …); set by the host.
    resolver: ?Resolver = null,
    /// Battle grid `.cm` (PlaceActor by cell).
    combat_map: ?level_files.CombatMap = null,
    /// Location areas (`.ar`, PlaceActor).
    areas: []level_files.Area = &.{},
    ticks: u64 = 0,
    /// Running battle (`NN__*` locations), created after scripts start.
    battle: ?battle_mod.Battle = null,
    /// Discovered immunities: the game's (`Options.immunity`, game.Game), else own.
    immunity: *immunity_mod.Known,
    own_immunity: immunity_mod.Known = .{},

    pub const Resolver = struct { ctx: *anyopaque, find: *const fn (ctx: *anyopaque, level: []const u8) anyerror!?*World };

    /// Set the selected hero without the player-action effects (those are game.selectHero).
    pub fn setSelectedHero(self: *World, name: []const u8) void {
        if (self.rt.findObject(name)) |o| self.selected_hero = o.name;
    }

    /// The player may pick this hero: Medusa only on a battle level (portrait 0x4b2761,
    /// field click 0x451467; selection 0x45acb0 itself has no such check).
    pub fn playerCanSelect(self: *World, o: *Object) bool {
        return self.isCombat() or !fields.isMedusa(o);
    }

    pub fn destroy(self: *World) void {
        const gpa = self.gpa;
        self.deinitScripts();
        self.res.lang.close(self.io, self.gpa);
        self.res.common.close(self.io, self.gpa);
        self.res.sprites.close(self.io, self.gpa);
        self.res.other.close(self.io, self.gpa);
        gpa.destroy(self);
    }

    pub fn deinitScripts(self: *World) void {
        groups.freeLoadSteps(self.gpa, self.flow.load_steps.items);
        self.flow.load_steps.deinit(self.gpa);
        if (self.battle) |*b| b.deinit();
        self.battle = null;
        self.scene.rockets.deinit(self.gpa);
        self.out.deinit(self.gpa);
        self.popups.deinit(self.gpa);
        self.effects.deinit(self.gpa);
        self.shadows.deinit(self.gpa);
        self.gpa.free(self.nav_cells);
        self.nav_cells = &.{};
        for (self.rt.objects.items) |o| if (o.host) |h| {
            native(h).actor.deinit(self.gpa);
            native(h).growth.skills.deinit(self.gpa);
            self.gpa.destroy(native(h));
        };
        self.rt.deinit();
        self.arena_state.deinit();
    }

    fn native(h: *anyopaque) *object.Native {
        return @ptrCast(@alignCast(h));
    }

    pub fn nativeOf(obj: *Object) *object.Native {
        return native(obj.host.?);
    }

    /// Object with native part `init`. The native part is allocated first so OOM never
    /// leaves an object without `host`.
    pub fn addObject(self: *World, name: []const u8, cls: *@import("../script.zig").object.Class, init: object.Native) !*Object {
        const n = try self.gpa.create(object.Native);
        errdefer self.gpa.destroy(n);
        n.* = init;
        const o = try self.rt.createObject(name, cls);
        o.host = n;
        return o;
    }

    /// Location object from script file `file` (name = file without extension); the level
    /// object becomes `self.level`. Null for non-object files and classes that fail to load
    /// (logged).
    pub fn addScriptObject(self: *World, file: []const u8) !?*Object {
        const ext = std.fs.path.extension(file);
        if (object.kindOf(ext) == .other) return null;
        const cls = self.rt.loadClass(file) catch |err| {
            std.log.warn("{s}: {s}:{d}: {s} ({t})", .{ file, self.rt.diag_file, self.rt.diag.line, self.rt.diag.message, err });
            return null;
        };
        var nat = object.nativeFor(ext);
        nat.from_file = true;
        const obj = try self.addObject(file[0 .. file.len - ext.len], cls, nat);
        if (nativeOf(obj).kind == .level) self.level = obj;
        return obj;
    }

    /// Level actorScale, default 0.15 (0x51e24c, 0x421907).
    pub fn actorScale(self: *World) f32 {
        var s = model_cache.default_actor_scale;
        if (self.level) |l| if (l.getVar("actorScale")) |v| {
            if (v.value.toFloat() > 0) s = v.value.toFloat();
        };
        return s;
    }

    pub const max_actions = 4;
    pub const AreaAction = struct { action: u8, name: []const u8 };

    pub const ExamineEntry = union(enum) {
        /// Action k (`funcID`, `funcID1`…): string.tab operation id.
        action: struct { k: u8, id: i32 },
        /// "Use <item>" (`use_item_N`, held by the party, counter > 0).
        use: *Object,
        cancel,
    };

    /// Background point a sound plays at: projected x, y, z for actors and items; pos_x,
    /// pos_y for background animations; none for levels and areas.
    pub fn soundPos(self: *World, o: *Object) ?[2]f32 {
        const n = nativeOf(o);
        if (n.kind == .actor or isGroundItem(o)) {
            const q = self.cam.project(fields.pos(o));
            return .{ q.x, q.y };
        }
        if (n.kind == .animation or n.kind == .active_animation) {
            return .{ @floatFromInt(o.getInt("pos_x")), @floatFromInt(o.getInt("pos_y")) };
        }
        return null;
    }

    pub const max_party = 6;

    /// The party in panel order (see `party`); `slice()` on a local copy.
    pub const Party = struct {
        buf: [max_party]*Object = undefined,
        len: usize = 0,
        pub fn slice(self: *const Party) []const *Object {
            return self.buf[0..self.len];
        }
    };

    /// The party in panel order: the three `gamestart` heroes, then those who joined.
    pub fn party(self: *World) Party {
        var p: Party = .{};
        for ([_][]const u8{ "Sullivan", "Ovitz", "Trantigne" }) |name| {
            const o = self.actorObject(name) orelse continue;
            if (!nativeOf(o).hero or nativeOf(o).deleted) continue;
            p.buf[p.len] = o;
            p.len += 1;
        }
        for (self.rt.objects.items) |o| {
            const nat = nativeOf(o);
            if (p.len == max_party) break;
            if (!nat.hero or nat.kind != .actor or nat.deleted) continue;
            if (std.mem.indexOfScalar(*Object, p.buf[0..p.len], o) != null) continue;
            p.buf[p.len] = o;
            p.len += 1;
        }
        return p;
    }

    /// The selected hero's object.
    pub fn selectedHero(self: *World) ?*Object {
        return self.actorObject(self.selected_hero);
    }

    /// Actor by name (case-insensitive).
    pub fn actorObject(self: *World, name: []const u8) ?*Object {
        const o = self.rt.findObject(name) orelse return null;
        return if (nativeOf(o).kind == .actor) o else null;
    }

    pub fn speedScale(self: *World) f32 {
        const l = self.level orelse return 1;
        const v = l.getVar("speedScale") orelse return 1;
        return if (v.value.toFloat() > 0) v.value.toFloat() else 1;
    }

    pub fn stringOr(self: *World, id: i32, fallback: []const u8) []const u8 {
        if (self.strings) |t| if (t.get(id)) |s| return s;
        return fallback;
    }

    /// Scene moving to another location (LOADLEVEL, PREVLEVEL): name, next command and
    /// dialogue file; strings in `gpa`.
    pub const MovingScene = struct { name: []u8, pc: usize, dialog_file: []u8 };

    /// A class that failed to load: out of memory propagates, anything else is logged
    /// and counted (like missing builtins) and the caller skips the object.
    pub fn classMissing(self: *World, file: []const u8, err: anyerror) !void {
        if (err == error.OutOfMemory) return err;
        std.log.warn("class {s}: {t}", .{ file, err });
        try self.countMissing("class ", file);
    }

    /// Counts unimplemented scene commands (alongside builtins).
    pub fn countMissing(self: *World, prefix: []const u8, name: []const u8) !void {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, name }) catch return;
        const gop = try self.rt.missing_builtins.getOrPut(self.rt.arena(), key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.rt.arena().dupe(u8, key);
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
    }

    /// Location actors in runtime order, scanned incrementally.
    pub fn actorObjects(self: *World) []*Object {
        const objs = self.rt.objects.items;
        while (self.actor_scanned < objs.len) {
            const o = objs[self.actor_scanned];
            if (o.host == null) break; // still being created; resume next call
            if (nativeOf(o).kind == .actor) self.actor_objs.append(self.arena_state.allocator(), o) catch break;
            self.actor_scanned += 1;
        }
        return self.actor_objs.items;
    }

    pub fn screenPos(self: *World, o: *Object) [2]f32 {
        const p = self.cam.project(fields.pos(o));
        return .{ p.x, p.y };
    }

    /// The game's rand(): one state per process (crt_rand.global).
    pub fn crt(_: *const World) *crt_rand.Rand {
        return &crt_rand.global;
    }

    /// The level inherits CombatLevel: a battle.
    pub fn isCombat(self: *World) bool {
        const l = self.level orelse return false;
        return l.class.isA("combatlevel");
    }
};

/// Live item or weapon (not deleted).
pub fn isActor(o: *Object) bool {
    return World.nativeOf(o).kind == .actor;
}

/// Party hero flag (`.hro` objects and joined heroes).
pub fn isHero(o: *Object) bool {
    return World.nativeOf(o).hero;
}

/// A party hero that is an actor (the hero roster's members).
pub fn isHeroActor(o: *Object) bool {
    return isHero(o) and isActor(o);
}

pub fn isItem(o: *Object) bool {
    const n = World.nativeOf(o);
    return (n.kind == .item or n.kind == .weapon) and !n.deleted;
}

/// Item on the ground: drawn when it has a model and place == 0 (`inventory.Place.ground`,
/// 0x4adb20). `visible` is only the hero's blink (0x4adb8c), not visibility.
pub fn isGroundItem(o: *Object) bool {
    if (!isItem(o) or !o.enabled) return false;
    if (o.getInt("place") != 0) return false;
    return fields.meshFile(o).len > 0;
}

pub fn actorOf(o: *Object) *actor_mod.Actor {
    return &World.nativeOf(o).actor;
}

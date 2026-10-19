//! The game over location worlds: current, left ones (cache; restore() on return, like
//! the exe's r*.dat cache), previous, party at battle entry, loaded save and discovered
//! immunities. One level transition (LEVEL_Load) for the viewer and the gorky-tool
//! playthrough; their own steps go before `switchTo` and between it and `finish`.

const std = @import("std");
const state_groups = @import("state.zig").groups;
const fields = @import("fields.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const world_mod = @import("state.zig").world;
const World = world_mod.World;
const levels = @import("world.zig").levels;
const spawn = @import("world.zig").spawn;
pub const life = @import("game/life.zig");
const bi_level = @import("builtins.zig").level;
const bi_actors = @import("builtins.zig").actors;
const scenes = @import("scene.zig").scenes;
const crt_rand = @import("crt_rand.zig");
const Party = @import("world.zig").party.Party;
const save_mod = @import("save.zig");
const save_apply = @import("game/save_apply.zig");
const immunity = @import("battle.zig").immunity;
const turns = @import("combat.zig").turns;
const battle_tick = @import("combat.zig").tick;
const control = @import("combat.zig").control;
const model_cache = @import("actor.zig").model_cache;
const audio_scene = @import("audio.zig").scene;
const font = @import("formats.zig").font;
const lang = @import("formats.zig").lang;
const archive = @import("formats.zig").archive;

pub const Game = struct {
    io: Io,
    gpa: Allocator,
    dat: Io.Dir,
    models: ?*model_cache.Cache,
    world: ?*World = null,
    /// Left locations by name (battles are not cached: rebuilt on next entry).
    cache: std.StringHashMapUnmanaged(*World) = .empty,
    /// Where we came from (not a battle): return from battle without backLevel, Backspace, scenes.
    prev: ?[]u8 = null,
    /// Party at entry to the current battle, for retry after a loss.
    entry_party: ?Party = null,
    /// Loaded save: its locations load with saved state on first entry.
    saved: ?save_mod.Save = null,
    /// Saved locations already built for GO_RunFun after a load; entered like a saved one.
    prebuilt: std.StringHashMapUnmanaged(*World) = .empty,
    immunity: immunity.Known = .{},
    /// Dialog font (`02_dialog` + language set): subtitle pages for every world.
    /// Glyphs point into `dialog_font_bytes`; the Game must not move after loading.
    dialog_font: ?font.Font = null,
    dialog_font_bytes: ?[]u8 = null,

    pub fn deinit(self: *Game) void {
        self.reset();
        self.cache.deinit(self.gpa);
        self.prebuilt.deinit(self.gpa);
        if (self.dialog_font_bytes) |b| self.gpa.free(b);
    }

    /// Load the dialog font from `common/other.dat`; missing font — one page per line.
    pub fn loadDialogFont(self: *Game) void {
        var arc = archive.Archive.open(self.io, self.gpa, self.dat, "common/other.dat") catch return;
        defer arc.close(self.io, self.gpa);
        const bytes = lang.readFont(self.io, self.gpa, &arc, "02_dialog", lang.language(self.io, self.gpa, self.dat)) orelse return;
        self.dialog_font = font.parse(bytes) catch {
            self.gpa.free(bytes);
            return;
        };
        self.dialog_font_bytes = bytes;
    }

    /// New game or load: worlds, cache, battle party, save, immunities.
    pub fn reset(self: *Game) void {
        self.closeWorld();
        var it = self.cache.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.destroy();
            self.gpa.free(e.key_ptr.*);
        }
        self.cache.clearRetainingCapacity();
        var pit = self.prebuilt.iterator();
        while (pit.next()) |e| {
            e.value_ptr.*.destroy();
            self.gpa.free(e.key_ptr.*);
        }
        self.prebuilt.clearRetainingCapacity();
        self.setPrev(null) catch unreachable; // null allocates nothing
        if (self.entry_party) |*p| p.deinit();
        self.entry_party = null;
        if (self.saved) |*s| s.deinit();
        self.saved = null;
        self.immunity = .{};
    }

    pub fn closeWorld(self: *Game) void {
        if (self.world) |w| w.destroy();
        self.world = null;
    }

    pub fn setPrev(self: *Game, name: ?[]const u8) !void {
        const copy = if (name) |n| try self.gpa.dupe(u8, n) else null;
        if (self.prev) |p| self.gpa.free(p);
        self.prev = copy;
    }

    /// World options every game world gets: lookup of other locations, the game's
    /// immunities and dialog font.
    fn worldOptions(self: *Game, opts: life.Options) life.Options {
        var o = opts;
        o.resolver = .{ .ctx = self, .find = findCached };
        o.immunity = &self.immunity;
        o.dialog_font = if (self.dialog_font) |*f| f else null;
        return o;
    }

    /// Make a new world for `name` current (the old current is destroyed; `name` must not
    /// come from it). `ws`: its saved state, applied and marked loaded.
    pub fn open(self: *Game, name: []const u8, opts: life.Options, ws: ?*save_mod.WorldState) !*World {
        self.closeWorld();
        const w = try life.create(self.io, self.gpa, self.dat, name, self.models, self.worldOptions(opts));
        self.world = w;
        if (ws) |st| {
            try save_apply.apply(st, w);
            st.level = "";
            // A hero recreated by the save (joined elsewhere: Medusa, MacFadden) exists
            // only now; select them again.
            if (opts.hero) |h| w.setSelectedHero(h);
        }
        return w;
    }

    /// Retry after a loss: the same battle with the party as it entered.
    pub fn retry(self: *Game) !*World {
        const w = self.world orelse return error.NoWorld;
        const name = try self.gpa.dupe(u8, w.level_name);
        defer self.gpa.free(name);
        return self.open(name, .{ .party = if (self.entry_party) |*p| p else null }, null);
    }

    /// Load save `sv` (takes ownership): fresh game, its immunities, current location with
    /// its selected hero.
    pub fn load(self: *Game, sv: save_mod.Save) !*World {
        self.reset();
        self.saved = sv;
        const s = &self.saved.?;
        self.immunity = .{ .table = s.imm };
        const ws = s.find(s.current) orelse return error.BadSave;
        return self.open(s.current, .{ .hero = s.hero }, ws);
    }

    /// Save: current location, left ones, unvisited ones from the loaded save, immunities.
    pub fn snapshot(self: *Game, sv: *save_mod.Save) !void {
        const w = self.world orelse return error.NoWorld;
        sv.current = w.level_name;
        sv.hero = w.selected_hero;
        sv.imm = self.immunity.table;
        try sv.addWorld(w);
        var it = self.cache.valueIterator();
        while (it.next()) |cw| try sv.addWorld(cw.*);
        var pit = self.prebuilt.valueIterator();
        while (pit.next()) |pw| try sv.addWorld(pw.*);
        if (self.saved) |*old| for (old.worlds.items) |ws| {
            if (ws.level.len == 0 or sv.find(ws.level) != null) continue;
            try sv.addState(ws);
        };
    }

    /// Pending level change: LEVEL_Load or "back" (a scene returning to the previous location).
    pub fn pendingLevel(self: *Game) ?[]const u8 {
        const w = self.world orelse return null;
        if (w.flow.want_prev_level) {
            w.flow.want_prev_level = false;
            if (self.prev) |p| w.flow.pending_level = p;
        }
        return w.flow.pending_level;
    }

    pub const Switch = struct {
        /// Left location (gpa): AfterBattle(from) after returning from battle.
        from: []u8,
        /// The left location was destroyed (battle); otherwise cached.
        destroyed: bool,
        /// The new one came from the cache (restore()); otherwise created.
        restored: bool,
        after_battle: bool,
        steps: []state_groups.LoadStep,
        moving: ?World.MovingScene,
    };

    /// Switch to `next_raw` (LEVEL_Load): party and selected hero carry over; the old
    /// location is cached (a battle is destroyed); the new one comes from the cache
    /// (restore()), the save, or is created. Then call `finish`.
    pub fn switchTo(self: *Game, next_raw: []const u8) !Switch {
        const old = self.world orelse return error.NoWorld;
        const next = try self.gpa.dupe(u8, next_raw);
        defer self.gpa.free(next);
        const from = try self.gpa.dupe(u8, old.level_name);
        errdefer self.gpa.free(from);
        const combat = old.isCombat();
        const load_ab = old.flow.load_ab;
        old.flow.load_ab = false;
        const steps = try levels.takeLoadSteps(old);
        errdefer {
            state_groups.freeLoadSteps(self.gpa, steps);
            self.gpa.free(steps);
        }
        const moving = try scenes.takeMovingScene(old);
        errdefer if (moving) |m| {
            self.gpa.free(m.name);
            self.gpa.free(m.dialog_file);
        };
        var party = try Party.capture(self.gpa, old);
        var keep_party = false;
        defer if (!keep_party) party.deinit();
        var hero_buf: [64]u8 = undefined;
        const hero = hero_buf[0..@min(old.selected_hero.len, hero_buf.len)];
        @memcpy(hero, old.selected_hero[0..hero.len]);
        old.flow.pending_level = null;
        // Camera requests (DOLLY, zoom reset) don't survive the switch: loading resets the
        // camera (0x41fb09). Otherwise DOLLY(…,200) issued with LOADLEVEL when skipping a
        // scene zoomed 2× on return.
        old.out.dolly = null;
        old.out.zoom_reset = false;
        try levels.leave(old, next);
        // A skipped scene deletes and leaves in one tick: no frame pass between them.
        spawn.releaseRemoved(old);
        self.world = null;
        if (combat) old.destroy() else {
            // Lowercase keys: scripts write level names in any case (findCached and
            // Save.find ignore case too).
            const key = try std.ascii.allocLowerString(self.gpa, from);
            errdefer self.gpa.free(key);
            try self.cache.put(self.gpa, key, old);
            try self.setPrev(from);
        }
        var restored = false;
        const next_key = try std.ascii.allocLowerString(self.gpa, next);
        defer self.gpa.free(next_key);
        if (self.cache.fetchRemove(next_key)) |kv| {
            self.gpa.free(kv.key);
            self.world = kv.value;
            restored = true;
            const w = kv.value;
            w.out.dolly = null;
            w.out.zoom_reset = false;
            w.setSelectedHero(hero);
            // Arriving heroes before restore(): in the exe they are already in the global
            // list, so the level restore()'s PlaceHeroes places them too (0x411cd0).
            try party.apply(w, true);
            try levels.reenter(w);
        } else if (self.prebuilt.fetchRemove(next_key)) |kv| {
            // Built from the save for GO_RunFun: entered like a saved location.
            self.gpa.free(kv.key);
            self.world = kv.value;
            try party.apply(kv.value, false);
        } else if (if (self.saved) |*sv| sv.find(next) else null) |ws| {
            // Saved state first, then the current party (it is newer).
            const w = try self.open(next, .{ .hero = hero }, ws);
            try party.apply(w, false);
        } else _ = try self.open(next, .{ .party = &party, .hero = hero }, null);
        const w = self.world.?;
        w.setSelectedHero(hero);
        if (w.isCombat()) {
            if (self.entry_party) |*p| p.deinit();
            self.entry_party = party;
            keep_party = true;
        }
        return .{ .from = from, .destroyed = combat, .restored = restored, .after_battle = combat or load_ab, .steps = steps, .moving = moving };
    }

    /// End of the switch: deferred calls, AfterBattle, moved scene. All three run; the first
    /// error is returned.
    pub fn finish(self: *Game, sw: Switch) !void {
        defer self.gpa.free(sw.from);
        const w = self.world.?;
        var first: ?anyerror = null;
        runLoadSteps(w, sw.steps) catch |e| {
            first = e;
        };
        if (sw.after_battle) afterBattle(w, sw.from) catch |e| {
            first = first orelse e;
        };
        if (sw.moving) |m| scenes.resumeScene(w, m) catch |e| {
            first = first orelse e;
        };
        if (first) |e| return e;
    }

    /// Player-requested switch (Backspace, console `back`).
    pub fn goTo(self: *Game, name: []const u8) void {
        if (self.world) |w| w.flow.pending_level = name;
    }

    /// Victory: back to where the battle started (battle `backLevel`, else previous);
    /// false if nowhere.
    pub fn leaveBattle(self: *Game) bool {
        const w = self.world orelse return false;
        const p = backLevel(w) orelse self.prev orelse return false;
        w.flow.pending_level = p;
        if (w.battle) |*b| b.over_ticks = 0;
        return true;
    }

    /// Game over: the GAMEOVER scene finished — true once.
    pub fn takeGameOver(self: *Game) bool {
        const w = self.world orelse return false;
        if (!w.flow.game_over or w.scene.runner != null) return false;
        w.flow.game_over = false;
        return true;
    }

    /// World of a left location by name, for GO_RunFun: cached, or (after a load) built
    /// from the loaded save (`prebuilt`). Deviation: the exe reaches only the previous level
    /// object ([0x592844]) and a load clears it (0x411890), which softlocks e.g. the matrix
    /// disc in 01_port_store.
    fn findCached(ctx: *anyopaque, name: []const u8) anyerror!?*World {
        const self: *Game = @ptrCast(@alignCast(ctx));
        var buf: [64]u8 = undefined;
        if (name.len > buf.len) return null;
        const key = std.ascii.lowerString(&buf, name);
        if (self.cache.get(key)) |w| return w;
        if (self.prebuilt.get(key)) |w| return w;
        const ws = (if (self.saved) |*sv| sv.find(name) else null) orelse return null;
        if (ws.level.len == 0) return null;
        const w = try life.create(self.io, self.gpa, self.dat, name, self.models, self.worldOptions(.{}));
        errdefer w.destroy();
        try save_apply.apply(ws, w);
        ws.level = "";
        const k = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(k);
        try self.prebuilt.put(self.gpa, k, w);
        return w;
    }
};

/// Player hero selection (portrait, keys 1–6; 0x45acb0): not a hero with
/// `avoidEnumerate` 1; HERO_SELECTED is `selected_hero` (scenario.zig), in battle selects the fighter
/// (0x455490), always plays "selecthero". (`walkMode` 1 would allow only Sullivan;
/// it is 0 in adjust.kdt.)
pub fn selectHero(w: *World, name: []const u8) void {
    const o = w.actorObject(name) orelse return;
    if (o.getInt("avoidEnumerate") == 1) return;
    w.selected_hero = o.name;
    if (w.battle) |*b| control.select(b, w, o);
    w.out.sound(w.gpa, "selecthero", null);
}

/// Level music input for `audio.scene.Scene.startMusic`.
pub fn levelMusic(w: *World) audio_scene.LevelMusic {
    return .{ .name = w.level_name, .combat = w.battle_music };
}

/// Input for `audio.scene.Scene.update`; refills `w.out.ambients` from ambient objects.
pub fn audioInput(w: *World) !audio_scene.Input {
    w.out.ambients.clearRetainingCapacity();
    for (w.rt.objects.items) |o| {
        const n = World.nativeOf(o);
        const a = n.ambient orelse continue;
        try w.out.ambients.append(w.gpa, .{ .obj = o, .wav = a.wav, .pos = a.pos, .active = o.enabled and !n.deleted });
    }
    return .{ .out = &w.out, .ticks = w.ticks, .enemy_music = if (w.battle) |b| b.enemyMusic() else null };
}

/// One world tick in the exe frame order (0x420296…0x420328): fade (0x420110), battle
/// (0x45a870), scenes (0x479120), then the objects' +0x24 pass — actor animation and motion
/// (0x4262d0), effects, weapon ticks — then presentation. The other pre-battle calls are the
/// host's (zoom 0x41fe80, GUI mode 0x45ba70, scroll clamp 0x42cf60); the late +0x30 pass
/// (0x4269b0) drops references to removed objects, which our objects never need.
pub fn tick(w: *World) !void {
    w.ticks += 1;
    crt_rand.frames +%= 1;
    scenes.tickFade(w);
    // Battle pauses during a dialogue/scene or under the level-up window. Under that window
    // the battle mode doesn't tick (0x45a8f6), but damage, exp and "Level up" popups —
    // world objects — run out (0x4cf5c6 +40, 0x48fb78 +75).
    if (w.battle) |*b| if (w.scene.runner == null) {
        if (w.gui_hold) turns.tickPopups(b) else try battle_tick.tick(b, w);
    };
    try scenes.tick(w);
    try life.tickObjects(w);
    try life.tickPresentation(w);
}

/// Run calls deferred until entering this location, then free them. A LEVEL_Load among
/// them defers the rest again.
fn runLoadSteps(self: *World, steps: []const state_groups.LoadStep) !void {
    defer {
        state_groups.freeLoadSteps(self.gpa, steps);
        self.gpa.free(steps);
    }
    const ctx: *anyopaque = self;
    const level = self.level orelse return;
    self.flow.replaying = true;
    defer self.flow.replaying = false;
    for (steps) |st| {
        const f: world_mod.Builtin = switch (st.kind) {
            .level_load => bi_level.biLevelLoad,
            .place_heroes => bi_level.biPlaceHeroes,
            .place_actor => bi_actors.biPlaceActor,
            .fade_in => bi_level.biFadeIn,
            .disable_heroes => bi_level.biDisableHeroes,
        };
        _ = try f(ctx, &self.rt, level, st.args);
    }
}

/// Idle line (0x451110): a party of two or more, 1800 ticks without input — the
/// selected hero says `idle_<su|ov|tr>_01.dlg` (Ovitz first plays "medicine").
/// `idle` is the host's counter of ticks without input; scenes and battles reset it.
pub fn idleChatter(w: *World, idle: *u64, ticks: u64) !void {
    if (w.battle != null or w.scene.runner != null or w.scene.cutscene) {
        idle.* = 0;
        return;
    }
    const members = w.party();
    if (members.slice().len < 2) return;
    idle.* += ticks;
    if (idle.* < 1800) return;
    idle.* = 0;
    const hero = w.selectedHero() orelse return;
    const file: []const u8 = switch (fields.nameId(hero)) {
        20 => "idle_su_01.dlg",
        21 => "idle_ov_01.dlg",
        22 => "idle_tr_01.dlg",
        else => return,
    };
    if (fields.nameId(hero) == 21) world_mod.actorOf(hero).play("medicine", false, true);
    try scenes.startDialog(w, hero.name, file);
}

/// After winning battle `name`: the level's AfterBattle(name) (0x41fb44).
fn afterBattle(w: *World, name: []const u8) !void {
    const l = w.level orelse return;
    // The script may keep the argument in a variable (assignment stores the
    // slice); the caller's buffer dies after the switch.
    _ = try w.rt.callIfExists(l, "AfterBattle", &.{.{ .string = try w.rt.arena().dupe(u8, name) }});
}

/// Where to return after battle: the battle level's `backLevel` (park → silos).
fn backLevel(w: *World) ?[]const u8 {
    const l = w.level orelse return null;
    const b = l.getString("backLevel");
    return if (b.len > 0) b else null;
}

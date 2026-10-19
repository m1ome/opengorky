//! gorky-tool play: headless playthrough by commands (scripts/fullgame.sh,
//! regress.sh, linux/check.sh).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");

/// Headless playthrough: commands `wait:N`, `scene`, `goto:AREA`,
/// `click:X,Y`, `hero:NAME`, `use:ITEM:TARGET`. Level transitions, auto-battle
/// and the AfterBattle return work as in the viewer. `goto:`/`click:` go through
/// `actions.click` (clickAction): only the selected hero walks, companions stay —
/// not the viewer's party walk (`clickPlay` → `partyWalk`).
pub const PlayGame = struct {
    io: Io,
    gpa: Allocator,
    dat: Io.Dir,
    out: *Io.Writer,
    /// Level worlds, transitions, party at battle entry, save (game.Game).
    game: og.game.Game,
    names: std.heap.ArenaAllocator,
    ticks: u64 = 0,
    last_scene: []const u8 = "",
    last_sub: ?[*]const u8 = null,
    lost: bool = false,
    /// Loop guard: the same scene on the same level or the same battle
    /// `loop_limit` times in a row fails the run (the crazy-Medusa scene and its
    /// battle used to repeat).
    loop: bool = false,
    rep_scene: []const u8 = "",
    rep_scene_level: []const u8 = "",
    rep_scene_n: u32 = 0,
    rep_battle: []const u8 = "",
    rep_battle_from: []const u8 = "",
    rep_battle_n: u32 = 0,
    /// End-of-game scene (GUI_CREDITS).
    finished: bool = false,
    battles: u32 = 0,
    /// `blog`: strike log and roster of every battle.
    battle_log: bool = false,
    retries: u32 = 0,
    /// Ticks in a row with the scene camera outside a scene (mouse does not scroll).
    cam_stuck: u32 = 0,
    /// Debug: full health and ammo before every battle.
    autorefill: bool = false,
    /// Spend level points before every battle (as a player): accuracy up to 90,
    /// the rest into health.
    autolevel: bool = false,
    /// Before every battle: heroes without armor get the party's best unworn armor.
    autoequip: bool = false,
    /// Debug: heroes take no damage in battles (auto-battle cannot handle tactical fights).
    godmode: bool = false,
    /// `passive`: heroes do nothing in battle — each turn ends at once (to watch enemy AI).
    passive: bool = false,
    /// `counters`: with `passive` the hero still counterattacks (autoCounter).
    counters: bool = false,
    /// Unimplemented functions and commands across all levels.
    missing: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// Scene starts by name (a scene continuing after its LOADLEVEL is not a start).
    scene_starts: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// `oncecheck`: at the end, a scene started twice fails the run unless the scripts
    /// re-trigger it by design (`retriggered`).
    once: bool = false,
    /// `autosaveload`: after each transition into a non-battle level, save the whole game
    /// and load it back at the first idle moment (as a player saving everywhere).
    autosaveload: bool = false,
    want_saveload: bool = false,
    /// Ticks without input for the idle line (game.idleChatter); every script command
    /// and level switch is input, like a click in the viewer.
    idle_ticks: u64 = 0,

    const World = og.state.world.World;

    /// Current world.
    pub fn cur(self: *PlayGame) *World {
        return self.game.world.?;
    }

    /// Run flags (`noautorefill` — battle-entry health as a player has it, regress.sh).
    pub fn setFlag(self: *PlayGame, cmd: []const u8) bool {
        inline for (.{
            .{ "godmode", "godmode", true },   .{ "nogodmode", "godmode", false },        .{ "passive", "passive", true },
            .{ "counters", "counters", true }, .{ "autoequip", "autoequip", true },       .{ "autolevel", "autolevel", true },
            .{ "blog", "battle_log", true },   .{ "autorefill", "autorefill", true },     .{ "noautorefill", "autorefill", false },
            .{ "oncecheck", "once", true },    .{ "autosaveload", "autosaveload", true },
        }) |f| if (std.mem.eql(u8, cmd, f[0])) {
            @field(self, f[1]) = f[2];
            return true;
        };
        return false;
    }

    pub fn collectMissing(self: *PlayGame, w: *World) !void {
        var it = w.rt.missing_builtins.iterator();
        while (it.next()) |e| {
            const key = try self.names.allocator().dupe(u8, e.key_ptr.*);
            const gop = try self.missing.getOrPut(self.gpa, key);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += e.value_ptr.*;
        }
        w.rt.missing_builtins.clearRetainingCapacity();
    }

    const loop_limit = 3;

    /// The same event (`name` at `where`) in a row; `loop_limit` times is an error.
    fn noteRepeat(self: *PlayGame, last: *[]const u8, last_where: *[]const u8, n: *u32, name: []const u8, where: []const u8, what: []const u8) !void {
        if (std.ascii.eqlIgnoreCase(last.*, name) and std.ascii.eqlIgnoreCase(last_where.*, where)) {
            n.* += 1;
        } else {
            const a = self.names.allocator();
            last.* = try a.dupe(u8, name);
            last_where.* = try a.dupe(u8, where);
            n.* = 1;
        }
        if (n.* >= loop_limit and !self.loop) {
            self.loop = true;
            self.lost = true;
            try self.out.print("[{d:>6}] LOOP: {s} '{s}' ({s}) {d} times in a row\n", .{ self.ticks, what, name, where, n.* });
        }
    }

    pub fn deinit(self: *PlayGame) void {
        self.game.deinit();
        self.missing.deinit(self.gpa);
        self.scene_starts.deinit(self.gpa);
        self.names.deinit();
    }

    /// One tick: world, log, battle, transitions.
    pub fn step(self: *PlayGame) !void {
        const w = self.cur();
        try og.game.tick(w);
        try og.game.idleChatter(w, &self.idle_ticks, 1);
        // No audio/video host here: drop the requests, or they grow for the whole run.
        w.out.sound_events.clearRetainingCapacity();
        w.out.voice_events.clearRetainingCapacity();
        w.out.music_events.clearRetainingCapacity();
        w.out.video_requests.clearRetainingCapacity();
        self.ticks += 1;
        const sc = if (w.scene.runner) |s| s.name else "";
        if (!std.mem.eql(u8, sc, self.last_scene)) {
            try self.out.print("[{d:>6}] {s}: scene '{s}'\n", .{ self.ticks, w.level_name, sc });
            self.last_scene = sc;
            if (sc.len > 0 and !std.mem.eql(u8, sc, "dialog")) {
                try self.noteRepeat(&self.rep_scene, &self.rep_scene_level, &self.rep_scene_n, sc, w.level_name, "scene");
                const gop = try self.scene_starts.getOrPut(self.gpa, sc);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try self.names.allocator().dupe(u8, sc);
                    gop.value_ptr.* = 0;
                }
                gop.value_ptr.* += 1;
            }
        }
        if (w.scene.subtitle) |st| if (self.last_sub != st.text.ptr) {
            try self.out.print("[{d:>6}]   {s}: {s}\n", .{ self.ticks, st.speaker, st.text[0..@min(st.text.len, 70)] });
            self.last_sub = st.text.ptr;
        };
        if (!w.scene.autocamera and w.scene.runner == null and !w.scene.cutscene and w.battle == null) {
            self.cam_stuck += 1;
            if (self.cam_stuck == 300) try self.out.print("[{d:>6}] {s}: scene camera outside a scene (mouse does not scroll)\n", .{ self.ticks, w.level_name });
        } else self.cam_stuck = 0;
        if (w.battle) |*b| {
            if (self.battle_log and b.log == null) {
                b.log = self.out;
                for (b.fighters.items) |f| try self.out.print("  {s:<14} {t:<5} hp {d} move {d} weapon {s}\n", .{
                    f.obj.name, f.side, f.hp(), og.fields.walkRange(f.obj), if (f.weapon) |o| o.name else "-",
                });
            }
            b.auto_heroes = !self.passive;
            if (self.passive and b.idle()) {
                if (b.phase == .player or (b.phase == .counter and !self.counters)) {
                    try og.combat.turns.endTurn(b, w);
                } else if (b.phase == .counter) try og.combat.turns.autoCounter(b, w);
            }
            b.lenient_loss = true;
            w.debug.god = self.godmode;
            // No result in 60 turns (e.g. Reverend beetles freeze every hero each turn and
            // godmode prevents losing) — treated as a loss:
            // retry with another seed.
            const stuck = b.turn > 60 and b.phase != .won and b.phase != .lost;
            if (stuck) try self.out.print("[{d:>6}] battle {s} stuck: turn {d}\n", .{ self.ticks, w.level_name, b.turn });
            if (b.phase == .won or b.phase == .lost or stuck) {
                if (!stuck) try self.out.print("[{d:>6}] battle {s}: {t} on turn {d}\n", .{ self.ticks, w.level_name, b.phase, b.turn });
                self.battles += 1;
                if (b.phase == .lost or stuck) {
                    if (self.retries < 6 and self.game.entry_party != null) {
                        self.retries += 1;
                        try self.out.print("[{d:>6}] battle retry {s} ({d})\n", .{ self.ticks, w.level_name, self.retries });
                        try self.collectMissing(w);
                        const nw = try self.game.retry();
                        nw.crt().seed(0x6f726b79 +% self.retries *% 7919);
                        if (self.autorefill) refill(nw);
                        return;
                    }
                    self.lost = true;
                    return;
                }
                self.retries = 0;
                _ = self.game.leaveBattle();
            }
        }
        if (w.flow.game_over and !self.finished) {
            self.finished = true;
            try self.out.print("[{d:>6}] end of game ({s})\n", .{ self.ticks, w.level_name });
        }
        if (self.game.pendingLevel()) |next| try self.switchTo(next);
    }

    fn switchTo(self: *PlayGame, next_raw: []const u8) !void {
        const a = self.names.allocator();
        const next = try a.dupe(u8, next_raw);
        const w = self.cur();
        try self.out.print("[{d:>6}] transition {s} -> {s}\n", .{ self.ticks, w.level_name, next });
        if (std.mem.indexOf(u8, next, "__") != null and !w.isCombat()) try self.noteRepeat(&self.rep_battle, &self.rep_battle_from, &self.rep_battle_n, next, w.level_name, "battle");
        try self.collectMissing(w);
        const sw = try self.game.switchTo(next);
        self.idle_ticks = 0;
        const moved = sw.moving != null;
        const nw = self.cur();
        if (self.autolevel and nw.isCombat()) spendPoints(nw);
        if (self.autoequip and nw.isCombat()) equipArmor(nw);
        if (self.autorefill and nw.isCombat()) refill(nw);
        try self.game.finish(sw);
        // A current or morph glow still playing in a level we come back to (its actor is gone).
        const fx = &nw.effects;
        if (sw.restored and fx.beams.items.len + fx.morphs.items.len > 0)
            try self.out.print("[{d:>6}] {s}: leftover fx: beams {d} morphs {d}\n", .{ self.ticks, nw.level_name, fx.beams.items.len, fx.morphs.items.len });
        self.last_scene = "";
        // The scene that issued LOADLEVEL goes on here: logged, not counted as a start.
        if (moved) if (nw.scene.runner) |sc| {
            try self.out.print("[{d:>6}] {s}: scene '{s}' (continued)\n", .{ self.ticks, nw.level_name, sc.name });
            self.last_scene = sc.name;
        };
        self.want_saveload = self.autosaveload and !nw.isCombat();
    }

    /// Save the whole game and load it back (viewer save/load), once the level is idle.
    /// Called between steps: a step may hold the world it started with.
    pub fn saveLoad(self: *PlayGame) !void {
        const w = self.cur();
        if (w.scene.runner != null or w.scene.cutscene or w.scene.queue.items.len > 0 or w.battle != null or
            w.flow.pending_level != null or w.act.interaction != null or w.act.exploring != null) return;
        self.want_saveload = false;
        var sv: og.save.Save = .init(self.gpa);
        defer sv.deinit();
        try self.game.snapshot(&sv);
        var text: Io.Writer.Allocating = .init(self.gpa);
        defer text.deinit();
        try sv.write(&text.writer);
        const nw = try self.game.load(try og.save.Save.parse(self.gpa, text.written()));
        try self.out.print("[{d:>6}] saveload {s}\n", .{ self.ticks, nw.level_name });
        self.last_scene = "";
    }

    /// Scripts re-trigger these by design: ladders, lifts and gates run on every use, the
    /// sewer switch and valve on every toggle, the leaving-the-city line on every exit.
    const retriggered = [_][]const u8{
        "01_port_laddup",  "01_port_ladddown",          "04_city_laddup",           "04_city_ladddown",           "winda",        "winda_in",
        "winda_out",       "gateopen",                  "gateclose",                "02s_switch",                 "02s_zawor1ON", "02s_zawor1OFF",
        "museum-slavskyA", "city-leaving_city_slavsky", "city-leaving_city_medusa", "city-leaving_city_hutchens",
    };

    /// `oncecheck`: scenes started more than once that the scripts don't re-trigger.
    pub fn reportTwice(self: *PlayGame) !bool {
        var bad = false;
        var it = self.scene_starts.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.* < 2) continue;
            const ok = for (retriggered) |r| {
                if (std.ascii.eqlIgnoreCase(r, e.key_ptr.*)) break true;
            } else false;
            if (ok) continue;
            try self.out.print("SCENE TWICE: '{s}' started {d} times\n", .{ e.key_ptr.*, e.value_ptr.* });
            bad = true;
        }
        return bad;
    }

    /// Armor as a player would wear it: who has none gets the best from the party's
    /// backpacks (protection `armor` and resistances `pr*`: freeze and sleep).
    fn equipArmor(w: *World) void {
        const inv = og.inventory;
        for (w.rt.objects.items) |h| {
            if (!og.state.world.isHeroActor(h) or !h.enabled) continue;
            if (inv.equipment.armorItem(w, h) != null) continue;
            var best: ?*og.script.object.Object = null;
            var best_score: f32 = -1;
            for (w.rt.objects.items) |o| {
                const n = World.nativeOf(o);
                if (n.kind != .item or n.deleted or inv.item.typeOf(o) != .armor) continue;
                if (inv.item.placeOf(o) != .backpack) continue;
                const owner = w.rt.findObject(og.fields.owner(o)) orelse continue;
                if (!World.nativeOf(owner).hero) continue;
                var score = og.fields.getF(o, "armor");
                for ([_][]const u8{ "prFire", "prFreeze", "prGas", "prTranq", "prElect", "prEnergy", "prDist" }) |pr|
                    score += 10 * (o.getVarDyn(pr) orelse continue).value.toFloat();
                if (score > best_score) {
                    best = o;
                    best_score = score;
                }
            }
            const a = best orelse continue;
            og.fields.setOwner(a, h.name);
            inv.equipment.equip(w, h, a);
        }
    }

    fn spendPoints(w: *World) void {
        for (w.rt.objects.items) |o| {
            if (!og.state.world.isHeroActor(o)) continue;
            // Like a player in the points window (0x4b0bc0): accuracy up to 90, the rest to health.
            var pts: [7]i32 = @splat(0);
            for (0..@intCast(@max(0, og.inventory.points.takeLevelPoints(o)))) |_| {
                if (og.fields.getF(o, "accuracy") + og.num.toF32(pts[4]) < 90) pts[4] += 1 else pts[1] += 1;
            }
            og.inventory.points.applyLevelPoints(o, pts);
        }
    }

    /// Auto-battle: full hero health and at least 30 ammo in each of their packs.
    fn refill(w: *World) void {
        og.console.hero.healHeroes(w, null);
        _ = og.console.hero.addAmmo(w, 30, true);
    }

    /// Ticks until `done` returns true (battles always finish).
    pub fn runUntil(self: *PlayGame, limit: u64, comptime done: fn (*PlayGame, u64) bool) !void {
        var t: u64 = 0;
        while (t < limit or self.cur().battle != null) : (t += 1) {
            try self.step();
            if (self.lost or t > 200_000) return;
            if (self.cur().battle == null and done(self, t)) return;
        }
    }

    pub fn heroIdle(self: *PlayGame) bool {
        const w = self.cur();
        if (w.act.interaction != null or w.scene.runner != null or w.act.exploring != null) return false;
        const h = w.selectedHero() orelse return true;
        return !og.state.world.actorOf(h).busy();
    }
};

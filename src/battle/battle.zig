//! Turn-based battle on the `.cm` grid: fighters, turn phases, player and enemy
//! state. Rules (walking, aiming, hit, damage) are in battle/rules.zig and
//! battle/grid.zig, recovered from the exe.
//! `Battle` methods live here; behaviour lives in combat/* as free functions
//! taking `self: *Battle` first, called through the module (`turns.endTurn(b, w)`).

const std = @import("std");
const fields = @import("../fields.zig");
const Allocator = std.mem.Allocator;
const object = @import("../script.zig").object;
const Object = object.Object;
const rules = @import("rules.zig");
const grid_mod = @import("grid.zig");
const popup_mod = @import("../popup.zig");
const Popup = popup_mod.Popup;
const attacks = @import("attacks.zig");
const Lift = attacks.Lift;

const Tile = grid_mod.Tile;
const fighter_mod = @import("fighter.zig");
const Fighter = fighter_mod.Fighter;
const Side = fighter_mod.Side;

pub const max_path = 32;

pub const Plan = struct {
    path: [max_path]Tile = undefined,
    len: usize = 0,
    /// Path tile index to strike from (null = no strike).
    attack_at: ?usize = null,
    weapon: ?*Object = null,
    aim: grid_mod.Target = undefined,
    score: i32 = std.math.minInt(i32),
    /// For the log: path length to the nearest opponent from the start tile (100 = unreachable).
    foe_dist: f64 = 0,
};

pub const Phase = enum {
    /// Enemies walk onto the field (AIEnemyAppear).
    appear,
    player,
    enemy,
    /// A hero's counter-attack during the enemy turn (0x45bd70): strike only.
    counter,
    won,
    lost,
};

/// Barrel blast: weapon `explodeWeapon` (class 17, the 8 neighbours), tile,
/// ticks until the strike.
/// `order` is the weapon's place in the exe object list (creation number: newer first).
/// `credit` is who blew the barrel up (its +0x24aec → weapon +0x1ab0, 0x492055).
const Blast = struct { barrel: u16, weapon: *Object, tile: Tile, ticks: u32, order: usize, credit: ?u16 };

/// Strike result (0x4ced30): miss (+0x1a94), damage (+0x1a9c), luck (+0x1a98).
const Strike = rules.Strike;

const Pending = union(enum) {
    none,
    walk: u16,
    /// Attack: the hit lands `delay` ticks after the animation starts.
    attack: struct {
        who: u16,
        weapon: *Object,
        aim: grid_mod.Target,
        delay: u32,
        flight: u32 = 0,
        /// Ticks since the attack started; attacker's wait after the hit; victim lift.
        tick: u32 = 0,
        after: u32 = 0,
        lift: ?Lift = null,
        victim: ?u16 = null,
        /// Second rocket (Jet Elmer, 0x48a0ed): `second` ticks after the first, damage on
        /// each arrival.
        second: u32 = 0,
        second_in: ?u32 = null,
        flight2: u32 = 0,
        melee2_in: ?u32 = null,
        /// The target's reaction repeats without damage (code 7) `react` ticks after the hit.
        react: u32 = 0,
        react_in: ?u32 = null,
        /// Invisible (0x48a2a6): vanish `vanish` ticks after the hit.
        vanish: u32 = 0,
        vanish_in: ?u32 = null,
        /// Flash before the hit: tick from the animation start (MonsterAttack.pre).
        pre: ?u32 = null,
        launched: bool = false,
        hit1: bool = false,
        /// Hit when the attack animation finishes; then animation `then`.
        until_end: bool = false,
        then: ?[]const u8 = null,
        /// The attacker is still turning to the target (command 0x12 at the start of
        /// the attack queue, 0x4897e1): strike animation and countdown start after it.
        turning: bool = false,
        /// Strike roll from the attack start (0x47c58a → +0xec): every hit of this
        /// attack uses it (+0xf0 reads +0x1a94/+0x1a9c).
        strike: Strike = .{},
    },
    /// Waiting for animations to finish (hit, death).
    settle,
    /// Push (0x48d890): push_start, the hero walks into the obstacle's tile
    /// (push_walk), the obstacle slides to `to`, push_end.
    push: struct { hero: u16, obstacle: u16, to: Tile, stage: u8 = 0, anim: []const u8 = "", sound: []const u8 = "", sound_ticks: u32 = 0, begun: bool = false },
};

pub const max_fighters = 32;

/// Scratch buffers of one AI plan (combat/ai.zig) for an `n`-tile grid: the threat map,
/// path-length fields (one per foe, guard point, 4 decoys), the wave buffers and the
/// per-foe reach. The grid doesn't change during a battle, so they are allocated once.
const AiScratch = struct {
    danger: []u16 = &.{},
    dist: []f32 = &.{},
    visited: []u8 = &.{},
    queue: []grid_mod.QEntry = &.{},
    slot: []u8 = &.{},
    left: []f32 = &.{},

    pub fn ensure(self: *AiScratch, gpa: Allocator, n: usize) !void {
        if (self.danger.len == n) return;
        std.debug.assert(self.danger.len == 0); // grid size is fixed per battle
        errdefer self.deinit(gpa);
        self.danger = try gpa.alloc(u16, n);
        self.dist = try gpa.alloc(f32, n * (max_fighters + 1 + 4));
        self.visited = try gpa.alloc(u8, n);
        self.queue = try gpa.alloc(grid_mod.QEntry, 8 * n + 1);
        self.slot = try gpa.alloc(u8, n);
        self.left = try gpa.alloc(f32, n);
    }

    pub fn deinit(self: *AiScratch, gpa: Allocator) void {
        inline for (.{ "danger", "dist", "visited", "queue", "slot", "left" }) |f| {
            if (@field(self, f).len > 0) gpa.free(@field(self, f));
        }
        self.* = .{};
    }
};

const Seq = struct {
    side: Side,
    next: usize = 0,
    wait: u32 = 0,
    delay: u32 = 0,
    bombs: bool = false,
};

/// Time bomb or decoy on the field: a neutral fighter occupying its tile (`fighter`).
/// `large`: PutLargeTimeBomb (everyone dies). `ticked`: the clock already moved
/// this enemy turn (+0x24908).
pub const Bomb = struct { obj: *Object, tile: Tile, fighter: ?u16 = null, large: bool = false, ticked: bool = false };
const max_targets = 512;

pub const Battle = struct {
    gpa: Allocator,
    fighters: std.ArrayList(Fighter) = .empty,
    blocked: []bool,
    occupant: []u16,
    /// Remaining walk per tile for the selected fighter (`grid_mod.reach`).
    reach_left: []f32,
    /// Fire and gas on tiles (`.cm` tile +5 and +6 in the exe): turns until they die out.
    fire: []u8,
    gas: []u8,
    /// Flame phase of a burning tile (fire object +0x2cc, 32×32 row-major): 1..31
    /// from the shared rand() on ignition (0x4a69d5), 0 = not burning.
    fire_phase: [32][32]u8 = @splat(@splat(0)),
    width: u32,
    height: u32,
    phase: Phase = .appear,
    turn: i32 = 1,
    selected: ?u16 = null,
    pending: Pending = .none,
    /// Current enemy in the enemy phase and what it does.
    enemy_cursor: usize = 0,
    ai_stage: enum { plan, walk1, attack, attack2, walk2 } = .plan,
    /// Schizo's second strike weapon (0x4e0d70).
    schizo_second: ?*Object = null,
    ai_plan: Plan = .{},
    /// Enemy turn preview (0x499770, drawing 0x497f60): walk range while walking
    /// (command 0x31); then 14 ticks of attack tiles and the enemy (0x32), 44 more with
    /// effect tiles (0x33); then the strike.
    ai_show: ?struct { who: u16, stage: enum { walk, area, effect }, ticks: u32 = 0 } = null,
    /// The current enemy's attack was shown.
    ai_shown: bool = false,
    /// Enemy's walk range at its turn start (for the preview) and its attack tiles.
    ai_reach: []f32 = &.{},
    /// AI planning buffers (combat/ai.zig), sized from the grid on first use and reused.
    ai_scratch: AiScratch = .{},
    ai_target_buf: [max_targets]grid_mod.Target = undefined,
    ai_target_len: usize = 0,
    /// Heroes act on their own (same AI), for testing battles without a UI.
    auto_heroes: bool = false,
    /// Battle log (tool and debugging): attacks, damage, deaths.
    log: ?*std.Io.Writer = null,
    popups: std.ArrayList(Popup) = .empty,
    /// Blasts of destroyed barrels waiting to strike.
    blasts: std.ArrayList(Blast) = .empty,
    /// Push sound after 47 ticks (110 with a two-handed weapon, 0x4dc490).
    push_sound: ?struct { name: []const u8, ticks: u32 } = null,
    /// Ticks since the battle ended (pause before returning).
    over_ticks: u32 = 0,
    target_buf: [max_targets]grid_mod.Target = undefined,
    target_len: usize = 0,
    /// EndTurnGlobal from after_select_gui (battle still in the appear phase): the
    /// heroes' first turn is skipped (04__city_mfd).
    skip_turn: bool = false,
    /// CombatEnemiesAppear hook at the end of the appearance, only at battle start.
    started: bool = false,
    /// GUI_SelectMode("GUI_Staging") from after_select_gui: the battle starts as an
    /// enemy turn (their music, flag [0x6c4e88]); otherwise straight to the player turn.
    staging: bool = false,
    /// Side turn start sequence (0x498310/0x498650): pause, bombs, state damage one
    /// fighter at a time with a 60-tick pause after each wounded one.
    seq: ?Seq = null,
    /// Enemy currently walking in (one at a time, 0x48f240).
    appear_walker: ?u16 = null,
    /// Waiting for the pre-battle dialog started after the appearance.
    wait_dialog: bool = false,
    /// Enemy turn or their appearance in progress (`[0x6c4e88]`, 0x498460 … 0x49859d).
    enemy_period: bool = false,
    /// Enemy turn camera on a strike (0x454cf1 → 0x45c270): midway between the
    /// attacker and the target tile (0x6c4eb0/eb4, 0x499b12) until the next one acts.
    cam_pair: ?struct { who: u16, tile: Tile } = null,
    /// Defeat only when everyone died (for the playthrough); in the exe any hero.
    lenient_loss: bool = false,
    /// Time bombs: large ones (PutLargeTimeBomb) and hero bombs.
    bombs: std.ArrayList(Bomb) = .empty,
    /// Tile of an exploded bomb: the camera watches it for 90 ticks after the blast
    /// (0x4987fa: [0x6c12c8] = 2 → 0x454cb0 → 0x45c160).
    bomb_cam: ?Tile = null,
    /// A hero bomb blast strike is running (weapon +0x1ab4 = 1): class 9 strikes instead of placing.
    bomb_blast: bool = false,
    /// A barrel blast strikes on behalf of whoever blew it up (+0x1ab0 → +0xf0,
    /// 0x4ce217): reaction, last attacker and exp are theirs; tiles and roll are the barrel's.
    blast_credit: ?u16 = null,
    /// Battle with the girl (`levelMode` 8, 0x47c464, 0x4b4afc): the first hero strike
    /// on a non-hero starts 100 ticks until `03ch_lilith1` turns into Lilith, and 80
    /// later the dialog `03__museum_child2.dlg`. −10 = not started.
    lilith_ticks: i32 = -10,
    lilith_dialog_ticks: i32 = -10,
    /// Invisible `04mf_invisible1` (04__city_mfd) left the grid at the end of the enemy
    /// turn (0x498614, flag 0x6c4edc): removed at the next enemy turn start.
    invisible_leaving: bool = false,
    /// Fighter wounded by the last strike (for the repeated reaction, code 7).
    last_hit: ?u16 = null,
    /// Hero facing selection mode (0x64feb8, vtable 0x508ca4): facingArrow arrows on
    /// free side neighbours.
    facing_mode: bool = false,
    /// Decoys (class 18 weapon, 0x4b9750 → 0x4bdb40): "fighter" `Distractor<N>`.
    decoys: std.ArrayList(Bomb) = .empty,

    /// Whether the enemy battle music track plays (0x40edc0): enemy turn and their
    /// appearance.
    pub fn enemyMusic(self: *const Battle) bool {
        return self.phase == .enemy or (self.phase == .appear and (self.staging or self.started));
    }

    pub fn grid(self: *Battle) grid_mod.Grid {
        return .{ .width = self.width, .height = self.height, .blocked = self.blocked, .occupant = self.occupant };
    }

    pub fn deinit(self: *Battle) void {
        self.fighters.deinit(self.gpa);
        self.bombs.deinit(self.gpa);
        self.decoys.deinit(self.gpa);
        self.popups.deinit(self.gpa);
        self.blasts.deinit(self.gpa);
        self.gpa.free(self.blocked);
        self.gpa.free(self.occupant);
        self.gpa.free(self.reach_left);
        if (self.ai_reach.len > 0) self.gpa.free(self.ai_reach);
        self.ai_scratch.deinit(self.gpa);
        self.gpa.free(self.fire);
        self.gpa.free(self.gas);
    }

    /// Tile of an exploded bomb: the camera stays on it for 90 ticks after the blast
    /// (0x454cb0: [0x6c12c8] = 2 → 0x45c160).
    pub fn cameraTile(self: *Battle) ?Tile {
        return if (self.seq != null) self.bomb_cam else null;
    }

    /// Whom the camera follows in the turn sequence (0x454cb0 → 0x45bfc0, actor
    /// `[0x6c4e8c]`): the enemy walking in, the enemy acting.
    pub fn cameraActor(self: *Battle) ?*Object {
        if (self.phase == .appear) {
            if (self.appear_walker) |k| return self.fighters.items[k].obj;
            return null;
        }
        if (self.phase == .enemy and self.enemy_cursor < self.fighters.items.len and self.seq == null) {
            if (self.ai_show) |sh| return self.fighters.items[sh.who].obj;
        }
        return null;
    }

    /// Attacking enemy and its target tile: the camera is midway (0x45c270).
    pub fn cameraPair(self: *Battle) ?struct { obj: *Object, tile: Tile } {
        if (self.phase != .enemy) return null;
        const cp = self.cam_pair orelse return null;
        return .{ .obj = self.fighters.items[cp.who].obj, .tile = cp.tile };
    }

    pub fn fighterOf(self: *Battle, o: *Object) ?u16 {
        for (self.fighters.items, 0..) |f, i| if (f.obj == o) return @intCast(i);
        return null;
    }

    /// A live fighter is frozen (+0x248e0 ≠ 0): its animation stands still (0x48e940).
    pub fn isFrozen(self: *Battle, o: *Object) bool {
        const i = self.fighterOf(o) orelse return false;
        const f = self.fighters.items[i];
        return f.frozen > 0 and f.alive();
    }

    /// Live Invisible `04mf_invisible1` (looked up by name, 0x42b140 in 0x4985fb/0x49839f).
    pub fn invisibleMfd(self: *Battle) ?u16 {
        for (self.fighters.items, 0..) |f, i| {
            if (f.alive() and std.ascii.eqlIgnoreCase(f.obj.name, "04mf_invisible1")) return @intCast(i);
        }
        return null;
    }

    /// The hero already acted this round (+0x24610): the inventory can't take items.
    pub fn hasActed(self: *Battle, o: *Object) bool {
        const i = self.fighterOf(o) orelse return false;
        return self.fighters.items[i].acted;
    }

    /// Fighters at most 1 tile apart (0x481ec0): an item can be handed over.
    pub fn adjacent(self: *Battle, a: *Object, b: *Object) bool {
        const ia = self.fighterOf(a) orelse return false;
        const ib = self.fighterOf(b) orelse return false;
        const ta = self.fighters.items[ia].tile;
        const tb = self.fighters.items[ib].tile;
        const dx: f32 = @floatFromInt(ta[0] - tb[0]);
        const dy: f32 = @floatFromInt(ta[1] - tb[1]);
        return @sqrt(dx * dx + dy * dy) <= 1.0;
    }

    pub fn current(self: *Battle) ?*Fighter {
        const i = self.selected orelse return null;
        return &self.fighters.items[i];
    }

    pub fn idle(self: *Battle) bool {
        return self.pending == .none;
    }
};

// ---------------------------------------------------------------- helpers

pub fn note(self: *Battle, comptime fmt: []const u8, args: anytype) void {
    const out = self.log orelse return;
    out.print(fmt ++ "\n", args) catch {};
}

pub fn popup(self: *Battle, f: Fighter, text: []const u8, style: Popup.Style) !void {
    try popup_mod.queuePopup(&self.popups, self.gpa, fields.pos(f.obj), text, style);
}

//! Battle AI, recovered from gorky17.exe (AI turn 0x498d30).
//!
//! 1. Targets are live fighters of the other side; with `aiMode` 1 only the
//!    AITargetLock target; `aiMode` 2 never walks.
//! 2. Threat map (0x49af80): for each opponent, the tiles it can reach with a full
//!    walk budget and its weapons' hit tiles from there; a tile keeps the maximum
//!    `pct × max_damage / 100` per opponent, and the tile threat is the sum over
//!    opponents (0x494f90).
//! 3. Every path (0x498ed0) within `walk_range`: straight step 1, diagonal 1.5.
//!    Each path tile is scored (0x499170); the best over all paths is kept, the
//!    shorter path on a tie.
//! 4. Execution (0x499770): walk to the strike tile, strike, walk the rest.
//!
//! Tile score (`aic*` are fighter variables):
//! - strike: for each weapon and aim tile, the sum over fighters on hit tiles:
//!   opponent `(max_damage + 5) × pct / 100` (AITargetLock target ×100), ally
//!   `−10 ×` the same; × `aicAttack`. The best strike carries down the path;
//! - `− aicDefense × tile threat`;
//! - without a strike: `− aicPlayerDist × distance to the nearest opponent`
//!   (with `aiMode` 3, `− aicGuardDist ×` distance to the guard point);
//!   with a strike: `+ aicPlayerDist ×` distance (step away after striking).
//!
//! Special fighters (`classType` 1, 6–18; method +0xe0) score their own way
//! (`Eval`): based on "scoring A" (0x4dcb40), no decoy, no +5 to damage and no ×2
//! for `classType` 5; on top, rules for Garcia, Smoke Rider, Grandma and children,
//! Incubus, Cripple, Guard, Schizo and Messiah.

const std = @import("std");
const num = @import("../num.zig");
const fields = @import("../fields.zig");
const weapons = @import("weapons.zig");
const battle_mod = @import("../battle.zig").battle;
const Class = @import("../battle.zig").fighter.Class;
const immunity = @import("../battle.zig").immunity;
const Battle = battle_mod.Battle;
const Fighter = @import("../battle.zig").fighter.Fighter;
const World = @import("../state.zig").world.World;
const object = @import("../script.zig").object;
const value = @import("../script.zig").value;
const Object = object.Object;
const rules = @import("../battle.zig").rules;
const WeaponClass = @import("../battle.zig").weapon_class.WeaponClass;
const grid = @import("../battle.zig").grid;
const patterns = @import("../battle.zig").patterns;
const generic = @import("../battle.zig").generic;
const strike = @import("strike.zig");

const Tile = grid.Tile;
/// Best strike found higher up the path (passed down by value).
const Carry = struct {
    score: i32 = 0,
    depth: usize = 0,
    weapon: ?*Object = null,
    aim: grid.Target = undefined,
};

/// Tile scoring kind by `classType` (table 0x4bcbb0).
const Eval = enum { generic, a, garcia, smokerider, grandma, grandma_child, incubus, cripple, guard, schizo, messiah };

pub fn evalOf(f: Fighter) Eval {
    if (f.side != .enemy) return .generic;
    return switch (Class.of(f.obj)) {
        .garcia => .garcia,
        .smokerider => .smokerider,
        .grandma => .grandma,
        .grandma_child => .grandma_child,
        .stinger, .fatman, .puppet, .judge, .judge_child => .a,
        .incubus => .incubus,
        .cripple => .cripple,
        .guard => .guard,
        .schizo => .schizo,
        .messiah => .messiah,
        // Port-only generic fighter: strategy from the `ai` field (battle/generic.zig).
        .generic => switch (generic.aiOf(f.obj)) {
            .standard, .stationary => .generic,
            .focused => .a,
            .sleep_hunter => .guard,
        },
        else => .generic,
    };
}

const Params = struct {
    attack: i32,
    defense: i32,
    player_dist: i32,
    guard_dist: i32,
    mode: i32,
};

/// Weapon for the search (script fields read once).
const WInfo = struct {
    pat: ?*const patterns.Weapon,
    md: i32,
    class: i32,
    secondary: bool,
    /// Damage kind code (immunity.damageCode), for the heroes' autoplay.
    dcode: ?immunity.Resist,
};

/// Fighter for scoring hit tiles.
const FInfo = struct {
    class: Class,
    hp: i32,
    name_id: i32,
    /// Effect of its weapon in hand (rules.weaponEffect).
    weff: ?rules.Effect,
};

fn weaponInfo(wpn: *Object) WInfo {
    const class = wpn.getInt("classType");
    return .{
        .pat = patterns.find(class),
        .md = wpn.getInt("max_damage"),
        .class = class,
        .secondary = wpn.getInt("secondaryWeapon") != 0,
        .dcode = immunity.damageCode(.from(wpn.getInt("type"))),
    };
}

const Search = struct {
    b: *Battle,
    w: *World,
    who: u16,
    me: Fighter,
    p: Params,
    foes: [battle_mod.max_fighters]u16 = undefined,
    n_foes: usize = 0,
    weapons: [16]*Object = undefined,
    n_weapons: usize = 0,
    /// Weapon and fighter fields read once per plan: the path search changes neither
    /// fighters nor items (only the fighter's own tiles on the grid).
    winfo: [16]WInfo = undefined,
    finfo: [battle_mod.max_fighters]FInfo = undefined,
    danger: []u16,
    path: [battle_mod.max_path]Tile = undefined,
    best: battle_mod.Plan = .{},
    can_attack: bool,
    can_move: bool,
    locked: ?u16 = null,
    guard: ?Tile = null,
    targets_buf: [512]grid.Target = undefined,
    /// Path length (0x49a630) from a tile to opponent `k` and to the guard point,
    /// cached per tile (NaN = not computed yet): the fighter stands on the scored tile,
    /// so the path from it depends only on the tile.
    foe_dist: [][]f32,
    guard_dist: []f32,
    foe_tile: [battle_mod.max_fighters]Tile = undefined,
    decoy_tile: [4]Tile = undefined,
    /// Wave 0x49a630 buffers: visited tiles and the queue.
    visited: []u8,
    queue: []grid.QEntry,
    /// Decoys on the field and distances to them (0x499620): an attracted enemy
    /// doesn't strike and walks to the nearest, `−2000 × aicPlayerDist × path`.
    decoy_dist: [4][]f32 = undefined,
    n_decoys: usize = 0,
    eval: Eval = .generic,
    /// Grandma (for the children): distance field to her.
    grandma_dist: ?[]f32 = null,
};

/// Turn plan of fighter `who`.
pub fn plan(b: *Battle, w: *World, who: u16) !battle_mod.Plan {
    const me = b.fighters.items[who];
    const n = b.width * b.height;
    try b.ai_scratch.ensure(b.gpa, n);
    const danger = b.ai_scratch.danger;
    const dist_all = b.ai_scratch.dist;
    @memset(dist_all, std.math.nan(f32));
    var dist_rows: [battle_mod.max_fighters][]f32 = undefined;
    for (&dist_rows, 0..) |*r, i| r.* = dist_all[i * n ..][0..n];
    const visited = b.ai_scratch.visited;
    const queue = b.ai_scratch.queue;
    var s: Search = .{
        .b = b,
        .w = w,
        .who = who,
        .me = me,
        .p = params(me),
        .danger = danger,
        .foe_dist = &dist_rows,
        .guard_dist = dist_all[battle_mod.max_fighters * n ..][0..n],
        .visited = visited,
        .queue = queue,
        .can_attack = me.obj.getInt("attackLock") == 0 and !me.disabled(),
        .can_move = !fields.moveLock(me.obj) and !me.disabled() and
            !(generic.is(me.obj) and generic.aiOf(me.obj) == .stationary),
        .eval = evalOf(me),
    };
    const nat = World.nativeOf(me.obj);
    if (s.p.mode == 3) s.guard = nat.fight.guard_point;
    for (b.fighters.items, 0..) |f, i| {
        if (f.side == me.side or f.side == .neutral or !f.alive() or f.appear_to != null) continue;
        if (s.p.mode == 1 and nat.fight.target_lock.len > 0) {
            if (!std.ascii.eqlIgnoreCase(f.obj.name, nat.fight.target_lock)) continue;
            s.locked = @intCast(i);
        }
        s.foes[s.n_foes] = @intCast(i);
        s.n_foes += 1;
    }
    s.n_weapons = weapons.weaponsOf(w, me, &s.weapons).len;
    filterWeapons(&s);
    for (s.weapons[0..s.n_weapons], 0..) |wpn, i| s.winfo[i] = weaponInfo(wpn);
    for (b.fighters.items, 0..) |f, i| s.finfo[i] = .{
        .class = Class.of(f.obj),
        .hp = f.hp(),
        .name_id = fields.nameId(f.obj),
        .weff = if (f.weapon) |fw| rules.weaponEffect(fw.getInt("classType")) else null,
    };
    try buildDanger(&s);

    // Path search; the fighter is "moved" along the path tiles.
    const g = b.grid();
    g.remove(me.tile, me.size);
    for (s.foes[0..s.n_foes], 0..) |fi, k| s.foe_tile[k] = b.fighters.items[fi].tile;
    // Grandma's child stays close to her (0x4e0602).
    if (s.eval == .grandma_child) for (b.fighters.items) |f| {
        if (!f.alive() or !std.ascii.eqlIgnoreCase(f.obj.name, "grandma")) continue;
        const d = dist_all[(battle_mod.max_fighters + 1 + 3) * n ..][0..n];
        distanceField(&s, d, f.tile, f.size);
        s.grandma_dist = d;
        break;
    };
    // Decoys affect enemies (heroes have no AI in the original).
    // Fighters resistant to decoys (code 3, 0x498d4d) are not attracted.
    if (s.eval == .generic and me.side == .enemy and me.attracted and !w.immunity.immune(fields.nameId(me.obj), .attract)) {
        for (b.decoys.items) |d| {
            if (s.n_decoys == s.decoy_dist.len) break;
            s.decoy_dist[s.n_decoys] = dist_all[(battle_mod.max_fighters + 1 + s.n_decoys) * n ..][0..n];
            s.decoy_tile[s.n_decoys] = d.tile;
            s.n_decoys += 1;
        }
        if (s.n_decoys > 0) s.can_attack = false;
    }
    defer {
        g.place(me.tile, me.size, who);
    }
    search(&s, 0, me.tile, me.budget(), .{});
    s.best.foe_dist = nearestFoe(&s, me.tile);
    return s.best;
}

/// Weapon by scoring kind: Garcia's long one (`secondaryWeapon`) only below half
/// health (0x4dfe8d); Schizo only the first; Messiah without the hand blocked by
/// a box (1019: obstacle at (10,19), 1020: at (10,17)).
fn filterWeapons(s: *Search) void {
    var n: usize = 0;
    for (s.weapons[0..s.n_weapons]) |wpn| {
        const keep = switch (s.eval) {
            .garcia => (wpn.getInt("secondaryWeapon") != 0) == (s.me.hp() * 2 < fields.maxHp(s.me.obj)),
            .schizo => n == 0,
            .messiah => !(WeaponClass.of(wpn) == .messiah_left and obstacleAt(s.b, .{ 10, 19 })) and
                !(WeaponClass.of(wpn) == .messiah_right and obstacleAt(s.b, .{ 10, 17 })),
            else => true,
        };
        if (!keep) continue;
        s.weapons[n] = wpn;
        n += 1;
    }
    s.n_weapons = n;
}

/// An `.obs` obstacle stands on the tile (type 4, not an item box).
pub fn obstacleAt(b: *Battle, t: Tile) bool {
    const o = b.grid().at(t);
    if (o == grid.Grid.none) return false;
    const f = b.fighters.items[o];
    return f.side == .neutral and f.obj.getVar("cnt_itm") == null;
}

fn params(f: Fighter) Params {
    var p: Params = .{
        .attack = f.obj.getInt("aicAttack"),
        .defense = f.obj.getInt("aicDefense"),
        .player_dist = f.obj.getInt("aicPlayerDist"),
        .guard_dist = f.obj.getInt("aicGuardDist"),
        .mode = f.obj.getInt("aiMode"),
    };
    // Heroes without their own parameters (autobattle) act as an ordinary monster.
    if (p.attack == 0 and p.defense == 0 and p.player_dist == 0) p = .{ .attack = 10, .defense = 2, .player_dist = 100, .guard_dist = 100, .mode = 0 };
    return p;
}

/// Threat map from opponents (0x49af80, 0x4ce930).
fn buildDanger(s: *Search) !void {
    const b = s.b;
    @memset(s.danger, 0);
    const slot = b.ai_scratch.slot;
    const left = b.ai_scratch.left;
    const g = b.grid();
    for (s.foes[0..s.n_foes]) |fi| {
        const f = b.fighters.items[fi];
        @memset(slot, 0);
        var list: [16]*Object = undefined;
        const ws = weapons.threatWeaponsOf(s.w, f, &list);
        grid.reach(g, left, f.tile, f.size, fi, @floatFromInt(fields.walkRange(f.obj)));
        var wi: [16]WInfo = undefined;
        for (ws, 0..) |wpn, i| wi[i] = weaponInfo(wpn);
        for (0..b.height) |y| for (0..b.width) |x| {
            if (left[y * b.width + x] < 0) continue;
            const from: Tile = .{ @intCast(x), @intCast(y) };
            for (wi[0..ws.len]) |info| {
                const pat = info.pat orelse continue;
                const md = info.md;
                for (grid.targets(g, pat, from, fi, false, false, &s.targets_buf)) |aim| {
                    var eff: [128]Tile = undefined;
                    // 0x494f20: a tile is a byte; larger values store the low byte
                    // (`mov byte ptr [eax], cl`), no saturation.
                    const v: i32 = @divTrunc(@as(i32, aim.pct) * md, 100);
                    for (grid.effectTiles(g, pat, aim, &eff)) |t| {
                        const k = grid.tileIndex(b.width, t);
                        if (v > slot[k]) slot[k] = @truncate(@as(u32, @bitCast(v)));
                    }
                }
            }
        };
        for (s.danger, slot) |*d, v| d.* += v;
    }
}

const neighbours = [8]struct { d: Tile, cost: f32 }{
    .{ .d = .{ -1, -1 }, .cost = grid.diagonal_cost_ai }, .{ .d = .{ 0, -1 }, .cost = 1 },
    .{ .d = .{ 1, -1 }, .cost = grid.diagonal_cost_ai },  .{ .d = .{ 1, 0 }, .cost = 1 },
    .{ .d = .{ 1, 1 }, .cost = grid.diagonal_cost_ai },   .{ .d = .{ 0, 1 }, .cost = 1 },
    .{ .d = .{ -1, 1 }, .cost = grid.diagonal_cost_ai },  .{ .d = .{ -1, 0 }, .cost = 1 },
};

/// 0x498ed0: tile `t` at depth `depth`, walk budget left `budget`.
fn search(s: *Search, depth: usize, t: Tile, budget: f32, carry_in: Carry) void {
    if (budget < 0 or depth >= battle_mod.max_path or !s.b.grid().inside(t)) return;
    s.path[depth] = t;
    const g = s.b.grid();
    g.place(t, s.me.size, s.who);
    var carry = carry_in;
    evaluate(s, depth, t, &carry);
    g.remove(t, s.me.size);
    if (!s.can_move) return;
    for (neighbours) |n| {
        const nt: Tile = .{ t[0] + n.d[0], t[1] + n.d[1] };
        if (!g.fits(nt, s.me.size, s.who)) continue;
        search(s, depth + 1, nt, budget - n.cost, carry);
    }
}

/// 0x499170: tile score.
fn evaluate(s: *Search, depth: usize, t: Tile, carry: *Carry) void {
    const b = s.b;
    const g = b.grid();
    // Smoke Rider tries its weapons even without "can strike" (0x4de890).
    const try_attack = s.can_attack or s.eval == .smokerider;
    if (try_attack) for (s.weapons[0..s.n_weapons], s.winfo[0..s.n_weapons]) |wpn, *wi| {
        const pat = wi.pat orelse continue;
        const md = wi.md;
        for (grid.targets(g, pat, t, s.who, true, false, &s.targets_buf)) |aim| {
            // A sleeping Smoke Rider sees only a ±π/4 cone from its facing.
            if (s.eval == .smokerider and !s.can_attack and !inCone(s, t, aim.tile)) continue;
            var eff: [128]Tile = undefined;
            var sum: i32 = 0;
            if (s.eval == .smokerider and !s.can_move) sum = dist2(t, aim.tile);
            for (grid.effectTiles(g, pat, aim, &eff)) |et| {
                const o = g.at(et);
                if (s.eval == .incubus) {
                    sum +%= incubusTile(s, o, et, t, aim, md);
                    continue;
                }
                if (o == grid.Grid.none) continue;
                // Heroes' autoplay (gorky-tool only; in the game the player controls heroes):
                // the Messiah is hurt only from tile (10,18) (0x4cee33), so from other tiles he
                // isn't a target, or the heroes would shoot past him for the whole battle.
                if (s.me.side == .hero and s.finfo[o].class == .messiah and !strike.messiahOpen(t)) continue;
                // A 2×2 fighter covers several tiles; the original counts each.
                sum +%= occupantScore(s, o, wi, md, aim.pct);
            }
            const score = s.p.attack *% sum;
            if (score > carry.score) carry.* = .{ .score = score, .depth = depth, .weapon = wpn, .aim = aim };
        }
    };
    // The Guard ignores threat (no call to 0x494f90).
    const danger: i32 = if (s.eval == .guard) 0 else s.danger[grid.tileIndex(b.width, t)];
    var score = carry.score -% s.p.defense *% danger;
    if (s.grandma_dist) |gd| {
        const d = at(s, gd, t);
        if (d > 3) score -%= s.p.guard_dist *% value.floatToInt(d);
    }
    if (s.n_decoys > 0) score -%= 2000 *% s.p.player_dist *% value.floatToInt(nearestDecoy(s, t));
    if (carry.weapon == null) {
        if (s.p.mode == 3 and s.guard != null) {
            const d = pathLen(s, s.guard_dist, s.guard.?, t);
            score -%= if (d >= 0) s.p.guard_dist *% value.floatToInt(d) else 100 *% s.p.guard_dist;
        } else {
            score -%= s.p.player_dist *% value.floatToInt(nearestFoe(s, t));
        }
    } else if (s.me.side == .enemy and s.eval != .guard) {
        // After the strike, step away (the Guard stays).
        score +%= s.p.player_dist *% value.floatToInt(nearestFoe(s, t));
    }
    // Heroes in autoplay don't step away after striking (enemies do, per the exe).
    if (score > s.best.score or (score == s.best.score and depth + 1 < s.best.len)) {
        s.best = .{ .score = score, .len = depth + 1, .weapon = carry.weapon, .aim = carry.aim };
        s.best.attack_at = if (carry.weapon != null) carry.depth else null;
        @memcpy(s.best.path[0 .. depth + 1], s.path[0 .. depth + 1]);
    }
}

/// Contribution of fighter `o` on a hit tile by scoring kind.
fn occupantScore(s: *Search, o: u16, wi: *const WInfo, md: i32, pct: u8) i32 {
    const f = s.b.fighters.items[o];
    const foe = f.side != s.me.side and f.side != .neutral;
    const p: i32 = pct;
    switch (s.eval) {
        .generic => {
            const base = (md +% 5) *% p;
            if (s.locked != null and o == s.locked.?) return @divTrunc(base *% 100, 100);
            if (foe) {
                var k: i32 = if (s.finfo[o].class == .monitor) 2 else 1;
                if (s.me.side == .hero) k *= heroPriority(s.w.immunity, &s.finfo[o], wi, md);
                return @divTrunc(base *% k, 100);
            }
            return @divTrunc((0 -% base) *% 10, 100);
        },
        // Scoring A and its variants: damage × pct / 100, AITargetLock target ×100 (not
        // for the Cripple), others −10×.
        .a, .garcia, .smokerider, .grandma_child, .cripple => {
            const base = md *% p;
            if (s.eval != .cripple and s.locked != null and o == s.locked.?) return base;
            if (foe) return @divTrunc(base, 100);
            return @divTrunc((0 -% base) *% 10, 100);
        },
        // Grandma strikes only her target (her child's killer).
        .grandma => return if (s.me.grandma_target != null and o == s.me.grandma_target.?) md *% p else 0,
        // Guard (0x4e2260): melee (`secondaryWeapon`) +100 per sleeping hero, the
        // sleep shot +1 per awake one (0x4e2374…0x4e239b).
        .guard => {
            if (f.side != .hero) return 0;
            const asleep = f.asleep > 0;
            return if (wi.secondary) (if (asleep) 100 else 0) else (if (asleep) 0 else 1);
        },
        .schizo => return if (f.side == .hero) 10 else -100,
        .messiah => return if (foe) @divTrunc(md *% p, 100) else 0,
        .incubus => return 0,
    }
}

/// Incubus (0x4e2b50) scores a hit tile: occupied −10×; empty, on the first
/// activation `200 − damage·pct·d/100` (d = nearest hero, dx² + dy²), on the second
/// `(path tile − aim)² · damage·pct/100`.
fn incubusTile(s: *Search, o: u16, et: Tile, here: Tile, aim: grid.Target, md: i32) i32 {
    const p: i32 = aim.pct;
    if (o != grid.Grid.none) return @divTrunc(-10 *% md *% p, 100);
    if (!s.me.second) {
        var dmin: i32 = std.math.maxInt(i32);
        for (s.b.fighters.items) |f| if (f.side == .hero and f.alive()) {
            dmin = @min(dmin, dist2(et, f.tile));
        };
        if (dmin <= 0 or dmin == std.math.maxInt(i32)) dmin = 100;
        return 200 -% @divTrunc(md *% p *% dmin, 100);
    }
    return @divTrunc(dist2(here, aim.tile) *% md *% p, 100);
}

fn dist2(a: Tile, b: Tile) i32 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    return dx * dx + dy * dy;
}

/// Aim within a ±π/4 cone of the fighter's facing (0x50a210).
fn inCone(s: *Search, from: Tile, to: Tile) bool {
    const want = fields.facing(@floatFromInt(to[0] - from[0]), @floatFromInt(to[1] - from[1]));
    const cur = s.me.obj.getVar("angle").?.value.toFloat();
    const d = std.math.atan2(@sin(want - cur), @cos(want - cur));
    return @abs(d) <= std.math.pi * 0.25;
}

/// Heroes' autoplay only (in the original the player controls them): like a
/// player, hit those who freeze and put to sleep first (otherwise they lock a hero
/// out all battle), and finish off the wounded.
fn heroPriority(known: *immunity.Known, f: *const FInfo, wi: *const WInfo, max_damage: i32) i32 {
    // Target immune to the weapon's damage kind: pointless; like a player we know
    // only what was discovered.
    if (wi.dcode) |code| {
        if (known.isKnown(f.name_id, code)) return 0;
    }
    var k: i32 = 1;
    if (f.weff) |e| {
        if (e == .freeze or e == .sleep) k *%= 3;
    }
    if (f.hp <= max_damage) k *%= 2;
    return k;
}

/// Path to the nearest decoy (unreachable 10000, the initial 0x40c38800).
fn nearestDecoy(s: *Search, t: Tile) f64 {
    var best: f64 = 10000;
    for (s.decoy_dist[0..s.n_decoys], s.decoy_tile[0..s.n_decoys]) |d, dt| {
        var v = pathLen(s, d, dt, t);
        if (v < 0) v = 10000;
        best = @min(best, v);
    }
    return best;
}

/// Distance to the nearest opponent (by path; unreachable 100, none 10000).
fn nearestFoe(s: *Search, t: Tile) f64 {
    var best: f64 = 10000;
    for (0..s.n_foes) |k| {
        var d = pathLen(s, s.foe_dist[k], s.foe_tile[k], t);
        if (d < 0) d = 100;
        best = @min(best, d);
    }
    return best;
}

/// Path length from tile `t` to target `to` (0x49a630), cached per tile; −1 = unreachable.
fn pathLen(s: *Search, cache: []f32, to: Tile, t: Tile) f64 {
    // A tile outside the grid (a party hero the battle script didn't place stands at
    // its level coordinates) is unreachable; otherwise we'd index past the cache.
    if (t[0] < 0 or t[1] < 0 or t[0] >= s.b.width or t[1] >= s.b.height) return -1;
    const k = grid.tileIndex(s.b.width, t);
    if (std.math.isNan(cache[k])) cache[k] = wave(s, t, to);
    return cache[k];
}

/// 0x49a630: wave from fighter tile `from` (the fighter stands on it) to a tile
/// next to the target: the target's top-left corner in [x − 1, x + s + 1] on both
/// axes, s = ⌊√charSize − 1⌋ (0x49a64f…0x49a71b). The queue is in insertion
/// order: straight neighbours (↑ → ↓ ←, +1), then diagonal (↖ ↗ ↘ ↙, +1.5;
/// 0x49a730…0x49a897); a tile is marked visited after it's processed (0x49a89e)
/// and visited ones are skipped. The answer is the cost of the first matching tile
/// (0x49a8d5); an empty queue gives −1 (0x49a8c5).
fn wave(s: *Search, from: Tile, to: Tile) f32 {
    return grid.waveLen(s.b.grid(), s.visited, s.queue, s.me.size, from, to);
}

fn at(s: *Search, field: []const f32, t: Tile) f64 {
    const v = field[grid.tileIndex(s.b.width, t)];
    return if (v == std.math.inf(f32)) -1 else v;
}

/// 0x49a630 for all tiles at once: path length of the fighter to a tile next to
/// target `to` (of size `to_size`) (step 1, diagonal 1.5; start value
/// √charSize − 1). The wave runs from the target; infinity = unreachable.
fn distanceField(s: *Search, d: []f32, to: Tile, to_size: u32) void {
    const b = s.b;
    const g = b.grid();
    const size = s.me.size;
    @memset(d, std.math.inf(f32));
    const start: f32 = num.toF32(size) - 1;
    const si: i32 = @intCast(size);
    const ti: i32 = @intCast(to_size);
    // Tiles next to the target (rectangles touch, diagonals included).
    for (0..b.height) |y| for (0..b.width) |x| {
        const t: Tile = .{ @intCast(x), @intCast(y) };
        const near = to[0] <= t[0] + si and to[0] + ti >= t[0] and to[1] <= t[1] + si and to[1] + ti >= t[1];
        if (near and g.fits(t, size, s.who)) d[y * b.width + x] = start;
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (0..b.height) |y| for (0..b.width) |x| {
            const here = d[y * b.width + x];
            if (here == std.math.inf(f32)) continue;
            const t: Tile = .{ @intCast(x), @intCast(y) };
            for (neighbours) |n| {
                const nt: Tile = .{ t[0] + n.d[0], t[1] + n.d[1] };
                if (!g.inside(nt) or !g.fits(nt, size, s.who)) continue;
                const k = grid.tileIndex(b.width, nt);
                if (here + n.cost < d[k] - 1e-4) {
                    d[k] = here + n.cost;
                    changed = true;
                }
            }
        };
    }
}

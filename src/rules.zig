//! Rules: the one seam over the logic the exe keeps in its own tables by classic_id,
//! classType and action (attack branches, resistances, icons, weapon classes,
//! medicine, actions, special IDs). Every lookup goes through `active`.
//! - Classic (no manifest): `builtin`, the exe's tables as the port has them; the
//!   port behaves bit for bit as before.
//! - OpenGorky: the composition layer reads the project's `rules\*.ss` over the
//!   built-ins (loaders/rules_text.zig: their text, loaders/codec.zig: a row's) and
//!   hands the tables in force to `use`. The core keeps only the tables and lookups.
//! Identity (OpenGorky): a fighter, weapon, hero or item key may name the entity's class
//! (`fighter = "ft_wasp"`, `weapon = "cw_laser"`: `classOf`) instead of its classic_id; lookups
//! take a `Who` and prefer the class row, then the classic_id row, then the built-in. Classic
//! has no class: the exe's lookups by classic_id only.
//! Built-in rows live next to the code that uses them; this file only gathers them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const script = @import("script.zig");
const Object = script.object.Object;

/// The row types (their text forms: loaders/codec.zig).
pub const rows = @import("rules/rows.zig");
/// The exe's tuning globals (adjust.kdt), filled by compose.loadAdjust (OpenGorky: `use`).
pub const adjust = @import("rules/adjust.zig");
pub const adjust_owners = @import("rules/adjust_owners.zig");
const consts = @import("rules/consts.zig");

pub const Const = rows.Const;
pub const Effect = rows.Effect;
pub const MedicineKind = rows.MedicineKind;
pub const resistIndex = rows.resistIndex;
pub const MonsterAttack = rows.MonsterAttack;
pub const HeroAttack = rows.HeroAttack;
pub const WdelayHero = rows.WdelayHero;
pub const Resist = rows.Resist;
pub const KillIcon = rows.KillIcon;
pub const Glow = rows.Glow;
pub const SkillIcon = rows.SkillIcon;
pub const WeaponSound = rows.WeaponSound;
pub const WeaponClass = rows.WeaponClass;
pub const Pattern = rows.Pattern;
pub const Medicine = rows.Medicine;
pub const HealBonus = rows.HealBonus;
pub const Action = rows.Action;
pub const ExpLevel = rows.ExpLevel;
pub const HiddenWeapons = rows.HiddenWeapons;
pub const IdleChatter = rows.IdleChatter;
pub const WeaponFlags = rows.WeaponFlags;
pub const AiProfile = rows.AiProfile;
pub const AiEval = rows.AiEval;
pub const FxAs = rows.FxAs;
pub const Value = rows.Value;
pub const Campaign = rows.Campaign;
pub const Character = rows.Character;
pub const Setting = rows.Setting;

const d_attacks = @import("rules/attacks.zig");
const d_resist = @import("rules/resist.zig");
const d_ui = @import("rules/ui.zig");
const d_fx = @import("rules/fx.zig");
const d_weapon_classes = @import("rules/weapon_classes.zig");
const d_fighter_classes = @import("rules/fighter_classes.zig");
/// The exe's fighter classes by name (a Classic piece; the converter writes them).
pub const fighter_classes = d_fighter_classes;
const d_patterns = @import("rules/patterns.zig");
const d_items = @import("rules/items.zig");
const d_actions = @import("rules/actions.zig");
const d_party = @import("rules/party.zig");
const d_ai = @import("rules/ai.zig");
const d_campaign = @import("rules/campaign.zig");

// ---------------------------------------------------------------- the set

/// Every table, in its file's order.
pub const Set = struct {
    monster_attacks: []const MonsterAttack,
    hero_attacks: []const HeroAttack,
    wdelay_heroes: []const WdelayHero,
    resist: []const Resist,
    kill_icons: []const KillIcon,
    glows: []const Glow,
    skill_icons: []const SkillIcon,
    weapon_sounds: []const WeaponSound,
    fx_as: []const rows.FxAs,
    weapon_classes: []const WeaponClass,
    weapon_flags: []const WeaponFlags,
    patterns: []const Pattern,
    medicine: []const Medicine,
    heal_bonus: []const HealBonus,
    actions: []const Action,
    exp_levels: []const ExpLevel,
    idle_chatter: []const IdleChatter,
    hidden_weapons: []const HiddenWeapons,
    values: []const Value,
    ai_profiles: []const AiProfile,
    campaign: []const Campaign,
    /// OpenGorky's character roles (none built in: Classic's are its files').
    characters: []const Character,
    /// OpenGorky's tuning values (Classic: adjust.kdt); none built in (the callers' defaults).
    adjust: []const Setting,
};

pub const builtin: Set = .{
    .monster_attacks = &d_attacks.monster_attacks,
    .hero_attacks = &d_attacks.hero_attacks,
    .wdelay_heroes = &d_attacks.wdelay_heroes,
    .resist = &d_resist.table,
    .kill_icons = &d_ui.monster_icons,
    .glows = &d_ui.glows,
    .skill_icons = &d_ui.skill_icons,
    .weapon_sounds = &d_fx.weapon_sounds,
    .fx_as = &.{},
    .weapon_classes = &d_weapon_classes.weapon_classes,
    .weapon_flags = &d_weapon_classes.weapon_flags,
    .patterns = &d_patterns.all,
    .medicine = &d_items.table,
    .heal_bonus = &d_items.heal_bonus,
    .actions = &d_actions.actions,
    .exp_levels = &d_party.exp_levels,
    .idle_chatter = &d_party.idle_chatter,
    .hidden_weapons = &d_party.hidden_weapons,
    .values = &consts.builtin,
    .ai_profiles = &d_ai.profiles,
    .campaign = &d_campaign.builtin,
    .characters = &.{},
    .adjust = &.{},
};

/// The exe's weapon classes' names (WeaponClass and Pattern rows are keyed by them).
pub const weapon_class_names = d_weapon_classes.names;
pub const WeaponClassName = d_weapon_classes.Class;

/// The built-in resistance rows (the saves' order).
pub const resist_count = d_resist.table.len;

/// The rules in force (process-wide, set at startup by loaders.openGame).
pub var active: *const Set = &builtin;
/// An OpenGorky project: class fields override rules (the exe ignores them).
pub var og = false;

/// Classic code paths entered while an OpenGorky project runs: a project
/// of OG Script reads nothing of the exe's built-ins, the Classic files or
/// core/classic.zig, so `convert-regress` asserts 0. Counted only with `og` (a Classic
/// run never counts); `classic_first` names the first one met. Process-wide, never reset.
pub var classic_paths: u32 = 0;
pub var classic_first: []const u8 = "";

/// Classic path `what` entered (counted for an OpenGorky project only).
pub fn classicPath(what: []const u8) void {
    if (!og) return;
    if (classic_paths == 0) classic_first = what;
    classic_paths += 1;
}

/// The rules files (rows' `file`), each `rules\<name>.ss`.
pub const files = [_][]const u8{ "attacks", "resist", "ui", "fx", "weapon_classes", "patterns", "items", "actions", "party", "ai", "campaign", "fighters", "adjust", "battle" };

/// Rules file `name`'s in an OpenGorky project (`rules/<it>.ogs`): party's and adjust's
/// rows are its `settings` (the reader reads every file alike).
pub fn ogFile(name: []const u8) []const u8 {
    for ([_][]const u8{ "party", "adjust" }) |x| if (std.mem.eql(u8, name, x)) return "settings";
    return name;
}

/// Rules file `name`'s path in an OpenGorky project's `src/` (`name`: a table's file, or
/// ogFile's `settings`): the interface's `ui.ogs` beside game.ogs, the rest `rules/<ogFile>.ogs`.
pub fn ogPath(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "settings")) return "rules/settings.ogs";
    inline for (files) |f| if (std.mem.eql(u8, f, name)) return comptime pathOf(f);
    return "rules/other.ogs";
}

fn pathOf(comptime f: []const u8) []const u8 {
    if (std.mem.eql(u8, f, "ui")) return "ui.ogs";
    return "rules/" ++ ogFile(f) ++ ".ogs";
}

/// Row `r`'s rules file in an OpenGorky project: its table's (ogFile), the game-wide AI
/// profile's (no fighter, no class) `settings`.
pub fn rowFile(comptime Row: type, r: Row) []const u8 {
    if (Row == AiProfile and r.fighter == 0 and r.fighter_class.len == 0 and r.class == 0 and r.class_name.len == 0) return "settings";
    return ogFile(Row.file);
}

// ---------------------------------------------------------------- lookups

fn find(comptime field: []const u8, comptime key: []const u8, v: anytype) ?*const @typeInfo(@FieldType(Set, field)).pointer.child {
    for (@field(active.*, field)) |*r| if (@field(r, key) == v) return r;
    return null;
}

/// What a rule row is looked up for: a classic_id and, in an OpenGorky project, a class.
pub const Who = struct {
    id: i32,
    class: []const u8 = "",
    /// The object's own name (a level's placed fighter `01pr_hornet02`; OpenGorky): a
    /// class key naming it beats its class.
    obj: []const u8 = "",
};

/// `o`'s identity: its classic_id and (OpenGorky only) its class.
pub fn who(o: *Object) Who {
    return .{ .id = o.getInt("classic_id"), .class = if (og) classOf(o.class) else "", .obj = if (og) o.name else "" };
}

/// Prefixes of the entity scripts a level's object script includes.
const entity_prefixes = [_][]const u8{ "ft_", "wp_", "cw_", "ca_", "ci_" };

/// The entity class an object is made of: the first ft_/wp_/cw_/ca_/ci_ script its init()
/// includes (a level's `01pr_hornet02.ftr` → `ft_hornet`), else its own file's stem
/// (`cw_riffle.s` → `cw_riffle`, `gamestart\ovitz.hro` → `ovitz`). Cached in the class.
pub fn classOf(cls: *script.object.Class) []const u8 {
    if (cls.ident) |s| return s;
    classicPath("rules.classOf");
    const s = (if (cls.findFunction("init")) |f| includedClass(f.body) else null) orelse stem(cls.name);
    cls.ident = s;
    return s;
}

fn includedClass(body: []const script.ast.Stmt) ?[]const u8 {
    for (body) |*st| switch (st.*) {
        .include => |n| {
            const s = stem(n);
            for (entity_prefixes) |p| if (std.ascii.startsWithIgnoreCase(s, p)) return s;
        },
        .block => |b| if (includedClass(b)) |s| return s,
        else => {},
    };
    return null;
}

/// File name without folders and extension.
pub fn stem(path: []const u8) []const u8 {
    const base = path[if (std.mem.lastIndexOfAny(u8, path, "\\/")) |k| k + 1 else 0..];
    return base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];
}

/// An OpenGorky project's blocks that are another's (`same_as`), by path → that main
/// block's path: one identity (a row by one names them all, as Classic's by their shared
/// classic_id did); loaders/ogs.zig fills it.
pub var mains: std.StringHashMapUnmanaged([]const u8) = .empty;

fn mainOf(path: []const u8) []const u8 {
    return mains.get(path) orelse path;
}

/// Classes `a` and `b` are one thing: the same, or of one `same_as` group.
fn sameThing(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b) or std.ascii.eqlIgnoreCase(mainOf(a), mainOf(b));
}

/// How key `k` of row `r` names `w`: 3 by its object, 2 by class, 1 by classic_id (a row
/// without a class).
pub fn keyMatch(r: anytype, comptime k: []const u8, w: Who) ?u2 {
    const c: []const u8 = @field(r, k ++ "_class");
    if (c.len > 0) return if (w.obj.len > 0 and std.ascii.eqlIgnoreCase(c, w.obj)) 3 else if (w.class.len > 0 and sameThing(c, w.class)) 2 else null;
    return if (@field(r, k) == w.id) 1 else null;
}

/// The row of `field` whose key `key` names `w` best (class, then classic_id; the first of equals).
fn findWho(comptime field: []const u8, comptime key: []const u8, w: Who) ?*const @typeInfo(@FieldType(Set, field)).pointer.child {
    var best: ?*const @typeInfo(@FieldType(Set, field)).pointer.child = null;
    var score: u2 = 0;
    for (@field(active.*, field)) |*r| if (keyMatch(r.*, key, w)) |m| if (m > score) {
        best = r;
        score = m;
    };
    return best;
}

/// Key `k` of `r` is the wildcard 0 (no class).
fn anyKey(r: anytype, comptime k: []const u8) bool {
    return @field(r, k) == 0 and @field(r, k ++ "_class").len == 0;
}

/// The fighter's row with this weapon, else its weapon = 0 row (the last one, as the
/// exe's table reads); a class key beats a classic_id one, the fighter's before the weapon's.
pub fn monsterAttack(fighter: Who, weapon: Who) ?*const MonsterAttack {
    var best: ?*const MonsterAttack = null;
    var score: u8 = 0;
    for (active.monster_attacks) |*r| {
        const f = keyMatch(r.*, "fighter", fighter) orelse continue;
        const wm: u8 = if (keyMatch(r.*, "weapon", weapon)) |m| m else if (anyKey(r.*, "weapon")) 0 else continue;
        const s = @as(u8, f) * 4 + wm + 1;
        if (s > score or (s == score and wm == 0)) {
            best = r;
            score = s;
        }
    }
    return best;
}

/// Weapon classes of `fighter`'s `give` rows (OpenGorky: new attacks), into `out`.
pub fn givenWeapons(fighter: Who, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    for (active.monster_attacks) |*r| {
        if (!r.give or r.weapon_class.len == 0 or keyMatch(r.*, "fighter", fighter) == null) continue;
        if (n == out.len) break;
        out[n] = r.weapon_class;
        n += 1;
    }
    return out[0..n];
}

/// A fighter with MonsterAttack rows strikes by them.
pub fn hasMonsterAttack(fighter: Who) bool {
    return findWho("monster_attacks", "fighter", fighter) != null;
}

/// The weapon's row for this hero, else its hero = 0 row, else the weapon = 0, hero = 0
/// row (both the last one); class keys first.
pub fn heroAttack(weapon: Who, hero: Who) *const HeroAttack {
    if (heroAttackRow(weapon, hero)) |b| return b;
    // No row, not even a wildcard: the exe's rifle strike (Classic's data).
    classicPath("rules.heroAttack: no row");
    return &builtin.hero_attacks[builtin.hero_attacks.len - 1];
}

/// `hero`'s strike row with `weapon`; null: none, not even a wildcard (a monster's weapon).
pub fn heroAttackRow(weapon: Who, hero: Who) ?*const HeroAttack {
    var best: ?*const HeroAttack = null;
    var score: u8 = 0;
    for (active.hero_attacks) |*r| {
        const s: u8 = if (keyMatch(r.*, "weapon", weapon)) |wm| blk: {
            const hm: u8 = if (keyMatch(r.*, "hero", hero)) |m| m else if (anyKey(r.*, "hero")) 0 else continue;
            break :blk @as(u8, wm) * 4 + hm + 1;
        } else if (anyKey(r.*, "weapon") and anyKey(r.*, "hero")) 1 else continue;
        // An exact row: the first; a fallback: the last.
        const exact = s > 1 and (s - 1) % 4 != 0;
        if (s > score or (s == score and !exact)) {
            best = r;
            score = s;
        }
    }
    return best;
}

pub fn wdelayHero(hero: Who) bool {
    return findWho("wdelay_heroes", "hero", hero) != null;
}

pub fn resist(fighter: Who) ?*const Resist {
    return findWho("resist", "fighter", fighter);
}

/// Engine setting `name` of weapon `w`: its own (`Setting(weapon = ~w"…")`, the weapon block's
/// `flame = Flame(…)`), else null (the project's: adjust).
fn weaponSetting(name: []const u8, w: Who) ?adjust.Value {
    var best: ?adjust.Value = null;
    var score: u2 = 0;
    for (active.adjust) |r| {
        if (anyKey(r, "weapon") or !std.mem.eql(u8, r.name, name)) continue;
        if (keyMatch(r, "weapon", w)) |m| if (m > score) {
            best = r.value();
            score = m;
        };
    }
    return best;
}

/// Engine setting `name` (rules/adjust_defaults.zig) for an effect weapon `w` makes (null:
/// none): the weapon's own, else the project's.
pub fn weaponFloat(comptime name: []const u8, w: ?Who) f32 {
    if (w) |x| if (weaponSetting(name, x)) |v| switch (v) {
        .float => |f| return f,
        .int => |n| return @floatFromInt(n),
        .rgba => {},
    };
    return adjust.float(name);
}

pub fn weaponInt(comptime name: []const u8, w: ?Who) i32 {
    if (w) |x| if (weaponSetting(name, x)) |v| switch (v) {
        .int => |n| return n,
        .float => |f| return @import("script.zig").value.floatToInt(f),
        .rgba => {},
    };
    return adjust.int(name);
}

pub fn weaponRgb(comptime name: []const u8, w: ?Who) [3]u8 {
    if (w) |x| if (weaponSetting(name, x)) |v| if (v == .rgba) return v.rgba;
    return adjust.rgb(name);
}

pub fn killIcon(fighter: Who) ?[]const u8 {
    return if (findWho("kill_icons", "fighter", fighter)) |r| r.icon else null;
}

/// `fighter`'s glow (rules Glow), if any.
pub fn glow(fighter: Who) ?*const Glow {
    return findWho("glows", "fighter", fighter);
}

pub fn skillIcon(weapon: Who) ?[]const u8 {
    return if (findWho("skill_icons", "weapon", weapon)) |r| r.icon else null;
}

/// The hit sound of game weapon classic_id `weapon` (after FxAs).
pub fn weaponSound(weapon: i32) ?[]const u8 {
    return if (find("weapon_sounds", "weapon", weapon)) |r| r.sound else null;
}

/// A WeaponSound row by `weapon`'s class (OpenGorky), over the one by its effects' classic_id.
pub fn classWeaponSound(weapon: Who) ?[]const u8 {
    const r = findWho("weapon_sounds", "weapon", weapon) orelse return null;
    return if (r.weapon_class.len > 0) r.sound else null;
}

pub fn fxAs(weapon: Who) i32 {
    return if (findWho("fx_as", "weapon", weapon)) |r| (if (r.as != 0) r.as else weapon.id) else weapon.id;
}

/// Weapon `weapon` has flag `f` (WeaponFlags' bools).
pub fn weaponFlag(weapon: Who, comptime f: enum { no_counter, shock, sparks, silent_frames }) bool {
    return if (findWho("weapon_flags", "weapon", weapon)) |r| @field(r, @tagName(f)) else false;
}

/// The AI profile of a fighter of classType `class`: its class's row (else class 0's),
/// the fields a row by the fighter writes over it (null: none, battle/generic.zig
/// aiProfile: a non-enemy's). Every field set.
pub fn aiProfile(fighter: ?Who, class: i32) AiProfile {
    const rs = aiProfileRows(fighter, class);
    var p = if (rs.base) |b| b.* else blk: {
        // No class-0 row: the exe's ordinary monster (Classic's data).
        classicPath("rules.aiProfile: no class row");
        break :blk d_ai.profiles[0];
    };
    if (rs.own) |r| inline for (@typeInfo(AiProfile).@"struct".field_names) |n| {
        if (comptime @typeInfo(@FieldType(AiProfile, n)) == .optional) if (@field(r, n)) |v| {
            @field(p, n) = v;
        };
    };
    // A class row a file left incomplete: the ordinary monster's values.
    inline for (@typeInfo(AiProfile).@"struct".field_names) |n| if (comptime @typeInfo(@FieldType(AiProfile, n)) == .optional and !isAicField(n)) {
        if (@field(p, n) == null) @field(p, n) = @field(d_ai.profiles[0], n);
    };
    return p;
}

/// The rows aiProfile is made of: its classType's (else class 0's) and the fighter's own
/// (null `fighter`: none).
pub fn aiProfileRows(fighter: ?Who, class: i32) struct { base: ?*const AiProfile, own: ?*const AiProfile } {
    var base: ?*const AiProfile = null;
    for (active.ai_profiles) |*r| if (anyKey(r.*, "fighter")) {
        if (rowClass(r.*) == class) {
            base = r;
            break;
        }
        if (rowClass(r.*) == 0 and base == null) base = r;
    };
    return .{ .base = base, .own = if (fighter) |w| findWho("ai_profiles", "fighter", w) else null };
}

test aiProfileRows {
    // The game's rows: an ordinary monster has class 0's, the Stinger (classType 9) its
    // own, a classType with no row class 0's; no fighter has a row of its own.
    const rs = aiProfileRows(.{ .id = 119 }, 9);
    try std.testing.expectEqualStrings("a", rs.base.?.scoring.?);
    try std.testing.expect(rs.own == null);
    try std.testing.expectEqual(@as(i32, 0), aiProfileRows(.{ .id = 119 }, 99).base.?.class);
    try std.testing.expectEqual(@as(i32, 0), aiProfileRows(.{ .id = 119 }, 0).base.?.class);
}

/// AiProfile fields that override the fighter's own ai_*_weight, ai_mode (null: its own).
fn isAicField(comptime n: []const u8) bool {
    for ([_][]const u8{ "attack_weight", "threat_weight", "opponent_distance_weight", "guard_distance_weight", "mode" }) |x| if (std.mem.eql(u8, x, n)) return true;
    return false;
}

/// Weapon class `class` (the object's number: Classic `classType`).
pub fn weaponClass(class: i32) WeaponClass {
    return if (find("weapon_classes", "classic_id", class)) |r| r.* else .{ .name = weaponClassName(class) orelse "", .classic_id = class };
}

pub fn pattern(class: i32) ?*const Pattern {
    return find("patterns", "classic_id", class);
}

/// The number of the weapon class named `name` (its WeaponClass or Pattern row's; an
/// OpenGorky weapon's `class = pistol`), any case; null: no row.
pub fn weaponClassId(name: []const u8) ?i32 {
    for (active.weapon_classes) |r| if (std.ascii.eqlIgnoreCase(r.name, name)) return r.classic_id;
    for (active.patterns) |r| if (std.ascii.eqlIgnoreCase(r.name, name)) return r.classic_id;
    return null;
}

/// The port's own fighter of fields (battle/generic.zig): its class, fixed.
const generic_class: i32 = 100;

/// The number of fighter class `name` (a fighter's `battle_class = smokerider`, a row's
/// `class_name`), any case: `generic` 100; Classic the exe's (rules/fighter_classes.zig);
/// an OpenGorky project's, one made from the name (the same every run), its classes being
/// its own names. null: Classic, no such class.
pub fn fighterClassId(name: []const u8) ?i32 {
    if (std.ascii.eqlIgnoreCase(name, "generic")) return generic_class;
    if (!og) return d_fighter_classes.idOf(name);
    var h = std.hash.Fnv1a_32.init();
    for (name) |ch| h.update(&.{std.ascii.toLower(ch)});
    const n: i32 = @intCast(0x10000 + h.final() % 0x3fff0000);
    fighter_names.put(std.heap.page_allocator, n, std.heap.page_allocator.dupe(u8, name) catch return n) catch {};
    return n;
}

/// The name of fighter class number `n` (one fighterClassId made, the exe's); null: none.
pub fn fighterClassName(n: i32) ?[]const u8 {
    if (n == generic_class) return "generic";
    if (fighter_names.get(n)) |x| return x;
    return if (og) null else d_fighter_classes.nameOf(n);
}

var fighter_names: std.AutoHashMapUnmanaged(i32, []const u8) = .empty;

/// The class number row `r` (Abilities, AiProfile) is keyed by: its `class_name`'s, else its `class`.
pub fn rowClass(r: anytype) i32 {
    return if (r.class_name.len > 0) fighterClassId(r.class_name) orelse -1 else r.class;
}

/// The class of the AiProfile row a generic fighter of `ai = <name>` takes (its
/// `generic_ai`: focused, sleep_hunter); 0 (class 0's): none.
pub fn genericAiClass(name: []const u8) i32 {
    for (active.ai_profiles) |r| if (std.ascii.eqlIgnoreCase(r.generic_ai, name)) return rowClass(r);
    return 0;
}

/// The name of weapon class number `class`: its rows', else the exe's class's
/// (weapon_classes.zig `names`: a new row of it); null: none.
pub fn weaponClassName(class: i32) ?[]const u8 {
    if (find("weapon_classes", "classic_id", class)) |r| if (r.name.len > 0) return r.name;
    if (pattern(class)) |r| if (r.name.len > 0) return r.name;
    classicPath("rules.weaponClassName: the exe's class names");
    const n = d_weapon_classes.nameOf(class);
    return if (n.len > 0) n else null;
}

pub fn medicineOf(item: Who) Medicine {
    return if (findWho("medicine", "item", item)) |r| r.* else .{ .item = item.id };
}

pub fn healBonusPct(healer: Who) i32 {
    return heroBonus(healer).pct;
}

/// The hero's bonuses row (HealBonus), else none (all 0).
pub fn heroBonus(hero: Who) HealBonus {
    return if (findWho("heal_bonus", "healer", hero)) |r| r.* else .{ .healer = hero.id, .pct = 0 };
}

pub fn action(func: i32) ?*const Action {
    return find("actions", "classic_id", func);
}

/// The Action row named `name` (an OpenGorky object's `action = Take`), any case.
pub fn actionNamed(name: []const u8) ?*const Action {
    for (active.actions) |*r| if (std.ascii.eqlIgnoreCase(r.name, name)) return r;
    return null;
}

/// string.tab id of action `func`'s menu row; 0: none (an OpenGorky project's own action
/// without `text`: its number is the reader's, the row shows its name).
pub fn actionText(func: i32) i32 {
    const a = action(func) orelse return func;
    if (a.text != 0) return a.text;
    if (a.label.len > 0) return 0;
    if (og) classicPath("rules.actionText: a row without text");
    if (og) for (builtin.actions) |b| {
        if (std.ascii.eqlIgnoreCase(b.name, a.name)) break;
    } else return 0;
    return func;
}

/// Action `func`'s menu text by interface key (its `label`, core/ui_text.zig; "": none).
pub fn actionLabel(func: i32) []const u8 {
    return if (action(func)) |a| a.label else "";
}

/// Action `func` (an object's action…) has flag `f` (Action's bools).
pub fn actionFlag(func: i32, comptime f: enum { auto_open, on_exit, walk_click }) bool {
    return if (action(func)) |a| @field(a, @tagName(f)) else false;
}

/// Exp threshold of `level`; 0 past the table.
pub fn expLevel(level: i32) i32 {
    return if (find("exp_levels", "level", level)) |r| r.exp else 0;
}

/// The highest level of the table in force (the exe's 19): heroes level up to it.
pub fn maxLevel() i32 {
    var m: i32 = 0;
    for (active.exp_levels) |r| m = @max(m, r.level);
    return m;
}

/// `exp` at `level` keeps `levels`' thresholds growing: above every lower level's,
/// below every higher one's.
pub fn expGrows(levels: []const ExpLevel, level: i32, exp: i32) bool {
    for (levels) |r| if ((r.level < level and r.exp >= exp) or (r.level > level and r.exp <= exp)) return false;
    return true;
}

pub fn hiddenWeapons(hero: Who) ?*const HiddenWeapons {
    return findWho("hidden_weapons", "hero", hero);
}

pub fn idleChatter(hero: Who) ?*const IdleChatter {
    return findWho("idle_chatter", "hero", hero);
}

pub fn value(c: Const) i32 {
    return if (find("values", "name", c)) |r| r.value else consts.default(c);
}

/// The roles row of character `w` (OpenGorky; null: its files' roles).
pub fn character(w: Who) ?*const Character {
    return findWho("characters", "fighter", w);
}

/// The campaign in force (the built-in one: the exe's new game).
pub fn campaign() *const Campaign {
    return &active.campaign[0];
}

/// The project's texts that are code (OGS components or functions; OpenGorky): whole, as
/// written. Each world loads them (state/hooks.zig): the game's hooks are their `for
/// game` components, a fighter's scripted abilities (`Abilities` `scripts`) their `for
/// fighter` ones.
pub var scripts: []const Script = &.{};

pub const Script = struct { name: []const u8, data: []const u8 };

/// The keys naming a fighter, weapon, hero or item (classic_id, or a class where the table
/// has `<key>_class`).
pub const entity_keys = .{ "fighter", "weapon", "hero", "item", "healer" };

/// How `r` names `w` by one of its entity keys: 2 by class, 1 by classic_id, null not.
pub fn rowMatch(comptime Row: type, r: Row, w: Who) ?u2 {
    var best: ?u2 = null;
    inline for (entity_keys) |k| if (@hasField(Row, k)) {
        const m: ?u2 = if (@hasField(Row, k ++ "_class")) keyMatch(r, k, w) else if (@field(r, k) == w.id) 1 else null;
        if (m) |x| if (best == null or x > best.?) {
            best = x;
        };
    };
    return best;
}

// ---------------------------------------------------------------- the rules read from files

/// The arena of the rules read from files (loaders/rules_text.zig), until `reset`.
var loaded_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var loaded: Set = builtin;

/// The rules' arena (loaders/rules_text.zig reads the files into it).
pub fn filesArena() Allocator {
    return loaded_arena.allocator();
}

/// Bumped whenever the rules in force change (`use`, `reset`): what the core stores from
/// them (core/entity.zig's records) is dropped then.
pub var version: u32 = 0;

/// `set` (its rows in `filesArena`) as the rules in force. error.OutOfMemory: the
/// project's Setting rows did not all go in (the rest would be silently the defaults).
pub fn use(set: Set) Allocator.Error!void {
    loaded = set;
    active = &loaded;
    version +%= 1;
    // OpenGorky: the tuning values are the Setting rows (none: compose's fallback stays).
    if (og and set.adjust.len > 0) {
        adjust.clear();
        // One weapon's own value (weaponSetting) is no project's.
        for (set.adjust) |r| if (anyKey(r, "weapon")) if (r.value()) |v| try adjust.put(r.name, v);
    }
}

/// Back to the built-ins.
pub fn reset() void {
    active = &builtin;
    version +%= 1;
    og = false;
    _ = loaded_arena.reset(.free_all);
    loaded = builtin;
    scripts = &.{};
}

test "rules: the built-in AI profiles are the exe's table 0x4bcbb0" {
    const want = [_]struct { i32, AiEval }{
        .{ 0, "generic" },       .{ 1, "garcia" }, .{ 2, "generic" }, .{ 5, "generic" },  .{ 6, "smokerider" }, .{ 7, "grandma" },
        .{ 8, "grandma_child" }, .{ 9, "a" },      .{ 10, "a" },      .{ 11, "incubus" }, .{ 12, "cripple" },   .{ 13, "a" },
        .{ 14, "guard" },        .{ 15, "a" },     .{ 16, "a" },      .{ 17, "schizo" },  .{ 18, "messiah" },   .{ 19, "generic" },
    };
    for (want) |x| try std.testing.expectEqualStrings(x[1], aiProfile(.{ .id = 1 }, x[0]).scoring.?);
    // Only the ordinary monster takes +5, a monitor x2 and decoys; the Guard no threat.
    try std.testing.expectEqual(5, aiProfile(.{ .id = 1 }, 0).damage_bonus.?);
    try std.testing.expectEqual(0, aiProfile(.{ .id = 1 }, 9).damage_bonus.?);
    try std.testing.expect(aiProfile(.{ .id = 1 }, 0).decoys.? and !aiProfile(.{ .id = 1 }, 1).decoys.?);
    try std.testing.expect(!aiProfile(.{ .id = 1 }, 14).threat.? and !aiProfile(.{ .id = 1 }, 14).step_away.?);
}

test "rules: the weapon flags are the exe's classic_id lists" {
    for ([_]i32{ 1031, 33, 45, 1025, 52, 34, 55 }) |id| try std.testing.expect(weaponFlag(.{ .id = id }, .no_counter));
    for ([_]i32{ 92, 46, 98, 0 }) |id| try std.testing.expect(!weaponFlag(.{ .id = id }, .no_counter));
    for ([_]i32{ 52, 55, 92 }) |id| try std.testing.expect(weaponFlag(.{ .id = id }, .shock));
    try std.testing.expect(weaponFlag(.{ .id = 46 }, .sparks) and !weaponFlag(.{ .id = 52 }, .sparks));
    try std.testing.expect(weaponFlag(.{ .id = 45 }, .silent_frames) and !weaponFlag(.{ .id = 49 }, .silent_frames));
}

test "rules: a row by a placed fighter beats its class's, which beats its classic_id's" {
    var set = builtin;
    set.resist = &.{
        .{ .fighter = 0, .fighter_class = "01pr_hornet02", .armor = -3 },
        .{ .fighter = 0, .fighter_class = "ft_hornet", .armor = -1 },
        .{ .fighter = 128, .armor = -2 },
    };
    try use(set);
    defer reset();
    try std.testing.expectEqual(-3, resist(.{ .id = 128, .class = "ft_hornet", .obj = "01pr_hornet02" }).?.armor);
    try std.testing.expectEqual(-1, resist(.{ .id = 128, .class = "ft_hornet", .obj = "01pr_hornet03" }).?.armor);
    try std.testing.expectEqual(-2, resist(.{ .id = 128 }).?.armor);
}

test stem {
    try std.testing.expectEqualStrings("ft_hornet", stem("ft_hornet.ss"));
    try std.testing.expectEqualStrings("ovitz", stem("gamestart\\ovitz.hro"));
    try std.testing.expectEqualStrings("cw_riffle", stem("cw_riffle"));
}

test expGrows {
    const t = builtin.exp_levels;
    try std.testing.expect(expGrows(t, 1, 221) and expGrows(t, 1, 449) and expGrows(t, 20, 8954881));
    try std.testing.expect(!expGrows(t, 1, 450) and !expGrows(t, 1, 0) and !expGrows(t, 20, 8954880));
}

test "rules: the built-in action flags are the exe's special cases" {
    try std.testing.expect(actionFlag(7, .auto_open) and !actionFlag(3, .auto_open));
    try std.testing.expect(actionFlag(1, .on_exit) and !actionFlag(-1, .on_exit));
    try std.testing.expect(actionFlag(2, .walk_click) and !actionFlag(0, .walk_click));
    try std.testing.expectEqual(7, actionText(7));
    try std.testing.expectEqual(3, actionNamed("take").?.classic_id);
}

test {
    _ = consts;
    _ = rows;
    _ = adjust;
    _ = adjust_owners;
    _ = d_fighter_classes;
}

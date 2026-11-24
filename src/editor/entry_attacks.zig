//! An entity's behaviour rules on its page (OpenGorky; og.rules): an enemy's attacks
//! (MonsterAttack rows by its class, one per weapon, new ones given at battle entry) and
//! the AI profile it uses (AiProfile, edited on the AI profiles page: rulespages), the saws
//! its own strike spins (FighterStrike by `special`), a weapon's effects (its block's
//! `effects_from`…; Classic's FxAs), a hero's
//! party rules (IdleChatter, Value party_max). Each edit writes the row by its key into
//! the layer's rules file (rules_rows: one undo step); the rules in force follow.
//! Classic: the locked rows (the exe keeps all this in its code by classic_id).

const std = @import("std");
const Allocator = std.mem.Allocator;
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const model = @import("model.zig");
const Entry = @import("catalog.zig").Entry;
const common_archive = @import("store.zig").common_archive;
const entry_rules = @import("entry_rules.zig");
const rules_rows = @import("rules_rows.zig");
const preview = @import("preview.zig");
const picker = @import("picker.zig");
const og = @import("opengorky");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const rules = og.rules;
const codec = og.loaders.codec;
const World = og.state.world.World;

// ---------------------------------------------------------------- rows in force

/// Rows of fields: each a text field showing the value, or (a third element, a Choice)
/// a list of its known values; a value typed in or picked is written by
/// `apply(field, text)`. `keys`: the fields' id prefix.
pub fn fieldRows(app: *App, a: Allocator, comptime Row: type, row: Row, comptime fields: anytype, key: []const u8, ctx: anytype, comptime apply: fn (@TypeOf(ctx), *App, []const u8, []const u8) anyerror!void) void {
    inline for (fields) |fl| {
        gui.fieldRow(tx.get(fl[1]));
        const id = std.fmt.allocPrint(a, "{s}_{s}", .{ key, fl[0] }) catch fl[0];
        const cur = rules_rows.fieldText(a, Row, row, fl[0]);
        if (fl.len > 2) {
            const open = picker.field(app, clay.id(id), fl[2].label(app, a, cur), false);
            clay.close();
            if (open) if (picker.listKey(app, a, fl[2].rows(app, a, cur))) |t| apply(ctx, app, fl[0], t) catch |err| rules_rows.failed(app, fl[0], err);
        } else {
            if (gui.textField(app, id, cur, 0, "—")) |t| apply(ctx, app, fl[0], t) catch |err| rules_rows.failed(app, fl[0], err);
            clay.close();
        }
    }
}

/// A rules field's known values (fieldRows' third element): `label` of the value `cur`
/// as fieldText writes it, `rows` the values (each key the text written).
const Choice = struct {
    label: *const fn (*App, Allocator, []const u8) []const u8,
    rows: *const fn (*App, Allocator, []const u8) []picker.Opt,
};

/// Rows of `keys` labelled by `label`, the one `cur` selected.
fn keyRows(app: *App, a: Allocator, keys: []const []const u8, cur: []const u8, label: *const fn (*App, Allocator, []const u8) []const u8) []picker.Opt {
    const out = a.alloc(picker.Opt, keys.len) catch return &.{};
    for (keys, out) |k, *o| o.* = .{ .key = k, .label = label(app, a, k), .selected = std.mem.eql(u8, k, cur) };
    return out;
}

fn intKeys(a: Allocator, vs: []const i32) []const []const u8 {
    const out = a.alloc([]const u8, vs.len) catch return &.{};
    for (vs, out) |v, *o| o.* = std.fmt.allocPrint(a, "{d}", .{v}) catch "0";
    return out;
}

/// A field's text as its number: an archetype's path (`weapons::rocket_launcher`, an
/// OpenGorky reference: fieldText) its classic_id.
fn parsed(t: []const u8) i32 {
    if (std.mem.indexOf(u8, t, "::") != null) return og.core.entity.idOf(t) orelse 0;
    return std.fmt.parseInt(i32, t, 10) catch 0;
}

/// A game weapon classic_id whose effects (`st` null: any stage's) a field takes: 0 the
/// weapon's own, -1 none (`none`: a stage's alone).
pub fn gameWeapon(comptime st: ?Stage, comptime none: bool) Choice {
    return .{ .label = struct {
        fn f(app: *App, a: Allocator, cur: []const u8) []const u8 {
            return stageLabel(app, a, parsed(cur));
        }
    }.f, .rows = struct {
        fn f(app: *App, a: Allocator, cur: []const u8) []picker.Opt {
            const lead: []const i32 = if (none) &.{ 0, -1 } else &.{0};
            const ids = if (st) |s| stageIds(a, s) else blk: {
                var all: std.ArrayList(i32) = .empty;
                for (og.core.modules.tables().weapon_fx) |w| if (std.mem.indexOfScalar(i32, all.items, w.id) == null) all.append(a, w.id) catch {};
                break :blk all.items;
            };
            return keyRows(app, a, intKeys(a, std.mem.concat(a, i32, &.{ lead, ids }) catch lead), cur, @This().label);
        }
        fn label(app: *App, a: Allocator, k: []const u8) []const u8 {
            return stageLabel(app, a, parsed(k));
        }
    }.f };
}

/// A sound by name ("": the game's, WeaponSound).
const sound_choice: Choice = .{ .label = struct {
    fn f(_: *App, _: Allocator, cur: []const u8) []const u8 {
        return if (cur.len > 0) cur else tx.get(tx.fx_sound_hint);
    }
}.f, .rows = struct {
    fn f(app: *App, a: Allocator, cur: []const u8) []picker.Opt {
        const ns = app.player.names(app, a);
        const out = a.alloc(picker.Opt, ns.len + 1) catch return &.{};
        out[0] = .{ .key = "", .label = tx.get(tx.fx_sound_hint), .selected = cur.len == 0 };
        for (ns, out[1..]) |n, *o| o.* = .{ .key = n, .label = n, .selected = std.mem.eql(u8, n, cur) };
        return out;
    }
}.f };

/// A weapon class (classType; 0: the weapon's own).
const class_choice: Choice = .{ .label = classOrOwn, .rows = struct {
    fn f(app: *App, a: Allocator, cur: []const u8) []picker.Opt {
        var ks: std.ArrayList([]const u8) = .empty;
        ks.append(a, "") catch {};
        for (rules.active.patterns) |p| if (p.name.len > 0) ks.append(a, p.name) catch {};
        return keyRows(app, a, ks.items, cur, classOrOwn);
    }
}.f };

/// A weapon class by its name ("": the weapon's own).
fn classOrOwn(_: *App, a: Allocator, k: []const u8) []const u8 {
    if (k.len == 0) return tx.get(tx.fx_same);
    const n = rules.weaponClassId(k) orelse return k;
    return @import("item_page.zig").classLabel(a, @floatFromInt(n));
}

/// A damage type (`type` of a weapon; 0: the weapon's own).
const damage_choice: Choice = .{ .label = damageOrOwn, .rows = struct {
    fn f(app: *App, a: Allocator, cur: []const u8) []picker.Opt {
        return keyRows(app, a, std.meta.fieldNames(rules.rows.DamageKind), cur, damageOrOwn);
    }
}.f };

/// An AiProfile field over the fighter's own (unset: "").
fn unsetOr(cur: []const u8, comptime f: fn ([]const u8) []const u8) []const u8 {
    return if (cur.len == 0) tx.get(tx.ai_unset) else f(cur);
}

/// The scoring (AiEval) of an AI profile.
pub const eval_choice: Choice = .{
    .label = struct {
        fn f(_: *App, _: Allocator, cur: []const u8) []const u8 {
            return unsetOr(cur, struct {
                fn g(c: []const u8) []const u8 {
                    return c;
                }
            }.g);
        }
    }.f,
    .rows = struct {
        fn f(app: *App, a: Allocator, cur: []const u8) []picker.Opt {
            // The scorings the rules in force have (AiScoring rows' names).
            const ss = og.core.modules.tables().scorings;
            const names = a.alloc([]const u8, ss.len) catch return &.{};
            for (ss, names) |r, *n| n.* = r.eval;
            return keyRows(app, a, names, cur, struct {
                fn g(_: *App, _: Allocator, k: []const u8) []const u8 {
                    return k;
                }
            }.g);
        }
    }.f,
};

/// aiMode's meanings (0–3: combat/ai.zig).
pub fn modeLabel(k: []const u8) []const u8 {
    const ms = [_]tx.Msg{ tx.ai_mode_0, tx.ai_mode_1, tx.ai_mode_2, tx.ai_mode_3 };
    const v = std.fmt.parseInt(usize, k, 10) catch return k;
    return if (v < ms.len) tx.get(ms[v]) else k;
}

/// An AI mode (aiMode; an AiProfile's `mode` over it).
pub const mode_choice: Choice = .{ .label = struct {
    fn f(_: *App, _: Allocator, cur: []const u8) []const u8 {
        return unsetOr(cur, modeLabel);
    }
}.f, .rows = struct {
    fn f(app: *App, a: Allocator, cur: []const u8) []picker.Opt {
        return keyRows(app, a, &.{ "0", "1", "2", "3" }, cur, struct {
            fn g(_: *App, _: Allocator, k: []const u8) []const u8 {
                return modeLabel(k);
            }
        }.g);
    }
}.f };

fn yesNo(k: []const u8) []const u8 {
    return tx.get(if (std.mem.eql(u8, k, "1")) tx.la_yes else tx.la_no);
}

/// An AiProfile flag (decoys, step_away, ...): yes / no over the fighter's.
pub const flag_choice: Choice = .{ .label = struct {
    fn f(_: *App, _: Allocator, cur: []const u8) []const u8 {
        return unsetOr(cur, yesNo);
    }
}.f, .rows = struct {
    fn f(app: *App, a: Allocator, cur: []const u8) []picker.Opt {
        return keyRows(app, a, &.{ "1", "0" }, cur, struct {
            fn g(_: *App, _: Allocator, k: []const u8) []const u8 {
                return yesNo(k);
            }
        }.g);
    }
}.f };

/// A damage kind by its word (`none`: the weapon's own).
fn damageOrOwn(_: *App, _: Allocator, k: []const u8) []const u8 {
    const v = std.meta.stringToEnum(rules.rows.DamageKind, k) orelse return k;
    return if (v == .none) tx.get(tx.fx_same) else @import("item_page.zig").damageLabel(@floatFromInt(@backingInt(v)));
}

// ---------------------------------------------------------------- enemy attacks

/// One of an enemy's attacks: its weapon class (`wp_hornet`), that weapon's classic_id, and
/// whether a rule gives it (a new attack, not in the battles' `.wpn`).
pub const Attack = struct { class: []const u8, id: i32, given: bool };

/// The enemy's attacks: the weapon classes its fighters hold (its base class's for a copy
/// not placed yet), then those its rows give.
pub fn attacksOf(app: *App, a: Allocator, e: Entry, who: rules.Who) []Attack {
    var out: std.ArrayList(Attack) = .empty;
    var weapons = e.weapons.items;
    if (weapons.len == 0) if (e.base) |b| for (app.catalog.entries.items) |x| {
        if (x.kind == .enemy and std.ascii.eqlIgnoreCase(x.id, b)) weapons = x.weapons.items;
    };
    for (weapons) |w| out.append(a, .{ .class = rules.stem(w), .id = weaponId(app, rules.stem(w)), .given = false }) catch {};
    var gb: [8][]const u8 = undefined;
    for (rules.givenWeapons(who, &gb)) |g| {
        const dup = for (out.items) |x| {
            if (std.ascii.eqlIgnoreCase(x.class, g)) break true;
        } else false;
        if (!dup) out.append(a, .{ .class = g, .id = weaponId(app, g), .given = true }) catch {};
    }
    return out.items;
}

/// classic_id of weapon class `class` (`classes\<class>.ss`, or `.s` for a cw_ one).
pub fn weaponId(app: *App, class: []const u8) i32 {
    if (app.ogLayout()) return og.core.entity.idOf(class) orelse 0;
    var buf: [128]u8 = undefined;
    for ([_][]const u8{ ".ss", ".s" }) |ext| {
        const f = app.store.file(common_archive, std.fmt.bufPrint(&buf, "classes\\{s}{s}", .{ class, ext }) catch continue) catch continue;
        return @intFromFloat(model.get(app.store.text(f), "classic_id") orelse 0);
    }
    return 0;
}

/// The row in force for `at`, keyed by the enemy's class and the weapon's (what an edit
/// writes); null: the enemy strikes by the hero table.
pub fn attackRow(who: rules.Who, at: Attack) ?rules.MonsterAttack {
    var r = (rules.monsterAttack(who, .{ .id = at.id, .class = at.class }) orelse return null).*;
    r.give = r.give or at.given;
    r.note = "";
    return r;
}

/// `attackRow` keyed for writing (ownKey); a new row is the attack's by its weapon class.
fn ownAttack(app: *App, who: rules.Who, at: Attack) ?rules.MonsterAttack {
    const cur = attackRow(who, at) orelse return null;
    var r = rules_rows.ownKey(app, rules.MonsterAttack, "fighter", cur, who);
    if (r.fighter == cur.fighter and std.ascii.eqlIgnoreCase(r.fighter_class, cur.fighter_class)) return r;
    r.weapon = 0;
    r.weapon_class = at.class;
    return r;
}

/// An attack row's fields by subgroup: timings, effects, damage.
const timing_fields = .{
    .{ "hit_delay", tx.af_wait },          .{ "after_delay", tx.af_after },   .{ "second_delay", tx.af_second },
    .{ "react_delay", tx.af_react },       .{ "flash_delay", tx.af_pre },     .{ "lift_delay", tx.af_lift },
    .{ "drop_delay", tx.af_lift_release }, .{ "vanish_delay", tx.af_vanish },
};
const effect_fields = .{
    .{ "effects_from", tx.af_fx, gameWeapon(null, false) }, .{ "flash_from", tx.af_flash, gameWeapon(.flash, true) }, .{ "launch_from", tx.af_launch, gameWeapon(.launch, true) },
    .{ "hit_from", tx.af_hit, gameWeapon(.hit, true) },     .{ "sound", tx.af_sound, sound_choice },                  .{ "strike", tx.af_special },
    .{ "linked_anim", tx.af_linked },
};
const damage_fields = .{
    .{ "attack_zone", tx.af_zone, class_choice }, .{ "max_damage", tx.af_damage }, .{ "damage_kind", tx.af_dtype, damage_choice },
    .{ "recharge_turns", tx.af_recharge },        .{ "range", tx.af_range },
};

const AttackCtx = struct { who: rules.Who, at: Attack };

fn applyAttack(c: AttackCtx, app: *App, field: []const u8, text: []const u8) !void {
    try setAttack(app, c.who, c.at, field, text);
}

/// Field `field` of the enemy's attack `at` made `text` (the row by class written whole).
pub fn setAttack(app: *App, who: rules.Who, at: Attack, field: []const u8, text: []const u8) !void {
    const base = ownAttack(app, who, at) orelse return error.NoMonsterTable;
    try rules_rows.putField(app, rules.MonsterAttack, base, field, text);
    app.setStatus(tx.st_rule_set, .{ field, at.class });
}

/// A new attack of weapon class `class` (an enemy weapon `wp_*` or a weapon `cw_*`): a
/// `give` row as the enemy's strike with its other weapons, the weapon's own effects.
pub fn addAttack(app: *App, who: rules.Who, from: Attack, class: []const u8) !void {
    var r = ownAttack(app, who, from) orelse return error.NoMonsterTable;
    r.weapon = 0;
    r.weapon_class = class;
    r.give = true;
    // The other weapon's effects and zone are this one's.
    inline for (.{ "effects_from", "flash_from", "launch_from", "hit_from", "max_damage" }) |n| @field(r, n) = 0;
    r.attack_zone = "";
    r.damage_kind = .none;
    r.sound = "";
    try rules_rows.put(app, rules.MonsterAttack, r);
    app.setStatus(tx.st_attack_added, .{ class, who.class });
}

/// A copy of attack `at`: its weapon class copied (`wp_hornet_2.ss`) and given with the
/// same row; the copy's fields are then its own.
pub fn copyAttack(app: *App, who: rules.Who, at: Attack) ![]const u8 {
    var buf: [128]u8 = undefined;
    const ext = if (std.ascii.startsWithIgnoreCase(at.class, "cw_")) ".s" else ".ss";
    const src = app.store.file(common_archive, try std.fmt.bufPrint(&buf, "classes\\{s}{s}", .{ at.class, ext })) catch return error.NoWeaponClass;
    var k: u32 = 2;
    const name = while (k < 100) : (k += 1) {
        const n = try std.fmt.allocPrint(app.catalog.arena.allocator(), "{s}_{d}", .{ at.class, k });
        const entry = try std.fmt.bufPrint(&buf, "classes\\{s}{s}", .{ n, ext });
        if (app.store.file(common_archive, entry)) |_| continue else |_| {}
        var ar = og.formats.archive.Archive.open(app.io, app.gpa, app.dat, common_archive) catch break n;
        defer ar.close(app.io, app.gpa);
        if (ar.find(entry) == null) break n;
    } else return error.NoFreeName;
    const entry = try std.fmt.bufPrint(&buf, "classes\\{s}{s}", .{ name, ext });
    app.store.group();
    defer app.store.endGroup("+ {s}", .{name});
    _ = try app.store.addNew(&.{.{ .archive = common_archive, .entry = entry, .text = try app.gpa.dupe(u8, app.store.text(src)) }});
    var r = ownAttack(app, who, at) orelse return error.NoMonsterTable;
    r.weapon = 0;
    r.weapon_class = name;
    r.give = true;
    try rules_rows.put(app, rules.MonsterAttack, r);
    app.setStatus(tx.st_attack_added, .{ name, who.class });
    return name;
}

/// The enemy's own row of attack `at` out: a given attack is gone, a held one strikes
/// by the game's row again.
pub fn removeAttack(app: *App, who: rules.Who, at: Attack) !void {
    const r = ownAttack(app, who, at) orelse return error.NoMonsterTable;
    if (!try rules_rows.drop(app, rules.MonsterAttack, r)) return error.NoOwnRow;
    app.setStatus(tx.st_attack_removed, .{ at.class, who.class });
}

/// The "Strikes" block of an enemy weapon class's page (`class`): per enemy striking with
/// it a card of its row's fields (timings, effects, damage), copy and remove. The enemy's
/// page only assigns it (char_arsenal.zig).
pub fn strikesSection(app: *App, a: Allocator, class: []const u8) void {
    if (!gui.block(app, "strikes", tx.get(tx.sec_strikes), .{ .og = true })) return;
    defer gui.blockEnd();
    var k: u32 = 0;
    for (app.catalog.entries.items) |x| {
        if (x.kind != .enemy) continue;
        const f = @import("entries.zig").fileOf(app, x) orelse continue;
        const who = @import("entries.zig").enemyWho(app, x, app.store.text(f));
        for (attacksOf(app, a, x, who)) |at| if (std.ascii.eqlIgnoreCase(at.class, class)) {
            strikeCard(app, a, x, who, at, k);
            k += 1;
        };
    }
    if (k == 0) gui.note(tx.get(tx.atk_nobody));
    gui.note(tx.get(tx.attacks_note));
}

/// Enemy `who`'s (entry `x`) attack `at` as a card: its row's fields, copy and remove.
fn strikeCard(app: *App, a: Allocator, x: Entry, who: rules.Who, at: Attack, k: u32) void {
    const name = if (x.title.len > 0) x.title else x.id;
    const row = attackRow(who, at) orelse {
        _ = gui.block(app, null, name, .{ .inner = true });
        gui.note(tx.get(tx.attacks_hero_table));
        return gui.blockEnd();
    };
    const own = !rules_rows.isBuiltin(rules.MonsterAttack, "monster_attacks", row);
    _ = gui.block(app, null, tx.alloc(a, tx.attack_card, .{ name, row.anim }), .{ .inner = true });
    defer gui.blockEnd();
    gui.note(tx.get(if (at.given) tx.attack_given else if (own) tx.attack_own else tx.attack_game));
    const key = std.fmt.allocPrint(a, "atk{d}", .{k}) catch "atk";
    const ctx: AttackCtx = .{ .who = who, .at = at };
    gui.subhead(tx.get(tx.sec_timing));
    animRow(app, a, x, row.anim, std.fmt.allocPrint(a, "{s}_anim", .{key}) catch "atk_anim", ctx);
    fieldRows(app, a, rules.MonsterAttack, row, timing_fields, key, ctx, applyAttack);
    gui.subhead(tx.get(tx.sec_effects));
    fieldRows(app, a, rules.MonsterAttack, row, effect_fields, key, ctx, applyAttack);
    gui.fieldRow("");
    if (gui.check(app, clay.idi("atk_gas", k), row.gas, tx.get(tx.af_gas))) setAttack(app, who, at, "gas", if (row.gas) "0" else "1") catch |err| app.failed(err);
    clay.close();
    // Its saws (`special`): the page's Effects block, as its first enemy strikes.
    gui.subhead(tx.get(tx.sec_damage));
    fieldRows(app, a, rules.MonsterAttack, row, damage_fields, key, ctx, applyAttack);
    const labels = [_][]const u8{ tx.get(tx.attack_copy), tx.get(tx.attack_remove) };
    if (gui.footer(app, key, labels[0..if (own or at.given) 2 else 1], null)) |b| switch (b) {
        0 => _ = copyAttack(app, who, at) catch |err| app.failed(err),
        else => removeAttack(app, who, at) catch |err| app.failed(err),
    };
}

/// The attack's animation slot, picked from those enemy `x`'s look registers (the one in
/// the row kept when the look lacks it).
fn animRow(app: *App, a: Allocator, x: Entry, cur: []const u8, id: []const u8, ctx: AttackCtx) void {
    gui.fieldRow(tx.get(tx.af_anim));
    const open = picker.field(app, clay.id(id), cur, false);
    clay.close();
    if (!open) return;
    const ents = @import("entries.zig");
    var slots: std.ArrayList([]const u8) = .empty;
    slots.append(a, cur) catch {};
    if (ents.fileOf(app, x)) |f| if (@import("look_pages.zig").lookFile(app, x, app.store.text(f))) |look| for (preview.anims(a, app.store.text(look))) |an| {
        const seen = for (slots.items) |s| {
            if (std.mem.eql(u8, s, an.slot)) break true;
        } else false;
        if (!seen) slots.append(a, an.slot) catch {};
    };
    const rows = picker.names(a, slots.items);
    rows[0].selected = true;
    if (picker.listKey(app, a, rows)) |t| applyAttack(ctx, app, "anim", t) catch |err| rules_rows.failed(app, "anim", err);
}

/// The enemy weapon classes (`classes\wp_*.ss`) as rows (each its class, damage).
pub fn weaponClassRows(app: *App, a: Allocator) []picker.Opt {
    var out: std.ArrayList(picker.Opt) = .empty;
    for (@import("entry_weapons.zig").weaponClasses(app, a)) |entry| {
        const f = app.store.file(common_archive, entry) catch continue;
        const t = app.store.text(f);
        const name = rules.stem(app.store.files.items[f].entry);
        out.append(a, .{ .key = name, .label = name, .note = tx.alloc(a, tx.wp_option, .{ @import("item_page.zig").classLabel(a, model.get(t, "class")), model.get(t, "max_damage") orelse 0 }) }) catch {};
    }
    return out.items;
}

/// The attack shown struck in the model pane (`app.enemy_strike`): its animation slot
/// and its effects on its countdown (preview_fx.zig).
pub fn strikeShown(app: *App, a: Allocator, e: Entry, who: rules.Who) ?Struck {
    const k = app.enemy_strike orelse return null;
    if (!app.ogLayout()) return null;
    const list = attacksOf(app, a, e, who);
    if (k >= list.len) return null;
    return strikeOf(app.gpa, who, list[k]);
}

/// An enemy's attack struck: its animation slot, its effects, its row's own strike
/// (`special`: the spins).
const Struck = struct { slot: []const u8, held: preview.Held, special: i32 };

/// Attack `at` of the enemy `who` as the preview strikes it; null: it strikes by the hero table.
pub fn strikeOf(gpa: Allocator, who: rules.Who, at: Attack) ?Struck {
    const row = attackRow(who, at) orelse return null;
    const fx_ = @import("preview_fx.zig");
    const wait = row.hit_delay.ticks();
    const s = fx_.strikeOf(gpa, .{ .who = who, .weapon = .{ .id = at.id, .class = at.class } }, og.combat.anim.hitFrame(wait), if (row.flash_delay) |p| og.combat.anim.hitFrame(p.ticks()) else null);
    return .{ .slot = row.anim, .held = .{ .mesh = "", .link = "", .strike = s }, .special = og.core.entity.refId(row.strike, row.strike_class) };
}

/// The first enemy (in the catalog) striking with weapon class `class` (an attack's page:
/// its preview): its entry and the strike.
pub fn struckBy(app: *App, a: Allocator, class: []const u8) ?struct { enemy: usize, struck: Struck } {
    for (app.catalog.entries.items, 0..) |x, i| {
        if (x.kind != .enemy) continue;
        const f = @import("entries.zig").fileOf(app, x) orelse continue;
        const who = @import("entries.zig").enemyWho(app, x, app.store.text(f));
        for (attacksOf(app, a, x, who)) |at| if (std.ascii.eqlIgnoreCase(at.class, class)) {
            return .{ .enemy = i, .struck = strikeOf(app.gpa, who, at) orelse continue };
        };
    }
    return null;
}

// ---------------------------------------------------------------- AI profile (chosen; edited on the AI profiles page)

/// A profile row's name: its fighter (class or classic_id), else its classType ("every other
/// class" for 0).
pub fn profileName(a: Allocator, r: rules.AiProfile) []const u8 {
    if (r.fighter_class.len > 0) return r.fighter_class;
    if (r.fighter != 0) return std.fmt.allocPrint(a, "classic_id {d}", .{r.fighter}) catch "";
    // An OpenGorky row's class by name; a Classic one's number with the exe's name.
    if (r.class_name.len > 0) return r.class_name;
    if (r.class != 0) return if (rules.fighterClassName(r.class)) |n| std.fmt.allocPrint(a, "classType {d} · {s}", .{ r.class, n }) catch "" else std.fmt.allocPrint(a, "classType {d}", .{r.class}) catch "";
    return tx.get(tx.ai_other_classes);
}

/// A profile row as a list shows it: its name and eval ("classType 9 · a").
fn profileLabel(a: Allocator, r: rules.AiProfile) []const u8 {
    if (r.profile.len > 0) return std.fmt.allocPrint(a, "{s} · {s}", .{ profileName(a, r), r.profile }) catch "";
    return std.fmt.allocPrint(a, "{s} · {s}", .{ profileName(a, r), r.scoring orelse "—" }) catch "";
}

/// Index in the rules in force of the enemy's profile row: its own, else its classType's.
pub fn profileOf(who: rules.Who, class: i32) ?usize {
    const rs = rules.aiProfileRows(who, class);
    const p = rs.own orelse rs.base orelse return null;
    return (@intFromPtr(p) - @intFromPtr(rules.active.ai_profiles.ptr)) / @sizeOf(rules.AiProfile);
}

/// Row `k` in force made the enemy's profile: its classType's own row chosen drops the
/// enemy's row; another one is copied as its own row (by its class; one undo step).
pub fn setProfile(app: *App, who: rules.Who, class: i32, k: usize) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const list = rules.active.ai_profiles;
    if (k >= list.len) return error.NoSuchRow;
    const rs = rules.aiProfileRows(who, class);
    const want = &list[k];
    if (rs.own == want) return;
    if (want == rs.base) {
        if (!try rules_rows.drop(app, rules.AiProfile, rs.own.?.*)) return error.NoOwnRow;
    } else {
        const key = rules_rows.ownKey(app, rules.AiProfile, "fighter", if (rs.own) |o| o.* else .{}, who);
        var r = want.*;
        r.fighter = key.fighter;
        r.fighter_class = key.fighter_class;
        r.class = key.class;
        r.note = "";
        try rules_rows.put(app, rules.AiProfile, r);
    }
    app.setStatus(tx.st_ai_profile, .{ who.class, profileName(app.frame.allocator(), list[k]) });
}

/// The enemy's AI profile: chosen from the rows in force (OpenGorky; Classic: shown), and
/// opened on the AI profiles page.
pub fn aiChoice(app: *App, a: Allocator, who: rules.Who, class: i32) void {
    const cur = profileOf(who, class);
    const name = if (cur) |k| profileLabel(a, rules.active.ai_profiles[k]) else "—";
    const own = if (cur) |k| rules.aiProfileRows(who, class).own == &rules.active.ai_profiles[k] else false;
    const label = if (own) tx.alloc(a, tx.ai_own, .{name}) else name;
    gui.fieldRow(tx.get(tx.ai_pick));
    if (app.ogLayout()) {
        if (picker.field(app, clay.idi("choice", 9), label, false)) {
            const ps = rules.active.ai_profiles;
            const rows = a.alloc(picker.Opt, ps.len) catch return clay.close();
            for (ps, rows, 0..) |r, *o, k| o.* = .{ .label = profileLabel(a, r), .selected = cur == k };
            if (picker.list(app, a, rows)) |k| setProfile(app, who, class, k) catch |err| app.failed(err);
        }
    } else {
        gui.txtWrap(label, .body, theme.text, font_mod.regular);
        gui.spacer();
    }
    if (cur) |k| if (gui.goButton(app, clay.idi("ai_goto", 0))) {
        @import("doctabs.zig").show(app, .ai_profiles, std.fmt.allocPrint(a, "{d}", .{k}) catch "");
    };
    clay.close();
    gui.fieldNote(tx.get(tx.ai_pick_note), theme.dim);
}

// ---------------------------------------------------------------- a fighter's own strike (FighterStrike)

const Spin = og.core.behaviour.Spin;

/// Strike `special`'s spins in force.
fn spinsOf(special: i32) []const Spin {
    return if (og.core.modules.fighterStrike(special)) |s| s.spins else &.{};
}

/// Spin `i` of strike `special`: `field` link (a link point of the model), at (its tick as
/// the rules write it: `30`, `adjust("…", 30) + 5`) or frame (the strike animation's
/// frame it fires on, spinAt) made `text`; `add`: a new one on link point `text` (`LINK@FRAME`:
/// on that frame, else tick 0); `remove` (the last of a special the project added: its
/// row dropped). The strike's row written whole (one undo step).
pub fn setSpin(app: *App, special: i32, i: usize, field: []const u8, text: []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const a = app.frame.allocator();
    const cur = spinsOf(special);
    const eq = std.mem.eql;
    const t = std.mem.trim(u8, text, " ");
    const ss: []const Spin = if (eq(u8, field, "add")) blk: {
        const k = std.mem.lastIndexOfScalar(u8, t, '@');
        const at: rules.rows.Num = if (k) |x| spinAt(.{}, try std.fmt.parseInt(u32, t[x + 1 ..], 10)) else .{};
        break :blk try std.mem.concat(a, Spin, &.{ cur, &.{.{ .link = t[0 .. k orelse t.len], .at = at }} });
    } else blk: {
        if (i >= cur.len) return error.NoSuchSpin;
        if (eq(u8, field, "remove")) break :blk try std.mem.concat(a, Spin, &.{ cur[0..i], cur[i + 1 ..] });
        const out = try a.dupe(Spin, cur);
        if (eq(u8, field, "link")) out[i].link = t else if (eq(u8, field, "at")) {
            out[i].at = try codec.readText(rules.rows.Num, a, t, &app.rule_why);
        } else if (eq(u8, field, "frame")) {
            out[i].at = spinAt(cur[i].at, try std.fmt.parseInt(u32, t, 10));
        } else return error.NoSuchField;
        break :blk out;
    };
    for (ss) |sp| if (sp.link.len == 0) return error.NoLinkPoint;
    // The row's own key (an OpenGorky row names the fighter by archetype: a new one too).
    const old = og.core.modules.fighterStrike(special);
    const cls = if (old) |r| r.special_class else og.core.entity.classOf(special) orelse "";
    const key: og.core.behaviour.Strike = .{ .special = if (old) |r| r.special else if (cls.len > 0) 0 else special, .special_class = cls, .spins = ss };
    // The last one gone: a project's special's row dropped whole; the exe's kept empty
    // (dropped, the exe's saws would come back).
    if (ss.len == 0 and !rules_rows.builtinKey(og.core.behaviour.Strike, "strikes", key)) {
        _ = try rules_rows.drop(app, og.core.behaviour.Strike, key);
        return app.setStatus(tx.st_rules_row, .{og.core.behaviour.Strike.call});
    }
    try rules_rows.put(app, og.core.behaviour.Strike, key);
    app.setStatus(tx.st_rule_set, .{ "spins", og.core.behaviour.Strike.call });
}

/// The strike animation's frame (from its first) a spin at tick `at` fires on: tick at + 1
/// counted from the animation's start (combat/attack.zig), as the hit's (anim.hitFrame).
pub fn spinFrame(at: rules.rows.Num) u32 {
    return og.combat.anim.hitFrame(@intCast(@max(0, at.int())));
}

/// Tick `old` moved to fire on `frame`: its constant changed, an adjust value it reads
/// kept (`adjust("attack_headnail_delay1", 30) + 5` stays one); on that frame already: as it is.
fn spinAt(old: rules.rows.Num, frame: u32) rules.rows.Num {
    if (spinFrame(old) == frame) return old;
    var out = old;
    const tick: i32 = @intCast(frame + og.actor.Actor.blend_ticks - 1);
    out.c += tick - old.int();
    return out;
}

test spinAt {
    const headnail = rules.rows.Num.adj("attack_headnail_delay1", 30);
    // Tick 30 + 1 is frame 21 of the strike (10 blending ticks on frame 0).
    try std.testing.expectEqual(@as(u32, 21), spinFrame(headnail));
    const moved = spinAt(headnail, 25);
    try std.testing.expectEqual(@as(u32, 25), spinFrame(moved));
    try std.testing.expectEqual(@as(i32, 4), moved.c);
    try std.testing.expectEqualStrings("attack_headnail_delay1", moved.a.?.name);
    try std.testing.expectEqual(@as(u32, 0), spinFrame(spinAt(.{ .c = 40 }, 0)));
    try std.testing.expectEqual(@as(i32, 7), spinAt(.{ .c = 7 }, 0).c);
}

/// The spins of strike `special` on its animation's timeline.
pub const SpinLane = struct { special: i32, spins: []const Spin };

/// An enemy's own strike: its MonsterAttack `special` and animation slot.
const OwnStrike = struct { special: i32, slot: []const u8 };

/// The own strikes of enemy `e` (`text` its file).
pub fn ownStrikes(app: *App, a: Allocator, e: Entry, text: []const u8) []const OwnStrike {
    var out: std.ArrayList(OwnStrike) = .empty;
    const who = @import("entries.zig").enemyWho(app, e, text);
    for (attacksOf(app, a, e, who)) |at| if (attackRow(who, at)) |r| {
        const special = og.core.entity.refId(r.strike, r.strike_class);
        if (special != 0) out.append(a, .{ .special = special, .slot = r.anim }) catch {};
    };
    return out.items;
}

/// Model `mesh`'s link points (`gfx_3d\<mesh>.msh` hold modes), in `a`.
pub fn linkPoints(app: *App, a: Allocator, mesh: ?[]const u8) []const []const u8 {
    var eb: [160]u8 = undefined;
    const f = app.store.file(common_archive, std.fmt.bufPrint(&eb, "gfx_3d\\{s}.msh", .{mesh orelse return &.{}}) catch return &.{}) catch return &.{};
    var m = og.formats.mesh.parse(app.gpa, app.store.text(f)) catch return &.{};
    defer m.deinit();
    const out = a.alloc([]const u8, m.hold_modes.len) catch return &.{};
    for (m.hold_modes, out) |h, *o| o.* = a.dupe(u8, h.name) catch "";
    return out;
}

/// The spins on animation `anim_file` of look script `look` (`act` its text): the own
/// strikes of the enemies with this look that play it, each special once.
pub fn spinLanes(app: *App, a: Allocator, look: usize, act: []const u8, anim_file: []const u8) []const SpinLane {
    var out: std.ArrayList(SpinLane) = .empty;
    const list = preview.anims(a, act);
    for (app.catalog.entries.items) |e| {
        if (e.kind != .enemy) continue;
        const f = @import("entries.zig").fileOf(app, e) orelse continue;
        const text = app.store.text(f);
        if (@import("look_pages.zig").lookFile(app, e, text) != look) continue;
        for (ownStrikes(app, a, e, text)) |st| {
            const plays = for (list) |an| {
                if (std.mem.eql(u8, an.slot, st.slot)) break std.ascii.eqlIgnoreCase(an.file, anim_file);
            } else false;
            const seen = for (out.items) |l| {
                if (l.special == st.special) break true;
            } else false;
            if (plays and !seen) out.append(a, .{ .special = st.special, .spins = spinsOf(st.special) }) catch {};
        }
    }
    return out.items;
}

/// The "Spins" of an attack's own strike `special` (enemy `enemy`'s, in slot `slot`): each
/// saw's link point and frame, read only; › edits them on the timeline of the enemy's
/// animations page.
pub fn spinSummary(app: *App, a: Allocator, special: i32, enemy: usize, slot: []const u8) void {
    gui.subhead(tx.alloc(a, tx.spin_title, .{special}));
    const ss = spinsOf(special);
    for (ss, 0..) |sp, i| gui.propRow(tx.alloc(a, tx.spin_n, .{i + 1}), tx.alloc(a, tx.spin_on, .{ sp.link, spinFrame(sp.at) }));
    if (ss.len == 0) gui.fieldNote(tx.get(tx.spin_none), theme.dim);
    const e = app.catalog.entries.items[enemy];
    const f = @import("entries.zig").fileOf(app, e) orelse return;
    const look = @import("look_pages.zig").lookFile(app, e, app.store.text(f)) orelse return;
    gui.fieldRow(tx.get(tx.spin_edit));
    gui.spacer();
    if (gui.goButton(app, clay.id("spin_go"))) {
        // On the strike's animation.
        for (preview.anims(a, app.store.text(look))) |an| if (std.mem.eql(u8, an.slot, slot)) app.anim_name.set(an.file);
        @import("doctabs.zig").show(app, .anims, @import("look_pages.zig").scriptKey(app, a, look));
    }
    clay.close();
    gui.fieldNote(tx.get(tx.spin_note), theme.dim);
}

// ---------------------------------------------------------------- weapon effects

const Stage = og.core.effect.Stage;

/// Game weapon classic_ids with an effect of stage `s` in force (the project's rules\fx.ss
/// WeaponFx rows included).
fn stageIds(a: Allocator, s: Stage) []const i32 {
    return og.core.effect.ids(a, og.core.modules.tables().weapon_fx, s) catch &.{};
}

/// A weapon's effect fields (Classic's FxAs row on the weapon): all of
/// a game weapon's, each stage's alone (−1: none), the hit's sound; battle/generic.zig fxOf.
pub const fx_fields = [_][]const u8{ "effects_from", "flash_from", "launch_from", "hit_from", "hit_sound" };

/// Field `field` (fx_fields) of weapon `class`'s block made `text` (the scripted edits,
/// fxdesc.newRecord).
pub fn setFx(app: *App, class: []const u8, field: []const u8, text: []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    try setFxField(app, entry_rules.weaponFile(app, class) orelse return error.NoEntry, field, text);
    app.setStatus(tx.st_rule_set, .{ field, class });
}

/// Field `field` of weapon block file `file` made `text`: "0" or "" takes it out (its own
/// effects, the game's sound); a classic_id that one weapon archetype has as its reference
/// (`~w"weapons::rocket_launcher"`), else the number; the sound a string.
fn setFxField(app: *App, file: usize, field: []const u8, text: []const u8) !void {
    for (fx_fields) |f| {
        if (std.mem.eql(u8, f, field)) break;
    } else return error.NoSuchField;
    const mo = model.model_og;
    if (text.len == 0 or std.mem.eql(u8, text, "0")) return mo.unset(app, file, &.{field});
    const a = app.frame.allocator();
    if (std.mem.eql(u8, field, "hit_sound")) return mo.set(app, file, &.{field}, try std.fmt.allocPrint(a, "\"{s}\"", .{text}));
    // A weapon archetype by its path (`weapons::rocket_launcher`).
    if (std.mem.indexOf(u8, text, "::") != null) return mo.set(app, file, &.{field}, try std.fmt.allocPrint(a, "~w\"{s}\"", .{text}));
    const id = parsed(text);
    var path: ?[]const u8 = null;
    if (id > 0) for (app.catalog.entries.items) |x| if (x.kind == .weapon and x.name_id == id and std.mem.indexOf(u8, x.class, "::") != null) {
        if (path != null) {
            path = null;
            break;
        }
        path = x.class;
    };
    return mo.set(app, file, &.{field}, if (path) |p| try std.fmt.allocPrint(a, "~w\"{s}\"", .{p}) else try std.fmt.allocPrint(a, "{d}", .{id}));
}

/// Field `name` of block file `file` as the pickers take it: a number (a weapon archetype's
/// classic_id), a string's text; "" none.
fn fxText(app: *App, a: Allocator, file: usize, name: []const u8) []const u8 {
    const x = model.field(app, file, name).og_expr orelse return "";
    if (og.core.schema.int(x)) |n| return std.fmt.allocPrint(a, "{d}", .{n}) catch "";
    const t = og.core.schema.text(x) orelse return "";
    if (x.sigil != .weapon) return t;
    // A weapon archetype: its classic_id (the catalog's; the pickers' keys are numbers).
    for (app.catalog.entries.items) |e| if (e.kind == .weapon and std.ascii.eqlIgnoreCase(e.class, t)) if (e.name_id) |n| return std.fmt.allocPrint(a, "{d}", .{n}) catch "";
    return t;
}

/// The OpenGorky weapon page's Effects block: block file `file`'s effect fields (fx_fields),
/// each stage picked from the game weapons with such an effect, the hit's sound; then the
/// class's WeaponSound row (entry `idx`). Classic: none (its FxAs rows are the rules pages').
pub fn effectsRows(app: *App, a: Allocator, file: usize, idx: usize) void {
    if (!app.ogLayout()) return;
    const rows = .{ .{ tx.af_fx, gameWeapon(null, false) }, .{ tx.af_flash, gameWeapon(.flash, true) }, .{ tx.af_launch, gameWeapon(.launch, true) }, .{ tx.af_hit, gameWeapon(.hit, true) }, .{ tx.af_sound, sound_choice } };
    inline for (fx_fields, rows, 0..) |name, r, k| {
        gui.fieldRow(tx.get(r[0]));
        const cur = fxText(app, a, file, name);
        const open = picker.field(app, clay.idi("fx_stage", k), r[1].label(app, a, cur), false);
        clay.close();
        if (open) if (picker.listKey(app, a, r[1].rows(app, a, cur))) |t| setFxField(app, file, name, t) catch |err| rules_rows.failed(app, name, err);
    }
    @import("entry_tables.zig").soundRow(app, idx, @import("entry_tables.zig").whoOf(app, idx));
    if (fxText(app, a, file, "hit_sound").len > 0) gui.fieldNote(tx.get(tx.ws_wins), theme.warn);
    gui.note(tx.get(tx.fx_note));
}

/// "98 · Rifle", "as the weapon" (0), "none" (-1).
fn stageLabel(app: *App, a: Allocator, v: i32) []const u8 {
    if (v == 0) return tx.get(tx.fx_same);
    if (v < 0) return tx.get(tx.fx_none);
    const name = @import("texts.zig").get(app, a, .strings, v) orelse "";
    // OpenGorky: the weapon by its name and path (its number the reader's); a number only
    // where no block has it (a built-in effect).
    if (app.ogLayout()) for (app.catalog.entries.items) |x| if (x.kind == .weapon and x.name_id == v) {
        return std.fmt.allocPrint(a, "{s} · {s}", .{ if (name.len > 0) name else x.id, x.class }) catch "";
    };
    return std.fmt.allocPrint(a, "{d} · {s}", .{ v, name }) catch "";
}

// ---------------------------------------------------------------- hero party rules

fn applyHero(who: rules.Who, app: *App, field: []const u8, text: []const u8) !void {
    try setHero(app, who, field, text);
}

/// `party_max` (Value), else a field of the hero's own IdleChatter row by class.
pub fn setHero(app: *App, who: rules.Who, field: []const u8, text: []const u8) !void {
    if (std.mem.eql(u8, field, "party_max")) {
        // What the port holds (its party buffers; state/world.zig party), not clamped there silently.
        const n = std.fmt.parseInt(i32, std.mem.trim(u8, text, " "), 10) catch return error.BadNumber;
        if (n < World.party_min or n > World.party_cap) return error.PartySize3To12;
        try rules_rows.putField(app, rules.Value, .{ .name = .party_max, .value = rules.value(.party_max) }, "value", text);
    } else {
        const cur: rules.IdleChatter = if (rules.idleChatter(who)) |r| r.* else .{ .hero = 0, .dialog = "" };
        const base = rules_rows.ownKey(app, rules.IdleChatter, "hero", cur, who);
        try rules_rows.putField(app, rules.IdleChatter, base, field, text);
    }
    app.setStatus(tx.st_rule_set, .{ field, who.class });
}

/// The "Party" block of a hero page: the party size and the hero's idle line.
pub fn heroSection(app: *App, a: Allocator, who: rules.Who) void {
    const og_project = app.ogLayout();
    const sum = if (og_project) tx.alloc(a, tx.sum_party, .{rules.value(.party_max)}) else "";
    if (!gui.block(app, "party", tx.get(tx.sec_party), .{ .og = true, .summary = sum })) return;
    defer gui.blockEnd();
    gui.note(tx.get(tx.party_rows));
    const v: rules.Value = .{ .name = .party_max, .value = rules.value(.party_max) };
    fieldRows(app, a, rules.Value, v, .{.{ "value", tx.pr_max }}, "party_max", who, struct {
        fn f(w: rules.Who, ap: *App, _: []const u8, t: []const u8) anyerror!void {
            try setHero(ap, w, "party_max", t);
        }
    }.f);
    const ic: rules.IdleChatter = if (rules.idleChatter(who)) |r| r.* else .{ .hero = 0, .dialog = "" };
    fieldRows(app, a, rules.IdleChatter, ic, .{ .{ "dialog", tx.pr_dialog }, .{ "anim", tx.pr_anim } }, "idle", who, applyHero);
    gui.note(tx.get(tx.party_note));
}

// ---------------------------------------------------------------- hero bonuses

/// The hero's own HealBonus row (by class) with `field` = `text`.
pub fn setBonus(app: *App, who: rules.Who, field: []const u8, text: []const u8) !void {
    const base = rules_rows.ownKey(app, rules.HealBonus, "healer", rules.heroBonus(who), who);
    try rules_rows.putField(app, rules.HealBonus, base, field, text);
    app.setStatus(tx.st_rule_set, .{ field, who.class });
}

/// The "Character bonuses" block of a hero page: its heal bonus (HealBonus; not 0: the
/// stats window's line), hit chance, damage and walk range bonuses. Classic: locked (the
/// exe's McFadden 15% by classic_id).
pub fn bonusSection(app: *App, a: Allocator, who: rules.Who) void {
    const og_project = app.ogLayout();
    const sum = if (og_project) tx.alloc(a, tx.sum_bonus, .{rules.healBonusPct(who)}) else "";
    if (!gui.block(app, "bonuses", tx.get(tx.sec_bonuses), .{ .og = true, .summary = sum })) return;
    defer gui.blockEnd();
    const row = rules.heroBonus(who);
    fieldRows(app, a, rules.HealBonus, row, .{ .{ "pct", tx.bn_heal }, .{ "hit", tx.bn_hit }, .{ "damage", tx.bn_damage }, .{ "walk", tx.bn_walk } }, "bonus", who, struct {
        fn f(w: rules.Who, ap: *App, field: []const u8, t: []const u8) anyerror!void {
            try setBonus(ap, w, field, t);
        }
    }.f);
    gui.note(tx.get(tx.bonus_note));
}

test "entry_attacks: every damage kind of the rules has its label (the picker's words)" {
    inline for (@typeInfo(rules.rows.DamageKind).@"enum".field_values) |v| if (v != 0) {
        try std.testing.expect(!std.mem.eql(u8, @import("item_page.zig").damageLabel(v), "?"));
    };
}

//! The exe's tables by classic_id made editable on the entity pages (OpenGorky; og.rules):
//! a weapon's hero strikes (HeroAttack), its class's properties (WeaponClass), its
//! battle code flags (WeaponFlags), skills window icon (SkillIcon) and hit sound
//! (WeaponSound); an enemy's kill icon (KillIcon) and armour (Resist); a hero's slower
//! strikes (WdelayHero) and weapons it can't take (HiddenWeapons); a medicine's effect
//! (Medicine). Each edit writes one row (rules_rows: one undo step), keyed as
//! rules_rows.ownKey keys it. Classic: the blocks locked (gui.block og).

const std = @import("std");
const Allocator = std.mem.Allocator;
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const model = @import("model.zig");
const entry_rules = @import("entry_rules.zig");
const rules_rows = @import("rules_rows.zig");
const rulesapi = @import("rulesapi.zig");
const preview = @import("preview.zig");
const picker = @import("picker.zig");
const og = @import("opengorky");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const rules = og.rules;

// ---------------------------------------------------------------- shared

/// The rules reference's description of `call`'s field (en/ru).
fn doc(comptime call: []const u8, comptime field: []const u8) []const u8 {
    const c = rulesapi.find(call) orelse return "";
    return tx.get((rulesapi.field(c, field) orelse return "").doc);
}

const choice = @import("entries.zig").choiceRow;

/// The rows of rules words `words` (their doc after each).
fn wordRows(a: Allocator, words: anytype) []picker.Opt {
    const out = a.alloc(picker.Opt, words.len) catch return &.{};
    for (words, out) |wd, *o| o.* = .{ .key = wd.name, .label = wd.name, .note = tx.get(wd.doc) };
    return out;
}

/// The rows of the heroes (their class the key), `anyone` first when given.
fn heroOpts(app: *App, a: Allocator, anyone: ?[]const u8) []picker.Opt {
    var out: std.ArrayList(picker.Opt) = .empty;
    if (anyone) |l| out.append(a, .{ .label = l }) catch {};
    for (heroes(app, a)) |hi| {
        const e = app.catalog.entries.items[hi];
        out.append(a, .{ .key = entry_rules.classOf(e), .label = if (e.title.len > 0) e.title else e.id }) catch {};
    }
    return out.items;
}

/// Ticks of `labels` two to a row (a long label cut at its cell); the one clicked.
fn ticks(app: *App, id: []const u8, labels: []const []const u8, on: []const bool) ?usize {
    var hit: ?usize = null;
    var i: usize = 0;
    while (i < labels.len) : (i += 2) {
        gui.row(lay.space.xs);
        for (i..@min(i + 2, labels.len)) |k| {
            clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(lay.height.small) }, .childAlignment = .{ .y = @import("ui").CLAY_ALIGN_Y_CENTER } }, .clip = .{ .horizontal = true } });
            if (gui.check(app, clay.idi(id, @intCast(k)), on[k], labels[k])) hit = k;
            clay.close();
        }
        clay.close();
    }
    return hit;
}

/// The identity of catalog entry `idx` its rules name: classic_id and (OpenGorky) class.
pub fn whoOf(app: *App, idx: usize) rules.Who {
    const entries = @import("entries.zig");
    const e = app.catalog.entries.items[idx];
    const file = entries.fileOf(app, e) orelse return .{ .id = e.name_id orelse 0 };
    // An OpenGorky project's block: its classic_id field, its class its path.
    if (e.class.len > 0) return .{ .id = if (model.ownNum(app, file, "classic_id")) |v| @intFromFloat(v) else og.core.entity.idOf(e.class) orelse e.name_id orelse 0, .class = e.class };
    const text = app.store.text(file);
    if (e.kind == .enemy or e.kind == .hero) return .{ .id = entries.enemyClassicId(app, text), .class = if (app.ogLayout()) entry_rules.classOf(e) else "" };
    return .{ .id = if (model.get(text, "classic_id")) |v| @intFromFloat(v) else e.name_id orelse 0, .class = if (app.ogLayout()) entry_rules.classOf(e) else "" };
}

// ---------------------------------------------------------------- hero strikes

/// The HeroAttack rows naming weapon `w` (each hero key's best), else the fallback row
/// (every other weapon's): what its cards show.
fn heroRows(a: Allocator, w: rules.Who) []rules.HeroAttack {
    var out: std.ArrayList(rules.HeroAttack) = .empty;
    var score: std.ArrayList(u2) = .empty;
    for (rules.active.hero_attacks) |r| {
        const m = rules.keyMatch(r, "weapon", w) orelse continue;
        const same = for (out.items, 0..) |x, k| {
            if (x.hero == r.hero and std.ascii.eqlIgnoreCase(x.hero_class, r.hero_class)) break k;
        } else null;
        if (same) |k| {
            if (m > score.items[k]) {
                out.items[k] = r;
                score.items[k] = m;
            }
        } else {
            out.append(a, r) catch return out.items;
            score.append(a, m) catch return out.items;
        }
    }
    if (out.items.len == 0) out.append(a, rules.heroAttack(w, .{ .id = -1 }).*) catch {};
    return out.items;
}

/// Row `r` of weapon `w` keyed for writing (its own, else a new one by its class).
fn ownStrike(app: *App, w: rules.Who, r: rules.HeroAttack) rules.HeroAttack {
    var x = r;
    x.note = "";
    return rules_rows.ownKey(app, rules.HeroAttack, "weapon", x, w);
}

/// Field `field` of weapon `w`'s strike row `r` made `text` (the row written whole).
fn setStrike(app: *App, w: rules.Who, r: rules.HeroAttack, field: []const u8, text: []const u8) !void {
    try rules_rows.putField(app, rules.HeroAttack, ownStrike(app, w, r), field, text);
    app.setStatus(tx.st_rule_set, .{ field, w.class });
}

/// Strike row `r` made hero `hero`'s (class; "" anyone): its own row re-keyed where it
/// stands, else a new row; `add`: a new row beside it.
fn strikeFor(app: *App, w: rules.Who, r: rules.HeroAttack, hero: []const u8, add: bool) !void {
    const at = ownStrike(app, w, r);
    var n = at;
    n.hero = 0;
    n.hero_class = hero;
    if (rules_rows.has(app, rules.HeroAttack, n)) return error.RowExists;
    if (!add and rules_rows.has(app, rules.HeroAttack, at)) try rules_rows.putAt(app, rules.HeroAttack, at, n) else try rules_rows.put(app, rules.HeroAttack, n);
    app.setStatus(tx.st_rule_set, .{ "hero", w.class });
}

/// Strike row `r` out of the rules files (the one under it in force again).
fn removeStrike(app: *App, w: rules.Who, r: rules.HeroAttack) !void {
    if (!try rules_rows.drop(app, rules.HeroAttack, ownStrike(app, w, r))) return error.NoOwnRow;
    app.setStatus(tx.st_attack_removed, .{ w.class, if (r.hero_class.len > 0) r.hero_class else "*" });
}

/// The heroes able to strike: catalog index, class, title.
fn heroes(app: *App, a: Allocator) []const usize {
    return @import("entry_model.zig").heroEntries(app, a);
}

/// Catalog index of the hero row `r` names (null: anyone or none known).
fn heroOf(app: *App, a: Allocator, r: rules.HeroAttack) ?usize {
    for (heroes(app, a)) |hi| {
        const e = app.catalog.entries.items[hi];
        if (r.hero_class.len > 0) {
            if (std.ascii.eqlIgnoreCase(r.hero_class, entry_rules.classOf(e))) return hi;
        } else if (r.hero != 0 and e.name_id == r.hero) return hi;
    }
    return null;
}

fn heroLabel(app: *App, a: Allocator, r: rules.HeroAttack) []const u8 {
    if (r.hero == 0 and r.hero_class.len == 0) return tx.get(tx.hs_anyone);
    const e = app.catalog.entries.items[heroOf(app, a, r) orelse return if (r.hero_class.len > 0) r.hero_class else std.fmt.allocPrint(a, "{d}", .{r.hero}) catch "?"];
    return if (e.title.len > 0) e.title else e.id;
}

/// The animation slots (stance 0) of hero `hi`, else of the hero shown striking.
fn heroAnims(app: *App, a: Allocator, hi: ?usize) []const []const u8 {
    const hs = heroes(app, a);
    if (hs.len == 0) return &.{};
    const shown = for (hs) |h| {
        if (h == app.attack_hero) break h;
    } else hs[0];
    const e = app.catalog.entries.items[hi orelse shown];
    const f = @import("entries.zig").fileOf(app, e) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (preview.anims(a, app.store.text(f))) |an| if (std.mem.indexOfScalar(u8, an.slot, '/') == null) out.append(a, an.slot) catch {};
    return out.items;
}

/// "the weapon's own `name` = v wins over this" when the weapon's script sets it (the
/// port's overlay, battle/attacks.zig: numbers above 0, after_delay any).
fn wins(a: Allocator, text: []const u8, comptime name: []const u8) void {
    const v: []const u8 = if (comptime std.mem.eql(u8, name, "attack_anim")) model.getStr(text, name) orelse return else blk: {
        const x = model.get(text, name) orelse return;
        if (x <= 0 and !std.mem.eql(u8, name, "after_delay")) return;
        break :blk std.fmt.allocPrint(a, "{d}", .{@as(i32, @intFromFloat(x))}) catch return;
    };
    gui.fieldNote(tx.alloc(a, tx.hs_wins, .{ name, v }), theme.warn);
}

/// The weapon script's own fields over hero strike `h` (OpenGorky: the battle's
/// overlayHero, battle/attacks.zig): attack_anim, hit_delay (drops extra), after_delay,
/// flash_delay; numbers 0 or less (but after_delay) keep the row's.
pub fn scriptOver(h: og.battle.attacks.HeroAttack, text: []const u8) og.battle.attacks.HeroAttack {
    var r = h;
    if (model.getStr(text, "attack_anim")) |s| if (s.len > 0) {
        r.anim = s;
    };
    if (model.get(text, "hit_delay")) |v| if (v >= 1) {
        r.wait = std.math.lossyCast(u32, v);
        r.extra = 0;
    };
    if (model.get(text, "after_delay")) |v| {
        r.after = std.math.lossyCast(u32, @max(0, v));
    }
    if (model.get(text, "flash_delay")) |v| if (v >= 1) {
        r.pre = std.math.lossyCast(u32, v);
    };
    return r;
}

test "a weapon script's strike fields over its HeroAttack row" {
    const t = std.testing;
    const row: og.battle.attacks.HeroAttack = .{ .anim = "attack_pistol", .wait = 20, .extra = 5, .after = 10, .pre = 3 };
    const kept = scriptOver(row, "hit_delay = 0;\r\nflash_delay = -1;\r\n");
    try t.expectEqual(@as(u32, 20), kept.wait);
    try t.expectEqual(@as(i32, 5), kept.extra);
    try t.expectEqual(@as(?u32, 3), kept.pre);
    const over = scriptOver(row, "attack_anim = \"attack_rifle\";\r\nhit_delay = 31;\r\nafter_delay = 0;\r\nflash_delay = 7;\r\n");
    try t.expectEqualStrings("attack_rifle", over.anim);
    try t.expectEqual(@as(u32, 31), over.wait);
    try t.expectEqual(@as(i32, 0), over.extra);
    try t.expectEqual(@as(u32, 0), over.after);
    try t.expectEqual(@as(?u32, 7), over.pre);
}

const StrikeCtx = struct { w: rules.Who, r: rules.HeroAttack };

fn applyStrike(c: StrikeCtx, app: *App, field: []const u8, text: []const u8) !void {
    try setStrike(app, c.w, c.r, field, text);
}

/// The "Hero strikes" block of a weapon page: a card per HeroAttack row of it (who
/// strikes, animation, timings), the weapon's own fields that win marked; a row for
/// one hero added, an own row removed. Classic: locked.
pub fn strikeSection(app: *App, a: Allocator, w: rules.Who, text: []const u8) void {
    if (!gui.block(app, "hero_strikes", tx.get(tx.sec_hero_strikes), .{ .og = true })) return;
    defer gui.blockEnd();
    const list = heroRows(a, w);
    const fallback = list.len == 1 and rules.keyMatch(list[0], "weapon", w) == null;
    const fieldRows = @import("entry_attacks.zig").fieldRows;
    for (list, 0..) |r, k| {
        const kk: u32 = @intCast(k);
        _ = gui.block(app, null, tx.alloc(a, tx.hs_card, .{ heroLabel(app, a, r), r.anim }), .{ .inner = true });
        const own = !fallback and rules_rows.has(app, rules.HeroAttack, ownStrike(app, w, r));
        gui.note(tx.get(if (fallback) tx.hs_default else if (own) tx.attack_own else tx.attack_game));
        const ctx: StrikeCtx = .{ .w = w, .r = r };
        if (choice(app, 100 + kk * 4, tx.get(tx.hs_who), heroLabel(app, a, r))) {
            const rows = heroOpts(app, a, tx.get(tx.hs_anyone));
            if (picker.list(app, a, rows)) |j| strikeFor(app, w, r, rows[j].key, false) catch |err| app.failed(err);
        }
        const hi = heroOf(app, a, r);
        if (choice(app, 101 + kk * 4, tx.get(tx.af_anim), r.anim)) {
            const rows = picker.names(a, heroAnims(app, a, hi));
            if (picker.list(app, a, rows)) |j| setStrike(app, w, r, "anim", rows[j].key) catch |err| app.failed(err);
        }
        wins(a, text, "attack_anim");
        const key = std.fmt.allocPrint(a, "hs{d}", .{k}) catch "hs";
        fieldRows(app, a, rules.HeroAttack, r, .{ .{ "wait", tx.af_wait }, .{ "extra", tx.hs_extra } }, key, ctx, applyStrike);
        wins(a, text, "hit_delay");
        gui.fieldNote(doc("HeroAttack", "extra"), theme.dim);
        fieldRows(app, a, rules.HeroAttack, r, .{.{ "after", tx.af_after }}, key, ctx, applyStrike);
        wins(a, text, "after_delay");
        fieldRows(app, a, rules.HeroAttack, r, .{.{ "pre", tx.af_pre }}, key, ctx, applyStrike);
        wins(a, text, "flash_delay");
        gui.fieldRow("");
        if (gui.check(app, clay.idi("hs_until", kk), r.until_end, tx.get(tx.hs_until))) setStrike(app, w, r, "until_end", if (r.until_end) "0" else "1") catch |err| app.failed(err);
        clay.close();
        if (r.until_end) if (choice(app, 102 + kk * 4, tx.get(tx.hs_then), if (r.then.len > 0) r.then else "—")) {
            const rows = picker.names(a, heroAnims(app, a, hi));
            if (picker.list(app, a, rows)) |j| setStrike(app, w, r, "then", rows[j].key) catch |err| app.failed(err);
        };
        if (own and gui.footer(app, key, &.{tx.get(tx.attack_remove)}, null) != null) removeStrike(app, w, r) catch |err| app.failed(err);
        gui.blockEnd();
    }
    if (choice(app, 90, tx.get(tx.hs_add), tx.get(tx.hs_add_pick))) {
        const rows = heroOpts(app, a, null);
        if (picker.list(app, a, rows)) |j| strikeFor(app, w, list[0], rows[j].key, true) catch |err| app.failed(err);
    }
    gui.note(tx.get(tx.hs_note));
}

// ---------------------------------------------------------------- weapon class, flags

/// Field `field` of class `class`'s WeaponClass row made `value` (written by its class number).
fn setClass(app: *App, class: i32, field: []const u8, value: []const u8) !void {
    var r = rules.weaponClass(class);
    r.note = "";
    if (std.mem.eql(u8, field, "effect")) {
        r.effect = if (std.mem.eql(u8, value, "none")) null else std.meta.stringToEnum(rules.Effect, value) orelse return error.BadEffect;
    } else if (std.mem.eql(u8, field, "kind")) {
        r.kind = std.meta.stringToEnum(rules.rows.WeaponKind, value) orelse return error.BadKind;
    } else if (std.mem.eql(u8, field, "recharge")) {
        r.recharge = @max(0, try std.fmt.parseInt(i32, value, 10));
    } else {
        const on = std.mem.eql(u8, value, "true");
        if (std.mem.eql(u8, field, "rolls_to_hit")) r.rolls_to_hit = on else if (std.mem.eql(u8, field, "ignites_soaked")) r.ignites_soaked = on else return error.NoSuchField;
    }
    try rules_rows.put(app, rules.WeaponClass, r);
    var b: [16]u8 = undefined;
    app.setStatus(tx.st_rule_set, .{ field, std.fmt.bufPrint(&b, "class {d}", .{class}) catch "" });
}

/// The weapons and enemy attacks of classType `class`, by name.
fn classMembers(app: *App, a: Allocator, class: i32) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (app.catalog.entries.items) |e| {
        if (e.kind != .weapon and e.kind != .attack) continue;
        const f = @import("entries.zig").fileOf(app, e) orelse continue;
        if (model.get(app.store.text(f), "class") != @as(f32, @floatFromInt(class))) continue;
        if (out.items.len > 0) out.appendSlice(a, ", ") catch {};
        out.appendSlice(a, if (e.title.len > 0) e.title else e.id) catch {};
    }
    return out.items;
}

/// A strike's class properties (WeaponClass of its `class`), in the Damage block:
/// recharge, the state a hit applies, its kind, rolls to hit, ignites soaked, and the weapons the
/// change reaches. Classic: none (the caller shows the exe's values).
pub fn classRows(app: *App, a: Allocator, text: []const u8) void {
    if (!app.ogLayout()) return;
    const class: i32 = @intFromFloat(model.get(text, "class") orelse 0);
    const r = rules.weaponClass(class);
    gui.subhead(tx.alloc(a, tx.wc_title, .{class}));
    const d = gui.stepper(app, a, "wc_recharge", std.fmt.allocPrint(a, "{s}: {d}", .{ tx.get(tx.f_recharge), r.recharge }) catch "", @floatFromInt(r.recharge), 1);
    if (d != 0) {
        var b: [16]u8 = undefined;
        setClass(app, class, "recharge", std.fmt.bufPrint(&b, "{d}", .{@max(0, r.recharge + @as(i32, @intFromFloat(d)))}) catch "0") catch |err| app.failed(err);
    }
    const words = (rulesapi.field(rulesapi.find("WeaponClass").?, "effect").?).words;
    if (choice(app, 80, tx.get(tx.c_effect), if (r.effect) |e| @tagName(e) else tx.get(tx.fx_none))) {
        var rows: std.ArrayList(picker.Opt) = .empty;
        rows.append(a, .{ .key = "none", .label = tx.get(tx.fx_none) }) catch {};
        for (wordRows(a, words)) |o| if (!std.mem.eql(u8, o.key, "defend")) rows.append(a, o) catch {};
        if (picker.list(app, a, rows.items)) |j| setClass(app, class, "effect", rows.items[j].key) catch |err| app.failed(err);
    }
    const kinds = (rulesapi.field(rulesapi.find("WeaponClass").?, "kind").?).words;
    if (choice(app, 81, tx.get(tx.wc_kind), @tagName(r.kind))) {
        if (picker.list(app, a, wordRows(a, kinds))) |j| setClass(app, class, "kind", kinds[j].name) catch |err| app.failed(err);
    }
    gui.fieldRow("");
    gui.stack(0);
    if (gui.check(app, clay.id("wc_rolls"), r.rolls_to_hit, tx.get(tx.wc_rolls))) setClass(app, class, "rolls_to_hit", if (r.rolls_to_hit) "false" else "true") catch |err| app.failed(err);
    if (gui.check(app, clay.id("wc_ignites"), r.ignites_soaked, tx.get(tx.wc_ignites))) setClass(app, class, "ignites_soaked", if (r.ignites_soaked) "false" else "true") catch |err| app.failed(err);
    clay.close();
    clay.close();
    gui.fieldNote(tx.alloc(a, tx.wc_shared, .{ class, classMembers(app, a, class) }), theme.warn);
}

const flag_names = [_][]const u8{ "no_counter", "shock", "sparks", "silent_frames" };

/// Flag `name` of weapon `w`'s WeaponFlags row flipped (by its class, else in place).
fn toggleFlag(app: *App, w: rules.Who, name: []const u8) !void {
    const cur = rules_rows.bestFor(rules.WeaponFlags, "weapon_flags", "weapon", w) orelse rules.WeaponFlags{ .weapon = 0 };
    try rules_rows.putOwn(app, rules.WeaponFlags, "weapon", cur, w, struct {
        fn f(r: *rules.WeaponFlags, n: []const u8) !void {
            inline for (flag_names) |fl| if (std.mem.eql(u8, fl, n)) {
                @field(r, fl) = !@field(r, fl);
                return;
            };
            return error.NoSuchField;
        }
    }.f, name);
}

/// The weapon's battle code flags (WeaponFlags), four ticks. Classic: none.
pub fn flagRows(app: *App, w: rules.Who) void {
    if (!app.ogLayout()) return;
    gui.subhead(tx.get(tx.wf_title));
    const r = rules_rows.bestFor(rules.WeaponFlags, "weapon_flags", "weapon", w) orelse rules.WeaponFlags{ .weapon = 0 };
    const on = [_]bool{ r.no_counter, r.shock, r.sparks, r.silent_frames };
    const labels = [_][]const u8{ tx.get(tx.wf_no_counter), tx.get(tx.wf_shock), tx.get(tx.wf_sparks), tx.get(tx.wf_silent) };
    if (ticks(app, "wf_tick", &labels, &on)) |k| toggleFlag(app, w, flag_names[k]) catch |err| app.failed(err);
    gui.note(tx.get(rulesapi.find("WeaponFlags").?.doc));
}

// ---------------------------------------------------------------- icons, sound

/// The skills window's icon of weapon `w` (SkillIcon): picked from the icons; none:
/// the weapon isn't listed there. Classic: none.
pub fn skillIconRow(app: *App, idx: usize, w: rules.Who) void {
    if (!app.ogLayout()) return;
    gui.fieldRow(tx.get(tx.c_skill_icon));
    const cur = rules.skillIcon(w);
    if (cur) |n| if (app.icon(n)) |t| clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lay.height.tab), .height = clay.fixed(lay.height.tab) } }, .image = .{ .imageData = t } });
    const open = picker.field(app, clay.id("skill_icon"), cur orelse "—", cur == null);
    clay.close();
    if (open) if (picker.listKey(app, app.frame.allocator(), @import("entries.zig").iconRows(app, app.frame.allocator()))) |v| picked(app, .skill_icon, idx, v) catch |err| app.failed(err);
    if (cur == null) gui.fieldNote(tx.get(tx.skill_none), theme.warn);
}

/// The kill icon of the after-battle report (KillIcon) of enemy `who`: picked.
pub fn killIconRow(app: *App, idx: usize, who: rules.Who) void {
    const cur = og.battle.report.iconOf(who);
    gui.fieldRow(tx.get(tx.c_report_icon));
    if (cur) |n| if (app.icon(n)) |t| clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lay.height.tab), .height = clay.fixed(lay.height.tab) } }, .image = .{ .imageData = t } });
    const open = picker.field(app, clay.id("kill_icon"), cur orelse "—", cur == null);
    // The icon's own page (sprite.dat: frames from and to PNG).
    if (cur) |n| if (gui.goButton(app, clay.id("kill_icon_go"))) @import("sprview.zig").open(app, n) catch |err| app.failed(err);
    clay.close();
    if (open) if (picker.listKey(app, app.frame.allocator(), @import("entries.zig").iconRows(app, app.frame.allocator()))) |v| picked(app, .kill_icon, idx, v) catch |err| app.failed(err);
    if (cur == null) gui.fieldNote(tx.get(tx.report_none), theme.warn);
}

/// The hit sound of weapon `w` (WeaponSound by its class): picked and played; the
/// weapon's `hit_sound` wins over it (entry_attacks.effectsRows notes it).
pub fn soundRow(app: *App, idx: usize, w: rules.Who) void {
    const cur = if (rules_rows.bestFor(rules.WeaponSound, "weapon_sounds", "weapon", w)) |r| r.sound else rules.weaponSound(rules.fxAs(w)) orelse "";
    gui.fieldRow(tx.get(tx.c_weapon_sound));
    const open = picker.field(app, clay.id("weapon_sound"), if (cur.len > 0) cur else "—", false);
    if (cur.len > 0 and gui.textButton(app, "weapon_sound_play", tx.get(tx.snd_play), theme.accent_hover)) app.player.play(app, cur);
    clay.close();
    if (open) {
        const a = app.frame.allocator();
        if (picker.listKey(app, a, picker.names(a, app.player.names(app, a)))) |v| picked(app, .weapon_sound, idx, v) catch |err| app.failed(err);
    }
}

/// The value picked for entry `idx`'s kill icon, skills window icon or hit sound.
fn picked(app: *App, what: enum { kill_icon, skill_icon, weapon_sound }, idx: usize, value: []const u8) !void {
    const w = whoOf(app, idx);
    // OpenGorky: the block's own field (its rows: rules_text.block_rows), not a rules row.
    if (app.ogLayout()) if (@import("entries.zig").fileOf(app, app.catalog.entries.items[idx])) |file| if (model.model_og.blockOf(app, app.frame.allocator(), file)) |b| if (b.names.len == 1) {
        if (what == .weapon_sound) app.player.play(app, value);
        const field = switch (what) {
            .kill_icon => "report_icon",
            .skill_icon => "skill_icon",
            .weapon_sound => "weapon_sound",
        };
        const esc = try std.mem.replaceOwned(u8, app.frame.allocator(), value, "\\", "\\\\");
        return model.model_og.set(app, file, &.{field}, try std.fmt.allocPrint(app.frame.allocator(), "\"{s}\"", .{esc}));
    };
    switch (what) {
        .kill_icon => try rules_rows.setOwn(app, rules.KillIcon, "fighter", rules_rows.bestFor(rules.KillIcon, "kill_icons", "fighter", w) orelse .{ .fighter = 0, .icon = "" }, w, "icon", value),
        .skill_icon => try rules_rows.setOwn(app, rules.SkillIcon, "weapon", rules_rows.bestFor(rules.SkillIcon, "skill_icons", "weapon", w) orelse .{ .weapon = 0, .icon = "" }, w, "icon", value),
        .weapon_sound => {
            app.player.play(app, value);
            try rules_rows.setOwn(app, rules.WeaponSound, "weapon", rules_rows.bestFor(rules.WeaponSound, "weapon_sounds", "weapon", w) orelse .{ .weapon = 0, .sound = "" }, w, "sound", value);
        },
    }
}

// ---------------------------------------------------------------- armour

/// Enemy `who`'s Resist armour made `armor` (-3 heavy … 0 none).
fn setArmor(app: *App, who: rules.Who, armor: i32) !void {
    if (armor < -3 or armor > 0) return error.Armor3To0;
    const cur = if (og.core.entity.enemyOf(who).resist) |e| e.* else rules.Resist{ .fighter = 0 };
    try rules_rows.putOwn(app, rules.Resist, "fighter", cur, who, struct {
        fn f(r: *rules.Resist, v: i32) !void {
            r.armor = v;
        }
    }.f, armor);
}

/// The armour class row of the resistances: picked from its four (OpenGorky), else read-only.
pub fn armorRow(app: *App, a: Allocator, who: rules.Who, editable: bool) void {
    const cur: i32 = if (og.core.entity.enemyOf(who).resist) |e| e.armor else 0;
    const names = [_]tx.Msg{ tx.r_armor_none, tx.r_armor_light, tx.r_armor_medium, tx.r_armor_heavy };
    const shown = std.fmt.allocPrint(a, "{d} · {s}", .{ cur, tx.get(names[@intCast(std.math.clamp(-cur, 0, 3))]) }) catch "";
    if (!editable) {
        gui.fieldRow(tx.get(tx.r_armor));
        gui.txt(shown, .body, theme.dim, font_mod.regular);
        return clay.close();
    }
    // A list, not a segmented row: four labels don't fit a narrow values column.
    if (!picker.row(app, clay.id("armor_class"), tx.get(tx.r_armor), tx.get(names[@intCast(std.math.clamp(-cur, 0, 3))]))) return;
    var rows: [names.len]picker.Opt = undefined;
    for (&rows, names, 0..) |*o, m, k| o.* = .{ .label = tx.get(m), .selected = -cur == k };
    const k = picker.list(app, a, &rows) orelse return;
    if (-@as(i32, @intCast(k)) != cur) setArmor(app, who, -@as(i32, @intCast(k))) catch |err| app.failed(err);
}

/// The armour choices of a script's `armor` (none, light, medium, heavy).
pub fn armorRows(a: Allocator, cur: ?f32) []picker.Opt {
    const out = a.alloc(picker.Opt, 4) catch return &.{};
    for ([_]f32{ -1, 0, 1, 2 }, out) |v, *o| o.* = .{ .key = std.fmt.allocPrint(a, "{d}", .{v}) catch "", .label = armorLabel(a, v), .selected = cur == v };
    return out;
}

/// The armour shown: "1 · medium: …"; a number past 0…2 is none (no reduction).
pub fn armorLabel(a: Allocator, v: ?f32) []const u8 {
    const n: i32 = @intFromFloat(@trunc(v orelse return "—"));
    return switch (n) {
        0 => tx.get(tx.c_armor_light),
        1 => tx.get(tx.c_armor_medium),
        2 => tx.get(tx.c_armor_heavy),
        else => tx.alloc(a, tx.c_armor_none, .{n}),
    };
}

test armorLabel {
    try std.testing.expectEqualStrings("—", armorLabel(std.testing.allocator, null));
    try std.testing.expectEqualStrings(tx.get(tx.c_armor_heavy), armorLabel(std.testing.allocator, 2));
    const none = armorLabel(std.testing.allocator, 5);
    defer std.testing.allocator.free(none);
    try std.testing.expect(std.mem.startsWith(u8, none, "5 · "));
}

// ---------------------------------------------------------------- hero rules

/// Hero `who`'s WdelayHero row: put by its class (on) or its row in force dropped (off;
/// a built-in row not in the rules files can't be).
fn setWdelay(app: *App, who: rules.Who, on: bool) !void {
    if (on) {
        if (rules.wdelayHero(who)) return;
        try rules_rows.put(app, rules.WdelayHero, rules_rows.ownKey(app, rules.WdelayHero, "hero", .{ .hero = 0 }, who));
    } else {
        var r = rules_rows.bestFor(rules.WdelayHero, "wdelay_heroes", "hero", who) orelse return;
        r.note = "";
        if (!try rules_rows.drop(app, rules.WdelayHero, r)) return error.NoOwnRow;
    }
    app.setStatus(tx.st_rule_set, .{ "WdelayHero", who.class });
}

/// Weapon classic_id `id` in or out of hero `who`'s HiddenWeapons row.
pub fn toggleHidden(app: *App, who: rules.Who, id: i32) !void {
    const cur = rules_rows.bestFor(rules.HiddenWeapons, "hidden_weapons", "hero", who) orelse rules.HiddenWeapons{ .hero = 0, .weapons = &.{} };
    try rules_rows.putOwn(app, rules.HiddenWeapons, "hero", cur, who, struct {
        fn f(r: *rules.HiddenWeapons, x: struct { Allocator, i32 }) !void {
            r.weapons = try toggled(x[0], r.weapons, x[1]);
        }
    }.f, .{ app.frame.allocator(), id });
}

/// `list` with `id` taken out, else added at its end.
fn toggled(a: Allocator, list: []const i32, id: i32) ![]const i32 {
    var out: std.ArrayList(i32) = .empty;
    var had = false;
    for (list) |x| if (x == id) {
        had = true;
    } else try out.append(a, x);
    if (!had) try out.append(a, id);
    return out.items;
}

test toggled {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, try toggled(a, &.{ 1, 2 }, 3));
    const taken = try toggled(a, &.{ 1, 2, 3 }, 2);
    try std.testing.expectEqualSlices(i32, &.{ 1, 3 }, taken);
}

/// The weapons with a classic_id (one per number): ids and labels.
fn weaponList(app: *App, a: Allocator, kind: @import("catalog.zig").Kind, item_type: ?f32) struct { ids: []i32, labels: [][]const u8 } {
    var ids: std.ArrayList(i32) = .empty;
    var labels: std.ArrayList([]const u8) = .empty;
    for (app.catalog.entries.items) |e| {
        const id = e.name_id orelse continue;
        if (e.kind != kind or id <= 0 or std.mem.indexOfScalar(i32, ids.items, id) != null) continue;
        if (item_type) |t| {
            const f = @import("entries.zig").fileOf(app, e) orelse continue;
            if (model.get(app.store.text(f), "kind") != t) continue;
        }
        ids.append(a, id) catch break;
        labels.append(a, std.fmt.allocPrint(a, "{s} · {d}", .{ if (e.title.len > 0) e.title else e.id, id }) catch e.id) catch break;
    }
    return .{ .ids = ids.items, .labels = labels.items };
}

/// The "Battle rules" block of a hero page: slower strikes (WdelayHero) and the weapons it
/// can't take in hand (HiddenWeapons). Classic: locked.
pub fn heroRules(app: *App, a: Allocator, who: rules.Who) void {
    if (!gui.block(app, "hero_rules", tx.get(tx.sec_hero_rules), .{ .og = true })) return;
    defer gui.blockEnd();
    const slow = rules.wdelayHero(who);
    if (gui.check(app, clay.id("hr_wdelay"), slow, tx.get(tx.hr_wdelay))) setWdelay(app, who, !slow) catch |err| app.failed(err);
    gui.note(doc("HeroAttack", "extra"));
    gui.subhead(tx.get(tx.hr_hidden));
    const hidden: []const i32 = if (rules.hiddenWeapons(who)) |r| r.weapons else &.{};
    const l = weaponList(app, a, .weapon, null);
    const on = a.alloc(bool, l.ids.len) catch return;
    for (on, l.ids) |*o, id| o.* = std.mem.indexOfScalar(i32, hidden, id) != null;
    if (ticks(app, "hr_hidden", l.labels, on)) |k| toggleHidden(app, who, l.ids[k]) catch |err| app.failed(err);
    gui.note(tx.get(tx.hr_note));
}

// ---------------------------------------------------------------- medicine

/// Item `who`'s Medicine row with `field` (`kind`: a word; `random`: a classic_id toggled).
fn setMedicine(app: *App, who: rules.Who, field: []const u8, value: []const u8) !void {
    var cur = rules.medicineOf(who);
    if (rules_rows.bestFor(rules.Medicine, "medicine", "item", who) == null) cur.item = 0;
    if (std.mem.eql(u8, field, "random")) {
        const id = try std.fmt.parseInt(i32, value, 10);
        return rules_rows.putOwn(app, rules.Medicine, "item", cur, who, struct {
            fn f(r: *rules.Medicine, x: struct { Allocator, i32 }) !void {
                r.random = try toggled(x[0], r.random, x[1]);
            }
        }.f, .{ app.frame.allocator(), id });
    }
    return rules_rows.setOwn(app, rules.Medicine, "item", cur, who, field, value);
}

/// The "Medicine" block of a medicine item (type 20): its effect and the items it may act
/// as at random. Classic: locked.
pub fn medicineSection(app: *App, a: Allocator, who: rules.Who) void {
    if (!gui.block(app, "medicine", tx.get(tx.sec_medicine), .{ .og = true })) return;
    defer gui.blockEnd();
    const r = rules.medicineOf(who);
    const words = (rulesapi.field(rulesapi.find("Medicine").?, "kind").?).words;
    if (choice(app, 70, tx.get(tx.med_kind), std.fmt.allocPrint(a, "{s} · {s}", .{ @tagName(r.kind), tx.get(words[@backingInt(r.kind)].doc) }) catch "")) {
        if (picker.list(app, a, wordRows(a, words))) |j| setMedicine(app, who, "kind", words[j].name) catch |err| app.failed(err);
    }
    gui.subhead(tx.get(tx.med_random));
    const l = weaponList(app, a, .item, 20);
    const on = a.alloc(bool, l.ids.len) catch return;
    for (on, l.ids) |*o, id| o.* = std.mem.indexOfScalar(i32, r.random, id) != null;
    if (ticks(app, "med_random", l.labels, on)) |k| {
        var b: [16]u8 = undefined;
        setMedicine(app, who, "random", std.fmt.bufPrint(&b, "{d}", .{l.ids[k]}) catch "0") catch |err| app.failed(err);
    }
    gui.note(tx.get(tx.med_note));
}

// ---------------------------------------------------------------- scripted

/// `--row ENTRY CALL FIELD VALUE` (scripted.zig): a field of the entry's row of CALL as
/// its page writes it. HeroAttack[:hero class] (FIELD `hero`: re-keyed, `add`: a row for
/// VALUE, `remove`), WeaponClass, WeaponFlags (FIELD flipped), SkillIcon, KillIcon,
/// WeaponSound (FIELD icon/sound), Resist armor, WdelayHero (on true/false),
/// HiddenWeapons (FIELD weapon: VALUE's classic_id flipped), Medicine (kind, random),
/// Abilities (the entry's own row, a copy of its classType's at first: FIELD as the rules write it).
pub fn setByName(app: *App, idx: usize, call: []const u8, field: []const u8, value: []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const w = whoOf(app, idx);
    const eq = std.ascii.eqlIgnoreCase;
    const colon = std.mem.indexOfScalar(u8, call, ':');
    const name = call[0 .. colon orelse call.len];
    if (eq(name, "HeroAttack")) {
        const hero = if (colon) |k| call[k + 1 ..] else "";
        const list = heroRows(app.frame.allocator(), w);
        const r = for (list) |x| {
            if (eq(x.hero_class, hero) or (hero.len == 0 and x.hero == 0 and x.hero_class.len == 0)) break x;
        } else return error.NoSuchRow;
        if (eq(field, "hero")) return strikeFor(app, w, r, value, false);
        if (eq(field, "add")) return strikeFor(app, w, r, value, true);
        if (eq(field, "remove")) return removeStrike(app, w, r);
        return setStrike(app, w, r, field, value);
    }
    const text = app.store.text(@import("entries.zig").fileOf(app, app.catalog.entries.items[idx]) orelse return error.NoFile);
    if (eq(name, "WeaponClass")) return setClass(app, @intFromFloat(model.get(text, "class") orelse 0), field, value);
    if (eq(name, "WeaponFlags")) return toggleFlag(app, w, field);
    if (eq(name, "SkillIcon")) return picked(app, .skill_icon, idx, value);
    if (eq(name, "KillIcon")) return picked(app, .kill_icon, idx, value);
    if (eq(name, "WeaponSound")) return picked(app, .weapon_sound, idx, value);
    if (eq(name, "Resist")) return setArmor(app, w, try std.fmt.parseInt(i32, value, 10));
    if (eq(name, "WdelayHero")) return setWdelay(app, w, eq(value, "true"));
    if (eq(name, "HiddenWeapons")) return toggleHidden(app, w, try std.fmt.parseInt(i32, value, 10));
    if (eq(name, "Medicine")) return setMedicine(app, w, field, value);
    const ea = @import("entry_attacks.zig");
    // The tile scoring of the entry's AI eval; strike `FighterStrike:SPECIAL`'s spin `N.link`, `N.at`, `N.remove` or `add`.
    if (eq(name, "AiScoring")) return @import("rulespages.zig").setScoring(app, rules.aiProfile(w, @intFromFloat(model.get(text, "battle_class") orelse 0)).scoring orelse "generic", field, value);
    if (eq(name, "Abilities")) return @import("char_abilities.zig").setField(app, w, @intFromFloat(model.get(text, "battle_class") orelse 0), field, value);
    if (eq(name, "FighterStrike")) {
        const special = try std.fmt.parseInt(i32, call[(colon orelse return error.NoSpecial) + 1 ..], 10);
        if (eq(field, "add")) return ea.setSpin(app, special, 0, "add", value);
        const dot = std.mem.indexOfScalar(u8, field, '.') orelse return error.NoSuchField;
        return ea.setSpin(app, special, try std.fmt.parseInt(usize, field[0..dot], 10), field[dot + 1 ..], value);
    }
    return error.NoSuchCall;
}

test heroRows {
    // Weapon 86 (molotov): Hutchens' row and anyone's; an unknown weapon: the fallback.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const rows = heroRows(arena.allocator(), .{ .id = 86 });
    try std.testing.expectEqual(2, rows.len);
    try std.testing.expectEqual(29, rows[0].hero);
    try std.testing.expectEqual(0, rows[1].hero);
    const none = heroRows(arena.allocator(), .{ .id = 99999 });
    try std.testing.expectEqual(1, none.len);
    try std.testing.expect(rules.keyMatch(none[0], "weapon", .{ .id = 99999 }) == null);
}

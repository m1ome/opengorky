//! An enemy's and a hero's constructor blocks (entries.zig draws the page around them):
//! the look, the model and its animations, the base stats with the resistances, an
//! enemy's AI profile, weapons and attacks (char_arsenal.zig), its extra abilities
//! (char_abilities.zig, a hero's too), a hero's growth, strikes and rules.

const std = @import("std");
const baseName = @import("doctab.zig").baseName;
const Allocator = std.mem.Allocator;
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const model = @import("model.zig");
const sprview = @import("sprview.zig");
const entry_rules = @import("entry_rules.zig");
const entry_model = @import("entry_model.zig");
const look_pages = @import("look_pages.zig");
const art = @import("art.zig");
const entry_anims = @import("entry_anims.zig");
const entry_attacks = @import("entry_attacks.zig");
const entry_tables = @import("entry_tables.zig");
const entry_weapons = @import("entry_weapons.zig");
const picker = @import("picker.zig");
const entries = @import("entries.zig");
const og = @import("opengorky");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;

const choiceRow = entries.choiceRow;
const numRow = entries.numRow;

const hero_stats = app_mod.base_stats ++ [_]app_mod.Stat{
    .{ .label = tx.f_rage, .names = &.{"max_rage"} },
    .{ .label = tx.f_counter, .names = &.{"counter_attack"} },
    .{ .label = tx.f_experience, .names = &.{"experience"} },
    .{ .label = tx.f_level, .names = &.{"level"} },
};

/// An enemy class's blocks; `act_file`, `act_text`: its look's script (`act_*.ss`).
pub fn enemy(app: *App, a: Allocator, idx: usize, file: usize, text: []const u8, act_file: ?usize, act_text: ?[]const u8) void {
    const e = app.catalog.entries.items[idx];
    const mesh = entries.meshOf(app, e, text);
    if (gui.block(app, "look", tx.get(tx.sec_look), .{})) {
        // The look's script: its animations' page.
        const sum = if (act_text) |t| entry_anims.summary(app, a, t, mesh orelse "") else null;
        if (slot(app, 0, tx.get(tx.c_visual), entries.actOf(text) orelse "—", true, if (act_file) |f| .{ .tab = .anims, .key = look_pages.scriptKey(app, a, f) } else null, if (sum) |m| m.text else "", if (sum) |m| m.warn else false)) {
            if (picker.listKey(app, a, picker.names(a, app.catalog.acts.items))) |v| entries.setAct(app, file, v) catch |err| app.failed(err);
        }
        // The kill icon of the battle report: the exe's by classic_id, not the class's
        // spriteFile; editing it changes that monster's icon everywhere (its sprite page).
        // OpenGorky: picked (its KillIcon row by class).
        if (app.ogLayout()) entry_tables.killIconRow(app, idx, entries.enemyWho(app, e, text)) else {
            const report_icon = og.battle.report.iconOf(entries.enemyWho(app, e, text));
            gui.fieldRow(tx.get(tx.c_report_icon));
            if (report_icon) |n| {
                gui.txt(n, .label, theme.text, font_mod.regular);
                gui.spacer();
                if (gui.goButton(app, clay.id("report_icon_go"))) sprview.open(app, n) catch |err| app.setStatus(tx.st_import_failed, .{err});
            } else gui.txtWrap(tx.get(tx.report_none), .caption, theme.warn, font_mod.regular);
            clay.close();
        }
        // OpenGorky: picked into the file holding it (its look's), as a hero's is; a
        // character both hero and enemy has a look for each (Medusa: medusa, medusa_2).
        if (mesh) |m| modelSlots(app, a, idx, m, if (app.ogLayout()) @import("og_page.zig").meshHolder(app, file) else null, true);
        gui.blockEnd();
    }
    // Base stats with the resistances.
    if (gui.block(app, "base", tx.get(tx.sec_base), .{})) {
        for (app_mod.base_stats, 0..) |st, k| {
            if (std.mem.eql(u8, st.names[0], "armor")) armorChoice(app, file) else numRow(app, a, @intCast(2000 + k), tx.get(st.label), file, st.names, null, true);
        }
        // OpenGorky: what the game reads that the list above lacks.
        if (app.ogLayout()) numRow(app, a, 2110, tx.get(tx.f_rage), file, &.{"max_rage"}, null, true);
        ogNum(app, a, 2130, tx.p_rage_start, tx.p_rage_note, file, "rage", null);
        movesRows(app, a, file, text, null, false);
        sizeRows(app, a, file, mesh, null);
        entry_weapons.resistBlock(app, a, .{ .id = entries.enemyClassicId(app, text), .class = if (app.ogLayout()) entry_rules.classOf(e) else "" });
        gui.blockEnd();
    }
    // The AI: its profile picked (edited on its page, ›), its mode and own numbers.
    const who = entries.enemyWho(app, e, text);
    const class: i32 = @intFromFloat(model.textNum(app, text, "battle_class") orelse 0);
    if (gui.block(app, "ai", tx.get(tx.sec_ai), .{})) {
        entry_attacks.aiChoice(app, a, who, class);
        aiRows(app, a, file, text, null, true);
        gui.blockEnd();
    }
    @import("char_arsenal.zig").block(app, a, e, who, text);
    @import("char_abilities.zig").block(app, a, who, class, act_text);
    // OpenGorky: a class that is a hero too (its roles row): a hero's strikes, bonuses, rules.
    if (app.ogLayout()) if (og.rules.character(who)) |r| if (r.as_hero) {
        entry_attacks.heroSection(app, a, who);
        entry_attacks.bonusSection(app, a, who);
        entry_tables.heroRules(app, a, who);
    };
    leftovers(app, a, file, text, true);
}

/// OpenGorky: its size: the tiles it takes (`charSize`, ≥ 9: 3×3, ≥ 4: 2×2 as
/// combat/roster.fighterSize; the hit chance against it grows with it) and its model's
/// height (the `.msh`'s scale: every character wearing that model).
fn sizeRows(app: *App, a: Allocator, file: usize, mesh: ?[]const u8, after: ?[]const u8) void {
    if (!app.ogLayout()) return;
    gui.subhead(tx.get(tx.sec_size));
    numRow(app, a, 2120, tx.get(tx.p_char_size), file, &.{"footprint_tiles"}, after, true);
    const cs = model.ownNum(app, file, "footprint_tiles") orelse 1;
    const n: u32 = if (cs >= 9) 3 else if (cs >= 4) 2 else 1;
    gui.fieldNote(tx.alloc(a, tx.char_size_note, .{ n, n }), theme.dim);
    if (mesh) |m| entry_model.heightRow(app, a, m);
}

/// A hero's blocks, as an enemy's: the look is the hero file's own or its class's
/// (`act_text`; `act_file` its own), the weapons are its inventory (the head's button), no
/// AI (the player's).
pub fn hero(app: *App, a: Allocator, idx: usize, file: usize, text: []const u8, act_file: ?usize, act_text: ?[]const u8) void {
    const e = app.catalog.entries.items[idx];
    const own = act_text orelse entries.lookOf(app, text);
    const mesh = model.textStr(app, own, "mesh");
    if (gui.block(app, "look", tx.get(tx.sec_look), .{})) {
        // A hero's portraits (the panel, the inventory, the report): edited in the sprite page.
        if (model.textStr(app, own, "portrait")) |n| {
            gui.fieldRow(tx.get(tx.c_portrait_hero));
            gui.txt(n, .label, theme.text, font_mod.regular);
            gui.spacer();
            if (gui.goButton(app, clay.id("art_edit_icon"))) sprview.open(app, n) catch |err| app.setStatus(tx.st_import_failed, .{err});
            clay.close();
        }
        if (mesh) |m| {
            // The script binding its animations: its own file or the class's.
            const lf = look_pages.lookFile(app, e, text);
            const sum = entry_anims.summary(app, a, own, m);
            const lname = if (lf) |f| app.store.files.items[f].entry else "—";
            _ = slot(app, 11, tx.get(tx.sec_anims), baseName(lname), false, if (lf) |f| .{ .tab = .anims, .key = look_pages.scriptKey(app, a, f) } else null, sum.text, sum.warn);
            // The class's look: picked on the class's page.
            if (act_file == null) gui.fieldNote(tx.get(tx.hero_class_look), theme.dim);
            modelSlots(app, a, idx, m, act_file, act_file != null);
        } else if (act_file != null) entries.meshRow(app, a, tx.c_model, file, null);
        gui.blockEnd();
    }
    const who: og.rules.Who = .{ .id = entries.enemyClassicId(app, text), .class = entry_rules.classOf(e) };
    if (gui.block(app, "base", tx.get(tx.sec_combat), .{})) {
        for (hero_stats, 0..) |st, k| {
            if (k == app_mod.base_stats.len) {
                // A woman (`sex` 1): pushes nothing, no health2 voice (combat/devices.zig).
                flagRow(app, 3, tx.p_sex, tx.p_woman_n, file, own, "gender", "{");
                gui.subhead(tx.get(tx.sec_growth));
            }
            numRow(app, a, @intCast(2000 + k), tx.get(st.label), file, st.names, "{", false);
        }
        ogNum(app, a, 2130, tx.p_rage_start, tx.p_rage_note, file, "rage", "{");
        movesRows(app, a, file, text, "{", true);
        sizeRows(app, a, file, mesh, "{");
        entry_weapons.resistBlock(app, a, .{ .id = who.id, .class = if (app.ogLayout()) who.class else "" });
        gui.blockEnd();
    }
    // The AI leading it (an ally, the autobattle): the profile by it (base 0, as
    // generic.aiProfile for a non-enemy) and its own numbers.
    if (gui.block(app, "ai", tx.get(tx.sec_ai), .{})) {
        entry_attacks.aiChoice(app, a, who, 0);
        aiRows(app, a, file, text, "{", false);
        gui.fieldNote(tx.get(tx.ai_hero_note), theme.dim);
        gui.blockEnd();
    }
    @import("char_abilities.zig").block(app, a, who, @intFromFloat(model.textNum(app, own, "battle_class") orelse model.textNum(app, text, "battle_class") orelse 0), own);
    entry_attacks.heroSection(app, a, who);
    entry_attacks.bonusSection(app, a, who);
    entry_tables.heroRules(app, a, who);
    leftovers(app, a, file, text, false);
}

/// An asset slot: `value` picked from a list (`pick`; else only shown), a › to its page
/// (`to`), `sum` under it. True while its list is open: the caller draws it.
fn slot(app: *App, k: u32, label: []const u8, value: []const u8, pick: bool, to: ?struct { tab: app_mod.Tab, key: []const u8 }, sum: []const u8, warn: bool) bool {
    gui.fieldRow(label);
    const id = clay.idi("choice", k);
    const open = if (pick) picker.field(app, id, value, false) else blk: {
        gui.txtClip(value, .label, theme.text, font_mod.regular);
        gui.spacer();
        break :blk false;
    };
    if (to) |d| if (gui.goButton(app, clay.idi("slot_go", k))) @import("doctabs.zig").openKept(app, d.tab, d.key);
    clay.close();
    if (sum.len > 0) gui.fieldNote(sum, if (warn) theme.warn else theme.dim);
    return open;
}

/// The look's model (picked when `pick`, the file whose meshFile it is) and its textures,
/// each with its page; then a new look for the character (an item: its model): a model
/// from glTF, a copy of the model wearing a PNG (`texture`).
pub fn modelSlots(app: *App, a: Allocator, idx: usize, mesh: []const u8, pick: ?usize, texture: bool) void {
    if (slot(app, 1, tx.get(tx.c_model), mesh, pick != null, .{ .tab = .models, .key = mesh }, entry_model.modelSummary(app, a, mesh), false)) {
        if (picker.listKey(app, a, picker.names(a, app.catalog.meshes.items))) |v| entries.setString(app, pick.?, "mesh", v) catch |err| app.failed(err);
    }
    const names = art.textures(app, a, mesh);
    for (names, 0..) |n, k| _ = slot(app, @intCast(20 + k), if (k == 0) tx.get(tx.sec_textures) else "", n, false, .{ .tab = .textures, .key = n }, "", false);
    gui.subhead(tx.get(tx.sec_new_look));
    const kind = app.catalog.entries.items[idx].kind;
    gui.note(tx.get(if (kind == .enemy or kind == .hero) tx.look_new_note else tx.look_new_note_item));
    var labels: [9][]const u8 = undefined;
    labels[0] = tx.get(tx.b_glb_in);
    var n: usize = 1;
    // One per texture when the model has several (its parts' own: fang, smokerider).
    if (texture) for (0..@min(@max(names.len, 1), labels.len - 1)) |k| {
        labels[n] = if (names.len <= 1) tx.get(tx.b_new_texture) else tx.alloc(a, tx.b_new_texture_of, .{names[k]});
        n += 1;
    };
    const k = gui.footer(app, "look_foot", labels[0..n], null) orelse return;
    app.askFile(if (k == 0) .{ .kind = .glb, .run = entry_model.onGlbIn, .entry = idx } else .{ .kind = .png, .run = entries.onTextureIn, .entry = idx, .slot = @intCast(k - 1) });
}

/// An enemy's armour: which of the weapon's lightArmor, mediumArmor, heavyArmor percents
/// its damage loses (battle/rules.afterArmor, 0x49123e); written as the number field was.
fn armorChoice(app: *App, file: usize) void {
    const a = app.frame.allocator();
    const cur = model.ownNum(app, file, "armor");
    if (choiceRow(app, 8, tx.get(tx.p_armor), entry_tables.armorLabel(a, cur))) if (picker.listKey(app, a, entry_tables.armorRows(a, cur))) |v| model.set(app, file, &.{"armor"}, v, null) catch |err| app.failed(err);
    gui.fieldNote(tx.get(tx.c_armor_note), theme.dim);
}

/// OpenGorky: number field `name` of `file` edited (`after`: where a missing one goes);
/// Classic: shown (the exe's fields stay as the game has them).
fn ogNum(app: *App, a: Allocator, row: u32, label: tx.Msg, note: ?tx.Msg, file: usize, comptime name: []const u8, after: ?[]const u8) void {
    if (app.ogLayout()) numRow(app, a, row, tx.get(label), file, &.{name}, after, true) else {
        gui.fieldRow(tx.get(label));
        gui.txt(app_mod.fmtNum(a, model.ownNum(app, file, name)), .body, theme.text, font_mod.regular);
        clay.close();
    }
    if (note) |n| gui.fieldNote(tx.get(n), theme.dim);
}

/// A 0/1 field (`name`, read from `text`, written to `file`) as a tick; Classic: shown.
fn flagRow(app: *App, k: u32, label: tx.Msg, note: tx.Msg, file: usize, text: []const u8, comptime name: []const u8, after: ?[]const u8) void {
    const on = (model.textNum(app, text, name) orelse 0) != 0;
    gui.fieldRow(tx.get(label));
    if (app.ogLayout()) {
        if (gui.check(app, clay.idi("flag", k), on, "")) model.set(app, file, &.{name}, if (on) "0" else "1", after) catch |err| app.failed(err);
    } else gui.txt(tx.get(if (on) tx.la_yes else tx.la_no), .body, theme.text, font_mod.regular);
    clay.close();
    gui.fieldNote(tx.get(note), theme.dim);
}

/// Its turn speed and the locks scripts set (fields.moveLock, combat attackLock), a
/// hero's `avoidEnumerate` (an AI ally, combat/roster.zig) too.
fn movesRows(app: *App, a: Allocator, file: usize, text: []const u8, after: ?[]const u8, hero_: bool) void {
    gui.subhead(tx.get(tx.sec_moves));
    ogNum(app, a, 2131, tx.p_rot_speed, null, file, "turn_speed", after);
    flagRow(app, 0, tx.p_move_lock, tx.p_move_lock_n, file, text, "move_locked", after);
    flagRow(app, 1, tx.p_attack_lock, tx.p_attack_lock_n, file, text, "attack_locked", after);
    if (hero_) flagRow(app, 2, tx.p_ally, tx.p_ally_n, file, text, "outside_party", after);
}

/// The AI's fields: its mode (aiMode, a choice) and own numbers (aic*; combat/ai.zig
/// params: the profile's over them). An enemy's numbers stay editable in Classic (as
/// they were), a hero's are OpenGorky's.
fn aiRows(app: *App, a: Allocator, file: usize, text: []const u8, after: ?[]const u8, enemy_: bool) void {
    const mode = std.fmt.allocPrint(a, "{d}", .{@as(i32, @intFromFloat(model.textNum(app, text, "ai_mode") orelse 0))}) catch "0";
    gui.fieldRow(tx.get(tx.p_ai_mode));
    if (app.ogLayout()) {
        if (picker.field(app, clay.idi("choice", 10), entry_attacks.modeLabel(mode), false)) if (picker.listKey(app, a, entry_attacks.mode_choice.rows(app, a, mode))) |v| model.set(app, file, &.{"ai_mode"}, v, after) catch |err| app.failed(err);
    } else gui.txt(entry_attacks.modeLabel(mode), .body, theme.text, font_mod.regular);
    clay.close();
    gui.fieldNote(tx.get(tx.ai_mode_note), theme.dim);
    const ai = app_mod.fighter_stats[app_mod.base_stats.len + 1 ..];
    inline for (0..4) |k| {
        const st = ai[k];
        if (enemy_) numRow(app, a, @intCast(2000 + app_mod.base_stats.len + 1 + k), tx.get(st.label), file, st.names, after, true) else ogNum(app, a, 2140 + k, st.label, null, file, st.names[0], after);
    }
    gui.fieldNote(tx.get(tx.ai_fields_note), theme.dim);
}

/// Its battle class (`classType`, battle/fighter.Class; its own or its class's): the
/// exe's behaviour by it, its base AI profile and abilities. OpenGorky: picked from the
/// exe's classes (the port's generic 100 left out: it needs fields of its own).
pub fn classTypeRow(app: *App, a: Allocator, file: usize, text: []const u8, after: ?[]const u8) void {
    const cur: i32 = @intFromFloat(entries.inheritedVar(app, text, "battle_class") orelse 0);
    gui.fieldRow(tx.get(tx.p_class_type));
    if (app.ogLayout()) {
        if (picker.field(app, clay.idi("choice", 12), classLabel(a, cur), false)) {
            // The classes the rules in force name (their rows' class_name), the port's
            // generic left out (it needs fields of its own).
            var rows: std.ArrayList(picker.Opt) = .empty;
            rows.append(a, .{ .key = "0", .label = tx.get(tx.class_plain), .selected = cur == 0 }) catch {};
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            for (og.rules.active.ai_profiles) |r| addClass(a, &rows, &seen, r.class_name, cur);
            for (og.core.modules.tables().classes) |r| addClass(a, &rows, &seen, r.class_name, cur);
            if (picker.listKey(app, a, rows.items)) |v| model.set(app, file, &.{"battle_class"}, v, after) catch |err| app.failed(err);
        }
    } else gui.txt(classLabel(a, cur), .body, theme.text, font_mod.regular);
    clay.close();
    gui.fieldNote(tx.get(tx.p_class_type_n), theme.dim);
}

/// `N · name` of classType `v` (0: an ordinary fighter).
fn classLabel(a: Allocator, v: i32) []const u8 {
    if (v == 0) return tx.get(tx.class_plain);
    const name = og.rules.fighterClassName(v) orelse return std.fmt.allocPrint(a, "{d}", .{v}) catch "";
    // OpenGorky: the name alone (its number is the rules' own).
    return if (og.rules.og) name else std.fmt.allocPrint(a, "{d} · {s}", .{ v, name }) catch "";
}

/// Class `name` (a row's class_name) a choice once, `cur` the one selected.
fn addClass(a: Allocator, rows: *std.ArrayList(picker.Opt), seen: *std.StringHashMapUnmanaged(void), name: []const u8, cur: i32) void {
    if (name.len == 0 or std.ascii.eqlIgnoreCase(name, "generic") or seen.contains(name)) return;
    seen.put(a, name, {}) catch return;
    rows.append(a, .{ .key = name, .label = name, .selected = og.rules.fighterClassId(name) == cur }) catch {};
}

/// "Other fields", folded: the Fighter.s fields this fighter's script sets that nothing
/// reads for it (enemies resist by the table and Resist rows, a hero's armour is its
/// items' pr*, movable/explosive are obstacles'); edited as the others (OpenGorky).
fn leftovers(app: *App, a: Allocator, file: usize, text: []const u8, enemy_: bool) void {
    const Field = struct { name: []const u8, label: tx.Msg, enemy_only: bool = false };
    const list = [_]Field{
        .{ .name = "calmness", .label = tx.p_calmness },
        .{ .name = "experience", .label = tx.f_experience, .enemy_only = true },
        .{ .name = "level", .label = tx.f_level, .enemy_only = true },
        .{ .name = "counter_attack", .label = tx.f_counter, .enemy_only = true },
        .{ .name = "gender", .label = tx.p_sex, .enemy_only = true },
        .{ .name = "actRot", .label = tx.p_act_rot },
        .{ .name = "movable", .label = tx.p_movable },
        .{ .name = "explosive", .label = tx.p_explosive },
        .{ .name = "blast_weapon", .label = tx.p_explode_weapon },
    };
    var n: usize = 0;
    inline for (list) |f| n += @intFromBool((enemy_ or !f.enemy_only) and (model.find(text, f.name) != null));
    inline for (og.battle.immunity.pr_fields) |pr| n += @intFromBool((model.find(text, pr) != null));
    if (n == 0) return;
    if (!gui.block(app, "leftovers", tx.get(tx.sec_leftovers), .{ .folded = true, .summary = std.fmt.allocPrint(a, "{d}", .{n}) catch "" })) return;
    defer gui.blockEnd();
    gui.note(tx.get(tx.leftovers_note));
    const after: ?[]const u8 = if (enemy_) null else "{";
    inline for (list, 0..) |f, k| if ((enemy_ or !f.enemy_only) and (model.find(text, f.name) != null)) {
        // calmness: edited in Classic too, as the base stats had it.
        if (comptime std.mem.eql(u8, f.name, "calmness")) numRow(app, a, 2150 + k, tx.get(f.label), file, &.{f.name}, after, true) else if (model.textStr(app, text, f.name)) |sv| {
            gui.fieldRow(tx.get(f.label));
            gui.txt(sv, .body, theme.text, font_mod.regular);
            clay.close();
        } else ogNum(app, a, 2150 + k, f.label, null, file, f.name, after);
    };
    inline for (og.battle.immunity.pr_fields, 0..) |pr, k| if ((model.find(text, pr) != null)) {
        if (app.ogLayout()) numRow(app, a, 2170 + k, tx.alloc(a, tx.p_pr, .{pr}), file, &.{pr}, after, true) else gui.propRow(tx.alloc(a, tx.p_pr, .{pr}), app_mod.fmtNum(a, model.textNum(app, text, pr)));
    };
}

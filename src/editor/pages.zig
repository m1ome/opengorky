//! Enemies, items and heroes tabs: the catalog on the left; the selected class or hero
//! with its parameters, look (enemy model, item icon and model), weapon effect and
//! damage zone; "make a copy" makes a new class from a game one.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const c = @import("sdl");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const vars = @import("vars.zig");
const catalog = @import("catalog.zig");
const Kind = catalog.Kind;
const Entry = catalog.Entry;
const placement = @import("placement.zig");
const info = @import("info.zig");
const common_archive = @import("store.zig").common_archive;
const preview = @import("preview.zig");
const sounds = @import("sounds.zig");
const sprview = @import("sprview.zig");
const codeview = @import("codeview.zig");
const art = @import("art.zig");
const og = @import("opengorky");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;

const Picker = main.Picker;

/// Model of an entry: an item's `meshFile`, an enemy's through its look.
pub fn meshOf(app: *App, e: Entry, text: []const u8) ?[]const u8 {
    if (e.kind != .enemy) return vars.getStr(text, "meshFile");
    var buf: [128]u8 = undefined;
    const f = app.store.file(common_archive, std.fmt.bufPrint(&buf, "classes\\{s}", .{actOf(text) orelse return null}) catch return null) catch return null;
    return vars.getStr(app.store.text(f), "meshFile");
}

/// A PNG chosen in a dialog (or given on the command line) for entry `ask.entry`.
// File dialog answers (app.askFile) for catalog entry `ask.entry`: its icon or model
// texture (`ask.slot`) from a PNG, or out to one.
pub fn onIconIn(app: *App, ask: main.FileAsk, path: []const u8) !void {
    const e = app.catalog.entries.items[ask.entry];
    const file = fileOf(app, e) orelse return;
    const text = app.store.text(file);
    if (e.kind == .enemy) {
        try art.replaceIcon(app, og.battle.report.iconOf(enemyNameId(app, text)) orelse "", path);
        return app.setStatus(tx.st_icon_added, .{e.id});
    }
    app.setStatus(tx.st_icon_added, .{try art.importIcon(app, file, e.id, path)});
}
pub fn onIconOut(app: *App, ask: main.FileAsk, path: []const u8) !void {
    const e = app.catalog.entries.items[ask.entry];
    const text = app.store.text(fileOf(app, e) orelse return);
    try art.exportIcon(app, (if (e.kind == .enemy) og.battle.report.iconOf(enemyNameId(app, text)) else vars.getStr(text, "spriteFile")) orelse "", path);
    app.setStatus(tx.st_exported, .{path});
}
pub fn onTextureOut(app: *App, ask: main.FileAsk, path: []const u8) !void {
    const e = app.catalog.entries.items[ask.entry];
    const text = app.store.text(fileOf(app, e) orelse return);
    try art.exportTexture(app, meshOf(app, e, text) orelse "", path, ask.slot);
    app.setStatus(tx.st_exported, .{path});
}
pub fn onTextureIn(app: *App, ask: main.FileAsk, path: []const u8) !void {
    const e = app.catalog.entries.items[ask.entry];
    const file = fileOf(app, e) orelse return;
    const text = app.store.text(file);
    if (e.kind == .enemy) {
        const act = try art.newLook(app, actOf(text) orelse return error.NoLook, path, ask.slot);
        try setAct(app, file, act);
        return app.setStatus(tx.st_look_added, .{act});
    }
    const model = try art.newModel(app, vars.getStr(text, "meshFile") orelse return error.NoModel, path, ask.slot);
    try setString(app, file, "meshFile", model);
    app.setStatus(tx.st_look_added, .{model});
}

/// Unsaved common/other.dat files for the model preview.
pub fn overlayGet(ctx: *anyopaque, name: []const u8) ?[]const u8 {
    const app: *App = @ptrCast(@alignCast(ctx));
    const i = app.store.find(common_archive, name) orelse return null;
    return app.store.text(i);
}

const hero_stats = main.base_stats ++ [_]main.Stat{
    .{ .label = tx.f_rage, .names = &.{"max_rage"} },
    .{ .label = tx.f_counter, .names = &.{"counterAttack"} },
    .{ .label = tx.f_experience, .names = &.{"experience"} },
    .{ .label = tx.f_level, .names = &.{"level"} },
};

/// Item fields with a label; others show their script name.
const field_labels = [_]struct { []const u8, tx.Msg }{
    .{ "max_damage", tx.f_damage }, .{ "lightArmor", tx.f_light },    .{ "mediumArmor", tx.f_medium },
    .{ "heavyArmor", tx.f_heavy },  .{ "extraExperience", tx.f_exp }, .{ "ammoUsed", tx.f_ammo },
    .{ "counter", tx.f_count },     .{ "classType", tx.f_class },     .{ "hp", tx.p_hp },
    .{ "armor", tx.p_armor },       .{ "prFire", tx.p_fire },         .{ "prElect", tx.p_elect },
    .{ "prDist", tx.p_dist },       .{ "prEnergy", tx.p_energy },     .{ "prFreeze", tx.p_freeze },
    .{ "prTranq", tx.p_tranq },     .{ "prGas", tx.p_gas },
};
/// Item fields not shown as numbers (identity, placement, or picked from a list).
const hidden = [_][]const u8{ "nameID", "funcID", "place", "type", "classType", "ammoUsed", "recharge" };

const WeaponClass = og.battle.weapon_class.WeaponClass;
/// The engine's weapon classes: values and names.
const class_tags = @typeInfo(WeaponClass).@"enum".field_names;
pub const class_values = blk: {
    const vs = @typeInfo(WeaponClass).@"enum".field_values;
    var out: [vs.len]i32 = undefined;
    for (vs, 0..) |x, i| out[i] = x;
    break :blk out;
};

/// Names of the player's weapon classes (1–24); monster ones show their engine name.
const class_names = [_]tx.Msg{
    tx.w_pistol,    tx.w_rifle, tx.w_dartgun,  tx.w_flame,  tx.w_rocket,   tx.w_ion,     tx.w_blaster, tx.w_satellite,
    tx.w_time_bomb, tx.w_melee, tx.w_grenade,  tx.w_knife,  tx.w_chaingun, tx.w_shotgun, tx.w_molotov, tx.w_napalm,
    tx.w_barrel,    tx.w_decoy, tx.w_nitrogen, tx.w_bottle, tx.w_matches,  tx.w_stun,    tx.w_gas,     tx.w_shocker,
};

pub fn classLabel(a: Allocator, v: ?f32) []const u8 {
    const n: i32 = @intFromFloat(v orelse return "—");
    if (n >= 1 and n <= class_names.len) return tx.alloc(a, tx.w_class_fmt, .{ n, tx.get(class_names[@intCast(n - 1)]) });
    for (class_values, class_tags) |cv, t| if (cv == n) return tx.alloc(a, tx.w_class_fmt, .{ n, t });
    return std.fmt.allocPrint(a, "{d}", .{n}) catch "?";
}

/// Ammo item classes with their nameID (what `ammoUsed` names).
const Ammo = struct { id: i32, title: []const u8 };

pub fn ammoClasses(app: *App, a: Allocator) []const Ammo {
    var out: std.ArrayList(Ammo) = .empty;
    for (app.catalog.entries.items) |e| {
        if (e.kind != .ammo) continue;
        const f = fileOf(app, e) orelse continue;
        const id = vars.get(app.store.text(f), "nameID") orelse continue;
        out.append(a, .{ .id = @intFromFloat(id), .title = if (e.title.len > 0) e.title else e.id }) catch {};
    }
    return out.items;
}

fn ammoLabel(app: *App, a: Allocator, v: ?f32) []const u8 {
    const n: i32 = @intFromFloat(v orelse 0);
    if (n == 0) return tx.get(tx.a_none);
    if (n == -1) return tx.get(tx.a_self);
    for (ammoClasses(app, a)) |x| if (x.id == n) return x.title;
    return std.fmt.allocPrint(a, "{d}", .{n}) catch "?";
}

/// Weapon `type` (damage kind, battle/immunity.zig).
pub const damage_types = [_]struct { i32, tx.Msg }{
    .{ 1, tx.d_fire },  .{ 2, tx.d_freeze },  .{ 3, tx.d_electricity }, .{ 5, tx.d_gas },        .{ 6, tx.d_bullet },     .{ 7, tx.d_melee },
    .{ 9, tx.d_tranq }, .{ 11, tx.d_energy }, .{ 12, tx.d_attract },    .{ 13, tx.d_explosion }, .{ 14, tx.d_flammable },
};

/// Where a missing value goes: class `.ss` files are included into init() whole, item
/// classes and heroes keep values inside their first function. Attacks are either
/// (`wp_timebomb_explode.s` has its init()); without a `{` the value goes at the end.
fn afterFor(k: Kind) ?[]const u8 {
    return if (k == .enemy) null else "{";
}

pub fn fileOf(app: *App, e: Entry) ?usize {
    return app.store.file(e.archive, e.entry) catch null;
}

pub fn entryById(app: *App, id: []const u8) !usize {
    for (app.catalog.entries.items, 0..) |e, i| if (std.ascii.eqlIgnoreCase(e.id, id)) return i;
    return error.NoSuchEntry;
}

pub fn page(app: *App, a: Allocator) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    if (app.entry) |i| detail(app, a, i) else {
        clay.open(.{ .layout = .{ .padding = .{ .left = 24, .top = 24 } } });
        txt(tx.get(tx.pick_entry), 15, theme.dim, font_mod.regular);
        clay.close();
    }
    clay.close();
    if (app.picker) |p| picker(app, a, p);
}

/// Current icon of an item: from the edited file when it is open, else as listed.
pub fn iconOf(app: *App, e: Entry) []const u8 {
    if (e.kind == .enemy) return og.battle.report.iconOf(enemyNameId(app, app.store.text(fileOf(app, e) orelse return ""))) orelse "";
    const i = app.store.find(e.archive, e.entry) orelse return e.icon;
    return vars.getStr(app.store.text(i), "spriteFile") orelse e.icon;
}

fn detail(app: *App, a: Allocator, idx: usize) void {
    const e = app.catalog.entries.items[idx];
    const file = fileOf(app, e) orelse return;
    const text = app.store.text(file);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fit() }, .padding = .{ .left = 20, .right = 20, .top = 16, .bottom = 8 }, .childGap = 14, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    if (e.kind != .enemy and e.kind != .hero and (e.kind != .attack or vars.getStr(text, "spriteFile") != null)) clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(56), .height = clay.fixed(56) } }, .image = .{ .imageData = app.icon(vars.getStr(text, "spriteFile") orelse "") } });
    clay.open(.{ .layout = .{ .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 4 } });
    // As the concept's: the name, its kind as a chip, its id dim; the file under it.
    clay.open(.{ .layout = .{ .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    txt(if (e.title.len > 0) e.title else e.id, 24, theme.text, font_mod.bold);
    clay.open(.{ .layout = .{ .padding = .{ .left = 8, .right = 8, .top = 2, .bottom = 2 } }, .backgroundColor = theme.button, .cornerRadius = clay.radius(4), .border = .{ .color = theme.button_edge, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } } });
    txt(tx.get(switch (e.kind) {
        .enemy => tx.chip_enemy,
        .hero => tx.chip_hero,
        .weapon => tx.chip_weapon,
        .ammo => tx.chip_ammo,
        .item => tx.chip_item,
        .attack => tx.chip_attack,
    }), 12, theme.text, font_mod.regular);
    clay.close();
    txt(e.id, 14, theme.dim, font_mod.regular);
    clay.close();
    txt(if (e.base) |b| tx.alloc(a, tx.copy_of, .{b}) else e.entry, 12, theme.dim, font_mod.regular);
    clay.close();
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    if (e.kind == .hero) if (main.toolButton(app, "inventory", .package, tx.get(tx.inv_open), false, false)) openInventory(app, idx);
    if (main.toolButton(app, "code", .code, tx.get(tx.code_open), false, false)) openCode(app, idx);
    if (e.kind != .hero and e.kind != .attack) if (main.toolButton(app, "copy", .copy, tx.get(tx.make_copy), false, true)) copyClicked(app, idx);
    clay.close();

    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fit() }, .padding = .{ .left = 20, .right = 20, .bottom = 8 } } });
    const hint: tx.Msg = if (e.base != null) (if (e.kind == .enemy) tx.hint_copy_enemy else tx.hint_copy_item) else switch (e.kind) {
        .enemy => tx.hint_enemy,
        .hero => tx.hint_hero,
        .attack => tx.hint_attack,
        else => tx.hint_item,
    };
    clay.text(tx.get(hint), .{ .textColor = if (e.kind == .hero) theme.dim else theme.warn, .fontSize = 13, .fontId = font_mod.regular });
    clay.close();

    // Enemies and heroes: data | model over animations | sounds, the edges dragged.
    const act_text: ?[]const u8 = switch (e.kind) {
        .hero => text,
        .enemy => blk: {
            var buf: [128]u8 = undefined;
            const entry = std.fmt.bufPrint(&buf, "classes\\{s}", .{actOf(text) orelse break :blk null}) catch break :blk null;
            break :blk if (app.store.file(common_archive, entry)) |af| app.store.text(af) else |_| null;
        },
        else => null,
    };
    // A weapon: a hero striking with it (the exe's strike by nameID, two-handed ones in
    // the two-handed stance), the weapon in hand.
    var strike: ?Strike = null;
    if (e.kind == .weapon) strike = strikeOf(app, a, text);
    const lk: ?Look = if (act_text) |t| look(app, a, t, null, null, e.riders.items) else if (strike) |s| look(app, a, s.hero_text, s.slot, s.held, &.{}) else null;
    // As the concept's: the model over its animations and their sounds in the centre,
    // the values on the right.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    // A weapon: its model or its damage zone; an enemy attack has only the zone.
    if (e.kind == .weapon) {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = 12, .top = 8, .bottom = 8 } }, .backgroundColor = theme.viewport });
        if (main.segmented(app, "entry_view", &.{ tx.get(tx.view_model), tx.get(tx.view_zone) }, @intFromBool(app.zone_view))) |k| app.zone_view = k == 1;
        clay.close();
    }
    if (e.kind == .attack or (e.kind == .weapon and app.zone_view)) {
        clay.openScroll(.{ .id = clay.id("zone"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
        reachMap(a, vars.get(text, "classType"), 0);
        clay.close();
    } else if (lk) |l| {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(app.split(.entry_y)) } } });
        modelPane(app, l, if (strike) |st| st.info else null);
        clay.close();
        app.splitter(.entry_y, true, 1, 0);
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } } });
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(app.split(.entries)), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
        if (strike != null) heroList(app, a) else animList(app, l);
        clay.close();
        app.splitter(.entries, false, 1, 0);
        if (l.tex != null) soundsBlock(app, a, l.mesh, l.file);
        clay.close();
    } else {
        // No model: its icon large in the centre (as the game draws it, pixels kept).
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.viewport });
        if (app.icon(iconOf(app, e))) |t| {
            var w: f32 = 0;
            var h: f32 = 0;
            _ = c.SDL_GetTextureSize(t, &w, &h);
            const k = @floor(@min(6, 320 / @max(1, @max(w, h))));
            clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(w * @max(1, k)), .height = clay.fixed(h * @max(1, k)) } }, .image = .{ .imageData = t } });
        }
        clay.close();
    }
    clay.close();
    app.splitter(.entry_x, false, -1, 0);
    clay.openScroll(.{ .id = clay.id("fields"), .layout = .{ .sizing = .{ .width = clay.fixed(app.split(.entry_x)), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 8, .bottom = 12 } }, .backgroundColor = theme.panel, .border = .{ .color = theme.line, .width = .{ .left = 1 } } });
    textsBlock(app, a, e, text);
    switch (e.kind) {
        .enemy => {
            if (section(app, "look", tx.sec_look)) {
                choiceRow(app, 0, tx.get(tx.c_visual), actOf(text) orelse "—", .{ .what = .act, .file = file });
                textureButtons(app, a, idx, meshOf(app, e, text));
                if (meshOf(app, e, text)) |m| modelFields(app, a, idx, m);
                // The kill icon of the battle report: the exe's by nameID, not the class's
                // spriteFile; editing it changes that monster's icon everywhere.
                rowOpen(tx.get(tx.c_report_icon));
                const report_icon = og.battle.report.iconOf(enemyNameId(app, text));
                if (report_icon) |n| txt(n, 14, theme.text, font_mod.regular) else clay.text(tx.get(tx.report_none), .{ .textColor = theme.warn, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
                clay.close();
                if (report_icon) |n| artButtons(app, idx, &.{ .{ tx.b_icon_png, .png, onIconIn }, .{ tx.b_export_icon, .png_out, onIconOut } }, n);
            }
            // Base stats, then the AI's (the last four), as the concept's sections.
            const ai_from = main.fighter_stats.len - 4;
            if (section(app, "base", tx.sec_base)) for (main.fighter_stats[0..ai_from], 0..) |st, k| numRow(app, a, @intCast(2000 + k), tx.get(st.label), file, st.names, null, true);
            if (section(app, "ai", tx.sec_ai)) for (main.fighter_stats[ai_from..], ai_from..) |st, k| numRow(app, a, @intCast(2000 + k), tx.get(st.label), file, st.names, null, true);
            resistBlock(enemyNameId(app, text), 4);
            weaponBlock(app, a, e);
        },
        .hero => {
            // A hero's portraits (the panel, the inventory, the report): edited in the sprite page.
            if (vars.getStr(text, "spriteFile")) |n| {
                rowOpen(tx.get(tx.c_portrait_hero));
                txt(n, 14, theme.text, font_mod.regular);
                clay.close();
                artButtons(app, idx, &.{}, n);
            }
            for (hero_stats, 0..) |st, k| numRow(app, a, @intCast(2000 + k), tx.get(st.label), file, st.names, "{", false);
            if (vars.getStr(text, "meshFile")) |m| modelFields(app, a, idx, m);
        },
        else => {
            // Most enemy attacks have no icon or model (the human enemies' guns do).
            if (e.kind != .attack or vars.getStr(text, "spriteFile") != null) {
                choiceRow(app, 0, tx.get(tx.c_icon), vars.getStr(text, "spriteFile") orelse "—", .{ .what = .icon, .file = file });
                artButtons(app, idx, &.{ .{ tx.b_icon_png, .png, onIconIn }, .{ tx.b_export_icon, .png_out, onIconOut } }, vars.getStr(text, "spriteFile"));
            }
            if (e.kind == .weapon or vars.getStr(text, "meshFile") != null) {
                choiceRow(app, 1, tx.get(tx.c_mesh), vars.getStr(text, "meshFile") orelse "—", .{ .what = .mesh, .file = file });
                if (vars.getStr(text, "meshFile")) |m| {
                    textureButtons(app, a, idx, m);
                    modelFields(app, a, idx, m);
                }
            }
            if (e.kind == .weapon or e.kind == .attack) {
                effectRow(a, text);
                if (e.kind == .weapon) flashRows(app, a, text);
                choiceRow(app, 3, tx.get(tx.c_damage), damageLabel(vars.get(text, "type")), .{ .what = .damage, .file = file });
                choiceRow(app, 4, tx.get(tx.f_class), classLabel(a, vars.get(text, "classType")), .{ .what = .weapon_class, .file = file });
                if (e.kind == .weapon) choiceRow(app, 5, tx.get(tx.f_ammo), ammoLabel(app, a, vars.get(text, "ammoUsed")), .{ .what = .ammo, .file = file });
                rechargeRow(a, text);
            }
            var buf: [48][]const u8 = undefined;
            const names = vars.numericNames(text, &buf);
            for (names, 0..) |n, k| {
                if (isHidden(n) or unused(n)) continue;
                numRow(app, a, @intCast(2000 + k), labelOf(n), file, a.dupe([]const u8, &.{n}) catch continue, "{", true);
            }
            // Fields the classes fill but no battle code reads, the exe's (effect_time,
            // effect_power: burning and poison are 3 turns, 15/10/5, 0x4900f0/0x4903d0) nor ours.
            var any = false;
            for (names) |n| {
                if (!unused(n)) continue;
                if (!any) {
                    main.panelHeader(tx.get(tx.unused_title));
                    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fit() }, .padding = .{ .left = 12, .right = 12, .bottom = 4 } } });
                    clay.text(tx.get(tx.unused_hint), .{ .textColor = theme.dim, .fontSize = 12, .fontId = font_mod.regular });
                    clay.close();
                    any = true;
                }
                rowOpen(n);
                txt(main.fmtNum(a, vars.get(text, n)), 14, theme.dim, font_mod.regular);
                clay.close();
            }
        },
    }
    if (section(app, "info", tx.info_title)) info.show(app, info.rows(app, std.fmt.allocPrint(a, "entry:{d}:{s}", .{ idx, e.entry }) catch e.entry, idx, entryInfo));
    clay.close();
    clay.close();
}

const Look = @import("entry_model.zig").Look;
const look = @import("entry_model.zig").look;
const Strike = @import("entry_model.zig").Strike;
const strikeOf = @import("entry_model.zig").strikeOf;
const heroList = @import("entry_model.zig").heroList;
const modelPane = @import("entry_model.zig").modelPane;
const animList = @import("entry_model.zig").animList;
const soundsBlock = @import("entry_model.zig").soundsBlock;
const modelFields = @import("entry_model.zig").modelFields;
pub const soundOp = @import("entry_model.zig").soundOp;

/// The entry's Info: its file (and level), what it includes, its nameID and the others
/// with it, the identity fields, what it names, the scripts making it a party hero, the
/// levels whose scripts name its class (`#include ft_sphinx.ss`, `cw_pistol`…).
fn entryInfo(idx: usize, app: *App, list: *info.List) void {
    const e = app.catalog.entries.items[idx];
    const text = app.store.text(fileOf(app, e) orelse return);
    info.defined(list, e.archive, e.entry, true);
    info.includes(app, list, e.archive, text, 4);
    // A hero may name itself in a class it includes (the catalog read it there).
    const id: i32 = if (e.kind == .enemy) enemyNameId(app, text) else if (vars.get(text, "nameID")) |v| @intFromFloat(v) else e.name_id orelse 0;
    if (id > 0) {
        info.nameId(app, list, id);
        info.sameName(app, list, id, idx);
    }
    switch (e.kind) {
        // Its attacks' pages (`wp_x.ss` → entry `wp_x`).
        .enemy => for (e.weapons.items) |w| list.add(.{ .group = .refs, .text = w, .to = if (entryById(app, std.fs.path.stem(w))) |i| .{ .entry = i } else |_| .{ .code = .{ .archive = common_archive, .entry = list.fmt("classes\\{s}", .{w}) } }, .icon = .swords }),
        .hero => if (std.mem.eql(u8, e.archive, common_archive)) list.add(.{ .group = .party, .text = tx.get(tx.info_party_start) }) else {
            const n = list.rows.items.len;
            info.joins(app, list, e.id);
            if (list.rows.items.len == n) list.add(.{ .group = .party, .text = tx.get(tx.info_party_never) });
        },
        else => {
            for (hidden) |n| {
                // nameID has its row; a weapon picks these from lists above.
                if (eql(n, "nameID") or ((e.kind == .weapon or e.kind == .attack) and (eql(n, "type") or eql(n, "classType"))) or (e.kind == .weapon and eql(n, "ammoUsed"))) continue;
                const v = vars.get(text, n) orelse continue;
                list.add(.{ .group = .fields, .text = list.fmt("{s} {s}", .{ n, main.fmtNum(list.a, v) }) });
            }
            if (e.kind == .weapon and id > 0) list.add(.{ .group = .fields, .text = tx.alloc(list.a, tx.info_strike, .{og.battle.attacks.heroAttack(20, id).anim}) });
            // A weapon names its ammo by nameID (-1: itself), weapons name an ammo.
            const ammo: i32 = @intFromFloat(vars.get(text, "ammoUsed") orelse 0);
            for (app.catalog.entries.items, 0..) |x, i| {
                if (e.kind == .weapon and ammo > 0 and x.kind == .ammo and x.name_id == ammo) list.add(.{ .group = .refs, .text = info.entryText(list, x), .to = .{ .entry = i }, .icon = .package });
                if (e.kind != .ammo or x.kind != .weapon or id <= 0) continue;
                const f = fileOf(app, x) orelse continue;
                if (vars.get(app.store.text(f), "ammoUsed") == @as(f32, @floatFromInt(id))) list.add(.{ .group = .used, .text = info.entryText(list, x), .to = .{ .entry = i }, .icon = .package });
            }
            if (ammo == -1) list.add(.{ .group = .refs, .text = tx.get(tx.a_self) });
            // The enemy classes whose fighters hold an attack in the battles.
            if (e.kind == .attack) for (app.catalog.entries.items, 0..) |x, i| for (x.weapons.items) |w| {
                if (std.ascii.eqlIgnoreCase(std.fs.path.stem(w), e.id)) list.add(.{ .group = .used, .text = info.entryText(list, x), .to = .{ .entry = i }, .icon = .user });
            };
        },
    }
    const stem = std.fs.path.stem(e.entry[if (std.mem.lastIndexOfScalar(u8, e.entry, '\\')) |k| k + 1 else 0..]);
    const before = list.rows.items.len;
    info.levelsNaming(app, list, stem);
    if (list.rows.items.len == before and e.kind != .ammo) list.add(.{ .group = .used, .text = tx.get(tx.info_used_none) });
}

/// A section's header (as the concept's): a chevron and its title; true while open
/// (folding is remembered: `sec/<key>` in the open-folder set means folded).
fn section(app: *App, key: []const u8, title: tx.Msg) bool {
    var kb: [48]u8 = undefined;
    const k = std.fmt.bufPrint(&kb, "sec/{s}", .{key}) catch key;
    const folded = app.tree_open.contains(k);
    const sid = clay.id(k);
    if (main.clickable(app, .{ .id = sid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(34) }, .padding = .{ .left = 6, .right = 12 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.header, .border = .{ .color = theme.line, .width = .{ .bottom = 1 } } }, false)) @import("assettree.zig").toggleKey(app, k);
    @import("icons.zig").leaf(app.r, app.gpa, if (folded) .chevron_right else .chevron_down, 14, theme.dim);
    txt(tx.get(title), 14, theme.text, font_mod.bold);
    clay.close();
    return !folded;
}

pub fn idName(a: Allocator, base: []const u8, k: usize) []const u8 {
    return std.fmt.allocPrint(a, "{s}{d}", .{ base, k }) catch base;
}

pub fn smallButton(app: *App, id: []const u8, label: []const u8, col: clay.Color) bool {
    const bid = clay.id(id);
    clay.open(.{ .id = bid, .layout = .{ .padding = .{ .left = 5, .right = 5, .top = 1, .bottom = 1 } }, .backgroundColor = if (clay.pointerOver(bid)) theme.row_hover else .{ .r = 0, .g = 0, .b = 0, .a = 0 }, .cornerRadius = clay.radius(3) });
    const hit = clay.hovered() and app.clicked;
    txt(label, 14, col, font_mod.bold);
    clay.close();
    return hit;
}

pub const weaponChoice = @import("entry_weapons.zig").weaponChoice;
pub const swapClassWeapon = @import("entry_weapons.zig").swapClassWeapon;
pub const swapWeapon = @import("entry_weapons.zig").swapWeapon;
pub const resistBlock = @import("entry_weapons.zig").resistBlock;
const weaponBlock = @import("entry_weapons.zig").weaponBlock;
const reachMap = @import("entry_weapons.zig").reachMap;

/// Turns to recharge after a strike: set by the weapon's class in the exe.
fn rechargeRow(a: Allocator, text: []const u8) void {
    const n = og.battle.rules.rechargeTurns(@intFromFloat(vars.get(text, "classType") orelse 0));
    rowOpen(tx.get(tx.f_recharge));
    txt(std.fmt.allocPrint(a, "{d}", .{n}) catch "?", 14, theme.dim, font_mod.regular);
    txt(tx.get(tx.f_recharge_class), 12, theme.dim, font_mod.regular);
    clay.close();
}

/// nameID of an enemy class: its own (after a look change), else its look's.
/// The entry's texts: its name in the game (string.tab by nameID) and, for items, what
/// examining it says (items.inf) — typed in place (the classes sharing the number: Info).
fn textsBlock(app: *App, a: Allocator, e: Entry, text: []const u8) void {
    const texts = @import("texts.zig");
    const textedit = @import("textedit.zig");
    if (!section(app, "texts", tx.sec_texts)) return;
    const id: i32 = if (e.kind == .enemy) enemyNameId(app, text) else if (vars.get(text, "nameID")) |v| @intFromFloat(v) else return;
    if (id <= 0) return;
    rowOpen(tx.alloc(a, tx.c_name_game, .{id}));
    if (textedit.field(app, "ent_name", texts.get(app, a, .strings, id) orelse "", 0, tx.get(tx.c_name_none))) |v| {
        texts.set(app, .strings, id, v) catch |err| app.setStatus(tx.st_set_failed, .{err});
        app.refreshTitles();
    }
    clay.close();
    if (e.kind == .weapon or e.kind == .ammo or e.kind == .item) {
        rowOpen(tx.get(tx.c_examine));
        if (textedit.field(app, "ent_examine", texts.get(app, a, .items, id) orelse "", 0, tx.get(tx.c_examine_none))) |v| texts.set(app, .items, id, v) catch |err| app.setStatus(tx.st_set_failed, .{err});
        clay.close();
    }
}

fn enemyNameId(app: *App, text: []const u8) i32 {
    if (vars.get(text, "nameID")) |v| return @intFromFloat(v);
    var buf: [128]u8 = undefined;
    const f = app.store.file(common_archive, std.fmt.bufPrint(&buf, "classes\\{s}", .{actOf(text) orelse return 0}) catch return 0) catch return 0;
    return @intFromFloat(vars.get(app.store.text(f), "nameID") orelse 0);
}

/// Declared in Weapon.s and filled in the classes, read by neither the exe nor the port.
const unused_fields = [_][]const u8{ "effect_time", "effect_power", "effect_range", "range", "max_range", "min_damage", "accuracy_effect", "range_effect", "dist_effect", "near_effect", "move_range_effect" };

fn unused(n: []const u8) bool {
    for (unused_fields) |u| if (std.ascii.eqlIgnoreCase(u, n)) return true;
    return false;
}

fn isHidden(n: []const u8) bool {
    for (hidden) |h| if (std.ascii.eqlIgnoreCase(h, n)) return true;
    return false;
}

fn labelOf(n: []const u8) []const u8 {
    for (field_labels) |l| if (std.ascii.eqlIgnoreCase(l[0], n)) return tx.get(l[1]);
    return n;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// `act_x.ss` an enemy class includes.
pub fn actOf(text: []const u8) ?[]const u8 {
    const p = std.ascii.findIgnoreCase(text, "#include act_") orelse return null;
    const s = p + "#include ".len;
    var e = s;
    while (e < text.len and !std.ascii.isWhitespace(text[e])) e += 1;
    return text[s..e];
}

/// State the weapon's class applies by itself (the exe's, rules.weaponEffect).
fn classEffect(text: []const u8) ?tx.Msg {
    const cls = vars.get(text, "classType") orelse return null;
    const e = og.battle.rules.weaponEffect(@intFromFloat(cls)) orelse return null;
    return switch (e) {
        .burn => tx.e_burn,
        .freeze => tx.e_freeze,
        .gas, .bite => tx.e_poison,
        .soak => tx.e_soak,
        .sleep => tx.e_sleep,
        .defend => null,
    };
}

/// Effect on hit: set by the weapon's class in the exe.
fn effectRow(a: Allocator, text: []const u8) void {
    rowOpen(tx.get(tx.c_effect));
    txt(if (classEffect(text)) |m| tx.alloc(a, tx.e_class, .{tx.get(m)}) else "—", 13, theme.dim, font_mod.regular);
    clay.close();
}

/// The shot's muzzle flash: where and how the exe attaches it is its own table by the
/// weapon's nameID (0x48bda2…0x48ce33, fx/hits.zig flashFor), not data — shown as is;
/// the effect itself (its frames, `.dsc`) is data: edited on its page.
fn flashRows(app: *App, a: Allocator, text: []const u8) void {
    const id: i32 = @intFromFloat(vars.get(text, "nameID") orelse return);
    rowOpen(tx.get(tx.c_flash));
    const f = og.fx.hits.flashFor(id, 0) orelse {
        txt(tx.get(tx.flash_none), 13, theme.dim, font_mod.regular);
        return clay.close();
    };
    txt(tx.alloc(a, tx.flash_of, .{ f.effect, f.link, f.ticks }), 13, theme.text, font_mod.regular);
    clay.close();
    main.propNote(tx.alloc(a, tx.flash_note, .{ f.offset[0], f.offset[1], f.offset[2], f.scale }));
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(34) }, .padding = .{ .left = 12, .right = 12 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    if (artButton(app, clay.id("flash_edit"), tx.get(tx.flash_edit))) {
        @import("doctabs.zig").keepCurrent(app);
        app.setTab(.effects);
        app.effect.sel.set(f.effect);
    }
    clay.close();
}

fn damageLabel(v: ?f32) []const u8 {
    const t: i32 = @intFromFloat(v orelse return "—");
    for (damage_types) |d| if (d[0] == t) return tx.get(d[1]);
    return "?";
}

fn numRow(app: *App, a: Allocator, row: u32, label: []const u8, file: usize, names: []const []const u8, after: ?[]const u8, show_missing: bool) void {
    const v = vars.get(app.store.text(file), names[0]);
    if (v == null and !show_missing) return;
    rowOpen(label);
    main.valueCell(app, a, row, file, names, after, v, true, false);
    clay.close();
}

/// Buttons under a look row: pick a PNG (or where to write one).
/// Buttons under a look or icon row; `icon` set: "Edit…" opens it in the sprite page.
pub fn artButtons(app: *App, idx: usize, buttons: []const struct { tx.Msg, main.FileKind, *const fn (*App, main.FileAsk, []const u8) anyerror!void }, icon: ?[]const u8) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(34) }, .padding = .{ .left = 12, .right = 12 }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    for (buttons) |b| if (artButton(app, clay.idi("art", @truncate(std.hash.Wyhash.hash(0, b[0].en))), tx.get(b[0]))) app.askFile(.{ .kind = b[1], .run = b[2], .entry = idx });
    if (icon) |n| if (artButton(app, clay.id("art_edit_icon"), tx.get(tx.b_edit_icon))) sprview.open(app, n) catch |err| app.setStatus(tx.st_import_failed, .{err});
    clay.close();
}

/// New texture / texture to PNG for a model: one pair, or a row per texture named
/// when the model has several (its parts' own: fang, smokerider, the judge).
fn textureButtons(app: *App, a: Allocator, idx: usize, mesh: ?[]const u8) void {
    const names = if (mesh) |m| art.textures(app, a, m) else &.{};
    if (names.len <= 1) return artButtons(app, idx, &.{ .{ tx.b_new_texture, .png, onTextureIn }, .{ tx.b_export_texture, .png_out, onTextureOut } }, null);
    for (names, 0..) |n, k| {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(30) }, .padding = .{ .left = 12, .right = 12 }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(236) } } });
        txt(n, 13, theme.dim, font_mod.regular);
        clay.close();
        const slot: u8 = @intCast(@min(k, 255));
        if (artButton(app, clay.idi("art_tex_new", @intCast(k)), tx.get(tx.b_new_texture))) app.askFile(.{ .kind = .png, .run = onTextureIn, .entry = idx, .slot = slot });
        if (artButton(app, clay.idi("art_tex_out", @intCast(k)), tx.get(tx.b_export_texture))) app.askFile(.{ .kind = .png_out, .run = onTextureOut, .entry = idx, .slot = slot });
        clay.close();
    }
}

fn artButton(app: *App, bid: ui.Clay_ElementId, label: []const u8) bool {
    _ = main.clickable(app, .{
        .id = bid,
        .layout = .{ .sizing = .{ .height = clay.fixed(24) }, .padding = .{ .left = 10, .right = 10 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = theme.panel,
        .cornerRadius = clay.radius(theme.radius),
        .border = .{ .color = theme.field_border, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } },
    }, false);
    const hit = clay.hovered() and app.clicked;
    txt(label, 13, theme.text, font_mod.regular);
    clay.close();
    return hit;
}

pub fn rowOpen(label: []const u8) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(28) }, .padding = .{ .left = 12, .right = 12 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(230) } } });
    txt(label, 14, theme.dim, font_mod.regular);
    clay.close();
}

fn choiceRow(app: *App, k: u32, label: []const u8, value: []const u8, p: Picker) void {
    rowOpen(label);
    const bid = clay.idi("choice", k);
    const open = if (app.picker) |cur| cur.what == p.what else false;
    if (main.clickable(app, .{
        .id = bid,
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(24) }, .padding = .{ .left = 8, .right = 8 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = theme.field,
        .cornerRadius = clay.radius(theme.radius),
        .border = .{ .color = if (open) theme.accent else theme.field_border, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } },
    }, open)) app.picker = if (open) null else p;
    txt(value, 14, theme.text, font_mod.regular);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    txt("…", 13, theme.dim, font_mod.regular);
    clay.close();
    clay.close();
}

fn button(app: *App, id: []const u8, label: []const u8, on: *const fn (*App, usize) void, arg: usize) void {
    if (main.button(app, id, label, true)) on(app, arg);
}

/// The hero's starting inventory in the box window: owner as its calls name it.
pub fn openInventory(app: *App, idx: usize) void {
    const e = app.catalog.entries.items[idx];
    const f = fileOf(app, e) orelse return;
    const t = app.store.text(f);
    // The owner in the hero's own calls ("Bt"), else the script's name.
    const owner: []const u8 = blk: {
        const p = std.mem.indexOf(u8, t, "_New(") orelse break :blk e.id;
        var it = std.mem.tokenizeAny(u8, t[p + 5 ..], ",); \t\r\n");
        _ = it.next();
        _ = it.next();
        break :blk std.mem.trim(u8, it.next() orelse break :blk e.id, "\"");
    };
    app.box = .{ .file = f, .name = if (e.title.len > 0) e.title else e.id, .owner = owner };
}

fn openCode(app: *App, idx: usize) void {
    const f = fileOf(app, app.catalog.entries.items[idx]) orelse return;
    codeview.open(app, f, null);
}

fn copyClicked(app: *App, idx: usize) void {
    copyEntry(app, idx) catch |err| app.setStatus(tx.st_copy_failed, .{err});
}

/// A new class `<id>_<n>` copying entry `idx` (a mark line names its game class).
pub fn copyEntry(app: *App, idx: usize) !void {
    const e = app.catalog.entries.items[idx];
    if (e.kind == .hero) return error.HeroesAreFixed;
    // No battle could take a copy: the `.wpn` swap lists the game's attacks.
    if (e.kind == .attack) return error.AttacksAreFixed;
    const file = fileOf(app, e) orelse return error.NotFound;
    var text = app.store.text(file);
    // A copy of a copy names the game class too.
    if (std.mem.startsWith(u8, text, catalog.copy_mark)) text = text[(std.mem.indexOfScalar(u8, text, '\n') orelse text.len - 1) + 1 ..];
    const base = e.base orelse e.id;
    var id_buf: [96]u8 = undefined;
    const id = for (2..1000) |n| {
        const s = try std.fmt.bufPrint(&id_buf, "{s}_{d}", .{ base, n });
        if (!app.catalog.has(e.kind, s)) break s;
    } else return error.NoFreeName;
    const nt = try std.fmt.allocPrint(app.gpa, "{s}{s}{s}{s}{s}{s}", .{ catalog.copy_mark, catalog.prefix(e.kind), base, catalog.ext(e.kind), placement.newline(text), text });
    errdefer app.gpa.free(nt);
    const ne = try app.catalog.addCopy(e, id);
    _ = try app.store.add(common_archive, ne.entry, nt, null, true);
    app.entry = app.catalog.entries.items.len - 1;
    app.picker = null;
    app.setStatus(tx.st_copied, .{ ne.entry, base });
}

/// Sets field `name` of entry `e` (CLI `--entry`): `act` (enemy look),
/// `spriteFile`, `meshFile` (strings) or a number (`hp` sets max_hp too).
pub fn setField(app: *App, e: Entry, name: []const u8, value: []const u8) !void {
    const file = fileOf(app, e) orelse return error.NotFound;
    if (std.mem.eql(u8, name, "act")) return setAct(app, file, value);
    if (std.mem.eql(u8, name, "spriteFile") or std.mem.eql(u8, name, "meshFile")) return setString(app, file, name, value);
    const names: []const []const u8 = if (std.mem.eql(u8, name, "hp")) &.{ "hp", "max_hp" } else &.{name};
    return app.store.setVar(file, names, value, afterFor(e.kind));
}

/// A new look (`act_*.ss`: model, animations). The look also carries the fighter's
/// nameID (name, resistances, special rules), so the class keeps its own after it.
pub fn setAct(app: *App, file: usize, act: []const u8) !void {
    const text = app.store.text(file);
    const old = actOf(text) orelse return error.NoLook;
    var ob: [128]u8 = undefined;
    var nb: [128]u8 = undefined;
    const id: ?f32 = vars.get(text, "nameID") orelse blk: {
        const ai = app.store.file(common_archive, try std.fmt.bufPrint(&ob, "classes\\{s}", .{old})) catch break :blk null;
        break :blk vars.get(app.store.text(ai), "nameID");
    };
    try app.store.replaceText(file, try std.fmt.bufPrint(&ob, "#include {s}", .{old}), try std.fmt.bufPrint(&nb, "#include {s}", .{act}));
    if (id) |v| try app.store.setVar(file, &.{"nameID"}, try std.fmt.bufPrint(&nb, "{d}", .{v}), "#include act_");
}

pub fn setString(app: *App, file: usize, name: []const u8, v: []const u8) !void {
    var buf: [128]u8 = undefined;
    try app.store.setVar(file, &.{name}, try std.fmt.bufPrint(&buf, "\"{s}\"", .{v}), "{");
}

pub const picked = @import("entry_picker.zig").picked;
const picker = @import("entry_picker.zig").picker;

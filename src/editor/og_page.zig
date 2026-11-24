//! An OpenGorky project's block on its page: the OG layout of a
//! character, a weapon, an item (the catalog's entries of `src/`), a battle's or location's
//! own block, a block inside one (a battle's fighter, its weapon). Two layers only: what
//! the block writes itself (× takes it out) over its archetype's and the schema's. Its
//! fields, the components it attaches with their params, the blocks inside it (a fighter's
//! weapons and items) and, for a fighter, its look's fields and its "Extra abilities"
//! (char_abilities.zig, its own Abilities row). Every value is edited by its type: an enum
//! picked, a `character` picked from the characters, a struct field by field, a
//! `list<Struct>` element by element (+, ×), a number, string or `list<int>` typed as
//! OG Script. Each change writes one statement through the OG backend (model_og.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const tx = @import("text.zig");
const picker = @import("picker.zig");
const font_mod = @import("font.zig");
const lay = @import("layout.zig");
const frame = @import("frame.zig");
const model = @import("model.zig");
const model_og = model.model_og;
const traitinfo = @import("traitinfo.zig");
const og = @import("opengorky");
const ir = og.script.ir;
const schema = og.core.schema;
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;

/// Where a value's type names are found: the module and `use`s of what declares it.
const Scope = struct { module: []const u8, uses: []const []const u8 };

/// Catalog entry `idx` (an `og_src` block) on its tab: its text on the stage, its sections
/// in the constructor.
pub fn detail(app: *App, a: Allocator, idx: usize) void {
    const e = app.catalog.entries.items[idx];
    const file = app.store.file(e.archive, e.entry) catch return;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } } });
    frame.stage(app);
    entryStage(app, a, e, file);
    frame.props(app, "og_fields");
    sections(app, a, file, "og", e.name_id);
    // Its model to and from glTF; a new one goes where the model is named (its look's: shared).
    if (meshOf(app, file)) |m| if (gui.block(app, "og_glb", tx.get(tx.c_model), .{})) {
        if (meshHolder(app, file) != file) gui.note(tx.get(tx.og_glb_look_note));
        const em = @import("entry_model.zig");
        if (gui.footer(app, "og_glb_foot", &.{ tx.get(tx.b_glb_in), tx.get(tx.b_glb_out) }, null)) |k|
            app.askFile(if (k == 0) .{ .kind = .glb, .run = em.onGlbIn, .entry = idx } else .{ .kind = .glb_out, .run = em.onGlbOut, .entry = idx, .name = m });
        gui.blockEnd();
    };
    // Its icons of the game's windows: an enemy's in the after-battle report (its
    // `report_icon`), a weapon's in the skills window (`skill_icon`).
    if (e.kind == .enemy or e.kind == .weapon) if (gui.block(app, "og_icons", tx.get(tx.og_icons), .{})) {
        const et = @import("entry_tables.zig");
        const w = et.whoOf(app, idx);
        if (e.kind == .enemy) {
            et.killIconRow(app, idx, w);
        } else {
            et.skillIconRow(app, idx, w);
        }
        gui.blockEnd();
    };
    // A weapon's effects: its effect fields (fieldsBlockTitled leaves them to this block).
    if (e.kind == .weapon and gui.block(app, "og_effects", tx.get(tx.sec_effects), .{})) {
        @import("entry_attacks.zig").effectsRows(app, a, file, idx);
        gui.blockEnd();
    }
    clay.closeScrollColumn();
    clay.close();
}

/// What the stage shows of an entry: a character its look (the model over its animations,
/// as Classic's page), a weapon its model, a hero striking with it or its reach, anything
/// else its block's text.
fn entryStage(app: *App, a: Allocator, e: @import("catalog.zig").Entry, file: usize) void {
    const em = @import("entry_model.zig");
    if (e.kind == .enemy or e.kind == .hero) if (em.lookText(app, file)) |t| {
        // Its strikes (a weapon it holds each): the model, or it striking with one.
        const ea = @import("entry_attacks.zig");
        if (strikesOf(app, a, e)) |ss| if (ss.list.len > 0) {
            const labels = a.alloc([]const u8, ss.list.len + 1) catch return;
            labels[0] = tx.get(tx.view_model);
            for (ss.list, 1..) |at, k| labels[k] = weaponTitle(app, at.class);
            const cur: usize = if (app.enemy_strike) |k| @min(k + 1, ss.list.len) else 0;
            clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = lay.space.md, .top = lay.space.sm, .bottom = lay.space.sm }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.viewport });
            if (gui.segmented(app, "og_strike", labels, cur)) |k| app.enemy_strike = if (k == 0) null else @intCast(k - 1);
            clay.close();
            if (cur > 0) if (ea.strikeOf(app.gpa, ss.who, ss.list[cur - 1])) |sh| {
                const info = tx.alloc(a, tx.atk_with, .{ sh.slot, labels[cur] });
                return em.lookStage(app, a, em.look(app, a, t, sh.slot, sh.held, e.riders.items), t, info, sh.held.strike, &.{});
            };
        };
        return em.lookStage(app, a, em.look(app, a, t, null, null, e.riders.items), t, null, null, &.{});
    };
    if (e.kind != .weapon) return stageText(app, a, file);
    const text = app.store.text(file);
    const view = app.entry_view;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = lay.space.md, .top = lay.space.sm, .bottom = lay.space.sm }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.viewport });
    if (gui.segmented(app, "entry_view", &.{ tx.get(tx.view_model), tx.get(tx.view_strike), tx.get(tx.view_zone) }, @backingInt(view))) |k| app.entry_view = @fromBackingInt(@intCast(k));
    clay.close();
    switch (view) {
        .zone => {
            clay.openScrollXY(.{ .id = clay.id("zone"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
            @import("zone_edit.zig").page(app, a, model.textNum(app, text, "class"));
            clay.close();
        },
        .strike => if (em.strikeOf(app, a, text, e.class)) |st| {
            const fx = if (st.held) |h| h.strike else null;
            em.lookStage(app, a, em.look(app, a, st.hero_text, st.slot, st.held, &.{}), null, st.info, fx, &.{});
        } else stageText(app, a, file),
        else => if (model.textStr(app, text, "mesh")) |m| {
            em.modelPane(app, em.look(app, a, std.fmt.allocPrint(a, "meshFile=\"{s}\";", .{m}) catch "", null, null, &.{}), null, tx.model_hint);
        } else stageText(app, a, file),
    }
}

/// A character's strikes: the weapons it holds (an enemy; a hero striking by its own rows,
/// Medusa: its enemy side's) and who strikes; null: it strikes by the hero table.
fn strikesOf(app: *App, a: Allocator, e: @import("catalog.zig").Entry) ?struct { who: og.rules.Who, list: []const @import("entry_attacks.zig").Attack } {
    const ea = @import("entry_attacks.zig");
    const who: og.rules.Who = .{ .id = og.core.entity.idOf(e.class) orelse 0, .class = e.class };
    if (e.kind == .enemy) return .{ .who = who, .list = ea.attacksOf(app, a, e, who) };
    if (!og.core.entity.heroOf(who).own_attacks) return null;
    for (app.catalog.entries.items) |x| if (x.kind == .enemy and std.mem.eql(u8, x.class, e.class)) return .{ .who = who, .list = ea.attacksOf(app, a, x, who) };
    return null;
}

/// Weapon class `class`'s title (its entry's), else its name.
fn weaponTitle(app: *App, class: []const u8) []const u8 {
    const id = @import("entry_rules.zig").bareClass(class);
    for (app.catalog.entries.items) |x| if (x.kind == .weapon and std.ascii.eqlIgnoreCase(x.id, id)) return if (x.title.len > 0) x.title else id;
    return id;
}

/// Scene `name` of an OpenGorky project (`src/scenes/<name>.ogs`): its block's text on the
/// stage; "Scene on" (`enabled = false`: never started) and its
/// fields (`points`) as any block's.
pub fn scene(app: *App, a: Allocator, name: []const u8) void {
    const file = sceneFile(app, name) orelse return gui.warning(tx.get(tx.og_no_block));
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } } });
    frame.stage(app);
    // Its name (a click renames it, levelops.renameScene) and where the project starts it.
    const sp = @import("scenepage.zig");
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(16, 12), .childGap = 8 } });
    const renamed = sp.ogHeader(app, a, name);
    // The views as on Classic: the overview (where it starts, the map, the block's text),
    // its lines, a test run.
    const overview = app.scenes.view == .overview;
    if (!renamed) {
        sp.ogTabs(app, file);
        if (overview) {
            sp.ogStarts(app, a, name);
            sp.ogMap(app, a, name, file);
        }
    }
    clay.close();
    if (renamed) {
        clay.close();
        clay.close();
        return;
    }
    if (overview) stageText(app, a, file) else sp.ogView(app, a, name, file);
    frame.props(app, "og_scene");
    gui.fieldRow("");
    const on = sceneOn(app, file);
    if (gui.check(app, clay.id("og_scene_on"), on, tx.get(tx.og_scene_on))) setSceneOn(app, file, !on) catch |err| app.failed(err);
    clay.close();
    gui.fieldNote(tx.get(tx.og_scene_on_note), theme.dim);
    sections(app, a, file, "ogsc", null);
    clay.closeScrollColumn();
    clay.close();
}

/// Scene `name`'s block file (`src/scenes/<name>.ogs`); null: none.
pub fn sceneFile(app: *App, name: []const u8) ?usize {
    const path = std.fmt.allocPrint(app.frame.allocator(), "scenes/{s}.ogs", .{name}) catch return null;
    const f = app.store.file(@import("store.zig").og_src, path) catch return null;
    return if (model_og.blockOf(app, app.frame.allocator(), f) != null) f else null;
}

fn sceneOn(app: *App, file: usize) bool {
    const e = model.field(app, file, "enabled").og_expr orelse return true;
    return !(e.kind == .lit and e.kind.lit == .bool and !e.kind.lit.bool);
}

/// Scene block file `file` on (its `enabled` taken out) or off (`enabled = false`).
pub fn setSceneOn(app: *App, file: usize, on: bool) !void {
    if (on) return model_og.unset(app, file, &.{"enabled"});
    return model_og.set(app, file, &.{"enabled"}, "false");
}

/// The block's text on the stage (as written: its comments too).
fn stageText(app: *App, a: Allocator, file: usize) void {
    clay.openScrollXY(.{ .id = clay.id("og_stage"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(16, 12), .childGap = 2 }, .backgroundColor = theme.viewport });
    if (model_og.blockOf(app, a, file)) |b| {
        gui.txt(tx.alloc(a, tx.og_stage_file, .{b.path}), .caption, theme.dim, font_mod.regular);
        const t = app.store.text(b.text_file);
        var it = std.mem.splitScalar(u8, t[b.e.span.start..@min(t.len, b.e.span.end)], '\n');
        while (it.next()) |l| gui.txt(if (l.len > 0) l else " ", .body, theme.text, font_mod.regular);
    } else gui.warning(tx.get(tx.og_no_block));
    clay.close();
}

/// The block's sections: its head, fields, components, inner blocks; a fighter's look and
/// abilities (`name_id`: its classic_id, the catalog's). `key` keeps ids apart (several on a page).
pub fn sections(app: *App, a: Allocator, file: usize, key: []const u8, name_id: ?i32) void {
    const b = model_og.blockOf(app, a, file) orelse return gui.warning(tx.get(tx.og_no_block));
    const scope: Scope = .{ .module = b.ns, .uses = b.uses };
    gui.headCard();
    // An entry's in-game name as its heading (as the tree and tab say it), its block's name after.
    const name = b.names[b.names.len - 1];
    const title: []const u8 = if (name_id != null and b.names.len == 1) if (app.catalog.byKey(@import("store.zig").og_src, app.store.files.items[file].entry)) |i| app.catalog.entries.items[i].title else "" else "";
    if (title.len > 0) gui.heading(title, std.fmt.allocPrint(a, "{s} · {s}", .{ name, tx.alloc(a, tx.og_head, .{ b.e.kind, b.path }) }) catch name) else gui.heading(name, tx.alloc(a, tx.og_head, .{ b.e.kind, b.path }));
    if (b.e.base.len > 0) gui.chip(tx.alloc(a, tx.og_archetype, .{b.e.base}));
    // Its code (the block's text) and its model (a weapon's mesh, a fighter's look's).
    gui.row(lay.space.sm);
    if (gui.smallButton(app, clay.id(std.fmt.allocPrint(a, "{s}_code", .{key}) catch key), tx.get(tx.og_code))) @import("doctabs.zig").showCode(app, b.text_file, b.e.span.start);
    if (meshOf(app, file)) |m| if (gui.smallButton(app, clay.id(std.fmt.allocPrint(a, "{s}_model", .{key}) catch key), tx.alloc(a, tx.og_model, .{m}))) @import("doctabs.zig").show(app, .models, m);
    clay.close();
    if (b.names.len == 1) nameRows(app, a, file, b);
    gui.blockEnd();
    // A location or battle: its components first (Reinforcements' waves), its many
    // fields folded; its objects are picked on the map (their blocks below then).
    const place = std.mem.eql(u8, b.e.kind, "battle") or std.mem.eql(u8, b.e.kind, "level");
    if (place) attachBlock(app, a, file, b, key);
    fieldsBlockTitled(app, a, file, b, scope, key, tx.get(tx.og_fields), place, false);
    if (!place) attachBlock(app, a, file, b, key);
    if (!place) innerBlock(app, a, file, b, key) else objectsBlock(app, a, file, key);
    if (!isFighter(b.e.kind)) return;
    // Its look (an archetype's, shared): its slots, idles, walks as fields.
    const look = model.field(app, file, "look");
    if (look.og_expr) |le| if (le.kind == .word) if (model_og.archetypeFile(app, le.kind.word)) |lf| if (model_og.blockOf(app, a, lf)) |lb| {
        fieldsBlockTitled(app, a, lf, lb, .{ .module = lb.ns, .uses = lb.uses }, std.fmt.allocPrint(a, "{s}_look", .{key}) catch key, tx.alloc(a, tx.og_look, .{le.kind.word}), true, false);
    };
    // What it strikes with in battle (its MonsterAttack rows' weapons), each to its page.
    strikesBlock(app, a, b, key);
    // "Extra abilities": its own Abilities row.
    @import("char_abilities.zig").block(app, a, whoOf(app, a, file, b, name_id), classType(app, file), null);
}

/// The model of block file `file`: its `mesh` (a weapon's, an item's), else its look's.
pub fn meshOf(app: *App, file: usize) ?[]const u8 {
    return model.textStr(app, app.store.text(meshHolder(app, file) orelse return null), "mesh");
}

/// The file whose `mesh` is block file `file`'s model: its own, else its look's (shared).
pub fn meshHolder(app: *App, file: usize) ?usize {
    if (model.textStr(app, app.store.text(file), "mesh") != null) return file;
    const v = model.field(app, file, "look").og_expr orelse return null;
    if (v.kind != .word) return null;
    const lf = model_og.archetypeFile(app, v.kind.word) orelse return null;
    return if (model.textStr(app, app.store.text(lf), "mesh") != null) lf else null;
}

/// The catalog entry of archetype `class` (`weapons::pistol`); null: none.
fn entryOf(app: *App, class: []const u8) ?usize {
    for (app.catalog.entries.items, 0..) |e, i| if (e.class.len > 0 and std.ascii.eqlIgnoreCase(e.class, class)) return i;
    return null;
}

/// Archetype `class` as a list shows it: its name in the game and its path.
fn entryLabel(app: *App, a: Allocator, class: []const u8) []const u8 {
    const i = entryOf(app, class) orelse return class;
    const e = app.catalog.entries.items[i];
    return if (e.title.len > 0) std.fmt.allocPrint(a, "{s} · {s}", .{ e.title, class }) catch class else class;
}

/// A fighter archetype's strikes (rules MonsterAttack by its class): the weapon of each,
/// its page a click away, and the animation it plays.
fn strikesBlock(app: *App, a: Allocator, b: model_og.Block, key: []const u8) void {
    if (b.names.len != 1) return;
    const class = if (b.ns.len > 0) std.fmt.allocPrint(a, "{s}::{s}", .{ b.ns, b.names[0] }) catch return else b.names[0];
    var rows: std.ArrayList(og.rules.MonsterAttack) = .empty;
    for (og.rules.active.monster_attacks) |r| if (std.ascii.eqlIgnoreCase(r.fighter_class, class)) rows.append(a, r) catch {};
    if (rows.items.len == 0) return;
    if (!gui.block(app, std.fmt.allocPrint(a, "{s}_strikes", .{key}) catch key, tx.get(tx.og_strikes), .{ .summary = std.fmt.allocPrint(a, "{d}", .{rows.items.len}) catch "" })) return;
    defer gui.blockEnd();
    for (rows.items, 0..) |r, k| {
        gui.fieldRow(r.anim);
        gui.txtClip(if (r.weapon_class.len > 0) entryLabel(app, a, r.weapon_class) else tx.get(tx.og_any_weapon), .caption, theme.dim, font_mod.regular);
        gui.spacer();
        if (r.weapon_class.len > 0) if (entryOf(app, r.weapon_class)) |i| if (gui.goButton(app, clay.idi(std.fmt.allocPrint(a, "{s}_sgo", .{key}) catch key, @intCast(k)))) @import("entries.zig").showEntry(app, i);
        clay.close();
    }
}

/// An archetype's name in the game (`name = "…"` on the blocks owning its classic_id, else
/// its `UiText` row; texts.zig) typed in; a weapon's or item's examine text too (`examine`,
/// else `Examine`). The catalog's list shows it.
fn nameRows(app: *App, a: Allocator, file: usize, b: model_og.Block) void {
    const kind = b.e.kind;
    if (!isFighter(kind) and !std.mem.eql(u8, kind, "weapon") and !std.mem.eql(u8, kind, "item")) return;
    // Its texts are its blocks' fields (`name`, `examine`: the identity is the path).
    textRow(app, a, file, "name", "og_name", tx.get(tx.c_name_og), tx.get(tx.c_name_og_none));
    if (std.mem.eql(u8, kind, "fighter")) return;
    textRow(app, a, file, "examine", "og_examine", tx.get(tx.c_examine), tx.get(tx.c_examine_none));
}

/// Text field `field` of block file `file` typed in place (its archetype's shown under it).
fn textRow(app: *App, a: Allocator, file: usize, field: []const u8, id: []const u8, label: []const u8, none: []const u8) void {
    const v = model.field(app, file, field);
    const cur: []const u8 = if (v.og_expr) |x| schema.text(x) orelse "" else "";
    gui.fieldRow(label);
    if (gui.textField(app, id, cur, 0, none)) |t| {
        const esc = std.mem.replaceOwned(u8, a, t, "\"", "\\\"") catch return;
        const q = std.fmt.allocPrint(a, "\"{s}\"", .{esc}) catch return;
        (if (t.len == 0) model_og.unset(app, file, &.{field}) else model_og.set(app, file, &.{field}, q)) catch |err| app.failed(err);
        app.refreshTitles();
    }
    clay.close();
}

/// Field `n` is edited by its own row of the page (the Icons block, the Effects block's sound).
fn ownRow(n: []const u8) bool {
    for ([_][]const u8{ "report_icon", "skill_icon", "weapon_sound" }) |x| if (std.mem.eql(u8, n, x)) return true;
    return false;
}

/// Field `n` of a weapon archetype's block is one its Effects block edits (detail).
fn fxField(b: model_og.Block, n: []const u8) bool {
    if (b.names.len != 1 or !std.mem.eql(u8, b.e.kind, "weapon")) return false;
    for (@import("entry_attacks.zig").fx_fields) |f| if (std.mem.eql(u8, f, n)) return true;
    return false;
}

/// A weapon's ammo: `ammo = ~i"items::x"`, an item archetype
/// of the project's ammo (`type = ammo`) picked by its name, `thrown = true`, else none; the
/// pick (`none`, `thrown` or an archetype's path) when picked.
/// (Read from the catalog: a block read per item here would push the page's own parsed
/// texts out of model_og's cache while their names are in use.)
fn ammoRow(app: *App, a: Allocator, id: []const u8, file: usize, x: ?Trail) ?[]const u8 {
    const ammo = model.field(app, file, "ammo");
    const thrown_v = model.field(app, file, "thrown");
    const thrown = if (thrown_v.og_expr) |e| e.kind == .lit and e.kind.lit == .bool and e.kind.lit.bool else false;
    // The block's own `thrown` over an archetype's `ammo` (the reader applies it after).
    const path: ?[]const u8 = if (thrown_v.own and !ammo.own) null else if (ammo.og_expr) |e| schema.text(e) else null;
    var rows: std.ArrayList(picker.Opt) = .empty;
    rows.append(a, .{ .key = "none", .label = tx.get(tx.og_ammo_none), .selected = path == null and !thrown }) catch {};
    rows.append(a, .{ .key = "thrown", .label = tx.get(tx.og_ammo_thrown), .selected = path == null and thrown }) catch {};
    var shown: []const u8 = rows.items[@intFromBool(thrown)].label;
    var known = path == null;
    for (app.catalog.entries.items) |e| {
        // The catalog's ammo (catalog.useOg: an item block of `type = ammo`).
        if (e.kind != .ammo) continue;
        const label = std.fmt.allocPrint(a, "{s}", .{if (e.title.len > 0) e.title else e.id}) catch continue;
        const this = if (path) |p| std.mem.eql(u8, p, e.class) else false;
        if (this) {
            shown = label;
            known = true;
        }
        rows.append(a, .{ .key = e.class, .label = label, .note = e.class, .selected = this }) catch {};
    }
    if (!known) shown = path.?;
    gui.fieldRow(tx.get(tx.f_ammo));
    const open = picker.field(app, clay.id(id), shown, !known);
    trailOf(app, x);
    clay.close();
    if (!open) return null;
    return picker.listKey(app, a, rows.items);
}

/// A field's label: a look's lists by what they hold, the others by their name.
fn fieldLabel(n: []const u8) []const u8 {
    const pairs = .{ .{ "slots", tx.og_look_slots }, .{ "idles", tx.og_look_idles }, .{ "walk", tx.og_look_walk }, .{ "not_in_place", tx.og_look_not_in_place } };
    inline for (pairs) |p| if (std.mem.eql(u8, p[0], n)) return tx.get(p[1]);
    return n;
}

/// Fighter block `b` (file `file`) as its own Abilities row names it: an archetype by its
/// class (`characters::grandma`), a battle's fighter by its object's name (the row over
/// every other key: rules.Who.obj); `name_id` its classic_id when the block sets none.
pub fn whoOf(app: *App, a: Allocator, file: usize, b: model_og.Block, name_id: ?i32) og.rules.Who {
    const class = if (b.ns.len > 0) std.fmt.allocPrint(a, "{s}::{s}", .{ b.ns, b.names[0] }) catch b.names[0] else b.names[0];
    // Its own classic_id (a level's object of one), else the number the reader gave its path.
    const id: i32 = if (model.ownNum(app, file, "classic_id")) |v| @intFromFloat(v) else (if (b.names.len == 1) og.core.entity.idOf(class) else null) orelse name_id orelse 0;
    if (b.names.len > 1) return .{ .id = id, .obj = b.names[b.names.len - 1] };
    return .{ .id = id, .class = class };
}

/// Block file `file`'s `battle_class` (0: none).
pub fn classType(app: *App, file: usize) i32 {
    return if (model.num(model.field(app, file, "battle_class").value)) |v| @intFromFloat(v) else 0;
}

/// The fields the block or its archetype sets (the schema's order, then its own), each
/// edited by its type; "+ field" adds one of the schema's others.
fn fieldsBlockTitled(app: *App, a: Allocator, file: usize, b: model_og.Block, scope: Scope, key: []const u8, title: []const u8, folded: bool, inner: bool) void {
    const host = model_og.hostOf(b);
    const all: []const schema.Field = if (host) |h| schema.fields(a, h, true) catch &.{} else &.{};
    var shown: std.ArrayList([]const u8) = .empty;
    for (all) |s| if (model.field(app, file, s.name).og_expr != null) shown.append(a, s.name) catch {};
    // Its own fields the schema does not know (a look's `slots`: no host).
    for (b.e.fields) |f| {
        for (shown.items) |n| {
            if (std.mem.eql(u8, n, f.name)) break;
        } else shown.append(a, f.name) catch {};
    }
    // Its texts (`name`, a weapon's or item's `examine`) are nameRows' rows above.
    if (b.names.len == 1) {
        const item = std.mem.eql(u8, b.e.kind, "weapon") or std.mem.eql(u8, b.e.kind, "item");
        if (item or isFighter(b.e.kind)) {
            var k: usize = 0;
            for (shown.items) |n| if (!(std.mem.eql(u8, n, "name") or (item and std.mem.eql(u8, n, "examine")) or fxField(b, n) or ownRow(n))) {
                shown.items[k] = n;
                k += 1;
            };
            shown.shrinkRetainingCapacity(k);
        }
    }
    // A weapon's ammo row even when it sets none (ammoRow).
    if (std.mem.eql(u8, b.e.kind, "weapon")) for (shown.items) |n| {
        if (std.mem.eql(u8, n, "ammo") or std.mem.eql(u8, n, "thrown")) break;
    } else shown.append(a, "ammo") catch {};
    if (!gui.block(app, std.fmt.allocPrint(a, "{s}_fields", .{key}) catch key, title, .{ .folded = folded, .inner = inner, .summary = std.fmt.allocPrint(a, "{d}", .{shown.items.len}) catch "" })) return;
    defer gui.blockEnd();
    for (shown.items, 0..) |n, k| {
        const v = model.field(app, file, n);
        const s: ?schema.Field = if (host) |h| schema.ogField(h, n) else null;
        const id = std.fmt.allocPrint(a, "{s}/{s}", .{ key, n }) catch continue;
        // A flag (an int the exe reads as 0/1): written true/false, a switch.
        const tn = if (s) |x| (if (x.flag) "bool" else if (x.type_name.len > 0) x.type_name else typeWord(x.type)) else lookType(n);
        // Own: × at its row's end takes it out (its archetype's or the default again).
        var reset = false;
        const xid = clay.idi(std.fmt.allocPrint(a, "{s}_x", .{key}) catch key, @intCast(k));
        const trail: ?Trail = if (v.own) .{ .id = xid, .hit = &reset } else null;
        // A weapon's ammo: one row of `ammo` and `thrown` (ammoRow).
        if (std.mem.eql(u8, b.e.kind, "weapon") and (std.mem.eql(u8, n, "ammo") or std.mem.eql(u8, n, "thrown"))) {
            if (std.mem.eql(u8, n, "thrown") and model.field(app, file, "ammo").og_expr != null) continue;
            const own = v.own or model.field(app, file, "thrown").own;
            const pick = ammoRow(app, a, id, file, if (own) .{ .id = xid, .hit = &reset } else null);
            if (!own) gui.fieldNote(if (v.layer == .archetype) tx.alloc(a, tx.og_from, .{b.e.base}) else tx.get(tx.og_default), theme.dim);
            if (reset) return model_og.unset(app, file, &.{ "ammo", "thrown" }) catch |err| app.failed(err);
            if (pick) |p| return model_og.setAmmo(app, file, p) catch |err| app.failed(err);
            continue;
        }
        // A name of the rules (a weapon's class, an action, a fighter's class): picked.
        if (ruleWords(app, a, n)) |ws| {
            const cur: []const u8 = if (v.og_expr) |e| (if (e.kind == .word) e.kind.word else model_og.exprText(a, e)) else "";
            gui.fieldRow(fieldLabel(n));
            const open = picker.field(app, clay.id(id), if (cur.len > 0) cur else "—", false);
            trailOf(app, trail);
            clay.close();
            if (!v.own) gui.fieldNote(if (v.layer == .archetype) tx.alloc(a, tx.og_from, .{b.e.base}) else tx.get(tx.og_default), theme.dim);
            if (reset) return model_og.unset(app, file, &.{n}) catch |err| app.failed(err);
            if (open) if (picker.listKey(app, a, picker.names(a, ws))) |p| return model_og.set(app, file, &.{n}, p) catch |err| app.failed(err);
            continue;
        }
        // An icon (icons\\<name>.spr) or a model (<name>.msh): picked from the game's.
        if (std.mem.eql(u8, n, "icon") or std.mem.eql(u8, n, "mesh")) {
            const pick = assetRow(app, a, id, fieldLabel(n), std.mem.eql(u8, n, "icon"), v.og_expr, trail);
            if (!v.own) gui.fieldNote(if (v.layer == .archetype) tx.alloc(a, tx.og_from, .{b.e.base}) else tx.get(tx.og_default), theme.dim);
            if (reset) return model_og.unset(app, file, &.{n}) catch |err| app.failed(err);
            if (pick) |p| return model_og.set(app, file, &.{n}, std.fmt.allocPrint(a, "\"{s}\"", .{p}) catch return) catch |err| app.failed(err);
            continue;
        }
        // A reference to a block of the project (`look = looks::lamar`): picked from its folder.
        const ref_dir: ?[]const u8 = if (s) |x| switch (x.ref) {
            .weapon => "weapons",
            .item => "items",
            .look => "looks",
            .dialog => "dialogs",
            else => null,
        } else null;
        const changed = if (ref_dir) |dir| refRow(app, a, id, fieldLabel(n), dir, v.og_expr, trail) else valueRow(app, a, id, fieldLabel(n), tn, scope, v.og_expr, trail);
        if (!v.own) gui.fieldNote(if (v.layer == .archetype) tx.alloc(a, tx.og_from, .{b.e.base}) else tx.get(tx.og_default), theme.dim);
        if (reset) return model_og.unset(app, file, &.{n}) catch |err| app.failed(err);
        if (changed) |x| return model_og.setExpr(app, file, n, x) catch |err| app.failed(err);
    }
    // "+ field": a schema field it does not show yet, with its type's first value.
    if (all.len == 0) return;
    gui.fieldRow("");
    const pid = clay.id(std.fmt.allocPrint(a, "{s}_add", .{key}) catch key);
    const open = picker.field(app, pid, tx.get(tx.og_add_field), false);
    clay.close();
    if (!open) return;
    var rows: std.ArrayList(picker.Opt) = .empty;
    for (all) |s| {
        if (fxField(b, s.name)) continue;
        // Shown above (its texts), or no OpenGorky block's own (its identity is its path).
        if (b.names.len == 1 and (std.mem.eql(u8, s.name, "classic_id") or std.mem.eql(u8, s.name, "name") or std.mem.eql(u8, s.name, "examine"))) continue;
        for (shown.items) |n| {
            if (std.mem.eql(u8, n, s.name)) break;
        } else rows.append(a, .{ .key = s.name, .label = s.name, .note = if (s.type_name.len > 0) s.type_name else typeWord(s.type) }) catch {};
    }
    const pick = picker.listKey(app, a, rows.items) orelse return;
    const s = schema.ogField(host.?, pick).?;
    model_og.setExpr(app, file, pick, firstValue(app, a, if (s.type_name.len > 0) s.type_name else typeWord(s.type), scope) catch return) catch |err| app.failed(err);
}

/// A look's fields have no host schema: their prelude types by name (script/traits.zig).
fn lookType(n: []const u8) []const u8 {
    const pairs = [_][2][]const u8{ .{ "slots", "list<Slot>" }, .{ "idles", "list<Idle>" }, .{ "walk", "list<Speed>" }, .{ "not_in_place", "list<string>" } };
    for (pairs) |p| if (std.mem.eql(u8, p[0], n)) return p[1];
    return "";
}

fn typeWord(t: ir.Type) []const u8 {
    return switch (t) {
        .int => "int",
        .float => "float",
        .string => "string",
        .bool => "bool",
        else => "",
    };
}

/// The components the block attaches, each with its params edited by their types; "Remove"
/// takes one out, "+ component" attaches one of the project's for its kind.
fn attachBlock(app: *App, a: Allocator, file: usize, b: model_og.Block, key: []const u8) void {
    if (!gui.block(app, std.fmt.allocPrint(a, "{s}_attach", .{key}) catch key, tx.get(tx.og_attach), .{ .summary = std.fmt.allocPrint(a, "{d}", .{b.e.attach.len}) catch "" })) return;
    defer gui.blockEnd();
    const p = traitinfo.load(a);
    for (b.e.attach, 0..) |at, k| {
        gui.fieldRow(at.component);
        gui.spacer();
        // Its code: the component's page (its methods, its text).
        if (compOf(p, a, b, at.component)) |c| if (gui.goButton(app, clay.idi(std.fmt.allocPrint(a, "{s}_ago", .{key}) catch key, @intCast(k)))) @import("doctabs.zig").show(app, .components, c.path);
        if (gui.smallButton(app, clay.idi(std.fmt.allocPrint(a, "{s}_arm", .{key}) catch key, @intCast(k)), tx.get(tx.ab_remove))) return model_og.edit(app, file, .{ .attach = .{ .index = k, .new = null } }) catch |err| app.failed(err);
        clay.close();
        const c = compOf(p, a, b, at.component) orelse {
            gui.fieldNote(tx.alloc(a, tx.ab_script_missing, .{at.component}), theme.warn);
            continue;
        };
        const scope: Scope = .{ .module = c.it.module, .uses = c.uses };
        for (p.fields(a, c)) |f| {
            if (f.kind != .param) continue;
            const id = std.fmt.allocPrint(a, "{s}/a{d}/{s}", .{ key, k, f.name }) catch continue;
            const cur: ?*const ir.Expr = for (at.params) |x| {
                if (std.mem.eql(u8, x.name, f.name)) break x.value;
            } else f.default;
            const nv = valueRow(app, a, id, if (f.doc.len > 0) f.doc else f.name, f.type_name, scope, cur, null) orelse continue;
            var ps: std.ArrayList(ir.Named) = .empty;
            ps.appendSlice(a, at.params) catch return;
            for (ps.items) |*x| if (std.mem.eql(u8, x.name, f.name)) {
                x.value = nv;
                break;
            } else ps.append(a, .{ .name = f.name, .value = nv }) catch return;
            return model_og.edit(app, file, .{ .attach = .{ .index = k, .new = .{ .component = at.component, .params = ps.items, .line = 0 } } }) catch |err| app.failed(err);
        }
    }
    gui.fieldRow("");
    const pid = clay.id(std.fmt.allocPrint(a, "{s}_aadd", .{key}) catch key);
    const open = picker.field(app, pid, tx.get(tx.ab_add), false);
    clay.close();
    if (!open) return;
    var rows: std.ArrayList(picker.Opt) = .empty;
    for (p.comps) |c| if (forKind(c.it, b.e.kind)) rows.append(a, .{ .key = c.path, .label = c.path, .note = c.file }) catch {};
    const pick = picker.listKey(app, a, rows.items) orelse return;
    model_og.edit(app, file, .{ .attach = .{ .index = null, .new = .{ .component = pick, .params = &.{}, .line = 0 } } }) catch |err| app.failed(err);
}

/// Component path `name` as block `b`'s module names it.
fn compOf(p: traitinfo.Project, a: Allocator, b: model_og.Block, name: []const u8) ?*const traitinfo.SComp {
    if (p.comp(name)) |c| return c;
    if (b.ns.len > 0) if (p.comp(std.fmt.allocPrint(a, "{s}::{s}", .{ b.ns, name }) catch return null)) |c| return c;
    for (b.uses) |u| if (p.comp(std.fmt.allocPrint(a, "{s}::{s}", .{ u, name }) catch continue)) |c| return c;
    return null;
}

/// Component `c` may go on a block of kind `kind` (its `for` names it, or none).
fn forKind(c: *const ir.Component, kind: []const u8) bool {
    if (c.hosts.len == 0) return true;
    for (c.hosts) |h| if (std.mem.eql(u8, h, kind)) return true;
    return false;
}

/// The blocks inside it (a fighter's weapons and items, a battle's fighters), each a link
/// to its own page section below; "+ weapon", "+ item" from the archetypes.
fn innerBlock(app: *App, a: Allocator, file: usize, b: model_og.Block, key: []const u8) void {
    const fighter = isFighter(b.e.kind);
    if (b.e.children.len == 0 and !fighter) return;
    if (!gui.block(app, std.fmt.allocPrint(a, "{s}_inner", .{key}) catch key, tx.get(if (fighter) tx.og_inventory else tx.og_inner), .{ .summary = std.fmt.allocPrint(a, "{d}", .{b.e.children.len}) catch "" })) return;
    defer gui.blockEnd();
    for (b.e.children, 0..) |c, k| {
        gui.fieldRow(std.fmt.allocPrint(a, "{s} {s}", .{ c.kind, c.name }) catch c.name);
        if (c.base.len > 0) gui.txtClip(entryLabel(app, a, c.base), .caption, theme.dim, font_mod.regular);
        gui.spacer();
        // Its archetype's page (the weapon, the item, the character).
        if (c.base.len > 0) if (entryOf(app, c.base)) |i| if (gui.goButton(app, clay.idi(std.fmt.allocPrint(a, "{s}_irmgo", .{key}) catch key, @intCast(k)))) @import("entries.zig").showEntry(app, i);
        if (gui.smallButton(app, clay.idi(std.fmt.allocPrint(a, "{s}_irm", .{key}) catch key, @intCast(k)), tx.get(tx.ab_remove))) return model_og.edit(app, file, .{ .child = .{ .name = c.name, .new = null } }) catch |err| app.failed(err);
        clay.close();
        // Its fields in place (a weapon's `place`, its ammo).
        const cf = model_og.innerFile(app, file, c.name) catch continue;
        const cb = model_og.blockOf(app, a, cf) orelse continue;
        fieldsBlockTitled(app, a, cf, cb, .{ .module = cb.ns, .uses = cb.uses }, std.fmt.allocPrint(a, "{s}_i{d}", .{ key, k }) catch continue, tx.alloc(a, tx.og_inner_fields, .{c.name}), false, true);
    }
    if (!fighter) return;
    // New: a weapon or an item of the project's archetypes.
    inline for (.{ .{ "weapon", "weapons", tx.og_add_weapon }, .{ "item", "items", tx.og_add_item } }) |w| {
        gui.fieldRow("");
        const pid = clay.id(std.fmt.allocPrint(a, "{s}_add_{s}", .{ key, w[0] }) catch key);
        const open = picker.field(app, pid, tx.get(w[2]), false);
        clay.close();
        if (open) {
            var rows: std.ArrayList(picker.Opt) = .empty;
            for (app.catalog.entries.items) |e| if (std.mem.startsWith(u8, e.class, w[1] ++ "::")) rows.append(a, .{ .key = e.class, .label = if (e.title.len > 0) e.title else e.id, .note = e.class }) catch {};
            if (picker.listKey(app, a, rows.items)) |base| {
                const stem = base[std.mem.lastIndexOf(u8, base, "::").? + 2 ..];
                model_og.addInner(app, file, w[0], model_og.freeInner(a, b, stem), base) catch |err| app.failed(err);
            }
        }
    }
}

/// A level's objects (all its texts': `objects.ogs` too), each with "Remove"; a battle's
/// "+ fighter" of the project's characters (written to `objects.ogs`, model_og.addInner).
/// Their fields: picked on the map, the block's section below.
fn objectsBlock(app: *App, a: Allocator, file: usize, key: []const u8) void {
    const objs = model_og.levelObjects(app, a, file);
    const b = model_og.blockOf(app, a, file) orelse return;
    if (!gui.block(app, std.fmt.allocPrint(a, "{s}_objs", .{key}) catch key, tx.get(tx.og_objects), .{ .folded = true, .summary = std.fmt.allocPrint(a, "{d}", .{objs.len}) catch "" })) return;
    defer gui.blockEnd();
    for (objs, 0..) |c, k| {
        gui.fieldRow(std.fmt.allocPrint(a, "{s} {s}", .{ c.kind, c.name }) catch c.name);
        if (c.base.len > 0) gui.txtClip(entryLabel(app, a, c.base), .caption, theme.dim, font_mod.regular);
        gui.spacer();
        // Its archetype's page (the weapon, the item, the character).
        if (c.base.len > 0) if (entryOf(app, c.base)) |i| if (gui.goButton(app, clay.idi(std.fmt.allocPrint(a, "{s}_ormgo", .{key}) catch key, @intCast(k)))) @import("entries.zig").showEntry(app, i);
        if (gui.smallButton(app, clay.idi(std.fmt.allocPrint(a, "{s}_orm", .{key}) catch key, @intCast(k)), tx.get(tx.ab_remove))) {
            clay.close();
            const of = model_og.innerFile(app, file, c.name) catch return;
            return model_og.remove(app, of) catch |err| app.failed(err);
        }
        clay.close();
    }
    if (!std.mem.eql(u8, b.e.kind, "battle")) return;
    gui.fieldRow("");
    const pid = clay.id(std.fmt.allocPrint(a, "{s}_add_fighter", .{key}) catch key);
    const open = picker.field(app, pid, tx.get(tx.og_add_fighter), false);
    clay.close();
    if (!open) return;
    var rows: std.ArrayList(picker.Opt) = .empty;
    for (app.catalog.entries.items) |e| if ((e.kind == .enemy or e.kind == .hero) and e.class.len > 0) rows.append(a, .{ .key = e.class, .label = if (e.title.len > 0) e.title else e.id, .note = e.class }) catch {};
    const base = picker.listKey(app, a, rows.items) orelse return;
    _ = @import("level_og.zig").addFighter(app, file, base) catch |err| app.failed(err);
}

// ---------------------------------------------------------------- values by type

/// A value of type `tn` (as written: `int`, `Side`, `list<Wave>`, `character`) labelled
/// The rules' names field `n` takes (a weapon's `class`/`attack_zone`: its WeaponClass and
/// Pattern rows; `action`…: the Action rows, walk, none; `battle_class`: the fighter
/// classes its rows name); null: another field.
fn ruleWords(app: *App, a: Allocator, n: []const u8) ?[]const []const u8 {
    _ = app;
    var out: std.ArrayList([]const u8) = .empty;
    const r = og.rules.active;
    if (std.mem.eql(u8, n, "class") or std.mem.eql(u8, n, "attack_zone")) {
        for (r.weapon_classes) |x| if (x.name.len > 0) addWord(a, &out, x.name);
        for (r.patterns) |x| if (x.name.len > 0) addWord(a, &out, x.name);
    } else if (std.mem.startsWith(u8, n, "action") and (n.len == 6 or (n.len == 7 and std.ascii.isDigit(n[6])))) {
        addWord(a, &out, "walk");
        addWord(a, &out, "none");
        for (r.actions) |x| addWord(a, &out, x.name);
    } else if (std.mem.eql(u8, n, "battle_class")) {
        addWord(a, &out, "generic");
        for (r.ai_profiles) |x| if (x.class_name.len > 0) addWord(a, &out, x.class_name);
        for (og.core.modules.tables().classes) |x| if (x.class_name.len > 0) addWord(a, &out, x.class_name);
    } else return null;
    return out.items;
}

fn addWord(a: Allocator, out: *std.ArrayList([]const u8), w: []const u8) void {
    for (out.items) |x| if (std.ascii.eqlIgnoreCase(x, w)) return;
    out.append(a, w) catch {};
}

/// An `icon` (`icon_pick`: the sprites of common's `icons\\`, its picture beside) or a
/// `mesh` (the game's models) picked from a list; the name picked.
fn assetRow(app: *App, a: Allocator, id: []const u8, label: []const u8, icon_pick: bool, cur: ?*const ir.Expr, x: ?Trail) ?[]const u8 {
    const name: []const u8 = if (cur) |e| schema.text(e) orelse "" else "";
    gui.fieldRow(label);
    if (icon_pick and name.len > 0) if (app.icon(name)) |t| clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lay.height.tab), .height = clay.fixed(lay.height.tab) } }, .image = .{ .imageData = t } });
    const open = picker.field(app, clay.id(id), if (name.len > 0) name else "—", false);
    trailOf(app, x);
    clay.close();
    if (!open) return null;
    var names: std.ArrayList([]const u8) = .empty;
    if (icon_pick) {
        for (@import("sprview.zig").entries(app, a, @import("store.zig").sprite_archive)) |e| {
            if (!std.ascii.startsWithIgnoreCase(e, "icons\\")) continue;
            const base = e["icons\\".len..];
            names.append(a, if (std.ascii.endsWithIgnoreCase(base, ".spr")) base[0 .. base.len - 4] else base) catch {};
        }
    } else names.appendSlice(a, @import("look_pages.zig").models(app, a)) catch {};
    return picker.listKey(app, a, picker.names(a, names.items));
}

/// `label`, `cur` its expression now (null: none); the new expression when changed.
/// A row's × (the field's own value taken out): drawn at its end, `hit` set when clicked.
const Trail = struct { id: ui.Clay_ElementId, hit: *bool };

/// The × of `t` at the end of the row open (an empty slot without one).
fn trailOf(app: *App, t: ?Trail) void {
    if (t) |x| {
        if (gui.trail(app, x.id)) x.hit.* = true;
    }
}

fn valueRow(app: *App, a: Allocator, id: []const u8, label: []const u8, tn: []const u8, scope: Scope, cur: ?*const ir.Expr, x: ?Trail) ?*const ir.Expr {
    const p = traitinfo.load(a);
    if (std.mem.startsWith(u8, tn, "list<") and std.mem.endsWith(u8, tn, ">")) {
        const inner = tn[5 .. tn.len - 1];
        if (p.structNamed(a, scope.module, scope.uses, inner)) |st| return listRow(app, a, id, label, inner, st, scope, cur, x);
    } else if (p.enumNamed(a, scope.module, scope.uses, tn)) |en| {
        return enumRow(app, a, id, label, en, cur, x);
    } else if (p.structNamed(a, scope.module, scope.uses, tn)) |st| {
        headRow(app, label, x);
        return structFields(app, a, id, st, scope, cur);
    } else if (std.mem.eql(u8, tn, "character")) {
        return characterRow(app, a, id, label, cur, x);
    } else if (std.mem.eql(u8, tn, "bool")) {
        const on = if (cur) |e| (if (model_og.litValue(e)) |v| model.num(v) != 0 else false) else false;
        gui.fieldRow("");
        defer clay.close();
        const hit = gui.check(app, clay.id(id), on, label);
        trailOf(app, x);
        if (hit) return model_og.parseValue(a, if (on) "false" else "true") catch null;
        return null;
    }
    // Anything else typed as OG Script (a number, a "string", [5, 2]).
    gui.fieldRow(label);
    const shown = if (cur) |e| model_og.exprText(a, e) else "";
    const typed = gui.textField(app, id, shown, 0, "—");
    trailOf(app, x);
    clay.close();
    const t = typed orelse return null;
    if (std.mem.eql(u8, t, shown)) return null;
    return model_og.parseValue(a, t) catch {
        app.setStatus(tx.st_og_bad_value, .{t});
        return null;
    };
}

/// A struct's or list's title over its fields (its × at the end).
fn headRow(app: *App, label: []const u8, x: ?Trail) void {
    gui.row(lay.space.sm);
    gui.txtClip(label, .label, theme.text, font_mod.bold);
    gui.spacer();
    trailOf(app, x);
    clay.close();
}

/// An enum's value picked by its label (`Side::enemy` written `enemy`, as data takes it).
fn enumRow(app: *App, a: Allocator, id: []const u8, label: []const u8, en: *const ir.Enum, cur: ?*const ir.Expr, x: ?Trail) ?*const ir.Expr {
    // A number (an int field's enum: `type = 7`) stands for the value of that number.
    const name: []const u8 = if (cur) |e| switch (e.kind) {
        .word => |w| w[if (std.mem.lastIndexOf(u8, w, "::")) |k| k + 2 else 0..],
        .lit => |v| if (v == .int) (for (en.values) |ev| {
            if (ev.number == v.int) break ev.name;
        } else model_og.exprText(a, e)) else model_og.exprText(a, e),
        else => model_og.exprText(a, e),
    } else "";
    const shown = if (en.value(name)) |ev| enumLabel(en, ev.*) else if (name.len > 0) name else "—";
    gui.fieldRow(label);
    const open = picker.field(app, clay.id(id), shown, name.len > 0 and en.value(name) == null);
    trailOf(app, x);
    clay.close();
    if (!open) return null;
    const rows = a.alloc(picker.Opt, en.values.len) catch return null;
    for (en.values, rows) |ev, *o| o.* = .{ .label = enumLabel(en, ev), .note = ev.name, .selected = std.mem.eql(u8, ev.name, name) };
    const j = picker.list(app, a, rows) orelse return null;
    return word(a, en.values[j].name);
}

/// Value `x` of enum `en` as shown: a prelude type's in the interface language.
fn enumLabel(en: *const ir.Enum, x: ir.EnumValue) []const u8 {
    if (std.mem.eql(u8, en.file, "engine.ogs")) if (tx.preludeLabel(en.name, x.name)) |l| return l;
    return if (x.label.len > 0) x.label else x.name;
}

/// A block of the project's folder `dir` (`looks` → `looks::lamar`), picked from its texts.
fn refRow(app: *App, a: Allocator, id: []const u8, label: []const u8, dir: []const u8, cur: ?*const ir.Expr, x: ?Trail) ?*const ir.Expr {
    const name: []const u8 = if (cur) |e| model_og.exprText(a, e) else "";
    var rows: std.ArrayList(picker.Opt) = .empty;
    var known = name.len == 0;
    const og_src = @import("store.zig").og_src;
    for (app.store.files.items) |f| {
        if (!std.mem.eql(u8, f.archive, og_src) or f.entry.len <= dir.len + 5 or !std.mem.startsWith(u8, f.entry, dir) or f.entry[dir.len] != '/' or !std.mem.endsWith(u8, f.entry, ".ogs")) continue;
        const path = std.mem.replaceOwned(u8, a, f.entry[0 .. f.entry.len - 4], "/", "::") catch continue;
        const this = std.mem.eql(u8, path, name);
        known = known or this;
        rows.append(a, .{ .key = path, .label = path, .selected = this }) catch {};
    }
    gui.fieldRow(label);
    const open = picker.field(app, clay.id(id), if (name.len > 0) name else "—", !known);
    trailOf(app, x);
    clay.close();
    if (!open) return null;
    return word(a, picker.listKey(app, a, rows.items) orelse return null);
}

/// A `character` (an archetype, `~c"characters::grandma"`) picked from the characters.
fn characterRow(app: *App, a: Allocator, id: []const u8, label: []const u8, cur: ?*const ir.Expr, x: ?Trail) ?*const ir.Expr {
    const name: []const u8 = if (cur) |e| switch (e.kind) {
        .lit => |v| if (v == .string) v.string else "",
        .word => |w| w,
        else => "",
    } else "";
    gui.fieldRow(label);
    const open = picker.field(app, clay.id(id), if (name.len > 0) name else "—", false);
    trailOf(app, x);
    clay.close();
    if (!open) return null;
    var rows: std.ArrayList(picker.Opt) = .empty;
    for (app.catalog.entries.items) |e| if ((e.kind == .hero or e.kind == .enemy) and e.class.len > 0)
        rows.append(a, .{ .key = e.class, .label = if (e.title.len > 0) e.title else e.id, .note = e.class, .selected = std.mem.eql(u8, e.class, name) }) catch {};
    const pick = picker.listKey(app, a, rows.items) orelse return null;
    const e = a.create(ir.Expr) catch return null;
    e.* = .{ .line = 0, .kind = .{ .lit = .{ .string = a.dupe(u8, pick) catch return null } }, .sigil = .character };
    return e;
}

/// A struct value (`Wave(turn = 3, …)`) field by field; the new record when one changed.
fn structFields(app: *App, a: Allocator, id: []const u8, st: *const ir.Struct, scope: Scope, cur: ?*const ir.Expr) ?*const ir.Expr {
    const named: []const ir.Named = if (cur) |e| (if (e.kind == .call) e.kind.call.named else &.{}) else &.{};
    const sc: Scope = .{ .module = st.module, .uses = scope.uses };
    for (st.fields) |f| {
        const v: ?*const ir.Expr = for (named) |x| {
            if (std.mem.eql(u8, x.name, f.name)) break x.value;
        } else f.default;
        const label = if (std.mem.eql(u8, st.file, "engine.ogs")) (tx.preludeLabel(st.name, f.name) orelse f.name) else if (f.doc.len > 0) f.doc else f.name;
        const nv = valueRow(app, a, std.fmt.allocPrint(a, "{s}.{s}", .{ id, f.name }) catch continue, label, f.type_name, sc, v, null) orelse continue;
        var out: std.ArrayList(ir.Named) = .empty;
        out.appendSlice(a, named) catch return null;
        for (out.items) |*x| if (std.mem.eql(u8, x.name, f.name)) {
            x.value = nv;
            break;
        } else out.append(a, .{ .name = f.name, .value = nv }) catch return null;
        return record(a, st.name, out.items);
    }
    return null;
}

/// A `list<Struct>` (waves, slots): each element a card of its fields with ×, "+ element"
/// adds one of the fields' first values; the new list when changed.
fn listRow(app: *App, a: Allocator, id: []const u8, label: []const u8, inner: []const u8, st: *const ir.Struct, scope: Scope, cur: ?*const ir.Expr, x: ?Trail) ?*const ir.Expr {
    const items: []const *const ir.Expr = if (cur) |e| (if (e.kind == .list) e.kind.list else &.{}) else &.{};
    // An element's name: a prelude type's in the interface language ("Slot 1"), one's own as declared.
    const tname = if (std.mem.eql(u8, st.file, "engine.ogs")) tx.preludeType(st.name) orelse inner else inner;
    headRow(app, tx.alloc(a, tx.og_list_head, .{ label, items.len }), x);
    for (items, 0..) |el, k| {
        gui.fieldRow(tx.alloc(a, tx.og_elem, .{ tname, k + 1 }));
        gui.spacer();
        if (gui.smallButton(app, clay.id(std.fmt.allocPrint(a, "{s}#{d}x", .{ id, k }) catch id), tx.get(tx.ab_remove))) {
            clay.close();
            return list(a, std.mem.concat(a, *const ir.Expr, &.{ items[0..k], items[k + 1 ..] }) catch return null);
        }
        clay.close();
        if (structFields(app, a, std.fmt.allocPrint(a, "{s}#{d}", .{ id, k }) catch continue, st, scope, el)) |nv| {
            const out = a.dupe(*const ir.Expr, items) catch return null;
            out[k] = nv;
            return list(a, out);
        }
    }
    gui.fieldRow("");
    defer clay.close();
    if (gui.smallButton(app, clay.id(std.fmt.allocPrint(a, "{s}+", .{id}) catch id), tx.alloc(a, tx.og_add_elem, .{tname}))) {
        const nv = firstValue(app, a, inner, scope) catch return null;
        return list(a, std.mem.concat(a, *const ir.Expr, &.{ items, &.{nv} }) catch return null);
    }
    return null;
}

/// A first value of type `tn`: 0, "", false, an enum's first, an empty list, a record of
/// its required fields' first values (an element «+» adds, a field "+ field" adds).
fn firstValue(app: *App, a: Allocator, tn: []const u8, scope: Scope) !*const ir.Expr {
    const p = traitinfo.load(a);
    if (std.mem.startsWith(u8, tn, "list<")) return list(a, &.{}) orelse error.OutOfMemory;
    if (p.enumNamed(a, scope.module, scope.uses, tn)) |en| return word(a, if (en.values.len > 0) en.values[0].name else "") orelse error.OutOfMemory;
    if (p.structNamed(a, scope.module, scope.uses, tn)) |st| {
        var out: std.ArrayList(ir.Named) = .empty;
        for (st.fields) |f| if (f.default == null) try out.append(a, .{ .name = f.name, .value = try firstValue(app, a, f.type_name, .{ .module = st.module, .uses = scope.uses }) });
        return record(a, st.name, out.items) orelse error.OutOfMemory;
    }
    if (std.mem.eql(u8, tn, "character")) {
        for (app.catalog.entries.items) |e| if ((e.kind == .hero or e.kind == .enemy) and e.class.len > 0) {
            const x = try a.create(ir.Expr);
            x.* = .{ .line = 0, .kind = .{ .lit = .{ .string = e.class } }, .sigil = .character };
            return x;
        };
    }
    return model_og.parseValue(a, if (std.mem.eql(u8, tn, "string")) "\"\"" else if (std.mem.eql(u8, tn, "bool")) "false" else if (std.mem.eql(u8, tn, "float")) "0.0" else "0");
}

fn word(a: Allocator, w: []const u8) ?*const ir.Expr {
    const x = a.create(ir.Expr) catch return null;
    x.* = .{ .line = 0, .kind = .{ .word = w } };
    return x;
}

fn list(a: Allocator, items: []const *const ir.Expr) ?*const ir.Expr {
    const x = a.create(ir.Expr) catch return null;
    x.* = .{ .line = 0, .kind = .{ .list = items } };
    return x;
}

fn record(a: Allocator, name: []const u8, fields: []const ir.Named) ?*const ir.Expr {
    const x = a.create(ir.Expr) catch return null;
    x.* = .{ .line = 0, .kind = .{ .call = .{ .id = 0, .text = name, .args = &.{}, .named = fields } } };
    return x;
}

/// A fighter's block: `fighter` or `hero` (a hero is a fighter, host `fighter`).
fn isFighter(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "fighter") or std.mem.eql(u8, kind, "hero");
}

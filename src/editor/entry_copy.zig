//! Entries made from others (entries.zig): a copy of an enemy, item, weapon, ammo or hero
//! as the exe reads it (classic_id, party slot, own look), a new weapon with its ammo, a
//! hero's own portraits.

const std = @import("std");
const tx = @import("text.zig");
const model = @import("model.zig");
const catalog = @import("catalog.zig");
const placement = @import("placement.zig");
const common_archive = @import("store.zig").common_archive;
const og_src = @import("store.zig").og_src;
const entry_rules = @import("entry_rules.zig");
const art = @import("art.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const entries = @import("entries.zig");
const og = @import("opengorky");

const actOf = entries.actOf;
const fileOf = entries.fileOf;
const setString = entries.setString;

/// What a copy is to the exe, which keys names and rules by classic_id. `same`: the base's
/// classic_id — its name rows, strike, effects, and items stack with it; `new_id`: a fresh
/// one with its own name rows and the exe's defaults. A hero always gets a fresh one:
/// `party` in common's gamestart\ (in the party from a new game, 0x431550), `level`
/// beside its base, hidden in that level until a trigger makes it join.
pub const CopyMode = enum { same, new_id, party, level };

/// Copy of entry `idx` as the page's first button makes it (the tree's Duplicate, `--copy`).
pub fn copyEntry(app: *App, idx: usize) !void {
    return copyEntryAs(app, idx, switch (app.catalog.entries.items[idx].kind) {
        .weapon, .enemy, .attack => .same,
        .item, .ammo => .new_id,
        .hero => .party,
    });
}

/// The exe's party: 6 slots (0x6b4e78, its count right after at 0x6b4e90), filled by
/// 0x481ce0 with no check — a 7th hero overwrites the count. The game's campaign has
/// at most 5 heroes at once (fullgame.sh), and a party copy is in it from the start.
const exe_party = 6;
const game_party_peak = 5;

/// A new entry `<id>_<n>` copying entry `idx` (a mark line names its game class or hero).
/// An enemy copy gets its own look (`act_*.ss`; the model stays shared until a texture
/// or glb import makes another) but keeps the base's classic_id: the exe's monster rules
/// are by classic_id 100…139 (0x4896b0: else the hero strike, 0x48bda2), as resistances
/// (0x6d2070) and the report icon (0x523f00) are.
pub fn copyEntryAs(app: *App, idx: usize, mode: CopyMode) !void {
    const e = app.catalog.entries.items[idx];
    // No battle could take a copy: the `.wpn` swap lists the game's attacks.
    if (e.kind == .attack) return error.AttacksAreFixed;
    const fits = switch (e.kind) {
        .hero => mode == .party or (mode == .level and !std.mem.eql(u8, e.archive, common_archive)),
        .enemy => mode == .same,
        else => mode == .same or mode == .new_id,
    };
    if (!fits) return error.NotForThisKind;
    if (mode == .party and !app.ogLayout()) {
        var copies: usize = 0;
        for (app.catalog.entries.items) |x| copies += @intFromBool(x.kind == .hero and x.base != null and std.mem.eql(u8, x.archive, common_archive));
        if (game_party_peak + copies + 1 > exe_party) return error.ExePartyFull;
    }
    // OpenGorky: a block of its own beside it (`weapons::pistol_1`), named "<its name> <n>",
    // its rules by its class.
    if (app.ogLayout()) {
        const a = app.frame.allocator();
        const dir = e.class[0 .. std.mem.indexOf(u8, e.class, "::") orelse return error.NotFound];
        entry_rules.sync(app);
        const from_id = og.core.entity.idOf(e.class) orelse 0;
        const old = @import("texts.zig").get(app, a, .strings, from_id) orelse e.id;
        app.store.group();
        defer app.store.endGroup("+ {s}", .{e.id});
        const made = try ogCopy(app, e, dir, e.id, try std.fmt.allocPrint(a, "{s} {{d}}", .{old}));
        app.refreshTitles();
        try entry_rules.writeOwn(app, .{ .id = from_id, .class = e.class }, .{ .id = made.nid, .class = app.catalog.entries.items[made.entry].class }, false);
        return;
    }
    const file = fileOf(app, e) orelse return error.NotFound;
    const a = app.frame.allocator();
    var text = app.store.text(file);
    // A copy of a copy names the game class too.
    if (std.mem.startsWith(u8, text, catalog.copy_mark)) text = text[(std.mem.indexOfScalar(u8, text, '\n') orelse text.len - 1) + 1 ..];
    const base = e.base orelse e.id;
    var id_buf: [96]u8 = undefined;
    var n: usize = 2;
    const id = while (n < 1000) : (n += 1) {
        const s = try std.fmt.bufPrint(&id_buf, "{s}_{d}", .{ base, n });
        if (!app.catalog.has(e.kind, s)) break s;
    } else return error.NoFreeName;
    // The class, its look, name rows and rules: one undo step.
    app.store.group();
    defer app.store.endGroup("+ {s}", .{id});
    var name_id = e.name_id;
    var vb: [96]u8 = undefined;
    // OpenGorky: every copy its own classic_id (its texts only), its rules by its class.
    if (mode != .same or app.ogLayout()) {
        const nid = entry_rules.freshClassicId(app);
        text = try model.setIn(a, text, "classic_id", try std.fmt.bufPrint(&vb, "{d}", .{nid}), "{");
        name_id = nid;
    }
    // In the party from the start: the exe's party is the heroes without it (0x481ce0).
    if (mode == .party) text = try model.setIn(a, text, "outside_party", "0", "{");
    if (e.kind == .enemy) {
        const act = actOf(text) orelse return error.NoLook;
        const act_text = app.store.text(try app.store.file(common_archive, try std.fmt.bufPrint(&vb, "classes\\{s}", .{act})));
        const own = try art.newAct(app, act, model.getStr(act_text, "mesh") orelse return error.NoModel);
        const p = @intFromPtr(act.ptr) - @intFromPtr(text.ptr);
        text = try std.mem.concat(a, u8, &.{ text[0..p], own, text[p + act.len ..] });
    }
    const into = if (mode == .party or e.kind != .hero) common_archive else e.archive;
    const nt = try std.fmt.allocPrint(app.gpa, "{s}{s}{s}{s}{s}{s}", .{ catalog.copy_mark, catalog.prefix(e.kind), base, catalog.ext(e.kind), placement.newline(text), text });
    // The Store owns it once added: freed only on the way there (a later error double-freed it).
    const ne = app.catalog.addCopy(e, id, into, name_id) catch |err| {
        app.gpa.free(nt);
        return err;
    };
    _ = app.store.addNew(&.{.{ .archive = into, .entry = ne.entry, .text = nt }}) catch |err| {
        app.gpa.free(nt);
        return err;
    };
    if (mode == .level) {
        // Hidden in its level until a trigger shows it (Hero joins the party).
        const level = into[0 .. into.len - "/other.dat".len];
        const lev = try app.store.file(into, try std.fmt.bufPrint(&vb, "{s}.lev", .{level}));
        try app.store.replace(lev, try @import("trigger.zig").hideHero(app.gpa, app.store.text(lev), id));
    }
    // Its own name rows, the base's texts with the number.
    if (name_id != e.name_id) {
        const texts = @import("texts.zig");
        const old: i32 = e.name_id orelse 0;
        try texts.set(app, .strings, name_id.?, try std.fmt.allocPrint(a, "{s} {d}", .{ texts.get(app, a, .strings, old) orelse base, n }));
        if (texts.get(app, a, .items, old)) |d| try texts.set(app, .items, name_id.?, d);
        app.refreshTitles();
    }
    if (app.ogLayout()) try entry_rules.writeOwn(app, .{ .id = e.name_id orelse 0, .class = entry_rules.classOf(e) }, .{ .id = name_id orelse 0, .class = entry_rules.classOf(ne) }, false);
    entries.showEntry(app, app.catalog.entries.items.len - 1);
    app.setStatus(tx.st_copied, .{ ne.entry, base });
}

/// A new weapon from no other (`classes\cw_new_weapon_<n>.s`): a firearm (the rifle's
/// model, icon and numbers: the exe strikes a classic_id it doesn't know with attack_rifle,
/// 0x48bda2) with its own ammo (`classes\ca_new_weapon_<n>_ammo.s`, the rifle ammo's icon,
/// `ammo` naming it), fresh classic_ids (≥ 2000: the exe's defaults, no rules of its own —
/// flash and sound as a classic_id it doesn't know) and their name rows; then edited as any
/// (OpenGorky: its strike animation picked or another weapon's strike forked). Classic
/// and OpenGorky alike.
pub fn newWeapon(app: *App) !void {
    // OpenGorky: a copy of the rifle's archetype (src/weapons/new_weapon_<n>.ogs) with its
    // own ammo, a copy of the rifle's (src/items/new_weapon_<n>_ammo.ogs, as
    // Classic); its page's ammo field picks any other ammo of the project.
    if (app.store.root != null) {
        const tpl = for (app.catalog.entries.items) |x| {
            if (x.kind == .weapon and std.mem.eql(u8, x.id, "riffle")) break x;
        } else for (app.catalog.entries.items) |x| {
            if (x.kind == .weapon) break x;
        } else return error.NoWeapons;
        const a = app.frame.allocator();
        app.store.group();
        defer app.store.endGroup("+ {s}", .{"new_weapon"});
        const made = try ogCopy(app, tpl, "weapons", "new_weapon", tx.gameText(app.catalog.cyrillic, tx.game_new_weapon));
        const n = std.fmt.parseInt(usize, made.id["new_weapon_".len..], 10) catch 1;
        app.refreshTitles();
        if (ogAmmoFile(app, made.file)) |af| {
            const ammo = try ogClone(app, af, "items", try std.fmt.allocPrint(a, "{s}_ammo", .{made.id}), tx.game(a, app.catalog.cyrillic, tx.game_new_ammo, .{n}));
            try model.model_og.setAmmo(app, made.file, try std.fmt.allocPrint(a, "items::{s}", .{ammo}));
            catalog.useOg(&app.catalog, &app.store);
            app.refreshTitles();
            entries.showEntry(app, app.catalog.byKey(og_src, app.store.files.items[made.file].entry) orelse return);
            app.setStatus(tx.st_weapon_new_og, .{ app.store.files.items[made.file].entry, ammo });
        }
        return;
    }
    var id_buf: [64]u8 = undefined;
    var n: usize = 1;
    const id = while (n < 1000) : (n += 1) {
        const s = try std.fmt.bufPrint(&id_buf, "new_weapon_{d}", .{n});
        if (!app.catalog.has(.weapon, s)) break s;
    } else return error.NoFreeName;
    app.store.group();
    defer app.store.endGroup("+ {s}", .{id});
    // Its ammo first (the weapon names its classic_id; its name row keeps it from the weapon's).
    const ammo_nid = try newAmmo(app, try std.fmt.allocPrint(app.frame.allocator(), "{s}_ammo", .{id}), n);
    const nid = entry_rules.freshClassicId(app);
    const text = try std.fmt.allocPrint(app.gpa,
        \\#include Weapon.s
        \\
        \\
        \\function class_init()
        \\{{
        \\  nameID={d};
        \\  funcID=3; // Take
        \\
        \\  spriteFile="riffle";
        \\  meshFile="riffle";
        \\
        \\  ammoUsed={d};
        \\
        \\  Owner="";
        \\  place=-1;
        \\  two_handed=1;
        \\
        \\    classType = 2;
        \\    max_damage = 25;
        \\    type = 6;
        \\
        \\    lightArmor = 0;
        \\    mediumArmor = 10;
        \\    heavyArmor = 15;
        \\}};
        \\
        \\function Take(string hero)
        \\{{
        \\  Owner = hero;
        \\  place = 1;
        \\}};
        \\
    , .{ nid, ammo_nid });
    defer app.gpa.free(text);
    // The game's scripts are CRLF.
    const crlf = try std.mem.replaceOwned(u8, app.gpa, text, "\n", "\r\n");
    errdefer app.gpa.free(crlf);
    // The catalog's entry shape of a weapon (its fields are replaced below).
    const of = for (app.catalog.entries.items) |x| {
        if (x.kind == .weapon) break x;
    } else return error.NoWeapons;
    var ne = try app.catalog.addCopy(of, id, common_archive, nid);
    ne.base = null;
    ne.title = "";
    app.catalog.entries.items[app.catalog.entries.items.len - 1] = ne;
    _ = try app.store.addNew(&.{.{ .archive = common_archive, .entry = ne.entry, .text = crlf }});
    try @import("texts.zig").set(app, .strings, nid, tx.game(app.frame.allocator(), app.catalog.cyrillic, tx.game_new_weapon, .{n}));
    app.refreshTitles();
    entries.showEntry(app, app.catalog.entries.items.len - 1);
    app.setStatus(tx.st_copied, .{ ne.entry, "—" });
}

/// The fighter a new character starts as: an ordinary enemy archetype with a look (its
/// own or its `same_as` block's; no classType: generic AI), else the first with a look.
fn template(app: *App) !usize {
    var first: ?usize = null;
    for (app.catalog.entries.items, 0..) |x, i| if (x.kind == .enemy) {
        const f = app.store.file(x.archive, x.entry) catch continue;
        if (model.field(app, f, "look").og_expr == null) {
            const sv = model.field(app, f, "same_as").og_expr orelse continue;
            if (sv.kind != .word) continue;
            const tf = model.model_og.archetypeFile(app, og.script.ir.Import.of(sv.kind.word).path) orelse continue;
            if (model.field(app, tf, "look").og_expr == null) continue;
        }
        if (model.num(model.field(app, f, "battle_class").value) orelse 0 == 0) return i;
        if (first == null) first = i;
    };
    return first orelse error.NoTemplate;
}

/// A new character from no other (OpenGorky): `src/characters/new_character_<n>.ogs`, a
/// copy of the template fighter's archetype (model, animations, numbers) with its own look
/// (`src/looks/new_character_<n>.ogs`, the template's), a fresh classic_id, its rules by its
/// class cloned from the template's (its strikes), its own Abilities row (its abilities
/// apart from its classType's) and its roles row (an enemy); then its page. Battles place
/// it (a fighter block of it), the test room fights it.
pub fn newCharacter(app: *App) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const tpl = app.catalog.entries.items[try template(app)];
    const a = app.frame.allocator();
    app.store.group();
    defer app.store.endGroup("+ {s}", .{"new_character"});
    const made = try ogCopy(app, tpl, "characters", "new_character", tx.gameText(app.catalog.cyrillic, tx.game_new_char));
    app.refreshTitles();
    // Its own look: the template's, copied under its name.
    if (model.field(app, made.file, "look").og_expr) |le| if (le.kind == .word) if (model.model_og.archetypeFile(app, le.kind.word)) |lf| {
        const look = try ogClone(app, lf, "looks", made.id, null);
        try model.model_og.set(app, made.file, &.{"look"}, try std.fmt.allocPrint(a, "looks::{s}", .{look}));
    };
    const ne = app.catalog.entries.items[made.entry];
    // Its rules: the template's strikes (and the rest) by its class, its own behaviour, its roles.
    // Its number: its classic_id, else the OG reader's (a converted project's: by its path).
    entry_rules.sync(app);
    const from_class = entry_rules.classOf(tpl);
    const from: og.rules.Who = .{ .id = tpl.name_id orelse og.core.entity.idOf(from_class) orelse 0, .class = from_class };
    try entry_rules.writeOwn(app, from, .{ .id = made.nid, .class = ne.class }, false);
    const tf = try app.store.file(tpl.archive, tpl.entry);
    try @import("char_abilities.zig").ownRow(app, og.core.modules.abilities(from, @intFromFloat(model.num(model.field(app, tf, "battle_class").value) orelse 0)).*, ne.class);
    try @import("rules_rows.zig").put(app, og.rules.Character, .{ .fighter_class = ne.class, .as_enemy = true });
    app.setStatus(tx.st_char_new, .{ne.entry});
}

/// A new archetype made by `ogCopy`: its Store file, catalog entry, name, the OG reader's number.
const Made = struct { file: usize, entry: usize, id: []const u8, nid: i32 };

/// OpenGorky: a new archetype `<dir>::<stem>_<n>` (`src/<dir>/<stem>_<n>.ogs`), a copy of
/// archetype entry `tpl`'s block with a fresh classic_id; the catalog read again, it shown.
fn ogCopy(app: *App, tpl: catalog.Entry, dir: []const u8, stem: []const u8, title: ?[]const u8) !Made {
    const a = app.frame.allocator();
    var n: usize = 1;
    const id = while (n < 1000) : (n += 1) {
        const s = try std.fmt.allocPrint(app.catalog.arena.allocator(), "{s}_{d}", .{ stem, n });
        if (!app.catalog.has(tpl.kind, s) and !ogTaken(app, dir, s)) break s;
    } else return error.NoFreeName;
    // Its name: `title` with its number (`{d}`).
    const name = if (title) |t| try std.mem.replaceOwned(u8, a, t, "{d}", try std.fmt.allocPrint(a, "{d}", .{n})) else null;
    _ = try ogClone(app, try app.store.file(tpl.archive, tpl.entry), dir, id, name);
    catalog.useOg(&app.catalog, &app.store);
    app.refreshTitles();
    const path = try std.fmt.allocPrint(a, "{s}/{s}.ogs", .{ dir, id });
    const k = app.catalog.byKey(og_src, path) orelse return error.NotFound;
    entries.showEntry(app, k);
    app.setStatus(tx.st_copied, .{ path, tpl.id });
    entry_rules.sync(app);
    return .{ .file = try app.store.file(og_src, path), .entry = k, .id = id, .nid = og.core.entity.idOf(try std.fmt.allocPrint(a, "{s}::{s}", .{ dir, id })) orelse 0 };
}

/// OpenGorky: the ammo archetype weapon block file `weapon` uses (its `ammo`); null: none
/// (a melee or thrown weapon).
fn ogAmmoFile(app: *App, weapon: usize) ?usize {
    const e = model.field(app, weapon, "ammo").og_expr orelse return null;
    return model.model_og.archetypeFile(app, og.core.schema.text(e) orelse return null);
}

/// `src/<dir>/<name>.ogs` is there already (in the Store or on disk).
fn ogTaken(app: *App, dir: []const u8, name: []const u8) bool {
    const path = std.fmt.allocPrint(app.frame.allocator(), "{s}/{s}.ogs", .{ dir, name }) catch return true;
    if (app.store.find(og_src, path)) |f| return !app.store.files.items[f].deleted;
    _ = app.store.file(og_src, path) catch return false;
    return true;
}

/// Block file `from`'s main block (as written, its comments too) as the new file
/// `src/<dir>/<name>.ogs`: `module <dir> { <kind> <name> … }`, a thing of its own (no
/// classic_id, no `same_as`: the OG reader numbers it by its path), named `title` (its
/// `name`; null: as it is). Returns `name`.
fn ogClone(app: *App, from: usize, dir: []const u8, name: []const u8, title: ?[]const u8) ![]const u8 {
    const a = app.frame.allocator();
    const b = model.model_og.blockOf(app, a, from) orelse return error.NoSuchBlock;
    const t = app.store.text(b.text_file);
    const body = t[b.e.span.start..@min(t.len, b.e.span.end)];
    // `<kind> <name>`: the name a word or a "string".
    var at = b.e.kind.len;
    while (at < body.len and body[at] == ' ') at += 1;
    var end = at;
    if (end < body.len and body[end] == '"') {
        end = (std.mem.indexOfScalarPos(u8, body, end + 1, '"') orelse return error.NoSuchBlock) + 1;
    } else while (end < body.len and (std.ascii.isAlphanumeric(body[end]) or body[end] == '_')) end += 1;
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "module {s} {{\n    {s}{s}", .{ dir, body[0..at], name });
    // Its other lines one level in when it was at the root (the module's own depth).
    var it = std.mem.splitScalar(u8, body[end..], '\n');
    try out.appendSlice(a, it.first());
    while (it.next()) |l| try out.print(a, "\n{s}{s}", .{ if (b.ns.len == 0 and l.len > 0) "    " else "", l });
    try out.appendSlice(a, "\n}\n");
    const path = try std.fmt.allocPrint(a, "{s}/{s}.ogs", .{ dir, name });
    const f = try app.store.addNew(&.{.{ .archive = og_src, .entry = path, .text = try app.gpa.dupe(u8, out.items) }});
    try ownSameAs(app, a, f, b.e.*);
    try model.model_og.unset(app, f, &.{ "classic_id", "same_as" });
    if (title) |tt| {
        var w: std.Io.Writer.Allocating = .init(a);
        try og.script.ogs.lexer.writeString(&w.writer, tt);
        try model.model_og.set(app, f, &.{"name"}, w.written());
    }
    return name;
}

/// What block `e` (copied into Store file `f`) takes from its `same_as` block (`import X;`,
/// schema.sameAsOf: values, texts, rows by the group) written into the copy, which is a
/// thing of its own: the nearest in that block's chain, none `e` or its archetypes set.
fn ownSameAs(app: *App, a: std.mem.Allocator, f: usize, e: og.script.ir.Entity) !void {
    const v = for (e.fields) |x| {
        if (std.mem.eql(u8, x.name, "same_as")) break x.value;
    } else return;
    if (v.kind != .word) return;
    var done: std.ArrayList([]const u8) = .empty;
    var at = model.model_og.archetypeFile(app, og.script.ir.Import.of(v.kind.word).path);
    var depth: u32 = 0;
    while (at) |tf| : (depth += 1) {
        const tb = model.model_og.blockOf(app, a, tf) orelse break;
        for (tb.e.fields) |x| {
            if (og.core.schema.sameAsOf(e.kind, x.name) == .no or sets(app, a, e, x.name, 0)) continue;
            const seen = for (done.items) |d| {
                if (std.mem.eql(u8, d, x.name)) break true;
            } else false;
            if (seen) continue;
            try done.append(a, x.name);
            try model.model_og.set(app, f, &.{x.name}, model.model_og.exprText(a, x.value));
        }
        if (tb.e.base.len == 0 or depth > 16) break;
        at = model.model_og.archetypeFile(app, tb.e.base);
    }
}

/// Block `e` or its archetypes set field `n`.
fn sets(app: *App, a: std.mem.Allocator, e: og.script.ir.Entity, n: []const u8, depth: u32) bool {
    for (e.fields) |x| if (std.mem.eql(u8, x.name, n)) return true;
    if (e.base.len == 0 or depth > 16) return false;
    const b = model.model_og.blockOf(app, a, model.model_og.archetypeFile(app, e.base) orelse return false) orelse return false;
    return sets(app, a, b.e.*, n, depth + 1);
}

/// The new weapon's ammo `classes\ca_<id>.s` (the rifle ammo's icon, 6 a pack) with a
/// fresh classic_id and its name row; returns that classic_id.
fn newAmmo(app: *App, id: []const u8, n: usize) !i32 {
    const nid = entry_rules.freshClassicId(app);
    const text = try std.fmt.allocPrint(app.gpa, "#include Item.s\r\n\r\n\r\nfunction class_init()\r\n{{\r\n  nameID={d};\r\n  funcID=3; // Take\r\n\r\n  spriteFile=\"RiffleAmmo\";\r\n\r\n  type = 10;\r\n  Owner=\"\";\r\n  place=-1;\r\n\r\n  counter = 6;\r\n}};\r\n", .{nid});
    errdefer app.gpa.free(text);
    const of = for (app.catalog.entries.items) |x| {
        if (x.kind == .ammo) break x;
    } else return error.NoAmmo;
    var ne = try app.catalog.addCopy(of, id, common_archive, nid);
    ne.base = null;
    ne.title = "";
    app.catalog.entries.items[app.catalog.entries.items.len - 1] = ne;
    _ = try app.store.addNew(&.{.{ .archive = common_archive, .entry = ne.entry, .text = text }});
    try @import("texts.zig").set(app, .strings, nid, tx.game(app.frame.allocator(), app.catalog.cyrillic, tx.game_new_ammo, .{n}));
    return nid;
}

/// The hero's portraits (`icons\<spriteFile>.spr`) copied under the hero's name, so they
/// are painted apart from its base's (the sprite page).
pub fn ownPortraits(app: *App, idx: usize) !void {
    const e = app.catalog.entries.items[idx];
    const file = fileOf(app, e) orelse return error.NotFound;
    const old = model.getStr(app.store.text(file), "portrait") orelse return error.NoPortraits;
    const sprites = @import("store.zig").sprite_archive;
    var ob: [96]u8 = undefined;
    var nb: [96]u8 = undefined;
    const src = try std.fmt.bufPrint(&ob, "icons\\{s}.spr", .{old});
    const entry = try std.fmt.bufPrint(&nb, "icons\\{s}.spr", .{e.id});
    if (app.store.find(sprites, entry) != null) return error.Taken;
    for (app.catalog.icons.items) |x| if (std.ascii.eqlIgnoreCase(x, e.id)) return error.Taken;
    const bytes = try app.gpa.dupe(u8, app.store.text(app.store.find(sprites, src) orelse try app.store.file(sprites, src)));
    errdefer app.gpa.free(bytes);
    app.store.group();
    defer app.store.endGroup("+ {s}", .{entry});
    _ = try app.store.addNew(&.{.{ .archive = sprites, .entry = entry, .text = bytes }});
    try app.catalog.icons.append(app.catalog.arena.allocator(), try app.catalog.arena.allocator().dupe(u8, e.id));
    try setString(app, file, "portrait", e.id);
    app.setStatus(tx.st_portraits_copied, .{entry});
}

/// Where else the project names OpenGorky entry `key`'s block (`characters::sullivan`):
/// the first other text of src/ that does (null: none, it can go).
/// shortcut: a text match of its class; a bare name inside its own module is not found.
pub fn ogUsedIn(app: *App, key: []const u8) ?[]const u8 {
    const i = entries.entryByKey(app, key) catch return null;
    const e = app.catalog.entries.items[i];
    const a = app.frame.allocator();
    for (app.store.listing(a, og_src, null, false)) |path| {
        if (std.ascii.eqlIgnoreCase(path, e.entry) or !std.mem.endsWith(u8, path, ".ogs")) continue;
        const f = app.store.file(og_src, path) catch continue;
        const t = app.store.text(f);
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, t, from, e.class)) |k| : (from = k + 1) {
            const end = k + e.class.len;
            // Not a longer name (`characters::sullivan_2`).
            if (end < t.len and (std.ascii.isAlphanumeric(t[end]) or t[end] == '_')) continue;
            return path;
        }
    }
    return null;
}

/// OpenGorky entry `key` (`src|characters/x.ogs`) deleted: its file (one undo step;
/// saving takes it out of src/), its tab closed without asking.
pub fn deleteOg(app: *App, key: []const u8) !void {
    const i = try entries.entryByKey(app, key);
    const e = app.catalog.entries.items[i];
    const f = try app.store.file(e.archive, e.entry);
    const label = try app.frame.allocator().dupe(u8, if (e.title.len > 0) e.title else e.id);
    if (@import("doctabs.zig").isShown(app, @import("kinds.zig").tabOf(e.kind), key)) @import("doctabs.zig").dropActive(app);
    try app.store.delete(&.{f});
    // Read again keeping the entry shown by its key (gone: none shown until its tab closes).
    app.rebuildCatalog();
    app.setStatus(tx.st_entry_deleted, .{label});
}

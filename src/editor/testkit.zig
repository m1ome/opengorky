//! OpenGorky's test kit: what the test room's heroes (testroom.zig) go in with — weapons
//! in hand or in the backpack, ammo, items — and the enemy's weapon, edited on a page of
//! its own (the editor's, one for every In battle; the asset tree's row by the Reference). An editor file beside the room, `og_testkit.txt`
//! of `og__testroom/other.dat` (the room's folder: in no level list; the room's make
//! keeps it), one line a thing:
//! `enemy <wp_class>`, `<hero> <class file> <count> [hand]` (count: an ammo's rounds,
//! else units). testroom.make turns them into the room's restore() calls: the
//! campaign's heroes and saves never change.
//!
//! An OpenGorky project keeps it in `.og/testkit.txt` (beside its history: never built
//! into its package): its heroes one by one (`hero sullivan`, `hero ovitz off`: not in the
//! test room), their things archetypes (`sullivan weapons::shotgun 1 hand`), the test
//! room's enemy (`fighter characters::grandma`, its own weapons). None yet: the game's
//! party with the things their OnStart gives (`defaults`). A battle played from the editor
//! (the test room too) is built with it (compose/og/build.zig Kit): the heroes carry the
//! kit's things in place of their start's; the room has the ticked heroes only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const picker = @import("picker.zig");
const boxpanel = @import("boxpanel.zig");
const rulespages = @import("rulespages.zig");
const ea = @import("entry_attacks.zig");
const store_mod = @import("store.zig");
const common_archive = store_mod.common_archive;
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const lay = @import("layout.zig");

pub const archive = @import("level_templates.zig").test_room ++ "/other.dat";
pub const entry = "og_testkit.txt";
/// The room's character on the heroes' side (testroom.zig, as_hero).
pub const extra = "og_test_hero";

const Row = struct { hero: []const u8, class: []const u8, count: i32 = 1, hand: bool = false };
/// A hero of the kit (OpenGorky): its catalog id; `on`: in the test room.
const Hero = struct { id: []const u8, on: bool = true };
const Kit = struct { enemy: ?[]const u8 = null, rows: []Row = &.{}, heroes: []Hero = &.{}, fighter: ?[]const u8 = null };

/// The kit of `text` (lines it can't read are skipped).
fn parse(a: Allocator, text: []const u8) Kit {
    var kit: Kit = .{};
    var rows: std.ArrayList(Row) = .empty;
    var heroes: std.ArrayList(Hero) = .empty;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |l| {
        var it = std.mem.tokenizeAny(u8, l, " \t");
        const who = it.next() orelse continue;
        const class = it.next() orelse continue;
        if (std.mem.eql(u8, who, "enemy")) {
            kit.enemy = class;
            continue;
        }
        if (std.mem.eql(u8, who, "fighter")) {
            kit.fighter = class;
            continue;
        }
        if (std.mem.eql(u8, who, "hero")) {
            const off = if (it.next()) |x| std.mem.eql(u8, x, "off") else false;
            heroes.append(a, .{ .id = class, .on = !off }) catch {};
            continue;
        }
        var r: Row = .{ .hero = who, .class = class };
        if (it.next()) |n| r.count = std.fmt.parseInt(i32, n, 10) catch 1;
        r.hand = if (it.next()) |h| std.mem.eql(u8, h, "hand") else false;
        rows.append(a, r) catch {};
    }
    kit.rows = rows.items;
    kit.heroes = heroes.items;
    return kit;
}

fn format(a: Allocator, kit: Kit) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    if (kit.enemy) |w| try out.print(a, "enemy {s}\r\n", .{w});
    if (kit.fighter) |w| try out.print(a, "fighter {s}\r\n", .{w});
    for (kit.heroes) |h| try out.print(a, "hero {s}{s}\r\n", .{ h.id, if (h.on) "" else " off" });
    for (kit.rows) |r| try out.print(a, "{s} {s} {d}{s}\r\n", .{ r.hero, r.class, r.count, if (r.hand) " hand" else "" });
    return out.items;
}

/// The script lines giving the kit's things to the heroes (in the room's restore():
/// the heroes are there, their own post_init still to come): `og_tk_<n>` objects, a
/// hand weapon put in hand (place 11), ammo one stack of `count` rounds.
pub fn calls(a: Allocator, kit: Kit) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    for (kit.rows) |r| {
        const weapon = std.ascii.startsWithIgnoreCase(r.class, "cw_");
        const ammo = std.ascii.startsWithIgnoreCase(r.class, "ca_");
        const units: usize = if (ammo) 1 else @intCast(@max(1, r.count));
        for (0..units) |k| {
            n += 1;
            try out.print(a, "    {s}(\"og_tk_{d}\", \"{s}\", \"{s}\"", .{ if (weapon) "Weapon_New" else "Item_New", n, r.class, r.hero });
            if (ammo) try out.print(a, ", {d}", .{r.count});
            try out.appendSlice(a, ");\r\n");
            if (r.hand and weapon and k == 0) try out.print(a, "    Item_SetPlace(\"og_tk_{d}\", 11);\r\n", .{n});
        }
    }
    return out.items;
}

/// The kit's file in an OpenGorky project (Store archive `og_meta`).
const og_entry = "testkit.txt";

/// The kit file's Store archive and entry.
fn where(app: *App) [2][]const u8 {
    return if (app.store.root != null) .{ store_mod.og_meta, og_entry } else .{ archive, entry };
}

/// The kit file's Store index; null: none yet.
pub fn fileIndex(app: *App) ?usize {
    const w = where(app);
    return app.store.file(w[0], w[1]) catch null;
}

/// OpenGorky: the kit's things as blocks of the test room's battle, each its hero's
/// (`owner`): a weapon `place = hand` or in the backpack, an ammo (an archetype of `ammo`,
/// `ammoPaths`) one stack of `count` rounds, an item `count` of them; `og_tk_<n>` as the
/// Classic room's.
fn ogBlocks(a: Allocator, kit: Kit, ammo_paths: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    for (kit.rows) |r| {
        const weapon = std.mem.startsWith(u8, r.class, "weapons::");
        const ammo = for (ammo_paths) |p| {
            if (std.ascii.eqlIgnoreCase(p, r.class)) break true;
        } else false;
        const units: usize = if (ammo) 1 else @intCast(@max(1, r.count));
        for (0..units) |k| {
            n += 1;
            try out.print(a, "{s} og_tk_{d}: {s} {{\n    owner = \"{s}\";\n    place = {s};\n", .{ if (weapon) "weapon" else "item", n, r.class, r.hero, if (r.hand and weapon and k == 0) "hand" else "backpack" });
            if (ammo) try out.print(a, "    count = {d};\n", .{r.count});
            try out.appendSlice(a, "}\n");
        }
    }
    return out.items;
}

/// The project's ammo archetypes (`items::shotgun_ammo`: the catalog's, `kind = ammo`).
fn ammoPaths(app: *App, a: Allocator) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (app.catalog.entries.items) |e| if (e.kind == .ammo and std.mem.indexOf(u8, e.class, "::") != null) out.append(a, e.class) catch {};
    return out.items;
}

/// Kit row class `class` is ammo / a weapon: an OpenGorky archetype's path by its catalog
/// entry (archetypes have no kind prefix), a Classic class file by its
/// prefix (`ca_`, `cw_`).
fn isAmmo(app: *App, class: []const u8) bool {
    if (std.mem.indexOf(u8, class, "::") != null) return kindOf(app, class) == .ammo;
    return std.ascii.startsWithIgnoreCase(class, "ca_");
}

fn isWeapon(class: []const u8) bool {
    if (std.mem.indexOf(u8, class, "::") != null) return std.mem.startsWith(u8, class, "weapons::");
    return std.ascii.startsWithIgnoreCase(class, "cw_");
}

fn kindOf(app: *App, class: []const u8) ?@import("catalog.zig").Kind {
    for (app.catalog.entries.items) |e| if (std.ascii.eqlIgnoreCase(e.class, class)) return e.kind;
    return null;
}

/// The kit as saved (none: empty).
pub fn load(app: *App, a: Allocator) Kit {
    const i = fileIndex(app) orelse return if (app.store.root != null) defaults(app, a) else .{};
    var kit = parse(a, app.store.text(i));
    // An older kit (no hero lines): its rows' heroes.
    if (app.store.root != null and kit.heroes.len == 0) {
        var hs: std.ArrayList(Hero) = .empty;
        for (kit.rows) |r| {
            for (hs.items) |h| {
                if (std.ascii.eqlIgnoreCase(h.id, r.hero)) break;
            } else hs.append(a, .{ .id = r.hero }) catch {};
        }
        kit.heroes = hs.items;
    }
    return kit;
}

/// OpenGorky's kit before any change: the game's party (`game.party`) with the things
/// each one's OnStart gives (`item::New("su_food", "items::food", "Sullivan")`, a count
/// after), one row per archetype; the first weapon taking ammo in hand.
fn defaults(app: *App, a: Allocator) Kit {
    var heroes: std.ArrayList(Hero) = .empty;
    var rows: std.ArrayList(Row) = .empty;
    const game = app.store.file(store_mod.og_src, "game.ogs") catch return .{};
    const list = @import("model.zig").field(app, game, "party").og_expr orelse return .{};
    if (list.kind != .list) return .{};
    for (list.kind.list) |x| {
        if (x.kind != .word) continue;
        const p = x.kind.word;
        const id = p[if (std.mem.lastIndexOf(u8, p, "::")) |k| k + 2 else 0..];
        const e = entryOf(app, id) orelse continue;
        heroes.append(a, .{ .id = e.id }) catch continue;
        heroRows(app, a, e, &rows);
    }
    return .{ .heroes = heroes.items, .rows = rows.items };
}

/// Hero `e`'s things onto `rows`: what its OnStart gives (`item::New…`), else the weapons
/// nested in its file's blocks (`weapon la: weapons::medusalong { place = hand; }`: Medusa's,
/// given by the battle that has her, none by a start).
fn heroRows(app: *App, a: Allocator, e: @import("catalog.zig").Entry, rows: *std.ArrayList(Row)) void {
    const text = app.store.text(@import("entries.zig").fileOf(app, e) orelse return);
    const before = rows.items.len;
    if (std.mem.indexOf(u8, text, "fn OnStart(")) |start| {
        const end = std.mem.indexOfPos(u8, text, start, "\n        }") orelse text.len;
        var hand = false;
        var lines = std.mem.tokenizeScalar(u8, text[start..end], '\n');
        while (lines.next()) |l| {
            const weapon = std.mem.indexOf(u8, l, "item::NewWeapon(") != null;
            if (!weapon and std.mem.indexOf(u8, l, "item::New(") == null) continue;
            var args = std.mem.tokenizeAny(u8, l[std.mem.indexOfScalar(u8, l, '(').? + 1 ..], ",); ");
            _ = args.next() orelse continue;
            const class = std.mem.trim(u8, args.next() orelse continue, "\"");
            _ = args.next();
            const n: i32 = if (args.next()) |c| std.fmt.parseInt(i32, c, 10) catch 1 else 1;
            const ammo = isAmmo(app, class);
            const last = if (rows.items.len > before) &rows.items[rows.items.len - 1] else null;
            if (!ammo and last != null and std.mem.eql(u8, last.?.class, class)) {
                last.?.count += 1;
                continue;
            }
            const in_hand = weapon and !hand and takesAmmo(app, class);
            hand = hand or in_hand;
            rows.append(a, .{ .hero = e.id, .class = class, .count = n, .hand = in_hand }) catch {};
        }
    }
    if (rows.items.len > before) return;
    for (nestedWeapons(a, text)) |w| rows.append(a, .{ .hero = e.id, .class = w.class, .count = 1, .hand = w.hand }) catch {};
}

/// The `weapon <name>: <archetype> { … }` blocks of a character file, in hand when
/// `place = hand`; one archetype once.
const Nested = struct { class: []const u8, hand: bool };
fn nestedWeapons(a: Allocator, text: []const u8) []const Nested {
    var out: std.ArrayList(Nested) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var cur: ?usize = null;
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, l, "weapon ") and std.mem.endsWith(u8, l, "{")) {
            const colon = std.mem.indexOf(u8, l, ": ") orelse continue;
            const class = std.mem.trim(u8, l[colon + 2 .. l.len - 1], " ");
            cur = null;
            const seen = for (out.items) |w| {
                if (std.mem.eql(u8, w.class, class)) break true;
            } else false;
            if (seen) continue;
            out.append(a, .{ .class = class, .hand = false }) catch continue;
            cur = out.items.len - 1;
        } else if (cur) |c| {
            if (std.mem.eql(u8, l, "place = hand;")) out.items[c].hand = true;
            if (std.mem.eql(u8, l, "}")) cur = null;
        }
    }
    return out.items;
}

/// Weapon archetype `class` names its ammo (`ammo = items::…`).
fn takesAmmo(app: *App, class: []const u8) bool {
    const f = @import("model_og.zig").archetypeFile(app, class) orelse return false;
    return std.mem.indexOf(u8, app.store.text(f), "ammo = ") != null;
}

/// The catalog's hero of id `id`.
fn entryOf(app: *App, id: []const u8) ?@import("catalog.zig").Entry {
    for (app.catalog.entries.items) |e| if (e.kind == .hero and std.ascii.eqlIgnoreCase(e.id, id)) return e;
    return null;
}

/// OpenGorky: the kit for a battle's build (compose/og/build.zig Kit): its things' blocks,
/// its heroes' archetypes, the ticked ones (the test room's party).
pub fn buildKit(app: *App, a: Allocator) !og.compose.og_build.Kit {
    const kit = load(app, a);
    var heroes: std.ArrayList([]const u8) = .empty;
    var party_: std.ArrayList([]const u8) = .empty;
    for (kit.heroes) |h| {
        const e = entryOf(app, h.id) orelse continue;
        try heroes.append(a, e.class);
        if (h.on) try party_.append(a, e.class);
    }
    return .{ .blocks = try ogBlocks(a, kit, ammoPaths(app, a)), .heroes = heroes.items, .party = party_.items };
}

/// The kit written to its file (made on first change), one undo step.
fn store(app: *App, a: Allocator, kit: Kit) void {
    const t = format(a, kit) catch return;
    const own = app.gpa.dupe(u8, t) catch return;
    const i = fileIndex(app) orelse {
        const w = where(app);
        _ = app.store.addNew(&.{.{ .archive = w[0], .entry = w[1], .text = own }}) catch |err| {
            app.gpa.free(own);
            app.failed(err);
        };
        return;
    };
    app.store.replace(i, own) catch |err| {
        app.gpa.free(own);
        app.failed(err);
    };
}

/// `--test-kit LINE` (a line of the file): an `enemy` line replaces the enemy's weapon,
/// a hero's is added (a `hand` one takes the hand from the hero's others).
pub fn addLine(app: *App, line: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var kit = load(app, a);
    const more = parse(a, line);
    if (more.enemy) |w| kit.enemy = w;
    for (more.rows) |r| kit = try withRow(a, kit, r);
    store(app, a, kit);
}

fn withRow(a: Allocator, kit: Kit, r: Row) !Kit {
    var k = kit;
    if (r.hand) k = try handed(a, k, r.hero, null);
    k.rows = try std.mem.concat(a, Row, &.{ k.rows, &.{r} });
    return k;
}

/// `kit` with `hero`'s hand weapon row `i` (null: none).
fn handed(a: Allocator, kit: Kit, hero: []const u8, i: ?usize) !Kit {
    var k = kit;
    k.rows = try a.dupe(Row, kit.rows);
    for (k.rows, 0..) |*r, j| if (std.ascii.eqlIgnoreCase(r.hero, hero)) {
        r.hand = j == i;
    };
    return k;
}

/// The test party: the campaign's heroes (rules campaign.party), else the game's
/// (gamestart\), as their catalog entries' ids and names; then the room's character
/// on the heroes' side.
fn party(app: *App, a: Allocator) []picker.Opt {
    var out: std.ArrayList(picker.Opt) = .empty;
    const list = og.rules.campaign().party;
    for (app.catalog.entries.items) |e| {
        if (e.kind != .hero) continue;
        // OpenGorky: the project's heroes (its game's party names them).
        const ours = if (app.store.root != null) true else if (list.len > 0) blk: {
            var it = std.mem.tokenizeAny(u8, list, " ,");
            while (it.next()) |f| if (std.ascii.eqlIgnoreCase(og.rules.stem(f), e.id)) break :blk true;
            break :blk false;
        } else !e.ally and std.mem.eql(u8, e.archive, common_archive) and std.ascii.startsWithIgnoreCase(e.entry, "gamestart\\");
        if (ours) out.append(a, .{ .key = e.id, .label = if (e.title.len > 0) e.title else e.id }) catch {};
    }
    if (app.store.root == null) out.append(a, .{ .key = extra, .label = tx.get(tx.kit_extra) }) catch {};
    return out.items;
}

/// OpenGorky: the project's weapon archetypes (their paths the keys).
fn weaponRows(app: *App, a: Allocator) []picker.Opt {
    var out: std.ArrayList(picker.Opt) = .empty;
    for (app.catalog.entries.items) |e| if (e.kind == .weapon and std.mem.eql(u8, e.archive, store_mod.og_src))
        out.append(a, .{ .key = e.class, .label = if (e.title.len > 0) e.title else e.id, .note = e.class }) catch {};
    return out.items;
}

/// What a hero can carry: every weapon, ammo and item class (its file the key).
fn classRows(app: *App, a: Allocator) []picker.Opt {
    var out: std.ArrayList(picker.Opt) = .empty;
    for (app.catalog.entries.items) |e| {
        if (e.kind != .weapon and e.kind != .ammo and e.kind != .item) continue;
        // OpenGorky: the archetype's path (`weapons::shotgun`).
        if (std.mem.eql(u8, e.archive, store_mod.og_src)) {
            out.append(a, .{ .key = e.class, .label = if (e.title.len > 0) e.title else e.id, .icon = e.icon, .note = e.class }) catch {};
            continue;
        }
        if (!std.ascii.startsWithIgnoreCase(e.entry, "classes\\")) continue;
        out.append(a, .{ .key = e.entry["classes\\".len..], .label = if (e.title.len > 0) e.title else e.id, .icon = e.icon, .note = e.id }) catch {};
    }
    return out.items;
}

/// The test kit's page (an editor tab of its own, OpenGorky): the enemy's weapon, then
/// each hero of the test party with its things.
pub fn page(app: *App, a: Allocator) void {
    rulespages.head(app, "testkit_page", .package, tx.sec_testkit, tx.kit_hint);
    clay.close();
    rulespages.form("testkit_page");
    defer clay.closeScrollColumn();
    if (!app.ogLayout()) return;
    if (app.store.root != null) return ogPage(app, a);
    var kit = load(app, a);
    if (gui.block(app, "kit_enemy_sec", tx.get(tx.kit_enemy), .{ .summary = kit.enemy orelse tx.get(tx.kit_enemy_own) })) {
        defer gui.blockEnd();
        gui.txtWrap(tx.get(tx.kit_enemy_hint), .caption, theme.dim, font_mod.regular);
        gui.fieldRow(tx.get(tx.kit_enemy));
        const open = picker.field(app, clay.id("kit_enemy"), kit.enemy orelse tx.get(tx.kit_enemy_own), false);
        clay.close();
        if (open) {
            // OpenGorky: the project's weapon archetypes.
            const these = if (app.store.root != null) weaponRows(app, a) else ea.weaponClassRows(app, a);
            const rows = std.mem.concat(a, picker.Opt, &.{ &.{.{ .label = tx.get(tx.kit_enemy_own), .selected = kit.enemy == null }}, these }) catch return;
            if (picker.list(app, a, rows)) |j| {
                kit.enemy = if (j == 0) null else rows[j].key;
                return store(app, a, kit);
            }
        }
    }
    if (!gui.block(app, "kit_party", tx.get(tx.kit_party), .{ .summary = tx.alloc(a, tx.sum_testkit, .{kit.rows.len}) })) return;
    defer gui.blockEnd();
    const classes = classRows(app, a);
    for (party(app, a), 0..) |h, hi| {
        gui.subhead(h.label);
        for (kit.rows, 0..) |r, i| if (std.ascii.eqlIgnoreCase(r.hero, h.key)) if (row(app, a, kit, classes, r, @intCast(i))) |k| return store(app, a, k);
        gui.fieldRow("");
        const id = clay.idi("kit_add", @intCast(hi));
        const open = picker.field(app, id, tx.get(tx.kit_add), false);
        clay.close();
        if (open) if (picker.list(app, a, classes)) |j| {
            const class = classes[j].key;
            const ammo = isAmmo(app, class);
            const has_hand = for (kit.rows) |x| {
                if (x.hand and std.ascii.eqlIgnoreCase(x.hero, h.key)) break true;
            } else false;
            // The first weapon goes in hand.
            const r: Row = .{ .hero = h.key, .class = class, .count = if (ammo) boxpanel.defaultCount(app, class) orelse 1 else 1, .hand = !has_hand and isWeapon(class) };
            return store(app, a, withRow(a, kit, r) catch return);
        };
    }
}

/// OpenGorky's page: the test room (its enemy, "In battle"), then the kit's heroes one by
/// one, each ticked (in the room) or not, × to take it out, its things and «+», then
/// "+ fighter".
fn ogPage(app: *App, a: Allocator) void {
    var kit = load(app, a);
    if (gui.block(app, "kit_room", tx.get(tx.kit_room), .{ .summary = if (kit.fighter) |f| entryLabel(app, f) else "—" })) {
        defer gui.blockEnd();
        gui.txtWrap(tx.get(tx.kit_room_hint), .caption, theme.dim, font_mod.regular);
        gui.fieldRow(tx.get(tx.kit_fighter));
        const open = picker.field(app, clay.id("kit_fighter"), if (kit.fighter) |f| entryLabel(app, f) else "—", false);
        clay.close();
        if (open) {
            var rows: std.ArrayList(picker.Opt) = .empty;
            for (app.catalog.entries.items) |e| if (e.kind == .enemy and e.class.len > 0)
                rows.append(a, .{ .key = e.class, .label = if (e.title.len > 0) e.title else e.id, .note = e.class, .selected = kit.fighter != null and std.mem.eql(u8, kit.fighter.?, e.class) }) catch {};
            if (picker.listKey(app, a, rows.items)) |k| {
                kit.fighter = k;
                return store(app, a, kit);
            }
        }
        if (kit.fighter) |f| if (gui.button(app, "kit_play", tx.get(tx.b_in_battle), true)) return @import("testroom.zig").playOg(app, f);
    }
    if (!gui.block(app, "kit_party", tx.get(tx.kit_party), .{ .summary = tx.alloc(a, tx.sum_kit_heroes, .{kit.heroes.len}) })) return;
    defer gui.blockEnd();
    gui.txtWrap(tx.get(tx.kit_party_hint), .caption, theme.dim, font_mod.regular);
    const classes = classRows(app, a);
    for (kit.heroes, 0..) |h, hi| {
        const e = entryOf(app, h.id);
        const name = if (e) |x| (if (x.title.len > 0) x.title else x.id) else h.id;
        gui.row(lay.space.sm);
        const tick = gui.check(app, clay.idi("kit_on", @intCast(hi)), h.on, name);
        gui.spacer();
        const drop = gui.trail(app, clay.idi("kit_hero_x", @intCast(hi)));
        clay.close();
        if (tick) {
            const hs = a.dupe(Hero, kit.heroes) catch return;
            hs[hi].on = !h.on;
            kit.heroes = hs;
            return store(app, a, kit);
        }
        if (drop) {
            kit.heroes = std.mem.concat(a, Hero, &.{ kit.heroes[0..hi], kit.heroes[hi + 1 ..] }) catch return;
            var keep: std.ArrayList(Row) = .empty;
            for (kit.rows) |r| if (!std.ascii.eqlIgnoreCase(r.hero, h.id)) keep.append(a, r) catch {};
            kit.rows = keep.items;
            return store(app, a, kit);
        }
        for (kit.rows, 0..) |r, i| if (std.ascii.eqlIgnoreCase(r.hero, h.id)) if (row(app, a, kit, classes, r, @intCast(i))) |k| return store(app, a, k);
        gui.fieldRow("");
        const open = picker.field(app, clay.idi("kit_add", @intCast(hi)), tx.get(tx.kit_add), false);
        clay.close();
        if (open) if (picker.list(app, a, classes)) |j| {
            const class = classes[j].key;
            const ammo = isAmmo(app, class);
            const has_hand = for (kit.rows) |x| {
                if (x.hand and std.ascii.eqlIgnoreCase(x.hero, h.id)) break true;
            } else false;
            const r: Row = .{ .hero = h.id, .class = class, .count = if (ammo) boxpanel.defaultCount(app, class) orelse 1 else 1, .hand = !has_hand and isWeapon(class) };
            return store(app, a, withRow(a, kit, r) catch return);
        };
    }
    // "+ fighter": a hero of the project not in the kit yet.
    gui.fieldRow("");
    const open = picker.field(app, clay.id("kit_hero_add"), tx.get(tx.kit_hero_add), false);
    clay.close();
    if (!open) return;
    var rows: std.ArrayList(picker.Opt) = .empty;
    for (app.catalog.entries.items) |e| if (e.kind == .hero and std.mem.eql(u8, e.archive, store_mod.og_src)) {
        for (kit.heroes) |h| {
            if (std.ascii.eqlIgnoreCase(h.id, e.id)) break;
        } else rows.append(a, .{ .key = e.id, .label = if (e.title.len > 0) e.title else e.id, .note = e.class }) catch {};
    };
    const k = picker.listKey(app, a, rows.items) orelse return;
    kit.heroes = std.mem.concat(a, Hero, &.{ kit.heroes, &.{.{ .id = k }} }) catch return;
    // Its things as a start gives them (Medusa: her own weapons), if it has none in the kit yet.
    if (entryOf(app, k)) |e| {
        var things: std.ArrayList(Row) = .empty;
        things.appendSlice(a, kit.rows) catch return;
        const has = for (kit.rows) |r| {
            if (std.ascii.eqlIgnoreCase(r.hero, e.id)) break true;
        } else false;
        if (!has) heroRows(app, a, e, &things);
        kit.rows = things.items;
    }
    store(app, a, kit);
}

/// A catalog entry's name by its archetype (`characters::grandma` → "Grandma").
fn entryLabel(app: *App, class: []const u8) []const u8 {
    for (app.catalog.entries.items) |e| if (std.mem.eql(u8, e.class, class)) return if (e.title.len > 0) e.title else e.id;
    return class;
}

/// Row `i`: the thing, its count −/+ (Shift: ×10), in hand or not (a weapon), ×; the
/// kit changed by a click.
fn row(app: *App, a: Allocator, kit: Kit, classes: []const picker.Opt, r: Row, i: u32) ?Kit {
    const label = for (classes) |c| {
        if (std.ascii.eqlIgnoreCase(c.key, r.class)) break c.label;
    } else r.class;
    gui.fieldRow(label);
    defer clay.close();
    var out: ?Kit = null;
    const shift = (@import("sdl").SDL_GetModState() & @import("sdl").SDL_KMOD_SHIFT) != 0;
    const step: i32 = if (shift) 10 else 1;
    // Ammo may be an empty stack; a thing is one at least.
    const least: i32 = if (isAmmo(app, r.class)) 0 else 1;
    if (gui.smallButton(app, clay.idi("kit_m", i), "-")) out = counted(a, kit, i, @max(least, r.count - step));
    gui.txt(std.fmt.allocPrint(a, "{d}", .{r.count}) catch "?", .body, theme.text, font_mod.bold);
    if (gui.smallButton(app, clay.idi("kit_p", i), "+")) out = counted(a, kit, i, r.count + step);
    if (isWeapon(r.class)) {
        if (gui.buttonOf(app, clay.idi("kit_hand", i), .{ .label = tx.get(tx.kit_hand), .style = .outline, .size = .small, .on = r.hand })) out = handed(a, kit, r.hero, if (r.hand) null else i) catch null;
    }
    gui.spacer();
    if (gui.trail(app, clay.idi("kit_del", i))) {
        var k = kit;
        k.rows = std.mem.concat(a, Row, &.{ kit.rows[0..i], kit.rows[i + 1 ..] }) catch return null;
        out = k;
    }
    return out;
}

fn counted(a: Allocator, kit: Kit, i: usize, n: i32) ?Kit {
    var k = kit;
    k.rows = a.dupe(Row, kit.rows) catch return null;
    k.rows[i].count = n;
    return k;
}

test "testkit: an OpenGorky kit's heroes, ticked or not, and the room's enemy round-trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "fighter characters::grandma\r\nhero sullivan\r\nhero ovitz off\r\nsullivan weapons::pistol 1 hand\r\n";
    const kit = parse(a, text);
    try std.testing.expectEqualStrings("characters::grandma", kit.fighter.?);
    try std.testing.expectEqual(2, kit.heroes.len);
    try std.testing.expect(kit.heroes[0].on and !kit.heroes[1].on);
    try std.testing.expectEqualStrings(text, try format(a, kit));
}

test "testkit: an OpenGorky kit as the room's blocks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const kit = parse(a, "enemy weapons::pistol\nsullivan weapons::shotgun 1 hand\nsullivan items::shotgun_ammo 30\novitz items::bandage 2\n");
    try std.testing.expectEqualStrings(
        "weapon og_tk_1: weapons::shotgun {\n    owner = \"sullivan\";\n    place = hand;\n}\n" ++
            "item og_tk_2: items::shotgun_ammo {\n    owner = \"sullivan\";\n    place = backpack;\n    count = 30;\n}\n" ++
            "item og_tk_3: items::bandage {\n    owner = \"ovitz\";\n    place = backpack;\n}\n" ++
            "item og_tk_4: items::bandage {\n    owner = \"ovitz\";\n    place = backpack;\n}\n",
        try ogBlocks(a, kit, &.{"items::shotgun_ammo"}),
    );
}

test "testkit: a character's nested weapons, the one in hand" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text = "    fighter medusa {\n        weapon la: weapons::medusalong {\n            place = hand;\n        }\n        weapon sa: weapons::medusashort {\n            place = backpack;\n        }\n        weapon lb: weapons::medusalong {\n        }\n    }\n";
    const ws = nestedWeapons(arena.allocator(), text);
    try std.testing.expectEqual(2, ws.len);
    try std.testing.expectEqualStrings("weapons::medusalong", ws[0].class);
    try std.testing.expect(ws[0].hand and !ws[1].hand);
}

test "testkit: lines, calls" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var kit = parse(a, "enemy wp_hornet\r\nsullivan cw_pistol.s 1 hand\r\nsullivan ca_pistolammo.s 30\r\nbad\r\novitz ci_bandage.s 2\r\n");
    try std.testing.expectEqualStrings("wp_hornet", kit.enemy.?);
    try std.testing.expectEqual(3, kit.rows.len);
    try std.testing.expect(kit.rows[0].hand);
    // A new hand weapon takes the hand.
    kit = try withRow(a, kit, .{ .hero = "sullivan", .class = "cw_riffle.s", .hand = true });
    try std.testing.expect(!kit.rows[0].hand and kit.rows[3].hand);
    try std.testing.expectEqualStrings("enemy wp_hornet\r\nsullivan cw_pistol.s 1\r\nsullivan ca_pistolammo.s 30\r\novitz ci_bandage.s 2\r\nsullivan cw_riffle.s 1 hand\r\n", try format(a, kit));
    try std.testing.expectEqualStrings(
        "    Weapon_New(\"og_tk_1\", \"cw_pistol.s\", \"sullivan\");\r\n" ++
            "    Item_New(\"og_tk_2\", \"ca_pistolammo.s\", \"sullivan\", 30);\r\n" ++
            "    Item_New(\"og_tk_3\", \"ci_bandage.s\", \"ovitz\");\r\n" ++
            "    Item_New(\"og_tk_4\", \"ci_bandage.s\", \"ovitz\");\r\n" ++
            "    Weapon_New(\"og_tk_5\", \"cw_riffle.s\", \"sullivan\");\r\n" ++
            "    Item_SetPlace(\"og_tk_5\", 11);\r\n",
        try calls(a, kit),
    );
}

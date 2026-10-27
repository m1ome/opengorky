//! Objects of a level added, removed, turned and moved (level.Doc): enemies, own heroes,
//! obstacles, props, boxes, party heroes, 3D model actors — each one Store edit.

const std = @import("std");
const og = @import("opengorky");
const placement = @import("placement.zig");
const vars = @import("vars.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const common_archive = store_mod.common_archive;
const box_mod = @import("box.zig");
const trigger = @import("trigger.zig");
const archive = og.formats.archive;
const level = @import("level.zig");
const Doc = level.Doc;
const builtWeaponId = templates.builtWeaponId;
const setVarLine = level.setVarLine;
const crlf = level.crlf;
const Template = level.Template;
const Prop = level.Prop;
const Obstacle = level.Obstacle;
const templates = @import("level_templates.zig");

/// Copies template `t` into this battle as a new enemy (its `.ftr` and weapons
/// under a new name), centred on grid point `at` or on the first free tile;
/// returns its object index.
pub fn addEnemy(self: *Doc, t: Template, at: ?[2]f32) !usize {
    if (self.world.combat_map == null) return error.NotBattle;
    if (self.script.restore_close == null) return error.NoRestore;
    var fighters: usize = 0;
    for (self.objects.items) |o| fighters += @intFromBool(o.tile != null);
    if (fighters >= og.battle.battle.max_fighters) return error.TooManyFighters;
    var name_buf: [64]u8 = undefined;
    const name = for (1..1000) |n| {
        const s = try std.fmt.bufPrint(&name_buf, "{s}_{d}", .{ t.class, n });
        if (!self.nameTaken(s)) break s;
    } else return error.NoFreeName;

    var path_buf: [256]u8 = undefined;
    const st = self.store;
    if (t.weapon) |wp| {
        var eb: [128]u8 = undefined;
        _ = try st.add(self.level_archive, try std.fmt.bufPrint(&eb, "{s}.ftr", .{name}), try crlf(self.gpa, templates.built_fighter, .{t.class}), name, true);
        // The exe strikes by the weapon's nameID per monster (0x4896b0): the
        // shoggoth's branch (0x489fe2) wants its own tail, 1015, and with another
        // returns queuing nothing — the battle waits for the strike forever.
        const own = if (builtWeaponId(t.class)) |id| try std.fmt.bufPrint(&path_buf, "  nameID = {d};\n", .{id}) else "";
        _ = try st.add(self.level_archive, try std.fmt.bufPrint(&eb, "{s}_sa.wpn", .{name}), try crlf(self.gpa, templates.built_weapon, .{ wp, own, name }), name, true);
        return self.placeNew(st.files.items.len - 2, at);
    }
    const ar_path = try std.fmt.bufPrint(&path_buf, "{s}/other.dat", .{t.level});
    var ar = try archive.Archive.open(st.io, self.gpa, st.dat, ar_path);
    defer ar.close(st.io, self.gpa);
    const old_q = try std.fmt.allocPrint(self.gpa, "\"{s}\"", .{t.fighter});
    defer self.gpa.free(old_q);
    const new_q = try std.fmt.allocPrint(self.gpa, "\"{s}\"", .{name});
    defer self.gpa.free(new_q);
    var ftr: ?usize = null;
    for (ar.entries) |*e| {
        const is_ftr = e.name.len == t.fighter.len + 4 and std.ascii.startsWithIgnoreCase(e.name, t.fighter) and std.ascii.endsWithIgnoreCase(e.name, ".ftr");
        if (!is_ftr and !std.ascii.endsWithIgnoreCase(e.name, ".wpn")) continue;
        // The template's files as edited (a class's weapon swapped), else the archive's.
        const data = if (st.find(ar_path, e.name)) |k| try self.gpa.dupe(u8, st.text(k)) else try ar.readAlloc(st.io, self.gpa, e);
        defer self.gpa.free(data);
        if (!is_ftr and std.ascii.findIgnoreCase(data, old_q) == null) continue;
        // Self-references (Owner, AITargetLock…) follow the new name.
        var t_new = try std.mem.replaceOwned(u8, self.gpa, data, old_q, new_q);
        errdefer self.gpa.free(t_new);
        // An editor-made class: the copied fighter includes it instead of its base.
        if (is_ftr) if (t.base) |base| {
            var ib: [128]u8 = undefined;
            var nb: [128]u8 = undefined;
            const old_inc = try std.fmt.bufPrint(&ib, "ft_{s}.ss", .{base});
            const new_inc = try std.fmt.bufPrint(&nb, "ft_{s}.ss", .{t.class});
            if (std.ascii.findIgnoreCase(t_new, old_inc)) |p| {
                const out = try std.mem.concat(self.gpa, u8, &.{ t_new[0..p], new_inc, t_new[p + old_inc.len ..] });
                self.gpa.free(t_new);
                t_new = out;
            }
        };
        var entry_buf: [128]u8 = undefined;
        const entry = if (is_ftr)
            try std.fmt.bufPrint(&entry_buf, "{s}.ftr", .{name})
        else if (std.ascii.startsWithIgnoreCase(e.name, t.fighter))
            try std.fmt.bufPrint(&entry_buf, "{s}{s}", .{ name, e.name[t.fighter.len..] })
        else
            try std.fmt.bufPrint(&entry_buf, "{s}_{s}", .{ name, e.name });
        // A class with a weapon nameID the exe wants (the shoggoth's), copied from
        // a fighter made before it was set.
        if (!is_ftr) if (builtWeaponId(t.class)) |id| if (vars.get(t_new, "nameID") == null) {
            var ib: [16]u8 = undefined;
            const out = try vars.set(self.gpa, t_new, "nameID", try std.fmt.bufPrint(&ib, "{d}", .{id}), "#include wp_");
            self.gpa.free(t_new);
            t_new = out;
        };
        const i = try st.add(self.level_archive, entry, t_new, name, true);
        if (is_ftr) ftr = i;
    }
    return self.placeNew(ftr orelse return error.NotFound, at);
}

/// Places the fighter whose `.ftr` is Store file `fi` (just added) at `at` or the
/// first free tile, by PlaceActor in restore().
pub fn placeNew(self: *Doc, fi: usize, at: ?[2]f32) !usize {
    const cm = self.world.combat_map.?;
    const close = self.script.restore_close.?;
    const st = self.store;
    const owner = st.files.items[fi].owner.?;
    const size: u32 = if (try self.classOf(fi, "#include ft_")) |ci| blk: {
        // As the battle sizes fighters by charSize (roster.zig).
        const cs = vars.get(st.text(ci), "charSize") orelse 1;
        break :blk if (cs >= 9) 3 else if (cs >= 4) 2 else 1;
    } else 1;

    try self.objects.append(self.gpa, .{ .name = owner, .kind = .enemy, .pos = .{ 0, 0 }, .size = size, .tile = .{ 0, 0 }, .added = true });
    const oi = self.objects.items.len - 1;
    const tile: [2]i32 = if (at) |g| blk: {
        const half = @as(f32, @floatFromInt(size)) / 2;
        const tt: [2]i32 = .{ @intFromFloat(@floor(g[0] - half + 0.5)), @intFromFloat(@floor(g[1] - half + 0.5)) };
        if (self.canPlace(oi, tt)) break :blk tt;
        _ = self.objects.pop();
        return error.TileNotFree;
    } else find: for (0..cm.height) |y| {
        for (0..cm.width) |x| {
            const tt: [2]i32 = .{ @intCast(x), @intCast(y) };
            if (self.canPlace(oi, tt)) break :find tt;
        }
    } else {
        _ = self.objects.pop();
        return error.NoFreeTile;
    };
    const o = &self.objects.items[oi];
    o.tile = tile;
    o.pos = self.tilePos(cm, tile, size);
    const ins = placement.insertPoint(self.text(), close);
    const line = try std.fmt.allocPrint(self.gpa, "    PlaceActor(\"{s}\",{d},{d},0);{s}", .{ owner, tile[0], tile[1], placement.newline(self.text()) });
    defer self.gpa.free(line);
    var edits = [_]placement.Edit{.{ .span = .{ .start = ins, .end = ins }, .text = line }};
    self.edit(&edits) catch |err| {
        _ = self.objects.pop();
        return err;
    };
    return oi;
}

/// Party hero `hero` on the battle at grid point `g`: `PlaceActor("Medusa",x,y,0)` in
/// restore(), as the battles place Sullivan and BT; the exe skips it while that hero
/// isn't in the party. Returns its object index.
pub fn addOwn(self: *Doc, hero: []const u8, g: [2]f32) !usize {
    if (self.world.combat_map == null) return error.NotBattle;
    if (self.script.restore_close == null) return error.NoRestore;
    var fighters: usize = 0;
    for (self.objects.items) |o| fighters += @intFromBool(o.tile != null);
    if (fighters >= og.battle.battle.max_fighters) return error.TooManyFighters;
    const name = hero;
    for (self.script.calls) |call| if (std.ascii.eqlIgnoreCase(call.name, name)) return error.HeroThere;
    // The PlaceActor line only: the object comes with the party.
    const cm = self.world.combat_map.?;
    try self.objects.append(self.gpa, .{ .name = name, .kind = .hero, .pos = .{ 0, 0 }, .size = 1, .tile = .{ 0, 0 }, .added = true });
    const oi = self.objects.items.len - 1;
    const tile: [2]i32 = .{ @intFromFloat(@floor(g[0])), @intFromFloat(@floor(g[1])) };
    if (!self.canPlace(oi, tile)) {
        _ = self.objects.pop();
        return error.TileNotFree;
    }
    self.objects.items[oi].tile = tile;
    self.objects.items[oi].pos = self.tilePos(cm, tile, 1);
    const ins = placement.insertPoint(self.text(), self.script.restore_close.?);
    const line = try std.fmt.allocPrint(self.gpa, "    PlaceActor(\"{s}\",{d},{d},0);{s}", .{ name, tile[0], tile[1], placement.newline(self.text()) });
    defer self.gpa.free(line);
    var edits = [_]placement.Edit{.{ .span = .{ .start = ins, .end = ins }, .text = line }};
    self.edit(&edits) catch |err| {
        _ = self.objects.pop();
        return err;
    };
    return oi;
}

/// A new templates.obstacle on the tile under grid point `g`, written as the battles' own: a
/// crate or barrel `.obs` (`#include obs_crate_wod.ss`…; a barrel names its blast
/// weapon `<name>_explode.wpn`, wp_barrel_explode.ss) or an empty item box `.obs_i`
/// (obs_i_itembox.ss), placed by PlaceActor in restore(); returns its object index.
pub fn addObstacle(self: *Doc, what: Obstacle, g: [2]f32) !usize {
    const cm = self.world.combat_map orelse return error.NotBattle;
    const close = self.script.restore_close orelse return error.NoRestore;
    var fighters: usize = 0;
    for (self.objects.items) |o| fighters += @intFromBool(o.tile != null);
    if (fighters >= og.battle.battle.max_fighters) return error.TooManyFighters;
    var nb: [96]u8 = undefined;
    const name = for (1..1000) |n| {
        const s = try std.fmt.bufPrint(&nb, "{s}_{s}{d}", .{ self.name, @tagName(what), n });
        if (!self.nameTaken(s)) break s;
    } else return error.NoFreeName;
    const tile: [2]i32 = .{ @intFromFloat(@floor(g[0])), @intFromFloat(@floor(g[1])) };
    try self.objects.append(self.gpa, .{ .name = name, .kind = .neutral, .pos = self.tilePos(cm, tile, 1), .size = 1, .tile = tile, .added = true });
    const oi = self.objects.items.len - 1;
    errdefer _ = self.objects.pop();
    if (!self.canPlace(oi, tile)) return error.TileNotFree;

    var eb: [128]u8 = undefined;
    const st = self.store;
    switch (what) {
        .box => _ = try st.add(self.level_archive, try std.fmt.bufPrint(&eb, "{s}.obs_i", .{name}), try crlf(self.gpa, templates.item_box, .{}), name, true),
        .barrel => {
            var wb: [128]u8 = undefined;
            const blast = try std.fmt.bufPrint(&wb, "\n    explodeWeapon = \"{s}_explode\";", .{name});
            _ = try st.add(self.level_archive, try std.fmt.bufPrint(&eb, "{s}.obs", .{name}), try crlf(self.gpa, templates.obstacle, .{ "obs_barrel.ss", blast }), name, true);
            _ = try st.add(self.level_archive, try std.fmt.bufPrint(&eb, "{s}_explode.wpn", .{name}), try crlf(self.gpa, templates.barrel_blast, .{name}), name, true);
        },
        .wcrate, .mcrate => _ = try st.add(self.level_archive, try std.fmt.bufPrint(&eb, "{s}.obs", .{name}), try crlf(self.gpa, templates.obstacle, .{ if (what == .wcrate) "obs_crate_wod.ss" else "obs_crate_met.ss", "" }), name, true),
    }
    self.objects.items[oi].name = st.files.items[st.files.items.len - 1].owner.?;
    const ins = placement.insertPoint(self.text(), close);
    const line = try std.fmt.allocPrint(self.gpa, "    PlaceActor(\"{s}\",{d},{d},0);{s}", .{ name, tile[0], tile[1], placement.newline(self.text()) });
    defer self.gpa.free(line);
    var edits = [_]placement.Edit{.{ .span = .{ .start = ins, .end = ins }, .text = line }};
    try self.edit(&edits);
    return oi;
}

/// A new decorative prop at grid point `g` (half tiles, as the battles' own): a
/// one-line `.act` (`#include obs_a_pipe.s`) placed by PlaceCombatActor(name, x, y, 0)
/// in restore(); it takes no tile. Returns its object index.
pub fn addProp(self: *Doc, what: Prop, g: [2]f32) !usize {
    const cm = self.world.combat_map orelse return error.NotBattle;
    const close = self.script.restore_close orelse return error.NoRestore;
    const at: [2]f32 = .{ @round(g[0] * 2) / 2, @round(g[1] * 2) / 2 };
    if (!self.gridOpen(at)) return error.TileNotFree;
    var nb: [96]u8 = undefined;
    const name = for (1..1000) |n| {
        const s = try std.fmt.bufPrint(&nb, "{s}_a_{s}{d}", .{ self.name, @tagName(what), n });
        if (!self.nameTaken(s)) break s;
    } else return error.NoFreeName;
    var eb: [128]u8 = undefined;
    const f = try self.store.add(self.level_archive, try std.fmt.bufPrint(&eb, "{s}.act", .{name}), try crlf(self.gpa, "#include obs_a_{s}.s\n", .{@tagName(what)}), name, true);
    const owner = self.store.files.items[f].owner.?;
    const ins = placement.insertPoint(self.text(), close);
    const line = try std.fmt.allocPrint(self.gpa, "    PlaceCombatActor(\"{s}\", {d:.1}, {d:.1}, 0);{s}", .{ name, at[0], at[1], placement.newline(self.text()) });
    defer self.gpa.free(line);
    var edits = [_]placement.Edit{.{ .span = .{ .start = ins, .end = ins }, .text = line }};
    try self.edit(&edits);
    try self.objects.append(self.gpa, .{ .name = owner, .kind = .prop, .pos = self.gridPos(cm, at), .grid = at, .added = true });
    self.bind();
    return self.objects.items.len - 1;
}

/// Which way object `i` faces in the battle, degrees: a prop's PlaceCombatActor
/// angle, or an templates.obstacle's PlaceActor direction in eighths of a turn (dir·π·0.25,
/// 0x48e90a; none — 0). Null for fighters: the battle start (0x4b4a51) turns each
/// to its nearest opponent, rounded to a grid side, whatever the script says; and
/// for AIEnemyAppear (it faces the way it walks in) and unplaced objects.
pub fn facing(self: *const Doc, i: usize) ?f32 {
    const o = self.objects.items[i];
    const call = self.script.calls[o.call orelse return null];
    return switch (call.func) {
        .place_combat => call.arg(self.text(), 2),
        // Numeric arguments after the name: x, y, dir.
        .place_actor => if (o.kind == .neutral) 45 * (call.arg(self.text(), 2) orelse 0) else null,
        .enemy_appear => null,
    };
}

/// Turns object `i` by `delta` degrees: a prop's angle kept in -180…180 (as the
/// game's own), PlaceActor's direction by eighths 0…7 (added when the call has none).
pub fn rotate(self: *Doc, i: usize, delta: f32) !void {
    const call = self.script.calls[self.objects.items[i].call orelse return];
    const a = (self.facing(i) orelse return) + delta;
    var buf: [24]u8 = undefined;
    var edits = [_]placement.Edit{switch (call.func) {
        .place_combat => .{ .span = call.args[2], .text = try std.fmt.bufPrint(&buf, "{d}", .{@as(i32, @intFromFloat(@round(a - 360 * @round(a / 360))))}) },
        else => blk: {
            const dir = @mod(@as(i32, @intFromFloat(@round(a / 45))), 8);
            if (call.n_args > 2) break :blk .{ .span = call.args[2], .text = try std.fmt.bufPrint(&buf, "{d}", .{dir}) };
            const end = call.args[1].end;
            break :blk .{ .span = .{ .start = end, .end = end }, .text = try std.fmt.bufPrint(&buf, ",{d}", .{dir}) };
        },
    }};
    try self.edit(&edits);
}

/// Battle enemy `i` placed by restore(): PlaceActor ↔ AIEnemyAppear (it walks in at
/// the battle start from just past the nearest grid edge, as the battles' own:
/// 01__port_castlegate's sphinx from x = -2, its size). Null — neither applies.
pub fn canWalkIn(self: *const Doc, i: usize) ?bool {
    const o = self.objects.items[i];
    if (o.kind != .enemy or o.later != null) return null;
    const call = self.script.calls[o.call orelse return null];
    if (!call.in_restore) return null;
    return switch (call.func) {
        .place_actor => false,
        .enemy_appear => true,
        .place_combat => null,
    };
}

pub fn toggleWalkIn(self: *Doc, i: usize) !void {
    const cm = self.world.combat_map orelse return error.NotBattle;
    const walks = self.canWalkIn(i) orelse return error.NotEnemy;
    const o = self.objects.items[i];
    const call = self.script.calls[o.call.?];
    const t = o.tile.?;
    const n: i32 = @intCast(o.size);
    var buf: [160]u8 = undefined;
    const line = if (walks)
        try std.fmt.bufPrint(&buf, "PlaceActor(\"{s}\",{d},{d},0);", .{ call.name, t[0], t[1] })
    else blk: {
        const w: i32 = @intCast(cm.width);
        const h: i32 = @intCast(cm.height);
        // The nearest edge; the start is just outside it, in line with the tile.
        const d = [4]i32{ t[0], w - t[0] - n, t[1], h - t[1] - n };
        var k: usize = 0;
        for (d, 0..) |v, j| if (v < d[k]) {
            k = j;
        };
        const from: [2]i32 = switch (k) {
            0 => .{ -n, t[1] },
            1 => .{ w, t[1] },
            2 => .{ t[0], -n },
            else => .{ t[0], h },
        };
        break :blk try std.fmt.bufPrint(&buf, "AIEnemyAppear(\"{s}\", {d}, {d}, {d}, {d});", .{ call.name, from[0], from[1], t[0], t[1] });
    };
    var edits = [_]placement.Edit{.{ .span = call.stmt, .text = line }};
    try self.edit(&edits);
}

/// Store index of object `name`'s box script (`.itm`, battle `.obs_i`, a safe's
/// `.are`); null — not a box.
pub fn boxFile(self: *Doc, name: []const u8) ?usize {
    var buf: [128]u8 = undefined;
    for ([_][]const u8{ ".itm", ".obs_i", ".are" }) |ext| {
        const entry = std.fmt.bufPrint(&buf, "{s}{s}", .{ name, ext }) catch return null;
        const f = self.store.file(self.level_archive, entry) catch continue;
        return if (@import("box.zig").isBox(self.store.text(f))) f else null;
    }
    return null;
}

/// A new, empty item box on the floor under background point `bg`, made as the
/// game's own: `<name>.itm` (ci_box.s, slots in init()) and its position in
/// common/other.dat `variables\<name>.var`; returns its object index.
pub fn addBox(self: *Doc, bg: [2]f32) !usize {
    if (self.isBattle()) return error.NotLocation;
    if (!self.walkableAt(bg)) return error.NotWalkable;
    var nb: [96]u8 = undefined;
    var eb: [100]u8 = undefined;
    const name = for (1..1000) |n| {
        const s = try std.fmt.bufPrint(&nb, "{s}_box{d}", .{ self.name, n });
        if (!self.nameTaken(s) and self.store.find(self.level_archive, try std.fmt.bufPrint(&eb, "{s}.itm", .{s})) == null) break s;
    } else return error.NoFreeName;
    const p = og.world.floor.groundAt(self.world, bg);
    // Where the hero walks to open it: the walkable cell nearest the box.
    const walk_to = self.nearestWalkable(bg) orelse return error.NoWalkableNear;
    const itm = try crlf(self.gpa,
        \\#include ci_box.s
        \\
        \\string itm_1;
        \\
        \\function init()
        \\{{
        \\  class_init();
        \\
        \\  itm_1 = "";
        \\  cnt_itm=0;
        \\}};
        \\
        \\
        \\function post_init_box()
        \\{{
        \\}};
        \\
    , .{});
    errdefer self.gpa.free(itm);
    // The keys of the game's box .var files, in their order and number format.
    const vars_text = try crlf(self.gpa,
        \\nameID=75
        \\x={d:.6}
        \\y={d:.6}
        \\z={d:.6}
        \\angle=0.000000
        \\scale=1.000000
        \\radius=21
        \\Owner=
        \\spriteFile=(null)
        \\meshFile=skrzynia
        \\useAnim=(null)
        \\walk_x={d:.0}
        \\walk_y={d:.0}
        \\walk_angle=0.000000
        \\place=0
        \\two_handed=0
        \\type=0
        \\armor=0
        \\hp=0
        \\counter=0
        \\fire_resistance=0
        \\cold_resistance=0
        \\elec_resistance=0
        \\poison_resistance=0
        \\gas_resistance=0
        \\bullet_resistance=0
        \\blade_resistance=0
        \\noise_resistance=0
        \\stun_resistance=0
        \\effect_time=0
        \\effect_power=0
        \\visible=1
        \\funcID=1
        \\cnt_itm=0
        \\
    , .{ p[0], p[1], p[2], walk_to[0], walk_to[1] });
    errdefer self.gpa.free(vars_text);
    var vb: [120]u8 = undefined;
    const f = try self.store.addNew(&.{
        .{ .archive = self.level_archive, .entry = try std.fmt.bufPrint(&eb, "{s}.itm", .{name}), .text = itm },
        .{ .archive = common_archive, .entry = try std.fmt.bufPrint(&vb, "variables\\{s}.var", .{name}), .text = vars_text },
    });
    const entry = self.store.files.items[f].entry;
    try self.objects.append(self.gpa, .{ .name = entry[0 .. entry.len - 4], .kind = .item, .pos = bg, .added = true, .file = f });
    return self.objects.items.len - 1;
}

/// A hero from another level (`src_archive` file `src_entry`, e.g. Medusa's
/// `03__museum_corner/other.dat: medusa.hro`) on this location at background point
/// `bg`: the `.hro` with its position and without the battle locks, the weapons it
/// owns (`Owner="<hero>"`), and `DisableObject("<hero>")` first in post_init() — hidden
/// until a scene shows it (`DISABLEOBJECT("<hero>",0)`, `SETHERO("<hero>",1)`), as
/// Bt in 01_port. One undo step; the level shows it once saved.
pub fn addHero(self: *Doc, src_archive: []const u8, src_entry: []const u8, bg: [2]f32) ![]const u8 {
    if (self.isBattle()) return error.NotLocation;
    if (!self.walkableAt(bg)) return error.NotWalkable;
    const file = src_entry[if (std.mem.lastIndexOfScalar(u8, src_entry, '\\')) |k| k + 1 else 0..];
    const stem = file[0 .. file.len - 4];
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    for (try self.levelFiles(a)) |f| if (std.ascii.eqlIgnoreCase(self.store.files.items[f].entry, file)) return error.HeroThere;
    const src = self.store.text(try self.store.file(src_archive, src_entry));
    // The .hro: battle locks out, the position last in init() (over what it includes).
    var hro: std.ArrayList(u8) = .empty;
    defer hro.deinit(self.gpa);
    const body = box_mod.funcBody(src, "init") orelse return error.NoInit;
    const close_line = std.mem.lastIndexOfScalar(u8, src[0..body.end], '\n').? + 1;
    const p = og.world.floor.groundAt(self.world, bg);
    var lines = std.mem.splitScalar(u8, src[0..close_line], '\n');
    var first = true;
    while (lines.next()) |l| {
        const t = std.mem.trim(u8, l, " \t\r");
        if (std.mem.startsWith(u8, t, "moveLock") or std.mem.startsWith(u8, t, "attackLock")) continue;
        if (!first) try hro.append(self.gpa, '\n');
        first = false;
        try hro.appendSlice(self.gpa, l);
    }
    try hro.print(self.gpa, "  x = {d:.1};\r\n  y = {d:.1};\r\n  z = {d:.1};\r\n  angle = 0.0;\r\n", .{ p[0], p[1], p[2] });
    try hro.appendSlice(self.gpa, src[close_line..]);
    var files: std.ArrayList(store_mod.NewFile) = .empty;
    try files.append(a, .{ .archive = self.level_archive, .entry = try a.dupe(u8, file), .text = try hro.toOwnedSlice(self.gpa) });
    errdefer for (files.items) |f| self.gpa.free(f.text);
    // Its weapons.
    const owner = try std.fmt.allocPrint(a, "owner=\"{s}\"", .{stem});
    var ar = try archive.Archive.open(self.store.io, self.gpa, self.store.dat, src_archive);
    defer ar.close(self.store.io, self.gpa);
    for (ar.entries) |*e| {
        if (!std.ascii.endsWithIgnoreCase(e.name, ".wpn")) continue;
        const t = try ar.readAlloc(self.store.io, a, e);
        const flat = try a.alloc(u8, t.len);
        var n: usize = 0;
        for (t) |ch| if (ch != ' ' and ch != '\t') {
            flat[n] = std.ascii.toLower(ch);
            n += 1;
        };
        if (std.mem.indexOf(u8, flat[0..n], owner) == null) continue;
        for (try self.levelFiles(a)) |f| if (std.ascii.eqlIgnoreCase(self.store.files.items[f].entry, e.name)) return error.HeroThere;
        try files.append(a, .{ .archive = self.level_archive, .entry = try a.dupe(u8, e.name), .text = try self.gpa.dupe(u8, t) });
    }
    // Hidden until a scene: first in the level's post_init().
    const lev = self.text();
    const pb = box_mod.funcBody(lev, "post_init") orelse return error.NoPostInit;
    const at = std.mem.indexOfScalarPos(u8, lev, pb.start, '\n').? + 1;
    const new_lev = try std.fmt.allocPrint(self.gpa, "{s}  DisableObject(\"{s}\");   // hero added in the editor: hidden until a scene shows it\r\n{s}", .{ lev[0..at], stem, lev[at..] });
    errdefer self.gpa.free(new_lev);
    _ = try self.store.addNew(files.items);
    files.clearRetainingCapacity();
    try self.store.replace(self.lev, new_lev);
    return stem;
}

/// The `.hro` of hero `name` in this level's archive, if it is one of the level's.
pub fn heroFile(self: *Doc, name: []const u8) ?usize {
    var buf: [128]u8 = undefined;
    return self.store.file(self.level_archive, std.fmt.bufPrint(&buf, "{s}.hro", .{name}) catch return null) catch null;
}

/// Hero `name` taken out of the location: its `.hro` and the `.wpn` it owns
/// deleted, the level scripts' lines that are one call naming it (DisableObject,
/// EnableObject, HERO_EnableEnumerate…) dropped. Refused, nothing changed, while
/// another line of them names it: `ref_file` says which script.
pub fn removeHero(self: *Doc, name: []const u8) !void {
    if (self.isBattle()) return error.NotLocation;
    const hro = self.heroFile(name) orelse return error.NotAHero;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var gone: std.ArrayList(usize) = .empty;
    try gone.append(a, hro);
    const owner = try std.fmt.allocPrint(a, "owner=\"{s}\"", .{name});
    const quoted = try std.fmt.allocPrint(a, "\"{s}\"", .{name});
    var edits: std.ArrayList(struct { f: usize, text: []u8 }) = .empty;
    defer for (edits.items) |e| self.gpa.free(e.text);
    for (try self.levelFiles(a)) |f| {
        if (f == hro) continue;
        const t = self.store.text(f);
        if (std.ascii.endsWithIgnoreCase(self.store.files.items[f].entry, ".wpn")) {
            const flat = try a.alloc(u8, t.len);
            var n: usize = 0;
            for (t) |ch| if (ch != ' ' and ch != '\t') {
                flat[n] = std.ascii.toLower(ch);
                n += 1;
            };
            const low = try std.ascii.allocLowerString(a, owner);
            if (std.mem.indexOf(u8, flat[0..n], low) != null) {
                try gone.append(a, f);
                continue;
            }
        }
        const kept = try trigger.dropCallsOf(self.gpa, t, name);
        if (std.ascii.findIgnoreCase(placement.uncommented(a, kept) catch kept, quoted) != null) {
            self.gpa.free(kept);
            const entry = self.store.files.items[f].entry;
            const l = @min(entry.len, self.ref_file.len);
            @memcpy(self.ref_file[0..l], entry[0..l]);
            self.ref_len = l;
            return error.Referenced;
        }
        if (std.mem.eql(u8, kept, t)) self.gpa.free(kept) else edits.append(a, .{ .f = f, .text = kept }) catch |err| {
            self.gpa.free(kept);
            return err;
        };
    }
    try self.store.delete(gone.items);
    while (edits.pop()) |e| self.store.replace(e.f, e.text) catch |err| {
        self.gpa.free(e.text);
        return err;
    };
}

/// Script of item box `name` that can be deleted whole (a location's `.itm`; battle
/// boxes are removed from the battle, safes stay areas).
pub fn deletableBox(self: *Doc, name: []const u8) ?usize {
    var buf: [128]u8 = undefined;
    const f = self.store.file(self.level_archive, std.fmt.bufPrint(&buf, "{s}.itm", .{name}) catch return null) catch return null;
    return if (@import("box.zig").isBox(self.store.text(f))) f else null;
}

/// A location actor standing by its own `.act` (x, y in init(), as "Add a 3D model"
/// makes them) that no other script of the level names: that file, deletable whole.
pub fn deletableActor(self: *Doc, name: []const u8) ?usize {
    const f = self.actFile(name) orelse return null;
    if (!self.actorMovable(name)) return null;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const quoted = std.fmt.allocPrint(a, "\"{s}\"", .{name}) catch return null;
    for (self.levelFiles(a) catch return null) |k| {
        if (k != f and std.ascii.findIgnoreCase(self.store.text(k), quoted) != null) return null;
    }
    return f;
}

/// Deletes item box `i` (its `.itm` and `variables\\<name>.var`) or a standalone actor
/// (its `.act`); one undo step.
pub fn deleteBox(self: *Doc, i: usize) !void {
    const o = self.objects.items[i];
    if (self.deletableActor(o.name)) |act| {
        try self.store.delete(&.{act});
        try self.removed.append(self.gpa, .{ .file = act, .obj = o });
        _ = self.objects.orderedRemove(i);
        return;
    }
    const itm = self.deletableBox(o.name) orelse return error.NotABox;
    var buf: [128]u8 = undefined;
    const v: ?usize = self.store.file(common_archive, try std.fmt.bufPrint(&buf, "variables\\{s}.var", .{o.name})) catch null;
    if (v) |vf| try self.store.delete(&.{ itm, vf }) else try self.store.delete(&.{itm});
    try self.removed.append(self.gpa, .{ .file = itm, .obj = o });
    _ = self.objects.orderedRemove(i);
}

/// After undo brought file `f` back: its deleted box returns to the list.
pub fn restoreDeleted(self: *Doc, f: usize) void {
    if (self.store.isDeleted(f)) return;
    var k = self.removed.items.len;
    while (k > 0) {
        k -= 1;
        const r = self.removed.items[k];
        if (r.file != f) continue;
        self.objects.append(self.gpa, r.obj) catch return;
        _ = self.removed.orderedRemove(k);
    }
}

/// Moves location item `i` onto the floor under `bg` (x, y, z and the walk point
/// in its `.var`; one undo step).
pub fn moveItem(self: *Doc, i: usize, bg: [2]f32) !void {
    const o = &self.objects.items[i];
    const f = self.varFile(o.name) orelse return error.NoPosition;
    const p = og.world.floor.groundAt(self.world, bg);
    const w = self.nearestWalkable(bg) orelse return error.NoWalkableNear;
    var t = try self.gpa.dupe(u8, self.store.text(f));
    errdefer self.gpa.free(t);
    var vb: [5][32]u8 = undefined;
    const vals = [_]struct { []const u8, []const u8 }{
        .{ "x", try std.fmt.bufPrint(&vb[0], "{d:.6}", .{p[0]}) },
        .{ "y", try std.fmt.bufPrint(&vb[1], "{d:.6}", .{p[1]}) },
        .{ "z", try std.fmt.bufPrint(&vb[2], "{d:.6}", .{p[2]}) },
        .{ "walk_x", try std.fmt.bufPrint(&vb[3], "{d:.0}", .{w[0]}) },
        .{ "walk_y", try std.fmt.bufPrint(&vb[4], "{d:.0}", .{w[1]}) },
    };
    for (vals) |kv| {
        const next = try setVarLine(self.gpa, t, kv[0], kv[1]);
        self.gpa.free(t);
        t = next;
    }
    try self.store.replace(f, t);
    o.pos = bg;
}

/// A location actor's own script (`<name>.act`), if any.
pub fn actFile(self: *Doc, name: []const u8) ?usize {
    var buf: [128]u8 = undefined;
    return self.store.file(self.level_archive, std.fmt.bufPrint(&buf, "{s}.act", .{name}) catch return null) catch null;
}

/// A location actor placed by its own x, y (in init(); the exe shows such an actor
/// without PlaceActor): moved by dragging. One placed at an area moves with it.
pub fn actorMovable(self: *Doc, name: []const u8) bool {
    const f = self.actFile(name) orelse return false;
    return vars.get(self.store.text(f), "x") != null;
}

/// Location actor `i` onto the floor under `bg` (x, y, z in its init(); one step).
pub fn moveActor(self: *Doc, i: usize, bg: [2]f32) !void {
    const o = &self.objects.items[i];
    const f = self.actFile(o.name) orelse return error.NoPosition;
    const p = og.world.floor.groundAt(self.world, bg);
    var t = try self.gpa.dupe(u8, self.store.text(f));
    errdefer self.gpa.free(t);
    var vb: [3][32]u8 = undefined;
    for ([_][]const u8{ "x", "y", "z" }, 0..) |k, j| {
        const next = try vars.set(self.gpa, t, k, try std.fmt.bufPrint(&vb[j], "{d:.1}", .{p[j]}), "{");
        self.gpa.free(t);
        t = next;
    }
    try self.store.replace(f, t);
    o.pos = bg;
}

/// A new location actor showing model `mesh`, standing on the floor under `bg`
/// (`<name>.act`: Actor.s, its model and place in init(); one undo step). The level is
/// shown at once.
pub fn addActor(self: *Doc, mesh: []const u8, bg: [2]f32) ![]const u8 {
    if (self.isBattle()) return error.NotLocation;
    if (!self.walkableAt(bg)) return error.NotWalkable;
    var nb: [64]u8 = undefined;
    var eb: [72]u8 = undefined;
    const stem = std.fs.path.stem(mesh);
    const name = for (1..1000) |n| {
        const s0 = try std.fmt.bufPrint(&nb, "{s}{d}", .{ stem, n });
        const lower = std.ascii.lowerString(nb[0..s0.len], s0);
        if (!self.nameTaken(lower) and self.store.find(self.level_archive, try std.fmt.bufPrint(&eb, "{s}.act", .{lower})) == null and self.actFile(lower) == null) break lower;
    } else return error.NoFreeName;
    const p = og.world.floor.groundAt(self.world, bg);
    const t = try std.fmt.allocPrint(self.gpa, "#include Actor.s\r\n\r\nfunction init()\r\n{{\r\n  nameID=-1;\r\n  meshFile=\"{s}\";\r\n  x={d:.1};\r\n  y={d:.1};\r\n  z={d:.1};\r\n  angle=0.0;\r\n  rotSpeed=0.01;\r\n}};\r\n\r\nfunction update()\r\n{{\r\n}};\r\n", .{ stem, p[0], p[1], p[2] });
    errdefer self.gpa.free(t);
    const f = try self.store.addNew(&.{.{ .archive = self.level_archive, .entry = try std.fmt.bufPrint(&eb, "{s}.act", .{name}), .text = t }});
    // Shown at once (the world, read from the archives, has it after a save).
    const owned = self.store.files.items[f].entry;
    const n = owned[0 .. owned.len - ".act".len];
    try self.objects.append(self.gpa, .{ .name = n, .kind = .actor, .pos = bg, .added = true, .file = f });
    return n;
}

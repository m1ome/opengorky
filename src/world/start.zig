//! Location start (0x431830): objects and heroes from the archives, `.var`, init(),
//! restore(), post_init(); level camera after initCamera().

const std = @import("std");
const state_object = @import("../state.zig").object;
const camera = @import("../actor.zig").camera;
const fields = @import("../fields.zig");
const sources = @import("sources.zig");
const rules = @import("../rules.zig");
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;
const hooks = @import("../state.zig").hooks;
const ir = @import("../script.zig").ir;
const Class = @import("../script.zig").object.Class;
const schema = @import("../core.zig").schema;
const entity = @import("../core.zig").entity;
const queue = @import("queue.zig");
const Value = @import("../script.zig").value.Value;
const actor_mod = @import("../actor.zig");
const dispatch = @import("../script.zig").dispatch;
const traits = @import("../script.zig").traits;

/// Game heroes and shared items (`common/other.dat: gamestart\*`, 0x431550): `.hro` are
/// heroes, `.itm`/`.wpn` items (Sullivan's transmitter, the fist at `place` 200).
/// A campaign's own party (rules campaign.ss, OpenGorky) instead of gamestart's heroes:
/// `createParty`.
pub fn createHeroes(self: *World) !void {
    if (self.res.source.level_block.len > 0) return createModelParty(self);
    const party = rules.campaign().party;
    for (self.res.source.gamestart) |file| {
        const ext = std.fs.path.extension(file);
        const kind = state_object.kindOf(ext);
        if (kind != .actor and kind != .item and kind != .weapon) continue;
        if (kind == .actor and party.len > 0) continue;
        const cls = self.rt.loadClass(file) catch |err| {
            std.log.warn("gamestart {s}: {t}", .{ file, err });
            continue;
        };
        const hero = kind == .actor;
        _ = try self.addObject(file[0 .. file.len - ext.len], cls, .{ .kind = kind, .hero = hero, .hro = hero, .fighter = hero });
    }
    if (party.len > 0) try createParty(self, party);
}

/// The campaign's heroes in its order: scripts of gamestart\ or of any location (a hero
/// the location has itself, as a battle's Medusa, stays its own).
fn createParty(self: *World, list: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, list, " ,");
    while (it.next()) |file| {
        const name = file[0 .. file.len - std.fs.path.extension(file).len];
        if (self.rt.findObject(name) != null) continue;
        const cls = self.rt.loadClass(file) catch cls: {
            if (try sources.addForeignSource(self, file)) if (self.rt.loadClass(file)) |c| break :cls c else |_| {};
            std.log.warn("campaign party {s}: no such hero script", .{file});
            continue;
        };
        _ = try self.addObject(name, cls, .{ .kind = .actor, .hero = true, .hro = true, .fighter = true });
    }
}

pub fn createObjects(self: *World) !void {
    if (self.res.source.level_block.len > 0) return createModel(self, self.res.source.level_block);
    for (self.res.source.level_files) |name| _ = try self.addScriptObject(name);
    // Mod objects missing from the archive (one it has already exists: `mod` swaps its source).
    for (self.res.source.mod_files) |name| {
        if (self.rt.findObject(name[0 .. name.len - std.fs.path.extension(name).len]) != null) continue;
        _ = try self.addScriptObject(name);
    }
}

// ---------------------------------------------------------------- OpenGorky

/// An OpenGorky location's objects: the level's block (`level`/`battle`; its code is its
/// own, `fn`s in the block, attached with it), then its nested blocks in order (a
/// fighter's weapon right after it, its `Owner`; `nestedOf`). Each is an object of its
/// block's kind with its host schema's fields, set by its look, its archetypes (the
/// farthest first), then by itself.
fn createModel(self: *World, key: []const u8) !void {
    self.block_item = newBlockItem;
    const e = self.rt.ogs.blocks.get(key) orelse return error.NoLevelBlock;
    const m = moduleOf(self, e) orelse return error.NoLevelBlock;
    const lv = try addBlock(self, m, e, "", e.name) orelse return error.NoLevelBlock;
    self.level = lv;
    try addChildren(self, m, e, lv.name);
}

/// The nested blocks of `e` (object `owner`'s) as objects, its archetypes' too (an
/// archetype is a whole prototype).
fn addChildren(self: *World, m: *const ir.Module, e: *const ir.Entity, owner: []const u8) !void {
    return addChildrenAs(self, m, e, owner, false);
}

/// `inherited`: `e` is the owner's archetype (spawnBlock), its own blocks too.
fn addChildrenAs(self: *World, m: *const ir.Module, e: *const ir.Entity, owner: []const u8, inherited: bool) !void {
    const a = self.rt.arena();
    var list: std.ArrayList(Nested) = .empty;
    try nestedOf(self, a, m, e, &list, 0);
    for (list.items) |x| {
        // A path's script (`path deska { attach … }`): made at its first node (pathBlock).
        if (std.mem.eql(u8, x.e.kind, "path")) continue;
        // An archetype's block is the owner's own object: `grandma_child1_gun` of `gun`.
        const name = if (x.inherited or inherited) try std.fmt.allocPrint(a, "{s}_{s}", .{ owner, x.e.name }) else "";
        // A level's own weapon or item lies in it, nobody's (its `Owner` its own field).
        const owned = (std.mem.eql(u8, x.e.kind, "weapon") or std.mem.eql(u8, x.e.kind, "item")) and !isLevel(e);
        if (try addBlock(self, x.m, x.e, if (owned) owner else "", name)) |o| try addChildrenAs(self, x.m, x.e, o.name, false);
    }
}

fn isLevel(e: *const ir.Entity) bool {
    return std.mem.eql(u8, e.kind, "level") or std.mem.eql(u8, e.kind, "battle");
}

/// Weapon_New/Item_New's object `name` of an OpenGorky project, and a battle device's
/// (combat/devices.zig): archetype `class` (a path, `items::food`: what the converter writes;
/// or a file name naming a block by its stem, `ci_food.s`: a `weapon
/// weapons::ci_food` / `item items::ci_food` / `fighter characters::ci_food` block) with
/// native state `nat`. Null: no such block.
fn newBlockItem(self: *World, name: []const u8, class: []const u8, nat: state_object.Native) anyerror!?*Object {
    const m, const e = archetypeOf(self, class, &.{ "weapon weapons::", "item items::", "fighter characters::", "weapon ", "item ", "fighter " }) orelse return null;
    return addBlockAs(self, m, e, "", name, nat);
}

/// A fighter spawned in battle from archetype `path` (`characters::grandma`; combat/debug.zig
/// spawnFile): an object of its block named `name`, with its nested blocks (its weapons).
/// Null: no such fighter block.
pub fn spawnBlock(self: *World, name: []const u8, archetype: []const u8) !?*Object {
    const m, const e = archetypeOf(self, archetype, &.{ "fighter ", "fighter characters::" }) orelse return null;
    const o = try addBlockAs(self, m, e, "", name, state_object.nativeFor(".ftr")) orelse return null;
    // As an instance's: the archetype's blocks are its own objects (`<name>_gun`).
    try addChildrenAs(self, m, e, o.name, true);
    return o;
}

/// The block archetype `class` names (`items::food` or `ci_food.s`, any case: the exe's
/// file names are), its key one of `prefixes` and the name.
fn archetypeOf(self: *World, class: []const u8, prefixes: []const []const u8) ?struct { *const ir.Module, *const ir.Entity } {
    var stem = class[if (std.mem.lastIndexOfAny(u8, class, "\\/")) |k| k + 1 else 0..];
    if (std.mem.indexOf(u8, stem, "::") == null) if (std.mem.lastIndexOfScalar(u8, stem, '.')) |k| {
        stem = stem[0..k];
    };
    var buf: [256]u8 = undefined;
    for (prefixes) |pre| {
        const key = std.fmt.bufPrint(&buf, "{s}{s}", .{ pre, stem }) catch continue;
        var it = self.rt.ogs.blocks.iterator();
        while (it.next()) |kv| if (std.ascii.eqlIgnoreCase(kv.key_ptr.*, key)) {
            const e = kv.value_ptr.*;
            return .{ moduleOf(self, e) orelse continue, e };
        };
    }
    return null;
}

/// The level a block being made again stands in (`recreateBlock`), over the world's.
var block_level: ?[]const u8 = null;

/// A carried object (world/party.zig: a hero's item, a hero who joined elsewhere) in an
/// OpenGorky project, made again from its block with native state `nat`: the archetype its
/// class is (`items::food`, Item_New's), else the nested block of that name in any
/// location (`item 01p_grenade1` of `level "01_port"`, by the last part of its path
/// `locations::_01_port::01p_grenade1`). As Classic makes it again of its class: no event
/// run (the caller restores the carried values). `nat` null: its block kind's (a save's
/// object, game/save_apply.zig). Null: no such block.
pub fn recreateBlock(self: *World, name: []const u8, ident: []const u8, nat: ?state_object.Native) !?*Object {
    const kinds = [_][]const u8{ "item", "weapon", "fighter", "hero" };
    const o = blk: {
        if (archetypeOf(self, ident, &.{ "item ", "weapon ", "fighter ", "hero " })) |x| break :blk try addBlockAs(self, x[0], x[1], "", name, nat);
        // A level's own object (`01_port/decha`, loaders/ogs.zig levelKey): that level's block.
        if (std.mem.indexOfScalar(u8, ident, '/')) |k| for (self.rt.ogs.modules.items) |*m| for (m.entities) |*top| {
            if (!std.mem.eql(u8, top.kind, "level") and !std.mem.eql(u8, top.kind, "battle")) continue;
            if (!std.ascii.eqlIgnoreCase(top.name, ident[0..k])) continue;
            if (nestedNamed(top, ident[k + 1 ..], &kinds)) |e| {
                // Its identity is its own level's, not the one it is made again in.
                block_level = top.name;
                defer block_level = null;
                break :blk try addBlockAs(self, m, e, "", name, nat);
            }
        };
        const own = if (std.mem.lastIndexOf(u8, ident, "::")) |k| ident[k + 2 ..] else ident;
        for (self.rt.ogs.modules.items) |*m| for (m.entities) |*top| if (nestedNamed(top, own, &kinds)) |e| break :blk try addBlockAs(self, m, e, "", name, nat);
        return null;
    } orelse return null;
    // Made again, not read from a location's file (addBlockAs's default).
    World.nativeOf(o).from_file = false;
    return o;
}

/// The block named `name` (any case) of one of `kinds` nested in `e`, at any depth.
fn nestedNamed(e: *const ir.Entity, name: []const u8, kinds: []const []const u8) ?*const ir.Entity {
    for (e.children) |*c| {
        for (kinds) |k| if (std.mem.eql(u8, c.kind, k) and std.ascii.eqlIgnoreCase(c.name, name)) return c;
        if (nestedNamed(c, name, kinds)) |x| return x;
    }
    return null;
}

/// ACTOR_MORPH's new class (world/spawn.zig applyMorph) in an OpenGorky project: the
/// fighter archetype the converter made of the Classic `.mtm` (`03ch_lilith_m.mtm` →
/// `fighter "03ch_lilith_m"`). Null: none.
pub fn morphTarget(self: *World, class: []const u8) ?MorphTarget {
    const m, const e = archetypeOf(self, class, &.{ "fighter characters::", "fighter " }) orelse return null;
    return .{ .m = m, .e = e };
}

const MorphTarget = struct { m: *const ir.Module, e: *const ir.Entity };

/// The model (`mesh`, its archetypes' too) of morph target `class`; null: none.
pub fn morphMesh(self: *World, class: []const u8) ?[]const u8 {
    const t = morphTarget(self, class) orelse return null;
    _, const v = valueIn(self, t.m, t.e, "mesh", 0) orelse return null;
    return if (v.kind == .lit and v.kind.lit == .string) v.kind.lit.string else null;
}

/// Actor `o` becomes block `t` (Classic: its class swapped, its variables kept, the new
/// class's init() run by the caller): its scripted components go (the old class's code),
/// its natives stay (the caller reattaches them) and so do the battle's abilities (the
/// battle swaps them by the rows, combat/events.zig attachScripts), then the block's look,
/// fields and components as at creation.
pub fn morphInto(self: *World, o: *Object, t: MorphTarget) !void {
    var k: usize = 0;
    for (o.components.items) |c| if (c.class.component == null or c.scope == .battle) {
        o.components.items[k] = c;
        k += 1;
    };
    o.components.shrinkRetainingCapacity(k);
    o.refreshImplements();
    const a = self.rt.arena();
    const cls = try a.create(Class);
    cls.* = .{ .name = "og", .parent = o.class.parent, .ident = try path(a, t.m, t.e) };
    o.class = cls;
    if (try lookOf(self, t.m, t.e, 0)) |lk| try applyLook(self, o, lk[0], lk[1]);
    try applyChain(self, o, t.m, t.e, 0);
}

const Nested = struct { m: *const ir.Module, e: *const ir.Entity, inherited: bool };

/// Into `out`: the nested blocks of `e`'s archetypes (the farthest first, `inherited`),
/// then its own; an own block of an inherited one's kind and name takes its place (and
/// its object's name).
fn nestedOf(self: *World, a: std.mem.Allocator, m: *const ir.Module, e: *const ir.Entity, out: *std.ArrayList(Nested), depth: u32) !void {
    if (depth > 16) return error.ArchetypeCycle;
    if (e.base.len > 0) {
        const bm, const b = findBlock(self, m, e.kind, e.base) orelse return error.NoArchetype;
        try nestedOf(self, a, bm, b, out, depth + 1);
        for (out.items) |*x| x.inherited = true;
    }
    next: for (e.children) |*c| {
        for (out.items) |*x| if (std.mem.eql(u8, x.e.kind, c.kind) and std.mem.eql(u8, x.e.name, c.name)) {
            x.* = .{ .m = m, .e = c, .inherited = x.inherited };
            continue :next;
        };
        try out.append(a, .{ .m = m, .e = c, .inherited = false });
    }
}

/// The `game` block's own nested blocks (shared items), then its party
/// (`party = [characters::sullivan, …]`): each hero an object of
/// its archetype's block, named by it, with its nested blocks (a hero already there, as a
/// battle's own, stays).
fn createModelParty(self: *World) !void {
    const g, const m = found: {
        for (self.rt.ogs.modules.items) |*m| for (m.entities) |*x| if (std.mem.eql(u8, x.kind, "game")) break :found .{ x, m };
        return;
    };
    // Its own objects first (the party's shared items: `gamestart\\gs_fist_all.wpn`, in
    // the exe before the heroes), then the heroes.
    for (g.children) |*c| _ = try addBlock(self, m, c, "", "");
    for (g.fields) |f| if (std.ascii.eqlIgnoreCase(f.name, "party")) {
        if (f.value.kind != .list) return std.log.warn("game party: not a list", .{});
        for (f.value.kind.list) |x| {
            if (x.kind != .word) continue;
            // A hero's (`hero sullivan`), else a fighter archetype's.
            const hm, const h = findBlock(self, m, "hero", x.kind.word) orelse findBlock(self, m, "fighter", x.kind.word) orelse {
                std.log.warn("game party: no fighter {s}", .{x.kind.word});
                continue;
            };
            if (self.rt.findObject(h.name) != null) continue;
            const o = try addBlock(self, hm, h, "", "") orelse continue;
            const n = World.nativeOf(o);
            n.kind = .actor;
            n.hero = true;
            n.hro = true;
            n.fighter = true;
            try addChildren(self, hm, h, o.name);
        }
    };
}

/// The editor's test battle (compose/og/build.zig Kit): the game block's `test_kit` heroes
/// (`[characters::sullivan, …]`) keep only the kit's things (`og_tk_*`), the ones their
/// start gave them (OnStart's item::New) gone.
fn testKit(self: *World) void {
    const g = found: {
        for (self.rt.ogs.modules.items) |*m| for (m.entities) |*x| if (std.mem.eql(u8, x.kind, "game")) break :found x;
        return;
    };
    // A test room (`test_room = 1`): its heroes are the player's to play, whatever their
    // story holds them to (Medusa: outside the party, chained until the museum's victory).
    for (g.fields) |f| if (std.mem.eql(u8, f.name, "test_room") and f.value.kind == .lit and f.value.kind.lit == .int and f.value.kind.lit.int != 0) {
        for (self.rt.objects.items) |o| {
            const n = World.nativeOf(o);
            if (n.kind != .actor or !n.hero) continue;
            o.setInt("outside_party", 0);
            fields.clearMoveLock(o);
            o.setInt("attack_locked", 0);
        }
    };
    const list = for (g.fields) |f| {
        if (std.mem.eql(u8, f.name, "test_kit") and f.value.kind == .list) break f.value.kind.list;
    } else return;
    for (self.rt.objects.items) |o| {
        const kind = World.nativeOf(o).kind;
        if (kind != .item and kind != .weapon) continue;
        if (std.mem.startsWith(u8, o.name, "og_tk_")) continue;
        const owner = fields.owner(o);
        for (list) |x| if (x.kind == .word) {
            const w = x.kind.word;
            const hero = w[if (std.mem.lastIndexOf(u8, w, "::")) |k| k + 2 else 0..];
            if (!std.ascii.eqlIgnoreCase(hero, owner)) continue;
            o.enabled = false;
            World.nativeOf(o).deleted = true;
            break;
        };
    }
}

/// OpenGorky: the script object of path `name` (`path deska { attach … }` in the level's
/// block, a Classic `<name>.pth`), its components attached; null: the level has none.
pub fn pathBlock(self: *World, name: []const u8) !?*Object {
    const lv = self.rt.ogs.blocks.get(self.res.source.level_block) orelse return null;
    const m = moduleOf(self, lv) orelse return null;
    const e = for (lv.children) |*c| {
        if (std.mem.eql(u8, c.kind, "path") and std.ascii.eqlIgnoreCase(c.name, name)) break c;
    } else return null;
    const a = self.rt.arena();
    const cls = try a.create(Class);
    cls.* = .{ .name = "og:path", .parent = null, .ident = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.level_name, e.name }) };
    const o = try self.addObject(try std.fmt.allocPrint(a, "{s}.pth", .{e.name}), cls, .{ .kind = .other });
    self.rt.applyEntity(o, m, e.*) catch |err| switch (err) {
        error.ScriptFault => std.log.warn("{s}: {f}", .{ o.name, self.rt.fault }),
        else => return err,
    };
    return o;
}

/// Object kinds by block kind, as the Classic file extensions make them.
const block_exts = [_]struct { []const u8, []const u8 }{
    .{ "level", ".lev" }, .{ "battle", ".lev" }, .{ "fighter", ".ftr" }, .{ "hero", ".hro" },        .{ "weapon", ".wpn" },   .{ "item", ".itm" },
    .{ "area", ".are" },  .{ "anim", ".ba" },    .{ "actor", ".act" },   .{ "active_anim", ".aba" }, .{ "obstacle", ".obs" },
};

/// Object of block `e` (module `m`) named `name` (else the block's); its `Owner` `owner`
/// ("" none). Null: a kind that makes no object (warned).
fn addBlock(self: *World, m: *const ir.Module, e: *const ir.Entity, owner: []const u8, name: []const u8) !?*Object {
    return addBlockAs(self, m, e, owner, name, null);
}

/// `addBlock` with native state `nat` (null: its kind's, as made from a location's file).
fn addBlockAs(self: *World, m: *const ir.Module, e: *const ir.Entity, owner: []const u8, name: []const u8, nat_as: ?state_object.Native) !?*Object {
    const ext = for (block_exts) |k| {
        if (std.mem.eql(u8, k[0], e.kind)) break k[1];
    } else {
        std.log.warn("{s} {s}: no object of this kind", .{ e.kind, e.name });
        return null;
    };
    const h = schema.blockHost(e.kind) orelse return null;
    const a = self.rt.arena();
    const cls = try a.create(Class);
    // Its archetype is its class (rules.who): `characters::grandma`; none: its own path.
    const base = if (e.base.len > 0) (findBlock(self, m, e.kind, e.base) orelse return error.NoArchetype) else null;
    // A level's own object of no archetype: `<level>/<name>` (loaders/ogs.zig levelKey).
    const lv = block_level orelse self.level_name;
    const own_key = if (base == null and m.path.len == 0 and lv.len > 0) try std.fmt.allocPrint(a, "{s}/{s}", .{ lv, e.name }) else null;
    const ident = if (base) |b| try path(a, b[0], b[1]) else own_key orelse try path(a, m, e);
    cls.* = .{ .name = "og", .parent = try hostClass(self, h), .ident = ident };
    const nat = nat_as orelse n: {
        var x = state_object.nativeFor(ext);
        x.from_file = true;
        break :n x;
    };
    const o = try self.addObject(if (name.len > 0) name else e.name, cls, nat);
    // The exe's fields with their defaults; an OpenGorky-only one (`resist`, `explodable`,
    // `ai`…) only where a block sets it: absent, the engine does what Classic does
    // (battle/generic.zig registerFighter: the rules' Resist row; fields.explodable).
    for (try schema.fields(a, h, false)) |fd| {
        var buf: [128]u8 = undefined;
        try o.declare(a, std.ascii.lowerString(&buf, fd.name), .{ .type = fd.type, .value = fd.default() });
    }
    // Its look under its archetypes' fields (an `act_*.ss` is init()'s first include).
    if (try lookOf(self, m, e, 0)) |lk| try applyLook(self, o, lk[0], lk[1]);
    try applyChain(self, o, m, e, 0);
    if (owner.len > 0) fields.setOwner(o, owner);
    if (o.getInt("classic_id") == 0) if (entity.idOf(ident)) |id| o.setInt("classic_id", id);
    return o;
}

/// Block `e`'s archetypes (the farthest first), then `e` applied to `o`.
fn applyChain(self: *World, o: *Object, m: *const ir.Module, e: *const ir.Entity, depth: u32) !void {
    if (depth > 16) return error.ArchetypeCycle;
    if (e.base.len > 0) {
        const bm, const b = findBlock(self, m, e.kind, e.base) orelse return error.NoArchetype;
        try applyChain(self, o, bm, b, depth + 1);
    }
    // The block it is one thing with (`same_as = characters::c_nato`): its values this one
    // and its archetypes leave out (schema.sameAsOf `value`), then its own over them; its own
    // variables declared without a value take that block's (`var float luck;`).
    // A module's block only (an archetype): a level's own object's `same_as` names its identity alone.
    const top = for (m.entities) |*x| {
        if (x == e) break true;
    } else false;
    const same = if (top) sameAsBlock(self, e) else null;
    if (same) |t| try fromSameAs(self, o, m, e, t, .fields);
    self.rt.applyEntity(o, m, e.*) catch |err| switch (err) {
        error.ScriptFault => std.log.warn("{s}: {f}", .{ o.name, self.rt.fault }),
        else => return err,
    };
    if (same) |t| try fromSameAs(self, o, m, e, t, .vars);
    try applyWords(self, o, m, e);
}

/// The fields of block `e` (module `m`'s) the world reads itself into `o`: references by
/// their blocks' numbers, words by their rows' (`class = pistol`, `action = Take`), the camera.
fn applyWords(self: *World, o: *Object, m: *const ir.Module, e: *const ir.Entity) !void {
    // `ammo = ~i"items::x"` (a weapon's): its classic_id, the number the core counts
    // its ammo by (the object's `ammo`, combat/weapons.zig); `thrown = true`: −1 (`false`: none, 0).
    for (e.fields) |f| if (std.mem.eql(u8, f.name, "ammo")) {
        const im, const it = findBlock(self, m, "item", schema.text(f.value) orelse continue) orelse return error.NoArchetype;
        o.setInt("ammo", try classicIdOf(self, im, it, 0));
    } else if (std.mem.eql(u8, f.name, "thrown") and f.value.kind == .lit and f.value.kind.lit == .bool) {
        o.setInt("ammo", if (f.value.kind.lit.bool) -1 else 0);
    } else if (std.mem.eql(u8, f.name, "pickable") and f.value.kind == .lit and f.value.kind.lit == .bool) {
        // `pickable = false`: the core's classic_id −1 (schema.pickable_field).
        if (!f.value.kind.lit.bool) o.setInt("classic_id", -1);
    };
    // `action = Take` (an item's, an area's; `action1`… an area's further menu rows):
    // the classic_id of that rules Action row, the number the core reads (Classic
    // `funcID`); `none` 0, `walk` −1 (no row: schema.noAction).
    for (e.fields) |f| if (actionField(f.name) and f.value.kind == .word) {
        const t = f.value.kind.word;
        const n: i32 = schema.noAction(t) orelse (rules.actionNamed(t) orelse {
            std.log.err("{s}: {s}: no rules Action {s}", .{ o.name, f.name, t });
            return error.NoAction;
        }).classic_id;
        var buf: [16]u8 = undefined;
        try o.declare(self.rt.arena(), std.ascii.lowerString(&buf, f.name), .{ .type = .int, .value = .{ .int = 0 } });
        o.getVarDyn(f.name).?.value = .{ .int = n };
    };
    // `effects_from = ~w"weapons::x"` (a weapon's; its stages `flash_from`… too): that
    // archetype's classic_id (battle/generic.zig fxId, fxOf).
    if (std.mem.eql(u8, e.kind, "weapon")) for (e.fields) |f| if (f.value.sigil == .weapon and isEffectsField(f.name)) {
        const wm, const we = findBlock(self, m, "weapon", schema.text(f.value) orelse continue) orelse return error.NoArchetype;
        try o.declare(self.rt.arena(), f.name, .{ .type = .int, .value = .{ .int = 0 } });
        o.getVarDyn(f.name).?.value = .{ .int = try classicIdOf(self, wm, we, 0) };
    };
    // `class = pistol`, `attack_zone = shotgun` (a weapon's): the number of that rules
    // WeaponClass/Pattern name, the core's (Classic `classType`; battle/weapon_class.zig).
    if (std.mem.eql(u8, e.kind, "weapon")) for (e.fields) |f| if (f.value.kind == .word and (std.mem.eql(u8, f.name, "class") or std.mem.eql(u8, f.name, "attack_zone"))) {
        const n = rules.weaponClassId(f.value.kind.word) orelse {
            std.log.err("{s}: {s}: no rules WeaponClass {s}", .{ o.name, f.name, f.value.kind.word });
            return error.NoWeaponClass;
        };
        try o.declare(self.rt.arena(), f.name, .{ .type = .int, .value = .{ .int = 0 } });
        o.getVarDyn(f.name).?.value = .{ .int = n };
    };
    // `battle_class = smokerider` (a fighter's): the number of that class name (rules
    // fighterClassId; the rows name it so too).
    for (e.fields) |f| if (std.mem.eql(u8, f.name, "battle_class")) {
        // A number as is (Classic's ally/enemy Lamar −5: no class of the table).
        const n = if (f.value.kind == .word) rules.fighterClassId(f.value.kind.word) orelse 0 else schema.int(f.value) orelse continue;
        try o.declare(self.rt.arena(), f.name, .{ .type = .int, .value = .{ .int = 0 } });
        o.getVarDyn(f.name).?.value = .{ .int = n };
    };
    // `camera = Camera(eye_x = …, …)`: the level's fields initCamera() sets (`perspective`: a bool).
    for (e.fields) |f| if (std.mem.eql(u8, f.name, "camera") and f.value.kind == .call) for (f.value.kind.call.named) |n| {
        const slot = o.getVarDyn(n.name) orelse continue;
        const x: f32 = if (n.value.kind == .lit and n.value.kind.lit == .bool) @floatFromInt(@intFromBool(n.value.kind.lit.bool)) else schema.number(n.value) orelse continue;
        slot.value = try (Value{ .float = x }).convert(slot.type, self.rt.strings());
    };
}

/// `action`, `action1`…`action9` (schema.zig actionFields).
fn actionField(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "action")) return false;
    return name.len == 6 or (name.len == 7 and std.ascii.isDigit(name[6]));
}

/// A weapon's field naming a weapon whose effects it takes (schema.zig effectsField).
fn isEffectsField(name: []const u8) bool {
    for ([_][]const u8{ "effects_from", "flash_from", "launch_from", "hit_from" }) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// Block `e`'s classic_id: its own or its nearest archetype's field, else its path's (entity.idOf).
fn classicIdOf(self: *World, m: *const ir.Module, e: *const ir.Entity, depth: u32) !i32 {
    if (depth > 16) return error.ArchetypeCycle;
    for (e.fields) |f| if (std.mem.eql(u8, f.name, "classic_id")) if (schema.int(f.value)) |n| return n;
    if (e.base.len == 0) return entity.idOf(try path(self.rt.arena(), m, e)) orelse 0;
    const bm, const b = findBlock(self, m, e.kind, e.base) orelse return error.NoArchetype;
    return classicIdOf(self, bm, b, depth + 1);
}

/// The look block `e` names (`look = looks::grandma`), else its nearest archetype's; a
/// module's block none of whose chain sets `look` takes its `same_as` block's (`look =
/// nil`: none).
fn lookOf(self: *World, m: *const ir.Module, e: *const ir.Entity, depth: u32) !?struct { *const ir.Module, *const ir.Entity } {
    if (depth > 16) return error.ArchetypeCycle;
    for (e.fields) |f| if (std.mem.eql(u8, f.name, "look")) {
        if (f.value.kind != .word) return null;
        return findBlock(self, m, "look", f.value.kind.word) orelse error.NoLook;
    };
    if (e.base.len > 0) {
        const bm, const b = findBlock(self, m, e.kind, e.base) orelse return error.NoArchetype;
        if (try lookOf(self, bm, b, depth + 1)) |x| return x;
        if (chainSets(self, bm, b, "look", 0)) return null;
    }
    const top = for (m.entities) |*x| {
        if (x == e) break true;
    } else false;
    const tm, const te = (if (top) sameAsBlock(self, e) else null) orelse return null;
    return lookOf(self, tm, te, depth + 1);
}

/// Look `lk` on actor `o` (the Classic `act_*.ss`): its fields, then its animations as
/// ActorSetWalkSpeed, RegisterIdleAnimation, RegisterAnimation register them (a hero's
/// NotInPlaceAnimation, ReferenceAnimation too).
fn applyLook(self: *World, o: *Object, m: *const ir.Module, lk: *const ir.Entity) !void {
    self.rt.applyEntity(o, m, lk.*) catch |err| switch (err) {
        error.ScriptFault => std.log.warn("{s}: {f}", .{ o.name, self.rt.fault }),
        else => return err,
    };
    if (World.nativeOf(o).kind != .actor) return;
    const a = world.actorOf(o);
    for (lk.fields) |f| if (f.value.kind == .list) for (f.value.kind.list) |x| {
        if (x.kind != .call) continue;
        const c = x.kind.call;
        const str = struct {
            fn of(cl: ir.Call, n: []const u8) []const u8 {
                return schema.text(schema.recordField(cl, n) orelse return "") orelse "";
            }
        }.of;
        const state = if (schema.recordField(c, "state")) |v| schema.int(v) orelse -1 else 0;
        if (state < 0 or state >= actor_mod.exe_states) continue;
        const st: u8 = @intCast(state);
        if (std.mem.eql(u8, f.name, "walk")) {
            a.setSpeed(str(c, "anim"), schema.number(schema.recordField(c, "speed") orelse continue) orelse continue);
        } else if (std.mem.eql(u8, f.name, "idles")) {
            a.registerIdle(st, str(c, "anim"), @intCast(@max(0, schema.int(schema.recordField(c, "weight") orelse continue) orelse continue)));
        } else if (std.mem.eql(u8, f.name, "slots")) {
            try a.registerMapping(self.gpa, st, str(c, "name"), str(c, "anim"));
        }
    };
    for (lk.fields) |f| {
        if (std.mem.eql(u8, f.name, "reference")) a.reference = schema.text(f.value) orelse continue;
        if (std.mem.eql(u8, f.name, "not_in_place") and f.value.kind == .list) for (f.value.kind.list) |x| try a.not_in_place.append(self.gpa, schema.text(x) orelse continue);
    }
}

/// The OpenGorky level's placement (restore()'s PlaceActor): one call of
/// `Level.Placement()` (a component's answer, else its default: the level's `placement`
/// field), each `Place(who, tile | at)` of it in order, then each nested block's own
/// `tile`, then its `at`. Enabled actors only, as PlaceActor; the camera snaps to the selected hero after
/// (on re-entry, world/levels.zig reenter, only when it placed one: as restore()'s PlaceActor).
pub fn placeModel(self: *World, reentry: bool) !void {
    const e = self.rt.ogs.blocks.get(self.res.source.level_block) orelse return;
    const lv = self.level orelse return;
    var none = [_]Value{};
    const answer = try dispatch.call(&self.rt, lv, traits.method("Level.Placement"), &none);
    const list = answer orelse if (lv.getVarDyn("placement")) |v| v.value else Value.nil;
    var placed = false;
    if (list == .list) for (list.list) |x| {
        if (x != .map) continue;
        const who = placeField(x, "who");
        const o = try placeable(self, if (who == .string) who.string else continue) orelse continue;
        const tile = placeField(x, "tile");
        const at = placeField(x, "at");
        if (tile == .list) {
            placeTile(self, o, tile.list);
        } else if (at == .string and at.string.len > 0) {
            queue.placeAtPoint(self, o, at.string, placeField(x, "point").toInt(), placeField(x, "floor").toInt());
        } else continue;
        placed = true;
    };
    for (e.children) |*c| for (c.fields) |f| if (std.mem.eql(u8, f.name, "tile")) if (try placeable(self, c.name)) |o| if (f.value.kind == .list) {
        var ints: [3]Value = undefined;
        const n = @min(f.value.kind.list.len, ints.len);
        for (f.value.kind.list[0..n], ints[0..n]) |x, *v| v.* = .{ .int = schema.int(x) orelse 0 };
        placeTile(self, o, ints[0..n]);
        placed = true;
    };
    // A prop's `at` (battle::PlaceProp's, builtins/combat.zig biPlaceCombatActor):
    // any actor, enabled or not, as that call places it.
    if (self.map.combat) |cm| for (e.children) |*c| for (c.fields) |f| if (std.mem.eql(u8, f.name, "at")) if (self.rt.findObject(c.name)) |o| if (World.nativeOf(o).kind == .actor and f.value.kind == .list and f.value.kind.list.len == 3) {
        const l = f.value.kind.list;
        const wp = cm.toWorld(schema.number(l[0]) orelse 0, schema.number(l[1]) orelse 0);
        fields.setPos(o, .{ wp[0], wp[1], cm.center[2] });
        fields.setAngle(o, (schema.number(l[2]) orelse 0) * std.math.pi / 180.0);
        world.actorOf(o).placed = true;
        placed = true;
    };
    if (placed or !reentry) self.out.camera_snap = true;
}

/// The level block's `entry = "<point>"`: the selected hero on that point of the level's
/// areas (point 0, floor 0), as the code it came from did right before `Level.OnRestore`
/// (builtins/actors.zig biPlaceActor: the camera snaps either way, an absent, disabled or
/// non-actor hero stays where it is).
pub fn placeEntry(self: *World) !void {
    const e = self.rt.ogs.blocks.get(self.res.source.level_block) orelse return;
    const point = for (e.fields) |f| {
        if (std.mem.eql(u8, f.name, "entry")) break schema.text(f.value) orelse return;
    } else return;
    self.out.camera_snap = true;
    const o = try placeable(self, self.selected_hero) orelse return;
    queue.placeAtPoint(self, o, point, 0, 0);
}

/// Field `name` of a `Place` value (a struct is a map by field name).
fn placeField(v: Value, name: []const u8) Value {
    for (v.map.keys, v.map.values) |k, x| if (k == .string and std.mem.eql(u8, k.string, name)) return x;
    return .nil;
}

fn placeable(self: *World, name: []const u8) !?*Object {
    // As PlaceActor (builtins/args.zig targetObject): an absent one is counted, quietly
    // (a hero not in the party yet: Medusa).
    const o = self.rt.findObject(name) orelse {
        const ar = self.arena_state.allocator();
        const gop = try self.debug.missing_objects.getOrPut(ar, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try ar.dupe(u8, name);
            gop.value_ptr.* = 0;
        }
        gop.value_ptr.* += 1;
        return null;
    };
    return if (World.nativeOf(o).kind == .actor and o.enabled) o else null;
}

/// `[x, y]` or `[x, y, direction]` (eighths of a turn), as PlaceActor's ints.
fn placeTile(self: *World, o: *Object, l: []const Value) void {
    if (l.len < 2) return;
    const at = struct {
        fn of(x: Value) f32 {
            return @floatFromInt(x.toInt());
        }
    }.of;
    queue.placeOnTile(self, o, at(l[0]), at(l[1]), if (l.len > 2) at(l[2]) else 0);
}

/// The top-level `kind` block that `name` names from module `m` (its own namespace, else
/// the root), with its module.
const Found = struct { *const ir.Module, *const ir.Entity };

/// Block `e`'s `same_as` block (a path word: any kind's); null: none.
fn sameAsBlock(self: *World, e: *const ir.Entity) ?Found {
    const v = for (e.fields) |f| {
        if (std.mem.eql(u8, f.name, "same_as")) break f.value;
    } else return null;
    if (v.kind != .word) return null;
    var buf: [256]u8 = undefined;
    // `characters::medusa<fighter>`: that kind's; else the one block at the path but this one
    // (the linker requires the kind where several have it).
    const t = ir.Import.of(v.kind.word);
    for (schema.block_kinds) |k| {
        if (t.kind.len > 0 and !std.mem.eql(u8, k, t.kind)) continue;
        const key = std.fmt.bufPrint(&buf, "{s} {s}", .{ k, t.path }) catch continue;
        if (self.rt.ogs.blocks.get(key)) |x| if (x != e) return .{ moduleOf(self, x) orelse continue, x };
    }
    return null;
}

/// The value block `b` (module `m`) or its archetypes give field or variable `n`: the
/// nearest one's, with its module.
fn valueIn(self: *World, m: *const ir.Module, b: *const ir.Entity, n: []const u8, depth: u32) ?struct { *const ir.Module, *const ir.Expr } {
    for (b.fields) |f| if (std.mem.eql(u8, f.name, n)) return .{ m, f.value };
    for (b.vars) |v| if (std.ascii.eqlIgnoreCase(v.name, n)) if (v.default) |d| return .{ m, d };
    if (b.base.len == 0 or depth > 16) return null;
    const bm, const bb = findBlock(self, m, b.kind, b.base) orelse return null;
    return valueIn(self, bm, bb, n, depth + 1);
}

/// `e` (module `m`) or its archetypes set field `n`.
fn chainSets(self: *World, m: *const ir.Module, e: *const ir.Entity, n: []const u8, depth: u32) bool {
    for (e.fields) |f| if (std.mem.eql(u8, f.name, n)) return true;
    if (e.base.len == 0 or depth > 16) return false;
    const bm, const b = findBlock(self, m, e.kind, e.base) orelse return false;
    return chainSets(self, bm, b, n, depth + 1);
}

/// Of same_as block `t` onto `o` (block `e`): `.fields` the fields `e`'s chain leaves out,
/// `.vars` the values of `e`'s variables declared without one.
fn fromSameAs(self: *World, o: *Object, m: *const ir.Module, e: *const ir.Entity, t: Found, what: enum { fields, vars }) !void {
    const tm, const te = t;
    const a = self.rt.arena();
    switch (what) {
        .fields => {
            var fs: std.ArrayList(ir.Named) = .empty;
            var at: ?*const ir.Entity = te;
            var am: *const ir.Module = tm;
            var depth: u32 = 0;
            while (at) |b| : (depth += 1) {
                for (b.fields) |f| {
                    if (!schema.sameAsField(e.kind, f.name) or chainSets(self, m, e, f.name, 0)) continue;
                    for (fs.items) |x| {
                        if (std.mem.eql(u8, x.name, f.name)) break;
                    } else try fs.append(a, f);
                }
                if (b.base.len == 0 or depth > 16) break;
                const bm, const bb = findBlock(self, am, b.kind, b.base) orelse break;
                am = bm;
                at = bb;
            }
            if (fs.items.len == 0) return;
            const synth: ir.Entity = .{ .kind = e.kind, .name = e.name, .fields = fs.items, .attach = &.{}, .line = e.line };
            self.rt.applyEntity(o, tm, synth) catch |err| switch (err) {
                error.ScriptFault => std.log.warn("{s}: {f}", .{ o.name, self.rt.fault }),
                else => return err,
            };
            try applyWords(self, o, tm, &synth);
        },
        .vars => for (e.vars) |v| {
            if (v.default != null) continue;
            const vm, const val = valueIn(self, tm, te, v.name, 0) orelse continue;
            var x = v;
            x.default = val;
            const synth: ir.Entity = .{ .kind = e.kind, .name = e.name, .fields = &.{}, .attach = &.{}, .vars = &.{x}, .line = e.line };
            self.rt.applyEntity(o, vm, synth) catch |err| switch (err) {
                error.ScriptFault => std.log.warn("{s}: {f}", .{ o.name, self.rt.fault }),
                else => return err,
            };
        },
    }
}

fn findBlock(self: *World, m: *const ir.Module, kind: []const u8, name: []const u8) ?struct { *const ir.Module, *const ir.Entity } {
    // A fighter's archetype may be a hero (`fighter x: characters::sullivan`).
    if (std.mem.eql(u8, kind, "fighter")) return findKind(self, m, "fighter", name) orelse findKind(self, m, "hero", name);
    return findKind(self, m, kind, name);
}

fn findKind(self: *World, m: *const ir.Module, kind: []const u8, name: []const u8) ?struct { *const ir.Module, *const ir.Entity } {
    var bufs: [2][256]u8 = undefined;
    const own = std.fmt.bufPrint(&bufs[0], "{s} {s}{s}{s}", .{ kind, m.path, if (m.path.len > 0) "::" else "", name }) catch return null;
    const root = std.fmt.bufPrint(&bufs[1], "{s} {s}", .{ kind, name }) catch return null;
    for ([_][]const u8{ own, root }) |k| if (self.rt.ogs.blocks.get(k)) |e| return .{ moduleOf(self, e) orelse continue, e };
    return null;
}

fn moduleOf(self: *World, e: *const ir.Entity) ?*const ir.Module {
    for (self.rt.ogs.modules.items) |*m| for (m.entities) |*x| if (x == e) return m;
    return null;
}

fn path(a: std.mem.Allocator, m: *const ir.Module, e: *const ir.Entity) ![]const u8 {
    return if (m.path.len > 0) std.fmt.allocPrint(a, "{s}::{s}", .{ m.path, e.name }) else e.name;
}

/// The class of host schema `h` and its ancestors (`isA("combatlevel")` of a battle), made once.
fn hostClass(self: *World, h: *const schema.Host) !*Class {
    var buf: [64]u8 = undefined;
    const key = try std.fmt.bufPrint(&buf, "og:{s}", .{h.name});
    if (self.rt.classes.get(key)) |c| return c;
    const a = self.rt.arena();
    const cls = try a.create(Class);
    cls.* = .{ .name = h.name, .parent = if (h.parent) |p| try hostClass(self, schema.host(p).?) else null };
    try self.rt.classes.put(a, try a.dupe(u8, key), cls);
    return cls;
}

/// Location creation, part one (0x431886): `.var` and init() of every object but the level,
/// then the level's init(). Part two is `startRestore`.
pub fn startInit(self: *World) !void {
    // Length is snapshotted: in the exe new objects (Ambient_New in init()) go to the head
    // of list [0x63bcb8] while the walk goes from the head along +0x2c0, so it never sees them.
    const objs = &self.rt.objects;
    for (0..objs.items.len) |i| {
        const o = objs.items[i];
        if (!o.enabled) continue;
        try loadVars(self, o);
        if (World.nativeOf(o).kind == .level) continue;
        try initObject(self, o);
    }
    if (self.level) |l| {
        _ = try self.rt.callIfExists(l, "initCamera", &.{});
        _ = try hooks.on(self, l, "Level.OnCamera", &.{});
        self.cam = makeCamera(self, l);
        _ = try self.rt.callIfExists(l, "init", &.{});
        _ = try hooks.on(self, l, "Object.OnCreate", &.{});
        // Combat level (restore 0x4b49f0): model scale and walk speed come from the grid
        // cell size over `.var`: `.cm` xSize/350 and xSize·0.02. A battle: the exe's class
        // declares `isCombat` (0x431404), OpenGorky's block is of kind `battle` (its class
        // a combatlevel).
        const battle = if (self.res.source.level_block.len > 0) self.isCombat() else l.getVar("isCombat") != null;
        if (self.map.combat) |cm| if (battle) {
            fields.setF(l, "actor_scale", cm.cell_size[0] / 350.0);
            fields.setF(l, "speed_scale", cm.cell_size[0] * 0.02);
        };
    }
}

/// Location creation, part two: restore() of the level and objects, post_init().
pub fn startRestore(self: *World) !void {
    const objs = &self.rt.objects;
    if (self.level) |l| {
        _ = try self.rt.callIfExists(l, "restore", &.{});
        if (self.res.source.level_block.len > 0) {
            try placeModel(self, false);
            try placeEntry(self);
        }
        _ = try hooks.on(self, l, "Level.OnRestore", &.{});
    }
    var i: usize = 0;
    while (i < objs.items.len) : (i += 1) {
        const o = objs.items[i];
        if (World.nativeOf(o).kind == .level or !World.nativeOf(o).kind.hooks().restore) continue;
        _ = try self.rt.callIfExists(o, "restore", &.{});
        _ = try hooks.on(self, o, "Anim.OnRestore", &.{});
    }
    i = 0;
    while (i < objs.items.len) : (i += 1) {
        const o = objs.items[i];
        // post_init (+0x34) runs for every new object, enabled or not (0x4319c4…0x4319cf
        // only checks +0x74 "from the global list"): 02_serwers.post_init disables
        // MacFadden before her post_init, which creates her items (mf_pistol, mf_am_pistol…).
        if (!World.nativeOf(o).kind.hooks().post_init or World.nativeOf(o).from_party) continue;
        _ = try self.rt.callIfExists(o, "post_init", &.{});
        _ = try hooks.on(self, o, "Level.OnStart", &.{});
    }
    if (self.res.source.level_block.len > 0) testKit(self);
    for (objs.items) |o| {
        try updateVisibility(self, o);
        const n = World.nativeOf(o);
        if (n.kind == .actor and (o.getInt("x") != 0 or o.getInt("y") != 0)) n.actor.placed = true;
        if (n.kind == .actor and n.actor.anim.len == 0) n.actor.pickIdle(self.crt());
    }
}

pub fn updateVisibility(self: *World, o: *Object) !void {
    const n = World.nativeOf(o);
    if (n.kind != .animation and n.kind != .active_animation) return;
    const own = if (try self.rt.callIfExists(o, "allowRender", &.{})) |v| v.exeTruth() else true;
    n.visible = own and if (try hooks.on(self, o, "Anim.CanRender", &.{})) |v| v.truth() else true;
}

fn loadVars(self: *World, o: *Object) !void {
    const v = try self.res.source.loadVars(self.rt.strings(), o.name) orelse return;
    for (v) |entry| self.rt.applyVar(o, entry.key, entry.value);
}

/// BitmapAnimation::Init (0x4b3db0): `frame` = 0, script init(), default `frames_per_second` 15.
fn initObject(self: *World, o: *Object) !void {
    const n = World.nativeOf(o);
    const is_anim = n.kind == .animation or n.kind == .active_animation;
    if (is_anim) o.setInt("frame", 0);
    _ = try self.rt.callIfExists(o, "init", &.{});
    _ = try hooks.on(self, o, "Object.OnCreate", &.{});
    if (is_anim and o.getInt("frames_per_second") == 0) o.setInt("frames_per_second", world.default_speed);
    if (n.kind == .actor) try actorHooks(self, o);
}

/// After an actor's init() (0x4225d0): additionalIdleAnims() — idles for states 7 and 8 —
/// then postinit() (heroes: ReferenceAnimation, NotInPlaceAnimation).
pub fn actorHooks(self: *World, o: *Object) !void {
    // Battle sets 7/8 and sleep 6 are copies of 0/1/0 (0x422694…0x4226ae).
    const a = world.actorOf(o);
    try a.copyState(self.gpa, 0, 7);
    try a.copyState(self.gpa, 1, 8);
    try a.copyState(self.gpa, 0, 6);
    _ = try self.rt.callIfExists(o, "additionalIdleAnims", &.{});
    _ = try self.rt.callIfExists(o, "postinit", &.{});
    _ = try hooks.on(self, o, "Actor.OnActorReady", &.{});
    // Its native abilities, for good (the panel asks them outside battles too).
    try @import("../core.zig").natives.attach(&self.rt, o);
}

/// Camera from level vars after initCamera(): perspective when perspective=1.
pub fn makeCamera(self: *World, l: *Object) camera.Camera {
    if (l.getInt("perspective") == 0) return .ortho;
    const size = self.res.source.backgroundSize() orelse return .ortho;
    const f = fields.getF;
    const p = camera.Persp.initBank(
        .{ f(l, "eye_x"), f(l, "eye_y"), f(l, "eye_z") },
        .{ f(l, "target_x"), f(l, "target_y"), f(l, "target_z") },
        f(l, "fov"),
        f(l, "camera_scale"),
        f(l, "floor_z"),
        @floatFromInt(size[0]),
        @floatFromInt(size[1]),
        f(l, "camera_bank"),
    ) orelse return .ortho;
    return .{ .persp = p.withAspect(f(l, "aspect_ratio")) };
}

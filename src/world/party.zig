//! The hero party across locations. In the exe heroes and their items are global objects;
//! here every location recreates heroes (`gamestart\*.hro`), so leaving a location captures
//! the heroes and their items and the next location applies them.
//!
//! Carried over: all hero vars (except position), skills, level points, and every item or
//! weapon owned by a hero (`Owner`). Items that no longer exist (thrown grenade) are removed.

const std = @import("std");
const state_object = @import("../state.zig").object;
const fields = @import("../fields.zig");
const walk = @import("walk.zig");
const sources = @import("sources.zig");
const snapshot = @import("snapshot.zig");
const Allocator = std.mem.Allocator;
const world = @import("../state.zig").world;
const inventory = @import("../inventory.zig");
const World = world.World;
const object = @import("../script.zig").object;
const Object = object.Object;

const VarCopy = snapshot.VarCopy;

const Entry = struct {
    name: []const u8,
    class_file: []const u8,
    /// Class source when it comes from the location archive rather than common.
    class_src: ?[]const u8 = null,
    kind: state_object.Kind,
    hero: bool,
    /// Known hero (`.hro`) outside the party: carried so later scenes can enable him
    /// (SETHERO).
    hro: bool = false,
    /// Hero deleted (DELETEOBJECT: Medusa after museum-medusa_crazy); exe heroes are global,
    /// so he is gone everywhere.
    deleted: bool = false,
    vars: []VarCopy,
    skills: []const state_object.Skill,
    stat_points: i32,
};

/// Hero position vars, kept per location.
const local_vars = [_][]const u8{ "x", "y", "z", "angle", "initok" };

pub const Party = struct {
    arena: std.heap.ArenaAllocator,
    entries: []Entry = &.{},

    pub fn deinit(self: *Party) void {
        self.arena.deinit();
    }

    /// Capture heroes and their items from the world.
    pub fn capture(gpa: Allocator, w: *World) !Party {
        var p: Party = .{ .arena = .init(gpa) };
        errdefer p.deinit();
        const a = p.arena.allocator();
        var list: std.ArrayList(Entry) = .empty;
        for (w.rt.objects.items) |o| {
            const nat = World.nativeOf(o);
            if (nat.deleted) {
                if (nat.kind == .actor and (nat.hero or nat.hro)) try list.append(a, .{
                    .name = try a.dupe(u8, o.name),
                    .class_file = try a.dupe(u8, o.class.name),
                    .kind = nat.kind,
                    .hero = false,
                    .hro = true,
                    .deleted = true,
                    .vars = &.{},
                    .skills = &.{},
                    .stat_points = 0,
                });
                continue;
            }
            const hero = nat.hero;
            if (!hero and !nat.hro and !ownedByHero(w, o)) continue;
            const vars = try snapshot.copyVars(a, o, if (hero) &local_vars else local_vars[0..0]);
            const skills = try a.dupe(state_object.Skill, nat.growth.skills.items);
            try list.append(a, .{
                .name = try a.dupe(u8, o.name),
                .class_file = try a.dupe(u8, o.class.name),
                .class_src = if (sources.localSource(w, o.class.name)) |src| try a.dupe(u8, src) else null,
                .kind = nat.kind,
                .hero = hero,
                .hro = nat.hro,
                .vars = vars,
                .skills = skills,
                .stat_points = nat.growth.stat_points,
            });
        }
        p.entries = list.items;
        return p;
    }

    /// Before the location starts: create heroes it lacks (BT) so init()/restore() see them
    /// (PlaceActor in battles).
    pub fn createMissingHeroes(self: *const Party, w: *World) !void {
        for (self.entries) |e| {
            if (!e.hero or w.rt.findObject(e.name) != null) continue;
            if (e.class_src) |src| try sources.addSource(w, e.class_file, src);
            const cls = w.rt.loadClass(e.class_file) catch |err| {
                try w.classMissing(e.class_file, err);
                continue;
            };
            _ = try w.addObject(e.name, cls, .{ .kind = .actor, .hero = true, .fighter = true });
        }
    }

    fn has(self: *const Party, name: []const u8) bool {
        for (self.entries) |e| if (std.ascii.eqlIgnoreCase(e.name, name)) return true;
        return false;
    }

    /// Apply the party to the world (after start or on return). `keep_level_disabled`
    /// (fresh load): don't enable a hero the level's init/restore disabled (he appears
    /// later via AIEnemyAppear).
    pub fn apply(self: *const Party, w: *World, keep_level_disabled: bool) !void {
        var joined: [World.max_party]*Object = undefined;
        var n_joined: usize = 0;
        for (self.entries) |e| {
            var obj = w.rt.findObject(e.name);
            const existed = obj != null;
            // Not in the party: the location's own copy wins; without one, create it disabled.
            // If that copy is still in the party (stored before he left or was deleted), take
            // him out: in the exe a hero is one object for the whole game (Medusa, deleted in
            // the observatory, used to come back in 03_museum).
            if (!e.hero and e.hro and obj != null) {
                const nat = World.nativeOf(obj.?);
                if (nat.hero) {
                    nat.hero = false;
                    obj.?.enabled = false;
                    if (e.deleted) nat.deleted = true;
                }
                continue;
            }
            if (e.deleted) continue;
            if (obj == null) {
                // A hero who joined during the game (BT), from his class source.
                if (e.class_src) |src| try sources.addSource(w, e.class_file, src);
                const cls = w.rt.loadClass(e.class_file) catch |err| {
                    try w.classMissing(e.class_file, err);
                    continue;
                };
                const o = try snapshot.recreate(w, e.name, cls, .{ .kind = e.kind, .hero = e.hero, .hro = e.hro, .fighter = e.hero or e.hro }, e.hero or e.hro);
                obj = o;
                if (e.hero and e.kind == .actor and n_joined < joined.len) {
                    joined[n_joined] = o;
                    n_joined += 1;
                }
            }
            const o = obj.?;
            const nat = World.nativeOf(o);
            nat.from_party = true;
            nat.deleted = false;
            nat.hero = e.hero;
            if (!(keep_level_disabled and existed and e.hero and !o.enabled)) o.enabled = e.hero or !e.hro;
            try snapshot.restore(w, o, e.vars, e.skills, e.stat_points);
        }
        for (joined[0..n_joined]) |o| if (o.enabled) walk.placeBesideLead(w, o);
        // Remove items of carried heroes that the party no longer has (thrown grenade).
        // Items of heroes first met here (Medusa) are untouched.
        for (w.rt.objects.items) |o| {
            const nat = World.nativeOf(o);
            if (nat.hero or nat.deleted or !ownedByHero(w, o)) continue;
            if (!self.has(fields.owner(o))) continue;
            const known = self.has(o.name);
            if (!known) {
                nat.deleted = true;
                o.enabled = false;
            }
        }
    }
};

/// Item that travels with the party (0x4adcd0, vtable +0x80): `place > 0` and owned by a
/// hero (flag +0x2cd, 0x4ad2b6), or `place == 200`. Items put on the ground (the gas tank
/// at the rubble, place 0) stay on their location.
fn ownedByHero(w: *World, o: *Object) bool {
    const nat = World.nativeOf(o);
    if (nat.kind != .item and nat.kind != .weapon) return false;
    const place = inventory.item.placeOf(o);
    if (place == .party) return true;
    if (@backingInt(place) <= 0) return false;
    const owner = fields.owner(o);
    if (owner.len == 0) return false;
    const h = w.rt.findObject(owner) orelse return false;
    return World.nativeOf(h).hero or World.nativeOf(h).hro;
}

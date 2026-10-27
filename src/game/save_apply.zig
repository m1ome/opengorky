//! Applies a save (format: save.zig) to a freshly created world (game.Game.load).

const std = @import("std");
const state_object = @import("../state.zig").object;
const fields = @import("../fields.zig");
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const WorldState = @import("../save.zig").WorldState;
const snapshot = @import("../world.zig").snapshot;
const sources = @import("../world.zig").sources;
const walk = @import("../world.zig").walk;
const inventory = @import("../inventory.zig");

pub fn apply(ws: *const WorldState, w: *World) !void {
    const ra = w.rt.arena();
    w.scene.dropForLoad();
    for (ws.objects) |e| {
        var obj = w.rt.findObject(e.name);
        if (obj == null) {
            if (e.kind == .ambient) continue;
            const cls = w.rt.loadClass(e.class_file) catch blk: {
                // Class from another location's archive (items picked up there).
                if (!try sources.addForeignSource(w, e.class_file)) {
                    try w.countMissing("class ", e.class_file);
                    continue;
                }
                break :blk w.rt.loadClass(e.class_file) catch |err| {
                    try w.classMissing(e.class_file, err);
                    continue;
                };
            };
            var nat = state_object.nativeFor(std.fs.path.extension(e.class_file));
            nat.kind = e.kind;
            // A recreated actor (hero who joined elsewhere: MacFadden, Medusa) gets init() as in
            // party transfer; vars then come from the save.
            obj = try snapshot.recreate(w, e.name, cls, nat, e.kind == .actor);
        }
        const o = obj.?;
        const n = World.nativeOf(o);
        // Party membership comes from the save: BT is created as a non-hero on his own
        // location and joins via the meeting scene's SETHERO.
        n.hero = e.hero;
        o.enabled = e.enabled;
        n.deleted = e.deleted;
        n.actor.placed = e.placed;
        n.actor.map = e.map;
        n.actor.state = e.state;
        n.actor.idle_off = e.idle_off;
        // Takes effect at the pickIdle below (the exe restores currentAnimID beside it).
        n.actor.forced_idle = if (e.idle_anim.len == 0) null else try ra.dupe(u8, e.idle_anim);
        n.actor.resetForLoad();
        // Item animation (open/closed box) jumps to its last frame; otherwise the fresh
        // post_init's "closed" would remain.
        if ((e.kind == .item or e.kind == .weapon) and e.anim.len > 0) n.actor.holdLast(try ra.dupe(u8, e.anim), e.anim_reverse);
        try snapshot.restore(w, o, e.vars, e.skills, e.stat_points);
    }
    // Objects the save lacks: ones scripts made again (Item_New in post_init) are deleted;
    // a script file of the archive newer than the save (a mod's hero, enemy, box) stays
    // as created, as in the exe.
    for (w.rt.objects.items) |o| {
        const n = World.nativeOf(o);
        if (n.kind == .ambient or n.kind == .level or n.from_file) continue;
        const known = for (ws.objects) |e| {
            if (std.ascii.eqlIgnoreCase(e.name, o.name)) break true;
        } else false;
        if (!known) {
            n.deleted = true;
            o.enabled = false;
        }
    }
    restoreAmmoPacks(w);
    // Stance by weapon and mode (old saves had stance 1 outside battle).
    inventory.equipment.refreshHoldStates(w);
    walk.unstickHeroes(w);
    for (w.rt.objects.items) |o| {
        const n = World.nativeOf(o);
        if (n.kind == .actor) n.actor.pickIdle(w.crt());
    }
    // Area walkability (0x47a040): forbids first, then allows.
    for ([_]bool{ false, true }) |allow| for (ws.walk) |wa| if (wa.allow == allow) try walk.setWalkInArea(w, wa.name, allow, wa.floor);
}

/// Repairs saves made before disabled objects got post_init: a hero who joined on his own
/// location (MacFadden in 02_serwers) lacked ammo packs because the post_init creating them
/// (Item_New(…, 0)) never ran. Giving ammo (0x4b3630) only fills the receiver's pack
/// (0x47d880), so it got "No ammo". In the exe every hero has packs of all kinds (9 per
/// .hro); a missing pack is created empty from another hero's pack class.
fn restoreAmmoPacks(w: *World) void {
    const heroes = w.party();
    const party = heroes.slice();
    for (party) |h| {
        var i: usize = 0;
        while (i < w.rt.objects.items.len) : (i += 1) {
            const p = w.rt.objects.items[i];
            if (!world_mod.isItem(p) or inventory.item.typeOf(p) != .ammo) continue;
            const owner = fields.owner(p);
            const of_party = for (party) |q| {
                if (std.ascii.eqlIgnoreCase(q.name, owner)) break true;
            } else false;
            if (!of_party) continue;
            _ = inventory.ammo.ammoPackOf(w, h, p);
        }
    }
}

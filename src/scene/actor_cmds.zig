//! Scene commands for actors and objects: animations, placement, walking, items,
//! morphs, attacks, rockets.

const std = @import("std");
const num = @import("../num.zig");
const fields = @import("../fields.zig");
const inventory = @import("../inventory.zig");
const spawn = @import("../world.zig").spawn;
const walk = @import("../world.zig").walk;
const floor = @import("../world.zig").floor;
const queue = @import("../world.zig").queue;
const bitmap_anim = @import("../world.zig").bitmap_anim;
const scriptlet = @import("../formats.zig").scriptlet;
const fx_mod = @import("../fx.zig");
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const Runner = @import("../state.zig").scene.Runner;
const Object = @import("../script.zig").object.Object;
const actor_mod = @import("../actor.zig");

fn enqueue(w: *World, o: *Object, cmd: actor_mod.command.Command) !void {
    const a = world_mod.actorOf(o);
    try a.queue.append(w.gpa, cmd);
    try queue.runQueue(w, o, a);
}

fn placeAt(w: *World, o: *Object, p: scriptlet.Point) void {
    const a = world_mod.actorOf(o);
    a.attached_to = null;
    // 0x422dd0 → 0x427c10: queue and path reset, so a one-shot animation (Slavsky's
    // knees in museum-slavsky) no longer holds anyone.
    a.dropCommands(w.crt());
    fields.setPos(o, floor.groundOn(w, a.map, .{ p.x, p.y }));
    fields.setAngle(o, p.angle);
    a.placed = true;
}

/// Actors and objects: animations, placement, walking, items, morphs, attacks.
pub fn execActor(self: *Runner, w: *World, c: scriptlet.Command, n: []const u8) !bool {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(n, "ANIMATION")) {
        // Into the actor's queue (0x47734c, command 0x13): raw name, repeats, reverse;
        // the scene doesn't wait (sync is WAITFORACTOR).
        if (self.skip) return true;
        const o = w.actorObject(c.arg(0).str()) orelse return true;
        const count: u8 = if (c.args.len > 2) @intCast(std.math.clamp(c.arg(2).int(), 1, 255)) else 1;
        try enqueue(w, o, .{ .scene_anim = .{ .name = c.arg(1).str(), .count = count, .reverse = c.args.len > 3 and c.arg(3).num() != 0 } });
        return true;
    }
    if (eq(n, "IDLE_ANIMATION")) {
        const o = w.actorObject(c.arg(0).str()) orelse return true;
        try enqueue(w, o, .{ .idle_anim = c.arg(1).str() });
        return true;
    }
    if (eq(n, "ACTORSETSTATE")) {
        const o = w.actorObject(c.arg(0).str()) orelse return true;
        const a = world_mod.actorOf(o);
        a.state = @intCast(std.math.clamp(c.arg(1).int(), 0, actor_mod.max_states - 1));
        a.forced_idle = null;
        return true;
    }
    if (eq(n, "PLACE")) {
        const o = w.actorObject(c.arg(0).str()) orelse return true;
        const p = self.point(c.arg(1).str()) orelse return true;
        // placeAt resets the queue and path (0x427c10): a companion still following the
        // hero into the scene area would otherwise walk past the point (museum-medusa_crazy).
        // PLACE(actor, point, floor) (0x422c90): floor ≥ 0 switches the actor's map
        // (+0x3190), height from that map's cell. Without a third argument the exe
        // passes 0 (0x476887 `push 0`), i.e. floor 0: BT, put on floor 1 by port-deska
        // (PLACE("Bt","bt_p1",1)), returns to the ground in port-meet_bt
        // (PLACE("BT","bt_p1")); otherwise after the trabant battle he stayed on the
        // .wm2 map and couldn't move.
        const fl = c.arg(2).num();
        if (fl >= 0) world_mod.actorOf(o).map = if (fl >= 1) 1 else 0;
        placeAt(w, o, p);
        return true;
    }
    if (eq(n, "WALKTO")) {
        const o = w.actorObject(c.arg(0).str()) orelse return true;
        const p = self.point(c.arg(1).str()) orelse return true;
        // Scene skip: straight to the point (0x422c90).
        if (self.skip) {
            placeAt(w, o, p);
            return true;
        }
        try enqueue(w, o, .{ .walk = .{ p.x, p.y } });
        // 0x4789fa → 0x4272c0 → 0x427340: on arrival turn to the point's angle (third
        // coordinate, normalized to 0…2π; command 0x12). Without it heroes stayed facing
        // the walk direction, back to the people they talk to.
        const tau = 2 * std.math.pi;
        try enqueue(w, o, .{ .angle = @mod(@mod(p.angle, tau) + tau, tau) });
        return true;
    }
    if (eq(n, "DISABLEOBJECT")) {
        // Second argument 0 enables (that's how scene actors appear).
        const o = w.rt.findObject(c.arg(0).str()) orelse return true;
        o.enabled = c.args.len > 1 and c.arg(1).num() == 0;
        return true;
    }
    if (eq(n, "DELETEOBJECT")) {
        const o = w.rt.findObject(c.arg(0).str()) orelse return true;
        o.enabled = false;
        World.nativeOf(o).deleted = true;
        return true;
    }
    if (eq(n, "WALK_ANIMATION")) {
        // Into the queue (command 0x28): walk animation for later paths; speed is
        // arg·0.01 in ActorSetWalkSpeed units (0 = unchanged), step ·speedScale.
        const o = w.actorObject(c.arg(0).str()) orelse return true;
        const sp: ?f32 = if (c.arg(2).num() > 0) c.arg(2).num() * 0.01 else null;
        try enqueue(w, o, .{ .walk_anim = .{ .name = c.arg(1).str(), .speed = sp } });
        return true;
    }
    if (eq(n, "IMPULSEOBJECT")) {
        const o = w.rt.findObject(c.arg(0).str()) orelse return true;
        if (World.nativeOf(o).kind == .active_animation) bitmap_anim.impulse(o, c.arg(1).int());
        return true;
    }
    if (eq(n, "FAST_ANIMATION")) {
        // At once, no queue or blend, from the first frame (0x47728c).
        const o = w.actorObject(c.arg(0).str()) orelse return true;
        const a = world_mod.actorOf(o);
        a.queue.clearRetainingCapacity();
        a.play(c.arg(1).str(), false, true);
        return true;
    }
    if (eq(n, "ASSIGN_ITEM")) {
        // Item to an actor (0x477d4d): ammo (type 10) is added to its first pack of the
        // same nameID (0x47d880 searches before the owner changes, so the item itself is
        // never found wherever it is in the list) and the item is deleted (+0x60);
        // anything else goes into the backpack (place 1) with the owner (0x4adad0).
        const o = w.rt.findObject(c.arg(1).str()) orelse return true;
        if (inventory.item.typeOf(o) == .ammo) {
            if (inventory.ammo.heroAmmo(w, c.arg(0).str(), fields.nameId(o), o)) |pack| fields.setCounter(pack, fields.counter(pack) + fields.counter(o));
            World.nativeOf(o).deleted = true;
            o.enabled = false;
            return true;
        }
        fields.setOwner(o, try w.rt.arena().dupe(u8, c.arg(0).str()));
        inventory.item.setPlace(o, .backpack);
        return true;
    }
    if (eq(n, "WALKAREA") or eq(n, "FORBID_WALK_IN_AREA") or eq(n, "ALLOW_WALK_IN_AREA")) {
        const allow = if (eq(n, "WALKAREA")) c.arg(2).num() != 0 else eq(n, "ALLOW_WALK_IN_AREA");
        try walk.setWalkInArea(w, c.arg(0).str(), allow, c.arg(1).int());
        return true;
    }
    if (eq(n, "ACTOR_MORPH")) {
        // ACTOR_MORPH(actor, "class.mtm", "model", "idle anim"): BT turns into the
        // "Schizo family" before the last battle.
        const o = w.actorObject(c.arg(0).str()) orelse return true;
        try spawn.morphActor(w, o, c.arg(1).str(), c.arg(2).str(), c.arg(3).str());
        return true;
    }
    if (eq(n, "ROCKET")) {
        // ROCKET(actor, x, y, z) (0x476e9f): rocket from the actor's hands to a world point.
        const o = w.actorObject(c.arg(0).str()) orelse return true;
        try launchRocket(w, o, .{ c.arg(1).num(), c.arg(2).num(), c.arg(3).num() });
        return true;
    }
    if (eq(n, "WEAPON")) {
        // WEAPON(actor, mesh[, n]) (0x478500): mesh into the hand, on `two_hands` with
        // state 1 if there is a third argument, else on `one_hand` with state 0 (8 / 7 in
        // battle); WEAPON(actor) removes it, state 0 (0x42b450).
        const o = w.actorObject(c.arg(0).str()) orelse return true;
        const a = world_mod.actorOf(o);
        const combat: u8 = if (w.isCombat()) 7 else 0;
        if (c.args.len >= 2 and c.arg(1).str().len > 0) {
            const two = c.args.len > 2;
            a.scene_weapon = .{ .mesh = try w.arena_state.allocator().dupe(u8, c.arg(1).str()), .two_hands = two };
            a.state = combat + @intFromBool(two);
        } else {
            a.scene_weapon = null;
            a.state = combat;
        }
        return true;
    }
    if (eq(n, "ATTACK")) {
        // ATTACK(actor) (0x4770a4): a two-handed item in hand uses two_hands and
        // "attack_sniper", else one_hand and "attack_gun"; queued. Weapon and stance at
        // once (0x42b450, 0x42ac30), the animation as a deferred command (type 4,
        // 0x47725a), absent when skipped. Empty hands (+0x3250 == 0, 0x477109): the line
        // just completes (0x47689c), no stance, no animation.
        const o = w.actorObject(c.arg(0).str()) orelse return true;
        const a = world_mod.actorOf(o);
        const it = inventory.equipment.equipped(w, o, .hand) orelse return true;
        const two = it.getInt("two_handed") != 0;
        a.scene_weapon = .{ .mesh = fields.meshFile(it), .two_hands = two };
        a.state = @intFromBool(two);
        if (self.skip) return true;
        // Logical names (RegisterAnimation: attack_gun → "pistol", attack_sniper →
        // "g_sniper") resolve by the stance set above.
        try enqueue(w, o, .{ .scene_anim = .{ .name = a.resolve(if (two) "attack_sniper" else "attack_gun") } });
        return true;
    }
    if (eq(n, "ACTOR_GOINDOWN")) {
        // ACTOR_GOINDOWN(actor, z, speed) (0x478170): z toward the target by speed·0.01.
        if (self.skip) return true;
        const o = w.actorObject(c.arg(0).str()) orelse return true;
        self.wait = .{ .goindown = .{ .o = o, .z = c.arg(1).num(), .step = @max(0.01, c.arg(2).num() * 0.01) } };
        return true;
    }
    if (eq(n, "FX_WEAPON")) {
        // FX_WEAPON(actor, 0|1) (0x476d89): muzzle flash, pistol or chaingun.
        const o = w.actorObject(c.arg(0).str()) orelse return true;
        fx_mod.hits.onHitId(w, o, if (c.arg(1).num() != 0) 1023 else 49, fields.pos(o));
        return true;
    }
    if (eq(n, "VOLTAGE")) {
        // VOLTAGE(actor) (0x476dff → 0x4a44e0): Medusa's current, arcs current1→3, 2→4.
        const o = w.actorObject(c.arg(0).str()) orelse return true;
        fx_mod.hits.current(w, o);
        return true;
    }
    return false;
}

/// ROCKET(actor, x, y, z) (0x476e9f): launcher rocket (0x49d8d0, like hero code
/// 23 at 0x48781c) from the actor's hands to world point x, y, z; no weapon or
/// target. The command has no sound; "bazooka.wav" is in the g_bazooka animation.
fn launchRocket(self: *World, from: *Object, target: [3]f32) !void {
    const id = fx_mod.launch.sceneRocket(self, from, target);
    if (id != 0) try self.scene.rockets.append(self.gpa, .{ .id = id, .target = target });
}

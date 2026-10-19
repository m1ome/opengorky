//! Fighter states: sleep, gas, fire, freeze, rage, poison; hazard tiles.

const fields = @import("../fields.zig");
const inventory = @import("../inventory.zig");
const scenes = @import("../scene.zig").scenes;
const spawn = @import("../world.zig").spawn;
const battle = @import("../battle.zig").battle;
const Battle = battle.Battle;
const rules = @import("../battle.zig").rules;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const immunity = @import("../battle.zig").immunity;
const grid = @import("../battle.zig").grid;
const Tile = grid.Tile;
const Fighter = @import("../battle.zig").fighter.Fighter;

/// Apply a state (0x4900f0). Resistance: monsters by table, heroes by worn armour
/// (`pr*` of the item). Applied during the enemy turn (`[0x6c4e88]`) it lasts one turn longer.
pub fn applyEffect(self: *Battle, w: *World, f: *Fighter, kind: rules.Effect) void {
    // Obstacles take no states, except fire on a barrel (0x4900f0).
    if (f.side == .neutral and !(f.explosive and kind == .burn)) return;
    if (immunity.effectCode(kind)) |code| {
        if (resistsDiscover(self, w, f.*, code)) return;
    }
    // Applied during the enemy turn (`[0x6c4e88]`): one turn longer, so the
    // end-of-turn countdown does not eat the victim's turn.
    const extra: i32 = @intFromBool(self.enemy_period);
    switch (kind) {
        .burn => {
            f.burning = 3 + extra;
            f.frozen = 0;
        },
        .freeze => {
            f.burning = 0;
            f.soaked = 0;
            f.frozen = 2 + extra;
        },
        .gas => f.gassed = 3 + extra,
        .soak => if (f.burning > 0) {
            f.burning = 3;
        } else {
            f.soaked = 3 + extra;
        },
        .defend => f.defending = true,
        // Sleep (0x49036f): unless defending, stance 6 (sleep) and the weapon leaves the
        // hand (+0x30d0 = 0, 0x490397); when defending nothing changes.
        .sleep => {
            f.asleep = 2 + extra;
            // The turn is lost at once (0x49037d…0x49038b): walked = whole walk_range,
            // acted, turn over (+0x2460c…+0x24614).
            f.used = @floatFromInt(fields.walkRange(f.obj));
            f.acted = true;
            if (!f.defending) {
                const a = world_mod.actorOf(f.*.obj);
                a.state = 6;
                a.weapon_detached = true;
            }
        },
        .bite => f.bitten = true,
    }
    battle.note(self, "  {s}: state {d}", .{ f.obj.name, @backingInt(kind) });
}

/// Tranquilizer antidote (0x49006d): sleep removed, the turn restarts (walked 0,
/// not acted, +0x2460c…+0x24614); stance 0x42b450: 4 when defending (idle,
/// 0x422f90), else 0 (7 in battle).
pub fn wake(w: *World, f: *Fighter) void {
    f.asleep = 0;
    f.used = 0;
    f.acted = false;
    const a = world_mod.actorOf(f.*.obj);
    a.setState(if (f.defending) 4 else 0, true);
    if (f.defending) a.pickIdle(w.crt());
}

pub fn setHazard(self: *Battle, layer: []u8, t: Tile, v: u8) void {
    if (!self.grid().inside(t)) return;
    const i = grid.tileIndex(self.width, t);
    layer[i] = @max(layer[i], v);
}

pub fn hazardAt(self: *Battle, layer: []const u8, t: Tile) u8 {
    if (!self.grid().inside(t)) return 0;
    return layer[grid.tileIndex(self.width, t)];
}

/// A fighter on a burning tile catches fire (0x48f820), in gas gets poisoned (0x48f8c0).
pub fn hazardCheck(self: *Battle, w: *World, f: *Fighter) void {
    if (!f.alive() or f.appear_to != null) return;
    var on_fire = false;
    var in_gas = false;
    for (0..f.size) |dy| for (0..f.size) |dx| {
        const t: Tile = .{ f.tile[0] + @as(i32, @intCast(dx)), f.tile[1] + @as(i32, @intCast(dy)) };
        if (hazardAt(self, self.fire, t) > 0) on_fire = true;
        if (hazardAt(self, self.gas, t) > 0) in_gas = true;
    };
    // In the exe this is the fighter's turn start (0x48f6f0 via vtable +0xc0), before
    // the enemy-turn flag (0x498448 before 0x498460): fire and gas underfoot last the
    // usual 3 turns with damage that turn (else 4 turns and no damage: napalm didn't burn).
    const period = self.enemy_period;
    self.enemy_period = false;
    defer self.enemy_period = period;
    if (on_fire) applyEffect(self, w, f, .burn);
    if (in_gas) applyEffect(self, w, f, .gas);
}

pub fn tickLilith(self: *Battle, w: *World) !void {
    if (self.lilith_ticks > 0) {
        self.lilith_ticks -= 1;
        if (self.lilith_ticks == 0) {
            self.lilith_dialog_ticks = 80;
            if (w.rt.findObject("03ch_lilith1")) |o| {
                fields.clearMoveLock(o);
                o.setInt("attackLock", 0);
                try spawn.morphActor(w, o, "03ch_lilith_m.mtm", "lilith", "dech");
                w.out.sound(w.gpa, "transformation", null);
                battle.note(self, "  {s}: transform", .{o.name});
            }
        }
    }
    if (self.lilith_dialog_ticks > 0) {
        self.lilith_dialog_ticks -= 1;
        if (self.lilith_dialog_ticks == 0) try scenes.startDialog(w, "03__museum_child_2", "03__museum_child2.dlg");
    }
}

/// Monster resistance by table: on first trigger a popup over it (string.tab
/// 801–808) and the "known" mark (0x4caa80: 1 → 2).
pub fn resistsDiscover(self: *Battle, w: *World, f: Fighter, code: immunity.Resist) bool {
    const id = fields.nameId(f.obj);
    if (w.immunity.immune(id, code)) {
        if (w.immunity.discover(id, code)) {
            battle.popup(self, f, w.stringOr(800 + @as(i32, @backingInt(code)), immunity.protection_text[code.index()]), .info) catch {};
            battle.note(self, "  {s}: {s}", .{ f.obj.name, immunity.protection_text[code.index()] });
        }
        return true;
    }
    return f.side == .hero and inventory.equipment.armorProtects(w, f.obj, code);
}

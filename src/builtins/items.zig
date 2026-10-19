//! Script builtins: items and weapons (Item_*, Weapon_New, ammo).
const state_object = @import("../state.zig").object;
const fields = @import("../fields.zig");
const areas = @import("../world.zig").areas;

const floor = @import("../world.zig").floor;
const runtime = @import("../script.zig").runtime;
const inventory = @import("../inventory.zig");
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const Object = @import("../script.zig").object.Object;
const Runtime = runtime.Runtime;
const value = @import("../script.zig").value;
const Value = value.Value;
const args_mod = @import("args.zig");

pub fn biActorHaveAmmoForWeapon(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const wpn = rt.findObject(args_mod.argString(args, 1)) orelse return .zero;
    if (World.nativeOf(wpn).kind != .weapon) return .zero;
    return .{ .int = @intFromBool(args_mod.ownerHasAmmo(args_mod.worldOf(ctx), args_mod.argString(args, 0), wpn)) };
}

/// AnyHero_HaveAmmoForWeapon(weapon) (0x4c0630): anyone in the party.
pub fn biAnyHeroHaveAmmoForWeapon(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const wpn = rt.findObject(args_mod.argString(args, 0)) orelse return .zero;
    if (World.nativeOf(wpn).kind != .weapon) return .zero;
    const heroes = w.party();
    for (heroes.slice()) |h| if (args_mod.ownerHasAmmo(w, h.name, wpn)) return .{ .int = 1 };
    return .zero;
}

pub fn biWeaponNew(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    try itemNew(args_mod.worldOf(ctx), args, .weapon);
    return .zero;
}

pub fn biItemNew(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    try itemNew(args_mod.worldOf(ctx), args, .item);
    return .zero;
}

/// Weapon_New / Item_New (name, "class.s", owner[, count]): a string 3rd argument is the
/// owner, a number the counter; the 4th, if any, is the counter.
fn itemNew(w: *World, args: []const Value, kind: state_object.Kind) !void {
    const third: ?Value = if (args.len > 2) args[2] else null;
    const owner: ?[]const u8 = if (third) |v| (if (v == .string) v.string else null) else null;
    var counter: ?i32 = if (third) |v| (if (v != .string) v.toInt() else null) else null;
    if (args.len > 3) counter = args[3].toInt();
    _ = try inventory.create.newItem(w, args_mod.argString(args, 0), args_mod.argString(args, 1), owner, counter, kind);
}

/// FighterSetWeaponSkillLevel(fighter, weapon nameID, level) (0x4be990 → 0x48fe30).
pub fn biFighterSetWeaponSkillLevel(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.targetObject(ctx, rt, args) orelse return .zero;
    if (args.len < 3 or World.nativeOf(o).kind != .actor) return .zero;
    const skills = &World.nativeOf(o).growth.skills;
    const id = args[1].toInt();
    for (skills.items) |*sk| if (sk.id == id) {
        sk.level = args[2].toInt();
        return .zero;
    };
    try skills.append(args_mod.worldOf(ctx).gpa, .{ .id = id, .level = args[2].toInt() });
    return .zero;
}

pub fn biItemGetNameID(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    return args_mod.itemField(ctx, rt, self, args, "nameID");
}

/// Item_Animation(item, "anim", reverse): item model animation (box: Open is
/// "box", Close is "box" reversed); the last frame is held.
pub fn biItemAnimation(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.objectArg(ctx, rt, self, args) orelse return .zero;
    const a = world_mod.actorOf(o);
    a.play(args_mod.argString(args, 1), false, false);
    a.hold_last = true;
    a.reverse = args.len > 2 and args[2].toInt() != 0;
    return .zero;
}

/// Item_SetPos(item, x, y, z) (0x4c0fe0): world coordinates; or
/// Item_SetPos(item, "area", point, z) (0x4ad6f0): an area polygon point (−1 =
/// control point) on the `.wm` floor raised by z, its angle becomes walk_angle,
/// approach point (x, y + 20) in background pixels (gas bottle at the port tunnel rubble).
pub fn biItemSetPos(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.objectArg(ctx, rt, self, args) orelse return .zero;
    if (args.len < 4) return .zero;
    if (args[1] != .string) {
        fields.setPos(o, .{ args[1].toFloat(), args[2].toFloat(), args[3].toFloat() });
        return .zero;
    }
    const w = args_mod.worldOf(ctx);
    const area = areas.findArea(w, args[1].string) orelse return .zero;
    const idx = args[2].toInt();
    if (idx < -1 or idx >= @as(i32, @intCast(area.points.len))) return .zero;
    var bg: [2]f32 = area.control;
    if (idx >= 0) {
        const pt = area.points[@intCast(idx)];
        bg = .{ pt[0], pt[1] };
        fields.setF(o, "walk_angle", pt[2]);
    }
    bg = .{ @trunc(bg[0]), @trunc(bg[1]) };
    const h: f32 = if (w.walk_map) |m| floor.floorHeight(m, bg) else 0;
    o.setInt("walk_x", value.floatToInt(bg[0]));
    o.setInt("walk_y", value.floatToInt(bg[1] + 20));
    fields.setPos(o, w.cam.unproject(bg[0], bg[1], h + args[3].toFloat()));
    return .zero;
}

pub fn biItemSetAngle(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.objectArg(ctx, rt, self, args) orelse return .zero;
    if (args.len > 1) fields.setAngle(o, args[1].toFloat());
    return .zero;
}

pub fn biItemSetNameID(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.objectArg(ctx, rt, self, args) orelse return .zero;
    if (args.len > 1) fields.setNameId(o, args[1].toInt());
    return .zero;
}

pub fn biItemDisableWalkCircle(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    return args_mod.walkCircle(ctx, rt, self, args, false);
}

pub fn biItemEnableWalkCircle(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    return args_mod.walkCircle(ctx, rt, self, args, true);
}

/// Item_SetPlace(item, place) (0x4c0f80 → 0x4add00). Place 0 (ground) for an
/// owned item clears the owner (0x4adad0("")); taken from the hand, the hero gets
/// the unarmed stance (0x4add74 → 0x42b450). The pier plank and the port tunnel
/// gas bottle leave the inventory for good this way.
pub fn biItemSetPlace(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const o = args_mod.objectArg(ctx, rt, self, args) orelse return .zero;
    if (args.len < 2 or args[1] != .int or !world_mod.isItem(o)) return .zero;
    const place = args[1].int;
    const owner = fields.owner(o);
    if (place == 0 and owner.len > 0) {
        const was = o.getInt("place");
        const hero = w.actorObject(owner);
        fields.setOwner(o, "");
        if (was == inventory.item.place_hand) if (hero) |h| inventory.equipment.setHoldState(w, h, null);
    }
    o.setInt("place", place);
    return .zero;
}

pub fn biItemGetPlace(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    return args_mod.itemField(ctx, rt, self, args, "place");
}

pub fn biItemSetVisible(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.objectArg(ctx, rt, self, args) orelse return .zero;
    if (args.len > 1) o.setInt("visible", args[1].toInt());
    return .zero;
}

pub fn biItemSetFuncID(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.objectArg(ctx, rt, self, args) orelse return .zero;
    if (args.len > 1) o.setInt("funcID", args[1].toInt());
    return .zero;
}

pub fn biItemGetType(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    return args_mod.itemField(ctx, rt, self, args, "type");
}

/// AnyHero_HaveItem("item") (0x4c05a0): the item's `Owner` is a hero.
pub fn biAnyHeroHaveItem(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    _ = ctx;
    const o = rt.findObject(args_mod.argString(args, 0)) orelse return .zero;
    if (!world_mod.isItem(o)) return .zero;
    const owner = rt.findObject(fields.owner(o)) orelse return .zero;
    return .{ .int = @intFromBool(World.nativeOf(owner).hero) };
}

//! Shared builtin helpers: object from an argument, flags, animation state,
//! calls deferred until a level load. Below the table (builtins.zig) and the
//! topic builtins that call them.

const std = @import("std");
const state_groups = @import("../state.zig").groups;
const value = @import("../script.zig").value;
const fields = @import("../fields.zig");
const level_files = @import("../formats.zig").level_files;
const floor = @import("../world.zig").floor;
const actor_mod = @import("../actor.zig");
const runtime = @import("../script.zig").runtime;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const Object = @import("../script.zig").object.Object;
const Runtime = runtime.Runtime;
const Value = @import("../script.zig").value.Value;

pub fn targetObject(ctx: *anyopaque, rt: *Runtime, args: []const Value) ?*Object {
    const name = argString(args, 0);
    if (rt.findObject(name)) |o| return o;
    const w = worldOf(ctx);
    const a = w.arena_state.allocator();
    const gop = w.debug.missing_objects.getOrPut(a, name) catch return null;
    if (!gop.found_existing) {
        gop.key_ptr.* = a.dupe(u8, name) catch name;
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += 1;
    return null;
}

pub fn clampState(v: Value) u8 {
    return @intCast(std.math.clamp(v.toInt(), 0, actor_mod.max_states - 1));
}

/// State number for animation sets (0x422960, 0x4229b0): integer 0..8, otherwise
/// the call is skipped.
pub fn animState(v: Value) ?u8 {
    if (v != .int or v.int < 0 or v.int >= actor_mod.exe_states) return null;
    return @intCast(v.int);
}

pub fn setLink(w: *World, a: *actor_mod.Actor, link: []const u8, mesh: []const u8) !void {
    if (mesh.len == 0) return;
    for (a.links.items) |*l| if (std.ascii.eqlIgnoreCase(l.link, link)) {
        l.mesh = mesh;
        return;
    };
    try a.links.append(w.gpa, .{ .link = link, .mesh = mesh });
}

/// Whether `owner` has ammo for `wpn` (0x4c0830): an item with nameID = the
/// weapon's ammoUsed and counter > 0.
pub fn ownerHasAmmo(w: *World, owner: []const u8, wpn: *Object) bool {
    const id = wpn.getInt("ammoUsed");
    for (w.rt.objects.items) |o| {
        if (!world_mod.isItem(o)) continue;
        if (fields.nameId(o) == id and fields.counter(o) > 0 and fields.ownerIs(o, owner)) return true;
    }
    return false;
}

/// After LEVEL_Load in the same script call, a call refers to the new level, so
/// defer it (true). A new LEVEL_Load from another call (update() every tick) while
/// a transition is pending would not happen in the exe, so skip it.
pub fn deferAfterLoad(w: *World, kind: @FieldType(state_groups.LoadStep, "kind"), args: []const Value) !bool {
    if (w.flow.pending_level == null) return false;
    if (!w.flow.replaying and (w.rt.depth == 0 or w.rt.top_call != w.flow.load_call)) return kind == .level_load;
    const copy = try w.gpa.alloc(Value, args.len);
    for (args, copy) |a, *c| c.* = if (a == .string) .{ .string = try w.gpa.dupe(u8, a.string) } else a;
    try w.flow.load_steps.append(w.gpa, .{ .kind = kind, .args = copy });
    return true;
}

/// LEVEL_*AdvVar (0x4c0400…0x4c0470): level progress counter, the `advVar`
/// variable of the level object (pointer +0x340), so it is saved with it (sewer
/// switch and valves: two activations drain the acid, 02s_toksyny).
pub fn advVar(ctx: *anyopaque) ?*Object {
    return worldOf(ctx).level;
}

/// Item_GetNameID / Item_GetPlace / Item_GetType (0x4c12f0, 0x4c1260, 0x4c1210):
/// item field (+0x58, +0x344, +0x368); not an item or no object gives −1.
pub fn itemField(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value, field: []const u8) Value {
    const o = objectArg(ctx, rt, self, args) orelse return .{ .int = -1 };
    if (!world_mod.isItem(o)) return .{ .int = -1 };
    return .{ .int = o.getIntDyn(field) };
}

/// Object named by the argument; "this" is the caller itself.
pub fn objectArg(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) ?*Object {
    if (std.ascii.eqlIgnoreCase(argString(args, 0), "this")) return self;
    return targetObject(ctx, rt, args);
}

/// Actor* functions of `.pth` path scripts: no name, the actor on the path.
pub fn nodeActor(ctx: *anyopaque) ?*actor_mod.Actor {
    const o = worldOf(ctx).node_actor orelse return null;
    return world_mod.actorOf(o);
}

/// Integer fourth argument equals 1 (0x4c6510 by type 1): the reverse flag of path Actor* functions.
pub fn reverseFlag(args: []const Value) bool {
    return args.len > 3 and args[3] == .int and args[3].int == 1;
}

/// Item_Disable/EnableWalkCircle(item[, floor]) (0x4c14a0, 0x4ade60/0x4adde0):
/// `.wm` cells within `radius` background pixels (if ≥ 2) around the item become
/// blocked / walkable (0x4ac850: bits 0 and 1).
pub fn walkCircle(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value, walkable: bool) !Value {
    const w = worldOf(ctx);
    const o = objectArg(ctx, rt, self, args) orelse return .zero;
    const r = o.getInt("radius");
    if (r < 2) return .zero;
    // The exe reads the floor from an integer args[0] (0x4c1512), but then args[0]
    // is not a name and no object is found (0x431b40), so the floor is always 0.
    const m = floor.floorMap(w, 0) orelse return .zero;
    const c = w.screenPos(o);
    const cx = value.floatToInt(c[0]);
    const cy = value.floatToInt(c[1]);
    const cs: i32 = level_files.WalkMap.cell_size;
    var y = cy - r;
    while (y <= cy + r) : (y += cs) {
        var x = cx - r;
        while (x <= cx + r) : (x += cs) {
            const dx: i64 = x - cx;
            const dy: i64 = y - cy;
            if (dx * dx + dy * dy >= @as(i64, r) * r) continue;
            if (x < 0 or y < 0) continue;
            const gx: usize = @intCast(@divTrunc(x, cs));
            const gy: usize = @intCast(@divTrunc(y, cs));
            if (gx >= m.width or gy >= m.height) continue;
            const cell = &m.cells[gy * m.width + gx];
            if (walkable) cell.kind |= 3 else cell.kind &= ~@as(u8, 3);
        }
    }
    return .zero;
}

/// The builtin context is the world.
pub fn worldOf(ctx: *anyopaque) *World {
    return @ptrCast(@alignCast(ctx));
}

/// String argument `i`, or "" if missing or not a string.
pub fn argString(args: []const Value, i: usize) []const u8 {
    if (i >= args.len) return "";
    return switch (args[i]) {
        .string => |s| s,
        else => "",
    };
}

//! Object snapshot for moving the party between locations (world/party.zig) and for
//! saves (save.zig): vars, skills, level points; recreating an object from its class.

const std = @import("std");
const state_object = @import("../state.zig").object;
const Allocator = std.mem.Allocator;
const world = @import("../state.zig").world;
const World = world.World;
const start = @import("start.zig");
const object = @import("../script.zig").object;
const Object = object.Object;
const Value = @import("../script.zig").value.Value;

pub const VarCopy = struct { name: []const u8, value: Value };

/// Copies of the object's vars in `a`, except names in `skip` (case-insensitive).
pub fn copyVars(a: Allocator, o: *Object, skip: []const []const u8) ![]VarCopy {
    var vars: std.ArrayList(VarCopy) = .empty;
    var it = o.vars.iterator();
    outer: while (it.next()) |e| {
        const name = object.nameOf(e.key_ptr.*);
        for (skip) |s| if (std.ascii.eqlIgnoreCase(s, name)) continue :outer;
        try vars.append(a, .{ .name = try a.dupe(u8, name), .value = try e.value_ptr.value.dupe(a) });
    }
    return vars.items;
}

/// Apply vars (only those the object has), skills and level points.
pub fn restore(w: *World, o: *Object, vars: []const VarCopy, skills: []const state_object.Skill, stat_points: i32) !void {
    const ra = w.rt.arena();
    for (vars) |v| {
        const dst = o.getVarDyn(v.name) orelse continue;
        dst.value = try v.value.dupe(ra);
    }
    const nat = World.nativeOf(o);
    nat.growth.skills.clearRetainingCapacity();
    try nat.growth.skills.appendSlice(w.gpa, skills);
    nat.growth.stat_points = stat_points;
}

/// Recreate a missing object from its class. Actors also get init() and actor hooks as on
/// location start, which registers their animations (otherwise no idle; they step in place).
pub fn recreate(w: *World, name: []const u8, cls: *object.Class, nat: state_object.Native, actor: bool) !*Object {
    const o = try w.addObject(name, cls, nat);
    if (actor) {
        _ = try w.rt.callIfExists(o, "init", &.{});
        try start.actorHooks(w, o);
    }
    return o;
}

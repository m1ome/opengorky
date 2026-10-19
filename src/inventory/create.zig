//! New items: Weapon_New/Item_New (0x4c2050, 0x4c1f20) and the debug `giveItem`.

const std = @import("std");
const state_object = @import("../state.zig").object;
const fields = @import("../fields.zig");
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;
const item_mod = @import("item.zig");

/// New item of class `class_file` (`cw_*` = weapon) for `owner`, like Weapon_New/Item_New;
/// ammo merges into the hero's pack.
pub fn giveItem(self: *World, class_file: []const u8, owner: []const u8, count: ?i32) !?*Object {
    self.debug.items += 1;
    var buf: [96]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "dbg_{d}_{s}", .{ self.debug.items, class_file });
    const kind: state_object.Kind = if (std.ascii.startsWithIgnoreCase(class_file, "cw_")) .weapon else .item;
    const o = try newItem(self, name, class_file, owner, null, kind) orelse return null;
    if (count) |n| fields.setCounter(o, n);
    item_mod.mergeAmmo(self, o);
    return o;
}

/// New item `name` of class `class_file` (Weapon_New 0x4c2050, Item_New 0x4c1f20): runs
/// class_init() then init(). With `owner`: sets `Owner` and place backpack (1); otherwise
/// owner and place come from the class (box contents). `counter` overrides the class value.
/// Null if the name is empty, taken, or the class fails to load.
pub fn newItem(w: *World, name: []const u8, class_file: []const u8, owner: ?[]const u8, counter: ?i32, kind: state_object.Kind) !?*Object {
    const rt = &w.rt;
    if (name.len == 0 or rt.findObject(name) != null) return null;
    const cls = rt.loadClass(class_file) catch |err| {
        std.log.warn("{s}: {s}: {t}", .{ name, class_file, err });
        return null;
    };
    const obj = try w.addObject(try rt.arena().dupe(u8, name), cls, .{ .kind = kind });
    _ = try rt.callIfExists(obj, "class_init", &.{});
    _ = try rt.callIfExists(obj, "init", &.{});
    if (owner) |o| {
        fields.setOwner(obj, try rt.arena().dupe(u8, o));
        item_mod.setPlace(obj, .backpack);
    }
    if (counter) |n| fields.setCounter(obj, n);
    return obj;
}

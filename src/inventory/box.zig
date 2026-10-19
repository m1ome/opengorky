//! Item actions on the field and boxes (funcID, 0x4564b0).

const std = @import("std");
const state_groups = @import("../state.zig").groups;
const fields = @import("../fields.zig");
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;
const Value = @import("../script.zig").value.Value;
const item_mod = @import("item.zig");

/// Item action by `funcID` (string.tab names: 1 Open, 2 Close, 3 Take, 4 Use,
/// 7 Explore). Take without its own function uses UniversalTake; Explore opens the box
/// window (`exploring`).
pub fn itemOperation(self: *World, item: *Object, hero: *Object) !void {
    const arg = [_]Value{.{ .string = hero.name }};
    switch (item.getInt("funcID")) {
        3 => {
            if (try self.rt.callIfExists(item, "Take", &arg) == null) {
                _ = try self.rt.callIfExists(item, "UniversalTake", &arg);
            }
            item_mod.mergeAmmo(self, item);
        },
        7 => try exploreBox(self, item, hero),
        else => |id| if (state_groups.operationName(id)) |name| {
            _ = try self.rt.callIfExists(item, name, &arg);
        },
    }
}

/// Box exploration (funcID 7): post_init_box() creates the contents on first look; the
/// host shows the list (`exploring`).
pub fn exploreBox(self: *World, box: *Object, hero: *Object) !void {
    var first = std.mem.splitScalar(u8, box.getString("itm_1"), ',');
    const first_name = std.mem.trim(u8, first.next() orelse "", " ");
    if (first_name.len > 0 and self.rt.findObject(first_name) == null) {
        _ = try self.rt.callIfExists(box, "post_init_box", &.{});
    }
    self.act.exploring = .{ .box = box, .hero = hero };
}

pub fn closeBox(self: *World) void {
    self.act.exploring = null;
}

/// Untaken box items over slots `itm_1..itm_13` (0x4564b0).
fn boxContents(self: *World, box: *Object, out: []*Object) []*Object {
    var n: usize = 0;
    for (1..14) |k| n += boxSlot(self, box, k, out[n..]).len;
    return out[0..n];
}

/// Untaken items of box slot `itm_k` (comma-separated names).
pub fn boxSlot(self: *World, box: *Object, k: usize, out: []*Object) []*Object {
    var name_buf: [8]u8 = undefined;
    const field = std.fmt.bufPrint(&name_buf, "itm_{d}", .{k}) catch return out[0..0];
    const v = box.getVarDyn(field) orelse return out[0..0];
    if (v.value != .string) return out[0..0];
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, v.value.string, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0 or n == out.len) continue;
        const o = self.rt.findObject(name) orelse continue;
        if (World.nativeOf(o).deleted or fields.owner(o).len > 0) continue;
        out[n] = o;
        n += 1;
    }
    return out[0..n];
}

/// Take one item from a box (Take Selected); an emptied box can only be closed.
pub fn takeFromBox(self: *World, box: *Object, item: *Object, hero: *Object) !void {
    fields.setOwner(item, hero.name);
    item_mod.setPlace(item, .backpack);
    self.out.sound(self.gpa, "takeitems1", null);
    item_mod.mergeAmmo(self, item);
    var buf: [64]*Object = undefined;
    const left = boxContents(self, box, &buf).len;
    box.setInt("cnt_itm", @intCast(left));
    if (left == 0) box.setInt("funcID", 2);
}

pub fn takeAllFromBox(self: *World, box: *Object, hero: *Object) !void {
    var buf: [64]*Object = undefined;
    for (boxContents(self, box, &buf)) |o| try takeFromBox(self, box, o, hero);
}

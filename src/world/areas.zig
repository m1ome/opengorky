//! Read-only location queries shared by walking (world/walk.zig) and actions
//! (world/actions.zig): `.ar` area by name, active area and ground item under a point,
//! area action id.

const std = @import("std");
const fields = @import("../fields.zig");
const level_files = @import("../formats.zig").level_files;
const Object = @import("../script.zig").object.Object;
const world = @import("../state.zig").world;
const World = world.World;

/// The pick 0x450fa0 skips objects with nameID −1 (`cmp [+0x58], -1; jle`): decor
/// items, used covers, exits not yet opened.
fn pickable(o: *Object) bool {
    return fields.nameId(o) > -1;
}

/// Enabled active area (`.are`) under a background point.
pub fn activeAreaAt(self: *World, bg: [2]f32) ?*Object {
    for (self.rt.objects.items) |o| {
        if (World.nativeOf(o).kind != .area or !o.enabled or World.nativeOf(o).deleted or !pickable(o)) continue;
        const area = findArea(self, o.getString("areaName")) orelse continue;
        if (level_files.areaContains(area, bg[0], bg[1])) return o;
    }
    return null;
}

/// Visible ground item (`place` 0) under a background point (0x450fa0): its drawn
/// screen rect contains the point (0x47d3f0, inclusive, ints); the last in the
/// object list wins. A host that draws nothing (gorky-tool) has no rects: then the
/// nearest item within 28 px is taken instead.
pub fn itemAt(self: *World, bg: [2]f32) ?*Object {
    const x = @floor(bg[0]);
    const y = @floor(bg[1]);
    var hit: ?*Object = null;
    var best: ?*Object = null;
    var best_d: f32 = 28;
    for (self.rt.objects.items) |o| {
        if (!world.isGroundItem(o) or !pickable(o)) continue;
        if (world.actorOf(o).screen_box) |b| {
            if (x >= @floor(b[0]) and x <= @floor(b[2]) and y >= @floor(b[1]) and y <= @floor(b[3])) hit = o;
            continue;
        }
        const p = self.screenPos(o);
        const d = @sqrt((p[0] - bg[0]) * (p[0] - bg[0]) + (p[1] - bg[1]) * (p[1] - bg[1]));
        if (d < best_d) {
            best = o;
            best_d = d;
        }
    }
    return hit orelse best;
}

pub fn findArea(self: *World, name: []const u8) ?level_files.Area {
    for (self.areas) |a| if (std.ascii.eqlIgnoreCase(a.name, name)) return a;
    return null;
}

/// Area action `action`: 0 = `funcID`, 1 = `funcID1`… (the action menu is built from
/// funcID, funcID1, …, 0x4574a3; lift buttons have a second one).
pub fn actionId(area: *Object, action: u8) i32 {
    if (action == 0) return area.getInt("funcID");
    var buf: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "funcID{d}", .{action}) catch return -1;
    const v = area.getVarDyn(name) orelse return -1;
    return v.value.toInt();
}

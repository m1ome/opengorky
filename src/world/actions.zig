//! Player actions on areas and items: field clicks, active areas, examine, operations and
//! the arrived hero's action.

const std = @import("std");
const state_groups = @import("../state.zig").groups;
const fields = @import("../fields.zig");
const object = @import("../script.zig").object;
const inventory = @import("../inventory.zig");
const Object = object.Object;
const Value = @import("../script.zig").value.Value;
const world = @import("../state.zig").world;
const World = world.World;
const max_actions = World.max_actions;
const ExamineEntry = World.ExamineEntry;
const AreaAction = World.AreaAction;
const walk = @import("walk.zig");
const areas = @import("areas.zig");
const route = @import("route.zig");

/// Whether the object accepts an item: has UseItem and, if `use_item_N` are set, lists it.
pub fn accepts(self: *World, target: *Object, item: *Object) bool {
    _ = self;
    if (!target.hasFunction("UseItem")) return false;
    var listed = false;
    var buf: [16]u8 = undefined;
    for (1..9) |k| {
        const name = std.fmt.bufPrint(&buf, "use_item_{d}", .{k}) catch break;
        if (target.getVarDyn(name) == null) continue;
        listed = true;
        if (std.ascii.eqlIgnoreCase(target.getStringDyn(name), item.name)) return true;
    }
    return !listed;
}

/// Actions of the area under a point (menu): operation ids and names.
pub fn actionsAt(self: *World, bg: [2]f32, out: *[max_actions]AreaAction) usize {
    if (self.mouse.use != null) return 0;
    const o = areas.activeAreaAt(self, bg) orelse return 0;
    var n: usize = 0;
    for (0..max_actions) |k| {
        const id = areas.actionId(o, @intCast(k));
        const name = state_groups.operationName(id) orelse continue;
        out[n] = .{ .action = @intCast(k), .name = name };
        n += 1;
    }
    return n;
}

/// Every object gets the examine menu except exits and non-empty item boxes (Explore with
/// cnt_itm > 0 opens the box window at once, 0x457340).
fn wantsExamine(self: *World, o: *Object) bool {
    _ = self;
    if (o.getInt("isLevelSwitch") > 0) return false;
    if (o.getInt("funcID") == 7 and o.getInt("cnt_itm") > 0) return false;
    return true;
}

/// Examine menu rows: actions, "Use …", then Cancel (or a lone Ok).
pub fn examineEntries(self: *World, o: *Object, out: []ExamineEntry) []ExamineEntry {
    var n: usize = 0;
    for (0..5) |k| {
        const id = areas.actionId(o, @intCast(k));
        if (state_groups.operationName(id) == null or n + 1 >= out.len) continue;
        out[n] = .{ .action = .{ .k = @intCast(k), .id = id } };
        n += 1;
    }
    var buf: [16]u8 = undefined;
    for (0..9) |k| {
        const name = std.fmt.bufPrint(&buf, "use_item_{d}", .{k}) catch break;
        const v = o.getVarDyn(name) orelse continue;
        if (v.value != .string or n + 1 >= out.len) continue;
        const it = self.rt.findObject(v.value.string) orelse continue;
        if (World.nativeOf(it).deleted or fields.owner(it).len == 0) continue;
        if (inventory.item.typeOf(it) == .ammo and fields.counter(it) <= 0) continue;
        out[n] = .{ .use = it };
        n += 1;
    }
    out[n] = .cancel;
    return out[0 .. n + 1];
}

/// Examine menu choice (0x457730): hero action or UseItem.
pub fn examineChoose(self: *World, e: ExamineEntry) !void {
    const ex = self.act.examining orelse return;
    self.act.examining = null;
    switch (e) {
        .cancel => {},
        .use => |item| {
            const args = [_]Value{ .{ .string = item.name }, .{ .string = ex.hero.name } };
            _ = try self.rt.callIfExists(ex.obj, "UseItem", &args);
        },
        .action => |a| {
            switch (World.nativeOf(ex.obj).kind) {
                .item, .weapon => try inventory.box.itemOperation(self, ex.obj, ex.hero),
                else => try areaOperation(self, ex.obj, ex.hero, a.k),
            }
            // An opened, non-empty box (funcID 7) shows its window on its own after 90 ticks.
            if (self.act.exploring == null and ex.obj.getInt("funcID") == 7 and ex.obj.getInt("cnt_itm") > 0)
                // The exe waits 60 + 30 ticks; we open once the lid animation ends (at
                // least 8 ticks).
                self.act.pending_explore = .{ .box = ex.obj, .hero = ex.hero, .ticks = 8 };
        },
    }
}

fn areaOperation(self: *World, area: *Object, hero: *Object, action: u8) !void {
    const id = areas.actionId(area, action);
    if (area.getInt("isLevelSwitch") > 0 and id != 1) {
        _ = try self.rt.callIfExists(area, "LevelSwitch", &.{});
        return;
    }
    // Explore on a non-empty area (the chief's safe after its code): the box window, as
    // for item boxes (0x457340); the scripts have no Explore() of their own.
    if (id == 7 and area.getInt("cnt_itm") > 0) return inventory.box.exploreBox(self, area, hero);
    const name = state_groups.operationName(id) orelse return;
    _ = try self.rt.callIfExists(area, name, &.{.{ .string = hero.name }});
}

pub fn closeExamine(self: *World) void {
    self.act.examining = null;
}

pub fn closeSafe(self: *World) void {
    self.act.safe_box = null;
}

/// Safe code entered (8 digits, 0x4583be): close the keypad, call the area's CheckCode(code).
pub fn enterSafeCode(self: *World, code: i32) !void {
    const area = self.act.safe_box orelse return;
    self.act.safe_box = null;
    _ = try self.rt.callIfExists(area, "CheckCode", &.{.{ .int = code }});
    // The right code opens the door (funcID 7): the contents show once it has swung, as
    // after opening a box.
    if (area.getInt("funcID") == 7 and area.getInt("cnt_itm") > 0) if (self.selectedHero()) |hero| {
        self.act.pending_explore = .{ .box = area, .hero = hero, .ticks = 8 };
    };
}

/// The hero arrived at an area or item: run its function.
pub fn runInteraction(self: *World) !void {
    const it = self.act.interaction orelse return;
    if (world.actorOf(it.hero).busy()) return;
    self.act.interaction = null;
    // While a scene or dialogue runs, the action is lost (0x45ad40 → 0x45bf90: scene list
    // 0x68b154 not empty or the dialogue window 0x64ef40 on top).
    if (self.scene.runner != null) return;
    self.scene.last_action_hero = it.hero.name;
    if (it.use) |item| {
        const args = [_]Value{ .{ .string = item.name }, .{ .string = it.hero.name } };
        _ = try self.rt.callIfExists(it.area, "UseItem", &args);
    } else if (it.mode == .level_switch) {
        _ = try self.rt.callIfExists(it.area, "LevelSwitch", &.{});
    } else if (it.mode == .examine or (self.examine_menus and it.action == 0 and wantsExamine(self, it.area))) {
        self.act.examining = .{ .obj = it.area, .hero = it.hero };
    } else switch (World.nativeOf(it.area).kind) {
        .item, .weapon => try inventory.box.itemOperation(self, it.area, it.hero),
        else => try areaOperation(self, it.area, it.hero, it.action),
    }
}

/// Player click (0x451430 left, 0x4514c0 right). Left: another hero — select; item — walk
/// there; area with WalkPath — follow it; exit — walk there and LevelSwitch; other area —
/// walk there; elsewhere — walk. Right: item or area — walk there and examine; elsewhere —
/// nothing. The whole party walks (0x427780). False while a scene has control.
pub fn clickPlay(self: *World, bg: [2]f32, right: bool) !bool {
    const hero = clickHero(self) orelse return false;
    // On a ladder: finish climbing first.
    if (world.actorOf(hero).onPortal()) return true;
    // "Use … on …": walk there and UseItem.
    if (self.mouse.use != null) return clickAction(self, bg, 0);
    if (!right) if (walk.heroAt(self, bg)) |other| if (other != hero and self.playerCanSelect(other)) {
        self.selected_hero = other.name;
        self.out.sound(self.gpa, "selecthero", null);
        return true;
    };
    self.act.interaction = null;
    if (areas.itemAt(self, bg)) |item| {
        if (!try walk.partyWalk(self, hero, walk.itemGoal(self, item))) return true;
        if (right) self.act.interaction = .{ .hero = hero, .area = item, .mode = .examine };
        return true;
    }
    if (areas.activeAreaAt(self, bg)) |o| {
        const area = areas.findArea(self, o.getString("areaName")).?;
        const func = o.getInt("funcID");
        const ls = o.getInt("isLevelSwitch");
        if (right) {
            if (!try walk.partyWalk(self, hero, area.control)) return true;
            const no_examine = o.getInt("noExamine") == 1 or (func == -1 and ls > 0);
            if (!no_examine) self.act.interaction = .{ .hero = hero, .area = o, .mode = .examine };
            return true;
        }
        const wp = o.getString("WalkPath");
        if (func == -1 and wp.len > 0) {
            try walk.walkPath(self, hero, wp);
            return true;
        }
        if (func == 2 and ls == 0) {
            _ = try walk.partyWalk(self, hero, bg);
            return true;
        }
        if (!try walk.partyWalk(self, hero, area.control)) return true;
        if (func != 1 and ls > 0) self.act.interaction = .{ .hero = hero, .area = o, .mode = .level_switch };
        return true;
    }
    if (right) return false;
    _ = try walk.partyWalk(self, hero, bg);
    return true;
}

/// Common start of a field click: no scene in control, a placed selected hero.
fn clickHero(self: *World) ?*Object {
    if (walk.playerLocked(self)) return null;
    const hero = self.selectedHero() orelse return null;
    if (!world.actorOf(hero).placed) return null;
    return hero;
}

pub fn click(self: *World, bg: [2]f32) !bool {
    return clickAction(self, bg, 0);
}

/// Click with an area action choice (0 main, 1 `funcID1`, …); false if the area lacks it.
pub fn clickAction(self: *World, bg: [2]f32, action: u8) !bool {
    if (action > 0) {
        const o = areas.activeAreaAt(self, bg) orelse return false;
        if (areas.actionId(o, action) <= 0) return false;
    }
    const hero = clickHero(self) orelse return false;
    // On a ladder: finish climbing first (as clickPlay); a new path would drop the
    // transition and leave the hero on blocked cells.
    if (world.actorOf(hero).onPortal()) return true;
    const use = self.mouse.use;
    // "Use X on …" (0x450b76…0x450cc4): the target is a ground item or the area under the
    // cursor; `use_item_N` isn't checked (that's the examine menu, 0x45752c); a target without
    // UseItem does nothing; a miss keeps the mode.
    if (use) |u| {
        if (areas.itemAt(self, bg)) |item| {
            // Item: no walking, the message goes straight to the hero's queue (esi = 1).
            self.mouse.use = null;
            self.act.interaction = .{ .hero = hero, .area = item, .use = u };
            return true;
        }
        if (areas.activeAreaAt(self, bg)) |o| {
            // Area: walk to its control point (0x427210), then UseItem.
            const area = areas.findArea(self, o.getString("areaName")).?;
            if (!try walk.walkToReach(self, hero, area.control)) return true;
            self.mouse.use = null;
            self.act.interaction = .{ .hero = hero, .area = o, .use = u, .action = action };
            return true;
        }
        // Target lookup as 0x450fa0: ground item, area, then actor. A party hero (0x450c6c):
        // medicine (type 20, 0x47b900) runs 0x48ff50 and is consumed even with hp 0; other
        // items send UseItem to the hero (0x450c92 → 0x425550), which heroes lack. The mode
        // closes either way (0x450cc6).
        if (walk.heroAt(self, bg)) |target| {
            if (inventory.item.typeOf(u) == .medicine) {
                try inventory.medicine.healWith(self, hero, target, u);
            } else {
                self.mouse.use = null;
                const args = [_]Value{ .{ .string = u.name }, .{ .string = hero.name } };
                _ = try self.rt.callIfExists(target, "UseItem", &args);
            }
            return true;
        }
        return true;
    }
    // Ground item: walk to its point (`walk_x`, `walk_y` in background pixels).
    if (areas.itemAt(self, bg)) |item| {
        if (!try walk.walkToReach(self, hero, walk.itemGoal(self, item))) return true;
        self.act.interaction = .{ .hero = hero, .area = item };
        return true;
    }
    if (areas.activeAreaAt(self, bg)) |o| {
        const area = areas.findArea(self, o.getString("areaName")).?;
        if (o.getInt("funcID") <= 0 and o.getInt("isLevelSwitch") <= 0) {
            try route.walkTo(self, hero, bg);
            return true;
        }
        if (!try walk.walkToReach(self, hero, area.control)) return true;
        self.act.interaction = .{ .hero = hero, .area = o, .action = action };
        return true;
    }
    self.act.interaction = null;
    try route.walkTo(self, hero, bg);
    return true;
}

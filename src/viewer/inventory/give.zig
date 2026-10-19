//! Item transfer and the count window (0x4b2fb0). InventoryView methods (see viewer/inventory.zig).

const std = @import("std");
const og = @import("opengorky");
const gui_mod = @import("../gui.zig");
const game_inventory = @import("opengorky").inventory;
const inventory_mod = @import("../inventory.zig");
const InventoryView = inventory_mod.InventoryView;
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");
const World = @import("opengorky").state.world.World;
const Object = @import("opengorky").script.object.Object;
const inv = @import("opengorky").inventory;
const give_rects = inventory_mod.give_rects;

pub fn closeGive(self: *InventoryView, w: *World) void {
    self.give = null;
    w.out.sound(w.gpa, "invbuttonweapons", null);
}

/// Count window button under a point: the LAST matching rect (0x4b3160…0x4b318c
/// keeps the last): "+" (0x52b4c8, down to y = 290) overlaps Cancel, and Cancel
/// wins in the overlap.
fn giveButton(pt: ?[2]f32) ?usize {
    const p = pt orelse return null;
    var hit: ?usize = null;
    for (give_rects, 0..) |r, i| {
        if (p[0] < r[0] or p[0] > r[2] or p[1] < r[1] or p[1] > r[3]) continue;
        hit = i;
    }
    return hit;
}

/// Click in the count window (0x4b3110): −, +, Accept, Cancel.
pub fn clickGive(self: *InventoryView, w: *World, x: f32, y: f32) void {
    const g = &(self.give orelse return);
    if (giveButton(.{ x, y })) |i| {
        switch (i) {
            0 => if (g.amount > 0) {
                g.amount -= 1;
                w.out.sound(w.gpa, "invselect", null);
            },
            1 => if (g.amount < g.max) {
                g.amount += 1;
                w.out.sound(w.gpa, "invselect", null);
            },
            2 => {
                game_inventory.give.transfer(w, g.from, g.to, g.item, g.amount);
                self.current = inv.equipment.equipped(w, g.from, .hand);
                closeGive(self, w);
            },
            else => closeGive(self, w),
        }
    }
}

/// Count window (0x4b3330) at (260, 140): centred icon (frame 1) at (334, 182),
/// name at (334, 197), "have" right-aligned at x = 394, y = 160, count "%02d" in
/// atlas digits at (334, 249), Accept / Cancel labels.
pub fn drawGive(self: *InventoryView, r: *c.SDL_Renderer, mouse: [2]f32) !void {
    const g = self.give orelse return;
    try self.giveman.draw(r, 0, 260, 140);
    // Pressed button under the cursor: frames 1–4 at (270,221), (362,221), (275,273),
    // (334,273) (0x4b338f…0x4b33f7).
    const pk = giveButton(self.press_at);
    if (pk != null and pk == giveButton(mouse) and self.giveman.len() > 4) {
        const at = [4][2]f32{ .{ 270, 221 }, .{ 362, 221 }, .{ 275, 273 }, .{ 334, 273 } };
        try self.giveman.draw(r, pk.? + 1, at[pk.?][0], at[pk.?][1]);
    }
    if (self.icon(g.item.getString("spriteFile"))) |f| if (f.len() > 1) {
        const sz = f.sizes.items[1];
        try f.draw(r, 1, 334 - og.num.toF32(sz[0] >> 1), 182 - og.num.toF32(sz[1] >> 1));
    };
    var buf: [16]u8 = undefined;
    const amount = std.fmt.bufPrint(&buf, "{d:0>2}", .{@as(u32, @intCast(@max(0, g.amount)))}) catch "";
    if (self.atlas.len() > 1) {
        var wdt: i32 = 0;
        for (amount) |ch| if (self.digits[ch]) |gl| {
            wdt += gl.advance;
        };
        var x: f32 = 334 - og.num.toF32(wdt >> 1);
        for (amount) |ch| if (self.digits[ch]) |gl| {
            try self.atlas.drawPart(r, 1, .{ @floatFromInt(gl.x), @floatFromInt(gl.y), @floatFromInt(gl.w), @floatFromInt(gl.h) }, x, 249 - 20);
            x += @floatFromInt(gl.advance);
        };
    }
    const t = &(self.give_text orelse return);
    @memset(t.pixels, 0);
    const name = self.itemName(g.item);
    const col: [3]u8 = gui_mod.text_light;
    // y is the row top (0x47b640, like Exit on the inventory screen): name in font 2
    // at y = 197, "have" and button labels in font 3 at y = 160 and 279.
    gui_mod.textShadow(self.font, t.*, 334 - @divTrunc(@as(i32, @intCast(self.font.measure(name))), 2), 197, name, .{ 255, 255, 255 });
    var mb: [16]u8 = undefined;
    const max = std.fmt.bufPrint(&mb, "{d}", .{g.max}) catch "";
    // x = 394 − w (0x4b346d), then 0x47b640 centres again: − (w >> 1).
    const mw: i32 = @intCast(self.sys.measure(max));
    gui_mod.textShadow(self.sys, t.*, 394 - mw - (mw >> 1), 160, max, col);
    const accept = self.strings.get(512) orelse "Accept";
    const cancel = self.strings.get(5) orelse "Cancel";
    gui_mod.textShadow(self.sys, t.*, 305 - @divTrunc(@as(i32, @intCast(self.sys.measure(accept))), 2), 279, accept, col);
    gui_mod.textShadow(self.sys, t.*, 365 - @divTrunc(@as(i32, @intCast(self.sys.measure(cancel))), 2), 279, cancel, col);
    try gfx.drawImage(r, &self.give_tex, t.*);
}

/// "Give" mode from the panel (0x4536e0 in battle, 0x450770 outside): more than one
/// unit — count window (0x4b2fb0) over the field, true; otherwise false.
pub fn openGive(self: *InventoryView, w: *World, from: *Object, to: *Object, item: *Object) bool {
    if (!inv.list.severalUnits(w, item) or self.giveman.len() <= 4) return false;
    self.give = .{ .from = from, .to = to, .item = item, .max = game_inventory.ammo.unitsOf(w, from, item) };
    return true;
}

/// Count window open over the field (inventory closed): clicks go to it.
pub fn pressGive(self: *InventoryView, w: *World, x: f32, y: f32, left: bool) void {
    if (left) clickGive(self, w, x, y) else closeGive(self, w);
}

/// Cursor item dropped on a hero portrait (0x42e3f0): give. Not to self, not to
/// Medusa (nameID 119), in battle only to a neighbour; more than one — count window.
pub fn dropOnHero(self: *InventoryView, w: *World, hero: *Object, item: *Object, i: usize) void {
    const heroes = w.party();
    const party = heroes.slice();
    if (i >= party.len) return;
    const to = party[i];
    if (!game_inventory.give.canGive(w, hero, to)) return;
    inv.item.setPlace(item, .backpack);
    self.carried = null;
    if (inv.list.severalUnits(w, item) and self.giveman.len() > 4) {
        self.give = .{ .from = hero, .to = to, .item = item, .max = game_inventory.ammo.unitsOf(w, hero, item) };
    } else game_inventory.give.handOver(w, hero, to, item);
    self.current = inv.equipment.equipped(w, hero, .hand);
    w.out.sound(w.gpa, "Itemput", null);
}

//! Mouse presses in the inventory: take, put, tabs, portraits; while the give
//! window is open, presses go to it. InventoryView methods (see viewer/inventory.zig).

const inventory_give = @import("give.zig");
const inventory_mod = @import("../inventory.zig");
const InventoryView = inventory_mod.InventoryView;
const World = @import("opengorky").state.world.World;
const Object = @import("opengorky").script.object.Object;
const inv = @import("opengorky").inventory;

/// Left press (0x42dec0): take an item, put it, tabs, portraits.
pub fn press(self: *InventoryView, w: *World, x: f32, y: f32) void {
    self.sync(w);
    if (self.give != null) return inventory_give.clickGive(self, w, x, y);
    const hero = self.heroObj(w) orelse return;
    // Scrollbar: drag the thumb; a click on the track scrolls ±16.
    if (x >= inventory_mod.bar_x and x <= inventory_mod.bar_x + 12 and y >= inventory_mod.bar.y - 1 and y <= inventory_mod.bar.y + inventory_mod.bar.len + 1) {
        if (inventory_mod.bar.click(&self.scroll, self.bagCount(w, hero), y)) self.thumb_drag = true;
        return;
    }
    const hit = InventoryView.hitAt(w, x, y);
    self.pressed = hit;
    const battle = if (w.battle) |*b| b else null;
    const locked = if (battle) |b| b.hasActed(hero) else false;
    if (self.carried) |item| {
        switch (hit) {
            .cell, .bag => {
                inv.item.setPlace(item, .backpack);
                drop(self, w);
            },
            // The body takes armour only (type 30).
            .torso => if (inv.item.typeOf(item) == .armor) {
                if (inv.equipment.equipped(w, hero, .armor)) |old| inv.item.setPlace(old, .backpack);
                inv.item.setPlace(item, .armor);
                drop(self, w);
            },
            // The hand takes any item.
            .hand => {
                inv.equipment.toHand(w, hero, item);
                drop(self, w);
            },
            .portrait => |i| inventory_give.dropOnHero(self, w, hero, item, i),
            else => {},
        }
        return;
    }
    switch (hit) {
        .portrait => |i| if (i != self.hero) {
            inv.equipment.leaveInventory(w, hero); // 0x42e27c
            self.hero = i;
            self.scroll = 0;
            self.current = if (self.heroObj(w)) |h| inv.equipment.equipped(w, h, .hand) else null;
            w.out.sound(w.gpa, "selecthero", null);
        },
        .cell => |k| if (!locked) if (self.cellItem(w, hero, k)) |item| pick(self, w, item),
        .torso => if (!locked) if (inv.equipment.equipped(w, hero, .armor)) |item| pick(self, w, item),
        .hand => if (!locked) if (inv.equipment.equipped(w, hero, .hand)) |item| {
            pick(self, w, item);
            inv.equipment.setHoldState(w, hero, null);
        },
        .tab => |i| if (@backingInt(self.tab) != i) {
            self.tab = @fromBackingInt(@intCast(i));
            self.scroll = 0;
            w.out.sound(w.gpa, switch (i) {
                0 => "invbuttonweapons",
                1 => "invbuttonitems",
                else => "invbuttonkeys",
            }, null);
        },
        else => {},
    }
}

/// Puts an item on the cursor.
fn pick(self: *InventoryView, w: *World, item: *Object) void {
    item.setInt("place", -1);
    self.carried = item;
    self.current = item;
    w.out.sound(w.gpa, "Itemchoose", null);
}

/// The cursor item was put down.
fn drop(self: *InventoryView, w: *World) void {
    self.carried = null;
    w.out.sound(w.gpa, "Itemput", null);
}

/// Right button: cursor item → backpack; otherwise the item under the cursor becomes current.
pub fn pressRight(self: *InventoryView, w: *World, x: f32, y: f32) void {
    self.sync(w);
    if (self.give != null) return inventory_give.closeGive(self, w);
    if (self.carried) |item| {
        inv.item.setPlace(item, .backpack);
        self.carried = null;
        w.out.sound(w.gpa, "Itemput", null);
        return;
    }
    if (self.hoverItem(w, x, y)) |item| {
        self.current = item;
        w.out.sound(w.gpa, "Itemchoose", null);
    }
}

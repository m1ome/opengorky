//! Box and examine windows on the field. InventoryView methods (see viewer/inventory.zig).

const std = @import("std");
const gui_mod = @import("../gui.zig");
const inventory_draw = @import("draw.zig");
const actions_mod = og.world.actions;
const inventory_mod = @import("../inventory.zig");
const InventoryView = inventory_mod.InventoryView;
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");
const World = @import("opengorky").state.world.World;
const Object = @import("opengorky").script.object.Object;
const BoxSlot = InventoryView.BoxSlot;
const Exam = InventoryView.Exam;

fn boxSlots(w: *World, box: *Object, out: []BoxSlot) []BoxSlot {
    var n: usize = 0;
    for (1..14) |k| {
        var slot: BoxSlot = .{ .k = k };
        slot.n = og.inventory.box.boxSlot(w, box, k, &slot.objs).len;
        for (slot.objs[0..slot.n]) |o| slot.qty += if (og.inventory.item.typeOf(o) == .ammo) og.fields.counter(o) else 1;
        if (slot.n == 0 or n == out.len) continue;
        out[n] = slot;
        n += 1;
    }
    return out[0..n];
}

/// Window corner (0x4564b0): right of the item if it is in the left half of the
/// screen, else left; vertically centred on the rows and three buttons; no clamp (0x45675e…0x4567ab).
fn boxOrigin(w: *World, box: *Object, rows: usize, scroll: [2]f32) [2]f32 {
    const p = w.soundPos(box) orelse if (w.selectedHero()) |h| w.soundPos(h) orelse [2]f32{ 320, 0 } else [2]f32{ 320, 0 };
    const cx = p[0] - scroll[0];
    const x = if (cx <= 320) cx + 60 else cx - 158 - 60;
    const y = @divTrunc(440 - 3 * 30 - @as(i32, @intCast(rows)) * 68, 2);
    return .{ @trunc(x), @floatFromInt(y) };
}

/// Box button under a point (Take All, Take Selected, Cancel).
fn boxButton(o: [2]f32, rows: usize, pt: ?[2]f32) ?usize {
    const p = pt orelse return null;
    const by = o[1] + 68 * og.num.toF32(rows);
    if (p[0] < o[0] or p[0] > o[0] + 158 or p[1] < by or p[1] >= by + 90) return null;
    return @intFromFloat((p[1] - by) / 30);
}

/// Click in the box window (0x456a20): a row checkbox toggles; Take All, Take
/// Selected, Cancel.
pub fn clickBox(self: *InventoryView, w: *World, x: f32, y: f32, scroll: [2]f32) !void {
    const ex = w.act.exploring orelse return;
    var buf: [13]BoxSlot = undefined;
    const slots = boxSlots(w, ex.box, &buf);
    const o = boxOrigin(w, ex.box, slots.len, scroll);
    for (slots, 0..) |sl, i| {
        const ry = o[1] + 68 * og.num.toF32(i);
        if (x >= o[0] + 12 and x <= o[0] + 31 and y >= ry + 24 and y <= ry + 44) {
            self.box_selected ^= @as(u16, 1) << @intCast(sl.k);
            w.out.sound(w.gpa, "invselect", null);
            return;
        }
    }
    const k = boxButton(o, slots.len, .{ x, y }) orelse return;
    w.out.sound(w.gpa, "selecthero", null);
    switch (k) {
        0, 1 => {
            if (k == 0) try og.inventory.box.takeAllFromBox(w, ex.box, ex.hero) else for (slots) |sl| {
                if (self.box_selected & (@as(u16, 1) << @intCast(sl.k)) == 0) continue;
                for (sl.objs[0..sl.n]) |it| try og.inventory.box.takeFromBox(w, ex.box, it, ex.hero);
            }
            w.out.sound(w.gpa, "invgive", null);
            self.box_selected = 0;
            if (k == 0 or boxSlots(w, ex.box, &buf).len == 0) og.inventory.box.closeBox(w);
        },
        else => {
            self.box_selected = 0;
            og.inventory.box.closeBox(w);
        },
    }
}

/// Box window (`ebox.spr`, 0x456c60): rows 158×68 (frame 0), checkbox (frame 3),
/// icon (frame 1), name centred at (79, 50), count at (135, 11); buttons 158×30
/// (frame 1): Take All, Take Selected, Cancel.
pub fn drawBox(self: *InventoryView, r: *c.SDL_Renderer, w: *World, scroll: [2]f32, mouse: [2]f32) !void {
    const ex = w.act.exploring orelse return;
    if (self.ebox.len() < 4) return;
    var buf: [13]BoxSlot = undefined;
    const slots = boxSlots(w, ex.box, &buf);
    const o = boxOrigin(w, ex.box, slots.len, scroll);
    @memset(self.text.pixels, 0);
    const col: [3]u8 = gui_mod.text_light;
    for (slots, 0..) |sl, i| {
        const ry = o[1] + 68 * og.num.toF32(i);
        try self.ebox.draw(r, 0, o[0], ry);
        if (self.box_selected & (@as(u16, 1) << @intCast(sl.k)) != 0) {
            const sz = self.ebox.sizes.items[3];
            try self.ebox.draw(r, 3, o[0] + 12 + (19 - og.num.toF32(sz[0])) / 2, ry + 24 + (20 - og.num.toF32(sz[1])) / 2);
        }
        const first = sl.objs[0];
        if (self.icon(first.getString("spriteFile"))) |f| if (f.len() > 1) {
            const sz = f.sizes.items[1];
            try f.drawShadowed(r, 1, gfx.Frames.center(o[0] + 47, 93, sz[0]), gfx.Frames.center(ry + 8, 52, sz[1]));
        };
        const name = self.itemName(first);
        const ix: i32 = @intFromFloat(o[0] + 79);
        const iy: i32 = @intFromFloat(ry + 50);
        // Name in font 2 centred on x, row top + 50 (0x456e15); count in font 3
        // at (135, 11) (0x456e82), both shadowed.
        inventory_draw.shadowText(self, self.text, ix - @divTrunc(@as(i32, @intCast(self.font.measure(name))), 2), iy, name, col);
        var qb: [12]u8 = undefined;
        const q = std.fmt.bufPrint(&qb, "{d}", .{sl.qty}) catch "";
        gui_mod.textShadow(self.sys, self.text, @intFromFloat(o[0] + 135), @intFromFloat(ry + 11), q, col);
    }
    const labels = [3][]const u8{ self.strings.get(8) orelse "Take All", self.strings.get(9) orelse "Take Selected", self.strings.get(5) orelse "Cancel" };
    for (labels, 0..) |lb, k| {
        const by = o[1] + 68 * og.num.toF32(slots.len) + 30 * og.num.toF32(k);
        try self.ebox.draw(r, 1, o[0], by);
        // Pressed and under the cursor: frame 2 (0x456ede…0x456f00).
        const pk = boxButton(o, slots.len, self.press_at);
        if (pk != null and pk == k and boxButton(o, slots.len, mouse) == k) try self.ebox.draw(r, 2, o[0], by);
        // Font 3 centred on the button, row top + 11.
        gui_mod.textShadow(self.sys, self.text, @as(i32, @intFromFloat(o[0] + 79)) - @divTrunc(@as(i32, @intCast(self.sys.measure(lb))), 2), @intFromFloat(by + 11), lb, col);
    }
    try gfx.drawImage(r, &self.text_tex, self.text);
}

// ---------------------------------------------------------------- examine menu

/// Object description: `items.inf` for items, `activeareas.inf` for areas.
fn examineText(self: *InventoryView, o: *Object) []const u8 {
    const id = og.fields.nameId(o);
    const k = World.nativeOf(o).kind;
    if (k == .item or k == .weapon) return self.examine.get(id) orelse "";
    return self.area_examine.get(id) orelse "";
}

/// Geometry (0x457340): text height < 30 → 30, else th − th % 10 + 10 (always
/// +10); H = text + 22. X from the centre of the selected hero's screen rect
/// (+0x64/+0x6c): left of 320 → +60, else −218; computed once at open, no clamp,
/// doesn't follow scrolling. Y = (400 − 30·rows − H) / 2.
fn examGeom(self: *InventoryView, w: *World, o: *Object, rows: usize, scroll: [2]f32) Exam {
    const lines = wrapCount(self, examineText(self, o), 140);
    const th: i32 = @intCast(lines * (self.font.height + 1));
    const h: i32 = (if (th < 30) 30 else th - @rem(th, 10) + 10) + 22;
    const anchor = if (self.exam_anchor) |a| (if (a.obj == o) a.x else null) else null;
    const x = anchor orelse blk: {
        const box = if (w.selectedHero()) |hero| og.state.world.actorOf(hero).screen_box else null;
        const cx: f32 = if (box) |b| @trunc(b[0] - scroll[0]) + @trunc((b[2] - b[0]) / 2) else 320;
        const nx = if (cx < 320) cx + 60 else cx - 218;
        self.exam_anchor = .{ .obj = o, .x = nx };
        break :blk nx;
    };
    const y = @divTrunc(400 - @as(i32, @intCast(rows)) * 30 - h, 2);
    return .{ .x = x, .y = @floatFromInt(y), .h = @floatFromInt(h), .lines = lines };
}

fn wrapCount(self: *InventoryView, text: []const u8, max_w: u32) usize {
    var n: usize = 0;
    var rest = text;
    while (rest.len > 0) : (n += 1) {
        const cut = self.font.lineCut(rest, max_w);
        rest = std.mem.trimStart(u8, rest[cut..], " ");
    }
    return n;
}

fn entryLabel(self: *InventoryView, e: World.ExamineEntry, only: bool, buf: []u8) []const u8 {
    return switch (e) {
        .action => |a| self.strings.get(a.id) orelse (og.state.groups.operationName(a.id) orelse "?"),
        .use => |it| std.fmt.bufPrint(buf, "{s} {s}", .{ self.strings.get(4) orelse "Use", self.itemName(it) }) catch "Use",
        .cancel => if (only) self.strings.get(6) orelse "Ok" else self.strings.get(5) orelse "Cancel",
    };
}

/// Examine menu row under a point.
fn examRow(g: Exam, n: usize, pt: ?[2]f32) ?usize {
    const p = pt orelse return null;
    for (0..n) |i| {
        const ry = g.y + g.h + 30 * og.num.toF32(i);
        if (p[0] >= g.x + 1 and p[0] <= g.x + 158 and p[1] >= ry + 2 and p[1] <= ry + 30) return i;
    }
    return null;
}

/// Click in the examine menu: a row runs its action; a miss closes.
pub fn clickExamine(self: *InventoryView, w: *World, x: f32, y: f32, scroll: [2]f32) !void {
    const ex = w.act.examining orelse return;
    var buf: [16]World.ExamineEntry = undefined;
    const entries = actions_mod.examineEntries(w, ex.obj, &buf);
    const g = examGeom(self, w, ex.obj, entries.len, scroll);
    if (examRow(g, entries.len, .{ x, y })) |i| {
        w.out.sound(w.gpa, "selecthero", null);
        return actions_mod.examineChoose(w, entries[i]);
    }
    actions_mod.closeExamine(w);
}

/// Examine menu (0x457970): frame 0, strips 1–3 of 10 px, frame 5, description at
/// (9, 14); rows frame 6 (158×30), label centred at (79, 11).
pub fn drawExamine(self: *InventoryView, r: *c.SDL_Renderer, w: *World, scroll: [2]f32, mouse: [2]f32) !void {
    const ex = w.act.examining orelse return;
    if (self.exbox.len() < 7) return;
    var buf: [16]World.ExamineEntry = undefined;
    const entries = actions_mod.examineEntries(w, ex.obj, &buf);
    const g = examGeom(self, w, ex.obj, entries.len, scroll);
    try self.exbox.draw(r, 0, g.x, g.y);
    const strips: usize = @intFromFloat((g.h - 22) / 10);
    for (0..strips) |i| try self.exbox.draw(r, 1 + i % 3, g.x, g.y + 9 + 10 * og.num.toF32(i));
    try self.exbox.draw(r, 5, g.x, g.y + 9 + 10 * og.num.toF32(strips));
    const pk = examRow(g, entries.len, self.press_at);
    const hk = examRow(g, entries.len, mouse);
    for (entries, 0..) |_, i| {
        const ry = g.y + g.h + 30 * og.num.toF32(i);
        try self.exbox.draw(r, 6, g.x, ry);
        // Pressed and under the cursor: frame 7 at (X+6, row+8) (0x457b11…0x457b53).
        if (pk != null and pk == i and hk == i and self.exbox.len() > 7) try self.exbox.draw(r, 7, g.x + 6, ry + 8);
    }
    @memset(self.text.pixels, 0);
    // Description in font 2 with shadow at (X+9, Y+14) (0x457aa7).
    _ = inventory_draw.textWrappedShadow(self, self.font, @intFromFloat(g.x + 9), @intFromFloat(g.y + 14), examineText(self, ex.obj), gui_mod.text_light, 140, @intFromFloat(g.y + g.h));
    for (entries, 0..) |e, i| {
        var lb: [96]u8 = undefined;
        const t = entryLabel(self, e, entries.len == 1, &lb);
        const ry = g.y + g.h + 30 * og.num.toF32(i);
        // Row label in font 3 with shadow, centred (X+79, row+11) (0x457be2).
        gui_mod.textShadow(self.sys, self.text, @as(i32, @intFromFloat(g.x + 79)) - @divTrunc(@as(i32, @intCast(self.sys.measure(t))), 2), @intFromFloat(ry + 11), t, gui_mod.text_dim);
    }
    try gfx.drawImage(r, &self.text_tex, self.text);
}

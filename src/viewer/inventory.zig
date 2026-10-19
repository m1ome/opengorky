//! Hero inventory screen (`common/sprite.dat: inventory.spr`, icons `icons\*.spr`).
//! Logic lives in src/inventory.zig; the layout comes from the exe tables below.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("media/gfx.zig");
const lang_mod = og.formats.lang;
const gui = @import("gui.zig");
const archive = og.formats.archive;
const Image = og.formats.image.Image;
const Font = og.formats.font.Font;
const World = og.state.world.World;
const Object = og.script.object.Object;
const inv = og.inventory;

/// Rectangle (l, t, r, b) inclusive, as in the exe tables.
pub const Rect = struct {
    l: f32,
    t: f32,
    r: f32,
    b: f32,

    fn has(self: Rect, x: f32, y: f32) bool {
        return x >= self.l and x <= self.r and y >= self.t and y <= self.b;
    }
};

// Inventory screen regions (0x51f3e8).
const bag_rect: Rect = .{ .l = 14, .t = 68, .r = 160, .b = 437 };
pub const torso_rect: Rect = .{ .l = 222, .t = 112, .r = 299, .b = 161 };
pub const hand_rect: Rect = .{ .l = 222, .t = 244, .r = 299, .b = 291 };
pub const picture_rect: Rect = .{ .l = 203, .t = 344, .r = 437, .b = 437 };
pub const tab_rects = [3]Rect{
    .{ .l = 18, .t = 21, .r = 63, .b = 46 },
    .{ .l = 72, .t = 21, .r = 117, .b = 46 },
    .{ .l = 127, .t = 21, .r = 172, .b = 46 },
};
pub const portrait_l = [5]f32{ 202, 252, 302, 351, 399 };
/// Portrait right edges (table 0x51f458); gaps between them belong to no one.
const portrait_r = [5]f32{ 241, 291, 339, 389, 437 };
pub const exit_rect: Rect = .{ .l = 9, .t = 453, .r = 490, .b = 475 };
pub const skill_rect: Rect = .{ .l = 503, .t = 454, .r = 625, .b = 475 };

pub fn portraitRect(i: usize) Rect {
    return .{ .l = portrait_l[i], .t = 17, .r = portrait_r[i], .b = 63 };
}

/// Backpack cells (0x51f4c8): 16 of 70×46, two columns of 8, column-major.
pub const cells = 16;

pub fn cellRect(k: usize) Rect {
    const l: f32 = if (k < 8) 13 else 90;
    const t = 70 + 46 * og.num.toF32(k % 8);
    return .{ .l = l, .t = t, .r = l + 70, .b = t + 46 };
}

/// Backpack scrollbar (0x4ae790(12, 335, 15, 29, 16, 1) at (168, 87)): GScrollBar
/// thumb and arrows (0x4aed50), travel 335 − 29, a click on the track — ±16.
pub const bar_x: f32 = 168;
pub const bar: gui.Scrollbar = .{ .y = 87, .len = 335, .rows = cells };

/// Transfer with a count choice.
const Give = struct { from: *Object, to: *Object, item: *Object, max: i32, amount: i32 = 1 };

/// GiveMan buttons (0x52b4b8 + (260, 140)): −, +, Accept, Cancel.
pub const give_rects = [4][4]f32{ .{ 270, 221, 301, 256 }, .{ 362, 221, 393, 290 }, .{ 275, 273, 333, 294 }, .{ 334, 273, 392, 294 } };

/// What is under the cursor (0x5a5c14).
const Hit = union(enum) {
    none,
    /// Backpack cell k (list row scroll + k).
    cell: usize,
    bag,
    torso,
    hand,
    picture,
    tab: usize,
    portrait: usize,
    exit,
    skills,
};

/// Release outcome: close the inventory or the skills window.
pub const Action = enum { none, close, skills };

pub const InventoryView = struct {
    gpa: Allocator,
    io: Io,
    renderer: *c.SDL_Renderer,
    open: bool = false,
    hero: usize = 0,
    tab: inv.list.Tab = .weapons,
    scroll: usize = 0,
    /// World that `carried` and `current` belong to.
    world: ?*World = null,
    /// Cursor item (0x5a5c18): taken by a click, put down by the next.
    carried: ?*Object = null,
    /// Current item (0x5a5c00): big picture and description.
    current: ?*Object = null,
    /// Pressed bottom button (acts on release over the same button).
    pressed: Hit = .none,
    /// The backpack thumb is being dragged.
    thumb_drag: bool = false,
    bg: gfx.Frames = .{},
    /// Box contents window (`item_list.spr`).
    box_bg: gfx.Frames = .{},
    /// Count choice on transfer (`GiveMan.spr`, 0x4b2fb0/0x4b3110/0x4b3330).
    giveman: gfx.Frames = .{},
    give: ?Give = null,
    give_text: ?Image = null,
    give_tex: ?*c.SDL_Texture = null,
    /// Count digits: atlas font 1 (`fonts.spr` frame 1, `02_hp.fnt`).
    atlas: gfx.Frames = .{},
    digits: [256]?og.formats.font.TexGlyph = @splat(null),
    box_scroll: usize = 0,
    /// Checked box slots (bit k is `itm_k`).
    box_selected: u16 = 0,
    /// Where the left button went down (until release): the "pressed" frame of
    /// count, box and examine buttons shows while the cursor is over the same button.
    press_at: ?[2]f32 = null,
    /// Examine menu X: computed once at open (0x457631) for this object.
    exam_anchor: ?struct { obj: *Object, x: f32 } = null,
    /// Examine menu (`examine_box.spr`) and area descriptions (`activeareas.inf`).
    exbox: gfx.Frames = .{},
    area_bytes: []u8 = &.{},
    area_examine: og.formats.strtab.Table = .{},
    ebox: gfx.Frames = .{},
    icons: std.StringHashMapUnmanaged(gfx.Frames) = .empty,
    sprites: archive.Archive,
    /// Font 2 (`03_small_1.fnt`): hints, box, examine.
    font_bytes: []u8,
    font: Font,
    /// Font 3 (`04_system_1.fnt`): inventory screen labels.
    sys_bytes: []u8,
    sys: Font,
    strings_bytes: []u8,
    examine_bytes: []u8,
    strings: og.formats.strtab.Table,
    examine: og.formats.strtab.Table,
    examine_arena: std.heap.ArenaAllocator,
    text: Image,
    text_tex: ?*c.SDL_Texture = null,

    pub fn load(io: Io, gpa: Allocator, r: *c.SDL_Renderer, dat: Io.Dir) !InventoryView {
        var sprites = try archive.Archive.open(io, gpa, dat, "common/sprite.dat");
        errdefer sprites.close(io, gpa);
        var other = try archive.Archive.open(io, gpa, dat, "common/other.dat");
        defer other.close(io, gpa);
        var lang = try archive.Archive.open(io, gpa, dat, "common/lang.dat");
        defer lang.close(io, gpa);
        const ln = lang_mod.language(io, gpa, dat);
        const font_bytes = lang_mod.readFont(io, gpa, &other, "03_small", ln) orelse return error.NotFound;
        errdefer gpa.free(font_bytes);
        const sys_bytes = lang_mod.readFont(io, gpa, &other, "04_system", ln) orelse return error.NotFound;
        errdefer gpa.free(sys_bytes);
        const strings_bytes = try lang.readAlloc(io, gpa, lang.find("string.tab") orelse return error.NotFound);
        errdefer gpa.free(strings_bytes);
        const examine_bytes = try lang.readAlloc(io, gpa, lang.find("items.inf") orelse return error.NotFound);
        errdefer gpa.free(examine_bytes);
        var v: InventoryView = .{
            .gpa = gpa,
            .io = io,
            .renderer = r,
            .sprites = sprites,
            .font_bytes = font_bytes,
            .font = try og.formats.font.parse(font_bytes),
            .sys_bytes = sys_bytes,
            .sys = try og.formats.font.parse(sys_bytes),
            .strings_bytes = strings_bytes,
            .examine_bytes = examine_bytes,
            .strings = try og.formats.strtab.parseStrings(gpa, strings_bytes),
            .examine = undefined,
            .examine_arena = .init(gpa),
            .text = try Image.init(gpa, og.state.world.screen_w, og.state.world.screen_h),
        };
        v.examine = try og.formats.strtab.parseExamine(gpa, v.examine_arena.allocator(), examine_bytes);
        v.bg = try v.loadSprite("inventory.spr");
        v.box_bg = v.loadSprite("item_list.spr") catch .{};
        v.giveman = v.loadSprite("GiveMan.spr") catch .{};
        v.ebox = v.loadSprite("ebox.spr") catch .{};
        v.exbox = v.loadSprite("examine_box.spr") catch .{};
        if (lang.find("activeareas.inf")) |e| if (lang.readAlloc(io, gpa, e)) |b| {
            v.area_bytes = b;
            v.area_examine = og.formats.strtab.parseExamineKey(gpa, v.examine_arena.allocator(), b, "AREA_EXAMINE:") catch .{};
        } else |_| {};
        v.atlas = v.loadSprite("fonts.spr") catch .{};
        if (other.find("02_hp.fnt")) |e| if (other.readAlloc(io, gpa, e)) |b| {
            defer gpa.free(b);
            v.digits = og.formats.font.parseTex(b) catch @splat(null);
        } else |_| {};
        v.give_text = Image.init(gpa, og.state.world.screen_w, og.state.world.screen_h) catch null;
        return v;
    }

    pub fn deinit(self: *InventoryView) void {
        self.bg.deinit(self.gpa);
        self.box_bg.deinit(self.gpa);
        self.giveman.deinit(self.gpa);
        self.ebox.deinit(self.gpa);
        self.exbox.deinit(self.gpa);
        self.area_examine.deinit(self.gpa);
        if (self.area_bytes.len > 0) self.gpa.free(self.area_bytes);
        self.atlas.deinit(self.gpa);
        if (self.give_tex) |t| c.SDL_DestroyTexture(t);
        if (self.give_text) |*t| t.deinit(self.gpa);
        var it = self.icons.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.icons.deinit(self.gpa);
        if (self.text_tex) |t| c.SDL_DestroyTexture(t);
        self.text.deinit(self.gpa);
        self.strings.deinit(self.gpa);
        self.examine.deinit(self.gpa);
        self.examine_arena.deinit();
        self.gpa.free(self.font_bytes);
        self.gpa.free(self.sys_bytes);
        self.gpa.free(self.strings_bytes);
        self.gpa.free(self.examine_bytes);
        self.sprites.close(self.io, self.gpa);
    }

    fn loadSprite(self: *InventoryView, name: []const u8) !gfx.Frames {
        const e = self.sprites.find(name) orelse return error.NotFound;
        const data = try self.sprites.readAlloc(self.io, self.gpa, e);
        defer self.gpa.free(data);
        return gfx.loadSmooth(self.gpa, self.renderer, name, data);
    }

    /// Item icon `icons\<spriteFile>.spr` (frame 0 big, 1 small).
    pub fn icon(self: *InventoryView, sprite_file: []const u8) ?*gfx.Frames {
        if (sprite_file.len == 0 or sprite_file.len > 48) return null;
        var key_buf: [64]u8 = undefined;
        const key = std.ascii.lowerString(&key_buf, sprite_file);
        if (self.icons.getPtr(key)) |f| return f;
        var buf: [80]u8 = undefined;
        const frames = self.loadSprite(std.fmt.bufPrint(&buf, "icons\\{s}.spr", .{sprite_file}) catch return null) catch gfx.Frames{};
        const owned = self.gpa.dupe(u8, key) catch return null;
        self.icons.put(self.gpa, owned, frames) catch {
            self.gpa.free(owned);
            return null;
        };
        return self.icons.getPtr(key);
    }

    /// Open (0x42dc10): the selected hero, current item = the one in hand.
    pub fn show(self: *InventoryView, w: *World) void {
        self.open = true;
        self.world = w;
        self.carried = null;
        self.pressed = .none;
        self.thumb_drag = false;
        const heroes = w.party();
        self.hero = 0;
        for (heroes.slice(), 0..) |h, i| if (std.ascii.eqlIgnoreCase(h.name, w.selected_hero)) {
            self.hero = i;
        };
        self.current = if (self.heroObj(w)) |h| inv.equipment.equipped(w, h, .hand) else null;
    }

    /// Close (0x42dd70): the cursor item goes back to the backpack.
    pub fn close(self: *InventoryView, w: *World) void {
        self.sync(w);
        if (self.carried) |o| inv.item.setPlace(o, .backpack);
        self.carried = null;
        self.give = null;
        self.open = false;
    }

    /// Another world (level switch): item references are invalid.
    pub fn sync(self: *InventoryView, w: *World) void {
        if (self.world == w) return;
        self.world = w;
        self.carried = null;
        self.current = null;
    }

    /// The mouse cursor isn't drawn while an item is on the cursor.
    pub fn hidesCursor(self: *const InventoryView) bool {
        return self.open and self.carried != null;
    }

    pub fn heroObj(self: *InventoryView, w: *World) ?*Object {
        const heroes = w.party();
        const list = heroes.slice();
        return if (self.hero < list.len) list[self.hero] else null;
    }

    /// Hero portrait (`icons\<spriteFile>.spr`).
    pub fn portrait(self: *InventoryView, hero: *Object) ?*gfx.Frames {
        const sf = hero.getString("spriteFile");
        return self.icon(if (sf.len > 0) sf else hero.name);
    }

    pub fn itemName(self: *InventoryView, o: *Object) []const u8 {
        return self.strings.get(og.fields.nameId(o)) orelse o.name;
    }

    // ---------------------------------------------------------------- input (0x42dec0)

    pub fn bagList(self: *InventoryView, w: *World, hero: *Object, out: []inv.list.Entry) []inv.list.Entry {
        return inv.list.list(w, hero, self.tab, out);
    }

    fn partyLen(w: *World) usize {
        const heroes = w.party();
        return heroes.slice().len;
    }

    pub fn hitAt(w: *World, x: f32, y: f32) Hit {
        for (0..cells) |k| if (cellRect(k).has(x, y)) return .{ .cell = k };
        if (bag_rect.has(x, y)) return .bag;
        if (torso_rect.has(x, y)) return .torso;
        if (hand_rect.has(x, y)) return .hand;
        if (picture_rect.has(x, y)) return .picture;
        for (tab_rects, 0..) |r, i| if (r.has(x, y)) return .{ .tab = i };
        for (0..@min(partyLen(w), portrait_l.len)) |i| if (portraitRect(i).has(x, y)) return .{ .portrait = i };
        if (exit_rect.has(x, y)) return .exit;
        if (skill_rect.has(x, y)) return .skills;
        return .none;
    }

    /// Item in a backpack cell (the first with this nameID).
    pub fn cellItem(self: *InventoryView, w: *World, hero: *Object, k: usize) ?*Object {
        var buf: [inv.list.max_entries]inv.list.Entry = undefined;
        const items = self.bagList(w, hero, &buf);
        const i = self.scroll + k;
        return if (i < items.len) items[i].item else null;
    }

    pub fn bagCount(self: *InventoryView, w: *World, hero: *Object) usize {
        var buf: [inv.list.max_entries]inv.list.Entry = undefined;
        return self.bagList(w, hero, &buf).len;
    }

    /// Left release: Exit and Weapons Skill act if released over themselves.
    pub fn release(self: *InventoryView, w: *World, x: f32, y: f32) Action {
        self.sync(w);
        self.thumb_drag = false;
        const was = self.pressed;
        self.pressed = .none;
        const now = hitAt(w, x, y);
        if (was == .exit and now == .exit) {
            w.out.sound(w.gpa, "invgive", null);
            self.close(w);
            return .close;
        }
        if (was == .skills and now == .skills) {
            w.out.sound(w.gpa, "invgive", null);
            return .skills;
        }
        return .none;
    }

    /// Mouse motion: the backpack thumb.
    pub fn motion(self: *InventoryView, w: *World, y: f32) void {
        if (!self.thumb_drag) return;
        const hero = self.heroObj(w) orelse return;
        bar.drag(&self.scroll, self.bagCount(w, hero), y);
    }

    pub fn scrollBy(self: *InventoryView, d: i32) void {
        if (d < 0) self.scroll -|= 1 else self.scroll += 1;
    }

    pub fn hoverItem(self: *InventoryView, w: *World, x: f32, y: f32) ?*Object {
        const hero = self.heroObj(w) orelse return null;
        return switch (hitAt(w, x, y)) {
            .cell => |k| self.cellItem(w, hero, k),
            .torso => inv.equipment.equipped(w, hero, .armor),
            .hand => inv.equipment.equipped(w, hero, .hand),
            else => null,
        };
    }

    // ---------------------------------------------------------------- drawing (0x42ed90)

    /// Box slot `itm_k` (0x4564b0): its items, count, checkmark.
    pub const BoxSlot = struct { objs: [13]*Object = undefined, n: usize = 0, qty: i32 = 0, k: usize };

    pub const Exam = struct { x: f32, y: f32, h: f32, lines: usize };
};

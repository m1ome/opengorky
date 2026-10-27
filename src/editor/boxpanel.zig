//! Box contents window (right click on a box in a level): the items with their
//! amounts on the left, every weapon, ammo and item class to add on the right.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const ui = @import("ui");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const vars = @import("vars.zig");
const box = @import("box.zig");
const catalog = @import("catalog.zig");
const search = @import("search.zig");
const common_archive = @import("store.zig").common_archive;
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;

const Open = main.BoxOpen;

/// Catalog entry of class file `class` (`cw_crowbar.s`).
fn entryOf(app: *App, class: []const u8) ?catalog.Entry {
    for (app.catalog.entries.items) |e| {
        if (e.kind == .enemy or e.kind == .hero) continue;
        if (std.ascii.endsWithIgnoreCase(e.entry, class) and e.entry.len == "classes\\".len + class.len) return e;
    }
    return null;
}

/// The class's own ammo count (`counter`).
fn defaultCount(app: *App, class: []const u8) ?i32 {
    var buf: [96]u8 = undefined;
    const f = app.store.file(common_archive, std.fmt.bufPrint(&buf, "classes\\{s}", .{class}) catch return null) catch return null;
    const v = vars.get(app.store.text(f), "counter") orelse return null;
    return @intFromFloat(v);
}

fn isAmmo(class: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(class, "ca_");
}

/// Adds one `class` to box `o` (CLI `--box-add`).
pub fn addClass(app: *App, a: Allocator, o: Open, class: []const u8) !void {
    add(app, a, o, try parse(app, a, o), class);
}

pub fn panel(app: *App, a: Allocator, o: Open) void {
    const items = parse(app, a, o) catch return;
    if (main.modal(app, "boxpanel", 860, 600, theme.panel, if (o.owner != null) tx.alloc(a, tx.inv_title, .{o.name}) else tx.alloc(a, tx.box_title, .{o.name}), "") == .close) app.box = null;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fit() }, .padding = .{ .left = 16, .right = 16, .bottom = 8 } } });
    clay.text(tx.get(if (o.owner != null) tx.inv_hint else tx.box_hint), .{ .textColor = theme.warn, .fontSize = 13, .fontId = font_mod.regular });
    clay.close();

    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } }, .border = .{ .color = theme.line, .width = .{ .top = 1 } } });
    // Contents.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    main.panelHeader(tx.alloc(a, tx.box_contents, .{items.len}));
    clay.openScroll(.{ .id = clay.id("box_items"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    if (items.len == 0) {
        clay.open(.{ .layout = .{ .padding = .{ .left = 16, .top = 8 } } });
        txt(tx.get(tx.box_empty), 14, theme.dim, font_mod.regular);
        clay.close();
    }
    for (items, 0..) |it, i| itemRow(app, a, o, items, i, it);
    clay.close();
    clay.close();
    // Classes to add.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(320), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM }, .border = .{ .color = theme.line, .width = .{ .left = 1 } } });
    main.panelHeader(tx.get(tx.box_add));
    main.searchField(app, a);
    clay.openScroll(.{ .id = clay.id("box_classes"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    for (app.catalog.entries.items, 0..) |e, i| {
        if (e.kind == .enemy or e.kind == .hero) continue;
        if (!search.matches(app.query(), &.{ e.id, e.title })) continue;
        const rid = clay.idi("box_cls", @intCast(i));
        if (main.clickable(app, .{
            .id = rid,
            .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(30) }, .padding = .{ .left = 10, .right = 8 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
            .backgroundColor = theme.panel,
        }, false)) add(app, a, o, items, e.entry["classes\\".len..]);
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(26), .height = clay.fixed(26) } }, .image = .{ .imageData = app.icon(e.icon) } });
        txt(if (e.title.len > 0) e.title else e.id, 14, theme.text, font_mod.regular);
        txt(e.id, 12, theme.dim, font_mod.regular);
        clay.close();
    }
    clay.close();
    clay.close();
    clay.close();
    clay.close();
}

fn itemRow(app: *App, a: Allocator, o: Open, items: []box.Item, i: usize, it: box.Item) void {
    const e = entryOf(app, it.class);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(36) }, .padding = .{ .left = 12, .right = 12 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(32), .height = clay.fixed(32) } }, .image = .{ .imageData = if (e) |x| app.icon(x.icon) else null } });
    txt(if (e) |x| (if (x.title.len > 0) x.title else x.id) else it.class, 14, theme.text, font_mod.regular);
    txt(it.class, 12, theme.dim, font_mod.regular);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    const ammo = isAmmo(it.class);
    const n: i32 = if (ammo) it.count orelse defaultCount(app, it.class) orelse 1 else @intCast(it.names.items.len);
    smallButton(app, @intCast(i * 4), "-", a, o, items, i, -1);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(48) }, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER } } });
    txt(std.fmt.allocPrint(a, "{d}", .{n}) catch "?", 15, theme.text, font_mod.bold);
    clay.close();
    smallButton(app, @intCast(i * 4 + 1), "+", a, o, items, i, 1);
    smallButton(app, @intCast(i * 4 + 2), "×", a, o, items, i, 0);
    clay.close();
}

/// −/+ (`delta`, ×10 with Shift) or × (0: remove).
fn smallButton(app: *App, id: u32, label: []const u8, a: Allocator, o: Open, items: []box.Item, i: usize, delta: i32) void {
    const bid = clay.idi("box_btn", id);
    if (main.clickable(app, .{
        .id = bid,
        .layout = .{ .sizing = .{ .width = clay.fixed(26), .height = clay.fixed(24) }, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = theme.bg,
    }, false)) {
        const shift = (c.SDL_GetModState() & c.SDL_KMOD_SHIFT) != 0;
        change(app, a, o, items, i, if (delta == 0) null else delta * @as(i32, if (shift) 10 else 1));
    }
    txt(label, 15, if (delta == 0 and clay.pointerOver(bid)) theme.warn else theme.text, font_mod.bold);
    clay.close();
}

/// Item `i` by `delta` units (ammo: rounds); null removes it.
fn change(app: *App, a: Allocator, o: Open, items: []box.Item, i: usize, delta: ?i32) void {
    var list: std.ArrayList(box.Item) = .empty;
    list.appendSlice(a, items) catch return;
    const it = &list.items[i];
    if (delta) |d| {
        if (isAmmo(it.class)) {
            // A hero keeps an empty ammo slot (count 0), a box holds at least one round.
            it.count = @max(@as(i32, if (o.owner != null) 0 else 1), (it.count orelse defaultCount(app, it.class) orelse 1) + d);
        } else if (d < 0) {
            const drop: usize = @min(it.names.items.len, @as(usize, @intCast(-d)));
            it.names.shrinkRetainingCapacity(it.names.items.len - drop);
        } else for (0..@intCast(d)) |_| {
            it.names.append(a, newName(app, a, o, list.items, it.class) catch return) catch return;
        }
    } else it.names.clearRetainingCapacity();
    store(app, o, list.items);
}

pub fn add(app: *App, a: Allocator, o: Open, items: []box.Item, class: []const u8) void {
    // Ammo already there: one more pack (the class's count).
    for (items, 0..) |it, i| if (std.ascii.eqlIgnoreCase(it.class, class)) return change(app, a, o, items, i, if (isAmmo(class)) defaultCount(app, class) orelse 1 else 1);
    var list: std.ArrayList(box.Item) = .empty;
    list.appendSlice(a, items) catch return;
    var it: box.Item = .{ .class = class };
    it.names.append(a, newName(app, a, o, items, class) catch return) catch return;
    list.append(a, it) catch return;
    store(app, o, list.items);
}

fn store(app: *App, o: Open, items: []const box.Item) void {
    const out = (if (o.owner) |who| box.writeOwned(app.gpa, app.store.text(o.file), items, who) else box.write(app.gpa, app.store.text(o.file), items)) catch |err| return app.setStatus(tx.st_set_failed, .{err});
    app.store.replace(o.file, out) catch |err| {
        app.gpa.free(out);
        app.setStatus(tx.st_set_failed, .{err});
    };
}

/// `<level>_<box>_<class>_<k>`: objects are found by name in the whole game (saves,
/// heroes' inventories), so the level and box keep it unique.
fn parse(app: *App, a: Allocator, o: Open) ![]box.Item {
    return if (o.owner) |who| box.parseOwned(a, app.store.text(o.file), who) else box.parse(a, app.store.text(o.file));
}

fn newName(app: *App, a: Allocator, o: Open, items: []const box.Item, class: []const u8) ![]const u8 {
    // A hero's items: `<hero>_<class>_<k>` (`trantigne_stilleto_1`).
    const lvl = if (o.owner != null) "" else if (app.doc) |d| d.name else "";
    var lower: [64]u8 = undefined;
    const base = if (o.owner) |who| std.ascii.lowerString(&lower, who[0..@min(who.len, lower.len)]) else o.name;
    const dot = std.mem.lastIndexOfScalar(u8, class, '.') orelse class.len;
    const cls = class[(if (std.mem.indexOfScalar(u8, class, '_')) |k| k + 1 else 0)..dot];
    const text = app.store.text(o.file);
    var k: usize = 1;
    while (k < 1000) : (k += 1) {
        // A box made in the editor is already named after its level.
        const name = if (lvl.len == 0 or std.ascii.startsWithIgnoreCase(base, lvl))
            try std.fmt.allocPrint(a, "{s}_{s}_{d}", .{ base, cls, k })
        else
            try std.fmt.allocPrint(a, "{s}_{s}_{s}_{d}", .{ lvl, base, cls, k });
        if (std.ascii.findIgnoreCase(text, name) != null) continue;
        const taken = blk: {
            for (items) |it| for (it.names.items) |n| if (std.ascii.eqlIgnoreCase(n, name)) break :blk true;
            break :blk false;
        };
        if (taken) continue;
        if (app.doc) |d| if (d.world.rt.findObject(name) != null) continue;
        return name;
    }
    return error.NoFreeName;
}

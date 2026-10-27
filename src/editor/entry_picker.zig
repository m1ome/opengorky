//! The value chooser of an entry page (a model, a damage type, a class, ammo, a sound…):
//! the searchable list and what picking a row writes.

const std = @import("std");
const ammoClasses = @import("pages.zig").ammoClasses;
const classLabel = @import("pages.zig").classLabel;
const class_values = @import("pages.zig").class_values;
const setString = @import("pages.zig").setString;
const damage_types = @import("pages.zig").damage_types;
const setAct = @import("pages.zig").setAct;
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const catalog = @import("catalog.zig");
const sounds = @import("sounds.zig");
const search = @import("search.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;
const Picker = main.Picker;
const pages = @import("pages.zig");

pub fn picked(app: *App, p: Picker, value: []const u8) void {
    app.picker = null;
    const r = switch (p.what) {
        .act => setAct(app, p.file, value),
        .icon => setString(app, p.file, "spriteFile", value),
        .mesh => setString(app, p.file, "meshFile", value),
        .damage => app.store.setVar(p.file, &.{"type"}, value, "{"),
        .weapon_class => app.store.setVar(p.file, &.{"classType"}, value, "{"),
        .ammo => app.store.setVar(p.file, &.{"ammoUsed"}, value, "{"),
        .enemy_weapon => unreachable,
        .sound => blk: {
            app.player.play(app, value);
            break :blk sounds.edit(app, p.file, p.anim, .{ .set = .{ .i = p.cue, .name = value } });
        },
    };
    r catch |err| app.setStatus(tx.st_set_failed, .{err});
}

pub fn picker(app: *App, a: Allocator, p: Picker) void {
    // A battle enemy's weapon and a frame sound are chosen in their own parts.
    if (p.what == .enemy_weapon or p.what == .sound) return;
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.fixed(340), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM },
        .backgroundColor = theme.panel,
        .border = .{ .color = theme.line, .width = .{ .left = 1 } },
    });
    const title: tx.Msg = switch (p.what) {
        .act => tx.c_visual,
        .icon => tx.c_icon,
        .mesh => tx.c_mesh,
        .damage => tx.c_damage,
        .weapon_class => tx.f_class,
        .ammo => tx.f_ammo,
        .sound => unreachable,
        .enemy_weapon => unreachable,
    };
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fit() }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    main.panelHeader(tx.alloc(a, tx.pick_title, .{tx.get(title)}));
    const cid = clay.id("pick_cancel");
    clay.open(.{ .id = cid, .layout = .{ .padding = .{ .left = 8, .right = 12 } } });
    if (clay.hovered() and app.clicked) app.picker = null;
    txt(tx.get(tx.cancel), 13, if (clay.pointerOver(cid)) theme.warn else theme.dim, font_mod.regular);
    clay.close();
    clay.close();
    clay.openScroll(.{ .id = clay.id("picker"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .bottom = 8 } } });
    switch (p.what) {
        .act => for (app.catalog.acts.items, 0..) |v, i| option(app, p, i, v, v, null),
        .icon => for (app.catalog.icons.items, 0..) |v, i| option(app, p, i, v, v, v),
        .mesh => for (app.catalog.meshes.items, 0..) |v, i| option(app, p, i, v, v, null),
        .damage => for (damage_types, 0..) |d, i| option(app, p, i, std.fmt.allocPrint(a, "{d}", .{d[0]}) catch continue, tx.get(d[1]), null),
        .weapon_class => {
            for (class_values, 0..) |v, i| option(app, p, i, std.fmt.allocPrint(a, "{d}", .{v}) catch "", classLabel(a, @floatFromInt(v)), null);
        },
        .ammo => {
            option(app, p, 0, "0", tx.get(tx.a_none), null);
            option(app, p, 1, "-1", tx.get(tx.a_self), null);
            for (ammoClasses(app, a), 2..) |x, i| option(app, p, i, std.fmt.allocPrint(a, "{d}", .{x.id}) catch continue, std.fmt.allocPrint(a, "{s} ({d})", .{ x.title, x.id }) catch x.title, null);
        },
        // shortcut: 300 shown at most; the search narrows the rest.
        .enemy_weapon => unreachable,
        .sound => unreachable,
    }
    clay.close();
    clay.close();
}

fn option(app: *App, p: Picker, i: usize, value: []const u8, label: []const u8, icon: ?[]const u8) void {
    const oid = clay.idi("opt", @intCast(i));
    if (main.clickable(app, .{
        .id = oid,
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(if (icon != null) 36 else 26) }, .padding = .{ .left = 12, .right = 8 }, .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = theme.panel,
    }, false)) picked(app, p, value);
    if (icon) |n| clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(32), .height = clay.fixed(32) } }, .image = .{ .imageData = app.icon(n) } });
    txt(label, 14, theme.text, font_mod.regular);
    clay.close();
}

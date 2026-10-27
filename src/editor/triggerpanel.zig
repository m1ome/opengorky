//! Trigger window (right click on an area of a location): the area's own script
//! (`.are` of the object naming it) and every place of the level's scripts that names
//! the area (`HeroInArea("cutscene_crazy")`…), each block can be turned off and on.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const scenes = @import("scenes.zig");
const scenepage = @import("scenepage.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;

pub fn panel(app: *App, a: Allocator, name: []const u8) void {
    const d = app.doc orelse return;
    if (main.modal(app, "triggerpanel", 900, 640, theme.bg, tx.alloc(a, tx.tr_title, .{name}), "") == .close) app.trigger = null;
    clay.openScroll(.{ .id = clay.id("trigger_body"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 16, .right = 16, .bottom = 16 }, .childGap = 8 } });

    // Places naming it, in every script of the level.
    main.panelHeader(tx.get(tx.tr_refs));
    var n: u32 = 0;
    for (d.scripts.items) |entry| {
        const fi = app.store.file(d.level_archive, entry) catch continue;
        const cs = scenes.refs(a, app.store.text(fi), name) catch continue;
        for (cs, 0..) |call, k| {
            n += 1;
            scenepage.card(app, a, fi, d.name, entry, call, @intCast(n * 16 + k), tx.tr_turn_off);
        }
    }
    if (n == 0) txt(tx.get(tx.tr_no_refs), 13, theme.dim, font_mod.regular);

    // The area object's own script (`areaName` = this area): its functions run on use.
    for (d.world.rt.objects.items) |o| {
        if (!std.ascii.eqlIgnoreCase(o.getString("areaName"), name)) continue;
        var buf: [128]u8 = undefined;
        const entry = std.fmt.bufPrint(&buf, "{s}.are", .{o.name}) catch continue;
        const fi = app.store.file(d.level_archive, entry) catch continue;
        main.panelHeader(tx.alloc(a, tx.tr_own, .{entry}));
        var lines = std.mem.splitScalar(u8, app.store.text(fi), '\n');
        while (lines.next()) |raw| {
            const l = std.mem.trimEnd(u8, raw, " \t\r");
            if (l.len > 0) txt(a.dupe(u8, l) catch continue, 12, theme.text, font_mod.regular);
        }
    }
    clay.close();
    clay.close();
}

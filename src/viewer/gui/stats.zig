//! Hero stats and skills windows. Gui methods (see gui.zig).

const std = @import("std");
const gui_panel = @import("panel.zig");
const gui_mod = @import("../gui.zig");
const Gui = gui_mod.Gui;
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");
const gui_windows = @import("windows.zig");
const SkillWindow = gui_windows.SkillWindow;
const StatsWindow = gui_windows.StatsWindow;

/// Hero skill list: (weapon nameID, level) with an icon.
fn skillRows(w: *og.state.world.World, hero: *og.script.object.Object, out: []og.state.object.Skill) []og.state.object.Skill {
    var n: usize = 0;
    for (og.state.world.World.nativeOf(hero).growth.skills.items) |sk| {
        if (sk.level <= 0 or SkillWindow.iconOf(sk.id) == null) continue;
        if (n == out.len) break;
        out[n] = sk;
        n += 1;
    }
    _ = w;
    return out[0..n];
}

/// Skills window (0x4af450): background, portrait (frame 1) at (14,16), name
/// right-aligned at x+125, y+77, three rows: centred icon (frame 1) and "Lv.N"
/// (string.tab 577) at (right − 30, top + 10); GScrollBar thumb and arrows.
pub fn drawSkills(self: *Gui, r: *c.SDL_Renderer, w: *og.state.world.World, strings: ?*const og.formats.strtab.Table) !void {
    const sw = &self.skills;
    sw.step(w.ticks);
    if (!sw.visible or self.skill_spr.len() == 0) return;
    const hero = w.actorObject(sw.hero) orelse return;
    try self.skill_spr.draw(r, 0, sw.x, sw.y);
    if (self.portrait(hero)) |fr| if (fr.len() > 1) try fr.draw(r, 1, sw.x + 14, sw.y + 16);
    var rows_buf: [64]og.state.object.Skill = undefined;
    const rows = skillRows(w, hero, &rows_buf);
    const max_scroll = rows.len -| 3;
    sw.scroll = @min(sw.scroll, max_scroll);
    const t = &(self.win_text orelse return);
    @memset(t.pixels, 0);
    // Name and "Lv." in font 3 (04_system, 0x4af692, 0x4af653).
    const f = self.sys_font orelse self.font orelse return;
    const name = if (strings) |st| st.get(og.fields.nameId(hero)) orelse hero.name else hero.name;
    const nx: i32 = @as(i32, @intFromFloat(sw.x)) + 125 - @as(i32, @intCast(f.measure(name)));
    gui_mod.textShadow(f, t.*, nx, @as(i32, @intFromFloat(sw.y)) + 77, name, gui_mod.text_light);
    for (0..3) |i| {
        const k = sw.scroll + i;
        if (k >= rows.len) break;
        const rc = SkillWindow.rows[i];
        if (self.icon(SkillWindow.iconOf(rows[k].id).?)) |fr| if (fr.len() > 1) {
            const size = fr.sizes.items[1];
            try fr.drawShadowed(r, 1, gfx.Frames.center(@trunc(sw.x) + rc[0], rc[2] - rc[0], size[0]), gfx.Frames.center(@trunc(sw.y) + rc[1], rc[3] - rc[1], size[1]));
        };
        var tb: [24]u8 = undefined;
        const lv = std.fmt.bufPrint(&tb, "{s}{d}", .{ if (strings) |st| st.get(577) orelse "Lv." else "Lv.", rows[k].level }) catch continue;
        gui_mod.textShadow(f, t.*, @as(i32, @intFromFloat(sw.x + rc[2] - 30)), @as(i32, @intFromFloat(sw.y + rc[1] + 10)), lv, gui_mod.text_light);
    }
    try gfx.drawImage(r, &self.win_tex, t.*);
    // Scrollbar (0x4aed64, setup 0x4af0e1: 12, 175, 15, 29) at (x+117, y+117).
    const sb: gui_mod.Scrollbar = .{ .y = @trunc(sw.y) + 117, .len = 175, .rows = 3 };
    try sb.draw(r, &self.scrollbar, @trunc(sw.x) + 117, sw.scroll, rows.len);
}

/// Skills window tooltip: the weapon name under the cursor.
pub fn skillTooltip(self: *Gui, w: *og.state.world.World, mx: f32, my: f32, strings: ?*const og.formats.strtab.Table) ?[]const u8 {
    const i = self.skills.rowAt(mx, my) orelse return null;
    const hero = w.actorObject(self.skills.hero) orelse return null;
    var rows_buf: [64]og.state.object.Skill = undefined;
    const rows = skillRows(w, hero, &rows_buf);
    const k = self.skills.scroll + i;
    if (k >= rows.len) return null;
    return if (strings) |st| st.get(rows[k].id) else null;
}

/// Window rows: (current, limit) per 0x48fcb0… — exp / level threshold, hp /
/// max_hp, move, luck %, accuracy %, counterattack %, coolness (rage / max_rage).
fn statRow(hero: *og.script.object.Object, i: usize) [2]f32 {
    const f = og.fields.getF;
    return switch (i) {
        0 => .{ @floatFromInt(og.fields.experience(hero)), @floatFromInt(og.battle.rules.levelThreshold(hero.getInt("level"))) },
        1 => .{ @floatFromInt(og.fields.hp(hero)), @floatFromInt(og.fields.maxHp(hero)) },
        2 => .{ @floatFromInt(og.fields.walkRange(hero)), @floatFromInt(og.fields.walkRange(hero)) },
        3 => .{ f(hero, "luck"), 100 },
        4 => .{ f(hero, "accuracy"), 100 },
        5 => .{ f(hero, "counterAttack"), 100 },
        else => blk: {
            const rmax: f32 = @floatFromInt(hero.getInt("max_rage"));
            var cur: f32 = @floatFromInt(hero.getInt("rage"));
            if (cur < 0 or cur > rmax) cur = 0;
            break :blk .{ cur, rmax };
        },
    };
}

/// "+" (0x4b0980): health and coolness always, luck/accuracy/counterattack up to
/// 100; "−" (0x4b0a90): while above 0, coolness while max_rage ≥ 1 (may go
/// negative). Remaining = total − Σ|points|; below zero — undo.
pub fn statsClick(self: *Gui, w: *og.state.world.World, mx: f32, my: f32) void {
    const sw = &self.stats;
    if (!sw.upgrade or !sw.visible) return;
    const hero = w.actorObject(sw.hero) orelse return;
    w.out.sound(w.gpa, "upgrade_setpoints", null);
    const X = @trunc(sw.x);
    const Y = @trunc(sw.y);
    var o: f32 = 0;
    for (0..7) |i| {
        const in = struct {
            fn f(x: f32, y: f32, ax: f32, ay: f32) bool {
                return x >= ax and x <= ax + 25 and y >= ay and y <= ay + 25;
            }
        }.f;
        if (in(mx, my, X - 23, Y + 98 + o)) {
            const p = &sw.pts[i];
            switch (i) {
                1, 3, 4, 5 => if (p.* > 0) {
                    p.* -= 1;
                },
                6 => if (og.num.toF32(hero.getInt("max_rage") + p.*) > 1) {
                    p.* -= 1;
                    if (sw.remaining() < 0) p.* += 1;
                },
                else => {},
            }
            return;
        }
        if (in(mx, my, X + 183, Y + 98 + o)) {
            const p = &sw.pts[i];
            const r = statRow(hero, i);
            switch (i) {
                1, 6 => p.* += 1,
                3, 4, 5 => if (r[0] + og.num.toF32(p.* + 1) <= r[1]) {
                    p.* += 1;
                },
                else => {},
            }
            if (sw.remaining() < 0) p.* -= 1;
            return;
        }
        o = @trunc(o + 33.5);
    }
    // Accept (0x4b0bc0): max_hp, luck, accuracy, counterattack, max_rage; leftover points are lost.
    if (mx >= X and mx <= X + 185 and my >= Y + 337 and my <= Y + 367) {
        og.inventory.points.applyLevelPoints(hero, sw.pts);
        w.out.sound(w.gpa, "invgive", null);
        sw.upgrade = false;
        sw.close();
    }
}

/// Stats window (0x4afe00).
pub fn drawStats(self: *Gui, r: *c.SDL_Renderer, w: *og.state.world.World, strings: ?*const og.formats.strtab.Table) !void {
    return drawStatsWindow(self, r, w, strings, &self.stats);
}

/// Stats window on the inventory screen (0x42dc10): fixed at (450, 10), read-only.
pub fn drawInventoryStats(self: *Gui, r: *c.SDL_Renderer, w: *og.state.world.World, hero: []const u8, strings: ?*const og.formats.strtab.Table) !void {
    if (!self.inv_stats.visible or !std.mem.eql(u8, self.inv_stats.hero, hero)) self.inv_stats.show(450, 10, hero, false, 0);
    return drawStatsWindow(self, r, w, strings, &self.inv_stats);
}

fn drawStatsWindow(self: *Gui, r: *c.SDL_Renderer, w: *og.state.world.World, strings: ?*const og.formats.strtab.Table, sw: *StatsWindow) !void {
    sw.step(w.ticks);
    if (!sw.visible or self.hero_stats.len() < 19) return;
    const hero = w.actorObject(sw.hero) orelse return;
    const X = @trunc(sw.x);
    const Y = @trunc(sw.y);
    try self.hero_stats.draw(r, 0, X, Y);
    if (self.portrait(hero)) |p| if (p.len() > 1) try p.draw(r, 1, X + 15, Y + 15);
    const t = &(self.win_text orelse return);
    @memset(t.pixels, 0);
    const f2 = self.font orelse return;
    const f3 = self.sys_font orelse f2;
    const xi: i32 = @intFromFloat(X);
    const yi: i32 = @intFromFloat(Y);
    const name = if (strings) |st| st.get(og.fields.nameId(hero)) orelse hero.name else hero.name;
    gui_mod.textShadow(f3, t.*, xi + 169 - @as(i32, @intCast(f3.measure(name))), yi + 18, name, gui_mod.text_light);
    var b: [96]u8 = undefined;
    const s = struct {
        fn get(st: ?*const og.formats.strtab.Table, id: i32, fb: []const u8) []const u8 {
            return if (st) |x| x.get(id) orelse fb else fb;
        }
    }.get;
    // Joan McFadden (nameID 24): "special skill: / healing +15%".
    if (og.fields.nameId(hero) == 24) {
        const l1 = std.fmt.bufPrint(&b, "{s}:", .{s(strings, 574, "special skill")}) catch "";
        gui_mod.textShadow(f2, t.*, xi + 225 - @as(i32, @intCast(f2.measure(l1))), yi + 32, l1, gui_mod.text_light);
        var b2: [64]u8 = undefined;
        const l2 = std.fmt.bufPrint(&b2, "{s} +15%", .{s(strings, 575, "healing")}) catch "";
        gui_mod.textShadow(f2, t.*, xi + 225 - @as(i32, @intCast(f2.measure(l1))), yi + 32 + @as(i32, @intCast(f2.height + 1)), l2, gui_mod.text_light);
    }
    const lv = std.fmt.bufPrint(&b, "{s}: {d}", .{ s(strings, 360, "LEVEL"), hero.getInt("level") }) catch "";
    gui_mod.textShadow(f3, t.*, xi + 110, yi + 74, lv, gui_mod.text_dim);
    const labels = [7]struct { id: i32, fb: []const u8 }{
        .{ .id = 350, .fb = "Experience" }, .{ .id = 351, .fb = "HP / Max HP" }, .{ .id = 352, .fb = "Walk Range" },
        .{ .id = 353, .fb = "Luck" },       .{ .id = 354, .fb = "Accuracy" },    .{ .id = 355, .fb = "Counter Attack" },
        .{ .id = 356, .fb = "Calmness" },
    };
    for (0..7) |i| {
        const off = 33.5 * og.num.toF32(i);
        const row = statRow(hero, i);
        const lab = s(strings, labels[i].id, labels[i].fb);
        const p = sw.pts[i];
        const text = switch (i) {
            0, 2 => std.fmt.bufPrint(&b, "{s} {d:.0}/{d:.0} ", .{ lab, row[0], row[1] }),
            3, 4, 5 => if (sw.upgrade) std.fmt.bufPrint(&b, "{s} {d:.0}% +{d}", .{ lab, row[0], p }) else std.fmt.bufPrint(&b, "{s} {d:.0}%", .{ lab, row[0] }),
            else => if (sw.upgrade) std.fmt.bufPrint(&b, "{s} {d:.0}/{d:.0} +{d}", .{ lab, row[0], row[1], p }) else std.fmt.bufPrint(&b, "{s} {d:.0}/{d:.0}", .{ lab, row[0], row[1] }),
        } catch "";
        gui_mod.textShadow(f2, t.*, xi + 20, @intFromFloat(Y + 103 + off), text, gui_mod.text_light);
        try self.hero_stats.draw(r, 2, X + 16, @trunc(Y + 114 + off));
        const len: f32 = if (row[1] > 0) std.math.clamp(@trunc(row[0] / row[1] * 154), 0, 154) else 0;
        try self.hero_stats.drawClipped(r, 1, X + 16, @trunc(Y + 114 + off), len);
        if (sw.upgrade and sw.popin >= 0 and i != 0 and i != 2) {
            var nb: [12]u8 = undefined;
            const ns = std.fmt.bufPrint(&nb, "{d}", .{p}) catch "";
            gui_mod.textShadow(f3, t.*, xi + 155, @intFromFloat(Y + 103 + off), ns, .{ 255, 255, 255 });
            const fi: usize = @intFromFloat(@trunc(sw.popin));
            try self.hero_stats.draw(r, fi + 3, X - 23, @trunc(Y + 98 + off));
            try self.hero_stats.draw(r, fi + 10, X + 183, @trunc(Y + 98 + off));
        }
    }
    if (sw.upgrade) {
        try self.hero_stats.draw(r, 17, X, Y + 337);
        try self.hero_stats.draw(r, 18, X - 60, Y + 10);
        const acc = s(strings, 512, "Accept");
        // Centred (X+93, Y+348) (0x50b674).
        gui_mod.textShadow(f3, t.*, xi + 93 - @divTrunc(@as(i32, @intCast(f3.measure(acc))), 2), yi + 348, acc, gui_mod.text_dim);
    }
    try gfx.drawImage(r, &self.win_tex, t.*);
    if (sw.upgrade) {
        var nb: [12]u8 = undefined;
        const ns = std.fmt.bufPrint(&nb, "{d}", .{sw.remaining()}) catch "";
        // Remaining points: 02_HP centred at X−30 on baseline Y+59 (0x47a970).
        try gui_panel.drawGlyphsBase(self, r, &self.hp_glyphs, 1, ns, X - 30, Y + 59);
    }
}

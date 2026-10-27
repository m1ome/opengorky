//! An enemy's weapons on its page: swapped for this enemy or its whole class, the reach
//! of each shown on a grid, and the resistances the exe gives its nameID.

const std = @import("std");
const classLabel = @import("pages.zig").classLabel;
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const vars = @import("vars.zig");
const catalog = @import("catalog.zig");
const Entry = catalog.Entry;
const common_archive = @import("store.zig").common_archive;
const og = @import("opengorky");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;
const Picker = main.Picker;
const pages = @import("pages.zig");
const zone = @import("zone.zig");

/// A battle enemy's weapon (`.wpn` Store file `wpn`, its class `class`): the class it
/// includes, and on a click the other enemy weapon classes of the same reach (close or
/// long, as the attack animation goes by it) to swap in — this enemy only.
pub fn weaponChoice(app: *App, a: Allocator, wpn: usize, class: ?usize) void {
    const cur = if (class) |ci| classFile(app.store.files.items[ci].entry) else "?";
    const cur_long = if (class) |ci| (vars.get(app.store.text(ci), "longAttack") orelse 0) != 0 else false;
    const new = weaponPicker(app, a, wpn, cur, cur_long, tx.wp_change) orelse return;
    swapWeapon(app, wpn, cur, new) catch |err| app.setStatus(tx.st_set_failed, .{err});
}

/// The weapon class `cur` (close or long by `cur_long`) as a row; a click lists the
/// other enemy weapon classes of the same reach (the attack animation goes by it).
/// Returns the one clicked. `key` tells the open list apart.
fn weaponPicker(app: *App, a: Allocator, key: usize, cur: []const u8, cur_long: bool, action: tx.Msg) ?[]const u8 {
    const open = if (app.picker) |p| p.what == .enemy_weapon and p.file == key else false;
    const rid = clay.idi("wpn_cls", @truncate(key));
    if (main.clickable(app, .{
        .id = rid,
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(26) }, .padding = .{ .left = 24, .right = 12 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = theme.panel,
    }, open)) app.picker = if (open) null else .{ .what = .enemy_weapon, .file = key };
    txt(tx.alloc(a, tx.wp_class_of, .{ cur, tx.get(if (cur_long) tx.wp_long else tx.wp_short) }), 13, theme.text, font_mod.regular);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    txt(tx.get(if (open) tx.cancel else action), 12, theme.accent_hover, font_mod.regular);
    clay.close();
    if (!open) return null;
    var ar = og.formats.archive.Archive.open(app.io, app.gpa, app.dat, common_archive) catch return null;
    defer ar.close(app.io, app.gpa);
    var chosen: ?[]const u8 = null;
    for (ar.entries, 0..) |*e, i| {
        if (!std.ascii.startsWithIgnoreCase(e.name, "classes\\wp_") or !std.ascii.endsWithIgnoreCase(e.name, ".ss")) continue;
        const f = app.store.file(common_archive, e.name) catch continue;
        const t = app.store.text(f);
        if (((vars.get(t, "longAttack") orelse 0) != 0) != cur_long) continue;
        const name = app.store.files.items[f].entry["classes\\".len..];
        if (std.ascii.eqlIgnoreCase(name, cur)) continue;
        const oid = clay.idi("wpn_opt", @intCast(i));
        if (main.clickable(app, .{
            .id = oid,
            .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(24) }, .padding = .{ .left = 36, .right = 12 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
            .backgroundColor = theme.bg,
        }, false)) {
            app.picker = null;
            chosen = name;
        }
        txt(name[0 .. name.len - 3], 13, theme.text, font_mod.regular);
        txt(tx.alloc(a, tx.wp_option, .{ classLabel(a, vars.get(t, "classType")), vars.get(t, "max_damage") orelse 0 }), 12, theme.dim, font_mod.regular);
        clay.close();
    }
    return chosen;
}

/// Every fighter of enemy class `class` in every battle (the game's and the ones added
/// in the editor) gets weapon class `new` for `cur` (a step per `.wpn`); the editor's
/// built attack (shogoth) follows. Returns how many weapons changed.
pub fn swapClassWeapon(app: *App, class: []const u8, cur: []const u8, new: []const u8) !usize {
    const a = app.frame.allocator();
    const ft = try std.fmt.allocPrint(a, "ft_{s}.ss", .{class});
    var n: usize = 0;
    for (app.levels) |lvl| {
        if (!lvl.battle) continue;
        const path = try std.fmt.allocPrint(a, "{s}/other.dat", .{lvl.name});
        // Entries of the archive and the editor's new files of it.
        var names: std.ArrayList([]const u8) = .empty;
        if (og.formats.archive.Archive.open(app.io, app.gpa, app.dat, path)) |ar_c| {
            var ar = ar_c;
            defer ar.close(app.io, app.gpa);
            for (ar.entries) |e| try names.append(a, try a.dupe(u8, e.name));
        } else |_| continue;
        for (app.store.files.items, 0..) |f, i| if (std.mem.eql(u8, f.archive, path) and !app.store.gone(i)) try names.append(a, f.entry);
        for (names.items) |fe| {
            if (!std.ascii.endsWithIgnoreCase(fe, ".ftr")) continue;
            const fi = app.store.file(path, fe) catch continue;
            if (std.ascii.findIgnoreCase(app.store.text(fi), ft) == null) continue;
            const q = try std.fmt.allocPrint(a, "\"{s}\"", .{fe[0 .. fe.len - 4]});
            for (names.items) |we| {
                if (!std.ascii.endsWithIgnoreCase(we, ".wpn")) continue;
                const wi = app.store.file(path, we) catch continue;
                const t = app.store.text(wi);
                if (std.ascii.findIgnoreCase(t, q) == null) continue;
                swapWeapon(app, wi, cur, new) catch continue;
                n += 1;
            }
        }
    }
    for (app.templates) |*t| if (t.weapon != null and std.ascii.eqlIgnoreCase(t.class, class) and std.ascii.eqlIgnoreCase(t.weapon.?, cur)) {
        t.weapon = try app.catalog.arena.allocator().dupe(u8, new);
        n += 1;
    };
    // The class page lists the new one.
    for (app.catalog.entries.items) |*e| if (e.kind == .enemy and std.ascii.eqlIgnoreCase(e.id, class)) {
        for (e.weapons.items) |*w| if (std.ascii.eqlIgnoreCase(w.*, cur)) {
            w.* = try app.catalog.arena.allocator().dupe(u8, new);
        };
    };
    return n;
}

/// `wp_x.ss` of `classes\\wp_x.ss`.
fn classFile(entry: []const u8) []const u8 {
    return entry[if (std.mem.lastIndexOfScalar(u8, entry, '\\')) |k| k + 1 else 0..];
}

/// `.wpn` file `wpn` includes class `new` instead of `cur` (one undo step).
pub fn swapWeapon(app: *App, wpn: usize, cur: []const u8, new: []const u8) !void {
    var ob: [96]u8 = undefined;
    var nb: [96]u8 = undefined;
    try app.store.replaceText(wpn, try std.fmt.bufPrint(&ob, "#include {s}", .{cur}), try std.fmt.bufPrint(&nb, "#include {s}", .{new}));
    // The enemy's files are read again (its weapon class changed).
    app.enemy_of = null;
}

/// Resistances of `name_id` from the exe table (read-only: the exe keys them by nameID).
pub fn resistBlock(name_id: i32, columns: usize) void {
    const immunity = og.battle.immunity;
    var flags: [8]bool = @splat(false);
    for (immunity.table) |e| if (e.id == name_id) {
        for (&flags, e.flags) |*f, x| f.* = x != 0;
    };
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fit() }, .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 4 }, .childGap = 8 } });
    txt(tx.get(tx.r_title), 13, theme.dim, font_mod.bold);
    txt(tx.get(tx.r_game), 12, theme.dim, font_mod.regular);
    clay.close();
    const names = [8]tx.Msg{ tx.p_fire, tx.p_elect, tx.r_decoy, tx.p_energy, tx.p_freeze, tx.p_tranq, tx.p_gas, tx.r_flammable };
    for (0..8 / columns) |row| {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(26) }, .padding = .{ .left = 12, .right = 8 }, .childGap = 4 } });
        for (row * columns..row * columns + columns) |i| {
            clay.open(.{
                .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(24) }, .padding = .{ .left = 6, .right = 6 }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
                .backgroundColor = theme.panel,
            });
            clay.leaf(.{
                .layout = .{ .sizing = .{ .width = clay.fixed(14), .height = clay.fixed(14) } },
                .backgroundColor = if (flags[i]) theme.row_selected else theme.bg,
                .border = .{ .color = theme.dim, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } },
            });
            txt(tx.get(names[i])[std.mem.indexOf(u8, tx.get(names[i]), ": ").? + 2 ..], 13, if (flags[i]) theme.text else theme.dim, font_mod.regular);
            clay.close();
        }
        clay.close();
    }
}

/// The weapons an enemy class's fighters hold (`wp_*.ss`), with their damage.
pub fn weaponBlock(app: *App, a: Allocator, e: Entry) void {
    var weapons = e.weapons.items;
    // A copy not placed in a battle yet: its base class's.
    if (weapons.len == 0) if (e.base) |b| for (app.catalog.entries.items) |x| {
        if (x.kind == .enemy and std.ascii.eqlIgnoreCase(x.id, b)) weapons = x.weapons.items;
    };
    // No fighter of it in the game's battles (shogoth): the attack the editor gives it.
    var built = false;
    if (weapons.len == 0) for (app.templates) |t| if (t.weapon) |w| if (std.ascii.eqlIgnoreCase(t.class, e.base orelse e.id)) {
        weapons = a.dupe([]const u8, &.{w}) catch weapons;
        built = true;
    };
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fit() }, .padding = .{ .left = 12, .right = 12, .top = 12, .bottom = 4 }, .childGap = 8 } });
    txt(tx.get(tx.wp_title), 13, theme.dim, font_mod.bold);
    txt(tx.get(if (built) tx.wp_built else tx.wp_hint), 12, if (built) theme.warn else theme.dim, font_mod.regular);
    clay.close();
    if (weapons.len == 0) {
        clay.open(.{ .layout = .{ .padding = .{ .left = 12 } } });
        txt(tx.get(tx.wp_none), 13, theme.dim, font_mod.regular);
        clay.close();
    }
    for (weapons, 0..) |w, k| {
        var buf: [128]u8 = undefined;
        const f = app.store.file(common_archive, std.fmt.bufPrint(&buf, "classes\\{s}", .{w}) catch continue) catch continue;
        const t = app.store.text(f);
        const long = (vars.get(t, "longAttack") orelse 0) != 0;
        const label = std.fmt.allocPrint(a, "{s} · {s} · {s}", .{ w[0 .. w.len - 3], tx.get(if (long) tx.wp_long else tx.wp_short), classLabel(a, vars.get(t, "classType")) }) catch w;
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(28) }, .padding = .{ .left = 12, .right = 12 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(380) } } });
        txt(label, 13, theme.text, font_mod.regular);
        clay.close();
        main.valueCell(app, a, @intCast(2100 + k), f, &.{"max_damage"}, null, vars.get(t, "max_damage"), true, false);
        clay.close();
        clay.open(.{ .layout = .{ .padding = .{ .left = 24 } } });
        txt(tx.alloc(a, tx.wp_tick, .{@as(i32, @intFromFloat(vars.get(t, "attackEffectDelay") orelse 15))}), 12, theme.dim, font_mod.regular);
        clay.close();
        reachToggle(app, a, @intCast(k), vars.get(t, "classType"));
        // Picker keys apart from the battle's `.wpn` Store indices.
        if (weaponPicker(app, a, (1 << 30) + k, w, long, tx.wp_change_class)) |new| {
            if (swapClassWeapon(app, e.base orelse e.id, w, new)) |n| app.setStatus(tx.st_weapon_class, .{ w, new, n }) else |err| app.setStatus(tx.st_set_failed, .{err});
        }
    }
}

/// An enemy weapon's reach map, shown on a click (one at a time).
fn reachToggle(app: *App, a: Allocator, k: u32, class: ?f32) void {
    const open = app.reach_open != null and app.reach_open.? == k;
    const rid = clay.idi("reach_t", k);
    clay.open(.{ .id = rid, .layout = .{ .padding = .{ .left = 24, .top = 2, .bottom = 2 } } });
    if (clay.hovered() and app.clicked) app.reach_open = if (open) null else k;
    txt(tx.get(if (open) tx.reach_hide else tx.reach_show), 12, if (clay.pointerOver(rid)) theme.text else theme.accent_hover, font_mod.regular);
    clay.close();
    if (open) reachMap(a, class, k + 1);
}

/// The damage zone of weapon class `class_f`, from the exe's patterns (zone.zig): the
/// tiles around the shooter with the damage percent at each (outlined: a ray's first
/// tile; the others are cut by an obstacle before them), a wide ray's second tiles, and
/// the tiles each hit covers around the target. `id` tells several maps apart.
pub fn reachMap(a: Allocator, class_f: ?f32, id: u32) void {
    const class: i32 = @intFromFloat(class_f orelse 0);
    main.panelHeader(tx.alloc(a, tx.reach_title, .{classLabel(a, class_f)}));
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 }, .childGap = 8 } });
    defer clay.close();
    const w = og.battle.patterns.find(class) orelse return txt(tx.get(tx.reach_none), 12, theme.dim, font_mod.regular);
    switch (og.battle.weapon_class.WeaponClass.from(class)) {
        .satellite => txt(tx.get(tx.reach_satellite), 12, theme.text, font_mod.regular),
        .time_bomb => txt(tx.get(tx.reach_bomb), 12, theme.text, font_mod.regular),
        else => {},
    }
    const z = zone.build(a, w) catch return;
    var sets: usize = 0;
    for (z.used) |u| sets += @intFromBool(u);
    if (z.cells.count() > 0) {
        clay.text(tx.alloc(a, tx.reach_hint, .{ if (w.wide) tx.get(tx.reach_wide) else "", if (sets > 1) tx.get(tx.reach_sets) else "" }), .{ .textColor = theme.dim, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
        clay.open(.{ .id = clay.idi("reach", id * 8), .layout = .{ .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 1 } });
        var y = z.lo[1];
        while (y <= z.hi[1]) : (y += 1) {
            clay.open(.{ .layout = .{ .childGap = 1 } });
            var x = z.lo[0];
            while (x <= z.hi[0]) : (x += 1) {
                if (x >= 0 and y >= 0 and x < z.size and y < z.size) {
                    cellBox(shooter_col, false, "", "");
                    continue;
                }
                const v = z.cells.get(.{ x, y }) orelse {
                    cellBox(theme.viewport, false, "", "");
                    continue;
                };
                const shade = 90 + @as(f32, @floatFromInt(v.pct)) * 1.2;
                const bg: clay.Color = if (v.side) .{ .r = 40, .g = shade * 0.6, .b = 60, .a = 255 } else .{ .r = 40, .g = shade, .b = 70, .a = 255 };
                cellBox(bg, !v.chain and !v.side, std.fmt.allocPrint(a, "{d}", .{v.pct}) catch "", if (sets > 1) std.fmt.allocPrint(a, "{d}", .{v.effect + 1}) catch "" else "");
            }
            clay.close();
        }
        clay.close();
    }
    // The hit sets the rays use (satellite: none, its one set).
    clay.open(.{ .layout = .{ .childGap = 16 } });
    for (w.effects, 0..) |eff, k| {
        if (eff.len == 0 or (z.cells.count() > 0 and !z.used[k])) continue;
        clay.open(.{ .layout = .{ .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 4 } });
        if (eff.len == 1 and eff[0][0] == 0 and eff[0][1] == 0) {
            txt(tx.alloc(a, tx.reach_single, .{k + 1}), 12, theme.dim, font_mod.regular);
            clay.close();
            continue;
        }
        txt(tx.alloc(a, tx.reach_area, .{ k + 1, eff.len }), 12, theme.dim, font_mod.regular);
        const b = zone.setBounds(eff);
        clay.open(.{ .id = clay.idi("reach", id * 8 + 1 + @as(u32, @intCast(k))), .layout = .{ .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 1 } });
        var y = b[0][1];
        while (y <= b[1][1]) : (y += 1) {
            clay.open(.{ .layout = .{ .childGap = 1 } });
            var x = b[0][0];
            while (x <= b[1][0]) : (x += 1) {
                const hit = for (eff) |d| {
                    if (d[0] == x and d[1] == y) break true;
                } else false;
                cellBox(if (x == 0 and y == 0) target_col else if (hit) hit_col else theme.viewport, false, "", "");
            }
            clay.close();
        }
        clay.close();
        clay.close();
    }
    clay.close();
    legend();
}

const shooter_col: clay.Color = .{ .r = 70, .g = 140, .b = 255, .a = 255 };
const target_col: clay.Color = .{ .r = 200, .g = 60, .b = 60, .a = 255 };
const hit_col: clay.Color = .{ .r = 210, .g = 130, .b = 50, .a = 255 };

/// A tile of a zone map: `pct` over `set` (either may be empty); `edge` outlines it.
fn cellBox(bg: clay.Color, edge: bool, pct: []const u8, set: []const u8) void {
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.fixed(32), .height = clay.fixed(32) }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = bg,
        .border = if (edge) .{ .color = theme.text, .width = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 } } else .{},
    });
    if (pct.len > 0) txt(pct, 10, theme.text, font_mod.regular);
    if (set.len > 0) txt(set, 9, theme.warn, font_mod.regular);
    clay.close();
}

/// What the colours of the zone maps mean.
fn legend() void {
    const items = [_]struct { clay.Color, bool, tx.Msg }{
        .{ shooter_col, false, tx.zl_shooter },                             .{ .{ .r = 40, .g = 210, .b = 70, .a = 255 }, true, tx.zl_start },
        .{ .{ .r = 40, .g = 180, .b = 70, .a = 255 }, false, tx.zl_chain }, .{ .{ .r = 40, .g = 126, .b = 60, .a = 255 }, false, tx.zl_side },
        .{ target_col, false, tx.zl_target },                               .{ hit_col, false, tx.zl_hit },
    };
    // One column: the enemy page shows it in its narrow values column too.
    for (items) |it| {
        clay.open(.{ .layout = .{ .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(14), .height = clay.fixed(14) } }, .backgroundColor = it[0], .border = if (it[1]) .{ .color = theme.text, .width = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 } } else .{} });
        txt(tx.get(it[2]), 12, theme.dim, font_mod.regular);
        clay.close();
    }
}

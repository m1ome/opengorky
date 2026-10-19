//! Console commands for heroes: items, experience, health, ammo, selection.

const std = @import("std");
const fields = @import("../fields.zig");
const game = @import("../game.zig");
const control = @import("../combat.zig").control;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const rules = @import("../battle.zig").rules;
const inventory = @import("../inventory.zig");
const common = @import("common.zig");
const Cmd = common.Cmd;
const Effect = common.Effect;

pub fn run(c: Cmd, w: *World, _: []const u8, it: *common.Args, out: *std.Io.Writer) !Effect {
    const eq = std.ascii.eqlIgnoreCase;
    switch (c) {
        .give => {
            const cls = it.next() orelse return common.usage(out, "give <class.s> [count] [hero]");
            var count: ?i32 = null;
            var hero_name: []const u8 = w.selected_hero;
            while (it.next()) |a| {
                if (std.fmt.parseInt(i32, a, 10)) |n| count = n else |_| hero_name = a;
            }
            const hero = w.actorObject(hero_name) orelse return common.say(out, "no hero {s}\n", .{hero_name});
            const file = if (std.mem.endsWith(u8, cls, ".s")) cls else try std.fmt.allocPrint(w.arena_state.allocator(), "{s}.s", .{cls});
            const o = (try inventory.create.giveItem(w, file, hero.name, count)) orelse return common.say(out, "cannot create {s}\n", .{file});
            try out.print("{s} -> {s} ({s}, counter {d})\n", .{ file, hero.name, o.name, fields.counter(o) });
        },
        .godmode => {
            w.debug.god = !w.debug.god;
            try out.print("godmode {s}\n", .{if (w.debug.god) "on" else "off"});
        },
        .levelup => {
            // levelup [hero] [n]: a number without a name levels the selected hero.
            var hero_name: []const u8 = w.selected_hero;
            var n: i32 = 1;
            while (it.next()) |a| {
                if (std.fmt.parseInt(i32, a, 10)) |v| n = v else |_| hero_name = a;
            }
            const hero = w.actorObject(hero_name) orelse return common.say(out, "no hero\n", .{});
            const level = hero.getInt("level") + n;
            hero.setInt("level", level);
            fields.setExperience(hero, rules.levelThreshold(level));
            World.nativeOf(hero).growth.stat_points += 5 * n;
            try out.print("{s}: level {d}, points {d}\n", .{ hero.name, level, World.nativeOf(hero).growth.stat_points });
        },
        .exp => {
            // exp [hero] [n]: without a number — the current level threshold, the next hit levels up.
            var hero_name: []const u8 = w.selected_hero;
            var v: ?i32 = null;
            while (it.next()) |a| {
                if (std.fmt.parseInt(i32, a, 10)) |x| v = x else |_| hero_name = a;
            }
            const hero = w.actorObject(hero_name) orelse return common.say(out, "no hero\n", .{});
            fields.setExperience(hero, v orelse rules.levelThreshold(hero.getInt("level")));
            try out.print("{s}: experience {d}\n", .{ hero.name, fields.experience(hero) });
        },
        .heal => {
            const only = it.next();
            healHeroes(w, only);
            for (w.rt.objects.items) |o| if (world_mod.isHeroActor(o)) if (only == null or eq(only.?, o.name))
                try out.print("{s}: hp {d}\n", .{ o.name, fields.hp(o) });
        },
        .ammo => {
            const n = std.fmt.parseInt(i32, it.next() orelse "30", 10) catch 30;
            const at_least = if (it.next()) |a| eq(a, "min") else false;
            try out.print("+{d} rounds in {d} stacks\n", .{ n, addAmmo(w, n, at_least) });
        },
        .skills => {
            const hero = w.actorObject(it.next() orelse w.selected_hero) orelse return common.say(out, "no hero\n", .{});
            for (World.nativeOf(hero).growth.skills.items) |sk| {
                try out.print("{s}: weapon {d} level {d} uses {d} ({s})\n", .{ hero.name, sk.id, sk.level, sk.count, w.stringOr(sk.id, "?") });
            }
        },
        .hero => {
            const hero = w.actorObject(it.next() orelse "") orelse return common.say(out, "no such hero\n", .{});
            game.selectHero(w, hero.name);
            try out.print("selected {s}\n", .{w.selected_hero});
        },
        .items => {
            const hero = w.actorObject(it.next() orelse w.selected_hero) orelse return common.say(out, "no hero\n", .{});
            for (w.rt.objects.items) |o| {
                if (!world_mod.isItem(o)) continue;
                if (!eq(fields.owner(o), hero.name)) continue;
                try out.print("{s} ({s}) place {d} counter {d}\n", .{ o.name, o.class.name, o.getInt("place"), fields.counter(o) });
            }
        },
        .equip => {
            const o = w.rt.findObject(it.next() orelse "") orelse return common.say(out, "no such item\n", .{});
            const hero = w.actorObject(fields.owner(o)) orelse return common.say(out, "item has no hero owner\n", .{});
            if (!inventory.equipment.canEquip(o)) return common.say(out, "cannot equip {s}\n", .{o.name});
            inventory.equipment.equip(w, hero, o);
            if (w.battle) |*b| if (b.fighterOf(hero)) |i| if (World.nativeOf(o).kind == .weapon) {
                b.fighters.items[i].weapon = o;
                control.refreshSelection(b, w);
            };
            try out.print("{s} equips {s}\n", .{ hero.name, o.name });
        },
        .pick => {
            // pick <item>: into the owner's hand and "Use/Heal … on …" mode, like choosing
            // in the quick list (0x4b0f90).
            const o = w.rt.findObject(it.next() orelse "") orelse return common.say(out, "no such item\n", .{});
            const hero = w.actorObject(fields.owner(o)) orelse return common.say(out, "item has no hero owner\n", .{});
            inventory.equipment.toHand(w, hero, o);
            w.mouse.use = o;
            if (w.battle) |*b| control.refreshSelection(b, w);
            try out.print("{s} picks {s}\n", .{ hero.name, o.name });
        },
        else => unreachable,
    }
    return .none;
}

/// Full health for party heroes (all, or the one named `only`).
pub fn healHeroes(w: *World, only: ?[]const u8) void {
    for (w.rt.objects.items) |o| {
        if (!world_mod.isHeroActor(o)) continue;
        if (only) |name| if (!std.ascii.eqlIgnoreCase(name, o.name)) continue;
        fields.setHp(o, fields.maxHp(o));
    }
}

/// `n` rounds to every hero-owned ammo stack (`at_least`: raise to at least `n`); returns
/// the number of stacks.
pub fn addAmmo(w: *World, n: i32, at_least: bool) usize {
    var stacks: usize = 0;
    for (w.rt.objects.items) |o| {
        const nat = World.nativeOf(o);
        if (nat.kind != .item or nat.deleted or inventory.item.typeOf(o) != .ammo) continue;
        const owner = w.rt.findObject(fields.owner(o)) orelse continue;
        if (!World.nativeOf(owner).hero) continue;
        fields.setCounter(o, if (at_least) @max(fields.counter(o), n) else fields.counter(o) + n);
        stacks += 1;
    }
    return stacks;
}

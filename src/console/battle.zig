//! Console commands for battles: fighters, attacks, hazards, devices, turn control.

const std = @import("std");
const fields = @import("../fields.zig");
const game = @import("../game.zig");
const control = @import("../combat.zig").control;
const debug = @import("../combat.zig").debug;
const devices = @import("../combat.zig").devices;
const states = @import("../combat.zig").states;
const turns_mod = @import("../combat.zig").turns;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const rules = @import("../battle.zig").rules;
const inventory = @import("../inventory.zig");
const fx = @import("../fx.zig");
const ai = @import("../combat.zig").ai;
const common = @import("common.zig");
const Cmd = common.Cmd;
const Effect = common.Effect;

pub fn run(c: Cmd, w: *World, cmd: []const u8, it: *common.Args, out: *std.Io.Writer) !Effect {
    const eq = std.ascii.eqlIgnoreCase;
    switch (c) {
        .fighters => {
            const b = &(w.battle orelse return common.say(out, "not in a battle\n", .{}));
            try out.print("phase {t} pending {t} over {d} tick {d}\n", .{ b.phase, b.pending, b.over_ticks, w.ticks });
            for (b.fighters.items) |f| {
                const p = w.screenPos(f.obj);
                try out.print("{s} {t} tile {d},{d} bg {d:.0},{d:.0} id {d} hp {d} rage {d} sleep {d} burn {d} gas {d} frozen {d} weapon {s} recharge {d} acted {} stance {d} detached {}\n", .{ f.obj.name, f.side, f.tile[0], f.tile[1], p[0], p[1], fields.nameId(f.obj), f.hp(), f.berserk, f.asleep, f.burning, f.gassed, f.frozen, if (f.weapon) |wp| wp.name else "-", if (f.weapon) |wp| World.nativeOf(wp).fight.recharge else 0, f.acted, world_mod.actorOf(f.obj).state, world_mod.actorOf(f.obj).weapon_detached });
            }
        },
        .put => {
            // put <fighter> x y: move a fighter to a battle cell.
            const b = &(w.battle orelse return common.say(out, "not in a battle\n", .{}));
            const o = w.actorObject(it.next() orelse "") orelse return common.usage(out, "put <fighter> x y");
            const x = std.fmt.parseInt(i32, it.next() orelse "", 10) catch return common.usage(out, "put <fighter> x y");
            const y = std.fmt.parseInt(i32, it.next() orelse "", 10) catch return common.usage(out, "put <fighter> x y");
            try out.print("{s} -> {d},{d}: {s}\n", .{ o.name, x, y, if (debug.debugPut(b, w, o, .{ x, y })) "ok" else "occupied" });
        },
        .spawn => {
            // spawn <file.ftr> x y: put your own fighter into the battle (mods).
            if (w.battle == null) return common.say(out, "not in a battle\n", .{});
            const file = it.next() orelse return common.usage(out, "spawn <file.ftr> x y");
            const x = std.fmt.parseInt(i32, it.next() orelse "", 10) catch return common.usage(out, "spawn <file.ftr> x y");
            const y = std.fmt.parseInt(i32, it.next() orelse "", 10) catch return common.usage(out, "spawn <file.ftr> x y");
            if (try debug.spawnFile(w, file, .{ x, y })) |o| {
                try out.print("{s} -> {d},{d}\n", .{ o.name, x, y });
            } else try out.print("cannot spawn {s} at {d},{d}\n", .{ file, x, y });
        },
        .plan => {
            // plan <fighter>: what the AI would pick (weapon, aim, score, path).
            const b = &(w.battle orelse return common.say(out, "not in a battle\n", .{}));
            const o = w.actorObject(it.next() orelse "") orelse return common.usage(out, "plan <fighter>");
            const who = b.fighterOf(o) orelse return common.say(out, "not a fighter\n", .{});
            const p = try ai.plan(b, w, who);
            try out.print("{s}: score {d}, weapon {s}", .{ o.name, p.score, if (p.weapon) |wp| wp.name else "-" });
            if (p.weapon != null) try out.print(" at {d},{d} from step {d}", .{ p.aim.tile[0], p.aim.tile[1], p.attack_at.? });
            try out.print(", path", .{});
            for (p.path[0..p.len]) |t| try out.print(" {d},{d}", .{ t[0], t[1] });
            try out.print("\n", .{});
        },
        .medicine => {
            const item = w.rt.findObject(it.next() orelse "") orelse return common.usage(out, "medicine <item> <hero>");
            const to = w.actorObject(it.next() orelse "") orelse return common.usage(out, "medicine <item> <hero>");
            const from = w.selectedHero() orelse return common.say(out, "no selected hero\n", .{});
            const hp = fields.hp(to);
            if (w.battle) |*b| {
                if (!try debug.debugMedicine(b, w, from, item, to)) return common.say(out, "cannot use ({t}, {t})\n", .{ b.pending, b.phase });
                const f = b.fighters.items[b.fighterOf(to).?];
                try out.print("{s} -> {s}: hp {d} -> {d}, rage {d}, sleep {d}, gas {d}, acted {}\n", .{ item.name, to.name, hp, fields.hp(to), f.berserk, f.asleep, f.gassed, f.acted });
            } else {
                try inventory.medicine.healWith(w, from, to, item);
                try out.print("{s} -> {s}: hp {d} -> {d}\n", .{ item.name, to.name, hp, fields.hp(to) });
            }
        },
        .popups => {
            const b = &(w.battle orelse return common.say(out, "not in a battle\n", .{}));
            try out.print("popups {d}\n", .{b.popups.items.len});
            for (b.popups.items) |*pp| try out.print("popup \"{s}\" delay {d} state {d} v {d:.2} dy {d:.0}\n", .{ pp.text(), pp.delay, pp.state, pp.v, pp.dy });
        },
        .win => {
            const b = &(w.battle orelse return common.say(out, "not in a battle\n", .{}));
            try debug.debugWin(b, w);
            try out.print("enemies killed\n", .{});
        },
        .lose => {
            const b = &(w.battle orelse return common.say(out, "not in a battle\n", .{}));
            for (b.fighters.items) |*f| {
                if (f.side != .hero or !f.alive()) continue;
                fields.setHp(f.obj, 0);
                f.dead = true;
                // Like a battle death: death animation, then the corpse fades.
                const a = world_mod.actorOf(f.obj);
                a.play(a.resolve("death"), false, true);
                a.hold_last = true;
                a.startCorpseFade();
            }
            try out.print("heroes killed\n", .{});
        },
        .launch => {
            const cm = w.combat_map orelse return common.say(out, "no battle\n", .{});
            const id = std.fmt.parseInt(i32, it.next() orelse "", 10) catch return common.usage(out, "launch <weaponID> x y");
            const x = std.fmt.parseInt(i32, it.next() orelse "", 10) catch return common.usage(out, "launch <weaponID> x y");
            const y = std.fmt.parseInt(i32, it.next() orelse "", 10) catch return common.usage(out, "launch <weaponID> x y");
            const hero = w.selectedHero() orelse return common.say(out, "no hero\n", .{});
            const n = fx.launch.launchId(w, hero, id, cm.tileCenter(.{ x, y }, 1), false);
            try out.print("projectile {d}\n", .{n});
        },
        .hitfx => {
            const cm = w.combat_map orelse return common.say(out, "no battle\n", .{});
            const id = std.fmt.parseInt(i32, it.next() orelse "", 10) catch return common.usage(out, "hitfx <weaponID> x y [attacker]");
            const x = std.fmt.parseInt(i32, it.next() orelse "", 10) catch return common.usage(out, "hitfx <weaponID> x y [attacker]");
            const y = std.fmt.parseInt(i32, it.next() orelse "", 10) catch return common.usage(out, "hitfx <weaponID> x y [attacker]");
            const at = cm.tileCenter(.{ x, y }, 1);
            // Optional 4th argument: the attacking object (monster effects).
            if (it.next()) |by| {
                const o = w.rt.findObject(by) orelse return common.say(out, "no object\n", .{});
                fx.hits.preFlash(w, o, id, at);
                fx.hits.onHitAs(w, o, id, at, false);
            } else {
                const hero = w.selectedHero() orelse return common.say(out, "no hero\n", .{});
                // The ion rifle beam and blaster stream set the callback before the hit.
                fx.hits.preFlash(w, hero, id, at);
                fx.hits.onHitId(w, hero, id, at);
            }
            try out.print("hit fx {d}\n", .{id});
        },
        .explode => {
            const b = &(w.battle orelse return common.say(out, "no battle\n", .{}));
            const o = w.rt.findObject(it.next() orelse "") orelse return common.say(out, "no object\n", .{});
            const i = b.fighterOf(o) orelse return common.say(out, "not a fighter\n", .{});
            if (!b.fighters.items[i].explosive) return common.say(out, "not explosive\n", .{});
            try devices.destroyBarrel(b, w, i);
            if (b.pending == .none) b.pending = .settle;
            try out.print("{s} explodes\n", .{o.name});
        },
        .push => {
            const b = &(w.battle orelse return common.say(out, "no battle\n", .{}));
            const x = std.fmt.parseInt(i32, it.next() orelse "", 10) catch return common.usage(out, "push x y");
            const y = std.fmt.parseInt(i32, it.next() orelse "", 10) catch return common.usage(out, "push x y");
            try out.print("{s}\n", .{if (try devices.push(b, w, .{ x, y })) "pushing" else "cannot push"});
        },
        .targets => {
            const b = &(w.battle orelse return common.say(out, "no battle\n", .{}));
            for (control.targetList(b)) |t| try out.print("{d},{d} ", .{ t.tile[0], t.tile[1] });
            try out.print("\n", .{});
        },
        .tile => {
            const b = &(w.battle orelse return common.say(out, "no battle\n", .{}));
            const x = std.fmt.parseInt(i32, it.next() orelse "", 10) catch return common.usage(out, "tile x y");
            const y = std.fmt.parseInt(i32, it.next() orelse "", 10) catch return common.usage(out, "tile x y");
            try control.clickTileMode(b, w, .{ x, y }, w.mouse.aim);
            try out.print("click tile {d},{d}\n", .{ x, y });
        },
        .aim => {
            // Aim mode (right button in battle): the host turns it on by the flag.
            if (w.battle == null) return common.say(out, "no battle\n", .{});
            w.mouse.aim = !w.mouse.aim;
            try out.print("aim {s}\n", .{if (w.mouse.aim) "on" else "off"});
        },
        .attack => {
            const b = &(w.battle orelse return common.say(out, "no battle\n", .{}));
            const hero = w.actorObject(it.next() orelse "") orelse return common.usage(out, "attack <hero> <weapon> [target]");
            const wname = it.next() orelse return common.usage(out, "attack <hero> <weapon> [target]");
            const wpn = w.rt.findObject(wname) orelse blk: {
                const file = if (std.mem.endsWith(u8, wname, ".s")) wname else try std.fmt.allocPrint(w.arena_state.allocator(), "{s}.s", .{wname});
                break :blk (try inventory.create.giveItem(w, file, hero.name, null)) orelse return common.say(out, "cannot create {s}\n", .{file});
            };
            const target = if (it.next()) |tn| (w.actorObject(tn) orelse return common.say(out, "no target {s}\n", .{tn})) else null;
            // `here` after the target — strike from the own cell without moving the hero.
            const here = if (it.next()) |h| std.mem.eql(u8, h, "here") else false;
            if (!try debug.debugAttack(b, w, hero, wpn, target, here)) return common.say(out, "cannot attack\n", .{});
            try out.print("{s} attacks with {s}\n", .{ hero.name, wpn.name });
        },
        .endturn => {
            const b = &(w.battle orelse return common.say(out, "no battle\n", .{}));
            const before = b.phase;
            try turns_mod.endTurn(b, w);
            try out.print("turn ended (phase {t} -> {t}, turn {d})\n", .{ before, b.phase, b.turn });
        },
        .auto => {
            const b = &(w.battle orelse return common.say(out, "no battle\n", .{}));
            b.auto_heroes = !b.auto_heroes;
            try out.print("auto heroes {s}\n", .{if (b.auto_heroes) "on" else "off"});
        },
        .defend => {
            // defend [hero]: defend (X key, 0x48f7e0) of the selected or named hero.
            const b = &(w.battle orelse return common.say(out, "not in battle\n", .{}));
            if (it.next()) |name| {
                const hero = w.actorObject(name) orelse return common.say(out, "no such hero\n", .{});
                game.selectHero(w, hero.name);
            }
            control.defend(b, w);
            try out.print("defend {s}\n", .{w.selected_hero});
        },
        .state => {
            // Debug: apply a state to a fighter, like a hit (0x4900f0).
            const b = &(w.battle orelse return common.say(out, "not in a battle\n", .{}));
            const o = w.rt.findObject(it.next() orelse "") orelse return common.usage(out, "state <fighter> sleep|freeze|gas|burn");
            const i = b.fighterOf(o) orelse return common.say(out, "not a fighter\n", .{});
            const st = it.next() orelse "";
            const kind: rules.Effect = if (eq(st, "sleep")) .sleep else if (eq(st, "freeze")) .freeze else if (eq(st, "gas")) .gas else if (eq(st, "burn")) .burn else return common.usage(out, "state <fighter> sleep|freeze|gas|burn");
            states.applyEffect(b, w, &b.fighters.items[i], kind);
            try out.print("{s}: {s}\n", .{ o.name, st });
        },
        .fire, .gas => {
            const b = &(w.battle orelse return common.say(out, "not in a battle\n", .{}));
            const x = std.fmt.parseInt(i32, it.next() orelse "", 10) catch return common.usage(out, "fire <x> <y> [turns]");
            const y = std.fmt.parseInt(i32, it.next() orelse "", 10) catch return common.usage(out, "fire <x> <y> [turns]");
            const default: u8 = if (eq(cmd, "fire")) 3 else 1;
            const n = std.fmt.parseInt(u8, it.next() orelse "", 10) catch default;
            states.setHazard(b, if (eq(cmd, "fire")) b.fire else b.gas, .{ x, y }, n);
            try out.print("{s} at {d},{d} for {d}\n", .{ cmd, x, y, n });
        },
        else => unreachable,
    }
    return .none;
}

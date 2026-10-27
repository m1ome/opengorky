//! Debug console: technical commands for testing the game (viewer — the
//! ` or F2 key, playthrough — `cmd:…`). Commands work on the current level's
//! world; output goes to `out` as lines.

const std = @import("std");
const World = @import("state.zig").world.World;
const common = @import("console/common.zig");
const battle = @import("console/battle.zig");
pub const hero = @import("console/hero.zig");
const world = @import("console/world.zig");

const help_text =
    \\help                          this list
    \\give <class.s> [count] [hero] new item from common\classes (cw_* = weapon)
    \\godmode                       heroes take no damage (toggle)
    \\levelup [hero] [n]            raise level by n (+5 points per level)
    \\exp [hero] [n]                set experience (default: level threshold, next hit levels up)
    \\popups                        battle popups: text, delay, phase, alpha
    \\heal [hero]                   full health (all heroes by default)
    \\ammo [n] [min]                +n (30) rounds to every hero ammo stack; `min`: at least n
    \\win / lose                    end the battle
    \\level <name>                  go to a location
    \\auto                          battle: heroes play by AI (toggle)
    \\skip                          skip the current scene line (Space)
    \\skipscene                     skip the whole scene (Esc), unless NO_SKIP
    \\tile x y                      battle: click a tile (select, walk; attack with `aim`)
    \\targets                       battle: aim tiles of the selected hero
    \\explode <barrel>              battle: blow up a barrel (chain, 8 neighbours)
    \\push x y                      battle: selected hero pushes the obstacle at a tile
    \\wait <ticks>                  run world ticks (console scripts in --shot)
    \\launch <weaponID> x y         battle: projectile from the selected hero to a tile
    \\hitfx <weaponID> x y          battle: hit effects of a weapon at a tile (no damage)
    \\skills [hero]                 weapon skills: weapon nameID, level, uses
    \\call <obj> <func> [args...]   call a script function (args: numbers or strings)
    \\scene <name>                  play a cutscene (common\scriptlets\<name>.scr)
    \\playscene <name>              the level's own start scene dropped, then <name> (debugging a scene)
    \\hero <name>                   select a hero
    \\click <x> <y>                 click the background point like the player (walk, areas)
    \\get <object> <var>            script variable
    \\set <object> <var> <value>    set a script variable
    \\items [hero]                  hero's items
    \\equip <item>                  put on / take in hand (also in battle)
    \\fire <x> <y> [turns]          set fire on a battle tile (3)
    \\gas <x> <y> [turns]           set gas on a battle tile (1)
    \\where <object>                tile, background position, state, animation, pickable
    \\immunities                    reveal all monster immunities
    \\fighters                      battle fighters: tile, bg, nameID, hp
    \\medicine <item> <hero>        selected hero gives a medicine (battle: moved next to it)
    \\put <fighter> x y             battle: move a fighter to a free tile
    \\spawn <file.ftr> x y          battle: place an own fighter (mods)
    \\plan <fighter>                battle: what the AI would do (weapon, aim, score, path)
    \\map / whereami                current location, battle, scene, hero position
    \\endturn                       battle: end the turn (as E)
    \\aim                           battle: aim mode (right button, toggle)
    \\defend [hero]                 battle: defend (X)
    \\pick <item>                   in hand and Use/Heal mode, as the quick list
    \\state <fighter> sleep|freeze|gas|burn   battle: apply a state as a hit
    \\attack <hero> <weapon> [target]  battle: attack as in a turn (weapon: object or class.s,
    \\                              given if missing; hero moved to a tile in range)
    \\morph <obj> <class> <mesh>    actor morph (ACTOR_MORPH)
    \\fxstate <obj> shock|appear|vanish|alpha N   actor effect state
    \\clear / close                 clear / close the console (PgUp/PgDn, wheel - scroll)
;

/// Command result the host must carry out.
pub const Effect = common.Effect;

/// Runs one console line; each command group lives in console/<group>.zig.
pub fn run(w: *World, line: []const u8, out: *std.Io.Writer) !Effect {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const cmd = it.next() orelse return .none;
    var lower: [16]u8 = undefined;
    const known = if (cmd.len <= lower.len) std.meta.stringToEnum(common.Cmd, std.ascii.lowerString(&lower, cmd)) else null;
    const c = known orelse return common.say(out, "unknown command {s} (try help)\n", .{cmd});
    return switch (c) {
        .help => common.say(out, help_text, .{}),
        .clear => .clear,
        .close => .close,
        .fighters, .put, .spawn, .plan, .medicine, .popups, .win, .lose, .launch, .hitfx, .explode, .push, .targets, .tile, .aim, .attack, .endturn, .auto, .defend, .state, .fire, .gas => battle.run(c, w, cmd, &it, out),
        .give, .godmode, .levelup, .exp, .heal, .ammo, .skills, .hero, .items, .equip, .pick => hero.run(c, w, cmd, &it, out),
        .map, .whereami, .level, .morph, .fxstate, .wait, .skipscene, .skip, .call, .scene, .playscene, .click, .get, .set, .where, .immunities => world.run(c, w, cmd, &it, out),
    };
}

test "every command has a help line" {
    for (std.meta.fieldNames(common.Cmd)) |name| {
        var found = false;
        var lines = std.mem.splitScalar(u8, help_text, '\n');
        while (lines.next()) |l| {
            const col = l[0 .. std.mem.indexOf(u8, l, "  ") orelse l.len];
            var words = std.mem.tokenizeScalar(u8, col, ' ');
            while (words.next()) |word| found = found or std.mem.eql(u8, word, name);
        }
        if (!found) std.debug.panic("no help for {s}", .{name});
    }
}

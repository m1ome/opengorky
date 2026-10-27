//! Integration tests of `Game`: level switch, cache, battle, save/load, scenes, on the
//! hand-written fixture data (`fixture.zig`).

const std = @import("std");
const fields = @import("../fields.zig");
const game = @import("../game.zig");
const Game = game.Game;
const save_mod = @import("../save.zig");
const scenes = @import("../scene.zig").scenes;
const crt_rand = @import("../crt_rand.zig");
const battle_tick = @import("../combat.zig").tick;
const immunity = @import("../battle.zig").immunity;
const items = @import("../inventory.zig");
const fixture = @import("fixture.zig");

const TestGame = struct {
    tmp: std.testing.TmpDir,
    game: Game,

    /// 01_a ↔ 01_b (plain) and 01__fight (combat, no grid); hero Sullivan.
    fn init(self: *TestGame) !void {
        self.tmp = std.testing.tmpDir(.{ .iterate = true });
        const d = self.tmp.dir;
        try fixture.writeCommon(d);
        try fixture.writeLevel(d, "01_a",
            \\int order; int visits; int mark; int nameID; string lastBattle;
            \\function init() { order = order * 10 + 1; };
            \\function restore() { order = order * 10 + 2; visits = visits + 1; };
            \\function AfterBattle(string s) { lastBattle = s; };
            \\function go() { LEVEL_Load("01_b"); FadeIn(); };
            \\function goTwice() { LEVEL_Load("01_b"); LEVEL_Load("01_a"); FadeIn(); };
        );
        try fixture.writeLevel(d, "01_b", "int visits;\nfunction restore() { visits = visits + 1; };");
        try fixture.writeLevel(d, "01__fight", "#inherit combatlevel\n");
        self.game = .{ .io = std.testing.io, .gpa = std.testing.allocator, .dat = d, .models = null };
        _ = try self.game.open("01_a", .{ .hero = "Sullivan" }, null);
    }

    fn deinit(self: *TestGame) void {
        self.game.deinit();
        self.tmp.cleanup();
    }

    fn go(self: *TestGame, name: []const u8) !Game.Switch {
        const sw = try self.game.switchTo(name);
        try self.game.finish(sw);
        return sw;
    }

    fn level(self: *TestGame) *@import("../script.zig").object.Object {
        return self.game.world.?.level.?;
    }

    fn hero(self: *TestGame) *@import("../script.zig").object.Object {
        return self.game.world.?.actorObject("Sullivan").?;
    }
};

test "create: level init() before restore()" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    try std.testing.expectEqual(12, t.level().getInt("order"));
    try std.testing.expectEqualStrings("Sullivan", t.game.world.?.selected_hero);
}

test "switchTo/finish: there and back through the world cache" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const a = t.game.world.?;
    t.level().setInt("mark", 7);
    var sw = try t.go("01_b");
    try std.testing.expect(!sw.restored and !sw.destroyed);
    try std.testing.expectEqualStrings("01_b", t.game.world.?.level_name);
    try std.testing.expectEqualStrings("01_a", t.game.prev.?);
    try std.testing.expect(t.game.cache.get("01_a") == a);
    sw = try t.go("01_a");
    // Same world object, state kept, restore() called again (0x411cd0).
    try std.testing.expect(sw.restored);
    try std.testing.expect(t.game.world.? == a);
    try std.testing.expectEqual(7, t.level().getInt("mark"));
    try std.testing.expectEqual(2, t.level().getInt("visits"));
    try std.testing.expectEqualStrings("Sullivan", t.game.world.?.selected_hero);
    try std.testing.expect(t.game.cache.get("01_b") != null);
}

test "a joined hero is a hero-class object in a new location: HERO_EnableEnumerate takes him out (0x4c1970)" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    // Medusa joins in 01_m (SETHERO); 01_n is entered for the first time, so the party
    // creates her there. Its trigger is the observatory's crazy-Medusa one: she leaves the
    // party (HERO_EnableEnumerate 0) and GUI_IsHero must say so, or the scene and its
    // battle come again after the win.
    try fixture.writeArchive(t.tmp.dir, "01_m/other.dat", &.{
        .{ "01_m.lev", "" },
        .{ "Medusa.hro", "int nameID; int avoidEnumerate;" },
    });
    try fixture.writeArchive(t.tmp.dir, "01_m/sprite.dat", &.{});
    try fixture.writeLevel(t.tmp.dir, "01_n", "int was; int now;\nfunction leave() { was = GUI_IsHero(\"Medusa\"); HERO_EnableEnumerate(\"Medusa\",0); now = GUI_IsHero(\"Medusa\"); };");
    _ = try t.go("01_m");
    const m = t.game.world.?.actorObject("Medusa").?;
    @TypeOf(t.game.world.?.*).nativeOf(m).hero = true;
    _ = try t.go("01_n");
    _ = try t.game.world.?.rt.callIfExists(t.level(), "leave", &.{});
    try std.testing.expectEqual(1, t.level().getInt("was"));
    try std.testing.expectEqual(0, t.level().getInt("now"));
}

test "battle: not cached, AfterBattle on return, retry restores the entry party" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    fields.setHp(t.hero(), 50);
    _ = try t.go("01__fight");
    try std.testing.expect(t.game.world.?.isCombat());
    try std.testing.expect(t.game.entry_party != null);
    // Retry after a loss: the battle again with the party as it entered; immunities found
    // in the lost battle are forgotten (the exe reloads the "battle" save, 0x4542c0).
    fields.setHp(t.hero(), 1);
    _ = t.game.immunity.discover(immunity.table[0].id, .gas);
    _ = try t.game.retry();
    try std.testing.expectEqual(50, fields.hp(t.hero()));
    try std.testing.expect(!t.game.immunity.isKnown(immunity.table[0].id, .gas));
    // Victory: back to where the battle started (no backLevel → prev).
    try std.testing.expect(t.game.leaveBattle());
    const sw = try t.go(t.game.pendingLevel().?);
    try std.testing.expect(sw.destroyed and sw.restored and sw.after_battle);
    try std.testing.expectEqualStrings("01__fight", t.level().getString("lastBattle"));
    try std.testing.expect(t.game.cache.get("01__fight") == null);
}

test "battle save: game over outside battle re-enters the last battle as it was entered" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    try std.testing.expect(t.game.battle_save == null);
    t.level().setInt("mark", 7);
    fields.setHp(t.hero(), 50);
    const id = immunity.table[0].id;
    _ = t.game.immunity.discover(id, .fire);
    _ = try t.go("01__fight");
    try std.testing.expect(t.game.battle_save != null);
    _ = t.game.immunity.discover(id, .gas);
    try std.testing.expect(t.game.leaveBattle());
    _ = try t.go(t.game.pendingLevel().?);
    t.level().setInt("mark", 9);
    fields.setHp(t.hero(), 1);
    // GUI_GAMEOVER "Yes" (0x4542c0): the battle again, the rest as the save had it.
    const w = try t.game.reloadBattle();
    try std.testing.expect(w.isCombat());
    try std.testing.expectEqual(50, fields.hp(t.hero()));
    try std.testing.expect(t.game.prev == null);
    // Immunities as the battle was entered (table 0x6d2070 is in the save, 0x4722a5).
    try std.testing.expect(t.game.immunity.isKnown(id, .fire) and !t.game.immunity.isKnown(id, .gas));
    _ = try t.go("01_a");
    try std.testing.expectEqual(7, t.level().getInt("mark"));
}

test "snapshot + load: current and cached locations come back from the save" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    t.level().setInt("mark", 7);
    _ = try t.go("01_b");
    fields.setHp(t.hero(), 33);
    @TypeOf(t.game.world.?.*).nativeOf(t.hero()).actor.forced_idle = "medicine";
    var text: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer text.deinit();
    {
        var sv: save_mod.Save = .init(std.testing.allocator);
        defer sv.deinit();
        try t.game.snapshot(&sv);
        try sv.write(&text.writer);
    }
    const w = try t.game.load(try save_mod.Save.parse(std.testing.allocator, text.written()));
    try std.testing.expectEqualStrings("01_b", w.level_name);
    try std.testing.expectEqual(33, fields.hp(t.hero()));
    // idleAnimOverride (+0x30ed) is part of the actor's saved properties (0x46a691).
    try std.testing.expectEqualStrings("medicine", @TypeOf(w.*).nativeOf(t.hero()).actor.forced_idle.?);
    try std.testing.expect(t.game.cache.count() == 0 and t.game.prev == null);
    // 01_a was only in the cache: its saved state, not a fresh init().
    _ = try t.go("01_a");
    try std.testing.expectEqual(7, t.level().getInt("mark"));
    // A cut-off save never reaches the game.
    const cut = text.written()[0 .. text.written().len - 4];
    try std.testing.expectError(error.BadSave, save_mod.Save.parse(std.testing.allocator, cut));
}

test "deferred LEVEL_Load steps run on the new location; a LEVEL_Load among them defers the rest" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    // FadeIn after LEVEL_Load in the same call refers to the new location.
    _ = try t.game.world.?.rt.callIfExists(t.level(), "go", &.{});
    try std.testing.expectEqual(0, t.game.world.?.scene.fade);
    _ = try t.go(t.game.pendingLevel().?);
    try std.testing.expectEqualStrings("01_b", t.game.world.?.level_name);
    try std.testing.expectEqual(1, t.game.world.?.scene.fade);
    try std.testing.expect(t.game.world.?.flow.pending_level == null);
    // Back, then two loads in one call: on 01_b the replayed LEVEL_Load("01_a") is
    // pending again and FadeIn waits for 01_a.
    _ = try t.go("01_a");
    _ = try t.game.world.?.rt.callIfExists(t.level(), "goTwice", &.{});
    _ = try t.go(t.game.pendingLevel().?);
    const w = t.game.world.?;
    try std.testing.expectEqualStrings("01_b", w.level_name);
    try std.testing.expectEqualStrings("01_a", w.flow.pending_level.?);
    try std.testing.expectEqual(1, w.flow.load_steps.items.len);
    try std.testing.expectEqual(.fade_in, w.flow.load_steps.items[0].kind);
}

test "a scene with LOADLEVEL continues on the new location" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const a = t.game.world.?;
    try scenes.startScriptlet(a, "move");
    try scenes.tick(a);
    try std.testing.expectEqualStrings("01_b", t.game.pendingLevel().?);
    _ = try t.go(t.game.pendingLevel().?);
    // Left location no longer runs it; the new one resumes after LOADLEVEL.
    try std.testing.expect(a.scene.runner == null);
    const sc = t.game.world.?.scene.runner.?;
    try std.testing.expectEqualStrings("move", sc.name);
    try std.testing.expectEqual(1, sc.pc);
    try scenes.tick(t.game.world.?);
    try std.testing.expectEqual(1, t.game.world.?.scene.fade_target);
}

test "give: nothing to or from Medusa (0x42e485, 0x450872)" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const w = t.game.world.?;
    const other = t.level(); // stands in for a second hero; only nameID matters
    try std.testing.expect(items.give.canGive(w, t.hero(), other));
    fields.setNameId(other, 119);
    try std.testing.expect(!items.give.canGive(w, t.hero(), other));
    fields.setNameId(other, 1);
    fields.setNameId(t.hero(), 119);
    try std.testing.expect(!items.give.canGive(w, t.hero(), other));
}

test "give: the backpack's items go before the worn one" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const w = t.game.world.?;
    const worn = (try items.create.giveItem(w, "vest.s", "Sullivan", null)).?;
    const spare = (try items.create.giveItem(w, "vest.s", "Sullivan", null)).?;
    items.item.setPlace(worn, .armor);
    items.give.transfer(w, t.hero(), t.level(), worn, 1);
    try std.testing.expect(fields.ownerIs(spare, t.level().name));
    try std.testing.expect(fields.ownerIs(worn, "Sullivan"));
    try std.testing.expectEqual(items.item.Place.armor, items.item.placeOf(worn));
}

test "Medusa can't be picked by the player outside a battle (0x4b2761, 0x451467)" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    try std.testing.expect(t.game.world.?.playerCanSelect(t.hero()));
    fields.setNameId(t.hero(), 119);
    try std.testing.expect(!t.game.world.?.playerCanSelect(t.hero()));
    _ = try t.go("01__fight");
    try std.testing.expect(t.game.world.?.playerCanSelect(t.hero()));
}

test "battle music is drawn at level load: rand() % 2 == 0 is battle" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    crt_rand.global.seed(7);
    var copy = crt_rand.global;
    const want: []const u8 = if (copy.below(2) == 0) "battle" else "battle2";
    _ = try t.go("01__fight");
    try std.testing.expectEqualStrings(want, t.game.world.?.battle_music.?);
    try std.testing.expectEqualStrings(want, game.levelMusic(t.game.world.?).combat.?);
    // Plain levels draw nothing.
    try std.testing.expect(t.game.cache.count() == 1 and t.game.cache.get("01_a").?.battle_music == null);
}

test "a mid-line page turn keeps the voice; ending the line cuts it" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const w = t.game.world.?;
    w.scene.subtitle = .{ .speaker = "Sullivan", .text = "Hello" };
    w.scene.line_open = true;
    w.scene.subtitle_pages = 2;
    try std.testing.expect(scenes.skipLine(w));
    try std.testing.expect(!w.out.voice_cut);
    try std.testing.expect(scenes.skipLine(w));
    try std.testing.expect(w.out.voice_cut);
}

test "selectHero: avoidEnumerate heroes are skipped; plays the sound" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const w = t.game.world.?;
    w.selected_hero = "";
    t.hero().setInt("avoidEnumerate", 1);
    game.selectHero(w, "Sullivan");
    try std.testing.expectEqualStrings("", w.selected_hero);
    t.hero().setInt("avoidEnumerate", 0);
    game.selectHero(w, "Sullivan");
    try std.testing.expectEqualStrings("Sullivan", w.selected_hero);
    try std.testing.expectEqualStrings("selecthero", w.out.sound_events.items[w.out.sound_events.items.len - 1].name);
}

test "switchTo: a selected hero not in the new location's party list gives way to its first (0x481ce0)" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    // Medusa picked in a battle: on a location she is not a selectable party hero.
    t.game.world.?.selected_hero = "Medusa";
    _ = try t.go("01_b");
    try std.testing.expectEqualStrings("Sullivan", t.game.world.?.selected_hero);
}

test "battle end: the engine queues victory or gameover music 90 ticks later (0x454880, 0x454350)" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const w = t.game.world.?;
    var tb: fixture.TestBattle = .init();
    defer tb.deinit();
    const b = &tb.b;
    b.phase = .lost;
    for (0..89) |_| try battle_tick.tick(b, w);
    for (w.out.music_events.items) |m| try std.testing.expect(!std.mem.eql(u8, m.name, "gameover"));
    try battle_tick.tick(b, w);
    try std.testing.expectEqualStrings("gameover", w.out.music_events.items[w.out.music_events.items.len - 1].name);
}

test "world cache keys ignore case (scripts write level names in any case)" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const a = t.game.world.?;
    _ = try t.go("01_b");
    const sw = try t.go("01_A");
    try std.testing.expect(sw.restored and t.game.world.? == a);
}

test "a removed actor's current and morph glow end with it, not on return to the level" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const w = t.game.world.?;
    const h = t.hero();
    // VOLTAGE("Medusa") … DELETEOBJECT("Medusa") (museum-medusa_crazy.scr); ACTOR_MORPH Bt …
    // DELETEOBJECT("Bt") (lab-lamare_dying.scr).
    @import("../fx.zig").hits.current(w, h);
    var m = @import("../effects.zig").bitmap.Morph.init(.{ 0, 0, 0 }, 0, "bt", "", 1, w.crt());
    m.owner = h;
    try w.effects.morphs.append(w.gpa, m);
    h.enabled = false;
    @TypeOf(w.*).nativeOf(h).deleted = true;
    try game.tick(w);
    _ = try t.go("01_b");
    _ = try t.go("01_a");
    try std.testing.expectEqual(0, w.effects.beams.items.len);
    try std.testing.expectEqual(0, w.effects.morphs.items.len);
}

test "mod scene commands and builtins: IDLE_OFF, ZOOM, GUI_GAMEOVER, Actor_QueueState, AttachActors" {
    var t: TestGame = undefined;
    try t.init();
    defer t.deinit();
    const w = t.game.world.?;
    const h = t.hero();
    const a = @import("../state.zig").world.actorOf(h);
    try scenes.startScriptlet(w, "modcmds");
    try scenes.tick(w);
    // IDLE_OFF is queued (command 0x26) and runs with the queue; ZOOM clamps to 200 %.
    try std.testing.expect(a.idle_off);
    try std.testing.expectEqual(@as(f32, 2), w.out.zoom.?.to);
    try std.testing.expectEqual(@as(?f32, 10), w.out.zoom.?.time);
    try std.testing.expectEqual(@as(?u32, 0), w.flow.defeat_ticks);
    // The scene's end turns idles back on (0x479093).
    for (0..8) |_| try game.tick(w);
    try std.testing.expect(w.scene.runner == null and !a.idle_off);
    for (0..90) |_| try game.tick(w);
    var music = false;
    for (w.out.music_events.items) |m| music = music or std.mem.eql(u8, m.name, "gameover");
    try std.testing.expect(music);
    // Actor_QueueState(…, 4) (command 0x22): links off, then the state.
    const bi = @import("../builtins.zig").actors;
    try a.links.append(w.gpa, .{ .link = "back", .mesh = "m" });
    _ = try bi.biActorQueueState(w, &w.rt, h, &.{ .{ .string = "Sullivan" }, .{ .int = 4 } });
    try @import("../world.zig").queue.runQueue(w, h, a);
    try std.testing.expectEqual(4, a.state);
    try std.testing.expect(a.links.items.len == 0 and a.weapon_detached);
    // AttachActors: offset (a, b, c) in world units → mesh x = b, y = c, z = a over the scale.
    _ = try bi.biAttachActors(w, &w.rt, h, &.{ .{ .string = "Sullivan" }, .{ .string = "Sullivan" }, .{ .float = 1 }, .{ .float = 2 }, .{ .float = 3 }, .{ .float = 0.5 } });
    const s = w.actorScale() * 24;
    try std.testing.expectApproxEqAbs(2 / s, a.link_offset[0], 1e-6);
    try std.testing.expectApproxEqAbs(3 / s, a.link_offset[1], 1e-6);
    try std.testing.expectApproxEqAbs(1 / s, a.link_offset[2], 1e-6);
    try std.testing.expectEqual(@as(f32, 0.5), a.link_angle);
    a.attached_to = null;
}

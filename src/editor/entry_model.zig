//! A fighter's (or a weapon's) look on its page: the model with its animations, a frame
//! slider and each animation's sounds on a timeline; a weapon shown struck by a hero.

const std = @import("std");
const actOf = @import("entries.zig").actOf;
const idName = @import("entries.zig").idName;
const fileOf = @import("entries.zig").fileOf;
const overlayGet = @import("entries.zig").overlayGet;
const entryById = @import("entries.zig").entryById;
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const model = @import("model.zig");
const catalog = @import("catalog.zig");
const common_archive = @import("store.zig").common_archive;
const preview = @import("preview.zig");
const sounds = @import("sounds.zig");
const soundpage = @import("soundpage.zig");
const picker = @import("picker.zig");
const og = @import("opengorky");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const entries = @import("entries.zig");
const art = @import("art.zig");
const ea = @import("entry_attacks.zig");
const SpinLane = ea.SpinLane;

/// What the preview shows: an actor script's model (`meshFile`) in the chosen
/// animation (logical slot and file animation), drawn this frame.
pub const Look = struct { list: []const preview.Anim, slot: []const u8, file: []const u8, mesh: []const u8, tex: ?*anyopaque };

/// `want`: this animation slot instead of the one picked (a weapon's attack);
/// `held`: a weapon in the hand.
/// `riders`: fighters riding it (catalog.Rider).
pub fn look(app: *App, a: Allocator, act_text: []const u8, want: ?[]const u8, held: ?preview.Held, riders: []const catalog.Rider) Look {
    const list_ = preview.anims(a, act_text);
    const mesh = model.textStr(app, act_text, "mesh") orelse "";
    const fileOfSlot = struct {
        fn f(l: []const preview.Anim, s: []const u8) ?[]const u8 {
            for (l) |an| if (std.mem.eql(u8, an.slot, s)) return an.file;
            return null;
        }
    }.f;
    // The model's animation picked (another model's: none); none: the long attack, as
    // the game shows it most.
    const anims = @import("entry_anims.zig").modelAnims(app, mesh) orelse &.{};
    const mine = app.anim_name.len > 0 and (@import("entry_anims.zig").has(anims, app.anim_name.get()) or for (list_) |an| {
        if (std.ascii.eqlIgnoreCase(an.file, app.anim_name.get())) break true;
    } else false);
    const file = if (want) |w| fileOfSlot(list_, w) orelse "" else if (mine) app.anim_name.get() else fileOfSlot(list_, "long_attack") orelse if (anims.len > 0) anims[0].name else "";
    const slot = want orelse for (list_) |an| {
        if (std.ascii.eqlIgnoreCase(an.file, file)) break an.slot;
    } else "";
    // As large as the picture's place was last frame.
    const px: [2]u32 = if (clay.box(clay.id("preview_img"))) |b| .{ @intFromFloat(@max(64, b.width)), @intFromFloat(@max(64, b.height)) } else .{ 512, 512 };
    // OpenGorky: a slot's animation the model lacks shows an idle, as the game draws it.
    const drawn = if (app.ogLayout()) @import("entry_anims.zig").idleInstead(app, a, act_text, anims, file) orelse file else file;
    const tex = app.preview.draw(app.gpa, app.io, app.dat, app.r, .{ .ctx = app, .get = overlayGet }, mesh, drawn, held, ridersOn(app, a, riders, slot), px);
    // Stopped: what it was playing stops too (a long sound would play on).
    const playing = app.preview.paused == null;
    if (app.preview.was_playing and !playing) app.player.stopAll();
    app.preview.was_playing = playing;
    // The strike's effect sounds and the riders' frame sounds, as the model's (soundsBlock).
    if (!app.player.muted) for (app.preview.fx_sounds) |n| app.player.play(app, n);
    for (app.preview.riders_shown) |rs| {
        var l = sounds.load(app, rs.mesh) orelse continue;
        defer l.list.deinit();
        for (l.list.items) |an| if (std.ascii.eqlIgnoreCase(an.name, rs.anim)) app.player.frames(app, an, rs.prev, rs.now);
    }
    return .{ .list = list_, .slot = slot, .file = file, .mesh = mesh, .tex = tex };
}

/// Riders for the preview, as the game moves them: in their own idle animation whatever
/// the model plays (the exe syncs no hit or death); the Smoke Rider's ladder_start (its
/// weapon 1004 strike, combat/anim.zig) makes the second rider play long_attack
/// (callback 21, 0x487698, when more than one rides).
pub fn ridersOn(app: *App, a: Allocator, riders: []const catalog.Rider, slot: []const u8) []const preview.Rider {
    var on: std.ArrayList(preview.Rider) = .empty;
    for (riders, 0..) |rd, i| {
        var buf: [128]u8 = undefined;
        const af = app.store.file(common_archive, std.fmt.bufPrint(&buf, "classes\\{s}", .{rd.act}) catch continue) catch continue;
        const rt = app.store.text(af);
        const idle = idle: {
            const p = std.mem.indexOf(u8, rt, "RegisterIdleAnimation(") orelse break :idle "";
            var it = std.mem.splitScalar(u8, rt[p..], '"');
            _ = it.next();
            break :idle it.next() orelse "";
        };
        const fires = i == 1 and riders.len > 1 and std.mem.eql(u8, slot, "ladder_start");
        const act = if (fires) for (preview.anims(a, rt)) |an| {
            if (std.mem.eql(u8, an.slot, "long_attack")) break an.file;
        } else "" else "";
        on.append(a, .{ .mesh = model.getStr(rt, "mesh") orelse continue, .link = rd.point, .anim = idle, .act = act }) catch {};
    }
    return on.items;
}

/// A hero striking with a weapon: the hero's script, the animation slot, the weapon in
/// hand and a line about it.
pub const Strike = struct { hero_text: []const u8, slot: []const u8, held: ?preview.Held, info: []const u8 };

pub fn strikeOf(app: *App, a: Allocator, text: []const u8, class: []const u8) ?Strike {
    const og_project = app.ogLayout();
    const weapon_id: i32 = if (og_project) og.core.entity.idOf(class) orelse 0 else @intFromFloat(model.textNum(app, text, "classic_id") orelse 0);
    const weapon_who: og.rules.Who = .{ .id = weapon_id, .class = if (og_project) class else "" };
    const heroes = strikers(app, a, text, class, weapon_who);
    app.strikers = heroes;
    if (heroes.len == 0) return null;
    const hi = for (heroes) |h| {
        if (h == app.attack_hero) break h;
    } else heroes[0];
    const he = app.catalog.entries.items[hi];
    const h = heroWho(app, he) orelse return null;
    const ht = h.text;
    const hero_who = h.who;
    // Striking by its own rows (Medusa): its attack with this weapon, as its enemy side's page shows it.
    if (og.core.entity.heroOf(hero_who).own_attacks) {
        const at = ownAttack(app, a, hero_who, class) orelse return null;
        const st = ea.strikeOf(app.gpa, hero_who, at) orelse return null;
        return .{ .hero_text = ht, .slot = st.slot, .held = st.held, .info = tx.alloc(a, tx.atk_own, .{st.slot}) };
    }
    const at = heroStrike(app, text, weapon_who, hero_who);
    const two = (model.textNum(app, text, "two_handed") orelse 0) == 1;
    const slot = heroSlot(a, ht, at.anim, two) orelse at.anim;
    const wait: i32 = @as(i32, @intCast(at.wait)) + at.extra;
    // What the exe shows of the strike by the weapon's effects id: the flash, projectile
    // and hit (fx/hits.zig, fx/launch.zig), at the hit's frame.
    const src: @import("preview_fx.zig").Src = .{ .who = hero_who, .weapon = weapon_who, .fx_as = @intFromFloat(model.textNum(app, text, "effects_from") orelse 0), .projectile = model.textStr(app, text, "projectile") };
    const strike = @import("preview_fx.zig").strikeOf(app.gpa, src, og.combat.anim.hitFrame(@intCast(@max(0, wait))), if (at.pre) |p| og.combat.anim.hitFrame(p) else null);
    // Nothing in hand (the satellite radio): the strike's effects alone.
    const held: ?preview.Held = if (model.textStr(app, text, "mesh")) |m| .{ .mesh = m, .link = if (two) "two_hands" else "one_hand", .strike = strike } else .{ .mesh = "", .link = "", .strike = strike };
    return .{ .hero_text = ht, .slot = slot, .held = held, .info = tx.alloc(a, tx.atk_info, .{ slot, wait, tx.get(if (two) tx.atk_two else tx.atk_one) }) };
}

/// A hero's look text (its animations) and who it is to the rules.
fn heroWho(app: *App, he: catalog.Entry) ?struct { text: []const u8, who: og.rules.Who } {
    const hf = fileOf(app, he) orelse return null;
    // OpenGorky: the hero's look block binds its animations; the numbers the reader's.
    if (app.ogLayout()) return .{ .text = lookText(app, hf) orelse return null, .who = .{ .id = og.core.entity.idOf(he.class) orelse 0, .class = he.class } };
    const ht = app.store.text(hf);
    return .{ .text = ht, .who = .{ .id = @intFromFloat(model.textNum(app, ht, "classic_id") orelse 0) } };
}

/// The hero table's strike of `hero` with the weapon (its block `text`), the weapon's own numbers over it.
fn heroStrike(app: *App, text: []const u8, weapon: og.rules.Who, hero: og.rules.Who) og.battle.attacks.HeroAttack {
    const row = og.battle.attacks.heroAttack(hero, weapon);
    return if (app.ogLayout()) @import("entry_tables.zig").scriptOver(row, text) else row;
}

/// The animation slot `anim` in look `ht` (two-handed: the stance-1 one, `attack_rifle/1`
/// → g_rifle, if it has it); null: the look has neither.
fn heroSlot(a: Allocator, ht: []const u8, anim: []const u8, two: bool) ?[]const u8 {
    const s1 = if (two) std.fmt.allocPrint(a, "{s}/1", .{anim}) catch anim else anim;
    var plain = false;
    for (preview.anims(a, ht)) |an| {
        if (std.mem.eql(u8, an.slot, s1)) return s1;
        if (std.mem.eql(u8, an.slot, anim)) plain = true;
    }
    return if (plain) anim else null;
}

/// Who strikes with the weapon (block `text`, class `class`): a hero of the hero table
/// with a row for this weapon and the row's animation in its look; one striking by its
/// own rows (Medusa) when its enemy side holds the weapon.
fn strikers(app: *App, a: Allocator, text: []const u8, class: []const u8, weapon: og.rules.Who) []const usize {
    var out: std.ArrayList(usize) = .empty;
    const two = (model.textNum(app, text, "two_handed") orelse 0) == 1;
    for (app.catalog.entries.items, 0..) |e, hi| {
        if (e.kind != .hero) continue;
        const h = heroWho(app, e) orelse continue;
        const fits = if (og.core.entity.heroOf(h.who).own_attacks) ownAttack(app, a, h.who, class) != null else blk: {
            // The exe's rifle fallback (no row for the weapon at all) is not a strike with it.
            const row = og.rules.heroAttackRow(weapon, h.who) orelse break :blk false;
            if (og.rules.keyMatch(row.*, "weapon", weapon) == null) break :blk false;
            break :blk heroSlot(a, h.text, heroStrike(app, text, weapon, h.who).anim, two) != null;
        };
        if (fits) out.append(a, hi) catch {};
    }
    return out.items;
}

/// Attack with weapon `class` of a hero striking by its own rows (Medusa), as its enemy
/// side (the enemy of its class) holds it (catalog: its fighter block's weapons) or its
/// rows give it; null: it does not.
fn ownAttack(app: *App, a: Allocator, who: og.rules.Who, class: []const u8) ?ea.Attack {
    const want = @import("entry_rules.zig").bareClass(class);
    const og_project = app.ogLayout();
    for (app.catalog.entries.items) |x| {
        if (x.kind != .enemy) continue;
        const f = fileOf(app, x) orelse continue;
        const w = entries.enemyWho(app, x, app.store.text(f));
        if (if (og_project) !std.mem.eql(u8, w.class, who.class) else w.id != who.id) continue;
        for (ea.attacksOf(app, a, x, w)) |at| if (std.ascii.eqlIgnoreCase(@import("entry_rules.zig").bareClass(at.class), want)) return at;
    }
    return null;
}

/// OpenGorky: the text of fighter block file `file`'s look (`look = looks::sullivan`: its
/// block's file, binding the model's animations); null: none.
pub fn lookText(app: *App, file: usize) ?[]const u8 {
    const v = model.field(app, file, "look").og_expr orelse return null;
    if (v.kind != .word) return null;
    return app.store.text(model.model_og.archetypeFile(app, v.kind.word) orelse return null);
}

/// Catalog indices of the heroes able to strike.
pub fn heroEntries(app: *App, a: Allocator) []const usize {
    var out: std.ArrayList(usize) = .empty;
    for (app.catalog.entries.items, 0..) |e, i| {
        if (e.kind != .hero) continue;
        // Only those with strikes (the party; not the monitors or the girl).
        const f = fileOf(app, e) orelse continue;
        const t = if (app.ogLayout()) lookText(app, f) orelse continue else app.store.text(f);
        if (std.ascii.findIgnoreCase(t, "\"attack_") == null) continue;
        out.append(a, i) catch {};
    }
    return out.items;
}

/// Bottom left on a weapon's page: who strikes with it in the preview.
fn heroList(app: *App) void {
    clay.openScroll(.{ .id = clay.id("atk_heroes"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = lay.space.sm, .top = lay.space.xs } } });
    gui.txt(tx.get(tx.atk_who), .body, theme.dim, font_mod.bold);
    const list = app.strikers;
    const cur = for (list) |h| {
        if (h == app.attack_hero) break h;
    } else if (list.len > 0) list[0] else 0;
    for (list, 0..) |hi, k| {
        const e = app.catalog.entries.items[hi];
        const sel = hi == cur;
        if (gui.listRow(app, clay.idi("atk_hero", @intCast(k)), .{ .selected = sel, .h = lay.height.small, .rounded = false, .bg = theme.bg })) app.attack_hero = hi;
        gui.txt(if (e.title.len > 0) e.title else e.id, .label, theme.text, if (sel) font_mod.bold else font_mod.regular);
        gui.txt(e.id, .caption, theme.dim, font_mod.regular);
        clay.close();
    }
    clay.close();
}

/// A look on the stage: the model over its animations (`act`'s; null: the heroes striking,
/// heroList) and their sounds, the edges dragged; `fx`: a strike's effects over its frames;
/// `spins`: the own strikes' spins on the animation shown (the animations page).
pub fn lookStage(app: *App, a: Allocator, l: Look, act: ?[]const u8, info: ?[]const u8, fx: ?@import("preview_fx.zig").Strike, spins: []const SpinLane) void {
    const centre = @import("frame.zig").width(app);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(app.pane(.entry_y)) } } });
    modelPane(app, l, info, if (act == null) tx.atk_hint else tx.anim_hint);
    clay.close();
    app.splitter(.entry_y, true, 1, 0);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } } });
    // At most 45% of the centre: the sounds beside it keep room in a narrow window.
    const list_w = @min(app.pane(.entries), centre * 0.45);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(list_w), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    if (act) |t| @import("entry_anims.zig").list(app, a, t, l.mesh, l.file) else heroList(app);
    clay.close();
    app.splitter(.entries, false, 1, 0);
    // The rest, as a bound: its timeline is as wide as this, not as its content.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(@max(0, centre - list_w - lay.border.edge)), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    if (fx) |s| @import("fxdesc.zig").timeline(app, a, s);
    if (l.tex != null) soundsBlock(app, a, l.mesh, l.file, spins);
    clay.close();
    clay.close();
}

/// The model over the whole top part; dragging it turns it, the wheel zooms; `hint` under it.
pub fn modelPane(app: *App, l: Look, info: ?[]const u8, hint: tx.Msg) void {
    // The picture fills the area; the buttons and the hint lie over it.
    clay.open(.{ .id = clay.id("preview_img"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .top = lay.space.sm, .bottom = lay.space.sm }, .childGap = lay.space.sm }, .backgroundColor = theme.viewport, .image = .{ .imageData = l.tex }, .clip = .{ .vertical = true } });
    // Over the model: back to the starting angle.
    // Scrolled sideways when even the icons don't fit (300% in a small window).
    var bar = gui.Toolbar.over("preview_bar");
    // Playback: a frame back, play / pause, a frame on, where it is.
    const pv = &app.preview;
    if (bar.button(app, "preview_back", .skip_back, "", false, false)) pv.step(-1);
    if (bar.button(app, "preview_play", if (pv.paused == null) .pause else .play, "", pv.paused != null, false)) pv.togglePause();
    if (bar.button(app, "preview_next", .skip_forward, "", false, false)) pv.step(1);
    const at = std.fmt.allocPrint(app.frame.allocator(), "{d} / {d}", .{ pv.at + 1, pv.frames }) catch "";
    gui.txt(at, .caption, theme.dim, font_mod.regular);
    bar.reserve(app.font.measure(at, font_mod.regular, gui.Type.caption.pt())[0]);
    gui.spacer();
    // The view's buttons as icons in a narrow pane (the tool shown keeps its name).
    if (bar.button(app, "preview_tex", .image, tx.get(tx.pv_texture), !app.preview.wire, false)) app.preview.wire = false;
    if (bar.button(app, "preview_wire", .box, tx.get(tx.pv_wire), app.preview.wire, false)) app.preview.wire = true;
    if (bar.button(app, "preview_reset", .undo_2, tx.get(tx.pv_reset), false, false)) {
        app.preview.yaw = 210;
        app.preview.pitch = 0;
        app.preview.zoom = 1;
        app.preview.shift = .{ 0, 0 };
    }
    bar.close();
    clay.leaf(.{ .layout = .{ .sizing = .{ .height = clay.grow() } } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.sm, 0), .childGap = lay.space.sm } });
    if (info) |s| gui.txtWrap(s, .body, theme.text, font_mod.regular);
    gui.txtWrap(tx.get(if (l.tex == null) tx.no_model else hint), .body, if (l.tex == null) theme.warn else theme.dim, font_mod.regular);
    clay.close();
    clay.close();
}

/// The frame sounds of the animation shown (`.ani` of the model): played with the
/// preview; each can be moved by frames, swapped or removed, and new ones added.
fn soundsBlock(app: *App, a: Allocator, mesh: []const u8, anim_file: []const u8, spins: []const SpinLane) void {
    var l = sounds.load(app, mesh) orelse return;
    defer l.list.deinit();
    const ai = for (l.list.items, 0..) |an, i| {
        if (std.ascii.eqlIgnoreCase(an.name, anim_file)) break i;
    } else {
        // A binding to nothing in the model: no sounds of its own to show.
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .padding = gui.pad(lay.space.md, lay.space.md) }, .backgroundColor = theme.panel });
        gui.txtWrap(tx.get(if (app.ogLayout()) tx.an_missing_og else tx.an_missing), .body, theme.warn, font_mod.regular);
        clay.close();
        return;
    };
    const an = l.list.items[ai];
    app.player.frames(app, an, app.preview.prev, app.preview.frame);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM }, .backgroundColor = theme.panel });
    // The title bar, as the other parts': the animation, the frame shown, sound on/off.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(lay.height.tool) }, .padding = gui.pad(lay.space.md, 0), .childGap = lay.space.sm, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.header, .border = .{ .color = theme.line, .width = .{ .bottom = lay.border.line } } });
    gui.txt(tx.alloc(a, tx.snd_title, .{ an.name, app.preview.frame -| an.first, an.last - an.first }), .caption, theme.dim, font_mod.bold);
    gui.spacer();
    if (gui.textButton(app, "snd_mute", tx.get(if (app.player.muted) tx.snd_off else tx.snd_on), theme.dim)) app.player.muted = !app.player.muted;
    clay.close();
    const r = struct {
        fn op(ap: *App, file: usize, i: usize, o: sounds.Op) void {
            sounds.edit(ap, file, i, o) catch |err| ap.failed(err);
        }
    };
    timeline(app, a, an, l.file, ai, spins);
    clay.openScroll(.{ .id = clay.id("snd_rows"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    // Shown by frame; `k` stays the cue's index in the file.
    const order: []usize = a.alloc(usize, an.sounds.len) catch &.{};
    for (order, 0..) |*o, j| o.* = j;
    std.mem.sort(usize, order, an.sounds, struct {
        fn f(cs: []const og.formats.anim.SoundCue, x: usize, y: usize) bool {
            return cs[x].frame < cs[y].frame or (cs[x].frame == cs[y].frame and x < y);
        }
    }.f);
    for (order) |k| {
        const cue = an.sounds[k];
        const id: u32 = @intCast(k);
        _ = gui.listRow(app, clay.idi("snd", id), .{ .h = lay.height.small, .gap = lay.space.xs, .rounded = false, .bg = theme.bg });
        gui.txt(tx.alloc(a, tx.snd_frame, .{cue.frame -| an.first}), .body, theme.dim, font_mod.regular);
        const nid = clay.idi("snd_name", id);
        clay.open(.{ .id = nid, .layout = .{ .sizing = .{ .width = clay.grow() } } });
        if (clay.hovered() and app.clicked) picker.toggle(app, nid);
        gui.txt(cue.name, .body, if (clay.pointerOver(nid)) theme.accent_hover else theme.text, font_mod.regular);
        clay.close();
        if (picker.isOpen(app, nid)) soundList(app, a, l.file, ai, k);
        if (gui.textButton(app, idName(a, "snd_play", k), tx.get(tx.snd_play), theme.accent_hover)) app.player.play(app, cue.name);
        if (gui.textButton(app, idName(a, "snd_m10", k), "«", theme.dim)) r.op(app, l.file, ai, .{ .move = .{ .i = k, .d = -10 } });
        if (gui.textButton(app, idName(a, "snd_m1", k), "<", theme.dim)) r.op(app, l.file, ai, .{ .move = .{ .i = k, .d = -1 } });
        if (gui.textButton(app, idName(a, "snd_p1", k), ">", theme.dim)) r.op(app, l.file, ai, .{ .move = .{ .i = k, .d = 1 } });
        if (gui.textButton(app, idName(a, "snd_p10", k), "»", theme.dim)) r.op(app, l.file, ai, .{ .move = .{ .i = k, .d = 10 } });
        if (gui.textButton(app, idName(a, "snd_del", k), "×", theme.warn)) r.op(app, l.file, ai, .{ .remove = k });
        clay.close();
    }
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = lay.space.sm, .top = lay.space.xs } } });
    if (gui.textButton(app, "snd_add", tx.get(tx.snd_add), theme.accent_hover)) picker.toggle(app, clay.id("snd_add"));
    if (picker.isOpen(app, clay.id("snd_add"))) soundList(app, a, l.file, ai, null);
    clay.close();
    spinRows(app, a, mesh, spins, app.preview.frame -| an.first);
    clay.close();
    gui.txtWrap(tx.alloc(a, tx.snd_shared, .{mesh}), .caption, theme.dim, font_mod.regular);
    clay.close();
}

/// The animation's frames as a ruler (as the concept's timeline): every 5th numbered,
/// the frame shown marked, each sound a marker at its frame — dragged to another frame
/// (one undo step on release).
fn timeline(app: *App, a: Allocator, an: og.formats.anim.Animation, file: usize, ai: usize, spins: []const SpinLane) void {
    const n: u32 = an.last - an.first + 1;
    const tid = clay.id("snd_timeline");
    // The ruler's geometry, in layout tokens: its inset, the ticks under the numbers, the
    // frame line and the markers under them.
    const inset = lay.space.md;
    const ticks_y = lay.space.lg;
    const marks_y = lay.space.xl + lay.space.md;
    const mark = lay.height.tick - lay.border.mark;
    // A lane under the sounds for each own strike's spins.
    const ruler_h = @as(f32, @floatFromInt(2 + spins.len)) * lay.height.tab;
    const w = if (clay.box(tid)) |b| b.width - 2 * inset else lay.width.page;
    const step = w / @as(f32, @floatFromInt(@max(1, n - 1)));
    const xOf = struct {
        fn f(fr: u32, st: f32) f32 {
            return inset + @as(f32, @floatFromInt(fr)) * st;
        }
    }.f;
    // Its marks float over it, cut with the pane (a narrow one shows part of the frames).
    // Clipped: its marks float, so a narrow pane cuts them rather than letting them spill.
    clay.open(.{ .id = tid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(ruler_h) } }, .backgroundColor = theme.field, .border = .{ .color = theme.line, .width = .{ .bottom = lay.border.line } }, .clip = .{ .horizontal = true } });
    const over = clay.hovered();
    var fr: u32 = 0;
    while (fr < n) : (fr += 1) {
        const major = fr % 5 == 0;
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lay.border.line), .height = clay.fixed(if (major) lay.space.md else lay.space.md / 2) } }, .backgroundColor = theme.field_border, .floating = .{ .offset = .{ .x = xOf(fr, step), .y = ticks_y }, .attachTo = ui.CLAY_ATTACH_TO_PARENT, .clipTo = ui.CLAY_CLIP_TO_ATTACHED_PARENT } });
        if (major and (step >= lay.space.xs or fr % 10 == 0)) {
            clay.open(.{ .floating = .{ .offset = .{ .x = xOf(fr, step) - lay.space.xs, .y = 0 }, .attachTo = ui.CLAY_ATTACH_TO_PARENT, .clipTo = ui.CLAY_CLIP_TO_ATTACHED_PARENT } });
            gui.txt(std.fmt.allocPrint(a, "{d}", .{fr}) catch "", .caption, theme.dim, font_mod.regular);
            clay.close();
        }
    }
    // The frame the preview shows.
    const cur = app.preview.frame -| an.first;
    if (cur < n) clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(lay.border.mark), .height = clay.fixed(ruler_h - ticks_y - lay.space.xs) } }, .backgroundColor = theme.accent, .floating = .{ .offset = .{ .x = xOf(cur, step) - lay.border.line, .y = ticks_y }, .attachTo = ui.CLAY_ATTACH_TO_PARENT, .clipTo = ui.CLAY_CLIP_TO_ATTACHED_PARENT, .zIndex = 2 } });
    for (an.sounds, 0..) |cue, k| {
        const dragging = if (app.cue_drag) |d| d.cue == k else false;
        const f = if (dragging) app.cue_drag.?.frame else cue.frame -| an.first;
        const mid = clay.idi("snd_mark", @intCast(k));
        clay.open(.{ .id = mid, .layout = .{ .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER } }, .floating = .{ .offset = .{ .x = xOf(f, step) - mark / 2, .y = marks_y }, .attachTo = ui.CLAY_ATTACH_TO_PARENT, .clipTo = ui.CLAY_CLIP_TO_ATTACHED_PARENT, .zIndex = 3 } });
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(mark), .height = clay.fixed(mark) } }, .backgroundColor = if (dragging) theme.warn else theme.accent_hover, .cornerRadius = clay.radius(lay.radius.sm) });
        // A name only where no earlier cue sits close (the list below names them all).
        const crowded = for (an.sounds[0..k]) |o| {
            if (@abs(@as(f32, @floatFromInt(o.frame)) - @as(f32, @floatFromInt(cue.frame))) * step < lay.width.number) break true;
        } else false;
        if (!crowded) gui.txt(std.fs.path.stem(cue.name), .caption, theme.dim, font_mod.regular);
        clay.close();
        if (clay.pointerOver(mid) and app.clicked) app.cue_drag = .{ .file = file, .anim = ai, .cue = k, .frame = f };
    }
    // The spins, each a marker on its frame in its strike's lane: dragged to another frame
    // (OpenGorky: the FighterStrike row, one undo step on release).
    for (spins, 0..) |lane, li| for (lane.spins, 0..) |sp, k| {
        const dragging = if (app.spin_drag) |d| d.special == lane.special and d.i == k else false;
        const f = if (dragging) app.spin_drag.?.frame else ea.spinFrame(sp.at);
        const sid = clay.idi("spin_mark", @intCast(li * 64 + k));
        clay.open(.{ .id = sid, .layout = .{ .childGap = lay.space.xs, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .floating = .{ .offset = .{ .x = xOf(f, step) - mark / 2, .y = @as(f32, @floatFromInt(2 + li)) * lay.height.tab - lay.space.xs }, .attachTo = ui.CLAY_ATTACH_TO_PARENT, .clipTo = ui.CLAY_CLIP_TO_ATTACHED_PARENT, .zIndex = 3 } });
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(mark), .height = clay.fixed(mark) } }, .backgroundColor = if (dragging) theme.text else theme.warn });
        // A name only where no earlier spin of the lane sits close (the list below names them all).
        const crowded = for (lane.spins[0..k]) |o| {
            if (@abs(@as(f32, @floatFromInt(ea.spinFrame(o.at))) - @as(f32, @floatFromInt(f))) * step < lay.width.number) break true;
        } else false;
        if (!crowded) gui.txt(sp.link, .caption, theme.dim, font_mod.regular);
        clay.close();
        if (clay.pointerOver(sid) and app.clicked and app.ogLayout()) app.spin_drag = .{ .special = lane.special, .i = k, .frame = f };
    };
    clay.close();
    if (app.spin_drag) |*d| for (spins) |lane| if (lane.special == d.special and d.i < lane.spins.len) {
        const b = clay.box(tid) orelse return;
        d.frame = @intFromFloat(std.math.clamp(@round((app.mouse[0] - b.x - inset) / step), 0, @as(f32, @floatFromInt(n - 1))));
        if (!app.down) {
            const sd = d.*;
            app.spin_drag = null;
            if (sd.frame != ea.spinFrame(lane.spins[sd.i].at)) ea.setSpin(app, sd.special, sd.i, "frame", std.fmt.allocPrint(a, "{d}", .{sd.frame}) catch return) catch |err| app.failed(err);
        }
    };
    // A marker being dragged follows the pointer by frame; on release the move is made.
    if (app.cue_drag) |*d| if (d.file == file and d.anim == ai) {
        const b = clay.box(tid) orelse return;
        const x = app.mouse[0] - b.x - inset;
        d.frame = @intFromFloat(std.math.clamp(@round(x / step), 0, @as(f32, @floatFromInt(n - 1))));
        if (!app.down) {
            const was = an.sounds[d.cue].frame -| an.first;
            const delta: i32 = @as(i32, @intCast(d.frame)) - @as(i32, @intCast(was));
            const k = d.cue;
            app.cue_drag = null;
            if (delta != 0) sounds.edit(app, file, ai, .{ .move = .{ .i = k, .d = delta } }) catch |err| app.failed(err);
        }
    };
    _ = over;
}

/// The own strikes' spins under the sounds: per spin its frame, link point and × (OpenGorky),
/// a new one on the frame shown (`cur`) on a link point of model `mesh`; Classic: the exe's,
/// shown.
fn spinRows(app: *App, a: Allocator, mesh: []const u8, spins: []const SpinLane, cur: u32) void {
    const og_project = app.ogLayout();
    for (spins, 0..) |lane, li| {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = lay.space.sm, .top = lay.space.sm } } });
        gui.txt(tx.alloc(a, tx.spin_lane, .{lane.special}), .caption, theme.dim, font_mod.bold);
        clay.close();
        for (lane.spins, 0..) |sp, k| {
            const id: u32 = @intCast(li * 64 + k);
            _ = gui.listRow(app, clay.idi("spin", id), .{ .h = lay.height.small, .gap = lay.space.xs, .rounded = false, .bg = theme.bg });
            gui.txt(tx.alloc(a, tx.snd_frame, .{ea.spinFrame(sp.at)}), .body, theme.dim, font_mod.regular);
            gui.txt(sp.link, .body, theme.warn, font_mod.regular);
            gui.spacer();
            if (og_project and gui.textButton(app, idName(a, "spin_del", id), "×", theme.warn)) ea.setSpin(app, lane.special, k, "remove", "") catch |err| app.failed(err);
            clay.close();
        }
        if (!og_project) continue;
        const add_name = idName(a, "spin_add", li);
        const add = clay.id(add_name);
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = lay.space.sm, .top = lay.space.xs } } });
        if (gui.textButton(app, add_name, tx.alloc(a, tx.spin_add_at, .{cur}), theme.accent_hover)) picker.toggle(app, add);
        if (picker.isOpen(app, add)) {
            const links = ea.linkPoints(app, a, mesh);
            if (picker.list(app, a, picker.names(a, links))) |j| ea.setSpin(app, lane.special, 0, "add", std.fmt.allocPrint(a, "{s}@{d}", .{ links[j], cur }) catch "") catch |err| app.failed(err);
        }
        clay.close();
    }
}

/// `--sound ID ANIM ACTION` (checks): enemy `ID` shown in its animation `ANIM` (file
/// name, `atak`); ACTION `+NAME` adds, `K=NAME` swaps, `K>D` moves by D frames, `-K` removes.
pub fn soundOp(app: *App, id: []const u8, anim_file: []const u8, action: []const u8) !void {
    const i = try entryById(app, id);
    entries.showEntry(app, i);
    const text = app.store.text(fileOf(app, app.catalog.entries.items[i]) orelse return error.NoFile);
    var buf: [128]u8 = undefined;
    const act = app.store.text(try app.store.file(common_archive, try std.fmt.bufPrint(&buf, "classes\\{s}", .{actOf(text) orelse return error.NoLook})));
    app.anim_name.set(anim_file);
    if (action.len == 0) return;
    var l = sounds.load(app, model.textStr(app, act, "mesh") orelse return error.NoModel) orelse return error.NoAni;
    defer l.list.deinit();
    const ai = for (l.list.items, 0..) |an, k| {
        if (std.ascii.eqlIgnoreCase(an.name, anim_file)) break k;
    } else return error.NoAnimation;
    // `?`: the sound list open for a new one (screenshots).
    if (action[0] == '?') {
        picker.open(app, clay.id("snd_add"));
        return;
    }
    const op: sounds.Op = if (action[0] == '+') .{ .set = .{ .i = null, .name = action[1..] } } else if (action[0] == '-') .{ .remove = try std.fmt.parseInt(usize, action[1..], 10) } else if (std.mem.indexOfScalar(u8, action, '=')) |k|
        .{ .set = .{ .i = try std.fmt.parseInt(usize, action[0..k], 10), .name = action[k + 1 ..] } }
    else if (std.mem.indexOfScalar(u8, action, '>')) |k|
        .{ .move = .{ .i = try std.fmt.parseInt(usize, action[0..k], 10), .d = try std.fmt.parseInt(i32, action[k + 1 ..], 10) } }
    else
        return error.BadAction;
    return sounds.edit(app, l.file, ai, op);
}

/// The sounds to put on a frame of animation `ai` of `.ani` `file` (common/sound.dat and
/// the imported ones) for cue `cue` (null: a new one); the one clicked played and put on.
fn soundList(app: *App, a: Allocator, file: usize, ai: usize, cue: ?usize) void {
    const ns = app.player.names(app, a);
    const rows = picker.names(a, ns);
    for (rows) |*o| if (app.store.find(soundpage.archive_path, o.key) != null) {
        o.note = tx.get(tx.new);
    };
    const j = picker.list(app, a, rows) orelse return;
    app.player.play(app, ns[j]);
    sounds.edit(app, file, ai, .{ .set = .{ .i = cue, .name = ns[j] } }) catch |err| app.failed(err);
}

// The model as glTF and its own fields: file dialog answers for entry `ask.entry`
// (as entries.zig onTextureIn), the import a new model the entry then uses.
pub fn onGlbOut(app: *App, ask: app_mod.FileAsk, path: []const u8) !void {
    const e = app.catalog.entries.items[ask.entry];
    const text = app.store.text(fileOf(app, e) orelse return);
    try art.exportGlb(app, entries.meshOf(app, e, text) orelse return error.NoModel, path);
    app.setStatus(tx.st_glb_out, .{path});
}
pub fn onGlbIn(app: *App, ask: app_mod.FileAsk, path: []const u8) !void {
    const e = app.catalog.entries.items[ask.entry];
    const file = fileOf(app, e) orelse return;
    const text = app.store.text(file);
    const r = art.importGlb(app, entries.meshOf(app, e, text) orelse return error.NoModel, path, app.importTarget()) catch |err| return glbFailed(app, err);
    // As a new look: an enemy through a copy of its act_*.ss, the rest by meshFile; an
    // OpenGorky block where its model is named (its own `mesh`, else its look's).
    if (app.ogLayout()) {
        var buf: [64]u8 = undefined;
        try model.model_og.set(app, @import("og_page.zig").meshHolder(app, file) orelse return error.NoModel, &.{"mesh"}, try std.fmt.bufPrint(&buf, "\"{s}\"", .{r.name}));
    } else if (e.kind == .enemy) try entries.setAct(app, file, try art.newAct(app, actOf(text) orelse return error.NoLook, r.name)) else try entries.setString(app, file, "mesh", r.name);
    if (r.fitted > 0) app.setStatusPort(tx.st_glb_fit, .{ r.name, r.textures, r.fitted }, tx.st_og_art) else app.setStatusPort(tx.st_glb_in, .{ r.name, r.textures }, tx.st_og_art);
}
pub fn onAnimsIn(app: *App, ask: app_mod.FileAsk, path: []const u8) !void {
    const e = app.catalog.entries.items[ask.entry];
    const text = app.store.text(fileOf(app, e) orelse return);
    return animsIn(app, entries.meshOf(app, e, text) orelse return error.NoModel, path);
}

/// The animations of the `.glb` at `path` into model `mesh`, said in the status.
pub fn animsIn(app: *App, mesh: []const u8, path: []const u8) !void {
    const a = app.frame.allocator();
    const r = art.importAnims(app, a, mesh, path) catch |err| return glbFailed(app, err);
    const none = "—";
    const added = if (r.added.len > 0) std.mem.join(a, ", ", r.added) catch none else none;
    const replaced = if (r.replaced.len > 0) std.mem.join(a, ", ", r.replaced) catch none else none;
    app.setStatus(tx.st_anims_in, .{ mesh, r.added.len, added, r.replaced.len, replaced });
}

/// Import errors (the exe's limits, gltf_import.zig) said plainly.
const glb_errors = [_]struct { []const u8, tx.Msg }{
    .{ "TooManyVertices", tx.glb_verts },  .{ "TooManyTriangles", tx.glb_verts }, .{ "BadTriangle", tx.glb_tri },
    .{ "NameTooLong", tx.glb_name },       .{ "StringTooLong", tx.glb_name },     .{ "BadBone", tx.glb_bone },
    .{ "BadAttachBone", tx.glb_bone },     .{ "BonesMismatch", tx.glb_skel },     .{ "SkeletonMismatch", tx.glb_skel },
    .{ "TooManyInfluences", tx.glb_skin }, .{ "SeveralSkins", tx.glb_skin },      .{ "NotGlb", tx.glb_file },
    .{ "BadGlb", tx.glb_file },            .{ "ExternalBuffer", tx.glb_file },    .{ "ExternalImage", tx.glb_file },
    .{ "AnimOutOfRange", tx.glb_anim },    .{ "BadSize", tx.glb_size },
};

/// The exe's limits a Classic project keeps (mesh.checkLimits `.both`, tex3df sizes).
const exe_limits = [_][]const u8{ "TooManyVertices", "TooManyTriangles", "NameTooLong", "StringTooLong", "BadTriangle", "BadSize" };

pub fn glbFailed(app: *App, err: anyerror) void {
    const why = for (glb_errors) |ge| {
        if (std.mem.eql(u8, ge[0], @errorName(err))) break ge[1];
    } else tx.glb_other;
    // Past the exe's limits in a Classic project: the way is conversion, not splitting.
    if (!app.ogLayout()) for (exe_limits) |n| if (std.mem.eql(u8, n, @errorName(err))) return app.setAlert(tx.glb_failed_title, tx.st_glb_failed, .{ tx.get(tx.glb_classic), err });
    app.setAlert(tx.glb_failed_title, tx.st_glb_failed, .{ tx.get(why), err });
}

/// The model block: its height, centre, rotation and attach points, added and removed
/// (the `.msh` itself: every entry with this model has them), the model to and from glTF.
/// `idx`: the entry a model imported from glTF goes to (null: no import; the model's
/// page, look_pages.zig, exports the one shown).
pub fn modelFields(app: *App, a: Allocator, idx: ?usize, mesh: []const u8) void {
    var eb: [160]u8 = undefined;
    const f: ?usize = app.store.file(common_archive, std.fmt.bufPrint(&eb, "gfx_3d\\{s}.msh", .{mesh}) catch "") catch null;
    var parsed: ?og.formats.mesh.Mesh = if (f) |fi| og.formats.mesh.parse(app.gpa, app.store.text(fi)) catch null else null;
    defer if (parsed) |*m| m.deinit();
    var adds: [hold_names.len][]const u8 = undefined;
    var n_adds: usize = 0;
    if (parsed) |*m| {
        const xyz = [_][]const u8{ "X", "Y", "Z" };
        // Every row ends in the × slot of the attach points' (the values end alike).
        gui.fieldRow(tx.get(tx.m_height));
        if (gui.numberField(app, a, "msh_height", "", m.height, lay.width.number)) |v| setField(app, mesh, .{ .height = v }, "height");
        gui.spacer();
        _ = gui.trail(app, null);
        clay.close();
        gui.fieldRow(tx.get(tx.m_center));
        for (0..3) |k| if (gui.numberField(app, a, idName(a, "msh_center", k), xyz[k], m.center[k], gui.cellWidth(3, true))) |v| setField(app, mesh, .{ .center = .{ .k = k, .v = v } }, "center");
        _ = gui.trail(app, null);
        clay.close();
        gui.fieldRow(tx.get(tx.m_rotation));
        for (0..3) |k| if (gui.numberField(app, a, idName(a, "msh_rot", k), xyz[k], m.rotation[k], gui.cellWidth(3, true))) |v| setField(app, mesh, .{ .rotation = .{ .k = k, .v = v } }, "rotation");
        _ = gui.trail(app, null);
        clay.close();
        gui.subhead(tx.get(tx.m_points));
        const no_bone = og.formats.mesh.no_bone;
        for (m.hold_modes, 0..) |h, i| {
            // Its name in the label's column, its bone, ×; then offset and angles.
            gui.fieldRowLead();
            if (gui.textField(app, idName(a, "msh_hold_name", i), h.name, 0, "")) |s| if (s.len > 0) setField(app, mesh, .{ .hold_name = .{ .i = i, .v = s } }, "attach point name");
            clay.close();
            gui.fieldRowValues();
            // Bone −1: a point in model space (ponton).
            const bone: f32 = if (h.bone == no_bone) -1 else @floatFromInt(h.bone);
            if (gui.numberField(app, a, idName(a, "msh_hold_bone", i), tx.get(tx.m_bone), bone, 0)) |v| setField(app, mesh, .{ .hold_bone = .{ .i = i, .v = if (v < 0) no_bone else @intFromFloat(@round(v)) } }, "attach point bone");
            if (gui.trail(app, clay.id(idName(a, "msh_hold_del", i)))) setField(app, mesh, .{ .hold_remove = i }, "attach point removed");
            clay.close();
            for (0..2) |part| {
                gui.fieldRow(tx.get(if (part == 0) tx.m_offset else tx.m_angles));
                for (0..3) |k| {
                    const p = part * 3 + k;
                    const pre = if (part == 0) xyz[k] else tx.alloc(a, tx.m_angle, .{xyz[k]});
                    if (gui.numberField(app, a, idName(a, idName(a, "msh_hold_p", i), p), pre, h.params[p], gui.cellWidth(3, true))) |v| setField(app, mesh, .{ .hold_param = .{ .i = i, .k = p, .v = v } }, if (part == 0) "attach point offset" else "attach point angles");
                }
                _ = gui.trail(app, null);
                clay.close();
            }
        }
        // The names the exe asks for (strcmp, 0x44c660), each once.
        gui.note(tx.get(tx.m_attach_hint));
        for (hold_names) |hn| {
            const taken = for (m.hold_modes) |h| {
                if (std.mem.eql(u8, h.name, hn)) break true;
            } else false;
            if (taken) continue;
            adds[n_adds] = hn;
            n_adds += 1;
        }
    }
    // The points to add, then the model to and from glTF.
    var labels: [hold_names.len + 2][]const u8 = undefined;
    for (adds[0..n_adds], 0..) |hn, k| labels[k] = tx.alloc(a, tx.m_attach_add, .{hn});
    var n = n_adds;
    if (idx != null) {
        labels[n] = tx.get(tx.b_glb_in);
        n += 1;
    }
    labels[n] = tx.get(tx.b_glb_out);
    const k = gui.footer(app, "msh_foot", labels[0 .. n + 1], null) orelse return;
    if (k < n_adds) return setField(app, mesh, .{ .hold_add = adds[k] }, "attach point added");
    const i = idx orelse return app.askFile(.{ .kind = .glb_out, .run = @import("look_pages.zig").onGlbOut, .name = mesh });
    app.askFile(if (k == n_adds) .{ .kind = .glb, .run = onGlbIn, .entry = i } else .{ .kind = .glb_out, .run = onGlbOut, .entry = i, .name = mesh });
}

/// The model block's header: its height and attach points (read again on an edit).
pub fn modelSummary(app: *App, a: Allocator, mesh: []const u8) []const u8 {
    var h = std.hash.Wyhash.init(app.store.rev);
    h.update(std.mem.asBytes(&app.catalog.gen));
    h.update(mesh);
    if (sum_cache.key != h.final()) {
        sum_cache.key = h.final();
        sum_cache.len = 0;
        var eb: [160]u8 = undefined;
        const f = app.store.file(common_archive, std.fmt.bufPrint(&eb, "gfx_3d\\{s}.msh", .{mesh}) catch return "") catch return "";
        var m = og.formats.mesh.parse(app.gpa, app.store.text(f)) catch return "";
        defer m.deinit();
        sum_cache.len = tx.print(&sum_cache.buf, tx.sum_model, .{ m.height, m.hold_modes.len }).len;
    }
    return a.dupe(u8, sum_cache.buf[0..sum_cache.len]) catch "";
}

var sum_cache: struct { key: u64 = 0, buf: [96]u8 = undefined, len: usize = 0 } = .{};

/// Model `mesh`'s height (its scale) as a character's row: the `.msh`'s, so every
/// character wearing the model (its own comes with a glb import or a texture).
pub fn heightRow(app: *App, a: Allocator, mesh: []const u8) void {
    var eb: [160]u8 = undefined;
    const f = app.store.file(common_archive, std.fmt.bufPrint(&eb, "gfx_3d\\{s}.msh", .{mesh}) catch return) catch return;
    var m = og.formats.mesh.parse(app.gpa, app.store.text(f)) catch return;
    defer m.deinit();
    gui.fieldRow(tx.get(tx.m_height));
    if (gui.numberField(app, a, "char_height", "", m.height, lay.width.number)) |v| setField(app, mesh, .{ .height = v }, "height");
    clay.close();
    gui.fieldNote(tx.alloc(a, tx.m_height_note, .{mesh}), theme.dim);
}

/// What the game does with an attach point of this name (exact).
const point_uses = [_]struct { []const u8, tx.Msg }{
    .{ "one_hand", tx.pu_hand }, .{ "two_hands", tx.pu_hand },  .{ "back", tx.pu_back },   .{ "hand", tx.pu_lift },
    .{ "kula1", tx.pu_ball },    .{ "kula2", tx.pu_ball },      .{ "paszcza", tx.pu_fx },  .{ "oko1", tx.pu_fx },
    .{ "oko2", tx.pu_fx },       .{ "chaingun", tx.pu_fx },     .{ "dmuchawa", tx.pu_fx }, .{ "t1", tx.pu_glow },
    .{ "t2", tx.pu_glow },       .{ "t3", tx.pu_glow },         .{ "t4", tx.pu_glow },     .{ "t5", tx.pu_glow },
    .{ "t6", tx.pu_glow },       .{ "default", tx.pu_default },
};

/// Attach point `name`'s uses on model `mesh`: by its name, a rider's (`pilot…`), the
/// spins of the own strikes of the enemies wearing the model.
fn pointUses(app: *App, a: Allocator, mesh: []const u8, name: []const u8) []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (point_uses) |u| if (std.ascii.eqlIgnoreCase(u[0], name)) out.append(a, tx.get(u[1])) catch {};
    if (std.ascii.startsWithIgnoreCase(name, "pilot")) out.append(a, tx.get(tx.pu_rider)) catch {};
    for (app.catalog.entries.items) |e| {
        if (e.kind != .enemy) continue;
        const text = app.store.text(fileOf(app, e) orelse continue);
        if (!std.ascii.eqlIgnoreCase(entries.meshOf(app, e, text) orelse "", mesh)) continue;
        for (ea.ownStrikes(app, a, e, text)) |st| if (og.core.modules.fighterStrike(st.special)) |fs| for (fs.spins) |sp| {
            if (!std.ascii.eqlIgnoreCase(sp.link, name)) continue;
            const u = tx.alloc(a, tx.pu_spin, .{st.special});
            for (out.items) |o| {
                if (std.mem.eql(u8, o, u)) break;
            } else out.append(a, u) catch {};
        };
    }
    if (out.items.len == 0) return tx.get(tx.pu_none);
    return std.mem.join(a, ", ", out.items) catch "";
}

/// The line under the Model page's preview about the attach point picked: its name, its
/// uses, how it moves (dragged; OpenGorky only).
pub fn pointInfo(app: *App, a: Allocator, mesh: []const u8) ?[]const u8 {
    const i = app.points.sel orelse return null;
    const m = app.preview.modelOf(app.gpa, app.io, app.dat, .{ .ctx = app, .get = overlayGet }, mesh) orelse return null;
    if (i >= m.mesh.hold_modes.len) return null;
    const name = m.mesh.hold_modes[i].name;
    return tx.alloc(a, tx.pt_info, .{ name, pointUses(app, a, mesh, name), tx.get(if (app.ogLayout()) tx.pt_drag else tx.pt_locked) });
}

/// Model `mesh`'s attach points as handles over the preview (the Model page): one clicked
/// is picked (pointInfo), dragged it moves in the picture's plane (OpenGorky; its offset
/// written on release, one undo step).
pub fn pointHandles(app: *App, mesh: []const u8) void {
    const pv = &app.preview;
    const key = std.hash.Wyhash.hash(0, mesh);
    if (app.points.mesh != key) app.points = .{ .mesh = key };
    // Last drawn of this model.
    const shown = pv.key_buf[0..pv.key_len];
    if (!(std.ascii.startsWithIgnoreCase(shown, mesh) and shown.len > mesh.len and shown[mesh.len] == '/')) return;
    const m = pv.modelOf(app.gpa, app.io, app.dat, .{ .ctx = app, .get = overlayGet }, mesh) orelse return;
    const pid = clay.id("preview_img");
    const r = lay.space.md;
    for (pv.points) |p| {
        if (p.i >= m.mesh.hold_modes.len) continue;
        const sel = app.points.sel == p.i;
        const at = if (sel) if (app.points.drag) |from| [2]f32{ p.at[0] + app.mouse[0] - from[0], p.at[1] + app.mouse[1] - from[1] } else p.at else p.at;
        const hid = clay.idi("msh_point", @intCast(p.i));
        clay.open(.{ .id = hid, .layout = .{ .childGap = lay.space.xs, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .floating = .{ .offset = .{ .x = at[0] - r / 2, .y = at[1] - r / 2 }, .attachTo = ui.CLAY_ATTACH_TO_ELEMENT_WITH_ID, .parentId = pid.id, .clipTo = ui.CLAY_CLIP_TO_ATTACHED_PARENT, .zIndex = 4 } });
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(r), .height = clay.fixed(r) } }, .backgroundColor = if (sel) theme.warn else theme.accent_hover, .cornerRadius = clay.radius(r / 2), .border = .{ .color = theme.text, .width = .{ .left = lay.border.line, .right = lay.border.line, .top = lay.border.line, .bottom = lay.border.line } } });
        if (sel or clay.pointerOver(hid)) gui.txt(m.mesh.hold_modes[p.i].name, .caption, theme.text, font_mod.bold);
        clay.close();
        if (clay.pointerOver(hid) and app.clicked) {
            // Picked, not turning the model.
            app.turning = null;
            app.points.sel = p.i;
            if (app.ogLayout()) app.points.drag = app.mouse;
        }
    }
    const from = app.points.drag orelse return;
    if (app.down) return;
    app.points.drag = null;
    const d = [2]f32{ app.mouse[0] - from[0], app.mouse[1] - from[1] };
    if (d[0] == 0 and d[1] == 0) return;
    for (pv.points) |p| if (p.i == app.points.sel) return movePoint(app, mesh, p, d);
}

/// Attach point `p` of model `mesh` moved `d` pixels on the preview (preview.offsetFor).
fn movePoint(app: *App, mesh: []const u8, p: preview.Point, d: [2]f32) void {
    if (!app.ogLayout()) return app.failed(error.ClassicProject);
    setField(app, mesh, .{ .hold_move = .{ .i = p.i, .d = preview.offsetFor(p.d, d) } }, "attach point moved");
}

/// `--point MESH I` (shots): model `MESH`'s page with attach point I picked;
/// `--point-drag MESH I DX,DY`: then dragged DX, DY pixels on the preview, as by the mouse.
pub fn pointOp(app: *App, mesh: []const u8, i: usize, drag: ?[2]f32) !void {
    @import("doctabs.zig").show(app, .models, mesh);
    app.points = .{ .mesh = std.hash.Wyhash.hash(0, mesh), .sel = i };
    const d = drag orelse return;
    for (app.preview.points) |p| if (p.i == i) return movePoint(app, mesh, p, d);
    return error.NoAttachPoint;
}

/// Attach point names the game uses: the weapon in the hand (actors.zig setLink).
const hold_names = [_][]const u8{ "one_hand", "two_hands", "default" };

fn setField(app: *App, mesh: []const u8, f: art.MeshField, what: []const u8) void {
    art.setMeshField(app, mesh, f, what) catch |err| return app.failed(err);
    app.setStatus(tx.st_mesh_set, .{ mesh, what });
}

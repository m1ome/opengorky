//! A fighter's (or a weapon's) look on its page: the model with its animations, a frame
//! slider and each animation's sounds on a timeline; a weapon shown struck by a hero.

const std = @import("std");
const picked = @import("pages.zig").picked;
const actOf = @import("pages.zig").actOf;
const idName = @import("pages.zig").idName;
const fileOf = @import("pages.zig").fileOf;
const overlayGet = @import("pages.zig").overlayGet;
const entryById = @import("pages.zig").entryById;
const smallButton = @import("pages.zig").smallButton;
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const vars = @import("vars.zig");
const catalog = @import("catalog.zig");
const common_archive = @import("store.zig").common_archive;
const preview = @import("preview.zig");
const sounds = @import("sounds.zig");
const soundpage = @import("soundpage.zig");
const search = @import("search.zig");
const og = @import("opengorky");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;
const Picker = main.Picker;
const pages = @import("pages.zig");
const art = @import("art.zig");
const textedit = @import("textedit.zig");
const numBox = @import("paint_camera.zig").numBox;

/// What the preview shows: an actor script's model (`meshFile`) in the chosen
/// animation (logical slot and file animation), drawn this frame.
pub const Look = struct { list: []const preview.Anim, slot: []const u8, file: []const u8, mesh: []const u8, tex: ?*anyopaque };

/// `want`: this animation slot instead of the one picked (a weapon's attack);
/// `held`: a weapon in the hand.
/// `riders`: fighters riding it (catalog.Rider).
pub fn look(app: *App, a: Allocator, act_text: []const u8, want: ?[]const u8, held: ?preview.Held, riders: []const catalog.Rider) Look {
    const list_ = preview.anims(a, act_text);
    // None picked yet: the long attack, as the game shows it most.
    var slot: []const u8 = want orelse if (app.anim_name.len > 0) app.anim_name.get() else "long_attack";
    const file = for (list_) |an| {
        if (std.mem.eql(u8, an.slot, slot)) break an.file;
    } else if (list_.len > 0) blk: {
        slot = list_[0].slot;
        break :blk list_[0].file;
    } else "";
    const mesh = vars.getStr(act_text, "meshFile") orelse "";
    const tex = app.preview.draw(app.gpa, app.io, app.dat, app.r, .{ .ctx = app, .get = overlayGet }, mesh, file, held, ridersOn(app, a, riders, slot));
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
        on.append(a, .{ .mesh = vars.getStr(rt, "meshFile") orelse continue, .link = rd.point, .anim = idle, .act = act }) catch {};
    }
    return on.items;
}

/// A hero striking with a weapon: the hero's script, the animation slot, the weapon in
/// hand and a line about it.
pub const Strike = struct { hero_text: []const u8, slot: []const u8, held: ?preview.Held, info: []const u8 };

pub fn strikeOf(app: *App, a: Allocator, text: []const u8) ?Strike {
    const heroes = heroEntries(app, a);
    if (heroes.len == 0) return null;
    const hi = heroes[@min(app.attack_hero, heroes.len - 1)];
    const hf = fileOf(app, app.catalog.entries.items[hi]) orelse return null;
    const ht = app.store.text(hf);
    const hero_id: i32 = @intFromFloat(vars.get(ht, "nameID") orelse 0);
    const weapon_id: i32 = @intFromFloat(vars.get(text, "nameID") orelse 0);
    const at = og.battle.attacks.heroAttack(hero_id, weapon_id);
    const two = (vars.get(text, "two_handed") orelse 0) == 1;
    // Two-handed: the stance-1 animation (`attack_rifle/1` → g_rifle) if the hero has it.
    var slot: []const u8 = at.anim;
    if (two) {
        const s1 = std.fmt.allocPrint(a, "{s}/1", .{at.anim}) catch at.anim;
        for (preview.anims(a, ht)) |an| if (std.mem.eql(u8, an.slot, s1)) {
            slot = s1;
        };
    }
    const wait: i32 = @as(i32, @intCast(at.wait)) + at.extra;
    // What the exe shows of the strike by the weapon's effects id: the flash, projectile
    // and hit (fx/hits.zig, fx/launch.zig), at the hit's frame.
    const fx_id = @import("preview_fx.zig").fxId(app.gpa, weapon_id, @intFromFloat(vars.get(text, "fx_as") orelse 0), vars.getStr(text, "projectile"));
    const strike: @import("preview_fx.zig").Strike = .{ .fx = fx_id, .hero = hero_id, .hit = og.combat.anim.hitFrame(@intCast(@max(0, wait))), .pre = if (at.pre) |p| og.combat.anim.hitFrame(p) else null };
    const held: ?preview.Held = if (vars.getStr(text, "meshFile")) |m| .{ .mesh = m, .link = if (two) "two_hands" else "one_hand", .strike = strike } else null;
    return .{ .hero_text = ht, .slot = slot, .held = held, .info = tx.alloc(a, tx.atk_info, .{ slot, wait, tx.get(if (two) tx.atk_two else tx.atk_one) }) };
}

/// Catalog indices of the heroes able to strike.
fn heroEntries(app: *App, a: Allocator) []const usize {
    var out: std.ArrayList(usize) = .empty;
    for (app.catalog.entries.items, 0..) |e, i| {
        if (e.kind != .hero) continue;
        // Only those with strikes (the party; not the monitors or the girl).
        const f = fileOf(app, e) orelse continue;
        if (std.ascii.findIgnoreCase(app.store.text(f), "\"attack_") == null) continue;
        out.append(a, i) catch {};
    }
    return out.items;
}

/// Bottom left on a weapon's page: who strikes with it in the preview.
pub fn heroList(app: *App, a: Allocator) void {
    clay.openScroll(.{ .id = clay.id("atk_heroes"), .layout = .{ .sizing = .{ .width = clay.fixed(app.split(.entry_x)), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 8, .top = 4 } } });
    txt(tx.get(tx.atk_who), 13, theme.dim, font_mod.bold);
    for (heroEntries(app, a), 0..) |hi, k| {
        const e = app.catalog.entries.items[hi];
        const sel = k == @min(app.attack_hero, heroEntries(app, a).len - 1);
        const bid = clay.idi("atk_hero", @intCast(k));
        if (main.clickable(app, .{
            .id = bid,
            .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(24) }, .padding = .{ .left = 10, .right = 8 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
            .backgroundColor = theme.bg,
        }, sel)) app.attack_hero = k;
        txt(if (e.title.len > 0) e.title else e.id, 14, theme.text, if (sel) font_mod.bold else font_mod.regular);
        txt(e.id, 12, theme.dim, font_mod.regular);
        clay.close();
    }
    clay.close();
}

/// The model, square in the top-right part; dragging it turns it.
pub fn modelPane(app: *App, l: Look, info: ?[]const u8) void {
    // The square as large as the area allows (by last frame's layout), centred.
    const area = clay.box(clay.id("model_area"));
    // The height less the buttons above (~40) and the two lines under it (~44) and padding.
    const side = if (area) |b| @max(160, @min(b.width - 24, b.height - 120)) else @max(160, app.split(.entry_y) - 130);
    // Clipped: the square never widens the area it was sized from (else each frame grew it).
    clay.open(.{ .id = clay.id("model_area"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .top = 10, .bottom = 8 }, .childGap = 6, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER } }, .backgroundColor = theme.viewport, .clip = .{ .horizontal = true, .vertical = true } });
    // Over the model: back to the starting angle.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = 10, .right = 10 }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    // Playback: a frame back, play / pause, a frame on, where it is.
    const pv = &app.preview;
    if (main.toolButton(app, "preview_back", .skip_back, "", false, false)) pv.step(-1);
    if (main.toolButton(app, "preview_play", if (pv.paused == null) .pause else .play, "", pv.paused != null, false)) pv.togglePause();
    if (main.toolButton(app, "preview_next", .skip_forward, "", false, false)) pv.step(1);
    txt(std.fmt.allocPrint(app.frame.allocator(), "{d} / {d}", .{ pv.at + 1, pv.frames }) catch "", 12, theme.dim, font_mod.regular);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    if (main.toolButton(app, "preview_tex", .image, tx.get(tx.pv_texture), !app.preview.wire, false)) app.preview.wire = false;
    if (main.toolButton(app, "preview_wire", .box, tx.get(tx.pv_wire), app.preview.wire, false)) app.preview.wire = true;
    if (main.toolButton(app, "preview_reset", .undo_2, tx.get(tx.pv_reset), false, false)) app.preview.yaw = 210;
    clay.close();
    clay.leaf(.{ .id = clay.id("preview_img"), .layout = .{ .sizing = .{ .width = clay.fixed(side), .height = clay.fixed(side) } }, .image = .{ .imageData = l.tex } });
    if (info) |s| txt(s, 13, theme.text, font_mod.regular);
    txt(tx.get(if (l.tex == null) tx.no_model else if (info != null) tx.atk_hint else tx.anim_hint), 13, if (l.tex == null) theme.warn else theme.dim, font_mod.regular);
    clay.close();
}

/// The animations the actor script registers (bottom left); a click shows one.
pub fn animList(app: *App, l: Look) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM }, .backgroundColor = theme.panel });
    main.panelHeader(tx.alloc(app.frame.allocator(), tx.part_anims_n, .{l.list.len}));
    // The search (as the concept's): by slot and file name.
    const q = app.anim_query.get();
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = 8, .right = 8, .top = 6, .bottom = 6 } } });
    const sid = clay.id("anim_search");
    clay.open(.{ .id = sid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(28) }, .padding = .{ .left = 8, .right = 8 }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.field, .cornerRadius = clay.radius(theme.radius), .border = .{ .color = if (app.anim_focus) theme.accent else theme.field_border, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } } });
    if (clay.hovered() and app.clicked) app.anim_focus = true;
    @import("icons.zig").leaf(app.r, app.gpa, .search, 14, theme.dim);
    if (q.len > 0 or app.anim_focus) txt(std.fmt.allocPrint(app.frame.allocator(), "{s}{s}", .{ q, if (app.anim_focus) "|" else "" }) catch q, 13, theme.text, font_mod.regular) else txt(tx.get(tx.anim_search), 13, theme.dim, font_mod.regular);
    clay.close();
    clay.close();
    clay.openScroll(.{ .id = clay.id("anims"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .top = 2 } } });
    for (l.list, 0..) |an, i| {
        if (!@import("search.zig").matches(q, &.{ an.slot, an.file })) continue;
        const sel = std.mem.eql(u8, an.slot, l.slot);
        const bid = clay.idi("anim", @intCast(i));
        if (main.clickable(app, .{
            .id = bid,
            .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(24) }, .padding = .{ .left = 10, .right = 8 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
            .backgroundColor = theme.panel,
        }, sel)) app.anim_name.set(an.slot);
        txt(an.slot, 14, theme.text, if (sel) font_mod.bold else font_mod.regular);
        if (!std.mem.eql(u8, an.slot, an.file)) txt(an.file, 12, theme.dim, font_mod.regular);
        clay.close();
    }
    clay.close();
    clay.close();
}

/// The frame sounds of the animation shown (`.ani` of the model): played with the
/// preview; each can be moved by frames, swapped or removed, and new ones added.
pub fn soundsBlock(app: *App, a: Allocator, mesh: []const u8, anim_file: []const u8) void {
    var l = sounds.load(app, mesh) orelse return;
    defer l.list.deinit();
    const ai = for (l.list.items, 0..) |an, i| {
        if (std.ascii.eqlIgnoreCase(an.name, anim_file)) break i;
    } else if (l.list.items.len > 0) 0 else return;
    const an = l.list.items[ai];
    app.player.frames(app, an, app.preview.prev, app.preview.frame);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 2 }, .backgroundColor = theme.panel });
    // The title bar, as the other parts': the animation, the frame shown, sound on/off.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(30) }, .padding = .{ .left = 12, .right = 8 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.header, .border = .{ .color = theme.line, .width = .{ .bottom = 1 } } });
    txt(tx.alloc(a, tx.snd_title, .{ an.name, app.preview.frame -| an.first, an.last - an.first }), 12, theme.dim, font_mod.bold);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    if (smallButton(app, "snd_mute", tx.get(if (app.player.muted) tx.snd_off else tx.snd_on), theme.dim)) app.player.muted = !app.player.muted;
    clay.close();
    const r = struct {
        fn op(ap: *App, file: usize, i: usize, o: sounds.Op) void {
            sounds.edit(ap, file, i, o) catch |err| ap.setStatus(tx.st_set_failed, .{err});
        }
    };
    // Choosing a sound (a new one or for a cue): the list here, with search.
    if (app.picker) |p| if (p.what == .sound and p.file == l.file) {
        soundChooser(app, a, p);
        clay.close();
        return;
    };
    timeline(app, a, an, l.file, ai);
    clay.openScroll(.{ .id = clay.id("snd_rows"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 2 } });
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
        const rid = clay.idi("snd", id);
        _ = main.clickable(app, .{
            .id = rid,
            .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(24) }, .padding = .{ .left = 8, .right = 4 }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
            .backgroundColor = theme.bg,
        }, false);
        txt(tx.alloc(a, tx.snd_frame, .{cue.frame -| an.first}), 13, theme.dim, font_mod.regular);
        const nid = clay.idi("snd_name", id);
        clay.open(.{ .id = nid, .layout = .{ .sizing = .{ .width = clay.grow() } } });
        if (clay.hovered() and app.clicked) app.picker = .{ .what = .sound, .file = l.file, .anim = ai, .cue = k };
        txt(cue.name, 13, if (clay.pointerOver(nid)) theme.accent_hover else theme.text, font_mod.regular);
        clay.close();
        if (smallButton(app, idName(a, "snd_play", k), tx.get(tx.snd_play), theme.accent_hover)) app.player.play(app, cue.name);
        if (smallButton(app, idName(a, "snd_m10", k), "«", theme.dim)) r.op(app, l.file, ai, .{ .move = .{ .i = k, .d = -10 } });
        if (smallButton(app, idName(a, "snd_m1", k), "<", theme.dim)) r.op(app, l.file, ai, .{ .move = .{ .i = k, .d = -1 } });
        if (smallButton(app, idName(a, "snd_p1", k), ">", theme.dim)) r.op(app, l.file, ai, .{ .move = .{ .i = k, .d = 1 } });
        if (smallButton(app, idName(a, "snd_p10", k), "»", theme.dim)) r.op(app, l.file, ai, .{ .move = .{ .i = k, .d = 10 } });
        if (smallButton(app, idName(a, "snd_del", k), "×", theme.warn)) r.op(app, l.file, ai, .{ .remove = k });
        clay.close();
    }
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = 8, .top = 2 }, .childGap = 8 } });
    if (smallButton(app, "snd_add", tx.get(tx.snd_add), theme.accent_hover)) app.picker = .{ .what = .sound, .file = l.file, .anim = ai };
    clay.close();
    clay.close();
    clay.text(tx.alloc(a, tx.snd_shared, .{mesh}), .{ .textColor = theme.dim, .fontSize = 11, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    clay.close();
}

/// The animation's frames as a ruler (as the concept's timeline): every 5th numbered,
/// the frame shown marked, each sound a marker at its frame — dragged to another frame
/// (one undo step on release).
fn timeline(app: *App, a: Allocator, an: og.formats.anim.Animation, file: usize, ai: usize) void {
    const n: u32 = an.last - an.first + 1;
    const tid = clay.id("snd_timeline");
    const w = if (clay.box(tid)) |b| b.width - 24 else 400;
    const step = w / @as(f32, @floatFromInt(@max(1, n - 1)));
    const xOf = struct {
        fn f(fr: u32, st: f32) f32 {
            return 12 + @as(f32, @floatFromInt(fr)) * st;
        }
    }.f;
    clay.open(.{ .id = tid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(78) } }, .backgroundColor = theme.field, .border = .{ .color = theme.line, .width = .{ .bottom = 1 } } });
    const over = clay.hovered();
    var fr: u32 = 0;
    while (fr < n) : (fr += 1) {
        const major = fr % 5 == 0;
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(1), .height = clay.fixed(if (major) 12 else 6) } }, .backgroundColor = theme.field_border, .floating = .{ .offset = .{ .x = xOf(fr, step), .y = 18 }, .attachTo = ui.CLAY_ATTACH_TO_PARENT } });
        if (major and (step >= 4 or fr % 10 == 0)) {
            clay.open(.{ .floating = .{ .offset = .{ .x = xOf(fr, step) - 4, .y = 2 }, .attachTo = ui.CLAY_ATTACH_TO_PARENT } });
            txt(std.fmt.allocPrint(a, "{d}", .{fr}) catch "", 11, theme.dim, font_mod.regular);
            clay.close();
        }
    }
    // The frame the preview shows.
    const cur = app.preview.frame -| an.first;
    if (cur < n) clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(2), .height = clay.fixed(60) } }, .backgroundColor = theme.accent, .floating = .{ .offset = .{ .x = xOf(cur, step) - 1, .y = 16 }, .attachTo = ui.CLAY_ATTACH_TO_PARENT, .zIndex = 2 } });
    for (an.sounds, 0..) |cue, k| {
        const dragging = if (app.cue_drag) |d| d.cue == k else false;
        const f = if (dragging) app.cue_drag.?.frame else cue.frame -| an.first;
        const mid = clay.idi("snd_mark", @intCast(k));
        clay.open(.{ .id = mid, .layout = .{ .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER }, .childGap = 2 }, .floating = .{ .offset = .{ .x = xOf(f, step) - 7, .y = 36 }, .attachTo = ui.CLAY_ATTACH_TO_PARENT, .zIndex = 3 } });
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(14), .height = clay.fixed(14) } }, .backgroundColor = if (dragging) theme.warn else theme.accent_hover, .cornerRadius = clay.radius(3) });
        // A name only where no earlier cue sits close (the list below names them all).
        const crowded = for (an.sounds[0..k]) |o| {
            if (@abs(@as(f32, @floatFromInt(o.frame)) - @as(f32, @floatFromInt(cue.frame))) * step < 50) break true;
        } else false;
        if (!crowded) txt(std.fs.path.stem(cue.name), 10, theme.dim, font_mod.regular);
        clay.close();
        if (clay.pointerOver(mid) and app.clicked) app.cue_drag = .{ .file = file, .anim = ai, .cue = k, .frame = f };
    }
    clay.close();
    // A marker being dragged follows the pointer by frame; on release the move is made.
    if (app.cue_drag) |*d| if (d.file == file and d.anim == ai) {
        const b = clay.box(tid) orelse return;
        const x = app.mouse[0] - b.x - 12;
        d.frame = @intFromFloat(std.math.clamp(@round(x / step), 0, @as(f32, @floatFromInt(n - 1))));
        if (!app.down) {
            const was = an.sounds[d.cue].frame -| an.first;
            const delta: i32 = @as(i32, @intCast(d.frame)) - @as(i32, @intCast(was));
            const k = d.cue;
            app.cue_drag = null;
            if (delta != 0) sounds.edit(app, file, ai, .{ .move = .{ .i = k, .d = delta } }) catch |err| app.setStatus(tx.st_set_failed, .{err});
        }
    };
    _ = over;
}

/// `--sound ID ANIM ACTION` (checks): enemy `ID` shown in its animation `ANIM` (file
/// name, `atak`); ACTION `+NAME` adds, `K=NAME` swaps, `K>D` moves by D frames, `-K` removes.
pub fn soundOp(app: *App, id: []const u8, anim_file: []const u8, action: []const u8) !void {
    const i = try entryById(app, id);
    app.entry = i;
    const text = app.store.text(fileOf(app, app.catalog.entries.items[i]) orelse return error.NoFile);
    var buf: [128]u8 = undefined;
    const act = app.store.text(try app.store.file(common_archive, try std.fmt.bufPrint(&buf, "classes\\{s}", .{actOf(text) orelse return error.NoLook})));
    for (preview.anims(app.frame.allocator(), act)) |an| if (std.ascii.eqlIgnoreCase(an.file, anim_file)) app.anim_name.set(an.slot);
    if (action.len == 0) return;
    var l = sounds.load(app, vars.getStr(act, "meshFile") orelse return error.NoModel) orelse return error.NoAni;
    defer l.list.deinit();
    const ai = for (l.list.items, 0..) |an, k| {
        if (std.ascii.eqlIgnoreCase(an.name, anim_file)) break k;
    } else return error.NoAnimation;
    // `?`: the sound list open for a new one (screenshots).
    if (action[0] == '?') {
        app.picker = .{ .what = .sound, .file = l.file, .anim = ai };
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

/// The sounds to put on a frame (common/sound.dat and the imported ones), searched by
/// name; a click plays one and puts it on.
fn soundChooser(app: *App, a: Allocator, p: Picker) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    txt(tx.get(if (p.cue == null) tx.snd_choose_new else tx.snd_choose), 13, theme.text, font_mod.bold);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    if (smallButton(app, "snd_cancel", tx.get(tx.cancel), theme.warn)) app.picker = null;
    clay.close();
    main.searchField(app, a);
    clay.openScroll(.{ .id = clay.id("snd_pick"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    var shown: usize = 0;
    for (app.player.names(app, a), 0..) |n, i| {
        if (!search.matches(app.query(), &.{n})) continue;
        // shortcut: 300 rows at most; the search narrows the rest.
        shown += 1;
        if (shown > 300) break;
        const oid = clay.idi("snd_opt", @intCast(i));
        if (main.clickable(app, .{
            .id = oid,
            .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(24) }, .padding = .{ .left = 8, .right = 8 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
            .backgroundColor = theme.bg,
        }, false)) picked(app, p, n);
        txt(n, 13, theme.text, font_mod.regular);
        if (app.store.find(soundpage.archive_path, n) != null) txt(tx.get(tx.new), 12, theme.accent_hover, font_mod.regular);
        clay.close();
    }
    if (shown == 0) txt(tx.get(tx.snd_none), 13, theme.dim, font_mod.regular);
    clay.close();
}

// The model as glTF and its own fields: file dialog answers for entry `ask.entry`
// (as pages.zig onTextureIn), the import a new model the entry then uses.
pub fn onGlbOut(app: *App, ask: main.FileAsk, path: []const u8) !void {
    const e = app.catalog.entries.items[ask.entry];
    const text = app.store.text(fileOf(app, e) orelse return);
    try art.exportGlb(app, pages.meshOf(app, e, text) orelse return error.NoModel, path);
    app.setStatus(tx.st_glb_out, .{path});
}
pub fn onGlbIn(app: *App, ask: main.FileAsk, path: []const u8) !void {
    const e = app.catalog.entries.items[ask.entry];
    const file = fileOf(app, e) orelse return;
    const text = app.store.text(file);
    const r = art.importGlb(app, pages.meshOf(app, e, text) orelse return error.NoModel, path) catch |err| return glbFailed(app, err);
    // As a new look: an enemy through a copy of its act_*.ss, the rest by meshFile.
    if (e.kind == .enemy) try pages.setAct(app, file, try art.newAct(app, actOf(text) orelse return error.NoLook, r.name)) else try pages.setString(app, file, "meshFile", r.name);
    app.setStatus(tx.st_glb_in, .{ r.name, r.textures });
}
pub fn onAnimsIn(app: *App, ask: main.FileAsk, path: []const u8) !void {
    const e = app.catalog.entries.items[ask.entry];
    const text = app.store.text(fileOf(app, e) orelse return);
    const mesh = pages.meshOf(app, e, text) orelse return error.NoModel;
    const a = app.frame.allocator();
    const r = art.importAnims(app, a, mesh, path) catch |err| return glbFailed(app, err);
    const none = "—";
    const added = if (r.added.len > 0) std.mem.join(a, ", ", r.added) catch none else none;
    const replaced = if (r.replaced.len > 0) std.mem.join(a, ", ", r.replaced) catch none else none;
    app.setStatus(tx.st_anims_in, .{ mesh, r.added.len, added, r.replaced.len, replaced });
}

/// Import errors (the exe's limits, gltf.zig) said plainly.
const glb_errors = [_]struct { []const u8, tx.Msg }{
    .{ "TooManyVertices", tx.glb_verts },  .{ "TooManyTriangles", tx.glb_verts }, .{ "BadTriangle", tx.glb_tri },
    .{ "NameTooLong", tx.glb_name },       .{ "StringTooLong", tx.glb_name },     .{ "BadBone", tx.glb_bone },
    .{ "BadAttachBone", tx.glb_bone },     .{ "BonesMismatch", tx.glb_skel },     .{ "SkeletonMismatch", tx.glb_skel },
    .{ "TooManyInfluences", tx.glb_skin }, .{ "SeveralSkins", tx.glb_skin },      .{ "NotGlb", tx.glb_file },
    .{ "BadGlb", tx.glb_file },            .{ "ExternalBuffer", tx.glb_file },    .{ "ExternalImage", tx.glb_file },
    .{ "AnimOutOfRange", tx.glb_anim },
};

fn glbFailed(app: *App, err: anyerror) void {
    const why = for (glb_errors) |ge| {
        if (std.mem.eql(u8, ge[0], @errorName(err))) break ge[1];
    } else tx.glb_other;
    app.setStatus(tx.st_glb_failed, .{ tx.get(why), err });
}

/// Under the look: the model to and from glTF, then its height, centre and attach
/// points (the `.msh` itself: every entry with this model has them).
pub fn modelFields(app: *App, a: Allocator, idx: usize, mesh: []const u8) void {
    pages.artButtons(app, idx, &.{.{ tx.b_glb_out, .glb_out, onGlbOut }}, null);
    pages.artButtons(app, idx, &.{ .{ tx.b_glb_in, .glb, onGlbIn }, .{ tx.b_anims_in, .glb, onAnimsIn } }, null);
    var eb: [160]u8 = undefined;
    const f = app.store.file(common_archive, std.fmt.bufPrint(&eb, "gfx_3d\\{s}.msh", .{mesh}) catch return) catch return;
    var m = og.formats.mesh.parse(app.gpa, app.store.text(f)) catch return;
    defer m.deinit();
    const xyz = [_][]const u8{ "X", "Y", "Z" };
    pages.rowOpen(tx.get(tx.m_height));
    if (numBox(app, a, "msh_height", "", m.height, 0)) |v| setField(app, mesh, .{ .height = v }, "height");
    clay.close();
    pages.rowOpen(tx.get(tx.m_center));
    for (0..3) |k| if (numBox(app, a, idName(a, "msh_center", k), xyz[k], m.center[k], 0)) |v| setField(app, mesh, .{ .center = .{ .k = k, .v = v } }, "center");
    clay.close();
    if (m.hold_modes.len == 0) return;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = 12, .top = 6, .bottom = 2 } } });
    txt(tx.get(tx.m_attach), 13, theme.dim, font_mod.regular);
    clay.close();
    const no_bone = og.formats.mesh.no_bone;
    for (m.hold_modes, 0..) |h, i| {
        const row: clay.Decl = .{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = 12, .right = 12, .top = 2 }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } };
        clay.open(row);
        if (textedit.field(app, idName(a, "msh_hold_name", i), h.name, 0, "")) |s| if (s.len > 0) setField(app, mesh, .{ .hold_name = .{ .i = i, .v = s } }, "attach point name");
        // Bone −1: a point in model space (ponton).
        const bone: f32 = if (h.bone == no_bone) -1 else @floatFromInt(h.bone);
        if (numBox(app, a, idName(a, "msh_hold_bone", i), tx.get(tx.m_bone), bone, 110)) |v| setField(app, mesh, .{ .hold_bone = .{ .i = i, .v = if (v < 0) no_bone else @intFromFloat(@round(v)) } }, "attach point bone");
        clay.close();
        for (0..2) |part| {
            clay.open(row);
            for (0..3) |k| {
                const p = part * 3 + k;
                const pre = if (part == 0) xyz[k] else tx.alloc(a, tx.m_angle, .{xyz[k]});
                if (numBox(app, a, idName(a, idName(a, "msh_hold_p", i), p), pre, h.params[p], 0)) |v| setField(app, mesh, .{ .hold_param = .{ .i = i, .k = p, .v = v } }, if (part == 0) "attach point offset" else "attach point angles");
            }
            clay.close();
        }
    }
}

fn setField(app: *App, mesh: []const u8, f: art.MeshField, what: []const u8) void {
    art.setMeshField(app, mesh, f, what) catch |err| return app.setStatus(tx.st_set_failed, .{err});
    app.setStatus(tx.st_mesh_set, .{ mesh, what });
}

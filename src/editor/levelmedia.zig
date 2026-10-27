//! The open level's pictures and sounds beside its objects: its `sprite.dat` sprites and
//! its music (common/voice.dat, as the exe picks it) and the sounds of common/sound.dat
//! its scripts and scenes name (`PlaySound("door")`, `SOUND("wheel")`; fighters' blows
//! stay with the fighters), each with who names it (`spriteFile="woda1"` in `water2.ba`). Found
//! once per loaded level and edit; both groups start folded (they are rarely wanted).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const og = @import("opengorky");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const icons = @import("icons.zig");
const sprview = @import("sprview.zig");
const voices = @import("voices.zig");
const scenes = @import("scenes.zig");
const level = @import("level.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;
const refs = @import("refs.zig");
const common_archive = @import("store.zig").common_archive;

/// A sprite or sound and the scripts naming it (", "-joined; "" — none); `music`: a
/// track of common/voice.dat (`by` says when it plays).
const Use = struct { name: []const u8, by: []const u8, music: bool = false };

pub const Media = struct {
    arena: std.heap.ArenaAllocator,
    /// The doc and Store state it was found for.
    doc: *const level.Doc,
    name: []const u8,
    steps: usize,
    sprites: []const Use = &.{},
    sounds: []const Use = &.{},

    pub fn deinit(self: *Media) void {
        self.arena.deinit();
    }
};

/// The level's media, found again when the level or the Store changed.
fn get(app: *App, d: *level.Doc) ?*Media {
    if (app.level_media) |*m| {
        // The same doc (by address and level: a new one may reuse the address) and edits.
        if (m.doc == d and std.mem.eql(u8, m.name, d.name) and m.steps == app.store.undo.items.len) return m;
        m.deinit();
        app.level_media = null;
    }
    app.level_media = find(app, d) catch return null;
    return &app.level_media.?;
}

fn find(app: *App, d: *level.Doc) !Media {
    var m: Media = .{ .arena = .init(app.gpa), .doc = d, .name = d.name, .steps = app.store.undo.items.len };
    errdefer m.deinit();
    const a = m.arena.allocator();
    // The texts that may name them: the level's scripts and the scenes they start.
    var texts: std.ArrayList(struct { who: []const u8, text: []const u8 }) = .empty;
    for (refs.files(app, a, d.level_archive, refs.script)) |f| try texts.append(a, .{ .who = f.name, .text = f.text });
    var started: std.ArrayList([]const u8) = .empty;
    for (texts.items) |t| for (app.catalog.scenes.items) |sc| {
        const cs = scenes.calls(a, t.text, sc.name) catch continue;
        // Each scene once (a level may start one from several places).
        if (cs.len > 0 and for (started.items) |x| {
            if (x.ptr == sc.name.ptr) break false;
        } else true) try started.append(a, sc.name);
    };
    for (started.items) |sc| {
        var eb: [96]u8 = undefined;
        const f = app.store.file(common_archive, std.fmt.bufPrint(&eb, "scriptlets\\{s}.scr", .{sc}) catch continue) catch continue;
        try texts.append(a, .{ .who = try std.fmt.allocPrint(a, "{s}.scr", .{sc}), .text = app.store.text(f) });
    }
    const quoted = struct {
        /// Who names `name` (with or without its extension) in quotes, ", "-joined.
        fn users(al: Allocator, ts: anytype, name: []const u8) []const u8 {
            const stem = name[0 .. std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len];
            var out: std.ArrayList(u8) = .empty;
            for (ts) |t| {
                var pos: usize = 0;
                const hit = while (std.mem.indexOfScalarPos(u8, t.text, pos, '"')) |q| {
                    const e = std.mem.indexOfScalarPos(u8, t.text, q + 1, '"') orelse break false;
                    pos = e + 1;
                    const s = t.text[q + 1 .. e];
                    if (std.ascii.eqlIgnoreCase(s, stem) or std.ascii.eqlIgnoreCase(s, name)) break true;
                } else false;
                if (!hit) continue;
                if (out.items.len > 0) out.appendSlice(al, ", ") catch {};
                out.appendSlice(al, t.who) catch {};
            }
            return out.items;
        }
    };
    // Sprites: all of the level's; sounds: only those named.
    const spr_archive = try std.fmt.allocPrint(a, "{s}/sprite.dat", .{d.name});
    var sprites: std.ArrayList(Use) = .empty;
    for (sprview.entries(app, a, spr_archive)) |s| try sprites.append(a, .{ .name = s, .by = quoted.users(a, texts.items, s) });
    var sounds: std.ArrayList(Use) = .empty;
    for (app.player.names(app, a)) |s| {
        const by = quoted.users(a, texts.items, s);
        if (by.len > 0) try sounds.append(a, .{ .name = try a.dupe(u8, s), .by = by });
    }
    std.mem.sort(Use, sounds.items, {}, struct {
        fn lt(_: void, x: Use, y: Use) bool {
            return std.ascii.lessThanIgnoreCase(x.name, y.name);
        }
    }.lt);
    // The music it plays first (the exe's choice, audio/sound.zig and game/life.zig).
    var music: std.ArrayList(Use) = .empty;
    var cand_buf: [2][]const u8 = undefined;
    const cands = og.audio.sound.musicCandidates(d.name, &cand_buf);
    const own = for (cands, 0..) |cn, k| {
        if (voices.has(app, std.fmt.allocPrint(a, "{s}.mp3", .{cn}) catch continue)) break k;
    } else null;
    if (own) |k| {
        try music.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}.mp3", .{cands[k]}), .by = tx.get(if (k == 0) tx.lm_music_own else tx.lm_music_district), .music = true });
    } else if (d.isBattle()) {
        // No track of its own: the battle tracks, the enemy turn's after each.
        const boss = if (d.world.level) |l| l.getInt("bossmonsterLevel") != 0 else false;
        const tracks: []const []const u8 = if (boss) &.{"battle3"} else &.{ "battle", "battle2" };
        for (tracks) |t| {
            try music.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}.mp3", .{t}), .by = tx.get(if (boss) tx.lm_music_boss else tx.lm_music_battle), .music = true });
            try music.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}_enemy.mp3", .{t}), .by = tx.get(tx.lm_music_enemy), .music = true });
        }
    }
    try music.appendSlice(a, sounds.items);
    m.sprites = sprites.items;
    m.sounds = music.items;
    return m;
}

/// The two groups under the level's objects (none when the level has none of them).
pub fn groups(app: *App, a: Allocator, d: *level.Doc) void {
    const m = get(app, d) orelse return;
    const spr_archive = std.fmt.allocPrint(a, "{s}/sprite.dat", .{d.name}) catch return;
    if (m.sprites.len > 0 and header(app, a, "sprites", .image, tx.at_sprites, m.sprites.len)) {
        for (m.sprites, 0..) |u, k| {
            const open = if (app.spr) |ed| std.mem.eql(u8, app.store.files.items[ed.file].archive, spr_archive) and std.ascii.eqlIgnoreCase(ed.name, u.name) else false;
            if (row(app, a, clay.idi("lm_spr", @intCast(k)), .image, u, open, null) != .none) {
                // On its page in a tab of its own, the level's kept.
                @import("doctabs.zig").keepCurrent(app);
                sprview.openEntry(app, spr_archive, u.name) catch |err| app.setStatus(tx.st_open_failed, .{ u.name, err });
            }
        }
        if (main.toolButton(app, "lm_spr_new", .plus, tx.get(tx.spr_import_new), false, false)) app.askNewSprite(spr_archive, false);
    }
    if (m.sounds.len > 0 and header(app, a, "sounds", .volume_2, tx.at_sounds, m.sounds.len)) {
        // Its own track (`<level>.mp3`) put in: the location or battle plays it.
        if (main.toolButton(app, "lm_own_music", .plus, tx.get(tx.mus_own), false, false)) app.askMusic(d.name);
        for (m.sounds, 0..) |u, k| {
            const sel = app.tab == .sounds and std.ascii.eqlIgnoreCase(app.sound_sel.get(), u.name);
            switch (row(app, a, clay.idi("lm_snd", @intCast(k)), .volume_2, u, sel, std.fmt.allocPrint(a, "lm_snd_open{d}", .{k}) catch "lmo")) {
                .none => {},
                .row => if (u.music) voices.play(app, u.name) else app.player.play(app, u.name),
                // Its page (Music or Sounds) in a tab of its own, the level's kept.
                .open => {
                    @import("doctabs.zig").keepCurrent(app);
                    if (u.music) {
                        app.setTab(.music);
                        app.music.sel.set(u.name);
                    } else @import("treemenu.zig").openItem(app, .of(.sound, u.name));
                },
            }
        }
    }
}

/// A folded-by-default group header (`objopen/<key>` kept while open); true while open.
fn header(app: *App, a: Allocator, key: []const u8, ic: icons.Icon, title: tx.Msg, n: usize) bool {
    const okey = std.fmt.allocPrint(a, "objopen/{s}", .{key}) catch return false;
    const open = app.tree_open.contains(okey);
    const gid = clay.id(okey);
    if (main.clickable(app, .{ .id = gid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(28) }, .padding = .{ .left = 8, .right = 8 }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel }, false)) @import("assettree.zig").toggleKey(app, okey);
    icons.leaf(app.r, app.gpa, if (open) .chevron_down else .chevron_right, 13, theme.dim);
    icons.leaf(app.r, app.gpa, ic, 15, theme.dim);
    txt(tx.get(title), 13, theme.text, font_mod.bold);
    txt(std.fmt.allocPrint(a, "({d})", .{n}) catch "", 12, theme.dim, font_mod.regular);
    clay.close();
    return open;
}

const Hit = enum { none, row, open };

/// A sprite or sound row: its name and who names it (dim; "not used" in warning colour);
/// `open`: the id of an open button at its end.
fn row(app: *App, a: Allocator, id: ui.Clay_ElementId, ic: icons.Icon, u: Use, sel: bool, open: ?[]const u8) Hit {
    _ = main.clickable(app, .{ .id = id, .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = 34, .right = 8, .top = 5, .bottom = 5 }, .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel, .cornerRadius = clay.radius(4) }, sel);
    const hit = clay.hovered() and app.clicked;
    icons.leaf(app.r, app.gpa, ic, 14, theme.dim);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 1 } });
    txt(u.name, 14, theme.text, if (sel) font_mod.bold else font_mod.regular);
    if (u.music and !voices.has(app, u.name)) {
        txt(tx.get(tx.lm_music_missing), 11, theme.warn, font_mod.regular);
    } else if (u.by.len > 0) {
        clay.text(if (u.music) u.by else tx.alloc(a, tx.lm_by, .{u.by}), .{ .textColor = theme.dim, .fontSize = 11, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    } else txt(tx.get(tx.lm_unused), 11, theme.warn, font_mod.regular);
    clay.close();
    const opened = if (open) |oid| main.toolButton(app, oid, .file_text, "", false, false) else false;
    clay.close();
    return if (opened) .open else if (hit) .row else .none;
}

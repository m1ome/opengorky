//! Campaign (OpenGorky): what a new game starts with and the shell around the main menu
//! — the rules' Campaign row (rules campaign.ss; the built-in is the exe's 01_port start)
//! and the manifest's title — with pickers for locations, heroes, videos and music; and
//! the project's script hooks (rules\hooks.ss); the shell's rows of rules ui.ss (core/ui.zig:
//! the music the exe names, the main menu's scene, the sliding windows' places, the bottom
//! panel's buttons dragged over game_box.spr). Each
//! field writes the row into the layer's rules file (one undo step; rules_rows.put; a
//! keyless row: the file's last, the one in force). Classic: the locked rows and the
//! exe's start.

const std = @import("std");
const baseName = @import("doctab.zig").baseName;
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const sdl = @import("sdl");
const og = @import("opengorky");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const tx = @import("text.zig");
const doctabs = @import("doctabs.zig");
const rules_rows = @import("rules_rows.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const rules = og.rules;
const shell = og.core.ui;
const common_archive = @import("store.zig").common_archive;
const picker = @import("picker.zig");
const rulesapi = @import("rulesapi.zig");

const Pick = enum { level, leader, intro, startup, credits_video, menu_music, credits_music, level_up, battle_enter, victory, game_over, statistics, battle, boss, sound, font, glow };

/// The page's state (`app.campaign`): the panel's picture (game_box.spr
/// frame 0), its place picked and one being dragged (where its top left is now, the grab
/// point inside it; panel pixels).
/// shortcut: the picture is loaded once, game_box.spr edited shows on the next start.
pub const State = struct {
    panel: ?*sdl.SDL_Texture = null,
    place: ?usize = null,
    drag: ?struct { k: usize, at: [2]f32, grab: [2]f32 } = null,
};

/// Field `field` of the campaign set to `text` (as the rules file writes it).
pub fn set(app: *App, field: []const u8, text: []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    if (std.mem.eql(u8, field, "title")) return setTitle(app, text);
    if (std.mem.eql(u8, field, "party") and partyCount(text) > partyMax()) return error.PartyOverMax;
    if (std.mem.eql(u8, field, "menu_music") or std.mem.eql(u8, field, "credits_music")) {
        try setMusic(app, if (field[0] == 'm') "menu" else "credits", text);
    } else if (gameField(field)) |gf| {
        try setGame(app, gf, field, text);
    } else try rules_rows.putField(app, rules.Campaign, rules.campaign().*, field, text);
    app.setStatus(tx.st_camp_set, .{ field, text });
}

/// The game block's field of Campaign field `field` (loaders/rules_text.zig gameRows):
/// `level` its `start`, the start's place `start_area`…; null: none (the party's lists).
fn gameField(field: []const u8) ?[]const u8 {
    const map = [_][2][]const u8{
        .{ "level", "start" },                 .{ "leader", "leader" },       .{ "area", "start_area" },
        .{ "point", "start_point" },           .{ "scene", "start_scene" },   .{ "intro", "intro" },
        .{ "startup", "startup" },             .{ "menu_logo", "menu_logo" }, .{ "menu_music", "menu_music" },
        .{ "credits_music", "credits_music" }, .{ "credits", "credits" },     .{ "credits_video", "credits_video" },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], field)) return m[1];
    return null;
}

/// The game block's current field `name` (src/game.ogs), each item printed: a list's items,
/// a record's named values by name (`Music(menu = "menu")`: "menu" → `"menu"`).
fn gameItems(app: *App, a: Allocator, name: []const u8) !struct { list: []const []const u8, named: []const [2][]const u8 } {
    const mo = @import("model_og.zig");
    const f = try app.store.file(@import("store.zig").og_src, "game.ogs");
    const b = mo.blockOf(app, a, f) orelse return error.NoSuchBlock;
    var list: std.ArrayList([]const u8) = .empty;
    var named: std.ArrayList([2][]const u8) = .empty;
    for (b.e.fields) |fd| if (std.mem.eql(u8, fd.name, name)) switch (fd.value.kind) {
        .list => |l| for (l) |x| try list.append(a, try printed(a, x)),
        .call => |c| for (c.named) |n| try named.append(a, .{ try a.dupe(u8, n.name), try printed(a, n.value) }),
        else => {},
    };
    return .{ .list = list.items, .named = named.items };
}

fn printed(a: Allocator, e: *const og.script.ir.Expr) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try og.script.ogs.print.expression(&w.writer, e);
    return w.written();
}

/// The game block's music record's `key` (`menu`, `credits`, `level_up`, `battle`…) made
/// `text` (several words: a list), the rest kept; "" takes it out.
fn setMusic(app: *App, key: []const u8, text: []const u8) !void {
    const a = app.frame.allocator();
    const mo = @import("model_og.zig");
    const f = try app.store.file(@import("store.zig").og_src, "game.ogs");
    const old = try gameItems(app, a, "music");
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.writeAll("Music(");
    var n: usize = 0;
    for (old.named) |x| {
        if (std.mem.eql(u8, x[0], key)) continue;
        try w.writer.print("{s}{s} = {s}", .{ if (n > 0) ", " else "", x[0], x[1] });
        n += 1;
    }
    const t = std.mem.trim(u8, text, " ");
    if (t.len > 0) {
        try w.writer.print("{s}{s} = ", .{ if (n > 0) ", " else "", key });
        try stringsText(&w.writer, t, std.mem.indexOfScalar(u8, t, ' ') != null, &.{});
    }
    try w.writer.writeByte(')');
    try mo.set(app, f, &.{"music"}, w.written());
}

/// Words `t` as OG Script: a string, or (`list`) `["a", "b"]`, an item `keep` has by its
/// name (`Video(name = "a.avi", y = 60)`) as it is there.
fn stringsText(w: *std.Io.Writer, t: []const u8, list: bool, keep: []const []const u8) !void {
    const lexer = og.script.ogs.lexer;
    if (!list) return lexer.writeString(w, t);
    try w.writeByte('[');
    var it = std.mem.tokenizeAny(u8, t, " ,");
    var i: usize = 0;
    while (it.next()) |x| : (i += 1) {
        if (i > 0) try w.writeAll(", ");
        const kept = for (keep) |k| {
            const q = std.fmt.allocPrint(std.heap.page_allocator, "name = \"{s}\"", .{x}) catch break null;
            defer std.heap.page_allocator.free(q);
            if (std.mem.startsWith(u8, k, "Video(") and std.ascii.findIgnoreCase(k, q) != null) break k;
        } else null;
        if (kept) |k| try w.writeAll(k) else try lexer.writeString(w, x);
    }
    try w.writeByte(']');
}

/// Game block field `gf` (src/game.ogs) made `text` as OG Script writes it: `~l"01_port"`,
/// `@Sullivan`, `["a.avi", "b.avi"]`, a number, a string; "" takes it out.
fn setGame(app: *App, gf: []const u8, field: []const u8, text: []const u8) !void {
    const a = app.frame.allocator();
    const mo = @import("model_og.zig");
    const f = try app.store.file(@import("store.zig").og_src, "game.ogs");
    const t = std.mem.trim(u8, text, " ");
    if (t.len == 0) return mo.unset(app, f, &.{gf});
    var w: std.Io.Writer.Allocating = .init(a);
    const lexer = og.script.ogs.lexer;
    if (std.mem.eql(u8, field, "point")) {
        try w.writer.print("{d}", .{std.fmt.parseInt(i32, t, 10) catch return error.BadRow});
    } else if (std.mem.eql(u8, field, "leader")) {
        try w.writer.writeByte('@');
        try lexer.writeString(&w.writer, t);
    } else if (std.mem.eql(u8, field, "intro") or std.mem.eql(u8, field, "startup")) {
        // A video keeps its place (`Video(name = "intro.avi", y = 60, double = true)`).
        try stringsText(&w.writer, t, true, (try gameItems(app, a, gf)).list);
    } else {
        if (std.mem.eql(u8, field, "level")) try w.writer.writeAll("~l");
        if (std.mem.eql(u8, field, "scene")) try w.writer.writeAll("~e");
        try lexer.writeString(&w.writer, t);
    }
    try mo.set(app, f, &.{gf}, w.written());
}

/// Shell row `Row` (ExeMusic, MainMenu, Windows) in force.
fn shellRow(comptime Row: type) Row {
    const u = og.core.modules.ui();
    return switch (Row) {
        shell.Music => u.music,
        shell.Menu => u.menu,
        shell.Windows => u.windows,
        shell.Sounds => u.sounds,
        shell.Effects => u.effects,
        shell.Assets => u.assets,
        shell.Canvas => u.canvas,
        else => @compileError("no shell row " ++ @typeName(Row)),
    };
}

/// Field `field` of shell row `Row` set to `text` (as the rules file writes it; the menu's
/// start_y/h_space: their default, a number); a menu's file must be in the game.
pub fn setShell(app: *App, comptime Row: type, field: []const u8, text: []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    // The exe's music is the game block's `music` record (loaders/rules_text.zig gameRows).
    if (Row == shell.Music) return setMusic(app, field, text);
    var r = shellRow(Row);
    if (Row == shell.Menu and (std.mem.eql(u8, field, "start_y") or std.mem.eql(u8, field, "h_space"))) {
        const n = std.fmt.parseInt(i32, std.mem.trim(u8, text, " "), 10) catch return error.BadNumber;
        if (field[0] == 's') r.start_y.d = n else r.h_space.d = n;
    } else r = try og.loaders.rules_text.withField(app.frame.allocator(), Row, r, field, text, &app.rule_why);
    if (Row == shell.Menu) try checkMenu(app, r, field);
    try rules_rows.putSaid(app, Row, r);
}

/// Window place `k` (`windows` order), its `j`-th number made `v`.
pub fn setWindow(app: *App, k: usize, j: usize, v: f32) !void {
    var w = shellRow(shell.Windows);
    windowSlot(&w, k)[j] = v;
    try rules_rows.putSaid(app, shell.Windows, w);
}

/// The menu's field `field` names a file of the game (common/other.dat, as the menu loads it).
fn checkMenu(app: *App, m: shell.Menu, field: []const u8) !void {
    const f = field;
    const eq = std.mem.eql;
    if (eq(u8, f, "model")) {
        if (!inGame(app, "gfx_3d\\{s}.msh", m.model)) return error.NoSuchModel;
    } else if (eq(u8, f, "anim")) {
        var buf: [128]u8 = undefined;
        const i = app.store.file(common_archive, std.fmt.bufPrint(&buf, "gfx_3d\\{s}.ani", .{m.model}) catch return error.NoSuchAnimation) catch return error.NoSuchAnimation;
        var list = og.formats.anim.parseAni(app.gpa, app.store.text(i)) catch return error.NoSuchAnimation;
        defer list.deinit();
        if (list.find(m.anim) == null) return error.NoSuchAnimation;
    } else if (eq(u8, f, "font") or eq(u8, f, "glow")) {
        if (!inGame(app, "{s}_1.fnt", if (f[0] == 'f') m.font else m.glow)) return error.NoSuchFont;
    } else inline for (.{ "light", "circle", "flare", "lens", "lens2", "arrow", "cursor" }) |n| if (eq(u8, f, n)) {
        if (!inGame(app, "gfx_3d\\textures\\{s}", @field(m, n))) return error.NoSuchTexture;
    };
}

/// common/other.dat has `fmt` of `name` (the Store's: new files in, removed out).
fn inGame(app: *App, comptime fmt: []const u8, name: []const u8) bool {
    var buf: [128]u8 = undefined;
    const entry = std.fmt.bufPrint(&buf, fmt, .{name}) catch return false;
    if (name.len == 0) return false;
    _ = app.store.file(common_archive, entry) catch return false;
    return true;
}

/// The menu fonts (`3d_menu`: `<font>_1.fnt` its first page, no `_<n>` letter set itself).
fn menuFonts(app: *App, a: Allocator) []const []const u8 {
    const all = app.store.listing(a, common_archive, struct {
        fn f(e: []const u8) bool {
            return std.ascii.endsWithIgnoreCase(e, ".fnt") and std.ascii.startsWithIgnoreCase(e, "3d_");
        }
    }.f, true);
    var out: std.ArrayList([]const u8) = .empty;
    for (all) |n| {
        const stem = n[0 .. n.len - ".fnt".len];
        const u = std.mem.lastIndexOfScalar(u8, stem, '_') orelse continue;
        if (u + 1 < stem.len and std.ascii.isDigit(stem[u + 1])) continue;
        const first = std.fmt.allocPrint(a, "{s}_1.fnt", .{stem}) catch continue;
        for (all) |x| if (std.ascii.eqlIgnoreCase(x, first)) {
            out.append(a, stem) catch {};
            break;
        };
    }
    return out.items;
}

/// The manifest's title (opengorky.mod in the game folder; not in the edit history).
fn setTitle(app: *App, t: []const u8) !void {
    app.project.setTitle(t);
    var game = try std.Io.Dir.cwd().openDir(app.io, app.game_dir, .{});
    defer game.close(app.io);
    try app.project.save(app.io, game);
}

pub fn page(app: *App, a: Allocator) void {
    const pid = clay.id("campaign_page");
    clay.openScrollColumn(.{ .id = pid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.xl, lay.space.md), .childGap = lay.block.gap }, .backgroundColor = theme.bg });
    gui.pageHeader(app, .play, tx.get(tx.camp_title), tx.get(tx.camp_hint));
    clay.close();
    gui.form(pid, lay.width.label_md, lay.space.xl + lay.block.pad_x);
    // Classic has no game page (its tree row is OpenGorky's).
    if (!app.ogLayout()) return clay.closeScrollColumn();
    if (gui.block(app, "camp_project", tx.get(tx.s_sec_project), .{})) {
        gui.fieldRow(tx.get(tx.cp_title));
        if (gui.textField(app, "camp_title", app.project.title(), 0, "—")) |t| setTitle(app, t) catch |err| app.failed(err);
        _ = pickSlot(app, null, "");
        clay.close();
        gui.fieldNote(tx.get(tx.camp_title_note), theme.dim);
        gui.blockEnd();
    }
    if (gui.block(app, "camp_start", tx.get(tx.camp_sec_start), .{})) {
        valueRow(app, a, rules.Campaign, "level", tx.cp_level, .level);
        valueRow(app, a, rules.Campaign, "leader", tx.cp_leader, .leader);
        party(app, a);
        valueRow(app, a, rules.Campaign, "area", tx.cp_area, null);
        valueRow(app, a, rules.Campaign, "point", tx.cp_point, null);
        valueRow(app, a, rules.Campaign, "scene", tx.cp_scene, null);
        gui.blockEnd();
    }
    if (gui.block(app, "g_video", tx.get(tx.g_sec_video), .{})) {
        valueRow(app, a, rules.Campaign, "intro", tx.cp_intro, .intro);
        valueRow(app, a, rules.Campaign, "startup", tx.cp_startup, .startup);
        valueRow(app, a, rules.Campaign, "credits", tx.cp_credits, null);
        valueRow(app, a, rules.Campaign, "credits_video", tx.cp_credits_video, .credits_video);
        gui.blockEnd();
    }
    if (gui.block(app, "g_music", tx.get(tx.g_sec_music), .{})) {
        valueRow(app, a, rules.Campaign, "menu_music", tx.cp_music, .menu_music);
        valueRow(app, a, rules.Campaign, "credits_music", tx.cp_credits_music, .credits_music);
        valueRow(app, a, shell.Music, "level_up", tx.cp_level_up, .level_up);
        valueRow(app, a, shell.Music, "battle_enter", tx.cp_battle_enter, .battle_enter);
        valueRow(app, a, shell.Music, "battle", tx.cp_battle, .battle);
        valueRow(app, a, shell.Music, "boss", tx.cp_boss, .boss);
        valueRow(app, a, shell.Music, "victory", tx.cp_victory, .victory);
        valueRow(app, a, shell.Music, "game_over", tx.cp_game_over, .game_over);
        valueRow(app, a, shell.Music, "statistics", tx.cp_statistics, .statistics);
        valueRow(app, a, shell.Music, "enemy_suffix", tx.cp_enemy_suffix, null);
        gui.blockEnd();
    }
    const rp = @import("rulespages.zig");
    rp.expBlock(app, a);
    rp.valuesBlocks(app, a);
    rp.statesBlock(app, a);
    const own = @import("ownedpage.zig");
    if (gui.block(app, "g_feel", tx.get(tx.g_sec_feel), .{})) {
        own.fields(app, a, "Motion", "");
        own.fields(app, a, "Sound", tx.get(tx.g_sub_sound));
        gui.blockEnd();
    }
    if (gui.block(app, "g_effects", tx.get(tx.g_sec_effects), .{})) {
        inline for (.{ "Blood", "Sparks", "Particles", "Explosion", "Fire", "ShotFlash", "Shock", "Flame", "RocketTrail", "Ball", "Grenade", "Morph" }) |r| own.fields(app, a, r, r);
        gui.fieldNote(tx.get(tx.g_effects_note), theme.dim);
        gui.blockEnd();
    }
    if (gui.block(app, "camp_hooks", tx.get(tx.camp_sec_hooks), .{})) {
        hooks(app, a);
        gui.blockEnd();
    }
    clay.closeScrollColumn();
}

/// The interface (src/ui.ogs): the main menu, the sliding windows, the bottom panel, the
/// interface's sounds, effects and sprites (core/ui.zig rows).
pub fn uiPage(app: *App, a: Allocator) void {
    const pid = clay.id("ui_page");
    clay.openScrollColumn(.{ .id = pid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = gui.pad(lay.space.xl, lay.space.md), .childGap = lay.block.gap }, .backgroundColor = theme.bg });
    gui.pageHeader(app, .maximize, tx.get(tx.ui_title), tx.get(tx.ui_hint));
    clay.close();
    gui.form(pid, lay.width.label_md, lay.space.xl + lay.block.pad_x);
    if (!app.ogLayout()) return clay.closeScrollColumn();
    if (gui.block(app, "ui_canvas", tx.get(tx.ui_sec_canvas), .{})) {
        const cv = shellRow(shell.Canvas);
        gui.fieldRow(tx.get(tx.ui_canvas_size));
        inline for (.{ "width", "height" }, .{ "W", "H" }) |n, p| {
            if (gui.numberField(app, a, "ui_canvas_" ++ n, p, @floatFromInt(@field(cv, n)), gui.cellWidth(2, false))) |v| setShell(app, shell.Canvas, n, std.fmt.allocPrint(a, "{d}", .{@max(if (n[0] == 'w') @as(i32, 640) else 480, @as(i32, @intFromFloat(@round(v))))}) catch "") catch |err| rules_rows.failed(app, n, err);
        }
        clay.close();
        gui.fieldNote(tx.get(tx.ui_canvas_note), theme.dim);
        gui.blockEnd();
    }
    if (gui.block(app, "ui_menu", tx.get(tx.ui_sec_menu), .{})) {
        valueRow(app, a, rules.Campaign, "menu_logo", tx.cp_logo, null);
        valueRow(app, a, shell.Menu, "model", tx.cp_menu_model, null);
        valueRow(app, a, shell.Menu, "anim", tx.cp_menu_anim, null);
        inline for (.{ "light", "circle", "flare", "lens", "lens2", "arrow", "cursor" }, .{ tx.cp_menu_light, tx.cp_menu_circle, tx.cp_menu_flare, tx.cp_menu_lens, tx.cp_menu_lens2, tx.cp_menu_arrow, tx.cp_menu_cursor }) |n, m| valueRow(app, a, shell.Menu, n, m, null);
        valueRow(app, a, shell.Menu, "font", tx.cp_menu_font, .font);
        valueRow(app, a, shell.Menu, "glow", tx.cp_menu_glow, .glow);
        const m = shellRow(shell.Menu);
        inline for (.{ "start_y", "h_space" }, .{ tx.cp_menu_start_y, tx.cp_menu_h_space }) |n, l| {
            gui.fieldRow(tx.get(l));
            if (gui.numberField(app, a, "camp_" ++ n, "", @floatFromInt(@field(m, n).d), lay.width.number)) |v| setShell(app, shell.Menu, n, std.fmt.allocPrint(a, "{d}", .{@as(i32, @intFromFloat(@round(v)))}) catch "") catch |err| rules_rows.failed(app, n, err);
            clay.close();
        }
        gui.fieldNote(tx.get(tx.camp_menu_note), theme.dim);
        gui.blockEnd();
    }
    if (gui.block(app, "camp_windows", tx.get(tx.camp_sec_windows), .{})) {
        windows(app, a);
        gui.blockEnd();
    }
    if (gui.block(app, "camp_panel", tx.get(tx.camp_sec_panel), .{})) {
        panel(app, a);
        gui.blockEnd();
    }
    const own = @import("ownedpage.zig");
    if (gui.block(app, "ui_popup", tx.get(tx.ui_sec_popup), .{})) {
        own.fields(app, a, "PopupColors", "");
        own.fields(app, a, "PopupText", tx.get(tx.ui_sub_popup_text));
        gui.blockEnd();
    }
    if (gui.block(app, "ui_battle", tx.get(tx.ui_sec_battle), .{})) {
        own.fields(app, a, "BattleColors", "");
        own.fields(app, a, "BattleGrid", tx.get(tx.ui_sub_grid));
        own.fields(app, a, "Cinema", tx.get(tx.ui_sub_cinema));
        gui.blockEnd();
    }
    if (gui.block(app, "ui_menu_light", tx.get(tx.ui_sec_menu_light), .{})) {
        own.fields(app, a, "MenuLight", "");
        own.fields(app, a, "CreditsColors", tx.get(tx.ui_sub_credits));
        own.fields(app, a, "SafeLock", tx.get(tx.ui_sub_safe));
        gui.blockEnd();
    }
    rowBlock(app, a, shell.Sounds, "ui_sounds", tx.ui_sec_sounds, .sound);
    rowBlock(app, a, shell.Effects, "ui_effects", tx.ui_sec_effects, null);
    rowBlock(app, a, shell.Assets, "ui_assets", tx.ui_sec_assets, null);
    clay.closeScrollColumn();
}

/// A one-row table's block (`UiSounds`, `UiEffects`, `UiAssets`): each of its names a field,
/// its doc after it (rulesapi), a sound picked from the game's (`pick`).
fn rowBlock(app: *App, a: Allocator, comptime Row: type, comptime id: []const u8, title: tx.Msg, comptime pick: ?Pick) void {
    if (!gui.block(app, id, tx.get(title), .{})) return;
    const r = shellRow(Row);
    const call = rulesapi.find(Row.call);
    inline for (@typeInfo(Row).@"struct".field_names, @typeInfo(Row).@"struct".field_types) |name, T| if (comptime T == []const u8 and !std.mem.eql(u8, name, "note")) {
        const doc = if (call) |c| if (rulesapi.field(c, name)) |fd| tx.get(fd.doc) else name else name;
        if (pick) |pk| {
            valueRowOf(app, a, Row, name, doc, pk, @field(r, name));
        } else {
            gui.fieldRow(doc);
            if (gui.textField(app, id ++ "_" ++ name, @field(r, name), 0, "—")) |t| setShell(app, Row, name, t) catch |err| rules_rows.failed(app, name, err);
            _ = pickSlot(app, null, "");
            clay.close();
        }
    };
    gui.blockEnd();
}

/// `valueRow` of a label given as text and a value at hand.
fn valueRowOf(app: *App, a: Allocator, comptime Row: type, comptime name: []const u8, label: []const u8, comptime p: Pick, shown: []const u8) void {
    gui.fieldRow(label);
    if (gui.textField(app, "row_" ++ @typeName(Row) ++ name, shown, 0, "—")) |t| setOf(app, Row, name, t) catch |err| rules_rows.failed(app, name, err);
    const pid = clay.id("rowpick_" ++ @typeName(Row) ++ name);
    if (pickSlot(app, pid, tx.get(if (isList(p)) tx.camp_add_video else tx.camp_pick))) picker.toggle(app, pid);
    clay.close();
    if (!picker.isOpen(app, pid)) return;
    const rows = picker.names(a, choices(app, a, p));
    const choice = rows[picker.list(app, a, rows) orelse return].key;
    setOf(app, Row, name, choice) catch |err| app.failed(err);
}

/// A row's picker button after its field, as wide in every row (so the fields end
/// alike; `id` null: the slot kept empty). True when clicked.
fn pickSlot(app: *App, id: ?ui.Clay_ElementId, label: []const u8) bool {
    var w: f32 = 0;
    for ([_]tx.Msg{ tx.camp_pick, tx.camp_add_video }) |m| w = @max(w, gui.buttonWidth(app, .{ .label = tx.get(m), .size = .small }));
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(w) } } });
    const hit = if (id) |i| gui.buttonOf(app, i, .{ .label = label, .size = .small, .wide = true }) else false;
    clay.close();
    return hit;
}

/// A field's row: its value typed in, and a picker where it has one (a video list's
/// adds to the list).
fn valueRow(app: *App, a: Allocator, comptime Row: type, comptime name: []const u8, label: tx.Msg, pick: ?Pick) void {
    const v = @field(if (Row == rules.Campaign) rules.campaign().* else shellRow(Row), name);
    const shown = if (@TypeOf(v) == i32) std.fmt.allocPrint(a, "{d}", .{v}) catch "" else v;
    gui.fieldRow(tx.get(label));
    if (gui.textField(app, "camp_" ++ name, shown, 0, "—")) |t| setOf(app, Row, name, t) catch |err| rules_rows.failed(app, name, err);
    const p = pick orelse {
        _ = pickSlot(app, null, "");
        return clay.close();
    };
    const pid = clay.id("campick_" ++ name);
    if (pickSlot(app, pid, tx.get(if (isList(p)) tx.camp_add_video else tx.camp_pick))) picker.toggle(app, pid);
    clay.close();
    if (!picker.isOpen(app, pid)) return;
    const rows = picker.names(a, choices(app, a, p));
    const choice = rows[picker.list(app, a, rows) orelse return].key;
    const text = if (isList(p) and shown.len > 0) std.fmt.allocPrint(a, "{s} {s}", .{ shown, choice }) catch return else choice;
    setOf(app, Row, name, text) catch |err| app.failed(err);
}

fn setOf(app: *App, comptime Row: type, field: []const u8, text: []const u8) !void {
    return if (Row == rules.Campaign) set(app, field, text) else setShell(app, Row, field, text);
}

/// The sliding windows' places (Windows), each two numbers on the 640×480 screen.
const window_rows = [_]struct { tx.Msg, [2][]const u8 }{
    .{ tx.win_skills_at, .{ "X", "Y" } },  .{ tx.win_skills_from, .{ "X", "Y" } }, .{ tx.win_skills_size, .{ "W", "H" } },
    .{ tx.win_skills_inv, .{ "X", "Y" } }, .{ tx.win_stats_at, .{ "X", "Y" } },    .{ tx.win_stats_from, .{ "X", "Y" } },
    .{ tx.win_stats_size, .{ "W", "H" } }, .{ tx.win_stats_inv, .{ "X", "Y" } },   .{ tx.win_level_up, .{ "X", "Y" } },
};

fn windowSlot(w: *shell.Windows, k: usize) *[2]f32 {
    return switch (k) {
        0 => &w.skills.at,
        1 => &w.skills.from,
        2 => &w.skills.size,
        3 => &w.skills_inventory,
        4 => &w.stats.at,
        5 => &w.stats.from,
        6 => &w.stats.size,
        7 => &w.stats_inventory,
        else => &w.level_up,
    };
}

fn windows(app: *App, a: Allocator) void {
    var w = shellRow(shell.Windows);
    for (window_rows, 0..) |r, k| {
        gui.fieldRow(tx.get(r[0]));
        const at = windowSlot(&w, k);
        for (0..2) |j| if (gui.numberField(app, a, std.fmt.allocPrint(a, "camp_win{d}_{d}", .{ k, j }) catch "camp_win", r[1][j], at[j], gui.cellWidth(2, false))) |v| setWindow(app, k, j, v) catch |err| app.failed(err);
        clay.close();
    }
    gui.fieldNote(tx.get(tx.camp_windows_note), theme.dim);
}

/// Panel place `k` (PanelPlace, `places` order): x, y, w or h (`j`) made `v`, its
/// button's row written whole.
pub fn setPlace(app: *App, k: usize, j: usize, v: f32) !void {
    const ps = og.core.modules.ui().panel.places;
    if (k >= ps.len or j > 3) return error.NoSuchPlace;
    const r = ps[k].rect;
    var n = [4]f32{ r[0], r[1], r[2] - r[0] + 1, r[3] - r[1] + 1 };
    n[j] = v;
    try putPlace(app, k, n);
}

/// Place `k` made x, y, w, h `n` (whole pixels, at least 1×1): one row, one undo step.
fn putPlace(app: *App, k: usize, n: [4]f32) !void {
    var p = og.core.modules.ui().panel.places[k];
    const x = @round(n[0]);
    const y = @round(n[1]);
    p.rect = .{ x, y, x + @max(1, @round(n[2])) - 1, y + @max(1, @round(n[3])) - 1 };
    try rules_rows.putSaid(app, shell.Place, p);
}

/// A portrait slot after the last one, as far on as that one is from its own neighbour
/// (the controls are the exe's, each once; a party holds no more than World.party_cap).
pub fn addPlace(app: *App) !void {
    var last: [2]?shell.Place = .{ null, null };
    var n: usize = 0;
    for (og.core.modules.ui().panel.places) |p| if (p.button.slot()) |s| {
        n = @max(n, s + 1);
        last = .{ last[1], p };
    };
    if (n >= og.state.world.World.party_cap) return error.PartyCapReached;
    var p = last[1] orelse return error.NoPortraitSlot;
    const dx = if (last[0]) |q| p.rect[0] - q.rect[0] else p.rect[2] - p.rect[0] + 1;
    p.button = .portrait(n);
    p.rect = .{ p.rect[0] + dx, p.rect[1], p.rect[2] + dx, p.rect[3] };
    try rules_rows.putSaid(app, shell.Place, p);
    app.campaign.place = og.core.modules.ui().panel.places.len - 1;
}

/// A place the project added (no built-in has its button).
fn isAdded(p: shell.Place) bool {
    return !rules_rows.builtinKey(shell.Place, "places", p);
}

/// Place `k` removed: only one the project added (the rules files only write over the
/// built-in rows).
pub fn removePlace(app: *App, k: usize) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const ps = og.core.modules.ui().panel.places;
    if (k >= ps.len) return error.NoSuchPlace;
    if (!isAdded(ps[k])) return error.BuiltInPlace;
    if (!try rules_rows.drop(app, shell.Place, ps[k])) return error.NoOwnRow;
    app.campaign.place = null;
    app.setStatus(tx.st_rules_row, .{shell.Place.call});
}

/// "inventory", "portrait2".
fn buttonName(a: Allocator, b: shell.Button) []const u8 {
    return if (b.slot()) |s| std.fmt.allocPrint(a, "portrait{d}", .{s}) catch "" else @tagName(b);
}

/// The bottom panel (game_box.spr frame 0) with its places' rectangles over it: one
/// clicked is picked, dragged it moves (one undo step on release); the picked one's
/// numbers, removed when the project added it; a new portrait slot.
fn panel(app: *App, a: Allocator) void {
    const st = &app.campaign;
    const ps = og.core.modules.ui().panel.places;
    if (st.panel == null) st.panel = app.spriteTexture("game_box.spr") catch null;
    const t = st.panel orelse return gui.note(tx.get(tx.camp_panel_none));
    _ = sdl.SDL_SetTextureScaleMode(t, sdl.SDL_SCALEMODE_NEAREST);
    var tw: f32 = 0;
    var th: f32 = 0;
    _ = sdl.SDL_GetTextureSize(t, &tw, &th);
    const pid = clay.id("camp_panel_pic");
    // The picture fills the block's width, its shape kept (aspectRatio: a fixed width would
    // hold the block open, never letting it narrow); the places scale as its last layout.
    const s = (if (clay.box(pid)) |b| b.width else tw) / @max(1, tw);
    clay.open(.{ .id = pid, .layout = .{ .sizing = .{ .width = clay.grow() } }, .aspectRatio = .{ .aspectRatio = tw / @max(1, th) }, .image = .{ .imageData = t } });
    for (ps, 0..) |p, k| {
        var r = p.rect;
        if (st.drag) |d| if (d.k == k) {
            r = .{ d.at[0], d.at[1], d.at[0] + r[2] - r[0], d.at[1] + r[3] - r[1] };
        };
        const id = clay.idi("camp_place", @intCast(k));
        const sel = st.place == k;
        var fill = theme.accent;
        fill.a = if (sel) 70 else 0;
        clay.leaf(.{ .id = id, .layout = .{ .sizing = .{ .width = clay.fixed((r[2] - r[0] + 1) * s), .height = clay.fixed((r[3] - r[1] + 1) * s) } }, .backgroundColor = fill, .border = .{ .color = if (sel) theme.accent else if (clay.pointerOver(id)) theme.accent_hover else theme.warn, .width = gui.edges(lay.border.line) }, .floating = .{ .offset = .{ .x = r[0] * s, .y = r[1] * s }, .attachTo = ui.CLAY_ATTACH_TO_PARENT, .zIndex = if (sel) 3 else 2 } });
        // The last one under the pointer (drawn on top) is picked.
        if (clay.pointerOver(id) and app.clicked) {
            st.place = k;
            if (clay.box(pid)) |b| st.drag = .{ .k = k, .at = .{ r[0], r[1] }, .grab = .{ (app.mouse[0] - b.x) / s - r[0], (app.mouse[1] - b.y) / s - r[1] } };
        }
    }
    clay.close();
    // A place being dragged follows the pointer by whole pixels; on release it is written.
    if (st.drag) |*d| if (clay.box(pid)) |b| {
        d.at = .{ @round((app.mouse[0] - b.x) / s - d.grab[0]), @round((app.mouse[1] - b.y) / s - d.grab[1]) };
        if (!app.down) {
            const k = d.k;
            const at = d.at;
            st.drag = null;
            if (k < ps.len and (at[0] != ps[k].rect[0] or at[1] != ps[k].rect[1])) {
                const r = ps[k].rect;
                putPlace(app, k, .{ at[0], at[1], r[2] - r[0] + 1, r[3] - r[1] + 1 }) catch |err| app.failed(err);
            }
        }
    };
    if (st.place) |k| if (k < ps.len) {
        const p = ps[k];
        const r = p.rect;
        const v = [4]f32{ r[0], r[1], r[2] - r[0] + 1, r[3] - r[1] + 1 };
        gui.fieldRow(buttonName(a, p.button));
        for ([_][]const u8{ "X", "Y", "W", "H" }, 0..) |l, j| if (gui.numberField(app, a, std.fmt.allocPrint(a, "camp_place_n{d}", .{j}) catch "camp_place_n", l, v[j], gui.cellWidth(4, true))) |x| setPlace(app, k, j, x) catch |err| app.failed(err);
        if (gui.trail(app, if (isAdded(p)) clay.id("camp_place_del") else null)) removePlace(app, k) catch |err| app.failed(err);
        clay.close();
    };
    if (st.place == null) gui.fieldNote(tx.get(tx.camp_panel_pick), theme.dim);
    if (gui.footer(app, "camp_panel_add", &.{tx.get(tx.camp_panel_add)}, null) != null) addPlace(app) catch |err| app.failed(err);
    gui.fieldNote(tx.get(tx.camp_panel_note), theme.dim);
}

fn isList(p: Pick) bool {
    return p == .intro or p == .startup or p == .credits_video or p == .battle;
}

/// The values picker `p` offers.
fn choices(app: *App, a: Allocator, p: Pick) []const []const u8 {
    var opts: std.ArrayList([]const u8) = .empty;
    switch (p) {
        .level => for (app.levels) |lv| if (!lv.battle) opts.append(a, lv.name) catch {},
        .leader => for (app.catalog.entries.items) |e| if (e.kind == .hero and !e.ally) opts.append(a, rules.stem(e.entry)) catch {},
        .intro, .startup, .credits_video => for (@import("videopage.zig").names(app)) |n| opts.append(a, n) catch {},
        .menu_music, .credits_music, .level_up, .battle_enter, .victory, .game_over, .statistics, .battle, .boss => for (@import("musicpage.zig").names(app)) |n| opts.append(a, rules.stem(n)) catch {},
        .sound => for (app.player.names(app, a)) |n| opts.append(a, rules.stem(n)) catch {},
        .font, .glow => opts.appendSlice(a, menuFonts(app, a)) catch {},
    }
    return opts.items;
}

fn inList(list: []const u8, file: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " ,");
    while (it.next()) |x| if (std.ascii.eqlIgnoreCase(x, file)) return true;
    return false;
}

/// The most heroes a party holds: rules Value(party_max) as the port clamps it (the exe's
/// party array holds 6, 0x6b4e78: the built-in value).
fn partyMax() usize {
    const W = og.state.world.World;
    return @intCast(std.math.clamp(rules.value(.party_max), W.party_min, W.party_cap));
}

fn partyCount(list: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, list, " ,");
    while (it.next()) |_| n += 1;
    return n;
}

/// The party: a tick per hero (the game's own while the list is empty: every
/// gamestart\ hero); a tick changed makes the list the campaign's.
fn party(app: *App, a: Allocator) void {
    // The game block's `party = [characters::sullivan, …]` (world/start.zig createModelParty).
    const have = (gameItems(app, a, "party") catch return).list;
    gui.fieldRow(tx.get(tx.cp_party));
    gui.stack(lay.space.xs);
    var k: u32 = 0;
    for (app.catalog.entries.items) |e| {
        if (e.kind != .hero or e.ally) continue;
        const stem = rules.stem(baseName(e.entry));
        const path = std.fmt.allocPrint(a, "characters::{s}", .{stem}) catch continue;
        const on = for (have) |h| {
            if (std.mem.eql(u8, h, path)) break true;
        } else false;
        const label = if (e.title.len > 0) std.fmt.allocPrint(a, "{s} · {s}", .{ e.title, path }) catch path else path;
        if (gui.check(app, clay.idi("camp_hero", k), on, label)) setParty(app, a, have, path, !on) catch |err| if (err == error.PartyOverMax) app.setStatus(tx.cp_party_full, .{partyMax()}) else app.failed(err);
        k += 1;
    }
    clay.close();
    clay.close();
    gui.fieldNote(tx.get(tx.camp_party_note), theme.dim);
    gui.fieldNote(tx.alloc(a, tx.cp_party_max, .{partyMax()}), theme.dim);
}

/// The party with hero `path` in (`on`) or out, its order kept (a new one last).
fn setParty(app: *App, a: Allocator, have: []const []const u8, path: []const u8, on: bool) !void {
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.writeByte('[');
    var n: usize = 0;
    for (have) |h| {
        if (!on and std.mem.eql(u8, h, path)) continue;
        try w.writer.print("{s}{s}", .{ if (n > 0) ", " else "", h });
        n += 1;
    }
    if (on) {
        if (n + 1 > partyMax()) return error.PartyOverMax;
        try w.writer.print("{s}{s}", .{ if (n > 0) ", " else "", path });
    }
    try w.writer.writeByte(']');
    const f = try app.store.file(@import("store.zig").og_src, "game.ogs");
    try @import("model_og.zig").set(app, f, &.{"party"}, w.written());
    app.setStatus(tx.st_camp_set, .{ "party", w.written() });
}

/// The hooks file opened (made from the template when the project has none) and the
/// hooks the engine calls.
fn hooks(app: *App, a: Allocator) void {
    const entry = @import("codecomplete.zig").hooks_file;
    for (og.script.traits.hooks()) |h| {
        gui.propRow(std.fmt.allocPrint(a, "{s}({s})", .{ h.name, h.params }) catch h.name, h.when.en);
    }
    gui.note(tx.get(tx.camp_hooks_note));
    const file = app.store.file(@import("store.zig").og_src, entry) catch null;
    if (gui.footer(app, "camp_hooks", &.{tx.get(if (file != null) tx.camp_hooks_open else tx.camp_hooks_make)}, null) == null) return;
    if (file) |f| return doctabs.showCode(app, f, null);
    if (app.store.addNew(&.{.{ .archive = @import("store.zig").og_src, .entry = entry, .text = og.script.traits.hooksTemplate(app.gpa) catch return }})) |f| doctabs.showCode(app, f, null) else |err| app.failed(err);
}

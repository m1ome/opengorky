//! The editor's state (App), shared types and small widgets used by every page. Some
//! App methods live elsewhere, as aliases here: app_levels.zig (the open and kept
//! levels), textedit.zig (typing), doctabs.zig (links).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const clay = @import("clay.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const Font = font_mod.Font;
const level = @import("level.zig");
const Doc = level.Doc;
const tx = @import("text.zig");
const Settings = @import("settings.zig").Settings;
const Split = @import("settings.zig").Split;
const config = @import("config");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const catalog = @import("catalog.zig");
const preview = @import("preview.zig");
const sounds = @import("sounds.zig");
const codeview = @import("codeview.zig");
const sprview = @import("sprview.zig");
const entries = @import("entries.zig");
const paint = @import("paint.zig");
const doctabs = @import("doctabs.zig");
const refs = @import("refs.zig");
const common_archive = @import("store.zig").common_archive;
const code = @import("code.zig");
const level_edit = @import("level_edit.zig");
const textedit = @import("textedit.zig");
const app_levels = @import("app_levels.zig");
const app_reload = @import("app_reload.zig");

pub const theme = @import("theme.zig");

// The App's value types (app_types.zig).
const app_types = @import("app_types.zig");
pub const BoxOpen = app_types.BoxOpen;
const Ref = app_types.Ref;
pub const ScenePreview = app_types.ScenePreview;
pub const Confirm = app_types.Confirm;
pub const AnimDrag = app_types.AnimDrag;
pub const Parked = app_types.Parked;
pub const PaintKeep = app_types.PaintKeep;
pub const Tab = app_types.Tab;
pub const Stat = app_types.Stat;
pub const base_stats = app_types.base_stats;
pub const fighter_stats = app_types.fighter_stats;
pub const damage_stat = app_types.damage_stat;
pub const FileKind = app_types.FileKind;
pub const FileAsk = app_types.FileAsk;
pub const Menu = app_types.Menu;
pub const Clip = app_types.Clip;
pub const Name = app_types.Name;

/// Dialog answer: SDL may call back on another thread; the main loop takes it.
var dialog_path: [1024]u8 = undefined;
var dialog_len: usize = 0;
var dialog_ready: std.atomic.Value(bool) = .init(false);

fn dialogDone(_: ?*anyopaque, files: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    if (files == null or files[0] == null) return;
    const p = std.mem.span(files[0]);
    if (p.len > dialog_path.len) return;
    @memcpy(dialog_path[0..p.len], p);
    dialog_len = p.len;
    dialog_ready.store(true, .release);
}

pub const App = struct {
    gpa: Allocator,
    window: *c.SDL_Window,
    io: Io,
    r: *c.SDL_Renderer,
    font: *Font,
    dat: Io.Dir,
    game_dir: []const u8,
    /// The game folder's manifest (opengorky.mod): a Classic game, whose archives saves
    /// rewrite within the exe's limits, or an OpenGorky project of OG Script (`format =
    /// ogs`, read-only until the editor writes OG Script: app_reload `save`).
    project: og.formats.manifest.Manifest = .{},
    levels: []level.LevelEntry,
    templates: []level.Template,
    /// Every edited file (levels, fighters, classes, heroes): one undo, one save.
    store: Store,
    catalog: catalog.Catalog,
    /// common/sprite.dat for item icons, and icons decoded so far (name → texture).
    sprites: ?og.formats.archive.Archive = null,
    icons: std.StringHashMapUnmanaged(?*c.SDL_Texture) = .empty,
    /// Enemies/items/heroes tabs: the selected catalog entry.
    entry: ?usize = null,
    /// The open value list (picker.zig): the id of what opened it, and its search.
    pick: ?u32 = null,
    pick_q: Name(64) = .{},
    /// Scenes tab: the scene shown, by name (`.dlg` at its end: a dialogue instead —
    /// a battle's or an idle one); kept by name, the catalog sorts again after a save.
    scene: Name(64) = .{},
    scenes: @import("scenepage.zig").State = .{},
    logic: @import("logicview.zig").State = .{},
    /// Code open in other tabs than the shown one (`code`), and the code page's lower panel.
    code_parked: std.ArrayList(*code.View) = .empty,
    code_bottom: enum { problems, refs, usages } = .problems,
    /// The name of a new location (from the open one) and whether its row is open.
    level_name: Name(24) = .{},
    level_naming: bool = false,
    /// A blank level's picture size (0: its kind's own, newlevel.blankSize).
    blank_size: [2]u32 = .{ 0, 0 },
    /// Its "Make" clicked: made at the next frame's start (it opens the new level).
    level_make: bool = false,
    /// A hero to delete from the menu, at the next frame's start (the level reloads).
    hero_drop: Name(48) = .{},
    /// A document tab to close (its ×), at the next frame's start: closing may save or
    /// discard, which rebuilds what this frame's layout still points into.
    tab_close: ?usize = null,
    /// `tab_close` without the question on its unsaved edits (what it showed is deleted).
    tab_close_quiet: bool = false,
    /// History's Return clicked: done at the next frame's start (as tab_close).
    history_go: bool = false,
    /// The catalog replaced mid-frame: freed at the next frame's start (this frame's
    /// layout holds its names until drawn).
    stale_catalog: ?catalog.Catalog = null,
    /// A link clicked (scene, level and object), followed at the next frame's start.
    nav: ?struct { scene: bool, name: [64]u8, name_len: usize, obj: [64]u8, obj_len: usize } = null,
    /// Enemy model preview and its animation (logical name, `long_attack`).
    preview: preview.Preview = .{},
    /// The open sprite (the Sprites page, sprview.zig).
    spr: ?*sprview.Edit = null,
    /// Where "Import PNG…" puts a new sprite: its archive and folder (`icons` or none).
    spr_new: Name(64) = .{},
    spr_new_icons: bool = false,
    /// The dialogue line's voice file a file dialog is for (scenepage.zig).
    voice_for: Name(64) = .{},
    /// The dialogue line a silent line's own file goes to (scenepage.silentRow).
    voice_line: usize = 0,
    /// The level edit mode (paint.zig) over the open location.
    paint: ?*paint.Paint = null,
    /// Frame sounds of the preview.
    player: sounds.Player = .{},
    /// A file dialog is open for this.
    asking: ?FileAsk = null,
    /// The game folder dialog is open.
    asking_game: bool = false,
    /// Dragging the preview: last pointer.
    turning: ?[2]f32 = null,
    /// Moving the preview's picture (right or middle drag): last pointer.
    shifting: ?[2]f32 = null,
    /// The UI scale the renderer and font are set to (settings.ui_scale once applied).
    scale_on: f32 = 1,
    /// The UI scale on the settings' slider while it is dragged.
    scale_drag: ?f32 = null,
    anim_name: Name(48) = .{},
    sound_sel: Name(64) = .{},
    /// The look pages' documents (look_pages.zig): a model, a look script, a texture.
    model_sel: Name(64) = .{},
    /// The trait and the component pages' (traitpage.zig) names.
    trait_sel: Name(64) = .{},
    comp_sel: Name(64) = .{},
    anims_sel: Name(160) = .{},
    texture_sel: Name(64) = .{},
    effect: @import("effectpage.zig").State = .{},
    fonts: @import("fontpage.zig").State = .{},
    texts: @import("textpage.zig").State = .{},
    adjust: @import("adjustpage.zig").State = .{},
    campaign: @import("campaignpage.zig").State = .{},
    rules_page: @import("rulespages.zig").State = .{},
    post: @import("postpage.zig").State = .{},
    /// The level stage's background with its post-processing (postpage.stageTexture), and
    /// whether the stage shows it (the toolbar's Post-processing).
    post_stage: @import("postpage.zig").State = .{},
    /// The game's post-processing shader on the GPU renderer (the previews above draw by it).
    post_gpu: @import("viewer").gpu_post.Post = .{},
    stage_post: bool = true,
    material: @import("fxmaterial.zig").State = .{},
    reference: @import("reference.zig").State = .{},
    music: @import("musicpage.zig").State = .{},
    video: @import("videopage.zig").State = .{},
    /// The ffmpeg run going on (videos, music).
    convert: ?*@import("convert.zig").Job = null,
    /// "Convert to OpenGorky…": its window and run (projconvert.zig).
    proj_convert: ?*@import("projconvert.zig").Window = null,
    /// Weapon page: which hero strikes in the preview (catalog index; not one of them: the first).
    attack_hero: usize = 0,
    /// Weapon page: the heroes able to strike with the weapon shown (entry_model.strikeOf, this frame).
    strikers: []const usize = &.{},
    /// A placed enemy's resistance ticks write its own row (else its class's).
    resist_own: bool = true,
    /// The enemy attack struck in the model pane (entry_attacks.zig), by its place in the list.
    enemy_strike: ?u32 = null,
    /// Enemy class page: the weapon whose reach map is shown.
    reach_open: ?u32 = null,
    /// Weapon and attack pages: the stage shows the weapon's model (an attack: its strike),
    /// a hero or an enemy striking with it, or its damage zone.
    entry_view: enum { model, strike, zone } = .model,
    /// Weapon page, its effect description (fxdesc.zig): the stage shown (hit) and its part picked.
    fx_stage: u8 = 4,
    fx_part: ?usize = null,
    /// A pane edge being dragged: which, the pointer and the size at the press, and
    /// whether the size grows to the right/down (+1) or the left/up (-1).
    split_drag: ?struct { key: Split, across: bool, from: f32, start: f32, sign: f32 } = null,
    /// Resize cursors (left-right, up-down), made on first use; which one this frame.
    cursors: [2]?*c.SDL_Cursor = .{ null, null },
    cursor_want: ?u1 = null,
    tab: Tab = .battles,
    /// The selected enemy's files, for the object name `enemy_of` (pointer identity).
    enemy: ?level.Enemy = null,
    enemy_of: ?[*]const u8 = null,
    /// The field typed into (text, number, script value), and a typed text waiting for its
    /// field (textedit.zig).
    text_edit: ?@import("textedit.zig").Edit = null,
    text_given: ?@import("textedit.zig").Edit = null,
    /// The asset tree: its open folders (keys owned) and its search (typed: textedit `live`).
    tree_open: std.StringHashMapUnmanaged(void) = .empty,
    tree_query: Name(64) = .{},
    /// The animation list's search (enemy and hero pages).
    anim_query: Name(32) = .{},
    /// The selection the tree last opened its folders for.
    tree_seen: u64 = 0,
    /// Open documents (the tab strip over the centre).
    doc_tabs: std.ArrayList(doctabs.DocTab) = .empty,
    /// The document shown (doctabs.refresh): what the tabs, the tree's highlight and the
    /// shortcuts act on.
    active: ?doctabs.DocTab = null,
    /// The tab last scrolled into the strip (hash).
    tab_seen: u64 = 0,
    /// Undo steps when the tabs were last synced (a new step keeps the shown tab).
    tab_steps: usize = 0,
    /// Objects hidden in the view (names, `kind:<kind>`; keys owned).
    view_hidden: std.StringHashMapUnmanaged(void) = .empty,
    /// The slider being dragged (its id's hash).
    slider_drag: ?u32 = null,
    /// A sound marker dragged on the timeline: its .ani file, animation, cue, frame now.
    cue_drag: ?struct { file: usize, anim: usize, cue: usize, frame: u32 } = null,
    /// A spin marker dragged on the timeline: its strike's special, spin, frame now.
    spin_drag: ?struct { special: i32, i: usize, frame: u32 } = null,
    /// The Model page's attach point handles: the model's (name hash), the point picked
    /// and where the pointer took it (a drag).
    points: struct { mesh: u64 = 0, sel: ?usize = null, drag: ?[2]f32 = null } = .{},
    settings: Settings = .{},
    /// `<config dir>/editor.cfg`; null — no settings folder.
    settings_path: ?[]const u8 = null,
    current: ?usize = null,
    /// Levels open in other tabs, kept loaded while away (most recent last); a null doc
    /// is read again when its tab comes back (the archives changed).
    parked: std.ArrayList(Parked) = .empty,
    /// Levels left in the edit mode for another tab (level index → the mode), opened
    /// in it again when shown.
    paint_left: std.AutoHashMapUnmanaged(usize, PaintKeep) = .empty,
    doc: ?*Doc = null,
    selected: ?usize = null,
    status_buf: [512]u8 = undefined,
    status: []const u8 = "",
    /// Why the last rules value typed did not read (`rules_rows.failed` says it in the
    /// status line): set by the editor's `codec.readText` / `rules_text.withField` calls.
    rule_why: og.loaders.codec.Why = .not_value,
    frame: std.heap.ArenaAllocator,
    // Input of the current frame.
    mouse: [2]f32 = .{ 0, 0 },
    down: bool = false,
    clicked: bool = false,
    /// Panning: last pointer position.
    pan: ?[2]f32 = null,
    /// Right-click menu on the level: where it opened (screen) and the grid point there.
    menu: ?Menu = null,
    /// Scripts naming the menu's object ("file: line"), found when the menu opened (owned).
    menu_refs: std.ArrayList(Ref) = .empty,
    /// The copied object (Paste puts it), and objects the editor will not move (names; owned).
    clip: ?Clip = null,
    /// The asset tree's right-click menu and its copied row.
    tree_menu: ?@import("treemenu.zig").Menu = null,
    tree_clip: ?@import("treemenu.zig").Item = null,
    paths: @import("paths.zig").State = .{},
    anims: @import("levelanims.zig").State = .{},
    /// The game's model names (gfx_3d\\*.msh stems; owned), read once.
    models: std.ArrayList([]u8) = .empty,
    /// The open level's sprites and sounds with their users (levelmedia.zig).
    level_media: ?@import("levelmedia.zig").Media = null,
    locked: std.StringHashMapUnmanaged(void) = .empty,
    /// A deletion waiting for its confirmation.
    confirm: ?Confirm = null,
    /// A refusal shown in a window until closed (`alertOf`): its title and text.
    alert: ?struct { title: []const u8, text: []const u8 } = null,
    alert_buf: [512]u8 = undefined,
    /// Box contents window (right click on a box).
    box: ?BoxOpen = null,
    /// Trigger window: the area's name (right click on an area).
    trigger: ?[]const u8 = null,
    /// The mod check's window (after Save).
    check: ?*@import("checkpanel.zig").Result = null,
    /// Play asked for while the port wasn't found: run once it's chosen (level, scene).
    play_pending: ?struct { buf: [128]u8 = undefined, level: usize = 0, scene: ?usize = null } = null,
    /// History: the row whose changed lines are shown — a step of this session or a save
    /// of an earlier one (history.Pick).
    history_pick: @import("history.zig").Pick = .none,
    /// Code window (codeview.zig).
    code: ?*code.View = null,
    /// Locations: walkable cells shown over the background.
    show_walk: bool = true,
    /// The level as the game draws it in place of its bare background: shown, the
    /// picture, the level world it was made from (a reload makes it again), the models.
    rendered: struct {
        on: bool = false,
        tex: ?*c.SDL_Texture = null,
        of: u32 = 0,
        models: ?og.actor.model_cache.Cache = null,
        textures: ?og.render.textures.Textures = null,
        /// The level's scene kept for drawing its visible part finer when zoomed in:
        /// that texture, its background rectangle and detail (x, y, w, h, k), the view
        /// last seen and when it last moved.
        scene: ?*@import("viewer").Scene = null,
        detail: ?*c.SDL_Texture = null,
        detail_key: [5]u32 = .{ 0, 0, 0, 0, 0 },
        view_key: [5]u32 = .{ 0, 0, 0, 0, 0 },
        moved_ms: u64 = 0,
        still_frames: u32 = 0,
    } = .{},
    /// Search typed in the menu or the box window (cleared when one opens).
    query_name: Name(64) = .{},
    /// SDL text input is on (typing a number or a search).
    text_input: bool = false,
    overlay_was: bool = false,
    /// Right button pressed over the level at this point (a click opens the menu).
    right_down: ?[2]f32 = null,
    /// A right click this frame away from the level (rows of the object list take it).
    right_clicked: bool = false,
    /// Object being dragged.
    moving: ?usize = null,
    /// Window size in points (headless edits lay out with it).
    size: [2]f32 = .{ 0, 0 },

    /// Everything the session made, freed (in the reverse order it was made); the
    /// level list and templates last (the templates point into its names).
    pub fn deinit(self: *App) void {
        const gpa = self.gpa;
        if (self.paint) |p| p.destroy(gpa);
        if (self.spr) |e| e.destroy(gpa);
        for (self.parked.items) |pk| if (pk.doc) |d| d.deinit();
        self.parked.deinit(gpa);
        self.paint_left.deinit(gpa);
        if (self.doc) |d| d.deinit();
        freeTextures(gpa, &self.icons);
        if (self.sprites) |*ar| ar.close(self.io, gpa);
        for (self.cursors) |cur| if (cur) |k| c.SDL_DestroyCursor(k);
        freeKeys(gpa, &self.view_hidden);
        @import("info.zig").deinit();
        @import("uses.zig").deinit();
        @import("model.zig").deinitSnippets(self.gpa);
        @import("rulespages.zig").deinit();
        @import("entry_rules.zig").deinit();
        @import("assettree.zig").deinit(self);
        @import("checkpanel.zig").close(self);
        for (self.video.list.items) |v| gpa.free(v);
        self.video.list.deinit(gpa);
        for (self.menu_refs.items) |ref| gpa.free(ref.label);
        self.menu_refs.deinit(gpa);
        self.setClip(null);
        freeKeys(gpa, &self.locked);
        if (self.code) |v| v.destroy(gpa);
        for (self.code_parked.items) |v| v.destroy(gpa);
        self.code_parked.deinit(gpa);
        self.doc_tabs.deinit(gpa);
        self.scenes.preview.names.deinit(gpa);
        @import("videopage.zig").stop(self);
        @import("convert.zig").wait(self);
        @import("projconvert.zig").drop(self);
        if (self.level_media) |*m| m.deinit();
        @import("logicview.zig").close(self);
        self.logic.cmds.deinit(gpa);
        self.dropReport();
        for (self.music.list.items) |m| gpa.free(m);
        self.music.list.deinit(gpa);
        freeTextures(gpa, &self.anims.tex);
        for (self.models.items) |m| gpa.free(m);
        self.models.deinit(gpa);
        freeTextures(gpa, &self.effect.tex);
        @import("postpage.zig").deinit(self);
        if (self.fonts.edit) |*fe| fe.deinit(gpa);
        if (self.campaign.panel) |t| c.SDL_DestroyTexture(t);
        self.player.deinit(gpa);
        @import("viewport.zig").dropRendered(self);
        if (self.rendered.textures) |*t| t.deinit();
        if (self.rendered.models) |*m| m.deinit();
        self.preview.deinit();
        if (self.stale_catalog) |*old| old.deinit();
        self.catalog.deinit();
        self.store.deinit();
        self.frame.deinit();
        level.freeTemplates(gpa, self.templates);
        gpa.free(self.templates);
        for (self.levels) |e| gpa.free(e.name);
        gpa.free(self.levels);
    }

    fn freeTextures(gpa: Allocator, m: *std.StringHashMapUnmanaged(?*c.SDL_Texture)) void {
        var it = m.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            if (kv.value_ptr.*) |t| c.SDL_DestroyTexture(t);
        }
        m.deinit(gpa);
    }

    fn freeKeys(gpa: Allocator, m: *std.StringHashMapUnmanaged(void)) void {
        var it = m.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        m.deinit(gpa);
    }

    /// The OG layout: the OpenGorky-only fields, rows and edits (own
    /// rules rows, abilities, hooks, materials, post chains, the port's import limits), on
    /// an OpenGorky project (`format = ogs`): its pages write its `src/` texts through the
    /// OG writer (model_og.zig, store.og_src). Classic never shows them (no locks).
    pub fn ogLayout(self: *const App) bool {
        return self.project.format == .ogs;
    }

    /// Whom imported models and textures are made for: the exe (Classic) or the port only.
    pub fn importTarget(self: *const App) og.formats.mesh.Target {
        return if (self.ogLayout()) .port else .both;
    }

    pub fn setStatus(self: *App, comptime m: tx.Msg, args: anytype) void {
        self.status = tx.print(&self.status_buf, m, args);
    }

    /// `setStatus`, and the message in a window (`title` its heading) until closed.
    pub fn setAlert(self: *App, comptime title: tx.Msg, comptime m: tx.Msg, args: anytype) void {
        self.setStatus(m, args);
        self.alert = .{ .title = tx.get(title), .text = tx.print(&self.alert_buf, m, args) };
    }

    /// An edit that failed, in the status line.
    pub fn failed(self: *App, err: anyerror) void {
        self.setStatus(tx.st_set_failed, .{err});
    }

    /// `setStatus`, then in an OpenGorky project the limits an import had (`limits`:
    /// tx.st_og_art, tx.st_og_video); Classic imports refuse past the exe's instead.
    pub fn setStatusPort(self: *App, comptime m: tx.Msg, args: anytype, comptime limits: tx.Msg) void {
        self.setStatus(m, args);
        if (!self.ogLayout()) return;
        const tail = tx.get(limits);
        const n = @min(tail.len, self.status_buf.len - self.status.len);
        @memcpy(self.status_buf[self.status.len..][0..n], tail[0..n]);
        self.status = self.status_buf[0 .. self.status.len + n];
    }

    pub fn setLang(self: *App, l: tx.Lang) void {
        if (tx.lang == l) return;
        tx.lang = l;
        self.settings.lang = l;
        self.saveSettings();
        _ = c.SDL_SetWindowTitle(self.window, tx.get(tx.title).ptr);
        self.status = "";
    }

    /// Pane `k`'s size: its share of the window (layout.pane).
    pub fn pane(self: *const App, k: Split) f32 {
        const room = self.size[@intFromBool(k == .entry_y)];
        // The model over the animations may take more of the height than a column the width.
        return lay.pane(room, self.settings.split(k), if (k == .entry_y) 0.7 else 0.5);
    }

    /// A side pane that isn't dragged: its share `frac` of the window (layout.pane).
    pub fn sidePane(self: *const App, frac: f32) f32 {
        return lay.pane(self.size[0], frac, 0.25);
    }

    /// A draggable edge between panes for size `key`: a bar `across` (between rows) or
    /// down (between columns); `n` tells apart two bars of one size.
    pub fn splitter(self: *App, key: Split, across: bool, sign: f32, n: u32) void {
        const id = clay.idi("split", @as(u32, @backingInt(key)) * 4 + n);
        const active = if (self.split_drag) |d| d.key == key else false;
        clay.leaf(.{
            .id = id,
            .layout = .{ .sizing = if (across) .{ .width = clay.grow(), .height = clay.fixed(lay.border.edge) } else .{ .width = clay.fixed(lay.border.edge), .height = clay.grow() } },
            .backgroundColor = if (active or clay.pointerOver(id)) theme.accent else theme.bg,
        });
        if (!clay.pointerOver(id) and !active) return;
        self.cursor_want = @intFromBool(across);
        if (self.clicked and self.split_drag == null) {
            self.split_drag = .{ .key = key, .across = across, .from = self.mouse[@intFromBool(across)], .start = self.pane(key), .sign = sign };
            self.clicked = false;
        }
    }

    /// Each frame: the dragged edge follows the pointer; on release the sizes are kept.
    pub fn dragSplit(self: *App) void {
        const d = self.split_drag orelse return;
        if (!self.down) {
            self.split_drag = null;
            return self.saveSettings();
        }
        // Kept as a share of the window (layout.pane keeps it to its min and max).
        const room = @max(1, self.size[@intFromBool(d.across)]);
        self.settings.splits[@backingInt(d.key)] = std.math.clamp((d.start + (self.mouse[@intFromBool(d.across)] - d.from) * d.sign) / room, 0.01, 1);
    }

    /// The resize cursor over (or dragging) an edge, else the arrow.
    pub fn applyCursor(self: *App) void {
        if (self.cursor_want) |k| {
            if (self.cursors[k] == null) self.cursors[k] = c.SDL_CreateSystemCursor(if (k == 0) c.SDL_SYSTEM_CURSOR_EW_RESIZE else c.SDL_SYSTEM_CURSOR_NS_RESIZE);
            if (self.cursors[k]) |cur| _ = c.SDL_SetCursor(cur);
        } else _ = c.SDL_SetCursor(c.SDL_GetDefaultCursor());
        self.cursor_want = null;
    }

    pub fn saveSettings(self: *App) void {
        const path = self.settings_path orelse return;
        var buf: [4096]u8 = undefined;
        const data = self.settings.format(&buf) catch return;
        Io.Dir.cwd().createDirPath(self.io, std.fs.path.dirname(path).?) catch return;
        config.writeAtomic(self.io, path, data) catch |err| std.log.warn("{s}: {t}", .{ path, err });
    }

    // Reloading and undo (app_reload.zig).
    pub const discardDoc = app_reload.discardDoc;
    pub const afterStoreChange = app_reload.afterStoreChange;
    pub const rebuildCatalog = app_reload.rebuildCatalog;
    pub const save = app_reload.save;
    pub const saveFirst = app_reload.saveFirst;
    pub const saveOnly = app_reload.saveOnly;
    pub const undo = app_reload.undo;
    pub const rollBack = app_reload.rollBack;
    pub const returnToPast = app_reload.returnToPast;

    /// Object (or `kind:<kind>`) `key` shown or hidden in the view.
    pub fn toggleHidden(self: *App, key: []const u8) void {
        if (self.view_hidden.fetchRemove(key)) |kv| return self.gpa.free(kv.key);
        const k = self.gpa.dupe(u8, key) catch return;
        self.view_hidden.put(self.gpa, k, {}) catch self.gpa.free(k);
    }

    pub const closeLevel = app_levels.closeLevel;
    pub const dropLevelSelection = app_levels.dropLevelSelection;
    pub const dropMissingLevels = app_levels.dropMissingLevels;
    pub const dropParked = app_levels.dropParked;
    pub const clearParked = app_levels.clearParked;
    pub const park = app_levels.park;
    pub const unpark = app_levels.unpark;
    pub const levelDoc = app_levels.levelDoc;
    pub const dropLooks = app_levels.dropLooks;
    pub const forgetLevel = app_levels.forgetLevel;
    pub const eachDoc = app_levels.eachDoc;

    /// Shows tab `t` (its page over the code shown, which stays in its tab): the level of
    /// battles and of locations each as it was left; an entry page empty until one is picked.
    pub fn setTab(self: *App, t: Tab) void {
        codeview.park(self);
        if (t == self.tab) return;
        self.leavePaint();
        self.closePaint();
        self.tab = t;
        self.entry = null;
        self.pick = null;
        if (t != .battles and t != .locations) return;
        defer self.backToPaint();
        const want_battle = t == .battles;
        const have = if (self.doc) |d| d.isBattle() == want_battle else false;
        if (have) return;
        // The open level kept; the last one left of this kind comes back.
        self.park();
        var pk = self.parked.items.len;
        while (pk > 0) {
            pk -= 1;
            if (self.levels[self.parked.items[pk].current].battle == want_battle) {
                self.unparkInto(pk);
                break;
            }
        }
        self.dropLevelSelection();
        if (self.doc == null) if (self.current) |i| self.open(i, false);
    }

    const unparkInto = app_levels.unparkInto;

    /// Icon `name` (`icons\<name>.spr`, first frame) as a texture; null — none.
    pub fn icon(self: *App, name: []const u8) ?*c.SDL_Texture {
        if (name.len == 0 or name.len > 64) return null;
        var key_buf: [64]u8 = undefined;
        const key = std.ascii.lowerString(&key_buf, name);
        if (self.icons.get(key)) |t| return t;
        const t = self.loadIcon(name) catch null;
        const k = self.gpa.dupe(u8, key) catch return t;
        self.icons.put(self.gpa, k, t) catch self.gpa.free(k);
        return t;
    }

    /// Icon `name` drawn again (edited).
    pub fn forgetIcon(self: *App, name: []const u8) void {
        var key_buf: [64]u8 = undefined;
        if (name.len > key_buf.len) return;
        const key = std.ascii.lowerString(&key_buf, name);
        const kv = self.icons.fetchRemove(key) orelse return;
        if (kv.value) |t| c.SDL_DestroyTexture(t);
        self.gpa.free(kv.key);
    }

    fn loadIcon(self: *App, name: []const u8) !?*c.SDL_Texture {
        var buf: [96]u8 = undefined;
        return self.spriteTexture(try std.fmt.bufPrint(&buf, "icons\\{s}.spr", .{name}));
    }

    /// Sprite `entry` of sprite.dat (its first frame) as a texture, the caller's; null — none.
    pub fn spriteTexture(self: *App, entry: []const u8) !?*c.SDL_Texture {
        // A new icon is in the Store until saved.
        const bytes = if (self.store.find(store_mod.sprite_archive, entry)) |i| try self.gpa.dupe(u8, self.store.text(i)) else blk: {
            const ar = self.sprites orelse return null;
            const e = ar.find(entry) orelse return null;
            break :blk try ar.readAlloc(self.io, self.gpa, e);
        };
        defer self.gpa.free(bytes);
        var spr = try og.formats.sprite.parse(self.gpa, bytes);
        defer spr.deinit(self.gpa);
        if (spr.frames.len == 0) return null;
        var img = try og.formats.sprite.decodeFrame(self.gpa, spr.frames[0]);
        defer img.deinit(self.gpa);
        const t = c.SDL_CreateTexture(self.r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, @intCast(img.width), @intCast(img.height)) orelse return null;
        _ = c.SDL_UpdateTexture(t, null, img.pixels.ptr, @intCast(img.width * 4));
        _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_BLEND);
        return t;
    }

    pub const open = app_levels.open;

    pub fn dropReport(self: *App) void {
        const r = &(self.scenes.report orelse return);
        self.gpa.free(r.name);
        self.gpa.free(r.level);
        r.report.deinit(self.gpa);
        self.scenes.report = null;
    }

    pub const reloadLevel = app_levels.reloadLevel;
    pub const paintKeep = app_levels.paintKeep;
    pub const paintAgain = app_levels.paintAgain;
    pub const leavePaint = app_levels.leavePaint;
    pub const backToPaint = app_levels.backToPaint;
    pub const openPaint = app_levels.openPaint;
    pub const closePaint = app_levels.closePaint;
    pub const endPaint = app_levels.endPaint;

    pub const removeSelected = level_edit.removeSelected;

    /// Battle palette: the game's enemy classes, then classes made in the editor
    /// (fighters of their base class, including the new class).
    pub fn allTemplates(self: *App, a: Allocator) []const level.Template {
        var list: std.ArrayList(level.Template) = .empty;
        list.appendSlice(a, self.templates) catch return self.templates;
        for (self.catalog.entries.items) |e| {
            const base = e.base orelse continue;
            if (e.kind != .enemy) continue;
            for (self.templates) |t| if (std.ascii.eqlIgnoreCase(t.class, base)) {
                var nt = t;
                nt.class = e.id;
                nt.base = base;
                list.append(a, nt) catch {};
                break;
            };
        }
        return list.items;
    }

    pub const addEnemy = level_edit.appAddEnemy;
    pub const addObstacle = level_edit.appAddObstacle;
    pub const addProp = level_edit.appAddProp;

    /// Files of the selected battle enemy (looked up once per selection).
    pub fn selectedEnemy(self: *App) ?level.Enemy {
        const d = self.doc orelse return null;
        const i = self.selected orelse return null;
        const o = d.objects.items[i];
        if (!d.isBattle() or o.kind != .enemy) return null;
        if (self.enemy_of != o.name.ptr) {
            self.enemy_of = o.name.ptr;
            self.enemy = d.enemy(o.name) catch |err| blk: {
                self.setStatus(tx.st_no_fighter, .{ o.name, err });
                break :blk null;
            };
        }
        return self.enemy;
    }

    /// Asks for a PNG to read (or, to export, a place to write one).
    pub fn askFile(self: *App, ask: FileAsk) void {
        self.asking = ask;
        dialog_ready.store(false, .release);
        if (ask.kind == .folder) return c.SDL_ShowOpenFolderDialog(dialogDone, null, self.window, null, false);
        // Any file (an .app bundle is one in the macOS panel).
        if (ask.kind == .program) return c.SDL_ShowOpenFileDialog(dialogDone, null, self.window, null, 0, null, false);
        const filter: c.SDL_DialogFileFilter = switch (ask.kind) {
            .png, .png_out => .{ .name = "PNG", .pattern = "png" },
            .sound => .{ .name = "WAV, MP3", .pattern = "wav;mp3" },
            .wav_out => .{ .name = "WAV", .pattern = "wav" },
            .audio => .{ .name = "Audio", .pattern = "mp3;wav;ogg;flac;m4a;aac;opus" },
            .video => .{ .name = "Video", .pattern = "mp4;mov;avi;mkv;webm;wmv;asf;mpg" },
            .ttf => .{ .name = "TrueType", .pattern = "ttf;otf" },
            .glb, .glb_out => .{ .name = "glTF Binary", .pattern = "glb" },
            .folder, .program => unreachable,
        };
        const filters = [_]c.SDL_DialogFileFilter{filter};
        if (ask.kind == .png_out or ask.kind == .wav_out or ask.kind == .glb_out) {
            c.SDL_ShowSaveFileDialog(dialogDone, null, self.window, &filters, 1, suggestedPath(ask));
        } else c.SDL_ShowOpenFileDialog(dialogDone, null, self.window, &filters, 1, null, false);
    }

    /// An export's place to start: `~/Downloads/<the original's name>.<the export's ext>`
    /// (the dialog's name field then holds the original's name); null: none named.
    fn suggestedPath(ask: FileAsk) ?[*:0]const u8 {
        const S = struct {
            var buf: [1024]u8 = undefined;
        };
        if (ask.name.len == 0) return null;
        const ext: []const u8 = switch (ask.kind) {
            .png_out => ".png",
            .wav_out => ".wav",
            .glb_out => ".glb",
            else => "",
        };
        // `icons\axe.spr` → `axe`: the base name without its own extension.
        const base = ask.name[if (std.mem.lastIndexOfAny(u8, ask.name, "/\\")) |k| k + 1 else 0..];
        const stem = base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];
        const home = std.c.getenv("HOME") orelse std.c.getenv("USERPROFILE") orelse return null;
        const p = std.fmt.bufPrint(&S.buf, "{s}/Downloads/{s}{s}\x00", .{ std.mem.span(home), stem, ext }) catch return null;
        return @ptrCast(p.ptr);
    }

    /// The mod packed into folder `out`: the files the editor's saves changed (its
    /// history in the game folder).
    pub fn packMod(self: *App, out: []const u8) !void {
        if (!self.saveFirst()) return;
        const cwd = Io.Dir.cwd();
        var game = try cwd.openDir(self.io, self.game_dir, .{});
        defer game.close(self.io);
        try cwd.createDirPath(self.io, out);
        var dest = try cwd.openDir(self.io, out, .{});
        defer dest.close(self.io);
        const modpack = @import("modpack.zig");
        const files = try modpack.pack(self.io, self.gpa, game, dest);
        defer modpack.freeList(self.gpa, files);
        self.setStatus(tx.st_packed, .{ files.len, out });
    }

    pub fn onPackage(self: *App, _: FileAsk, path: []const u8) !void {
        try self.packMod(path);
    }

    /// The path chosen for `ask` handled.
    pub fn fileChosen(self: *App, ask: FileAsk, path: []const u8) void {
        ask.run(self, ask, path) catch |err| self.setStatus(tx.st_import_failed, .{err});
    }

    /// Asks for the game folder (settings). With unsaved edits it says to save them first:
    /// another folder starts the editor anew.
    pub fn askGame(self: *App) void {
        if (self.store.dirty()) return self.setStatus(tx.st_save_first, .{});
        self.asking_game = true;
        dialog_ready.store(false, .release);
        c.SDL_ShowOpenFolderDialog(dialogDone, null, self.window, null, false);
    }

    /// The editor started anew on folder `path`, as on one picked in the settings (the
    /// main loop takes it at the frame's end: takeGame).
    pub fn reopen(self: *App, path: []const u8) void {
        const n = @min(path.len, dialog_path.len);
        @memcpy(dialog_path[0..n], path[0..n]);
        dialog_len = n;
        self.asking_game = true;
        dialog_ready.store(true, .release);
    }

    /// The folder chosen for the game, once.
    pub fn takeGame(self: *App) ?[]const u8 {
        if (!self.asking_game or !dialog_ready.load(.acquire)) return null;
        dialog_ready.store(false, .release);
        self.asking_game = false;
        return dialog_path[0..dialog_len];
    }

    /// The file chosen in the dialog, once (fileChosen handles it).
    pub fn takeDialog(self: *App) ?struct { ask: FileAsk, path: []const u8 } {
        const ask = self.asking orelse return null;
        if (!dialog_ready.load(.acquire)) return null;
        dialog_ready.store(false, .release);
        self.asking = null;
        return .{ .ask = ask, .path = dialog_path[0..dialog_len] };
    }

    pub const stopEditing = textedit.stopEditing;

    pub fn treeQuery(self: *const App) []const u8 {
        return self.tree_query.get();
    }

    pub fn query(self: *const App) []const u8 {
        return self.query_name.get();
    }

    /// The asset tree's search typed into (Cmd K, the new tab's +).
    pub fn focusTree(self: *App) void {
        textedit.focusEnd(self, clay.id("tree_search"), self.tree_query.get(), @import("search.zig").keep.any, textedit.live(&self.tree_query));
    }

    /// The level edit mode with its Objects tool: objects are moved, added, removed
    /// (the view mode only shows them).
    pub fn editingObjects(self: *const App) bool {
        return if (self.paint) |p| p.tool == .objects else false;
    }

    /// Something over the centre that takes the mouse and keys: a window (`modal`), the
    /// code, the sprite canvas.
    pub fn overlay(self: *const App) bool {
        return self.modal() or self.code != null or self.sprShown() != null;
    }

    /// A window open over everything: a menu, a question, the box, trigger or check window.
    pub fn modal(self: *const App) bool {
        return self.menu != null or self.tree_menu != null or self.confirm != null or self.alert != null or self.proj_convert != null or self.box != null or self.trigger != null or (if (self.check) |r| r.shown else false);
    }

    /// Tab `t`'s page is the centre (no code over it).
    fn pageShown(self: *const App, t: Tab) bool {
        return self.tab == t and self.code == null;
    }

    /// A level's map is the centre (a battle's or a location's tab, no code over it).
    pub fn levelShown(self: *const App) bool {
        return self.pageShown(.battles) or self.pageShown(.locations);
    }

    /// The open sprite when its page is the centre's document (else its canvas is not drawn).
    pub fn sprShown(self: *const App) ?*@import("sprview.zig").Edit {
        return if (self.pageShown(.sprites)) self.spr else null;
    }

    /// The contents window of box `name` of the open level (an object's name, its Doc's);
    /// false: not a box.
    pub fn openBox(self: *App, name: []const u8) bool {
        const d = self.doc orelse return false;
        self.box = .{ .file = d.boxFile(name) orelse return false, .name = name };
        return true;
    }

    /// The Scenes tab on dialogue `name` (`01__port_bulldozer.dlg`).
    pub fn showDialog(self: *App, name: []const u8) void {
        doctabs.show(self, .scenes, name);
    }

    /// A new sprite from a PNG into `archive` (`icons`: an icon) — asks for the file.
    pub fn askNewSprite(self: *App, archive: []const u8, icons_dir: bool) void {
        self.spr_new.set(archive);
        self.spr_new_icons = icons_dir;
        self.askFile(.{ .kind = .png, .run = @import("sprview.zig").onNew });
    }

    /// The catalog's names from string.tab as edited (by each entry's classic_id).
    pub fn refreshTitles(self: *App) void {
        const texts = @import("texts.zig");
        const rs = texts.rows(self, self.frame.allocator(), .strings);
        const ca = self.catalog.arena.allocator();
        for (self.catalog.entries.items) |*e| {
            const id = e.name_id orelse continue;
            for (rs) |r| if (r.id == id) {
                if (!std.mem.eql(u8, e.title, r.text)) e.title = ca.dupe(u8, r.text) catch e.title;
                break;
            };
        }
    }

    /// A music file to import, as `target` (a level's own track) or by its name.
    pub fn askMusic(self: *App, target: ?[]const u8) void {
        const t = target orelse "";
        self.music.target.set(t);
        self.askFile(.{ .kind = .audio, .run = @import("musicpage.zig").onMusicIn });
    }

    /// A new script `classes\script<N>.s` (includable by levels and classes), opened in
    /// the code editor; one undo step.
    pub fn newScript(self: *App) void {
        var nb: [48]u8 = undefined;
        const entry = for (1..1000) |n| {
            const e = std.fmt.bufPrint(&nb, "classes\\script{d}.s", .{n}) catch unreachable;
            // Neither in the Store nor in the archive (a deleted one too: its name stays taken).
            if (self.store.find(common_archive, e) == null and (self.store.file(common_archive, e) catch null) == null) break e;
        } else return;
        const base = entry["classes\\".len..];
        const text = std.fmt.allocPrint(self.gpa, "// A script made in the editor: #include {s} in a level or class script takes it in.\r\n", .{base}) catch return;
        const f = self.store.addNew(&.{.{ .archive = common_archive, .entry = entry, .text = text }}) catch |err| return self.failed(err);
        doctabs.showCode(self, f, null);
        self.setStatus(tx.st_script_added, .{ base, base });
    }

    pub const syncTextInput = textedit.syncTextInput;
    pub const commitEditing = textedit.commitEditing;
    pub const typed = textedit.typed;

    pub const clipOf = level_edit.clipOf;
    pub const setClip = level_edit.setClip;
    pub const copyObject = level_edit.copyObject;
    pub const paste = level_edit.paste;
    pub const duplicate = level_edit.duplicate;

    /// Deletion `what` of `index` / `name` asked about first ("Delete <name>?").
    pub fn askDelete(self: *App, what: @FieldType(Confirm, "what"), index: usize, name: []const u8) void {
        var cf: Confirm = .{ .what = what, .index = index };
        cf.arg_len = @min(name.len, cf.arg_buf.len);
        @memcpy(cf.arg_buf[0..cf.arg_len], name[0..cf.arg_len]);
        const t = switch (what) {
            .text_row => tx.print(&cf.text_buf, tx.cf_text_row, .{ index, name }),
            .frame => tx.print(&cf.text_buf, tx.cf_frame, .{name}),
            .purge => tx.print(&cf.text_buf, tx.cf_purge, .{name}),
            else => tx.print(&cf.text_buf, tx.cf_delete, .{name}),
        };
        cf.text_len = t.len;
        self.confirm = cf;
    }

    /// The confirmed deletion done.
    pub fn confirmed(self: *App) void {
        const cf = self.confirm orelse return;
        self.confirm = null;
        const n = cf.arg();
        switch (cf.what) {
            .object => {
                self.selected = cf.index;
                self.removeSelected();
            },
            .box => self.deleteBox(cf.index),
            .hero => {
                self.hero_drop.set(n);
            },
            .area => if (self.paint) |p| {
                paint.pickName(p, n);
                p.pending = .delete;
            },
            .point => paint.dropPoint(self, n),
            .light => paint.dropLight(self, cf.index),
            .frame => sprview.removeFrame(self, cf.index) catch |err| self.setStatus(tx.st_remove_failed, .{err}),
            .voice => @import("voices.zig").remove(self, n) catch |err| self.failed(err),
            .text_row => {
                const texts = @import("texts.zig");
                const f: texts.File = for (std.enums.values(texts.File)) |v| {
                    if (std.mem.eql(u8, v.entry(), n)) break v;
                } else .strings;
                texts.remove(self, f, @intCast(cf.index)) catch |err| self.failed(err);
            },
            .anim => if (self.doc) |d| @import("levelanims.zig").remove(self, d, n),
            .path => if (self.doc) |d| @import("paths.zig").remove(self, d, n),
            .effect_frame => @import("effectpage.zig").removeFrame(self, cf.index) catch |err| self.setStatus(tx.st_remove_failed, .{err}),
            .model => @import("look_pages.zig").deleteModel(self, n) catch |err| self.setStatus(tx.st_remove_failed, .{err}),
            .entry => @import("entry_copy.zig").deleteOg(self, n) catch |err| self.setStatus(tx.st_remove_failed, .{err}),
            .purge => if (self.doc) |d| for (d.orphans(self.frame.allocator()) catch &.{}) |o| d.dropFiles(o) catch |err| self.setStatus(tx.st_remove_failed, .{err}),
        }
    }

    /// Object `name` locked (the editor does not move it) or unlocked.
    pub fn toggleLocked(self: *App, name: []const u8) void {
        if (self.locked.fetchRemove(name)) |kv| return self.gpa.free(kv.key);
        const k = self.gpa.dupe(u8, name) catch return;
        self.locked.put(self.gpa, k, {}) catch self.gpa.free(k);
    }

    /// The view centred on background point `p`.
    pub fn centreOn(self: *App, p: [2]f32) void {
        const d = self.doc orelse return;
        const v = viewportRect() orelse return;
        if (!d.fitted) d.fit(v);
        d.origin = .{ p[0] - v.w / 2 / d.zoom, p[1] - v.h / 2 / d.zoom };
    }

    /// Lines of the level's scripts and the scenes naming `name` (quoted), for the menu
    /// (the where-used index's texts, uses.zig).
    fn findRefs(self: *App, name: []const u8) void {
        for (self.menu_refs.items) |r| self.gpa.free(r.label);
        self.menu_refs.clearRetainingCapacity();
        const d = self.doc orelse return;
        var qb: [80]u8 = undefined;
        const needle = std.fmt.bufPrint(&qb, "\"{s}\"", .{name}) catch return;
        const ix = @import("uses.zig").get(self);
        const where = [_]struct { []const u8, []const refs.File }{ .{ d.level_archive, ix.level(d.name) }, .{ common_archive, ix.scenes } };
        for (where) |wh| for (wh[1]) |f| {
            const t = f.text;
            var from: usize = 0;
            while (std.ascii.findIgnoreCasePos(t, from, needle)) |at| : (from = at + needle.len) {
                const ls = if (std.mem.lastIndexOfScalar(u8, t[0..at], '\n')) |k| k + 1 else 0;
                const le = std.mem.indexOfScalarPos(u8, t, at, '\n') orelse t.len;
                var line: usize = 1;
                for (t[0..at]) |ch| line += @intFromBool(ch == '\n');
                const text = std.mem.trim(u8, t[ls..le], " \t\r");
                const label = std.fmt.allocPrint(self.gpa, "{s}:{d}  {s}", .{ f.name, line, text[0..@min(text.len, 60)] }) catch continue;
                self.menu_refs.append(self.gpa, .{ .path = wh[0], .entry = label[0..f.name.len], .at = at, .label = label }) catch self.gpa.free(label);
                if (self.menu_refs.items.len >= 40) return;
            }
        };
    }

    pub fn modelNames(self: *App) []const []u8 {
        if (self.models.items.len > 0) return self.models.items;
        var ar = og.formats.archive.Archive.open(self.io, self.gpa, self.dat, common_archive) catch return self.models.items;
        defer ar.close(self.io, self.gpa);
        for (ar.entries) |e| {
            if (!std.ascii.startsWithIgnoreCase(e.name, "gfx_3d\\") or !std.ascii.endsWithIgnoreCase(e.name, ".msh")) continue;
            const stem = e.name["gfx_3d\\".len .. e.name.len - 4];
            if (std.mem.indexOfScalar(u8, stem, '\\') != null) continue;
            self.models.append(self.gpa, self.gpa.dupe(u8, stem) catch continue) catch {};
        }
        return self.models.items;
    }

    pub const addActor = level_edit.appAddActor;
    pub const addBox = level_edit.appAddBox;

    pub fn openMenu(self: *App) void {
        if (self.paint == null and self.rendered.on) return; // the preview: no editing
        const d = self.doc orelse return;
        const v = viewportRect() orelse return;
        const picked = d.pick(v, self.mouse);
        if (picked) |i| self.selected = i;
        self.menu = .{ .at = self.menuAt(), .grid = d.gridAt(v, self.mouse), .obj = picked, .bg = d.toBackground(v, self.mouse) };
        if (picked) |i| self.findRefs(d.objects.items[i].name);
    }

    /// The menu for object `i` (a right click on its row in the list).
    pub fn openMenuFor(self: *App, i: usize) void {
        const d = self.doc orelse return;
        self.selected = i;
        self.menu = .{ .at = self.menuAt(), .grid = null, .obj = i, .bg = d.objects.items[i].pos };
        self.findRefs(d.objects.items[i].name);
    }

    /// At the pointer, kept inside the window (with the search and list ~560 points tall).
    fn menuAt(self: *App) [2]f32 {
        return .{ @min(self.mouse[0], self.size[0] - 264), @max(0, @min(self.mouse[1], self.size[1] - 560)) };
    }

    pub const link = doctabs.link;
    pub const followLink = doctabs.followLink;
    pub const showScene = doctabs.showScene;
    pub const showLevel = doctabs.showLevel;

    /// The scene shown in the Scenes tab, as the catalog has it; null: none (or a
    /// dialogue, or a scene the catalog no longer has).
    pub fn sceneName(self: *const App) ?[]const u8 {
        if (self.dialogName() != null) return null;
        const i = self.sceneIndex(self.scene.get()) orelse return null;
        return self.catalog.scenes.items[i].name;
    }

    /// The dialogue shown in the Scenes tab instead of a scene; null: none.
    pub fn dialogName(self: *const App) ?[]const u8 {
        const n = self.scene.get();
        return if (std.ascii.endsWithIgnoreCase(n, ".dlg")) n else null;
    }

    /// The catalog's scene `name` (any case; the first of that name).
    pub fn sceneIndex(self: *const App, name: []const u8) ?usize {
        for (self.catalog.scenes.items, 0..) |sc, i| if (std.ascii.eqlIgnoreCase(sc.name, name)) return i;
        return null;
    }

    /// Level `name` in the list (any case; the first of that name).
    pub fn levelIndex(self: *const App, name: []const u8) ?usize {
        for (self.levels, 0..) |l, i| if (std.ascii.eqlIgnoreCase(l.name, name)) return i;
        return null;
    }

    pub const deleteBox = level_edit.appDeleteBox;

    pub fn viewportRect() ?c.SDL_FRect {
        const b = clay.box(clay.id("viewport")) orelse return null;
        return .{ .x = b.x, .y = b.y, .w = b.width, .h = b.height };
    }

    pub fn overViewport(self: *const App) bool {
        const v = viewportRect() orelse return false;
        return self.mouse[0] >= v.x and self.mouse[0] < v.x + v.w and self.mouse[1] >= v.y and self.mouse[1] < v.y + v.h;
    }
};

/// Game name of enemy class `class` ("" — unknown).
pub fn enemyTitle(self: *App, class: []const u8) []const u8 {
    for (self.catalog.entries.items) |e| if (e.kind == .enemy and std.ascii.eqlIgnoreCase(e.id, class)) return e.title;
    return "";
}

pub fn fmtNum(a: Allocator, v: ?f32) []const u8 {
    const x = v orelse return "—";
    return std.fmt.allocPrint(a, "{d}", .{x}) catch "?";
}

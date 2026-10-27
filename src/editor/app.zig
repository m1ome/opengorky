//! The editor's state (App), shared types and small widgets used by every page.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const ui = @import("ui");
const clay = @import("clay.zig");
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
const paint = @import("paint.zig");
const doctabs = @import("doctabs.zig");
const trigger = @import("trigger.zig");
const newlevel = @import("newlevel.zig");
const placement = @import("placement.zig");
const refs = @import("refs.zig");
const common_archive = @import("store.zig").common_archive;
const search = @import("search.zig");
const code = @import("code.zig");

/// A list of values to pick for a field of file `file` (pages.zig).
pub const Picker = struct {
    what: What,
    file: usize,
    /// `.sound`: the animation (index in the `.ani`) and its cue (null — a new one).
    anim: usize = 0,
    cue: ?usize = null,
};
const What = enum { act, icon, mesh, damage, weapon_class, ammo, sound, enemy_weapon };

/// What a chosen PNG is for.
/// The box being edited (boxpanel.zig): its script (Store index) and object name.
pub const BoxOpen = struct {
    file: usize,
    name: []const u8,
    /// A hero's starting inventory (the calls giving items to this owner) instead of a box.
    owner: ?[]const u8 = null,
};

/// Dark neutral greys with one blue accent, as Unreal Engine's and Unity's editors:
/// docked panels on a darker frame, inset fields, rounded controls.
pub const theme = struct {
    /// The frame behind the panels (top bar, gaps, status bar).
    pub const bg = clay.rgb(0x15171b);
    pub const panel = clay.rgb(0x1b1e23);
    /// Panel title bars and toolbars.
    pub const header = clay.rgb(0x20242a);
    pub const row_hover = clay.rgb(0x272b32);
    pub const row_selected = clay.rgb(0x2f7cf6);
    pub const viewport = clay.rgb(0x101114);
    pub const text = clay.rgb(0xe3e6ea);
    pub const dim = clay.rgb(0x8b919b);
    pub const line = clay.rgb(0x2a2e35);
    pub const accent = clay.rgb(0x2f7cf6);
    pub const accent_hover = clay.rgb(0x5a98f8);
    pub const warn = clay.rgb(0xe8a33d);
    pub const ok = clay.rgb(0x3fb950);
    /// Inset value fields and their frame.
    pub const field = clay.rgb(0x14161a);
    pub const field_border = clay.rgb(0x333842);
    /// Buttons: their face (hovered, pressed) and outline; title bars.
    pub const button = clay.rgb(0x23272e);
    pub const button_hover = clay.rgb(0x2c313a);
    const button_down = clay.rgb(0x1c1f25);
    pub const button_edge = clay.rgb(0x363b45);
    pub const title = clay.rgb(0x20242a);
    pub const radius = 6;
};

/// The right panel's page.
pub const Inspector = enum { inspector, history };

/// A script line naming something: its Store file, byte offset and the line shown (owned).
/// (`entry` points into `label`; `path` is the level's or common's archive).
const Ref = struct { path: []const u8, entry: []const u8, at: usize, label: []u8 };

/// The scene page's map: the location, its starting area, the objects the scene names.
pub const ScenePreview = struct {
    doc: ?*Doc = null,
    sel: ?usize = null,
    focus: ?[4]f32 = null,
    names: std.ArrayList(usize) = .empty,
    show: [3]bool = .{ true, true, true },
};

/// A deletion asked about first (the confirmation window): what, on which object.
pub const Confirm = struct {
    what: enum { object, box, hero, area, point, light, frame, voice, purge, text_row, anim, path, effect_frame },
    /// The object or frame index; the name (area, point, voice, hero).
    index: usize = 0,
    arg_buf: [64]u8 = undefined,
    arg_len: usize = 0,
    text_buf: [240]u8 = undefined,
    text_len: usize = 0,

    pub fn arg(self: *const Confirm) []const u8 {
        return self.arg_buf[0..self.arg_len];
    }

    pub fn text(self: *const Confirm) []const u8 {
        return self.text_buf[0..self.text_len];
    }
};

/// An animation dragged on the map: its name, where its top-left goes, the grab offset.
pub const AnimDrag = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    at: [2]f32,
    off: [2]f32,

    pub fn name(self: *const AnimDrag) []const u8 {
        return self.buf[0..self.len];
    }
};

/// A level kept loaded in its tab while another is shown.
const Parked = struct { doc: ?*Doc, current: usize };

/// A level's edit mode as it was: its tool, layer, shown and locked layers.
const PaintKeep = struct { tool: paint.Tool, layer: paint.Layer, show: [5]bool, locked: [5]bool, show_objects: bool };

pub const Tab = enum {
    battles,
    locations,
    enemies,
    items,
    heroes,
    scenes,
    sounds,
    videos,
    music,
    texts,
    fonts,
    effects,
    sprites,
    /// adjust.kdt: the engine's tuning values.
    adjust,
    history,
    settings,
    /// Only a document tab's kind (code in the centre over any tab), never `app.tab`.
    code,
};

/// An editable parameter: its label and variables (HP sets hp and max_hp).
pub const Stat = struct { label: tx.Msg, names: []const []const u8 };

/// What enemies and heroes share; each list goes on with its own.
pub const base_stats = [_]Stat{
    .{ .label = tx.p_hp, .names = &.{ "hp", "max_hp" } },
    .{ .label = tx.p_armor, .names = &.{"armor"} },
    .{ .label = tx.p_walk, .names = &.{"walk_range"} },
    .{ .label = tx.p_accuracy, .names = &.{"accuracy"} },
    .{ .label = tx.p_luck, .names = &.{"luck"} },
};

pub const fighter_stats = base_stats ++ [_]Stat{
    .{ .label = tx.p_calmness, .names = &.{"calmness"} },
    .{ .label = tx.p_ai_attack, .names = &.{"aicAttack"} },
    .{ .label = tx.p_ai_defense, .names = &.{"aicDefense"} },
    .{ .label = tx.p_ai_player, .names = &.{"aicPlayerDist"} },
    .{ .label = tx.p_ai_guard, .names = &.{"aicGuardDist"} },
};
// Resistances are not here: `pr*` fields are the heroes' armour; monsters resist by
// the exe table for their nameID (pages.resistBlock, read-only).
pub const damage_stat: Stat = .{ .label = tx.damage_of, .names = &.{"max_damage"} };

/// A number being typed into a parameter.
/// A file asked for in a dialog and what to do with it (App.fileChosen).
/// `slot`: which of a model's textures (`mesh.textureNames` order).
/// What a file dialog offers (its filter), and whether it saves (`_out`).
pub const FileKind = enum { png, png_out, sound, wav_out, audio, video, ttf, glb, glb_out, folder, program };

/// A file asked for: the dialog's kind, what the chosen path does (it sets the status;
/// an error it returns is shown as a failed import), the thing it is for (`entry`, `slot`).
pub const FileAsk = struct { kind: FileKind, run: *const fn (*App, FileAsk, []const u8) anyerror!void, entry: usize = 0, slot: u8 = 0 };

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

pub const Menu = struct {
    at: [2]f32,
    grid: ?[2]f32,
    /// The object clicked on (it can be removed).
    obj: ?usize = null,
    /// Background point clicked (a new box goes there).
    bg: [2]f32 = .{ 0, 0 },
    /// The submenu shown beside it (hovered last).
    open: Sub = .none,
    /// The submenu row under the pointer and since when (ms): it opens after a rest.
    hover: Sub = .none,
    hover_since: u64 = 0,

    const Sub = enum { none, add, enemy, own, hero, refs, model };
};

/// An object copied (Copy, Duplicate) to paste in this or another level of its kind.
const Clip = struct {
    what: enum { enemy, obstacle, prop, box },
    class_buf: [48]u8 = undefined,
    class_len: usize = 0,
    obstacle: level.Obstacle = .box,
    prop: level.Prop = .barrier,
    /// A box's script (its contents; owned) and its kind (`.itm` locations, `.obs_i` battles).
    box_text: ?[]u8 = null,
    box_battle: bool = false,

    pub fn class(self: *const Clip) []const u8 {
        return self.class_buf[0..self.class_len];
    }
};

/// A number typed into a level panel's stepper (its label clicked): Enter or a click
/// elsewhere sets it, Escape drops it.
pub const NumEdit = struct {
    /// Hash of the stepper's id.
    id: u64,
    buf: [24]u8 = undefined,
    len: usize = 0,
    done: bool = false,

    pub fn text(self: *const NumEdit) []const u8 {
        return self.buf[0..self.len];
    }
};

const Editing = struct {
    row: u32,
    file: usize,
    names: []const []const u8,
    after: ?[]const u8,
    buf: [16]u8 = undefined,
    len: usize = 0,
};

pub const App = struct {
    gpa: Allocator,
    window: *c.SDL_Window,
    io: Io,
    r: *c.SDL_Renderer,
    font: *Font,
    dat: Io.Dir,
    game_dir: []const u8,
    levels: []level.LevelEntry,
    templates: []level.Template,
    /// Every edited file (levels, fighters, classes, heroes): one undo, one save.
    store: Store,
    catalog: catalog.Catalog,
    /// common/sprite.dat for item icons, and icons decoded so far (name → texture).
    sprites: ?og.formats.archive.Archive = null,
    icons: std.StringHashMapUnmanaged(?*c.SDL_Texture) = .empty,
    /// Enemies/items/heroes tabs: the selected catalog entry and the open value picker.
    entry: ?usize = null,
    picker: ?Picker = null,
    /// Scenes tab: the selected scene (index into catalog.scenes).
    scene: ?usize = null,
    scenes: @import("scenepage.zig").State = .{},
    logic: @import("logicview.zig").State = .{},
    /// Code open in other tabs than the shown one (`code`), and the code page's lower panel.
    code_parked: std.ArrayList(*code.View) = .empty,
    code_bottom: enum { problems, refs } = .problems,
    /// The name of a new location being typed (from the open one).
    level_name: [24]u8 = undefined,
    level_name_len: usize = 0,
    level_naming: bool = false,
    /// Its "Make" clicked: made at the next frame's start (it opens the new level).
    level_make: bool = false,
    /// A hero to delete from the menu, at the next frame's start (the level reloads).
    hero_drop: Name(48) = .{},
    /// A link clicked (scene, level and object), followed at the next frame's start.
    nav: ?struct { scene: bool, name: [64]u8, name_len: usize, obj: [64]u8, obj_len: usize } = null,
    /// Enemy model preview and its animation (logical name, `long_attack`).
    preview: preview.Preview = .{},
    /// The open sprite (the Sprites page, sprview.zig).
    spr: ?*sprview.Edit = null,
    /// Where "Import PNG…" puts a new sprite: its archive and folder (`icons` or none).
    spr_new: Name(64) = .{},
    spr_new_icons: bool = false,
    /// The dialogue line's voice file a chooser or file dialog is for (scenepage.zig).
    voice_for: Name(64) = .{},
    voice_choosing: bool = false,
    /// The level edit mode (paint.zig) over the open location.
    paint: ?*paint.Paint = null,
    /// Frame sounds of the preview.
    player: sounds.Player = .{},
    /// A file dialog is open for this.
    asking: ?FileAsk = null,
    /// The game folder dialog is open.
    asking_game: bool = false,
    /// Dragging the preview: last pointer x.
    turning: ?f32 = null,
    anim_name: Name(48) = .{},
    sound_sel: Name(64) = .{},
    effect: @import("effectpage.zig").State = .{},
    fonts: @import("fontpage.zig").State = .{},
    texts: @import("textpage.zig").State = .{},
    adjust: @import("adjustpage.zig").State = .{},
    music: @import("musicpage.zig").State = .{},
    video: @import("videopage.zig").State = .{},
    /// The ffmpeg run going on (videos, music).
    convert: ?*@import("convert.zig").Job = null,
    /// Weapon page: which hero strikes in the preview (index among the heroes).
    attack_hero: usize = 0,
    /// Enemy class page: the weapon whose reach map is shown.
    reach_open: ?u32 = null,
    /// Weapon page: the damage zone shown in place of the model.
    zone_view: bool = false,
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
    editing: ?Editing = null,
    num_edit: ?NumEdit = null,
    /// The free-text field typed into, and a typed text waiting for its field (textedit.zig).
    text_edit: ?@import("textedit.zig").Edit = null,
    text_given: ?@import("textedit.zig").Edit = null,
    /// The asset tree: its open folders (keys owned), its search and whether typing goes there.
    tree_open: std.StringHashMapUnmanaged(void) = .empty,
    tree_query: Name(64) = .{},
    tree_focus: bool = false,
    /// The animation list's search (enemy and hero pages).
    anim_query: Name(32) = .{},
    anim_focus: bool = false,
    /// The selection the tree last opened its folders for.
    tree_seen: u64 = 0,
    /// Open documents (the tab strip over the centre).
    doc_tabs: [doctabs.max]doctabs.DocTab = undefined,
    doc_tabs_n: usize = 0,
    /// The tab last scrolled into the strip (hash).
    tab_seen: u64 = 0,
    /// Undo steps when the tabs were last synced (a new step keeps the shown tab).
    tab_steps: usize = 0,
    /// Its stepper was laid out this frame (else the edit is dropped: no field takes the typing).
    num_seen: bool = false,
    inspector: Inspector = .inspector,
    /// Objects hidden in the view (names, `kind:<kind>`; keys owned).
    view_hidden: std.StringHashMapUnmanaged(void) = .empty,
    /// The slider being dragged (its id's hash).
    slider_drag: ?u32 = null,
    /// A sound marker dragged on the timeline: its .ani file, animation, cue, frame now.
    cue_drag: ?struct { file: usize, anim: usize, cue: usize, frame: u32 } = null,
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
    /// Per tab: the id of the entry shown last (enemies, items, heroes).
    tab_entry: std.EnumArray(Tab, [64]u8) = .initUndefined(),
    tab_entry_len: std.EnumArray(Tab, usize) = .initFill(0),
    doc: ?*Doc = null,
    selected: ?usize = null,
    /// Level clicked while the open one has unsaved edits (a second click discards them).
    pending_switch: ?usize = null,
    status_buf: [512]u8 = undefined,
    status: []const u8 = "",
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
    /// Box contents window (right click on a box).
    box: ?BoxOpen = null,
    /// Trigger window: the area's name (right click on an area).
    trigger: ?[]const u8 = null,
    /// The mod check's window (top bar button).
    check: ?*@import("checkpanel.zig").Result = null,
    /// Play asked for while the port wasn't found: run once it's chosen (level, scene).
    play_pending: ?struct { buf: [128]u8 = undefined, level: usize = 0, scene: ?usize = null } = null,
    /// History window open (every edit, any of them to go back to).
    /// History: the step whose changed lines are shown (1-based; 0: as the editor opened it).
    history_open: ?usize = null,
    /// History: a save of an earlier session picked instead (1-based; 0: the original).
    history_old: ?usize = null,
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
    query_buf: [64]u8 = undefined,
    query_len: usize = 0,
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

    pub fn setStatus(self: *App, comptime m: tx.Msg, args: anytype) void {
        self.status = tx.print(&self.status_buf, m, args);
    }

    pub fn setLang(self: *App, l: tx.Lang) void {
        if (tx.lang == l) return;
        tx.lang = l;
        self.settings.lang = l;
        self.saveSettings();
        _ = c.SDL_SetWindowTitle(self.window, tx.get(tx.title).ptr);
        self.status = "";
    }

    pub fn split(self: *const App, k: Split) f32 {
        // At most 40% of the window (a pane dragged wide in a small window leaves room).
        const room = if (k == .entry_y) self.size[1] else self.size[0];
        const v = self.settings.split(k);
        return if (room > 0) @min(v, room * 0.4) else v;
    }

    /// A draggable edge between panes for size `key`: a bar `across` (between rows) or
    /// down (between columns); `n` tells apart two bars of one size.
    pub fn splitter(self: *App, key: Split, across: bool, sign: f32, n: u32) void {
        const id = clay.idi("split", @as(u32, @backingInt(key)) * 4 + n);
        const active = if (self.split_drag) |d| d.key == key else false;
        clay.leaf(.{
            .id = id,
            .layout = .{ .sizing = if (across) .{ .width = clay.grow(), .height = clay.fixed(4) } else .{ .width = clay.fixed(4), .height = clay.grow() } },
            .backgroundColor = if (active or clay.pointerOver(id)) theme.accent else theme.bg,
        });
        if (!clay.pointerOver(id) and !active) return;
        self.cursor_want = @intFromBool(across);
        if (self.clicked and self.split_drag == null) {
            self.split_drag = .{ .key = key, .across = across, .from = self.mouse[@intFromBool(across)], .start = self.split(key), .sign = sign };
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
        const limit = self.size[@intFromBool(d.across)] - 200;
        self.settings.splits[@backingInt(d.key)] = std.math.clamp(d.start + (self.mouse[@intFromBool(d.across)] - d.from) * d.sign, 140, @max(140, limit));
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

    /// Level clicked: with unsaved edits the first click warns, the second discards them
    /// (the level is loaded from the archives, so they must agree).
    pub fn requestOpen(self: *App, i: usize) void {
        // A level kept in its tab needs no reading (its edits are in it).
        const kept = for (self.parked.items) |pk| {
            if (pk.current == i and pk.doc != null) break true;
        } else false;
        if (!kept and self.store.dirty()) {
            if (self.pending_switch != i) {
                self.pending_switch = i;
                self.setStatus(tx.st_unsaved, .{});
                return;
            }
            self.discard();
        }
        self.open(i, false);
    }

    /// Forgets every unsaved edit.
    fn discard(self: *App) void {
        if (self.paint) |p| p.destroy(self.gpa);
        self.paint = null;
        if (self.doc) |d| d.deinit();
        self.doc = null;
        self.dropParked();
        self.store.revert();
        self.dropMissingLevels();
        self.player.reload();
        self.rebuildCatalog();
    }

    /// Object (or `kind:<kind>`) `key` shown or hidden in the view.
    pub fn toggleHidden(self: *App, key: []const u8) void {
        if (self.view_hidden.fetchRemove(key)) |kv| return self.gpa.free(kv.key);
        const k = self.gpa.dupe(u8, key) catch return;
        self.view_hidden.put(self.gpa, k, {}) catch self.gpa.free(k);
    }

    /// The open level closed (its tab closed): nothing shown in the centre.
    pub fn closeLevel(self: *App) void {
        _ = self.endPaint();
        if (self.doc) |d| d.deinit();
        self.doc = null;
        self.current = null;
        self.selected = null;
        self.moving = null;
    }

    /// Levels whose folder is gone (a made level undone) out of the list; the open one
    /// among them closed.
    fn dropMissingLevels(self: *App) void {
        var kept: usize = 0;
        var buf: [160]u8 = undefined;
        const cur = if (self.current) |i| self.levels[i].name else null;
        var reopen: ?usize = null;
        for (self.levels) |lv| {
            const p = std.fmt.bufPrint(&buf, "{s}/other.dat", .{lv.name}) catch continue;
            if (self.dat.access(self.io, p, .{})) {
                if (cur != null and std.mem.eql(u8, cur.?, lv.name)) reopen = kept;
                self.levels[kept] = lv;
                kept += 1;
            } else |_| {
                self.setStatus(tx.st_level_unmade, .{lv.name});
                if (cur != null and std.mem.eql(u8, cur.?, lv.name)) {
                    _ = self.endPaint();
                    if (self.doc) |d| d.deinit();
                    self.doc = null;
                    self.selected = null;
                }
                self.clearParked();
                // shortcut: the entry's name string is left (templates may still point into it).
            }
        }
        if (kept == self.levels.len) return;
        self.levels = self.levels[0..kept];
        self.current = reopen;
    }

    /// The levels kept in tabs: their docs closed (the archives changed), each read
    /// again when its tab is shown.
    fn dropParked(self: *App) void {
        for (self.parked.items) |*pk| if (pk.doc) |d| {
            d.deinit();
            pk.doc = null;
        };
    }

    /// Every kept level forgotten (level indices changed).
    fn clearParked(self: *App) void {
        self.dropParked();
        self.paint_left.clearRetainingCapacity();
        self.parked.clearRetainingCapacity();
    }

    /// The open level kept in its tab; nothing open after.
    fn park(self: *App) void {
        const i = self.current orelse return;
        // An older copy of it in the tabs goes (its left edit mode stays).
        if (self.unpark(i)) |pk| if (pk.doc) |d| d.deinit();
        self.parked.append(self.gpa, .{ .doc = self.doc, .current = i }) catch {
            if (self.doc) |d| d.deinit();
        };
        self.doc = null;
        self.current = null;
    }

    /// Level `i` kept in a tab: taken out (its doc, null if not kept or dropped).
    fn unpark(self: *App, i: usize) ?Parked {
        for (self.parked.items, 0..) |pk, k| if (pk.current == i) return self.parked.orderedRemove(k);
        return null;
    }

    /// Level `name` loaded for a look (the scene page's map): the open one, a kept one,
    /// or read now and kept (as a tab's).
    pub fn levelDoc(self: *App, name: []const u8) ?*Doc {
        const i = for (self.levels, 0..) |lv, k| {
            if (std.ascii.eqlIgnoreCase(lv.name, name)) break k;
        } else return null;
        if (self.current == i) return self.doc;
        for (self.parked.items) |*pk| if (pk.current == i) {
            if (pk.doc == null) pk.doc = Doc.load(&self.store, self.r, self.levels[i].name) catch return null;
            return pk.doc;
        };
        const d = Doc.load(&self.store, self.r, self.levels[i].name) catch return null;
        self.parked.append(self.gpa, .{ .doc = d, .current = i }) catch {
            d.deinit();
            return null;
        };
        return d;
    }

    /// Level `i` no longer kept (its tab closed).
    pub fn forgetLevel(self: *App, i: usize) void {
        if (self.unpark(i)) |pk| if (pk.doc) |d| d.deinit();
        _ = self.paint_left.remove(i);
    }

    /// Every loaded level: the open one and those kept in tabs.
    fn eachDoc(self: *App, buf: []*Doc) []*Doc {
        var n: usize = 0;
        if (self.doc) |d| {
            buf[n] = d;
            n += 1;
        }
        for (self.parked.items) |pk| if (pk.doc) |d| if (n < buf.len) {
            buf[n] = d;
            n += 1;
        };
        return buf[0..n];
    }

    /// Shows tab `t` as it was left: the level of battles and of locations each, the
    /// entry of enemies, items and heroes each.
    pub fn setTab(self: *App, t: Tab) void {
        if (t == self.tab) return;
        self.leavePaint();
        self.closePaint();
        const n = if (self.entry) |e| self.catalog.entries.items[e].id else "";
        @memcpy(self.tab_entry.getPtr(self.tab)[0..@min(n.len, 64)], n[0..@min(n.len, 64)]);
        self.tab_entry_len.set(self.tab, @min(n.len, 64));
        self.tab = t;
        self.entry = null;
        self.picker = null;
        const id = self.tab_entry.getPtrConst(t)[0..self.tab_entry_len.get(t)];
        if (id.len > 0) for (self.catalog.entries.items, 0..) |e, i| if (std.ascii.eqlIgnoreCase(e.id, id)) {
            self.entry = i;
        };
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
        self.selected = null;
        self.enemy_of = null;
        self.menu = null;
        self.box = null;
        self.trigger = null;
        self.moving = null;
        if (self.doc == null) if (self.current) |i| self.open(i, false);
    }

    /// Kept level `k` open again as it was (read again if its doc was dropped: open()).
    fn unparkInto(self: *App, k: usize) void {
        const pk = self.parked.orderedRemove(k);
        self.doc = pk.doc;
        self.current = pk.current;
    }

    /// Reads the catalog again (after save or discard: new classes are on disk or gone).
    fn rebuildCatalog(self: *App) void {
        self.entry = null;
        self.picker = null;
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.gpa);
        for (self.levels) |e| names.append(self.gpa, e.name) catch return;
        const fresh = catalog.Catalog.build(self.io, self.gpa, self.dat, names.items) catch |err| return std.log.warn("catalog: {t}", .{err});
        self.catalog.deinit();
        self.catalog = fresh;
    }

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
        const entry = try std.fmt.bufPrint(&buf, "icons\\{s}.spr", .{name});
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

    pub fn open(self: *App, i: usize, keep_view: bool) void {
        // A level opened (not read again after an edit): the one left keeps its edit mode.
        if (!keep_view) self.leavePaint();
        const painted = self.endPaint();
        var view: ?struct { origin: [2]f32, zoom: f32 } = null;
        // Another level: the open one stays in its tab (read again with what the mode changed).
        if (self.current != null and self.current.? != i) {
            if (painted) if (self.doc) |d| {
                d.deinit();
                self.doc = Doc.load(&self.store, self.r, self.levels[self.current.?].name) catch null;
            };
            self.park();
        }
        if (self.doc) |d| {
            if (keep_view) view = .{ .origin = d.origin, .zoom = d.zoom };
            d.deinit();
        }
        self.doc = null;
        const kept = self.unpark(i);
        self.selected = null;
        self.enemy_of = null;
        self.menu = null;
        self.box = null;
        self.trigger = null;
        self.stopEditing();
        self.moving = null;
        self.pending_switch = null;
        self.current = i;
        const name = self.levels[i].name;
        if (kept) |pk| if (pk.doc) |d| if (keep_view) d.deinit() else {
            self.doc = d;
        };
        if (self.doc == null) self.doc = Doc.load(&self.store, self.r, name) catch |err| {
            self.setStatus(tx.st_open_failed, .{ name, err });
            return;
        };
        const d = self.doc.?;
        if (view) |v| {
            d.origin = v.origin;
            d.zoom = v.zoom;
            d.fitted = true;
        }
        if (!keep_view) self.backToPaint();
        var editable: usize = 0;
        for (d.objects.items) |o| editable += @intFromBool(o.call != null);
        if (d.isBattle()) {
            self.setStatus(tx.st_battle, .{ name, d.objects.items.len, editable });
        } else self.setStatus(tx.st_location, .{ name, @as(u32, @intFromFloat(d.bg_size[0])), @as(u32, @intFromFloat(d.bg_size[1])), d.objects.items.len });
    }

    /// The one Save: the open code editor's text and the value being typed go in first.
    /// The open level in the port (the viewer beside the editor, or the game's app on
    /// macOS), straight in with the starting party; the edits saved first (it reads
    /// the folder).
    pub fn playLevel(self: *App) void {
        const d = self.doc orelse return;
        self.playIn(d.name, null);
    }

    /// Scene `name` run on level `level` to its end without a window (saved first: the
    /// run reads the game's files), its report kept for the Debug view.
    pub fn testScene(self: *App, level_name: []const u8, name: []const u8) void {
        if (self.store.dirty()) {
            self.save();
            if (self.store.dirty()) return;
        }
        var models = og.actor.model_cache.Cache.open(self.io, self.gpa, self.dat) catch |err| return self.setStatus(tx.st_set_failed, .{err});
        defer models.deinit();
        const rep = og.scene_check.run(self.io, self.gpa, self.dat, &models, level_name, name) catch |err| return self.setStatus(tx.st_set_failed, .{err});
        self.dropReport();
        self.scenes.report = .{ .name = self.gpa.dupe(u8, name) catch return, .level = self.gpa.dupe(u8, level_name) catch return, .report = rep };
        self.setStatus(tx.st_scene_run, .{ name, rep.result, rep.ticks });
    }

    pub fn dropReport(self: *App) void {
        const r = &(self.scenes.report orelse return);
        self.gpa.free(r.name);
        self.gpa.free(r.level);
        r.report.deinit(self.gpa);
        self.scenes.report = null;
    }

    /// Level `level` in the port (saved first), scene `scene` started as it loads
    /// (the console's `scene`, Space skips a line there).
    pub fn playIn(self: *App, level_name: []const u8, scene: ?[]const u8) void {
        if (self.store.dirty()) {
            self.save();
            if (self.store.dirty()) return; // the save failed or waits (a script error)
        }
        var db: [1024]u8 = undefined;
        const dir = db[0 .. std.process.executableDirPath(self.io, &db) catch return self.setStatus(tx.st_play_failed, .{error.NoExePath})];
        const exe = if (@import("builtin").os.tag == .windows) "opengorky-viewer.exe" else "opengorky-viewer";
        var pb: [1200]u8 = undefined;
        // The one chosen in the settings, else beside the editor (zig-out/bin, the Windows/Linux packages), else the macOS game app next to the editor's.
        const viewer = blk: {
            if (self.settings.viewerPath()) |vp| {
                const p = @import("settings.zig").viewerProgram(&pb, vp, exe);
                Io.Dir.cwd().access(self.io, p, .{}) catch {
                    self.setStatus(tx.st_viewer_missing, .{p});
                    return self.askViewer(level_name, scene);
                };
                break :blk p;
            }
            // The Windows package names it OpenGorky.exe, in the folder `opengorky` beside the editor's.
            const near = if (@import("builtin").os.tag == .windows)
                .{ "{s}/opengorky-viewer.exe", "{s}/OpenGorky.exe", "{s}/../opengorky/OpenGorky.exe" }
            else
                .{ "{s}/opengorky-viewer", "{s}/../../../OpenGorky.app/Contents/MacOS/opengorky-viewer" };
            inline for (near) |fmt| {
                if (std.fmt.bufPrint(&pb, fmt, .{dir})) |p| {
                    if (Io.Dir.cwd().access(self.io, p, .{})) break :blk p else |_| {}
                } else |_| {}
            }
            self.setStatus(tx.st_no_viewer, .{});
            return self.askViewer(level_name, scene);
        };
        var ab: [160]u8 = undefined;
        const archive = std.fmt.bufPrint(&ab, "{s}/sprite.dat", .{level_name}) catch return;
        var sb: [96]u8 = undefined;
        const scene_cmd = if (scene) |n| std.fmt.bufPrint(&sb, "playscene {s}", .{n}) catch return else "";
        const base = [_][]const u8{ viewer, self.game_dir, archive, "--level", "--heroes", "--play" };
        const with_scene = base ++ [_][]const u8{ "--dev", "--console", scene_cmd, "--console", "close" };
        // shortcut: the child is never waited for (it outlives the editor or ends on its own); keep its handle if the editor ever needs to stop it.
        _ = std.process.spawn(self.io, .{
            .argv = if (scene != null) &with_scene else &base,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| return self.setStatus(tx.st_play_failed, .{err});
        self.setStatus(tx.st_playing, .{level_name});
    }

    pub fn save(self: *App) void {
        self.commitEditing();
        // Every open code tab's edits; a syntax error: the first press only warns.
        if (!codeview.applyAll(self)) return;
        _ = self.endPaint();
        if (!self.store.dirty()) return;
        const n = self.store.pending();
        self.store.save() catch |err| return self.setStatus(tx.st_save_failed, .{err});
        // The archives now hold the edits: start from them again (the level's scripts
        // run on the saved files, new classes come into the catalog).
        if (self.doc) |d| d.deinit();
        self.doc = null;
        self.dropParked();
        self.player.reload();
        self.preview.reload();
        const entry_id = if (self.entry) |e| self.gpa.dupe(u8, self.catalog.entries.items[e].id) catch null else null;
        defer if (entry_id) |s| self.gpa.free(s);
        self.rebuildCatalog();
        // The entry shown again (a new class sorts in, so by id).
        if (entry_id) |id| for (self.catalog.entries.items, 0..) |e, i| if (std.ascii.eqlIgnoreCase(e.id, id)) {
            self.entry = i;
        };
        if (self.current) |i| self.open(i, true);
        self.setStatus(tx.st_saved, .{n});
        // What the original exe would stumble on: the window opens only on problems.
        @import("checkpanel.zig").run(self);
    }

    /// A trigger on the open location: polygon `pts` into its `.ar`, a once-only
    /// `HeroInArea` block into its `.lev`; the level read again (the edit mode
    /// stays on), the code editor at the block for what happens.
    pub fn addTriggerArea(self: *App, pts: []const [2]i32) void {
        const d = self.doc orelse return;
        var eb: [160]u8 = undefined;
        const ar_entry = std.fmt.bufPrint(&eb, "{s}.ar", .{d.name}) catch return;
        const arf = self.store.file(d.level_archive, ar_entry) catch |err| return self.setStatus(tx.st_paint_failed, .{err});
        const lev_file = d.lev;
        var nb: [32]u8 = undefined;
        const name = trigger.freeName(&nb, self.store.text(arf), "trigger");
        const ar = trigger.addArea(self.gpa, self.store.text(arf), name, pts, null) catch |err| return self.setStatus(tx.st_paint_failed, .{err});
        const lev = trigger.addTrigger(self.gpa, self.store.text(lev_file), name) catch |err| {
            self.gpa.free(ar);
            return self.setStatus(tx.st_paint_failed, .{err});
        };
        self.store.replace(arf, ar) catch |err| {
            self.gpa.free(ar);
            self.gpa.free(lev.text);
            return self.setStatus(tx.st_paint_failed, .{err});
        };
        self.store.replace(lev_file, lev.text) catch |err| {
            self.gpa.free(lev.text);
            return self.setStatus(tx.st_paint_failed, .{err});
        };
        self.reloadLevel();
        codeview.open(self, lev_file, lev.at);
        self.setStatus(tx.st_trigger_added, .{name});
    }

    /// A clickable exit on polygon `pts` of the open location to level `target`, hint
    /// `label` (string.tab): the area, its control point on the walkable cell nearest
    /// its middle (the hero walks there), and its `<area>_are.are`. Two undo steps.
    pub fn addExitArea(self: *App, pts: []const [2]i32, target: []const u8, label: u16) void {
        const d = self.doc orelse return;
        const a = self.frame.allocator();
        const arf = self.arFile(d) orelse return;
        var nb: [32]u8 = undefined;
        const name = trigger.freeName(&nb, self.store.text(arf), "exit");
        var mid: [2]f32 = .{ 0, 0 };
        for (pts) |p| mid = .{ mid[0] + @as(f32, @floatFromInt(p[0])), mid[1] + @as(f32, @floatFromInt(p[1])) };
        const n: f32 = @floatFromInt(@max(1, pts.len));
        const to = d.nearestWalkable(.{ mid[0] / n, mid[1] / n }) orelse return self.setStatus(tx.st_paint_failed, .{error.NoWalkableNear});
        const ar = trigger.addArea(self.gpa, self.store.text(arf), name, pts, .{ @intFromFloat(@round(to[0])), @intFromFloat(@round(to[1])) }) catch |err| return self.setStatus(tx.st_paint_failed, .{err});
        const enable = std.mem.indexOf(u8, self.store.text(d.lev), "DisableHeroes(") != null;
        const script = trigger.exitScript(self.gpa, name, label, target, enable) catch |err| {
            self.gpa.free(ar);
            return self.setStatus(tx.st_paint_failed, .{err});
        };
        _ = self.store.addNew(&.{.{ .archive = d.level_archive, .entry = std.fmt.allocPrint(a, "{s}_are.are", .{name}) catch return, .text = script }}) catch |err| {
            self.gpa.free(ar);
            self.gpa.free(script);
            return self.setStatus(tx.st_paint_failed, .{err});
        };
        self.store.replaceLabeled(arf, ar, std.fmt.allocPrint(a, "+ {s} → {s}", .{ name, target }) catch null) catch |err| {
            self.gpa.free(ar);
            return self.setStatus(tx.st_paint_failed, .{err});
        };
        self.setStatus(tx.st_exit_added, .{ name, target });
        self.reloadLevel();
    }

    /// Area `name` of the open location moved by `off` (background pixels): its points,
    /// its control point too, kept on the walkable cell nearest (a hero walks there).
    pub fn moveArea(self: *App, name: []const u8, off: [2]i32) void {
        const d = self.doc orelse return;
        const a = self.frame.allocator();
        const arf = self.arFile(d) orelse return;
        const areas = og.formats.level_files.parseAreas(a, self.store.text(arf)) catch |err| return self.setStatus(tx.st_paint_failed, .{err});
        const area = for (areas) |ar| {
            if (std.ascii.eqlIgnoreCase(ar.name, name)) break ar;
        } else return self.setStatus(tx.st_paint_failed, .{error.NoArea});
        const moved: [2]f32 = .{ area.control[0] + @as(f32, @floatFromInt(off[0])), area.control[1] + @as(f32, @floatFromInt(off[1])) };
        const cp = d.nearestWalkable(moved) orelse moved;
        const ar = trigger.moveArea(self.gpa, self.store.text(arf), name, off, .{ @intFromFloat(@round(cp[0])), @intFromFloat(@round(cp[1])) }) catch |err| return self.setStatus(tx.st_paint_failed, .{err});
        self.store.replaceLabeled(arf, ar, std.fmt.allocPrint(a, "{s} ↔ {d},{d}", .{ name, off[0], off[1] }) catch null) catch |err| {
            self.gpa.free(ar);
            return self.setStatus(tx.st_paint_failed, .{err});
        };
        self.reloadLevel();
        // The mode opened anew: the area picked again.
        if (self.paint) |p| if (self.doc) |nd| {
            for (nd.objects.items) |o| if (o.kind == .area and std.ascii.eqlIgnoreCase(o.name, name)) {
                paint.pickName(p, o.name);
            };
        };
    }

    /// The exit script (`.are` with LevelSwitch) of area `name` of location `d`, if any.
    pub fn exitOf(self: *App, d: *Doc, name: []const u8) ?usize {
        for (d.levelFiles(self.frame.allocator()) catch &.{}) |f| {
            if (std.ascii.endsWithIgnoreCase(self.store.files.items[f].entry, ".are") and trigger.isExitOf(self.store.text(f), name)) return f;
        }
        return null;
    }

    /// Exit `f` leading to level `target` instead (one undo step).
    pub fn setExitTarget(self: *App, f: usize, target: []const u8) void {
        const t = trigger.setExitTarget(self.gpa, self.store.text(f), target) catch |err| return self.setStatus(tx.st_paint_failed, .{err});
        self.store.replaceLabeled(f, t, std.fmt.allocPrint(self.frame.allocator(), "→ {s}", .{target}) catch null) catch |err| {
            self.gpa.free(t);
            self.setStatus(tx.st_paint_failed, .{err});
        };
    }

    /// Area `name` of the open location taken out: its polygon from `.ar`, the trigger
    /// the editor made for it from `.lev`, its exit script. Refused while another script
    /// still names it (the level's or a scene's): the status says which.
    pub fn deleteArea(self: *App, name: []const u8) void {
        const d = self.doc orelse return;
        const a = self.frame.allocator();
        const arf = self.arFile(d) orelse return;
        const exit = self.exitOf(d, name);
        const lev = trigger.removeTrigger(self.gpa, self.store.text(d.lev), name) catch |err| return self.setStatus(tx.st_paint_failed, .{err});
        if (self.areaUser(d, name, lev, exit)) |where| {
            self.gpa.free(lev);
            return self.setStatus(tx.st_area_used, .{ name, where });
        }
        const ar = trigger.removeArea(self.gpa, self.store.text(arf), name) catch |err| {
            self.gpa.free(lev);
            return self.setStatus(tx.st_paint_failed, .{err});
        };
        self.store.replaceLabeled(arf, ar, std.fmt.allocPrint(a, "− {s}", .{name}) catch null) catch |err| {
            self.gpa.free(ar);
            self.gpa.free(lev);
            return self.setStatus(tx.st_paint_failed, .{err});
        };
        if (std.mem.eql(u8, lev, self.store.text(d.lev))) self.gpa.free(lev) else self.store.replace(d.lev, lev) catch |err| {
            self.gpa.free(lev);
            return self.setStatus(tx.st_paint_failed, .{err});
        };
        if (exit) |f| self.store.delete(&.{f}) catch |err| return self.setStatus(tx.st_paint_failed, .{err});
        self.setStatus(tx.st_area_deleted, .{name});
        self.reloadLevel();
    }

    /// Area `old` named `new`: in `.ar` and in every script of the level (`"old"`, the
    /// editor's `ready_old`). Refused if a scene names it (they are shared by levels).
    pub fn renameArea(self: *App, old: []const u8, new: []const u8) void {
        const d = self.doc orelse return;
        const a = self.frame.allocator();
        if (!trigger.validName(new)) return self.setStatus(tx.st_area_bad_name, .{new});
        const arf = self.arFile(d) orelse return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        if (trigger.hasArea(self.store.text(arf), new)) return self.setStatus(tx.st_area_taken, .{new});
        if (self.sceneUser(old)) |where| return self.setStatus(tx.st_area_in_scene, .{ old, where });
        const ar = trigger.renameArea(self.gpa, self.store.text(arf), old, new) catch |err| return self.setStatus(tx.st_paint_failed, .{err});
        self.store.replaceLabeled(arf, ar, std.fmt.allocPrint(a, "{s} → {s}", .{ old, new }) catch null) catch |err| {
            self.gpa.free(ar);
            return self.setStatus(tx.st_paint_failed, .{err});
        };
        for (d.levelFiles(arena.allocator()) catch &.{}) |f| {
            const t = trigger.renameRefs(self.gpa, self.store.text(f), old, new) catch continue;
            if (std.mem.eql(u8, t, self.store.text(f))) self.gpa.free(t) else self.store.replace(f, t) catch self.gpa.free(t);
        }
        self.setStatus(tx.st_area_renamed, .{ old, new });
        self.reloadLevel();
    }

    fn arFile(self: *App, d: *Doc) ?usize {
        var eb: [160]u8 = undefined;
        return self.store.file(d.level_archive, std.fmt.bufPrint(&eb, "{s}.ar", .{d.name}) catch return null) catch |err| {
            self.setStatus(tx.st_paint_failed, .{err});
            return null;
        };
    }

    /// The script still naming area `name` (`"name"` outside comments): one of the
    /// level's (its `.lev` as `lev`) or a scene; null if none.
    fn areaUser(self: *App, d: *Doc, name: []const u8, lev: []const u8, skip: ?usize) ?[]const u8 {
        const a = self.frame.allocator();
        const q = std.fmt.allocPrint(a, "\"{s}\"", .{name}) catch return null;
        for (d.levelFiles(a) catch &.{}) |f| {
            if (skip != null and skip.? == f) continue;
            const t = if (f == d.lev) lev else self.store.text(f);
            if (std.ascii.findIgnoreCase(placement.uncommented(a, t) catch t, q) != null) return self.store.files.items[f].entry;
        }
        return self.sceneUser(name);
    }

    fn sceneUser(self: *App, name: []const u8) ?[]const u8 {
        const a = self.frame.allocator();
        const q = std.fmt.allocPrint(a, "\"{s}\"", .{name}) catch return null;
        for (self.catalog.scenes.items) |sc| {
            const e = std.fmt.allocPrint(a, "scriptlets\\{s}.scr", .{sc.name}) catch continue;
            const f = self.store.file(common_archive, e) catch continue;
            if (std.ascii.findIgnoreCase(self.store.text(f), q) != null) return self.store.files.items[f].entry;
        }
        return null;
    }

    /// The open level read again from the Store, the edit mode open again over it.
    pub fn reloadLevel(self: *App) void {
        // The mode opens again with its tool, layer and shown layers.
        const keep = self.paintKeep();
        _ = self.endPaint();
        if (self.current) |i| self.open(i, true);
        if (keep) |k| self.paintAgain(k);
    }

    fn paintKeep(self: *const App) ?PaintKeep {
        const p = self.paint orelse return null;
        return .{ .tool = p.tool, .layer = p.layer, .show = p.show, .locked = p.locked, .show_objects = p.show_objects };
    }

    fn paintAgain(self: *App, k: PaintKeep) void {
        self.openPaint();
        const p = self.paint orelse return;
        p.tool = k.tool;
        if (paint.hasLayer(p, k.layer)) p.layer = k.layer;
        p.show = k.show;
        p.locked = k.locked;
        p.show_objects = k.show_objects;
    }

    /// The open level left in the edit mode: remembered to come back in it.
    fn leavePaint(self: *App) void {
        const i = self.current orelse return;
        const k = self.paintKeep() orelse return;
        self.paint_left.put(self.gpa, i, k) catch {};
    }

    /// The open level shown again: its edit mode back if it was left in it.
    fn backToPaint(self: *App) void {
        const i = self.current orelse return;
        if (self.paint != null or self.doc == null) return;
        if (self.paint_left.fetchRemove(i)) |kv| self.paintAgain(kv.value);
    }

    /// The level edit mode over the open location.
    pub fn openPaint(self: *App) void {
        const d = self.doc orelse return;
        self.paint = paint.open(self, d) catch |err| return self.setStatus(tx.st_paint_failed, .{err});
        self.selected = null;
        self.moving = null;
    }

    /// Leaves the edit mode; the map is drawn again from the changed files.
    pub fn closePaint(self: *App) void {
        if (self.endPaint()) if (self.current) |i| self.open(i, true);
    }

    /// The mode's changed layers into the Store (Save writes them); true if any.
    fn endPaint(self: *App) bool {
        const p = self.paint orelse return false;
        self.paint = null;
        defer p.destroy(self.gpa);
        const changed = p.undo.items.len > 0;
        paint.commit(self, p) catch |err| self.setStatus(tx.st_paint_failed, .{err});
        return changed;
    }

    pub fn removeSelected(self: *App) void {
        const d = self.doc orelse return;
        const i = self.selected orelse return;
        if (d.objects.items[i].call == null or d.objects.items[i].later != null) return;
        const name = d.objects.items[i].name;
        d.remove(i) catch |err| return if (err == error.Referenced) self.setStatus(tx.st_referenced, .{ name, d.refFile() }) else self.setStatus(tx.st_remove_failed, .{err});
        self.selected = null;
        self.setStatus(tx.st_removed, .{name});
    }

    pub fn undo(self: *App) void {
        const f = self.store.undoLast() orelse return self.dropMissingLevels();
        // An icon: drawn anew, and the Sprites page shows it as it is now.
        const entry = self.store.files.items[f].entry;
        if (std.ascii.startsWithIgnoreCase(entry, "icons\\") and std.ascii.endsWithIgnoreCase(entry, ".spr")) self.forgetIcon(entry["icons\\".len .. entry.len - 4]);
        if (std.ascii.startsWithIgnoreCase(entry, "gfx_3d\\")) self.preview.reload();
        if (self.spr) |e| if (e.file == f) sprview.load(self, e) catch {};
        if (self.fonts.edit) |*fe| if (fe.file == f) @import("fontpage.zig").load(self, fe) catch {};
        var docs_buf: [doctabs.max + 1]*Doc = undefined;
        for (self.eachDoc(&docs_buf)) |d| {
            d.dropGone(f);
            d.restoreDeleted(f);
            d.refreshPos(f);
            if (f == d.lev) d.afterUndo() catch |err| return self.setStatus(tx.st_undo_failed, .{err});
        }
        if (self.doc) |d| if (self.selected) |i| if (i >= d.objects.items.len) {
            self.selected = null;
        };
        self.setStatus(tx.st_undone, .{});
    }

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

    pub fn addEnemy(self: *App, t: level.Template, at: ?[2]f32) void {
        const d = self.doc orelse return;
        const i = d.addEnemy(t, at) catch |err| return switch (err) {
            error.NoFreeTile, error.TileNotFree => self.setStatus(tx.st_no_tile, .{}),
            error.TooManyFighters => self.setStatus(tx.st_too_many, .{og.battle.battle.max_fighters}),
            else => self.setStatus(tx.st_add_failed, .{ t.class, err }),
        };
        self.selected = i;
        const o = d.objects.items[i];
        self.setStatus(tx.st_added, .{ o.name, t.class, t.level, o.tile.?[0], o.tile.?[1] });
    }

    pub fn addObstacle(self: *App, what: level.Obstacle, g: [2]f32) void {
        const d = self.doc orelse return;
        const i = d.addObstacle(what, g) catch |err| return switch (err) {
            error.TileNotFree => self.setStatus(tx.st_no_tile, .{}),
            error.TooManyFighters => self.setStatus(tx.st_too_many, .{og.battle.battle.max_fighters}),
            else => self.setStatus(tx.st_add_failed, .{ @tagName(what), err }),
        };
        self.selected = i;
        const o = d.objects.items[i];
        // A new item box opens for filling, as on locations.
        if (what == .box) if (d.boxFile(o.name)) |f| {
            self.box = .{ .file = f, .name = o.name };
            return self.setStatus(tx.st_box_added, .{o.name});
        };
        self.setStatus(tx.st_placed, .{o.name});
    }

    pub fn addProp(self: *App, what: level.Prop, g: [2]f32) void {
        const d = self.doc orelse return;
        const i = d.addProp(what, g) catch |err| return switch (err) {
            error.TileNotFree => self.setStatus(tx.st_no_tile, .{}),
            else => self.setStatus(tx.st_add_failed, .{ @tagName(what), err }),
        };
        self.selected = i;
        self.setStatus(tx.st_placed, .{d.objects.items[i].name});
    }

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
            c.SDL_ShowSaveFileDialog(dialogDone, null, self.window, &filters, 1, null);
        } else c.SDL_ShowOpenFileDialog(dialogDone, null, self.window, &filters, 1, null, false);
    }

    /// The mod packed into folder `out`: what differs from the original game (settings).
    pub fn packMod(self: *App, out: []const u8) !void {
        const orig_path = self.settings.originalPath() orelse return error.NoOriginal;
        if (std.mem.eql(u8, orig_path, self.game_dir)) return error.SameFolder;
        if (self.store.dirty()) {
            self.save();
            if (self.store.dirty()) return;
        }
        const cwd = Io.Dir.cwd();
        var game = try cwd.openDir(self.io, self.game_dir, .{});
        defer game.close(self.io);
        var orig = try cwd.openDir(self.io, orig_path, .{});
        defer orig.close(self.io);
        try cwd.createDirPath(self.io, out);
        var dest = try cwd.openDir(self.io, out, .{});
        defer dest.close(self.io);
        const files = try @import("modpack.zig").pack(self.io, self.gpa, game, orig, dest);
        defer @import("modpack.zig").freeList(self.gpa, files);
        self.setStatus(tx.st_packed, .{ files.len, out });
    }

    pub fn onOriginal(self: *App, _: FileAsk, path: []const u8) !void {
        self.settings.setOriginalPath(path);
        self.saveSettings();
    }

    pub fn onViewer(self: *App, _: FileAsk, path: []const u8) !void {
        self.settings.setViewerPath(path);
        self.saveSettings();
    }

    /// The port's file asked for at once, the play run after it's chosen.
    fn askViewer(self: *App, level_name: []const u8, scene: ?[]const u8) void {
        var pp: @TypeOf(self.play_pending.?) = .{};
        const sc = scene orelse "";
        if (level_name.len + sc.len > pp.buf.len) return;
        @memcpy(pp.buf[0..level_name.len], level_name);
        @memcpy(pp.buf[level_name.len..][0..sc.len], sc);
        pp.level = level_name.len;
        if (scene != null) pp.scene = sc.len;
        self.play_pending = pp;
        self.askFile(.{ .kind = .program, .run = onViewerPlay });
    }

    fn onViewerPlay(self: *App, ask: FileAsk, path: []const u8) !void {
        try self.onViewer(ask, path);
        var pp = self.play_pending orelse return;
        self.play_pending = null;
        self.playIn(pp.buf[0..pp.level], if (pp.scene) |n| pp.buf[pp.level..][0..n] else null);
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

    /// Undoes the edits after step `keep` (0 — every edit).
    pub fn rollBack(self: *App, keep: usize) void {
        var n: usize = 0;
        while (self.store.undo.items.len > keep) : (n += 1) self.undo();
        self.setStatus(tx.st_rolled_back, .{n});
    }

    /// Back to the files as an earlier session's save `keep` left them (0: the
    /// original): this session's edits undone, then the files put back as unsaved
    /// edits (Undo takes them back, Save writes them).
    pub fn returnToPast(self: *App, keep: usize) void {
        self.commitEditing();
        _ = self.endPaint();
        while (self.store.undo.items.len > 0) self.undo();
        const n = self.store.restorePast(keep) catch |err| return self.setStatus(tx.st_undo_failed, .{err});
        // The documents shown from the files as they are now.
        if (self.doc) |d| d.deinit();
        self.doc = null;
        self.dropParked();
        self.player.reload();
        self.preview.reload();
        self.rebuildCatalog();
        if (self.current) |i| self.open(i, true);
        self.setStatus(tx.st_returned, .{n});
    }

    fn startEditing(self: *App, e: Editing) void {
        self.commitEditing();
        self.editing = e;
    }

    pub fn stopEditing(self: *App) void {
        if (self.editing == null) return;
        self.editing = null;
    }

    pub fn treeQuery(self: *const App) []const u8 {
        return self.tree_query.get();
    }

    pub fn query(self: *const App) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    /// The level edit mode with its Objects tool: objects are moved, added, removed
    /// (the view mode only shows them).
    pub fn editingObjects(self: *const App) bool {
        return if (self.paint) |p| p.tool == .objects else false;
    }

    pub fn overlay(self: *const App) bool {
        return self.menu != null or self.tree_menu != null or self.confirm != null or self.box != null or self.trigger != null or self.code != null or self.sprShown() != null or (if (self.check) |r| r.shown else false);
    }

    /// The open sprite when its page is the centre's document (else its canvas is not drawn).
    pub fn sprShown(self: *const App) ?*@import("sprview.zig").Edit {
        return if (self.tab == .sprites and self.code == null) self.spr else null;
    }

    /// Typing goes to the search field: an overlay or a list of sounds.
    pub fn searching(self: *const App) bool {
        return self.overlay() or (self.picker != null and self.picker.?.what == .sound);
    }

    /// The Scenes tab on dialogue `name` (`01__port_bulldozer.dlg`).
    pub fn showDialog(self: *App, name: []const u8) void {
        self.setTab(.scenes);
        self.scene = null;
        self.scenes.dlg.set(name);
    }

    /// A new sprite from a PNG into `archive` (`icons`: an icon) — asks for the file.
    pub fn askNewSprite(self: *App, archive: []const u8, icons_dir: bool) void {
        self.spr_new.set(archive);
        self.spr_new_icons = icons_dir;
        self.askFile(.{ .kind = .png, .run = @import("sprview.zig").onNew });
    }

    /// The catalog's names from string.tab as edited (by each entry's nameID).
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
        const f = self.store.addNew(&.{.{ .archive = common_archive, .entry = entry, .text = text }}) catch |err| return self.setStatus(tx.st_set_failed, .{err});
        codeview.open(self, f, null);
        self.setStatus(tx.st_script_added, .{ base, base });
    }

    /// Text input on while something takes typing; a newly opened window starts an
    /// empty search.
    pub fn syncTextInput(self: *App) void {
        if (self.searching() and !self.overlay_was) self.query_len = 0;
        self.overlay_was = self.searching();
        const naming = self.level_naming or self.scenes.naming or (if (self.paint) |p| p.renaming else false);
        const want = self.editing != null or self.text_edit != null or self.num_edit != null or self.tree_focus or self.anim_focus or self.searching() or naming;
        if (want == self.text_input) return;
        self.text_input = want;
        _ = if (want) c.SDL_StartTextInput(self.window) else c.SDL_StopTextInput(self.window);
    }

    pub fn commitEditing(self: *App) void {
        const e = self.editing orelse return;
        self.stopEditing();
        const v = e.buf[0..e.len];
        _ = std.fmt.parseFloat(f32, v) catch return;
        self.store.setVar(e.file, e.names, v, e.after) catch |err| self.setStatus(tx.st_set_failed, .{err});
    }

    pub fn typed(self: *App, s: []const u8) void {
        if (self.text_edit != null) return @import("textedit.zig").typed(self, s);
        if (self.anim_focus) {
            const n = @min(s.len, self.anim_query.buf.len - self.anim_query.len);
            @memcpy(self.anim_query.buf[self.anim_query.len..][0..n], s[0..n]);
            self.anim_query.len += n;
            return;
        }
        if (self.tree_focus) {
            const n = @min(s.len, self.tree_query.buf.len - self.tree_query.len);
            @memcpy(self.tree_query.buf[self.tree_query.len..][0..n], s[0..n]);
            self.tree_query.len += n;
            return;
        }
        if (self.num_edit) |*e| {
            for (s) |ch| {
                if (e.len == e.buf.len or !(std.ascii.isDigit(ch) or ch == '.' or ch == ',' or ch == '-')) continue;
                e.buf[e.len] = if (ch == ',') '.' else ch;
                e.len += 1;
            }
            return;
        }
        if (self.paint) |p| if (p.renaming) return paint.typeName(p, s);
        if (self.level_naming) {
            for (s) |ch| {
                if (self.level_name_len == self.level_name.len or !(std.ascii.isAlphanumeric(ch) or ch == '_')) continue;
                self.level_name[self.level_name_len] = std.ascii.toLower(ch);
                self.level_name_len += 1;
            }
            return;
        }
        if (self.scenes.naming) {
            for (s) |ch| {
                if (self.scenes.name.len == self.scenes.name.buf.len or !(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) continue;
                self.scenes.name.buf[self.scenes.name.len] = ch;
                self.scenes.name.len += 1;
            }
            return;
        }
        const e = &(self.editing orelse {
            if (!self.searching() or self.query_len + s.len > self.query_buf.len) return;
            @memcpy(self.query_buf[self.query_len..][0..s.len], s);
            self.query_len += s.len;
            return;
        });
        for (s) |ch| {
            const ok = std.ascii.isDigit(ch) or ch == '.' or (ch == '-' and e.len == 0);
            if (!ok or e.len == e.buf.len) continue;
            e.buf[e.len] = ch;
            e.len += 1;
        }
    }

    /// What object `i` of the open level copies as; null (and a status) if it cannot.
    fn clipOf(self: *App, i: usize) ?Clip {
        const d = self.doc orelse return null;
        const o = d.objects.items[i];
        if (d.boxFile(o.name)) |f| {
            const t = self.gpa.dupe(u8, self.store.text(f)) catch return null;
            return .{ .what = .box, .box_text = t, .box_battle = d.isBattle() };
        }
        if (d.isBattle() and o.kind == .enemy) {
            const en = d.enemy(o.name) catch return null;
            const ci = en.class orelse return null;
            const entry = self.store.files.items[ci].entry;
            const base = entry[(std.mem.lastIndexOfScalar(u8, entry, '\\') orelse 0) + 1 ..];
            const cls = if (std.ascii.startsWithIgnoreCase(base, "ft_")) base[3..] else base;
            const stem = cls[0 .. std.mem.lastIndexOfScalar(u8, cls, '.') orelse cls.len];
            var cl: Clip = .{ .what = .enemy };
            cl.class_len = @min(stem.len, cl.class_buf.len);
            @memcpy(cl.class_buf[0..cl.class_len], stem[0..cl.class_len]);
            return cl;
        }
        if (d.isBattle()) {
            var eb: [128]u8 = undefined;
            const act = if (std.fmt.bufPrint(&eb, "{s}.act", .{o.name})) |e| (if (self.store.file(d.level_archive, e)) |f| self.store.text(f) else |_| "") else |_| "";
            inline for (comptime std.enums.values(level.Prop)) |pv| if (std.ascii.findIgnoreCase(o.name, "_a_" ++ @tagName(pv)) != null or std.ascii.findIgnoreCase(act, "obs_a_" ++ @tagName(pv)) != null) return .{ .what = .prop, .prop = pv };
            inline for (.{ "wcrate", "mcrate", "barrel" }) |tag| if (std.ascii.findIgnoreCase(o.name, tag) != null) return .{ .what = .obstacle, .obstacle = @field(level.Obstacle, tag) };
        }
        self.setStatus(tx.st_cant_copy, .{o.name});
        return null;
    }

    pub fn setClip(self: *App, cl: ?Clip) void {
        if (self.clip) |old| if (old.box_text) |t| self.gpa.free(t);
        self.clip = cl;
    }

    /// Object `i` copied.
    pub fn copyObject(self: *App, i: usize) void {
        const cl = self.clipOf(i) orelse return;
        self.setClip(cl);
        self.setStatus(tx.st_obj_copied, .{self.doc.?.objects.items[i].name});
    }

    /// The copied object put at background point `bg` (battles: the grid point `g` there,
    /// or the first free tile for an enemy without one).
    pub fn paste(self: *App, bg: [2]f32, g: ?[2]f32) void {
        const d = self.doc orelse return;
        const cl = self.clip orelse return;
        switch (cl.what) {
            .box => {
                if (cl.box_battle != d.isBattle()) return self.setStatus(tx.st_paste_kind, .{});
                if (d.isBattle()) self.addObstacle(.box, g orelse return self.setStatus(tx.st_no_tile, .{})) else self.addBox(bg);
                // The new box takes the copied contents (its script names no box).
                const b = self.box orelse return;
                const t = self.gpa.dupe(u8, cl.box_text.?) catch return;
                self.store.replace(b.file, t) catch self.gpa.free(t);
                self.box = null;
            },
            .enemy => {
                if (!d.isBattle()) return self.setStatus(tx.st_paste_kind, .{});
                for (self.allTemplates(self.frame.allocator())) |t| if (std.ascii.eqlIgnoreCase(t.class, cl.class())) return self.addEnemy(t, g);
                self.setStatus(tx.st_cant_copy, .{cl.class()});
            },
            .obstacle => if (d.isBattle()) self.addObstacle(cl.obstacle, g orelse return self.setStatus(tx.st_no_tile, .{})) else self.setStatus(tx.st_paste_kind, .{}),
            .prop => if (d.isBattle()) self.addProp(cl.prop, g orelse return self.setStatus(tx.st_no_tile, .{})) else self.setStatus(tx.st_paste_kind, .{}),
        }
    }

    /// Object `i` copied and put beside it (the clipboard keeps what it had).
    pub fn duplicate(self: *App, i: usize) void {
        const d = self.doc orelse return;
        const cl = self.clipOf(i) orelse return;
        const keep = self.clip;
        self.clip = cl;
        defer {
            if (cl.box_text) |t| self.gpa.free(t);
            self.clip = keep;
        }
        const o = d.objects.items[i];
        const g: ?[2]f32 = if (o.grid) |gp| .{ gp[0] + 1, gp[1] } else if (o.tile) |t| .{ @as(f32, @floatFromInt(t[0] + @as(i32, @intCast(o.size)))) + 0.5, @as(f32, @floatFromInt(t[1])) + 0.5 } else null;
        const before = d.objects.items.len;
        self.paste(.{ o.pos[0] + 24, o.pos[1] }, g);
        // An enemy with no free tile beside it: the first free one.
        if (cl.what == .enemy and d.objects.items.len == before) self.paste(o.pos, null);
    }

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
            .voice => @import("voices.zig").remove(self, n) catch |err| self.setStatus(tx.st_set_failed, .{err}),
            .text_row => {
                const texts = @import("texts.zig");
                const f: texts.File = for (std.enums.values(texts.File)) |v| {
                    if (std.mem.eql(u8, v.entry(), n)) break v;
                } else .strings;
                texts.remove(self, f, @intCast(cf.index)) catch |err| self.setStatus(tx.st_set_failed, .{err});
            },
            .anim => if (self.doc) |d| @import("levelanims.zig").remove(self, d, n),
            .path => if (self.doc) |d| @import("paths.zig").remove(self, d, n),
            .effect_frame => @import("effectpage.zig").removeFrame(self, cf.index) catch |err| self.setStatus(tx.st_remove_failed, .{err}),
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

    /// Lines of the level's scripts and the scenes naming `name` (quoted), for the menu.
    fn findRefs(self: *App, name: []const u8) void {
        for (self.menu_refs.items) |r| self.gpa.free(r.label);
        self.menu_refs.clearRetainingCapacity();
        const d = self.doc orelse return;
        var qb: [80]u8 = undefined;
        const needle = std.fmt.bufPrint(&qb, "\"{s}\"", .{name}) catch return;
        var tmp: std.heap.ArenaAllocator = .init(self.gpa);
        defer tmp.deinit();
        const where = [_]struct { []const u8, *const fn ([]const u8) bool }{ .{ d.level_archive, refs.script }, .{ common_archive, refs.scene } };
        for (where) |wh| for (refs.files(self, tmp.allocator(), wh[0], wh[1])) |f| {
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

    /// A 3D model standing on the location at `bg` (its own .act), picked.
    pub fn addActor(self: *App, mesh: []const u8, bg: [2]f32) void {
        const d = self.doc orelse return;
        const name = d.addActor(mesh, bg) catch |err| return if (err == error.NotWalkable) self.setStatus(tx.st_not_walkable, .{}) else self.setStatus(tx.st_add_failed, .{ mesh, err });
        self.selected = d.objects.items.len - 1;
        self.setStatus(tx.st_actor_added, .{name});
    }

    /// A new box at background point `bg`, its contents window open.
    pub fn addBox(self: *App, bg: [2]f32) void {
        const d = self.doc orelse return;
        const i = d.addBox(bg) catch |err| return if (err == error.NotWalkable) self.setStatus(tx.st_not_walkable, .{}) else self.setStatus(tx.st_add_failed, .{ "box", err });
        self.selected = i;
        const o = d.objects.items[i];
        self.box = .{ .file = o.file.?, .name = o.name };
        self.setStatus(tx.st_box_added, .{o.name});
    }

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
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSize(self.window, &w, &h);
        return .{ @min(self.mouse[0], @as(f32, @floatFromInt(w)) - 264), @max(0, @min(self.mouse[1], @as(f32, @floatFromInt(h)) - 560)) };
    }

    /// A new scene `sceneN`: its script (a template to fill), an empty points file and a
    /// dialogue without recordings; selected, the script open. One undo step.
    pub fn newScene(self: *App) void {
        var nb: [32]u8 = undefined;
        const name = for (1..1000) |n| {
            const s = std.fmt.bufPrint(&nb, "scene{d}", .{n}) catch unreachable;
            for (self.catalog.scenes.items) |sc| {
                if (std.ascii.eqlIgnoreCase(sc.name, s)) break;
            } else break s;
        } else return;
        const a = self.frame.allocator();
        const scr = std.fmt.allocPrint(self.gpa,
            \\// A scene made in the editor. Its points: scriptlets\{s}.pts (level edit
            \\// mode, "Scene points"); its lines: {s}.dlg. Started by StartScriptlet("{s}").
            \\GUI_CUTSCENE
            \\PANORAMA_ON
            \\AUTOCAMERA_OFF
            \\DIALOG_INIT("{s}","{s}.dlg")
            \\// A hero brought to the level joins in the level script before this scene starts,
            \\// as McFadden in 02_serwers.lev: EnableObject("Medusa"); HERO_EnableEnumerate("Medusa",1);
            \\// ACTORSETSTATE("Medusa",0)
            \\// PLACE("Medusa","p1")
            \\// DOLLY("p1",0,130)
            \\// WALKTO("Medusa","p2")
            \\// WAITFORACTOR("Medusa")
            \\DIALOG_DISPLAY(0)
            \\GUI_NORMAL
            \\PANORAMA_OFF
            \\
        , .{ name, name, name, name, name }) catch return;
        const scr_crlf = std.mem.replaceOwned(u8, self.gpa, scr, "\n", "\r\n") catch return;
        self.gpa.free(scr);
        const dlg = std.fmt.allocPrint(self.gpa, "DIALOG {s}\r\n\r\nSullivan:\r\n  ...\r\n", .{name}) catch return;
        const pts = self.gpa.alloc(u8, 0) catch return;
        const f = self.store.addNew(&.{
            .{ .archive = common_archive, .entry = std.fmt.allocPrint(a, "scriptlets\\{s}.scr", .{name}) catch return, .text = scr_crlf },
            .{ .archive = common_archive, .entry = std.fmt.allocPrint(a, "scriptlets\\{s}.pts", .{name}) catch return, .text = pts },
            .{ .archive = "common/lang.dat", .entry = std.fmt.allocPrint(a, "{s}.dlg", .{name}) catch return, .text = dlg },
        }) catch |err| return self.setStatus(tx.st_set_failed, .{err});
        self.catalog.scenes.append(self.catalog.arena.allocator(), .{ .name = self.catalog.arena.allocator().dupe(u8, name) catch return }) catch return;
        self.scene = self.catalog.scenes.items.len - 1;
        self.scenes.dlg.len = 0;
        codeview.open(self, f, null);
        self.setStatus(tx.st_scene_added, .{name});
    }

    /// Location `name` made from the open one and opened: written to disk at once
    /// (the level list and the world read levels from there), not an undo step.
    pub fn newLevel(self: *App, name: []const u8) void {
        self.level_naming = false;
        // The mode's strokes into the Store first (it may reload the level).
        _ = self.endPaint();
        const d = self.doc orelse return;
        const battle = d.isBattle();
        makeLevel(self, d, name) catch |err| return if (battle) self.setStatus(tx.st_battle_failed, .{ name, err }) else self.setStatus(tx.st_location_failed, .{ name, err });
        // The old names stay alive (templates point into them); only the list grows.
        const more = self.gpa.alloc(level.LevelEntry, self.levels.len + 1) catch return;
        @memcpy(more[0..self.levels.len], self.levels);
        more[self.levels.len] = .{ .name = self.gpa.dupe(u8, name) catch return self.gpa.free(more), .battle = battle };
        std.mem.sort(level.LevelEntry, more, {}, struct {
            fn lt(_: void, x: level.LevelEntry, y: level.LevelEntry) bool {
                return std.mem.order(u8, x.name, y.name) == .lt;
            }
        }.lt);
        self.gpa.free(self.levels);
        self.levels = more;
        self.current = null;
        self.store.levelMade(name, tx.alloc(self.frame.allocator(), tx.st_level_step, .{name})) catch {};
        if (battle) self.setStatus(tx.st_battle_made, .{ name, d.name, name }) else self.setStatus(tx.st_location_made, .{ name, d.name, name });
        self.showLevel(name, if (battle) null else "capt_start");
    }

    /// Scene `old` named `new`: its `.scr` and `.pts` under the new name, every
    /// `"old"` in the scripts starting scenes and in the other scenes as `"new"`.
    pub fn renameScene(self: *App, old_in: []const u8, new: []const u8) void {
        const a = self.frame.allocator();
        const old = a.dupe(u8, old_in) catch return;
        if (new.len == 0 or new.len > 40) return self.setStatus(tx.st_scene_bad_name, .{new});
        for (new) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-') return self.setStatus(tx.st_scene_bad_name, .{new});
        if (std.ascii.eqlIgnoreCase(old, new)) return;
        var idx: ?usize = null;
        for (self.catalog.scenes.items, 0..) |sc, i| {
            if (std.ascii.eqlIgnoreCase(sc.name, new)) return self.setStatus(tx.st_scene_taken, .{new});
            if (std.ascii.eqlIgnoreCase(sc.name, old)) idx = i;
        }
        // The files: copies under the new name, the old ones deleted.
        var news: std.ArrayList(store_mod.NewFile) = .empty;
        var gone: std.ArrayList(usize) = .empty;
        for ([_][]const u8{ "scr", "pts" }) |ext| {
            const f = self.store.file(common_archive, std.fmt.allocPrint(a, "scriptlets\\{s}.{s}", .{ old, ext }) catch return) catch continue;
            const t = self.gpa.dupe(u8, self.store.text(f)) catch return;
            news.append(a, .{ .archive = common_archive, .entry = std.fmt.allocPrint(a, "scriptlets\\{s}.{s}", .{ new, ext }) catch return, .text = t }) catch return;
            gone.append(a, f) catch return;
        }
        if (news.items.len == 0) return self.setStatus(tx.st_set_failed, .{error.NoScene});
        _ = self.store.addNew(news.items) catch |err| return self.setStatus(tx.st_set_failed, .{err});
        self.store.delete(gone.items) catch |err| return self.setStatus(tx.st_set_failed, .{err});
        // The names in the scripts: level ones starting scenes, then the scenes.
        var files: std.ArrayList(usize) = .empty;
        for (self.catalog.scene_files.items) |sf| files.append(a, self.store.file(sf.archive, sf.entry) catch continue) catch {};
        for (self.catalog.scenes.items) |sc| files.append(a, self.store.file(common_archive, std.fmt.allocPrint(a, "scriptlets\\{s}.scr", .{if (std.ascii.eqlIgnoreCase(sc.name, old)) new else sc.name}) catch continue) catch continue) catch {};
        var n: usize = 0;
        for (files.items) |f| {
            const t = trigger.renameQuoted(self.gpa, self.store.text(f), old, new) catch continue;
            if (std.mem.eql(u8, t, self.store.text(f))) {
                self.gpa.free(t);
                continue;
            }
            self.store.replace(f, t) catch {
                self.gpa.free(t);
                continue;
            };
            n += 1;
        }
        if (idx) |i| self.catalog.scenes.items[i].name = self.catalog.arena.allocator().dupe(u8, new) catch return;
        self.setStatus(tx.st_scene_renamed, .{ old, new, n });
    }

    /// A link to follow once this frame is laid out: scene `name`, or level `name`
    /// with object `obj`.
    pub fn link(self: *App, scene: bool, name: []const u8, obj: ?[]const u8) void {
        var n: @FieldType(@typeInfo(@FieldType(App, "nav")).optional.child, "name") = undefined;
        var o: @FieldType(@typeInfo(@FieldType(App, "nav")).optional.child, "obj") = undefined;
        const nl = @min(name.len, n.len);
        @memcpy(n[0..nl], name[0..nl]);
        const ob = obj orelse "";
        const ol = @min(ob.len, o.len);
        @memcpy(o[0..ol], ob[0..ol]);
        self.nav = .{ .scene = scene, .name = n, .name_len = nl, .obj = o, .obj_len = ol };
    }

    pub fn followLink(self: *App) void {
        const l = self.nav orelse return;
        self.nav = null;
        self.trigger = null;
        if (l.scene) return self.showScene(l.name[0..l.name_len]);
        self.showLevel(l.name[0..l.name_len], if (l.obj_len > 0) l.obj[0..l.obj_len] else null);
    }

    /// The Scenes tab on scene `name` (a link from a trigger or another scene).
    pub fn showScene(self: *App, name: []const u8) void {
        for (self.catalog.scenes.items, 0..) |sc, i| if (std.ascii.eqlIgnoreCase(sc.name, name)) {
            self.setTab(.scenes);
            self.scene = i;
            self.scenes.dlg.len = 0;
            self.scenes.naming = false;
            return;
        };
        self.setStatus(tx.st_no_such_scene, .{name});
    }

    /// Level `level` open on its tab; area or object `obj` (if given) picked and centred.
    pub fn showLevel(self: *App, level_name: []const u8, obj: ?[]const u8) void {
        for (self.levels, 0..) |lv, i| if (std.ascii.eqlIgnoreCase(lv.name, level_name)) {
            self.setTab(if (lv.battle) .battles else .locations);
            if (self.current == null or self.current.? != i) self.open(i, false);
            const d = self.doc orelse return;
            const name = obj orelse return;
            for (d.objects.items, 0..) |o, k| if (std.ascii.eqlIgnoreCase(o.name, name)) {
                self.selected = k;
                if (viewportRect()) |v| {
                    if (!d.fitted) d.fit(v);
                    d.origin = .{ o.pos[0] - v.w / 2 / d.zoom, o.pos[1] - v.h / 2 / d.zoom };
                }
                return;
            };
            return;
        };
        self.setStatus(tx.st_no_such_level, .{level_name});
    }

    /// The scene picked in the Scenes tab (its points are placed in the level edit mode).
    pub fn sceneName(self: *const App) ?[]const u8 {
        const i = self.scene orelse return null;
        return if (i < self.catalog.scenes.items.len) self.catalog.scenes.items[i].name else null;
    }

    /// Party hero `name` on the open battle at grid point `g` (PlaceActor in restore()).
    pub fn addOwn(self: *App, name: []const u8, g: [2]f32) void {
        const d = self.doc orelse return;
        const i = d.addOwn(name, g) catch |err| return switch (err) {
            error.TileNotFree => self.setStatus(tx.st_no_tile, .{}),
            error.HeroThere => self.setStatus(tx.st_hero_there, .{name}),
            else => self.setStatus(tx.st_add_failed, .{ name, err }),
        };
        self.selected = i;
        self.setStatus(tx.st_own_added, .{name});
    }

    /// Hero entry `e` (catalog) brought onto the open location at `bg`, hidden.
    pub fn addHero(self: *App, e: usize, bg: [2]f32) void {
        const d = self.doc orelse return;
        const en = self.catalog.entries.items[e];
        const name = d.addHero(en.archive, en.entry, bg) catch |err| return switch (err) {
            error.NotWalkable => self.setStatus(tx.st_not_walkable, .{}),
            error.HeroThere => self.setStatus(tx.st_hero_there, .{en.id}),
            else => self.setStatus(tx.st_add_failed, .{ en.id, err }),
        };
        self.setStatus(tx.st_hero_added, .{name});
    }

    /// Hero `name` of the open location deleted with its weapons and the script lines
    /// calling it (Ctrl+Z brings them back); the scenes this level starts that still
    /// name it are reported (they are shared: not touched).
    pub fn removeHero(self: *App, name_in: []const u8) void {
        const d = self.doc orelse return;
        const a = self.frame.allocator();
        const name = a.dupe(u8, name_in) catch return;
        d.removeHero(name) catch |err| return if (err == error.Referenced) self.setStatus(tx.st_hero_referenced, .{ name, d.refFile() }) else self.setStatus(tx.st_remove_failed, .{err});
        self.selected = null;
        // A scene of this level still placing it (PLACE("Medusa",…)): it would play without it.
        const q = std.fmt.allocPrint(a, "\"{s}\"", .{name}) catch return;
        var scene: ?[]const u8 = null;
        for (self.catalog.scenes.items) |sc| {
            const f = self.store.file(common_archive, std.fmt.allocPrint(a, "scriptlets\\{s}.scr", .{sc.name}) catch continue) catch continue;
            if (std.ascii.findIgnoreCase(self.store.text(f), q) == null) continue;
            const sq = std.fmt.allocPrint(a, "\"{s}\"", .{sc.name}) catch continue;
            for (d.levelFiles(a) catch &.{}) |lf_| if (std.ascii.findIgnoreCase(self.store.text(lf_), sq) != null) {
                scene = sc.name;
            };
        }
        if (scene) |sc| self.setStatus(tx.st_hero_removed_scene, .{ name, sc }) else self.setStatus(tx.st_hero_removed, .{name});
        self.reloadLevel();
    }

    /// Deletes box `i` of the level (its script and position file; Ctrl+Z brings it back).
    pub fn deleteBox(self: *App, i: usize) void {
        const d = self.doc orelse return;
        const name = d.objects.items[i].name;
        const actor = d.objects.items[i].kind == .actor;
        d.deleteBox(i) catch |err| return self.setStatus(tx.st_remove_failed, .{err});
        self.selected = null;
        if (actor) self.setStatus(tx.st_actor_deleted, .{name}) else self.setStatus(tx.st_box_deleted, .{name});
    }

    pub fn viewportRect() ?c.SDL_FRect {
        const b = clay.box(clay.id("viewport")) orelse return null;
        return .{ .x = b.x, .y = b.y, .w = b.width, .h = b.height };
    }

    pub fn overViewport(self: *const App) bool {
        const v = viewportRect() orelse return false;
        return self.mouse[0] >= v.x and self.mouse[0] < v.x + v.w and self.mouse[1] >= v.y and self.mouse[1] < v.y + v.h;
    }
};

/// A short name kept by value (a picked file, a typed query): no allocation, cut at `n`.
pub fn Name(comptime n: usize) type {
    return struct {
        buf: [n]u8 = undefined,
        len: usize = 0,

        pub fn get(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn set(self: *@This(), s: []const u8) void {
            self.len = @min(s.len, n);
            @memcpy(self.buf[0..self.len], s[0..self.len]);
        }
    };
}

/// A player's place: "0:42 / 3:15" and a bar filled that far (`len` null: unknown).
pub fn timeBar(a: Allocator, at: f32, len: ?f32) void {
    const w: f32 = 240;
    clay.open(.{ .layout = .{ .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(w), .height = clay.fixed(4) } }, .backgroundColor = theme.line, .cornerRadius = clay.radius(2) });
    const frac = if (len) |l| if (l > 0) std.math.clamp(at / l, 0, 1) else 0 else 0;
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(w * frac), .height = clay.grow() } }, .backgroundColor = theme.accent, .cornerRadius = clay.radius(2) });
    clay.close();
    const s: u32 = @intFromFloat(at);
    const t = if (len) |l| std.fmt.allocPrint(a, "{d}:{d:0>2} / {d}:{d:0>2}", .{ s / 60, s % 60, @as(u32, @intFromFloat(l)) / 60, @as(u32, @intFromFloat(l)) % 60 }) else std.fmt.allocPrint(a, "{d}:{d:0>2}", .{ s / 60, s % 60 });
    txt(t catch "", 13, theme.dim, font_mod.regular);
    clay.close();
}

pub fn txt(s: []const u8, pt: u16, col: clay.Color, font_id: u16) void {
    clay.text(s, .{ .textColor = col, .fontSize = pt, .fontId = font_id, .wrapMode = ui.CLAY_TEXT_WRAP_NONE });
}

/// A clickable row or card: opened as `d` (its id and its own colour), highlighted
/// under the pointer and while `selected`; true when clicked. The caller fills and
/// closes it.
pub fn clickable(app: *const App, d: clay.Decl, selected: bool) bool {
    var dd = d;
    if (selected) dd.backgroundColor = theme.row_selected else if (clay.pointerOver(d.id)) dd.backgroundColor = theme.row_hover;
    clay.open(dd);
    return clay.hovered() and app.clicked;
}

/// A centred window over the editor (`w` wide, at most `h` tall) with its title bar:
/// `title`, then `extra` (a text button; "" for none) and Close. Says which was clicked;
/// the caller fills the window under the bar and closes it.
const ModalHit = enum { none, close, extra };

pub fn modal(app: *const App, id: []const u8, w: f32, h_max: f32, bg: clay.Color, title: []const u8, extra: []const u8) ModalHit {
    const h = @min(h_max, app.size[1] - 80);
    clay.open(.{
        .id = clay.id(id),
        .layout = .{ .sizing = .{ .width = clay.fixed(w), .height = clay.fixed(h) }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM },
        .backgroundColor = bg,
        .border = .{ .color = theme.row_selected, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } },
        .floating = .{ .offset = .{ .x = (app.size[0] - w) / 2, .y = (app.size[1] - h) / 2 }, .zIndex = 100, .attachTo = ui.CLAY_ATTACH_TO_ROOT },
    });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fit() }, .padding = .{ .left = 16, .right = 12, .top = 12, .bottom = 4 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    txt(title, 18, theme.text, font_mod.bold);
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow() } } });
    var hit: ModalHit = .none;
    for ([_][]const u8{ extra, tx.get(tx.close) }, 0..) |label, k| {
        if (label.len == 0) continue;
        if (clickable(app, .{ .id = clay.idi(id, @intCast(k + 1)), .layout = .{ .padding = .{ .left = 10, .right = 10, .top = 4, .bottom = 4 } }, .backgroundColor = bg }, false)) hit = if (k == 0) .extra else .close;
        txt(label, 14, theme.dim, font_mod.regular);
        clay.close();
    }
    clay.close();
    return hit;
}

/// A page's right column — its properties and actions, beside the centre's view or
/// editor, as the level's inspector (the same width, dragged by its edge). Closed by
/// the caller.
pub fn propsOpen(app: *App, id: []const u8) void {
    app.splitter(.objects, false, -1, 1);
    clay.openScroll(.{ .id = clay.id(id), .layout = .{ .sizing = .{ .width = clay.fixed(app.split(.objects)), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 }, .childGap = 10 }, .backgroundColor = theme.panel, .border = .{ .color = theme.line, .width = .{ .left = 1 } } });
}

/// A titled group of the right column (a line above all but the first).
pub fn propsTitle(s: []const u8, first: bool) void {
    if (!first) clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(1) } }, .backgroundColor = theme.line });
    txt(s, 15, theme.text, font_mod.bold);
}

/// A label and its value in the right column.
pub fn propRow(label: []const u8, value: []const u8) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(100) } } });
    txt(label, 13, theme.dim, font_mod.regular);
    clay.close();
    clay.text(value, .{ .textColor = theme.text, .fontSize = 13, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    clay.close();
}

/// A dim wrapped note in the right column.
pub fn propNote(s: []const u8) void {
    clay.text(s, .{ .textColor = theme.dim, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
}

/// A panel's title bar: darker, a line under it.
/// A section title: a raised bar, the accent mark at its left, the title in light bold.
pub fn panelHeader(s: []const u8) void {
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(32) }, .padding = .{ .left = 12, .right = 12 }, .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = theme.title,
        .border = .{ .color = theme.line, .width = .{ .bottom = 1 } },
    });
    txt(s, 14, theme.text, font_mod.bold);
    clay.close();
}

/// A raised button; `primary` in the accent colour. True when clicked.
pub fn button(app: *const App, id: []const u8, label: []const u8, primary: bool) bool {
    return buttonSized(app, id, label, primary, clay.fit());
}

/// A toolbar button: an icon and (if any) a label; `on` — the tool in use (accent),
/// `primary` — the main action.
pub fn toolButton(app: *App, id: []const u8, ic: @import("icons.zig").Icon, label: []const u8, on: bool, primary: bool) bool {
    const bid = clay.id(id);
    const over = clay.pointerOver(bid);
    clay.open(.{
        .id = bid,
        .layout = .{ .sizing = .{ .height = clay.fixed(30) }, .padding = .{ .left = 10, .right = if (label.len > 0) 12 else 10 }, .childGap = 7, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = if (primary) (if (over) theme.accent_hover else theme.accent) else if (on) theme.row_selected else if (over) theme.button_hover else theme.button,
        .cornerRadius = clay.radius(theme.radius),
        .border = .{ .color = if (primary or on) theme.accent else theme.button_edge, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } },
    });
    const hit = clay.hovered() and app.clicked;
    @import("icons.zig").leaf(app.r, app.gpa, ic, 16, if (on or primary) theme.text else theme.dim);
    if (label.len > 0) txt(label, 13, theme.text, if (on or primary) font_mod.bold else font_mod.regular);
    clay.close();
    return hit;
}

/// A segmented control (as the concept's Paint | Erase): `labels` side by side, `sel`
/// highlighted; returns the one clicked.
pub fn segmented(app: *App, id: []const u8, labels: []const []const u8, sel: usize) ?usize {
    var hit: ?usize = null;
    clay.open(.{ .layout = .{ .childGap = 0 }, .cornerRadius = clay.radius(theme.radius), .border = .{ .color = theme.button_edge, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } } });
    for (labels, 0..) |l, k| {
        const bid = clay.idi(id, @intCast(k));
        const on = k == sel;
        clay.open(.{ .id = bid, .layout = .{ .sizing = .{ .height = clay.fixed(30) }, .padding = .{ .left = 16, .right = 16 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = if (on) theme.accent else if (clay.pointerOver(bid)) theme.button_hover else theme.button, .cornerRadius = clay.radius(theme.radius) });
        if (clay.hovered() and app.clicked) hit = k;
        txt(l, 13, theme.text, if (on) font_mod.bold else font_mod.regular);
        clay.close();
    }
    clay.close();
    return hit;
}

/// A slider 0…1 (as the concept's opacity): a track, its filled part and a knob;
/// pressed and dragged it follows the pointer. Returns the new value while moved.
pub fn slider(app: *App, id: []const u8, v: f32) ?f32 {
    const sid = clay.id(id);
    const h: u32 = sid.id;
    const b = clay.box(sid);
    clay.open(.{ .id = sid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(24) }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
    if (clay.hovered() and app.clicked) app.slider_drag = h;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(6) } }, .backgroundColor = theme.field_border, .cornerRadius = clay.radius(3) });
    const w = if (b) |bb| bb.width else 160;
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(@max(0, w * std.math.clamp(v, 0, 1))), .height = clay.fixed(6) } }, .backgroundColor = theme.accent, .cornerRadius = clay.radius(3) });
    clay.close();
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(16), .height = clay.fixed(16) } }, .backgroundColor = theme.text, .cornerRadius = clay.radius(8), .floating = .{ .offset = .{ .x = w * std.math.clamp(v, 0, 1) - 8, .y = 4 }, .attachTo = ui.CLAY_ATTACH_TO_PARENT } });
    clay.close();
    if (app.slider_drag == h) {
        if (!app.down) {
            app.slider_drag = null;
            return null;
        }
        const bb = b orelse return null;
        return std.math.clamp((app.mouse[0] - bb.x) / @max(1, bb.width), 0, 1);
    }
    return null;
}

/// `button` as wide as its column (the level's actions).
pub fn buttonWide(app: *const App, id: []const u8, label: []const u8, primary: bool) bool {
    return buttonSized(app, id, label, primary, clay.grow());
}

fn buttonSized(app: *const App, id: []const u8, label: []const u8, primary: bool, width: ui.Clay_SizingAxis) bool {
    const bid = clay.id(id);
    const over = clay.pointerOver(bid);
    clay.open(.{
        .id = bid,
        .layout = .{ .sizing = .{ .width = width, .height = clay.fixed(28) }, .padding = .{ .left = 12, .right = 12 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = if (over and app.down) (if (primary) theme.accent else theme.button_down) else if (primary) (if (over) theme.accent_hover else theme.accent) else if (over) theme.button_hover else theme.button,
        .cornerRadius = clay.radius(theme.radius),
        .border = .{ .color = if (primary) theme.accent else theme.button_edge, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } },
    });
    const hit = clay.hovered() and app.clicked;
    txt(label, 13, theme.text, if (primary) font_mod.bold else font_mod.regular);
    clay.close();
    return hit;
}

/// The search typed into the open window (it takes all typing; Backspace erases).
pub fn searchField(app: *App, a: Allocator) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fit() }, .padding = .{ .left = 10, .right = 10, .bottom = 6 } } });
    clay.open(.{
        .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(26) }, .padding = .{ .left = 8, .right = 8 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = theme.field,
        .cornerRadius = clay.radius(theme.radius),
        .border = .{ .color = theme.accent, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } },
    });
    if (app.query_len > 0) {
        txt(std.fmt.allocPrint(a, "{s}|", .{app.query()}) catch "", 14, theme.text, font_mod.regular);
    } else txt(tx.get(tx.search_hint), 14, theme.dim, font_mod.regular);
    clay.close();
    clay.close();
}

/// Game name of enemy class `class` ("" — unknown).
pub fn enemyTitle(self: *App, class: []const u8) []const u8 {
    for (self.catalog.entries.items) |e| if (e.kind == .enemy and std.ascii.eqlIgnoreCase(e.id, class)) return e.title;
    return "";
}

pub fn fmtNum(a: Allocator, v: ?f32) []const u8 {
    const x = v orelse return "—";
    return std.fmt.allocPrint(a, "{d}", .{x}) catch "?";
}

/// A number box: shows `v`, a click starts typing a new value for `names` of `file`
/// (a missing one goes after the line holding `after`).
pub fn valueCell(app: *App, a: Allocator, row: u32, file: usize, names: []const []const u8, after: ?[]const u8, v: ?f32, strong: bool, bold: bool) void {
    const vid = clay.idi("val", row);
    const editing = if (app.editing) |e| e.row == row else false;
    clay.open(.{
        .id = vid,
        .layout = .{ .sizing = .{ .width = clay.fixed(64), .height = clay.fixed(20) }, .padding = .{ .left = 6, .right = 6 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = if (editing) theme.viewport else if (clay.pointerOver(vid)) theme.row_hover else theme.field,
        .cornerRadius = clay.radius(theme.radius),
        .border = .{ .color = if (editing) theme.accent else theme.field_border, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } },
    });
    if (clay.hovered() and app.clicked and !editing) app.startEditing(.{ .row = row, .file = file, .names = names, .after = after });
    if (editing) {
        const e = app.editing.?;
        txt(std.fmt.allocPrint(a, "{s}|", .{e.buf[0..e.len]}) catch "", 13, theme.text, font_mod.regular);
    } else txt(fmtNum(a, v), 13, if (strong) theme.text else theme.dim, if (bold) font_mod.bold else font_mod.regular);
    clay.close();
}

/// Level `name` in `dat/<name>/` from level `d` (its unsaved edits included):
/// `background\<d>.*` and the pixel format under the new name; a location's walk
/// grids and lights, no paths, the entry area and a clean script; a battle's grid
/// (`.cm`), lights and areas, its heroes' places, no enemies (newlevel.zig).
fn makeLevel(app: *App, d: *Doc, name: []const u8) !void {
    const battle = d.isBattle();
    if (!newlevel.validName(name, battle)) return error.BadName;
    const io = app.io;
    const dat = app.store.dat;
    if (dat.access(io, name, .{})) |_| return error.LevelExists else |_| {}
    var arena_state: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // sprite.dat: the pixel format and every background\<template>.* renamed.
    var sprites: std.ArrayList(og.formats.archive.File) = .empty;
    var other: std.ArrayList(og.formats.archive.File) = .empty;
    const tpl_sprites = try std.fmt.allocPrint(a, "{s}/sprite.dat", .{d.name});
    {
        var ar = try og.formats.archive.Archive.open(io, app.gpa, dat, tpl_sprites);
        defer ar.close(io, app.gpa);
        const prefix = try std.fmt.allocPrint(a, "background\\{s}.", .{d.name});
        for (ar.entries) |*e| {
            const ext = if (std.ascii.startsWithIgnoreCase(e.name, prefix)) e.name[prefix.len..] else if (std.ascii.eqlIgnoreCase(e.name, "1.bin")) "" else continue;
            const f = try app.store.file(tpl_sprites, e.name);
            try sprites.append(a, .{
                .name = if (ext.len == 0) "1.bin" else try std.fmt.allocPrint(a, "background\\{s}.{s}", .{ name, ext }),
                .data = app.store.text(f),
            });
        }
    }
    if (sprites.items.len < 2) return error.NoTemplate;
    // other.dat: a location's walk grids and lights (no paths, a new entry area); a
    // battle's grid, lights and areas; a clean script.
    const copied: []const []const u8 = if (battle) &.{ "cm", "lts", "ar" } else &.{ "wm", "wm2", "lts" };
    for (copied) |ext| {
        const f = app.store.file(d.level_archive, try std.fmt.allocPrint(a, "{s}.{s}", .{ d.name, ext })) catch continue;
        try other.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}.{s}", .{ name, ext }), .data = app.store.text(f) });
    }
    const lev = try app.store.file(d.level_archive, try std.fmt.allocPrint(a, "{s}.lev", .{d.name}));
    if (battle) {
        // Its fighters (each `.ftr` an enemy object) stay out of the new one.
        var enemies: std.ArrayList([]const u8) = .empty;
        for (try d.levelFiles(a)) |f| {
            const e = app.store.files.items[f].entry;
            if (std.ascii.endsWithIgnoreCase(e, ".ftr")) try enemies.append(a, e[0 .. e.len - 4]);
        }
        try other.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}.lev", .{name}), .data = try newlevel.battleLevText(a, app.store.text(lev), enemies.items) });
        return writeLevel(app, a, name, sprites.items, other.items);
    }
    const centre: [2]f32 = .{ d.bg_size[0] / 2, d.bg_size[1] / 2 };
    const start = d.nearestWalkable(centre) orelse return error.NoWalkable;
    try other.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}.lev", .{name}), .data = try newlevel.levText(a, app.store.text(lev), d.name) });
    try other.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}.ar", .{name}), .data = try newlevel.arText(a, start) });
    try other.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}.ap", .{name}), .data = "pathCnt=0\r\n" });
    return writeLevel(app, a, name, sprites.items, other.items);
}

/// `dat/<name>/sprite.dat` and `other.dat` with these files: empty archives (their
/// closing empty entry) filled as the editor's saves are; nothing left on failure.
fn writeLevel(app: *App, a: Allocator, name: []const u8, sprites: []const og.formats.archive.File, other: []const og.formats.archive.File) !void {
    const io = app.io;
    const dat = app.store.dat;
    try dat.createDirPath(io, name);
    errdefer dat.deleteTree(io, name) catch {};
    const empty = try og.formats.archive.build(a, &.{.{ .name = "", .data = "" }});
    for ([_]struct { []const u8, []const og.formats.archive.File }{ .{ "sprite.dat", sprites }, .{ "other.dat", other } }) |part| {
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ name, part[0] });
        try dat.writeFile(io, .{ .sub_path = path, .data = empty });
        try og.formats.archive.rewrite(io, app.gpa, dat, path, part[1]);
    }
}

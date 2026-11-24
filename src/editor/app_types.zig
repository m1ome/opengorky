//! The value types of the editor's state (App, app.zig, re-exports them): what a field
//! of App holds — an open box, a confirmation, a drag, a menu, a clip, a short name.

const std = @import("std");
const tx = @import("text.zig");
const level = @import("level.zig");
const Doc = level.Doc;
const paint = @import("paint.zig");
const App = @import("app.zig").App;

/// What a chosen PNG is for.
/// The box being edited (boxpanel.zig): its script (Store index) and object name.
pub const BoxOpen = struct {
    file: usize,
    name: []const u8,
    /// A hero's starting inventory (the calls giving items to this owner) instead of a box.
    owner: ?[]const u8 = null,
};

/// A script line naming something: its Store file, byte offset and the line shown (owned).
/// (`entry` points into `label`; `path` is the level's or common's archive).
pub const Ref = struct { path: []const u8, entry: []const u8, at: usize, label: []u8 };

/// The scene page's map: the location, its starting area, the objects the scene names.
pub const ScenePreview = struct {
    doc: ?*Doc = null,
    sel: ?usize = null,
    focus: ?[4]f32 = null,
    names: std.ArrayList(usize) = .empty,
    show: [3]bool = .{ true, true, true },
};

/// A deletion asked about first (the confirmation window): what, on which object; or
/// the project's conversion to OpenGorky.
pub const Confirm = struct {
    what: enum { object, box, hero, area, point, light, frame, voice, purge, text_row, anim, path, effect_frame, model, entry },
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
pub const Parked = struct { doc: ?*Doc, current: usize };

/// A level's edit mode as it was: its tool, layer, shown and locked layers.
pub const PaintKeep = struct { tool: paint.Tool, layer: paint.Layer, show: [5]bool, locked: [5]bool, show_objects: bool, scene: Name(64) };

pub const Tab = @import("doctab.zig").Tab;

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
    .{ .label = tx.p_ai_attack, .names = &.{"ai_attack_weight"} },
    .{ .label = tx.p_ai_defense, .names = &.{"ai_threat_weight"} },
    .{ .label = tx.p_ai_player, .names = &.{"ai_opponent_distance_weight"} },
    .{ .label = tx.p_ai_guard, .names = &.{"ai_guard_distance_weight"} },
};
// Resistances are not here: `pr*` fields are the heroes' armour; monsters resist by
// the exe table for their classic_id (entries.resistBlock, read-only).
pub const damage_stat: Stat = .{ .label = tx.damage_of, .names = &.{"max_damage"} };

/// What a file dialog offers (its filter), and whether it saves (`_out`).
pub const FileKind = enum { png, png_out, sound, wav_out, audio, video, ttf, glb, glb_out, folder, program };

/// A file asked for: the dialog's kind, what the chosen path does (it sets the status;
/// an error it returns is shown as a failed import), the thing it is for (`entry`, `slot`).
/// `name`: an export's suggested file name, the original's (`skrzynia.3df` → `skrzynia.png`;
/// the export's extension put on, App.askFile).
pub const FileAsk = struct { kind: FileKind, run: *const fn (*App, FileAsk, []const u8) anyerror!void, entry: usize = 0, slot: u8 = 0, name: []const u8 = "" };

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
pub const Clip = struct {
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
            // `s` may be this name itself (a key read back from it).
            std.mem.copyForwards(u8, self.buf[0..self.len], s[0..self.len]);
        }
    };
}

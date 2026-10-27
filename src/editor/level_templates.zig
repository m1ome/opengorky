//! What can be put on a level: the editor's built-in fighter, weapon, obstacle and box
//! files, and the game's levels and enemy templates read from the folder.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const archive = og.formats.archive;
const level = @import("level.zig");
const Template = level.Template;
const templates = @import("level_templates.zig");

// A fighter of a class no battle has, as the battles' own (01__port_park hornets).
pub const built_fighter =
    \\#include Fighter.s
    \\
    \\int initok;
    \\
    \\function init()
    \\{{
    \\#include ft_{s}.ss
    \\}};
    \\
    \\function post_init()
    \\{{
    \\}};
    \\
    \\function update()
    \\{{
    \\}};
    \\
;

pub const built_weapon =
    \\#include Weapon.s
    \\
    \\
    \\function init()
    \\{{
    \\#include {s}
    \\{s}
    \\  Owner="{s}";
    \\  place=10;
    \\}};
    \\
    \\function update()
    \\{{
    \\}};
    \\
    \\function Take(string hero)
    \\{{
    \\  Owner = hero;
    \\  place = 1;
    \\}};
    \\
;

// Scripts of new obstacles, as the battles' own (01__port_park, 01__port_bulldozer2).
pub const obstacle =
    \\#include Fighter.s
    \\
    \\int initok;
    \\
    \\function init()
    \\{{
    \\#include {s}
    \\{s}
    \\}};
    \\
    \\function post_init()
    \\{{
    \\}};
    \\
    \\function update()
    \\{{
    \\}};
    \\
;

pub const barrel_blast =
    \\#include Weapon.s
    \\
    \\
    \\function init()
    \\{{
    \\#include wp_barrel_explode.ss
    \\
    \\    Owner="{s}";
    \\    place=11;
    \\}};
    \\
    \\function update()
    \\{{
    \\}};
    \\
    \\function Take(string hero)
    \\{{
    \\  Owner = hero;
    \\  place = 1;
    \\}};
    \\
;

pub const item_box =
    \\#include Fighter.s
    \\
    \\int initok;
    \\
    \\string itm_1;
    \\int funcID;
    \\int cnt_itm;
    \\
    \\function init()
    \\{{
    \\#include obs_i_itembox.ss
    \\
    \\  itm_1 = "";
    \\  cnt_itm=0;
    \\  funcID =  1;
    \\}};
    \\
    \\function post_init()
    \\{{
    \\  Actor_SetAsyncAnimation(GetName(),"closed",0,0);
    \\}};
    \\
    \\function Open(string hero)
    \\{{
    \\  funcID = 7;
    \\  if (cnt_itm==0) funcID = 2;
    \\  Actor_SetAsyncAnimation(GetName(),"box",0,0);
    \\}};
    \\
    \\function Close(string hero)
    \\{{
    \\  funcID = 1;
    \\  Actor_SetAsyncAnimation(GetName(),"box",0,1);
    \\}};
    \\
    \\function update()
    \\{{
    \\}};
    \\
;

pub const LevelEntry = struct {
    name: []const u8,
    /// The script inherits CombatLevel.
    battle: bool,
};

/// Levels in `<game>/dat`: folders whose other.dat holds `<name>.lev`, sorted by name.
pub fn listLevels(io: Io, gpa: Allocator, dat: Io.Dir) ![]LevelEntry {
    var list: std.ArrayList(LevelEntry) = .empty;
    errdefer {
        for (list.items) |e| gpa.free(e.name);
        list.deinit(gpa);
    }
    var it = dat.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        var buf: [256]u8 = undefined;
        var ar = archive.Archive.open(io, gpa, dat, std.fmt.bufPrint(&buf, "{s}/other.dat", .{e.name}) catch continue) catch continue;
        defer ar.close(io, gpa);
        const lev = ar.find(std.fmt.bufPrint(&buf, "{s}.lev", .{e.name}) catch continue) orelse continue;
        const text = ar.readAlloc(io, gpa, lev) catch continue;
        defer gpa.free(text);
        try list.append(gpa, .{ .name = try gpa.dupe(u8, e.name), .battle = std.mem.indexOf(u8, text, "CombatLevel") != null });
    }
    std.mem.sort(LevelEntry, list.items, {}, struct {
        fn lt(_: void, a: LevelEntry, b: LevelEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    return list.toOwnedSlice(gpa);
}

/// Templates for adding enemies: the first armed `.ftr` of each fighter class in the
/// battles (else the first), sorted by class.
/// The close attack of a built fighter: a big monster's (cutterpill's, 25).
const built_attack = "wp_cutterpillshort.ss";

/// The weapon nameID the exe's strike branch of a built class wants (its own weapon
/// class is gone from the data): the shoggoth's tail.
pub fn builtWeaponId(class: []const u8) ?i32 {
    return if (std.ascii.eqlIgnoreCase(class, "shogoth")) 1015 else null;
}

pub fn listTemplates(io: Io, gpa: Allocator, dat: Io.Dir, levels: []const LevelEntry) ![]Template {
    var list: std.ArrayList(Template) = .empty;
    errdefer {
        freeTemplates(gpa, list.items);
        list.deinit(gpa);
    }
    for (levels) |lvl| {
        if (!lvl.battle) continue;
        var buf: [256]u8 = undefined;
        var ar = archive.Archive.open(io, gpa, dat, try std.fmt.bufPrint(&buf, "{s}/other.dat", .{lvl.name})) catch continue;
        defer ar.close(io, gpa);
        for (ar.entries) |*e| {
            if (!std.ascii.endsWithIgnoreCase(e.name, ".ftr")) continue;
            const text = ar.readAlloc(io, gpa, e) catch continue;
            defer gpa.free(text);
            const p = std.ascii.findIgnoreCase(text, "#include ft_") orelse continue;
            const s = p + "#include ft_".len;
            const end = std.ascii.findIgnoreCasePos(text, s, ".ss") orelse continue;
            const class = text[s..end];
            const fighter = e.name[0 .. e.name.len - 4];
            const have: ?*Template = for (list.items) |*t| {
                if (std.ascii.eqlIgnoreCase(t.class, class)) break t;
            } else null;
            if (have) |t| if (t.armed) continue;
            const armed = try isArmed(io, gpa, ar, fighter);
            if (have) |t| {
                if (!armed) continue;
                gpa.free(t.level);
                gpa.free(t.fighter);
                t.level = try gpa.dupe(u8, lvl.name);
                t.fighter = try gpa.dupe(u8, fighter);
                t.armed = true;
                continue;
            }
            const t: Template = .{
                .class = try gpa.dupe(u8, class),
                .level = try gpa.dupe(u8, lvl.name),
                .fighter = try gpa.dupe(u8, fighter),
                .armed = armed,
            };
            try list.append(gpa, t);
        }
    }
    // Classes no battle has but able to strike (shogoth): built, with a close attack.
    if (archive.Archive.open(io, gpa, dat, "common/other.dat")) |ar_c| {
        var ar = ar_c;
        defer ar.close(io, gpa);
        for (ar.entries) |*e| {
            if (!std.ascii.startsWithIgnoreCase(e.name, "classes\\ft_") or !std.ascii.endsWithIgnoreCase(e.name, ".ss")) continue;
            const class = e.name["classes\\ft_".len .. e.name.len - 3];
            for (list.items) |t| {
                if (std.ascii.eqlIgnoreCase(t.class, class)) break;
            } else {
                const text = ar.readAlloc(io, gpa, e) catch continue;
                defer gpa.free(text);
                const p = std.ascii.findIgnoreCase(text, "#include act_") orelse continue;
                const s = p + "#include ".len;
                var k = s;
                while (k < text.len and !std.ascii.isWhitespace(text[k])) k += 1;
                var nb: [128]u8 = undefined;
                const act_e = ar.find(std.fmt.bufPrint(&nb, "classes\\{s}", .{text[s..k]}) catch continue) orelse continue;
                const act = ar.readAlloc(io, gpa, act_e) catch continue;
                defer gpa.free(act);
                if (std.ascii.findIgnoreCase(act, "\"short_attack\"") == null) continue;
                try list.append(gpa, .{ .class = try gpa.dupe(u8, class), .level = try gpa.dupe(u8, ""), .fighter = try gpa.dupe(u8, ""), .armed = true, .weapon = built_attack });
            }
        }
    } else |_| {}
    std.mem.sort(Template, list.items, {}, struct {
        fn lt(_: void, a: Template, b: Template) bool {
            return std.mem.order(u8, a.class, b.class) == .lt;
        }
    }.lt);
    return list.toOwnedSlice(gpa);
}

fn isArmed(io: Io, gpa: Allocator, ar: archive.Archive, fighter: []const u8) !bool {
    var buf: [128]u8 = undefined;
    const q = try std.fmt.bufPrint(&buf, "\"{s}\"", .{fighter});
    for (ar.entries) |*e| {
        if (!std.ascii.endsWithIgnoreCase(e.name, ".wpn")) continue;
        const text = ar.readAlloc(io, gpa, e) catch continue;
        defer gpa.free(text);
        if (std.ascii.findIgnoreCase(text, q) != null) return true;
    }
    return false;
}

pub fn freeTemplates(gpa: Allocator, items: []const Template) void {
    for (items) |t| {
        gpa.free(t.class);
        gpa.free(t.level);
        gpa.free(t.fighter);
    }
}

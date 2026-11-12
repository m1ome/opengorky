//! The Info block of every object page (read only): where the object is defined, the
//! files it includes, its name in the game, what it names, who makes it a party hero,
//! where it is used — in this order on every page; each row that names something is a
//! link to its page, level, scene or script line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ui = @import("ui");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const icons = @import("icons.zig");
const refs = @import("refs.zig");
const uses = @import("uses.zig");
const model = @import("model.zig");
const doctabs = @import("doctabs.zig");
const entries = @import("entries.zig");
const common_archive = @import("store.zig").common_archive;
const app_mod = @import("app.zig");
const App = app_mod.App;
const Tab = app_mod.Tab;
const theme = app_mod.theme;

/// The rows' groups, in the order shown.
pub const Group = enum {
    file,
    level,
    includes,
    name_id,
    same_name,
    fields,
    refs,
    party,
    used,

    fn label(g: Group) tx.Msg {
        return switch (g) {
            .file => tx.info_file,
            .level => tx.info_level,
            .includes => tx.info_includes,
            .name_id => tx.info_name_id,
            .same_name => tx.info_same_name,
            .fields => tx.info_fields,
            .refs => tx.info_refs,
            .party => tx.info_party,
            .used => tx.info_used,
        };
    }
};

/// Where a row leads.
pub const Target = union(enum) {
    none,
    /// A level (`obj`: an area or object of it picked).
    level: struct { name: []const u8, obj: ?[]const u8 = null },
    scene: []const u8,
    /// A catalog entry by index (heroes of two levels share an id).
    entry: usize,
    /// A script in the code editor, the cursor at byte `at`.
    code: struct { archive: []const u8, entry: []const u8, at: ?usize = null },
    /// A document as its tab opens it (string.tab, a sound…).
    doc: struct { tab: Tab, name: []const u8 },
};

pub const Row = struct { group: Group, text: []const u8, to: Target = .none, icon: icons.Icon = .file_text };

pub const List = struct {
    a: Allocator,
    rows: std.ArrayList(Row) = .empty,

    pub fn add(self: *List, r: Row) void {
        self.rows.append(self.a, r) catch {};
    }

    pub fn fmt(self: *List, comptime f: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.a, f, args) catch "";
    }

    /// The rows by group (stable: each group keeps the order rows were added in).
    fn sorted(self: *List) []const Row {
        std.sort.insertion(Row, self.rows.items, {}, struct {
            fn lt(_: void, x: Row, y: Row) bool {
                return @backingInt(x.group) < @backingInt(y.group);
            }
        }.lt);
        return self.rows.items;
    }
};

/// `none` as `list`'s "Used by" row when no row came after its first `n` (the count
/// taken before the users were added: a page's own rows above them don't count).
pub fn usedNone(list: *List, n: usize, none: tx.Msg) void {
    if (list.rows.items.len == n) list.add(.{ .group = .used, .text = tx.get(none) });
}

/// The rows built last (scans of every level's scripts: once per page and edit).
var cache: struct { arena: ?std.heap.ArenaAllocator = null, key: u64 = 0, rows: []const Row = &.{} } = .{};

/// The Info rows of page `name`: `build(ctx, app, list)` runs again only when the page,
/// the edits or the language change.
pub fn rows(app: *App, name: []const u8, ctx: anytype, comptime build: fn (@TypeOf(ctx), *App, *List) void) []const Row {
    var h = std.hash.Wyhash.init(app.store.rev);
    h.update(std.mem.asBytes(&app.catalog.gen));
    h.update(name);
    h.update(std.mem.asBytes(&tx.lang));
    const key = h.final();
    if (cache.arena != null and cache.key == key) return cache.rows;
    if (cache.arena) |*ar| _ = ar.reset(.retain_capacity) else cache.arena = .init(app.gpa);
    var list: List = .{ .a = cache.arena.?.allocator() };
    build(ctx, app, &list);
    cache.key = key;
    cache.rows = list.sorted();
    return cache.rows;
}

pub fn deinit() void {
    if (cache.arena) |*ar| ar.deinit();
    cache = .{};
}

/// The rows built last (scripted: `--info N`).
pub fn last() []const Row {
    return cache.rows;
}

/// The rows under a header the page draws: each group's label, its rows (links in the
/// accent colour); `none` when there are none.
pub fn show(app: *App, list: []const Row) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    var prev: ?Group = null;
    for (list, 0..) |r, k| {
        if (prev != r.group) {
            clay.open(.{ .layout = .{ .padding = .{ .top = if (prev == null) 0 else lay.space.sm, .bottom = lay.space.xs } } });
            gui.txt(tx.get(r.group.label()), .caption, theme.dim, font_mod.bold);
            clay.close();
            prev = r.group;
        }
        if (r.to == .none) {
            clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = lay.space.sm } } });
            gui.txtWrap(r.text, .body, theme.text, font_mod.regular);
            clay.close();
            continue;
        }
        if (gui.listRow(app, clay.idi("info_row", @intCast(k)), .{ .h = lay.height.small })) follow(app, r.to);
        gui.icon(app, r.icon, lay.icon.md, theme.dim);
        gui.txt(r.text, .body, theme.accent_hover, font_mod.regular);
        clay.close();
    }
    if (list.len == 0) gui.txt(tx.get(tx.info_none), .body, theme.dim, font_mod.regular);
    clay.close();
}

/// What an Info block's header sums up: its file's archive and the levels in `list`.
pub fn summary(a: Allocator, archive: []const u8, list: []const Row) []const u8 {
    var n: usize = 0;
    for (list) |r| n += @intFromBool(r.to == .level);
    return tx.alloc(a, tx.sum_info, .{ std.fs.path.basename(archive), n });
}

/// Row `t` followed, as the tree and the other links open things.
pub fn follow(app: *App, t: Target) void {
    switch (t) {
        .none => {},
        // An object is centred in the level's view: after a layout (the next frame's start).
        .level => |l| if (l.obj != null) app.link(false, l.name, l.obj) else {
            app.trigger = null;
            app.showLevel(l.name, null);
        },
        .scene => |n| {
            app.trigger = null;
            app.showScene(n);
        },
        .entry => |i| entries.showEntry(app, i),
        .code => |c| {
            const f = app.store.file(c.archive, c.entry) catch |err| return app.setStatus(tx.st_open_failed, .{ c.entry, err });
            // The shown tab kept, unless a code jump opened it (codehist).
            if (!@import("codehist.zig").onJumped(app)) doctabs.keepCurrent(app);
            doctabs.showCode(app, f, c.at);
        },
        .doc => |d| doctabs.show(app, d.tab, d.name),
    }
}

// ---------------------------------------------------------------- shared rows

/// Level of a level archive (`01_port/other.dat` → `01_port`); null for common's.
pub fn levelOf(archive: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, archive, "common/")) return null;
    return archive[0 .. std.mem.indexOfScalar(u8, archive, '/') orelse return null];
}

fn levelIcon(name: []const u8) icons.Icon {
    return if (std.mem.indexOf(u8, name, "__") != null) .swords else .map_pin;
}

/// Where file `entry` of `archive` is: the file (a script opens in the code editor) and,
/// for a level's own, that level.
pub fn defined(list: *List, archive: []const u8, entry: []const u8, script: bool) void {
    list.add(.{ .group = .file, .text = list.fmt("{s} · {s}", .{ archive, entry }), .to = if (script) .{ .code = .{ .archive = archive, .entry = entry } } else .none, .icon = .code });
    if (levelOf(archive)) |lv| list.add(.{ .group = .level, .text = lv, .to = .{ .level = .{ .name = lv } }, .icon = levelIcon(lv) });
}

/// The files `text` (of `archive`) includes and inherits, and theirs (4 deep), each
/// once: found as the engine finds them (its archive, then common's classes\,
/// scriptlets\, gamestart\).
pub fn includes(app: *App, list: *List, archive: []const u8, text: []const u8, depth: u8) void {
    // OpenGorky has no `#include`: a block's archetype and components are on its page.
    if (app.ogLayout()) return;
    if (depth == 0) return;
    for (model.directives(list.a, text)) |n| {
        const found = find(app, list.a, archive, n) orelse {
            list.add(.{ .group = .includes, .text = list.fmt("{s} ({s})", .{ n, tx.get(tx.info_not_found) }) });
            continue;
        };
        const seen = for (list.rows.items) |r| {
            if (r.group == .includes and r.to == .code and std.ascii.eqlIgnoreCase(r.to.code.entry, found.entry)) break true;
        } else false;
        if (seen) continue;
        list.add(.{ .group = .includes, .text = found.entry, .to = .{ .code = .{ .archive = found.archive, .entry = found.entry } }, .icon = .code });
        includes(app, list, found.archive, found.text, depth - 1);
    }
}

fn find(app: *App, a: Allocator, archive: []const u8, name: []const u8) ?struct { archive: []const u8, entry: []const u8, text: []const u8 } {
    if (!std.mem.eql(u8, archive, common_archive)) if (refs.read(app, a, archive, name)) |t| return .{ .archive = archive, .entry = name, .text = t };
    for ([_][]const u8{ "classes\\", "scriptlets\\", "gamestart\\" }) |dir| {
        const entry = std.fmt.allocPrint(a, "{s}{s}", .{ dir, name }) catch continue;
        if (refs.read(app, a, common_archive, entry)) |t| return .{ .archive = common_archive, .entry = entry, .text = t };
    }
    return null;
}

/// classic_id `id`: its string.tab row (a link to the texts).
pub fn classicId(app: *App, list: *List, id: i32) void {
    const name = @import("texts.zig").get(app, list.a, .strings, id) orelse "";
    list.add(.{ .group = .name_id, .text = list.fmt("{d} · {s}", .{ id, if (name.len > 0) name else "—" }), .to = .{ .doc = .{ .tab = .texts, .name = "string.tab" } }, .icon = .file_text });
}

/// Catalog entries but `self` with classic_id `id`.
pub fn sameName(app: *App, list: *List, id: i32, self: usize) void {
    for (app.catalog.entries.items, 0..) |o, i| {
        if (i == self or o.name_id != id) continue;
        list.add(.{ .group = .same_name, .text = entryText(list, o), .to = .{ .entry = i }, .icon = entryIcon(o.kind) });
    }
}

pub fn entryText(list: *List, e: @import("catalog.zig").Entry) []const u8 {
    return if (e.title.len > 0) list.fmt("{s} · {s}", .{ e.title, e.id }) else e.id;
}

fn entryIcon(k: @import("catalog.zig").Kind) icons.Icon {
    return if (k == .enemy or k == .hero) .user else if (k == .attack) .swords else .package;
}

/// Levels whose scripts have `needle` (case aside), each a link.
pub fn levelsNaming(app: *App, list: *List, needle: []const u8) void {
    for (uses.get(app).levelsNaming(list.a, needle)) |lv| list.add(.{ .group = .used, .text = lv, .to = .{ .level = .{ .name = lv } }, .icon = levelIcon(lv) });
}

/// Scenes whose script has `needle` (but `self`), each a link.
pub fn scenesNaming(app: *App, list: *List, needle: []const u8, self: []const u8) void {
    for (uses.naming(list.a, uses.get(app).scenes, needle)) |entry| {
        const sc = entry["scriptlets\\".len .. entry.len - 4];
        if (std.ascii.eqlIgnoreCase(sc, self)) continue;
        list.add(.{ .group = .used, .text = sc, .to = .{ .scene = sc }, .icon = .clapperboard });
    }
}

/// Every script making object `id` a party hero (SETHERO / HERO_EnableEnumerate with
/// 1): the scenes' and the levels', each a link to the call.
pub fn joins(app: *App, list: *List, id: []const u8) void {
    const ix = uses.get(app);
    joinsIn(list, common_archive, ix.scenes, id);
    for (ix.levels) |lv| joinsIn(list, lv.archive, lv.files, id);
}

fn joinsIn(list: *List, archive: []const u8, files: []const refs.File, id: []const u8) void {
    for (files) |f| {
        for (model.joins(list.a, f.text) catch continue) |n| {
            if (!std.ascii.eqlIgnoreCase(n, id)) continue;
            const where = if (levelOf(archive)) |lv| list.fmt("{s} · {s}", .{ lv, f.name }) else f.name;
            list.add(.{ .group = .party, .text = where, .to = .{ .code = .{ .archive = list.fmt("{s}", .{archive}), .entry = list.fmt("{s}", .{f.name}), .at = @intFromPtr(n.ptr) - @intFromPtr(f.text.ptr) } }, .icon = .code });
        }
    }
}

//! The game's texts in common/lang.dat, as rows by number: `string.tab` (`id=text`
//! under `//===` section headers: names by `nameID`, interface words), `items.inf`
//! (`ITEM_EXAMINE: id` and the indented description, examining an item) and
//! `activeareas.inf` (`AREA_EXAMINE: id`, examining an area). A row edited keeps the
//! file's layout (one line changed, Windows lines, the game's code page); a new row goes
//! at the end (string.tab: under an `EDITOR` section). The exe sizes its string table by
//! the largest number (0x40f5ce), so any free number works; a line is at most 900 bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const code = @import("code.zig");
const main = @import("app.zig");
const App = main.App;

pub const archive = "common/lang.dat";

pub const File = enum {
    strings,
    items,
    areas,

    pub fn entry(self: File) []const u8 {
        return switch (self) {
            .strings => "string.tab",
            .items => "items.inf",
            .areas => "activeareas.inf",
        };
    }

    fn key(self: File) []const u8 {
        return switch (self) {
            .strings => "",
            .items => "ITEM_EXAMINE:",
            .areas => "AREA_EXAMINE:",
        };
    }
};

/// A row: its number, text (UTF-8), the section or comment above it, and where its text
/// is in the file (the value's bytes; `.inf`: from the key line to the block's end).
pub const Row = struct { id: i32, text: []const u8, section: []const u8, start: usize, end: usize };

/// The longest line the exe reads.
const max_line = 900;

pub fn fileOf(app: *App, f: File) ?usize {
    return app.store.file(archive, f.entry()) catch null;
}

/// The rows of `f` as the Store has it now (texts in `a`).
pub fn rows(app: *App, a: Allocator, f: File) []const Row {
    const fi = fileOf(app, f) orelse return &.{};
    return parse(a, app.store.text(fi), f, app.catalog.cyrillic) catch &.{};
}

fn parse(a: Allocator, t: []const u8, f: File, cyrillic: bool) ![]const Row {
    var out: std.ArrayList(Row) = .empty;
    var section: []const u8 = "";
    var pos: usize = 0;
    while (pos < t.len) {
        const le = std.mem.indexOfScalarPos(u8, t, pos, '\n') orelse t.len;
        const line = std.mem.trimEnd(u8, t[pos..le], "\r");
        const next = @min(le + 1, t.len);
        if (f == .strings) {
            if (std.mem.startsWith(u8, line, "//")) {
                section = try code.fromGame(a, std.mem.trim(u8, line[2..], " =/"), cyrillic);
            } else if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                if (std.fmt.parseInt(i32, std.mem.trim(u8, line[0..eq], " \t"), 10)) |id| {
                    try out.append(a, .{ .id = id, .text = try code.fromGame(a, line[eq + 1 ..], cyrillic), .section = section, .start = pos + eq + 1, .end = pos + line.len });
                } else |_| {}
            }
            pos = next;
            continue;
        }
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "#")) section = try code.fromGame(a, std.mem.trim(u8, line, " \t#"), cyrillic);
        if (std.mem.startsWith(u8, line, f.key())) {
            const id = std.fmt.parseInt(i32, std.mem.trim(u8, line[f.key().len..], " \t"), 10) catch -1;
            // The description: the indented lines up to an empty line, a comment or a key.
            var text: std.ArrayList(u8) = .empty;
            var p = next;
            while (p < t.len) {
                const e = std.mem.indexOfScalarPos(u8, t, p, '\n') orelse t.len;
                const l = std.mem.trim(u8, t[p..e], " \t\r");
                if (l.len == 0 or l[0] == '#' or std.mem.startsWith(u8, l, f.key())) break;
                if (text.items.len > 0) try text.append(a, ' ');
                try text.appendSlice(a, l);
                p = @min(e + 1, t.len);
            }
            if (id >= 0) try out.append(a, .{ .id = id, .text = try code.fromGame(a, text.items, cyrillic), .section = section, .start = pos, .end = p });
            pos = p;
            continue;
        }
        pos = next;
    }
    return out.items;
}

/// The text of number `id` in `f` (null: none).
pub fn get(app: *App, a: Allocator, f: File, id: i32) ?[]const u8 {
    for (rows(app, a, f)) |r| if (r.id == id) return r.text;
    return null;
}

/// Number `id` of `f` says `text` (UTF-8): its row changed, or a new row; one undo step.
pub fn set(app: *App, f: File, id: i32, text: []const u8) !void {
    const fi = fileOf(app, f) orelse return error.NoFile;
    const a = app.frame.allocator();
    const game = try code.toGame(a, std.mem.trim(u8, text, " \t\r\n"), app.catalog.cyrillic);
    if (game.len > max_line - 16) return error.TooLong;
    const t = app.store.text(fi);
    const rs = try parse(a, t, f, app.catalog.cyrillic);
    const row: ?Row = for (rs) |r| {
        if (r.id == id) break r;
    } else null;
    const piece = if (f == .strings) game else try std.fmt.allocPrint(a, "{s} {d}\r\n  {s}\r\n", .{ f.key(), id, game });
    const new = if (row) |r|
        try std.mem.concat(app.gpa, u8, &.{ t[0..r.start], piece, t[r.end..] })
    else
        try appended(app.gpa, t, f, id, game);
    errdefer app.gpa.free(new);
    var lb: [96]u8 = undefined;
    try app.store.replaceLabeled(fi, new, std.fmt.bufPrint(&lb, "{s} {d}", .{ f.entry(), id }) catch f.entry());
}

/// `t` with a new row for `id` at its end (string.tab: in the editor's section).
fn appended(gpa: Allocator, t: []const u8, f: File, id: i32, game: []const u8) ![]u8 {
    const nl = if (t.len == 0 or std.mem.endsWith(u8, t, "\n")) "" else "\r\n";
    var ib: [16]u8 = undefined;
    const ids = std.fmt.bufPrint(&ib, "{d}", .{id}) catch "";
    if (f != .strings) return std.mem.concat(gpa, u8, &.{ t, nl, "\r\n", f.key(), " ", ids, "\r\n  ", game, "\r\n" });
    const head = if (std.mem.indexOf(u8, t, editor_section) == null) "\r\n//" ++ editor_section ++ "\r\n" else "";
    return std.mem.concat(gpa, u8, &.{ t, nl, head, ids, "=", game, "\r\n" });
}

const editor_section = "=========== EDITOR ===========";

/// A number no row of `f` has, from `from` on (new names: past the game's largest, 1081).
pub fn freeId(app: *App, f: File, from: i32) i32 {
    var id = from;
    const rs = rows(app, app.frame.allocator(), f);
    while (for (rs) |r| {
        if (r.id == id) break true;
    } else false) id += 1;
    return id;
}

/// Row `id` of `f` taken out (one undo step).
pub fn remove(app: *App, f: File, id: i32) !void {
    const fi = fileOf(app, f) orelse return error.NoFile;
    const a = app.frame.allocator();
    const t = app.store.text(fi);
    const rs = try parse(a, t, f, app.catalog.cyrillic);
    const r = for (rs) |r| {
        if (r.id == id) break r;
    } else return error.NotFound;
    // The whole line (string.tab) or the key line and its description.
    var s0 = if (f == .strings) code.lineStart(t, r.start) else r.start;
    var e = r.end;
    if (f == .strings) e = @min(t.len, (std.mem.indexOfScalarPos(u8, t, r.end, '\n') orelse t.len - 1) + 1);
    if (f != .strings and s0 > 0) {
        // Its `# comment` line just above goes with it.
        const ps = code.lineStart(t, s0 - 1);
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, t[ps..s0], " \t"), "#")) s0 = ps;
    }
    const new = try std.mem.concat(app.gpa, u8, &.{ t[0..s0], t[e..] });
    var lb: [96]u8 = undefined;
    try app.store.replaceLabeled(fi, new, std.fmt.bufPrint(&lb, "- {s} {d}", .{ f.entry(), id }) catch f.entry());
}

test parse {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const s = "//=== HEROES ===\r\n1=Sullivan\r\n2=Ovitz\r\n";
    const rs = try parse(arena.allocator(), s, .strings, false);
    try std.testing.expectEqual(2, rs.len);
    try std.testing.expectEqualStrings("Ovitz", rs[1].text);
    try std.testing.expectEqualStrings("HEROES", rs[1].section);
    try std.testing.expectEqualStrings("Ovitz", s[rs[1].start..rs[1].end]);
    const inf = "# Box\r\nITEM_EXAMINE: 75\r\n  Small\r\n  box.\r\n\r\n# Pistol\r\nITEM_EXAMINE: 49\r\n  Gun.\r\n";
    const ri = try parse(arena.allocator(), inf, .items, false);
    try std.testing.expectEqual(2, ri.len);
    try std.testing.expectEqualStrings("Small box.", ri[0].text);
    try std.testing.expectEqualStrings("Box", ri[0].section);
    try std.testing.expectEqual(@as(i32, 49), ri[1].id);
}

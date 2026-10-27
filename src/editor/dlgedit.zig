//! A dialogue's lines edited in place (formats/dialog.zig's layout): a line's text or
//! speaker, a line added after another, deleted, moved up or down. The file keeps its
//! notes (`#`), Windows lines and code page. A line's voice file is named by its number
//! (`<dialogue>_<code>_<nn>.wav`), so lines that change number take their recordings
//! along (the files renamed), and each line keeps the voice it had.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const code = @import("code.zig");
const voices = @import("voices.zig");
const main = @import("app.zig");
const App = main.App;
const tx = @import("text.zig");
const store_mod = @import("store.zig");

/// A line in the file: its speaker header (`Speaker:` line; null for a `-` line, the
/// speaker above), where its block starts (header or `-`) and ends (after its text).
const Block = struct { header: ?[]const u8, start: usize, text_start: usize, end: usize };

/// The blocks of `t` (game bytes), in order — the dialogue's lines.
fn blocks(a: Allocator, t: []const u8) ![]Block {
    var out: std.ArrayList(Block) = .empty;
    var pos: usize = 0;
    var cur: ?Block = null;
    while (pos < t.len) {
        const le = std.mem.indexOfScalarPos(u8, t, pos, '\n') orelse t.len;
        const next = @min(le + 1, t.len);
        const raw = std.mem.trimEnd(u8, t[pos..le], "\r");
        const trimmed = std.mem.trim(u8, raw, " \t");
        const indented = raw.len > 0 and (raw[0] == ' ' or raw[0] == '\t');
        if (trimmed.len == 0 or trimmed[0] == '#' or std.mem.startsWith(u8, trimmed, "DIALOG ")) {
            pos = next;
            continue;
        }
        if (!indented and trimmed[trimmed.len - 1] == ':') {
            if (cur) |c| try out.append(a, c);
            cur = .{ .header = trimmed[0 .. trimmed.len - 1], .start = pos, .text_start = next, .end = next };
        } else if (std.mem.eql(u8, trimmed, "-")) {
            if (cur) |c| try out.append(a, c);
            cur = .{ .header = null, .start = pos, .text_start = next, .end = next };
        } else if (cur) |*c| c.end = next;
        pos = next;
    }
    if (cur) |c| try out.append(a, c);
    return out.items;
}

pub const Op = union(enum) {
    text: []const u8,
    speaker: []const u8,
    /// A new line after this one (the speaker's, "..." said).
    add_after,
    delete,
    up,
    down,
};

/// Op `op` on line `k` of dialogue file `f` (`name`: its entry, for the voices).
pub fn apply(app: *App, f: usize, name: []const u8, k: usize, op: Op) !void {
    const a = app.frame.allocator();
    const t = app.store.text(f);
    const bs = try blocks(a, t);
    if (k >= bs.len) return error.NoLine;
    const b = bs[k];
    const cyr = app.catalog.cyrillic;
    const nl = "\r\n";
    const speaker_of = struct {
        fn of(list: []const Block, i: usize) []const u8 {
            var j = i + 1;
            while (j > 0) : (j -= 1) if (list[j - 1].header) |h| return h;
            return "Sullivan";
        }
    }.of;
    // Which old line each new line is (voices follow it); null — a new one.
    var from: std.ArrayList(?usize) = .empty;
    for (0..bs.len) |i| try from.append(a, i);
    var new: []u8 = undefined;
    switch (op) {
        .text => |s| {
            const g = try code.toGame(a, std.mem.trim(u8, s, " \t\r\n"), cyr);
            new = try std.mem.concat(app.gpa, u8, &.{ t[0..b.text_start], "  ", g, nl, t[b.end..] });
        },
        .speaker => |s| {
            const g = try code.toGame(a, std.mem.trim(u8, s, " \t\r\n:"), cyr);
            if (g.len == 0) return error.NoSpeaker;
            // A `-` line becomes a line of its own speaker; a header is renamed.
            new = try std.mem.concat(app.gpa, u8, &.{ t[0..b.start], g, ":", nl, t[b.text_start..] });
        },
        .add_after => {
            const sp = speaker_of(bs, k);
            new = try std.mem.concat(app.gpa, u8, &.{ t[0..b.end], sp, ":", nl, "  ...", nl, t[b.end..] });
            try from.insert(a, k + 1, null);
        },
        .delete => {
            // The next line of the same speaker (`-`) gets the header this one had.
            const keep_head = b.header != null and k + 1 < bs.len and bs[k + 1].header == null;
            if (keep_head) {
                const nb = bs[k + 1];
                new = try std.mem.concat(app.gpa, u8, &.{ t[0..b.start], b.header.?, ":", nl, t[nb.text_start..] });
            } else new = try std.mem.concat(app.gpa, u8, &.{ t[0..b.start], t[b.end..] });
            _ = from.orderedRemove(k);
        },
        .up, .down => {
            const i = if (op == .up) k -| 1 else k;
            if (op == .up and k == 0) return;
            if (i + 1 >= bs.len) return;
            const x = bs[i];
            const y = bs[i + 1];
            // Both as lines with their own speaker header (a `-` would change speaker).
            const xs = try std.fmt.allocPrint(a, "{s}:{s}{s}", .{ speaker_of(bs, i), nl, t[x.text_start..x.end] });
            const ys = try std.fmt.allocPrint(a, "{s}:{s}{s}", .{ speaker_of(bs, i + 1), nl, t[y.text_start..y.end] });
            new = try std.mem.concat(app.gpa, u8, &.{ t[0..x.start], ys, t[x.end..y.start], xs, t[y.end..] });
            from.items[i] = i + 1;
            from.items[i + 1] = i;
        },
    }
    errdefer app.gpa.free(new);
    // The voices before and after (names by number and speaker code).
    const old_names = try voiceNames(a, t, name, cyr);
    try app.store.replaceLabeled(f, new, std.fmt.bufPrint(try a.alloc(u8, 96), "{s}: {s} {d}", .{ name, @tagName(op), k }) catch name);
    const new_names = try voiceNames(a, app.store.text(f), name, cyr);
    try moveVoices(app, a, old_names, new_names, from.items);
    if (op != .text and op != .speaker) try renumberScenes(app, a, name, from.items, bs.len);
}

/// Scenes showing this dialogue (`DIALOG_INIT(…, "name")`) by number: each
/// `DIALOG_DISPLAY(n)` / `DIALOG_SHOW(n)` after it to the line's new number.
fn renumberScenes(app: *App, a: Allocator, name: []const u8, from: []const ?usize, old_len: usize) !void {
    // Old number → new.
    const to = try a.alloc(?usize, old_len);
    @memset(to, null);
    for (from, 0..) |src, i| if (src) |o| if (o < old_len) {
        to[o] = i;
    };
    var lost: usize = 0;
    // Only scenes naming the file are read into the Store.
    for (@import("refs.zig").naming(app, a, store_mod.common_archive, @import("refs.zig").scene, name)) |entry| {
        const fi = app.store.file(store_mod.common_archive, entry) catch continue;
        const t = app.store.text(fi);
        var out: std.ArrayList(u8) = .empty;
        var cur_is = false;
        var pos: usize = 0;
        var changed = false;
        while (pos < t.len) {
            const le = std.mem.indexOfScalarPos(u8, t, pos, '\n') orelse t.len;
            const line = t[pos..@min(le + 1, t.len)];
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.ascii.startsWithIgnoreCase(trimmed, "DIALOG_INIT(")) cur_is = std.ascii.findIgnoreCase(trimmed, name) != null;
            const cmd: ?[]const u8 = if (std.ascii.startsWithIgnoreCase(trimmed, "DIALOG_DISPLAY(")) "DIALOG_DISPLAY(" else if (std.ascii.startsWithIgnoreCase(trimmed, "DIALOG_SHOW(")) "DIALOG_SHOW(" else null;
            if (cur_is) if (cmd) |c| {
                const ns = (line.len - trimmed.len) + c.len;
                var ne = ns;
                while (ne < line.len and std.ascii.isDigit(line[ne])) ne += 1;
                const n = std.fmt.parseInt(usize, line[ns..ne], 10) catch std.math.maxInt(usize);
                if (n < to.len) {
                    if (to[n]) |nn| {
                        if (nn != n) {
                            try out.appendSlice(a, line[0..ns]);
                            try out.print(a, "{d}", .{nn});
                            try out.appendSlice(a, line[ne..]);
                            changed = true;
                            pos = @min(le + 1, t.len);
                            continue;
                        }
                    } else lost += 1;
                }
            };
            try out.appendSlice(a, line);
            pos = @min(le + 1, t.len);
        }
        if (changed) try app.store.replaceLabeled(fi, try app.gpa.dupe(u8, out.items), entry);
    }
    if (lost > 0) app.setStatus(tx.st_dlg_lost, .{ name, lost });
}

fn voiceNames(a: Allocator, t: []const u8, name: []const u8, cyr: bool) ![]const []const u8 {
    const utf8 = try code.fromGame(a, t, cyr);
    const dlg = try og.formats.dialog.parse(a, utf8);
    var out: std.ArrayList([]const u8) = .empty;
    for (dlg.lines, 0..) |ln, n| {
        var vb: [96]u8 = undefined;
        try out.append(a, try a.dupe(u8, og.formats.dialog.voiceName(&vb, name, ln.code, n) catch ""));
    }
    return out.items;
}

/// Each line's recording to its new name: all read first, the old names taken out,
/// then the new ones written (no file overwritten before it is read).
fn moveVoices(app: *App, a: Allocator, old: []const []const u8, new: []const []const u8, from: []const ?usize) !void {
    const Move = struct { to: []const u8, bytes: []const u8 };
    var moves: std.ArrayList(Move) = .empty;
    var gone: std.ArrayList([]const u8) = .empty;
    for (new, 0..) |to, i| {
        const src = if (i < from.len) from[i] orelse continue else continue;
        if (src >= old.len or std.ascii.eqlIgnoreCase(old[src], to)) continue;
        const bytes = voices.bytesOf(app, a, old[src]) orelse continue;
        try moves.append(a, .{ .to = to, .bytes = try a.dupe(u8, bytes) });
        try gone.append(a, old[src]);
    }
    if (moves.items.len == 0) return;
    // An old name no recording moves into is removed (a new line there starts silent).
    for (gone.items) |g| {
        const filled = for (moves.items) |m| {
            if (std.ascii.eqlIgnoreCase(m.to, g)) break true;
        } else false;
        if (!filled and voices.has(app, g)) voices.remove(app, g) catch {};
    }
    for (moves.items) |m| try voices.put(app, m.to, try app.gpa.dupe(u8, m.bytes));
    app.setStatus(tx.st_voices_moved, .{moves.items.len});
}

test blocks {
    const t = "#x\r\nDIALOG D\r\nOvitz:\r\n  Hi\r\n  -\r\n  Wah\r\nSullivan:\r\n  Go\r\n";
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const bs = try blocks(arena.allocator(), t);
    try std.testing.expectEqual(3, bs.len);
    try std.testing.expectEqualStrings("Ovitz", bs[0].header.?);
    try std.testing.expect(bs[1].header == null);
    try std.testing.expectEqualStrings("  Wah\r\n", t[bs[1].text_start..bs[1].end]);
    try std.testing.expectEqualStrings("Sullivan", bs[2].header.?);
}

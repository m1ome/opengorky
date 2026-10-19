//! Dialogues `.dlg` (`dat/common/lang.dat`).
//!
//! `DIALOG name`, `#` lines are developer notes; a line is `Speaker:` followed by
//! indented text lines; a `-` line starts a new line of the same speaker (own voice
//! file and number).
//! Voice of line n: `voice.dat: <file name without .dlg, '-' → '_'>_<code>_<nn>.wav`;
//! the speaker code comes from the exe table (0x4594a0), an unknown one reuses the previous code.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Line = struct {
    speaker: []const u8,
    /// Speaker code for the voice file name (`su`, `ta`, `ln`…).
    code: [2]u8 = .{ 'x', 'x' },
    /// Text; the line's rows joined with spaces (in the arena).
    text: []const u8,
};

pub const Dialog = struct {
    name: []const u8,
    lines: []Line,
};

pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!Dialog {
    var dlg: Dialog = .{ .name = "", .lines = &.{} };
    var lines: std.ArrayList(Line) = .empty;
    var cur: ?struct { speaker: []const u8, text: std.ArrayList(u8) } = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.mem.startsWith(u8, trimmed, "DIALOG ")) {
            dlg.name = std.mem.trim(u8, trimmed["DIALOG ".len..], " ");
            continue;
        }
        const indented = raw.len > 0 and (raw[0] == ' ' or raw[0] == '\t');
        if (!indented and trimmed[trimmed.len - 1] == ':') {
            if (cur) |*c| try lines.append(arena, .{ .speaker = c.speaker, .text = c.text.items });
            cur = .{ .speaker = trimmed[0 .. trimmed.len - 1], .text = .empty };
            continue;
        }
        // "-" ends the line; a new one of the same speaker follows.
        if (std.mem.eql(u8, trimmed, "-")) {
            if (cur) |*c| {
                try lines.append(arena, .{ .speaker = c.speaker, .text = c.text.items });
                c.text = .empty;
            }
            continue;
        }
        if (cur) |*c| {
            if (c.text.items.len > 0) try c.text.append(arena, ' ');
            try c.text.appendSlice(arena, trimmed);
        }
    }
    if (cur) |*c| try lines.append(arena, .{ .speaker = c.speaker, .text = c.text.items });
    // Unknown speaker reuses the previous code (a static buffer in the exe).
    var prev: [2]u8 = .{ 'x', 'x' };
    for (lines.items) |*l| {
        if (speakerCode(l.speaker)) |cd| prev = cd;
        l.code = prev;
    }
    dlg.lines = lines.items;
    return dlg;
}

/// Speaker code (0x4594a0, case-insensitive).
fn speakerCode(speaker: []const u8) ?[2]u8 {
    const table = [_]struct { []const u8, *const [2]u8 }{
        .{ "Sullivan", "su" },  .{ "Ovitz", "ov" },    .{ "Trantigne", "tr" }, .{ "Bt", "bt" },
        .{ "MacFadden", "ma" }, .{ "Hutchens", "hu" }, .{ "Medusa", "me" },    .{ "Slavsky", "sl" },
        .{ "Thief_A", "ta" },   .{ "Thief_B", "tb" },  .{ "Lamar", "la" },     .{ "Nato1", "na" },
        .{ "Kozov", "ko" },     .{ "HQ", "hq" },       .{ "l_Nato1", "ln" },
    };
    for (table) |e| if (std.ascii.eqlIgnoreCase(e[0], speaker)) return e[1].*;
    return null;
}

/// Voice file name of line `index` in `voice.dat`.
pub fn voiceName(buf: []u8, dlg_file: []const u8, code: [2]u8, index: usize) ![]const u8 {
    const stem = if (std.ascii.endsWithIgnoreCase(dlg_file, ".dlg")) dlg_file[0 .. dlg_file.len - 4] else dlg_file;
    var s: [64]u8 = undefined;
    if (stem.len > s.len) return error.NameTooLong;
    for (stem, 0..) |ch, i| s[i] = if (ch == '-') '_' else std.ascii.toLower(ch);
    return std.fmt.bufPrint(buf, "{s}_{s}_{d:0>2}.wav", .{ s[0..stem.len], &code, index });
}

test parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const d = try parse(arena.allocator(),
        \\DIALOG Arriving_at_the_port
        \\
        \\#comment
        \\Ovitz:
        \\  So, boss, NOW can you
        \\  tell us why we're here?
        \\
        \\Sullivan:
        \\  Has anyone here heard about Gorky-17?
        \\  -
        \\  Anyone?
        \\Thief_A:
        \\  Hm.
        \\Stranger:
        \\  ...
    );
    try std.testing.expectEqualStrings("Arriving_at_the_port", d.name);
    try std.testing.expectEqual(5, d.lines.len);
    try std.testing.expectEqualStrings("Anyone?", d.lines[2].text);
    try std.testing.expectEqualStrings("ta", &d.lines[3].code);
    try std.testing.expectEqualStrings("ta", &d.lines[4].code);
    try std.testing.expectEqualStrings("So, boss, NOW can you tell us why we're here?", d.lines[0].text);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("port_arriving_su_01.wav", try voiceName(&buf, "port-arriving.dlg", d.lines[1].code, 1));
}

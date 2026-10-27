//! Dialogues `.dlg` (`dat/common/lang.dat`).
//!
//! `DIALOG name`, `#` lines are developer notes; a line is `Speaker:` followed by
//! indented text lines; a `-` line starts a new line of the same speaker (own voice
//! file and number). `#CAM x,y` gives the line being read a camera scroll (0x458d37).
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
    /// `#CAM x,y`: the camera scroll while it shows in a level's own dialogue (entry
    /// +0, +4; -1 none, 0x459196).
    cam: ?[2]i32 = null,
};

pub const Dialog = struct {
    name: []const u8,
    lines: []Line,
    /// Lines after this one take the next voice number (the cut line's, 0x45981b).
    voice_shift: ?usize = null,

    /// Voice file number of line `i`.
    pub fn voiceIndex(self: Dialog, i: usize) usize {
        return if (self.voice_shift) |k| (if (i > k) i + 1 else i) else i;
    }
};

pub fn parse(arena: Allocator, text: []const u8) Allocator.Error!Dialog {
    return parseCut(arena, text, null);
}

/// The German edition (language 3, `string.tab` 950) cuts the line after line 7 of
/// `port_meet_bt.dlg` (0x458cd2…0x458d17, 0x45981b).
pub fn editionCut(file: []const u8, language: u8) ?usize {
    return if (language == 3 and std.ascii.eqlIgnoreCase(file, "port_meet_bt.dlg")) 7 else null;
}

/// `cut`: a `-` ending line `cut` starts no line; the file line after it is skipped
/// and the rows up to the next speaker or `-` are dropped (0x458cf9: ebx = -1).
pub fn parseCut(arena: Allocator, text: []const u8, cut: ?usize) Allocator.Error!Dialog {
    var dlg: Dialog = .{ .name = "", .lines = &.{}, .voice_shift = cut };
    var lines: std.ArrayList(Line) = .empty;
    var cur: ?struct { speaker: []const u8, text: std.ArrayList(u8), cam: ?[2]i32 = null, dropped: bool = false } = null;
    var skip_next = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        if (skip_next) {
            skip_next = false;
            continue;
        }
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        // `#CAM %d,%d` (strncmp 4, sscanf) sets the current line's camera.
        if (std.mem.startsWith(u8, raw, "#CAM")) if (cur) |*c| if (!c.dropped) {
            var xy = std.mem.splitScalar(u8, std.mem.trim(u8, trimmed[4..], " \t"), ',');
            const x = std.fmt.parseInt(i32, std.mem.trim(u8, xy.next() orelse "", " "), 10) catch continue;
            const y = std.fmt.parseInt(i32, std.mem.trim(u8, xy.next() orelse "", " "), 10) catch continue;
            c.cam = .{ x, y };
        };
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.mem.startsWith(u8, trimmed, "DIALOG ")) {
            dlg.name = std.mem.trim(u8, trimmed["DIALOG ".len..], " ");
            continue;
        }
        const indented = raw.len > 0 and (raw[0] == ' ' or raw[0] == '\t');
        if (!indented and trimmed[trimmed.len - 1] == ':') {
            if (cur) |*c| if (!c.dropped) try lines.append(arena, .{ .speaker = c.speaker, .text = c.text.items, .cam = c.cam });
            cur = .{ .speaker = trimmed[0 .. trimmed.len - 1], .text = .empty };
            continue;
        }
        // "-" ends the line; a new one of the same speaker follows.
        if (std.mem.eql(u8, trimmed, "-")) {
            if (cur) |*c| {
                const was_dropped = c.dropped;
                if (!was_dropped) try lines.append(arena, .{ .speaker = c.speaker, .text = c.text.items, .cam = c.cam });
                c.text = .empty;
                c.cam = null;
                c.dropped = !was_dropped and cut != null and lines.items.len - 1 == cut.?;
                skip_next = c.dropped;
            }
            continue;
        }
        if (cur) |*c| if (!c.dropped) {
            if (c.text.items.len > 0) try c.text.append(arena, ' ');
            try c.text.appendSlice(arena, trimmed);
        };
    }
    if (cur) |*c| if (!c.dropped) try lines.append(arena, .{ .speaker = c.speaker, .text = c.text.items, .cam = c.cam });
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
        \\#CAM 0,100
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
    try std.testing.expectEqual([2]i32{ 0, 100 }, d.lines[0].cam.?);
    try std.testing.expect(d.lines[1].cam == null);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("port_arriving_su_01.wav", try voiceName(&buf, "port-arriving.dlg", d.lines[1].code, 1));
}

test "German edition: the line after port_meet_bt line 7 is cut, later voices shift (0x458cd2)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var src: std.ArrayList(u8) = .empty;
    for (0..7) |_| try src.appendSlice(arena.allocator(), "Bt:\n  x\n");
    try src.appendSlice(arena.allocator(), "Bt:\n  seven\n  -\n  cut row one\n  cut row two\n#CAM 1,2\nOvitz:\n  nine\n");
    const cut = editionCut("PORT_MEET_BT.dlg", 3);
    try std.testing.expectEqual(@as(?usize, 7), cut);
    try std.testing.expect(editionCut("port_meet_bt.dlg", 0) == null);
    const d = try parseCut(arena.allocator(), src.items, cut);
    try std.testing.expectEqual(9, d.lines.len);
    try std.testing.expectEqualStrings("seven", d.lines[7].text);
    try std.testing.expectEqualStrings("nine", d.lines[8].text);
    try std.testing.expect(d.lines[8].cam == null);
    try std.testing.expectEqual(7, d.voiceIndex(7));
    try std.testing.expectEqual(9, d.voiceIndex(8));
    // Without the cut the "-" starts line 8.
    try std.testing.expectEqual(10, (try parse(arena.allocator(), src.items)).lines.len);
}

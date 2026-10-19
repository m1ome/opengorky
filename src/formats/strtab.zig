//! UI texts from `common/lang.dat`:
//! - `string.tab`: `number=text` lines (hero and item names by `nameID`, battle
//! labels: 516 "Counter attack", 524 "Level up", 578 "exp"), `//` comments;
//! - `items.inf`: item descriptions, `ITEM_EXAMINE: number` then indented text lines
//! up to an empty line; `#` comments.

const std = @import("std");
const text_mod = @import("text.zig");
const Allocator = std.mem.Allocator;

pub const Table = struct {
    map: std.AutoHashMapUnmanaged(i32, []const u8) = .empty,

    pub fn deinit(self: *Table, gpa: Allocator) void {
        self.map.deinit(gpa);
    }

    pub fn get(self: Table, id: i32) ?[]const u8 {
        return self.map.get(id);
    }
};

/// Edition language number (0x45a1d0): line 950 of `string.tab`, leading digits
/// (like atoi). 0 and 1 are the base letter set; the English edition is 0, the Russian
/// ("Горький-18") is 5: cp1251 Cyrillic lives in the `_5_cz` sets.
pub fn language(t: Table) u8 {
    const s = t.get(950) orelse return 0;
    var n: u32 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') break;
        n = n * 10 + (ch - '0');
        if (n > 255) return 0;
    }
    return @intCast(n);
}

/// Letter set suffix of language N (0x47a2d0): font files `<name>_N<suffix>`.
pub fn langSuffix(n: u8) ?[]const u8 {
    const names = [_][]const u8{ "_pl", "_de", "_fr", "_cz", "_nl", "_sp", "_it", "_hu" };
    return if (n >= 2 and n <= 9) names[n - 2] else null;
}

test language {
    var t = try parseStrings(std.testing.allocator, "950=5\r\n1=x\n");
    defer t.deinit(std.testing.allocator);
    try std.testing.expectEqual(5, language(t));
    try std.testing.expectEqualStrings("_cz", langSuffix(5).?);
    try std.testing.expectEqual(null, langSuffix(1));
}

/// `string.tab`; strings point into `text`.
pub fn parseStrings(gpa: Allocator, text: []const u8) !Table {
    var t: Table = .{};
    errdefer t.deinit(gpa);
    var lines: text_mod.Lines = .init(text);
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "//")) continue;
        const kv = text_mod.keyValue(line) orelse continue;
        try t.map.put(gpa, std.fmt.parseInt(i32, kv.key, 10) catch continue, kv.value);
    }
    return t;
}

/// `items.inf`; multi-line descriptions joined with spaces in `arena`.
pub fn parseExamine(gpa: Allocator, arena: Allocator, text: []const u8) !Table {
    return parseExamineKey(gpa, arena, text, "ITEM_EXAMINE:");
}

/// Same for `activeareas.inf` (`AREA_EXAMINE: id`).
pub fn parseExamineKey(gpa: Allocator, arena: Allocator, text: []const u8, key: []const u8) !Table {
    var t: Table = .{};
    errdefer t.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    var cur: ?i32 = null;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    while (true) {
        const raw = it.next();
        const line = if (raw) |r| std.mem.trim(u8, r, " \t\r") else "";
        const end = raw == null or line.len == 0 or std.mem.startsWith(u8, line, "#") or std.mem.startsWith(u8, line, key);
        if (end) if (cur) |id| {
            try t.map.put(gpa, id, try arena.dupe(u8, buf.items));
            cur = null;
            buf.clearRetainingCapacity();
        };
        if (raw == null) break;
        if (std.mem.startsWith(u8, line, key)) {
            cur = std.fmt.parseInt(i32, std.mem.trim(u8, line[key.len..], " \t"), 10) catch null;
            continue;
        }
        if (cur != null and !end) {
            if (buf.items.len > 0) try buf.append(gpa, ' ');
            try buf.appendSlice(gpa, line);
        }
    }
    return t;
}

test parseStrings {
    var t = try parseStrings(std.testing.allocator, "// x\r\n0=Not Defined\r\n49=Pistol\r\n\r\n516=Counter attack\r\n");
    defer t.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Pistol", t.get(49).?);
    try std.testing.expectEqualStrings("Counter attack", t.get(516).?);
}

test parseExamine {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var t = try parseExamine(std.testing.allocator, arena.allocator(), "# Box\r\nITEM_EXAMINE: 75\r\n  Small\r\n  box.\r\n\r\n# Pistol\r\nITEM_EXAMINE: 49\r\n  Standard pistol.\r\n");
    defer t.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Small box.", t.get(75).?);
    try std.testing.expectEqualStrings("Standard pistol.", t.get(49).?);
}

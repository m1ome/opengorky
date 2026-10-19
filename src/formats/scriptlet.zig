//! Scenes (`common/other.dat: scriptlets\*.scr`) and their points (`*.pts`).
//!
//! `.scr`: one command per line, `NAME` or `NAME(arg, …)`, sometimes with a trailing `;`;
//! `//` starts a comment. Arguments are quoted strings or numbers.
//! `.pts`: `name,x,y,angle` per line (x, y are background pixels).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Arg = union(enum) {
    string: []const u8,
    number: f32,

    pub fn str(self: Arg) []const u8 {
        return switch (self) {
            .string => |s| s,
            .number => "",
        };
    }

    /// Like the exe's `atof`: `WALKAREA("ciuch_blokada",0,1")` in `05l_ciuchcia.scr` gives 1.
    pub fn num(self: Arg) f32 {
        return switch (self) {
            .number => |n| n,
            .string => |s| @import("../script.zig").value.atof(s),
        };
    }

    /// Integer via `_ftol`: NaN and 1e30 from a file do not crash the cast.
    pub fn int(self: Arg) i32 {
        return @import("../script.zig").value.floatToInt(self.num());
    }
};

pub const Command = struct {
    name: []const u8,
    args: []Arg,
    line: u32,

    pub fn arg(self: Command, i: usize) Arg {
        return if (i < self.args.len) self.args[i] else .{ .string = "" };
    }
};

const Error = error{BadSyntax} || Allocator.Error;

/// Result strings point into `text`; memory is in `arena`.
pub fn parse(arena: Allocator, text: []const u8) Error![]Command {
    var cmds: std.ArrayList(Command) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: u32 = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        var line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.indexOf(u8, line, "//")) |c| line = std.mem.trimEnd(u8, line[0..c], " \t");
        line = std.mem.trimEnd(u8, line, "; \t");
        if (line.len == 0) continue;
        const open = std.mem.indexOfScalar(u8, line, '(');
        const name = std.mem.trim(u8, if (open) |o| line[0..o] else line, " \t");
        var args: std.ArrayList(Arg) = .empty;
        if (open) |o| {
            // Three game scenes have WALKTO without a closing parenthesis — accepted.
            const close = std.mem.lastIndexOfScalar(u8, line, ')') orelse line.len;
            if (close < o) return error.BadSyntax;
            var rest = line[o + 1 .. close];
            while (true) {
                rest = std.mem.trimStart(u8, rest, " \t");
                if (rest.len == 0) break;
                if (rest[0] == '"') {
                    const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return error.BadSyntax;
                    try args.append(arena, .{ .string = rest[1..end] });
                    rest = rest[end + 1 ..];
                } else {
                    const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
                    const tok = std.mem.trim(u8, rest[0..end], " \t");
                    try args.append(arena, if (std.fmt.parseFloat(f32, tok)) |n| .{ .number = n } else |_| .{ .string = tok });
                    rest = rest[end..];
                }
                rest = std.mem.trimStart(u8, rest, " \t");
                if (rest.len > 0 and rest[0] == ',') rest = rest[1..];
            }
        }
        try cmds.append(arena, .{ .name = name, .args = args.items, .line = line_no });
    }
    return cmds.items;
}

pub const Point = struct {
    name: []const u8,
    x: f32,
    y: f32,
    angle: f32,
};

pub fn parsePoints(arena: Allocator, text: []const u8) Error![]Point {
    var pts: std.ArrayList(Point) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var it = std.mem.splitScalar(u8, line, ',');
        const name = it.next() orelse continue;
        var v: [3]f32 = .{ 0, 0, 0 };
        for (&v) |*x| x.* = std.fmt.parseFloat(f32, std.mem.trim(u8, it.next() orelse "0", " ")) catch return error.BadSyntax;
        try pts.append(arena, .{ .name = name, .x = v[0], .y = v[1], .angle = v[2] });
    }
    return pts.items;
}

test parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cmds = try parse(arena.allocator(),
        \\PANORAMA_ON
        \\ANIMATION("Trantigne","pontA_out");
        \\// comment
        \\DOLLY("cam_1",0,100)
        \\WAITFORACTOR("Ovitz"); // trailing
    );
    try std.testing.expectEqual(4, cmds.len);
    try std.testing.expectEqualStrings("ANIMATION", cmds[1].name);
    try std.testing.expectEqualStrings("pontA_out", cmds[1].arg(1).str());
    try std.testing.expectEqual(100, cmds[2].arg(2).num());
    try std.testing.expectEqualStrings("Ovitz", cmds[3].arg(0).str());
}

test parsePoints {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const pts = try parsePoints(arena.allocator(), "ovic_p1,1605,272,12.720011\r\ncam_1,1652,284,0.000000\r\n");
    try std.testing.expectEqual(2, pts.len);
    try std.testing.expectEqual(1605, pts[0].x);
}

test "int argument wraps like _ftol" {
    try std.testing.expectEqual(@as(i32, 705032704), (Arg{ .number = 5e9 }).int());
    try std.testing.expectEqual(@as(i32, 0), (Arg{ .number = std.math.nan(f32) }).int());
}

test "number argument with trailing junk" {
    try std.testing.expectEqual(@as(f32, 1), (Arg{ .string = "1\"" }).num());
    try std.testing.expectEqual(@as(f32, 2.5), (Arg{ .string = " 2.5x" }).num());
    try std.testing.expectEqual(@as(f32, 0), (Arg{ .string = "abc" }).num());
}

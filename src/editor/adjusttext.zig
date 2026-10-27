//! adjust.kdt's decrypted lines for the Engine settings page (adjustpage.zig): each
//! `type name = value;`, its group, a typed value in the exe's form.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A line `type name = value;`: its parts and where its value is in the text.
pub const Param = struct { kind: []const u8, name: []const u8, value: []const u8, at: usize };

pub fn params(a: Allocator, text: []const u8) []const Param {
    var out: std.ArrayList(Param) = .empty;
    var pos: usize = 0;
    while (pos < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
        const line = text[pos..end];
        defer pos = end + 1;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const eq = std.mem.indexOf(u8, line, " = ") orelse continue;
        var v_end = line.len;
        while (v_end > eq + 3 and (line[v_end - 1] == ';' or line[v_end - 1] == '\r' or line[v_end - 1] == ' ')) v_end -= 1;
        out.append(a, .{ .kind = line[0..sp], .name = std.mem.trim(u8, line[sp + 1 .. eq], " "), .value = line[eq + 3 .. v_end], .at = pos + eq + 3 }) catch {};
    }
    return out.items;
}

/// Its group: the first word of the name, `attack_<x>` for the attacks (half of them).
pub fn group(name: []const u8) []const u8 {
    const k = std.mem.indexOfScalar(u8, name, '_') orelse return name;
    if (!std.mem.eql(u8, name[0..k], "attack")) return name[0..k];
    return name[0 .. std.mem.indexOfScalarPos(u8, name, k + 1, '_') orelse name.len];
}

/// `v` typed for a value of `kind`, in the exe's form ("8", "1.300000", "200,60,20");
/// null if it isn't one.
pub fn normalize(a: Allocator, kind: []const u8, v: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, v, " ");
    if (std.mem.eql(u8, kind, "int")) return std.fmt.allocPrint(a, "{d}", .{std.fmt.parseInt(i32, t, 10) catch return null}) catch null;
    if (std.mem.eql(u8, kind, "float")) return std.fmt.allocPrint(a, "{d:.6}", .{std.fmt.parseFloat(f32, t) catch return null}) catch null;
    if (!std.mem.eql(u8, kind, "rgba")) return null;
    var c: [3]u8 = undefined;
    var it = std.mem.splitScalar(u8, t, ',');
    for (&c) |*ch| ch.* = std.fmt.parseInt(u8, std.mem.trim(u8, it.next() orelse return null, " "), 10) catch return null;
    if (it.next() != null) return null;
    return std.fmt.allocPrint(a, "{d},{d},{d}", .{ c[0], c[1], c[2] }) catch null;
}

test "params: values, their place, the attack groups" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const t = "int fighter_stunned_level = 8;\nrgba fighter_stunned_color = 200,60,20\nfloat attack_ball_speed = 70.000000;\n";
    const ps = params(arena.allocator(), t);
    try std.testing.expectEqual(3, ps.len);
    try std.testing.expectEqualStrings("8", ps[0].value);
    try std.testing.expectEqualStrings("200,60,20", ps[1].value);
    try std.testing.expectEqualStrings("70.000000", t[ps[2].at..][0..9]);
    try std.testing.expectEqualStrings("attack_ball", group(ps[2].name));
    try std.testing.expectEqualStrings("1.300000", normalize(arena.allocator(), "float", "1.3").?);
    try std.testing.expect(normalize(arena.allocator(), "rgba", "300,0,0") == null);
}

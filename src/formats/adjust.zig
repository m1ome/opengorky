//! `adjust.kdt` — engine tuning parameters (600 of them: sound, effects, combat).
//!
//! The file is a sequence of records `u32 length` + `length` bytes; byte `i` of a record
//! is XORed with `(length*0x1F + i*0x65) & 0xFF` (loader 0x418120 in the exe).
//! Decrypted text: lines `int name = 5;`, `float name = 0.5;`, `rgba name = r,g,b`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Error = error{Truncated} || Allocator.Error;

/// Decrypts the file to text (records concatenated).
fn decrypt(gpa: Allocator, bytes: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 0;
    while (pos + 4 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;
        if (len == 0) break;
        if (pos + len > bytes.len) return error.Truncated;
        const base: u8 = @truncate(len *% 0x1f);
        for (bytes[pos..][0..len], 0..) |b, i| {
            const key: u8 = base +% @as(u8, @truncate(i *% 0x65));
            try out.append(gpa, b ^ key);
        }
        pos += len;
    }
    return out.toOwnedSlice(gpa);
}

const Value = union(enum) {
    int: i32,
    float: f32,
    rgba: [3]u8,
};

const Adjust = struct {
    text: []u8,
    /// Name → value; names point into `text`.
    values: std.StringHashMapUnmanaged(Value) = .empty,

    pub fn deinit(self: *Adjust, gpa: Allocator) void {
        self.values.deinit(gpa);
        gpa.free(self.text);
        self.* = undefined;
    }

    pub fn float(self: Adjust, name: []const u8, default: f32) f32 {
        return switch (self.values.get(name) orelse return default) {
            .float => |v| v,
            .int => |v| @floatFromInt(v),
            .rgba => default,
        };
    }

    pub fn int(self: Adjust, name: []const u8, default: i32) i32 {
        return switch (self.values.get(name) orelse return default) {
            .int => |v| v,
            .float => |v| @import("../script.zig").value.floatToInt(v),
            .rgba => default,
        };
    }
};

pub fn parse(gpa: Allocator, bytes: []const u8) Error!Adjust {
    var adj: Adjust = .{ .text = try decrypt(gpa, bytes) };
    errdefer adj.deinit(gpa);
    var lines = std.mem.splitScalar(u8, adj.text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r;");
        var it = std.mem.tokenizeAny(u8, line, " \t=");
        const type_name = it.next() orelse continue;
        const name = it.next() orelse continue;
        const rest = std.mem.trim(u8, it.rest(), " \t=");
        const v: Value = if (std.mem.eql(u8, type_name, "int"))
            .{ .int = std.fmt.parseInt(i32, rest, 10) catch continue }
        else if (std.mem.eql(u8, type_name, "float"))
            .{ .float = std.fmt.parseFloat(f32, rest) catch continue }
        else if (std.mem.eql(u8, type_name, "rgba")) blk: {
            var c: [3]u8 = .{ 0, 0, 0 };
            var parts = std.mem.splitScalar(u8, rest, ',');
            for (&c) |*ch| ch.* = std.fmt.parseInt(u8, std.mem.trim(u8, parts.next() orelse "0", " "), 10) catch 0;
            break :blk .{ .rgba = c };
        } else continue;
        try adj.values.put(gpa, name, v);
    }
    return adj;
}

test "decrypt and parse" {
    const gpa = std.testing.allocator;
    const plain = "float sound_volume_falloff = 0.004000;\nint fps = 0;\nrgba c = 200,60,20\n";
    var enc: [4 + plain.len]u8 = undefined;
    std.mem.writeInt(u32, enc[0..4], plain.len, .little);
    for (plain, 0..) |ch, i| enc[4 + i] = ch ^ @as(u8, @truncate(plain.len * 0x1f + i * 0x65));

    var adj = try parse(gpa, &enc);
    defer adj.deinit(gpa);
    try std.testing.expectEqual(0.004, adj.float("sound_volume_falloff", 0));
    try std.testing.expectEqual(0, adj.int("fps", 30));
    try std.testing.expectEqual(Value{ .rgba = .{ 200, 60, 20 } }, adj.values.get("c").?);
    try std.testing.expectEqual(7, adj.int("missing", 7));
    // A float read as int goes through _ftol and does not panic on NaN.
    try adj.values.put(gpa, "bad", .{ .float = std.math.nan(f32) });
    try std.testing.expectEqual(0, adj.int("bad", 7));
}

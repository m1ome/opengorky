//! Script language values and type conversions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");

pub const Value = union(enum) {
    int: i32,
    float: f32,
    /// Strings are immutable; memory is the runtime string arena or the script source.
    /// `object` values are stored as a string with the object's name.
    string: []const u8,

    pub const zero: Value = .{ .int = 0 };

    pub fn toInt(self: Value) i32 {
        return switch (self) {
            .int => |v| v,
            .float => |v| floatToInt(v),
            .string => |s| std.fmt.parseInt(i32, std.mem.trim(u8, s, " "), 10) catch 0,
        };
    }

    pub fn toFloat(self: Value) f32 {
        return switch (self) {
            .int => |v| @floatFromInt(v),
            .float => |v| v,
            .string => |s| std.fmt.parseFloat(f32, std.mem.trim(u8, s, " ")) catch 0,
        };
    }

    /// Allocates a string in `arena` for numbers.
    fn toString(self: Value, arena: Allocator) Allocator.Error![]const u8 {
        return switch (self) {
            .string => |s| s,
            .int => |v| std.fmt.allocPrint(arena, "{d}", .{v}),
            .float => |v| std.fmt.allocPrint(arena, "{d:.6}", .{v}),
        };
    }

    /// Condition of `if`, `&&`, `||` (0x4c6510): `toInt(v) != 0`; a fraction truncates
    /// (`0.5` is false), a string is false (the exe reads its pointer as a float ≈ 0).
    pub fn truthy(self: Value) bool {
        return self.exeInt() != 0;
    }

    /// Integer as the exe interpreter sees it: a string is 0.
    fn exeInt(self: Value) i32 {
        return switch (self) {
            .string => 0,
            else => self.toInt(),
        };
    }

    /// Conversion to the variable's declared type: setter 0x44ae80 (from assignment
    /// 0x4e3d50) by target type. Int is 0x4c6510: a string gives 0.
    pub fn convert(self: Value, t: ast.Type, arena: Allocator) Allocator.Error!Value {
        return switch (t) {
            .int => .{ .int = self.exeInt() },
            // shortcut: the exe (0x4c6530) does `fild` on the data, i.e. a string's address;
            // we parse the text. Game scripts never assign this way.
            .float => .{ .float = self.toFloat() },
            // shortcut: the exe copies the data as `char*`, garbage for a number; we format it.
            .string, .object => .{ .string = try self.toString(arena) },
        };
    }

    /// Value from `.var` text (0x431ee0): int is the leading digits without sign or
    /// spaces ("-1" → 0, "5x" → 5, wrapping), float is `atof` (0x4f7fb4). The exe
    /// doesn't read strings or objects from `.var`, so those give null.
    pub fn parse(text: []const u8, t: ast.Type) ?Value {
        return switch (t) {
            .int => blk: {
                var n: i32 = 0;
                for (text) |ch| {
                    if (ch < '0' or ch > '9') break;
                    n = n *% 10 +% (ch - '0');
                }
                break :blk .{ .int = n };
            },
            .float => .{ .float = atof(text) },
            .string, .object => null,
        };
    }

    pub fn initial(t: ast.Type) Value {
        return switch (t) {
            .int => .{ .int = 0 },
            .float => .{ .float = 0 },
            .string, .object => .{ .string = "" },
        };
    }

    /// Copy with its own string in `a`.
    pub fn dupe(self: Value, a: Allocator) Allocator.Error!Value {
        return switch (self) {
            .string => |s| .{ .string = try a.dupe(u8, s) },
            else => self,
        };
    }

    pub fn format(self: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .int => |v| try w.print("{d}", .{v}),
            .float => |v| try w.print("{d}", .{v}),
            .string => |s| try w.print("\"{s}\"", .{s}),
        }
    }
};

/// CRT `atof`: spaces, sign, digits, fraction, exponent, longest prefix
/// ("1\"" → 1, "abc" → 0).
pub fn atof(s: []const u8) f32 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    const start = i;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
        if (j < s.len and std.ascii.isDigit(s[j])) {
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            i = j;
        }
    }
    return std.fmt.parseFloat(f32, s[start..i]) catch 0;
}

/// `_ftol` (0x4f73a8): `fistp qword` truncation, low 32 bits (3e9 → −1294967296).
/// NaN and |v| ≥ 2^63 give the "integer indefinite" 0x8000000000000000, low bits 0.
pub fn floatToInt(v: anytype) i32 {
    if (!(@abs(v) < 0x1p63)) return 0;
    return @truncate(@as(i64, @intFromFloat(v)));
}

/// `_ftol(x · k)`: an int scaled by a float factor, as the exe does (0x4f73a8).
pub fn scaleInt(x: i32, k: f32) i32 {
    return floatToInt(@as(f32, @floatFromInt(x)) * k);
}

/// Arithmetic and comparisons: if either operand is float, compute in float.
pub fn binary(op: ast.BinaryOp, a: Value, b: Value) Value {
    const use_float = a == .float or b == .float;
    switch (op) {
        .add, .sub, .mul, .div => {
            if (use_float) {
                const x = a.toFloat();
                const y = b.toFloat();
                return .{
                    .float = switch (op) {
                        .add => x + y,
                        .sub => x - y,
                        .mul => x * y,
                        .div => x / y, // fdivr 0x4c620f: ±inf/NaN on 0
                        else => unreachable,
                    },
                };
            }
            // Integer arithmetic 0x4c60a0…0x4c6243 takes operands via 0x4c6510: a string
            // is 0 (`"5" + 1` → 1).
            const x = a.exeInt();
            const y = b.exeInt();
            return .{
                .int = switch (op) {
                    .add => x +% y,
                    .sub => x -% y,
                    .mul => x *% y,
                    // shortcut: idiv by 0 raises a CPU exception in the exe; we return 0.
                    .div => if (y == 0) 0 else if (y == -1) 0 -% x else @divTrunc(x, y),
                    else => unreachable,
                },
            };
        },
        // `==` (0x4c6510): always on truncated integers (`1.5 == 1`; strings are equal).
        .eq => return .{ .int = @intFromBool(a.exeInt() == b.exeInt()) },
        // Exe bugs: `!=` falls into the add branch (0x4e3879), `<=` calls the same
        // function as `>=` (0x4e379a). Not used in game scripts.
        .ne => return binary(.add, a, b),
        .lt, .le, .gt, .ge => {
            if (use_float) {
                // x87 `fcomp` b with a (0x4c6260, 0x4c62e0, 0x4c63e0): NaN is "unordered", so
                // `<` is false and `>`, `>=` are true.
                const x = a.toFloat();
                const y = b.toFloat();
                return .{ .int = @intFromBool(switch (op) {
                    .lt => x < y,
                    .gt => !(y >= x),
                    .le, .ge => !(y > x),
                    else => unreachable,
                }) };
            }
            const order = std.math.order(a.exeInt(), b.exeInt());
            const r = switch (op) {
                .lt => order == .lt,
                .gt => order == .gt,
                .le, .ge => order != .lt,
                else => unreachable,
            };
            return .{ .int = @intFromBool(r) };
        },
        // && and || without short-circuit (0x4c6460, 0x4c64a0).
        .@"and" => return .{ .int = @intFromBool(a.truthy() and b.truthy()) },
        .@"or" => return .{ .int = @intFromBool(a.truthy() or b.truthy()) },
    }
}

test "arithmetic promotes to float" {
    try std.testing.expectEqual(Value{ .int = 7 }, binary(.add, .{ .int = 3 }, .{ .int = 4 }));
    try std.testing.expectEqual(Value{ .float = 3.5 }, binary(.add, .{ .int = 3 }, .{ .float = 0.5 }));
    try std.testing.expectEqual(Value{ .int = -2 }, binary(.div, .{ .int = -7 }, .{ .int = 3 }));
    try std.testing.expectEqual(Value{ .int = 1 }, binary(.add, .{ .string = "5" }, .{ .int = 1 }));
    try std.testing.expectEqual(Value{ .int = std.math.minInt(i32) }, binary(.div, .{ .int = std.math.minInt(i32) }, .{ .int = -1 }));
    try std.testing.expect(std.math.isInf(binary(.div, .{ .float = 1 }, .{ .int = 0 }).float));
    try std.testing.expectEqual(Value{ .int = 0 }, binary(.div, .{ .int = 1 }, .{ .int = 0 }));
    try std.testing.expectEqual(Value{ .int = 1 }, binary(.ge, .{ .float = 2 }, .{ .int = 2 }));
}

test "comparisons as in the exe" {
    try std.testing.expectEqual(Value{ .int = 1 }, binary(.eq, .{ .float = 1.5 }, .{ .int = 1 }));
    try std.testing.expectEqual(Value{ .int = 0 }, binary(.le, .{ .int = 3 }, .{ .int = 5 }));
    try std.testing.expectEqual(Value{ .int = 5 }, binary(.ne, .{ .int = 2 }, .{ .int = 3 }));
    try std.testing.expect(!(Value{ .float = 0.5 }).truthy());
    try std.testing.expect(!(Value{ .string = "x" }).truthy());
}

test "NaN comparisons as x87" {
    const nan: Value = .{ .float = std.math.nan(f32) };
    try std.testing.expectEqual(Value{ .int = 0 }, binary(.lt, nan, .{ .int = 1 }));
    try std.testing.expectEqual(Value{ .int = 1 }, binary(.gt, nan, .{ .int = 1 }));
    try std.testing.expectEqual(Value{ .int = 1 }, binary(.ge, nan, .{ .int = 1 }));
    try std.testing.expectEqual(Value{ .int = 1 }, binary(.le, .{ .int = 1 }, nan));
}

test "float to int wraps like _ftol" {
    try std.testing.expectEqual(@as(i32, -1294967296), floatToInt(@as(f32, 3e9)));
    try std.testing.expectEqual(@as(i32, 0), floatToInt(std.math.nan(f32)));
    try std.testing.expectEqual(@as(i32, 0), floatToInt(@as(f32, 1e30)));
    try std.testing.expectEqual(@as(i32, -1), floatToInt(@as(f32, -1.9)));
    try std.testing.expectEqual(@as(i32, 7), floatToInt(@as(f64, 7.9)));
    try std.testing.expectEqual(@as(i32, 15), scaleInt(10, 1.53));
}

test "conversions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(Value{ .int = 1 }, try (Value{ .float = 1.9 }).convert(.int, a));
    try std.testing.expectEqual(Value{ .int = 0 }, try (Value{ .string = "5" }).convert(.int, a));
    try std.testing.expectEqualStrings("15", (try (Value{ .int = 15 }).convert(.string, a)).string);
    try std.testing.expectEqual(Value{ .float = -1.5 }, Value.parse("-1.500000", .float).?);
}

test ".var values as the exe loader" {
    try std.testing.expectEqual(Value{ .int = 0 }, Value.parse("-1", .int).?);
    try std.testing.expectEqual(Value{ .int = 5 }, Value.parse("5x", .int).?);
    try std.testing.expectEqual(Value{ .int = 664 }, Value.parse("664", .int).?);
    try std.testing.expectEqual(Value{ .float = 2.5 }, Value.parse(" 2.5x", .float).?);
    try std.testing.expectEqual(null, Value.parse("13_lampki", .string));
    try std.testing.expectEqual(@as(f32, 0), atof("abc"));
    try std.testing.expectEqual(@as(f32, 1), atof("1\""));
    try std.testing.expectEqual(@as(f32, 100), atof("1e2"));
    try std.testing.expectEqual(@as(f32, 1), atof("1e"));
}

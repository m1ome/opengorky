//! Per-tick list filter shared by the effect lists.

const std = @import("std");

/// Tick a list (each item's `tick`), removing finished ones and keeping order.
pub fn retain(list: anytype, ctx: anytype) void {
    var n: usize = 0;
    for (list.items) |*it| if (it.tick(ctx)) {
        list.items[n] = it.*;
        n += 1;
    };
    list.shrinkRetainingCapacity(n);
}

test "retain: finished items go, the rest keep their order" {
    const Item = struct {
        left: u32,
        fn tick(i: *@This(), _: void) bool {
            if (i.left <= 1) return false;
            i.left -= 1;
            return true;
        }
    };
    const a = std.testing.allocator;
    var l: std.ArrayList(Item) = .empty;
    defer l.deinit(a);
    for ([_]u32{ 3, 1, 4, 2 }) |n| try l.append(a, .{ .left = n });
    retain(&l, {});
    try std.testing.expectEqual(3, l.items.len);
    for (l.items, [_]u32{ 2, 3, 1 }) |x, n| try std.testing.expectEqual(n, x.left);
}

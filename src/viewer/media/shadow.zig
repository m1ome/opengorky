//! Icon shadow (0x47d7b0 → 0x41bdb0): the frame rectangle 3 px lower, only where
//! the frame has no pixels of its own. Shadow pixel (i, j) darkens if the frame
//! has a pixel diagonally up-left: at (1, 1) ×0.5, else at (2, 2) ×0.625, else
//! at (3, 3) ×0.75. The exe treats rows past the frame's bottom as its own
//! (memset 1, 0x41bf35), so the shadow's bottom 3 rows are empty.

const std = @import("std");

/// Black alpha over the background giving a brightness factor of 0.5 / 0.625 / 0.75.
const shades = [3]u8{ 128, 96, 64 };

/// Shadow RGBA of the same size as frame `rgba` (w×h, bytes R, G, B, A).
pub fn build(gpa: std.mem.Allocator, w: usize, h: usize, rgba: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, w * h * 4);
    @memset(out, 0);
    const solid = struct {
        fn at(px: []const u8, ww: usize, hh: usize, x: isize, y: isize) bool {
            if (x < 0 or y < 0) return false;
            const ux: usize = @intCast(x);
            const uy: usize = @intCast(y);
            if (uy >= hh) return true;
            if (ux >= ww) return false;
            return px[(uy * ww + ux) * 4 + 3] != 0;
        }
    }.at;
    for (0..h) |j| for (0..w) |i| {
        const x: isize = @intCast(i);
        const y: isize = @intCast(j + 3);
        if (solid(rgba, w, h, x, y)) continue;
        for (shades, 1..) |a, d| {
            const k: isize = @intCast(d);
            if (solid(rgba, w, h, x - k, y - k)) {
                out[(j * w + i) * 4 + 3] = a;
                break;
            }
        }
    };
    return out;
}

test "icon shadow: diagonal down-right, not over own pixels" {
    const gpa = std.testing.allocator;
    // 6×6 frame with one pixel at (1, 1).
    var px: [6 * 6 * 4]u8 = @splat(0);
    px[(1 * 6 + 1) * 4 + 3] = 255;
    const s = try build(gpa, 6, 6, &px);
    defer gpa.free(s);
    // Shadow pixel (i, j) is frame point (i, j + 3). Pixel (1, 1) darkens
    // (2, 2) — above the shadow rectangle, (3, 3) ×0.625, (4, 4) ×0.75.
    try std.testing.expectEqual(@as(u8, 96), s[(0 * 6 + 3) * 4 + 3]);
    try std.testing.expectEqual(@as(u8, 64), s[(1 * 6 + 4) * 4 + 3]);
    try std.testing.expectEqual(@as(u8, 0), s[(0 * 6 + 2) * 4 + 3]);
    // The bottom 3 shadow rows are the frame's "own" rows past its edge.
    for (3..6) |j| for (0..6) |i| try std.testing.expectEqual(@as(u8, 0), s[(j * 6 + i) * 4 + 3]);
}

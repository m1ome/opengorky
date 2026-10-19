//! Effect resource description `.dsc`: blend mode and frame list.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Resource blend mode (0x408ad0).
pub const Blend = enum(u3) {
    opaque_ = 0,
    /// ONE / ONE
    add = 1,
    /// SRCALPHA / INVSRCALPHA
    alpha = 2,
    /// ZERO / INVSRCCOLOR
    darken = 3,
    /// ONE / INVSRCCOLOR — default for effects without a header (D3D)
    screen = 4,
    /// DESTCOLOR / ZERO
    multiply = 5,
};

/// `.dsc` parse (0x45df40): frame lines up to an empty line; a `[alpha]` line means mode 2,
/// `[add]` 1, `[ala]` 2 (D3D); no header means 4. `frames` are `.3df` file names in the same
/// folder, slices of `text`.
pub const Dsc = struct {
    blend: Blend = .screen,
    frames: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *Dsc, gpa: Allocator) void {
        self.frames.deinit(gpa);
    }
};

pub fn parseDsc(gpa: Allocator, text: []const u8) !Dsc {
    var d: Dsc = .{};
    errdefer d.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.indexOf(u8, line, "[alpha]") != null or std.mem.indexOf(u8, line, "[ala]") != null) {
            d.blend = .alpha;
            continue;
        }
        if (std.mem.indexOf(u8, line, "[add]") != null) {
            d.blend = .add;
            continue;
        }
        if (line.len == 0) break;
        try d.frames.append(gpa, line);
    }
    return d;
}

test parseDsc {
    var d = try parseDsc(std.testing.allocator, "[alpha]\r\nexp.01.3df\r\nexp.02.3df\r\n\r\nzzz\r\n");
    defer d.deinit(std.testing.allocator);
    try std.testing.expectEqual(Blend.alpha, d.blend);
    try std.testing.expectEqual(2, d.frames.items.len);
    try std.testing.expectEqualStrings("exp.02.3df", d.frames.items[1]);
}

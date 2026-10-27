//! The editor's command line: the scripted edits (checks, scripts, demos) by name and
//! how many values each takes, in one table; the parser and the usage text use it.
//! The edits themselves are scripted.zig (one function each).

const std = @import("std");

pub const Op = struct { name: []const u8, arity: u8 };

pub const ops = [_]Op{
    .{ .name = "--add", .arity = 1 },
    .{ .name = "--add-at", .arity = 3 },
    .{ .name = "--adjust", .arity = 2 },
    .{ .name = "--add-model", .arity = 2 },
    .{ .name = "--add-frame", .arity = 1 },
    .{ .name = "--add-hero", .arity = 2 },
    .{ .name = "--add-own", .arity = 2 },
    .{ .name = "--anim", .arity = 1 },
    .{ .name = "--anim-new", .arity = 2 },
    .{ .name = "--area-delete", .arity = 1 },
    .{ .name = "--area-move", .arity = 2 },
    .{ .name = "--area-rename", .arity = 2 },
    .{ .name = "--ask-delete", .arity = 1 },
    .{ .name = "--box", .arity = 1 },
    .{ .name = "--box-add", .arity = 1 },
    .{ .name = "--cam-drag", .arity = 2 },
    .{ .name = "--camera", .arity = 2 },
    .{ .name = "--class-weapon", .arity = 3 },
    .{ .name = "--click", .arity = 2 },
    .{ .name = "--code", .arity = 1 },
    .{ .name = "--copy", .arity = 1 },
    .{ .name = "--delete-box", .arity = 1 },
    .{ .name = "--depth-fit", .arity = 0 },
    .{ .name = "--dialog", .arity = 1 },
    .{ .name = "--dlg", .arity = 3 },
    .{ .name = "--dup", .arity = 1 },
    .{ .name = "--effect", .arity = 1 },
    .{ .name = "--effect-add", .arity = 1 },
    .{ .name = "--entry", .arity = 3 },
    .{ .name = "--export-glb", .arity = 2 },
    .{ .name = "--export-icon", .arity = 2 },
    .{ .name = "--export-sound", .arity = 2 },
    .{ .name = "--export-texture", .arity = 2 },
    .{ .name = "--font", .arity = 1 },
    .{ .name = "--font-ttf", .arity = 1 },
    .{ .name = "--frame-in", .arity = 2 },
    .{ .name = "--frame-out", .arity = 2 },
    .{ .name = "--goto", .arity = 1 },
    .{ .name = "--grid-split", .arity = 2 },
    .{ .name = "--history", .arity = 0 },
    .{ .name = "--history-old", .arity = 1 },
    .{ .name = "--icon", .arity = 1 },
    .{ .name = "--import-anims", .arity = 2 },
    .{ .name = "--import-glb", .arity = 2 },
    .{ .name = "--import-icon", .arity = 2 },
    .{ .name = "--import-sound", .arity = 1 },
    .{ .name = "--import-texture", .arity = 2 },
    .{ .name = "--import-music", .arity = 2 },
    .{ .name = "--import-sprite", .arity = 2 },
    .{ .name = "--import-video", .arity = 1 },
    .{ .name = "--info", .arity = 1 },
    .{ .name = "--inventory", .arity = 1 },
    .{ .name = "--level-area", .arity = 1 },
    .{ .name = "--level-done", .arity = 0 },
    .{ .name = "--level-exit", .arity = 2 },
    .{ .name = "--level-light", .arity = 1 },
    .{ .name = "--level-paint", .arity = 1 },
    .{ .name = "--level-undo", .arity = 0 },
    .{ .name = "--menu", .arity = 2 },
    .{ .name = "--menu-obj", .arity = 1 },
    .{ .name = "--menu-open", .arity = 1 },
    .{ .name = "--modcheck", .arity = 0 },
    .{ .name = "--move", .arity = 3 },
    .{ .name = "--new-box", .arity = 2 },
    .{ .name = "--new-location", .arity = 1 },
    .{ .name = "--new-scene", .arity = 0 },
    .{ .name = "--new-script", .arity = 0 },
    .{ .name = "--num", .arity = 2 },
    .{ .name = "--obstacle", .arity = 3 },
    .{ .name = "--open-key", .arity = 1 },
    .{ .name = "--paint", .arity = 1 },
    .{ .name = "--paint-tool", .arity = 1 },
    .{ .name = "--path", .arity = 1 },
    .{ .name = "--path-node", .arity = 1 },
    .{ .name = "--play-level", .arity = 0 },
    .{ .name = "--prop", .arity = 3 },
    .{ .name = "--purge", .arity = 0 },
    .{ .name = "--put", .arity = 2 },
    .{ .name = "--query", .arity = 1 },
    .{ .name = "--remove", .arity = 1 },
    .{ .name = "--remove-hero", .arity = 1 },
    .{ .name = "--rendered", .arity = 0 },
    .{ .name = "--roll-back", .arity = 1 },
    .{ .name = "--return-to", .arity = 1 },
    .{ .name = "--save-now", .arity = 0 },
    .{ .name = "--scene", .arity = 1 },
    .{ .name = "--scene-test", .arity = 1 },
    .{ .name = "--logic", .arity = 2 },
    .{ .name = "--open", .arity = 2 },
    .{ .name = "--package", .arity = 2 },
    .{ .name = "--scene-off", .arity = 1 },
    .{ .name = "--scene-point", .arity = 1 },
    .{ .name = "--scene-rename", .arity = 2 },
    .{ .name = "--scene-skip", .arity = 1 },
    .{ .name = "--select", .arity = 1 },
    .{ .name = "--set", .arity = 3 },
    .{ .name = "--set-class", .arity = 3 },
    .{ .name = "--show", .arity = 1 },
    .{ .name = "--sound", .arity = 3 },
    .{ .name = "--preview-frame", .arity = 1 },
    .{ .name = "--strike-hero", .arity = 1 },
    .{ .name = "--sprite", .arity = 2 },
    .{ .name = "--text", .arity = 3 },
    .{ .name = "--tree", .arity = 1 },
    .{ .name = "--tree-dup", .arity = 1 },
    .{ .name = "--tree-menu", .arity = 1 },
    .{ .name = "--trigger", .arity = 1 },
    .{ .name = "--turn", .arity = 2 },
    .{ .name = "--type", .arity = 1 },
    .{ .name = "--voice", .arity = 2 },
    .{ .name = "--voice-copy", .arity = 2 },
    .{ .name = "--walk", .arity = 0 },
    .{ .name = "--wheel", .arity = 3 },
    .{ .name = "--walk-in", .arity = 1 },
    .{ .name = "--weapon", .arity = 3 },
    .{ .name = "--wire", .arity = 0 },
    .{ .name = "--zone", .arity = 0 },
};

pub fn find(arg: []const u8) ?Op {
    for (ops) |o| if (std.mem.eql(u8, o.name, arg)) return o;
    return null;
}

/// The message (if any) and the usage on stderr; error.Usage.
pub fn fail(comptime fmt: []const u8, args: anytype) error{Usage} {
    if (fmt.len > 0) std.debug.print(fmt ++ "\n", args);
    std.debug.print("usage: opengorky-editor [game dir] [--level NAME] [--lang en|ru] [--tab TAB] [--shot out.png] [--save]\n  scripted edits, in order:\n", .{});
    for (ops) |o| {
        std.debug.print("    {s}", .{o.name});
        for (0..o.arity) |_| std.debug.print(" V", .{});
        std.debug.print("\n", .{});
    }
    return error.Usage;
}

test find {
    try std.testing.expectEqual(@as(u8, 3), find("--move").?.arity);
    try std.testing.expect(find("--sav") == null);
    // Each name once.
    for (ops, 0..) |o, i| for (ops[i + 1 ..]) |x| try std.testing.expect(!std.mem.eql(u8, o.name, x.name));
}

//! Resource kind by file name, and safe paths for extraction.

const std = @import("std");

pub const Kind = enum { sprite, background, jpeg, zbuffer, texture, audio, other };

pub fn kindOf(name: []const u8) Kind {
    const ext = std.fs.path.extension(name);
    if (std.ascii.eqlIgnoreCase(ext, ".spr") or std.ascii.eqlIgnoreCase(ext, ".spz")) return .sprite;
    if (std.ascii.eqlIgnoreCase(ext, ".bkg")) return .background;
    if (std.ascii.eqlIgnoreCase(ext, ".jpg")) return .jpeg;
    if (std.ascii.eqlIgnoreCase(ext, ".zbf")) return .zbuffer;
    if (std.ascii.eqlIgnoreCase(ext, ".3df")) return .texture;
    if (std.ascii.eqlIgnoreCase(ext, ".wav") or std.ascii.eqlIgnoreCase(ext, ".mp3")) return .audio;
    return .other;
}

/// Script-language files. `.dlg` and `.scr` are other formats.
pub fn isScript(name: []const u8) bool {
    const exts = [_][]const u8{
        ".lev", ".act", ".ba",  ".aba", ".s",     ".ss",  ".itm", ".are",
        ".obs", ".wpn", ".ftr", ".hro", ".obs_i", ".pth", ".mtm",
    };
    const ext = std.fs.path.extension(name);
    for (exts) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// Archive name (`background\01_port.bkg`) → relative path with `/`.
/// Null for empty, absolute and `..` names.
pub fn safeRelPath(buf: []u8, name: []const u8) ?[]const u8 {
    if (name.len == 0 or name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = if (c == '\\') '/' else c;
    const p = buf[0..name.len];
    if (p[0] == '/' or std.mem.indexOfScalar(u8, p, ':') != null) return null;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return null;
    }
    return p;
}

test kindOf {
    try std.testing.expectEqual(Kind.sprite, kindOf("icons\\axe.SPR"));
    try std.testing.expectEqual(Kind.background, kindOf("background\\01_port.bkg"));
    try std.testing.expectEqual(Kind.other, kindOf("01_port.lev"));
}

test safeRelPath {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("background/01_port.bkg", safeRelPath(&buf, "background\\01_port.bkg").?);
    try std.testing.expectEqual(null, safeRelPath(&buf, ""));
    try std.testing.expectEqual(null, safeRelPath(&buf, "..\\evil"));
    try std.testing.expectEqual(null, safeRelPath(&buf, "\\abs"));
    try std.testing.expectEqual(null, safeRelPath(&buf, "c:\\x"));
}

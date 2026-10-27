//! Mod check: what the original exe needs of a game folder the editor changed —
//! archives it can read, scripts that parse and find their #include / #inherit,
//! models and textures that exist and fit its limits, levels that LEVEL_Load names.
//! A problem here is one the original would stumble on (a missing object, a crash),
//! even where the port copes.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const archive = @import("formats.zig").archive;
const resource = @import("formats.zig").resource;
const tex3df = @import("formats.zig").tex3df;
const parser = @import("script.zig").parser;

pub const Problem = struct {
    /// The archive (`common/other.dat`) and its entry ("" — the archive itself).
    archive: []const u8,
    entry: []const u8,
    what: []const u8,
};

const Check = struct {
    io: Io,
    a: Allocator,
    archives: []const []const u8,
    common: archive.Archive,
    out: std.ArrayList(Problem) = .empty,
    /// Models already looked at (lowercase names).
    meshes: std.StringHashMapUnmanaged(void) = .empty,

    fn add(self: *Check, path: []const u8, entry: []const u8, comptime fmt: []const u8, args: anytype) !void {
        try self.out.append(self.a, .{ .archive = path, .entry = entry, .what = try std.fmt.allocPrint(self.a, fmt, args) });
    }
};

/// Every problem of the game folder's `dat` (memory from `a`, an arena).
pub fn run(io: Io, a: Allocator, dat: Io.Dir) ![]Problem {
    var c: Check = .{
        .io = io,
        .a = a,
        .archives = try archive.listArchives(io, a, dat),
        .common = try archive.Archive.open(io, a, dat, "common/other.dat"),
    };
    defer c.common.close(io, a);
    for (c.archives) |path| {
        var arc = archive.Archive.open(io, a, dat, path) catch |err| {
            try c.add(path, "", "can't be read ({t})", .{err});
            continue;
        };
        defer arc.close(io, a);
        if (!arc.wellFormed()) try c.add(path, "", "entries out of order, without a time or a script not marked: the exe misses them (Save or `gorky-tool sortdat` fixes it)", .{});
        for (arc.entries) |*e| {
            if (std.ascii.eqlIgnoreCase(std.fs.path.extension(e.name), ".3df")) {
                const head = try arc.readAlloc(io, a, e);
                checkTexture(&c, path, e.name, head) catch {};
            } else if (resource.isScript(e.name)) {
                try checkScript(&c, path, arc, e.name, try arc.readAlloc(io, a, e));
            }
        }
    }
    return c.out.items;
}

/// The exe's texture limits: power-of-two sides up to 256, at most 8:1.
fn checkTexture(c: *Check, path: []const u8, name: []const u8, bytes: []const u8) !void {
    const h = tex3df.parseHeader(bytes) catch |err| return c.add(path, name, "not a texture the exe reads ({t})", .{err});
    if (!std.math.isPowerOfTwo(h.width) or !std.math.isPowerOfTwo(h.height) or @max(h.width, h.height) > 256 or @max(h.width, h.height) / @min(h.width, h.height) > 8)
        try c.add(path, name, "{d}×{d}: the exe takes power-of-two sides up to 256, at most 8:1", .{ h.width, h.height });
}

fn checkScript(c: *Check, path: []const u8, arc: archive.Archive, name: []const u8, src: []const u8) !void {
    var diag: parser.Diagnostic = .{};
    const unit = parser.parse(c.a, src, &diag) catch |err| return c.add(path, name, "line {d}: {s} ({t})", .{ diag.line, diag.message, err });
    for (unit.items) |it| switch (it) {
        .include => |n| if (resolve(arc, c.common, n) == null) try c.add(path, name, "#include \"{s}\" not found", .{n}),
        // `#inherit Level` → `level.s`.
        .inherit => |n| {
            const file = if (std.fs.path.extension(n).len > 0) n else try std.fmt.allocPrint(c.a, "{s}.s", .{n});
            if (resolve(arc, c.common, file) == null) try c.add(path, name, "#inherit {s}: {s} not found", .{ n, file });
        },
        else => {},
    };
    // References by name in the text (comments skipped).
    var lines = std.mem.splitScalar(u8, src, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = raw[0 .. std.mem.indexOf(u8, raw, "//") orelse raw.len];
        if (quotedAfter(line, "meshFile")) |m| try checkMesh(c, path, name, line_no, m);
        if (quotedAfter(line, "LEVEL_Load")) |lv| if (!levelExists(c, lv))
            try c.add(path, name, "line {d}: LEVEL_Load(\"{s}\"): no such level (dat/{s}/other.dat)", .{ line_no, lv, lv });
    }
}

/// The first `"…"` after `key` on `line` (`key = "x"`, `key("x")`).
fn quotedAfter(line: []const u8, key: []const u8) ?[]const u8 {
    const k = for (0..(line.len + 1) -| key.len) |i| {
        if (std.ascii.startsWithIgnoreCase(line[i..], key)) break i;
    } else return null;
    const q0 = std.mem.indexOfScalarPos(u8, line, k + key.len, '"') orelse return null;
    // Only `=`, `(` and spaces between the key and the quote.
    for (line[k + key.len .. q0]) |ch| if (ch != ' ' and ch != '\t' and ch != '=' and ch != '(') return null;
    const q1 = std.mem.indexOfScalarPos(u8, line, q0 + 1, '"') orelse return null;
    return line[q0 + 1 .. q1];
}

test quotedAfter {
    try std.testing.expectEqualStrings("fang", quotedAfter("  meshFile=\"fang\";", "meshFile").?);
    try std.testing.expectEqualStrings("01_port", quotedAfter("LEVEL_Load( \"01_port\");", "LEVEL_Load").?);
    try std.testing.expect(quotedAfter("meshFile = name;", "meshFile") == null);
    try std.testing.expect(quotedAfter("x = meshFile; y(\"a\")", "meshFile") == null);
}

fn levelExists(c: *Check, level: []const u8) bool {
    for (c.archives) |p| {
        const slash = std.mem.indexOfAny(u8, p, "/\\") orelse continue;
        if (std.ascii.eqlIgnoreCase(p[0..slash], level) and std.ascii.eqlIgnoreCase(p[slash + 1 ..], "other.dat")) return true;
    }
    return false;
}

/// A model named by `meshFile`: its `.msh` and the textures its parts name.
fn checkMesh(c: *Check, path: []const u8, name: []const u8, line_no: usize, mesh: []const u8) !void {
    if (mesh.len == 0) return;
    const key = try std.ascii.allocLowerString(c.a, mesh);
    if ((try c.meshes.getOrPut(c.a, key)).found_existing) return;
    var buf: [archive.name_size]u8 = undefined;
    const e = c.common.find(std.fmt.bufPrint(&buf, "gfx_3d\\{s}.msh", .{mesh}) catch return) orelse
        return c.add(path, name, "line {d}: meshFile \"{s}\": no gfx_3d\\{s}.msh in common/other.dat", .{ line_no, mesh, mesh });
    const bytes = try c.common.readAlloc(c.io, c.a, e);
    // Chunk 9: a part's texture (sizes and kinds as in formats/mesh.zig).
    var pos: usize = 0;
    while (pos + 12 <= bytes.len) {
        const size = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        const kind = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
        if (size < 8 or pos + size > bytes.len) return c.add("common/other.dat", e.name, "broken chunk at {d}", .{pos});
        if (kind == 9 and size >= 12) {
            const raw = bytes[pos + 12 .. pos + size];
            const tex = raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse raw.len];
            if (tex.len > 0 and c.common.find(std.fmt.bufPrint(&buf, "gfx_3d\\textures\\{s}", .{tex}) catch "") == null)
                try c.add("common/other.dat", e.name, "texture {s} not found in gfx_3d\\textures", .{tex});
        }
        pos += size;
    }
}

/// An included script: the level's archive first, then common `classes\` (as the exe).
fn resolve(local: archive.Archive, common: archive.Archive, name: []const u8) ?*const archive.Entry {
    if (local.find(name)) |e| return e;
    var buf: [archive.name_size]u8 = undefined;
    return common.find(std.fmt.bufPrint(&buf, "classes\\{s}", .{name}) catch return null);
}

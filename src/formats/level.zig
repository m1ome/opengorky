//! Static level data: background, walk grids, areas, paths, lights.
//! Objects and scripts live in `state/world.zig`.

const std = @import("std");
const vec = @import("../vec.zig");
const num = @import("../num.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const archive = @import("archive.zig");
const level_files = @import("level_files.zig");
const zbuffer = @import("zbuffer.zig");

/// Background parameters from `background\<level>.cfg` for orthographic levels
/// (parsed by 0x41cc70 in the exe). `frontPlane`/`backPlane` lines are skipped: the camera
/// takes them from the level object's vars (see viewer/level/depth.zig).
pub const OrthoCfg = struct {
    /// Height (world px) that height-map value `g1` maps to.
    gscale: f32 = 200,
    /// Height-map value at ground level.
    g0: f32 = 57088,
    g1: f32 = 27904,

    /// Background surface height for a `.zbf` value.
    pub fn height(self: OrthoCfg, v: u16) f32 {
        return (self.g0 - num.toF32(v)) / (self.g0 - self.g1) * self.gscale;
    }
};

/// `.cfg` of a perspective level (0x41cf07): eye (vx, vy, vz), target (tx, ty, tz)
/// and scene depth `tl`. A `.zbf` value v is depth `far − v·tl/65536`, where
/// far = |eye − target| + tl (W-buffer; v = 0 is the far plane).
const PerspCfg = struct {
    eye: [3]f32 = .{ 0, 0, 0 },
    target: [3]f32 = .{ 0, 0, 0 },
    tl: f32 = -1,

    pub fn far(self: PerspCfg) f32 {
        const d = [3]f32{ self.eye[0] - self.target[0], self.eye[1] - self.target[1], self.eye[2] - self.target[2] };
        return vec.len(d) + self.tl;
    }
};

/// Background point depth for a `.zbf` value (perspective, see PerspCfg).
pub fn perspDepth(far: f32, tl: f32, v: u16) f32 {
    return far - num.toF32(v) * tl / 65536;
}

pub const Level = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    /// Background entry in sprite.dat (`background\<level>.bkg` or `.jpg`), if any.
    background: ?[]const u8,
    // World parses the `.wm`/`.wm2` grids, `.ar` areas, `.ap` paths and the `.cm` battle grid.
    lights: ?level_files.Lights = null,
    /// Orthographic levels only (no `tl` in .cfg).
    ortho: ?OrthoCfg = null,
    /// `.cfg` of a perspective level (14 levels lack it — then tl comes from initCamera).
    persp: ?PerspCfg = null,
    /// Background height map (`.zbf`).
    heights: ?zbuffer.ZBuffer = null,

    pub fn deinit(self: *Level) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn load(io: Io, gpa: Allocator, dat: Io.Dir, name: []const u8) !Level {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var path_buf: [256]u8 = undefined;
    var sprites = try archive.Archive.open(io, gpa, dat, try std.fmt.bufPrint(&path_buf, "{s}/sprite.dat", .{name}));
    defer sprites.close(io, gpa);
    var other = try archive.Archive.open(io, gpa, dat, try std.fmt.bufPrint(&path_buf, "{s}/other.dat", .{name}));
    defer other.close(io, gpa);

    var background: ?[]const u8 = null;
    for ([_][]const u8{ "bkg", "jpg" }) |ext| {
        const bg_name = try std.fmt.bufPrint(&path_buf, "background\\{s}.{s}", .{ name, ext });
        if (sprites.find(bg_name)) |e| {
            background = try a.dupe(u8, e.name);
            break;
        }
    }

    // Everything below lives in the level arena, so parser free functions are not needed.
    var lvl: Level = .{
        .arena = undefined,
        .name = try a.dupe(u8, name),
        .background = background,
    };
    if (try readOptional(io, a, other, &path_buf, name, "lts")) |d| lvl.lights = try level_files.parseLights(a, d);
    if (sprites.find(try std.fmt.bufPrint(&path_buf, "background\\{s}.cfg", .{name}))) |e| {
        const text = try sprites.readAlloc(io, a, e);
        lvl.ortho = parseCfg(text);
        if (lvl.ortho == null) lvl.persp = parsePerspCfg(text);
    }
    if (sprites.find(try std.fmt.bufPrint(&path_buf, "background\\{s}.zbf", .{name}))) |e| {
        lvl.heights = try zbuffer.decode(a, try sprites.readAlloc(io, a, e));
    }
    lvl.arena = arena;
    return lvl;
}

/// Reads `<level>.<ext>` from the archive if present.
fn readOptional(io: Io, a: Allocator, arc: archive.Archive, buf: []u8, name: []const u8, ext: []const u8) !?[]u8 {
    const entry = arc.find(try std.fmt.bufPrint(buf, "{s}.{s}", .{ name, ext })) orelse return null;
    return try arc.readAlloc(io, a, entry);
}

/// Background `.cfg` keys: `name value` per line. null for a perspective level (`tl`).
fn parseCfg(text: []const u8) ?OrthoCfg {
    var cfg: OrthoCfg = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var it = std.mem.tokenizeAny(u8, raw, " \t\r");
        const key = it.next() orelse continue;
        const val = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
        if (std.mem.eql(u8, key, "tl")) return null;
        if (std.mem.eql(u8, key, "gscale")) cfg.gscale = val;
        if (std.mem.eql(u8, key, "g0")) cfg.g0 = val;
        if (std.mem.eql(u8, key, "g1")) cfg.g1 = val;
    }
    return cfg;
}

/// Perspective `.cfg`: vx vy vz tx ty tz tl.
fn parsePerspCfg(text: []const u8) ?PerspCfg {
    var cfg: PerspCfg = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var it = std.mem.tokenizeAny(u8, raw, " \t\r");
        const key = it.next() orelse continue;
        const val = std.fmt.parseFloat(f32, it.next() orelse continue) catch continue;
        const keys = [_][]const u8{ "vx", "vy", "vz", "tx", "ty", "tz" };
        for (keys, 0..) |k, i| if (std.mem.eql(u8, key, k)) {
            if (i < 3) cfg.eye[i] = val else cfg.target[i - 3] = val;
        };
        if (std.mem.eql(u8, key, "tl")) cfg.tl = val;
    }
    return if (cfg.tl > 0) cfg else null;
}

test parsePerspCfg {
    const c = parsePerspCfg("vx 0\nvy 3\nvz -4\ntx 0\nty 0\ntz 0\ntl 2\n").?;
    try std.testing.expectEqual(7, c.far());
    try std.testing.expectEqual(7, perspDepth(c.far(), c.tl, 0));
    try std.testing.expectEqual(6, perspDepth(c.far(), c.tl, 32768));
}

test parseCfg {
    const c = parseCfg("bkg 01_port\r\nfrontPlane 600.000000\r\ngscale 253.000000\r\ng0 57088\r\ng1 27904\r\n").?;
    try std.testing.expectEqual(253, c.gscale);
    try std.testing.expectEqual(0, c.height(57088));
    try std.testing.expectEqual(253, c.height(27904));
    try std.testing.expectEqual(null, parseCfg("vx -10.851\ntl 6.96675\n"));
}

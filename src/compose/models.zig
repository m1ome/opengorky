//! Models from their files: `models/<name>.msh|ani|bfr|2s`, `effects/…`, `textures/…`
//! (loaders/assets.zig; Classic: `common/other.dat: gfx_3d\`) — parsed and handed to the
//! core's model cache (actor/model_cache.zig) as core records (core/model.zig); textures (`.3df` with mip levels) to the renderer's cache
//! (render/textures.zig, `textures`). The editor and gorky-tool look unsaved files up first
//! (`Overlay`) and export the format records.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const assets = @import("../loaders.zig").assets;
const mesh_fmt = @import("../formats.zig").mesh;
const anim = @import("../formats.zig").anim;
const tex3df = @import("../formats.zig").tex3df;
const dsc = @import("../formats.zig").dsc;
const Image = @import("../image.zig").Image;
const core = @import("../core.zig");
const model_cache = @import("../actor.zig").model_cache;
const render_textures = @import("../render.zig").textures;

/// Files looked up before the assets (the editor's unsaved models and textures), by
/// their `common/other.dat` entry name.
pub const Overlay = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,
};

/// A model's files as the formats read them (gltf export, the editor's writes).
const Parsed = struct {
    mesh: mesh_fmt.Mesh,
    anims: anim.AnimList,
    frames: anim.BoneFrames,
};

pub const Files = struct {
    io: Io,
    gpa: Allocator,
    assets: assets.Stack,
    overlay: ?Overlay = null,

    pub fn open(io: Io, gpa: Allocator, dat: Io.Dir) !*Files {
        const f = try gpa.create(Files);
        errdefer gpa.destroy(f);
        f.* = .{ .io = io, .gpa = gpa, .assets = try @import("../loaders.zig").assetStack(io, gpa, dat) };
        errdefer f.assets.deinit();
        // No other.dat, no models (as before the stack).
        _ = try f.assets.archiveOf("common/other.dat");
        return f;
    }

    pub fn close(self: *Files) void {
        self.assets.deinit();
        self.gpa.destroy(self);
    }

    /// The core's model cache over these files (its deinit closes them).
    pub fn cache(self: *Files) model_cache.Cache {
        return .init(self.gpa, .{ .ctx = self, .model = modelOf, .effect = effectOf, .close = closeCtx });
    }

    /// File `path` (logical, `models/x.msh`; overlay first) in `a`; error.NotFound: none.
    pub fn read(self: *Files, a: Allocator, path: []const u8) ![]u8 {
        if (self.overlaid(path)) |d| return a.dupe(u8, d);
        return self.assets.read(a, path);
    }

    fn overlaid(self: *Files, path: []const u8) ?[]const u8 {
        const o = self.overlay orelse return null;
        var bufs: [2][assets.max_path]u8 = undefined;
        const e = assets.toEntry(&bufs, path) orelse return null;
        return o.get(o.ctx, e.name);
    }

    fn has(self: *Files, path: []const u8) bool {
        return self.assets.exists(path) or self.overlaid(path) != null;
    }

    /// Model `name`'s `.msh`, `.ani`, `.bfr` (frames checked against the list), all in
    /// `a` (an arena).
    pub fn parse(self: *Files, a: Allocator, name: []const u8) !Parsed {
        var buf: [assets.max_path]u8 = undefined;
        const msh = try self.read(a, try std.fmt.bufPrint(&buf, "models/{s}.msh", .{name}));
        const mesh = try mesh_fmt.parse(a, msh);
        const anims = try anim.parseAni(a, try self.read(a, try std.fmt.bufPrint(&buf, "models/{s}.ani", .{name})));
        const frames = try anim.parseBfr(a, try self.read(a, try std.fmt.bufPrint(&buf, "models/{s}.bfr", .{name})), @intCast(mesh.boneCount()));
        try anim.checkFrames(anims, frames);
        return .{ .mesh = mesh, .anims = anims, .frames = frames };
    }

    /// Texture `name` (`textures/<name>`), its top level; null: missing or broken.
    pub fn texture(self: *Files, a: Allocator, name: []const u8) ?Image {
        var buf: [assets.max_path]u8 = undefined;
        const bytes = self.read(a, std.fmt.bufPrint(&buf, "textures/{s}", .{name}) catch return null) catch return null;
        return tex3df.decode(a, bytes) catch null;
    }

    /// Texture `name`'s mip levels in `a`; `none` when missing or broken.
    fn mips(self: *Files, a: Allocator, name: []const u8, none: []Image) []Image {
        var buf: [assets.max_path]u8 = undefined;
        const bytes = self.read(a, std.fmt.bufPrint(&buf, "textures/{s}", .{name}) catch return none) catch return none;
        return tex3df.decodeMips(a, bytes) catch none;
    }
};

/// The core's model cache over `dat`'s `common/other.dat` (`overlay` looked up first).
pub fn open(io: Io, gpa: Allocator, dat: Io.Dir, overlay: ?Overlay) !model_cache.Cache {
    const f = try Files.open(io, gpa, dat);
    f.overlay = overlay;
    return f.cache();
}

/// The renderer's textures over the files of `cache` (made by `open`); deinit it before the cache.
pub fn textures(gpa: Allocator, cache: *model_cache.Cache) render_textures.Textures {
    return .init(gpa, .{ .ctx = cache.source.ctx, .mips = mipsAt, .texture = textureAt });
}

fn mipsAt(ctx: ?*anyopaque, a: Allocator, name: []const u8) ?[]Image {
    const m = filesOf(ctx).mips(a, name, &.{});
    return if (m.len > 0) m else null;
}

fn filesOf(ctx: ?*anyopaque) *Files {
    return @ptrCast(@alignCast(ctx.?));
}

fn closeCtx(ctx: ?*anyopaque) void {
    filesOf(ctx).close();
}

fn textureAt(ctx: ?*anyopaque, a: Allocator, path: []const u8) ?Image {
    const f = filesOf(ctx);
    const bytes = f.read(f.gpa, path) catch return null;
    defer f.gpa.free(bytes);
    return tex3df.decode(a, bytes) catch null;
}

/// Effect `name`'s `.dsc` as the core's record in `a`: no header is the D3D default (screen).
fn effectOf(ctx: ?*anyopaque, a: Allocator, name: []const u8) anyerror!@import("../effects.zig").dsc.Dsc {
    var buf: [assets.max_path]u8 = undefined;
    const d = try dsc.parse(a, try filesOf(ctx).read(a, try std.fmt.bufPrint(&buf, "effects/{s}/{s}.dsc", .{ name, name })));
    return .{ .blend = switch (d.header) {
        .none => .screen,
        .alpha => .alpha,
        .add => .add,
    }, .frames = d.frames };
}

/// The parsed files as core records in `a`.
fn modelOf(ctx: ?*anyopaque, a: Allocator, name: []const u8) anyerror!model_cache.Model {
    const f = filesOf(ctx);
    var tmp: std.heap.ArenaAllocator = .init(f.gpa);
    defer tmp.deinit();
    const p = try f.parse(tmp.allocator(), name);
    const mesh = try meshOf(a, p.mesh);
    const fr = framesOf(p.frames);
    var m: model_cache.Model = .{
        .mesh = mesh,
        .anims = .{ .items = try animsOf(a, p.anims.items) },
        .frames = .{ .frames = fr.frames, .bones = fr.bones, .matrices = try a.dupe([12]f32, fr.matrices), .extra = try a.dupe([6]f32, fr.extra) },
    };
    var nb: [assets.max_path]u8 = undefined;
    m.two_sided = f.has(try std.fmt.bufPrint(&nb, "models/{s}.2s", .{name}));
    return m;
}

/// A `.msh` as the core's mesh, copied into `a`.
pub fn meshOf(a: Allocator, m: mesh_fmt.Mesh) Allocator.Error!core.model.Mesh {
    const parts = try a.alloc(core.model.Part, m.parts.len);
    for (parts, m.parts) |*d, p| {
        const vs = try a.alloc(core.model.Vertex, p.vertices.len);
        for (vs, p.vertices) |*v, s| v.* = .{ .pos = s.pos, .uv = s.uv };
        const inf = try a.alloc(core.model.Influence, p.influences.len);
        for (inf, p.influences) |*v, s| v.* = .{ .bone = s.bone, .weight = s.weight };
        d.* = .{ .name = try a.dupe(u8, p.name), .vertices = vs, .ranges = try a.dupe([2]u32, p.ranges), .influences = inf, .triangles = try a.dupe([3]u32, p.triangles), .texture = try a.dupe(u8, p.texture) };
    }
    const holds = try a.alloc(core.model.HoldMode, m.hold_modes.len);
    for (holds, m.hold_modes) |*d, h| d.* = .{ .name = try a.dupe(u8, h.name), .params = h.params, .bone = h.bone };
    return .{
        .name = try a.dupe(u8, m.name),
        .center = m.center,
        .rotation = m.rotation,
        .height = m.height,
        .joints = try a.dupe([3]f32, m.joints),
        .texture = try a.dupe(u8, m.texture),
        .animations = try a.dupe(u8, m.animations),
        .hold_modes = holds,
        .parts = parts,
    };
}

/// An `.ani` list as the core's animations (with their sound cues), copied into `a`.
fn animsOf(a: Allocator, items: []const anim.Animation) Allocator.Error![]core.model.Animation {
    const out = try a.alloc(core.model.Animation, items.len);
    for (out, items) |*d, s| {
        const cues = try a.alloc(core.model.SoundCue, s.sounds.len);
        for (cues, s.sounds) |*c, x| c.* = .{ .name = try a.dupe(u8, x.name), .frame = x.frame, .volume = x.volume };
        d.* = .{ .name = try a.dupe(u8, s.name), .first = s.first, .last = s.last, .speed = s.speed, .sounds = cues };
    }
    return out;
}

/// `.bfr` frames as the core's (a view: the same matrices).
pub fn framesOf(f: anim.BoneFrames) core.model.BoneFrames {
    return .{ .frames = f.frames, .bones = f.bones, .matrices = f.matrices, .extra = f.extra };
}

test "meshOf keeps what the core draws" {
    var verts = [_]mesh_fmt.Vertex{.{ .pos = .{ 1, 2, 3 }, .uv = .{ 0.5, 1 }, .id = 7 }};
    var ranges = [_][2]u32{.{ 0, 1 }};
    var infl = [_]mesh_fmt.Influence{.{ .bone = 2, .weight = 0.25, .percent = 25 }};
    var parts = [_]mesh_fmt.Part{.{ .name = "body", .vertices = &verts, .ranges = &ranges, .influences = &infl, .triangles = &.{}, .texture = "t.3df" }};
    var holds = [_]mesh_fmt.HoldMode{.{ .name = "one_hand", .params = .{ 1, 2, 3, 4, 5, 6 }, .bone = 2 }};
    const m: mesh_fmt.Mesh = .{ .arena = undefined, .center = .{ 0, 9.4, 0 }, .height = 24, .hold_modes = &holds, .parts = &parts };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const c = try meshOf(arena.allocator(), m);
    try std.testing.expectEqual([3]f32{ 1, 2, 3 }, c.parts[0].vertices[0].pos);
    try std.testing.expectEqual(@as(f32, 0.25), c.parts[0].influences[0].weight);
    try std.testing.expectEqualStrings("t.3df", c.parts[0].texture);
    try std.testing.expectEqual(@as(u32, 2), c.holdMode("ONE_HAND").?.bone);
    try std.testing.expectEqual(@as(f32, 9.4), c.center[1]);
}

//! Actor models by `meshFile` name: mesh, animations, bone frames, texture with
//! mip levels (`common/other.dat: gfx_3d\\`), `.dsc` effects. Loaded on first
//! use; the engine needs this cache, not the layer renderer (`actors.zig`).

const std = @import("std");
const vec = @import("../vec.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const archive = @import("../formats.zig").archive;
const mesh_fmt = @import("../formats.zig").mesh;
const anim = @import("../formats.zig").anim;
const tex3df = @import("../formats.zig").tex3df;
const Image = @import("../formats.zig").image.Image;
const effects_mod = @import("../effects.zig");
const camera = @import("camera.zig");
const skin = @import("skin.zig");

/// Default actorScale (0x421907).
pub const default_actor_scale: f32 = 0.15;

pub const Model = struct {
    mesh: mesh_fmt.Mesh,
    anims: anim.AnimList,
    frames: anim.BoneFrames,
    texture: ?Image,
    /// Texture mip levels (`mips[0]` is `texture` itself): the exe picks a level with
    /// MIPLINEAR filtering (0x406d90); without them fine detail shimmers.
    mips: []Image = &.{},
    /// Lowest and highest bind-pose points along the mesh Y axis (feet, top of head).
    base_y: f32,
    top_y: f32,
    /// Mesh rotation by the chunk 14 angles.
    local: [9]f32,
    /// Vertex welding for normals (0x4c6e07): for each part vertex, the first vertex
    /// with the same bind-pose coordinates (smooth across UV seams).
    weld: []const []const u32 = &.{},

    /// World units per mesh unit at actorScale = 1: the model's own scale from
    /// chunk 12 (mesh `+0x5c`, multiplied at 0x429311).
    pub fn unitScale(self: Model) f32 {
        return if (self.mesh.height > 0) self.mesh.height else 24;
    }

    fn deinit(self: *Model, gpa: Allocator) void {
        if (self.mips.len > 0) {
            for (self.mips) |*t| t.deinit(gpa);
            gpa.free(self.mips);
        } else if (self.texture) |*t| t.deinit(gpa);
        self.frames.deinit(gpa);
        self.anims.deinit();
        self.mesh.deinit();
    }

    /// Global .bfr frame for an animation and the ticks since it started.
    pub fn frameOf(self: Model, anim_name: []const u8, ticks: f32, loop: bool) u32 {
        const a = self.anims.find(anim_name) orelse return 0;
        const len = a.last - a.first + 1;
        // One frame per tick (30 Hz); the exe ignores the `.ani` `speed` when showing.
        const n: u32 = @intFromFloat(@max(0, ticks));
        return a.first + if (loop) n % len else @min(n, len - 1);
    }
};

/// Models by `meshFile` name (case-insensitive), loaded on first use.
pub const Cache = struct {
    gpa: Allocator,
    io: Io,
    common: archive.Archive,
    /// File bytes: model strings point into them.
    arena: std.heap.ArenaAllocator,
    models: std.StringHashMapUnmanaged(?*Model) = .empty,
    effects: std.StringHashMapUnmanaged(?*effects_mod.dsc.Dsc) = .empty,

    pub fn open(io: Io, gpa: Allocator, dat: Io.Dir) !Cache {
        return .{ .gpa = gpa, .io = io, .common = try archive.Archive.open(io, gpa, dat, "common/other.dat"), .arena = .init(gpa) };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.models.valueIterator();
        while (it.next()) |m| if (m.*) |model| {
            model.deinit(self.gpa);
            self.gpa.destroy(model);
        };
        self.models.deinit(self.gpa);
        self.effects.deinit(self.gpa);
        self.arena.deinit();
        self.common.close(self.io, self.gpa);
    }

    pub fn get(self: *Cache, name: []const u8) ?*Model {
        var key_buf: [archive.name_size]u8 = undefined;
        if (name.len == 0 or name.len > key_buf.len) return null;
        const key = std.ascii.lowerString(&key_buf, name);
        if (self.models.get(key)) |m| return m;
        const m = self.load(name) catch |err| blk: {
            std.log.warn("model {s}: {t}", .{ name, err });
            break :blk null;
        };
        const a = self.arena.allocator();
        self.models.put(self.gpa, a.dupe(u8, key) catch return m, m) catch {};
        return m;
    }

    /// Effect `gfx_3d\Effects\<name>\<name>.dsc` (case-insensitive): frames and blending.
    pub fn effect(self: *Cache, name: []const u8) ?*const effects_mod.dsc.Dsc {
        var key_buf: [64]u8 = undefined;
        if (name.len == 0 or name.len > key_buf.len) return null;
        const key = std.ascii.lowerString(&key_buf, name);
        if (self.effects.get(key)) |d| return d;
        const d: ?*effects_mod.dsc.Dsc = blk: {
            const text = self.read("gfx_3d\\Effects\\{s}\\{s}.dsc", .{ name, name }) catch break :blk null;
            const dsc = self.arena.allocator().create(effects_mod.dsc.Dsc) catch break :blk null;
            dsc.* = effects_mod.dsc.parseDsc(self.arena.allocator(), text) catch break :blk null;
            break :blk dsc;
        };
        self.effects.put(self.gpa, self.arena.allocator().dupe(u8, key) catch return d, d) catch {};
        return d;
    }

    /// A `common/other.dat` file (effect frame etc.), in the cache arena.
    pub fn readFile(self: *Cache, name: []const u8) ![]u8 {
        return self.read("{s}", .{name});
    }

    fn read(self: *Cache, comptime fmt: []const u8, args: anytype) ![]u8 {
        var buf: [archive.name_size]u8 = undefined;
        const e = self.common.find(try std.fmt.bufPrint(&buf, fmt, args)) orelse return error.NotFound;
        return self.common.readAlloc(self.io, self.arena.allocator(), e);
    }

    fn load(self: *Cache, name: []const u8) !*Model {
        const m = try self.gpa.create(Model);
        errdefer self.gpa.destroy(m);
        m.mesh = try mesh_fmt.parse(self.gpa, try self.read("gfx_3d\\{s}.msh", .{name}));
        errdefer m.mesh.deinit();
        m.anims = try anim.parseAni(self.gpa, try self.read("gfx_3d\\{s}.ani", .{name}));
        errdefer m.anims.deinit();
        m.frames = try anim.parseBfr(self.gpa, try self.read("gfx_3d\\{s}.bfr", .{name}), @intCast(m.mesh.boneCount()));
        errdefer m.frames.deinit(self.gpa);
        try anim.checkFrames(m.anims, m.frames);
        m.mips = if (self.read("gfx_3d\\textures\\{s}", .{m.mesh.texture})) |d| tex3df.decodeMips(self.gpa, d) catch &.{} else |_| &.{};
        m.texture = if (m.mips.len > 0) m.mips[0] else null;
        m.local = camera.rotationXYZ(m.mesh.rotation);
        m.base_y = std.math.inf(f32);
        m.top_y = -std.math.inf(f32);
        for (m.mesh.parts) |p| for (p.vertices) |v| {
            m.base_y = @min(m.base_y, v.pos[1]);
            m.top_y = @max(m.top_y, v.pos[1]);
        };
        const a = self.arena.allocator();
        const weld = try a.alloc([]u32, m.mesh.parts.len);
        for (m.mesh.parts, weld) |p, *wp| {
            wp.* = try a.alloc(u32, p.vertices.len);
            for (p.vertices, 0..) |v, i| {
                wp.*[i] = @intCast(i);
                for (p.vertices[0..i], 0..) |u, j| if (u.pos[0] == v.pos[0] and u.pos[1] == v.pos[1] and u.pos[2] == v.pos[2]) {
                    wp.*[i] = wp.*[j];
                    break;
                };
            }
        }
        m.weld = weld;
        return m;
    }
};

/// Mesh point of `owner` (mesh units) in the world: local axes, scale `s`, rotation by
/// angle (cos `ca`, sin `sa`) and position. Mesh Y up → world Z up (0x44edb0).
pub fn toWorld(owner: *const Model, pt: [3]f32, s: f32, pos: [3]f32, ca: f32, sa: f32) [3]f32 {
    return toWorldLocal(localPoint(owner, pt), s, pos, ca, sa);
}

/// Same for a point already in mesh local axes (after `localPoint`).
pub fn toWorldLocal(v: [3]f32, s: f32, pos: [3]f32, ca: f32, sa: f32) [3]f32 {
    const mx = v[0] * s;
    const my = v[2] * s;
    return .{ pos[0] + mx * ca - my * sa, pos[1] + mx * sa + my * ca, pos[2] + v[1] * s };
}

/// Attachment point `name` of the model at a frame (mesh units, before local axes).
pub fn linkPoint(model: *const Model, frame: u32, name: []const u8) ?[3]f32 {
    return linkPointOff(model, frame, name, .{ 0, 0, 0 });
}

/// Attachment point shifted by `off` in bone axes before its matrix (0x429ca0: the second
/// output is the same point with x + 1 — how the exe gets the point's axis, e.g. a rifle barrel).
pub fn linkPointOff(model: *const Model, frame: u32, name: []const u8, off: [3]f32) ?[3]f32 {
    const h = model.mesh.holdMode(name) orelse return null;
    if (model.frames.bones == 0 or h.bone >= model.frames.bones) return null;
    const j = model.mesh.joints[h.bone];
    return skin.transform(model.frames.matrix(frame, h.bone), .{ j[0] + h.params[0] + off[0], j[1] + h.params[1] + off[1], j[2] + h.params[2] + off[2] }, .row);
}

/// Mesh vertex in its local axes (0x44c060 without scale): R·v + shift.
pub fn localPoint(model: *const Model, v: [3]f32) [3]f32 {
    return vec.add(camera.mulVec(model.local, v), model.mesh.center);
}

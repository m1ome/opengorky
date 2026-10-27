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
    /// Each part's own texture (mip levels): chunk 9 sets the texture of the part
    /// being read (0x44cf3a → 0x44d7b0, part +0x6c), so a model can have several
    /// (fang: `pasozyt` on the back with `fangtyl`, the body with
    /// `fang_poprawiany`). Parts without one of their own share `mips`.
    part_mips: []const []Image = &.{},
    /// Lowest and highest bind-pose points along the mesh Y axis (feet, top of head).
    base_y: f32,
    top_y: f32,
    /// Mesh rotation by the chunk 14 angles.
    local: [9]f32,
    /// Vertex welding for normals (0x4c6e07): for each part vertex, the first vertex
    /// with the same bind-pose coordinates (smooth across UV seams).
    weld: []const []const u32 = &.{},
    /// `gfx_3d\<name>.2s` exists (chaingun, wave): the exe zeroes the triangles' planes
    /// (0x44d213 → 0x44bf30 → 0x4c6950), so no back face is skipped and none casts a shadow.
    two_sided: bool = false,

    /// Mip levels of part `pi`'s texture (none: `mips`).
    pub fn partMips(self: Model, pi: usize) []Image {
        return if (pi < self.part_mips.len) self.part_mips[pi] else self.mips;
    }

    /// Texture of part `pi` (its top mip level).
    pub fn partTexture(self: Model, pi: usize) ?Image {
        const m = self.partMips(pi);
        return if (m.len > 0) m[0] else self.texture;
    }

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

pub const Overlay = struct {
    ctx: *anyopaque,
    get: *const fn (ctx: *anyopaque, name: []const u8) ?[]const u8,
};

/// Models by `meshFile` name (case-insensitive), loaded on first use.
pub const Cache = struct {
    gpa: Allocator,
    io: Io,
    common: archive.Archive,
    /// File bytes: model strings point into them.
    arena: std.heap.ArenaAllocator,
    models: std.StringHashMapUnmanaged(?*Model) = .empty,
    /// Files looked up before the archive (the editor's unsaved models and textures).
    overlay: ?Overlay = null,
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
        const name = try std.fmt.bufPrint(&buf, fmt, args);
        if (self.overlay) |o| if (o.get(o.ctx, name)) |d| return self.arena.allocator().dupe(u8, d);
        const e = self.common.find(name) orelse return error.NotFound;
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
        // Other parts' textures, decoded once per name (the cache's arena owns them).
        const pm = try self.arena.allocator().alloc([]Image, m.mesh.parts.len);
        for (m.mesh.parts, pm, 0..) |p, *dst, i| {
            dst.* = m.mips;
            if (p.texture.len == 0 or std.ascii.eqlIgnoreCase(p.texture, m.mesh.texture)) continue;
            dst.* = for (m.mesh.parts[0..i], pm[0..i]) |q, prev| {
                if (std.ascii.eqlIgnoreCase(q.texture, p.texture)) break prev;
            } else if (self.read("gfx_3d\\textures\\{s}", .{p.texture})) |d| tex3df.decodeMips(self.arena.allocator(), d) catch m.mips else |_| m.mips;
        }
        m.part_mips = pm;
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
        var nb: [archive.name_size]u8 = undefined;
        const two = try std.fmt.bufPrint(&nb, "gfx_3d\\{s}.2s", .{name});
        m.two_sided = self.common.find(two) != null or (if (self.overlay) |o| o.get(o.ctx, two) != null else false);
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

/// The start pose's bone after an off-place animation (0x4234e2…0x4235b0): translation
/// minus `s` (x, y, z), then rows (row vectors) times the turn by `s[3]` about the height axis.
pub fn unshift(m: [12]f32, s: [4]f32) [12]f32 {
    const c = @cos(s[3]);
    const sn = @sin(s[3]);
    var out = m;
    for (0..3) |k| out[9 + k] -= s[k];
    for (0..4) |r| {
        const x = out[r * 3];
        const z = out[r * 3 + 2];
        out[r * 3] = x * c + z * sn;
        out[r * 3 + 2] = z * c - x * sn;
    }
    return out;
}

/// The model with one frame: bone matrices lerped element-wise from frame `from` (or the
/// drawn pose `from_pose`, one matrix per bone) to `to` by `w` (0x44fd30, the transition
/// into a new animation).
/// `shift` takes an off-place animation's end out of the start pose (`unshift`).
pub fn blended(arena: std.mem.Allocator, model: *const Model, from: u32, from_pose: ?[]const [12]f32, shift: [4]f32, to: u32, w: f32) std.mem.Allocator.Error!*const Model {
    const out = try arena.create(Model);
    out.* = model.*;
    const fr = model.frames;
    if (fr.bones == 0) return out;
    const mats = try arena.alloc([12]f32, fr.bones);
    // A pose of another skeleton (drawn before a morph) isn't lerped: the exe reads past it.
    const pose = if (from_pose) |p| (if (p.len == fr.bones) p else null) else null;
    for (mats, 0..) |*m, b| for (m, unshift(if (pose) |p| p[b] else fr.matrix(@min(from, fr.frames - 1), @intCast(b)).*, shift), fr.matrix(@min(to, fr.frames - 1), @intCast(b))) |*d, a, c| {
        d.* = a * (1 - w) + c * w;
    };
    out.frames = .{ .frames = 1, .bones = fr.bones, .matrices = mats, .extra = fr.extra };
    return out;
}

test blended {
    var mats = [_][12]f32{ @splat(0), @splat(9) };
    var m: Model = undefined;
    m.frames = .{ .frames = 2, .bones = 1, .matrices = &mats, .extra = &.{} };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const b = try blended(arena.allocator(), &m, 0, null, @splat(0), 1, 1.0 / 9.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1), b.frames.matrix(0, 0)[5], 1e-5);
    // From a drawn half-blended pose (0x44f9e2): 4.5 → 9 by 1/9 = 5.
    const half = [_][12]f32{@splat(4.5)};
    const p = try blended(arena.allocator(), &m, 0, &half, @splat(0), 1, 1.0 / 9.0);
    try std.testing.expectApproxEqAbs(@as(f32, 5), p.frames.matrix(0, 0)[0], 1e-5);
    // After an off-place animation the start pose's translation comes back by its shift
    // (0x4234e2): x 0 − 9 → 9 by 1/9 = −7, rotation untouched.
    const s = try blended(arena.allocator(), &m, 0, null, .{ 9, 0, 0, 0 }, 1, 1.0 / 9.0);
    try std.testing.expectApproxEqAbs(@as(f32, -7), s.frames.matrix(0, 0)[9], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), s.frames.matrix(0, 0)[0], 1e-5);
}

test unshift {
    // A bone turned by 90° (row x → z) with the actor now turned by it too: the start pose
    // comes back to identity (0x47cd30 bone·R), translation (1, 0, 0) − shift turned along.
    const t = [12]f32{ 0, 0, 1, 0, 1, 0, -1, 0, 0, 3, 0, 0 };
    const u = unshift(t, .{ 2, 0, 0, std.math.pi / 2.0 });
    for ([_]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, -1 }, u) |e, v| try std.testing.expectApproxEqAbs(e, v, 1e-5);
}

/// Mesh vertex in its local axes (0x44c060 without scale): R·v + shift.
pub fn localPoint(model: *const Model, v: [3]f32) [3]f32 {
    return vec.add(camera.mulVec(model.local, v), model.mesh.center);
}

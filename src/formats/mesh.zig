//! 3D models `.msh` (`common/other.dat: gfx_3d\*.msh`).
//!
//! The file is a sequence of chunks `u32 size (with header), u32 type, data`
//! (loader 0x44c6c0 in the exe). A model has several parts, each with its own
//! vertices, triangles and skeleton bone influences.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Vertex = struct {
    pos: [3]f32,
    uv: [2]f32,
};

const Influence = struct {
    bone: u32,
    /// 0..1 (percent in the file).
    weight: f32,
};

const Part = struct {
    name: []const u8,
    vertices: []Vertex,
    /// Per vertex, a range `[start, end)` into `influences`.
    ranges: [][2]u32,
    influences: []Influence,
    triangles: [][3]u16,
    /// Part texture (chunk 9 after this part's chunk 3; menus have one per part).
    texture: []const u8 = "",
};

/// Weapon hold mode (`default`, `two_hands`, `one_hand`) and the hand bone.
pub const HoldMode = struct {
    name: []const u8,
    /// Offset from the bone joint (x, y, z) and rotation angles around X, Y, Z
    /// (0x3c-byte record: name, +0x20 offset, +0x2c angles, +0x38 bone; 0x4290f0).
    params: [6]f32,
    bone: u32,
};

pub const Mesh = struct {
    arena: std.heap.ArenaAllocator,
    /// Chunk 11 (+0x28): model shift to the origin — (0, 9.4, 0) on heroes puts
    /// animation feet on the ground (0x44c060: v' = height·(R·v + shift)).
    center: [3]f32 = .{ 0, 0, 0 },
    /// Chunk 14 (+0x34): model rotation around X, Y, Z in radians
    /// (π around Y on the hornet, stinger and shoggoth; on weapons — the in-hand pose).
    rotation: [3]f32 = .{ 0, 0, 0 },
    /// Chunk 12: model height.
    height: f32 = 0,
    /// Chunk 1: joint points in the bind pose (one per bone).
    joints: [][3]f32 = &.{},
    texture: []const u8 = "",
    animations: []const u8 = "",
    hold_modes: []HoldMode = &.{},
    parts: []Part = &.{},

    pub fn deinit(self: *Mesh) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn boneCount(self: Mesh) usize {
        return self.joints.len;
    }

    /// Attachment point by name (case-insensitive), first match.
    pub fn holdMode(self: Mesh, name: []const u8) ?HoldMode {
        for (self.hold_modes) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h;
        return null;
    }
};

const Error = error{ Truncated, BadChunk } || Allocator.Error;

const Reader = struct {
    b: []const u8,
    pos: usize = 0,

    fn u32_(self: *Reader) Error!u32 {
        if (self.pos + 4 > self.b.len) return error.Truncated;
        defer self.pos += 4;
        return std.mem.readInt(u32, self.b[self.pos..][0..4], .little);
    }
    fn u16_(self: *Reader) Error!u16 {
        if (self.pos + 2 > self.b.len) return error.Truncated;
        defer self.pos += 2;
        return std.mem.readInt(u16, self.b[self.pos..][0..2], .little);
    }
    fn f32_(self: *Reader) Error!f32 {
        return @bitCast(try self.u32_());
    }
    fn vec3(self: *Reader) Error![3]f32 {
        return .{ try self.f32_(), try self.f32_(), try self.f32_() };
    }
    fn bytes(self: *Reader, n: usize) Error![]const u8 {
        if (self.pos + n > self.b.len) return error.Truncated;
        defer self.pos += n;
        return self.b[self.pos..][0..n];
    }
    /// A `u32 length` + bytes string (no terminating zero).
    fn string(self: *Reader) Error![]const u8 {
        const raw = try self.bytes(try self.u32_());
        return raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse raw.len];
    }
    fn count(self: *Reader, elem_size: usize) Error!u32 {
        const n = try self.u32_();
        if (@as(u64, n) * elem_size > self.b.len - self.pos) return error.Truncated;
        return n;
    }
};

/// Result strings point into `bytes`.
pub fn parse(gpa: Allocator, bytes: []const u8) Error!Mesh {
    var mesh: Mesh = .{ .arena = .init(gpa) };
    errdefer mesh.arena.deinit();
    const a = mesh.arena.allocator();

    var parts: std.ArrayList(Part) = .empty;
    var cur: ?*Part = null;
    var pos: usize = 0;
    while (pos + 8 <= bytes.len) {
        const size = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        const kind = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
        if (size < 8 or pos + size > bytes.len) return error.BadChunk;
        var r: Reader = .{ .b = bytes[pos + 8 .. pos + size] };
        pos += size;
        switch (kind) {
            0 => _ = try r.string(), // model name (always empty)
            1 => {
                mesh.joints = try a.alloc([3]f32, try r.count(12));
                for (mesh.joints) |*j| j.* = try r.vec3();
            },
            2 => {
                const p = try parts.addOne(a);
                p.* = .{ .name = "", .vertices = &.{}, .ranges = &.{}, .influences = &.{}, .triangles = &.{} };
                cur = p;
            },
            3 => (cur orelse return error.BadChunk).name = try r.string(),
            4 => {
                const p = cur orelse return error.BadChunk;
                p.vertices = try a.alloc(Vertex, try r.count(22));
                // x y z u v, then a u16 vertex index (unused).
                for (p.vertices) |*v| {
                    v.* = .{ .pos = try r.vec3(), .uv = .{ try r.f32_(), try r.f32_() } };
                    _ = try r.u16_();
                }
            },
            5 => {
                const p = cur orelse return error.BadChunk;
                p.ranges = try a.alloc([2]u32, try r.count(8));
                for (p.ranges) |*rg| rg.* = .{ try r.u32_(), try r.u32_() };
            },
            6 => {
                const p = cur orelse return error.BadChunk;
                p.triangles = try a.alloc([3]u16, try r.count(6));
                for (p.triangles) |*t| t.* = .{ try r.u16_(), try r.u16_(), try r.u16_() };
            },
            7 => {
                const p = cur orelse return error.BadChunk;
                p.influences = try a.alloc(Influence, try r.count(8));
                for (p.influences) |*inf| inf.* = .{ .bone = try r.u32_(), .weight = try r.f32_() * 0.01 };
            },
            8 => _ = try r.u32_(), // part count is only a capacity hint; reserving after chunk 2 would leave cur dangling
            9 => {
                mesh.texture = try r.bytes(try r.u32_());
                if (cur) |p| p.texture = mesh.texture;
            },
            10 => mesh.animations = (try r.bytes(try r.u32_())),
            11 => mesh.center = try r.vec3(),
            12 => mesh.height = try r.f32_(),
            13 => {
                // Record: string, 6 × f32, u32 hand bone.
                mesh.hold_modes = try a.alloc(HoldMode, try r.count(32));
                for (mesh.hold_modes) |*h| {
                    h.name = try r.string();
                    for (&h.params) |*v| v.* = try r.f32_();
                    h.bone = try r.u32_();
                }
            },
            14 => mesh.rotation = try r.vec3(),
            else => return error.BadChunk,
        }
    }
    mesh.parts = try parts.toOwnedSlice(a);
    try validate(mesh);
    return mesh;
}

fn validate(mesh: Mesh) Error!void {
    for (mesh.parts) |p| {
        if (p.ranges.len != p.vertices.len) return error.BadChunk;
        for (p.ranges) |rg| if (rg[0] > rg[1] or rg[1] > p.influences.len) return error.BadChunk;
        for (p.influences) |inf| if (inf.bone >= mesh.joints.len) return error.BadChunk;
        for (p.triangles) |t| for (t) |i| if (i >= p.vertices.len) return error.BadChunk;
    }
}

fn chunk(comptime kind: u32, comptime payload: []const u8) []const u8 {
    var hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], 8 + payload.len, .little);
    std.mem.writeInt(u32, hdr[4..8], kind, .little);
    return &hdr ++ payload;
}

fn le(comptime T: type, comptime v: T) [@sizeOf(T)]u8 {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(@Int(.unsigned, @bitSizeOf(T)), &b, @bitCast(v), .little);
    return b;
}

test "parse minimal mesh" {
    const gpa = std.testing.allocator;
    const inf100 = comptime le(u32, 0) ++ le(f32, 100);
    const vert = comptime le(f32, 1) ++ le(f32, 2) ++ le(f32, 3) ++ le(f32, 0.5) ++ le(f32, 0.25) ++ le(u16, 0);
    const bytes = comptime chunk(1, &(le(u32, 1) ++ le(f32, 0) ++ le(f32, 5) ++ le(f32, 0))) ++
        chunk(9, &le(u32, 3) ++ "a.3") ++
        chunk(8, &le(u32, 1)) ++
        chunk(2, "") ++
        chunk(3, &le(u32, 4) ++ "body") ++
        chunk(4, &(le(u32, 3) ++ vert ++ vert ++ vert)) ++
        chunk(5, &(le(u32, 3) ++ le(u32, 0) ++ le(u32, 1) ++ le(u32, 1) ++ le(u32, 2) ++ le(u32, 2) ++ le(u32, 3))) ++
        chunk(6, &(le(u32, 1) ++ le(u16, 0) ++ le(u16, 1) ++ le(u16, 2))) ++
        chunk(7, &(le(u32, 3) ++ inf100 ++ inf100 ++ inf100));
    var m = try parse(gpa, bytes);
    defer m.deinit();
    try std.testing.expectEqual(1, m.boneCount());
    try std.testing.expectEqualStrings("a.3", m.texture);
    try std.testing.expectEqualStrings("body", m.parts[0].name);
    try std.testing.expectEqual([2]f32{ 0.5, 0.25 }, m.parts[0].vertices[2].uv);
    try std.testing.expectEqual(1.0, m.parts[0].influences[0].weight);
}

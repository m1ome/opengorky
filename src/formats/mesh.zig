//! 3D models `.msh` (`common/other.dat: gfx_3d\*.msh`).
//!
//! The file is a sequence of chunks `u32 size (with header), u32 type, data`
//! (loader 0x44c6c0 in the exe). A model has several parts, each with its own
//! vertices, triangles and skeleton bone influences.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Vertex = struct {
    pos: [3]f32,
    uv: [2]f32,
    /// The u16 after each vertex (the exporter's vertex number; the exe skips it).
    id: u16 = 0,
};

pub const Influence = struct {
    bone: u32,
    /// 0..1 (percent in the file).
    weight: f32,
    /// The file's percent, written back while `weight` still comes from it.
    percent: f32 = 0,
};

pub const Part = struct {
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
    /// Chunk 0: model name (empty but in four models).
    name: []const u8 = "",
    /// Chunk 11 (+0x28): model shift to the origin — (0, 9.4, 0) on heroes puts
    /// animation feet on the ground (0x44c060: v' = height·(R·v + shift)).
    center: [3]f32 = .{ 0, 0, 0 },
    /// Chunk 14 (+0x34): model rotation around X, Y, Z in radians
    /// (π around Y on the hornet, stinger and shoggoth; on weapons — the in-hand pose).
    rotation: [3]f32 = .{ 0, 0, 0 },
    /// Chunk 14 was in the file (76 models have it with zero angles, 22 lack it).
    has_rotation: bool = false,
    /// Chunk 12: model height.
    height: f32 = 0,
    /// Chunk 1: joint points in the bind pose (one per bone).
    joints: [][3]f32 = &.{},
    texture: []const u8 = "",
    animations: []const u8 = "",
    hold_modes: []HoldMode = &.{},
    parts: []Part = &.{},
    /// Chunks of other types: the exe skips them (0x44d156 → 0x44be20); kept for `encode`.
    unknown: []Unknown = &.{},

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

/// A chunk `parse` does not read and the parts read before it (0: before the parts).
const Unknown = struct { kind: u32, data: []const u8, after: usize };

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
    var unknown: std.ArrayList(Unknown) = .empty;
    var cur: ?*Part = null;
    var pos: usize = 0;
    while (pos + 8 <= bytes.len) {
        const size = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        const kind = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
        if (size < 8 or pos + size > bytes.len) return error.BadChunk;
        var r: Reader = .{ .b = bytes[pos + 8 .. pos + size] };
        pos += size;
        switch (kind) {
            0 => mesh.name = try r.string(),
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
                    v.* = .{ .pos = try r.vec3(), .uv = .{ try r.f32_(), try r.f32_() }, .id = try r.u16_() };
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
                for (p.influences) |*inf| {
                    const bone = try r.u32_();
                    const pc = try r.f32_();
                    inf.* = .{ .bone = bone, .weight = pc * 0.01, .percent = pc };
                }
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
            14 => {
                mesh.rotation = try r.vec3();
                mesh.has_rotation = true;
            },
            else => try unknown.append(a, .{ .kind = kind, .data = r.b, .after = parts.items.len }),
        }
    }
    mesh.parts = try parts.toOwnedSlice(a);
    mesh.unknown = try unknown.toOwnedSlice(a);
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

/// The exe's limits on a model (loader 0x44c6c0, renderers 0x446f20/0x447460):
/// - every string is read into a 128-byte stack buffer with no length check
///   (chunks 0/3/9/10/13 at ebp−0x4c8…−0x2c8): longer smashes the stack;
/// - part and attach point names are strncpy'd into 32 bytes (0x44ca74, 0x44bd90):
///   31 characters keep the zero the lookups need;
/// - the texture path `gfx_3d\textures\<name>` goes into a 64-byte name in the
///   texture cache (0x432fe0), so names up to 47 characters;
/// - the renderers' vertex caches have 1024 entries (0x64ac70, 0x648c70) and the
///   index buffer 6144 u16 (0x63e0e8): at most 1024 vertices and 2048 triangles a part,
///   no bounds checks there;
/// - triangle indices are not checked against the vertex count (0x44cdf6), and the
///   first triangle with a repeated index cuts the part's triangles off (0x4c6f55);
/// - ranges are kept as u16 (0x44cc70) and walked per vertex (0x44d1bd), influence and
///   attach point bones index the frame's matrices unchecked (0x4c67e8, 0x4291f2).
const max_string = 127;
pub const no_bone = std.math.maxInt(u32);
const max_name = 31;
const max_texture = 47;
const max_part_vertices = 1024;
const max_part_triangles = 2048;

const LimitError = error{ StringTooLong, NameTooLong, TooManyVertices, TooManyTriangles, BadTriangle, BadRanges, BadBone };

/// Whether the exe can load and draw `m` (see the limits above).
pub fn checkLimits(m: Mesh) LimitError!void {
    for ([_][]const u8{ m.name, m.texture, m.animations }) |s| if (s.len > max_string) return error.StringTooLong;
    for (m.hold_modes) |h| {
        if (h.name.len > max_name) return error.NameTooLong;
        // Bone −1: a point in model space (ponton, which has no bones).
        if (h.bone >= m.joints.len and h.bone != no_bone) return error.BadBone;
    }
    for (m.parts) |p| {
        if (p.name.len > max_name or p.texture.len > max_texture) return error.NameTooLong;
        if (p.vertices.len > max_part_vertices) return error.TooManyVertices;
        if (p.triangles.len > max_part_triangles) return error.TooManyTriangles;
        for (p.triangles) |t| {
            if (t[0] == t[1] or t[1] == t[2] or t[0] == t[2]) return error.BadTriangle;
            for (t) |i| if (i >= p.vertices.len) return error.BadTriangle;
        }
        if (p.ranges.len != p.vertices.len or p.influences.len > 0xffff) return error.BadRanges;
        for (p.ranges) |rg| if (rg[0] > rg[1] or rg[1] > p.influences.len) return error.BadRanges;
        for (p.influences) |inf| if (inf.bone >= m.joints.len) return error.BadBone;
    }
}

/// The `.msh` bytes of `m` in the order the game's files have (0, 11, 14, 12, 1, 13,
/// 10, 8, then per part 2, 3, 9, 4, 5, 6, 7); unknown chunks go back after the part
/// they followed. Every game model comes back byte for byte (`gorky-tool models`).
pub fn encode(gpa: Allocator, m: Mesh) Allocator.Error![]u8 {
    var w: Writer = .{ .gpa = gpa };
    errdefer w.out.deinit(gpa);
    try w.begin(0);
    try w.str(m.name);
    try w.begin(11);
    try w.vec(&m.center);
    if (m.has_rotation or !std.meta.eql(m.rotation, [3]f32{ 0, 0, 0 })) {
        try w.begin(14);
        try w.vec(&m.rotation);
    }
    try w.begin(12);
    try w.f32_(m.height);
    try w.begin(1);
    try w.u32_(@intCast(m.joints.len));
    for (m.joints) |j| try w.vec(&j);
    try w.begin(13);
    try w.u32_(@intCast(m.hold_modes.len));
    for (m.hold_modes) |h| {
        try w.str(h.name);
        try w.vec(&h.params);
        try w.u32_(h.bone);
    }
    try w.begin(10);
    try w.str(m.animations);
    try w.unknown(m, 0);
    try w.begin(8);
    try w.u32_(@intCast(m.parts.len));
    for (m.parts, 1..) |p, i| {
        try w.begin(2);
        try w.begin(3);
        try w.str(p.name);
        try w.begin(9);
        try w.str(if (p.texture.len > 0) p.texture else m.texture);
        try w.begin(4);
        try w.u32_(@intCast(p.vertices.len));
        for (p.vertices) |v| {
            try w.vec(&v.pos);
            try w.vec(&v.uv);
            try w.bytes(&std.mem.toBytes(std.mem.nativeToLittle(u16, v.id)));
        }
        try w.begin(5);
        try w.u32_(@intCast(p.ranges.len));
        for (p.ranges) |rg| try w.vec(&rg);
        try w.begin(6);
        try w.u32_(@intCast(p.triangles.len));
        for (p.triangles) |t| for (t) |k| try w.bytes(&std.mem.toBytes(std.mem.nativeToLittle(u16, k)));
        try w.begin(7);
        try w.u32_(@intCast(p.influences.len));
        for (p.influences) |inf| {
            try w.u32_(inf.bone);
            // An edited weight drops the file's percent.
            try w.f32_(if (inf.percent * 0.01 == inf.weight) inf.percent else inf.weight * 100);
        }
        try w.unknown(m, i);
    }
    try w.end();
    return w.out.toOwnedSlice(gpa);
}

const Writer = struct {
    gpa: Allocator,
    out: std.ArrayList(u8) = .empty,
    /// Start of the open chunk (its size is written when the next one begins).
    open: ?usize = null,

    fn bytes(w: *Writer, b: []const u8) Allocator.Error!void {
        try w.out.appendSlice(w.gpa, b);
    }
    fn u32_(w: *Writer, v: u32) Allocator.Error!void {
        try w.bytes(&std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
    }
    fn f32_(w: *Writer, v: f32) Allocator.Error!void {
        try w.u32_(@bitCast(v));
    }
    /// f32 or u32 items.
    fn vec(w: *Writer, v: anytype) Allocator.Error!void {
        for (v) |x| if (@TypeOf(x) == f32) try w.f32_(x) else try w.u32_(x);
    }
    fn str(w: *Writer, s: []const u8) Allocator.Error!void {
        try w.u32_(@intCast(s.len));
        try w.bytes(s);
    }
    fn end(w: *Writer) Allocator.Error!void {
        const at = w.open orelse return;
        std.mem.writeInt(u32, w.out.items[at..][0..4], @intCast(w.out.items.len - at), .little);
        w.open = null;
    }
    fn begin(w: *Writer, kind: u32) Allocator.Error!void {
        try w.end();
        w.open = w.out.items.len;
        try w.u32_(0);
        try w.u32_(kind);
    }
    fn unknown(w: *Writer, m: Mesh, after: usize) Allocator.Error!void {
        for (m.unknown) |u| if (u.after == after) {
            try w.begin(u.kind);
            try w.bytes(u.data);
        };
    }
};

fn chunk(comptime kind: u32, comptime payload: []const u8) []const u8 {
    var hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], 8 + payload.len, .little);
    std.mem.writeInt(u32, hdr[4..8], kind, .little);
    return &hdr ++ payload;
}

/// The model's textures: the last one named (the mesh's own) first, then the other
/// parts' in order, each once (fang: `fang_poprawiany` for the body, `fangtyl`).
pub fn textureNames(a: Allocator, m: Mesh) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (m.texture.len > 0) try out.append(a, m.texture);
    for (m.parts) |p| {
        if (p.texture.len == 0) continue;
        for (out.items) |n| {
            if (std.ascii.eqlIgnoreCase(n, p.texture)) break;
        } else try out.append(a, p.texture);
    }
    return out.toOwnedSlice(a);
}

/// `bytes` with texture `old` (every texture when null) renamed `name` in each part
/// using it; the other parts keep theirs.
pub fn withTexture(gpa: Allocator, bytes: []const u8, old: ?[]const u8, name: []const u8) (Allocator.Error || error{BadChunk})![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 0;
    while (pos + 8 <= bytes.len) {
        const size = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        const kind = std.mem.readInt(u32, bytes[pos + 4 ..][0..4], .little);
        if (size < 8 or pos + size > bytes.len) return error.BadChunk;
        const was = if (kind == 9 and size >= 12) bytes[pos + 12 .. pos + size] else "";
        const was_name = was[0 .. std.mem.indexOfScalar(u8, was, 0) orelse was.len];
        if (kind == 9 and (old == null or std.ascii.eqlIgnoreCase(was_name, old.?))) {
            var hdr: [12]u8 = undefined;
            std.mem.writeInt(u32, hdr[0..4], @intCast(12 + name.len), .little);
            std.mem.writeInt(u32, hdr[4..8], 9, .little);
            std.mem.writeInt(u32, hdr[8..12], @intCast(name.len), .little);
            try out.appendSlice(gpa, &hdr);
            try out.appendSlice(gpa, name);
        } else try out.appendSlice(gpa, bytes[pos .. pos + size]);
        pos += size;
    }
    try out.appendSlice(gpa, bytes[pos..]);
    return out.toOwnedSlice(gpa);
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

    const re = try withTexture(gpa, bytes, null, "garcia_2.3df");
    defer gpa.free(re);
    var m2 = try parse(gpa, re);
    defer m2.deinit();
    try std.testing.expectEqualStrings("garcia_2.3df", m2.texture);
    try std.testing.expectEqual(m.parts[0].vertices.len, m2.parts[0].vertices.len);
}

test "a texture per part" {
    const gpa = std.testing.allocator;
    const bytes = comptime chunk(2, "") ++ chunk(3, &le(u32, 3) ++ "top") ++ chunk(9, &le(u32, 4) ++ "t.3d") ++
        chunk(2, "") ++ chunk(3, &le(u32, 4) ++ "body") ++ chunk(9, &le(u32, 4) ++ "b.3d");
    var m = try parse(gpa, bytes);
    defer m.deinit();
    const names = try textureNames(gpa, m);
    defer gpa.free(names);
    try std.testing.expectEqual(2, names.len);
    try std.testing.expectEqualStrings("b.3d", names[0]);
    try std.testing.expectEqualStrings("t.3d", names[1]);
    // Only the parts wearing `t.3d` change.
    const re = try withTexture(gpa, bytes, "t.3d", "new.3d");
    defer gpa.free(re);
    var m2 = try parse(gpa, re);
    defer m2.deinit();
    try std.testing.expectEqualStrings("new.3d", m2.parts[0].texture);
    try std.testing.expectEqualStrings("b.3d", m2.parts[1].texture);
}

test "encode gives the file back, unknown chunks included" {
    const gpa = std.testing.allocator;
    const vert = comptime le(f32, 1) ++ le(f32, 2) ++ le(f32, 3) ++ le(f32, 0.5) ++ le(f32, 0.25) ++ le(u16, 7);
    const bytes = comptime chunk(0, &le(u32, 2) ++ "ab") ++ chunk(11, &(le(f32, 0) ++ le(f32, 9.4) ++ le(f32, 0))) ++
        chunk(14, &(le(f32, 0) ++ le(f32, 0) ++ le(f32, 0))) ++ chunk(12, &le(f32, 24)) ++
        chunk(1, &(le(u32, 1) ++ le(f32, 0) ++ le(f32, 5) ++ le(f32, 0))) ++
        chunk(13, &(le(u32, 1) ++ le(u32, 4) ++ "hand".* ++ le(f32, 1) ++ le(f32, 2) ++ le(f32, 3) ++ le(f32, 0) ++ le(f32, 0) ++ le(f32, 0.5) ++ le(u32, 0))) ++
        chunk(10, &le(u32, 5) ++ "a.ani") ++ chunk(99, "xyz") ++ chunk(8, &le(u32, 1)) ++
        chunk(2, "") ++ chunk(3, &le(u32, 4) ++ "body") ++ chunk(9, &le(u32, 3) ++ "a.3") ++
        chunk(4, &(le(u32, 2) ++ vert ++ vert)) ++
        chunk(5, &(le(u32, 2) ++ le(u32, 0) ++ le(u32, 1) ++ le(u32, 1) ++ le(u32, 1))) ++
        chunk(6, &(le(u32, 1) ++ le(u16, 0) ++ le(u16, 1) ++ le(u16, 1))) ++
        chunk(7, &(le(u32, 1) ++ le(u32, 0) ++ le(f32, 33.3)));
    var m = try parse(gpa, bytes);
    defer m.deinit();
    const back = try encode(gpa, m);
    defer gpa.free(back);
    try std.testing.expectEqualSlices(u8, bytes, back);
    // An edited weight is written from `weight`.
    m.parts[0].influences[0].weight = 0.5;
    const edited = try encode(gpa, m);
    defer gpa.free(edited);
    var m2 = try parse(gpa, edited);
    defer m2.deinit();
    try std.testing.expectEqual(0.5, m2.parts[0].influences[0].weight);
    try std.testing.expectEqual(99, m2.unknown[0].kind);
}

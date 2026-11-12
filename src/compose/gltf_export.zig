//! glTF export: a game model (format records) as `.glb` (mapping: gltf.zig).

const std = @import("std");
const Allocator = std.mem.Allocator;
const formats = @import("../formats.zig");
const mesh_fmt = formats.mesh;
const anim = formats.anim;
const png = formats.png;
const Image = @import("../image.zig").Image;
const rotationXYZ = @import("../actor.zig").camera.rotationXYZ;
const gltf = @import("gltf.zig");
const frameTime = gltf.frameTime;
const Doc = gltf.Doc;
const Scene = gltf.Scene;
const GMesh = gltf.GMesh;
const Skin = gltf.Skin;
const Texture = gltf.Texture;
const GImage = gltf.GImage;
const TexSampler = gltf.TexSampler;
const Buffer = gltf.Buffer;
const Node = gltf.Node;
const Info = gltf.Info;
const Primitive = gltf.Primitive;
const Animation = gltf.Animation;
const Material = gltf.Material;
const Accessor = gltf.Accessor;
const BufferView = gltf.BufferView;
const boneTrs = gltf.boneTrs;
const dot4 = gltf.dot4;
const quatFromRows = gltf.quatFromRows;

/// `.glb` of a game model: `textures` are the images of `mesh.textureNames(m)` in that
/// order (null: missing, the material has no texture).
pub fn exportGlb(gpa: Allocator, name: []const u8, mesh: mesh_fmt.Mesh, anims: []const anim.Animation, frames: anim.BoneFrames, textures: []const ?Image) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The bind pose is the joints; some of the game's are its exporter's garbage (specnaz
    // bone 3: 7e28), which no float keeps a frame against: those are the origin.
    var m = mesh;
    m.joints = try a.dupe([3]f32, mesh.joints);
    for (m.joints) |*j| if (!saneJoint(j.*)) {
        j.* = .{ 0, 0, 0 };
    };
    var b: Builder = .{ .a = a };
    const nb = m.joints.len;

    const tex_names = try mesh_fmt.textureNames(a, m);
    const materials = try a.alloc(Material, tex_names.len);
    var images: std.ArrayList(GImage) = .empty;
    var texs: std.ArrayList(Texture) = .empty;
    for (tex_names, materials, 0..) |tn, *mat, i| {
        mat.* = .{ .name = tn, .pbrMetallicRoughness = .{ .metallicFactor = 0, .roughnessFactor = 1 } };
        const img = (if (i < textures.len) textures[i] else null) orelse continue;
        var w: std.Io.Writer.Allocating = .init(a);
        try png.write(a, &w.writer, img);
        try images.append(a, .{ .name = tn, .bufferView = try b.view(w.written(), null), .mimeType = "image/png" });
        try texs.append(a, .{ .source = @intCast(images.items.len - 1), .sampler = 0 });
        mat.pbrMetallicRoughness.?.baseColorTexture = .{ .index = @intCast(texs.items.len - 1) };
    }

    // Nodes: root, bones, rest, attach points, parts.
    var nodes: std.ArrayList(Node) = .empty;
    var root_children: std.ArrayList(u32) = .empty;
    const info: Info = .{ .name = m.name, .center = m.center, .rotation = if (m.has_rotation or !std.meta.eql(m.rotation, [3]f32{ 0, 0, 0 })) m.rotation else null, .height = m.height, .animations = m.animations };
    try nodes.append(a, .{ .name = name, .extras = .{ .gorky = info } });
    const bone_children = try a.alloc(std.ArrayList(u32), nb);
    for (bone_children) |*c| c.* = .empty;
    const attach0: usize = if (nb > 0) 2 + nb else 1;
    for (m.hold_modes, 0..) |h, i| {
        const kids = if (h.bone == mesh_fmt.no_bone) &root_children else if (h.bone < nb) &bone_children[h.bone] else return error.BadAttachBone;
        try kids.append(a, @intCast(attach0 + i));
    }
    if (nb > 0) {
        for (m.joints, 0..) |j, i| {
            try nodes.append(a, .{ .name = try std.fmt.allocPrint(a, "bone{d:0>2}", .{i}), .translation = j, .children = if (bone_children[i].items.len > 0) bone_children[i].items else null });
            try root_children.append(a, @intCast(1 + i));
        }
        try nodes.append(a, .{ .name = "rest" });
        try root_children.append(a, @intCast(1 + nb));
    }
    for (m.hold_modes) |h| try nodes.append(a, .{
        .name = h.name,
        .translation = h.params[0..3].*,
        .rotation = quatFromRows(rotationXYZ(h.params[3..6].*)),
        .extras = .{ .gorky_attach = h.params },
    });

    // A part's vertex influences plus the rest joint; two JOINTS/WEIGHTS sets hold 8.
    var meshes: std.ArrayList(GMesh) = .empty;
    var scene_nodes: std.ArrayList(u32) = .empty;
    try scene_nodes.append(a, 0);
    for (m.parts) |p| {
        const n = p.vertices.len;
        const pos = try a.alloc([3]f32, n);
        const uv = try a.alloc([2]f32, n);
        const ids = try a.alloc(f32, n);
        for (p.vertices, pos, uv, ids) |v, *ps, *u, *id| {
            ps.* = v.pos;
            u.* = v.uv;
            id.* = @floatFromInt(v.id);
        }
        var prim: Primitive = .{ .attributes = .{
            .POSITION = try b.accessor([3]f32, pos, 34962, true),
            .TEXCOORD_0 = try b.accessor([2]f32, uv, 34962, false),
            ._VERTEX_ID = try b.accessor(f32, ids, 34962, false),
        } };
        if (nb > 0) {
            const joints = try a.alloc([8]u16, n);
            const weights = try a.alloc([8]f32, n);
            const percents = try a.alloc([8]f32, n);
            var wide = false;
            for (p.ranges, joints, weights, percents) |rg, *js, *ws, *ps| {
                js.* = @splat(0);
                ws.* = @splat(0);
                ps.* = @splat(0);
                var rest: f32 = 1;
                var k: usize = 0;
                for (p.influences[rg[0]..rg[1]]) |inf| {
                    if (k == 8) return error.TooManyInfluences;
                    js[k] = @intCast(inf.bone);
                    ws[k] = inf.weight;
                    ps[k] = inf.percent;
                    rest -= inf.weight;
                    k += 1;
                }
                if (rest > 0) {
                    if (k == 8) return error.TooManyInfluences;
                    js[k] = @intCast(nb);
                    ws[k] = rest;
                    k += 1;
                }
                wide = wide or k > 4;
            }
            for (0..@as(usize, if (wide) 2 else 1)) |set| {
                const j4 = try a.alloc([4]u16, n);
                const w4 = try a.alloc([4]f32, n);
                const p4 = try a.alloc([4]f32, n);
                for (joints, weights, percents, j4, w4, p4) |js, ws, ps, *j, *w, *pc| {
                    j.* = js[set * 4 ..][0..4].*;
                    w.* = ws[set * 4 ..][0..4].*;
                    pc.* = ps[set * 4 ..][0..4].*;
                }
                const ja = try b.accessor([4]u16, j4, 34962, false);
                const wa = try b.accessor([4]f32, w4, 34962, false);
                const pa = try b.accessor([4]f32, p4, 34962, false);
                if (set == 0) {
                    prim.attributes.JOINTS_0 = ja;
                    prim.attributes.WEIGHTS_0 = wa;
                    prim.attributes._PERCENTS_0 = pa;
                } else {
                    prim.attributes.JOINTS_1 = ja;
                    prim.attributes.WEIGHTS_1 = wa;
                    prim.attributes._PERCENTS_1 = pa;
                }
            }
        }
        const flat: []const u32 = @as([*]const u32, @ptrCast(p.triangles.ptr))[0 .. p.triangles.len * 3];
        prim.indices = if (p.vertices.len > 0x10000) try b.accessor(u32, flat, 34963, false) else blk: {
            const short = try a.alloc(u16, flat.len);
            for (short, flat) |*d, x| d.* = @intCast(x);
            break :blk try b.accessor(u16, short, 34963, false);
        };
        for (tex_names, 0..) |tn, i| if (std.ascii.eqlIgnoreCase(tn, if (p.texture.len > 0) p.texture else m.texture)) {
            prim.material = @intCast(i);
        };
        try meshes.append(a, .{ .name = p.name, .primitives = try a.dupe(Primitive, &.{prim}) });
        try scene_nodes.append(a, @intCast(nodes.items.len));
        try nodes.append(a, .{ .name = p.name, .mesh = @intCast(meshes.items.len - 1), .skin = if (nb > 0) 0 else null });
    }
    nodes.items[0].children = if (root_children.items.len > 0) root_children.items else null;

    var doc: Doc = .{
        .asset = .{ .generator = "OpenGorky" },
        .scene = 0,
        .scenes = try a.dupe(Scene, &.{.{ .nodes = scene_nodes.items }}),
        .materials = if (materials.len > 0) materials else null,
        .images = if (images.items.len > 0) images.items else null,
        .textures = if (texs.items.len > 0) texs.items else null,
        .samplers = if (texs.items.len > 0) try a.dupe(TexSampler, &.{.{ .wrapS = 33071, .wrapT = 33071 }}) else null,
    };
    if (nb > 0) {
        const ibm = try a.alloc([16]f32, nb + 1);
        const joint_nodes = try a.alloc(u32, nb + 1);
        for (ibm, joint_nodes, 0..) |*mat, *jn, i| {
            mat.* = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
            if (i < nb) for (0..3) |k| {
                mat[12 + k] = -m.joints[i][k];
            };
            jn.* = @intCast(1 + i);
        }
        doc.skins = try a.dupe(Skin, &.{.{ .joints = joint_nodes, .inverseBindMatrices = try b.accessor([16]f32, ibm, null, false), .skeleton = 0 }});
        doc.animations = try exportAnimations(a, &b, m, anims, frames);
    }
    doc.nodes = nodes.items;
    doc.meshes = if (meshes.items.len > 0) meshes.items else null;
    doc.accessors = b.accessors.items;
    doc.bufferViews = b.views.items;
    doc.buffers = try a.dupe(Buffer, &.{.{ .byteLength = b.bin.items.len }});
    const json = try std.json.Stringify.valueAlloc(a, doc, .{ .emit_null_optional_fields = false });
    return glb(gpa, json, b.bin.items);
}

/// A joint a model's coordinates can hold (the game's models span tens of units).
fn saneJoint(j: [3]f32) bool {
    for (j) |x| if (!std.math.isFinite(x) or @abs(x) > 1e4) return false;
    return true;
}

test "saneJoint" {
    try std.testing.expect(saneJoint(.{ 4.2e-38, 0, -1.07 }));
    try std.testing.expect(!saneJoint(.{ 6.998e28, 9.3e-9, 2.7e20 }));
    try std.testing.expect(!saneJoint(.{ std.math.nan(f32), 0, 0 }));
}

fn exportAnimations(a: Allocator, b: *Builder, m: mesh_fmt.Mesh, anims: []const anim.Animation, frames: anim.BoneFrames) ![]const Animation {
    const nb = m.joints.len;
    const out = try a.alloc(Animation, anims.len);
    const Ch = @typeInfo(@FieldType(Animation, "channels")).pointer.child;
    const Sm = @typeInfo(@FieldType(Animation, "samplers")).pointer.child;
    for (anims, out) |an, *o| {
        const count = an.last - an.first + 1;
        const times = try a.alloc(f32, count);
        for (times, 0..) |*t, k| t.* = frameTime(k);
        const input = try b.accessor(f32, times, null, true);
        var chans: std.ArrayList(Ch) = .empty;
        var samps: std.ArrayList(Sm) = .empty;
        for (0..nb) |bone| {
            const tr = try a.alloc([3]f32, count);
            const rot = try a.alloc([4]f32, count);
            const sc = try a.alloc([3]f32, count);
            var scaled = false;
            for (0..count) |k| {
                const trs = boneTrs(frames.matrix(an.first + @as(u32, @intCast(k)), @intCast(bone)), m.joints[bone]);
                tr[k] = trs.t;
                rot[k] = trs.r;
                // Neighbouring keys on the same side of the quaternion sphere (shortest path).
                if (k > 0 and dot4(rot[k], rot[k - 1]) < 0) rot[k] = .{ -rot[k][0], -rot[k][1], -rot[k][2], -rot[k][3] };
                sc[k] = trs.s;
                for (trs.s) |s| scaled = scaled or @abs(s - 1) > 1e-5;
            }
            const node: u32 = @intCast(1 + bone);
            try samps.append(a, .{ .input = input, .output = try b.accessor([3]f32, tr, null, false), .interpolation = "LINEAR" });
            try chans.append(a, .{ .sampler = @intCast(samps.items.len - 1), .target = .{ .node = node, .path = "translation" } });
            try samps.append(a, .{ .input = input, .output = try b.accessor([4]f32, rot, null, false), .interpolation = "LINEAR" });
            try chans.append(a, .{ .sampler = @intCast(samps.items.len - 1), .target = .{ .node = node, .path = "rotation" } });
            if (scaled) {
                try samps.append(a, .{ .input = input, .output = try b.accessor([3]f32, sc, null, false), .interpolation = "LINEAR" });
                try chans.append(a, .{ .sampler = @intCast(samps.items.len - 1), .target = .{ .node = node, .path = "scale" } });
            }
        }
        o.* = .{ .name = an.name, .channels = chans.items, .samplers = samps.items, .extras = .{ .first = an.first, .last = an.last, .speed = an.speed, .sounds = an.sounds } };
    }
    return out;
}

/// Bin chunk and the accessors over it.
const Builder = struct {
    a: Allocator,
    bin: std.ArrayList(u8) = .empty,
    views: std.ArrayList(BufferView) = .empty,
    accessors: std.ArrayList(Accessor) = .empty,

    fn view(b: *Builder, data: []const u8, target: ?u32) !u32 {
        while (b.bin.items.len % 4 != 0) try b.bin.append(b.a, 0);
        try b.views.append(b.a, .{ .byteOffset = b.bin.items.len, .byteLength = data.len, .target = target });
        try b.bin.appendSlice(b.a, data);
        return @intCast(b.views.items.len - 1);
    }

    /// Accessor of `items` (f32 or u16, scalars or arrays); `bounds`: min and max (required
    /// for POSITION and animation input).
    fn accessor(b: *Builder, comptime T: type, items: []const T, target: ?u32, bounds: bool) !u32 {
        const n = switch (@typeInfo(T)) {
            .array => |ar| ar.len,
            else => 1,
        };
        const C = switch (@typeInfo(T)) {
            .array => |ar| ar.child,
            else => T,
        };
        var acc: Accessor = .{
            .bufferView = try b.view(std.mem.sliceAsBytes(items), target),
            .componentType = switch (C) {
                f32 => 5126,
                u32 => 5125,
                else => 5123,
            },
            .count = items.len,
            .type = switch (n) {
                1 => "SCALAR",
                2 => "VEC2",
                3 => "VEC3",
                4 => "VEC4",
                16 => "MAT4",
                else => @compileError("type"),
            },
        };
        if (bounds and items.len > 0) {
            const lo = try b.a.alloc(f32, n);
            const hi = try b.a.alloc(f32, n);
            @memset(lo, std.math.inf(f32));
            @memset(hi, -std.math.inf(f32));
            for (items) |it| for (0..n) |k| {
                const v: f32 = if (n == 1) (if (C == f32) it else @floatFromInt(it)) else it[k];
                lo[k] = @min(lo[k], v);
                hi[k] = @max(hi[k], v);
            };
            acc.min = lo;
            acc.max = hi;
        }
        try b.accessors.append(b.a, acc);
        return @intCast(b.accessors.items.len - 1);
    }
};

/// `.glb` container: header, JSON chunk (space-padded), BIN chunk (zero-padded).
fn glb(gpa: Allocator, json: []const u8, bin: []const u8) ![]u8 {
    const jl = std.mem.alignForward(usize, json.len, 4);
    const bl = std.mem.alignForward(usize, bin.len, 4);
    const total = 12 + 8 + jl + 8 + bl;
    const out = try gpa.alloc(u8, total);
    @memcpy(out[0..4], "glTF");
    std.mem.writeInt(u32, out[4..8], 2, .little);
    std.mem.writeInt(u32, out[8..12], @intCast(total), .little);
    std.mem.writeInt(u32, out[12..16], @intCast(jl), .little);
    @memcpy(out[16..20], "JSON");
    @memcpy(out[20..][0..json.len], json);
    @memset(out[20 + json.len .. 20 + jl], ' ');
    const bp = 20 + jl;
    std.mem.writeInt(u32, out[bp..][0..4], @intCast(bl), .little);
    @memcpy(out[bp + 4 ..][0..4], "BIN\x00");
    @memcpy(out[bp + 8 ..][0..bin.len], bin);
    @memset(out[bp + 8 + bin.len ..], 0);
    return out;
}

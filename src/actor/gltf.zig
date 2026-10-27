//! glTF 2.0 binary (`.glb`) export and import of game models (not in the exe).
//!
//! Mapping (export writes it, import reads it back):
//! - mesh units and axes as in `.msh` (Y up; the game's view is right-handed, camera.zig
//!   Persp), triangles as they are (outward normal (B−A)×(C−A) is glTF's CCW front);
//! - a part is a node + mesh named like the part; its texture a material and PNG named
//!   like the `.3df`;
//! - bone i is node `boneNN` at its chunk 1 joint, no hierarchy (the `.bfr` matrices take
//!   the bind pose straight to the pose), inverse bind matrix = translation by −joint.
//!   The weight the bones leave stays on the bind pose in the exe (skin.zig): it goes to
//!   joint `rest`, which never moves;
//! - bone i at frame f: node TRS = M·T(joint), M the `.bfr` matrix (shear, in 3 models,
//!   does not fit TRS and is dropped);
//! - each `.ani` animation is a glTF animation at 30 frames a second, a LINEAR key per
//!   frame; extras keep first/last/speed/sounds, so frames go back where they were;
//! - an attach point (chunk 13: weapon grips, kula1, pilot1…) is a child node of its
//!   bone: offset as translation, angles as rotation; extras keep the exact numbers;
//! - root node extras `gorky`: chunk 0 name, center, rotation, height, `.ani` spelling.

const std = @import("std");
const Allocator = std.mem.Allocator;
const formats = @import("../formats.zig");
const mesh_fmt = formats.mesh;
const anim = formats.anim;
const tex3df = formats.tex3df;
const png = formats.png;
const jpeg = formats.jpeg;
const Image = formats.image.Image;
const skin = @import("skin.zig");
const rotationXYZ = @import("camera.zig").rotationXYZ;

comptime {
    // Buffers are written and read in host order; glb is little-endian.
    std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
}

/// Game frames a second (one `.bfr` frame per 30 Hz tick, model_cache.frameOf).
const fps = 30;

// The subset of the glTF schema used here (field names are glTF's).
const Doc = struct {
    asset: struct { version: []const u8 = "2.0", generator: ?[]const u8 = null } = .{},
    scene: ?u32 = null,
    scenes: ?[]const Scene = null,
    nodes: ?[]const Node = null,
    meshes: ?[]const GMesh = null,
    skins: ?[]const Skin = null,
    animations: ?[]const Animation = null,
    materials: ?[]const Material = null,
    textures: ?[]const Texture = null,
    images: ?[]const GImage = null,
    samplers: ?[]const TexSampler = null,
    accessors: ?[]const Accessor = null,
    bufferViews: ?[]const BufferView = null,
    buffers: ?[]const Buffer = null,
};

const Scene = struct { nodes: []const u32 = &.{} };
const GMesh = struct { name: ?[]const u8 = null, primitives: []const Primitive };
const Skin = struct { joints: []const u32, inverseBindMatrices: ?u32 = null, skeleton: ?u32 = null };
const Texture = struct { source: ?u32 = null, sampler: ?u32 = null };
const GImage = struct { name: ?[]const u8 = null, bufferView: ?u32 = null, mimeType: ?[]const u8 = null, uri: ?[]const u8 = null };
const TexSampler = struct { wrapS: ?u32 = null, wrapT: ?u32 = null };
const Buffer = struct { byteLength: usize, uri: ?[]const u8 = null };

const Node = struct {
    name: ?[]const u8 = null,
    children: ?[]const u32 = null,
    mesh: ?u32 = null,
    skin: ?u32 = null,
    translation: ?[3]f32 = null,
    rotation: ?[4]f32 = null,
    scale: ?[3]f32 = null,
    matrix: ?[16]f32 = null,
    extras: ?struct { gorky: ?Info = null, gorky_attach: ?[6]f32 = null } = null,
};

/// Model fields without a glTF place (root node extras).
const Info = struct { name: []const u8 = "", center: [3]f32 = .{ 0, 0, 0 }, rotation: ?[3]f32 = null, height: f32 = 0, animations: []const u8 = "" };

const Primitive = struct {
    attributes: struct {
        POSITION: ?u32 = null,
        TEXCOORD_0: ?u32 = null,
        JOINTS_0: ?u32 = null,
        WEIGHTS_0: ?u32 = null,
        JOINTS_1: ?u32 = null,
        WEIGHTS_1: ?u32 = null,
        /// `.msh` vertex number (Vertex.id) and the file percents beside WEIGHTS_0/1
        /// (several percents give one f32 weight), for byte-exact round trips.
        _VERTEX_ID: ?u32 = null,
        _PERCENTS_0: ?u32 = null,
        _PERCENTS_1: ?u32 = null,
    },
    indices: ?u32 = null,
    material: ?u32 = null,
    mode: ?u32 = null,
};

const Animation = struct {
    name: ?[]const u8 = null,
    channels: []const struct { sampler: u32, target: struct { node: ?u32 = null, path: []const u8 } },
    samplers: []const struct { input: u32, output: u32, interpolation: ?[]const u8 = null },
    extras: ?struct { first: ?u32 = null, last: ?u32 = null, speed: ?f32 = null, sounds: ?[]const anim.SoundCue = null } = null,
};

const Material = struct {
    name: ?[]const u8 = null,
    pbrMetallicRoughness: ?struct {
        baseColorTexture: ?struct { index: u32 } = null,
        metallicFactor: ?f32 = null,
        roughnessFactor: ?f32 = null,
    } = null,
};

const Accessor = struct {
    bufferView: ?u32 = null,
    byteOffset: usize = 0,
    componentType: u32,
    normalized: ?bool = null,
    count: usize,
    type: []const u8,
    min: ?[]const f32 = null,
    max: ?[]const f32 = null,
    sparse: ?std.json.Value = null,
};

const BufferView = struct { buffer: u32 = 0, byteOffset: usize = 0, byteLength: usize, byteStride: ?u32 = null, target: ?u32 = null };

// ---- export ----

/// `.glb` of a game model: `textures` are the images of `mesh.textureNames(m)` in that
/// order (null: missing, the material has no texture).
pub fn exportGlb(gpa: Allocator, name: []const u8, m: mesh_fmt.Mesh, anims: []const anim.Animation, frames: anim.BoneFrames, textures: []const ?Image) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
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
        const flat: []const u16 = @as([*]const u16, @ptrCast(p.triangles.ptr))[0 .. p.triangles.len * 3];
        prim.indices = try b.accessor(u16, flat, 34963, false);
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

fn frameTime(k: usize) f32 {
    return @as(f32, @floatFromInt(k)) / fps;
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
            .componentType = if (C == f32) 5126 else 5123,
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
                const v: f32 = if (n == 1) it else it[k];
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

// ---- matrices ----

/// 4×4, column-major (glTF's order).
const Mat = [16]f64;
const identity: Mat = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

fn mul(x: Mat, y: Mat) Mat {
    var o: Mat = undefined;
    for (0..4) |c| for (0..4) |r| {
        var s: f64 = 0;
        for (0..4) |k| s += x[k * 4 + r] * y[c * 4 + k];
        o[c * 4 + r] = s;
    };
    return o;
}

/// Inverse of an affine matrix.
fn inverse(x: Mat) Mat {
    const a = x[0];
    const b = x[4];
    const c = x[8];
    const d = x[1];
    const e = x[5];
    const f = x[9];
    const g = x[2];
    const h = x[6];
    const i = x[10];
    const det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
    const k = if (det == 0) 0 else 1 / det;
    // Rows of the inverse 3×3 (adjugate / det).
    const r = [9]f64{ (e * i - f * h) * k, (c * h - b * i) * k, (b * f - c * e) * k, (f * g - d * i) * k, (a * i - c * g) * k, (c * d - a * f) * k, (d * h - e * g) * k, (b * g - a * h) * k, (a * e - b * d) * k };
    var o = identity;
    for (0..3) |row| {
        for (0..3) |col| o[col * 4 + row] = r[row * 3 + col];
        o[12 + row] = -(r[row * 3] * x[12] + r[row * 3 + 1] * x[13] + r[row * 3 + 2] * x[14]);
    }
    return o;
}

fn trsMatrix(t: [3]f32, q: [4]f32, s: [3]f32) Mat {
    const r = rowsFromQuat(q);
    var o = identity;
    for (0..3) |c| {
        for (0..3) |row| o[c * 4 + row] = r[row * 3 + c] * s[c];
        o[12 + c] = t[c];
    }
    return o;
}

/// The `.bfr` 12 floats are the column-major 4×4 without its last row.
fn fromBfr(m: *const [12]f32) Mat {
    var o = identity;
    for (0..4) |c| for (0..3) |r| {
        o[c * 4 + r] = m[c * 3 + r];
    };
    return o;
}

fn toBfr(x: Mat) [12]f32 {
    var o: [12]f32 = undefined;
    for (0..4) |c| for (0..3) |r| {
        o[c * 3 + r] = @floatCast(x[c * 4 + r]);
    };
    return o;
}

const Trs = struct { t: [3]f32, r: [4]f32, s: [3]f32 };

/// Joint node TRS for bone matrix `m`: world = M·T(joint). The 3×3 is split into a
/// rotation and per-axis scales (Gram-Schmidt on its columns; shear is dropped).
fn boneTrs(m: *const [12]f32, joint: [3]f32) Trs {
    const w = mul(fromBfr(m), trsMatrix(joint, .{ 0, 0, 0, 1 }, .{ 1, 1, 1 }));
    var c: [3][3]f64 = undefined;
    for (0..3) |i| c[i] = .{ w[i * 4], w[i * 4 + 1], w[i * 4 + 2] };
    const unit = [3][3]f64{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
    var u: [3][3]f64 = undefined;
    u[0] = normalized(c[0]) orelse unit[0];
    u[1] = normalized(sub3(c[1], scale3(u[0], dot3(c[1], u[0])))) orelse
        normalized(cross3(u[0], unit[2])) orelse normalized(cross3(u[0], unit[0])).?;
    u[2] = cross3(u[0], u[1]);
    var rows: [9]f64 = undefined;
    for (0..3) |i| for (0..3) |r| {
        rows[r * 3 + i] = u[i][r];
    };
    var s: [3]f32 = undefined;
    for (0..3) |i| s[i] = @floatCast(dot3(c[i], u[i]));
    return .{ .t = .{ @floatCast(w[12]), @floatCast(w[13]), @floatCast(w[14]) }, .r = quatFromRows(rows), .s = s };
}

fn dot3(x: [3]f64, y: [3]f64) f64 {
    return x[0] * y[0] + x[1] * y[1] + x[2] * y[2];
}
fn sub3(x: [3]f64, y: [3]f64) [3]f64 {
    return .{ x[0] - y[0], x[1] - y[1], x[2] - y[2] };
}
fn scale3(x: [3]f64, k: f64) [3]f64 {
    return .{ x[0] * k, x[1] * k, x[2] * k };
}
fn cross3(x: [3]f64, y: [3]f64) [3]f64 {
    return .{ x[1] * y[2] - x[2] * y[1], x[2] * y[0] - x[0] * y[2], x[0] * y[1] - x[1] * y[0] };
}
fn normalized(x: [3]f64) ?[3]f64 {
    const l = @sqrt(dot3(x, x));
    return if (l < 1e-12) null else scale3(x, 1 / l);
}
fn dot4(x: [4]f32, y: [4]f32) f32 {
    return x[0] * y[0] + x[1] * y[1] + x[2] * y[2] + x[3] * y[3];
}

/// Quaternion (x, y, z, w) of a rotation given by rows (f32 or f64).
fn quatFromRows(m: anytype) [4]f32 {
    var r: [9]f64 = undefined;
    for (&r, m) |*d, v| d.* = v;
    const tr = r[0] + r[4] + r[8];
    var q: [4]f64 = undefined;
    if (tr > 0) {
        const s = @sqrt(tr + 1) * 2;
        q = .{ (r[7] - r[5]) / s, (r[2] - r[6]) / s, (r[3] - r[1]) / s, s / 4 };
    } else if (r[0] > r[4] and r[0] > r[8]) {
        const s = @sqrt(1 + r[0] - r[4] - r[8]) * 2;
        q = .{ s / 4, (r[1] + r[3]) / s, (r[2] + r[6]) / s, (r[7] - r[5]) / s };
    } else if (r[4] > r[8]) {
        const s = @sqrt(1 + r[4] - r[0] - r[8]) * 2;
        q = .{ (r[1] + r[3]) / s, s / 4, (r[5] + r[7]) / s, (r[2] - r[6]) / s };
    } else {
        const s = @sqrt(1 + r[8] - r[0] - r[4]) * 2;
        q = .{ (r[2] + r[6]) / s, (r[5] + r[7]) / s, s / 4, (r[3] - r[1]) / s };
    }
    const l = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    return .{ @floatCast(q[0] / l), @floatCast(q[1] / l), @floatCast(q[2] / l), @floatCast(q[3] / l) };
}

fn rowsFromQuat(q4: [4]f32) [9]f64 {
    const l = @sqrt(@as(f64, dot4(q4, q4)));
    const x = q4[0] / l;
    const y = q4[1] / l;
    const z = q4[2] / l;
    const w = q4[3] / l;
    return .{
        1 - 2 * (y * y + z * z), 2 * (x * y - z * w),     2 * (x * z + y * w),
        2 * (x * y + z * w),     1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
        2 * (x * z - y * w),     2 * (y * z + x * w),     1 - 2 * (x * x + y * y),
    };
}

/// Angles a with rotationXYZ(a) = R (R by rows): R = Rx·Ry·Rz gives R02 = −sin y,
/// R01/R00 = −tan z, R12/R22 = −tan x.
fn anglesXYZ(r: [9]f64) [3]f32 {
    const y = std.math.asin(std.math.clamp(-r[2], -1, 1));
    if (@abs(r[2]) > 0.999999) {
        // Gimbal lock: z folds into x.
        return .{ @floatCast(std.math.atan2(r[3], r[4])), @floatCast(y), 0 };
    }
    return .{ @floatCast(std.math.atan2(-r[5], r[8])), @floatCast(y), @floatCast(std.math.atan2(-r[1], r[0])) };
}

// ---- import ----

/// Files of an imported model: `<name>.msh`, `.ani`, `.bfr` and `.3df` textures.
const Files = struct {
    arena: std.heap.ArenaAllocator,
    msh: []const u8 = "",
    ani: []const u8 = "",
    bfr: []const u8 = "",
    textures: []const struct { name: []const u8, data: []const u8 } = &.{},

    pub fn deinit(self: *Files) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Gltf = struct {
    doc: Doc,
    bin: []const u8,
    parent: []?u32,

    fn nodes(g: Gltf) []const Node {
        return g.doc.nodes orelse &.{};
    }
};

fn parseGlb(a: Allocator, bytes: []const u8) !Gltf {
    if (bytes.len < 20 or !std.mem.eql(u8, bytes[0..4], "glTF") or std.mem.readInt(u32, bytes[4..8], .little) != 2) return error.NotGlb;
    const total = @min(bytes.len, std.mem.readInt(u32, bytes[8..12], .little));
    var pos: usize = 12;
    var json: ?[]const u8 = null;
    var bin: []const u8 = "";
    while (pos + 8 <= total) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        if (len > total - pos - 8) return error.BadGlb;
        const data = bytes[pos + 8 ..][0..len];
        if (std.mem.eql(u8, bytes[pos + 4 ..][0..4], "JSON")) json = data else if (std.mem.eql(u8, bytes[pos + 4 ..][0..4], "BIN\x00")) bin = data;
        pos += 8 + len;
    }
    const doc = try std.json.parseFromSliceLeaky(Doc, a, json orelse return error.BadGlb, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    const g: Gltf = .{ .doc = doc, .bin = bin, .parent = try a.alloc(?u32, if (doc.nodes) |n| n.len else 0) };
    @memset(g.parent, null);
    for (g.nodes(), 0..) |n, i| for (n.children orelse &.{}) |c| {
        if (c >= g.parent.len) return error.BadGlb;
        g.parent[c] = @intCast(i);
    };
    return g;
}

/// Accessor `idx` as `n` floats per element (integers as their value, normalized ones /max).
fn readAccessor(g: Gltf, a: Allocator, idx: u32, comptime n: usize) ![][n]f32 {
    const accs = g.doc.accessors orelse return error.BadGlb;
    if (idx >= accs.len) return error.BadGlb;
    const acc = accs[idx];
    if (acc.sparse != null) return error.SparseAccessor;
    const out = try a.alloc([n]f32, acc.count);
    const vi = acc.bufferView orelse {
        @memset(out, @splat(0));
        return out;
    };
    const views = g.doc.bufferViews orelse return error.BadGlb;
    if (vi >= views.len) return error.BadGlb;
    const v = views[vi];
    const bufs = g.doc.buffers orelse return error.BadGlb;
    if (v.buffer != 0 or bufs.len == 0 or bufs[0].uri != null) return error.ExternalBuffer;
    const csize: usize = switch (acc.componentType) {
        5120, 5121 => 1,
        5122, 5123 => 2,
        5125, 5126 => 4,
        else => return error.BadGlb,
    };
    // Components the accessor has (a VEC3 read as 4 leaves the 4th 0).
    const comps: usize = if (std.mem.eql(u8, acc.type, "SCALAR")) 1 else if (std.mem.eql(u8, acc.type, "MAT4")) 16 else if (acc.type.len == 4 and std.mem.startsWith(u8, acc.type, "VEC")) acc.type[3] - '0' else return error.BadGlb;
    const stride = v.byteStride orelse csize * comps;
    const norm = acc.normalized orelse false;
    if (v.byteOffset + v.byteLength > g.bin.len) return error.BadGlb;
    const data = g.bin[v.byteOffset..][0..v.byteLength];
    for (out, 0..) |*o, i| for (o, 0..) |*x, k| {
        if (k >= comps) {
            x.* = 0;
            continue;
        }
        const off = acc.byteOffset + i * stride + k * csize;
        if (off + csize > data.len) return error.BadGlb;
        var p: [4]u8 = @splat(0);
        @memcpy(p[0..csize], data[off..][0..csize]);
        x.* = switch (acc.componentType) {
            5126 => @bitCast(std.mem.readInt(u32, p[0..4], .little)),
            5125 => @floatFromInt(std.mem.readInt(u32, p[0..4], .little)),
            5123 => @as(f32, @floatFromInt(std.mem.readInt(u16, p[0..2], .little))) / @as(f32, if (norm) 65535 else 1),
            5122 => @max(-1, @as(f32, @floatFromInt(std.mem.readInt(i16, p[0..2], .little))) / @as(f32, if (norm) 32767 else 1)),
            5121 => @as(f32, @floatFromInt(p[0])) / @as(f32, if (norm) 255 else 1),
            else => @max(-1, @as(f32, @floatFromInt(@as(i8, @bitCast(p[0])))) / @as(f32, if (norm) 127 else 1)),
        };
    };
    return out;
}

/// The skin of the mesh nodes, its joints mapped to game bones (`boneNN` names when all
/// joints have them, else skin order; joint `rest` is the bind pose).
const Skeleton = struct {
    joints: []const u32 = &.{},
    /// Game bone of each skin joint (null: `rest`).
    bone: []?u32 = &.{},
    ibm: []Mat = &.{},
    bones: usize = 0,

    fn of(g: Gltf, a: Allocator) !Skeleton {
        var si: ?u32 = null;
        for (g.nodes()) |n| if (n.mesh != null) if (n.skin) |s| {
            if (si != null and si.? != s) return error.SeveralSkins;
            si = s;
        };
        const skins = g.doc.skins orelse return .{};
        const s = skins[si orelse return .{}];
        var sk: Skeleton = .{ .joints = s.joints, .bone = try a.alloc(?u32, s.joints.len), .ibm = try a.alloc(Mat, s.joints.len) };
        @memset(sk.ibm, identity);
        if (s.inverseBindMatrices) |ia| for (try readAccessor(g, a, ia, 16), sk.ibm) |m, *d| {
            for (d, m) |*x, y| x.* = y;
        };
        var named = true;
        for (s.joints, sk.bone) |j, *b| {
            if (j >= g.nodes().len) return error.BadGlb;
            const nm = g.nodes()[j].name orelse "";
            b.* = if (std.mem.eql(u8, nm, "rest")) null else blk: {
                sk.bones += 1;
                const num = if (std.mem.startsWith(u8, nm, "bone")) std.fmt.parseInt(u32, nm[4..], 10) catch null else null;
                named = named and num != null;
                break :blk num orelse 0;
            };
        }
        // boneNN must cover 0..bones-1 once each, else skin order.
        var seen = try a.alloc(bool, sk.bones);
        @memset(seen, false);
        for (sk.bone) |b| if (b) |v| {
            if (v >= sk.bones or seen[v]) named = false else seen[v] = true;
        };
        if (!named) {
            var k: u32 = 0;
            for (sk.bone) |*b| if (b.*) |_| {
                b.* = k;
                k += 1;
            };
        }
        return sk;
    }

    fn jointOf(sk: Skeleton, node: u32) ?usize {
        return std.mem.indexOfScalar(u32, sk.joints, node);
    }
};

/// Game model from a `.glb` (chunk 10 names `<name>.ani`). Checked against the exe's
/// limits (mesh.checkLimits).
pub fn importGlb(gpa: Allocator, bytes: []const u8, name: []const u8) !Files {
    var files: Files = .{ .arena = .init(gpa) };
    errdefer files.arena.deinit();
    const a = files.arena.allocator();
    const g = try parseGlb(a, bytes);
    const sk = try Skeleton.of(g, a);

    var m: mesh_fmt.Mesh = .{ .arena = undefined, .animations = try std.fmt.allocPrint(a, "{s}.ani", .{name}) };
    for (g.nodes()) |n| if (n.extras) |e| if (e.gorky) |info| {
        m.name = info.name;
        m.center = info.center;
        m.height = info.height;
        m.has_rotation = info.rotation != null;
        m.rotation = info.rotation orelse .{ 0, 0, 0 };
        // The exported spelling (thiefA.ani) when it names the same file.
        if (std.ascii.eqlIgnoreCase(info.animations, m.animations)) m.animations = info.animations;
        break;
    };
    if (m.height == 0) m.height = 1;

    // Joints and attach points from the bind pose (inverse bind matrices).
    m.joints = try a.alloc([3]f32, sk.bones);
    for (sk.bone, sk.ibm) |bone, ibm| if (bone) |b| {
        const bind = inverse(ibm);
        m.joints[b] = .{ @floatCast(bind[12]), @floatCast(bind[13]), @floatCast(bind[14]) };
        // A pure translation (as exported) negates exactly, −0 included.
        if (std.meta.eql(ibm[0..12].*, identity[0..12].*)) m.joints[b] = .{ @floatCast(-ibm[12]), @floatCast(-ibm[13]), @floatCast(-ibm[14]) };
    };
    // Attach points, in node order: non-joint, non-mesh children of a bone, or of the
    // root (extras `gorky`) for points without a bone (ponton).
    var holds: std.ArrayList(mesh_fmt.HoldMode) = .empty;
    for (g.nodes(), 0..) |cn, ci| {
        const par = g.parent[ci] orelse continue;
        if (sk.jointOf(@intCast(ci)) != null or cn.mesh != null) continue;
        const pn = g.nodes()[par];
        if (sk.jointOf(par)) |k| {
            const b = sk.bone[k] orelse continue;
            try holds.append(a, .{ .name = cn.name orelse "", .params = attachParams(cn, inverse(sk.ibm[k])), .bone = b });
        } else if (pn.extras != null and pn.extras.?.gorky != null) {
            try holds.append(a, .{ .name = cn.name orelse "", .params = attachParams(cn, restWorld(g, par)), .bone = mesh_fmt.no_bone });
        }
    }
    m.hold_modes = holds.items;

    var parts: std.ArrayList(mesh_fmt.Part) = .empty;
    var tex_names: std.ArrayList([]const u8) = .empty;
    var tex_files: std.ArrayList(@typeInfo(@FieldType(Files, "textures")).pointer.child) = .empty;
    for (g.nodes(), 0..) |n, ni| {
        const mi = n.mesh orelse continue;
        const meshes = g.doc.meshes orelse return error.BadGlb;
        if (mi >= meshes.len) return error.BadGlb;
        // A static mesh keeps its place; a skinned one is in bind space already.
        const world = if (n.skin == null) restWorld(g, @intCast(ni)) else identity;
        for (meshes[mi].primitives, 0..) |prim, k| {
            if ((prim.mode orelse 4) != 4) return error.NotTriangles;
            var p = try importPart(g, a, sk, prim, world);
            const base = n.name orelse meshes[mi].name orelse "part";
            p.name = if (meshes[mi].primitives.len > 1) try std.fmt.allocPrint(a, "{s}{d}", .{ base, k }) else base;
            if (prim.material) |mat| p.texture = try importTexture(g, a, mat, name, &tex_names, &tex_files);
            try parts.append(a, p);
        }
    }
    m.parts = parts.items;
    if (parts.items.len > 0) m.texture = parts.items[parts.items.len - 1].texture;

    var anims: std.ArrayList(anim.Animation) = .empty;
    var mats: std.ArrayList([12]f32) = .empty;
    try importAnimations(g, a, sk, sk.bones, &anims, &mats, true);
    const frames = try finishFrames(a, m, mats.items);
    try mesh_fmt.checkLimits(m);
    try anim.checkLimits(anims.items, frames, m.joints.len);
    files.msh = try mesh_fmt.encode(a, m);
    files.ani = try anim.writeAni(a, anims.items);
    files.bfr = try anim.writeBfr(a, frames);
    files.textures = tex_files.items;
    return files;
}

/// `ani`/`bfr` of an existing model with the animations of a `.glb` of the same skeleton
/// added (an animation of the same name is replaced); the frames no animation uses are
/// dropped (`compactFrames`).
pub fn importAnimationsInto(gpa: Allocator, bytes: []const u8, m: mesh_fmt.Mesh, list: []const anim.Animation, frames: anim.BoneFrames) !Files {
    var files: Files = .{ .arena = .init(gpa) };
    errdefer files.arena.deinit();
    const a = files.arena.allocator();
    const g = try parseGlb(a, bytes);
    const sk = try Skeleton.of(g, a);
    if (sk.bones != m.joints.len or frames.bones != m.joints.len) return error.SkeletonMismatch;
    var anims: std.ArrayList(anim.Animation) = .empty;
    try anims.appendSlice(a, list);
    var mats: std.ArrayList([12]f32) = .empty;
    try mats.appendSlice(a, frames.matrices);
    var new: std.ArrayList(anim.Animation) = .empty;
    try importAnimations(g, a, sk, sk.bones, &new, &mats, false);
    for (new.items) |an| {
        // Braced: the `else` is the loop's (no animation of that name), not the `if`'s.
        for (anims.items) |*old| {
            if (std.ascii.eqlIgnoreCase(old.name, an.name)) {
                old.* = an;
                break;
            }
        } else try anims.append(a, an);
    }
    const out = try finishFrames(a, m, try compactFrames(a, m.joints.len, anims.items, mats.items, frames.frames));
    try anim.checkLimits(anims.items, out, m.joints.len);
    files.ani = try anim.writeAni(a, anims.items);
    files.bfr = try anim.writeBfr(a, out);
    return files;
}

/// `mats` (`bones` per frame) with only frame 0 and the frames of `anims` kept, their
/// ranges and sound cues renumbered: the exe reads frames only through `.ani` ranges and
/// starts a model on frame 0 (player 0x44f910, stride 0x44c012). Padded with rest frames
/// to at least `min_frames` (the old count), so the old `.ani` still fits the new `.bfr`
/// while the editor swaps them one at a time (and back on undo).
fn compactFrames(a: Allocator, bones: usize, anims: []anim.Animation, mats: []const [12]f32, min_frames: u32) ![]const [12]f32 {
    if (bones == 0) return mats;
    const n = mats.len / bones;
    const keep = try a.alloc(bool, n);
    @memset(keep, false);
    if (n > 0) keep[0] = true;
    for (anims) |an| {
        if (an.first > an.last or an.last >= n) return error.AnimOutOfRange;
        @memset(keep[an.first .. an.last + 1], true);
    }
    const to = try a.alloc(u32, n);
    var k: u32 = 0;
    for (keep, to) |kp, *t| {
        t.* = k;
        if (kp) k += 1;
    }
    const out = try a.alloc([12]f32, @max(k, min_frames) * bones);
    @memset(out, rest_matrix);
    for (keep, to, 0..) |kp, t, f| if (kp) @memcpy(out[t * bones ..][0..bones], mats[f * bones ..][0..bones]);
    for (anims) |*an| {
        const first = to[an.first];
        const sounds = try a.dupe(anim.SoundCue, an.sounds);
        for (sounds) |*s| s.frame = s.frame -% an.first +% first;
        an.* = .{ .name = an.name, .first = first, .last = to[an.last], .speed = an.speed, .sounds = sounds };
    }
    return out;
}

/// Attach point params (offset, angles) of node `n` under a bone whose bind matrix is
/// `bind`: offset = bind 3×3 · translation, rotation = bind 3×3 · node rotation. The
/// extras' exact numbers when they still give the same.
fn attachParams(n: Node, bind: Mat) [6]f32 {
    const t = n.translation orelse .{ 0, 0, 0 };
    const q = n.rotation orelse .{ 0, 0, 0, 1 };
    const lr = rowsFromQuat(q);
    var rows: [9]f64 = undefined;
    var p: [6]f32 = undefined;
    for (0..3) |r| {
        p[r] = @floatCast(bind[r] * t[0] + bind[4 + r] * t[1] + bind[8 + r] * t[2]);
        for (0..3) |c| rows[r * 3 + c] = bind[r] * lr[c] + bind[4 + r] * lr[3 + c] + bind[8 + r] * lr[6 + c];
    }
    p[3..6].* = anglesXYZ(rows);
    const e = (n.extras orelse return p).gorky_attach orelse return p;
    const er = rotationXYZ(e[3..6].*);
    for (0..3) |k| if (@abs(e[k] - p[k]) > 1e-4) return p;
    for (0..9) |k| if (@abs(er[k] - rows[k]) > 1e-4) return p;
    return e;
}

/// World matrix of node `ni` in its rest pose.
fn restWorld(g: Gltf, ni: u32) Mat {
    var w = identity;
    var cur: ?u32 = ni;
    while (cur) |c| : (cur = g.parent[c]) w = mul(restLocal(g.nodes()[c]), w);
    return w;
}

fn restLocal(n: Node) Mat {
    if (n.matrix) |mm| {
        var o: Mat = undefined;
        for (&o, mm) |*x, y| x.* = y;
        return o;
    }
    return trsMatrix(n.translation orelse .{ 0, 0, 0 }, n.rotation orelse .{ 0, 0, 0, 1 }, n.scale orelse .{ 1, 1, 1 });
}

fn importPart(g: Gltf, a: Allocator, sk: Skeleton, prim: Primitive, world: Mat) !mesh_fmt.Part {
    const pos = try readAccessor(g, a, prim.attributes.POSITION orelse return error.NoPositions, 3);
    if (pos.len > 0xffff) return error.TooManyVertices;
    const uv = if (prim.attributes.TEXCOORD_0) |i| try readAccessor(g, a, i, 2) else null;
    const ids = if (prim.attributes._VERTEX_ID) |i| try readAccessor(g, a, i, 1) else null;
    var p: mesh_fmt.Part = .{ .name = "", .vertices = try a.alloc(mesh_fmt.Vertex, pos.len), .ranges = try a.alloc([2]u32, pos.len), .influences = &.{}, .triangles = &.{} };
    for (p.vertices, pos, 0..) |*v, ps, i| {
        var q = ps;
        if (!std.meta.eql(world, identity)) for (0..3) |r| {
            q[r] = @floatCast(world[r] * ps[0] + world[4 + r] * ps[1] + world[8 + r] * ps[2] + world[12 + r]);
        };
        // UVs stay as given: the exe clamps them to 0..1 on load (0x44cb0c).
        const t = if (uv) |u| u[i] else [2]f32{ 0, 0 };
        v.* = .{ .pos = q, .uv = t, .id = if (ids) |d| @intFromFloat(std.math.clamp(d[i][0], 0, 0xffff)) else @intCast(i) };
    }
    // Influences: game bones only, the rest joint's share is the bind pose.
    var infl: std.ArrayList(mesh_fmt.Influence) = .empty;
    const at = prim.attributes;
    const sets = [2][3]?u32{ .{ at.JOINTS_0, at.WEIGHTS_0, at._PERCENTS_0 }, .{ at.JOINTS_1, at.WEIGHTS_1, at._PERCENTS_1 } };
    // Joints, weights, file percents (weights ·100 when missing).
    var jw: [2]?[3][][4]f32 = .{ null, null };
    for (sets, &jw) |s, *d| if (s[0] != null and s[1] != null and sk.joints.len > 0) {
        const w = try readAccessor(g, a, s[1].?, 4);
        d.* = .{ try readAccessor(g, a, s[0].?, 4), w, if (s[2]) |pi| try readAccessor(g, a, pi, 4) else w };
        for (d.*.?) |x| if (x.len != pos.len) return error.BadGlb;
    };
    for (p.ranges, 0..) |*rg, i| {
        const start = infl.items.len;
        var total: f32 = 0;
        for (jw) |set| if (set) |s| for (s[0][i], s[1][i], s[2][i]) |jf, w, pc| {
            if (w <= 0) continue;
            const j: usize = @intFromFloat(jf);
            if (j >= sk.joints.len) return error.BadGlb;
            total += w;
            if (sk.bone[j]) |b| try infl.append(a, .{ .bone = b, .weight = w, .percent = pc });
        };
        // Weights above 1 would push the vertex past the pose (the exe adds 1 − Σ).
        for (infl.items[start..]) |*inf| {
            if (total > 1.0001) inf.weight /= total;
            if (inf.percent * 0.01 != inf.weight) inf.percent = percentOf(inf.weight);
            inf.weight = inf.percent * 0.01;
        }
        rg.* = .{ @intCast(start), @intCast(infl.items.len) };
        // A vertex at the place of an earlier one with the same influences shares its
        // range, as in the game's files (all but 8 of 7600 such vertices).
        for (p.ranges[0..i], p.vertices[0..i]) |prev, pv| if (std.meta.eql(pv.pos, p.vertices[i].pos) and
            std.mem.eql(u8, std.mem.sliceAsBytes(infl.items[prev[0]..prev[1]]), std.mem.sliceAsBytes(infl.items[start..])))
        {
            infl.shrinkRetainingCapacity(start);
            rg.* = prev;
            break;
        };
    }
    if (infl.items.len > 0xffff) return error.TooManyInfluences;
    p.influences = infl.items;
    const idx = if (prim.indices) |i| try readAccessor(g, a, i, 1) else null;
    const count = if (idx) |x| x.len else pos.len;
    var tris: std.ArrayList([3]u16) = .empty;
    for (0..count / 3) |k| {
        var t: [3]u16 = undefined;
        for (&t, 0..) |*v, c| {
            const vi: usize = if (idx) |x| @intFromFloat(x[k * 3 + c][0]) else k * 3 + c;
            if (vi >= pos.len) return error.BadGlb;
            v.* = @intCast(vi);
        }
        // A triangle with a repeated vertex cuts the part short in the exe (0x4c6f55).
        if (t[0] != t[1] and t[1] != t[2] and t[0] != t[2]) try tris.append(a, t);
    }
    p.triangles = tris.items;
    // A mirroring node transform turns the faces inside out.
    const det = world[0] * (world[5] * world[10] - world[9] * world[6]) - world[4] * (world[1] * world[10] - world[9] * world[2]) + world[8] * (world[1] * world[6] - world[5] * world[2]);
    if (det < 0) for (p.triangles) |*t| std.mem.swap(u16, &t[1], &t[2]);
    return p;
}

/// The file percent whose ·0.01 is `w` (the exe multiplies by 0.01, 0x44cd09), so an
/// exported weight comes back as the same bits.
fn percentOf(w: f32) f32 {
    var p: f32 = w * 100;
    for (0..4) |_| {
        const back: f32 = p * 0.01;
        if (back == w) break;
        p = if (back < w) std.math.nextAfter(f32, p, std.math.inf(f32)) else std.math.nextAfter(f32, p, -std.math.inf(f32));
    }
    return p;
}

/// Texture of material `mat` as a `.3df` (argb4444 with mips, halved down to 256): the
/// image's name when it is a `.3df` name, else `<model>_<n>.3df`.
fn importTexture(g: Gltf, a: Allocator, mat: u32, model: []const u8, names: *std.ArrayList([]const u8), files: anytype) ![]const u8 {
    const mats = g.doc.materials orelse return "";
    if (mat >= mats.len) return error.BadGlb;
    const ti = ((mats[mat].pbrMetallicRoughness orelse return "").baseColorTexture orelse return "").index;
    const texs = g.doc.textures orelse return error.BadGlb;
    if (ti >= texs.len) return error.BadGlb;
    const si = texs[ti].source orelse return "";
    const imgs = g.doc.images orelse return error.BadGlb;
    if (si >= imgs.len) return error.BadGlb;
    const im = imgs[si];
    const nm = im.name orelse "";
    const tex_name = if (std.ascii.endsWithIgnoreCase(nm, ".3df")) nm else try std.fmt.allocPrint(a, "{s}_{d}.3df", .{ model, si });
    for (names.items) |n| if (std.ascii.eqlIgnoreCase(n, tex_name)) return n;
    const views = g.doc.bufferViews orelse return error.BadGlb;
    const vi = im.bufferView orelse return error.ExternalImage;
    if (vi >= views.len or views[vi].byteOffset + views[vi].byteLength > g.bin.len) return error.BadGlb;
    var img = try jpeg.decode(a, g.bin[views[vi].byteOffset..][0..views[vi].byteLength]);
    while (@max(img.width, img.height) > 256) img = try tex3df.half(a, img);
    try names.append(a, tex_name);
    try files.append(a, .{ .name = tex_name, .data = try tex3df.encodeArgb4444(a, img) });
    return tex_name;
}

/// A bone in the bind pose (frames no animation covers).
const rest_matrix = [12]f32{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0 };

/// Input sampler of an animation channel.
const Sampler = struct {
    times: [][1]f32,
    values: [][4]f32,
    step: bool,
    /// CUBICSPLINE: (in-tangent, value, out-tangent) per key.
    cubic: bool,

    fn at(s: Sampler, t: f32) [4]f32 {
        const n = s.times.len;
        const k: usize = if (s.cubic) 3 else 1;
        const off: usize = if (s.cubic) 1 else 0;
        if (n == 0) return .{ 0, 0, 0, 1 };
        if (t <= s.times[0][0]) return s.values[off];
        var i: usize = 0;
        while (i + 1 < n and s.times[i + 1][0] <= t) i += 1;
        if (i + 1 >= n or s.times[i][0] == t or s.step) return s.values[i * k + off];
        // shortcut: CUBICSPLINE is read as LINEAR between its key values (tangents
        // ignored); exact enough for baked per-frame keys, sample properly if needed.
        const x0 = s.values[i * k + off];
        var x1 = s.values[(i + 1) * k + off];
        const f = (t - s.times[i][0]) / (s.times[i + 1][0] - s.times[i][0]);
        if (dot4(x0, x1) < 0) x1 = .{ -x1[0], -x1[1], -x1[2], -x1[3] };
        var o: [4]f32 = undefined;
        for (&o, x0, x1) |*d, p, q| d.* = p + (q - p) * f;
        return o;
    }
};

/// The animations of `g` as `.ani` entries and frames appended to `mats` (`bones` per
/// frame). `keep_place`: frames go back to the extras' first…last when free (or holding
/// the same matrices), as they were in the exported model.
fn importAnimations(g: Gltf, a: Allocator, sk: Skeleton, bones: usize, anims: *std.ArrayList(anim.Animation), mats: *std.ArrayList([12]f32), keep_place: bool) !void {
    const gl_anims = g.doc.animations orelse return;
    if (bones == 0) return;
    const nn = g.nodes().len;
    var placed: std.ArrayList(bool) = .empty;
    try placed.appendNTimes(a, false, mats.items.len / bones);
    for (gl_anims, 0..) |ga, ai| {
        // Channels by node and path (translation, rotation, scale).
        const ch = try a.alloc([3]?Sampler, nn);
        @memset(ch, .{ null, null, null });
        var dur: f32 = 0;
        for (ga.channels) |c| {
            const node = c.target.node orelse continue;
            const path: usize = if (std.mem.eql(u8, c.target.path, "translation")) 0 else if (std.mem.eql(u8, c.target.path, "rotation")) 1 else if (std.mem.eql(u8, c.target.path, "scale")) 2 else continue;
            if (node >= nn or c.sampler >= ga.samplers.len) return error.BadGlb;
            const s = ga.samplers[c.sampler];
            const interp = s.interpolation orelse "LINEAR";
            const smp: Sampler = .{ .times = try readAccessor(g, a, s.input, 1), .values = try readAccessor(g, a, s.output, 4), .step = std.mem.eql(u8, interp, "STEP"), .cubic = std.mem.eql(u8, interp, "CUBICSPLINE") };
            if (smp.values.len < smp.times.len * @as(usize, if (smp.cubic) 3 else 1)) return error.BadGlb;
            if (smp.times.len > 0) dur = @max(dur, smp.times[smp.times.len - 1][0]);
            ch[node][path] = smp;
        }
        const count: u32 = @as(u32, @intFromFloat(@round(dur * fps))) + 1;
        const start = mats.items.len;
        const world = try a.alloc(Mat, nn);
        const done = try a.alloc(bool, nn);
        for (0..count) |k| {
            @memset(done, false);
            const row = try mats.addManyAsSlice(a, bones);
            @memset(row, rest_matrix);
            for (sk.joints, sk.bone, sk.ibm) |jn, bone, ibm| if (bone) |b| {
                row[b] = toBfr(mul(worldAt(g, ch, frameTime(k), jn, world, done), ibm));
            };
        }
        // Back to the exported place when it is free or already holds these frames.
        const ex = ga.extras;
        var first: u32 = @intCast(start / bones);
        if (keep_place) if (ex) |e| if (e.first) |f| if (e.last == null or e.last.? == f + count - 1) {
            const new = mats.items[start..];
            var fits = true;
            for (0..count) |k| {
                const slot = f + k;
                if (slot < placed.items.len and placed.items[slot] and !std.mem.eql(u8, std.mem.sliceAsBytes(mats.items[slot * bones ..][0..bones]), std.mem.sliceAsBytes(new[k * bones ..][0..bones]))) fits = false;
            }
            if (fits) {
                const moved = try a.dupe([12]f32, new);
                mats.shrinkRetainingCapacity(start);
                if (mats.items.len < (f + count) * bones) {
                    const old_len = mats.items.len;
                    try mats.resize(a, (f + count) * bones);
                    @memset(mats.items[old_len..], rest_matrix);
                }
                @memcpy(mats.items[f * bones ..][0 .. count * bones], moved);
                first = f;
            }
        };
        if (placed.items.len < mats.items.len / bones) try placed.appendNTimes(a, false, mats.items.len / bones - placed.items.len);
        @memset(placed.items[first..][0..count], true);
        const sounds = try a.dupe(anim.SoundCue, if (ex) |e| e.sounds orelse &.{} else &.{});
        const was: u32 = if (ex) |e| e.first orelse first else first;
        for (sounds) |*s| s.frame = s.frame -% was +% first;
        try anims.append(a, .{
            .name = ga.name orelse try std.fmt.allocPrint(a, "anim{d}", .{ai}),
            .first = first,
            .last = first + count - 1,
            .speed = if (ex) |e| e.speed orelse 1 else 1,
            .sounds = sounds,
        });
    }
}

/// World matrix of node `ni` at time `t` (memoized in `world`/`done`).
fn worldAt(g: Gltf, ch: []const [3]?Sampler, t: f32, ni: u32, world: []Mat, done: []bool) Mat {
    if (done[ni]) return world[ni];
    const n = g.nodes()[ni];
    var local = restLocal(n);
    if (ch[ni][0] != null or ch[ni][1] != null or ch[ni][2] != null) {
        const tr = if (ch[ni][0]) |s| s.at(t)[0..3].* else n.translation orelse .{ 0, 0, 0 };
        const rot = if (ch[ni][1]) |s| s.at(t) else n.rotation orelse .{ 0, 0, 0, 1 };
        const sc = if (ch[ni][2]) |s| s.at(t)[0..3].* else n.scale orelse .{ 1, 1, 1 };
        local = trsMatrix(tr, rot, sc);
    }
    world[ni] = if (g.parent[ni]) |p| mul(worldAt(g, ch, t, p, world, done), local) else local;
    done[ni] = true;
    return world[ni];
}

/// Bone frames from matrices (at least one frame: the bind pose), with each frame's
/// skinned bounds.
fn finishFrames(a: Allocator, m: mesh_fmt.Mesh, mats: []const [12]f32) !anim.BoneFrames {
    const bones = m.joints.len;
    var all = mats;
    var frames: u32 = if (bones == 0) 1 else @intCast(mats.len / bones);
    if (frames == 0) {
        frames = 1;
        const id = try a.alloc([12]f32, bones);
        @memset(id, rest_matrix);
        all = id;
    }
    const bf: anim.BoneFrames = .{ .frames = frames, .bones = @intCast(bones), .matrices = @constCast(all), .extra = try a.alloc([6]f32, frames) };
    for (bf.extra, 0..) |*e, f| {
        var lo: [3]f32 = @splat(std.math.inf(f32));
        var hi: [3]f32 = @splat(-std.math.inf(f32));
        for (try skin.pose(a, m, bf, @intCast(f), .row)) |part| for (part) |v| for (0..3) |k| {
            lo[k] = @min(lo[k], v[k]);
            hi[k] = @max(hi[k], v[k]);
        };
        if (lo[0] > hi[0]) {
            lo = @splat(0);
            hi = @splat(0);
        }
        e.* = lo ++ hi;
    }
    return bf;
}

test "export then import gives the model back" {
    const gpa = std.testing.allocator;
    var verts = [_]mesh_fmt.Vertex{ .{ .pos = .{ 0, 0, 0 }, .uv = .{ 0, 0 } }, .{ .pos = .{ 1, 0, 0 }, .uv = .{ 1, 0 }, .id = 1 }, .{ .pos = .{ 0, 1, -0.0 }, .uv = .{ 0, 1 }, .id = 2 } };
    var ranges = [_][2]u32{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 2 } };
    var infl = [_]mesh_fmt.Influence{ .{ .bone = 0, .weight = 1, .percent = 100 }, .{ .bone = 0, .weight = 0.6, .percent = 60 } };
    var tris = [_][3]u16{.{ 0, 1, 2 }};
    var parts = [_]mesh_fmt.Part{.{ .name = "body", .vertices = &verts, .ranges = &ranges, .influences = &infl, .triangles = &tris, .texture = "t.3df" }};
    var joints = [_][3]f32{.{ 0, 5, 0 }};
    var holds = [_]mesh_fmt.HoldMode{.{ .name = "one_hand", .params = .{ 1, 2, 3, 0.1, -0.2, 0.3 }, .bone = 0 }};
    const m: mesh_fmt.Mesh = .{ .arena = undefined, .center = .{ 0, 9.4, 0 }, .has_rotation = true, .height = 24, .joints = &joints, .texture = "t.3df", .animations = "x.ani", .hold_modes = &holds, .parts = &parts };
    var sounds = [_]anim.SoundCue{.{ .name = "a.wav", .frame = 2, .volume = 100 }};
    const anims = [_]anim.Animation{.{ .name = "turn", .first = 1, .last = 2, .speed = 1, .sounds = &sounds }};
    // Frame 0 rest, 1 moved, 2 turned 90° around Y.
    var mats = [_][12]f32{ rest_matrix, .{ 1, 0, 0, 0, 1, 0, 0, 0, 1, 2, 0, 0 }, .{ 0, 0, -1, 0, 1, 0, 1, 0, 0, 0, 0, 0 } };
    var extra: [3][6]f32 = undefined;
    const frames: anim.BoneFrames = .{ .frames = 3, .bones = 1, .matrices = &mats, .extra = &extra };
    var img = try Image.init(gpa, 2, 2);
    defer img.deinit(gpa);
    const glb_bytes = try exportGlb(gpa, "x", m, &anims, frames, &.{img});
    defer gpa.free(glb_bytes);

    var files = try importGlb(gpa, glb_bytes, "x");
    defer files.deinit();
    const want = try mesh_fmt.encode(gpa, m);
    defer gpa.free(want);
    try std.testing.expectEqualSlices(u8, want, files.msh);
    const want_ani = try anim.writeAni(gpa, &anims);
    defer gpa.free(want_ani);
    try std.testing.expectEqualSlices(u8, want_ani, files.ani);
    try std.testing.expectEqualStrings("t.3df", files.textures[0].name);
    var back = try anim.parseBfr(gpa, files.bfr, 1);
    defer back.deinit(gpa);
    try std.testing.expectEqual(3, back.frames);
    for (mats, back.matrices) |x, y| for (x, y) |p, q| try std.testing.expectApproxEqAbs(p, q, 1e-5);
    // Frame 1 bounds (bone +2 x): the 60% vertex moves 1.2, its 40% stays on the bind pose.
    try std.testing.expectApproxEqAbs(@as(f32, 2.2), back.extra[1][3], 1e-5);

    // Its animations into a model having "turn" and "idle": "turn" replaced, none added.
    const two = [_]anim.Animation{ .{ .name = "idle", .first = 0, .last = 0, .speed = 1, .sounds = &.{} }, anims[0] };
    var into = try importAnimationsInto(gpa, glb_bytes, m, &two, frames);
    defer into.deinit();
    var list = try anim.parseAni(gpa, into.ani);
    defer list.deinit();
    try std.testing.expectEqual(2, list.items.len);
    // The old "turn" frames dropped: again 3 frames, "turn" on 1…2 with its sound on 2.
    var got = try anim.parseBfr(gpa, into.bfr, 1);
    defer got.deinit(gpa);
    try std.testing.expectEqual(3, got.frames);
    var again = try importAnimationsInto(gpa, glb_bytes, m, list.items, got);
    defer again.deinit();
    try std.testing.expectEqual(into.bfr.len, again.bfr.len);
    var list2 = try anim.parseAni(gpa, again.ani);
    defer list2.deinit();
    const t = list2.find("turn").?;
    try std.testing.expectEqual(1, t.first);
    try std.testing.expectEqual(2, t.last);
    try std.testing.expectEqual(2, t.sounds[0].frame);
    for (mats[1..], got.matrices[1..]) |x, y| for (x, y) |p, q| try std.testing.expectApproxEqAbs(p, q, 1e-5);
}

test anglesXYZ {
    const a = [3]f32{ 0.3, -1.1, 2.5 };
    var r: [9]f64 = undefined;
    for (&r, rotationXYZ(a)) |*d, v| d.* = v;
    for (anglesXYZ(r), a) |x, y| try std.testing.expectApproxEqAbs(y, x, 1e-5);
}

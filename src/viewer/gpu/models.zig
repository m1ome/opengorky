//! Models on the GPU (`--renderer gpu`): the model layer's models (render/layer.zig
//! `Sink`) drawn by SDL GPU into a texture of the layer's size, which goes over the CPU
//! layer (shadows, effects) on the 2D renderer of the same device.
//!
//! Whole models (`Sink.mesh`) are skinned, lit and projected on the GPU: their parts' bind
//! pose, weights, triangles and welded-vertex triangle lists are uploaded once
//! (`GMesh`), each frame only the bone matrices and the lamps; compute `pose.comp` poses
//! the vertices, `light.comp` computes what `drawParts` does per vertex into the vertex
//! buffer, also growing the frame's depth range and each drawn thing's screen box (read
//! back a frame late). Parts the CPU prepared (`Sink.part`: weapons in hand, effects
//! meshes) are uploaded as vertices. Then one render pass draws them all in the order
//! drawn — a depth buffer between models, `.zbf` depth (a float texture) against the
//! background, mip-mapped textures, opaque or alpha-blended — as the software canvas does.
//! Shadows follow (the casters posed, cast into a mask, composited), then the effects
//! (`Sink.effect`: billboards, attachment-point meshes) into the color, glow and screen
//! targets, depth-tested against the models and the background.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const og = @import("opengorky");
const Image = og.image.Image;
const Layer = og.render.layer.Layer;
const Model = og.actor.model_cache.Model;
const camera = og.actor.camera;

const shaders = struct {
    const vert_spv = @embedFile("shaders/model.vert.spv");
    const frag_spv = @embedFile("shaders/model.frag.spv");
    const pose_spv = @embedFile("shaders/pose.comp.spv");
    const light_spv = @embedFile("shaders/light.comp.spv");
    const mask_vert_spv = @embedFile("shaders/mask.vert.spv");
    const mask_frag_spv = @embedFile("shaders/mask.frag.spv");
    const comp_vert_spv = @embedFile("shaders/composite.vert.spv");
    const comp_frag_spv = @embedFile("shaders/composite.frag.spv");
    const shadow_spv = @embedFile("shaders/shadow.comp.spv");
    const tiles_spv = @embedFile("shaders/tiles.comp.spv");
    const mask_vert_msl = @embedFile("shaders/mask.vert.msl");
    const mask_frag_msl = @embedFile("shaders/mask.frag.msl");
    const comp_vert_msl = @embedFile("shaders/composite.vert.msl");
    const comp_frag_msl = @embedFile("shaders/composite.frag.msl");
    const shadow_msl = @embedFile("shaders/shadow.comp.msl");
    const tiles_msl = @embedFile("shaders/tiles.comp.msl");
    const vert_msl = @embedFile("shaders/model.vert.msl");
    const frag_msl = @embedFile("shaders/model.frag.msl");
    const pose_msl = @embedFile("shaders/pose.comp.msl");
    const light_msl = @embedFile("shaders/light.comp.msl");
    const fx_vert_spv = @embedFile("shaders/effect.vert.spv");
    const fx_frag_spv = @embedFile("shaders/effect.frag.spv");
    const fx_vert_msl = @embedFile("shaders/effect.vert.msl");
    const fx_frag_msl = @embedFile("shaders/effect.frag.msl");
};

const Vertex = extern struct { pos: [3]f32, uv: [2]f32, col: [3]f32 };
const SVert = extern struct { pos: [4]f32, start: u32, count: u32, uv: [2]f32 };
const FrameU = extern struct { size: [2]f32, _pad: [2]f32 = .{ 0, 0 } };
const DrawU = extern struct { alpha: f32, bias: f32, textured: f32, ss: f32 };
const PoseU = extern struct { n: u32, posed_base: u32, bone_base: u32, skinned: u32 };
const LightU = extern struct {
    local0: [4]f32,
    local1: [4]f32,
    local2: [4]f32,
    center_s: [4]f32,
    pos_aspect: [4]f32,
    rot: [4]f32,
    origin: [4]f32,
    ambient: [4]f32,
    directional: [4]f32,
    ortho: [4]f32,
    eye_scale: [4]f32,
    fwd: [4]f32,
    right: [4]f32,
    up: [4]f32,
    persp: [4]f32,
    counts: [4]u32,
    box: [4]u32,
};

const ShadowU = extern struct {
    local0: [4]f32,
    local1: [4]f32,
    local2: [4]f32,
    center_s: [4]f32,
    pos_zg: [4]f32,
    light: [4]f32,
    rot: [4]f32,
    origin: [4]f32,
    ortho: [4]f32,
    eye_scale: [4]f32,
    fwd: [4]f32,
    right: [4]f32,
    up: [4]f32,
    persp: [4]f32,
    counts: [4]u32,
};
const TilesU = extern struct { n: u32, w: f32, h: f32, _pad: u32 = 0 };
const FxU = extern struct { mode_alpha: [4]f32, scale: [4]f32, tint: [4]f32, uvx: [4]f32 };
const CompU = extern struct { screen: [4]f32, origin: [4]f32, ortho: [4]f32, eye_scale: [4]f32, fwd: [4]f32, right: [4]f32, up: [4]f32, persp: [4]f32 };

/// The camera as the shaders take it: the isometric one's cos, sin, k; the perspective one's.
const CamU = struct { persp: bool, ortho: [4]f32, eye_scale: [4]f32 = @splat(0), fwd: [4]f32 = @splat(0), right: [4]f32 = @splat(0), up: [4]f32 = @splat(0), lens: [4]f32 = @splat(0) };

fn camU(cam: camera.Camera) CamU {
    var o: CamU = .{ .persp = cam == .persp, .ortho = .{ cam.project(.{ 1, 0, 0 }).x, cam.project(.{ 0, 1, 0 }).x, camera.k, 0 } };
    if (cam == .persp) {
        const pc = cam.persp;
        o.eye_scale = .{ pc.eye[0], pc.eye[1], pc.eye[2], pc.scale };
        o.fwd = .{ pc.fwd[0], pc.fwd[1], pc.fwd[2], 0 };
        o.right = .{ pc.right[0], pc.right[1], pc.right[2], 0 };
        o.up = .{ pc.up[0], pc.up[1], pc.up[2], 0 };
        o.lens = .{ pc.focal, pc.focal_y, pc.cx, pc.cy };
    }
    return o;
}

const local_size = 64;
const mask_size = 512;

/// Pipeline variant: back faces culled, alpha-blended, depth written.
const Key = packed struct(u3) { cull: bool, blend: bool, write: bool };

/// A draw: `count` indices from `first` of the frame's index buffer, or of `ibuf` (a
/// part's own triangles); vertices from `base` of the computed region (`computed`) or of
/// the CPU's vertices that follow it.
const Draw = struct { first: u32, count: u32, base: u32, computed: bool, ibuf: ?*c.SDL_GPUBuffer, tex: ?*c.SDL_GPUTexture, key: Key, alpha: f32, bias: f32 };

/// A mesh part on the GPU: bind pose and weights, triangles (also its index buffer),
/// each vertex's welded group of triangle corners.
const GPart = struct { verts: *c.SDL_GPUBuffer, infl: *c.SDL_GPUBuffer, tris: *c.SDL_GPUBuffer, grp: *c.SDL_GPUBuffer, corners: *c.SDL_GPUBuffer, n: u32, ntri: u32 };

/// An effect draw: `count` vertices from `first` of the CPU's, or (`ibuf`: a computed
/// part's triangles, an actor's additive pass) `count` indices of the computed vertices
/// from `base`; blended by `mode` (0 alpha, 1 add, 2 screen: the effect pipelines).
/// `tint`: that colour instead of the vertices' (rgb, 1); `uvx`: uv scale, offset, wrap
/// (1); `cull`: back faces skipped.
const FxDraw = struct {
    first: u32,
    count: u32,
    base: u32 = 0,
    ibuf: ?*c.SDL_GPUBuffer = null,
    tex: *c.SDL_GPUTexture,
    mode: u2,
    alpha: f32 = 1,
    program: f32 = 0,
    k: f32 = 0,
    tint: [4]f32 = @splat(0),
    uvx: [4]f32 = .{ 1, 0, 0, 0 },
    cull: bool = false,
};

const Job = struct { part: *const GPart, pose: PoseU, light: LightU };
const SJob = struct { part: *const GPart, pose: PoseU, su: ShadowU };

/// The process's pass (run.zig sets it with --renderer gpu), as the raster pool is one.
pub var active: ?*GpuModels = null;

pub const GpuModels = struct {
    gpa: Allocator,
    device: *c.SDL_GPUDevice,
    renderer: *c.SDL_Renderer,
    pipes: [8]*c.SDL_GPUGraphicsPipeline,
    pose_pipe: *c.SDL_GPUComputePipeline,
    light_pipe: *c.SDL_GPUComputePipeline,
    shadow_pipe: *c.SDL_GPUComputePipeline,
    tiles_pipe: *c.SDL_GPUComputePipeline,
    mask_pipe: *c.SDL_GPUGraphicsPipeline,
    comp_pipe: *c.SDL_GPUGraphicsPipeline,
    fx_pipes: [3]*c.SDL_GPUGraphicsPipeline,
    smp_tex: *c.SDL_GPUSampler,
    smp_bg: *c.SDL_GPUSampler,
    /// 1×1 white for untextured parts (the shader greys them).
    blank: *c.SDL_GPUTexture,
    /// Model textures by their top level's pixels (Textures keeps them for the run).
    textures: std.AutoHashMapUnmanaged(usize, *c.SDL_GPUTexture) = .empty,
    /// Meshes by their parts' address (the model cache keeps them for the run).
    meshes: std.AutoHashMapUnmanaged(usize, []GPart) = .empty,

    // The frame: CPU-prepared vertices and indices, the computed models, the draws.
    verts: std.ArrayList(Vertex) = .empty,
    indices: std.ArrayList(u32) = .empty,
    draws: std.ArrayList(Draw) = .empty,
    fx: std.ArrayList(FxDraw) = .empty,
    jobs: std.ArrayList(Job) = .empty,
    /// Shadows: their parts posed and cast, the casters' floor heights in order.
    sjobs: std.ArrayList(SJob) = .empty,
    floors: std.ArrayList(f32) = .empty,
    n_posed: u32 = 0,
    n_shadow: u32 = 0,
    bones: std.ArrayList([12]f32) = .empty,
    omni: std.ArrayList([2][4]f32) = .empty,
    lamps_set: bool = false,
    n_computed: u32 = 0,
    zmin: f32 = std.math.inf(f32),
    zmax: f32 = -std.math.inf(f32),
    /// Screen boxes: this frame's slots by id, last frame's boxes by id.
    box_slots: std.AutoArrayHashMapUnmanaged(usize, void) = .empty,
    box_prev: std.AutoHashMapUnmanaged(usize, [4]f32) = .empty,
    box_fence: ?*c.SDL_GPUFence = null,
    box_ids: std.ArrayList(usize) = .empty,

    // Buffers grown as needed.
    vbuf: ?*c.SDL_GPUBuffer = null,
    vcap: u32 = 0,
    ibuf: ?*c.SDL_GPUBuffer = null,
    icap: u32 = 0,
    posed: ?*c.SDL_GPUBuffer = null,
    pcap: u32 = 0,
    bbuf: ?*c.SDL_GPUBuffer = null,
    bcap: u32 = 0,
    obuf: ?*c.SDL_GPUBuffer = null,
    ocap: u32 = 0,
    boxes: ?*c.SDL_GPUBuffer = null,
    boxcap: u32 = 0,
    zrange: *c.SDL_GPUBuffer,
    svbuf: ?*c.SDL_GPUBuffer = null,
    svcap: u32 = 0,
    sboxes: ?*c.SDL_GPUBuffer = null,
    sbcap: u32 = 0,
    fbuf: ?*c.SDL_GPUBuffer = null,
    fcap: u32 = 0,
    tiles: *c.SDL_GPUBuffer,
    xfer: ?*c.SDL_GPUTransferBuffer = null,
    xcap: u32 = 0,
    dl: ?*c.SDL_GPUTransferBuffer = null,
    dlcap: u32 = 0,

    // Targets of the layer's size.
    w: u32 = 0,
    h: u32 = 0,
    ss: u32 = 1,
    color: ?*c.SDL_GPUTexture = null,
    depth: ?*c.SDL_GPUTexture = null,
    /// The models' canvas depth (where they wrote it; 3e38 elsewhere): the shadow test.
    zcol: ?*c.SDL_GPUTexture = null,
    mask: *c.SDL_GPUTexture,
    bg: ?*c.SDL_GPUTexture = null,
    bw: u32 = 0,
    bh: u32 = 0,
    /// What `bg` holds: uploaded again only when the background depth changed (scroll,
    /// a gate's z-frame), not every frame.
    bg_last: std.ArrayList(f32) = .empty,
    /// Additive and screen effects (the CPU layer's `glow`, `screen`).
    glow: ?*c.SDL_GPUTexture = null,
    screen: ?*c.SDL_GPUTexture = null,
    /// What `color` starts as each frame (premultiplied): none in the game, the editor
    /// preview's background there.
    clear: [4]f32 = @splat(0),
    /// `color`, `glow`, `screen` as the 2D renderer's textures; the last two are shown
    /// only when used this frame.
    tex: ?*c.SDL_Texture = null,
    glow_tex: ?*c.SDL_Texture = null,
    screen_tex: ?*c.SDL_Texture = null,
    glow_used: bool = false,
    screen_used: bool = false,

    /// On the 2D renderer's device; null when it is not a GPU renderer or the shaders do
    /// not load (the CPU draws the models then).
    pub fn init(gpa: Allocator, renderer: *c.SDL_Renderer) ?*GpuModels {
        const dev = c.SDL_GetGPURendererDevice(renderer) orelse return null;
        const self = gpa.create(GpuModels) catch return null;
        self.* = make(gpa, dev, renderer) catch |err| {
            std.log.warn("GPU models off: {t} ({s})", .{ err, c.SDL_GetError() });
            gpa.destroy(self);
            return null;
        };
        return self;
    }

    fn make(gpa: Allocator, dev: *c.SDL_GPUDevice, renderer: *c.SDL_Renderer) !GpuModels {
        const formats = c.SDL_GetGPUShaderFormats(dev);
        const msl = formats & c.SDL_GPU_SHADERFORMAT_MSL != 0;
        if (!msl and formats & c.SDL_GPU_SHADERFORMAT_SPIRV == 0) return error.NoShaderFormat;
        const vs = try shader(dev, if (msl) shaders.vert_msl else shaders.vert_spv, msl, c.SDL_GPU_SHADERSTAGE_VERTEX, 0, 1, 1);
        defer c.SDL_ReleaseGPUShader(dev, vs);
        const fs = try shader(dev, if (msl) shaders.frag_msl else shaders.frag_spv, msl, c.SDL_GPU_SHADERSTAGE_FRAGMENT, 2, 0, 1);
        defer c.SDL_ReleaseGPUShader(dev, fs);
        var pipes: [8]*c.SDL_GPUGraphicsPipeline = undefined;
        for (&pipes, 0..) |*p, i| p.* = try pipeline(dev, vs, fs, @bitCast(@as(u3, @intCast(i))));
        const pose_pipe = try compute(dev, if (msl) shaders.pose_msl else shaders.pose_spv, msl, 3, 1);
        const light_pipe = try compute(dev, if (msl) shaders.light_msl else shaders.light_spv, msl, 6, 3);
        const shadow_pipe = try compute(dev, if (msl) shaders.shadow_msl else shaders.shadow_spv, msl, 1, 2);
        const tiles_pipe = try compute(dev, if (msl) shaders.tiles_msl else shaders.tiles_spv, msl, 2, 1);
        const mvs = try shader(dev, if (msl) shaders.mask_vert_msl else shaders.mask_vert_spv, msl, c.SDL_GPU_SHADERSTAGE_VERTEX, 0, 0, 0);
        defer c.SDL_ReleaseGPUShader(dev, mvs);
        const mfs = try shader(dev, if (msl) shaders.mask_frag_msl else shaders.mask_frag_spv, msl, c.SDL_GPU_SHADERSTAGE_FRAGMENT, 0, 0, 0);
        defer c.SDL_ReleaseGPUShader(dev, mfs);
        const mask_pipe = try maskPipeline(dev, mvs, mfs);
        const cvs = try shader(dev, if (msl) shaders.comp_vert_msl else shaders.comp_vert_spv, msl, c.SDL_GPU_SHADERSTAGE_VERTEX, 0, 0, 0);
        defer c.SDL_ReleaseGPUShader(dev, cvs);
        const cfs = try shader(dev, if (msl) shaders.comp_frag_msl else shaders.comp_frag_spv, msl, c.SDL_GPU_SHADERSTAGE_FRAGMENT, 3, 1, 1);
        defer c.SDL_ReleaseGPUShader(dev, cfs);
        const comp_pipe = try compositePipeline(dev, cvs, cfs);
        const evs = try shader(dev, if (msl) shaders.fx_vert_msl else shaders.fx_vert_spv, msl, c.SDL_GPU_SHADERSTAGE_VERTEX, 0, 0, 1);
        defer c.SDL_ReleaseGPUShader(dev, evs);
        const efs = try shader(dev, if (msl) shaders.fx_frag_msl else shaders.fx_frag_spv, msl, c.SDL_GPU_SHADERSTAGE_FRAGMENT, 3, 0, 1);
        defer c.SDL_ReleaseGPUShader(dev, efs);
        var fx_pipes: [3]*c.SDL_GPUGraphicsPipeline = undefined;
        for (&fx_pipes, 0..) |*p, i| p.* = try effectPipeline(dev, evs, efs, @intCast(i));
        const smp_tex = c.SDL_CreateGPUSampler(dev, &.{
            .min_filter = c.SDL_GPU_FILTER_LINEAR,
            .mag_filter = c.SDL_GPU_FILTER_LINEAR,
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .max_lod = 1000,
        }) orelse return error.Sampler;
        const smp_bg = c.SDL_CreateGPUSampler(dev, &.{
            .min_filter = c.SDL_GPU_FILTER_NEAREST,
            .mag_filter = c.SDL_GPU_FILTER_NEAREST,
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        }) orelse return error.Sampler;
        const zrange = c.SDL_CreateGPUBuffer(dev, &.{ .usage = c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE | c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ | c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ, .size = 8 }) orelse return error.GpuBuffer;
        const tiles = c.SDL_CreateGPUBuffer(dev, &.{ .usage = c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE | c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ, .size = 64 * 4 }) orelse return error.GpuBuffer;
        const mask = c.SDL_CreateGPUTexture(dev, &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R8_UNORM,
            .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = mask_size,
            .height = mask_size,
            .layer_count_or_depth = 1,
            .num_levels = 1,
        }) orelse return error.GpuTexture;
        var self: GpuModels = .{ .gpa = gpa, .device = dev, .renderer = renderer, .pipes = pipes, .pose_pipe = pose_pipe, .light_pipe = light_pipe, .shadow_pipe = shadow_pipe, .tiles_pipe = tiles_pipe, .mask_pipe = mask_pipe, .comp_pipe = comp_pipe, .fx_pipes = fx_pipes, .smp_tex = smp_tex, .smp_bg = smp_bg, .blank = undefined, .zrange = zrange, .tiles = tiles, .mask = mask };
        const white = [4]u8{ 255, 255, 255, 255 };
        self.blank = try self.upload(&.{.{ .width = 1, .height = 1, .pixels = @constCast(&white) }});
        return self;
    }

    pub fn deinit(self: *GpuModels) void {
        const dev = self.device;
        if (self.box_fence) |f| {
            _ = c.SDL_WaitForGPUFences(dev, true, &f, 1);
            c.SDL_ReleaseGPUFence(dev, f);
        }
        self.forget();
        self.textures.deinit(self.gpa);
        self.meshes.deinit(self.gpa);
        self.freeTargets();
        for ([_]?*c.SDL_GPUBuffer{ self.vbuf, self.ibuf, self.posed, self.bbuf, self.obuf, self.boxes, self.zrange, self.svbuf, self.sboxes, self.fbuf, self.tiles }) |b| if (b) |x| c.SDL_ReleaseGPUBuffer(dev, x);
        c.SDL_ReleaseGPUTexture(dev, self.mask);
        c.SDL_ReleaseGPUComputePipeline(dev, self.shadow_pipe);
        c.SDL_ReleaseGPUComputePipeline(dev, self.tiles_pipe);
        c.SDL_ReleaseGPUGraphicsPipeline(dev, self.mask_pipe);
        c.SDL_ReleaseGPUGraphicsPipeline(dev, self.comp_pipe);
        for (self.fx_pipes) |p| c.SDL_ReleaseGPUGraphicsPipeline(dev, p);
        self.fx.deinit(self.gpa);
        self.sjobs.deinit(self.gpa);
        self.floors.deinit(self.gpa);
        if (self.xfer) |b| c.SDL_ReleaseGPUTransferBuffer(dev, b);
        if (self.dl) |b| c.SDL_ReleaseGPUTransferBuffer(dev, b);
        c.SDL_ReleaseGPUTexture(dev, self.blank);
        for (self.pipes) |p| c.SDL_ReleaseGPUGraphicsPipeline(dev, p);
        c.SDL_ReleaseGPUComputePipeline(dev, self.pose_pipe);
        c.SDL_ReleaseGPUComputePipeline(dev, self.light_pipe);
        c.SDL_ReleaseGPUSampler(dev, self.smp_tex);
        c.SDL_ReleaseGPUSampler(dev, self.smp_bg);
        self.bg_last.deinit(self.gpa);
        self.verts.deinit(self.gpa);
        self.indices.deinit(self.gpa);
        self.draws.deinit(self.gpa);
        self.jobs.deinit(self.gpa);
        self.bones.deinit(self.gpa);
        self.omni.deinit(self.gpa);
        self.box_slots.deinit(self.gpa);
        self.box_prev.deinit(self.gpa);
        self.box_ids.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// The uploaded textures and meshes dropped (the editor read its models again: their
    /// memory, the caches' keys, may be another model's now).
    pub fn forget(self: *GpuModels) void {
        const dev = self.device;
        _ = c.SDL_WaitForGPUIdle(dev);
        var it = self.textures.valueIterator();
        while (it.next()) |t| c.SDL_ReleaseGPUTexture(dev, t.*);
        self.textures.clearRetainingCapacity();
        var mi = self.meshes.valueIterator();
        while (mi.next()) |parts| {
            for (parts.*) |p| for ([_]*c.SDL_GPUBuffer{ p.verts, p.infl, p.tris, p.grp, p.corners }) |b| c.SDL_ReleaseGPUBuffer(dev, b);
            self.gpa.free(parts.*);
        }
        self.meshes.clearRetainingCapacity();
    }

    fn freeTargets(self: *GpuModels) void {
        for ([_]?*c.SDL_Texture{ self.tex, self.glow_tex, self.screen_tex }) |t| if (t) |x| c.SDL_DestroyTexture(x);
        for ([_]?*c.SDL_GPUTexture{ self.glow, self.screen }) |t| if (t) |x| c.SDL_ReleaseGPUTexture(self.device, x);
        self.glow_tex = null;
        self.screen_tex = null;
        self.glow = null;
        self.screen = null;
        if (self.color) |t| c.SDL_ReleaseGPUTexture(self.device, t);
        if (self.depth) |t| c.SDL_ReleaseGPUTexture(self.device, t);
        if (self.zcol) |t| c.SDL_ReleaseGPUTexture(self.device, t);
        if (self.bg) |t| c.SDL_ReleaseGPUTexture(self.device, t);
        self.zcol = null;
        self.tex = null;
        self.color = null;
        self.depth = null;
        self.bg = null;
    }

    /// A new frame on a `w`×`h` canvas (`ss` canvas pixels per background pixel); last
    /// frame's screen boxes read back.
    pub fn begin(self: *GpuModels, w: u32, h: u32, ss: u32) !void {
        self.readBoxes();
        self.verts.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
        self.draws.clearRetainingCapacity();
        self.fx.clearRetainingCapacity();
        self.glow_used = false;
        self.screen_used = false;
        self.jobs.clearRetainingCapacity();
        self.sjobs.clearRetainingCapacity();
        self.floors.clearRetainingCapacity();
        self.n_posed = 0;
        self.n_shadow = 0;
        self.bones.clearRetainingCapacity();
        self.omni.clearRetainingCapacity();
        self.box_slots.clearRetainingCapacity();
        self.lamps_set = false;
        self.n_computed = 0;
        self.zmin = std.math.inf(f32);
        self.zmax = -std.math.inf(f32);
        if (self.color != null and self.w == w and self.h == h and self.ss == ss) return;
        self.freeTargets();
        self.w = w;
        self.h = h;
        self.ss = ss;
        const dev = self.device;
        self.color = try self.target(&self.tex, c.SDL_BLENDMODE_BLEND_PREMULTIPLIED);
        // Added (ONE / ONE), as the CPU layer's glow texture (media/gfx.zig blendAdd).
        self.glow = try self.target(&self.glow_tex, c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDOPERATION_ADD, c.SDL_BLENDFACTOR_ZERO, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDOPERATION_ADD));
        // ONE / INVSRCCOLOR (0x408ad0 mode 4), as the CPU layer's screen texture.
        self.screen = try self.target(&self.screen_tex, c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_COLOR, c.SDL_BLENDOPERATION_ADD, c.SDL_BLENDFACTOR_ZERO, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDOPERATION_ADD));
        self.depth = c.SDL_CreateGPUTexture(dev, &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT,
            .usage = c.SDL_GPU_TEXTUREUSAGE_DEPTH_STENCIL_TARGET,
            .width = w,
            .height = h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
        }) orelse return error.GpuTexture;
        self.zcol = c.SDL_CreateGPUTexture(dev, &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R32_FLOAT,
            .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = w,
            .height = h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
        }) orelse return error.GpuTexture;
    }

    /// An RGBA target of the layer's size, also as a 2D renderer texture `tex` drawn with `blend`.
    fn target(self: *GpuModels, tex: *?*c.SDL_Texture, blend: c.SDL_BlendMode) !*c.SDL_GPUTexture {
        const t = c.SDL_CreateGPUTexture(self.device, &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = self.w,
            .height = self.h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
        }) orelse return error.GpuTexture;
        errdefer c.SDL_ReleaseGPUTexture(self.device, t);
        const props = c.SDL_CreateProperties();
        defer c.SDL_DestroyProperties(props);
        _ = c.SDL_SetPointerProperty(props, c.SDL_PROP_TEXTURE_CREATE_GPU_TEXTURE_POINTER, t);
        _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_TEXTURE_CREATE_FORMAT_NUMBER, c.SDL_PIXELFORMAT_ABGR8888);
        _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_TEXTURE_CREATE_ACCESS_NUMBER, c.SDL_TEXTUREACCESS_TARGET);
        _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_TEXTURE_CREATE_WIDTH_NUMBER, self.w);
        _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_TEXTURE_CREATE_HEIGHT_NUMBER, self.h);
        tex.* = c.SDL_CreateTextureWithProperties(self.renderer, props) orelse return error.GpuTexture;
        _ = c.SDL_SetTextureBlendMode(tex.*, blend);
        _ = c.SDL_SetTextureScaleMode(tex.*, c.SDL_SCALEMODE_NEAREST);
        return t;
    }

    /// Last frame's boxes (its fence passed long ago: the frame was presented).
    fn readBoxes(self: *GpuModels) void {
        const f = self.box_fence orelse return;
        const dev = self.device;
        _ = c.SDL_WaitForGPUFences(dev, true, &f, 1);
        c.SDL_ReleaseGPUFence(dev, f);
        self.box_fence = null;
        self.box_prev.clearRetainingCapacity();
        const src: [*]const u32 = @ptrCast(@alignCast(c.SDL_MapGPUTransferBuffer(dev, self.dl, false) orelse return));
        defer c.SDL_UnmapGPUTransferBuffer(dev, self.dl);
        for (self.box_ids.items, 0..) |id, i| {
            const b = [4]f32{ unordered(src[i * 4]), unordered(src[i * 4 + 1]), unordered(src[i * 4 + 2]), unordered(src[i * 4 + 3]) };
            if (b[0] <= b[2] and b[1] <= b[3]) self.box_prev.put(self.gpa, id, b) catch {};
        }
    }

    pub fn sink(self: *GpuModels) Layer.Sink {
        return .{ .ctx = self, .part = partCb, .mesh = meshCb, .shadow = shadowCb, .effect = effectCb };
    }

    fn effectCb(ctx: *anyopaque, d: Layer.EffectDraw) void {
        const self: *GpuModels = @ptrCast(@alignCast(ctx));
        self.effect(d) catch |err| std.log.warn("GPU effect: {t}", .{err});
    }

    /// An effect triangle, after the models; consecutive ones of the same state in one draw.
    fn effect(self: *GpuModels, d: Layer.EffectDraw) !void {
        const tex = if (d.tex) |t| try self.texture(&.{t}) else self.blank;
        const mode: u2 = switch (d.blend) {
            .alpha => 0,
            .add => 1,
            .screen => 2,
        };
        switch (mode) {
            1 => self.glow_used = true,
            2 => self.screen_used = true,
            else => {},
        }
        const first: u32 = @intCast(self.verts.items.len);
        for (d.p, d.uv) |p, uv| try self.verts.append(self.gpa, .{ .pos = p, .uv = uv, .col = d.col });
        const program: f32 = @floatFromInt(@backingInt(d.program));
        if (self.fx.items.len > 0) {
            const l = &self.fx.items[self.fx.items.len - 1];
            if (l.ibuf == null and l.first + l.count == first and l.tex == tex and l.mode == mode and l.alpha == d.alpha and l.program == program and l.k == d.k) {
                l.count += 3;
                return;
            }
        }
        try self.fx.append(self.gpa, .{ .first = first, .count = 3, .tex = tex, .mode = mode, .alpha = d.alpha, .program = program, .k = d.k });
    }

    fn partCb(ctx: *anyopaque, d: Layer.PartDraw) void {
        const self: *GpuModels = @ptrCast(@alignCast(ctx));
        self.part(d) catch |err| std.log.warn("GPU model part: {t}", .{err});
    }

    fn meshCb(ctx: *anyopaque, d: Layer.MeshDraw) ?[4]f32 {
        const self: *GpuModels = @ptrCast(@alignCast(ctx));
        self.mesh(d) catch |err| std.log.warn("GPU model: {t}", .{err});
        return if (d.box_id != 0) self.box_prev.get(d.box_id) else null;
    }

    fn shadowCb(ctx: *anyopaque, d: Layer.ShadowDraw) void {
        const self: *GpuModels = @ptrCast(@alignCast(ctx));
        self.shadow(d) catch |err| std.log.warn("GPU shadow: {t}", .{err});
    }

    /// A caster for the compute passes: its main part (all with `all_parts`) posed and
    /// cast into mask coordinates.
    fn shadow(self: *GpuModels, d: Layer.ShadowDraw) !void {
        const m = d.model;
        const parts = try self.meshOf(m);
        var main: usize = 0;
        for (m.mesh.parts, 0..) |mp, i| {
            if (mp.triangles.len > m.mesh.parts[main].triangles.len) main = i;
        }
        const fr = m.frames;
        const skinned = fr.bones > 0 and fr.frames > 0;
        const bone_base: u32 = @intCast(self.bones.items.len);
        if (skinned) try self.bones.appendSlice(self.gpa, fr.matrices[@as(usize, d.frame) * fr.bones ..][0..fr.bones]);
        const slot: u32 = @intCast(self.floors.items.len);
        try self.floors.append(self.gpa, d.pos[2]);
        const cu = camU(d.cam);
        const l = m.local;
        var su: ShadowU = .{
            .local0 = .{ l[0], l[1], l[2], 0 },
            .local1 = .{ l[3], l[4], l[5], 0 },
            .local2 = .{ l[6], l[7], l[8], 0 },
            .center_s = .{ m.mesh.center[0], m.mesh.center[1], m.mesh.center[2], d.s },
            .pos_zg = .{ d.pos[0], d.pos[1], d.pos[2], d.pos[2] },
            .light = .{ d.light[0], d.light[1], d.light[2], if (cu.persp) 1 else 0 },
            .rot = .{ @cos(d.angle), @sin(d.angle), d.ss, 0 },
            .origin = .{ d.origin[0], d.origin[1], 2 * 255 / d.w, 2 * 255 / d.h },
            .ortho = cu.ortho,
            .eye_scale = cu.eye_scale,
            .fwd = cu.fwd,
            .right = cu.right,
            .up = cu.up,
            .persp = cu.lens,
            .counts = .{ 0, 0, 0, slot },
        };
        for (parts, 0..) |*gp, pi| {
            if (!d.all_parts and pi != main) continue;
            const pb = self.n_posed;
            self.n_posed += gp.n;
            su.counts[0] = gp.n;
            su.counts[1] = pb;
            su.counts[2] = self.n_shadow;
            self.n_shadow += gp.n;
            try self.sjobs.append(self.gpa, .{ .part = gp, .pose = .{ .n = gp.n, .posed_base = pb, .bone_base = bone_base, .skinned = @intFromBool(skinned) }, .su = su });
        }
    }

    fn part(self: *GpuModels, d: Layer.PartDraw) !void {
        if (d.tris.len == 0) return;
        const base: u32 = @intCast(self.verts.items.len);
        const first: u32 = @intCast(self.indices.items.len);
        try self.verts.ensureUnusedCapacity(self.gpa, d.pos.len);
        for (d.pos, d.verts, d.col) |p, v, cl| {
            self.zmin = @min(self.zmin, p[2]);
            self.zmax = @max(self.zmax, p[2]);
            self.verts.appendAssumeCapacity(.{ .pos = p, .uv = v.uv, .col = cl });
        }
        try self.indices.appendSlice(self.gpa, @as([*]const u32, @ptrCast(d.tris.ptr))[0 .. d.tris.len * 3]);
        const tex: ?*c.SDL_GPUTexture = if (d.mips.len > 0) try self.texture(d.mips) else null;
        const a = std.math.clamp(d.alpha, 0, 1);
        try self.draws.append(self.gpa, .{ .first = first, .count = @intCast(d.tris.len * 3), .base = base, .computed = false, .ibuf = null, .tex = tex, .key = .{ .cull = !d.two_sided, .blend = a < 1, .write = d.depth_write }, .alpha = a, .bias = d.test_bias });
    }

    /// A whole model for the compute passes, its parts drawn from their own triangles.
    fn mesh(self: *GpuModels, d: Layer.MeshDraw) !void {
        const m = d.model;
        const parts = try self.meshOf(m);
        const fr = m.frames;
        const skinned = fr.bones > 0 and fr.frames > 0;
        const bone_base: u32 = @intCast(self.bones.items.len);
        if (skinned) try self.bones.appendSlice(self.gpa, fr.matrices[@as(usize, d.frame) * fr.bones ..][0..fr.bones]);
        if (!self.lamps_set) {
            self.lamps_set = true;
            for (d.light.omni) |o| try self.omni.append(self.gpa, .{ .{ o.pos[0], o.pos[1], o.pos[2], o.range }, .{ o.color[0], o.color[1], o.color[2], 0 } });
        }
        const slot: u32 = if (d.box_id != 0) blk: {
            const gop = try self.box_slots.getOrPut(self.gpa, d.box_id);
            break :blk @intCast(gop.index + 1);
        } else 0;
        const p = d.p;
        const cam = d.cam;
        const ox = cam.project(.{ 1, 0, 0 });
        const oy = cam.project(.{ 0, 1, 0 });
        const persp: ?camera.Persp = switch (cam) {
            .ortho => null,
            .persp => |pc| pc,
        };
        const l = m.local;
        var lu: LightU = .{
            .local0 = .{ l[0], l[1], l[2], 0 },
            .local1 = .{ l[3], l[4], l[5], 0 },
            .local2 = .{ l[6], l[7], l[8], 0 },
            .center_s = .{ m.mesh.center[0], m.mesh.center[1], m.mesh.center[2], d.s },
            .pos_aspect = .{ p.pos[0], p.pos[1], p.pos[2], cam.aspect() },
            .rot = .{ @cos(p.angle), @sin(p.angle), d.ss, if (persp != null) 1 else 0 },
            .origin = .{ d.origin[0], d.origin[1], 0, 0 },
            .ambient = .{ d.light.ambient[0], d.light.ambient[1], d.light.ambient[2], 0 },
            .directional = .{ d.light.directional[0], d.light.directional[1], d.light.directional[2], 0 },
            .ortho = .{ ox.x, oy.x, camera.k, 0 },
            .eye_scale = @splat(0),
            .fwd = @splat(0),
            .right = @splat(0),
            .up = @splat(0),
            .persp = @splat(0),
            .counts = .{ 0, 0, 0, @intCast(self.omni.items.len) },
            .box = .{ slot, 0, 0, 0 },
        };
        if (persp) |pc| {
            lu.eye_scale = .{ pc.eye[0], pc.eye[1], pc.eye[2], pc.scale };
            lu.fwd = .{ pc.fwd[0], pc.fwd[1], pc.fwd[2], 0 };
            lu.right = .{ pc.right[0], pc.right[1], pc.right[2], 0 };
            lu.up = .{ pc.up[0], pc.up[1], pc.up[2], 0 };
            lu.persp = .{ pc.focal, pc.focal_y, pc.cx, pc.cy };
        }
        const a = std.math.clamp(p.alpha, 0, 1);
        for (parts, 0..) |*gp, pi| {
            if (gp.ntri == 0) continue;
            const base = self.n_computed;
            self.n_computed += gp.n;
            const pb = self.n_posed;
            self.n_posed += gp.n;
            lu.counts[0] = gp.n;
            lu.counts[1] = pb;
            lu.counts[2] = base;
            try self.jobs.append(self.gpa, .{ .part = gp, .pose = .{ .n = gp.n, .posed_base = pb, .bone_base = bone_base, .skinned = @intFromBool(skinned) }, .light = lu });
            const mips: []const Image = if (d.textures) |t| t.partMips(m, pi) else &.{};
            const tex: ?*c.SDL_GPUTexture = if (mips.len > 0) try self.texture(mips) else null;
            if (!p.hidden) try self.draws.append(self.gpa, .{ .first = 0, .count = gp.ntri * 3, .base = base, .computed = true, .ibuf = gp.tris, .tex = tex, .key = .{ .cull = !m.two_sided, .blend = a < 1, .write = p.depth_write }, .alpha = a, .bias = p.depth_bias });
            // Additive passes over the part's own triangles (layer.drawParts): ice, the
            // shock's current, the materialisation glow.
            const pass: FxDraw = .{ .first = 0, .count = gp.ntri * 3, .base = base, .ibuf = gp.tris, .tex = self.blank, .mode = 1, .cull = !m.two_sided };
            for (p.overlays) |ov| if (ov) |o| {
                var f = pass;
                f.tex = try self.texture(&.{o.tex});
                f.tint = .{ 1, 1, 1, 1 };
                f.uvx = .{ o.uv_scale, o.uv_offset[0], o.uv_offset[1], if (o.wrap) 1 else 0 };
                try self.fx.append(self.gpa, f);
                self.glow_used = true;
            };
            if (p.tint) |tc| {
                var f = pass;
                f.tint = .{ tc[0], tc[1], tc[2], 1 };
                try self.fx.append(self.gpa, f);
                self.glow_used = true;
            }
        }
    }

    fn dispatchPose(self: *GpuModels, cmd: *c.SDL_GPUCommandBuffer, pass: ?*c.SDL_GPUComputePass, gp: *const GPart, pose: PoseU) void {
        const ro = [3]*c.SDL_GPUBuffer{ gp.verts, gp.infl, self.bbuf.? };
        c.SDL_BindGPUComputeStorageBuffers(pass, 0, @ptrCast(&ro), 3);
        c.SDL_PushGPUComputeUniformData(cmd, 0, &pose, @sizeOf(PoseU));
        c.SDL_DispatchGPUCompute(pass, (pose.n + local_size - 1) / local_size, 1, 1);
    }

    /// The GPU copy of `m`'s mesh (bind pose, weights, triangles, weld groups).
    fn meshOf(self: *GpuModels, m: *const Model) ![]GPart {
        const key = @intFromPtr(m.mesh.parts.ptr);
        if (self.meshes.get(key)) |g| return g;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const out = try self.gpa.alloc(GPart, m.mesh.parts.len);
        errdefer self.gpa.free(out);
        for (m.mesh.parts, out, 0..) |mp, *gp, pi| {
            const n = mp.vertices.len;
            const sv = try a.alloc(SVert, n);
            for (mp.vertices, mp.ranges, sv) |v, rg, *o| {
                // As skin.pose: the weight the bones leave, subtracted in its order.
                var rest: f32 = 1;
                for (mp.influences[rg[0]..rg[1]]) |inf| rest -= inf.weight;
                o.* = .{ .pos = .{ v.pos[0], v.pos[1], v.pos[2], rest }, .start = rg[0], .count = rg[1] - rg[0], .uv = v.uv };
            }
            const infl = try a.alloc([2]u32, @max(1, mp.influences.len));
            for (mp.influences, 0..) |inf, i| infl[i] = .{ inf.bone, @bitCast(inf.weight) };
            // Each vertex's weld group: the corners of triangles whose vertex welds to the same one.
            const weld = if (pi < m.weld.len) m.weld[pi] else &.{};
            const counts = try a.alloc(u32, n + 1);
            @memset(counts, 0);
            for (mp.triangles) |t| for (t) |vi| {
                counts[if (vi < weld.len) weld[vi] else vi] += 1;
            };
            const starts = try a.alloc(u32, n + 1);
            var sum: u32 = 0;
            for (counts, starts) |cn, *st| {
                st.* = sum;
                sum += cn;
            }
            const corners = try a.alloc(u32, @max(1, sum));
            const fill = try a.dupe(u32, starts);
            for (mp.triangles, 0..) |t, ti| for (t) |vi| {
                const k = if (vi < weld.len) weld[vi] else vi;
                corners[fill[k]] = @intCast(ti);
                fill[k] += 1;
            };
            const grp = try a.alloc([2]u32, n);
            for (grp, 0..) |*g, i| {
                const k = if (i < weld.len) weld[i] else i;
                g.* = .{ starts[k], counts[k] };
            }
            const tris = if (mp.triangles.len > 0) std.mem.sliceAsBytes(mp.triangles) else std.mem.asBytes(&[3]u32{ 0, 0, 0 });
            const rd = c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ;
            gp.* = .{
                .verts = try self.staticBuffer(std.mem.sliceAsBytes(sv), rd),
                .infl = try self.staticBuffer(std.mem.sliceAsBytes(infl), rd),
                .tris = try self.staticBuffer(tris, rd | c.SDL_GPU_BUFFERUSAGE_INDEX),
                .grp = try self.staticBuffer(std.mem.sliceAsBytes(grp), rd),
                .corners = try self.staticBuffer(std.mem.sliceAsBytes(corners), rd),
                .n = @intCast(n),
                .ntri = @intCast(mp.triangles.len),
            };
        }
        try self.meshes.put(self.gpa, key, out);
        return out;
    }

    fn staticBuffer(self: *GpuModels, data: []const u8, usage: c.SDL_GPUBufferUsageFlags) !*c.SDL_GPUBuffer {
        const dev = self.device;
        const size: u32 = @intCast(@max(16, data.len));
        const b = c.SDL_CreateGPUBuffer(dev, &.{ .usage = usage, .size = size }) orelse return error.GpuBuffer;
        errdefer c.SDL_ReleaseGPUBuffer(dev, b);
        const xb = c.SDL_CreateGPUTransferBuffer(dev, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = size }) orelse return error.GpuBuffer;
        defer c.SDL_ReleaseGPUTransferBuffer(dev, xb);
        const dst: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(dev, xb, false) orelse return error.GpuBuffer);
        @memcpy(dst[0..data.len], data);
        c.SDL_UnmapGPUTransferBuffer(dev, xb);
        const cmd = c.SDL_AcquireGPUCommandBuffer(dev) orelse return error.GpuCommand;
        const cp = c.SDL_BeginGPUCopyPass(cmd);
        c.SDL_UploadToGPUBuffer(cp, &.{ .transfer_buffer = xb, .offset = 0 }, &.{ .buffer = b, .offset = 0, .size = @intCast(data.len) }, false);
        c.SDL_EndGPUCopyPass(cp);
        if (!c.SDL_SubmitGPUCommandBuffer(cmd)) return error.GpuCommand;
        return b;
    }

    /// The GPU copy of texture `mips` (levels halving: one texture with them all).
    fn texture(self: *GpuModels, mips: []const Image) !*c.SDL_GPUTexture {
        const key = @intFromPtr(mips[0].pixels.ptr);
        if (self.textures.get(key)) |t| return t;
        var n: usize = 1;
        while (n < mips.len and mips[n].width == @max(1, mips[n - 1].width / 2) and mips[n].height == @max(1, mips[n - 1].height / 2)) n += 1;
        const t = try self.upload(mips[0..n]);
        try self.textures.put(self.gpa, key, t);
        return t;
    }

    /// A sampled RGBA texture with `levels` as its mip levels.
    fn upload(self: *GpuModels, levels: []const Image) !*c.SDL_GPUTexture {
        const dev = self.device;
        const t = c.SDL_CreateGPUTexture(dev, &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = levels[0].width,
            .height = levels[0].height,
            .layer_count_or_depth = 1,
            .num_levels = @intCast(levels.len),
        }) orelse return error.GpuTexture;
        errdefer c.SDL_ReleaseGPUTexture(dev, t);
        var total: usize = 0;
        for (levels) |l| total += l.pixels.len;
        const xb = c.SDL_CreateGPUTransferBuffer(dev, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = @intCast(total) }) orelse return error.GpuBuffer;
        defer c.SDL_ReleaseGPUTransferBuffer(dev, xb);
        const dst: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(dev, xb, false) orelse return error.GpuBuffer);
        var off: usize = 0;
        for (levels) |l| {
            @memcpy(dst[off..][0..l.pixels.len], l.pixels);
            off += l.pixels.len;
        }
        c.SDL_UnmapGPUTransferBuffer(dev, xb);
        const cmd = c.SDL_AcquireGPUCommandBuffer(dev) orelse return error.GpuCommand;
        const cp = c.SDL_BeginGPUCopyPass(cmd);
        off = 0;
        for (levels, 0..) |l, i| {
            c.SDL_UploadToGPUTexture(cp, &.{ .transfer_buffer = xb, .offset = @intCast(off) }, &.{ .texture = t, .mip_level = @intCast(i), .w = l.width, .h = l.height, .d = 1 }, false);
            off += l.pixels.len;
        }
        c.SDL_EndGPUCopyPass(cp);
        if (!c.SDL_SubmitGPUCommandBuffer(cmd)) return error.GpuCommand;
        return t;
    }

    /// Draws the frame's models over background depth `bg` (`bw`×`bh`, the canvas's
    /// units), then their shadows (`shade`: intensity, depth bias; null: none) seen by
    /// `cam` from `origin`; false when there were none (the texture is then not to be shown).
    pub fn finish(self: *GpuModels, bg: []const f32, bw: u32, bh: u32, cam: camera.Camera, origin: [2]f32, shade: ?[2]f32) !bool {
        if (self.draws.items.len == 0 and self.fx.items.len == 0) return false;
        const dev = self.device;
        if (self.bg == null or self.bw != bw or self.bh != bh) {
            if (self.bg) |t| c.SDL_ReleaseGPUTexture(dev, t);
            self.bg = c.SDL_CreateGPUTexture(dev, &.{
                .type = c.SDL_GPU_TEXTURETYPE_2D,
                .format = c.SDL_GPU_TEXTUREFORMAT_R32_FLOAT,
                .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
                .width = bw,
                .height = bh,
                .layer_count_or_depth = 1,
                .num_levels = 1,
            }) orelse return error.GpuTexture;
            self.bw = bw;
            self.bh = bh;
            self.bg_last.clearRetainingCapacity();
        }
        const bg_now = bg[0 .. bw * bh];
        // By bytes: a NaN (no depth) equals itself.
        const bg_new = !std.mem.eql(u8, std.mem.sliceAsBytes(self.bg_last.items), std.mem.sliceAsBytes(bg_now));
        if (bg_new) {
            self.bg_last.clearRetainingCapacity();
            try self.bg_last.appendSlice(self.gpa, bg_now);
        }
        const ncomp = self.n_computed;
        const nbox: u32 = @intCast(self.box_slots.count());
        const comp_bytes = ncomp * @sizeOf(Vertex);
        const cpu_bytes: u32 = @intCast(self.verts.items.len * @sizeOf(Vertex));
        const ibytes: u32 = @intCast(self.indices.items.len * 4);
        const bonebytes: u32 = @intCast(self.bones.items.len * 48);
        const omnibytes: u32 = @intCast(self.omni.items.len * 32);
        const boxbytes = nbox * 16;
        const ncast: u32 = @intCast(self.floors.items.len);
        const floorbytes = ncast * 4;
        const sboxbytes = ncast * 16;
        const bgbytes: u32 = if (bg_new) bw * bh * 4 else 0;
        const st = c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_READ;
        try grow(dev, &self.vbuf, &self.vcap, comp_bytes + cpu_bytes, c.SDL_GPU_BUFFERUSAGE_VERTEX | c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE);
        try grow(dev, &self.ibuf, &self.icap, ibytes, c.SDL_GPU_BUFFERUSAGE_INDEX);
        try grow(dev, &self.posed, &self.pcap, self.n_posed * 16, st | c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE);
        try grow(dev, &self.svbuf, &self.svcap, self.n_shadow * 8, c.SDL_GPU_BUFFERUSAGE_VERTEX | c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE);
        try grow(dev, &self.sboxes, &self.sbcap, sboxbytes, st | c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE);
        try grow(dev, &self.fbuf, &self.fcap, floorbytes, st);
        try grow(dev, &self.bbuf, &self.bcap, bonebytes, st);
        try grow(dev, &self.obuf, &self.ocap, omnibytes, st);
        try grow(dev, &self.boxes, &self.boxcap, boxbytes, st | c.SDL_GPU_BUFFERUSAGE_COMPUTE_STORAGE_WRITE);
        // Upload: CPU vertices, indices, bones, lamps, box and depth range starts, background depth.
        const off_i = cpu_bytes;
        const off_b = off_i + ibytes;
        const off_o = off_b + bonebytes;
        const off_x = off_o + omnibytes;
        const off_z = off_x + boxbytes;
        const off_f = off_z + 8;
        const off_sb = off_f + floorbytes;
        const off_bg = off_sb + sboxbytes;
        const xneed = off_bg + bgbytes;
        if (self.xcap < xneed) {
            if (self.xfer) |b| c.SDL_ReleaseGPUTransferBuffer(dev, b);
            self.xcap = xneed + xneed / 2;
            self.xfer = c.SDL_CreateGPUTransferBuffer(dev, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD, .size = self.xcap }) orelse return error.GpuBuffer;
        }
        // Cycled: the previous frame's copy may still be in flight.
        const dst: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(dev, self.xfer, true) orelse return error.GpuBuffer);
        @memcpy(dst[0..cpu_bytes], std.mem.sliceAsBytes(self.verts.items));
        @memcpy(dst[off_i..][0..ibytes], std.mem.sliceAsBytes(self.indices.items));
        @memcpy(dst[off_b..][0..bonebytes], std.mem.sliceAsBytes(self.bones.items));
        @memcpy(dst[off_o..][0..omnibytes], std.mem.sliceAsBytes(self.omni.items));
        const box_init: [*]u32 = @ptrCast(@alignCast(dst + off_x));
        for (0..nbox) |i| box_init[i * 4 ..][0..4].* = .{ 0xFFFF_FFFF, 0xFFFF_FFFF, 0, 0 };
        const zr: *[2]u32 = @ptrCast(@alignCast(dst + off_z));
        zr.* = if (self.verts.items.len > 0) .{ ordered(self.zmin), ordered(self.zmax) } else .{ 0xFFFF_FFFF, 0 };
        @memcpy(dst[off_f..][0..floorbytes], std.mem.sliceAsBytes(self.floors.items));
        const sbox_init: [*]u32 = @ptrCast(@alignCast(dst + off_sb));
        for (0..ncast) |i| sbox_init[i * 4 ..][0..4].* = .{ 0xFFFF_FFFF, 0xFFFF_FFFF, 0, 0 };
        if (bg_new) @memcpy(dst[off_bg..][0..bgbytes], std.mem.sliceAsBytes(bg_now));
        c.SDL_UnmapGPUTransferBuffer(dev, self.xfer);

        const cmd = c.SDL_AcquireGPUCommandBuffer(dev) orelse return error.GpuCommand;
        const cp = c.SDL_BeginGPUCopyPass(cmd);
        const x = self.xfer;
        // The vertex buffer cycles on its first write this frame (here, else the compute pass's).
        if (cpu_bytes > 0) c.SDL_UploadToGPUBuffer(cp, &.{ .transfer_buffer = x, .offset = 0 }, &.{ .buffer = self.vbuf, .offset = comp_bytes, .size = cpu_bytes }, true);
        if (ibytes > 0) c.SDL_UploadToGPUBuffer(cp, &.{ .transfer_buffer = x, .offset = off_i }, &.{ .buffer = self.ibuf, .offset = 0, .size = ibytes }, true);
        if (bonebytes > 0) c.SDL_UploadToGPUBuffer(cp, &.{ .transfer_buffer = x, .offset = off_b }, &.{ .buffer = self.bbuf, .offset = 0, .size = bonebytes }, true);
        if (omnibytes > 0) c.SDL_UploadToGPUBuffer(cp, &.{ .transfer_buffer = x, .offset = off_o }, &.{ .buffer = self.obuf, .offset = 0, .size = omnibytes }, true);
        if (boxbytes > 0) c.SDL_UploadToGPUBuffer(cp, &.{ .transfer_buffer = x, .offset = off_x }, &.{ .buffer = self.boxes, .offset = 0, .size = boxbytes }, true);
        c.SDL_UploadToGPUBuffer(cp, &.{ .transfer_buffer = x, .offset = off_z }, &.{ .buffer = self.zrange, .offset = 0, .size = 8 }, true);
        if (ncast > 0) {
            c.SDL_UploadToGPUBuffer(cp, &.{ .transfer_buffer = x, .offset = off_f }, &.{ .buffer = self.fbuf, .offset = 0, .size = floorbytes }, true);
            c.SDL_UploadToGPUBuffer(cp, &.{ .transfer_buffer = x, .offset = off_sb }, &.{ .buffer = self.sboxes, .offset = 0, .size = sboxbytes }, true);
        }
        if (bg_new) c.SDL_UploadToGPUTexture(cp, &.{ .transfer_buffer = x, .offset = off_bg }, &.{ .texture = self.bg, .w = bw, .h = bh, .d = 1 }, true);
        c.SDL_EndGPUCopyPass(cp);

        if (self.n_posed > 0) {
            // Pose every computed part and caster, then light and project them, cast the
            // shadows, mark the tiles (each pass reads the one before: separate passes
            // keep them in order).
            const rw1 = [1]c.SDL_GPUStorageBufferReadWriteBinding{.{ .buffer = self.posed, .cycle = true }};
            const p1 = c.SDL_BeginGPUComputePass(cmd, null, 0, &rw1, 1);
            c.SDL_BindGPUComputePipeline(p1, self.pose_pipe);
            for (self.jobs.items) |j| self.dispatchPose(cmd, p1, j.part, j.pose);
            for (self.sjobs.items) |j| self.dispatchPose(cmd, p1, j.part, j.pose);
            c.SDL_EndGPUComputePass(p1);
        }
        if (self.jobs.items.len > 0) {
            const rw2 = [3]c.SDL_GPUStorageBufferReadWriteBinding{ .{ .buffer = self.vbuf, .cycle = cpu_bytes == 0 }, .{ .buffer = self.boxes, .cycle = false }, .{ .buffer = self.zrange, .cycle = false } };
            const p2 = c.SDL_BeginGPUComputePass(cmd, null, 0, &rw2, 3);
            c.SDL_BindGPUComputePipeline(p2, self.light_pipe);
            for (self.jobs.items) |j| {
                const ro = [6]*c.SDL_GPUBuffer{ j.part.verts, j.part.tris, j.part.grp, j.part.corners, self.posed.?, self.obuf.? };
                c.SDL_BindGPUComputeStorageBuffers(p2, 0, @ptrCast(&ro), 6);
                c.SDL_PushGPUComputeUniformData(cmd, 0, &j.light, @sizeOf(LightU));
                c.SDL_DispatchGPUCompute(p2, (j.light.counts[0] + local_size - 1) / local_size, 1, 1);
            }
            c.SDL_EndGPUComputePass(p2);
        }
        const shadows = shade != null and self.sjobs.items.len > 0;
        if (shadows) {
            const rw3 = [2]c.SDL_GPUStorageBufferReadWriteBinding{ .{ .buffer = self.svbuf, .cycle = true }, .{ .buffer = self.sboxes, .cycle = false } };
            const p3 = c.SDL_BeginGPUComputePass(cmd, null, 0, &rw3, 2);
            c.SDL_BindGPUComputePipeline(p3, self.shadow_pipe);
            for (self.sjobs.items) |j| {
                const ro = [1]*c.SDL_GPUBuffer{self.posed.?};
                c.SDL_BindGPUComputeStorageBuffers(p3, 0, @ptrCast(&ro), 1);
                c.SDL_PushGPUComputeUniformData(cmd, 0, &j.su, @sizeOf(ShadowU));
                c.SDL_DispatchGPUCompute(p3, (j.su.counts[0] + local_size - 1) / local_size, 1, 1);
            }
            c.SDL_EndGPUComputePass(p3);
            const rw4 = [1]c.SDL_GPUStorageBufferReadWriteBinding{.{ .buffer = self.tiles, .cycle = true }};
            const p4 = c.SDL_BeginGPUComputePass(cmd, null, 0, &rw4, 1);
            c.SDL_BindGPUComputePipeline(p4, self.tiles_pipe);
            const ro4 = [2]*c.SDL_GPUBuffer{ self.sboxes.?, self.fbuf.? };
            c.SDL_BindGPUComputeStorageBuffers(p4, 0, @ptrCast(&ro4), 2);
            const tu: TilesU = .{ .n = ncast, .w = @floatFromInt(self.w), .h = @floatFromInt(self.h) };
            c.SDL_PushGPUComputeUniformData(cmd, 0, &tu, @sizeOf(TilesU));
            c.SDL_DispatchGPUCompute(p4, 1, 1, 1);
            c.SDL_EndGPUComputePass(p4);
            // The mask: every caster's triangles, ones.
            const mt: c.SDL_GPUColorTargetInfo = .{ .texture = self.mask, .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 }, .load_op = c.SDL_GPU_LOADOP_CLEAR, .store_op = c.SDL_GPU_STOREOP_STORE };
            const mp = c.SDL_BeginGPURenderPass(cmd, &mt, 1, null);
            c.SDL_BindGPUGraphicsPipeline(mp, self.mask_pipe);
            c.SDL_BindGPUVertexBuffers(mp, 0, &.{ .buffer = self.svbuf, .offset = 0 }, 1);
            for (self.sjobs.items) |j| {
                c.SDL_BindGPUIndexBuffer(mp, &.{ .buffer = j.part.tris, .offset = 0 }, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);
                c.SDL_DrawGPUIndexedPrimitives(mp, j.part.ntri * 3, 1, 0, @intCast(j.su.counts[2]), 0);
            }
            c.SDL_EndGPURenderPass(mp);
        }

        const ct: c.SDL_GPUColorTargetInfo = .{ .texture = self.color, .clear_color = .{ .r = self.clear[0], .g = self.clear[1], .b = self.clear[2], .a = self.clear[3] }, .load_op = c.SDL_GPU_LOADOP_CLEAR, .store_op = c.SDL_GPU_STOREOP_STORE };
        const dt: c.SDL_GPUDepthStencilTargetInfo = .{ .texture = self.depth, .clear_depth = 1, .load_op = c.SDL_GPU_LOADOP_CLEAR, .store_op = c.SDL_GPU_STOREOP_DONT_CARE, .stencil_load_op = c.SDL_GPU_LOADOP_DONT_CARE, .stencil_store_op = c.SDL_GPU_STOREOP_DONT_CARE };
        const cts = [2]c.SDL_GPUColorTargetInfo{ ct, .{ .texture = self.zcol, .clear_color = .{ .r = 3e38, .g = 0, .b = 0, .a = 0 }, .load_op = c.SDL_GPU_LOADOP_CLEAR, .store_op = c.SDL_GPU_STOREOP_STORE } };
        const rp = c.SDL_BeginGPURenderPass(cmd, &cts, 2, &dt);
        const fu: FrameU = .{ .size = .{ @floatFromInt(self.w), @floatFromInt(self.h) } };
        c.SDL_PushGPUVertexUniformData(cmd, 0, &fu, @sizeOf(FrameU));
        const zb = [1]*c.SDL_GPUBuffer{self.zrange};
        c.SDL_BindGPUVertexStorageBuffers(rp, 0, @ptrCast(&zb), 1);
        c.SDL_BindGPUVertexBuffers(rp, 0, &.{ .buffer = self.vbuf, .offset = 0 }, 1);
        var cur: ?Key = null;
        var cur_ib: ?*c.SDL_GPUBuffer = null;
        for (self.draws.items) |d| {
            if (cur == null or @as(u3, @bitCast(cur.?)) != @as(u3, @bitCast(d.key))) {
                c.SDL_BindGPUGraphicsPipeline(rp, self.pipes[@as(u3, @bitCast(d.key))]);
                cur = d.key;
            }
            const ib = d.ibuf orelse self.ibuf.?;
            if (cur_ib != ib) {
                c.SDL_BindGPUIndexBuffer(rp, &.{ .buffer = ib, .offset = 0 }, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);
                cur_ib = ib;
            }
            const binds = [2]c.SDL_GPUTextureSamplerBinding{ .{ .texture = d.tex orelse self.blank, .sampler = self.smp_tex }, .{ .texture = self.bg, .sampler = self.smp_bg } };
            c.SDL_BindGPUFragmentSamplers(rp, 0, &binds, 2);
            const du: DrawU = .{ .alpha = d.alpha, .bias = d.bias, .textured = if (d.tex != null) 1 else 0, .ss = @floatFromInt(self.ss) };
            c.SDL_PushGPUFragmentUniformData(cmd, 0, &du, @sizeOf(DrawU));
            const base = if (d.computed) d.base else ncomp + d.base;
            c.SDL_DrawGPUIndexedPrimitives(rp, d.count, 1, d.first, @intCast(base), 0);
        }
        c.SDL_EndGPURenderPass(rp);

        // Shadows over the models and the empty layer (layer.compositeShadow).
        if (shadows) {
            const sh = shade.?;
            const cu = camU(cam);
            const ss: f32 = @floatFromInt(self.ss);
            const cuu: CompU = .{ .screen = .{ @floatFromInt(self.w / self.ss), @floatFromInt(self.h / self.ss), ss, if (cu.persp) 1 else 0 }, .origin = .{ origin[0], origin[1], sh[0], sh[1] }, .ortho = .{ camera.k, 0, 0, 0 }, .eye_scale = cu.eye_scale, .fwd = cu.fwd, .right = cu.right, .up = cu.up, .persp = cu.lens };
            const lt: c.SDL_GPUColorTargetInfo = .{ .texture = self.color, .load_op = c.SDL_GPU_LOADOP_LOAD, .store_op = c.SDL_GPU_STOREOP_STORE };
            const sp = c.SDL_BeginGPURenderPass(cmd, &lt, 1, null);
            c.SDL_BindGPUGraphicsPipeline(sp, self.comp_pipe);
            const sb = [3]c.SDL_GPUTextureSamplerBinding{ .{ .texture = self.mask, .sampler = self.smp_bg }, .{ .texture = self.bg, .sampler = self.smp_bg }, .{ .texture = self.zcol, .sampler = self.smp_bg } };
            c.SDL_BindGPUFragmentSamplers(sp, 0, &sb, 3);
            const tb = [1]*c.SDL_GPUBuffer{self.tiles};
            c.SDL_BindGPUFragmentStorageBuffers(sp, 0, @ptrCast(&tb), 1);
            c.SDL_PushGPUFragmentUniformData(cmd, 0, &cuu, @sizeOf(CompU));
            c.SDL_DrawGPUPrimitives(sp, 3, 1, 0, 0);
            c.SDL_EndGPURenderPass(sp);
        }

        // Effects over the models and shadows, in the order drawn.
        if (self.fx.items.len > 0) {
            const clear = c.SDL_GPUColorTargetInfo{ .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 }, .load_op = c.SDL_GPU_LOADOP_CLEAR, .store_op = c.SDL_GPU_STOREOP_STORE };
            var ets = [3]c.SDL_GPUColorTargetInfo{ .{ .texture = self.color, .load_op = c.SDL_GPU_LOADOP_LOAD, .store_op = c.SDL_GPU_STOREOP_STORE }, clear, clear };
            ets[1].texture = self.glow;
            ets[2].texture = self.screen;
            const ep = c.SDL_BeginGPURenderPass(cmd, &ets, 3, null);
            c.SDL_PushGPUVertexUniformData(cmd, 0, &fu, @sizeOf(FrameU));
            c.SDL_BindGPUVertexBuffers(ep, 0, &.{ .buffer = self.vbuf, .offset = 0 }, 1);
            var cur_mode: ?u2 = null;
            var fx_ib: ?*c.SDL_GPUBuffer = null;
            for (self.fx.items) |d| {
                if (cur_mode != d.mode) {
                    c.SDL_BindGPUGraphicsPipeline(ep, self.fx_pipes[d.mode]);
                    cur_mode = d.mode;
                }
                const binds = [3]c.SDL_GPUTextureSamplerBinding{ .{ .texture = d.tex, .sampler = self.smp_tex }, .{ .texture = self.bg, .sampler = self.smp_bg }, .{ .texture = self.zcol, .sampler = self.smp_bg } };
                c.SDL_BindGPUFragmentSamplers(ep, 0, &binds, 3);
                const eu: FxU = .{ .mode_alpha = .{ @floatFromInt(d.mode), d.alpha, d.program, d.k }, .scale = .{ @floatFromInt(self.ss), if (d.cull) 1 else 0, 0, 0 }, .tint = d.tint, .uvx = d.uvx };
                c.SDL_PushGPUFragmentUniformData(cmd, 0, &eu, @sizeOf(FxU));
                if (d.ibuf) |ib| {
                    if (fx_ib != ib) {
                        c.SDL_BindGPUIndexBuffer(ep, &.{ .buffer = ib, .offset = 0 }, c.SDL_GPU_INDEXELEMENTSIZE_32BIT);
                        fx_ib = ib;
                    }
                    c.SDL_DrawGPUIndexedPrimitives(ep, d.count, 1, d.first, @intCast(d.base), 0);
                } else c.SDL_DrawGPUPrimitives(ep, d.count, 1, ncomp + d.first, 0);
            }
            c.SDL_EndGPURenderPass(ep);
        }

        // The boxes back to the CPU (read at the next frame's begin).
        self.box_ids.clearRetainingCapacity();
        if (nbox > 0) {
            try self.box_ids.appendSlice(self.gpa, self.box_slots.keys());
            if (self.dlcap < boxbytes) {
                if (self.dl) |b| c.SDL_ReleaseGPUTransferBuffer(dev, b);
                self.dlcap = boxbytes * 2;
                self.dl = c.SDL_CreateGPUTransferBuffer(dev, &.{ .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD, .size = self.dlcap }) orelse return error.GpuBuffer;
            }
            const dp = c.SDL_BeginGPUCopyPass(cmd);
            c.SDL_DownloadFromGPUBuffer(dp, &.{ .buffer = self.boxes, .offset = 0, .size = boxbytes }, &.{ .transfer_buffer = self.dl, .offset = 0 });
            c.SDL_EndGPUCopyPass(dp);
            self.box_fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmd) orelse return error.GpuCommand;
        } else if (!c.SDL_SubmitGPUCommandBuffer(cmd)) return error.GpuCommand;
        return true;
    }
};

/// Floats ordered as unsigned ints (light.comp's atomic min/max) and back.
fn ordered(f: f32) u32 {
    const u: u32 = @bitCast(f);
    return if (u & 0x8000_0000 != 0) ~u else u | 0x8000_0000;
}
fn unordered(u: u32) f32 {
    return @bitCast(if (u & 0x8000_0000 != 0) u & 0x7FFF_FFFF else ~u);
}

test ordered {
    for ([_]f32{ -1e9, -3.5, -0.0, 0.0, 1e-30, 2.25, 7e8 }) |a| for ([_]f32{ -1e9, -3.5, -0.0, 0.0, 1e-30, 2.25, 7e8 }) |b| {
        if (a < b) try std.testing.expect(ordered(a) < ordered(b));
    };
    try std.testing.expectEqual(@as(f32, -3.5), unordered(ordered(-3.5)));
    try std.testing.expectEqual(@as(f32, 2.25), unordered(ordered(2.25)));
}

fn grow(dev: *c.SDL_GPUDevice, buf: *?*c.SDL_GPUBuffer, cap: *u32, need: u32, usage: c.SDL_GPUBufferUsageFlags) !void {
    if (cap.* >= need and buf.* != null) return;
    if (buf.*) |b| c.SDL_ReleaseGPUBuffer(dev, b);
    cap.* = @max(need + need / 2, 1 << 16);
    buf.* = c.SDL_CreateGPUBuffer(dev, &.{ .usage = usage, .size = cap.* }) orelse return error.GpuBuffer;
}

fn shader(dev: *c.SDL_GPUDevice, code: []const u8, msl: bool, stage: c.SDL_GPUShaderStage, samplers: u32, storage: u32, uniforms: u32) !*c.SDL_GPUShader {
    return c.SDL_CreateGPUShader(dev, &.{
        .code_size = code.len,
        .code = code.ptr,
        .entrypoint = if (msl) "main0" else "main",
        .format = if (msl) c.SDL_GPU_SHADERFORMAT_MSL else c.SDL_GPU_SHADERFORMAT_SPIRV,
        .stage = stage,
        .num_samplers = samplers,
        .num_storage_buffers = storage,
        .num_uniform_buffers = uniforms,
    }) orelse error.GpuShader;
}

fn compute(dev: *c.SDL_GPUDevice, code: []const u8, msl: bool, ro: u32, rw: u32) !*c.SDL_GPUComputePipeline {
    return c.SDL_CreateGPUComputePipeline(dev, &.{
        .code_size = code.len,
        .code = code.ptr,
        .entrypoint = if (msl) "main0" else "main",
        .format = if (msl) c.SDL_GPU_SHADERFORMAT_MSL else c.SDL_GPU_SHADERFORMAT_SPIRV,
        .num_readonly_storage_buffers = ro,
        .num_readwrite_storage_buffers = rw,
        .num_uniform_buffers = 1,
        .threadcount_x = local_size,
        .threadcount_y = 1,
        .threadcount_z = 1,
    }) orelse error.GpuPipeline;
}

fn pipeline(dev: *c.SDL_GPUDevice, vs: *c.SDL_GPUShader, fs: *c.SDL_GPUShader, key: Key) !*c.SDL_GPUGraphicsPipeline {
    const attrs = [3]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(Vertex, "pos") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "uv") },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(Vertex, "col") },
    };
    const vb = c.SDL_GPUVertexBufferDescription{ .slot = 0, .pitch = @sizeOf(Vertex), .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX };
    // Premultiplied "over" (the shader multiplies by alpha); opaque parts write as is.
    const ctd = c.SDL_GPUColorTargetDescription{
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .blend_state = .{
            .enable_blend = key.blend,
            .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
        },
    };
    // The canvas depth, where the part writes depth.
    const zd = c.SDL_GPUColorTargetDescription{ .format = c.SDL_GPU_TEXTUREFORMAT_R32_FLOAT, .blend_state = .{ .enable_color_write_mask = true, .color_write_mask = if (key.write) c.SDL_GPU_COLORCOMPONENT_R else 0 } };
    const targets = [2]c.SDL_GPUColorTargetDescription{ ctd, zd };
    return c.SDL_CreateGPUGraphicsPipeline(dev, &.{
        .vertex_shader = vs,
        .fragment_shader = fs,
        .vertex_input_state = .{ .vertex_buffer_descriptions = &vb, .num_vertex_buffers = 1, .vertex_attributes = &attrs, .num_vertex_attributes = attrs.len },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        // Back faces as layer.backFacing: clockwise on screen (y down) is clockwise in NDC.
        .rasterizer_state = .{ .fill_mode = c.SDL_GPU_FILLMODE_FILL, .cull_mode = if (key.cull) c.SDL_GPU_CULLMODE_BACK else c.SDL_GPU_CULLMODE_NONE, .front_face = c.SDL_GPU_FRONTFACE_COUNTER_CLOCKWISE },
        .depth_stencil_state = .{ .compare_op = c.SDL_GPU_COMPAREOP_LESS, .enable_depth_test = true, .enable_depth_write = key.write },
        .target_info = .{ .color_target_descriptions = &targets, .num_color_targets = 2, .depth_stencil_format = c.SDL_GPU_TEXTUREFORMAT_D32_FLOAT, .has_depth_stencil_target = true },
    }) orelse error.GpuPipeline;
}

/// Effects of `mode` (0 alpha, 1 add, 2 screen) into the color, glow and screen targets
/// (effect.frag): the mode's target blended as the CPU canvas does, the others untouched —
/// except an alpha effect also scales the glow under it.
fn effectPipeline(dev: *c.SDL_GPUDevice, vs: *c.SDL_GPUShader, fs: *c.SDL_GPUShader, mode: u2) !*c.SDL_GPUGraphicsPipeline {
    const attrs = [3]c.SDL_GPUVertexAttribute{
        .{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(Vertex, "pos") },
        .{ .location = 1, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = @offsetOf(Vertex, "uv") },
        .{ .location = 2, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3, .offset = @offsetOf(Vertex, "col") },
    };
    const vb = c.SDL_GPUVertexBufferDescription{ .slot = 0, .pitch = @sizeOf(Vertex), .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX };
    const rgba = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
    const off = c.SDL_GPUColorTargetDescription{ .format = rgba, .blend_state = .{ .enable_color_write_mask = true, .color_write_mask = 0 } };
    const one = c.SDL_GPU_BLENDFACTOR_ONE;
    const add = c.SDL_GPU_BLENDOP_ADD;
    const over = c.SDL_GPUColorTargetDescription{ .format = rgba, .blend_state = .{ .enable_blend = true, .src_color_blendfactor = one, .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, .color_blend_op = add, .src_alpha_blendfactor = one, .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, .alpha_blend_op = add } };
    // Glow under an alpha effect: rgb·(1 − alpha), its alpha kept.
    const fade = c.SDL_GPUColorTargetDescription{ .format = rgba, .blend_state = .{ .enable_blend = true, .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO, .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, .color_blend_op = add, .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ZERO, .dst_alpha_blendfactor = one, .alpha_blend_op = add } };
    const sum = c.SDL_GPUColorTargetDescription{ .format = rgba, .blend_state = .{ .enable_blend = true, .src_color_blendfactor = one, .dst_color_blendfactor = one, .color_blend_op = add, .src_alpha_blendfactor = one, .dst_alpha_blendfactor = one, .alpha_blend_op = add } };
    const scr = c.SDL_GPUColorTargetDescription{ .format = rgba, .blend_state = .{ .enable_blend = true, .src_color_blendfactor = one, .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_COLOR, .color_blend_op = add, .src_alpha_blendfactor = one, .dst_alpha_blendfactor = one, .alpha_blend_op = add } };
    const targets: [3]c.SDL_GPUColorTargetDescription = switch (mode) {
        0 => .{ over, fade, off },
        1 => .{ off, sum, off },
        else => .{ off, off, scr },
    };
    return c.SDL_CreateGPUGraphicsPipeline(dev, &.{
        .vertex_shader = vs,
        .fragment_shader = fs,
        .vertex_input_state = .{ .vertex_buffer_descriptions = &vb, .num_vertex_buffers = 1, .vertex_attributes = &attrs, .num_vertex_attributes = attrs.len },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{ .fill_mode = c.SDL_GPU_FILLMODE_FILL, .cull_mode = c.SDL_GPU_CULLMODE_NONE },
        .target_info = .{ .color_target_descriptions = &targets, .num_color_targets = 3 },
    }) orelse error.GpuPipeline;
}

/// Shadow triangles into the mask: ones, no depth, no culling (layer.shadowTri).
fn maskPipeline(dev: *c.SDL_GPUDevice, vs: *c.SDL_GPUShader, fs: *c.SDL_GPUShader) !*c.SDL_GPUGraphicsPipeline {
    const attr = c.SDL_GPUVertexAttribute{ .location = 0, .buffer_slot = 0, .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2, .offset = 0 };
    const vb = c.SDL_GPUVertexBufferDescription{ .slot = 0, .pitch = 8, .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX };
    const ctd = c.SDL_GPUColorTargetDescription{ .format = c.SDL_GPU_TEXTUREFORMAT_R8_UNORM };
    return c.SDL_CreateGPUGraphicsPipeline(dev, &.{
        .vertex_shader = vs,
        .fragment_shader = fs,
        .vertex_input_state = .{ .vertex_buffer_descriptions = &vb, .num_vertex_buffers = 1, .vertex_attributes = &attr, .num_vertex_attributes = 1 },
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{ .fill_mode = c.SDL_GPU_FILLMODE_FILL, .cull_mode = c.SDL_GPU_CULLMODE_NONE },
        .target_info = .{ .color_target_descriptions = &ctd, .num_color_targets = 1 },
    }) orelse error.GpuPipeline;
}

/// The shadow composite over the whole target: black with alpha, premultiplied "over".
fn compositePipeline(dev: *c.SDL_GPUDevice, vs: *c.SDL_GPUShader, fs: *c.SDL_GPUShader) !*c.SDL_GPUGraphicsPipeline {
    const ctd = c.SDL_GPUColorTargetDescription{
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .blend_state = .{
            .enable_blend = true,
            .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
            .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
            .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
            .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
        },
    };
    return c.SDL_CreateGPUGraphicsPipeline(dev, &.{
        .vertex_shader = vs,
        .fragment_shader = fs,
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{ .fill_mode = c.SDL_GPU_FILLMODE_FILL, .cull_mode = c.SDL_GPU_CULLMODE_NONE },
        .target_info = .{ .color_target_descriptions = &ctd, .num_color_targets = 1 },
    }) orelse error.GpuPipeline;
}

//! A project's post-processing on the GPU renderer (render/post.zig's programs as
//! shaders/post.frag, an SDL GPU render state): the game's frame (app/frame.zig) and the
//! editor's preview of it (editor/postpage.zig) draw through the same shader.

const std = @import("std");
const c = @import("sdl");
const og = @import("opengorky");

const Step = og.core.effect.Post;

/// post.frag's uniforms: steps, the picture's size; each step's program and k, rgb.
const PostU = extern struct { info: [4]f32, step: [8][4]f32, rgb: [8][4]f32 };

/// Steps the shader takes; the rest of a longer chain are dropped.
const max_steps = 8;

pub const Post = struct {
    state: ?*c.SDL_GPURenderState = null,
    shader: ?*c.SDL_GPUShader = null,
    /// No GPU renderer, or the shader did not load: the chain is not drawn.
    off: bool = false,

    pub fn deinit(self: *Post, r: *c.SDL_Renderer) void {
        if (self.state) |s| c.SDL_DestroyGPURenderState(s);
        if (self.shader) |s| if (c.SDL_GetGPURendererDevice(r)) |d| c.SDL_ReleaseGPUShader(d, s);
        self.* = .{};
    }

    /// Whether the steps can be drawn on `r` (its shader loaded on first use); logs why not, once.
    pub fn ready(self: *Post, r: *c.SDL_Renderer) bool {
        if (self.off) return false;
        if (self.state != null) return true;
        const dev = c.SDL_GetGPURendererDevice(r) orelse {
            std.log.info("post-processing off: not the GPU renderer", .{});
            self.off = true;
            return false;
        };
        self.load(r, dev) catch |err| {
            std.log.warn("post-processing off: {t} ({s})", .{ err, c.SDL_GetError() });
            self.off = true;
            return false;
        };
        std.log.info("post-processing: GPU shader", .{});
        return true;
    }

    /// `tex` (`w`×`h`) through the first `max_steps` steps over the whole current target.
    /// shortcut: steps past `max_steps` dropped; raise `PostU` if chains grow.
    pub fn draw(self: *Post, r: *c.SDL_Renderer, tex: *c.SDL_Texture, w: f32, h: f32, all: []const Step) void {
        if (!self.ready(r)) return;
        const steps = all[0..@min(all.len, max_steps)];
        var u: PostU = .{ .info = .{ @floatFromInt(steps.len), w, h, 0 }, .step = @splat(@splat(0)), .rgb = @splat(@splat(0)) };
        for (steps, 0..) |s, i| {
            u.step[i] = .{ @floatFromInt(@backingInt(s.program)), s.k, 0, 0 };
            u.rgb[i] = .{ s.rgb[0], s.rgb[1], s.rgb[2], 0 };
        }
        const state = self.state.?;
        _ = c.SDL_SetGPURenderStateFragmentUniforms(state, 0, &u, @sizeOf(PostU));
        _ = c.SDL_SetGPURenderState(r, state);
        _ = c.SDL_RenderTexture(r, tex, null, null);
        _ = c.SDL_SetGPURenderState(r, null);
    }

    fn load(self: *Post, r: *c.SDL_Renderer, dev: *c.SDL_GPUDevice) !void {
        const msl = c.SDL_GetGPUShaderFormats(dev) & c.SDL_GPU_SHADERFORMAT_SPIRV == 0;
        const code = if (msl) @embedFile("shaders/post.frag.msl") else @embedFile("shaders/post.frag.spv");
        self.shader = c.SDL_CreateGPUShader(dev, &.{
            .code_size = code.len,
            .code = code.ptr,
            .entrypoint = if (msl) "main0" else "main",
            .format = if (msl) c.SDL_GPU_SHADERFORMAT_MSL else c.SDL_GPU_SHADERFORMAT_SPIRV,
            .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
            .num_samplers = 1,
            .num_uniform_buffers = 1,
        }) orelse return error.GpuShader;
        self.state = c.SDL_CreateGPURenderState(r, &.{ .fragment_shader = self.shader }) orelse return error.GpuRenderState;
    }
};

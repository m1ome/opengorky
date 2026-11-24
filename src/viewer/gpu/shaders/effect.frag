#version 450
// raster.zig's blend and add passes for effects (billboards, attachment-point meshes):
// depth-tested against the models (model.frag's depth) else the background, no depth
// write; texel (with the material program: heat, tint) × vertex colour, then by mode:
// alpha — premultiplied "over" the models, scaling the glow under it (the canvas's
// `glow_px`); add — summed into the glow target; screen — ONE / INVSRCCOLOR into the
// screen target. The pipelines' blend states and write masks pick the targets.

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec3 v_col;
layout(location = 2) in float v_z;

layout(set = 2, binding = 0) uniform sampler2D tex;
layout(set = 2, binding = 1) uniform sampler2D bg_depth;
layout(set = 2, binding = 2) uniform sampler2D model_depth;

layout(set = 3, binding = 0) uniform E {
    vec4 mode_alpha;  // mode (0 alpha, 1 add, 2 screen); alpha; program (0 none, 1 dissolve, 2 heat, 3 tint); k
    vec4 scale;       // canvas pixels per background pixel; back faces skipped (1)
    vec4 tint;        // rgb instead of the vertex colour (w 1)
    vec4 uvx;         // uv scale, offset u, v; wrapped (1)
};

layout(location = 0) out vec4 out_color;
layout(location = 1) out vec4 out_glow;
layout(location = 2) out vec4 out_screen;

// raster.zig `noise`: Murmur2_32 of (x << 32 | y), 0…1.
float noise(uvec2 p) {
    const uint m = 0x5bd1e995u;
    uint h = 0xc70f6907u ^ 8u;
    uint k = p.y * m;
    k ^= k >> 24;
    k *= m;
    h *= m;
    h ^= k;
    k = p.x * m;
    k ^= k >> 24;
    k *= m;
    h *= m;
    h ^= k;
    h ^= h >> 13;
    h *= m;
    h ^= h >> 15;
    return float(h % 1024u) / 1024.0;
}

void main() {
    int mode = int(mode_alpha.x);
    int program = int(mode_alpha.z);
    float k = mode_alpha.w;
    ivec2 hp = ivec2(gl_FragCoord.xy);
    float d = texelFetch(model_depth, hp, 0).r;
    if (d > 1e38) {
        ivec2 bp = ivec2(gl_FragCoord.xy / scale.x);
        ivec2 bs = textureSize(bg_depth, 0);
        if (bp.x < bs.x && bp.y < bs.y) d = texelFetch(bg_depth, bp, 0).r;
    }
    // The add pass's tolerance over a surface already drawn.
    if (scale.y > 0.5 && !gl_FrontFacing) discard;
    if (mode == 0 ? v_z >= d : v_z > d + abs(d) * 1e-4 + 1e-3) discard;
    vec2 uv = v_uv * uvx.x + uvx.yz;
    if (program == 2) uv.x += sin(uv.y * 25.0 + k) * 0.03;
    if (uvx.w > 0.5) uv = fract(uv);
    vec4 t = texture(tex, clamp(uv, 0.0, 1.0));
    if (program == 3) t.rgb = clamp(mix(t.rgb, vec3(dot(t.rgb, vec3(0.299, 0.587, 0.114))), k), 0.0, 1.0);
    vec3 c = clamp(t.rgb * (tint.w > 0.5 ? tint.rgb : v_col), 0.0, 1.0);
    if (program == 1 && noise(uvec2(hp)) < k) discard;
    out_color = vec4(0.0);
    out_glow = vec4(0.0);
    out_screen = vec4(0.0);
    if (mode == 0) {
        float pa = clamp(mode_alpha.y, 0.0, 1.0) * t.a;
        if (pa <= 0.0) discard;
        out_color = vec4(c * pa, pa);
        out_glow = vec4(0.0, 0.0, 0.0, pa);
    } else if (mode == 1) {
        out_glow = vec4(c, 1.0);
    } else {
        out_screen = vec4(c, 1.0);
    }
}

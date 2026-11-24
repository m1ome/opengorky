#version 450
// raster.zig `shade` and its depth test: texel (grey 200 untextured) × vertex light,
// clamped; hidden where the background (`.zbf`, one texel per `ss` canvas pixels) is
// as close or closer — `bias` moves the model that fraction of its depth closer for the
// test only. Premultiplied alpha out (the SDL texture blends BLEND_PREMULTIPLIED).

layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec3 v_col;
layout(location = 2) in float v_z;

layout(set = 2, binding = 0) uniform sampler2D tex;
layout(set = 2, binding = 1) uniform sampler2D bg_depth;

layout(set = 3, binding = 0) uniform Draw {
    float alpha;
    float bias;
    float textured;
    float ss;
};

layout(location = 0) out vec4 out_color;
// The canvas depth where the part writes depth (the shadow composite's test).
layout(location = 1) out vec4 out_depth;

void main() {
    float zt = v_z - bias * abs(v_z);
    ivec2 bp = ivec2(gl_FragCoord.xy / ss);
    ivec2 bs = textureSize(bg_depth, 0);
    if (bp.x < bs.x && bp.y < bs.y && zt >= texelFetch(bg_depth, bp, 0).r) discard;
    vec3 c = textured > 0.5 ? texture(tex, clamp(v_uv, 0.0, 1.0)).rgb : vec3(200.0 / 255.0);
    vec3 lit = clamp(c * v_col, 0.0, 1.0);
    float a = clamp(alpha, 0.0, 1.0);
    out_color = vec4(lit * a, a);
    out_depth = vec4(v_z);
}

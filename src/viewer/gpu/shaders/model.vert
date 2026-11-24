#version 450
// A model vertex already lit and projected by the CPU (render/layer.zig drawParts): canvas
// pixels x, y and the canvas depth (larger is farther). Screen-space (w = 1), so uv and
// light interpolate affinely like the software rasterizer.

layout(location = 0) in vec3 pos;
layout(location = 1) in vec2 uv;
layout(location = 2) in vec3 col;

#ifdef MSL
#define RO(i) (i + 1)
#else
#define RO(i) (i)
#endif

layout(set = 1, binding = 0) uniform Frame {
    vec2 size;  // canvas pixels
};
// The frame's depth range (ordered float bits; light.comp grows it) onto 0…1.
layout(std430, set = 0, binding = RO(0)) readonly buffer ZRange { uint zrange[2]; };

float unordered(uint u) {
    return uintBitsToFloat((u & 0x80000000u) != 0u ? u & 0x7FFFFFFFu : ~u);
}

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec3 v_col;
layout(location = 2) out float v_z;

void main() {
    float zmin = unordered(zrange[0]);
    float span = unordered(zrange[1]) - zmin;
    float zscale = span > 0.0 ? 0.999 / span : 0.0;
    gl_Position = vec4(pos.x / size.x * 2.0 - 1.0, 1.0 - pos.y / size.y * 2.0, (pos.z - zmin) * zscale, 1.0);
    v_uv = uv;
    v_col = col;
    v_z = pos.z;
}

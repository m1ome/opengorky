#version 450
// An effect triangle's corner (render/layer.zig `billboard`, `drawEffect`): canvas pixels
// x, y and the canvas depth, screen-space like model.vert. No depth target: effect.frag
// tests depth itself, so the frame's model depth range does not clip them.

layout(location = 0) in vec3 pos;
layout(location = 1) in vec2 uv;
layout(location = 2) in vec3 col;

layout(set = 1, binding = 0) uniform Frame {
    vec2 size;  // canvas pixels
};

layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec3 v_col;
layout(location = 2) out float v_z;

void main() {
    gl_Position = vec4(pos.x / size.x * 2.0 - 1.0, 1.0 - pos.y / size.y * 2.0, 0.5, 1.0);
    v_uv = uv;
    v_col = col;
    v_z = pos.z;
}

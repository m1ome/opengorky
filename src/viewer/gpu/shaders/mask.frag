#version 450
// Shadowed (layer.zig `shadowTri`: ones, no depth test, order free).
layout(location = 0) out vec4 out_mask;

void main() {
    out_mask = vec4(1.0);
}

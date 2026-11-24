#version 450
// A shadow triangle's corner (shadow.comp: 512×512 mask coordinates) into the mask target.
layout(location = 0) in vec2 pos;

void main() {
    gl_Position = vec4(pos.x / 512.0 * 2.0 - 1.0, 1.0 - pos.y / 512.0 * 2.0, 0.0, 1.0);
}

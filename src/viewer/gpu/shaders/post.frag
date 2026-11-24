#version 450
// render/post.zig `apply` on the GPU renderer: a project's post steps over the drawn world,
// one pass (frame.zig draws the world's copy through it as an SDL GPU render state). Each
// step clamped and rounded to 8 bits as the CPU's.

layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_uv;

layout(set = 2, binding = 0) uniform sampler2D u_texture;

layout(set = 3, binding = 0) uniform Post {
    vec4 info;      // steps; target width, height
    vec4 step[8];   // program (0 grade, 1 vignette, 2 scanlines, 3 hsl); k
    vec4 rgb[8];
};

layout(location = 0) out vec4 o_color;

float hue(float p, float q, float t) {
    t -= floor(t);
    if (t < 1.0 / 6.0) return p + (q - p) * 6.0 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3.0) return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
    return p;
}

vec3 hsl(vec3 c, float turn, float sat, float light) {
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float l = (mx + mn) / 2.0;
    float d = mx - mn;
    float h = 0.0;
    float s = 0.0;
    if (d > 0.0) {
        s = l > 0.5 ? d / (2.0 - mx - mn) : d / (mx + mn);
        if (mx == c.r) h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0);
        else if (mx == c.g) h = (c.b - c.r) / d + 2.0;
        else h = (c.r - c.g) / d + 4.0;
        h /= 6.0;
    }
    h = fract(h + turn);
    s = clamp(s * sat, 0.0, 1.0);
    l = clamp(l * light, 0.0, 1.0);
    if (s == 0.0) return vec3(l);
    float q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
    float p = 2.0 * l - q;
    return vec3(hue(p, q, h + 1.0 / 3.0), hue(p, q, h), hue(p, q, h - 1.0 / 3.0));
}

void main() {
    vec4 t = texture(u_texture, v_uv) * v_color;
    vec3 c = t.rgb;
    vec2 px = floor(v_uv * info.yz);
    float fx = (px.x + 0.5) / info.y * 2.0 - 1.0;
    float fy = (px.y + 0.5) / info.z * 2.0 - 1.0;
    bool odd = (int(px.y) * 480 / int(info.z)) % 2 == 1;
    int n = int(info.x);
    for (int i = 0; i < n; i++) {
        int prog = int(step[i].x);
        float k = step[i].y;
        if (prog == 0) {
            c *= rgb[i].rgb;
            float l = dot(c, vec3(0.299, 0.587, 0.114));
            c = l + (c - l) * k;
        } else if (prog == 1) {
            c *= 1.0 - k * (fx * fx + fy * fy) / 2.0;
        } else if (prog == 2) {
            if (odd) c *= 1.0 - k;
        } else {
            c += (hsl(c, (rgb[i].r - 1.0) / 2.0, rgb[i].g, rgb[i].b) - c) * k;
        }
        c = clamp(round(c * 255.0) / 255.0, 0.0, 1.0);
    }
    o_color = vec4(c, t.a);
}

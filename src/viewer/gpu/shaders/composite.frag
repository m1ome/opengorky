#version 450
// render/layer.zig `compositeShadow` per canvas pixel: in a tile some shadow touched
// (tiles.comp), the mask's 256×256 coverage (2×2 sums, 0…4) sampled bilinearly at the
// pixel's center, the tile's floor plane depth-tested (LESSEQUAL, moved `bias` toward the
// camera) against what is there — a model (its depth, model.frag) or the background; the
// pixel darkened by intensity·coverage: black with that alpha over it (premultiplied).

layout(set = 2, binding = 0) uniform sampler2D mask;
layout(set = 2, binding = 1) uniform sampler2D bg_depth;
layout(set = 2, binding = 2) uniform sampler2D model_depth;
#ifdef MSL
#define RO(i) (i + 1)
#else
#define RO(i) (i + 3)
#endif
layout(std430, set = 2, binding = RO(0)) readonly buffer Tiles { float tiles[64]; };

layout(set = 3, binding = 0) uniform C {
    vec4 screen;      // screen pixels w, h; canvas pixels per screen pixel; perspective (1) or not
    vec4 origin;      // layer origin; intensity; bias
    vec4 ortho;       // k
    vec4 eye_scale;
    vec4 fwd;
    vec4 right;
    vec4 up;
    vec4 persp;       // focal, focal_y, cx, cy
};

layout(location = 0) out vec4 out_color;

float covAt(int tx, int ty) {
    ivec2 m = ivec2(tx * 2, ty * 2);
    return texelFetch(mask, m, 0).r + texelFetch(mask, m + ivec2(1, 0), 0).r + texelFetch(mask, m + ivec2(0, 1), 0).r + texelFetch(mask, m + ivec2(1, 1), 0).r;
}

// Where canvas column (row) `i` samples the 256×256 coverage (layer.zig shadowAxis).
void axis(float i, float ss, float n, out float e, out float frac, out int lo, out int hi) {
    e = (i + 0.5) / ss;
    float v = (1.0 + e * 2.0 * 255.0 / n) / 2.0 - 0.5;
    float iv = floor(v);
    frac = v - iv;
    lo = int(clamp(iv, 0.0, 255.0));
    hi = int(clamp(iv + 1.0, 0.0, 255.0));
}

float planeDepth(float x, float y, float z) {
    if (screen.w < 0.5) return y + 2.0 * z / ortho.x;
    float a = (x - persp.z) / persp.x;
    float b = (persp.w - y) / persp.y;
    float dy = fwd.y + right.y * a + up.y * b;
    if (abs(dy) < 1e-6) return -3e38;
    return -((z * eye_scale.w - eye_scale.y) / dy);
}

void main() {
    ivec2 hp = ivec2(gl_FragCoord.xy);
    float ss = screen.z;
    int w = int(screen.x);
    int h = int(screen.y);
    ivec2 sp = hp / int(ss);
    int tw = max(1, w / 8);
    int th = max(1, h / 8);
    float zg = tiles[min(sp.y / th, 7) * 8 + min(sp.x / tw, 7)];
    if (zg > 1e38) discard;
    float ex, fx, ey, fy;
    int x0, x1, y0, y1;
    axis(float(hp.x), ss, screen.x, ex, fx, x0, x1);
    axis(float(hp.y), ss, screen.y, ey, fy, y0, y1);
    float sum = (covAt(x0, y0) * (1.0 - fx) + covAt(x1, y0) * fx) * (1.0 - fy) + (covAt(x0, y1) * (1.0 - fx) + covAt(x1, y1) * fx) * fy;
    if (sum <= 0.0) discard;
    float plane = -planeDepth(ex + origin.x, ey + origin.y, zg) - origin.w;
    float d = texelFetch(model_depth, hp, 0).r;
    if (d > 1e38) d = texelFetch(bg_depth, sp, 0).r;
    if (plane > d) discard;
    float a = clamp(origin.z * sum / 4.0, 0.0, 1.0);
    out_color = vec4(0.0, 0.0, 0.0, a);
}

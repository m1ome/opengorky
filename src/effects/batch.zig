//! Billboards of the exe's particle batch (0x45e150) for world effects: bitmaps, trails,
//! projectile planes. Each enumerator hands them to a sink (`put(Billboard)`) — the
//! viewer's level renderer, the editor's model preview.

const bitmap = @import("bitmap.zig");
const projectile = @import("projectile.zig");

/// One batch billboard: `.dsc` effect `name`, half size `half`, colour `rgb`, alpha.
pub const Billboard = struct { name: []const u8, frame: u32, pos: [3]f32, half: f32, alpha: f32 = 1, rgb: [3]f32 = .{ 1, 1, 1 } };

/// Bitmaps and flashes (0x4cb600, draw 0x4cb8b0); `as` is actorScale.
pub fn bitmaps(items: []const bitmap.Bitmap, as: f32, sink: anytype) !void {
    for (items) |bm| {
        if (bm.delay > 0) continue;
        try sink.put(.{ .name = bm.effect, .frame = if (bm.flash_rate > 0) 0 else bm.frame(), .pos = bm.pos, .half = as * bm.drawSize(), .alpha = bm.alpha, .rgb = bm.rgb });
    }
}

/// Trails (0x4cd4a0): separate objects that outlive the projectile; size and
/// brightness fall toward the tail.
pub fn trails(items: []const projectile.Trail, as: f32, sink: anytype) !void {
    for (items) |t| {
        var s: f32 = 1;
        var a: f32 = 1;
        var idx: usize = t.head;
        for (0..t.count) |k| {
            if (s <= 0.01 or a <= 0.01) break;
            if (k >= t.eaten) try sink.put(.{ .name = t.effect, .frame = @intCast(k), .pos = t.pts[idx], .half = as * s * t.size, .alpha = a, .rgb = t.rgb });
            s -= t.size_fade;
            a *= t.fade;
            idx = (idx + 1) % projectile.Trail.ring;
        }
    }
}

/// Projectile planes (0x49bab0): a projectile without a body mesh, bullet or rocket.
pub fn projectilePlanes(items: []const projectile.Projectile, as: f32, sink: anytype) !void {
    for (items) |pr| {
        if (pr.done or pr.bullet or pr.rocket or pr.effect.len == 0) continue;
        if (pr.ball) |b| {
            // Ball (0x4a6280): two "kula" frames cross-fading by wave a, sizes ±40·b,
            // then "poswiata" 400 tinted (0.2 + 0.08a, 0.2, 0.4); scale / attack_ball_ms.
            const s = pr.k * pr.mesh_scale / projectile.attackBallMs();
            const fade = 2.5 * b.a + 0.5;
            try sink.put(.{ .name = "kula", .frame = b.f1, .pos = pr.pos, .half = as * (130 * s + 40 * b.b), .alpha = fade });
            try sink.put(.{ .name = "kula", .frame = b.f2, .pos = pr.pos, .half = as * (130 * s + 8 - 40 * b.b), .alpha = 1 - fade });
            try sink.put(.{ .name = "poswiata", .frame = 0, .pos = pr.pos, .half = as * 400 * s, .rgb = .{ 0.2 + 0.08 * b.a, 0.2, 0.4 } });
            continue;
        }
        try sink.put(.{ .name = pr.effect, .frame = pr.ticks, .pos = pr.pos, .half = as * pr.size * pr.k });
    }
}

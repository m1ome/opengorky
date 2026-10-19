//! Ground markers: click point (0x4c81e0), speaker (0x459e60), active areas (0x4bd640).

const std = @import("std");
const level = @import("../level.zig");
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");
const LevelView = level.LevelView;
const World = og.state.world.World;

pub fn drawMarker(l: *LevelView, scroll: [2]f32) !void {
    const mk = l.marker orelse return;
    const v = l.fx_view orelse return;
    // Tick 0x4c81e0: size starts at 30 (factory arg 0x4c8560), +24 per tick
    // (+0x2ec); past 150 the step flips sign (peak 174); below 0 it ends.
    var s: f32 = 30;
    var step: f32 = 24;
    for (0..l.world.ticks -% mk.start) |_| {
        s += step;
        if (s > 150) step = -step;
    }
    if (s < 0) {
        l.marker = null;
        return;
    }
    // Object 0x4c7ff0: kwadrat with disturb.3df, additive, no depth.
    const col: [4]f32 = if (mk.ok) .{ 0.1, 0.4, 0.1, 1 } else .{ 0.4, 0.1, 0.1, 1 };
    try v.drawMeshTexAdd(.{ .arena = l.frame_arena.allocator(), .cam = l.world.cam, .scroll = scroll }, "disturb.3df", mk.pos, .{ 0, 1, 0 }, l.world.actorScale() * s, col);
}

/// Speaker marker (0x459e60, dialog box pre-draw — any dialog and scenes):
/// kwadrat + disturb.3df under the speaking actor, scale 350, pulse
/// s = 0.7 + 0.3·|sin 1.5t| on clock 0x402c00 (0x459e98), colour (0.2s, 0.4s,
/// 0.2s), additive.
pub fn drawSpeakerMarker(l: *LevelView, scroll: [2]f32) !void {
    const w = l.world;
    const line = w.scene.subtitle orelse return;
    const v = l.fx_view orelse return;
    const o = for (w.rt.objects.items) |o| {
        const n = World.nativeOf(o);
        if (n.kind != .actor or !o.enabled or n.deleted or !n.actor.placed) continue;
        if (std.ascii.eqlIgnoreCase(o.name, line.speaker) or std.ascii.eqlIgnoreCase(w.stringOr(og.fields.nameId(o), ""), line.speaker)) break o;
    } else return;
    if (w.battle) |*b| if (b.fighterOf(o)) |fi| if (!b.fighters.items[fi].alive()) return;
    const t = og.num.toF32(l.now_ms) / 1000;
    const s = 0.7 + 0.3 * @abs(@sin(1.5 * t));
    try v.drawMeshTexAdd(.{ .arena = l.frame_arena.allocator(), .cam = w.cam, .scroll = scroll }, "disturb.3df", og.fields.pos(o), .{ 0, 1, 0 }, l.world.actorScale() * 350, .{ 0.2 * s, 0.4 * s, 0.2 * s, 1 });
}

/// Active area markers (ActiveArea, tick 0x4bd510, draw 0x4bd640): at the area's
/// control point when a party hero is closer than 250 px and noHint ≠ 1, outside
/// battle, scenes and windows; "breathes" on clock 0x402c00 (0x4bd643):
/// v = ((sin 4t + 1)/2 + 1)/2, size v·35, grey (1 − (v − 0.3))·255, additive.
pub fn drawAreaMarkers(l: *LevelView, r: *c.SDL_Renderer, scroll: [2]f32) !void {
    const w = l.world;
    if (w.battle != null or w.scene.cutscene or w.scene.panorama or w.scene.runner != null or l.ui_modal) return;
    if (!l.arrows_loaded) {
        l.arrows_loaded = true;
        if (l.models) |m| if (m.readFile("gfx_3d\\textures\\strzalki.3df")) |bytes| {
            if (og.formats.tex3df.decode(l.gpa, bytes)) |img_| {
                var img = img_;
                defer img.deinit(l.gpa);
                l.arrows_tex = gfx.textureLinear(r, img) catch null;
                if (l.arrows_tex) |tx| _ = c.SDL_SetTextureBlendMode(tx, gfx.blendAdd());
            } else |_| {}
        } else |_| {};
    }
    const tex = l.arrows_tex orelse return;
    const t = og.num.toF32(l.now_ms) / 1000;
    const v = ((@sin(4 * t) + 1) * 0.5 + 1) * 0.5;
    const sz: f32 = @trunc(v * 35);
    const half: f32 = @floor(sz / 2);
    const g = std.math.clamp(@trunc((1 - (v - 0.3)) * 255), 0, 255) / 255;
    _ = c.SDL_SetTextureColorModFloat(tex, g, g, g);
    defer _ = c.SDL_SetTextureColorModFloat(tex, 1, 1, 1);
    const heroes = w.party();
    const party = heroes.slice();
    for (w.rt.objects.items) |o| {
        const n = World.nativeOf(o);
        if (n.kind != .area or !o.enabled or n.deleted) continue;
        if (o.getInt("noHint") == 1) continue;
        const area = og.world.areas.findArea(w, o.getString("areaName")) orelse continue;
        // Centre of the area polygon's bbox (0x4792e0: +0x33c/+0x340), not the entry point.
        if (area.points.len == 0) continue;
        var lo = [2]f32{ area.points[0][0], area.points[0][1] };
        var hi = lo;
        for (area.points) |pt| {
            lo = .{ @min(lo[0], pt[0]), @min(lo[1], pt[1]) };
            hi = .{ @max(hi[0], pt[0]), @max(hi[1], pt[1]) };
        }
        const cp = [2]f32{ @trunc((lo[0] + hi[0]) / 2), @trunc((lo[1] + hi[1]) / 2) };
        var near = false;
        for (party) |h| {
            const p = w.screenPos(h);
            const dx = p[0] - cp[0];
            const dy = p[1] - cp[1];
            if (dx * dx + dy * dy < 250 * 250) near = true;
        }
        if (!near) continue;
        const dst: c.SDL_FRect = .{ .x = @trunc(cp[0]) - half - scroll[0], .y = @trunc(cp[1]) - half - scroll[1], .w = sz, .h = sz };
        try gfx.check(c.SDL_RenderTexture(r, tex, null, &dst));
    }
}

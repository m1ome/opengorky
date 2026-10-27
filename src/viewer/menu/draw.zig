//! Menu drawing: scene, monster, flares, items, credits. Menu methods (see viewer/menu.zig).

const std = @import("std");
const menu_slots = @import("slots.zig");
const menu_mod = @import("../menu.zig");
const Menu = menu_mod.Menu;
const og = @import("opengorky");
const adj = og.formats.adjust;

/// Brightness `name` (0…255, the shipped 255) as a grey tint.
fn grey3(name: []const u8) [3]u8 {
    const v: u8 = @intCast(std.math.clamp(adj.getInt(name, 255), 0, 255));
    return .{ v, v, v };
}
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");
const loadTex = @import("font.zig").loadTex;

/// Credits (0x42c880, tick 0x42c830): lines centred 34 px apart; +1 px per tick,
/// after 34 the next line; the first visible starts at −15 (line 0 at y = 510);
/// headings (104,168,136), names (112,136,88); ends when the first visible is past
/// the last + 3.
fn drawCredits(self: *Menu, r: *c.SDL_Renderer) !void {
    if (self.credits_bg.len() > 0) try self.credits_bg.draw(r, 0, 0, 0);
    if (self.credits_font == null) return;
    const ticks: i64 = @intCast((c.SDL_GetTicks() - self.credits_start_ms + self.credits_skip_ms) * og.state.world.tick_hz / 1000);
    const first = @divTrunc(ticks, 35) - 15;
    const shift = @min(@mod(ticks, 35), 34);
    @memset(self.text.pixels, 0);
    for (self.credits_rows.items, 0..) |row, k| {
        const y = 34 * (@as(i64, @intCast(k)) - first) - shift;
        if (y < -40 or y > 480) continue;
        const f = &self.credits_sets[@min(row.charset, 9)];
        const color: [3]u8 = if (row.title) adj.getRgb("cftCreditsTitle", .{ 104, 168, 136 }) else adj.getRgb("cftCreditsNormal", .{ 112, 136, 88 });
        const w: i64 = @intCast(f.measure(row.text));
        f.draw(self.text, @intCast(320 - @divTrunc(w, 2)), @intCast(y), row.text, color);
    }
    try gfx.drawImage(r, &self.text_tex, self.text);
    // Everything scrolled past the top: credits over.
    if (first > @as(i64, @intCast(self.credits_rows.items.len)) + 3) self.screen = self.back_to;
}

/// Textured quad (0x40c0d0: UV 0..1, CLAMP addressing — 0x40a400(0) in 0x416428).
/// In Direct3D 7 the pixel centre is integer, so quad pixel j samples v = j/h; in
/// SDL the centre is j + 0.5, so the quad is shifted half a pixel to match
/// (otherwise the texture's bottom row lands fully in the frame).
fn quad(r: *c.SDL_Renderer, tex: ?*c.SDL_Texture, mode: c.SDL_BlendMode, grey: [3]u8, x: f32, y: f32, w: f32, h: f32) !void {
    return quadSrc(r, tex, null, mode, grey, x, y, w, h);
}

fn quadSrc(r: *c.SDL_Renderer, tex: ?*c.SDL_Texture, src: ?*const c.SDL_FRect, mode: c.SDL_BlendMode, grey: [3]u8, x: f32, y: f32, w: f32, h: f32) !void {
    const t = tex orelse return;
    _ = c.SDL_SetTextureBlendMode(t, mode);
    _ = c.SDL_SetTextureColorMod(t, grey[0], grey[1], grey[2]);
    try gfx.check(c.SDL_RenderTexture(r, t, src, &.{ .x = x + 0.5, .y = y + 0.5, .w = w, .h = h }));
}

/// Shadow offset of point (px, py) from the cursor (0x416270): ±20, (−d·10) >> 8.
fn shadowOff(mouse: [2]f32, px: f32, py: f32) [2]f32 {
    const dx: i32 = @intFromFloat(-(mouse[0] - px) * 10);
    const dy: i32 = @intFromFloat(-(mouse[1] - py) * 10);
    return .{ @floatFromInt(std.math.clamp(dx >> 8, -20, 20)), @floatFromInt(std.math.clamp(dy >> 8, -20, 20)) };
}

/// Monster (step 7): mesh parts multiplied by the light map; X·32.2, Y·32.2
/// from screen centre (ortho camera ±320×±240, model scale 23 × 1.4).
fn drawMonster(self: *Menu, r: *c.SDL_Renderer) !void {
    const models = self.models orelse return;
    const model = models.get("menu") orelse return;
    if (!self.part_tex_loaded) {
        self.part_tex_loaded = true;
        if (self.other) |*o| for (model.mesh.parts, 0..) |p, i| {
            if (i >= self.part_tex.len) break;
            const name = std.fs.path.basenameWindows(p.texture);
            self.part_tex[i] = loadTex(self.io, self.gpa, r, o, name);
        };
    }
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const ticks = og.num.toF32(c.SDL_GetTicks() - self.start_ms) * og.num.toF32(og.state.world.tick_hz) / 1000;
    const frame = model.frameOf("menu", ticks, true);
    const pts = try og.actor.skin.pose(arena.allocator(), model.mesh, model.frames, frame, .row);
    const k = 1.4 * (if (model.mesh.height > 0) model.mesh.height else 23);
    for (model.mesh.parts, pts, 0..) |part, ppts, i| {
        const tex = if (i < self.part_tex.len) self.part_tex[i] else null;
        const t = tex orelse continue;
        _ = c.SDL_SetTextureBlendMode(t, self.modes.multiply);
        _ = c.SDL_SetTextureColorMod(t, 255, 255, 255);
        const verts = try arena.allocator().alloc(c.SDL_Vertex, ppts.len);
        for (verts, ppts, part.vertices) |*v, p, src| v.* = .{
            .position = .{ .x = 320 + k * (p[0] + model.mesh.center[0]), .y = 240 - k * (p[1] + model.mesh.center[1]) },
            .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
            .tex_coord = .{ .x = src.uv[0], .y = src.uv[1] },
        };
        const idx = try arena.allocator().alloc(c_int, part.triangles.len * 3);
        for (part.triangles, 0..) |tri, j| for (tri, 0..) |v, n| {
            idx[j * 3 + n] = v;
        };
        try gfx.check(c.SDL_RenderGeometry(r, t, verts.ptr, @intCast(verts.len), idx.ptr, @intCast(idx.len)));
    }
}

/// Menu frame (0x416330): light map, shadows, monster, logo, items, flares.
fn drawScene(self: *Menu, r: *c.SDL_Renderer, mouse_in: [2]f32) !void {
    const mouse = [2]f32{ @min(mouse_in[0], 637), @min(mouse_in[1], 477) };
    const m = self.modes;
    const white: [3]u8 = .{ 255, 255, 255 };
    // 1. Grey 60 (menu_fade_intensity): the light map.
    const grey: u8 = @intCast(std.math.clamp(adj.getInt("menu_fade_intensity", 60), 0, 255));
    try gfx.check(c.SDL_SetRenderDrawColor(r, grey, grey, grey, 255));
    try gfx.check(c.SDL_RenderClear(r));
    // 2–3. Spot behind the cursor (menu_fade_size 400, menu_light_color 255,255,150) and the logo halo.
    const spot: f32 = @floatFromInt(adj.getInt("menu_fade_size", 400));
    try quad(r, self.circle, m.add, adj.getRgb("menu_light_color", .{ 255, 255, 150 }), mouse[0] - spot / 2, mouse[1] - spot / 2, spot, spot);
    try quad(r, self.logo_light, m.add, white, -30, -30, 480, 212);
    const list = self.items();
    const sel = self.selected[@backingInt(self.screen)];
    var buf: [96]u8 = undefined;
    // 4. Selected item glow: font 3d_menuG ×2, 10 lower.
    const vr = self.visible();
    const sel_vis = sel >= vr[0] and sel < vr[1];
    if (sel_vis) try self.glow.draw(r, self.label(list[sel], &buf), 320, self.itemY(sel) + 10, 2, white, m.add);
    // 5. Item shadows, from the cursor.
    for (list[vr[0]..vr[1]], vr[0]..) |it, k| {
        const y = self.itemY(k);
        const o = shadowOff(mouse, 320, y);
        try self.font.draw(r, self.label(it, &buf), 320 + o[0], y + o[1], 1, white, m.darken);
    }
    // 6. Logo shadow (centre (210, 76)).
    const lo = shadowOff(mouse, 210, 76);
    try quad(r, self.logo, m.darken, .{ 200, 200, 200 }, 210 + lo[0] - 200, 76 + lo[1] - 66, 400, 132);
    // 7. Monster multiplied by the light map.
    try drawMonster(self, r);
    // 8–9. Logo and screen title.
    try quad(r, self.logo, m.screen, .{ 200, 200, 200 }, 10, 10, 400, 132);
    if (self.title()) |t| try self.font.draw(r, t, 320, self.offset() + 170, 1, white, m.screen);
    // 10. Items additive: grey 128, selected 255.
    for (list[vr[0]..vr[1]], vr[0]..) |it, k| if (k != sel) {
        try self.font.draw(r, self.label(it, &buf), 320, self.itemY(k), 1, .{ 128, 128, 128 }, m.add);
    };
    if (sel_vis) try self.font.draw(r, self.label(list[sel], &buf), 320, self.itemY(sel), 1, white, m.add);
}

/// Flares (step 12): a star at the cursor; lenses mirror the cursor through the centre.
fn drawFlares(self: *Menu, r: *c.SDL_Renderer, mouse_in: [2]f32) !void {
    const mouse = [2]f32{ @min(mouse_in[0], 637), @min(mouse_in[1], 477) };
    const m = self.modes;
    // Star 200×300 (menu_flare_width/height, brightness menu_flare_intensity 255;
    // 0x416763…0x4167c4). The last row of `menuflare.3df` is artist junk
    // (16,16,8,16… across), visible in the exe as a faint line under the star.
    // Deviation at the player's request: that row is not used.
    if (self.flare) |t| {
        var fw: f32 = 0;
        var fh: f32 = 0;
        _ = c.SDL_GetTextureSize(t, &fw, &fh);
        const src: c.SDL_FRect = .{ .x = 0, .y = 0, .w = fw, .h = @max(1, fh - 1) };
        const w: f32 = @floatFromInt(adj.getInt("menu_flare_width", 200));
        const h: f32 = @floatFromInt(adj.getInt("menu_flare_height", 300));
        try quadSrc(r, t, &src, m.add, grey3("menu_flare_intensity"), mouse[0] - w / 2, mouse[1] - h / 2, w, h);
    }
    // Lenses mirrored through the centre at menu_lens_dist / menu_lens2_dist.
    const d1 = adj.getFloat("menu_lens_dist", 0.4);
    const s1: f32 = @floatFromInt(adj.getInt("menu_lens_size", 100));
    const l1 = [2]f32{ 320 + (320 - mouse[0]) * d1, 240 + (240 - mouse[1]) * d1 };
    try quad(r, self.lens, m.screen, grey3("menu_lens_intensity"), l1[0] - s1 / 2, l1[1] - s1 / 2, s1, s1);
    const d2 = adj.getFloat("menu_lens2_dist", 1);
    const s2: f32 = @floatFromInt(adj.getInt("menu_lens2_size", 50));
    const l2 = [2]f32{ 320 + (320 - mouse[0]) * d2, 240 + (240 - mouse[1]) * d2 };
    try quad(r, self.lens2, m.screen, grey3("menu_lens2_intensity"), l2[0] - s2 / 2, l2[1] - s2 / 2, s2, s2);
}

/// Selection under the mouse only if the mouse moved (0x415b42); a change plays a sound.
fn updateHover(self: *Menu, mouse: [2]f32) void {
    if (mouse[0] == self.last_mouse[0] and mouse[1] == self.last_mouse[1]) return;
    self.last_mouse = mouse;
    const k = self.itemAt(mouse[0], mouse[1]) orelse return;
    const s = &self.selected[@backingInt(self.screen)];
    if (s.* != k) {
        s.* = k;
        self.select_sound = true;
    }
}

pub fn draw(self: *Menu, r: *c.SDL_Renderer, mouse: [2]f32) !void {
    if (self.screen == .credits) {
        try gfx.check(c.SDL_SetRenderDrawColor(r, 0, 0, 0, 255));
        try gfx.check(c.SDL_RenderClear(r));
        return drawCredits(self, r);
    }
    updateHover(self, mouse);
    self.tickLogic(mouse);
    const s = &self.selected[@backingInt(self.screen)];
    s.* = @min(s.*, self.items().len -| 1);
    try drawScene(self, r, mouse);
    if (self.arrows()) |a| if (self.arrow) |t| {
        _ = c.SDL_SetTextureBlendMode(t, self.modes.add);
        _ = c.SDL_SetTextureColorMod(t, 255, 255, 255);
        for (a.hit, a.draw_x, 0..) |rc, dx, k| {
            const dst: c.SDL_FRect = .{ .x = dx, .y = rc[1], .w = rc[2], .h = rc[3] };
            // The left arrow is the same texture mirrored.
            try gfx.check(c.SDL_RenderTextureRotated(r, t, null, &dst, 0, null, if (k == 0) c.SDL_FLIP_HORIZONTAL else c.SDL_FLIP_NONE));
        }
    };
    if (self.screen == .load or self.screen == .save) try menu_slots.drawSlots(self, r);
    try drawFlares(self, r, mouse);
}

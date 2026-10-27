//! The level map drawn (level.Doc.draw): background, walkable cells, objects with their
//! icons and facing, areas, a battle's grid with its numbers.

const std = @import("std");
const og = @import("opengorky");
const c = @import("sdl");
const Font = @import("font.zig").Font;
const placement = @import("placement.zig");
const lf = og.formats.level_files;
const level = @import("level.zig");
const Doc = level.Doc;
const Obj = level.Obj;
const Kind = level.Kind;

pub fn polyArea(poly: []const [3]f32) f32 {
    var sum: f32 = 0;
    for (poly, 0..) |p, i| {
        const q = poly[(i + 1) % poly.len];
        sum += p[0] * q[1] - q[0] * p[1];
    }
    return @abs(sum) / 2;
}

/// Fills polygon `poly` (background pixels, maybe concave) by ear clipping.
pub fn fillPoly(self: *const Doc, r: *c.SDL_Renderer, rect: c.SDL_FRect, poly: []const [3]f32, rgba: [4]u8) void {
    if (poly.len < 3 or poly.len > 64) return;
    var idx: [64]usize = undefined;
    var n = poly.len;
    for (0..n) |i| idx[i] = i;
    // Winding sign, so "convex corner" means the same either way round.
    var sum: f32 = 0;
    for (poly, 0..) |p, i| {
        const q = poly[(i + 1) % poly.len];
        sum += p[0] * q[1] - q[0] * p[1];
    }
    const sign: f32 = if (sum >= 0) 1 else -1;
    const col: c.SDL_FColor = .{ .r = @as(f32, @floatFromInt(rgba[0])) / 255, .g = @as(f32, @floatFromInt(rgba[1])) / 255, .b = @as(f32, @floatFromInt(rgba[2])) / 255, .a = @as(f32, @floatFromInt(rgba[3])) / 255 };
    var guard: usize = 0;
    while (n > 2 and guard < 64 * 64) : (guard += 1) {
        var cut = false;
        for (0..n) |k| {
            const a = poly[idx[(k + n - 1) % n]];
            const b = poly[idx[k]];
            const cc = poly[idx[(k + 1) % n]];
            const cross = (b[0] - a[0]) * (cc[1] - a[1]) - (b[1] - a[1]) * (cc[0] - a[0]);
            if (cross * sign <= 0) continue;
            // No other corner inside the ear.
            const empty = for (0..n) |m| {
                if (m == k or m == (k + n - 1) % n or m == (k + 1) % n) continue;
                const p = poly[idx[m]];
                if (inTri(p, a, b, cc)) break false;
            } else true;
            if (!empty) continue;
            var v: [3]c.SDL_Vertex = undefined;
            for ([_][3]f32{ a, b, cc }, 0..) |pt, j| {
                const sp = self.toScreen(rect, .{ pt[0], pt[1] });
                v[j] = .{ .position = .{ .x = sp[0], .y = sp[1] }, .color = col, .tex_coord = .{ .x = 0, .y = 0 } };
            }
            _ = c.SDL_RenderGeometry(r, null, &v, 3, null, 0);
            std.mem.copyForwards(usize, idx[k .. n - 1], idx[k + 1 .. n]);
            n -= 1;
            cut = true;
            break;
        }
        if (!cut) break;
    }
}

pub fn inTri(p: [3]f32, a: [3]f32, b: [3]f32, cc: [3]f32) bool {
    const d1 = (p[0] - b[0]) * (a[1] - b[1]) - (a[0] - b[0]) * (p[1] - b[1]);
    const d2 = (p[0] - cc[0]) * (b[1] - cc[1]) - (b[0] - cc[0]) * (p[1] - cc[1]);
    const d3 = (p[0] - a[0]) * (cc[1] - a[1]) - (cc[0] - a[0]) * (p[1] - a[1]);
    const neg = d1 < 0 or d2 < 0 or d3 < 0;
    const pos = d1 > 0 or d2 > 0 or d3 > 0;
    return !(neg and pos);
}

/// Object `o` left out of the editor's view (its eye, or its kind's, closed).
pub fn hiddenInView(self: *const Doc, o: Obj) bool {
    const h = self.view_hidden orelse return false;
    if (h.contains(o.name)) return true;
    var buf: [32]u8 = undefined;
    return h.contains(std.fmt.bufPrint(&buf, "kind:{t}", .{o.kind}) catch return false);
}

pub fn kindColor(k: Kind) [3]u8 {
    return switch (k) {
        .enemy => .{ 235, 70, 60 },
        .hero => .{ 70, 140, 255 },
        .neutral => .{ 170, 170, 170 },
        .prop => .{ 190, 120, 255 },
        .item => .{ 250, 200, 60 },
        .actor => .{ 120, 220, 140 },
        .area => .{ 80, 200, 230 },
    };
}

/// `bg`: the background picture too (the level edit mode draws its own layers).
pub fn draw(self: *Doc, r: *c.SDL_Renderer, font: *const Font, rect: c.SDL_FRect, selected: ?usize, walk: bool, bg: bool) void {
    if (!self.fitted) self.fit(rect);
    if (bg) if (self.bg) |t| {
        const a = self.toScreen(rect, .{ 0, 0 });
        _ = c.SDL_RenderTexture(r, t, null, &.{ .x = a[0], .y = a[1], .w = self.bg_size[0] * self.zoom, .h = self.bg_size[1] * self.zoom });
    };
    if ((walk or self.preview != null) and !self.isBattle()) self.drawWalk(r, rect);
    const cm_opt = self.grid_view orelse self.world.combat_map;
    if (cm_opt) |cm| if (!self.grid_hidden) self.drawGrid(r, font, rect, cm);
    for (self.objects.items, 0..) |o, i| {
        if (self.hiddenInView(o)) continue;
        const sel = selected != null and selected.? == i;
        const col: [3]u8 = if (o.later != null) .{ 150, 150, 150 } else kindColor(o.kind);
        if (o.tile) |t| if (cm_opt) |cm| {
            self.fillTiles(r, rect, cm, t, o.size, .{ col[0], col[1], col[2], if (sel) 170 else if (o.later != null) 60 else 90 });
            if (o.call) |ci| if (self.script.calls[ci].func == .enemy_appear) self.drawEntry(r, rect, cm, self.script.calls[ci], o.size, col);
        };
        if (o.poly) |poly| {
            // A real area (not a point marker): filled.
            if (polyArea(poly) > 300) fillPoly(self, r, rect, poly, .{ col[0], col[1], col[2], if (sel) 90 else 45 });
            _ = c.SDL_SetRenderDrawColor(r, col[0], col[1], col[2], if (sel) 255 else 110);
            for (poly, 0..) |p, k| {
                const n = poly[(k + 1) % poly.len];
                const a = self.toScreen(rect, .{ p[0], p[1] });
                const b = self.toScreen(rect, .{ n[0], n[1] });
                _ = c.SDL_RenderLine(r, a[0], a[1], b[0], b[1]);
            }
        }
        const q = self.toScreen(rect, o.pos);
        const s: f32 = if (sel) 6 else 4;
        _ = c.SDL_SetRenderDrawColor(r, 0, 0, 0, 200);
        _ = c.SDL_RenderFillRect(r, &.{ .x = q[0] - s - 1, .y = q[1] - s - 1, .w = 2 * s + 2, .h = 2 * s + 2 });
        _ = c.SDL_SetRenderDrawColor(r, col[0], col[1], col[2], 255);
        if (o.kind == .prop) {
            // Props: a hollow marker (not on the grid, no footprint).
            _ = c.SDL_RenderRect(r, &.{ .x = q[0] - s, .y = q[1] - s, .w = 2 * s, .h = 2 * s });
        } else _ = c.SDL_RenderFillRect(r, &.{ .x = q[0] - s, .y = q[1] - s, .w = 2 * s, .h = 2 * s });
        const label_w = font.measure(o.name, 0, 13)[0];
        _ = c.SDL_SetRenderDrawColor(r, 0, 0, 0, 150);
        // Battles: the label under the marker, so facing arrows (mostly right) stay clear.
        const lp: [2]f32 = if (self.isBattle()) .{ q[0] - label_w / 2 - 3, q[1] + 9 } else .{ q[0] + 8, q[1] - 9 };
        _ = c.SDL_RenderFillRect(r, &.{ .x = lp[0], .y = lp[1], .w = label_w + 6, .h = 18 });
        const fg: [4]u8 = if (self.isBattle() and (o.call == null or o.later != null)) .{ 160, 160, 160, 255 } else .{ 255, 255, 255, 255 };
        font.draw(r, o.name, if (sel) 1 else 0, 13, lp[0] + 3, lp[1], fg);
        // Over the label: which way it faces (from its tile block's centre).
        if (cm_opt) |cm| if (self.facing(i)) |deg| {
            const half = @as(f32, @floatFromInt(o.size)) / 2;
            const g = o.grid orelse if (o.tile) |t| [2]f32{ @as(f32, @floatFromInt(t[0])) + half, @as(f32, @floatFromInt(t[1])) + half } else continue;
            self.drawFacing(r, rect, cm, g, deg, col);
        };
    }
    if (selected) |i| if (i < self.objects.items.len) if (self.turnHandles(rect, i)) |hs| {
        self.drawTurn(r, hs[0], false);
        self.drawTurn(r, hs[1], true);
    };
    if (self.preview) |p| if (p.bg) |b| {
        const q = self.toScreen(rect, b);
        if (p.ok) _ = c.SDL_SetRenderDrawColor(r, 80, 255, 120, 255) else _ = c.SDL_SetRenderDrawColor(r, 255, 60, 60, 255);
        _ = c.SDL_RenderFillRect(r, &.{ .x = q[0] - 6, .y = q[1] - 6, .w = 12, .h = 12 });
    };
    if (self.preview) |p| if (p.bg == null) if (cm_opt) |cm| {
        const o = self.objects.items[p.obj];
        const col: [4]u8 = if (p.ok) .{ 80, 255, 120, 150 } else .{ 255, 60, 60, 150 };
        const at = if (o.grid != null) self.gridPos(cm, p.grid) else blk: {
            self.fillTiles(r, rect, cm, p.tile, o.size, col);
            break :blk self.tilePos(cm, p.tile, o.size);
        };
        const q = self.toScreen(rect, at);
        _ = c.SDL_SetRenderDrawColor(r, col[0], col[1], col[2], 255);
        _ = c.SDL_RenderFillRect(r, &.{ .x = q[0] - 5, .y = q[1] - 5, .w = 10, .h = 10 });
    };
}

/// Walkable cells (8×8 background pixels): green, the second floor's (`.wm2`) blue.
pub fn drawWalk(self: *Doc, r: *c.SDL_Renderer, rect: c.SDL_FRect) void {
    const m = self.world.walk_map orelse return;
    if (self.walk_tex == null) {
        var img = og.formats.image.Image.init(self.gpa, m.width, m.height) catch return;
        defer img.deinit(self.gpa);
        for (0..m.height) |y| for (0..m.width) |x| {
            const px = img.pixels[(y * m.width + x) * 4 ..][0..4];
            if (m.at(x, y).walkable()) px.* = .{ 60, 230, 110, 90 } else if (self.world.walk_map2) |m2| {
                if (x < m2.width and y < m2.height and m2.at(x, y).walkable()) px.* = .{ 70, 140, 255, 90 };
            }
        };
        const t = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, @intCast(m.width), @intCast(m.height)) orelse return;
        _ = c.SDL_UpdateTexture(t, null, img.pixels.ptr, @intCast(m.width * 4));
        _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetTextureScaleMode(t, c.SDL_SCALEMODE_NEAREST);
        self.walk_tex = t;
    }
    const k: f32 = lf.WalkMap.cell_size;
    const a = self.toScreen(rect, .{ 0, 0 });
    _ = c.SDL_RenderTexture(r, self.walk_tex.?, null, &.{ .x = a[0], .y = a[1], .w = @as(f32, @floatFromInt(m.width)) * k * self.zoom, .h = @as(f32, @floatFromInt(m.height)) * k * self.zoom });
}

/// Screen centres of the turn handles over selected object `i`: left turns it
/// counter-clockwise on screen (−45°), right clockwise (+45°); null — not a prop.
pub fn turnHandles(self: *const Doc, rect: c.SDL_FRect, i: usize) ?[2][2]f32 {
    if (self.facing(i) == null) return null;
    const q = self.toScreen(rect, self.objects.items[i].pos);
    return .{ .{ q[0] - 16, q[1] - 24 }, .{ q[0] + 16, q[1] - 24 } };
}

/// The map icons as textures (embedded PNGs), smooth when scaled and turned.
pub fn icon(self: *Doc, r: *c.SDL_Renderer, k: usize) ?*c.SDL_Texture {
    if (self.icons == null) {
        const pngs = [3][]const u8{ @embedFile("icon_facing"), @embedFile("icon_turn_ccw"), @embedFile("icon_turn_cw") };
        var ts: [3]*c.SDL_Texture = undefined;
        for (pngs, 0..) |png, n| {
            var img = og.formats.jpeg.decode(self.gpa, png) catch return null;
            defer img.deinit(self.gpa);
            ts[n] = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, @intCast(img.width), @intCast(img.height)) orelse return null;
            _ = c.SDL_UpdateTexture(ts[n], null, img.pixels.ptr, @intCast(img.width * 4));
            _ = c.SDL_SetTextureBlendMode(ts[n], c.SDL_BLENDMODE_BLEND);
            _ = c.SDL_SetTextureScaleMode(ts[n], c.SDL_SCALEMODE_LINEAR);
        }
        self.icons = ts;
    }
    return self.icons.?[k];
}

/// A turn handle: the icon on its disc, 24 points across.
pub fn drawTurn(self: *Doc, r: *c.SDL_Renderer, p: [2]f32, clockwise: bool) void {
    const t = self.icon(r, if (clockwise) 2 else 1) orelse return;
    _ = c.SDL_RenderTexture(r, t, null, &.{ .x = p[0] - 12, .y = p[1] - 12, .w = 24, .h = 24 });
}

/// Which way the object at grid point `g` faces at `deg`: a thin shaft and the
/// arrowhead, in its kind's colour `col`, about a tile out (the actor angle,
/// world (cos, sin); the model turns its front along it).
pub fn drawFacing(self: *Doc, r: *c.SDL_Renderer, rect: c.SDL_FRect, cm: lf.CombatMap, g: [2]f32, deg: f32, col: [3]u8) void {
    const p0 = cm.toWorld(g[0], g[1]);
    const one = cm.toWorld(g[0] + 1, g[1]);
    const len = @sqrt((one[0] - p0[0]) * (one[0] - p0[0]) + (one[1] - p0[1]) * (one[1] - p0[1]));
    const rad = deg * std.math.pi / 180.0;
    const tip = self.world.cam.project(.{ p0[0] + @cos(rad) * len * 1.1, p0[1] + @sin(rad) * len * 1.1, p0[2] });
    const base = self.world.cam.project(p0);
    const a = self.toScreen(rect, .{ base.x, base.y });
    const b = self.toScreen(rect, .{ tip.x, tip.y });
    _ = c.SDL_SetRenderDrawColor(r, col[0], col[1], col[2], 160);
    _ = c.SDL_RenderLine(r, a[0], a[1], b[0], b[1]);
    const t = self.icon(r, 0) orelse return;
    _ = c.SDL_SetTextureColorMod(t, col[0], col[1], col[2]);
    // The icon points up: turned by the screen angle plus a quarter.
    const ang = std.math.atan2(b[1] - a[1], b[0] - a[0]) * 180.0 / std.math.pi + 90;
    _ = c.SDL_RenderTextureRotated(r, t, null, &.{ .x = b[0] - 9, .y = b[1] - 9, .w = 18, .h = 18 }, ang, null, c.SDL_FLIP_NONE);
}

/// AIEnemyAppear: a line from the tile it walks in from to the one it stops on.
pub fn drawEntry(self: *const Doc, r: *c.SDL_Renderer, rect: c.SDL_FRect, cm: lf.CombatMap, call: placement.Call, size: u32, col: [3]u8) void {
    var p: [2][2]f32 = undefined;
    for (0..2) |k| {
        const t: [2]i32 = .{ @intFromFloat(call.arg(self.text(), 2 * k).?), @intFromFloat(call.arg(self.text(), 2 * k + 1).?) };
        const q = self.world.cam.project(cm.tileCenter(t, size));
        p[k] = self.toScreen(rect, .{ q.x, q.y });
    }
    _ = c.SDL_SetRenderDrawColor(r, col[0], col[1], col[2], 200);
    _ = c.SDL_RenderLine(r, p[0][0], p[0][1], p[1][0], p[1][1]);
    _ = c.SDL_RenderRect(r, &.{ .x = p[0][0] - 4, .y = p[0][1] - 4, .w = 8, .h = 8 });
}

pub fn corner(self: *const Doc, rect: c.SDL_FRect, cm: lf.CombatMap, gx: f32, gy: f32) c.SDL_FPoint {
    const q = self.world.cam.project(cm.toWorld(gx, gy));
    const s = self.toScreen(rect, .{ q.x, q.y });
    return .{ .x = s[0], .y = s[1] };
}

pub fn quad(r: *c.SDL_Renderer, p: [4]c.SDL_FPoint, rgba: [4]u8) void {
    var v: [4]c.SDL_Vertex = undefined;
    const col: c.SDL_FColor = .{ .r = @as(f32, @floatFromInt(rgba[0])) / 255, .g = @as(f32, @floatFromInt(rgba[1])) / 255, .b = @as(f32, @floatFromInt(rgba[2])) / 255, .a = @as(f32, @floatFromInt(rgba[3])) / 255 };
    for (&v, p) |*vert, pt| vert.* = .{ .position = pt, .color = col, .tex_coord = .{ .x = 0, .y = 0 } };
    const idx = [6]c_int{ 0, 1, 2, 0, 2, 3 };
    _ = c.SDL_RenderGeometry(r, null, &v, 4, &idx, 6);
}

pub fn fillTiles(self: *const Doc, r: *c.SDL_Renderer, rect: c.SDL_FRect, cm: lf.CombatMap, t: [2]i32, size: u32, rgba: [4]u8) void {
    const x0: f32 = @floatFromInt(t[0]);
    const y0: f32 = @floatFromInt(t[1]);
    const n: f32 = @floatFromInt(size);
    quad(r, .{ self.corner(rect, cm, x0, y0), self.corner(rect, cm, x0 + n, y0), self.corner(rect, cm, x0 + n, y0 + n), self.corner(rect, cm, x0, y0 + n) }, rgba);
}

pub fn drawGridOnly(self: *const Doc, r: *c.SDL_Renderer, font: *const Font, rect: c.SDL_FRect, cm: lf.CombatMap) void {
    self.drawGrid(r, font, rect, cm);
}

pub fn drawGrid(self: *const Doc, r: *c.SDL_Renderer, font: *const Font, rect: c.SDL_FRect, cm: lf.CombatMap) void {
    for (0..cm.height) |y| for (0..cm.width) |x| {
        const blocked = cm.blocked[y * cm.width + x];
        self.fillTiles(r, rect, cm, .{ @intCast(x), @intCast(y) }, 1, if (blocked) .{ 255, 60, 60, 45 } else .{ 60, 255, 120, 30 });
    };
    _ = c.SDL_SetRenderDrawColor(r, 255, 255, 255, 50);
    for (0..cm.width + 1) |x| {
        const a = self.corner(rect, cm, @floatFromInt(x), 0);
        const b = self.corner(rect, cm, @floatFromInt(x), @floatFromInt(cm.height));
        _ = c.SDL_RenderLine(r, a.x, a.y, b.x, b.y);
    }
    for (0..cm.height + 1) |y| {
        const a = self.corner(rect, cm, 0, @floatFromInt(y));
        const b = self.corner(rect, cm, @floatFromInt(cm.width), @floatFromInt(y));
        _ = c.SDL_RenderLine(r, a.x, a.y, b.x, b.y);
    }
    // Tile numbers (as in the scripts' x, y; x yellow, y cyan) outside both edges: one
    // side may be off screen.
    const w: f32 = @floatFromInt(cm.width);
    const h: f32 = @floatFromInt(cm.height);
    for (0..cm.width) |x| for ([_]f32{ -0.5, h + 0.5 }) |gy| self.gridNumber(r, font, rect, cm, x, .{ @as(f32, @floatFromInt(x)) + 0.5, gy }, .{ 255, 215, 90, 255 });
    for (0..cm.height) |y| for ([_]f32{ -0.5, w + 0.5 }) |gx| self.gridNumber(r, font, rect, cm, y, .{ gx, @as(f32, @floatFromInt(y)) + 0.5 }, .{ 110, 220, 255, 255 });
}

pub fn gridNumber(self: *const Doc, r: *c.SDL_Renderer, font: *const Font, rect: c.SDL_FRect, cm: lf.CombatMap, n: usize, g: [2]f32, col: [4]u8) void {
    var buf: [8]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    const p = self.corner(rect, cm, g[0], g[1]);
    const sz = font.measure(s, 0, 12);
    _ = c.SDL_SetRenderDrawColor(r, 0, 0, 0, 150);
    _ = c.SDL_RenderFillRect(r, &.{ .x = p.x - sz[0] / 2 - 3, .y = p.y - 9, .w = sz[0] + 6, .h = 18 });
    font.draw(r, s, 0, 12, p.x - sz[0] / 2, p.y - 9, col);
}

//! Viewer debugging (not in the exe): .wm/.wm2 grids, areas and paths, area action
//! menu outside the game, hero placement, door impulse.

const std = @import("std");
const level = @import("../level.zig");
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");
const LevelView = level.LevelView;
const World = og.state.world.World;
const Allocator = std.mem.Allocator;
const Image = og.formats.image.Image;
const lf = og.formats.level_files;

/// Debug: places unplaced heroes near the screen centre.
pub fn placeHeroes(l: *LevelView, scroll: [2]f32) void {
    var i: f32 = 0;
    for (l.world.rt.objects.items) |o| {
        const n = World.nativeOf(o);
        if (n.kind != .actor or n.actor.placed or !o.enabled) continue;
        const p = l.world.cam.unproject(scroll[0] + 280 + i * 40, scroll[1] + 300 + i * 10, 0);
        og.fields.setPos(o, p);
        og.fields.setAngle(o, 0.8);
        n.actor.placed = true;
        i += 1;
    }
}

/// Debug: ABA_Impulse on all doors and other ActiveBitmapAnimations.
pub fn impulseAll(l: *LevelView) void {
    for (l.world.rt.objects.items) |o| {
        if (World.nativeOf(o).kind == .active_animation) og.world.bitmap_anim.impulse(o, 0);
    }
}

pub fn cycleWalkLayer(l: *LevelView) void {
    // Battle level (no .wm): the whole `.cm` grid.
    if (l.walk_textures[0] == null and l.walk_textures[1] == null and l.world.combat_map != null) {
        l.show_grid = !l.show_grid;
        return;
    }
    l.walk_layer = switch (l.walk_layer) {
        0 => if (l.walk_textures[0] != null) 1 else if (l.walk_textures[1] != null) 2 else 0,
        1 => if (l.walk_textures[1] != null) 2 else 0,
        else => 0,
    };
}

pub fn drawActionMenu(l: *LevelView, r: *c.SDL_Renderer, scroll: [2]f32, mouse: [2]f32) !void {
    const m = l.action_menu orelse return;
    const hv = m.hit(.{ mouse[0] + scroll[0], mouse[1] + scroll[1] });
    var buf: [32]u8 = undefined;
    for (0..m.len) |k| {
        var rc = m.rect(k);
        rc.x -= scroll[0];
        rc.y -= scroll[1];
        if (hv == k) try gfx.check(c.SDL_SetRenderDrawColor(r, 90, 70, 30, 230)) else try gfx.check(c.SDL_SetRenderDrawColor(r, 20, 18, 14, 220));
        try gfx.check(c.SDL_RenderFillRect(r, &rc));
        try gfx.check(c.SDL_SetRenderDrawColor(r, 255, 220, 150, 255));
        const label = std.fmt.bufPrintSentinel(&buf, "{s}", .{m.items[k].name}, 0) catch continue;
        try gfx.check(c.SDL_RenderDebugText(r, rc.x + 4, rc.y + 3, label));
    }
}

/// Grid cell colours by `kind` bits: `.ap` path ends (bits 1, 2) magenta,
/// walkable (bit 0) green.
pub fn walkMapTexture(gpa: Allocator, r: *c.SDL_Renderer, m: lf.WalkMap) !*c.SDL_Texture {
    var img = try Image.init(gpa, m.width, m.height);
    defer img.deinit(gpa);
    for (m.cells, 0..) |cell, i| {
        const px: [4]u8 = if (cell.kind & 6 != 0)
            .{ 255, 60, 220, 200 }
        else if (cell.walkable())
            .{ 40, 255, 80, 70 }
        else
            .{ 0, 0, 0, 0 };
        img.pixels[i * 4 ..][0..4].* = px;
    }
    return gfx.textureFromImage(r, img);
}

fn drawAreas(r: *c.SDL_Renderer, areas: []const lf.Area, scroll: [2]f32) !void {
    var pts: [64]c.SDL_FPoint = undefined;
    for (areas) |a| {
        const n = @min(a.points.len, pts.len - 1);
        for (a.points[0..n], pts[0..n]) |p, *q| q.* = .{ .x = p[0] - scroll[0], .y = p[1] - scroll[1] };
        pts[n] = pts[0];
        try gfx.check(c.SDL_SetRenderDrawColor(r, 255, 200, 40, 255));
        try gfx.check(c.SDL_RenderLines(r, &pts, @intCast(n + 1)));
        try gfx.check(c.SDL_RenderFillRect(r, &.{ .x = a.control[0] - scroll[0] - 2, .y = a.control[1] - scroll[1] - 2, .w = 5, .h = 5 }));
        var buf: [128]u8 = undefined;
        const label = std.fmt.bufPrintSentinel(&buf, "{s}", .{a.name}, 0) catch continue;
        try gfx.check(c.SDL_RenderDebugText(r, pts[0].x + 2, pts[0].y + 2, label));
    }
}

fn drawPaths(r: *c.SDL_Renderer, paths: []const lf.Path, scroll: [2]f32) !void {
    var pts: [64]c.SDL_FPoint = undefined;
    for (paths) |p| {
        const n = @min(p.points.len, pts.len);
        for (p.points[0..n], pts[0..n]) |pt, *q| q.* = .{ .x = pt[0] - scroll[0], .y = pt[1] - scroll[1] };
        try gfx.check(c.SDL_SetRenderDrawColor(r, 80, 220, 255, 255));
        try gfx.check(c.SDL_RenderLines(r, &pts, @intCast(n)));
        for (pts[0..n]) |q| try gfx.check(c.SDL_RenderFillRect(r, &.{ .x = q.x - 2, .y = q.y - 2, .w = 5, .h = 5 }));
        var buf: [128]u8 = undefined;
        const label = std.fmt.bufPrintSentinel(&buf, "{s}", .{p.name}, 0) catch continue;
        try gfx.check(c.SDL_RenderDebugText(r, pts[0].x + 4, pts[0].y - 10, label));
    }
}

/// .wm/.wm2 grid (M) and areas with paths (R) over the background.
pub fn drawLayers(l: *LevelView, r: *c.SDL_Renderer, scroll: [2]f32) !void {
    if (l.walk_layer != 0) {
        if (l.walk_textures[l.walk_layer - 1]) |tex| {
            const m = (if (l.walk_layer == 1) l.world.walk_map else l.world.walk_map2).?;
            const cs: f32 = lf.WalkMap.cell_size;
            const dst: c.SDL_FRect = .{
                .x = -scroll[0],
                .y = -scroll[1],
                .w = og.num.toF32(m.width) * cs,
                .h = og.num.toF32(m.height) * cs,
            };
            try gfx.check(c.SDL_RenderTexture(r, tex, null, &dst));
        }
    }
    if (l.show_areas) {
        try drawPaths(r, l.world.paths, scroll);
        try drawAreas(r, l.world.areas, scroll);
    }
}

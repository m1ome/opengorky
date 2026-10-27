//! Battle grid on Tab (0x4b4aa0, wave 0x495f80, draw 0x496140) and the debug `.cm`
//! grid (M).

const level_view = @import("../level.zig");
const LevelView = level_view.LevelView;
const lf = og.formats.level_files;
const c = @import("sdl");
const og = @import("opengorky");
const gfx = @import("../media/gfx.zig");
const battle_view = @import("view.zig");

/// Tab in battle (0x4b4aa0, key 0x12 = DIK_TAB): the grid appears as a wave; a
/// second press fades it; a press while fading turns it on again.
pub fn toggleGrid(self: *LevelView) void {
    if (self.world.combat_map == null) return;
    level_view.grid_wave = 0;
    level_view.grid_mode = if (level_view.grid_mode == 1) 2 else 1;
}

/// Grid wave step (0x495f80), once per tick: the budget grows by 4 up to 80; while
/// appearing, each not-yet-full edge (in list order) spends 0.25 and gains 1
/// brightness (up to 16); while fading, edges dim from the list end; all dark —
/// grid off.
fn gridStep(edges: []lf.CombatMap.GridEdge) void {
    if (level_view.grid_mode == 0) return;
    if (level_view.grid_wave < 80) level_view.grid_wave += 4;
    var left: f64 = @floatFromInt(level_view.grid_wave);
    if (level_view.grid_mode == 1) {
        for (edges) |*e| {
            if (e.level >= 16) continue;
            left -= 0.25;
            if (left <= 0) break;
            e.level += 1;
        }
        return;
    }
    var dimmed = false;
    var i = edges.len;
    while (i > 0) {
        i -= 1;
        const e = &edges[i];
        if (e.level <= 0) continue;
        left -= 0.25;
        if (left <= 0) break;
        e.level -= 1;
        dimmed = true;
    }
    if (!dimmed) level_view.grid_mode = 0;
}

/// Battle grid (0x496140, after the scene 0x420979): each edge with brightness > 0
/// is a strip 2·grid_width·xSize (0.2) wide along the cell line with pointed ends
/// (0x495a30: six vertices, u 0 → 0.5 → 1 across, four triangles), texture
/// combatGrid.3df, colour grid_color (32,48,32) × brightness/16, additive
/// (level.grid_mode 0 → mode 1). The exe depth-tests the strip (0x408930(1)) so it
/// hides behind the foreground; ours draws under actors like the tile highlight.
pub fn drawGrid(self: *LevelView, r: *c.SDL_Renderer, scroll: [2]f32) !void {
    const cm = self.world.combat_map orelse return;
    if (self.grid_edges_of != cm.blocked.ptr) {
        if (self.grid_edges.len > 0) self.gpa.free(self.grid_edges);
        self.grid_edges = &.{};
        self.grid_edges = try cm.gridEdges(self.gpa);
        self.grid_edges_of = cm.blocked.ptr;
        self.grid_tick = self.world.ticks;
    }
    const now = self.world.ticks;
    var steps = now -| self.grid_tick;
    self.grid_tick = now;
    if (steps > 200) steps = 200;
    while (steps > 0) : (steps -= 1) gridStep(self.grid_edges);
    if (level_view.grid_mode == 0) return;
    const v = self.fx_view orelse return;
    const tex = v.namedTexture("combatGrid.3df") orelse return;
    _ = c.SDL_SetTextureBlendMode(tex, v.modes[1]);
    const wx = og.formats.adjust.getFloat("grid_width", 0.2);
    const wy = wx * cm.cell_size[0] / cm.cell_size[1];
    const gc = og.formats.adjust.getRgb("grid_color", .{ 32, 48, 32 });
    const color = [3]f32{ @floatFromInt(gc[0]), @floatFromInt(gc[1]), @floatFromInt(gc[2]) };
    for (self.grid_edges) |e| {
        if (e.level <= 0) continue;
        var rgb: [3]f32 = undefined;
        for (color, &rgb) |k, *o| o.* = @trunc(k * og.num.toF32(e.level) * 0.0625) / 255.0;
        const x0: f32 = @floatFromInt(e.x);
        const y0: f32 = @floatFromInt(e.y);
        const x1 = x0 + 1;
        const y1 = y0 + 1;
        // Vertices of 0x495a30 per side (grid in cells, z = centerZ).
        const p: [6][2]f32 = switch (e.side) {
            1, 3 => blk: {
                const y = if (e.side == 1) y0 else y1;
                break :blk .{ .{ x0, y }, .{ x0 + wx, y - wy }, .{ x1 - wx, y - wy }, .{ x1, y }, .{ x1 - wx, y + wy }, .{ x0 + wx, y + wy } };
            },
            else => blk: {
                const x = if (e.side == 2) x1 else x0;
                break :blk .{ .{ x, y0 }, .{ x + wx, y0 + wy }, .{ x + wx, y1 - wy }, .{ x, y1 }, .{ x - wx, y1 - wy }, .{ x - wx, y0 + wy } };
            },
        };
        const uv = [6][2]f32{ .{ 0.5, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0.5, 1 }, .{ 0, 1 }, .{ 0, 0 } };
        var vert: [6]c.SDL_Vertex = undefined;
        for (p, uv, &vert) |gp, tc, *vv| {
            const q = self.world.cam.project(cm.toWorld(gp[0], gp[1]));
            vv.* = .{
                .position = .{ .x = q.x - scroll[0], .y = q.y - scroll[1] },
                .color = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 1 },
                .tex_coord = .{ .x = tc[0], .y = tc[1] },
            };
        }
        const idx = [12]c_int{ 0, 1, 3, 1, 2, 3, 3, 4, 5, 0, 3, 5 };
        try gfx.check(c.SDL_RenderGeometry(r, tex, &vert, 6, &idx, 12));
    }
}

/// Debug (`M` in battle): the whole `.cm` grid — free cells green, occupied red.
pub fn drawCombatGrid(self: *LevelView, r: *c.SDL_Renderer, scroll: [2]f32) !void {
    if (!self.show_grid) return;
    const cm = self.world.combat_map orelse return;
    for (0..cm.height) |y| for (0..cm.width) |x| {
        const blocked = cm.blocked[y * cm.width + x];
        const rgba: [4]f32 = if (blocked) .{ 1, 0.2, 0.2, 0.3 } else .{ 0.2, 1, 0.3, 0.25 };
        try battle_view.fillTile(self, r, cm, scroll, .{ @intCast(x), @intCast(y) }, rgba);
    };
}

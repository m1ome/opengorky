//! Battle on the field: move and attack cells, cell frame under the cursor, selected hero marker, facing arrows. Tab grid: battle/grid.zig; fighter info and bars: battle/hud.zig.

const std = @import("std");
const control_mod = og.combat.control;
const level_view = @import("../level.zig");
const LevelView = level_view.LevelView;
const lf = og.formats.level_files;
const battle_mod = og.battle.battle;
const c = @import("sdl");
const og = @import("opengorky");
const World = og.state.world.World;
const gfx = @import("../media/gfx.zig");

/// Grid floor point for cell highlights: in `04__city_hotelentrance` the highlight
/// floor is 30 lower (0x454e6e: [0x651ca0] = −30, 0x47d0e0, 0x47cf70).
pub fn gridPoint(self: *LevelView, cm: lf.CombatMap, gx: f32, gy: f32) [3]f32 {
    var p = cm.toWorld(gx, gy);
    if (std.ascii.eqlIgnoreCase(self.world.level_name, "04__city_hotelentrance")) p[2] -= 30;
    return p;
}
/// Battle grid cell under a background point (ray onto the grid floor).
pub fn tileAt(self: *LevelView, bg: [2]f32) ?og.battle.grid.Tile {
    const cm = self.world.combat_map orelse return null;
    const h = switch (self.world.cam) {
        .persp => |pc| cm.center[2] - pc.zlevel / pc.scale,
        .ortho => cm.center[2],
    };
    const p = self.world.cam.unproject(bg[0], bg[1], h);
    const t = cm.tileOf(p, 1);
    if (t[0] < 0 or t[1] < 0 or t[0] >= cm.width or t[1] >= cm.height) return null;
    return t;
}
/// Battle cells under actors (0x455720, aim mode 0x4527d0): whole-cell fill without
/// depth, alpha pulsing 0.2…0.4 (tile_flash_*, 0x45c8a0).
/// Normal mode: the selected hero's moves or (after 15 hover ticks) the full move of
/// the hovered enemy in green (cftPlayer/EnemyWalkRange 20,140,50); the hovered
/// fighter's cells in blue (cftFighterArea 50,50,178); the frame of the cell under
/// the cursor (cftFreeTileFrame 255,128,0); sel.3df marker under the selected hero
/// (cftSelectedTileFX 130,55,20, additive). Aim mode: all attack cells red
/// (cftAttackRange 210,76,76) with alpha pct·pulse, hit cells at the cursor yellow
/// (cftEffectRange 210,210,0), no moves.
pub fn drawBattleTiles(self: *LevelView, r: *c.SDL_Renderer, scroll: [2]f32, mouse_bg: [2]f32) !void {
    const b = &(self.world.battle orelse return);
    const cm = self.world.combat_map orelse return;
    const grid = og.battle.grid;
    const ticks = self.world.ticks;
    // The exe doesn't fill fire and gas cells: fire is the "flame" (0x4a66a0), gas
    // the "gas2" cloud (0x4a95d0), both in level_effects.
    const pulse = gfx.tilePulse(gfx.tileFlashStep() * og.num.toF32(ticks));
    const cursor = if (self.window_top) null else tileAt(self, mouse_bg);
    // Hovered fighter: alive, visible, not an invisible monster.
    var hv: ?u16 = null;
    if (cursor) |t| {
        const o = b.grid().at(t);
        if (o != grid.Grid.none) {
            const f = b.fighters.items[o];
            const nat = World.nativeOf(f.obj);
            if (f.alive() and f.side != .neutral and !og.fields.isInvisibleMonster(f.obj) and nat.actor.alpha != 0) hv = o;
        }
    }
    if (hv != self.hover) {
        self.hover = hv;
        self.hover_since = ticks;
        self.enemy_reach_for = null;
    }
    self.hover_ticks = ticks -% self.hover_since;
    const turn = (b.phase == .player or b.phase == .counter) and b.idle() and !self.window_top;
    const me = b.current();
    const can_act = turn and me != null and me.?.alive() and (b.phase == .counter or (!me.?.acted and !me.?.disabled()));
    // Aim mode (0x452660): an attack started (0x47c120 → 0, a miss too) exits via
    // 0x452a00; refusals "Recharging"/"No ammo" (2) and "Out of range" (3) keep it.
    if (!can_act) self.world.mouse.aim = false;
    // A counterattack is always aim mode (0x45bd70 → 0x4524d0).
    if (b.phase == .counter and can_act) self.world.mouse.aim = true;
    // Hero facing choice (0x453380): arrows on neighbour cells.
    if (turn and b.facing_mode) try drawFacingArrows(self, r, cm, scroll, b);
    // Cross (0x4559a0): the hero's cell and its four side neighbours, walkable only,
    // pulsing colour.
    if (turn and self.cross_mode) if (me) |f| {
        const offs = [_][2]i32{ .{ 0, 0 }, .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } };
        for (offs) |d| {
            const t: og.battle.grid.Tile = .{ f.tile[0] + d[0], f.tile[1] + d[1] };
            if (t[0] < 0 or t[1] < 0 or t[0] >= cm.width or t[1] >= cm.height) continue;
            if (cm.blocked[og.battle.grid.tileIndex(cm.width, t)]) continue;
            try fillTile(self, r, cm, scroll, t, rgbA(gfx.adjRgb("cftTilePGCross", .{ 178, 178, 50 }), pulse));
        }
    };
    if (turn and !self.world.mouse.aim and !b.facing_mode and !self.cross_mode) {
        // Each reachable cell paints the fighter's whole footprint (size×size, 0x49ac20).
        var shown = false;
        if (self.hover) |k| if (self.hover_ticks > 15 and b.fighters.items[k].side == .enemy) {
            if (enemyReach(self, b, k)) |reach| {
                try fillReach(self, r, cm, scroll, b, reach, b.fighters.items[k].size, rgbA(gfx.adjRgb("cftEnemyWalkRange", .{ 20, 140, 50 }), pulse));
                shown = true;
            }
        };
        if (!shown) if (me) |f| try fillReach(self, r, cm, scroll, b, b.reach_left, f.size, rgbA(gfx.adjRgb("cftPlayerWalkRange", .{ 20, 140, 50 }), pulse));
    }
    if (turn and self.world.mouse.aim) {
        for (control_mod.targetList(b)) |aim| {
            try fillTile(self, r, cm, scroll, aim.tile, rgbA(gfx.adjRgb("cftAttackRange", .{ 210, 76, 76 }), og.num.toF32(aim.pct) * 0.01 * pulse));
        }
        if (cursor) |t| if (me) |f| if (f.weapon) |wpn| {
            for (control_mod.targetList(b)) |aim| if (aim.tile[0] == t[0] and aim.tile[1] == t[1]) {
                try fillEffect(self, r, cm, scroll, b, wpn, aim, pulse);
                break;
            };
        };
    }
    // Enemy turn (0x497f60): alpha = pulse + 0.1; moves (cftAiWalkRange) while walking;
    // attack cells (cftAiAttackRange 210,76,76) and the enemy's own (cftAiCharacterRange
    // 50,50,178); then the hit cells (cftAiEffectRange 210,210,0).
    if (b.phase == .enemy) if (b.ai_show) |sh| {
        const a = pulse + 0.1;
        const f = b.fighters.items[sh.who];
        switch (sh.stage) {
            .walk => try fillReach(self, r, cm, scroll, b, b.ai_reach, f.size, rgbA(gfx.adjRgb("cftAiWalkRange", .{ 20, 140, 50 }), a)),
            .area, .effect => {
                for (og.combat.ai_turn.aiTargets(b)) |aim| try fillTile(self, r, cm, scroll, aim.tile, rgbA(gfx.adjRgb("cftAiAttackRange", .{ 210, 76, 76 }), a));
                try fillFootprint(self, r, cm, scroll, f, a);
                if (sh.stage == .effect) if (b.ai_plan.weapon) |wpn| try fillEffect(self, r, cm, scroll, b, wpn, b.ai_plan.aim, a);
            },
        }
    };
    // Hovered fighter's cells.
    if (self.hover) |k| try fillFootprint(self, r, cm, scroll, b.fighters.items[k], pulse);
    // Frame of the cell under the cursor, on walkable `.cm` cells.
    if (cursor) |t| if (!cm.blocked[og.battle.grid.tileIndex(cm.width, t)]) {
        try frameTile(self, r, cm, scroll, t, rgbA(gfx.adjRgb("cftFreeTileFrame", .{ 255, 128, 0 }), 1));
    };
    // Selected hero marker (0x47d9a0, 0x47de60): two "snakes" of sel.3df sparks
    // run around the hero's cell.
    if (turn) if (me) |f| if (f.alive()) try selSnakes(self, cm, scroll, f.tile);
}
fn rgbA(rgb: [3]f32, a: f32) [4]f32 {
    return .{ rgb[0], rgb[1], rgb[2], a };
}
/// Fighter cells (size×size) in blue.
fn fillFootprint(self: *LevelView, r: *c.SDL_Renderer, cm: lf.CombatMap, scroll: [2]f32, f: og.battle.fighter.Fighter, a: f32) !void {
    for (0..f.size) |dy| for (0..f.size) |dx| {
        try fillTile(self, r, cm, scroll, .{ f.tile[0] + @as(i32, @intCast(dx)), f.tile[1] + @as(i32, @intCast(dy)) }, rgbA(gfx.adjRgb("cftFighterArea", .{ 50, 50, 178 }), a));
    };
}
/// Hit cells of weapon `wpn` at aim `aim` in yellow.
fn fillEffect(self: *LevelView, r: *c.SDL_Renderer, cm: lf.CombatMap, scroll: [2]f32, b: *battle_mod.Battle, wpn: *og.script.object.Object, aim: og.battle.grid.Target, a: f32) !void {
    const pat = og.battle.weapon_class.pattern(wpn) orelse return;
    var buf: [128]og.battle.grid.Tile = undefined;
    for (og.battle.grid.effectTiles(b.grid(), pat, aim, &buf)) |et| try fillTile(self, r, cm, scroll, et, rgbA(gfx.adjRgb("cftEffectRange", .{ 210, 210, 0 }), a));
}
/// Reach fill: a size×size footprint at each cell with remaining ≥ 0, no cell
/// filled twice.
fn fillReach(self: *LevelView, r: *c.SDL_Renderer, cm: lf.CombatMap, scroll: [2]f32, b: *battle_mod.Battle, reach: []const f32, fsize: u32, rgba: [4]f32) !void {
    const n = @as(usize, b.width) * b.height;
    const mask = try self.frame_arena.allocator().alloc(bool, n);
    @memset(mask, false);
    for (0..b.height) |y| for (0..b.width) |x| {
        if (reach[y * b.width + x] < 0) continue;
        for (0..fsize) |dy| for (0..fsize) |dx| {
            const xx = x + dx;
            const yy = y + dy;
            if (xx < b.width and yy < b.height) mask[yy * b.width + xx] = true;
        };
    };
    for (0..b.height) |y| for (0..b.width) |x| {
        if (mask[y * b.width + x]) try fillTile(self, r, cm, scroll, .{ @intCast(x), @intCast(y) }, rgba);
    };
}
/// Full move of enemy `k` (cached until the hover changes); an immobile one
/// (moveLock, frozen, asleep) shows only its footprint.
fn enemyReach(self: *LevelView, b: *battle_mod.Battle, k: u16) ?[]const f32 {
    const n = @as(usize, b.width) * b.height;
    if (self.enemy_reach.len != n) {
        if (self.enemy_reach.len > 0) self.gpa.free(self.enemy_reach);
        self.enemy_reach = self.gpa.alloc(f32, n) catch return null;
        self.enemy_reach_for = null;
    }
    if (self.enemy_reach_for != k) {
        const f = b.fighters.items[k];
        const stuck = og.fields.moveLock(f.obj) or f.disabled();
        og.battle.grid.reachCost(b.grid(), self.enemy_reach, f.tile, f.size, k, if (stuck) 0 else @floatFromInt(og.fields.walkRange(f.obj)), og.battle.grid.diagonal_cost_ai);
        self.enemy_reach_for = k;
    }
    return self.enemy_reach;
}
fn tileCorners(self: *LevelView, cm: lf.CombatMap, scroll: [2]f32, t: og.battle.grid.Tile) [4]c.SDL_FPoint {
    var out: [4]c.SDL_FPoint = undefined;
    const corners = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
    for (corners, &out) |k, *o| {
        const fx = og.num.toF32(t[0]) + k[0];
        const fy = og.num.toF32(t[1]) + k[1];
        const q = self.world.cam.project(gridPoint(self, cm, fx, fy));
        o.* = .{ .x = q.x - scroll[0], .y = q.y - scroll[1] };
    }
    return out;
}
/// Cell frame (0x47cf70): four lines at the cell corners on the grid floor. The exe
/// uses Direct3D lines; ours are antialiased, because the near-vertical edges of
/// the trapezoid under the tilted camera otherwise step per pixel and the frame
/// looks crooked after the 640×480 upscale.
fn frameTile(self: *LevelView, r: *c.SDL_Renderer, cm: lf.CombatMap, scroll: [2]f32, t: og.battle.grid.Tile, rgba: [4]f32) !void {
    const p = tileCorners(self, cm, scroll, t);
    for (0..4) |i| try smoothLine(r, p[i], p[(i + 1) % 4], rgba);
}
/// Selected hero marker (0x47d9a0 — positions each tick from 0x454e0c, 0x47de60 —
/// draw): two "snakes" of 25 sparks run around the hero's cell (start cell only,
/// ignoring size), the second from the opposite corner. Spark k (1…25) leads the
/// first by (k − 1) steps of 0.08 edge per tick (an edge is 12.5 ticks), size
/// 0.12·k(k − 1)/2 (the head is larger than the tail). Each is mesh kwadrat with
/// sel.3df (0x4c7c30), scale aS·size, colour cftSelectedTileFX (130,55,20)/255,
/// additive, no depth.
fn selSnakes(self: *LevelView, cm: lf.CombatMap, scroll: [2]f32, t: og.battle.grid.Tile) !void {
    const v = self.fx_view orelse return;
    const fx: f32 = @floatFromInt(t[0]);
    const fy: f32 = @floatFromInt(t[1]);
    const corners = [4][3]f32{
        cm.toWorld(fx, fy),
        cm.toWorld(fx + 1, fy),
        cm.toWorld(fx + 1, fy + 1),
        cm.toWorld(fx, fy + 1),
    };
    const as = self.world.actorScale();
    const ticks: f32 = @floatFromInt(self.world.ticks);
    const col = rgbA(gfx.adjRgb("cftSelectedTileFX", .{ 130, 55, 20 }), 1);
    for ([_]f32{ 0, 2 }) |start_edge| for (1..26) |k| {
        const kf: f32 = @floatFromInt(k);
        const p = (ticks + kf - 1) * 0.08 + start_edge;
        const e: usize = @intFromFloat(@mod(@floor(p), 4));
        const frac = p - @floor(p);
        const a = corners[e];
        const b = corners[(e + 1) % 4];
        const pos = [3]f32{ a[0] + (b[0] - a[0]) * frac, a[1] + (b[1] - a[1]) * frac, a[2] + (b[2] - a[2]) * frac };
        const dot = 0.12 * kf * (kf - 1) / 2;
        if (dot <= 0) continue;
        try v.drawMeshTexAdd(.{ .arena = self.frame_arena.allocator(), .cam = self.world.cam, .scroll = scroll }, "sel.3df", pos, .{ 0, 1, 0 }, as * dot, col);
    };
}
/// Facing arrows (0x453380, quad 0x453040): on each walkable cell beside the hero,
/// a quad inset s = 0.15 + 0.1·(sin φ + 1)/2 from the cell edges (φ += 1 per
/// frame), facingArrow texture pointing away from the hero, alpha blend.
fn drawFacingArrows(self: *LevelView, r: *c.SDL_Renderer, cm: lf.CombatMap, scroll: [2]f32, b: *battle_mod.Battle) !void {
    if (!self.arrow_loaded) {
        self.arrow_loaded = true;
        if (self.models) |m| if (m.readFile("gfx_3d\\textures\\facingArrow.3df")) |bytes| {
            if (og.formats.tex3df.decode(self.gpa, bytes)) |img_| {
                var img = img_;
                defer img.deinit(self.gpa);
                self.arrow_tex = gfx.textureLinear(r, img) catch null;
                if (self.arrow_tex) |tx| _ = c.SDL_SetTextureBlendMode(tx, c.SDL_BLENDMODE_BLEND);
            } else |_| {}
        } else |_| {};
    }
    const tex = self.arrow_tex orelse return;
    var cells: [4]?og.battle.grid.Tile = undefined;
    control_mod.facingCells(b, &cells);
    const s = 0.15 + 0.1 * (@sin(og.num.toF32(self.world.ticks)) + 1) * 0.5;
    const h = 0.5 - s;
    const dirs = [4][2]f32{ .{ 0, -1 }, .{ 1, 0 }, .{ 0, 1 }, .{ -1, 0 } };
    for (cells, dirs) |ct, d| {
        const t = ct orelse continue;
        const cx = og.num.toF32(t[0]) + 0.5;
        const cy = og.num.toF32(t[1]) + 0.5;
        // Texture up (v = 0) points away from the hero, u across.
        const side = [2]f32{ -d[1], d[0] };
        const uv = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
        var v: [4]c.SDL_Vertex = undefined;
        for (uv, &v) |tc, *vert| {
            const a = (tc[0] - 0.5) * 2 * h;
            const bb = (0.5 - tc[1]) * 2 * h;
            const gx = cx + side[0] * a + d[0] * bb;
            const gy = cy + side[1] * a + d[1] * bb;
            const q = self.world.cam.project(cm.toWorld(gx, gy));
            vert.* = .{
                .position = .{ .x = q.x - scroll[0], .y = q.y - scroll[1] },
                .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
                .tex_coord = .{ .x = tc[0], .y = tc[1] },
            };
        }
        const idx = [6]c_int{ 0, 1, 2, 0, 2, 3 };
        try gfx.check(c.SDL_RenderGeometry(r, tex, &v, 4, &idx, 6));
    }
}
/// Fills a whole cell (0x47d0e0).
pub fn fillTile(self: *LevelView, r: *c.SDL_Renderer, cm: lf.CombatMap, scroll: [2]f32, t: og.battle.grid.Tile, rgba: [4]f32) !void {
    var v: [4]c.SDL_Vertex = undefined;
    const corners = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
    for (corners, &v) |k, *vert| {
        const fx = og.num.toF32(t[0]) + k[0];
        const fy = og.num.toF32(t[1]) + k[1];
        const q = self.world.cam.project(gridPoint(self, cm, fx, fy));
        vert.* = .{
            .position = .{ .x = q.x - scroll[0], .y = q.y - scroll[1] },
            .color = .{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] },
            .tex_coord = .{ .x = 0, .y = 0 },
        };
    }
    const idx = [6]c_int{ 0, 1, 2, 0, 2, 3 };
    try gfx.check(c.SDL_RenderGeometry(r, null, &v, 4, &idx, 6));
}

/// Antialiased 1-px line: a strip ±1 pixel from the axis, alpha 1 on the axis to 0
/// at the edges (interpolated per vertex), ends extended by half a pixel.
fn smoothLine(r: *c.SDL_Renderer, a: c.SDL_FPoint, b: c.SDL_FPoint, rgba: [4]f32) !void {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 1e-3) return;
    const ux = dx / len * 0.5;
    const uy = dy / len * 0.5;
    const nx = -dy / len;
    const ny = dx / len;
    const p0 = c.SDL_FPoint{ .x = a.x - ux, .y = a.y - uy };
    const p1 = c.SDL_FPoint{ .x = b.x + ux, .y = b.y + uy };
    const on = c.SDL_FColor{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = rgba[3] };
    const off = c.SDL_FColor{ .r = rgba[0], .g = rgba[1], .b = rgba[2], .a = 0 };
    const v = [6]c.SDL_Vertex{
        .{ .position = .{ .x = p0.x - nx, .y = p0.y - ny }, .color = off, .tex_coord = .{ .x = 0, .y = 0 } },
        .{ .position = p0, .color = on, .tex_coord = .{ .x = 0, .y = 0 } },
        .{ .position = .{ .x = p0.x + nx, .y = p0.y + ny }, .color = off, .tex_coord = .{ .x = 0, .y = 0 } },
        .{ .position = .{ .x = p1.x - nx, .y = p1.y - ny }, .color = off, .tex_coord = .{ .x = 0, .y = 0 } },
        .{ .position = p1, .color = on, .tex_coord = .{ .x = 0, .y = 0 } },
        .{ .position = .{ .x = p1.x + nx, .y = p1.y + ny }, .color = off, .tex_coord = .{ .x = 0, .y = 0 } },
    };
    const idx = [12]c_int{ 0, 3, 4, 0, 4, 1, 1, 4, 5, 1, 5, 2 };
    try gfx.check(c.SDL_RenderGeometry(r, null, &v, 6, &idx, 12));
}

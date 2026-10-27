//! Over the battlefield: fighter info under the cursor (0x455d90), health bars,
//! damage and a status line (debug).

const std = @import("std");
const level_compose = @import("../level/compose.zig");
const gui_panel = @import("../gui/panel.zig");
const actors_view = @import("../level/actors.zig");
const gui_battle = @import("gui.zig");
const level_view = @import("../level.zig");
const LevelView = level_view.LevelView;
const c = @import("sdl");
const og = @import("opengorky");
const world_mod = og.state.world;
const World = world_mod.World;
const gfx = @import("../media/gfx.zig");
const battle_view = @import("view.zig");

/// Fighter info under the cursor (0x455d90, `FighterInfo.spr`), no backing:
/// "hp/max" in font 3 (188,206,168) at (x+2, y); bar frame 0 at (x, y+12) and fill
/// frame 1 at (x+1, y+12), width trunc(hp/max·60); name in white font 2 at (x, y+20);
/// icons from y+35, 3 per row, step 17: cell 0 armour class (9–11), then
/// resistances 1–7 (frames 2–8). x = cursor + 40, right edge ≤ 638.
pub fn drawFighterInfo(self: *LevelView, r: *c.SDL_Renderer, g: *@import("../gui.zig").Gui, bg: [2]f32, mouse: [2]f32) !void {
    const info = &g.fighter_info;
    const b = &(self.world.battle orelse return);
    const t = battle_view.tileAt(self, bg) orelse return;
    const o = b.grid().at(t);
    if (o == og.battle.grid.Grid.none) return;
    const f = b.fighters.items[o];
    // Obstacles have no info window (+0x7c = 0); invisible fighters aren't hovered.
    if (!f.alive() or info.len() < 12 or f.side == .neutral) return;
    if (world_mod.actorOf(f.obj).alpha == 0) return;
    const id = og.fields.nameId(f.obj);
    const name = self.world.stringOr(id, f.obj.name);
    const name_w: f32 = if (g.font) |f2| @floatFromInt(f2.measure(name)) else 70;
    const wdt = @max(70, name_w);
    var x = mouse[0] + 40;
    if (x + wdt > 638) x = 638 - wdt;
    const y = mouse[1];
    var buf: [32]u8 = undefined;
    const max_hp = @max(1, og.fields.maxHp(f.obj));
    const hp_s = std.fmt.bufPrint(&buf, "{d}/{d}", .{ @max(0, f.hp()), max_hp }) catch "";
    try gui_panel.label(g, r, g.sys_font orelse g.font, x + 2, y, hp_s, .{ 188, 206, 168 }, false);
    try info.draw(r, 0, x, y + 12);
    const k = std.math.clamp(og.num.toF32(f.hp()) / og.num.toF32(max_hp), 0, 1);
    try info.drawClipped(r, 1, x + 1, y + 12, @trunc(k * 60)); // _ftol (0x455e41)
    try gui_panel.label(g, r, g.font, x, y + 20, name, .{ 255, 255, 255 }, false);
    const cy0 = y + 35;
    if (f.side != .hero) if (self.world.immunity.armorClass(id)) |cls| if (self.world.immunity.isKnown(id, .armor)) {
        try info.draw(r, 9 + @as(usize, @intCast(std.math.clamp(cls, 0, 2))), x, cy0);
    };
    var slot: usize = 1;
    for (1..8) |code| {
        if (!self.world.immunity.immune(id, @fromBackingInt(@intCast(code))) or !self.world.immunity.isKnown(id, @fromBackingInt(@intCast(code)))) continue;
        const cx = x + 17 * og.num.toF32(slot % 3);
        const cy = cy0 + 17 * og.num.toF32(slot / 3);
        try info.draw(r, code + 1, cx, cy);
        slot += 1;
    }
}

/// Health bars, damage popups and the battle status line.
pub fn drawBattleHud(self: *LevelView, r: *c.SDL_Renderer, scroll: [2]f32, gui: ?*@import("../gui.zig").Gui) !void {
    const b = &(self.world.battle orelse return);
    var buf: [160]u8 = undefined;
    for (b.fighters.items) |f| {
        if (!f.alive() or f.appear_to != null or f.side == .neutral) continue;
        const tall = (actors_view.modelHeight(self, f.obj) orelse 80) + 10;
        const head = self.world.cam.project(level_view.addZ(og.fields.pos(f.obj), tall));
        const max_hp = @max(1, og.fields.maxHp(f.obj));
        const k = std.math.clamp(og.num.toF32(f.hp()) / og.num.toF32(max_hp), 0, 1);
        const x = head.x - scroll[0] - 16;
        const y = head.y - scroll[1];
        if (self.debug_hud) {
            try gfx.fillRect(r, .{ 0, 0, 0, 200 }, .{ .x = x - 1, .y = y - 1, .w = 34, .h = 5 });
            if (f.side == .hero) try gfx.check(c.SDL_SetRenderDrawColor(r, 80, 220, 90, 255)) else try gfx.check(c.SDL_SetRenderDrawColor(r, 230, 70, 50, 255));
            try gfx.check(c.SDL_RenderFillRect(r, &.{ .x = x, .y = y, .w = 32 * k, .h = 3 }));
        }
        // States (0x4dc700): string.tab 526–530 joined with " + ", colour (200,60,20).
        var st_buf: [96]u8 = undefined;
        var st_len: usize = 0;
        const parts = [_]struct { on: bool, id: i32, fb: []const u8 }{
            .{ .on = f.asleep > 0, .id = 526, .fb = "tranquilized" },
            .{ .on = f.gassed > 0, .id = 527, .fb = "poisoned" },
            .{ .on = f.bitten, .id = 528, .fb = "poisoned" },
            .{ .on = f.soaked > 0, .id = 529, .fb = "flammable" },
            .{ .on = f.enraged(), .id = 530, .fb = "enraged" },
        };
        for (parts) |pt| if (pt.on) {
            const t = self.world.stringOr(pt.id, pt.fb);
            const sep: []const u8 = if (st_len > 0) " + " else "";
            const piece = std.fmt.bufPrint(st_buf[st_len..], "{s}{s}", .{ sep, t }) catch break;
            st_len += piece.len;
        };
        if (st_len > 0) {
            // 3d_msg font, scale 0.5, additive, centred on the model's screen box
            // (+0x64…+0x70) at its top + fighter_stunned_level (0x4dcaa0).
            const sb = world_mod.actorOf(f.obj).screen_box orelse .{ head.x, head.y, head.x, head.y };
            const sx = (sb[0] + sb[2]) / 2 - scroll[0];
            const sy = sb[1] + og.num.toF32(og.formats.adjust.getInt("fighter_stunned_level", 8)) - scroll[1];
            if (gui) |g| {
                try gui_battle.msgTextBlend(g, r, st_buf[0..st_len], sx, sy, 0.5, gfx.rgb(200, 60, 20), 1, gfx.blendAdd());
            } else {
                const label = std.fmt.bufPrintSentinel(&buf, "{s}", .{st_buf[0..st_len]}, 0) catch continue;
                try gfx.check(c.SDL_SetRenderDrawColor(r, 200, 60, 20, 255));
                try gfx.check(c.SDL_RenderDebugText(r, sx - og.num.toF32(st_len) * 4, sy, label));
            }
        }
    }
    // Bomb timer (0x4bdf00): "time N" in 3d_msg font, scale 0.4, white, centred
    // at the top-left corner of the bomb's screen rect (+0x64, +0x68).
    if (gui) |g| for (b.bombs.items) |bomb| {
        const t = World.nativeOf(bomb.obj).fight.bomb_timer orelse continue;
        const box = world_mod.actorOf(bomb.obj).screen_box orelse continue;
        const label = std.fmt.bufPrint(&buf, "time {d}", .{t}) catch continue;
        try gui_battle.msgText(g, r, label, box[0] - scroll[0], box[1] - scroll[1], 0.4, .{ 1, 1, 1 }, 1);
    };
    if (gui) |g| for (b.popups.items) |*pp| try level_compose.drawPopup(self, r, g, pp, scroll);
    // Status line above the panel (debug).
    if (!self.debug_hud) return;
    const status: [:0]const u8 = switch (b.phase) {
        // SDL debug font: ASCII only.
        .appear => "Enemies appear...",
        .player => blk: {
            const f = b.current() orelse break :blk "Your turn";
            const wpn = if (f.weapon) |o| o.name else "-";
            break :blk std.fmt.bufPrintSentinel(&buf, "Turn {d}: {s} hp {d}/{d} lv{d} move {d:.1} {s}{s}{s}  [Q]weapon [X]defend [E]end", .{
                b.turn,                                                                   f.obj.name,      f.hp(), og.fields.maxHp(f.obj), f.obj.getInt("level"), @max(0, f.budget()), wpn,
                if (f.disabled()) " (frozen/asleep)" else if (f.acted) " (done)" else "", statusText(f.*),
            }, 0) catch "Your turn";
        },
        .enemy => std.fmt.bufPrintSentinel(&buf, "Turn {d}: enemies move", .{b.turn}, 0) catch "Enemies move",
        .counter => blk: {
            const f = b.current() orelse break :blk "Counterattack!";
            break :blk std.fmt.bufPrintSentinel(&buf, "COUNTERATTACK: {s} with {s} - click an enemy, [E] skip", .{ f.obj.name, if (f.weapon) |o| o.name else "-" }, 0) catch "Counterattack!";
        },
        .won => "Victory!",
        .lost => "Defeat (Backspace to leave)",
    };
    try gfx.fillRect(r, .{ 0, 0, 0, 170 }, .{ .x = 0, .y = 396, .w = 640, .h = 14 });
    try gfx.check(c.SDL_SetRenderDrawColor(r, 255, 230, 160, 255));
    try gfx.check(c.SDL_RenderDebugText(r, 4, 399, status));
}

fn statusText(f: og.battle.fighter.Fighter) []const u8 {
    if (f.burning > 0) return " [burning]";
    if (f.gassed > 0) return " [gassed]";
    if (f.soaked > 0) return " [soaked]";
    if (f.defending) return " [defending]";
    return "";
}

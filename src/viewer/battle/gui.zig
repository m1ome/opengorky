//! Battle text (3d_msg font), battle banner, game over, battle report. Gui methods (see gui.zig).

const std = @import("std");
const gui_mod = @import("../gui.zig");
const Gui = gui_mod.Gui;
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");
const monster_icons = Gui.monster_icons;

/// Text in the 3d_msg font centred at (cx, cy) with scale, colour and brightness.
/// 3d_msg glyph: its own if present (capitals), else the lowercase one.
fn msgGlyph(self: *Gui, ch: u8) ?og.formats.font.TexGlyph {
    return self.msg_glyphs[ch] orelse self.msg_glyphs[std.ascii.toLower(ch)];
}

/// Glyph page (main or the language set).
fn msgTex(self: *Gui, ch: u8) ?*c.SDL_Texture {
    const k = if (self.msg_glyphs[ch] != null) ch else std.ascii.toLower(ch);
    return self.msg_tex[self.msg_page[k]] orelse self.msg_tex[0];
}

pub fn msgText(self: *Gui, r: *c.SDL_Renderer, t: []const u8, cx: f32, cy: f32, scale: f32, rgb: [3]f32, a: f32) !void {
    return msgTextBlend(self, r, t, cx, cy, scale, rgb, a, null);
}

/// Same with a blend mode (fighter state labels are additive, 0x4dca65).
pub fn msgTextBlend(self: *Gui, r: *c.SDL_Renderer, t: []const u8, cx: f32, cy: f32, scale: f32, rgb: [3]f32, a: f32, blend: ?c.SDL_BlendMode) !void {
    if (self.msg_tex[0] == null) return;
    var mode: c.SDL_BlendMode = undefined;
    _ = c.SDL_GetTextureBlendMode(self.msg_tex[0].?, &mode);
    for (self.msg_tex) |pt| if (pt) |tx| if (blend) |bl| {
        _ = c.SDL_SetTextureBlendMode(tx, bl);
    };
    defer for (self.msg_tex) |pt| if (pt) |tx| {
        _ = c.SDL_SetTextureBlendMode(tx, mode);
    };
    var wdt: f32 = 0;
    var hgt: f32 = 0;
    for (t) |ch| if (msgGlyph(self, ch)) |g| {
        wdt += @floatFromInt(g.advance);
        hgt = @max(hgt, og.num.toF32(g.h));
    } else {
        wdt += 14;
    };
    for (self.msg_tex) |pt| if (pt) |tx| {
        _ = c.SDL_SetTextureColorModFloat(tx, rgb[0] * a, rgb[1] * a, rgb[2] * a);
    };
    defer for (self.msg_tex) |pt| if (pt) |tx| {
        _ = c.SDL_SetTextureColorModFloat(tx, 1, 1, 1);
    };
    var x = cx - wdt * scale / 2;
    const y = cy - hgt * scale / 2;
    for (t) |ch| {
        const g = msgGlyph(self, ch) orelse {
            x += 14 * scale;
            continue;
        };
        const src: c.SDL_FRect = .{ .x = @floatFromInt(g.x), .y = @floatFromInt(g.y), .w = @floatFromInt(g.w), .h = @floatFromInt(g.h) };
        const dst: c.SDL_FRect = .{ .x = x, .y = y, .w = src.w * scale, .h = src.h * scale };
        if (msgTex(self, ch)) |tex| try gfx.check(c.SDL_RenderTexture(r, tex, &src, &dst));
        x += og.num.toF32(g.advance) * scale;
    }
}

/// 3d_msg text with alpha blending (TextEffect, 0x4c8d50): colour `rgb`, alpha `a`.
pub fn msgTextAlpha(self: *Gui, r: *c.SDL_Renderer, t: []const u8, cx: f32, cy: f32, scale: f32, rgb: [3]f32, a: f32) !void {
    for (self.msg_tex) |pt| if (pt) |tx| {
        _ = c.SDL_SetTextureAlphaModFloat(tx, std.math.clamp(a, 0, 1));
    };
    defer for (self.msg_tex) |pt| if (pt) |tx| {
        _ = c.SDL_SetTextureAlphaModFloat(tx, 1);
    };
    try msgTextBlend(self, r, t, cx, cy, scale, rgb, 1, c.SDL_BLENDMODE_BLEND);
}

/// Turn banners (0x45b150, 0x45b1b0): "Enemy Turn" (518) at the enemy turn start,
/// "Player Turn" (517) after it — a TextEffect at a screen point (0x4c8ac0(320, 250)):
/// same life and drawing as popups over fighters (`og.popup.Popup`), rising 1 px per
/// tick while holding and fading. "Victory" (501, 90,174,170, scale 2.25) at
/// (320, 240) 90 ticks after the win (0x454880).
pub fn drawBattleBanner(self: *Gui, r: *c.SDL_Renderer, w: *og.state.world.World, strings: ?*const og.formats.strtab.Table) !void {
    const b = &(w.battle orelse {
        self.last_phase = null;
        self.banner = null;
        return;
    });
    if (self.last_phase != b.phase) {
        const prev = self.last_phase;
        self.last_phase = b.phase;
        if (b.phase == .enemy and prev == .player) {
            self.banner = og.popup.Popup.make(.{ 0, 0, 0 }, if (strings) |st| st.get(518) orelse "Enemy Turn" else "Enemy Turn", .enemy_turn);
        } else if (b.phase == .player and prev == .enemy) {
            self.banner = og.popup.Popup.make(.{ 0, 0, 0 }, if (strings) |st| st.get(517) orelse "Player Turn" else "Player Turn", .player_turn);
        }
        self.banner_tick = w.ticks;
    }
    // Defeat (0x454350), phase 1: "Game Over" fades in over the battle for 90 ticks.
    if (b.phase == .lost and self.go_frame == null) {
        const a = @min(1, og.num.toF32(b.over_ticks) / 30);
        try msgText(self, r, if (strings) |st| st.get(500) orelse "Game Over" else "Game Over", 320, 220, 2.25, gfx.rgb(240, 64, 64), a);
        return;
    }
    if (b.phase == .won) {
        const t: f32 = @floatFromInt(b.over_ticks);
        if (t > 90 and !self.report_open) {
            const a = @min(1, (t - 90) / 30);
            try msgText(self, r, if (strings) |st| st.get(501) orelse "Victory" else "Victory", 320, 240, 2.25, gfx.rgb(90, 174, 170), a);
        }
        return;
    }
    const bn = &(self.banner orelse return);
    var n = w.ticks -% self.banner_tick;
    self.banner_tick = w.ticks;
    while (n > 0) : (n -= 1) if (!bn.tick()) {
        self.banner = null;
        return;
    };
    const lk = bn.look() orelse return;
    try msgTextAlpha(self, r, bn.text(), 320, 250 - bn.dy, bn.scale, lk.rgb, lk.a);
}

/// Defeat, phase 2 (0x454350): frozen battle frame, "Game Over" (500), "Repeat
/// Battle" (531) at (320, 300), YES (532) at (320, 330), NO (533) at (320, 355);
/// selected — scale 0.6, (255,140,40); the other — 0.5, (170,60,10).
pub fn drawGameOver(self: *Gui, r: *c.SDL_Renderer, strings: ?*const og.formats.strtab.Table) !void {
    const frame = self.go_frame orelse return;
    try gfx.check(c.SDL_RenderTexture(r, frame, null, null));
    const s = struct {
        fn get(st: ?*const og.formats.strtab.Table, id: i32, fb: []const u8) []const u8 {
            return if (st) |x| x.get(id) orelse fb else fb;
        }
    }.get;
    try msgText(self, r, s(strings, 500, "Game Over"), 320, 220, 2.25, gfx.rgb(240, 64, 64), 1);
    try msgText(self, r, s(strings, 531, "Repeat Battle"), 320, 300, 0.6, gfx.rgb(240, 64, 64), 1);
    const on = gfx.rgb(255, 140, 40);
    const off = gfx.rgb(170, 60, 10);
    try msgText(self, r, s(strings, 532, "Yes"), 320, 330, if (self.go_sel == 0) 0.6 else 0.5, if (self.go_sel == 0) on else off, 1);
    try msgText(self, r, s(strings, 533, "No"), 320, 355, if (self.go_sel == 1) 0.6 else 0.5, if (self.go_sel == 1) on else off, 1);
}

pub fn clearGameOver(self: *Gui) void {
    if (self.go_frame) |t| c.SDL_DestroyTexture(t);
    self.go_frame = null;
    self.go_sel = 0;
}

/// Post-battle report (0x452120): window at (10, 50); a row per hero (3 visible,
/// step 102): portrait (frame 0) at (17, +3), name right-aligned at x = 140, "exp
/// +N" (string.tab 350) at (67, +80), kills — icon at (154 + 85j, +6) and "name xN"
/// centred at (200 + 85j); "Close" (2) at (313, 409).
pub fn drawReport(self: *Gui, r: *c.SDL_Renderer, w: *og.state.world.World, strings: ?*const og.formats.strtab.Table) !void {
    const b = &(w.battle orelse {
        self.report_open = false;
        self.report_done = false;
        return;
    });
    if (b.phase == .won and b.over_ticks > 240 and !self.report_open and !self.report_done and self.raport.len() > 0) {
        self.report_open = true;
        self.report_scroll = 0;
        w.out.music_events.append(w.gpa, .{ .name = "statistics" }) catch {};
    }
    if (!self.report_open or self.raport.len() == 0) return;
    const X: f32 = 10;
    const Y: f32 = 50;
    try self.raport.draw(r, 0, X, Y);
    const t = &(self.win_text orelse return);
    @memset(t.pixels, 0);
    const f2 = self.font orelse return;
    // Close, names and kill labels in font 3 (0x4521a6); Close centred at (313, 409).
    const f = self.sys_font orelse f2;
    const col: [3]u8 = gui_mod.text_light;
    const close = if (strings) |st| st.get(2) orelse "Close" else "Close";
    gui_mod.textShadow(f, t.*, 313 - @divTrunc(@as(i32, @intCast(f.measure(close))), 2), 409, close, col);
    var heroes: [8]*og.battle.fighter.Fighter = undefined;
    var nh: usize = 0;
    for (b.fighters.items) |*fi| if (fi.controllable() and nh < heroes.len) {
        heroes[nh] = fi;
        nh += 1;
    };
    self.report_scroll = @min(self.report_scroll, nh -| 3);
    for (0..3) |i| {
        const k = self.report_scroll + i;
        if (k >= nh) break;
        const fi = heroes[k];
        const ry = Y + 22 + 102 * og.num.toF32(i);
        if (self.portrait(fi.obj)) |p| if (p.len() > 0) try p.draw(r, 0, X + 17, ry + 3);
        const name = if (strings) |st| st.get(og.fields.nameId(fi.obj)) orelse fi.obj.name else fi.obj.name;
        gui_mod.textShadow(f, t.*, @as(i32, @intFromFloat(X + 140)) - @as(i32, @intCast(f.measure(name))), @intFromFloat(ry), name, gui_mod.text_dim);
        if (fi.exp_gained > 0) {
            var eb: [48]u8 = undefined;
            const e = std.fmt.bufPrint(&eb, "{s} +{d}", .{ if (strings) |st| st.get(350) orelse "Experience" else "Experience", fi.exp_gained }) catch "";
            gui_mod.textShadow(f2, t.*, @intFromFloat(X + 67), @intFromFloat(ry + 80), e, .{ 255, 255, 255 });
        }
        for (fi.kills[0..fi.kills_n], 0..) |kl, j| {
            const jx = X + 154 + 85 * og.num.toF32(j);
            for (monster_icons) |mi| if (mi.id == kl.id) {
                if (self.icon(mi.name)) |ic| if (ic.len() > 0) try ic.draw(r, 0, jx, ry + 6);
                break;
            };
            var kb: [64]u8 = undefined;
            const kn = std.fmt.bufPrint(&kb, "{s} x{d}", .{ if (strings) |st| st.get(kl.id) orelse "?" else "?", kl.n }) catch "";
            gui_mod.textShadow(f, t.*, @as(i32, @intFromFloat(jx + 46)) - @divTrunc(@as(i32, @intCast(f.measure(kn))), 2), @intFromFloat(ry), kn, col);
        }
    }
    try gfx.drawImage(r, &self.win_tex, t.*);
}

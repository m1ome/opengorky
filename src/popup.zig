//! Floating text over fighters (TextEffect 0x4c8830) and its appearance queue
//! (delay object 0x4cd7b0).

const std = @import("std");
const num = @import("num.zig");
const adjust = @import("formats.zig").adjust;

/// TextEffect adjust.kdt values (registered 0x4c8660…0x4c87f0, tick 0x4c8c20): fade-in
/// teff_m1_step, flash teff_m2_step, hold teff_m2_timelen ticks, fade-out teff_m3_step,
/// height teff_height·aS (0x4c8bbd). teff_linedist is registered but never read;
/// teff_wait_a_little = 1 means it rises only while holding and fading (0x4c8d01).
fn teffM1() f32 {
    return adjust.getFloat("teff_m1_step", 0.15);
}
fn teffM2() f32 {
    return adjust.getFloat("teff_m2_step", 0.1);
}
fn teffM3() f32 {
    return adjust.getFloat("teff_m3_step", 0.05);
}
pub fn teffHeight() f32 {
    return @floatFromInt(adjust.getInt("teff_height", 650));
}

/// Floating text (TextEffect 0x4c8830, tick 0x4c8c20, draw 0x4c8d50): centred 3d_msg
/// font, alpha blend (mode 2), at point + teff_height·aS. Phases: fade in white, white →
/// colour, hold, fade out; the last two move 1 px per tick (up; down from y = 50 when the
/// point is within 80 px of the top, 0x4c88a9). Turn banners are the same class at a
/// screen point (0x4c8ac0, always up).
pub const Popup = struct {
    buf: [32]u8 = undefined,
    len: u8 = 0,
    pos: [3]f32,
    rgb: [3]u8 = .{ 255, 255, 255 },
    scale: f32 = 0.8,
    /// Ticks until it appears (0x4cd7b0).
    delay: u32 = 0,
    state: u8 = 0,
    v: f32 = 0,
    hold: u32 = 0,
    /// Screen-pixel offset.
    dy: f32 = 0,

    /// Colour and scale from adjust.kdt (cfc*), delay.
    pub const Style = enum { damage, heal, miss, exp, level, info, skill, range, notice, crit, counter, player_turn, enemy_turn };

    pub fn make(pos: [3]f32, text_: []const u8, style: Style) Popup {
        var p: Popup = .{ .pos = pos };
        const n = @min(text_.len, p.buf.len);
        @memcpy(p.buf[0..n], text_[0..n]);
        p.len = @intCast(n);
        switch (style) {
            .damage => {
                p.rgb = adjust.getRgb("cfcHpLoss", .{ 247, 83, 16 });
                p.scale = 0.8;
            },
            .heal => {
                p.rgb = adjust.getRgb("cfcHpGain", .{ 50, 160, 175 });
                p.scale = 0.8;
            },
            .miss => {
                p.rgb = adjust.getRgb("cfcMiss", .{ 95, 208, 179 });
                p.scale = 0.75;
            },
            .exp => {
                p.rgb = adjust.getRgb("cfcExpGain", .{ 207, 254, 251 });
                p.scale = 0.6;
                p.delay = 40;
            },
            .level => {
                p.rgb = adjust.getRgb("cfcLevelGain", .{ 255, 255, 255 });
                p.scale = 0.8;
                p.delay = 75;
            },
            .info => {
                p.rgb = adjust.getRgb("cfcProt", .{ 202, 230, 240 });
                p.scale = 0.5;
                // Delay object 0x4cd7b0(30): after the damage number.
                p.delay = 30;
            },
            .skill => {
                p.rgb = adjust.getRgb("cfcSkillGain", .{ 155, 212, 255 });
                p.scale = 0.6;
            },
            .crit => {
                p.rgb = adjust.getRgb("cfcCriticalhit", .{ 235, 252, 255 });
                p.scale = 0.75;
            },
            .range => {
                p.rgb = adjust.getRgb("cfcOutofrange", .{ 202, 230, 240 });
                p.scale = 0.6;
            },
            .notice => {
                p.rgb = adjust.getRgb("cfcNoammo", .{ 202, 230, 240 });
                p.scale = 0.6;
            },
            // "Counterattack" (516) over the hero, cfcCounter, scale 1 (0x45be3d).
            .counter => {
                p.rgb = adjust.getRgb("cfcCounter", .{ 184, 205, 247 });
                p.scale = 1;
            },
            // Turn banners (0x45b1b0, 0x45b150): cfcPlayerTurn / cfcMonsterTurn, 1.5.
            .player_turn => {
                p.rgb = adjust.getRgb("cfcPlayerTurn", .{ 80, 164, 160 });
                p.scale = 1.5;
            },
            .enemy_turn => {
                p.rgb = adjust.getRgb("cfcMonsterTurn", .{ 200, 90, 50 });
                p.scale = 1.5;
            },
        }
        return p;
    }

    pub fn text(self: *const Popup) []const u8 {
        return self.buf[0..self.len];
    }

    /// Ticks until it has faded in, flashed and risen one line (20 px); the next popup
    /// over the same fighter waits this long (`queuePopup`).
    fn clearIn(self: Popup) u32 {
        const line: f32 = 20;
        const rest: f32 = switch (self.state) {
            0 => @ceil((1 - self.v) / teffM1()) + @ceil(1 / teffM2()) + line,
            1 => @ceil(self.v / teffM2()) + line,
            else => @max(0, line - self.dy),
        };
        return self.delay + @as(u32, @intFromFloat(rest));
    }

    /// False once it has vanished.
    pub fn tick(self: *Popup) bool {
        if (self.delay > 0) {
            self.delay -= 1;
            return true;
        }
        switch (self.state) {
            0 => {
                self.v += teffM1();
                if (self.v >= 1) {
                    self.v = 1;
                    self.state = 1;
                }
            },
            1 => {
                self.v -= teffM2();
                if (self.v < 0) {
                    self.v = 0;
                    self.state = 2;
                }
            },
            2 => {
                self.dy += 1;
                self.hold += 1;
                if (self.hold >= @as(u32, @intCast(@max(0, adjust.getInt("teff_m2_timelen", 30))))) {
                    self.state = 3;
                    self.v = 1;
                }
            },
            else => {
                self.dy += 1;
                self.v -= teffM3();
                if (self.v <= 0) return false;
            },
        }
        return true;
    }

    /// Colour (0–1) and alpha; null before it appears.
    pub fn look(self: Popup) ?struct { rgb: [3]f32, a: f32 } {
        if (self.delay > 0) return null;
        const base = [3]f32{ num.toF32(self.rgb[0]) / 255, num.toF32(self.rgb[1]) / 255, num.toF32(self.rgb[2]) / 255 };
        return switch (self.state) {
            0 => .{ .rgb = .{ 1, 1, 1 }, .a = self.v },
            1 => .{ .rgb = .{ base[0] + (1 - base[0]) * self.v, base[1] + (1 - base[1]) * self.v, base[2] + (1 - base[2]) * self.v }, .a = 1 },
            2 => .{ .rgb = base, .a = 1 },
            else => .{ .rgb = base, .a = self.v },
        };
    }
};

/// Ticks all popups, removing finished ones and keeping order.
pub fn tickAll(popups: *std.ArrayList(Popup)) void {
    var i: usize = 0;
    while (i < popups.items.len) {
        if (!popups.items[i].tick()) _ = popups.orderedRemove(i) else i += 1;
    }
}

/// Popup over a fighter at `pos`. Each exe popup is its own object, appended without
/// looking for an existing one (0x4916ee → 0x431c10; "No ammo" 0x47c404). Some are wrapped
/// in the delay object 0x4cd7b0 (`startDelay`): damage (0x492170), "Luck" (0x4cf087) and
/// "Miss" (0x4cf31c) at once; armour class and "… protection" (0x4cabc1, 0x4cacbd) after
/// 30; "exp" (0x4cf5c6) after 40; "Weapon skill increased" (0x4cf703) after 3; "Level up"
/// (0x48fb78) after 75. So damage shows first although armour is created earlier
/// (0x4caa80 runs in 0x490f10 before 0x4913bb).
/// Deviation requested by the player (2026-10-11): the exe never spaces popups, so
/// "Medium Armor" and "… protection" overlap. Here popups over one fighter queue in
/// appearance order: each waits until every earlier one has risen a line, and later
/// ones wait for it.
pub fn queuePopup(popups: *std.ArrayList(Popup), gpa: std.mem.Allocator, pos: [3]f32, text: []const u8, style: Popup.Style) !void {
    var np = Popup.make(pos, text, style);
    np.delay = startDelay(style);
    for (popups.items) |p| if (p.pos[0] == pos[0] and p.pos[1] == pos[1] and p.delay <= np.delay) {
        np.delay = @max(np.delay, p.clearIn());
    };
    // Later popups, in appearance order, each after the previous one.
    var prev = np;
    while (true) {
        var next: ?*Popup = null;
        for (popups.items) |*p| if (p.pos[0] == pos[0] and p.pos[1] == pos[1] and p.delay > prev.delay) {
            if (next == null or p.delay < next.?.delay) next = p;
        };
        const p = next orelse break;
        p.delay = @max(p.delay, prev.clearIn());
        prev = p.*;
    }
    try popups.append(gpa, np);
}

/// Appearance delay per the exe delay object 0x4cd7b0 (`queuePopup`).
fn startDelay(style: Popup.Style) u32 {
    return switch (style) {
        .info => 30,
        .exp => 40,
        .skill => 3,
        .level => 75,
        else => 0,
    };
}

test "damage pops before the armor notice created earlier (0x4cd7b0 delay 30)" {
    var list: std.ArrayList(Popup) = .empty;
    defer list.deinit(std.testing.allocator);
    try queuePopup(&list, std.testing.allocator, .{ 1, 2, 0 }, "Medium Armor", .info);
    try queuePopup(&list, std.testing.allocator, .{ 1, 2, 0 }, "12", .damage);
    try std.testing.expectEqual(@as(u32, 0), list.items[1].delay);
    try std.testing.expect(list.items[0].delay >= list.items[1].clearIn());
}

test "two delayed notices stay in order after damage is inserted before them" {
    var list: std.ArrayList(Popup) = .empty;
    defer list.deinit(std.testing.allocator);
    try queuePopup(&list, std.testing.allocator, .{ 1, 2, 0 }, "Medium Armor", .info);
    try queuePopup(&list, std.testing.allocator, .{ 1, 2, 0 }, "Fire protection", .info);
    try queuePopup(&list, std.testing.allocator, .{ 1, 2, 0 }, "12", .damage);
    try std.testing.expectEqual(@as(u32, 0), list.items[2].delay);
    try std.testing.expect(list.items[0].delay >= list.items[2].clearIn());
    try std.testing.expect(list.items[1].delay >= list.items[0].clearIn());
}

test "same damage twice over one fighter gives two popups, the second after the first" {
    var list: std.ArrayList(Popup) = .empty;
    defer list.deinit(std.testing.allocator);
    try queuePopup(&list, std.testing.allocator, .{ 1, 2, 0 }, "15", .damage);
    try queuePopup(&list, std.testing.allocator, .{ 1, 2, 0 }, "15", .damage);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expect(list.items[1].delay >= list.items[0].clearIn());
}

test "popup over the same fighter waits until the previous one rises a line" {
    var a = Popup.make(.{ 0, 0, 0 }, "Medium Armor", .info);
    const wait = a.clearIn();
    var t: u32 = 0;
    while (t < wait) : (t += 1) _ = a.tick();
    try std.testing.expect(a.state >= 2 and a.dy >= 20);
}

//! State of the skills and stats windows (slide, rows, points); drawn by gui/stats.zig.

const std = @import("std");

/// Weapon skills window (`WeaponSkill.spr`, 0x4af020 / 0x4af110 / 0x4af450).
pub const SkillWindow = struct {
    /// 1 — slides in and stays, 0 — slides out; x eases to the target (−150 when closed).
    open: bool = false,
    visible: bool = false,
    x: f32 = -150,
    y: f32 = 40,
    target_x: f32 = 5,
    hero: []const u8 = "",
    scroll: usize = 0,
    tick: u64 = 0,

    /// Rows: weapons with level above 0 and a known icon (table 0x52a3a8).
    const icons = [_]struct { id: i32, name: []const u8 }{
        .{ .id = 49, .name = "pistolet" },          .{ .id = 98, .name = "riffle" },         .{ .id = 45, .name = "dartgun" },
        .{ .id = 1022, .name = "Chaingun" },        .{ .id = 1023, .name = "shotgun" },      .{ .id = 1024, .name = "RocketLuncher" },
        .{ .id = 1025, .name = "LiquidThrower" },   .{ .id = 1026, .name = "FlameThrower" }, .{ .id = 42, .name = "axe" },
        .{ .id = 76, .name = "bejsbol" },           .{ .id = 44, .name = "crowbar" },        .{ .id = 52, .name = "shocker" },
        .{ .id = 43, .name = "bagnet" },            .{ .id = 70, .name = "fist" },           .{ .id = 35, .name = "grenade" },
        .{ .id = 1027, .name = "grenade_teargas" }, .{ .id = 86, .name = "Molotov" },        .{ .id = 33, .name = "bomb_stun" },
        .{ .id = 40, .name = "knife_throwing" },    .{ .id = 34, .name = "bomb_time" },      .{ .id = 1037, .name = "blaster" },
        .{ .id = 1028, .name = "NapalmThrower" },   .{ .id = 1029, .name = "IonRifle" },     .{ .id = 80, .name = "matches" },
        .{ .id = 1030, .name = "gasoline" },        .{ .id = 1031, .name = "distractor" },   .{ .id = 1032, .name = "vodka" },
        .{ .id = 1020, .name = "MedusaShort" },     .{ .id = 1021, .name = "MedusaLong" },
    };

    pub fn iconOf(id: i32) ?[]const u8 {
        for (icons) |e| if (e.id == id) return e.name;
        return null;
    }

    /// Window rows (0x52aac8, from the window corner).
    pub const rows = [3][4]f32{ .{ 14, 100, 113, 168 }, .{ 14, 169, 113, 236 }, .{ 14, 237, 113, 305 } };

    pub fn show(self: *SkillWindow, x: f32, y: f32, hero: []const u8) void {
        if (!self.visible) self.x = -150;
        self.open = true;
        self.visible = true;
        self.target_x = x;
        self.y = y;
        self.hero = hero;
        self.scroll = 0;
    }

    pub fn close(self: *SkillWindow) void {
        self.open = false;
    }

    /// Slide per tick (0x4af110): step |d|/6, within 4 — stop; closed — disappear.
    pub fn step(self: *SkillWindow, ticks: u64) void {
        if (!self.visible) return;
        var n = @min(ticks -% self.tick, 30);
        self.tick = ticks;
        while (n > 0) : (n -= 1) {
            const target: f32 = if (self.open) self.target_x else -150;
            const d = target - self.x;
            if (@abs(d) < 4) {
                self.x = target;
                if (!self.open) self.visible = false;
                return;
            }
            self.x += @trunc(@abs(d)) / 6 * std.math.sign(d);
        }
    }

    pub fn rowAt(self: SkillWindow, mx: f32, my: f32) ?usize {
        if (!self.visible) return null;
        for (rows, 0..) |r, i| {
            if (mx >= self.x + r[0] and mx <= self.x + r[2] and my >= self.y + r[1] and my <= self.y + r[3]) return i;
        }
        return null;
    }

    pub fn contains(self: SkillWindow, mx: f32, my: f32) bool {
        return self.visible and mx >= self.x and mx < self.x + 143 and my >= self.y and my < self.y + 323;
    }
};

/// Hero stats window (0x4af780 show, 0x4af890 update, 0x4afe00 draw): seven rows
/// (exp, health, move, luck, accuracy, counterattack, coolness); in point
/// allocation mode (level-up) — ± buttons and Accept.
pub const StatsWindow = struct {
    open: bool = false,
    visible: bool = false,
    animate: bool = true,
    upgrade: bool = false,
    /// The points window is the top GUI mode (0x4af7c2: [0x651cbc] = window) until it
    /// slides out (0x4af8eb → 0x4afcd0 → 0x4afda9): only it ticks and draws
    /// (0x45a8f6, 0x45ac1c); the battle mode below stands still.
    modal: bool = false,
    x: f32 = 700,
    y: f32 = 50,
    target_x: f32 = 450,
    hero: []const u8 = "",
    total: i32 = 0,
    pts: [7]i32 = @splat(0),
    /// Wait before sliding in (150 ticks, points mode) and the ± buttons unfolding.
    delay: u32 = 0,
    popin: f32 = -7,
    tick: u64 = 0,

    /// show (0x4af780): animated from (700, 50), only X moves.
    pub fn show(self: *StatsWindow, x: f32, y: f32, hero: []const u8, animate: bool, points: i32) void {
        self.* = .{ .open = true, .visible = true, .animate = animate, .hero = hero, .target_x = x, .tick = self.tick };
        if (animate) {
            self.x = 700;
            self.y = 50;
        } else {
            self.x = x;
            self.y = y;
        }
        if (points > 0) {
            self.upgrade = true;
            self.modal = true;
            self.total = points;
            self.delay = 150;
        }
    }

    pub fn close(self: *StatsWindow) void {
        self.open = false;
        if (!self.animate) {
            self.visible = false;
            self.modal = false;
        }
    }

    pub fn remaining(self: StatsWindow) i32 {
        var n: i32 = 0;
        for (self.pts) |p| n += @intCast(@abs(p));
        return self.total - n;
    }

    /// Tick (0x4af890): wait, slide (step |d|/6, within 4 — stop), ± unfolding.
    pub fn step(self: *StatsWindow, ticks: u64) void {
        var n = @min(ticks -% self.tick, 600);
        self.tick = ticks;
        while (n > 0 and self.visible) : (n -= 1) {
            if (self.upgrade and self.delay > 0) {
                self.delay -= 1;
                continue;
            }
            if (self.animate) {
                const t: f32 = if (self.open) self.target_x else 700;
                const d = t - self.x;
                if (@abs(d) < 4) {
                    self.x = t;
                    if (!self.open) {
                        self.visible = false;
                        self.modal = false;
                    }
                } else self.x += @trunc(@abs(d)) / 6 * std.math.sign(d);
            }
            self.popin = @min(5, self.popin + 0.4);
        }
    }

    pub fn contains(self: StatsWindow, mx: f32, my: f32) bool {
        return self.visible and mx >= self.x and mx <= self.x + 185 and my >= self.y and my <= self.y + 336;
    }
};

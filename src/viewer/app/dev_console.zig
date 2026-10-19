//! Debug console: input line, scrollable output, command history and drawing.
//! Commands run in `commands.consoleRun` (world commands in `console.zig`).

const std = @import("std");
const og = @import("opengorky");
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");

const screen_w = @import("opengorky").state.world.screen_w;

pub const DevConsole = struct {
    open: bool = false,
    input: [160]u8 = undefined,
    len: usize = 0,
    lines: std.ArrayList([]u8) = .empty,
    /// Scroll: lines up from the end (PageUp/PageDown, Shift+arrows, wheel);
    /// 0 is the bottom, where new output shows at once.
    scroll: usize = 0,
    /// Command history (up/down arrows) and the position in it
    /// (`history.items.len` is the new line).
    history: std.ArrayList([]u8) = .empty,
    history_pos: usize = 0,

    pub fn deinit(self: *DevConsole, gpa: Allocator) void {
        self.clear(gpa);
        self.lines.deinit(gpa);
        for (self.history.items) |t| gpa.free(t);
        self.history.deinit(gpa);
    }

    /// Clears the output.
    pub fn clear(self: *DevConsole, gpa: Allocator) void {
        for (self.lines.items) |t| gpa.free(t);
        self.lines.clearRetainingCapacity();
    }

    /// Adds a command to the history (no consecutive repeats); position back to the new line.
    pub fn remember(self: *DevConsole, gpa: Allocator, line: []const u8) void {
        defer self.history_pos = self.history.items.len;
        if (line.len == 0) return;
        const h = self.history.items;
        if (h.len > 0 and std.mem.eql(u8, h[h.len - 1], line)) return;
        const copy = gpa.dupe(u8, line) catch return;
        self.history.append(gpa, copy) catch return gpa.free(copy);
        if (self.history.items.len > 100) gpa.free(self.history.orderedRemove(0));
    }

    /// Up (-1) / down (+1) arrow: input line from the history.
    pub fn historyStep(self: *DevConsole, d: i32) void {
        const h = self.history.items;
        if (h.len == 0) return;
        if (d < 0) {
            self.history_pos -|= 1;
        } else if (self.history_pos < h.len) {
            self.history_pos += 1;
        }
        if (self.history_pos >= h.len) {
            self.len = 0;
            return;
        }
        const t = h[self.history_pos];
        const n = @min(t.len, self.input.len);
        @memcpy(self.input[0..n], t[0..n]);
        self.len = n;
    }

    /// Line into the console; long lines wrap at 78 chars.
    pub fn print(self: *DevConsole, gpa: Allocator, text: []const u8) !void {
        var rest = text;
        while (true) {
            const n = @min(rest.len, 78);
            try self.lines.append(gpa, try gpa.dupe(u8, rest[0..n]));
            // Scrolled up: the view stays; at the bottom: the new line shows.
            if (self.scroll > 0) self.scroll += 1;
            rest = rest[n..];
            if (rest.len == 0) break;
        }
        while (self.lines.items.len > 1000) gpa.free(self.lines.orderedRemove(0));
    }

    /// Typed characters (printable ASCII except "`").
    pub fn typeText(self: *DevConsole, t: []const u8) void {
        for (t) |ch| if (ch != '`' and ch >= 32 and ch < 127 and self.len < self.input.len) {
            self.input[self.len] = ch;
            self.len += 1;
        };
    }

    pub fn draw(self: *DevConsole, r: *c.SDL_Renderer) !void {
        if (!self.open) return;
        const rows = 40;
        try gfx.fillRect(r, .{ 0, 0, 0, 200 }, .{ .x = 0, .y = 0, .w = screen_w, .h = rows * 10 + 16 });
        try gfx.check(c.SDL_SetRenderDrawColor(r, 170, 230, 170, 255));
        const all = self.lines.items;
        self.scroll = @min(self.scroll, all.len -| rows);
        const lines = all[0 .. all.len - self.scroll];
        const first = lines.len -| rows;
        var buf: [200]u8 = undefined;
        // Scrollbar on the right: visible share and position in the output.
        if (all.len > rows) {
            const h: f32 = rows * 10 + 8;
            const total: f32 = @floatFromInt(all.len);
            const bar = @max(8, h * rows / total);
            const top = (h - bar) * og.num.toF32(first) / og.num.toF32(all.len - rows);
            try gfx.fillRect(r, .{ 60, 80, 60, 255 }, .{ .x = screen_w - 6, .y = 4, .w = 3, .h = h });
            try gfx.fillRect(r, .{ 170, 230, 170, 255 }, .{ .x = screen_w - 7, .y = 4 + top, .w = 5, .h = bar });
        }
        if (self.scroll > 0) {
            const z = std.fmt.bufPrintSentinel(&buf, "-- {d} more below (End) --", .{self.scroll}, 0) catch "";
            try gfx.check(c.SDL_SetRenderDrawColor(r, 255, 210, 80, 255));
            try gfx.check(c.SDL_RenderDebugText(r, screen_w - 230, rows * 10 + 4, z));
            try gfx.check(c.SDL_SetRenderDrawColor(r, 170, 230, 170, 255));
        }
        for (lines[first..], 0..) |t, i| {
            const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{t[0..@min(t.len, 79)]}, 0) catch continue;
            try gfx.check(c.SDL_RenderDebugText(r, 4, 4 + og.num.toF32(i) * 10, z));
        }
        try gfx.check(c.SDL_SetRenderDrawColor(r, 255, 255, 255, 255));
        const caret: []const u8 = if ((c.SDL_GetTicks() / 400) % 2 == 0) "_" else " ";
        const z = std.fmt.bufPrintSentinel(&buf, "] {s}{s}", .{ self.input[0..self.len], caret }, 0) catch return;
        try gfx.check(c.SDL_RenderDebugText(r, 4, rows * 10 + 4, z));
    }
};

//! Viewer console commands: world commands (console.zig) plus its own — layer show/hide, perf, mute, impulse, placeheroes, fast, scale, back, pause.

const std = @import("std");
const Debug = @import("../level.zig").Debug;
const c = @import("sdl");
const debug_layers = @import("../level/debug_layers.zig");
const viewer = @import("viewer.zig");
const battle_view = @import("../battle/view.zig");
const Viewer = viewer.Viewer;
const Io = std.Io;
const og = @import("opengorky");
const viewer_help = viewer.viewer_help;
const Layer = Viewer.Layer;
const LevelView = @import("../level.zig").LevelView;

/// Runs a console command (`console.zig`) and keeps the output.
pub fn consoleRun(self: *Viewer, line: []const u8) void {
    // A typed command scrolls the output back to the bottom.
    self.console.scroll = 0;
    self.console.remember(self.gpa, line);
    const echo = std.fmt.allocPrint(self.gpa, "> {s}", .{line}) catch return;
    self.console.lines.append(self.gpa, echo) catch self.gpa.free(echo);
    if (viewerCommand(self, line)) return;
    const l = &(self.level orelse {
        self.console.print(self.gpa, "no level loaded") catch {};
        return;
    });
    var out: Io.Writer.Allocating = .init(self.gpa);
    defer out.deinit();
    const eff = og.console.run(l.world, line, &out.writer) catch |err| blk: {
        out.writer.print("error: {t}\n", .{err}) catch {};
        break :blk og.console.Effect.none;
    };
    if (eff == .close) {
        self.console.open = false;
        return;
    }
    if (eff == .clear) {
        self.console.clear(self.gpa);
        return;
    }
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line, " \t"), "help")) out.writer.print("\n{s}", .{viewer_help}) catch {};
    consoleOut(self, out.written());
}
/// Command output line by line into the console (and the log for scripts).
fn consoleOut(self: *Viewer, text: []const u8) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |t| if (t.len > 0) {
        self.console.print(self.gpa, t) catch {};
        // Shots (--shot): console replies go to the log too, so scripts see the result.
        if (self.shot_run or self.input_mode or viewer.log_level == .info) std.log.warn("console: {s}", .{t});
    };
}
/// Viewer commands (formerly debug keys): layer `show`/`hide`, `impulse`,
/// `placeheroes`, `fast`, `scale`, `back`, `mute`, `pause`. true — handled here.
fn viewerCommand(self: *Viewer, line: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const cmd = it.next() orelse return false;
    const eq = std.ascii.eqlIgnoreCase;
    var buf: [256]u8 = undefined;
    // scroll: camera scroll (screen = background − scroll), for script clicks.
    if (eq(cmd, "scroll")) {
        consoleOut(self, std.fmt.bufPrint(&buf, "scroll {d:.0},{d:.0}", .{ self.scroll[0], self.scroll[1] }) catch "");
        return true;
    }
    // ui: top GUI state, for --input checks.
    if (eq(cmd, "ui")) {
        const m_open = if (self.menu) |m| m.open else false;
        const screen = if (self.menu) |m| @tagName(m.screen) else "none";
        const modal = if (self.gui) |g| g.stats.modal else false;
        const lvl = if (self.level) |*l| l.world.level_name else "none";
        const tr_ticks: u32 = if (self.transition) |tr| tr.ticks else 0;
        consoleOut(self, std.fmt.bufPrint(&buf, "ui menu {} screen {s} level {s} transition {} ({d}) modal {}", .{ m_open, screen, lvl, self.transition != null, tr_ticks, modal }) catch "");
        return true;
    }
    // tilepos X Y: screen point of battle cell X,Y centre, for --input clicks.
    if (eq(cmd, "tilepos")) {
        const l = &(self.level orelse return true);
        const cm = l.world.combat_map orelse {
            consoleOut(self, "no combat map");
            return true;
        };
        const gx = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0;
        const gy = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0;
        const p = l.world.cam.project(battle_view.gridPoint(l, cm, gx + 0.5, gy + 0.5));
        const sx = (p.x - self.scroll[0] - og.state.world.screen_cx) * self.zoom + og.state.world.screen_cx;
        const sy = (p.y - self.scroll[1] - og.state.world.screen_cy) * self.zoom + og.state.world.screen_cy;
        consoleOut(self, std.fmt.bufPrint(&buf, "tile {d:.0},{d:.0} screen {d:.0},{d:.0}", .{ gx, gy, sx, sy }) catch "");
        return true;
    }
    if (eq(cmd, "show") or eq(cmd, "hide")) {
        const on = eq(cmd, "show");
        const name = it.next() orelse {
            consoleOut(self, layerList(self, &buf));
            return true;
        };
        const layer = std.meta.stringToEnum(Layer, name) orelse {
            consoleOut(self, "layers: walk walk2 cells areas objects hud depth shadows");
            return true;
        };
        if (layer != .hud and layer != .depth and layer != .shadows and self.level == null) {
            consoleOut(self, "no level loaded");
            return true;
        }
        setLayer(self, layer, on);
        consoleOut(self, layerList(self, &buf));
        return true;
    }
    if (eq(cmd, "perf")) {
        self.show_perf = !self.show_perf;
        consoleOut(self, if (self.show_perf) "perf on (fps and ms per part)" else "perf off");
        return true;
    }
    if (eq(cmd, "mute")) {
        const snd = self.sound orelse {
            consoleOut(self, "no sound");
            return true;
        };
        snd.mixer.master = if (snd.mixer.master > 0) 0 else 1;
        consoleOut(self, if (snd.mixer.master > 0) "sound on" else "sound off");
        return true;
    }
    const l = &(self.level orelse return false);
    if (eq(cmd, "impulse")) {
        debug_layers.impulseAll(l);
        consoleOut(self, "impulse: all active animations");
    } else if (eq(cmd, "placeheroes")) {
        debug_layers.placeHeroes(l, self.scroll);
        consoleOut(self, "heroes placed");
    } else if (eq(cmd, "fast")) {
        const n = std.fmt.parseInt(u32, it.next() orelse "", 10) catch (if (l.speed > 1) @as(u32, 1) else 8);
        l.speed = std.math.clamp(n, 1, 64);
        consoleOut(self, std.fmt.bufPrint(&buf, "world speed x{d}", .{l.speed}) catch "");
    } else if (eq(cmd, "scale")) {
        const pc = std.fmt.parseFloat(f32, it.next() orelse "100") catch 100;
        self.debug.scale_tweak = std.math.clamp(pc / 100, Debug.scale_min, Debug.scale_max);
        consoleOut(self, std.fmt.bufPrint(&buf, "model scale {d:.0}%", .{self.debug.scale_tweak * 100}) catch "");
    } else if (eq(cmd, "back")) {
        const p = self.game.prev orelse {
            consoleOut(self, "no previous location");
            return true;
        };
        self.game.goTo(p);
        consoleOut(self, std.fmt.bufPrint(&buf, "back to {s}", .{p}) catch "");
    } else if (eq(cmd, "shadowstat")) {
        // Shadow pixels in the last frame and those dropped by the background depth (hires > 1).
        const st = (l.layer orelse return true).shadow_stat;
        consoleOut(self, std.fmt.bufPrint(&buf, "shadow lit {d} cut_bg {d}", .{ st.lit, st.cut_bg }) catch "");
    } else if (eq(cmd, "pause")) {
        l.paused = !l.paused;
        consoleOut(self, if (l.paused) "paused" else "running");
    } else return false;
    return true;
}
fn setLayer(self: *Viewer, layer: Layer, on: bool) void {
    switch (layer) {
        .hud => self.show_debug = on,
        .depth => self.debug.no_depth = !on,
        .shadows => self.debug.shadow_debug = on,
        .walk, .walk2 => {
            const l = &self.level.?;
            const k: u2 = if (layer == .walk) 1 else 2;
            if (on and l.walk_textures[k - 1] != null) {
                l.walk_layer = k;
            } else if (l.walk_layer == k) l.walk_layer = 0;
        },
        .cells => self.level.?.show_grid = on and self.level.?.world.combat_map != null,
        .areas => self.level.?.show_areas = on,
        .objects => self.level.?.show_objects = on,
    }
}
/// "layer on/off" line for `show` without an argument.
fn layerList(self: *Viewer, buf: []u8) []const u8 {
    const lv: ?*LevelView = if (self.level) |*l| l else null;
    return std.fmt.bufPrint(buf, "walk {s}, walk2 {s}, cells {s}, areas {s}, objects {s}, hud {s}, depth {s}, shadows {s}", .{
        viewer.onOff(if (lv) |l| l.walk_layer == 1 else false),
        viewer.onOff(if (lv) |l| l.walk_layer == 2 else false),
        viewer.onOff(if (lv) |l| l.show_grid else false),
        viewer.onOff(if (lv) |l| l.show_areas else false),
        viewer.onOff(if (lv) |l| l.show_objects else false),
        viewer.onOff(self.show_debug),
        viewer.onOff(!self.debug.no_depth),
        viewer.onOff(self.debug.shadow_debug),
    }) catch "";
}

/// Key while the console is open: Esc closes, Enter runs, PgUp/PgDn, Home/End and
/// Shift+arrows scroll, arrows browse the history.
pub fn consoleKey(v: *Viewer, window: *c.SDL_Window, k: c.SDL_Keycode, mod: c.SDL_Keymod) void {
    const con = &v.console;
    switch (k) {
        c.SDLK_ESCAPE => {
            con.open = false;
            _ = c.SDL_StopTextInput(window);
        },
        c.SDLK_BACKSPACE => con.len -|= 1,
        c.SDLK_PAGEUP => con.scroll += 20,
        c.SDLK_PAGEDOWN => con.scroll -|= 20,
        c.SDLK_HOME => con.scroll = con.lines.items.len,
        c.SDLK_END => con.scroll = 0,
        c.SDLK_UP => if (mod & c.SDL_KMOD_SHIFT != 0) {
            con.scroll += 1;
        } else con.historyStep(-1),
        c.SDLK_DOWN => if (mod & c.SDL_KMOD_SHIFT != 0) {
            con.scroll -|= 1;
        } else con.historyStep(1),
        c.SDLK_RETURN, c.SDLK_KP_ENTER => {
            const line = v.gpa.dupe(u8, con.input[0..con.len]) catch return;
            defer v.gpa.free(line);
            con.len = 0;
            consoleRun(v, line);
        },
        else => {},
    }
}

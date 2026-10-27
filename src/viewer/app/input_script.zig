//! Input script `--input "step;step;…"` (or `--input @file`): per-frame steps fed
//! as SDL events, like a player's mouse and keyboard.
//!   m/d/u/c/r/b X,Y — move, press, release, click, right, double;
//!   v N — wheel; p key — press (SDL name); w N — wait N frames;
//!   s file — 640×480 shot; S file — window shot; x/k command — console;
//!   R — wait for the battle report and close it; q — quit;
//!   o DIR — record every frame into DIR/00000.png…; O — stop recording;
//!   W — wait for a scene to start (60 s at most: a walk to its area) and end.

const std = @import("std");
const commands = @import("commands.zig");
const c = @import("sdl");
const Viewer = @import("viewer.zig").Viewer;
const gfx = @import("../media/gfx.zig");

pub const InputScript = struct {
    it: std.mem.SplitIterator(u8, .scalar),
    wait: u32 = 0,
    /// Step "R": wait for the battle report and close it like the Close button.
    report: bool = false,
    /// Step "W": frames left to wait for a scene to start, then (started) its end.
    scene: ?u32 = null,
    scene_started: bool = false,
    /// Shot requested by step `s`; taken after the frame is drawn.
    shot: ?[]const u8 = null,

    const Result = enum { ok, quit };

    /// Steps up to the next wait; `.quit` when the script ends or on `q`.
    pub fn step(self: *InputScript, v: *Viewer, window: *c.SDL_Window, renderer: *c.SDL_Renderer) !Result {
        if (self.scene) |*left| {
            const playing = if (v.level) |*l| l.world.scene.runner != null else false;
            if (playing) self.scene_started = true;
            if (self.scene_started and !playing) {
                self.scene = null;
            } else if (!self.scene_started) {
                if (left.* == 0) self.scene = null else left.* -= 1;
            }
        } else if (self.report) {
            if (v.gui) |g| if (g.report_open) {
                g.report_open = false;
                g.report_done = true;
                self.report = false;
            };
        } else if (self.wait > 0) {
            self.wait -= 1;
        } else while (self.it.next()) |raw| {
            const cmd = std.mem.trim(u8, raw, " ");
            if (cmd.len == 0) continue;
            const arg = std.mem.trim(u8, cmd[1..], " ");
            switch (cmd[0]) {
                'w' => {
                    self.wait = std.fmt.parseInt(u32, arg, 10) catch 1;
                    break;
                },
                's' => {
                    self.shot = arg;
                    break;
                },
                // S <file> — window shot (frame scaled to the window per `scaling`).
                'S' => {
                    v.window_shot = arg;
                    break;
                },
                'q' => return .quit,
                'o' => {
                    std.Io.Dir.cwd().createDirPath(v.io, arg) catch |err| std.log.warn("record {s}: {t}", .{ arg, err });
                    v.record_dir = arg;
                    v.record_n = 0;
                },
                'O' => v.record_dir = null,
                'R' => {
                    self.report = true;
                    break;
                },
                'W' => {
                    self.scene = 60 * 30;
                    self.scene_started = false;
                    break;
                },
                // k / x <command> — console command (battle, auto, scene…).
                'k', 'x' => {
                    commands.consoleRun(v, arg);
                    self.wait = 1;
                    break;
                },
                // p <key> — press and release a key (SDL name: Tab, E, Return…).
                'p' => {
                    var nb: [32]u8 = undefined;
                    const name = std.fmt.bufPrintSentinel(&nb, "{s}", .{arg}, 0) catch "";
                    for ([_]u32{ c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP }) |t| {
                        var ke: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
                        ke.type = t;
                        ke.key.windowID = c.SDL_GetWindowID(window);
                        ke.key.key = c.SDL_GetKeyFromName(name.ptr);
                        ke.key.down = t == c.SDL_EVENT_KEY_DOWN;
                        _ = c.SDL_PushEvent(&ke);
                    }
                    self.wait = 1;
                    break;
                },
                'v' => {
                    var we: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
                    we.type = c.SDL_EVENT_MOUSE_WHEEL;
                    we.wheel.windowID = c.SDL_GetWindowID(window);
                    we.wheel.y = std.fmt.parseFloat(f32, arg) catch -1;
                    _ = c.SDL_PushEvent(&we);
                    self.wait = 6;
                    break;
                },
                'm', 'd', 'u', 'c', 'r', 'b' => {
                    var xy = std.mem.splitScalar(u8, arg, ',');
                    const lx = std.fmt.parseFloat(f32, xy.next() orelse "0") catch 0;
                    const ly = std.fmt.parseFloat(f32, xy.next() orelse "0") catch 0;
                    var wx: f32 = 0;
                    var wy: f32 = 0;
                    _ = c.SDL_RenderCoordinatesToWindow(renderer, lx + gfx.wide, ly, &wx, &wy);
                    var mv: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
                    mv.type = c.SDL_EVENT_MOUSE_MOTION;
                    mv.motion.windowID = c.SDL_GetWindowID(window);
                    mv.motion.x = wx;
                    mv.motion.y = wy;
                    _ = c.SDL_PushEvent(&mv);
                    const btn: u8 = if (cmd[0] == 'r') c.SDL_BUTTON_RIGHT else c.SDL_BUTTON_LEFT;
                    const downs: []const bool = switch (cmd[0]) {
                        'd' => &.{true},
                        'u' => &.{false},
                        'c', 'r' => &.{ true, false },
                        // Double click: the second press with clicks = 2 (SDL).
                        'b' => &.{ true, false, true, false },
                        else => &.{},
                    };
                    var n_down: u8 = 0;
                    for (downs) |down| {
                        if (down) n_down += 1;
                        var be: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
                        be.type = if (down) c.SDL_EVENT_MOUSE_BUTTON_DOWN else c.SDL_EVENT_MOUSE_BUTTON_UP;
                        be.button.windowID = mv.motion.windowID;
                        be.button.button = btn;
                        be.button.down = down;
                        be.button.clicks = n_down;
                        be.button.x = wx;
                        be.button.y = wy;
                        _ = c.SDL_PushEvent(&be);
                    }
                    // Release on the next frame, like a human.
                    if (cmd[0] == 'd' or cmd[0] == 'c' or cmd[0] == 'r' or cmd[0] == 'b') {
                        self.wait = 1;
                        break;
                    }
                },
                else => {},
            }
        } else if (self.wait == 0) return .quit;
        return .ok;
    }
};

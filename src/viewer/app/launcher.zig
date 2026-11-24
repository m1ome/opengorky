//! Launcher window: shown before the game when it starts without arguments (a double
//! click, the macOS app, `opengorky` on Linux without a path), with `launcher = 1`,
//! Shift held, or no usable game folder. Two views: the home one (the game to play, the
//! game folder's state, Play) and the settings (opengorky.cfg in three tabs). Play saves
//! the settings and the game opens its own window; Esc on the home view or closing the
//! window quits without saving. Layout by the editor's Clay kit.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("sdl");
const ui = @import("ui");
const og = @import("opengorky");
const kit = @import("kit");
const config = @import("config.zig");
const startup = @import("startup.zig");
const packages = @import("packages.zig");
const gfx = @import("../media/gfx.zig");
const clay = kit.clay;
const Io = std.Io;
const Scaling = config.Scaling;

/// The view it opens on (`--launcher-tab`): `play` the home view, the others a settings tab.
pub const Tab = enum { play, display, game, advanced };
pub const Result = enum { play, exit };

const Fonts = kit.font.Fonts(&.{
    .{ .ttf = @embedFile("font_regular"), .sizes = &.{ 10, 11, 12, 13 } },
    .{ .ttf = @embedFile("font_bold"), .sizes = &.{ 9, 10, 12, 14, 15, 19 } },
    .{ .ttf = @embedFile("font_heading"), .sizes = &.{32} },
    // The title on the home view, Latin only (its size would not fit the atlas otherwise).
    .{ .ttf = @embedFile("font_heading"), .sizes = &.{96}, .latin = true },
}, 1280);
const regular = 0;
const bold = 1;
/// Oswald Bold: the settings' title.
const heading = 2;
const brand = 3;

/// The reference design's colours (its HTML mock-up).
const theme = struct {
    const orange = clay.rgb(0xf28b19);
    const orange_hover = clay.rgb(0xffa52b);
    const orange_line = clay.rgb(0xffae44);
    const ink = clay.rgb(0x15100a);
    const white = clay.rgb(0xe9e7de);
    const eyebrow = clay.rgb(0xe39b4c);
    const sub = clay.rgb(0xc6c2b8);
    const label = clay.rgb(0xbcb9b0);
    const footer = clay.rgb(0x99978e);
    const ok = clay.rgb(0xb5dca0);
    const ok_ring = clay.rgb(0x8ec771);
    const err = clay.rgb(0xe37b68);
    const detail = clay.rgb(0xaaa69b);
    const desc = clay.rgb(0x93958c);
    const tab = clay.rgb(0xa5a59b);
    const back = clay.rgb(0xc8c5bc);
    const line = clay.rgb(0x44463e);
    const row_line = clay.rgb(0x343731);
    const bottom_line = clay.rgb(0x3b3e37);
    const control = clay.rgb(0x1a1c19);
    const control_text = clay.rgb(0xc1c0b8);
    const control_line = clay.rgb(0x484b43);
    const field = clay.rgb(0x171916);
    const field_text = clay.rgb(0xd5d2c8);
    const toggle_off = clay.rgb(0x44463f);
    const muted = clay.rgb(0x6f7068);
    const clear: clay.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
};

fn rgba(hex: u24, a: u8) clay.Color {
    var col = clay.rgb(hex);
    col.a = @floatFromInt(a);
    return col;
}

/// Icons (assets/launcher/icons, scripts/launcher-icons.swift): white, tinted when drawn.
const Icon = enum { settings, info, back, check, warning, play };

const Folder = enum { unset, missing, no_dat, ok };

const View = enum { home, settings };

/// The native folder dialog's answer; its callback may run on another thread (SDL docs)
/// and after the window is gone, so it lives here.
const Pick = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    done: std.atomic.Value(bool) = .init(true),

    fn picked(ud: ?*anyopaque, list: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
        const p: *Pick = @ptrCast(@alignCast(ud));
        if (list != null and list[0] != null) {
            const path = std.mem.span(list[0]);
            p.len = @min(path.len, p.buf.len);
            @memcpy(p.buf[0..p.len], path[0..p.len]);
        }
        p.done.store(true, .release);
    }
};
var pick: Pick = .{};

const Launcher = struct {
    io: Io,
    gpa: std.mem.Allocator,
    r: *c.SDL_Renderer,
    window: *c.SDL_Window,
    fonts: *Fonts,
    cfg: config.Config,
    cfg_path: []const u8,
    view: View,
    /// The settings' tab (`play` is not one: display).
    tab: Tab,
    size: [2]f32 = .{ 0, 0 },
    mouse: [2]f32 = .{ -1, -1 },
    down: bool = false,
    clicked: bool = false,
    result: ?Result = null,
    picking: bool = false,
    icons: [std.enums.values(Icon).len]?*c.SDL_Texture = @splat(null),
    background: ?*c.SDL_Texture = null,
    folder: Folder = .unset,
    /// The settings' folder (its `mods/` holds packages too).
    cfg_dir: ?[]const u8 = null,
    /// The packages of the `mods/` folders (`pkg_arena`'s), found with the game folder.
    pkgs: []const packages.Package = &.{},
    pkg_arena: std.heap.ArenaAllocator = undefined,
    lang: u8 = 0,
    avi: bool = false,
    /// A note at the bottom right (About) until SDL tick `toast_until`.
    toast: []const u8 = "",
    toast_until: u64 = 0,
    /// Texts made per frame (clay keeps pointers until the frame is drawn).
    path_buf: [2][1100]u8 = undefined,
    detail_buf: [200]u8 = undefined,
    fps_buf: [2][200]u8 = undefined,

    /// Looks at the game folder: set, there, with `dat` (and `avi`), its language.
    fn check(self: *Launcher) void {
        const path = self.cfg.gamePath();
        _ = self.pkg_arena.reset(.retain_capacity);
        self.pkgs = packages.find(self.io, self.pkg_arena.allocator(), path, self.cfg_dir);
        self.folder = .unset;
        if (path.len == 0) return;
        var d = Io.Dir.cwd().openDir(self.io, path, .{}) catch {
            self.folder = .missing;
            return;
        };
        defer d.close(self.io);
        var dat = d.openDir(self.io, "dat", .{ .iterate = true }) catch {
            self.folder = .no_dat;
            return;
        };
        defer dat.close(self.io);
        self.lang = og.formats.lang.language(self.io, self.gpa, dat);
        self.avi = if (d.openDir(self.io, "avi", .{})) |a| blk: {
            var avi = a;
            avi.close(self.io);
            break :blk true;
        } else |_| false;
        self.folder = .ok;
    }

    fn texture(self: *Launcher, data: []const u8, smooth: bool) ?*c.SDL_Texture {
        var img = og.formats.jpeg.decode(self.gpa, data) catch return null;
        defer img.deinit(self.gpa);
        const t = c.SDL_CreateTexture(self.r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, @intCast(img.width), @intCast(img.height)) orelse return null;
        _ = c.SDL_UpdateTexture(t, null, img.pixels.ptr, @intCast(img.width * 4));
        _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_BLEND);
        _ = c.SDL_SetTextureScaleMode(t, if (smooth) c.SDL_SCALEMODE_LINEAR else c.SDL_SCALEMODE_NEAREST);
        return t;
    }

    fn icon(self: *Launcher, ic: Icon, px: f32, color: clay.Color) void {
        const k = @backingInt(ic);
        if (self.icons[k] == null) self.icons[k] = self.texture(switch (ic) {
            inline else => |t| @embedFile("launcher_" ++ @tagName(t)),
        }, true);
        clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(px), .height = clay.fixed(px) } }, .image = .{ .imageData = self.icons[k] }, .backgroundColor = color, .userData = &kit.render.tinted });
    }

    /// The package chosen (none: the original game, or the chosen one not found).
    fn chosen(self: *const Launcher) ?packages.Package {
        const file = self.cfg.package.get();
        if (file.len == 0) return null;
        for (self.pkgs) |p| if (std.ascii.eqlIgnoreCase(p.file, file)) return p;
        return null;
    }

    /// Play can start: the game folder found and the choice playable.
    fn playable(self: *const Launcher) bool {
        if (self.folder != .ok) return false;
        return if (self.chosen()) |p| p.supported else true;
    }

    fn showToast(self: *Launcher, s: []const u8) void {
        self.toast = s;
        self.toast_until = c.SDL_GetTicks() + 2600;
    }

    fn openSettings(self: *Launcher, tab: Tab) void {
        self.view = .settings;
        self.tab = if (tab == .play) .display else tab;
    }

    fn deinit(self: *Launcher) void {
        self.pkg_arena.deinit();
        for (self.icons) |t| if (t) |tt| c.SDL_DestroyTexture(tt);
        if (self.background) |t| c.SDL_DestroyTexture(t);
    }

    /// Opens the system folder dialog (non-blocking; the answer comes in `pick`).
    fn changeFolder(self: *Launcher) void {
        if (self.picking) return;
        var start: [1025]u8 = undefined;
        const cur = self.cfg.gamePath();
        const loc: ?[*:0]const u8 = if (cur.len > 0 and cur.len < start.len) blk: {
            @memcpy(start[0..cur.len], cur);
            start[cur.len] = 0;
            break :blk start[0..cur.len :0];
        } else null;
        pick.len = 0;
        pick.done.store(false, .release);
        self.picking = true;
        c.SDL_ShowOpenFolderDialog(Pick.picked, &pick, self.window, loc, false);
    }

    fn pollPick(self: *Launcher) void {
        if (!self.picking or !pick.done.load(.acquire)) return;
        self.picking = false;
        if (pick.len == 0) return;
        self.cfg.setGamePath(pick.buf[0..pick.len]);
        self.check();
    }
};

/// Shift held right now (at startup: show the launcher with `launcher = 0`).
/// shortcut: Linux has no query without a window (X11/Wayland), so only macOS and Windows.
pub fn shiftHeld() bool {
    switch (builtin.os.tag) {
        .windows => return GetAsyncKeyState(0x10) < 0, // VK_SHIFT
        .macos => {
            // CoreGraphics is loaded with SDL; looked up so the build needs no framework.
            const f = std.c.dlsym(@ptrFromInt(std.math.maxInt(usize) - 1), "CGEventSourceFlagsState") orelse return false; // RTLD_DEFAULT
            const flags: *const fn (c_int) callconv(.c) u64 = @ptrCast(@alignCast(f));
            return flags(1) & 0x20000 != 0; // combined session state, kCGEventFlagMaskShift
        },
        else => return false,
    }
}
extern "user32" fn GetAsyncKeyState(key: c_int) callconv(.winapi) c_short;

pub const Start = struct {
    tab: Tab = .play,
    /// A game folder given on the command line (not saved unless Play).
    folder: ?[]const u8 = null,
    /// `--launcher-shot`: draw the window hidden into this PNG and quit.
    shot: ?[]const u8 = null,
};

/// Runs the launcher on `cfg`; on Play `cfg` holds the new settings, saved to `cfg_path`.
pub fn run(io: Io, gpa: std.mem.Allocator, cfg: *config.Config, cfg_dir: ?[]const u8, cfg_path: ?[]const u8, start: Start) !Result {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;
    defer c.SDL_QuitSubSystem(c.SDL_INIT_VIDEO);
    var window: ?*c.SDL_Window = null;
    var renderer: ?*c.SDL_Renderer = null;
    const flags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | (if (start.shot != null) c.SDL_WINDOW_HIDDEN else 0);
    if (!c.SDL_CreateWindowAndRenderer("OpenGorky", 900, 620, flags, &window, &renderer)) return error.SdlWindow;
    defer c.SDL_DestroyWindow(window);
    defer c.SDL_DestroyRenderer(renderer);
    _ = c.SDL_SetWindowMinimumSize(window, 760, 540);
    startup.setWindowIcon(gpa, window.?);
    const r = renderer.?;
    _ = c.SDL_SetRenderDrawBlendMode(r, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderVSync(r, 1);
    const density = @max(1, c.SDL_GetWindowPixelDensity(window));
    _ = c.SDL_SetRenderScale(r, density, density);
    const fonts = try Fonts.init(gpa, r, density);
    defer fonts.deinit(gpa);
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSize(window, &w, &h);
    try clay.init(gpa, fonts, @floatFromInt(w), @floatFromInt(h));
    defer clay.deinit(gpa);

    var l: Launcher = .{ .io = io, .gpa = gpa, .r = r, .window = window.?, .fonts = fonts, .cfg = cfg.*, .cfg_path = cfg_path orelse "opengorky.cfg", .view = .home, .tab = .display, .cfg_dir = cfg_dir, .pkg_arena = .init(gpa) };
    defer l.deinit();
    if (start.tab != .play) l.openSettings(start.tab);
    if (start.folder) |f| l.cfg.setGamePath(f);
    l.background = l.texture(@embedFile("launcher_background"), true);
    l.check();

    if (start.shot) |path| {
        // Hover and boxes need a previous frame's layout.
        for (0..3) |_| present(&l, .{ @floatFromInt(w), @floatFromInt(h) }, 0);
        try writeShot(&l, path);
        return .exit;
    }
    while (l.result == null) {
        l.clicked = false;
        var wheel: f32 = 0;
        var ev: c.SDL_Event = undefined;
        // Idle: wait for input instead of drawing at the display rate (the toast's end too).
        if (c.SDL_WaitEventTimeout(&ev, 100)) {
            var more = true;
            while (more) : (more = c.SDL_PollEvent(&ev)) switch (ev.type) {
                c.SDL_EVENT_QUIT, c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => l.result = .exit,
                c.SDL_EVENT_MOUSE_MOTION => l.mouse = .{ ev.motion.x, ev.motion.y },
                c.SDL_EVENT_WINDOW_MOUSE_LEAVE => l.mouse = .{ -1, -1 },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN => if (ev.button.button == c.SDL_BUTTON_LEFT) {
                    l.down = true;
                    l.clicked = true;
                },
                c.SDL_EVENT_MOUSE_BUTTON_UP => if (ev.button.button == c.SDL_BUTTON_LEFT) {
                    l.down = false;
                },
                c.SDL_EVENT_MOUSE_WHEEL => wheel += ev.wheel.y,
                c.SDL_EVENT_KEY_DOWN => switch (ev.key.key) {
                    // Esc: back from the settings; on the home view, quit.
                    c.SDLK_ESCAPE => if (l.view == .settings) {
                        l.view = .home;
                    } else {
                        l.result = .exit;
                    },
                    c.SDLK_RETURN, c.SDLK_KP_ENTER => if (l.playable()) {
                        l.result = .play;
                    },
                    // The previous / next settings tab.
                    c.SDLK_LEFT, c.SDLK_UP => if (l.view == .settings) {
                        l.tab = if (l.tab == .display) .advanced else @fromBackingInt(@backingInt(l.tab) - 1);
                    },
                    c.SDLK_RIGHT, c.SDLK_DOWN => if (l.view == .settings) {
                        l.tab = if (l.tab == .advanced) .display else @fromBackingInt(@backingInt(l.tab) + 1);
                    },
                    else => {},
                },
                c.SDL_EVENT_WINDOW_RESIZED => _ = c.SDL_GetWindowSize(window, &w, &h),
                else => {},
            };
        }
        l.pollPick();
        present(&l, .{ @floatFromInt(w), @floatFromInt(h) }, wheel);
        _ = c.SDL_RenderPresent(r);
    }
    if (l.result.? == .exit) return .exit;
    cfg.* = l.cfg;
    if (cfg_dir != null and cfg_path != null) cfg.save(io, cfg_dir.?, cfg_path.?);
    return .play;
}

fn present(l: *Launcher, size: [2]f32, wheel: f32) void {
    l.size = size;
    clay.begin(.{ .size = size, .mouse = l.mouse, .down = l.down, .wheel = .{ 0, wheel * 30 }, .dt = 1.0 / 60.0 });
    switch (l.view) {
        .home => home(l),
        .settings => settings(l),
    }
    const cmds = clay.end();
    _ = c.SDL_SetRenderDrawColor(l.r, 0x11, 0x13, 0x10, 255);
    _ = c.SDL_RenderClear(l.r);
    kit.render.draw(l.r, l.fonts, cmds, paint, l);
}

fn writeShot(l: *Launcher, path: []const u8) !void {
    const surf = gfx.readFrame(l.r) orelse return error.ReadPixels;
    defer c.SDL_DestroySurface(surf);
    var img = try og.image.Image.init(l.gpa, @intCast(surf.*.w), @intCast(surf.*.h));
    defer img.deinit(l.gpa);
    const src: [*]const u8 = @ptrCast(surf.*.pixels.?);
    const stride = img.width * 4;
    for (0..img.height) |y| @memcpy(img.pixels[y * stride ..][0..stride], src[y * @as(usize, @intCast(surf.*.pitch)) ..][0..stride]);
    var out: Io.Writer.Allocating = .init(l.gpa);
    defer out.deinit();
    try og.formats.png.write(l.gpa, &out.writer, img);
    try Io.Dir.cwd().writeFile(l.io, .{ .sub_path = path, .data = out.written() });
}

// ---- Layout ----

const center: ui.Clay_ChildAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER };
const middle: ui.Clay_ChildAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER };

/// One line of text; `spacing` points between letters.
fn txt(s: []const u8, pt: u16, col: clay.Color, font_id: u16, spacing: u16) void {
    clay.text(s, .{ .textColor = col, .fontSize = pt, .fontId = font_id, .letterSpacing = spacing, .wrapMode = ui.CLAY_TEXT_WRAP_NONE });
}

/// Text wrapped at words to its parent's width.
fn para(s: []const u8, pt: u16, col: clay.Color) void {
    clay.text(s, .{ .textColor = col, .fontSize = pt, .fontId = regular, .lineHeight = pt + 5 });
}

fn edges(w: u16) ui.Clay_BorderWidth {
    return .{ .left = w, .right = w, .top = w, .bottom = w };
}

fn pad(x: u16, y: u16) ui.Clay_Padding {
    return .{ .left = x, .right = x, .top = y, .bottom = y };
}

fn gap(px: f32) void {
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(1), .height = clay.fixed(px) } } });
}

fn spacer() void {
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() } } });
}

/// `customData` of the backgrounds (paint).
const home_paint = 1;
const settings_paint = 2;

const build_version = @import("version").version;

// ---- Home ----

fn home(l: *Launcher) void {
    clay.open(.{ .id = clay.id("home"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM }, .custom = .{ .customData = @ptrFromInt(home_paint) } });

    // Settings and About, top right.
    clay.open(.{ .layout = .{ .childGap = 9 }, .floating = .{ .offset = .{ .x = -24, .y = 20 }, .attachTo = ui.CLAY_ATTACH_TO_PARENT, .attachPoints = .{ .element = ui.CLAY_ATTACH_POINT_RIGHT_TOP, .parent = ui.CLAY_ATTACH_POINT_RIGHT_TOP } } });
    if (iconButton(l, "open_settings", .settings)) l.openSettings(.display);
    if (iconButton(l, "about", .info)) l.showToast("OpenGorky " ++ build_version ++ " · open-source engine for Gorky 17");
    clay.close();

    // The block in the middle of the height left under the buttons and above the footer.
    gap(56);
    spacer();
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 56 } } });
    txt("INDEPENDENT PROJECT · GORKY 17", 10, theme.eyebrow, bold, 3);
    gap(17);
    clay.open(.{ .layout = .{ .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 0 } });
    brandLine("OPEN", "");
    brandLine("GORKY ", "17");
    clay.close();
    gap(16);
    txt("OPEN-SOURCE ENGINE FOR THE ORIGINAL GAME", 10, theme.sub, regular, 2);
    gap(42);
    clay.open(.{ .layout = .{ .childGap = 18, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_BOTTOM } } });
    playButton(l);
    gameChoice(l);
    clay.close();
    gap(24);
    status(l);
    clay.close();

    spacer();
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .left = 26, .right = 26, .bottom = 18 } } });
    txt("INDEPENDENT · OPEN SOURCE · COMMUNITY DRIVEN", 9, theme.footer, bold, 1);
    spacer();
    txt("BUILD " ++ build_version, 9, theme.footer, bold, 1);
    clay.close();

    toast(l);
    clay.close();
}

/// A line of the title: `text`, then `accent` in orange.
fn brandLine(text: []const u8, accent: []const u8) void {
    clay.open(.{ .layout = .{} });
    clay.text(text, .{ .textColor = theme.white, .fontSize = 96, .fontId = brand, .letterSpacing = 1, .lineHeight = 70, .wrapMode = ui.CLAY_TEXT_WRAP_NONE });
    if (accent.len > 0) clay.text(accent, .{ .textColor = theme.orange, .fontSize = 96, .fontId = brand, .letterSpacing = 1, .lineHeight = 70, .wrapMode = ui.CLAY_TEXT_WRAP_NONE });
    clay.close();
}

/// A square icon button (35 points, framed); true when clicked.
fn iconButton(l: *Launcher, id: []const u8, ic: Icon) bool {
    const eid = clay.id(id);
    const over = clay.pointerOver(eid);
    clay.open(.{ .id = eid, .layout = .{ .sizing = .{ .width = clay.fixed(35), .height = clay.fixed(35) }, .childAlignment = center }, .backgroundColor = rgba(0x161815, 0xb0), .cornerRadius = clay.radius(5), .border = .{ .color = if (over) theme.orange else clay.rgb(0x5a5a52), .width = edges(1) } });
    l.icon(ic, 18, if (over) theme.orange else clay.rgb(0xdddddd));
    clay.close();
    return over and l.clicked;
}

/// Play: off until the game folder is found and the choice can be played.
fn playButton(l: *Launcher) void {
    const ok = l.playable();
    const pid = clay.id("play");
    const over = ok and clay.pointerOver(pid);
    if (over and l.clicked) l.result = .play;
    clay.open(.{
        .id = pid,
        .layout = .{ .sizing = .{ .width = clay.fixed(196), .height = clay.fixed(54) }, .childGap = 10, .childAlignment = center },
        .backgroundColor = if (!ok) clay.rgb(0x2c2a24) else if (over) theme.orange_hover else theme.orange,
        .cornerRadius = clay.radius(5),
        .border = .{ .color = if (ok) theme.orange_line else clay.rgb(0x3e3c34), .width = edges(1) },
    });
    const ink = if (ok) theme.ink else theme.muted;
    l.icon(.play, 16, ink);
    txt("PLAY", 19, ink, bold, 1);
    clay.close();
}

/// What Play starts: the original game or a package of the `mods/` folders (app/packages.zig);
/// a click picks it (kept in the settings' `package`).
fn gameChoice(l: *Launcher) void {
    clay.open(.{ .layout = .{ .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 8 } });
    txt("GAME", 10, theme.label, bold, 1);
    clay.open(.{ .layout = .{ .childGap = 4 } });
    const sel = l.chosen();
    if (segment(l, 0, "Original", sel == null, true)) l.cfg.package.set("");
    for (l.pkgs, 1..) |p, k| {
        if (segment(l, @intCast(k), p.title, sel != null and std.mem.eql(u8, sel.?.file, p.file), p.supported)) l.cfg.package.set(p.file);
    }
    clay.close();
    clay.close();
}

/// One button of the game choice; true when clicked.
fn segment(l: *Launcher, k: u32, label: []const u8, on: bool, enabled: bool) bool {
    const eid = clay.idi("game", k);
    const over = enabled and !on and clay.pointerOver(eid);
    clay.open(.{ .id = eid, .layout = .{ .padding = pad(15, 11), .childAlignment = center }, .backgroundColor = if (on) clay.rgb(0x302319) else rgba(0x171a18, 0xbb), .cornerRadius = clay.radius(4), .border = .{ .color = if (on or over) theme.orange else clay.rgb(0x595a51), .width = edges(1) } });
    txt(label, 12, if (!enabled) theme.muted else if (on) theme.orange else clay.rgb(0xd2cfc6), regular, 0);
    clay.close();
    return over and l.clicked;
}

fn edition(n: u8) ?[]const u8 {
    // Language number (string.tab line 950, formats/strtab.zig); 5 is the Russian edition.
    return switch (n) {
        0, 1 => "English",
        2 => "Polish",
        3 => "German",
        4 => "French",
        5 => "Russian",
        6 => "Dutch",
        7 => "Spanish",
        8 => "Italian",
        9 => "Hungarian",
        else => null,
    };
}

/// The game folder's state (and the chosen package's, when it cannot be played); a folder
/// not found offers the folder dialog right here.
fn status(l: *Launcher) void {
    const sel = l.chosen();
    const missing_pkg = l.cfg.package.get().len > 0 and sel == null;
    const newer = if (sel) |p| !p.supported else false;
    const ok = l.folder == .ok and !newer;
    const lines: [2][]const u8 = switch (l.folder) {
        .ok => if (newer)
            .{ "Package needs a newer OpenGorky", "Update OpenGorky to play it, or choose the original game." }
        else if (missing_pkg)
            .{ "Game folder found", std.fmt.bufPrint(&l.detail_buf, "{s} is not in a mods folder any more: the original game starts.", .{l.cfg.package.get()}) catch "" }
        else
            .{ "Game folder found", if (edition(l.lang)) |e|
                (if (l.avi) std.fmt.bufPrint(&l.detail_buf, "{s} edition. All required files are present.", .{e}) else std.fmt.bufPrint(&l.detail_buf, "{s} edition. No avi folder: videos and some music will not play.", .{e})) catch ""
            else if (l.avi) "All required files are present." else "No avi folder: videos and some music will not play." },
        .unset => .{ "Game folder not set", "Choose the Gorky 17 folder (with dat and avi) to play." },
        .missing => .{ "Game folder not found", "It may have been moved or deleted. Choose the Gorky 17 folder again." },
        .no_dat => .{ "Not a Gorky 17 folder", "It has no dat folder. Choose the folder with dat and avi." },
    };
    clay.open(.{ .layout = .{ .childGap = 10, .childAlignment = middle } });
    const tone = if (ok) theme.ok else theme.err;
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(24), .height = clay.fixed(24) }, .childAlignment = center }, .cornerRadius = clay.radius(12), .border = .{ .color = if (ok) theme.ok_ring else theme.err, .width = edges(1) } });
    l.icon(if (ok) .check else .warning, 13, tone);
    clay.close();
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.growMax(430) }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 4 } });
    txt(lines[0], 12, tone, regular, 0);
    para(lines[1], 10, theme.detail);
    clay.close();
    if (l.folder != .ok) {
        if (secondary(l, "choose_folder", if (l.picking) "Choosing…" else "Choose folder")) l.changeFolder();
    }
    clay.close();
}

/// The About note at the bottom right, for a moment.
fn toast(l: *Launcher) void {
    if (l.toast.len == 0 or c.SDL_GetTicks() >= l.toast_until) return;
    clay.open(.{ .layout = .{ .padding = pad(15, 10) }, .backgroundColor = clay.rgb(0x252921), .cornerRadius = clay.radius(4), .border = .{ .color = clay.rgb(0x7c673d), .width = edges(1) }, .floating = .{ .offset = .{ .x = -24, .y = -55 }, .zIndex = 10, .attachTo = ui.CLAY_ATTACH_TO_PARENT, .attachPoints = .{ .element = ui.CLAY_ATTACH_POINT_RIGHT_BOTTOM, .parent = ui.CLAY_ATTACH_POINT_RIGHT_BOTTOM }, .pointerCaptureMode = ui.CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH } });
    txt(l.toast, 11, theme.white, regular, 0);
    clay.close();
}

/// An orange-outlined button; true when clicked.
fn secondary(l: *Launcher, id: []const u8, label: []const u8) bool {
    const eid = clay.id(id);
    const over = !l.picking and clay.pointerOver(eid);
    clay.open(.{ .id = eid, .layout = .{ .padding = pad(14, 10), .childAlignment = center }, .backgroundColor = if (over) clay.rgb(0x2f281c) else clay.rgb(0x242018), .cornerRadius = clay.radius(4), .border = .{ .color = if (over) theme.orange else clay.rgb(0x6a5840), .width = edges(1) } });
    txt(label, 13, if (l.picking) theme.muted else clay.rgb(0xf3a042), regular, 0);
    clay.close();
    return over and l.clicked;
}

// ---- Settings ----

fn settings(l: *Launcher) void {
    clay.open(.{ .id = clay.id("settings"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 31, .right = 31, .top = 22, .bottom = 18 } }, .custom = .{ .customData = @ptrFromInt(settings_paint) } });

    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childAlignment = middle } });
    txt("SETTINGS", 32, theme.white, heading, 1);
    spacer();
    const bid = clay.id("back");
    const bover = clay.pointerOver(bid);
    if (bover and l.clicked) l.view = .home;
    clay.open(.{ .id = bid, .layout = .{ .padding = pad(4, 6), .childGap = 6, .childAlignment = middle } });
    l.icon(.back, 15, if (bover) theme.orange else theme.back);
    txt("BACK TO LAUNCHER", 13, if (bover) theme.orange else theme.back, regular, 0);
    clay.close();
    clay.close();
    gap(18);

    // Tabs, underlined.
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 25 }, .border = .{ .color = theme.line, .width = .{ .bottom = 1 } } });
    const tabs = [_]struct { Tab, []const u8 }{ .{ .display, "DISPLAY" }, .{ .game, "GAME" }, .{ .advanced, "ADVANCED" } };
    for (tabs, 0..) |t, k| {
        const eid = clay.idi("tab", @intCast(k));
        const on = l.tab == t[0];
        const over = clay.pointerOver(eid);
        if (over and l.clicked) l.tab = t[0];
        clay.open(.{ .id = eid, .layout = .{ .padding = .{ .left = 2, .right = 2, .bottom = 12 } }, .border = .{ .color = if (on) theme.orange else theme.clear, .width = .{ .bottom = 2 } } });
        txt(t[1], 14, if (on) theme.orange else if (over) theme.white else theme.tab, bold, 0);
        clay.close();
    }
    clay.close();

    clay.openScroll(.{ .id = clay.id("pane"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .top = 6, .bottom = 6, .right = 14 } } });
    switch (l.tab) {
        .play, .display => displayTab(l),
        .game => gameTab(l),
        .advanced => advancedTab(l),
    }
    clay.close();

    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .top = 12 }, .childAlignment = middle }, .border = .{ .color = theme.bottom_line, .width = .{ .top = 1 } } });
    txt("SETTINGS ARE SAVED WHEN YOU PRESS PLAY", 11, theme.footer, regular, 1);
    spacer();
    const did = clay.id("done");
    const dover = clay.pointerOver(did);
    if (dover and l.clicked) l.view = .home;
    clay.open(.{ .id = did, .layout = .{ .padding = pad(30, 12), .childAlignment = center }, .backgroundColor = if (dover) theme.orange_hover else theme.orange, .cornerRadius = clay.radius(4) });
    txt("DONE", 14, theme.ink, bold, 1);
    clay.close();
    clay.close();

    clay.close();
}

/// A setting: its title and explanation at the left (growing), its control after;
/// `last`: no line under it. Close with `rowEnd`.
fn row(id: ?ui.Clay_ElementId, title: []const u8, desc: []const u8, last: bool, enabled: bool) void {
    var d: clay.Decl = .{ .layout = .{ .sizing = .{ .width = clay.grow() }, .padding = .{ .top = 13, .bottom = 13 }, .childGap = 18, .childAlignment = middle }, .border = .{ .color = theme.row_line, .width = .{ .bottom = if (last) 0 else 1 } } };
    if (id) |i| d.id = i;
    clay.open(d);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .childGap = 5 } });
    txt(title, 15, if (enabled) theme.white else theme.muted, bold, 0);
    if (desc.len > 0) {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.growMax(560) } } });
        para(desc, 12, if (enabled) theme.desc else theme.muted);
        clay.close();
    }
    clay.close();
}

fn rowEnd() void {
    clay.close();
}

/// A setting with a switch; a click anywhere on the row toggles `v`.
fn toggleRow(l: *Launcher, id: []const u8, title: []const u8, desc: []const u8, v: *bool, last: bool) void {
    const eid = clay.id(id);
    if (clay.pointerOver(eid) and l.clicked) v.* = !v.*;
    row(eid, title, desc, last, true);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(44), .height = clay.fixed(25) } }, .backgroundColor = if (v.*) theme.orange else theme.toggle_off, .cornerRadius = clay.radius(12.5) });
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(19), .height = clay.fixed(19) } }, .backgroundColor = if (v.*) clay.rgb(0x151515) else clay.rgb(0xdddddd), .cornerRadius = clay.radius(9.5), .floating = .{ .offset = .{ .x = if (v.*) 22 else 3, .y = 3 }, .attachTo = ui.CLAY_ATTACH_TO_PARENT } });
    clay.close();
    rowEnd();
}

/// A setting with a choice of `labels` (`sel` highlighted, none for a value not among
/// them); returns the one clicked.
fn choiceRow(l: *Launcher, id: []const u8, title: []const u8, desc: []const u8, labels: []const []const u8, sel: ?usize, enabled: bool, last: bool) ?usize {
    row(null, title, desc, last, enabled);
    var hit: ?usize = null;
    clay.open(.{ .layout = .{ .childGap = 4 } });
    for (labels, 0..) |s, k| {
        const eid = clay.idi(id, @intCast(k));
        const on = sel == k;
        const over = enabled and !on and clay.pointerOver(eid);
        if (over and l.clicked) hit = k;
        clay.open(.{ .id = eid, .layout = .{ .padding = pad(12, 9), .childAlignment = center }, .backgroundColor = if (on and enabled) theme.orange else if (over) clay.rgb(0x25271f) else theme.control, .cornerRadius = clay.radius(3), .border = .{ .color = if (on and enabled) theme.orange else if (over) clay.rgb(0x6a6c62) else theme.control_line, .width = edges(1) } });
        txt(s, 13, if (!enabled) theme.muted else if (on) clay.rgb(0x17130e) else theme.control_text, if (on) bold else regular, 0);
        clay.close();
    }
    clay.close();
    rowEnd();
    return hit;
}

/// `path` cut from the left with "…" (into `buf`) to fit `max` points.
fn fitPath(l: *Launcher, buf: []u8, path: []const u8, max: f32) []const u8 {
    if (max <= 0 or l.fonts.measure(path, regular, 13)[0] <= max) return path;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] & 0xc0 == 0x80) continue; // not mid-letter
        const out = std.fmt.bufPrint(buf, "…{s}", .{path[i..]}) catch return path;
        if (l.fonts.measure(out, regular, 13)[0] <= max) return out;
    }
    return path;
}

/// A path in a field: cut to its width, the whole of it under the pointer; `empty` when none.
fn pathField(l: *Launcher, id: []const u8, buf: []u8, path: []const u8, empty: []const u8, max: f32) void {
    const fid = clay.id(id);
    const shown = fitPath(l, buf, path, if (clay.box(fid)) |b| b.width - 20 else 0);
    clay.open(.{ .id = fid, .layout = .{ .sizing = .{ .width = clay.growMax(max), .height = clay.fixed(37) }, .padding = .{ .left = 11, .right = 11 }, .childAlignment = middle }, .backgroundColor = theme.field, .cornerRadius = clay.radius(3), .border = .{ .color = theme.control_line, .width = edges(1) }, .clip = .{ .horizontal = true } });
    if (path.len > 0) txt(shown, 13, theme.field_text, regular, 0) else txt(empty, 13, theme.muted, regular, 0);
    if (shown.ptr != path.ptr and clay.pointerOver(fid)) {
        clay.open(.{ .layout = .{ .padding = pad(10, 6) }, .backgroundColor = clay.rgb(0x25271f), .cornerRadius = clay.radius(4), .border = .{ .color = theme.line, .width = edges(1) }, .floating = .{ .offset = .{ .x = 0, .y = 4 }, .zIndex = 10, .attachTo = ui.CLAY_ATTACH_TO_PARENT, .attachPoints = .{ .element = ui.CLAY_ATTACH_POINT_LEFT_TOP, .parent = ui.CLAY_ATTACH_POINT_LEFT_BOTTOM }, .pointerCaptureMode = ui.CLAY_POINTER_CAPTURE_MODE_PASSTHROUGH } });
        txt(path, 13, theme.white, regular, 0);
        clay.close();
    }
    clay.close();
}

/// A setting whose control (a path field) sits under its text, the whole width.
fn wideRow(title: []const u8, desc: []const u8, last: bool) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .top = 13, .bottom = 13 }, .childGap = 5 }, .border = .{ .color = theme.row_line, .width = .{ .bottom = if (last) 0 else 1 } } });
    txt(title, 15, theme.white, bold, 0);
    para(desc, 12, theme.desc);
    gap(3);
}

const modes = std.enums.values(Scaling);

fn modeLabel(m: Scaling) []const u8 {
    return switch (m) {
        .integer => "Integer",
        .sharp => "Sharp",
        .smooth => "Smooth",
        .stretch => "Stretch",
        .adaptive => "Adaptive",
        .@"stretch-blur" => "Stretch-blur",
    };
}

fn modeText(m: Scaling) []const u8 {
    return switch (m) {
        .integer => "How the original 640 × 480 image fills the screen. Integer: whole-number zoom, crisp pixels, may leave borders.",
        .sharp => "How the original 640 × 480 image fills the screen. Sharp: fills the window keeping 4:3, sharp pixels.",
        .smooth => "How the original 640 × 480 image fills the screen. Smooth: fills the window keeping 4:3, smoothed.",
        .stretch => "How the original 640 × 480 image fills the screen. Stretch: the whole window, no borders; 4:3 is distorted on wide screens.",
        .adaptive => "How the original 640 × 480 image fills the screen. Adaptive: wide windows show more of large locations; battles and rooms are zoomed to fill the width.",
        .@"stretch-blur" => "How the original 640 × 480 image fills the screen. Stretch-blur: 4:3 in the middle over a blurred, darkened copy instead of black borders.",
    };
}

fn displayTab(l: *Launcher) void {
    var labels: [modes.len][]const u8 = undefined;
    for (modes, &labels) |m, *s| s.* = modeLabel(m);
    if (choiceRow(l, "mode", "Image mode", modeText(l.cfg.scaling), &labels, std.mem.indexOfScalar(Scaling, modes, l.cfg.scaling), true, false)) |k| l.cfg.scaling = modes[k];
    toggleRow(l, "hires", "Sharp models and effects", "Render 3D models and effects at window resolution. Off: 640 × 480 like the original.", &l.cfg.hires, false);
    toggleRow(l, "fullscreen", "Fullscreen", "Start in fullscreen. F11 or Alt+Enter to toggle in the game.", &l.cfg.fullscreen, false);
    if (choiceRow(l, "upscale", "Interface and portraits", "With sharp models on: smoothed edges or the original pixels, just larger.", &.{ "Smooth (xBR)", "Original pixels" }, @backingInt(l.cfg.upscale), l.cfg.hires, false)) |k|
        l.cfg.upscale = @fromBackingInt(@as(u1, @intCast(k)));
    if (choiceRow(l, "renderer", "Models drawn by", "Processor: works everywhere. Video card: much faster with detailed models; the processor is used where there is none.", &.{ "Processor", "Video card" }, @backingInt(l.cfg.renderer), true, true)) |k|
        l.cfg.renderer = @fromBackingInt(@as(u1, @intCast(k)));
}

fn gameTab(l: *Launcher) void {
    const limits = [_]u32{ 30, 60, 0 };
    const lsel = std.mem.indexOfScalar(u32, &limits, l.cfg.fps_limit);
    const ldesc = if (lsel != null) "Frames per second in the active window. The world always runs at 30 ticks per second, like the original." else std.fmt.bufPrint(&l.fps_buf[0], "Frames per second in the active window; now {d}, set in opengorky.cfg. The world always runs at 30 ticks per second.", .{l.cfg.fps_limit}) catch "";
    if (choiceRow(l, "fps", "Frame rate", ldesc, &.{ "30", "60", "Match display" }, lsel, true, false)) |k| l.cfg.fps_limit = limits[k];
    const backs = [_]u32{ 15, 30, 0 };
    const bsel = std.mem.indexOfScalar(u32, &backs, l.cfg.fps_background);
    const bdesc = if (bsel != null) "When the window loses focus. A minimized or fully covered window is not drawn at all." else std.fmt.bufPrint(&l.fps_buf[1], "When the window loses focus; now {d}, set in opengorky.cfg. A minimized or covered window is not drawn.", .{l.cfg.fps_background}) catch "";
    if (choiceRow(l, "fps_bg", "Background frame rate", bdesc, &.{ "15", "30", "Same as active" }, bsel, true, false)) |k| l.cfg.fps_background = backs[k];
    toggleRow(l, "pause_bg", "Pause in background", "Pause the game and sound when the window loses focus or is minimized.", &l.cfg.pause_background, false);
    toggleRow(l, "launcher", "Show launcher at startup", "Off: the game starts at once; hold Shift while starting it to see this window.", &l.cfg.launcher, true);
}

fn advancedTab(l: *Launcher) void {
    toggleRow(l, "debug", "Debug overlays", "Battle status line, health bars and the F1 line.", &l.cfg.debug, false);
    toggleRow(l, "console", "Developer console", "Open debug commands with ` or F2 in the game (heal, win the battle, give items…).", &l.cfg.console, false);
    if (choiceRow(l, "log", "Terminal messages", "How much the game prints to the terminal it was started from.", &.{ "None", "Warnings", "Info" }, @backingInt(l.cfg.log), true, false)) |k|
        l.cfg.log = @fromBackingInt(@as(u2, @intCast(k)));
    wideRow("Game folder", "The installed Gorky 17 (with dat and avi).", false);
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 8, .childAlignment = middle } });
    pathField(l, "game_path", &l.path_buf[0], l.cfg.gamePath(), "No folder chosen", 430);
    if (secondary(l, "browse", if (l.picking) "Choosing…" else "Browse")) l.changeFolder();
    clay.close();
    clay.close();
    wideRow("Settings file", "Play saves the settings here (rewritten with an explanation of every key); Esc and closing the window leave it unchanged.", true);
    pathField(l, "cfg_path", &l.path_buf[1], l.cfg_path, "", 10_000);
    clay.close();
}

// ---- Custom drawing ----

fn paint(ctx: *anyopaque, data: ?*anyopaque, box: c.SDL_FRect) void {
    const l: *Launcher = @ptrCast(@alignCast(ctx));
    drawBackground(l, box, @intFromPtr(data) == settings_paint);
}

fn fcol(hex: u24, a: f32) c.SDL_FColor {
    return .{ .r = @as(f32, @floatFromInt(hex >> 16)) / 255, .g = @as(f32, @floatFromInt((hex >> 8) & 0xff)) / 255, .b = @as(f32, @floatFromInt(hex & 0xff)) / 255, .a = a };
}

/// A rectangle shaded across (`across`: left to right, else top to bottom) from `a` to `b`.
fn shade(r: *c.SDL_Renderer, rect: c.SDL_FRect, a: c.SDL_FColor, b: c.SDL_FColor, across: bool) void {
    const v = [4]c.SDL_Vertex{
        .{ .position = .{ .x = rect.x, .y = rect.y }, .color = a },
        .{ .position = .{ .x = rect.x + rect.w, .y = rect.y }, .color = if (across) b else a },
        .{ .position = .{ .x = rect.x + rect.w, .y = rect.y + rect.h }, .color = b },
        .{ .position = .{ .x = rect.x, .y = rect.y + rect.h }, .color = if (across) a else b },
    };
    const idx = [6]c_int{ 0, 1, 2, 0, 2, 3 };
    _ = c.SDL_RenderGeometry(r, null, &v, 4, &idx, 6);
}

/// The background picture covering `box`, kept at its right edge, under the reference's
/// gradients: the home view darkens it to the left (for the text) and at the bottom; the
/// settings show it faintly behind a nearly solid panel.
fn drawBackground(l: *Launcher, box: c.SDL_FRect, faint: bool) void {
    const r = l.r;
    _ = c.SDL_SetRenderDrawColorFloat(r, 0.067, 0.078, 0.067, 1);
    _ = c.SDL_RenderFillRect(r, &box);
    if (l.background) |t| {
        var tw: f32 = 0;
        var th: f32 = 0;
        _ = c.SDL_GetTextureSize(t, &tw, &th);
        const k = @max(box.w / tw, box.h / th);
        const dst: c.SDL_FRect = .{ .x = box.x + box.w - tw * k, .y = box.y + (box.h - th * k) / 2, .w = tw * k, .h = th * k };
        _ = c.SDL_SetTextureAlphaModFloat(t, if (faint) 0.23 else 1);
        _ = c.SDL_RenderTexture(r, t, null, &dst);
        _ = c.SDL_SetTextureAlphaModFloat(t, 1);
    }
    if (faint) {
        const cut = box.w * 0.35;
        _ = c.SDL_SetRenderDrawColorFloat(r, 0.078, 0.086, 0.075, 1);
        _ = c.SDL_RenderFillRect(r, &.{ .x = box.x, .y = box.y, .w = cut, .h = box.h });
        shade(r, .{ .x = box.x + cut, .y = box.y, .w = box.w - cut, .h = box.h }, fcol(0x141613, 1), fcol(0x141613, 0.87), true);
        return;
    }
    // Left to right: #101311 → f5 at 28% → 9a at 57% → 33 at the edge.
    const stops = [_][2]f32{ .{ 0, 1 }, .{ 0.28, 0.96 }, .{ 0.57, 0.6 }, .{ 1, 0.2 } };
    for (stops[0 .. stops.len - 1], stops[1..]) |s0, s1| {
        shade(r, .{ .x = box.x + box.w * s0[0], .y = box.y, .w = box.w * (s1[0] - s0[0]), .h = box.h }, fcol(0x111411, s0[1]), fcol(0x111411, s1[1]), true);
    }
    // The bottom third: #0e100d at 0.91 down to clear.
    const hb = box.h * 0.32;
    shade(r, .{ .x = box.x, .y = box.y + box.h - hb, .w = box.w, .h = hb }, fcol(0x0e100d, 0), fcol(0x0e100d, 0.91), false);
}

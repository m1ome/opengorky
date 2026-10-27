//! Level editing: a location's layers painted on its map — the picture (`.bkg`, or the
//! `.jpg` of small rooms), the depth that hides actors behind the scenery (`.zbf`), the
//! walk grids of both floors (`.wm`, `.wm2`, 8×8-pixel cells). A brush (and an
//! eyedropper) on the chosen layer, each layer shown or hidden, PNG out and in for the
//! picture and the depth. Strokes undo inside the mode; "Done" (or Save) writes the
//! changed layers into the Store, a step each, in the game's own formats.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const ui = @import("ui");
const og = @import("opengorky");
const Image = og.formats.image.Image;
const ZBuffer = og.formats.zbuffer.ZBuffer;
const lf = og.formats.level_files;
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;
const art = @import("art.zig");
const Doc = @import("level.zig").Doc;
const trigger = @import("trigger.zig");
const newlevel = @import("newlevel.zig");

pub const Layer = enum(u8) { picture, depth, walk, walk2, grid };
pub const Tool = enum { objects, move, brush, picker, area, exit, points, paths, light, camera };
/// The camera gizmo's parts: the centre moves the camera, the rings turn it.
pub const Ring = enum { pan, yaw, pitch, roll };

const Change = struct { idx: u32, old: u32 };
/// One undo step: pixel/cell changes of a stroke, or a whole layer (a PNG loaded).
const Step = struct { layer: Layer, changes: []Change = &.{}, whole: ?[]u8 = null };

pub const Paint = struct {
    /// Layers (null: the level has none) and their Store files.
    pic: ?Image = null,
    pic_file: ?usize = null,
    jpg: bool = false,
    depth: ?ZBuffer = null,
    depth_file: ?usize = null,
    walk: [2]?lf.WalkMap = .{ null, null },
    walk_file: [2]?usize = .{ null, null },
    tex: [4]?*c.SDL_Texture = .{ null, null, null, null },
    show: [5]bool = .{ true, false, true, false, true },
    /// Locked layers take no strokes (shown or not).
    locked: [5]bool = @splat(false),
    /// The walk grids' overlay opacity over the picture (0…1).
    overlay: f32 = 1,
    /// A battle's grid (`.cm`): its cells painted free/blocked, its placement edited.
    grid: ?lf.CombatMap = null,
    grid_file: ?usize = null,
    /// The level shown (its camera maps the background onto the grid).
    doc: ?*const Doc = null,
    /// Areas, items, markers of the level over the layers.
    show_objects: bool = true,
    layer: Layer = .picture,
    tool: Tool = .objects,
    size: u16 = 8,
    color: [4]u8 = .{ 255, 255, 255, 255 },
    depth_value: u8 = 128,
    walk_on: bool = true,
    walk_height: i16 = 0,
    /// The stroke in progress: its changes, which indices it touched, the last point.
    painting: bool = false,
    stroke: std.ArrayList(Change) = .empty,
    touched: std.AutoHashMapUnmanaged(u32, void) = .empty,
    last: [2]f32 = .{ 0, 0 },
    undo: std.ArrayList(Step) = .empty,
    /// A trigger area being drawn: its points (background pixels).
    poly: std.ArrayList([2]i32) = .empty,
    /// The exit tool's outline closed before a level is picked: it waits for one.
    poly_closed: bool = false,
    /// The area picked with the hand (its name), the new name being typed, delete asked once.
    area: [48]u8 = undefined,
    area_len: usize = 0,
    name: [48]u8 = undefined,
    name_len: usize = 0,
    renaming: bool = false,
    confirm_delete: bool = false,
    /// The points tool lists every scene, not only the level's.
    all_scenes: bool = false,
    /// A panel button's action, run at the next frame's start (it reloads the level,
    /// this Paint included — not while the panel lays itself out).
    pending: enum { none, finish, rename, delete, reload } = .none,
    /// Pointer over the map (background pixels), for the brush outline.
    hover: ?[2]f32 = null,
    /// The lamp picked with the light tool, and where it is being dragged (written on release).
    light: ?usize = null,
    light_drag: ?[3]f32 = null,
    /// The picked area being dragged with the hand: where the press was, the offset now.
    area_from: ?[2]f32 = null,
    area_off: [2]f32 = .{ 0, 0 },
    /// The exit tool's level and hint (string.tab id).
    exit_to: [64]u8 = undefined,
    exit_to_len: usize = 0,
    exit_label: u16 = trigger.exit_labels[0],
    /// The camera tool: the part dragged and the pointer's last spot (window pixels);
    /// the camera keys before the move (written once it rests: release, wheel idle).
    cam_ring: ?Ring = null,
    cam_last: [2]f32 = .{ 0, 0 },
    cam_base: ?[Doc.camera_keys.len]f32 = null,
    cam_at: u64 = 0,

    pub fn destroy(self: *Paint, gpa: Allocator) void {
        if (self.pic) |*p| p.deinit(gpa);
        if (self.depth) |*d| d.deinit(gpa);
        if (self.grid) |*g| g.deinit(gpa);
        for (&self.walk) |*w| if (w.*) |*m| m.deinit(gpa);
        for (self.tex) |t| if (t) |x| c.SDL_DestroyTexture(x);
        self.stroke.deinit(gpa);
        self.poly.deinit(gpa);
        self.touched.deinit(gpa);
        for (self.undo.items) |s| freeStep(gpa, s);
        self.undo.deinit(gpa);
        gpa.destroy(self);
    }
};

/// Layer `l` has strokes not undone (every one undone: as when the mode opened).
pub fn changed(p: *const Paint, l: Layer) bool {
    for (p.undo.items) |s| if (s.layer == l) return true;
    return false;
}

fn freeStep(gpa: Allocator, s: Step) void {
    gpa.free(s.changes);
    if (s.whole) |w| gpa.free(w);
}

/// The layers of location `d`, read through the Store (edits since kept).
pub fn open(app: *App, d: *Doc) !*Paint {
    const gpa = app.gpa;
    const p = try gpa.create(Paint);
    p.* = .{};
    errdefer p.destroy(gpa);
    var sb: [256]u8 = undefined;
    var eb: [256]u8 = undefined;
    const sprites = try std.fmt.bufPrint(&sb, "{s}/sprite.dat", .{d.name});
    for ([_][]const u8{ "bkg", "jpg" }) |ext| {
        const f = app.store.file(sprites, try std.fmt.bufPrint(&eb, "background\\{s}.{s}", .{ d.name, ext })) catch continue;
        const bytes = app.store.text(f);
        p.pic = if (std.mem.eql(u8, ext, "bkg")) try og.formats.background.decode(gpa, bytes) else try og.formats.jpeg.decode(gpa, bytes);
        p.pic_file = f;
        p.jpg = std.mem.eql(u8, ext, "jpg");
        break;
    }
    if (app.store.file(sprites, try std.fmt.bufPrint(&eb, "background\\{s}.zbf", .{d.name}))) |f| {
        p.depth = try og.formats.zbuffer.decode(gpa, app.store.text(f));
        p.depth_file = f;
    } else |_| {}
    for ([_][]const u8{ "wm", "wm2" }, 0..) |ext, k| {
        const f = app.store.file(d.level_archive, try std.fmt.bufPrint(&eb, "{s}.{s}", .{ d.name, ext })) catch continue;
        p.walk[k] = try lf.parseWalkMap(gpa, app.store.text(f));
        p.walk_file[k] = f;
    }
    p.doc = d;
    if (d.isBattle()) if (app.store.file(d.level_archive, try std.fmt.bufPrint(&eb, "{s}.cm", .{d.name}))) |f| {
        p.grid = try lf.parseCombatMap(gpa, app.store.text(f));
        p.grid_file = f;
    } else |_| {};
    if (p.pic == null) p.layer = if (p.grid != null) .grid else .walk;
    try textures(app, p);
    return p;
}

pub fn hasLayer(p: *const Paint, l: Layer) bool {
    return has(p, l);
}

fn has(p: *const Paint, l: Layer) bool {
    return switch (l) {
        .picture => p.pic != null,
        .depth => p.depth != null,
        .walk => p.walk[0] != null,
        .walk2 => p.walk[1] != null,
        .grid => p.grid != null,
    };
}

fn makeTexture(app: *App, w: u32, h: u32, nearest: bool) ?*c.SDL_Texture {
    const t = c.SDL_CreateTexture(app.r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, @intCast(w), @intCast(h)) orelse return null;
    _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetTextureScaleMode(t, if (nearest) c.SDL_SCALEMODE_NEAREST else c.SDL_SCALEMODE_LINEAR);
    return t;
}

fn textures(app: *App, p: *Paint) !void {
    if (p.pic) |img| {
        if (p.tex[0] == null) p.tex[0] = makeTexture(app, img.width, img.height, true);
        refresh(app, p, .picture, .{ 0, 0, img.width, img.height });
    }
    if (p.depth) |z| {
        if (p.tex[1] == null) p.tex[1] = makeTexture(app, z.width, z.height, true);
        refresh(app, p, .depth, .{ 0, 0, z.width, z.height });
    }
    for (0..2) |k| if (p.walk[k]) |m| {
        if (p.tex[2 + k] == null) p.tex[2 + k] = makeTexture(app, m.width, m.height, true);
        refresh(app, p, @fromBackingInt(@intCast(2 + k)), .{ 0, 0, m.width, m.height });
    };
}

/// Layer `l`'s texture redrawn in rectangle `r` (x, y, w, h in its own units).
fn refresh(app: *App, p: *Paint, l: Layer, r: [4]u32) void {
    if (l == .grid) return;
    const t = p.tex[@backingInt(l)] orelse return;
    if (r[2] == 0 or r[3] == 0) return;
    const rect: c.SDL_Rect = .{ .x = @intCast(r[0]), .y = @intCast(r[1]), .w = @intCast(r[2]), .h = @intCast(r[3]) };
    switch (l) {
        .picture => {
            const img = p.pic.?;
            _ = c.SDL_UpdateTexture(t, &rect, img.pixels[(r[1] * img.width + r[0]) * 4 ..].ptr, @intCast(img.width * 4));
        },
        .depth, .walk, .walk2 => {
            const buf = app.gpa.alloc(u8, r[2] * r[3] * 4) catch return;
            defer app.gpa.free(buf);
            for (0..r[3]) |y| for (0..r[2]) |x| {
                const px = buf[(y * r[2] + x) * 4 ..][0..4];
                if (l == .depth) {
                    const z = p.depth.?;
                    const v: u8 = @truncate(z.depth[(r[1] + y) * z.width + r[0] + x] >> 8);
                    px.* = .{ v, v, v, 210 };
                } else if (l == .walk or l == .walk2) {
                    const m = p.walk[@backingInt(l) - 2].?;
                    const on = m.at(r[0] + x, r[1] + y).walkable();
                    px.* = if (on) (if (l == .walk) [4]u8{ 60, 230, 110, 110 } else [4]u8{ 70, 140, 255, 110 }) else [4]u8{ 230, 60, 60, 45 };
                }
            };
            _ = c.SDL_UpdateTexture(t, &rect, buf.ptr, @intCast(r[2] * 4));
        },
        .grid => {},
    }
}

/// The map with the shown layers, the brush outline over it.
pub fn draw(app: *App, p: *Paint, d: *Doc, rect: c.SDL_FRect) void {
    const r = app.r;
    const clip: c.SDL_Rect = .{ .x = @intFromFloat(rect.x), .y = @intFromFloat(rect.y), .w = @intFromFloat(rect.w), .h = @intFromFloat(rect.h) };
    _ = c.SDL_SetRenderClipRect(r, &clip);
    defer _ = c.SDL_SetRenderClipRect(r, null);
    if (!d.fitted) d.fit(rect);
    const o = screen(d, rect, .{ 0, 0 });
    for ([_]Layer{ .picture, .depth, .walk, .walk2 }) |l| {
        if (!p.show[@backingInt(l)]) continue;
        const t = p.tex[@backingInt(l)] orelse continue;
        var tw: f32 = 0;
        var th: f32 = 0;
        _ = c.SDL_GetTextureSize(t, &tw, &th);
        const k: f32 = if (l == .walk or l == .walk2) lf.WalkMap.cell_size else 1;
        // The walk grids at the overlay opacity (the concept's slider).
        _ = c.SDL_SetTextureAlphaModFloat(t, if (l == .walk or l == .walk2) p.overlay else 1);
        _ = c.SDL_RenderTexture(r, t, null, &.{ .x = o[0], .y = o[1], .w = tw * k * d.zoom, .h = th * k * d.zoom });
    }
    // A battle: its grid as edited here (hidden with its eye).
    d.grid_view = if (p.show[@backingInt(Layer.grid)]) p.grid else null;
    d.grid_hidden = p.grid != null and !p.show[@backingInt(Layer.grid)];
    defer {
        d.grid_view = null;
        d.grid_hidden = false;
    }
    // The Objects tool: the picked object with its turn handles, as the view mode once.
    if (p.show_objects) d.draw(r, app.font, rect, if (p.tool == .objects) app.selected else pickedIndex(p, d), false, false) else if (d.grid_view) |g| d.drawGridOnly(r, app.font, rect, g);
    if (p.tool == .area or p.tool == .exit) drawPoly(r, p, d, rect);
    drawMoved(r, p, d, rect);
    if (p.tool == .points) drawPoints(app, d, rect);
    if (p.tool == .paths) @import("paths.zig").draw(app, d, rect);
    if (p.tool == .light) drawLights(app, p, d, rect);
    if (p.tool == .camera) drawGizmo(app, p, d, rect);
    // The brush: a square of its size (a cell's multiple on the walk grids).
    if (p.tool != .move and p.tool != .camera and p.tool != .objects) if (p.hover) |h| {
        const s: f32 = brushPixels(p);
        const cell: f32 = if (p.layer == .walk or p.layer == .walk2) lf.WalkMap.cell_size else 1;
        const x0 = @floor((h[0] - s / 2) / cell) * cell;
        const y0 = @floor((h[1] - s / 2) / cell) * cell;
        const a = screen(d, rect, .{ x0, y0 });
        _ = c.SDL_SetRenderDrawColor(r, 255, 255, 255, 200);
        _ = c.SDL_RenderRect(r, &.{ .x = a[0], .y = a[1], .w = @max(1, s * d.zoom), .h = @max(1, s * d.zoom) });
    };
}

fn pickedIndex(p: *const Paint, d: *const Doc) ?usize {
    if (p.area_len == 0) return null;
    for (d.objects.items, 0..) |o, i| if (o.kind == .area and std.ascii.eqlIgnoreCase(o.name, p.area[0..p.area_len])) return i;
    return null;
}

/// A hand press on the map: the area under it picked and its drag started (true),
/// or none picked (false: the hand drags the map).
pub fn pickAt(p: *Paint, d: *const Doc, v: c.SDL_FRect, s: [2]f32) bool {
    p.renaming = false;
    p.confirm_delete = false;
    p.area_len = 0;
    const i = d.pick(v, s) orelse return false;
    const o = d.objects.items[i];
    if (o.kind != .area) return false;
    pickName(p, o.name);
    p.area_from = d.toBackground(v, s);
    p.area_off = .{ 0, 0 };
    return true;
}

pub fn pickName(p: *Paint, name: []const u8) void {
    p.area_len = @min(name.len, p.area.len);
    @memcpy(p.area[0..p.area_len], name[0..p.area_len]);
    p.name = p.area;
    p.name_len = p.area_len;
}

/// The picked area dragged to background point `b`.
pub fn areaDrag(p: *Paint, b: [2]f32) void {
    const from = p.area_from orelse return;
    p.area_off = .{ @round(b[0] - from[0]), @round(b[1] - from[1]) };
}

/// Released: the dragged area written where it is (a move under 2 pixels is a click).
/// The level reloads: this Paint is gone after a move.
pub fn areaRelease(app: *App, p: *Paint) void {
    if (p.area_from == null) return;
    p.area_from = null;
    const off: [2]i32 = .{ @intFromFloat(p.area_off[0]), @intFromFloat(p.area_off[1]) };
    p.area_off = .{ 0, 0 };
    if (@abs(off[0]) + @abs(off[1]) < 2) return;
    var nb: [48]u8 = undefined;
    const name = nb[0..p.area_len];
    @memcpy(name, p.area[0..p.area_len]);
    app.moveArea(name, off);
}

/// The dragged area's outline where it would go.
fn drawMoved(r: *c.SDL_Renderer, p: *const Paint, d: *const Doc, rect: c.SDL_FRect) void {
    if (p.area_from == null or p.area_len == 0) return;
    const i = pickedIndex(p, d) orelse return;
    const pts = d.objects.items[i].poly orelse return;
    if (pts.len < 2) return;
    _ = c.SDL_SetRenderDrawColor(r, 255, 255, 255, 230);
    var prev = screen(d, rect, .{ pts[pts.len - 1][0] + p.area_off[0], pts[pts.len - 1][1] + p.area_off[1] });
    for (pts) |pt| {
        const q = screen(d, rect, .{ pt[0] + p.area_off[0], pt[1] + p.area_off[1] });
        _ = c.SDL_RenderLine(r, prev[0], prev[1], q[0], q[1]);
        prev = q;
    }
}

/// The panel's button action, if one waits (start of a frame).
pub fn runPending(app: *App, p: *Paint) void {
    if (p.cam_ring == null and c.SDL_GetTicks() > p.cam_at + 400) camCommit(app, p);
    const what = p.pending;
    p.pending = .none;
    switch (what) {
        .none => {},
        .finish => finishArea(app, p),
        .reload => app.reloadLevel(),
        .rename => rename(app, p),
        .delete => {
            var ob: [48]u8 = undefined;
            const old = ob[0..p.area_len];
            @memcpy(old, p.area[0..p.area_len]);
            app.deleteArea(old);
        },
    }
}

/// Typing into the new name.
pub fn typeName(p: *Paint, s: []const u8) void {
    for (s) |ch| {
        if (p.name_len == p.name.len or !(std.ascii.isAlphanumeric(ch) or ch == '_')) continue;
        p.name[p.name_len] = ch;
        p.name_len += 1;
    }
}

/// A key while the name is typed: Backspace, Enter (rename), Esc (stop).
pub fn nameKey(app: *App, p: *Paint, k: c.SDL_Keycode) void {
    switch (k) {
        c.SDLK_BACKSPACE => p.name_len -|= 1,
        c.SDLK_RETURN, c.SDLK_KP_ENTER => rename(app, p),
        else => p.renaming = false,
    }
}

fn rename(app: *App, p: *Paint) void {
    p.renaming = false;
    var ob: [48]u8 = undefined;
    var nb: [48]u8 = undefined;
    const old = ob[0..p.area_len];
    @memcpy(old, p.area[0..p.area_len]);
    const new = nb[0..p.name_len];
    @memcpy(new, p.name[0..p.name_len]);
    if (std.mem.eql(u8, old, new)) return;
    // The mode opens anew over the reloaded level: this Paint is gone after.
    app.renameArea(old, new);
}

const points = @import("paint_points.zig").points;
const drawPoints = @import("paint_points.zig").drawPoints;
pub const pointClick = @import("paint_points.zig").pointClick;
pub const dropPoint = @import("paint_points.zig").dropPoint;
const pointsPanel = @import("paint_points.zig").pointsPanel;

const lights = @import("paint_lights.zig").lights;
pub const dropLight = @import("paint_lights.zig").dropLight;
const drawLights = @import("paint_lights.zig").drawLights;
pub const lightPress = @import("paint_lights.zig").lightPress;
pub const lightDrag = @import("paint_lights.zig").lightDrag;
pub const lightRelease = @import("paint_lights.zig").lightRelease;
pub const stepper = @import("paint_lights.zig").stepper;
const lightsPanel = @import("paint_lights.zig").lightsPanel;

const drawPoly = @import("paint_areas.zig").drawPoly;
pub const areaClick = @import("paint_areas.zig").areaClick;
pub const finishArea = @import("paint_areas.zig").finishArea;
const exitPanel = @import("paint_areas.zig").exitPanel;
const areaPanel = @import("paint_areas.zig").areaPanel;

pub fn screen(d: *const Doc, rect: c.SDL_FRect, b: [2]f32) [2]f32 {
    return .{ rect.x + (b[0] - d.origin[0]) * d.zoom, rect.y + (b[1] - d.origin[1]) * d.zoom };
}

/// The brush side in background pixels (walk grids: whole cells).
fn brushPixels(p: *const Paint) f32 {
    const s: f32 = @floatFromInt(p.size);
    return if (p.layer == .walk or p.layer == .walk2) @max(lf.WalkMap.cell_size, @round(s / 8) * 8) else s;
}

/// Pressed on the map at background point `b`: the eyedropper, or a stroke begins.
pub fn press(app: *App, p: *Paint, b: [2]f32) void {
    if (!has(p, p.layer) or p.tool == .move) return;
    if (p.locked[@backingInt(p.layer)]) return app.setStatus(tx.st_layer_locked, .{});
    if (p.tool == .picker) {
        pick(p, b);
        p.tool = .brush;
        return;
    }
    p.painting = true;
    p.stroke.clearRetainingCapacity();
    p.touched.clearRetainingCapacity();
    // A cell made walkable takes the floor height of where the stroke began, if walkable.
    if (p.layer == .walk or p.layer == .walk2) if (cellAt(p, b)) |ci| {
        const cell = p.walk[@backingInt(p.layer) - 2].?.cells[ci];
        if (cell.walkable()) p.walk_height = cell.height;
    };
    dab(app, p, b);
    p.last = b;
}

/// Dragged to `b`: dabs along the way (no gaps when the pointer moves fast).
pub fn drag(app: *App, p: *Paint, b: [2]f32) void {
    if (!p.painting) return;
    const dx = b[0] - p.last[0];
    const dy = b[1] - p.last[1];
    const step = @max(1, brushPixels(p) / 3);
    const n: usize = @intFromFloat(@ceil(@sqrt(dx * dx + dy * dy) / step));
    for (1..n + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        dab(app, p, .{ p.last[0] + dx * t, p.last[1] + dy * t });
    }
    p.last = b;
}

/// Released: the stroke is one undo step.
pub fn release(app: *App, p: *Paint) void {
    if (!p.painting) return;
    p.painting = false;
    if (p.stroke.items.len == 0) return;
    const changes = app.gpa.dupe(Change, p.stroke.items) catch return;
    p.undo.append(app.gpa, .{ .layer = p.layer, .changes = changes }) catch app.gpa.free(changes);
}

fn cellAt(p: *const Paint, b: [2]f32) ?usize {
    const m = p.walk[@backingInt(p.layer) - 2] orelse return null;
    if (b[0] < 0 or b[1] < 0) return null;
    const x: usize = @intFromFloat(b[0] / lf.WalkMap.cell_size);
    const y: usize = @intFromFloat(b[1] / lf.WalkMap.cell_size);
    if (x >= m.width or y >= m.height) return null;
    return y * m.width + x;
}

fn pick(p: *Paint, b: [2]f32) void {
    switch (p.layer) {
        .picture => {
            const img = p.pic.?;
            const x: usize = @intFromFloat(@max(0, b[0]));
            const y: usize = @intFromFloat(@max(0, b[1]));
            if (x < img.width and y < img.height) p.color = img.pixels[(y * img.width + x) * 4 ..][0..4].*;
        },
        .depth => {
            const z = p.depth.?;
            const x: usize = @intFromFloat(@max(0, b[0]));
            const y: usize = @intFromFloat(@max(0, b[1]));
            if (x < z.width and y < z.height) p.depth_value = @truncate(z.depth[y * z.width + x] >> 8);
        },
        .walk, .walk2 => if (cellAt(p, b)) |ci| {
            const cell = p.walk[@backingInt(p.layer) - 2].?.cells[ci];
            p.walk_on = cell.walkable();
            if (cell.walkable()) p.walk_height = cell.height;
        },
        .grid => if (gridCell(p, b)) |ci| {
            p.walk_on = !p.grid.?.blocked[ci];
        },
    }
}

/// The battle grid cell (index into `blocked`) under background point `b`, if any:
/// the floor plane under it as the editor's battle view takes it (Doc.gridAt).
fn gridCell(p: *const Paint, b: [2]f32) ?usize {
    const cm = p.grid orelse return null;
    const d = p.doc orelse return null;
    const h = switch (d.world.cam) {
        .persp => |pc| cm.center[2] - pc.zlevel / pc.scale,
        .ortho => cm.center[2],
    };
    const w = d.world.cam.unproject(b[0], b[1], h);
    const g = cm.toGrid(w[0], w[1]);
    if (g[0] < 0 or g[1] < 0) return null;
    const x: usize = @intFromFloat(g[0]);
    const y: usize = @intFromFloat(g[1]);
    if (x >= cm.width or y >= cm.height) return null;
    return y * cm.width + x;
}

/// The brush once at `b` on the chosen layer; each value's old one kept once a stroke.
fn dab(app: *App, p: *Paint, b: [2]f32) void {
    const s = brushPixels(p);
    switch (p.layer) {
        .picture, .depth => {
            const w: u32 = if (p.layer == .picture) p.pic.?.width else p.depth.?.width;
            const h: u32 = if (p.layer == .picture) p.pic.?.height else p.depth.?.height;
            const x0: i64 = @intFromFloat(@floor(b[0] - s / 2));
            const y0: i64 = @intFromFloat(@floor(b[1] - s / 2));
            const n: i64 = @intFromFloat(s);
            const ax: u32 = @intCast(std.math.clamp(x0, 0, w));
            const ay: u32 = @intCast(std.math.clamp(y0, 0, h));
            const bx: u32 = @intCast(std.math.clamp(x0 + n, 0, w));
            const by: u32 = @intCast(std.math.clamp(y0 + n, 0, h));
            for (ay..by) |y| for (ax..bx) |x| {
                const i: u32 = @intCast(y * w + x);
                if (p.layer == .picture) {
                    const px = p.pic.?.pixels[i * 4 ..][0..4];
                    keep(app, p, i, std.mem.readInt(u32, px, .little));
                    px.* = .{ p.color[0], p.color[1], p.color[2], 255 };
                } else {
                    const z = &p.depth.?.depth[i];
                    keep(app, p, i, z.*);
                    z.* = @as(u16, p.depth_value) << 8;
                }
            };
            refresh(app, p, p.layer, .{ ax, ay, bx -| ax, by -| ay });
        },
        .walk, .walk2 => {
            const m = &p.walk[@backingInt(p.layer) - 2].?;
            const cells: i64 = @intFromFloat(s / lf.WalkMap.cell_size);
            const cx: i64 = @intFromFloat(@floor(b[0] / lf.WalkMap.cell_size));
            const cy: i64 = @intFromFloat(@floor(b[1] / lf.WalkMap.cell_size));
            const x0 = cx - @divFloor(cells - 1, 2);
            const y0 = cy - @divFloor(cells - 1, 2);
            const ax: u32 = @intCast(std.math.clamp(x0, 0, m.width));
            const ay: u32 = @intCast(std.math.clamp(y0, 0, m.height));
            const bx: u32 = @intCast(std.math.clamp(x0 + cells, 0, m.width));
            const by: u32 = @intCast(std.math.clamp(y0 + cells, 0, m.height));
            for (ay..by) |y| for (ax..bx) |x| {
                const i: u32 = @intCast(y * m.width + x);
                const cell = &m.cells[i];
                keep(app, p, i, @as(u32, cell.kind) | @as(u32, @as(u16, @bitCast(cell.height))) << 8);
                if (p.walk_on) {
                    // A cell that wasn't floor gets the stroke's floor height.
                    if (!cell.walkable()) cell.height = p.walk_height;
                    cell.kind |= 1;
                } else cell.kind &= ~@as(u8, 1);
            };
            refresh(app, p, p.layer, .{ ax, ay, bx -| ax, by -| ay });
        },
        // One cell a dab: battle cells are much bigger than the brush.
        .grid => if (gridCell(p, b)) |ci| {
            const cell = &p.grid.?.blocked[ci];
            keep(app, p, @intCast(ci), @intFromBool(cell.*));
            cell.* = !p.walk_on;
        },
    }
}

fn keep(app: *App, p: *Paint, i: u32, old: u32) void {
    const g = p.touched.getOrPut(app.gpa, i) catch return;
    if (g.found_existing) return;
    p.stroke.append(app.gpa, .{ .idx = i, .old = old }) catch {};
}

/// The last stroke (or loaded PNG) undone.
pub fn undo(app: *App, p: *Paint) bool {
    const s = p.undo.pop() orelse return false;
    defer freeStep(app.gpa, s);
    if (s.whole) |w| {
        switch (s.layer) {
            .picture => @memcpy(p.pic.?.pixels, w),
            .depth => @memcpy(std.mem.sliceAsBytes(p.depth.?.depth), w),
            // The grid's placement or size changed: its `.cm` text before.
            .grid => if (lf.parseCombatMap(app.gpa, w)) |g| {
                p.grid.?.deinit(app.gpa);
                p.grid = g;
            } else |_| {},
            else => {},
        }
    } else {
        var k = s.changes.len;
        while (k > 0) {
            k -= 1;
            const ch = s.changes[k];
            switch (s.layer) {
                .picture => std.mem.writeInt(u32, p.pic.?.pixels[ch.idx * 4 ..][0..4], ch.old, .little),
                .depth => p.depth.?.depth[ch.idx] = @truncate(ch.old),
                .walk, .walk2 => {
                    const cell = &p.walk[@backingInt(s.layer) - 2].?.cells[ch.idx];
                    cell.kind = @truncate(ch.old);
                    cell.height = @bitCast(@as(u16, @truncate(ch.old >> 8)));
                },
                .grid => p.grid.?.blocked[ch.idx] = ch.old != 0,
            }
        }
    }
    textures(app, p) catch {};
    return true;
}

/// Changed layers written into the Store (a step each, in the game's formats).
pub fn commit(app: *App, p: *Paint) !void {
    const gpa = app.gpa;
    camCommit(app, p);
    if (changed(p, .picture)) if (p.pic_file) |f| {
        const bytes = if (p.jpg) try og.formats.jpeg.encode(gpa, p.pic.?, 92) else try og.formats.background.encode(gpa, p.pic.?);
        try app.store.replaceLabeled(f, bytes, tx.get(tx.lp_step_picture));
    };
    if (changed(p, .grid)) if (p.grid_file) |f| try app.store.replaceLabeled(f, try lf.encodeCombatMap(gpa, p.grid.?), tx.get(tx.lp_step_grid));
    if (changed(p, .depth)) if (p.depth_file) |f| try app.store.replaceLabeled(f, try og.formats.zbuffer.encode(gpa, p.depth.?), tx.get(tx.lp_step_depth));
    for (0..2) |k| if (changed(p, @fromBackingInt(@intCast(2 + k)))) if (p.walk_file[k]) |f| {
        try app.store.replaceLabeled(f, try lf.encodeWalkMap(gpa, p.walk[k].?), tx.get(if (k == 0) tx.lp_step_walk else tx.lp_step_walk2));
    };
}

/// Layer `l` from a PNG (fitted to its size; the depth from the grey); one step.
fn importLayer(app: *App, p: *Paint, l: Layer, path: []const u8) !void {
    var img = try art.readPng(app, path);
    defer img.deinit(app.gpa);
    const w = if (l == .picture) p.pic.?.width else p.depth.?.width;
    const h = if (l == .picture) p.pic.?.height else p.depth.?.height;
    var fit = try art.resize(app.gpa, img, w, h);
    defer fit.deinit(app.gpa);
    const old = try app.gpa.dupe(u8, if (l == .picture) p.pic.?.pixels else std.mem.sliceAsBytes(p.depth.?.depth));
    errdefer app.gpa.free(old);
    try p.undo.append(app.gpa, .{ .layer = l, .whole = old });
    if (l == .picture) {
        for (0..w * h) |i| p.pic.?.pixels[i * 4 ..][0..4].* = .{ fit.pixels[i * 4], fit.pixels[i * 4 + 1], fit.pixels[i * 4 + 2], 255 };
    } else for (0..w * h) |i| {
        p.depth.?.depth[i] = @as(u16, fit.pixels[i * 4]) << 8;
    }
    try textures(app, p);
}

/// The depth layer put on the exe's scale. A depth made elsewhere (a render, a depth
/// estimator) has its own: the exe compares a model's W-buffer depth with the `.zbf`
/// value as is (0x41cf07: z = far − v·tl/65536; without a `.cfg` far = tl =
/// frontPlane − backPlane), and feet sink into a floor it takes for nearer. On
/// walkable floor cells each value is paired with the one the exe expects there, a
/// line fitted (lineFit), every pixel mapped by it, the floor two steps farther so
/// feet stand on it. One undo step. Returns the floor's median mismatch before, in
/// `.zbf` steps.
pub fn fitDepth(app: *App, p: *Paint, d: *Doc) !f32 {
    const z = &(p.depth orelse return error.NoDepth);
    const cam = switch (d.world.cam) {
        .persp => |pc| pc,
        .ortho => return error.NotPerspective,
    };
    var cb: [160]u8 = undefined;
    if (app.store.find(try std.fmt.bufPrint(&cb, "{s}/sprite.dat", .{d.name}), try std.fmt.bufPrint(cb[80..], "background\\{s}.cfg", .{d.name})) != null) return error.HasCfg;
    const l = d.world.level orelse return error.NoLevel;
    const tl = og.fields.getF(l, "frontPlane") - og.fields.getF(l, "backPlane");
    if (tl <= 0) return error.NoPlanes;
    const a = app.frame.allocator();
    // Floor points: walkable cells of a location, free cells of a battle grid.
    var floor: std.ArrayList([3]f32) = .empty;
    if (p.walk[0]) |m| {
        var y: usize = 0;
        while (y < m.height) : (y += 2) {
            var x: usize = 0;
            while (x < m.width) : (x += 2) {
                if (!m.at(x, y).walkable()) continue;
                const cs = lf.WalkMap.cell_size;
                const bg: [2]f32 = .{ @as(f32, @floatFromInt(x * cs)) + cs / 2, @as(f32, @floatFromInt(y * cs)) + cs / 2 };
                try floor.append(a, og.world.floor.groundAt(d.world, bg));
            }
        }
    } else if (p.grid) |g| {
        for (0..g.height) |y| for (0..g.width) |x| {
            if (g.blocked[y * g.width + x]) continue;
            for ([_][2]f32{ .{ 0.25, 0.25 }, .{ 0.75, 0.25 }, .{ 0.25, 0.75 }, .{ 0.75, 0.75 } }) |f|
                try floor.append(a, g.toWorld(@as(f32, @floatFromInt(x)) + f[0], @as(f32, @floatFromInt(y)) + f[1]));
        };
    } else return error.NoFloor;
    var pts: std.ArrayList([2]f32) = .empty;
    for (floor.items) |fp| {
        const q = cam.project(fp);
        if (q.x < 0 or q.y < 0 or q.x >= @as(f32, @floatFromInt(z.width)) or q.y >= @as(f32, @floatFromInt(z.height))) continue;
        const g: f32 = @floatFromInt(z.depth[@as(usize, @intFromFloat(q.y)) * z.width + @as(usize, @intFromFloat(q.x))]);
        try pts.append(a, .{ g, (tl + q.depth) * 65536 / tl });
    }
    var miss = try a.alloc(f32, pts.items.len);
    for (pts.items, 0..) |pt, i| miss[i] = @abs(pt[0] - pt[1]) / 256;
    std.mem.sort(f32, miss, {}, std.sort.asc(f32));
    const ab = og.render.depth_fit.lineFit(pts.items) orelse return error.TooLittleFloor;
    try p.undo.append(app.gpa, .{ .layer = .depth, .whole = try app.gpa.dupe(u8, std.mem.sliceAsBytes(z.depth)) });
    for (z.depth) |*v| {
        const nv = ab[0] * @as(f32, @floatFromInt(v.*)) + ab[1] - 2 * 256;
        // The game's `.zbf` keeps the high byte only.
        v.* = @as(u16, @intFromFloat(std.math.clamp(nv, 0, 65535))) & 0xff00;
    }
    try textures(app, p);
    return if (miss.len > 0) miss[miss.len / 2] else 0;
}

/// Layer `l` as a PNG (the depth as grey: its high byte, the low one is 0 in the game).
fn exportLayer(app: *App, p: *Paint, l: Layer, path: []const u8) !void {
    if (l == .picture) return art.writePng(app, p.pic.?, path);
    const z = p.depth.?;
    var img = try Image.init(app.gpa, z.width, z.height);
    defer img.deinit(app.gpa);
    for (z.depth, 0..) |v, i| {
        const g: u8 = @truncate(v >> 8);
        img.pixels[i * 4 ..][0..4].* = .{ g, g, g, 255 };
    }
    try art.writePng(app, img, path);
}

/// The right-hand panel of the mode: layers, the tool and its setting, PNG, done.
pub fn panel(app: *App, a: Allocator, p: *Paint) void {
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(app.split(.objects)), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM }, .backgroundColor = theme.panel, .border = .{ .color = theme.line, .width = .{ .left = 1 } } });
    if (@import("main.zig").inspectorTabs(app)) {
        @import("main.zig").inspectorHistory(app, a);
        return clay.close();
    }
    // Everything scrolls (a battle's grid and camera are taller than a window).
    clay.openScroll(.{ .id = clay.id("lp_scroll"), .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM } });
    main.panelHeader(tx.get(tx.lp_title));
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 }, .childGap = 4 } });
    const names = [_]tx.Msg{ tx.lp_picture, tx.lp_depth, tx.lp_walk, tx.lp_walk2, tx.lp_grid };
    for ([_]Layer{ .picture, .depth, .walk, .walk2, .grid }, 0..) |l, k| {
        if (!has(p, l)) continue;
        const r = layerRow(app, @intCast(k), tx.get(names[k]), p.show[k], p.locked[k], p.layer == l, changed(p, l));
        if (r.eye) p.show[k] = !p.show[k] else if (r.lock) p.locked[k] = !p.locked[k] else if (r.row) {
            p.layer = l;
            p.show[k] = true;
        }
    }
    // The level's objects: shown or not, never painted.
    if (layerRow(app, 9, tx.get(tx.lp_objects), p.show_objects, null, false, false).any()) p.show_objects = !p.show_objects;
    if (p.jpg) clay.text(tx.get(tx.lp_jpg), .{ .textColor = theme.dim, .fontSize = 11, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    actorScaleRow(app, a);
    if (p.layer == .depth) backgroundCfg(app, a);
    clay.close();

    main.panelHeader(tx.get(switch (p.tool) {
        .objects => tx.lp_objects_tool,
        .move => tx.lp_move,
        .brush => tx.lp_brush,
        .picker => tx.spr_picker,
        .light => tx.lp_lights,
        .area => tx.lp_area,
        .exit => tx.lp_exit,
        .points => tx.lp_points,
        .paths => tx.lp_paths,
        .camera => tx.lp_cam_tool,
    }));
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 10, .right = 10, .top = 8, .bottom = 8 }, .childGap = 8 } });
    if (p.tool == .objects) {
        @import("main.zig").objectsBlock(app, a);
    } else if (p.tool == .brush or p.tool == .picker) {
        clay.open(.{ .layout = .{ .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(140) } } });
        txt(tx.get(tx.lp_brush_size), 13, theme.text, font_mod.regular);
        clay.close();
        if (main.button(app, "lp_smaller", "-", false)) p.size = @max(1, p.size / 2);
        if (numBox(app, a, "lp_size_box", "px", brushPixels(p), 90)) |v| p.size = @intFromFloat(std.math.clamp(@round(v), 1, 256));
        if (main.button(app, "lp_bigger", "+", false)) p.size = @min(256, p.size * 2);
        clay.close();
    }
    if (p.tool == .objects) {} else if (p.tool == .points) {
        pointsPanel(app, a, p);
    } else if (p.tool == .paths) {
        if (app.doc) |d| @import("paths.zig").panel(app, a, d);
    } else if (p.tool == .light) {
        lightsPanel(app, a, p);
    } else if (p.tool == .camera) {
        clay.text(tx.get(tx.lp_cam_tool_hint), .{ .textColor = theme.text, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
        cameraPanel(app, a, p, false);
    } else if (p.tool == .exit) {
        exitPanel(app, a, p);
    } else if (p.tool == .area) {
        clay.text(tx.get(tx.lp_area_hint), .{ .textColor = theme.text, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
        if (p.poly.items.len >= 3) if (main.button(app, "lp_area_done", tx.get(tx.lp_area_done), true)) {
            p.pending = .finish;
        };
    } else switch (p.layer) {
        .picture => {
            clay.open(.{ .layout = .{ .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
            txt(tx.get(tx.lp_color), 13, theme.text, font_mod.regular);
            clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(28), .height = clay.fixed(20) } }, .backgroundColor = .{ .r = @floatFromInt(p.color[0]), .g = @floatFromInt(p.color[1]), .b = @floatFromInt(p.color[2]), .a = 255 }, .cornerRadius = clay.radius(3) });
            clay.close();
        },
        .depth => {
            clay.open(.{ .layout = .{ .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
            txt(tx.alloc(a, tx.lp_depth_value, .{p.depth_value}), 13, theme.text, font_mod.regular);
            if (main.button(app, "lp_d_m", "-8", false)) p.depth_value -|= 8;
            if (main.button(app, "lp_d_p", "+8", false)) p.depth_value +|= 8;
            clay.close();
            clay.text(tx.get(tx.lp_depth_fit_hint), .{ .textColor = theme.dim, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
            if (main.button(app, "lp_depth_fit", tx.get(tx.lp_depth_fit), false)) if (app.doc) |d| {
                if (fitDepth(app, p, d)) |before| app.setStatus(tx.st_depth_fit, .{before}) else |err| app.setStatus(tx.st_set_failed, .{err});
            };
        },
        .walk, .walk2 => {
            // As the concept's: the brush mode as two halves, the overlay's opacity.
            clay.open(.{ .layout = .{ .childGap = 8, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
            clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(140) } } });
            txt(tx.get(tx.lp_brush_mode), 13, theme.text, font_mod.regular);
            clay.close();
            if (main.segmented(app, "lp_mode", &.{ tx.get(tx.lp_walk_on), tx.get(tx.lp_walk_off) }, if (p.walk_on) 0 else 1)) |k| p.walk_on = k == 0;
            clay.close();
            clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 18, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
            clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(130) } } });
            txt(tx.get(tx.lp_overlay), 13, theme.text, font_mod.regular);
            clay.close();
            if (main.slider(app, "lp_overlay", p.overlay)) |v| p.overlay = v;
            txt(std.fmt.allocPrint(a, "{d:.0}%", .{p.overlay * 100}) catch "", 13, theme.dim, font_mod.regular);
            clay.close();
        },
        .grid => gridPanel(app, a, p),
    }
    if (p.area_len > 0) areaPanel(app, a, p);
    // Painting's hint and the layer's PNG out / in: with the painting tools.
    const painting = p.tool == .move or p.tool == .brush or p.tool == .picker;
    if (painting) clay.text(tx.get(tx.lp_hint), .{ .textColor = theme.dim, .fontSize = 11, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    if (painting and (p.layer == .picture or p.layer == .depth)) {
        clay.open(.{ .layout = .{ .childGap = 6 } });
        if (main.button(app, "lp_export", tx.get(tx.spr_to_png), false)) app.askFile(.{ .kind = .png_out, .run = onLayerOut, .entry = @backingInt(p.layer) });
        if (main.button(app, "lp_import", tx.get(tx.spr_from_png), false)) app.askFile(.{ .kind = .png, .run = onLayerIn, .entry = @backingInt(p.layer) });
        clay.close();
    }
    clay.close();
    clay.close();
    clay.close();
}

/// The edit mode's tools over the view (as the concept's toolbar): objects, the hand,
/// painting, lights, then what belongs to the level kind; Done on the right.
pub fn toolbar(app: *App, p: *Paint) void {
    const Btn = struct { t: Tool, ic: @import("icons.zig").Icon, label: tx.Msg };
    if (app.doc == null) return;
    const all = [_]Btn{
        .{ .t = .objects, .ic = .mouse_pointer_2, .label = tx.lp_objects_tool },
        .{ .t = .move, .ic = .hand, .label = tx.lp_move },
        .{ .t = .brush, .ic = .paintbrush, .label = tx.lp_brush },
        .{ .t = .picker, .ic = .pipette, .label = tx.spr_picker },
        .{ .t = .light, .ic = .lightbulb, .label = tx.lp_lights },
        .{ .t = .area, .ic = .square_dashed, .label = tx.lp_area },
        .{ .t = .exit, .ic = .log_out, .label = tx.lp_exit },
        .{ .t = .points, .ic = .crosshair, .label = tx.lp_points },
        .{ .t = .paths, .ic = .redo_2, .label = tx.lp_paths },
        .{ .t = .camera, .ic = .camera, .label = tx.lp_cam_tool },
    };
    // Every tool named when the view is wide (as the concept), else only the one in use.
    const named = if (App.viewportRect()) |v| v.w >= 980 else false;
    inline for (all) |b| {
        // Triggers, exits and scene points belong to locations; the camera to perspective levels.
        const shown = !((b.t == .area or b.t == .exit or b.t == .points or b.t == .paths) and p.grid != null);
        if (shown and main.toolButton(app, "lp_tool_" ++ @tagName(b.t), b.ic, if (named or p.tool == b.t) tx.get(b.label) else "", p.tool == b.t, false)) p.tool = b.t;
    }
}

const RowHit = struct {
    eye: bool = false,
    lock: bool = false,
    row: bool = false,

    fn any(self: RowHit) bool {
        return self.eye or self.lock or self.row;
    }
};

/// A layer's row (as the concept's): the eye (shown), the lock (no painting; null —
/// none), its name, whether changed.
fn layerRow(app: *App, k: u32, label: []const u8, shown: bool, locked: ?bool, sel: bool, edited: bool) RowHit {
    const icons = @import("icons.zig");
    var hit: RowHit = .{};
    const rid = clay.idi("lp_layer", k);
    _ = main.clickable(app, .{ .id = rid, .layout = .{ .sizing = .{ .width = clay.grow(), .height = clay.fixed(34) }, .padding = .{ .left = 8, .right = 10 }, .childGap = 10, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } }, .backgroundColor = theme.panel, .cornerRadius = clay.radius(theme.radius) }, sel);
    const row_over = clay.hovered();
    const eid = clay.idi("lp_eye", k);
    clay.open(.{ .id = eid, .layout = .{ .sizing = .{ .width = clay.fixed(24), .height = clay.fixed(24) }, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } } });
    hit.eye = clay.hovered() and app.clicked;
    icons.leaf(app.r, app.gpa, if (shown) .eye else .eye_off, 17, if (shown) (if (sel) theme.text else theme.accent_hover) else theme.dim);
    clay.close();
    if (locked) |lk| {
        const lid = clay.idi("lp_lock", k);
        clay.open(.{ .id = lid, .layout = .{ .sizing = .{ .width = clay.fixed(24), .height = clay.fixed(24) }, .childAlignment = .{ .x = ui.CLAY_ALIGN_X_CENTER, .y = ui.CLAY_ALIGN_Y_CENTER } } });
        hit.lock = clay.hovered() and app.clicked;
        icons.leaf(app.r, app.gpa, if (lk) .lock else .lock_open, 15, if (lk) theme.warn else theme.dim);
        clay.close();
    } else clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(24) } } });
    txt(label, 14, theme.text, if (sel) font_mod.bold else font_mod.regular);
    if (edited) txt(tx.get(tx.lp_changed), 11, theme.warn, font_mod.regular);
    clay.close();
    hit.row = row_over and app.clicked and !hit.eye and !hit.lock;
    return hit;
}

const backgroundCfg = @import("paint_camera.zig").backgroundCfg;
const gridPanel = @import("paint_camera.zig").gridPanel;
pub const cameraStep = @import("paint_camera.zig").cameraStep;
pub const gridSplitTo = @import("paint_camera.zig").gridSplitTo;
const cameraPanel = @import("paint_camera.zig").cameraPanel;
const numBox = @import("paint_camera.zig").numBox;
pub const gizmo_r = @import("paint_camera.zig").gizmo_r;
const ringAt = @import("paint_camera.zig").ringAt;
const drawGizmo = @import("paint_camera.zig").drawGizmo;
pub const cameraPress = @import("paint_camera.zig").cameraPress;
pub const cameraDrag = @import("paint_camera.zig").cameraDrag;
pub const cameraRelease = @import("paint_camera.zig").cameraRelease;
pub const cameraWheel = @import("paint_camera.zig").cameraWheel;
pub const camCommit = @import("paint_camera.zig").camCommit;

/// The size of characters on this level (`actorScale` in initCamera(); the exe's
/// default 0.15 when unset, 0x421907): a new picture drawn at another scale needs it.
fn actorScaleRow(app: *App, a: Allocator) void {
    const d = app.doc orelse return;
    const lev = app.store.text(d.lev);
    const set = newlevel.cameraVar(lev, "actorScale");
    const v = if (set) |x| (if (x > 0) x else default_actor_scale) else default_actor_scale;
    const step = stepper(app, a, "lp_ascale", tx.alloc(a, tx.lp_actor_scale, .{ v, v / default_actor_scale * 100 }), v, 0.01);
    if (step == 0) return;
    const t = newlevel.setCameraVar(app.gpa, lev, "actorScale", std.math.clamp(v + step, 0.03, 1)) catch |err| return app.setStatus(tx.st_set_failed, .{err});
    app.store.replaceLabeled(d.lev, t, tx.alloc(a, tx.lp_actor_scale, .{ v + step, (v + step) / default_actor_scale * 100 })) catch |err| {
        app.gpa.free(t);
        app.setStatus(tx.st_set_failed, .{err});
    };
}

const default_actor_scale = og.actor.model_cache.default_actor_scale;

// File dialog answers (app.askFile): `ask.entry` is the layer.
fn onLayerIn(app: *App, ask: main.FileAsk, path: []const u8) !void {
    try importLayer(app, app.paint orelse return, @fromBackingInt(@intCast(ask.entry)), path);
    app.setStatus(tx.st_layer_set, .{});
}
fn onLayerOut(app: *App, ask: main.FileAsk, path: []const u8) !void {
    try exportLayer(app, app.paint orelse return, @fromBackingInt(@intCast(ask.entry)), path);
    app.setStatus(tx.st_layer_saved, .{path});
}

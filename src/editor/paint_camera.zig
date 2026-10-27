//! A level's view settings in the edit mode: a battle's grid (size, split) and camera
//! (the gizmo dragged, initCamera keys), a location's ortho camera, the background .cfg.

const std = @import("std");
const screen = @import("paint.zig").screen;
const stepper = @import("paint.zig").stepper;
const Ring = @import("paint.zig").Ring;
const Paint = @import("paint.zig").Paint;
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const ui = @import("ui");
const og = @import("opengorky");
const lf = og.formats.level_files;
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;
const txt = main.txt;
const Doc = @import("level.zig").Doc;
const newlevel = @import("newlevel.zig");
const paint = @import("paint.zig");

/// A location's camera (orthographic, initCamera()): the tilt the background was drawn
/// at (`rotxy`, −30° in the game's) and the depth planes. 3D characters are drawn with
/// it over the picture, so it has to match the picture.
fn orthoPanel(app: *App, a: Allocator, d: *Doc) void {
    clay.text(tx.get(tx.cam_ortho_hint), .{ .textColor = theme.dim, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    const lev = app.store.text(d.lev);
    const rows = [_]struct { tx.Msg, []const u8, f32 }{ .{ tx.cam_tilt, "rotxy", 180.0 / std.math.pi }, .{ tx.cam_front, "frontPlane", 1 }, .{ tx.cam_back, "backPlane", 1 } };
    inline for (rows) |r| {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(140) } } });
        txt(tx.get(r[0]), 13, theme.text, font_mod.regular);
        clay.close();
        const v = (newlevel.cameraVar(lev, r[1]) orelse 0) * r[2];
        if (numBox(app, a, "lp_ortho_" ++ r[1], "", v, 120)) |nv| {
            const t = newlevel.setCameraVar(app.gpa, lev, r[1], nv / r[2]) catch |err| {
                clay.close();
                return app.setStatus(tx.st_set_failed, .{err});
            };
            app.store.replaceLabeled(d.lev, t, r[1]) catch |err| {
                app.gpa.free(t);
                app.setStatus(tx.st_set_failed, .{err});
            };
        }
        clay.close();
    }
}

/// The background's `.cfg` (sprite.dat `background\\<level>.cfg`, read by the exe at
/// 0x41cf07): how the depth picture turns into floor height on a location (gscale, g0,
/// g1) and its planes; a battle's eye and target (vx…tz, tl). Shown with the depth layer.
pub fn backgroundCfg(app: *App, a: Allocator) void {
    const d = app.doc orelse return;
    const archive = std.fmt.allocPrint(a, "{s}/sprite.dat", .{d.name}) catch return;
    const entry = std.fmt.allocPrint(a, "background\\{s}.cfg", .{d.name}) catch return;
    const f = app.store.file(archive, entry) catch return;
    const t = app.store.text(f);
    clay.text(tx.get(tx.bg_cfg_hint), .{ .textColor = theme.dim, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    const keys: []const []const u8 = if (std.mem.indexOf(u8, t, "\ntl ") != null or std.mem.startsWith(u8, t, "tl ")) &.{ "vx", "vy", "vz", "tx", "ty", "tz", "tl" } else &.{ "gscale", "g0", "g1", "frontPlane", "backPlane" };
    for (keys) |k| {
        const v = cfgValue(t, k) orelse continue;
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(110) } } });
        txt(k, 13, theme.text, font_mod.regular);
        clay.close();
        if (numBox(app, a, std.fmt.allocPrint(a, "bgcfg_{s}", .{k}) catch k, "", v, 140)) |nv| {
            const nt = cfgSet(app.gpa, t, k, nv) catch {
                clay.close();
                return;
            };
            app.store.replaceLabeled(f, nt, entry) catch app.gpa.free(nt);
        }
        clay.close();
    }
}

/// `key value` line's value.
fn cfgValue(t: []const u8, key: []const u8) ?f32 {
    var it = std.mem.splitScalar(u8, t, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len > key.len and std.mem.startsWith(u8, l, key) and l[key.len] == ' ') return std.fmt.parseFloat(f32, std.mem.trim(u8, l[key.len..], " ")) catch null;
    }
    return null;
}

/// `t` with `key`'s value `v` (`%f`, as the game's files write it).
fn cfgSet(gpa: Allocator, t: []const u8, key: []const u8, v: f32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitScalar(u8, t, '\n');
    var first = true;
    while (it.next()) |raw| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (l.len > key.len and std.mem.startsWith(u8, l, key) and l[key.len] == ' ') {
            try out.print(gpa, "{s} {d:.6}", .{ key, v });
            if (raw.len > l.len) try out.append(gpa, '\r');
        } else try out.appendSlice(gpa, raw);
    }
    return out.toOwnedSlice(gpa);
}

/// The battle grid: cells free or blocked (the brush), and where the grid lies — its
/// centre, turn, cell size, size in cells. A placement change is one undo step.
pub fn gridPanel(app: *App, a: Allocator, p: *Paint) void {
    clay.open(.{ .layout = .{ .childGap = 6 } });
    if (main.button(app, "lp_on", tx.get(tx.lp_grid_free), p.walk_on)) p.walk_on = true;
    if (main.button(app, "lp_off", tx.get(tx.lp_grid_blocked), !p.walk_on)) p.walk_on = false;
    clay.close();
    clay.text(tx.get(tx.lp_grid_hint), .{ .textColor = theme.dim, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    const g = &(p.grid orelse return);
    const step = g.cell_size[0] / 4;
    const Edit = struct { id: []const u8, label: []const u8, cur: f32, d: f32 };
    const rows = [_]Edit{
        .{ .id = "lp_gx", .label = tx.alloc(a, tx.lp_grid_x, .{g.center[0]}), .cur = g.center[0], .d = step },
        .{ .id = "lp_gy", .label = tx.alloc(a, tx.lp_grid_y, .{g.center[1]}), .cur = g.center[1], .d = step },
        .{ .id = "lp_gz", .label = tx.alloc(a, tx.lp_grid_z, .{g.center[2]}), .cur = g.center[2], .d = 5 },
        .{ .id = "lp_gr", .label = tx.alloc(a, tx.lp_grid_turn, .{g.rotation}), .cur = g.rotation, .d = 0.01 },
        .{ .id = "lp_gs", .label = tx.alloc(a, tx.lp_grid_cell, .{g.cell_size[0]}), .cur = g.cell_size[0], .d = 0.5 },
        .{ .id = "lp_gw", .label = tx.alloc(a, tx.lp_grid_w, .{g.width}), .cur = @floatFromInt(g.width), .d = 1 },
        .{ .id = "lp_gh", .label = tx.alloc(a, tx.lp_grid_h, .{g.height}), .cur = @floatFromInt(g.height), .d = 1 },
        .{ .id = "lp_gsw", .label = tx.alloc(a, tx.lp_grid_split_w, .{g.width}), .cur = @floatFromInt(g.width), .d = 1 },
        .{ .id = "lp_gsh", .label = tx.alloc(a, tx.lp_grid_split_h, .{g.height}), .cur = @floatFromInt(g.height), .d = 1 },
    };
    for (rows, 0..) |r, k| {
        const v = stepper(app, a, r.id, r.label, r.cur, r.d);
        if (v == 0) continue;
        const before = lf.encodeCombatMap(app.gpa, g.*) catch return;
        p.undo.append(app.gpa, .{ .layer = .grid, .whole = before }) catch {
            app.gpa.free(before);
            return;
        };
        switch (k) {
            0, 1 => g.center[k] += v,
            2 => g.center[2] += v,
            3 => g.rotation += v,
            4 => g.cell_size = .{ @max(4, g.cell_size[0] + v), @max(4, g.cell_size[1] + v) },
            5, 6 => resizeGrid(app.gpa, g, if (k == 5) @intFromFloat(v) else 0, if (k == 6) @intFromFloat(v) else 0) catch {},
            else => splitGrid(app.gpa, g, if (k == 7) @intFromFloat(v) else 0, if (k == 8) @intFromFloat(v) else 0) catch {},
        }
    }
    cameraPanel(app, a, p, true);
}

/// `g` cut into `dw` columns / `dh` rows more or fewer over the same floor: the cell
/// size follows, each new cell takes the old cell under its middle. (In a battle the
/// cell size also sets the models' size: actorScale = xSize/350, 0x4b49f0.)
fn splitGrid(gpa: Allocator, g: *lf.CombatMap, dw: i32, dh: i32) !void {
    const w: u32 = @intCast(std.math.clamp(@as(i32, @intCast(g.width)) + dw, 1, 255));
    const h: u32 = @intCast(std.math.clamp(@as(i32, @intCast(g.height)) + dh, 1, 255));
    const cells = try gpa.alloc(bool, w * h);
    for (0..h) |y| for (0..w) |x| {
        const ox = (2 * x + 1) * g.width / (2 * w);
        const oy = (2 * y + 1) * g.height / (2 * h);
        cells[y * w + x] = g.blocked[oy * g.width + ox];
    };
    g.cell_size = .{ g.cell_size[0] * @as(f32, @floatFromInt(g.width)) / @as(f32, @floatFromInt(w)), g.cell_size[1] * @as(f32, @floatFromInt(g.height)) / @as(f32, @floatFromInt(h)) };
    gpa.free(g.blocked);
    g.blocked = cells;
    g.width = w;
    g.height = h;
}

/// One camera key changed by `dv` in the Store's script (as the panel's buttons).
pub fn cameraStep(app: *App, key: []const u8, dv: f32) !void {
    const d = app.doc orelse return error.NoLevel;
    const l = d.world.level orelse return error.NoLevel;
    var v: ?f32 = null;
    inline for (Doc.camera_keys) |k| if (std.mem.eql(u8, k, key)) {
        v = og.fields.getF(l, k);
    };
    const t = try newlevel.setCameraVar(app.gpa, app.store.text(d.lev), key, (v orelse return error.NoSuchKey) + dv);
    try app.store.replace(d.lev, t);
}

/// `g` split into `w` × `h` cells over the same floor (CLI; the panel steps by one).
pub fn gridSplitTo(app: *App, p: *Paint, w: u32, h: u32) !void {
    const g = &(p.grid orelse return error.NoGrid);
    try p.undo.append(app.gpa, .{ .layer = .grid, .whole = try lf.encodeCombatMap(app.gpa, g.*) });
    try splitGrid(app.gpa, g, @as(i32, @intCast(w)) - @as(i32, @intCast(g.width)), @as(i32, @intCast(h)) - @as(i32, @intCast(g.height)));
}

/// The battle's camera (initCamera() of its script): where it looks from and to, its
/// angle and floor level, for a picture rendered from elsewhere. Each change is a
/// history step; the level reloads to show the grid and fighters through it.
/// `titled`: its own header and hint (under the grid; the camera tool has its own).
pub fn cameraPanel(app: *App, a: Allocator, p: *Paint, titled: bool) void {
    const d = app.doc orelse return;
    const l = d.world.level orelse return;
    if (d.world.cam != .persp) return orthoPanel(app, a, d);
    if (titled) main.panelHeader(tx.get(tx.lp_camera));
    clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .layoutDirection = ui.CLAY_TOP_TO_BOTTOM, .padding = .{ .left = 2, .right = 2, .top = 8 }, .childGap = 8 } });
    if (titled) clay.text(tx.get(tx.lp_camera_hint), .{ .textColor = theme.dim, .fontSize = 12, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    // As the concept's: position and target as X Y Z, then the single values.
    const Row = struct { label: tx.Msg, keys: []const []const u8, prefixes: []const []const u8 };
    const rows = [_]Row{
        .{ .label = tx.cam_position, .keys = &.{ "viewX", "viewY", "viewZ" }, .prefixes = &.{ "X", "Y", "Z" } },
        .{ .label = tx.cam_target, .keys = &.{ "aimX", "aimY", "aimZ" }, .prefixes = &.{ "X", "Y", "Z" } },
        .{ .label = tx.cam_fov, .keys = &.{"angle"}, .prefixes = &.{"°"} },
        .{ .label = tx.cam_floor, .keys = &.{"zLevel"}, .prefixes = &.{""} },
        .{ .label = tx.cam_bank, .keys = &.{"camBan"}, .prefixes = &.{"°"} },
    };
    var set: ?struct { key: []const u8, v: f32 } = null;
    for (rows) |r| {
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.grow() }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } } });
        clay.open(.{ .layout = .{ .sizing = .{ .width = clay.fixed(110) } } });
        txt(tx.get(r.label), 13, theme.text, font_mod.regular);
        clay.close();
        for (r.keys, r.prefixes) |k, pre| {
            const v = camVar(l, k);
            if (numBox(app, a, std.fmt.allocPrint(a, "lp_cam_{s}", .{k}) catch k, pre, v, if (r.keys.len == 3) 0 else 120)) |nv| set = .{ .key = k, .v = nv };
        }
        clay.close();
    }
    clay.close();
    const s = set orelse return;
    const t = newlevel.setCameraVar(app.gpa, app.store.text(d.lev), s.key, s.v) catch |err| return app.setStatus(tx.st_set_failed, .{err});
    app.store.replaceLabeled(d.lev, t, std.fmt.allocPrint(a, "{s} = {d:.3}", .{ s.key, s.v }) catch null) catch |err| {
        app.gpa.free(t);
        return app.setStatus(tx.st_set_failed, .{err});
    };
    p.pending = .reload;
}

/// Camera key `k` of the level object (camera_keys).
fn camVar(l: anytype, k: []const u8) f32 {
    inline for (Doc.camera_keys) |ck| if (std.mem.eql(u8, ck, k)) return og.fields.getF(l, ck);
    return 0;
}

/// A number field (as the concept's X / Y / Z boxes): its value with a dim prefix; a
/// click types a new one (Enter, Tab or a click elsewhere sets it, Escape drops it).
/// Returns the new value when set. `w` 0: the row's share.
pub fn numBox(app: *App, a: Allocator, id: []const u8, prefix: []const u8, cur: f32, w: f32) ?f32 {
    const h = std.hash.Wyhash.hash(0, id);
    const fid = clay.id(id);
    const editing = if (app.num_edit) |e| e.id == h else false;
    clay.open(.{
        .id = fid,
        .layout = .{ .sizing = .{ .width = if (w > 0) clay.fixed(w) else clay.grow(), .height = clay.fixed(30) }, .padding = .{ .left = 8, .right = 8 }, .childGap = 6, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = theme.field,
        .cornerRadius = clay.radius(theme.radius),
        .border = .{ .color = if (editing) theme.accent else if (clay.pointerOver(fid)) theme.button_edge else theme.field_border, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } },
    });
    const over = clay.hovered();
    if (prefix.len > 0) txt(prefix, 12, theme.dim, font_mod.regular);
    // Whole numbers without decimals (a brush size), the rest to three places.
    const shown = if (@round(cur) == cur) std.fmt.allocPrint(a, "{d:.0}", .{cur}) else std.fmt.allocPrint(a, "{d:.3}", .{cur});
    if (editing) txt(std.fmt.allocPrint(a, "{s}|", .{app.num_edit.?.text()}) catch "", 13, theme.text, font_mod.regular) else txt(shown catch "", 13, theme.text, font_mod.regular);
    clay.close();
    if (editing) {
        app.num_seen = true;
        const e = &app.num_edit.?;
        if (e.done or (app.clicked and !over)) {
            const v = std.fmt.parseFloat(f32, e.text()) catch null;
            app.num_edit = null;
            if (v) |x| if (std.math.isFinite(x) and x != cur) return std.math.clamp(x, -1e5, 1e5);
        }
    } else if (over and app.clicked) {
        var e: main.NumEdit = .{ .id = h };
        e.len = if (std.fmt.bufPrint(&e.buf, "{d}", .{cur})) |t| t.len else |_| 0;
        app.num_edit = e;
        app.num_seen = true;
    }
    return null;
}

/// The camera gizmo, in the middle of the view: rings turn the camera about its aim
/// (green: round the vertical, red: up/down, blue: the bank `camBan`), the centre
/// moves it, the wheel over it brings it nearer (Shift: the view angle). The level
/// shows it live; the script gets it when the pointer rests (one history step).
pub const gizmo_r: f32 = 90;

fn gizmoCenter(rect: c.SDL_FRect) [2]f32 {
    return .{ rect.x + rect.w / 2, rect.y + rect.h / 2 };
}

/// The gizmo's part under window point `m`.
pub fn ringAt(rect: c.SDL_FRect, m: [2]f32) ?Ring {
    const o = gizmoCenter(rect);
    const dx = m[0] - o[0];
    const dy = m[1] - o[1];
    const dist = @sqrt(dx * dx + dy * dy);
    if (dist <= 16) return .pan;
    if (onEllipse(dx, dy, gizmo_r, gizmo_r * 0.35)) return .yaw;
    if (onEllipse(dx, dy, gizmo_r * 0.35, gizmo_r)) return .pitch;
    if (@abs(dist - gizmo_r * 1.25) <= 8) return .roll;
    return null;
}

/// (dx, dy) within 7 pixels of the ellipse with half-axes a, b (along its own ray).
fn onEllipse(dx: f32, dy: f32, a: f32, b: f32) bool {
    const e = @sqrt((dx / a) * (dx / a) + (dy / b) * (dy / b));
    if (e < 1e-3) return false;
    const dist = @sqrt(dx * dx + dy * dy);
    return @abs(dist - dist / e) <= 7;
}

fn ellipse(r: *c.SDL_Renderer, o: [2]f32, a: f32, b: f32, rgb: [3]u8, hot: bool) void {
    _ = c.SDL_SetRenderDrawColor(r, rgb[0], rgb[1], rgb[2], if (hot) 255 else 170);
    // Hot: drawn three times, a pixel apart (thicker).
    const n: usize = if (hot) 3 else 1;
    for (0..n) |w| {
        const k = @as(f32, @floatFromInt(w)) - @as(f32, @floatFromInt(n / 2));
        var prev: [2]f32 = .{ o[0] + a + k, o[1] };
        for (1..65) |i| {
            const t = @as(f32, @floatFromInt(i)) / 64 * std.math.tau;
            const nx: [2]f32 = .{ o[0] + (a + k) * @cos(t), o[1] + (b + k) * @sin(t) };
            _ = c.SDL_RenderLine(r, prev[0], prev[1], nx[0], nx[1]);
            prev = nx;
        }
    }
}

pub fn drawGizmo(app: *App, p: *const Paint, d: *const Doc, rect: c.SDL_FRect) void {
    const r = app.r;
    const o = gizmoCenter(rect);
    const hot = p.cam_ring orelse ringAt(rect, app.mouse);
    // Where it turns about: the aim (camera → world is (X, Z, Y) / cameraScale).
    if (d.world.cam == .persp) if (d.world.level) |l| {
        const s = d.world.cam.persp.scale;
        const q = d.world.cam.project(.{ og.fields.getF(l, "aimX") / s, og.fields.getF(l, "aimZ") / s, og.fields.getF(l, "aimY") / s });
        const a = screen(d, rect, .{ q.x, q.y });
        _ = c.SDL_SetRenderDrawColor(r, 255, 210, 60, 255);
        _ = c.SDL_RenderLine(r, a[0] - 8, a[1], a[0] + 8, a[1]);
        _ = c.SDL_RenderLine(r, a[0], a[1] - 8, a[0], a[1] + 8);
    };
    ellipse(r, o, gizmo_r * 1.25, gizmo_r * 1.25, .{ 80, 140, 255 }, hot == .roll);
    ellipse(r, o, gizmo_r, gizmo_r * 0.35, .{ 90, 220, 90 }, hot == .yaw);
    ellipse(r, o, gizmo_r * 0.35, gizmo_r, .{ 240, 80, 80 }, hot == .pitch);
    _ = c.SDL_SetRenderDrawColor(r, 0, 0, 0, 200);
    _ = c.SDL_RenderFillRect(r, &.{ .x = o[0] - 11, .y = o[1] - 11, .w = 22, .h = 22 });
    _ = c.SDL_SetRenderDrawColor(r, 255, 255, 255, if (hot == .pan) 255 else 190);
    _ = c.SDL_RenderFillRect(r, &.{ .x = o[0] - 8, .y = o[1] - 8, .w = 16, .h = 16 });
}

fn camKeys(l: anytype) [Doc.camera_keys.len]f32 {
    var v: [Doc.camera_keys.len]f32 = undefined;
    inline for (Doc.camera_keys, 0..) |k, i| v[i] = og.fields.getF(l, k);
    return v;
}

/// The level's camera set to `v` (camera_keys order) and shown; false (and nothing
/// changed) when it makes no picture (looking straight down).
fn camSet(p: *Paint, d: *Doc, l: anytype, v: [Doc.camera_keys.len]f32) bool {
    const old = camKeys(l);
    inline for (Doc.camera_keys, 0..) |k, i| og.fields.setF(l, k, v[i]);
    const cam = og.world.start.makeCamera(d.world, l);
    if (cam != .persp) {
        inline for (Doc.camera_keys, 0..) |k, i| og.fields.setF(l, k, old[i]);
        return false;
    }
    if (p.cam_base == null) p.cam_base = old;
    d.world.cam = cam;
    p.cam_at = c.SDL_GetTicks();
    return true;
}

/// Pressed at window point `m`: a part of the gizmo grabbed (false off it: the map moves).
pub fn cameraPress(p: *Paint, rect: c.SDL_FRect, m: [2]f32) bool {
    p.cam_ring = ringAt(rect, m) orelse return false;
    p.cam_last = m;
    return true;
}

/// The grabbed part dragged to window point `m`.
pub fn cameraDrag(p: *Paint, d: *Doc, rect: c.SDL_FRect, m: [2]f32) void {
    const ring = p.cam_ring orelse return;
    const l = d.world.level orelse return;
    if (d.world.cam != .persp) return;
    const cam = d.world.cam.persp;
    var v = camKeys(l);
    const dx = m[0] - p.cam_last[0];
    const dy = m[1] - p.cam_last[1];
    const vec = og.vec;
    var aim: [3]f32 = v[3..6].*;
    var off = vec.sub(v[0..3].*, aim);
    const dist = @sqrt(vec.dot(off, off));
    switch (ring) {
        // Round the vertical (camera Y).
        .yaw => {
            const t = -dx * 0.006;
            off = .{ off[0] * @cos(t) + off[2] * @sin(t), off[1], -off[0] * @sin(t) + off[2] * @cos(t) };
        },
        // Up/down over the aim, short of straight up or down.
        .pitch => {
            const h = @sqrt(off[0] * off[0] + off[2] * off[2]);
            const e = std.math.clamp(std.math.atan2(off[1], h) + dy * 0.006, -1.5, 1.5);
            const k = if (h > 1e-6) dist * @cos(e) / h else 0;
            off = .{ off[0] * k, dist * @sin(e), off[2] * k };
        },
        // The bank: the pointer's turn round the gizmo centre.
        .roll => {
            const o = gizmoCenter(rect);
            const a0 = std.math.atan2(p.cam_last[1] - o[1], p.cam_last[0] - o[0]);
            const a1 = std.math.atan2(m[1] - o[1], m[0] - o[0]);
            var da = a1 - a0;
            if (da > std.math.pi) da -= std.math.tau;
            if (da < -std.math.pi) da += std.math.tau;
            v[8] -= da * 180 / std.math.pi;
        },
        // Camera and aim together, so the picture under the pointer follows it.
        .pan => {
            const k = dist / cam.focal / d.zoom;
            const move = vec.add(mul(cam.right, -dx * k), mul(cam.up, dy * k));
            aim = vec.add(aim, move);
        },
    }
    v[0..3].* = vec.add(aim, off);
    v[3..6].* = aim;
    p.cam_last = m;
    _ = camSet(p, d, l, v);
}

pub fn mul(a: [3]f32, k: f32) [3]f32 {
    return .{ a[0] * k, a[1] * k, a[2] * k };
}

/// Released: the moved camera written.
pub fn cameraRelease(app: *App, p: *Paint) void {
    if (p.cam_ring == null) return;
    p.cam_ring = null;
    camCommit(app, p);
}

/// The wheel at window point `m` over the gizmo: nearer/farther (`fov`: the view
/// angle narrower/wider); false off it (the view zooms).
pub fn cameraWheel(p: *Paint, d: *Doc, rect: c.SDL_FRect, m: [2]f32, notches: f32, fov: bool) bool {
    const o = gizmoCenter(rect);
    if (std.math.hypot(m[0] - o[0], m[1] - o[1]) > gizmo_r * 1.25 + 10) return false;
    const l = d.world.level orelse return false;
    if (d.world.cam != .persp) return false;
    var v = camKeys(l);
    const k = std.math.pow(f32, 0.92, notches);
    if (fov) {
        v[6] = std.math.clamp(v[6] * k, 5, 150);
    } else {
        const vec = og.vec;
        const aim: [3]f32 = v[3..6].*;
        const off = vec.sub(v[0..3].*, aim);
        if (vec.dot(off, off) * k * k > 1e-4) v[0..3].* = vec.add(aim, mul(off, k));
    }
    _ = camSet(p, d, l, v);
    return true;
}

/// The camera moved since the last write: its changed keys into initCamera(), one step.
pub fn camCommit(app: *App, p: *Paint) void {
    const base = p.cam_base orelse return;
    p.cam_base = null;
    const d = app.doc orelse return;
    const l = d.world.level orelse return;
    const v = camKeys(l);
    var t = app.gpa.dupe(u8, app.store.text(d.lev)) catch return;
    inline for (Doc.camera_keys, 0..) |k, i| if (v[i] != base[i]) {
        const n = newlevel.setCameraVar(app.gpa, t, k, v[i]) catch |err| {
            app.gpa.free(t);
            return app.setStatus(tx.st_set_failed, .{err});
        };
        app.gpa.free(t);
        t = n;
    };
    app.store.replace(d.lev, t) catch |err| {
        app.gpa.free(t);
        return app.setStatus(tx.st_set_failed, .{err});
    };
    // The fighters' marks are placed on load.
    p.pending = .reload;
}

/// `g` with `dw` columns / `dh` rows more (new cells free) or fewer (1…255 each).
fn resizeGrid(gpa: Allocator, g: *lf.CombatMap, dw: i32, dh: i32) !void {
    const w: u32 = @intCast(std.math.clamp(@as(i32, @intCast(g.width)) + dw, 1, 255));
    const h: u32 = @intCast(std.math.clamp(@as(i32, @intCast(g.height)) + dh, 1, 255));
    const cells = try gpa.alloc(bool, w * h);
    for (0..h) |y| for (0..w) |x| {
        cells[y * w + x] = if (x < g.width and y < g.height) g.blocked[y * g.width + x] else false;
    };
    gpa.free(g.blocked);
    g.blocked = cells;
    g.width = w;
    g.height = h;
}

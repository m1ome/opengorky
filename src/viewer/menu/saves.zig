//! Saves in the viewer: menu settings (options.cfg), slots (list, thumbnails), save and load.

const std = @import("std");
const config = @import("../app/config.zig");
const menu_slots = @import("slots.zig");
const gfx = @import("../media/gfx.zig");
const render = @import("../app/render.zig");
const viewer_mod = @import("../app/viewer.zig");
const Viewer = viewer_mod.Viewer;
const Io = std.Io;
const og = @import("opengorky");
const c = @import("sdl");
const Image = og.formats.image.Image;

/// Settings (`options.cfg` next to the saves): "music 75" etc.
pub fn loadOptions(self: *Viewer, gains: *[3]f32) void {
    var buf: [512]u8 = undefined;
    const dir = self.saves_dir orelse return;
    const path = std.fmt.bufPrint(&buf, "{s}/options.cfg", .{dir}) catch return;
    const data = Io.Dir.cwd().readFileAlloc(self.io, path, self.gpa, .limited(4096)) catch return;
    defer self.gpa.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |l| {
        var it = std.mem.tokenizeScalar(u8, l, ' ');
        const key = it.next() orelse continue;
        const val = std.fmt.parseInt(u32, it.next() orelse continue, 10) catch continue;
        if (std.mem.eql(u8, key, "shadows")) {
            self.shadows = val != 0;
            continue;
        }
        if (std.mem.eql(u8, key, "gamma")) {
            self.gamma = @floatFromInt(@min(val, 400));
            continue;
        }

        const k: usize = if (std.mem.eql(u8, key, "sfx")) 0 else if (std.mem.eql(u8, key, "music")) 1 else if (std.mem.eql(u8, key, "voice")) 2 else continue;
        gains[k] = og.num.toF32(@min(val, 100)) / 100;
    }
}
pub fn saveOptions(self: *Viewer, gains: *const [3]f32) void {
    var buf: [512]u8 = undefined;
    const dir = self.saves_dir orelse return;
    const path = std.fmt.bufPrint(&buf, "{s}/options.cfg", .{dir}) catch return;
    var text: [160]u8 = undefined;
    // Like the exe's registry values (HKCU\Software\Metropolis\G17): volumes, shadows, gamma.
    const data = std.fmt.bufPrint(&text, "sfx {d}\nmusic {d}\nvoice {d}\nshadows {d}\ngamma {d}\n", .{
        @as(u32, @intFromFloat(@round(gains[0] * 100))), @as(u32, @intFromFloat(@round(gains[1] * 100))), @as(u32, @intFromFloat(@round(gains[2] * 100))),
        @intFromBool(self.shadows),                      @as(u32, @intFromFloat(@round(self.gamma))),
    }) catch return;
    Io.Dir.cwd().createDirPath(self.io, dir) catch return;
    Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = data }) catch |err| std.log.warn("options: {t}", .{err});
}
pub fn slotPath(self: *Viewer, buf: []u8, slot: usize) ?[]const u8 {
    const dir = self.saves_dir orelse return null;
    return std.fmt.bufPrint(buf, "{s}/slot{d}.ogsave", .{ dir, slot + 1 }) catch null;
}
/// Menu slot labels: the level from the file's `current` line; the newest file
/// (0x412f70: FindFirstFile + CompareFileTime) is preselected.
pub fn refreshSlots(self: *Viewer) void {
    const m = self.menu orelse return;
    m.newest = null;
    var newest_time: i96 = std.math.minInt(i96);
    for (0..@import("items.zig").slot_count) |i| {
        var buf: [512]u8 = undefined;
        const path = slotPath(self, &buf, i) orelse continue;
        if (Io.Dir.cwd().statFile(self.io, path, .{})) |st| {
            if (st.mtime.nanoseconds > newest_time) {
                newest_time = st.mtime.nanoseconds;
                m.newest = i;
            }
        } else |_| {}
        // Save header: the file's first lines.
        const file = Io.Dir.cwd().openFile(self.io, path, .{}) catch {
            menu_slots.setSlot(m, i, null);
            menu_slots.setThumb(m, i, null);
            continue;
        };
        var head: [1024]u8 = undefined;
        const got = file.readPositionalAll(self.io, &head, 0) catch 0;
        file.close(self.io);
        const data = head[0..got];
        // Label: the save name, else the level (old files).
        var label: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |l| {
            if (std.mem.startsWith(u8, l, "world ")) break;
            if (std.mem.startsWith(u8, l, "current ") and label == null) label = std.mem.trimEnd(u8, l["current ".len..], "\r");
            if (std.mem.startsWith(u8, l, "name ")) {
                const n = std.mem.trimEnd(u8, l["name ".len..], "\r");
                if (n.len > 0) label = n;
            }
        }
        menu_slots.setSlot(m, i, label);
        // Thumbnail slotN.png next to the save.
        var tb: [512]u8 = undefined;
        const tp = std.fmt.bufPrint(&tb, "{s}.png", .{path}) catch continue;
        const png = Io.Dir.cwd().readFileAlloc(self.io, tp, self.gpa, .limited(1 << 20)) catch {
            menu_slots.setThumb(m, i, null);
            continue;
        };
        defer self.gpa.free(png);
        var img = og.formats.jpeg.decode(self.gpa, png) catch {
            menu_slots.setThumb(m, i, null);
            continue;
        };
        defer img.deinit(self.gpa);
        menu_slots.setThumb(m, i, img);
    }
}
/// Game snapshot for the save thumbnail (0x41348b: 213×160), taken when the menu opens.
pub fn captureThumb(self: *Viewer) void {
    const was_open = if (self.menu) |m| m.open else false;
    if (self.menu) |m| m.open = false;
    defer if (self.menu) |m| {
        m.open = was_open;
    };
    render.render(self) catch return;
    const surf = gfx.readFrame(self.renderer) orelse return;
    defer c.SDL_DestroySurface(surf);
    if (self.thumb == null) self.thumb = Image.init(self.gpa, 213, 160) catch return;
    const t = &self.thumb.?;
    const sw: usize = @intCast(surf.*.w);
    const sh: usize = @intCast(surf.*.h);
    const src: [*]const u8 = @ptrCast(surf.*.pixels.?);
    const pitch: usize = @intCast(surf.*.pitch);
    for (0..160) |y| for (0..213) |x| {
        const sx = x * sw / 213;
        const sy = y * sh / 160;
        @memcpy(t.pixels[(y * 213 + x) * 4 ..][0..4], src[sy * pitch + sx * 4 ..][0..4]);
    };
    if (self.menu) |m| {
        if (m.snapshot) |x| c.SDL_DestroyTexture(x);
        m.snapshot = gfx.textureFromImage(self.renderer, t.*) catch null;
    }
}
/// "save" is available (0x4138a4): a game is running, no battle, scene or line.
pub fn canSave(self: *Viewer) bool {
    const l = &(self.level orelse return false);
    return l.world.battle == null and l.world.scene.runner == null and l.world.scene.subtitle == null;
}
pub fn saveGame(self: *Viewer, slot: usize, name: []const u8) !void {
    const l = &(self.level orelse return);
    if (l.world.battle != null) {
        // The exe has no save messages of its own; only with debug text.
        if (self.show_debug) l.world.out.message = "Cannot save during a battle";
        return;
    }
    var sv: og.save.Save = .init(self.gpa);
    defer sv.deinit();
    try self.game.snapshot(&sv);
    sv.name = name;
    var text: Io.Writer.Allocating = .init(self.gpa);
    defer text.deinit();
    try sv.write(&text.writer);
    var buf: [512]u8 = undefined;
    const path = slotPath(self, &buf, slot) orelse return;
    if (self.saves_dir) |d| try Io.Dir.cwd().createDirPath(self.io, d);
    try config.writeAtomic(self.io, path, text.written());
    var tb: [520]u8 = undefined;
    const tp = try std.fmt.bufPrint(&tb, "{s}.png", .{path});
    if (self.thumb) |t| {
        var png: Io.Writer.Allocating = .init(self.gpa);
        defer png.deinit();
        try og.formats.png.write(self.gpa, &png.writer, t);
        try config.writeAtomic(self.io, tp, png.written());
    } else Io.Dir.cwd().deleteFile(self.io, tp) catch {}; // drop the previous save's thumbnail
    if (self.show_debug) l.world.out.message = "Game saved";
    refreshSlots(self);
}

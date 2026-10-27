//! Scene commands for presentation: camera, fades, panorama, signatures, sound,
//! music, dialogue lines and their files, background animations.

const std = @import("std");
const num = @import("../num.zig");
const scriptlet = @import("../formats.zig").scriptlet;
const dialog = @import("../formats.zig").dialog;
const archive = @import("../formats.zig").archive;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const Runner = @import("../state.zig").scene.Runner;

/// Fade-out/in frames (0x4200b0: step 0.1).
pub const fade_ticks = 10;

/// Presentation: camera, fades, panorama, signatures, sound, music, dialogue, background animations.
pub fn execShow(self: *Runner, w: *World, c: scriptlet.Command, n: []const u8) !bool {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(n, "DOLLY")) {
        // DOLLY(point[, time 1/100 s[, zoom %]]) (0x47837a): linear host camera move.
        if (self.point(c.arg(0).str())) |p| w.out.dolly = .{
            .to = .{ p.x, p.y },
            .time = c.arg(1).num(),
            .zoom = if (c.args.len > 2) std.math.clamp(c.arg(2).num(), 100, 200) / 100 else null,
        };
        return true;
    }
    if (eq(n, "ZOOM")) {
        // ZOOM(percent[, time 1/100 s]) (0x478220 → 0x420030): the camera zoom goes to
        // percent (100…200)/100; time 0 at once, an integer time like DOLLY's, otherwise
        // at zoom_speed (0x5927f4). An integer percent, else a syntax error.
        if (c.args.len < 1 or c.args[0] != .number) return true;
        const z = num.toF32(std.math.clamp(c.arg(0).int(), 100, 200)) / 100;
        const t: ?f32 = if (c.args.len > 1 and c.args[1] == .number) num.toF32(c.arg(1).int()) else null;
        w.out.zoom = .{ .to = z, .time = t };
        return true;
    }
    if (eq(n, "FADE_OUT") or eq(n, "FADE_IN")) {
        w.scene.fade_target = if (eq(n, "FADE_OUT")) 1 else 0;
        self.wait = .{ .ticks = fade_ticks };
        return true;
    }
    if (eq(n, "AUTOCAMERA_ON") or eq(n, "AUTOCAMERA_OFF")) {
        w.scene.autocamera = eq(n, "AUTOCAMERA_ON");
        return true;
    }
    if (eq(n, "SIGNATURE_ON")) {
        w.scene.signature = .{ .frame = @intCast(@max(0, c.arg(0).int())), .start = w.ticks };
        return true;
    }
    if (eq(n, "SIGNATURE_OFF")) {
        w.scene.signature = null;
        return true;
    }
    if (eq(n, "PANORAMA_ON")) {
        w.scene.panorama = true;
        w.scene.panorama_h = @import("../state.zig").scene.panoramaHeight();
        return true;
    }
    if (eq(n, "PANORAMA_OFF")) {
        // Bars leave at 2 px per tick (0x478bf7); at once when skipped.
        if (!w.scene.panorama) return true;
        if (self.skip) {
            w.scene.panorama = false;
        } else self.wait = .panorama;
        return true;
    }
    if (eq(n, "MP3_PLAY")) {
        try w.out.music_events.append(w.gpa, .{ .name = c.arg(0).str() });
        w.scene.mp3 = true;
        return true;
    }
    if (eq(n, "DIALOG_INIT")) {
        if (self.skip) return true;
        self.dialog_file = c.arg(1).str();
        self.dialog = loadDialog(w, self.dialog_file) catch |err| blk: {
            std.log.warn("dialog {s}: {t}", .{ self.dialog_file, err });
            break :blk null;
        };
        return true;
    }
    if (eq(n, "DIALOG_DISPLAY")) {
        if (self.skip) return true;
        const d = self.dialog orelse return true;
        const i: usize = @intCast(@max(0, c.arg(0).int()));
        if (i >= d.lines.len) return true;
        const line = d.lines[i];
        w.scene.subtitle = .{ .speaker = line.speaker, .text = line.text };
        w.scene.dialog_cam = if (std.mem.eql(u8, self.name, "dialog")) line.cam else null;
        w.scene.splitPages(w.res.dialog_font, line.text);
        w.scene.line_open = true;
        // Our text estimate (2 ticks a character, at least 2 s); the host
        // replaces it by the voice file size (scenes.voiceStarted). "..." is
        // 2 s without voice (0x4597d0).
        w.scene.timeLine(line.text.len, @as(f64, @floatFromInt(@max(60, line.text.len * 2))) / 30);
        if (std.mem.eql(u8, std.mem.trim(u8, line.text, " "), "...")) {
            w.scene.timeLine(line.text.len, 2.0);
            self.wait = .dialog;
            return true;
        }
        var buf: [96]u8 = undefined;
        const voice = try dialog.voiceName(&buf, self.dialog_file, line.code, d.voiceIndex(i));
        try w.out.voice_events.append(w.gpa, try w.arena_state.allocator().dupe(u8, voice));
        self.wait = .dialog;
        return true;
    }
    if (eq(n, "ABA_STATE")) {
        const o = w.rt.findObject(c.arg(0).str()) orelse return true;
        o.setInt("state", c.arg(1).int());
        return true;
    }
    if (eq(n, "ABA_POS")) {
        const o = w.rt.findObject(c.arg(0).str()) orelse return true;
        o.setInt("pos_x", c.arg(1).int());
        o.setInt("pos_y", c.arg(2).int());
        World.nativeOf(o).aba_move = null;
        return true;
    }
    if (eq(n, "ABA_MOVE")) {
        // ABA_MOVE(object, x, y, speed): path step is speed/distance per tick.
        const o = w.rt.findObject(c.arg(0).str()) orelse return true;
        const from: [2]i32 = .{ o.getInt("pos_x"), o.getInt("pos_y") };
        const to: [2]i32 = .{ c.arg(1).int(), c.arg(2).int() };
        const dx = num.toF32(to[0]) - num.toF32(from[0]);
        const dy = num.toF32(to[1]) - num.toF32(from[1]);
        const dist = @sqrt(dx * dx + dy * dy);
        if (dist < 1) return true;
        const dt = c.arg(3).num() / dist;
        World.nativeOf(o).aba_move = .{ .from = from, .to = to, .step = dt, .t = dt };
        return true;
    }
    if (eq(n, "SOUND")) {
        w.out.sound(w.gpa, c.arg(0).str(), null);
        return true;
    }
    if (eq(n, "FADE_BLACK")) {
        w.scene.fade = 1;
        w.scene.fade_target = 1;
        return true;
    }
    if (eq(n, "DIALOG_SHOW")) {
        // Show/hide the dialog box (0x477a96; unused in game scenes).
        if (c.arg(0).num() == 0) w.scene.subtitle = null;
        return true;
    }
    if (eq(n, "MP3_FADE")) {
        w.out.music_fade = true;
        return true;
    }
    if (eq(n, "EARTHQUAKE")) {
        w.out.earthquake = @intCast(@max(0, c.arg(0).int()));
        return true;
    }
    return false;
}

pub fn loadDialog(self: *World, file: []const u8) !dialog.Dialog {
    // Combat levels' StartDialog() gives the name without extension.
    if (self.scene.dialog_cache.get(file)) |d| return d;
    var buf: [archive.name_size]u8 = undefined;
    const e = self.res.lang.find(file) orelse
        self.res.lang.find(std.fmt.bufPrint(&buf, "{s}.dlg", .{file}) catch file) orelse
        return error.NotFound;
    const a = self.arena_state.allocator();
    const language = if (self.strings) |t| @import("../formats.zig").strtab.language(t.*) else 0;
    const d = try dialog.parseCut(a, try self.res.lang.readAlloc(self.io, a, e), dialog.editionCut(file, language));
    try self.scene.dialog_cache.put(a, try a.dupe(u8, file), d);
    return d;
}

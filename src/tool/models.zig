//! gorky-tool `models`, `anims`, `model`: check all models and render a model
//! at an animation frame.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const common_mod = @import("common.zig");
const export_cmd = @import("export.zig");
const archive = og.formats.archive;

/// Parses every model in `common/other.dat: gfx_3d\`: mesh, animation list,
/// bone frames; checks the animation frames exist in `.bfr`.
/// Model sizes: height from chunk 12 and the pose height in the first frame.
pub fn modelSizes(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8) !void {
    var dat = try common_mod.openDat(io, game_dir, .{});
    defer dat.close(io);
    var cache = try og.actor.model_cache.Cache.open(io, gpa, dat);
    defer cache.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (cache.common.entries) |*e| {
        if (!std.ascii.startsWithIgnoreCase(e.name, "gfx_3d\\") or !std.ascii.endsWithIgnoreCase(e.name, ".msh")) continue;
        const stem = e.name["gfx_3d\\".len .. e.name.len - 4];
        const m = cache.get(stem) orelse continue;
        const pts = og.actor.skin.pose(arena.allocator(), m.mesh, m.frames, 0, .row) catch continue;
        var lo: [3]f32 = @splat(std.math.inf(f32));
        var hi: [3]f32 = @splat(-std.math.inf(f32));
        for (pts) |part| for (part) |v| for (0..3) |k| {
            lo[k] = @min(lo[k], v[k]);
            hi[k] = @max(hi[k], v[k]);
        };
        try out.print("{s:<16} height {d:>6.1}  pose x {d:>6.1} y {d:>6.1} z {d:>6.1}\n", .{ stem, m.mesh.height, hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2] });
    }
}

pub fn checkModels(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8) !void {
    var dat = try common_mod.openDat(io, game_dir, .{});
    defer dat.close(io);
    var common = try archive.Archive.open(io, gpa, dat, "common/other.dat");
    defer common.close(io, gpa);

    var models: usize = 0;
    var failed: usize = 0;
    var total_anims: usize = 0;
    var total_frames: usize = 0;
    for (common.entries) |*e| {
        if (!std.ascii.endsWithIgnoreCase(e.name, ".msh")) continue;
        models += 1;
        loadModel(io, gpa, common, e, &total_anims, &total_frames) catch |err| {
            failed += 1;
            try out.print("{s}: {t}\n", .{ e.name, err });
        };
    }
    try out.print("models {d}, failed {d}, animations {d}, bone frames {d}\n", .{ models, failed, total_anims, total_frames });
}

fn loadModel(io: Io, gpa: Allocator, arc: archive.Archive, e: *const archive.Entry, anims_out: *usize, frames_out: *usize) !void {
    const data = try arc.readAlloc(io, gpa, e);
    defer gpa.free(data);
    var mesh = og.formats.mesh.parse(gpa, data) catch |err| return switch (err) {
        error.Truncated => error.MeshTruncated,
        else => err,
    };
    defer mesh.deinit();

    var buf: [archive.name_size]u8 = undefined;
    const stem = e.name[0 .. e.name.len - 4];
    const ani_entry = arc.find(try std.fmt.bufPrint(&buf, "gfx_3d\\{s}", .{mesh.animations})) orelse
        arc.find(try std.fmt.bufPrint(&buf, "{s}.ani", .{stem})) orelse return error.NoAni;
    const ani_data = try arc.readAlloc(io, gpa, ani_entry);
    defer gpa.free(ani_data);
    var anims = og.formats.anim.parseAni(gpa, ani_data) catch |err| return switch (err) {
        error.Truncated => error.AniTruncated,
        else => err,
    };
    defer anims.deinit();

    const bfr_entry = arc.find(try std.fmt.bufPrint(&buf, "{s}.bfr", .{stem})) orelse return error.NoBfr;
    const bfr_data = try arc.readAlloc(io, gpa, bfr_entry);
    defer gpa.free(bfr_data);
    var frames = og.formats.anim.parseBfr(gpa, bfr_data, @intCast(mesh.boneCount())) catch |err| return switch (err) {
        error.Truncated => error.BfrSizeMismatch,
        else => err,
    };
    defer frames.deinit(gpa);
    try og.formats.anim.checkFrames(anims, frames);
    anims_out.* += anims.items.len;
    frames_out.* += frames.frames;
}

pub fn renderModel(
    io: Io,
    gpa: Allocator,
    out: *Io.Writer,
    game_dir: []const u8,
    name: []const u8,
    anim_name: []const u8,
    frame_in_anim: u32,
    path: []const u8,
    conv: og.actor.skin.Convention,
    yaw_deg: f32,
    weapon: ?[]const u8,
) !void {
    var dat = try common_mod.openDat(io, game_dir, .{});
    defer dat.close(io);
    var cache = try og.actor.model_cache.Cache.open(io, gpa, dat);
    defer cache.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const model = cache.get(name) orelse return error.NotFound;
    const mesh = model.mesh;
    const tex = model.texture;

    // Items (weapons) without animations: the single frame is named "-".
    const still: og.formats.anim.Animation = .{ .name = "-", .first = 0, .last = 0, .speed = 1, .sounds = &.{} };
    const a = if (model.anims.items.len == 0 and std.mem.eql(u8, anim_name, "-")) &still else model.anims.find(anim_name) orelse {
        try out.print("no animation '{s}'; available:", .{anim_name});
        for (model.anims.items) |it| try out.print(" {s}", .{it.name});
        try out.writeByte('\n');
        return error.NoAnimation;
    };
    // Frame "all" (frame_in_anim = maxInt): every animation frame into folder `path`
    // (000.png, 001.png…) at one scale, for GIFs.
    const all = frame_in_anim == std.math.maxInt(u32);
    const count: u32 = if (all) a.last - a.first + 1 else 1;
    var fixed: ?[2]f32 = null;
    var path_buf: [512]u8 = undefined;
    for (0..count) |fi| {
        const frame = if (all) a.first + @as(u32, @intCast(fi)) else @min(a.first + frame_in_anim, a.last);
        const out_path = if (all) try std.fmt.bufPrint(&path_buf, "{s}/{d:0>3}.png", .{ path, fi }) else path;
        // Model in local axes (rotation and shift of chunks 14 and 11), weapon in hand.
        var parts: std.ArrayList(Drawn) = .empty;
        const pts = try og.actor.skin.pose(arena, mesh, model.frames, frame, conv);
        try parts.append(arena, .{ .model = model, .pts = pts });
        if (weapon) |wspec| {
            const colon = std.mem.indexOfScalar(u8, wspec, ':') orelse wspec.len;
            const link_name = if (colon < wspec.len) wspec[colon + 1 ..] else "one_hand";
            const wm = cache.get(wspec[0..colon]) orelse return error.NotFound;
            if (mesh.holdMode(link_name)) |h| {
                if (fi == 0) {
                    for (mesh.hold_modes) |hm| std.debug.print("link {s}: {any} bone {d}\n", .{ hm.name, hm.params, hm.bone });
                    std.debug.print("weapon {s}: rotation {any} center {any}\n", .{ wspec[0..colon], wm.mesh.rotation, wm.mesh.center });
                }
                if (try og.render.layer.attachedPoints(arena, model, frame, .{ .model = wm, .link = h })) |wp|
                    try parts.append(arena, .{ .model = wm, .pts = wp });
                if (flash_spec) |fs| if (cache.get("chaingun")) |cm| {
                    var v: [4]f32 = .{ 0, 0, 0, 0.5 };
                    var it = std.mem.tokenizeScalar(u8, fs, ',');
                    var i: usize = 0;
                    while (it.next()) |t| : (i += 1) if (i < 4) {
                        v[i] = try std.fmt.parseFloat(f32, t);
                    };
                    if (try og.render.layer.attachedPoints(arena, model, frame, .{ .model = cm, .link = h, .offset = v[0..3].*, .scale = v[3] })) |fp|
                        try parts.append(arena, .{ .model = cm, .pts = fp });
                };
            }
        }
        for (parts.items) |d| for (d.pts) |pp| for (pp) |*p| {
            p.* = og.actor.model_cache.localPoint(model, p.*);
        };

        const size = 320;
        var canvas = try og.render.raster.Canvas.init(gpa, size, size, .{ 40, 44, 52, 255 });
        defer canvas.deinit(gpa);
        const yaw = yaw_deg * std.math.pi / 180.0;
        const cy = @cos(yaw);
        const sy = @sin(yaw);
        // Crop to the pose's vertical bounds.
        var min_y: f32 = std.math.inf(f32);
        var max_y: f32 = -std.math.inf(f32);
        for (parts.items) |d| for (d.pts) |pp| for (pp) |p| {
            min_y = @min(min_y, p[1]);
            max_y = @max(max_y, p[1]);
        };
        if (fixed == null) fixed = .{ (min_y + max_y) / 2, @as(f32, size) * 0.85 / @max(max_y - min_y, 1) };
        const center_y = fixed.?[0];
        const scale = fixed.?[1];
        const project = struct {
            fn f(p: [3]f32, c: f32, s_: f32, k: f32, cy_: f32) [3]f32 {
                const x = p[0] * c + p[2] * s_;
                const z = -p[0] * s_ + p[2] * c;
                return .{ size / 2 + x * k, size / 2 - (p[1] - cy_) * k, z };
            }
        }.f;
        const light = [3]f32{ 0.4, 0.7, -0.6 };
        for (parts.items) |d| for (d.model.mesh.parts, d.pts) |part, ppts| {
            for (part.triangles) |t| {
                var sp: [3][3]f32 = undefined;
                var uv: [3][2]f32 = undefined;
                for (0..3) |k| {
                    sp[k] = project(ppts[t[k]], cy, sy, scale, center_y);
                    uv[k] = part.vertices[t[k]].uv;
                }
                const e1 = og.vec.sub(ppts[t[1]], ppts[t[0]]);
                const e2 = og.vec.sub(ppts[t[2]], ppts[t[0]]);
                const n = og.vec.cross(e1, e2);
                const len = og.vec.len(n);
                const shade = if (len > 0) 0.45 + 0.55 * @abs((n[0] * light[0] + n[1] * light[1] + n[2] * light[2]) / len) else 1;
                canvas.triangle(sp, uv, d.model.texture, og.render.raster.gray(shade));
            }
        };
        _ = tex;
        try export_cmd.writePng(io, gpa, Io.Dir.cwd(), out_path, canvas.img);
        try out.print("{s} {s} frame {d} ({d}..{d}), {d} parts -> {s}\n", .{ name, a.name, frame, a.first, a.last, mesh.parts.len, out_path });
    }
}

pub var flash_spec: ?[]const u8 = null;

const Drawn = struct { model: *const og.actor.model_cache.Model, pts: [][][3]f32 };

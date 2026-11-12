//! What a location is drawn with, read from its assets by logical path (loaders/assets.zig
//! `Stack`): sprite frame counts, the background's size, the backdrop (background, depth,
//! lights, camera config), voices. Both readers give their world's source these
//! (loaders/world.zig for Classic, loaders/ogs.zig for OpenGorky): assets only, no
//! Classic files.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assets = @import("assets.zig");
const sprite = @import("../formats.zig").sprite;
const jpeg = @import("../formats.zig").jpeg;
const level_fmt = @import("../formats.zig").level;
const lights_fmt = @import("../formats.zig").level_files;
const zbuffer = @import("../formats.zig").zbuffer;
const map = @import("../core.zig").map;

/// Frames of `levels/<level>/sprites/<name>.spr` by its header (capped to fit an i32);
/// 0: none or not a sprite.
pub fn frameCount(s: *assets.Stack, level: []const u8, name: []const u8) u32 {
    var buf: [assets.max_path]u8 = undefined;
    var head: [12]u8 = undefined;
    if (s.head(assets.levelSprite(&buf, level, name, "spr") orelse return 0, &head) != head.len) return 0;
    if (!std.mem.eql(u8, head[0..4], sprite.magic)) return 0;
    return @min(std.mem.readInt(u32, head[8..12], .little), std.math.maxInt(i32));
}

/// `levels/<level>/background.bkg` (its header) or `.jpg`.
pub fn backgroundSize(s: *assets.Stack, gpa: Allocator, level: []const u8) ?[2]u32 {
    const px = pictureSize(s, gpa, level) orelse return null;
    // A high-resolution picture (k times its `.zbf`) spans the level's own size.
    var buf: [assets.max_path]u8 = undefined;
    var head: [12]u8 = undefined;
    const zname = std.fmt.bufPrint(&buf, "levels/{s}/background.zbf", .{level}) catch return px;
    const z: ?[2]u32 = if (s.head(zname, &head) == 12 and std.mem.eql(u8, head[0..4], "zbc1")) .{ std.mem.readInt(u32, head[4..8], .little), std.mem.readInt(u32, head[8..12], .little) } else null;
    const k = map.bgScale(px[0], px[1], z);
    return .{ px[0] / k, px[1] / k };
}

/// The background picture's own pixels.
fn pictureSize(s: *assets.Stack, gpa: Allocator, level: []const u8) ?[2]u32 {
    var buf: [assets.max_path]u8 = undefined;
    for ([_][]const u8{ "bkg", "jpg" }) |ext| {
        const name = std.fmt.bufPrint(&buf, "levels/{s}/background.{s}", .{ level, ext }) catch return null;
        if (!s.exists(name)) continue;
        if (ext[0] == 'b') {
            var head: [20]u8 = undefined;
            if (s.head(name, &head) != 20) return null;
            return .{ std.mem.readInt(u32, head[12..16], .little), std.mem.readInt(u32, head[16..20], .little) };
        }
        const data = s.read(gpa, name) catch return null;
        defer gpa.free(data);
        return jpeg.size(data);
    }
    return null;
}

/// `levels/<level>/background.bkg|jpg|cfg|zbf`, `lights.lts`, in `a`.
pub fn backdrop(s: *assets.Stack, a: Allocator, level: []const u8) !map.Backdrop {
    var buf: [assets.max_path]u8 = undefined;
    var b: map.Backdrop = .{};
    for ([_][]const u8{ "bkg", "jpg" }) |ext| {
        const name = try std.fmt.bufPrint(&buf, "levels/{s}/background.{s}", .{ level, ext });
        if (!s.exists(name)) continue;
        b.background = try a.dupe(u8, name);
        break;
    }
    if (try readOr(s, a, try std.fmt.bufPrint(&buf, "levels/{s}/lights.lts", .{level}))) |text| {
        const l = try lights_fmt.parseLights(a, text);
        const omni = try a.alloc(map.Omni, l.omni.len);
        for (omni, l.omni) |*o, x| o.* = .{ .pos = x.pos, .color = x.color, .range = x.range };
        b.lights = .{ .omni = omni, .ambient = l.ambient, .directional_color = l.directional_color, .shadow_light = l.shadow_light, .shadow_intensity = l.shadow_intensity };
    }
    if (try readOr(s, a, try std.fmt.bufPrint(&buf, "levels/{s}/background.cfg", .{level}))) |text| {
        if (level_fmt.parseCfg(text)) |c| {
            b.ortho = .{ .gscale = c.gscale, .g0 = c.g0, .g1 = c.g1 };
        } else if (level_fmt.parsePerspCfg(text)) |c| b.persp = .{ .eye = c.eye, .target = c.target, .tl = c.tl };
    }
    if (try readOr(s, a, try std.fmt.bufPrint(&buf, "levels/{s}/background.zbf", .{level}))) |bytes| {
        const z = try zbuffer.decode(a, bytes);
        b.heights = .{ .width = z.width, .height = z.height, .depth = z.depth };
    }
    return b;
}

/// Asset `path` in `a`; null: none.
fn readOr(s: *assets.Stack, a: Allocator, path: []const u8) !?[]u8 {
    return s.read(a, path) catch |err| switch (err) {
        error.NotFound => null,
        else => err,
    };
}

/// Voice `name` of `common/voice.dat` (`voice/<name>`, `music/<name>`); missing: no.
pub fn hasVoice(s: *assets.Stack, name: []const u8) bool {
    var buf: [assets.max_path]u8 = undefined;
    return s.exists(assets.fromEntry(&buf, "common/voice.dat", name) orelse return false);
}

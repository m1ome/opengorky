//! Character animations: the `.ani` list and `.bfr` bone frames.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SoundCue = struct {
    name: []const u8,
    frame: u32,
    volume: u8,
};

pub const Animation = struct {
    name: []const u8,
    /// Global frame numbers in `.bfr`, inclusive.
    first: u32,
    last: u32,
    speed: f32,
    sounds: []SoundCue,

    /// Shown frame for step `fr` (first…last): reversed, the exe counts down from
    /// last (0x44fb3b, 0x44fc05) and matches frame sounds against it (0x44fb92).
    pub fn shown(self: Animation, fr: u32, reverse: bool) u32 {
        return if (reverse) self.last - (fr - self.first) else fr;
    }
};

pub const AnimList = struct {
    arena: std.heap.ArenaAllocator,
    items: []Animation,

    pub fn deinit(self: *AnimList) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn find(self: AnimList, name: []const u8) ?*const Animation {
        for (self.items) |*a| if (std.ascii.eqlIgnoreCase(a.name, name)) return a;
        return null;
    }
};

const Error = error{Truncated} || Allocator.Error;

/// `.ani`: `u32 n`, then n records: name string, `u32 first`, `u32 last`,
/// `f32 speed`, `u32 sounds`, sounds (string, `u32 frame`, `u8 volume`).
/// A string is `u32 length` + bytes. Result strings point into `bytes`.
pub fn parseAni(gpa: Allocator, bytes: []const u8) Error!AnimList {
    var list: AnimList = .{ .arena = .init(gpa), .items = &.{} };
    errdefer list.arena.deinit();
    const a = list.arena.allocator();
    var pos: usize = 0;
    const R = struct {
        fn take(b: []const u8, p: *usize, n: usize) Error![]const u8 {
            if (p.* + n > b.len) return error.Truncated;
            defer p.* += n;
            return b[p.*..][0..n];
        }
        fn u32_(b: []const u8, p: *usize) Error!u32 {
            return std.mem.readInt(u32, (try take(b, p, 4))[0..4], .little);
        }
        fn str(b: []const u8, p: *usize) Error![]const u8 {
            return take(b, p, try u32_(b, p));
        }
    };
    const n = try R.u32_(bytes, &pos);
    if (n > bytes.len) return error.Truncated;
    list.items = try a.alloc(Animation, n);
    for (list.items) |*anim| {
        anim.name = try R.str(bytes, &pos);
        anim.first = try R.u32_(bytes, &pos);
        anim.last = try R.u32_(bytes, &pos);
        anim.speed = @bitCast(try R.u32_(bytes, &pos));
        const ns = try R.u32_(bytes, &pos);
        if (ns > bytes.len) return error.Truncated;
        anim.sounds = try a.alloc(SoundCue, ns);
        for (anim.sounds) |*s| s.* = .{
            .name = try R.str(bytes, &pos),
            .frame = try R.u32_(bytes, &pos),
            .volume = (try R.take(bytes, &pos, 1))[0],
        };
    }
    return list;
}

/// The `.ani` bytes of `items` (as parseAni reads them; the game's files come back
/// byte for byte, `gorky-tool models` checks).
pub fn writeAni(gpa: Allocator, items: []const Animation) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const W = struct {
        fn u32_(o: *std.ArrayList(u8), g: Allocator, v: u32) Allocator.Error!void {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, v, .little);
            try o.appendSlice(g, &b);
        }
        fn str(o: *std.ArrayList(u8), g: Allocator, s: []const u8) Allocator.Error!void {
            try u32_(o, g, @intCast(s.len));
            try o.appendSlice(g, s);
        }
    };
    try W.u32_(&out, gpa, @intCast(items.len));
    for (items) |an| {
        try W.str(&out, gpa, an.name);
        try W.u32_(&out, gpa, an.first);
        try W.u32_(&out, gpa, an.last);
        try W.u32_(&out, gpa, @bitCast(an.speed));
        try W.u32_(&out, gpa, @intCast(an.sounds.len));
        for (an.sounds) |s| {
            try W.str(&out, gpa, s.name);
            try W.u32_(&out, gpa, s.frame);
            try out.append(gpa, s.volume);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// `.bfr`: `u32 frames`, then `frames × bones` 3×4 matrices (12 f32: 3×3 rotation,
/// translation), then `frames × 6 f32` — the skinned mesh bounds (min xyz, max xyz)
/// for culling, lights and shadows (0x443790, 0x47f070, 0x419970).
/// Bone count = joint count in `.msh`.
pub const BoneFrames = struct {
    frames: u32,
    bones: u32,
    /// Copy of the matrices (file data is not 4-aligned after the archive header).
    matrices: [][12]f32,
    extra: [][6]f32,

    pub fn deinit(self: *BoneFrames, gpa: Allocator) void {
        gpa.free(self.matrices);
        gpa.free(self.extra);
        self.* = undefined;
    }

    pub fn matrix(self: BoneFrames, frame: u32, bone: u32) *const [12]f32 {
        return &self.matrices[@as(usize, frame) * self.bones + bone];
    }
};

/// Animation frames are within `.bfr`, and a boned mesh has at least one frame;
/// otherwise `BoneFrames.matrix` reads past the array (true for every game model).
pub fn checkFrames(list: AnimList, frames: BoneFrames) error{AnimOutOfRange}!void {
    if (frames.bones > 0 and frames.frames == 0) return error.AnimOutOfRange;
    for (list.items) |a| if (a.first > a.last or a.last >= frames.frames) return error.AnimOutOfRange;
}

/// The exe's limits on animations (loader 0x44e7f0): names are strncpy'd into 32 bytes
/// (0x44ea06) and sound names into 64 (0x44ecae), every string read into a 128-byte
/// buffer; frames are indexed unchecked (0x44f9ac) with the mesh joint count as the
/// `.bfr` stride (0x44c012).
pub fn checkLimits(list: []const Animation, frames: BoneFrames, joints: usize) error{ NameTooLong, AnimOutOfRange, BonesMismatch }!void {
    if (frames.bones != joints) return error.BonesMismatch;
    if (frames.bones > 0 and frames.frames == 0) return error.AnimOutOfRange;
    for (list) |a| {
        if (a.name.len > 31) return error.NameTooLong;
        for (a.sounds) |s| if (s.name.len > 63) return error.NameTooLong;
        if (a.first > a.last or a.last >= frames.frames) return error.AnimOutOfRange;
    }
}

pub fn parseBfr(gpa: Allocator, bytes: []const u8, bones: u32) Error!BoneFrames {
    if (bytes.len < 4) return error.Truncated;
    const frames = std.mem.readInt(u32, bytes[0..4], .little);
    const n_mats = @as(usize, frames) * bones;
    const size = std.math.add(usize, std.math.mul(usize, n_mats, 48) catch return error.Truncated, @as(usize, frames) * 24 + 4) catch return error.Truncated;
    if (size != bytes.len) return error.Truncated;
    const mats = try gpa.alloc([12]f32, n_mats);
    errdefer gpa.free(mats);
    for (mats, 0..) |*m, i| for (m, 0..) |*v, k| {
        v.* = @bitCast(std.mem.readInt(u32, bytes[4 + i * 48 + k * 4 ..][0..4], .little));
    };
    const extra = try gpa.alloc([6]f32, frames);
    const base = 4 + n_mats * 48;
    for (extra, 0..) |*e, i| for (e, 0..) |*v, k| {
        v.* = @bitCast(std.mem.readInt(u32, bytes[base + i * 24 + k * 4 ..][0..4], .little));
    };
    return .{ .frames = frames, .bones = bones, .matrices = mats, .extra = extra };
}

/// The `.bfr` bytes of `f` (as parseBfr reads them).
pub fn writeBfr(gpa: Allocator, f: BoneFrames) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, 4 + f.matrices.len * 48 + f.extra.len * 24);
    std.mem.writeInt(u32, out[0..4], f.frames, .little);
    var pos: usize = 4;
    for (f.matrices) |m| for (m) |v| {
        std.mem.writeInt(u32, out[pos..][0..4], @bitCast(v), .little);
        pos += 4;
    };
    for (f.extra) |e| for (e) |v| {
        std.mem.writeInt(u32, out[pos..][0..4], @bitCast(v), .little);
        pos += 4;
    };
    return out;
}

test parseAni {
    const gpa = std.testing.allocator;
    const bytes = [_]u8{ 1, 0, 0, 0, 3, 0, 0, 0 } ++ "run".* ++ [_]u8{ 5, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0x80, 0x3f, 1, 0, 0, 0, 1, 0, 0, 0, 'a', 7, 0, 0, 0, 100 };
    var l = try parseAni(gpa, &bytes);
    defer l.deinit();
    const a = l.find("RUN").?;
    try std.testing.expectEqual(5, a.first);
    try std.testing.expectEqual(9, a.last);
    try std.testing.expectEqual(1.0, a.speed);
    try std.testing.expectEqualStrings("a", a.sounds[0].name);
    try std.testing.expectEqual(7, a.sounds[0].frame);
    const back = try writeAni(gpa, l.items);
    defer gpa.free(back);
    try std.testing.expectEqualSlices(u8, &bytes, back);
}

test "bfr with overflowing size is an error" {
    const bytes = [_]u8{ 0xff, 0xff, 0xff, 0xff };
    try std.testing.expectError(error.Truncated, parseBfr(std.testing.allocator, &bytes, 0xffff_ffff));
}

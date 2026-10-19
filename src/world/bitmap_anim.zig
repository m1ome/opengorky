//! Background 2D animations: BitmapAnimation (0x4b3c50) and ActiveBitmapAnimation
//! (0x4b41f0) — frames by `speed`, the `state` machine, ABA_Impulse.

const std = @import("std");
const state_object = @import("../state.zig").object;
const value = @import("../script.zig").value;
const archive = @import("../formats.zig").archive;
const sprite = @import("../formats.zig").sprite;
const runtime = @import("../script.zig").runtime;
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;
const Runtime = runtime.Runtime;
const speed_divisor = world.speed_divisor;

fn frameCount(self: *World, sprite_name: []const u8) u32 {
    var lower_buf: [archive.name_size]u8 = undefined;
    if (sprite_name.len + 4 > lower_buf.len) return 0;
    const key = std.ascii.lowerString(&lower_buf, sprite_name);
    if (self.res.frame_counts.get(key)) |n| return n;
    const n = readFrameCount(self, sprite_name) catch 0;
    const a = self.arena_state.allocator();
    const owned = a.dupe(u8, key) catch return n;
    self.res.frame_counts.put(a, owned, n) catch {};
    return n;
}

fn readFrameCount(self: *World, sprite_name: []const u8) !u32 {
    var buf: [archive.name_size]u8 = undefined;
    const e = self.res.sprites.find(try std.fmt.bufPrint(&buf, "{s}.spr", .{sprite_name})) orelse return 0;
    var head: [12]u8 = undefined;
    if (e.size < head.len or try self.res.sprites.file.readPositionalAll(self.io, &head, e.offset) != head.len) return 0;
    if (!std.mem.eql(u8, head[0..4], sprite.magic)) return 0;
    // The header count must fit the i32 @intCast in the animations.
    return @min(std.mem.readInt(u32, head[8..12], .little), std.math.maxInt(i32));
}

/// The accumulator compare is unsigned (`jb`/`jae`, 0x4b3c77, 0x4b426c): a negative speed
/// makes the exe spin ~2³²/30 frames; same arithmetic here.
fn advance(n: *state_object.Native, speed: i32) i32 {
    const acc: u32 = @bitCast(n.acc +% speed);
    n.acc = @bitCast(acc % speed_divisor);
    return @bitCast(acc / speed_divisor);
}

/// BitmapAnimation::Update (0x4b3c50): looping animation.
pub fn updateAnimation(self: *World, o: *Object, n: *state_object.Native) void {
    const count: i32 = @intCast(frameCount(self, o.getString("spriteFile")));
    var frame = o.getInt("cur_frame") +% advance(n, o.getInt("speed"));
    // `idiv` remainder (0x4b3d0e): a negative frame stays negative.
    if (count > 0) frame = @rem(frame, count);
    o.setInt("cur_frame", frame);
}

/// ActiveBitmapAnimation::Update (0x4b41f0): `state` machine (0 closed, 1 opening,
/// 2 open, 3 closing).
pub fn updateActiveAnimation(self: *World, o: *Object, n: *state_object.Native) void {
    if (n.aba_move) |*mv| {
        const t = mv.t;
        // _ftol((to − from)·t + from) in x87 precision (0x4b4549…0x4b4588).
        o.setInt("pos_x", value.floatToInt(@as(f64, @floatFromInt(mv.to[0] - mv.from[0])) * t + @as(f64, @floatFromInt(mv.from[0]))));
        o.setInt("pos_y", value.floatToInt(@as(f64, @floatFromInt(mv.to[1] - mv.from[1])) * t + @as(f64, @floatFromInt(mv.from[1]))));
        mv.t += mv.step;
        if (mv.t >= 1) {
            o.setInt("pos_x", mv.to[0]);
            o.setInt("pos_y", mv.to[1]);
            n.aba_move = null;
        }
    }
    const count: i32 = @intCast(frameCount(self, o.getString("spriteFile")));
    if (count == 0) {
        o.setInt("cur_frame", 0);
        return;
    }
    const last = count - 1;
    var frame = o.getInt("cur_frame");
    switch (o.getInt("state")) {
        0 => frame = 0,
        1 => {
            frame +%= advance(n, o.getInt("speed"));
            if (o.getInt("unistate") != 0) {
                // One-shot animation (explosion, dust): hide after the end.
                if (frame > last) {
                    frame = 0;
                    o.setInt("state", 0);
                }
            } else if (frame >= last) {
                frame = last;
                o.setInt("state", 2);
            }
        },
        2 => frame = last,
        3 => {
            frame -%= advance(n, o.getInt("speed"));
            if (frame <= 0) {
                frame = 0;
                o.setInt("state", 0);
            }
        },
        else => {},
    }
    o.setInt("cur_frame", frame);
}

/// ABA_Impulse (0x4b4424): reverse direction. `forbid` 1 blocks opening, 2 blocks closing
/// (meaning inferred from the code; scripts never pass it).
pub fn impulse(o: *Object, forbid: i32) void {
    switch (o.getInt("state")) {
        0, 3 => if (forbid != 1) o.setInt("state", 1),
        1, 2 => if (forbid != 2) o.setInt("state", 3),
        else => {},
    }
}

test "active animation state machine" {
    // State machine on a bare object without game files.
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = undefined, .fetch = undefined });
    defer rt.deinit();
    var cls: @import("../script.zig").object.Class = .{ .name = "door.aba", .parent = null };
    try cls.vars.appendSlice(rt.arena(), &.{
        .{ .type = .int, .name = "state", .line = 0 },
        .{ .type = .int, .name = "cur_frame", .line = 0 },
        .{ .type = .int, .name = "speed", .line = 0 },
        .{ .type = .int, .name = "unistate", .line = 0 },
    });
    const o = try rt.createObject("door", &cls);
    o.setInt("speed", 30);
    try std.testing.expectEqual(0, o.getInt("state"));
    impulse(o, 0);
    try std.testing.expectEqual(1, o.getInt("state"));
    impulse(o, 0);
    try std.testing.expectEqual(3, o.getInt("state"));
    // From "closing" it opens again; forbidding close (2) doesn't prevent that.
    impulse(o, 2);
    try std.testing.expectEqual(1, o.getInt("state"));
    // Forbidding open (1) keeps a closed door closed.
    o.setInt("state", 0);
    impulse(o, 1);
    try std.testing.expectEqual(0, o.getInt("state"));
}

test "advance: unsigned accumulator like 0x4b3c77" {
    var n: state_object.Native = .{ .kind = .other };
    try std.testing.expectEqual(1, advance(&n, 45));
    try std.testing.expectEqual(15, n.acc);
    n.acc = 0;
    // Negative speed: 0xffffffff / 30 frames, remainder 15.
    try std.testing.expectEqual(143165576, advance(&n, -1));
    try std.testing.expectEqual(15, n.acc);
}

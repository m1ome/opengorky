//! Script builtins: objects, sound, misc.

const std = @import("std");
const fields = @import("../fields.zig");
const runtime = @import("../script.zig").runtime;
const world = @import("../state.zig").world;
const crt_rand = @import("../crt_rand.zig");
const World = world.World;
const Object = @import("../script.zig").object.Object;
const Runtime = runtime.Runtime;
const Value = @import("../script.zig").value.Value;
const args_mod = @import("args.zig");

pub fn biStricmp(_: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const a = args_mod.argString(args, 0);
    const b = args_mod.argString(args, 1);
    var i: usize = 0;
    while (i < a.len and i < b.len) : (i += 1) {
        const x = std.ascii.toLower(a[i]);
        const y = std.ascii.toLower(b[i]);
        if (x != y) return .{ .int = @as(i32, x) - @as(i32, y) };
    }
    return .{ .int = @as(i32, @intCast(a.len)) - @as(i32, @intCast(b.len)) };
}

pub fn biPrint(_: *anyopaque, _: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    for (args) |a| std.log.info("{s}: print {f}", .{ self.name, a });
    return .zero;
}

pub fn biGetName(_: *anyopaque, _: *Runtime, self: *Object, _: []const Value) anyerror!Value {
    return .{ .string = self.name };
}

pub fn biEnableObject(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    if (args_mod.targetObject(ctx, rt, args)) |o| o.enabled = true;
    return .zero;
}

pub fn biDisableObject(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    if (args_mod.targetObject(ctx, rt, args)) |o| o.enabled = false;
    return .zero;
}

pub fn biDeleteObject(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    if (args_mod.targetObject(ctx, rt, args)) |o| {
        o.enabled = false;
        World.nativeOf(o).deleted = true;
    }
    return .zero;
}

/// PlaySound(name[, int]) (0x4c19d0 → 0x432090): the second argument is the loop flag.
/// The sound is attached to the calling script's object (position via vfunc +0x14).
pub fn biPlaySound(ctx: *anyopaque, _: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const name = args_mod.argString(args, 0);
    if (name.len == 0) return .zero;
    const loop = args.len > 1 and args[1] == .int and args[1].int != 0;
    try w.out.sound_events.append(w.gpa, .{ .name = name, .pos = w.soundPos(self), .loop = loop });
    return .zero;
}

/// PlayRandomSound2D(x, y, "a,b,c"[, chance]) (0x4c1b70, 0x4c1a30): with chance > 0
/// the sound plays only if rand() % chance == 0; then srand(tick) (0x4c1a52) and
/// rand() % count picks from the comma list (up to 10 variants).
pub fn biPlayRandomSound2D(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    // Argument types are checked strictly: int, int, string.
    if (args.len < 3 or args[0] != .int or args[1] != .int or args[2] != .string) return .zero;
    const rand = w.crt();
    const chance: i32 = if (args.len > 3) args[3].toInt() else -1;
    if (chance > 0 and @rem(rand.next(), chance) != 0) return .zero;
    // srand(process frame counter [0x54c46c]) before picking the variant (0x4c1a52).
    rand.seed(crt_rand.frames);

    var variants: [10][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, args[2].string, ',');
    while (it.next()) |v| {
        if (n == variants.len) break;
        variants[n] = v;
        n += 1;
    }
    const name = variants[rand.below(@intCast(n))];
    try w.out.sound_events.append(w.gpa, .{
        .name = name,
        .pos = .{ @floatFromInt(args[0].int), @floatFromInt(args[1].int) },
        .loop = false,
    });
    return .zero;
}

/// Ambient_New(name, x, y, wav) (0x4c1df0): creates an ambient object, a looping
/// sound at a point. Does nothing if an object with that name exists.
pub fn biAmbientNew(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    if (args.len < 4) return .zero;
    const name = args_mod.argString(args, 0);
    if (name.len == 0 or rt.findObject(name) != null) return .zero;
    const cls = w.ambient_class orelse blk: {
        const c = try rt.arena().create(@import("../script.zig").object.Class);
        c.* = .{ .name = "ambient", .parent = null };
        w.ambient_class = c;
        break :blk c;
    };
    _ = try w.addObject(name, cls, .{ .kind = .ambient, .ambient = .{
        .wav = try rt.arena().dupe(u8, args_mod.argString(args, 3)),
        .pos = .{ args[1].toFloat(), args[2].toFloat() },
    } });
    return .zero;
}

/// IsObject(name) (0x4c1550).
pub fn biIsObject(_: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    return .{ .int = @intFromBool(rt.findObject(args_mod.argString(args, 0)) != null) };
}

/// GetNameID(object) (0x4c12b0): nameID of any object (heroes: 20 Sullivan,
/// 21 Ovitz, 22 Trantigne, 24 Lucy); −1 if there is no object.
pub fn biGetNameID(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.objectArg(ctx, rt, self, args) orelse return .{ .int = -1 };
    return .{ .int = fields.nameId(o) };
}

pub fn biNoop(_: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
    return .zero;
}

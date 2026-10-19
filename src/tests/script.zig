//! Integration tests of the script runtime: classes, inheritance, includes, builtins and
//! control flow, run end-to-end from hand-written sources.

const std = @import("std");
const script = @import("../script.zig");
const Runtime = script.runtime.Runtime;
const Object = script.object.Object;
const Value = script.value.Value;
const object = script.object;

const TestSources = struct {
    files: []const [2][]const u8,

    fn fetch(ctx: *anyopaque, name: []const u8) anyerror!?[]const u8 {
        const self: *TestSources = @ptrCast(@alignCast(ctx));
        for (self.files) |f| if (std.ascii.eqlIgnoreCase(f[0], name)) return f[1];
        return null;
    }
};

fn recordBuiltin(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    _ = rt;
    _ = self;
    const log: *std.ArrayList(i32) = @ptrCast(@alignCast(ctx));
    try log.append(std.testing.allocator, args[0].toInt());
    return .{ .int = args[0].toInt() * 2 };
}

test "class inheritance, vars, includes and builtins" {
    var sources: TestSources = .{ .files = &.{
        .{ "base.s", "int speed;\nstring spriteFile;\nfunction twice(int x) { return(Record(x)); };" },
        .{
            "door.aba",
            \\#inherit Base
            \\int state;
            \\function init()
            \\{
            \\    spriteFile="gate";
            \\    Speed=15;
            \\#include extra.ss
            \\    state = twice(speed) + 0.5;
            \\    if (state > 30 && Missing()) state = -1;
            \\    else { newVar = 2; };
            \\};
        },
        .{ "extra.ss", "speed = speed + 1;" },
    } };
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = &sources, .fetch = TestSources.fetch });
    defer rt.deinit();
    var log: std.ArrayList(i32) = .empty;
    defer log.deinit(std.testing.allocator);
    try rt.registerBuiltin("Record", &log, recordBuiltin);

    const obj = try rt.createObject("door", try rt.loadClass("door.aba"));
    _ = try rt.callIfExists(obj, "init", &.{});

    try std.testing.expectEqualStrings("gate", obj.getString("spritefile"));
    try std.testing.expectEqual(16, obj.getInt("speed"));
    // 16*2 + 0.5 = 32.5 → int 32.
    try std.testing.expectEqual(32, obj.getInt("state"));
    try std.testing.expectEqualSlices(i32, &.{16}, log.items);
    try std.testing.expectEqual(1, rt.missing_builtins.get("Missing"));
    // An undeclared variable is not created (0x44ae80).
    try std.testing.expectEqual(null, obj.getVar("newVar"));
    try std.testing.expect(obj.class.isA("base"));
}

test "#inherit: grandparent functions, mutual inheritance terminates" {
    var sources: TestSources = .{ .files = &.{
        .{ "a.s", "#inherit b\nfunction fa() { return(1); };" },
        .{ "b.s", "#inherit c\n#inherit a\n" },
        .{ "c.s", "function fc() { return(3); };" },
    } };
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = &sources, .fetch = TestSources.fetch });
    defer rt.deinit();
    const a = try rt.loadClass("a.s");
    try std.testing.expect(a.functions.contains(object.findName("fc").?));
    try std.testing.expect(a.functions.contains(object.findName("fa").?));
    // The ancestor chain has no cycles: missing-function lookup and isA terminate.
    try std.testing.expect(a.findFunction("nope") == null);
    try std.testing.expect(!a.isA("zzz"));
    const obj = try rt.createObject("o", a);
    _ = obj;
}

test "#inherit twice: variables of both parents" {
    var sources: TestSources = .{ .files = &.{
        .{ "k.s", "#inherit p\n#inherit q\n" },
        .{ "p.s", "int pv;" },
        .{ "q.s", "int qv;" },
    } };
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = &sources, .fetch = TestSources.fetch });
    defer rt.deinit();
    const obj = try rt.createObject("o", try rt.loadClass("k.s"));
    try std.testing.expect(obj.getVar("pv") != null);
    try std.testing.expect(obj.getVar("qv") != null);
}

test "include of itself inside a function is an error" {
    var sources: TestSources = .{ .files = &.{
        .{ "a.ba", "function f()\n{\n#include self.ss\n};" },
        .{ "self.ss", "#include self.ss\n" },
    } };
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = &sources, .fetch = TestSources.fetch });
    defer rt.deinit();
    const obj = try rt.createObject("a", try rt.loadClass("a.ba"));
    try std.testing.expectError(error.IncludeCycle, rt.callIfExists(obj, "f", &.{}));
}

test "return without value and nested if/else" {
    var sources: TestSources = .{ .files = &.{.{
        "a.ba",
        \\int r;
        \\function f(int a, int b)
        \\{
        \\  if (a) if (b) return(1); else return(2);
        \\  return(3);
        \\};
        \\function g() { r = f(1,0) * 10 + f(0,1); return; r = 99; };
    }} };
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = &sources, .fetch = TestSources.fetch });
    defer rt.deinit();
    const obj = try rt.createObject("a", try rt.loadClass("a.ba"));
    _ = try rt.callIfExists(obj, "g", &.{});
    // `return;` without a value doesn't leave the function in the exe.
    try std.testing.expectEqual(99, obj.getInt("r"));
}

test "first definition wins, && and || as in the exe" {
    var sources: TestSources = .{ .files = &.{
        .{ "base.s", "int n;\nint c;\nint r;\nfunction post_init() { n = 1; };" },
        .{
            "kid.ftr",
            \\#include Base.s
            \\function post_init() { };
            \\function f() { c = c * 10 + 1; return(0); };
            \\function g() { c = c * 10 + 2; return(1); };
            \\function t() { if (1 || 0 && 0) r = 1; else r = 2; n = f() && g(); };
        },
        .{ "heir.ftr", "#inherit Base\nfunction post_init() { };" },
    } };
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = &sources, .fetch = TestSources.fetch });
    defer rt.deinit();
    const kid = try rt.createObject("kid", try rt.loadClass("kid.ftr"));
    _ = try rt.callIfExists(kid, "post_init", &.{});
    try std.testing.expectEqual(1, kid.getInt("n"));
    _ = try rt.callIfExists(kid, "t", &.{});
    // (1 || 0) && 0; both operands, right first.
    try std.testing.expectEqual(2, kid.getInt("r"));
    try std.testing.expectEqual(21, kid.getInt("c"));
    const heir = try rt.createObject("heir", try rt.loadClass("heir.ftr"));
    _ = try rt.callIfExists(heir, "post_init", &.{});
    try std.testing.expectEqual(1, heir.getInt("n"));
}

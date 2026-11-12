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

// ---------------------------------------------------------------- exe quirks through the IR

/// One class `q.ba` from `src`; calls `f(args)` and returns the object.
fn quirk(rt: *Runtime, sources: *TestSources, src: []const u8, args: []const Value) !*Object {
    sources.files = &.{.{ "q.ba", src }};
    const obj = try rt.createObject("q", try rt.loadClass("q.ba"));
    _ = try rt.callIfExists(obj, "f", args);
    return obj;
}

fn quirkRt(sources: *TestSources) Runtime {
    return .init(std.testing.allocator, .{ .ctx = sources, .fetch = TestSources.fetch });
}

test "quirk: assignment converts to the declared type, a string to int is 0" {
    var sources: TestSources = .{ .files = &.{} };
    var rt = quirkRt(&sources);
    defer rt.deinit();
    const o = try quirk(&rt, &sources,
        \\int i; int j; float f; string s;
        \\function f() { i = 1.9; j = "5"; f = 15; s = 15; };
    , &.{});
    try std.testing.expectEqual(1, o.getInt("i"));
    try std.testing.expectEqual(0, o.getInt("j"));
    try std.testing.expectEqual(Value{ .float = 15 }, o.getVar("f").?.value);
    try std.testing.expectEqualStrings("15", o.getString("s"));
}

test "quirk: == truncates floats and calls strings equal; != adds, <= is >=" {
    var sources: TestSources = .{ .files = &.{} };
    var rt = quirkRt(&sources);
    defer rt.deinit();
    const o = try quirk(&rt, &sources,
        \\float x; int a; int b; int c; int d; int e;
        \\function f() { x = 1.5; a = x == 1; b = "a" == "b"; c = 2 != 3; d = 3 <= 5; e = 2 == 2; };
    , &.{});
    try std.testing.expectEqual(1, o.getInt("a"));
    try std.testing.expectEqual(1, o.getInt("b"));
    try std.testing.expectEqual(5, o.getInt("c"));
    try std.testing.expectEqual(0, o.getInt("d"));
    try std.testing.expectEqual(1, o.getInt("e"));
}

test "quirk: operands right first, && evaluates both sides" {
    var sources: TestSources = .{ .files = &.{} };
    var rt = quirkRt(&sources);
    defer rt.deinit();
    var log: std.ArrayList(i32) = .empty;
    defer log.deinit(std.testing.allocator);
    try rt.registerBuiltin("Record", &log, recordBuiltin);
    const o = try quirk(&rt, &sources,
        \\int r; int s;
        \\function f() { r = Record(1) - Record(2); s = 0 && Record(3); };
    , &.{});
    // 1*2 - 2*2, the right call first; `0 && …` still makes the call.
    try std.testing.expectEqual(-2, o.getInt("r"));
    try std.testing.expectEqual(0, o.getInt("s"));
    try std.testing.expectEqualSlices(i32, &.{ 2, 1, 3 }, log.items);
}

test "quirk: truth truncates a float and calls a string false" {
    var sources: TestSources = .{ .files = &.{} };
    var rt = quirkRt(&sources);
    defer rt.deinit();
    const o = try quirk(&rt, &sources,
        \\float h; string t; int a; int b; int c;
        \\function f() { h = 0.5; t = "x"; if (h) a = 1; if (t) b = 1; c = !h; };
    , &.{});
    try std.testing.expectEqual(0, o.getInt("a"));
    try std.testing.expectEqual(0, o.getInt("b"));
    try std.testing.expectEqual(1, o.getInt("c"));
}

test "quirk: string arithmetic, division by 0, _ftol, NaN as x87" {
    var sources: TestSources = .{ .files = &.{} };
    var rt = quirkRt(&sources);
    defer rt.deinit();
    const o = try quirk(&rt, &sources,
        \\int a; int b; int c; int d; int e; float n; int g; int l;
        \\function f() { a = "5" + 1; b = -"5"; c = 1 / 0; d = 3000000000.0; n = 0.0 / 0.0; g = n > 1; l = n < 1; e = 7 / -2; };
    , &.{});
    try std.testing.expectEqual(1, o.getInt("a"));
    try std.testing.expectEqual(-5, o.getInt("b"));
    try std.testing.expectEqual(0, o.getInt("c"));
    try std.testing.expectEqual(-1294967296, o.getInt("d"));
    try std.testing.expectEqual(1, o.getInt("g"));
    try std.testing.expectEqual(0, o.getInt("l"));
    try std.testing.expectEqual(-3, o.getInt("e"));
}

test "quirk: unknown names, this, scene object names, undeclared assignment" {
    var sources: TestSources = .{ .files = &.{} };
    var rt = quirkRt(&sources);
    defer rt.deinit();
    sources.files = &.{.{ "o.ba", "int k;" }};
    _ = try rt.createObject("Slavsky", try rt.loadClass("o.ba"));
    const o = try quirk(&rt, &sources,
        \\string a; string b; string c;
        \\function f() { a = slavsky; b = nobody; c = THIS; undeclared = 3; };
    , &.{});
    try std.testing.expectEqualStrings("Slavsky", o.getString("a"));
    try std.testing.expectEqualStrings("0", o.getString("b"));
    try std.testing.expectEqualStrings("q", o.getString("c"));
    try std.testing.expectEqual(1, rt.unknown_names.get("nobody"));
    try std.testing.expectEqual(1, rt.unknown_names.get("undeclared"));
}

test "quirk: a local declared on one path only falls back to the object variable" {
    var sources: TestSources = .{ .files = &.{} };
    var rt = quirkRt(&sources);
    defer rt.deinit();
    const o = try quirk(&rt, &sources,
        \\int x; int r; int s;
        \\function f(int a) { x = 7; if (a) { int x; x = 5; }; r = x; x = 9; };
        \\function g() { s = x; };
    , &.{.{ .int = 0 }});
    try std.testing.expectEqual(7, o.getInt("r"));
    try std.testing.expectEqual(9, o.getInt("x"));
    _ = try rt.callIfExists(o, "f", &.{.{ .int = 1 }});
    // The local took the reads and the write.
    try std.testing.expectEqual(5, o.getInt("r"));
    try std.testing.expectEqual(7, o.getInt("x"));
}

test "quirk: a class function shadows the builtin; over 32 arguments is 0 unevaluated" {
    var sources: TestSources = .{ .files = &.{} };
    var rt = quirkRt(&sources);
    defer rt.deinit();
    var log: std.ArrayList(i32) = .empty;
    defer log.deinit(std.testing.allocator);
    try rt.registerBuiltinSig("Record", &log, recordBuiltin, .{ .text = "int(int)", .pure = true });
    const o = try quirk(&rt, &sources,
        \\int r; int s;
        \\function Record(int x) { r = r + 10; return(x); };
        \\function f() { s = Record(4); r = r + Record(1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33); };
    , &.{});
    try std.testing.expectEqual(4, o.getInt("s"));
    try std.testing.expectEqual(10, o.getInt("r"));
    try std.testing.expectEqual(0, log.items.len);
    // The class's function made the builtin's "pure" unusable: any older IR is stale.
    try std.testing.expect(rt.ir_gen > 0);
}

test "quirk: include in a function inlines statements and locals; deep calls overflow" {
    var sources: TestSources = .{ .files = &.{} };
    var rt = quirkRt(&sources);
    defer rt.deinit();
    sources.files = &.{
        .{ "q.ba", "int r;\nfunction f()\n{\n#include part.ss\n  r = n * 2;\n};\nfunction deep() { deep(); };" },
        .{ "part.ss", "int n;\nn = 21;\n" },
    };
    const o = try rt.createObject("q", try rt.loadClass("q.ba"));
    _ = try rt.callIfExists(o, "f", &.{});
    try std.testing.expectEqual(42, o.getInt("r"));
    try std.testing.expect(o.getVar("n") == null);
    try std.testing.expectError(error.StackOverflow, rt.callIfExists(o, "deep", &.{}));
}

test "quirk: a missing include fails where it stands and is retried on the next call" {
    var sources: TestSources = .{ .files = &.{} };
    var rt = quirkRt(&sources);
    defer rt.deinit();
    sources.files = &.{.{ "q.ba", "int r;\nfunction f(int a)\n{\n  r = 1;\n  if (a)\n  {\n#include late.ss\n  };\n};" }};
    const o = try rt.createObject("q", try rt.loadClass("q.ba"));
    _ = try rt.callIfExists(o, "f", &.{.{ .int = 0 }});
    try std.testing.expectEqual(1, o.getInt("r"));
    try std.testing.expectError(error.ScriptNotFound, rt.callIfExists(o, "f", &.{.{ .int = 1 }}));
    sources.files = &.{ sources.files[0], .{ "late.ss", "r = 2;" } };
    _ = try rt.callIfExists(o, "f", &.{.{ .int = 1 }});
    try std.testing.expectEqual(2, o.getInt("r"));
}

test "import: plain nodes only where the exe behaves the same" {
    var sources: TestSources = .{ .files = &.{} };
    var rt = quirkRt(&sources);
    defer rt.deinit();
    try rt.registerBuiltinSig("Pure", &rt, recordBuiltin, .{ .text = "int(int)", .pure = true });
    sources.files = &.{.{ "q.ba", "int v;\nfunction f(int a, int b) { if (a == 1 && Pure(b)) v = a + b; if (v == 1 || a) v = -v; };" }};
    const cls = try rt.loadClass("q.ba");
    const f = try rt.compiled(cls.findFunctionId(object.findName("f").?).?);
    const ir = script.ir;
    // Locals and a pure int builtin: `==` and `&&` are plain, short-circuit.
    const c1 = f.body[0].kind.@"if".cond.kind.logic;
    try std.testing.expectEqual(ir.LogicOp.@"and", c1.op);
    try std.testing.expectEqual(ir.BinaryOp.eq, c1.lhs.kind.binary.op);
    try std.testing.expectEqual(ir.BinaryOp.add, f.body[0].kind.@"if".then[0].kind.assign.value.kind.binary.op);
    // An object variable has no static type: `exe.eq`, truth through `exe.truthy`.
    const c2 = f.body[1].kind.@"if".cond.kind.logic;
    try std.testing.expectEqual(ir.ExeOp.eq, c2.lhs.kind.exe.op);
    try std.testing.expectEqual(ir.ExeOp.neg, f.body[1].kind.@"if".then[0].kind.assign.value.kind.exe.op);
}

test ".var values apply before init: int is the leading digits" {
    var sources: TestSources = .{ .files = &.{} };
    var rt = quirkRt(&sources);
    defer rt.deinit();
    const o = try quirk(&rt, &sources, "int i; float f;\nfunction g() { };", &.{});
    rt.applyVar(o, "I", "-1");
    rt.applyVar(o, "f", " 2.5x");
    try std.testing.expectEqual(0, o.getInt("i"));
    try std.testing.expectEqual(Value{ .float = 2.5 }, o.getVar("f").?.value);
}

fn first(_: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    return if (args.len > 0) args[0] else .zero;
}

test "OGS data blocks checked against the schema (core/schema.zig), sigils, errors with their line" {
    var src: TestSources = .{ .files = &.{} };
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = &src, .fetch = TestSources.fetch });
    defer rt.deinit();
    rt.schema = @import("../core.zig").schema.blockField;
    try rt.registerBuiltinSig("LEVEL_Load", &src, first, .{ .text = "int(level)", .ogs = "level::Load" });
    try rt.loadOgs("data.ogs", script.ogs.print.data_example);
    // A sigil's value is the plain string.
    const go = rt.ogs.components.get("Go").?;
    const cls = try rt.arena().create(object.Class);
    cls.* = .{ .name = "h.s", .parent = null };
    const c = try rt.attach(try rt.createObject("h", cls), go, &.{});
    try std.testing.expectEqualStrings("01__port_citadel", (try rt.callIfExists(c, "run", &.{})).?.string);

    const bad = [_]struct { []const u8, []const u8 }{
        .{ "fightr x { }", "unknown block kind fightr" },
        .{ "fighter x { hpp = 1; }", "fighter has no field hpp" },
        .{ "fighter x { hp = \"a\"; }", "hp: expected int" },
        .{ "weapon g { place = handd; }", "place: ItemPlace has no value handd" },
        .{ "fighter x: characters::nope { }", "no fighter characters::nope" },
        .{ "fighter x { blast_weapon = weapons::nope; }", "blast_weapon: no weapon weapons::nope" },
        .{ "dialog d { Line(who = speakers::HQ); }", "no block speakers::HQ" },
        .{ "weapon g { ammo = \"items::x\"; }", "ammo: expected an item (~i\"…\")" },
        .{ "weapon g { ammo = -1; }", "ammo: expected an item (~i\"…\")" },
        .{ "item i { action = 1.5; }", "action: expected an action's name (Take), none or walk" },
        .{ "item i { action = -1; }", "action: expected an action's name (Take), none or walk" },
        .{ "item i { action = \"Take\"; }", "action: expected an action's name (Take), none or walk" },
        .{ "weapon g { class = 10; }", "class: expected a weapon class's name (pistol)" },
        .{ "weapon g { attack_zone = \"pistol\"; }", "attack_zone: expected a weapon class's name (pistol)" },
        .{ "item i { funcID = 3; }", "item has no field funcID" },
        .{ "weapon g { thrown = 1; }", "thrown: expected true or false" },
        .{ "level l { entry = 3; }", "entry: expected a point's name (\"capt_start\")" },
        .{ "fighter x { attach Nope(); }", "no component Nope" },
        .{ "look g { walk = [Speed(3.6)]; }", "walk: Speed: a struct takes named fields (f = v)" },
        .{ "scene s { points = [Point(3.6)]; }", "Point: a struct takes named fields (f = v)" },
        .{ "fn f() { return level::Load(~s\"door\"); }", "level::Load: argument 1 is a level, not a sound" },
        .{ "fn f() { return ~q\"x\"; }", "unknown sigil ~q" },
        .{ "fighter x { WALKTO(@a, \"p\"); }", "commands are in scene and dialog blocks only" },
        .{ "fn f() { return classic::nope(1); }", "unknown classic::nope" },
        .{ "module m { fighter x { } } module m { fighter x { } }", "fighter m::x is defined twice" },
    };
    for (bad) |b| {
        if (rt.loadOgs("bad.ogs", b[0])) |_| return error.Loaded else |_| {}
        std.testing.expectEqualStrings(b[1], rt.diag.message) catch |err| {
            std.debug.print("{s}\n", .{b[0]});
            return err;
        };
    }
    if (rt.loadOgs("bad.ogs", "fighter x {\n hpp = 1; }")) |_| return error.Loaded else |_| {}
    try std.testing.expectEqual(2, rt.diag.line);
}

test "the prelude's enums ItemPlace, ItemKind, WeaponKind, Resistance, Effect are the engine's" {
    const item = @import("../inventory.zig").item;
    const schema = @import("../core.zig").schema;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const place = (try schema.engineEnum(arena.allocator(), "ItemPlace")).?;
    const kind = (try schema.engineEnum(arena.allocator(), "ItemKind")).?;
    for (place.values) |w| try std.testing.expectEqualStrings(w.name, @tagName(@as(item.Place, @fromBackingInt(w.number.?))));
    for (kind.values) |w| try std.testing.expectEqualStrings(w.name, @tagName(@as(item.ItemType, @fromBackingInt(w.number.?))));
    try std.testing.expectEqual(@typeInfo(item.Place).@"enum".field_names.len, place.values.len);
    try std.testing.expectEqual(@typeInfo(item.ItemType).@"enum".field_names.len, kind.values.len);
    // WeaponKind: battle/immunity.zig DamageType, plus none (0) and tear gas (4, no resistance).
    const DamageType = @import("../battle.zig").immunity.DamageType;
    const weapon = (try schema.engineEnum(arena.allocator(), "WeaponKind")).?;
    for (weapon.values) |w| if (w.number.? != 0 and w.number.? != 4) try std.testing.expectEqualStrings(w.name, @tagName(@as(DamageType, @fromBackingInt(w.number.?))));
    try std.testing.expectEqual(@typeInfo(DamageType).@"enum".field_names.len + 2, weapon.values.len);
    try std.testing.expectEqualStrings("WeaponKind", schema.field(schema.host("weapon").?, "damage_kind").?.type_name);
    // Resistance: immunity.Resist without armour (9); Effect: rules Effect.
    const Resist = @import("../battle.zig").immunity.Resist;
    const res = (try schema.engineEnum(arena.allocator(), "Resistance")).?;
    for (res.values) |w| try std.testing.expectEqualStrings(w.name, @tagName(@as(Resist, @fromBackingInt(@intCast(w.number.?)))));
    try std.testing.expectEqual(@typeInfo(Resist).@"enum".field_names.len - 1, res.values.len);
    const Effect = @import("../rules.zig").rows.Effect;
    const eff = (try schema.engineEnum(arena.allocator(), "Effect")).?;
    for (eff.values) |w| try std.testing.expectEqualStrings(w.name, @tagName(@as(Effect, @fromBackingInt(@intCast(w.number.?)))));
    try std.testing.expectEqual(@typeInfo(Effect).@"enum".field_names.len, eff.values.len);
    // A fighter's resistances are its `immunity` (Resist row) alone: no field of its own.
    try std.testing.expect(schema.ogField(schema.host("fighter").?, "resist") == null);
    // No engine enum of fighter classes: a project names its own (rules.fighterClassId).
    try std.testing.expect(try schema.engineEnum(arena.allocator(), "BattleClass") == null);
}

test "OGS: str(x) gives any value's text, + joins two strings only; obj.name is read-only" {
    var src: TestSources = .{ .files = &.{} };
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = &src, .fetch = TestSources.fetch });
    defer rt.deinit();
    inline for (@import("../builtins.zig").table) |e| if (comptime std.mem.eql(u8, e[0], "str")) try rt.registerBuiltinSig(e[0], &src, e[1], e[2]);
    try rt.loadOgs("s.ogs",
        \\component S {
        \\    fn run() {
        \\        return str(host.hp) + "!" + str(2.5) + str(true) + str(false) + str(nil) + str(host) + str([1, "a"]) + str({"k": nil}) + str("s");
        \\    }
        \\    fn bad() { return host.hp + "!"; }
        \\    fn names() { return [host.name, @"01pr_garcia1".name, host.NAME]; }
        \\    fn rename() { host.name = "x"; }
        \\}
    );
    const cls = try rt.arena().create(object.Class);
    cls.* = .{ .name = "h.s", .parent = null };
    const h = try rt.createObject("Sullivan", cls);
    try h.declare(rt.arena(), "hp", .{ .type = .int, .value = .{ .int = 40 } });
    // A variable called `name` does not shadow the object's name.
    try h.declare(rt.arena(), "name", .{ .type = .string, .value = .{ .string = "shadow" } });
    _ = try rt.createObject("01pr_garcia1", cls);
    const c = try rt.attach(h, rt.ogs.components.get("S").?, &.{});
    try std.testing.expectEqualStrings("40!2.500000truefalsenilSullivan[1, \"a\"]{\"k\": nil}s", (try rt.callIfExists(c, "run", &.{})).?.string);
    try std.testing.expectError(error.ScriptFault, rt.callIfExists(c, "bad", &.{}));
    try std.testing.expectEqualStrings("40 add \"!\"", rt.fault.message);
    var aw: std.Io.Writer.Allocating = .init(rt.arena());
    try aw.writer.print("{f}", .{(try rt.callIfExists(c, "names", &.{})).?});
    try std.testing.expectEqualStrings("[\"Sullivan\", \"01pr_garcia1\", \"Sullivan\"]", aw.written());
    try std.testing.expectError(error.ScriptFault, rt.callIfExists(c, "rename", &.{}));
    try std.testing.expectEqualStrings("Sullivan.name is read-only", rt.fault.message);
    try std.testing.expectEqualStrings("shadow", h.getString("name"));
}

test "OGS: host.f() and a call by name reach a method of the host's component (a converted class's own functions)" {
    var src: TestSources = .{ .files = &.{} };
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = &src, .fetch = TestSources.fetch });
    defer rt.deinit();
    try rt.loadOgs("c.ogs",
        \\component A {
        \\    fn run() { return host.Play(2) + 1; }
        \\}
        \\component B {
        \\    fn Play(k) { host.hp = host.hp + k; return host.hp; }
        \\}
    );
    const cls = try rt.arena().create(object.Class);
    cls.* = .{ .name = "h.s", .parent = null };
    const h = try rt.createObject("box", cls);
    try h.declare(rt.arena(), "hp", .{ .type = .int, .value = .{ .int = 40 } });
    const c = try rt.attach(h, rt.ogs.components.get("A").?, &.{});
    _ = try rt.attach(h, rt.ogs.components.get("B").?, &.{});
    try std.testing.expectEqual(@as(i32, 43), (try rt.callIfExists(c, "run", &.{})).?.int);
    // The exe's call by name (GO_RunFun, Take): the host answers with its component's method.
    try std.testing.expectEqual(@as(i32, 45), (try rt.callIfExists(h, "play", &.{.{ .int = 3 }})).?.int);
    try std.testing.expect(try rt.callIfExists(h, "nothing", &.{}) == null);
}

test "OGS far references: an object of another location is nil to fields and methods, equal to itself, not here" {
    var src: TestSources = .{ .files = &.{} };
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = &src, .fetch = TestSources.fetch });
    defer rt.deinit();
    inline for (@import("../builtins.zig").table) |e| {
        if (comptime std.mem.eql(u8, e[0], "IsHere")) try rt.registerBuiltinSig(e[0], &src, e[1], e[2]);
    }
    try rt.loadOgs("f.ogs",
        \\component F for fighter {
        \\    var x; var y;
        \\    fn check() { return [x.hp, x.name, x.go(1), object::IsHere(x), object::IsHere(host), object::IsHere(3), x == y, x == host, x]; }
        \\}
    );
    const cls = try rt.arena().create(object.Class);
    cls.* = .{ .name = "h.s", .parent = null };
    const f = try rt.attach(try rt.createObject("grandma", cls), rt.ogs.components.get("F").?, &.{});
    // Two values of the same object of 01_port: one stand-in; a `grandma` here is another.
    f.getVar("x").?.value = try rt.farRef("01_port", "Grandma");
    f.getVar("y").?.value = try rt.farRef("01_Port", "grandma");
    var aw: std.Io.Writer.Allocating = .init(rt.arena());
    try aw.writer.print("{f}", .{(try rt.callIfExists(f, "check", &.{})).?});
    try std.testing.expectEqualStrings("[nil, nil, nil, false, true, false, true, false, @01_port::Grandma]", aw.written());
}

test "OGS events: Subscribe, Emit in subscription order with its values, Unsubscribe, detach drops, depth capped" {
    // The script faults (and missing rows) this test makes on purpose log warnings: not
    // shown, as `zig build test` prints a test binary's stderr under "failed command".
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    var src: TestSources = .{ .files = &.{} };
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = &src, .fetch = TestSources.fetch });
    defer rt.deinit();
    // Emit's own handler needs a World (the battle log); the runtime part is the same.
    const S = struct {
        var order: [64]u8 = undefined;
        var len: usize = 0;
        fn emit(_: *anyopaque, r: *Runtime, _: *Object, args: []const Value) anyerror!Value {
            return .{ .int = @intCast(try r.emit(args[0].string, args[1..])) };
        }
        fn note(_: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
            order[len] = args[0].string[0];
            len += 1;
            return .zero;
        }
    };
    inline for (@import("../builtins.zig").table) |e| {
        if (comptime std.mem.eql(u8, e[0], "str") or std.mem.eql(u8, e[0], "Subscribe") or std.mem.eql(u8, e[0], "Unsubscribe")) try rt.registerBuiltinSig(e[0], &src, e[1], e[2]);
        if (comptime std.mem.eql(u8, e[0], "Emit")) try rt.registerBuiltinSig(e[0], &src, S.emit, e[2]);
    }
    try rt.registerBuiltinSig("Note", &src, S.note, .{ .text = "int(string)" });
    try rt.loadOgs("e.ogs",
        \\component Kid for fighter { fn OnDeath(killer) { return events::Emit("child_died", host, killer); } }
        \\component Grandma for fighter {
        \\    var string got = "";
        \\    fn OnSpawn() { return [events::Subscribe("child_died", "OnChildDied"), events::Subscribe("child_died", "OnChildDied")]; }
        \\    fn OnChildDied(kid, killer, extra) { Note("g"); got += kid.name + "/" + str(killer) + "/" + str(extra); }
        \\    fn stop() { return events::Unsubscribe("child_died"); }
        \\}
        \\component Aunt for fighter { fn OnSpawn() { events::Subscribe("child_died", "heard"); } fn heard(kid) { Note("a"); } }
        \\component Echo for fighter { var int n = 0; fn OnSpawn() { events::Subscribe("echo", "again"); } fn again() { n += 1; events::Emit("echo"); } }
    );
    const cls = try rt.arena().create(object.Class);
    cls.* = .{ .name = "h.s", .parent = null };
    const kid = try rt.attach(try rt.createObject("kid", cls), rt.ogs.components.get("Kid").?, &.{});
    const granny = try rt.attach(try rt.createObject("grandma", cls), rt.ogs.components.get("Grandma").?, &.{});
    const aunt_host = try rt.createObject("aunt", cls);
    const aunt = try rt.attach(aunt_host, rt.ogs.components.get("Aunt").?, &.{});
    // The aunt subscribes first, so she hears first; the second Subscribe is a no-op.
    _ = try rt.callIfExists(aunt, "OnSpawn", &.{});
    var aw: std.Io.Writer.Allocating = .init(rt.arena());
    try aw.writer.print("{f}", .{(try rt.callIfExists(granny, "OnSpawn", &.{})).?});
    try std.testing.expectEqualStrings("[true, false]", aw.written());
    try std.testing.expectEqual(Value{ .int = 2 }, (try rt.callIfExists(kid, "OnDeath", &.{.{ .string = "Sullivan" }})).?);
    try std.testing.expectEqualStrings("ag", S.order[0..S.len]);
    // The host as an object, the killer as given, a missing value nil.
    try std.testing.expectEqualStrings("kid/Sullivan/nil", granny.getString("got"));
    try std.testing.expectEqual(Value{ .int = 1 }, (try rt.callIfExists(granny, "stop", &.{})).?);
    try std.testing.expectEqual(Value{ .int = 1 }, (try rt.callIfExists(kid, "OnDeath", &.{.nil})).?);
    try std.testing.expectEqualStrings("aga", S.order[0..S.len]);
    // Detached (as a battle attaches its scripted ones anew): no longer called, dropped.
    aunt_host.components.clearRetainingCapacity();
    try std.testing.expectEqual(Value{ .int = 0 }, (try rt.callIfExists(kid, "OnDeath", &.{.nil})).?);
    try std.testing.expectEqual(0, rt.subs.items.len);
    // A handler that emits its own event: 8 Emits deep, the 9th faults (that handler only).
    const echo = try rt.attach(try rt.createObject("echo", cls), rt.ogs.components.get("Echo").?, &.{});
    _ = try rt.callIfExists(echo, "OnSpawn", &.{});
    _ = try rt.callIfExists(echo, "again", &.{});
    try std.testing.expectEqual(1 + Runtime.max_emit_depth, echo.getInt("n"));
    try std.testing.expectEqualStrings("events::Emit: EmitTooDeep", rt.fault.message);
    // The handler is checked at link time: a method of the calling component, in one.
    for ([_][2][]const u8{
        .{ "module g { use events; component G for fighter { fn OnSpawn() { Subscribe(\"e\", \"OnChildDie\"); } fn OnChildDied() { } } }", "Subscribe: G has no method OnChildDie" },
        .{ "fn f() { events::Subscribe(\"e\", \"f\"); }", "events::Subscribe: call it in a component's method" },
        .{ "trait T { fn h(); fn g() { events::Unsubscribe(\"e\", \"x\"); } }", "events::Unsubscribe: T has no method x" },
    }) |b| {
        try std.testing.expectError(error.LinkError, rt.loadOgs("bad.ogs", b[0]));
        try std.testing.expectEqualStrings(b[1], rt.diag.message);
    }
}

// ---------------------------------------------------------------- Classic → OG Script

/// The conversion tests' builtins: `Rec(x)` writes `x` down and answers it, `Yes(x)` is a
/// yes/no answer (x is not 0), `GetName`, `s_stricmp` and `EqualsIgnoreCase` as the game's.
const ConvLog = struct { text: std.Io.Writer.Allocating };

fn convRec(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const log: *ConvLog = @ptrCast(@alignCast(ctx));
    try log.text.writer.print("Rec({f}) ", .{if (args.len > 0) args[0] else Value.nil});
    return if (args.len > 0) args[0] else .zero;
}

fn convYes(_: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    return .{ .int = @intFromBool(args[0].toInt() != 0) };
}

fn convName(_: *anyopaque, _: *Runtime, self: *Object, _: []const Value) anyerror!Value {
    return .{ .string = self.name };
}

fn convStricmp(_: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    return .{ .int = switch (std.ascii.orderIgnoreCase(args[0].string, args[1].string)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    } };
}

fn convEq(_: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    return .{ .int = @intFromBool(std.ascii.eqlIgnoreCase(args[0].string, args[1].string)) };
}

fn convRuntime(sources: *TestSources, log: *ConvLog) !Runtime {
    var rt: Runtime = .init(std.testing.allocator, .{ .ctx = sources, .fetch = TestSources.fetch });
    rt.lift = false;
    try rt.registerBuiltinSig("Rec", log, convRec, .{ .text = "int(int)" });
    try rt.registerBuiltinSig("Yes", log, convYes, .{ .text = "bool(int)", .pure = true });
    try rt.registerBuiltinSig("GetName", log, convName, .{ .text = "string()", .pure = true, .classic = true });
    try rt.registerBuiltinSig("s_stricmp", log, convStricmp, .{ .text = "int(string, string)", .pure = true, .classic = true });
    try rt.registerBuiltinSig("EqualsIgnoreCase", log, convEq, .{ .text = "bool(string a, string b)", .pure = true });
    return rt;
}

/// Class `file` of `files` converted to a component for `kind`; each call of `runs` (a
/// Classic function and its arguments) run as Classic IR and as the translation, on new
/// objects of the class: the same result (nil allowed from an event nobody reads), object
/// variables and builtin calls. Asserts the translation has each of `has` and no
/// `classic::` but `classic_left`; returns nothing.
fn convertCheck(files: []const [2][]const u8, file: []const u8, kind: []const u8, runs: []const struct { []const u8, []const Value }, has: []const []const u8, classic_left: usize) !void {
    const t = std.testing;
    var sources: TestSources = .{ .files = files };
    var log_a: ConvLog = .{ .text = .init(t.allocator) };
    defer log_a.text.deinit();
    var log_b: ConvLog = .{ .text = .init(t.allocator) };
    defer log_b.text.deinit();
    var ra = try convRuntime(&sources, &log_a);
    defer ra.deinit();
    var rb = try convRuntime(&sources, &log_b);
    defer rb.deinit();
    const a = ra.arena();
    const ogsify = script.classic.ogsify;
    const ca = try ra.loadClass(file);
    var stats: ogsify.Stats = .{};
    const cls = try ogsify.classOf(a, &ra, ca, file, "T", kind, false);
    const text = try ogsify.text(a, "m", &.{try ogsify.component(a, &cls, ra.builtinNames(), &stats)});
    rb.loadOgs("t.ogs", text) catch |err| {
        std.debug.print("{s}\n{d}: {s}\n", .{ text, rb.diag.line, rb.diag.message });
        return err;
    };
    for (has) |x| if (std.mem.indexOf(u8, text, x) == null) {
        std.debug.print("no `{s}` in\n{s}\n", .{ x, text });
        return error.TestExpectedForm;
    };
    try t.expectEqual(classic_left, std.mem.count(u8, text, "classic::"));
    const comp = (try rb.ogs.component(a, null, "m::T")).?;
    const cb = try rb.loadClass(file);
    for (runs) |r| {
        const oa = try ra.createObject("t", ca);
        const ob = try rb.createObject("t", cb);
        const inst = try rb.attach(ob, comp, &.{});
        const i = for (cls.methods, 0..) |m, k| {
            if (std.ascii.eqlIgnoreCase(m.f.name, r[0])) break k;
        } else unreachable;
        log_a.text.clearRetainingCapacity();
        log_b.text.clearRetainingCapacity();
        const va = (try ra.callIfExists(oa, r[0], r[1])).?;
        const vb = (rb.callIfExists(inst, comp.methods[i].name, r[1]) catch |err| {
            std.debug.print("{s}\n{s}:{d}: {s}\n", .{ text, rb.fault.file, rb.fault.line, rb.fault.message });
            return err;
        }).?;
        if (!(vb == .nil and std.mem.startsWith(u8, comp.methods[i].name, "On")) and !script.ir.sameSkipping(Value, va, vb, &.{})) {
            std.debug.print("{s}: {f} / {f}\n{s}\n", .{ r[0], va, vb, text });
            return error.TestDiffers;
        }
        for (oa.vars.keys(), oa.vars.values()) |id, v| try t.expect(script.ir.sameSkipping(Value, v.value, ob.getVarId(id).?.value, &.{}));
        try t.expectEqualStrings(log_a.text.written(), log_b.text.written());
    }
}

test "convert: truth of an int, a float (truncated), a string (false), a yes/no answer" {
    try convertCheck(&.{.{
        "t.lev",
        \\int n; float f; string s;
        \\function check(int k) {
        \\  n = k; f = k * 0.5; s = "x";
        \\  if (n) Rec(1);
        \\  if (f) Rec(2);
        \\  if (s) Rec(3);
        \\  if (Yes(k)) Rec(4);
        \\  return(n);
        \\};
    }}, "t.lev", "level", &.{ .{ "check", &.{.{ .int = 0 }} }, .{ "check", &.{.{ .int = 1 }} }, .{ "check", &.{.{ .int = 3 }} } }, &.{ "if (n) {", "var int t = f;", "if (t) {", "if (false) {", "if (Yes(k)) {", "f = k * 0.5;" }, 0);
}

test "convert: == of ints, a yes/no answer == 1 / == 0, two strings, s_stricmp; a float stays classic::eq" {
    try convertCheck(&.{.{
        "t.lev",
        \\int n; float f; string s;
        \\function check(int k) {
        \\  n = k; f = k + 0.5;
        \\  if (n == 2) Rec(1);
        \\  if (Yes(k) == 1) Rec(2);
        \\  if (Yes(k) == 0) Rec(3);
        \\  if (s == "abc") Rec(4);
        \\  if (f == 2) Rec(5);
        \\  if (s_stricmp(s, "") == 0) Rec(6);
        \\};
    }}, "t.lev", "level", &.{ .{ "check", &.{.{ .int = 0 }} }, .{ "check", &.{.{ .int = 2 }} } }, &.{ "if (n == 2) {", "if (Yes(k)) {", "if (!Yes(k)) {", "if (true) {", "classic::eq(f, 2)", "if (EqualsIgnoreCase(s, \"\")) {" }, 1);
}

test "convert: arithmetic and comparisons over numbers; != adds, <= is >=; an order that matters stays classic" {
    try convertCheck(&.{.{
        "t.lev",
        \\int n; int m; float f;
        \\function check(int k) {
        \\  n = k; f = 1.5;
        \\  m = 2 + Rec(k);
        \\  f = f * k;
        \\  m = n != 3;
        \\  if (n <= 5) Rec(7);
        \\  if (f > n) Rec(8);
        \\  n = n + Rec(k);
        \\};
    }}, "t.lev", "level", &.{ .{ "check", &.{.{ .int = 1 }} }, .{ "check", &.{.{ .int = 6 }} } }, &.{ "m = 2 + Rec(k);", "f = f * k;", "m = n + 3;", "if (n >= 5) {", "if (f > n) {", "n = classic::add(n, Rec(k));" }, 1);
}

test "convert: && and || with effects: both sides into locals, right first, then and / or" {
    try convertCheck(&.{.{
        "t.lev",
        \\int n;
        \\function check(int k) {
        \\  if (Rec(k) && Rec(k + 1)) n = 1;
        \\  if (n || Yes(Rec(2))) n = n + 1;
        \\};
    }}, "t.lev", "level", &.{ .{ "check", &.{.{ .int = 0 }} }, .{ "check", &.{.{ .int = 1 }} }, .{ "check", &.{.{ .int = -1 }} } }, &.{ "var t = Rec(k + 1);", "var t_ = Rec(k);", "if (t_ and t) {", " or " }, 0);
}

test "convert: names: fields, this, an unknown one; an undeclared assignment dropped, its effects kept" {
    try convertCheck(&.{.{
        "t.lev",
        \\int n; string who;
        \\function check(int k) {
        \\  n = k;
        \\  undeclared = Rec(5);
        \\  missing = 3;
        \\  who = GetName();
        \\  Rec(this);
        \\  Rec(nowhere);
        \\};
    }}, "t.lev", "level", &.{.{ "check", &.{.{ .int = 4 }} }}, &.{ "n = k;", "    Rec(5);", "who = host.name;", "Rec(host.name);", "Rec(classic::name(\"nowhere\"));" }, 1);
}

test "convert: events renamed (calls too), own calls, a call of nothing, return 0 where the value is read; a function's value is of no known type" {
    try convertCheck(&.{.{
        "t.lev",
        \\int n;
        \\function init() { n = 1; helper(2); Nowhere(Rec(3)); };
        \\function helper(int x) { n = n + x; };
        \\function update() { n = helper(1) + 1; };
        \\function again() { init(); return(n); };
    }}, "t.lev", "level", &.{ .{ "init", &.{} }, .{ "helper", &.{.{ .int = 3 }} }, .{ "update", &.{} }, .{ "again", &.{} } }, &.{ "fn OnCreate() {\n            n = 1;\n            helper(2);\n            Rec(3);\n        }", "fn helper(x: int) {\n            n = n + x;\n            return 0;", "fn OnUpdate() {", "OnCreate();", "n = classic::add(helper(1), 1);" }, 1);
}

test "convert: the event's missing parameters appended (NodeResponse → OnNode(no, dir, walker))" {
    try convertCheck(&.{.{ "t.pth", "function NodeResponse(int no, int dir) { Rec(no + dir); };\nfunction again() { NodeResponse(3, 4); };" }}, "t.pth", "path", &.{ .{ "NodeResponse", &.{ .{ .int = 1 }, .{ .int = 2 } } }, .{ "again", &.{} } }, &.{ "fn OnNode(no: int, dir: int, walker = nil) {", "OnNode(3, 4);" }, 0);
}

test "convert: an inherited function inline (no parameters, locals or return), else on host" {
    try convertCheck(&.{
        .{ "base.s", "int n; function setup() { n = 5; Rec(n); }; function play(int k) { Rec(k); };" },
        .{ "t.lev", "#inherit Base\nfunction init() { setup(); play(2); };" },
    }, "t.lev", "level", &.{.{ "init", &.{} }}, &.{"fn OnCreate() {\n            n = 5;\n            Rec(n);\n            host.play(2);"}, 0);
}

test "convert: a yes/no answer where Classic's int is needed: classic::truthy (int 1/0)" {
    try convertCheck(&.{.{
        "t.lev",
        \\int n; string s;
        \\function check(int k) { n = Yes(k) + 1; s = Yes(k); return(Yes(k)); };
    }}, "t.lev", "level", &.{ .{ "check", &.{.{ .int = 0 }} }, .{ "check", &.{.{ .int = 5 }} } }, &.{ "n = classic::truthy(Yes(k)) + 1;", "s = classic::truthy(Yes(k));", "return classic::truthy(Yes(k));" }, 3);
}

test "convert: two Classic events of one OGS event: a method calling them in the exe's order" {
    try convertCheck(&.{.{ "t.act", "function postinit() { Rec(2); };\nfunction additionalIdleAnims() { Rec(1); };" }}, "t.act", "actor", &.{ .{ "postinit", &.{} }, .{ "additionalIdleAnims", &.{} } }, &.{"fn OnActorReady() {\n            additionalIdleAnims();\n            postinit();\n        }"}, 0);
}

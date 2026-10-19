//! Script interpreter: classes (`#inherit`), objects with variables, calls to
//! script functions and engine builtins. Walks the parse tree, no compilation.
//!
//! Variable and function names are case-insensitive (.wpn files write `Owner`
//! while the class declares `owner`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const value_mod = @import("value.zig");
const Value = value_mod.Value;

/// Script source provider by file name (`activebitmapanimation.s`,
/// `drzwi_barak_aba.aba`). Returned memory must live as long as the runtime.
const SourceProvider = struct {
    ctx: *anyopaque,
    fetch: *const fn (ctx: *anyopaque, name: []const u8) anyerror!?[]const u8,
};

const BuiltinFn = *const fn (ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value;

const Builtin = struct {
    ctx: *anyopaque,
    func: BuiltinFn,
};

const object = @import("object.zig");
const Class = object.Class;
const Var = object.Var;
const Object = object.Object;

const Error = error{ ScriptNotFound, IncludeCycle, StackOverflow } || parser.Error || Allocator.Error;

pub const Runtime = struct {
    gpa: Allocator,
    /// Classes, parse trees, sources, names: everything until the runtime is destroyed.
    arena_state: std.heap.ArenaAllocator,
    /// Strings created at run time.
    strings_state: std.heap.ArenaAllocator,
    source: SourceProvider,
    classes: std.StringHashMapUnmanaged(*Class) = .empty,
    units: std.StringHashMapUnmanaged(ast.Unit) = .empty,
    objects: std.ArrayList(*Object) = .empty,
    /// Lower-case object name → first object with that name (objects are only added,
    /// names never change), so `findObject` doesn't scan.
    by_name: std.StringHashMapUnmanaged(*Object) = .empty,
    builtins: std.AutoHashMapUnmanaged(u32, Builtin) = .empty,
    /// Builtins called but not implemented (name → call count).
    missing_builtins: std.StringArrayHashMapUnmanaged(u32) = .empty,
    /// Assignments to undeclared variables and reads of unknown names.
    unknown_names: std.StringArrayHashMapUnmanaged(u32) = .empty,
    depth: u32 = 0,
    /// `#include` nesting inside a function body (no deeper than 16, like addItems).
    include_depth: u32 = 0,
    /// Number of the current top-level script call (grows on every entry from depth
    /// 0), to tell "the same call" from the next one.
    top_call: u64 = 0,
    /// Last parse error (file and line).
    diag_file: []const u8 = "",
    diag: parser.Diagnostic = .{},

    /// shortcut: the exe has no call depth limit (recursion overflows the stack); we
    /// return StackOverflow. Game scripts don't recurse.
    const max_depth = 64;

    pub fn init(gpa: Allocator, source: SourceProvider) Runtime {
        return .{ .gpa = gpa, .arena_state = .init(gpa), .strings_state = .init(gpa), .source = source };
    }

    pub fn deinit(self: *Runtime) void {
        self.strings_state.deinit();
        self.arena_state.deinit();
        self.* = undefined;
    }

    pub fn arena(self: *Runtime) Allocator {
        return self.arena_state.allocator();
    }

    pub fn strings(self: *Runtime) Allocator {
        return self.strings_state.allocator();
    }

    fn lower(self: *Runtime, s: []const u8) Allocator.Error![]const u8 {
        return std.ascii.allocLowerString(self.arena(), s);
    }

    pub fn registerBuiltin(self: *Runtime, name: []const u8, ctx: *anyopaque, func: BuiltinFn) Allocator.Error!void {
        try self.builtins.put(self.arena(), try object.intern(name), .{ .ctx = ctx, .func = func });
    }

    // ---------------------------------------------------------------- loading

    fn loadUnit(self: *Runtime, file: []const u8) Error!ast.Unit {
        const key = try self.lower(file);
        if (self.units.get(key)) |u| return u;
        const src = (self.source.fetch(self.source.ctx, file) catch return error.ScriptNotFound) orelse return error.ScriptNotFound;
        const unit = parser.parse(self.arena(), src, &self.diag) catch |err| {
            self.diag_file = key;
            return err;
        };
        try self.units.put(self.arena(), key, unit);
        return unit;
    }

    /// Class from a script file. `#inherit X` → `x.s`.
    pub fn loadClass(self: *Runtime, file: []const u8) Error!*Class {
        const key = try self.lower(file);
        if (self.classes.get(key)) |c| return c;
        const cls = try self.arena().create(Class);
        cls.* = .{ .name = key, .parent = null, .loading = true };
        // Register first so cyclic inheritance doesn't recurse.
        try self.classes.put(self.arena(), key, cls);
        // Text not found: don't leave an empty class behind (a retry would return it).
        errdefer _ = self.classes.remove(key);
        try self.addItems(cls, try self.loadUnit(file), 0);
        cls.loading = false;
        return cls;
    }

    fn addItems(self: *Runtime, cls: *Class, unit: ast.Unit, depth: u32) Error!void {
        if (depth > 16) return error.IncludeCycle;
        for (unit.items) |*it| switch (it.*) {
            .inherit => |name| {
                const file = if (std.fs.path.extension(name).len > 0) name else try std.fmt.allocPrint(self.arena(), "{s}.s", .{name});
                const p = try self.loadClass(file);
                if (!p.loading) cls.parent = p;
                // #inherit is an insertion at this point too: ancestors' variables and functions
                // come before the class's later definitions (the parent has collected its own
                // #inherit already). Each of several #inherit lines inserts its own.
                try cls.vars.appendSlice(self.arena(), p.vars.items);
                var fit = p.functions.iterator();
                while (fit.next()) |e| {
                    const gop = try cls.functions.getOrPut(self.arena(), e.key_ptr.*);
                    if (!gop.found_existing) gop.value_ptr.* = e.value_ptr.*;
                }
            },
            // Top-level `#include` is a text insertion into the same class.
            .include => |name| try self.addItems(cls, try self.loadUnit(name), depth + 1),
            .var_decl => |d| try cls.vars.append(self.arena(), d),
            // The first definition wins (text insertion in the exe): Headnail gets post_init
            // from Headnail.s, not the empty one from .ftr.
            .function => |*f| {
                const gop = try cls.functions.getOrPut(self.arena(), try object.intern(f.name));
                if (!gop.found_existing) gop.value_ptr.* = f;
            },
            // Top-level statements only occur in `.ss` snippets included inside functions.
            .stmt => {},
        };
    }

    /// Creates an object with the class variables (inherited ones included) at their defaults.
    pub fn createObject(self: *Runtime, name: []const u8, cls: *Class) Allocator.Error!*Object {
        const obj = try self.arena().create(Object);
        obj.* = .{ .name = try self.arena().dupe(u8, name), .class = cls };
        try self.declareVars(obj, cls);
        try self.objects.append(self.arena(), obj);
        const gop = try self.by_name.getOrPut(self.arena(), try self.lower(name));
        if (!gop.found_existing) gop.value_ptr.* = obj;
        return obj;
    }

    /// Change an object's class (ACTOR_MORPH): new class variables are added, old
    /// values stay.
    pub fn morph(self: *Runtime, obj: *Object, cls: *Class) Allocator.Error!void {
        obj.class = cls;
        try self.declareVars(obj, cls);
    }

    fn declareVars(self: *Runtime, obj: *Object, cls: *Class) Allocator.Error!void {
        var buf: [128]u8 = undefined;
        for (cls.vars.items) |d| {
            const lname = if (d.name.len <= buf.len) std.ascii.lowerString(&buf, d.name) else try self.lower(d.name);
            try obj.declare(self.arena(), lname, .{ .type = d.type, .value = .initial(d.type) });
        }
    }

    pub fn findObject(self: *Runtime, name: []const u8) ?*Object {
        var buf: [256]u8 = undefined;
        if (name.len > buf.len) {
            for (self.objects.items) |o| if (std.ascii.eqlIgnoreCase(o.name, name)) return o;
            return null;
        }
        return self.by_name.get(std.ascii.lowerString(&buf, name));
    }

    /// Values from `.var` (0x431ee0): declared int and float only.
    pub fn applyVar(self: *Runtime, obj: *Object, name: []const u8, text: []const u8) void {
        _ = self;
        const v = obj.getVarDyn(name) orelse return;
        v.value = Value.parse(text, v.type) orelse return;
    }

    // ---------------------------------------------------------------- calls

    /// Calls a script function by name if it exists; null if there is none.
    pub fn callIfExists(self: *Runtime, obj: *Object, name: []const u8, args: []const Value) Error!?Value {
        var buf: [128]u8 = undefined;
        if (name.len > buf.len) return null;
        const f = obj.class.findFunction(std.ascii.lowerString(&buf, name)) orelse return null;
        return try self.callScript(obj, f, args);
    }

    /// Same for a comptime-known name (`update` of every object every tick): the id is
    /// looked up once per call site.
    pub fn callIfExistsC(self: *Runtime, obj: *Object, comptime name: []const u8, args: []const Value) Error!?Value {
        // The struct must capture `name`, or every call site would share one cache.
        const S = struct {
            const key = blk: {
                var buf: [name.len]u8 = undefined;
                for (name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
                const final = buf;
                break :blk &final;
            };
            var id: ?u32 = null;
        };
        const id = S.id orelse blk: {
            const found = object.findName(S.key) orelse return null;
            S.id = found;
            break :blk found;
        };
        const f = obj.class.findFunctionId(id) orelse return null;
        return try self.callScript(obj, f, args);
    }

    fn callScript(self: *Runtime, obj: *Object, f: *const ast.Function, args: []const Value) Error!Value {
        if (self.depth >= max_depth) return error.StackOverflow;
        if (self.depth == 0) self.top_call += 1;
        self.depth += 1;
        defer self.depth -= 1;

        var frame: Frame = .{ .obj = obj };
        frame.locals = .initBuffer(&frame.inline_buf);
        defer frame.deinit(self.gpa);
        for (f.params, 0..) |p, i| {
            const v = if (i < args.len) try args[i].convert(p.type, self.strings()) else Value.initial(p.type);
            try frame.push(self.gpa, .{ .id = p.id, .v = .{ .type = p.type, .value = v } });
        }
        for (f.body) |*st| {
            if (try self.exec(&frame, st) == .returned) break;
        }
        return frame.ret;
    }

    fn callNamed(self: *Runtime, frame: *Frame, call: ast.Expr.Call) Error!Value {
        // Arguments go into 0x108 bytes of stack at 0x4e3b80, 8 bytes each plus a zero
        // terminator: up to 32. shortcut: beyond 32 the exe corrupts its stack; we return 0 unevaluated.
        var args_buf: [32]Value = undefined;
        if (call.args.len > args_buf.len) return .zero;
        for (call.args, 0..) |a, i| args_buf[i] = try self.eval(frame, a);
        const args = args_buf[0..call.args.len];

        // shortcut: names longer than 128 give 0 (the exe has no limit; game names are under 40).
        if (call.name.len > 128) return .zero;
        if (frame.obj.class.findFunctionId(call.id)) |f| return self.callScript(frame.obj, f, args);
        if (self.builtins.get(call.id)) |b| {
            return b.func(b.ctx, self, frame.obj, args) catch |err| {
                std.log.warn("builtin {s}: {t}", .{ call.name, err });
                return .zero;
            };
        }
        try self.count(&self.missing_builtins, call.name);
        return .zero;
    }

    fn count(self: *Runtime, map: *std.StringArrayHashMapUnmanaged(u32), name: []const u8) Allocator.Error!void {
        const gop = try map.getOrPut(self.arena(), name);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    // ---------------------------------------------------------------- execution

    const Local = struct { id: u32, v: Var };

    const Frame = struct {
        obj: *Object,
        locals: std.ArrayList(Local) = .empty,
        ret: Value = .zero,
        /// The first locals live in the frame itself without allocation; more go to the
        /// heap (`on_heap`).
        inline_buf: [16]Local = undefined,
        on_heap: bool = false,

        fn push(self: *Frame, gpa: Allocator, l: Local) Allocator.Error!void {
            if (self.locals.items.len == self.locals.capacity) {
                if (self.on_heap) {
                    try self.locals.ensureUnusedCapacity(gpa, 1);
                } else {
                    var heap: std.ArrayList(Local) = try .initCapacity(gpa, self.locals.capacity * 2 + 8);
                    heap.appendSliceAssumeCapacity(self.locals.items);
                    self.locals = heap;
                    self.on_heap = true;
                }
            }
            self.locals.appendAssumeCapacity(l);
        }

        fn deinit(self: *Frame, gpa: Allocator) void {
            if (self.on_heap) self.locals.deinit(gpa);
        }

        fn local(self: *Frame, id: u32) ?*Var {
            var i = self.locals.items.len;
            while (i > 0) {
                i -= 1;
                if (self.locals.items[i].id == id) return &self.locals.items[i].v;
            }
            return null;
        }
    };

    const Flow = enum { normal, returned };

    fn exec(self: *Runtime, frame: *Frame, st: *const ast.Stmt) Error!Flow {
        switch (st.*) {
            .empty => {},
            .expr => |e| _ = try self.eval(frame, e),
            .var_decl => |d| try frame.push(self.gpa, .{ .id = d.id orelse try object.intern(d.name), .v = .{ .type = d.type, .value = .initial(d.type) } }),
            .block => |stmts| for (stmts) |*s| {
                if (try self.exec(frame, s) == .returned) return .returned;
            },
            .@"if" => |i| {
                const branch = if ((try self.eval(frame, i.cond)).truthy()) i.then else i.@"else";
                if (branch) |b| return self.exec(frame, b);
            },
            .@"return" => |v| {
                // `return;` without a value gives type 0 in the exe and doesn't return (0x4e3eaa).
                const e = v orelse return .normal;
                frame.ret = try self.eval(frame, e);
                return .returned;
            },
            .include => |name| {
                if (self.include_depth > 16) return error.IncludeCycle;
                self.include_depth += 1;
                defer self.include_depth -= 1;
                const unit = try self.loadUnit(name);
                for (unit.items) |*it| switch (it.*) {
                    .stmt => |*s| if (try self.exec(frame, s) == .returned) return .returned,
                    .include => |inner| {
                        const inc: ast.Stmt = .{ .include = inner };
                        if (try self.exec(frame, &inc) == .returned) return .returned;
                    },
                    .var_decl => |d| try frame.push(self.gpa, .{ .id = d.id orelse try object.intern(d.name), .v = .{ .type = d.type, .value = .initial(d.type) } }),
                    .function, .inherit => {},
                };
            },
        }
        return .normal;
    }

    fn eval(self: *Runtime, frame: *Frame, e: *const ast.Expr) Error!Value {
        return switch (e.kind) {
            .int => |v| .{ .int = v },
            .float => |v| .{ .float = v },
            .string => |s| .{ .string = s },
            .ident => |ident| blk: {
                const name = ident.name;
                if (frame.local(ident.id)) |v| break :blk v.value;
                if (frame.obj.getVarId(ident.id)) |v| break :blk v.value;
                if (std.ascii.eqlIgnoreCase(name, "this")) break :blk .{ .string = frame.obj.name };
                // A scenario object's name refers to it (0x44b130).
                if (self.findObject(name)) |o| break :blk .{ .string = o.name };
                try self.count(&self.unknown_names, name);
                break :blk .zero;
            },
            .call => |c| try self.callNamed(frame, c),
            .unary => |u| blk: {
                const v = try self.eval(frame, u.operand);
                break :blk switch (u.op) {
                    .neg => switch (v) {
                        .float => |f| .{ .float = -f },
                        else => .{ .int = -%v.toInt() },
                    },
                    .not => .{ .int = @intFromBool(!v.truthy()) },
                };
            },
            .binary => |b| blk: {
                // As in the exe (0x4e3620): right operand first, then left, no short-circuit.
                const rhs = try self.eval(frame, b.rhs);
                const lhs = try self.eval(frame, b.lhs);
                break :blk value_mod.binary(b.op, lhs, rhs);
            },
            .assign => |a| blk: {
                const v = try self.eval(frame, a.value);
                const target = frame.local(a.id) orelse frame.obj.getVarId(a.id) orelse {
                    // Undeclared variable (0x44ae80): "Cannot find variable", the assignment is skipped.
                    try self.count(&self.unknown_names, a.name);
                    break :blk v;
                };
                target.value = try v.convert(target.type, self.strings());
                break :blk target.value;
            },
        };
    }
};

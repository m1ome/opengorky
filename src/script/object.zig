//! Script objects and classes: object variables (case-insensitive names) and
//! class functions with inheritance (`#inherit`). The interpreter is `runtime.zig`.

const std = @import("std");
const ast = @import("ast.zig");
const Value = @import("value.zig").Value;

pub const Class = struct {
    /// Class file name, lower case.
    name: []const u8,
    /// Last `#inherit` (for `isA`); never set to a class that is still loading
    /// (mutual inheritance), so the chain has no cycles.
    parent: ?*Class,
    /// Class is still being built (`Runtime.loadClass`).
    loading: bool = false,
    /// Own variables and inserted `#inherit` ones, in text order.
    vars: std.ArrayList(ast.VarDecl) = .empty,
    /// Key is the interned function name (`intern`); the first definition wins
    /// (`#inherit`/`#include` insertions come before later ones).
    functions: std.AutoHashMapUnmanaged(u32, *const ast.Function) = .empty,

    pub fn findFunction(self: *const Class, lower_name: []const u8) ?*const ast.Function {
        return self.findFunctionId(findName(lower_name) orelse return null);
    }

    /// Lookup by interned name id, up the ancestor chain.
    pub fn findFunctionId(self: *const Class, id: u32) ?*const ast.Function {
        var c: ?*const Class = self;
        while (c) |cls| : (c = cls.parent) {
            if (cls.functions.get(id)) |f| return f;
        }
        return null;
    }

    /// Whether the class inherits (directly or via ancestors) from `lower_name`.
    pub fn isA(self: *const Class, lower_name: []const u8) bool {
        var c: ?*const Class = self;
        while (c) |cls| : (c = cls.parent) {
            if (std.mem.eql(u8, std.fs.path.stem(cls.name), lower_name)) return true;
        }
        return false;
    }
};

pub const Var = struct {
    type: ast.Type,
    value: Value,
};

/// Process-wide table of lower-case variable names: each name gets a small id once, so
/// object lookups compare integers instead of hashing strings (~13% of a playthrough).
/// Only the script thread touches it.
const names = struct {
    var ids: std.StringHashMapUnmanaged(u32) = .empty;
    var list: std.ArrayList([]const u8) = .empty;
    const gpa = std.heap.smp_allocator;
};

/// Id of a lower-case name, adding it to the table.
fn internName(lower: []const u8) std.mem.Allocator.Error!u32 {
    if (names.ids.get(lower)) |id| return id;
    const copy = try names.gpa.dupe(u8, lower);
    errdefer names.gpa.free(copy);
    const id: u32 = @intCast(names.list.items.len);
    try names.list.append(names.gpa, copy);
    errdefer _ = names.list.pop();
    try names.ids.put(names.gpa, copy, id);
    return id;
}

/// Id of a name in any case, adding it to the table (the parser resolves identifiers once).
pub fn intern(name: []const u8) std.mem.Allocator.Error!u32 {
    var buf: [128]u8 = undefined;
    if (name.len <= buf.len) return internName(std.ascii.lowerString(&buf, name));
    const lower = try names.gpa.alloc(u8, name.len);
    defer names.gpa.free(lower);
    return internName(std.ascii.lowerString(lower, name));
}

/// Id of a lower-case name, or null if no object ever declared it.
pub fn findName(lower: []const u8) ?u32 {
    return names.ids.get(lower);
}

/// Lower-case name of an id.
pub fn nameOf(id: u32) []const u8 {
    return names.list.items[id];
}

pub const Object = struct {
    name: []const u8,
    class: *Class,
    /// Key is the interned id of the lower-case variable name (`nameOf`).
    vars: std.AutoArrayHashMapUnmanaged(u32, Var) = .empty,
    enabled: bool = true,
    /// Engine data attached to the object.
    host: ?*anyopaque = null,

    /// Variable by a comptime-known name (almost every engine access): the id is looked
    /// up once per call site and cached.
    pub fn getVar(self: *Object, comptime name: []const u8) ?*Var {
        // The struct must capture `name`, or every call site would share one cache.
        const S = struct {
            const key = lowerConst(name);
            var id: ?u32 = null;
            /// Slot of the last hit: objects of one class share the variable order, so the
            /// next object usually has the name at the same slot.
            var slot: usize = 0;
        };
        const id = S.id orelse blk: {
            // Not cached until some object declares the name.
            const found = findName(S.key) orelse return null;
            S.id = found;
            break :blk found;
        };
        const keys = self.vars.keys();
        if (S.slot < keys.len and keys[S.slot] == id) return &self.vars.values()[S.slot];
        const i = self.vars.getIndex(id) orelse return null;
        S.slot = i;
        return &self.vars.values()[i];
    }

    /// Variable by an interned id (script identifiers resolved at parse time).
    pub fn getVarId(self: *Object, id: u32) ?*Var {
        return self.vars.getPtr(id);
    }

    /// Variable by a runtime name.
    pub fn getVarDyn(self: *Object, name: []const u8) ?*Var {
        var buf: [128]u8 = undefined;
        if (name.len > buf.len) return null;
        return self.vars.getPtr(findName(std.ascii.lowerString(&buf, name)) orelse return null);
    }

    /// Declare a variable by its lower-case name unless the object has it.
    pub fn declare(self: *Object, gpa: std.mem.Allocator, lower: []const u8, v: Var) std.mem.Allocator.Error!void {
        const gop = try self.vars.getOrPut(gpa, try internName(lower));
        if (!gop.found_existing) gop.value_ptr.* = v;
    }

    pub fn getInt(self: *Object, comptime name: []const u8) i32 {
        const v = self.getVar(name) orelse return 0;
        return v.value.toInt();
    }

    pub fn getIntDyn(self: *Object, name: []const u8) i32 {
        const v = self.getVarDyn(name) orelse return 0;
        return v.value.toInt();
    }

    pub fn getString(self: *Object, comptime name: []const u8) []const u8 {
        const v = self.getVar(name) orelse return "";
        return switch (v.value) {
            .string => |s| s,
            else => "",
        };
    }

    pub fn getStringDyn(self: *Object, name: []const u8) []const u8 {
        const v = self.getVarDyn(name) orelse return "";
        return switch (v.value) {
            .string => |s| s,
            else => "",
        };
    }

    /// Write converting to the variable's type. Strings must live in the runtime arena.
    pub fn setInt(self: *Object, comptime name: []const u8, v: i32) void {
        const p = self.getVar(name) orelse return;
        p.value = switch (p.type) {
            .int => .{ .int = v },
            .float => .{ .float = @floatFromInt(v) },
            else => p.value,
        };
    }

    pub fn hasFunction(self: *Object, name: []const u8) bool {
        var buf: [128]u8 = undefined;
        if (name.len > buf.len) return false;
        return self.class.findFunction(std.ascii.lowerString(&buf, name)) != null;
    }
};

fn lowerConst(comptime name: []const u8) []const u8 {
    comptime {
        var buf: [name.len]u8 = undefined;
        for (name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
        const final = buf;
        return &final;
    }
}

test "interned variable names: case-insensitive, unknown name misses" {
    const gpa = std.testing.allocator;
    var o: Object = .{ .name = "o", .class = undefined };
    defer o.vars.deinit(gpa);
    try o.declare(gpa, "speed", .{ .type = .int, .value = .{ .int = 7 } });
    try o.declare(gpa, "speed", .{ .type = .int, .value = .{ .int = 9 } });
    try std.testing.expectEqual(7, o.getInt("Speed"));
    try std.testing.expectEqual(7, o.getIntDyn("SPEED"));
    try std.testing.expectEqualStrings("speed", nameOf(o.vars.keys()[0]));
    try std.testing.expect(o.getVarDyn("never_declared_name_xyz") == null);
}

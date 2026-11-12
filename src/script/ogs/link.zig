//! OGS program: every loaded text's functions, components and
//! data blocks by namespace path (`a::b::f`), never by file. All texts are added first,
//! then the whole program links, so the order of the texts does not matter. `link`
//! resolves each call of the code: a qualified `a::b::f` names that function; a plain
//! `f` is, in order, a method of the caller's component, a function of its namespace, of
//! a namespace it `use`s (two that have it: an error), of the root namespace, a root
//! builtin (exact case). Builtins live in reserved packages (`fighter::SetHp`, `packages`;
//! `use fighter;` like a namespace); the root has the core (`print`). Named arguments and the required parameters are checked against the
//! function, a sigil (`~l"01_port"`) against the builtin's parameter and the names the
//! program and the host know. Data blocks are checked against the schema the host gives
//! (`core/schema.zig blockField`): the block's kind, its fields, their values' types,
//! enum words and references. Errors carry the file and line. Rules rows are data and are
//! not linked. Traits: a component's method table is built once, statically
//! (`Table`: its own methods, else the most specific default body); a default body is
//! linked once, in its trait, its calls of the trait's methods virtual (`ir.Callee.virtual`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../ir.zig");
const parser = @import("parser.zig");
const traits = @import("../traits.zig");
const object = @import("../object.zig");

pub const Error = Allocator.Error || error{LinkError};

/// Where a link error is and why.
pub const Diagnostic = struct {
    file: []const u8 = "",
    line: u32 = 0,
    message: []const u8 = "",
    /// A warning's parts, for a host's own words (the editor's notes): the method, its host
    /// kind and the event it is close to.
    parts: [3][]const u8 = .{ "", "", "" },
};

/// The builtins' packages (docs/og-script.md §16): no module of the program may take one's
/// name, nor `classic` (the Classic forms, docs/og-script.md §20.1).
pub const packages = [_][]const u8{ "object", "sound", "actor", "path", "level", "hero", "scene", "gui", "item", "battle", "fighter", "events" };

fn reserved(first: []const u8) bool {
    if (std.mem.eql(u8, first, "classic") or std.mem.eql(u8, first, foundation)) return true;
    return isPackage(first);
}

/// The engine's namespace (its prelude, engine.ogs): code names its traits, structs and
/// enums `foundation::Side` (or bare after `use foundation;`); data short (`place = hand`,
/// `Place(…)`: the schema's or the field's type says whose).
pub const foundation = "foundation";

fn isPackage(ns: []const u8) bool {
    for (packages) |p| if (std.mem.eql(u8, p, ns)) return true;
    return false;
}

/// What the host knows of builtins: builtin `name` (its OGS path, exact case), if any; whether the game
/// has a `kind` named `name` (a level, a sound…: what no block of the program declares;
/// null, or a null answer: the host can't tell, the name is not checked).
pub const Env = struct {
    ctx: *anyopaque,
    builtin: *const fn (ctx: *anyopaque, name: []const u8) ?Builtin,
    exists: ?*const fn (ctx: *anyopaque, kind: ir.Sigil, name: []const u8) ?bool = null,
    /// Field `name` of data blocks of kind `kind` (`core/schema.zig blockField`); null:
    /// kinds and fields are not checked.
    schema: ?*const fn (kind: []const u8, name: []const u8) Lookup = null,
    /// The engine's native components (core/natives.zig): `x.get(Guard)` names one.
    natives: []const object.Native = &.{},
};

/// A data block's field as the schema has it: its type, the type of the prelude it takes
/// (`list<Place>`, `ItemPlace`: an int field's enum, its values' numbers), the kind of
/// block it names (`explodeWeapon`: a weapon).
/// `rows`: the block's rules rows (`ai = AiProfile(…)`: the rules loader reads them; their
/// sigils only are checked here).
pub const Field = struct { name: []const u8, type: ir.Type, type_name: []const u8 = "", ref: ir.Sigil = .none, check: ?Check = null, rows: bool = false };

/// The shape of a structured data value (a list, a record: `tile = [2, 9]`): null if
/// right, else what is wrong (the field's name goes before it).
pub const Check = *const fn (v: *const ir.Expr) ?[]const u8;

/// What the schema says of a field of a block kind (`no_schema`: a kind whose fields
/// are not checked yet).
pub const Lookup = union(enum) { unknown_kind, no_schema, no_field, field: Field };

/// A builtin's id and signature (`int(string target, ?int turns)`: named parameters).
/// `moved`: `name` is the builtin's Classic one; OGS calls it `moved` ("": OGS has none).
pub const Builtin = struct { id: u32, sig: []const u8 = "", moved: ?[]const u8 = null };

/// Position of parameter `name` in signature `sig`, if the signature names it.
fn sigParam(sig: []const u8, name: []const u8) ?usize {
    const open = std.mem.indexOfScalar(u8, sig, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, sig, ')') orelse return null;
    var it = std.mem.splitScalar(u8, sig[open + 1 .. close], ',');
    var i: usize = 0;
    while (it.next()) |p| : (i += 1) {
        const t = std.mem.trim(u8, p, " ");
        const sp = std.mem.lastIndexOfScalar(u8, t, ' ') orelse continue;
        if (std.mem.eql(u8, t[sp + 1 ..], name)) return i;
    }
    return null;
}

/// Type word of parameter `i` in signature `sig` (`level` of `int(level, ?int)`), if any.
/// A last parameter named `x...` takes every argument from its place on (`Emit`).
pub fn sigType(sig: []const u8, i: usize) []const u8 {
    const open = std.mem.indexOfScalar(u8, sig, '(') orelse return "";
    const close = std.mem.lastIndexOfScalar(u8, sig, ')') orelse return "";
    var it = std.mem.splitScalar(u8, sig[open + 1 .. close], ',');
    var k: usize = 0;
    var t: []const u8 = "";
    while (it.next()) |p| : (k += 1) {
        t = std.mem.trim(u8, p, " ?");
        if (k == i) break;
    } else if (!std.mem.endsWith(u8, t, "...")) return "";
    return t[0 .. std.mem.indexOfScalar(u8, t, ' ') orelse t.len];
}

pub const Program = struct {
    /// The texts added, in order (`add`); one that fails to link is dropped (`link`).
    texts: std.ArrayList(parser.Unit) = .empty,
    /// Of every text, in order (rebuilt when a text is dropped).
    modules: std.ArrayList(ir.Module) = .empty,
    fns: std.StringHashMapUnmanaged(*const ir.Fn) = .empty,
    components: std.StringHashMapUnmanaged(*const ir.Component) = .empty,
    traits: std.StringHashMapUnmanaged(*const ir.Trait) = .empty,
    /// Structs and enums by path, the prelude's (engine.ogs: `Place`, `Side`) in the root.
    types: std.StringHashMapUnmanaged(TypeDecl) = .empty,
    /// Each linked component's method table.
    tables: std.AutoHashMapUnmanaged(*const ir.Component, Table) = .empty,
    /// Warnings of the texts linked (a method named close to an event).
    warnings: std.ArrayList(Diagnostic) = .empty,
    /// Of them, the texts' linked so far (`linked`): a link that fails gives its texts'
    /// warnings again when it is retried, so they are dropped first.
    linked_warnings: usize = 0,
    namespaces: std.StringHashMapUnmanaged(void) = .empty,
    /// The top-level data blocks by `kind path` (`level 01_port`, `fighter characters::grandma`).
    blocks: std.StringHashMapUnmanaged(*const ir.Entity) = .empty,
    /// Their paths, of any kind.
    block_paths: std.StringHashMapUnmanaged(void) = .empty,
    /// Texts linked so far: a later link links the rest (the editor's check sets it to
    /// skip the texts it does not check).
    linked: usize = 0,

    /// A parsed text added (not linked yet); a name defined twice is an error and the
    /// text is not added.
    pub fn add(self: *Program, a: Allocator, u: parser.Unit, diag: *Diagnostic) Error!void {
        // The engine's traits come first (`traits.prelude`); their names stay the engine's
        // (`traits.find`), so the text is neither indexed nor linked.
        if (self.texts.items.len == 0) {
            var pd: parser.Diagnostic = .{};
            const pre = parser.parse(a, traits.prelude, prelude_file, &pd) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return fail(a, diag, prelude_file, pd.line, "{s}", .{pd.message}),
            };
            try self.texts.append(a, pre);
            try self.indexText(a, pre, diag);
        }
        try self.texts.append(a, u);
        // Only the new text's names: re-indexing them all made adding n texts quadratic.
        self.indexText(a, u, diag) catch |err| {
            _ = self.texts.pop();
            var ignored: Diagnostic = .{};
            self.index(a, &ignored) catch {};
            return err;
        };
    }

    /// The maps of names rebuilt from `texts`.
    fn index(self: *Program, a: Allocator, diag: *Diagnostic) Error!void {
        self.modules.clearRetainingCapacity();
        self.fns.clearRetainingCapacity();
        self.components.clearRetainingCapacity();
        self.traits.clearRetainingCapacity();
        self.types.clearRetainingCapacity();
        self.namespaces.clearRetainingCapacity();
        self.blocks.clearRetainingCapacity();
        self.block_paths.clearRetainingCapacity();
        // The prelude first (it is the first text), as `add` indexes them.
        for (self.texts.items) |u| if (isPrelude(u)) try self.indexText(a, u, diag);
        for (self.texts.items) |u| if (!isPrelude(u)) try self.indexText(a, u, diag);
    }

    /// Text `u`'s names into the maps (the texts before it indexed already).
    fn indexText(self: *Program, a: Allocator, u: parser.Unit, diag: *Diagnostic) Error!void {
        // The engine's types, in `foundation` (its traits stay `traits.find`'s).
        try self.namespaces.put(a, foundation, {});
        if (isPrelude(u)) {
            for (u.modules) |m| {
                var fm = m;
                fm.path = foundation;
                try self.indexTypes(a, u, fm, diag);
            }
            return;
        }
        for (u.modules) |m| {
            try self.namespaces.put(a, m.path, {});
            // Each prefix of `a::b::c` is a namespace too.
            var it = std.mem.splitSequence(u8, m.path, "::");
            var end: usize = 0;
            while (it.next()) |part| {
                if (end == 0 and reserved(part)) return fail(a, diag, u.file, 0, "{s}: reserved package", .{part});
                end += part.len;
                try self.namespaces.put(a, m.path[0..end], {});
                end += 2;
            }
            for (m.fns) |f| try put(a, &self.fns, "", try key(a, m.path, f.name), f, f.file, f.line, diag);
            for (m.components) |c| try put(a, &self.components, "", try key(a, m.path, c.name), c, u.file, c.line, diag);
            for (m.traits) |t| try put(a, &self.traits, "trait ", try key(a, m.path, t.name), t, u.file, t.line, diag);
            try self.indexTypes(a, u, m, diag);
            for (m.entities) |*e| {
                const path = try key(a, m.path, e.name);
                try put(a, &self.blocks, "", try std.fmt.allocPrint(a, "{s} {s}", .{ e.kind, path }), e, u.file, e.line, diag);
                try self.block_paths.put(a, path, {});
            }
            try self.modules.append(a, m);
        }
        // `Shielded::absorb` names a trait's body or a module's function: not both.
        var it = self.traits.iterator();
        while (it.next()) |e| if (self.namespaces.contains(e.key_ptr.*)) return fail(a, diag, e.value_ptr.*.file, e.value_ptr.*.line, "{s} is both a trait and a module", .{e.key_ptr.*});
    }

    fn indexTypes(self: *Program, a: Allocator, u: parser.Unit, m: ir.Module, diag: *Diagnostic) Error!void {
        for (m.structs) |x| {
            if (x.host) return fail(a, diag, u.file, x.line, "host {s}: a data block kind's fields are the engine's (foundation/hosts.ogs)", .{x.name});
            try put(a, &self.types, "", try key(a, m.path, x.name), TypeDecl{ .@"struct" = x }, u.file, x.line, diag);
        }
        for (m.enums) |x| {
            try put(a, &self.types, "", try key(a, m.path, x.name), TypeDecl{ .@"enum" = x }, u.file, x.line, diag);
        }
    }

    /// Struct or enum `path` as code in module `m` names it (`Wave`, `lib::Wave`): the
    /// module's, a used namespace's, the root's; the engine's are `foundation::Side`.
    fn typeNamed(self: *const Program, a: Allocator, m: ?*const ir.Module, path: []const u8) Allocator.Error!?TypeDecl {
        if (std.mem.indexOf(u8, path, "::") != null) return self.types.get(path);
        if (m) |mod| {
            if (mod.path.len > 0) if (self.types.get(try key(a, mod.path, path))) |t| return t;
            for (mod.uses) |u| if (self.types.get(try key(a, u, path))) |t| return t;
        }
        return self.types.get(path);
    }

    /// As `typeNamed`, in data (`data_`): a bare name no code declares is the engine's
    /// (`Place(…)`, `Camera(…)` of a block's field).
    fn typeIn(self: *const Program, a: Allocator, m: ?*const ir.Module, path: []const u8, data_: bool) Allocator.Error!?TypeDecl {
        if (try self.typeNamed(a, m, path)) |t| return t;
        if (!data_ or std.mem.indexOf(u8, path, "::") != null) return null;
        return self.types.get(try key(a, foundation, path));
    }

    fn enumIn(self: *const Program, a: Allocator, m: ?*const ir.Module, path: []const u8, data_: bool) Allocator.Error!?*const ir.Enum {
        const t = try self.typeIn(a, m, path, data_) orelse return null;
        return if (t == .@"enum") t.@"enum" else null;
    }

    /// The enum `path` names, if it is one.
    pub fn enumNamed(self: *const Program, a: Allocator, m: ?*const ir.Module, path: []const u8) Allocator.Error!?*const ir.Enum {
        const t = try self.typeNamed(a, m, path) orelse return null;
        return if (t == .@"enum") t.@"enum" else null;
    }

    /// Component `c`'s fields: the params of its traits it does not declare itself (the
    /// most general trait's first), then its own (`Table.fields`; not linked: its own).
    pub fn fieldsOf(self: *const Program, c: *const ir.Component) []const ir.Field {
        return if (self.tables.get(c)) |t| t.fields else c.fields;
    }

    /// The default body of engine method `trait.name` in the prelude (`Level.Placement`:
    /// `return host.placement;`); null: none (`{ }`, the engine's own answer).
    fn engineBody(self: *const Program, trait_name: []const u8, name: []const u8) ?*const ir.Fn {
        const u = if (self.texts.items.len > 0 and isPrelude(self.texts.items[0])) self.texts.items[0] else return null;
        for (u.modules) |m| for (m.traits) |t| if (std.mem.eql(u8, t.name, trait_name)) for (t.methods) |x| {
            if (std.mem.eql(u8, x.f.name, name) and x.f.body.len > 0) return x.f;
        };
        return null;
    }

    fn put(a: Allocator, map: anytype, what: []const u8, k: []const u8, v: anytype, file: []const u8, line: u32, diag: *Diagnostic) Error!void {
        const gop = try map.getOrPut(a, k);
        if (gop.found_existing) return fail(a, diag, file, line, "{s}{s} is defined twice", .{ what, k });
        gop.value_ptr.* = v;
    }

    /// Links every text added since the last link against the whole program. A text that
    /// fails is dropped from the program (its names, its components: none attaches) and
    /// its error returned; linking again links the others without it.
    pub fn link(self: *Program, a: Allocator, env: Env, diag: *Diagnostic) Error!void {
        self.warnings.shrinkRetainingCapacity(self.linked_warnings);
        for (self.texts.items[self.linked..], self.linked..) |u, i| {
            self.linkText(a, env, diag, u) catch |err| {
                _ = self.texts.orderedRemove(i);
                var ignored: Diagnostic = .{};
                try self.index(a, &ignored);
                return err;
            };
        }
        self.linked = self.texts.items.len;
        self.linked_warnings = self.warnings.items.len;
    }

    fn linkText(self: *Program, a: Allocator, env: Env, diag: *Diagnostic, u: parser.Unit) Error!void {
        if (isPrelude(u)) return;
        for (u.modules) |*m| {
            var l: Linker = .{ .p = self, .a = a, .env = env, .diag = diag, .m = m, .file = u.file };
            for (m.uses) |n| if (!self.namespaces.contains(n) and !isPackage(n)) return fail(a, diag, u.file, 0, "use {s}: no such namespace", .{n});
            for (m.fns) |f| try l.function(f);
            for (m.traits) |t| try l.trait(t);
            for (m.structs) |x| {
                l.file = x.file;
                try l.fieldList(x.fields, x.name);
            }
            for (m.components) |c| {
                l.file = u.file;
                try l.table(c);
                l.comp = c;
                try l.fieldList(c.fields, c.name);
                for (c.methods) |f| try l.function(f);
                l.comp = null;
                l.ctx = .{};
            }
            l.file = u.file;
            for (m.entities) |e| try l.block(e);
            for (m.rows) |r| try l.sigils(r);
        }
    }

    /// Whether block `path` (as data names it from module `m`) of one of `of` kinds (all:
    /// empty) is in the program.
    fn hasBlock(self: *const Program, a: Allocator, m: *const ir.Module, path: []const u8, of: []const []const u8) Allocator.Error!bool {
        const full = if (m.path.len > 0) try key(a, m.path, path) else path;
        if (of.len == 0) return self.block_paths.contains(path) or self.block_paths.contains(full);
        for (of) |k| {
            if (self.blocks.contains(try std.fmt.allocPrint(a, "{s} {s}", .{ k, path }))) return true;
            if (self.blocks.contains(try std.fmt.allocPrint(a, "{s} {s}", .{ k, full }))) return true;
        }
        return false;
    }

    /// Component `path` as code in module `m` names it (`Rage`, `abilities::Rage`):
    /// the module's, a used namespace's, the root's.
    /// A block's own component `c` (ir.Entity.own) as the program has it; null: dropped
    /// (it did not link).
    pub fn ownComponent(self: *const Program, c: *const ir.Component) ?*const ir.Component {
        var buf: [512]u8 = undefined;
        const k = if (c.module.len == 0) c.name else std.fmt.bufPrint(&buf, "{s}::{s}", .{ c.module, c.name }) catch return null;
        return self.components.get(k);
    }

    pub fn component(self: *const Program, a: Allocator, m: ?*const ir.Module, path: []const u8) Allocator.Error!?*const ir.Component {
        if (std.mem.indexOf(u8, path, "::") != null) return self.components.get(path);
        if (m) |mod| {
            if (self.components.get(try key(a, mod.path, path))) |c| return c;
            for (mod.uses) |u| if (self.components.get(try key(a, u, path))) |c| return c;
        }
        return self.components.get(path);
    }
};

/// A struct or an enum declared (`Program.types`).
const TypeDecl = union(enum) { @"struct": *const ir.Struct, @"enum": *const ir.Enum };

/// The engine's prelude's file: the one text `native fn` is written in.
const prelude_file = "engine.ogs";

fn isPrelude(u: parser.Unit) bool {
    return std.mem.eql(u8, u.file, prelude_file);
}

fn key(a: Allocator, ns: []const u8, n: []const u8) Allocator.Error![]const u8 {
    return if (ns.len == 0) n else std.fmt.allocPrint(a, "{s}::{s}", .{ ns, n });
}

fn fail(a: Allocator, diag: *Diagnostic, file: []const u8, line: u32, comptime fmt: []const u8, args: anytype) Error {
    diag.* = .{ .file = file, .line = line, .message = try std.fmt.allocPrint(a, fmt, args) };
    return error.LinkError;
}

const Linker = struct {
    p: *Program,
    a: Allocator,
    env: Env,
    diag: *Diagnostic,
    m: *const ir.Module,
    comp: ?*const ir.Component = null,
    file: []const u8 = "",
    /// The trait or component being linked.
    ctx: Ctx = .{},
    /// The function being linked (`super` names its method).
    cur: ?*const ir.Fn = null,

    const Ctx = struct {
        /// Its traits, supertraits included (`ir.Callee.virtual`, `super`, events).
        closure: []const ir.TraitRef = &.{},
        /// Its host kind (`fighter`; "" none): `host`'s static type.
        kind: []const u8 = "",
        /// A component's method table.
        methods: []const Resolved = &.{},
        /// A trait's default bodies are being linked.
        trait: ?*const ir.Trait = null,
    };

    fn function(self: *Linker, f: *const ir.Fn) Error!void {
        self.file = f.file;
        self.cur = f;
        defer self.cur = null;
        for (f.params) |p| {
            if (p.default) |d| {
                try self.expr(d);
                try self.value(p.type_name, p.name, d, false);
            }
            if (p.resolved) |r| r.* = try self.typeRef(p.type_name, f.line);
        }
        try self.stmts(f.body);
    }

    /// Fields of a component, a struct or a trait's params: their defaults (of their type)
    /// and the traits their types name.
    fn fieldList(self: *Linker, list: []const ir.Field, who: []const u8) Error!void {
        for (list) |fd| {
            if (fd.default) |d| {
                try self.expr(d);
                try self.value(fd.type_name, try std.fmt.allocPrint(self.a, "{s}.{s}", .{ who, fd.name }), d, false);
            }
            if (fd.resolved) |r| r.* = try self.typeRef(fd.type_name, fd.line);
        }
    }

    /// Value `v` of declared type `t` (`what` names it in the message): a literal of
    /// another type, a struct of another kind, a word that is no value of the enum, an
    /// element of a `list<T>` literal that is no `T` is an error. A bare word is an enum's
    /// value only in data (`side = enemy`; `data`); code writes `Side::enemy`. Anything
    /// else (a call, a variable) is checked when it runs.
    fn value(self: *Linker, t: []const u8, what: []const u8, v: *const ir.Expr, data_: bool) Error!void {
        if (t.len == 0 or std.mem.eql(u8, t, "any")) return;
        if (std.mem.startsWith(u8, t, "list<")) {
            const inner = t[5 .. t.len - 1];
            switch (v.kind) {
                .list => |l| for (l) |x| try self.value(inner, what, x, data_),
                .lit => |x| if (x != .nil) return fail(self.a, self.diag, self.file, v.line, "{s}: expected {s}", .{ what, try shortType(self.a, t, data_) }),
                .call => |c| if (try self.p.typeIn(self.a, self.m, c.text, data_) != null) return fail(self.a, self.diag, self.file, v.line, "{s}: expected {s}, not {s}", .{ what, try shortType(self.a, t, data_), c.text }),
                else => {},
            }
            return;
        }
        // An archetype (`character who`): `~c"characters::grandma"`, a fighter block's path in data.
        if (std.mem.eql(u8, t, "character")) return switch (v.kind) {
            .lit => |x| if (x == .nil or (x == .string and v.sigil == .character)) {} else fail(self.a, self.diag, self.file, v.line, "{s}: expected character (~c\"…\")", .{what}),
            .word => |w| if (data_ and try self.p.hasBlock(self.a, self.m, w, &.{"fighter"})) {} else fail(self.a, self.diag, self.file, v.line, "{s}: expected character (~c\"…\"), not {s}", .{ what, w }),
            .list, .map => fail(self.a, self.diag, self.file, v.line, "{s}: expected character (~c\"…\")", .{what}),
            else => {},
        };
        if (try self.p.typeIn(self.a, self.m, t, data_)) |decl| switch (decl) {
            .@"struct" => |st| switch (v.kind) {
                // Data names the field's struct by its name (`Place(…)` of a `list<foundation::Place>`).
                .call => |c| if (if (data_ and std.mem.eql(u8, c.text, st.name)) decl else try self.p.typeIn(self.a, self.m, c.text, data_)) |other| {
                    if (other != .@"struct" or other.@"struct" != st) return fail(self.a, self.diag, self.file, v.line, "{s}: expected {s}, not {s}", .{ what, st.name, c.text });
                    _ = try self.makes(try std.fmt.allocPrint(self.a, "{s}: ", .{what}), v.line, c, data_);
                } else if (c.target == null or c.args.len > 0 or !data_) {} else return fail(self.a, self.diag, self.file, v.line, "{s}: expected {s}(…), not {s}(…)", .{ what, st.name, c.text }),
                .lit => |x| if (x != .nil) return fail(self.a, self.diag, self.file, v.line, "{s}: expected {s}", .{ what, st.name }),
                .list => return fail(self.a, self.diag, self.file, v.line, "{s}: expected {s}, not a list", .{ what, st.name }),
                else => {},
            },
            .@"enum" => |en| switch (v.kind) {
                .word => |w| {
                    const k = std.mem.lastIndexOf(u8, w, "::");
                    if (k) |i| if (try self.p.enumIn(self.a, self.m, w[0..i], data_) != en)
                        return fail(self.a, self.diag, self.file, v.line, "{s}: expected {s}, not {s}", .{ what, en.name, w });
                    if (k == null and !data_) return fail(self.a, self.diag, self.file, v.line, "{s}: write {s}::{s}", .{ what, en.name, w });
                    const n = if (k) |i| w[i + 2 ..] else w;
                    if (en.value(n) == null) return fail(self.a, self.diag, self.file, v.line, "{s}: {s} has no value {s}", .{ what, en.name, n });
                },
                .field => |x| if (en.value(x.text) != null) return fail(self.a, self.diag, self.file, v.line, "{s}: write {s}::{s}", .{ what, en.name, x.text }),
                .lit => |x| switch (x) {
                    .nil => {},
                    .string => |n| if (en.value(n) == null) return fail(self.a, self.diag, self.file, v.line, "{s}: {s} has no value {s}", .{ what, en.name, n }),
                    // An int field's enum (`ItemPlace`): other numbers are fine.
                    .int => if (en.values.len == 0 or en.values[0].number == null) return fail(self.a, self.diag, self.file, v.line, "{s}: expected {s}", .{ what, en.name }),
                    else => return fail(self.a, self.diag, self.file, v.line, "{s}: expected {s}", .{ what, en.name }),
                },
                else => {},
            },
        };
        const want = std.meta.stringToEnum(ir.Type, t) orelse .any;
        if (want == .any or v.kind != .lit) return;
        const x = v.kind.lit;
        const ok = switch (want) {
            .int => x == .int or x == .bool,
            .float => x == .int or x == .float,
            .string, .object => x == .string,
            .bool => x == .bool,
            .any => true,
        };
        if (!ok and x != .nil) return fail(self.a, self.diag, self.file, v.line, "{s}: expected {s}", .{ what, t });
    }

    /// The enum a value of `e` is statically: `Side::enemy`, `Side::from(…)`, a parameter
    /// or field declared of it.
    fn staticEnum(self: *Linker, e: *const ir.Expr) Error!?*const ir.Enum {
        return switch (e.kind) {
            .word => |w| if (std.mem.lastIndexOf(u8, w, "::")) |k| try self.p.enumNamed(self.a, self.m, w[0..k]) else null,
            .call => |c| if (c.target) |t| if (t.* == .enum_from) t.enum_from else null else null,
            .local => |slot| if (self.cur) |f| for (f.params) |p| {
                if (p.slot == slot) break try self.p.enumNamed(self.a, self.m, p.type_name);
            } else null else null,
            .field => |x| if (self.comp) |c| for (self.p.fieldsOf(c)) |fd| {
                if (std.ascii.eqlIgnoreCase(fd.name, x.text)) break try self.p.enumNamed(self.a, self.m, fd.type_name);
            } else null else null,
            else => null,
        };
    }

    /// `a op b` with an enum: only `==`/`!=`, with the same enum (or anything not an int).
    fn enumCompare(self: *Linker, line: u32, op: ir.BinaryOp, lhs: *const ir.Expr, rhs: *const ir.Expr) Error!void {
        const l = try self.staticEnum(lhs);
        const r = try self.staticEnum(rhs);
        const one = l orelse r orelse return;
        if (op != .eq and op != .ne) return fail(self.a, self.diag, self.file, line, "{s}: an enum compares with == and != only", .{one.name});
        if (l != null and r != null and l != r) return fail(self.a, self.diag, self.file, line, "comparing {s} with {s}", .{ l.?.name, r.?.name });
        const other = if (l != null) rhs else lhs;
        if (other.kind == .lit and ir.numeric(other.kind.lit)) return fail(self.a, self.diag, self.file, line, "comparing {s} with a number", .{one.name});
        // The value runs as its name string, but code compares it with the enum's values.
        if (self.staticString(other)) return fail(self.a, self.diag, self.file, line, "comparing {s} with a string", .{one.name});
    }

    /// Whether `e` is statically a string: a literal, `str(…)`, a parameter or field
    /// declared `string`.
    fn staticString(self: *Linker, e: *const ir.Expr) bool {
        return switch (e.kind) {
            .lit => |x| x == .string,
            .call => |c| c.target != null and c.target.?.* == .builtin and std.mem.eql(u8, c.text, "str"),
            .local => |slot| if (self.cur) |f| for (f.params) |p| {
                if (p.slot == slot) break p.type == .string;
            } else false else false,
            .field => |x| if (self.comp) |c| for (self.p.fieldsOf(c)) |fd| {
                if (std.ascii.eqlIgnoreCase(fd.name, x.text)) break fd.type == .string;
            } else false else false,
            else => false,
        };
    }

    fn stmts(self: *Linker, list: []const ir.Stmt) Error!void {
        for (list) |*s| switch (s.kind) {
            .expr, .@"return" => |e| try self.expr(e),
            .assign => |x| {
                switch (x.target) {
                    .member => |m| try self.expr(m.obj),
                    .field => |f| try self.noField(s.line, f.text),
                    else => {},
                }
                try self.expr(x.value);
            },
            .@"if" => |x| {
                try self.expr(x.cond);
                try self.stmts(x.then);
                try self.stmts(x.@"else");
            },
            .@"while" => |x| {
                try self.expr(x.cond);
                try self.stmts(x.body);
            },
            .for_in => |x| {
                try self.expr(x.iter);
                if (x.to) |t| try self.expr(t);
                try self.stmts(x.body);
            },
            .local, .@"break", .@"continue", .fail => {},
        };
    }

    fn exprs(self: *Linker, list: []const *const ir.Expr) Error!void {
        for (list) |e| try self.expr(e);
    }

    fn named(self: *Linker, list: []const ir.Named) Error!void {
        for (list) |n| try self.expr(n.value);
    }

    fn expr(self: *Linker, e: *const ir.Expr) Error!void {
        if (e.sigil != .none) try self.sigil(e);
        switch (e.kind) {
            .lit, .local, .name, .host, .self, .ref => {},
            // Code: an enum's value (`Side::enemy`); a block's path is data's.
            .word => |w| {
                const k = std.mem.lastIndexOf(u8, w, "::") orelse return fail(self.a, self.diag, self.file, e.line, "unknown name {s}", .{w});
                const en = try self.p.enumNamed(self.a, self.m, w[0..k]) orelse {
                    const h = try foundationHint(self.p, self.a, w[0..k]);
                    if (h.len > 0) return fail(self.a, self.diag, self.file, e.line, "no enum {s}{s}", .{ w[0..k], h });
                    return fail(self.a, self.diag, self.file, e.line, "no enum {s} (write {s}(…) to call)", .{ w[0..k], w });
                };
                if (en.value(w[k + 2 ..]) == null) return fail(self.a, self.diag, self.file, e.line, "{s} has no value {s}", .{ en.name, w[k + 2 ..] });
            },
            .field => |f| try self.noField(e.line, f.text),
            .trait_op => |t| {
                try self.expr(t.obj);
                const r = try self.nativeRef(t.name) orelse try self.traitRef(if (t.op == .is) "" else try std.fmt.allocPrint(self.a, "{t}({s}): ", .{ t.op, t.name }), t.name, e.line);
                if ((t.op == .get or t.op == .all) and r == .engine) if (engineTrait(r.engine)) |et| if (et.kind != .mark)
                    return fail(self.a, self.diag, self.file, e.line, "{t}({s}): a {s} is not a component trait (host.as({s}))", .{ t.op, t.name, if (et.kind == .role) "role" else "host kind", t.name });
                t.resolved.* = r;
            },
            .call => |c| {
                try self.exprs(c.args);
                try self.named(c.named);
                if (c.target) |t| t.* = try self.resolve(e.line, c);
            },
            .exe => |x| try self.exprs(x.args),
            .unary => |u| try self.expr(u.operand),
            .binary => |b| {
                try self.expr(b.lhs);
                try self.expr(b.rhs);
                try self.enumCompare(e.line, b.op, b.lhs, b.rhs);
            },
            .logic => |b| {
                try self.expr(b.lhs);
                try self.expr(b.rhs);
            },
            .assign => |x| try self.expr(x.value),
            .member => |m| try self.expr(m.obj),
            .index => |x| {
                try self.expr(x.obj);
                try self.expr(x.key);
            },
            .list => |l| try self.exprs(l),
            .map => |m| {
                try self.exprs(m.keys);
                try self.exprs(m.values);
            },
            .method => |m| {
                // A role's or another kind's engine method on `host` of this kind (13).
                if (m.obj.kind == .host and self.ctx.kind.len > 0) for (traits.all()) |*et| for (et.methods) |ef| {
                    if (!ef.native or !std.mem.eql(u8, ef.name, m.text) or has(self.ctx.closure, .{ .engine = et.name })) continue;
                    return fail(self.a, self.diag, self.file, e.line, "host.{s}(): host is {s}, {s} is {s}'s (if (host is " ++ foundation ++ "::{s}) host.as(" ++ foundation ++ "::{s}).{s}())", .{ m.text, self.ctx.kind, m.text, et.name, et.name, et.name, m.text });
                };
                try self.expr(m.obj);
                try self.exprs(m.args);
                try self.named(m.named);
            },
        }
    }

    fn resolve(self: *Linker, line: u32, c: ir.Call) Error!ir.Callee {
        const t = c.text;
        if (c.super) return self.superCall(line, c);
        if (try self.makes("", line, c, false)) |st| return .{ .make = st };
        if (std.mem.lastIndexOf(u8, t, "::")) |k| if (std.mem.eql(u8, t[k + 2 ..], "from")) if (try self.p.enumNamed(self.a, self.m, t[0..k])) |en| {
            if (c.args.len != 1 or c.named.len > 0) return fail(self.a, self.diag, self.file, line, "{s} takes one argument (the value's name)", .{t});
            return .{ .enum_from = en };
        };
        // In a default body, the trait's own methods are the component's (virtual).
        if (self.ctx.trait != null and std.mem.indexOf(u8, t, "::") == null) if (methodArity(self.ctx.closure, t)) |n| {
            if (c.args.len > n) return fail(self.a, self.diag, self.file, line, "{s} takes {d} arguments", .{ t, n });
            return .virtual;
        };
        if (std.mem.lastIndexOf(u8, t, "::")) |k| if (!isPackage(t[0..k])) if (try self.findTrait(self.m.path, self.m.uses, t[0..k])) |r| return self.traitPath(line, c, r, t[k + 2 ..]);
        const f = try self.find(line, t) orelse {
            const path = try self.builtinPath(t);
            const b = self.env.builtin(self.env.ctx, path) orelse return fail(self.a, self.diag, self.file, line, "unknown function {s}{s}", .{ t, try foundationHint(self.p, self.a, t) });
            if (b.moved) |m| return if (m.len > 0)
                fail(self.a, self.diag, self.file, line, "unknown function {s} (did you mean {s})", .{ t, m })
            else
                fail(self.a, self.diag, self.file, line, "unknown function {s}", .{t});
            if (c.named.len == 0) {
                for (c.args, 0..) |x, k| try self.sigilArg(line, t, b.sig, k, x);
                return .{ .builtin = .{ .id = b.id } };
            }
            // Named arguments go to their positions; none may leave a gap.
            const slots = try self.a.alloc(u8, c.named.len);
            var used: u64 = (@as(u64, 1) << @intCast(@min(c.args.len, 63))) - 1;
            for (c.named, slots) |n, *s| {
                const k = sigParam(b.sig, n.name) orelse return fail(self.a, self.diag, self.file, line, "builtin {s} has no parameter {s}", .{ t, n.name });
                if (k >= 32 or used & (@as(u64, 1) << @intCast(k)) != 0) return fail(self.a, self.diag, self.file, line, "{s}: {s} given twice", .{ t, n.name });
                used |= @as(u64, 1) << @intCast(k);
                s.* = @intCast(k);
            }
            if (used & (used + 1) != 0) return fail(self.a, self.diag, self.file, line, "{s}: the arguments before a named one are needed", .{t});
            for (c.named, slots) |n, k| try self.sigilArg(line, t, b.sig, k, n.value);
            for (c.args, 0..) |x, k| try self.sigilArg(line, t, b.sig, k, x);
            return .{ .builtin = .{ .id = b.id, .slots = slots } };
        };
        if (c.args.len > f.params.len) return fail(self.a, self.diag, self.file, line, "{s} takes {d} arguments", .{ t, f.params.len });
        for (c.named, 0..) |n, i| {
            for (c.named[0..i]) |m| if (std.mem.eql(u8, m.name, n.name)) return fail(self.a, self.diag, self.file, line, "{s}: {s} given twice", .{ t, n.name });
            const k = for (f.params, 0..) |p, k| {
                if (std.mem.eql(u8, p.name, n.name)) break k;
            } else return fail(self.a, self.diag, self.file, line, "{s} has no parameter {s}", .{ t, n.name });
            if (k < c.args.len) return fail(self.a, self.diag, self.file, line, "{s}: {s} given twice", .{ t, n.name });
        }
        for (f.params[c.args.len..]) |p| if (p.default == null) for (c.named) |n| {
            if (std.mem.eql(u8, n.name, p.name)) break;
        } else return fail(self.a, self.diag, self.file, line, "{s}: no value for {s}", .{ t, p.name });
        return .{ .func = f };
    }

    /// The struct call `c` makes (`Wave(turn = 3)`), its fields checked: named only, each
    /// one of it, once, of its type; every one without a default given. Null: no struct.
    /// `prefix` starts its messages (`placement: `).
    fn makes(self: *Linker, prefix: []const u8, line: u32, c: ir.Call, data_: bool) Error!?*const ir.Struct {
        const decl = try self.p.typeIn(self.a, self.m, c.text, data_) orelse return null;
        if (decl == .@"enum") return fail(self.a, self.diag, self.file, line, "{s}{s} is an enum: write {s}::value", .{ prefix, c.text, c.text });
        const st = decl.@"struct";
        if (c.args.len > 0) return fail(self.a, self.diag, self.file, line, "{s}{s}: a struct takes named fields (f = v)", .{ prefix, c.text });
        for (c.named, 0..) |n, i| {
            for (c.named[0..i]) |o| if (std.mem.eql(u8, o.name, n.name)) return fail(self.a, self.diag, self.file, line, "{s}{s}: {s} given twice", .{ prefix, c.text, n.name });
            const f = st.field(n.name) orelse return fail(self.a, self.diag, self.file, line, "{s}{s} takes {s}", .{ prefix, c.text, try fieldNames(self.a, st.fields) });
            try self.value(f.type_name, try std.fmt.allocPrint(self.a, "{s}{s}.{s}", .{ prefix, st.name, f.name }), n.value, data_);
        }
        for (st.fields) |f| if (f.default == null) for (c.named) |n| {
            if (std.mem.eql(u8, n.name, f.name)) break;
        } else return fail(self.a, self.diag, self.file, line, "{s}{s} needs {s}", .{ prefix, c.text, f.name });
        return st;
    }

    /// Argument `k` of builtin `t`: a sigil of another kind than its parameter's is an
    /// error; so is a `method` parameter (`Subscribe`) outside a component or a trait, or
    /// a string there that names none of its methods.
    fn sigilArg(self: *Linker, line: u32, t: []const u8, sig: []const u8, k: usize, x: *const ir.Expr) Error!void {
        if (std.mem.eql(u8, sigType(sig, k), "method")) {
            if (self.comp == null and self.ctx.trait == null) return fail(self.a, self.diag, self.file, line, "{s}: call it in a component's method", .{t});
            if (x.kind != .lit or x.kind.lit != .string) return;
            const n = x.kind.lit.string;
            const own = if (self.comp) |c| c.name else self.ctx.trait.?.name;
            if (self.comp != null) {
                for (self.ctx.methods) |r| if (std.mem.eql(u8, r.f.name, n)) return;
            } else if (methodArity(self.ctx.closure, n) != null) return;
            return fail(self.a, self.diag, self.file, line, "{s}: {s} has no method {s}", .{ t, own, n });
        }
        if (x.sigil == .none) return;
        const want = ir.Sigil.ofType(sigType(sig, k)) orelse return;
        if (want != x.sigil) return fail(self.a, self.diag, self.file, line, "{s}: argument {d} is a {t}, not a {t}", .{ t, k + 1, want, x.sigil });
    }

    /// Sigil string `e`: a block of the program declares it, or the host knows it.
    fn sigil(self: *Linker, e: *const ir.Expr) Error!void {
        const n = e.kind.lit.string;
        if (try self.p.hasBlock(self.a, self.m, n, e.sigil.blocks())) return;
        const f = self.env.exists orelse return;
        if (f(self.env.ctx, e.sigil, n) orelse true) return;
        return fail(self.a, self.diag, self.file, e.line, "no {t} {s}", .{ e.sigil, n });
    }

    /// An `ai_profile` block's field `f`: true when checked here (its `score`, a component);
    /// the Classic table's names are none of OG Script's (rules_text.zig Profiles).
    fn profileField(self: *Linker, f: ir.Named) Error!bool {
        const gone = [_][2][]const u8{
            .{ "scoring", "a profile scores by its own fields (weapons, follow_lock, score, wakeful, near); share them by its base: ai_profile x : a" },
            .{ "scoring_rules", "write its fields in the profile: weapons = by_health; follow_lock = false; score = ai_scoring::Avenge;" },
            .{ "generic_ai", "a fighter names its profile: ai_profile = ai::x;" },
        };
        for (gone) |g| if (std.mem.eql(u8, f.name, g[0])) return fail(self.a, self.diag, self.file, f.value.line, "ai_profile has no {s}: {s}", .{ g[0], g[1] });
        if (!std.mem.eql(u8, f.name, "score")) return false;
        if (f.value.kind != .word) return fail(self.a, self.diag, self.file, f.value.line, "score: expected a component (score = ai_scoring::Avenge)", .{});
        if (try self.p.component(self.a, self.m, f.value.kind.word) == null) return fail(self.a, self.diag, self.file, f.value.line, "score: no component {s}", .{f.value.kind.word});
        return true;
    }

    /// Block `e`'s `import X;` (`v`, its `same_as`): a block at that path, not `e` itself;
    /// where several kinds have the path, `X<kind>` says which.
    fn importOf(self: *Linker, e: ir.Entity, v: *const ir.Expr) Error!void {
        const t = ir.Import.of(v.kind.word);
        const own = try key(self.a, self.m.path, e.name);
        var found: std.ArrayList([]const u8) = .empty;
        var it = self.p.blocks.keyIterator();
        while (it.next()) |k| {
            const sp = std.mem.indexOfScalar(u8, k.*, ' ') orelse continue;
            const kind = k.*[0..sp];
            const p = k.*[sp + 1 ..];
            if (!std.mem.eql(u8, p, t.path) and !std.mem.eql(u8, p, try key(self.a, self.m.path, t.path))) continue;
            if (std.mem.eql(u8, kind, e.kind) and std.mem.eql(u8, p, own)) continue;
            if (t.kind.len > 0 and !std.mem.eql(u8, kind, t.kind)) continue;
            try found.append(self.a, kind);
        }
        if (found.items.len == 0) return fail(self.a, self.diag, self.file, v.line, "import {s}: no {s} there", .{ v.kind.word, if (t.kind.len > 0) t.kind else "block" });
        if (found.items.len > 1) {
            std.mem.sort([]const u8, found.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.order(u8, x, y) == .lt;
                }
            }.lt);
            return fail(self.a, self.diag, self.file, v.line, "import {s}: a {s} and a {s} have this path, name one: import {s}<{s}>;", .{ t.path, found.items[0], found.items[1], t.path, found.items[0] });
        }
    }

    /// Data block `e`: its kind, archetype, fields (by its host's schema), attachments,
    /// nested blocks and commands.
    fn block(self: *Linker, e: ir.Entity) Error!void {
        if (self.env.schema) |sc| if (sc(e.kind, "") == .unknown_kind) return fail(self.a, self.diag, self.file, e.line, "unknown block kind {s}", .{e.kind});
        // A fighter's archetype may be a hero (`fighter x: characters::sullivan`: an enemy made of a hero).
        const kinds: []const []const u8 = if (std.mem.eql(u8, e.kind, "fighter")) &.{ "fighter", "hero" } else &.{e.kind};
        if (e.base.len > 0 and !try self.p.hasBlock(self.a, self.m, e.base, kinds)) return fail(self.a, self.diag, self.file, e.line, "no {s} {s}", .{ e.kind, e.base });
        for (e.fields) |f| if (std.mem.eql(u8, f.name, "same_as") and f.value.kind == .word) try self.importOf(e, f.value);
        for (e.vars) |v| {
            if (self.env.schema) |sc| if (sc(e.kind, v.name) == .field) return fail(self.a, self.diag, self.file, v.line, "{s} has field {s}: no var of that name", .{ e.kind, v.name });
            if (v.default) |d| try self.data(d, true);
        }
        for (e.fields) |f| {
            if (self.env.schema) |sc| switch (sc(e.kind, f.name)) {
                .unknown_kind, .no_schema => {},
                .no_field => return fail(self.a, self.diag, self.file, f.value.line, "{s} has no field {s}", .{ e.kind, f.name }),
                .field => |fd| {
                    try self.fieldValue(fd, f.value);
                    if (fd.rows) {
                        try self.sigils(f.value);
                        continue;
                    }
                },
            };
            // `import X;`: importOf's (a kind after its path is no block's name).
            if (std.mem.eql(u8, f.name, "same_as") and f.value.kind == .word) continue;
            if (std.mem.eql(u8, e.kind, "ai_profile") and try self.profileField(f)) continue;
            try self.data(f.value, true);
        }
        for (e.attach) |x| {
            const c = try self.p.component(self.a, self.m, x.component) orelse return fail(self.a, self.diag, self.file, x.line, "no component {s}", .{x.component});
            for (x.params) |p| {
                const fd = for (self.p.fieldsOf(c)) |fd| {
                    if (fd.kind == .param and std.mem.eql(u8, fd.name, p.name)) break fd;
                } else return fail(self.a, self.diag, self.file, x.line, "{s} has no param {s}", .{ x.component, p.name });
                // Its type as the component's module names it (`Side`: its own, or foundation's).
                const at = self.m;
                defer self.m = at;
                for (self.p.modules.items) |*mm| for (mm.components) |y| if (y == c) {
                    self.m = mm;
                };
                try self.value(fd.type_name, p.name, p.value, true);
                try self.data(p.value, true);
            }
        }
        for (e.children) |c| try self.block(c);
        for (e.rows) |r| try self.data(r, false);
    }

    /// Value `v` of schema field `fd`: of its type, one of its words, a block of its kind.
    fn fieldValue(self: *Linker, fd: Field, v: *const ir.Expr) Error!void {
        // A type of the prelude (`list<Place>`, `Camera`, `ItemPlace`).
        if (fd.type_name.len > 0) return self.value(try engineType(self.a, fd.type_name), fd.name, v, true);
        if (fd.check) |c| {
            if (c(v)) |m| return fail(self.a, self.diag, self.file, v.line, "{s}: {s}", .{ fd.name, m });
            return;
        }
        const x = if (v.kind == .unary and v.kind.unary.op == .neg) v.kind.unary.operand else v;
        const ok = switch (x.kind) {
            .lit => |l| switch (fd.type) {
                .int => l == .int or l == .bool,
                .float => l == .int or l == .float,
                // A reference field's `nil`: none (`look = nil`: no look, not its same_as block's).
                .string, .object => (l == .string and x == v) or (l == .nil and fd.ref != .none),
                .bool => l == .bool,
                .any => true,
            },
            .word => |w| if (fd.ref != .none) {
                if (try self.p.hasBlock(self.a, self.m, w, fd.ref.blocks())) return;
                return fail(self.a, self.diag, self.file, v.line, "{s}: no {t} {s}", .{ fd.name, fd.ref, w });
            } else false,
            .ref => fd.type == .string or fd.type == .object,
            else => false,
        };
        if (!ok) return fail(self.a, self.diag, self.file, v.line, "{s}: expected {t}", .{ fd.name, fd.type });
    }

    /// Data value `v`: sigils, paths naming blocks; `record`: a call in it is a record
    /// (`Speed(anim = "walk")`: named fields only), else a command (any arguments).
    fn data(self: *Linker, v: *const ir.Expr, record: bool) Error!void {
        if (v.sigil != .none) try self.sigil(v);
        switch (v.kind) {
            .word => |w| if (std.mem.lastIndexOf(u8, w, "::")) |k| if (!try self.p.hasBlock(self.a, self.m, w, &.{})) {
                const en = try self.p.enumIn(self.a, self.m, w[0..k], true) orelse return fail(self.a, self.diag, self.file, v.line, "no block {s}", .{w});
                if (en.value(w[k + 2 ..]) == null) return fail(self.a, self.diag, self.file, v.line, "{s} has no value {s}", .{ en.name, w[k + 2 ..] });
            },
            .call => |c| {
                if (record) if (try self.makes("", v.line, c, true)) |st| if (c.target) |t| {
                    t.* = .{ .make = st };
                };
                if (record and c.args.len > 0) return fail(self.a, self.diag, self.file, v.line, "{s}: a record takes named fields (f = v)", .{c.text});
                for (c.args) |x| try self.data(x, true);
                for (c.named) |n| try self.data(n.value, true);
            },
            .list => |l| for (l) |x| try self.data(x, true),
            .unary => |u| try self.data(u.operand, true),
            else => {},
        }
    }

    /// The sigils of a rules row (data: not linked otherwise).
    fn sigils(self: *Linker, v: *const ir.Expr) Error!void {
        if (v.sigil != .none) try self.sigil(v);
        switch (v.kind) {
            .call => |c| {
                for (c.args) |x| try self.sigils(x);
                for (c.named) |n| try self.sigils(n.value);
            },
            .list => |l| for (l) |x| try self.sigils(x),
            else => {},
        }
    }

    /// The function `t` names; null: a builtin's (`builtinPath`) or none.
    fn find(self: *Linker, line: u32, t: []const u8) Error!?*const ir.Fn {
        if (std.mem.indexOf(u8, t, "::") != null) return self.p.fns.get(t);
        if (self.comp != null) for (self.ctx.methods) |r| if (std.mem.eql(u8, r.f.name, t)) return r.f;
        if (self.p.fns.get(try key(self.a, self.m.path, t))) |f| return f;
        var found: ?*const ir.Fn = null;
        var from: ?[]const u8 = null;
        for (self.m.uses) |u| {
            const k = try key(self.a, u, t);
            const f = self.p.fns.get(k);
            if (f == null and !self.isBuiltin(k)) continue;
            if (from != null and (f == null or found != f)) return fail(self.a, self.diag, self.file, line, "{s} is in more than one used namespace", .{t});
            found = f;
            from = k;
        }
        return if (from != null) found else self.p.fns.get(t);
    }

    /// The builtin plain `t` names: of a used package (`use fighter;`), else of the root.
    fn builtinPath(self: *Linker, t: []const u8) Allocator.Error![]const u8 {
        if (std.mem.indexOf(u8, t, "::") == null) for (self.m.uses) |u| {
            const k = try key(self.a, u, t);
            if (self.isBuiltin(k)) return k;
        };
        return t;
    }

    fn isBuiltin(self: *const Linker, path: []const u8) bool {
        const b = self.env.builtin(self.env.ctx, path) orelse return false;
        return b.moved == null;
    }

    // ---------------------------------------------------------------- traits

    /// Trait `path` as code in a module of `mod` (its `uses`) names it: the module's, a
    /// used namespace's, the root's; else the engine's (by name or by host kind, `fighter`).
    fn findTrait(self: *const Linker, mod: []const u8, uses: []const []const u8, path: []const u8) Allocator.Error!?ir.TraitRef {
        const p = self.p;
        if (std.mem.startsWith(u8, path, foundation ++ "::")) return if (engineTrait(path[foundation.len + 2 ..])) |et| .{ .engine = et.name } else null;
        if (std.mem.indexOf(u8, path, "::") != null) return if (p.traits.get(path)) |t| .{ .script = t } else null;
        if (mod.len > 0) if (p.traits.get(try key(self.a, mod, path))) |t| return .{ .script = t };
        for (uses) |u| {
            if (std.mem.eql(u8, u, foundation)) if (engineTrait(path)) |et| return .{ .engine = et.name };
            if (p.traits.get(try key(self.a, u, path))) |t| return .{ .script = t };
        }
        if (p.traits.get(path)) |t| return .{ .script = t };
        if (kindTrait(path)) |et| return .{ .engine = et.name };
        return null;
    }

    /// `x.get(Guard)`: the native component `name` names, when no trait has that name
    /// (a mark: `Monitor` stays the engine's).
    fn nativeRef(self: *const Linker, name: []const u8) Allocator.Error!?ir.TraitRef {
        if (try self.findTrait(self.m.path, self.m.uses, name) != null) return null;
        for (self.env.natives) |n| if (std.mem.eql(u8, n.name, name)) return .{ .native = n.name };
        return null;
    }

    /// Trait `path` in this module; `prefix` starts the message when it names none.
    fn traitRef(self: *Linker, prefix: []const u8, path: []const u8, line: u32) Error!ir.TraitRef {
        if (try self.findTrait(self.m.path, self.m.uses, path)) |r| return r;
        if (try self.p.component(self.a, self.m, path) != null) return fail(self.a, self.diag, self.file, line, "{s}{s} is a component, not a trait", .{ prefix, path });
        return fail(self.a, self.diag, self.file, line, "{s}no trait {s}{s}", .{ prefix, path, try foundationHint(self.p, self.a, path) });
    }

    /// The trait a param's or parameter's type names (`Shielded`, `fighter`); a lower-case
    /// word that is no host kind stays unchecked, as before traits.
    fn typeRef(self: *Linker, name: []const u8, line: u32) Error!ir.TraitRef {
        // A struct, an enum, a list: no trait (`value` checks them).
        if (std.mem.startsWith(u8, name, "list<") or try self.p.typeNamed(self.a, self.m, name) != null) return .unresolved;
        if (std.ascii.isLower(name[0]) and std.mem.indexOf(u8, name, "::") == null) return if (kindTrait(name)) |et| .{ .engine = et.name } else .unresolved;
        // A type of foundation's, bare.
        if (try self.findTrait(self.m.path, self.m.uses, name) == null and self.p.types.contains(try key(self.a, foundation, name)))
            return fail(self.a, self.diag, self.file, line, "no type {s}{s}", .{ name, try foundationHint(self.p, self.a, name) });
        return self.traitRef("", name, line);
    }

    fn supersOf(self: *const Linker, r: ir.TraitRef) Allocator.Error![]const ir.TraitRef {
        var out: std.ArrayList(ir.TraitRef) = .empty;
        switch (r) {
            .unresolved, .native => {},
            .script => |t| for (t.supers) |n| if (try self.findTrait(t.module, t.uses, n)) |x| try out.append(self.a, x),
            .engine => |n| if (engineTrait(n)) |et| for (et.supers) |x| try out.append(self.a, .{ .engine = x }),
        }
        return out.items;
    }

    /// `roots` and all their supertraits, each once, depth first (the most specific first).
    fn closure(self: *const Linker, roots: []const ir.TraitRef) Allocator.Error![]const ir.TraitRef {
        var out: std.ArrayList(ir.TraitRef) = .empty;
        for (roots) |r| try self.addClosure(&out, r);
        return out.items;
    }

    fn addClosure(self: *const Linker, out: *std.ArrayList(ir.TraitRef), r: ir.TraitRef) Allocator.Error!void {
        if (has(out.items, r)) return;
        try out.append(self.a, r);
        for (try self.supersOf(r)) |x| try self.addClosure(out, x);
    }

    /// Whether `b` is a supertrait of `a` (directly or through a chain).
    fn isSuper(self: *const Linker, a: ir.TraitRef, b: ir.TraitRef) Allocator.Error!bool {
        const cl = try self.closure(&.{a});
        return !a.eql(b) and has(cl, b);
    }

    const Body = union(enum) { none, one: struct { f: *const ir.Fn, t: *const ir.Trait }, clash: [2][]const u8 };

    /// The default body of `name` among `cl`: the most specific trait's; two
    /// unrelated ones clash.
    fn bodyOf(self: *const Linker, cl: []const ir.TraitRef, name: []const u8) Allocator.Error!Body {
        var cands: std.ArrayList(struct { f: *const ir.Fn, t: *const ir.Trait }) = .empty;
        for (cl) |r| if (r == .script) for (r.script.methods) |m| if (m.body and std.mem.eql(u8, m.f.name, name)) try cands.append(self.a, .{ .f = m.f, .t = r.script });
        var kept: std.ArrayList(@TypeOf(cands.items[0])) = .empty;
        for (cands.items, 0..) |c, i| {
            const overridden = for (cands.items, 0..) |d, j| {
                if (i != j and try self.isSuper(.{ .script = d.t }, .{ .script = c.t })) break true;
            } else false;
            if (!overridden) try kept.append(self.a, c);
        }
        return switch (kept.items.len) {
            0 => .none,
            1 => .{ .one = .{ .f = kept.items[0].f, .t = kept.items[0].t } },
            else => .{ .clash = .{ kept.items[0].t.name, kept.items[1].t.name } },
        };
    }

    /// Trait `t`: its supertraits (no role, no cycle), its methods against theirs and the
    /// engine's, then its default bodies.
    fn trait(self: *Linker, t: *const ir.Trait) Error!void {
        self.file = t.file;
        const prefix = try std.fmt.allocPrint(self.a, "trait {s}: ", .{t.name});
        for (t.supers) |n| {
            const r = try self.traitRef(prefix, n, t.line);
            if (r == .engine and engineTrait(r.engine).?.kind == .role) return fail(self.a, self.diag, self.file, t.line, "{s} is a role the engine grants: write for {s}", .{ r.engine, r.engine });
        }
        var path: std.ArrayList([]const u8) = .empty;
        try self.cycle(t, t, &path);
        const cl = try self.closure(&.{.{ .script = t }});
        self.ctx = .{ .closure = cl, .kind = kindOf(cl), .trait = t };
        defer self.ctx = .{};
        for (t.methods) |m| {
            for (cl[1..]) |r| if (r == .script) for (r.script.methods) |sm| if (std.mem.eql(u8, sm.f.name, m.f.name)) try self.arity(t.name, m.f, r.script.name, sm.f.params.len, t.line);
            if (m.body) try self.engineCheck(t.name, true, m.f);
        }
        try self.fieldList(t.params, t.name);
        for (t.methods) |m| if (m.body) try self.function(m.f);
    }

    /// A path of supertraits from `t` back to `start` is an error (16).
    fn cycle(self: *Linker, start: *const ir.Trait, t: *const ir.Trait, path: *std.ArrayList([]const u8)) Error!void {
        try path.append(self.a, t.name);
        defer _ = path.pop();
        for (try self.supersOf(.{ .script = t })) |r| if (r == .script) {
            if (r.script == start) {
                const chain = try std.mem.join(self.a, ": ", path.items);
                return fail(self.a, self.diag, self.file, start.line, "trait {s}: a trait can't be its own supertrait ({s}: {s})", .{ start.name, chain, start.name });
            }
            const seen = for (path.items) |n| {
                if (std.mem.eql(u8, n, r.script.name)) break true;
            } else false;
            if (!seen) try self.cycle(start, r.script, path);
        };
    }

    /// `who.f` declares `f` with the parameters of `T.f` (`n` of them), else error 2.
    fn arity(self: *Linker, who: []const u8, f: *const ir.Fn, t: []const u8, n: usize, line: u32) Error!void {
        if (f.params.len == n) return;
        return fail(self.a, self.diag, self.file, line, "{s}.{s} takes {d} parameter{s} (as {s}.{s}), not {d}", .{ who, f.name, n, plural(n), t, f.name, f.params.len });
    }

    /// Component `c`'s host kinds and roles, traits, and method table (`Program.tables`).
    fn table(self: *Linker, c: *const ir.Component) Error!void {
        var roots: std.ArrayList(ir.TraitRef) = .empty;
        var kinds: std.ArrayList([]const u8) = .empty;
        var roles: traits.Roles = .empty;
        for (c.hosts) |h| {
            // `for Battle`: a host kind is its lowercase word (a role keeps its capital).
            const low = try std.ascii.allocLowerString(self.a, h);
            if (!std.mem.eql(u8, low, h) and kindTrait(low) != null and (engineTrait(h) == null or engineTrait(h).?.kind != .role))
                return fail(self.a, self.diag, self.file, c.line, "{s} for {s}: a host kind is lowercase: write for {s}", .{ c.name, h, low });
            const et = engineTrait(h) orelse kindTrait(h) orelse return fail(self.a, self.diag, self.file, c.line, "{s} for {s}: no such host kind", .{ c.name, h });
            if (et.kind == .role) {
                roles.insert(traits.Role.of(h).?);
                for (c.hosts) |g| if (std.mem.eql(u8, g, "fighter")) return fail(self.a, self.diag, self.file, c.line, "{s} already means fighter", .{h});
            } else if (!std.mem.eql(u8, hostOf(et), h)) return fail(self.a, self.diag, self.file, c.line, "{s} for {s}: no such host kind", .{ c.name, h });
            try roots.append(self.a, .{ .engine = et.name });
            try kinds.append(self.a, if (et.kind == .role) "fighter" else h);
        }
        for (c.traits) |n| {
            const r = try self.traitRef("", n, c.line);
            if (r == .engine and engineTrait(r.engine).?.kind == .role) return fail(self.a, self.diag, self.file, c.line, "{s} is a role the engine grants: write for {s}", .{ r.engine, r.engine });
            const tk = kindOf(try self.closure(&.{r}));
            if (kinds.items.len > 0 and tk.len > 0) for (kinds.items) |k| {
                if (has(try self.closure(&.{.{ .engine = kindTrait(k).?.name }}), .{ .engine = kindTrait(tk).?.name })) break;
            } else return fail(self.a, self.diag, self.file, c.line, "{s} for {s}: {s} is for {s}", .{ c.name, try std.mem.join(self.a, ", ", c.hosts), n, tk });
            try roots.append(self.a, r);
        }
        const cl = try self.closure(roots.items);
        self.ctx = .{ .closure = cl, .kind = if (kinds.items.len > 0) kinds.items[0] else kindOf(cl) };
        var methods: std.ArrayList(Resolved) = .empty;
        for (c.methods) |f| {
            try methods.append(self.a, .{ .f = f });
            try self.engineCheck(c.name, false, f);
        }
        for (cl) |r| if (r == .script) for (r.script.methods) |m| {
            const n = m.f.name;
            if (for (methods.items) |x| {
                if (std.mem.eql(u8, x.f.name, n)) break true;
            } else false) {
                // Its own (or one taken already): the parameters as the trait's.
                for (c.methods) |f| if (std.mem.eql(u8, f.name, n)) try self.arity(c.name, f, r.script.name, m.f.params.len, f.line);
                continue;
            }
            for (cl) |q| if (q == .script and q.script != r.script) for (q.script.methods) |o| if (std.mem.eql(u8, o.f.name, n)) try self.arity(q.script.name, o.f, r.script.name, m.f.params.len, c.line);
            switch (try self.bodyOf(cl, n)) {
                .none => return fail(self.a, self.diag, self.file, c.line, "{s}: no {s}() (required by {s})", .{ c.name, n, r.script.name }),
                .clash => |x| return fail(self.a, self.diag, self.file, c.line, "{s}: {s} has defaults in {s} and {s}: define it", .{ c.name, n, x[0], x[1] }),
                .one => |b| try methods.append(self.a, .{ .f = b.f, .from = b.t }),
            }
        };
        self.ctx.methods = methods.items;
        // Its traits' params (the most general first), its own declaration of one overriding it.
        var fields: std.ArrayList(ir.Field) = .empty;
        var i = cl.len;
        while (i > 0) {
            i -= 1;
            if (cl[i] == .script) for (cl[i].script.params) |tp| {
                if (fieldIn(fields.items, tp.name) != null) continue;
                const own = fieldIn(c.fields, tp.name);
                if (own) |o| if (o.kind != .param) return fail(self.a, self.diag, self.file, o.line, "{s}: {s} is a param of {s}", .{ c.name, tp.name, cl[i].script.name });
                try fields.append(self.a, own orelse tp);
            };
        }
        for (c.fields) |f| if (fieldIn(fields.items, f.name) == null) try fields.append(self.a, f);
        try self.p.tables.put(self.a, c, .{ .traits = cl, .roles = roles, .methods = methods.items, .fields = fields.items });
    }

    /// Method `f` of `who` (a component, or a trait's default body) against the engine's
    /// methods of its traits: not a native one (12), their parameters (6); an engine event
    /// needs a host (8); a name close to one is a warning (7).
    fn engineCheck(self: *Linker, who: []const u8, is_trait: bool, f: *const ir.Fn) Error!void {
        for (self.ctx.closure) |r| if (r == .engine) for (engineTrait(r.engine).?.methods) |ef| if (std.mem.eql(u8, ef.name, f.name)) {
            if (ef.native) return fail(self.a, self.diag, self.file, f.line, "{s} is the engine's ({s}): a component can't define it", .{ f.name, r.engine });
            const n = ef.arity();
            if (n != f.params.len) return fail(self.a, self.diag, self.file, f.line, "{s} takes {d} parameter{s} ({s}), not {d}", .{ f.name, n, plural(n), ef.params, f.params.len });
            return;
        };
        if (self.ctx.kind.len == 0) {
            for (traits.all()) |*et| for (et.methods) |ef| if (!ef.native and std.mem.eql(u8, ef.name, f.name)) {
                if (is_trait) return fail(self.a, self.diag, self.file, f.line, "trait {s}: {s} is an engine event: name the host (trait {s}: " ++ foundation ++ "::{s})", .{ who, f.name, who, et.name });
                return fail(self.a, self.diag, self.file, f.line, "{s}: {s} is an engine event: name the host (for {s})", .{ who, f.name, if (et.host) |h| h else et.name });
            };
            return;
        }
        if (!std.mem.startsWith(u8, f.name, "On") and !std.mem.startsWith(u8, f.name, "Can")) return;
        for (self.ctx.closure) |r| if (r == .engine) for (engineTrait(r.engine).?.methods) |ef| if (!ef.native and near(ef.name, f.name)) {
            try self.p.warnings.append(self.a, .{ .file = self.file, .line = f.line, .message = try std.fmt.allocPrint(self.a, "{s}: no event of {s} ({s}?)", .{ f.name, self.ctx.kind, ef.name }), .parts = .{ f.name, self.ctx.kind, ef.name } });
            return;
        };
    }

    /// `super.f(…)` in method `f` that overrides a trait's `f`: the body it would take
    /// otherwise (a component: from its traits; a trait: from its supertraits).
    fn superCall(self: *Linker, line: u32, c: ir.Call) Error!ir.Callee {
        const n = c.text;
        const cur = self.cur orelse return self.superOutside(line, n);
        if (!std.mem.eql(u8, cur.name, n) or (self.comp == null and self.ctx.trait == null)) return self.superOutside(line, n);
        const cl = if (self.ctx.trait) |t| try self.closure(try self.supersOf(.{ .script = t })) else self.ctx.closure;
        const k = methodArity(cl, n) orelse return self.superOutside(line, n);
        if (c.args.len > k) return fail(self.a, self.diag, self.file, line, "super.{s} takes {d} arguments", .{ n, k });
        return switch (try self.bodyOf(cl, n)) {
            .one => |b| .{ .trait_default = .{ .body = b.f } },
            .clash => |x| fail(self.a, self.diag, self.file, line, "super.{s}: defaults in {s} and {s}: write {s}::{s}(self, …)", .{ n, x[0], x[1], x[0], n }),
            .none => if (engineOwner(cl, n)) |et| .{ .trait_default = .{ .body = self.p.engineBody(et, n) } } else fail(self.a, self.diag, self.file, line, "super.{s}: no default body", .{n}),
        };
    }

    fn superOutside(self: *Linker, line: u32, n: []const u8) Error {
        return fail(self.a, self.diag, self.file, line, "super.{s} outside a method that overrides {s}", .{ n, n });
    }

    /// `T::f(self, …)`: the default body of `f` as trait `T` has it, for the instance given first.
    fn traitPath(self: *Linker, line: u32, c: ir.Call, r: ir.TraitRef, n: []const u8) Error!ir.Callee {
        const cl = try self.closure(&.{r});
        const k = methodArity(cl, n) orelse return fail(self.a, self.diag, self.file, line, "{s} has no method {s}", .{ r.name(), n });
        if (c.args.len == 0 or c.args.len - 1 > k) return fail(self.a, self.diag, self.file, line, "{s}: write {s}(self, …) with up to {d} more", .{ c.text, c.text, k });
        return switch (try self.bodyOf(cl, n)) {
            .one => |b| .{ .trait_default = .{ .body = b.f, .trait = r } },
            .clash => |x| fail(self.a, self.diag, self.file, line, "{s}: defaults in {s} and {s}: write {s}::{s}(self, …)", .{ c.text, x[0], x[1], x[0], n }),
            .none => if (engineOwner(cl, n)) |et| .{ .trait_default = .{ .body = self.p.engineBody(et, n), .trait = r } } else fail(self.a, self.diag, self.file, line, "{s}: no default body", .{c.text}),
        };
    }

    /// A bare name in a default body (9): a trait has no fields.
    fn noField(self: *Linker, line: u32, n: []const u8) Error!void {
        if (self.ctx.trait == null) return;
        // A param of the trait (or a supertrait's): the instance's field.
        for (self.ctx.closure) |r| if (r == .script) if (fieldIn(r.script.params, n) != null) return;
        return fail(self.a, self.diag, self.file, line, "a trait has no fields: {s} (add fn {s}(); and define it in the component)", .{ n, n });
    }
};

/// A component's method table and what it implements.
pub const Table = struct {
    /// Its traits, supertraits included, the most specific first (`for fighter`:
    /// `Fighter`, `Actor`, `Object`).
    traits: []const ir.TraitRef,
    /// `for Hero`, `for Enemy`: active only while the host has the role (`Object.for_roles`).
    roles: traits.Roles,
    /// Its own methods, then the default bodies it takes.
    methods: []const Resolved,
    /// Its traits' params, then its own fields (`Program.fieldsOf`).
    fields: []const ir.Field = &.{},
};

fn fieldIn(list: []const ir.Field, name: []const u8) ?ir.Field {
    for (list) |f| if (std.ascii.eqlIgnoreCase(f.name, name)) return f;
    return null;
}

/// `a, b, c`.
fn fieldNames(a: Allocator, list: []const ir.Field) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (list, 0..) |f, i| {
        if (i > 0) try out.appendSlice(a, ", ");
        try out.appendSlice(a, f.name);
    }
    return out.items;
}

/// `from`: the trait whose default body it is; null: the component's own method.
const Resolved = struct { f: *const ir.Fn, from: ?*const ir.Trait = null };

fn has(list: []const ir.TraitRef, r: ir.TraitRef) bool {
    for (list) |x| if (x.eql(r)) return true;
    return false;
}

/// The host kind of traits `cl` (`fighter`), from the first engine kind among them.
fn kindOf(cl: []const ir.TraitRef) []const u8 {
    for (cl) |r| if (r == .engine) if (engineTrait(r.engine)) |et| if (et.host) |h| return h;
    return "";
}

/// The parameter count of method `n` of traits `cl` (the program's or the engine's).
fn methodArity(cl: []const ir.TraitRef, n: []const u8) ?usize {
    for (cl) |r| if (r == .script) for (r.script.methods) |m| if (std.mem.eql(u8, m.f.name, n)) return m.f.params.len;
    return if (engineMethod(cl, n)) |ef| ef.arity() else null;
}

/// The engine trait of `cl` that has method `n`.
fn engineOwner(cl: []const ir.TraitRef, n: []const u8) ?[]const u8 {
    for (cl) |r| if (r == .engine) if (engineTrait(r.engine).?.own(n) != null) return r.engine;
    return null;
}

fn engineMethod(cl: []const ir.TraitRef, n: []const u8) ?*const traits.Method {
    for (cl) |r| if (r == .engine) for (engineTrait(r.engine).?.methods) |*ef| if (std.mem.eql(u8, ef.name, n)) return ef;
    return null;
}

fn plural(n: usize) []const u8 {
    return if (n == 1) "" else "s";
}

/// `b` is a misspelling of `a`: another name at most two edits away (`OnHitt`, `onHit`).
fn near(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b) or a.len > 31 or b.len > 31) return false;
    if (std.ascii.eqlIgnoreCase(a, b)) return true;
    var row: [32]usize = undefined;
    for (0..b.len + 1) |j| row[j] = j;
    for (a, 1..) |ca, i| {
        var diag_ = row[0];
        row[0] = i;
        for (b, 1..) |cb, j| {
            const up = row[j];
            row[j] = @min(@min(row[j] + 1, row[j - 1] + 1), diag_ + @intFromBool(ca != cb));
            diag_ = up;
        }
    }
    return row[b.len] <= 2;
}

// ---------------------------------------------------------------- engine traits

/// The engine's trait `name` (`script/traits.zig`).
fn engineTrait(name: []const u8) ?*const traits.Trait {
    return traits.find(name);
}

/// A schema field's type (core/schema.zig: `ItemPlace`, `list<Place>`): the engine's,
/// as `foundation::ItemPlace`, `list<foundation::Place>`.
fn engineType(a: Allocator, t: []const u8) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, t, "list<")) return std.fmt.allocPrint(a, "list<" ++ foundation ++ "::{s}", .{t[5..]});
    return key(a, foundation, t);
}

/// Type `t` as a message about data names it (`list<Place>`: data writes it bare).
fn shortType(a: Allocator, t: []const u8, data_: bool) Allocator.Error![]const u8 {
    return if (data_) std.mem.replaceOwned(u8, a, t, foundation ++ "::", "") else t;
}

/// `name` is the engine's (a trait, a struct, an enum of `foundation`): how code names
/// it, for a message about it bare ("": none of them).
fn foundationHint(p: *const Program, a: Allocator, name: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, name, "::") != null) return "";
    if (engineTrait(name) == null and !p.types.contains(try key(a, foundation, name))) return "";
    return std.fmt.allocPrint(a, " ({s} is foundation's: write " ++ foundation ++ "::{s}, or use " ++ foundation ++ ";)", .{ name, name });
}

/// The engine trait of host kind `word` (`fighter` → `Fighter`).
fn kindTrait(word: []const u8) ?*const traits.Trait {
    return traits.ofHost(word);
}

/// The host kind word of an engine trait ("" a role or a mark).
fn hostOf(t: *const traits.Trait) []const u8 {
    return t.host orelse "";
}

test "namespaces: module, use, qualified, root, builtin; errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const B = struct {
        fn builtin(_: *anyopaque, n: []const u8) ?Builtin {
            const eq = std.mem.eql;
            if (eq(u8, n, "Log")) return .{ .id = 7, .sig = "int(string text, ?int level, ?int more)" };
            if (eq(u8, n, "fighter::SetHp")) return .{ .id = 8, .sig = "int(string who, int hp)" };
            if (eq(u8, n, "events::Emit")) return .{ .id = 9 };
            // Classic names: OGS has them in a package, or not at all.
            if (eq(u8, n, "FighterSetHp")) return .{ .id = 8, .moved = "fighter::SetHp" };
            if (eq(u8, n, "GetName")) return .{ .id = 10, .moved = "" };
            return null;
        }
    };
    var dummy: u8 = 0;
    const env: Env = .{ .ctx = &dummy, .builtin = B.builtin };
    var pdiag: parser.Diagnostic = .{};
    var diag: Diagnostic = .{};
    var p: Program = .{};
    // Two texts: names come from the code, not the files.
    try p.add(a, try parser.parse(a, "module lib::math { fn twice(x) { return x * 2; } fn id(x) { return x; } }  fn root() { return 1; }", "one.ogs", &pdiag), &diag);
    try p.add(a, try parser.parse(a,
        \\module game {
        \\    use lib::math;
        \\    fn id(x) { return 0; }
        \\    fn f() { return twice(1) + id(2) + lib::math::id(3) + root() + Log("x"); }
        \\    component C { fn twice(x) { return 3; } fn g() { return twice(1); } }
        \\}
    , "two.ogs", &pdiag), &diag);
    try p.link(a, env, &diag);
    const game = p.fns.get("game::f").?;
    const sum = game.body[0].kind.@"return";
    const calls = [_]*const ir.Expr{ sum.kind.binary.lhs.kind.binary.lhs.kind.binary.lhs.kind.binary.lhs, sum.kind.binary.lhs.kind.binary.lhs.kind.binary.lhs.kind.binary.rhs, sum.kind.binary.lhs.kind.binary.lhs.kind.binary.rhs, sum.kind.binary.lhs.kind.binary.rhs, sum.kind.binary.rhs };
    try std.testing.expectEqual(p.fns.get("lib::math::twice").?, calls[0].kind.call.target.?.func);
    // Its own namespace before a used one.
    try std.testing.expectEqual(p.fns.get("game::id").?, calls[1].kind.call.target.?.func);
    try std.testing.expectEqual(p.fns.get("lib::math::id").?, calls[2].kind.call.target.?.func);
    try std.testing.expectEqual(p.fns.get("root").?, calls[3].kind.call.target.?.func);
    try std.testing.expectEqual(7, calls[4].kind.call.target.?.builtin.id);
    // A component's own method first.
    const c = p.components.get("game::C").?;
    try std.testing.expectEqual(c.methods[0], c.methods[1].body[0].kind.@"return".kind.call.target.?.func);
    try std.testing.expectEqual(c, (try p.component(a, &p.modules.items[3], "C")).?);
    try std.testing.expect(p.namespaces.contains("lib"));

    // Builtins by package path or `use`; a root function may take a builtin's name.
    try p.add(a, try parser.parse(a,
        \\module pk {
        \\    use fighter;
        \\    fn f() { return fighter::SetHp("a", 1) + SetHp("b", 2) + Emit(); }
        \\}
        \\fn Emit() { return 0; }
        \\fn g() { return Emit(); }
    , "three.ogs", &pdiag), &diag);
    try p.link(a, env, &diag);
    const pk = p.fns.get("pk::f").?.body[0].kind.@"return".kind.binary;
    try std.testing.expectEqual(8, pk.lhs.kind.binary.lhs.kind.call.target.?.builtin.id);
    try std.testing.expectEqual(8, pk.lhs.kind.binary.rhs.kind.call.target.?.builtin.id);
    try std.testing.expectEqual(p.fns.get("Emit").?, pk.rhs.kind.call.target.?.func);
    try std.testing.expectEqual(p.fns.get("Emit").?, p.fns.get("g").?.body[0].kind.@"return".kind.call.target.?.func);

    const bad = [_]struct { []const u8, []const u8 }{
        .{ "fn h() { return nope(1); }", "unknown function nope" },
        .{ "fn h() { return FighterSetHp(\"a\", 1); }", "unknown function FighterSetHp (did you mean fighter::SetHp)" },
        .{ "fn h() { return GetName(); }", "unknown function GetName" },
        .{ "fn h() { return fighter::Nope(); }", "unknown function fighter::Nope" },
        .{ "module fighter { fn q() { return 1; } }", "fighter: reserved package" },
        .{ "module classic::x { fn q() { return 1; } }", "classic: reserved package" },
        .{ "fn h() { return Log(x: 1); }", "builtin Log has no parameter x" },
        .{ "fn h() { return Log(more: 1); }", "Log: the arguments before a named one are needed" },
        .{ "fn h() { return Log(\"a\", text: 1); }", "Log: text given twice" },
        .{ "fn k(a, b = 2) { return a + b; } fn h() { return k(b: 1); }", "k: no value for a" },
        .{ "fn k2(a) { return a; } fn h() { return k2(1, a: 2); }", "k2: a given twice" },
        .{ "fn k3(a) { return a; } fn h() { return k3(a: 1, a: 2); }", "k3: a given twice" },
        .{ "module x { use nowhere; fn h() { return 1; } }", "use nowhere: no such namespace" },
        .{ "fn root() { return 2; }", "root is defined twice" },
        .{ "module m1 { fn q() { return 1; } } module m2 { fn q() { return 2; } } module m3 { use m1; use m2; fn h() { return q(); } }", "q is in more than one used namespace" },
    };
    // A sigil: a block of the program declares the name, else the host knows it.
    const H = struct {
        fn exists(_: *anyopaque, kind: ir.Sigil, n: []const u8) ?bool {
            return if (kind == .level) std.mem.eql(u8, n, "01_port") else null;
        }
    };
    const host_env: Env = .{ .ctx = &dummy, .builtin = B.builtin, .exists = H.exists };
    var s: Program = .{};
    try s.add(a, try parser.parse(a, "battle \"01__port_citadel\" { } fn h() { return [~l\"01_port\", ~l\"01__port_citadel\", ~s\"any\"]; }", "s", &pdiag), &diag);
    try s.link(a, host_env, &diag);
    try s.add(a, try parser.parse(a, "fn k() {\n return ~l\"nowhere\"; }", "t", &pdiag), &diag);
    try std.testing.expectError(error.LinkError, s.link(a, host_env, &diag));
    try std.testing.expectEqualStrings("no level nowhere", diag.message);
    try std.testing.expectEqual(2, diag.line);
    // The text that failed is gone; the rest links.
    try s.link(a, host_env, &diag);
    try std.testing.expect(s.fns.get("k") == null);

    for (bad) |b| {
        var q: Program = .{};
        try q.add(a, try parser.parse(a, "fn root() { return 1; }", "r", &pdiag), &diag);
        const r = q.add(a, try parser.parse(a, b[0], "b", &pdiag), &diag);
        if (r) |_| try std.testing.expectError(error.LinkError, q.link(a, env, &diag)) else |err| try std.testing.expectEqual(error.LinkError, err);
        try std.testing.expectEqualStrings(b[1], diag.message);
    }
}

test "import: the one block at its path, of several the one its kind names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dummy: u8 = 0;
    const env: Env = .{ .ctx = &dummy, .builtin = struct {
        fn f(_: *anyopaque, _: []const u8) ?Builtin {
            return null;
        }
    }.f };
    const Case = struct { []const u8, ?[]const u8 };
    for ([_]Case{
        .{ "module characters { fighter medusa { } hero medusa { import characters::medusa<fighter>; } }", null },
        .{ "module characters { fighter c_nato { } hero kozov { import characters::c_nato; } }", null },
        .{ "module characters { fighter medusa { } hero medusa { } hero x { import characters::medusa; } }", "import characters::medusa: a fighter and a hero have this path, name one: import characters::medusa<fighter>;" },
        .{ "module characters { fighter medusa { } hero x { import characters::medusa<hero>; } }", "import characters::medusa<hero>: no hero there" },
        .{ "module characters { hero x { import characters::nobody; } }", "import characters::nobody: no block there" },
    }) |c| {
        var pdiag: parser.Diagnostic = .{};
        var diag: Diagnostic = .{};
        var p: Program = .{};
        try p.add(a, try parser.parse(a, c[0], "c.ogs", &pdiag), &diag);
        if (c[1]) |want| {
            try std.testing.expectError(error.LinkError, p.link(a, env, &diag));
            try std.testing.expectEqualStrings(want, diag.message);
        } else try p.link(a, env, &diag);
    }
}

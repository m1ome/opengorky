//! gorky-tool `scripts`: parse every script and list builtin calls
//! (`--api` prints the called functions).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const common_mod = @import("common.zig");
const archive = og.formats.archive;

/// Parses every script from every game archive, checks that `#include` and `#inherit`
/// resolve, and collects calls to functions not defined in scripts
/// (engine builtins).
pub fn checkScripts(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8, print_api: bool) !void {
    var dat = try common_mod.openDat(io, game_dir, .{ .iterate = true });
    defer dat.close(io);
    const archives = try og.formats.archive.listArchives(io, gpa, dat);
    defer og.formats.archive.freeList(gpa, archives);
    var common = try archive.Archive.open(io, gpa, dat, "common/other.dat");
    defer common.close(io, gpa);

    // All names, strings and trees live until the command ends.
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Call = struct { count: usize = 0, min_args: usize = std.math.maxInt(usize), max_args: usize = 0 };
    var calls: std.StringArrayHashMapUnmanaged(Call) = .empty;
    var defined: std.StringHashMapUnmanaged(void) = .empty;

    var files: usize = 0;
    var failed: usize = 0;
    var functions: usize = 0;
    var unresolved: usize = 0;
    for (archives) |path| {
        var arc = try archive.Archive.open(io, gpa, dat, path);
        defer arc.close(io, gpa);
        for (arc.entries) |*e| {
            if (!og.formats.resource.isScript(e.name)) continue;
            files += 1;
            const src = try arc.readAlloc(io, arena, e);
            var diag: og.script.parser.Diagnostic = .{};
            const unit = og.script.parser.parse(arena, src, &diag) catch |err| {
                failed += 1;
                try out.print("{s}: {s}:{d}: {s} ({t})\n", .{ path, e.name, diag.line, diag.message, err });
                continue;
            };
            var refs: std.ArrayList([]const u8) = .empty;
            for (unit.items) |it| switch (it) {
                .function => |f| {
                    functions += 1;
                    try defined.put(arena, try std.ascii.allocLowerString(arena, f.name), {});
                    for (f.body) |*st| try collectStmt(arena, st, &calls, &refs);
                },
                .stmt => |*st| try collectStmt(arena, st, &calls, &refs),
                .include => |name| try refs.append(arena, name),
                // `#inherit Level` → `level.s`; `#inherit Fighter.s` also occurs.
                .inherit => |name| try refs.append(arena, if (std.fs.path.extension(name).len > 0)
                    name
                else
                    try std.fmt.allocPrint(arena, "{s}.s", .{name})),
                .var_decl => {},
            };
            for (refs.items) |name| {
                if (resolveScript(arc, common, name) == null) {
                    unresolved += 1;
                    try out.print("{s}: {s}: cannot resolve '{s}'\n", .{ path, e.name, name });
                }
            }
        }
    }

    if (print_api) {
        const Sort = struct {
            map: *std.StringArrayHashMapUnmanaged(Call),
            pub fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                return std.ascii.lessThanIgnoreCase(ctx.map.keys()[a], ctx.map.keys()[b]);
            }
        };
        calls.sort(Sort{ .map = &calls });
        var builtins: usize = 0;
        for (calls.keys(), calls.values()) |name, c| {
            if (defined.contains(try std.ascii.allocLowerString(arena, name))) continue;
            builtins += 1;
            if (c.min_args == c.max_args)
                try out.print("{s:<36} args {d:<5} calls {d}\n", .{ name, c.min_args, c.count })
            else
                try out.print("{s:<36} args {d}-{d:<3} calls {d}\n", .{ name, c.min_args, c.max_args, c.count });
        }
        try out.print("builtin functions: {d}\n", .{builtins});
    }
    try out.print("scripts {d}, failed {d}, functions {d}, unresolved includes {d}\n", .{ files, failed, functions, unresolved });
}

/// Finds an included script: first in the level archive, then in `common/other.dat: classes\`.
fn resolveScript(local: archive.Archive, common: archive.Archive, name: []const u8) ?*const archive.Entry {
    if (local.find(name)) |e| return e;
    var buf: [archive.name_size]u8 = undefined;
    const in_classes = std.fmt.bufPrint(&buf, "classes\\{s}", .{name}) catch return null;
    return common.find(in_classes);
}

fn collectStmt(
    arena: Allocator,
    st: *const og.script.ast.Stmt,
    calls: anytype,
    refs: *std.ArrayList([]const u8),
) !void {
    switch (st.*) {
        .expr => |e| try collectExpr(arena, e, calls),
        .include => |name| try refs.append(arena, name),
        .block => |stmts| for (stmts) |*s| try collectStmt(arena, s, calls, refs),
        .@"if" => |i| {
            try collectExpr(arena, i.cond, calls);
            try collectStmt(arena, i.then, calls, refs);
            if (i.@"else") |e| try collectStmt(arena, e, calls, refs);
        },
        .@"return" => |v| if (v) |e| try collectExpr(arena, e, calls),
        .var_decl, .empty => {},
    }
}

fn collectExpr(arena: Allocator, e: *const og.script.ast.Expr, calls: anytype) !void {
    switch (e.kind) {
        .call => |c| {
            // Case-insensitive key, like `defined` (the exe calls are case-insensitive).
            const gop = try calls.getOrPut(arena, og.script.object.nameOf(c.id));
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.count += 1;
            gop.value_ptr.min_args = @min(gop.value_ptr.min_args, c.args.len);
            gop.value_ptr.max_args = @max(gop.value_ptr.max_args, c.args.len);
            for (c.args) |a| try collectExpr(arena, a, calls);
        },
        .unary => |u| try collectExpr(arena, u.operand, calls),
        .binary => |b| {
            try collectExpr(arena, b.lhs, calls);
            try collectExpr(arena, b.rhs, calls);
        },
        .assign => |a| try collectExpr(arena, a.value, calls),
        .int, .float, .string, .ident => {},
    }
}

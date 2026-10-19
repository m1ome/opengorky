//! Script language parser (recursive descent).
//!
//! Exe grammar we don't support (unused in game scripts): field access `a.b`
//! (0x44b6d0, call 0x44b790, assign 0x4e3db0; here `a.b` is one name),
//! `while`/`for … to`/`do`/`local`/`null` (strings 0x5263b8…), a "builtin only"
//! call (node flag +0x14, 0x4e3bc6), per-function rather than per-call parameters
//! (0x44ad24: recursion in the exe overwrites the caller's parameters). The exe
//! has no `%` operator (0x4c5160…0x4c53e9); here it is a parse error.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const object = @import("object.zig");
const Token = lexer.Token;
const Tag = lexer.Tag;

pub const Error = lexer.Error || Allocator.Error || error{ParseError};

pub const Diagnostic = struct {
    line: u32 = 0,
    message: []const u8 = "",
};

/// Parses a whole file. Nodes are allocated in `arena`; on error `diag` holds the
/// line and description.
pub fn parse(arena: Allocator, src: []const u8, diag: *Diagnostic) Error!ast.Unit {
    var p: Parser = .{ .arena = arena, .lx = .init(src), .diag = diag };
    try p.advance();
    var items: std.ArrayList(ast.Item) = .empty;
    while (p.tok.tag != .eof) try items.append(arena, try p.item());
    return .{ .items = items.items };
}

const Parser = struct {
    arena: Allocator,
    lx: lexer.Lexer,
    diag: *Diagnostic,
    tok: Token = undefined,

    fn advance(self: *Parser) Error!void {
        self.tok = self.lx.next() catch |err| {
            self.diag.* = .{ .line = self.lx.err_line, .message = @errorName(err) };
            return err;
        };
    }

    fn fail(self: *Parser, message: []const u8) Error {
        self.diag.* = .{ .line = self.tok.line, .message = message };
        return error.ParseError;
    }

    fn expect(self: *Parser, tag: Tag, message: []const u8) Error!Token {
        if (self.tok.tag != tag) return self.fail(message);
        const t = self.tok;
        try self.advance();
        return t;
    }

    fn eat(self: *Parser, tag: Tag) Error!bool {
        if (self.tok.tag != tag) return false;
        try self.advance();
        return true;
    }

    fn isWord(self: *Parser, word: []const u8) bool {
        return self.tok.tag == .identifier and std.mem.eql(u8, self.tok.text, word);
    }

    fn typeKeyword(self: *Parser) ?ast.Type {
        if (self.tok.tag != .identifier) return null;
        return std.meta.stringToEnum(ast.Type, self.tok.text);
    }

    // ---------------------------------------------------------------- top level

    fn item(self: *Parser) Error!ast.Item {
        switch (self.tok.tag) {
            .directive_inherit => {
                const name = self.tok.arg();
                try self.advance();
                return .{ .inherit = name };
            },
            .directive_include => {
                const name = self.tok.arg();
                try self.advance();
                return .{ .include = name };
            },
            else => {},
        }
        if (self.isWord("function")) return .{ .function = try self.function() };
        if (self.typeKeyword() != null) return .{ .var_decl = try self.varDecl() };
        return .{ .stmt = try self.stmt() };
    }

    fn function(self: *Parser) Error!ast.Function {
        const line = self.tok.line;
        try self.advance(); // function
        const name = (try self.expect(.identifier, "expected function name")).text;
        _ = try self.expect(.l_paren, "expected '(' after function name");
        var params: std.ArrayList(ast.Param) = .empty;
        if (self.tok.tag != .r_paren) while (true) {
            const t = self.typeKeyword() orelse return self.fail("expected parameter type");
            try self.advance();
            const pname = (try self.expect(.identifier, "expected parameter name")).text;
            try params.append(self.arena, .{ .type = t, .name = pname, .id = try object.intern(pname) });
            if (!try self.eat(.comma)) break;
        };
        _ = try self.expect(.r_paren, "expected ')' after parameters");
        const body = try self.block();
        _ = try self.eat(.semicolon);
        return .{ .name = name, .params = params.items, .body = body, .line = line };
    }

    fn varDecl(self: *Parser) Error!ast.VarDecl {
        const line = self.tok.line;
        const t = self.typeKeyword().?;
        try self.advance();
        const name = (try self.expect(.identifier, "expected variable name")).text;
        _ = try self.expect(.semicolon, "expected ';' after variable declaration");
        return .{ .type = t, .name = name, .line = line, .id = try object.intern(name) };
    }

    // ---------------------------------------------------------------- statements

    fn block(self: *Parser) Error![]const ast.Stmt {
        _ = try self.expect(.l_brace, "expected '{'");
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        while (self.tok.tag != .r_brace) {
            if (self.tok.tag == .eof) return self.fail("unexpected end of file, expected '}'");
            try stmts.append(self.arena, try self.stmt());
        }
        try self.advance();
        return stmts.items;
    }

    fn stmt(self: *Parser) Error!ast.Stmt {
        switch (self.tok.tag) {
            .semicolon => {
                try self.advance();
                return .empty;
            },
            .l_brace => {
                const stmts = try self.block();
                // In this language `;` usually follows `}`.
                _ = try self.eat(.semicolon);
                return .{ .block = stmts };
            },
            .directive_include => {
                const name = self.tok.arg();
                try self.advance();
                return .{ .include = name };
            },
            else => {},
        }
        if (self.typeKeyword() != null) return .{ .var_decl = try self.varDecl() };
        if (self.isWord("if")) return self.ifStmt();
        if (self.isWord("return")) {
            try self.advance();
            if (try self.eat(.semicolon)) return .{ .@"return" = null };
            const value = try self.expr();
            _ = try self.expect(.semicolon, "expected ';' after return");
            return .{ .@"return" = value };
        }
        const e = try self.expr();
        _ = try self.expect(.semicolon, "expected ';' after expression");
        return .{ .expr = e };
    }

    /// `if (cond) stmt [;] [else stmt]`. Typical form: `if(a) {…}; else {…};`.
    fn ifStmt(self: *Parser) Error!ast.Stmt {
        try self.advance(); // if
        _ = try self.expect(.l_paren, "expected '(' after if");
        const cond = try self.expr();
        _ = try self.expect(.r_paren, "expected ')' after if condition");
        const then = try self.alloc(ast.Stmt, try self.stmt());
        // The `;` after a block was already eaten in stmt(); else may follow it.
        var else_branch: ?*const ast.Stmt = null;
        if (self.isWord("else")) {
            try self.advance();
            else_branch = try self.alloc(ast.Stmt, try self.stmt());
        }
        return .{ .@"if" = .{ .cond = cond, .then = then, .@"else" = else_branch } };
    }

    // ---------------------------------------------------------------- expressions

    fn expr(self: *Parser) Error!*const ast.Expr {
        // Assignment: name = expression (right-associative).
        if (self.tok.tag == .identifier) {
            const save_lx = self.lx;
            const save_tok = self.tok;
            try self.advance();
            if (self.tok.tag == .equal) {
                try self.advance();
                const value = try self.expr();
                return self.node(save_tok.line, .{ .assign = .{ .name = save_tok.text, .id = try object.intern(save_tok.text), .value = value } });
            }
            self.lx = save_lx;
            self.tok = save_tok;
        }
        return self.binary(0);
    }

    const Level = struct { tags: []const Tag, ops: []const ast.BinaryOp };
    const levels = [_]Level{
        // && and || share one level, left to right (exe grammar).
        .{ .tags = &.{ .pipe_pipe, .amp_amp }, .ops = &.{ .@"or", .@"and" } },
        .{ .tags = &.{ .equal_equal, .bang_equal }, .ops = &.{ .eq, .ne } },
        .{ .tags = &.{ .less, .less_equal, .greater, .greater_equal }, .ops = &.{ .lt, .le, .gt, .ge } },
        .{ .tags = &.{ .plus, .minus }, .ops = &.{ .add, .sub } },
        .{ .tags = &.{ .star, .slash }, .ops = &.{ .mul, .div } },
    };

    fn binary(self: *Parser, level: usize) Error!*const ast.Expr {
        if (level == levels.len) return self.unary();
        var lhs = try self.binary(level + 1);
        loop: while (true) {
            for (levels[level].tags, levels[level].ops) |tag, op| {
                if (self.tok.tag == tag) {
                    const line = self.tok.line;
                    try self.advance();
                    const rhs = try self.binary(level + 1);
                    lhs = try self.node(line, .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } });
                    continue :loop;
                }
            }
            return lhs;
        }
    }

    fn unary(self: *Parser) Error!*const ast.Expr {
        const line = self.tok.line;
        if (try self.eat(.minus)) return self.node(line, .{ .unary = .{ .op = .neg, .operand = try self.unary() } });
        if (try self.eat(.bang)) return self.node(line, .{ .unary = .{ .op = .not, .operand = try self.unary() } });
        if (try self.eat(.plus)) return self.unary();
        return self.primary();
    }

    fn primary(self: *Parser) Error!*const ast.Expr {
        const t = self.tok;
        switch (t.tag) {
            .int_literal => {
                try self.advance();
                const v = std.fmt.parseInt(i32, t.text, 10) catch return self.fail("integer literal out of range");
                return self.node(t.line, .{ .int = v });
            },
            .float_literal => {
                try self.advance();
                const v = std.fmt.parseFloat(f32, t.text) catch return self.fail("bad float literal");
                return self.node(t.line, .{ .float = v });
            },
            .string_literal => {
                try self.advance();
                return self.node(t.line, .{ .string = t.stringValue() });
            },
            .l_paren => {
                try self.advance();
                const e = try self.expr();
                _ = try self.expect(.r_paren, "expected ')'");
                return e;
            },
            .identifier => {
                try self.advance();
                if (!try self.eat(.l_paren)) return self.node(t.line, .{ .ident = .{ .name = t.text, .id = try object.intern(t.text) } });
                var args: std.ArrayList(*const ast.Expr) = .empty;
                if (self.tok.tag != .r_paren) while (true) {
                    try args.append(self.arena, try self.expr());
                    if (!try self.eat(.comma)) break;
                };
                _ = try self.expect(.r_paren, "expected ')' after arguments");
                return self.node(t.line, .{ .call = .{ .name = t.text, .args = args.items, .id = try object.intern(t.text) } });
            },
            else => return self.fail("expected expression"),
        }
    }

    fn node(self: *Parser, line: u32, kind: ast.Expr.Kind) Error!*const ast.Expr {
        return self.alloc(ast.Expr, .{ .line = line, .kind = kind });
    }

    fn alloc(self: *Parser, comptime T: type, value: T) Allocator.Error!*const T {
        const p = try self.arena.create(T);
        p.* = value;
        return p;
    }
};

// ---------------------------------------------------------------- tests

fn parseTest(src: []const u8) !struct { std.heap.ArenaAllocator, ast.Unit } {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    errdefer arena.deinit();
    var diag: Diagnostic = .{};
    const unit = parse(arena.allocator(), src, &diag) catch |err| {
        std.debug.print("line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    return .{ arena, unit };
}

test "typical object script" {
    var arena, const unit = try parseTest(
        \\#inherit ActiveBitmapAnimation
        \\
        \\int ret;
        \\function init()
        \\{
        \\    spriteFile="gate1";
        \\    speed=15;
        \\};
        \\function allowRender()
        \\{
        \\    if(state==0) return(0);
        \\    else return(1);
        \\};
    );
    defer arena.deinit();
    try std.testing.expectEqual(4, unit.items.len);
    try std.testing.expectEqualStrings("ActiveBitmapAnimation", unit.items[0].inherit);
    try std.testing.expectEqual(ast.Type.int, unit.items[1].var_decl.type);
    const f = unit.items[3].function;
    try std.testing.expectEqualStrings("allowRender", f.name);
    const if_stmt = f.body[0].@"if";
    try std.testing.expectEqual(ast.BinaryOp.eq, if_stmt.cond.kind.binary.op);
    try std.testing.expect(if_stmt.@"else" != null);
}

test "else after block with semicolon, nested if without braces" {
    var arena, const unit = try parseTest(
        \\function f(string hero, int n)
        \\{
        \\  if(turnNo >= 4)
        \\  if(a == 0 && !b)
        \\  {
        \\     x = -1;
        \\  };
        \\  else
        \\  if(AIFreeTile(6,10))
        \\  {
        \\     PlaceActor("Sullivan",6,12,0);
        \\  };
        \\#include wp_barrel_explode.ss
        \\};
    );
    defer arena.deinit();
    const f = unit.items[0].function;
    try std.testing.expectEqual(2, f.params.len);
    const outer = f.body[0].@"if";
    try std.testing.expect(outer.@"else" == null);
    // else binds to the nearest if.
    try std.testing.expect(outer.then.@"if".@"else" != null);
    try std.testing.expectEqualStrings("wp_barrel_explode.ss", f.body[1].include);
}

test "operator precedence" {
    var arena, const unit = try parseTest("x = 1 + 2 * 3 == 7 || y;");
    defer arena.deinit();
    const assign = unit.items[0].stmt.expr.kind.assign;
    try std.testing.expectEqualStrings("x", assign.name);
    const or_expr = assign.value.kind.binary;
    try std.testing.expectEqual(ast.BinaryOp.@"or", or_expr.op);
    const eq = or_expr.lhs.kind.binary;
    try std.testing.expectEqual(ast.BinaryOp.eq, eq.op);
    try std.testing.expectEqual(ast.BinaryOp.add, eq.lhs.kind.binary.op);
    try std.testing.expectEqual(ast.BinaryOp.mul, eq.lhs.kind.binary.rhs.kind.binary.op);
}

test "error reports line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.ParseError, parse(arena.allocator(), "function f()\n{\n  x = ;\n};", &diag));
    try std.testing.expectEqual(3, diag.line);
}

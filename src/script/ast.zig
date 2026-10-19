//! Script parse tree. Nodes and strings live in the parser arena and point into
//! the source text, which must outlive the tree.

pub const Type = enum { int, float, string, object };

pub const VarDecl = struct {
    type: Type,
    name: []const u8,
    line: u32,
    /// Interned name id (`object.intern`); null when built outside the parser.
    id: ?u32 = null,
};

pub const Param = struct {
    type: Type,
    name: []const u8,
    id: u32,
};

pub const Function = struct {
    name: []const u8,
    params: []const Param,
    body: []const Stmt,
    line: u32,
};

/// File top level. `.ss` snippets may also contain plain statements.
pub const Item = union(enum) {
    inherit: []const u8,
    include: []const u8,
    var_decl: VarDecl,
    function: Function,
    stmt: Stmt,
};

pub const Unit = struct {
    items: []const Item,
};

pub const Stmt = union(enum) {
    expr: *const Expr,
    var_decl: VarDecl,
    /// `#include` inside a function body: the file's text is substituted here.
    include: []const u8,
    block: []const Stmt,
    @"if": If,
    @"return": ?*const Expr,
    empty,

    const If = struct {
        cond: *const Expr,
        then: *const Stmt,
        @"else": ?*const Stmt,
    };
};

pub const BinaryOp = enum { add, sub, mul, div, eq, ne, lt, le, gt, ge, @"and", @"or" };
const UnaryOp = enum { neg, not };

pub const Expr = struct {
    line: u32,
    kind: Kind,

    pub const Kind = union(enum) {
        int: i32,
        float: f32,
        string: []const u8,
        ident: Ident,
        call: Call,
        unary: Unary,
        binary: Binary,
        assign: Assign,
    };

    /// `id` is the interned name (`object.intern`), resolved at parse time.
    pub const Call = struct { name: []const u8, args: []const *const Expr, id: u32 };
    const Unary = struct { op: UnaryOp, operand: *const Expr };
    const Binary = struct { op: BinaryOp, lhs: *const Expr, rhs: *const Expr };
    /// `id` is the interned name (`object.intern`), resolved at parse time.
    const Ident = struct { name: []const u8, id: u32 };
    const Assign = struct { name: []const u8, id: u32, value: *const Expr };
};

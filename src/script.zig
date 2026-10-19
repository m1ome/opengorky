//! Entry point of `script/` for other engine folders. Script language core: values, objects, runtime.
//! Files not exported here are internal to the folder.

pub const ast = @import("script/ast.zig");
pub const object = @import("script/object.zig");
pub const parser = @import("script/parser.zig");
pub const runtime = @import("script/runtime.zig");
pub const value = @import("script/value.zig");

test {
    _ = @import("script/lexer.zig");
    _ = parser;
    _ = runtime;
    _ = value;
}

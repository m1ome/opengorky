//! Entry point of `core/`: the world model's entities and the behaviour modules. The
//! core reads no files: the composition layer (src/compose.zig) fills it from the
//! parsers (src/formats) and the OpenGorky layer.

pub const entity = @import("core/entity.zig");
pub const modules = @import("core/modules.zig");
pub const scene = @import("core/scene.zig");
pub const map = @import("core/map.zig");
pub const source = @import("core/source.zig");
pub const model = @import("core/model.zig");
pub const effect = @import("core/effect.zig");
pub const ui_text = @import("core/ui_text.zig");
pub const behaviour = @import("core/behaviour.zig");
/// The native abilities as built-in components.
pub const natives = @import("core/natives.zig");
/// The original's fighters as ability rows (the hand-written part of the Classic load).
pub const classic = @import("core/classic.zig");
pub const ui = @import("core/ui.zig");
/// Host schemas: the fields of each kind of object, from the original's base classes.
pub const schema = @import("core/schema.zig");

test {
    _ = entity;
    _ = modules;
    _ = scene;
    _ = map;
    _ = source;
    _ = model;
    _ = effect;
    _ = behaviour;
    _ = natives;
    _ = classic;
    _ = ui;
    _ = schema;
    _ = ui_text;
}

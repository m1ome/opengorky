//! Materials: a mod's named look of an effect part over its life (core/effect.zig
//! names them on parts; the rules' `Material` rows, core/modules.zig, are in force).

const Track = @import("beam.zig").Track;

/// A material (a mod's; a part's `material` names it, OpenGorky only): over the part's
/// life its colour, alpha and strength `k` as tracks stepped by its age, a blend, and a
/// CPU program of the software layer (battle billboards, the editor's preview):
/// `dissolve` drops the pixels whose noise is below k, `heat` ripples the texture (k its
/// phase), `tint` greys the texture by k so the colour tints it. On the screen pass (off
/// the battle layer) only colour, alpha and blend; a dissolve fades by k there.
pub const Material = struct {
    pub const call = "Material";
    pub const file = "fx";
    pub const keys = .{"name"};
    pub const doc =
        \\A material a part names (material = "name" on an emitter, ribbon look, beam, mesh,
        \\bitmap or cloud): rgb (three tracks), alpha and k (tracks stepped by the part's age),
        \\blend (add, alpha, screen), program: none, dissolve (pixels drop out below k), heat
        \\(the texture ripples, k its phase), tint (the texture greyed by k, so rgb colours it).
        \\CPU only: the battle layer and the editor's preview.
    ;
    name: []const u8,
    program: Program = .none,
    blend: ?Blend = null,
    rgb: [3]Track = @splat(.{ .v = 1 }),
    alpha: Track = .{ .v = 1 },
    k: Track = .{},
};
pub const Blend = enum { add, alpha, screen };

/// A CPU program of the software layer: `dissolve` drops pixels whose noise is below k,
/// `heat` ripples the texture by phase k, `tint` greys the texel by k.
pub const Program = enum { none, dissolve, heat, tint };

/// The frame's post-processing (a project's, OpenGorky only: none in Classic): built-in
/// programs over the drawn world, in order (render/post.zig, the viewer's shader: GPU
/// renderer only); a level's own row,
/// else (a battle) its location's, else the global one (level ""): core/modules.zig postSteps.
pub const PostChain = struct {
    pub const call = "PostChain";
    pub const file = "fx";
    pub const keys = .{"level"};
    pub const doc =
        \\The frame's post-processing: steps over the drawn world (before the interface), in
        \\order, each Post(program, k, rgb): grade (colour ×rgb, saturation ×k), vignette (the
        \\edges darkened by k), scanlines (every other screen line darkened by k), hsl (hue
        \\turned by (r − 1)·180°, saturation ×g, lightness ×b, mixed in by k). Only with the
        \\GPU renderer (`renderer = gpu`): with the CPU one the chain is ignored.
        \\  level: the level (dat folder, "01_port") this chain is for; "" (left out): every
        \\  level without its own. A battle level is a level of its own ("01__port_park"); one
        \\  without its own row takes its location's (the level whose scripts start it:
        \\  01_port for "01__port_barge"), else the global one.
    ;
    level: []const u8 = "",
    steps: []const Post = &.{},
};

/// One post-processing step: a built-in program, its strength and colour.
pub const Post = struct {
    program: PostProgram,
    k: f32 = 1,
    rgb: [3]f32 = .{ 1, 1, 1 },
};
const PostProgram = enum { grade, vignette, scanlines, hsl };

/// The materials in force by name (core/modules.zig sets it with the rules' tables).
pub var lookup: *const fn ([]const u8) ?*const Material = none;

fn none(_: []const u8) ?*const Material {
    return null;
}

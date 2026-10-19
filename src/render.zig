//! Software renderer for 3D actors (viewer and gorky-tool only; game logic does not use it).

pub const layer = @import("render/layer.zig");
pub const raster = @import("render/raster.zig");
pub const depth_fit = @import("render/depth_fit.zig");

test {
    _ = layer;
    _ = raster;
    _ = depth_fit;
}

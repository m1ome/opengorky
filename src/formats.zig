//! Entry point of `formats/` for other engine folders. Game file formats.
//! Files not exported here are internal to the folder.

pub const adjust = @import("formats/adjust.zig");
pub const anim = @import("formats/anim.zig");
pub const archive = @import("formats/archive.zig");
pub const background = @import("formats/background.zig");
pub const dialog = @import("formats/dialog.zig");
pub const font = @import("formats/font.zig");
pub const image = @import("formats/image.zig");
pub const jpeg = @import("formats/jpeg.zig");
pub const lang = @import("formats/lang.zig");
pub const level = @import("formats/level.zig");
pub const level_files = @import("formats/level_files.zig");
pub const mesh = @import("formats/mesh.zig");
pub const png = @import("formats/png.zig");
pub const resource = @import("formats/resource.zig");
pub const scriptlet = @import("formats/scriptlet.zig");
pub const sprite = @import("formats/sprite.zig");
pub const strtab = @import("formats/strtab.zig");
pub const tex3df = @import("formats/tex3df.zig");
pub const vars = @import("formats/vars.zig");
pub const xbr = @import("formats/xbr.zig");
pub const zbuffer = @import("formats/zbuffer.zig");

test {
    _ = resource;
    _ = adjust;
    _ = anim;
    _ = archive;
    _ = background;
    _ = font;
    _ = level_files;
    _ = mesh;
    _ = png;
    _ = scriptlet;
    _ = sprite;
    _ = tex3df;
    _ = xbr;
    _ = zbuffer;
}

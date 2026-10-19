//! Entry point of `audio/`: decoding, mixer, sounds, location sound logic (no device).
//! Files not exported here are internal to the folder.

pub const decode = @import("audio/decode.zig");
pub const mixer = @import("audio/mixer.zig");
pub const scene = @import("audio/scene.zig");
pub const sound = @import("audio/sound.zig");

test {
    _ = decode;
    _ = mixer;
}

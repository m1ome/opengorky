//! Save/load slot screen: name entry, thumbnails, newest slot. Menu methods (see viewer/menu.zig).

const std = @import("std");
const menu_mod = @import("../menu.zig");
const Menu = menu_mod.Menu;
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("../media/gfx.zig");

pub fn setThumb(self: *Menu, i: usize, img: ?og.formats.image.Image) void {
    if (self.thumbs[i]) |t| c.SDL_DestroyTexture(t);
    self.thumbs[i] = if (img) |x| gfx.textureFromImage(self.renderer, x) catch null else null;
}

pub fn setSlot(self: *Menu, i: usize, text: ?[]const u8) void {
    if (self.slots[i]) |b| self.gpa.free(b);
    self.slots[i] = if (text) |l| self.gpa.dupe(u8, l) catch null else null;
}

/// Name entry (0x415564): a char passing 0x412a00 — space, digit, Latin letter
/// (case kept) or a sign with a glyph in the menu font; length below 15.
pub fn typeChar(self: *Menu, ch: u8) bool {
    if (self.editing == null or self.edit_len >= self.edit_buf.len) return false;
    if (!nameChar(self, ch)) return false;
    self.edit_buf[self.edit_len] = ch;
    self.edit_len += 1;
    return true;
}

fn nameChar(self: *const Menu, ch: u8) bool {
    if (ch == ' ' or std.ascii.isAlphanumeric(ch)) return true;
    if (ch == 0) return false;
    const g = self.font.glyphs[ch] orelse return false;
    return g.w > 0;
}

pub fn backspace(self: *Menu) void {
    if (self.editing != null) self.edit_len -|= 1;
}

pub fn editName(self: *Menu) []const u8 {
    return self.edit_buf[0..self.edit_len];
}

/// Slots (0x4151a0, 0x4153c8): selected slot preview — `save.spr` frame at
/// (407, 5), 213×160 thumbnail at (412, 10), frame 1 if none; while typing a name,
/// a blinking `kursor.3df` 30×30 after the text and the current game snapshot.
pub fn drawSlots(self: *Menu, r: *c.SDL_Renderer) !void {
    const list = self.items();
    const sel = self.selected[@backingInt(self.screen)];
    if (sel < list.len) switch (list[sel].kind) {
        .slot => |k| if (self.save_frame.len() > 1) {
            try self.save_frame.draw(r, 0, 407, 5);
            // Typing a name: the current game snapshot (0x415300…0x415321).
            if (if (self.editing != null) self.snapshot else self.thumbs[k]) |t| {
                try gfx.check(c.SDL_RenderTexture(r, t, null, &.{ .x = 412, .y = 10, .w = 213, .h = 160 }));
            } else try self.save_frame.draw(r, 1, 412, 10);
        },
        else => {},
    };
    if (self.editing) |k| if (self.cursor_tex) |t| {
        const vr = self.visible();
        if (k < vr[0] or k >= vr[1]) return;
        const w = self.font.width(editName(self));
        // 0x4153f7: grey = pulse·255, additive, 30×30 at (321 + w/2, row − 20);
        // the phase grows in the menu logic tick (0x415ad0 → 0x45c8a0).
        const a = gfx.tilePulse(self.pulse_phase);
        _ = c.SDL_SetTextureBlendMode(t, self.modes.add);
        const g: u8 = @intFromFloat(255 * a);
        _ = c.SDL_SetTextureColorMod(t, g, g, g);
        try gfx.check(c.SDL_RenderTexture(r, t, null, &.{ .x = 321 + w / 2, .y = self.itemY(k) - 20, .w = 30, .h = 30 }));
    };
}

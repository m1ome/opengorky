//! A text field for free text (names, descriptions, lines; Cyrillic too): a click types
//! into it, Enter or a click elsewhere gives the text, Esc drops it. One at a time; its
//! text lives in the App (`text_edit`) while typed.

const std = @import("std");
const ui = @import("ui");
const clay = @import("clay.zig");
const font_mod = @import("font.zig");
const main = @import("app.zig");
const App = main.App;
const theme = main.theme;

pub const Edit = struct {
    /// The field typed into.
    id: ui.Clay_ElementId,
    buf: [1024]u8 = undefined,
    len: usize = 0,
    /// Laid out this frame (else it was left: dropped).
    seen: bool = false,

    pub fn text(self: *const Edit) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Field `key` showing `value` (`width` 0: the rest of the row); the typed text when
/// given (Enter or a click away), else null. `hint` shows while empty.
pub fn field(app: *App, key: []const u8, value: []const u8, width: f32, hint: []const u8) ?[]const u8 {
    const fid = clay.id(key);
    // Its typing ended (Enter, a click away): the text, once.
    var given: ?[]const u8 = null;
    if (app.text_given) |g| if (g.id.id == fid.id) {
        given = app.frame.allocator().dupe(u8, g.text()) catch null;
        app.text_given = null;
    };
    var typing = if (app.text_edit) |*e| e.id.id == fid.id else false;
    if (typing) app.text_edit.?.seen = true;
    clay.open(.{
        .id = fid,
        .layout = .{ .sizing = .{ .width = if (width == 0) clay.grow() else clay.fixed(width), .height = .{ .type = ui.CLAY__SIZING_TYPE_FIT, .size = .{ .minMax = .{ .min = 30, .max = 0 } } } }, .padding = .{ .left = 10, .right = 10, .top = 6, .bottom = 6 }, .childAlignment = .{ .y = ui.CLAY_ALIGN_Y_CENTER } },
        .backgroundColor = if (typing) theme.field else if (clay.pointerOver(fid)) theme.row_hover else theme.field,
        .cornerRadius = clay.radius(theme.radius),
        .border = .{ .color = if (typing) theme.accent else theme.field_border, .width = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 } },
    });
    if (!typing and clay.hovered() and app.clicked) {
        var e: Edit = .{ .id = fid, .seen = true };
        e.len = @min(value.len, e.buf.len);
        @memcpy(e.buf[0..e.len], value[0..e.len]);
        app.text_edit = e;
        typing = true;
    }
    const shown = if (typing) std.fmt.allocPrint(app.frame.allocator(), "{s}|", .{app.text_edit.?.text()}) catch "" else value;
    clay.text(if (shown.len == 0) hint else shown, .{ .textColor = if (shown.len == 0) theme.dim else theme.text, .fontSize = 13, .fontId = font_mod.regular, .wrapMode = ui.CLAY_TEXT_WRAP_WORDS });
    clay.close();
    return given;
}

/// Field `key` typed into now (as clicked), starting from `value`.
pub fn focus(app: *App, key: []const u8, value: []const u8) void {
    var e: Edit = .{ .id = clay.id(key), .seen = true };
    e.len = @min(value.len, e.buf.len);
    @memcpy(e.buf[0..e.len], value[0..e.len]);
    app.text_edit = e;
}

/// Before a layout: a click outside the field typed into gives its text.
pub fn clickAway(app: *App) void {
    const e = &(app.text_edit orelse return);
    if (app.clicked and !clay.pointerOver(e.id)) return enter(app);
    e.seen = false;
}

/// Enter: the typed text given to its field (at its next layout).
pub fn enter(app: *App) void {
    app.text_given = app.text_edit;
    app.text_edit = null;
}

/// After a layout: a field no longer shown drops its typing (and an unclaimed text).
pub fn afterLayout(app: *App) void {
    if (app.text_edit) |e| if (!e.seen) {
        app.text_edit = null;
    };
}

pub fn typed(app: *App, s: []const u8) void {
    const e = &(app.text_edit orelse return);
    const n = @min(s.len, e.buf.len - e.len);
    @memcpy(e.buf[e.len..][0..n], s[0..n]);
    e.len += n;
}

/// Backspace: the last character (all its UTF-8 bytes).
pub fn backspace(app: *App) void {
    const e = &(app.text_edit orelse return);
    while (e.len > 0) {
        e.len -= 1;
        if (e.buf[e.len] & 0xc0 != 0x80) break;
    }
}

test backspace {
    var e: Edit = .{ .id = .{} };
    const s = "ab\u{0436}";
    @memcpy(e.buf[0..s.len], s);
    e.len = s.len;
    while (e.len > 0) {
        e.len -= 1;
        if (e.buf[e.len] & 0xc0 != 0x80) break;
    }
    try std.testing.expectEqualStrings("ab", e.text());
}

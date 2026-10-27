//! Clay render commands → SDL renderer (in points; the render scale is the pixel density).

const std = @import("std");
const c = @import("sdl");
const ui = @import("ui");
const clay = @import("clay.zig");
const Font = @import("font.zig").Font;

/// Draws a CUSTOM element (`customData` set in its declaration) into its box.
const Custom = *const fn (ctx: *anyopaque, data: ?*anyopaque, box: c.SDL_FRect) void;

fn rgba(col: ui.Clay_Color) [4]u8 {
    return .{ @intFromFloat(col.r), @intFromFloat(col.g), @intFromFloat(col.b), @intFromFloat(col.a) };
}

fn setColor(r: *c.SDL_Renderer, col: ui.Clay_Color) void {
    const v = rgba(col);
    _ = c.SDL_SetRenderDrawColor(r, v[0], v[1], v[2], v[3]);
}

/// Points around `rect` with corners rounded by `cr` (clockwise from the top left),
/// `seg` per corner.
fn outline(rect: c.SDL_FRect, cr: ui.Clay_CornerRadius, out: *[n_pts][2]f32) void {
    const radii = [4]f32{ cr.topLeft, cr.topRight, cr.bottomRight, cr.bottomLeft };
    const half = @min(rect.w, rect.h) / 2;
    // Corner centres and the start angle of each arc (screen y down).
    for (0..4) |k| {
        const rr = @min(radii[k], half);
        const cx = if (k == 0 or k == 3) rect.x + rr else rect.x + rect.w - rr;
        const cy = if (k < 2) rect.y + rr else rect.y + rect.h - rr;
        const a0 = std.math.pi * (1.0 + 0.5 * @as(f32, @floatFromInt(k)));
        for (0..seg + 1) |s| {
            const t = a0 + std.math.pi * 0.5 * @as(f32, @floatFromInt(s)) / seg;
            out[k * (seg + 1) + s] = .{ cx + @cos(t) * rr, cy + @sin(t) * rr };
        }
    }
}

const seg = 8;
const n_pts = 4 * (seg + 1);

/// The anti-aliasing fringe (points; a pixel at 2× density): colour fading to clear.
const feather: f32 = 0.6;

/// `userData` of an element drawn raised (buttons, title bars): its colour as a top-lit
/// gradient, a light edge along the top and a shadow under it.
var raised: u8 = 0;

/// `userData` of a UI icon image: tinted by its colour.
pub var tinted: u8 = 0;

fn shade(col: ui.Clay_Color, d: f32) c.SDL_FColor {
    return .{ .r = std.math.clamp((col.r + d) / 255, 0, 1), .g = std.math.clamp((col.g + d) / 255, 0, 1), .b = std.math.clamp((col.b + d) / 255, 0, 1), .a = col.a / 255 };
}

fn fcolor(col: ui.Clay_Color) c.SDL_FColor {
    return .{ .r = col.r / 255, .g = col.g / 255, .b = col.b / 255, .a = col.a / 255 };
}

/// The outline of `rect` grown by `d` (shrunk when negative), round corners kept
/// concentric, square ones square.
fn outlineBy(rect: c.SDL_FRect, cr: ui.Clay_CornerRadius, d: f32, out: *[n_pts][2]f32) void {
    const grow = struct {
        fn f(v: f32, by: f32) f32 {
            return if (v > 0) @max(0, v + by) else 0;
        }
    }.f;
    outline(.{ .x = rect.x - d, .y = rect.y - d, .w = rect.w + 2 * d, .h = rect.h + 2 * d }, .{ .topLeft = grow(cr.topLeft, d), .topRight = grow(cr.topRight, d), .bottomRight = grow(cr.bottomRight, d), .bottomLeft = grow(cr.bottomLeft, d) }, out);
}

/// Triangles joining two outlines (`a` and `b` vertices from `ia` and `ib`) into `idx`.
fn strip(idx: []c_int, at: *usize, ia: usize, ib: usize) void {
    for (0..n_pts) |k| {
        const k1 = (k + 1) % n_pts;
        for ([_]usize{ ia + k, ia + k1, ib + k1, ia + k, ib + k1, ib + k }) |v| {
            idx[at.*] = @intCast(v);
            at.* += 1;
        }
    }
}

/// A rounded box filled from `top` to `bottom` colour (by height), its edge feathered.
fn fillShape(r: *c.SDL_Renderer, rect: c.SDL_FRect, cr: ui.Clay_CornerRadius, top: c.SDL_FColor, bottom: c.SDL_FColor) void {
    var in: [n_pts][2]f32 = undefined;
    var out: [n_pts][2]f32 = undefined;
    outlineBy(rect, cr, 0, &in);
    outlineBy(rect, cr, feather, &out);
    const at = struct {
        fn f(t: c.SDL_FColor, b: c.SDL_FColor, k: f32, a: f32) c.SDL_FColor {
            return .{ .r = t.r + (b.r - t.r) * k, .g = t.g + (b.g - t.g) * k, .b = t.b + (b.b - t.b) * k, .a = a };
        }
    }.f;
    var verts: [2 * n_pts + 1]c.SDL_Vertex = undefined;
    verts[0] = .{ .position = .{ .x = rect.x + rect.w / 2, .y = rect.y + rect.h / 2 }, .color = at(top, bottom, 0.5, top.a) };
    for (0..n_pts) |k| {
        const kin = std.math.clamp((in[k][1] - rect.y) / @max(1, rect.h), 0, 1);
        verts[1 + k] = .{ .position = .{ .x = in[k][0], .y = in[k][1] }, .color = at(top, bottom, kin, top.a) };
        verts[1 + n_pts + k] = .{ .position = .{ .x = out[k][0], .y = out[k][1] }, .color = at(top, bottom, kin, 0) };
    }
    var idx: [n_pts * 3 + n_pts * 6]c_int = undefined;
    for (0..n_pts) |k| {
        idx[k * 3] = 0;
        idx[k * 3 + 1] = @intCast(k + 1);
        idx[k * 3 + 2] = @intCast((k + 1) % n_pts + 1);
    }
    var n: usize = n_pts * 3;
    strip(&idx, &n, 1, 1 + n_pts);
    _ = c.SDL_RenderGeometry(r, null, &verts, verts.len, &idx, @intCast(n));
}

/// A rounded frame `w` points wide inside `rect`, both its edges feathered.
fn strokeShape(r: *c.SDL_Renderer, rect: c.SDL_FRect, cr: ui.Clay_CornerRadius, w: f32, col: ui.Clay_Color) void {
    const fc = fcolor(col);
    const clear: c.SDL_FColor = .{ .r = fc.r, .g = fc.g, .b = fc.b, .a = 0 };
    // From outside in: clear, solid, solid, clear.
    const rings = [4]struct { d: f32, col: c.SDL_FColor }{ .{ .d = feather / 2, .col = clear }, .{ .d = -feather / 2, .col = fc }, .{ .d = -w + feather / 2, .col = fc }, .{ .d = -w - feather / 2, .col = clear } };
    var verts: [4 * n_pts]c.SDL_Vertex = undefined;
    for (rings, 0..) |ring, k| {
        var pts: [n_pts][2]f32 = undefined;
        outlineBy(rect, cr, ring.d, &pts);
        for (pts, 0..) |p, i| verts[k * n_pts + i] = .{ .position = .{ .x = p[0], .y = p[1] }, .color = ring.col };
    }
    var idx: [3 * n_pts * 6]c_int = undefined;
    var n: usize = 0;
    for (0..3) |k| strip(&idx, &n, k * n_pts, (k + 1) * n_pts);
    _ = c.SDL_RenderGeometry(r, null, &verts, verts.len, &idx, @intCast(n));
}

/// A raised box: the shadow a point below it, the face lighter at the top than at the
/// bottom, a one-point highlight under the top edge.
fn fillRaised(r: *c.SDL_Renderer, rect: c.SDL_FRect, cr: ui.Clay_CornerRadius, col: ui.Clay_Color) void {
    fillRounded(r, .{ .x = rect.x, .y = rect.y + 1.5, .w = rect.w, .h = rect.h }, cr, .{ .r = 0, .g = 0, .b = 0, .a = 150 });
    fillShape(r, rect, cr, shade(col, 22), shade(col, -16));
    const hl = shade(col, 48);
    _ = c.SDL_SetRenderDrawColorFloat(r, hl.r, hl.g, hl.b, 0.55);
    const inset = @min(cr.topLeft, rect.h / 2);
    _ = c.SDL_RenderLine(r, rect.x + inset, rect.y + 1, rect.x + rect.w - inset, rect.y + 1);
}

fn rounded(cr: ui.Clay_CornerRadius) bool {
    return cr.topLeft > 0 or cr.topRight > 0 or cr.bottomLeft > 0 or cr.bottomRight > 0;
}

fn fillRounded(r: *c.SDL_Renderer, rect: c.SDL_FRect, cr: ui.Clay_CornerRadius, col: ui.Clay_Color) void {
    const fc = fcolor(col);
    fillShape(r, rect, cr, fc, fc);
}

pub fn draw(r: *c.SDL_Renderer, font: *const Font, cmds: clay.Commands, custom: Custom, ctx: *anyopaque) void {
    for (cmds) |*cmd| {
        const bb = cmd.boundingBox;
        const rect: c.SDL_FRect = .{ .x = bb.x, .y = bb.y, .w = bb.width, .h = bb.height };
        switch (cmd.commandType) {
            ui.CLAY_RENDER_COMMAND_TYPE_RECTANGLE => {
                const rd = cmd.renderData.rectangle;
                if (cmd.userData == @as(?*anyopaque, &raised)) {
                    fillRaised(r, rect, rd.cornerRadius, rd.backgroundColor);
                    continue;
                }
                if (rounded(rd.cornerRadius)) {
                    fillRounded(r, rect, rd.cornerRadius, rd.backgroundColor);
                    continue;
                }
                setColor(r, rd.backgroundColor);
                _ = c.SDL_RenderFillRect(r, &rect);
            },
            ui.CLAY_RENDER_COMMAND_TYPE_BORDER => {
                const b = cmd.renderData.border;
                setColor(r, b.color);
                const w = b.width;
                // A rounded frame all round (fields, buttons): a one-point outline. A
                // single edge (a tab's accent) stays a straight bar.
                if (rounded(b.cornerRadius) and w.left > 0 and w.left == w.right and w.left == w.top and w.left == w.bottom) {
                    strokeShape(r, rect, b.cornerRadius, @floatFromInt(w.left), b.color);
                    continue;
                }
                const edges = [_]c.SDL_FRect{
                    .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = @floatFromInt(w.top) },
                    .{ .x = rect.x, .y = rect.y + rect.h - @as(f32, @floatFromInt(w.bottom)), .w = rect.w, .h = @floatFromInt(w.bottom) },
                    .{ .x = rect.x, .y = rect.y, .w = @floatFromInt(w.left), .h = rect.h },
                    .{ .x = rect.x + rect.w - @as(f32, @floatFromInt(w.right)), .y = rect.y, .w = @floatFromInt(w.right), .h = rect.h },
                };
                _ = c.SDL_RenderFillRects(r, &edges, edges.len);
            },
            ui.CLAY_RENDER_COMMAND_TYPE_TEXT => {
                const t = cmd.renderData.text;
                font.draw(r, t.stringContents.chars[0..@intCast(t.stringContents.length)], t.fontId, t.fontSize, rect.x, rect.y, rgba(t.textColor));
            },
            ui.CLAY_RENDER_COMMAND_TYPE_SCISSOR_START => {
                // In render coordinates: SDL applies the render scale to the clip rectangle.
                const clip: c.SDL_Rect = .{
                    .x = @intFromFloat(@floor(rect.x)),
                    .y = @intFromFloat(@floor(rect.y)),
                    .w = @intFromFloat(@ceil(rect.w)),
                    .h = @intFromFloat(@ceil(rect.h)),
                };
                _ = c.SDL_SetRenderClipRect(r, &clip);
            },
            ui.CLAY_RENDER_COMMAND_TYPE_SCISSOR_END => _ = c.SDL_SetRenderClipRect(r, null),
            ui.CLAY_RENDER_COMMAND_TYPE_CUSTOM => custom(ctx, cmd.renderData.custom.customData, rect),
            // `imageData` is an SDL texture; it fills the box keeping its aspect.
            ui.CLAY_RENDER_COMMAND_TYPE_IMAGE => if (cmd.renderData.image.imageData) |p| {
                const t: *c.SDL_Texture = @ptrCast(@alignCast(p));
                var tw: f32 = 0;
                var th: f32 = 0;
                _ = c.SDL_GetTextureSize(t, &tw, &th);
                const k = @min(rect.w / tw, rect.h / th);
                // A UI icon (`userData` = `tinted`): white, drawn in its element's colour.
                const tint = cmd.renderData.image.backgroundColor;
                const tinted_icon = cmd.userData == @as(?*anyopaque, &tinted);
                if (tinted_icon) _ = c.SDL_SetTextureColorModFloat(t, tint.r / 255, tint.g / 255, tint.b / 255);
                defer if (tinted_icon) {
                    _ = c.SDL_SetTextureColorModFloat(t, 1, 1, 1);
                };
                _ = c.SDL_RenderTexture(r, t, null, &.{ .x = rect.x + (rect.w - tw * k) / 2, .y = rect.y + (rect.h - th * k) / 2, .w = tw * k, .h = th * k });
            },
            else => {},
        }
    }
}

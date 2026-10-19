//! SDL event dispatch: text input, key release and wheel here; key presses in keys.zig,
//! mouse buttons and motion in mouse.zig. main_loop.zig calls `handle` per event.

const std = @import("std");
const saves_ui = @import("../menu/saves.zig");
const menu_slots = @import("../menu/slots.zig");
const gui_short = @import("../gui/short.zig");
const camera_view = @import("../level/camera.zig");
const c = @import("sdl");
const viewer = @import("viewer.zig");
const Viewer = viewer.Viewer;
const keys = @import("keys.zig");
const mouse = @import("mouse.zig");
const input_ctx = @import("input_ctx.zig");
const Flow = input_ctx.Flow;
const Ctx = input_ctx.Ctx;

pub fn handle(v: *Viewer, ctx: *Ctx, raw: c.SDL_Event) !Flow {
    // Mouse in 640×480 canvas coordinates, once for all branches.
    var ev = raw;
    _ = c.SDL_ConvertEventToRenderCoordinates(ctx.renderer, &ev);
    switch (ev.type) {
        c.SDL_EVENT_QUIT => return .quit,
        c.SDL_EVENT_TEXT_INPUT => if (v.menu != null and v.menu.?.open and v.menu.?.editing != null) {
            // Save name (0x415470): what 0x412a00 lets through; "keyboard" sound.
            for (std.mem.span(ev.text.text)) |ch| {
                if (menu_slots.typeChar(v.menu.?, ch)) v.uiSound("keyboard");
            }
        } else if (v.console.open) v.console.typeText(std.mem.span(ev.text.text)),
        c.SDL_EVENT_KEY_DOWN => return keys.keyDown(v, ctx, ev),
        c.SDL_EVENT_KEY_UP => {
            // Tab released: speed-up ends (viewer; in the game it's `fast`).
            if (ev.key.key == c.SDLK_TAB and !v.play) if (v.level) |*l| {
                l.speed = 1;
            };
            if (ev.key.key == c.SDLK_LEFT or ev.key.key == c.SDLK_RIGHT) if (v.menu) |m| {
                m.hold_key = 0;
                if (m.options_changed) {
                    m.options_changed = false;
                    if (m.gains) |g| saves_ui.saveOptions(v, g);
                }
            };
        },
        c.SDL_EVENT_MOUSE_WHEEL => if (camera_view.wheelStep(v, ev.wheel.y)) |up| if (v.console.open) {
            if (up) v.console.scroll += 3 else v.console.scroll -|= 3;
        } else if (v.gui != null and gui_short.shortContains(v.gui.?, v.mouse[0], v.mouse[1])) {
            const g = v.gui.?;
            if (v.level) |*l| gui_short.shortScrollBy(g, l.world, if (up) -1 else 1);
        } else if (v.gui != null and v.gui.?.skills.contains(v.mouse[0], v.mouse[1])) {
            const sw = &v.gui.?.skills;
            if (up) sw.scroll -|= 1 else sw.scroll += 1;
        } else if (v.inventory) |inv| {
            if (inv.open) inv.scrollBy(if (up) -1 else 1);
            if (v.level) |*l| if (l.world.act.exploring != null) {
                if (up) inv.box_scroll -|= 1 else inv.box_scroll += 1;
            };
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN => return mouse.mouseDown(v, ctx, ev),
        c.SDL_EVENT_MOUSE_BUTTON_UP => return mouse.mouseUp(v, ctx, ev),
        c.SDL_EVENT_MOUSE_MOTION => return mouse.motion(v, ctx, ev),
        else => {},
    }
    return .next;
}

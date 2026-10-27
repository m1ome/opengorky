//! Mouse buttons and motion: panel, safe, menu, inventory, count window, quick list,
//! battle and field clicks, map dragging.

const std = @import("std");
const flow = @import("flow.zig");
const saves_ui = @import("../menu/saves.zig");
const panel_actions = @import("../gui/actions.zig");
const inventory_give = @import("../inventory/give.zig");
const inventory_input = @import("../inventory/input.zig");
const inventory_box = @import("../inventory/box.zig");
const gui_stats = @import("../gui/stats.zig");
const gui_short = @import("../gui/short.zig");
const gui_panel = @import("../gui/panel.zig");
const camera_view = @import("../level/camera.zig");
const battle_view = @import("../battle/view.zig");
const gui_battle = @import("../battle/gui.zig");
const devices_mod = og.combat.devices;
const turns_mod = og.combat.turns;
const scenes_mod = og.scene.scenes;
const og = @import("opengorky");
const c = @import("sdl");
const viewer = @import("viewer.zig");
const Viewer = viewer.Viewer;
const gui_mod = @import("../gui.zig");
const input_ctx = @import("input_ctx.zig");
const Flow = input_ctx.Flow;
const Ctx = input_ctx.Ctx;

/// Mouse press: panel, safe, menu, inventory, count window, quick list; otherwise start dragging the map.
pub fn mouseDown(v: *Viewer, ctx: *Ctx, ev: c.SDL_Event) !Flow {
    ctx.press_ui = false;
    v.idle_ticks = 0;
    // Point allocation is modal; ± and Accept act on the LMB press edge (0x404810(1), 0x4af890).
    if (v.gui) |g| if (g.stats.modal) {
        if (ev.button.button == c.SDL_BUTTON_LEFT) if (v.level) |*l| gui_stats.statsClick(g, l.world, ev.button.x, ev.button.y);
        return .next;
    };
    // The battle report is modal: a press only works its scrollbar (its Close acts on release).
    if (v.gui) |g| if (g.report_open) {
        if (ev.button.button == c.SDL_BUTTON_LEFT) if (v.level) |*l| {
            _ = gui_battle.reportPress(g, l.world, ev.button.x, ev.button.y);
        };
        return .next;
    };
    if (v.inventory) |inv| inv.press_at = if (ev.button.button == c.SDL_BUTTON_LEFT) .{ ev.button.x, ev.button.y } else null;
    if (v.gui) |g| if (ev.button.button == c.SDL_BUTTON_LEFT) {
        g.pressed_btn = null;
        const covered = v.video != null or g.go_frame != null or (v.menu != null and v.menu.?.open);
        if (v.level) |*l| if (!covered and !g.panel_hidden and !l.world.scene.cutscene and !l.world.scene.panorama and ev.button.y >= gui_mod.panel_y) {
            if (gui_panel.buttonAt(ev.button.x, ev.button.y)) |b| if (gui_panel.enabled(l.world, b)) {
                g.pressed_btn = b;
                if (b == .hand and !panel_actions.counterLock(v)) try panel_actions.handButton(v);
                // Double click on a portrait (0x4b279a, WM_LBUTTONDBLCLK): the
                // stats window; the release no longer selects anything.
                if (ev.button.clicks >= 2 and gui_panel.isPortrait(b) and !panel_actions.counterLock(v)) {
                    g.pressed_btn = null;
                    try panel_actions.portraitDouble(v);
                }
            };
        };
    };
    if (v.safeOpen()) {
        if (ev.button.button == c.SDL_BUTTON_LEFT) _ = v.safe.?.press(ev.button.x, ev.button.y);
        return .next;
    }
    // Menu: slider arrows repeat while the button is held.
    if (v.menu) |m| if (m.open and ev.button.button == c.SDL_BUTTON_LEFT) {
        if (m.press(ev.button.x, ev.button.y)) return .next;
    };
    // Inventory and quick list act on press (0x42dec0, 0x4b0f90); the map isn't
    // dragged then.
    if (v.video == null and !(v.menu != null and v.menu.?.open)) if (v.level) |*l| {
        const mx = ev.button.x;
        const my = ev.button.y;
        const left = ev.button.button == c.SDL_BUTTON_LEFT;
        if (v.inventory) |inv| if (inv.open and l.world.act.exploring == null and l.world.act.examining == null) {
            if (left) inventory_input.press(inv, l.world, mx, my) else if (ev.button.button == c.SDL_BUTTON_RIGHT) inventory_input.pressRight(inv, l.world, mx, my);
            return .next;
        };
        // The count window over the field (give mode from the panel) is modal.
        if (v.inventory) |inv| if (!inv.open and inv.give != null) {
            inventory_give.pressGive(inv, l.world, mx, my, left);
            ctx.press_ui = true;
            return .next;
        };
        if (left) if (v.gui) |g| if (gui_short.shortContains(g, mx, my)) {
            if (!gui_short.shortScrollPress(g, l.world, mx, my)) if (gui_short.shortRowAt(g, mx, my)) |k| try panel_actions.shortListClick(v, k);
            ctx.press_ui = true;
            return .next;
        };
    };
    // The exe has no camera dragging; viewer only.
    ctx.dragging = !v.play;
    ctx.drag_dist = 0;
    return .next;
}

/// Mouse release: clicks on windows, the panel and the field.
pub fn mouseUp(v: *Viewer, ctx: *Ctx, ev: c.SDL_Event) !Flow {
    ctx.dragging = false;
    if (v.inventory) |inv| inv.press_at = null;
    if (v.gui) |g| if (g.go_frame != null) {
        if (ev.button.button == c.SDL_BUTTON_LEFT) try flow.gameOverChoose(v, g.go_sel == 0);
        return .next;
    };
    if (v.gui) |g| {
        g.short_drag = false;
        g.report_drag = false;
    }
    if (v.inventory) |inv| if (inv.open and ev.button.button != c.SDL_BUTTON_LEFT) return .next;
    if (v.video != null) {
        v.stopVideo(true);
        return .next;
    }
    if (v.gui) |g| if (g.stats.modal) return .next;
    if (v.gui) |g| if (g.stats.contains(v.mouse[0], v.mouse[1])) return .next;
    if (v.gui) |g| if (g.report_open) {
        const bx = ev.button.x;
        const by = ev.button.y;
        if (ev.button.button == c.SDL_BUTTON_RIGHT or (bx >= 23 and bx <= 616 and by >= 399 and by <= 424)) {
            g.report_open = false;
            g.report_done = true;
            if (v.level) |*l| l.world.out.sound(l.world.gpa, "invgive", null);
        }
        return .next;
    };
    if (v.safeOpen()) {
        const w = v.level.?.world;
        // Right button closes, left presses a keypad key.
        if (ev.button.button == c.SDL_BUTTON_RIGHT) {
            v.safe.?.close(w);
        } else if (try v.safe.?.release(w, ev.button.x, ev.button.y)) {
            w.out.sound(w.gpa, "safekey", null);
        }
        return .next;
    }
    if (v.menu) |m| if (m.open) {
        const was_held = m.hold_mouse != 0;
        m.release();
        // Right button goes back (0x415ad0).
        if (ev.button.button == c.SDL_BUTTON_RIGHT) {
            if (m.screen == .ingame and v.level != null) {
                m.open = false;
                v.uiSound("click");
            } else m.back();
            v.menuSound();
            return .next;
        }
        if (!was_held) try flow.menuAction(v, m.click(ev.button.x, ev.button.y));
        v.menuSound();
        if (m.options_changed) {
            m.options_changed = false;
            if (m.gains) |g| saves_ui.saveOptions(v, g);
        }
        return .next;
    };
    // Right button cancels "Use … on …", else the area's second action (lift
    // button: down).
    if (ev.button.button == c.SDL_BUTTON_RIGHT) {
        // The press already went to the count window over the field.
        if (ctx.press_ui) {
            ctx.press_ui = false;
            return .next;
        }
        if (v.gui != null) if (v.level) |*l| if (l.world.mouse.push) {
            l.world.mouse.push = false;
            return .next;
        };
        // Quick list: close (and cancel give).
        if (v.gui) |g| if (g.short_open or (if (v.level) |*l| l.world.mouse.give != null else false)) {
            g.short_open = false;
            if (v.level) |*l| l.world.mouse.give = null;
            return .next;
        };
        if (v.inventory) |inv| if (inv.open) return .next;
        if (v.level) |*l| {
            if (l.world.mouse.use != null) {
                l.world.mouse.use = null;
            } else if (l.world.battle != null and ctx.drag_dist < 4) {
                try turns_mod.rightClick(&l.world.battle.?, l.world);
            } else if (l.world.battle == null and ctx.drag_dist < 4) {
                const bg = camera_view.bgMouse(v, .{ ev.button.x, ev.button.y });
                // Game: right click — walk up and open the examine menu (0x4514c0).
                if (l.world.examine_menus) {
                    if (og.world.actions.clickPlay(l.world, bg, true) catch false) l.clickMarker(bg);
                } else _ = og.world.actions.clickAction(l.world, bg, 1) catch false;
            }
        }
        return .next;
    }
    // A click without dragging: walk to the point.
    if (ctx.drag_dist < 4) if (v.level) |*l| {
        const mx = ev.button.x;
        const my = ev.button.y;
        if (v.inventory) |inv| if (l.world.act.exploring != null) {
            try inventory_box.clickBox(inv, l.world, mx, my, v.scroll);
            return .next;
        };
        if (v.inventory) |inv| if (l.world.act.examining != null) {
            try inventory_box.clickExamine(inv, l.world, mx, my, v.scroll);
            return .next;
        };
        if (v.inventory) |inv| if (inv.open) {
            panel_actions.inventoryAction(v, inv.release(l.world, mx, my));
            return .next;
        };
        // Scene line (0x478d56): left click — next.
        if (l.world.scene.cutscene and scenes_mod.skipLine(l.world)) return .next;
        if (v.gui) |g| if (g.skills.contains(mx, my)) return .next;
        if (v.gui) |g| if (gui_short.shortContains(g, mx, my)) return .next;
        // Weapon quick list open: a click outside only closes the list (on the
        // panel it works as usual).
        if (v.gui) |g| if (g.short_open and my < gui_mod.panel_hit_y) {
            g.short_open = false;
            l.world.mouse.give = null;
            return .next;
        };
        if (ctx.press_ui) {
            ctx.press_ui = false;
            return .next;
        }
        const on_panel = v.gui != null and !v.gui.?.panel_hidden and !l.world.scene.cutscene and !l.world.scene.panorama and my >= gui_mod.panel_hit_y;
        // Give mode: a field click picks the hero under the cursor (a miss does nothing).
        if (!on_panel and v.gui != null and l.world.mouse.give != null) {
            if (panel_actions.heroUnderMouse(v, l)) |to| try panel_actions.giveTo(v, to);
            return .next;
        }
        // Push mode: an obstacle cell (0x452ac0); on success the mode ends.
        if (!on_panel and v.gui != null and l.world.mouse.push) if (l.world.battle) |*b| {
            if (battle_view.tileAt(l, camera_view.bgMouse(v, .{ mx, my }))) |t| if (try devices_mod.push(b, l.world, t)) {
                l.world.mouse.push = false;
            };
            return .next;
        };
        if (on_panel) {
            try panel_actions.panelClick(v, mx, my);
        } else panel_actions.clickWalk(l, camera_view.bgMouse(v, .{ mx, my })) catch |err| std.log.warn("walk: {t}", .{err});
    };
    return .next;
}

/// Mouse motion: hover, dragging thumbs, map scrolling.
pub fn motion(v: *Viewer, ctx: *Ctx, ev: c.SDL_Event) !Flow {
    v.mouse = .{ ev.motion.x, ev.motion.y };
    if (v.gui) |g| g.hover_btn = gui_panel.buttonAt(v.mouse[0], v.mouse[1]);
    // Defeat: mouse above 340 — YES, below — NO.
    if (v.gui) |g| if (g.go_frame != null) {
        const sel: u8 = if (v.mouse[1] < 340) 0 else 1;
        if (sel != g.go_sel) {
            g.go_sel = sel;
            v.uiSound("menu1");
        }
    };
    if (v.level) |*l| {
        if (v.inventory) |inv| if (inv.open) inv.motion(l.world, v.mouse[1]);
        if (v.gui) |g| if (g.short_drag) gui_short.shortDrag(g, l.world, v.mouse[1]);
        if (v.gui) |g| if (g.report_drag) gui_battle.reportDrag(g, l.world, v.mouse[1]);
    }
    if (!ctx.dragging) return .next;
    ctx.drag_dist += @abs(ev.motion.xrel) + @abs(ev.motion.yrel);
    if (ctx.drag_dist >= 4) if (v.level) |*l| {
        l.follow = false;
    };
    // Converts the mouse delta from window to logical coordinates.
    camera_view.scrollBy(v, -ev.motion.xrel, -ev.motion.yrel);
    return .next;
}

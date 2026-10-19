//! Key presses: console, menu and defeat screen, window output, modal gates, game
//! and viewer keys, and the Esc ladder.

const flow = @import("flow.zig");
const debug_layers = @import("../level/debug_layers.zig");
const saves_ui = @import("../menu/saves.zig");
const panel_actions = @import("../gui/actions.zig");
const menu_slots = @import("../menu/slots.zig");
const gui_short = @import("../gui/short.zig");
const gui_panel = @import("../gui/panel.zig");
const frame = @import("frame.zig");
const commands = @import("commands.zig");
const camera_view = @import("../level/camera.zig");
const battle_grid = @import("../battle/grid.zig");
const control_mod = og.combat.control;
const turns_mod = og.combat.turns;
const scenes_mod = og.scene.scenes;
const Debug = @import("../level.zig").Debug;
const og = @import("opengorky");
const c = @import("sdl");
const viewer = @import("viewer.zig");
const Viewer = viewer.Viewer;
const input_ctx = @import("input_ctx.zig");
const Flow = input_ctx.Flow;
const Ctx = input_ctx.Ctx;

/// Key: console, menu and defeat screen, window output, then game and viewer keys.
pub fn keyDown(v: *Viewer, ctx: *Ctx, ev: c.SDL_Event) !Flow {
    v.idle_ticks = 0;
    if (consoleKey(v, ctx, ev)) return .next;
    if (windowKey(v, ctx, ev)) return .next;
    if (try menuKey(v, ev)) return .next;
    if (modalKey(v, ev)) return .next;
    if (blockedKey(v, ev)) return .next;
    if (try gameKey(v, ev)) |f| return f;
    try viewerKey(v, ctx, ev);
    return .next;
}

/// Console: ` or F2 toggles it; while open, keys go to it. In the game (--play)
/// only with `console = 1` or launch options (--dev, --console); the `x` step of
/// --input runs commands anyway; the resource viewer always.
fn consoleKey(v: *Viewer, ctx: *Ctx, ev: c.SDL_Event) bool {
    const console_ok = !v.play or v.cfg.console or ctx.opts.dev or ctx.opts.n_console > 0;
    if (console_ok and (ev.key.key == c.SDLK_GRAVE or ev.key.key == c.SDLK_F2)) {
        v.console.open = !v.console.open;
        if (v.console.open) {
            _ = c.SDL_StartTextInput(ctx.window);
            if (v.console.lines.items.len == 0) v.console.print(v.gpa, "OpenGorky console - type help") catch {};
        } else _ = c.SDL_StopTextInput(ctx.window);
        return true;
    }
    if (v.console.open) {
        commands.consoleKey(v, ctx.window, ev.key.key, ev.key.mod);
        return true;
    }
    return false;
}

/// Menu sliders, the defeat screen (0x454350) and menu navigation.
fn menuKey(v: *Viewer, ev: c.SDL_Event) !bool {
    // Left/Right — slider or value list: a step on press, then per menu tick while
    // the key is held (0x414f40); no OS key repeat needed.
    if (v.menu) |m| if (m.open and (ev.key.key == c.SDLK_LEFT or ev.key.key == c.SDLK_RIGHT)) {
        if (!ev.key.repeat) m.stepKey(if (ev.key.key == c.SDLK_LEFT) -1 else 1);
        v.menuSound();
        return true;
    };
    // Defeat: Y/Enter — yes, N — no, arrows — choose.
    if (v.gui) |g| if (g.go_frame != null) {
        switch (ev.key.key) {
            c.SDLK_Y => try flow.gameOverChoose(v, true),
            c.SDLK_N => try flow.gameOverChoose(v, false),
            c.SDLK_RETURN, c.SDLK_KP_ENTER => try flow.gameOverChoose(v, g.go_sel == 0),
            c.SDLK_UP, c.SDLK_DOWN => {
                g.go_sel ^= 1;
                v.uiSound("menu1");
            },
            else => {},
        }
        return true;
    };
    // Up/Down choose, Enter activates (or saves while typing a name), Backspace
    // deletes while typing (0x4155f6), else goes back (0x415d4f).
    if (v.menu) |m| if (m.open and m.screen != .credits) {
        switch (ev.key.key) {
            c.SDLK_UP => m.keyNav(-1),
            c.SDLK_DOWN => m.keyNav(1),
            c.SDLK_RETURN, c.SDLK_KP_ENTER => try flow.menuAction(v, m.enter()),
            c.SDLK_BACKSPACE => if (m.editing != null) {
                menu_slots.backspace(m);
                v.uiSound("keyboard");
            } else m.back(),
            else => {},
        }
        v.menuSound();
        if (ev.key.key == c.SDLK_UP or ev.key.key == c.SDLK_DOWN or ev.key.key == c.SDLK_RETURN or
            ev.key.key == c.SDLK_KP_ENTER or ev.key.key == c.SDLK_BACKSPACE) return true;
    };
    return false;
}

/// Window output: F10 — scaling; fullscreen — F11, Alt+Enter, Cmd+Enter,
/// Ctrl+Cmd+F (macOS takes F11).
fn windowKey(v: *Viewer, ctx: *Ctx, ev: c.SDL_Event) bool {
    const mod = ev.key.mod;
    const enter = ev.key.key == c.SDLK_RETURN or ev.key.key == c.SDLK_KP_ENTER;
    const full_key = ev.key.key == c.SDLK_F11 or
        (enter and (mod & (c.SDL_KMOD_ALT | c.SDL_KMOD_GUI)) != 0) or
        (ev.key.key == c.SDLK_F and (mod & c.SDL_KMOD_GUI) != 0 and (mod & c.SDL_KMOD_CTRL) != 0);
    if (ev.key.key != c.SDLK_F10 and !full_key) return false;
    if (ev.key.key == c.SDLK_F10) {
        v.cfg.scaling = @fromBackingInt(@intCast((@backingInt(v.cfg.scaling) + 1) % 3));
        frame.applyScaling(v);
        v.showMessage(switch (v.cfg.scaling) {
            .integer => "Scaling: integer",
            .sharp => "Scaling: fill, sharp",
            .smooth => "Scaling: fill, smooth",
        });
    } else {
        v.cfg.fullscreen = !v.cfg.fullscreen;
        _ = c.SDL_SetWindowFullscreen(ctx.window, v.cfg.fullscreen);
    }
    if (v.cfg_dir) |d| if (v.cfg_path) |pth| v.cfg.save(ctx.io, d, pth);
    return true;
}

/// An open menu or the level-up window is the top GUI mode (0x651cbc): game keys
/// don't reach the field. Esc still closes the menu, but not the level-up window.
fn modalKey(v: *Viewer, ev: c.SDL_Event) bool {
    if (v.gui) |g| if (g.stats.modal) return true;
    if (v.menu) |m| if (m.open) return ev.key.key != c.SDLK_ESCAPE;
    return false;
}

/// Keys swallowed in the current mode.
fn blockedKey(v: *Viewer, ev: c.SDL_Event) bool {
    // Counterattack: only the mouse attack and refusal (E, Enter, Esc, right button).
    if (panel_actions.counterLock(v)) switch (ev.key.key) {
        c.SDLK_I, c.SDLK_TAB, c.SDLK_Q, c.SDLK_X, c.SDLK_G, c.SDLK_P, c.SDLK_SPACE, c.SDLK_1, c.SDLK_2, c.SDLK_3, c.SDLK_4, c.SDLK_5, c.SDLK_6 => return true,
        else => {},
    };
    // Game mode (--play): debug layers and actions only via console commands
    // (show/hide, impulse, placeheroes, fast, scale, back, mute), so they can't be
    // turned on by accident.
    if (v.play) switch (ev.key.key) {
        c.SDLK_F1, c.SDLK_LEFTBRACKET, c.SDLK_RIGHTBRACKET, c.SDLK_L, c.SDLK_O, c.SDLK_M, c.SDLK_K, c.SDLK_N, c.SDLK_H, c.SDLK_MINUS, c.SDLK_EQUALS, c.SDLK_BACKSPACE, c.SDLK_R, c.SDLK_HOME => return true,
        c.SDLK_TAB => if (v.level) |*l| if (l.world.combat_map == null) return true,
        else => {},
    };
    return false;
}

/// Game keys: Esc, scene paging, inventory, battle, party, camera. Null: not handled here.
fn gameKey(v: *Viewer, ev: c.SDL_Event) !?Flow {
    // Hotkeys act once per press (exe edge bit, 0x404680/0x404330); only scrolling repeats.
    if (ev.key.repeat and v.play) switch (ev.key.key) {
        c.SDLK_W, c.SDLK_A, c.SDLK_S, c.SDLK_UP, c.SDLK_DOWN => {},
        else => return .next,
    };
    const s: f32 = if (ev.key.mod & c.SDL_KMOD_SHIFT != 0) 256 else 32;
    switch (ev.key.key) {
        c.SDLK_ESCAPE => return onEscape(v),
        // Arrows scroll the open quick list (0x4aea50); otherwise viewerKey.
        c.SDLK_UP, c.SDLK_DOWN => {
            const g = v.gui orelse return null;
            if (!g.short_open) return null;
            const l = if (v.level) |*l| l else return null;
            gui_short.shortScrollBy(g, l.world, if (ev.key.key == c.SDLK_UP) -1 else 1);
        },
        // Space: in a scene or dialog the next line page (in the exe that's a left
        // click and space skips the scene — ours is Esc); outside scenes it hides or
        // shows the panel (`[0x5247d0]`).
        c.SDLK_SPACE => if (v.level) |*l| {
            if (l.world.scene.runner != null or l.world.scene.subtitle != null) {
                _ = scenes_mod.skipLine(l.world);
            } else if (v.gui) |g| {
                g.panel_hidden = !g.panel_hidden;
            }
        } else {
            v.playing = !v.playing;
        },
        c.SDLK_I => if (v.level) |*l| if (v.inventory) |inv| {
            if (inv.open) inv.close(l.world) else inv.show(l.world);
            if (l.world.battle) |*b| control_mod.refreshSelection(b, l.world);
        },
        // Tab in battle: the battle grid (0x4b4aa0); outside battle: speed-up (debug).
        c.SDLK_TAB => if (v.level) |*l| {
            if (l.world.combat_map != null) battle_grid.toggleGrid(l) else l.speed = 8;
        },
        c.SDLK_Q => if (v.level) |*l| if (l.world.battle) |*b| control_mod.cycleWeapon(b, l.world),
        c.SDLK_E, c.SDLK_RETURN => if (v.level) |*l| if (l.world.battle) |*b| try turns_mod.endTurn(b, l.world),
        c.SDLK_X => if (v.level) |*l| if (l.world.battle) |*b| control_mod.defend(b, l.world),
        c.SDLK_F => if (v.level) |*l| {
            l.follow = true;
        },
        c.SDLK_1, c.SDLK_2, c.SDLK_3, c.SDLK_4, c.SDLK_5, c.SDLK_6 => if (v.level) |*l| {
            const heroes = l.world.party();
            const list = heroes.slice();
            const k: usize = @intCast(ev.key.key - c.SDLK_1);
            if (k < list.len and l.world.playerCanSelect(list[k])) {
                og.game.selectHero(l.world, list[k].name);
                l.follow = true;
            }
        },
        // P: in the game push (0x451510), in the viewer pause.
        c.SDLK_P => if (v.level) |*l| {
            if (!v.play) {
                l.paused = !l.paused;
            } else if (v.gui != null and l.world.battle != null and gui_panel.enabled(l.world, .push)) {
                l.world.mouse.push = !l.world.mouse.push;
            }
        },
        // G: give (panel button 1).
        c.SDLK_G => if (v.level != null) if (v.gui) |g| {
            g.pressed_btn = .give;
            try panel_actions.panelClick(v, gui_panel.rectCenter(.give)[0], gui_panel.rectCenter(.give)[1]);
        },
        c.SDLK_W => scrollKey(v, 0, -s),
        c.SDLK_S => scrollKey(v, 0, s),
        c.SDLK_A => scrollKey(v, -s, 0),
        // D: in the game battle defence, in the viewer scrolling.
        c.SDLK_D => if (v.play) {
            if (v.level) |*l| if (l.world.battle) |*b| control_mod.defend(b, l.world);
        } else scrollKey(v, s, 0),
        else => return null,
    }
    return .next;
}

fn scrollKey(v: *Viewer, dx: f32, dy: f32) void {
    camera_view.scrollBy(v, dx, dy);
    if (v.level) |*l| l.follow = false;
}

/// Resource viewer and debug keys (the game blocks them in `blockedKey`).
fn viewerKey(v: *Viewer, ctx: *Ctx, ev: c.SDL_Event) !void {
    switch (ev.key.key) {
        c.SDLK_F1 => v.show_debug = !v.show_debug,
        c.SDLK_LEFTBRACKET => try v.step(.archive, -1),
        c.SDLK_RIGHTBRACKET => try v.step(.archive, 1),
        // In a level the arrows move the camera (cameraTick).
        c.SDLK_UP => if (v.level == null) try v.step(.image, -1),
        c.SDLK_DOWN => if (v.level == null) try v.step(.image, 1),
        c.SDLK_LEFT => if (v.level == null) try v.step(.frame, -1),
        c.SDLK_RIGHT => if (v.level == null) try v.step(.frame, 1),
        c.SDLK_L => v.toggleLevel(),
        c.SDLK_O => if (v.level) |*l| {
            l.show_objects = !l.show_objects;
        },
        c.SDLK_M => if (v.level) |*l| debug_layers.cycleWalkLayer(l),
        c.SDLK_K => if (v.level) |*l| debug_layers.impulseAll(l),
        c.SDLK_N => ctx.mixer.master = if (ctx.mixer.master > 0) 0 else 1,
        c.SDLK_H => if (v.level) |*l| debug_layers.placeHeroes(l, v.scroll),
        c.SDLK_MINUS => v.debug.scale_tweak = @max(Debug.scale_min, v.debug.scale_tweak - Debug.scale_step),
        c.SDLK_EQUALS => v.debug.scale_tweak = @min(Debug.scale_max, v.debug.scale_tweak + Debug.scale_step),
        c.SDLK_BACKSPACE => if (v.game.prev) |p| v.game.goTo(p),
        c.SDLK_R => if (v.level) |*l| {
            l.show_areas = !l.show_areas;
        },
        c.SDLK_HOME => v.scroll = .{ 0, 0 },
        else => {},
    }
}

/// Esc (in order): skip a video, close the count window, quick list, safe; skip
/// a scene; menu; close the inventory; otherwise quit.
fn onEscape(v: *Viewer) Flow {
    // Video: skip (at startup all intro videos, 0x40fd15).
    if (v.video != null) {
        v.stopVideo(true);
        return .next;
    }
    if (v.inventory) |inv| if (inv.give != null) {
        inv.give = null;
        return .next;
    };
    if (v.gui) |g| if (g.short_open) {
        g.short_open = false;
        return .next;
    };
    if (v.safeOpen()) {
        v.safe.?.close(v.level.?.world);
        return .next;
    }
    // Scene: skip it whole (space in the exe, 0x479220).
    if (v.level) |*l| if (l.world.scene.runner != null and (v.menu == null or !v.menu.?.open)) {
        if (scenes_mod.skipScene(l.world)) return .next;
    };
    if (v.menu) |m| {
        // In the game Esc opens the menu; in the main menu nothing.
        // Esc (0x415ad0): to the parent screen; in the in-game menu — resume.
        if (m.open and m.screen == .ingame and v.level != null) {
            m.open = false;
            v.uiSound("click");
            return .next;
        }
        if (m.open and m.screen != .main) {
            m.escape();
            v.menuSound();
            return .next;
        }
        if (!m.open and v.level != null) {
            if (v.inventory) |inv| inv.close(v.level.?.world);
            saves_ui.captureThumb(v);
            m.can_save = saves_ui.canSave(v);
            m.show(.ingame);
            return .next;
        }
        return .next;
    }
    if (v.inventory) |inv| if (inv.open) {
        if (v.level) |*l| inv.close(l.world);
        if (v.gui) |g| g.skills.close();
        if (v.level) |*l| if (l.world.battle) |*b| control_mod.refreshSelection(b, l.world);
        return .next;
    };
    return .quit;
}

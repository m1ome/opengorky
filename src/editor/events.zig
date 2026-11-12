//! The editor's input events, one function per kind (main.zig's loop hands them over):
//! the pointer moving, its buttons and wheel, typed text, keys; and closing.

const std = @import("std");
const c = @import("sdl");
const clay = @import("clay.zig");
const tx = @import("text.zig");
const settings_mod = @import("settings.zig");
const sprview = @import("sprview.zig");
const paint = @import("paint.zig");
const treemenu = @import("treemenu.zig");
const textedit = @import("textedit.zig");
const levelanims = @import("levelanims.zig");
const paths = @import("paths.zig");
const codeview = @import("codeview.zig");
const levelpanel = @import("levelpanel.zig");
const App = @import("app.zig").App;

/// The quit is the Mac's Window menu Close (Cmd+W, SDL's own menu): a tab's close (keyDown), not the editor's.
pub fn closeKeyHeld() bool {
    return c.SDL_GetKeyboardState(null)[c.SDL_SCANCODE_W] and (c.SDL_GetModState() & c.SDL_KMOD_GUI) != 0;
}

/// Closing with edits not saved (or not applied in the code editor): save them, drop
/// them, or stay; true — close.
pub fn confirmQuit(app: *App) bool {
    const code_open = codeview.anyChanged(app);
    if (!app.store.dirty() and !code_open) return true;
    const buttons = [_]c.SDL_MessageBoxButtonData{
        .{ .flags = c.SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT, .buttonID = 1, .text = tx.get(tx.q_save).ptr },
        .{ .flags = 0, .buttonID = 2, .text = tx.get(tx.q_discard).ptr },
        .{ .flags = c.SDL_MESSAGEBOX_BUTTON_ESCAPEKEY_DEFAULT, .buttonID = 0, .text = tx.get(tx.cancel).ptr },
    };
    const data: c.SDL_MessageBoxData = .{
        .flags = c.SDL_MESSAGEBOX_WARNING,
        .window = app.window,
        .title = tx.get(tx.title).ptr,
        .message = tx.get(tx.q_unsaved).ptr,
        .numbuttons = buttons.len,
        .buttons = &buttons,
        .colorScheme = null,
    };
    var hit: c_int = 0;
    if (!c.SDL_ShowMessageBox(&data, &hit)) return true;
    switch (hit) {
        1 => {
            app.save();
            return !app.store.dirty() and !codeview.anyChanged(app);
        },
        2 => return true,
        else => return false,
    }
}

/// Delete on the picked object: asked first (as the menu's Delete).
fn askRemoveSelected(app: *App) void {
    const d = app.doc orelse return;
    const i = app.selected orelse return;
    const o = d.objects.items[i];
    // A box or a model stood here goes with its file.
    if (d.deletableBox(o.name) != null or (o.kind == .actor and d.deletableActor(o.name) != null)) return app.askDelete(.box, i, o.name);
    if (o.call == null or o.later != null) return;
    app.askDelete(.object, i, o.name);
}

/// Object keys (copy, paste, duplicate, rename) act on the level: its edit mode's
/// Objects tool, nothing over it.
fn levelKeys(app: *App) bool {
    return app.levelShown() and app.editingObjects() and !app.modal();
}

/// The pointer moved to `m` (points): what is dragged follows it.
pub fn motion(app: *App, m: [2]f32) void {
    if (app.code) |v| if (v.dragging) codeview.pointer(app, v, m, true);
    if (app.sprShown()) |e| if (e.painting) sprview.pointer(e, m, false);
    if (app.paint) |p| if (app.doc) |d| if (App.viewportRect()) |v| {
        const bg = d.toBackground(v, m);
        if (p.painting) paint.drag(app, p, bg);
        if (p.light_drag != null) paint.lightDrag(p, d, bg);
        if (p.area_from != null) paint.areaDrag(p, bg);
        if (p.cam_ring != null) paint.cameraDrag(p, d, v, m);
    };
    if (app.turning) |*t| {
        app.preview.yaw -= (m[0] - t[0]) * 0.6;
        // Up and down tilt it, short of straight above or below.
        app.preview.pitch = std.math.clamp(app.preview.pitch + (m[1] - t[1]) * 0.6, -89, 89);
        t.* = m;
    }
    if (app.shifting) |*p| {
        app.preview.shift = .{ app.preview.shift[0] + m[0] - p[0], app.preview.shift[1] + m[1] - p[1] };
        p.* = m;
    }
    if (app.doc) |d| {
        if (app.paths.drag != null) {
            if (App.viewportRect()) |v| paths.drag(app, d, v, m);
        } else if (app.anims.drag) |*dr| {
            if (App.viewportRect()) |v| {
                const bg = d.toBackground(v, m);
                dr.at = .{ @round(bg[0] - dr.off[0]), @round(bg[1] - dr.off[1]) };
            }
        } else if (app.moving) |mi| {
            if (App.viewportRect()) |v| d.drag(v, mi, m);
        } else if (app.pan) |*last| {
            d.origin[0] -= (m[0] - last[0]) / d.zoom;
            d.origin[1] -= (m[1] - last[1]) / d.zoom;
            last.* = m;
        }
    }
    app.mouse = m;
}

pub fn buttonDown(app: *App, b: c.SDL_MouseButtonEvent) void {
    if (b.button == c.SDL_BUTTON_LEFT) {
        app.down = true;
        app.clicked = true;
        if (app.code) |v| if (codeview.over(v, app.mouse)) {
            codeview.press(app, v, app.mouse, b.clicks, c.SDL_GetModState());
            v.dragging = true;
        };
        if (app.sprShown()) |e| if (sprview.over(e, app.mouse)) {
            e.painting = true;
            sprview.pointer(e, app.mouse, false);
        };
    } else if (b.button == c.SDL_BUTTON_X1 or b.button == c.SDL_BUTTON_X2) {
        // The mouse's side buttons: Back and Forward through the code's jumps.
        _ = @import("codehist.zig").step(app, b.button == c.SDL_BUTTON_X2);
    } else if (b.button == c.SDL_BUTTON_RIGHT and app.code != null and codeview.over(app.code.?, app.mouse)) {
        codeview.openMenu(app, app.code.?);
    } else if (app.sprShown()) |e| {
        // The right button on the icon: the eyedropper.
        if (sprview.over(e, app.mouse)) sprview.pointer(e, app.mouse, true);
    } else if (clay.pointerOver(clay.id("preview_img"))) {
        app.shifting = app.mouse;
    } else if (app.levelShown() and !app.modal()) {
        // Right or middle drag pans the level; a right click opens the menu
        // (on the level, or on a row of the object list).
        if (app.overViewport()) app.pan = app.mouse;
        if (b.button == c.SDL_BUTTON_RIGHT) app.right_down = app.mouse;
    }
}

/// Button `button` released: drags, strokes and moves end (a short right click opens the menu).
pub fn buttonUp(app: *App, button: u8) void {
    if (button == c.SDL_BUTTON_LEFT) {
        app.down = false;
        app.turning = null;
        if (app.code) |v| {
            v.dragging = false;
            v.hbar = null;
            v.vbar = null;
        }
        if (app.spr) |e| if (e.painting) sprview.release(app, e);
        if (app.paint) |p| paint.release(app, p);
        if (app.paint) |p| paint.lightRelease(app, p);
        if (app.paint) |p| paint.cameraRelease(app, p);
        // Last: a moved area reloads the level, this Paint with it.
        if (app.paint) |p| paint.areaRelease(app, p);
    }
    if (button == c.SDL_BUTTON_RIGHT) if (app.right_down) |p| {
        app.right_down = null;
        if (@abs(p[0] - app.mouse[0]) + @abs(p[1] - app.mouse[1]) < 4) {
            if (app.overViewport()) {
                if (app.editingObjects()) app.openMenu();
            } else app.right_clicked = true;
        }
    };
    app.pan = null;
    app.shifting = null;
    if (app.paths.drag != null) if (app.doc) |d| paths.release(app, d);
    if (app.anims.drag) |dr| {
        app.anims.drag = null;
        if (app.doc) |d| levelanims.place(app, d, dr.name(), dr.at);
    }
    if (app.moving != null) {
        app.moving = null;
        if (app.doc) |d| d.drop() catch |err| switch (err) {
            error.NotWalkable => app.setStatus(tx.st_not_walkable, .{}),
            error.TileNotFree => app.setStatus(tx.st_no_tile, .{}),
            else => app.setStatus(tx.st_move_failed, .{err}),
        };
    }
}

/// The wheel: the code editor's scroll under the pointer, else added to this frame's `acc`.
pub fn wheel(app: *App, w: c.SDL_MouseWheelEvent, acc: *[2]f32) void {
    if (app.code != null and codeview.over(app.code.?, app.mouse)) {
        codeview.wheel(app.code.?, w.x, w.y, (c.SDL_GetModState() & c.SDL_KMOD_SHIFT) != 0);
    } else {
        acc.* = .{ acc[0] + w.x, acc[1] + w.y };
    }
}

pub fn textInput(app: *App, s: []const u8) void {
    if (app.text_edit == null and app.code != null) {
        codeview.typed(app, app.code.?, s);
    } else app.typed(s);
}

/// A key pressed: the field or window typed into first, else the editor's shortcuts.
pub fn keyDown(app: *App, key: c.SDL_KeyboardEvent) void {
    // F1 anywhere but in the code (its own F1: the word's article or its help column).
    const tree = textedit.typingIn(app, "tree_search");
    if (key.key == c.SDLK_F1 and (app.code == null or tree)) return @import("reference.zig").open(app, null);
    // Cmd+W / Ctrl+W anywhere: the shown tab closes (as its ×), never the editor.
    if (key.key == c.SDLK_W and (key.mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI)) != 0) return @import("doctabs.zig").closeActive(app);
    // Enter and Esc in a window's search are the window's (as its other keys' shortcuts).
    if (textedit.typingIn(app, "window_search") and (key.key == c.SDLK_RETURN or key.key == c.SDLK_KP_ENTER or key.key == c.SDLK_ESCAPE)) app.text_edit = null;
    if (app.confirm == null and app.pick != null and key.key == c.SDLK_ESCAPE) {
        // Esc closes an open list (picker.zig), its search typed into or not.
        if (textedit.typingIn(app, "pick_search")) app.text_edit = null;
        app.pick = null;
    } else if (app.confirm != null and (key.key == c.SDLK_RETURN or key.key == c.SDLK_KP_ENTER or key.key == c.SDLK_ESCAPE)) {
        // The confirmation window: Enter deletes, Esc keeps.
        if (key.key == c.SDLK_ESCAPE) app.confirm = null else app.confirmed();
    } else if (app.text_edit != null and key.key == c.SDLK_ESCAPE and app.text_edit.?.id.id == clay.id("code_find").id) {
        // Esc in the code's find field closes the bar too (one Esc, not two).
        if (app.code) |v| codeview.closeFind(app, v);
        app.text_edit = null;
    } else if (app.text_edit != null and textedit.keyDown(app, key.key, key.mod)) {
        // The field typed into took it.
    } else if (app.code != null and !tree and codeview.key(app, app.code.?, key.key, key.mod)) {
        // The code editor took it.
    } else {
        const cmd = (key.mod & (c.SDL_KMOD_CTRL | c.SDL_KMOD_GUI)) != 0;
        switch (key.key) {
            c.SDLK_S => if (cmd) app.saveOnly(app.store.doc), // the shown tab's edits
            // The UI scale by 10% (as browsers'), back to 100%: reachable when the
            // settings' slider is scaled out of the window.
            c.SDLK_EQUALS, c.SDLK_PLUS, c.SDLK_KP_PLUS, c.SDLK_MINUS, c.SDLK_KP_MINUS, c.SDLK_0 => if (cmd) {
                const k = key.key;
                const d: f32 = if (k == c.SDLK_0) 0 else if (k == c.SDLK_MINUS or k == c.SDLK_KP_MINUS) -0.1 else 0.1;
                app.settings.ui_scale = if (d == 0) 1 else std.math.clamp(@round((app.settings.ui_scale + d) * 20) / 20, settings_mod.ui_scale_min, settings_mod.ui_scale_max);
                app.saveSettings();
            },
            c.SDLK_K => if (cmd) app.focusTree(),
            // In the edit mode: its strokes, then (none left) the edits before
            // it, the level read again.
            c.SDLK_Z => if (cmd) if (app.paint) |p| {
                if (!paint.undo(app, p)) {
                    app.undo();
                    app.reloadLevel();
                }
            } else app.undo(),
            // Enter: a drawn area finished, else the picked box's contents opened.
            c.SDLK_RETURN, c.SDLK_KP_ENTER => if (app.paint) |p| if (p.poly.items.len > 0 or !levelKeys(app)) paint.finishArea(app, p) else if (app.doc) |d| if (app.selected) |i| {
                _ = app.openBox(d.objects.items[i].name);
            },
            c.SDLK_DELETE, c.SDLK_BACKSPACE => if (app.paint) |p| {
                // A closed outline opens again first; the Objects tool removes the picked.
                if (p.tool == .objects) askRemoveSelected(app) else if (p.poly_closed) p.poly_closed = false else _ = p.poly.pop();
            },
            c.SDLK_ESCAPE => if (app.paint != null and app.paint.?.poly.items.len > 0) {
                app.paint.?.poly.clearRetainingCapacity();
                app.paint.?.poly_closed = false;
            } else {
                app.menu = null;
                app.box = null;
                app.trigger = null;
                app.moving = null;
                if (app.doc) |d| d.preview = null;
            },
            // F: the picked object centred (none: the whole level fitted).
            c.SDLK_F => if (app.doc) |d| if (App.viewportRect()) |v| if (app.selected) |i| app.centreOn(d.objects.items[i].pos) else d.fit(v),
            // Copy, duplicate, paste: the picked object while editing the level's
            // objects, else the open document (a tree row's copy).
            c.SDLK_C => if (cmd) if (levelKeys(app)) (if (app.selected) |i| app.copyObject(i)) else if (treemenu.current(app)) |it| treemenu.copy(app, it),
            c.SDLK_D => if (cmd) if (levelKeys(app)) (if (app.selected) |i| app.duplicate(i)) else if (treemenu.current(app)) |it| treemenu.duplicate(app, it),
            c.SDLK_V => if (cmd) if (levelKeys(app)) (if (app.doc) |d| if (App.viewportRect()) |v| app.paste(d.toBackground(v, app.mouse), d.gridAt(v, app.mouse))) else if (app.tree_clip) |it| treemenu.duplicate(app, it),
            c.SDLK_F2 => if (levelKeys(app)) if (app.doc) |d| if (app.selected) |i| if (d.objects.items[i].kind == .area) levelpanel.renameArea(app, d.objects.items[i].name),
            else => {},
        }
    }
}

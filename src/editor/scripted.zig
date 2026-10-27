//! The editor's scripted edits (checks, scripts, demos): one function each, found by
//! the name cli.zig parses; main.zig runs them in order after loading.

const std = @import("std");
const Io = std.Io;
const c = @import("sdl");
const level = @import("level.zig");
const tx = @import("text.zig");
const catalog = @import("catalog.zig");
const pages = @import("pages.zig");
const boxpanel = @import("boxpanel.zig");
const preview = @import("preview.zig");
const soundpage = @import("soundpage.zig");
const sprview = @import("sprview.zig");
const paint = @import("paint.zig");
const scenepage = @import("scenepage.zig");
const checkpanel = @import("checkpanel.zig");
const assettree = @import("assettree.zig");
const icons = @import("icons.zig");
const doctabs = @import("doctabs.zig");
const treemenu = @import("treemenu.zig");
const cli = @import("cli.zig");
const levelanims = @import("levelanims.zig");
const logicview = @import("logicview.zig");
const paths = @import("paths.zig");
const codeview = @import("codeview.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Tab = app_mod.Tab;
const ui_main = @import("main.zig");

const Handler = *const fn (*App, []const []const u8) anyerror!void;

/// Scripted edit `op[0]` with its values `op[1..]`.
pub fn run(app: *App, op: []const []const u8) !void {
    const h = handlers.get(op[0]) orelse return error.UnknownOp;
    return h(app, op);
}

const handlers = std.StaticStringMap(Handler).initComptime(.{
    .{ "--package", opPackage },
    .{ "--query", opQuery },
    .{ "--import-icon", opArtFile },
    .{ "--import-texture", opArtFile },
    .{ "--export-texture", opArtFile },
    .{ "--export-icon", opArtFile },
    .{ "--export-glb", opArtFile },
    .{ "--import-glb", opArtFile },
    .{ "--import-anims", opArtFile },
    .{ "--scene-skip", opSceneSkip },
    .{ "--scene-off", opSceneSkip },
    .{ "--dialog", opDialog },
    .{ "--scene", opScene },
    .{ "--code", opCode },
    .{ "--type", opType },
    .{ "--walk", opWalk },
    .{ "--modcheck", opModcheck },
    .{ "--wire", opWire },
    .{ "--zone", opZone },
    .{ "--num", opNum },
    .{ "--play-level", opPlayLevel },
    .{ "--history", opHistory },
    .{ "--roll-back", opRollBack },
    .{ "--history-old", opHistoryOld },
    .{ "--return-to", opReturnTo },
    .{ "--box-add", opBoxAdd },
    .{ "--inventory", opInventory },
    .{ "--icon", opIcon },
    .{ "--paint", opPaint },
    .{ "--level-paint", opLevelPaint },
    .{ "--level-done", opLevelDone },
    .{ "--camera", opCamera },
    .{ "--cam-drag", opCamDrag },
    .{ "--grid-split", opGridSplit },
    .{ "--depth-fit", opDepthFit },
    .{ "--paint-tool", opPaintTool },
    .{ "--new-scene", opNewScene },
    .{ "--new-script", opNewScript },
    .{ "--effect", opEffect },
    .{ "--effect-add", opEffectAdd },
    .{ "--font", opFont },
    .{ "--font-ttf", opFontTtf },
    .{ "--import-music", opImportMusic },
    .{ "--dlg", opDlg },
    .{ "--text", opText },
    .{ "--scene-test", opSceneTest },
    .{ "--logic", opLogic },
    .{ "--open-key", opOpenKey },
    .{ "--sprite", opSprite },
    .{ "--import-sprite", opImportSprite },
    .{ "--add-frame", opAddFrame },
    .{ "--frame-out", opFrameOut },
    .{ "--frame-in", opFrameIn },
    .{ "--tree-dup", opTreeDup },
    .{ "--tree-menu", opTreeDup },
    .{ "--open", opOpen },
    .{ "--tree", opTree },
    .{ "--import-video", opImportVideo },
    .{ "--add-own", opAddOwn },
    .{ "--goto", opGoto },
    .{ "--info", opInfo },
    .{ "--scene-rename", opSceneRename },
    .{ "--new-location", opNewLocation },
    .{ "--put", opPut },
    .{ "--scene-point", opScenePoint },
    .{ "--add-hero", opScenePoint },
    .{ "--area-delete", opAreaDelete },
    .{ "--remove-hero", opRemoveHero },
    .{ "--rendered", opRendered },
    .{ "--area-move", opAreaMove },
    .{ "--area-rename", opAreaRename },
    .{ "--voice", opVoice },
    .{ "--voice-copy", opVoiceCopy },
    .{ "--level-area", opLevelArea },
    .{ "--level-light", opLevelLight },
    .{ "--level-exit", opLevelExit },
    .{ "--level-undo", opLevelUndo },
    .{ "--show", opShow },
    .{ "--copy", opCopy },
    .{ "--sound", opSound },
    .{ "--class-weapon", opClassWeapon },
    .{ "--import-sound", opImportSound },
    .{ "--export-sound", opExportSound },
    .{ "--entry", opEntry },
    .{ "--menu-open", opMenuOpen },
    .{ "--ask-delete", opAskDelete },
    .{ "--add-model", opAddModel },
    .{ "--path", opPath },
    .{ "--path-node", opPathNode },
    .{ "--anim", opAnim },
    .{ "--anim-new", opAnimNew },
    .{ "--dup", opDup },
    .{ "--save-now", opSaveNow },
    .{ "--purge", opPurge },
    .{ "--remove", opRemove },
    .{ "--walk-in", opWalkIn },
    .{ "--weapon", opWeapon },
    .{ "--prop", opProp },
    .{ "--turn", opTurn },
    .{ "--obstacle", opObstacle },
    .{ "--add-at", opAddAt },
    .{ "--new-box", opNewBox },
    .{ "--select", opSelect },
    .{ "--delete-box", opDeleteBox },
    .{ "--menu-obj", opDeleteBox },
    .{ "--trigger", opTrigger },
    .{ "--box", opBox },
    .{ "--click", opClick },
    .{ "--adjust", opAdjust },
    .{ "--strike-hero", opStrikeHero },
    .{ "--preview-frame", opPreviewFrame },
    .{ "--wheel", opWheel },
    .{ "--menu", opMenu },
    .{ "--add", opAdd },
    .{ "--set", opSet },
    .{ "--set-class", opSet },
    .{ "--move", opMove },
});

// Every op the command line parses has its edit (checked when the editor builds).
comptime {
    @setEvalBranchQuota(100_000);
    for (cli.ops) |o| if (handlers.get(o.name) == null) @compileError("no scripted edit for " ++ o.name);
}

fn opQuery(app: *App, op: []const []const u8) !void {
    const n = @min(op[1].len, app.query_buf.len);
    @memcpy(app.query_buf[0..n], op[1][0..n]);
    app.query_len = n;
}

fn opArtFile(app: *App, op: []const []const u8) !void {
    // `ID#N`: the model's texture N (0 — its own).
    const hash = std.mem.indexOfScalar(u8, op[1], '#');
    const i = try pages.entryById(app, op[1][0 .. hash orelse op[1].len]);
    const slot: u8 = if (hash) |h| try std.fmt.parseInt(u8, op[1][h + 1 ..], 10) else 0;
    app.entry = i;
    const em = @import("entry_model.zig");
    const handler: *const fn (*App, app_mod.FileAsk, []const u8) anyerror!void = if (std.mem.eql(u8, op[0], "--export-texture")) pages.onTextureOut else if (std.mem.eql(u8, op[0], "--export-icon")) pages.onIconOut else if (std.mem.eql(u8, op[0], "--import-icon")) pages.onIconIn else if (std.mem.eql(u8, op[0], "--export-glb")) em.onGlbOut else if (std.mem.eql(u8, op[0], "--import-glb")) em.onGlbIn else if (std.mem.eql(u8, op[0], "--import-anims")) em.onAnimsIn else pages.onTextureIn;
    return app.fileChosen(.{ .kind = .png, .run = handler, .entry = i, .slot = slot }, op[2]);
}

fn opSceneSkip(app: *App, op: []const []const u8) !void {
    return scenepage.scripted(app, app.frame.allocator(), op[0][8] == 's', op[1]);
}

fn opDialog(app: *App, op: []const []const u8) !void {
    return app.showDialog(op[1]);
}

fn opScene(app: *App, op: []const []const u8) !void {
    for (app.catalog.scenes.items, 0..) |sc, i| if (std.ascii.eqlIgnoreCase(sc.name, op[1])) {
        app.scene = i;
    };
}

fn opCode(app: *App, op: []const []const u8) !void {
    // `archive:entry` (e.g. `common/lang.dat:port_deska.dlg`), or an entry of the open level.
    if (std.mem.indexOfScalar(u8, op[1], ':')) |k| return codeview.open(app, try app.store.file(op[1][0..k], op[1][k + 1 ..]), null);
    const dd = app.doc orelse return error.NoLevel;
    codeview.open(app, if (std.mem.eql(u8, op[1], "lev")) dd.lev else try app.store.file(dd.level_archive, op[1]), null);
}

fn opType(app: *App, op: []const []const u8) !void {
    const v = app.code orelse return error.NoCode;
    for (0..2) |_| ui_main.present(app, ui_main.frame(app, app.size, .{ 0, 0 }));
    // `\n` is Enter, `@` asks for completion (tasks on an empty spot), `^` takes it (Tab),
    // `<`/`>` move in the list, `?` is F1, `%` formats, `$` applies, `~` comments the line out (Cmd+/).
    for (op[1]) |ch| switch (ch) {
        '\n' => _ = codeview.key(app, v, c.SDLK_RETURN, 0),
        '@' => _ = codeview.key(app, v, c.SDLK_SPACE, c.SDL_KMOD_CTRL),
        '^' => _ = codeview.key(app, v, c.SDLK_TAB, 0),
        '<' => _ = codeview.key(app, v, c.SDLK_UP, 0),
        '?' => _ = codeview.key(app, v, c.SDLK_F1, 0),
        '>' => _ = codeview.key(app, v, c.SDLK_DOWN, 0),
        '%' => codeview.formatText(app, v),
        '~' => _ = codeview.key(app, v, c.SDLK_SLASH, c.SDL_KMOD_GUI),
        '$' => codeview.apply(app, v),
        else => codeview.typed(v, &.{ch}),
    };
}

fn opWalk(app: *App, op: []const []const u8) !void {
    _ = op;
    app.show_walk = true;
}

fn opModcheck(app: *App, op: []const []const u8) !void {
    _ = op;
    checkpanel.run(app);
    if (app.check) |r| r.shown = true;
}

fn opWire(app: *App, op: []const []const u8) !void {
    _ = op;
    app.preview.wire = true;
}

/// `--zone`: a weapon page shows its damage zone instead of the model.
fn opZone(app: *App, op: []const []const u8) !void {
    _ = op;
    app.zone_view = true;
}

/// `--num ID VALUE`: VALUE typed into the level panel's stepper ID (Enter), applied on the next frame.
fn opNum(app: *App, op: []const []const u8) !void {
    var e: app_mod.NumEdit = .{ .id = std.hash.Wyhash.hash(0, op[1]), .done = true };
    e.len = @min(op[2].len, e.buf.len);
    @memcpy(e.buf[0..e.len], op[2][0..e.len]);
    app.num_edit = e;
    for (0..2) |_| ui_main.present(app, ui_main.frame(app, app.size, .{ 0, 0 }));
}

fn opPlayLevel(app: *App, op: []const []const u8) !void {
    _ = op;
    return app.playLevel();
}

fn opHistory(app: *App, op: []const []const u8) !void {
    _ = op;
    app.setTab(.history);
    app.history_open = app.store.undo.items.len;
}

fn opRollBack(app: *App, op: []const []const u8) !void {
    return app.rollBack(try std.fmt.parseInt(usize, op[1], 10));
}

/// History tab with an earlier session's save `op[1]` picked (0: the original).
fn opHistoryOld(app: *App, op: []const []const u8) !void {
    app.setTab(.history);
    app.history_open = null;
    app.history_old = try std.fmt.parseInt(usize, op[1], 10);
}

fn opReturnTo(app: *App, op: []const []const u8) !void {
    return app.returnToPast(try std.fmt.parseInt(usize, op[1], 10));
}

fn opBoxAdd(app: *App, op: []const []const u8) !void {
    return boxpanel.addClass(app, app.frame.allocator(), app.box orelse return error.NoBox, op[1]);
}

fn opInventory(app: *App, op: []const []const u8) !void {
    return pages.openInventory(app, try pages.entryById(app, op[1]));
}

fn opIcon(app: *App, op: []const []const u8) !void {
    return sprview.open(app, op[1]);
}

/// `--paint F,X,Y,RRGGBB`: one pixel of frame F in the open icon, a step.
fn opPaint(app: *App, op: []const []const u8) !void {
    const e = app.spr orelse return error.NoIcon;
    var it = std.mem.splitScalar(u8, op[1], ',');
    e.frame = try std.fmt.parseInt(usize, it.next() orelse return error.BadPaint, 10);
    const x = try std.fmt.parseFloat(f32, it.next() orelse return error.BadPaint);
    const y = try std.fmt.parseFloat(f32, it.next() orelse return error.BadPaint);
    const rgb = try std.fmt.parseInt(u24, it.next() orelse return error.BadPaint, 16);
    e.color = .{ @truncate(rgb >> 16), @truncate(rgb >> 8), @truncate(rgb), 255 };
    e.tool = .pencil;
    e.zoom = 1;
    e.origin = .{ 0, 0 };
    sprview.pointer(e, .{ x, y }, false);
    return sprview.release(app, e);
}

/// `--level-paint LAYER,X0,Y0,X1,Y1[,VALUE]`: a stroke in the level edit mode (opened
/// if not yet) on the open location, background pixels; VALUE: RRGGBB, a depth, 0/1.
fn opLevelPaint(app: *App, op: []const []const u8) !void {
    if (app.paint == null) app.openPaint();
    const p = app.paint orelse return error.NoLevel;
    var it = std.mem.splitScalar(u8, op[1], ',');
    p.layer = std.meta.stringToEnum(paint.Layer, it.next() orelse return error.BadPaint) orelse return error.BadPaint;
    var pts: [4]f32 = undefined;
    for (&pts) |*v| v.* = try std.fmt.parseFloat(f32, it.next() orelse return error.BadPaint);
    if (it.next()) |v| switch (p.layer) {
        .picture => {
            const rgb = try std.fmt.parseInt(u24, v, 16);
            p.color = .{ @truncate(rgb >> 16), @truncate(rgb >> 8), @truncate(rgb), 255 };
        },
        .depth => p.depth_value = try std.fmt.parseInt(u8, v, 10),
        .walk, .walk2, .grid => p.walk_on = !std.mem.eql(u8, v, "0"),
    };
    p.tool = .brush;
    paint.press(app, p, pts[0..2].*);
    paint.drag(app, p, pts[2..4].*);
    return paint.release(app, p);
}

fn opLevelDone(app: *App, op: []const []const u8) !void {
    _ = op;
    return app.closePaint();
}

/// `--camera KEY DELTA`: a battle camera key of initCamera() changed; `--grid-split W H`.
fn opCamera(app: *App, op: []const []const u8) !void {
    try paint.cameraStep(app, op[1], try std.fmt.parseFloat(f32, op[2]));
    return app.reloadLevel();
}

/// `--cam-drag yaw|pitch|roll|pan|zoom DX,DY`: the camera gizmo's part dragged by DX,DY
/// pixels (zoom: DY wheel notches) in an 800×600 view.
fn opCamDrag(app: *App, op: []const []const u8) !void {
    if (app.paint == null) app.openPaint();
    const p = app.paint orelse return error.NoLevel;
    const d = app.doc orelse return error.NoLevel;
    p.tool = .camera;
    const rect: c.SDL_FRect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    var it = std.mem.splitScalar(u8, op[2], ',');
    const dx = try std.fmt.parseFloat(f32, it.next() orelse return error.BadPoint);
    const dy = try std.fmt.parseFloat(f32, it.next() orelse return error.BadPoint);
    if (std.mem.eql(u8, op[1], "zoom")) {
        if (!paint.cameraWheel(p, d, rect, .{ 400, 300 }, dy, false)) return error.NoCamera;
        return paint.camCommit(app, p);
    }
    const r = paint.gizmo_r;
    const at: [2]f32 = switch (std.meta.stringToEnum(paint.Ring, op[1]) orelse return error.BadRing) {
        .pan => .{ 400, 300 },
        .yaw => .{ 400 + r, 300 },
        .pitch => .{ 400, 300 - r },
        .roll => .{ 400 + r * 1.25, 300 },
    };
    if (!paint.cameraPress(p, rect, at)) return error.NoRing;
    paint.cameraDrag(p, d, rect, .{ at[0] + dx, at[1] + dy });
    return paint.cameraRelease(app, p);
}

fn opGridSplit(app: *App, op: []const []const u8) !void {
    if (app.paint == null) app.openPaint();
    return paint.gridSplitTo(app, app.paint orelse return error.NoLevel, try std.fmt.parseInt(u32, op[1], 10), try std.fmt.parseInt(u32, op[2], 10));
}

fn opDepthFit(app: *App, op: []const []const u8) !void {
    _ = op;
    if (app.paint == null) app.openPaint();
    const before = try paint.fitDepth(app, app.paint orelse return error.NoLevel, app.doc.?);
    return app.setStatus(tx.st_depth_fit, .{before});
}

/// `--paint-tool NAME`: the level edit mode (opened if not yet) with this tool.
fn opPaintTool(app: *App, op: []const []const u8) !void {
    if (app.paint == null) app.openPaint();
    const p = app.paint orelse return error.NoLevel;
    p.tool = std.meta.stringToEnum(paint.Tool, op[1]) orelse return error.BadTool;
}

fn opNewScene(app: *App, op: []const []const u8) !void {
    _ = op;
    return app.newScene();
}

fn opNewScript(app: *App, op: []const []const u8) !void {
    _ = op;
    return app.newScript();
}

/// `--effect NAME`: an effect shown; `--effect-add PNG`: a frame added to it.
fn opEffect(app: *App, op: []const []const u8) !void {
    app.setTab(.effects);
    return app.effect.sel.set(op[1]);
}

fn opEffectAdd(app: *App, op: []const []const u8) !void {
    return @import("effectpage.zig").addFrame(app, op[1]);
}

/// `--font NAME`: a font shown (Fonts tab); `--font-ttf FILE`: drawn anew from a TTF.
fn opFont(app: *App, op: []const []const u8) !void {
    app.setTab(.fonts);
    app.fonts.sel.set(op[1]);
    return @import("fontpage.zig").open(app, op[1]);
}

fn opFontTtf(app: *App, op: []const []const u8) !void {
    return @import("fontpage.zig").fromTtf(app, op[1]);
}

/// `--import-music FILE NAME` (NAME `-`: the file's): a track into voice.dat.
fn opImportMusic(app: *App, op: []const []const u8) !void {
    try @import("musicpage.zig").import(app, op[1], if (std.mem.eql(u8, op[2], "-")) null else op[2]);
    @import("convert.zig").wait(app);
    app.setTab(.music);
}

/// `--dlg DIALOGUE LINE OP` (OP: add, delete, up, down, text:WORDS, speaker:NAME).
fn opDlg(app: *App, op: []const []const u8) !void {
    const dlgedit = @import("dlgedit.zig");
    const f = try app.store.file("common/lang.dat", op[1]);
    const k = try std.fmt.parseInt(usize, op[2], 10);
    const o: dlgedit.Op = if (std.mem.eql(u8, op[3], "add")) .add_after else if (std.mem.eql(u8, op[3], "delete")) .delete else if (std.mem.eql(u8, op[3], "up")) .up else if (std.mem.eql(u8, op[3], "down")) .down else if (std.mem.startsWith(u8, op[3], "text:")) .{ .text = op[3][5..] } else if (std.mem.startsWith(u8, op[3], "speaker:")) .{ .speaker = op[3][8..] } else return error.BadOp;
    return dlgedit.apply(app, f, op[1], k, o);
}

/// `--text FILE ID TEXT` (FILE: strings, items, areas): a row of the game's texts.
fn opText(app: *App, op: []const []const u8) !void {
    const f = std.meta.stringToEnum(@import("texts.zig").File, op[1]) orelse return error.BadFile;
    try @import("texts.zig").set(app, f, try std.fmt.parseInt(i32, op[2], 10), op[3]);
    app.refreshTitles();
    app.setTab(.texts);
    app.texts.file = f;
}

/// `--scene-test LEVEL:SCENE`: the scene's Debug view after a test run.
fn opSceneTest(app: *App, op: []const []const u8) !void {
    const k = std.mem.indexOfScalar(u8, op[1], ':') orelse return error.BadScene;
    app.showScene(op[1][k + 1 ..]);
    app.scenes.view = .debug;
    return app.testScene(op[1][0..k], op[1][k + 1 ..]);
}

/// `--logic "CMDS" TICK`: the open level's Debug run with the player's commands, at TICK.
fn opLogic(app: *App, op: []const []const u8) !void {
    app.logic.cmds.clearRetainingCapacity();
    try app.logic.cmds.appendSlice(app.gpa, op[1]);
    logicview.run(app);
    const v = logicview.of(app) orelse return error.NotRun;
    v.tick = @min(v.tr.ticks -| 1, try std.fmt.parseInt(u32, op[2], 10));
}

/// `--open-key KEY`: a tree folder or a folded group opened (`objopen/sounds`).
fn opOpenKey(app: *App, op: []const []const u8) !void {
    return assettree.toggleKey(app, op[1]);
}

/// `--sprite ARCHIVE ENTRY`: a sprite opened; `--import-sprite ARCHIVE PNG`: a new one
/// (`icons` in the archive name's place: an icon of common/sprite.dat).
fn opSprite(app: *App, op: []const []const u8) !void {
    return sprview.openEntry(app, op[1], op[2]);
}

fn opImportSprite(app: *App, op: []const []const u8) !void {
    const icons_dir = std.mem.eql(u8, op[1], "icons");
    _ = try sprview.importNew(app, if (icons_dir) @import("store.zig").sprite_archive else op[1], if (icons_dir) "icons" else "", op[2]);
}

fn opAddFrame(app: *App, op: []const []const u8) !void {
    return sprview.addFrame(app, op[1]);
}

/// `--frame-out K PNG` / `--frame-in K PNG`: frame K (from 0) of the open sprite out / in.
fn opFrameOut(app: *App, op: []const []const u8) !void {
    return sprview.exportFrame(app, try std.fmt.parseInt(usize, op[1], 10), op[2]);
}

fn opFrameIn(app: *App, op: []const []const u8) !void {
    return sprview.importFrame(app, try std.fmt.parseInt(usize, op[1], 10), op[2]);
}

/// `--tree-dup KIND:NAME`, `--tree-menu KIND:NAME`: a tree row duplicated, or its menu shown.
fn opTreeDup(app: *App, op: []const []const u8) !void {
    const k = std.mem.indexOfScalar(u8, op[1], ':') orelse return error.BadItem;
    const it = treemenu.Item.of(std.meta.stringToEnum(treemenu.Kind, op[1][0..k]) orelse return error.BadItem, op[1][k + 1 ..]);
    if (op[0][7] == 'd') return treemenu.duplicate(app, it);
    app.mouse = .{ 200, 300 };
    return treemenu.open(app, it);
}

/// `--open TAB NAME`: a document shown as if its tab were clicked (`items bandage`).
fn opOpen(app: *App, op: []const []const u8) !void {
    return doctabs.openDoc(app, std.meta.stringToEnum(app_mod.Tab, op[1]) orelse return error.BadTab, op[2]);
}

fn opTree(app: *App, op: []const []const u8) !void {
    app.tree_query.set(op[1]);
}

fn opImportVideo(app: *App, op: []const []const u8) !void {
    app.fileChosen(.{ .kind = .video, .run = @import("videopage.zig").onVideoIn }, op[1]);
    @import("convert.zig").wait(app);
}

/// `--add-own NAME X,Y`: a party hero on the open battle at grid point X,Y.
fn opAddOwn(app: *App, op: []const []const u8) !void {
    var it = std.mem.splitScalar(u8, op[2], ',');
    return app.addOwn(op[1], .{ try std.fmt.parseFloat(f32, it.next() orelse return error.BadPoint), try std.fmt.parseFloat(f32, it.next() orelse return error.BadPoint) });
}

/// `--goto LEVEL:OBJECT` or `--goto scene:NAME`: a link followed as a click does.
fn opGoto(app: *App, op: []const []const u8) !void {
    const k = std.mem.indexOfScalar(u8, op[1], ':') orelse return error.BadGoto;
    if (std.mem.eql(u8, op[1][0..k], "scene")) app.link(true, op[1][k + 1 ..], null) else app.link(false, op[1][0..k], op[1][k + 1 ..]);
    return app.followLink();
}

/// `--info N`: row N of the shown page's Info clicked (after the page is drawn).
fn opInfo(app: *App, op: []const []const u8) !void {
    for (0..2) |_| ui_main.present(app, ui_main.frame(app, app.size, .{ 0, 0 }));
    const rows = @import("info.zig").last();
    const k = try std.fmt.parseInt(usize, op[1], 10);
    if (k >= rows.len) return error.NoSuchRow;
    @import("info.zig").follow(app, rows[k].to);
    return app.followLink();
}

fn opSceneRename(app: *App, op: []const []const u8) !void {
    return app.renameScene(op[1], op[2]);
}

/// `--new-location NAME`: a location (or battle) made from the open one.
fn opNewLocation(app: *App, op: []const []const u8) !void {
    return app.newLevel(op[1]);
}

/// `--put ARCHIVE:ENTRY PATH`: a file's text from a local file (bytes as they are).
fn opPut(app: *App, op: []const []const u8) !void {
    const k = std.mem.indexOfScalar(u8, op[1], ':') orelse return error.BadPut;
    const f = try app.store.file(op[1][0..k], op[1][k + 1 ..]);
    return app.store.replace(f, try Io.Dir.cwd().readFileAlloc(app.io, op[2], app.gpa, .limited(1 << 24)));
}

/// `--scene-point X,Y`: a point of the picked scene; `--add-hero ID X,Y` (background pixels).
fn opScenePoint(app: *App, op: []const []const u8) !void {
    var it = std.mem.splitScalar(u8, op[op.len - 1], ',');
    const b: [2]f32 = .{ try std.fmt.parseFloat(f32, it.next() orelse return error.BadPoint), try std.fmt.parseFloat(f32, it.next() orelse return error.BadPoint) };
    if (op[0][2] == 's') return paint.pointClick(app, b);
    for (app.catalog.entries.items, 0..) |e, k| if (e.kind == .hero and std.ascii.eqlIgnoreCase(e.id, op[1]) and !std.mem.startsWith(u8, e.archive, "common")) return app.addHero(k, b);
    return error.NoSuchHero;
}

fn opAreaDelete(app: *App, op: []const []const u8) !void {
    return app.deleteArea(op[1]);
}

/// `--rendered`: the level shown as the game draws it.
fn opRendered(app: *App, op: []const []const u8) !void {
    _ = op;
    app.rendered.on = true;
}

fn opRemoveHero(app: *App, op: []const []const u8) !void {
    return app.removeHero(op[1]);
}

/// `--area-move NAME DX,DY`: area NAME moved by DX,DY background pixels.
fn opAreaMove(app: *App, op: []const []const u8) !void {
    var it = std.mem.splitScalar(u8, op[2], ',');
    return app.moveArea(op[1], .{ try std.fmt.parseInt(i32, it.next() orelse return error.BadPoint, 10), try std.fmt.parseInt(i32, it.next() orelse return error.BadPoint, 10) });
}

fn opAreaRename(app: *App, op: []const []const u8) !void {
    return app.renameArea(op[1], op[2]);
}

/// `--voice NAME PATH`: line voice file NAME from a WAV/MP3; `--voice-copy FROM TO`.
fn opVoice(app: *App, op: []const []const u8) !void {
    return @import("voices.zig").importTo(app, op[1], op[2]);
}

fn opVoiceCopy(app: *App, op: []const []const u8) !void {
    return @import("voices.zig").copyTo(app, op[1], op[2]);
}

/// `--level-area X,Y;X,Y;…`: a trigger area with these corners (background pixels).
fn opLevelArea(app: *App, op: []const []const u8) !void {
    if (app.paint == null) app.openPaint();
    const p = app.paint orelse return error.NoLevel;
    var it = std.mem.splitScalar(u8, op[1], ';');
    while (it.next()) |pt| {
        var xy = std.mem.splitScalar(u8, pt, ',');
        try p.poly.append(app.gpa, .{ try std.fmt.parseInt(i32, xy.next() orelse return error.BadArea, 10), try std.fmt.parseInt(i32, xy.next() orelse return error.BadArea, 10) });
    }
    return paint.finishArea(app, p);
}

/// `--level-light X,Y[,X2,Y2]`: the light tool pressed at background point X,Y (a lamp
/// picked or put), dragged to X2,Y2 if given.
fn opLevelLight(app: *App, op: []const []const u8) !void {
    if (app.paint == null) app.openPaint();
    const p = app.paint orelse return error.NoLevel;
    var it = std.mem.splitScalar(u8, op[1], ',');
    var v: [4]f32 = undefined;
    var n: usize = 0;
    while (it.next()) |x| : (n += 1) {
        if (n == 4) return error.BadPoint;
        v[n] = try std.fmt.parseFloat(f32, x);
    }
    if (n != 2 and n != 4) return error.BadPoint;
    p.tool = .light;
    paint.lightPress(app, p, app.doc.?, v[0..2].*);
    if (n == 4) paint.lightDrag(p, app.doc.?, v[2..4].*);
    return paint.lightRelease(app, p);
}

/// `--level-exit LEVEL X,Y;X,Y;…`: an exit to LEVEL with these corners.
fn opLevelExit(app: *App, op: []const []const u8) !void {
    if (app.paint == null) app.openPaint();
    const p = app.paint orelse return error.NoLevel;
    p.tool = .exit;
    p.exit_to_len = @min(op[1].len, p.exit_to.len);
    @memcpy(p.exit_to[0..p.exit_to_len], op[1][0..p.exit_to_len]);
    var it = std.mem.splitScalar(u8, op[2], ';');
    while (it.next()) |pt| {
        var xy = std.mem.splitScalar(u8, pt, ',');
        try p.poly.append(app.gpa, .{ try std.fmt.parseInt(i32, xy.next() orelse return error.BadArea, 10), try std.fmt.parseInt(i32, xy.next() orelse return error.BadArea, 10) });
    }
    return paint.finishArea(app, p);
}

fn opLevelUndo(app: *App, op: []const []const u8) !void {
    _ = op;
    return if (app.paint) |p| {
        _ = paint.undo(app, p);
    };
}

fn opShow(app: *App, op: []const []const u8) !void {
    // `--show garcia:1`: with the reach map of its weapon 1 (0-based) open.
    const colon = std.mem.indexOfScalar(u8, op[1], ':');
    app.entry = try pages.entryById(app, op[1][0 .. colon orelse op[1].len]);
    if (colon) |k| app.reach_open = try std.fmt.parseInt(u32, op[1][k + 1 ..], 10);
}

fn opCopy(app: *App, op: []const []const u8) !void {
    return pages.copyEntry(app, try pages.entryById(app, op[1]));
}

fn opSound(app: *App, op: []const []const u8) !void {
    return pages.soundOp(app, op[1], op[2], op[3]);
}

fn opClassWeapon(app: *App, op: []const []const u8) !void {
    const n = try pages.swapClassWeapon(app, op[1], op[2], op[3]);
    return app.setStatus(tx.st_weapon_class, .{ op[2], op[3], n });
}

fn opImportSound(app: *App, op: []const []const u8) !void {
    return app.fileChosen(.{ .kind = .sound, .run = soundpage.onSoundIn }, op[1]);
}

fn opExportSound(app: *App, op: []const []const u8) !void {
    app.sound_sel.set(op[1]);
    return app.fileChosen(.{ .kind = .wav_out, .run = soundpage.onSoundOut }, op[2]);
}

fn opEntry(app: *App, op: []const []const u8) !void {
    const i = try pages.entryById(app, op[1]);
    app.entry = i;
    return pages.setField(app, app.catalog.entries.items[i], op[2], op[3]);
}

fn opMenuOpen(app: *App, op: []const []const u8) !void {
    const m = &(app.menu orelse return error.NoMenu);
    m.open = std.meta.stringToEnum(@TypeOf(m.open), op[1]) orelse return error.BadSection;
}

/// `--ask-delete NAME`: the confirmation for deleting object NAME shown.
fn opAskDelete(app: *App, op: []const []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    for (d.objects.items, 0..) |o, k| if (std.ascii.eqlIgnoreCase(o.name, op[1])) return app.askDelete(.object, k, o.name);
    return error.NoObject;
}

/// `--add-model MESH X,Y`: a 3D model stood on the location there.
fn opAddModel(app: *App, op: []const []const u8) !void {
    var it = std.mem.splitScalar(u8, op[2], ',');
    app.addActor(op[1], .{ try std.fmt.parseFloat(f32, it.next() orelse "0"), try std.fmt.parseFloat(f32, it.next() orelse "0") });
}

/// `--path NAME`: a walk path picked (Paths tool); `--path-node X,Y`: a node added to it.
fn opPath(app: *App, op: []const []const u8) !void {
    return app.paths.sel.set(op[1]);
}

fn opPathNode(app: *App, op: []const []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    var it = std.mem.splitScalar(u8, op[1], ',');
    const bg: [2]f32 = .{ try std.fmt.parseFloat(f32, it.next() orelse "0"), try std.fmt.parseFloat(f32, it.next() orelse "0") };
    for (0..2) |_| ui_main.present(app, ui_main.frame(app, app.size, .{ 0, 0 }));
    const v = App.viewportRect() orelse return error.NoView;
    app.paths.mode = .add;
    paths.press(app, d, v, d.toScreen(v, bg));
    app.paths.mode = .pick;
}

/// `--anim NAME`: a bitmap animation picked; `--anim-new SPRITE X,Y`: one made there.
fn opAnim(app: *App, op: []const []const u8) !void {
    return app.anims.sel.set(op[1]);
}

fn opAnimNew(app: *App, op: []const []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    var it = std.mem.splitScalar(u8, op[2], ',');
    levelanims.add(app, d, op[1], .{ try std.fmt.parseFloat(f32, it.next() orelse "0"), try std.fmt.parseFloat(f32, it.next() orelse "0") });
}

/// `--dup NAME`: object NAME duplicated beside itself (as Cmd+D).
fn opDup(app: *App, op: []const []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    for (d.objects.items, 0..) |o, k| if (std.ascii.eqlIgnoreCase(o.name, op[1])) return app.duplicate(k);
    return error.NoObject;
}

/// `--save-now`: a save between edits (`--save` saves after all of them).
fn opSaveNow(app: *App, op: []const []const u8) !void {
    _ = op;
    return app.save();
}

fn opPurge(app: *App, op: []const []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    _ = op;
    for (try d.orphans(app.frame.allocator())) |n| try d.dropFiles(n);
}

fn opRemove(app: *App, op: []const []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    for (d.objects.items, 0..) |o, k| if (std.ascii.eqlIgnoreCase(o.name, op[1])) {
        app.selected = k;
        return app.removeSelected();
    };
    return error.NoSuchObject;
}

fn opWalkIn(app: *App, op: []const []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    for (d.objects.items, 0..) |o, k| if (std.ascii.eqlIgnoreCase(o.name, op[1])) return d.toggleWalkIn(k);
    return error.NoSuchObject;
}

fn opWeapon(app: *App, op: []const []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    const en = try d.enemy(op[1]);
    for (en.wpn[0..en.n_wpn], en.wpn_class[0..en.n_wpn]) |w, ci| {
        const cur = app.store.files.items[ci orelse continue].entry;
        if (std.ascii.endsWithIgnoreCase(cur, op[2])) return pages.swapWeapon(app, w, cur["classes\\".len..], op[3]);
    }
    return error.NoSuchWeapon;
}

fn opProp(app: *App, op: []const []const u8) !void {
    const what = std.meta.stringToEnum(level.Prop, op[1]) orelse return error.BadProp;
    return app.addProp(what, .{ try std.fmt.parseFloat(f32, op[2]), try std.fmt.parseFloat(f32, op[3]) });
}

fn opTurn(app: *App, op: []const []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    for (d.objects.items, 0..) |o, k| if (std.ascii.eqlIgnoreCase(o.name, op[1])) return d.rotate(k, try std.fmt.parseFloat(f32, op[2]));
    return error.NoSuchObject;
}

fn opObstacle(app: *App, op: []const []const u8) !void {
    const what = std.meta.stringToEnum(level.Obstacle, op[1]) orelse return error.BadObstacle;
    return app.addObstacle(what, .{ try std.fmt.parseFloat(f32, op[2]), try std.fmt.parseFloat(f32, op[3]) });
}

fn opAddAt(app: *App, op: []const []const u8) !void {
    const g: [2]f32 = .{ try std.fmt.parseFloat(f32, op[2]), try std.fmt.parseFloat(f32, op[3]) };
    for (app.allTemplates(app.frame.allocator())) |t| if (std.ascii.eqlIgnoreCase(t.class, op[1])) return app.addEnemy(t, g);
    return error.NoSuchClass;
}

fn opNewBox(app: *App, op: []const []const u8) !void {
    app.addBox(.{ try std.fmt.parseFloat(f32, op[1]), try std.fmt.parseFloat(f32, op[2]) });
}

fn opSelect(app: *App, op: []const []const u8) !void {
    const dd = app.doc orelse return error.NoLevel;
    const name = std.mem.trimEnd(u8, op[1], "!");
    for (dd.objects.items, 0..) |o, k| if (std.ascii.eqlIgnoreCase(o.name, name)) {
        app.selected = k;
        // `--select NAME!`: its first weapon's class choice open too.
        if (app.selectedEnemy()) |en| if (en.n_wpn > 0 and std.mem.endsWith(u8, op[1], "!")) {
            app.picker = .{ .what = .enemy_weapon, .file = en.wpn[0] };
        };
        return;
    };
    return error.NoSuchObject;
}

fn opDeleteBox(app: *App, op: []const []const u8) !void {
    const dd = app.doc orelse return error.NoLevel;
    for (dd.objects.items, 0..) |o, k| if (std.ascii.eqlIgnoreCase(o.name, op[1])) {
        if (op[0][2] == 'd') return app.deleteBox(k);
        for (0..2) |_| ui_main.present(app, ui_main.frame(app, app.size, .{ 0, 0 }));
        app.mouse = .{ app.size[0] - 300, 200 };
        return app.openMenuFor(k);
    };
    return error.NoSuchObject;
}

fn opTrigger(app: *App, op: []const []const u8) !void {
    const dd = app.doc orelse return error.NoLevel;
    for (dd.objects.items) |o| if (o.kind == .area and std.ascii.eqlIgnoreCase(o.name, op[1])) {
        app.trigger = o.name;
        return;
    };
    return error.NoSuchArea;
}

fn opBox(app: *App, op: []const []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    for (d.objects.items) |o| if (std.ascii.eqlIgnoreCase(o.name, op[1])) {
        app.box = .{ .file = d.boxFile(o.name) orelse return error.NotABox, .name = o.name };
        return;
    };
    return error.NoSuchObject;
}

fn opClick(app: *App, op: []const []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    // A left click at screen point X, Y (after a layout), no drag.
    for (0..2) |_| ui_main.present(app, ui_main.frame(app, app.size, .{ 0, 0 }));
    app.mouse = .{ try std.fmt.parseFloat(f32, op[1]), try std.fmt.parseFloat(f32, op[2]) };
    app.clicked = true;
    ui_main.present(app, ui_main.frame(app, app.size, .{ 0, 0 }));
    app.clicked = false;
    app.moving = null;
    d.preview = null;
}

/// `--wheel X Y DY`: DY wheel notches with the mouse at screen point X, Y.
fn opWheel(app: *App, op: []const []const u8) !void {
    app.mouse = .{ try std.fmt.parseFloat(f32, op[1]), try std.fmt.parseFloat(f32, op[2]) };
    for (0..2) |_| ui_main.present(app, ui_main.frame(app, app.size, .{ 0, 0 }));
    ui_main.present(app, ui_main.frame(app, app.size, .{ 0, try std.fmt.parseFloat(f32, op[3]) }));
    for (0..2) |_| ui_main.present(app, ui_main.frame(app, app.size, .{ 0, 0 }));
}

/// `--strike-hero N`: the weapon page's striking hero, N-th in its list.
fn opStrikeHero(app: *App, op: []const []const u8) !void {
    app.attack_hero = try std.fmt.parseInt(usize, op[1], 10);
}

/// `--preview-frame N`: the model preview stopped on frame N of its animation.
fn opPreviewFrame(app: *App, op: []const []const u8) !void {
    // After the animation is shown (a new one starts on its first frame).
    for (0..2) |_| ui_main.present(app, ui_main.frame(app, app.size, .{ 0, 0 }));
    app.preview.paused = try std.fmt.parseInt(u32, op[1], 10);
}

/// `--adjust NAME VALUE`: an adjust.kdt value set (Engine settings).
fn opAdjust(app: *App, op: []const []const u8) !void {
    return @import("adjustpage.zig").setByName(app, op[1], op[2]);
}

fn opMenu(app: *App, op: []const []const u8) !void {
    // After a layout (the viewport's box): the menu at screen point X, Y.
    for (0..2) |_| ui_main.present(app, ui_main.frame(app, app.size, .{ 0, 0 }));
    app.mouse = .{ try std.fmt.parseFloat(f32, op[1]), try std.fmt.parseFloat(f32, op[2]) };
    return app.openMenu();
}

fn opAdd(app: *App, op: []const []const u8) !void {
    for (app.allTemplates(app.frame.allocator())) |t| if (std.ascii.eqlIgnoreCase(t.class, op[1])) return app.addEnemy(t, null);
    return error.NoSuchClass;
}

/// `--set NAME FIELD VALUE` on the enemy's own file, `--set-class` on its class.
fn opSet(app: *App, op: []const []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    const en = try d.enemy(op[1]);
    const names: []const []const u8 = if (std.mem.eql(u8, op[2], "hp")) &.{ "hp", "max_hp" } else op[2..3];
    if (std.mem.eql(u8, op[0], "--set")) return app.store.setVar(en.ftr, names, op[3], "#include ft_");
    return app.store.setVar(en.class orelse return error.NoClass, names, op[3], null);
}

/// `--move NAME X Y`: a background point on a location, a grid cell in a battle.
fn opMove(app: *App, op: []const []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    const name = op[1];
    const x = try std.fmt.parseFloat(f32, op[2]);
    const y = try std.fmt.parseFloat(f32, op[3]);
    for (d.objects.items, 0..) |o, i| {
        if (!std.ascii.eqlIgnoreCase(o.name, name)) continue;
        if (!d.isBattle()) {
            // Locations: X, Y are a background point.
            d.preview = .{ .obj = i, .bg = .{ x, y }, .ok = d.walkableAt(.{ x, y }) };
            return d.drop();
        }
        d.preview = .{ .obj = i, .tile = .{ @intFromFloat(x), @intFromFloat(y) }, .grid = .{ x, y } };
        d.preview.?.ok = if (o.grid != null) d.gridOpen(.{ x, y }) else d.canPlace(i, d.preview.?.tile);
        try d.drop();
        return;
    }
    return error.NoSuchObject;
}

/// `--package ORIGINAL OUT`: the mod packed into OUT (what differs from the game in ORIGINAL).
fn opPackage(app: *App, op: []const []const u8) !void {
    app.settings.setOriginalPath(op[1]);
    try app.packMod(op[2]);
}

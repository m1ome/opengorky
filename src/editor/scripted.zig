//! The editor's command line: the scripted edits (checks, scripts, demos), one function
//! each, by name and how many values each takes (`ops`); main.zig parses them with
//! `find` and runs them in order after loading.

const std = @import("std");
const Io = std.Io;
const c = @import("sdl");
const level = @import("level.zig");
const tx = @import("text.zig");
const entries = @import("entries.zig");
const boxpanel = @import("boxpanel.zig");
const soundpage = @import("soundpage.zig");
const sprview = @import("sprview.zig");
const paint = @import("paint.zig");
const scenepage = @import("scenepage.zig");
const checkpanel = @import("checkpanel.zig");
const assettree = @import("assettree.zig");
const doctabs = @import("doctabs.zig");
const treemenu = @import("treemenu.zig");
const levelanims = @import("levelanims.zig");
const logicview = @import("logicview.zig");
const paths = @import("paths.zig");
const codeview = @import("codeview.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const play = @import("play.zig");
const levelops = @import("levelops.zig");
const areas = @import("areas.zig");
const main = @import("main.zig");

const Handler = *const fn (*App, []const []const u8) anyerror!void;

/// Scripted edit `op[0]` with its values `op[1..]`.
pub fn run(app: *App, op: []const []const u8) !void {
    const o = find(op[0]) orelse return error.UnknownOp;
    // Ops run without frames between: the rules in force as a frame's start has them.
    @import("entry_rules.zig").sync(app);
    // The op sees its own name (an older one given: an alias).
    var named: [8][]const u8 = undefined;
    if (op.len > named.len) return error.UnknownOp;
    @memcpy(named[0..op.len], op);
    named[0] = o.name;
    return o.run(app, named[0..op.len]);
}

pub const Op = struct { name: []const u8, arity: u8, run: Handler };

/// Every scripted edit: its name on the command line, how many values it takes and its
/// function, in one table (the parser, the usage text and `run` read it).
pub const ops = [_]Op{
    .{ .name = "--add", .arity = 1, .run = opAdd },
    .{ .name = "--add-at", .arity = 3, .run = opAddAt },
    .{ .name = "--adjust", .arity = 2, .run = opAdjust },
    .{ .name = "--model-add", .arity = 2, .run = opAddModel },
    .{ .name = "--frame-add", .arity = 1, .run = opAddFrame },
    .{ .name = "--hero-add", .arity = 2, .run = opScenePoint },
    .{ .name = "--active", .arity = 0, .run = opActive },
    .{ .name = "--add-own", .arity = 2, .run = opAddOwn },
    .{ .name = "--anim", .arity = 1, .run = opAnim },
    .{ .name = "--anim-bind", .arity = 3, .run = opAnimBind },
    .{ .name = "--anim-autobind", .arity = 1, .run = opAnimBind },
    .{ .name = "--anim-new", .arity = 2, .run = opAnimNew },
    .{ .name = "--area-delete", .arity = 1, .run = opAreaDelete },
    .{ .name = "--area-move", .arity = 2, .run = opAreaMove },
    .{ .name = "--area-rename", .arity = 2, .run = opAreaRename },
    .{ .name = "--ask-delete", .arity = 1, .run = opAskDelete },
    .{ .name = "--box", .arity = 1, .run = opBox },
    .{ .name = "--box-add", .arity = 1, .run = opBoxAdd },
    .{ .name = "--cam-drag", .arity = 2, .run = opCamDrag },
    .{ .name = "--camera", .arity = 2, .run = opCamera },
    .{ .name = "--class-weapon", .arity = 3, .run = opClassWeapon },
    .{ .name = "--click", .arity = 2, .run = opClick },
    .{ .name = "--click-id", .arity = 2, .run = opClickId },
    .{ .name = "--tab-close", .arity = 1, .run = opCloseTab },
    .{ .name = "--tab-close-at", .arity = 2, .run = opCloseTab },
    .{ .name = "--code", .arity = 1, .run = opCode },
    .{ .name = "--code-view", .arity = 1, .run = opCodeView },
    .{ .name = "--code-at", .arity = 2, .run = opCodeAt },
    .{ .name = "--code-goto", .arity = 3, .run = opCodeGoto },
    .{ .name = "--code-hover", .arity = 2, .run = opCodeAt },
    .{ .name = "--code-menu", .arity = 2, .run = opCodeAt },
    .{ .name = "--code-usages", .arity = 0, .run = opCodeUsages },
    .{ .name = "--code-check-all", .arity = 0, .run = opCodeCheckAll },
    .{ .name = "--code-probe", .arity = 1, .run = opCodeProbe },
    .{ .name = "--copy", .arity = 1, .run = opCopy },
    .{ .name = "--copy-as", .arity = 2, .run = opCopyAs },
    .{ .name = "--box-delete", .arity = 1, .run = opDeleteBox },
    .{ .name = "--depth-fit", .arity = 0, .run = opDepthFit },
    .{ .name = "--dialog", .arity = 1, .run = opDialog },
    .{ .name = "--dlg", .arity = 3, .run = opDlg },
    .{ .name = "--drag", .arity = 4, .run = opDrag },
    .{ .name = "--dup", .arity = 1, .run = opDup },
    .{ .name = "--effect", .arity = 1, .run = opEffect },
    .{ .name = "--effect-add", .arity = 1, .run = opEffectAdd },
    .{ .name = "--effect-new", .arity = 0, .run = opEffectNew },
    .{ .name = "--entry", .arity = 3, .run = opEntry },
    .{ .name = "--glb-export", .arity = 2, .run = opArtFile },
    .{ .name = "--icon-export", .arity = 2, .run = opArtFile },
    .{ .name = "--sound-export", .arity = 2, .run = opExportSound },
    .{ .name = "--texture-export", .arity = 2, .run = opArtFile },
    .{ .name = "--font", .arity = 1, .run = opFont },
    .{ .name = "--fx-new", .arity = 1, .run = opFxNew },
    .{ .name = "--fx-part", .arity = 2, .run = opFxPart },
    .{ .name = "--fx-put", .arity = 3, .run = opFxPut },
    .{ .name = "--fx-copy", .arity = 2, .run = opFxCopy },
    .{ .name = "--font-ttf", .arity = 1, .run = opFontTtf },
    .{ .name = "--frame-in", .arity = 2, .run = opFrameIn },
    .{ .name = "--frame-out", .arity = 2, .run = opFrameOut },
    .{ .name = "--goto", .arity = 1, .run = opGoto },
    .{ .name = "--grid-split", .arity = 2, .run = opGridSplit },
    .{ .name = "--history", .arity = 0, .run = opHistory },
    .{ .name = "--history-old", .arity = 1, .run = opHistoryOld },
    .{ .name = "--icon", .arity = 1, .run = opIcon },
    .{ .name = "--anims-import", .arity = 2, .run = opArtFile },
    .{ .name = "--glb-import", .arity = 2, .run = opArtFile },
    .{ .name = "--glb-new", .arity = 1, .run = opGlbNew },
    .{ .name = "--model-delete", .arity = 1, .run = opModelDelete },
    .{ .name = "--model-export", .arity = 2, .run = opModelExport },
    .{ .name = "--icon-import", .arity = 2, .run = opArtFile },
    .{ .name = "--sound-import", .arity = 1, .run = opImportSound },
    .{ .name = "--texture-import", .arity = 2, .run = opArtFile },
    .{ .name = "--music-import", .arity = 2, .run = opImportMusic },
    .{ .name = "--sprite-import", .arity = 2, .run = opImportSprite },
    .{ .name = "--video-import", .arity = 1, .run = opImportVideo },
    .{ .name = "--info", .arity = 1, .run = opInfo },
    .{ .name = "--inventory", .arity = 1, .run = opInventory },
    .{ .name = "--key", .arity = 1, .run = opKey },
    .{ .name = "--level-area", .arity = 1, .run = opLevelArea },
    .{ .name = "--level-done", .arity = 0, .run = opLevelDone },
    .{ .name = "--level-exit", .arity = 2, .run = opLevelExit },
    .{ .name = "--level-light", .arity = 1, .run = opLevelLight },
    .{ .name = "--level-layer-in", .arity = 2, .run = opLevelLayerIn },
    .{ .name = "--level-paint", .arity = 1, .run = opLevelPaint },
    .{ .name = "--level-undo", .arity = 0, .run = opLevelUndo },
    .{ .name = "--level-copy", .arity = 2, .run = opLevelCopy },
    .{ .name = "--undo", .arity = 0, .run = opUndo },
    .{ .name = "--menu", .arity = 2, .run = opMenu },
    .{ .name = "--menu-obj", .arity = 1, .run = opDeleteBox },
    .{ .name = "--menu-open", .arity = 1, .run = opMenuOpen },
    .{ .name = "--modcheck", .arity = 0, .run = opModcheck },
    .{ .name = "--move", .arity = 3, .run = opMove },
    .{ .name = "--box-new", .arity = 2, .run = opNewBox },
    .{ .name = "--blank-new", .arity = 1, .run = opNewBlank },
    .{ .name = "--blank-size", .arity = 2, .run = opBlankSize },
    .{ .name = "--weapon-new", .arity = 0, .run = opNewWeapon },
    .{ .name = "--char-new", .arity = 0, .run = opNewChar },
    .{ .name = "--roles", .arity = 2, .run = opRoles },
    .{ .name = "--test-room", .arity = 1, .run = opTestRoom },
    .{ .name = "--test-kit", .arity = 1, .run = opTestKit },
    .{ .name = "--location-new", .arity = 1, .run = opNewLocation },
    .{ .name = "--scene-new", .arity = 0, .run = opNewScene },
    .{ .name = "--script-new", .arity = 0, .run = opNewScript },
    .{ .name = "--num", .arity = 2, .run = opNum },
    .{ .name = "--obstacle", .arity = 3, .run = opObstacle },
    .{ .name = "--open-key", .arity = 1, .run = opOpenKey },
    .{ .name = "--paint", .arity = 1, .run = opPaint },
    .{ .name = "--paint-tool", .arity = 1, .run = opPaintTool },
    .{ .name = "--path", .arity = 1, .run = opPath },
    .{ .name = "--path-link", .arity = 2, .run = opPathNode },
    .{ .name = "--path-new", .arity = 0, .run = opPathNew },
    .{ .name = "--path-delete", .arity = 1, .run = opPathDelete },
    .{ .name = "--path-node", .arity = 1, .run = opPathNode },
    .{ .name = "--level-play", .arity = 0, .run = opPlayLevel },
    .{ .name = "--prop", .arity = 3, .run = opProp },
    .{ .name = "--purge", .arity = 0, .run = opPurge },
    .{ .name = "--put", .arity = 2, .run = opPut },
    .{ .name = "--pick", .arity = 1, .run = opPick },
    .{ .name = "--query", .arity = 1, .run = opQuery },
    .{ .name = "--remove", .arity = 1, .run = opRemove },
    .{ .name = "--hero-remove", .arity = 1, .run = opRemoveHero },
    .{ .name = "--replace", .arity = 3, .run = opReplace },
    .{ .name = "--rendered", .arity = 0, .run = opRendered },
    .{ .name = "--video-replace", .arity = 2, .run = opReplaceVideo },
    .{ .name = "--roll-back", .arity = 1, .run = opRollBack },
    .{ .name = "--return-to", .arity = 1, .run = opReturnTo },
    .{ .name = "--save-now", .arity = 0, .run = opSaveNow },
    .{ .name = "--scene", .arity = 1, .run = opScene },
    .{ .name = "--scene-test", .arity = 1, .run = opSceneTest },
    .{ .name = "--logic", .arity = 2, .run = opLogic },
    .{ .name = "--open", .arity = 2, .run = opOpen },
    .{ .name = "--portraits-own", .arity = 1, .run = opOwnPortraits },
    .{ .name = "--rules-own", .arity = 1, .run = opOwnRules },
    .{ .name = "--package", .arity = 1, .run = opPackage },
    .{ .name = "--convert-ask", .arity = 1, .run = opConvertAsk },
    .{ .name = "--convert-start", .arity = 1, .run = opConvertStart },
    .{ .name = "--convert-to", .arity = 1, .run = opConvertTo },
    .{ .name = "--convert-cancel", .arity = 1, .run = opConvertCancel },
    .{ .name = "--scene-off", .arity = 1, .run = opSceneSkip },
    .{ .name = "--scene-point", .arity = 1, .run = opScenePoint },
    .{ .name = "--scene-rename", .arity = 2, .run = opSceneRename },
    .{ .name = "--scene-skip", .arity = 1, .run = opSceneSkip },
    .{ .name = "--ref", .arity = 1, .run = opRef },
    .{ .name = "--ref-search", .arity = 1, .run = opRef },
    .{ .name = "--select", .arity = 1, .run = opSelect },
    .{ .name = "--explodable", .arity = 2, .run = opExplodable },
    .{ .name = "--set", .arity = 3, .run = opSet },
    .{ .name = "--class-set", .arity = 3, .run = opSet },
    .{ .name = "--show", .arity = 1, .run = opShow },
    .{ .name = "--sound", .arity = 3, .run = opSound },
    .{ .name = "--preview-frame", .arity = 1, .run = opPreviewFrame },
    .{ .name = "--point", .arity = 2, .run = opPoint },
    .{ .name = "--point-drag", .arity = 3, .run = opPoint },
    .{ .name = "--hero-strike", .arity = 1, .run = opStrikeHero },
    .{ .name = "--sprite", .arity = 2, .run = opSprite },
    .{ .name = "--text", .arity = 3, .run = opText },
    .{ .name = "--tree", .arity = 1, .run = opTree },
    .{ .name = "--tree-dup", .arity = 1, .run = opTreeDup },
    .{ .name = "--tree-menu", .arity = 1, .run = opTreeDup },
    .{ .name = "--trigger", .arity = 1, .run = opTrigger },
    .{ .name = "--trigger-hero", .arity = 3, .run = opTriggerHero },
    .{ .name = "--trigger-off", .arity = 1, .run = opTriggerOff },
    .{ .name = "--engine-level", .arity = 1, .run = opEngineLevel },
    .{ .name = "--scene-view", .arity = 1, .run = opSceneView },
    .{ .name = "--turn", .arity = 2, .run = opTurn },
    .{ .name = "--type", .arity = 1, .run = opType },
    .{ .name = "--voice", .arity = 2, .run = opVoice },
    .{ .name = "--voice-copy", .arity = 2, .run = opVoiceCopy },
    .{ .name = "--walk", .arity = 0, .run = opWalk },
    .{ .name = "--wheel", .arity = 3, .run = opWheel },
    .{ .name = "--walk-in", .arity = 1, .run = opWalkIn },
    .{ .name = "--weapon", .arity = 3, .run = opWeapon },
    .{ .name = "--attack", .arity = 3, .run = opAttack },
    .{ .name = "--ai", .arity = 3, .run = opRule },
    .{ .name = "--weapon-fx", .arity = 3, .run = opRule },
    .{ .name = "--hero-rule", .arity = 3, .run = opRule },
    .{ .name = "--hero-bonus", .arity = 3, .run = opRule },
    .{ .name = "--campaign", .arity = 2, .run = opCampaign },
    .{ .name = "--exp-level", .arity = 2, .run = opExpLevel },
    .{ .name = "--value", .arity = 2, .run = opValue },
    .{ .name = "--scoring", .arity = 3, .run = opScoring },
    .{ .name = "--action", .arity = 3, .run = opAction },
    .{ .name = "--ai-profile", .arity = 3, .run = opAiProfile },
    .{ .name = "--row", .arity = 4, .run = opRow },
    .{ .name = "--ability", .arity = 3, .run = opAbility },
    .{ .name = "--og-set", .arity = 3, .run = opOgSet },
    .{ .name = "--og-attach", .arity = 4, .run = opOgAttach },
    .{ .name = "--og-inner", .arity = 4, .run = opOgInner },
    .{ .name = "--og-fighter", .arity = 2, .run = opOgFighter },
    .{ .name = "--og-remove", .arity = 1, .run = opOgRemove },
    .{ .name = "--og-name", .arity = 2, .run = opOgName },
    .{ .name = "--og-ammo", .arity = 2, .run = opOgAmmo },
    .{ .name = "--og-entry", .arity = 2, .run = opOgEntry },
    .{ .name = "--ability-new", .arity = 2, .run = opAbilityNew },
    .{ .name = "--material", .arity = 3, .run = opMaterial },
    .{ .name = "--post", .arity = 3, .run = opPost },
    .{ .name = "--post-for", .arity = 1, .run = opPostFor },
    .{ .name = "--level-post", .arity = 1, .run = opLevelPost },
    .{ .name = "--shell", .arity = 3, .run = opShell },
    .{ .name = "--wire", .arity = 0, .run = opWire },
    .{ .name = "--zone", .arity = 0, .run = opZone },
    .{ .name = "--strike-view", .arity = 0, .run = opStrikeView },
    .{ .name = "--zone-edit", .arity = 3, .run = opZoneEdit },
};

/// Older names (verb first) kept working: old → the op's name (`--<noun>-<verb>`).
const aliases = [_][2][]const u8{
    .{ "--add-model", "--model-add" },
    .{ "--add-frame", "--frame-add" },
    .{ "--add-hero", "--hero-add" },
    .{ "--close-tab", "--tab-close" },
    .{ "--delete-box", "--box-delete" },
    .{ "--export-glb", "--glb-export" },
    .{ "--export-icon", "--icon-export" },
    .{ "--export-sound", "--sound-export" },
    .{ "--export-texture", "--texture-export" },
    .{ "--import-anims", "--anims-import" },
    .{ "--import-glb", "--glb-import" },
    .{ "--import-icon", "--icon-import" },
    .{ "--import-sound", "--sound-import" },
    .{ "--import-texture", "--texture-import" },
    .{ "--import-music", "--music-import" },
    .{ "--import-sprite", "--sprite-import" },
    .{ "--import-video", "--video-import" },
    .{ "--new-box", "--box-new" },
    .{ "--new-blank", "--blank-new" },
    .{ "--new-weapon", "--weapon-new" },
    .{ "--new-location", "--location-new" },
    .{ "--new-scene", "--scene-new" },
    .{ "--new-script", "--script-new" },
    .{ "--own-portraits", "--portraits-own" },
    .{ "--own-rules", "--rules-own" },
    .{ "--play-level", "--level-play" },
    .{ "--remove-hero", "--hero-remove" },
    .{ "--replace-video", "--video-replace" },
    .{ "--strike-hero", "--hero-strike" },
    .{ "--set-class", "--class-set" },
};

// Each name once, every alias naming an op (checked when the editor builds).
comptime {
    @setEvalBranchQuota(200_000);
    for (ops, 0..) |o, i| for (ops[i + 1 ..]) |x| if (std.mem.eql(u8, o.name, x.name)) @compileError("twice: " ++ o.name);
    for (aliases) |al| {
        for (ops) |o| if (std.mem.eql(u8, o.name, al[0])) @compileError("alias is an op: " ++ al[0]);
        for (ops) |o| {
            if (std.mem.eql(u8, o.name, al[1])) break;
        } else @compileError("alias of nothing: " ++ al[1]);
    }
}

/// Op `arg` (by its name or an older one; the Op has its name).
pub fn find(arg: []const u8) ?Op {
    const name = for (aliases) |al| {
        if (std.mem.eql(u8, al[0], arg)) break al[1];
    } else arg;
    for (ops) |o| if (std.mem.eql(u8, o.name, name)) return o;
    return null;
}

/// The message (if any) and the usage on stderr; error.Usage.
pub fn fail(comptime fmt: []const u8, args: anytype) error{Usage} {
    if (fmt.len > 0) std.debug.print(fmt ++ "\n", args);
    std.debug.print("usage: opengorky-editor [game dir] [--level NAME] [--lang en|ru] [--tab TAB] [--shot out.png] [--save]\n  scripted edits, in order:\n", .{});
    for (ops) |o| {
        std.debug.print("    {s}", .{o.name});
        for (0..o.arity) |_| std.debug.print(" V", .{});
        std.debug.print("\n", .{});
    }
    return error.Usage;
}

/// `--pick ID`: the value list opened by element ID (`choice:0`: a numbered one) shown.
fn opPick(app: *App, op: []const []const u8) !void {
    const clay = @import("clay.zig");
    const colon = std.mem.indexOfScalar(u8, op[1], ':');
    @import("picker.zig").open(app, if (colon) |k| clay.idi(op[1][0..k], try std.fmt.parseInt(u32, op[1][k + 1 ..], 10)) else clay.id(op[1]));
}

fn opQuery(app: *App, op: []const []const u8) !void {
    app.query_name.set(op[1]);
    // The window's search begins again from it.
    if (@import("textedit.zig").typingIn(app, "window_search")) app.text_edit = null;
}

fn opArtFile(app: *App, op: []const []const u8) !void {
    // `ID#N`: the model's texture N (0 — its own).
    const hash = std.mem.indexOfScalar(u8, op[1], '#');
    const i = try entries.entryById(app, op[1][0 .. hash orelse op[1].len]);
    const slot: u8 = if (hash) |h| try std.fmt.parseInt(u8, op[1][h + 1 ..], 10) else 0;
    entries.showEntry(app, i);
    const em = @import("entry_model.zig");
    const handler: *const fn (*App, app_mod.FileAsk, []const u8) anyerror!void = if (std.mem.eql(u8, op[0], "--texture-export")) entries.onTextureOut else if (std.mem.eql(u8, op[0], "--icon-export")) entries.onIconOut else if (std.mem.eql(u8, op[0], "--icon-import")) entries.onIconIn else if (std.mem.eql(u8, op[0], "--glb-export")) em.onGlbOut else if (std.mem.eql(u8, op[0], "--glb-import")) em.onGlbIn else if (std.mem.eql(u8, op[0], "--anims-import")) em.onAnimsIn else entries.onTextureIn;
    return app.fileChosen(.{ .kind = .png, .run = handler, .entry = i, .slot = slot }, op[2]);
}

/// `--model-delete NAME`: the project's own unworn model deleted, as its page's button
/// confirmed (look_pages.deleteModel).
fn opModelDelete(app: *App, op: []const []const u8) !void {
    return @import("look_pages.zig").deleteModel(app, op[1]);
}

/// `--model-export NAME FILE`: model NAME (by its mesh name) to FILE, as its page's
/// "Export model (.glb)".
fn opModelExport(app: *App, op: []const []const u8) !void {
    doctabs.show(app, .models, op[1]);
    return @import("look_pages.zig").onGlbOut(app, .{ .kind = .glb_out, .run = @import("look_pages.zig").onGlbOut }, op[2]);
}

/// `--glb-new FILE`: a new model from FILE, only added (OpenGorky: the tree's Models).
fn opGlbNew(app: *App, op: []const []const u8) !void {
    app.fileChosen(.{ .kind = .glb, .run = @import("look_pages.zig").onGlbNew }, op[1]);
}

fn opSceneSkip(app: *App, op: []const []const u8) !void {
    return scenepage.scripted(app, app.frame.allocator(), op[0][8] == 's', op[1]);
}

fn opDialog(app: *App, op: []const []const u8) !void {
    return doctabs.show(app, .scenes, op[1]);
}

fn opScene(app: *App, op: []const []const u8) !void {
    app.showScene(op[1]);
}

fn opCode(app: *App, op: []const []const u8) !void {
    // `archive:entry` (e.g. `common/lang.dat:port_deska.dlg`), or an entry of the open level.
    if (std.mem.indexOfScalar(u8, op[1], ':')) |k| return doctabs.showCode(app, try app.store.file(op[1][0..k], op[1][k + 1 ..]), null);
    const dd = app.doc orelse return error.NoLevel;
    doctabs.showCode(app, if (std.mem.eql(u8, op[1], "lev")) dd.lev else try app.store.file(dd.level_archive, op[1]), null);
}

/// `--code-view ogs|classic`: the open Classic script as OG Script, or its own text.
fn opCodeView(app: *App, op: []const []const u8) !void {
    const v = app.code orelse return error.NoCode;
    @import("codetabs.zig").setView(app, v, std.mem.eql(u8, op[1], "ogs"));
    if (v.ogs_view != std.mem.eql(u8, op[1], "ogs")) return error.NoView;
}

/// `--code-at LINE COL`: the cursor there (both scrolls follow); `--code-hover LINE COL`:
/// the pointer resting on that character; `--code-menu LINE COL`: the right-click menu there.
fn opCodeAt(app: *App, op: []const []const u8) !void {
    const v = app.code orelse return error.NoCode;
    for (0..2) |_| main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    codeview.cursorTo(v, try std.fmt.parseInt(u32, op[1], 10), try std.fmt.parseInt(u32, op[2], 10));
    main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    if (std.mem.eql(u8, op[0], "--code-at")) return;
    app.mouse = codeview.pointOf(app, v, v.buf.cursor);
    if (std.mem.eql(u8, op[0], "--code-menu")) return codeview.openMenu(app, v);
    // Resting long enough for the tip.
    v.rest = app.mouse;
    v.rest_since = c.SDL_GetTicks() -% 1000;
}

/// `--code-goto FILE LINE COL`: FILE (as --code) opened, the cursor at LINE COL, Go to there.
fn opCodeGoto(app: *App, op: []const []const u8) !void {
    try opCode(app, op[0..2]);
    const v = app.code orelse return error.NoCode;
    for (0..2) |_| main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    codeview.cursorTo(v, try std.fmt.parseInt(u32, op[2], 10), try std.fmt.parseInt(u32, op[3], 10));
    main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    codeview.goTo(app, v);
    app.followLink();
}

/// `--code-check-all`: every script and rules file checked, the problems printed.
fn opCodeCheckAll(app: *App, op: []const []const u8) !void {
    _ = op;
    try codeview.checkAll(app);
}

/// `--code-probe PREFIX`: what Go to, the tip and completion know in the texts under PREFIX (codeprobe.zig).
fn opCodeProbe(app: *App, op: []const []const u8) !void {
    try @import("codeprobe.zig").run(app, op[1]);
}

/// `--code-usages`: Find usages of the word at the cursor.
fn opCodeUsages(app: *App, op: []const []const u8) !void {
    _ = op;
    codeview.findUsages(app, app.code orelse return error.NoCode);
}

fn opType(app: *App, op: []const []const u8) !void {
    for (0..2) |_| main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    // No code open: into the field typed into.
    const v = app.code orelse return app.typed(op[1]);
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
        else => codeview.typed(app, v, &.{ch}),
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

/// `--strike-view`: a weapon page shows a hero striking with it.
fn opStrikeView(app: *App, op: []const []const u8) !void {
    _ = op;
    app.entry_view = .strike;
}

/// `--zone`: a weapon page shows its damage zone instead of the model.
fn opZone(app: *App, op: []const []const u8) !void {
    _ = op;
    app.entry_view = .zone;
}

/// `--zone-edit CLASS WHAT VALUE`: an edit of weapon class CLASS's damage zone (zone_edit.zig).
fn opZoneEdit(app: *App, op: []const []const u8) !void {
    return @import("zone_edit.zig").scripted(app, try std.fmt.parseInt(i32, op[1], 10), op[2], op[3]);
}

/// `--num ID VALUE`: VALUE typed into the level panel's stepper ID (Enter), applied on the next frame.
fn opNum(app: *App, op: []const []const u8) !void {
    var e: @import("textedit.zig").Edit = .{ .id = @import("clay.zig").id(try std.fmt.allocPrint(app.frame.allocator(), "{s}_n", .{op[1]})), .entered = true };
    e.field.add(op[2]);
    app.text_given = e;
    for (0..2) |_| main.present(app, main.frame(app, app.size, .{ 0, 0 }));
}

fn opPlayLevel(app: *App, op: []const []const u8) !void {
    _ = op;
    return play.playLevel(app);
}

fn opHistory(app: *App, op: []const []const u8) !void {
    _ = op;
    app.setTab(.history);
    app.history_pick = .{ .session = app.store.undo.items.len };
}

fn opRollBack(app: *App, op: []const []const u8) !void {
    return app.rollBack(try std.fmt.parseInt(usize, op[1], 10));
}

/// History tab with an earlier session's save `op[1]` picked (0: the original).
fn opHistoryOld(app: *App, op: []const []const u8) !void {
    app.setTab(.history);
    app.history_pick = .{ .past = try std.fmt.parseInt(usize, op[1], 10) };
}

fn opReturnTo(app: *App, op: []const []const u8) !void {
    return app.returnToPast(try std.fmt.parseInt(usize, op[1], 10));
}

fn opBoxAdd(app: *App, op: []const []const u8) !void {
    return boxpanel.addClass(app, app.frame.allocator(), app.box orelse return error.NoBox, op[1]);
}

fn opInventory(app: *App, op: []const []const u8) !void {
    return entries.openInventory(app, try entries.entryById(app, op[1]));
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
    return levelops.newScene(app);
}

fn opNewScript(app: *App, op: []const []const u8) !void {
    _ = op;
    return app.newScript();
}

/// `--effect NAME`: an effect shown; `--effect-add PNG`: a frame added to it.
fn opEffect(app: *App, op: []const []const u8) !void {
    doctabs.show(app, .effects, op[1]);
}

/// `--effect-new`: a new effect from scratch (effectpage.newEffect), shown.
fn opEffectNew(app: *App, op: []const []const u8) !void {
    _ = op;
    app.setTab(.effects);
    _ = try @import("effectpage.zig").newEffect(app);
}

fn opEffectAdd(app: *App, op: []const []const u8) !void {
    return @import("effectpage.zig").addFrame(app, op[1]);
}

/// `--font NAME`: a font shown (Fonts tab); `--font-ttf FILE`: drawn anew from a TTF.
fn opFont(app: *App, op: []const []const u8) !void {
    doctabs.show(app, .fonts, op[1]);
    return @import("fontpage.zig").open(app, op[1]);
}

fn opFontTtf(app: *App, op: []const []const u8) !void {
    return @import("fontpage.zig").fromTtf(app, op[1]);
}

/// `--music-import FILE NAME` (NAME `-`: the file's): a track into voice.dat.
fn opImportMusic(app: *App, op: []const []const u8) !void {
    try @import("musicpage.zig").import(app, op[1], if (std.mem.eql(u8, op[2], "-")) null else op[2]);
    @import("convert.zig").wait(app);
    app.setTab(.music);
}

/// `--dlg DIALOGUE LINE OP` (OP: add, delete, up, down, text:WORDS, speaker:NAME; OpenGorky:
/// voice:FILE and voice-file:PATH, a new recording from a sound file, too). DIALOGUE: `x.dlg`, on OpenGorky the block `dialog "x"` (`src/dialogs/x.ogs`).
fn opDlg(app: *App, op: []const []const u8) !void {
    const dlgedit = @import("dlgedit.zig");
    const stem = if (std.ascii.endsWithIgnoreCase(op[1], ".dlg")) op[1][0 .. op[1].len - 4] else op[1];
    const f = if (app.store.root != null) try app.store.file(@import("store.zig").og_src, try std.fmt.allocPrint(app.frame.allocator(), "dialogs/{s}.ogs", .{stem})) else try app.store.file("common/lang.dat", op[1]);
    const k = try std.fmt.parseInt(usize, op[2], 10);
    if (std.mem.startsWith(u8, op[3], "voice-file:")) return dlgedit.voiceFromFile(app, f, op[1], k, op[3]["voice-file:".len..]);
    const o: dlgedit.Op = if (std.mem.eql(u8, op[3], "add")) .add_after else if (std.mem.eql(u8, op[3], "delete")) .delete else if (std.mem.eql(u8, op[3], "up")) .up else if (std.mem.eql(u8, op[3], "down")) .down else if (std.mem.startsWith(u8, op[3], "text:")) .{ .text = op[3][5..] } else if (std.mem.startsWith(u8, op[3], "speaker:")) .{ .speaker = op[3][8..] } else if (std.mem.startsWith(u8, op[3], "voice:")) .{ .voice = op[3][6..] } else return error.BadOp;
    return dlgedit.apply(app, f, op[1], k, o);
}

/// `--text FILE ID TEXT` (FILE: strings, items, areas): a row of the game's texts.
fn opText(app: *App, op: []const []const u8) !void {
    const f = std.meta.stringToEnum(@import("texts.zig").File, op[1]) orelse return error.BadFile;
    try @import("texts.zig").set(app, f, try std.fmt.parseInt(i32, op[2], 10), op[3]);
    app.refreshTitles();
    doctabs.show(app, .texts, f.entry());
}

/// `--scene-test LEVEL:SCENE`: the scene's Debug view after a test run.
fn opSceneTest(app: *App, op: []const []const u8) !void {
    const k = std.mem.indexOfScalar(u8, op[1], ':') orelse return error.BadScene;
    app.showScene(op[1][k + 1 ..]);
    app.scenes.view = .debug;
    return play.testScene(app, op[1][0..k], op[1][k + 1 ..]);
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

/// `--sprite ARCHIVE ENTRY`: a sprite opened; `--sprite-import ARCHIVE PNG`: a new one
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
    return doctabs.show(app, @import("doctab.zig").parse(op[1]) orelse return error.BadTab, op[2]);
}

/// `--key cmd+d`: a key pressed (after a layout), as the window gets it (`cmd`, `shift`, `alt`
/// before an SDL key name).
fn opKey(app: *App, op: []const []const u8) !void {
    for (0..2) |_| main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    var ev = std.mem.zeroes(c.SDL_KeyboardEvent);
    var it = std.mem.splitBackwardsScalar(u8, op[1], '+');
    var name: [32]u8 = @splat(0);
    const k = it.first();
    if (k.len >= name.len) return error.BadKey;
    @memcpy(name[0..k.len], k);
    ev.key = c.SDL_GetKeyFromName(&name);
    if (ev.key == c.SDLK_UNKNOWN) return error.BadKey;
    while (it.next()) |m| ev.mod |= if (std.mem.eql(u8, m, "cmd")) c.SDL_KMOD_GUI else if (std.mem.eql(u8, m, "shift")) c.SDL_KMOD_SHIFT else if (std.mem.eql(u8, m, "alt")) c.SDL_KMOD_ALT else if (std.mem.eql(u8, m, "ctrl")) c.SDL_KMOD_CTRL else return error.BadKey;
    @import("events.zig").keyDown(app, ev);
}

fn opTree(app: *App, op: []const []const u8) !void {
    app.tree_query.set(op[1]);
}

/// `--video-replace NAME FILE`: game video NAME replaced by FILE (videopage.replace).
fn opReplaceVideo(app: *App, op: []const []const u8) !void {
    doctabs.show(app, .videos, op[1]);
    try @import("videopage.zig").replace(app, op[1], op[2]);
    @import("convert.zig").wait(app);
}

fn opImportVideo(app: *App, op: []const []const u8) !void {
    app.fileChosen(.{ .kind = .video, .run = @import("videopage.zig").onVideoIn }, op[1]);
    @import("convert.zig").wait(app);
}

/// `--add-own NAME X,Y`: a party hero on the open battle at grid point X,Y.
fn opAddOwn(app: *App, op: []const []const u8) !void {
    var it = std.mem.splitScalar(u8, op[2], ',');
    return levelops.addOwn(app, op[1], .{ try std.fmt.parseFloat(f32, it.next() orelse return error.BadPoint), try std.fmt.parseFloat(f32, it.next() orelse return error.BadPoint) });
}

/// `--active`: the shown document (the tree's highlight) and the picked object printed,
/// `active TAB KEY OBJECT` (checks: every way of opening a document ends the same).
fn opActive(app: *App, _: []const []const u8) !void {
    doctabs.refresh(app);
    const d = app.active orelse return std.debug.print("active none\n", .{});
    const obj = if (app.doc) |dd| if (app.selected) |k| dd.objects.items[k].name else "" else "";
    std.debug.print("active {t} {s} {s}\n", .{ d.tab, d.key(), obj });
}

/// `--goto LEVEL:OBJECT` or `--goto scene:NAME`: a link followed as a click does.
fn opGoto(app: *App, op: []const []const u8) !void {
    const k = std.mem.indexOfScalar(u8, op[1], ':') orelse return error.BadGoto;
    if (std.mem.eql(u8, op[1][0..k], "scene")) app.link(true, op[1][k + 1 ..], null) else app.link(false, op[1][0..k], op[1][k + 1 ..]);
    return app.followLink();
}

/// `--info N`: row N of the shown page's Info clicked (after the page is drawn).
fn opInfo(app: *App, op: []const []const u8) !void {
    for (0..2) |_| main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    const rows = @import("info.zig").last();
    const k = try std.fmt.parseInt(usize, op[1], 10);
    if (k >= rows.len) return error.NoSuchRow;
    @import("info.zig").follow(app, rows[k].to);
    return app.followLink();
}

fn opSceneRename(app: *App, op: []const []const u8) !void {
    return levelops.renameScene(app, op[1], op[2]);
}

/// `--location-new NAME`: a location (or battle) made from the open one.
fn opNewLocation(app: *App, op: []const []const u8) !void {
    return levelops.newLevel(app, op[1]);
}

/// `--weapon-new`: a weapon from scratch (entries.newWeapon), shown.
fn opNewWeapon(app: *App, op: []const []const u8) !void {
    _ = op;
    app.setTab(.items);
    return entries.newWeapon(app);
}

/// `--char-new`: a character from scratch (entries.newCharacter; OpenGorky), shown.
fn opNewChar(app: *App, op: []const []const u8) !void {
    _ = op;
    return entries.newCharacter(app);
}

/// `--test-room ID`: the test room made for character ID (testroom.make), not played.
fn opTestRoom(app: *App, op: []const []const u8) !void {
    const i = try entries.entryById(app, op[1]);
    // An OpenGorky project: the build's room (dist/play.ogp), its fighter of the archetype.
    if (app.store.root != null) return play.buildRoom(app, app.catalog.entries.items[i].class);
    return @import("testroom.zig").make(app, i, null);
}

/// `--test-kit LINE`: a line added to the test kit (testkit.addLine).
fn opTestKit(app: *App, op: []const []const u8) !void {
    return @import("testkit.zig").addLine(app, op[1]);
}

fn opRoles(app: *App, op: []const []const u8) !void {
    return entries.setRoles(app, try entries.entryById(app, op[1]), op[2]);
}

/// `--blank-size W H`: the next blank level's picture size.
fn opBlankSize(app: *App, op: []const []const u8) !void {
    app.blank_size = .{ try std.fmt.parseInt(u32, op[1], 10), try std.fmt.parseInt(u32, op[2], 10) };
}

/// `--blank-new NAME`: a blank level (a battle by an `NN__` name).
fn opNewBlank(app: *App, op: []const []const u8) !void {
    return levelops.blankLevel(app, op[1]);
}

/// `--put ARCHIVE:ENTRY PATH`: a file's text from a local file (bytes as they are).
fn opPut(app: *App, op: []const []const u8) !void {
    const k = std.mem.indexOfScalar(u8, op[1], ':') orelse return error.BadPut;
    const f = try app.store.file(op[1][0..k], op[1][k + 1 ..]);
    return app.store.replace(f, try Io.Dir.cwd().readFileAlloc(app.io, op[2], app.gpa, .limited(1 << 24)));
}

/// `--scene-point X,Y`: a point of the picked scene; `--hero-add ID X,Y` (background pixels).
fn opScenePoint(app: *App, op: []const []const u8) !void {
    var it = std.mem.splitScalar(u8, op[op.len - 1], ',');
    const b: [2]f32 = .{ try std.fmt.parseFloat(f32, it.next() orelse return error.BadPoint), try std.fmt.parseFloat(f32, it.next() orelse return error.BadPoint) };
    if (op[0][2] == 's') return paint.pointClick(app, b);
    for (app.catalog.entries.items, 0..) |e, k| if (e.kind == .hero and std.ascii.eqlIgnoreCase(e.id, op[1]) and !std.mem.startsWith(u8, e.archive, "common")) return levelops.addHero(app, k, b);
    return error.NoSuchHero;
}

fn opAreaDelete(app: *App, op: []const []const u8) !void {
    return areas.deleteArea(app, op[1]);
}

/// `--rendered`: the level shown as the game draws it.
fn opRendered(app: *App, op: []const []const u8) !void {
    _ = op;
    app.rendered.on = true;
}

fn opRemoveHero(app: *App, op: []const []const u8) !void {
    return levelops.removeHero(app, op[1]);
}

/// `--area-move NAME DX,DY`: area NAME moved by DX,DY background pixels.
fn opAreaMove(app: *App, op: []const []const u8) !void {
    var it = std.mem.splitScalar(u8, op[2], ',');
    return areas.moveArea(app, op[1], .{ try std.fmt.parseInt(i32, it.next() orelse return error.BadPoint, 10), try std.fmt.parseInt(i32, it.next() orelse return error.BadPoint, 10) });
}

fn opAreaRename(app: *App, op: []const []const u8) !void {
    return areas.renameArea(app, op[1], op[2]);
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

/// `--level-layer-in LAYER PATH`: a layer from a PNG, as the panel's button (a
/// location's picture of another size resizes the level; it reloads).
fn opLevelLayerIn(app: *App, op: []const []const u8) !void {
    if (app.paint == null) app.openPaint();
    const p = app.paint orelse return error.NoLevel;
    try paint.importLayer(app, p, std.meta.stringToEnum(paint.Layer, op[1]) orelse return error.BadPaint, op[2]);
    if (p.pending == .reload) app.reloadLevel();
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

/// `--undo`: the last edit undone (Ctrl+Z).
fn opUndo(app: *App, op: []const []const u8) !void {
    _ = op;
    app.undo();
}

/// `--level-copy LEVEL NEW`: level LEVEL copied as NEW (the tree's Duplicate).
fn opLevelCopy(app: *App, op: []const []const u8) !void {
    return levelops.copyLevel(app, op[1], op[2]);
}

fn opShow(app: *App, op: []const []const u8) !void {
    // `--show garcia:1`: with the reach map of its weapon 1 (0-based) open.
    const colon = std.mem.indexOfScalar(u8, op[1], ':');
    entries.showEntry(app, try entries.entryById(app, op[1][0 .. colon orelse op[1].len]));
    if (colon) |k| app.reach_open = try std.fmt.parseInt(u32, op[1][k + 1 ..], 10);
}

/// `--ref NAME`: the Reference on article NAME (a function, callback, hook, rules call or
/// setting); `--ref-search TEXT`: the Reference searching TEXT.
fn opRef(app: *App, op: []const []const u8) !void {
    const reference = @import("reference.zig");
    if (std.mem.eql(u8, op[0], "--ref-search")) {
        reference.open(app, null);
        return app.reference.filter.set(op[1]);
    }
    reference.open(app, reference.find(op[1]) orelse return error.NoSuchArticle);
}

fn opCopy(app: *App, op: []const []const u8) !void {
    return entries.copyEntry(app, try entries.entryById(app, op[1]));
}

/// `--copy-as ID same|new_id|party|level` (entries.CopyMode).
fn opCopyAs(app: *App, op: []const []const u8) !void {
    return entries.copyEntryAs(app, try entries.entryById(app, op[1]), std.meta.stringToEnum(entries.CopyMode, op[2]) orelse return error.BadMode);
}

/// `--rules-own ID`: the entry's rules by its class ("Make own rules", entry_rules).
fn opOwnRules(app: *App, op: []const []const u8) !void {
    const e = app.catalog.entries.items[try entries.entryById(app, op[1])];
    const rules = @import("entry_rules.zig");
    const w: @import("opengorky").rules.Who = .{ .id = e.name_id orelse 0, .class = rules.classOf(e) };
    return rules.writeOwn(app, w, w, true);
}

/// `--replace ARCHIVE:ENTRY OLD NEW`: text OLD of a file made NEW (one undo step).
fn opReplace(app: *App, op: []const []const u8) !void {
    const k = std.mem.indexOfScalar(u8, op[1], ':') orelse return error.BadFile;
    return app.store.replaceText(try app.store.file(op[1][0..k], op[1][k + 1 ..]), op[2], op[3]);
}

fn opOwnPortraits(app: *App, op: []const []const u8) !void {
    return entries.ownPortraits(app, try entries.entryById(app, op[1]));
}

/// `--trigger-hero AREA HERO join|leave`: the party change in area AREA's block.
fn opTriggerHero(app: *App, op: []const []const u8) !void {
    const join = std.mem.eql(u8, op[3], "join");
    if (!join and !std.mem.eql(u8, op[3], "leave")) return error.BadMode;
    return @import("triggerpanel.zig").partyCall(app, op[1], op[2], join);
}

fn opSound(app: *App, op: []const []const u8) !void {
    return entries.soundOp(app, op[1], op[2], op[3]);
}

/// `--point MESH I`: model MESH's page, attach point I picked; `--point-drag MESH I DX,DY`:
/// then dragged DX, DY pixels on its preview (after a frame drawn, as the mouse does).
fn opPoint(app: *App, op: []const []const u8) !void {
    const em = @import("entry_model.zig");
    const i = try std.fmt.parseInt(usize, op[2], 10);
    try em.pointOp(app, op[1], i, null);
    if (op.len < 4) return;
    for (0..2) |_| main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    var it = std.mem.splitScalar(u8, op[3], ',');
    const d = [2]f32{ try std.fmt.parseFloat(f32, it.next() orelse "0"), try std.fmt.parseFloat(f32, it.next() orelse "0") };
    return em.pointOp(app, op[1], i, d);
}

fn opClassWeapon(app: *App, op: []const []const u8) !void {
    const n = try entries.swapClassWeapon(app, op[1], op[2], op[3]);
    return app.setStatus(tx.st_weapon_class, .{ op[2], op[3], n });
}

fn opImportSound(app: *App, op: []const []const u8) !void {
    return app.fileChosen(.{ .kind = .sound, .run = soundpage.onSoundIn }, op[1]);
}

fn opExportSound(app: *App, op: []const []const u8) !void {
    doctabs.show(app, .sounds, op[1]);
    return app.fileChosen(.{ .kind = .wav_out, .run = soundpage.onSoundOut }, op[2]);
}

fn opEntry(app: *App, op: []const []const u8) !void {
    const i = try entries.entryById(app, op[1]);
    entries.showEntry(app, i);
    return entries.setField(app, app.catalog.entries.items[i], op[2], op[3]);
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

/// `--model-add MESH X,Y`: a 3D model stood on the location there.
fn opAddModel(app: *App, op: []const []const u8) !void {
    var it = std.mem.splitScalar(u8, op[2], ',');
    app.addActor(op[1], .{ try std.fmt.parseFloat(f32, it.next() orelse "0"), try std.fmt.parseFloat(f32, it.next() orelse "0") });
}

/// `--path NAME`: a walk path picked (Paths tool); `--path-new`: one made (and picked),
/// `--path-delete NAME` one deleted (as confirmed);
/// `--path-node X,Y`: a node added to it; `--path-link start|end X,Y`: its start or end
/// cell set at background point X,Y (as clicked).
fn opPath(app: *App, op: []const []const u8) !void {
    return app.paths.sel.set(op[1]);
}

fn opPathNew(app: *App, op: []const []const u8) !void {
    _ = op;
    const d = app.doc orelse return error.NoLevel;
    paths.newPath(app, d, paths.load(app, d));
}

fn opPathDelete(app: *App, op: []const []const u8) !void {
    paths.remove(app, app.doc orelse return error.NoLevel, op[1]);
}

fn opPathNode(app: *App, op: []const []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    var it = std.mem.splitScalar(u8, op[op.len - 1], ',');
    const bg: [2]f32 = .{ try std.fmt.parseFloat(f32, it.next() orelse "0"), try std.fmt.parseFloat(f32, it.next() orelse "0") };
    for (0..2) |_| main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    const v = App.viewportRect() orelse return error.NoView;
    app.paths.mode = if (op.len > 2) std.meta.stringToEnum(paths.Mode, op[1]) orelse return error.BadMode else .add;
    paths.press(app, d, v, d.toScreen(v, bg));
    app.paths.mode = .pick;
}

/// `--anim NAME`: a bitmap animation picked; `--anim-new SPRITE X,Y`: one made there.
fn opAnim(app: *App, op: []const []const u8) !void {
    return app.anims.sel.set(op[1]);
}

/// `--anim-bind ID SLOT ANIM`, `--anim-autobind ID`: an entry's animation bindings.
fn opAnimBind(app: *App, op: []const []const u8) !void {
    const ea = @import("entry_anims.zig");
    return if (op.len > 3) ea.bindOp(app, op[1], op[2], op[3]) else ea.bindOp(app, op[1], null, "");
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
        if (std.ascii.endsWithIgnoreCase(cur, op[2])) return entries.swapWeapon(app, w, cur["classes\\".len..], op[3]);
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

/// `--explodable NAME 0|1`: an obstacle's `explodable` (levelpanel.zig).
fn opExplodable(app: *App, op: []const []const u8) !void {
    const lp = @import("levelpanel.zig");
    const d = app.doc orelse return error.NoLevel;
    const f = try app.store.file(d.level_archive, lp.scriptOf(d, op[1]) orelse return error.NoSuchObject);
    try lp.setExplodable(app, f, std.mem.eql(u8, op[2], "1"));
}

fn opSelect(app: *App, op: []const []const u8) !void {
    const dd = app.doc orelse return error.NoLevel;
    const name = std.mem.trimEnd(u8, op[1], "!");
    for (dd.objects.items, 0..) |o, k| if (std.ascii.eqlIgnoreCase(o.name, name)) {
        app.selected = k;
        // `--select NAME!`: its first weapon's class choice open too.
        if (app.selectedEnemy()) |en| if (en.n_wpn > 0 and std.mem.endsWith(u8, op[1], "!")) {
            @import("picker.zig").open(app, @import("entry_weapons.zig").changeId(en.wpn[0]));
        };
        return;
    };
    return error.NoSuchObject;
}

fn opDeleteBox(app: *App, op: []const []const u8) !void {
    const dd = app.doc orelse return error.NoLevel;
    for (dd.objects.items, 0..) |o, k| if (std.ascii.eqlIgnoreCase(o.name, op[1])) {
        if (std.mem.eql(u8, op[0], "--box-delete")) return app.deleteBox(k);
        for (0..2) |_| main.present(app, main.frame(app, app.size, .{ 0, 0 }));
        app.mouse = .{ app.size[0] - 300, 200 };
        return app.openMenuFor(k);
    };
    return error.NoSuchObject;
}

/// `--trigger-off AREA`: the first block naming the area turned off (triggerpanel.turnOff),
/// the trigger window shown.
fn opTriggerOff(app: *App, op: []const []const u8) !void {
    try @import("triggerpanel.zig").turnOff(app, op[1]);
    return opTrigger(app, op);
}

/// `--engine-level LEVEL`: level LEVEL opened by the engine's reader as a new world would be
/// (the project's files on disk, its own assets in src/assets/: not the editor's Store),
/// its background's size printed (`engine LEVEL: background W×H`) — what the engine sees now.
fn opEngineLevel(app: *App, op: []const []const u8) !void {
    const opener: @import("opengorky").loaders.world.Opener = .{ .io = app.io, .dat = app.dat };
    const src = try opener.factory().openLevel(app.gpa, op[1]);
    defer src.deinit();
    const sz = src.backgroundSize() orelse [2]u32{ 0, 0 };
    std.debug.print("engine {s}: background {d}×{d}\n", .{ op[1], sz[0], sz[1] });
}

/// `--scene-view overview|lines|debug`: the scene page's view.
fn opSceneView(app: *App, op: []const []const u8) !void {
    app.scenes.view = std.meta.stringToEnum(@TypeOf(app.scenes.view), op[1]) orelse return error.BadView;
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
        if (!app.openBox(o.name)) return error.NotABox;
        return;
    };
    return error.NoSuchObject;
}

fn opClick(app: *App, op: []const []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    // A left click at screen point X, Y (after a layout), no drag.
    for (0..2) |_| main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    app.mouse = .{ try std.fmt.parseFloat(f32, op[1]), try std.fmt.parseFloat(f32, op[2]) };
    app.clicked = true;
    main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    app.clicked = false;
    app.moving = null;
    d.preview = null;
}

/// `--click-id NAME K`: a left click on the middle of Clay element NAME, index K (`resist_tick 0`).
fn opClickId(app: *App, op: []const []const u8) !void {
    for (0..2) |_| main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    const b = @import("clay.zig").box(@import("clay.zig").idi(op[1], try std.fmt.parseInt(u32, op[2], 10))) orelse return error.NoElement;
    app.mouse = .{ b.x + b.width / 2, b.y + b.height / 2 };
    // The pointer over it a frame first, as a hand's (a menu takes only clicks it is under).
    main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    app.clicked = true;
    main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    app.clicked = false;
}

/// `--drag X1 Y1 X2 Y2`: the left button pressed at X1, Y1, moved to X2, Y2 over a few
/// frames and released there (a scroll bar's thumb, a splitter).
fn opDrag(app: *App, op: []const []const u8) !void {
    var v: [4]f32 = undefined;
    for (&v, op[1..5]) |*x, s| x.* = try std.fmt.parseFloat(f32, s);
    app.mouse = .{ v[0], v[1] };
    for (0..2) |_| main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    app.down = true;
    app.clicked = true;
    main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    app.clicked = false;
    for (1..9) |k| {
        const t: f32 = @as(f32, @floatFromInt(k)) / 8;
        app.mouse = .{ v[0] + (v[2] - v[0]) * t, v[1] + (v[3] - v[1]) * t };
        main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    }
    app.down = false;
    for (0..2) |_| main.present(app, main.frame(app, app.size, .{ 0, 0 }));
}

/// `--wheel X Y DY` (or `DX,DY`, a trackpad's swipe): wheel notches with the mouse at
/// screen point X, Y.
fn opWheel(app: *App, op: []const []const u8) !void {
    app.mouse = .{ try std.fmt.parseFloat(f32, op[1]), try std.fmt.parseFloat(f32, op[2]) };
    for (0..2) |_| main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    const comma = std.mem.indexOfScalar(u8, op[3], ',');
    const d: [2]f32 = if (comma) |k| .{ try std.fmt.parseFloat(f32, op[3][0..k]), try std.fmt.parseFloat(f32, op[3][k + 1 ..]) } else .{ 0, try std.fmt.parseFloat(f32, op[3]) };
    // Over the code editor the wheel is its own (events.wheel).
    if (app.code) |v| if (codeview.over(v, app.mouse)) codeview.wheel(v, d[0], d[1], false);
    main.present(app, main.frame(app, app.size, d));
    for (0..2) |_| main.present(app, main.frame(app, app.size, .{ 0, 0 }));
}

/// `--hero-strike N`: the weapon page's striking hero, the N-th of the heroes with strikes (if it can strike with the weapon).
/// `--attack ENEMY WEAPON show|copy|remove|give|FIELD=VALUE`: an enemy's attack by its
/// weapon class (entry_attacks.zig): struck in the preview, copied, its own row removed,
/// WEAPON given as a new attack, or a field of its row.
fn opAttack(app: *App, op: []const []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const ea = @import("entry_attacks.zig");
    const i = try entries.entryById(app, op[1]);
    entries.showEntry(app, i);
    const e = app.catalog.entries.items[i];
    const who = entries.enemyWho(app, e, app.store.text(entries.fileOf(app, e) orelse return error.NoFile));
    const list = ea.attacksOf(app, app.frame.allocator(), e, who);
    if (std.mem.eql(u8, op[3], "give")) return ea.addAttack(app, who, if (list.len > 0) list[0] else return error.NoAttack, try app.catalog.arena.allocator().dupe(u8, op[2]));
    const k = for (list, 0..) |at, n| {
        if (std.ascii.eqlIgnoreCase(at.class, op[2]) or std.ascii.eqlIgnoreCase(@import("entry_rules.zig").bareClass(at.class), op[2])) break n;
    } else return error.NoSuchAttack;
    if (std.mem.eql(u8, op[3], "show")) {
        app.enemy_strike = @intCast(k);
    } else if (std.mem.eql(u8, op[3], "copy")) {
        _ = try ea.copyAttack(app, who, list[k]);
    } else if (std.mem.eql(u8, op[3], "remove")) {
        try ea.removeAttack(app, who, list[k]);
    } else {
        const eq = std.mem.indexOfScalar(u8, op[3], '=') orelse return error.BadMode;
        try ea.setAttack(app, who, list[k], op[3][0..eq], op[3][eq + 1 ..]);
    }
}

/// `--ai ENEMY FIELD VALUE` (FIELD `profile`: row VALUE of the rules in force chosen), `--weapon-fx WEAPON FIELD VALUE`, `--hero-rule HERO FIELD
/// VALUE`, `--hero-bonus HERO FIELD VALUE`: a field of the entry's AiProfile, party or
/// HealBonus rows, `--weapon-fx`'s of the weapon's block (`effects_from`… hit_sound;
/// entry_attacks.zig).
fn opRule(app: *App, op: []const []const u8) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    const ea = @import("entry_attacks.zig");
    const i = try entries.entryById(app, op[1]);
    entries.showEntry(app, i);
    const e = app.catalog.entries.items[i];
    const class = @import("entry_rules.zig").classOf(e);
    if (std.mem.eql(u8, op[0], "--weapon-fx")) return ea.setFx(app, class, op[2], op[3]);
    const who = entries.enemyWho(app, e, app.store.text(entries.fileOf(app, e) orelse return error.NoFile));
    if (std.mem.eql(u8, op[0], "--ai")) {
        if (std.mem.eql(u8, op[2], "profile")) return ea.setProfile(app, who, @intFromFloat(@import("model.zig").get(app.store.text(entries.fileOf(app, e).?), "battle_class") orelse 0), try std.fmt.parseInt(usize, op[3], 10));
        return @import("rulespages.zig").setAi(app, .{ .fighter_class = who.class }, op[2], op[3]);
    }
    if (std.mem.eql(u8, op[0], "--hero-bonus")) return ea.setBonus(app, .{ .id = who.id, .class = class }, op[2], op[3]);
    return ea.setHero(app, .{ .id = who.id, .class = class }, op[2], op[3]);
}

/// `--ability ENTRY NAME VALUE`: the character's (hero or enemy) ability NAME (an Abilities
/// field) added (`+`), taken away (`-`) or made VALUE, as its "Extra abilities" block does.
fn opAbility(app: *App, op: []const []const u8) !void {
    // An OpenGorky project's block by its path, keyed as its page keys it (a battle's
    // fighter: its object's name).
    if (std.mem.indexOfScalar(u8, op[1], '/') != null) {
        const f = try ogBlock(app, op[1]);
        const og_page = @import("og_page.zig");
        const b = @import("model_og.zig").blockOf(app, app.frame.allocator(), f).?;
        return @import("char_abilities.zig").setAbility(app, og_page.whoOf(app, app.frame.allocator(), f, b, null), og_page.classType(app, f), op[2], op[3]);
    }
    const i = try entries.entryById(app, op[1]);
    entries.showEntry(app, i);
    const text = app.store.text(entries.fileOf(app, app.catalog.entries.items[i]) orelse return error.NoFile);
    const tables = @import("entry_tables.zig");
    return @import("char_abilities.zig").setAbility(app, tables.whoOf(app, i), @intFromFloat(@import("model.zig").get(text, "battle_class") orelse 0), op[2], op[3]);
}

/// Block `path` of an OpenGorky project (`characters/grandma.ogs`, a block inside one
/// `battles/b/battle.ogs#kid/gun`) as the Store's file (model_og.zig).
fn ogBlock(app: *App, path: []const u8) !usize {
    if (!app.ogLayout()) return error.ClassicProject;
    const f = try app.store.file(@import("store.zig").og_src, path);
    if (@import("model_og.zig").blockOf(app, app.frame.allocator(), f) == null) return error.NoSuchBlock;
    return f;
}

/// `--og-set BLOCK FIELD VALUE`: the block's field made VALUE (OG Script as typed:
/// `40`, `"x"`, `[5, 2]`, `Wave(turn = 3)`), `-` taken out (model.set / unset).
fn opOgSet(app: *App, op: []const []const u8) !void {
    const f = try ogBlock(app, op[1]);
    const model = @import("model.zig");
    if (std.mem.eql(u8, op[3], "-")) return model.unset(app, f, &.{op[2]});
    return model.set(app, f, &.{op[2]}, op[3], null);
}

/// `--og-attach BLOCK COMPONENT PARAM VALUE`: PARAM `+` attaches COMPONENT, `-` takes it
/// out; else that param of its (first) attach made VALUE (OG Script as typed).
fn opOgAttach(app: *App, op: []const []const u8) !void {
    const f = try ogBlock(app, op[1]);
    const mo = @import("model_og.zig");
    const a = app.frame.allocator();
    const b = mo.blockOf(app, a, f).?;
    const k: ?usize = for (b.e.attach, 0..) |x, i| {
        if (std.mem.eql(u8, x.component, op[2])) break i;
    } else null;
    if (std.mem.eql(u8, op[3], "+")) return mo.edit(app, f, .{ .attach = .{ .index = null, .new = .{ .component = op[2], .params = &.{}, .line = 0 } } });
    const i = k orelse return error.NotAttached;
    if (std.mem.eql(u8, op[3], "-")) return mo.edit(app, f, .{ .attach = .{ .index = i, .new = null } });
    const v = try mo.parseValue(a, op[4]);
    var ps: std.ArrayList(@import("opengorky").script.ir.Named) = .empty;
    try ps.appendSlice(a, b.e.attach[i].params);
    for (ps.items) |*p| if (std.mem.eql(u8, p.name, op[3])) {
        p.value = v;
        break;
    } else try ps.append(a, .{ .name = op[3], .value = v });
    return mo.edit(app, f, .{ .attach = .{ .index = i, .new = .{ .component = op[2], .params = ps.items, .line = 0 } } });
}

/// `--og-fighter BATTLE ARCHETYPE`: "+ fighter" of the level page (a free tile when shown).
fn opOgFighter(app: *App, op: []const []const u8) !void {
    const name = try @import("level_og.zig").addFighter(app, try ogBlock(app, op[1]), op[2]);
    return app.setStatus(tx.st_og_fighter, .{name});
}

/// `--og-inner BLOCK KIND NAME BASE`: a new block `KIND NAME: BASE {}` inside BLOCK
/// (BASE `-`: none).
fn opOgInner(app: *App, op: []const []const u8) !void {
    const f = try ogBlock(app, op[1]);
    return @import("model_og.zig").addInner(app, f, op[2], op[3], if (std.mem.eql(u8, op[4], "-")) "" else op[4]);
}

/// `--og-remove BLOCK`: the block taken out (an inner one from its parent, a file's main
/// block: the file deleted on save).
fn opOgRemove(app: *App, op: []const []const u8) !void {
    return @import("model_og.zig").remove(app, try ogBlock(app, op[1]));
}

/// `--og-name BLOCK TEXT`: the block's name in the game (its classic_id's `UiText` row in
/// src/texts/ui.ogs), as the page's "Name in the game" types it.
fn opOgName(app: *App, op: []const []const u8) !void {
    const f = try ogBlock(app, op[1]);
    const model = @import("model.zig");
    const id = model.num(model.field(app, f, "classic_id").value) orelse return error.NoClassicId;
    try @import("texts.zig").set(app, .strings, @intFromFloat(id), op[2]);
    app.refreshTitles();
}

/// `--og-ammo WEAPON PICK`: the weapon page's "Ammo" row: `none`, `thrown` or an ammo
/// archetype (`items::riffleammo`; model_og.setAmmo).
fn opOgAmmo(app: *App, op: []const []const u8) !void {
    return @import("model_og.zig").setAmmo(app, try ogBlock(app, op[1]), op[2]);
}

/// `--og-entry LOCATION POINT`: the location's "Hero's entry" (`entry = "POINT"`; `-`: none).
fn opOgEntry(app: *App, op: []const []const u8) !void {
    const f = try ogBlock(app, try std.fmt.allocPrint(app.frame.allocator(), "locations/{s}/level.ogs", .{op[1]}));
    return @import("levelpanel.zig").setEntry(app, f, if (std.mem.eql(u8, op[2], "-")) "" else op[2]);
}

/// `--ability-new ENTRY NAME`: a new scripted ability NAME (a component from the template
/// in rules\abilities.ss) on the character's page, as "+ new ability" makes one (not attached).
fn opAbilityNew(app: *App, op: []const []const u8) !void {
    const i = try entries.entryById(app, op[1]);
    entries.showEntry(app, i);
    return @import("char_abilities.zig").addAbility(app, @import("entry_tables.zig").whoOf(app, i), op[2]);
}

/// `--row ENTRY CALL FIELD VALUE`: a field of the entry's row of CALL as its page writes
/// it (entry_tables.setByName).
fn opRow(app: *App, op: []const []const u8) !void {
    const i = try entries.entryById(app, op[1]);
    entries.showEntry(app, i);
    return @import("entry_tables.zig").setByName(app, i, op[2], op[3], op[4]);
}

/// `--material NAME FIELD VALUE`: material NAME's FIELD (program, blend, rgb, alpha, k) as
/// the rules write it (fxmaterial.zig); FIELD `add` (a new one), `rename` (to VALUE),
/// `delete`, `show` (shown on the weapon page), `pick` (the picked part's list open).
fn opMaterial(app: *App, op: []const []const u8) !void {
    const m = @import("fxmaterial.zig");
    const f = op[2];
    if (std.mem.eql(u8, f, "add")) return m.add(app);
    if (std.mem.eql(u8, f, "rename")) return m.rename(app, op[1], op[3]);
    if (std.mem.eql(u8, f, "delete")) return m.delete(app, op[1]);
    if (std.mem.eql(u8, f, "show") or std.mem.eql(u8, f, "pick")) {
        app.material.sel.set(op[1]);
        if (f[0] == 'p') @import("picker.zig").open(app, m.pickId());
        return;
    }
    return m.setText(app, op[1], f, op[3]);
}

/// `--post STEP FIELD VALUE`: the post-processing page (postpage.zig) shown, step STEP's
/// FIELD (program, k, rgb) as the rules write it, or `up`, `down`, `remove`, `show`; STEP
/// `add` (FIELD the program), `view` (FIELD before or after).
fn opPost(app: *App, op: []const []const u8) !void {
    const p = @import("postpage.zig");
    app.setTab(.post);
    if (std.mem.eql(u8, op[1], "add")) return p.add(app, op[2]);
    if (std.mem.eql(u8, op[1], "view")) {
        app.post.before = std.mem.eql(u8, op[2], "before");
        return;
    }
    const i = try std.fmt.parseInt(usize, op[1], 10);
    if (std.mem.eql(u8, op[2], "show")) {
        app.post.sel = i;
        return;
    }
    return p.setStep(app, i, op[2], op[3]);
}

/// `--post-for LEVEL`: the post-processing page on LEVEL's chain (`global`: the global one).
fn opPostFor(app: *App, op: []const []const u8) !void {
    @import("postpage.zig").showFor(app, if (std.mem.eql(u8, op[1], "global")) "" else op[1]);
}

/// `--level-post own|shared`: the open level's post-processing made its own (a copy of the
/// global chain) or the global one again (levelpanel.zig's slot).
fn opLevelPost(app: *App, op: []const []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    return @import("postpage.zig").setOwn(app, d.name, std.mem.eql(u8, op[1], "own"));
}

/// `--shell ROW FIELD VALUE`: a shell row of rules ui.ss: ROW `music`, `menu` (FIELD as the
/// row writes it; campaignpage.zig), `windows` (FIELD `K.J`: place K's number J),
/// `video:NAME` (videopage.zig: FIELD x, y, double, `add`, `remove`, `show`: only shown),
/// `panel` (PanelPlace: FIELD `K.x`, `K.y`, `K.w`, `K.h`, `K.pick`, `K.remove`, `add`).
fn opShell(app: *App, op: []const []const u8) !void {
    const cp = @import("campaignpage.zig");
    const shell = @import("opengorky").core.ui;
    const eq = std.mem.eql;
    if (std.mem.startsWith(u8, op[1], "video:")) {
        const name = op[1]["video:".len..];
        doctabs.show(app, .videos, name);
        if (eq(u8, op[2], "show")) return;
        return @import("videopage.zig").setPlace(app, name, op[2], op[3]);
    }
    app.setTab(.campaign);
    if (eq(u8, op[1], "music")) return cp.setShell(app, shell.Music, op[2], op[3]);
    if (eq(u8, op[1], "menu")) return cp.setShell(app, shell.Menu, op[2], op[3]);
    if (eq(u8, op[1], "panel")) {
        if (eq(u8, op[2], "add")) return cp.addPlace(app);
        const dot = std.mem.indexOfScalar(u8, op[2], '.') orelse return error.BadPlace;
        const k = try std.fmt.parseInt(usize, op[2][0..dot], 10);
        const f = op[2][dot + 1 ..];
        if (eq(u8, f, "pick")) {
            app.campaign.place = k;
            return;
        }
        if (eq(u8, f, "remove")) return cp.removePlace(app, k);
        if (f.len != 1) return error.BadPlace;
        const j = std.mem.indexOfScalar(u8, "xywh", f[0]) orelse return error.BadPlace;
        return cp.setPlace(app, k, j, try std.fmt.parseFloat(f32, op[3]));
    }
    if (!eq(u8, op[1], "windows")) return error.NoSuchRow;
    const d = std.mem.indexOfScalar(u8, op[2], '.') orelse return error.BadPlace;
    const k = try std.fmt.parseInt(usize, op[2][0..d], 10);
    const j = try std.fmt.parseInt(usize, op[2][d + 1 ..], 10);
    if (k > 8 or j > 1) return error.BadPlace;
    return cp.setWindow(app, k, j, try std.fmt.parseFloat(f32, op[3]));
}

/// `--campaign FIELD VALUE`: a field of the campaign (campaignpage.zig).
fn opCampaign(app: *App, op: []const []const u8) !void {
    app.setTab(.campaign);
    return @import("campaignpage.zig").set(app, op[1], op[2]);
}

/// `--exp-level LEVEL EXP`: a level's threshold (rulespages.zig); LEVEL `add`: a level
/// after the last, EXP `remove`: the last one dropped (one the project added).
fn opExpLevel(app: *App, op: []const []const u8) !void {
    const rp = @import("rulespages.zig");
    app.setTab(.exp_levels);
    if (std.mem.eql(u8, op[1], "add")) return rp.addLevel(app);
    if (std.mem.eql(u8, op[2], "remove")) return rp.removeLevel(app);
    return rp.setExp(app, try std.fmt.parseInt(i32, op[1], 10), op[2]);
}

/// `--value NAME VALUE`: a special value (Value; rulespages.zig); VALUE `pick`: its list opened.
/// `--scoring EVAL FIELD VALUE`: a field of the AI tile scoring EVAL as its page sets it.
fn opScoring(app: *App, op: []const []const u8) !void {
    return @import("rulespages.zig").setScoring(app, op[1], op[2], op[3]);
}

fn opValue(app: *App, op: []const []const u8) !void {
    app.setTab(.values);
    if (std.mem.eql(u8, op[2], "pick")) {
        @import("picker.zig").open(app, @import("rulespages.zig").valuePick(std.meta.stringToEnum(@import("opengorky").rules.Const, op[1]) orelse return error.NoSuchValue));
        return;
    }
    return @import("rulespages.zig").setValue(app, std.meta.stringToEnum(@import("opengorky").rules.Const, op[1]) orelse return error.NoSuchValue, op[2]);
}

/// `--action FUNC FIELD VALUE`: action FUNC shown and its FIELD set (rulespages.zig);
/// FUNC `new`: a new action; FIELD `show`: only shown (VALUE `pick`: its text list
/// open, `levels`: the levels searched); `delete`: its row dropped.
fn opAction(app: *App, op: []const []const u8) !void {
    const rp = @import("rulespages.zig");
    app.setTab(.actions);
    if (std.mem.eql(u8, op[1], "new")) return rp.newAction(app);
    const func = try std.fmt.parseInt(i32, op[1], 10);
    app.rules_page.act = func;
    if (std.mem.eql(u8, op[2], "show")) {
        if (std.mem.eql(u8, op[3], "pick")) @import("picker.zig").open(app, @import("clay.zig").id("act_text_pick"));
        if (std.mem.eql(u8, op[3], "levels")) rp.searchLevels(app, func);
        return;
    }
    if (std.mem.eql(u8, op[2], "delete")) return rp.dropAction(app, func);
    return rp.setAction(app, func, op[2], op[3]);
}

/// `--ai-profile K FIELD VALUE`: AI profile row K (in the rules in force) shown and its
/// FIELD set (rulespages.zig); FIELD `show`: only shown.
fn opAiProfile(app: *App, op: []const []const u8) !void {
    const k = try std.fmt.parseInt(usize, op[1], 10);
    const list = @import("opengorky").rules.active.ai_profiles;
    if (k >= list.len) return error.NoSuchRow;
    doctabs.show(app, .ai_profiles, op[1]);
    if (std.mem.eql(u8, op[2], "show")) return;
    return @import("rulespages.zig").setAi(app, list[k], op[2], op[3]);
}

fn opStrikeHero(app: *App, op: []const []const u8) !void {
    const hs = @import("entry_model.zig").heroEntries(app, app.frame.allocator());
    const k = try std.fmt.parseInt(usize, op[1], 10);
    if (k >= hs.len) return error.NoSuchHero;
    app.attack_hero = hs[k];
}

/// `--fx-put KEY STAGE PART`: a part (its rules text) after effect record KEY's of STAGE
/// (KEY: a weapon's ID, or FIGHTER:WEAPON a fighter's own with its own_* stages).
fn opFxPut(app: *App, op: []const []const u8) !void {
    return @import("fxdesc.zig").putText(app, op[1], op[2], op[3]);
}

/// `--fx-copy TO FROM`: built-in effect record FROM copied as record TO's row (keys as --fx-put's).
fn opFxCopy(app: *App, op: []const []const u8) !void {
    return @import("fxdesc.zig").copyText(app, op[1], op[2]);
}

/// `--fx-new ID`: weapon ID (shown) strikes with a new effect description (fxdesc.newRecord).
fn opFxNew(app: *App, op: []const []const u8) !void {
    const i = try entries.entryById(app, op[1]);
    entries.showEntry(app, i);
    _ = try @import("fxdesc.zig").newRecord(app, @import("entry_rules.zig").classOf(app.catalog.entries.items[i]));
}

/// `--fx-part STAGE N`: the weapon page's (an enemy's attack card's) effect description on STAGE, part N picked.
fn opFxPart(app: *App, op: []const []const u8) !void {
    app.fx_stage = @backingInt(std.meta.stringToEnum(@import("fxdesc.zig").Stage, op[1]) orelse return error.BadStage);
    app.fx_part = try std.fmt.parseInt(usize, op[2], 10);
}

/// `--preview-frame N`: the model preview stopped on frame N of its animation.
fn opPreviewFrame(app: *App, op: []const []const u8) !void {
    // After the animation is shown (a new one starts on its first frame).
    for (0..2) |_| main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    app.preview.paused = try std.fmt.parseInt(u32, op[1], 10);
}

/// `--adjust NAME VALUE`: an adjust.kdt value set (Engine settings).
fn opAdjust(app: *App, op: []const []const u8) !void {
    return @import("adjustpage.zig").setByName(app, op[1], op[2]);
}

fn opMenu(app: *App, op: []const []const u8) !void {
    // After a layout (the viewport's box): the menu at screen point X, Y.
    for (0..2) |_| main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    app.mouse = .{ try std.fmt.parseFloat(f32, op[1]), try std.fmt.parseFloat(f32, op[2]) };
    return app.openMenu();
}

fn opAdd(app: *App, op: []const []const u8) !void {
    for (app.allTemplates(app.frame.allocator())) |t| if (std.ascii.eqlIgnoreCase(t.class, op[1])) return app.addEnemy(t, null);
    return error.NoSuchClass;
}

/// `--set NAME FIELD VALUE` on the enemy's own file, `--class-set` on its class.
fn opSet(app: *App, op: []const []const u8) !void {
    const d = app.doc orelse return error.NoLevel;
    const en = try d.enemy(op[1]);
    const names: []const []const u8 = if (std.mem.eql(u8, op[2], "hp")) &.{ "hp", "max_hp" } else op[2..3];
    if (std.mem.eql(u8, op[0], "--set")) return @import("model.zig").set(app, en.ftr, names, op[3], "#include ft_");
    return @import("model.zig").set(app, en.class orelse return error.NoClass, names, op[3], null);
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

/// `--package OUT`: the mod packed into OUT (what the editor's saves changed).
fn opPackage(app: *App, op: []const []const u8) !void {
    try app.packMod(op[1]);
}

/// `--convert-ask DIR|-`: Settings → "Convert to OpenGorky…", the folder DIR
/// chosen (`-`: the one offered); one with anything in it is refused in the window.
fn opConvertAsk(app: *App, op: []const []const u8) !void {
    const pc = @import("projconvert.zig");
    pc.ask(app);
    if (app.proj_convert == null) return error.NotAsked;
    if (!std.mem.eql(u8, op[1], "-")) try pc.choose(app, op[1]);
}

/// `--convert-start DIR|-`: as --convert-ask, then Convert: the run going on (its progress
/// in the window; the session's end cancels it, the folder left empty).
fn opConvertStart(app: *App, op: []const []const u8) !void {
    try opConvertAsk(app, op);
    try @import("projconvert.zig").begin(app);
}

/// `--convert-to DIR|-`: as --convert-start, waited for: converted and built, the editor
/// then starts anew on the new project (the shot is of its summary); a failure: its report
/// window stays (the shot is of it), the status says the error.
fn opConvertTo(app: *App, op: []const []const u8) !void {
    try opConvertStart(app, op);
    @import("projconvert.zig").wait(app);
}

/// `--convert-cancel DIR|-`: as --convert-start, Cancel pressed at once: the run stops,
/// nothing left in the folder, the editor stays in the Classic project.
fn opConvertCancel(app: *App, op: []const []const u8) !void {
    const pc = @import("projconvert.zig");
    try opConvertStart(app, op);
    app.proj_convert.?.stop.store(true, .monotonic);
    pc.wait(app);
    if (app.proj_convert != null) return error.NotCanceled;
}

/// `--tab-close save|discard|cancel`: the shown tab's × clicked, the unsaved question answered so;
/// `--tab-close-at K ANSWER`: tab K's (from 0, the strip's order), shown or not.
fn opCloseTab(app: *App, op: []const []const u8) !void {
    const at: ?usize = if (op.len == 3) try std.fmt.parseInt(usize, op[1], 10) else null;
    doctabs.scripted_answer = std.meta.stringToEnum(doctabs.Answer, op[op.len - 1]) orelse return error.BadAnswer;
    defer doctabs.scripted_answer = null;
    // As a click on its ×: asked for during a frame's layout, done before the next one.
    main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    const cmds = main.frame(app, app.size, .{ 0, 0 });
    if (at) |k| app.tab_close = k else doctabs.closeActive(app);
    main.present(app, cmds);
    main.present(app, main.frame(app, app.size, .{ 0, 0 }));
}

//! Script builtins: level, scenes, dialogs, GUI, walkability, transitions.

const std = @import("std");
const walk_mod = @import("../world.zig").walk;
const scenes = @import("../scene.zig").scenes;
const areas = @import("../world.zig").areas;
const level_files = @import("../formats.zig").level_files;
const runtime = @import("../script.zig").runtime;
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const Object = @import("../script.zig").object.Object;
const Runtime = runtime.Runtime;
const Value = @import("../script.zig").value.Value;
const args_mod = @import("args.zig");
const advVar = args_mod.advVar;

/// SetGlobalStringVariable (0x4bf7e6 → 0x450210): no-op. The exe's global string table
/// is read only by scene `#NAME` arguments (0x476561), and the game's scenes name only
/// #HERO_SELECTED and #LAST_ACTION_HERO, which scenario.zig maps to world state.
pub fn biSetGlobalStringVariable(_: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
    return .zero;
}

/// FadeIn() (0x4be9f0 → 0x4200b0(0, −0.1)): fade in from black. After LEVEL_Load
/// it applies to the new level.
pub fn biFadeIn(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    if (try args_mod.deferAfterLoad(w, .fade_in, args)) return .zero;
    w.scene.fade = 1;
    w.scene.fade_target = 0;
    return .zero;
}

/// HeroInArea("area") (0x4c0230): any hero stands in the area (by background point).
/// The exe also sets global string HERO1 (0x4c0306); only the unused corpses.scr reads it.
pub fn biHeroInArea(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const area = areas.findArea(w, args_mod.argString(args, 0)) orelse return .zero;
    for (w.actorObjects()) |o| {
        if (!world_mod.isHero(o) or !o.enabled or !world_mod.actorOf(o).placed) continue;
        const p = w.screenPos(o);
        if (level_files.areaContains(area, p[0], p[1])) {
            return .{ .int = 1 };
        }
    }
    return .zero;
}

pub fn biGetSelectedHero(ctx: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
    return .{ .string = args_mod.worldOf(ctx).selected_hero };
}

pub fn biStartScriptlet(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    scenes.startScriptlet(args_mod.worldOf(ctx), args_mod.argString(args, 0)) catch |err| std.log.warn("scriptlet {s}: {t}", .{ args_mod.argString(args, 0), err });
    return .zero;
}

/// SetAddonScriptlet("scene") (0x4791e0): with a scene running, the name goes to
/// the deferred slot (0x5266a8, overwriting); otherwise StartScriptlet at once.
pub fn biSetAddonScriptlet(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    scenes.setAddonScriptlet(args_mod.worldOf(ctx), args_mod.argString(args, 0)) catch |err| std.log.warn("scriptlet {s}: {t}", .{ args_mod.argString(args, 0), err });
    return .zero;
}

pub fn biLevelLoad(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    if (try args_mod.deferAfterLoad(w, .level_load, args)) return .zero;
    const name = args_mod.argString(args, 0);
    w.flow.load_call = w.rt.top_call;
    if (name.len > 0) w.flow.pending_level = try w.arena_state.allocator().dupe(u8, name);
    return .zero;
}

/// LEVEL_LoadAB(name) (0x4c04d0): LEVEL_Load after which the new level gets
/// AfterBattle(previous name), as after a battle (0x41fb06).
pub fn biLevelLoadAB(ctx: *anyopaque, rt: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const was_pending = w.flow.pending_level != null;
    _ = try biLevelLoad(ctx, rt, self, args);
    if (!was_pending) w.flow.load_ab = w.flow.pending_level != null;
    return .zero;
}

/// DisableHeroes() (0x4c1920): only the selected hero stays in the room; party
/// heroes (0x6b4e78, without avoidEnumerate) are disabled, extras untouched. After
/// LEVEL_Load (museum balcony exit 03m_exit2balkon: LEVEL_Load("04_city"),
/// PlaceActor(selected, "balkon_start"), DisableHeroes()) it applies to the new level.
pub fn biDisableHeroes(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    if (try args_mod.deferAfterLoad(w, .disable_heroes, args)) return .zero;
    for (w.rt.objects.items) |o| {
        if (world_mod.isHero(o) and o.getInt("avoidEnumerate") == 0 and !std.ascii.eqlIgnoreCase(o.name, w.selected_hero)) o.enabled = false;
    }
    return .zero;
}

/// EnableHeroes() (0x4c1900 → 0x481e20): enable heroes without avoidEnumerate
/// (+0x24a40; Medusa stays disabled until she joins).
pub fn biEnableHeroes(ctx: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    for (w.rt.objects.items) |o| if (world_mod.isHero(o) and o.getInt("avoidEnumerate") == 0) {
        o.enabled = true;
    };
    return .zero;
}

pub fn biGuiPanorama(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    if (args.len > 0) args_mod.worldOf(ctx).scene.panorama = args[0].toInt() != 0;
    return .zero;
}

pub fn biAdvInc(ctx: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
    if (advVar(ctx)) |l| l.setInt("advVar", l.getInt("advVar") + 1);
    return .zero;
}

pub fn biAdvDec(ctx: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
    if (advVar(ctx)) |l| l.setInt("advVar", l.getInt("advVar") - 1);
    return .zero;
}

pub fn biAdvGet(ctx: *anyopaque, _: *Runtime, _: *Object, _: []const Value) anyerror!Value {
    return .{ .int = if (advVar(ctx)) |l| l.getInt("advVar") else 0 };
}

pub fn biAdvSet(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    if (args.len > 0) if (advVar(ctx)) |l| l.setInt("advVar", args[0].toInt());
    return .zero;
}

/// DialogInit("name", "file.dlg"): show a whole dialog (lines one by one).
pub fn biDialogInit(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    try scenes.startDialog(args_mod.worldOf(ctx), args_mod.argString(args, 0), args_mod.argString(args, 1));
    return .zero;
}

/// PlaceHeroes("area"[, floor]) (0x4bf050); see walk.placeHeroes.
pub fn biPlaceHeroes(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    if (try args_mod.deferAfterLoad(args_mod.worldOf(ctx), .place_heroes, args)) return .zero;
    if (args.len == 0 or args[0] != .string) return .zero;
    walk_mod.placeHeroes(args_mod.worldOf(ctx), args_mod.argString(args, 0), if (args.len > 1) args[1].toInt() else 0);
    args_mod.worldOf(ctx).out.camera_snap = true; // 0x4bf0c6 → 0x45ba90
    return .{ .int = 1 }; // 0x4bf0ce
}

/// ForbidWalkInArea("area", floor) / AllowWalkInArea: block or open the floor map
/// cells (0 `.wm`, 1 `.wm2`) inside the area polygon.
pub fn biForbidWalkInArea(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    try walk_mod.setWalkInArea(args_mod.worldOf(ctx), args_mod.argString(args, 0), false, if (args.len > 1) args[1].toInt() else 0);
    return .zero;
}

pub fn biAllowWalkInArea(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    try walk_mod.setWalkInArea(args_mod.worldOf(ctx), args_mod.argString(args, 0), true, if (args.len > 1) args[1].toInt() else 0);
    return .zero;
}

/// TestActorMapChange("area", floor) (0x4beea0): heroes (vfunc +0x64: also disabled
/// and non-party ones) standing in the area switch to the floor (0x42b420; 0 `.wm`,
/// 1 `.wm2`); called from the level's update() every tick.
pub fn biTestActorMapChange(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    if (args.len < 2 or args[1] != .int) return .zero;
    const area = areas.findArea(w, args_mod.argString(args, 0)) orelse return .zero;
    const floor: u1 = if (args[1].int == 1) 1 else 0;
    for (w.actorObjects()) |o| {
        if (!world_mod.actorOf(o).placed or !(world_mod.isHero(o) or World.nativeOf(o).hro)) continue;
        const p = w.screenPos(o);
        if (level_files.areaContains(area, p[0], p[1])) world_mod.actorOf(o).map = floor;
    }
    return .zero;
}

/// SetActorMap(actor, floor).
pub fn biSetActorMap(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const o = args_mod.worldOf(ctx).actorObject(args_mod.argString(args, 0)) orelse return .zero;
    if (args.len > 1) world_mod.actorOf(o).map = if (args[1].toInt() == 1) 1 else 0;
    return .zero;
}

/// GUI_Disable(mode) (0x4c18c0): 1 like the scene's GUI_DISABLE (0x45a3f0, panorama
/// off); 0 normal mode (0x45a410); 2 scene mode (0x45bd00 → 0x450ec0, like
/// GUI_CUTSCENE: no control, autocamera).
pub fn biGUIDisable(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    if (args.len == 0 or args[0] != .int) return .zero;
    switch (args[0].int) {
        0 => {
            w.scene.cutscene = false;
            w.out.camera_snap = true;
        },
        1 => w.scene.panorama = false,
        2 => {
            w.scene.cutscene = true;
            w.scene.autocamera = true;
        },
        else => {},
    }
    return .zero;
}

/// AVI_Play("name.avi", x, y, double): video before a boss battle (0x45d620);
/// the host plays it.
pub fn biAVIPlay(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    try w.out.video_requests.append(w.gpa, .{
        .name = try w.arena_state.allocator().dupe(u8, args_mod.argString(args, 0)),
        .x = if (args.len > 1) args[1].toInt() else 0,
        .y = if (args.len > 2) args[2].toInt() else 0,
        .double = args.len > 3 and args[3].toInt() != 0,
    });
    return .zero;
}

/// Signature(n) (0x4c2200): date caption, `intro.spr` frame n at the bottom of the
/// screen (01_port: "somewhere in Poland"); −1 removes it.
pub fn biSignature(ctx: *anyopaque, _: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const n: i32 = if (args.len > 0) args[0].toInt() else -1;
    w.scene.signature = if (n < 0) null else .{ .frame = @intCast(n), .start = w.ticks };
    return .zero;
}

/// GUI_SelectMode("mode") (0x4c17f0): "GUI_SafeBox" is the safe keypad (0x457ff0)
/// for the calling area; "GUI_Staging" starts the battle with the enemy turn
/// sequence (0x45b150(1)): enemies walk in, their music, states one turn longer.
/// Without it the battle starts with the player turn. The exe has no hero deployment.
pub fn biGUISelectMode(ctx: *anyopaque, _: *Runtime, self: *Object, args: []const Value) anyerror!Value {
    const w = args_mod.worldOf(ctx);
    const mode = args_mod.argString(args, 0);
    if (std.ascii.eqlIgnoreCase(mode, "GUI_SafeBox")) w.act.safe_box = self;
    if (std.ascii.eqlIgnoreCase(mode, "GUI_Staging")) if (w.battle) |*b| {
        b.staging = true;
        b.enemy_period = true;
    };
    return .zero;
}

/// GO_RunFun(object, "function"[, args…]): call an object's function.
pub fn biGORunFun(ctx: *anyopaque, rt: *Runtime, _: *Object, args: []const Value) anyerror!Value {
    const rest: []const Value = if (args.len > 2) args[2..] else &.{};
    if (rt.findObject(args_mod.argString(args, 0))) |obj| return (try rt.callIfExists(obj, args_mod.argString(args, 1), rest)) orelse .zero;
    // Object of another level (usually its level object): look among loaded ones.
    const w = args_mod.worldOf(ctx);
    const r = w.resolver orelse return .zero;
    const other = (try r.find(r.ctx, args_mod.argString(args, 0))) orelse return .zero;
    const obj = other.rt.findObject(args_mod.argString(args, 0)) orelse return .zero;
    // Scenes run on the exe's shared player (0x68b154): one started there (the
    // lever in the duty room starts the lab train) runs on the current level.
    other.scene_host = w;
    defer other.scene_host = null;
    return (try other.rt.callIfExists(obj, args_mod.argString(args, 1), rest)) orelse Value.zero;
}

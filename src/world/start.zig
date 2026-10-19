//! Location start (0x431830): objects and heroes from the archives, `.var`, init(),
//! restore(), post_init(); level camera after initCamera().

const std = @import("std");
const state_object = @import("../state.zig").object;
const archive = @import("../formats.zig").archive;
const vars = @import("../formats.zig").vars;
const jpeg = @import("../formats.zig").jpeg;
const camera = @import("../actor.zig").camera;
const fields = @import("../fields.zig");
const mods = @import("mods.zig");
const world = @import("../state.zig").world;
const World = world.World;
const Object = @import("../script.zig").object.Object;

/// Game heroes and shared items (`common/other.dat: gamestart\*`, 0x431550): `.hro` are
/// heroes, `.itm`/`.wpn` items (Sullivan's transmitter, the fist at `place` 200).
pub fn createHeroes(self: *World) !void {
    for (self.res.common.entries) |e| {
        if (!std.ascii.startsWithIgnoreCase(e.name, "gamestart\\")) continue;
        const file = e.name["gamestart\\".len..];
        const ext = std.fs.path.extension(file);
        const kind = state_object.kindOf(ext);
        if (kind != .actor and kind != .item and kind != .weapon) continue;
        const cls = self.rt.loadClass(file) catch |err| {
            std.log.warn("gamestart {s}: {t}", .{ file, err });
            continue;
        };
        const hero = kind == .actor;
        _ = try self.addObject(file[0 .. file.len - ext.len], cls, .{ .kind = kind, .hero = hero, .hro = hero, .fighter = hero });
    }
}

pub fn createObjects(self: *World) !void {
    for (self.res.other.entries) |e| _ = try self.addScriptObject(e.name);
    try mods.createLevelObjects(self);
}

/// Location creation, part one (0x431886): `.var` and init() of every object but the level,
/// then the level's init(). Part two is `startRestore`.
pub fn startInit(self: *World) !void {
    // Length is snapshotted: in the exe new objects (Ambient_New in init()) go to the head
    // of list [0x63bcb8] while the walk goes from the head along +0x2c0, so it never sees them.
    const objs = &self.rt.objects;
    for (0..objs.items.len) |i| {
        const o = objs.items[i];
        if (!o.enabled) continue;
        try loadVars(self, o);
        if (World.nativeOf(o).kind == .level) continue;
        try initObject(self, o);
    }
    if (self.level) |l| {
        _ = try self.rt.callIfExists(l, "initCamera", &.{});
        self.cam = makeCamera(self, l);
        _ = try self.rt.callIfExists(l, "init", &.{});
        // Combat level (restore 0x4b49f0): model scale and walk speed come from the grid
        // cell size over `.var`: xSize/350 and xSize·0.02.
        if (self.combat_map) |cm| if (l.getVar("isCombat") != null) {
            fields.setF(l, "actorScale", cm.cell_size[0] / 350.0);
            fields.setF(l, "speedScale", cm.cell_size[0] * 0.02);
        };
    }
}

/// Location creation, part two: restore() of the level and objects, post_init().
pub fn startRestore(self: *World) !void {
    const objs = &self.rt.objects;
    if (self.level) |l| _ = try self.rt.callIfExists(l, "restore", &.{});
    var i: usize = 0;
    while (i < objs.items.len) : (i += 1) {
        const o = objs.items[i];
        if (World.nativeOf(o).kind == .level or !World.nativeOf(o).kind.hooks().restore) continue;
        _ = try self.rt.callIfExists(o, "restore", &.{});
    }
    i = 0;
    while (i < objs.items.len) : (i += 1) {
        const o = objs.items[i];
        // post_init (+0x34) runs for every new object, enabled or not (0x4319c4…0x4319cf
        // only checks +0x74 "from the global list"): 02_serwers.post_init disables
        // MacFadden before her post_init, which creates her items (mf_pistol, mf_am_pistol…).
        if (!World.nativeOf(o).kind.hooks().post_init or World.nativeOf(o).from_party) continue;
        _ = try self.rt.callIfExists(o, "post_init", &.{});
    }
    for (objs.items) |o| {
        try updateVisibility(self, o);
        const n = World.nativeOf(o);
        if (n.kind == .actor and (o.getInt("x") != 0 or o.getInt("y") != 0)) n.actor.placed = true;
        if (n.kind == .actor and n.actor.anim.len == 0) n.actor.pickIdle(self.crt());
    }
}

pub fn updateVisibility(self: *World, o: *Object) !void {
    const n = World.nativeOf(o);
    if (n.kind != .animation and n.kind != .active_animation) return;
    n.visible = if (try self.rt.callIfExists(o, "allowRender", &.{})) |v| v.truthy() else true;
}

fn loadVars(self: *World, o: *Object) !void {
    var buf: [archive.name_size]u8 = undefined;
    const name = try std.fmt.bufPrint(&buf, "variables\\{s}.var", .{o.name});
    const e = self.res.common.find(name) orelse return;
    const text = try self.res.common.readAlloc(self.io, self.rt.strings(), e);
    var v = try vars.parse(self.gpa, text);
    defer v.deinit(self.gpa);
    for (v.entries) |entry| self.rt.applyVar(o, entry.key, entry.value);
}

/// BitmapAnimation::Init (0x4b3db0): cur_frame = 0, script init(), default speed 15.
fn initObject(self: *World, o: *Object) !void {
    const n = World.nativeOf(o);
    const is_anim = n.kind == .animation or n.kind == .active_animation;
    if (is_anim) o.setInt("cur_frame", 0);
    _ = try self.rt.callIfExists(o, "init", &.{});
    if (is_anim and o.getInt("speed") == 0) o.setInt("speed", world.default_speed);
    if (n.kind == .actor) try actorHooks(self, o);
}

/// After an actor's init() (0x4225d0): additionalIdleAnims() — idles for states 7 and 8 —
/// then postinit() (heroes: ReferenceAnimation, NotInPlaceAnimation).
pub fn actorHooks(self: *World, o: *Object) !void {
    // Battle sets 7/8 and sleep 6 are copies of 0/1/0 (0x422694…0x4226ae).
    const a = world.actorOf(o);
    try a.copyState(self.gpa, 0, 7);
    try a.copyState(self.gpa, 1, 8);
    try a.copyState(self.gpa, 0, 6);
    _ = try self.rt.callIfExists(o, "additionalIdleAnims", &.{});
    _ = try self.rt.callIfExists(o, "postinit", &.{});
}

/// Camera from level vars after initCamera(): perspective when perspective=1.
fn makeCamera(self: *World, l: *Object) camera.Camera {
    if (l.getInt("perspective") == 0) return .ortho;
    const size = backgroundSize(self) orelse return .ortho;
    const f = fields.getF;
    const p = camera.Persp.initBank(
        .{ f(l, "viewX"), f(l, "viewY"), f(l, "viewZ") },
        .{ f(l, "aimX"), f(l, "aimY"), f(l, "aimZ") },
        f(l, "angle"),
        f(l, "cameraScale"),
        f(l, "zLevel"),
        @floatFromInt(size[0]),
        @floatFromInt(size[1]),
        f(l, "camBan"),
    ) orelse return .ortho;
    return .{ .persp = p.withAspect(f(l, "aspectRatio")) };
}

pub fn backgroundSize(self: *World) ?[2]u32 {
    var buf: [archive.name_size]u8 = undefined;
    for ([_][]const u8{ "bkg", "jpg" }) |ext| {
        const name = std.fmt.bufPrint(&buf, "background\\{s}.{s}", .{ self.level_name, ext }) catch return null;
        const e = self.res.sprites.find(name) orelse continue;
        if (ext[0] == 'b') {
            var head: [20]u8 = undefined;
            if ((self.res.sprites.file.readPositionalAll(self.io, &head, e.offset) catch return null) != 20) return null;
            return .{ std.mem.readInt(u32, head[12..16], .little), std.mem.readInt(u32, head[16..20], .little) };
        }
        const data = self.res.sprites.readAlloc(self.io, self.gpa, e) catch return null;
        defer self.gpa.free(data);
        return jpeg.size(data);
    }
    return null;
}

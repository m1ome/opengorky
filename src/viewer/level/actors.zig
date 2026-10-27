//! Actor layer: visible actor selection, scale and hand weapons, light and ice, threaded software model raster, shadows. Background depth: level/depth.zig; layer texture and upload: level/layer.zig.

const std = @import("std");
const depth = @import("depth.zig");
const effects_view = @import("effects_view.zig");
const billboards = @import("billboards.zig");
const place = @import("place.zig");
const layer_mod = @import("layer.zig");
const level_view = @import("../level.zig");
const LevelView = level_view.LevelView;
const og = @import("opengorky");
const lf = og.formats.level_files;
const render_layer = og.render.layer;
const Image = og.formats.image.Image;
const world_mod = og.state.world;
const World = world_mod.World;
const c = @import("sdl");
const LayerKey = LevelView.LayerKey;
const gfx = @import("../media/gfx.zig");
const perf = @import("../app/perf.zig");
const Canvas = og.render.raster.Canvas;

/// Object model height on world screen (feet to crown); null without a model.
pub fn modelHeight(self: *LevelView, o: *og.script.object.Object) ?f32 {
    const m = (self.models orelse return null).get(og.fields.meshFile(o)) orelse return null;
    return (m.top_y - m.base_y) * self.world.actorScale() * m.unitScale() * self.world.cam.aspect();
}
/// Ice on a frozen fighter (0x4dc700): the level moves toward 4 (frozen) or 0 by
/// 1 every 2 ticks; texture `{5 − level}.3df`.
fn iceTexture(self: *LevelView, o: *og.script.object.Object) ?Image {
    const b = &(self.world.battle orelse return null);
    const fi = b.fighterOf(o) orelse return null;
    const frozen = b.fighters.items[fi].frozen > 0 and b.fighters.items[fi].alive();
    if (!self.ice_loaded) {
        self.ice_loaded = true;
        if (self.models) |m| for (&self.ice, 0..) |*im, k| {
            var buf: [40]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "gfx_3d\\textures\\{d}.3df", .{k + 1}) catch continue;
            const bytes = m.readFile(path) catch continue;
            im.* = og.formats.tex3df.decode(self.gpa, bytes) catch null;
        };
    }
    const gop = self.ice_level.getOrPut(self.gpa, o) catch return null;
    if (!gop.found_existing) gop.value_ptr.* = 0;
    const dt: f32 = @floatFromInt(@min(self.world.ticks -% self.ice_tick, 30));
    const target: f32 = if (frozen) 4 else 0;
    const lv = gop.value_ptr;
    if (lv.* < target) lv.* = @min(target, lv.* + 0.5 * dt) else lv.* = @max(target, lv.* - 0.5 * dt);
    const lvl: usize = @intFromFloat(@floor(lv.*));
    if (lvl == 0) return null;
    return self.ice[@min(4, 5 - lvl) - 1];
}
/// `.lts` lamps and short effect lights (0x4321b0): shot flashes (effect list), a
/// rocket in flight (rocket1_light: (255,128,64), 900·aS — 0x49c0b3), current on a
/// shocked fighter (0x496d2c, case 1 of 0x496d10: (0.5, 0.5, 1), range
/// attack_shocker_light_range 600·aS — 0x496de6, at height attack_shocker_light_level
/// 500·aS — 0x496d3f).
fn dynamicLights(self: *LevelView, static: []const lf.Omni) ![]const lf.Omni {
    const w = self.world;
    const e = &w.effects;
    const as = w.actorScale();
    var list: std.ArrayList(lf.Omni) = .empty;
    const a = self.frame_arena.allocator();
    try list.appendSlice(a, static);
    for (e.lights.items) |l| try list.append(a, .{ .pos = l.pos, .color = l.color, .range = l.range });
    for (e.projectiles.items) |pr| if (pr.rocket and !pr.done)
        try list.append(a, .{ .pos = pr.pos, .color = gfx.rgb(255, 128, 64), .range = 900 * as });
    for (w.rt.objects.items) |o| {
        const n = World.nativeOf(o);
        if (n.kind != .actor or !n.actor.placed or n.actor.fx != .shock) continue;
        const p = og.fields.pos(o);
        try list.append(a, .{ .pos = .{ p[0], p[1], p[2] + og.formats.adjust.getFloat("attack_shocker_light_level", 500) * as }, .color = .{ 0.5, 0.5, 1 }, .range = og.formats.adjust.getFloat("attack_shocker_light_range", 600) * as });
    }
    return list.items;
}
/// Ground item blink (0x4ad960, 0x4adb20): if `visible` ≠ 0 and a party hero is
/// closer than flash_range·aS (1700), alpha = flash_min + (1 − flash_min)·|sin(t·
/// flash_speed)| (0.4, 4; t in seconds); outside battle and with no windows open.
fn itemFlash(self: *LevelView, o: *og.script.object.Object) f32 {
    const w = self.world;
    if (w.battle != null or w.scene.cutscene or self.ui_modal) return 1;
    if (o.getInt("visible") == 0) return 1;
    const p = og.fields.pos(o);
    const range = og.formats.adjust.getFloat("flash_range", 1700) * self.world.actorScale();
    var near = false;
    const heroes = w.party();
    for (heroes.slice()) |h| {
        const q = og.fields.pos(h);
        const dx = q[0] - p[0];
        const dy = q[1] - p[1];
        if (dx * dx + dy * dy <= range * range) near = true;
    }
    if (!near) return 1;
    const t = og.num.toF32(w.ticks) / og.state.world.tick_hz;
    const lo = og.formats.adjust.getFloat("flash_min", 0.4);
    return lo + (1 - lo) * @abs(@sin(t * og.formats.adjust.getFloat("flash_speed", 4)));
}
/// A `classType` 5 fighter (factory 0x4bc6c0 → class 0x4bcf70, table 0x50df40) is
/// not drawn: its draw +0x50 is an empty `ret` (0x4bcf90). These are the monitors
/// in 03__museum_monitor — targets with HP and no model (meshFile "garcia" in data).
/// In battle a fighter not taking part (off the battle grid — a party hero the
/// battle script didn't place) is not drawn (roster.participates).
fn sidelined(self: *LevelView, o: *og.script.object.Object) bool {
    const b = &(self.world.battle orelse return false);
    if (!og.fields.isFighter(o)) return false;
    const n = World.nativeOf(o);
    if (n.fight.appear != null or n.fight.bomb_timer != null or n.fight.decoy) return false;
    return b.fighterOf(o) == null;
}

fn unseenFighter(o: *og.script.object.Object) bool {
    const v = o.getVar("classType") orelse return false;
    return v.value == .int and v.value.int == 5 and o.getVar("charSize") != null;
}
/// Actor passes (0x42a2e0, 0x42a620, 0x4dc700): transparency, materialisation
/// (v ≥ 0.6 — model at alpha v, else only the glow (0.2v, 0.3v, v)), ice over a
/// frozen fighter, "current" on a shocked one (UV·3 + (s, cos 2πs),
/// s = ((9·T) & 255)/255). false — the actor is invisible.
fn actorPasses(self: *LevelView, o: *og.script.object.Object, a: *const og.actor.Actor, pl: *render_layer.Layer.Placement) bool {
    if (a.fxLevel()) |v| {
        if (v >= 0.6) pl.alpha = v else {
            pl.hidden = true;
            pl.tint = .{ 0.2 * v, 0.3 * v, v };
        }
    } else if (a.alpha == 0) {
        return false;
    } else pl.alpha = og.num.toF32(a.alpha) / 255;
    // During a morph depth is not written (0x42a8bd).
    if (a.morph_left > 0) pl.depth_write = false;
    if (iceTexture(self, o)) |ice| pl.overlays[0] = .{ .tex = ice };
    if (a.fx == .shock) if (currentTexture(self)) |cur| {
        const sv: f32 = og.num.toF32((9 *% self.world.ticks) & 255) / 255;
        pl.overlays[1] = .{ .tex = cur, .uv_scale = 3, .uv_offset = .{ sv, @cos(2 * std.math.pi * sv) }, .wrap = true };
    };
    return true;
}
/// Batch billboards (billboards.zig) into the layer on combat levels, after models
/// and shadows: the particle flush (0x45d8d0) keeps the z-test on there.
const LayerSink = struct {
    self: *LevelView,
    layer: *render_layer.Layer,
    models: *og.actor.model_cache.Cache,
    drew: *bool,
    pub fn put(s: LayerSink, b: billboards.Billboard) !void {
        const frames = effectFrames(s.self, s.models, b.name) orelse return;
        const d = s.models.effect(b.name) orelse return;
        // Modes 3 and 5 don't occur in the batch; opaque draws as alpha.
        const blend: render_layer.Layer.BillboardBlend = switch (d.blend) {
            .add => .add,
            .alpha, .opaque_ => .alpha,
            else => .screen,
        };
        const cam = s.self.world.cam;
        s.layer.billboard(cam, effects_view.billboardCorners(cam, b.pos, b.half), frames[b.frame % frames.len], b.alpha, b.rgb, blend);
        s.drew.* = true;
    }
};

/// `world.effects.attached` effects into the model layer (Layer.drawEffect). true
/// if something was drawn.
fn attachedEffects(self: *LevelView, layer: *render_layer.Layer, models: *og.actor.model_cache.Cache) !bool {
    var drew = false;
    const e = &self.world.effects;
    for (e.attached.items) |at| {
        if (at.delay > 0) continue;
        const n = World.nativeOf(at.actor);
        if (n.kind != .actor or !n.actor.placed or !at.actor.enabled or n.deleted) continue;
        const model = models.get(og.fields.meshFile(at.actor)) orelse continue;
        const pl = place.placement(self, at.actor, model) orelse continue;
        const mesh = models.get(at.mesh) orelse continue;
        const link = model.mesh.holdMode(at.link) orelse continue;
        const frames = effectFrames(self, models, at.effect) orelse continue;
        const tex = frames[@intCast((e.ticks -% at.start) % frames.len)];
        try layer.drawEffect(self.frame_arena.allocator(), self.world.cam, model, pl, .{ .model = mesh, .link = link, .offset = at.offset, .rot = at.rot, .scale = at.scale }, tex);
        drew = true;
    }
    return drew;
}
/// Frames of effect `gfx_3d\effects\<name>` (per .dsc), once per name.
fn effectFrames(self: *LevelView, models: *og.actor.model_cache.Cache, name: []const u8) ?[]Image {
    var key_buf: [64]u8 = undefined;
    if (name.len == 0 or name.len > key_buf.len) return null;
    const key = std.ascii.lowerString(&key_buf, name);
    if (self.effect_frames.get(key)) |f| return if (f.len > 0) f else null;
    const d = models.effect(name) orelse return null;
    var list: std.ArrayList(Image) = .empty;
    for (d.frames.items) |f| {
        var buf: [160]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "gfx_3d\\effects\\{s}\\{s}", .{ name, f }) catch continue;
        const bytes = models.readFile(path) catch continue;
        const img = og.formats.tex3df.decode(self.gpa, bytes) catch continue;
        list.append(self.gpa, img) catch break;
    }
    const owned = list.toOwnedSlice(self.gpa) catch return null;
    const k = self.gpa.dupe(u8, key) catch return null;
    self.effect_frames.put(self.gpa, k, owned) catch return null;
    return if (owned.len > 0) owned else null;
}
fn currentTexture(self: *LevelView) ?Image {
    if (!self.current_loaded) {
        self.current_loaded = true;
        if (self.models) |m| if (m.readFile("gfx_3d\\textures\\current.3df")) |bytes| {
            self.current_tex = og.formats.tex3df.decode(self.gpa, bytes) catch null;
        } else |_| {};
    }
    return self.current_tex;
}
/// Fighter's hand weapon (0x42b300): battle only, the weapon's `meshFile` model on
/// the actor model's `two_hands` / `one_hand` point.
fn weaponInHand(self: *LevelView, o: *og.script.object.Object, model: *const og.actor.model_cache.Model) ?render_layer.Layer.Attachment {
    const models = self.models orelse return null;
    if (world_mod.actorOf(o).scene_weapon) |sw| {
        const wm = models.get(sw.mesh) orelse return null;
        return holdOn(model, wm, if (sw.two_hands) "two_hands" else "one_hand");
    }
    const b = &(self.world.battle orelse return null);
    for (b.fighters.items) |f| {
        if (f.obj != o) continue;
        const wpn = f.weapon orelse return null;
        if (world_mod.actorOf(o).weapon_detached) return null; // asleep: taken off the hand (0x490397)
        // In defence (stance 4, `def_loop`) the weapon isn't drawn — a deviation at
        // the player's request: one pose for all weapons, no grip, so the weapon hung
        // backwards. During a counterattack the stance is already combat — drawn.
        if (f.defending and world_mod.actorOf(o).state == 4) return null;
        if (!og.inventory.equipment.weaponVisible(og.fields.nameId(o), og.fields.nameId(wpn))) return null;
        const wm = models.get(og.fields.meshFile(wpn)) orelse return null;
        return holdOn(model, wm, if (wpn.getInt("two_handed") == 1) "two_hands" else "one_hand");
    }
    return null;
}
/// Meshes on the actor's link points (ActivateLink).
fn linkedMeshes(self: *LevelView, o: *og.script.object.Object, model: *const og.actor.model_cache.Model) []const render_layer.Layer.Attachment {
    const models = self.models orelse return &.{};
    const links = world_mod.actorOf(o).links.items;
    var out: std.ArrayList(render_layer.Layer.Attachment) = .empty;
    const a = self.frame_arena.allocator();
    for (links) |l| {
        const m = models.get(l.mesh) orelse continue;
        var at = holdOn(model, m, l.link) orelse continue;
        if (l.anim.len > 0) {
            // The first one holds its first frame through the transition from frame 0
            // (0x44f910 with length 8, as the actor's `anim_hold`), then runs.
            const bt = og.actor.Actor.blend_ticks;
            const e = self.world.ticks -| l.anim_from;
            const hold = if (l.blend) bt -| e else 0;
            at.frame = m.frameOf(l.anim, @floatFromInt(if (l.blend) e -| bt else e), false);
            if (hold > 0) {
                const w = @min(1, @as(f32, @floatFromInt(bt - hold)) / @as(f32, @floatFromInt(bt - 1)));
                at.model = og.actor.model_cache.blended(a, m, 0, null, @splat(0), at.frame, w) catch return out.items;
                at.frame = 0;
            }
        }
        out.append(a, at) catch return out.items;
    }
    // Actors riding it (LinkActor): their meshes in their own animations (0x4297b4).
    for (self.world.rt.objects.items) |rider| {
        const n = World.nativeOf(rider);
        if (n.kind != .actor or n.actor.attached_to != o or !rider.enabled or n.deleted) continue;
        const lp = n.actor.link_point orelse continue;
        const m = models.get(og.fields.meshFile(rider)) orelse continue;
        out.append(a, .{ .model = m, .link = lp, .frame = n.actor.frameIn(m) }) catch return out.items;
    }
    return out.items;
}
fn holdOn(model: *const og.actor.model_cache.Model, wm: *const og.actor.model_cache.Model, link: []const u8) ?render_layer.Layer.Attachment {
    return .{ .model = wm, .link = model.mesh.holdMode(link) orelse return null };
}
pub fn drawActors(self: *LevelView, r: *c.SDL_Renderer, scroll: [2]f32) !void {
    const layer = &(self.layer orelse return);
    layer.shadow_debug = self.debug.shadow_debug;
    const models = self.models orelse return;
    const tex = self.layer_tex orelse return;
    const key: LayerKey = .{
        .world = @intFromPtr(self.world),
        .ticks = self.world.ticks,
        .scroll = scroll,
        .pixels = @intFromPtr(layer.canvas.img.pixels.ptr),
        .width = layer.canvas.img.width,
        .height = layer.canvas.img.height,
        .shadows = self.shadows,
        .ui_modal = self.ui_modal,
    };
    if (self.debug.layer_cache) if (self.layer_key) |k| if (std.meta.eql(k, key)) {
        // Same world tick and camera: the layer and texture are ready.
        if (self.layer_any) try present(self, r, tex, layer);
        return;
    };
    self.layer_key = key;
    self.layer_any = false;
    self.hero_box = null;
    defer self.ice_tick = self.world.ticks;
    _ = self.frame_arena.reset(.retain_capacity);
    const src = depth.depthSource(self);
    var pt = perf.now();
    layer.begin(scroll, src);
    layer.light = if (self.level.lights) |lt| .{ .ambient = lt.ambient, .directional = lt.directional_color, .omni = lt.omni } else .{};
    layer.light.omni = try dynamicLights(self, layer.light.omni);
    // z pass (0x420686): z-frames of visible objects with `zbufFile` over the
    // background, so actors behind an open gate hide; frame = cur_frame % frames.
    // Order as for animations (from the list end, see draw).
    var zi = self.world.rt.objects.items.len;
    while (zi > 0) {
        zi -= 1;
        const o = self.world.rt.objects.items[zi];
        const n = World.nativeOf(o);
        if (n.kind != .animation and n.kind != .active_animation) continue;
        if (!o.enabled or n.deleted or !n.visible) continue;
        const spz = self.spzFrames(o.getString("zbufFile")) orelse continue;
        const frames = spz.sprite.frames;
        const k: usize = @intCast(@mod(o.getInt("cur_frame"), @as(i32, @intCast(frames.len))));
        layer.overlayDepth(frames[k], o.getInt("pos_x"), o.getInt("pos_y"), src);
    }
    perf.add(.layer_begin, pt);
    pt = perf.now();
    var any = false;
    const scale = self.world.actorScale() * self.debug.scale_tweak;
    // Shadows (0x4206dc, 0x42097e): light `shadowLight` from .lts; off with
    // disable_shadows or a light below the floor.
    if (self.shadows) if (self.level.lights) |lt| {
        for (self.world.rt.objects.items) |o| {
            if (!drawnActor(self, o)) continue;
            const n = World.nativeOf(o);
            if (n.actor.alpha == 0 and n.actor.fxLevel() == null) continue;
            const raw = models.get(og.fields.meshFile(o)) orelse continue;
            var pl = place.placement(self, o, raw) orelse continue;
            const model = try place.posed(self, o, raw, &pl);
            const mf = og.fields.meshFile(o);
            const all = std.ascii.eqlIgnoreCase(mf, "rura") or std.ascii.eqlIgnoreCase(mf, "fang");
            try layer.castShadow(self.frame_arena.allocator(), self.world.cam, model, pl, lt.shadow_light, all);
        }
    };
    perf.add(.shadow_cast, pt);
    pt = perf.now();
    // Model triangles are recorded, then rasterised in screen bands on threads.
    layer.canvas.record(self.gpa);
    // Ground items: the item's `meshFile` model at the item's `scale`. Before the
    // actors: their depth bias is for the background only (layer.Placement.depth_bias),
    // against actors they sort by true depth as in the exe (0x4adb20 → 0x44d310).
    for (self.world.rt.objects.items) |o| {
        if (!og.state.world.isGroundItem(o)) continue;
        const model = models.get(og.fields.meshFile(o)) orelse continue;
        const n = World.nativeOf(o);
        const item_scale = og.fields.getF(o, "scale");
        try layer.draw(self.frame_arena.allocator(), self.world.cam, model, .{
            .pos = og.fields.pos(o),
            .angle = og.fields.modelAngle(og.fields.angle(o)),
            .scale = (if (item_scale > 0) item_scale else 1) * scale,
            .frame = n.actor.frameIn(model),
            .alpha = itemFlash(self, o),
            .depth_bias = og.render.depth_fit.fit.ground_item_bias,
        });
        n.actor.screen_box = if (layer.bbox[0] <= layer.bbox[2]) .{ layer.bbox[0] + scroll[0], layer.bbox[1] + scroll[1], layer.bbox[2] + scroll[0], layer.bbox[3] + scroll[1] } else null;
        any = true;
    }
    for (self.world.rt.objects.items) |o| {
        if (!drawnActor(self, o)) continue;
        const n = World.nativeOf(o);
        const raw = models.get(og.fields.meshFile(o)) orelse continue;
        var pl = place.placement(self, o, raw) orelse continue;
        const model = try place.posed(self, o, raw, &pl);
        pl.attach = weaponInHand(self, o, model);
        pl.extra = linkedMeshes(self, o, model);
        if (!actorPasses(self, o, &n.actor, &pl)) continue;
        try layer.draw(self.frame_arena.allocator(), self.world.cam, model, pl);
        var box = layer.bbox;
        any = true;
        // RegisterExtraBody (0x42a138): each extra mesh in the actor's place, the main mesh's
        // shift (+0x28) added to its own; not `still` — in the actor's animation with its own
        // player's transition (0x4233d5 → 0x44f910). The screen box takes them in (0x42a9da).
        for (&n.actor.extra_bodies) |*slot| if (slot.*) |*eb| if (models.get(eb.mesh)) |em| {
            const shifted = try self.frame_arena.allocator().create(og.actor.model_cache.Model);
            var ep = pl;
            ep.attach = null;
            ep.extra = &.{};
            ep.frame = 0;
            const em_posed = if (eb.still) em else blk: {
                const to = n.actor.frameIn(em);
                eb.last_frame = to;
                ep.frame = to;
                break :blk try place.posedState(self, eb, n.actor.blendWeight(), to, em, &ep);
            };
            shifted.* = em_posed.*;
            for (&shifted.mesh.center, raw.mesh.center) |*cc, mc| cc.* += mc;
            try layer.draw(self.frame_arena.allocator(), self.world.cam, shifted, ep);
            if (layer.bbox[0] <= layer.bbox[2]) box = .{ @min(box[0], layer.bbox[0]), @min(box[1], layer.bbox[1]), @max(box[2], layer.bbox[2]), @max(box[3], layer.bbox[3]) };
        };
        n.actor.screen_box = if (box[0] <= box[2]) .{ box[0] + scroll[0], box[1] + scroll[1], box[2] + scroll[0], box[3] + scroll[1] } else null;
        if (std.ascii.eqlIgnoreCase(o.name, self.world.selected_hero) and box[0] <= box[2]) self.hero_box = box;
    }
    // New morph model (0x4260a0): after a delay, idle animation, alpha from 50/255,
    // no depth write.
    for (self.world.effects.morphs.items) |mo| {
        if (mo.delay > 0) continue;
        const model = models.get(mo.mesh) orelse continue;
        try layer.draw(self.frame_arena.allocator(), self.world.cam, model, .{
            .pos = mo.pos,
            .angle = mo.angle,
            .scale = scale,
            .frame = model.frameOf(mo.anim, mo.anim_ticks, true),
            .alpha = og.num.toF32(mo.alpha) / 255,
            .depth_write = false,
        });
        any = true;
    }
    // Effects on link points (flashes, "nitro"): after all models, depth-tested
    // against the finished z-buffer, like the exe's z-test without depth write.
    if (try attachedEffects(self, layer, models)) any = true;
    layer.canvas.flush(layer_mod.rasterPool(self.io));
    perf.add(.models, pt);
    pt = perf.now();
    if (self.shadows) if (self.level.lights) |lt| {
        layer.compositeShadow(self.world.cam, lt.shadow_intensity, depth.shadowBias(self, src));
        any = true;
    };
    perf.add(.shadow_mix, pt);
    // Billboards recorded and rasterised in bands on threads too: explosions cover
    // much of the screen, one by one on this thread they took tens of ms per frame.
    if (self.world.isCombat()) {
        layer.canvas.record(self.gpa);
        try billboards.all(self, LayerSink{ .self = self, .layer = layer, .models = models, .drew = &any });
        layer.canvas.flush(layer_mod.rasterPool(self.io));
    }
    if (!any) return;
    self.layer_any = true;
    pt = perf.now();
    defer perf.add(.upload, pt);
    // Only what was drawn this frame and what was erased since the last goes to
    // the texture, by parts (models, shadows); outside them canvas and texture are empty.
    var up: [2 * Canvas.max_regions]Canvas.Rect = undefined;
    const old = self.tex_regions[0..self.n_tex_regions];
    const cur = layer.canvas.dirtyRegions();
    @memcpy(up[0..old.len], old);
    @memcpy(up[old.len..][0..cur.len], cur);
    var n = old.len + cur.len;
    @memcpy(self.tex_regions[0..cur.len], cur);
    self.n_tex_regions = cur.len;
    n = layer_mod.mergeRects(up[0..n]);
    for (up[0..n]) |u| try layer_mod.uploadRect(tex, layer.canvas.img.pixels, layer.canvas.img.width, u);
    if (layer.glow_used) if (self.glow_tex) |gt|
        try layer_mod.uploadRect(gt, layer.glow.pixels, layer.glow.width, .{ .x0 = 0, .y0 = 0, .x1 = layer.glow.width, .y1 = layer.glow.height });
    if (layer.screen_used) if (self.screen_tex) |st|
        try layer_mod.uploadRect(st, layer.screen.pixels, layer.screen.width, .{ .x0 = 0, .y0 = 0, .x1 = layer.screen.width, .y1 = layer.screen.height });
    try present(self, r, tex, layer);
}
/// Model layer, glow and screen billboards over the frame.
fn present(self: *LevelView, r: *c.SDL_Renderer, tex: *c.SDL_Texture, layer: *const render_layer.Layer) !void {
    try gfx.check(c.SDL_RenderTexture(r, tex, null, null));
    if (layer.glow_used) if (self.glow_tex) |gt| try gfx.check(c.SDL_RenderTexture(r, gt, null, null));
    if (layer.screen_used) if (self.screen_tex) |st| try gfx.check(c.SDL_RenderTexture(r, st, null, null));
}
/// An actor drawn by the model layer (and casting a shadow).
fn drawnActor(self: *LevelView, o: *og.script.object.Object) bool {
    const n = World.nativeOf(o);
    // A linked rider is drawn by its parent (0x42b210).
    return n.kind == .actor and n.actor.placed and n.actor.link_point == null and o.enabled and !n.deleted and !unseenFighter(o) and !sidelined(self, o);
}

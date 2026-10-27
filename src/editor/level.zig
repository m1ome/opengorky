//! An open level: the world after init()/restore() (as the game starts it), its
//! background and the objects the editor shows, in background coordinates.
//! Battle placement edits change the `.lev` text (placement.zig); it and the fighter
//! files are kept in the editor's Store, which saves them.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const placement = @import("placement.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const common_archive = store_mod.common_archive;
const trigger = @import("trigger.zig");
const World = og.state.world.World;
const lf = og.formats.level_files;
const archive = og.formats.archive;

pub const Kind = enum { enemy, hero, neutral, prop, item, actor, area };

pub const Obj = struct {
    name: []const u8,
    kind: Kind,
    /// Background point (feet / centre).
    pos: [2]f32,
    /// Battle fighter: corner tile (for AIEnemyAppear the tile it walks to) and size.
    tile: ?[2]i32 = null,
    size: u32 = 1,
    /// Battle prop: fractional grid point.
    grid: ?[2]f32 = null,
    /// Its placement call in restore() (index into `script.calls`); null — not editable.
    call: ?usize = null,
    /// Added in the editor (dropped when undo takes its call away).
    added: bool = false,
    /// A box made in the editor: its script (Store index; undo takes it away).
    file: ?usize = null,
    /// An area (trigger, exit…): its polygon, background pixels.
    poly: ?[]const [3]f32 = null,
    /// A reinforcement: the n-th AIEnemyAppear of this name in CombatEnemiesAppear
    /// (later ones are fallback tiles). Not on the grid at the start.
    later: ?u8 = null,
    /// A location's hero kept disabled (shown by a scene or script later).
    hidden: bool = false,
};

/// A battle enemy's files: its `.ftr`, weapons and their classes (Store indices).
pub const Enemy = struct {
    name: []const u8,
    ftr: usize,
    class: ?usize,
    wpn: [4]usize = undefined,
    wpn_class: [4]?usize = undefined,
    n_wpn: usize = 0,
};

/// An enemy to copy into a battle: the first fighter of each class in the game.
pub const Template = struct {
    /// Class name: `ft_<class>.ss`.
    class: []const u8,
    /// A class made in the editor: the game class it copies (whose fighter is used).
    base: ?[]const u8 = null,
    level: []const u8,
    fighter: []const u8,
    /// Some `.wpn` of the level names it as Owner.
    armed: bool = false,
    /// No fighter of it in the game's battles (`level` empty): built from the class as
    /// the battles' own, with a close attack of this weapon class.
    weapon: ?[]const u8 = null,
};

/// A drag in progress: the object and where it would land.
pub const Preview = struct {
    obj: usize,
    tile: [2]i32 = .{ 0, 0 },
    grid: [2]f32 = .{ 0, 0 },
    /// Location: the background point it goes to.
    bg: ?[2]f32 = null,
    ok: bool = false,
};

pub const Doc = struct {
    gpa: Allocator,
    store: *Store,
    name: []const u8,
    /// `<name>/other.dat`.
    level_archive: []u8 = &.{},
    /// The level's areas as edited (its `.ar` changed in the Store); null: the world's.
    own_areas: ?[]lf.Area = null,
    world: *World,
    bg: ?*c.SDL_Texture = null,
    /// Walkable cells of the location (made on first show).
    walk_tex: ?*c.SDL_Texture = null,
    /// Map icons (facing arrowhead, turn left, turn right), made on first draw.
    icons: ?[3]*c.SDL_Texture = null,
    bg_size: [2]f32 = .{ 640, 480 },
    objects: std.ArrayList(Obj) = .empty,
    /// Script files of the level archive (`.lev`, `.are`, `.itm`…), for searching names.
    scripts: std.ArrayList([]u8) = .empty,
    /// Names of party heroes the battle places but the editor's world lacks (Medusa, BT
    /// before joining): their objects' names (call names live in the edited text).
    party_names: std.ArrayList([]u8) = .empty,
    /// Boxes deleted (their script's Store index), for undo to bring back.
    removed: std.ArrayList(struct { file: usize, obj: Obj }) = .empty,
    /// The level script (Store index) and its placement calls.
    lev: usize = 0,
    script: placement.Script = .{ .calls = &.{}, .restore_close = null },
    preview: ?Preview = null,
    /// Removal refused: the file naming the object.
    ref_file: [128]u8 = undefined,
    ref_len: usize = 0,
    /// View: background point at the viewport's top-left and points per background pixel.
    origin: [2]f32 = .{ 0, 0 },
    zoom: f32 = 1,
    fitted: bool = false,
    /// The level edit mode's battle grid, drawn instead of the level's (or none drawn).
    grid_view: ?lf.CombatMap = null,
    grid_hidden: bool = false,
    /// Objects the editor's view leaves out (names, and `kind:<kind>` for whole kinds); set
    /// by the app before drawing.
    view_hidden: ?*const std.StringHashMapUnmanaged(void) = null,
    /// Walk grid cells of the largest connected walkable region (made on first use).
    main_area: ?[]bool = null,
    /// Which load this is (a reload is another): pictures made of its world know it.
    serial: u32 = 0,

    var loads: u32 = 0;

    pub fn load(st: *Store, r: *c.SDL_Renderer, name: []const u8) !*Doc {
        const gpa = st.gpa;
        const io = st.io;
        const dat = st.dat;
        const world = try og.game.life.create(io, gpa, dat, name, null, .{});
        errdefer world.destroy();
        const self = try gpa.create(Doc);
        errdefer gpa.destroy(self);
        loads += 1;
        self.* = .{ .gpa = gpa, .store = st, .name = name, .world = world, .serial = loads };
        errdefer self.freeEdits();
        self.level_archive = try std.fmt.allocPrint(gpa, "{s}/other.dat", .{name});
        self.loadBackground(io, r, dat, name) catch |err| std.log.warn("{s}: background: {t}", .{ name, err });
        try self.loadScript();
        try self.applyEdits();
        try self.collect();
        self.bind();
        return self;
    }

    /// The camera keys of initCamera() the level edit mode changes.
    pub const camera_keys = [_][]const u8{ "viewX", "viewY", "viewZ", "aimX", "aimY", "aimZ", "angle", "zLevel", "camBan" };

    /// Unsaved edits the world (read from disk) lacks: the battle grid (`.cm`) and
    /// the camera of initCamera() from the Store's texts.
    fn applyEdits(self: *Doc) !void {
        const w = self.world;
        var nb: [160]u8 = undefined;
        if (self.store.find(self.level_archive, try std.fmt.bufPrint(&nb, "{s}.cm", .{self.name}))) |f| {
            if (lf.parseCombatMap(w.arena_state.allocator(), self.store.text(f))) |cm| {
                w.combat_map = cm;
            } else |_| {}
        }
        const l = w.level orelse return;
        inline for (camera_keys) |k| if (@import("newlevel.zig").cameraVar(self.text(), k)) |v| og.fields.setF(l, k, v);
        w.cam = og.world.start.makeCamera(w, l);
    }

    fn freeEdits(self: *Doc) void {
        self.objects.deinit(self.gpa);
        self.script.deinit(self.gpa);
        self.removed.deinit(self.gpa);
        for (self.scripts.items) |n| self.gpa.free(n);
        self.scripts.deinit(self.gpa);
        for (self.party_names.items) |n| self.gpa.free(n);
        self.party_names.deinit(self.gpa);
        self.gpa.free(self.level_archive);
        if (self.main_area) |ma| self.gpa.free(ma);
        self.main_area = null;
    }

    pub fn deinit(self: *Doc) void {
        if (self.bg) |t| c.SDL_DestroyTexture(t);
        if (self.walk_tex) |t| c.SDL_DestroyTexture(t);
        if (self.icons) |ts| for (ts) |t| c.SDL_DestroyTexture(t);
        self.freeEdits();
        if (self.own_areas) |o| lf.freeAreas(self.gpa, o);
        self.world.destroy();
        self.gpa.destroy(self);
    }

    fn loadScript(self: *Doc) !void {
        var buf: [256]u8 = undefined;
        {
            var ar = try archive.Archive.open(self.store.io, self.gpa, self.store.dat, self.level_archive);
            defer ar.close(self.store.io, self.gpa);
            for (ar.entries) |e| for ([_][]const u8{ ".lev", ".are", ".itm", ".ftr", ".hro", ".obs", ".obs_i", ".wpn" }) |x| {
                if (!std.ascii.endsWithIgnoreCase(e.name, x)) continue;
                const n = try self.gpa.dupe(u8, e.name);
                self.scripts.append(self.gpa, n) catch |err| {
                    self.gpa.free(n);
                    return err;
                };
                break;
            };
        }
        self.lev = try self.store.file(self.level_archive, try std.fmt.bufPrint(&buf, "{s}.lev", .{self.name}));
        self.script = try placement.scan(self.gpa, self.text());
    }

    /// The level script as edited.
    pub fn text(self: *const Doc) []const u8 {
        return self.store.text(self.lev);
    }

    fn loadBackground(self: *Doc, io: Io, r: *c.SDL_Renderer, dat: Io.Dir, name: []const u8) !void {
        var lvl = try og.formats.level.load(io, self.gpa, dat, name);
        defer lvl.deinit();
        const entry_name = lvl.background orelse return;
        var buf: [256]u8 = undefined;
        var sprites = try archive.Archive.open(io, self.gpa, dat, try std.fmt.bufPrint(&buf, "{s}/sprite.dat", .{name}));
        defer sprites.close(io, self.gpa);
        const data = try sprites.readAlloc(io, self.gpa, sprites.find(entry_name) orelse return error.NotFound);
        defer self.gpa.free(data);
        var img = switch (og.formats.resource.kindOf(entry_name)) {
            .background => try og.formats.background.decode(self.gpa, data),
            else => try og.formats.jpeg.decode(self.gpa, data),
        };
        defer img.deinit(self.gpa);
        const t = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, @intCast(img.width), @intCast(img.height)) orelse return error.Texture;
        _ = c.SDL_UpdateTexture(t, null, img.pixels.ptr, @intCast(img.width * 4));
        self.bg = t;
        self.bg_size = .{ @floatFromInt(img.width), @floatFromInt(img.height) };
    }

    pub fn isBattle(self: *const Doc) bool {
        return self.world.battle != null and self.world.combat_map != null;
    }

    /// Battle: fighters on the grid and props placed by PlaceCombatActor. Elsewhere:
    /// actors and items lying on the level.
    fn collect(self: *Doc) !void {
        const w = self.world;
        if (w.battle) |b| if (w.combat_map) |cm| {
            for (b.fighters.items) |f| {
                if (f.appear_to == null and (f.tile[0] < 0 or f.tile[1] < 0)) continue;
                const t = f.appear_to orelse f.tile;
                try self.objects.append(self.gpa, .{
                    .name = f.obj.name,
                    .kind = switch (f.side) {
                        .enemy => .enemy,
                        .hero => .hero,
                        .neutral => .neutral,
                    },
                    .pos = self.tilePos(cm, t, f.size),
                    .tile = t,
                    .size = f.size,
                });
            }
            // Reinforcements (disabled, not fighters yet): the name from the runtime
            // (call names point into the script text, which edits replace).
            for (self.script.calls, 0..) |call, ci| {
                if (call.func != .enemy_appear or !call.in_appear) continue;
                const o = w.rt.findObject(call.name) orelse continue;
                const size = og.combat.roster.fighterSize(o);
                var nth: u8 = 0;
                for (self.objects.items) |p| nth += @intFromBool(p.later != null and p.name.ptr == o.name.ptr);
                const t: [2]i32 = .{ @intFromFloat(call.arg(self.text(), 2).?), @intFromFloat(call.arg(self.text(), 3).?) };
                try self.objects.append(self.gpa, .{ .name = o.name, .kind = .enemy, .pos = self.tilePos(cm, t, size), .tile = t, .size = size, .call = ci, .later = nth });
            }
            for (self.script.calls) |call| {
                if (call.func != .place_combat or !call.in_restore) continue;
                const o = w.rt.findObject(call.name) orelse continue;
                const g: [2]f32 = .{ call.arg(self.text(), 0).?, call.arg(self.text(), 1).? };
                try self.objects.append(self.gpa, .{ .name = o.name, .kind = .prop, .pos = self.gridPos(cm, g), .grid = g });
            }
            // A PlaceActor naming no object of the battle: a hero coming with the party
            // (the editor's world has only the starting three).
            for (self.script.calls) |call| {
                if (call.func != .place_actor or !call.in_restore or w.rt.findObject(call.name) != null) continue;
                const x = call.arg(self.text(), 0) orelse continue;
                const y = call.arg(self.text(), 1) orelse continue;
                const t: [2]i32 = .{ @intFromFloat(x), @intFromFloat(y) };
                const name = try self.gpa.dupe(u8, call.name);
                try self.party_names.append(self.gpa, name);
                try self.objects.append(self.gpa, .{ .name = name, .kind = .hero, .pos = self.tilePos(cm, t, 1), .tile = t, .size = 1 });
            }
            return;
        };
        for (w.rt.objects.items) |o| {
            const n = World.nativeOf(o);
            if (n.deleted) continue;
            // The level's own heroes (its `.hro`: Medusa, BT before they join), hidden ones too.
            if (n.kind == .actor and n.hro) {
                if (self.heroFile(o.name) == null) continue;
                const q = w.cam.project(og.fields.pos(o));
                try self.objects.append(self.gpa, .{ .name = o.name, .kind = .hero, .pos = .{ q.x, q.y }, .hidden = !o.enabled });
                continue;
            }
            if (!o.enabled) continue;
            const kind: Kind = switch (n.kind) {
                .item => if (og.inventory.item.placeOf(o) == .ground and o.getInt("visible") != 0) .item else continue,
                // A weapon nobody holds lies there (the port's shotgun by the plank); its
                // `visible` is only the blink.
                .weapon => if (og.inventory.item.placeOf(o) == .ground and o.getString("Owner").len == 0) .item else continue,
                .actor => if (n.hro) continue else .actor,
                // An area holding items (the chief's safe): a box at its polygon's centre.
                .area => {
                    if (o.getString("itm_1").len == 0) continue;
                    const ar = og.world.areas.findArea(w, o.getString("areaName")) orelse continue;
                    var cxy: [2]f32 = .{ 0, 0 };
                    for (ar.points) |p| cxy = .{ cxy[0] + p[0], cxy[1] + p[1] };
                    const k: f32 = @floatFromInt(@max(1, ar.points.len));
                    try self.objects.append(self.gpa, .{ .name = o.name, .kind = .item, .pos = .{ cxy[0] / k, cxy[1] / k } });
                    continue;
                },
                else => continue,
            };
            const q = w.cam.project(og.fields.pos(o));
            try self.objects.append(self.gpa, .{ .name = o.name, .kind = kind, .pos = .{ q.x, q.y } });
        }
        // Areas (triggers, exits): scripts check the hero in them by name. An edited
        // `.ar` (new, renamed, removed areas) over the one the world read from disk.
        var nb: [160]u8 = undefined;
        const areas = blk: {
            const f = self.store.find(self.level_archive, std.fmt.bufPrint(&nb, "{s}.ar", .{self.name}) catch break :blk w.areas) orelse break :blk w.areas;
            if (self.own_areas) |o| lf.freeAreas(self.gpa, o);
            self.own_areas = lf.parseAreas(self.gpa, self.store.text(f)) catch null;
            break :blk self.own_areas orelse w.areas;
        };
        for (areas) |ar| {
            if (ar.points.len < 3) continue;
            var cxy: [2]f32 = .{ 0, 0 };
            for (ar.points) |p| cxy = .{ cxy[0] + p[0], cxy[1] + p[1] };
            const k: f32 = @floatFromInt(ar.points.len);
            try self.objects.append(self.gpa, .{ .name = ar.name, .kind = .area, .pos = .{ cxy[0] / k, cxy[1] / k }, .poly = ar.points });
        }
    }

    /// Links battle objects to their restore() placement calls (after every rescan).
    pub fn bind(self: *Doc) void {
        if (!self.isBattle()) return;
        for (self.objects.items) |*o| {
            o.call = null;
            if (o.later) |nth| {
                var n: u8 = 0;
                for (self.script.calls, 0..) |call, i| {
                    if (call.func != .enemy_appear or !call.in_appear or !std.ascii.eqlIgnoreCase(call.name, o.name)) continue;
                    if (n == nth) o.call = i;
                    n += 1;
                }
                continue;
            }
            for (self.script.calls, 0..) |call, i| {
                if (!call.in_restore or !std.ascii.eqlIgnoreCase(call.name, o.name)) continue;
                if ((o.kind == .prop) != (call.func == .place_combat)) continue;
                o.call = i;
                break;
            }
        }
    }

    pub fn tilePos(self: *const Doc, cm: lf.CombatMap, t: [2]i32, size: u32) [2]f32 {
        const q = self.world.cam.project(cm.tileCenter(t, size));
        return .{ q.x, q.y };
    }

    pub fn gridPos(self: *const Doc, cm: lf.CombatMap, g: [2]f32) [2]f32 {
        const q = self.world.cam.project(cm.toWorld(g[0], g[1]));
        return .{ q.x, q.y };
    }

    // ------------------------------------------------------------ editing

    /// Grid coordinates (fractional cells) under screen point `s`.
    pub fn gridAt(self: *const Doc, rect: c.SDL_FRect, s: [2]f32) ?[2]f32 {
        const cm = self.world.combat_map orelse return null;
        const h = switch (self.world.cam) {
            .persp => |pc| cm.center[2] - pc.zlevel / pc.scale,
            .ortho => cm.center[2],
        };
        const bgp = self.toBackground(rect, s);
        const p = self.world.cam.unproject(bgp[0], bgp[1], h);
        return cm.toGrid(p[0], p[1]);
    }

    /// Updates the drag preview of object `i` for the pointer at `s`.
    pub fn drag(self: *Doc, rect: c.SDL_FRect, i: usize, s: [2]f32) void {
        if (!self.isBattle()) {
            // A location item: only onto walkable floor.
            const b = self.toBackground(rect, s);
            self.preview = .{ .obj = i, .bg = b, .ok = self.walkableAt(b) };
            return;
        }
        const g = self.gridAt(rect, s) orelse return;
        const o = self.objects.items[i];
        var p: Preview = .{ .obj = i };
        if (o.grid != null) {
            p.grid = .{ @round(g[0] * 2) / 2, @round(g[1] * 2) / 2 };
            p.ok = self.gridOpen(p.grid);
        } else {
            const half = @as(f32, @floatFromInt(o.size)) / 2;
            p.tile = .{ @intFromFloat(@floor(g[0] - half + 0.5)), @intFromFloat(@floor(g[1] - half + 0.5)) };
            p.ok = self.canPlace(i, p.tile);
        }
        self.preview = p;
    }

    /// Grid point `g` (a barrel, a moving prop) is inside the grid on an open tile.
    pub fn gridOpen(self: *const Doc, g: [2]f32) bool {
        const cm = self.world.combat_map orelse return false;
        if (g[0] < 0 or g[1] < 0 or g[0] >= @as(f32, @floatFromInt(cm.width)) or g[1] >= @as(f32, @floatFromInt(cm.height))) return false;
        return !cm.blocked[@as(usize, @intFromFloat(g[1])) * cm.width + @as(usize, @intFromFloat(g[0]))];
    }

    /// Footprint of object `i` at corner tile `t` is inside the grid, open and free.
    pub fn canPlace(self: *const Doc, i: usize, t: [2]i32) bool {
        const cm = self.world.combat_map orelse return false;
        const me = self.objects.items[i];
        const n: i32 = @intCast(me.size);
        if (t[0] < 0 or t[1] < 0 or t[0] + n > cm.width or t[1] + n > cm.height) return false;
        var y = t[1];
        while (y < t[1] + n) : (y += 1) {
            var x = t[0];
            while (x < t[0] + n) : (x += 1) {
                if (cm.blocked[@as(usize, @intCast(y)) * cm.width + @as(usize, @intCast(x))]) return false;
            }
        }
        for (self.objects.items, 0..) |o, k| {
            // Reinforcements come later (the script checks AIFreeTile then): no clash.
            if (k == i or o.later != null or me.later != null) continue;
            const ot = o.tile orelse continue;
            const on: i32 = @intCast(o.size);
            if (t[0] < ot[0] + on and ot[0] < t[0] + n and t[1] < ot[1] + on and ot[1] < t[1] + n) return false;
        }
        return true;
    }

    /// Applies the drag preview, if it is valid and moves the object.
    pub fn drop(self: *Doc) !void {
        const p = self.preview orelse return;
        self.preview = null;
        if (p.bg) |b| {
            const o = self.objects.items[p.obj];
            // A click without a drag: it stays.
            if (@abs(b[0] - o.pos[0]) + @abs(b[1] - o.pos[1]) < 3) return;
            if (!p.ok) return error.NotWalkable;
            return if (o.kind == .actor) self.moveActor(p.obj, b) else self.moveItem(p.obj, b);
        }
        if (!p.ok) return error.TileNotFree;
        const o = &self.objects.items[p.obj];
        const call = self.script.calls[o.call orelse return];
        var bufs: [4 + 2 * 9][24]u8 = undefined;
        var edits: [4 + 2 * 9]placement.Edit = undefined;
        var n: usize = 0;
        const cm = self.world.combat_map.?;
        if (o.grid) |g| {
            if (g[0] == p.grid[0] and g[1] == p.grid[1]) return;
            for (0..2) |k| {
                edits[n] = .{ .span = call.args[k], .text = try std.fmt.bufPrint(&bufs[k], "{d:.1}", .{p.grid[k]}) };
                n += 1;
            }
            try self.edit(edits[0..n]);
            o.grid = p.grid;
            o.pos = self.gridPos(cm, p.grid);
            return;
        }
        const old = o.tile.?;
        if (old[0] == p.tile[0] and old[1] == p.tile[1]) return;
        const new_args: [4]i32 = switch (call.func) {
            .place_actor => .{ p.tile[0], p.tile[1], 0, 0 },
            // The start moves with the target: the enemy keeps walking in from the same side.
            .enemy_appear => .{
                @as(i32, @intFromFloat(call.arg(self.text(), 0).?)) + p.tile[0] - old[0],
                @as(i32, @intFromFloat(call.arg(self.text(), 1).?)) + p.tile[1] - old[1],
                p.tile[0],
                p.tile[1],
            },
            .place_combat => unreachable,
        };
        const count: usize = if (call.func == .enemy_appear) 4 else 2;
        for (0..count) |k| {
            edits[n] = .{ .span = call.args[k], .text = try std.fmt.bufPrint(&bufs[k], "{d}", .{new_args[k]}) };
            n += 1;
        }
        // Its AIFreeTile checks move with it, so the script still tests the tiles it takes.
        for (call.guards[0..call.n_guards]) |g| for (0..2) |k| {
            const v = (std.fmt.parseInt(i32, self.text()[g[k].start..g[k].end], 10) catch continue) + p.tile[k] - old[k];
            edits[n] = .{ .span = g[k], .text = try std.fmt.bufPrint(&bufs[n], "{d}", .{v}) };
            n += 1;
        };
        try self.edit(edits[0..n]);
        o.tile = p.tile;
        o.pos = self.tilePos(cm, p.tile, o.size);
    }

    /// Removes object `i` from the level (its placement call; the object file stays,
    /// an unplaced fighter takes no part in the battle).
    pub fn remove(self: *Doc, i: usize) !void {
        // Its EnableObject and flags stay in the script: edited there, not here.
        if (self.objects.items[i].later != null) return error.Scripted;
        const call = self.script.calls[self.objects.items[i].call orelse return];
        var nb: [96]u8 = undefined;
        const name = try std.fmt.bufPrint(&nb, "{s}", .{self.objects.items[i].name});
        // Another script names it (a reinforcement, a target lock, a dialog): it stays,
        // the user is told where (`ref_file`).
        if (try self.namedIn(name, call.stmt)) |f| {
            const e = self.store.files.items[f].entry;
            const n = @min(e.len, self.ref_file.len);
            @memcpy(self.ref_file[0..n], e[0..n]);
            self.ref_len = n;
            return error.Referenced;
        }
        var edits = [_]placement.Edit{.{ .span = placement.lineOf(self.text(), call.stmt), .text = "" }};
        try self.edit(&edits);
        _ = self.objects.orderedRemove(i);
        self.bind();
        // Its files go too (a step of their own): the exe makes an object of every
        // script file and brings an enabled fighter nobody placed into the battle at the
        // grid corner — then crashes on its turn.
        try self.dropFiles(name);
    }

    /// The file naming object `name` (`ref_len` long) when removing it was refused.
    pub fn refFile(self: *const Doc) []const u8 {
        return self.ref_file[0..self.ref_len];
    }

    /// Script files of the level archive now: the archive's and the editor's new ones,
    /// without deleted ones (Store indices; read into the Store).
    pub fn levelFiles(self: *Doc, a: Allocator) ![]usize {
        var out: std.ArrayList(usize) = .empty;
        for (self.scripts.items) |n| {
            const f = self.store.file(self.level_archive, n) catch continue;
            try out.append(a, f);
        }
        for (self.store.files.items, 0..) |f, i| {
            if (!std.mem.eql(u8, f.archive, self.level_archive) or self.store.gone(i) or f.deleted) continue;
            if (!archive.isScript(f.entry)) continue;
            for (out.items) |k| {
                if (k == i) break;
            } else try out.append(a, i);
        }
        return out.items;
    }

    /// Whether file `entry` belongs to object `name`: named after it, or a weapon it
    /// owns (`Owner="name"`; a barrel's `_explode.wpn`).
    fn ownedBy(self: *Doc, f: usize, name: []const u8) bool {
        const e = self.store.files.items[f].entry;
        const stem = e[0 .. e.len - std.fs.path.extension(e).len];
        if (std.ascii.eqlIgnoreCase(stem, name)) return true;
        if (!std.ascii.endsWithIgnoreCase(e, ".wpn")) return false;
        var qb: [112]u8 = undefined;
        const q = std.fmt.bufPrint(&qb, "Owner=\"{s}\"", .{name}) catch return false;
        return std.ascii.findIgnoreCase(self.store.text(f), q) != null;
    }

    /// The script of the level, other than `name`'s own files, naming it (`"name"`,
    /// outside comments; in the level script `skip` — its placement — aside).
    fn namedIn(self: *Doc, name: []const u8, skip: ?placement.Span) !?usize {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var qb: [112]u8 = undefined;
        const q = try std.fmt.bufPrint(&qb, "\"{s}\"", .{name});
        for (try self.levelFiles(a)) |f| {
            if (self.ownedBy(f, name)) continue;
            var t = self.store.text(f);
            if (f == self.lev) if (skip) |sp| {
                t = try std.mem.concat(a, u8, &.{ t[0..sp.start], t[sp.end..] });
            };
            if (std.ascii.findIgnoreCase(try placement.uncommented(a, t), q) != null) return f;
        }
        return null;
    }

    /// Deletes object `name`'s files (one undo step).
    pub fn dropFiles(self: *Doc, name: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var own: std.ArrayList(usize) = .empty;
        for (try self.levelFiles(arena.allocator())) |f| if (self.ownedBy(f, name)) try own.append(arena.allocator(), f);
        if (own.items.len > 0) try self.store.delete(own.items);
    }

    /// Fighters, obstacles and props with files in the level that no script names
    /// (left by an older editor's removal): the exe would bring them into the battle.
    pub fn orphans(self: *Doc, a: Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        if (!self.isBattle()) return out.items;
        for (try self.levelFiles(a)) |f| {
            const e = self.store.files.items[f].entry;
            const ext = std.fs.path.extension(e);
            const kinds = [_][]const u8{ ".ftr", ".obs", ".obs_i", ".act" };
            for (kinds) |k| {
                if (!std.ascii.eqlIgnoreCase(ext, k)) continue;
                const stem = e[0 .. e.len - ext.len];
                if (try self.namedIn(stem, null) == null) try out.append(a, try a.dupe(u8, stem));
            }
        }
        return out.items;
    }

    pub fn edit(self: *Doc, edits: []placement.Edit) !void {
        const out = try placement.apply(self.gpa, self.text(), edits);
        errdefer self.gpa.free(out);
        const script = try placement.scan(self.gpa, out);
        try self.store.replace(self.lev, out);
        self.script.deinit(self.gpa);
        self.script = script;
        self.bind();
    }

    /// After undo restored the level script: re-reads positions from it; added
    /// objects whose call is gone are dropped.
    pub fn afterUndo(self: *Doc) !void {
        const script = try placement.scan(self.gpa, self.text());
        self.script.deinit(self.gpa);
        self.script = script;
        self.bind();
        try self.resync();
        var k = self.objects.items.len;
        while (k > 0) {
            k -= 1;
            const o = self.objects.items[k];
            if (o.added and o.call == null) _ = self.objects.orderedRemove(k);
        }
    }

    /// Object positions from the current calls (after undo; removed objects stay
    /// removed until the level is reloaded).
    fn resync(self: *Doc) !void {
        const cm = self.world.combat_map orelse return;
        for (self.objects.items) |*o| {
            const call = self.script.calls[o.call orelse continue];
            if (o.grid != null) {
                o.grid = .{ call.arg(self.text(), 0).?, call.arg(self.text(), 1).? };
                o.pos = self.gridPos(cm, o.grid.?);
            } else {
                const k: usize = if (call.func == .enemy_appear) 2 else 0;
                o.tile = .{ @intFromFloat(call.arg(self.text(), k).?), @intFromFloat(call.arg(self.text(), k + 1).?) };
                o.pos = self.tilePos(cm, o.tile.?, o.size);
            }
        }
    }

    // ------------------------------------------------------------ fighter files

    /// The class file a fighter/weapon script includes (`#include ft_x.ss` → classes\ft_x.ss).
    pub fn classOf(self: *Doc, i: usize, prefix: []const u8) !?usize {
        const t = self.store.text(i);
        const p = std.ascii.findIgnoreCase(t, prefix) orelse return null;
        const s = p + "#include ".len;
        var e = s;
        while (e < t.len and !std.ascii.isWhitespace(t[e])) e += 1;
        var buf: [128]u8 = undefined;
        const entry = try std.fmt.bufPrint(&buf, "classes\\{s}", .{t[s..e]});
        return self.store.file(common_archive, entry) catch |err| if (err == error.NotFound) null else err;
    }

    /// Files of battle enemy `name` (`<name>.ftr`, `.wpn` with `Owner="<name>"`).
    pub fn enemy(self: *Doc, name: []const u8) !Enemy {
        var buf: [128]u8 = undefined;
        const st = self.store;
        const ftr = try st.file(self.level_archive, try std.fmt.bufPrint(&buf, "{s}.ftr", .{name}));
        var en: Enemy = .{ .name = st.files.items[ftr].entry[0..name.len], .ftr = ftr, .class = try self.classOf(ftr, "#include ft_") };
        {
            var ar = try archive.Archive.open(st.io, self.gpa, st.dat, self.level_archive);
            defer ar.close(st.io, self.gpa);
            for (ar.entries) |e| {
                if (std.ascii.endsWithIgnoreCase(e.name, ".wpn")) _ = try st.file(self.level_archive, e.name);
            }
        }
        const owner = try std.fmt.bufPrint(&buf, "\"{s}\"", .{name});
        for (0..st.files.items.len) |i| {
            const f = st.files.items[i];
            if (!std.mem.eql(u8, f.archive, self.level_archive) or !std.ascii.endsWithIgnoreCase(f.entry, ".wpn")) continue;
            if (std.ascii.findIgnoreCase(f.text, owner) == null or en.n_wpn == en.wpn.len) continue;
            en.wpn[en.n_wpn] = i;
            en.wpn_class[en.n_wpn] = try self.classOf(i, "#include wp_");
            en.n_wpn += 1;
        }
        return en;
    }

    // Objects of a level added, removed, turned and moved (level.Doc): enemies, own heroes,
    // obstacles, props, boxes, party heroes, 3D model actors — each one Store edit.
    pub const addEnemy = @import("level_edit.zig").addEnemy;
    pub const placeNew = @import("level_edit.zig").placeNew;
    pub const addOwn = @import("level_edit.zig").addOwn;
    pub const addObstacle = @import("level_edit.zig").addObstacle;
    pub const addProp = @import("level_edit.zig").addProp;
    pub const facing = @import("level_edit.zig").facing;
    pub const rotate = @import("level_edit.zig").rotate;
    pub const canWalkIn = @import("level_edit.zig").canWalkIn;
    pub const toggleWalkIn = @import("level_edit.zig").toggleWalkIn;
    pub const boxFile = @import("level_edit.zig").boxFile;
    pub const addBox = @import("level_edit.zig").addBox;
    pub const addHero = @import("level_edit.zig").addHero;
    pub const heroFile = @import("level_edit.zig").heroFile;
    pub const removeHero = @import("level_edit.zig").removeHero;
    pub const deletableBox = @import("level_edit.zig").deletableBox;
    pub const deleteBox = @import("level_edit.zig").deleteBox;
    pub const deletableActor = @import("level_edit.zig").deletableActor;
    pub const restoreDeleted = @import("level_edit.zig").restoreDeleted;
    const moveItem = @import("level_edit.zig").moveItem;
    pub const actFile = @import("level_edit.zig").actFile;
    pub const actorMovable = @import("level_edit.zig").actorMovable;
    const moveActor = @import("level_edit.zig").moveActor;
    pub const addActor = @import("level_edit.zig").addActor;

    /// Background point `bg` is on walkable floor (either floor's map); no map — anywhere.
    pub fn walkableAt(self: *const Doc, bg: [2]f32) bool {
        const nav = og.world.nav;
        const cc = nav.cellOf(bg);
        for ([_]?lf.WalkMap{ self.world.walk_map, self.world.walk_map2 }) |mo| {
            const cell = nav.cellAt(mo orelse continue, cc) orelse continue;
            if (cell.walkable()) return true;
        }
        return self.world.walk_map == null;
    }

    /// Background point `bg` is on the level's main walkable floor (the hero gets there
    /// on foot; the exe shows an exit only if its control point can be reached, 0x427780).
    pub fn reachable(self: *Doc, bg: [2]f32) bool {
        const m = self.world.walk_map orelse return true;
        const main = self.mainArea() orelse return true;
        const cc = og.world.nav.cellOf(bg);
        if (cc[0] < 0 or cc[1] < 0 or cc[0] >= m.width or cc[1] >= m.height) return false;
        const i = @as(usize, @intCast(cc[1])) * m.width + @as(usize, @intCast(cc[0]));
        return main[i] and m.cells[i].kind & path_link == 0;
    }

    /// Walk grid bits of an `.ap` path's end cells (a ladder, the pontoon): a hero
    /// stepping there is taken along the path.
    const path_link: u8 = 0b110;

    /// Control point of area `name` (where a hero walks to use it), as edited.
    pub fn areaControl(self: *const Doc, name: []const u8) ?[2]f32 {
        for (self.own_areas orelse self.world.areas) |ar| if (std.ascii.eqlIgnoreCase(ar.name, name)) return ar.control;
        return null;
    }

    fn mainArea(self: *Doc) ?[]const bool {
        if (self.main_area == null) if (self.world.walk_map) |m| {
            const ps = og.world.route.levelPortals(self.world, self.gpa) catch return null;
            defer self.gpa.free(ps);
            self.main_area = og.world.nav.largestRegion(self.gpa, m, ps) catch null;
        };
        return self.main_area;
    }

    /// Centre of the walkable cell nearest background point `bg` (within ~200 pixels)
    /// on the main floor (a cell cut off from it — the pontoon's — is no place to walk to).
    pub fn nearestWalkable(self: *Doc, bg: [2]f32) ?[2]f32 {
        const nav = og.world.nav;
        const m = self.world.walk_map orelse return bg;
        const main = self.mainArea();
        const c0 = nav.cellOf(bg);
        var r: i32 = 0;
        while (r < 25) : (r += 1) {
            var best: ?[2]i32 = null;
            var best_d: i32 = std.math.maxInt(i32);
            var dy = -r;
            while (dy <= r) : (dy += 1) {
                var dx = -r;
                while (dx <= r) : (dx += 1) {
                    if (@max(@abs(dx), @abs(dy)) != r) continue;
                    const cc: [2]i32 = .{ c0[0] + dx, c0[1] + dy };
                    const cell = nav.cellAt(m, cc) orelse continue;
                    if (!cell.walkable() or cell.kind & path_link != 0) continue;
                    if (main) |ma| if (!ma[@as(usize, @intCast(cc[1])) * m.width + @as(usize, @intCast(cc[0]))]) continue;
                    const d = dx * dx + dy * dy;
                    if (d < best_d) {
                        best_d = d;
                        best = cc;
                    }
                }
            }
            if (best) |b| return nav.center(b);
        }
        return null;
    }

    /// Position file of location item `name` (`variables\\<name>.var`, as the game's).
    pub fn varFile(self: *Doc, name: []const u8) ?usize {
        var buf: [128]u8 = undefined;
        return self.store.file(common_archive, std.fmt.bufPrint(&buf, "variables\\{s}.var", .{name}) catch return null) catch null;
    }

    /// After undo restored file `f`: an item whose `.var` it is goes back to its place.
    pub fn refreshPos(self: *Doc, f: usize) void {
        for (self.objects.items) |*o| {
            if (o.kind != .item) continue;
            var buf: [128]u8 = undefined;
            const entry = std.fmt.bufPrint(&buf, "variables\\{s}.var", .{o.name}) catch continue;
            if (self.store.find(common_archive, entry) != f) continue;
            const t = self.store.text(f);
            const q = self.world.cam.project(.{ varValue(t, "x") orelse continue, varValue(t, "y") orelse continue, varValue(t, "z") orelse continue });
            o.pos = .{ q.x, q.y };
        }
    }

    /// After undo took file `f` away: its box goes from the list.
    pub fn dropGone(self: *Doc, f: usize) void {
        if (!self.store.gone(f)) return;
        var k = self.objects.items.len;
        while (k > 0) {
            k -= 1;
            if (self.objects.items[k].file == f) _ = self.objects.orderedRemove(k);
        }
    }

    pub fn nameTaken(self: *Doc, name: []const u8) bool {
        if (self.world.rt.findObject(name) != null) return true;
        for (self.store.files.items) |f| if (f.owner) |o| if (std.ascii.eqlIgnoreCase(o, name)) return true;
        return false;
    }

    // ------------------------------------------------------------ view

    pub fn toScreen(self: *const Doc, rect: c.SDL_FRect, p: [2]f32) [2]f32 {
        return .{ rect.x + (p[0] - self.origin[0]) * self.zoom, rect.y + (p[1] - self.origin[1]) * self.zoom };
    }

    pub fn toBackground(self: *const Doc, rect: c.SDL_FRect, s: [2]f32) [2]f32 {
        return .{ (s[0] - rect.x) / self.zoom + self.origin[0], (s[1] - rect.y) / self.zoom + self.origin[1] };
    }

    /// Whole background in the viewport, centred.
    pub fn fit(self: *Doc, rect: c.SDL_FRect) void {
        self.zoom = @min(rect.w / self.bg_size[0], rect.h / self.bg_size[1]);
        self.origin = .{ (self.bg_size[0] - rect.w / self.zoom) / 2, (self.bg_size[1] - rect.h / self.zoom) / 2 };
        self.fitted = true;
    }

    /// Zoom by `k` keeping screen point `s` fixed.
    pub fn zoomAt(self: *Doc, rect: c.SDL_FRect, s: [2]f32, k: f32) void {
        const p = self.toBackground(rect, s);
        self.zoom = std.math.clamp(self.zoom * k, 0.1, 8);
        self.origin = .{ p[0] - (s[0] - rect.x) / self.zoom, p[1] - (s[1] - rect.y) / self.zoom };
    }

    /// Object under screen point `s` (its marker, else the smallest area there); hidden
    /// ones left out.
    pub fn pick(self: *const Doc, rect: c.SDL_FRect, s: [2]f32) ?usize {
        return self.pickMarker(rect, s) orelse self.pickArea(rect, s);
    }

    /// Object within 10 points of its marker, nearest first.
    pub fn pickMarker(self: *const Doc, rect: c.SDL_FRect, s: [2]f32) ?usize {
        var best: ?usize = null;
        var best_d: f32 = 10 * 10;
        for (self.objects.items, 0..) |o, i| {
            if (self.hiddenInView(o)) continue;
            const q = self.toScreen(rect, o.pos);
            const d = (q[0] - s[0]) * (q[0] - s[0]) + (q[1] - s[1]) * (q[1] - s[1]);
            if (d < best_d) {
                best_d = d;
                best = i;
            }
        }
        return best;
    }

    /// The smallest area holding screen point `s`.
    fn pickArea(self: *const Doc, rect: c.SDL_FRect, s: [2]f32) ?usize {
        var best: ?usize = null;
        const b = self.toBackground(rect, s);
        var best_size: f32 = std.math.inf(f32);
        for (self.objects.items, 0..) |o, i| {
            if (self.hiddenInView(o)) continue;
            const poly = o.poly orelse continue;
            if (!inside(poly, b)) continue;
            var lo: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
            var hi: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };
            for (poly) |p| {
                lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
                hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
            }
            const size = (hi[0] - lo[0]) * (hi[1] - lo[1]);
            if (size < best_size) {
                best_size = size;
                best = i;
            }
        }
        return best;
    }

    // The level map drawn (level.Doc.draw): background, walkable cells, objects with their
    // icons and facing, areas, a battle's grid with its numbers.
    const polyArea = @import("level_draw.zig").polyArea;
    const fillPoly = @import("level_draw.zig").fillPoly;
    const inTri = @import("level_draw.zig").inTri;
    pub const hiddenInView = @import("level_draw.zig").hiddenInView;
    pub const kindColor = @import("level_draw.zig").kindColor;
    pub const draw = @import("level_draw.zig").draw;
    pub const drawWalk = @import("level_draw.zig").drawWalk;
    pub const turnHandles = @import("level_draw.zig").turnHandles;
    pub const icon = @import("level_draw.zig").icon;
    pub const drawTurn = @import("level_draw.zig").drawTurn;
    pub const drawFacing = @import("level_draw.zig").drawFacing;
    pub const drawEntry = @import("level_draw.zig").drawEntry;
    pub const corner = @import("level_draw.zig").corner;
    pub const quad = @import("level_draw.zig").quad;
    pub const fillTiles = @import("level_draw.zig").fillTiles;
    pub const drawGridOnly = @import("level_draw.zig").drawGridOnly;
    pub const drawGrid = @import("level_draw.zig").drawGrid;
    pub const gridNumber = @import("level_draw.zig").gridNumber;

    fn inside(poly: []const [3]f32, p: [2]f32) bool {
        var in = false;
        var j = poly.len - 1;
        for (poly, 0..) |a, i| {
            const b = poly[j];
            if ((a[1] > p[1]) != (b[1] > p[1]) and p[0] < (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0]) in = !in;
            j = i;
        }
        return in;
    }
};

/// `key=value` of a `.var` file.
pub fn varValue(text: []const u8, key: []const u8) ?f32 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \r");
        if (l.len > key.len and std.mem.startsWith(u8, l, key) and l[key.len] == '=') return std.fmt.parseFloat(f32, l[key.len + 1 ..]) catch null;
    }
    return null;
}

/// `.var` text with `key=value` replaced (or added at the end).
pub fn setVarLine(gpa: Allocator, text: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var found = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |raw| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (!found and l.len > key.len and std.mem.startsWith(u8, l, key) and l[key.len] == '=') {
            try out.print(gpa, "{s}={s}", .{ key, value });
            if (raw.len > l.len) try out.append(gpa, '\r');
            found = true;
        } else try out.appendSlice(gpa, raw);
    }
    if (!found) try out.print(gpa, "{s}={s}\r\n", .{ key, value });
    return out.toOwnedSlice(gpa);
}

/// `fmt` with `args`, lines ending in CRLF as the game's files.
pub fn crlf(gpa: Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    const t = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(t);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (t) |ch| {
        if (ch == '\n') try out.append(gpa, '\r');
        try out.append(gpa, ch);
    }
    return out.toOwnedSlice(gpa);
}

/// Decorative props (`obs_a_<tag>.s` of common/other.dat classes).
pub const Prop = enum { automat, barrier, bathtub, corpse, fcrate, logs, pipe };

/// Obstacles a battle gets from the editor (the games's classes); the tag is in the name.
pub const Obstacle = enum { wcrate, mcrate, barrel, box };

pub const LevelEntry = @import("level_templates.zig").LevelEntry;
pub const listLevels = @import("level_templates.zig").listLevels;
pub const listTemplates = @import("level_templates.zig").listTemplates;
pub const freeTemplates = @import("level_templates.zig").freeTemplates;

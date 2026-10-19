//! Save files. Our own text format (no original saves to copy), one block per object.
//! Every visited location is stored: all script objects with vars, flags and actor
//! state. Loading recreates the location (init/restore), then applies the saved state;
//! objects created during play (Weapon_New, Item_New) are recreated from their class
//! file, deleted ones are deleted.
//!
//! ```
//! OGSAVE 1
//! current 01_port
//! hero Sullivan
//! name <save name>
//! imm <monster id> <mask>
//! world 01_port
//! obj <name> <class> <kind> <flags> <floor> <state> <points>
//! var <name> i:<int> | f:<float> | s:<escaped string>
//! skill <id> <level> <count>
//! anim <reverse> <animation>
//! walk <allow> <floor> <area>
//! end
//! ```

const std = @import("std");
const state_object = @import("state.zig").object;
const state_groups = @import("state.zig").groups;
const snapshot = @import("world.zig").snapshot;
const Allocator = std.mem.Allocator;
const world_mod = @import("state.zig").world;
const World = world_mod.World;
const object = @import("script.zig").object;
const Value = @import("script.zig").value.Value;
const immunity = @import("battle.zig").immunity;

const VarCopy = snapshot.VarCopy;

const ObjState = struct {
    name: []const u8,
    class_file: []const u8,
    kind: state_object.Kind,
    enabled: bool,
    deleted: bool,
    placed: bool,
    hero: bool,
    map: u1,
    state: u8,
    stat_points: i32,
    /// Item model animation (Item_Animation: an opened box) and its direction.
    anim: []const u8 = "",
    anim_reverse: bool = false,
    vars: []VarCopy,
    skills: []state_object.Skill,
};

pub const WorldState = struct {
    level: []const u8,
    objects: []ObjState,
    /// Forbid/AllowWalkInArea areas (0x411fa3), replayed on load.
    walk: []state_groups.WalkArea = &.{},
};

pub const Save = struct {
    arena: std.heap.ArenaAllocator,
    current: []const u8 = "",
    hero: []const u8 = "Sullivan",
    /// Save name typed on the save screen (up to 15 chars, case as typed).
    name: []const u8 = "",
    worlds: std.ArrayList(WorldState) = .empty,
    /// Discovered immunities (`imm`), written from the game and applied on load (game.Game)
    /// only after a successful parse.
    imm: [immunity.table.len]u16 = @splat(0),

    pub fn init(gpa: Allocator) Save {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Save) void {
        self.arena.deinit();
    }

    pub fn find(self: *Save, level: []const u8) ?*WorldState {
        for (self.worlds.items) |*ws| if (std.ascii.eqlIgnoreCase(ws.level, level)) return ws;
        return null;
    }

    /// Capture a world's state (appended to the save).
    pub fn addWorld(self: *Save, w: *World) !void {
        const a = self.arena.allocator();
        var objs: std.ArrayList(ObjState) = .empty;
        for (w.rt.objects.items) |o| {
            const n = World.nativeOf(o);
            if (n.kind == .ambient) continue; // scripts repeat Ambient_New
            const vars = try snapshot.copyVars(a, o, &.{});
            try objs.append(a, .{
                .name = try a.dupe(u8, o.name),
                .class_file = try a.dupe(u8, o.class.name),
                .kind = n.kind,
                .enabled = o.enabled,
                .deleted = n.deleted,
                .placed = n.actor.placed,
                .hero = n.hero,
                .map = n.actor.map,
                .state = n.actor.state,
                .stat_points = n.growth.stat_points,
                .anim = if (n.kind == .item or n.kind == .weapon) try a.dupe(u8, n.actor.anim) else "",
                .anim_reverse = n.actor.reverse,
                .vars = vars,
                .skills = try a.dupe(state_object.Skill, n.growth.skills.items),
            });
        }
        const walk = try a.alloc(state_groups.WalkArea, w.walk_areas.items.len);
        for (w.walk_areas.items, walk) |src, *dst| dst.* = .{ .name = try a.dupe(u8, src.name), .allow = src.allow, .floor = src.floor };
        try self.worlds.append(a, .{ .level = try a.dupe(u8, w.level_name), .objects = objs.items, .walk = walk });
    }

    /// Copy another location's state from another save.
    pub fn addState(self: *Save, ws: WorldState) !void {
        const a = self.arena.allocator();
        const objs = try a.alloc(ObjState, ws.objects.len);
        for (ws.objects, objs) |src, *dst| {
            dst.* = src;
            dst.name = try a.dupe(u8, src.name);
            dst.class_file = try a.dupe(u8, src.class_file);
            dst.anim = try a.dupe(u8, src.anim);
            dst.vars = try a.alloc(VarCopy, src.vars.len);
            for (src.vars, dst.vars) |v, *d| d.* = .{ .name = try a.dupe(u8, v.name), .value = try v.value.dupe(a) };
            dst.skills = try a.dupe(state_object.Skill, src.skills);
        }
        const walk = try a.alloc(state_groups.WalkArea, ws.walk.len);
        for (ws.walk, walk) |src, *dst| dst.* = .{ .name = try a.dupe(u8, src.name), .allow = src.allow, .floor = src.floor };
        try self.worlds.append(a, .{ .level = try a.dupe(u8, ws.level), .objects = objs, .walk = walk });
    }

    pub fn write(self: *const Save, out: *std.Io.Writer) !void {
        try out.print("OGSAVE 1\ncurrent {s}\nhero {s}\nname {s}\n", .{ self.current, self.hero, self.name });
        // Discovered monster resistances (the exe saves table 0x6d2070).
        for (immunity.table, self.imm) |e, k| if (k != 0) try out.print("imm {d} {d}\n", .{ e.id, k });
        for (self.worlds.items) |ws| {
            try out.print("world {s}\n", .{ws.level});
            for (ws.objects) |o| {
                const flags: u8 = @as(u8, @intFromBool(o.enabled)) | @as(u8, @intFromBool(o.deleted)) << 1 | @as(u8, @intFromBool(o.placed)) << 2 | @as(u8, @intFromBool(o.hero)) << 3;
                try out.print("obj {s} {s} {t} {d} {d} {d} {d}\n", .{ o.name, o.class_file, o.kind, flags, o.map, o.state, o.stat_points });
                for (o.vars) |v| {
                    try out.print("var {s} ", .{v.name});
                    switch (v.value) {
                        .int => |i| try out.print("i:{d}\n", .{i}),
                        .float => |f| try out.print("f:{d}\n", .{f}),
                        .string => |s| {
                            try out.writeAll("s:");
                            try escape(out, s);
                            try out.writeByte('\n');
                        },
                    }
                }
                for (o.skills) |sk| try out.print("skill {d} {d} {d}\n", .{ sk.id, sk.level, sk.count });
                if (o.anim.len > 0) try out.print("anim {d} {s}\n", .{ @intFromBool(o.anim_reverse), o.anim });
            }
            for (ws.walk) |wa| try out.print("walk {d} {d} {s}\n", .{ @intFromBool(wa.allow), wa.floor, wa.name });
            try out.writeAll("end\n");
        }
    }

    pub fn parse(gpa: Allocator, text: []const u8) !Save {
        var s: Save = .init(gpa);
        errdefer s.deinit();
        const a = s.arena.allocator();
        var lines = std.mem.splitScalar(u8, text, '\n');
        const head = lines.next() orelse return error.BadSave;
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, head, "\r"), "OGSAVE 1")) return error.BadSave;
        var objs: std.ArrayList(ObjState) = .empty;
        var vars: std.ArrayList(VarCopy) = .empty;
        var skills: std.ArrayList(state_object.Skill) = .empty;
        var walk: std.ArrayList(state_groups.WalkArea) = .empty;
        var level: ?[]const u8 = null;
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
            const key = line[0..sp];
            const rest = if (sp < line.len) line[sp + 1 ..] else "";
            if (std.mem.eql(u8, key, "current")) {
                s.current = try a.dupe(u8, rest);
            } else if (std.mem.eql(u8, key, "imm")) {
                var it = std.mem.tokenizeScalar(u8, rest, ' ');
                const id = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
                const mask = std.fmt.parseInt(u16, it.next() orelse "0", 10) catch 0;
                for (immunity.table, &s.imm) |e, *k| if (e.id == id) {
                    k.* = mask;
                };
            } else if (std.mem.eql(u8, key, "hero")) {
                s.hero = try a.dupe(u8, rest);
            } else if (std.mem.eql(u8, key, "name")) {
                s.name = try a.dupe(u8, rest);
            } else if (std.mem.eql(u8, key, "world")) {
                if (level != null) return error.BadSave; // previous section lacks "end"
                level = try a.dupe(u8, rest);
                objs = .empty;
                walk = .empty;
            } else if (std.mem.eql(u8, key, "walk")) {
                var it = std.mem.tokenizeScalar(u8, rest, ' ');
                const allow = (std.fmt.parseInt(u8, it.next() orelse "0", 10) catch 0) != 0;
                const floor = std.fmt.parseInt(i32, it.next() orelse "0", 10) catch 0;
                try walk.append(a, .{ .name = try a.dupe(u8, it.rest()), .allow = allow, .floor = floor });
            } else if (std.mem.eql(u8, key, "obj")) {
                try finishObj(a, &objs, &vars, &skills);
                var it = std.mem.tokenizeScalar(u8, rest, ' ');
                const name = it.next() orelse return error.BadSave;
                const cls = it.next() orelse return error.BadSave;
                const kind = std.meta.stringToEnum(state_object.Kind, it.next() orelse "") orelse .other;
                const flags = try std.fmt.parseInt(u8, it.next() orelse "0", 10);
                const map = try std.fmt.parseInt(u8, it.next() orelse "0", 10);
                const state = try std.fmt.parseInt(u8, it.next() orelse "0", 10);
                // State indexes the actor's idle tables (apply → pickIdle).
                if (state >= @import("actor.zig").max_states) return error.BadSave;
                try objs.append(a, .{
                    .name = try a.dupe(u8, name),
                    .class_file = try a.dupe(u8, cls),
                    .kind = kind,
                    .enabled = flags & 1 != 0,
                    .deleted = flags & 2 != 0,
                    .placed = flags & 4 != 0,
                    .hero = flags & 8 != 0,
                    .map = @intCast(map & 1),
                    .state = state,
                    .stat_points = try std.fmt.parseInt(i32, it.next() orelse "0", 10),
                    .vars = &.{},
                    .skills = &.{},
                });
            } else if (std.mem.eql(u8, key, "var")) {
                const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
                const name = rest[0..sp2];
                const v = rest[sp2 + 1 ..];
                if (v.len < 2) continue;
                const value: Value = switch (v[0]) {
                    'i' => .{ .int = try std.fmt.parseInt(i32, v[2..], 10) },
                    'f' => .{ .float = try std.fmt.parseFloat(f32, v[2..]) },
                    else => .{ .string = try unescape(a, v[2..]) },
                };
                try vars.append(a, .{ .name = try a.dupe(u8, name), .value = value });
            } else if (std.mem.eql(u8, key, "anim")) {
                if (objs.items.len == 0) continue;
                const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
                const last = &objs.items[objs.items.len - 1];
                last.anim_reverse = !std.mem.eql(u8, rest[0..sp2], "0");
                last.anim = try a.dupe(u8, rest[sp2 + 1 ..]);
            } else if (std.mem.eql(u8, key, "skill")) {
                var it = std.mem.tokenizeScalar(u8, rest, ' ');
                try skills.append(a, .{
                    .id = try std.fmt.parseInt(i32, it.next() orelse "0", 10),
                    .level = try std.fmt.parseInt(i32, it.next() orelse "0", 10),
                    .count = try std.fmt.parseInt(i32, it.next() orelse "0", 10),
                });
            } else if (std.mem.eql(u8, key, "end")) {
                try finishObj(a, &objs, &vars, &skills);
                try s.worlds.append(a, .{ .level = level orelse return error.BadSave, .objects = objs.items, .walk = walk.items });
                level = null;
            }
        }
        // Truncated file: an unclosed section or no section for the current location.
        if (level != null or s.find(s.current) == null) return error.BadSave;
        try s.recoverPartyItems();
        return s;
    }

    /// Hero items lost from the current location in old saves (a class from another
    /// location's archive failed to load). Exe items are global, so a hero's item found in
    /// another location's section moves to the current one if it is missing there and no
    /// section says it was used up or isn't the hero's.
    fn recoverPartyItems(self: *Save) !void {
        const cur = self.find(self.current) orelse return;
        const a = self.arena.allocator();
        var add: std.ArrayList(ObjState) = .empty;
        for (self.worlds.items) |*ws| {
            if (ws == cur) continue;
            for (ws.objects) |e| {
                if (e.kind != .item and e.kind != .weapon) continue;
                if (findObj(cur.objects, e.name) != null or findObj(add.items, e.name) != null) continue;
                if (!heldByHero(cur, e)) continue;
                const agreed = for (self.worlds.items) |*other| {
                    const o = findObj(other.objects, e.name) orelse continue;
                    if (o.deleted or !heldByHero(cur, o.*)) break false;
                } else true;
                if (agreed) try add.append(a, e);
            }
        }
        if (add.items.len == 0) return;
        try add.insertSlice(a, 0, cur.objects);
        cur.objects = add.items;
    }
};

fn findObj(objs: []ObjState, name: []const u8) ?*ObjState {
    for (objs) |*o| if (std.ascii.eqlIgnoreCase(o.name, name)) return o;
    return null;
}

fn varOf(e: ObjState, name: []const u8) ?Value {
    for (e.vars) |v| if (std.ascii.eqlIgnoreCase(v.name, name)) return v.value;
    return null;
}

/// Item in the backpack, hand or worn by a party hero of the current location.
fn heldByHero(cur: *const WorldState, e: ObjState) bool {
    if (e.deleted) return false;
    const owner = varOf(e, "Owner") orelse return false;
    const place = varOf(e, "place") orelse return false;
    if (owner != .string or owner.string.len == 0) return false;
    const p: i64 = switch (place) {
        .int => |i| i,
        .float => |f| @import("script.zig").value.floatToInt(f),
        else => return false,
    };
    if (p <= 0) return false;
    const h = findObj(cur.objects, owner.string) orelse return false;
    return h.hero;
}

fn finishObj(a: Allocator, objs: *std.ArrayList(ObjState), vars: *std.ArrayList(VarCopy), skills: *std.ArrayList(state_object.Skill)) !void {
    if (objs.items.len == 0) {
        vars.* = .empty;
        skills.* = .empty;
        return;
    }
    const last = &objs.items[objs.items.len - 1];
    if (last.vars.len == 0 and vars.items.len > 0) last.vars = try a.dupe(VarCopy, vars.items);
    if (last.skills.len == 0 and skills.items.len > 0) last.skills = try a.dupe(state_object.Skill, skills.items);
    vars.clearRetainingCapacity();
    skills.clearRetainingCapacity();
}

fn escape(out: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        else => try out.writeByte(ch),
    };
}

fn unescape(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            try out.append(a, switch (s[i]) {
                'n' => '\n',
                'r' => '\r',
                else => s[i],
            });
        } else try out.append(a, s[i]);
    }
    return out.items;
}

test "save round trip" {
    const gpa = std.testing.allocator;
    var s: Save = .init(gpa);
    defer s.deinit();
    s.current = "01_port";
    const a = s.arena.allocator();
    const vars = try a.dupe(VarCopy, &.{
        .{ .name = "hp", .value = .{ .int = 42 } },
        .{ .name = "accuracy", .value = .{ .float = 90.5 } },
        .{ .name = "owner", .value = .{ .string = "Sul livan\\x\n" } },
    });
    const objs = try a.dupe(ObjState, &.{.{ .name = "sullivan", .class_file = "sullivan.hro", .kind = .actor, .enabled = true, .deleted = false, .placed = true, .hero = true, .map = 1, .state = 0, .stat_points = 5, .vars = vars, .skills = try a.dupe(state_object.Skill, &.{.{ .id = 49, .level = 3 }}) }});
    try s.worlds.append(a, .{ .level = "01_port", .objects = objs });
    var buf: std.Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try s.write(&buf.writer);
    var back = try Save.parse(gpa, buf.written());
    defer back.deinit();
    try std.testing.expectEqualStrings("01_port", back.current);
    const o = back.worlds.items[0].objects[0];
    try std.testing.expectEqual(1, o.map);
    try std.testing.expectEqual(5, o.stat_points);
    try std.testing.expectEqual(42, o.vars[0].value.int);
    try std.testing.expectEqualStrings("Sul livan\\x\n", o.vars[2].value.string);
    try std.testing.expectEqual(49, o.skills[0].id);
}

test "recover party items from other levels" {
    // Gloves only in the worker room's section (lost from 01_port), the knife used up on
    // 01_port, the key on the ground: only the gloves move.
    const text =
        \\OGSAVE 1
        \\current 01_port
        \\world 01_port
        \\obj sullivan sullivan.hro actor 13 0 0 0
        \\obj knife knife.itm item 2 0 0 0
        \\var owner s:sullivan
        \\var place i:1
        \\end
        \\world 01_port_worker
        \\obj sullivan sullivan.hro actor 13 0 0 0
        \\obj gloves gloves.itm item 1 0 0 0
        \\var owner s:sullivan
        \\var place i:1
        \\obj knife knife.itm item 1 0 0 0
        \\var owner s:sullivan
        \\var place i:1
        \\obj key key.itm item 1 0 0 0
        \\var owner s:
        \\var place i:0
        \\end
        \\
    ;
    var s = try Save.parse(std.testing.allocator, text);
    defer s.deinit();
    const cur = s.find("01_port").?;
    try std.testing.expect(findObj(cur.objects, "gloves") != null);
    try std.testing.expect(findObj(cur.objects, "key") == null);
    try std.testing.expect(findObj(cur.objects, "knife").?.deleted);
}

test "truncated save is rejected" {
    const id = immunity.table[0].id;
    var hb: [64]u8 = undefined;
    const head = try std.fmt.bufPrint(&hb, "OGSAVE 1\ncurrent 01_port\nimm {d} 3\n", .{id});
    const ok = "world 01_port\nobj sullivan sullivan.hro actor 13 0 0 0\nend\n";
    var tb: [512]u8 = undefined;
    // Cut mid-section, a section without "end" before the next, no current location.
    for ([_][]const u8{ "world 01_port\nobj sullivan sullivan.hro actor 13 0 0 0\n", "world 01_port\nworld 01_port_worker\nend\n", "world 01_port_worker\nend\n" }) |tail| {
        const t = try std.fmt.bufPrint(&tb, "{s}{s}", .{ head, tail });
        try std.testing.expectError(error.BadSave, Save.parse(std.testing.allocator, t));
    }
    // Actor state outside the idle tables.
    try std.testing.expectError(error.BadSave, Save.parse(std.testing.allocator, try std.fmt.bufPrint(&tb, "{s}world 01_port\nobj sullivan sullivan.hro actor 13 0 12 0\nend\n", .{head})));
    var s = try Save.parse(std.testing.allocator, try std.fmt.bufPrint(&tb, "{s}{s}", .{ head, ok }));
    defer s.deinit();
    try std.testing.expectEqual(3, s.imm[0]);
}

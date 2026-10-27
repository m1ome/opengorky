//! Box contents in a box script (`.itm` including ci_box.s, or a battle `.obs_i`):
//! slots `itm_N = "name1,name2";` (+ `cnt_itm`) in init(), and the objects they name
//! created by `Weapon_New("name","cw_x.s")` / `Item_New("name","ca_x.s"[,count])` in
//! post_init_box() (post_init() for battle boxes). The engine finds contents by the
//! slot names, so `write` rebuilds both places from one list.

const std = @import("std");
const Allocator = std.mem.Allocator;
const placement = @import("placement.zig");
const vars = @import("vars.zig");

pub const Item = struct {
    /// Class file, `cw_crowbar.s`.
    class: []const u8,
    /// Object names, one per unit (all listed in one slot).
    names: std.ArrayList([]const u8) = .empty,
    /// Item_New's count (ammo); null — the class default.
    count: ?i32 = null,

    pub fn weapon(self: Item) bool {
        return std.ascii.startsWithIgnoreCase(self.class, "cw_");
    }
};

/// The script creating the contents: post_init_box() of an exploration box, else post_init().
fn creator(text: []const u8) []const u8 {
    return if (std.mem.indexOf(u8, text, "function post_init_box") != null) "post_init_box" else "post_init";
}

pub fn isBox(text: []const u8) bool {
    return std.ascii.findIgnoreCase(text, "ci_box.s") != null or vars.find(text, "itm_1") != null;
}

/// Contents by slot; names missing from the creator are dropped (they make nothing).
pub fn parse(a: Allocator, text: []const u8) ![]Item {
    var calls: std.ArrayList(struct { name: []const u8, class: []const u8, count: ?i32 }) = .empty;
    const body = funcBody(text, creator(text)) orelse return &.{};
    var lines = std.mem.splitScalar(u8, text[body.start..body.end], '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (!(std.mem.startsWith(u8, t, "Weapon_New(") or std.mem.startsWith(u8, t, "Item_New("))) continue;
        var it = std.mem.tokenizeAny(u8, t[std.mem.indexOfScalar(u8, t, '(').? + 1 ..], ",); \t");
        const name = std.mem.trim(u8, it.next() orelse continue, "\"");
        const class = std.mem.trim(u8, it.next() orelse continue, "\"");
        const third = it.next();
        const count = if (third) |x| std.fmt.parseInt(i32, x, 10) catch null else null;
        try calls.append(a, .{ .name = name, .class = class, .count = count });
    }
    var items: std.ArrayList(Item) = .empty;
    var n: usize = 1;
    while (n <= 13) : (n += 1) {
        var key: [8]u8 = undefined;
        const slot = vars.getStr(text, std.fmt.bufPrint(&key, "itm_{d}", .{n}) catch unreachable) orelse continue;
        var item: ?Item = null;
        var names = std.mem.tokenizeScalar(u8, slot, ',');
        while (names.next()) |raw| {
            const name = std.mem.trim(u8, raw, " ");
            const call = for (calls.items) |cl| {
                if (std.ascii.eqlIgnoreCase(cl.name, name)) break cl;
            } else continue;
            if (item == null) item = .{ .class = call.class, .count = call.count };
            // A name twice in a slot makes one object (seen in 01pr_box2).
            for (item.?.names.items) |x| {
                if (std.ascii.eqlIgnoreCase(x, name)) break;
            } else try item.?.names.append(a, name);
        }
        if (item) |i| try items.append(a, i);
    }
    return items.items;
}

const Span = placement.Span;

/// From the `{` after `function <name>` to its matching `}`.
pub fn funcBody(text: []const u8, name: []const u8) ?Span {
    var buf: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&buf, "function {s}(", .{name}) catch return null;
    const p = std.mem.indexOf(u8, text, head) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, text, p, '{') orelse return null;
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) switch (text[i]) {
        '{' => depth += 1,
        '}' => {
            depth -= 1;
            if (depth == 0) return .{ .start = open + 1, .end = i };
        },
        '"' => i = std.mem.indexOfScalarPos(u8, text, i + 1, '"') orelse return null,
        else => {},
    };
    return null;
}

fn lineEnd(text: []const u8, i: usize) usize {
    return if (std.mem.indexOfScalarPos(u8, text, i, '\n')) |e| e + 1 else text.len;
}

fn isSlotLine(t: []const u8) bool {
    if (std.mem.startsWith(u8, t, "cnt_itm")) return true;
    if (!std.mem.startsWith(u8, t, "itm_")) return false;
    var k: usize = 4;
    while (k < t.len and std.ascii.isDigit(t[k])) k += 1;
    while (k < t.len and (t[k] == ' ' or t[k] == '\t')) k += 1;
    return k > 4 and k < t.len and t[k] == '=';
}

/// `text` with contents `items`: slot lines (at the first old one, else first in
/// init()) and creator calls (first in its body) rebuilt; every other line kept.
pub fn write(gpa: Allocator, text: []const u8, items: []const Item) ![]u8 {
    const nl = placement.newline(text);
    const body = funcBody(text, creator(text)) orelse return error.NoCreator;
    const init_body = funcBody(text, "init") orelse return error.NoInit;
    const calls_at = lineEnd(text, body.start - 1);
    const has_slots = blk: {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |l| if (isSlotLine(std.mem.trim(u8, l, " \t\r"))) break :blk true;
        break :blk false;
    };
    const slots_at = if (has_slots) null else lineEnd(text, init_body.start - 1);

    var slots: std.ArrayList(u8) = .empty;
    defer slots.deinit(gpa);
    var calls: std.ArrayList(u8) = .empty;
    defer calls.deinit(gpa);
    var used: usize = 0;
    for (items) |item| {
        if (item.names.items.len == 0) continue;
        used += 1;
        try slots.print(gpa, "  itm_{d} = \"", .{used});
        for (item.names.items, 0..) |name, k| {
            if (k > 0) try slots.append(gpa, ',');
            try slots.appendSlice(gpa, name);
            const f = if (item.weapon()) "Weapon_New" else "Item_New";
            if (item.count) |c| {
                try calls.print(gpa, "  {s}(\"{s}\",\"{s}\",{d});{s}", .{ f, name, item.class, c, nl });
            } else try calls.print(gpa, "  {s}(\"{s}\",\"{s}\");{s}", .{ f, name, item.class, nl });
        }
        try slots.print(gpa, "\";{s}", .{nl});
    }
    try slots.print(gpa, "  cnt_itm={d};{s}", .{ used, nl });

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var slots_done = false;
    var i: usize = 0;
    while (i < text.len) {
        const e = lineEnd(text, i);
        const t = std.mem.trim(u8, text[i..e], " \t\r\n");
        const in_body = i >= body.start and i < body.end;
        if (slots_at == i and !slots_done) {
            try out.appendSlice(gpa, slots.items);
            slots_done = true;
        }
        if (i == calls_at) try out.appendSlice(gpa, calls.items);
        if (isSlotLine(t)) {
            if (!slots_done) try out.appendSlice(gpa, slots.items);
            slots_done = true;
        } else if (!(in_body and (std.mem.startsWith(u8, t, "Weapon_New(") or std.mem.startsWith(u8, t, "Item_New(")))) {
            try out.appendSlice(gpa, text[i..e]);
        }
        i = e;
    }
    var result = try out.toOwnedSlice(gpa);
    // Slots past those the script declares, after its last `string itm_N;`.
    for (1..used + 1) |n| {
        var d: [24]u8 = undefined;
        const decl = std.fmt.bufPrint(&d, "string itm_{d};", .{n}) catch unreachable;
        if (std.mem.indexOf(u8, result, decl) != null) continue;
        const last = std.mem.lastIndexOf(u8, result, "string itm_") orelse {
            if (try vars.declare(gpa, result, decl)) |next| {
                gpa.free(result);
                result = next;
            }
            continue;
        };
        const at = lineEnd(result, last);
        const next = try std.mem.concat(gpa, u8, &.{ result[0..at], decl, nl, result[at..] });
        gpa.free(result);
        result = next;
    }
    return result;
}

/// A starting inventory: the `Item_New`/`Weapon_New(name, class, "<owner>"[, count])`
/// calls of a hero script, by class in their order.
pub fn parseOwned(a: Allocator, text: []const u8, owner: []const u8) ![]Item {
    var items: std.ArrayList(Item) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const call = ownedCall(raw, owner) orelse continue;
        const it = for (items.items) |*x| {
            if (std.ascii.eqlIgnoreCase(x.class, call.class)) break x;
        } else blk: {
            try items.append(a, .{ .class = call.class, .count = call.count });
            break :blk &items.items[items.items.len - 1];
        };
        try it.names.append(a, call.name);
    }
    return items.items;
}

const OwnedCall = struct { name: []const u8, class: []const u8, count: ?i32 };

/// `Item_New("n","c","Owner"[,N]);` on its own line, for `owner`.
fn ownedCall(raw: []const u8, owner: []const u8) ?OwnedCall {
    const t = std.mem.trim(u8, raw, " \t\r");
    if (!(std.mem.startsWith(u8, t, "Weapon_New(") or std.mem.startsWith(u8, t, "Item_New("))) return null;
    var it = std.mem.tokenizeAny(u8, t[std.mem.indexOfScalar(u8, t, '(').? + 1 ..], ",); \t");
    const name = std.mem.trim(u8, it.next() orelse return null, "\"");
    const class = std.mem.trim(u8, it.next() orelse return null, "\"");
    const who = std.mem.trim(u8, it.next() orelse return null, "\"");
    if (!std.ascii.eqlIgnoreCase(who, owner)) return null;
    const count = if (it.next()) |x| std.fmt.parseInt(i32, x, 10) catch null else null;
    return .{ .name = name, .class = class, .count = count };
}

/// The item whose names include `name`.
fn holder(items: []const Item, name: []const u8) ?Item {
    for (items) |it| for (it.names.items) |n| if (std.ascii.eqlIgnoreCase(n, name)) return it;
    return null;
}

/// `text` with the starting inventory of `owner` changed to `items` in place: lines of
/// names gone are removed, a count changes only its number, new names go after the
/// last line of their class (else after the owner's last call, else first in
/// post_init()); every other line stays as it is.
pub fn writeOwned(gpa: Allocator, text: []const u8, items: []const Item, owner: []const u8) ![]u8 {
    const nl = placement.newline(text);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const old = try parseOwned(a, text, owner);
    var edits: std.ArrayList(placement.Edit) = .empty;
    var last_owned: ?usize = null;
    var i: usize = 0;
    while (i < text.len) {
        const e = lineEnd(text, i);
        if (ownedCall(text[i..e], owner)) |call| {
            last_owned = e;
            const now = holder(items, call.name);
            if (now) |it| {
                if (it.count != call.count) if (it.count) |cnt| {
                    // The count: its number, or a new last argument.
                    const line = text[i..e];
                    const close = std.mem.lastIndexOfScalar(u8, line, ')') orelse return error.BadLine;
                    if (call.count != null) {
                        var end = close;
                        while (end > 0 and line[end - 1] == ' ') end -= 1;
                        var k = end;
                        while (k > 0 and (std.ascii.isDigit(line[k - 1]) or line[k - 1] == '-')) k -= 1;
                        try edits.append(a, .{ .span = .{ .start = i + k, .end = i + end }, .text = try std.fmt.allocPrint(a, "{d}", .{cnt}) });
                    } else try edits.append(a, .{ .span = .{ .start = i + close, .end = i + close }, .text = try std.fmt.allocPrint(a, ", {d}", .{cnt}) });
                };
            } else try edits.append(a, .{ .span = .{ .start = i, .end = e }, .text = "" });
        }
        i = e;
    }
    // New names, after their class's last line (else the owner's last call).
    for (items) |it| for (it.names.items) |name| {
        if (holder(old, name) != null) continue;
        var at: ?usize = null;
        var k: usize = 0;
        while (k < text.len) {
            const e = lineEnd(text, k);
            if (ownedCall(text[k..e], owner)) |call| if (std.ascii.eqlIgnoreCase(call.class, it.class)) {
                at = e;
            };
            k = e;
        }
        const pos = at orelse last_owned orelse blk: {
            const body = funcBody(text, "post_init") orelse return error.NoPostInit;
            break :blk lineEnd(text, body.start - 1);
        };
        const f = if (it.weapon()) "Weapon_New" else "Item_New";
        const line = if (it.count) |cnt|
            try std.fmt.allocPrint(a, "\t{s}(\"{s}\", \"{s}\", \"{s}\", {d});{s}", .{ f, name, it.class, owner, cnt, nl })
        else
            try std.fmt.allocPrint(a, "\t{s}(\"{s}\", \"{s}\", \"{s}\");{s}", .{ f, name, it.class, owner, nl });
        try edits.append(a, .{ .span = .{ .start = pos, .end = pos }, .text = line });
    };
    // Inserts at one point keep their order (apply sorts by start, stable for equal ones).
    return placement.apply(gpa, text, edits.items);
}

test "inventory: parse by class, write back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hro = "function post_init()\r\n{\r\n" ++
        "\tItem_New(\"su_food\", \"ci_food.s\", \"Sullivan\");\r\n" ++
        "\tItem_New(\"su_band1\", \"ci_bandage.s\", \"Sullivan\");\r\n" ++
        "\tItem_New(\"su_band2\", \"ci_bandage.s\", \"Sullivan\");\r\n" ++
        "\t//==== AMMO ====\r\n" ++
        "\tItem_New(\"su_am_pistol\", \"ca_pistolammo.s\", \"Sullivan\" , 12);\r\n" ++
        "};\r\n";
    const items = try parseOwned(a, hro, "sullivan");
    try std.testing.expectEqual(3, items.len);
    try std.testing.expectEqual(2, items[1].names.items.len);
    try std.testing.expectEqual(12, items[2].count.?);
    const out = try writeOwned(std.testing.allocator, hro, items, "Sullivan");
    defer std.testing.allocator.free(out);
    const back = try parseOwned(a, out, "Sullivan");
    try std.testing.expectEqual(3, back.len);
    try std.testing.expectEqual(12, back[2].count.?);
    // Unchanged: byte for byte.
    try std.testing.expectEqualStrings(hro, out);
    // One bandage less, ammo 20, a knife after the food: only those lines change.
    _ = items[1].names.pop();
    items[2].count = 20;
    var knife: Item = .{ .class = "cw_stilleto.s" };
    try knife.names.append(a, "su_stilleto_1");
    var list: std.ArrayList(Item) = .empty;
    try list.appendSlice(a, items);
    try list.append(a, knife);
    const out2 = try writeOwned(std.testing.allocator, hro, list.items, "Sullivan");
    defer std.testing.allocator.free(out2);
    try std.testing.expect(std.mem.indexOf(u8, out2, "su_band2") == null);
    try std.testing.expect(std.mem.indexOf(u8, out2, "\"Sullivan\" , 20);") != null);
    try std.testing.expect(std.mem.indexOf(u8, out2, "\"Sullivan\" , 20);\r\n\tWeapon_New(\"su_stilleto_1\", \"cw_stilleto.s\", \"Sullivan\");\r\n};") != null);
}

const sample =
    "#include ci_box.s\r\n" ++
    "string itm_1;\r\nstring itm_2;\r\n" ++
    "function init()\r\n{\r\n" ++
    "  itm_1 = \"b_crowbar1\";\r\n" ++
    "  itm_2 = \"b_food1,b_food2\";\r\n" ++
    "  cnt_itm=2;\r\n" ++
    "};\r\n" ++
    "function post_init_box()\r\n{\r\n" ++
    "  Weapon_New(\"b_crowbar1\",\"cw_crowbar.s\");\r\n" ++
    "  //Item_New(\"old\",\"ci_food.s\");\r\n" ++
    "  Item_New(\"b_food1\",\"ci_food.s\");\r\n" ++
    "  Item_New(\"b_food2\",\"ci_food.s\");\r\n" ++
    "};\r\n";

test "box: parse, change, write back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var items = try parse(a, sample);
    try std.testing.expectEqual(2, items.len);
    try std.testing.expectEqualStrings("cw_crowbar.s", items[0].class);
    try std.testing.expectEqual(2, items[1].names.items.len);

    // Unchanged contents keep the script byte for byte (but the spacing of rebuilt lines).
    const same = try write(std.testing.allocator, sample, items);
    defer std.testing.allocator.free(same);
    const again = try parse(a, same);
    try std.testing.expectEqual(2, again.len);

    // One food less, pistol ammo with a count in a third slot.
    _ = items[1].names.pop();
    var ammo: Item = .{ .class = "ca_pistolammo.s", .count = 24 };
    try ammo.names.append(a, "b_ammo1");
    var list: std.ArrayList(Item) = .empty;
    try list.appendSlice(a, items);
    try list.append(a, ammo);
    const out = try write(std.testing.allocator, sample, list.items);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "string itm_2;\r\nstring itm_3;\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  itm_2 = \"b_food1\";\r\n  itm_3 = \"b_ammo1\";\r\n  cnt_itm=3;\r\n};") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Item_New(\"b_food2\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "  Item_New(\"b_ammo1\",\"ca_pistolammo.s\",24);\r\n  //Item_New(\"old\"") != null);
    const back = try parse(a, out);
    try std.testing.expectEqual(24, back[2].count.?);
}

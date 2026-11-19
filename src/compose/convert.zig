//! The converter: a Classic game into an OpenGorky project,
//! one way. The Classic reader's classes (the runtime's, with their `.var`) and the rules
//! in force are the model; each object becomes a data block of its location in archive
//! order (the order the exe makes them in: the logs and the random draws depend on it)
//! and its class one component (`script/classic/ogsify.zig`, its inherited functions
//! too: the class as the exe resolves it). What the creation events set provably as
//! data (`classic/lift.zig`, the runtime's conservative options) leaves the code:
//! - a variable's value → a field of the block (schema fields) or `var T name = v;`
//!   (the class's own variables), only where it differs from what the OG reader starts
//!   the object with (the schema's default, its look);
//! - `act_*.ss` (ActorSetWalkSpeed, RegisterIdleAnimation, RegisterAnimation of init(),
//!   NotInPlaceAnimation, ReferenceAnimation of postinit()) → a shared `look` block
//!   (an animation the model lacks stays, as Classic registers it: the build warns);
//! - initCamera() → `camera = Camera(…)`; the level's restore() PlaceActor → `placement`;
//!   a level's restore() placing unconditionally → its objects' `tile`/`at`, its `placement`
//!   (`liftPlacing`).
//! The rest stays each event's code. Scenes and dialogs are blocks (texts cp1251 →
//! UTF-8), the rules every table's rows (keyed by archetypes where a number is only
//! theirs, `keyRefs`), the texts of `string.tab`, `items.inf` and `activeareas.inf` on
//! the blocks owning their numbers (`name`, `examine`), the rest rows (`UiText`,
//! `Examine`, `AreaExamine`, UTF-8), the heroes `characters::<hero>` and the game's
//! `party`. A location's objects of one Classic entity script (`ft_*.ss`, `wp_*.ss`) are
//! instances of one archetype (`fold`). The OG writer writes it (compose/og/write.zig), the manifest last.
//! The one place that sees both formats (scripts/layercheck.sh).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const script = @import("../script.zig");
const ir = script.ir;
const object = script.object;
const ogsify = script.classic.ogsify;
const lift = script.classic.lift;
const Runtime = script.runtime.Runtime;
const Value = script.value.Value;
const parser = script.ogs.parser;
const lexer = script.ogs.lexer;
const formats = @import("../formats.zig");
const archive = formats.archive;
const core = @import("../core.zig");
const schema = core.schema;
const builtins = @import("../builtins.zig");
const rules = @import("../rules.zig");
const generic = @import("../battle.zig").generic;
const immunity = @import("../battle.zig").immunity;
const og_write = @import("og/write.zig");
const print_ogs = script.ogs.print;
const assets = @import("../loaders.zig").assets;
const state_object = @import("../state.zig").object;
const codec = @import("../loaders.zig").codec;
const rules_text = @import("../loaders.zig").rules_text;

/// The steps as `Progress` names them.
pub const Step = enum { read, locations, scenes, dialogs, rules, assets, write };

/// The converter's progress: step, done, of total (gorky-tool prints a line, the editor a bar).
pub const Progress = struct {
    ctx: ?*anyopaque = null,
    on: ?*const fn (ctx: ?*anyopaque, step: Step, done: usize, total: usize) void = null,
    /// Set (by another thread: the editor's Cancel), the run stops at its next step or
    /// file with error.Canceled (before step 7 nothing of the project is written but
    /// the assets of step 6, which the caller removes).
    stop: ?*const std.atomic.Value(bool) = null,

    fn tell(self: Progress, step: Step, done: usize, total: usize) error{Canceled}!void {
        if (self.stop) |s| if (s.load(.monotonic)) return error.Canceled;
        if (self.on) |f| f(self.ctx, step, done, total);
    }
};

/// The project's id and title as gorky-tool and the editor convert the game (one, so the
/// two give the same bytes); the title tells it from the original (the launcher's game
/// choice, the main menu).
pub const game_id = "gorky";
pub const game_title = "Gorky 17 (OpenGorky)";

/// The report's counts as one line (gorky-tool prints it, the editor's summary shows it).
pub fn statsLine(w: *Writer, r: *const Report) Writer.Error!void {
    try w.print("converted: objects {d}, components {d}, looks {d}, fields {d}, vars {d}, scenes {d}, dialogs {d}, rules rows {d}, texts {d} (on blocks {d}), own assets {d}, traits {d} (components on them {d}), area triggers {d}, battle placing as data {d} (left code {d}), location placing as data {d} (left code {d}), entry points as data {d}, archetypes {d} (instance fields inherited {d}, weapons nested {d}), rows by archetype {d} (left by number {d}), values by archetype {d}, archetypes renamed {d} (collisions {d})", .{ r.objects, r.components, r.looks, r.fields, r.vars, r.scenes, r.dialogs, r.rows, r.texts, r.texts_on, r.assets, r.traits, r.split, r.triggers, r.placed_data, r.placed_code, r.loc_placed_data, r.loc_placed_code, r.entry_data, r.archetypes, r.inherited, r.nested, r.key_refs, r.key_numbers, r.value_refs, r.renamed, r.collisions });
}

pub const Options = struct {
    /// The project's id and title (the manifest's).
    id: []const u8,
    title: []const u8 = "",
    /// The installed game's folder, as the manifest names it.
    game: []const u8,
    /// The rules in force (`rules\<name>.ss` entries, compose.rulesFiles: the built-ins
    /// over the game's): every table's rows.
    rules: []const archive.File,
    /// The installed game's `dat` when the Classic game converted is another folder (a
    /// modded copy): its new and changed assets go to `src/assets/`. Null:
    /// the game is the installed one, it has none.
    installed: ?Io.Dir = null,
};

/// What the conversion did: counts and the lines of the report.
const IdOf = struct { path: []const u8, id: i32 };

/// `.og/classic_ids.txt` of project folder `out`: `path=number` a line (the editor's folder:
/// never built into the package; convert-check maps the numbers by it).
fn writeIds(io: Io, a: Allocator, out: Io.Dir, ids: []const IdOf) !void {
    var w: std.Io.Writer.Allocating = .init(a);
    try w.writer.writeAll("# The Classic number of each block the converter wrote without one (its identity is its path);\n# `!<file>=<number>`: a Classic text of no one, not written.\n");
    for (ids) |x| try w.writer.print("{s}={d}\n", .{ x.path, x.id });
    try out.createDirPath(io, ".og");
    try out.writeFile(io, .{ .sub_path = ".og/classic_ids.txt", .data = w.written() });
}

pub const Report = struct {
    objects: usize = 0,
    components: usize = 0,
    looks: usize = 0,
    fields: usize = 0,
    vars: usize = 0,
    scenes: usize = 0,
    dialogs: usize = 0,
    rows: usize = 0,
    /// Texts of `string.tab`, `items.inf`, `activeareas.inf`, and the `name`/`examine`
    /// fields they became on blocks (the rest are rows `UiText`, `Examine`, `AreaExamine`).
    texts: usize = 0,
    texts_on: usize = 0,
    /// Classes' shared code made traits, and the components that implement them.
    traits: usize = 0,
    split: usize = 0,
    /// adjust.kdt settings left out: no code of the engine reads them, or at its default
    /// (rules/adjust_defaults.zig).
    settings_unread: usize = 0,
    /// Values a block of `same_as` takes from that block (sameAsDiff), no more written.
    same_as_dropped: usize = 0,
    /// Values a block of `same_as` would take from that block where it had none, with no
    /// empty form to write instead (warned).
    same_as_kept: usize = 0,
    /// The heroes' empty ammo packs not written (dropEmptyPacks).
    empty_packs: usize = 0,
    /// Blocks whose class code is written in them (ownCode).
    own_code: usize = 0,
    /// Rules rows moved into their block's fields (rowsToBlocks).
    rows_in_blocks: usize = 0,
    /// Traits nothing implements (dropUnusedTraits).
    traits_unused: usize = 0,
    /// Statements and methods of Classic code doing nothing, not written (pruneDead).
    dead_code: usize = 0,
    /// The blocks whose classic_id the project no longer writes (`dropIds`): path and the
    /// Classic number, for the checks (`.og/classic_ids.txt`); how many kept it.
    ids: []const IdOf = &.{},
    ids_kept: usize = 0,
    /// Values naming a block by number made references to its archetype.
    ids_refs: usize = 0,
    /// Rules rows naming a number no block has nor the code sets (Classic's weapons and
    /// fighters the game never makes: the Smoke Rider's second rocket 1004…): dropped.
    ids_dead: usize = 0,
    /// Area triggers taken out of the levels' OnUpdate into their own components.
    triggers: usize = 0,
    /// Assets written to `src/assets/` (new or changed against the installed game).
    assets: usize = 0,
    /// A battle restore()'s placing calls of its objects: made their blocks' data
    /// (`tile`, `at`, the level's `placement`), and left code (conditional, after other
    /// code, placed twice).
    placed_data: usize = 0,
    placed_code: usize = 0,
    /// The same of the locations' restore() (re-entry places the data too).
    loc_placed_data: usize = 0,
    loc_placed_code: usize = 0,
    /// restore()'s `PlaceActor(GUI_GetSelectedHero(), "<point>", 0)` made the level's `entry`
    ///; those left code are in `placed_code`/`loc_placed_code`.
    entry_data: usize = 0,
    /// Archetypes folded of the locations' instances (`fold`: `characters::garcia`,
    /// `weapons::garcialong`), the instances' fields they hold instead (each instance's
    /// field gone counted), and the weapons nested in fighter archetypes (instances' objects).
    archetypes: usize = 0,
    inherited: usize = 0,
    nested: usize = 0,
    /// Rules rows keyed by archetype references now (`keyRefs`), and those left keyed by a
    /// number (no archetype is the number's alone: an unused row, a level's own block).
    key_refs: usize = 0,
    key_numbers: usize = 0,
    /// Rules values naming an entity made references (`valueRefs`: MonsterAttack `strike`…).
    value_refs: usize = 0,
    /// Archetypes named without their Classic file's prefix (`cw_axe` → `weapons::axe`), and
    /// those whose name another had already (`axe_2`; each in `lines`).
    renamed: usize = 0,
    collisions: usize = 0,
    lines: std.ArrayList([]const u8) = .empty,
    /// What the OG writer writes.
    project: og_write.Project = .{ .manifest = .{ .id = "" }, .modules = &.{} },
};

/// Game `dat` converted (in `a`, an arena): the project model, written into `out` (an
/// empty folder) by the OG writer.
pub fn run(io: Io, a: Allocator, dat: Io.Dir, out: Io.Dir, opts: Options, progress: Progress) !Report {
    var c: Conv = .{ .io = io, .a = a, .dat = dat, .progress = progress };
    defer c.deinit();
    try c.all(opts);
    if (opts.installed) |inst| c.report.assets = try ownAssets(io, a, dat, inst, out, progress);
    try progress.tell(.write, 0, 1);
    try og_write.write(io, a, out, c.report.project);
    try writeIds(io, a, out, c.report.ids);
    try progress.tell(.write, 1, 1);
    return c.report;
}

/// Each asset entry of game `dat`'s archives (one the asset table maps, no
/// script or other text the converter turns into OG Script) that installed game `installed` lacks or has other bytes of, written to
/// `out/src/assets/<logical path>`. The count.
fn ownAssets(io: Io, a: Allocator, dat: Io.Dir, installed: Io.Dir, out: Io.Dir, progress: Progress) !usize {
    const gpa = std.heap.page_allocator;
    const paths = try archive.listArchives(io, gpa, dat);
    defer archive.freeList(gpa, paths);
    // Counted first: the step is told a file at a time (the long one of a modded copy).
    var total: usize = 0;
    for (paths) |p| {
        var ar = try archive.Archive.open(io, gpa, dat, p);
        total += ar.entries.len;
        ar.close(io, gpa);
    }
    var n: usize = 0;
    var done: usize = 0;
    for (paths) |p| {
        var mine = try archive.Archive.open(io, gpa, dat, p);
        defer mine.close(io, gpa);
        var theirs: ?archive.Archive = archive.Archive.open(io, gpa, installed, p) catch null;
        defer if (theirs) |*t| t.close(io, gpa);
        for (mine.entries) |*e| {
            try progress.tell(.assets, done, total);
            done += 1;
            if (isConverted(e.name)) continue;
            var buf: [assets.max_path]u8 = undefined;
            const logical = assets.fromEntry(&buf, p, e.name) orelse continue;
            const bytes = try mine.readAlloc(io, a, e);
            if (theirs) |*t| if (t.find(e.name)) |te| if (std.mem.eql(u8, bytes, try t.readAlloc(io, a, te))) continue;
            const path = try std.fmt.allocPrint(a, "src/assets/{s}", .{logical});
            if (std.fs.path.dirname(path)) |d| try out.createDirPath(io, d);
            try out.writeFile(io, .{ .sub_path = path, .data = bytes });
            n += 1;
        }
    }
    try progress.tell(.assets, total, total);
    return n;
}

/// Entry `name` is what the converter makes OG Script of (scripts, `.var`, scenes,
/// dialogs), no asset.
fn isConverted(name: []const u8) bool {
    if (formats.resource.isScript(name)) return true;
    const ext = std.fs.path.extension(name);
    for ([_][]const u8{ ".var", ".scr", ".pts", ".dlg" }) |x| if (std.ascii.eqlIgnoreCase(ext, x)) return true;
    return false;
}

test "ownAssets: only what the installed game lacks or has other bytes of" {
    const testing = std.testing;
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "mod/dat/common", "game/dat/common", "out" }) |d| try tmp.dir.createDirPath(io, d);
    const mod = try archive.build(a, &.{ .{ .name = "same.spr", .data = "s" }, .{ .name = "changed.spr", .data = "new" }, .{ .name = "icons\\added.spr", .data = "+" } });
    // A script is no asset (the converter makes it OG Script).
    try tmp.dir.writeFile(io, .{ .sub_path = "mod/dat/common/other.dat", .data = try archive.build(a, &.{.{ .name = "classes\\x.s", .data = "int n;" }}) });
    const game = try archive.build(a, &.{ .{ .name = "same.spr", .data = "s" }, .{ .name = "changed.spr", .data = "old" } });
    try tmp.dir.writeFile(io, .{ .sub_path = "mod/dat/common/sprite.dat", .data = mod });
    try tmp.dir.writeFile(io, .{ .sub_path = "game/dat/common/sprite.dat", .data = game });
    var dat = try tmp.dir.openDir(io, "mod/dat", .{ .iterate = true });
    defer dat.close(io);
    var inst = try tmp.dir.openDir(io, "game/dat", .{ .iterate = true });
    defer inst.close(io);
    var out = try tmp.dir.openDir(io, "out", .{});
    defer out.close(io);
    try testing.expectEqual(@as(usize, 2), try ownAssets(io, a, dat, inst, out, .{}));
    try testing.expectEqualStrings("new", try out.readFileAlloc(io, "src/assets/sprites/changed.spr", a, .limited(64)));
    try testing.expectEqualStrings("+", try out.readFileAlloc(io, "src/assets/sprites/icons/added.spr", a, .limited(64)));
    try testing.expectError(error.FileNotFound, out.access(io, "src/assets/sprites/same.spr", .{}));
}

/// Script sources of one archive: its own entries, then `common/other.dat`'s classes,
/// scriptlets, gamestart (the Classic reader's order, loaders/world.zig findScript).
const Sources = struct {
    io: Io,
    a: Allocator,
    local: *const archive.Archive,
    common: *const archive.Archive,

    fn fetch(ctx: *anyopaque, name: []const u8) anyerror!?[]const u8 {
        const self: *Sources = @ptrCast(@alignCast(ctx));
        if (self.local.find(name)) |e| return try self.local.readAlloc(self.io, self.a, e);
        var buf: [archive.name_size]u8 = undefined;
        for ([_][]const u8{ "classes", "scriptlets", "gamestart" }) |dir| {
            const path = try std.fmt.bufPrint(&buf, "{s}\\{s}", .{ dir, name });
            if (self.common.find(path)) |e| return try self.common.readAlloc(self.io, self.a, e);
        }
        return null;
    }
};

/// Builtins as signatures only: the converter never runs code (the lift and ogsify ask
/// what a builtin is: declarative, pure, its result type).
fn noCall(_: *anyopaque, _: *Runtime, _: *object.Object, _: []const Value) anyerror!Value {
    return error.NotRun;
}

/// Block kinds by Classic extension (state/object.zig nativeFor; world/start.zig makes
/// the object of the block's kind as the extension did).
const exts = [_]struct { []const u8, []const u8 }{
    .{ ".ftr", "fighter" }, .{ ".hro", "hero" },        .{ ".wpn", "weapon" }, .{ ".itm", "item" },     .{ ".are", "area" },
    .{ ".ba", "anim" },     .{ ".aba", "active_anim" }, .{ ".act", "actor" },  .{ ".obs", "obstacle" }, .{ ".obs_i", "obstacle" },
};

fn blockKind(cls: *const object.Class, ext: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(ext, ".lev")) return if (cls.isA("combatlevel")) "battle" else "level";
    for (exts) |e| if (std.ascii.eqlIgnoreCase(e[0], ext)) return e[1];
    return null;
}

/// The OGS host kind of a component (ogsify: its traits' events) for block kind `k`.
fn hostKind(k: []const u8) []const u8 {
    if (std.mem.eql(u8, k, "hero")) return "fighter";
    return k;
}

/// The look calls (`act_*.ss`) and the hero's postinit() ones.
const look_calls = [_][]const u8{ "ActorSetWalkSpeed", "RegisterIdleAnimation", "RegisterAnimation", "NotInPlaceAnimation", "ReferenceAnimation" };

/// One look: its text (the fields inside its block) and its name.
const Look = struct { name: []const u8, body: []const u8 };

const Conv = struct {
    io: Io,
    a: Allocator,
    dat: Io.Dir,
    progress: Progress,
    report: Report = .{},
    common: ?archive.Archive = null,
    /// The installed game's assets (models: a look's animations).
    stack: ?assets.Stack = null,
    looks: std.ArrayList(Look) = .empty,
    modules: std.ArrayList(ir.Module) = .empty,
    /// The runtimes of the archives read: the IR the components hold points into them.
    runtimes: std.ArrayList(*Kept) = .empty,
    /// Making archetypes (no `.var`: Weapon_New/Item_New objects have none).
    archetype: bool = false,
    /// Making a morph's class (`.mtm`): every value its creation events set is written, a
    /// default too (the morphed actor keeps its old values, Runtime.morph).
    full: bool = false,
    /// The edition's language number (string.tab's; the manifest's `language`).
    language: u8 = 0,
    /// Its texts' code page.
    page: formats.cp1251.Page = .cp1251,
    /// The battle devices' class files (the rules' `Device(archetype = "ft_time_bomb.ss")`):
    /// archetypes too.
    devices: std.ArrayList([]const u8) = .empty,
    /// Rows the Classic reader's field rules give objects (`fieldRow`): rules text, parsed
    /// with the rules' rows at the end.
    field_rows: std.ArrayList(u8) = .empty,
    /// The location being converted: its actor objects (lower-case names; `liftPlacing`
    /// places only these), and the placing its restore() gave them as data (the field's
    /// statement, written into the object's block).
    actors: std.StringHashMapUnmanaged(void) = .empty,
    tiles: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The names blocks declare, by kind (`spellingOf`).
    names: struct { levels: []const []const u8 = &.{}, scenes: []const []const u8 = &.{}, dialogs: []const []const u8 = &.{} } = .{},
    /// A location's fighter or weapon object made of a Classic entity script (`01bg_garcia1.ftr`
    /// includes `ft_garcia.ss`, rules.classOf): "<level>\x00<name>" → that script's stem
    /// (`ft_garcia`), its archetype's group (`fold`).
    inst_arch: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The common classes made archetypes (`archetypeNames`, in archive order), and each
    /// one's path by its file's lower-case stem (`cw_axe` → `weapons::axe`): what
    /// Item_New/Weapon_New and the Device rows name instead of the Classic file (`spellingOf`).
    arch_list: std.ArrayList(Arch) = .empty,
    arch_paths: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// Each word of the game's scripts, scenes, dialogs and `.var` (lower case, strings
    /// too) and how often `function <word>` defines it (`mentions`).
    words: std.StringHashMapUnmanaged(u32) = .empty,
    defs: std.StringHashMapUnmanaged(u32) = .empty,
    /// The game's dialogs (its `.dlg` names, lower case, without the extension).
    dialog_names: std.StringHashMapUnmanaged(void) = .empty,
    /// A word's first spelling with capitals in the texts (`#inherit BitmapAnimation`: the
    /// archive's file is `bitmapanimation.s`), by its lower case: the traits' names.
    spellings: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The locations' heroes of their own `.hro` (`01_port`'s bt), by `instKey`: `foldHeroes`.
    heroes: std.StringHashMapUnmanaged(void) = .empty,
    /// Each level's Logic whose OnUpdate checks heroes in map areas (`triggersOut`), with
    /// the component names its triggers get, in their order.
    triggers: std.ArrayList(Triggers) = .empty,
    /// Each attached component made of a class with functions of other files (`splitClasses`).
    splits: std.ArrayList(Split) = .empty,

    const Arch = struct { file: []const u8, cls: *object.Class, ns: []const u8, kind: []const u8, name: []const u8 };

    const Kept = struct { arc: archive.Archive, sources: Sources, rt: Runtime };
    const Triggers = struct { logic: *const ir.Component, level: []const u8, kind: []const u8, ns: []const u8, names: []const []const u8 };

    /// A component as `addObject` made it, kept for `splitClasses`: its class's methods
    /// as `classOf` gave them (own: of the object's file) before the lifted replacements
    /// (`by`: an original → its replacement).
    const Split = struct {
        comp: *const ir.Component,
        oc: ogsify.Class,
        methods: []const ogsify.Method,
        by: []const [2]*const ir.Fn,
        rt: *Runtime,
    };

    fn deinit(self: *Conv) void {
        for (self.runtimes.items) |k| {
            k.rt.deinit();
            k.arc.close(self.io, std.heap.page_allocator);
        }
        if (self.stack) |*s| s.deinit();
        if (self.common) |*x| x.close(self.io, std.heap.page_allocator);
    }

    /// The declared name `name` of sigil kind `sg` stands for (any case): a location, a
    /// scene, a dialog of the game.
    fn spellingOf(ctx: *const anyopaque, sg: ir.Sigil, name: []const u8) ?[]const u8 {
        const self: *const Conv = @ptrCast(@alignCast(ctx));
        // A Classic class file (Item_New's `"cw_axe.s"`, ogsify): its archetype's path.
        if (sg == .item) return self.arch_paths.get(classStem(name, self.a) catch return null);
        const list = switch (sg) {
            .level => self.names.levels,
            .scene => self.names.scenes,
            .dialog => self.names.dialogs,
            else => return null,
        };
        for (list) |n| if (std.ascii.eqlIgnoreCase(n, name)) return n;
        return null;
    }

    fn line(self: *Conv, comptime fmt: []const u8, args: anytype) !void {
        try self.report.lines.append(self.a, try std.fmt.allocPrint(self.a, fmt, args));
    }

    fn all(self: *Conv, opts: Options) !void {
        const gpa = std.heap.page_allocator;
        self.common = try archive.Archive.open(self.io, gpa, self.dat, "common/other.dat");
        self.stack = try .classic(self.io, gpa, self.dat);
        const levels = try archive.levelDirs(self.io, gpa, self.dat);
        defer archive.freeList(gpa, levels);
        try self.declaredNames(levels);
        try self.mentions(levels);
        // The heroes and the party's shared items (gamestart\, the common archive).
        try self.progress.tell(.read, 0, 1);
        var rows = try self.parseRules(opts.rules);
        for (rows) |r| if (r.kind == .call and std.mem.eql(u8, r.kind.call.text, "Device")) for (r.kind.call.named) |n|
            if (std.mem.eql(u8, n.name, "archetype") and n.value.kind == .lit and n.value.kind.lit == .string) try self.devices.append(self.a, n.value.kind.lit.string);
        // The common archive's runtime (gamestart's, archetypes'); the archetypes' names
        // first: the heroes' code names them (`item::NewWeapon("…", "weapons::bayonet")`).
        _ = try self.runtime("common/other.dat");
        try self.archetypeNames();
        rows = try self.deviceRefs(rows);
        try self.gamestart();
        try self.archetypes();
        try self.progress.tell(.read, 1, 1);
        for (levels, 0..) |l, i| {
            try self.progress.tell(.locations, i, levels.len);
            // `dat/common` is the shared archives, no location.
            if (!std.ascii.eqlIgnoreCase(l, "common")) try self.location(l);
        }
        try self.progress.tell(.locations, levels.len, levels.len);
        // Before the folds: an archetype takes its instances' component as it is then.
        try self.splitClasses();
        try self.fold("weapon", "wp_", "weapons");
        try self.fold("fighter", "ft_", "characters");
        try self.foldPlaced("item", "items");
        try self.foldPlaced("weapon", "weapons");
        try self.foldPlaced("obstacle", "obstacles");
        try self.foldPlaced("actor", "actors");
        try self.foldPlaced("area", "areas");
        try self.foldHeroes();
        try self.triggersOut();
        try self.lookModule();
        // Dialogs first: a scene names one by its block (`dialog::Open(~d"port-arriving")`).
        try self.dialogs();
        try self.scenes();
        try self.progress.tell(.rules, 0, 1);
        // The field rules' rows (the OG reader has no such rule).
        if (self.field_rows.items.len > 0) rows = try std.mem.concat(self.a, *const ir.Expr, &.{ rows, try self.parseRules(&.{.{ .name = "field rules", .data = self.field_rows.items }}) });
        rows = try self.fxAsFields(rows);
        rows = try self.keyRefs(rows);
        self.report.rows = rows.len;
        try self.modules.append(self.a, .{ .path = "", .uses = &.{}, .fns = &.{}, .components = &.{}, .entities = &.{}, .rows = rows });
        try self.texts();
        try self.ammoRefs();
        for (self.modules.items) |m| try actionRefs(self.a, m.entities);
        for (self.modules.items) |m| try classRefs(self.a, m.entities);
        try self.dropIds();
        try self.sceneRefs();
        try self.dropUnusedTraits();
        try self.battleRows();
        try self.nameLists();
        try self.aiProfiles();
        try self.codedIdRows();
        try self.rowsToBlocks();
        try self.campaignToGame();
        try self.actionBlocks();
        try self.settingsBlock();
        try self.levelDialogs();
        try self.sameAsDiff();
        try self.levelCode();
        try self.ownCode();
        try self.avengerCode();
        try self.dropEmptyPacks();
        // The exe's special AI scorings as the project's code (AiScoring `script`).
        var sd: parser.Diagnostic = .{};
        const su = try parser.parse(self.a, core.classic.ai_scoring_ogs, "ai_scoring.ogs", &sd);
        try self.modules.appendSlice(self.a, su.modules);
        try self.progress.tell(.rules, 1, 1);
        const code = @import("../loaders.zig").ogs.manifest.languageCode(self.language);
        self.report.project = .{ .manifest = .{ .id = opts.id, .title = opts.title, .game = opts.game, .base = code, .language = code }, .modules = self.modules.items };
    }

    /// Each weapon's `ammo` number as OG writes it (OG Script's `ammo` is a reference; the
    /// OG reader sets the number back): N > 0 as `ammo = ~i"items::x"`, the item archetype
    /// of classic_id N, −1 as `thrown = true`; 0 (none) and a number no archetype
    /// has go (the game has no such weapon; a mod's loses its ammo, logged).
    fn ammoRefs(self: *Conv) !void {
        const a = self.a;
        var by_id: std.AutoHashMapUnmanaged(i32, []const u8) = .empty;
        for (self.modules.items) |m| if (std.mem.eql(u8, m.path, "items")) for (m.entities) |e| if (std.mem.eql(u8, e.kind, "item")) {
            for (e.fields) |f| if (std.mem.eql(u8, f.name, "classic_id")) if (schema.int(f.value)) |n| {
                const g = try by_id.getOrPut(a, n);
                if (!g.found_existing) g.value_ptr.* = try std.fmt.allocPrint(a, "items::{s}", .{e.name});
            };
        };
        for (self.modules.items) |m| try ammoIn(a, &by_id, m.entities);
    }

    fn declaredNames(self: *Conv, levels: []const []const u8) !void {
        const a = self.a;
        const ls = try a.alloc([]const u8, levels.len);
        for (ls, levels) |*l, x| l.* = try a.dupe(u8, x);
        self.names.levels = ls;
        var sc: std.ArrayList([]const u8) = .empty;
        for (self.common.?.entries) |e| if (std.ascii.startsWithIgnoreCase(e.name, "scriptlets\\") and std.ascii.endsWithIgnoreCase(e.name, ".scr"))
            try sc.append(a, try a.dupe(u8, e.name["scriptlets\\".len .. e.name.len - 4]));
        self.names.scenes = sc.items;
        var lang = try archive.Archive.open(self.io, std.heap.page_allocator, self.dat, "common/lang.dat");
        defer lang.close(self.io, std.heap.page_allocator);
        var dl: std.ArrayList([]const u8) = .empty;
        for (lang.entries) |e| if (std.ascii.endsWithIgnoreCase(e.name, ".dlg")) try dl.append(a, try a.dupe(u8, e.name[0 .. e.name.len - 4]));
        self.names.dialogs = dl.items;
    }

    /// The scenes' `@` names in one spelling: the project's most used one for that name
    /// (`@Bt`, `@bt` → `@BT`, as levels place it; the exe finds actors ignoring case).
    fn sceneRefs(self: *Conv) !void {
        const a = self.a;
        var count: std.StringArrayHashMapUnmanaged(u32) = .empty;
        const Walk = struct {
            fn expr(al: Allocator, n: *std.StringArrayHashMapUnmanaged(u32), v: *const ir.Expr) !void {
                switch (v.kind) {
                    .ref => |r| (try n.getOrPutValue(al, r, 0)).value_ptr.* += 1,
                    .call => |c| {
                        for (c.args) |x| try expr(al, n, x);
                        for (c.named) |x| try expr(al, n, x.value);
                    },
                    .list => |l| for (l) |x| try expr(al, n, x),
                    else => {},
                }
            }
            fn entity(al: Allocator, n: *std.StringArrayHashMapUnmanaged(u32), e: *const ir.Entity) !void {
                for (e.fields) |f| try expr(al, n, f.value);
                for (e.rows) |r| try expr(al, n, r);
                for (e.children) |*c| {
                    (try n.getOrPutValue(al, c.name, 0)).value_ptr.* += 1;
                    try entity(al, n, c);
                }
            }
        };
        for (self.modules.items) |m| for (m.entities) |*e| try Walk.entity(a, &count, e);
        var best: std.StringHashMapUnmanaged([]const u8) = .empty;
        var top: std.StringHashMapUnmanaged(u32) = .empty;
        for (count.keys(), count.values()) |n, k| {
            const low = try std.ascii.allocLowerString(a, n);
            const t = try top.getOrPut(a, low);
            if (t.found_existing and t.value_ptr.* >= k) continue;
            t.value_ptr.* = k;
            try best.put(a, low, n);
        }
        for (self.modules.items) |m| for (m.entities) |e| if (std.mem.eql(u8, e.kind, "scene")) for (e.rows) |r| if (r.kind == .call) for (r.kind.call.args) |x| if (x.kind == .ref) {
            if (best.get(try std.ascii.allocLowerString(a, x.kind.ref))) |n| @constCast(x).kind = .{ .ref = n };
        };
    }

    /// No classic_id in the project (a block's path is its
    /// identity; the OG reader gives the core a number, loaders/ogs.zig `idOf`): each
    /// top-level block's number goes, except where something still names it by number —
    /// the core's built-in tables (core/classic.zig `namesId`), a rules row's or a field's
    /// value, the code (`object::GetNameID(x) == 30`, `item::SetNameID`), a level's own object
    /// of no archetype. Blocks sharing a number (the location's actor and the battle's
    /// fighter) become one: the others `same_as` the main one (a fighter, else a weapon, an
    /// item, then by path). `report.ids` records each dropped number.
    fn dropIds(self: *Conv) !void {
        const a = self.a;
        // `classic_id = -1` (not picked): `pickable = false`.
        for (self.modules.items) |m| try unpickable(a, m.entities);
        // A number some value names where no archetype can stand instead: kept.
        var hard: std.AutoHashMapUnmanaged(i32, void) = .empty;
        // The values naming a number by a field that takes an archetype: rewritten.
        var soft: std.ArrayList(SoftRef) = .empty;
        var lists: std.ArrayList(SoftList) = .empty;
        for (self.modules.items) |m| {
            for (m.rows) |r| try refsIn(a, &hard, &soft, &lists, r);
            for (m.entities) |e| try refsInEntity(a, &hard, &soft, &lists, e);
        }
        // Top-level blocks by number, and the levels' own objects of no archetype (`<level>/<name>`).
        const Blk = struct { e: *ir.Entity, path: []const u8, rank: u8, child: bool = false };
        var groups: std.AutoArrayHashMapUnmanaged(i32, std.ArrayList(Blk)) = .empty;
        for (self.modules.items) |*m| for (@constCast(m.entities)) |*e| {
            const n = entityId(e) orelse continue;
            if (n <= 0) continue;
            const rank: u8 = if (std.mem.eql(u8, e.kind, "fighter")) 0 else if (std.mem.eql(u8, e.kind, "weapon")) 1 else if (std.mem.eql(u8, e.kind, "item")) 2 else 3;
            // The root's fighters, weapons, items (game.ogs' fist) by their name, never the
            // main one of a group with a module's block.
            if (m.path.len == 0 and rank > 2) continue;
            const g = try groups.getOrPut(a, n);
            if (!g.found_existing) g.value_ptr.* = .empty;
            const path = if (m.path.len == 0) e.name else try std.fmt.allocPrint(a, "{s}::{s}", .{ m.path, e.name });
            try g.value_ptr.append(a, .{ .e = e, .path = path, .rank = if (m.path.len == 0) rank + 5 else rank });
        };
        for (self.modules.items) |*m| for (@constCast(m.entities)) |*lv| if (isLevelKind(lv.kind)) for (@constCast(lv.children)) |*c| {
            if (c.base.len > 0) continue;
            const n = entityId(c) orelse continue;
            if (n <= 0) continue;
            const g = try groups.getOrPut(a, n);
            if (!g.found_existing) g.value_ptr.* = .empty;
            try g.value_ptr.append(a, .{ .e = c, .path = try std.fmt.allocPrint(a, "{s}/{s}", .{ lv.name, c.name }), .rank = if (std.mem.eql(u8, c.kind, "item") or std.mem.eql(u8, c.kind, "weapon") or std.mem.eql(u8, c.kind, "fighter")) 4 else 5, .child = true });
        };
        for (groups.values()) |*g| std.mem.sort(Blk, g.items, {}, struct {
            fn lt(_: void, x: Blk, y: Blk) bool {
                return x.rank < y.rank or (x.rank == y.rank and std.mem.lessThan(u8, x.path, y.path));
            }
        }.lt);
        // The block of a group a reference of sigil `sg` can name (of its kind), if any; a
        // group of one level object alone: the object by its name (`fighter = "01pr_hornet02"`).
        const Pick = struct {
            fn of(g: []const Blk, sg: ir.Sigil) ?struct { []const u8, ir.Sigil } {
                if (g.len == 1 and g[0].child) return .{ g[0].e.name, .none };
                for (g) |b| if (!b.child) for (sg.blocks()) |k| if (std.mem.eql(u8, b.e.kind, k)) return .{ b.path, sg };
                return null;
            }
        };
        // A class file's class_init (its trait's OnClassInit) sets the class's number: the
        // block gives it (a level object's code setting another one, NATO's captain 141 after
        // class_init, keeps it).
        for (self.modules.items) |m| for (m.traits) |t| for (t.methods) |x| if (std.mem.eql(u8, x.f.name, "OnClassInit")) try dropIdSets(a, @constCast(x.f));
        // The code: `GetNameID(x) == N` → `object::GetClass(x) == "<path>"`, `or` each block
        // of N (a level's own object: `"<level>/<name>"`, world/start.zig own_key); any
        // other number on a NameID line stays.
        var by_class: std.AutoHashMapUnmanaged(i32, []const []const u8) = .empty;
        // The numbers the code sets (`classic_id = 141`: NATO's captain): live without a block.
        var coded: std.AutoHashMapUnmanaged(i32, void) = .empty;
        for (groups.keys(), groups.values()) |n, g| {
            const ps = try a.alloc([]const u8, g.items.len);
            for (g.items, ps) |b, *p| p.* = b.path;
            try by_class.put(a, n, ps);
        }
        for (self.modules.items) |m| for (m.traits) |t| for (t.methods) |x| {
            self.report.ids_refs += try classOfIds(a, x.f.body, &by_class);
        };
        for (self.modules.items) |m| for (m.components) |c| {
            for (c.methods) |f| self.report.ids_refs += try classOfIds(a, f.body, &by_class);
            var w: std.Io.Writer.Allocating = .init(a);
            try print_ogs.component(&w.writer, c, 0);
            var it = std.mem.splitScalar(u8, w.written(), '\n');
            while (it.next()) |ln| {
                const name_id = std.mem.indexOf(u8, ln, "NameID(") != null;
                if (!name_id and std.mem.indexOf(u8, ln, "classic_id") == null) continue;
                var t = std.mem.tokenizeAny(u8, ln, " ()=,;!<>");
                while (t.next()) |x| if (std.fmt.parseInt(i32, x, 10)) |n| try (if (name_id) &hard else &coded).put(a, n, {}) else |_| {};
            }
        };
        // A number of level objects alone whose main one (the first) has no text of its own
        // (no identity to give it): kept. The others (a battle's card the location's) are the
        // main one's `same_as`.
        for (groups.keys(), groups.values()) |n, g| {
            const top = for (g.items) |b| {
                if (!b.child) break true;
            } else false;
            if (!top and !namedBlock(g.items[0].e)) try hard.put(a, n, {});
        }
        // A reference no block of its kind can take: its number stays.
        for (soft.items) |r| {
            const g = groups.getPtr(r.n) orelse continue;
            if (!r.text and Pick.of(g.items, r.sigil) == null) try hard.put(a, r.n, {});
        }
        // In a list a place names an archetype only (not a level's object by its name).
        for (lists.items) |l| for (l.ns) |n| {
            const g = groups.getPtr(n) orelse continue;
            const p = Pick.of(g.items, l.sigil) orelse {
                try hard.put(a, n, {});
                continue;
            };
            if (p[1] == .none) try hard.put(a, n, {});
        };
        // The scenes' `fx::Rocket(actor, x, y, z)`: the exe's rocket is the rocket launcher's
        // (1024, fx/launch.zig sceneRocket), named (its 5th argument).
        if (groups.getPtr(1024)) |g| if (Pick.of(g.items, .weapon)) |p| for (self.modules.items) |m| for (m.entities) |e| if (std.mem.eql(u8, e.kind, "scene")) for (e.rows) |r| {
            if (r.kind != .call or !std.mem.eql(u8, r.kind.call.text, "fx::Rocket") or r.kind.call.args.len != 4) continue;
            const v = try a.create(ir.Expr);
            v.* = .{ .line = r.line, .sigil = p[1], .kind = .{ .lit = .{ .string = p[0] } } };
            const args = try std.mem.concat(a, *const ir.Expr, &.{ r.kind.call.args, &.{v} });
            @constCast(r).kind.call.args = args;
        };
        try self.partyOrder();
        var ids: std.ArrayList(IdOf) = .empty;
        for (groups.keys(), groups.values()) |n, *g| {
            if (hard.contains(n)) {
                self.report.ids_kept += g.items.len;
                continue;
            }
            for (g.items, 0..) |b, i| {
                var fs: std.ArrayList(ir.Named) = .empty;
                for (b.e.fields) |f| if (!std.mem.eql(u8, f.name, "classic_id")) try fs.append(a, f);
                // The others are the main one's (an archetype, else the first level object).
                if (i > 0) {
                    const v = try a.create(ir.Expr);
                    const main = g.items[0].path;
                    // A level object as main: `"<level>/<name>"` (loaders/ogs.zig byLevelKey).
                    v.* = .{ .line = b.e.line, .kind = if (g.items[0].child) .{ .lit = .{ .string = main } } else .{ .word = main } };
                    try fs.insert(a, 0, .{ .name = "same_as", .value = v });
                }
                b.e.fields = fs.items;
                try ids.append(a, .{ .path = b.path, .id = n });
            }
        }
        // The rows' and fields' numbers of dropped groups → their block of the right kind.
        for (soft.items) |r| {
            if (hard.contains(r.n)) continue;
            const g = groups.getPtr(r.n) orelse continue;
            // A text row: the main block's path as a string (loaders/ogs.zig textId).
            const to = if (r.text) .{ g.items[0].path, ir.Sigil.none } else Pick.of(g.items, r.sigil) orelse continue;
            const v = try a.create(ir.Expr);
            v.* = .{ .line = r.at.value.line, .sigil = to[1], .kind = .{ .lit = .{ .string = to[0] } } };
            r.at.value = v;
            self.report.ids_refs += 1;
        }
        // The lists: each place of a dropped number its archetype, the others their numbers
        // (the list's shape kept: `pairs = list(list(…, …), …)`).
        for (lists.items) |l| {
            var any = false;
            const items = try a.alloc(*const ir.Expr, l.ns.len);
            for (l.ns, items) |n, *it| {
                const x = try a.create(ir.Expr);
                const g = groups.getPtr(n);
                const p = if (g != null and !hard.contains(n)) Pick.of(g.?.items, l.sigil) else null;
                if (p) |pp| {
                    x.* = .{ .line = l.at.value.line, .sigil = pp[1], .kind = .{ .lit = .{ .string = pp[0] } } };
                    any = true;
                } else x.* = .{ .line = l.at.value.line, .kind = .{ .lit = .{ .int = n } } };
                it.* = x;
            }
            if (!any) continue;
            var k: usize = 0;
            l.at.value = try reshape(a, l.at.value, items, &k);
            self.report.ids_refs += 1;
        }
        // A rules row whose reference names a number of no block, the code setting none: a
        // Classic weapon or fighter the game never makes, dropped (the reader would give
        // that number to no one).
        for (self.modules.items) |*m| {
            var keep: std.ArrayList(*const ir.Expr) = .empty;
            for (m.rows) |r| if (try actionRow(a, r)) |x| {
                try keep.append(a, x);
            } else if (try scoringRow(a, r)) |x| {
                try keep.append(a, x);
            } else if (try fighterClassRow(a, r)) |x| {
                try keep.append(a, x);
            } else if (classRow(r)) {
                // A weapon class is its name (loaders/rules_text.zig numberRows numbers it).
                var c = r.kind.call;
                var ns: std.ArrayList(ir.Named) = .empty;
                for (c.named) |n| if (!std.mem.eql(u8, n.name, "classic_id")) try ns.append(a, n);
                c.named = ns.items;
                const x = try a.create(ir.Expr);
                x.* = r.*;
                x.kind = .{ .call = c };
                try keep.append(a, x);
            } else if (deadRow(r, &groups, &hard, &coded)) {
                self.report.ids_dead += 1;
            } else if (deadText(r, &groups, &hard, &coded)) |t| {
                // For the checks: the Classic text it was (`!<file>=<number>`).
                try ids.append(a, .{ .path = t.file, .id = t.n });
                self.report.ids_dead += 1;
            } else try keep.append(a, r);
            m.rows = keep.items;
        }
        self.report.ids = ids.items;
    }

    /// The rules rows keyed by one top-level block (rules_text.block_rows: an enemy's
    /// KillIcon, a weapon's WeaponFx, a fighter's MonsterAttack rows…) moved into that
    /// block's field: a simple value, a record, a list of the records of several rows.
    /// A row of other fields than such a field takes, or keyed otherwise, stays a row.
    /// A battle's Classic rows by its levelMode as OpenGorky has them: MidDialog its Logic's
    /// OnEnemyTurnOver(turn) (`scene::Dialog` at that turn; combat/turns.zig calls it where
    /// the row was read); Transform's `into` the morph's block (`~c"03ch_lilith_m"`, not its
    /// `.mtm`), its `anim` gone when it is that block's `mesh` (world/spawn.zig morphActor
    /// takes it). A battle whose Logic has an OnEnemyTurnOver of its own keeps its rows.
    fn battleRows(self: *Conv) !void {
        const a = self.a;
        // Battles by mode: their module's Logic, when it has no OnEnemyTurnOver.
        const Logic = struct { m: *ir.Module, ci: usize, code: std.ArrayList(u8) = .empty };
        var by_mode: std.AutoArrayHashMapUnmanaged(i32, Logic) = .empty;
        var morphs: std.StringHashMapUnmanaged(*const ir.Entity) = .empty;
        for (self.modules.items) |*bm| for (bm.entities) |*e| {
            if (std.mem.eql(u8, e.kind, "fighter")) try morphs.put(a, e.name, e);
            if (!std.mem.eql(u8, e.kind, "battle")) continue;
            const mode = schema.int(namedIn(e.fields, "mode") orelse continue) orelse continue;
            // Its code's module (the block stands at the root).
            const p = try std.fmt.allocPrint(a, "battles::{s}", .{try ogsify.ident(a, e.name)});
            const m = for (self.modules.items) |*x| {
                if (std.mem.eql(u8, x.path, p)) break x;
            } else continue;
            for (m.components, 0..) |c, ci| if (std.mem.eql(u8, c.name, "Logic")) {
                const own = for (c.methods) |f| {
                    if (std.mem.eql(u8, f.name, "OnEnemyTurnOver")) break true;
                } else false;
                if (!own) try by_mode.put(a, mode, .{ .m = m, .ci = ci });
            };
        };
        for (self.modules.items) |*m| {
            var keep: std.ArrayList(*const ir.Expr) = .empty;
            for (m.rows) |r| {
                const c = if (r.kind == .call) r.kind.call else {
                    try keep.append(a, r);
                    continue;
                };
                if (std.mem.eql(u8, c.text, "Transform")) {
                    try keep.append(a, try transformRow(a, r, &morphs));
                    continue;
                }
                const mv = if (std.mem.eql(u8, c.text, "MidDialog")) namedArg(c, "mode") else null;
                const mode = if (mv) |v| schema.int(v) else null;
                const lg = if (mode) |n| by_mode.getPtr(n) else null;
                const turn = if (namedArg(c, "turn")) |v| schema.int(v) orelse 0 else 0;
                const dlg = if (namedArg(c, "dialog")) |v| schema.text(v) orelse "" else "";
                const file = if (namedArg(c, "dialog_file")) |v| schema.text(v) orelse "" else "";
                const l = lg orelse {
                    try keep.append(a, r);
                    continue;
                };
                const stem = if (std.ascii.endsWithIgnoreCase(file, ".dlg")) file[0 .. file.len - 4] else file;
                _ = dlg;
                try l.code.print(a, "if (turn == {d}) {{ scene::Dialog(~d\"{s}\"); }}\n", .{ turn, stem });
            }
            m.rows = keep.items;
        }
        for (by_mode.values()) |*l| if (l.code.items.len > 0) {
            const src = try std.fmt.allocPrint(a, "component Logic for battle {{ fn OnEnemyTurnOver(turn) {{ {s} }} }}", .{l.code.items});
            var d: parser.Diagnostic = .{};
            const u = try parser.parse(a, src, "logic.ogs", &d);
            const f = u.modules[0].components[0].methods[0];
            const old = l.m.components[l.ci];
            const c = try a.create(ir.Component);
            c.* = old.*;
            c.methods = try std.mem.concat(a, *const ir.Fn, &.{ old.methods, &.{f} });
            const cs = try a.dupe(*const ir.Component, l.m.components);
            cs[l.ci] = c;
            l.m.components = cs;
        };
    }

    /// Names written as lists of words, as OpenGorky reads them (codec): a WeaponClass's
    /// `effect = "sleep"` as `effects = [sleep]`, a Resist's `resist = "attract gas"` as
    /// `resist = [attract, gas]`.
    fn nameLists(self: *Conv) !void {
        const a = self.a;
        for (self.modules.items) |*m| {
            const rows = try a.dupe(*const ir.Expr, m.rows);
            for (rows) |*r| {
                if (r.*.kind != .call) continue;
                const c = r.*.kind.call;
                const which: ?struct { []const u8, []const u8 } = if (std.mem.eql(u8, c.text, "WeaponClass")) .{ "effect", "effects" } else if (std.mem.eql(u8, c.text, "Resist")) .{ "resist", "resist" } else null;
                const wh = which orelse continue;
                const ns = try a.dupe(ir.Named, c.named);
                var changed = false;
                for (ns) |*n| {
                    if (!std.mem.eql(u8, n.name, wh[0])) continue;
                    const sv = schema.text(n.value) orelse continue;
                    var items: std.ArrayList(*const ir.Expr) = .empty;
                    var it = std.mem.tokenizeAny(u8, sv, ", ;\t");
                    while (it.next()) |word| {
                        const x = try a.create(ir.Expr);
                        x.* = .{ .line = n.value.line, .kind = .{ .word = word } };
                        try items.append(a, x);
                    }
                    const l = try a.create(ir.Expr);
                    l.* = .{ .line = n.value.line, .kind = .{ .list = items.items } };
                    n.* = .{ .name = wh[1], .value = l };
                    changed = true;
                }
                if (!changed) continue;
                const x = try a.create(ir.Expr);
                x.* = .{ .line = r.*.line, .kind = .{ .call = .{ .id = c.id, .text = c.text, .args = c.args, .named = ns } } };
                r.* = x;
            }
            m.rows = rows;
        }
    }

    /// The AiProfile rows as `ai_profile` blocks of module `ai` (rules_text Profiles reads them
    /// back), each row's tile scoring (its `scoring`'s AiScoring row) its own fields
    /// (`scoringFields`; OG Script has no AiScoring, no `generic_ai`): the one of no fighter
    /// and no class `generic` (the game's `ai_profile`), the
    /// fields every other row has alike `monster : generic` (two rows or more), each other
    /// row a block over them of only what differs (by its `scoring`'s name, else its
    /// fighter's or class's; rows alike share one), named by its fighters' `ai_profile` (a
    /// class's: each fighter of that `battle_class`). A row by a fighter that already has
    /// its class's stays a row (its `ai` over it), and so does a row naming no block.
    fn aiProfiles(self: *Conv) !void {
        const a = self.a;
        var tops: std.StringHashMapUnmanaged(*ir.Entity) = .empty;
        var game: ?*ir.Entity = null;
        for (self.modules.items) |*m| for (@constCast(m.entities)) |*e| {
            if (std.mem.eql(u8, e.kind, "game")) game = e;
            if (std.mem.eql(u8, e.kind, "fighter") or std.mem.eql(u8, e.kind, "hero")) try tops.put(a, try std.fmt.allocPrint(a, "{s}{s}{s}", .{ m.path, if (m.path.len > 0) "::" else "", e.name }), e);
        };
        const g = game orelse return;
        // The AiScoring rows by their scoring's name (lower case): each profile's own fields.
        var scorings: std.StringHashMapUnmanaged(ir.Call) = .empty;
        for (self.modules.items) |m| for (m.rows) |r| if (r.kind == .call and std.mem.eql(u8, r.kind.call.text, "AiScoring")) {
            const ev = schema.text(namedArg(r.kind.call, "eval") orelse continue) orelse continue;
            try scorings.put(a, try std.ascii.allocLowerString(a, ev), r.kind.call);
        };
        const Prof = struct { r: *const ir.Expr, fields: []const ir.Named, targets: []const *ir.Entity, label: []const u8 };
        var default: ?Prof = null;
        var profs: std.ArrayList(Prof) = .empty;
        var has_profile: std.AutoHashMapUnmanaged(*ir.Entity, void) = .empty;
        // Class rows first: a fighter's own row over its class's stays a row.
        for ([_]bool{ true, false }) |class_pass| for (self.modules.items) |m| for (m.rows) |r| {
            if (r.kind != .call or !std.mem.eql(u8, r.kind.call.text, rules.AiProfile.call)) continue;
            const c = r.kind.call;
            var fs: std.ArrayList(ir.Named) = .empty;
            for (c.named) |n| {
                const skip = for ([_][]const u8{ "fighter", "class_name", "class", "scoring", "generic_ai" }) |x| {
                    if (std.mem.eql(u8, n.name, x)) break true;
                } else false;
                if (!skip) try fs.append(a, n);
            }
            // shortcut: `generic_ai` (a Classic generic fighter's `ai` picking this row) goes:
            // the game has no generic fighter; a mod's one plays class 0's profile then.
            if (namedArg(c, "scoring")) |sv| if (schema.text(sv)) |ev| if (scorings.get(try std.ascii.allocLowerString(a, ev))) |sc|
                try scoringFields(a, sc, &fs);
            const fv = namedArg(c, "fighter");
            const cv = namedArg(c, "class_name");
            if (namedArg(c, "class")) |v| if ((schema.int(v) orelse 1) != 0) continue;
            if (fv == null and cv == null) {
                if (class_pass and default == null) default = .{ .r = r, .fields = fs.items, .targets = &.{}, .label = "generic" };
                continue;
            }
            if ((cv != null) != class_pass) continue;
            var ts: std.ArrayList(*ir.Entity) = .empty;
            var label: []const u8 = "";
            if (cv) |v| {
                label = schema.text(v) orelse continue;
                var it = tops.valueIterator();
                while (it.next()) |e| if (namedIn(e.*.fields, "battle_class")) |bc| if (bc.kind == .word and std.ascii.eqlIgnoreCase(bc.kind.word, label)) try ts.append(a, e.*);
            } else {
                const path = schema.text(fv.?) orelse continue;
                const e = tops.get(path) orelse continue;
                if (has_profile.contains(e)) continue;
                try ts.append(a, e);
                label = lastPart(path);
            }
            if (ts.items.len == 0) continue;
            for (ts.items) |e| try has_profile.put(a, e, {});
            try profs.append(a, .{ .r = r, .fields = fs.items, .targets = ts.items, .label = label });
        };
        const d = default orelse return;
        // `monster`: what every other row has alike and the default has otherwise.
        var monster: std.ArrayList(ir.Named) = .empty;
        if (profs.items.len >= 2) for (profs.items[0].fields) |f| {
            const alike = for (profs.items[1..]) |p| {
                const v = namedIn(p.fields, f.name) orelse break false;
                if (!try sameText(a, v, f.value)) break false;
            } else true;
            if (!alike) continue;
            if (namedIn(d.fields, f.name)) |dv| if (try sameText(a, dv, f.value)) continue;
            try monster.append(a, f);
        };
        const over = if (monster.items.len > 0) "monster" else "generic";
        var blocks: std.ArrayList(ir.Entity) = .empty;
        try blocks.append(a, .{ .kind = "ai_profile", .name = "generic", .fields = d.fields, .attach = &.{}, .line = 0 });
        if (monster.items.len > 0) try blocks.append(a, .{ .kind = "ai_profile", .name = "monster", .base = "generic", .fields = monster.items, .attach = &.{}, .line = 0 });
        var drop: std.AutoHashMapUnmanaged(*const ir.Expr, void) = .empty;
        try drop.put(a, d.r, {});
        // Rows alike are one block: its fields (what differs from `monster` over
        // `generic`), its text, its fighters.
        const PGroup = struct { fields: []const ir.Named, text: []const u8, scoring: []const u8, label: []const u8, targets: std.ArrayList(*ir.Entity) = .empty };
        var groups: std.ArrayList(PGroup) = .empty;
        for (profs.items) |p| {
            var fs: std.ArrayList(ir.Named) = .empty;
            var tw: std.Io.Writer.Allocating = .init(a);
            for (p.fields) |f| {
                const eff = namedIn(monster.items, f.name) orelse namedIn(d.fields, f.name);
                if (eff) |v| if (try sameText(a, v, f.value)) continue;
                try fs.append(a, f);
                try tw.writer.print("{s}=", .{f.name});
                try print_ogs.expression(&tw.writer, f.value);
                try tw.writer.writeAll(";");
            }
            const gi = for (groups.items, 0..) |x, k| {
                if (std.mem.eql(u8, x.text, tw.written())) break k;
            } else blk: {
                const sc = if (namedArg(p.r.kind.call, "scoring")) |v| schema.text(v) orelse "" else "";
                try groups.append(a, .{ .fields = fs.items, .text = tw.written(), .scoring = sc, .label = p.label });
                break :blk groups.items.len - 1;
            };
            try groups.items[gi].targets.appendSlice(a, p.targets);
            try drop.put(a, p.r, {});
        }
        // Its name: its scoring's when that is all it changes or no other block has that
        // scoring, else its fighter's or class's.
        for (groups.items) |*gr| {
            // Nothing of its own (Classic's scoring A is the generic one for a monster): its
            // fighters take the profile it would stand on.
            if (gr.fields.len == 0) {
                const bref = try a.create(ir.Expr);
                bref.* = .{ .line = 0, .kind = .{ .word = try std.fmt.allocPrint(a, "ai::{s}", .{over}) } };
                for (gr.targets.items) |e| e.fields = try std.mem.concat(a, ir.Named, &.{ e.fields, &.{.{ .name = "ai_profile", .value = bref }} });
                continue;
            }
            const shared = for (groups.items) |x| {
                if (&x != gr and !std.mem.eql(u8, x.text, gr.text) and std.mem.eql(u8, x.scoring, gr.scoring)) break true;
            } else false;
            const only_scoring = for (gr.fields) |f| {
                if (!isScoringField(f.name)) break false;
            } else true;
            var name = if (gr.scoring.len > 0 and (!shared or only_scoring)) gr.scoring else gr.label;
            for (blocks.items) |b| if (std.mem.eql(u8, b.name, name)) {
                name = try std.fmt.allocPrint(a, "{s}_{s}", .{ name, gr.label });
            };
            try blocks.append(a, .{ .kind = "ai_profile", .name = name, .base = over, .fields = gr.fields, .attach = &.{}, .line = 0 });
            const pref = try a.create(ir.Expr);
            pref.* = .{ .line = 0, .kind = .{ .word = try std.fmt.allocPrint(a, "ai::{s}", .{name}) } };
            for (gr.targets.items) |e| e.fields = try std.mem.concat(a, ir.Named, &.{ e.fields, &.{.{ .name = "ai_profile", .value = pref }} });
        }
        // The AiScoring rows: their profiles' own fields now.
        for (self.modules.items) |m| for (m.rows) |r| if (r.kind == .call and std.mem.eql(u8, r.kind.call.text, "AiScoring")) try drop.put(a, r, {});
        const gref = try a.create(ir.Expr);
        gref.* = .{ .line = g.line, .kind = .{ .word = "ai::generic" } };
        g.fields = try std.mem.concat(a, ir.Named, &.{ g.fields, &.{.{ .name = "ai_profile", .value = gref }} });
        for (self.modules.items) |*m| {
            var keep: std.ArrayList(*const ir.Expr) = .empty;
            for (m.rows) |r| if (!drop.contains(r)) try keep.append(a, r);
            m.rows = keep.items;
        }
        try self.modules.append(a, .{ .path = "ai", .uses = &.{}, .fns = &.{}, .components = &.{}, .entities = blocks.items, .rows = &.{} });
    }

    /// The ExpLevel, Value and Setting rows into their places (rules_text reads them back):
    /// the game block's `exp_levels = [0, 220, …]` (levels 0… in order; else they stay rows),
    /// `hero_attack`, the formulas' numbers (`party_max = 6;`); an engine setting (only one
    /// other than the engine's, rowsToBlocks) the record of what it tunes
    /// (rules/adjust_owners.zig: `PopupColors(hp_loss = […])` in ui.ogs, `blood = Blood(…)`).
    fn settingsBlock(self: *Conv) !void {
        const a = self.a;
        var game: ?*ir.Entity = null;
        for (self.modules.items) |*m| for (@constCast(m.entities)) |*e| if (std.mem.eql(u8, e.kind, "game")) {
            game = e;
        };
        const g = game orelse return;
        var exp: std.ArrayList(*const ir.Expr) = .empty;
        var fs: std.ArrayList(ir.Named) = .empty;
        var levels_ok = true;
        var drop: std.AutoHashMapUnmanaged(*const ir.Expr, void) = .empty;
        var exp_rows: std.ArrayList(*const ir.Expr) = .empty;
        for (self.modules.items) |m| for (m.rows) |r| {
            if (r.kind != .call) continue;
            const c = r.kind.call;
            if (std.mem.eql(u8, c.text, "ExpLevel")) {
                const lv = if (namedArg(c, "level")) |v| schema.int(v) else null;
                if (lv != @as(?i32, @intCast(exp.items.len))) levels_ok = false;
                try exp.append(a, namedArg(c, "exp") orelse &zero_expr);
                try exp_rows.append(a, r);
                continue;
            }
            // The hero attack of every weapon with none of its own (no key).
            if (std.mem.eql(u8, c.text, "HeroAttack") and namedArg(c, "hero") == null) if (namedArg(c, "weapon")) |wv| if (schema.int(wv) == 0) {
                var ns: std.ArrayList(ir.Named) = .empty;
                for (c.named) |n| if (!std.mem.eql(u8, n.name, "weapon")) try ns.append(a, n);
                const x = try a.create(ir.Expr);
                x.* = .{ .line = r.line, .kind = .{ .call = .{ .id = c.id, .text = c.text, .args = &.{}, .named = ns.items } } };
                try fs.append(a, .{ .name = "hero_attack", .value = x });
                try drop.put(a, r, {});
                continue;
            };
            const is_value = std.mem.eql(u8, c.text, "Value");
            if (!is_value and !std.mem.eql(u8, c.text, "Setting")) continue;
            // A Value's name is a word (`name = idle_ticks`), a Setting's a string.
            const nv = namedArg(c, "name") orelse continue;
            const name = if (nv.kind == .word) nv.kind.word else schema.text(nv) orelse continue;
            if (!isIdent(name)) continue;
            const v: *const ir.Expr = if (is_value) namedArg(c, "value") orelse continue else if (namedArg(c, "int")) |x| x else if (namedArg(c, "float")) |x| blk: {
                // A float as one (`1.0`, not `1`): its kind is the setting's.
                const f = try a.create(ir.Expr);
                f.* = .{ .line = x.line, .kind = .{ .lit = .{ .float = schema.number(x) orelse continue } } };
                break :blk f;
            } else if (namedArg(c, "rgba")) |x| blk: {
                const items = switch (x.kind) {
                    .list => |l| l,
                    .call => |cc| cc.args,
                    else => continue,
                };
                const l = try a.create(ir.Expr);
                l.* = .{ .line = x.line, .kind = .{ .list = items } };
                break :blk l;
            } else continue;
            try fs.append(a, .{ .name = name, .value = v });
            try drop.put(a, r, {});
        };
        if (levels_ok and exp.items.len > 0) {
            const l = try a.create(ir.Expr);
            l.* = .{ .line = 0, .kind = .{ .list = exp.items } };
            try fs.insert(a, 0, .{ .name = "exp_levels", .value = l });
            for (exp_rows.items) |r| try drop.put(a, r, {});
        }
        // The game's rules (experience, the attack of no weapon's own, the formulas' numbers)
        // are the game block's; the engine's settings its own `settings` block.
        var rest: std.ArrayList(ir.Named) = .empty;
        var gfs: std.ArrayList(ir.Named) = .empty;
        try gfs.appendSlice(a, g.fields);
        for (fs.items) |f| {
            const of_game = std.mem.eql(u8, f.name, "exp_levels") or std.mem.eql(u8, f.name, "hero_attack") or std.meta.stringToEnum(@import("../rules.zig").Const, f.name) != null;
            try (if (of_game) &gfs else &rest).append(a, f);
        }
        // The engine's settings: each into the record of what it tunes (rules/adjust_owners.zig),
        // a ui row (`PopupColors(hp_loss = …)` in ui.ogs) or a game block field (`blood = Blood(…)`).
        const owners = @import("../rules.zig").adjust_owners;
        var records: std.StringArrayHashMapUnmanaged(std.ArrayList(ir.Named)) = .empty;
        for (rest.items) |f| {
            const o = owners.byName(f.name) orelse {
                try self.line("rules: setting {s} is the player's (no project's): left out", .{f.name});
                continue;
            };
            const g2 = try records.getOrPut(a, o.record);
            if (!g2.found_existing) g2.value_ptr.* = .empty;
            try g2.value_ptr.append(a, .{ .name = o.field, .value = f.value });
        }
        var ui_rows: std.ArrayList(*const ir.Expr) = .empty;
        for (records.keys(), records.values()) |rec, named| {
            const c = try a.create(ir.Expr);
            c.* = .{ .line = 0, .kind = .{ .call = .{ .id = 0, .text = rec, .args = &.{}, .named = named.items } } };
            const o = owners.of(rec, named.items[0].name).?;
            switch (o.owner) {
                .ui => try ui_rows.append(a, c),
                .game => try gfs.append(a, .{ .name = o.slot, .value = c }),
            }
        }
        g.fields = gfs.items;
        for (self.modules.items) |*m| {
            var keep: std.ArrayList(*const ir.Expr) = .empty;
            for (m.rows) |r| if (!drop.contains(r)) try keep.append(a, r);
            m.rows = keep.items;
        }
        if (ui_rows.items.len > 0) try self.modules.append(a, .{ .path = "", .uses = &.{}, .fns = &.{}, .components = &.{}, .entities = &.{}, .rows = ui_rows.items });
    }

    /// The Action rows as blocks (`action Open { label = "open"; on_exit = true; }`,
    /// actions.ogs; loaders/rules_text.zig actionRow reads them back): objects name them
    /// (`action = Open`), the build checks that (compose/og/build.zig).
    fn actionBlocks(self: *Conv) !void {
        try self.rowBlocks("Action", "action", "");
        try self.rowBlocks("Speaker", "speaker", "speakers");
        try self.districtMusic();
    }

    /// DistrictMusic(prefix = "03_museum_", track = "03_museum") as each level's own
    /// `music = "03_museum"` (the levels whose name contains the prefix, the first row that
    /// fits as the exe; a level with one already keeps it).
    fn districtMusic(self: *Conv) !void {
        const a = self.a;
        for (self.modules.items) |*m| {
            var keep: std.ArrayList(*const ir.Expr) = .empty;
            for (m.rows) |r| {
                const c = if (r.kind == .call and std.mem.eql(u8, r.kind.call.text, "DistrictMusic")) r.kind.call else {
                    try keep.append(a, r);
                    continue;
                };
                const prefix = if (namedArg(c, "prefix")) |v| schema.text(v) orelse "" else "";
                const track = namedArg(c, "track") orelse {
                    try keep.append(a, r);
                    continue;
                };
                if (prefix.len == 0) {
                    try keep.append(a, r);
                    continue;
                }
                for (self.modules.items) |*lm| for (@constCast(lm.entities)) |*lv| {
                    if (!isLevelKind(lv.kind) or std.mem.indexOf(u8, lv.name, prefix) == null or namedIn(lv.fields, "music") != null) continue;
                    lv.fields = try std.mem.concat(a, ir.Named, &.{ lv.fields, &.{.{ .name = "music", .value = track }} });
                };
            }
            m.rows = keep.items;
        }
    }

    /// The `call` rows keyed by `name` as `kind` blocks of module `path` (`action Open { … }`,
    /// `speaker HQ { portrait = … }`; loaders/rules_text.zig named_rows reads them back).
    fn rowBlocks(self: *Conv, call: []const u8, kind: []const u8, path: []const u8) !void {
        const a = self.a;
        var blocks: std.ArrayList(ir.Entity) = .empty;
        for (self.modules.items) |*m| {
            var keep: std.ArrayList(*const ir.Expr) = .empty;
            for (m.rows) |r| {
                const c = if (r.kind == .call and std.mem.eql(u8, r.kind.call.text, call)) r.kind.call else {
                    try keep.append(a, r);
                    continue;
                };
                const name = if (namedArg(c, "name")) |v| schema.text(v) orelse "" else "";
                if (name.len == 0 or c.args.len > 0) {
                    try keep.append(a, r);
                    continue;
                }
                var fs: std.ArrayList(ir.Named) = .empty;
                for (c.named) |n| if (!std.mem.eql(u8, n.name, "name")) try fs.append(a, n);
                try blocks.append(a, .{ .kind = kind, .name = name, .fields = fs.items, .attach = &.{}, .line = r.line });
            }
            m.rows = keep.items;
        }
        if (blocks.items.len == 0) return;
        try self.modules.append(a, .{ .path = path, .uses = &.{}, .fns = &.{}, .components = &.{}, .entities = blocks.items, .rows = &.{} });
    }

    /// A row keyed by a number the code sets (`KillIcon(fighter = 141, icon = …)`: NATO's
    /// captain, `classic_id = 141;` in its OnCreate): the field of each object whose own
    /// component sets it (`report_icon = "nato_capitan_rap"` on `nato1`; the rules key
    /// it by the object's name, loaders/rules_text.zig block_rows `child`).
    fn codedIdRows(self: *Conv) !void {
        const a = self.a;
        for (self.modules.items) |*m| {
            var keep: std.ArrayList(*const ir.Expr) = .empty;
            for (m.rows) |r| {
                const c = if (r.kind == .call and std.mem.eql(u8, r.kind.call.text, "KillIcon")) r.kind.call else {
                    try keep.append(a, r);
                    continue;
                };
                const n = if (namedArg(c, "fighter")) |v| schema.int(v) else null;
                const icon = namedArg(c, "icon");
                if (n == null or icon == null) {
                    try keep.append(a, r);
                    continue;
                }
                // The components setting it at their top (OnCreate's `classic_id = N;`).
                var comps: std.ArrayList([]const u8) = .empty;
                for (self.modules.items) |cm| for (cm.components) |comp| for (comp.methods) |f| for (f.body) |st| if (st.kind == .assign) {
                    const as = st.kind.assign;
                    const name = switch (as.target) {
                        .member => |mb| if (mb.obj.kind == .host) mb.text else "",
                        .field => |fl| fl.text,
                        else => "",
                    };
                    if (std.mem.eql(u8, name, "classic_id") and schema.int(as.value) == n.?)
                        try comps.append(a, if (cm.path.len > 0) try std.fmt.allocPrint(a, "{s}::{s}", .{ cm.path, comp.name }) else comp.name);
                };
                var every: std.ArrayList(*ir.Entity) = .empty;
                for (self.modules.items) |*bm| try allBlocks(a, @constCast(bm.entities), &every);
                var placed: usize = 0;
                for (every.items) |e| for (e.attach) |at| for (comps.items) |cp| if (std.mem.eql(u8, at.component, cp) and namedIn(e.fields, "report_icon") == null) {
                    e.fields = try std.mem.concat(a, ir.Named, &.{ e.fields, &.{.{ .name = "report_icon", .value = icon.? }} });
                    placed += 1;
                };
                if (placed == 0) try keep.append(a, r);
            }
            m.rows = keep.items;
        }
    }

    /// The Campaign row as the game block's fields (loaders/rules_text.zig gameRows reads
    /// them back): `start = ~l"01_port"`, `leader = @Sullivan`, `intro = ["introkon.avi"]`,
    /// the shell's names; `party` (Classic's .hro list) and `panel_first` (the party in
    /// `party_order`'s order) are the game block's lists already.
    fn campaignToGame(self: *Conv) !void {
        const a = self.a;
        var game: ?*ir.Entity = null;
        for (self.modules.items) |*m| for (@constCast(m.entities)) |*e| if (game == null and std.mem.eql(u8, e.kind, "game")) {
            game = e;
        };
        const g = game orelse return;
        // The game's videos by name without extension, lower case (null: no avi/ folder).
        var videos: ?std.StringHashMapUnmanaged(void) = null;
        if (self.dat.openDir(self.io, "../avi", .{ .iterate = true })) |d0| {
            var d = d0;
            defer d.close(self.io);
            var set: std.StringHashMapUnmanaged(void) = .empty;
            var dit = d.iterate();
            while (try dit.next(self.io)) |e| if (e.kind == .file) try set.put(a, try std.ascii.allocLowerString(a, stemOf(e.name)), {});
            videos = set;
        } else |_| {}
        // The videos' places (ExeVideo) by name, the exe's music (ExeMusic): into the game block.
        var placed: std.StringHashMapUnmanaged(ir.Call) = .empty;
        var exe_music: ?ir.Call = null;
        for (self.modules.items) |m| for (m.rows) |r| if (r.kind == .call) {
            const c = r.kind.call;
            if (std.mem.eql(u8, c.text, "ExeMusic")) exe_music = c;
            if (std.mem.eql(u8, c.text, "ExeVideo")) if (namedArg(c, "name")) |nv| if (schema.text(nv)) |t| try placed.put(a, try std.ascii.allocLowerString(a, t), c);
        };
        // The campaign's videos (their places go with them, a missing one's too).
        var campaign_videos: std.StringHashMapUnmanaged(void) = .empty;
        var music: std.ArrayList(ir.Named) = .empty;
        for (self.modules.items) |*m| {
            var keep: std.ArrayList(*const ir.Expr) = .empty;
            for (m.rows) |r| {
                if (r.kind != .call or !std.mem.eql(u8, r.kind.call.text, "Campaign")) {
                    try keep.append(a, r);
                    continue;
                }
                // The start first, then the party and the rest of the block.
                var fs: std.ArrayList(ir.Named) = .empty;
                for (r.kind.call.named) |n| {
                    const t = schema.text(n.value) orelse "";
                    const v = try a.create(ir.Expr);
                    v.* = .{ .line = r.line, .kind = .{ .lit = .{ .string = t } } };
                    const name: []const u8 = if (std.mem.eql(u8, n.name, "level")) blk: {
                        v.sigil = .level;
                        break :blk "start";
                    } else if (std.mem.eql(u8, n.name, "leader")) blk: {
                        v.kind = .{ .ref = t };
                        break :blk "leader";
                    } else if (std.mem.eql(u8, n.name, "scene")) blk: {
                        if (t.len == 0) continue;
                        v.sigil = .scene;
                        break :blk "start_scene";
                    } else if (std.mem.eql(u8, n.name, "area")) blk: {
                        if (t.len == 0) continue;
                        break :blk "start_area";
                    } else if (std.mem.eql(u8, n.name, "point")) {
                        if ((schema.int(n.value) orelse 0) != 0) try fs.append(a, .{ .name = "start_point", .value = n.value });
                        continue;
                    } else if (std.mem.eql(u8, n.name, "intro") or std.mem.eql(u8, n.name, "startup")) blk: {
                        var items: std.ArrayList(*const ir.Expr) = .empty;
                        var it = std.mem.tokenizeAny(u8, t, " ,");
                        while (it.next()) |x| {
                            try campaign_videos.put(a, try std.ascii.allocLowerString(a, x), {});
                            // The exe plays whichever of its list the game has (0x40fd06): the
                            // ones its avi/ folder has (`logo.avi` as `logo.asf` too).
                            if (videos) |vs| if (!vs.contains(try std.ascii.allocLowerString(a, stemOf(x)))) {
                                try self.line("rules: Campaign {s}: no video {s} in the game, left out", .{ n.name, x });
                                continue;
                            };
                            const e = try a.create(ir.Expr);
                            e.* = .{ .line = r.line, .kind = .{ .lit = .{ .string = x } } };
                            // Its place: `Video(name = "intro.avi", y = 60, double = true)`.
                            if (placed.get(try std.ascii.allocLowerString(a, x))) |pc| {
                                var vn: std.ArrayList(ir.Named) = .empty;
                                try vn.append(a, .{ .name = "name", .value = e });
                                for (pc.named) |pn| {
                                    if (std.mem.eql(u8, pn.name, "name") or std.mem.eql(u8, pn.name, "note")) continue;
                                    const off = if (pn.value.kind == .lit) switch (pn.value.kind.lit) {
                                        .int => |iv| iv == 0,
                                        .bool => |bv| !bv,
                                        else => false,
                                    } else false;
                                    if (!off) try vn.append(a, pn);
                                }
                                const ve = try a.create(ir.Expr);
                                ve.* = .{ .line = r.line, .kind = .{ .call = .{ .id = 0, .text = "Video", .args = &.{}, .named = vn.items } } };
                                try items.append(a, ve);
                                continue;
                            }
                            try items.append(a, e);
                        }
                        if (items.items.len == 0) continue;
                        v.kind = .{ .list = items.items };
                        break :blk n.name;
                    } else if (std.mem.eql(u8, n.name, "party")) {
                        if (t.len > 0) try self.line("rules: Campaign party \"{s}\": the game block's party lists the heroes, dropped", .{t});
                        continue;
                    } else if (std.mem.eql(u8, n.name, "panel_first")) {
                        continue;
                    } else if (std.mem.eql(u8, n.name, "menu_music") or std.mem.eql(u8, n.name, "credits_music")) {
                        // The music record's (`music = Music(menu = "menu", credits = "credits", …)`).
                        if (t.len > 0) try music.append(a, .{ .name = if (n.name[0] == 'm') "menu" else "credits", .value = v });
                        continue;
                    } else blk: {
                        if (t.len == 0 or std.mem.eql(u8, n.name, "note")) continue;
                        break :blk n.name;
                    };
                    try fs.append(a, .{ .name = name, .value = v });
                }
                // The exe's music beside the menu's and credits': one record.
                if (exe_music) |em| for (em.named) |mn| {
                    if (std.mem.eql(u8, mn.name, "note")) continue;
                    const mt = schema.text(mn.value) orelse "";
                    if (mt.len == 0) continue;
                    // Several tracks (`battle = "battle battle2"`) as a list.
                    if (std.mem.indexOfScalar(u8, mt, ' ') != null) {
                        var parts: std.ArrayList(*const ir.Expr) = .empty;
                        var pit = std.mem.tokenizeScalar(u8, mt, ' ');
                        while (pit.next()) |pt| {
                            const pe = try a.create(ir.Expr);
                            pe.* = .{ .line = r.line, .kind = .{ .lit = .{ .string = pt } } };
                            try parts.append(a, pe);
                        }
                        const le = try a.create(ir.Expr);
                        le.* = .{ .line = r.line, .kind = .{ .list = parts.items } };
                        try music.append(a, .{ .name = mn.name, .value = le });
                    } else try music.append(a, mn);
                };
                if (music.items.len > 0) {
                    const me = try a.create(ir.Expr);
                    me.* = .{ .line = r.line, .kind = .{ .call = .{ .id = 0, .text = "Music", .args = &.{}, .named = music.items } } };
                    try fs.append(a, .{ .name = "music", .value = me });
                }
                try fs.appendSlice(a, g.fields);
                g.fields = fs.items;
            }
            m.rows = keep.items;
        }
        // Their rows are the game block's now; so are the animations the engine plays itself
        // and the weapon hold points (`anims = Anims(…)`, `holds = Holds(…)`). The exe's
        // animation slots (LookSlot) are Classic's only: OpenGorky keys animations by name.
        var moved: std.ArrayList(ir.Named) = .empty;
        for (self.modules.items) |*m| {
            var keep: std.ArrayList(*const ir.Expr) = .empty;
            for (m.rows) |r| {
                if (r.kind == .call) {
                    const c = r.kind.call;
                    if (std.mem.eql(u8, c.text, "LookSlot")) continue;
                    const record: ?[2][]const u8 = if (std.mem.eql(u8, c.text, core.ui.Anims.call)) .{ "anims", "Anims" } else if (std.mem.eql(u8, c.text, core.ui.Holds.call)) .{ "holds", "Holds" } else null;
                    if (record) |rec| {
                        const x = try a.create(ir.Expr);
                        x.* = .{ .line = r.line, .kind = .{ .call = .{ .id = 0, .text = rec[1], .args = &.{}, .named = c.named } } };
                        try moved.append(a, .{ .name = rec[0], .value = x });
                        continue;
                    }
                    if (std.mem.eql(u8, c.text, "ExeMusic") and music.items.len > 0) continue;
                    if (std.mem.eql(u8, c.text, "ExeVideo")) if (namedArg(c, "name")) |nv| if (schema.text(nv)) |t|
                        if (campaign_videos.contains(try std.ascii.allocLowerString(a, t))) continue;
                }
                try keep.append(a, r);
            }
            m.rows = keep.items;
        }
        if (moved.items.len > 0) g.fields = try std.mem.concat(a, ir.Named, &.{ g.fields, moved.items });
    }

    fn rowsToBlocks(self: *Conv) !void {
        const a = self.a;
        const rt = @import("../loaders.zig").rules_text;
        // The top-level blocks by their key (a path, a battle's name).
        // A key's blocks: a battle and its dialog share a name (`04__city_hotelentrance`).
        var blocks: std.StringHashMapUnmanaged(std.ArrayList(*ir.Entity)) = .empty;
        for (self.modules.items) |*m| for (@constCast(m.entities)) |*e| {
            const k = if (m.path.len == 0 or isLevelKind(e.kind)) e.name else try std.fmt.allocPrint(a, "{s}::{s}", .{ m.path, e.name });
            const g = try blocks.getOrPut(a, k);
            if (!g.found_existing) g.value_ptr.* = .empty;
            try g.value_ptr.append(a, e);
        };
        const Key = struct { e: *ir.Entity, br: usize };
        var gathered: std.AutoArrayHashMapUnmanaged(Key, std.ArrayList(*const ir.Expr)) = .empty;
        for (self.modules.items) |*m| {
            var keep: std.ArrayList(*const ir.Expr) = .empty;
            row: for (m.rows) |r| {
                if (r.kind != .call) {
                    try keep.append(a, r);
                    continue;
                }
                const c = r.kind.call;
                // `PostChain()`: the whole game's screen effects, none (the built-in table's
                // one empty row; no row is the same).
                if (std.mem.eql(u8, c.text, "PostChain") and c.named.len == 0 and c.args.len == 0) continue :row;
                // A setting no code reads, or at the engine's default: left out.
                if (std.mem.eql(u8, c.text, "Setting") and !settingNeeded(c)) {
                    self.report.settings_unread += 1;
                    continue :row;
                }
                for (rt.block_rows, 0..) |br, bi| {
                    if (!std.mem.eql(u8, c.text, br.call)) continue;
                    var targets: std.ArrayList(*ir.Entity) = .empty;
                    // A row keying itself (`StateEffect(effect = burn, …)`): the game block's.
                    const kv = if (br.key.len == 0) blk: {
                        for (self.modules.items) |*gm| for (@constCast(gm.entities)) |*ge| for (br.kinds) |kd| if (std.mem.eql(u8, ge.kind, kd)) {
                            if (targets.items.len == 0) try targets.append(a, ge);
                        };
                        if (targets.items.len == 0) continue;
                        break :blk null;
                    } else namedArg(c, br.key) orelse continue;
                    const by_number = kv != null and br.key_field.len > 0 and schema.int(kv.?) != null;
                    // A level's or battle's own object by its name (`fighter = "04mf_invisible1"`).
                    const by_object = kv != null and br.child and kv.?.sigil == .none and kv.?.kind == .lit and kv.?.kind.lit == .string;
                    if (kv) |k| if (!by_number and !by_object and (k.kind != .lit or k.kind.lit != .string or k.sigil != br.sigil)) continue;
                    // Its blocks: the one of the key, or (`key_field`: a weapon class's row)
                    // each of that field's value (`class = blaster`).
                    if (kv == null) {} else if (by_object) {
                        var every: std.ArrayList(*ir.Entity) = .empty;
                        for (self.modules.items) |*bm| for (@constCast(bm.entities)) |*lv| if (isLevelKind(lv.kind)) try allBlocks(a, @constCast(lv.children), &every);
                        for (every.items) |be| if (std.mem.eql(u8, be.name, kv.?.kind.lit.string)) try targets.append(a, be);
                        // One object of that name, or it stays a row.
                        if (targets.items.len != 1) targets.clearRetainingCapacity();
                    } else if (br.key_field.len > 0) {
                        const kv_ = kv.?;
                        // The module's blocks of that class; none: one inside a level or
                        // battle (rules_text nestedClassRows; a battle's own weapon).
                        var top: std.ArrayList(*ir.Entity) = .empty;
                        var every: std.ArrayList(*ir.Entity) = .empty;
                        for (self.modules.items) |*bm| {
                            for (@constCast(bm.entities)) |*be| try top.append(a, be);
                            try allBlocks(a, @constCast(bm.entities), &every);
                        }
                        for ([_][]const *ir.Entity{ top.items, every.items }) |set| if (targets.items.len == 0) for (set) |be| {
                            const fv = namedIn(be.fields, br.key_field) orelse continue;
                            if (by_number) {
                                if (schema.int(fv) == schema.int(kv_)) try targets.append(a, be);
                                continue;
                            }
                            const fw = if (fv.kind == .word) fv.kind.word else schema.text(fv) orelse continue;
                            if (std.mem.eql(u8, fw, kv_.kind.lit.string)) try targets.append(a, be);
                        };
                    } else if (blocks.get(kv.?.kind.lit.string)) |es| try targets.appendSlice(a, es.items);
                    var n_in: usize = 0;
                    for (targets.items) |e| {
                        const kind_ok = for (br.kinds) |kd| {
                            if (std.mem.eql(u8, kd, e.kind)) break true;
                        } else false;
                        if (!kind_ok) continue;
                        // A flag: the row is its key alone (`extra_wait = true`).
                        const v: *const ir.Expr = if (br.flag) blk: {
                            if (c.named.len != 1) continue;
                            const x = try a.create(ir.Expr);
                            x.* = .{ .line = r.line, .kind = .{ .lit = .{ .bool = true } } };
                            break :blk x;
                        } else if (br.arg.len > 0) blk: {
                            // A simple value: the row is its key and that one field only.
                            if (c.named.len != 2) continue;
                            break :blk namedArg(c, br.arg) orelse continue;
                        } else blk: {
                            var ns: std.ArrayList(ir.Named) = .empty;
                            for (c.named) |n| {
                                if (std.mem.eql(u8, n.name, br.key)) continue;
                                // `class = 0` (a row by fighter): the record's default.
                                if (std.mem.eql(u8, n.name, "class") and (schema.int(n.value) orelse 1) == 0) continue;
                                try ns.append(a, n);
                            }
                            const x = try a.create(ir.Expr);
                            x.* = .{ .line = r.line, .kind = .{ .call = .{ .id = 0, .text = c.text, .args = &.{}, .named = ns.items } } };
                            break :blk x;
                        };
                        const g = try gathered.getOrPut(a, .{ .e = e, .br = bi });
                        if (!g.found_existing) g.value_ptr.* = .empty;
                        // A simple value once (a second row of the key: kept a row).
                        if (br.arg.len > 0 and g.value_ptr.items.len > 0) continue;
                        try g.value_ptr.append(a, v);
                        n_in += 1;
                    }
                    if (n_in == 0) {
                        // A class's abilities no block of the class has (the exe's hero classes):
                        // they apply to no one.
                        if (br.key_field.len > 0 and targets.items.len == 0 and std.mem.eql(u8, c.text, "Abilities")) {
                            try self.line("rules: Abilities of class {s}: no fighter of that class, dropped", .{if (kv) |k| schema.text(k) orelse "?" else "?"});
                            continue :row;
                        }
                        continue;
                    }
                    self.report.rows_in_blocks += 1;
                    continue :row;
                }
                try keep.append(a, r);
            }
            m.rows = keep.items;
        }
        for (gathered.keys(), gathered.values()) |k, vs| {
            const value: *const ir.Expr = if (vs.items.len == 1) vs.items[0] else blk: {
                const x = try a.create(ir.Expr);
                x.* = .{ .line = vs.items[0].line, .kind = .{ .list = vs.items } };
                break :blk x;
            };
            k.e.fields = try std.mem.concat(a, ir.Named, &.{ k.e.fields, &.{.{ .name = rt.block_rows[k.br].field, .value = value }} });
        }
    }

    /// A block's own class code as `fn`s in the block (ir.Component.own; the parser makes
    /// that component back, attached first): its component of its name it attaches first
    /// (`attach c_nato();`, no params), of no field, for its kind's host (its traits after
    /// `is`), no
    /// other block attaching it. A module's blocks (not a location's or battle's: their
    /// blocks stand at the root, their code in the level's namespace).
    fn ownCode(self: *Conv) !void {
        const a = self.a;
        // How many blocks attach each component (by its path).
        var uses: std.StringHashMapUnmanaged(u32) = .empty;
        for (self.modules.items) |*m| {
            var every: std.ArrayList(*ir.Entity) = .empty;
            try allBlocks(a, @constCast(m.entities), &every);
            for (every.items) |e| for (e.attach) |x| {
                const p = if (std.mem.indexOf(u8, x.component, "::") != null) x.component else try std.fmt.allocPrint(a, "{s}::{s}", .{ m.path, x.component });
                const g = try uses.getOrPut(a, p);
                g.value_ptr.* = if (g.found_existing) g.value_ptr.* + 1 else 1;
            };
        }
        for (self.modules.items) |*m| {
            if (m.path.len == 0 or std.mem.startsWith(u8, m.path, "locations::") or std.mem.startsWith(u8, m.path, "battles::")) continue;
            var folded: std.StringHashMapUnmanaged(void) = .empty;
            var owns: std.ArrayList(*const ir.Component) = .empty;
            for (@constCast(m.entities)) |*e| {
                if (e.attach.len == 0 or e.attach[0].params.len > 0 or !std.mem.eql(u8, e.attach[0].component, e.name)) continue;
                if ((uses.get(try std.fmt.allocPrint(a, "{s}::{s}", .{ m.path, e.name })) orelse 0) != 1) continue;
                const c = for (m.components) |x| {
                    if (std.mem.eql(u8, x.name, e.name)) break x;
                } else continue;
                const host = if (std.mem.eql(u8, e.kind, "hero")) "fighter" else e.kind;
                // Its traits go with it (`weapon pistol is items::ItemClass { … }`).
                if (c.fields.len > 0 or c.hosts.len != 1 or !std.mem.eql(u8, c.hosts[0], host)) continue;
                const nc = try a.create(ir.Component);
                nc.* = c.*;
                nc.own = true;
                e.own = nc;
                e.attach = e.attach[1..];
                try folded.put(a, c.name, {});
                try owns.append(a, nc);
                self.report.own_code += 1;
            }
            // As the parser has them: the others, then the blocks' own in their order.
            var keep: std.ArrayList(*const ir.Component) = .empty;
            for (m.components) |c| if (!folded.contains(c.name)) try keep.append(a, c);
            try keep.appendSlice(a, owns.items);
            m.components = keep.items;
        }
    }

    /// The heroes' empty ammo packs (`item::New("bt_am_pistol", "items::pistolammo", "Bt",
    /// 0);`, the exe's ready pack of every kind) out of the code: the first pack a hero gets is
    /// the one the next merge into (inventory/item.zig mergeAmmo), an empty one shows nowhere
    /// (inventory/list.zig), a load makes the packs a hero lacks (game/save_apply.zig).
    /// A method left empty goes (when no trait's default stands under it).
    fn dropEmptyPacks(self: *Conv) !void {
        const a = self.a;
        var ammo: std.StringHashMapUnmanaged(void) = .empty;
        for (self.modules.items) |m| if (m.path.len > 0) for (m.entities) |e| if (std.mem.eql(u8, e.kind, "item")) if (namedIn(e.fields, "kind")) |k| {
            const is_ammo = (k.kind == .word and std.mem.eql(u8, k.kind.word, "ammo")) or (schema.int(k) orelse 0) == 10;
            if (is_ammo) try ammo.put(a, try std.fmt.allocPrint(a, "{s}::{s}", .{ m.path, e.name }), {});
        };
        for (self.modules.items) |*m| {
            const cs = try a.dupe(*const ir.Component, m.components);
            for (cs) |*c| {
                var changed = false;
                const ms = try a.dupe(*const ir.Fn, c.*.methods);
                for (ms) |*f| {
                    var body: std.ArrayList(ir.Stmt) = .empty;
                    for (f.*.body) |st| {
                        if (emptyPack(st, &ammo)) {
                            self.report.empty_packs += 1;
                            continue;
                        }
                        try body.append(a, st);
                    }
                    if (body.items.len == f.*.body.len) continue;
                    const nf = try a.create(ir.Fn);
                    nf.* = f.*.*;
                    nf.body = body.items;
                    f.* = nf;
                    changed = true;
                }
                if (!changed) continue;
                var kept: std.ArrayList(*const ir.Fn) = .empty;
                for (ms) |f| if (f.body.len > 0 or c.*.traits.len > 0) try kept.append(a, f);
                const nc = try a.create(ir.Component);
                nc.* = c.*.*;
                // Its methods its own copies (their `component` the new one's).
                for (kept.items) |*f| {
                    const nf = try a.create(ir.Fn);
                    nf.* = f.*.*;
                    nf.component = nc;
                    f.* = nf;
                }
                nc.methods = kept.items;
                c.* = nc;
            }
            m.components = cs;
            for (@constCast(m.entities)) |*e| if (e.own) |o| for (cs) |c| if (c.own and std.mem.eql(u8, c.name, o.name)) {
                e.own = c;
            };
        }
    }

    /// A fighter's `abilities = Abilities(avenger = "x")` (the exe's Grandma child, 0x4e08d0)
    /// as its own code: its OnDeath makes the killer x's target and ends the turn, so x
    /// strikes at once (0x4e35b0 → 0x45b490). A block with an OnDeath of its own keeps the
    /// ability (logged).
    fn avengerCode(self: *Conv) !void {
        const a = self.a;
        for (self.modules.items) |*m| for (@constCast(m.entities)) |*e| {
            if (!std.mem.eql(u8, e.kind, "fighter")) continue;
            const fi = for (e.fields, 0..) |f, i| {
                if (std.mem.eql(u8, f.name, "abilities") and f.value.kind == .call) break i;
            } else continue;
            const c = e.fields[fi].value.kind.call;
            const ai = for (c.named, 0..) |n, i| {
                if (std.mem.eql(u8, n.name, "avenger")) break i;
            } else continue;
            const who = schema.text(c.named[ai].value) orelse continue;
            if (e.own) |o| if (for (o.methods) |f| {
                if (std.ascii.eqlIgnoreCase(f.name, "OnDeath")) break true;
            } else false) {
                try self.line("{s}: has an OnDeath of its own, Abilities avenger kept", .{e.name});
                continue;
            };
            const src = try std.fmt.allocPrint(a, "component C for fighter {{ fn OnDeath(killer) {{ fighter::SetTarget(\"{s}\", killer); battle::EndTurn(); }} }}", .{who});
            var d: parser.Diagnostic = .{};
            const f0 = (try parser.parse(a, src, "avenger.ogs", &d)).modules[0].components[0].methods[0];
            // The ability without `avenger` (none left: no field).
            const rest = try std.mem.concat(a, ir.Named, &.{ c.named[0..ai], c.named[ai + 1 ..] });
            if (rest.len == 0) {
                e.fields = try std.mem.concat(a, ir.Named, &.{ e.fields[0..fi], e.fields[fi + 1 ..] });
            } else {
                const x = try a.create(ir.Expr);
                x.* = e.fields[fi].value.*;
                x.kind.call.named = rest;
                const fs = try a.dupe(ir.Named, e.fields);
                fs[fi].value = x;
                e.fields = fs;
            }
            const nc = try a.create(ir.Component);
            if (e.own) |o| nc.* = o.* else nc.* = .{ .name = e.name, .module = m.path, .hosts = try a.dupe([]const u8, &.{"fighter"}), .traits = &.{}, .fields = &.{}, .methods = &.{}, .line = e.line, .own = true };
            const f = try a.create(ir.Fn);
            f.* = f0.*;
            f.component = nc;
            nc.methods = try std.mem.concat(a, *const ir.Fn, &.{ nc.methods, &.{f} });
            if (e.own) |o| {
                const cs = try a.dupe(*const ir.Component, m.components);
                for (cs) |*x| if (x.* == o) {
                    x.* = nc;
                };
                m.components = cs;
            } else m.components = try std.mem.concat(a, *const ir.Component, &.{ m.components, &.{nc} });
            e.own = nc;
        };
    }

    /// Each location's and battle's code (its namespace's `Logic`, the class's code) as its
    /// block's own (`battle "01__port_barge" { injects classes::CombatLevel; fn OnShown() … }`):
    /// what the block runs is written in it, no component found by its name.
    fn levelCode(self: *Conv) !void {
        const a = self.a;
        for (self.modules.items) |*bm| for (@constCast(bm.entities)) |*e| {
            if (!std.mem.eql(u8, e.kind, "battle") and !std.mem.eql(u8, e.kind, "level")) continue;
            if (e.own != null) continue;
            const p = try std.fmt.allocPrint(a, "{s}::{s}", .{ if (std.mem.eql(u8, e.kind, "battle")) "battles" else "locations", try ogsify.ident(a, e.name) });
            const m = for (self.modules.items) |*x| {
                if (std.mem.eql(u8, x.path, p)) break x;
            } else continue;
            const ci = for (m.components, 0..) |c, i| {
                if (std.mem.eql(u8, c.name, "Logic")) break i;
            } else continue;
            const c = m.components[ci];
            if (c.fields.len > 0) continue;
            const nc = try a.create(ir.Component);
            nc.* = c.*;
            nc.own = true;
            nc.name = e.name;
            nc.module = bm.path;
            nc.hosts = try a.dupe([]const u8, &.{e.kind});
            // Its methods are the block's component's now.
            const ms = try a.alloc(*const ir.Fn, c.methods.len);
            for (ms, c.methods) |*x, f| {
                const nf = try a.create(ir.Fn);
                nf.* = f.*;
                nf.component = nc;
                x.* = nf;
            }
            nc.methods = ms;
            e.own = nc;
            m.components = try std.mem.concat(a, *const ir.Component, &.{ m.components[0..ci], m.components[ci + 1 ..] });
            bm.components = try std.mem.concat(a, *const ir.Component, &.{ bm.components, &.{nc} });
            self.report.own_code += 1;
        };
    }

    /// Each location's and battle's own dialog, `dialog = ~d"<its name>"` where the game has
    /// `<its name>.dlg`: what its code's `scene::Dialog(host.dialog)` plays (the exe's
    /// `DialogInit(GetName(), GetName())`, a battle's StartDialog()).
    fn levelDialogs(self: *Conv) !void {
        const a = self.a;
        for (self.modules.items) |*m| for (@constCast(m.entities)) |*e| {
            if (!std.mem.eql(u8, e.kind, "battle") and !std.mem.eql(u8, e.kind, "level")) continue;
            if (namedIn(e.fields, "dialog") != null or !self.dialog_names.contains(try std.ascii.allocLowerString(a, e.name))) continue;
            const v = try a.create(ir.Expr);
            v.* = .{ .line = e.line, .sigil = .dialog, .kind = .{ .lit = .{ .string = e.name } } };
            e.fields = try std.mem.concat(a, ir.Named, &.{ e.fields, &.{.{ .name = "dialog", .value = v }} });
        };
    }

    /// A block of `same_as = <path>` (`import X;`) writes only what differs from that block,
    /// which gives it the rest (schema.sameAsOf: the world its values, the texts loader its
    /// `name`/`examine` by their one number, the rules their rows by the group, rules.sameThing): a field or a variable's value the same
    /// as the other's goes; one the other has where this one has none is written as this
    /// one's empty value (`0`, `""`, `false`, `[]`, `look = nil`, `action = none`), so
    /// nothing changes. A value with no empty form is kept to the report (`same_as_kept`).
    fn sameAsDiff(self: *Conv) !void {
        const a = self.a;
        // Blocks by path, and by kind and path (one path may be a fighter's and a hero's).
        var blocks: std.StringHashMapUnmanaged(*ir.Entity) = .empty;
        var by_kind: std.StringHashMapUnmanaged(*ir.Entity) = .empty;
        for (self.modules.items) |*m| if (m.path.len > 0) for (@constCast(m.entities)) |*e| {
            const p = try std.fmt.allocPrint(a, "{s}::{s}", .{ m.path, e.name });
            if (!blocks.contains(p)) try blocks.put(a, p, e);
            try by_kind.put(a, try std.fmt.allocPrint(a, "{s} {s}", .{ e.kind, p }), e);
        };
        for (self.modules.items) |*m| for (@constCast(m.entities)) |*e| {
            const sv = namedIn(e.fields, "same_as") orelse continue;
            if (sv.kind != .word) continue;
            // As the reader finds it (world/start.zig sameAsBlock): of its kind (`<fighter>`),
            // else the first by kind in the schema's order, not this block itself.
            const imp = ir.Import.of(sv.kind.word);
            var tk: []const u8 = "";
            var others: usize = 0;
            var found: ?*ir.Entity = null;
            for (schema.block_kinds) |k| if (by_kind.get(try std.fmt.allocPrint(a, "{s} {s}", .{ k, imp.path }))) |x| if (x != e) {
                others += 1;
                if (found == null and (imp.kind.len == 0 or std.mem.eql(u8, k, imp.kind))) {
                    found = x;
                    tk = k;
                }
            };
            const t = found orelse continue;
            // Several blocks at the path: the import names its kind (`import characters::medusa<fighter>;`).
            if (others > 1 and imp.kind.len == 0) {
                const nv = try a.create(ir.Expr);
                nv.* = sv.*;
                nv.kind = .{ .word = try std.fmt.allocPrint(a, "{s}<{s}>", .{ imp.path, tk }) };
                const nf = try a.dupe(ir.Named, e.fields);
                for (nf) |*f| if (std.mem.eql(u8, f.name, "same_as")) {
                    f.value = nv;
                };
                e.fields = nf;
            }
            // Fields: the same as the other's (its archetypes' too) go, where this one's
            // archetypes set none (they would come before it); a text only where the two
            // share one number (this one has no classic_id of its own); a class's row only
            // with the same class.
            const own_id = namedIn(e.fields, "classic_id") != null or baseSets(&blocks, e.base, "classic_id", 0);
            var fs: std.ArrayList(ir.Named) = .empty;
            for (e.fields) |f| {
                const cat = schema.sameAsOf(e.kind, f.name);
                const tv = valueOf(&blocks, t, f.name, 0);
                const same = cat != .no and !(cat == .text and own_id) and !baseSets(&blocks, e.base, f.name, 0) and
                    (if (tv) |v| try sameText(a, v, f.value) else false) and try sameKey(a, &blocks, e, t, f.name);
                if (same) self.report.same_as_dropped += 1 else try fs.append(a, f);
            }
            // The other's fields this one has none of: written as this one's empty value then.
            var at: ?*ir.Entity = t;
            var depth: u32 = 0;
            while (at) |b| : (depth += 1) {
                for (b.fields) |f| {
                    const cat = schema.sameAsOf(e.kind, f.name);
                    // Texts by the number, rows by the `same_as` group (rules.sameThing): already the other's.
                    if (cat != .value) continue;
                    // Its own (kept or the same as the other's), its archetypes': not this one's to write.
                    if (namedIn(e.fields, f.name) != null or namedIn(fs.items, f.name) != null or baseSets(&blocks, e.base, f.name, 0)) continue;
                    const ini = try emptyOf(a, e.kind, f.name, cat) orelse {
                        std.log.warn("{s} {s}: same_as {s} gives it {s}, which it has no empty value of", .{ e.kind, e.name, sv.kind.word, f.name });
                        self.report.same_as_kept += 1;
                        continue;
                    };
                    if (try sameText(a, ini, f.value)) continue;
                    try fs.append(a, .{ .name = f.name, .value = ini });
                }
                if (b.base.len == 0 or depth > 16) break;
                at = blocks.get(b.base);
            }
            e.fields = fs.items;
            // Variables: a value the same as the other's goes; none where the other has one:
            // this one's initial value written.
            const vs = try a.dupe(ir.Field, e.vars);
            for (vs) |*v| {
                const tv = valueOf(&blocks, t, v.name, 0) orelse continue;
                if (v.default) |d| {
                    if (try sameText(a, d, tv)) {
                        v.default = null;
                        self.report.same_as_dropped += 1;
                    }
                } else {
                    const ini = try initialExpr(a, v.type) orelse continue;
                    if (!try sameText(a, ini, tv)) v.default = ini;
                }
            }
            e.vars = vs;
        };
    }

    /// The traits no component implements and no trait extends (Classic class code whose
    /// values the blocks carry: Shotgun's `host.class = 14`): dropped.
    fn dropUnusedTraits(self: *Conv) !void {
        const a = self.a;
        var used: std.StringHashMapUnmanaged(void) = .empty;
        for (self.modules.items) |m| {
            for (m.components) |c| for (c.traits) |t| try used.put(a, lastPart(t), {});
            for (m.traits) |t| for (t.supers) |x| try used.put(a, lastPart(x), {});
        }
        for (self.modules.items) |*m| {
            var keep: std.ArrayList(*const ir.Trait) = .empty;
            for (m.traits) |t| if (used.contains(t.name)) try keep.append(a, t) else {
                self.report.traits_unused += 1;
            };
            m.traits = keep.items;
        }
    }

    /// The `game` block's `party_order`: the party's heroes and the locations' (`hero`
    /// archetypes) by their classic_id, the order Classic gives the party (game.zig
    /// keepSelectable: the hero selected when the selected one is gone), kept without numbers.
    fn partyOrder(self: *Conv) !void {
        const a = self.a;
        const H = struct { path: []const u8, id: i32 };
        var hs: std.ArrayList(H) = .empty;
        var game: ?*ir.Entity = null;
        var party: []const *const ir.Expr = &.{};
        for (self.modules.items) |*m| for (@constCast(m.entities)) |*e| if (std.mem.eql(u8, e.kind, "game")) {
            game = e;
            for (e.fields) |f| if (std.mem.eql(u8, f.name, "party") and f.value.kind == .list) {
                party = f.value.kind.list;
            };
        };
        const g = game orelse return;
        for (self.modules.items) |m| if (m.path.len > 0) for (m.entities) |e| {
            const path = try std.fmt.allocPrint(a, "{s}::{s}", .{ m.path, e.name });
            const in_party = for (party) |x| {
                if (x.kind == .word and std.mem.eql(u8, x.kind.word, path)) break true;
            } else false;
            if (!in_party and !std.mem.eql(u8, e.kind, "hero")) continue;
            try hs.append(a, .{ .path = path, .id = entityId(&e) orelse continue });
        };
        if (hs.items.len == 0) return;
        std.mem.sort(H, hs.items, {}, struct {
            fn lt(_: void, x: H, y: H) bool {
                return x.id < y.id or (x.id == y.id and std.mem.lessThan(u8, x.path, y.path));
            }
        }.lt);
        const list = try a.alloc(*const ir.Expr, hs.items.len);
        for (list, hs.items) |*l, h| {
            const x = try a.create(ir.Expr);
            x.* = .{ .line = g.line, .kind = .{ .word = h.path } };
            l.* = x;
        }
        const v = try a.create(ir.Expr);
        v.* = .{ .line = g.line, .kind = .{ .list = list } };
        var fs: std.ArrayList(ir.Named) = .empty;
        try fs.appendSlice(a, g.fields);
        try fs.append(a, .{ .name = "party_order", .value = v });
        g.fields = fs.items;
    }

    /// The classes' shared code as traits (a class file's code
    /// once, not in every component that includes it). Each file other classes `#include`
    /// whose functions some component has (`Item.s`' UniversalTake, `ci_box.s`' Open) becomes
    /// trait `classes::<File>` (a class of an archetype: `items::Box`, beside its component)
    /// with them as default bodies; each such component then implements it and keeps only
    /// what is its own (its file's functions, the lifted versions of the trait's). A trait
    /// is made only where it gives every component the Classic behaviour, else they keep
    /// the code as before: each one's version of every name of the file is the file's or its
    /// own (Classic: the first definition wins, OGS: the component's), the same arity as the
    /// file's; the file's words mean the same for all (a variable or not, a function they
    /// have or not); no function of an event made of two (`postinit`, OnActorReady), and no
    /// event among the ones it calls but has not.
    fn splitClasses(self: *Conv) !void {
        const a = self.a;
        const Shared = struct { recs: std.ArrayList(usize) = .empty, fns: std.StringArrayHashMapUnmanaged(*const ir.Fn) = .empty, ok: bool = true, trait: []const u8 = "" };
        var files: std.StringArrayHashMapUnmanaged(Shared) = .empty;
        for (self.splits.items, 0..) |sp, i| for (sp.methods) |x| if (!x.own) {
            const g = try files.getOrPut(a, try std.ascii.allocLowerString(a, x.f.file));
            if (!g.found_existing) g.value_ptr.* = .{};
            const sh = g.value_ptr;
            if (sh.recs.items.len == 0 or sh.recs.items[sh.recs.items.len - 1] != i) try sh.recs.append(a, i);
            const n = try std.ascii.allocLowerString(a, x.f.name);
            if (!sh.fns.contains(n)) try sh.fns.put(a, n, x.f);
        };
        // The class's own component (`items::box` of `ci_box.s`) is on its trait too.
        for (self.splits.items, 0..) |sp, i| for (sp.methods) |x| if (x.own) if (files.getPtr(try std.ascii.allocLowerString(a, x.f.file))) |sh| {
            if (std.mem.indexOfScalar(usize, sh.recs.items, i) == null) try sh.recs.append(a, i);
            break;
        };
        var made: std.ArrayList(*const ir.Trait) = .empty;
        var modules: std.StringArrayHashMapUnmanaged(std.ArrayList(*const ir.Trait)) = .empty;
        for (files.keys(), files.values()) |file, *sh| {
            const words = self.fileWords(file) orelse {
                sh.ok = false;
                continue;
            };
            sh.ok = try self.shareable(sh.fns, sh.recs.items, words, file);
            if (!sh.ok) continue;
            const r0 = self.splits.items[sh.recs.items[0]];
            var kinds: std.ArrayList([]const u8) = .empty;
            for (sh.recs.items) |i| try kinds.append(a, self.splits.items[i].oc.kind);
            const host = commonHost(kinds.items) orelse {
                sh.ok = false;
                continue;
            };
            // Its functions own, the ones it calls that every component has required.
            var ms: std.ArrayList(ogsify.Method) = .empty;
            for (sh.fns.values()) |f| try ms.append(a, .{ .f = f, .own = true });
            for (r0.methods) |x| if (wordIn(words, x.f.name) and !sh.fns.contains(try std.ascii.allocLowerString(a, x.f.name))) try ms.append(a, .{ .f = x.f, .own = false });
            const ns, const name = try self.traitName(file);
            var tc = r0.oc;
            tc.name = name;
            tc.kind = host.host.?;
            tc.methods = ms.items;
            tc.virtual = true;
            tc.host_fields = true;
            var stats: ogsify.Stats = .{};
            const new_names = try ogsify.methodNames(a, &tc, r0.rt.builtinNames(), &stats);
            var extra: std.ArrayList(ir.TraitFn) = .empty;
            for (ms.items, new_names) |x, nn| if (!x.own) {
                const f = try a.create(ir.Fn);
                f.* = .{ .name = nn, .file = x.f.file, .line = 0, .params = x.f.params, .slots = @intCast(x.f.params.len), .body = &.{}, .names = x.f.names[0..@min(x.f.names.len, x.f.params.len)], .ogs = true };
                try extra.append(a, .{ .f = f, .body = false });
            };
            const t = try ogsify.traitOf(a, &tc, ns, try a.dupe([]const u8, &.{host.name}), extra.items, r0.rt.builtinNames(), &stats);
            sh.trait = try std.fmt.allocPrint(a, "{s}::{s}", .{ ns, name });
            try made.append(a, t);
            const g = try modules.getOrPut(a, ns);
            if (!g.found_existing) g.value_ptr.* = .empty;
            try g.value_ptr.append(a, t);
        }
        // The traits extend the engine's (`trait Box: Item`): their modules use foundation.
        for (modules.keys(), modules.values()) |ns, ts| try self.modules.append(a, .{ .path = ns, .uses = &.{"foundation"}, .fns = &.{}, .components = &.{}, .traits = ts.items, .entities = &.{}, .rows = &.{} });
        // Each component: its own code, the traits' where they were made.
        for (self.splits.items) |sp| {
            var trait_list: std.ArrayList([]const u8) = .empty;
            var ms: std.ArrayList(ogsify.Method) = .empty;
            for (sp.methods) |x| {
                const sh = files.getPtr(try std.ascii.allocLowerString(a, x.f.file));
                var y = x;
                const replaced = for (sp.by) |r| {
                    if (r[0] == x.f) break r[1];
                } else null;
                // The class's own component: a function of its file nothing calls goes.
                if (sh != null and sh.?.ok and x.own and !sh.?.fns.contains(try std.ascii.allocLowerString(a, x.f.name)) and !self.mentioned(x.f.name)) continue;
                if (sh != null and sh.?.ok and replaced == null) {
                    y.own = false;
                    for (trait_list.items) |t| {
                        if (std.mem.eql(u8, t, sh.?.trait)) break;
                    } else try trait_list.append(a, sh.?.trait);
                } else {
                    y.own = true;
                    if (replaced) |f| y.f = f;
                }
                try ms.append(a, y);
            }
            if (trait_list.items.len == 0) continue;
            var oc = sp.oc;
            oc.methods = ms.items;
            oc.virtual = true;
            var stats: ogsify.Stats = .{};
            const comp = try ogsify.component(a, &oc, sp.rt.builtinNames(), &stats);
            const c = @constCast(sp.comp);
            c.methods = comp.methods;
            c.traits = trait_list.items;
            self.report.split += 1;
        }
        self.report.traits = made.items.len;
    }

    /// The words of class file `file` (`classes\\item.s`) of the common archive; null: none such.
    fn fileWords(self: *Conv, file: []const u8) ?std.StringHashMapUnmanaged(void) {
        const gpa = std.heap.page_allocator;
        const arc = &self.common.?;
        const e = for (arc.entries) |*e| {
            if (std.ascii.eqlIgnoreCase(e.name, file) or (std.ascii.endsWithIgnoreCase(e.name, file) and e.name.len > file.len and e.name[e.name.len - file.len - 1] == '\\')) break e;
        } else return null;
        const t = arc.readAlloc(self.io, gpa, e) catch return null;
        defer gpa.free(t);
        var set: std.StringHashMapUnmanaged(void) = .empty;
        var it = std.mem.tokenizeAny(u8, t, " \t\r\n(){};,=+-*/<>!&|\"'[].:#");
        while (it.next()) |w| set.put(self.a, std.ascii.allocLowerString(self.a, w) catch return null, {}) catch return null;
        return set;
    }

    /// Whether file `file`'s functions `fns` can be one trait for the components `recs`
    /// (`splitClasses`' conditions); `words`: the file's.
    fn shareable(self: *Conv, fns: std.StringArrayHashMapUnmanaged(*const ir.Fn), recs: []const usize, words: std.StringHashMapUnmanaged(void), file: []const u8) !bool {
        const a = self.a;
        for (fns.keys()) |n| for ([_][]const u8{ "postinit", "additionalidleanims" }) |m| if (std.mem.eql(u8, n, m)) return false;
        var key0: ?[]const u8 = null;
        for (recs) |i| {
            const sp = self.splits.items[i];
            // Each name of the file: the file's version, or its own of the same arity.
            for (fns.keys(), fns.values()) |n, f| {
                const x = for (sp.methods) |x| {
                    if (std.ascii.eqlIgnoreCase(x.f.name, n)) break x;
                } else return false;
                if (!x.own and !std.ascii.eqlIgnoreCase(x.f.file, file)) return false;
                if (x.f.params.len != f.params.len) return false;
            }
            // What the file's words are for it: a variable, a function it has.
            var key: std.ArrayList(u8) = .empty;
            var it = words.keyIterator();
            var sorted: std.ArrayList([]const u8) = .empty;
            while (it.next()) |w| try sorted.append(a, w.*);
            std.mem.sort([]const u8, sorted.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.order(u8, x, y) == .lt;
                }
            }.lt);
            for (sorted.items) |w| {
                const field = for (sp.oc.fields) |fd| {
                    if (std.ascii.eqlIgnoreCase(fd.name, w)) break true;
                } else false;
                const has = for (sp.methods) |x| {
                    if (std.ascii.eqlIgnoreCase(x.f.name, w)) break true;
                } else false;
                if (!field and !has) continue;
                // The file's own functions: the checks above.
                const its = for (sp.methods) |x| {
                    if (std.ascii.eqlIgnoreCase(x.f.name, w) and std.ascii.eqlIgnoreCase(x.f.file, file)) break true;
                } else false;
                if (its and !field) continue;
                // A function the file calls but has not: required, never an event.
                if (has and !fns.contains(w)) for (script.traits.classic) |c| if (std.ascii.eqlIgnoreCase(c.name, w)) return false;
                try key.print(a, "{s}{d}{d} ", .{ w, @intFromBool(field), @intFromBool(has) });
            }
            if (key0) |k| {
                if (!std.mem.eql(u8, k, key.items)) return false;
            } else key0 = key.items;
        }
        return true;
    }

    /// Trait name of class file `file`: its archetype's (`ci_box.s` → `items::Box`), else
    /// `classes::<Stem>` (`Class` appended where the engine has the name: `ItemClass`).
    fn traitName(self: *Conv, file: []const u8) !struct { []const u8, []const u8 } {
        const a = self.a;
        // The archive's spelling (`BitmapAnimation.s`), the IR's file is lower case.
        const spelled = for (self.common.?.entries) |e| {
            if (std.ascii.endsWithIgnoreCase(e.name, file) and (e.name.len == file.len or e.name[e.name.len - file.len - 1] == '\\')) break e.name[e.name.len - file.len ..];
        } else file;
        const base = spelled[if (std.mem.lastIndexOfScalar(u8, spelled, '\\')) |k| k + 1 else 0..];
        const raw = base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];
        const stem = self.spellings.get(try std.ascii.allocLowerString(a, raw)) orelse raw;
        var ns: []const u8 = "classes";
        var n: []const u8 = stem;
        if (self.arch_paths.get(try std.ascii.allocLowerString(a, stem))) |path| if (std.mem.indexOf(u8, path, "::")) |k| {
            ns = path[0..k];
            n = path[k + 2 ..];
        };
        // PascalCase: `actracting_device` → ActractingDevice, `BitmapAnimation` as it is.
        var pascal: std.ArrayList(u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, try ogsify.ident(a, n), '_');
        while (it.next()) |part| {
            try pascal.append(a, std.ascii.toUpper(part[0]));
            try pascal.appendSlice(a, part[1..]);
        }
        var out: []const u8 = if (pascal.items.len > 0 and !std.ascii.isDigit(pascal.items[0])) pascal.items else try ogsify.ident(a, n);
        if (script.traits.find(out) != null or parser.isKeyword(out)) out = try std.fmt.allocPrint(a, "{s}Class", .{out});
        return .{ ns, out };
    }

    /// `words`, `defs` from every text of the common and the locations' archives that may
    /// name a function: scripts, scenes (`.scr`), dialogs, `.var`. A string counts (calls by
    /// name: `QueueCall(hero, "GrandHand", "UniversalTake")`, GO_RunFun).
    fn mentions(self: *Conv, levels: []const []const u8) !void {
        const gpa = std.heap.page_allocator;
        var paths: std.ArrayList([]const u8) = .empty;
        try paths.appendSlice(self.a, &.{ "common/other.dat", "common/lang.dat" });
        for (levels) |l| if (!std.ascii.eqlIgnoreCase(l, "common")) try paths.append(self.a, try std.fmt.allocPrint(self.a, "{s}/other.dat", .{l}));
        for (paths.items) |p| {
            var arc = archive.Archive.open(self.io, gpa, self.dat, p) catch continue;
            defer arc.close(self.io, gpa);
            for (arc.entries) |*e| {
                const text_like = formats.resource.isScript(e.name) or for ([_][]const u8{ ".s", ".ss", ".scr", ".var", ".dlg", ".pts" }) |x| {
                    if (std.ascii.endsWithIgnoreCase(e.name, x)) break true;
                } else false;
                if (!text_like) continue;
                const t = arc.readAlloc(self.io, gpa, e) catch continue;
                defer gpa.free(t);
                try countWords(self.a, t, &self.words, &self.defs);
                try self.spellOf(t);
            }
        }
    }

    /// `spellings` from text `t`: each word with a capital, first seen.
    fn spellOf(self: *Conv, t: []const u8) !void {
        var it = std.mem.tokenizeAny(u8, t, " \t\r\n(){};,=+-*/<>!&|\"'[]:#.");
        while (it.next()) |w| {
            const cap = for (w) |c| {
                if (std.ascii.isUpper(c)) break true;
            } else false;
            if (!cap or w.len > 64) continue;
            const k = try std.ascii.allocLowerString(self.a, w);
            const g = try self.spellings.getOrPut(self.a, k);
            if (!g.found_existing) g.value_ptr.* = try self.a.dupe(u8, w);
        }
    }

    /// Inherited function `name` is called somewhere (by any text, by the engine as an
    /// event, a hook or an action's function), not only defined.
    fn mentioned(self: *const Conv, name: []const u8) bool {
        var buf: [128]u8 = undefined;
        if (name.len > buf.len) return true;
        const k = std.ascii.lowerString(&buf, name);
        if (rules.actionNamed(name) != null) return true;
        for (script.traits.classic) |c| if (std.ascii.eqlIgnoreCase(c.name, name)) return true;
        for (engine_calls) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
        return (self.words.get(k) orelse 0) > (self.defs.get(k) orelse 0);
    }

    /// A runtime over archive `path`'s scripts (kept to the end).
    fn runtime(self: *Conv, path: []const u8) !*Kept {
        const gpa = std.heap.page_allocator;
        const k = try self.a.create(Kept);
        k.arc = try archive.Archive.open(self.io, gpa, self.dat, path);
        k.sources = .{ .io = self.io, .a = self.a, .local = &k.arc, .common = &self.common.? };
        k.rt = .init(gpa, .{ .ctx = &k.sources, .fetch = Sources.fetch });
        // The runtime's own options (Runtime.lift): what it lifts is what runs as data.
        k.rt.lift = true;
        var dummy: u8 = 0;
        inline for (builtins.table) |e| try k.rt.registerBuiltinSig(e[0], &dummy, noCall, e[2]);
        try self.runtimes.append(self.a, k);
        return k;
    }

    // ------------------------------------------------------------ objects

    /// `gamestart\*`: heroes as `characters::<hero>` (`hero`, the party), the shared
    /// items as archetypes (`weapons::gs_fist_all`, `items::gs_transmitter_s`: a thing of
    /// its own, its rows by path) and their objects nested in the `game` block (`weapon
    /// gs_fist_all: weapons::gs_fist_all {}`), in the archive's order (the exe's).
    fn gamestart(self: *Conv) !void {
        const k = self.runtimes.items[0];
        var chars: Module = .{ .path = "characters" };
        var weapons: Module = .{ .path = "weapons" };
        var things: Module = .{ .path = "items" };
        var root: Module = .{ .path = "" };
        var game: std.Io.Writer.Allocating = .init(self.a);
        var party: std.ArrayList(u8) = .empty;
        var items: std.Io.Writer.Allocating = .init(self.a);
        for (k.arc.entries) |e| {
            if (!std.ascii.startsWithIgnoreCase(e.name, "gamestart\\")) continue;
            const file = e.name["gamestart\\".len..];
            const ext = std.fs.path.extension(file);
            const stem = file[0 .. file.len - ext.len];
            // Not a script (`vssver.scc`, the original's source control).
            if (state_object.kindOf(ext) == .other) continue;
            const cls = k.rt.loadClass(file) catch |err| {
                try self.line("gamestart {s}: {t}", .{ file, err });
                continue;
            };
            const hero = std.ascii.eqlIgnoreCase(ext, ".hro");
            const kind = if (hero) "hero" else blockKind(cls, ext) orelse continue;
            if (hero) {
                try self.addObject(&k.rt, &chars, cls, file, stem, kind, false, &chars.data.writer, 0);
                if (party.items.len > 0) try party.appendSlice(self.a, ", ");
                try party.print(self.a, "characters::{s}", .{try ogsify.ident(self.a, stem)});
            } else {
                const into = if (std.mem.eql(u8, kind, "weapon")) &weapons else &things;
                try self.addObject(&k.rt, into, cls, file, stem, kind, false, &into.data.writer, 0);
                const id = try ogsify.ident(self.a, stem);
                try items.writer.print("    {s} {s}: {s}::{s} {{\n    }}\n", .{ kind, id, into.path, id });
            }
        }
        try game.writer.print("game gorky {{\n    party = [{s}];\n{s}}}\n", .{ party.items, items.written() });
        try root.data.writer.writeAll(game.written());
        try self.addModule(&chars);
        try self.addModule(&weapons);
        try self.addModule(&things);
        try self.addModule(&root);
    }

    /// The common item and weapon classes (`classes\\ci_food.s`, `cw_riffle.s`…) and the
    /// battle devices' (`ft_time_bomb.ss`) as archetypes, named without their file's kind
    /// prefix (`items::food`, `weapons::riffle`, `characters::time_bomb`):
    /// `arch_list`, `arch_paths`. A name taken already in its namespace (a hero's, an
    /// earlier class's) gets `_2`… in archive order, reported (`collisions`).
    fn archetypeNames(self: *Conv) !void {
        const a = self.a;
        const k = self.runtimes.items[0];
        var used: std.StringHashMapUnmanaged(void) = .empty;
        // The heroes' (`characters::sullivan`, gamestart).
        for (k.arc.entries) |e| if (std.ascii.startsWithIgnoreCase(e.name, "gamestart\\") and std.ascii.endsWithIgnoreCase(e.name, ".hro")) {
            const f = e.name["gamestart\\".len..];
            try used.put(a, try std.fmt.allocPrint(a, "characters::{s}", .{try ogsify.ident(a, f[0 .. f.len - 4])}), {});
        };
        for (k.arc.entries) |e| {
            if (!std.ascii.startsWithIgnoreCase(e.name, "classes\\")) continue;
            const file = e.name["classes\\".len..];
            const device = for (self.devices.items) |d| {
                if (std.ascii.eqlIgnoreCase(d, file)) break true;
            } else false;
            if (!device and !std.ascii.endsWithIgnoreCase(e.name, ".s")) continue;
            const cls = k.rt.loadClass(file) catch continue;
            const names = try a.alloc([]const u8, cls.vars.items.len);
            for (cls.vars.items, names) |d, *n| n.* = d.name;
            const h = schema.hostOf(names) orelse continue;
            // A device that is no weapon is a fighter (combat/devices.zig placeDevice).
            const ns: []const u8 = if (std.mem.eql(u8, h.name, "weapon")) "weapons" else if (std.mem.eql(u8, h.name, "item")) "items" else if (device) "characters" else continue;
            const kind = if (std.mem.eql(u8, ns, "characters")) "fighter" else h.name;
            const stem = file[0 .. file.len - std.fs.path.extension(file).len];
            const base = try ogsify.ident(a, unprefixed(stem));
            var name = base;
            var i: usize = 2;
            while (used.contains(try std.fmt.allocPrint(a, "{s}::{s}", .{ ns, name }))) : (i += 1) name = try std.fmt.allocPrint(a, "{s}_{d}", .{ base, i });
            if (name.ptr != base.ptr) {
                self.report.collisions += 1;
                try self.line("archetype {s}: {s}::{s} taken, named {s}::{s}", .{ file, ns, base, ns, name });
            }
            if (!std.mem.eql(u8, name, stem)) self.report.renamed += 1;
            const path = try std.fmt.allocPrint(a, "{s}::{s}", .{ ns, name });
            try used.put(a, path, {});
            try self.arch_list.append(a, .{ .file = file, .cls = cls, .ns = ns, .kind = kind, .name = name });
            try self.arch_paths.put(a, try classStem(file, a), path);
        }
    }

    /// The archetypes of `archetypeNames` made (in archive order): what Weapon_New/Item_New
    /// make (world/start.zig newBlockItem, by the path the converted code names).
    fn archetypes(self: *Conv) !void {
        const k = self.runtimes.items[0];
        var items: Module = .{ .path = "items" };
        var weapons: Module = .{ .path = "weapons" };
        var chars: Module = .{ .path = "characters" };
        self.archetype = true;
        defer self.archetype = false;
        for (self.arch_list.items) |x| {
            const m = if (std.mem.eql(u8, x.ns, "weapons")) &weapons else if (std.mem.eql(u8, x.ns, "items")) &items else &chars;
            try self.addObject(&k.rt, m, x.cls, x.file, x.name, x.kind, false, &m.data.writer, 0);
        }
        try self.addModule(&items);
        try self.addModule(&weapons);
        try self.addModule(&chars);
    }

    /// The Device rows' `archetype` (`"ft_time_bomb.ss"`, the Classic file) as the path of
    /// the archetype made of it (`"characters::time_bomb"`; combat/devices.zig deviceObject).
    fn deviceRefs(self: *Conv, rows: []const *const ir.Expr) ![]const *const ir.Expr {
        const a = self.a;
        const out = try a.dupe(*const ir.Expr, rows);
        for (out) |*r| if (r.*.kind == .call and std.mem.eql(u8, r.*.kind.call.text, "Device")) {
            const c = r.*.kind.call;
            const named = try a.dupe(ir.Named, c.named);
            for (named) |*n| if (std.mem.eql(u8, n.name, "archetype")) {
                const s = schema.text(n.value) orelse continue;
                const p = self.arch_paths.get(try classStem(s, a)) orelse continue;
                const v = try a.create(ir.Expr);
                v.* = n.value.*;
                v.kind = .{ .lit = .{ .string = p } };
                n.value = v;
            };
            var nc = c;
            nc.named = named;
            const x = try a.create(ir.Expr);
            x.* = r.*.*;
            x.kind = .{ .call = nc };
            r.* = x;
        };
        return out;
    }

    /// Location `level` (`dat/<level>/other.dat`): its level block with every object of
    /// the archive nested in order, in module `locations::<level>` / `battles::<level>`.
    fn location(self: *Conv, level: []const u8) !void {
        var path_buf: [256]u8 = undefined;
        const k = self.runtime(try std.fmt.bufPrint(&path_buf, "{s}/other.dat", .{level})) catch |err| {
            try self.line("{s}: {t}", .{ level, err });
            return;
        };
        // The level object first: it decides the block's kind and namespace.
        var lev: ?*object.Class = null;
        var lev_file: []const u8 = "";
        for (k.arc.entries) |e| if (std.ascii.eqlIgnoreCase(std.fs.path.extension(e.name), ".lev")) {
            lev = k.rt.loadClass(e.name) catch null;
            lev_file = e.name;
            break;
        };
        const lc = lev orelse return self.line("{s}: no level object", .{level});
        const kind = blockKind(lc, ".lev").?;
        // Its actor objects (blocks below): what restore() may place as their data.
        self.actors.clearRetainingCapacity();
        self.tiles.clearRetainingCapacity();
        for (k.arc.entries) |e| {
            const ext = std.fs.path.extension(e.name);
            if (state_object.kindOf(ext) != .actor) continue;
            const cls = k.rt.loadClass(e.name) catch continue;
            if (blockKind(cls, ext) == null) continue;
            try self.actors.put(self.a, try std.ascii.allocLowerString(self.a, e.name[0 .. e.name.len - ext.len]), {});
        }
        const ns = if (std.mem.eql(u8, kind, "battle")) "battles" else "locations";
        // The block at the root (a `~l"…"` names it from any namespace), its code in the namespace.
        var m: Module = .{ .path = try std.fmt.allocPrint(self.a, "{s}::{s}", .{ ns, try ogsify.ident(self.a, level) }), .blocks_at_root = true };
        var inner: std.Io.Writer.Allocating = .init(self.a);
        var head: std.Io.Writer.Allocating = .init(self.a);
        var morphs: std.Io.Writer.Allocating = .init(self.a);
        try self.addObject(&k.rt, &m, lc, lev_file, level, kind, true, &head.writer, 0);
        // Its area triggers' component names, taken before its objects take theirs.
        for (m.comps.items) |c| if (std.mem.eql(u8, c.name, "Logic")) {
            var names: std.ArrayList([]const u8) = .empty;
            if (onUpdate(c)) |f| for (f.body) |st| if (triggerArea(st)) |area| try names.append(self.a, try m.uniqueName(self.a, try ogsify.ident(self.a, area)));
            if (names.items.len > 0) try self.triggers.append(self.a, .{ .logic = c, .level = level, .kind = kind, .ns = m.path, .names = names.items });
        };
        for (k.arc.entries) |e| {
            const ext = std.fs.path.extension(e.name);
            if (e.name.ptr == lev_file.ptr or std.ascii.eqlIgnoreCase(ext, ".lev")) continue;
            // A morph's class (ACTOR_MORPH, the battle's Transform): a fighter archetype
            // beside the level (world/start.zig morphTarget), no object of its own.
            if (std.ascii.eqlIgnoreCase(ext, ".mtm")) {
                const cls = k.rt.loadClass(e.name) catch |err| {
                    try self.line("{s}: {s}: {t}", .{ level, e.name, err });
                    continue;
                };
                self.archetype = true;
                self.full = true;
                defer self.archetype = false;
                defer self.full = false;
                try self.addObject(&k.rt, &m, cls, e.name, e.name[0 .. e.name.len - ext.len], "fighter", false, &morphs.writer, 0);
                continue;
            }
            // A path's script (`deska.pth`): with its path, below (`paths`).
            if (std.ascii.eqlIgnoreCase(ext, ".pth")) continue;
            if (state_object.kindOf(ext) == .other) continue;
            const cls = k.rt.loadClass(e.name) catch |err| {
                try self.line("{s}: {s}: {t}", .{ level, e.name, err });
                continue;
            };
            const bk = blockKind(cls, ext) orelse continue;
            const oname = e.name[0 .. e.name.len - ext.len];
            const prefix: []const u8 = if (std.mem.eql(u8, bk, "fighter")) "ft_" else if (std.mem.eql(u8, bk, "weapon")) "wp_" else "";
            if (prefix.len > 0) {
                const st = rules.classOf(cls);
                if (std.ascii.startsWithIgnoreCase(st, prefix)) try self.inst_arch.put(self.a, try instKey(self.a, level, oname), st);
            }
            if (std.ascii.eqlIgnoreCase(ext, ".hro")) try self.heroes.put(self.a, try instKey(self.a, level, oname), {});
            try self.addObject(&k.rt, &m, cls, e.name, oname, bk, false, &inner.writer, 1);
        }
        try self.walkPaths(k, level, &inner.writer);
        // The level's block: its own fields (head, without its closing brace), then the objects.
        const h = head.written();
        try m.data.writer.print("{s}{s}}}\n{s}", .{ h[0 .. h.len - 2], inner.written(), morphs.written() });
        try self.addModule(&m);
    }

    /// The level's walk paths (`<level>.ap`) as its `path` blocks (into `w`, written to the
    /// level's `paths.ogs`): `link`, `points` as PathPoint records and, where the path has a
    /// script (`<name>.pth`), its code in the block (NodeResponse → OnNode; world/start.zig
    /// pathBlock).
    fn walkPaths(self: *Conv, k: *Kept, level: []const u8, w: *Writer) !void {
        const a = self.a;
        const ap = for (k.arc.entries) |*e| {
            if (std.ascii.eqlIgnoreCase(std.fs.path.extension(e.name), ".ap")) break e;
        } else return;
        const text = try k.arc.readAlloc(self.io, a, ap);
        const ps = @import("../loaders.zig").map.parsePaths(a, text) catch |err| return self.line("{s}: {s}: {t}", .{ level, ap.name, err });
        for (ps) |p| {
            try indent(w, 1);
            try w.print("path {s} {{\n", .{try blockName(a, p.name)});
            try indent(w, 2);
            try w.print("link = [{d}, {d}, {d}, {d}];\n", .{ p.link[0], p.link[1], p.link[2], p.link[3] });
            try indent(w, 2);
            try w.writeAll("points = [");
            for (p.points, 0..) |pt, i| {
                try w.print("{s}PathPoint(x = {d}, y = {d}, angle = {d}", .{ if (i > 0) ", " else "", pt[0], pt[1], pt[2] });
                // A float literal (`0.0`, not `0`).
                if (@floor(pt[2]) == pt[2]) try w.writeAll(".0");
                try w.print(", z = {d})", .{pt[3]});
            }
            try w.writeAll("];\n");
            // Its script: its methods in the block.
            var nb: [128]u8 = undefined;
            const file = try std.fmt.bufPrint(&nb, "{s}.pth", .{p.name});
            const has = for (k.arc.entries) |e| {
                if (std.ascii.eqlIgnoreCase(e.name, file)) break true;
            } else false;
            if (has) if (k.rt.loadClass(file)) |cls| {
                var oc = try ogsify.classOf(a, &k.rt, cls, file, p.name, "path", false);
                var stats: ogsify.Stats = .{};
                const comp = try pruneDead(a, try ogsify.component(a, &oc, k.rt.builtinNames(), &stats), &self.report);
                if (comp.fields.len > 0) try self.line("{s}: {s}: its variables left out", .{ level, file });
                for (comp.methods) |f| try print_ogs.function(w, f, 2);
            } else |err| try self.line("{s}: {s}: {t}", .{ level, file, err });
            try indent(w, 1);
            try w.writeAll("}\n");
        }
    }

    /// Object `name` of class `cls` (file `file`) as block `kind` into `w` (at `depth`),
    /// its component into `m`. `is_level`: the location's own block (component `Logic`).
    fn addObject(self: *Conv, rt: *Runtime, m: *Module, cls: *object.Class, file: []const u8, name: []const u8, kind: []const u8, is_level: bool, w: *Writer, depth: usize) !void {
        const a = self.a;
        self.report.objects += 1;
        const host = schema.blockHost(kind).?;
        // A fighter archetype of a `.ss`/`.mtm` is an actor too.
        const actor = state_object.kindOf(std.fs.path.extension(file)) == .actor or std.mem.eql(u8, kind, "fighter");
        // The Classic start state: each variable's initial value, its `.var`, the lifted
        // values of the creation events.
        var state: std.ArrayList(Slot) = .empty;
        for (cls.vars.items) |d| try state.append(a, .{ .name = cls.varName(d), .type = d.type, .value = .initial(d.type) });
        if (!self.archetype) try self.applyVars(&state, name, cls.host);
        var lk: LookB = .{};
        var camera: std.ArrayList(u8) = .empty;
        var placement: std.ArrayList(u8) = .empty;
        var entry: ?[]const u8 = null;
        // Each creation event: its IR without the statements that became data.
        var replaced: std.ArrayList(struct { f: *const ir.Fn, by: *const ir.Fn }) = .empty;
        var lifted: std.StringHashMapUnmanaged(void) = .empty;
        // class_init() runs where init() calls it (an actor's: the engine calls it for
        // items alone): its look calls are look data then.
        const init_calls_ci = if (object.findAnyCase("init")) |id| if (cls.findFunctionId(id)) |func| callsFn(try rt.compiled(func), "class_init") else false else false;
        for ([_][]const u8{ "class_init", "init", "postinit", "initCamera", "restore" }) |ev| {
            const id = object.findAnyCase(ev) orelse continue;
            const func = cls.findFunctionId(id) orelse continue;
            const f = try rt.compiled(func);
            const l = try lift.lift(a, rt.importEnv(), f, cls);
            const placing = is_level and std.mem.eql(u8, ev, "restore");
            if (l.items.len == 0 and !placing) continue;
            var drop: std.AutoHashMapUnmanaged(u32, void) = .empty;
            for (l.items) |it| switch (it) {
                .field => |x| {
                    const s = slotOf(state.items, x.name) orelse continue;
                    // The exe's restore() and init() of the level: levelMode, the camera…
                    if (std.mem.eql(u8, ev, "initCamera") and isCameraField(x.name)) {
                        try camera.print(a, "{s}{s} = ", .{ if (camera.items.len > 0) ", " else "", cameraName(x.name) });
                        const v = try x.value.convert(s.type, a);
                        // `Camera.perspective` is a bool.
                        if (std.mem.eql(u8, cameraName(x.name), "perspective") and v == .int and (v.int == 0 or v.int == 1))
                            try camera.appendSlice(a, if (v.int == 1) "true" else "false")
                        else
                            try literal(a, &camera, v);
                    }
                    s.value = try x.value.convert(s.type, a);
                    try lifted.put(a, s.name, {});
                    try drop.put(a, x.origin.at, {});
                },
                .call => |x| {
                    const look_ev = std.mem.eql(u8, ev, "init") or std.mem.eql(u8, ev, "postinit") or (init_calls_ci and std.mem.eql(u8, ev, "class_init"));
                    if (actor and look_ev and isLookCall(x.name)) {
                        if (try lk.add(a, x.name, x.args, x.origin.file)) try drop.put(a, x.origin.at, {});
                    } else if (is_level and std.mem.eql(u8, ev, "restore") and std.ascii.eqlIgnoreCase(x.name, "PlaceActor")) {
                        if (try place(a, &placement, x.args, std.mem.eql(u8, kind, "battle"))) try drop.put(a, x.origin.at, {});
                    }
                },
            };
            if (placing) try self.liftPlacing(f, cls, &drop, &placement, &entry, std.mem.eql(u8, kind, "battle"));
            if (drop.count() == 0) continue;
            var body: std.ArrayList(ir.Stmt) = .empty;
            for (f.body, 0..) |st, i| if (!drop.contains(@intCast(i))) try body.append(a, st);
            const nf = try a.create(ir.Fn);
            nf.* = f.*;
            nf.body = body.items;
            try replaced.append(a, .{ .f = f, .by = nf });
        }

        if (std.mem.eql(u8, kind, "fighter")) if (try fieldRow(a, name, state.items)) |r| try self.field_rows.appendSlice(a, r);
        // The block.
        const bname = try blockName(a, name);
        try indent(w, depth);
        try w.print("{s} {s} {{\n", .{ kind, bname });
        // The look first (the OG reader puts it under the fields).
        var look_name: ?[]const u8 = null;
        if (lk.any()) {
            look_name = try self.look(&lk, state.items, file);
            try indent(w, depth + 1);
            try w.print("look = looks::{s};\n", .{look_name.?});
        }
        if (camera.items.len > 0) {
            try indent(w, depth + 1);
            try w.print("camera = Camera({s});\n", .{camera.items});
        }
        if (placement.items.len > 0) {
            try indent(w, depth + 1);
            try w.print("placement = [{s}];\n", .{placement.items});
        }
        if (entry) |p| {
            try indent(w, depth + 1);
            try w.writeAll("entry = ");
            var buf: std.ArrayList(u8) = .empty;
            try literal(a, &buf, .{ .string = p });
            try w.print("{s};\n", .{buf.items});
        }
        // The generic fighter's own resistances and armour class (the exe's fields `resist`,
        // `armor_class`): its `immunity`, OG Script's one place for them.
        const generic_resist = std.mem.eql(u8, kind, "fighter") and try genericImmunity(state.items, w, depth + 1);
        // Its battle's restore() placed it (liftPlacing).
        if (!is_level and depth == 1) if (self.tiles.get(try std.ascii.allocLowerString(a, name))) |t| {
            try indent(w, depth + 1);
            try w.print("{s}\n", .{t});
        };
        // A barrel's weapon whose blast the exe shows by its classic_id (modules.blastShown).
        if (std.mem.eql(u8, kind, "weapon")) if (slotOf(state.items, "classic_id")) |s| if (s.value == .int and core.modules.blastShown(s.value.int)) {
            try indent(w, depth + 1);
            try w.writeAll("explodable = 1;\n");
        };
        // The class's code as a component (all it answers: its own and inherited functions).
        const comp_name = try m.uniqueName(a, if (is_level) "Logic" else try ogsify.ident(a, name));
        var oc = try ogsify.classOf(a, rt, cls, file, comp_name, hostKind(kind), actor);
        oc.spelling = .{ .ctx = self, .of = spellingOf };
        // An inherited function nothing calls (`gameobject.s` dump(): a MessageBox for
        // debugging) is not written into every component.
        var used: std.ArrayList(ogsify.Method) = .empty;
        for (oc.methods) |x| if (x.own or self.mentioned(x.f.name)) try used.append(a, x);
        const ms = used.items;
        for (state.items) |s| {
            if (s.value == .nil) continue;
            // An area's further action (`action1`: OG Script's field, actionRefs) is its
            // Classic class's own variable.
            const further = std.mem.startsWith(u8, s.name, "action") and s.name.len == 7;
            if (if (further) null else schema.field(host, s.name)) |fd| {
                if (fd.only_og or (camera.items.len > 0 and isCameraField(s.name) and inCamera(camera.items, s.name))) continue;
                // Not carried (`Field.dropped`; `isCombat`: the block's kind).
                if (fd.only_classic and schema.ogField(host, s.name) == null) {
                    if (std.mem.eql(u8, s.name, "attackEffectDelay")) try genericHitDelay(rt, w, depth, state.items, s.value);
                    continue;
                }
                // What the OG reader starts it with: the schema's default, the look's.
                var start = try fd.default().convert(s.type, a);
                if (look_name != null) if (lk.field(s.name)) |v| {
                    start = v;
                };
                if (!(self.full and lifted.contains(s.name)) and ir.sameSkipping(Value, start, s.value, &.{})) continue;
                try indent(w, depth + 1);
                try w.print("{s} = ", .{fd.name});
                var buf: std.ArrayList(u8) = .empty;
                // `armor`: a hero's points (a number); a monster's class (battle/rules.zig
                // afterArmor: one past 0-2 cuts nothing, as `none`).
                if (std.mem.eql(u8, fd.name, "armor") and s.value == .int and std.mem.eql(u8, kind, "hero")) {
                    try literal(a, &buf, s.value);
                } else if (std.mem.eql(u8, fd.name, "armor") and std.mem.eql(u8, kind, "fighter") and s.value == .int and (s.value.int < 0 or s.value.int > 2)) {
                    try buf.appendSlice(a, "none");
                } else try wordOrLiteral(a, &buf, fd, s.value);
                try w.print("{s};\n", .{buf.items});
                self.report.fields += 1;
            } else {
                // Its Classic base class's field OpenGorky does not carry (an obstacle's
                // `actRot`: `fighter.s`'s; `Field.dropped`).
                if (cls.host) |ch| if (schema.host(@tagName(ch))) |hh| if (schema.field(hh, s.name)) |fd| if (fd.dropped) continue;
                const initial = ir.sameSkipping(Value, Value.initial(s.type), s.value, &.{});
                if (isUnreadVar(s.name) and initial) continue;
                if (generic_resist and (std.ascii.eqlIgnoreCase(s.name, "resist") or std.ascii.eqlIgnoreCase(s.name, "armor_class"))) continue;
                // A field its Classic class's kind declares itself and the block's has not (an
                // actor's `hp`: its `.act` includes Fighter.s; not the parents' `x`, which the
                // placing writes), at its initial value and named by none of its code: not
                // written (absent, the engine reads it as that; convertcheck too).
                if (initial and !(try anyMentions(a, ms, s.name))) if (cls.host) |ch| if (schema.host(@tagName(ch))) |hh| if (ownField(hh, s.name)) continue;
                try indent(w, depth + 1);
                try w.print("var {s} {s}", .{ typeName(s.type), s.name });
                if ((self.full and lifted.contains(s.name)) or !ir.sameSkipping(Value, Value.initial(s.type), s.value, &.{})) {
                    var buf: std.ArrayList(u8) = .empty;
                    try literal(a, &buf, s.value);
                    try w.print(" = {s}", .{buf.items});
                }
                try w.writeAll(";\n");
                self.report.vars += 1;
            }
        }
        const orig = try a.dupe(ogsify.Method, ms);
        var by: std.ArrayList([2]*const ir.Fn) = .empty;
        for (replaced.items) |r| try by.append(a, .{ r.f, r.by });
        for (ms) |*x| {
            x.own = true;
            for (replaced.items) |r| if (x.f == r.f) {
                x.f = r.by;
            };
        }
        var split_oc = oc;
        oc.methods = ms;
        var stats: ogsify.Stats = .{};
        const comp = try pruneDead(a, try ogsify.component(a, &oc, rt.builtinNames(), &stats), &self.report);
        if (comp.methods.len > 0) {
            split_oc.methods = orig;
            try self.splits.append(a, .{ .comp = comp, .oc = split_oc, .methods = orig, .by = by.items, .rt = rt });
            try m.comps.append(a, comp);
            self.report.components += 1;
            if (!is_level) {
                try indent(w, depth + 1);
                try w.print("attach {s}{s}{s}();\n", .{ if (m.blocks_at_root) m.path else "", if (m.blocks_at_root) "::" else "", comp_name });
            }
        }
        try indent(w, depth);
        try w.writeAll("}\n");
    }

    /// A level's restore() `f` (a battle's, a location's: `battle`): past what `lift` took
    /// (`drop`), its top-level placing calls with constant arguments — PlaceActor's tile
    /// form of its own objects (`self.actors`) → the block's `tile`, PlaceCombatActor
    /// (`battle::PlaceProp`) → `at`, PlaceActor's area form → a `Place` appended to
    /// `placement` — into `drop` and `self.tiles` (placement is
    /// data; a location's re-entry places it too, world/levels.zig reenter). Each such call only
    /// sets one object's position and angle, so the data's placing (world/start.zig
    /// placeModel, right before OnRestore) gives the same as the calls; the walk stops at
    /// the first statement that is no placing call or AIEnemyAppear (it too only places,
    /// builtins/combat.zig) — code after it may read or change what they place. An object
    /// placed or appearing twice stays code; what stays is counted (`placed_code`).
    /// `PlaceActor(GUI_GetSelectedHero(), "<point>", 0)` in the walk becomes the level's `entry`
    /// (world/start.zig placeEntry: right after the data, before OnRestore) when every
    /// placing before it is data too; the walk ends there (what follows would be placed
    /// before it).
    fn liftPlacing(self: *Conv, f: *const ir.Fn, cls: *const object.Class, drop: *std.AutoHashMapUnmanaged(u32, void), placement: *std.ArrayList(u8), entry: *?[]const u8, battle: bool) !void {
        const a = self.a;
        const data = if (battle) &self.report.placed_data else &self.report.loc_placed_data;
        const code = if (battle) &self.report.placed_code else &self.report.loc_placed_code;
        // `place`: a Place of `placement`, else the object block's `line`.
        const Cand = struct { at: u32, key: []const u8, line: []const u8, place: bool };
        var cands: std.ArrayList(Cand) = .empty;
        var seen: std.StringHashMapUnmanaged(u32) = .empty;
        var walking = true;
        var at_entry: ?struct { at: u32, point: []const u8 } = null;
        for (f.body, 0..) |*s, i| {
            const at: u32 = @intCast(i);
            if (drop.contains(at)) continue;
            const c = placingCall(s, cls) orelse {
                walking = false;
                continue;
            };
            const tile = std.ascii.eqlIgnoreCase(c.text, "PlaceActor");
            const prop = std.ascii.eqlIgnoreCase(c.text, "PlaceCombatActor");
            if (!walking) {
                if (tile or prop) code.* += 1;
                continue;
            }
            if (tile) if (entryPoint(c)) |p| {
                at_entry = .{ .at = at, .point = p };
                walking = false;
                continue;
            };
            var args: [5]Value = undefined;
            const n = @min(c.args.len, args.len);
            for (c.args[0..n], args[0..n]) |e, *v| v.* = constant(e) orelse {
                walking = false;
                break;
            };
            if (!walking or n == 0 or args[0] != .string) {
                walking = false;
                if (tile or prop) code.* += 1;
                continue;
            }
            const key = try std.ascii.allocLowerString(a, args[0].string);
            const g = try seen.getOrPut(a, key);
            g.value_ptr.* = if (g.found_existing) g.value_ptr.* + 1 else 1;
            if (!tile and !prop) continue;
            var stmt: std.ArrayList(u8) = .empty;
            if (tile and n >= 3 and args[1] == .string) {
                if (try place(a, &stmt, args[0..n], battle)) {
                    try cands.append(a, .{ .at = at, .key = key, .line = stmt.items, .place = true });
                } else code.* += 1;
                continue;
            }
            if (tile and n >= 3 and n <= 4 and args[1] == .int and args[2] == .int and (n == 3 or args[3] == .int)) {
                try stmt.print(a, "tile = [{d}, {d}", .{ args[1].int, args[2].int });
                if (n == 4 and args[3].int != 0) try stmt.print(a, ", {d}", .{args[3].int});
                try stmt.appendSlice(a, "];");
            } else if (prop and n == 4 and numeric(args[1]) and numeric(args[2]) and numeric(args[3])) {
                try stmt.appendSlice(a, "at = [");
                for (args[1..4], 0..) |v, k| {
                    if (k > 0) try stmt.appendSlice(a, ", ");
                    try literal(a, &stmt, v);
                }
                try stmt.appendSlice(a, "];");
            }
            if (stmt.items.len == 0 or !self.actors.contains(key)) {
                code.* += 1;
                continue;
            }
            try cands.append(a, .{ .at = at, .key = key, .line = stmt.items, .place = false });
        }
        var all_data = true;
        for (cands.items) |x| {
            if (seen.get(x.key).? > 1) {
                code.* += 1;
                all_data = false;
                continue;
            }
            try drop.put(a, x.at, {});
            if (x.place) {
                try placement.print(a, "{s}{s}", .{ if (placement.items.len > 0) ", " else "", x.line });
            } else try self.tiles.put(a, x.key, x.line);
            data.* += 1;
        }
        // A placing left code before it would run after it.
        if (at_entry) |x| if (all_data) {
            try drop.put(a, x.at, {});
            entry.* = x.point;
            self.report.entry_data += 1;
        } else {
            code.* += 1;
        };
    }

    /// Object `name`'s `.var` (`common/other.dat: variables\<name>.var`) over `state`, as
    /// the runtime applies it (Runtime.applyVar).
    fn applyVars(self: *Conv, state: *std.ArrayList(Slot), name: []const u8, host: ?script.classic.names.Host) !void {
        var buf: [archive.name_size]u8 = undefined;
        const common = &self.common.?;
        const e = common.find(try std.fmt.bufPrint(&buf, "variables\\{s}.var", .{name})) orelse return;
        const text = try common.readAlloc(self.io, self.a, e);
        var v = try formats.vars.parse(self.a, text);
        for (v.entries) |x| {
            const s = slotOf(state.items, script.classic.names.engine(host, x.key)) orelse continue;
            s.value = Value.parse(x.value, s.type) orelse continue;
        }
        _ = &v;
    }

    /// The look of `lk` (an actor of `file`): its model's fields from `state`, its
    /// calls; one block for every actor with the same (named by its `act_*.ss`).
    fn look(self: *Conv, lk: *LookB, state: []const Slot, file: []const u8) ![]const u8 {
        const a = self.a;
        var body: std.ArrayList(u8) = .empty;
        for ([_][]const u8{ "mesh", "portrait", "turn_speed" }) |f| if (slotOf(@constCast(state), f)) |s| if (s.value != .nil) {
            try body.print(a, "    {s} = ", .{f});
            try literal(a, &body, s.value);
            try body.appendSlice(a, ";\n");
            try lk.fields.append(a, .{ .name = f, .type = s.type, .value = s.value });
        };
        // A hero's pose lifted by an enemy (the slot `lifted`, combat/attack.zig): the exe's
        // by classic_id (modules.liftPose), its raw animation name as the exe plays it.
        if (std.ascii.endsWithIgnoreCase(file, ".hro")) {
            const id = if (slotOf(@constCast(state), "classic_id")) |s| (if (s.value == .int) s.value.int else 0) else 0;
            const args = try a.dupe(Value, &.{ .{ .int = 0 }, .{ .string = @import("../actor.zig").slots.lifted }, .{ .string = core.modules.liftPose(.{ .id = id }) } });
            try lk.calls.append(a, .{ .name = "RegisterAnimation", .args = args });
        }
        try lk.text(a, &body);
        for (self.looks.items) |l| if (std.mem.eql(u8, l.body, body.items)) return l.name;
        // Its name: the act_*.ss it came from (`act_grandma.ss` → grandma), else the object's.
        var base = try ogsify.ident(a, std.fs.path.stem(lk.origin orelse file));
        if (std.ascii.startsWithIgnoreCase(base, "act_")) base = base[4..];
        var n = base;
        var i: usize = 2;
        while (for (self.looks.items) |l| {
            if (std.ascii.eqlIgnoreCase(l.name, n)) break true;
        } else false) : (i += 1) n = try std.fmt.allocPrint(a, "{s}_{d}", .{ base, i });
        try self.looks.append(a, .{ .name = n, .body = body.items });
        self.report.looks += 1;
        return n;
    }

    /// The model (`mesh`) of block `e`'s look (`look = looks::x`); null: none.
    fn lookMesh(self: *const Conv, e: *const ir.Entity) ?[]const u8 {
        const v = fieldOf(e, "look") orelse return null;
        const w = if (v.kind == .word) v.kind.word else return null;
        const n = if (std.mem.startsWith(u8, w, "looks::")) w["looks::".len..] else return null;
        for (self.looks.items) |l| if (std.mem.eql(u8, l.name, n)) {
            const k = std.mem.indexOf(u8, l.body, "mesh = \"") orelse return null;
            const s0 = k + "mesh = \"".len;
            return l.body[s0 .. std.mem.indexOfScalarPos(u8, l.body, s0, '"') orelse return null];
        };
        return null;
    }

    fn lookModule(self: *Conv) !void {
        var m: Module = .{ .path = "looks" };
        for (self.looks.items) |l| try m.data.writer.print("look {s} {{\n{s}}}\n", .{ l.name, l.body });
        try self.addModule(&m);
    }

    // ------------------------------------------------------------ scenes, dialogs, rules

    /// `common/other.dat: scriptlets\<name>.scr` (+ `.pts`) → `scene "<name>"`.
    fn scenes(self: *Conv) !void {
        const a = self.a;
        const common = &self.common.?;
        var m: Module = .{ .path = "" };
        const w = &m.data.writer;
        var n: usize = 0;
        for (common.entries) |*e| {
            if (!std.ascii.startsWithIgnoreCase(e.name, "scriptlets\\") or !std.ascii.endsWithIgnoreCase(e.name, ".scr")) continue;
            const name = e.name["scriptlets\\".len .. e.name.len - 4];
            const cmds = formats.scriptlet.parse(a, try common.readAlloc(self.io, a, e)) catch |err| {
                try self.line("scene {s}: {t}", .{ name, err });
                continue;
            };
            var buf: [archive.name_size]u8 = undefined;
            const pts = if (common.find(try std.fmt.bufPrint(&buf, "scriptlets\\{s}.pts", .{name}))) |pe| formats.scriptlet.parsePoints(a, try common.readAlloc(self.io, a, pe)) catch &.{} else &.{};
            try w.writeAll("scene ");
            try nameOrString(w, name);
            try w.writeAll(" {\n");
            if (pts.len > 0) {
                try w.writeAll("    points = [");
                for (pts, 0..) |p, i| {
                    var l: std.ArrayList(u8) = .empty;
                    try l.print(a, "{s}Point(name = ", .{if (i > 0) ", " else ""});
                    try literal(a, &l, .{ .string = try utf8(a, p.name, self.page) });
                    for ([_]struct { []const u8, f32 }{ .{ "x", p.x }, .{ "y", p.y }, .{ "angle", p.angle } }) |f| {
                        try l.print(a, ", {s} = ", .{f[0]});
                        try literal(a, &l, .{ .float = f[1] });
                    }
                    try w.print("{s})", .{l.items});
                }
                try w.writeAll("];\n");
            }
            for (cmds) |c| try self.sceneLine(w, name, c);
            try w.writeAll("}\n");
            n += 1;
            try self.progress.tell(.scenes, n, 0);
        }
        self.report.scenes = n;
        try self.addModule(&m);
    }

    /// Classic scene command `c` as an OpenGorky scene's line (core/scene.zig `commands`):
    /// OG Script's name (`actor::WalkTo`; the glued typo `FADE_INDIALOG_DISPLAY` as the exe
    /// runs it, FADE_IN), a pair's by its flag (`camera::Panorama(true)`), each argument by
    /// its kind (`@Sullivan`, `@hero::selected`, seconds, `true`, `~d"port"`).
    fn sceneLine(self: *Conv, w: *Writer, scene: []const u8, c: formats.scriptlet.Command) !void {
        const a = self.a;
        // One the exe does not know is a "Syntax error" there: it never runs (scene/scenario.zig).
        const cmd = core.scene.ofExe(core.scene.exeMatch(c.name)) orelse return self.line("scene {s}: {s} is no scene command (the exe skips it): dropped", .{ scene, c.name });
        try w.print("    {s}(", .{cmd.ogs});
        var n: usize = 0;
        const sep = struct {
            fn put(wr: *Writer, k: *usize) !void {
                if (k.* > 0) try wr.writeAll(", ");
                k.* += 1;
            }
        }.put;
        for (c.args, 0..) |x0, i| {
            const kind: ?core.scene.Kind = if (i < cmd.args.len) .of(cmd.args[i]) else null;
            if (kind == .dropped) continue;
            // A number written as a string (`"10\""`) is the number the exe reads (atof).
            const is_num = if (kind) |k| switch (k) {
                .bool, .not, .given, .ticks, .centis, .percent, .int, .number, .line, .state => true,
                else => false,
            } else false;
            const x: formats.scriptlet.Arg = if (is_num and x0 == .string) .{ .number = (core.scene.Arg{ .string = x0.string }).num() } else x0;
            var l: std.ArrayList(u8) = .empty;
            switch (x) {
                .string => |str| if (kind == .actor or kind == .object) {
                    const name = try utf8(a, str, self.page);
                    // The runner reads its placeholders in any argument (scene/scenario.zig).
                    const p = core.scene.ogsActor(name);
                    if (p.ptr != name.ptr) try l.print(a, "@{s}", .{p}) else try ref(a, &l, name);
                } else if (kind == .dialog) {
                    // Its block's name (the `.dlg`'s, lower case); one the game lacks as written.
                    const t = try utf8(a, str, self.page);
                    const stem = try std.ascii.allocLowerString(a, if (std.ascii.endsWithIgnoreCase(t, ".dlg")) t[0 .. t.len - 4] else t);
                    if (self.dialog_names.contains(stem)) try l.appendSlice(a, "~d");
                    try literal(a, &l, .{ .string = if (self.dialog_names.contains(stem)) stem else t });
                } else if (kind != null and kind.?.sigil() != 0) {
                    try l.print(a, "~{c}", .{kind.?.sigil()});
                    try literal(a, &l, .{ .string = try utf8(a, str, self.page) });
                } else if (i == 1 and std.ascii.eqlIgnoreCase(cmd.exe, "GO_RUNFUN")) {
                    // GO_RUNFUN(obj, "init"): the function by its event's name.
                    try literal(a, &l, .{ .string = ogsify.renamedEvent(str) orelse str });
                } else try sceneLiteral(a, &l, x, self.page),
                .number => |f| if (kind) |k| switch (k) {
                    .bool, .not => try l.appendSlice(a, if ((f != 0) != (k == .not)) "true" else "false"),
                    .given => try l.appendSlice(a, "true"),
                    // The exe's whole ticks (_ftol) in hundredths of a second: they read back the same.
                    .ticks => try seconds(a, &l, @round(@as(f64, @floatFromInt((core.scene.Arg{ .number = f }).int())) * 100 / core.scene.ticks_per_second) / 100),
                    .centis, .percent => try seconds(a, &l, @as(f64, f) / 100),
                    else => try sceneLiteral(a, &l, x, self.page),
                } else try sceneLiteral(a, &l, x, self.page),
            }
            try sep(w, &n);
            try w.writeAll(l.items);
        }
        // DISABLEOBJECT(obj) disables it: `object::Enable(@obj, false)`.
        for (cmd.args[@min(c.args.len, cmd.args.len)..]) |k| if (k == @backingInt(core.scene.Kind.not)) {
            try sep(w, &n);
            try w.writeAll("false");
        };
        if (cmd.flag) |on| {
            try sep(w, &n);
            try w.writeAll(if (on) "true" else "false");
        }
        try w.writeAll(");\n");
    }

    /// Seconds or a factor `x`: whole as an int (`scene::Wait(1)`), else `0.33`.
    fn seconds(a: Allocator, l: *std.ArrayList(u8), x: f64) !void {
        try literal(a, l, if (x == @trunc(x) and @abs(x) < 1e9) .{ .int = @intFromFloat(x) } else .{ .float = @floatCast(x) });
    }

    /// A scene argument as written: a string in UTF-8, a whole number as one.
    fn sceneLiteral(a: Allocator, l: *std.ArrayList(u8), x: formats.scriptlet.Arg, page: formats.cp1251.Page) !void {
        try literal(a, l, switch (x) {
            .string => |str| .{ .string = try utf8(a, str, page) },
            .number => |f| if (f == @trunc(f) and @abs(f) < 1e9) .{ .int = @intFromFloat(f) } else .{ .float = f },
        });
    }

    /// `common/lang.dat: *.dlg` → `dialog "<name>"` of `Line(who, text, voice, cam)` (the
    /// edition's cut made once, the voice of each line named, texts UTF-8).
    fn dialogs(self: *Conv) !void {
        const a = self.a;
        const gpa = std.heap.page_allocator;
        var lang = try archive.Archive.open(self.io, gpa, self.dat, "common/lang.dat");
        defer lang.close(self.io, gpa);
        const language: u8 = blk: {
            const e = lang.find("string.tab") orelse break :blk 0;
            var t = formats.strtab.parseStrings(gpa, try lang.readAlloc(self.io, a, e)) catch break :blk 0;
            defer t.deinit(gpa);
            break :blk formats.strtab.language(t);
        };
        self.language = language;
        // Before any text: dialogs come first, then scenes and texts.
        self.page = formats.cp1251.forLanguage(language);
        var m: Module = .{ .path = "" };
        const w = &m.data.writer;
        var n: usize = 0;
        for (lang.entries) |*e| {
            if (!std.ascii.endsWithIgnoreCase(e.name, ".dlg")) continue;
            const d = try formats.dialog.parseCut(a, try lang.readAlloc(self.io, a, e), formats.dialog.editionCut(e.name, language));
            try self.dialog_names.put(a, try std.ascii.allocLowerString(a, e.name[0 .. e.name.len - 4]), {});
            try w.writeAll("dialog ");
            try nameOrString(w, e.name[0 .. e.name.len - 4]);
            try w.writeAll(" {\n");
            for (d.lines, 0..) |l, i| {
                var s: std.ArrayList(u8) = .empty;
                try s.appendSlice(a, "Line(who = ");
                try literal(a, &s, .{ .string = try utf8(a, l.speaker, self.page) });
                try s.appendSlice(a, ", text = ");
                try literal(a, &s, .{ .string = try utf8(a, l.text, self.page) });
                var vb: [96]u8 = undefined;
                // A voice the game lacks stays out (Classic looks it up and plays nothing).
                if (formats.dialog.voiceName(&vb, e.name, l.code, d.voiceIndex(i))) |v| {
                    const path = try std.fmt.allocPrint(a, "voice/{s}", .{v});
                    if (self.stack.?.exists(path)) {
                        try s.appendSlice(a, ", voice = ~s");
                        try literal(a, &s, .{ .string = path });
                    }
                } else |_| {}
                if (l.cam) |c| try s.print(a, ", cam = [{d}, {d}]", .{ c[0], c[1] });
                try w.print("    {s});\n", .{s.items});
            }
            try w.writeAll("}\n");
            n += 1;
            try self.progress.tell(.dialogs, n, 0);
        }
        self.report.dialogs = n;
        try self.addModule(&m);
    }

    /// `common/lang.dat`'s texts (one language, UTF-8): `string.tab`,
    /// `items.inf`, `activeareas.inf`, each by number (the reader's entity.texts as
    /// Classic's). A number a block's own `classic_id` has goes onto each such block
    ///: `name = "…"` its `string.tab`
    /// line, `examine = "…"` its `items.inf` text (an area's: `activeareas.inf`), right
    /// after the `classic_id` (an instance inheriting the number has them by its archetype).
    /// The rest stay rows `UiText(id, text)`, `Examine(id, text)`, `AreaExamine(id, text)`
    /// in number order: the interface's words, texts no block names.
    fn texts(self: *Conv) !void {
        const a = self.a;
        const gpa = std.heap.page_allocator;
        var lang = try archive.Archive.open(self.io, gpa, self.dat, "common/lang.dat");
        defer lang.close(self.io, gpa);
        const files = [_]struct { []const u8, []const u8, ?[]const u8 }{ .{ "string.tab", "UiText", null }, .{ "items.inf", "Examine", "ITEM_EXAMINE:" }, .{ "activeareas.inf", "AreaExamine", "AREA_EXAMINE:" } };
        var maps: [files.len]std.AutoArrayHashMapUnmanaged(i32, []const u8) = @splat(.empty);
        for (files, &maps) |f, *map| {
            const e = lang.find(f[0]) orelse continue;
            const bytes = try lang.readAlloc(self.io, a, e);
            var t = if (f[2]) |key| try formats.strtab.parseExamineKey(gpa, a, bytes, key) else try formats.strtab.parseStrings(gpa, bytes);
            defer t.deinit(gpa);
            var it = t.map.iterator();
            while (it.next()) |kv| try map.put(a, kv.key_ptr.*, try utf8(a, kv.value_ptr.*, self.page));
            self.report.texts += t.map.count();
        }
        // Onto the blocks; what a block took leaves its table.
        var used: [files.len]std.AutoHashMapUnmanaged(i32, void) = @splat(.empty);
        for (self.modules.items) |m| try textsOnto(a, m.entities, &maps, &used, &self.report.texts_on);
        var out: std.ArrayList(u8) = .empty;
        for (files, &maps, &used) |f, *map, *u| {
            const ids = try a.dupe(i32, map.keys());
            std.mem.sort(i32, ids, {}, std.sort.asc(i32));
            for (ids) |id| {
                if (u.contains(id)) continue;
                // An interface text the code names: by its key (core/ui_text.zig), no number.
                if (std.mem.eql(u8, f[1], "UiText")) if (core.ui_text.keyOf(id)) |k| {
                    try out.print(a, "{s}(key = \"{t}\", text = ", .{ f[1], k });
                    try literal(a, &out, .{ .string = map.get(id).? });
                    try out.appendSlice(a, ");\n");
                    continue;
                };
                try out.print(a, "{s}(id = {d}, text = ", .{ f[1], id });
                try literal(a, &out, .{ .string = map.get(id).? });
                try out.appendSlice(a, ");\n");
            }
        }
        var diag: parser.Diagnostic = .{};
        const u = parser.parse(a, out.items, "texts", &diag) catch |err| {
            try self.line("texts:{d}: {s}", .{ diag.line, diag.message });
            return err;
        };
        try self.modules.append(a, .{ .path = "", .uses = &.{}, .fns = &.{}, .components = &.{}, .entities = &.{}, .rows = u.modules[0].rows });
    }

    /// The rules in force: each `rules\<name>.ss` as OG Script rows (hooks.ss, a commented
    /// `component Hooks for game`, has none).
    fn parseRules(self: *Conv, files: []const archive.File) ![]const *const ir.Expr {
        var rows: std.ArrayList(*const ir.Expr) = .empty;
        for (files) |f| {
            var diag: parser.Diagnostic = .{};
            const u = parser.parse(self.a, f.data, f.name, &diag) catch {
                try self.line("rules {s}:{d}: {s}", .{ f.name, diag.line, diag.message });
                continue;
            };
            for (u.modules) |x| try rows.appendSlice(self.a, x.rows);
        }
        return rows.items;
    }

    /// Module `m`: its data text parsed (the blocks), its components as made.
    fn addModule(self: *Conv, m: *Module) !void {
        const text = m.data.written();
        var entities: []const ir.Entity = &.{};
        if (text.len > 0) {
            var diag: parser.Diagnostic = .{};
            const u = parser.parse(self.a, text, m.path, &diag) catch |err| {
                try self.line("{s}:{d}: {s} ({t})", .{ m.path, diag.line, diag.message, err });
                return err;
            };
            entities = u.modules[0].entities;
        }
        if (m.blocks_at_root) {
            try self.modules.append(self.a, .{ .path = "", .uses = &.{}, .fns = &.{}, .components = &.{}, .entities = entities, .rows = &.{} });
            entities = &.{};
        }
        try self.modules.append(self.a, .{ .path = m.path, .uses = &.{}, .fns = &.{}, .components = m.comps.items, .entities = entities, .rows = &.{} });
    }
    // ------------------------------------------------------------ archetypes of instances

    /// The `kind` objects of the locations made of one Classic entity script (`prefix`
    /// `ft_`/`wp_`: `ft_garcia.ss`, `inst_arch`) folded into one archetype each of module
    /// `ns` (`characters::garcia`, `weapons::garcialong`): it
    /// holds each field every instance sets, with the value more than half of them have,
    /// their variables and their component when all have the same; each instance becomes
    /// `fighter "01bg_garcia1": characters::garcia { … }` with only what differs. The OG
    /// reader applies the archetype's variables, fields and components before the
    /// instance's (world/start.zig applyChain), over the same look: the same start state.
    /// A fighter's weapons right after it, named `<fighter>_<x>` and owned by it, become the
    /// archetype's nested blocks `weapon x` when every instance has the same: the reader
    /// makes them right after the fighter as `<fighter>_<x>`, owned by it (the same objects
    /// in the same order).
    fn fold(self: *Conv, kind: []const u8, prefix: []const u8, ns: []const u8) !void {
        const a = self.a;
        var groups: Groups = .empty;
        for (self.modules.items) |*m| if (m.path.len == 0) for (@constCast(m.entities)) |*lev| if (isLevelKind(lev.kind)) {
            for (@constCast(lev.children)) |*c| if (std.mem.eql(u8, c.kind, kind)) {
                const st = self.inst_arch.get(try instKey(a, lev.name, c.name)) orelse continue;
                const g = try groups.getOrPut(a, try std.ascii.allocLowerString(a, st));
                if (!g.found_existing) g.value_ptr.* = .{ .name = g.key_ptr.*[prefix.len..] };
                try g.value_ptr.ms.append(a, .{ .lev = lev, .e = c });
            };
        };
        try self.foldGroups(kind, ns, &groups, false);
    }

    /// Each area trigger of a level's OnUpdate (`if (readyF02 and hero::AnyInArea("fight2_place"))
    /// { … }`) into a component of its own named after the area, attached to the level, in a
    /// text of its own beside it (`locations/01_port/fight2_place.ogs`: a trigger's code
    /// by its area). The `if` moves whole into the component's
    /// method of the same name; OnUpdate calls it where the `if` was (`host.fight2_place();`):
    /// the same checks, in the same order, on the same tick. The area stays a polygon of the
    /// map (no new object: nothing it would show or answer). After `splitClasses`, which
    /// writes the Logic's methods anew.
    fn triggersOut(self: *Conv) !void {
        const a = self.a;
        for (self.triggers.items) |tr| {
            const logic = @constCast(tr.logic);
            const ms = try a.dupe(*const ir.Fn, logic.methods);
            for (ms) |*mf| if (std.mem.eql(u8, mf.*.name, "OnUpdate")) {
                const body = try a.dupe(ir.Stmt, mf.*.body);
                var k: usize = 0;
                var comps: std.ArrayList(*const ir.Component) = .empty;
                for (body) |*st| {
                    if (triggerArea(st.*) == null) continue;
                    if (k >= tr.names.len) break;
                    const name = tr.names[k];
                    k += 1;
                    const f = try a.create(ir.Fn);
                    f.* = .{ .name = name, .file = mf.*.file, .line = st.line, .params = &.{}, .slots = mf.*.slots, .body = try a.dupe(ir.Stmt, &.{st.*}), .names = mf.*.names, .ogs = true };
                    const c = try a.create(ir.Component);
                    c.* = .{ .name = name, .module = logic.module, .hosts = logic.hosts, .fields = &.{}, .methods = try a.dupe(*const ir.Fn, &.{f}), .line = 0 };
                    try comps.append(a, c);
                    const host = try a.create(ir.Expr);
                    host.* = .{ .line = st.line, .kind = .host };
                    const call = try a.create(ir.Method);
                    call.* = .{ .obj = host, .id = try object.intern(name), .text = name, .args = &.{} };
                    const e = try a.create(ir.Expr);
                    e.* = .{ .line = st.line, .kind = .{ .method = call } };
                    st.* = .{ .file = st.file, .line = st.line, .kind = .{ .expr = e } };
                }
                if (comps.items.len == 0) continue;
                const nf = try a.create(ir.Fn);
                nf.* = mf.*.*;
                nf.body = body;
                mf.* = nf;
                logic.methods = ms;
                // Into the namespace beside the Logic, attached to the level block.
                for (self.modules.items) |*m| if (std.mem.eql(u8, m.path, tr.ns)) for (m.components) |c| if (c == tr.logic) {
                    m.components = try std.mem.concat(a, *const ir.Component, &.{ m.components, comps.items });
                    break;
                };
                for (self.modules.items) |*m| if (m.path.len == 0) for (@constCast(m.entities)) |*e| if (std.mem.eql(u8, e.kind, tr.kind) and std.mem.eql(u8, e.name, tr.level)) {
                    var at: std.ArrayList(ir.Attach) = .empty;
                    try at.appendSlice(a, e.attach);
                    for (comps.items) |c| try at.append(a, .{ .component = try std.fmt.allocPrint(a, "{s}::{s}", .{ tr.ns, c.name }), .params = &.{}, .line = e.line });
                    e.attach = at.items;
                };
                self.report.triggers += comps.items.len;
            };
        }
    }

    /// Each location's hero of its own `.hro` (`01_port`'s bt, `04_city`'s kozov: a character
    /// met there who may join) as a character `characters::<name>` (a hero's description is the character's, not
    /// the level's): its fields,
    /// variables and component there, where it stands the instance's.
    fn foldHeroes(self: *Conv) !void {
        const a = self.a;
        var groups: Groups = .empty;
        for (self.modules.items) |*m| if (m.path.len == 0) for (@constCast(m.entities)) |*lev| if (isLevelKind(lev.kind)) {
            for (@constCast(lev.children)) |*c| if (std.mem.eql(u8, c.kind, "hero") and c.base.len == 0) {
                const k = try instKey(a, lev.name, c.name);
                if (!self.heroes.contains(k)) continue;
                var g: Group = .{ .name = c.name, .alts = try a.dupe([]const u8, &.{try std.fmt.allocPrint(a, "{s}_hero", .{c.name})}) };
                try g.ms.append(a, .{ .lev = lev, .e = c });
                try groups.put(a, k, g);
            };
        };
        try self.foldGroups("hero", "characters", &groups, true);
    }

    /// The locations' own `kind` objects (item, weapon: no archetype yet, `fold`'s are)
    /// with the same `classic_id`, two or more, folded the same way into one archetype each
    /// of module `ns`: their number and its texts (`name`,
    /// `examine`: `texts` puts them on the block owning the number) once, on it. Named
    /// after the objects (`box_01_itm`, `box_02_itm` → `box`; `03mf_matrix`, `04c_matrix`
    /// → `matrix`; else `item_75`); where they stand stays each one's.
    fn foldPlaced(self: *Conv, kind: []const u8, ns: []const u8) !void {
        const a = self.a;
        var groups: Groups = .empty;
        for (self.modules.items) |*m| if (m.path.len == 0) for (@constCast(m.entities)) |*lev| if (isLevelKind(lev.kind)) {
            for (@constCast(lev.children)) |*c| if (std.mem.eql(u8, c.kind, kind) and c.base.len == 0) {
                const id = schema.int(fieldOf(c, "classic_id") orelse continue) orelse continue;
                // −1: no number (an actor's), nothing shared.
                if (id <= 0) continue;
                const g = try groups.getOrPut(a, try std.fmt.allocPrint(a, "{d}", .{id}));
                if (!g.found_existing) g.value_ptr.* = .{ .name = "" };
                try g.value_ptr.ms.append(a, .{ .lev = lev, .e = c });
            };
        };
        var many: Groups = .empty;
        for (groups.keys(), groups.values()) |id, *g| if (g.ms.items.len > 1) {
            var names: std.ArrayList([]const u8) = .empty;
            var meshes: std.ArrayList([]const u8) = .empty;
            for (g.ms.items) |x| {
                try names.append(a, x.e.name);
                if (fieldOf(x.e, "mesh")) |v| (if (schema.text(v)) |t| try meshes.append(a, t)) else if (self.lookMesh(x.e)) |t| try meshes.append(a, t);
            }
            // Then the model most have (`nato`), then the number (`actor_25`).
            const tried = try std.mem.concat(a, []const u8, &.{ try placedNames(a, names.items), if (meshes.items.len * 2 > g.ms.items.len) if (majority(meshes.items)) |m| &.{m} else &.{} else &.{}, &.{try std.fmt.allocPrint(a, "{s}_{s}", .{ kind, id })} });
            g.name = tried[0];
            g.alts = tried[1..];
            try many.put(a, id, g.*);
        };
        try self.foldGroups(kind, ns, &many, true);
    }

    /// `alts`: the names to try, in order, when `name` is taken (`foldPlaced`).
    const Group = struct { name: []const u8, alts: []const []const u8 = &.{}, ms: std.ArrayList(Member) = .empty };
    const Groups = std.StringArrayHashMapUnmanaged(Group);

    /// `fold`'s and `foldPlaced`'s groups (each its archetype's name to be) folded; `placed`:
    /// a location's own objects, whose position fields stay theirs.
    fn foldGroups(self: *Conv, kind: []const u8, ns: []const u8, groups: *const Groups, placed: bool) !void {
        const a = self.a;
        if (groups.count() == 0) return;
        var archs: std.ArrayList(ir.Entity) = .empty;
        var comps: std.ArrayList(*const ir.Component) = .empty;
        var gone: std.AutoHashMapUnmanaged(*const ir.Component, void) = .empty;
        var dropped: std.AutoHashMapUnmanaged(*const ir.Entity, void) = .empty;
        for (groups.values()) |g| {
            const ms = g.ms.items;
            const name = try self.archName(ns, kind, g.name, g.alts, archs.items);
            const base = try std.fmt.allocPrint(a, "{s}::{s}", .{ ns, name });
            var arch: ir.Entity = .{ .kind = kind, .name = name, .fields = &.{}, .attach = &.{}, .line = 1 };
            // Fields: each every instance sets, the value most have.
            var fs: std.ArrayList(ir.Named) = .empty;
            for (ms[0].e.fields) |f| {
                if (instanceField(f.name) or (placed and placedField(f.name))) continue;
                var best: ?*const ir.Expr = null;
                var best_n: usize = 0;
                for (ms) |x| {
                    const v = fieldOf(x.e, f.name) orelse break;
                    var n: usize = 0;
                    for (ms) |y| if (fieldOf(y.e, f.name)) |u| if (try sameExpr(a, u, v)) {
                        n += 1;
                    };
                    if (n > best_n) {
                        best = v;
                        best_n = n;
                    }
                } else if (best_n * 2 > ms.len) try fs.append(a, .{ .name = f.name, .value = best.? });
            }
            arch.fields = fs.items;
            for (ms) |x| {
                var own: std.ArrayList(ir.Named) = .empty;
                for (x.e.fields) |f| {
                    if (fieldOfList(fs.items, f.name)) |v| if (try sameExpr(a, v, f.value)) {
                        self.report.inherited += 1;
                        continue;
                    };
                    try own.append(a, f);
                }
                x.e.fields = own.items;
                x.e.base = base;
            }
            // Variables: when all have the same (their order kept).
            const vt = try varsText(a, ms[0].e.vars);
            for (ms[1..]) |x| {
                if (!std.mem.eql(u8, vt, try varsText(a, x.e.vars))) break;
            } else {
                arch.vars = ms[0].e.vars;
                for (ms) |x| x.e.vars = &.{};
            }
            // The component: when each has one, the same but its name.
            if (try self.sharedComponent(ms)) |c| {
                const nc = try a.create(ir.Component);
                nc.* = c.*;
                nc.name = try self.compName(ns, name);
                nc.module = ns;
                try comps.append(a, nc);
                arch.attach = try a.dupe(ir.Attach, &.{.{ .component = nc.name, .params = &.{}, .line = 1 }});
                for (ms) |x| {
                    try gone.put(a, self.componentOf(x.e.attach[0].component).?, {});
                    x.e.attach = &.{};
                }
                self.report.components -= ms.len - 1;
            }
            // A fighter's weapons, a barrel's blast (`01b2_barrel1_explode`).
            if (std.mem.eql(u8, kind, "fighter") or std.mem.eql(u8, kind, "obstacle")) arch.children = try self.nestWeapons(ms, &dropped);
            try archs.append(a, arch);
            self.report.archetypes += 1;
        }
        // The folded components leave their locations' namespaces, the nested weapons their levels.
        for (self.modules.items) |*m| {
            var cs: std.ArrayList(*const ir.Component) = .empty;
            for (m.components) |c| if (!gone.contains(c)) try cs.append(a, c);
            m.components = cs.items;
            if (m.path.len == 0) for (@constCast(m.entities)) |*lev| if (isLevelKind(lev.kind)) {
                var kids: std.ArrayList(ir.Entity) = .empty;
                for (lev.children) |*c| if (!dropped.contains(c)) try kids.append(a, c.*);
                lev.children = kids.items;
            };
        }
        try self.modules.append(a, .{ .path = ns, .uses = &.{}, .fns = &.{}, .components = comps.items, .entities = archs.items, .rows = &.{} });
    }

    /// The weapons of fighters `ms` (anywhere in its level, owned by it, `<fighter>_<x>`; the
    /// owner's name any case, as the exe finds objects) as the archetype's nested blocks
    /// `weapon x` (their `owner` the reader's): the set most of them have. A fighter with
    /// that set keeps none of its own; one with the same names, some other (`weapon a:
    /// weapons::c_nato_cpt`), its differing ones nested in it (they take the inherited
    /// ones' place). Those objects into `dropped`. A fighter with other names or none: no
    /// nesting (an inherited weapon cannot be taken away).
    fn nestWeapons(self: *Conv, ms: []const Member, dropped: *std.AutoHashMapUnmanaged(*const ir.Entity, void)) ![]const ir.Entity {
        const a = self.a;
        const Own = struct { list: []const ir.Entity, objs: []const *const ir.Entity, texts: []const []const u8, sig: []const u8 };
        const owns = try a.alloc(Own, ms.len);
        for (ms, owns) |x, *o| {
            var list: std.ArrayList(ir.Entity) = .empty;
            var objs: std.ArrayList(*const ir.Entity) = .empty;
            var shown: std.ArrayList([]const u8) = .empty;
            var sig: std.ArrayList(u8) = .empty;
            for (x.lev.children) |*c| {
                if (!std.mem.eql(u8, c.kind, "weapon") or !ownedBy(c.*, x.e.name)) continue;
                const n = x.e.name;
                if (c.name.len < n.len + 2 or !std.ascii.startsWithIgnoreCase(c.name, n) or c.name[n.len] != '_') return &.{};
                var nc = c.*;
                nc.name = c.name[n.len + 1 ..];
                var fs: std.ArrayList(ir.Named) = .empty;
                for (c.fields) |f| if (!std.mem.eql(u8, f.name, "owner")) try fs.append(a, f);
                nc.fields = fs.items;
                var w: std.Io.Writer.Allocating = .init(a);
                try print_ogs.entity(&w.writer, nc, 0);
                try list.append(a, nc);
                try objs.append(a, c);
                try shown.append(a, w.written());
                try sig.appendSlice(a, w.written());
            }
            o.* = .{ .list = list.items, .objs = objs.items, .texts = shown.items, .sig = sig.items };
        }
        // The set most have (the first of equals).
        var best: ?usize = null;
        var best_n: usize = 0;
        for (owns, 0..) |o, i| {
            if (o.list.len == 0) continue;
            var n: usize = 0;
            for (owns) |p| n += @intFromBool(std.mem.eql(u8, p.sig, o.sig));
            if (n > best_n) {
                best = i;
                best_n = n;
            }
        }
        const set = owns[best orelse return &.{}].list;
        // Each fighter: the same names in the same order, else none nested.
        for (owns) |o| {
            if (o.list.len != set.len) return &.{};
            for (o.list, set) |x, y| if (!std.mem.eql(u8, x.name, y.name)) return &.{};
        }
        const base = owns[best.?];
        for (ms, owns) |x, o| {
            var own: std.ArrayList(ir.Entity) = .empty;
            for (o.list, o.texts, base.texts) |w, t, bt| if (!std.mem.eql(u8, t, bt)) try own.append(a, w);
            if (own.items.len > 0) x.e.children = try std.mem.concat(a, ir.Entity, &.{ x.e.children, own.items });
            for (o.objs) |c| try dropped.put(a, c, {});
        }
        self.report.nested += set.len * ms.len;
        return set;
    }

    /// The one component every instance of `ms` attaches (no parameters), when it is the
    /// same for all but its name; null: not so.
    fn sharedComponent(self: *Conv, ms: []const Member) !?*const ir.Component {
        var text: []const u8 = "";
        var first: ?*const ir.Component = null;
        for (ms) |x| {
            if (x.e.attach.len != 1 or x.e.attach[0].params.len > 0) return null;
            const c = self.componentOf(x.e.attach[0].component) orelse return null;
            var nc = c.*;
            nc.name = "";
            var w: std.Io.Writer.Allocating = .init(self.a);
            try print_ogs.component(&w.writer, &nc, 0);
            if (first == null) {
                first = c;
                text = w.written();
            } else if (!std.mem.eql(u8, text, w.written())) return null;
        }
        return first;
    }

    /// The component an attach names (`battles::_01__port_barge::_01bg_garcia1`).
    fn componentOf(self: *Conv, p: []const u8) ?*const ir.Component {
        const k = std.mem.lastIndexOf(u8, p, "::") orelse return null;
        for (self.modules.items) |m| if (std.mem.eql(u8, m.path, p[0..k])) for (m.components) |c| if (std.mem.eql(u8, c.name, p[k + 2 ..])) return c;
        return null;
    }

    /// Rules rows `rows` keyed by archetypes: a key
    /// `fighter`/`weapon`/`hero`/… number N (`ref_keys`) becomes `~c"characters::garcia"`
    /// when the objects with classic_id N are exactly those of some archetypes (one row
    /// each), and an Abilities row by battle class C (no fighter) `fighter =
    /// ~c"…", class = 0` when the fighters of class C are exactly some archetypes'
    /// and none of them has a row of its own (an own row beats the class's; two own rows
    /// would pick another). The OG reader matches a class key by the object's archetype
    /// (rules.who: its class is its archetype's path), above a number: an object matches
    /// the same rows as before. The rest stays by number.
    fn keyRefs(self: *Conv, rows: []const *const ir.Expr) ![]const *const ir.Expr {
        const a = self.a;
        var ix: Idents = .{ .a = a };
        for (self.modules.items) |m| for (m.entities) |*e| try ix.tops.put(a, try std.fmt.allocPrint(a, "{s} {s}{s}{s}", .{ e.kind, m.path, if (m.path.len > 0) "::" else "", e.name }), e);
        for (self.modules.items) |m| try ix.walk(m.path, m.entities);
        var out: std.ArrayList(*const ir.Expr) = .empty;
        for (rows) |r| {
            if (r.kind != .call) {
                try out.append(a, r);
                continue;
            }
            const c = r.kind.call;
            const keys = for (ref_keys) |k| {
                if (std.mem.eql(u8, k[0], c.text)) break k[1];
            } else {
                try out.append(a, r);
                continue;
            };
            // Each key: the archetypes it becomes (null: stays).
            var choices: [2]?[]const []const u8 = .{ null, null };
            var numbers = false;
            for (keys, 0..) |k, i| {
                const n = schema.int(namedArg(c, k[0]) orelse continue) orelse continue;
                if (n == 0) continue;
                const prefix: []const u8 = if (k[1] == .weapon) "w" else "f";
                // A level's `hero` block of that classic_id (no archetype) keeps it a number.
                const hero = k[1] == .character and ix.by_value.contains(try std.fmt.allocPrint(a, "h{d}", .{n}));
                choices[i] = if (hero) null else ix.only(try std.fmt.allocPrint(a, "{s}{d}", .{ prefix, n }));
                if (choices[i] == null) numbers = true;
            }
            var by_class = false;
            // AiProfile too: a row by fighter is an enemy's only, as
            // its class's (battle/generic.zig aiProfile); but not the rows the generic
            // fighter's `ai` picks (their `generic_ai`).
            const ai = std.mem.eql(u8, c.text, "AiProfile");
            const class_keyed = ai or std.mem.eql(u8, c.text, "Abilities");
            if (class_keyed and choices[0] == null and !numbers and (schema.int(namedArg(c, "fighter") orelse &zero_expr) orelse 0) == 0) {
                const cl = schema.int(namedArg(c, "class") orelse &zero_expr) orelse 0;
                const kept = ai and namedArg(c, "generic_ai") != null;
                if (cl != 0 and !kept) if (ix.only(try std.fmt.allocPrint(a, "c{d}", .{cl}))) |ids| if (!ownRowFor(rows, c.text, &ix, ids)) {
                    choices[0] = ids;
                    by_class = true;
                } else {
                    numbers = true;
                };
            }
            if (choices[0] == null and choices[1] == null) {
                if (numbers) self.report.key_numbers += 1;
                try out.append(a, r);
                continue;
            }
            const one: []const []const u8 = &.{""};
            for (choices[0] orelse one) |x0| for (choices[1] orelse one) |x1| {
                var named: std.ArrayList(ir.Named) = .empty;
                for (c.named) |n| {
                    // `class = 0` (the field is required): the row is the fighter's own.
                    if (by_class and std.mem.eql(u8, n.name, "class")) {
                        try named.append(a, .{ .name = n.name, .value = &zero_expr });
                        continue;
                    }
                    const pick: ?[]const u8 = if (std.mem.eql(u8, n.name, keys[0][0]) and x0.len > 0) x0 else if (keys.len > 1 and std.mem.eql(u8, n.name, keys[1][0]) and x1.len > 0) x1 else null;
                    const sg = if (std.mem.eql(u8, n.name, keys[0][0])) keys[0][1] else if (keys.len > 1) keys[1][1] else .none;
                    if (pick) |p| {
                        const v = try a.create(ir.Expr);
                        v.* = .{ .line = n.value.line, .kind = .{ .lit = .{ .string = p } }, .sigil = sg };
                        try named.append(a, .{ .name = n.name, .value = v });
                    } else try named.append(a, n);
                }
                // A row by class had no fighter key: it leads.
                if (by_class) {
                    const v = try a.create(ir.Expr);
                    v.* = .{ .line = r.line, .kind = .{ .lit = .{ .string = x0 } }, .sigil = .character };
                    try named.insert(a, 0, .{ .name = "fighter", .value = v });
                }
                var nc = c;
                nc.named = named.items;
                const x = try a.create(ir.Expr);
                x.* = r.*;
                x.kind = .{ .call = nc };
                try out.append(a, x);
                self.report.key_refs += 1;
            };
        }
        for (out.items) |*r| r.* = try self.valueRefs(&ix, r.*);
        return out.items;
    }

    /// The FxAs rows (Classic's) as fields of the weapon blocks they name (no such row in
    /// OpenGorky): `as` → `effects_from`, `flash`/`launch`/`hit` →
    /// `flash_from`/`launch_from`/`hit_from`, `sound` → `hit_sound`; a classic_id value as
    /// a reference to the one weapon archetype having it (`~w"weapons::rocket_launcher"`), else
    /// the number. A row by classic_id N goes onto every weapon block with its own
    /// `classic_id = N` (the others inherit it, as the number), by class onto that archetype
    /// (by object name onto that block). A row naming no block goes (reported).
    fn fxAsFields(self: *Conv, rows: []const *const ir.Expr) ![]const *const ir.Expr {
        const a = self.a;
        var ix: Idents = .{ .a = a };
        for (self.modules.items) |m| for (m.entities) |*e| try ix.tops.put(a, try std.fmt.allocPrint(a, "{s} {s}{s}{s}", .{ e.kind, m.path, if (m.path.len > 0) "::" else "", e.name }), e);
        var out: std.ArrayList(*const ir.Expr) = .empty;
        for (rows) |r| {
            if (r.kind != .call or !std.mem.eql(u8, r.kind.call.text, rules.FxAs.call)) {
                try out.append(a, r);
                continue;
            }
            const c = r.kind.call;
            var fields: std.ArrayList(ir.Named) = .empty;
            for ([_][2][]const u8{ .{ "as", "effects_from" }, .{ "flash", "flash_from" }, .{ "launch", "launch_from" }, .{ "hit", "hit_from" }, .{ "sound", "hit_sound" } }) |m| {
                var v = namedArg(c, m[0]) orelse continue;
                if (schema.int(v)) |id| {
                    if (id == 0) continue;
                    if (id > 0) if (ix.archetypeOf("weapon", id)) |path| {
                        const x = try a.create(ir.Expr);
                        x.* = .{ .line = v.line, .kind = .{ .lit = .{ .string = path } }, .sigil = .weapon };
                        v = x;
                    };
                } else if (schema.text(v) == null or schema.text(v).?.len == 0) continue;
                try fields.append(a, .{ .name = m[1], .value = v });
            }
            const key = namedArg(c, "weapon") orelse &zero_expr;
            var n: usize = 0;
            for (self.modules.items) |m| n += try fxOnto(a, m.path, m.entities, key, self.arch_paths.get(try classStem(schema.text(key) orelse "", a)), fields.items);
            if (n == 0) try self.line("FxAs(weapon = {s}): no weapon block, the row dropped", .{if (schema.text(key)) |t| t else try std.fmt.allocPrint(a, "{d}", .{schema.int(key) orelse 0})});
        }
        return out.items;
    }

    /// Row `r`'s values naming an entity by classic_id (`value_refs`: MonsterAttack's
    /// `strike` a fighter's, `effects_from`… a weapon's)
    /// as references to the one archetype having that number (`strike = 118` →
    /// `~c"characters::headnail"`): the core takes its classic_id back (entity.refId). A
    /// number no archetype or several have stays (−1, 0: none, its own).
    fn valueRefs(self: *Conv, ix: *const Idents, r: *const ir.Expr) !*const ir.Expr {
        if (r.kind != .call) return r;
        const c = r.kind.call;
        const fields = for (value_refs) |v| {
            if (std.mem.eql(u8, v[0], c.text)) break v[1];
        } else return r;
        const a = self.a;
        const named = try a.dupe(ir.Named, c.named);
        var any = false;
        for (named) |*n| for (fields) |fd| if (std.mem.eql(u8, n.name, fd[0])) {
            const id = schema.int(n.value) orelse break;
            if (id <= 0) break;
            const path = ix.archetypeOf(if (fd[1] == .weapon) "weapon" else "fighter", id) orelse break;
            const v = try a.create(ir.Expr);
            v.* = .{ .line = n.value.line, .kind = .{ .lit = .{ .string = path } }, .sigil = fd[1] };
            n.value = v;
            any = true;
            self.report.value_refs += 1;
        };
        if (!any) return r;
        var nc = c;
        nc.named = named;
        const x = try a.create(ir.Expr);
        x.* = r.*;
        x.kind = .{ .call = nc };
        return x;
    }

    /// `base` as an archetype's name in `ns` no `kind` block there (nor in `made`, the
    /// ones being made) has: `base`, else its synonym (`box` → `crate`), else the first
    /// free of `alts`, else `base_2`…; not `base`: reported (`collisions`).
    fn archName(self: *Conv, ns: []const u8, kind: []const u8, base: []const u8, alts: []const []const u8, made: []const ir.Entity) ![]const u8 {
        const a = self.a;
        const b = try ogsify.ident(a, base);
        const syn: []const []const u8 = for (synonyms) |p| {
            if (std.mem.eql(u8, p[0], b)) break &.{p[1]};
        } else &.{};
        const n = for (try std.mem.concat(a, []const u8, &.{ &.{b}, syn, alts })) |c| {
            const id = try ogsify.ident(a, c);
            if (!self.taken(ns, kind, id) and !madeHas(made, id)) break id;
        } else blk: {
            var i: usize = 2;
            while (true) : (i += 1) {
                const id = try std.fmt.allocPrint(a, "{s}_{d}", .{ b, i });
                if (!self.taken(ns, kind, id) and !madeHas(made, id)) break :blk id;
            }
        };
        if (!std.mem.eql(u8, n, b)) {
            self.report.collisions += 1;
            try self.line("archetype {s}::{s} taken, named {s}::{s}", .{ ns, b, ns, n });
        }
        return n;
    }

    /// `base` as a component name `ns` has none of.
    fn compName(self: *Conv, ns: []const u8, base: []const u8) ![]const u8 {
        var n = base;
        var i: usize = 2;
        while (self.taken(ns, null, n)) : (i += 1) n = try std.fmt.allocPrint(self.a, "{s}_{d}", .{ base, i });
        return n;
    }

    /// Namespace `ns` has a `kind` block named `n` (null: a component).
    fn taken(self: *Conv, ns: []const u8, kind: ?[]const u8, n: []const u8) bool {
        for (self.modules.items) |m| if (std.mem.eql(u8, m.path, ns)) {
            if (kind) |k| {
                for (m.entities) |e| if (std.mem.eql(u8, e.kind, k) and std.mem.eql(u8, e.name, n)) return true;
            } else for (m.components) |c| if (std.mem.eql(u8, c.name, n)) return true;
        };
        return false;
    }
};

/// The rules tables whose keys may name an entity class (a `<key>_class` companion,
/// rules/rows.zig, core/behaviour.zig; rules.keyMatch), each key with its sigil. Medicine
/// stays by number (its `random` list holds classic_ids, looked up without a class).
const ref_keys = [_]struct { []const u8, []const struct { []const u8, ir.Sigil } }{
    .{ "MonsterAttack", &.{ .{ "fighter", .character }, .{ "weapon", .weapon } } },
    .{ "HeroAttack", &.{ .{ "weapon", .weapon }, .{ "hero", .character } } },
    .{ "WdelayHero", &.{.{ "hero", .character }} },
    .{ "Resist", &.{.{ "fighter", .character }} },
    .{ "KillIcon", &.{.{ "fighter", .character }} },
    .{ "Glow", &.{.{ "fighter", .character }} },
    .{ "SkillIcon", &.{.{ "weapon", .weapon }} },
    .{ "WeaponSound", &.{.{ "weapon", .weapon }} },
    .{ "FxAs", &.{.{ "weapon", .weapon }} },
    .{ "WeaponFlags", &.{.{ "weapon", .weapon }} },
    .{ "AiProfile", &.{.{ "fighter", .character }} },
    .{ "Abilities", &.{.{ "fighter", .character }} },
    .{ "Character", &.{.{ "fighter", .character }} },
    .{ "HealBonus", &.{.{ "healer", .character }} },
    .{ "HiddenWeapons", &.{.{ "hero", .character }} },
    .{ "IdleChatter", &.{.{ "hero", .character }} },
};

/// The rules values (not keys) naming an entity by classic_id that `valueRefs` makes
/// references, each with its sigil.
const value_refs = [_]struct { []const u8, []const struct { []const u8, ir.Sigil } }{
    .{ "MonsterAttack", &.{ .{ "strike", .character }, .{ "effects_from", .weapon }, .{ "flash_from", .weapon }, .{ "launch_from", .weapon }, .{ "hit_from", .weapon } } },
};

/// What `keyRefs` knows of the blocks: per entity class (`ident`, the archetype the OG
/// reader makes an object's class of, world/start.zig addBlockAs) the classic_ids and
/// battle classes its objects have, and back.
const Idents = struct {
    a: Allocator,
    /// "<id>" / "c<battle class>" → the idents having it; ident → those it has.
    by_value: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
    of_ident: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,
    /// Top-level blocks by "<kind> <path>" (the archetypes a key may name).
    tops: std.StringHashMapUnmanaged(*const ir.Entity) = .empty,

    fn add(self: *Idents, ident: []const u8, value: []const u8) !void {
        for ([_]struct { *std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)), []const u8, []const u8 }{ .{ &self.by_value, value, ident }, .{ &self.of_ident, ident, value } }) |x| {
            const g = try x[0].getOrPut(self.a, x[1]);
            if (!g.found_existing) g.value_ptr.* = .empty;
            for (g.value_ptr.items) |y| {
                if (std.mem.eql(u8, y, x[2])) break;
            } else try g.value_ptr.append(self.a, x[2]);
        }
    }

    /// Block `e`'s field `name` or its nearest archetype's.
    fn inherited(self: *const Idents, e: *const ir.Entity, name: []const u8, depth: u32) ?*const ir.Expr {
        if (fieldOf(e, name)) |v| return v;
        if (e.base.len == 0 or depth > 16) return null;
        const b = self.tops.get(std.fmt.allocPrint(self.a, "{s} {s}", .{ e.kind, e.base }) catch return null) orelse return null;
        return self.inherited(b, name, depth + 1);
    }

    /// Every object block under `es` (namespace `ns`), its ident's values.
    fn walk(self: *Idents, ns: []const u8, es: []const ir.Entity) !void {
        for (es) |*e| {
            try self.walk(ns, e.children);
            const fighter = std.mem.eql(u8, e.kind, "fighter") or std.mem.eql(u8, e.kind, "hero");
            if (!fighter and !std.mem.eql(u8, e.kind, "weapon") and !std.mem.eql(u8, e.kind, "item")) continue;
            const ident = if (e.base.len > 0) e.base else if (ns.len > 0) try std.fmt.allocPrint(self.a, "{s}::{s}", .{ ns, e.name }) else e.name;
            try self.add(ident, try std.fmt.allocPrint(self.a, "n{s}", .{try std.ascii.allocLowerString(self.a, e.name)}));
            const id = if (self.inherited(e, "classic_id", 0)) |v| schema.int(v) orelse 0 else 0;
            try self.add(ident, try std.fmt.allocPrint(self.a, "{s}{d}", .{ e.kind[0..1], id }));
            if (!fighter) continue;
            var bc: i32 = 0;
            if (self.inherited(e, "battle_class", 0)) |v| bc = schema.int(v) orelse if (v.kind == .word) battleClass(self.a, v.kind.word) orelse -1 else -1;
            try self.add(ident, try std.fmt.allocPrint(self.a, "c{d}", .{bc}));
        }
    }

    /// The one top-level `kind` block of a namespace (an archetype: `characters::headnail`)
    /// whose classic_id (its own or its archetype's) is `id`; null: none or several.
    fn archetypeOf(self: *const Idents, kind: []const u8, id: i32) ?[]const u8 {
        var found: ?[]const u8 = null;
        var it = self.tops.iterator();
        while (it.next()) |kv| {
            const k = kv.key_ptr.*;
            if (!std.mem.startsWith(u8, k, kind) or k.len <= kind.len or k[kind.len] != ' ') continue;
            const path = k[kind.len + 1 ..];
            if (std.mem.indexOf(u8, path, "::") == null) continue;
            const v = self.inherited(kv.value_ptr.*, "classic_id", 0) orelse continue;
            if ((schema.int(v) orelse continue) != id) continue;
            if (found != null) return null;
            found = path;
        }
        return found;
    }

    /// A value's sort: a classic_id (`f`ighter, `h`ero, `w`eapon, `i`tem), a battle
    /// `c`lass, an object's `n`ame.
    fn sortOf(ch: u8) u8 {
        return switch (ch) {
            'f', 'h', 'w', 'i' => 'i',
            else => ch,
        };
    }

    /// The archetypes whose objects alone have value `v` ("f101", "c7"; of their kind),
    /// each of them having only it; null: none, or an object of another class has it too.
    fn only(self: *const Idents, v: []const u8) ?[]const []const u8 {
        const ids = self.by_value.get(v) orelse return null;
        for (ids.items) |i| {
            if (std.mem.indexOf(u8, i, "::") == null) return null;
            const kind = for ([_][]const u8{ "fighter", "weapon", "item" }) |k| {
                if (self.tops.contains(std.fmt.allocPrint(self.a, "{s} {s}", .{ k, i }) catch return null)) break k;
            } else return null;
            _ = kind;
            // Its other values of the same sort (an id beside an id, a class beside a class).
            for (self.of_ident.get(i).?.items) |o| if (sortOf(o[0]) == sortOf(v[0])) if (!std.mem.eql(u8, o, v)) return null;
        }
        return ids.items;
    }
};

/// Named argument `name` of row `c`.
fn namedArg(c: ir.Call, name: []const u8) ?*const ir.Expr {
    for (c.named) |n| if (std.mem.eql(u8, n.name, name)) return n.value;
    return null;
}

const zero_expr: ir.Expr = .{ .line = 0, .kind = .{ .lit = .{ .int = 0 } } };

/// A row of table `table` other than by class names (by number, class or object name)
/// an object of archetypes `ids`: converting its class row would make two own rows.
fn ownRowFor(rows: []const *const ir.Expr, table: []const u8, ix: *const Idents, ids: []const []const u8) bool {
    for (rows) |r| {
        if (r.kind != .call or !std.mem.eql(u8, r.kind.call.text, table)) continue;
        const k = namedArg(r.kind.call, "fighter") orelse continue;
        if (schema.int(k)) |n| {
            if (n == 0) continue;
            for (ids) |i| for (ix.of_ident.get(i).?.items) |v| if (v[0] != 'c' and std.fmt.parseInt(i32, v[1..], 10) catch 0 == n) return true;
        } else if (schema.text(k)) |t| {
            const name = std.fmt.allocPrint(ix.a, "n{s}", .{t}) catch return true;
            for (ids) |i| {
                if (std.ascii.eqlIgnoreCase(i, t)) return true;
                for (ix.of_ident.get(i).?.items) |v| if (std.ascii.eqlIgnoreCase(v, name)) return true;
            }
        }
    }
    return false;
}

/// Fighter class word `w`'s Classic number (rules/fighter_classes.zig); null: none.
fn battleClass(_: Allocator, w: []const u8) ?i32 {
    return rules.fighter_classes.idOf(w);
}

/// FxAs fields `fs` (Conv.fxAsFields) onto the weapon blocks under `es` (namespace `ns`)
/// that row key `key` names: by classic_id those with their own `classic_id` of it, by
/// text the archetype `arch` (the class's path) or the block of that name. Returns how many.
fn fxOnto(a: Allocator, ns: []const u8, es: []const ir.Entity, key: *const ir.Expr, arch: ?[]const u8, fs: []const ir.Named) !usize {
    var n: usize = 0;
    for (@constCast(es)) |*e| {
        n += try fxOnto(a, ns, e.children, key, arch, fs);
        if (!std.mem.eql(u8, e.kind, "weapon")) continue;
        const hit = if (schema.int(key)) |id| (if (fieldOf(e, "classic_id")) |v| schema.int(v) == id else false) else if (schema.text(key)) |t| blk: {
            const path = try std.fmt.allocPrint(a, "{s}::{s}", .{ ns, e.name });
            break :blk std.ascii.eqlIgnoreCase(t, e.name) or std.ascii.eqlIgnoreCase(t, path) or (if (arch) |p| std.mem.eql(u8, p, path) else false);
        } else false;
        if (!hit) continue;
        var out: std.ArrayList(ir.Named) = .fromOwnedSlice(try a.dupe(ir.Named, e.fields));
        // A later row over an earlier one: its fields replace (rules_text's override).
        for (fs) |f| {
            for (out.items) |*o| {
                if (!std.mem.eql(u8, o.name, f.name)) continue;
                o.value = f.value;
                break;
            } else try out.append(a, f);
        }
        e.fields = out.items;
        n += 1;
    }
    return n;
}

test "fxOnto: FxAs fields onto the weapon blocks of the row's classic_id or class" {
    var ar: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const n98: ir.Expr = .{ .line = 1, .kind = .{ .lit = .{ .int = 98 } } };
    const n5: ir.Expr = .{ .line = 1, .kind = .{ .lit = .{ .int = 5 } } };
    var es = [_]ir.Entity{
        .{ .kind = "weapon", .name = "a", .fields = &.{.{ .name = "classic_id", .value = &n98 }}, .attach = &.{}, .line = 1 },
        .{ .kind = "weapon", .name = "b", .fields = &.{.{ .name = "classic_id", .value = &n5 }}, .attach = &.{}, .line = 2 },
    };
    const fs = [_]ir.Named{.{ .name = "launch_from", .value = &n5 }};
    try std.testing.expectEqual(1, try fxOnto(a, "weapons", &es, &n98, null, &fs));
    try std.testing.expectEqual(2, es[0].fields.len);
    try std.testing.expectEqualStrings("launch_from", es[0].fields[1].name);
    try std.testing.expectEqual(1, es[1].fields.len);
    // By class: the archetype; a second row replaces the field.
    const cls: ir.Expr = .{ .line = 1, .kind = .{ .lit = .{ .string = "cw_b" } } };
    try std.testing.expectEqual(1, try fxOnto(a, "weapons", &es, &cls, "weapons::b", &fs));
    try std.testing.expectEqual(1, try fxOnto(a, "weapons", &es, &cls, "weapons::b", &.{.{ .name = "launch_from", .value = &n98 }}));
    try std.testing.expectEqual(2, es[1].fields.len);
    try std.testing.expectEqual(98, schema.int(es[1].fields[1].value).?);
}

/// `Conv.texts` onto blocks `es` (and their inner blocks): each with its own `classic_id` N
/// gets `name` (table 0, `string.tab`) and `examine` (table 1, `items.inf`; an area's table
/// 2, `activeareas.inf`) of N; the numbers taken into `used`, the fields counted.
fn textsOnto(a: Allocator, es: []const ir.Entity, maps: []const std.AutoArrayHashMapUnmanaged(i32, []const u8), used: []std.AutoHashMapUnmanaged(i32, void), n: *usize) !void {
    for (@constCast(es)) |*e| {
        try textsOnto(a, e.children, maps, used, n);
        const at = for (e.fields, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, "classic_id")) break i;
        } else continue;
        const id = schema.int(e.fields[at].value) orelse continue;
        var fs: std.ArrayList(ir.Named) = .fromOwnedSlice(try a.dupe(ir.Named, e.fields));
        var k = at + 1;
        const ex: usize = if (std.mem.eql(u8, e.kind, "area")) 2 else 1;
        for ([_]struct { []const u8, usize }{ .{ "name", 0 }, .{ "examine", ex } }) |x| if (maps[x[1]].get(id)) |t| {
            const v = try a.create(ir.Expr);
            v.* = .{ .line = e.fields[at].value.line, .kind = .{ .lit = .{ .string = t } } };
            try fs.insert(a, k, .{ .name = x[0], .value = v });
            k += 1;
            try used[x[1]].put(a, id, {});
            n.* += 1;
        };
        e.fields = fs.items;
    }
}

test "textsOnto: a number's texts onto the blocks owning it, an area's examine its own" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: parser.Diagnostic = .{};
    const u = try parser.parse(a, "level l { item i { classic_id = 7; hp = 1; } area r { classic_id = 7; } item j: items::x { } }", "t", &diag);
    var maps: [3]std.AutoArrayHashMapUnmanaged(i32, []const u8) = @splat(.empty);
    try maps[0].put(a, 7, "Name");
    try maps[1].put(a, 7, "Item text");
    try maps[2].put(a, 7, "Area text");
    var used: [3]std.AutoHashMapUnmanaged(i32, void) = @splat(.empty);
    var n: usize = 0;
    try textsOnto(a, u.modules[0].entities, &maps, &used, &n);
    const kids = u.modules[0].entities[0].children;
    var w: std.Io.Writer.Allocating = .init(a);
    for (kids) |k| try print_ogs.entity(&w.writer, k, 0);
    try std.testing.expectEqualStrings(
        \\item i {
        \\    classic_id = 7;
        \\    name = "Name";
        \\    examine = "Item text";
        \\    hp = 1;
        \\}
        \\area r {
        \\    classic_id = 7;
        \\    name = "Name";
        \\    examine = "Area text";
        \\}
        \\item j: items::x {
        \\}
        \\
    , w.written());
    try std.testing.expectEqual(4, n);
    try std.testing.expect(used[0].contains(7) and used[1].contains(7) and used[2].contains(7));
}

/// The kind prefixes of the Classic class files (`cw_` a weapon, `ci_`/`ca_` an item or
/// ammo, `ft_` a fighter, `wp_` an enemy's weapon), not in archetype names.
const class_prefixes = [_][]const u8{ "cw_", "ci_", "ca_", "ft_", "wp_" };

/// `stem` without its kind prefix (`cw_axe` → `axe`); as it is without one, or when nothing follows.
fn unprefixed(stem: []const u8) []const u8 {
    for (class_prefixes) |p| if (stem.len > p.len and std.ascii.startsWithIgnoreCase(stem, p)) return stem[p.len..];
    return stem;
}

test unprefixed {
    try std.testing.expectEqualStrings("axe", unprefixed("cw_axe"));
    try std.testing.expectEqualStrings("time_bomb", unprefixed("FT_time_bomb"));
    try std.testing.expectEqualStrings("item", unprefixed("item"));
    try std.testing.expectEqualStrings("cw_", unprefixed("cw_"));
}

/// A Classic class file's lower-case stem (`classes\\CW_Axe.s` → `cw_axe`), `arch_paths`' key.
fn classStem(file: []const u8, a: Allocator) ![]const u8 {
    const base = file[if (std.mem.lastIndexOfAny(u8, file, "\\/")) |k| k + 1 else 0..];
    return std.ascii.allocLowerString(a, base[0 .. base.len - std.fs.path.extension(base).len]);
}

/// An instance of an archetype being folded: its block in level block `lev`.
const Member = struct { lev: *ir.Entity, e: *ir.Entity };

/// `inst_arch`'s key.
fn instKey(a: Allocator, level: []const u8, name: []const u8) ![]const u8 {
    return std.ascii.allocLowerString(a, try std.fmt.allocPrint(a, "{s}\x00{s}", .{ level, name }));
}

fn isLevelKind(k: []const u8) bool {
    return std.mem.eql(u8, k, "level") or std.mem.eql(u8, k, "battle");
}

/// A location's own object's position (`foldPlaced`): its own, never its archetype's.
fn placedField(n: []const u8) bool {
    for ([_][]const u8{ "x", "y", "z", "angle", "approach_x", "approach_y", "approach_angle", "pos_x", "pos_y", "areaName" }) |x| if (std.mem.eql(u8, n, x)) return true;
    return false;
}

/// An archetype name's stand-in when a class archetype has it already (the levels'
/// plain boxes beside the scripted class `items::box`). shortcut: one
/// pair, the game's only such clash; add pairs where a mod's need them.
const synonyms = [_][2][]const u8{.{ "box", "crate" }};

fn madeHas(made: []const ir.Entity, n: []const u8) bool {
    for (made) |e| if (std.mem.eql(u8, e.name, n)) return true;
    return false;
}

/// The archetype names to try for objects `names` (`foldPlaced`), best first: what they
/// begin with after their level's prefix (`03mf_matrix`, `04c_matrix` → `matrix`; the
/// name more than half have instead where it begins so: `exit2city`, `exit_two2city` →
/// `exit2city`), what they end with (`01pr_mcrate1`, `03lr_wcrate2` → `crate`), the name
/// more than half have (`01ps_exit2port` ×5, `worker_exit_are` → `exit2port`); each of three letters or more,
/// without the kind tail `_itm`/`_are`, trailing `_` and digits.
fn placedNames(a: Allocator, names: []const []const u8) ![]const []const u8 {
    const stems = try a.alloc([]const u8, names.len);
    for (names, stems) |full, *n| {
        n.* = full;
        // A level's prefix: digits, letters, `_` (`04c_`).
        if (n.len > 0 and std.ascii.isDigit(n.*[0])) if (std.mem.indexOfScalar(u8, n.*, '_')) |k| {
            n.* = n.*[k + 1 ..];
        };
        n.* = trimTail(n.*);
        for ([_][]const u8{ "_itm", "_are" }) |t| if (std.ascii.endsWithIgnoreCase(n.*, t)) {
            n.* = trimTail(n.*[0 .. n.len - t.len]);
        };
    }
    var head = stems[0];
    var tail = stems[0];
    for (stems[1..]) |n| {
        var k: usize = 0;
        while (k < head.len and k < n.len and std.ascii.toLower(head[k]) == std.ascii.toLower(n[k])) k += 1;
        head = head[0..k];
        k = 0;
        while (k < tail.len and k < n.len and std.ascii.toLower(tail[tail.len - 1 - k]) == std.ascii.toLower(n[n.len - 1 - k])) k += 1;
        tail = tail[tail.len - k ..];
    }
    head = trimTail(head);
    while (tail.len > 0 and (tail[0] == '_' or std.ascii.isDigit(tail[0]))) tail = tail[1..];
    const most = majority(stems);
    // The name most have, where it says more than what all begin with (`exit` → `exit2city`).
    if (most) |m| if (head.len >= 3 and std.ascii.startsWithIgnoreCase(m, head)) {
        head = m;
    };
    var out: std.ArrayList([]const u8) = .empty;
    for ([_]?[]const u8{ head, tail, most }) |c| if (c) |n| if (n.len >= 3) try out.append(a, n);
    return out.items;
}

/// `n` without its trailing `_` and digits.
fn trimTail(n: []const u8) []const u8 {
    var t = n;
    while (t.len > 0 and (t[t.len - 1] == '_' or std.ascii.isDigit(t[t.len - 1]))) t = t[0 .. t.len - 1];
    return t;
}

/// The value more than half of `vs` are (case aside); null: none.
fn majority(vs: []const []const u8) ?[]const u8 {
    for (vs) |v| {
        var n: usize = 0;
        for (vs) |u| n += @intFromBool(std.ascii.eqlIgnoreCase(u, v));
        if (n * 2 > vs.len) return v;
    }
    return null;
}

test placedNames {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const x = arena.allocator();
    try std.testing.expectEqualStrings("matrix", (try placedNames(x, &.{ "matrix", "04c_matrix", "03mf_matrix" }))[0]);
    try std.testing.expectEqualStrings("box", (try placedNames(x, &.{ "box01_store_itm", "box_01_itm", "box_02_itm" }))[0]);
    try std.testing.expectEqualStrings("crate", (try placedNames(x, &.{ "01pr_mcrate1", "03lr_wcrate2" }))[0]);
    try std.testing.expectEqualStrings("crate", (try placedNames(x, &.{ "01pr_wcrate1", "03lr_wcrate2", "01pr_mcrate1" }))[0]);
    try std.testing.expectEqualStrings("exit2port", (try placedNames(x, &.{ "01ps_exit2port", "01pt_exit2port", "worker_exit_are" }))[0]);
    try std.testing.expectEqualStrings("exit2city", (try placedNames(x, &.{ "04cg_exit2city", "04cs_exit2city", "04cf_exit_two2city" }))[0]);
    try std.testing.expectEqual(0, (try placedNames(x, &.{ "ab1", "ab2" })).len);
}

/// A field only an instance has (its place, its owner), never its archetype's.
fn instanceField(n: []const u8) bool {
    for ([_][]const u8{ "tile", "at", "owner" }) |x| if (std.mem.eql(u8, n, x)) return true;
    return false;
}

fn fieldOf(e: *const ir.Entity, name: []const u8) ?*const ir.Expr {
    return fieldOfList(e.fields, name);
}

fn fieldOfList(fs: []const ir.Named, name: []const u8) ?*const ir.Expr {
    for (fs) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
    return null;
}

/// Weapon block `c`'s `owner` is `name`.
fn ownedBy(c: ir.Entity, name: []const u8) bool {
    const v = fieldOf(&c, "owner") orelse return false;
    return v.kind == .lit and v.kind.lit == .string and std.ascii.eqlIgnoreCase(v.kind.lit.string, name);
}

/// Two values as OG Script writes them alike.
fn sameExpr(a: Allocator, x: *const ir.Expr, y: *const ir.Expr) !bool {
    var wx: std.Io.Writer.Allocating = .init(a);
    var wy: std.Io.Writer.Allocating = .init(a);
    try print_ogs.expression(&wx.writer, x);
    try print_ogs.expression(&wy.writer, y);
    return std.mem.eql(u8, wx.written(), wy.written());
}

/// Variables `vs` as text (their names, types, values in order).
fn varsText(a: Allocator, vs: []const ir.Field) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    for (vs) |v| {
        try w.writer.print("{s} {s} ", .{ v.type_name, v.name });
        if (v.default) |d| try print_ogs.expression(&w.writer, d);
        try w.writer.writeAll(";");
    }
    return w.written();
}

/// A namespace being made: its blocks as text, its components.
const Module = struct {
    path: []const u8,
    /// Its blocks in the root namespace (a location's: `~l"01_port"` names it anywhere).
    blocks_at_root: bool = false,
    data: std.Io.Writer.Allocating = .init(std.heap.page_allocator),
    comps: std.ArrayList(*const ir.Component) = .empty,
    names: std.StringHashMapUnmanaged(void) = .empty,

    /// `n`, else `n_2`, `n_3`… (a namespace's component names are unique).
    fn uniqueName(self: *Module, a: Allocator, n: []const u8) ![]const u8 {
        var x = n;
        var i: usize = 2;
        while (self.names.contains(x)) : (i += 1) x = try std.fmt.allocPrint(a, "{s}_{d}", .{ n, i });
        try self.names.put(a, x, {});
        return x;
    }
};

/// `Conv.ammoRefs` over blocks `es` and their nested blocks.
fn ammoIn(a: Allocator, by_id: *const std.AutoHashMapUnmanaged(i32, []const u8), es: []const ir.Entity) !void {
    for (@constCast(es)) |*e| {
        try ammoIn(a, by_id, e.children);
        if (!std.mem.eql(u8, e.kind, "weapon")) continue;
        for (e.fields, 0..) |f, i| if (std.mem.eql(u8, f.name, "ammo")) {
            const n = schema.int(f.value) orelse 0;
            const v = try a.create(ir.Expr);
            var fs: std.ArrayList(ir.Named) = .fromOwnedSlice(try a.dupe(ir.Named, e.fields));
            if (n == -1) {
                v.* = .{ .line = f.value.line, .kind = .{ .lit = .{ .bool = true } } };
                fs.items[i] = .{ .name = "thrown", .value = v };
            } else if (by_id.get(n)) |p| {
                v.* = .{ .line = f.value.line, .kind = .{ .lit = .{ .string = p } }, .sigil = .item };
                fs.items[i] = .{ .name = "ammo", .value = v };
            } else {
                if (n != 0) std.log.warn("{s}: ammo = {d}: no item archetype of that classic_id, dropped", .{ e.name, n });
                _ = fs.orderedRemove(i);
            }
            e.fields = fs.items;
            break;
        };
    }
}

/// Each object's `action` (an item's, an area's, a box's; `action1`… an area's further
/// menu rows, its own variables in Classic) as OG writes it: the name of the rules Action
/// row of that classic_id as a word (`action = Take`, Classic `funcID = 3`), the OG
/// reader sets the number back (world/start.zig); −1, 0 and a number no row has stay
/// numbers. A box's own `var int action` stays its variable (its code sets numbers).
fn actionRefs(a: Allocator, es: []const ir.Entity) !void {
    for (@constCast(es)) |*e| {
        try actionRefs(a, e.children);
        var fs: std.ArrayList(ir.Named) = .fromOwnedSlice(try a.dupe(ir.Named, e.fields));
        for (fs.items) |*f| if (std.mem.eql(u8, f.name, "action")) {
            f.value = try actionName(a, f.value) orelse continue;
        };
        // An area's `var int action1 = 17;`: the field `action1 = Down`.
        var vs: std.ArrayList(ir.Field) = .empty;
        for (e.vars) |v| {
            const n = v.name;
            const further = std.mem.eql(u8, e.kind, "area") and n.len == 7 and std.mem.startsWith(u8, n, "action") and std.ascii.isDigit(n[6]);
            if (further) if (v.default) |d| if (try actionName(a, d)) |x| {
                try fs.append(a, .{ .name = n, .value = x });
                continue;
            };
            try vs.append(a, v);
        }
        e.fields = fs.items;
        e.vars = vs.items;
    }
}

/// Action number `v` as the name of its rules Action row, 0 and −1 as the words `none`
/// and `walk`; null: no int, no row.
fn actionName(a: Allocator, v: *const ir.Expr) !?*const ir.Expr {
    const n = schema.int(v) orelse return null;
    const x = try a.create(ir.Expr);
    x.* = .{ .line = v.line, .kind = switch (n) {
        0 => .{ .word = "none" },
        -1 => .{ .word = "walk" },
        else => .{ .word = (rules.action(n) orelse {
            std.log.warn("action = {d}: no rules Action of that classic_id, left a number", .{n});
            return null;
        }).name },
    } };
    return x;
}

/// Each weapon's `class` number as the name of its rules WeaponClass/Pattern rows
/// (`class = pistol`); the OG reader sets the number back (world/start.zig). A number
/// without rows: dropped, warned.
fn classRefs(a: Allocator, es: []const ir.Entity) !void {
    for (@constCast(es)) |*e| {
        try classRefs(a, e.children);
        if (!std.mem.eql(u8, e.kind, "weapon")) continue;
        var fs: std.ArrayList(ir.Named) = .fromOwnedSlice(try a.dupe(ir.Named, e.fields));
        for (fs.items, 0..) |*f, i| if (std.mem.eql(u8, f.name, "class")) {
            const n = schema.int(f.value) orelse break;
            const name = rules.weaponClassName(n) orelse {
                std.log.warn("{s}: class = {d}: no rules WeaponClass of that number, dropped", .{ e.name, n });
                _ = fs.orderedRemove(i);
                break;
            };
            const x = try a.create(ir.Expr);
            x.* = .{ .line = f.value.line, .kind = .{ .word = name } };
            f.value = x;
            break;
        };
        e.fields = fs.items;
    }
}

/// A weapon's `attackEffectDelay` (`v`) as OpenGorky carries it: the
/// exe reads it only when a generic fighter (`battle_class` 100, battle/attacks.zig
/// genericAttack) strikes with it, so only a weapon such a fighter owns gets it, as its
/// own `hit_delay` (the weapon class field over the strike, battle/attacks.zig overlay);
/// unless it has one of its own. Other weapons' go.
/// Block `e` has a text of its own (`name`, `examine`): an identity worth a number.
fn namedBlock(e: *const ir.Entity) bool {
    for (e.fields) |f| if (std.mem.eql(u8, f.name, "name") or std.mem.eql(u8, f.name, "examine")) return true;
    return false;
}

/// Block `e`'s own classic_id field, if a number.
fn entityId(e: *const ir.Entity) ?i32 {
    for (e.fields) |f| if (std.mem.eql(u8, f.name, "classic_id")) return schema.int(f.value);
    return null;
}

/// A value naming a block by number in a field that takes an archetype (`Resist(fighter =
/// 105)`, a weapon's `hit_from = 98`): where it stands, the number, the reference's sigil.
const SoftRef = struct { at: *ir.Named, n: i32, sigil: ir.Sigil, text: bool = false };

/// A list of numbers in a field whose places may name archetypes (`HiddenWeapons(weapons =
/// "34 98")`, `Medicine(random = …)`): where it stands, its numbers, their references' sigil.
const SoftList = struct { at: *ir.Named, ns: []const i32, sigil: ir.Sigil };

/// The entity fields of the rows (and the blocks' effect fields) that hold numbers.
const id_keys = [_][]const u8{ "fighter", "weapon", "hero", "item", "id", "who", "healer", "strike", "user", "target", "enemy", "effects_from", "flash_from", "launch_from", "hit_from", "pairs", "random", "weapons", "special" };

/// Row or value `e`'s numbers in `id_keys` fields: a whole number where the row takes the
/// field as an archetype (codec.classField) into `soft`, any other into `hard`.
fn refsIn(a: Allocator, hard: *std.AutoHashMapUnmanaged(i32, void), soft: *std.ArrayList(SoftRef), lists: *std.ArrayList(SoftList), e: *const ir.Expr) !void {
    switch (e.kind) {
        .call => |c| {
            // A text row's `id` may name any block (by its path: dropIds).
            const text_row = for (@import("../loaders.zig").rules_text.text_rows) |t| {
                if (std.mem.eql(u8, c.text, t)) break true;
            } else false;
            if (text_row) for (c.named) |*n| if (std.mem.eql(u8, n.name, "id")) if (schema.int(n.value)) |x| {
                try soft.append(a, .{ .at = @constCast(n), .n = x, .sigil = .none, .text = true });
                return;
            };
            for (c.named) |*n| {
                const key = for (id_keys) |k| {
                    if (std.mem.eql(u8, n.name, k)) break true;
                } else false;
                if (key) {
                    if (schema.int(n.value)) |x| {
                        if (codec.classField(c.text, n.name)) |sg| {
                            try soft.append(a, .{ .at = @constCast(n), .n = x, .sigil = sg });
                        } else try hard.put(a, x, {});
                    } else if (codec.classField(c.text, n.name)) |sg| {
                        // A list of numbers whose places may name archetypes.
                        var ns: std.ArrayList(i32) = .empty;
                        try intsInOrder(a, &ns, n.value);
                        if (ns.items.len > 0) try lists.append(a, .{ .at = @constCast(n), .ns = ns.items, .sigil = sg });
                    } else try allInts(a, hard, n.value);
                }
                try refsIn(a, hard, soft, lists, n.value);
            }
            for (c.args) |x| try refsIn(a, hard, soft, lists, x);
        },
        .list => |l| for (l) |x| try refsIn(a, hard, soft, lists, x),
        else => {},
    }
}

/// Row `r` names by a reference field (codec.classField) a number > 0 that no block of
/// `groups` has, nothing keeps (`hard`) and the code sets to no object (`coded`): no one it
/// can apply to.
fn deadRow(r: *const ir.Expr, groups: anytype, hard: *const std.AutoHashMapUnmanaged(i32, void), coded: *const std.AutoHashMapUnmanaged(i32, void)) bool {
    if (r.kind != .call) return false;
    const c = r.kind.call;
    for (@import("../loaders.zig").rules_text.text_rows) |t| if (std.mem.eql(u8, c.text, t)) return false;
    for (c.named) |n| {
        if (codec.classField(c.text, n.name) == null) continue;
        const x = schema.int(n.value) orelse continue;
        if (x > 0 and !groups.contains(x) and !hard.contains(x) and !coded.contains(x)) return true;
    }
    return false;
}

/// An object's action field (`action`, `action1`…`action9`; world/start.zig actionField).
fn actionField(name: []const u8) bool {
    if (!std.ascii.startsWithIgnoreCase(name, "action")) return false;
    return name.len == 6 or (name.len == 7 and std.ascii.isDigit(name[6]));
}

/// The word of action number `n` (−1 walk, 0 none, else the rules Action's name); null: none.
fn actionWordOf(n: i32) ?[]const u8 {
    if (n == -1) return "walk";
    if (n == 0) return "none";
    return if (rules.action(n)) |r| r.name else null;
}

fn targetText(t: ir.Target) []const u8 {
    return switch (t) {
        .local => "",
        .name => |x| x.text,
        .field => |x| x.text,
        .member => |x| x.text,
    };
}

/// The variable expression `e` names (`action`, `host.action`), "" another.
fn exprField(e: *const ir.Expr) []const u8 {
    return switch (e.kind) {
        .name => |x| x.text,
        .field => |x| x.text,
        .member => |x| x.text,
        else => "",
    };
}

/// Field `n` of `fs` (null: none).
/// Blocks `es` and the ones inside them, in order.
fn allBlocks(a: Allocator, es: []ir.Entity, out: *std.ArrayList(*ir.Entity)) !void {
    for (es) |*e| {
        try out.append(a, e);
        try allBlocks(a, @constCast(e.children), out);
    }
}

/// `name` without its extension (`logo.avi`: `logo`).
fn stemOf(name: []const u8) []const u8 {
    return name[0 .. std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len];
}

fn isIdent(n: []const u8) bool {
    if (n.len == 0 or std.ascii.isDigit(n[0])) return false;
    for (n) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}

/// Transform row `r` with its `into` the morph's block (`"03ch_lilith_m.mtm"` as
/// `~c"03ch_lilith_m"`), its `anim` gone when it is that block's `mesh`.
fn transformRow(a: Allocator, r: *const ir.Expr, morphs: *const std.StringHashMapUnmanaged(*const ir.Entity)) !*const ir.Expr {
    const c = r.kind.call;
    const into = schema.text(namedArg(c, "into") orelse return r) orelse return r;
    const name = if (std.ascii.endsWithIgnoreCase(into, ".mtm")) into[0 .. into.len - 4] else into;
    const t = morphs.get(name) orelse return r;
    const mesh = if (namedIn(t.fields, "mesh")) |v| schema.text(v) orelse "" else "";
    var ns: std.ArrayList(ir.Named) = .empty;
    // Its dialog by its `.dlg`: `dialog = ~d"03__museum_child2"` (the Classic name nothing reads goes).
    const file = if (namedArg(c, "dialog_file")) |v| schema.text(v) orelse "" else "";
    for (c.named) |n| {
        if (std.mem.eql(u8, n.name, "anim") and std.ascii.eqlIgnoreCase(schema.text(n.value) orelse "", mesh)) continue;
        if (std.mem.eql(u8, n.name, "dialog_file") and file.len > 0) continue;
        if (std.mem.eql(u8, n.name, "dialog") and file.len > 0) {
            const v = try a.create(ir.Expr);
            v.* = .{ .line = n.value.line, .sigil = .dialog, .kind = .{ .lit = .{ .string = if (std.ascii.endsWithIgnoreCase(file, ".dlg")) file[0 .. file.len - 4] else file } } };
            try ns.append(a, .{ .name = n.name, .value = v });
            continue;
        }
        if (std.mem.eql(u8, n.name, "into")) {
            const v = try a.create(ir.Expr);
            v.* = .{ .line = n.value.line, .sigil = .character, .kind = .{ .lit = .{ .string = name } } };
            try ns.append(a, .{ .name = n.name, .value = v });
            continue;
        }
        try ns.append(a, n);
    }
    const x = try a.create(ir.Expr);
    x.* = .{ .line = r.line, .kind = .{ .call = .{ .id = c.id, .text = c.text, .args = c.args, .named = ns.items } } };
    return x;
}

fn namedIn(fs: []const ir.Named, n: []const u8) ?*const ir.Expr {
    for (fs) |f| if (std.mem.eql(u8, f.name, n)) return f.value;
    return null;
}

/// Block `b`'s value of field or variable `n`, its archetypes' (by path in `blocks`) after it.
fn valueOf(blocks: *const std.StringHashMapUnmanaged(*ir.Entity), b: *const ir.Entity, n: []const u8, depth: u32) ?*const ir.Expr {
    if (namedIn(b.fields, n)) |v| return v;
    for (b.vars) |v| if (std.ascii.eqlIgnoreCase(v.name, n)) if (v.default) |d| return d;
    if (b.base.len == 0 or depth > 16) return null;
    return valueOf(blocks, blocks.get(b.base) orelse return null, n, depth + 1);
}

/// Archetype `base` (and its own) sets field `n`.
fn baseSets(blocks: *const std.StringHashMapUnmanaged(*ir.Entity), base: []const u8, n: []const u8, depth: u32) bool {
    if (base.len == 0 or depth > 16) return false;
    const b = blocks.get(base) orelse return false;
    if (namedIn(b.fields, n) != null) return true;
    return baseSets(blocks, b.base, n, depth + 1);
}

/// `x` and `y` written alike (OG Script text).
fn sameText(a: Allocator, x: *const ir.Expr, y: *const ir.Expr) !bool {
    var wx: std.Io.Writer.Allocating = .init(a);
    var wy: std.Io.Writer.Allocating = .init(a);
    try print_ogs.expression(&wx.writer, x);
    try print_ogs.expression(&wy.writer, y);
    return std.mem.eql(u8, wx.written(), wy.written());
}

/// The initial value of a `kind` block's field `n` as OG Script writes it (a flag `false`).
fn initialOf(a: Allocator, kind: []const u8, n: []const u8) !?*const ir.Expr {
    const fd = schema.ogField(schema.blockHost(kind) orelse return null, n) orelse return null;
    if (fd.flag) {
        const x = try a.create(ir.Expr);
        x.* = .{ .line = 0, .kind = .{ .lit = .{ .bool = false } } };
        return x;
    }
    return initialExpr(a, fd.type);
}

/// A class's row field `n` (block_rows `key_field`): both blocks name the same class
/// (this one's own or, left out, the other's); any other field: true.
fn sameKey(a: Allocator, blocks: *const std.StringHashMapUnmanaged(*ir.Entity), e: *const ir.Entity, t: *const ir.Entity, n: []const u8) !bool {
    for (rules_text.block_rows) |br| if (br.key_field.len > 0 and std.mem.eql(u8, br.field, n)) {
        const tk = valueOf(blocks, t, br.key_field, 0) orelse return false;
        const ek = valueOf(blocks, e, br.key_field, 0) orelse return true;
        return sameText(a, ek, tk);
    };
    return true;
}

/// The value a `kind` block writes for field `n` (sameAsOf `value`) to take none from its
/// `same_as` block: what it has without one. Null: none to write.
fn emptyOf(a: Allocator, kind: []const u8, n: []const u8, cat: schema.SameAs) !?*const ir.Expr {
    std.debug.assert(cat == .value);
    const x = try a.create(ir.Expr);
    if (std.mem.eql(u8, n, "look")) {
        x.* = .{ .line = 0, .kind = .{ .lit = .nil } };
        return x;
    }
    if (std.mem.startsWith(u8, n, "action")) {
        x.* = .{ .line = 0, .kind = .{ .word = "none" } };
        return x;
    }
    const fd = schema.ogField(schema.blockHost(kind) orelse return null, n) orelse return null;
    if (std.mem.startsWith(u8, fd.type_name, "list<")) {
        x.* = .{ .line = 0, .kind = .{ .list = &.{} } };
        return x;
    }
    // A hero's `armor` is points, no class: a number.
    if (std.mem.eql(u8, n, "armor") and std.mem.eql(u8, kind, "hero")) return initialExpr(a, .int);
    // An engine enum's: its value numbered 0 (`ItemPlace` ground).
    if (fd.type_name.len > 0) return if (try enumZero(a, fd.type_name)) |w| blk: {
        x.* = .{ .line = 0, .kind = .{ .word = w } };
        break :blk x;
    } else null;
    if (fd.check != null) return null;
    return initialOf(a, kind, n);
}

/// The name of engine enum `type_name`'s value numbered 0 (foundation/types.ogs); null: none.
fn enumZero(a: Allocator, type_name: []const u8) !?[]const u8 {
    var diag: script.ogs.parser.Diagnostic = .{};
    const u = script.ogs.parser.parse(a, script.traits.types, "types.ogs", &diag) catch return null;
    for (u.modules) |m| for (m.enums) |en| if (std.mem.eql(u8, en.name, type_name)) {
        for (en.values, 0..) |v, i| if ((v.number orelse @as(i32, @intCast(i))) == 0) return v.name;
    };
    return null;
}

/// A type's initial value (`0`, `0.0`, `""`); null: another type.
fn initialExpr(a: Allocator, t: ir.Type) !?*const ir.Expr {
    const x = try a.create(ir.Expr);
    x.* = .{ .line = 0, .kind = .{ .lit = switch (t) {
        .int => .{ .int = 0 },
        .float => .{ .float = 0 },
        .string => .{ .string = "" },
        else => return null,
    } } };
    return x;
}

/// Setting row `c` says something to the engine: a name its code reads (rules/adjust_defaults.zig)
/// with a value other than that default. The rest (the exe's Classic tables' names: a
/// project's blocks hold those as numbers) is left out.
fn settingNeeded(c: ir.Call) bool {
    const n = schema.text(namedArg(c, "name") orelse return true) orelse return true;
    const d = @import("../rules.zig").adjust.defaultOf(n) orelse return false;
    if (namedArg(c, "rgba")) |x| {
        const items = switch (x.kind) {
            .list => |l| l,
            .call => |cc| cc.args,
            else => return true,
        };
        if (d != .rgba or items.len != 3) return true;
        for (items, d.rgba) |it, want| if ((schema.int(it) orelse return true) != want) return true;
        return false;
    }
    const v = schema.number(namedArg(c, "int") orelse namedArg(c, "float") orelse return true) orelse return true;
    const want: f32 = switch (d) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        .rgba => return true,
    };
    return v != want;
}

/// `p`'s last `::` part (`items::ItemClass` → `ItemClass`).
fn lastPart(p: []const u8) []const u8 {
    return if (std.mem.lastIndexOf(u8, p, "::")) |k| p[k + 2 ..] else p;
}

/// Action row `r` by number written by its name alone (the rules number it) and its menu
/// text by interface key (`label = "open"`, core/ui_text.zig); null: another row.
fn actionRow(a: Allocator, r: *const ir.Expr) !?*const ir.Expr {
    if (r.kind != .call) return null;
    var c = r.kind.call;
    if (!std.mem.eql(u8, c.text, "Action")) return null;
    const id = schema.int(namedArg(c, "classic_id") orelse return null) orelse return null;
    const text = if (namedArg(c, "text")) |t| schema.int(t) orelse 0 else 0;
    const key = core.ui_text.keyOf(if (text != 0) text else id);
    var ns: std.ArrayList(ir.Named) = .empty;
    for (c.named) |n| {
        if (std.mem.eql(u8, n.name, "classic_id") or (key != null and std.mem.eql(u8, n.name, "text"))) continue;
        try ns.append(a, n);
        if (std.mem.eql(u8, n.name, "name")) if (key) |k| {
            const x = try a.create(ir.Expr);
            x.* = .{ .line = n.value.line, .kind = .{ .lit = .{ .string = core.ui_text.keyName(k) } } };
            try ns.append(a, .{ .name = "label", .value = x });
        };
    }
    c.named = ns.items;
    const out = try a.create(ir.Expr);
    out.* = r.*;
    out.kind = .{ .call = c };
    return out;
}

/// A profile's tile-scoring fields (rules_text.zig Profiles reads them back).
fn isScoringField(n: []const u8) bool {
    for ([_][]const u8{ "weapons", "follow_lock", "score", "wakeful", "near" }) |x| if (std.mem.eql(u8, x, n)) return true;
    return false;
}

/// Classic AiScoring row `c` as an ai_profile's own fields into `out`: `keep` its
/// `weapons = by_health` (all: none); `occupant` generic and `a` (one for a monster: the
/// hero priority is the heroes' autoplay) none, `no_lock` `follow_lock = false`, `foes`
/// that and `ally_penalty = 0` (scoring A over opponents alone), `none` with its `script`
/// `score = ai_scoring::Avenge`; `wakeful = true`; `near = @grandma`. Its `tile` is its
/// script's (the Incubus's whole tile).
fn scoringFields(a: Allocator, c: ir.Call, out: *std.ArrayList(ir.Named)) !void {
    const mk = struct {
        fn f(al: Allocator, k: ir.Expr.Kind) !*const ir.Expr {
            const x = try al.create(ir.Expr);
            x.* = .{ .line = 0, .kind = k };
            return x;
        }
    }.f;
    if (namedArg(c, "keep")) |v| if (schema.text(v) orelse (if (v.kind == .word) v.kind.word else null)) |k| if (!std.mem.eql(u8, k, "all"))
        try out.append(a, .{ .name = "weapons", .value = try mk(a, .{ .word = k }) });
    const occ = if (namedArg(c, "occupant")) |v| schema.text(v) orelse (if (v.kind == .word) v.kind.word else "") else "";
    if (std.mem.eql(u8, occ, "no_lock") or std.mem.eql(u8, occ, "foes")) try out.append(a, .{ .name = "follow_lock", .value = try mk(a, .{ .lit = .{ .bool = false } }) });
    if (std.mem.eql(u8, occ, "foes")) {
        const pen = try mk(a, .{ .lit = .{ .int = 0 } });
        const had = for (out.items) |*f| {
            if (std.mem.eql(u8, f.name, "ally_penalty")) {
                f.value = pen;
                break true;
            }
        } else false;
        if (!had) try out.append(a, .{ .name = "ally_penalty", .value = pen });
    }
    if (namedArg(c, "script")) |v| if (schema.text(v)) |sname| if (sname.len > 0)
        try out.append(a, .{ .name = "score", .value = try mk(a, .{ .word = sname }) });
    // `wakeful = true` (the rules' bool; 1 in older text).
    if (namedArg(c, "wakeful")) |v| if ((v.kind == .lit and v.kind.lit == .bool and v.kind.lit.bool) or (schema.int(v) orelse 0) != 0) try out.append(a, .{ .name = "wakeful", .value = try mk(a, .{ .lit = .{ .bool = true } }) });
    if (namedArg(c, "near")) |v| if (schema.text(v)) |n| if (n.len > 0) try out.append(a, .{ .name = "near", .value = try mk(a, .{ .ref = n }) });
}

/// AiScoring row `r` of a special occupant or tile (the exe's: avenge, sleep_hunter,
/// heroes_only, whole) written as its component of core/classic.zig ai_scoring_ogs
/// (`occupant = "none"`, `script = "ai_scoring::Avenge"`); null: another row.
fn scoringRow(a: Allocator, r: *const ir.Expr) !?*const ir.Expr {
    if (r.kind != .call) return null;
    var c = r.kind.call;
    if (!std.mem.eql(u8, c.text, "AiScoring")) return null;
    var comp: ?[]const u8 = null;
    for (c.named) |n| if (std.mem.eql(u8, n.name, "occupant") or std.mem.eql(u8, n.name, "tile")) {
        const v = schema.text(n.value) orelse if (n.value.kind == .word) n.value.kind.word else continue;
        for (core.classic.ai_scoring_parts) |p| if (std.mem.eql(u8, p[0], v)) {
            comp = p[1];
        };
    };
    const script_name = comp orelse return null;
    var ns: std.ArrayList(ir.Named) = .empty;
    for (c.named) |n| {
        if (std.mem.eql(u8, n.name, "tile")) continue;
        if (std.mem.eql(u8, n.name, "occupant")) {
            const x = try a.create(ir.Expr);
            x.* = .{ .line = n.value.line, .kind = .{ .lit = .{ .string = "none" } } };
            try ns.append(a, .{ .name = n.name, .value = x });
        } else try ns.append(a, n);
    }
    const x = try a.create(ir.Expr);
    x.* = .{ .line = r.line, .kind = .{ .lit = .{ .string = script_name } } };
    try ns.append(a, .{ .name = "script", .value = x });
    c.named = ns.items;
    const out = try a.create(ir.Expr);
    out.* = r.*;
    out.kind = .{ .call = c };
    return out;
}

/// Row `r` (Abilities, AiProfile) by fighter class number written by the class's name
/// (`class_name = "puppet"`, rules/fighter_classes.zig); null: another row.
fn fighterClassRow(a: Allocator, r: *const ir.Expr) !?*const ir.Expr {
    if (r.kind != .call) return null;
    var c = r.kind.call;
    if (!std.mem.eql(u8, c.text, "Abilities") and !std.mem.eql(u8, c.text, "AiProfile")) return null;
    const v = namedArg(c, "class") orelse return null;
    const name = rules.fighter_classes.nameOf(schema.int(v) orelse return null) orelse return null;
    var ns: std.ArrayList(ir.Named) = .empty;
    for (c.named) |n| if (std.mem.eql(u8, n.name, "class")) {
        const x = try a.create(ir.Expr);
        x.* = .{ .line = n.value.line, .kind = .{ .lit = .{ .string = name } } };
        try ns.append(a, .{ .name = "class_name", .value = x });
    } else try ns.append(a, n);
    c.named = ns.items;
    const out = try a.create(ir.Expr);
    out.* = r.*;
    out.kind = .{ .call = c };
    return out;
}

/// Row `r` is a weapon class's (WeaponClass, Pattern) with a name.
fn classRow(r: *const ir.Expr) bool {
    if (r.kind != .call) return false;
    const c = r.kind.call;
    if (!std.mem.eql(u8, c.text, "WeaponClass") and !std.mem.eql(u8, c.text, "Pattern")) return false;
    for (c.named) |n| if (std.mem.eql(u8, n.name, "name")) return true;
    return false;
}

/// Text row `r` (`UiText(id = 89, …)`) of a number no block has, nothing keeps, the code
/// sets to no object and no interface key is (core/ui_text.zig): its Classic file (as
/// `.og/classic_ids.txt` lists it, `!string.tab`) and number; null: another row.
fn deadText(r: *const ir.Expr, groups: anytype, hard: *const std.AutoHashMapUnmanaged(i32, void), coded: *const std.AutoHashMapUnmanaged(i32, void)) ?struct { file: []const u8, n: i32 } {
    if (r.kind != .call) return null;
    const c = r.kind.call;
    const files = [_][2][]const u8{ .{ "UiText", "!string.tab" }, .{ "Examine", "!items.inf" }, .{ "AreaExamine", "!activeareas.inf" } };
    const file = for (files) |f| {
        if (std.mem.eql(u8, c.text, f[0])) break f[1];
    } else return null;
    for (c.named) |n| if (std.mem.eql(u8, n.name, "id")) {
        const x = schema.int(n.value) orelse return null;
        if (groups.contains(x) or hard.contains(x) or coded.contains(x) or core.ui_text.keyOf(x) != null) return null;
        return .{ .file = file, .n = x };
    };
    return null;
}

/// `e`'s whole numbers in order (a list's, a "34 98" string's).
fn intsInOrder(a: Allocator, out: *std.ArrayList(i32), e: *const ir.Expr) !void {
    if (schema.int(e)) |x| return out.append(a, x);
    if (schema.text(e)) |t| {
        var it = std.mem.tokenizeAny(u8, t, " ,");
        while (it.next()) |x| if (std.fmt.parseInt(i32, x, 10)) |n| try out.append(a, n) else |_| {};
        return;
    }
    switch (e.kind) {
        .list => |l| for (l) |x| try intsInOrder(a, out, x),
        .call => |c| if (std.ascii.eqlIgnoreCase(c.text, "list")) for (c.args) |x| try intsInOrder(a, out, x),
        else => {},
    }
}

fn refsInEntity(a: Allocator, hard: *std.AutoHashMapUnmanaged(i32, void), soft: *std.ArrayList(SoftRef), lists: *std.ArrayList(SoftList), e: ir.Entity) !void {
    for (e.fields) |*f| {
        // A weapon's stage fields take a weapon archetype (`hit_from = ~w"weapons::rocket"`).
        const stage = for ([_][]const u8{ "effects_from", "flash_from", "launch_from", "hit_from" }) |k| {
            if (std.mem.eql(u8, f.name, k)) break true;
        } else false;
        if (stage) if (schema.int(f.value)) |x| if (x > 0) {
            try soft.append(a, .{ .at = @constCast(f), .n = x, .sigil = .weapon });
            continue;
        };
        try refsIn(a, hard, soft, lists, f.value);
    }
    for (e.attach) |x| for (x.params) |p| try refsIn(a, hard, soft, lists, p.value);
    for (e.rows) |r| try refsIn(a, hard, soft, lists, r);
    for (e.children) |c| try refsInEntity(a, hard, soft, lists, c);
}

/// Blocks `es` (and their inner ones) of `classic_id = -1`: `pickable = false` instead.
fn unpickable(a: Allocator, es: []const ir.Entity) !void {
    for (@constCast(es)) |*e| {
        try unpickable(a, e.children);
        for (e.fields, 0..) |f, i| if (std.mem.eql(u8, f.name, "classic_id") and schema.int(f.value) == -1) {
            const fs = try a.dupe(ir.Named, e.fields);
            const v = try a.create(ir.Expr);
            v.* = .{ .line = f.value.line, .kind = .{ .lit = .{ .bool = false } } };
            fs[i] = .{ .name = "pickable", .value = v };
            e.fields = fs;
            break;
        };
    }
}

/// `e` (a list of numbers, nested or not, or a "34 98" string: a list) with its numbers,
/// in order (intsInOrder's), the next of `items` from `k`.
fn reshape(a: Allocator, e: *const ir.Expr, items: []const *const ir.Expr, k: *usize) !*const ir.Expr {
    if (schema.int(e) != null) {
        k.* += 1;
        return items[k.* - 1];
    }
    var out: std.ArrayList(*const ir.Expr) = .empty;
    if (schema.text(e)) |t| {
        var it = std.mem.tokenizeAny(u8, t, " ,");
        while (it.next()) |x| if (std.fmt.parseInt(i32, x, 10)) |_| {
            try out.append(a, items[k.*]);
            k.* += 1;
        } else |_| {};
    } else if (e.kind == .list) {
        for (e.kind.list) |x| try out.append(a, try reshape(a, x, items, k));
    } else if (e.kind == .call and std.ascii.eqlIgnoreCase(e.kind.call.text, "list")) {
        for (e.kind.call.args) |x| try out.append(a, try reshape(a, x, items, k));
    } else return e;
    const v = try a.create(ir.Expr);
    v.* = .{ .line = e.line, .kind = .{ .list = out.items } };
    return v;
}

/// Every whole number in `e` (a list's, a call's arguments) into `kept`.
fn allInts(a: Allocator, kept: *std.AutoHashMapUnmanaged(i32, void), e: *const ir.Expr) !void {
    if (schema.int(e)) |x| return kept.put(a, x, {});
    // A list written as a string (`weapons = "34 98 1022"`, `random = "1045 1047"`).
    if (schema.text(e)) |t| {
        var it = std.mem.tokenizeAny(u8, t, " ,");
        while (it.next()) |x| if (std.fmt.parseInt(i32, x, 10)) |n| try kept.put(a, n, {}) else |_| {};
        return;
    }
    switch (e.kind) {
        .list => |l| for (l) |x| try allInts(a, kept, x),
        .call => |c| {
            for (c.args) |x| try allInts(a, kept, x);
            for (c.named) |n| try allInts(a, kept, n.value);
        },
        else => {},
    }
}

/// `f` without its statements `host.classic_id = <number>;` (any depth).
fn dropIdSets(a: Allocator, f: *ir.Fn) !void {
    f.body = try withoutIdSets(a, f.body);
}

fn withoutIdSets(a: Allocator, body: []const ir.Stmt) ![]const ir.Stmt {
    var out: std.ArrayList(ir.Stmt) = .empty;
    for (body) |st| {
        var x = st;
        switch (x.kind) {
            .assign => |as| {
                const name = switch (as.target) {
                    .member => |m| if (m.obj.kind == .host) m.text else "",
                    .field => |fl| fl.text,
                    else => "",
                };
                if (std.mem.eql(u8, name, "classic_id") and schema.int(as.value) != null) continue;
            },
            .@"if" => |*i| {
                i.then = try withoutIdSets(a, i.then);
                i.@"else" = try withoutIdSets(a, i.@"else");
            },
            .@"while" => |*w| w.body = try withoutIdSets(a, w.body),
            .for_in => |*fi| fi.body = try withoutIdSets(a, fi.body),
            else => {},
        }
        try out.append(a, x);
    }
    return out.items;
}

/// In `body`, each `*::GetNameID(x) == N` (`!=`) whose N `single` maps to paths made
/// `object::GetClass(x) == "<path>"` for each (OG: GetClass is the archetype's path); how many.
fn classOfIds(a: Allocator, body: []const ir.Stmt, single: *const std.AutoHashMapUnmanaged(i32, []const []const u8)) !usize {
    var n: usize = 0;
    for (body) |st| switch (st.kind) {
        .expr, .@"return" => |e| n += try classOfIdsIn(a, e, single),
        .assign => |x| {
            // `action = 2;`: the action by its name (`action = "Close";`, the runtime's field word).
            if (actionField(targetText(x.target))) if (schema.int(x.value)) |v| if (actionWordOf(v)) |w| {
                @constCast(x.value).* = .{ .line = x.value.line, .span = x.value.span, .kind = .{ .lit = .{ .string = w } } };
                n += 1;
            };
            n += try classOfIdsIn(a, x.value, single);
        },
        .@"if" => |x| n += try classOfIdsIn(a, x.cond, single) + try classOfIds(a, x.then, single) + try classOfIds(a, x.@"else", single),
        .@"while" => |x| n += try classOfIdsIn(a, x.cond, single) + try classOfIds(a, x.body, single),
        .for_in => |x| {
            n += try classOfIdsIn(a, x.iter, single) + try classOfIds(a, x.body, single);
            if (x.to) |t| n += try classOfIdsIn(a, t, single);
        },
        else => {},
    };
    return n;
}

fn classOfIdsIn(a: Allocator, e: *const ir.Expr, single: *const std.AutoHashMapUnmanaged(i32, []const []const u8)) anyerror!usize {
    var n: usize = 0;
    switch (e.kind) {
        .binary => |b| {
            // `action == -1`: `action == object::ActionId("walk")`.
            if (b.op == .eq or b.op == .ne) for ([_]bool{ false, true }) |swap| {
                const f = if (swap) b.rhs else b.lhs;
                const lit = if (swap) b.lhs else b.rhs;
                if (!actionField(exprField(f))) continue;
                const w = actionWordOf(schema.int(lit) orelse continue) orelse continue;
                const sx = try a.create(ir.Expr);
                sx.* = .{ .line = lit.line, .span = lit.span, .kind = .{ .lit = .{ .string = w } } };
                const args = try a.dupe(*const ir.Expr, &.{sx});
                @constCast(lit).* = .{ .line = lit.line, .span = lit.span, .kind = .{ .call = .{ .id = 0, .text = "object::ActionId", .args = args } } };
                n += 1;
            };
            if (b.op == .eq or b.op == .ne) for ([_]bool{ false, true }) |swap| {
                const call = if (swap) b.rhs else b.lhs;
                const num = if (swap) b.lhs else b.rhs;
                if (call.kind != .call or !std.mem.endsWith(u8, call.kind.call.text, "GetNameID") or call.kind.call.args.len > 1) continue;
                const paths = single.get(schema.int(num) orelse continue) orelse continue;
                // Each path its comparison, joined by `or` (`!=`: `and`), in place of `e`.
                var out: ?*ir.Expr = null;
                for (paths) |path| {
                    const c = try a.create(ir.Expr);
                    c.* = call.*;
                    c.kind.call.text = "object::GetClass";
                    const v = try a.create(ir.Expr);
                    v.* = .{ .line = num.line, .span = num.span, .kind = .{ .lit = .{ .string = path } } };
                    const cmp = try a.create(ir.Expr);
                    cmp.* = .{ .line = e.line, .span = e.span, .kind = .{ .binary = .{ .op = b.op, .lhs = c, .rhs = v } } };
                    out = if (out) |o| blk: {
                        const j = try a.create(ir.Expr);
                        j.* = .{ .line = e.line, .span = e.span, .kind = .{ .logic = .{ .op = if (b.op == .eq) .@"or" else .@"and", .lhs = o, .rhs = cmp } } };
                        break :blk j;
                    } else cmp;
                }
                @constCast(e).* = out.?.*;
                return 1;
            };
            n += try classOfIdsIn(a, b.lhs, single) + try classOfIdsIn(a, b.rhs, single);
        },
        .call => |c| {
            // item::SetFuncID(x, 2): the action by its name.
            if (std.mem.eql(u8, c.text, "item::SetFuncID") and c.args.len == 2) if (schema.int(c.args[1])) |v| if (actionWordOf(v)) |w| {
                const x = try a.create(ir.Expr);
                x.* = .{ .line = c.args[1].line, .span = c.args[1].span, .kind = .{ .lit = .{ .string = w } } };
                @constCast(c.args)[1] = x;
                n += 1;
            };
            // A popup's interface text by its key (core/ui_text.zig), no number.
            if (std.mem.eql(u8, c.text, "actor::TextEffect") and c.args.len == 2) if (schema.int(c.args[1])) |t| if (core.ui_text.keyOf(t)) |k| {
                const v = try a.create(ir.Expr);
                v.* = .{ .line = c.args[1].line, .span = c.args[1].span, .kind = .{ .lit = .{ .string = core.ui_text.keyName(k) } } };
                @constCast(c.args)[1] = v;
                n += 1;
            };
            for (c.args) |x| n += try classOfIdsIn(a, x, single);
            for (c.named) |x| n += try classOfIdsIn(a, x.value, single);
        },
        .exe => |c| for (c.args) |x| {
            n += try classOfIdsIn(a, x, single);
        },
        .unary => |u| n += try classOfIdsIn(a, u.operand, single),
        .logic => |l| n += try classOfIdsIn(a, l.lhs, single) + try classOfIdsIn(a, l.rhs, single),
        .assign => |x| n += try classOfIdsIn(a, x.value, single),
        .list => |l| for (l) |x| {
            n += try classOfIdsIn(a, x, single);
        },
        else => {},
    }
    return n;
}

/// The OnUpdate method of component `c`, if any.
fn onUpdate(c: *const ir.Component) ?*const ir.Fn {
    for (c.methods) |f| if (std.mem.eql(u8, f.name, "OnUpdate")) return f;
    return null;
}

/// The map area statement `st` is the trigger of: an `if` whose condition is
/// `hero::AnyInArea("<area>")`, alone or `and` something.
fn triggerArea(st: ir.Stmt) ?[]const u8 {
    if (st.kind != .@"if") return null;
    return anyInArea(st.kind.@"if".cond);
}

fn anyInArea(e: *const ir.Expr) ?[]const u8 {
    switch (e.kind) {
        .call => |c| if (std.mem.eql(u8, c.text, "hero::AnyInArea") and c.args.len == 1) {
            const x = c.args[0];
            if (x.kind == .lit and x.kind.lit == .string) return x.kind.lit.string;
        },
        .logic => |l| if (l.op == .@"and") return anyInArea(l.lhs) orelse anyInArea(l.rhs),
        else => {},
    }
    return null;
}

fn wordIn(words: std.StringHashMapUnmanaged(void), name: []const u8) bool {
    var buf: [128]u8 = undefined;
    if (name.len > buf.len) return false;
    return words.contains(std.ascii.lowerString(&buf, name));
}

/// The most derived engine trait every host kind of `kinds` is (`item`, `weapon` → Item).
fn commonHost(kinds: []const []const u8) ?*const script.traits.Trait {
    var t = script.traits.ofHost(kinds[0]) orelse return null;
    while (true) {
        const all = for (kinds) |k| {
            if (!isA(script.traits.ofHost(k) orelse return null, t.name)) break false;
        } else true;
        if (all and t.host != null) return t;
        if (t.supers.len == 0) return null;
        t = script.traits.find(t.supers[0]) orelse return null;
    }
}

fn isA(t: *const script.traits.Trait, name: []const u8) bool {
    if (std.mem.eql(u8, t.name, name)) return true;
    for (t.supers) |s| if (script.traits.find(s)) |x| if (isA(x, name)) return true;
    return false;
}

/// Functions the engine calls by name beside the events (`traits.classic`) and the
/// actions' (rules.actions): `rt.callIfExists`/`call` in world/, game/, combat/, inventory/.
/// shortcut: kept by hand; a new engine call by name belongs here too, or conversion drops
/// an inherited function only it calls.
const engine_calls = [_][]const u8{ "UniversalTake", "OnDeath", "OnSpawn", "CombatEnemiesAppear", "AfterBattle", "NodeResponse", "CheckCode", "post_init_box", "LevelSwitch", "UseItem" };

/// Words of `text` (letters, digits, `_`; lower case) counted into `words`, the word after
/// `function` into `defs` too.
fn countWords(a: Allocator, text: []const u8, words: *std.StringHashMapUnmanaged(u32), defs: *std.StringHashMapUnmanaged(u32)) !void {
    var after_function = false;
    var i: usize = 0;
    while (i < text.len) {
        if (!isWordByte(text[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and isWordByte(text[i])) i += 1;
        var buf: [128]u8 = undefined;
        if (i - start > buf.len) continue;
        const w = std.ascii.lowerString(&buf, text[start..i]);
        const g = try words.getOrPut(a, w);
        if (!g.found_existing) {
            g.key_ptr.* = try a.dupe(u8, w);
            g.value_ptr.* = 0;
        }
        g.value_ptr.* += 1;
        if (after_function) {
            const d = try defs.getOrPut(a, g.key_ptr.*);
            if (!d.found_existing) d.value_ptr.* = 0;
            d.value_ptr.* += 1;
        }
        after_function = std.mem.eql(u8, w, "function");
    }
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test "countWords: a definition alone is no mention, a string is" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    var words: std.StringHashMapUnmanaged(u32) = .empty;
    var defs: std.StringHashMapUnmanaged(u32) = .empty;
    try countWords(arena.allocator(), "function dump() { MessageBox(\"x\"); };\nfunction Take(h) { QueueCall(h, \"me\", \"UniversalTake\"); };", &words, &defs);
    try std.testing.expectEqual(@as(u32, 1), words.get("dump").?);
    try std.testing.expectEqual(@as(u32, 1), defs.get("dump").?);
    try std.testing.expectEqual(@as(u32, 1), words.get("universaltake").?);
    try std.testing.expectEqual(@as(?u32, null), defs.get("universaltake"));
}

fn genericHitDelay(rt: *Runtime, w: *Writer, depth: usize, state: []Slot, v: Value) !void {
    if (v != .int or v.int <= 0 or slotOf(state, "hit_delay") != null) return;
    const owner = slotOf(state, "owner") orelse return;
    if (owner.value != .string) return;
    const o = rt.findObject(owner.value.string) orelse return;
    if (o.getInt("battle_class") != @backingInt(@import("../battle.zig").fighter.Class.generic)) return;
    try indent(w, depth + 1);
    try w.print("var int hit_delay = {d};\n", .{v.int});
}

/// A variable of the Classic start state.
const Slot = struct { name: []const u8, type: ir.Type, value: Value };

/// The generic fighter's (`battle_class` 100) own `resist` ("fire gas") and `armor_class`
/// (0-3) as its `immunity = Resist(resist = [fire, gas], armor = -1);` at `depth` into `w`
/// (core/immunity.zig register: the same entry); false: none set.
/// shortcut: the game has no such fighter (a mod's may); one with a Resist row of its
/// classic_id too would have two `immunity`, a build error then.
fn genericImmunity(state: []Slot, w: *Writer, depth: usize) !bool {
    const ct = slotOf(state, "battle_class") orelse return false;
    if (ct.value != .int or ct.value.int != 100) return false;
    const words: []const u8 = if (slotOf(state, "resist")) |r| (if (r.value == .string) r.value.string else "") else "";
    const ac: i32 = if (slotOf(state, "armor_class")) |c| (if (c.value == .int) c.value.int else 0) else 0;
    if (std.mem.trim(u8, words, " ,;\t").len == 0 and ac == 0) return false;
    try indent(w, depth);
    try w.writeAll("immunity = Resist(resist = [");
    var it = std.mem.tokenizeAny(u8, words, ", ;\t");
    var n: usize = 0;
    // The engine's words (`decoy` → attract, `cold` → freeze: rules.resistIndex), foundation's Resistance.
    while (it.next()) |x| if (rules.resistIndex(x)) |i| {
        try w.print("{s}{s}", .{ if (n > 0) ", " else "", @tagName(@as(immunity.Resist, @fromBackingInt(@as(u4, @intCast(i + 1))))) });
        n += 1;
    };
    try w.print("], armor = {d});\n", .{-std.math.clamp(ac, 0, 3)});
    return true;
}

/// The Abilities row of fighter object `name` (its start state `state`) that the Classic
/// reader's field rule gives it (core/classic.zig `fromFields`: the generic fighter,
/// `battle_class` 100, with `ai = "stationary"` never walks), keyed by its name; null: none.
/// The game has no such fighter: a mod's may.
fn fieldRow(a: Allocator, name: []const u8, state: []Slot) !?[]const u8 {
    const ct = slotOf(state, "battle_class") orelse return null;
    const ai = slotOf(state, "ai") orelse return null;
    if (ct.value != .int or ct.value.int != 100 or ai.value != .string or !std.ascii.eqlIgnoreCase(ai.value.string, "stationary")) return null;
    return try std.fmt.allocPrint(a, "Abilities(fighter_class = \"{s}\", class = 100, immobile = 1);\n", .{name});
}

test "genericImmunity: the generic fighter's resist and armor_class as its immunity row" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var st = [_]Slot{ .{ .name = "battle_class", .type = .int, .value = .{ .int = 100 } }, .{ .name = "resist", .type = .string, .value = .{ .string = "Fire, decoy cold" } }, .{ .name = "armor_class", .type = .int, .value = .{ .int = 2 } } };
    try std.testing.expect(try genericImmunity(&st, &out.writer, 1));
    try std.testing.expectEqualStrings("    immunity = Resist(resist = [fire, attract, freeze], armor = -2);\n", out.written());
    // Not the generic fighter, or nothing set: none.
    st[0].value = .{ .int = 6 };
    try std.testing.expect(!try genericImmunity(&st, &out.writer, 1));
    st[0].value = .{ .int = 100 };
    st[1].value = .{ .string = "" };
    st[2].value = .{ .int = 0 };
    try std.testing.expect(!try genericImmunity(&st, &out.writer, 1));
}

test "fieldRow: the generic fighter told to stand gets its own immobile row" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var st = [_]Slot{ .{ .name = "battle_class", .type = .int, .value = .{ .int = 100 } }, .{ .name = "ai", .type = .string, .value = .{ .string = "Stationary" } } };
    const r = (try fieldRow(a, "01pr_turret", &st)).?;
    try std.testing.expectEqualStrings("Abilities(fighter_class = \"01pr_turret\", class = 100, immobile = 1);\n", r);
    // The row reads back as the rules read it: immobile, by the object's name.
    var diag: parser.Diagnostic = .{};
    const u = try parser.parse(a, r, "f", &diag);
    const row = try @import("../loaders.zig").codec.read(core.behaviour.Abilities, a, u.modules[0].rows[0].kind.call, null);
    try std.testing.expect(row.immobile and row.class == 100 and std.mem.eql(u8, row.fighter_class, "01pr_turret"));
    st[1].value = .{ .string = "guard" };
    try std.testing.expect(try fieldRow(a, "x", &st) == null);
    st[1].value = .{ .string = "stationary" };
    st[0].value = .{ .int = 7 };
    try std.testing.expect(try fieldRow(a, "x", &st) == null);
}

fn slotOf(state: []Slot, name: []const u8) ?*Slot {
    for (state) |*s| if (std.ascii.eqlIgnoreCase(s.name, name)) return s;
    return null;
}

/// A look being made: its calls in order, the model's fields it holds.
const LookB = struct {
    calls: std.ArrayList(Call) = .empty,
    fields: std.ArrayList(Slot) = .empty,
    /// The file of its first call (`act_grandma.ss`): its name.
    origin: ?[]const u8 = null,

    const Call = struct {
        name: []const u8,
        args: []const Value,

        /// The animation it names (a model's, the build checks it); "" none.
        fn anim(c: Call) []const u8 {
            if (std.mem.eql(u8, c.name, "RegisterIdleAnimation")) return c.args[1].string;
            if (std.mem.eql(u8, c.name, "RegisterAnimation")) return c.args[2].string;
            return "";
        }
    };

    fn any(self: LookB) bool {
        return self.calls.items.len > 0;
    }

    fn field(self: LookB, name: []const u8) ?Value {
        for (self.fields.items) |f| if (std.ascii.eqlIgnoreCase(f.name, name)) return f.value;
        return null;
    }

    /// Call `name(args)` as look data where its arguments are what the builtin takes
    /// (builtins/actors.zig: of another type it does nothing, so it stays code); false: not.
    fn add(self: *LookB, a: Allocator, name: []const u8, args: []const Value, file: []const u8) !bool {
        const ok = if (std.ascii.eqlIgnoreCase(name, "ActorSetWalkSpeed"))
            args.len >= 2 and args[0] == .string and args[1] == .float
        else if (std.ascii.eqlIgnoreCase(name, "RegisterIdleAnimation"))
            args.len >= 3 and args[0] == .int and args[0].int >= 0 and args[0].int < 9 and args[1] == .string and args[2] == .int
        else if (std.ascii.eqlIgnoreCase(name, "RegisterAnimation"))
            args.len >= 3 and args[0] == .int and args[0].int >= 0 and args[0].int < 9 and args[1] == .string and args[2] == .string
        else
            args.len >= 1 and args[0] == .string;
        // Without a weight the exe registers nothing (builtins/actors.zig): no data, the call goes.
        if (!ok) return std.ascii.eqlIgnoreCase(name, "RegisterIdleAnimation") and args.len == 2 and args[0] == .int and args[1] == .string;
        if (self.origin == null) self.origin = file;
        for (look_calls) |n| if (std.ascii.eqlIgnoreCase(n, name)) try self.calls.append(a, .{ .name = n, .args = args });
        return true;
    }

    /// Its calls as the look's fields (`walk`, `idles`, `slots`, `not_in_place`, `reference`).
    fn text(self: LookB, a: Allocator, out: *std.ArrayList(u8)) !void {
        const lists = [_]struct { []const u8, []const u8 }{ .{ "walk", "ActorSetWalkSpeed" }, .{ "idles", "RegisterIdleAnimation" }, .{ "slots", "RegisterAnimation" }, .{ "not_in_place", "NotInPlaceAnimation" } };
        for (lists) |l| {
            var n: usize = 0;
            for (self.calls.items) |c| if (std.mem.eql(u8, c.name, l[1])) {
                try out.appendSlice(a, if (n == 0) try std.fmt.allocPrint(a, "    {s} = [", .{l[0]}) else ", ");
                n += 1;
                const x = c.args;
                if (std.mem.eql(u8, l[0], "walk")) {
                    try out.appendSlice(a, "Speed(anim = ");
                    try literal(a, out, x[0]);
                    try out.appendSlice(a, ", speed = ");
                    try literal(a, out, x[1]);
                } else if (std.mem.eql(u8, l[0], "idles")) {
                    try out.print(a, "Idle(state = {d}, anim = ", .{x[0].int});
                    try literal(a, out, x[1]);
                    try out.print(a, ", weight = {d}", .{x[2].int});
                } else if (std.mem.eql(u8, l[0], "slots")) {
                    try out.print(a, "Slot(state = {d}, name = ", .{x[0].int});
                    try literal(a, out, x[1]);
                    try out.appendSlice(a, ", anim = ");
                    try literal(a, out, x[2]);
                } else {
                    try literal(a, out, x[0]);
                    continue;
                }
                try out.appendSlice(a, ")");
            };
            if (n > 0) try out.appendSlice(a, "];\n");
        }
        // The last ReferenceAnimation wins, as the builtin sets it.
        var reference: ?Value = null;
        for (self.calls.items) |c| if (std.mem.eql(u8, c.name, "ReferenceAnimation")) {
            reference = c.args[0];
        };
        if (reference) |r| {
            try out.appendSlice(a, "    reference = ");
            try literal(a, out, r);
            try out.appendSlice(a, ";\n");
        }
    }
};

/// A Classic class's own variables nothing reads (every fighter file's `int initok;`): at
/// their initial value not written (tool/convertcheck.zig compares them not either).
/// shortcut: by name (the game's scripts never read it), upgrade to a check of the
/// class's code if a mod's script reads one.
const unread_vars = [_][]const u8{"initok"};

fn isUnreadVar(n: []const u8) bool {
    for (unread_vars) |x| if (std.ascii.eqlIgnoreCase(x, n)) return true;
    return false;
}

/// The engine's calls of these leave their result unread (world/start.zig postinit and
/// additionalIdleAnims, inventory/create.zig class_init): one returning 0 does nothing.
const unread_calls = [_][]const u8{ "postinit", "class_init", "additionalIdleAnims" };

/// Component `c` without the Classic code's leftovers that do nothing: a local's
/// declaration and its plain assignments of a literal where nothing else in its function
/// names it (`var float spd = 1.2;`), then a method of `unread_calls` whose body is no more
/// than `return 0;` with the component's `name();` statements calling it (a method named
/// anywhere else stays). Its methods none left: the caller attaches nothing.
fn pruneDead(a: Allocator, c: *const ir.Component, report: *Report) !*const ir.Component {
    var ms: std.ArrayList(*const ir.Fn) = .empty;
    for (c.methods) |m| try ms.append(a, try deadLocals(a, m, report));
    for (unread_calls) |name| {
        const k = for (ms.items, 0..) |m, i| {
            if (std.ascii.eqlIgnoreCase(m.name, name)) break i;
        } else continue;
        const body = ms.items[k].body;
        const nothing = body.len == 0 or (body.len == 1 and body[0].kind == .@"return" and schema.int(body[0].kind.@"return") == 0);
        if (!nothing) continue;
        // The others without their `name();`: then not named at all.
        var others: std.ArrayList(*const ir.Fn) = .empty;
        const named = for (ms.items, 0..) |m, i| {
            if (i == k) continue;
            var keep: std.ArrayList(ir.Stmt) = .empty;
            for (m.body) |st| if (!(st.kind == .expr and st.kind.expr.kind == .call and st.kind.expr.kind.call.args.len == 0 and std.ascii.eqlIgnoreCase(st.kind.expr.kind.call.text, name))) try keep.append(a, st);
            const nf = try a.create(ir.Fn);
            nf.* = m.*;
            nf.body = keep.items;
            if (try mentions(a, nf, name)) break true;
            try others.append(a, nf);
        } else false;
        if (named) continue;
        ms = others;
        report.dead_code += 1;
    }
    // A method with no body left, of a component of no trait (whose default it would
    // stand for) that nothing calls: as none (the engine calls an event if it is there).
    if (c.traits.len == 0) {
        var i: usize = 0;
        while (i < ms.items.len) {
            const m = ms.items[i];
            const called = m.body.len > 0 or for (ms.items) |o| {
                if (o != m and try mentions(a, o, m.name)) break true;
            } else false;
            if (called) {
                i += 1;
                continue;
            }
            _ = ms.orderedRemove(i);
            report.dead_code += 1;
        }
    }
    if (ms.items.len == c.methods.len and for (ms.items, c.methods) |x, y| {
        if (x != y) break false;
    } else true) return c;
    const nc = try a.create(ir.Component);
    nc.* = c.*;
    nc.methods = ms.items;
    return nc;
}

/// `f` without its dead locals (`pruneDead`).
fn deadLocals(a: Allocator, f: *const ir.Fn, report: *Report) !*const ir.Fn {
    var body = f.body;
    for (f.names, 0..) |n, si| {
        const slot: u16 = @intCast(si);
        const param = for (f.params) |p| {
            if (p.slot == slot) break true;
        } else false;
        if (param or n.len == 0) continue;
        var keep: std.ArrayList(ir.Stmt) = .empty;
        var dropped: usize = 0;
        for (body) |st| {
            const dead = switch (st.kind) {
                .local => |l| l.slot == slot,
                .assign => |x| x.op == .set and x.target == .local and x.target.local == slot and schema.number(x.value) != null,
                else => false,
            };
            if (dead) dropped += 1 else try keep.append(a, st);
        }
        if (dropped == 0) continue;
        const nf = try a.create(ir.Fn);
        nf.* = f.*;
        nf.body = keep.items;
        if (try mentions(a, nf, n)) continue;
        body = keep.items;
        report.dead_code += dropped;
    }
    if (body.ptr == f.body.ptr and body.len == f.body.len) return f;
    const nf = try a.create(ir.Fn);
    nf.* = f.*;
    nf.body = body;
    return nf;
}

/// `f`'s text names `word` (an identifier of its own; an unprintable one: yes).
fn mentions(a: Allocator, f: *const ir.Fn, word: []const u8) !bool {
    var w: std.Io.Writer.Allocating = .init(a);
    // Its body only: its own name is not a use.
    const nf = try a.create(ir.Fn);
    nf.* = f.*;
    nf.name = "_";
    print_ogs.function(&w.writer, nf, 0) catch return true;
    const t = w.written();
    var at: usize = 0;
    while (std.ascii.findIgnoreCasePos(t, at, word)) |k| : (at = k + 1) {
        const before = k == 0 or !(std.ascii.isAlphanumeric(t[k - 1]) or t[k - 1] == '_');
        const e = k + word.len;
        const after = e >= t.len or !(std.ascii.isAlphanumeric(t[e]) or t[e] == '_');
        if (before and after) return true;
    }
    return false;
}

/// Host `h` declares field `n` itself (not its parents), any case, and the engine does
/// not test it for being there: having `walk_range` makes an object a fighter (the exe's
/// rule, fields.isFighter), `battle_class` and `footprint_tiles` one the viewer draws so.
fn ownField(h: *const schema.Host, n: []const u8) bool {
    for ([_][]const u8{ "walk_range", "battle_class", "footprint_tiles" }) |m| if (std.ascii.eqlIgnoreCase(m, n)) return false;
    for (h.fields) |f| if (std.ascii.eqlIgnoreCase(f.name, n)) return true;
    return false;
}

/// One of methods `ms` names `word`.
fn anyMentions(a: Allocator, ms: []const ogsify.Method, word: []const u8) !bool {
    for (ms) |x| if (try mentions(a, x.f, word)) return true;
    return false;
}

/// `item::New(name, "items::<ammo>", owner, 0);`: an empty pack of an ammo archetype.
fn emptyPack(st: ir.Stmt, ammo: *const std.StringHashMapUnmanaged(void)) bool {
    if (st.kind != .expr or st.kind.expr.kind != .call) return false;
    const c = st.kind.expr.kind.call;
    if (c.target != null or !std.mem.eql(u8, c.text, "item::New") or c.args.len != 4) return false;
    const n = c.args[3];
    if (n.kind != .lit or n.kind.lit != .int or n.kind.lit.int != 0) return false;
    const arch = c.args[1];
    return arch.kind == .lit and arch.kind.lit == .string and ammo.contains(arch.kind.lit.string);
}

/// `f` calls `name()` as a statement of its own body (`class_init();`), any case.
fn callsFn(f: *const ir.Fn, name: []const u8) bool {
    for (f.body) |st| if (st.kind == .expr and st.kind.expr.kind == .call and std.ascii.eqlIgnoreCase(st.kind.expr.kind.call.text, name)) return true;
    return false;
}

fn isLookCall(name: []const u8) bool {
    for (look_calls) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

/// The level fields the `Camera(…)` record holds (core/schema.zig camera_fields).
const camera_names = [_][]const u8{ "perspective", "near_plane", "far_plane", "ortho_rotation_radians", "eye_x", "eye_y", "eye_z", "target_x", "target_y", "target_z", "fov", "floor_z", "camera_scale", "aspect_ratio", "camera_bank" };

fn isCameraField(name: []const u8) bool {
    for (camera_names) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

/// `name` is one of record `rec`'s fields (`viewX = …, …`).
fn inCamera(rec: []const u8, name: []const u8) bool {
    var it = std.mem.splitSequence(u8, rec, ", ");
    while (it.next()) |x| if (std.mem.startsWith(u8, x, cameraName(name)) and std.mem.startsWith(u8, x[cameraName(name).len..], " = ")) return true;
    return false;
}

fn cameraName(name: []const u8) []const u8 {
    for (camera_names) |n| if (std.ascii.eqlIgnoreCase(n, name)) return n;
    return name;
}

/// Statement `s` a placing call of a builtin (no function of `cls` by its name):
/// PlaceActor, PlaceCombatActor, AIEnemyAppear; null: another statement.
fn placingCall(s: *const ir.Stmt, cls: *const object.Class) ?ir.Call {
    if (s.kind != .expr or s.kind.expr.kind != .call) return null;
    const c = s.kind.expr.kind.call;
    if (c.target != null or cls.findFunctionId(c.id) != null) return null;
    for ([_][]const u8{ "PlaceActor", "PlaceCombatActor", "AIEnemyAppear" }) |n| if (std.ascii.eqlIgnoreCase(c.text, n)) return c;
    return null;
}

/// `PlaceActor(GUI_GetSelectedHero(), "<point>", 0)`'s point (a level's `entry`); null: another call.
fn entryPoint(c: ir.Call) ?[]const u8 {
    if (c.args.len != 3 or c.args[0].kind != .call) return null;
    const who = c.args[0].kind.call;
    if (who.target != null or who.args.len != 0 or !std.ascii.eqlIgnoreCase(who.text, "GUI_GetSelectedHero")) return null;
    const p = constant(c.args[1]) orelse return null;
    const n = constant(c.args[2]) orelse return null;
    if (p != .string or n != .int or n.int != 0) return null;
    return p.string;
}

/// A constant argument (`-5` is a minus over 5); null: another expression.
fn constant(e: *const ir.Expr) ?Value {
    return switch (e.kind) {
        .lit => |v| switch (v) {
            .int, .float, .string => v,
            else => null,
        },
        .unary => |u| if (u.op == .neg and u.operand.kind == .lit and ir.numeric(u.operand.kind.lit)) ir.neg(u.operand.kind.lit) else null,
        else => null,
    };
}

fn numeric(v: Value) bool {
    return v == .int or v == .float;
}

/// PlaceActor(args) as a `Place(…)` record (builtins/actors.zig biPlaceActor: a tile when
/// its second argument is an int, else an area's point and floor); false: arguments it
/// would not place by (it stays code).
fn place(a: Allocator, out: *std.ArrayList(u8), args: []const Value, battle: bool) !bool {
    _ = battle;
    if (args.len < 3 or args[0] != .string) return false;
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(a, "Place(who = ");
    try ref(a, &s, args[0].string);
    if (args[1] == .int) {
        if (args[2] != .int) return false;
        try s.print(a, ", tile = [{d}, {d}", .{ args[1].int, args[2].int });
        if (args.len > 3 and args[3] == .int and args[3].int != 0) try s.print(a, ", {d}", .{args[3].int});
        try s.appendSlice(a, "]");
    } else {
        if (args[1] != .string or args[2] != .int) return false;
        try s.appendSlice(a, ", at = ");
        try literal(a, &s, args[1]);
        try s.print(a, ", point = {d}", .{args[2].int});
        if (args.len > 3 and args[3] == .int and args[3].int != 0) try s.print(a, ", floor = {d}", .{args[3].int});
    }
    try s.appendSlice(a, ")");
    try out.print(a, "{s}{s}", .{ if (out.items.len > 0) ", " else "", s.items });
    return true;
}

// ------------------------------------------------------------ text

fn indent(w: *Writer, depth: usize) !void {
    for (0..depth) |_| try w.writeAll("    ");
}

fn typeName(t: ir.Type) []const u8 {
    return switch (t) {
        .any => "any",
        else => @tagName(t),
    };
}

/// A word when it is one (`grandma`), else a string (`"01pr_garcia1"`).
fn blockName(a: Allocator, n: []const u8) ![]const u8 {
    var w: std.Io.Writer.Allocating = .init(a);
    try nameOrString(&w.writer, n);
    return w.written();
}

fn isWord(n: []const u8) bool {
    if (n.len == 0 or std.ascii.isDigit(n[0]) or parser.isKeyword(n)) return false;
    for (n) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}

fn nameOrString(w: *Writer, n: []const u8) !void {
    if (isWord(n)) try w.writeAll(n) else try lexer.writeString(w, n);
}

/// `@x`, `@"01pr_x"`.
fn ref(a: Allocator, out: *std.ArrayList(u8), n: []const u8) !void {
    try out.append(a, '@');
    var w: std.Io.Writer.Allocating = .init(a);
    try nameOrString(&w.writer, n);
    try out.appendSlice(a, w.written());
}

/// `v` as an OG Script literal that reads back as the same value (a float keeps a point).
fn literal(a: Allocator, out: *std.ArrayList(u8), v: Value) !void {
    switch (v) {
        .int => |i| try out.print(a, "{d}", .{i}),
        .float => |f| {
            const start = out.items.len;
            try out.print(a, "{d}", .{f});
            if (std.mem.indexOfAny(u8, out.items[start..], ".eEn") == null) try out.appendSlice(a, ".0");
        },
        .string => |s| {
            var w: std.Io.Writer.Allocating = .init(a);
            try lexer.writeString(&w.writer, s);
            try out.appendSlice(a, w.written());
        },
        else => try out.appendSlice(a, "nil"),
    }
}

/// A schema field's value: its enum's word where it has one (`place = hand;`), else the literal.
fn wordOrLiteral(a: Allocator, out: *std.ArrayList(u8), fd: schema.Field, v: Value) !void {
    // A flag's 0/1; another number stays one (none in the game).
    if (fd.flag and v == .int and (v.int == 0 or v.int == 1)) return out.appendSlice(a, if (v.int == 1) "true" else "false");
    // A fighter's class: its name (rules/fighter_classes.zig), the project's own from here.
    if (v == .int and std.mem.eql(u8, fd.name, "battle_class")) if (rules.fighter_classes.nameOf(v.int)) |n| return out.appendSlice(a, n);
    // shortcut: the prelude's types parsed for each such field (items' place and type only).
    if (v == .int and fd.type_name.len > 0) if (try schema.engineEnum(a, fd.type_name)) |e| for (e.values) |x| if (x.number == v.int) return out.appendSlice(a, x.name);
    try literal(a, out, v);
}

/// The game's text as UTF-8 (the project's one encoding).
fn utf8(a: Allocator, s: []const u8, page: formats.cp1251.Page) ![]const u8 {
    return formats.cp1251.toUtf8(a, s, page);
}

test "literals read back as the same value" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const x = arena.allocator();
    for ([_]Value{ .{ .float = 0.2 }, .{ .float = 3 }, .{ .float = -6.7061 }, .{ .int = -1 }, .{ .string = "a\"b" } }) |v| {
        var out: std.ArrayList(u8) = .empty;
        try literal(x, &out, v);
        var diag: parser.Diagnostic = .{};
        const u = try parser.parse(x, try std.fmt.allocPrint(x, "item i {{ hp = {s}; }}", .{out.items}), "t", &diag);
        const e = u.modules[0].entities[0].fields[0].value;
        const got: Value = switch (e.kind) {
            .lit => |l| l,
            .unary => |un| switch (un.operand.kind.lit) {
                .int => |i| .{ .int = -i },
                .float => |f| .{ .float = -f },
                else => unreachable,
            },
            else => unreachable,
        };
        try std.testing.expect(ir.sameSkipping(Value, v, got, &.{}));
    }
}

test "pruneDead: unread locals, a do-nothing class_init and its call, an empty method go" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: parser.Diagnostic = .{};
    const u = try parser.parse(a, "module m { component c for actor { fn OnCreate() { var float spd = 1.2; var int n = 2; mesh = n; class_init(); } fn class_init() { return 0; } fn OnStart() { } } }", "t.ogs", &d);
    var r: Report = .{};
    const m = for (u.modules) |x| {
        if (x.components.len > 0) break x;
    } else return error.TestUnexpectedResult;
    const c = try pruneDead(a, m.components[0], &r);
    try std.testing.expectEqual(@as(usize, 1), c.methods.len);
    var w: std.Io.Writer.Allocating = .init(a);
    try print_ogs.function(&w.writer, c.methods[0], 0);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "spd") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "var int n = 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "class_init") == null);
}

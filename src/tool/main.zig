//! gorky-tool — a utility for exploring Gorky 17 resources.

const std = @import("std");
const devices_mod = og.combat.devices;
const Io = std.Io;
const og = @import("opengorky");
const common = @import("common.zig");
const archive = og.formats.archive;
const resource = og.formats.resource;

const play_script = @import("play_script.zig");
const export_cmd = @import("export.zig");
const battle_cmd = @import("battle.zig");
const check_cmd = @import("check.zig");
const models_cmd = @import("models.zig");
const probe_cmd = @import("probe.zig");
const scenes_cmd = @import("scenes.zig");
const scripts_cmd = @import("scripts.zig");

/// Command arguments: `args[0]` is gorky-tool, `args[1]` the command name.
const Ctx = struct { io: Io, gpa: std.mem.Allocator, out: *Io.Writer, args: []const [:0]const u8 };

/// Commands: name, required arguments after the name, help, handler.
const Command = struct { name: []const u8, min: usize, help: []const u8, run: *const fn (Ctx) anyerror!void };
const commands = [_]Command{
    .{ .name = "list", .min = 1, .help = "<archive.dat>", .run = list },
    .{ .name = "extract", .min = 2, .help = "<archive.dat> <out-dir> [name]", .run = extract },
    .{ .name = "export", .min = 2, .help = "<archive.dat> <out-dir>   sprites, backgrounds → PNG", .run = exportAll },
    .{ .name = "check", .min = 1, .help = "<game-dir>   decode everything and report errors", .run = check },
    .{ .name = "scripts", .min = 1, .help = "<game-dir> [--api]   parse all scripts, check #include/#inherit; --api: engine builtins", .run = scripts },
    .{ .name = "world", .min = 2, .help = "<game-dir> <level> [ticks]   run the level scripts and list objects", .run = world },
    .{ .name = "battle", .min = 2, .help = "<game-dir> <battle level> [turns] [seed] [--sounds]   battle: both sides auto-play, strike log (--sounds: sounds of every tick)", .run = battle },
    .{ .name = "decoytest", .min = 4, .help = "<game-dir> <battle> <x,y> <turns>   decoy on a tile, then auto-battle", .run = decoytest },
    .{ .name = "play", .min = 2, .help = "<game-dir> <level> [commands...]   headless playthrough (src/tool/play.zig)", .run = play },
    .{ .name = "scenes", .min = 2, .help = "<game-dir> <level:scene>...   run scenes and check them (hangs, actors, sounds)", .run = scenes },
    .{ .name = "walk", .min = 4, .help = "<game-dir> <level> <x,y> <x,y>   hero path between points", .run = walk },
    .{ .name = "paths", .min = 2, .help = "<game-dir> <level>   level paths and areas", .run = paths },
    .{ .name = "items", .min = 2, .help = "<game-dir> <level>   level items", .run = items },
    .{ .name = "use", .min = 4, .help = "<game-dir> <level> <item> <target>   use an item", .run = use },
    .{ .name = "voices", .min = 1, .help = "<game-dir>   dialogue voices", .run = voices },
    .{ .name = "listen", .min = 4, .help = "<game-dir> <level> <sec> <out.wav> [x,y]   record level audio (camera at background point x,y)", .run = listen },
    .{ .name = "models", .min = 1, .help = "<game-dir> [--sizes]   parse all 3D models (.msh, .ani, .bfr)", .run = models },
    .{ .name = "anims", .min = 2, .help = "<game-dir> <model> [anim]   animation frames, speed and sounds", .run = anims },
    .{ .name = "model", .min = 5, .help = "<game-dir> <model> <anim> <frame|all> <out.png> [row|column] [angle°] [weapon[:point]] [flash]   render a model", .run = model },
};

fn printUsage(out: *Io.Writer) !void {
    try out.writeAll("Usage:\n");
    for (commands) |c| try out.print("  gorky-tool {s} {s}\n", .{ c.name, c.help });
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    // Mods only with $OPENGORKY_MODS: runs use the game data.
    if (init.environ_map.get("OPENGORKY_MODS")) |mp| og.world.mods.dirs[0] = Io.Dir.cwd().openDir(io, mp, .{ .iterate = true }) catch null;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_fw.interface;
    defer out.flush() catch {};

    const cmd = if (args.len >= 2) args[1] else "";
    for (commands) |c| {
        if (std.mem.eql(u8, c.name, cmd) and args.len >= 2 + c.min) return c.run(.{ .io = io, .gpa = init.gpa, .out = out, .args = args });
    }
    try printUsage(out);
    try out.flush();
    std.process.exit(1);
}

fn xy(t: []const u8) ![2]f32 {
    var it = std.mem.splitScalar(u8, t, ',');
    return .{ try std.fmt.parseFloat(f32, it.next() orelse "0"), try std.fmt.parseFloat(f32, it.next() orelse "0") };
}

fn check(c: Ctx) !void {
    return check_cmd.check(c.io, c.gpa, c.out, c.args[2]);
}

fn world(c: Ctx) !void {
    const ticks = if (c.args.len >= 5) try std.fmt.parseInt(u32, c.args[4], 10) else 0;
    return probe_cmd.runWorld(c.io, c.gpa, c.out, c.args[2], c.args[3], ticks);
}

fn battle(c: Ctx) !void {
    var nums: [2][]const u8 = .{ "30", "1" };
    var n: usize = 0;
    for (c.args[4..]) |a| {
        if (std.mem.eql(u8, a, "--sounds")) battle_cmd.log_sounds = true else if (n < nums.len) {
            nums[n] = a;
            n += 1;
        }
    }
    const turns = try std.fmt.parseInt(i32, nums[0], 10);
    const seed = try std.fmt.parseInt(u64, nums[1], 10);
    return battle_cmd.autoBattle(c.io, c.gpa, c.out, c.args[2], c.args[3], turns, seed);
}

/// decoytest <game> <battle> x,y — a decoy on a tile, then auto-battle turns.
fn decoytest(c: Ctx) !void {
    var dat = try common.openDat(c.io, c.args[2], .{});
    defer dat.close(c.io);
    var it = std.mem.splitScalar(u8, c.args[4], ',');
    const t: [2]i32 = .{ try std.fmt.parseInt(i32, it.next() orelse "0", 10), try std.fmt.parseInt(i32, it.next() orelse "0", 10) };
    var cache = try og.actor.model_cache.Cache.open(c.io, c.gpa, dat);
    defer cache.deinit();
    const w = try og.game.life.create(c.io, c.gpa, dat, c.args[3], &cache, .{});
    defer w.destroy();
    const b = &(w.battle orelse return);
    try devices_mod.placeDecoy(b, w, t);
    return battle_cmd.battleOne(c.out, w, c.args[3], try std.fmt.parseInt(i32, c.args[5], 10), 1);
}

fn walk(c: Ctx) !void {
    return probe_cmd.walkTest(c.io, c.gpa, c.out, c.args[2], c.args[3], try xy(c.args[4]), try xy(c.args[5]));
}

fn scenes(c: Ctx) !void {
    return scenes_cmd.checkScenes(c.io, c.gpa, c.out, c.args[2], c.args[3..]);
}

fn play(c: Ctx) !void {
    return play_script.playScript(c.io, c.gpa, c.out, c.args[2], c.args[3], c.args[4..]);
}

fn paths(c: Ctx) !void {
    return probe_cmd.levelPaths(c.io, c.gpa, c.out, c.args[2], c.args[3]);
}

fn voices(c: Ctx) !void {
    return probe_cmd.voices(c.io, c.gpa, c.out, c.args[2]);
}

fn items(c: Ctx) !void {
    return probe_cmd.levelItems(c.io, c.gpa, c.out, c.args[2], c.args[3]);
}

fn use(c: Ctx) !void {
    return probe_cmd.useItemOn(c.io, c.gpa, c.out, c.args[2], c.args[3], c.args[4], c.args[5]);
}

fn listen(c: Ctx) !void {
    var center: [2]f32 = .{ 320, 240 };
    if (c.args.len >= 7) {
        var it = std.mem.splitScalar(u8, c.args[6], ',');
        center[0] = try std.fmt.parseFloat(f32, it.next() orelse "320");
        center[1] = try std.fmt.parseFloat(f32, it.next() orelse "240");
    }
    return probe_cmd.listen(c.io, c.gpa, c.out, c.args[2], c.args[3], try std.fmt.parseInt(u32, c.args[4], 10), c.args[5], center);
}

fn models(c: Ctx) !void {
    if (c.args.len >= 4 and std.mem.eql(u8, c.args[3], "--sizes")) return models_cmd.modelSizes(c.io, c.gpa, c.out, c.args[2]);
    return models_cmd.checkModels(c.io, c.gpa, c.out, c.args[2]);
}

/// anims <game> <model> [anim]: frames, speed and per-frame sounds.
fn anims(c: Ctx) !void {
    var dat = try common.openDat(c.io, c.args[2], .{});
    defer dat.close(c.io);
    var cache = try og.actor.model_cache.Cache.open(c.io, c.gpa, dat);
    defer cache.deinit();
    const m = cache.get(c.args[3]) orelse return error.NotFound;
    for (m.anims.items) |a| {
        if (c.args.len >= 5 and !std.ascii.eqlIgnoreCase(a.name, c.args[4])) continue;
        try c.out.print("{s}: {d} frames, speed {d}", .{ a.name, a.last - a.first + 1, a.speed });
        for (a.sounds) |snd| try c.out.print(" [{d}: {s}]", .{ snd.frame -| a.first, snd.name });
        try c.out.writeByte('\n');
    }
}

fn model(c: Ctx) !void {
    const args = c.args;
    const conv: og.actor.skin.Convention = if (args.len >= 8 and std.mem.eql(u8, args[7], "column")) .column else .row;
    const yaw = if (args.len >= 9) try std.fmt.parseFloat(f32, args[8]) else 0;
    const weapon: ?[]const u8 = if (args.len >= 10) args[9] else null;
    // 11th argument: chaingun flash at the same point — "x,y,z[,scale]".
    if (args.len >= 11) models_cmd.flash_spec = args[10];
    const fr: u32 = if (std.mem.eql(u8, args[5], "all")) std.math.maxInt(u32) else try std.fmt.parseInt(u32, args[5], 10);
    return models_cmd.renderModel(c.io, c.gpa, c.out, args[2], args[3], args[4], fr, args[6], conv, yaw, weapon);
}

fn scripts(c: Ctx) !void {
    const api = c.args.len >= 4 and std.mem.eql(u8, c.args[3], "--api");
    return scripts_cmd.checkScripts(c.io, c.gpa, c.out, c.args[2], api);
}

fn list(c: Ctx) !void {
    var arc = try archive.Archive.open(c.io, c.gpa, Io.Dir.cwd(), c.args[2]);
    defer arc.close(c.io, c.gpa);
    for (arc.entries) |e| try c.out.print("{d:>10} {d:>10}  {s}\n", .{ e.offset, e.size, e.name });
    try c.out.print("{d} entries\n", .{arc.entries.len});
}

fn extract(c: Ctx) !void {
    const cwd = Io.Dir.cwd();
    var arc = try archive.Archive.open(c.io, c.gpa, cwd, c.args[2]);
    defer arc.close(c.io, c.gpa);
    var out_dir = try cwd.createDirPathOpen(c.io, c.args[3], .{});
    defer out_dir.close(c.io);
    const only: ?[]const u8 = if (c.args.len >= 5) c.args[4] else null;
    var n: usize = 0;
    for (arc.entries) |*e| {
        if (only) |name| if (!std.ascii.eqlIgnoreCase(name, e.name)) continue;
        var path_buf: [archive.name_size]u8 = undefined;
        const rel = resource.safeRelPath(&path_buf, e.name) orelse continue;
        const data = try arc.readAlloc(c.io, c.gpa, e);
        defer c.gpa.free(data);
        try export_cmd.writeFileMkdir(c.io, out_dir, rel, data);
        n += 1;
    }
    try c.out.print("extracted {d} files\n", .{n});
}

fn exportAll(c: Ctx) !void {
    const cwd = Io.Dir.cwd();
    var arc = try archive.Archive.open(c.io, c.gpa, cwd, c.args[2]);
    defer arc.close(c.io, c.gpa);
    var out_dir = try cwd.createDirPathOpen(c.io, c.args[3], .{});
    defer out_dir.close(c.io);
    var n: usize = 0;
    for (arc.entries) |*e| {
        const kind = resource.kindOf(e.name);
        if (kind == .other) continue;
        var path_buf: [archive.name_size]u8 = undefined;
        const rel = resource.safeRelPath(&path_buf, e.name) orelse continue;
        const stem = rel[0 .. rel.len - std.fs.path.extension(rel).len];
        const data = try arc.readAlloc(c.io, c.gpa, e);
        defer c.gpa.free(data);
        n += export_cmd.exportImages(c.io, c.gpa, out_dir, stem, kind, data) catch |err| {
            try c.out.print("{s}: {t}\n", .{ e.name, err });
            continue;
        };
    }
    try c.out.print("exported {d} images\n", .{n});
}

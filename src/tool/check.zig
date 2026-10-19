//! gorky-tool `check`: every game archive and level file parses without errors.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const common = @import("common.zig");
const archive = og.formats.archive;
const sprite = og.formats.sprite;
const resource = og.formats.resource;

/// Walks `<game-dir>/dat`, decodes every known resource and reports errors.
pub fn check(io: Io, gpa: Allocator, out: *Io.Writer, game_dir: []const u8) !void {
    var root = try common.openDat(io, game_dir, .{ .iterate = true });
    defer root.close(io);
    const paths = try og.formats.archive.listArchives(io, gpa, root);
    defer og.formats.archive.freeList(gpa, paths);

    var counts = std.EnumArray(resource.Kind, usize).initFill(0);
    var level_files: usize = 0;
    var errors: usize = 0;
    var archives: usize = 0;
    for (paths) |path| {
        var arc = archive.Archive.open(io, gpa, root, path) catch |err| {
            try out.print("{s}: {t}\n", .{ path, err });
            errors += 1;
            continue;
        };
        defer arc.close(io, gpa);
        archives += 1;
        for (arc.entries) |*e| {
            const kind = resource.kindOf(e.name);
            counts.getPtr(kind).* += 1;
            const level_ext = levelFileExt(e.name);
            if (kind == .other and level_ext == null) continue;
            const data = try arc.readAlloc(io, gpa, e);
            defer gpa.free(data);
            if (level_ext != null) level_files += 1;
            const result = if (level_ext) |ext| checkLevelFile(gpa, ext, data) else checkOne(gpa, kind, data);
            result catch |err| {
                try out.print("{s}: {s}: {t}\n", .{ path, e.name, err });
                errors += 1;
            };
        }
    }
    try out.print("archives {d}, sprites {d}, bkg {d}, jpeg {d}, zbf {d}, 3df {d}, audio {d}, level files {d}, other {d}; errors {d}\n", .{
        archives,                         counts.get(.sprite),  counts.get(.background), counts.get(.jpeg),
        counts.get(.zbuffer),             counts.get(.texture), counts.get(.audio),      level_files,
        counts.get(.other) - level_files, errors,
    });
    if (errors > 0) return error.CheckFailed;
}

const LevelExt = enum { ap, ar, lts, wm, wm2, cm, scr, pts, dlg, fnt };

fn levelFileExt(name: []const u8) ?LevelExt {
    const ext = std.fs.path.extension(name);
    if (ext.len < 2) return null;
    var buf: [8]u8 = undefined;
    if (ext.len - 1 > buf.len) return null;
    return std.meta.stringToEnum(LevelExt, std.ascii.lowerString(&buf, ext[1..]));
}

fn checkLevelFile(gpa: Allocator, ext: LevelExt, data: []const u8) !void {
    const lf = og.formats.level_files;
    switch (ext) {
        .ap => lf.freePaths(gpa, try lf.parsePaths(gpa, data)),
        .ar => lf.freeAreas(gpa, try lf.parseAreas(gpa, data)),
        .lts => {
            var l = try lf.parseLights(gpa, data);
            l.deinit(gpa);
        },
        .wm, .wm2 => {
            var m = try lf.parseWalkMap(gpa, data);
            m.deinit(gpa);
        },
        .cm => {
            var m = try lf.parseCombatMap(gpa, data);
            m.deinit(gpa);
        },
        .fnt => {
            if (data.len == 4096 or data.len == 6144) {
                _ = try og.formats.font.parseTex(data);
            } else _ = try og.formats.font.parse(data);
        },
        .scr, .pts, .dlg => {
            var arena: std.heap.ArenaAllocator = .init(gpa);
            defer arena.deinit();
            switch (ext) {
                .scr => _ = try og.formats.scriptlet.parse(arena.allocator(), data),
                .pts => _ = try og.formats.scriptlet.parsePoints(arena.allocator(), data),
                else => _ = try og.formats.dialog.parse(arena.allocator(), data),
            }
        },
    }
}

fn checkOne(gpa: Allocator, kind: resource.Kind, data: []const u8) !void {
    switch (kind) {
        .sprite => {
            var spr = try sprite.parse(gpa, data);
            defer spr.deinit(gpa);
            for (spr.frames) |f| {
                var img = try sprite.decodeFrame(gpa, f);
                img.deinit(gpa);
            }
        },
        .background => {
            var img = try og.formats.background.decode(gpa, data);
            img.deinit(gpa);
        },
        .jpeg => {
            var img = try og.formats.jpeg.decode(gpa, data);
            img.deinit(gpa);
        },
        .zbuffer => {
            var z = try og.formats.zbuffer.decode(gpa, data);
            z.deinit(gpa);
        },
        .audio => {
            var s = try og.audio.decode.decode(gpa, data);
            s.deinit(gpa);
        },
        .texture => {
            var img = try og.formats.tex3df.decode(gpa, data);
            img.deinit(gpa);
        },
        .other => {},
    }
}

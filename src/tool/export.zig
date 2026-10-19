//! gorky-tool `extract`, `export`: dump archive files and resources to PNG.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const archive = og.formats.archive;
const sprite = og.formats.sprite;
const Image = og.formats.image.Image;
const resource = og.formats.resource;

pub fn exportImages(io: Io, gpa: Allocator, dir: Io.Dir, stem: []const u8, kind: resource.Kind, data: []const u8) !usize {
    var name_buf: [archive.name_size + 16]u8 = undefined;
    switch (kind) {
        .sprite => {
            var spr = try sprite.parse(gpa, data);
            defer spr.deinit(gpa);
            for (spr.frames, 0..) |f, i| {
                var img = try sprite.decodeFrame(gpa, f);
                defer img.deinit(gpa);
                const name = if (spr.frames.len == 1)
                    try std.fmt.bufPrint(&name_buf, "{s}.png", .{stem})
                else
                    try std.fmt.bufPrint(&name_buf, "{s}_{d:0>3}.png", .{ stem, i });
                try writePng(io, gpa, dir, name, img);
            }
            return spr.frames.len;
        },
        .background, .jpeg, .texture => {
            var img = switch (kind) {
                .background => try og.formats.background.decode(gpa, data),
                .jpeg => try og.formats.jpeg.decode(gpa, data),
                else => try og.formats.tex3df.decode(gpa, data),
            };
            defer img.deinit(gpa);
            try writePng(io, gpa, dir, try std.fmt.bufPrint(&name_buf, "{s}.png", .{stem}), img);
            return 1;
        },
        .zbuffer => {
            var z = try og.formats.zbuffer.decode(gpa, data);
            defer z.deinit(gpa);
            var img = try z.toImage(gpa);
            defer img.deinit(gpa);
            try writePng(io, gpa, dir, try std.fmt.bufPrint(&name_buf, "{s}.zbf.png", .{stem}), img);
            return 1;
        },
        .audio, .other => return 0,
    }
}

pub fn writePng(io: Io, gpa: Allocator, dir: Io.Dir, rel: []const u8, img: Image) !void {
    var buf: Io.Writer.Allocating = .init(gpa);
    defer buf.deinit();
    try og.formats.png.write(gpa, &buf.writer, img);
    try writeFileMkdir(io, dir, rel, buf.written());
}

pub fn writeFileMkdir(io: Io, dir: Io.Dir, rel: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(rel)) |sub| try dir.createDirPath(io, sub);
    try dir.writeFile(io, .{ .sub_path = rel, .data = data });
}

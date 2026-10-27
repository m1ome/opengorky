//! Imports transcoded off the UI thread, one run at a time (`transcode.zig`, the
//! linked FFmpeg): `start` runs it on a thread, `poll` (each frame) shows its progress
//! and hands the finished run to its `done` on the main thread, which edits the Store.

const std = @import("std");
const App = @import("app.zig").App;
const tx = @import("text.zig");
const transcode = @import("transcode.zig");

const smp = std.heap.smp_allocator;

pub const Kind = enum { video, music };

pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    kind: Kind,
    src: [:0]const u8,
    /// What is made (`clip.asf`, `track.mp3`) and the file written (video; music comes
    /// back in `result`).
    name: []const u8,
    out: [:0]const u8,
    done: *const fn (*App, *Job) void,
    /// The MP3 (in `arena`) for music, "" for a video.
    result: anyerror![]const u8 = error.NotRun,
    progress: transcode.Progress = .{},
    shown: u32 = std.math.maxInt(u32),
    finished: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
};

/// `src` → `kind`'s game format started; "Converting…" said (or that one still runs).
pub fn start(app: *App, kind: Kind, src: []const u8, name: []const u8, out: []const u8, done: *const fn (*App, *Job) void) !void {
    if (app.convert) |j| return app.setStatus(tx.st_converting, .{ j.name, j.shown / 10 });
    const job = try smp.create(Job);
    job.* = .{ .arena = .init(smp), .kind = kind, .src = "", .name = "", .out = "", .done = done };
    errdefer {
        job.arena.deinit();
        smp.destroy(job);
    }
    const a = job.arena.allocator();
    job.src = try a.dupeSentinel(u8, src, 0);
    job.name = try a.dupe(u8, name);
    job.out = try a.dupeSentinel(u8, out, 0);
    job.thread = try std.Thread.spawn(.{}, run, .{job});
    app.convert = job;
    poll(app);
}

fn run(job: *Job) void {
    job.result = switch (job.kind) {
        .video => if (transcode.video(job.src, job.out, &job.progress)) "" else |err| err,
        .music => transcode.music(job.arena.allocator(), job.src, &job.progress),
    };
    job.finished.store(true, .release);
}

/// Each frame: the progress in the status line, a finished run applied.
pub fn poll(app: *App) void {
    const job = app.convert orelse return;
    if (job.finished.load(.acquire)) return wait(app);
    const pm = job.progress.permille.load(.monotonic);
    if (pm == job.shown) return;
    job.shown = pm;
    app.setStatus(tx.st_converting, .{ job.name, pm / 10 });
}

/// The status bar's Cancel: the run stops at its next packet (`done` gets error.Canceled).
pub fn cancel(app: *App) void {
    if (app.convert) |j| j.progress.cancel.store(true, .monotonic);
}

/// The run waited for and applied (scripted edits, the editor closing).
pub fn wait(app: *App) void {
    const job = app.convert orelse return;
    job.thread.join();
    app.convert = null;
    job.done(app, job);
    job.arena.deinit();
    smp.destroy(job);
}

/// A failed run in the status line, by what went wrong.
pub fn failed(app: *App, job: *const Job, err: anyerror) void {
    const src = std.fs.path.basename(job.src);
    switch (err) {
        error.UnreadableFile => app.setStatus(tx.st_conv_unreadable, .{src}),
        error.UnsupportedCodec => app.setStatus(tx.st_conv_codec, .{src}),
        error.NoVideoStream => app.setStatus(tx.st_conv_no_video, .{src}),
        error.NoAudioStream => app.setStatus(tx.st_conv_no_audio, .{src}),
        error.Canceled => app.setStatus(tx.st_conv_canceled, .{job.name}),
        else => app.setStatus(tx.st_video_failed, .{err}),
    }
}

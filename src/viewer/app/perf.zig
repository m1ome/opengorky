//! Frame time by parts (console `perf`, `--perf`): averages over recent frames
//! in ms. Does not affect drawing or logic.
//! Process-wide profiler state: globals on purpose.

const std = @import("std");
const og = @import("opengorky");
const c = @import("sdl");

const Part = enum { update, layer_begin, shadow_cast, models, shadow_mix, upload, rest, present };

const names = [_][]const u8{ "update", "begin", "shadow", "models", "mix", "upload", "rest", "present" };

/// Sums over the window (SDL counter ticks) and frame count.
var sums: [names.len]u64 = @splat(0);
var frames: u32 = 0;
var frame_sum: u64 = 0;
var last_frame: u64 = 0;
/// Averaging window number (grows with each new average).
pub var window: u32 = 0;
/// Previous window averages, ms.
var avg: [sums.len]f32 = @splat(0);
var avg_frame: f32 = 0;
/// Whole-run totals (for `--perf`).
var total: [sums.len]u64 = @splat(0);
var total_frames: u32 = 0;
var total_frame_sum: u64 = 0;

pub fn now() u64 {
    return c.SDL_GetPerformanceCounter();
}

pub fn add(part: Part, start: u64) void {
    sums[@backingInt(part)] += now() - start;
}

fn ms(t: u64) f32 {
    return og.num.toF32(t) * 1000 / og.num.toF32(c.SDL_GetPerformanceFrequency());
}

/// End of frame: new averages every 30 frames.
pub fn endFrame() void {
    const t = now();
    if (last_frame != 0) {
        frame_sum += t - last_frame;
        frames += 1;
    }
    last_frame = t;
    if (frames < 30) return;
    // `rest` is measured whole (all drawing), without the actor layer parts.
    const inner = sums[1] + sums[2] + sums[3] + sums[4] + sums[5];
    sums[6] -|= inner;
    for (&avg, sums, &total) |*a, s, *tt| {
        a.* = ms(s) / og.num.toF32(frames);
        tt.* += s;
    }
    avg_frame = ms(frame_sum) / og.num.toF32(frames);
    window += 1;
    total_frames += frames;
    total_frame_sum += frame_sum;
    sums = @splat(0);
    frames = 0;
    frame_sum = 0;
}

/// Frame work without waiting for present (present waits for vsync), ms.
pub fn work() f32 {
    var t: f32 = 0;
    for (avg[0 .. avg.len - 1]) |a| t += a;
    return t;
}

/// Status line (fps, frame, update …) from the previous window averages.
pub fn line(buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const fps: f32 = if (avg_frame > 0) 1000 / avg_frame else 0;
    w.print("fps {d:.0} frame {d:.1}", .{ fps, avg_frame }) catch {};
    for (names, avg) |n, a| w.print(" {s} {d:.1}", .{ n, a }) catch {};
    return w.buffered();
}

/// Whole-run averages (printed on exit with `--perf`).
pub fn summary(buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (total_frames == 0) return "perf: too few frames";
    const n: f32 = @floatFromInt(total_frames);
    const fr = ms(total_frame_sum) / n;
    w.print("perf: frames {d}, fps {d:.1}, frame {d:.2} ms", .{ total_frames, if (fr > 0) 1000 / fr else 0, fr }) catch {};
    for (names, total) |nm, t| w.print(", {s} {d:.2}", .{ nm, ms(t) / n }) catch {};
    return w.buffered();
}

//! Videos `avi\*.asf` (ASF: MS-MPEG4 v1/v3, WMA v1 or MP3). Decoded by built-in
//! FFmpeg (libavformat/libavcodec, `-Dffmpeg`, on by default when available) or,
//! without it, by an external `ffmpeg` program (RGBA frames at 15 fps through a
//! pipe, audio as WAV). The exe player is 0x45d620 (name, x, y, line doubling):
//! frame at (x, y), doubled lines double the height.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const gfx = @import("gfx.zig");
const build_options = @import("build_options");
const av = if (build_options.ffmpeg) @import("ffmpeg") else struct {};

const fps = 15;

/// Built-in FFmpeg: demuxer, video decoder, RGBA conversion.
const Lib = if (build_options.ffmpeg) struct {
    fmt: *av.AVFormatContext,
    dec: *av.AVCodecContext,
    sws: *av.SwsContext,
    pkt: *av.AVPacket,
    frm: *av.AVFrame,
    stream: c_int,
    time_base: f64,
    /// Time (s) of the frame in `frame`.
    pts: f64 = -1,
    eof: bool = false,

    fn open(path: [:0]const u8) !@This() {
        av.av_log_set_level(av.AV_LOG_QUIET);
        var fmt: ?*av.AVFormatContext = null;
        if (av.avformat_open_input(&fmt, path.ptr, null, null) < 0) return error.NoVideo;
        errdefer av.avformat_close_input(&fmt);
        if (av.avformat_find_stream_info(fmt, null) < 0) return error.NoVideo;
        const idx = av.av_find_best_stream(fmt, av.AVMEDIA_TYPE_VIDEO, -1, -1, null, 0);
        if (idx < 0) return error.NoVideo;
        const st = fmt.?.streams[@intCast(idx)];
        const codec = av.avcodec_find_decoder(st.*.codecpar.*.codec_id) orelse return error.NoVideo;
        var dec: ?*av.AVCodecContext = av.avcodec_alloc_context3(codec) orelse return error.OutOfMemory;
        errdefer av.avcodec_free_context(&dec);
        if (av.avcodec_parameters_to_context(dec, st.*.codecpar) < 0) return error.NoVideo;
        if (av.avcodec_open2(dec, codec, null) < 0) return error.NoVideo;
        const d = dec.?;
        const sws = av.sws_getContext(d.width, d.height, d.pix_fmt, d.width, d.height, av.AV_PIX_FMT_RGBA, av.SWS_BILINEAR, null, null, null) orelse return error.NoVideo;
        errdefer av.sws_freeContext(sws);
        var pkt: ?*av.AVPacket = av.av_packet_alloc() orelse return error.OutOfMemory;
        errdefer av.av_packet_free(&pkt);
        const tb = st.*.time_base;
        return .{
            .fmt = fmt.?,
            .dec = d,
            .sws = sws,
            .pkt = pkt.?,
            .frm = av.av_frame_alloc() orelse return error.OutOfMemory,
            .stream = idx,
            .time_base = @as(f64, @floatFromInt(tb.num)) / @as(f64, @floatFromInt(@max(1, tb.den))),
        };
    }

    /// Next frame into `rgba` (w×h×4); false at the end.
    fn next(self: *@This(), rgba: []u8, w: u32) bool {
        while (true) {
            if (av.avcodec_receive_frame(self.dec, self.frm) == 0) {
                var dst = [4][*c]u8{ rgba.ptr, null, null, null };
                var stride = [4]c_int{ @intCast(w * 4), 0, 0, 0 };
                _ = av.sws_scale(self.sws, @ptrCast(&self.frm.*.data), &self.frm.*.linesize, 0, self.dec.*.height, &dst, &stride);
                const ts = if (self.frm.*.best_effort_timestamp != av.AV_NOPTS_VALUE) self.frm.*.best_effort_timestamp else self.frm.*.pts;
                self.pts = if (ts != av.AV_NOPTS_VALUE) @as(f64, @floatFromInt(ts)) * self.time_base else self.pts + 1.0 / @as(f64, fps);
                return true;
            }
            if (self.eof) return false;
            if (av.av_read_frame(self.fmt, self.pkt) < 0) {
                self.eof = true;
                _ = av.avcodec_send_packet(self.dec, null);
                continue;
            }
            defer av.av_packet_unref(self.pkt);
            if (self.pkt.*.stream_index == self.stream) _ = av.avcodec_send_packet(self.dec, self.pkt);
        }
    }

    fn close(self: *@This()) void {
        var frm: ?*av.AVFrame = self.frm;
        av.av_frame_free(&frm);
        var pkt: ?*av.AVPacket = self.pkt;
        av.av_packet_free(&pkt);
        av.sws_freeContext(self.sws);
        var dec: ?*av.AVCodecContext = self.dec;
        av.avcodec_free_context(&dec);
        var f: ?*av.AVFormatContext = self.fmt;
        av.avformat_close_input(&f);
    }

    /// The file's whole audio: 16-bit, 44.1 kHz, stereo.
    fn audio(gpa: Allocator, path: [:0]const u8) ?og.audio.decode.Sound {
        var fmt: ?*av.AVFormatContext = null;
        if (av.avformat_open_input(&fmt, path.ptr, null, null) < 0) return null;
        defer av.avformat_close_input(&fmt);
        if (av.avformat_find_stream_info(fmt, null) < 0) return null;
        const idx = av.av_find_best_stream(fmt, av.AVMEDIA_TYPE_AUDIO, -1, -1, null, 0);
        if (idx < 0) return null;
        const st = fmt.?.streams[@intCast(idx)];
        const codec = av.avcodec_find_decoder(st.*.codecpar.*.codec_id) orelse return null;
        var dec: ?*av.AVCodecContext = av.avcodec_alloc_context3(codec) orelse return null;
        defer av.avcodec_free_context(&dec);
        if (av.avcodec_parameters_to_context(dec, st.*.codecpar) < 0) return null;
        if (av.avcodec_open2(dec, codec, null) < 0) return null;
        var out_layout: av.AVChannelLayout = undefined;
        av.av_channel_layout_default(&out_layout, 2);
        var swr: ?*av.SwrContext = null;
        if (av.swr_alloc_set_opts2(&swr, &out_layout, av.AV_SAMPLE_FMT_S16, 44100, &dec.?.ch_layout, dec.?.sample_fmt, dec.?.sample_rate, 0, null) < 0) return null;
        defer av.swr_free(&swr);
        if (av.swr_init(swr) < 0) return null;
        var pkt: ?*av.AVPacket = av.av_packet_alloc() orelse return null;
        defer av.av_packet_free(&pkt);
        var frm: ?*av.AVFrame = av.av_frame_alloc() orelse return null;
        defer av.av_frame_free(&frm);
        var out: std.ArrayList(i16) = .empty;
        errdefer out.deinit(gpa);
        var eof = false;
        while (true) {
            while (av.avcodec_receive_frame(dec, frm) == 0) {
                const n = av.swr_get_out_samples(swr, frm.?.nb_samples);
                if (n <= 0) continue;
                const start = out.items.len;
                out.resize(gpa, start + @as(usize, @intCast(n)) * 2) catch return null;
                var dst = [1][*c]u8{@ptrCast(out.items[start..].ptr)};
                const got = av.swr_convert(swr, &dst, n, @ptrCast(frm.?.extended_data), frm.?.nb_samples);
                out.shrinkRetainingCapacity(start + @as(usize, @intCast(@max(0, got))) * 2);
            }
            if (eof) break;
            if (av.av_read_frame(fmt, pkt) < 0) {
                eof = true;
                _ = av.avcodec_send_packet(dec, null);
                continue;
            }
            if (pkt.?.stream_index == idx) _ = av.avcodec_send_packet(dec, pkt);
            av.av_packet_unref(pkt);
        }
        return .{ .channels = 2, .rate = 44100, .samples = out.toOwnedSlice(gpa) catch return null };
    }
} else void;

/// External ffmpeg: RGBA frames at 15 fps from a pipe.
const Proc = struct {
    child: std.process.Child,
    reader_buf: []u8,
    reader: Io.File.Reader,
};

const Backend = union(enum) { lib: Lib, proc: Proc };

pub const Video = struct {
    gpa: Allocator,
    io: Io,
    backend: Backend,
    frame: []u8,
    w: u32,
    h: u32,
    x: f32,
    y: f32,
    double: bool,
    tex: *c.SDL_Texture,
    start_ms: u64,
    shown: u64 = 0,
    done: bool = false,
    sound: ?og.audio.decode.Sound = null,
    voice: ?og.audio.mixer.VoiceId = null,
    /// introkon: the intro.spr frame 0 caption on top (0x436cdf).
    caption: bool = false,

    /// Finds `avi\<name>.asf` case-insensitively ("gradma.avi" → "gradma.asf").
    pub fn find(buf: []u8, io: Io, game_dir: []const u8, name: []const u8) ?[]const u8 {
        const base = if (std.mem.lastIndexOfScalar(u8, name, '.')) |d| name[0..d] else name;
        var path_buf: [512]u8 = undefined;
        const avi = std.fmt.bufPrint(&path_buf, "{s}/avi", .{game_dir}) catch return null;
        var dir = Io.Dir.cwd().openDir(io, avi, .{ .iterate = true }) catch return null;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            const stem = if (std.mem.lastIndexOfScalar(u8, e.name, '.')) |d| e.name[0..d] else e.name;
            if (!std.ascii.eqlIgnoreCase(stem, base)) continue;
            return std.fmt.bufPrint(buf, "{s}/{s}", .{ avi, e.name }) catch null;
        }
        return null;
    }

    fn probeSize(gpa: Allocator, io: Io, path: []const u8) ?[2]u32 {
        const res = std.process.run(gpa, io, .{ .argv = &.{ "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", path } }) catch return null;
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        var it = std.mem.tokenizeAny(u8, res.stdout, ",\r\n ");
        const w = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const h = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        return .{ w, h };
    }

    /// Starts a video; null without the file or a decoder.
    pub fn open(gpa: Allocator, io: Io, r: *c.SDL_Renderer, path: []const u8, x: i32, y: i32, double: bool) ?*Video {
        return openErr(gpa, io, r, path, x, y, double) catch null;
    }

    fn openErr(gpa: Allocator, io: Io, r: *c.SDL_Renderer, path: []const u8, x: i32, y: i32, double: bool) !*Video {
        var zbuf: [600]u8 = undefined;
        const pz = try std.fmt.bufPrintSentinel(&zbuf, "{s}", .{path}, 0);
        var backend: Backend = undefined;
        var dims: [2]u32 = undefined;
        var sound: ?og.audio.decode.Sound = null;
        if (build_options.ffmpeg) {
            const lib = try Lib.open(pz);
            dims = .{ @intCast(lib.dec.*.width), @intCast(lib.dec.*.height) };
            backend = .{ .lib = lib };
            sound = Lib.audio(gpa, pz);
        } else {
            dims = probeSize(gpa, io, path) orelse return error.NoVideo;
            const reader_buf = try gpa.alloc(u8, 1 << 16);
            errdefer gpa.free(reader_buf);
            const ffmpeg = "ffmpeg";
            const child = try std.process.spawn(io, .{
                .argv = &.{ ffmpeg, "-v", "error", "-i", path, "-an", "-f", "rawvideo", "-pix_fmt", "rgba", "-r", "15", "-" },
                .stdin = .ignore,
                .stdout = .pipe,
                .stderr = .ignore,
            });
            backend = .{ .proc = .{ .child = child, .reader_buf = reader_buf, .reader = undefined } };
            if (std.process.run(gpa, io, .{ .argv = &.{ ffmpeg, "-v", "error", "-i", path, "-vn", "-f", "wav", "-acodec", "pcm_s16le", "-ar", "44100", "-ac", "2", "-" } })) |res| {
                defer gpa.free(res.stdout);
                defer gpa.free(res.stderr);
                sound = og.audio.decode.decode(gpa, res.stdout) catch null;
            } else |_| {}
        }
        errdefer closeBackend(&backend, gpa, io);
        errdefer if (sound) |*s| s.deinit(gpa);
        const v = try gpa.create(Video);
        errdefer gpa.destroy(v);
        const frame = try gpa.alloc(u8, @as(usize, dims[0]) * dims[1] * 4);
        errdefer gpa.free(frame);
        const tex = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STREAMING, @intCast(dims[0]), @intCast(dims[1])) orelse return error.NoVideo;
        v.* = .{
            .gpa = gpa,
            .io = io,
            .backend = backend,
            .frame = frame,
            .w = dims[0],
            .h = dims[1],
            // x = −1000 centres it, width at most the screen (0x437158).
            .x = if (x == -1000) @floatFromInt((640 - @min(dims[0], 640)) / 2) else @floatFromInt(x),
            .y = @floatFromInt(y),
            .double = double,
            .tex = tex,
            .start_ms = c.SDL_GetTicks(),
            .sound = sound,
            .caption = std.mem.indexOf(u8, path, "introkon") != null,
        };
        switch (v.backend) {
            .proc => |*p| p.reader = p.child.stdout.?.reader(io, p.reader_buf),
            .lib => {},
        }
        return v;
    }

    pub fn startSound(self: *Video, mixer: *og.audio.mixer.Mixer) void {
        if (self.sound) |*s| self.voice = mixer.playAs(self.gpa, .music, s, 1, 0, false) catch null;
        self.start_ms = c.SDL_GetTicks();
    }

    /// Seconds since the video start.
    pub fn seconds(self: *Video) f32 {
        return og.num.toF32(c.SDL_GetTicks() - self.start_ms) / 1000;
    }

    /// Current frame time (s).
    fn framePts(self: *Video) f64 {
        return switch (self.backend) {
            .lib => |l| if (build_options.ffmpeg) l.pts else 0,
            .proc => @as(f64, @floatFromInt(self.shown)) / fps,
        };
    }

    /// Next frame; false at the end.
    fn nextFrame(self: *Video) bool {
        switch (self.backend) {
            .lib => |*l| if (build_options.ffmpeg) {
                if (!l.next(self.frame, self.w)) return false;
            } else unreachable,
            .proc => |*p| p.reader.interface.readSliceAll(self.frame) catch return false,
        }
        self.shown += 1;
        return true;
    }

    /// Frames up to `t` seconds (playback and --shot).
    pub fn seek(self: *Video, t: f64) void {
        var any = false;
        while (self.shown == 0 or self.framePts() + 1.0 / @as(f64, fps) <= t) {
            if (!self.nextFrame()) {
                self.done = true;
                break;
            }
            any = true;
        }
        if (any) _ = c.SDL_UpdateTexture(self.tex, null, self.frame.ptr, @intCast(self.w * 4));
    }

    pub fn update(self: *Video) void {
        if (self.done) return;
        self.seek(@as(f64, @floatFromInt(c.SDL_GetTicks() - self.start_ms)) / 1000);
    }

    pub fn draw(self: *Video, r: *c.SDL_Renderer) !void {
        try gfx.check(c.SDL_SetRenderDrawColor(r, 0, 0, 0, 255));
        try gfx.check(c.SDL_RenderClear(r));
        if (self.shown == 0) return;
        const hh: f32 = @floatFromInt(self.h * @as(u32, if (self.double) 2 else 1));
        const dst: c.SDL_FRect = .{ .x = self.x, .y = self.y, .w = @floatFromInt(self.w), .h = hh };
        try gfx.check(c.SDL_RenderTexture(r, self.tex, null, &dst));
    }

    pub fn close(self: *Video, mixer: ?*og.audio.mixer.Mixer) void {
        if (mixer) |m| if (self.voice) |id| m.stop(id);
        closeBackend(&self.backend, self.gpa, self.io);
        c.SDL_DestroyTexture(self.tex);
        if (self.sound) |*s| s.deinit(self.gpa);
        self.gpa.free(self.frame);
        self.gpa.destroy(self);
    }

    fn closeBackend(b: *Backend, gpa: Allocator, io: Io) void {
        switch (b.*) {
            .lib => |*l| if (build_options.ffmpeg) l.close(),
            .proc => |*p| {
                // Close the pipe first, or ffmpeg after SIGTERM blocks writing to a full pipe.
                if (p.child.stdout) |f| f.close(io);
                p.child.stdout = null;
                p.child.kill(io);
                gpa.free(p.reader_buf);
            },
        }
    }
};

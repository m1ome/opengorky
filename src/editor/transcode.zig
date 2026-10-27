//! Imports through the linked FFmpeg (libav*): any file it decodes → the game's
//! formats, in-process (demux → decode → swscale/swresample → encode → mux). Runs on
//! `convert.zig`'s thread; `Progress` is shared with the main thread.

const std = @import("std");
const build_options = @import("build_options");
const av = if (build_options.ffmpeg) @import("ffmpeg") else struct {};

pub const Progress = struct {
    /// Done so far, ‰ of the input's duration.
    permille: std.atomic.Value(u32) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
};

const fps = 15;
const rate = 44100;

/// `src` → an ASF at `dst` as the game's own videos: within its 640×480 screen (even
/// sizes), 15 fps, MS-MPEG4 v3 at q 3, WMA v1 44.1 kHz stereo 128 kb/s (if `src` has sound).
pub fn video(src: [:0]const u8, dst: [:0]const u8, p: *Progress) !void {
    if (!build_options.ffmpeg) return error.BuiltWithoutFfmpeg else {
        var t: T = .{ .p = p };
        defer t.deinit();
        try t.run(src, dst);
    }
}

/// `src`'s sound → MP3 bytes (44.1 kHz stereo 128 kb/s, LAME), owned by `gpa`.
pub fn music(gpa: std.mem.Allocator, src: [:0]const u8, p: *Progress) ![]u8 {
    if (!build_options.ffmpeg) return error.BuiltWithoutFfmpeg else {
        var t: T = .{ .p = p };
        defer t.deinit();
        try t.run(src, null);
        var buf: [*c]u8 = null;
        const n = av.avio_close_dyn_buf(t.out.?.pb, &buf);
        t.out.?.pb = null;
        defer av.av_free(buf);
        return gpa.dupe(u8, buf[0..@intCast(n)]);
    }
}

/// The ffmpeg `scale` the CLI import used: within 640×480 keeping the aspect
/// (`force_original_aspect_ratio=decrease`), then even sizes.
fn fit(iw: i64, ih: i64) [2]i64 {
    const w0 = @min(640, iw);
    const h0 = @min(480, ih);
    const w = @min(w0, @divTrunc(h0 * iw + @divTrunc(ih, 2), ih));
    const h = @min(h0, @divTrunc(w0 * ih + @divTrunc(iw, 2), iw));
    return .{ @max(2, w & ~@as(i64, 1)), @max(2, h & ~@as(i64, 1)) };
}

test fit {
    try std.testing.expectEqual([2]i64{ 270, 480 }, fit(720, 1280));
    try std.testing.expectEqual([2]i64{ 320, 240 }, fit(320, 240));
    try std.testing.expectEqual([2]i64{ 640, 360 }, fit(1920, 1080));
    try std.testing.expectEqual([2]i64{ 64, 48 }, fit(65, 49));
}

/// One run's FFmpeg state (`deinit` frees what was made).
const T = if (build_options.ffmpeg) struct {
    p: *Progress,
    in: ?*av.AVFormatContext = null,
    out: ?*av.AVFormatContext = null,
    vdec: ?*av.AVCodecContext = null,
    adec: ?*av.AVCodecContext = null,
    venc: ?*av.AVCodecContext = null,
    aenc: ?*av.AVCodecContext = null,
    vst: ?*av.AVStream = null,
    ast: ?*av.AVStream = null,
    vi: c_int = -1,
    ai: c_int = -1,
    sws: ?*av.SwsContext = null,
    swr: ?*av.SwrContext = null,
    fifo: ?*av.AVAudioFifo = null,
    pkt: ?*av.AVPacket = null,
    opkt: ?*av.AVPacket = null,
    frm: ?*av.AVFrame = null,
    /// The encoders' input: the scaled frame held until the next one's time is known,
    /// and one audio frame of the encoder's size.
    vfrm: ?*av.AVFrame = null,
    afrm: ?*av.AVFrame = null,
    held: bool = false,
    next_v: i64 = 0,
    next_a: i64 = 0,
    /// The input's start and length (s).
    start: f64 = 0,
    dur: f64 = 0,
    mem: bool = false,

    fn deinit(t: *@This()) void {
        av.av_frame_free(&t.frm);
        av.av_frame_free(&t.vfrm);
        av.av_frame_free(&t.afrm);
        av.av_packet_free(&t.pkt);
        av.av_packet_free(&t.opkt);
        if (t.fifo) |f| av.av_audio_fifo_free(f);
        av.swr_free(&t.swr);
        av.sws_freeContext(t.sws);
        av.avcodec_free_context(&t.vdec);
        av.avcodec_free_context(&t.adec);
        av.avcodec_free_context(&t.venc);
        av.avcodec_free_context(&t.aenc);
        av.avformat_close_input(&t.in);
        if (t.out) |o| {
            // A memory buffer left open (a failed music run) is freed through its close.
            if (o.pb != null) if (t.mem) {
                var b: [*c]u8 = null;
                _ = av.avio_close_dyn_buf(o.pb, &b);
                av.av_free(b);
            } else {
                _ = av.avio_closep(&o.pb);
            };
            av.avformat_free_context(o);
        }
    }

    /// `dst` null: MP3 into a memory buffer (`out.pb`), else the ASF video file.
    fn run(t: *@This(), src: [:0]const u8, dst: ?[:0]const u8) !void {
        av.av_log_set_level(av.AV_LOG_QUIET);
        if (av.avformat_open_input(&t.in, src.ptr, null, null) < 0) return error.UnreadableFile;
        const in = t.in.?;
        if (av.avformat_find_stream_info(in, null) < 0) return error.UnreadableFile;
        if (in.start_time != av.AV_NOPTS_VALUE) t.start = @as(f64, @floatFromInt(in.start_time)) / av.AV_TIME_BASE;
        if (in.duration > 0) t.dur = @as(f64, @floatFromInt(in.duration)) / av.AV_TIME_BASE;
        if (dst != null) {
            t.vi = av.av_find_best_stream(in, av.AVMEDIA_TYPE_VIDEO, -1, -1, null, 0);
            if (t.vi < 0) return error.NoVideoStream;
            t.vdec = try decoder(in.streams[@intCast(t.vi)]);
        }
        t.ai = av.av_find_best_stream(in, av.AVMEDIA_TYPE_AUDIO, -1, t.vi, null, 0);
        if (t.ai >= 0) t.adec = try decoder(in.streams[@intCast(t.ai)]) else if (dst == null) return error.NoAudioStream;

        if (av.avformat_alloc_output_context2(&t.out, null, if (dst != null) "asf" else "mp3", if (dst) |d| d.ptr else null) < 0) return error.OutOfMemory;
        const out = t.out.?;
        const global = out.oformat.*.flags & av.AVFMT_GLOBALHEADER != 0;
        if (t.vdec) |d| {
            const codec = av.avcodec_find_encoder(av.AV_CODEC_ID_MSMPEG4V3) orelse return error.NoEncoder;
            const e: *av.AVCodecContext = av.avcodec_alloc_context3(codec) orelse return error.OutOfMemory;
            t.venc = e;
            const size = fit(d.width, d.height);
            e.width = @intCast(size[0]);
            e.height = @intCast(size[1]);
            e.pix_fmt = av.AV_PIX_FMT_YUV420P;
            e.time_base = .{ .num = 1, .den = fps };
            e.framerate = .{ .num = fps, .den = 1 };
            // As ffmpeg's scale filter: the picture's aspect kept.
            const sar = av.av_guess_sample_aspect_ratio(in, in.streams[@intCast(t.vi)], null);
            if (sar.num > 0) {
                var n: c_int = 0;
                var m: c_int = 0;
                _ = av.av_reduce(&n, &m, @as(i64, e.height) * d.width * sar.num, @as(i64, e.width) * d.height * sar.den, 1 << 30);
                e.sample_aspect_ratio = .{ .num = n, .den = m };
            }
            // -q:v 3
            e.flags |= av.AV_CODEC_FLAG_QSCALE;
            e.global_quality = 3 * av.FF_QP2LAMBDA;
            if (global) e.flags |= av.AV_CODEC_FLAG_GLOBAL_HEADER;
            if (av.avcodec_open2(e, codec, null) < 0) return error.EncoderFailed;
            t.vst = try stream(out, e);
            t.vfrm = try frame();
            t.vfrm.?.format = e.pix_fmt;
            t.vfrm.?.width = e.width;
            t.vfrm.?.height = e.height;
            if (av.av_frame_get_buffer(t.vfrm, 0) < 0) return error.OutOfMemory;
        }
        if (t.adec != null) {
            const codec = av.avcodec_find_encoder(if (dst != null) av.AV_CODEC_ID_WMAV1 else av.AV_CODEC_ID_MP3) orelse return error.NoEncoder;
            const e: *av.AVCodecContext = av.avcodec_alloc_context3(codec) orelse return error.OutOfMemory;
            t.aenc = e;
            e.sample_rate = rate;
            av.av_channel_layout_default(&e.ch_layout, 2);
            e.sample_fmt = av.AV_SAMPLE_FMT_FLTP;
            e.bit_rate = 128000;
            e.time_base = .{ .num = 1, .den = rate };
            if (global) e.flags |= av.AV_CODEC_FLAG_GLOBAL_HEADER;
            if (av.avcodec_open2(e, codec, null) < 0) return error.EncoderFailed;
            t.ast = try stream(out, e);
            if (e.frame_size <= 0) return error.EncoderFailed;
            t.fifo = av.av_audio_fifo_alloc(e.sample_fmt, 2, e.frame_size) orelse return error.OutOfMemory;
            t.afrm = try frame();
            t.afrm.?.format = e.sample_fmt;
            t.afrm.?.sample_rate = rate;
            t.afrm.?.nb_samples = e.frame_size;
            if (av.av_channel_layout_copy(&t.afrm.?.ch_layout, &e.ch_layout) < 0 or av.av_frame_get_buffer(t.afrm, 0) < 0) return error.OutOfMemory;
        }
        if (dst) |d| {
            if (av.avio_open(&out.pb, d.ptr, av.AVIO_FLAG_WRITE) < 0) return error.CannotWrite;
        } else {
            if (av.avio_open_dyn_buf(&out.pb) < 0) return error.OutOfMemory;
            t.mem = true;
        }
        if (av.avformat_write_header(out, null) < 0) return error.CannotWrite;

        t.pkt = av.av_packet_alloc() orelse return error.OutOfMemory;
        t.opkt = av.av_packet_alloc() orelse return error.OutOfMemory;
        t.frm = try frame();
        const pkt = t.pkt.?;
        while (av.av_read_frame(in, pkt) >= 0) {
            defer av.av_packet_unref(pkt);
            if (t.p.cancel.load(.monotonic)) return error.Canceled;
            const ours = pkt.stream_index == t.vi or pkt.stream_index == t.ai;
            if (!ours) continue;
            const ts = if (pkt.pts != av.AV_NOPTS_VALUE) pkt.pts else pkt.dts;
            if (ts != av.AV_NOPTS_VALUE and t.dur > 0) {
                const s = seconds(ts, in.streams[@intCast(pkt.stream_index)].*.time_base) - t.start;
                const pm: u32 = @intFromFloat(std.math.clamp(s / t.dur * 1000, 0, 999));
                if (pm > t.p.permille.load(.monotonic)) t.p.permille.store(pm, .monotonic);
            }
            // A damaged packet is skipped, as the ffmpeg program did.
            if (pkt.stream_index == t.vi) {
                if (av.avcodec_send_packet(t.vdec, pkt) == 0) try t.decodedVideo();
            } else if (av.avcodec_send_packet(t.adec, pkt) == 0) try t.decodedAudio();
        }
        if (t.vdec != null) {
            _ = av.avcodec_send_packet(t.vdec, null);
            try t.decodedVideo();
            if (t.held) try t.encodeVideo(t.vfrm);
            try t.encodeVideo(null);
        }
        if (t.adec != null) {
            _ = av.avcodec_send_packet(t.adec, null);
            try t.decodedAudio();
            if (t.swr != null) try t.resample(null, 0);
            const left = av.av_audio_fifo_size(t.fifo);
            if (left > 0) {
                // The last frame filled with silence (WMA takes whole frames only).
                const f = t.afrm.?;
                try t.fill(left);
                _ = av.av_samples_set_silence(f.extended_data, left, f.nb_samples - left, 2, f.format);
                try t.encodeAudio(f);
            }
            try t.encodeAudio(null);
        }
        if (av.av_write_trailer(out) < 0) return error.CannotWrite;
        t.p.permille.store(1000, .monotonic);
    }

    fn decoder(st: *av.AVStream) !*av.AVCodecContext {
        const codec = av.avcodec_find_decoder(st.codecpar.*.codec_id) orelse return error.UnsupportedCodec;
        const d: *av.AVCodecContext = av.avcodec_alloc_context3(codec) orelse return error.OutOfMemory;
        errdefer {
            var x: ?*av.AVCodecContext = d;
            av.avcodec_free_context(&x);
        }
        if (av.avcodec_parameters_to_context(d, st.codecpar) < 0) return error.UnsupportedCodec;
        d.pkt_timebase = st.time_base;
        d.thread_count = 0;
        if (av.avcodec_open2(d, codec, null) < 0) return error.UnsupportedCodec;
        return d;
    }

    fn stream(out: *av.AVFormatContext, e: *av.AVCodecContext) !*av.AVStream {
        const st: *av.AVStream = av.avformat_new_stream(out, null) orelse return error.OutOfMemory;
        if (av.avcodec_parameters_from_context(st.codecpar, e) < 0) return error.OutOfMemory;
        st.time_base = e.time_base;
        st.sample_aspect_ratio = e.sample_aspect_ratio;
        return st;
    }

    fn frame() !*av.AVFrame {
        return av.av_frame_alloc() orelse error.OutOfMemory;
    }

    fn seconds(ts: i64, tb: av.AVRational) f64 {
        return @as(f64, @floatFromInt(ts)) * @as(f64, @floatFromInt(tb.num)) / @as(f64, @floatFromInt(@max(1, tb.den)));
    }

    /// Decoded pictures to 15 fps as the ffmpeg program's `-r 15`: each output frame
    /// shows the last picture due by its time (repeated or dropped).
    fn decodedVideo(t: *@This()) !void {
        const f = t.frm.?;
        const tb = t.in.?.streams[@intCast(t.vi)].*.time_base;
        while (av.avcodec_receive_frame(t.vdec, f) == 0) {
            defer av.av_frame_unref(f);
            const ts = if (f.best_effort_timestamp != av.AV_NOPTS_VALUE) f.best_effort_timestamp else f.pts;
            const slot: i64 = if (ts != av.AV_NOPTS_VALUE) @intFromFloat(@round((seconds(ts, tb) - t.start) * fps)) else t.next_v;
            while (t.held and t.next_v < slot) try t.encodeVideo(t.vfrm);
            const v = t.vfrm.?;
            if (av.av_frame_make_writable(v) < 0) return error.OutOfMemory;
            t.sws = av.sws_getCachedContext(t.sws, f.width, f.height, f.format, v.width, v.height, v.format, av.SWS_BICUBIC, null, null, null) orelse return error.UnsupportedCodec;
            _ = av.sws_scale(t.sws, @ptrCast(&f.data), &f.linesize, 0, f.height, @ptrCast(&v.data), &v.linesize);
            t.held = true;
        }
    }

    fn encodeVideo(t: *@This(), f: ?*av.AVFrame) !void {
        const e = t.venc.?;
        if (f) |v| {
            v.pts = t.next_v;
            v.quality = e.global_quality;
            v.pict_type = av.AV_PICTURE_TYPE_NONE;
            t.next_v += 1;
        }
        if (av.avcodec_send_frame(e, f) < 0) return error.EncoderFailed;
        try t.write(e, t.vst.?);
    }

    fn decodedAudio(t: *@This()) !void {
        const f = t.frm.?;
        while (av.avcodec_receive_frame(t.adec, f) == 0) {
            defer av.av_frame_unref(f);
            if (t.swr == null) {
                var layout = f.ch_layout;
                if (layout.order == av.AV_CHANNEL_ORDER_UNSPEC) av.av_channel_layout_default(&layout, layout.nb_channels);
                const e = t.aenc.?;
                if (av.swr_alloc_set_opts2(&t.swr, &e.ch_layout, e.sample_fmt, rate, &layout, f.format, f.sample_rate, 0, null) < 0 or av.swr_init(t.swr) < 0) return error.UnsupportedCodec;
            }
            try t.resample(f.extended_data, f.nb_samples);
        }
    }

    /// `n` input samples (null: the resampler's rest) into the FIFO, whole encoder
    /// frames out of it.
    fn resample(t: *@This(), data: [*c][*c]u8, n: c_int) !void {
        const max = av.swr_get_out_samples(t.swr, n);
        if (max > 0) {
            var buf: [2][*c]u8 = .{ null, null };
            if (av.av_samples_alloc(&buf, null, 2, max, t.aenc.?.sample_fmt, 0) < 0) return error.OutOfMemory;
            defer av.av_freep(@ptrCast(&buf[0]));
            const got = av.swr_convert(t.swr, &buf, max, @ptrCast(data), n);
            if (got < 0) return error.UnsupportedCodec;
            if (av.av_audio_fifo_write(t.fifo, @ptrCast(&buf), got) < got) return error.OutOfMemory;
        }
        const f = t.afrm.?;
        while (av.av_audio_fifo_size(t.fifo) >= f.nb_samples) {
            try t.fill(f.nb_samples);
            try t.encodeAudio(f);
        }
    }

    fn fill(t: *@This(), n: c_int) !void {
        const f = t.afrm.?;
        if (av.av_frame_make_writable(f) < 0) return error.OutOfMemory;
        if (av.av_audio_fifo_read(t.fifo, @ptrCast(&f.data), n) < n) return error.OutOfMemory;
    }

    fn encodeAudio(t: *@This(), f: ?*av.AVFrame) !void {
        const e = t.aenc.?;
        if (f) |a| {
            a.pts = t.next_a;
            t.next_a += a.nb_samples;
        }
        if (av.avcodec_send_frame(e, f) < 0) return error.EncoderFailed;
        try t.write(e, t.ast.?);
    }

    /// The encoder's packets into the file.
    fn write(t: *@This(), e: *av.AVCodecContext, st: *av.AVStream) !void {
        const p = t.opkt.?;
        while (av.avcodec_receive_packet(e, p) == 0) {
            av.av_packet_rescale_ts(p, e.time_base, st.time_base);
            p.stream_index = st.index;
            if (av.av_interleaved_write_frame(t.out, p) < 0) return error.CannotWrite;
        }
    }
} else void;

/// Test input for FFmpeg: `n` frames of a moving gradient as YUV4MPEG2 at 30 fps.
fn y4m(a: std.mem.Allocator, w: usize, h: usize, n: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "YUV4MPEG2 W{d} H{d} F30:1 Ip A1:1 C420jpeg\n", .{ w, h });
    for (0..n) |k| {
        try out.appendSlice(a, "FRAME\n");
        for (0..h) |y| for (0..w) |x| try out.append(a, @truncate(x + y + k * 8));
        try out.appendNTimes(a, 128, 2 * ((w + 1) / 2) * ((h + 1) / 2));
    }
    return out.items;
}

/// Test input: a second of a 440 Hz tone, 22.05 kHz mono 16-bit WAV.
fn wav(a: std.mem.Allocator) ![]u8 {
    const n = 22050;
    var out: std.ArrayList(u8) = .empty;
    const w = struct {
        fn u(o: *std.ArrayList(u8), al: std.mem.Allocator, comptime I: type, v: I) !void {
            try o.appendSlice(al, &std.mem.toBytes(std.mem.nativeToLittle(I, v)));
        }
    }.u;
    try out.appendSlice(a, "RIFF");
    try w(&out, a, u32, 36 + n * 2);
    try out.appendSlice(a, "WAVEfmt ");
    try w(&out, a, u32, 16);
    try w(&out, a, u16, 1);
    try w(&out, a, u16, 1);
    try w(&out, a, u32, 22050);
    try w(&out, a, u32, 44100);
    try w(&out, a, u16, 2);
    try w(&out, a, u16, 16);
    try out.appendSlice(a, "data");
    try w(&out, a, u32, n * 2);
    for (0..n) |k| try w(&out, a, i16, @intFromFloat(12000 * @sin(@as(f64, @floatFromInt(k)) * 2 * std.math.pi * 440 / 22050)));
    return out.items;
}

test "video and music transcode to the game's formats" {
    if (!build_options.ffmpeg) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "in.y4m", .data = try y4m(a, 65, 49, 30) });
    try tmp.dir.writeFile(io, .{ .sub_path = "in.wav", .data = try wav(a) });
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const dir = pb[0..try tmp.dir.realPath(io, &pb)];
    const src_v = try std.fmt.allocPrintSentinel(a, "{s}/in.y4m", .{dir}, 0);
    const src_a = try std.fmt.allocPrintSentinel(a, "{s}/in.wav", .{dir}, 0);
    const dst = try std.fmt.allocPrintSentinel(a, "{s}/out.asf", .{dir}, 0);

    var p: Progress = .{};
    try video(src_v, dst, &p);
    try std.testing.expectEqual(1000, p.permille.load(.monotonic));
    // ASF header object GUID, then the streams as the game's videos.
    const asf = try tmp.dir.readFileAlloc(io, "out.asf", a, .unlimited);
    try std.testing.expectEqualSlices(u8, &.{ 0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9, 0x00, 0xAA, 0x00, 0x62, 0xCE, 0x6C }, asf[0..16]);
    var in: ?*av.AVFormatContext = null;
    try std.testing.expect(av.avformat_open_input(&in, dst.ptr, null, null) >= 0);
    defer av.avformat_close_input(&in);
    try std.testing.expect(av.avformat_find_stream_info(in, null) >= 0);
    try std.testing.expectEqual(1, in.?.nb_streams);
    const par = in.?.streams[0].*.codecpar.*;
    try std.testing.expectEqual(@as(c_uint, av.AV_CODEC_ID_MSMPEG4V3), par.codec_id);
    try std.testing.expectEqual(64, par.width);
    try std.testing.expectEqual(48, par.height);
    // 30 pictures at 30 fps → slots 0…15 of 1/15 s (the ffmpeg program made 17).
    var pkt: ?*av.AVPacket = av.av_packet_alloc();
    defer av.av_packet_free(&pkt);
    var frames: usize = 0;
    while (av.av_read_frame(in, pkt) >= 0) : (av.av_packet_unref(pkt)) frames += 1;
    try std.testing.expectEqual(16, frames);

    try std.testing.expectError(error.NoVideoStream, video(src_a, dst, &p));
    var stop: Progress = .{};
    stop.cancel.store(true, .monotonic);
    try std.testing.expectError(error.Canceled, video(src_v, dst, &stop));
    try std.testing.expectError(error.NoAudioStream, music(a, src_v, &p));

    const mp3 = try music(a, src_a, &p);
    // ID3v2 tag skipped, then an MPEG-1 Layer III frame header: 128 kb/s, 44.1 kHz, stereo.
    var o: usize = 0;
    if (std.mem.startsWith(u8, mp3, "ID3")) o = 10 + (@as(usize, mp3[6]) << 21 | @as(usize, mp3[7]) << 14 | @as(usize, mp3[8]) << 7 | mp3[9]);
    const hd = mp3[o..][0..4];
    try std.testing.expectEqual(0xFF, hd[0]);
    try std.testing.expectEqual(0xFA, hd[1] & 0xFE); // MPEG-1, Layer III
    try std.testing.expectEqual(9, hd[2] >> 4); // 128 kb/s
    try std.testing.expectEqual(0, (hd[2] >> 2) & 3); // 44100 Hz
    try std.testing.expect(hd[3] >> 6 != 3); // not mono
    try std.testing.expect(mp3.len > 15000); // ~1 s at 128 kb/s
}

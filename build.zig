const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addModule("opengorky", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addCDeps(b, lib);

    // gorky-tool runs the whole game in checks (scripts/fullgame.sh, linux/check.sh):
    // a debug build takes ~1 min, mostly in the debug allocator. So without
    // -Dtool-optimize it (and its engine copy) builds ReleaseSafe — bounds and overflow
    // checks stay. The game run does not depend on the mode: logic has no @setFloatMode
    // (no FMA or reordering), Debug/ReleaseSafe/ReleaseSmall runs give the same
    // log. `-Dtool-optimize=debug` — a debug build of the tool.
    const tool_optimize = b.option(std.builtin.OptimizeMode, "tool-optimize", "gorky-tool optimization (default safe in a debug build)") orelse
        if (optimize == .debug) .safe else optimize;
    const tool_lib = if (tool_optimize == optimize) lib else engineModule(b, target, tool_optimize);
    const tool = b.addExecutable(.{
        .name = "gorky-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tool/main.zig"),
            .target = target,
            .optimize = tool_optimize,
            .imports = &.{.{ .name = "opengorky", .module = tool_lib }},
        }),
    });
    b.installArtifact(tool);

    const run_tool = b.addRunArtifact(tool);
    run_tool.step.dependOn(b.getInstallStep());
    run_tool.addPassthruArgs();
    b.step("tool", "Run gorky-tool").dependOn(&run_tool.step);

    // SDL3 is linked as a system library (brew install sdl3 / package libsdl3-dev).
    // `-Dsdl-prefix=DIR` — our own build (scripts/build-sdl3.sh: universal arm64 +
    // x86_64 for macOS distribution) instead of pkg-config.
    const sdl_prefix = b.option([]const u8, "sdl-prefix", "Own SDL3 build dir (include/, lib/) instead of pkg-config");
    const sdl = b.addTranslateC(.{
        .root_source_file = b.path("src/viewer/sdl.h"),
        .target = target,
        .optimize = optimize,
    });
    var pkg_config_exit: u8 = 0;
    if (sdl_prefix) |pre| {
        sdl.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{pre}) });
    } else if (b.runAllowFail(&.{ "pkg-config", "--cflags-only-I", "sdl3" }, &pkg_config_exit, .ignore)) |out| {
        var it = std.mem.tokenizeAny(u8, out, " \n");
        while (it.next()) |flag| {
            if (std.mem.startsWith(u8, flag, "-I")) sdl.addSystemIncludePath(.{ .cwd_relative = flag[2..] });
        }
    } else |_| {}
    const sdl_mod = sdl.createModule();
    if (sdl_prefix) |pre| {
        const ext = switch (target.result.os.tag) {
            .macos => "libSDL3.0.dylib",
            .windows => "libSDL3.dll.a", // import library; SDL3.dll goes next to the exe
            else => "libSDL3.so.0",
        };
        sdl_mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/{s}", .{ pre, ext }) });
    } else sdl_mod.linkSystemLibrary("SDL3", .{});

    // FFmpeg for videos (libavformat etc. via pkg-config); without it videos play
    // through an external ffmpeg program if present.
    // `-Dffmpeg-prefix=DIR` — our own FFmpeg build (scripts/build-ffmpeg.sh: only ASF,
    // MS-MPEG4, WMA, MP3) instead of the system one from pkg-config.
    const ff_libs = [_][]const u8{ "libavformat", "libavcodec", "libswscale", "libswresample", "libavutil" };
    const ff_prefix = b.option([]const u8, "ffmpeg-prefix", "Own FFmpeg build dir (include/, lib/) instead of pkg-config");
    var ff_found = true;
    var ff_cflags: ?[]const u8 = null;
    if (ff_prefix) |pre| {
        ff_cflags = b.fmt("-I{s}/include", .{pre});
    } else if (b.runAllowFail(&(.{ "pkg-config", "--cflags-only-I" } ++ ff_libs), &pkg_config_exit, .ignore)) |out| {
        ff_cflags = out;
    } else |_| ff_found = false;
    const use_ffmpeg = b.option(bool, "ffmpeg", "Decode videos with linked FFmpeg (default: if found)") orelse ff_found;
    const options = b.addOptions();
    options.addOption(bool, "ffmpeg", use_ffmpeg);
    const ffmpeg = b.addTranslateC(.{
        .root_source_file = b.path("src/viewer/ffmpeg.h"),
        .target = target,
        .optimize = optimize,
    });
    // Own-build headers via -I: they must come before the system ones (otherwise on
    // Linux with libav*-dev packages headers of another FFmpeg version get picked up
    // and struct layouts diverge from the libraries).
    if (ff_prefix) |pre| {
        ffmpeg.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{pre}) });
    } else if (ff_cflags) |out| {
        var it = std.mem.tokenizeAny(u8, out, " \n");
        while (it.next()) |flag| {
            if (std.mem.startsWith(u8, flag, "-I")) ffmpeg.addSystemIncludePath(.{ .cwd_relative = flag[2..] });
        }
    }
    const ffmpeg_mod = ffmpeg.createModule();
    // Own build by full library path: otherwise the linker finds the system FFmpeg in
    // the SDL3 directory (Homebrew) first.
    const dylib_ext = switch (target.result.os.tag) {
        .macos => "dylib",
        .windows => "dll.a",
        else => "so",
    };
    if (use_ffmpeg) for (ff_libs) |l| {
        if (ff_prefix) |pre| {
            ffmpeg_mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/{s}.{s}", .{ pre, l, dylib_ext }) });
        } else ffmpeg_mod.linkSystemLibrary(l[3..], .{});
    };

    // The viewer renders models in software: a debug build is ~10× slower, so
    // without -Dviewer-optimize it (and its engine copy) builds ReleaseFast. Not
    // ReleaseSmall: there LLVM (Zig 0.17, arm64) outlines repeated code
    // (MachineOutliner) and clobbers registers — in combat.devices.destroyBarrel the
    // return address saved in x2 was taken by an outlined chunk as argument `v`, and
    // shooting a barrel crashed the game (EXC_BAD_ACCESS). The outliner cannot be
    // disabled in Zig 0.17. `-Dviewer-optimize=safe` keeps bounds and overflow checks
    // (~14% slower), `=debug` builds a debug viewer.
    // Release logic is the same: Zig does not reorder floating-point operations without
    // @setFloatMode. Tests use -Doptimize (default Debug), gorky-tool -Dtool-optimize.
    // `-Dstrip` drops debug info (smaller binary; for distribution in
    // scripts/dist-*.sh; during development it gives crash stacks).
    const strip = b.option(bool, "strip", "Strip debug info from the viewer") orelse false;
    const viewer_optimize = b.option(std.builtin.OptimizeMode, "viewer-optimize", "Viewer optimization (default fast in a debug build)") orelse
        if (optimize == .debug) .fast else optimize;
    const viewer_lib = if (viewer_optimize == optimize) lib else if (viewer_optimize == tool_optimize) tool_lib else engineModule(b, target, viewer_optimize);
    const viewer = b.addExecutable(.{
        .name = "opengorky-viewer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/viewer/main.zig"),
            .target = target,
            .optimize = viewer_optimize,
            .strip = strip,
            .imports = if (use_ffmpeg) &.{
                .{ .name = "opengorky", .module = viewer_lib },
                .{ .name = "sdl", .module = sdl_mod },
                .{ .name = "ffmpeg", .module = ffmpeg_mod },
                .{ .name = "build_options", .module = options.createModule() },
            } else &.{
                .{ .name = "opengorky", .module = viewer_lib },
                .{ .name = "sdl", .module = sdl_mod },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    // Own FFmpeg build: shared libraries with @rpath; when run from zig-out they are
    // looked up in its directory (the scripts/dist-macos.sh and dist-linux.sh packages point next to the binary).
    // `-Dbundle-rpath='$ORIGIN/lib'` — library lookup path in the package (Linux) instead
    // of the FFmpeg build directory.
    if (b.option([]const u8, "bundle-rpath", "Viewer rpath in the package instead of the FFmpeg build dir")) |rp| {
        viewer.root_module.addRPath(.{ .cwd_relative = rp });
    } else {
        if (use_ffmpeg) if (ff_prefix) |pre| viewer.root_module.addRPath(.{ .cwd_relative = b.fmt("{s}/lib", .{pre}) });
        if (sdl_prefix) |pre| viewer.root_module.addRPath(.{ .cwd_relative = b.fmt("{s}/lib", .{pre}) });
    }
    // Windows: a GUI program, no console window next to the game (logs go nowhere).
    if (target.result.os.tag == .windows) viewer.subsystem = .windows;
    // Window icon: the project's own picture, embedded in the binary (@embedFile("icon_png")).
    viewer.root_module.addAnonymousImport("icon_png", .{ .root_source_file = b.path("assets/icon-256.png") });
    b.installArtifact(viewer);

    const run_viewer = b.addRunArtifact(viewer);
    run_viewer.step.dependOn(b.getInstallStep());
    run_viewer.addPassthruArgs();
    b.step("viewer", "Run the resource viewer").dependOn(&run_viewer.step);

    const lib_tests = b.addRunArtifact(b.addTest(.{ .root_module = lib }));
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&lib_tests.step);
    // Viewer files without SDL: settings, icon shadow, background pause.
    for ([_][]const u8{ "src/viewer/app/config.zig", "src/viewer/media/shadow.zig", "src/viewer/app/pause.zig" }) |p| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(p),
            .target = target,
            .optimize = optimize,
        }) })).step);
    }
    // Unformatted code fails the test (`zig fmt src build.zig` fixes it).
    test_step.dependOn(&b.addFmt(.{ .paths = &.{ b.path("src"), b.path("build.zig") }, .check = true }).step);
}

/// Third-party engine decoders (stb_image, dr_libs).
fn addCDeps(b: *std.Build, m: *std.Build.Module) void {
    m.addIncludePath(b.path("third_party/stb"));
    m.addCSourceFile(.{ .file = b.path("third_party/stb/stb_image.c"), .flags = &.{"-O2"} });
    m.addIncludePath(b.path("third_party/dr_libs"));
    m.addCSourceFile(.{ .file = b.path("third_party/dr_libs/dr_libs.c"), .flags = &.{"-O2"} });
}

/// Engine copy with its own optimization (for gorky-tool and the viewer).
fn engineModule(b: *std.Build, target: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = opt,
        .link_libc = true,
    });
    addCDeps(b, m);
    return m;
}

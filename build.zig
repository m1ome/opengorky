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

    // FFmpeg for videos and the editor's imports (libavformat etc. via pkg-config,
    // shared); without it videos play through an external ffmpeg program if present and
    // the editor cannot import.
    // `-Dffmpeg-prefix=DIR` — our own FFmpeg build (scripts/build-ffmpeg.sh: all
    // decoders, the game's encoders, LAME), linked statically, instead of pkg-config.
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
    const options_mod = options.createModule();
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
    // Own build by full archive path: otherwise the linker finds the system FFmpeg in
    // the SDL3 directory (Homebrew) first.
    if (use_ffmpeg) for (ff_libs ++ .{"libmp3lame"}) |l| {
        if (ff_prefix) |pre| {
            ffmpeg_mod.addObjectFile(.{ .cwd_relative = b.fmt("{s}/lib/{s}.a", .{ pre, l }) });
        } else if (!std.mem.eql(u8, l, "libmp3lame")) ffmpeg_mod.linkSystemLibrary(l[3..], .{});
    };
    // Static libraries' system needs: Windows' bcrypt (libavutil's random seed); the
    // macOS frameworks libavutil.pc lists go unused without VideoToolbox.
    if (use_ffmpeg and ff_prefix != null and target.result.os.tag == .windows) ffmpeg_mod.linkSystemLibrary("bcrypt", .{});

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
                .{ .name = "build_options", .module = options_mod },
            } else &.{
                .{ .name = "opengorky", .module = viewer_lib },
                .{ .name = "sdl", .module = sdl_mod },
                .{ .name = "build_options", .module = options_mod },
            },
        }),
    });
    // Own SDL3 build: a shared library with @rpath; when run from zig-out it is looked
    // up in its directory (the scripts/dist-macos.sh and dist-linux.sh packages point next to the binary).
    // `-Dbundle-rpath='$ORIGIN/lib'` — library lookup path in the package (Linux) instead
    // of the SDL build directory.
    const bundle_rpath = b.option([]const u8, "bundle-rpath", "Viewer and editor rpath in the package instead of the SDL build dir");
    if (bundle_rpath) |rp| {
        viewer.root_module.addRPath(.{ .cwd_relative = rp });
    } else if (sdl_prefix) |pre| viewer.root_module.addRPath(.{ .cwd_relative = b.fmt("{s}/lib", .{pre}) });
    // Windows: a GUI program, no console window next to the game (logs go nowhere).
    if (target.result.os.tag == .windows) viewer.subsystem = .windows;
    // Window icon: the project's own picture, embedded in the binary (@embedFile("icon_png")).
    viewer.root_module.addAnonymousImport("icon_png", .{ .root_source_file = b.path("assets/icon-256.png") });
    // `scaling = adaptive`: the riveted plate beside the 640-wide panel.
    viewer.root_module.addAnonymousImport("panel_plate_png", .{ .root_source_file = b.path("assets/panel-plate.png") });
    b.installArtifact(viewer);

    const run_viewer = b.addRunArtifact(viewer);
    run_viewer.step.dependOn(b.getInstallStep());
    run_viewer.addPassthruArgs();
    b.step("viewer", "Run the resource viewer").dependOn(&run_viewer.step);

    // Level editor: the engine and SDL as in the viewer, UI layout by Clay, text by
    // stb_truetype with the embedded PT Sans.
    const ui = b.addTranslateC(.{
        .root_source_file = b.path("src/editor/ui.h"),
        .target = target,
        .optimize = optimize,
    });
    ui.addIncludePath(b.path("third_party/clay"));
    ui.addIncludePath(b.path("third_party/stb"));
    const editor = b.addExecutable(.{
        .name = "opengorky-editor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/editor/main.zig"),
            .target = target,
            .optimize = viewer_optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "opengorky", .module = viewer_lib },
                .{ .name = "sdl", .module = sdl_mod },
                .{ .name = "ui", .module = ui.createModule() },
            },
        }),
    });
    // The viewer's video player (the Videos page plays them in the centre) and level
    // composition (the level view's "as in the game" picture): one module, they share
    // the viewer's media files.
    const viewer_part = b.createModule(.{ .root_source_file = b.path("src/viewer/level_render.zig"), .target = target, .optimize = viewer_optimize });
    viewer_part.addImport("opengorky", viewer_lib);
    viewer_part.addImport("sdl", sdl_mod);
    viewer_part.addImport("build_options", options_mod);
    if (use_ffmpeg) viewer_part.addImport("ffmpeg", ffmpeg_mod);
    editor.root_module.addImport("viewer", viewer_part);
    // Imports transcode in-process (src/editor/transcode.zig).
    editor.root_module.addImport("build_options", options_mod);
    if (use_ffmpeg) editor.root_module.addImport("ffmpeg", ffmpeg_mod);
    editor.root_module.addIncludePath(b.path("third_party/clay"));
    editor.root_module.addIncludePath(b.path("third_party/stb"));
    editor.root_module.addCSourceFile(.{ .file = b.path("third_party/clay/clay.c"), .flags = &.{"-O2"} });
    editor.root_module.addCSourceFile(.{ .file = b.path("third_party/stb/stb_truetype.c"), .flags = &.{"-O2"} });
    editor.root_module.addAnonymousImport("font_regular", .{ .root_source_file = b.path("assets/fonts/PTSans-Regular.ttf") });
    editor.root_module.addAnonymousImport("font_bold", .{ .root_source_file = b.path("assets/fonts/PTSans-Bold.ttf") });
    editor.root_module.addAnonymousImport("font_italic", .{ .root_source_file = b.path("assets/fonts/PTSans-Italic.ttf") });
    // Map icons (Lucide, ISC; scripts/editor-icons.swift renders them).
    for ([_][]const u8{ "facing", "turn_ccw", "turn_cw" }) |n| {
        editor.root_module.addAnonymousImport(b.fmt("icon_{s}", .{n}), .{ .root_source_file = b.path(b.fmt("assets/icons/{s}.png", .{n})) });
    }
    // UI icons (the same script, white, tinted when drawn): names as src/editor/icons.zig's Icon.
    for ([_][]const u8{ "save", "check", "play", "settings", "history", "search", "folder", "chevron_right", "chevron_down", "map_pin", "swords", "user", "package", "clapperboard", "volume_2", "plus", "file_text", "mouse_pointer_2", "hand", "paintbrush", "pipette", "lightbulb", "square_dashed", "log_out", "crosshair", "camera", "pencil", "code", "message_square", "maximize", "x", "undo_2", "redo_2", "eye", "eye_off", "lock", "lock_open", "layers", "trash_2", "copy", "image", "grid_3x3", "box", "pause", "skip_back", "skip_forward" }) |n| {
        editor.root_module.addAnonymousImport(b.fmt("ui_{s}", .{n}), .{ .root_source_file = b.path(b.fmt("assets/icons/ui_{s}.png", .{n})) });
    }
    // Window icon (assets/icon-editor.png at 256 px), as the viewer's.
    editor.root_module.addAnonymousImport("icon_png", .{ .root_source_file = b.path("assets/icon-editor-256.png") });
    // Settings folder and atomic writes, shared with the viewer (std only).
    editor.root_module.addAnonymousImport("config", .{ .root_source_file = b.path("src/viewer/app/config.zig") });
    if (bundle_rpath) |rp| {
        editor.root_module.addRPath(.{ .cwd_relative = rp });
    } else if (sdl_prefix) |pre| editor.root_module.addRPath(.{ .cwd_relative = b.fmt("{s}/lib", .{pre}) });
    if (target.result.os.tag == .windows) editor.subsystem = .windows;
    b.installArtifact(editor);

    const run_editor = b.addRunArtifact(editor);
    run_editor.step.dependOn(b.getInstallStep());
    run_editor.addPassthruArgs();
    b.step("editor", "Run the level editor").dependOn(&run_editor.step);

    const lib_tests = b.addRunArtifact(b.addTest(.{ .root_module = lib }));
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&lib_tests.step);
    // Viewer and editor files without SDL: settings, icon shadow, background pause, level script edits.
    for ([_][]const u8{ "src/viewer/app/config.zig", "src/viewer/media/shadow.zig", "src/viewer/app/pause.zig", "src/editor/placement.zig", "src/editor/vars.zig", "src/editor/settings.zig", "src/editor/box.zig", "src/editor/search.zig", "src/editor/scenes.zig", "src/editor/code.zig", "src/editor/api.zig", "src/editor/trigger.zig", "src/editor/newlevel.zig", "src/editor/cli.zig", "src/editor/texts.zig", "src/editor/modpack.zig", "src/editor/adjusttext.zig", "src/editor/adjustdoc.zig", "src/editor/savelog.zig", "src/editor/zone.zig", "src/editor/catalog.zig" }) |p| {
        const m = b.createModule(.{ .root_source_file = b.path(p), .target = target, .optimize = optimize });
        // The weapon patterns (zone.zig) and the class files (catalog.zig) are the engine's.
        m.addImport("opengorky", lib);
        // api.zig's test checks its entries against the builtins the port registers.
        m.addAnonymousImport("builtins_src", .{ .root_source_file = b.path("src/builtins.zig") });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }
    // The editor's import transcoding through the linked FFmpeg.
    const transcode = b.createModule(.{ .root_source_file = b.path("src/editor/transcode.zig"), .target = target, .optimize = optimize, .link_libc = true });
    transcode.addImport("build_options", options_mod);
    if (use_ffmpeg) transcode.addImport("ffmpeg", ffmpeg_mod);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = transcode })).step);
    // Unformatted code fails the test (`zig fmt src build.zig` fixes it).
    test_step.dependOn(&b.addFmt(.{ .paths = &.{ b.path("src"), b.path("build.zig") }, .check = true }).step);
}

/// Third-party engine decoders (stb_image, dr_libs).
fn addCDeps(b: *std.Build, m: *std.Build.Module) void {
    m.addIncludePath(b.path("third_party/stb"));
    // stb_image_write's JPEG bit buffer shifts signed ints on purpose (well defined on
    // every compiler it targets); Debug's UB check would trap on it.
    m.addCSourceFile(.{ .file = b.path("third_party/stb/stb_image.c"), .flags = &.{ "-O2", "-fno-sanitize=shift" } });
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

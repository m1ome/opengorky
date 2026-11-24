//! Post-processing page (Rules folder; OpenGorky rules fx.ss `PostChain`, render/post.zig):
//! the frame's steps in order — added, removed, moved up or down — each its program, its
//! strength k (a slider) and, for a grade, its colour; every edit writes the chosen PostChain
//! row (the global one or a location's own: rules_rows, one undo step). Under them the
//! location's background (the global chain: the open level's) with the steps run over it
//! (render/post.zig `apply`, as the game runs them over the drawn world), or as it is: made
//! again only when the steps or the picture change (the level stage's too, `stageTexture`).
//! Classic: locked.

const std = @import("std");
const Allocator = std.mem.Allocator;
const og = @import("opengorky");
const c = @import("sdl");
const clay = @import("clay.zig");
const gui = @import("widgets.zig");
const lay = @import("layout.zig");
const font_mod = @import("font.zig");
const tx = @import("text.zig");
const rulespages = @import("rulespages.zig");
const rules_rows = @import("rules_rows.zig");
const level = @import("level.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const theme = app_mod.theme;
const Post = og.core.effect.Post;
const Chain = og.core.effect.PostChain;

/// The page's state (`app.post`): the step shown, a slider being dragged (its value shown
/// before it is written), the preview's picture and what its texture shows.
pub const State = struct {
    /// The chain edited: a level's own (its name), empty: the global one.
    level_buf: [64]u8 = undefined,
    level_len: usize = 0,
    sel: ?usize = null,
    drag: ?struct { ch: u8, v: f32 } = null,
    before: bool = false,
    /// The background (`of`: its level and load) and its texture as last made (`key`).
    still: ?og.image.Image = null,
    of: u64 = 0,
    tex: ?*c.SDL_Texture = null,
    /// On the GPU renderer: the still uploaded once, drawn through the game's shader into
    /// `tex` (a render target there).
    src: ?*c.SDL_Texture = null,
    key: u64 = 0,
    /// When `tex` was last made (SDL ticks): a slider being dragged remakes it at most
    /// every `drag_ms`.
    made_ms: u64 = 0,
};

/// The steps run over the whole background on the CPU (a 2000×1900 picture: tens of ms):
/// every frame of a drag made the slider stall.
const drag_ms = 100;

/// The sliders' top (k and the colour: 0…2).
const top: f32 = 2;
const programs = std.meta.fieldNames(@FieldType(Post, "program"));

/// The level whose chain is edited ("": the global one).
fn chainLevel(app: *const App) []const u8 {
    return app.post.level_buf[0..app.post.level_len];
}

/// The chain of level `lv` ("": the global one) edited, the page shown.
pub fn showFor(app: *App, lv: []const u8) void {
    choose(app, lv);
    @import("doctabs.zig").show(app, .post, "");
}

fn choose(app: *App, lv: []const u8) void {
    const n = @min(lv.len, app.post.level_buf.len);
    @memcpy(app.post.level_buf[0..n], lv[0..n]);
    app.post.level_len = n;
    app.post.sel = null;
}

/// The steps in force on the chosen level.
fn steps(app: *const App) []const Post {
    return og.core.modules.postSteps(chainLevel(app));
}

/// The hint on battle `name`'s chain: the location whose scripts start it (core/modules.zig
/// locationOf), and the others that start it too.
pub fn battleHint(a: Allocator, name: []const u8) []const u8 {
    const loc = og.core.modules.locationOf(name) orelse return tx.get(tx.post_battle_none);
    var more: std.ArrayList(u8) = .empty;
    for (og.core.modules.starts) |s| if (std.ascii.eqlIgnoreCase(s.battle, name) and !std.ascii.eqlIgnoreCase(s.location, loc)) {
        more.appendSlice(a, if (more.items.len > 0) ", " else "") catch {};
        more.appendSlice(a, s.location) catch {};
    };
    return tx.alloc(a, tx.post_battle_hint, .{ loc, if (more.items.len > 0) tx.alloc(a, tx.post_battle_more, .{more.items}) else "" });
}

/// Level `name` gets its own chain, a copy of the one in force (the global one, a battle's
/// location's: `own`), or that one again (its row dropped): one undo step.
pub fn setOwn(app: *App, name: []const u8, own: bool) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    if (name.len == 0) return error.NoSuchLevel;
    if (!own) {
        _ = try rules_rows.drop(app, Chain, .{ .level = name });
        return;
    }
    if (og.core.modules.postChain(name) == null) try rules_rows.put(app, Chain, .{ .level = name, .steps = og.core.modules.postSteps(name) });
}

/// The chain made `ss` (its row; one undo step).
fn put(app: *App, ss: []const Post) !void {
    if (!app.ogLayout()) return error.ClassicProject;
    try rules_rows.put(app, Chain, .{ .level = chainLevel(app), .steps = ss });
    app.setStatus(tx.st_rules_row, .{std.fmt.allocPrint(app.frame.allocator(), "PostChain ({d})", .{ss.len}) catch "PostChain"});
}

/// A step of `program` after the last, shown.
pub fn add(app: *App, program: []const u8) !void {
    const p = std.meta.stringToEnum(@FieldType(Post, "program"), program) orelse return error.NoSuchProgram;
    const ss = steps(app);
    try put(app, try std.mem.concat(app.frame.allocator(), Post, &.{ ss, &.{.{ .program = p, .k = if (p == .grade or p == .hsl) 1 else 0.5 }} }));
    app.post.sel = ss.len;
}

/// Step `i`: `field` (program, k, rgb) typed as `text`, or moved (`up`, `down`) or
/// removed (`remove`) — the page's edits and `--post`.
pub fn setStep(app: *App, i: usize, field: []const u8, text: []const u8) !void {
    const a = app.frame.allocator();
    const out = try a.dupe(Post, steps(app));
    if (i >= out.len) return error.NoSuchStep;
    app.post.sel = i;
    if (std.mem.eql(u8, field, "remove")) {
        app.post.sel = null;
        return put(app, try std.mem.concat(a, Post, &.{ out[0..i], out[i + 1 ..] }));
    }
    if (std.mem.eql(u8, field, "up") or std.mem.eql(u8, field, "down")) {
        const j = if (field[0] == 'u') std.math.sub(usize, i, 1) catch return else i + 1;
        if (j >= out.len) return;
        std.mem.swap(Post, &out[i], &out[j]);
        app.post.sel = j;
        return put(app, out);
    }
    const t = std.mem.trim(u8, text, " ");
    if (std.mem.eql(u8, field, "program")) {
        out[i].program = std.meta.stringToEnum(@FieldType(Post, "program"), t) orelse return error.NoSuchProgram;
    } else if (std.mem.eql(u8, field, "k")) {
        out[i].k = try og.loaders.codec.readText(f32, a, t, &app.rule_why);
    } else if (std.mem.eql(u8, field, "rgb")) {
        out[i].rgb = try og.loaders.codec.readText([3]f32, a, t, &app.rule_why);
    } else return error.NoSuchField;
    try put(app, out);
}

pub fn page(app: *App, a: Allocator) void {
    rulespages.head(app, "post_page", .image, tx.post_title, tx.post_hint);
    clay.close();
    rulespages.form("post_page");
    // Classic has no post-processing page (its tree row is OpenGorky's).
    if (!app.ogLayout()) return clay.closeScrollColumn();
    // The dragged slider's value in place of its step's until it is let go (then written).
    var shown = a.dupe(Post, steps(app)) catch return clay.closeScrollColumn();
    const sel = if (app.post.sel) |s| if (s < shown.len) s else null else null;
    if (sel) |s| if (app.post.drag) |d| {
        if (d.ch == 0) shown[s].k = d.v else shown[s].rgb[d.ch - 1] = d.v;
    };
    const lv = chainLevel(app);
    if (gui.block(app, "post_for", tx.get(tx.post_for), .{ .summary = if (lv.len > 0) lv else tx.get(tx.post_global) })) {
        forRows(app, a, lv);
        gui.blockEnd();
    }
    if (lv.len > 0 and og.core.modules.postChain(lv) == null) gui.note(if (og.core.modules.postLocation(lv)) |r| tx.alloc(a, tx.post_loc_note, .{ lv, r.level }) else tx.alloc(a, tx.post_shared_note, .{lv}));
    if (gui.block(app, "post_steps", tx.get(tx.post_sec), .{ .summary = std.fmt.allocPrint(a, "{d}", .{shown.len}) catch "" })) {
        stepRows(app, a, shown, sel);
        gui.blockEnd();
    }
    if (gui.block(app, "post_preview", tx.get(tx.post_preview), .{})) {
        preview(app, a, shown);
        gui.blockEnd();
    }
    clay.closeScrollColumn();
}

/// The chains to pick: the global one, the open level, every level with its own.
fn forRows(app: *App, a: Allocator, lv: []const u8) void {
    var names: std.ArrayList([]const u8) = .empty;
    if (app.doc) |d| names.append(a, d.name) catch {};
    for (og.core.modules.tables().post) |r| if (r.level.len > 0 and !(app.doc != null and std.ascii.eqlIgnoreCase(app.doc.?.name, r.level))) names.append(a, r.level) catch {};
    if (forRow(app, 0, tx.get(tx.post_global), tx.get(tx.post_global_hint), lv.len == 0)) choose(app, "");
    for (names.items, 1..) |n, k| {
        const own = og.core.modules.postChain(n);
        const what = if (own) |r| tx.alloc(a, tx.post_own, .{r.steps.len}) else if (og.core.modules.postLocation(n)) |r| tx.alloc(a, tx.post_as_loc, .{r.level}) else tx.get(tx.post_shared);
        if (forRow(app, @intCast(k), n, what, std.ascii.eqlIgnoreCase(n, lv))) choose(app, n);
    }
}

fn forRow(app: *App, k: u32, name: []const u8, what: []const u8, on: bool) bool {
    const hit = gui.listRow(app, clay.idi("post_for", k), .{ .selected = on });
    gui.txtClip(name, .body, theme.text, if (on) font_mod.bold else font_mod.regular);
    gui.spacer();
    gui.txt(what, .caption, theme.dim, font_mod.regular);
    clay.close();
    return hit;
}

fn stepRows(app: *App, a: Allocator, shown: []Post, sel: ?usize) void {
    for (shown, 0..) |s, k| {
        const on = sel == k;
        if (gui.listRow(app, clay.idi("post_row", @intCast(k)), .{ .selected = on })) app.post.sel = if (on) null else k;
        gui.txt(std.fmt.allocPrint(a, "{d}. {t}", .{ k + 1, s.program }) catch "", .body, theme.text, if (on) font_mod.bold else font_mod.regular);
        gui.txtClip(if (s.program == .grade or s.program == .hsl) std.fmt.allocPrint(a, "k {d:.2} · rgb {d:.2} {d:.2} {d:.2}", .{ s.k, s.rgb[0], s.rgb[1], s.rgb[2] }) catch "" else std.fmt.allocPrint(a, "k {d:.2}", .{s.k}) catch "", .caption, theme.dim, font_mod.regular);
        clay.close();
    }
    if (shown.len == 0) gui.note(tx.get(tx.post_empty));
    // A new step of each program; the shown one's moves.
    var labels: [programs.len + 3][]const u8 = undefined;
    for (programs, 0..) |p, k| labels[k] = tx.alloc(a, tx.post_add, .{p});
    var n: usize = programs.len;
    if (sel != null) {
        for ([_]tx.Msg{ tx.fxd_up, tx.fxd_down, tx.fxd_remove }) |m| {
            labels[n] = tx.get(m);
            n += 1;
        }
    }
    if (gui.footer(app, "post_ops", labels[0..n], null)) |b| {
        const r = if (b < programs.len) add(app, programs[b]) else setStep(app, sel.?, ([_][]const u8{ "up", "down", "remove" })[b - programs.len], "");
        r catch |err| app.failed(err);
    }
    const i = sel orelse return;
    const s = shown[i];
    gui.subhead(tx.alloc(a, tx.post_step, .{ i + 1, @tagName(s.program) }));
    gui.fieldRow("program");
    if (gui.segmented(app, "post_program", programs, @backingInt(s.program))) |k| setStep(app, i, "program", programs[k]) catch |err| app.failed(err);
    clay.close();
    slider(app, a, i, 0, "k", s.k);
    if (s.program == .grade or s.program == .hsl) for (if (s.program == .hsl) [_][]const u8{ "h", "s", "l" } else [_][]const u8{ "r", "g", "b" }, 0..) |l, ch| slider(app, a, i, @intCast(ch + 1), l, s.rgb[ch]);
    gui.note(tx.get(switch (s.program) {
        .grade => tx.post_grade,
        .vignette => tx.post_vignette,
        .scanlines => tx.post_scanlines,
        .hsl => tx.post_hsl,
    }));
}

/// Channel `ch` (0: k, 1…3: r, g, b) of step `i` on a 0…2 slider: shown while dragged,
/// written when let go.
fn slider(app: *App, a: Allocator, i: usize, ch: u8, label: []const u8, v: f32) void {
    gui.fieldRow(label);
    const id = std.fmt.allocPrint(a, "post_sl{d}", .{ch}) catch "post_sl";
    if (gui.slider(app, id, v / top)) |x| app.post.drag = .{ .ch = ch, .v = @round(x * top * 100) / 100 };
    gui.txt(std.fmt.allocPrint(a, "{d:.2}", .{v}) catch "", .body, theme.text, font_mod.regular);
    clay.close();
    // Let go: the dragged value written (one undo step).
    const d = app.post.drag orelse return;
    if (d.ch != ch or app.slider_drag != null) return;
    app.post.drag = null;
    var out = a.dupe(Post, steps(app)) catch return;
    if (ch == 0) out[i].k = d.v else out[i].rgb[ch - 1] = d.v;
    put(app, out) catch |err| app.failed(err);
}

/// The chosen level's background (the global chain: the open level's) with `shown` run
/// over it (or as it is), fit to the page.
fn preview(app: *App, a: Allocator, shown: []const Post) void {
    if (gui.segmented(app, "post_view", &.{ tx.get(tx.post_before), tx.get(tx.post_after) }, @intFromBool(!app.post.before))) |k| app.post.before = k == 0;
    const name = stillName(app) orelse return gui.note(tx.get(tx.post_no_level));
    const t = texture(app, &app.post, name, shown) orelse return gui.note(tx.get(tx.post_no_level));
    var w: f32 = 0;
    var h: f32 = 0;
    _ = c.SDL_GetTextureSize(t, &w, &h);
    // The page's width (its last layout) up to a page's, the picture's shape kept.
    const pw = @min(lay.width.page, if (clay.box(clay.id("post_pic"))) |b| b.width else lay.width.page);
    clay.open(.{ .id = clay.id("post_pic"), .layout = .{ .sizing = .{ .width = clay.grow() } } });
    clay.leaf(.{ .layout = .{ .sizing = .{ .width = clay.fixed(pw), .height = clay.fixed(pw * h / @max(1, w)) } }, .image = .{ .imageData = t } });
    clay.close();
    gui.note(tx.alloc(a, tx.post_still, .{name}));
}

/// Level `name`'s background, the level loaded for it alone (not the open one).
fn otherStill(app: *App, name: []const u8) ?og.image.Image {
    const d = level.Doc.load(&app.store, app.r, name) catch return null;
    defer d.deinit();
    return d.backgroundImage(app.io, app.dat, name) catch null;
}

pub fn deinit(app: *App) void {
    drop(app, &app.post);
    drop(app, &app.post_stage);
    app.post_gpu.deinit(app.r);
}

fn drop(app: *App, st: *State) void {
    if (st.still) |*img| img.deinit(app.gpa);
    if (st.tex) |t| c.SDL_DestroyTexture(t);
    if (st.src) |t| c.SDL_DestroyTexture(t);
    st.still = null;
    st.tex = null;
    st.src = null;
}

/// The level stage's background with the chain in force on level `d` run over it (the
/// editor's marks drawn over it, as the game's interface is over its frame); null: Classic,
/// switched off (`app.stage_post`) or no steps (the bare background drawn).
pub fn stageTexture(app: *App, d: *level.Doc) ?*c.SDL_Texture {
    if (!app.ogLayout() or !app.stage_post) return null;
    const ss = og.core.modules.postSteps(d.name);
    if (ss.len == 0) return null;
    return texture(app, &app.post_stage, d.name, ss);
}

/// What the preview shows: the steps, the picture and the toggle.
fn keyOf(shown: []const Post, of: u64, before: bool) u64 {
    var h: std.hash.Wyhash = .init(of);
    h.update(&.{@intFromBool(before)});
    for (shown) |s| {
        h.update(&.{@backingInt(s.program)});
        for ([_]f32{ s.k, s.rgb[0], s.rgb[1], s.rgb[2] }) |x| h.update(std.mem.asBytes(&x));
    }
    return h.final();
}

/// The level whose background the preview shows: the chosen one, else the open one.
fn stillName(app: *const App) ?[]const u8 {
    const lv = chainLevel(app);
    return if (lv.len > 0) lv else if (app.doc) |d| d.name else null;
}

/// The preview's texture, made again only when its key changes (the steps run once per change).
fn texture(app: *App, st: *State, name: []const u8, shown: []const Post) ?*c.SDL_Texture {
    const open = if (app.doc) |d| std.ascii.eqlIgnoreCase(d.name, name) else false;
    // The open level by its load (an unsaved picture too), another by its name.
    const of = std.hash.Wyhash.hash(if (open) app.doc.?.serial else 0, name);
    if (st.of != of) {
        drop(app, st);
        st.still = if (open) app.doc.?.backgroundImage(app.io, app.dat, name) catch null else otherStill(app, name);
        st.of = of;
        st.key = 0;
    }
    const img = st.still orelse return null;
    const key = keyOf(shown, st.of, st.before);
    if (st.tex != null and st.key == key) return st.tex;
    const now = c.SDL_GetTicks();
    if (st.tex != null and app.slider_drag != null and now -% st.made_ms < drag_ms) return st.tex;
    st.made_ms = now;
    if (gpuTexture(app, st, img, shown)) |t| {
        st.key = key;
        return t;
    }
    if (st.tex == null) st.tex = c.SDL_CreateTexture(app.r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STREAMING, @intCast(img.width), @intCast(img.height));
    const t = st.tex orelse return null;
    const px = app.gpa.dupe(u8, img.pixels) catch return null;
    defer app.gpa.free(px);
    if (!st.before) og.render.post.apply(shown, px, img.width, img.height, img.width * 4);
    _ = c.SDL_UpdateTexture(t, null, px.ptr, @intCast(img.width * 4));
    st.key = key;
    return t;
}

/// On the GPU renderer the still drawn through the game's shader (viewer/gpu/post.zig, as
/// the game draws the chain) into `st.tex`; null on another renderer (render/post.zig then).
fn gpuTexture(app: *App, st: *State, img: og.image.Image, shown: []const Post) ?*c.SDL_Texture {
    const r = app.r;
    if (!app.post_gpu.ready(r)) return null;
    const w: c_int = @intCast(img.width);
    const h: c_int = @intCast(img.height);
    if (st.src == null) {
        st.src = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STATIC, w, h);
        const s = st.src orelse return null;
        _ = c.SDL_SetTextureBlendMode(s, c.SDL_BLENDMODE_NONE);
        _ = c.SDL_UpdateTexture(s, null, img.pixels.ptr, w * 4);
    }
    if (st.tex == null) st.tex = c.SDL_CreateTexture(r, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_TARGET, w, h);
    const t = st.tex orelse return null;
    const old = c.SDL_GetRenderTarget(r);
    _ = c.SDL_SetRenderTarget(r, t);
    if (st.before) _ = c.SDL_RenderTexture(r, st.src, null, null) else app.post_gpu.draw(r, st.src.?, @floatFromInt(w), @floatFromInt(h), shown);
    _ = c.SDL_SetRenderTarget(r, old);
    return t;
}

test "post steps: the row round-trips through the rules text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ss = [_]Post{ .{ .program = .grade, .k = 0.5, .rgb = .{ 1, 0.9, 0.8 } }, .{ .program = .vignette, .k = 0.3 } };
    var t = try rules_rows.putText(a, a, Chain, "Material(name = \"m\");\n", .{ .steps = &ss });
    // Put again (one step fewer): written over in place, no second row.
    t = try rules_rows.putText(a, a, Chain, t, .{ .steps = ss[1..] });
    var diag: og.script.ogs.parser.Diagnostic = .{};
    const rows = og.loaders.codec.parseRows(a, t, &diag).?;
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    const got = try og.loaders.codec.read(Chain, a, rows[1].kind.call, null);
    try std.testing.expectEqual(@as(usize, 1), got.steps.len);
    try std.testing.expect(got.steps[0].program == .vignette and got.steps[0].k == 0.3);
    // The key changes with a step's value and the toggle.
    try std.testing.expect(keyOf(&ss, 1, false) != keyOf(ss[0..1], 1, false));
    try std.testing.expect(keyOf(&ss, 1, false) != keyOf(&ss, 1, true));
}

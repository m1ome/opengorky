//! The code editor's probe (`--code-probe PREFIX`): every script and rules file whose
//! `archive:entry` starts with PREFIX opened in turn; at each name in it, whether Go to
//! (codeview.defsAt), the hover tip (codetips.tipsAt) and completion (the name's first
//! letters typed, codecomplete.wordsAt) know it; the time to open (with its check) and
//! to draw a frame scrolled through it. One line per miss, one per file, a summary per
//! kind of name: a map of what the editor does not know yet, and how slow it is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("sdl");
const code = @import("code.zig");
const codeview = @import("codeview.zig");
const codetips = @import("codetips.zig");
const codecomplete = @import("codecomplete.zig");
const codenav = @import("codenav.zig");
const doctabs = @import("doctabs.zig");
const main = @import("main.zig");
const App = @import("app.zig").App;

/// What a name is where it stands: a call (`f(`), a member (`x.f`), a path (`a::b`), a
/// field statement (`hp =`), a declaration's own name (`fn f`), a string's text, else a word.
const Cat = enum { call, member, path, field, decl, string, word };

const Count = struct { n: u32 = 0, def: u32 = 0, code: u32 = 0, help: u32 = 0, multi: u32 = 0, tip: u32 = 0, comp: u32 = 0, comp_n: u32 = 0 };

const decl_words = [_][]const u8{ "fn", "function", "component", "trait", "struct", "enum", "module", "var", "param", "use", "native", "int", "float", "string", "bool", "object" };

pub fn run(app: *App, prefix: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const files = codenav.texts(app, arena.allocator());
    var counts: [@typeInfo(Cat).@"enum".field_names.len]Count = @splat(.{});
    var nfiles: u32 = 0;
    for (files) |f| {
        var kb: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "{s}:{s}", .{ f.archive, f.entry }) catch continue;
        // `?`: the texts' keys only.
        if (std.mem.eql(u8, prefix, "?")) {
            std.debug.print("{s}\n", .{key});
            continue;
        }
        if (!std.mem.startsWith(u8, key, prefix)) continue;
        const idx = app.store.file(f.archive, f.entry) catch continue;
        nfiles += 1;
        probeFile(app, idx, key, &counts);
    }
    std.debug.print("SUMMARY files={d}\n", .{nfiles});
    for (counts, 0..) |k, ci| {
        if (k.n == 0) continue;
        std.debug.print("SUMMARY {s:<7} names={d:>6} def={d:>5.1}% (code {d:>5.1}% help {d:>5.1}%) multi={d:>5.1}% tip={d:>5.1}% comp={d:>5.1}% (of {d})\n", .{
            @tagName(@as(Cat, @fromBackingInt(@intCast(ci)))), k.n, pct(k.def, k.n), pct(k.code, k.n), pct(k.help, k.n), pct(k.multi, k.n), pct(k.tip, k.n), pct(k.comp, k.comp_n), k.comp_n,
        });
    }
}

fn pct(a: u32, b: u32) f64 {
    return if (b == 0) 0 else @as(f64, @floatFromInt(a)) * 100 / @as(f64, @floatFromInt(b));
}

fn ms(from: u64) f64 {
    return @as(f64, @floatFromInt(c.SDL_GetPerformanceCounter() - from)) * 1000 / @as(f64, @floatFromInt(c.SDL_GetPerformanceFrequency()));
}

fn draw(app: *App) void {
    main.present(app, main.frame(app, app.size, .{ 0, 0 }));
    // Outside the main loop nothing presents: SDL queued every frame's commands (100+ GB).
    _ = c.SDL_FlushRenderer(app.r);
}

fn probeFile(app: *App, idx: usize, key: []const u8, counts: []Count) void {
    var t0 = c.SDL_GetPerformanceCounter();
    doctabs.showCode(app, idx, null);
    draw(app);
    const open_ms = ms(t0);
    const v = app.code orelse return;
    // The check's findings (to compare two builds' checks).
    if (v.err_line > 0) std.debug.print("PROB {s}:{d} error {s}\n", .{ key, v.err_line, v.err_buf[0..v.err_len] });
    for (v.unknown[0..v.unknown_n]) |*u| std.debug.print("PROB {s}:{d} {s} {s} {s}\n", .{ key, u.line, @tagName(u.kind), u.name[0..u.len], u.msg[0..u.msg_len] });
    const t = v.buf.str();
    var nlines: usize = 1;
    for (t) |ch| nlines += @intFromBool(ch == '\n');
    // A frame at each of 20 places down the text.
    var frame_max: f64 = 0;
    var frame_sum: f64 = 0;
    for (0..20) |k| {
        v.scroll = nlines * k / 20;
        t0 = c.SDL_GetPerformanceCounter();
        draw(app);
        const d = ms(t0);
        frame_sum += d;
        frame_max = @max(frame_max, d);
    }
    // The same places with the cursor in a call there (its parameters above the line) and
    // the pointer resting on it (the hover tip): the first frame works the tip out, the
    // second has it cached.
    var live_max: f64 = 0;
    var live_sum: f64 = 0;
    for (0..20) |k| {
        v.scroll = nlines * k / 20;
        var at = code.lineOffset(t, @min(v.scroll + 2, nlines - 1));
        if (std.mem.indexOfScalarPos(u8, t[0..code.lineEnd(t, at)], at, '(')) |p| at = p + 1;
        v.buf.cursor = at;
        v.buf.anchor = null;
        app.mouse = codeview.pointOf(app, v, if (at > 0) at - 2 else at);
        v.rest = app.mouse;
        v.rest_since = c.SDL_GetTicks() -% 1000;
        for (0..2) |_| {
            t0 = c.SDL_GetPerformanceCounter();
            draw(app);
            const d = ms(t0);
            live_sum += d;
            live_max = @max(live_max, d);
            if (d > 16) std.debug.print("SLOW {s} frame {d}.{d} {d:.1}ms\n", .{ key, k, @intFromBool(d == d), d });
        }
    }
    v.scroll = 0;
    v.buf.cursor = 0;

    var arena: std.heap.ArenaAllocator = .init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Each name once per file and kind (Go to and the tip are by name, not by place,
    // but for a function's own locals: the first place stands for the rest).
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const ogs = codecomplete.isOgs(app, v);
    var names: u32 = 0;
    t0 = c.SDL_GetPerformanceCounter();
    var ls: usize = 0;
    var line_no: u32 = 1;
    while (ls <= t.len) : (line_no += 1) {
        const le = code.lineEnd(t, ls);
        const line = t[ls..le];
        for (code.highlight(a, line, ogs) catch &.{}) |sp| switch (sp.kind) {
            .keyword, .number, .comment, .directive => {},
            .string => {
                const s = std.mem.trim(u8, line[sp.start..sp.end], "\"");
                if (s.len < 2 or std.mem.indexOfAny(u8, s, " \t%\\") != null) continue;
                // A data row's own value (`Slot(name = "walk", anim = "walk")`): data, not a reference.
                if (rowArg(line, sp.start)) continue;
                const at = ls + sp.start + 1;
                probeName(app, v, a, &seen, key, line_no, .string, s, at, counts, &names);
            },
            else => {
                var k = sp.start;
                while (k < sp.end) {
                    if (!(std.ascii.isAlphabetic(line[k]) or line[k] == '_')) {
                        k += 1;
                        continue;
                    }
                    var e = k;
                    while (e < sp.end and (std.ascii.isAlphanumeric(line[e]) or line[e] == '_')) e += 1;
                    const w = line[k..e];
                    if (!keyword(w)) probeName(app, v, a, &seen, key, line_no, catOf(line, k, e), w, ls + k, counts, &names);
                    k = e;
                }
            },
        };
        if (le >= t.len) break;
        ls = code.lineAfter(t, le);
    }
    std.debug.print("FILE {s} lines={d} open={d:.1}ms frame_avg={d:.2}ms frame_max={d:.2}ms live_avg={d:.2}ms live_max={d:.2}ms names={d} probe={d:.0}ms\n", .{ key, nlines, open_ms, frame_sum / 20, frame_max, live_sum / 40, live_max, names, ms(t0) });
}

/// Whether the string at `s` of `line` is a named argument of a row (`Point(name = "…")`:
/// a capitalized call of no namespace).
fn rowArg(line: []const u8, s: usize) bool {
    var k = s;
    while (k > 0 and line[k - 1] != '(' and line[k - 1] != ',') k -= 1;
    if (std.mem.indexOfScalar(u8, line[k..s], '=') == null) return false;
    const open = std.mem.lastIndexOfScalar(u8, line[0..s], '(') orelse return false;
    var n = open;
    while (n > 0 and (std.ascii.isAlphanumeric(line[n - 1]) or line[n - 1] == '_')) n -= 1;
    return n < open and std.ascii.isUpper(line[n]) and !(n >= 2 and line[n - 1] == ':');
}

fn keyword(w: []const u8) bool {
    for (code.ogs_keywords) |k| if (std.mem.eql(u8, k, w)) return true;
    for ([_][]const u8{ "function", "if", "else", "while", "for", "return", "int", "float", "string", "break", "continue" }) |k| if (std.mem.eql(u8, k, w)) return true;
    return false;
}

fn catOf(line: []const u8, s: usize, e: usize) Cat {
    // The word before: a declaration's keyword.
    var p = s;
    while (p > 0 and (line[p - 1] == ' ' or line[p - 1] == '\t')) p -= 1;
    var q = p;
    while (q > 0 and (std.ascii.isAlphanumeric(line[q - 1]) or line[q - 1] == '_')) q -= 1;
    for (decl_words) |d| if (std.mem.eql(u8, line[q..p], d)) return .decl;
    if (s > 0 and line[s - 1] == '.') return .member;
    if (s >= 2 and std.mem.eql(u8, line[s - 2 .. s], "::")) return .path;
    if (e + 2 <= line.len and std.mem.eql(u8, line[e .. e + 2], "::")) return .path;
    var n = e;
    while (n < line.len and line[n] == ' ') n += 1;
    if (n < line.len and line[n] == '(') return .call;
    if (n < line.len and line[n] == '=' and !(n + 1 < line.len and line[n + 1] == '=')) return .field;
    return .word;
}

fn probeName(app: *App, v: *code.View, a: Allocator, seen: *std.StringHashMapUnmanaged(void), key: []const u8, line_no: u32, cat: Cat, w: []const u8, at: usize, counts: []Count, names: *u32) void {
    const sk = std.fmt.allocPrint(a, "{d}|{s}", .{ @backingInt(cat), w }) catch return;
    if ((seen.getOrPut(a, sk) catch return).found_existing) return;
    names.* += 1;
    const ct = &counts[@backingInt(cat)];
    ct.n += 1;
    var tmp: std.heap.ArenaAllocator = .init(app.gpa);
    defer tmp.deinit();
    const ta = tmp.allocator();
    // Go to (a declaration's own name: not asked, it is the definition).
    const d = codeview.defsAt(app, v, ta, at + 1);
    const found = switch (d) {
        .none => false,
        .here, .file, .rules_doc, .help => true,
        .hits => |h| h.len > 0,
    };
    switch (d) {
        .here, .file => ct.code += 1,
        .help => ct.help += 1,
        .hits => |h| if (h.len > 0 and h[0].to == .code) {
            ct.code += 1;
        },
        else => {},
    }
    if (found or cat == .decl) ct.def += 1 else std.debug.print("MISS def  {s:<7} {s} {s}:{d}\n", .{ @tagName(cat), w, key, line_no });
    if (d == .hits and d.hits.len > 1) {
        ct.multi += 1;
        std.debug.print("MULTI {d} {s:<7} {s} {s}:{d}", .{ d.hits.len, @tagName(cat), w, key, line_no });
        for (d.hits[0..@min(3, d.hits.len)]) |h| std.debug.print(" | {s}", .{h.label});
        std.debug.print("\n", .{});
    }
    if (codetips.tipsAt(app, v, ta, at + 1).len > 0) ct.tip += 1 else std.debug.print("MISS tip  {s:<7} {s} {s}:{d}\n", .{ @tagName(cat), w, key, line_no });
    // Completion: the name's first letters typed in its place (the rest of it gone).
    if (cat == .string or cat == .decl or w.len < 3) return;
    ct.comp_n += 1;
    const typed = @min(w.len - 1, 3);
    const t = v.buf.str();
    const t2 = std.mem.concat(ta, u8, &.{ t[0 .. at + typed], t[at + w.len ..] }) catch return;
    for (codecomplete.wordsAt(app, v, ta, t2, at + typed)) |x| if (std.mem.endsWith(u8, x, w) or std.mem.startsWith(u8, x, w)) {
        ct.comp += 1;
        return;
    };
    std.debug.print("MISS comp {s:<7} {s} {s}:{d}\n", .{ @tagName(cat), w, key, line_no });
}

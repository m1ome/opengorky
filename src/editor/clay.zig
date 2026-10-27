//! Clay from Zig: the C macros (CLAY, CLAY_TEXT, CLAY_ID) as functions. Strings passed
//! to `text` and `id` must live until the frame is rendered (use the frame arena).

const std = @import("std");
const ui = @import("ui");
const Font = @import("font.zig").Font;

pub const Decl = ui.Clay_ElementDeclaration;
const TextConfig = ui.Clay_TextElementConfig;
pub const Color = ui.Clay_Color;
pub const Commands = []const ui.Clay_RenderCommand;

var memory: []u8 = &.{};

/// The same radius at every corner.
pub fn radius(v: f32) ui.Clay_CornerRadius {
    return .{ .topLeft = v, .topRight = v, .bottomLeft = v, .bottomRight = v };
}

pub fn init(gpa: std.mem.Allocator, font: *Font, w: f32, h: f32) !void {
    memory = try gpa.alloc(u8, ui.Clay_MinMemorySize());
    const arena = ui.Clay_CreateArenaWithCapacityAndMemory(memory.len, memory.ptr);
    _ = ui.Clay_Initialize(arena, .{ .width = w, .height = h }, .{ .errorHandlerFunction = onError });
    ui.Clay_SetMeasureTextFunction(measure, font);
}

pub fn deinit(gpa: std.mem.Allocator) void {
    gpa.free(memory);
}

fn onError(e: ui.Clay_ErrorData) callconv(.c) void {
    std.log.warn("clay: {s}", .{e.errorText.chars[0..@intCast(e.errorText.length)]});
}

fn measure(s: ui.Clay_StringSlice, cfg: [*c]ui.Clay_TextElementConfig, user: ?*anyopaque) callconv(.c) ui.Clay_Dimensions {
    const font: *Font = @ptrCast(@alignCast(user.?));
    const d = font.measure(s.chars[0..@intCast(s.length)], cfg.*.fontId, cfg.*.fontSize);
    return .{ .width = d[0], .height = d[1] };
}

pub const Input = struct {
    size: [2]f32,
    mouse: [2]f32,
    down: bool,
    wheel: [2]f32,
    dt: f32,
};

pub fn begin(in: Input) void {
    ui.Clay_SetLayoutDimensions(.{ .width = in.size[0], .height = in.size[1] });
    ui.Clay_SetPointerState(.{ .x = in.mouse[0], .y = in.mouse[1] }, in.down);
    ui.Clay_UpdateScrollContainers(false, .{ .x = in.wheel[0], .y = in.wheel[1] }, in.dt);
    ui.Clay_BeginLayout();
}

pub fn end() Commands {
    const a = ui.Clay_EndLayout();
    return a.internalArray[0..@intCast(a.length)];
}

/// Opens an element; children follow, then `close`.
pub fn open(d: Decl) void {
    ui.Clay__OpenElement();
    ui.Clay__ConfigureOpenElement(d);
}

/// Opens a vertically scrolling element (CLAY with `.clip.childOffset = Clay_GetScrollOffset()`,
/// which must be read after the element is opened).
pub fn openScroll(d: Decl) void {
    ui.Clay__OpenElement();
    var dd = d;
    dd.clip = .{ .vertical = true, .childOffset = ui.Clay_GetScrollOffset() };
    ui.Clay__ConfigureOpenElement(dd);
}

/// Opens an element scrolling sideways.
pub fn openScrollX(d: Decl) void {
    ui.Clay__OpenElement();
    var dd = d;
    dd.clip = .{ .horizontal = true, .childOffset = ui.Clay_GetScrollOffset() };
    ui.Clay__ConfigureOpenElement(dd);
}

pub fn close() void {
    ui.Clay__CloseElement();
}

/// A leaf element.
pub fn leaf(d: Decl) void {
    open(d);
    close();
}

pub fn text(s: []const u8, cfg: TextConfig) void {
    ui.Clay__OpenTextElement(str(s), ui.Clay__StoreTextElementConfig(cfg));
}

pub fn str(s: []const u8) ui.Clay_String {
    return .{ .length = @intCast(s.len), .chars = s.ptr };
}

pub fn id(s: []const u8) ui.Clay_ElementId {
    return ui.Clay__HashString(str(s), 0, 0);
}

pub fn idi(s: []const u8, i: u32) ui.Clay_ElementId {
    return ui.Clay__HashString(str(s), i, 0);
}

/// The element being declared is under the pointer (by last frame's layout).
pub fn hovered() bool {
    return ui.Clay_Hovered();
}

pub fn pointerOver(e: ui.Clay_ElementId) bool {
    return ui.Clay_PointerOver(e);
}

/// Bounding box of element `e` from the last layout.
pub fn box(e: ui.Clay_ElementId) ?ui.Clay_BoundingBox {
    const d = ui.Clay_GetElementData(e);
    return if (d.found) d.boundingBox else null;
}

pub fn grow() ui.Clay_SizingAxis {
    return .{ .type = ui.CLAY__SIZING_TYPE_GROW };
}

pub fn fit() ui.Clay_SizingAxis {
    return .{ .type = ui.CLAY__SIZING_TYPE_FIT };
}

pub fn fixed(v: f32) ui.Clay_SizingAxis {
    return .{ .type = ui.CLAY__SIZING_TYPE_FIXED, .size = .{ .minMax = .{ .min = v, .max = v } } };
}

pub fn rgb(hex: u24) Color {
    return .{ .r = @floatFromInt(hex >> 16), .g = @floatFromInt((hex >> 8) & 0xff), .b = @floatFromInt(hex & 0xff), .a = 255 };
}

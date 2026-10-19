//! Shared console types: the command set, the result and output helpers.

const std = @import("std");

/// Command result the host must carry out.
pub const Effect = enum { none, clear, close };

/// Console commands; each has a line in `help_text` (test below).
pub const Cmd = enum { help, clear, close, fighters, put, spawn, plan, medicine, give, godmode, levelup, exp, popups, heal, ammo, win, lose, map, whereami, level, launch, hitfx, morph, fxstate, explode, wait, push, targets, tile, skipscene, skip, aim, attack, endturn, auto, skills, call, scene, click, hero, defend, get, set, items, equip, pick, state, fire, gas, where, immunities };

pub const Args = std.mem.TokenIterator(u8, .any);

pub fn say(out: *std.Io.Writer, comptime fmt: []const u8, args: anytype) !Effect {
    try out.print(fmt, args);
    return .none;
}

pub fn usage(out: *std.Io.Writer, text: []const u8) !Effect {
    try out.print("usage: {s}\n", .{text});
    return .none;
}

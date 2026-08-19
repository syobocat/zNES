//! What `App` and a platform backend agree on: the vocabulary they pass across
//! the seam, and a compile-time check that a backend actually implements it.
//!
//! `App` imports a backend under the name `platform` and never learns which
//! one answered. That works because the two backends are structurally
//! identical, which until now was true only by inspection -- the types were
//! declared once per backend and nothing compared them. Owning them here makes
//! the agreement a fact rather than a coincidence, and `verify` turns a
//! mismatch in the remaining surface -- the methods -- into a compile error in
//! the file that depends on it.

const std = @import("std");
const znes = @import("znes");
const input = @import("input");
const save = @import("save");

/// Which cartridge a battery save belongs to: the ROM's file name, which is
/// where a backend looks first, and a fingerprint of the ROM itself, which is
/// what settles it when the name has changed or was never unique. See
/// `save.zig` for what a backend does with the pair.
pub const SaveId = save.Id;

/// The console's own buttons, which are not part of any controller: they are
/// on the front of the machine.
///
/// One value rather than two flags, because the machine has one of each and
/// pressing both at once is not a state a desk can be in.
pub const ConsoleButton = enum { reset, power };

/// What one call to `pollInput` observed.
///
/// Some of this is only ever set by one backend -- a browser tab closes
/// without asking, and hands over a dropped file's bytes rather than a path
/// its caller could go and read. Those fields stay in the shared shape rather
/// than being conditional, so `App` and the entry points have one type to
/// handle; the backend that cannot produce one leaves it at its default.
pub const InputState = struct {
    /// The window was closed, or the platform asked us to stop.
    quit: bool = false,
    /// Held buttons for each player, every source already combined.
    players: input.Ports = input.no_input,
    /// Where the pointer is aiming, for a light gun to read.
    gun: input.Gun = .none,
    /// The player asked for something else to be plugged into the ports.
    cycle_peripherals: bool = false,
    /// A console button was pressed, if either was.
    console_button: ?ConsoleButton = null,
    /// A file was dropped on the window. Points into the platform's own
    /// storage and is only valid until the next `pollInput`; the caller must
    /// finish with it (or copy it) before then. If several files were dropped
    /// at once, this is the last of them.
    dropped_path: ?[]const u8 = null,
};

/// A block of text drawn over the video, in the console's own coordinates.
/// Lines within one overlay stack downwards; the placement says where the
/// block as a whole sits.
pub const Overlay = struct {
    lines: []const [:0]const u8,
    placement: Placement,

    pub const Placement = enum { top_left, bottom_left, center };
};

/// Fails to compile unless `P` implements every method `App` calls on a
/// platform, with the parameters and result it calls them expecting.
///
/// Three of these return an inferred error set, whose members differ by
/// backend and are none of `App`'s business, so only the parameters and the
/// payload are pinned.
pub fn verify(comptime P: type) void {
    comptime {
        const Pixel = znes.Palette.Pixel;
        // Initialises in place, for the reasons `App.init` gives.
        method(P, "init", &.{ *P, [:0]const u8, u32, u32, ?std.Io }, void);
        method(P, "deinit", &.{*P}, void);
        method(P, "pollInput", &.{*P}, InputState);
        method(P, "present", &.{ *P, ?[]const Pixel, []const Overlay }, void);
        method(P, "queueAudio", &.{ *P, []const f32 }, void);
        method(P, "clearAudio", &.{*P}, void);
        method(P, "queuedAudioSamples", &.{*P}, usize);
        method(P, "paceFrame", &.{*P}, void);
        method(P, "setTitle", &.{ *P, [:0]const u8 }, void);
        method(P, "loadBatteryRam", &.{ *P, SaveId, []u8 }, bool);
        method(P, "storeBatteryRam", &.{ *P, SaveId, []const u8 }, void);
    }
}

/// One method of the contract. `want` is the result `App` uses; a backend may
/// wrap it in an error set of its own choosing.
fn method(
    comptime P: type,
    comptime name: []const u8,
    comptime params: []const type,
    comptime want: type,
) void {
    if (!@hasDecl(P, name)) {
        @compileError(@typeName(P) ++ " is missing platform method '" ++ name ++ "'");
    }
    const info = switch (@typeInfo(@TypeOf(@field(P, name)))) {
        .@"fn" => |f| f,
        else => @compileError(@typeName(P) ++ "." ++ name ++ " is not a function"),
    };
    if (info.params.len != params.len) {
        @compileError(std.fmt.comptimePrint(
            "{s}.{s} takes {d} parameters, the platform contract has {d}",
            .{ @typeName(P), name, info.params.len, params.len },
        ));
    }
    for (params, info.params, 0..) |want_param, got, i| {
        if (got.type != want_param) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s} parameter {d} is {s}, the platform contract has {s}",
                .{ @typeName(P), name, i, @typeName(got.type orelse anyopaque), @typeName(want_param) },
            ));
        }
    }
    const returns = info.return_type orelse @compileError(@typeName(P) ++ "." ++ name ++ " is generic");
    const payload = switch (@typeInfo(returns)) {
        .error_union => |u| u.payload,
        else => returns,
    };
    if (payload != want) {
        @compileError(std.fmt.comptimePrint(
            "{s}.{s} returns {s}, the platform contract has {s}",
            .{ @typeName(P), name, @typeName(payload), @typeName(want) },
        ));
    }
}

// --- Tests ---------------------------------------------------------------

/// A backend that satisfies the contract and does nothing, which is what the
/// checks below need in order to be about `verify` rather than about SDL.
const Stub = struct {
    pub fn init(_: *Stub, _: [:0]const u8, _: u32, _: u32, _: ?std.Io) !void {}
    pub fn deinit(_: *Stub) void {}
    pub fn pollInput(_: *Stub) InputState {
        return .{};
    }
    pub fn present(_: *Stub, _: ?[]const znes.Palette.Pixel, _: []const Overlay) !void {}
    pub fn queueAudio(_: *Stub, _: []const f32) !void {}
    pub fn clearAudio(_: *Stub) void {}
    pub fn queuedAudioSamples(_: *Stub) usize {
        return 0;
    }
    pub fn paceFrame(_: *Stub) void {}
    pub fn setTitle(_: *Stub, _: [:0]const u8) void {}
    pub fn loadBatteryRam(_: *Stub, _: SaveId, _: []u8) bool {
        return false;
    }
    pub fn storeBatteryRam(_: *Stub, _: SaveId, _: []const u8) void {}
};

test "a complete backend verifies" {
    comptime verify(Stub);
}

test "a console button is one press, not two independent flags" {
    // The state `reset` and `power_cycle` could both be set in is the reason
    // this is an optional enum: a desk has one of each button and no way to
    // press both.
    const idle: InputState = .{};
    try std.testing.expectEqual(@as(?ConsoleButton, null), idle.console_button);

    const pressed: InputState = .{ .console_button = .power };
    try std.testing.expectEqual(ConsoleButton.power, pressed.console_button.?);
}

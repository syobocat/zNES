//! The controller state the app passes around, and the only thing every
//! input source agrees on.
//!
//! A frame's buttons can come from the keyboard, from a gamepad, from a
//! browser's keydown events, or from a movie file being replayed, and the
//! main loop treats them all the same way. This is its own module, below both
//! the app and the platform layers, because it is exactly the vocabulary
//! those two need to share: it lets a platform backend stay free of NES types
//! and `Movie` stay free of any platform's.

const std = @import("std");

/// How many controllers the app drives, which is how many ports the console
/// has. What each port is actually wired to is the core's business
/// (`Nes.Peripherals`).
pub const player_count = 2;

/// One player's held buttons.
///
/// The bit layout is `Controller.Button`'s, so a `@bitCast` to `u8` is
/// exactly what `Controller.setButtons` wants. That agreement is asserted
/// where the two meet -- in `Session.applyInput` -- rather than by importing
/// the core here.
pub const Buttons = packed struct(u8) {
    a: bool = false,
    b: bool = false,
    select: bool = false,
    start: bool = false,
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,

    pub const none: Buttons = .{};

    /// Everything held in either operand. Two sources for one player -- the
    /// keyboard and a gamepad, say -- combine this way, so plugging a pad in
    /// doesn't take the keyboard away.
    pub fn merge(lhs: Buttons, rhs: Buttons) Buttons {
        return @bitCast(@as(u8, @bitCast(lhs)) | @as(u8, @bitCast(rhs)));
    }
};

/// Both players' buttons for one frame.
pub const Ports = [player_count]Buttons;

pub const no_input: Ports = @splat(.none);

/// Where a light gun is pointed, and whether its trigger is being squeezed.
///
/// Not one of the `Ports`: a Zapper is not a pad with extra fields, and
/// nothing that merges two sources of buttons has any business merging two
/// aim points.
pub const Gun = struct {
    /// The pixel under the muzzle, in the console's own 256x240 coordinates.
    x: u8 = 0,
    y: u8 = 0,
    /// Whether the gun is pointed at the screen at all.
    ///
    /// A gun pointed away is a *state*, not missing input: a game checks that
    /// it sees no light during VBlank to prove a gun is plugged in, and
    /// covering the muzzle is how one cheats at Duck Hunt.
    on_screen: bool = false,
    /// Whether the trigger is being squeezed right now. The 100 ms the
    /// hardware takes to answer is the core's business, not a platform's.
    trigger: bool = false,

    pub const none: Gun = .{};
};

test "merge is a bitwise or" {
    const dpad: Buttons = .{ .left = true, .up = true };
    const face: Buttons = .{ .a = true, .up = true };
    try std.testing.expectEqual(
        Buttons{ .a = true, .up = true, .left = true },
        dpad.merge(face),
    );
}

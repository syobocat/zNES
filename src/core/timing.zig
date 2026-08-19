//! NTSC timing: the shape of a frame, and the clock it runs at.
//!
//! Its own file because it is not the PPU's alone. The PPU counts dots,
//! `Zapper` converts a photodiode's decay into them, and a frontend needs the
//! frame rate to pace a loop -- so these belong below all three rather than
//! inside any one of them. There is exactly one machine here (see the module
//! header of `root.zig`), which is why they are constants and not a table.

/// Dots in one scanline, including the ones that fall in horizontal blanking.
pub const dots_per_scanline = 341;
/// Scanlines in one frame: 240 visible, then post-render, VBlank and
/// pre-render.
pub const scanlines_per_frame = 262;
/// Scanlines that reach the screen. The rest carry no picture.
pub const visible_scanlines = 240;
pub const vblank_start_scanline = 241;
pub const prerender_scanline = 261;

/// The picture the PPU draws, which is what every frontend has to put on a
/// screen. One dot per pixel, and one visible scanline per row.
pub const screen_width = 256;
pub const screen_height = visible_scanlines;

/// The PPU's pixel clock, in Hz. Everything else here is counted in dots, so
/// this is the only place the wall clock enters.
pub const dot_clock_hz: f64 = 5_369_318.0;

/// Frames per second, which is not 60: a frame is `dots_per_scanline *
/// scanlines_per_frame` dots less the one an odd frame skips, i.e. half a dot
/// per frame on average. Works out to about 60.0988.
pub const frame_rate: f64 = dot_clock_hz /
    (@as(f64, dots_per_scanline * scanlines_per_frame) - 0.5);

// --- Tests ---------------------------------------------------------------

const std = @import("std");

test "the frame rate follows from the dot clock and the odd-frame skip" {
    // The familiar figure, to the precision it is usually quoted at.
    try std.testing.expectApproxEqAbs(60.0988, frame_rate, 0.0001);

    // Counting a whole 89342 dots -- forgetting the skip -- would be slower.
    const without_skip = dot_clock_hz / @as(f64, dots_per_scanline * scanlines_per_frame);
    try std.testing.expect(frame_rate > without_skip);
}

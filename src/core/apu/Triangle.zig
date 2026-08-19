// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! Triangle channel: a 32-step triangle-wave sequencer gated by both a length
//! counter and a linear counter.
//!
//! Unlike the pulse and noise channels its timer clocks every CPU cycle rather
//! than every other one, so it reaches twice as high a frequency for the same
//! period value -- which is what puts periods 0 and 1 above the audible band.

const Triangle = @This();

pub const init: Triangle = .{};
const LengthCounter = @import("LengthCounter.zig");

/// One full triangle: down from 15 to 0, then back up.
const sequence = [32]u4{
    15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5,  4,  3,  2,  1,  0,
    0,  1,  2,  3,  4,  5,  6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
};

length: LengthCounter = .init,

/// Reload value for the linear counter, from $4008's low 7 bits.
linear_reload_value: u7 = 0,
linear_counter: u7 = 0,
/// Set by a $400B write; makes the next quarter-frame clock reload the linear
/// counter instead of decrementing it. Held set for as long as the control
/// flag is, which is how software keeps the channel sounding indefinitely.
linear_reload_flag: bool = false,

timer_period: u11 = 0,
timer: u11 = 0,
step: u5 = 0,

/// $4008. The control flag doubles as the length counter's halt flag.
pub fn writeControl(self: *Triangle, value: u8) void {
    self.length.halt = (value & 0x80) != 0;
    self.linear_reload_value = @truncate(value & 0x7F);
}

/// $400A.
pub fn writeTimerLow(self: *Triangle, value: u8) void {
    self.timer_period = (self.timer_period & 0x0700) | value;
}

/// $400B. See `LengthCounter.load` for `clock_imminent`.
pub fn writeTimerHighAndLength(self: *Triangle, value: u8, clock_imminent: bool) void {
    self.timer_period = (self.timer_period & 0x00FF) | (@as(u11, value & 0x07) << 8);
    self.length.load(value, clock_imminent);
    self.linear_reload_flag = true;
}

/// One CPU cycle.
pub fn tickTimer(self: *Triangle) void {
    if (self.timer != 0) {
        self.timer -= 1;
        return;
    }
    self.timer = self.timer_period;
    // Both counters gate the sequencer, and neither gates the output: a
    // silenced triangle holds its last level rather than dropping to zero.
    if (self.length.active() and self.linear_counter > 0) self.step +%= 1;
}

pub fn clockLinearCounter(self: *Triangle) void {
    if (self.linear_reload_flag) {
        self.linear_counter = self.linear_reload_value;
    } else if (self.linear_counter > 0) {
        self.linear_counter -= 1;
    }
    if (!self.length.halt) self.linear_reload_flag = false;
}

pub fn output(self: *const Triangle) u4 {
    return sequence[self.step];
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// A channel loaded and free to sound, with `period` in its timer.
fn soundingTriangle(period: u11) Triangle {
    var t: Triangle = .{};
    t.length.enabled = true;
    t.writeControl(0x7F); // control clear, linear reload 127
    t.writeTimerLow(@truncate(period & 0xFF));
    t.writeTimerHighAndLength(@intCast((period >> 8) & 0x07), false);
    t.clockLinearCounter(); // load the linear counter
    return t;
}

test "the sequencer walks down from 15 to 0 and back up" {
    var t = soundingTriangle(0);
    t.step = 0;
    try testing.expectEqual(@as(u4, 15), t.output());
    for (0..15) |_| t.tickTimer();
    try testing.expectEqual(@as(u4, 0), t.output());
    t.tickTimer();
    try testing.expectEqual(@as(u4, 0), t.output()); // the level repeats at the turn
    t.tickTimer();
    try testing.expectEqual(@as(u4, 1), t.output());
}

test "the timer reloads after period+1 CPU cycles" {
    var t = soundingTriangle(3);
    t.timer = 0;
    const before = t.step;
    t.tickTimer(); // steps, and reloads to 3
    try testing.expectEqual(before +% 1, t.step);
    for (0..3) |_| t.tickTimer();
    try testing.expectEqual(before +% 1, t.step);
    t.tickTimer();
    try testing.expectEqual(before +% 2, t.step);
}

test "either counter at zero freezes the sequencer without silencing the output" {
    var t = soundingTriangle(0);
    t.step = 4;
    const level = t.output();

    t.linear_counter = 0;
    t.tickTimer();
    try testing.expectEqual(@as(u5, 4), t.step);
    try testing.expectEqual(level, t.output());

    t.linear_counter = 10;
    t.length.setEnabled(false);
    t.tickTimer();
    try testing.expectEqual(@as(u5, 4), t.step);
    try testing.expectEqual(level, t.output());
}

test "the reload flag survives quarter-frame clocks while the control flag is set" {
    var t: Triangle = .{};
    t.length.enabled = true;
    t.writeControl(0xC0 | 20); // control set, reload value 64 is masked off
    t.writeTimerHighAndLength(0, false);

    // With control set, the flag is never cleared, so every clock reloads.
    for (0..5) |_| {
        t.clockLinearCounter();
        try testing.expectEqual(@as(u7, 0x40 | 20), t.linear_counter);
    }

    // Clearing control lets the next clock consume the flag; after that the
    // counter counts down.
    t.writeControl(20);
    t.clockLinearCounter();
    try testing.expectEqual(@as(u7, 20), t.linear_counter);
    t.clockLinearCounter();
    try testing.expectEqual(@as(u7, 19), t.linear_counter);
}

test "the linear counter stops at zero rather than wrapping" {
    var t = soundingTriangle(0);
    t.linear_reload_flag = false;
    t.linear_counter = 1;
    t.clockLinearCounter();
    try testing.expectEqual(@as(u7, 0), t.linear_counter);
    t.clockLinearCounter();
    try testing.expectEqual(@as(u7, 0), t.linear_counter);
}

test "periods 0 and 1 run the sequencer far above the audible band" {
    // At period 0 the sequencer advances every CPU cycle, so one full 32-step
    // triangle takes 32 CPU cycles -- about 56 kHz. Hardware emits a steady
    // mid-level for this rather than a tone, which the output stage's
    // averaging reproduces.
    var t = soundingTriangle(0);
    var sum: u32 = 0;
    for (0..32) |_| {
        sum += t.output();
        t.tickTimer();
    }
    // The mean of one full period is the midpoint of the 0..15 range.
    try testing.expectEqual(@as(u32, 32 * 15 / 2), sum);
}

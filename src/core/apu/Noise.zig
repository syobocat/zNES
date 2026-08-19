//! Noise channel: a 15-bit linear-feedback shift register clocked from a
//! period lookup table, gated by the same envelope and length counter design
//! as the pulse channels.
//!
//! Mode 0 taps bit 1, giving a 32767-step sequence that sounds like white
//! noise; mode 1 taps bit 6 instead, shortening it to 93 steps and turning it
//! into a metallic tone.

const Noise = @This();

pub const init: Noise = .{};
const Envelope = @import("Envelope.zig");
const LengthCounter = @import("LengthCounter.zig");

/// Periods in **CPU cycles**, not APU cycles. The pulse channels' 11-bit timer
/// counts APU cycles, but this table and the DMC's are both quoted per CPU
/// cycle, which is why `tickTimer` halves before reloading. Every entry is
/// even, so the halving is exact.
const period_table = [16]u16{
    4,   8,   16,  32,  64,  96,   128,  160,
    202, 254, 380, 508, 762, 1016, 2034, 4068,
};

envelope: Envelope = .init,
length: LengthCounter = .init,

mode_short: bool = false,
timer_period: u16 = period_table[0],
timer: u16 = 0,
/// Powers up as 1; a register of all zeroes would never leave that state.
shift: u15 = 1,

/// $400C.
pub fn writeControl(self: *Noise, value: u8) void {
    self.length.halt = (value & 0x20) != 0;
    self.envelope.writeControl(value);
}

/// $400E.
pub fn writePeriod(self: *Noise, value: u8) void {
    self.mode_short = (value & 0x80) != 0;
    self.timer_period = period_table[value & 0x0F];
}

/// $400F. See `LengthCounter.load` for `clock_imminent`.
pub fn writeLength(self: *Noise, value: u8, clock_imminent: bool) void {
    self.length.load(value, clock_imminent);
    self.envelope.start = true;
}

/// One APU cycle, i.e. every other CPU cycle.
pub fn tickTimer(self: *Noise) void {
    if (self.timer != 0) {
        self.timer -= 1;
        return;
    }
    // `period_table` is in CPU cycles while this runs once per APU cycle, so
    // the reload is halved; the -1 is the extra tick the countdown itself
    // costs. Reloading the raw value would stretch every period to
    // `2 * (n + 1)` CPU cycles, roughly an octave low across the board.
    self.timer = self.timer_period / 2 - 1;

    const tap: u1 = if (self.mode_short) @truncate(self.shift >> 6) else @truncate(self.shift >> 1);
    const feedback: u15 = (self.shift & 1) ^ tap;
    self.shift = (self.shift >> 1) | (@as(u15, feedback) << 14);
}

pub fn clockEnvelope(self: *Noise) void {
    self.envelope.clock(self.length.halt);
}

pub fn output(self: *const Noise) u4 {
    if (!self.length.active() or (self.shift & 1) != 0) return 0;
    return self.envelope.output();
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// CPU cycles between two shift-register clocks, measured by running the
/// channel the way `Apu.tick` does: `tickTimer` on every other CPU cycle.
fn measuredPeriodInCpuCycles(rate: u4) u32 {
    var n: Noise = .{};
    n.writePeriod(rate);
    n.timer = 0; // clock on the very first APU tick

    var cpu_cycles: u32 = 0;
    var apu_phase: u1 = 0;
    var clocks: u32 = 0;
    var first_clock_at: u32 = 0;

    while (clocks < 2 and cpu_cycles < 1_000_000) : (cpu_cycles += 1) {
        if (apu_phase == 0) {
            const before = n.shift;
            n.tickTimer();
            if (n.shift != before) {
                clocks += 1;
                if (clocks == 1) first_clock_at = cpu_cycles;
            }
        }
        apu_phase +%= 1;
    }
    return cpu_cycles - 1 - first_clock_at;
}

test "each rate clocks the shift register at its documented CPU-cycle period" {
    // The table is quoted in CPU cycles while the timer runs on APU cycles, so
    // reloading the raw value would make every period twice as long. Measuring
    // in CPU cycles is the only way to catch that, since the table still looks
    // right at a glance.
    for (period_table, 0..) |expected, rate| {
        try testing.expectEqual(expected, measuredPeriodInCpuCycles(@intCast(rate)));
    }
}

test "the period table is even throughout and monotonically increasing" {
    // Evenness is what makes the halving in `tickTimer` exact.
    var previous: u16 = 0;
    for (period_table) |p| {
        try testing.expectEqual(@as(u16, 0), p % 2);
        try testing.expect(p > previous);
        previous = p;
    }
    // The top two entries are the ones most often transcribed wrongly, and a
    // plausible-looking value is no evidence here.
    try testing.expectEqual(@as(u16, 1016), period_table[0xD]);
    try testing.expectEqual(@as(u16, 2034), period_table[0xE]);
    try testing.expectEqual(@as(u16, 4068), period_table[0xF]);
}

/// How many clocks it takes the shift register to return to its starting
/// value, i.e. the sequence length.
fn sequenceLength(mode_short: bool) u32 {
    var n: Noise = .{};
    n.mode_short = mode_short;
    n.timer_period = 4; // the shortest, so each tick clocks
    const start = n.shift;
    var clocks: u32 = 0;
    while (clocks < 100_000) {
        n.timer = 0;
        n.tickTimer();
        clocks += 1;
        if (n.shift == start) break;
    }
    return clocks;
}

test "mode 0 runs the full 32767-step sequence and mode 1 the short 93-step one" {
    try testing.expectEqual(@as(u32, 32767), sequenceLength(false));
    try testing.expectEqual(@as(u32, 93), sequenceLength(true));
}

test "the output is silent whenever the shift register's low bit is set" {
    var n: Noise = .{};
    n.length.enabled = true;
    n.writeControl(0x1F); // constant volume 15
    n.writeLength(0x08, false);

    n.shift = 0b10;
    try testing.expectEqual(@as(u4, 15), n.output());
    n.shift = 0b11;
    try testing.expectEqual(@as(u4, 0), n.output());
}

test "a length counter at zero silences the channel" {
    var n: Noise = .{};
    n.length.enabled = true;
    n.writeControl(0x1F);
    n.writeLength(0x08, false);
    n.shift = 0b10;
    try testing.expectEqual(@as(u4, 15), n.output());

    n.length.setEnabled(false);
    try testing.expectEqual(@as(u4, 0), n.output());
}

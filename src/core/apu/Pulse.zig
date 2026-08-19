//! One of the APU's two pulse channels: a duty-cycle sequencer gated by an
//! envelope, a sweep unit and a length counter.
//!
//! The two channels are identical apart from how their sweep units negate, so
//! one type serves both and `channel` selects between them.

const Pulse = @This();
const Envelope = @import("Envelope.zig");
const LengthCounter = @import("LengthCounter.zig");

/// The four selectable duty cycles. The last is the second inverted, which is
/// why it reads as 75% rather than 25%.
const duty_table = [4][8]u1{
    .{ 0, 1, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 1, 0, 0, 0, 0, 0 },
    .{ 0, 1, 1, 1, 1, 0, 0, 0 },
    .{ 1, 0, 0, 1, 1, 1, 1, 1 },
};

/// Which of the two this is. The only thing it decides is the sweep unit's
/// negation; see `targetPeriod`.
pub const Channel = enum { one, two };

channel: Channel,

envelope: Envelope = .init,
length: LengthCounter = .init,

duty: u2 = 0,
timer_period: u11 = 0,
timer: u11 = 0,
duty_step: u3 = 0,

sweep_enabled: bool = false,
sweep_period: u3 = 0,
sweep_negate: bool = false,
sweep_shift: u3 = 0,
sweep_divider: u3 = 0,
sweep_reload: bool = false,

pub fn init(channel: Channel) Pulse {
    return .{ .channel = channel };
}

/// $4000 / $4004.
pub fn writeControl(self: *Pulse, value: u8) void {
    self.duty = @truncate(value >> 6);
    self.length.halt = (value & 0x20) != 0;
    self.envelope.writeControl(value);
}

/// $4001 / $4005.
pub fn writeSweep(self: *Pulse, value: u8) void {
    self.sweep_enabled = (value & 0x80) != 0;
    self.sweep_period = @truncate((value >> 4) & 0x07);
    self.sweep_negate = (value & 0x08) != 0;
    self.sweep_shift = @truncate(value & 0x07);
    self.sweep_reload = true;
}

/// $4002 / $4006.
pub fn writeTimerLow(self: *Pulse, value: u8) void {
    self.timer_period = (self.timer_period & 0x0700) | value;
}

/// $4003 / $4007. See `LengthCounter.load` for `clock_imminent`.
pub fn writeTimerHighAndLength(self: *Pulse, value: u8, clock_imminent: bool) void {
    self.timer_period = (self.timer_period & 0x00FF) | (@as(u11, value & 0x07) << 8);
    self.length.load(value, clock_imminent);
    self.envelope.start = true;
    self.duty_step = 0;
}

/// One APU cycle, i.e. every other CPU cycle.
pub fn tickTimer(self: *Pulse) void {
    if (self.timer == 0) {
        self.timer = self.timer_period;
        self.duty_step -%= 1;
    } else {
        self.timer -= 1;
    }
}

pub fn clockEnvelope(self: *Pulse) void {
    self.envelope.clock(self.length.halt);
}

/// The period the sweep unit would move to, before muting is considered.
///
/// The two channels differ here: pulse 1 negates with one's complement, an
/// extra -1 against pulse 2's two's complement, so a downward sweep on pulse 1
/// always lands one step lower than the same settings on pulse 2.
fn targetPeriod(self: *const Pulse) u16 {
    const change = self.timer_period >> self.sweep_shift;
    if (!self.sweep_negate) return @as(u16, self.timer_period) + change;
    const ones_complement_extra: u16 = switch (self.channel) {
        .one => 1,
        .two => 0,
    };
    return @as(u16, self.timer_period) -| (change + ones_complement_extra);
}

/// The sweep unit silences the channel whenever the current or target period
/// is out of range, whether or not sweeping is enabled -- so a period below 8
/// mutes even a channel that never writes $4001.
fn sweepMuting(self: *const Pulse) bool {
    return self.timer_period < 8 or self.targetPeriod() > 0x7FF;
}

pub fn clockSweep(self: *Pulse) void {
    if (self.sweep_divider == 0 and self.sweep_enabled and self.sweep_shift != 0 and !self.sweepMuting()) {
        self.timer_period = @truncate(self.targetPeriod());
    }
    if (self.sweep_divider == 0 or self.sweep_reload) {
        self.sweep_divider = self.sweep_period;
        self.sweep_reload = false;
    } else {
        self.sweep_divider -= 1;
    }
}

pub fn output(self: *const Pulse) u4 {
    if (!self.length.active() or self.sweepMuting()) return 0;
    if (duty_table[self.duty][self.duty_step] == 0) return 0;
    return self.envelope.output();
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// A channel at constant volume 15 with a mid-range period and a loaded length
/// counter, so `output` is decided by the duty sequencer and the sweep unit
/// alone.
fn soundingPulse(channel: Channel, period: u11) Pulse {
    var p = Pulse.init(channel);
    p.length.enabled = true;
    p.writeControl(0x3F); // duty 0, halt, constant volume 15
    p.writeTimerLow(@truncate(period & 0xFF));
    p.writeTimerHighAndLength(@intCast((period >> 8) & 0x07), false);
    return p;
}

test "the timer reloads after period+1 APU cycles and steps the sequencer" {
    var p = soundingPulse(.one, 3);
    p.timer = 0;
    p.duty_step = 0;
    p.tickTimer(); // reload, and step
    try testing.expectEqual(@as(u3, 7), p.duty_step); // counts down
    for (0..3) |_| p.tickTimer();
    try testing.expectEqual(@as(u3, 7), p.duty_step);
    p.tickTimer();
    try testing.expectEqual(@as(u3, 6), p.duty_step);
}

test "each duty setting outputs its documented pattern" {
    // The sequencer counts down, so walking `duty_step` upward walks the table
    // backwards; compare against the table itself rather than a transcription.
    for (0..4) |duty| {
        var p = soundingPulse(.one, 100);
        p.duty = @intCast(duty);
        for (0..8) |step| {
            p.duty_step = @intCast(step);
            const expected: u4 = if (duty_table[duty][step] == 1) 15 else 0;
            try testing.expectEqual(expected, p.output());
        }
    }
}

test "a period below 8 mutes the channel even with sweeping disabled" {
    var p = soundingPulse(.one, 8);
    p.duty_step = 1; // a high step of duty 0
    try testing.expectEqual(@as(u4, 15), p.output());

    p.timer_period = 7;
    try testing.expectEqual(@as(u4, 0), p.output());
}

test "a target period above $7FF mutes the channel" {
    var p = soundingPulse(.one, 0x400);
    p.duty_step = 1;
    p.sweep_shift = 1; // target = 0x400 + 0x200, still in range
    try testing.expectEqual(@as(u4, 15), p.output());

    p.sweep_shift = 0; // target = 0x400 + 0x400 = 0x800, out of range
    try testing.expectEqual(@as(u4, 0), p.output());
}

test "a negative sweep on pulse 1 lands one step lower than on pulse 2" {
    // Pulse 1 negates with one's complement, pulse 2 with two's complement.
    var one = soundingPulse(.one, 0x200);
    var two = soundingPulse(.two, 0x200);
    for ([_]*Pulse{ &one, &two }) |p| {
        p.sweep_negate = true;
        p.sweep_shift = 1; // change = 0x100
    }
    try testing.expectEqual(@as(u16, 0x200 - 0x100 - 1), one.targetPeriod());
    try testing.expectEqual(@as(u16, 0x200 - 0x100), two.targetPeriod());
}

test "the sweep unit only moves the period when enabled with a non-zero shift" {
    var p = soundingPulse(.one, 0x200);
    p.sweep_enabled = false;
    p.sweep_shift = 1;
    p.sweep_divider = 0;
    p.clockSweep();
    try testing.expectEqual(@as(u11, 0x200), p.timer_period);

    // A shift of zero means the target equals the period, so sweeping it would
    // be a no-op anyway -- but hardware declines outright.
    p.sweep_enabled = true;
    p.sweep_shift = 0;
    p.sweep_divider = 0;
    p.clockSweep();
    try testing.expectEqual(@as(u11, 0x200), p.timer_period);

    p.sweep_shift = 1;
    p.sweep_divider = 0;
    p.clockSweep();
    try testing.expectEqual(@as(u11, 0x300), p.timer_period);
}

test "the sweep divider moves the period once every period+1 clocks" {
    var p = soundingPulse(.one, 0x100);
    p.sweep_enabled = true;
    p.sweep_shift = 1;
    p.sweep_period = 2;
    p.sweep_divider = 2;

    p.clockSweep(); // divider 2 -> 1
    p.clockSweep(); // divider 1 -> 0
    try testing.expectEqual(@as(u11, 0x100), p.timer_period);
    p.clockSweep(); // divider is 0, so this one moves and reloads
    try testing.expectEqual(@as(u11, 0x180), p.timer_period);
    try testing.expectEqual(@as(u3, 2), p.sweep_divider);
}

test "a $4001 write reloads the divider on the next clock without skipping a move" {
    var p = soundingPulse(.one, 0x100);
    p.sweep_divider = 1;
    p.writeSweep(0x81); // enabled, period 0, shift 1
    try testing.expect(p.sweep_reload);

    // The divider is not zero, so this clock does not move the period, but the
    // reload flag still forces it back to the new period.
    p.clockSweep();
    try testing.expectEqual(@as(u11, 0x100), p.timer_period);
    try testing.expect(!p.sweep_reload);
    try testing.expectEqual(@as(u3, 0), p.sweep_divider);

    p.clockSweep();
    try testing.expectEqual(@as(u11, 0x180), p.timer_period);
}

test "a muting sweep is not applied, so the period cannot run away" {
    var p = soundingPulse(.one, 0x700);
    p.sweep_enabled = true;
    p.sweep_shift = 1; // target 0x780+0x700 > 0x7FF
    p.sweep_divider = 0;
    p.clockSweep();
    try testing.expectEqual(@as(u11, 0x700), p.timer_period);
}

test "a length counter at zero silences the channel whatever the sequencer says" {
    var p = soundingPulse(.one, 100);
    p.duty_step = 1;
    try testing.expectEqual(@as(u4, 15), p.output());
    p.length.setEnabled(false);
    try testing.expectEqual(@as(u4, 0), p.output());
}

test "writing the timer high byte restarts the sequencer and the envelope" {
    var p = soundingPulse(.one, 100);
    p.duty_step = 5;
    p.envelope.start = false;
    p.writeTimerHighAndLength(0, false);
    try testing.expectEqual(@as(u3, 0), p.duty_step);
    try testing.expect(p.envelope.start);
}

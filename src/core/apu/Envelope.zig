//! The envelope generator shared by the two pulse channels and the noise
//! channel: a 4-bit decay counter fed by a divider, clocked once per quarter
//! frame.
//!
//! The same register field is both the divider's period and the channel's
//! constant volume level, so `output` picks between the two rather than the
//! envelope being bypassed.

const Envelope = @This();

pub const init: Envelope = .{};

/// When set, the channel outputs `volume` directly and the decay counter,
/// though still clocked, is ignored.
constant_volume: bool = false,
/// Constant volume level, or the divider's reload period.
volume: u4 = 0,

/// Set by a write to the channel's length/timer-high register; the next clock
/// restarts the envelope instead of advancing it.
start: bool = false,
divider: u4 = 0,
decay: u4 = 0,

/// Takes the low 5 bits of a $4000/$4004/$400C write.
pub fn writeControl(self: *Envelope, value: u8) void {
    self.constant_volume = (value & 0x10) != 0;
    self.volume = @truncate(value & 0x0F);
}

/// One quarter-frame clock. `loop` is the channel's length-counter halt flag,
/// which doubles as this envelope's loop flag.
pub fn clock(self: *Envelope, loop: bool) void {
    if (self.start) {
        self.start = false;
        self.decay = 15;
        self.divider = self.volume;
        return;
    }
    if (self.divider != 0) {
        self.divider -= 1;
        return;
    }
    self.divider = self.volume;
    if (self.decay > 0) {
        self.decay -= 1;
    } else if (loop) {
        self.decay = 15;
    }
}

pub fn output(self: *const Envelope) u4 {
    return if (self.constant_volume) self.volume else self.decay;
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "the start flag reloads the decay to 15 and the divider to the period" {
    var envelope: Envelope = .{ .volume = 3, .start = true, .decay = 0, .divider = 0 };
    envelope.clock(false);
    try testing.expectEqual(@as(u4, 15), envelope.decay);
    try testing.expectEqual(@as(u4, 3), envelope.divider);
    try testing.expect(!envelope.start);
}

test "the decay steps down once every period+1 clocks" {
    var envelope: Envelope = .{ .volume = 2, .start = true };
    envelope.clock(false); // reload: decay 15, divider 2

    // Three clocks to walk the divider 2 -> 1 -> 0 -> reload, one decay step.
    for (0..3) |_| envelope.clock(false);
    try testing.expectEqual(@as(u4, 14), envelope.decay);
    for (0..3) |_| envelope.clock(false);
    try testing.expectEqual(@as(u4, 13), envelope.decay);
}

test "a period of zero steps the decay on every clock" {
    var envelope: Envelope = .{ .volume = 0, .start = true };
    envelope.clock(false);
    envelope.clock(false);
    try testing.expectEqual(@as(u4, 14), envelope.decay);
    envelope.clock(false);
    try testing.expectEqual(@as(u4, 13), envelope.decay);
}

test "the decay stops at zero unless the loop flag brings it back to 15" {
    var envelope: Envelope = .{ .volume = 0, .start = true };
    envelope.clock(false);
    for (0..15) |_| envelope.clock(false);
    try testing.expectEqual(@as(u4, 0), envelope.decay);

    envelope.clock(false);
    try testing.expectEqual(@as(u4, 0), envelope.decay);
    envelope.clock(true);
    try testing.expectEqual(@as(u4, 15), envelope.decay);
}

test "constant volume overrides the decay without freezing it" {
    var envelope: Envelope = .{ .volume = 7, .constant_volume = true, .start = true };
    envelope.clock(false);
    try testing.expectEqual(@as(u4, 7), envelope.output());
    try testing.expectEqual(@as(u4, 15), envelope.decay);

    envelope.constant_volume = false;
    try testing.expectEqual(@as(u4, 15), envelope.output());
}

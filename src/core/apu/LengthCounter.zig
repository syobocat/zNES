// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! The length counter shared by the pulse, triangle and noise channels: a
//! down-counter loaded from a lookup table that silences its channel when it
//! reaches zero, clocked twice per frame sequence.
//!
//! Two timing rules make this more than a counter, and both are observable
//! from software that writes on the exact cycle a clock lands:
//!
//!  - The halt flag is read as of the end of the *previous* CPU cycle
//!    (`halt_delayed`), so a halt written on the clock cycle is too late.
//!  - A load on the clock cycle is dropped outright when the counter is
//!    non-zero, and deferred by one clock when it is zero.

const LengthCounter = @This();

pub const init: LengthCounter = .{};

/// Indexed by the top 5 bits of a $4003/$4007/$400B/$400F write.
// zig fmt: off
const table = [32]u8{
     10, 254,  20,   2,  40,   4,  80,   6,
    160,   8,  60,  10,  14,  12,  26,  14,
     12,  16,  24,  18,  48,  20,  96,  22,
    192,  24,  72,  26,  16,  28,  32,  30,
};
// zig fmt: on

/// $4015's enable bit for this channel. A disabled channel's counter is held
/// at zero and cannot be loaded.
enabled: bool = false,
counter: u8 = 0,

/// Freezes the counter. The same bit doubles as the envelope's loop flag on
/// the pulse and noise channels, and as the linear counter's control flag on
/// the triangle, so the channels read it directly.
halt: bool = false,
/// `halt` as of the end of the previous CPU cycle, which is what `clock`
/// reads. `Apu.tick` refreshes it once per cycle, after that cycle's work but
/// before the CPU gets its turn.
halt_delayed: bool = false,

/// A load that arrived on the clock cycle while the counter was already zero.
/// Held back one clock so the clock still sees the zero it was going to find,
/// rather than decrementing a value that was never really there.
pending_reload: ?u8 = null,

pub fn setEnabled(self: *LengthCounter, enabled: bool) void {
    self.enabled = enabled;
    if (!enabled) self.counter = 0;
}

/// Whether the channel is sounding, i.e. what $4015 reports for it.
pub fn active(self: *const LengthCounter) bool {
    return self.counter > 0;
}

/// Loads from `value`'s top 5 bits. `clock_imminent` means the write landed
/// on the cycle hardware clocks the length on; see `Apu.lengthClockImminent`.
pub fn load(self: *LengthCounter, value: u8, clock_imminent: bool) void {
    if (!clock_imminent) {
        if (self.enabled) self.counter = table[value >> 3];
        return;
    }
    // The clock wins outright over a load that finds a running counter.
    if (self.counter != 0) return;
    self.pending_reload = table[value >> 3];
}

pub fn clock(self: *LengthCounter) void {
    if (self.pending_reload) |value| {
        self.pending_reload = null;
        if (self.enabled) self.counter = value;
        return;
    }
    if (!self.halt_delayed and self.counter > 0) self.counter -= 1;
}

pub fn snapshotHalt(self: *LengthCounter) void {
    self.halt_delayed = self.halt;
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

fn loaded(value: u8) LengthCounter {
    var length: LengthCounter = .{ .enabled = true };
    length.load(value, false);
    return length;
}

test "a load takes the table entry indexed by the top 5 bits" {
    try testing.expectEqual(@as(u8, 10), loaded(0x00).counter);
    try testing.expectEqual(@as(u8, 254), loaded(0x08).counter);
    try testing.expectEqual(@as(u8, 30), loaded(0xF8).counter);
    // The low 3 bits are the timer's high bits and must not reach the table.
    try testing.expectEqual(@as(u8, 10), loaded(0x07).counter);
}

test "a disabled channel cannot be loaded, and loses any count it had" {
    var length = loaded(0x08);
    length.setEnabled(false);
    try testing.expectEqual(@as(u8, 0), length.counter);
    length.load(0x08, false);
    try testing.expectEqual(@as(u8, 0), length.counter);
}

test "the halt flag is read one cycle late, so a halt on the clock cycle is too late" {
    var length = loaded(0x08);
    length.snapshotHalt(); // halt is false as of the previous cycle
    length.halt = true; // written on the clock cycle itself
    length.clock();
    try testing.expectEqual(@as(u8, 253), length.counter);

    // A cycle earlier, and it counts.
    length.snapshotHalt();
    length.clock();
    try testing.expectEqual(@as(u8, 253), length.counter);
}

test "a load on the clock cycle is ignored while the counter is running" {
    var length = loaded(0x08); // 254
    length.load(0xF8, true); // would be 30
    length.clock();
    try testing.expectEqual(@as(u8, 253), length.counter);
    try testing.expectEqual(@as(?u8, null), length.pending_reload);
}

test "a load on the clock cycle takes effect when the counter is zero" {
    var length: LengthCounter = .{ .enabled = true };
    length.load(0xF8, true); // 30
    length.clock(); // sees the zero, so does not decrement
    try testing.expectEqual(@as(u8, 30), length.counter);
}

test "a load just before the clock loads and is then decremented" {
    var length = loaded(0xF8); // 30
    length.clock();
    try testing.expectEqual(@as(u8, 29), length.counter);
}

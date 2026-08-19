//! Standard NES controller: the 8-bit parallel-in/serial-out shift register
//! behind $4016 (player 1) and $4017 (player 2).
//!
//! While the strobe line is high the register is continuously reloaded from
//! the buttons; while it is low each read clocks one bit out, low bit first,
//! and reads past the eighth return 1. Two details of *when* those happen are
//! visible to software and are modeled here:
//!
//!  - The strobe is level-sensitive and only sampled on put cycles, so a
//!    pulse that never spans one never reloads (`latchIfStrobing`).
//!  - The CPU's output-enable line stays asserted across adjacent cycles that
//!    read the same register, so a contiguous run of reads clocks the register
//!    once, not once per read (`read`).

const Controller = @This();

pub const Button = enum(u3) {
    a = 0,
    b = 1,
    select = 2,
    start = 3,
    up = 4,
    down = 5,
    left = 6,
    right = 7,
};

pub const init: Controller = .{};

/// Physical button state, one bit per `Button`, 1 = pressed.
buttons: u8 = 0,
/// The shift register's contents, low bit first out.
shift: u8 = 0,
/// The strobe line's level, as last written to $4016 bit 0.
strobe: bool = false,

/// The CPU cycle of the previous read, or null if this controller has never
/// been read. Used to tell a continued run of reads from a new one.
last_read_cycle: ?u64 = null,
/// Whether the current run of reads has earned a clock that has not been
/// applied yet. Deferring it is what makes every read in a run return the
/// same bit; see `read`.
shift_owed: bool = false,

pub fn setButton(self: *Controller, button: Button, pressed: bool) void {
    const mask = @as(u8, 1) << @intFromEnum(button);
    if (pressed) self.buttons |= mask else self.buttons &= ~mask;
}

/// Replaces every button at once with a mask in `Button` order, bit 0 being
/// A. A frontend reading a whole pad per frame has all eight bits in hand
/// already, and setting them one at a time only invites the order to be got
/// wrong somewhere along the way.
pub fn setButtons(self: *Controller, mask: u8) void {
    self.buttons = mask;
}

/// Records $4016 bit 0. Only the level is stored -- the reload it causes
/// happens on put cycles for as long as the level stays high, not at the
/// moment of the write.
pub fn writeStrobe(self: *Controller, value: u8) void {
    self.strobe = (value & 1) != 0;
}

/// Reloads the shift register if the strobe line is high. `Nes.stepCycle`
/// calls this at the end of every put cycle.
///
/// Sampling on put cycles only is observable whenever software drives the
/// line high for a single cycle: a read-modify-write such as `DEC $4016`
/// writes the un-decremented byte back (bit 0 set) and then the decremented
/// one (bit 0 clear), so whether the controller latches depends on which
/// cycle parity that one-cycle pulse landed on.
pub fn latchIfStrobing(self: *Controller) void {
    if (self.strobe) self.reload();
}

fn reload(self: *Controller) void {
    self.shift = self.buttons;
    self.shift_owed = false;
}

/// Reads the register onto the CPU data bus. Bit 0 is the shift register's
/// output; bits 1-4 are driven low by the controller itself; bits 5-7 are not
/// driven at all and come from `open_bus`.
///
/// `cycle` decides whether this read continues the previous one. The CPU
/// holds the output enable asserted for a whole cycle and across adjacent
/// cycles reading the same register, so the controller sees one read per
/// contiguous run and clocks once for it. That is what keeps a DMC DMA -- it
/// freezes the CPU mid-`LDA $4016` and makes it re-read the same address on
/// the halt, dummy and alignment cycles -- from eating bits of the report.
///
/// This is the NES-001 and AV Famicom behavior. The RF Famicom, Twin Famicom
/// and Famicom Titler gate the output enable per half-cycle and do clock on
/// every read cycle instead.
pub fn read(self: *Controller, open_bus: u8, cycle: u64) u8 {
    if (self.strobe) self.reload();

    const continues_run = if (self.last_read_cycle) |previous| cycle == previous +% 1 else false;
    self.last_read_cycle = cycle;

    // A run's clock is spent when the *next* run begins rather than when this
    // one ends, which is what makes every read within a run return the same
    // bit -- including the two halves of a double-read instruction such as
    // `SLO abs,X`.
    if (!continues_run and self.shift_owed) {
        self.shift = (self.shift >> 1) | 0x80;
        self.shift_owed = false;
    }
    if (!self.strobe and !continues_run) self.shift_owed = true;

    return (open_bus & 0xE0) | (self.shift & 1);
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// Hands out cycle numbers two apart, so consecutive calls are never mistaken
/// for one contiguous run of reads. The rule that makes them distinct has its
/// own tests below, which pass explicit cycle numbers.
var test_cycle: u64 = 0;
fn nextCycle() u64 {
    test_cycle += 2;
    return test_cycle;
}

/// Strobe high, one put cycle, strobe low: the standard way software latches
/// the buttons before shifting them out.
fn latchedController(buttons: []const Button) Controller {
    var c: Controller = .init;
    for (buttons) |b| c.setButton(b, true);
    c.writeStrobe(1);
    c.latchIfStrobing();
    c.writeStrobe(0);
    return c;
}

test "setButtons is setButton eight times over" {
    var one_at_a_time: Controller = .init;
    for ([_]Button{ .a, .select, .up, .right }) |b| one_at_a_time.setButton(b, true);

    var all_at_once: Controller = .init;
    all_at_once.setButtons(0b1001_0101);

    try testing.expectEqual(one_at_a_time.buttons, all_at_once.buttons);
}

test "strobe continuously reloads bit 0 from button A" {
    var c: Controller = .init;
    c.setButton(.a, true);
    c.writeStrobe(1);
    try testing.expectEqual(@as(u8, 1), c.read(0, nextCycle()) & 1);
    try testing.expectEqual(@as(u8, 1), c.read(0, nextCycle()) & 1);
    c.setButton(.a, false);
    try testing.expectEqual(@as(u8, 0), c.read(0, nextCycle()) & 1);
}

test "reading 8 times shifts out all buttons, then returns 1" {
    var c = latchedController(&.{ .a, .b, .select, .start });

    const expected = [_]u8{ 1, 1, 1, 1, 0, 0, 0, 0 };
    for (expected) |bit| {
        try testing.expectEqual(bit, c.read(0, nextCycle()) & 1);
    }
    // Past the eighth read the register shifts in 1s.
    try testing.expectEqual(@as(u8, 1), c.read(0, nextCycle()) & 1);
    try testing.expectEqual(@as(u8, 1), c.read(0, nextCycle()) & 1);
}

test "a strobe pulse that never spans a put cycle doesn't latch" {
    var c: Controller = .init;
    c.setButton(.a, true);
    // What `DEC $4016` does when its dummy write lands on a get cycle: the
    // line goes high and low again with no put cycle in between.
    c.writeStrobe(1);
    c.writeStrobe(0);
    try testing.expectEqual(@as(u8, 0), c.read(0, nextCycle()) & 1);
}

test "read forces bits 1-4 low and only lets bits 5-7 float as open bus" {
    var c: Controller = .init;
    c.setButton(.a, true);
    c.writeStrobe(1);
    try testing.expectEqual(@as(u8, 0b1110_0001), c.read(0b1111_1010, nextCycle()));
}

test "reads on adjacent cycles are one clock, and all return the same bit" {
    var c = latchedController(&.{.a}); // bit 0 set, everything above it clear

    try testing.expectEqual(@as(u8, 1), c.read(0, 100) & 1);
    try testing.expectEqual(@as(u8, 1), c.read(0, 101) & 1);
    try testing.expectEqual(@as(u8, 1), c.read(0, 102) & 1);

    // A new run, so it -- and only it -- pays the clock.
    try testing.expectEqual(@as(u8, 0), c.read(0, 110) & 1);
}

test "a run of reads costs exactly one shift, however long it is" {
    var c = latchedController(&.{ .a, .b });

    for (0..5) |i| _ = c.read(0, 200 + i);
    // The second run sees bit 1, not bit 5.
    try testing.expectEqual(@as(u8, 1), c.read(0, 300) & 1);
    // And the third sees bit 2, which is clear.
    try testing.expectEqual(@as(u8, 0), c.read(0, 400) & 1);
}

test "strobing during a run reloads and cancels the pending clock" {
    var c = latchedController(&.{.a});

    _ = c.read(0, 500); // consumes bit 0, owes a shift
    c.writeStrobe(1);
    c.latchIfStrobing(); // reload; the owed shift is moot
    c.writeStrobe(0);
    try testing.expectEqual(@as(u8, 1), c.read(0, 600) & 1);
}

test "the first read of a run is never mistaken for a continuation" {
    // A read at cycle 0 must not look like the continuation of an imaginary
    // read at cycle maxInt.
    var c = latchedController(&.{.b}); // bit 0 clear, bit 1 set
    try testing.expectEqual(@as(u8, 0), c.read(0, 0) & 1);
    try testing.expectEqual(@as(u8, 1), c.read(0, 10) & 1);
}

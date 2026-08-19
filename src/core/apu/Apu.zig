//! RP2A03 APU: two pulse channels, a triangle, a noise channel, the DMC, the
//! frame sequencer that clocks their envelopes/sweeps/length counters, and the
//! non-linear mixer.
//!
//! `tick` runs once per CPU cycle, matching every other component. The frame
//! sequencer and the triangle's timer clock every CPU cycle; the pulse, noise
//! and DMC timers clock every other one -- the classic "APU cycle" -- which
//! `cycle_parity` tracks.
//!
//! The frame sequencer's step boundaries are quoted below in CPU cycles rather
//! than APU cycles, because several of them fall on a half APU cycle and the
//! IRQ window's three cycles are only expressible at CPU resolution.

const std = @import("std");
const Apu = @This();
const Nes = @import("../Nes.zig");
const Pulse = @import("Pulse.zig");
const Triangle = @import("Triangle.zig");
const Noise = @import("Noise.zig");
const Dmc = @import("Dmc.zig");
const LengthCounter = @import("LengthCounter.zig");

pub const FrameMode = enum { four_step, five_step };

/// NTSC CPU clock, which is also the rate `mixSample` is evaluated at.
const cpu_hz: f32 = 1_789_773.0;

/// One-pole coefficient for a high-pass at `fc`, sampled at `cpu_hz`.
fn highPassCoeff(comptime fc: f32) f32 {
    return cpu_hz / (cpu_hz + 2.0 * std.math.pi * fc);
}

/// One-pole coefficient for a low-pass at `fc`, sampled at `cpu_hz`.
fn lowPassCoeff(comptime fc: f32) f32 {
    const w = 2.0 * std.math.pi * fc;
    return w / (cpu_hz + w);
}

/// What the console does to the mixer's output before it reaches the jack,
/// plus the downsample to the host's rate.
///
/// The DACs are followed by three filters: high-pass at 90 Hz, high-pass at
/// 440 Hz, and low-pass at 14 kHz. The high-pass pair is what removes the DC
/// the non-linear mixer sits on -- `mixSample` never returns a negative
/// number -- so without them every start and stop of playback is a click.
///
/// **The decimator matters as much as the filters.** Taking whichever sample
/// happens to be current at each output tick, roughly 1 in 40 at 44.1 kHz,
/// aliases everything above the output Nyquist straight back into the audible
/// band. Averaging every CPU cycle since the previous output sample is a box
/// filter: crude as anti-aliasing goes, but it costs one add and removes the
/// worst of it. It also reproduces the triangle's ultrasonic mode correctly,
/// where hardware emits a steady mid-level that averaging yields exactly.
const AudioOut = struct {
    /// Per high-pass stage: `y = a * (y_prev + x - x_prev)`.
    hp90_x: f32 = 0,
    hp90_y: f32 = 0,
    hp440_x: f32 = 0,
    hp440_y: f32 = 0,
    /// Low-pass: `y += b * (x - y)`.
    lp_y: f32 = 0,

    sum: f32 = 0,
    count: u32 = 0,

    const hp90_a = highPassCoeff(90.0);
    const hp440_a = highPassCoeff(440.0);
    const lp_b = lowPassCoeff(14_000.0);

    fn push(self: *AudioOut, raw: f32) void {
        const hp90 = hp90_a * (self.hp90_y + raw - self.hp90_x);
        self.hp90_x = raw;
        self.hp90_y = hp90;

        const hp440 = hp440_a * (self.hp440_y + hp90 - self.hp440_x);
        self.hp440_x = hp90;
        self.hp440_y = hp440;

        self.lp_y += lp_b * (hp440 - self.lp_y);

        self.sum += self.lp_y;
        self.count += 1;
    }

    /// The mean of every filtered cycle since the last call.
    fn take(self: *AudioOut) f32 {
        if (self.count == 0) return self.lp_y;
        const avg = self.sum / @as(f32, @floatFromInt(self.count));
        self.sum = 0;
        self.count = 0;
        return avg;
    }
};

pub const init: Apu = .{};

pulse1: Pulse = Pulse.init(.one),
pulse2: Pulse = Pulse.init(.two),
triangle: Triangle = .init,
noise: Noise = .init,
dmc: Dmc = .init,

/// The frame IRQ flag as $4015 reports it.
frame_irq: bool = false,
frame_mode: FrameMode = .four_step,
frame_irq_inhibit: bool = false,
/// Set by a $4015 read, consumed by `tick` at the end of the next get cycle.
frame_irq_clear_pending: bool = false,
/// The IRQ line as the CPU sees it. Tracks `frame_irq` except for the first
/// cycle of the assertion window, where the flag is already up but the line
/// has not dropped yet.
frame_irq_line: bool = false,
frame_cycle: u16 = 0,
cycle_parity: bool = false,

/// A $4017 write does not reset the sequencer immediately: the reset lands on
/// a fixed phase 3 or 4 CPU cycles later, depending on which half of an APU
/// cycle the write itself fell on.
pending_frame_mode: ?FrameMode = null,
pending_frame_irq_inhibit: bool = false,
frame_reset_delay: u3 = 0,
/// The last byte written to $4017, replayed by `reset`. At power-on this is 0,
/// which is also what hardware behaves as if had been written.
last_frame_counter_write: u8 = 0,

/// Output filtering and downsampling; see `AudioOut`.
audio: AudioOut = .{},

/// The five channel outputs `mix_value` was computed from. `mixSample`'s two
/// divisions are far too expensive to repeat every CPU cycle, and its inputs
/// only change when a channel's timer or envelope does, which is orders of
/// magnitude rarer.
mix_key: u32 = std.math.maxInt(u32),
mix_value: f32 = 0,

pub fn powerOn(self: *Apu) void {
    self.* = .init;
}

/// Reset is not power-on: most of the APU keeps running with whatever it had.
/// What changes is that every channel is disabled, the IRQ flags clear, the
/// triangle's phase returns to 0 and the DMC's output level keeps only its low
/// bit -- and the last value written to $4017 is written again.
///
/// That re-write is what restarts the frame sequencer. Without it the sequencer
/// free-runs across the reset, and every measurement of when the frame IRQ
/// arrives afterwards is wrong.
pub fn reset(self: *Apu, nes: *Nes) void {
    self.pulse1.length.setEnabled(false);
    self.pulse2.length.setEnabled(false);
    self.triangle.length.setEnabled(false);
    self.noise.length.setEnabled(false);
    self.dmc.setEnabled(false, nes.total_cycles);

    self.frame_irq = false;
    self.frame_irq_line = false;
    self.frame_irq_clear_pending = false;
    self.dmc.irq_flag = false;

    self.triangle.step = 0;
    self.dmc.output_level &= 1;

    self.writeFrameCounter(nes, self.last_frame_counter_write);
}

pub fn tick(self: *Apu, nes: *Nes) void {
    // A pending $4015-read clear takes effect once the get cycle it was
    // scheduled for is over, i.e. at the start of the following put.
    if (self.frame_irq_clear_pending and nes.total_cycles % 2 == 0) {
        self.frame_irq = false;
        self.frame_irq_line = false;
        self.frame_irq_clear_pending = false;
    }
    if (self.pending_frame_mode) |mode| {
        // Decrement before checking, not after: `frame_reset_delay` is set
        // during the write's own cycle and this function is not called again
        // until the next one, so checking first would land the reset a cycle
        // late.
        self.frame_reset_delay -= 1;
        if (self.frame_reset_delay == 0) {
            self.frame_mode = mode;
            self.frame_irq_inhibit = self.pending_frame_irq_inhibit;
            self.frame_cycle = 0;
            self.pending_frame_mode = null;
        }
    }

    self.tickFrameCounter();
    self.triangle.tickTimer();
    if (self.cycle_parity) {
        self.pulse1.tickTimer();
        self.pulse2.tickTimer();
        self.noise.tickTimer();
        self.dmc.tickTimer(nes.total_cycles);
    }
    self.cycle_parity = !self.cycle_parity;

    // Snapshot the halt flags after this tick's work but before the CPU gets
    // its cycle. That one-cycle lag is what makes a halt written on the cycle
    // a length clock lands on arrive too late, while one written a cycle
    // earlier still counts.
    for (self.lengthCounters()) |length| length.snapshotHalt();

    self.audio.push(self.cachedMixSample());
}

/// The four length counters, in $4015 bit order.
fn lengthCounters(self: *Apu) [4]*LengthCounter {
    return .{ &self.pulse1.length, &self.pulse2.length, &self.triangle.length, &self.noise.length };
}

/// `mixSample`, memoized on the channel outputs that feed it.
fn cachedMixSample(self: *Apu) f32 {
    const key = (@as(u32, self.pulse1.output()) << 0) |
        (@as(u32, self.pulse2.output()) << 4) |
        (@as(u32, self.triangle.output()) << 8) |
        (@as(u32, self.noise.output()) << 12) |
        (@as(u32, self.dmc.output()) << 16);
    if (key != self.mix_key) {
        self.mix_key = key;
        self.mix_value = self.mixSample();
    }
    return self.mix_value;
}

/// One output sample: everything the mixer produced since the previous call,
/// filtered and averaged. See `AudioOut`.
pub fn takeSample(self: *Apu) f32 {
    return self.audio.take();
}

fn clockQuarterFrame(self: *Apu) void {
    self.pulse1.clockEnvelope();
    self.pulse2.clockEnvelope();
    self.noise.clockEnvelope();
    self.triangle.clockLinearCounter();
}

fn clockHalfFrame(self: *Apu) void {
    for (self.lengthCounters()) |length| length.clock();
    self.pulse1.clockSweep();
    self.pulse2.clockSweep();
}

/// The CPU cycles at which the frame counter clocks the length counters, by
/// mode. Mode 0's second half-frame closes its sequence; mode 1's lands much
/// later, which is the whole difference between the two.
fn halfFrameCycles(mode: FrameMode) [2]u16 {
    return switch (mode) {
        .four_step => .{ 14913, 29829 },
        .five_step => .{ 14913, 37281 },
    };
}

/// Whether the *next* CPU cycle's tick will clock the length counters.
///
/// A CPU write completes at the end of its cycle, but this APU is ticked
/// before the CPU inside each `Nes.stepCycle`, so a write landing on cycle N
/// is only visible from tick N+1 onward. Hardware's length clock sits at the
/// *end* of a cycle: after that cycle's read, but simultaneous with -- and
/// winning over -- that cycle's write. Reads therefore already line up; writes
/// need this one-cycle look-ahead to tell "just before the clock" from
/// "during it".
fn lengthClockImminent(self: *const Apu) bool {
    // A $4017 reset landing next tick restarts the count instead of advancing
    // it, and can change the mode at the same time.
    const resetting_next = self.pending_frame_mode != null and self.frame_reset_delay == 1;
    const mode = if (resetting_next) self.pending_frame_mode.? else self.frame_mode;
    const next: u16 = if (resetting_next) 1 else self.frame_cycle +% 1;
    const targets = halfFrameCycles(mode);
    return next == targets[0] or next == targets[1];
}

/// One CPU cycle of the frame sequencer.
///
/// In four-step mode the frame IRQ is asserted as a *level* across the last
/// three cycles of the sequence rather than being set once, so a $4015 read
/// inside that window clears the flag only for it to be driven straight back
/// up on the next cycle. The three cycles are not identical:
///
///  - 29828 raises the readable flag only. The line the CPU samples stays high
///    for one more cycle.
///  - 29829 raises both, and is where the quarter and half clocks land -- one
///    cycle into the window, not on its first cycle.
///  - 29830 raises both and wraps the sequence, making it 29830 CPU cycles
///    (14915 APU cycles) long.
///
/// The inhibit bit gates the readable flag only on that last cycle, while it
/// gates the IRQ line throughout (see `irqLine`). Software with the frame IRQ
/// suppressed can therefore still observe the flag through $4015 for two
/// cycles without ever taking an interrupt.
fn tickFrameCounter(self: *Apu) void {
    self.frame_cycle += 1;
    switch (self.frame_mode) {
        .four_step => switch (self.frame_cycle) {
            7457, 22371 => self.clockQuarterFrame(),
            14913 => {
                self.clockQuarterFrame();
                self.clockHalfFrame();
            },
            29828 => self.frame_irq = true,
            29829 => {
                self.clockQuarterFrame();
                self.clockHalfFrame();
                self.frame_irq = true;
                self.frame_irq_line = !self.frame_irq_inhibit;
            },
            29830 => {
                self.frame_irq = !self.frame_irq_inhibit;
                self.frame_irq_line = !self.frame_irq_inhibit;
                self.frame_cycle = 0;
            },
            else => {},
        },
        .five_step => switch (self.frame_cycle) {
            7457, 22371 => self.clockQuarterFrame(),
            14913 => {
                self.clockQuarterFrame();
                self.clockHalfFrame();
            },
            // The last step's clocks land on APU cycle 18640.5, but the
            // counter does not wrap until APU 18641 -- one sequence is 37282
            // CPU cycles, not 37281. Wrapping on the same cycle as the clocks
            // would make every subsequent half-frame arrive a cycle early.
            37281 => {
                self.clockQuarterFrame();
                self.clockHalfFrame();
            },
            37282 => self.frame_cycle = 0,
            else => {},
        },
    }
}

fn writeFrameCounter(self: *Apu, nes: *Nes, value: u8) void {
    self.last_frame_counter_write = value;
    const mode: FrameMode = if ((value & 0x80) != 0) .five_step else .four_step;
    const inhibit = (value & 0x40) != 0;
    if (inhibit) {
        self.frame_irq = false;
        self.frame_irq_line = false;
    }
    self.pending_frame_mode = mode;
    self.pending_frame_irq_inhibit = inhibit;
    // The reset lands on a fixed phase, so how many CPU cycles away that is
    // depends on which half of an APU cycle the write fell on. The counts here
    // are one higher than the delay itself because `tick` decrements before
    // checking.
    self.frame_reset_delay = if (nes.total_cycles % 2 == 0) 5 else 4;
    // Switching to five-step mode clocks everything immediately, on top of
    // resetting the sequence.
    if (mode == .five_step) {
        self.clockQuarterFrame();
        self.clockHalfFrame();
    }
}

/// The IRQ line the APU drives to the CPU. Distinct from the readable
/// `frame_irq` flag: the inhibit bit gates the line at all times, but leaves a
/// two-cycle window where the flag itself is set.
pub fn irqLine(self: *const Apu) bool {
    return self.frame_irq_line and !self.frame_irq_inhibit;
}

/// $4015. Every other APU register is write-only, so the bus handles them.
pub fn readStatus(self: *Apu, nes: *Nes) u8 {
    // Bit 5 is the one bit of $4015 the APU never drives, so it falls through
    // from whatever the 2A03's *internal* data bus last held -- not the
    // external one.
    var value: u8 = nes.internal_bus & 0x20;
    if (self.pulse1.length.active()) value |= 0x01;
    if (self.pulse2.length.active()) value |= 0x02;
    if (self.triangle.length.active()) value |= 0x04;
    if (self.noise.length.active()) value |= 0x08;
    if (self.dmc.isPlaying()) value |= 0x10;
    if (self.frame_irq) value |= 0x40;
    if (self.dmc.irq_flag) value |= 0x80;

    // Reading $4015 does not drop the frame IRQ flag on the spot: the clear is
    // latched here and lands on the next get cycle. A read that happens *on* a
    // get therefore hands back the old value and clears right after, while a
    // read on a put leaves the flag standing one more cycle -- long enough
    // that a double-read instruction sees it set twice.
    self.frame_irq_clear_pending = true;
    return value;
}

pub fn writeRegister(self: *Apu, nes: *Nes, addr: u16, value: u8) void {
    const imminent = self.lengthClockImminent();
    switch (addr) {
        0x4000 => self.pulse1.writeControl(value),
        0x4001 => self.pulse1.writeSweep(value),
        0x4002 => self.pulse1.writeTimerLow(value),
        0x4003 => self.pulse1.writeTimerHighAndLength(value, imminent),
        0x4004 => self.pulse2.writeControl(value),
        0x4005 => self.pulse2.writeSweep(value),
        0x4006 => self.pulse2.writeTimerLow(value),
        0x4007 => self.pulse2.writeTimerHighAndLength(value, imminent),
        0x4008 => self.triangle.writeControl(value),
        0x400A => self.triangle.writeTimerLow(value),
        0x400B => self.triangle.writeTimerHighAndLength(value, imminent),
        0x400C => self.noise.writeControl(value),
        0x400E => self.noise.writePeriod(value),
        0x400F => self.noise.writeLength(value, imminent),
        0x4010 => self.dmc.writeControl(value),
        0x4011 => self.dmc.writeDirectLoad(value),
        0x4012 => self.dmc.writeSampleAddr(value),
        0x4013 => self.dmc.writeSampleLength(value),
        0x4015 => {
            for (self.lengthCounters(), 0..) |length, i| {
                length.setEnabled((value & (@as(u8, 1) << @intCast(i))) != 0);
            }
            self.dmc.irq_flag = false;
            self.dmc.setEnabled((value & 0x10) != 0, nes.total_cycles);
        },
        0x4017 => self.writeFrameCounter(nes, value),
        else => {},
    }
}

/// The console's non-linear mixer, returning a sample in roughly [0, 1]. Two
/// separate summing networks -- the pulses share one, the triangle, noise and
/// DMC the other -- which is why raising one channel's volume can lower
/// another's contribution.
pub fn mixSample(self: *const Apu) f32 {
    const p1: f32 = @floatFromInt(self.pulse1.output());
    const p2: f32 = @floatFromInt(self.pulse2.output());
    const t: f32 = @floatFromInt(self.triangle.output());
    const n: f32 = @floatFromInt(self.noise.output());
    const d: f32 = @floatFromInt(self.dmc.output());

    const pulse_sum = p1 + p2;
    const pulse_out: f32 = if (pulse_sum == 0) 0 else 95.88 / (8128.0 / pulse_sum + 100.0);

    const tnd_sum = t / 8227.0 + n / 12241.0 + d / 22638.0;
    const tnd_out: f32 = if (tnd_sum == 0) 0 else 159.79 / (1.0 / tnd_sum + 100.0);

    return pulse_out + tnd_out;
}

// --- Tests ---------------------------------------------------------------

const testing = std.testing;
const Cartridge = @import("../cart/Cartridge.zig");

/// A blank 16 KiB NROM image. `Cartridge` aliases these bytes.
const blank_rom: [16 + 16 * 1024]u8 = blk: {
    var bytes: [16 + 16 * 1024]u8 = @splat(0);
    bytes[0..4].* = .{ 'N', 'E', 'S', 0x1A };
    bytes[4] = 1;
    break :blk bytes;
};

/// An APU positioned so that its next `cycles_before + 1` ticks end on the
/// four-step sequence's second length clock, with pulse 1 loaded and sounding.
fn apuAtLengthClock(cycles_before: u16) Apu {
    var apu: Apu = .init;
    apu.pulse1.length.enabled = true;
    apu.pulse1.length.load(0x08, false); // 254
    apu.frame_cycle = halfFrameCycles(.four_step)[1] - 1 - cycles_before;
    return apu;
}

test "the output stage removes the mixer's DC offset" {
    // The mixer never returns a negative number, so a constant tone would sit
    // on a large DC pedestal without the high-pass pair -- audible as a click
    // at every start and stop.
    var out: AudioOut = .{};
    for (0..200_000) |_| out.push(0.25);
    try testing.expectApproxEqAbs(@as(f32, 0), out.take(), 0.01);
}

test "the output stage passes audible content through" {
    // A 1 kHz tone sits inside the 440 Hz - 14 kHz passband, so most of its
    // amplitude has to survive.
    var out: AudioOut = .{};
    var peak: f32 = 0;
    for (0..20_000) |i| {
        const t = @as(f32, @floatFromInt(i)) / cpu_hz;
        out.push(0.25 + 0.25 * @sin(2.0 * std.math.pi * 1000.0 * t));
        if (i > 10_000) peak = @max(peak, @abs(out.lp_y));
    }
    try testing.expect(peak > 0.2);
}

test "decimation averages every cycle instead of sampling one of them" {
    // Sampling would return whichever value happened to be current; averaging
    // returns the mean, which is what suppresses aliasing.
    var out: AudioOut = .{};
    out.lp_y = 0;
    out.sum = 3.0;
    out.count = 4;
    try testing.expectApproxEqAbs(@as(f32, 0.75), out.take(), 1e-6);
    // With nothing pushed since, the last filtered value stands in.
    out.lp_y = 0.5;
    try testing.expectApproxEqAbs(@as(f32, 0.5), out.take(), 1e-6);
}

test "a halt written on the clock cycle is too late; one cycle earlier is not" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);

    // On the clock cycle itself the halt has not been snapshotted yet, so the
    // counter still decrements.
    nes.apu = apuAtLengthClock(0);
    nes.apu.pulse1.length.halt = true;
    nes.apu.tick(&nes);
    try testing.expectEqual(@as(u8, 253), nes.apu.pulse1.length.counter);

    // A cycle earlier and the snapshot at the end of that cycle catches it.
    nes.apu = apuAtLengthClock(1);
    nes.apu.pulse1.length.halt = true;
    nes.apu.tick(&nes); // the cycle before, which snapshots the halt
    nes.apu.tick(&nes); // the clock cycle
    try testing.expectEqual(@as(u8, 254), nes.apu.pulse1.length.counter);
}

test "an unhalt written on the clock cycle is too late to restart counting" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);

    nes.apu = apuAtLengthClock(0);
    nes.apu.pulse1.length.halt = false;
    nes.apu.pulse1.length.halt_delayed = true;
    nes.apu.tick(&nes);
    try testing.expectEqual(@as(u8, 254), nes.apu.pulse1.length.counter);
}

test "a length reload on the clock cycle is ignored when the counter is non-zero" {
    var apu = apuAtLengthClock(0);
    apu.pulse1.length.load(0xF8, true); // would be 30
    apu.clockHalfFrame();
    try testing.expectEqual(@as(u8, 253), apu.pulse1.length.counter);
}

test "a length reload on the clock cycle takes when the counter is zero" {
    var apu = apuAtLengthClock(0);
    apu.pulse1.length.counter = 0;
    apu.pulse1.length.load(0xF8, true); // 30
    apu.clockHalfFrame();
    try testing.expectEqual(@as(u8, 30), apu.pulse1.length.counter);
}

test "a length reload just before the clock loads and is then decremented" {
    var apu = apuAtLengthClock(1);
    apu.pulse1.length.load(0xF8, false); // 30
    apu.clockHalfFrame();
    try testing.expectEqual(@as(u8, 29), apu.pulse1.length.counter);
}

test "lengthClockImminent sees exactly the cycle before each half-frame clock" {
    for ([_]FrameMode{ .four_step, .five_step }) |mode| {
        var apu: Apu = .init;
        apu.frame_mode = mode;
        for (halfFrameCycles(mode)) |target| {
            apu.frame_cycle = target - 1;
            try testing.expect(apu.lengthClockImminent());
            apu.frame_cycle = target;
            try testing.expect(!apu.lengthClockImminent());
            apu.frame_cycle = target - 2;
            try testing.expect(!apu.lengthClockImminent());
        }
    }
}

test "$4015 reports which channels are sounding, and reads bit 5 off the internal bus" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);

    nes.apu = .init;
    nes.apu.pulse2.length.enabled = true;
    nes.apu.pulse2.length.counter = 5;
    nes.apu.noise.length.enabled = true;
    nes.apu.noise.length.counter = 1;
    nes.internal_bus = 0xFF;

    const value = nes.apu.readStatus(&nes);
    try testing.expectEqual(@as(u8, 0x02 | 0x08 | 0x20), value);
    // The read arms the frame IRQ clear rather than performing it.
    try testing.expect(nes.apu.frame_irq_clear_pending);
}

test "the four-step sequence holds the IRQ line for three cycles and is 29830 long" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);
    nes.apu = .init;

    nes.apu.frame_cycle = 29827;
    nes.apu.tick(&nes); // 29828: flag only
    try testing.expect(nes.apu.frame_irq);
    try testing.expect(!nes.apu.irqLine());

    nes.apu.tick(&nes); // 29829: line too
    try testing.expect(nes.apu.irqLine());

    nes.apu.tick(&nes); // 29830: wraps
    try testing.expect(nes.apu.irqLine());
    try testing.expectEqual(@as(u16, 0), nes.apu.frame_cycle);
}

test "the inhibit bit gates the IRQ line at all times but the flag only at the wrap" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);
    nes.apu = .init;
    nes.apu.frame_irq_inhibit = true;
    nes.apu.frame_cycle = 29827;

    nes.apu.tick(&nes); // 29828
    try testing.expect(nes.apu.frame_irq); // readable...
    try testing.expect(!nes.apu.irqLine()); // ...but no interrupt
    nes.apu.tick(&nes); // 29829
    try testing.expect(nes.apu.frame_irq);
    try testing.expect(!nes.apu.irqLine());
    nes.apu.tick(&nes); // 29830: the inhibit finally clears the flag too
    try testing.expect(!nes.apu.frame_irq);
}

test "switching to five-step mode clocks everything immediately" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);
    nes.apu = .init;
    nes.apu.pulse1.length.enabled = true;
    nes.apu.pulse1.length.load(0x08, false); // 254

    nes.apu.writeRegister(&nes, 0x4017, 0x80);
    try testing.expectEqual(@as(u8, 253), nes.apu.pulse1.length.counter);

    // Four-step mode does not.
    nes.apu.writeRegister(&nes, 0x4017, 0x00);
    try testing.expectEqual(@as(u8, 253), nes.apu.pulse1.length.counter);
}

test "the mixer is non-linear: two pulses at the same level are less than twice one" {
    var apu: Apu = .init;
    apu.pulse1.length.enabled = true;
    apu.pulse1.length.counter = 1;
    apu.pulse1.writeControl(0x1F); // constant volume 15
    apu.pulse1.timer_period = 100;
    apu.pulse1.duty_step = 1;

    const one = apu.mixSample();
    apu.pulse2 = apu.pulse1;
    apu.pulse2.channel = .two;
    const two = apu.mixSample();

    try testing.expect(two > one);
    try testing.expect(two < 2 * one);
}

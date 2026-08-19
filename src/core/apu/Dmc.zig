//! Delta modulation channel: streams 1-bit delta-encoded samples out of
//! cartridge PRG space, moving a 7-bit output level by +/-2 per bit.
//!
//! Sample bytes arrive by cycle-stealing DMA rather than by reading the bus
//! directly. This channel only *requests* a fetch, by raising `dma_pending`
//! where `Nes.stepCycle` will see it, and receives the byte later through
//! `completeDmaFetch`. That indirection is what makes the DMA visible to the
//! rest of the system as stolen CPU cycles.

const Dmc = @This();

/// What kind of reload DMA the sample buffer emptying scheduled, in the case
/// where playback had already stopped by then. See `classifyReload`.
pub const Reload = enum { none, full, single_cycle };

/// Sample rates as full periods in **CPU cycles**, so `tickTimer` halves them
/// to run at its own APU-cycle cadence.
const rate_table = [16]u16{
    428, 380, 340, 320, 286, 254, 226, 214,
    190, 160, 142, 128, 106, 84,  72,  54,
};

irq_enabled: bool = false,
loop: bool = false,
rate: u16 = rate_table[0],
timer: u16 = 0,

output_level: u7 = 0,

sample_addr: u16 = 0xC000,
sample_length: u16 = 1,
current_addr: u16 = 0xC000,
bytes_remaining: u16 = 0,

sample_buffer: u8 = 0,
sample_buffer_filled: bool = false,
/// Set once a DMA fetch has been requested, so `Nes.stepCycle` does not
/// request another before the first completes.
dma_pending: bool = false,

pending_reload: Reload = .none,
/// The CPU cycle playback last stopped on, and whether it has stopped since
/// the last start. Both feed `classifyReload`.
stopped_at: u64 = 0,
playback_stopped: bool = false,
/// CPU cycles left before a freshly started sample's first fetch may be
/// requested; see `setEnabled`.
dma_startup_delay: u16 = 0,

shift_register: u8 = 0,
bits_remaining: u3 = 0,
silent: bool = true,

irq_flag: bool = false,

pub const init: Dmc = .{};

/// Whether the channel is sounding, i.e. what $4015 bit 4 reports.
pub fn isPlaying(self: *const Dmc) bool {
    return self.bytes_remaining > 0;
}

/// Whether the channel wants a sample byte right now: buffer empty, more bytes
/// to come, no fetch already in flight, and past the startup latency of a
/// freshly started sample.
pub fn needsDma(self: *const Dmc) bool {
    if (self.dma_pending or self.sample_buffer_filled or self.dma_startup_delay != 0) return false;
    return self.bytes_remaining > 0 or self.pending_reload != .none;
}

/// Decides what happens when the sample buffer empties -- the instant a reload
/// DMA would be scheduled -- if playback has already stopped.
///
/// The obvious answer, nothing, is only right when playback stopped a while
/// ago. Stopping it close to this instant leaves the DMA unit half-committed,
/// so with `d` the CPU cycles from the stop to this scheduling point:
///
///  - `d <= 1`: the stop landed in the *same* APU cycle as the scheduling
///    point, which is too late to matter. A completely normal reload runs.
///  - `d` of 2 or 3: the APU cycle immediately before. The DMA starts and is
///    aborted after its single halt cycle, stealing one CPU cycle and
///    fetching nothing.
///  - `d >= 4`: stopped early enough that nothing is scheduled at all.
fn classifyReload(self: *const Dmc, cycle: u64) Reload {
    if (self.bytes_remaining > 0 or !self.playback_stopped) return .none;
    return switch (cycle -% self.stopped_at) {
        0, 1 => .full,
        2, 3 => .single_cycle,
        else => .none,
    };
}

fn stopPlayback(self: *Dmc, cycle: u64) void {
    self.bytes_remaining = 0;
    self.stopped_at = cycle;
    self.playback_stopped = true;
}

/// One CPU cycle of the startup latency countdown; see `setEnabled`.
pub fn tickStartupDelay(self: *Dmc) void {
    if (self.dma_startup_delay > 0) self.dma_startup_delay -= 1;
}

/// $4010.
pub fn writeControl(self: *Dmc, value: u8) void {
    self.irq_enabled = (value & 0x80) != 0;
    self.loop = (value & 0x40) != 0;
    self.rate = rate_table[value & 0x0F];
    if (!self.irq_enabled) self.irq_flag = false;
}

/// $4011. Writing the output level directly is how software plays PCM samples
/// through this channel without using its delta decoder at all.
pub fn writeDirectLoad(self: *Dmc, value: u8) void {
    self.output_level = @truncate(value & 0x7F);
}

/// $4012. Sample addresses are 64-byte aligned within $C000-$FFC0.
pub fn writeSampleAddr(self: *Dmc, value: u8) void {
    self.sample_addr = 0xC000 | (@as(u16, value) << 6);
}

/// $4013. Sample lengths are `16n + 1` bytes.
pub fn writeSampleLength(self: *Dmc, value: u8) void {
    self.sample_length = (@as(u16, value) << 4) | 1;
}

/// $4015 bit 4: starts playback if it is not already running, or stops it.
/// Restarting an already-playing sample is a no-op.
///
/// Starting does not fetch anything here; `Nes.stepCycle` notices `needsDma`
/// once `dma_startup_delay` runs out. That first fetch is scheduled for the
/// get cycle of the second APU cycle after the write, so how far away it is
/// depends on which half of an APU cycle the write landed on: 4 CPU cycles
/// from a get, 3 from a put. Steady-state refills have no such latency and
/// fire the instant the buffer empties.
pub fn setEnabled(self: *Dmc, enabled: bool, write_cycle: u64) void {
    if (!enabled) {
        if (self.bytes_remaining > 0) self.stopPlayback(write_cycle);
        return;
    }
    if (self.bytes_remaining != 0) return;

    self.playback_stopped = false;
    self.pending_reload = .none;
    self.current_addr = self.sample_addr;
    self.bytes_remaining = self.sample_length;
    self.dma_startup_delay = if (write_cycle % 2 == 0) 4 else 3;
}

/// Called by `Dma` once its fetch completes.
pub fn completeDmaFetch(self: *Dmc, byte: u8, cycle: u64) void {
    self.sample_buffer = byte;
    self.sample_buffer_filled = true;
    self.dma_pending = false;
    self.pending_reload = .none;
    if (self.bytes_remaining == 0) return; // the channel was disabled mid-fetch

    // Sample addresses wrap within the cartridge window rather than into the
    // registers below it.
    self.current_addr = if (self.current_addr == 0xFFFF) 0x8000 else self.current_addr + 1;
    self.bytes_remaining -= 1;
    if (self.bytes_remaining != 0) return;

    if (self.loop) {
        self.current_addr = self.sample_addr;
        self.bytes_remaining = self.sample_length;
        return;
    }
    // Playback just ended on its own. That counts as a stop exactly like
    // clearing $4015 bit 4 does, which is how a non-looping one-byte sample
    // can trip the aborted-DMA case in `classifyReload`.
    self.stopPlayback(cycle);
    if (self.irq_enabled) self.irq_flag = true;
}

/// One APU cycle, i.e. every other CPU cycle.
pub fn tickTimer(self: *Dmc, cycle: u64) void {
    if (self.timer > 0) {
        self.timer -= 1;
        return;
    }
    // `rate_table` is a full CPU-cycle period while this runs once per APU
    // cycle, so the reload is halved; the -1 is the extra tick the countdown
    // itself costs.
    self.timer = self.rate / 2 - 1;

    if (!self.silent) {
        if ((self.shift_register & 1) != 0) {
            if (self.output_level <= 125) self.output_level += 2;
        } else {
            if (self.output_level >= 2) self.output_level -= 2;
        }
    }
    self.shift_register >>= 1;

    if (self.bits_remaining != 0) {
        self.bits_remaining -= 1;
        return;
    }
    self.bits_remaining = 7;
    if (self.sample_buffer_filled) {
        self.silent = false;
        self.shift_register = self.sample_buffer;
        self.sample_buffer_filled = false;
    } else {
        self.silent = true;
    }
    // The output cycle has ended with the sample buffer empty, which is the
    // instant a reload DMA is scheduled. `needsDma` picks the ordinary case up
    // from `bytes_remaining` on its own; this only decides what happens when
    // playback has just stopped.
    self.pending_reload = self.classifyReload(cycle);
}

pub fn output(self: *const Dmc) u7 {
    return self.output_level;
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// A channel decoding `byte`, with the shift register already loaded and the
/// output level at mid-scale.
fn decoding(byte: u8) Dmc {
    var d: Dmc = .init;
    d.output_level = 64;
    d.silent = false;
    d.shift_register = byte;
    d.bits_remaining = 7;
    d.rate = rate_table[0xF]; // the fastest, so ticks are cheap
    return d;
}

test "each rate table entry is an even CPU-cycle period, descending" {
    var previous: u16 = std.math.maxInt(u16);
    for (rate_table) |rate| {
        try testing.expectEqual(@as(u16, 0), rate % 2);
        try testing.expect(rate < previous);
        previous = rate;
    }
}

test "the timer clocks once per rate CPU cycles" {
    for ([_]u4{ 0, 7, 0xF }) |index| {
        var d: Dmc = .init;
        d.writeControl(index);
        d.timer = 0;
        d.tickTimer(0); // the clock under test, which reloads

        var apu_ticks: u32 = 1;
        while (d.timer != 0) : (apu_ticks += 1) d.tickTimer(0);
        // One more tick would clock again, so the period is that many APU
        // cycles, which is twice as many CPU cycles.
        try testing.expectEqual(rate_table[index], @as(u16, @intCast(apu_ticks * 2)));
    }
}

test "a 1 bit raises the output level by 2 and a 0 bit lowers it" {
    var d = decoding(0b0000_0001);
    d.timer = 0;
    d.tickTimer(0);
    try testing.expectEqual(@as(u7, 66), d.output_level);
    d.timer = 0;
    d.tickTimer(0); // the next bit is 0
    try testing.expectEqual(@as(u7, 64), d.output_level);
}

test "the output level clamps rather than wrapping at either end" {
    var high = decoding(0xFF);
    high.output_level = 126;
    for (0..8) |_| {
        high.timer = 0;
        high.tickTimer(0);
    }
    try testing.expectEqual(@as(u7, 126), high.output_level);

    var low = decoding(0x00);
    low.output_level = 1;
    for (0..8) |_| {
        low.timer = 0;
        low.tickTimer(0);
    }
    try testing.expectEqual(@as(u7, 1), low.output_level);
}

test "a silent channel holds its level instead of decoding" {
    var d = decoding(0xFF);
    d.silent = true;
    d.timer = 0;
    d.tickTimer(0);
    try testing.expectEqual(@as(u7, 64), d.output_level);
}

test "sample addresses are 64-byte aligned and lengths are 16n+1" {
    var d: Dmc = .init;
    d.writeSampleAddr(0x00);
    try testing.expectEqual(@as(u16, 0xC000), d.sample_addr);
    d.writeSampleAddr(0xFF);
    try testing.expectEqual(@as(u16, 0xFFC0), d.sample_addr);

    d.writeSampleLength(0x00);
    try testing.expectEqual(@as(u16, 1), d.sample_length);
    d.writeSampleLength(0xFF);
    try testing.expectEqual(@as(u16, 4081), d.sample_length);
}

test "the fetch address wraps from $FFFF back to $8000" {
    var d: Dmc = .init;
    d.writeSampleAddr(0xFF); // $FFC0
    d.writeSampleLength(0xFF);
    d.setEnabled(true, 0);
    d.current_addr = 0xFFFF;
    d.completeDmaFetch(0x5A, 0);
    try testing.expectEqual(@as(u16, 0x8000), d.current_addr);
}

test "a looping sample restarts at its own address once the last byte arrives" {
    var d: Dmc = .init;
    d.writeControl(0x40); // loop
    d.writeSampleAddr(0x01); // $C040
    d.writeSampleLength(0x00); // 1 byte
    d.setEnabled(true, 0);

    d.completeDmaFetch(0x5A, 0);
    try testing.expectEqual(@as(u16, 0xC040), d.current_addr);
    try testing.expectEqual(@as(u16, 1), d.bytes_remaining);
    try testing.expect(d.isPlaying());
}

test "a non-looping sample stops and raises its IRQ when enabled to" {
    var d: Dmc = .init;
    d.writeControl(0x80); // IRQ enabled, no loop
    d.writeSampleLength(0x00); // 1 byte
    d.setEnabled(true, 0);

    d.completeDmaFetch(0x5A, 100);
    try testing.expect(!d.isPlaying());
    try testing.expect(d.irq_flag);
    try testing.expect(d.playback_stopped);
    try testing.expectEqual(@as(u64, 100), d.stopped_at);

    // Clearing the IRQ enable also clears the flag.
    d.writeControl(0x00);
    try testing.expect(!d.irq_flag);
}

test "the first fetch of a fresh sample waits 4 CPU cycles from a get, 3 from a put" {
    var from_get: Dmc = .init;
    from_get.setEnabled(true, 100);
    try testing.expectEqual(@as(u16, 4), from_get.dma_startup_delay);

    var from_put: Dmc = .init;
    from_put.setEnabled(true, 101);
    try testing.expectEqual(@as(u16, 3), from_put.dma_startup_delay);

    // Nothing may be requested until the delay expires.
    try testing.expect(!from_put.needsDma());
    for (0..3) |_| from_put.tickStartupDelay();
    try testing.expect(from_put.needsDma());
}

test "enabling an already-playing channel does not restart it" {
    var d: Dmc = .init;
    d.writeSampleLength(0x10);
    d.setEnabled(true, 0);
    d.bytes_remaining = 5;
    d.dma_startup_delay = 0;
    d.setEnabled(true, 0);
    try testing.expectEqual(@as(u16, 5), d.bytes_remaining);
    try testing.expectEqual(@as(u16, 0), d.dma_startup_delay);
}

test "a stop close to the buffer emptying leaves the DMA half-committed" {
    // The three cases `classifyReload` distinguishes, driven through the same
    // path software would: stop playback, then let the buffer empty `d` CPU
    // cycles later.
    const cases = [_]struct { u64, Reload }{
        .{ 0, .full },
        .{ 1, .full },
        .{ 2, .single_cycle },
        .{ 3, .single_cycle },
        .{ 4, .none },
        .{ 100, .none },
    };
    for (cases) |case| {
        const delay, const expected = case;
        var d: Dmc = .init;
        d.writeSampleLength(0x10);
        d.setEnabled(true, 0);
        d.setEnabled(false, 1000); // stop

        // Empty the buffer at cycle 1000 + delay.
        d.bits_remaining = 0;
        d.timer = 0;
        d.sample_buffer_filled = false;
        d.tickTimer(1000 + delay);
        try testing.expectEqual(expected, d.pending_reload);
    }
}

test "a completed fetch clears the pending reload and the in-flight flag" {
    var d: Dmc = .init;
    d.writeSampleLength(0x10);
    d.setEnabled(true, 0);
    d.dma_pending = true;
    d.pending_reload = .full;
    d.completeDmaFetch(0x5A, 0);
    try testing.expect(!d.dma_pending);
    try testing.expectEqual(Reload.none, d.pending_reload);
    try testing.expect(d.sample_buffer_filled);
}

test "a fetch that lands after the channel was disabled is discarded" {
    var d: Dmc = .init;
    d.writeSampleLength(0x10);
    d.setEnabled(true, 0);
    d.setEnabled(false, 10);
    d.completeDmaFetch(0x5A, 20);
    try testing.expect(d.sample_buffer_filled); // the byte still lands
    try testing.expectEqual(@as(u16, 0), d.bytes_remaining); // but nothing advances
}

test "an empty sample buffer silences the decoder at the next output cycle" {
    var d = decoding(0xFF);
    d.sample_buffer_filled = false;
    d.bits_remaining = 0;
    d.timer = 0;
    d.tickTimer(0);
    try testing.expect(d.silent);

    d.sample_buffer = 0x0F;
    d.sample_buffer_filled = true;
    d.bits_remaining = 0;
    d.timer = 0;
    d.tickTimer(0);
    try testing.expect(!d.silent);
    try testing.expectEqual(@as(u8, 0x0F), d.shift_register);
    try testing.expect(!d.sample_buffer_filled);
}

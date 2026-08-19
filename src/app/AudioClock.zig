//! Resampling from the console's clock to the audio device's, and the
//! feedback that keeps the device's queue at a steady depth.
//!
//! Its own type because it is a closed control loop: it owns the accumulator,
//! the buffer this frame's samples land in, and the target depth, and the only
//! thing it needs from outside is how many samples the device still holds.
//! `App` decides when a frame runs; everything about how fast it is sampled is
//! decided here.

const std = @import("std");
const AudioClock = @This();
const Allocator = std.mem.Allocator;

/// The rate samples are produced at, which is what the device is opened at.
pub const sample_rate: u32 = 44_100;

/// NTSC CPU clock, Hz. The console emits one sample candidate per CPU cycle.
const cpu_hz: f64 = 1_789_773.0;

/// How much audio to keep queued ahead of playback, in seconds. This is the
/// slack that absorbs a late frame; it is also added latency, so it wants to
/// be as small as it can be without running dry. Three NES frames' worth is
/// enough to ride out an occasional hitch.
const target_latency: f64 = 0.050;
/// Ceiling on how far the resampling ratio may be stretched to steer the queue
/// back to that target. The mismatch being corrected is ~0.16%, so 1% is ample
/// headroom, and it is small enough not to be audible as pitch.
const max_rate_correction: f64 = 0.01;
/// Seconds the correction is allowed to take to close the whole gap. Sets how
/// hard the feedback pulls; too fast makes the ratio jitter with the queue's
/// own sampling noise.
const correction_time: f64 = 2.0;

/// This frame's audio, refilled from scratch every frame.
buf: std.ArrayList(f32) = .empty,
/// Running "cycles since last sample" accumulator.
accumulator: f64 = 0,
/// How deep the device's queue is kept, in samples.
target_samples: usize = @intFromFloat(target_latency * @as(f64, sample_rate)),

pub const init: AudioClock = .{};

pub fn deinit(self: *AudioClock, gpa: Allocator) void {
    self.buf.deinit(gpa);
}

/// Picks the rate to resample at for the coming frame, nudging it off
/// `sample_rate` to steer the queue back to its target depth.
///
/// Whatever paces the loop is not the audio device's clock, so the two
/// disagree about how long a second is. On the desktop the loop rides the
/// display's refresh, which produces `refresh_hz * samples_per_nes_frame`
/// samples per second against the device's rate; those only agree if the panel
/// refreshes at exactly NTSC's 60.0988 Hz, and on a 60.000 Hz one the
/// shortfall measures ~70 samples/s. In a browser the loop rides
/// `performance.now()` instead, which is closer but still another crystal.
/// Either way the mismatch drains any fixed head start and then leaves the
/// device playing silence between batches -- audible as intermittent crackling
/// that gets worse the longer the emulator runs.
///
/// Correcting the resampling ratio rather than the frame pacing is what keeps
/// the video pacing free to stay on whatever its own clock is, and confines the
/// compensation to a pitch shift far below the audible threshold.
pub fn rateFor(self: *const AudioClock, queued_samples: usize) f64 {
    const rate: f64 = @floatFromInt(sample_rate);
    const deficit = @as(f64, @floatFromInt(self.target_samples)) -
        @as(f64, @floatFromInt(queued_samples));
    const correction = std.math.clamp(
        deficit / (rate * correction_time),
        -max_rate_correction,
        max_rate_correction,
    );
    return rate * (1.0 + correction);
}

/// Starts a frame at `rate`, discarding whatever the last one produced.
pub fn beginFrame(self: *AudioClock) void {
    self.buf.clearRetainingCapacity();
}

/// One CPU cycle's worth of the console's output, at `rate`. Emits a sample
/// each time the accumulator crosses a whole CPU clock's worth.
///
/// Each emitted sample is the *average* of every CPU cycle since the previous
/// one, filtered by the console's own output stages -- the anti-aliasing lives
/// in the APU, not here.
pub fn cycle(self: *AudioClock, gpa: Allocator, rate: f64, sample: f32) !void {
    self.accumulator += rate;
    if (self.accumulator >= cpu_hz) {
        self.accumulator -= cpu_hz;
        try self.buf.append(gpa, sample);
    }
}

/// The samples this frame produced.
pub fn frame(self: *const AudioClock) []const f32 {
    return self.buf.items;
}

/// Fills the buffer with the silence the feedback loop assumes is already
/// queued, and returns it for the caller to hand to the device.
///
/// Starting from empty would take seconds to fill -- the correction can only
/// trim the rate by a fraction of a percent -- and every one of those seconds
/// would underrun. So the queue is primed with silence instead, whenever the
/// console being listened to changes.
pub fn prime(self: *AudioClock, gpa: Allocator) []const f32 {
    self.accumulator = 0;
    self.buf.clearRetainingCapacity();
    self.buf.appendNTimes(gpa, 0, self.target_samples) catch return &.{};
    return self.buf.items;
}

// --- Tests ---------------------------------------------------------------

const testing = std.testing;

test "a full queue is resampled slower and an empty one faster" {
    const clock: AudioClock = .init;
    const nominal: f64 = @floatFromInt(sample_rate);

    // Exactly on target: no correction.
    try testing.expectApproxEqAbs(nominal, clock.rateFor(clock.target_samples), 0.001);
    // Draining: speed up to refill it.
    try testing.expect(clock.rateFor(0) > nominal);
    // Overfull: slow down to let it drain.
    try testing.expect(clock.rateFor(clock.target_samples * 4) < nominal);
}

test "the correction is clamped, however far the queue has drifted" {
    const clock: AudioClock = .init;
    const nominal: f64 = @floatFromInt(sample_rate);
    const ceiling = nominal * (1.0 + max_rate_correction);

    try testing.expect(clock.rateFor(0) <= ceiling);
    try testing.expect(clock.rateFor(1_000_000) >= nominal * (1.0 - max_rate_correction));
}

test "one sample comes out per CPU-clock's worth of accumulated rate" {
    var clock: AudioClock = .init;
    defer clock.deinit(testing.allocator);

    // At the nominal rate, a second of CPU cycles yields a second of samples.
    const rate: f64 = @floatFromInt(sample_rate);
    clock.beginFrame();
    for (0..@intFromFloat(cpu_hz)) |_| try clock.cycle(testing.allocator, rate, 0.25);

    // Within one sample of the rate, since the accumulator carries a remainder.
    const produced = clock.frame().len;
    try testing.expect(produced == sample_rate or produced == sample_rate - 1);
    try testing.expectEqual(@as(f32, 0.25), clock.frame()[0]);
}

test "priming hands over exactly the head start the feedback assumes" {
    var clock: AudioClock = .init;
    defer clock.deinit(testing.allocator);

    const primed = clock.prime(testing.allocator);
    try testing.expectEqual(clock.target_samples, primed.len);
    for (primed) |sample| try testing.expectEqual(@as(f32, 0), sample);
    try testing.expectEqual(@as(f64, 0), clock.accumulator);
}

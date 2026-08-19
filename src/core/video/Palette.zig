//! The 2C02's master palette as RGB, generated from the composite signal it
//! actually emits: 512 entries indexed `(emphasis << 6) | (luma << 4) | hue`,
//! i.e. the 64-entry palette once for each of the 8 combinations of PPUMASK's
//! three color emphasis bits.
//!
//! These are not measured RGB values, because none exist: the PPU outputs
//! composite video, so "the" NES palette is a decoding choice and real
//! reference palettes visibly disagree with each other. What is fixed is the
//! signal, and this file models that instead of tabulating someone's decode.
//!
//! ## The base 64 entries
//!
//! Each chromatic entry is a square wave on the NTSC color subcarrier,
//! swinging between the row's $xD and $x0 levels. Decoding it through YIQ is
//! what makes the hue *steps* uneven in RGB space -- equal 30-degree phase
//! steps do not produce equal-looking hue steps -- which is why an evenly
//! spaced HSV wheel cannot reproduce this palette no matter how its phase is
//! tuned.
//!
//! **Every constant here is measured or standardized; none is chosen to
//! taste.** There are three sources and it is worth keeping them apart:
//!
//!  - *Measured*, and not negotiable: the eight terminated voltages in
//!    `level_low_mv`/`level_high_mv`, the 0.816328 attenuation ratio, the
//!    burst being wave 8, and the 5-degrees-per-row `phase_distortion`.
//!  - *Standardized*, and quotable: the SMPTE 170M burst-referenced
//!    `saturation`, and the FCC YIQ decode matrix.
//!  - *Chosen*, and therefore stated: black is $1D with no 7.5 IRE setup and
//!    white is $20, i.e. the Japanese convention. A US set adds the setup and
//!    comes out darker with more contrast.
//!
//! Independent decodes of the same signal land within a mean channel error of
//! about 7 of 255, worst 26. That residual is a difference of filtering model
//! and is not worth chasing -- closing it would mean copying someone else's
//! decode rather than deriving one. There is deliberately no test on it; the
//! file is stable, and a palette regression is visible at a glance.
//!
//! ## Color emphasis
//!
//! Each of PPUMASK bits 5/6/7 gates a shared attenuator with one color square
//! wave -- color $C for bit 5, $4 for bit 6, $8 for bit 7 -- attenuating the
//! composite signal during that wave's high phases. The screen takes on the
//! tint of the *complement* of the attenuated phase, which is why bit 5
//! attenuates color $C but reads as "emphasize red" (color $6).
//!
//! That is a phase-domain effect and cannot be expressed as a scale factor on
//! the decoded R/G/B channels. The giveaway is the two-bit case: the
//! attenuator is active for 6 of 12 half-clocks with one bit set, **10** with
//! two, and 12 with all three, because color $C's and color $4's windows
//! overlap by two half-clocks. Two bits are not the sum of two independent
//! per-channel effects.
//!
//! So `buildEntry` reconstructs the square wave in the phase domain,
//! attenuates the half-clocks the enabled bits gate, and decodes the result
//! the way a TV would: mean is luma, fundamental is chroma. With no emphasis
//! bits set this reproduces the base 64 entries exactly, which a test below
//! asserts against the closed form.
//!
//! Two hardware details are load-bearing: the attenuated signal is 0.816328
//! times the unattenuated one, and emphasis does not reach hues $E/$F (always
//! black) but does reach the blacks and greys of hue $D.
//!
//! ## What absolute hue rests on
//!
//! A composite decoder has no idea what hue anything is until it locks to the
//! colorburst, and that is the one constant here with no local sanity check:
//! rotating it moves all twelve hues together, leaves the greys and the luma
//! ramp untouched, and still passes "is $21 blue". See `burst_iq_phase_deg`,
//! which ties it to the burst being wave 8, and the test that picks hues near
//! a boundary where a wrong lock changes which color the entry reads as.

const std = @import("std");

/// One framebuffer pixel: `(emphasis << 6) | index`, where `index` is a 6-bit
/// palette-RAM value and `emphasis` is PPUMASK bits 7-5 in register order
/// (blue, green, red). Indexes `table` directly.
pub const Pixel = u9;

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// Expands a framebuffer into packed 8-bit colour, `stride` bytes per pixel.
///
/// Both frontends need exactly this and differ only in the stride -- 3 for a
/// texture upload, 4 for a canvas -- so the loop lives here rather than once
/// per backend. Bytes past the third of each pixel are left alone, which is
/// what lets a caller set alpha once and never again.
pub fn expand(pixels: []const Pixel, out: []u8, comptime stride: usize) void {
    std.debug.assert(out.len >= pixels.len * stride);
    for (pixels, 0..) |pixel, i| {
        const rgb = table[pixel];
        out[i * stride + 0] = rgb.r;
        out[i * stride + 1] = rgb.g;
        out[i * stride + 2] = rgb.b;
    }
}

pub const table: [512]Rgb = tables.rgb;

/// Each entry's luma -- the mean of its composite waveform -- as 0-255 with
/// $1D at 0 and $20 at 255.
///
/// This is the brightness the CRT's beam actually puts out, taken from the
/// signal rather than re-derived from the decoded RGB above, where per-channel
/// clamping has already thrown some of it away. `Zapper` is what wants it: a
/// light gun's photodiode integrates light, not colour.
pub const luma_table: [512]u8 = tables.luma;

const tables = buildTables();

/// Terminated output potentials in mV, measured into a properly terminated
/// (75 ohm) TV, and carrying about 10 mV of noise and 4 mV of quantization
/// error.
///
/// **Every level in this file comes from these eight numbers.** The DAC emits
/// one of two voltages per row and the rest is built out of them: $x1-$xC
/// output a square wave alternating between the levels for $xD and $x0,
/// $xE/$xF output the same voltage as $1D, and colors $20 and $30 are
/// identical. So a chromatic entry has no pedestal or amplitude of its own --
/// both are consequences of the pair below, and writing them down separately
/// would be writing down the same measurement twice.
const level_low_mv = [4]f32{ 228, 312, 552, 880 }; // $0D $1D $2D $3D
const level_high_mv = [4]f32{ 616, 840, 1100, 1100 }; // $00 $10 $20 $30

/// The signal low each row sits at, normalized. This is hue $D, which carries
/// no chroma but still tracks luma -- black at rows 0-1, dark grey at row 2,
/// light grey at row 3.
///
/// $0D sits *below* black. That is physical, and it decodes to the same black
/// a floored 0.0 would since every channel clamps, but keeping the true
/// negative matters under emphasis: attenuating it drives it further below
/// black and it stays black, whereas attenuating a floored 0.0 leaves a
/// chroma ripple that lifts a channel just above black and tints an entry
/// that should be pure black.
const low_levels = normalizeAll(level_low_mv);

/// The signal high each row sits at, normalized: hue 0, the grey column. Rows
/// 2 and 3 are the same voltage and differ only in how far the low sits below
/// it, i.e. in saturation.
const high_levels = normalizeAll(level_high_mv);

fn normalizeAll(mv: [4]f32) [4]f32 {
    var out: [4]f32 = undefined;
    for (mv, 0..) |v, i| out[i] = (v - black_mv) / (white_mv - black_mv);
    return out;
}

/// Half-clocks per subcarrier cycle. The color generator is clocked on both
/// edges of the ~21.48 MHz clock, giving 12 evenly spaced phases per cycle,
/// and each of the 12 color square waves is high for 6 of them.
const phases = 12;

/// Ratio of attenuated to unattenuated signal. This is a ratio of *absolute*
/// voltages, so it is not a scale factor on this file's normalized scale --
/// see `attenuate`.
const attenuation = 0.816328;

/// The two points every level here is normalized against, in mV of terminated
/// output: $1D at 312 mV is black (0 IRE) and $20 at 1100 mV is white.
const black_mv = 312.0;
const white_mv = 1100.0;

/// Attenuation scales the absolute voltage, and absolute zero is 312 mV
/// *below* black, so on a scale where black is 0.0 the operation picks up a
/// DC offset. Without it, the sub-black half of a saturated dark entry's
/// square wave moves toward black instead of away from it, which can make
/// emphasis brighten an entry.
fn attenuate(v: f32) f32 {
    const offset = black_mv * (attenuation - 1.0) / (white_mv - black_mv);
    return v * attenuation + offset;
}

/// The color square wave each emphasis bit gates the shared attenuator with,
/// in bit order (bit 5 red, bit 6 green, bit 7 blue).
const emphasis_waves = [3]usize{ 0xC, 0x4, 0x8 };

/// Whether color square wave `hue` (1-12) is high at half-clock `p`. Each
/// wave is high for 6 consecutive half-clocks and successive hues start one
/// half-clock earlier.
fn inColorPhase(hue: usize, p: usize) bool {
    return (p + hue - 1) % phases < 6;
}

/// Which of the twelve color square waves the colorburst is, and where that
/// puts it in the I/Q frame the decode below works in.
///
/// **This is what fixes absolute hue, and nothing else does.** The NTSC
/// colorburst -- pure shade -U -- sits at the same phase as wave 8. A receiver
/// locks its demodulator to the burst, so wave 8 *is* the -U axis by
/// definition -- and -U sits 57 degrees clockwise of +I, since the I/Q axes
/// are the U/V ones rotated 33 degrees.
///
/// Getting this wrong rotates every hue at once while leaving the grey column
/// and the luma ramp untouched, so it survives every sanity check that only
/// asks "is $21 blue". It is worth being suspicious of any hue constant that
/// is not tied back to the burst.
const burst_wave: f32 = 8.0;
const burst_iq_phase_deg: f32 = -57.0;

/// Rotation that lines the discrete fundamental up with the burst.
///
/// Summing six unit phasors 30 degrees apart lands 75 degrees off the start of
/// the window, and hue h's window starts at half-clock (13 - h) mod 12, so
/// this basis recovers hue h at `105 + offset - 30h` degrees. Solving that for
/// `burst_iq_phase_deg` at `burst_wave` is the line below; it works out to 78,
/// where a decode that instead pins hue 1 to 180 degrees -- a plausible-
/// looking choice -- gives 105.
const fundamental_phase_offset_deg: f32 =
    burst_iq_phase_deg + 30.0 * burst_wave - 105.0;

/// Colorburst potentials, terminated, in mV.
const burst_high_mv = 524.0;
const burst_low_mv = 148.0;

/// Chroma gain, referenced to the burst the way a receiver does it.
///
/// SMPTE 170M defines saturation against the burst's peak-to-peak amplitude,
/// which is 40 IRE in a standards-conforming signal. The NES's burst is
/// 376 mV, and 1 V is 140 IRE, so it is about 52.6 IRE -- a third louder than
/// the reference. A decoder locked to that burst therefore reads every chroma
/// back oversaturated unless it corrects by the ratio, which is what this is.
///
/// It is a derived number, not a taste knob: it falls out of two measured
/// voltages and one line of the standard.
const saturation: f32 = (40.0 / 140.0) / ((burst_high_mv - burst_low_mv) / 1000.0);

/// Differential phase distortion, in degrees of chroma rotation per luma row.
///
/// The PPU's output impedance depends on the signal level, so together with
/// the board's capacitance the brighter rows have their edges slowed and their
/// chroma delayed. It measures about 2.5 degrees per palette row on a 2C02E
/// and 5 on a 2C02G; this models a 2C02G, matching the revision the rest of
/// the emulator models.
///
/// **This is an analog property of the chip, not a decoding choice.** It is
/// the reason a reference palette's rows do not share one hue wheel.
const phase_distortion_deg_per_row: f32 = 5.0;

/// A 12-point DFT recovers a half-duty square wave's fundamental with
/// magnitude `(2/12)/sin(pi/12)` per unit of wave height, where the continuous
/// fundamental a receiver's filter would recover is `2/pi`. Scaling by the
/// ratio keeps unemphasized entries identical to the closed form rather than
/// 1.15% more saturated.
const fundamental_scale: f32 = (2.0 / std.math.pi) / ((2.0 / 12.0) / @sin(std.math.pi / 12.0));

fn buildTables() struct { rgb: [512]Rgb, luma: [512]u8 } {
    @setEvalBranchQuota(200_000);
    var rgb: [512]Rgb = undefined;
    var luma: [512]u8 = undefined;
    for (0..8) |emphasis| {
        for (0..4) |row| {
            for (0..16) |hue| {
                const built = buildEntry(emphasis, row, hue);
                rgb[emphasis * 64 + row * 16 + hue] = built.rgb;
                luma[emphasis * 64 + row * 16 + hue] = built.luma;
            }
        }
    }
    return .{ .rgb = rgb, .luma = luma };
}

const Entry = struct { rgb: Rgb, luma: u8 };

fn buildEntry(emphasis: usize, luma: usize, hue: usize) Entry {
    // $xE/$xF are black, and unlike $xD they stay black under every emphasis
    // combination.
    if (hue >= 14) return .{ .rgb = .{ .r = 0, .g = 0, .b = 0 }, .luma = 0 };

    // The composite signal's two levels for this entry. A chromatic hue swings
    // between the row's $xD and $x0 levels; hues 0 and 13 are those two levels
    // held flat, so their wave has no fundamental at all -- but is still
    // attenuable.
    const low, const high = switch (hue) {
        0 => .{ high_levels[luma], high_levels[luma] },
        13 => .{ low_levels[luma], low_levels[luma] },
        else => .{ low_levels[luma], high_levels[luma] },
    };

    // Walk the subcarrier cycle one half-clock at a time, attenuating the
    // phases the enabled emphasis bits gate, then decode as a TV would.
    var y: f32 = 0;
    var i: f32 = 0;
    var q: f32 = 0;
    for (0..phases) |p| {
        var level = if (hue != 0 and hue != 13 and inColorPhase(hue, p)) high else low;
        for (emphasis_waves, 0..) |wave, bit| {
            if ((emphasis >> @intCast(bit)) & 1 != 0 and inColorPhase(wave, p)) {
                level = attenuate(level);
                break; // one shared attenuator, so overlapping windows don't stack
            }
        }
        const angle = (@as(f32, @floatFromInt(p)) * (360.0 / @as(f32, phases)) +
            fundamental_phase_offset_deg +
            phase_distortion_deg_per_row * @as(f32, @floatFromInt(luma))) *
            std.math.pi / 180.0;
        y += level;
        i += level * @cos(angle);
        q += level * @sin(angle);
    }
    const mean = 1.0 / @as(f32, phases);
    const chroma_gain = 2 * mean * fundamental_scale * saturation;
    return .{
        .rgb = yiqToRgb(y * mean, i * chroma_gain, q * chroma_gain),
        // $0D sits below black, so this clamps for the same reason the
        // channels do -- there is no less light than none.
        .luma = channel(y * mean),
    };
}

/// Standard FCC NTSC YIQ -> RGB decode matrix.
fn yiqToRgb(y: f32, i: f32, q: f32) Rgb {
    return .{
        .r = channel(y + 0.956 * i + 0.621 * q),
        .g = channel(y - 0.272 * i - 0.647 * q),
        .b = channel(y - 1.106 * i + 1.703 * q),
    };
}

fn channel(x: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(x, 0, 1) * 255.0));
}

// --- Tests ---------------------------------------------------------------

test "expand writes three bytes per pixel and leaves the rest of the stride" {
    const pixels = [_]Pixel{ 0x0F, 0x20 };

    var packed_rgb: [2 * 3]u8 = @splat(0);
    expand(&pixels, &packed_rgb, 3);
    try std.testing.expectEqualSlices(u8, &.{
        table[0x0F].r, table[0x0F].g, table[0x0F].b,
        table[0x20].r, table[0x20].g, table[0x20].b,
    }, &packed_rgb);

    // At stride 4 the fourth byte of each pixel is never written, which is
    // what lets the web backend set alpha once at startup.
    var rgba: [2 * 4]u8 = @splat(0xAA);
    expand(&pixels, &rgba, 4);
    try std.testing.expectEqual(@as(u8, 0xAA), rgba[3]);
    try std.testing.expectEqual(@as(u8, 0xAA), rgba[7]);
    try std.testing.expectEqual(table[0x20].r, rgba[4]);
}

const testing = std.testing;

fn entry(emphasis: usize, luma: usize, hue: usize) Rgb {
    return table[emphasis * 64 + luma * 16 + hue];
}

fn luminance(c: Rgb) f32 {
    return 0.299 * @as(f32, @floatFromInt(c.r)) +
        0.587 * @as(f32, @floatFromInt(c.g)) +
        0.114 * @as(f32, @floatFromInt(c.b));
}

test "the luma table is the same brightness the grey column decodes to" {
    // Hue 0 is a flat level with no chroma at all, so its luma *is* its grey
    // level: the two paths out of `buildEntry` have to agree there, and
    // nowhere else are they comparable without re-deriving one from the other.
    for (0..4) |row| {
        const i = row * 16;
        try testing.expectEqual(table[i].r, luma_table[i]);
    }
    try testing.expectEqual(@as(u8, 255), luma_table[0x20]);
    try testing.expectEqual(@as(u8, 0), luma_table[0x1D]);
    // $0D sits below black and clamps to it, rather than wrapping.
    try testing.expectEqual(@as(u8, 0), luma_table[0x0D]);
    // $xE/$xF are black at every row and under every emphasis.
    for (0..8) |emphasis| {
        try testing.expectEqual(@as(u8, 0), luma_table[emphasis * 64 + 0x0E]);
    }
}

test "with no emphasis bits set, the phase-domain build reproduces the closed form exactly" {
    // The base 64 entries are the calibrated part of this file; generalizing
    // to emphasis must not perturb them. Recompute them the direct way --
    // midpoint as luma, the square wave's fundamental at the hue's phase --
    // and require an exact match.
    for (0..4) |luma| {
        for (0..16) |hue| {
            const expected: Rgb = if (hue == 13)
                yiqToRgb(low_levels[luma], 0, 0)
            else if (hue >= 14)
                .{ .r = 0, .g = 0, .b = 0 }
            else if (hue == 0)
                yiqToRgb(high_levels[luma], 0, 0)
            else blk: {
                // Hue h's fundamental sits at `105 + offset - 30h`, plus this
                // row's share of the distortion, and its amplitude is the
                // square wave's `(2/pi) * (high - low)`.
                const phase_deg = 105.0 + fundamental_phase_offset_deg -
                    30.0 * @as(f32, @floatFromInt(hue)) +
                    phase_distortion_deg_per_row * @as(f32, @floatFromInt(luma));
                const phase = phase_deg * std.math.pi / 180.0;
                const swing = high_levels[luma] - low_levels[luma];
                const amp = swing * (2.0 / std.math.pi) * saturation;
                const pedestal = (high_levels[luma] + low_levels[luma]) / 2.0;
                break :blk yiqToRgb(pedestal, amp * @cos(phase), amp * @sin(phase));
            };
            try testing.expectEqual(expected, entry(0, luma, hue));
        }
    }
}

test "attenuate reproduces every emphasized voltage hardware was measured at" {
    // Terminated potentials of each flat (chroma-free) level, unemphasized
    // and emphasized. These are the only direct measurements of emphasis
    // available, so they are what pins `attenuate`'s offset -- without it the
    // darker entries come out tens of mV too high, and the error grows as the
    // level falls.
    const measured = [_]struct { plain: f32, emphasized: f32 }{
        .{ .plain = 228, .emphasized = 192 }, // $0D
        .{ .plain = 312, .emphasized = 256 }, // $1D
        .{ .plain = 552, .emphasized = 448 }, // $2D
        .{ .plain = 616, .emphasized = 500 }, // $00
        .{ .plain = 840, .emphasized = 676 }, // $10
        .{ .plain = 880, .emphasized = 712 }, // $3D
        .{ .plain = 1100, .emphasized = 896 }, // $20
    };
    for (measured) |m| {
        const normalized = (m.plain - black_mv) / (white_mv - black_mv);
        const predicted_mv = black_mv + attenuate(normalized) * (white_mv - black_mv);
        // The measurements carry about 10 mV of noise and 4 mV of
        // quantization error.
        try testing.expectApproxEqAbs(m.emphasized, predicted_mv, 10.0);
    }
}

test "emphasis dims overall, leaves $xE/$xF black, and still affects $xD" {
    for (1..8) |emphasis| {
        for (0..4) |luma| {
            for (0..16) |hue| {
                const base = entry(0, luma, hue);
                const tinted = entry(emphasis, luma, hue);
                if (hue >= 14) {
                    try testing.expectEqual(base, tinted);
                    continue;
                }
                // Removing signal from part of the cycle lowers the mean, so
                // total brightness falls. This is *not* true per channel:
                // attenuating part of the cycle also rotates the chroma
                // toward the complement, which can push one channel up even
                // as the total drops. That rotation is the tint, and it is
                // why a per-channel scale factor cannot reproduce this.
                //
                // The drop is on the composite signal while the table keeps
                // only its clamped 8-bit decode, so where a base entry
                // already rides a rail the clamp swallows the drop
                // asymmetrically and rounding can tick a value back up by
                // one. A flat sub-black level has a further wrinkle:
                // attenuating 6 of 12 half-clocks turns it into a small
                // ripple whose upward half survives the clamp while its
                // downward half does not, lifting a channel a couple of units
                // above a base pinned at 0. Require a strict drop only where
                // there is headroom; elsewhere just forbid a visible rise.
                const clipped = base.r == 0 or base.g == 0 or base.b == 0 or
                    base.r == 255 or base.g == 255 or base.b == 255;
                if (clipped) {
                    try testing.expect(luminance(tinted) <= luminance(base) + 2.0);
                } else {
                    try testing.expect(luminance(tinted) < luminance(base));
                }
            }
        }
        // $2D is a mid grey: emphasis reaches hue $D even though it carries
        // no chroma of its own. Compare luminance rather than one channel,
        // since emphasis tints as well as dims.
        try testing.expect(luminance(entry(emphasis, 2, 13)) < luminance(entry(0, 2, 13)));
    }
}

test "each emphasis bit tints toward the color its attenuated phase complements" {
    // White ($20) has no chroma of its own to confound the result, so the
    // tint direction reads off directly.
    const red = entry(1, 2, 0); // bit 5
    try testing.expect(red.r > red.g and red.r > red.b);

    const green = entry(2, 2, 0); // bit 6
    try testing.expect(green.g > green.r and green.g > green.b);

    const blue = entry(4, 2, 0); // bit 7
    try testing.expect(blue.b > blue.r and blue.b > blue.g);
}

test "all three emphasis bits attenuate every phase, so the result is a flat dimming" {
    // With 12 of 12 half-clocks attenuated the signal is uniformly scaled,
    // which cannot rotate the chroma: the hue survives untinted and only the
    // brightness drops. Checked on $21, the strongly blue entry.
    const base = entry(0, 2, 1);
    const dimmed = entry(7, 2, 1);
    try testing.expect(dimmed.b > dimmed.r);
    try testing.expect(dimmed.b > dimmed.g);
    try testing.expect(dimmed.b < base.b);
}

test "two emphasis bits attenuate 10 of 12 half-clocks, not 12" {
    // Color $C's and color $4's windows overlap by two half-clocks, so
    // red+green emphasis must leave more signal than all three bits would.
    // On a grey entry that shows up directly as a higher luma. This is what a
    // per-channel approximation gets wrong.
    try testing.expect(entry(3, 2, 0).r > entry(7, 2, 0).r);
}

test "hue 0 and hue 13 are grey ramps, and hues 14-15 are black at every luma" {
    for (0..4) |luma| {
        for ([_]usize{ 0, 13 }) |hue| {
            const c = entry(0, luma, hue);
            try testing.expectEqual(c.r, c.g);
            try testing.expectEqual(c.g, c.b);
        }
        for (14..16) |hue| {
            try testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, entry(0, luma, hue));
        }
    }
}

test "brightness is monotonic across luma levels for the grey column" {
    try testing.expect(entry(0, 0, 0).r < entry(0, 1, 0).r);
    try testing.expect(entry(0, 1, 0).r < entry(0, 2, 0).r);
    try testing.expect(entry(0, 2, 0).r <= entry(0, 3, 0).r);
}

test "hue phase matches the two best-known NES reference colors: $x1 blue, $x9 green" {
    const sky_blue = entry(0, 2, 1); // $21
    try testing.expect(sky_blue.b > sky_blue.r);
    try testing.expect(sky_blue.b > sky_blue.g);

    const grass_green = entry(0, 2, 9); // $29
    try testing.expect(grass_green.g > grass_green.r);
    try testing.expect(grass_green.g > grass_green.b);
}

test "the hues that reveal an absolute phase error, which the two above cannot" {
    // "Is $21 blue" holds across about 50 degrees of rotation, so it passes
    // just as happily with the demodulator locked to the wrong axis. These
    // three sit near hue boundaries, where the *second* channel flips first
    // and a rotation of even 25 degrees changes which color the entry reads
    // as. They are what pins `burst_iq_phase_deg` in place.
    const teal = entry(0, 1, 0xC); // $1C: blue-leaning teal, not green-leaning
    try testing.expect(teal.b > teal.g);

    const red = entry(0, 1, 6); // $16: brick red, so green outranks blue
    try testing.expect(red.g > red.b);

    const indigo = entry(0, 1, 2); // $12: violet side of blue, so red beats green
    try testing.expect(indigo.r > indigo.g);
}

test "Pixel is exactly wide enough to index the palette table" {
    try testing.expectEqual(table.len, std.math.maxInt(Pixel) + 1);
}

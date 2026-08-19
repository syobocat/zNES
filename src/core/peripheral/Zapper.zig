//! The NES Zapper: a light gun that reports two bits on a controller port --
//! whether its photodiode is seeing light right now, and whether its trigger
//! is being squeezed.
//!
//! ## It reports brightness, not position
//!
//! Nothing in the gun knows where it is pointed. It sees the CRT's beam
//! sweep past its field of view and says "light, now"; the *game* knows where
//! the beam is at that instant, because it drew the picture. That is why a
//! Zapper game blacks the screen out and flashes one white box per target:
//! each frame answers one yes/no question, and the answers are what locate
//! the shot.
//!
//! Two things follow for an emulator. There is no cursor to hand the console
//! -- the aim point only ever enters through which *pixel* the diode is
//! looking at. And the light bit has to stay on for a while after the beam
//! passes, or a game that samples a few scanlines later sees nothing.
//!
//! ## The sensor's decay
//!
//! Light is collected as charge, drains away exponentially, and the bit is on
//! while it is above a threshold. Measured on hardware, the resulting window
//! is about 26 scanlines with pure white, 24 with light gray, and 19 with dark
//! gray.
//!
//! Those three points do not sit on any one exponential: fitting white and
//! dark grey exactly puts light grey at 23. So this fits all three by least
//! squares and lands on 26 / 23 / 19, which is inside the tolerance those
//! measurements carry. Fitting light grey instead would cost 2
//! scanlines at the dark end, where the curve is steepest and a game's timing
//! margin is thinnest.
//!
//! ## What is not modeled
//!
//! The real diode has a lens with a field of view several scanlines across,
//! and a filter tuned to the CRT's ~15 kHz line rate. This looks at a single
//! pixel and has no filter. Both simplifications are invisible to the games,
//! which aim the question at a white box far larger than the difference.

const Zapper = @This();
const Palette = @import("../video/Palette.zig");
const timing = @import("../timing.zig");

/// A scanline's worth of dots, for converting the sensor's decay into the
/// clock `Nes` measures everything else in.
const dots_per_scanline = timing.dots_per_scanline;

/// Scanlines the sensor stays on for after seeing a pure white pixel, and the
/// scanlines per e-fold of its decay. Fitted to the three measured
/// brightnesses; see the note above.
const white_hold_scanlines: f64 = 26.36;
const decay_scanlines: f64 = 7.45;

/// How long the trigger reads as half-pulled after being squeezed.
///
/// The gun's 10 uF capacitor against the console's 10 kOhm pull-up is a 0.1 s
/// time constant. A game fires on the 1 -> 0 edge, so this is also how long
/// after the click the shot registers.
const trigger_hold_dots: u64 = @intFromFloat(0.1 * timing.dot_clock_hz);

/// Bits 3 and 4 of the port. The Zapper drives no others -- not even bit 0,
/// which is why a game can tell a gun from a pad by seeing whether bit 3 is
/// ever high.
const light_bit: u8 = 0x08;
const trigger_bit: u8 = 0x10;

/// Which pixel the photodiode is looking at, or null when the gun is pointed
/// away from the screen. Pointing away is a real position, not a missing one:
/// a game checks for *no* light during VBlank to confirm a gun is there at
/// all, and a player who covers the muzzle is how one cheats at Duck Hunt.
pub const Aim = struct { x: u8, y: u8 };

aim: ?Aim = null,
/// The dot the trigger was squeezed on, or null while it is released.
pulled_at: ?u64 = null,

pub const init: Zapper = .{};

pub fn setAim(self: *Zapper, aim: ?Aim) void {
    self.aim = aim;
}

/// Records the trigger's position. Only the press *edge* matters: the
/// hardware's answer to a held trigger is decided by the RC above, not by how
/// long the player keeps squeezing.
pub fn setTrigger(self: *Zapper, pulled: bool, dots: u64) void {
    if (!pulled) {
        self.pulled_at = null;
    } else if (self.pulled_at == null) {
        self.pulled_at = dots;
    }
}

/// The port read. `sensing` is whether the pixel under `aim` is still lit as
/// far as the diode is concerned, which only `Nes` can answer since it owns
/// the PPU; `dots` is the free-running dot counter.
///
/// Bit 3 is inverted -- 0 means light *is* detected -- and bit 4 is 1 only
/// while the trigger is between released and fully pulled.
pub fn read(self: *const Zapper, open_bus: u8, sensing: bool, dots: u64) u8 {
    const light: u8 = if (sensing) 0 else light_bit;
    const trigger: u8 = if (self.halfPulled(dots)) trigger_bit else 0;
    return (open_bus & ~(light_bit | trigger_bit)) | light | trigger;
}

fn halfPulled(self: *const Zapper, dots: u64) bool {
    const pulled_at = self.pulled_at orelse return false;
    return dots -| pulled_at < trigger_hold_dots;
}

/// How long the diode stays on after the beam draws `pixel`, in dots. A
/// palette entry dark enough never to charge the sensor past its threshold
/// gives 0.
pub fn holdDots(pixel: Palette.Pixel) u32 {
    return hold_table[pixel];
}

const hold_table: [512]u32 = buildHoldTable();

fn buildHoldTable() [512]u32 {
    @setEvalBranchQuota(20_000);
    var t: [512]u32 = undefined;
    for (&t, 0..) |*slot, pixel| {
        const luma = @as(f64, @floatFromInt(Palette.luma_table[pixel])) / 255.0;
        const scanlines = if (luma <= 0)
            0
        else
            white_hold_scanlines + decay_scanlines * @log(luma);
        slot.* = if (scanlines <= 0) 0 else @intFromFloat(scanlines * dots_per_scanline);
    }
    return t;
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// `holdDots` in the units the hardware measurements are quoted in, rounded
/// the way a game counting whole scanlines would see it.
fn holdScanlines(pixel: Palette.Pixel) u32 {
    return holdDots(pixel) / dots_per_scanline;
}

test "the sensor's window matches the three measured brightnesses" {
    // Hardware gives about 26 scanlines with pure white, 24 with light gray
    // and 19 with dark gray. Light grey lands one short of that; see the note
    // at the top of the file.
    try testing.expectEqual(@as(u32, 26), holdScanlines(0x20));
    try testing.expectEqual(@as(u32, 23), holdScanlines(0x10));
    try testing.expectEqual(@as(u32, 19), holdScanlines(0x00));

    // $30 is the same signal as $20, so it must give the same answer.
    try testing.expectEqual(holdDots(0x20), holdDots(0x30));
}

test "black never charges the sensor, however long the beam sits on it" {
    // The three blacks a game has to choose between when it clears the screen
    // for a shot, including the one below black.
    try testing.expectEqual(@as(u32, 0), holdDots(0x0F));
    try testing.expectEqual(@as(u32, 0), holdDots(0x1D));
    try testing.expectEqual(@as(u32, 0), holdDots(0x0D));
}

test "a colour is as bright as its luma, not as its channels" {
    // $21 is a mid blue: bright enough to trip the sensor, and by exactly as
    // much as the grey of the same luma.
    try testing.expect(holdDots(0x21) > 0);
    try testing.expect(holdDots(0x21) < holdDots(0x20));
    // Emphasis attenuates the signal, so the same entry gives less light.
    try testing.expect(holdDots(0x20 | (1 << 6)) < holdDots(0x20));
}

test "bit 3 is inverted, and nothing but bits 3-4 is driven" {
    const z: Zapper = .init; // trigger released, so bit 4 is low throughout

    // Not sensing: bit 3 high, everything else straight off the bus.
    try testing.expectEqual(@as(u8, 0b1110_1111), z.read(0b1110_0111, false, 0));
    try testing.expectEqual(@as(u8, 0b0000_1000), z.read(0, false, 0));
    // Sensing: bit 3 low. The two bits the gun drives are exactly the two the
    // bus cannot reach, so a bus full of 1s comes back with both cleared.
    try testing.expectEqual(@as(u8, 0b1110_0111), z.read(0xFF, true, 0));
    // Bit 0 included: unlike a pad, the gun does not ground it, which is what
    // a game's "is this a controller?" check keys on.
    try testing.expectEqual(@as(u8, 0b1010_0101), z.read(0b1011_1101, true, 0));
}

test "the trigger reads high for one RC after the squeeze, then falls" {
    var z: Zapper = .init;
    try testing.expectEqual(@as(u8, 0), z.read(0, false, 1000) & trigger_bit);

    z.setTrigger(true, 1000);
    try testing.expectEqual(trigger_bit, z.read(0, false, 1000) & trigger_bit);
    try testing.expectEqual(trigger_bit, z.read(0, false, 1000 + trigger_hold_dots - 1) & trigger_bit);
    // The edge the game fires on.
    try testing.expectEqual(@as(u8, 0), z.read(0, false, 1000 + trigger_hold_dots) & trigger_bit);

    // Still held: the capacitor does not recharge just because the player has
    // not let go.
    z.setTrigger(true, 1000 + trigger_hold_dots * 2);
    try testing.expectEqual(@as(u8, 0), z.read(0, false, 1000 + trigger_hold_dots * 2) & trigger_bit);

    // Letting go and squeezing again is a fresh pull.
    z.setTrigger(false, 0);
    z.setTrigger(true, 9000);
    try testing.expectEqual(trigger_bit, z.read(0, false, 9000) & trigger_bit);
}

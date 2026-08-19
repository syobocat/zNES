// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! Mappers 9 and 10 (MMC2 / PxROM and MMC4 / FxROM): two 4 KiB CHR windows
//! whose bank numbers are chosen not by the CPU but by *what the PPU just
//! fetched*.
//!
//! ## The CHR banks switch themselves
//!
//! Each 4 KiB pattern window has **two** bank registers and a one-bit latch
//! saying which of them is live. Nothing the CPU writes moves that latch: it
//! flips when the PPU reads a pattern byte out of one particular tile. Tile
//! $FD selects the first register, tile $FE the second, and the switch lands
//! *after* the fetch that caused it -- so the triggering tile is itself drawn
//! from the outgoing bank.
//!
//! Punch-Out!!'s animation is built on this. Two tiles in the middle of the
//! opponent's sprite are $FD and $FE; the game leaves them in place and
//! rewrites the two bank registers, and the character animates because
//! fetching those tiles reaches into a different bank each time. There is no
//! CPU involvement per frame at all.
//!
//! Because the trigger is a *fetch*, the latch is only touched on PPU reads.
//! A $2007 write drives the same address lines but never asserts /RD, so it
//! leaves the latch alone.
//!
//! ## What separates the two chips
//!
//! MMC4 is MMC2 with three differences, all of them small enough that one
//! implementation with a `variant` field is honest rather than a shortcut:
//!
//!   * **PRG window.** MMC2 switches 8 KiB at $8000-$9FFF and fixes the last
//!     three 8 KiB banks above it; MMC4 switches 16 KiB at $8000-$BFFF and
//!     fixes the last 16 KiB.
//!   * **Left pattern table's trigger.** MMC2 only reacts to the two exact
//!     addresses $0FD8 and $0FE8, while its right table reacts to the whole
//!     eight-byte rows $1FD8-$1FDF and $1FE8-$1FEF. MMC4 uses the rows for
//!     both, which is the asymmetry it is described as suppressing.
//!   * **PRG RAM.** FxROM boards carry 8 KiB; PxROM boards carry none.

const Mmc2 = @This();
const mapper = @import("mapper.zig");
const Banks = mapper.Banks;
const Mirroring = mapper.Mirroring;

const chr_window = 0x1000;

pub const Variant = enum {
    /// Mapper 9, PxROM.
    mmc2,
    /// Mapper 10, FxROM.
    mmc4,

    fn prgWindow(self: Variant) usize {
        return switch (self) {
            .mmc2 => 0x2000,
            .mmc4 => 0x4000,
        };
    }
};

/// Which of a window's two bank registers is live. Named for the tile that
/// selects it, because that is how every description of this chip reads.
const Latch = enum(u1) { fd, fe };

variant: Variant,
mirroring_mode: Mirroring,

/// The switchable PRG bank, 4 bits wide.
prg_bank: u8 = 0,
/// `[window][latch]`: two bank registers for each of the two 4 KiB CHR
/// windows, 5 bits wide.
chr_banks: [2][2]u8 = @splat(@splat(0)),
/// One latch per CHR window.
///
/// **The power-on value is unspecified** and settles within the first tile
/// row a game renders. It only matters at all for a game that uses the trick,
/// and such a game necessarily writes both registers before drawing; a game
/// that does not use it writes the same value to both, which makes the latch
/// invisible.
latch: [2]Latch = @splat(.fe),

pub fn init(variant: Variant, mirroring_mode: Mirroring) Mmc2 {
    return .{
        .variant = variant,
        // Software owns mirroring from its first $F000 write; the header's bit
        // is only the power-on state, as on MMC3.
        .mirroring_mode = mirroring_mode,
    };
}

// --- CPU side ------------------------------------------------------------

/// Where `addr` lands in PRG ROM. The fixed region counts from the end, so it
/// is the top of the ROM whatever the size. `Banks.readPrgRom` wraps the
/// result rather than trusting the header's size.
fn prgIndex(self: *const Mmc2, banks: Banks, addr: u16) usize {
    const window = self.variant.prgWindow();
    const count = @max(banks.prg_rom.len / window, 1);
    const switchable_end: u16 = switch (self.variant) {
        .mmc2 => 0xA000,
        .mmc4 => 0xC000,
    };
    const bank = if (addr < switchable_end)
        @as(usize, self.prg_bank) % count
    else
        // The fixed banks are the last ones, in order: MMC2 has three of them
        // and MMC4 one, and either way the window `addr` falls in counts back
        // from the end of the ROM.
        count -| (1 + (0xFFFF - @as(usize, addr)) / window);
    return bank * window + (@as(usize, addr) & (window - 1));
}

pub fn cpuRead(self: *const Mmc2, banks: Banks, addr: u16) ?u8 {
    return switch (addr) {
        // PxROM has no WRAM, but an iNES 1.0 header cannot say so (see
        // `Cartridge`), so the header decides for both variants: an empty
        // `prg_ram` reads as open bus here.
        0x6000...0x7FFF => banks.readPrgRam(addr),
        0x8000...0xFFFF => banks.readPrgRom(self.prgIndex(banks, addr)),
        else => null,
    };
}

pub fn cpuWrite(self: *Mmc2, banks: Banks, addr: u16, value: u8, _: u64) void {
    switch (addr) {
        0x6000...0x7FFF => banks.writePrgRam(addr, value),
        // $8000-$9FFF decodes to nothing on either chip.
        0xA000...0xAFFF => self.prg_bank = value & 0x0F,
        0xB000...0xBFFF => self.chr_banks[0][@intFromEnum(Latch.fd)] = value & 0x1F,
        0xC000...0xCFFF => self.chr_banks[0][@intFromEnum(Latch.fe)] = value & 0x1F,
        0xD000...0xDFFF => self.chr_banks[1][@intFromEnum(Latch.fd)] = value & 0x1F,
        0xE000...0xEFFF => self.chr_banks[1][@intFromEnum(Latch.fe)] = value & 0x1F,
        0xF000...0xFFFF => self.mirroring_mode = if ((value & 1) != 0) .horizontal else .vertical,
        else => {},
    }
}

// --- PPU side ------------------------------------------------------------

fn chrIndex(self: *const Mmc2, addr: u16) usize {
    const window: u1 = @truncate(addr >> 12);
    const bank = self.chr_banks[window][@intFromEnum(self.latch[window])];
    return @as(usize, bank) * chr_window + (addr & 0x0FFF);
}

pub fn ppuRead(self: *Mmc2, banks: Banks, addr: u16) u8 {
    const value = banks.readChr(self.chrIndex(addr));
    // After the fetch, not before: the tile that triggers the switch is drawn
    // from the bank that was live when it was read.
    self.updateLatch(addr);
    return value;
}

/// Flips a window's latch if `addr` was one of its trigger addresses.
fn updateLatch(self: *Mmc2, addr: u16) void {
    const window: u1 = @truncate(addr >> 12);
    const low = addr & 0x0FFF;
    // MMC2's left window is the one asymmetric case: two exact addresses
    // rather than two rows of eight.
    if (self.variant == .mmc2 and window == 0) {
        if (low == 0xFD8) self.latch[0] = .fd;
        if (low == 0xFE8) self.latch[0] = .fe;
        return;
    }
    switch (low & 0x0FF8) {
        0xFD8 => self.latch[window] = .fd,
        0xFE8 => self.latch[window] = .fe,
        else => {},
    }
}

pub fn ppuWrite(self: *Mmc2, banks: Banks, addr: u16, value: u8) void {
    // No latch update: a write drives the address lines but not /RD.
    banks.writeChr(self.chrIndex(addr), value);
}

pub fn mirroring(self: *const Mmc2) Mirroring {
    return self.mirroring_mode;
}

/// Back to the board's power-on registers, keeping its configuration --
/// which describes the cartridge, not its state.
pub fn powerOn(self: *Mmc2) void {
    self.* = init(self.variant, self.mirroring_mode);
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// 128 KiB of PRG and 128 KiB of CHR, each byte stamped with the number of the
/// smallest bank that can contain it -- 8 KiB for PRG so both variants'
/// windows divide it, 4 KiB for CHR.
const test_prg_banks = 16;
const test_chr_banks = 32;
var test_prg: [test_prg_banks * 0x2000]u8 = undefined;
var test_chr: [test_chr_banks * chr_window]u8 = undefined;
var test_prg_ram: [0x2000]u8 = undefined;

fn testBanks() Banks {
    for (0..test_prg_banks) |bank| {
        @memset(test_prg[bank * 0x2000 ..][0..0x2000], @intCast(bank));
    }
    for (0..test_chr_banks) |bank| {
        @memset(test_chr[bank * chr_window ..][0..chr_window], @intCast(bank));
    }
    @memset(&test_prg_ram, 0);
    return .{
        .prg_rom = &test_prg,
        .chr_rom = &test_chr,
        .chr_ram = &.{},
        .prg_ram = &test_prg_ram,
    };
}

test "MMC2 switches 8 KiB at $8000 and fixes the last three banks above it" {
    const banks = testBanks();
    var m = Mmc2.init(.mmc2, .vertical);

    m.cpuWrite(banks, 0xA000, 5, 0);
    try testing.expectEqual(@as(u8, 5), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 5), m.cpuRead(banks, 0x9FFF).?);
    try testing.expectEqual(@as(u8, test_prg_banks - 3), m.cpuRead(banks, 0xA000).?);
    try testing.expectEqual(@as(u8, test_prg_banks - 2), m.cpuRead(banks, 0xC000).?);
    try testing.expectEqual(@as(u8, test_prg_banks - 1), m.cpuRead(banks, 0xE000).?);
    try testing.expectEqual(@as(u8, test_prg_banks - 1), m.cpuRead(banks, 0xFFFF).?);
}

test "MMC4 switches 16 KiB at $8000 and fixes the last 16 KiB above it" {
    const banks = testBanks();
    var m = Mmc2.init(.mmc4, .vertical);

    // The register counts 16 KiB banks here, so 2 is PRG bytes stamped 4 and 5.
    m.cpuWrite(banks, 0xA000, 2, 0);
    try testing.expectEqual(@as(u8, 4), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 5), m.cpuRead(banks, 0xA000).?);
    try testing.expectEqual(@as(u8, test_prg_banks - 2), m.cpuRead(banks, 0xC000).?);
    try testing.expectEqual(@as(u8, test_prg_banks - 1), m.cpuRead(banks, 0xE000).?);
}

test "the PRG register is four bits and wraps on the ROM's real size" {
    var banks = testBanks();
    var m = Mmc2.init(.mmc2, .vertical);

    m.cpuWrite(banks, 0xA000, 0xF5, 0); // only the low nibble is a bank
    try testing.expectEqual(@as(u8, 5), m.cpuRead(banks, 0x8000).?);

    banks.prg_rom = test_prg[0 .. 4 * 0x2000]; // a 32 KiB board
    m.cpuWrite(banks, 0xA000, 5, 0);
    try testing.expectEqual(@as(u8, 1), m.cpuRead(banks, 0x8000).?);
}

test "a pattern fetch of tile $FE switches the window, but only after itself" {
    const banks = testBanks();
    var m = Mmc2.init(.mmc2, .vertical);

    // Left window: register $FD = bank 3, register $FE = bank 9.
    m.cpuWrite(banks, 0xB000, 3, 0);
    m.cpuWrite(banks, 0xC000, 9, 0);
    m.latch[0] = .fd;

    // Reading the trigger byte itself still comes out of bank 3 -- the whole
    // point of the switch landing after the fetch.
    try testing.expectEqual(@as(u8, 3), m.ppuRead(banks, 0x0FE8));
    // From here on the window is bank 9.
    try testing.expectEqual(@as(u8, 9), m.ppuRead(banks, 0x0000));

    // And back again.
    try testing.expectEqual(@as(u8, 9), m.ppuRead(banks, 0x0FD8));
    try testing.expectEqual(@as(u8, 3), m.ppuRead(banks, 0x0000));
}

test "the two windows have independent latches" {
    const banks = testBanks();
    var m = Mmc2.init(.mmc2, .vertical);
    m.cpuWrite(banks, 0xB000, 1, 0); // left, $FD
    m.cpuWrite(banks, 0xC000, 2, 0); // left, $FE
    m.cpuWrite(banks, 0xD000, 3, 0); // right, $FD
    m.cpuWrite(banks, 0xE000, 4, 0); // right, $FE
    m.latch = @splat(.fd);

    // Triggering the right window must leave the left one where it was, which
    // is what lets the background and the sprites animate independently.
    _ = m.ppuRead(banks, 0x1FE8);
    try testing.expectEqual(@as(u8, 1), m.ppuRead(banks, 0x0000));
    try testing.expectEqual(@as(u8, 4), m.ppuRead(banks, 0x1000));
}

test "MMC2's left window triggers on two exact addresses, MMC4's on whole rows" {
    const banks = testBanks();
    for ([_]Mmc2.Variant{ .mmc2, .mmc4 }) |variant| {
        var m = Mmc2.init(variant, .vertical);
        m.cpuWrite(banks, 0xB000, 1, 0);
        m.cpuWrite(banks, 0xC000, 2, 0);

        // $0FE9 is inside the row but is not the exact address.
        m.latch[0] = .fd;
        _ = m.ppuRead(banks, 0x0FE9);
        const expected: u8 = if (variant == .mmc2) 1 else 2;
        try testing.expectEqual(expected, m.ppuRead(banks, 0x0000));

        // The right window uses the row on both chips, so $1FE9 always counts.
        m.cpuWrite(banks, 0xD000, 3, 0);
        m.cpuWrite(banks, 0xE000, 4, 0);
        m.latch[1] = .fd;
        _ = m.ppuRead(banks, 0x1FE9);
        try testing.expectEqual(@as(u8, 4), m.ppuRead(banks, 0x1000));
    }
}

test "a $2007 write does not move the latch" {
    const banks = testBanks();
    var m = Mmc2.init(.mmc4, .vertical);
    m.cpuWrite(banks, 0xB000, 1, 0);
    m.cpuWrite(banks, 0xC000, 2, 0);
    m.latch[0] = .fd;

    m.ppuWrite(banks, 0x0FE8, 0x5A); // CHR ROM, so the write itself does nothing
    try testing.expectEqual(@as(u8, 1), m.ppuRead(banks, 0x0000));
}

test "$F000 selects mirroring" {
    const banks = testBanks();
    var m = Mmc2.init(.mmc2, .horizontal);
    try testing.expectEqual(Mirroring.horizontal, m.mirroring());
    m.cpuWrite(banks, 0xF000, 0, 0);
    try testing.expectEqual(Mirroring.vertical, m.mirroring());
    m.cpuWrite(banks, 0xFFFF, 1, 0);
    try testing.expectEqual(Mirroring.horizontal, m.mirroring());
}

test "the PRG RAM window follows the header, and PRG ROM is not writable" {
    var banks = testBanks();
    var m = Mmc2.init(.mmc4, .vertical);
    m.cpuWrite(banks, 0x6000, 0x5A, 0);
    try testing.expectEqual(@as(u8, 0x5A), m.cpuRead(banks, 0x6000).?);

    banks.prg_ram = &.{};
    try testing.expectEqual(@as(?u8, null), m.cpuRead(banks, 0x6000));
}

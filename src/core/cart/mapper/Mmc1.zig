// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! Mapper 1 (MMC1 / SxROM). CPU writes to $8000-$FFFF load a 5-bit serial
//! shift register one bit at a time, LSB first; the fifth write commits the
//! assembled value into one of four internal registers, chosen by which 8 KiB
//! window ($8000/$A000/$C000/$E000) the write landed in. A write with bit 7
//! set resets the shift register instead of shifting, and forces PRG mode 3.
//!
//! Mirroring is entirely mapper-controlled here; the header's mirroring bit is
//! ignored.
//!
//! The SxROM family shares one chip across boards with very different wiring,
//! and an iNES 1.0 header cannot say which board it is. Bits 4 and 3-2 of the
//! CHR bank register mean different things depending on how much PRG ROM and
//! WRAM the cartridge has, so the size of each is what selects the meaning --
//! see `outerBank`, `prgRamDisabled` and `prgRamBank`.

const Mmc1 = @This();
const mapper = @import("mapper.zig");
const Banks = mapper.Banks;
const Mirroring = mapper.Mirroring;

const prg_window = 0x4000;
const prg_ram_window = 0x2000;
/// Boards larger than this wire the CHR register's bit 4 up as an outer PRG
/// bank; smaller ones use it for something else.
const max_single_outer_bank_prg = 0x40000;
/// A 16 KiB WRAM board with at least this much CHR ROM is an SZROM rather than
/// an SOROM, and selects its WRAM bank with a different bit. See `prgRamBank`.
const min_szrom_chr = 0x4000;

pub const init: Mmc1 = .{};

shift: u8 = 0,
shift_count: u3 = 0,
/// Power-on value: PRG mode 3 (16 KiB switchable at $8000, last bank fixed at
/// $C000), 8 KiB CHR mode, mirroring 0.
control: u8 = 0x0C,
chr_bank0: u8 = 0,
chr_bank1: u8 = 0,
prg_bank: u8 = 0,

/// The CPU cycle of the last write the cartridge saw, or null before any
/// write. Used by the consecutive-write rule in `writeSerial`.
last_write_cycle: ?u64 = null,

pub fn cpuRead(self: *const Mmc1, banks: Banks, addr: u16) ?u8 {
    return switch (addr) {
        0x6000...0x7FFF => if (self.prgRamIndex(banks, addr)) |i| banks.prg_ram[i] else null,
        0x8000...0xFFFF => banks.readPrgRom(self.prgIndex(banks, addr)),
        else => null,
    };
}

pub fn cpuWrite(self: *Mmc1, banks: Banks, addr: u16, value: u8, cycle: u64) void {
    switch (addr) {
        0x6000...0x7FFF => if (self.prgRamIndex(banks, addr)) |i| {
            banks.prg_ram[i] = value;
        },
        0x8000...0xFFFF => self.writeSerial(addr, value, cycle),
        else => {},
    }
    self.last_write_cycle = cycle;
}

/// A write on the cycle immediately after another write has its data bit
/// dropped, but a bit 7 reset is honoured regardless. In practice this only
/// happens under read-modify-write instructions, which write the original
/// value and then the modified one on the next cycle.
///
/// Both halves are load-bearing, and they pull in opposite directions:
/// software that resets by running `INC` over a ROM byte holding $FF needs the
/// $00 written the next cycle to be ignored, while software that sets bit 7 on
/// the second write of an `RRA abs,X` needs that reset to land.
///
/// The rule counts any preceding write cycle, not just one aimed at the serial
/// port -- a PRG RAM write followed immediately by a register write is the
/// reachable case.
fn writeSerial(self: *Mmc1, addr: u16, value: u8, cycle: u64) void {
    if ((value & 0x80) != 0) {
        self.shift = 0;
        self.shift_count = 0;
        self.control |= 0x0C;
        return;
    }
    if (self.last_write_cycle) |previous| {
        if (cycle == previous +% 1) return;
    }

    self.shift |= (value & 1) << self.shift_count;
    self.shift_count += 1;
    if (self.shift_count < 5) return;

    const bits = self.shift;
    self.shift = 0;
    self.shift_count = 0;
    switch (addr & 0x6000) {
        0x0000 => self.control = bits, // $8000-$9FFF
        0x2000 => self.chr_bank0 = bits, // $A000-$BFFF
        0x4000 => self.chr_bank1 = bits, // $C000-$DFFF
        0x6000 => self.prg_bank = bits, // $E000-$FFFF
        else => unreachable,
    }
}

/// The 256 KiB outer bank a board larger than 256 KiB selects with bit 4 of
/// the CHR bank register, as a count of 16 KiB banks.
///
/// The outer bank applies to *all* of PRG, including the normally fixed bank.
/// That is what makes ignoring it fatal rather than merely wrong: the fixed
/// window stops being the selected half's last bank and becomes the whole
/// ROM's, so a 512 KiB game loses its reset vector.
fn outerBank(self: *const Mmc1, banks: Banks) usize {
    if (banks.prg_rom.len <= max_single_outer_bank_prg) return 0;
    return @as(usize, (self.chr_bank0 >> 4) & 1) * 16;
}

fn prgIndex(self: *const Mmc1, banks: Banks, addr: u16) usize {
    const outer = self.outerBank(banks);
    // Bank numbers, including the "last" bank the fixed window uses, are
    // relative to the outer bank.
    const banks_in_outer: usize = if (banks.prg_rom.len > max_single_outer_bank_prg)
        16
    else
        banks.prg_rom.len / prg_window;
    const bank: usize = outer + (self.prg_bank & 0x0F);
    const last: usize = outer + (banks_in_outer -| 1);
    const offset: usize = addr - 0x8000;
    return switch ((self.control >> 2) & 0x03) {
        // 32 KiB mode ignores the bank's low bit. The outer bank is a multiple
        // of 16, so it survives the mask.
        0, 1 => ((bank & ~@as(usize, 1)) * prg_window) + offset,
        2 => if (addr < 0xC000)
            outer * prg_window + offset // first bank of the outer bank, fixed
        else
            bank * prg_window + (offset - prg_window),
        3 => if (addr < 0xC000)
            bank * prg_window + offset
        else
            last * prg_window + (offset - prg_window),
        else => unreachable,
    };
}

/// Whether PRG RAM is currently disabled, so $6000-$7FFF reads as open bus.
///
/// Two independent lines can do this:
///
///  - The PRG bank register's bit 4 is a chip enable on MMC1B and later, and
///    is present on every board.
///  - On SNROM the *CHR* bank register's bit 4 doubles as a disable. That line
///    is the outer PRG bank on SUROM/SXROM and a WRAM bank select on
///    SOROM/SXROM, so it only means "disable" on a board that is neither.
fn prgRamDisabled(self: *const Mmc1, banks: Banks) bool {
    if ((self.prg_bank & 0x10) != 0) return true;
    const is_snrom = banks.prg_rom.len <= max_single_outer_bank_prg and
        banks.prg_ram.len <= prg_ram_window;
    return is_snrom and (self.chr_bank0 & 0x10) != 0;
}

/// Which 8 KiB PRG RAM bank $6000-$7FFF currently shows. Boards with only one
/// window have nothing to select and spend those CHR bits on other things.
///
/// The boards that do bank WRAM drive its address lines from different bits,
/// so the size of the area picks the decode:
///
///  - **32 KiB (SXROM)**: bit 3 is A14 and bit 2 is A13, so the pair is the
///    bank number outright.
///  - **16 KiB with 16 KiB or more of CHR ROM (SZROM)**: that board needs its
///    CHR lines for CHR, so A13 comes from bit 4 instead. This exact shape is
///    also what identifies the board.
///  - **16 KiB otherwise (SOROM)**: A13 is bit 3, and bit 2 is still a CHR
///    line. Reusing the SXROM decode here would answer 2 for the board's own
///    second bank and wrap back onto the first.
fn prgRamBank(self: *const Mmc1, banks: Banks) usize {
    if (banks.prg_ram.len <= prg_ram_window) return 0;
    if (banks.prg_ram.len > 2 * prg_ram_window) return @as(usize, (self.chr_bank0 >> 2) & 0x03);
    if (banks.chr_rom.len >= min_szrom_chr) return @as(usize, (self.chr_bank0 >> 4) & 0x01);
    return @as(usize, (self.chr_bank0 >> 3) & 0x01);
}

/// The index into `banks.prg_ram` that `addr` maps to, or null when PRG RAM is
/// absent or disabled.
fn prgRamIndex(self: *const Mmc1, banks: Banks, addr: u16) ?usize {
    if (banks.prg_ram.len == 0) return null;
    if (self.prgRamDisabled(banks)) return null;
    const bank = self.prgRamBank(banks);
    return (bank * prg_ram_window + (addr - 0x6000)) % banks.prg_ram.len;
}

fn chrIndex(self: *const Mmc1, addr: u16) usize {
    if ((self.control & 0x10) != 0) {
        // 4 KiB mode: independent banks for $0000 and $1000.
        return if (addr < 0x1000)
            @as(usize, self.chr_bank0) * 0x1000 + addr
        else
            @as(usize, self.chr_bank1) * 0x1000 + (addr - 0x1000);
    }
    // 8 KiB mode ignores chr_bank0's low bit.
    return @as(usize, self.chr_bank0 >> 1) * 0x2000 + addr;
}

pub fn ppuRead(self: *Mmc1, banks: Banks, addr: u16) u8 {
    return banks.readChr(self.chrIndex(addr));
}

pub fn ppuWrite(self: *Mmc1, banks: Banks, addr: u16, value: u8) void {
    banks.writeChr(self.chrIndex(addr), value);
}

pub fn mirroring(self: *const Mmc1) Mirroring {
    return switch (self.control & 0x03) {
        0 => .single_screen_lower,
        1 => .single_screen_upper,
        2 => .vertical,
        3 => .horizontal,
        else => unreachable,
    };
}

/// Back to the board's power-on registers, keeping its configuration --
/// which describes the cartridge, not its state.
pub fn powerOn(self: *Mmc1) void {
    self.* = .init;
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

var test_prg: [0x8000]u8 = undefined;
var test_prg_ram: [0x2000]u8 = undefined;

fn testBanks() Banks {
    return .{
        .prg_rom = &test_prg,
        .chr_rom = &.{},
        .chr_ram = &.{},
        .prg_ram = &test_prg_ram,
    };
}

/// PRG ROM of `size` bytes with every 16 KiB bank stamped with its own index,
/// plus `ram_size` bytes of WRAM.
fn stampedBanks(comptime size: usize, comptime ram_size: usize) Banks {
    const S = struct {
        var prg: [size]u8 = undefined;
        var ram: [ram_size]u8 = undefined;
    };
    for (0..size / prg_window) |bank| @memset(S.prg[bank * prg_window ..][0..prg_window], @intCast(bank));
    @memset(&S.ram, 0);
    return .{ .prg_rom = &S.prg, .chr_rom = &.{}, .chr_ram = &.{}, .prg_ram = &S.ram };
}

/// `stampedBanks` with CHR ROM as well, which is what tells an SZROM apart
/// from an SOROM of the same WRAM size.
fn stampedBanksWithChr(comptime size: usize, comptime ram_size: usize, comptime chr_size: usize) Banks {
    const S = struct {
        var prg: [size]u8 = undefined;
        var ram: [ram_size]u8 = undefined;
        var chr: [chr_size]u8 = undefined;
    };
    for (0..size / prg_window) |bank| @memset(S.prg[bank * prg_window ..][0..prg_window], @intCast(bank));
    @memset(&S.ram, 0);
    @memset(&S.chr, 0);
    return .{ .prg_rom = &S.prg, .chr_rom = &S.chr, .chr_ram = &.{}, .prg_ram = &S.ram };
}

/// Shifts `bits` (five of them, LSB first) into the serial port, one write per
/// call on its own non-consecutive cycle.
fn loadRegister(m: *Mmc1, banks: Banks, addr: u16, bits: u8, start_cycle: u64) void {
    for (0..5) |i| {
        m.cpuWrite(banks, addr, @intCast((bits >> @intCast(i)) & 1), start_cycle + i * 2);
    }
}

test "five spaced writes assemble a register value" {
    const banks = testBanks();
    var m: Mmc1 = .init;
    loadRegister(&m, banks, 0xA000, 0x15, 100);
    try testing.expectEqual(@as(u8, 0x15), m.chr_bank0);
}

test "a write on the cycle right after another has its data bit ignored" {
    const banks = testBanks();
    var m: Mmc1 = .init;

    // Four good writes, then a pair on consecutive cycles. Honouring the
    // second of the pair would complete the load with the wrong bit; ignoring
    // it leaves the register still waiting.
    for (0..4) |i| m.cpuWrite(banks, 0xA000, 1, 100 + i * 2);
    try testing.expectEqual(@as(u3, 4), m.shift_count);

    m.cpuWrite(banks, 0xA000, 1, 200); // fifth bit completes the load
    try testing.expectEqual(@as(u8, 0x1F), m.chr_bank0);
    try testing.expectEqual(@as(u3, 0), m.shift_count);

    // A consecutive-cycle write must not even start a new bit.
    m.cpuWrite(banks, 0xA000, 1, 201);
    try testing.expectEqual(@as(u3, 0), m.shift_count);
}

test "the bit 7 reset is never ignored, even on a consecutive cycle" {
    const banks = testBanks();
    var m: Mmc1 = .init;
    m.control = 0; // clear the power-on PRG mode so the reset is visible

    for (0..3) |i| m.cpuWrite(banks, 0xA000, 1, 100 + i * 2);
    try testing.expectEqual(@as(u3, 3), m.shift_count);

    m.cpuWrite(banks, 0xA000, 0x80, 100 + 3 * 2 + 1);
    try testing.expectEqual(@as(u3, 0), m.shift_count);
    try testing.expectEqual(@as(u8, 0x0C), m.control & 0x0C);
}

test "a non-serial-port write still counts as the first of a consecutive pair" {
    const banks = testBanks();
    var m: Mmc1 = .init;
    m.cpuWrite(banks, 0x6000, 0xFF, 300); // PRG RAM, not the serial port
    m.cpuWrite(banks, 0xA000, 1, 301); // next cycle, so dropped
    try testing.expectEqual(@as(u3, 0), m.shift_count);
}

test "the very first write of a run is not treated as a follow-up" {
    const banks = testBanks();
    var m: Mmc1 = .init;
    m.cpuWrite(banks, 0xA000, 1, 0);
    try testing.expectEqual(@as(u3, 1), m.shift_count);
}

test "on a 512 KiB board the outer bank moves the fixed bank too" {
    const banks = stampedBanks(512 * 1024, 0x2000);
    var m: Mmc1 = .init;
    m.control = 0x0C; // PRG mode 3: switchable at $8000, last fixed at $C000
    m.prg_bank = 2;

    // Outer bank 0: switchable is 2, fixed is bank 15 of that half.
    m.chr_bank0 = 0x00;
    try testing.expectEqual(@as(u8, 2), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 15), m.cpuRead(banks, 0xC000).?);

    // Outer bank 1: both move up by 16.
    m.chr_bank0 = 0x10;
    try testing.expectEqual(@as(u8, 18), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 31), m.cpuRead(banks, 0xC000).?);
}

test "a 256 KiB board ignores the outer-bank bit" {
    // The same bit is a PRG RAM disable on SNROM, so it must not move banks on
    // a board that small.
    const banks = stampedBanks(256 * 1024, 0x2000);
    var m: Mmc1 = .init;
    m.control = 0x0C;
    m.prg_bank = 2;
    m.chr_bank0 = 0x10;
    try testing.expectEqual(@as(u8, 2), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 15), m.cpuRead(banks, 0xC000).?);
}

test "PRG mode 2 fixes the first bank at $8000 and switches $C000" {
    const banks = stampedBanks(256 * 1024, 0x2000);
    var m: Mmc1 = .init;
    m.control = 0x08; // PRG mode 2
    m.prg_bank = 5;
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 5), m.cpuRead(banks, 0xC000).?);
}

test "PRG modes 0 and 1 switch 32 KiB at a time, ignoring the bank's low bit" {
    const banks = stampedBanks(256 * 1024, 0x2000);
    var m: Mmc1 = .init;
    m.control = 0x00;
    m.prg_bank = 5; // odd: behaves as 4
    try testing.expectEqual(@as(u8, 4), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 5), m.cpuRead(banks, 0xC000).?);
}

test "PRG-RAM disable makes $6000-$7FFF read as open bus" {
    const banks = testBanks(); // 32 KiB PRG, 8 KiB WRAM: SNROM-shaped
    var m: Mmc1 = .init;
    m.cpuWrite(banks, 0x6000, 0x5A, 0);
    try testing.expectEqual(@as(u8, 0x5A), m.cpuRead(banks, 0x6000).?);

    // MMC1B's chip enable, present on every board.
    m.prg_bank = 0x10;
    try testing.expectEqual(@as(?u8, null), m.cpuRead(banks, 0x6000));
    m.prg_bank = 0x00;

    // SNROM reuses the CHR register's bit 4 for the same job.
    m.chr_bank0 = 0x10;
    try testing.expectEqual(@as(?u8, null), m.cpuRead(banks, 0x6000));
    m.chr_bank0 = 0x00;
    try testing.expectEqual(@as(u8, 0x5A), m.cpuRead(banks, 0x6000).?);
}

test "SXROM-sized WRAM is bank-switched by the CHR register" {
    const banks = stampedBanks(128 * 1024, 32 * 1024);
    var m: Mmc1 = .init;

    for (0..4) |bank| {
        m.chr_bank0 = @intCast(bank << 2);
        m.cpuWrite(banks, 0x6000, @intCast(0xA0 + bank), 0);
    }
    for (0..4) |bank| {
        m.chr_bank0 = @intCast(bank << 2);
        try testing.expectEqual(@as(u8, @intCast(0xA0 + bank)), m.cpuRead(banks, 0x6000).?);
    }
    // On a board with this much WRAM, bit 4 is not a RAM disable.
    m.chr_bank0 = 0x10;
    try testing.expect(m.cpuRead(banks, 0x6000) != null);
}

test "SOROM-sized WRAM is bank-switched by the CHR register's bit 3" {
    // Two 8 KiB chips, and only the upper `S` bit is wired: bit 2 is still a
    // CHR line here, so the SXROM decode would answer 2 for the second chip
    // and wrap it back onto the first.
    const banks = stampedBanks(128 * 1024, 16 * 1024);
    var m: Mmc1 = .init;

    m.chr_bank0 = 0x00;
    m.cpuWrite(banks, 0x6000, 0xA0, 0);
    m.chr_bank0 = 0x08;
    m.cpuWrite(banks, 0x6000, 0xB1, 0);

    m.chr_bank0 = 0x00;
    try testing.expectEqual(@as(u8, 0xA0), m.cpuRead(banks, 0x6000).?);
    m.chr_bank0 = 0x04; // CHR only: WRAM does not move
    try testing.expectEqual(@as(u8, 0xA0), m.cpuRead(banks, 0x6000).?);
    m.chr_bank0 = 0x08;
    try testing.expectEqual(@as(u8, 0xB1), m.cpuRead(banks, 0x6000).?);
    m.chr_bank0 = 0x0C;
    try testing.expectEqual(@as(u8, 0xB1), m.cpuRead(banks, 0x6000).?);
}

test "SZROM-sized WRAM is bank-switched by the CHR register's bit 4 instead" {
    // Same 16 KiB of WRAM, but the board spends its CHR lines on 16 KiB of
    // CHR ROM, so the WRAM address line moves up to bit 4.
    const banks = stampedBanksWithChr(128 * 1024, 16 * 1024, 16 * 1024);
    var m: Mmc1 = .init;

    m.chr_bank0 = 0x00;
    m.cpuWrite(banks, 0x6000, 0xA0, 0);
    m.chr_bank0 = 0x10;
    m.cpuWrite(banks, 0x6000, 0xB1, 0);

    m.chr_bank0 = 0x08; // a CHR line on this board
    try testing.expectEqual(@as(u8, 0xA0), m.cpuRead(banks, 0x6000).?);
    m.chr_bank0 = 0x10;
    try testing.expectEqual(@as(u8, 0xB1), m.cpuRead(banks, 0x6000).?);
    // And bit 4 is not the SNROM RAM disable on a board with two chips.
    try testing.expect(m.cpuRead(banks, 0x6000) != null);
}

test "the mirroring bits cover all four modes" {
    var m: Mmc1 = .init;
    const modes = [_]Mirroring{ .single_screen_lower, .single_screen_upper, .vertical, .horizontal };
    for (modes, 0..) |expected, bits| {
        m.control = @intCast(bits);
        try testing.expectEqual(expected, m.mirroring());
    }
}

test "a board with no PRG ROM reads as open bus instead of crashing" {
    // An iNES header can declare zero PRG banks, and `Cartridge` has no
    // minimum to reject it, so the first reset-vector fetch reaches here.
    const banks: Banks = .{ .prg_rom = &.{}, .chr_rom = &.{}, .chr_ram = &.{}, .prg_ram = &.{} };
    var m: Mmc1 = .init;
    try testing.expectEqual(@as(?u8, null), m.cpuRead(banks, 0xFFFC));
    try testing.expectEqual(@as(?u8, null), m.cpuRead(banks, 0x8000));
}

test "CHR mode selects between one 8 KiB bank and two 4 KiB banks" {
    const S = struct {
        var chr: [64 * 1024]u8 = undefined;
    };
    for (0..16) |bank| @memset(S.chr[bank * 0x1000 ..][0..0x1000], @intCast(bank));
    const banks: Banks = .{ .prg_rom = &test_prg, .chr_rom = &S.chr, .chr_ram = &.{}, .prg_ram = &.{} };

    var m: Mmc1 = .init;
    m.chr_bank0 = 5; // odd, so 8 KiB mode uses bank 4
    m.chr_bank1 = 9;

    m.control = 0x00; // 8 KiB CHR mode
    try testing.expectEqual(@as(u8, 4), m.ppuRead(banks, 0x0000));
    try testing.expectEqual(@as(u8, 5), m.ppuRead(banks, 0x1000));

    m.control = 0x10; // 4 KiB CHR mode
    try testing.expectEqual(@as(u8, 5), m.ppuRead(banks, 0x0000));
    try testing.expectEqual(@as(u8, 9), m.ppuRead(banks, 0x1000));
}

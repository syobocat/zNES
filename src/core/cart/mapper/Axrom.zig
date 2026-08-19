// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! Mapper 7 (AxROM / ANROM, AN1ROM, AMROM, AOROM): the whole $8000-$FFFF
//! window switches as one 32 KiB bank, and the same register picks which
//! single nametable the PPU sees.
//!
//! ## One-screen mirroring is not a solder pad here
//!
//! Every other board mapped in this emulator either hard-wires mirroring or
//! chooses between horizontal and vertical. AxROM does neither: it drives the
//! nametable's own high address line from a register bit, so all four logical
//! nametables show the *same* 1 KiB page and the game picks which one. The
//! header's mirroring bits say nothing about such a board and are ignored.
//!
//! That is why AxROM games scroll by moving the whole picture rather than by
//! wrapping across two nametables, and why Battletoads' vertical scroll is a
//! stream of full-screen redraws.

const Axrom = @This();
const mapper = @import("mapper.zig");
const Banks = mapper.Banks;
const Mirroring = mapper.Mirroring;

const prg_window = 0x8000;

/// Whether a bank write ANDs with the ROM byte underneath it. AMROM and some
/// AOROM wirings conflict; ANROM and AN1ROM carry a 74HC02 that disables PRG
/// ROM during a write and so do not.
///
/// **This is off unless the header says otherwise** -- the opposite of the
/// default `Cnrom` and `Uxrom` get. AxROM is the one licensed discrete board
/// whose conflict-prevention circuitry is there only sometimes, and an iNES
/// 1.0 header (which is what nearly all of them carry) cannot say which. See
/// `Cartridge.busConflicts`, and the test below for what enforcing it wrongly
/// costs.
bus_conflicts: bool,
/// The single register, `xxxM xPPP`: bits 2-0 select the PRG bank, bit 4 the
/// nametable page.
bank_select: u8 = 0,

pub fn init(bus_conflicts: bool) Axrom {
    return .{ .bus_conflicts = bus_conflicts };
}

/// Where `addr` lands in PRG ROM. Only three bank bits are decoded, which is
/// exactly enough for AOROM's 256 KiB. `Banks.readPrgRom` wraps the result, so
/// a 16 KiB image appears twice inside the window rather than running off the
/// end.
fn prgIndex(self: *const Axrom, addr: u16) usize {
    const bank: usize = self.bank_select & 0x07;
    return bank * prg_window + (addr - 0x8000);
}

pub fn cpuRead(self: *const Axrom, banks: Banks, addr: u16) ?u8 {
    return switch (addr) {
        0x6000...0x7FFF => banks.readPrgRam(addr),
        0x8000...0xFFFF => banks.readPrgRom(self.prgIndex(addr)),
        else => null,
    };
}

pub fn cpuWrite(self: *Axrom, banks: Banks, addr: u16, value: u8, _: u64) void {
    switch (addr) {
        0x6000...0x7FFF => banks.writePrgRam(addr, value),
        0x8000...0xFFFF => {
            // See `Uxrom.cpuWrite`: the byte the write fights with is the one
            // in the bank currently mapped at that address.
            self.bank_select = if (self.bus_conflicts)
                value & (self.cpuRead(banks, addr) orelse 0xFF)
            else
                value;
        },
        else => {},
    }
}

pub fn ppuRead(_: *Axrom, banks: Banks, addr: u16) u8 {
    return banks.readChr(addr);
}

pub fn ppuWrite(_: *Axrom, banks: Banks, addr: u16, value: u8) void {
    banks.writeChr(addr, value);
}

pub fn mirroring(self: *const Axrom) Mirroring {
    return if ((self.bank_select & 0x10) != 0) .single_screen_upper else .single_screen_lower;
}

/// Back to the board's power-on registers, keeping its configuration --
/// which describes the cartridge, not its state.
pub fn powerOn(self: *Axrom) void {
    self.* = init(self.bus_conflicts);
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

const test_banks_count = 8;
var test_prg: [test_banks_count * prg_window]u8 = undefined;
var test_chr_ram: [0x2000]u8 = undefined;

/// 256 KiB of PRG in 32 KiB banks, each stamped with its own number.
fn testBanks() Banks {
    for (0..test_banks_count) |bank| {
        @memset(test_prg[bank * prg_window ..][0..prg_window], @intCast(bank));
    }
    @memset(&test_chr_ram, 0);
    return .{
        .prg_rom = &test_prg,
        .chr_rom = &.{},
        .chr_ram = &test_chr_ram,
        .prg_ram = &.{},
    };
}

test "the register switches the whole window at once" {
    const banks = testBanks();
    var m = Axrom.init(false);

    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0xFFFF).?);

    m.cpuWrite(banks, 0x8000, 5, 0);
    // Both ends move together: there is no fixed half to land the reset vector
    // in, which is why every bank of an AxROM game carries its own vectors.
    try testing.expectEqual(@as(u8, 5), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 5), m.cpuRead(banks, 0xFFFF).?);
}

test "bit 4 picks the nametable page, independently of the bank" {
    const banks = testBanks();
    var m = Axrom.init(false);
    try testing.expectEqual(Mirroring.single_screen_lower, m.mirroring());

    m.cpuWrite(banks, 0x8000, 0x10, 0);
    try testing.expectEqual(Mirroring.single_screen_upper, m.mirroring());
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0x8000).?);

    m.cpuWrite(banks, 0x8000, 0x13, 0);
    try testing.expectEqual(Mirroring.single_screen_upper, m.mirroring());
    try testing.expectEqual(@as(u8, 3), m.cpuRead(banks, 0x8000).?);
}

test "only three bank bits are decoded" {
    const banks = testBanks();
    var m = Axrom.init(false);
    // Bit 3 is not a bank bit, so $0F selects bank 7, not bank 15.
    m.cpuWrite(banks, 0x8000, 0x0F, 0);
    try testing.expectEqual(@as(u8, 7), m.cpuRead(banks, 0x8000).?);
}

test "a 16 KiB image appears twice inside the 32 KiB window" {
    // `nes-test-roms/other/oam3.nes` is exactly this: mapper 7 with a single
    // 16 KiB PRG bank, where the second half of the window has no ROM behind
    // it and the address has to fold back rather than run off the end.
    var banks = testBanks();
    banks.prg_rom = test_prg[0..0x4000];
    var m = Axrom.init(false);
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0xFFFF).?);
    m.cpuWrite(banks, 0x8000, 7, 0); // no such bank
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0xC000).?);
}

test "a bank write ANDs with the byte in the bank currently mapped there" {
    const banks = testBanks();
    var m = Axrom.init(true);

    // Bank 0 is mapped, so every byte under the window is 0 and the register
    // cannot be moved off it at all -- the game never leaves its first bank.
    // That is the trap the 74HC02 boards were made to avoid, why software for
    // the conflicting ones writes through a table whose entries match their
    // own addresses' contents, and why `bus_conflicts` defaults to off here.
    m.cpuWrite(banks, 0x8000, 5, 0);
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0x8000).?);

    // With something non-zero underneath, the AND is visible.
    test_prg[0x1234] = 0x06;
    m.cpuWrite(banks, 0x9234, 0x05, 0);
    try testing.expectEqual(@as(u8, 4), m.cpuRead(banks, 0x8000).?);
}

test "CHR is unbanked RAM" {
    const banks = testBanks();
    var m = Axrom.init(false);
    m.ppuWrite(banks, 0x1234, 0x5A);
    m.cpuWrite(banks, 0x8000, 4, 0);
    try testing.expectEqual(@as(u8, 0x5A), m.ppuRead(banks, 0x1234));
}

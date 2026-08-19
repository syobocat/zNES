// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! The GNROM-like boards: a single 8-bit latch holds both banks, and any
//! write to $8000-$FFFF replaces the whole thing.
//!
//!  - **Mapper 11 (Color Dreams)**: PRG in bits 1-0, CHR in bits 7-4.
//!  - **Mapper 66 (GxROM: NES-GNROM and NES-MHROM)**: PRG in bits 5-4, CHR
//!    in bits 1-0.
//!
//! Nintendo's board and Color Dreams' are the same circuit with the two
//! fields at opposite ends of the byte, so they are one file with the decode
//! switched.
//! Color Dreams decodes a wider CHR field (16 banks against GxROM's 4)
//! because it has the room; GxROM's spare bits are simply not wired.
//!
//! ## One register, so the two windows cannot move independently
//!
//! `Uxrom` and `Cnrom` each switch one half of the cartridge and leave the
//! other fixed. This board switches both from one write, which has two
//! consequences a game has to be written around: there is no fixed PRG
//! window, so every 32 KiB bank carries its own reset and NMI vectors as on
//! AxROM, and the CHR bank cannot be changed without also naming a PRG bank
//! (so the code doing the CHR switch must be reachable from whichever PRG
//! bank it lands in).

const Gnrom = @This();
const mapper = @import("mapper.zig");
const Banks = mapper.Banks;
const Mirroring = mapper.Mirroring;

const prg_window = 0x8000;
const chr_window = 0x2000;

pub const Variant = enum { color_dreams, gxrom };

variant: Variant,
/// Fixed by solder pads on both boards, so the header's bits do describe
/// them.
mirroring_mode: Mirroring,
/// Whether a bank write ANDs with the ROM byte underneath it. On unless the
/// header says otherwise -- neither board carries prevention circuitry, and
/// only the Color Dreams prototypes (Free Fall) are reported free of it.
bus_conflicts: bool,
/// Color Dreams' `CCCC LLPP` or GxROM's `xxPP xxCC`. Color Dreams' bits 3-2
/// drive a charge pump at the CIC and mean nothing here; GxROM's bit 5 is
/// unused on MHROM, which only has 64 KiB of PRG.
bank_select: u8 = 0,

pub fn init(variant: Variant, mirroring_mode: Mirroring, bus_conflicts: bool) Gnrom {
    return .{ .variant = variant, .mirroring_mode = mirroring_mode, .bus_conflicts = bus_conflicts };
}

fn prgBank(self: *const Gnrom) usize {
    return switch (self.variant) {
        .color_dreams => self.bank_select & 0x03,
        .gxrom => (self.bank_select >> 4) & 0x03,
    };
}

fn chrBank(self: *const Gnrom) usize {
    return switch (self.variant) {
        .color_dreams => self.bank_select >> 4,
        .gxrom => self.bank_select & 0x03,
    };
}

/// Only two PRG bits are decoded on either board, which is exactly their
/// 128 KiB. `Banks.readPrgRom` wraps the result, so a short image folds back
/// into the window instead of running off the end.
fn prgIndex(self: *const Gnrom, addr: u16) usize {
    return self.prgBank() * prg_window + (addr - 0x8000);
}

fn chrIndex(self: *const Gnrom, banks: Banks, addr: u16) usize {
    const bank_count = @max(banks.chr_rom.len / chr_window, 1);
    return (self.chrBank() % bank_count) * chr_window + (addr & 0x1FFF);
}

pub fn cpuRead(self: *const Gnrom, banks: Banks, addr: u16) ?u8 {
    return switch (addr) {
        0x6000...0x7FFF => banks.readPrgRam(addr),
        0x8000...0xFFFF => banks.readPrgRom(self.prgIndex(addr)),
        else => null,
    };
}

pub fn cpuWrite(self: *Gnrom, banks: Banks, addr: u16, value: u8, _: u64) void {
    switch (addr) {
        0x6000...0x7FFF => banks.writePrgRam(addr, value),
        0x8000...0xFFFF => {
            // See `Cnrom.cpuWrite`. The byte fought with is the one in the
            // bank mapped there *now*, which on this board is a moving
            // target: the latch that decides it is the one being written.
            self.bank_select = if (self.bus_conflicts)
                value & (self.cpuRead(banks, addr) orelse 0xFF)
            else
                value;
        },
        else => {},
    }
}

pub fn ppuRead(self: *Gnrom, banks: Banks, addr: u16) u8 {
    // Nothing to select on a CHR RAM board, and the register's high bits are
    // still whatever the PRG write left there.
    if (banks.chr_ram.len != 0) return banks.readChr(addr);
    return banks.readChr(self.chrIndex(banks, addr));
}

pub fn ppuWrite(_: *Gnrom, banks: Banks, addr: u16, value: u8) void {
    banks.writeChr(addr, value);
}

pub fn mirroring(self: *const Gnrom) Mirroring {
    return self.mirroring_mode;
}

/// Back to the board's power-on registers, keeping its configuration --
/// which describes the cartridge, not its state.
pub fn powerOn(self: *Gnrom) void {
    self.* = init(self.variant, self.mirroring_mode, self.bus_conflicts);
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

const prg_banks_count = 4;
const chr_banks_count = 16;
var test_prg: [prg_banks_count * prg_window]u8 = undefined;
var test_chr: [chr_banks_count * chr_window]u8 = undefined;

/// The board at its declared capacity: 128 KiB of PRG in 32 KiB banks and
/// 128 KiB of CHR in 8 KiB banks, each stamped with its own number.
fn testBanks() Banks {
    for (0..prg_banks_count) |bank| {
        @memset(test_prg[bank * prg_window ..][0..prg_window], @intCast(bank));
    }
    for (0..chr_banks_count) |bank| {
        @memset(test_chr[bank * chr_window ..][0..chr_window], @intCast(bank));
    }
    return .{ .prg_rom = &test_prg, .chr_rom = &test_chr, .chr_ram = &.{}, .prg_ram = &.{} };
}

test "one write moves both windows" {
    const banks = testBanks();
    var m = Gnrom.init(.color_dreams, .horizontal, false);

    m.cpuWrite(banks, 0x8000, 0x52, 0); // CHR bank 5, PRG bank 2
    try testing.expectEqual(@as(u8, 2), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 2), m.cpuRead(banks, 0xFFFF).?);
    try testing.expectEqual(@as(u8, 5), m.ppuRead(banks, 0x0000));
    try testing.expectEqual(@as(u8, 5), m.ppuRead(banks, 0x1FFF));

    // And a game that only wants a different tileset still names a PRG bank,
    // even when the one it names is the one it is running from.
    m.cpuWrite(banks, 0x8000, 0xF2, 0);
    try testing.expectEqual(@as(u8, 2), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 15), m.ppuRead(banks, 0x0000));
}

test "the lockout bits are not bank bits" {
    const banks = testBanks();
    var m = Gnrom.init(.color_dreams, .horizontal, false);

    // $0C is bits 3-2 only: the charge pump moves, neither window does.
    m.cpuWrite(banks, 0x8000, 0x0C, 0);
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 0), m.ppuRead(banks, 0x0000));

    // And they do not carry into the PRG field: $07 selects bank 3, not 7.
    m.cpuWrite(banks, 0x8000, 0x07, 0);
    try testing.expectEqual(@as(u8, 3), m.cpuRead(banks, 0x8000).?);
}

test "a bank write ANDs with the byte in the bank currently mapped there" {
    const banks = testBanks();
    var m = Gnrom.init(.color_dreams, .horizontal, true);

    // Bank 0 is mapped and full of 0, so the latch cannot be moved off it --
    // the same trap AxROM has, and why software for this board writes through
    // a table of bytes matching their own addresses' contents.
    m.cpuWrite(banks, 0x8000, 0x31, 0);
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0x8000).?);

    test_prg[0x1234] = 0x33;
    m.cpuWrite(banks, 0x9234, 0x31, 0);
    try testing.expectEqual(@as(u8, 1), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 3), m.ppuRead(banks, 0x0000));
}

test "both bank numbers wrap on the sizes actually present" {
    var banks = testBanks();
    banks.prg_rom = test_prg[0..prg_window]; // one 32 KiB bank
    banks.chr_rom = test_chr[0 .. 2 * chr_window]; // two 8 KiB banks
    var m = Gnrom.init(.color_dreams, .horizontal, false);

    m.cpuWrite(banks, 0x8000, 0x53, 0);
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0xFFFF).?);
    try testing.expectEqual(@as(u8, 1), m.ppuRead(banks, 0x0000));
}

test "a CHR RAM board bypasses the CHR half of the register" {
    var chr_ram = [_]u8{0} ** chr_window;
    var banks = testBanks();
    banks.chr_ram = &chr_ram;

    var m = Gnrom.init(.color_dreams, .vertical, false);
    m.ppuWrite(banks, 0x0123, 0x5A);
    m.cpuWrite(banks, 0x8000, 0xF1, 0);
    try testing.expectEqual(@as(u8, 0x5A), m.ppuRead(banks, 0x0123));
    try testing.expectEqual(Mirroring.vertical, m.mirroring());
}

test "GxROM puts the same two fields at the other end of the byte" {
    const banks = testBanks();
    var m = Gnrom.init(.gxrom, .horizontal, false);

    // $12 is PRG bank 1, CHR bank 2 here -- and would be PRG 2, CHR 1 on a
    // Color Dreams board. Getting the decode backwards is silent: both
    // fields still move, just not the way the game meant.
    m.cpuWrite(banks, 0x8000, 0x12, 0);
    try testing.expectEqual(@as(u8, 1), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 2), m.ppuRead(banks, 0x0000));

    var cd = Gnrom.init(.color_dreams, .horizontal, false);
    cd.cpuWrite(banks, 0x8000, 0x12, 0);
    try testing.expectEqual(@as(u8, 2), cd.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 1), cd.ppuRead(banks, 0x0000));
}

test "GxROM decodes two CHR bits, not four" {
    const banks = testBanks();
    var m = Gnrom.init(.gxrom, .horizontal, false);
    // $0F would be CHR bank 15 if the field were as wide as Color Dreams';
    // on this board the top two bits are not wired and it is bank 3.
    m.cpuWrite(banks, 0x8000, 0x0F, 0);
    try testing.expectEqual(@as(u8, 3), m.ppuRead(banks, 0x0000));
    // And bit 5 is a PRG bit here, where Color Dreams has nothing.
    m.cpuWrite(banks, 0x8000, 0x30, 0);
    try testing.expectEqual(@as(u8, 3), m.cpuRead(banks, 0x8000).?);
}

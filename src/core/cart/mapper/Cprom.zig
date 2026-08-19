// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! Mapper 13 (CPROM): NROM's fixed 32 KiB of PRG, and 16 KiB of CHR **RAM**
//! banked as two 4 KiB windows -- the left pattern table fixed to page 0, the
//! right one switchable.
//!
//! ## The only board here that banks writable CHR
//!
//! Every other supported board with CHR RAM has exactly 8 KiB of it, unbanked,
//! which is why `Banks.readChr` can treat it as one flat array. This one has
//! four pages, and no iNES 1.0 header can say so -- "no CHR ROM" is the only
//! thing the format can express and it means 8 KiB. `Cartridge.boardChrRam`
//! is where the extra 8 KiB comes from, keyed on the mapper number, because
//! there is nothing else to key it on.
//!
//! Nintendo made one game for it: *Videomation*, a drawing program, where the
//! canvas is the CHR RAM the player is painting into.

const Cprom = @This();
const mapper = @import("mapper.zig");
const Banks = mapper.Banks;
const Mirroring = mapper.Mirroring;

const chr_window = 0x1000;

/// Fixed by the board at vertical, so the header's bit describes it rather
/// than the other way round.
mirroring_mode: Mirroring,
/// Whether a bank write ANDs with the ROM byte underneath it. The board has
/// no prevention circuitry, so this is on unless the header says otherwise.
bus_conflicts: bool,
/// Bits 1-0: the 4 KiB CHR RAM page at PPU $1000-$1FFF.
bank_select: u8 = 0,

pub fn init(mirroring_mode: Mirroring, bus_conflicts: bool) Cprom {
    return .{ .mirroring_mode = mirroring_mode, .bus_conflicts = bus_conflicts };
}

pub fn cpuRead(_: *const Cprom, banks: Banks, addr: u16) ?u8 {
    return switch (addr) {
        0x6000...0x7FFF => banks.readPrgRam(addr),
        0x8000...0xFFFF => banks.readPrgRomMirrored(addr),
        else => null,
    };
}

pub fn cpuWrite(self: *Cprom, banks: Banks, addr: u16, value: u8, _: u64) void {
    switch (addr) {
        0x6000...0x7FFF => banks.writePrgRam(addr, value),
        0x8000...0xFFFF => {
            // See `Cnrom.cpuWrite`: PRG ROM is still driving the bus, so the
            // latch takes the AND of the two.
            self.bank_select = if (self.bus_conflicts)
                value & (banks.readPrgRomMirrored(addr) orelse 0xFF)
            else
                value;
        },
        else => {},
    }
}

/// The left table is page 0 and never moves; only the right one is banked.
fn chrIndex(self: *const Cprom, addr: u16) usize {
    const page: usize = if (addr < chr_window) 0 else self.bank_select & 0x03;
    return page * chr_window + (addr & (chr_window - 1));
}

pub fn ppuRead(self: *Cprom, banks: Banks, addr: u16) u8 {
    return banks.readChr(self.chrIndex(addr));
}

pub fn ppuWrite(self: *Cprom, banks: Banks, addr: u16, value: u8) void {
    banks.writeChr(self.chrIndex(addr), value);
}

pub fn mirroring(self: *const Cprom) Mirroring {
    return self.mirroring_mode;
}

/// Back to the board's power-on registers, keeping its configuration --
/// which describes the cartridge, not its state.
pub fn powerOn(self: *Cprom) void {
    self.* = init(self.mirroring_mode, self.bus_conflicts);
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

var test_prg: [0x8000]u8 = undefined;
var test_chr_ram: [4 * chr_window]u8 = undefined;

fn testBanks() Banks {
    @memset(&test_prg, 0xFF);
    @memset(&test_chr_ram, 0);
    return .{
        .prg_rom = &test_prg,
        .chr_rom = &.{},
        .chr_ram = &test_chr_ram,
        .prg_ram = &.{},
    };
}

test "the left table is page 0 and the right one moves" {
    const banks = testBanks();
    var m = Cprom.init(.vertical, false);

    // Write a marker into each page through the switchable window.
    for (0..4) |page| {
        m.cpuWrite(banks, 0x8000, @intCast(page), 0);
        m.ppuWrite(banks, 0x1000, @intCast(0xA0 + page));
    }

    // The left table shows page 0's marker whatever is selected.
    for (0..4) |page| {
        m.cpuWrite(banks, 0x8000, @intCast(page), 0);
        try testing.expectEqual(@as(u8, 0xA0), m.ppuRead(banks, 0x0000));
        try testing.expectEqual(@as(u8, @intCast(0xA0 + page)), m.ppuRead(banks, 0x1000));
    }
}

test "only two bank bits are decoded" {
    const banks = testBanks();
    var m = Cprom.init(.vertical, false);
    m.cpuWrite(banks, 0x8000, 0x01, 0);
    m.ppuWrite(banks, 0x1FFF, 0x5A);

    // $FD is page 1 again, not page 61.
    m.cpuWrite(banks, 0x8000, 0xFD, 0);
    try testing.expectEqual(@as(u8, 0x5A), m.ppuRead(banks, 0x1FFF));
}

test "PRG is NROM's: fixed, and a 16 KiB image appears twice" {
    var banks = testBanks();
    test_prg[0x0000] = 0x11;
    test_prg[0x4000] = 0x22;
    var m = Cprom.init(.vertical, false);

    try testing.expectEqual(@as(u8, 0x11), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 0x22), m.cpuRead(banks, 0xC000).?);
    // Selecting a CHR page cannot move PRG, since there is nothing to move.
    m.cpuWrite(banks, 0x8000, 3, 0);
    try testing.expectEqual(@as(u8, 0x11), m.cpuRead(banks, 0x8000).?);

    banks.prg_rom = test_prg[0..0x4000];
    try testing.expectEqual(@as(u8, 0x11), m.cpuRead(banks, 0xC000).?);
}

test "a bank write ANDs with the byte underneath it" {
    const banks = testBanks();
    var m = Cprom.init(.vertical, true);
    m.cpuWrite(banks, 0x8000, 0x03, 0); // $FF underneath, so it passes through
    try testing.expectEqual(@as(u8, 3), m.bank_select);

    test_prg[0x1234] = 0x01;
    m.cpuWrite(banks, 0x9234, 0x03, 0);
    try testing.expectEqual(@as(u8, 1), m.bank_select);
}

// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! Mapper 0 (NROM): no bank switching at all. 16 or 32 KiB of PRG ROM (16 KiB
//! appears twice across $8000-$FFFF), up to 8 KiB of CHR ROM or RAM, fixed
//! mirroring from the header, and an optional 8 KiB PRG RAM window.

const Nrom = @This();
const mapper = @import("mapper.zig");
const Banks = mapper.Banks;
const Mirroring = mapper.Mirroring;

mirroring_mode: Mirroring,

pub fn init(mirroring_mode: Mirroring) Nrom {
    return .{ .mirroring_mode = mirroring_mode };
}

pub fn cpuRead(_: *const Nrom, banks: Banks, addr: u16) ?u8 {
    return switch (addr) {
        0x6000...0x7FFF => banks.readPrgRam(addr),
        0x8000...0xFFFF => banks.readPrgRomMirrored(addr),
        else => null,
    };
}

pub fn cpuWrite(_: *Nrom, banks: Banks, addr: u16, value: u8, _: u64) void {
    switch (addr) {
        0x6000...0x7FFF => banks.writePrgRam(addr, value),
        else => {},
    }
}

pub fn ppuRead(_: *Nrom, banks: Banks, addr: u16) u8 {
    return banks.readChr(addr);
}

pub fn ppuWrite(_: *Nrom, banks: Banks, addr: u16, value: u8) void {
    banks.writeChr(addr, value);
}

pub fn mirroring(self: *const Nrom) Mirroring {
    return self.mirroring_mode;
}

/// Back to the board's power-on registers, keeping its configuration --
/// which describes the cartridge, not its state.
pub fn powerOn(self: *Nrom) void {
    self.* = init(self.mirroring_mode);
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

var test_prg: [0x8000]u8 = undefined;
var test_chr: [0x2000]u8 = undefined;
var test_prg_ram: [0x2000]u8 = undefined;

/// `prg_kib` of PRG ROM stamped with its 16 KiB bank number, plus CHR ROM
/// stamped 0xC0 and 8 KiB of PRG RAM.
fn testBanks(prg_kib: usize) Banks {
    const prg = test_prg[0 .. prg_kib * 1024];
    for (0..prg.len / 0x4000) |bank| @memset(prg[bank * 0x4000 ..][0..0x4000], @intCast(bank));
    @memset(&test_chr, 0xC0);
    @memset(&test_prg_ram, 0);
    return .{
        .prg_rom = prg,
        .chr_rom = &test_chr,
        .chr_ram = &.{},
        .prg_ram = &test_prg_ram,
    };
}

test "a 16 KiB ROM appears in both halves of the CPU window" {
    const banks = testBanks(16);
    var m = Nrom.init(.horizontal);
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0xC000).?);
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0xFFFF).?);
}

test "a 32 KiB ROM fills the window once" {
    const banks = testBanks(32);
    var m = Nrom.init(.horizontal);
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 1), m.cpuRead(banks, 0xC000).?);
}

test "PRG ROM is not writable and unmapped addresses read as open bus" {
    const banks = testBanks(32);
    var m = Nrom.init(.horizontal);
    m.cpuWrite(banks, 0x8000, 0x5A, 0);
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(?u8, null), m.cpuRead(banks, 0x4020));
}

test "the PRG RAM window round-trips and mirrors across its size" {
    const banks = testBanks(32);
    var m = Nrom.init(.horizontal);
    m.cpuWrite(banks, 0x6000, 0x5A, 0);
    try testing.expectEqual(@as(u8, 0x5A), m.cpuRead(banks, 0x6000).?);

    // 8 KiB of RAM covers the window exactly, so nothing aliases; a board
    // with less would.
    var small = banks;
    small.prg_ram = test_prg_ram[0..0x800];
    m.cpuWrite(small, 0x6000, 0x11, 0);
    try testing.expectEqual(@as(u8, 0x11), m.cpuRead(small, 0x6800).?);
}

test "a board with no PRG RAM reads $6000-$7FFF as open bus" {
    var banks = testBanks(32);
    banks.prg_ram = &.{};
    var m = Nrom.init(.horizontal);
    m.cpuWrite(banks, 0x6000, 0x5A, 0); // must not fault
    try testing.expectEqual(@as(?u8, null), m.cpuRead(banks, 0x6000));
}

test "CHR RAM takes precedence over CHR ROM and is writable" {
    var chr_ram = [_]u8{0} ** 0x2000;
    var banks = testBanks(32);
    banks.chr_ram = &chr_ram;

    var m = Nrom.init(.horizontal);
    try testing.expectEqual(@as(u8, 0), m.ppuRead(banks, 0x0000));
    m.ppuWrite(banks, 0x0000, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), m.ppuRead(banks, 0x0000));

    // CHR ROM ignores writes.
    banks.chr_ram = &.{};
    m.ppuWrite(banks, 0x0000, 0x11);
    try testing.expectEqual(@as(u8, 0xC0), m.ppuRead(banks, 0x0000));
}

test "a board with neither CHR ROM nor CHR RAM reads 0 instead of faulting" {
    var banks = testBanks(32);
    banks.chr_rom = &.{};
    var m = Nrom.init(.horizontal);
    m.ppuWrite(banks, 0x0000, 0x5A);
    try testing.expectEqual(@as(u8, 0), m.ppuRead(banks, 0x0000));
}

test "mirroring is whatever the header said, and never changes" {
    var m = Nrom.init(.vertical);
    try testing.expectEqual(Mirroring.vertical, m.mirroring());
    m.cpuWrite(testBanks(32), 0x8000, 0xFF, 0);
    try testing.expectEqual(Mirroring.vertical, m.mirroring());
}

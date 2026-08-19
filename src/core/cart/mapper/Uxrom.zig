//! Mapper 2 (UxROM / UNROM, UOROM): one switchable 16 KiB PRG window at
//! $8000-$BFFF, the last bank wired permanently to $C000-$FFFF, and no CHR
//! banking at all.
//!
//! The fixed half is the whole design. Bank switching is a write to PRG ROM
//! space, so the code doing the switching has to be somewhere that does not
//! move underneath it -- which is why every UxROM game keeps its reset vector,
//! its interrupt handlers and its bank-switch stub in the top 16 KiB.
//!
//! Boards carry no CHR ROM: the 8 KiB of pattern data is RAM the game fills
//! from PRG. That makes `banks.chr()` the CHR RAM, and there is nothing here
//! to bank.

const Uxrom = @This();
const mapper = @import("mapper.zig");
const Banks = mapper.Banks;
const Mirroring = mapper.Mirroring;

const prg_window = 0x4000;

mirroring_mode: Mirroring,
/// Whether a bank write ANDs with the ROM byte underneath it; see `cpuWrite`.
bus_conflicts: bool,
prg_bank: u8 = 0,

pub fn init(mirroring_mode: Mirroring, bus_conflicts: bool) Uxrom {
    return .{ .mirroring_mode = mirroring_mode, .bus_conflicts = bus_conflicts };
}

/// Where `addr` lands in PRG ROM. The fixed window counts from the end so it
/// is the last bank whatever the ROM's size. `Banks.readPrgRom` wraps the
/// result on the length actually present.
fn prgIndex(self: *const Uxrom, banks: Banks, addr: u16) usize {
    const count = @max(banks.prg_rom.len / prg_window, 1);
    const bank = if (addr < 0xC000) @as(usize, self.prg_bank) % count else count - 1;
    return bank * prg_window + (addr & 0x3FFF);
}

pub fn cpuRead(self: *const Uxrom, banks: Banks, addr: u16) ?u8 {
    return switch (addr) {
        0x6000...0x7FFF => banks.readPrgRam(addr),
        0x8000...0xFFFF => banks.readPrgRom(self.prgIndex(banks, addr)),
        else => null,
    };
}

pub fn cpuWrite(self: *Uxrom, banks: Banks, addr: u16, value: u8, _: u64) void {
    switch (addr) {
        0x6000...0x7FFF => banks.writePrgRam(addr, value),
        0x8000...0xFFFF => {
            // The board leaves PRG ROM driving the data bus while the CPU
            // writes, so the two fight and the register latches the AND of
            // them -- the same conflict CNROM has, except that here the byte
            // underneath depends on which bank is currently mapped, so it has
            // to come from this mapper's own read rather than a flat mirror.
            //
            // Software written for the board writes through a table in the
            // fixed half whose entries are the bank numbers themselves, which
            // makes the conflict invisible.
            self.prg_bank = if (self.bus_conflicts)
                value & (self.cpuRead(banks, addr) orelse 0xFF)
            else
                value;
        },
        else => {},
    }
}

pub fn ppuRead(_: *Uxrom, banks: Banks, addr: u16) u8 {
    return banks.readChr(addr);
}

pub fn ppuWrite(_: *Uxrom, banks: Banks, addr: u16, value: u8) void {
    banks.writeChr(addr, value);
}

pub fn mirroring(self: *const Uxrom) Mirroring {
    return self.mirroring_mode;
}

/// Back to the board's power-on registers, keeping its configuration --
/// which describes the cartridge, not its state.
pub fn powerOn(self: *Uxrom) void {
    self.* = init(self.mirroring_mode, self.bus_conflicts);
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

const test_banks_count = 8;
var test_prg: [test_banks_count * prg_window]u8 = undefined;
var test_chr_ram: [0x2000]u8 = undefined;

/// 128 KiB of PRG in 16 KiB banks, each stamped with its own number.
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

test "the low window switches and the high window is always the last bank" {
    const banks = testBanks();
    var m = Uxrom.init(.vertical, false);

    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, test_banks_count - 1), m.cpuRead(banks, 0xC000).?);
    try testing.expectEqual(@as(u8, test_banks_count - 1), m.cpuRead(banks, 0xFFFF).?);

    m.cpuWrite(banks, 0x8000, 5, 0);
    try testing.expectEqual(@as(u8, 5), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 5), m.cpuRead(banks, 0xBFFF).?);
    // The fixed half does not move, which is what makes the switch survivable.
    try testing.expectEqual(@as(u8, test_banks_count - 1), m.cpuRead(banks, 0xC000).?);
}

test "any address in $8000-$FFFF selects, including inside the fixed half" {
    const banks = testBanks();
    var m = Uxrom.init(.vertical, false);
    m.cpuWrite(banks, 0xFFFF, 3, 0);
    try testing.expectEqual(@as(u8, 3), m.cpuRead(banks, 0x8000).?);
}

test "a bank write ANDs with the byte in the bank currently mapped there" {
    const banks = testBanks();
    var m = Uxrom.init(.vertical, true);

    // Bank 7 is fixed at $C000, so $C000 holds 7: writing 5 leaves 5.
    m.cpuWrite(banks, 0xC000, 5, 0);
    try testing.expectEqual(@as(u8, 5), m.cpuRead(banks, 0x8000).?);

    // $8000 now reads bank 5, so a write there ANDs with 5, not with whatever
    // a flat mirror of the ROM would have had. Asking for 3 gets 1.
    m.cpuWrite(banks, 0x8000, 3, 0);
    try testing.expectEqual(@as(u8, 1), m.cpuRead(banks, 0x8000).?);
}

test "the bank number wraps around the cartridge's actual PRG size" {
    var banks = testBanks();
    banks.prg_rom = test_prg[0 .. 2 * prg_window]; // a 32 KiB UNROM
    var m = Uxrom.init(.vertical, false);
    m.cpuWrite(banks, 0x8000, 5, 0); // only banks 0 and 1 exist
    try testing.expectEqual(@as(u8, 1), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 1), m.cpuRead(banks, 0xC000).?);
}

test "CHR is unbanked RAM, and mirroring never changes" {
    const banks = testBanks();
    var m = Uxrom.init(.vertical, false);

    m.ppuWrite(banks, 0x1234, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), m.ppuRead(banks, 0x1234));
    // Selecting a PRG bank must not move pattern data.
    m.cpuWrite(banks, 0x8000, 4, 0);
    try testing.expectEqual(@as(u8, 0x5A), m.ppuRead(banks, 0x1234));

    try testing.expectEqual(Mirroring.vertical, m.mirroring());
}

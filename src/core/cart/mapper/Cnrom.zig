//! Mapper 3 (CNROM): PRG fixed as on NROM, CHR ROM switched in 8 KiB banks by
//! writing anywhere in $8000-$FFFF.
//!
//! Real CNROM boards decode only 2 bits of the bank number, but masking by the
//! cartridge's actual bank count handles both smaller and the rare larger CHR
//! ROMs correctly.

const Cnrom = @This();
const mapper = @import("mapper.zig");
const Banks = mapper.Banks;
const Mirroring = mapper.Mirroring;

const chr_window = 0x2000;

mirroring_mode: Mirroring,
chr_bank: u8 = 0,
/// Whether a bank write ANDs with the ROM byte underneath it; see `cpuWrite`.
bus_conflicts: bool,

pub fn init(mirroring_mode: Mirroring, bus_conflicts: bool) Cnrom {
    return .{ .mirroring_mode = mirroring_mode, .bus_conflicts = bus_conflicts };
}

pub fn cpuRead(_: *const Cnrom, banks: Banks, addr: u16) ?u8 {
    return switch (addr) {
        0x6000...0x7FFF => banks.readPrgRam(addr),
        0x8000...0xFFFF => banks.readPrgRomMirrored(addr),
        else => null,
    };
}

pub fn cpuWrite(self: *Cnrom, banks: Banks, addr: u16, value: u8, _: u64) void {
    switch (addr) {
        0x6000...0x7FFF => banks.writePrgRam(addr, value),
        0x8000...0xFFFF => {
            // The board leaves PRG ROM driving the data bus while the CPU
            // writes, so the two fight and the register latches the AND of
            // them. Software written for the board writes the value already
            // at that address, which makes the conflict invisible; anything
            // else selects a different bank than it asked for.
            self.chr_bank = if (self.bus_conflicts)
                value & (banks.readPrgRomMirrored(addr) orelse 0xFF)
            else
                value;
        },
        else => {},
    }
}

fn chrIndex(self: *const Cnrom, banks: Banks, addr: u16) usize {
    const bank_count = @max(banks.chr_rom.len / chr_window, 1);
    return (@as(usize, self.chr_bank) % bank_count) * chr_window + (addr & 0x1FFF);
}

pub fn ppuRead(self: *Cnrom, banks: Banks, addr: u16) u8 {
    // CHR RAM boards have nothing to switch, so the bank register is bypassed.
    if (banks.chr_ram.len != 0) return banks.readChr(addr);
    return banks.readChr(self.chrIndex(banks, addr));
}

pub fn ppuWrite(_: *Cnrom, banks: Banks, addr: u16, value: u8) void {
    banks.writeChr(addr, value);
}

pub fn mirroring(self: *const Cnrom) Mirroring {
    return self.mirroring_mode;
}

/// Back to the board's power-on registers, keeping its configuration --
/// which describes the cartridge, not its state.
pub fn powerOn(self: *Cnrom) void {
    self.* = init(self.mirroring_mode, self.bus_conflicts);
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

var test_prg: [0x8000]u8 = undefined;
var test_chr: [0x8000]u8 = undefined;

/// 32 KiB of PRG ROM full of $FF, and 4 CHR banks each stamped with its own
/// index.
fn testBanks() Banks {
    @memset(&test_prg, 0xFF);
    for (0..4) |bank| @memset(test_chr[bank * chr_window ..][0..chr_window], @intCast(bank));
    return .{ .prg_rom = &test_prg, .chr_rom = &test_chr, .chr_ram = &.{}, .prg_ram = &.{} };
}

test "a bank write ANDs with the PRG byte underneath it" {
    const banks = testBanks();
    var m = Cnrom.init(.horizontal, true);

    // $FF underneath, so the write passes through untouched.
    m.cpuWrite(banks, 0x8000, 0x03, 0);
    try testing.expectEqual(@as(u8, 3), m.ppuRead(banks, 0x0000));

    // Put $01 under the target address; writing 3 now selects bank 1.
    test_prg[0x1234] = 0x01;
    m.cpuWrite(banks, 0x9234, 0x03, 0);
    try testing.expectEqual(@as(u8, 1), m.ppuRead(banks, 0x0000));

    // Writing the value already there is a no-op, which is what software
    // written for this board does.
    test_prg[0x1235] = 0x02;
    m.cpuWrite(banks, 0x9235, 0x02, 0);
    try testing.expectEqual(@as(u8, 2), m.ppuRead(banks, 0x0000));
}

test "submapper 1 boards have no bus conflict" {
    const banks = testBanks();
    var m = Cnrom.init(.horizontal, false);
    test_prg[0x1234] = 0x01;
    m.cpuWrite(banks, 0x9234, 0x03, 0);
    try testing.expectEqual(@as(u8, 3), m.ppuRead(banks, 0x0000));
}

test "the bank number wraps around the cartridge's actual CHR size" {
    var banks = testBanks();
    banks.chr_rom = test_chr[0 .. 2 * chr_window]; // only 2 banks present
    var m = Cnrom.init(.horizontal, false);
    m.cpuWrite(banks, 0x8000, 3, 0);
    try testing.expectEqual(@as(u8, 1), m.ppuRead(banks, 0x0000));
}

test "a CHR RAM board ignores the bank register and stays writable" {
    var chr_ram = [_]u8{0} ** 0x2000;
    var banks = testBanks();
    banks.chr_ram = &chr_ram;

    var m = Cnrom.init(.horizontal, false);
    m.cpuWrite(banks, 0x8000, 3, 0);
    m.ppuWrite(banks, 0x0000, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), m.ppuRead(banks, 0x0000));
}

//! Mapper 34: two boards that share nothing but a number.
//!
//!  - **BNROM** (Nintendo/Irem): 32 KiB of PRG switched by writing anywhere
//!    in $8000-$FFFF, 8 KiB of unbanked CHR.
//!  - **NINA-001** (American Video Entertainment): the same 32 KiB PRG
//!    window, but switched from three registers sitting *inside* PRG RAM at
//!    $7FFD-$7FFF, plus two independently switched 4 KiB CHR windows.
//!
//! ## Which board a header describes
//!
//! NES 2.0 says outright -- submapper 1 is NINA-001, submapper 2 is BNROM.
//! An iNES 1.0 image has to be told apart by its CHR ROM size, since
//! NINA-001 banks CHR in 4 KiB pages and so carries more than one 8 KiB
//! page, while BNROM has 8 KiB or none. `Cartridge.mapper34Variant` does
//! that; guessing wrong is not subtle, because the two boards do not have a
//! single register address in common.
//!
//! ## Bus conflicts are a property of the board, not of the submapper
//!
//! **Mapper 34 must not be routed through `Cartridge.busConflicts`.** For
//! every other discrete board, submappers 1 and 2 mean "no conflicts" and
//! "conflicts"; here they name boards instead, and the answer follows from
//! the board: BNROM latches from $8000-$FFFF with PRG ROM still driving the
//! bus and always conflicts, while NINA-001 latches from $7FFD-$7FFF, where
//! the byte underneath is RAM, and so cannot.

const Bnrom = @This();
const mapper = @import("mapper.zig");
const Banks = mapper.Banks;
const Mirroring = mapper.Mirroring;

const prg_window = 0x8000;
const chr_window = 0x1000;

pub const Variant = enum { bnrom, nina001 };

variant: Variant,
/// BNROM's is a solder pad and NINA-001's is fixed horizontal, so on both
/// boards the header's bits describe the hardware.
mirroring_mode: Mirroring,
/// The 32 KiB PRG bank, two bits on both boards.
prg_bank: u8 = 0,
/// NINA-001's two 4 KiB CHR windows, $0000 then $1000. Unused on BNROM,
/// whose CHR is unbanked.
///
/// The hardware's power-on value is undefined and games are expected to set
/// it; this powers up at 0 like every other register in this emulator, rather
/// than at the $0000/$1000 pair that would merely *look* right.
chr_banks: [2]u8 = @splat(0),

pub fn init(variant: Variant, mirroring_mode: Mirroring) Bnrom {
    return .{ .variant = variant, .mirroring_mode = mirroring_mode };
}

fn prgIndex(self: *const Bnrom, addr: u16) usize {
    const bank: usize = self.prg_bank & 0x03;
    return bank * prg_window + (addr - 0x8000);
}

pub fn cpuRead(self: *const Bnrom, banks: Banks, addr: u16) ?u8 {
    return switch (addr) {
        // On NINA-001 this window is the board's own 8 KiB of PRG RAM, and
        // reading a register address returns the last value written there --
        // the write went to both the latch and the RAM cell under it, so
        // there is nothing extra to model.
        0x6000...0x7FFF => banks.readPrgRam(addr),
        0x8000...0xFFFF => banks.readPrgRom(self.prgIndex(addr)),
        else => null,
    };
}

pub fn cpuWrite(self: *Bnrom, banks: Banks, addr: u16, value: u8, _: u64) void {
    switch (addr) {
        0x6000...0x7FFF => {
            banks.writePrgRam(addr, value);
            if (self.variant == .nina001) switch (addr) {
                0x7FFD => self.prg_bank = value & 0x03,
                0x7FFE => self.chr_banks[0] = value & 0x0F,
                0x7FFF => self.chr_banks[1] = value & 0x0F,
                else => {},
            };
        },
        0x8000...0xFFFF => {
            if (self.variant != .bnrom) return;
            // See `Cnrom.cpuWrite`: PRG ROM is still driving the bus, so the
            // latch takes the AND. The board has no version without this.
            self.prg_bank = value & (self.cpuRead(banks, addr) orelse 0xFF);
        },
        else => {},
    }
}

pub fn ppuRead(self: *Bnrom, banks: Banks, addr: u16) u8 {
    if (self.variant == .bnrom) return banks.readChr(addr);
    const half = (addr >> 12) & 1;
    const bank: usize = self.chr_banks[half];
    return banks.readChr(bank * chr_window + (addr & 0x0FFF));
}

/// Only BNROM has writable CHR. NINA-001 is a CHR ROM board, where
/// `writeChr` is already a no-op, so neither variant needs the bank here.
pub fn ppuWrite(_: *Bnrom, banks: Banks, addr: u16, value: u8) void {
    banks.writeChr(addr, value);
}

pub fn mirroring(self: *const Bnrom) Mirroring {
    return self.mirroring_mode;
}

/// Back to the board's power-on registers, keeping its configuration --
/// which describes the cartridge, not its state.
pub fn powerOn(self: *Bnrom) void {
    self.* = init(self.variant, self.mirroring_mode);
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

const prg_banks_count = 4;
const chr_banks_count = 16;
var test_prg: [prg_banks_count * prg_window]u8 = undefined;
var test_chr: [chr_banks_count * chr_window]u8 = undefined;
var test_prg_ram: [0x2000]u8 = undefined;

/// 128 KiB of PRG in 32 KiB banks and 64 KiB of CHR in 4 KiB banks, each
/// stamped with its own number, plus the 8 KiB of PRG RAM NINA-001 carries.
fn testBanks() Banks {
    for (0..prg_banks_count) |bank| {
        @memset(test_prg[bank * prg_window ..][0..prg_window], @intCast(bank));
    }
    for (0..chr_banks_count) |bank| {
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

test "BNROM: the whole window switches, and the write ANDs with what is under it" {
    const banks = testBanks();
    var m = Bnrom.init(.bnrom, .vertical);

    // Bank 0 is full of 0, so the board cannot leave it -- the conflict is
    // unconditional here, which is why BNROM software writes through a table
    // of bytes matching their own addresses' contents.
    m.cpuWrite(banks, 0x8000, 0x02, 0);
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0x8000).?);

    test_prg[0x1234] = 0x03;
    m.cpuWrite(banks, 0x9234, 0x02, 0);
    try testing.expectEqual(@as(u8, 2), m.cpuRead(banks, 0x8000).?);
    // No fixed half: the vectors move with everything else.
    try testing.expectEqual(@as(u8, 2), m.cpuRead(banks, 0xFFFF).?);
    try testing.expectEqual(Mirroring.vertical, m.mirroring());
}

test "BNROM: CHR is unbanked and the $7FFD-$7FFF addresses are plain RAM" {
    var chr_ram = [_]u8{0} ** 0x2000;
    var banks = testBanks();
    banks.chr_ram = &chr_ram;
    var m = Bnrom.init(.bnrom, .horizontal);

    // The NINA-001 register addresses must not do anything on this board.
    m.cpuWrite(banks, 0x7FFD, 0x02, 0);
    m.cpuWrite(banks, 0x7FFE, 0x05, 0);
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 0x02), m.cpuRead(banks, 0x7FFD).?);

    m.ppuWrite(banks, 0x1234, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), m.ppuRead(banks, 0x1234));
}

test "NINA-001: the registers live on top of PRG RAM and read back" {
    const banks = testBanks();
    var m = Bnrom.init(.nina001, .horizontal);

    m.cpuWrite(banks, 0x7FFD, 0x03, 0);
    try testing.expectEqual(@as(u8, 3), m.cpuRead(banks, 0x8000).?);
    // The same write landed in the RAM cell underneath, which is the only
    // reason a register that is write-only in the schematic reads back.
    try testing.expectEqual(@as(u8, 0x03), m.cpuRead(banks, 0x7FFD).?);
    // And the rest of the window is ordinary RAM.
    m.cpuWrite(banks, 0x6000, 0xA5, 0);
    try testing.expectEqual(@as(u8, 0xA5), m.cpuRead(banks, 0x6000).?);
}

test "NINA-001: two 4 KiB CHR windows move independently" {
    const banks = testBanks();
    var m = Bnrom.init(.nina001, .horizontal);

    m.cpuWrite(banks, 0x7FFE, 0x0A, 0);
    m.cpuWrite(banks, 0x7FFF, 0x03, 0);
    try testing.expectEqual(@as(u8, 10), m.ppuRead(banks, 0x0000));
    try testing.expectEqual(@as(u8, 10), m.ppuRead(banks, 0x0FFF));
    try testing.expectEqual(@as(u8, 3), m.ppuRead(banks, 0x1000));
    try testing.expectEqual(@as(u8, 3), m.ppuRead(banks, 0x1FFF));
}

test "NINA-001: writes to $8000-$FFFF do nothing at all" {
    const banks = testBanks();
    var m = Bnrom.init(.nina001, .horizontal);

    m.cpuWrite(banks, 0x7FFD, 0x02, 0);
    // There is no latch out here on this board, so a stray write cannot
    // move the window -- which is what the bus-conflict AND would have done
    // had this board been routed through `Cartridge.busConflicts`.
    m.cpuWrite(banks, 0x8000, 0x00, 0);
    try testing.expectEqual(@as(u8, 2), m.cpuRead(banks, 0x8000).?);
}

test "the PRG bank number wraps on the size actually present" {
    var banks = testBanks();
    banks.prg_rom = test_prg[0 .. 2 * prg_window]; // 64 KiB: two banks
    var m = Bnrom.init(.nina001, .horizontal);

    m.cpuWrite(banks, 0x7FFD, 0x03, 0);
    try testing.expectEqual(@as(u8, 1), m.cpuRead(banks, 0x8000).?);
}

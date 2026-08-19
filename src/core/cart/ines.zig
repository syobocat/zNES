// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! The iNES and NES 2.0 file headers: the 16 bytes in front of a ROM image,
//! and what they can and cannot be trusted to say.
//!
//! Pure decoding, and the whole of it. Nothing here knows what a cartridge is
//! -- it turns bytes into sizes and a mapper number, and `Cartridge` decides
//! what to do with them. The three format versions in circulation, and the
//! rules for telling them apart, are the reason this is worth its own file.

const std = @import("std");
const mappers = @import("mapper/mapper.zig");
const Mirroring = mappers.Mirroring;

pub const Error = error{
    InvalidHeader,
    TruncatedRom,
};

pub const magic = [4]u8{ 'N', 'E', 'S', 0x1A };
pub const header_size = 16;
pub const trainer_size = 512;
pub const prg_bank_size = 16 * 1024;
pub const chr_bank_size = 8 * 1024;

/// Storage for the on-cartridge RAMs, sized for the largest board mapped here:
/// SXROM's 32 KiB of bank-switched PRG RAM. A header asking for more is
/// clamped to this.
pub const max_ram_size = 32 * 1024;

/// What an iNES 1.0 header is taken to carry. The format cannot express "no
/// WRAM" -- byte 8's value 0 means 8 KiB for compatibility -- and cannot
/// reliably express more either, so 1.0 images get the classic single bank and
/// only NES 2.0 byte 10 can ask for a different amount. This matters beyond
/// capacity: `Mmc1` treats "more than 8 KiB" as its SOROM/SXROM detection, so
/// handing every 1.0 image 32 KiB would switch banks on boards without them.
pub const ines1_ram_size = 8 * 1024;

/// Which of the three headers actually in circulation this image carries.
///
/// Only bytes 0-6 mean the same thing in all three. Everything from byte 7 up
/// was added later, on top of a field that early tools left full of whatever
/// happened to be in memory -- most famously the string "DiskDude!", which an
/// old copier wrote across bytes 7-15 and which puts `D` ($44) in the byte
/// that now holds the mapper's high nibble. Reading that byte unconditionally
/// turns mapper 4 into mapper 68, so the version has to be established before
/// any of it is believed.
pub const Format = enum {
    /// Bytes 7-15 are not trustworthy and are ignored entirely.
    archaic,
    /// Byte 7's high nibble and byte 8 onward mean what iNES 1.0 says.
    ines1,
    nes2,

    /// A sequence of *disqualifications* rather than a version field: an
    /// image is only read as the newer format once it has given positive
    /// evidence for it.
    pub fn detect(bytes: *const [header_size]u8, file_len: usize) Format {
        if ((bytes[7] & 0x0C) == 0x08 and nes2SizesFit(bytes, file_len)) return .nes2;
        // Bytes 12-15 are reserved and zero in a real 1.0 header, so anything
        // there is the tail of a string someone wrote over the whole region.
        if ((bytes[7] & 0x0C) == 0x00 and std.mem.allEqual(u8, bytes[12..16], 0)) return .ines1;
        return .archaic;
    }

    /// Whether the NES 2.0 reading of the ROM areas fits inside the file.
    ///
    /// This is the other half of the $08 test, and it is what keeps a byte of
    /// junk from being read as a version marker: bits 3-2 of a random byte are
    /// `%10` one time in four, but a junk byte 9 then almost always claims
    /// hundreds of megabytes of ROM that the file plainly does not have.
    pub fn nes2SizesFit(bytes: *const [header_size]u8, file_len: usize) bool {
        const trainer: usize = if ((bytes[6] & 0x04) != 0) trainer_size else 0;
        const prg = romAreaSize(bytes[4], @truncate(bytes[9] & 0x0F), prg_bank_size);
        const chr = romAreaSize(bytes[5], @truncate(bytes[9] >> 4), chr_bank_size);
        const total = std.math.add(usize, header_size + trainer, prg) catch return false;
        return (std.math.add(usize, total, chr) catch return false) <= file_len;
    }
};

/// Everything `load` needs out of the 16 header bytes, with the header
/// versions' differences already resolved.
pub const Header = struct {
    mapper_number: u16,
    submapper: u4,
    mirroring: Mirroring,
    has_trainer: bool,
    prg_rom_len: usize,
    chr_rom_len: usize,
    prg_ram_len: usize,
    prg_nvram_len: usize,
    chr_ram_len: usize,

    has_battery: bool,

    pub fn parse(bytes: *const [header_size]u8, file_len: usize) Error!Header {
        if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidHeader;

        const format = Format.detect(bytes, file_len);
        const flags6 = bytes[6];
        const flags7 = bytes[7];
        const is_nes20 = format == .nes2;
        const chr_rom_len = if (is_nes20)
            romAreaSize(bytes[5], @truncate(bytes[9] >> 4), chr_bank_size)
        else
            @as(usize, bytes[5]) * chr_bank_size;

        // Byte 6 is common to all three header versions, so this bit is
        // readable even on an archaic image. NES 2.0 says the same thing a
        // second time, as a non-zero NVRAM shift count in byte 10's high
        // nibble, and either is enough: a board with battery-backed WRAM
        // declared only the newer way still has a battery.
        const has_battery = (flags6 & 0x02) != 0 or (is_nes20 and (bytes[10] >> 4) != 0);
        const prg_ram_len: usize = if (is_nes20) ramAreaSize(bytes[10]) else ines1_ram_size;
        // How much of that area the battery holds up. Only NES 2.0 can say;
        // an older header knows a battery exists but not which chip it feeds,
        // so the whole area counts as saved -- the safe direction, since a
        // save that carries some scratch along costs nothing and a save that
        // drops half of itself is gone.
        const declared_nvram: usize = if (is_nes20)
            @min(nvramAreaSize(bytes[10]), prg_ram_len)
        else
            0;
        const prg_nvram_len: usize = if (declared_nvram != 0)
            declared_nvram
        else if (has_battery) prg_ram_len else 0;

        // An archaic header only has the low nibble; taking the high one
        // from a byte holding text is the DiskDude bug.
        const mapper_number = @as(u16, flags6 >> 4) |
            (if (format == .archaic) 0 else @as(u16, flags7 & 0xF0)) |
            if (is_nes20) @as(u16, bytes[8] & 0x0F) << 8 else 0;

        return .{
            .mapper_number = mapper_number,
            .submapper = if (is_nes20) @truncate(bytes[8] >> 4) else 0,
            .mirroring = if ((flags6 & 0x08) != 0)
                .four_screen
            else if ((flags6 & 0x01) != 0) .vertical else .horizontal,
            .has_trainer = (flags6 & 0x04) != 0,
            .has_battery = has_battery,
            // NES 2.0 widens both ROM sizes with a nibble out of byte 9; the
            // older headers have only the byte, counting 16 KiB / 8 KiB units.
            .prg_rom_len = if (is_nes20)
                romAreaSize(bytes[4], @truncate(bytes[9] & 0x0F), prg_bank_size)
            else
                @as(usize, bytes[4]) * prg_bank_size,
            .chr_rom_len = chr_rom_len,
            .prg_ram_len = prg_ram_len,
            .prg_nvram_len = prg_nvram_len,
            .chr_ram_len = boardChrRam(mapper_number, if (is_nes20)
                ramAreaSize(bytes[11])
            else
                // The older headers say nothing about CHR RAM, so "no CHR ROM"
                // is the only signal that the board must have some.
                (if (chr_rom_len == 0) ines1_ram_size else 0)),
        };
    }
};

/// CHR RAM a board is known to carry but its header cannot declare.
///
/// iNES 1.0 has no field for CHR RAM at all -- "the image has no CHR ROM" is
/// the only signal, and it can only mean the usual 8 KiB. A board with a
/// different amount is therefore recognisable by mapper number and nothing
/// else, so that is what this does. NES 2.0 images say it properly in byte
/// 11 and come out of here unchanged, since the floor is what the board has.
pub fn boardChrRam(mapper_number: u16, declared: usize) usize {
    return switch (mapper_number) {
        // CPROM banks four 4 KiB pages. No 1.0 header can ask for 16 KiB.
        13 => @max(declared, 4 * 4 * 1024),
        // TQROM carries 8 KiB of CHR RAM *alongside* its CHR ROM, which iNES
        // 1.0 cannot express at all: there, CHR RAM is what a board has when
        // it has no CHR ROM.
        119 => @max(declared, 8 * 1024),
        else => declared,
    };
}

/// PRG ROM / CHR ROM area size from its LSB byte and 4-bit MSB nibble.
///
/// The plain form is a `unit`-sized count. MSB nibble $F is an escape that
/// packs an exponent and an odd multiplier into the LSB byte instead, for
/// sizes the count cannot express:
///
///     1111 EEEE EEMM   ->   2^E * (MM*2+1) bytes
pub fn romAreaSize(lsb: u8, msb: u4, unit: usize) usize {
    if (msb != 0x0F) return ((@as(usize, msb) << 8) | lsb) * unit;
    const exponent: u6 = @truncate(lsb >> 2);
    const multiplier: u64 = @as(u64, lsb & 0x03) * 2 + 1;
    // Worked out in 64 bits and saturated, so the answer does not depend on
    // how wide a pointer is: the exponent goes up to 63, which overflows the
    // shift on a 32-bit target long before it overflows the value. Nothing
    // real comes anywhere near either limit, and a saturated size is caught
    // by `load`'s length check.
    if (exponent >= 63) return std.math.maxInt(usize);
    const size = (@as(u64, 1) << exponent) * multiplier;
    return std.math.cast(usize, size) orelse std.math.maxInt(usize);
}

/// One nibble of a NES 2.0 RAM-size byte: a shift count where 0 means no such
/// chip and otherwise the size is `64 << count`.
pub fn ramShiftSize(shift: u4) usize {
    return if (shift == 0) 0 else @as(usize, 64) << shift;
}

/// The non-volatile part of a NES 2.0 RAM-size byte -- the high nibble alone.
pub fn nvramAreaSize(byte: u8) usize {
    return @min(ramShiftSize(@truncate(byte >> 4)), max_ram_size);
}

/// Total PRG RAM or CHR RAM area size from its NES 2.0 header byte: a volatile
/// shift count in the low nibble and a non-volatile one in the high nibble.
///
/// **The two nibbles are two separate chips, so the area is their sum.** Only
/// one of them being non-zero is the common case -- a single chip, battery or
/// not -- but boards that declare both are real: 8 KiB of PRG-RAM plus 8 KiB
/// of PRG-NVRAM alongside 16 KiB or more of CHR is exactly what identifies an
/// SZROM, and SOROM is the same shape. Both carry two 8 KiB PRG RAM chips with
/// the battery wired to only the second one.
///
/// Folding the pair with `@max` would hand those boards 8 KiB, and that is not
/// merely half the memory: `Mmc1.prgRamBank` keys the whole SOROM/SZROM/SXROM
/// WRAM bank select off the area being larger than one 8 KiB window, so the
/// bank select would go dead too and both chips would land on top of each
/// other.
pub fn ramAreaSize(byte: u8) usize {
    const volatile_size = ramShiftSize(@truncate(byte & 0x0F));
    return @min(volatile_size + nvramAreaSize(byte), max_ram_size);
}

// --- Tests ---------------------------------------------------------------

const testing = std.testing;

test "the exponent form is decoded as 2^E * (MM*2+1)" {
    // MSB nibble $F switches the LSB byte to `EEEEEEMM`.
    try testing.expectEqual(@as(usize, 8192), romAreaSize((13 << 2) | 0, 0x0F, prg_bank_size));
    try testing.expectEqual(@as(usize, 3072), romAreaSize((10 << 2) | 1, 0x0F, prg_bank_size));
    // The plain form still counts units.
    try testing.expectEqual(@as(usize, 2 * prg_bank_size), romAreaSize(2, 0, prg_bank_size));
}

test "a RAM shift count of 0 is no RAM, not the smallest RAM" {
    try testing.expectEqual(@as(usize, 0), ramShiftSize(0));
    try testing.expectEqual(@as(usize, 128), ramShiftSize(1));
    try testing.expectEqual(@as(usize, 8 * 1024), ramShiftSize(7));
}

test "the two RAM nibbles are separate chips, so the area is their sum" {
    // 8 KiB volatile in the low nibble plus 8 KiB battery-backed in the high
    // one is the SOROM/SZROM header: two chips, so 16 KiB.
    try testing.expectEqual(@as(usize, 16 * 1024), ramAreaSize(0x77));
    // Only the high nibble is what `batteryRam` writes out.
    try testing.expectEqual(@as(usize, 8 * 1024), nvramAreaSize(0x77));
    // A single chip either way.
    try testing.expectEqual(@as(usize, 8 * 1024), ramAreaSize(0x07));
    try testing.expectEqual(@as(usize, 8 * 1024), ramAreaSize(0x70));
}

// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! iNES / NES 2.0 ROM loading, and the storage a cartridge board carries.
//!
//! **A cartridge borrows the ROM image it was loaded from.** `prg_rom` and
//! `chr_rom` point into the caller's buffer, which must therefore outlive the
//! `Cartridge`. Nothing writes through them -- mappers only ever get
//! `[]const u8` -- so there is no reason to copy, and not copying is what lets
//! this type allocate nothing at all: the only writable memory a cartridge
//! owns is bounded by `max_ram_size` and stored inline.
//!
//! That leaves no allocator to keep and nothing to free, so there is no
//! `deinit`. A caller that needs to release the ROM image immediately must
//! copy it itself rather than making every cartridge pay for a copy.

const std = @import("std");
const Cartridge = @This();
// One import, not eleven: which mapper number is which board is the mapper
// package's business, and this file's only job is to hand it a `Config`.
// Named `mappers` because `mapper` is a field of this struct.
const mappers = @import("mapper/mapper.zig");
const Banks = mappers.Banks;
const Mapper = mappers.Mapper;
const Mirroring = mappers.Mirroring;

/// The header parser. Everything about how those 16 bytes are laid out, and
/// which of them can be believed, lives there rather than here.
const ines = @import("ines.zig");
const Header = ines.Header;
const header_size = ines.header_size;
const trainer_size = ines.trainer_size;
const max_ram_size = ines.max_ram_size;
const magic = ines.magic;
const prg_bank_size = ines.prg_bank_size;
const chr_bank_size = ines.chr_bank_size;
const ines1_ram_size = ines.ines1_ram_size;

pub const LoadError = ines.Error || mappers.UnsupportedMapper;

/// Borrowed from the caller's ROM image.
prg_rom: []const u8,
/// Borrowed too, and empty when the board uses CHR RAM instead -- which is
/// what `usesChrRam` reports. Which storage a mapper actually reads is
/// decided by `chr_ram_len` rather than by this, because TQROM has both.
chr_rom: []const u8,
/// Backing store for the writable RAMs; `chr_ram_len` / `prg_ram_len` say how
/// much of each the board actually wires up, and `banks` slices to those.
chr_ram: [max_ram_size]u8,
prg_ram: [max_ram_size]u8,
chr_ram_len: usize,
prg_ram_len: usize,
/// How much of `prg_ram` sits behind the battery, counted from the *end* of
/// the area. NES 2.0 splits the two in byte 10 and hardware really does have
/// them as separate chips, with the volatile one first. See `batteryRam`.
prg_nvram_len: usize,

/// The second 2 KiB of nametable RAM, which lives on the cartridge on
/// four-screen boards. The console itself only ever has 2 KiB, so a 64x60
/// tilemap is only possible because the board brings its own -- which is why
/// this is here and not in `Ppu`. Untouched on every other board.
ci_ram: [0x800]u8,

mapper: Mapper,
/// NES 2.0 submapper number, 0 for an iNES 1.0 header. Selects between board
/// variants that share a mapper number, such as CNROM with and without bus
/// conflicts.
submapper: u4,

/// Whether the board keeps its PRG RAM alive with a battery, so its contents
/// are a save file rather than scratch space. See `batteryRam`.
has_battery: bool,

/// Whether anything has written into the $6000-$7FFF window since this was
/// last cleared. Read it through `takeBatteryRamDirty`.
///
/// The point is to let a frontend persist a save when it changes instead of on
/// a timer: a game writes its save perhaps a handful of times a session, and
/// nothing else the console does touches this window.
battery_ram_dirty: bool = false,

/// `rom_bytes` must outlive the returned cartridge.
pub fn load(rom_bytes: []const u8) LoadError!Cartridge {
    if (rom_bytes.len < header_size) return error.TruncatedRom;
    const header = try Header.parse(rom_bytes[0..header_size], rom_bytes.len);

    const trainer: usize = if (header.has_trainer) trainer_size else 0;
    const prg_start = header_size + trainer;
    const chr_start = prg_start + header.prg_rom_len;
    const chr_end = chr_start + header.chr_rom_len;
    if (rom_bytes.len < chr_end) return error.TruncatedRom;

    return .{
        .prg_rom = rom_bytes[prg_start..chr_start],
        .chr_rom = rom_bytes[chr_start..chr_end],
        .chr_ram = @splat(0),
        .prg_ram = @splat(0),
        .chr_ram_len = header.chr_ram_len,
        .prg_ram_len = header.prg_ram_len,
        .prg_nvram_len = header.prg_nvram_len,
        .ci_ram = @splat(0),
        .mapper = try Mapper.fromConfig(.{
            .number = header.mapper_number,
            .submapper = header.submapper,
            .mirroring = header.mirroring,
            .chr_rom_len = header.chr_rom_len,
        }),
        .submapper = header.submapper,
        // A board can only save what it has: a battery bit on a header that
        // declares no WRAM describes nothing.
        .has_battery = header.has_battery and header.prg_ram_len != 0,
    };
}

/// Whether the header declared no CHR ROM, so the board carries writable CHR
/// RAM instead.
pub fn usesChrRam(self: *const Cartridge) bool {
    return self.chr_rom.len == 0;
}

/// The bytes that survive a power cut on this board, i.e. the save file --
/// empty on a board with no battery, which is most of them.
///
/// This is the *non-volatile* part of PRG RAM, which on nearly every board is
/// all of it. The exceptions are the two-chip boards -- SOROM and SZROM carry
/// 8 KiB of plain WRAM plus 8 KiB behind the battery, and it is the *second*
/// chip that retains its data. So the saved half is the tail of the area, and
/// `prg_nvram_len` is how long it is.
///
/// A header that claims a battery without splitting the area -- every iNES 1.0
/// image with the bit set, and any NES 2.0 one that leaves byte 10's high
/// nibble clear -- gets the whole area saved instead. Carrying a few KiB of
/// scratch along costs nothing; guessing away half of a real save does not.
///
/// **A frontend restoring a save must not resize this.** The length is the
/// board's, decided by the header; a file of a different length belongs to a
/// different board and `loadBatteryRam` refuses it.
pub fn batteryRam(self: *Cartridge) []u8 {
    if (!self.has_battery) return &.{};
    return self.prg_ram[self.prg_ram_len - self.prg_nvram_len ..][0..self.prg_nvram_len];
}

/// Restores a previously saved `batteryRam`, reporting whether it fit.
///
/// Refusing a mismatched length rather than padding or truncating is what
/// keeps a save from one game out of another's RAM: the file name a frontend
/// keys on is the ROM's, and ROMs get renamed.
///
/// **For a frontend that can hand over the whole stored file.** The ones in
/// this repository instead have their platform read straight into
/// `batteryRam`, because a platform is the only thing that can say how long
/// the file it found was, and a partial read must not become a save.
pub fn loadBatteryRam(self: *Cartridge, bytes: []const u8) bool {
    const ram = self.batteryRam();
    if (ram.len == 0 or bytes.len != ram.len) return false;
    @memcpy(ram, bytes);
    // Restoring is not a change worth writing back out.
    self.battery_ram_dirty = false;
    return true;
}

/// What this cartridge is, independent of the file it arrived in.
///
/// A frontend keys a save on the ROM's file name, which is what a player
/// renames. Carrying this in the save lets one be recognised as belonging to
/// this cartridge whatever it ended up being called, and lets a save that only
/// shares a name be refused.
pub const Fingerprint = struct {
    prg_len: u32,
    chr_len: u32,
    digest: [16]u8,
};

/// Identifies the cartridge by what is on it, so that a corrected header does
/// not disown a save.
///
/// The hash covers PRG then CHR and nothing else -- fixing a wrong mapper
/// number or promoting a dump to NES 2.0 rewrites only the header, and a
/// player who does that should keep their save.
///
/// SipHash-2-4 rather than a hash-table hash, whose output std is free to
/// change between releases: a changed digest would disown every save at once.
/// This one is pinned to the reference implementation's test vectors, and it
/// mixes well enough for images that are mostly padding and often share whole
/// banks with another game. It is not defending against anyone -- nothing is
/// gained by colliding two saves -- so the key is a constant.
pub fn fingerprint(self: *const Cartridge) Fingerprint {
    var hash = std.hash.SipHash128(2, 4).init(&fingerprint_key);
    hash.update(self.prg_rom);
    hash.update(self.chr_rom);
    var digest: [16]u8 = undefined;
    hash.final(&digest);
    return .{
        .prg_len = @intCast(self.prg_rom.len),
        .chr_len = @intCast(self.chr_rom.len),
        .digest = digest,
    };
}

const fingerprint_key: [16]u8 = @splat(0);

/// Whether `batteryRam` has been written since the last call, clearing the
/// flag. See `battery_ram_dirty`.
pub fn takeBatteryRamDirty(self: *Cartridge) bool {
    defer self.battery_ram_dirty = false;
    return self.battery_ram_dirty;
}

fn banks(self: *Cartridge) Banks {
    return .{
        .prg_rom = self.prg_rom,
        .chr_rom = self.chr_rom,
        // Empty on a board with no CHR RAM, since an empty slice is how
        // every mapper tells the two kinds apart. The *length* decides that,
        // not the absence of CHR ROM: TQROM carries both at once.
        .chr_ram = self.chr_ram[0..self.chr_ram_len],
        // Likewise a board with no WRAM: every mapper answers open bus for
        // $6000-$7FFF when handed an empty slice, so this is all of that
        // behavior.
        .prg_ram = self.prg_ram[0..self.prg_ram_len],
    };
}

pub fn cpuRead(self: *Cartridge, addr: u16) ?u8 {
    return self.mapper.cpuRead(self.banks(), addr);
}

pub fn cpuWrite(self: *Cartridge, addr: u16, value: u8, cycle: u64) void {
    // Noted here rather than in `Banks.writePrgRam` because this is the one
    // place every mapper's writes pass through, so no mapper can forget to
    // mark a save dirty. A mapper that drops the write (a board with the
    // window disabled, say) leaves the flag set for nothing, which costs one
    // redundant save file.
    if (self.has_battery and addr >= 0x6000 and addr < 0x8000) self.battery_ram_dirty = true;
    self.mapper.cpuWrite(self.banks(), addr, value, cycle);
}

pub fn ppuRead(self: *Cartridge, addr: u16) u8 {
    return self.mapper.ppuRead(self.banks(), addr);
}

pub fn ppuWrite(self: *Cartridge, addr: u16, value: u8) void {
    self.mapper.ppuWrite(self.banks(), addr, value);
}

/// `cpuRead` for a debugger or a test: guaranteed not to disturb anything.
///
/// The same call as `cpuRead`, rather than a second implementation that could
/// drift out of step. `Mapper.cpuRead` takes `*const`, so no mapper can mutate
/// through it; the cast is only needed because `banks()` hands out the
/// writable RAM slices the *write* path needs, and building those from a
/// `*const Cartridge` is what Zig will not allow. (Copying `self` to get a
/// mutable one would copy tens of KiB per byte inspected.)
pub fn inspect(self: *const Cartridge, addr: u16) ?u8 {
    return @constCast(self).cpuRead(addr);
}

pub fn mirroring(self: *Cartridge) Mirroring {
    return self.mapper.mirroring();
}

/// Puts the mapper's registers back to their power-on values, leaving the ROM
/// slices and the RAM contents (which hardware does not clear either) alone.
///
/// Rebuilt from the board's own configuration rather than zeroed, because some
/// mappers' power-on state is not all-zero: MMC1 comes up in PRG mode 3, and
/// CNROM has to remember whether its board has bus conflicts.
pub fn powerOn(self: *Cartridge) void {
    self.mapper.powerOn();
}

// --- Tests ---------------------------------------------------------------

const testing = std.testing;

/// A 16 KiB-PRG image with a valid header, plus whichever header bytes the
/// caller overrides. Byte 4 is 1 so the declared PRG area matches the buffer.
const TestRom = [header_size + prg_bank_size]u8;

fn testRom(bytes: *TestRom, overrides: []const struct { usize, u8 }) void {
    @memset(bytes, 0);
    bytes[0..4].* = magic;
    bytes[4] = 1;
    for (overrides) |pair| bytes[pair[0]] = pair[1];
}

test "a fingerprint follows the ROM's contents, not its header" {
    var plain: TestRom = undefined;
    testRom(&plain, &.{});
    // The same PRG, in an image whose header was later corrected -- here a
    // dump that had forgotten to declare the battery.
    var corrected: TestRom = undefined;
    testRom(&corrected, &.{.{ 6, 0x02 }});
    for (header_size..plain.len) |i| {
        plain[i] = @truncate(i * 31);
        corrected[i] = @truncate(i * 31);
    }

    const a = (try Cartridge.load(&plain)).fingerprint();
    const b = (try Cartridge.load(&corrected)).fingerprint();
    // Equal, or every header fix in a ROM set would orphan a save.
    try testing.expectEqualSlices(u8, &a.digest, &b.digest);
    try testing.expectEqual(a.prg_len, b.prg_len);

    // And a single byte of PRG is enough to make it a different cartridge.
    var patched: TestRom = undefined;
    testRom(&patched, &.{});
    for (header_size..patched.len) |i| patched[i] = @truncate(i * 31);
    patched[header_size] +%= 1;
    const c = (try Cartridge.load(&patched)).fingerprint();
    try testing.expect(!std.mem.eql(u8, &a.digest, &c.digest));
}

test "loads a minimal 32K/8K NROM header" {
    var rom_bytes: [header_size + prg_bank_size * 2 + chr_bank_size]u8 = undefined;
    @memset(&rom_bytes, 0xAB);
    rom_bytes[0..4].* = magic;
    rom_bytes[4] = 2; // 32 KiB PRG
    rom_bytes[5] = 1; // 8 KiB CHR
    @memset(rom_bytes[6..header_size], 0);
    rom_bytes[header_size] = 0x42; // first PRG byte, distinguishable

    var cart = try Cartridge.load(&rom_bytes);

    try testing.expectEqual(@as(usize, prg_bank_size * 2), cart.prg_rom.len);
    try testing.expectEqual(@as(usize, chr_bank_size), cart.chr_rom.len);
    try testing.expect(!cart.usesChrRam());
    try testing.expectEqual(Mirroring.horizontal, cart.mirroring());
    try testing.expectEqual(@as(u8, 0x42), cart.cpuRead(0x8000).?);
}

test "16K PRG mirrors across both halves of the CPU window" {
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{.{ header_size, 0x77 }});

    var cart = try Cartridge.load(&rom_bytes);
    try testing.expectEqual(@as(u8, 0x77), cart.cpuRead(0x8000).?);
    try testing.expectEqual(@as(u8, 0x77), cart.cpuRead(0xC000).?);
    try testing.expect(cart.usesChrRam());
}

test "ROM regions alias the caller's buffer rather than copying it" {
    // The property the whole type is built on: it is what removes the
    // allocator, and what makes the caller responsible for keeping the ROM
    // image alive. Reintroducing a copy would break that contract silently.
    var rom_bytes: [header_size + prg_bank_size + chr_bank_size]u8 = undefined;
    @memset(&rom_bytes, 0);
    rom_bytes[0..4].* = magic;
    rom_bytes[4] = 1;
    rom_bytes[5] = 1;

    const cart = try Cartridge.load(&rom_bytes);
    try testing.expectEqual(@intFromPtr(&rom_bytes[header_size]), @intFromPtr(cart.prg_rom.ptr));
    try testing.expectEqual(
        @intFromPtr(&rom_bytes[header_size + prg_bank_size]),
        @intFromPtr(cart.chr_rom.ptr),
    );

    // A cartridge owns nothing beyond its own bytes, so the struct is the two
    // ROM slices, the fixed RAM arrays and the mapper.
    try testing.expect(@sizeOf(Cartridge) < 2 * max_ram_size + 0x800 + 128);
}

test "a trainer shifts the PRG area past it" {
    var rom_bytes: [header_size + trainer_size + prg_bank_size]u8 = undefined;
    @memset(&rom_bytes, 0);
    rom_bytes[0..4].* = magic;
    rom_bytes[4] = 1;
    rom_bytes[6] = 0x04; // trainer present
    rom_bytes[header_size + trainer_size] = 0x99;

    var cart = try Cartridge.load(&rom_bytes);
    try testing.expectEqual(@as(u8, 0x99), cart.cpuRead(0x8000).?);
}

test "rejects bad magic, short files and unsupported mappers" {
    var bad = [_]u8{0} ** header_size;
    try testing.expectError(error.InvalidHeader, Cartridge.load(&bad));

    var short = magic ++ [_]u8{0} ** 4;
    try testing.expectError(error.TruncatedRom, Cartridge.load(&short));

    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{.{ 6, 0xF0 }}); // mapper 15
    try testing.expectError(error.UnsupportedMapper, Cartridge.load(&rom_bytes));
}

test "the header's mirroring bits pick horizontal, vertical or four-screen" {
    var rom_bytes: TestRom = undefined;
    const cases = [_]struct { u8, Mirroring }{
        .{ 0x00, .horizontal },
        .{ 0x01, .vertical },
        .{ 0x08, .four_screen },
        .{ 0x09, .four_screen }, // the four-screen bit wins
    };
    for (cases) |case| {
        testRom(&rom_bytes, &.{.{ 6, case[0] }});
        var cart = try Cartridge.load(&rom_bytes);
        try testing.expectEqual(case[1], cart.mirroring());
    }
}

test "NES 2.0: a PRG-RAM shift count of zero means the board has no WRAM" {
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{ .{ 7, 0x08 }, .{ 10, 0x00 } });

    var cart = try Cartridge.load(&rom_bytes);
    try testing.expectEqual(@as(usize, 0), cart.prg_ram_len);
    try testing.expectEqual(@as(?u8, null), cart.cpuRead(0x6000));

    // A write must not fabricate storage either.
    cart.cpuWrite(0x6000, 0x5A, 0);
    try testing.expectEqual(@as(?u8, null), cart.cpuRead(0x6000));
}

test "NES 2.0: a non-zero PRG-RAM shift count gives 64 << count bytes of WRAM" {
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{ .{ 7, 0x08 }, .{ 10, 0x07 } }); // 64 << 7 = 8 KiB

    var cart = try Cartridge.load(&rom_bytes);
    try testing.expectEqual(@as(usize, 8 * 1024), cart.prg_ram_len);
    cart.cpuWrite(0x6000, 0x5A, 0);
    try testing.expectEqual(@as(u8, 0x5A), cart.cpuRead(0x6000).?);
}

test "NES 2.0: battery-backed WRAM counts toward the size" {
    // No volatile WRAM and 32 KiB of battery-backed WRAM is the SXROM shape,
    // and what `Mmc1.prgRamBank` needs in order to have banks to switch.
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{ .{ 7, 0x08 }, .{ 10, 0x90 } });

    const cart = try Cartridge.load(&rom_bytes);
    try testing.expectEqual(@as(usize, max_ram_size), cart.prg_ram_len);
}

test "NES 2.0: two declared RAM chips add up instead of folding together" {
    // 8 KiB volatile + 8 KiB battery-backed is the SOROM/SZROM header, and
    // is what identifies an SZROM. The board really has two chips, so the
    // area is 16 KiB -- and that is what makes `Mmc1.prgRamBank` switch banks
    // at all.
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{ .{ 7, 0x08 }, .{ 10, 0x77 } });

    const cart = try Cartridge.load(&rom_bytes);
    try testing.expectEqual(@as(usize, 16 * 1024), cart.prg_ram_len);
    try testing.expectEqual(@as(usize, 8 * 1024), cart.prg_nvram_len);
    try testing.expect(cart.has_battery);
}

test "the save is the battery-backed chip alone when the header splits them" {
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{ .{ 7, 0x08 }, .{ 10, 0x77 } });

    var cart = try Cartridge.load(&rom_bytes);
    const save = cart.batteryRam();
    try testing.expectEqual(@as(usize, 8 * 1024), save.len);

    // "The first RAM chip will not retain its data, but the second one will":
    // the save is the tail of the area, not the head.
    cart.prg_ram[0] = 0x11;
    cart.prg_ram[8 * 1024] = 0x22;
    try testing.expectEqual(@as(u8, 0x22), save[0]);
}

test "a battery with no declared split still saves the whole area" {
    // iNES 1.0 cannot name the chip, and neither can a NES 2.0 header that
    // sets the battery bit but leaves byte 10's high nibble clear.
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{ .{ 6, 0x02 }, .{ 7, 0x08 }, .{ 10, 0x07 } });

    var cart = try Cartridge.load(&rom_bytes);
    try testing.expectEqual(@as(usize, 8 * 1024), cart.prg_ram_len);
    try testing.expectEqual(@as(usize, 8 * 1024), cart.batteryRam().len);
}

test "iNES 1.0 always gets one bank of WRAM, because the format cannot say otherwise" {
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{.{ 8, 0x00 }});

    var cart = try Cartridge.load(&rom_bytes);
    // One bank, not `max_ram_size`: handing 1.0 images the full 32 KiB would
    // make `Mmc1` read every one of them as an SXROM board.
    try testing.expectEqual(@as(usize, ines1_ram_size), cart.prg_ram_len);
    cart.cpuWrite(0x6000, 0x5A, 0);
    try testing.expectEqual(@as(u8, 0x5A), cart.cpuRead(0x6000).?);
}

test "NES 2.0: byte 9 extends the ROM sizes past what one byte can hold" {
    // A PRG MSB nibble of 1 means 256 more 16 KiB units than byte 4 alone can
    // express, i.e. 4 MiB. Checking the decoded size rather than loading a
    // 4 MiB buffer keeps the test cheap; that the size is *believed* is what
    // the fallback test below covers.
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{ .{ 7, 0x08 }, .{ 9, 0x01 } });
    try testing.expect(!ines.Format.nes2SizesFit(rom_bytes[0..header_size], rom_bytes.len));
    try testing.expect(ines.Format.nes2SizesFit(rom_bytes[0..header_size], header_size + 257 * prg_bank_size));

    // The same header read as iNES 1.0 ignores byte 9 and loads fine.
    testRom(&rom_bytes, &.{.{ 9, 0x01 }});
    _ = try Cartridge.load(&rom_bytes);
}

test "a DiskDude header does not turn mapper 4 into mapper 68" {
    // The canonical junk header: an old copier wrote "DiskDude!" across bytes
    // 7-15, so byte 7 holds `D` ($44) and its high nibble reads as $40 -- four
    // more mapper bits that were never meant to be there.
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{.{ 6, 0x40 }}); // mapper 4's low nibble
    @memcpy(rom_bytes[7..16], "DiskDude!");

    const cart = try Cartridge.load(&rom_bytes);
    try testing.expect(cart.mapper == .mmc3);

    // Bytes 8-15 go with it: byte 8's `i` must not become a submapper, and
    // byte 10's `d` must not be read as a PRG-RAM shift count.
    try testing.expectEqual(@as(u4, 0), cart.submapper);
    try testing.expectEqual(@as(usize, ines1_ram_size), cart.prg_ram_len);
}

test "any junk in bytes 12-15 disqualifies byte 7's mapper nibble" {
    // The general form of the DiskDude rule: those four bytes are reserved and
    // zero in a real iNES 1.0 header, so one non-zero byte anywhere in them is
    // enough to say the region was written over.
    var rom_bytes: TestRom = undefined;
    for (12..16) |junk_at| {
        testRom(&rom_bytes, &.{ .{ 6, 0x40 }, .{ 7, 0x10 }, .{ junk_at, 0x01 } });
        const cart = try Cartridge.load(&rom_bytes);
        try testing.expect(cart.mapper == .mmc3); // 4, not $14 = 20

        // With those bytes clear the same header is an ordinary 1.0 one, and
        // byte 7 does contribute -- mapper $14, which this emulator rejects.
        testRom(&rom_bytes, &.{ .{ 6, 0x40 }, .{ 7, 0x10 } });
        try testing.expectError(error.UnsupportedMapper, Cartridge.load(&rom_bytes));
    }
}

test "a header claiming NES 2.0 sizes the file cannot hold is read as archaic" {
    // Bits 3-2 of a junk byte 7 land on `%10` one time in four, so the $08
    // marker alone is not evidence. What settles it is whether byte 9's
    // widened sizes fit: here they claim 4 MiB out of a 16 KiB file.
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{ .{ 6, 0x40 }, .{ 7, 0x18 }, .{ 8, 0x21 }, .{ 9, 0x01 } });

    const cart = try Cartridge.load(&rom_bytes);
    // Archaic, so byte 7's $10 is not part of the mapper and byte 8 is neither
    // a submapper nor the mapper's top nibble.
    try testing.expect(cart.mapper == .mmc3);
    try testing.expectEqual(@as(u4, 0), cart.submapper);
    try testing.expectEqual(@as(usize, prg_bank_size), cart.prg_rom.len);
}

test "NES 2.0: the submapper number is parsed, and is 0 for iNES 1.0" {
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{ .{ 7, 0x08 }, .{ 8, 0x10 } }); // submapper 1, mapper MSB 0
    var cart = try Cartridge.load(&rom_bytes);
    try testing.expectEqual(@as(u4, 1), cart.submapper);

    // In iNES 1.0 byte 8 is the PRG-RAM count, not a submapper.
    testRom(&rom_bytes, &.{.{ 8, 0x10 }});
    cart = try Cartridge.load(&rom_bytes);
    try testing.expectEqual(@as(u4, 0), cart.submapper);
}

test "a board with neither CHR ROM nor CHR RAM reads without crashing" {
    // NES 2.0 can declare no CHR ROM *and* a CHR RAM shift count of 0, so both
    // CHR slices come out empty and any mapper that divides by their length
    // would fault.
    for ([_]u8{ 0x00, 0x10, 0x30, 0x40 }) |flags6| { // NROM, MMC1, CNROM, MMC3
        var rom_bytes: TestRom = undefined;
        testRom(&rom_bytes, &.{ .{ 6, flags6 }, .{ 7, 0x08 }, .{ 11, 0 } });

        var cart = try Cartridge.load(&rom_bytes);
        try testing.expectEqual(@as(usize, 0), cart.chr_ram_len);
        try testing.expectEqual(@as(usize, 0), cart.chr_rom.len);

        try testing.expectEqual(@as(u8, 0), cart.ppuRead(0x0000));
        try testing.expectEqual(@as(u8, 0), cart.ppuRead(0x1FFF));
        cart.ppuWrite(0x0000, 0x5A); // must not fabricate storage either
        try testing.expectEqual(@as(u8, 0), cart.ppuRead(0x0000));
    }
}

test "powerOn restores mapper registers without forgetting the board's wiring" {
    var rom_bytes: TestRom = undefined;

    // MMC1 comes up in PRG mode 3, not 0.
    testRom(&rom_bytes, &.{.{ 6, 0x10 }});
    var cart = try Cartridge.load(&rom_bytes);
    cart.mapper.mmc1.control = 0;
    cart.mapper.mmc1.prg_bank = 0x0F;
    cart.powerOn();
    try testing.expectEqual(@as(u8, 0x0C), cart.mapper.mmc1.control);
    try testing.expectEqual(@as(u8, 0), cart.mapper.mmc1.prg_bank);

    // CNROM has to remember that its board has bus conflicts.
    testRom(&rom_bytes, &.{ .{ 6, 0x30 }, .{ 7, 0x08 }, .{ 8, 0x00 } });
    cart = try Cartridge.load(&rom_bytes);
    try testing.expect(cart.mapper.cnrom.bus_conflicts);
    cart.mapper.cnrom.chr_bank = 3;
    cart.powerOn();
    try testing.expectEqual(@as(u8, 0), cart.mapper.cnrom.chr_bank);
    try testing.expect(cart.mapper.cnrom.bus_conflicts);

    // And MMC3 that its board is four-screen.
    testRom(&rom_bytes, &.{.{ 6, 0x48 }});
    cart = try Cartridge.load(&rom_bytes);
    cart.mapper.mmc3.bank_select = 0xFF;
    cart.powerOn();
    try testing.expectEqual(@as(u8, 0), cart.mapper.mmc3.bank_select);
    try testing.expectEqual(Mirroring.four_screen, cart.mirroring());
}

test "the bus-conflict default is enforced for UxROM/CNROM and not for AxROM" {
    // The two mappers go opposite ways on an iNES 1.0 header, which is what
    // nearly every board of either kind actually ships with. Getting AxROM
    // wrong is the expensive direction: with conflicts wrongly enforced and
    // bank 0 mapped, every byte a game could write through reads as 0, so the
    // bank register can never leave 0 and the game cannot start.
    var rom_bytes: TestRom = undefined;

    testRom(&rom_bytes, &.{.{ 6, 0x20 }}); // mapper 2, iNES 1.0
    var cart = try Cartridge.load(&rom_bytes);
    try testing.expect(cart.mapper.uxrom.bus_conflicts);

    testRom(&rom_bytes, &.{.{ 6, 0x70 }}); // mapper 7, iNES 1.0
    cart = try Cartridge.load(&rom_bytes);
    try testing.expect(!cart.mapper.axrom.bus_conflicts);

    // NES 2.0 says outright, and then the default does not apply either way.
    testRom(&rom_bytes, &.{ .{ 6, 0x70 }, .{ 7, 0x08 }, .{ 8, 0x20 } }); // submapper 2
    cart = try Cartridge.load(&rom_bytes);
    try testing.expect(cart.mapper.axrom.bus_conflicts);

    testRom(&rom_bytes, &.{ .{ 6, 0x20 }, .{ 7, 0x08 }, .{ 8, 0x10 } }); // submapper 1
    cart = try Cartridge.load(&rom_bytes);
    try testing.expect(!cart.mapper.uxrom.bus_conflicts);
}

test "the battery bit decides whether PRG RAM is a save file" {
    var rom_bytes: TestRom = undefined;

    // No battery: the RAM still works, it just is not worth persisting.
    testRom(&rom_bytes, &.{});
    var cart = try Cartridge.load(&rom_bytes);
    try testing.expect(!cart.has_battery);
    try testing.expectEqual(@as(usize, 0), cart.batteryRam().len);
    cart.cpuWrite(0x6000, 0x5A, 0);
    try testing.expectEqual(@as(u8, 0x5A), cart.cpuRead(0x6000).?);
    try testing.expect(!cart.takeBatteryRamDirty());

    // Battery: `batteryRam` is the board's whole WRAM.
    testRom(&rom_bytes, &.{.{ 6, 0x02 }});
    cart = try Cartridge.load(&rom_bytes);
    try testing.expect(cart.has_battery);
    try testing.expectEqual(@as(usize, ines1_ram_size), cart.batteryRam().len);
}

test "NES 2.0 can declare a battery through byte 10's NVRAM nibble alone" {
    // The SXROM shape: no volatile WRAM, 32 KiB of battery-backed WRAM, and
    // byte 6's battery bit left clear.
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{ .{ 7, 0x08 }, .{ 10, 0x90 } });
    var cart = try Cartridge.load(&rom_bytes);
    try testing.expect(cart.has_battery);
    try testing.expectEqual(@as(usize, max_ram_size), cart.batteryRam().len);
}

test "a battery bit on a board with no WRAM saves nothing" {
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{ .{ 6, 0x02 }, .{ 7, 0x08 }, .{ 10, 0x00 } });
    var cart = try Cartridge.load(&rom_bytes);
    try testing.expect(!cart.has_battery);
    try testing.expectEqual(@as(usize, 0), cart.batteryRam().len);
    // And the dirty flag must not be raised for storage that isn't there.
    cart.cpuWrite(0x6000, 0x5A, 0);
    try testing.expect(!cart.takeBatteryRamDirty());
}

test "a write into the save window is reported once, then forgotten" {
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{.{ 6, 0x02 }});
    var cart = try Cartridge.load(&rom_bytes);

    try testing.expect(!cart.takeBatteryRamDirty());
    cart.cpuWrite(0x6000, 0x5A, 0);
    try testing.expect(cart.takeBatteryRamDirty());
    try testing.expect(!cart.takeBatteryRamDirty());

    // Writes outside the window are not saves.
    cart.cpuWrite(0x8000, 0x5A, 0);
    try testing.expect(!cart.takeBatteryRamDirty());
}

test "a save is restored only at exactly the board's size" {
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{.{ 6, 0x02 }});
    var cart = try Cartridge.load(&rom_bytes);

    var save: [ines1_ram_size]u8 = @splat(0xA5);
    try testing.expect(cart.loadBatteryRam(&save));
    try testing.expectEqual(@as(u8, 0xA5), cart.cpuRead(0x6000).?);
    // Restoring is not a change to write back out.
    try testing.expect(!cart.takeBatteryRamDirty());

    // A file from a different board is refused rather than padded or cut, so a
    // renamed ROM cannot quietly inherit someone else's save.
    try testing.expect(!cart.loadBatteryRam(save[0 .. ines1_ram_size - 1]));
    try testing.expect(!cart.loadBatteryRam(&.{}));
    try testing.expectEqual(@as(u8, 0xA5), cart.cpuRead(0x6000).?);
}

test "a power cycle keeps the save, since a battery is what a battery is for" {
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{ .{ 6, 0x12 }, .{ header_size, 0 } }); // MMC1, battery
    var cart = try Cartridge.load(&rom_bytes);

    cart.cpuWrite(0x6000, 0x5A, 0);
    cart.powerOn();
    try testing.expectEqual(@as(u8, 0x5A), cart.cpuRead(0x6000).?);
}

test "inspect returns what cpuRead would, without a mutable cartridge" {
    var rom_bytes: TestRom = undefined;
    testRom(&rom_bytes, &.{.{ header_size, 0x5A }});
    const cart = try Cartridge.load(&rom_bytes);
    try testing.expectEqual(@as(u8, 0x5A), cart.inspect(0x8000).?);
    try testing.expectEqual(@as(?u8, null), cart.inspect(0x4020));
}

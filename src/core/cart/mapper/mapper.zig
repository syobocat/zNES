//! Cartridge mapper interface.
//!
//! Mappers are a tagged union rather than a vtable: the supported set is known
//! at comptime, so dispatch is a jump table and mapper-specific state (bank
//! registers, IRQ counters) lives inline with no indirection or allocation.
//!
//! A mapper never owns memory. `Cartridge` owns the ROM and RAM and hands
//! every call a `Banks` view of it; all a mapper decides is which bank of that
//! storage an address lands in.

const Nrom = @import("Nrom.zig");
const Mmc1 = @import("Mmc1.zig");
const Uxrom = @import("Uxrom.zig");
const Cnrom = @import("Cnrom.zig");
const Mmc3 = @import("Mmc3.zig");
const Axrom = @import("Axrom.zig");
const Mmc2 = @import("Mmc2.zig");
const Gnrom = @import("Gnrom.zig");
const Cprom = @import("Cprom.zig");
const Bnrom = @import("Bnrom.zig");

/// One CHR ROM page, which is the unit a header counts CHR in.
const chr_bank_size = 8 * 1024;

pub const Mirroring = enum {
    horizontal,
    vertical,
    single_screen_lower,
    single_screen_upper,
    four_screen,
};

/// The cartridge's storage, as every mapper sees it.
pub const Banks = struct {
    prg_rom: []const u8,
    chr_rom: []const u8,
    /// Non-empty when the board uses CHR RAM instead of CHR ROM.
    chr_ram: []u8,
    prg_ram: []u8,

    /// The CHR storage the PPU actually reads: RAM when the board has it,
    /// ROM otherwise. A board can legally have neither, in which case this is
    /// empty and `readChr`/`writeChr` become no-ops.
    pub fn chr(self: Banks) []const u8 {
        return if (self.chr_ram.len != 0) self.chr_ram else self.chr_rom;
    }

    pub fn readChr(self: Banks, index: usize) u8 {
        const bytes = self.chr();
        if (bytes.len == 0) return 0;
        return bytes[index % bytes.len];
    }

    /// Writes only reach CHR RAM; CHR ROM is not writable.
    pub fn writeChr(self: Banks, index: usize, value: u8) void {
        if (self.chr_ram.len == 0) return;
        self.chr_ram[index % self.chr_ram.len] = value;
    }

    /// One store by name, for the one board that carries **both** kinds at
    /// once and picks between them per bank -- `Mmc3`'s TQROM variant. Every
    /// other board has one kind and wants `chr`/`readChr`, which know which.
    pub fn readChrRom(self: Banks, index: usize) u8 {
        if (self.chr_rom.len == 0) return 0;
        return self.chr_rom[index % self.chr_rom.len];
    }

    /// The other half of `readChrRom`. Writes go through `writeChr`, which
    /// already reaches CHR RAM and nothing else.
    pub fn readChrRam(self: Banks, index: usize) u8 {
        if (self.chr_ram.len == 0) return 0;
        return self.chr_ram[index % self.chr_ram.len];
    }

    /// The unbanked $6000-$7FFF window most boards expose, or null when the
    /// board has no PRG RAM (so the address reads as open bus).
    pub fn readPrgRam(self: Banks, addr: u16) ?u8 {
        if (self.prg_ram.len == 0) return null;
        return self.prg_ram[(addr - 0x6000) % self.prg_ram.len];
    }

    pub fn writePrgRam(self: Banks, addr: u16, value: u8) void {
        if (self.prg_ram.len == 0) return;
        self.prg_ram[(addr - 0x6000) % self.prg_ram.len] = value;
    }

    /// $8000-$FFFF on a board with no PRG banking, so a 16 KiB ROM appears
    /// twice.
    pub fn readPrgRomMirrored(self: Banks, addr: u16) ?u8 {
        if (self.prg_rom.len == 0) return null;
        return self.prg_rom[(addr - 0x8000) % self.prg_rom.len];
    }

    /// $8000-$FFFF through a banking mapper's own arithmetic. Null when the
    /// board has no PRG ROM at all, so the window reads as open bus.
    ///
    /// The wrap belongs here rather than in each mapper's index calculation:
    /// it is what keeps an image shorter than its header claims mirroring
    /// inside the window instead of reading past its end, and a board with an
    /// empty ROM from dividing by its own length.
    pub fn readPrgRom(self: Banks, index: usize) ?u8 {
        if (self.prg_rom.len == 0) return null;
        return self.prg_rom[index % self.prg_rom.len];
    }
};

/// What a header says about the board, reduced to the parts that decide which
/// mapper to build and how to configure it.
///
/// A struct of its own rather than the header itself: this package should not
/// have to know how an iNES header is laid out, and `Cartridge` should not
/// have to know which mapper number is which board. This is the whole of what
/// passes between them.
pub const Config = struct {
    number: u16,
    submapper: u4,
    /// Already includes `.four_screen`; the boards that can override their
    /// own mirroring take it apart again themselves.
    mirroring: Mirroring,
    /// Only mapper 34 needs it, to tell its two unrelated boards apart when
    /// the header is too old to carry a submapper.
    chr_rom_len: usize,
};

pub const UnsupportedMapper = error{UnsupportedMapper};

pub const Mapper = union(enum) {
    nrom: Nrom,
    mmc1: Mmc1,
    uxrom: Uxrom,
    cnrom: Cnrom,
    mmc3: Mmc3,
    axrom: Axrom,
    /// Mappers 9 and 10 both, distinguished by `Mmc2.variant`.
    mmc2: Mmc2,
    /// Mappers 11 and 66, distinguished by `Gnrom.variant`.
    gnrom: Gnrom,
    cprom: Cprom,
    /// Mapper 34's two unrelated boards, distinguished by `Bnrom.variant`.
    bnrom: Bnrom,

    /// The board `config` describes, in its power-on state.
    pub fn fromConfig(config: Config) UnsupportedMapper!Mapper {
        const mirroring_mode = config.mirroring;
        return switch (config.number) {
            0 => .{ .nrom = Nrom.init(mirroring_mode) },
            1 => .{ .mmc1 = .init },
            2 => .{ .uxrom = Uxrom.init(mirroring_mode, busConflicts(config.submapper, true)) },
            3 => .{ .cnrom = Cnrom.init(mirroring_mode, busConflicts(config.submapper, true)) },
            // Submapper 004:1 is the MMC6, the one other chip on this mapper
            // number. Only a NES 2.0 header can name it, so everything else
            // is an MMC3.
            4 => .{ .mmc3 = Mmc3.init(if (config.submapper == 1) .mmc6 else .mmc3, mirroring_mode) },
            // AxROM drives the nametable select itself, so the header's
            // mirroring bits describe no board and are not passed on.
            7 => .{ .axrom = Axrom.init(busConflicts(config.submapper, false)) },
            9 => .{ .mmc2 = Mmc2.init(.mmc2, mirroring_mode) },
            10 => .{ .mmc2 = Mmc2.init(.mmc4, mirroring_mode) },
            11 => .{ .gnrom = Gnrom.init(.color_dreams, mirroring_mode, busConflicts(config.submapper, true)) },
            // The MMC3's predecessor, sharing its register file and nothing
            // above $9FFF. See `Mmc3`.
            13 => .{ .cprom = Cprom.init(mirroring_mode, busConflicts(config.submapper, true)) },
            // Not `busConflicts`: on mapper 34 the submapper names a board
            // rather than answering the conflict question, and each board's
            // answer is fixed. See `Bnrom`.
            34 => .{ .bnrom = Bnrom.init(mapper34Variant(config), mirroring_mode) },
            66 => .{ .gnrom = Gnrom.init(.gxrom, mirroring_mode, busConflicts(config.submapper, true)) },
            119 => .{ .mmc3 = Mmc3.init(.tqrom, mirroring_mode) },
            206 => .{ .mmc3 = Mmc3.init(.namco108, mirroring_mode) },
            else => error.UnsupportedMapper,
        };
    }

    /// Every board back to its power-on registers, keeping its configuration.
    pub fn powerOn(self: *Mapper) void {
        switch (self.*) {
            inline else => |*m| m.powerOn(),
        }
    }

    /// Null means nothing on the cartridge drives the bus for `addr`, so the
    /// read falls through to open bus.
    pub fn cpuRead(self: *const Mapper, banks: Banks, addr: u16) ?u8 {
        return switch (self.*) {
            inline else => |*m| m.cpuRead(banks, addr),
        };
    }

    /// `cycle` is the CPU cycle the write lands on. MMC1 needs it because its
    /// serial port ignores a write that arrives on the cycle right after
    /// another one; the other mappers ignore it.
    pub fn cpuWrite(self: *Mapper, banks: Banks, addr: u16, value: u8, cycle: u64) void {
        switch (self.*) {
            inline else => |*m| m.cpuWrite(banks, addr, value, cycle),
        }
    }

    pub fn ppuRead(self: *Mapper, banks: Banks, addr: u16) u8 {
        return switch (self.*) {
            inline else => |*m| m.ppuRead(banks, addr),
        };
    }

    pub fn ppuWrite(self: *Mapper, banks: Banks, addr: u16, value: u8) void {
        switch (self.*) {
            inline else => |*m| m.ppuWrite(banks, addr, value),
        }
    }

    pub fn mirroring(self: *const Mapper) Mirroring {
        return switch (self.*) {
            inline else => |*m| m.mirroring(),
        };
    }

    /// Reports every change of the PPU's VRAM address bus, so a mapper with an
    /// address-line-triggered IRQ counter can watch it without the PPU knowing
    /// anything about mapper internals. Mappers that have no such counter omit
    /// the method.
    ///
    /// `dot` is the PPU's free-running dot counter. MMC3 needs it because its
    /// A12 detector is a low-pass filter rather than a plain edge detector: a
    /// rising edge only counts once the line has been low for long enough, and
    /// since the bus is only reported when something drives it, that interval
    /// cannot be measured by counting calls.
    pub fn ppuAddressBus(self: *Mapper, addr: u16, dot: u64) void {
        switch (self.*) {
            inline else => |*m| {
                if (@hasDecl(@TypeOf(m.*), "ppuAddressBus")) m.ppuAddressBus(addr, dot);
            },
        }
    }

    /// Whether the cartridge is currently pulling /IRQ low. `dot` lets a
    /// mapper model the propagation delay between its own IRQ source and the
    /// line the CPU samples, which is finer than the CPU's once-per-cycle
    /// poll.
    pub fn irqPending(self: *Mapper, dot: u64) bool {
        return switch (self.*) {
            inline else => |*m| if (@hasDecl(@TypeOf(m.*), "irqPending")) m.irqPending(dot) else false,
        };
    }
};

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// A `Config` for `number`, with everything else at its most ordinary.
fn plainConfig(number: u16) Config {
    return .{ .number = number, .submapper = 0, .mirroring = .horizontal, .chr_rom_len = 0 };
}

test "every supported mapper number builds its board" {
    const expected = [_]struct { u16, std.meta.Tag(Mapper) }{
        .{ 0, .nrom },   .{ 1, .mmc1 },   .{ 2, .uxrom },  .{ 3, .cnrom },
        .{ 4, .mmc3 },   .{ 7, .axrom },  .{ 9, .mmc2 },   .{ 10, .mmc2 },
        .{ 11, .gnrom }, .{ 13, .cprom }, .{ 34, .bnrom }, .{ 66, .gnrom },
        .{ 119, .mmc3 }, .{ 206, .mmc3 },
    };
    for (expected) |pair| {
        const number, const tag = pair;
        const built = try Mapper.fromConfig(plainConfig(number));
        try testing.expectEqual(tag, std.meta.activeTag(built));
    }
}

test "an unsupported mapper number is refused rather than guessed at" {
    try testing.expectError(error.UnsupportedMapper, Mapper.fromConfig(plainConfig(5)));
    try testing.expectError(error.UnsupportedMapper, Mapper.fromConfig(plainConfig(99)));
    try testing.expectError(error.UnsupportedMapper, Mapper.fromConfig(plainConfig(118)));
}

test "powerOn keeps the board's configuration and drops its registers" {
    // MMC1 comes up in PRG mode 3, so a memset-style reset would be wrong.
    var m = try Mapper.fromConfig(plainConfig(1));
    m.mmc1.control = 0;
    m.mmc1.prg_bank = 0x0F;
    m.powerOn();
    try testing.expectEqual(@as(u8, 0x0C), m.mmc1.control);
    try testing.expectEqual(@as(u8, 0), m.mmc1.prg_bank);

    // And a board whose configuration is not all-zero keeps it.
    var u = try Mapper.fromConfig(.{
        .number = 2,
        .submapper = 1, // no bus conflicts
        .mirroring = .vertical,
        .chr_rom_len = 0,
    });
    u.uxrom.prg_bank = 3;
    u.powerOn();
    try testing.expectEqual(@as(u8, 0), u.uxrom.prg_bank);
    try testing.expectEqual(Mirroring.vertical, u.mirroring());
    try testing.expect(!u.uxrom.bus_conflicts);
}

test "mapper 34 picks its board by CHR size when the header cannot say" {
    var c = plainConfig(34);
    // BNROM has one 8 KiB page of CHR or none; NINA-001 banks 4 KiB pages and
    // so carries more.
    c.chr_rom_len = 8 * 1024;
    try testing.expectEqual(Bnrom.Variant.bnrom, (try Mapper.fromConfig(c)).bnrom.variant);
    c.chr_rom_len = 32 * 1024;
    try testing.expectEqual(Bnrom.Variant.nina001, (try Mapper.fromConfig(c)).bnrom.variant);

    // A NES 2.0 submapper says outright, whatever the CHR size.
    c.submapper = 2;
    try testing.expectEqual(Bnrom.Variant.bnrom, (try Mapper.fromConfig(c)).bnrom.variant);
}

test "an empty PRG ROM reads as open bus rather than dividing by its length" {
    const banks: Banks = .{ .prg_rom = &.{}, .chr_rom = &.{}, .chr_ram = &.{}, .prg_ram = &.{} };
    try testing.expectEqual(@as(?u8, null), banks.readPrgRom(0));
    try testing.expectEqual(@as(?u8, null), banks.readPrgRom(0x4000));
}

test "a PRG index past the end of a short image mirrors into it" {
    var prg: [0x4000]u8 = @splat(0);
    prg[0] = 0xA5;
    prg[1] = 0x5A;
    const banks: Banks = .{ .prg_rom = &prg, .chr_rom = &.{}, .chr_ram = &.{}, .prg_ram = &.{} };

    try testing.expectEqual(@as(?u8, 0xA5), banks.readPrgRom(0));
    // The second 16 KiB of a 32 KiB window lands back on the first.
    try testing.expectEqual(@as(?u8, 0xA5), banks.readPrgRom(0x4000));
    try testing.expectEqual(@as(?u8, 0x5A), banks.readPrgRom(0x4001));
}

/// Which of the two boards sharing mapper 34 a header describes.
///
/// NES 2.0 says which; an iNES 1.0 image is told apart by CHR ROM size.
/// NINA-001 banks CHR in 4 KiB pages and so carries more than one 8 KiB page
/// of it, while BNROM has 8 KiB of CHR or none at all.
fn mapper34Variant(config: Config) Bnrom.Variant {
    return switch (config.submapper) {
        1 => .nina001,
        2 => .bnrom,
        else => if (config.chr_rom_len > chr_bank_size) .nina001 else .bnrom,
    };
}

/// Whether a bank write on a discrete-logic board fights the ROM byte
/// underneath it. `default_on` is the answer for a header that does not say.
///
/// NES 2.0 says outright -- submapper 1 is a board wired so the conflict
/// cannot happen, submapper 2 is one where it can -- but an iNES 1.0 header
/// has no room to, so submapper 0 has to be a guess. **The right guess is not
/// the same for every mapper**, and getting that backwards is not a subtle
/// difference: a board wrongly given conflicts can find itself unable to leave
/// bank 0 at all, because every byte it could write through reads as 0.
///
///  - **UxROM and CNROM** boards have conflicts, so submapper 0 enforces
///    them.
///  - **AxROM** is the one licensed discrete board that carries the prevention
///    circuitry *unreliably* -- ANROM and AN1ROM have a 74HC02 that disables
///    PRG ROM during a write, AMROM does not, and AOROM depends on how its
///    chip enable is wired. With most of the library on the boards that are
///    safe, the advice for submapper 0 is the opposite: do **not** enforce.
fn busConflicts(submapper: u4, default_on: bool) bool {
    return switch (submapper) {
        1 => false,
        2 => true,
        else => default_on,
    };
}

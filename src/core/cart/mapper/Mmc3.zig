//! Mapper 4 (MMC3 / TxROM): two switchable 8 KiB PRG windows plus two fixed
//! ones, six switchable CHR windows (two 2 KiB and four 1 KiB), software
//! mirroring control, and a scanline IRQ counter driven off PPU A12.
//!
//! ## The IRQ counter is not a scanline counter
//!
//! It only looks like one. What the chip watches is PPU address line A12,
//! through a low-pass filter: a rising edge clocks the counter, but only once
//! the line has been continuously low for three falling edges of M2 first.
//! Rendering happens to toggle A12 once per scanline when the background comes
//! from $0000 and sprites from $1000, and that coincidence is the entire
//! mechanism.
//!
//! Two consequences follow. The counter runs whether or not rendering is on,
//! so software can clock it by hand just by pointing $2006 into $1000-$1FFF.
//! And the filter is load-bearing rather than an optimization: without it the
//! eight consecutive high dots of a single sprite pattern fetch would each
//! look like an edge. Its exact threshold is load-bearing too -- see
//! `a12_filter_dots`, where one dot decides whether a scanline clocks the
//! counter once or twice.
//!
//! ## The MMC6 is here too
//!
//! NES-HKROM carries a different chip, the MMC6, which shares iNES mapper 4
//! with every TxROM board. Banking, mirroring and the IRQ counter are the
//! MMC3's; what differs is the RAM. The MMC6 has 1 KiB *inside the chip*
//! rather than a RAM chip on the board, mapped at $7000-$7FFF instead of
//! $6000-$7FFF, and split into two 512-byte halves that are separately
//! enabled for reading and writing. Only NES 2.0 can say which chip an image
//! wants (submapper 004:1), so an iNES 1.0 header always lands on the MMC3.
//!
//! **This is not what `mmc3_test/6-MMC6.nes` checks.** That ROM tests an IRQ
//! counter behaviour some MMC3s share with the MMC6, and its expectations
//! contradict `5-MMC3.nes`'s -- see the two ROMs' expectations in
//! `nes_test_roms.zig`. Nothing in this file's MMC6 support changes it.
//!
//! ## The Namco 108 is here too
//!
//! Mapper 206 (Namco 108 / Namcot 118, Tengen MIMIC-1, Nintendo's DxROM) is
//! the MMC3's **predecessor**, so it is this chip with things taken away
//! rather than added: no IRQ counter, no WRAM, no mirroring register, no PRG
//! or CHR mode bits, and bank numbers narrower by two bits. It decodes only
//! $8000-$9FFF; everything above that is a write into the void.
//!
//! Many images on this board are labelled mapper 4 instead, and they run as
//! an MMC3 -- the taken-away parts are all things a 108 game never touches.
//! What does *not* work is the other direction: an image correctly labelled
//! 206 has to load at all.
//!
//! ## TQROM has both kinds of CHR at once
//!
//! Mapper 119 is an ordinary MMC3 whose CHR A16 line is wired to the two
//! chips' enables rather than to an address pin, so **bit 6 of a CHR bank
//! number chooses ROM or RAM** and the remaining six bits pick the 1 KiB bank
//! inside it. That is the only difference; banking, mirroring and the IRQ
//! counter are untouched.
//!
//! It is the one supported board that carries both kinds, which is why
//! `Banks` has `readChrRom` and `readChrRam` at all -- everywhere else, "does
//! this board have CHR RAM?" is a question with one answer.
//!
//! ## Chip revisions
//!
//! Two behaviors exist for what "the counter hit zero" means. This implements
//! the Sharp MMC3B/MMC3C one: the IRQ fires whenever the counter *is* zero
//! after a clock, so a latch of $00 interrupts every scanline. The NEC variant
//! fires only on a 1->0 transition, and so interrupts once. The two are
//! mutually exclusive, and test ROMs exist for each.

const Mmc3 = @This();
const mapper = @import("mapper.zig");
const Banks = mapper.Banks;
const Mirroring = mapper.Mirroring;

const prg_window = 0x2000;
const chr_window = 0x400;

/// How long A12 must sit low before a rising edge counts, in PPU dots. The
/// chip specifies it as three falling edges of M2, which is 3 CPU cycles --
/// but 3 CPU cycles is 9 dots, and 9 is exactly the gap this filter has to
/// *reject*, so the literal reading is one dot too generous.
///
/// The gap in question is the one between scanlines. With the background at
/// $1000 the pattern fetches hold A12 high, and the only stretch of a
/// rendering scanline long enough to look like a lull is the four garbage
/// nametable fetches at dots 337-340, the idle dot 0, and the nametable and
/// attribute fetches at dots 1-4 -- nine dots, ending in the rise at dot 5.
/// Hardware does not clock there: `4-scanline_timing`'s constants put its
/// clocks exactly 341 dots apart from scanline 1 on, i.e. one per scanline,
/// and a filter that accepted the nine-dot gap would clock twice.
///
/// So the real bound is "reject 9, accept the 12 that the shortest $2006 pair
/// leaves"; 10 is the low end of that. Where inside it the true threshold sits
/// depends on the CPU/PPU alignment this emulator has fixed (see `Nes`), since
/// that is what decides where M2's edges fall inside the gap.
const a12_filter_dots = 10;

/// Dots between the counter reaching zero and /IRQ reaching the CPU. The
/// counter and the line are separate things: software clocking A12 by hand
/// measures the former, while a test that brackets the IRQ to an exact PPU dot
/// measures the latter.
const irq_line_delay_dots: u64 = 2;

pub const Variant = enum {
    mmc3,
    /// NES-HKROM: the MMC3 with 1 KiB of RAM inside the chip. See below.
    mmc6,
    /// Mapper 206: the MMC3's simpler predecessor. See above.
    namco108,
    /// NES-TQROM: an MMC3 wired so that bit 6 of a CHR bank number picks the
    /// CHR **RAM** chip instead of the ROM. See below.
    tqrom,
};

variant: Variant,

/// Last value written to $8000: bank register index in bits 2-0, PRG mode in
/// bit 6, CHR A12 inversion in bit 7. On the MMC6, bit 5 additionally enables
/// the chip's internal RAM.
bank_select: u8 = 0,
/// MMC6 only. $A001's `HhLl xxxx`: read and write enables for the two
/// 512-byte halves of the internal RAM. Held at zero -- not merely ignored --
/// while $8000 bit 5 is clear, which is what the chip does.
ram_protect: u8 = 0,
/// R0-R7. R0/R1 select 2 KiB CHR banks (low bit ignored), R2-R5 select 1 KiB
/// CHR banks, R6/R7 select 8 KiB PRG banks (top two bits ignored, since the
/// chip only has six PRG address lines).
bank_regs: [8]u8 = @splat(0),

/// Set from $A000, and ignored entirely on four-screen boards where the extra
/// VRAM is wired on the cartridge and the chip has no say.
mirroring_mode: Mirroring = .horizontal,
four_screen: bool,

irq_latch: u8 = 0,
irq_counter: u8 = 0,
/// Set by a $C001 write; makes the next clock reload instead of decrement.
irq_reload: bool = false,
irq_enabled: bool = false,
irq_flag: bool = false,

/// A12 as of the last time anything drove the address bus, and the dot it last
/// went low on. Together these are the filter.
a12_high: bool = false,
a12_went_low_at: u64 = 0,
/// The dot the counter last raised `irq_flag` on, for `irq_line_delay_dots`.
irq_flag_set_at: u64 = 0,

pub fn init(variant: Variant, mirroring_mode: Mirroring) Mmc3 {
    const four_screen = mirroring_mode == .four_screen;
    return .{
        .variant = variant,
        .four_screen = four_screen,
        // On a two-screen board the header's bit is only the power-on state;
        // $A000 owns it from the first write onward.
        .mirroring_mode = if (four_screen) .four_screen else mirroring_mode,
    };
}

// --- CPU side ------------------------------------------------------------

/// Which 8 KiB PRG bank backs `addr`, as an index from the start of PRG ROM.
/// The two fixed windows are counted from the end, so they land correctly
/// whatever the ROM's size.
fn prgBank(self: *const Mmc3, banks: Banks, addr: u16) usize {
    const count = @max(banks.prg_rom.len / prg_window, 1);
    const last = count - 1;
    const second_last = if (count >= 2) count - 2 else 0;
    // Bit 6 swaps the $8000 and $C000 windows: one of them is always the
    // second-last bank and the other is always R6. The Namco 108 has no such
    // bit -- its last two banks are always the fixed ones -- and only four
    // bank bits, for its 128 KiB.
    const swapped = self.variant != .namco108 and (self.bank_select & 0x40) != 0;
    const prg_mask: u8 = if (self.variant == .namco108) 0x0F else 0x3F;
    const r6 = @as(usize, self.bank_regs[6] & prg_mask) % count;
    const r7 = @as(usize, self.bank_regs[7] & prg_mask) % count;
    return switch (addr) {
        0x8000...0x9FFF => if (swapped) second_last else r6,
        0xA000...0xBFFF => r7,
        0xC000...0xDFFF => if (swapped) r6 else second_last,
        else => last,
    };
}

pub fn cpuRead(self: *const Mmc3, banks: Banks, addr: u16) ?u8 {
    return switch (addr) {
        0x6000...0x7FFF => switch (self.variant) {
            .mmc3, .tqrom => banks.readPrgRam(addr),
            .mmc6 => self.mmc6RamRead(banks, addr),
            // No WRAM on the board at all, so nothing drives the window.
            .namco108 => null,
        },
        0x8000...0xFFFF => banks.readPrgRom(self.prgBank(banks, addr) * prg_window + (addr & 0x1FFF)),
        else => null,
    };
}

pub fn cpuWrite(self: *Mmc3, banks: Banks, addr: u16, value: u8, _: u64) void {
    // The Namco 108 decodes $8000-$9FFF and nothing else: no WRAM below it,
    // and no mirroring or IRQ registers above.
    if (self.variant == .namco108 and (addr < 0x8000 or addr >= 0xA000)) return;

    const odd = (addr & 1) != 0;
    switch (addr) {
        0x6000...0x7FFF => switch (self.variant) {
            .mmc3, .tqrom => banks.writePrgRam(addr, value),
            .mmc6 => self.mmc6RamWrite(banks, addr, value),
            .namco108 => unreachable, // returned above
        },
        0x8000...0x9FFF => if (odd) {
            self.bank_regs[self.bank_select & 0x07] = value;
        } else {
            self.bank_select = value;
            // Disabling the MMC6's RAM does not just gate it: while bit 5 is
            // clear the chip drives $A001 to zero itself, so the protect bits
            // are gone rather than remembered, and re-enabling the RAM comes
            // back to a fully disabled one.
            if (self.variant == .mmc6 and (value & 0x20) == 0) self.ram_protect = 0;
        },
        // $A001 is PRG RAM protect. On the MMC3 this is not modelled: no
        // supported board depends on write protection, and honouring it would
        // only ever turn working writes into dropped ones. On the MMC6 it is
        // not optional -- the chip's own RAM is unreadable until it is set.
        0xA000...0xBFFF => if (odd) {
            if (self.variant == .mmc6 and (self.bank_select & 0x20) != 0) self.ram_protect = value;
        } else if (!self.four_screen) {
            self.mirroring_mode = if ((value & 1) != 0) .horizontal else .vertical;
        },
        0xC000...0xDFFF => if (odd) {
            // A $C001 write clears the counter immediately and reloads it at
            // the next rising edge. It does *not* raise the IRQ, even though
            // it leaves the counter at zero: only a clock can set the flag.
            self.irq_counter = 0;
            self.irq_reload = true;
        } else {
            self.irq_latch = value;
        },
        0xE000...0xFFFF => if (odd) {
            self.irq_enabled = true;
        } else {
            self.irq_enabled = false;
            self.irq_flag = false;
        },
        else => {},
    }
}

// --- MMC6 internal RAM ---------------------------------------------------

/// Which 512-byte half of the chip's 1 KiB `addr` falls in: 0 for
/// $7000-$71FF, 1 for $7200-$73FF, and the same again in each mirror.
fn mmc6Half(addr: u16) u2 {
    return @intCast((addr >> 9) & 1);
}

/// Whether that half may be read, and whether it may be written. A write
/// enable only means anything while the same half is readable, which is the
/// chip's own rule rather than a simplification here.
fn mmc6Enabled(self: *const Mmc3, half: u2) struct { bool, bool } {
    const shift: u3 = @as(u3, half) * 2;
    const readable = (self.ram_protect & (@as(u8, 0x20) << shift)) != 0;
    const writable = readable and (self.ram_protect & (@as(u8, 0x10) << shift)) != 0;
    return .{ readable, writable };
}

/// $6000-$6FFF is not wired to anything on this board, and neither is a half
/// whose read enable is clear -- except that the two halves fail differently:
/// with *both* disabled the window is open bus, while with one of the two
/// enabled the other reads back as 0.
fn mmc6RamRead(self: *const Mmc3, banks: Banks, addr: u16) ?u8 {
    if (addr < 0x7000 or banks.prg_ram.len == 0) return null;
    const low = self.mmc6Enabled(0);
    const high = self.mmc6Enabled(1);
    if (!low[0] and !high[0]) return null;
    if (!(if (mmc6Half(addr) == 0) low[0] else high[0])) return 0;
    return banks.prg_ram[(addr & 0x3FF) % banks.prg_ram.len];
}

fn mmc6RamWrite(self: *const Mmc3, banks: Banks, addr: u16, value: u8) void {
    if (addr < 0x7000 or banks.prg_ram.len == 0) return;
    if (!self.mmc6Enabled(mmc6Half(addr))[1]) return;
    banks.prg_ram[(addr & 0x3FF) % banks.prg_ram.len] = value;
}

// --- PPU side ------------------------------------------------------------

/// Which 1 KiB CHR bank backs `addr`. Describing all six windows in 1 KiB
/// units makes the 2 KiB ones a pair with the low bit forced, which is exactly
/// how the chip ignores R0/R1's low bit.
fn chrBank(self: *const Mmc3, addr: u16) usize {
    // Bit 7 swaps the $0000-$0FFF and $1000-$1FFF halves wholesale, which in
    // 1 KiB units is a flip of the window index's bit 2. The Namco 108 has no
    // such bit: the 2 KiB banks are always the left table's.
    var window: u3 = @truncate(addr >> 10);
    if (self.variant != .namco108 and (self.bank_select & 0x80) != 0) window ^= 4;
    // Six bank bits on the 108, for its 64 KiB.
    const mask: u8 = if (self.variant == .namco108) 0x3F else 0xFF;
    return switch (window) {
        0 => self.bank_regs[0] & mask & 0xFE,
        1 => (self.bank_regs[0] & mask & 0xFE) | 1,
        2 => self.bank_regs[1] & mask & 0xFE,
        3 => (self.bank_regs[1] & mask & 0xFE) | 1,
        4 => self.bank_regs[2] & mask,
        5 => self.bank_regs[3] & mask,
        6 => self.bank_regs[4] & mask,
        7 => self.bank_regs[5] & mask,
    };
}

fn chrIndex(self: *const Mmc3, addr: u16) usize {
    return self.chrBank(addr) * chr_window + (addr & 0x3FF);
}

pub fn ppuRead(self: *Mmc3, banks: Banks, addr: u16) u8 {
    if (self.variant == .tqrom) {
        const bank = self.chrBank(addr);
        const index = (bank & 0x3F) * chr_window + (addr & 0x3FF);
        return if (bank & tqrom_ram_select != 0)
            banks.readChrRam(index)
        else
            banks.readChrRom(index);
    }
    return banks.readChr(self.chrIndex(addr));
}

pub fn ppuWrite(self: *Mmc3, banks: Banks, addr: u16, value: u8) void {
    if (self.variant == .tqrom) {
        const bank = self.chrBank(addr);
        // A write to a bank currently showing CHR ROM has nowhere to go, and
        // must not fall through into the RAM chip.
        if (bank & tqrom_ram_select == 0) return;
        banks.writeChr((bank & 0x3F) * chr_window + (addr & 0x3FF), value);
        return;
    }
    banks.writeChr(self.chrIndex(addr), value);
}

/// The bit of a TQROM CHR bank number that selects the RAM chip.
const tqrom_ram_select = 0x40;

pub fn mirroring(self: *const Mmc3) Mirroring {
    return self.mirroring_mode;
}

// --- IRQ counter ---------------------------------------------------------

pub fn ppuAddressBus(self: *Mmc3, addr: u16, dot: u64) void {
    if (self.variant == .namco108) return; // no counter to clock
    const a12 = (addr & 0x1000) != 0;
    if (a12 == self.a12_high) return;

    if (a12) {
        if (dot -| self.a12_went_low_at >= a12_filter_dots) self.clock(dot);
    } else {
        self.a12_went_low_at = dot;
    }
    self.a12_high = a12;
}

fn clock(self: *Mmc3, dot: u64) void {
    if (self.irq_counter == 0 or self.irq_reload) {
        self.irq_counter = self.irq_latch;
        self.irq_reload = false;
    } else {
        self.irq_counter -= 1;
    }
    if (self.irq_counter == 0 and self.irq_enabled and !self.irq_flag) {
        self.irq_flag = true;
        self.irq_flag_set_at = dot;
    }
}

pub fn irqPending(self: *const Mmc3, dot: u64) bool {
    if (!self.irq_flag) return false;
    return dot -| self.irq_flag_set_at >= irq_line_delay_dots;
}

/// Back to the board's power-on registers, keeping its configuration --
/// which describes the cartridge, not its state.
pub fn powerOn(self: *Mmc3) void {
    self.* = init(self.variant, if (self.four_screen) .four_screen else self.mirroring_mode);
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// 128 KiB PRG and 128 KiB CHR, each byte stamped with its own bank number so
/// a read says which bank answered.
const test_prg_banks = 16;
const test_chr_banks = 128;
var test_prg: [test_prg_banks * prg_window]u8 = undefined;
var test_chr: [test_chr_banks * chr_window]u8 = undefined;
var test_prg_ram: [0x2000]u8 = undefined;

fn testBanks() Banks {
    for (0..test_prg_banks) |bank| {
        @memset(test_prg[bank * prg_window ..][0..prg_window], @intCast(bank));
    }
    for (0..test_chr_banks) |bank| {
        @memset(test_chr[bank * chr_window ..][0..chr_window], @intCast(bank));
    }
    return .{
        .prg_rom = &test_prg,
        .chr_rom = &test_chr,
        .chr_ram = &.{},
        .prg_ram = &test_prg_ram,
    };
}

/// Selects bank register `reg` and loads `value` into it.
fn setBankReg(m: *Mmc3, banks: Banks, reg: u8, value: u8) void {
    m.cpuWrite(banks, 0x8000, reg, 0);
    m.cpuWrite(banks, 0x8001, value, 0);
}

test "PRG mode bit swaps the $8000 and $C000 windows, leaving $A000/$E000 put" {
    const banks = testBanks();
    var m = Mmc3.init(.mmc3, .horizontal);
    setBankReg(&m, banks, 6, 3);
    setBankReg(&m, banks, 7, 5);

    // Mode 0: $8000 is R6, $C000 is the second-last bank.
    try testing.expectEqual(@as(u8, 3), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 5), m.cpuRead(banks, 0xA000).?);
    try testing.expectEqual(@as(u8, test_prg_banks - 2), m.cpuRead(banks, 0xC000).?);
    try testing.expectEqual(@as(u8, test_prg_banks - 1), m.cpuRead(banks, 0xE000).?);

    // Mode 1: the two swap. Setting bit 6 also rewrites the register index, so
    // re-select R6 to keep the comparison honest.
    m.cpuWrite(banks, 0x8000, 0x40 | 6, 0);
    try testing.expectEqual(@as(u8, test_prg_banks - 2), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 5), m.cpuRead(banks, 0xA000).?);
    try testing.expectEqual(@as(u8, 3), m.cpuRead(banks, 0xC000).?);
    try testing.expectEqual(@as(u8, test_prg_banks - 1), m.cpuRead(banks, 0xE000).?);
}

test "R6/R7 ignore the top two bits" {
    const banks = testBanks();
    var m = Mmc3.init(.mmc3, .horizontal);
    setBankReg(&m, banks, 6, 0xC0 | 3); // only the 3 should survive
    try testing.expectEqual(@as(u8, 3), m.cpuRead(banks, 0x8000).?);
}

test "CHR windows are two 2 KiB banks then four 1 KiB banks, and bit 7 flips the halves" {
    const banks = testBanks();
    var m = Mmc3.init(.mmc3, .horizontal);
    for ([_]u8{ 2, 4, 8, 9, 10, 11 }, 0..) |v, reg| setBankReg(&m, banks, @intCast(reg), v);

    // R0 covers $0000-$07FF as a 2 KiB pair, so its second half is bank+1.
    try testing.expectEqual(@as(u8, 2), m.ppuRead(banks, 0x0000));
    try testing.expectEqual(@as(u8, 3), m.ppuRead(banks, 0x0400));
    try testing.expectEqual(@as(u8, 4), m.ppuRead(banks, 0x0800));
    try testing.expectEqual(@as(u8, 5), m.ppuRead(banks, 0x0C00));
    try testing.expectEqual(@as(u8, 8), m.ppuRead(banks, 0x1000));
    try testing.expectEqual(@as(u8, 9), m.ppuRead(banks, 0x1400));
    try testing.expectEqual(@as(u8, 10), m.ppuRead(banks, 0x1800));
    try testing.expectEqual(@as(u8, 11), m.ppuRead(banks, 0x1C00));

    // Inversion moves the 2 KiB pair up to $1000 and the 1 KiB set down.
    m.cpuWrite(banks, 0x8000, 0x80, 0);
    try testing.expectEqual(@as(u8, 8), m.ppuRead(banks, 0x0000));
    try testing.expectEqual(@as(u8, 11), m.ppuRead(banks, 0x0C00));
    try testing.expectEqual(@as(u8, 2), m.ppuRead(banks, 0x1000));
    try testing.expectEqual(@as(u8, 3), m.ppuRead(banks, 0x1400));
    try testing.expectEqual(@as(u8, 4), m.ppuRead(banks, 0x1800));
}

test "2 KiB CHR banks ignore the low bit of R0/R1" {
    const banks = testBanks();
    var m = Mmc3.init(.mmc3, .horizontal);
    setBankReg(&m, banks, 0, 7); // odd, so it behaves as 6
    try testing.expectEqual(@as(u8, 6), m.ppuRead(banks, 0x0000));
    try testing.expectEqual(@as(u8, 7), m.ppuRead(banks, 0x0400));
}

/// Drives A12 low then high with enough slack for the filter to accept it,
/// then advances past `irq_line_delay_dots` so a resulting IRQ is visible to
/// `irqPending`. These tests are about the counter, not that delay.
fn clockA12(m: *Mmc3, dot: *u64) void {
    m.ppuAddressBus(0x0000, dot.*);
    dot.* += a12_filter_dots;
    m.ppuAddressBus(0x1000, dot.*);
    dot.* += 1 + irq_line_delay_dots;
}

/// Latches `latch`, requests a reload, and enables IRQs.
fn armedCounter(latch: u8) Mmc3 {
    var m = Mmc3.init(.mmc3, .horizontal);
    m.cpuWrite(undefined, 0xC000, latch, 0);
    m.cpuWrite(undefined, 0xC001, 0, 0);
    m.cpuWrite(undefined, 0xE001, 0, 0);
    return m;
}

test "the IRQ counter reloads, counts down, and fires at zero" {
    var m = armedCounter(3);
    var dot: u64 = 100;

    // The first clock reloads to 3, then it counts 2, 1, 0, so the IRQ lands
    // on the fourth clock: N+1 scanlines between IRQs.
    for (0..3) |_| {
        clockA12(&m, &dot);
        try testing.expect(!m.irqPending(dot));
    }
    clockA12(&m, &dot);
    try testing.expect(m.irqPending(dot));

    // $E000 acknowledges and disables.
    m.cpuWrite(undefined, 0xE000, 0, 0);
    try testing.expect(!m.irqPending(dot));
}

test "a rising edge is ignored unless A12 was low long enough first" {
    var m = armedCounter(1);
    var dot: u64 = 100;
    clockA12(&m, &dot); // the reload clock

    // A dip one dot too short. This must not clock, or a single sprite fetch
    // would count as several scanlines.
    m.ppuAddressBus(0x0000, dot);
    dot += a12_filter_dots - 1;
    m.ppuAddressBus(0x1000, dot);
    dot += 1;
    try testing.expect(!m.irqPending(dot));

    clockA12(&m, &dot);
    try testing.expect(m.irqPending(dot));
}

test "the nine-dot gap between two scanlines' pattern fetches does not clock" {
    // The two bounds `a12_filter_dots` actually has to sit between, written
    // as dot counts rather than as the constant, so widening the filter by
    // one dot fails here instead of silently doubling the counter's rate.
    //
    // Low: the background fetch cadence's dots 337-340, 0, and 1-4, which is
    // the longest A12 stays low inside a scanline rendered from $1000.
    // High: two back-to-back $2006 writes, the fastest software can drive the
    // line by hand, at 4 CPU cycles each.
    const scanline_gap_dots = 9;
    const shortest_manual_gap_dots = 4 * 3;

    var m = armedCounter(1);
    var dot: u64 = 100;
    clockA12(&m, &dot); // the reload clock

    m.ppuAddressBus(0x0000, dot);
    dot += scanline_gap_dots;
    m.ppuAddressBus(0x1000, dot);
    dot += 1;
    try testing.expect(!m.irqPending(dot));

    m.ppuAddressBus(0x0000, dot);
    dot += shortest_manual_gap_dots;
    m.ppuAddressBus(0x1000, dot);
    dot += irq_line_delay_dots;
    try testing.expect(m.irqPending(dot));
}

test "writing $C001 clears the counter without raising the IRQ" {
    var m = Mmc3.init(.mmc3, .horizontal);
    m.cpuWrite(undefined, 0xC000, 0, 0);
    m.cpuWrite(undefined, 0xE001, 0, 0);
    m.cpuWrite(undefined, 0xC001, 0, 0);
    // The counter is zero and IRQs are enabled, yet nothing has fired: only a
    // clock can set the flag.
    try testing.expect(!m.irqPending(1000));
    try testing.expectEqual(@as(u8, 0), m.irq_counter);
}

test "a latch of zero fires every clock on this revision" {
    var m = armedCounter(0);
    var dot: u64 = 100;

    clockA12(&m, &dot);
    try testing.expect(m.irqPending(dot));
    m.cpuWrite(undefined, 0xE000, 0, 0);
    m.cpuWrite(undefined, 0xE001, 0, 0);
    clockA12(&m, &dot);
    try testing.expect(m.irqPending(dot));
}

test "the counter runs but stays silent while IRQs are disabled" {
    var m = Mmc3.init(.mmc3, .horizontal);
    m.cpuWrite(undefined, 0xC000, 0, 0);
    m.cpuWrite(undefined, 0xC001, 0, 0);
    var dot: u64 = 100;
    clockA12(&m, &dot);
    try testing.expect(!m.irq_flag);

    // Enabling afterwards does not retroactively raise it; the next clock does.
    m.cpuWrite(undefined, 0xE001, 0, 0);
    try testing.expect(!m.irq_flag);
    clockA12(&m, &dot);
    try testing.expect(m.irq_flag);
}

// --- MMC6 ----------------------------------------------------------------

/// An MMC6 with its internal RAM enabled at $8000 and `protect` written to
/// $A001, which is the only order the chip accepts.
fn enabledMmc6(banks: Banks, protect: u8) Mmc3 {
    var m = Mmc3.init(.mmc6, .horizontal);
    m.cpuWrite(banks, 0x8000, 0x20, 0);
    m.cpuWrite(banks, 0xA001, protect, 0);
    return m;
}

test "MMC6: the internal RAM is 1 KiB at $7000, mirrored, with nothing below it" {
    const banks = testBanks();
    var m = enabledMmc6(banks, 0xF0); // both halves readable and writable

    m.cpuWrite(banks, 0x7000, 0x11, 0);
    m.cpuWrite(banks, 0x7200, 0x22, 0);
    try testing.expectEqual(@as(u8, 0x11), m.cpuRead(banks, 0x7000).?);
    try testing.expectEqual(@as(u8, 0x22), m.cpuRead(banks, 0x7200).?);
    // 1 KiB repeated across the 4 KiB window.
    try testing.expectEqual(@as(u8, 0x11), m.cpuRead(banks, 0x7400).?);
    try testing.expectEqual(@as(u8, 0x22), m.cpuRead(banks, 0x7E00).?);

    // $6000-$6FFF is where a TxROM board's RAM chip would be. The MMC6 has
    // no board RAM at all, so this is open bus even with everything enabled.
    try testing.expectEqual(@as(?u8, null), m.cpuRead(banks, 0x6000));
    m.cpuWrite(banks, 0x6000, 0x33, 0);
    try testing.expectEqual(@as(?u8, null), m.cpuRead(banks, 0x6000));
}

test "MMC6: the two halves are protected separately, and fail differently" {
    const banks = testBanks();
    var m = enabledMmc6(banks, 0xF0);
    m.cpuWrite(banks, 0x7000, 0x11, 0);
    m.cpuWrite(banks, 0x7200, 0x22, 0);

    // Only the low half readable: the high one reads 0 rather than open bus,
    // because the chip is still driving the window.
    m.cpuWrite(banks, 0xA001, 0x20, 0);
    try testing.expectEqual(@as(u8, 0x11), m.cpuRead(banks, 0x7000).?);
    try testing.expectEqual(@as(u8, 0), m.cpuRead(banks, 0x7200).?);

    // Neither readable: now nothing drives it and the whole window is open
    // bus, which is a different answer from "reads 0".
    m.cpuWrite(banks, 0xA001, 0x00, 0);
    try testing.expectEqual(@as(?u8, null), m.cpuRead(banks, 0x7000));
    try testing.expectEqual(@as(?u8, null), m.cpuRead(banks, 0x7200));
}

test "MMC6: a write enable does nothing while its half is unreadable" {
    const banks = testBanks();
    var m = enabledMmc6(banks, 0xF0);
    m.cpuWrite(banks, 0x7000, 0x11, 0);

    // Write enable set, read enable clear: the chip refuses the write, so
    // re-enabling the read finds the old contents.
    m.cpuWrite(banks, 0xA001, 0x10, 0);
    m.cpuWrite(banks, 0x7000, 0x99, 0);
    m.cpuWrite(banks, 0xA001, 0x30, 0);
    try testing.expectEqual(@as(u8, 0x11), m.cpuRead(banks, 0x7000).?);

    // Readable but not writable is a plain dropped write.
    m.cpuWrite(banks, 0xA001, 0x20, 0);
    m.cpuWrite(banks, 0x7000, 0x99, 0);
    try testing.expectEqual(@as(u8, 0x11), m.cpuRead(banks, 0x7000).?);
}

test "MMC6: $8000 bit 5 clears the protect register rather than gating it" {
    const banks = testBanks();
    var m = enabledMmc6(banks, 0xF0);
    m.cpuWrite(banks, 0x7000, 0x11, 0);

    // Disable the RAM. $A001 is held at zero while bit 5 is clear, so writes
    // to it are lost...
    m.cpuWrite(banks, 0x8000, 0x00, 0);
    m.cpuWrite(banks, 0xA001, 0xF0, 0);
    try testing.expectEqual(@as(?u8, null), m.cpuRead(banks, 0x7000));

    // ...and re-enabling comes back to a disabled register, not to the $F0
    // that was there before. The contents survive; the permissions do not.
    m.cpuWrite(banks, 0x8000, 0x20, 0);
    try testing.expectEqual(@as(?u8, null), m.cpuRead(banks, 0x7000));
    m.cpuWrite(banks, 0xA001, 0xF0, 0);
    try testing.expectEqual(@as(u8, 0x11), m.cpuRead(banks, 0x7000).?);
}

test "MMC6: everything else is the MMC3, and an MMC3 has none of this" {
    const banks = testBanks();
    var m = enabledMmc6(banks, 0xF0);
    // Bit 5 shares the byte with the bank register index, so enabling the RAM
    // selects R0 as a side effect -- and banking is otherwise untouched.
    setBankReg(&m, banks, 0x20 | 6, 3);
    try testing.expectEqual(@as(u8, 3), m.cpuRead(banks, 0x8000).?);

    // The same accesses on an MMC3: $6000-$7FFF is one flat 8 KiB window with
    // no protect register in front of it.
    var plain = Mmc3.init(.mmc3, .horizontal);
    plain.cpuWrite(banks, 0x6000, 0x44, 0);
    try testing.expectEqual(@as(u8, 0x44), plain.cpuRead(banks, 0x6000).?);
    plain.cpuWrite(banks, 0xA001, 0x00, 0);
    try testing.expectEqual(@as(u8, 0x44), plain.cpuRead(banks, 0x6000).?);
}

// --- TQROM (mapper 119) --------------------------------------------------

/// A TQROM's banks: the same CHR ROM as every other test here, plus 8 KiB of
/// CHR RAM beside it rather than instead of it.
var test_tqrom_chr_ram: [0x2000]u8 = undefined;

fn tqromBanks() Banks {
    @memset(&test_tqrom_chr_ram, 0);
    var b = testBanks();
    b.chr_ram = &test_tqrom_chr_ram;
    return b;
}

test "TQROM: bit 6 of a CHR bank picks the RAM chip, and the rest is the bank" {
    const banks = tqromBanks();
    var m = Mmc3.init(.tqrom, .horizontal);

    // R2 covers $1000-$13FF. Bank 3 of the ROM, then bank 3 of the RAM.
    setBankReg(&m, banks, 2, 3);
    try testing.expectEqual(@as(u8, 3), m.ppuRead(banks, 0x1000));

    setBankReg(&m, banks, 2, 0x40 | 3);
    try testing.expectEqual(@as(u8, 0), m.ppuRead(banks, 0x1000));
    m.ppuWrite(banks, 0x1000, 0x5A);
    try testing.expectEqual(@as(u8, 0x5A), m.ppuRead(banks, 0x1000));

    // Back to ROM: the same six bank bits, the other chip, and the byte
    // written above is still where it was.
    setBankReg(&m, banks, 2, 3);
    try testing.expectEqual(@as(u8, 3), m.ppuRead(banks, 0x1000));
    setBankReg(&m, banks, 2, 0x40 | 3);
    try testing.expectEqual(@as(u8, 0x5A), m.ppuRead(banks, 0x1000));
}

test "TQROM: a write to a bank showing ROM does not fall through to the RAM" {
    const banks = tqromBanks();
    var m = Mmc3.init(.tqrom, .horizontal);

    setBankReg(&m, banks, 2, 3); // ROM bank 3 at $1000
    m.ppuWrite(banks, 0x1000, 0x5A);
    try testing.expectEqual(@as(u8, 3), m.ppuRead(banks, 0x1000));

    // RAM bank 3 must still be untouched -- the write had nowhere to go.
    setBankReg(&m, banks, 2, 0x40 | 3);
    try testing.expectEqual(@as(u8, 0), m.ppuRead(banks, 0x1000));
}

test "TQROM: the two kinds can be on screen at once" {
    // The whole point of the board: ROM tiles in one window, RAM tiles in
    // another, which is what `Banks.readChrRom`/`readChrRam` exist for.
    const banks = tqromBanks();
    var m = Mmc3.init(.tqrom, .horizontal);

    setBankReg(&m, banks, 0, 2); // 2 KiB of ROM at $0000
    setBankReg(&m, banks, 2, 0x40); // 1 KiB of RAM at $1000
    m.ppuWrite(banks, 0x1234, 0xC3);

    try testing.expectEqual(@as(u8, 2), m.ppuRead(banks, 0x0000));
    try testing.expectEqual(@as(u8, 0xC3), m.ppuRead(banks, 0x1234));
}

// --- Namco 108 (mapper 206) ----------------------------------------------

test "Namco 108: the last two PRG banks are fixed, whatever bit 6 says" {
    const banks = testBanks();
    var m = Mmc3.init(.namco108, .horizontal);
    setBankReg(&m, banks, 6, 3);
    setBankReg(&m, banks, 7, 5);

    try testing.expectEqual(@as(u8, 3), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, 5), m.cpuRead(banks, 0xA000).?);
    try testing.expectEqual(@as(u8, test_prg_banks - 2), m.cpuRead(banks, 0xC000).?);
    try testing.expectEqual(@as(u8, test_prg_banks - 1), m.cpuRead(banks, 0xE000).?);

    // Setting the MMC3's PRG mode bit changes nothing here: the 108 has no
    // such bit, so $46 selects R6 and leaves the windows where they are.
    m.cpuWrite(banks, 0x8000, 0x40 | 6, 0);
    try testing.expectEqual(@as(u8, 3), m.cpuRead(banks, 0x8000).?);
    try testing.expectEqual(@as(u8, test_prg_banks - 2), m.cpuRead(banks, 0xC000).?);
}

test "Namco 108: the 2 KiB banks are always the left table's" {
    const banks = testBanks();
    var m = Mmc3.init(.namco108, .horizontal);
    setBankReg(&m, banks, 0, 4);
    setBankReg(&m, banks, 2, 9);

    try testing.expectEqual(@as(u8, 4), m.ppuRead(banks, 0x0000));
    try testing.expectEqual(@as(u8, 9), m.ppuRead(banks, 0x1000));

    // The MMC3's CHR inversion bit is not wired, so the halves stay put.
    m.cpuWrite(banks, 0x8000, 0x80, 0);
    try testing.expectEqual(@as(u8, 4), m.ppuRead(banks, 0x0000));
    try testing.expectEqual(@as(u8, 9), m.ppuRead(banks, 0x1000));
}

test "Namco 108: bank numbers are two bits narrower than the MMC3's" {
    const banks = testBanks();
    var m = Mmc3.init(.namco108, .horizontal);

    // $C0 is bank 0 on this chip: bits 7-6 are not wired for CHR.
    setBankReg(&m, banks, 2, 0xC0 | 5);
    try testing.expectEqual(@as(u8, 5), m.ppuRead(banks, 0x1000));
    // And PRG keeps only four bits, for 128 KiB.
    setBankReg(&m, banks, 6, 0x30 | 3);
    try testing.expectEqual(@as(u8, 3), m.cpuRead(banks, 0x8000).?);
}

test "Namco 108: nothing above $9FFF is decoded, and there is no WRAM" {
    const banks = testBanks();
    var m = Mmc3.init(.namco108, .vertical);

    // The MMC3's mirroring register: a 108 board's mirroring is solder pads.
    m.cpuWrite(banks, 0xA000, 1, 0);
    try testing.expectEqual(Mirroring.vertical, m.mirroring());

    // Arming the MMC3's IRQ counter, then clocking A12 the way a scanline
    // would. There is no counter here, so nothing can come of it.
    m.cpuWrite(banks, 0xC000, 1, 0);
    m.cpuWrite(banks, 0xC001, 0, 0);
    m.cpuWrite(banks, 0xE001, 0, 0);
    var dot: u64 = 100;
    for (0..4) |_| clockA12(&m, &dot);
    try testing.expect(!m.irq_flag);
    try testing.expect(!m.irqPending(dot + 100));

    // $6000-$7FFF is open bus, not RAM.
    m.cpuWrite(banks, 0x6000, 0x5A, 0);
    try testing.expectEqual(@as(?u8, null), m.cpuRead(banks, 0x6000));
}

test "$A000 selects mirroring, but a four-screen board overrides it" {
    var m = Mmc3.init(.mmc3, .horizontal);
    m.cpuWrite(undefined, 0xA000, 0, 0);
    try testing.expectEqual(Mirroring.vertical, m.mirroring());
    m.cpuWrite(undefined, 0xA000, 1, 0);
    try testing.expectEqual(Mirroring.horizontal, m.mirroring());

    var four = Mmc3.init(.mmc3, .four_screen);
    four.cpuWrite(undefined, 0xA000, 0, 0);
    try testing.expectEqual(Mirroring.four_screen, four.mirroring());
}

test "the IRQ line reaches the CPU a fixed number of dots after the counter hits zero" {
    var m = armedCounter(0);
    var dot: u64 = 100;
    m.ppuAddressBus(0x0000, dot);
    dot += a12_filter_dots;
    m.ppuAddressBus(0x1000, dot); // the clock: reloads to 0 and fires

    // The flag itself is up straight away...
    try testing.expect(m.irq_flag);
    // ...but the line the CPU samples lags it.
    var d: u64 = 0;
    while (d < irq_line_delay_dots) : (d += 1) {
        try testing.expect(!m.irqPending(dot + d));
    }
    try testing.expect(m.irqPending(dot + irq_line_delay_dots));
}

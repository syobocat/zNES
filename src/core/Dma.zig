// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! OAM DMA ($4014) and DMC sample-fetch DMA.
//!
//! Both steal CPU cycles rather than running alongside the CPU: while either
//! is active, `Nes.stepCycle` calls `step` instead of `Cpu.step`, so the CPU
//! resumes an interrupted instruction exactly where it left off once DMA
//! releases the bus.
//!
//! The two units are otherwise independent and only interact when both want to
//! perform a real memory access on the same CPU cycle -- occupying a halt,
//! dummy or alignment cycle is not an access, and those overlap freely. A
//! cycle where neither unit accesses anything is still a bus cycle, though:
//! the halted CPU goes on repeating its last read. See `step`.

const Dma = @This();
const Nes = @import("Nes.zig");

pub const init: Dma = .{};

oam_active: bool = false,
oam_page: u8 = 0,
/// 0..512, where 512 is a done sentinel rather than a real step. Even values
/// are read cycles, odd ones writes.
oam_index: u10 = 0,
/// 1 cycle if OAM DMA starts on an even CPU cycle, 2 if odd -- the 513-versus-
/// 514-cycle asymmetry, which exists to line the first read up with a get.
oam_alignment_cycles_left: u2 = 0,
oam_read_value: u8 = 0,

dmc_active: bool = false,
dmc_cycles_left: u3 = 0,

pub fn isActive(self: *const Dma) bool {
    return self.oam_active or self.dmc_active;
}

pub fn requestOam(self: *Dma, nes: *Nes, page: u8) void {
    self.oam_active = true;
    self.oam_page = page;
    self.oam_index = 0;
    self.oam_alignment_cycles_left = if (nes.total_cycles % 2 == 0) 1 else 2;
}

/// Marks a DMC fetch as requested. The 3-versus-4 cycle count is deliberately
/// not decided here: the halt might not happen on the very next cycle, because
/// `Nes.stepCycle` defers it for as long as the CPU keeps writing, and each
/// deferral flips which parity the halt eventually lands on. Computing the
/// count from the request cycle's parity would silently assume no deferral.
pub fn requestDmc(self: *Dma) void {
    self.dmc_active = true;
    self.dmc_cycles_left = 0;
}

/// Consumes exactly one CPU cycle of DMA activity.
///
/// DMC and OAM normally just both progress on the same cycle: their halt,
/// dummy and alignment steps need exclusive access to nothing, so they overlap
/// freely with each other and with the other unit's real accesses. The one
/// real conflict is when both want their own real access on the same cycle.
/// DMC's fetch always lands on a get cycle, and so does every even-indexed
/// step of OAM DMA's read/write pairs. When they collide, DMC wins and OAM's
/// read is deferred: it keeps its place, `oam_index` unconsumed, and waits out
/// one more no-op cycle, since the next cycle is necessarily a put and its
/// next real chance is the get after that.
pub fn step(self: *Dma, nes: *Nes) void {
    const dmc_wants_access = self.dmc_active and self.dmc_cycles_left == 1;
    const oam_wants_read = self.oam_active and
        self.oam_alignment_cycles_left == 0 and
        self.oam_index % 2 == 0;

    if (dmc_wants_access and oam_wants_read) {
        _ = self.stepDmc(nes);
        self.oam_alignment_cycles_left = 1;
        return;
    }

    var accessed = false;
    if (self.dmc_active) accessed = self.stepDmc(nes);
    if (self.oam_active and self.stepOam(nes)) accessed = true;

    // Neither unit drove the bus, so this is one of the no-op cycles -- a
    // halt, a DMC dummy, or an alignment. The CPU is halted but not idle:
    // "when RDY is deasserted, the 6502 core repeats the last read cycle
    // indefinitely", and on a 2A03 those repeated reads are externally
    // visible, so the read really happens with every side effect it carries
    // (clearing $2002's VBlank flag, advancing $2007's address). Exactly one
    // bus cycle per CPU cycle: a no-op cycle for one unit that the other unit
    // fills with a real access is not a repeated read at all.
    if (!accessed) _ = readForDma(nes, nes.cpu.busAddress());
}

/// Called instead of `step` on a cycle where a DMC halt is pending but the CPU
/// is writing. A halt delayed by a write cancels an aborted DMA outright, so
/// this only ever discards the one-cycle kind; a normal DMA just waits.
pub fn cancelAbortedDmcIfHaltDelayed(self: *Dma, nes: *Nes) void {
    if (!self.dmc_active or self.dmc_cycles_left != 0) return;
    if (nes.apu.dmc.pending_reload != .single_cycle) return;
    self.endDmc(nes);
}

/// Tears the DMC unit down without a fetch.
///
/// `Dmc.completeDmaFetch` is normally the only thing that clears
/// `dma_pending`, and `needsDma` requires it clear, so an exit that skips the
/// fetch has to do that bookkeeping itself. Forgetting it leaves the DMC
/// permanently unable to request DMA again.
fn endDmc(self: *Dma, nes: *Nes) void {
    self.dmc_active = false;
    self.dmc_cycles_left = 0;
    nes.apu.dmc.dma_pending = false;
    nes.apu.dmc.pending_reload = .none;
}

/// One DMC cycle, reporting whether it drove the bus. See `step` for the
/// cycles that report false: hardware fills those with the halted CPU's
/// repeated read, which `step` issues once for the whole unit.
fn stepDmc(self: *Dma, nes: *Nes) bool {
    if (self.dmc_cycles_left == 0) {
        // This is the halt cycle: `Nes.stepCycle` only invokes `step` on a
        // cycle it has already confirmed is not a CPU write, and this is the
        // first such call since `requestDmc`.
        if (nes.apu.dmc.pending_reload == .single_cycle) {
            // The aborted-DMA case: playback stopped in the APU cycle before
            // this reload was scheduled, so the unit halts the CPU for one
            // cycle and then gives up -- no alignment, no dummy, no fetch.
            self.endDmc(nes);
            return false;
        }
        // The halt always commits from here, and once committed the transfer
        // runs to completion; stopping playback partway through does not
        // cancel it. Normally halt + dummy read + real read is 3 cycles, but a
        // halt that lands already put-aligned needs one alignment cycle first.
        // Alignment is global CPU cycle parity, unrelated to instruction
        // boundaries.
        self.dmc_cycles_left = if (nes.total_cycles % 2 == 0) 3 else 4;
    }

    self.dmc_cycles_left -= 1;
    if (self.dmc_cycles_left == 0) {
        self.dmc_active = false;
        const byte = readForDma(nes, nes.apu.dmc.current_addr);
        nes.apu.dmc.completeDmaFetch(byte, nes.total_cycles);
        return true;
    }
    return false;
}

/// One OAM cycle, reporting whether it drove the bus -- the halt and alignment
/// cycles do not, and `step` covers them. See `stepDmc`.
fn stepOam(self: *Dma, nes: *Nes) bool {
    if (self.oam_alignment_cycles_left > 0) {
        self.oam_alignment_cycles_left -= 1;
        return false;
    }

    if (self.oam_index % 2 == 0) {
        const addr: u16 = (@as(u16, self.oam_page) << 8) | @as(u8, @truncate(self.oam_index / 2));
        self.oam_read_value = readForDma(nes, addr);
    } else {
        // A put cycle is a real bus write driven by the 2A03, so it refreshes
        // *both* data buses -- including the internal one, which a DMA read
        // deliberately leaves alone. That is what keeps $4015's undriven bit 5
        // tracking the DMA's own traffic while it walks the register mirrors.
        nes.open_bus = self.oam_read_value;
        nes.internal_bus = self.oam_read_value;
        // Routed through the $2004 path rather than straight into OAM:
        // while rendering, hardware drops the byte and only glitches OAMADDR.
        nes.ppu.writeOamData(self.oam_read_value);
    }

    self.oam_index += 1;
    if (self.oam_index >= 512) self.oam_active = false;
    return true;
}

/// A read performed *by* a DMA unit rather than by the 6502 core.
///
/// Hardware decides whether the 2A03's own registers are switched on without
/// ever looking at the DMA's full address: it takes bits 15-5 from the core's
/// (frozen) address and bits 4-0 from whichever address the DMA is driving. So
/// the registers are live exactly when the halted core was itself reading
/// $4000-$401F, and the register the DMA lands on is `$4000 | (addr & $1F)` --
/// meaning a DMC sample fetch out of PRG ROM can spuriously clock a controller.
///
/// When that happens there can be *two* drivers on the external data bus: the
/// register, and whatever memory the DMA was actually aiming at. They do not
/// resolve the same way for every register, and the byte left on the external
/// bus is not always the byte the DMA keeps:
///
///  - **$4016/$4017 (controllers)**: a real conflict. The controller wins bits
///    0-4 (bit 0 is its shift output, bits 1-4 it pulls low) and memory keeps
///    bits 5-7. That mix is what the external bus ends up holding, and what a
///    later open-bus read sees. The DMA's own latch is different: when a memory
///    device really is driving, the DMA captures its byte intact; only when the
///    target is unmapped does the DMA latch the mix.
///  - **$4015 (APU status)**: no conflict, because the read never reaches the
///    external bus -- the 2A03 services it internally. Memory goes on driving
///    the external bus unopposed while the DMA latches the register's value.
///  - Everything else in the range is write-only, so memory has the bus to
///    itself.
///
/// When the registers are *not* active, a DMA aimed straight at $4000-$401F
/// finds nothing driving at all and reads open bus.
fn readForDma(nes: *Nes, addr: u16) u8 {
    // Register activation looks at bits 15-5 of the *core's* address, so this
    // single test decides it for every possible DMA address.
    const regs_active = (nes.cpu.busAddress() & 0xFFE0) == 0x4000;

    if (!regs_active) {
        if (addr >= 0x4000 and addr <= 0x401F) return nes.open_bus;
        return nes.dmaRead(addr);
    }

    // Whether some memory device out on the board drives the bus alongside the
    // register. When nothing does, the "memory value" is just the stale
    // external bus and the register's output is all there is to see.
    const mem_drives = memoryDrives(nes, addr);
    const mem_value = if (mem_drives) nes.cpuPeek(addr) else nes.open_bus;

    switch (0x4000 | (addr & 0x001F)) {
        0x4015 => {
            const value = nes.apu.readStatus(nes);
            nes.open_bus = mem_value;
            return value;
        },
        0x4016, 0x4017 => {
            nes.open_bus = mem_value; // what the controller mixes into
            const conflicted = nes.dmaRead(0x4000 | (addr & 0x001F));
            return if (mem_drives) mem_value else conflicted;
        },
        else => {
            nes.open_bus = mem_value;
            return mem_value;
        },
    }
}

/// Whether a memory device actually drives the external data bus for `addr`,
/// as opposed to the read falling through to open bus. Only used to resolve
/// DMA bus conflicts, where it decides whether two drivers are fighting or the
/// register has the bus to itself.
fn memoryDrives(nes: *Nes, addr: u16) bool {
    return switch (addr) {
        0x0000...0x1FFF => true, // internal RAM
        0x2000...0x3FFF => switch (addr & 0x0007) {
            2, 4, 7 => true,
            else => false, // the write-only PPU registers read as open bus
        },
        0x4000...0x401F => false, // the 2A03 itself, handled by the caller
        0x4020...0xFFFF => nes.cart.cpuRead(addr) != null,
    };
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;
const Cartridge = @import("cart/Cartridge.zig");

/// A blank 32 KiB NROM image whose reset vector points at $8000, where an
/// endless `JMP $8000` sits. That keeps the CPU doing something with a known,
/// write-free cycle shape while a DMA runs.
const spin_rom: [16 + 32 * 1024]u8 = blk: {
    var bytes: [16 + 32 * 1024]u8 = @splat(0);
    bytes[0..4].* = .{ 'N', 'E', 'S', 0x1A };
    bytes[4] = 2; // 32 KiB PRG
    bytes[16 + 0x0000] = 0x4C; // JMP $8000
    bytes[16 + 0x0001] = 0x00;
    bytes[16 + 0x0002] = 0x80;
    // The reset vector at $FFFC, which is the top of this 32 KiB image.
    bytes[16 + 0x7FFC] = 0x00;
    bytes[16 + 0x7FFD] = 0x80;
    break :blk bytes;
};

fn spinningNes(cart: *Cartridge) Nes {
    cart.* = Cartridge.load(&spin_rom) catch unreachable;
    return Nes.init(cart);
}

/// Runs until `nes.total_cycles` is even or odd as asked, so a DMA can be
/// started on a known alignment.
fn alignTo(nes: *Nes, even: bool) void {
    while ((nes.total_cycles % 2 == 0) != even) nes.stepCycle();
}

test "OAM DMA takes 513 cycles from an even cycle and 514 from an odd one" {
    var cart: Cartridge = undefined;
    for ([_]bool{ true, false }) |even| {
        var nes = spinningNes(&cart);
        alignTo(&nes, even);

        const start = nes.total_cycles;
        nes.dma.requestOam(&nes, 0x02);
        while (nes.dma.isActive()) nes.stepCycle();
        // The write that triggers the DMA is not counted here, so this is the
        // stolen-cycle count itself: 512 transfer cycles plus alignment.
        try testing.expectEqual(
            @as(u64, if (even) 513 else 514),
            nes.total_cycles - start,
        );
    }
}

test "OAM DMA copies a whole page through the $2004 path" {
    var cart: Cartridge = undefined;
    var nes = spinningNes(&cart);
    for (0..256) |i| nes.ram[0x0300 + i] = @intCast(i);

    nes.dma.requestOam(&nes, 0x03);
    while (nes.dma.isActive()) nes.stepCycle();

    for (0..256) |i| {
        // Attribute bytes keep only five bits, which is the $2004 path's doing.
        const expected: u8 = if (i % 4 == 2) @as(u8, @intCast(i)) & 0xE3 else @intCast(i);
        try testing.expectEqual(expected, nes.ppu.oam[i]);
    }
}

test "a DMC fetch takes 3 cycles put-aligned and 4 get-aligned" {
    var cart: Cartridge = undefined;
    for ([_]bool{ true, false }) |even| {
        var nes = spinningNes(&cart);
        alignTo(&nes, even);

        nes.apu.dmc.bytes_remaining = 1;
        nes.apu.dmc.current_addr = 0x8000;
        nes.dma.requestDmc();

        const start = nes.total_cycles;
        while (nes.dma.isActive()) nes.stepCycle();
        try testing.expectEqual(@as(u64, if (even) 3 else 4), nes.total_cycles - start);
        try testing.expect(nes.apu.dmc.sample_buffer_filled);
    }
}

test "a DMC fetch on the same get cycle as an OAM read defers the OAM read" {
    var cart: Cartridge = undefined;
    var nes = spinningNes(&cart);
    nes.ram[0x0300] = 0xC3;

    // Both units are one cycle away from a real access: OAM is past its
    // alignment and sitting on an even (read) index, and the DMC's countdown
    // is about to reach its fetch.
    nes.dma.oam_active = true;
    nes.dma.oam_alignment_cycles_left = 0;
    nes.dma.oam_index = 0;
    nes.dma.oam_page = 0x03;
    nes.dma.dmc_active = true;
    nes.dma.dmc_cycles_left = 1;
    nes.apu.dmc.bytes_remaining = 1;
    nes.apu.dmc.current_addr = 0x8000;

    nes.dma.step(&nes);

    // The DMC took the cycle...
    try testing.expect(nes.apu.dmc.sample_buffer_filled);
    try testing.expect(!nes.dma.dmc_active);
    // ...and OAM kept its place, waiting out one no-op cycle before its next
    // chance, since the cycle after this one is necessarily a put.
    try testing.expectEqual(@as(u10, 0), nes.dma.oam_index);
    try testing.expectEqual(@as(u2, 1), nes.dma.oam_alignment_cycles_left);

    // The deferred read then happens normally.
    nes.dma.step(&nes); // the waited-out cycle
    nes.dma.step(&nes); // the read
    try testing.expectEqual(@as(u8, 0xC3), nes.dma.oam_read_value);
}

test "a DMC fetch and an OAM no-op cycle overlap without interfering" {
    var cart: Cartridge = undefined;
    var nes = spinningNes(&cart);

    // OAM is still in its alignment cycle, which needs exclusive access to
    // nothing, so the DMC's fetch may share the cycle with it.
    nes.dma.oam_active = true;
    nes.dma.oam_alignment_cycles_left = 1;
    nes.dma.dmc_active = true;
    nes.dma.dmc_cycles_left = 1;
    nes.apu.dmc.bytes_remaining = 1;
    nes.apu.dmc.current_addr = 0x8000;

    nes.dma.step(&nes);
    try testing.expect(nes.apu.dmc.sample_buffer_filled);
    try testing.expectEqual(@as(u2, 0), nes.dma.oam_alignment_cycles_left);
}

test "an aborted DMC DMA steals one cycle and fetches nothing" {
    var cart: Cartridge = undefined;
    var nes = spinningNes(&cart);
    alignTo(&nes, true);

    // Playback already stopped, and the buffer emptied close enough to the
    // stop that the unit halts and then gives up.
    nes.apu.dmc.pending_reload = .single_cycle;
    nes.apu.dmc.dma_pending = true;
    nes.dma.requestDmc();

    const start = nes.total_cycles;
    while (nes.dma.isActive()) nes.stepCycle();
    try testing.expectEqual(@as(u64, 1), nes.total_cycles - start);
    try testing.expect(!nes.apu.dmc.sample_buffer_filled);
    // The DMC must be left able to request DMA again.
    try testing.expect(!nes.apu.dmc.dma_pending);
}

test "a DMA read of $40xx sees open bus while the 2A03's registers are off" {
    var cart: Cartridge = undefined;
    var nes = spinningNes(&cart);
    // The CPU is spinning on `JMP $8000`, so its address bus is nowhere near
    // $4000-$401F and the registers are switched off.
    nes.open_bus = 0x5A;
    try testing.expectEqual(@as(u8, 0x5A), readForDma(&nes, 0x4016));
    try testing.expectEqual(@as(u8, 0x5A), readForDma(&nes, 0x4000));
}

test "with the registers active, a controller read conflicts only where memory is silent" {
    var cart: Cartridge = undefined;
    var nes = spinningNes(&cart);
    // Freeze the core's address bus inside the register window, which is what
    // switches the registers on for a DMA.
    nes.cpu.cycle = 0;
    nes.cpu.pc = 0x4016;

    // Aimed at RAM, which really drives: the DMA keeps memory's byte intact
    // even though the controller is mixing into the external bus.
    nes.ram[0x0016] = 0xFF;
    try testing.expectEqual(@as(u8, 0xFF), readForDma(&nes, 0x0016));

    // Aimed at unmapped space, where nothing else drives: the DMA latches the
    // conflicted mix, whose bits 1-4 the controller pulls low.
    nes.open_bus = 0xFF;
    const conflicted = readForDma(&nes, 0x4016);
    try testing.expectEqual(@as(u8, 0), conflicted & 0x1E);
}

test "a DMA read of $4015 latches the register while memory keeps the bus" {
    var cart: Cartridge = undefined;
    var nes = spinningNes(&cart);
    nes.cpu.cycle = 0;
    nes.cpu.pc = 0x4015;

    nes.apu.pulse1.length.enabled = true;
    nes.apu.pulse1.length.counter = 3;
    nes.ram[0x0015] = 0xAA;

    // The DMA gets the register's value...
    try testing.expectEqual(@as(u8, 0x01), readForDma(&nes, 0x0015) & 0x1F);
    // ...while memory is what stayed on the external bus.
    try testing.expectEqual(@as(u8, 0xAA), nes.open_bus);
}

test "memoryDrives distinguishes the readable PPU registers from the write-only ones" {
    var cart: Cartridge = undefined;
    var nes = spinningNes(&cart);
    try testing.expect(memoryDrives(&nes, 0x0000)); // RAM
    try testing.expect(memoryDrives(&nes, 0x2002)); // PPUSTATUS
    try testing.expect(memoryDrives(&nes, 0x2004)); // OAMDATA
    try testing.expect(memoryDrives(&nes, 0x3FFF)); // a $2007 mirror
    try testing.expect(!memoryDrives(&nes, 0x2000)); // PPUCTRL, write-only
    try testing.expect(!memoryDrives(&nes, 0x4015)); // the 2A03 itself
    try testing.expect(memoryDrives(&nes, 0x8000)); // PRG ROM
    try testing.expect(!memoryDrives(&nes, 0x4020)); // unmapped on NROM
}

test "an OAM DMA halt cycle repeats the halted CPU's read" {
    var cart: Cartridge = undefined;
    var nes = spinningNes(&cart);
    // Freeze the CPU's address bus on $2002, as if the DMA halted it partway
    // through `LDA $2002`. OAM DMA's halt and alignment cycles are no-op
    // cycles for the DMA, but not for the bus.
    nes.cpu.cycle = 0;
    nes.cpu.pc = 0x2002;
    nes.ppu.status.vblank = true;

    nes.dma.oam_active = true;
    nes.dma.oam_alignment_cycles_left = 1;
    nes.dma.step(&nes);

    try testing.expect(!nes.ppu.status.vblank);
}

test "an OAM read leaves no room for the halted CPU's read on the same cycle" {
    var cart: Cartridge = undefined;
    var nes = spinningNes(&cart);
    nes.cpu.cycle = 0;
    nes.cpu.pc = 0x2002;
    nes.ppu.status.vblank = true;

    // Past alignment: this cycle is a real get, so the DMA owns the bus and
    // the repeated read does not happen.
    nes.dma.oam_active = true;
    nes.dma.oam_alignment_cycles_left = 0;
    nes.dma.step(&nes);

    try testing.expect(nes.ppu.status.vblank);
}

test "a DMC dummy read has the side effects of a real one" {
    var cart: Cartridge = undefined;
    var nes = spinningNes(&cart);
    // Freeze the CPU's address bus on $2002, which is what it would be reading
    // when a DMA halted it mid-`LDA $2002`.
    nes.cpu.cycle = 0;
    nes.cpu.pc = 0x2002;
    nes.ppu.status.vblank = true;

    _ = readForDma(&nes, nes.cpu.busAddress());
    try testing.expect(!nes.ppu.status.vblank);
}

//! The whole console: owns every component and drives the master clock.
//!
//! The CPU clock is the fundamental unit. Every CPU cycle `stepCycle` advances
//! the PPU by 3 dots and the APU by 1 cycle, and then lets the CPU -- or an
//! active DMA -- consume its own cycle. DMA is modelled as extra CPU-cycle-
//! shaped steps injected by `Dma`, so it stays in lockstep with the PPU and
//! APU regardless of when it preempts the CPU.
//!
//! This is also the bus: `cpuRead`/`cpuWrite` are where address decoding,
//! mirroring and open bus live, so no component needs to know the memory map.
//!
//! ## Three verbs for advancing time
//!
//! The core uses them consistently and they are not interchangeable:
//!
//!  - `tick` advances a component by one of *its own* clocks -- a PPU dot, an
//!    APU cycle, one step of a channel's timer.
//!  - `step` advances by one *bus* cycle, which is the CPU's unit. Only the
//!    things that can drive the bus have one: `Cpu`, `Dma`, and `stepCycle`
//!    here.
//!  - `clock` is a discrete event arriving from somewhere else -- the frame
//!    sequencer reaching a channel, an A12 edge reaching a mapper's counter.
//!    A `clock` is not periodic in the callee's own time.
//!
//! Components likewise get an `init`: `pub const init: T = .{}` when there is
//! nothing to configure, `pub fn init(...)` when there is. Inner register and
//! state structs are plain data and just use `.{}`.

const Nes = @This();
const Cpu = @import("cpu/Cpu.zig");
const Ppu = @import("ppu/Ppu.zig");
const Palette = @import("video/Palette.zig");
const Apu = @import("apu/Apu.zig");
const Cartridge = @import("cart/Cartridge.zig");
const Controller = @import("peripheral/Controller.zig");
const Zapper = @import("peripheral/Zapper.zig");
const Dma = @import("Dma.zig");

/// What is plugged into the two controller ports.
///
/// **This is a property of the desk, not of the console.** Flipping the power
/// switch does not unplug anything, so `powerOn` leaves this alone -- and
/// leaves the Zapper pointed where the player is pointing it.
pub const Peripherals = enum {
    /// A standard controller in each port.
    standard,
    /// A standard controller in port 1 and a Zapper in port 2, which is where
    /// every licensed light gun game looks for one.
    zapper,
};

cpu: Cpu,
ppu: Ppu,
apu: Apu,
cart: *Cartridge,
dma: Dma,

peripherals: Peripherals = .standard,

/// One per port, read directly unless a peripheral is in the way.
controllers: [2]Controller,
zapper: Zapper,

/// 2 KiB of internal CPU RAM, mirrored through $0000-$1FFF.
ram: [0x0800]u8,

/// The last value any device drove onto the CPU's *external* data bus, whether
/// by a CPU read or write or a DMA read or write. Unmapped and write-only
/// addresses read this back as open bus. No decay is modelled.
open_bus: u8 = 0,

/// The 6502 core's own data bus, *inside* the 2A03. It normally tracks
/// `open_bus` exactly, since every core read pulls the external bus in and
/// every core write pushes onto it. Two things separate them:
///
///  - Reading $4015 is serviced entirely within the 2A03, so it updates this
///    bus but never the external one.
///  - A DMA read is not a core read: the byte crosses the external bus into
///    the DMA unit's latch without the core ever seeing it, so it leaves this
///    bus untouched.
///
/// The distinction is observable because $4015's bit 5 is not driven by the
/// APU at all -- it comes from whatever this bus last held. A DMC DMA fetching
/// a byte with bit 5 set, one cycle before the CPU reads $4015, must not show
/// up in that bit.
internal_bus: u8 = 0,

/// Total CPU cycles since power-on or reset, including cycles spent on DMA.
total_cycles: u64 = 0,

/// Internal RAM's power-on contents. Hardware's are unreliable, so any fixed
/// pattern is a fiction -- but it has to be *one* fiction, shared by `init`
/// and `powerOn`, or "the same power-on" would mean two different things
/// depending on which entry point a caller used.
const ram_power_on_value: u8 = 0;

pub fn init(cart: *Cartridge) Nes {
    var nes: Nes = .{
        .cpu = .init,
        .ppu = Ppu.init(cart),
        .apu = .init,
        .cart = cart,
        .dma = .init,
        .controllers = @splat(.init),
        .zapper = .init,
        .ram = @splat(ram_power_on_value),
    };
    nes.cpu.reset();
    nes.runResetSequence();
    return nes;
}

/// Power-cycle: puts every component back to its power-on state without
/// reallocating anything.
///
/// **This is not `reset`.** A reset leaves most state alone; a power-on
/// rebuilds it. The CPU registers in particular have to be cleared here --
/// `Cpu.reset` deliberately leaves A/X/Y/P alone and only takes S down by 3,
/// which is right for the reset button and wrong for a cold boot. The mapper's
/// registers go back to their power-on values too.
pub fn powerOn(self: *Nes) void {
    self.ram = @splat(ram_power_on_value);
    self.cpu = .init;
    self.ppu.powerOn();
    self.apu.powerOn();
    self.cart.powerOn();
    self.dma = .init;
    // Everything in a peripheral that holds state -- shift registers, the
    // gun's trigger capacitor -- is electrically part of the console and goes
    // with it. Where the player is pointing is not.
    const aim = self.zapper.aim;
    self.controllers = @splat(.init);
    self.zapper = .init;
    self.zapper.aim = aim;
    self.open_bus = 0;
    self.internal_bus = 0;
    self.total_cycles = 0;
    self.cpu.reset();
    self.runResetSequence();
}

pub fn reset(self: *Nes) void {
    self.ppu.reset();
    self.apu.reset(self);
    self.cpu.reset();
    self.runResetSequence();
}

fn runResetSequence(self: *Nes) void {
    while (self.cpu.resetting) self.stepCycle();
}

/// Advances the system by exactly one CPU cycle's worth of bus activity,
/// running a pending DMA cycle instead of a CPU cycle where applicable.
pub fn stepCycle(self: *Nes) void {
    self.ppu.tick();
    self.ppu.tick();
    self.ppu.tick();
    self.apu.tick(self);

    // NMI edge detection must see every cycle, even ones DMA steals from the
    // CPU, so interrupt hijacking stays correct regardless of DMA.
    self.cpu.pollEdges(self);

    self.apu.dmc.tickStartupDelay();

    // The DMC requests its own DMA reactively, as soon as its buffer empties,
    // rather than the CPU-side bus dispatch driving it: a fetch can be
    // requested on any cycle, not just on a $4015 or $4013 write. A DMC fetch
    // takes priority over an in-progress OAM DMA, which `Dma` pauses.
    if (self.apu.dmc.needsDma()) {
        self.apu.dmc.dma_pending = true;
        self.dma.requestDmc();
    }

    // Hardware only samples RDY -- a DMA's halt request -- on read cycles, so
    // a DMA can never preempt a write and an otherwise-ready one waits for the
    // CPU's next read. Since the CPU's cycle state stays frozen for as long as
    // a DMA runs, this check only matters at the moment DMA would start, or
    // resume after being deferred; once under way it keeps re-evaluating the
    // same frozen "not a write" state.
    if (self.dma.isActive() and !self.cpu.nextCycleIsWrite()) {
        // RDY held low mid-instruction; see `Cpu.dma_interrupted`.
        if (self.cpu.cycle != 0) self.cpu.dma_interrupted = true;
        self.dma.step(self);
    } else {
        self.dma.cancelAbortedDmcIfHaltDelayed(self);
        self.cpu.step(self);
    }

    // The controller strobe line is sampled on put cycles only. Sampling at
    // the end of the cycle rather than the top is what makes a one-cycle-wide
    // strobe pulse land on the cycle that actually produced it.
    if (self.total_cycles % 2 == 0) {
        for (&self.controllers) |*controller| controller.latchIfStrobing();
    }

    self.total_cycles += 1;
}

/// The CPU-facing bus read: returns the byte on the external data bus,
/// honouring open-bus fallback for unmapped and write-only regions, and
/// latches the result as the new open-bus value.
pub fn cpuRead(self: *Nes, addr: u16) u8 {
    const value = self.cpuPeek(addr);
    self.internal_bus = value;
    // $4015 is entirely internal to the 2A03, so reading it does not touch the
    // external data bus latch -- unlike every other readable address,
    // including every other APU register.
    if (addr != 0x4015) self.open_bus = value;
    return value;
}

/// A read performed by a DMA unit rather than by the 6502 core. Drives the
/// external data bus exactly as a core read would, but leaves `internal_bus`
/// alone: the byte goes straight into the DMA unit's latch without ever
/// passing through the core.
pub fn dmaRead(self: *Nes, addr: u16) u8 {
    const value = self.cpuPeek(addr);
    if (addr != 0x4015) self.open_bus = value;
    return value;
}

/// The same address decoding as `cpuRead` without touching the external data
/// bus latch. Used by DMA and by `cpuRead` itself.
///
/// Despite the name this is a real bus access with all the side effects of
/// one; `inspect` is the one that disturbs nothing.
pub fn cpuPeek(self: *Nes, addr: u16) u8 {
    return switch (addr) {
        0x0000...0x1FFF => self.ram[addr & 0x07FF],
        0x2000...0x3FFF => self.ppu.readRegister(@truncate(addr)),
        0x4000...0x4013 => self.open_bus, // write-only APU registers
        0x4014 => self.open_bus, // OAMDMA is write-only
        0x4015 => self.apu.readStatus(self),
        0x4016 => self.readPort(0),
        0x4017 => self.readPort(1),
        0x4018...0x401F => self.open_bus,
        0x4020...0xFFFF => self.cart.cpuRead(addr) orelse self.open_bus,
    };
}

/// One controller port, resolved through whatever is plugged into it.
fn readPort(self: *Nes, port: u1) u8 {
    return switch (self.peripherals) {
        .standard => self.controllers[port].read(self.open_bus, self.total_cycles),
        .zapper => if (port == 0)
            self.controllers[0].read(self.open_bus, self.total_cycles)
        else
            self.zapper.read(self.open_bus, self.zapperSensing(), self.ppu.dots_elapsed),
    };
}

/// Whether the Zapper's photodiode is still charged from the pixel it is
/// aimed at.
///
/// The gun sees one pixel, and only while the beam is passing it or has just
/// passed: `Zapper.holdDots` says how long "just" is for that pixel's
/// brightness. Reading the framebuffer is exactly right for this -- the entry
/// under the aim point is the last colour the beam put there, whether that
/// was a moment ago or a frame ago.
fn zapperSensing(self: *const Nes) bool {
    const aim = self.zapper.aim orelse return false;
    // An aim point off the bottom of the picture is a gun pointed past the
    // screen, which sees no light -- the same answer as being pointed away.
    const pixel = self.ppu.pixelAt(aim.x, aim.y) orelse return false;
    return self.ppu.dotsSinceDrawn(aim.x, aim.y) < Zapper.holdDots(pixel);
}

/// Reads a byte **without disturbing anything**, for debuggers, tests and
/// tooling.
///
/// `cpuPeek` clears the VBlank flag at $2002, advances the $2007 read buffer,
/// arms the frame-IRQ clear at $4015 and clocks a controller at $4016/$4017.
/// That is correct for its callers -- a DMA read *is* a bus access -- but
/// useless for looking. Registers whose value cannot be produced without side
/// effects are reported as open bus rather than faked.
pub fn inspect(self: *const Nes, addr: u16) u8 {
    return switch (addr) {
        0x0000...0x1FFF => self.ram[addr & 0x07FF],
        // The PPU and APU register files are all either side-effecting to read
        // or write-only, so there is nothing safe to hand back.
        0x2000...0x401F => self.open_bus,
        0x4020...0xFFFF => self.cart.inspect(addr) orelse self.open_bus,
    };
}

pub fn cpuWrite(self: *Nes, addr: u16, value: u8) void {
    // What the data bus held going into this write, before the CPU drove it.
    // The PPU latches this for about the first dot of a write because the
    // 6502 asserts R/W before the data is valid; see `Ppu.writeRegisterEarly`.
    const early = self.open_bus;
    self.open_bus = value;
    self.internal_bus = value;
    switch (addr) {
        0x0000...0x1FFF => self.ram[addr & 0x07FF] = value,
        0x2000...0x3FFF => self.ppu.writeRegisterEarly(@truncate(addr), value, early),
        0x4000...0x4013, 0x4015, 0x4017 => self.apu.writeRegister(self, addr, value),
        0x4014 => self.dma.requestOam(self, value),
        0x4016 => {
            // One wire reaches both ports, whatever is plugged into them.
            for (&self.controllers) |*controller| controller.writeStrobe(value);
        },
        0x4018...0x401F => {},
        0x4020...0xFFFF => self.cart.cpuWrite(addr, value, self.total_cycles),
    }
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// A blank 16 KiB NROM image. `Cartridge` aliases these bytes.
const blank_rom: [16 + 16 * 1024]u8 = blk: {
    var bytes: [16 + 16 * 1024]u8 = @splat(0);
    bytes[0..4].* = .{ 'N', 'E', 'S', 0x1A };
    bytes[4] = 1;
    break :blk bytes;
};

test "powerOn and init leave the machine in the same state" {
    var cart_a = try Cartridge.load(&blank_rom);
    var fresh = Nes.init(&cart_a);

    var cart_b = try Cartridge.load(&blank_rom);
    var used = Nes.init(&cart_b);
    // Dirty it thoroughly, then power-cycle.
    used.cpu.a = 0x5A;
    used.cpu.x = 0x5A;
    used.cpu.y = 0x5A;
    used.ram[0] = 0x5A;
    used.open_bus = 0x5A;
    for (0..20_000) |_| used.stepCycle();
    used.powerOn();

    try testing.expectEqual(fresh.cpu.a, used.cpu.a);
    try testing.expectEqual(fresh.cpu.x, used.cpu.x);
    try testing.expectEqual(fresh.cpu.y, used.cpu.y);
    try testing.expectEqual(fresh.cpu.s, used.cpu.s);
    try testing.expectEqual(fresh.cpu.status(), used.cpu.status());
    try testing.expectEqual(fresh.ram[0], used.ram[0]);
    try testing.expectEqual(fresh.total_cycles, used.total_cycles);
}

test "powerOn puts the mapper back to its power-on registers" {
    // MMC1's control register comes up as $0C, not 0, so a memset-style reset
    // would be wrong here.
    var rom_bytes: [16 + 16 * 1024]u8 = @splat(0);
    rom_bytes[0..4].* = .{ 'N', 'E', 'S', 0x1A };
    rom_bytes[4] = 1;
    rom_bytes[6] = 0x10; // mapper 1
    var cart = try Cartridge.load(&rom_bytes);
    var nes = Nes.init(&cart);

    cart.mapper.mmc1.control = 0x00;
    cart.mapper.mmc1.prg_bank = 0x0F;
    nes.powerOn();

    try testing.expectEqual(@as(u8, 0x0C), cart.mapper.mmc1.control);
    try testing.expectEqual(@as(u8, 0), cart.mapper.mmc1.prg_bank);
}

/// Strobes the ports and reads one of them `count` times, one read per pair
/// of cycles so no two look like a contiguous run. Returns bit 0 of each
/// read, first out in the low bit.
fn shiftOutPort(nes: *Nes, addr: u16, count: usize) u32 {
    nes.cpuWrite(0x4016, 1);
    nes.total_cycles += 1;
    for (&nes.controllers) |*controller| controller.latchIfStrobing();
    nes.cpuWrite(0x4016, 0);

    var out: u32 = 0;
    for (0..count) |i| {
        nes.total_cycles += 2;
        out |= @as(u32, nes.cpuRead(addr) & 1) << @intCast(i);
    }
    return out;
}

test "two standard controllers, one per port" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);

    nes.controllers[0].setButtons(0b0000_0011);
    nes.controllers[1].setButtons(0b0000_0101);

    // Past the eighth read the line goes high and stays there.
    try testing.expectEqual(@as(u32, 0b1111_1111_0000_0011), shiftOutPort(&nes, 0x4016, 16));
    try testing.expectEqual(@as(u32, 0b0000_0101), shiftOutPort(&nes, 0x4017, 8));
}

/// Puts the beam `dots` past the pixel at (`x`, `y`), with `pixel` drawn
/// there, and points the gun at it.
fn aimAt(nes: *Nes, x: u8, y: u8, pixel: Palette.Pixel, dots: u64) void {
    nes.peripherals = .zapper;
    nes.zapper.setAim(.{ .x = x, .y = y });
    nes.ppu.framebuffer[@as(usize, y) * Ppu.screen_width + x] = pixel;

    const drawn_at = @as(u64, y) * 341 + x + 1;
    nes.ppu.scanline = @intCast((drawn_at + dots) / 341);
    nes.ppu.dot = @intCast((drawn_at + dots) % 341);
}

test "the Zapper sees light only while the beam has just passed its aim point" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);

    // White, one scanline after the beam went by: bit 3 low means light.
    aimAt(&nes, 128, 60, 0x20, 341);
    try testing.expectEqual(@as(u8, 0), nes.cpuRead(0x4017) & 0x08);

    // The same pixel 30 scanlines later, which is past even white's window.
    aimAt(&nes, 128, 60, 0x20, 30 * 341);
    try testing.expectEqual(@as(u8, 0x08), nes.cpuRead(0x4017) & 0x08);

    // Black never registers, however fresh.
    aimAt(&nes, 128, 60, 0x0F, 1);
    try testing.expectEqual(@as(u8, 0x08), nes.cpuRead(0x4017) & 0x08);

    // Pointed away from the screen: the gun is still there and still says so.
    aimAt(&nes, 128, 60, 0x20, 341);
    nes.zapper.setAim(null);
    try testing.expectEqual(@as(u8, 0x08), nes.cpuRead(0x4017) & 0x08);
}

test "an aim point below the picture sees no light" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);
    nes.peripherals = .zapper;

    // Nothing in the core clamps the aim: the web build hands over whatever
    // the page said, so a y past the last row has to answer rather than read
    // off the end of the framebuffer.
    nes.zapper.setAim(.{ .x = 128, .y = 250 });
    try testing.expectEqual(@as(u8, 0x08), nes.cpuRead(0x4017) & 0x08);
    try testing.expectEqual(@as(?Palette.Pixel, null), nes.ppu.pixelAt(128, 250));

    // The last row on the picture still reads.
    try testing.expect(nes.ppu.pixelAt(255, 239) != null);
}

test "a Zapper in port 2 leaves port 1 a plain controller" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);
    nes.peripherals = .zapper;

    nes.controllers[0].setButtons(0b0000_1001);
    try testing.expectEqual(@as(u32, 0b0000_1001), shiftOutPort(&nes, 0x4016, 8));

    // And port 2 reports no shift register at all: bit 0 is open bus there,
    // not a controller's grounded line.
    nes.open_bus = 0xFF;
    try testing.expectEqual(@as(u8, 1), nes.cpuRead(0x4017) & 1);
}

test "inspect reads RAM and ROM without disturbing anything" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);

    nes.ram[0x10] = 0x5A;
    try testing.expectEqual(@as(u8, 0x5A), nes.inspect(0x0010));
    try testing.expectEqual(@as(u8, 0x5A), nes.inspect(0x0810)); // mirror

    // Looking at $2002 must not clear the VBlank flag the way a read does.
    nes.ppu.status.vblank = true;
    _ = nes.inspect(0x2002);
    try testing.expect(nes.ppu.status.vblank);
    _ = nes.cpuPeek(0x2002);
    try testing.expect(!nes.ppu.status.vblank);

    // Nor may it clock a controller.
    nes.controllers[0].setButton(.a, true);
    nes.controllers[0].writeStrobe(1);
    nes.controllers[0].latchIfStrobing();
    nes.controllers[0].writeStrobe(0);
    const shift_before = nes.controllers[0].shift;
    _ = nes.inspect(0x4016);
    try testing.expectEqual(shift_before, nes.controllers[0].shift);
}

test "RAM and the PPU registers mirror across their windows" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);

    nes.cpuWrite(0x0000, 0x5A);
    for ([_]u16{ 0x0800, 0x1000, 0x1800 }) |mirror| {
        try testing.expectEqual(@as(u8, 0x5A), nes.cpuRead(mirror));
    }

    // $2003 through any of its mirrors reaches OAMADDR.
    nes.cpuWrite(0x3FFB, 0x42);
    try testing.expectEqual(@as(u8, 0x42), nes.ppu.oam_addr);
}

test "reading $4015 updates the internal bus but not the external one" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);

    nes.open_bus = 0x5A;
    nes.internal_bus = 0x5A;
    const value = nes.cpuRead(0x4015);
    try testing.expectEqual(@as(u8, 0x5A), nes.open_bus); // untouched
    try testing.expectEqual(value, nes.internal_bus);

    // Every other readable address drives both.
    nes.ram[0] = 0x33;
    _ = nes.cpuRead(0x0000);
    try testing.expectEqual(@as(u8, 0x33), nes.open_bus);
    try testing.expectEqual(@as(u8, 0x33), nes.internal_bus);
}

test "a DMA read drives the external bus but leaves the core's bus alone" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);

    nes.ram[0x100] = 0x77;
    nes.internal_bus = 0x11;
    _ = nes.dmaRead(0x0100);
    try testing.expectEqual(@as(u8, 0x77), nes.open_bus);
    try testing.expectEqual(@as(u8, 0x11), nes.internal_bus);
}

test "an OAM DMA put refreshes both data buses" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);

    nes.internal_bus = 0x11;
    nes.open_bus = 0x11;
    nes.ram[0x0300] = 0xC3;
    nes.dma.requestOam(&nes, 0x03);
    // Run to just past the first read/write pair.
    while (nes.dma.oam_index < 2) nes.stepCycle();

    try testing.expectEqual(@as(u8, 0xC3), nes.open_bus);
    try testing.expectEqual(@as(u8, 0xC3), nes.internal_bus);
}

test "unmapped addresses read back the last value on the bus" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);

    nes.cpuWrite(0x0000, 0xA7); // drives the bus
    try testing.expectEqual(@as(u8, 0xA7), nes.cpuRead(0x401F));
    // NROM leaves $4020-$5FFF unmapped.
    try testing.expectEqual(@as(u8, 0xA7), nes.cpuRead(0x4020));
    // As are the write-only APU registers.
    try testing.expectEqual(@as(u8, 0xA7), nes.cpuRead(0x4000));
}

test "the warm-up ends about 29658 CPU cycles after power-on" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);

    var cycles: u64 = 0;
    while (nes.ppu.in_reset and cycles < 100_000) : (cycles += 1) nes.stepCycle();
    try testing.expect(!nes.ppu.in_reset);

    // The familiar figure is measured from the first *instruction*; this
    // counts from `init`, so it also covers the CPU's own 7-cycle reset
    // sequence. Pinned exactly so a change in frame timing shows up here
    // rather than silently sliding the warm-up around.
    try testing.expectEqual(@as(u64, 29_661), cycles);

    // And once it is over, the registers take writes.
    nes.cpuWrite(0x2000, 0x80);
    try testing.expect(nes.ppu.ctrl.nmi_enable);
}

test "a system reset re-arms the PPU warm-up" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);
    while (nes.ppu.in_reset) nes.stepCycle();

    nes.reset();
    try testing.expect(nes.ppu.in_reset);
    nes.cpuWrite(0x2001, 0x1E);
    try testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(nes.ppu.mask)));
}

test "a system reset stops the PPU asserting NMI" {
    var cart = try Cartridge.load(&blank_rom);
    var nes = Nes.init(&cart);
    while (nes.ppu.in_reset) nes.stepCycle();

    // Arm NMI the way a game does, and confirm it is really armed.
    nes.cpuWrite(0x2000, 0x80);
    while (!nes.ppu.status.vblank) nes.stepCycle();
    nes.cpu.nmi_pending = false;
    nes.stepCycle();
    try testing.expect(nes.cpu.nmi_pending);

    // A reset clears PPUCTRL, so the VBlank after it must not raise /NMI.
    // Software cannot see the enable latch directly -- it only ever sees the
    // NMI that should not have happened -- so this runs a whole frame and
    // checks none arrives.
    nes.reset();
    nes.cpu.nmi_pending = false;
    const deadline = nes.ppu.frame + 2;
    while (nes.ppu.frame < deadline) {
        nes.stepCycle();
        try testing.expect(!nes.cpu.nmi_pending);
    }
}

//! AccuracyCoin: the full 141-test accuracy suite, run headless as a
//! single test. znes scores 141/141; this pins that down so a regression
//! anywhere in the CPU, PPU, APU or DMA shows up as a named failure.
//!
//! The ROM has no blargg-style result protocol, so this drives it the way
//! a person would: boot to the menu, press Start to kick off
//! `AutomaticallyRunEveryTestInROM`, then poll `RunningAllTests` ($35) /
//! `PostAllTestTally` ($37) until the suite reports itself finished. All
//! rendering stays off for the whole automated run, so there is nothing on
//! screen to read; each test's verdict is taken straight from its
//! `result_*` byte in CPU RAM, per the table below.
//!
//! A result byte's low 2 bits are the state (0 = never ran, 1 = pass,
//! 2 = fail) and the upper 6 bits are a test-specific error subcode, which
//! is 1-based: subcode N means "subtest N failed".
//!
//! Five entries share the result address $03FF because they inspect
//! power-on state, so they can't be read back individually under automated
//! execution. They're marked `readable = false` and excluded from the
//! verdict rather than being counted as failures.
//!
//! Part of `zig build test-full` rather than `zig build test`: a whole run of
//! the suite takes the better part of a minute.

const std = @import("std");
const testing = std.testing;
const znes = @import("znes");
const Nes = znes.Nes;
const Cartridge = znes.Cartridge;

pub const Test = struct { name: []const u8, addr: u16, readable: bool = true };

pub const tests = [_]Test{
    .{ .name = "ROM is not writable", .addr = 0x0405 },
    .{ .name = "RAM Mirroring", .addr = 0x0403 },
    .{ .name = "PC Wraparound", .addr = 0x044D },
    .{ .name = "The Decimal Flag", .addr = 0x0474 },
    .{ .name = "The B Flag", .addr = 0x0475 },
    .{ .name = "Dummy read cycles", .addr = 0x0406 },
    .{ .name = "Dummy write cycles", .addr = 0x0407 },
    .{ .name = "Open Bus", .addr = 0x0408 },
    .{ .name = "All NOP instructions", .addr = 0x047D },

    .{ .name = "Addressing: Absolute Indexed", .addr = 0x046E },
    .{ .name = "Addressing: Zero Page Indexed", .addr = 0x046F },
    .{ .name = "Addressing: Indirect", .addr = 0x0470 },
    .{ .name = "Addressing: Indirect, X", .addr = 0x0471 },
    .{ .name = "Addressing: Indirect, Y", .addr = 0x0472 },
    .{ .name = "Addressing: Relative", .addr = 0x0473 },

    .{ .name = "SLO $03", .addr = 0x0409 },
    .{ .name = "SLO $07", .addr = 0x040A },
    .{ .name = "SLO $0F", .addr = 0x040B },
    .{ .name = "SLO $13", .addr = 0x040C },
    .{ .name = "SLO $17", .addr = 0x040D },
    .{ .name = "SLO $1B", .addr = 0x040E },
    .{ .name = "SLO $1F", .addr = 0x040F },

    .{ .name = "RLA $23", .addr = 0x0419 },
    .{ .name = "RLA $27", .addr = 0x041A },
    .{ .name = "RLA $2F", .addr = 0x041B },
    .{ .name = "RLA $33", .addr = 0x041C },
    .{ .name = "RLA $37", .addr = 0x041D },
    .{ .name = "RLA $3B", .addr = 0x041E },
    .{ .name = "RLA $3F", .addr = 0x041F },

    .{ .name = "SRE $43", .addr = 0x0420 },
    .{ .name = "SRE $47", .addr = 0x047F },
    .{ .name = "SRE $4F", .addr = 0x0422 },
    .{ .name = "SRE $53", .addr = 0x0423 },
    .{ .name = "SRE $57", .addr = 0x0424 },
    .{ .name = "SRE $5B", .addr = 0x0425 },
    .{ .name = "SRE $5F", .addr = 0x0426 },

    .{ .name = "RRA $63", .addr = 0x0427 },
    .{ .name = "RRA $67", .addr = 0x0428 },
    .{ .name = "RRA $6F", .addr = 0x0429 },
    .{ .name = "RRA $73", .addr = 0x042A },
    .{ .name = "RRA $77", .addr = 0x042B },
    .{ .name = "RRA $7B", .addr = 0x042C },
    .{ .name = "RRA $7F", .addr = 0x042D },

    .{ .name = "SAX $83", .addr = 0x042E },
    .{ .name = "SAX $87", .addr = 0x042F },
    .{ .name = "SAX $8F", .addr = 0x0430 },
    .{ .name = "SAX $97", .addr = 0x0431 },
    .{ .name = "LAX $A3", .addr = 0x0432 },
    .{ .name = "LAX $A7", .addr = 0x0433 },
    .{ .name = "LAX $AF", .addr = 0x0434 },
    .{ .name = "LAX $B3", .addr = 0x0435 },
    .{ .name = "LAX $B7", .addr = 0x0436 },
    .{ .name = "LAX $BF", .addr = 0x0437 },

    .{ .name = "DCP $C3", .addr = 0x0438 },
    .{ .name = "DCP $C7", .addr = 0x0439 },
    .{ .name = "DCP $CF", .addr = 0x043A },
    .{ .name = "DCP $D3", .addr = 0x043B },
    .{ .name = "DCP $D7", .addr = 0x043C },
    .{ .name = "DCP $DB", .addr = 0x043D },
    .{ .name = "DCP $DF", .addr = 0x043E },

    .{ .name = "ISC $E3", .addr = 0x043F },
    .{ .name = "ISC $E7", .addr = 0x0440 },
    .{ .name = "ISC $EF", .addr = 0x0441 },
    .{ .name = "ISC $F3", .addr = 0x0442 },
    .{ .name = "ISC $F7", .addr = 0x0443 },
    .{ .name = "ISC $FB", .addr = 0x0444 },
    .{ .name = "ISC $FF", .addr = 0x0445 },

    .{ .name = "SHA $93", .addr = 0x0446 },
    .{ .name = "SHA $9F", .addr = 0x0447 },
    .{ .name = "SHS $9B", .addr = 0x0448 },
    .{ .name = "SHY $9C", .addr = 0x0449 },
    .{ .name = "SHX $9E", .addr = 0x044A },
    .{ .name = "LAE $BB", .addr = 0x044B },

    .{ .name = "ANC $0B", .addr = 0x0410 },
    .{ .name = "ANC $2B", .addr = 0x0411 },
    .{ .name = "ASR $4B", .addr = 0x0412 },
    .{ .name = "ARR $6B", .addr = 0x0413 },
    .{ .name = "ANE $8B", .addr = 0x0414 },
    .{ .name = "LXA $AB", .addr = 0x0415 },
    .{ .name = "AXS $CB", .addr = 0x0416 },
    .{ .name = "SBC $EB", .addr = 0x0417 },

    .{ .name = "Interrupt flag latency", .addr = 0x0461 },
    .{ .name = "NMI Overlap BRK", .addr = 0x0462 },
    .{ .name = "NMI Overlap IRQ", .addr = 0x0463 },

    .{ .name = "DMA + Open Bus", .addr = 0x046C },
    .{ .name = "DMA + $2002 Read", .addr = 0x0488 },
    .{ .name = "DMA + $2007 Read", .addr = 0x044C },
    .{ .name = "DMA + $2007 Write", .addr = 0x044F },
    .{ .name = "DMA + $4015 Read", .addr = 0x045D },
    .{ .name = "DMA + $4016 Read", .addr = 0x045E },
    .{ .name = "DMC DMA Bus Conflicts", .addr = 0x046B },
    .{ .name = "DMC DMA + OAM DMA", .addr = 0x0477 },
    .{ .name = "Explicit DMA Abort", .addr = 0x0479 },
    .{ .name = "Implicit DMA Abort", .addr = 0x0478 },

    .{ .name = "APU Length Counter", .addr = 0x0465 },
    .{ .name = "APU Length Table", .addr = 0x0466 },
    .{ .name = "Frame Counter IRQ", .addr = 0x0467 },
    .{ .name = "Frame Counter 4-step", .addr = 0x0468 },
    .{ .name = "Frame Counter 5-step", .addr = 0x0469 },
    .{ .name = "Delta Modulation Channel", .addr = 0x046A },
    .{ .name = "APU Register Activation", .addr = 0x045C },
    .{ .name = "Controller Strobing", .addr = 0x045F },
    .{ .name = "Controller Clocking", .addr = 0x047A },

    .{ .name = "PPU Reset Flag", .addr = 0x03FF, .readable = false },
    .{ .name = "CPU RAM (power-on)", .addr = 0x03FF, .readable = false },
    .{ .name = "CPU Registers (power-on)", .addr = 0x03FF, .readable = false },
    .{ .name = "PPU RAM (power-on)", .addr = 0x03FF, .readable = false },
    .{ .name = "Palette RAM (power-on)", .addr = 0x03FF, .readable = false },

    .{ .name = "CHR ROM is not writable", .addr = 0x0485 },
    .{ .name = "PPU Register Mirroring", .addr = 0x0404 },
    .{ .name = "PPU Register Open Bus", .addr = 0x044E },
    .{ .name = "PPU Read Buffer", .addr = 0x0476 },
    .{ .name = "Palette RAM Quirks", .addr = 0x047E },
    .{ .name = "Rendering Flag Behavior", .addr = 0x0486 },
    .{ .name = "$2007 read w/ rendering", .addr = 0x048A },
    .{ .name = "Attributes As Tiles", .addr = 0x0481 },

    .{ .name = "VBlank beginning", .addr = 0x0450 },
    .{ .name = "VBlank end", .addr = 0x0451 },
    .{ .name = "NMI Control", .addr = 0x0452 },
    .{ .name = "NMI Timing", .addr = 0x0453 },
    .{ .name = "NMI Suppression", .addr = 0x0454 },
    .{ .name = "NMI at VBlank end", .addr = 0x0455 },
    .{ .name = "NMI disabled at VBlank", .addr = 0x0456 },

    .{ .name = "Sprite overflow behavior", .addr = 0x0459 },
    .{ .name = "Sprite 0 Hit behavior", .addr = 0x0457 },
    .{ .name = "$2002 flag timing", .addr = 0x048D },
    .{ .name = "Suddenly Resize Sprite", .addr = 0x0489 },
    .{ .name = "Arbitrary Sprite zero", .addr = 0x0458 },
    .{ .name = "Misaligned OAM behavior", .addr = 0x045A },
    .{ .name = "Address $2004 behavior", .addr = 0x045B },
    .{ .name = "OAM Corruption", .addr = 0x047B },
    .{ .name = "INC $4014", .addr = 0x0480 },

    .{ .name = "t Register Quirks", .addr = 0x0482 },
    .{ .name = "Stale BG Shift Registers", .addr = 0x0483 },
    .{ .name = "Stale Sprite Shift Regs", .addr = 0x048F },
    .{ .name = "BG Serial In", .addr = 0x0487 },
    .{ .name = "Sprites On Scanline 0", .addr = 0x0484 },
    .{ .name = "$2004 Stress Test", .addr = 0x048C },
    .{ .name = "$2007 Stress Test", .addr = 0x048E },
    .{ .name = "ALE + Read", .addr = 0x0491 },
    .{ .name = "Hybrid Addresses", .addr = 0x0492 },

    .{ .name = "Instruction Timing", .addr = 0x0460 },
    .{ .name = "Implied Dummy Reads", .addr = 0x046D },
    .{ .name = "Branch Dummy Reads", .addr = 0x048B },
    .{ .name = "JSR Edge Cases", .addr = 0x047C },
    .{ .name = "Internal Data Bus", .addr = 0x0490 },
};
/// How many CPU frames to let the suite run before declaring it wedged.
/// A passing run finishes in a little over 4000.
const frame_budget: u32 = 7200;

/// Every test the ROM's own runner is expected to attempt. Distinct from
/// the number this file can read back: see the `readable` note above.
const expected_attempts: u8 = 141;

fn runFrames(nes: *Nes, count: u32) void {
    const target = nes.ppu.frame + count;
    while (nes.ppu.frame < target) nes.stepCycle();
}

/// What a run of the suite ended up doing. A bare pass/fail count cannot tell
/// the three distinct ways this can go wrong apart: a genuine hang, the ROM's
/// own runner losing its place (which shows up as tests never running, *not*
/// as failures), and a real behavioural regression (which shows up as
/// failures with the attempt count intact).
const Run = struct {
    timed_out: bool,
    jammed: bool,
    /// High-water mark of `PostAllTestTally`, incremented once per test
    /// the ROM's runner actually dispatches. Sampled only while
    /// `RunningAllTests` is set, since the ROM zeroes it afterwards to
    /// reuse it for the results screen.
    attempted: u8,
};

fn runSuite(nes: *Nes) Run {
    // Boot to the main menu.
    runFrames(nes, 120);

    // Press Start with the cursor at its power-on position to reach
    // `AutomaticallyRunEveryTestInROM`.
    nes.controllers[0].setButton(.start, true);
    runFrames(nes, 4);
    nes.controllers[0].setButton(.start, false);
    runFrames(nes, 4);

    var attempted: u8 = 0;
    var frames: u32 = 0;
    while (frames < frame_budget) : (frames += 1) {
        runFrames(nes, 1);
        const running = nes.ram[0x0035] != 0;
        const tally = nes.ram[0x0037];
        if (running and tally > attempted) attempted = tally;
        if (!running and tally != 0) {
            return .{ .timed_out = false, .jammed = nes.cpu.jammed, .attempted = attempted };
        }
    }
    return .{ .timed_out = true, .jammed = nes.cpu.jammed, .attempted = attempted };
}

test "AccuracyCoin: all 141 tests pass" {
    // Heap-allocated only because `Nes` borrows a pointer to it and the
    // struct carries 16 KiB of cartridge RAM inline.
    const cart = try testing.allocator.create(Cartridge);
    defer testing.allocator.destroy(cart);
    cart.* = try Cartridge.load(@embedFile("roms/AccuracyCoin/AccuracyCoin.nes"));

    var nes = Nes.init(cart);
    nes.powerOn();
    const run = runSuite(&nes);

    var failed: u32 = 0;
    var never_ran: u32 = 0;
    for (tests) |t| {
        if (!t.readable) continue;
        const raw = nes.ram[t.addr];
        switch (raw & 0x3) {
            1 => {},
            2 => {
                failed += 1;
                std.debug.print("FAIL  {s} (${X:0>4} = ${X:0>2}, subtest {d})\n", .{ t.name, t.addr, raw, raw >> 2 });
            },
            else => {
                never_ran += 1;
                std.debug.print("----  {s} (${X:0>4} = ${X:0>2}) never ran\n", .{ t.name, t.addr, raw });
            },
        }
    }

    // Report the shape of the run before the verdict, so a failure message
    // says which of the three failure modes this is.
    if (run.timed_out or run.jammed or run.attempted != expected_attempts or failed > 0 or never_ran > 0) {
        std.debug.print(
            "AccuracyCoin: timed_out={} jammed={} attempted={d}/{d} failed={d} never_ran={d}\n",
            .{ run.timed_out, run.jammed, run.attempted, expected_attempts, failed, never_ran },
        );
    }

    try testing.expect(!run.jammed); // CPU hit a JAM opcode
    try testing.expect(!run.timed_out); // suite never reported itself finished
    try testing.expectEqual(expected_attempts, run.attempted); // ROM's runner skipped tests
    try testing.expectEqual(@as(u32, 0), never_ran);
    try testing.expectEqual(@as(u32, 0), failed);
}

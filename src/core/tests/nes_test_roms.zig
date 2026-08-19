// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! Slower integration tests that execute real test ROMs embedded from
//! `roms/`. Run with `zig build test-full`; kept out of `zig build test`
//! since these run hundreds of millions of instructions.
//!
//! **Every ROM here asserts its *current* result, not "passes".** A ROM this
//! emulator gets wrong is pinned to the exact failure it produces today, with
//! a comment saying why. That makes the suite fail in both directions: a
//! regression breaks a passing ROM, and *fixing* a known gap breaks its
//! expectation, which is the reminder that the gap is closed.
//!
//! ## Reading a result out of a test ROM
//!
//! Two protocols, and picking the wrong one silently passes everything, so
//! `expectRomResult` reports `error.RomHasNoMemoryProtocol` rather than
//! falling back to the other.
//!
//!  - **Memory protocol** (newer blargg shells): `$6001-$6003` hold the
//!    signature `$DE $B0 $61`, `$6000` holds `$80` while running, `$81`
//!    to request a reset, and the result code otherwise. Text output is a
//!    NUL-terminated string at `$6004`. `runMemoryProtocolRom` below.
//!  - **Screen only** (2005-era ROMs, `sprite_overflow_tests`,
//!    `vbl_nmi_timing`, `dmc_dma_during_read4`): nothing is written to
//!    `$6000` at all. blargg's font tiles are indexed by ASCII code, so
//!    nametable 0 read back as bytes *is* the printed message.
//!    `runToScreenText` below.
//!
//! **Do not use "the CPU settled into a repeating loop" as a stopping
//! condition.** These shells sit in a two-instruction `bit $2002 / bpl`
//! spin during warm-up, which any window-comparison heuristic mistakes
//! for the final "forever" loop -- roughly 6000 instructions in, long
//! before the ROM has run a single test.

const std = @import("std");
const testing = std.testing;
const znes = @import("znes");
const Nes = znes.Nes;
const Cartridge = znes.Cartridge;

const State = struct {
    pc: u16,
    a: u8,
    x: u8,
    y: u8,
    p: u8,
    sp: u8,
    ppu_scanline: u16,
    ppu_dot: u16,
    cyc: u64,
};

fn fieldAfter(line: []const u8, key: []const u8) ![]const u8 {
    const idx = std.mem.indexOf(u8, line, key) orelse return error.FieldNotFound;
    const start = idx + key.len;
    var end = start;
    while (end < line.len and line[end] != ' ') end += 1;
    return line[start..end];
}

fn parseLogLine(line: []const u8) !State {
    const pc = try std.fmt.parseInt(u16, line[0..4], 16);
    const a = try std.fmt.parseInt(u8, try fieldAfter(line, "A:"), 16);
    const x = try std.fmt.parseInt(u8, try fieldAfter(line, "X:"), 16);
    const y = try std.fmt.parseInt(u8, try fieldAfter(line, "Y:"), 16);
    const p = try std.fmt.parseInt(u8, try fieldAfter(line, "P:"), 16);
    const sp = try std.fmt.parseInt(u8, try fieldAfter(line, "SP:"), 16);

    const ppu_idx = std.mem.indexOf(u8, line, "PPU:") orelse return error.FieldNotFound;
    var rest = std.mem.trimStart(u8, line[ppu_idx + "PPU:".len ..], " ");
    const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return error.FieldNotFound;
    const ppu_scanline = try std.fmt.parseInt(u16, rest[0..comma], 10);
    rest = std.mem.trimStart(u8, rest[comma + 1 ..], " ");
    var end: usize = 0;
    while (end < rest.len and rest[end] != ' ') end += 1;
    const ppu_dot = try std.fmt.parseInt(u16, rest[0..end], 10);

    const cyc = try std.fmt.parseInt(u64, try fieldAfter(line, "CYC:"), 10);

    return .{ .pc = pc, .a = a, .x = x, .y = y, .p = p, .sp = sp, .ppu_scanline = ppu_scanline, .ppu_dot = ppu_dot, .cyc = cyc };
}

fn snapshot(nes: *Nes) State {
    return .{
        .pc = nes.cpu.pc,
        .a = nes.cpu.a,
        .x = nes.cpu.x,
        .y = nes.cpu.y,
        .p = nes.cpu.status(),
        .sp = nes.cpu.s,
        .ppu_scanline = nes.ppu.scanline,
        .ppu_dot = nes.ppu.dot,
        .cyc = nes.total_cycles,
    };
}

/// Runs the CPU forward until it's about to fetch a fresh opcode (i.e. one
/// full instruction just retired), matching the granularity nestest.log
/// snapshots at.
fn runOneInstruction(nes: *Nes) void {
    nes.stepCycle();
    while (nes.cpu.cycle != 0 or nes.cpu.resetting) nes.stepCycle();
}

fn loadRom(rom_bytes: []const u8) !Nes {
    const cart = try testing.allocator.create(Cartridge);
    errdefer testing.allocator.destroy(cart);
    cart.* = try Cartridge.load(rom_bytes);
    return Nes.init(cart);
}

/// `loadRom` heap-allocates the cartridge (since `Nes` only borrows a
/// pointer to it); this frees it. The cartridge itself owns nothing --
/// its ROM slices point into the `@embedFile` data.
fn unloadRom(nes: *Nes) void {
    testing.allocator.destroy(nes.cart);
}

// --- Memory protocol ($6000) ---------------------------------------------

const running = 0x80;
const needs_reset = 0x81;

fn hasSignature(nes: *Nes) bool {
    return nes.inspect(0x6001) == 0xDE and nes.inspect(0x6002) == 0xB0 and nes.inspect(0x6003) == 0x61;
}

/// The ROM's own NUL-terminated status text at `$6004`, with control
/// characters (it emits ANSI colour escapes) flattened to spaces so a
/// failure message stays on one line.
fn readProtocolText(nes: *Nes, buf: []u8) []const u8 {
    var n: usize = 0;
    var addr: u16 = 0x6004;
    while (n < buf.len) : (addr += 1) {
        const c = nes.inspect(addr);
        if (c == 0) break;
        buf[n] = if (c >= 0x20 and c < 0x7F) c else ' ';
        n += 1;
    }
    return std.mem.trim(u8, buf[0..n], " ");
}

/// Runs a memory-protocol ROM to completion and returns its result code
/// (0 = passed). Polls every 256 instructions rather than every one: the
/// ROM writes `$6000` well before it stops executing, and the check is
/// three bus peeks.
fn runMemoryProtocolRom(nes: *Nes, text_buf: []u8, text_out: *[]const u8) !u8 {
    // $81 means "press reset, but not sooner than 100ms from now" --
    // 100ms is ~179k CPU cycles, and these ROMs measure the delay, so
    // give it a comfortable margin rather than the bare minimum.
    const reset_delay_instructions = 200_000;
    const max_instructions = 60_000_000;

    var saw_signature = false;
    var reset_at: u64 = 0;
    var i: u64 = 0;
    while (i < max_instructions) : (i += 1) {
        runOneInstruction(nes);
        if (i % 256 != 0) continue;

        if (!saw_signature) {
            saw_signature = hasSignature(nes);
            continue;
        }
        switch (nes.inspect(0x6000)) {
            running => {},
            needs_reset => {
                if (reset_at == 0) {
                    reset_at = i + reset_delay_instructions;
                } else if (i >= reset_at) {
                    nes.reset();
                    reset_at = 0;
                }
            },
            else => |code| {
                text_out.* = readProtocolText(nes, text_buf);
                return code;
            },
        }
    }
    if (!saw_signature) return error.RomHasNoMemoryProtocol;
    return error.RomDidNotFinish;
}

/// Asserts a memory-protocol ROM still produces exactly `expected_code`.
/// `expected_code` is 0 for the ROMs this emulator gets right and the
/// ROM's own failure code for the ones it doesn't -- see the file header
/// for why the failing ones are pinned rather than skipped.
fn expectRomResult(comptime path: []const u8, expected_code: u8) !void {
    var nes = try loadRom(@embedFile(path));
    defer unloadRom(&nes);

    var text_buf: [1024]u8 = undefined;
    var text: []const u8 = "";
    const code = runMemoryProtocolRom(&nes, &text_buf, &text) catch |err| {
        // Most often `RomHasNoMemoryProtocol`: this ROM only prints to the
        // screen, so it belongs in `expectScreenText` instead.
        std.debug.print("\n{s}\n  {t}\n", .{ path, err });
        return err;
    };
    if (code != expected_code) {
        std.debug.print(
            "\n{s}\n  expected result code {d}, got {d}\n  ROM says: {s}\n",
            .{ path, expected_code, code, text },
        );
        if (expected_code != 0) {
            std.debug.print(
                "  (this ROM is a pinned known failure -- if it now passes, " ++
                    "the gap it records is closed; update this expectation)\n",
                .{},
            );
        }
        return error.UnexpectedRomResult;
    }
}

// --- Screen-text protocol ------------------------------------------------

/// Nametable 0 read back as ASCII. blargg's font puts each glyph at the
/// tile index matching its character code, so the raw tile bytes are the
/// printed text; anything outside printable ASCII is a blank tile.
fn readScreenText(nes: *Nes, buf: []u8) []const u8 {
    var n: usize = 0;
    for (0..30) |row| {
        for (0..32) |col| {
            if (n == buf.len) return buf[0..n];
            const c = nes.ppu.vram[row * 32 + col];
            buf[n] = if (c >= 0x21 and c < 0x7F) c else ' ';
            n += 1;
        }
        if (n == buf.len) return buf[0..n];
        buf[n] = '\n';
        n += 1;
    }
    return buf[0..n];
}

/// Runs frame by frame until `needle` shows up on screen, or the frame
/// budget runs out. Stopping early keeps the common (still-correct) case
/// cheap; the budget only gets spent when something changed.
fn runToScreenText(nes: *Nes, max_frames: u32, buf: []u8, needle: []const u8) []const u8 {
    var text: []const u8 = "";
    var frames: u32 = 0;
    while (frames < max_frames) : (frames += 1) {
        const target = nes.ppu.frame + 1;
        while (nes.ppu.frame < target) nes.stepCycle();
        text = readScreenText(nes, buf);
        if (std.mem.indexOf(u8, text, needle) != null) return text;
    }
    return text;
}

/// Asserts a screen-only ROM still prints `expected`. As with
/// `expectRomResult`, a ROM this emulator gets wrong is pinned to the
/// wrong text it prints today.
fn expectScreenText(comptime path: []const u8, max_frames: u32, expected: []const u8) !void {
    var nes = try loadRom(@embedFile(path));
    defer unloadRom(&nes);

    var buf: [32 * 31]u8 = undefined;
    const text = runToScreenText(&nes, max_frames, &buf, expected);
    if (std.mem.indexOf(u8, text, expected) == null) {
        std.debug.print(
            "\n{s}\n  expected the screen to contain \"{s}\", got:\n{s}\n",
            .{ path, expected, text },
        );
        return error.UnexpectedRomResult;
    }
}

// --- CPU -----------------------------------------------------------------

test "nestest: CPU trace matches the golden log for every official + unofficial opcode" {
    const rom_bytes = @embedFile("roms/nes-test-roms/other/nestest.nes");
    const log_bytes = @embedFile("roms/nes-test-roms/other/nestest.log");

    var cart = try Cartridge.load(rom_bytes);

    var nes = Nes.init(&cart);
    // nestest's documented "automation mode": after the normal reset
    // sequence completes, force PC to $C000 instead of following the
    // cartridge's own (interactive-menu) reset vector.
    nes.cpu.pc = 0xC000;

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, log_bytes, "\n"), '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        const expected = parseLogLine(line) catch |err| {
            std.debug.print("line {d}: failed to parse golden log line {s}: {}\n", .{ line_no, line, err });
            return err;
        };
        const actual = snapshot(&nes);

        if (!std.meta.eql(expected, actual)) {
            std.debug.print(
                "line {d} mismatch:\n  expected {any}\n  actual   {any}\n  log line: {s}\n",
                .{ line_no, expected, actual, line },
            );
            return error.TraceMismatch;
        }

        runOneInstruction(&nes);
    }
}

test "instr_test-v5: instruction correctness via checksum, per addressing-mode category" {
    const categories = [_][]const u8{
        "01-basics", "02-implied",  "03-immediate", "04-zero_page",
        "05-zp_xy",  "06-absolute", "07-abs_xy",    "08-ind_x",
        "09-ind_y",  "10-branches", "11-stack",     "12-jmp_jsr",
        "13-rts",    "14-rti",      "15-brk",       "16-special",
    };
    inline for (categories) |category| {
        try expectRomResult("roms/nes-test-roms/instr_test-v5/rom_singles/" ++ category ++ ".nes", 0);
    }
}

test "instr_test-v3: the older instruction suite, including its combined ROMs" {
    const categories = [_][]const u8{
        "01-implied",  "02-immediate", "03-zero_page", "04-zp_xy",
        "05-absolute", "06-abs_xy",    "07-ind_x",     "08-ind_y",
        "09-branches", "10-stack",     "11-jmp_jsr",   "12-rts",
        "13-rti",      "14-brk",       "15-special",
    };
    inline for (categories) |category| {
        try expectRomResult("roms/nes-test-roms/instr_test-v3/rom_singles/" ++ category ++ ".nes", 0);
    }
    // The combined builds run every category back to back, which is a much
    // longer run than any single ROM here.
    try expectRomResult("roms/nes-test-roms/instr_test-v3/all_instrs.nes", 0);
    try expectRomResult("roms/nes-test-roms/instr_test-v3/official_only.nes", 0);
}

test "nes_instr_test: independent instruction suite" {
    const categories = [_][]const u8{
        "01-implied",  "02-immediate", "03-zero_page", "04-zp_xy",
        "05-absolute", "06-abs_xy",    "07-ind_x",     "08-ind_y",
        "09-branches", "10-stack",     "11-special",
    };
    inline for (categories) |category| {
        try expectRomResult("roms/nes-test-roms/nes_instr_test/rom_singles/" ++ category ++ ".nes", 0);
    }
}

test "instr_misc: address wrapping, dummy reads, and APU dummy reads" {
    const categories = [_][]const u8{
        "01-abs_x_wrap", "02-branch_wrap", "03-dummy_reads", "04-dummy_reads_apu",
    };
    inline for (categories) |category| {
        try expectRomResult("roms/nes-test-roms/instr_misc/rom_singles/" ++ category ++ ".nes", 0);
    }
}

test "cpu_dummy_reads: dummy-read addresses match hardware" {
    try expectScreenText("roms/nes-test-roms/cpu_dummy_reads/cpu_dummy_reads.nes", 1200, "Passed");
}

test "cpu_dummy_writes: read-modify-write double-write behavior" {
    try expectRomResult("roms/nes-test-roms/cpu_dummy_writes/cpu_dummy_writes_oam.nes", 0);
    try expectRomResult("roms/nes-test-roms/cpu_dummy_writes/cpu_dummy_writes_ppumem.nes", 0);
}

test "cpu_exec_space: executing code out of I/O space, and open bus there" {
    try expectRomResult("roms/nes-test-roms/cpu_exec_space/test_cpu_exec_space_apu.nes", 0);
    try expectRomResult("roms/nes-test-roms/cpu_exec_space/test_cpu_exec_space_ppuio.nes", 0);
}

test "branch_timing_tests: branch cycle counts and page-crossing penalties" {
    try expectScreenText("roms/nes-test-roms/branch_timing_tests/1.Branch_Basics.nes", 1200, "PASSED");
    try expectScreenText("roms/nes-test-roms/branch_timing_tests/2.Backward_Branch.nes", 1200, "PASSED");
    try expectScreenText("roms/nes-test-roms/branch_timing_tests/3.Forward_Branch.nes", 1200, "PASSED");
}

test "instr_timing: instruction cycle counts across the whole opcode set" {
    try expectRomResult("roms/nes-test-roms/instr_timing/rom_singles/1-instr_timing.nes", 0);
    try expectRomResult("roms/nes-test-roms/instr_timing/rom_singles/2-branch_timing.nes", 0);
}

test "cpu_timing_test6: whole-instruction-set timing, reported on screen" {
    try expectScreenText("roms/nes-test-roms/cpu_timing_test6/cpu_timing_test.nes", 1800, "PASSED");
}

test "cpu_reset: register and RAM state across a reset" {
    try expectRomResult("roms/nes-test-roms/cpu_reset/registers.nes", 0);
    try expectRomResult("roms/nes-test-roms/cpu_reset/ram_after_reset.nes", 0);
}

test "cpu_interrupts_v2: interrupt polling and hijacking timing" {
    try expectRomResult("roms/nes-test-roms/cpu_interrupts_v2/rom_singles/1-cli_latency.nes", 0);
    try expectRomResult("roms/nes-test-roms/cpu_interrupts_v2/rom_singles/2-nmi_and_brk.nes", 0);
    try expectRomResult("roms/nes-test-roms/cpu_interrupts_v2/rom_singles/3-nmi_and_irq.nes", 0);
    try expectRomResult("roms/nes-test-roms/cpu_interrupts_v2/rom_singles/4-irq_and_dma.nes", 0);
}

// --- PPU -----------------------------------------------------------------

test "ppu_vbl_nmi: VBlank flag and NMI timing" {
    const passing = [_][]const u8{
        "01-vbl_basics",      "02-vbl_set_time",   "03-vbl_clear_time",
        "04-nmi_control",     "05-nmi_timing",     "06-suppression",
        "07-nmi_on_timing",   "08-nmi_off_timing", "09-even_odd_frames",
        "10-even_odd_timing",
    };
    inline for (passing) |category| {
        try expectRomResult("roms/nes-test-roms/ppu_vbl_nmi/rom_singles/" ++ category ++ ".nes", 0);
    }
}

test "vbl_nmi_timing: the older VBlank/NMI suite, reported on screen" {
    try expectScreenText("roms/nes-test-roms/vbl_nmi_timing/1.frame_basics.nes", 3000, "PASSED");
    try expectScreenText("roms/nes-test-roms/vbl_nmi_timing/2.vbl_timing.nes", 3000, "PASSED");
    try expectScreenText("roms/nes-test-roms/vbl_nmi_timing/3.even_odd_frames.nes", 3000, "PASSED");
    try expectScreenText("roms/nes-test-roms/vbl_nmi_timing/4.vbl_clear_timing.nes", 3000, "PASSED");
    try expectScreenText("roms/nes-test-roms/vbl_nmi_timing/5.nmi_suppression.nes", 3000, "PASSED");
    try expectScreenText("roms/nes-test-roms/vbl_nmi_timing/6.nmi_disable.nes", 3000, "PASSED");
    try expectScreenText("roms/nes-test-roms/vbl_nmi_timing/7.nmi_timing.nes", 3000, "PASSED");
}

test "blargg_ppu_tests_2005: palette/sprite RAM, VRAM access, VBL clear time" {
    // This suite reports a code on screen, and its "passed" code is $01,
    // not $00 (blargg_ppu_tests_2005.09.15b/readme.txt).
    try expectScreenText("roms/nes-test-roms/blargg_ppu_tests_2005.09.15b/palette_ram.nes", 900, "$01");
    try expectScreenText("roms/nes-test-roms/blargg_ppu_tests_2005.09.15b/sprite_ram.nes", 900, "$01");
    try expectScreenText("roms/nes-test-roms/blargg_ppu_tests_2005.09.15b/vram_access.nes", 900, "$01");
    try expectScreenText("roms/nes-test-roms/blargg_ppu_tests_2005.09.15b/vbl_clear_time.nes", 900, "$01");
    // power_up_palette is deliberately absent: it compares power-on palette
    // contents against the one console its author wrote it on, so its result
    // says nothing about any emulator.
}

test "sprite_hit_tests: sprite 0 hit pixel/timing accuracy" {
    const categories = [_][]const u8{
        "01.basics",        "02.alignment",    "03.corners",       "04.flip",
        "05.left_clip",     "06.right_edge",   "07.screen_bottom", "08.double_height",
        "09.timing_basics", "10.timing_order", "11.edge_timing",
    };
    inline for (categories) |category| {
        try expectScreenText("roms/nes-test-roms/sprite_hit_tests_2005.10.05/" ++ category ++ ".nes", 3000, "PASSED");
    }
}

test "sprite_overflow_tests: 8-sprite limit and overflow flag" {
    try expectScreenText("roms/nes-test-roms/sprite_overflow_tests/1.Basics.nes", 3000, "PASSED");
    try expectScreenText("roms/nes-test-roms/sprite_overflow_tests/2.Details.nes", 3000, "PASSED");
    try expectScreenText("roms/nes-test-roms/sprite_overflow_tests/3.Timing.nes", 3000, "PASSED");
    try expectScreenText("roms/nes-test-roms/sprite_overflow_tests/4.Obscure.nes", 3000, "PASSED");
    try expectScreenText("roms/nes-test-roms/sprite_overflow_tests/5.Emulator.nes", 3000, "PASSED");
}

test "oam_read: OAM readback via $2004" {
    try expectRomResult("roms/nes-test-roms/oam_read/oam_read.nes", 0);
}

test "oam_stress: heavy OAM read/write access patterns" {
    try expectRomResult("roms/nes-test-roms/oam_stress/oam_stress.nes", 0);
}

test "ppu_open_bus: PPU data bus behavior on unmapped/write-only reads" {
    try expectRomResult("roms/nes-test-roms/ppu_open_bus/ppu_open_bus.nes", 0);
}

test "ppu_read_buffer: $2007 read buffer quirks" {
    try expectRomResult("roms/nes-test-roms/ppu_read_buffer/test_ppu_read_buffer.nes", 0);
}

// --- APU / DMA -----------------------------------------------------------

test "apu_test: length counter, frame IRQ, and DMC basics/rates" {
    const passing = [_][]const u8{
        "1-len_ctr",    "2-len_table",       "3-irq_flag",   "4-jitter",
        "5-len_timing", "6-irq_flag_timing", "7-dmc_basics", "8-dmc_rates",
    };
    inline for (passing) |category| {
        try expectRomResult("roms/nes-test-roms/apu_test/rom_singles/" ++ category ++ ".nes", 0);
    }
}

test "blargg_apu_2005: frame counter and length counter timing, reported on screen" {
    // Passing code is $01 here too (blargg_apu_2005.07.30/tests.txt).
    const passing = [_][]const u8{
        "01.len_ctr",         "02.len_table",         "03.irq_flag",
        "04.clock_jitter",    "05.len_timing_mode0",  "06.len_timing_mode1",
        "07.irq_flag_timing", "08.irq_timing",        "09.reset_timing",
        "10.len_halt_timing", "11.len_reload_timing",
    };
    inline for (passing) |category| {
        try expectScreenText("roms/nes-test-roms/blargg_apu_2005.07.30/" ++ category ++ ".nes", 2400, "$01");
    }
}

test "apu_reset: APU state at power-on and across a reset" {
    try expectRomResult("roms/nes-test-roms/apu_reset/4015_cleared.nes", 0);
    try expectRomResult("roms/nes-test-roms/apu_reset/len_ctrs_enabled.nes", 0);
    try expectRomResult("roms/nes-test-roms/apu_reset/4017_timing.nes", 0);
    try expectRomResult("roms/nes-test-roms/apu_reset/4017_written.nes", 0);
    try expectRomResult("roms/nes-test-roms/apu_reset/irq_flag_cleared.nes", 0);
    try expectRomResult("roms/nes-test-roms/apu_reset/works_immediately.nes", 0);
}

test "apu_mixer: non-linear mixing of each channel" {
    try expectRomResult("roms/nes-test-roms/apu_mixer/square.nes", 0);
    try expectRomResult("roms/nes-test-roms/apu_mixer/triangle.nes", 0);
    try expectRomResult("roms/nes-test-roms/apu_mixer/noise.nes", 0);
    try expectRomResult("roms/nes-test-roms/apu_mixer/dmc.nes", 0);
}

test "sprdma_and_dmc_dma: OAM DMA + DMC DMA overlap" {
    try expectRomResult("roms/nes-test-roms/sprdma_and_dmc_dma/sprdma_and_dmc_dma.nes", 0);
    try expectRomResult("roms/nes-test-roms/sprdma_and_dmc_dma/sprdma_and_dmc_dma_512.nes", 0);
}

test "dmc_dma_during_read4: DMC DMA bus interaction with $2007/$4016 reads" {
    try expectScreenText("roms/nes-test-roms/dmc_dma_during_read4/dma_2007_write.nes", 3000, "Passed");
    try expectScreenText("roms/nes-test-roms/dmc_dma_during_read4/dma_4016_read.nes", 3000, "Passed");
    // These print a CRC over all their output rather than a verdict, and
    // hardware has more than one accepted answer depending on CPU-PPU
    // synchronization -- each ROM's source header lists them. `5E3DF9C4`
    // is one of dma_2007_read's two.
    try expectScreenText("roms/nes-test-roms/dmc_dma_during_read4/dma_2007_read.nes", 3000, "5E3DF9C4");
    try expectScreenText("roms/nes-test-roms/dmc_dma_during_read4/double_2007_read.nes", 3000, "85CFD627");
    try expectScreenText("roms/nes-test-roms/dmc_dma_during_read4/read_write_2007.nes", 3000, "Passed");
}

test "read_joy3: controller reads stay correct while DMC DMA is active" {
    try expectScreenText("roms/nes-test-roms/read_joy3/thorough_test.nes", 3000, "Passed");
}

// --- Mappers -------------------------------------------------------------

test "mmc3_test: MMC3 bank switching and the A12-driven IRQ counter" {
    const prefix = "roms/nes-test-roms/mmc3_test/";
    try expectRomResult(prefix ++ "1-clocking.nes", 0);
    try expectRomResult(prefix ++ "2-details.nes", 0);
    try expectRomResult(prefix ++ "3-A12_clocking.nes", 0);
    // Brackets the IRQ to an exact PPU dot, which pins both of `Mmc3`'s
    // timing constants: the A12 low-pass threshold (one dot looser and every
    // scanline clocks the counter twice) and the /IRQ propagation delay.
    try expectRomResult(prefix ++ "4-scanline_timing.nes", 0);
    try expectRomResult(prefix ++ "5-MMC3.nes", 0);
    // NOT A GAP, and not about the MMC6's registers -- znes implements that
    // chip (submapper 004:1). What this ROM checks is the same IRQ counter
    // revision difference `mmc3_test_2`'s 6-MMC3_alt does, under another
    // name: its own source says "some MMC3 chips also have this behavior".
    // Its test 3 and 5-MMC3's test 3 assert opposite results for the same
    // sequence, so at most one of the two can pass, and znes implements the
    // revision 5-MMC3 describes.
    try expectRomResult(prefix ++ "6-MMC6.nes", 3);
}

test "mmc3_test_2: the same suite's rom_singles, plus the alternate revision" {
    const prefix = "roms/nes-test-roms/mmc3_test_2/rom_singles/";
    try expectRomResult(prefix ++ "1-clocking.nes", 0);
    try expectRomResult(prefix ++ "2-details.nes", 0);
    try expectRomResult(prefix ++ "3-A12_clocking.nes", 0);
    try expectRomResult(prefix ++ "4-scanline_timing.nes", 0);
    try expectRomResult(prefix ++ "5-MMC3.nes", 0);
    // NOT A GAP, and not fixable alongside 5-MMC3: the two ROMs check
    // opposite chip revisions and the readme says at most one can pass.
    // znes implements the Sharp/"normal" one, so 5 passes and this fails.
    try expectRomResult(prefix ++ "6-MMC3_alt.nes", 2);
}

// --- Mappers with no verdict-reporting ROM -------------------------------

/// The switchable PRG bank register of whichever mapper is loaded, or 0 for a
/// board that has none. Used only by `expectBootsAndBanks`.
fn switchableBank(cart: *const Cartridge) u8 {
    return switch (cart.mapper) {
        .uxrom => |m| m.prg_bank,
        .axrom => |m| m.bank_select,
        .mmc2 => |m| m.prg_bank,
        .mmc1 => |m| m.prg_bank,
        .mmc3 => |m| m.bank_regs[6],
        // One latch holds both banks here, so a CHR switch counts as
        // movement too. That is the honest reading: on this board a game
        // cannot move one window without naming the other.
        .gnrom => |m| m.bank_select,
        .bnrom => |m| m.prg_bank,
        else => 0,
    };
}

/// Runs a ROM for `frames` and asserts that the CPU never reached a JAM opcode
/// and that something other than a flat backdrop reached the screen.
///
/// **This is as much as the mapper-2 and mapper-7 images in this corpus can be
/// held to.** They are a test suite's front end, a PCM demo and a hex dump --
/// none of them report a verdict anywhere a harness can read, and two of the
/// three want a controller. What they do exercise is the part that actually
/// breaks when a bank calculation is wrong: a board whose fixed window is off
/// by a bank lands the CPU on garbage within a frame or two, and one whose
/// switchable window is wrong stops drawing.
fn expectBoots(comptime path: []const u8, frames: u32, require_banking: bool) !void {
    var nes = try loadRom(@embedFile(path));
    defer unloadRom(&nes);

    const first_bank = switchableBank(nes.cart);
    var banked = false;
    for (0..frames) |_| {
        const target = nes.ppu.picture + 1;
        while (nes.ppu.picture < target) {
            nes.stepCycle();
            if (nes.cpu.jammed) {
                std.debug.print("\n{s}\n  CPU jammed\n", .{path});
                return error.UnexpectedRomResult;
            }
        }
        if (switchableBank(nes.cart) != first_bank) banked = true;
    }

    if (require_banking and !banked) {
        std.debug.print("\n{s}\n  never switched a PRG bank\n", .{path});
        return error.UnexpectedRomResult;
    }

    var seen: [512]bool = @splat(false);
    var colors: usize = 0;
    for (nes.ppu.framebuffer) |pixel| {
        if (!seen[pixel]) {
            seen[pixel] = true;
            colors += 1;
        }
    }
    if (colors < 3) {
        std.debug.print("\n{s}\n  drew {d} distinct colours, expected a picture\n", .{ path, colors });
        return error.UnexpectedRomResult;
    }
}

test "uxrom: mapper 2 boards boot, bank PRG and draw" {
    try expectBoots("roms/nes-test-roms/240pee/240pee.nes", 600, true);
    try expectBoots("roms/nes-test-roms/other/PCM.demo.wgraphics.nes", 600, true);
}

test "axrom: mapper 7 boards boot and draw" {
    // No banking to require: this ROM is 16 KiB, which is half of one AxROM
    // bank, so there is nothing for the register to select. What it does
    // exercise is the folding that puts that half-bank across the whole
    // $8000-$FFFF window -- get it wrong and the reset vector reads past the
    // end of the ROM. `Axrom`'s own tests cover the banking.
    try expectBoots("roms/nes-test-roms/other/oam3.nes", 600, false);
}

test "colordreams: mapper 11 boards boot, bank and draw" {
    // Four builds of one demo, differing only in which emulator's name they
    // put on screen. Each is 64 KiB of PRG and 64 KiB of CHR, so both halves
    // of the latch have somewhere to go.
    const prefix = "roms/nes-test-roms/other/";
    try expectBoots(prefix ++ "test001.nes", 600, true);
    try expectBoots(prefix ++ "fceuxd.nes", 600, true);
    try expectBoots(prefix ++ "nestopia.nes", 600, true);
    try expectBoots(prefix ++ "nintendulator.nes", 600, true);
}

test "bnrom: mapper 34 boards boot, bank PRG and draw" {
    try expectBoots("roms/nes-test-roms/240pee/240pee-bnrom.nes", 600, true);
}

// MMC2/MMC4 (mappers 9 and 10) and NINA-001 (mapper 34's other board) have no
// ROM here at all, so they are covered by their own unit tests only.

test "mmc3_irq_tests: the older MMC3 IRQ suite, reported on screen" {
    const prefix = "roms/nes-test-roms/mmc3_irq_tests/";
    try expectScreenText(prefix ++ "1.Clocking.nes", 3000, "PASSED");
    try expectScreenText(prefix ++ "2.Details.nes", 3000, "PASSED");
    try expectScreenText(prefix ++ "3.A12_clocking.nes", 3000, "PASSED");
    try expectScreenText(prefix ++ "4.Scanline_timing.nes", 3000, "PASSED");
    try expectScreenText(prefix ++ "6.MMC3_rev_B.nes", 3000, "PASSED");
    // NOT A GAP: revision A is the behavior znes deliberately doesn't
    // implement. The readme is explicit that 5 and 6 are mutually
    // exclusive, so this failing is what "6 passes" costs.
    try expectScreenText(prefix ++ "5.MMC3_rev_A.nes", 3000, "FAILED #3");
}

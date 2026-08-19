// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! Where a frame begins, checked against a ROM that can tell.
//!
//! Replaying a movie only works if the console reads each record at the same
//! point in its own execution that the emulator which recorded it did. FCEUX
//! -- whose `.fm2` files this player exists for -- takes its input for a frame
//! immediately before running the post-render scanline and entering VBlank. So
//! a record is latched **between the last visible dot and VBlank**, and stays
//! put for the whole of the following picture.
//!
//! Cut the loop anywhere else and a game that polls the controller in its
//! main loop rather than in its NMI handler sees the *next* record instead:
//! one frame of input arriving early, every frame. That is invisible in a
//! screenshot and fatal to a movie.
//!
//! The ROM below makes the difference observable. Every frame it reads the
//! controller twice -- once in VBlank, right after its NMI, and once about
//! forty scanlines later, well into the next picture -- and logs both. Both
//! reads belong to the same frame of the game's logic, so they must return
//! the same record. They only do if the frame boundary is in the right place.
//!
//! The same log pins down the two other ways a movie can slip a frame: the
//! console must consume exactly one record per frame with no drift, and a
//! record carrying a reset command must cost one record like any other rather
//! than leaving the console stranded mid-picture.

const std = @import("std");

const Session = @import("../Session.zig");
const Movie = @import("../Movie.zig");
const input = @import("input");

const testing = std.testing;

/// Where the ROM logs its VBlank reads, one byte per frame.
const vblank_log = 0x0200;
/// Where it logs its mid-picture reads.
const render_log = 0x0300;
/// Both logs are indexed by a byte, so this is all the ROM can record.
const log_capacity = 256;

/// How far into the movie the game's first NMI lands. This ROM waits for two
/// VBlanks before it enables NMI, so the first frame it can log is the third.
///
/// This is the console's own boot, not FCEUX's: the records a *movie player*
/// skips on top of it are `Movie.fceux_dead_frames`, and this test drives
/// playback from record 0 so that the two are measured separately.
const boot_frames = 2;

// --- The ROM -------------------------------------------------------------

/// A 6502 program that logs the controller twice per frame.
///
/// Assembled by hand, because the alternative is a build-time dependency on
/// an assembler for ninety bytes of code. Addresses are written out in the
/// comments so the branch offsets can be checked against them.
///
///     C000  RESET   SEI / CLD / LDX #$FF / TXS
///                   LDA #$00 / STA $2000 / STA $2001    ; NMI off, blank
///                   STA $10 / STA $11                   ; frame counter, last seen
///     C011  VB1     BIT $2002 / BPL VB1                 ; wait out the warm-up
///     C016  VB2     BIT $2002 / BPL VB2
///                   LDA #$80 / STA $2000                ; NMI on
///     C020  MAIN    LDA $10 / CMP $11 / BEQ MAIN        ; wait for the NMI
///                   STA $11 / TAY / DEY / STY $13       ; index = count - 1
///                   JSR READPAD / STA vblank_log,Y      ; poll #1: in VBlank
///                   JSR DELAY                           ; ~45 scanlines
///                   JSR READPAD / STA render_log,Y      ; poll #2: mid-picture
///                   JMP MAIN
///     C060  READPAD strobe $4016, then shift eight reads into $12,
///                   first bit read landing in bit 0 -- the same order
///                   `Controller.Button` numbers them in.
///     C080  DELAY   two nested loops, about 5150 cycles.
///     C090  NMI     INC $10 / RTI
///     C095  IRQ     RTI
// zig fmt: off
const prg_code = [_]struct { u16, []const u8 }{
    .{ 0x0000, &.{
        0x78, // SEI
        0xD8, // CLD
        0xA2, 0xFF, // LDX #$FF
        0x9A, // TXS
        0xA9, 0x00, // LDA #$00
        0x8D, 0x00, 0x20, // STA $2000
        0x8D, 0x01, 0x20, // STA $2001
        0x85, 0x10, // STA $10
        0x85, 0x11, // STA $11
        0x2C, 0x02, 0x20, // C011 BIT $2002
        0x10, 0xFB, // BPL C011
        0x2C, 0x02, 0x20, // C016 BIT $2002
        0x10, 0xFB, // BPL C016
        0xA9, 0x80, // LDA #$80
        0x8D, 0x00, 0x20, // STA $2000
        0xA5, 0x10, // C020 LDA $10
        0xC5, 0x11, // CMP $11
        0xF0, 0xFA, // BEQ C020
        0x85, 0x11, // STA $11
        0xA8, // TAY
        0x88, // DEY
        0x84, 0x13, // STY $13
        0x20, 0x60, 0xC0, // JSR C060 (READPAD)
        0xA4, 0x13, // LDY $13
        0xA5, 0x12, // LDA $12
        0x99, 0x00, 0x02, // STA $0200,Y
        0x20, 0x80, 0xC0, // JSR C080 (DELAY)
        0x20, 0x60, 0xC0, // JSR C060 (READPAD)
        0xA4, 0x13, // LDY $13
        0xA5, 0x12, // LDA $12
        0x99, 0x00, 0x03, // STA $0300,Y
        0x4C, 0x20, 0xC0, // JMP C020
    } },
    .{ 0x0060, &.{
        0xA9, 0x01, // LDA #$01
        0x8D, 0x16, 0x40, // STA $4016
        0xA9, 0x00, // LDA #$00
        0x8D, 0x16, 0x40, // STA $4016
        0xA2, 0x08, // LDX #$08
        0x85, 0x12, // STA $12
        0xAD, 0x16, 0x40, // C06E LDA $4016
        0x4A, // LSR A
        0x66, 0x12, // ROR $12
        0xCA, // DEX
        0xD0, 0xF7, // BNE C06E
        0x60, // RTS
    } },
    .{ 0x0080, &.{
        0xA2, 0x04, // LDX #$04
        0xA0, 0x00, // C082 LDY #$00
        0x88, // C084 DEY
        0xD0, 0xFD, // BNE C084
        0xCA, // DEX
        0xD0, 0xF8, // BNE C082
        0x60, // RTS
    } },
    .{ 0x0090, &.{
        0xE6, 0x10, // INC $10
        0x40, // RTI
    } },
    .{ 0x0095, &.{
        0x40, // RTI
    } },
    // Vectors: NMI $C090, RESET $C000, IRQ $C095.
    .{ 0x3FFA, &.{ 0x90, 0xC0, 0x00, 0xC0, 0x95, 0xC0 } },
};
// zig fmt: on

const rom_image = blk: {
    @setEvalBranchQuota(100_000);
    var rom: [16 + 16 * 1024]u8 = @splat(0);
    rom[0..4].* = .{ 'N', 'E', 'S', 0x1A };
    rom[4] = 1; // one 16 KiB PRG bank, mirrored into $C000
    rom[5] = 0; // no CHR ROM, so the board carries CHR RAM
    for (prg_code) |chunk| {
        const at, const bytes = chunk;
        @memcpy(rom[16 + at ..][0..bytes.len], bytes);
    }
    break :blk rom;
};

// --- The movie -----------------------------------------------------------

/// A button pattern that is different every frame, so any misalignment shows
/// up as a mismatch rather than as a run of identical bytes that happens to
/// agree. Kept away from $00 and $FF for the same reason.
fn patternFor(frame: usize) u8 {
    return @truncate(frame *% 37 +% 0x5B);
}

fn writeMovie(gpa: std.mem.Allocator, frames: usize, reset_at: ?usize) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(gpa);
    try text.appendSlice(gpa, "version 3\nport0 1\nport1 1\nport2 0\n");
    for (0..frames) |frame| {
        const buttons = patternFor(frame);
        const reset = reset_at != null and reset_at.? == frame;
        try text.appendSlice(gpa, if (reset) "|1|" else "|0|");
        // fm2 writes bit 7 first, one mnemonic per button.
        for (0..8) |i| {
            const bit: u3 = @intCast(7 - i);
            const held = buttons & (@as(u8, 1) << bit) != 0;
            try text.append(gpa, if (held) "RLDUTSBA"[i] else '.');
        }
        try text.appendSlice(gpa, "|........||\n");
    }
    return text.toOwnedSlice(gpa);
}

// --- Tests ---------------------------------------------------------------

const Run = struct {
    session: *Session,
    playback: Movie.Playback,

    fn deinit(self: *Run, gpa: std.mem.Allocator) void {
        self.playback.deinit(gpa);
        self.session.deinit(gpa);
    }

    /// Replays `frames` records the same way `App` does: apply the record's
    /// commands and input, then run the console to the next picture boundary.
    fn play(gpa: std.mem.Allocator, frames: usize, reset_at: ?usize) !Run {
        // Past this the ROM's byte-wide index wraps and the log stops meaning
        // what the assertions below take it to mean.
        std.debug.assert(frames <= log_capacity);

        const rom = try gpa.dupe(u8, &rom_image);
        errdefer gpa.free(rom);
        const session = try Session.adopt(gpa, "timing.nes", rom);
        errdefer session.deinit(gpa);

        const text = try writeMovie(gpa, frames, reset_at);
        defer gpa.free(text);
        var run: Run = .{
            .session = session,
            .playback = .{ .movie = try Movie.parse(gpa, "timing.fm2", text) },
        };
        errdefer run.playback.deinit(gpa);

        session.powerCycle();
        session.alignToFrame(); // as `App.startMovie` does
        while (run.playback.next()) |frame| {
            if (frame.commands.soft_reset) {
                session.reset();
                session.alignToFrame();
            }
            session.applyInput(frame.ports, .none);
            try session.runFrame({});
        }
        return run;
    }

    fn vblankRead(self: *const Run, i: usize) u8 {
        return self.session.nes.ram[vblank_log + i];
    }

    fn renderRead(self: *const Run, i: usize) u8 {
        return self.session.nes.ram[render_log + i];
    }
};

test "a frame's input is latched before VBlank, so the whole frame reads one record" {
    const gpa = testing.allocator;
    const frames = 120;
    var run = try Run.play(gpa, frames, null);
    defer run.deinit(gpa);

    // The ROM cannot log a frame it never ran, so it must have run them.
    try testing.expect(run.vblankRead(frames - boot_frames - 2) != 0);

    for (0..frames - boot_frames - 1) |i| {
        // The game polled twice within one of its own frames, on either
        // side of the picture boundary. Both polls have to see the same
        // record; if the second one has moved on to the next, the loop is
        // cutting frames in the wrong place.
        try testing.expectEqual(run.vblankRead(i), run.renderRead(i));
    }
}

test "each record reaches the game exactly once, in order" {
    const gpa = testing.allocator;
    const frames = 120;
    var run = try Run.play(gpa, frames, null);
    defer run.deinit(gpa);

    // `boot_frames` records go by while the console warms up and the ROM
    // waits for its second VBlank, so the first logged read is that far into
    // the movie. From there it must advance one record per frame, forever.
    for (0..frames - boot_frames - 1) |i| {
        try testing.expectEqual(patternFor(i + boot_frames), run.vblankRead(i));
    }
}

test "a movie's reset command costs exactly one record, like any other frame" {
    const gpa = testing.allocator;
    const reset_at = 30;
    var run = try Run.play(gpa, 70, reset_at);
    defer run.deinit(gpa);

    // The ROM starts its log over after a reset, so index 0 is the first
    // frame it logged on the way back up -- `boot_frames` after the record
    // that carried the command, exactly as at power-on. One record more than
    // that means the reset left the console mid-picture and the frame it
    // landed in was a stub.
    try testing.expectEqual(patternFor(reset_at + boot_frames), run.vblankRead(0));
    try testing.expectEqual(patternFor(reset_at + boot_frames + 1), run.vblankRead(1));
}

test "the movie's buttons arrive as the movie wrote them" {
    // A sanity check on the bit order that the pattern above would hide if
    // it were wrong in both the writer and the reader: spell one frame out.
    const gpa = testing.allocator;
    var movie = try Movie.parse(gpa, "t.fm2", "|0|RLDUTSBA|........||\n|0|.......A|........||\n");
    defer movie.deinit(gpa);

    try testing.expectEqual(@as(u8, 0xFF), @as(u8, @bitCast(movie.frames[0].ports[0])));
    try testing.expectEqual(input.Buttons{ .a = true }, movie.frames[1].ports[0]);
}

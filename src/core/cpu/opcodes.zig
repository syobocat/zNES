//! Static decode table for the RP2A03's instruction set: every official
//! opcode plus the documented unofficial ones. The NES's 6502 core lacks BCD
//! but is otherwise a stock NMOS 6502, including its read-modify-write and
//! unintended-opcode quirks, so all 256 entries are defined and none are
//! "illegal" as far as this decoder is concerned.
//!
//! This is pure data rather than a component, so it keeps the lowercase-module
//! naming instead of the file-is-struct convention.

/// How an instruction reaches its operand, which is what decides its bus-cycle
/// shape. `Cpu.step` dispatches on this for every opcode except the handful it
/// special-cases by mnemonic, where the sequence fits no generic shape.
pub const AddrMode = enum {
    implied,
    immediate,
    zero_page,
    zero_page_x,
    zero_page_y,
    absolute,
    absolute_x,
    absolute_y,
    indirect,
    indirect_x,
    indirect_y,
    relative,
};

/// What the addressing mode does with the operand once it has the address:
/// read it, write it, or read-modify-write it (which costs two extra cycles
/// and writes twice). `other` is for the opcodes dispatched by mnemonic, where
/// the question does not arise.
pub const Class = enum { read, write, rmw, other };

pub const Op = enum {
    adc,
    @"and",
    asl,
    bcc,
    bcs,
    beq,
    bit,
    bmi,
    bne,
    bpl,
    brk,
    bvc,
    bvs,
    clc,
    cld,
    cli,
    clv,
    cmp,
    cpx,
    cpy,
    dec,
    dex,
    dey,
    eor,
    inc,
    inx,
    iny,
    jmp,
    jsr,
    lda,
    ldx,
    ldy,
    lsr,
    nop,
    ora,
    pha,
    php,
    pla,
    plp,
    rol,
    ror,
    rti,
    rts,
    sbc,
    sec,
    sed,
    sei,
    sta,
    stx,
    sty,
    tax,
    tay,
    tsx,
    txa,
    txs,
    tya,

    // Unofficial opcodes.
    slo,
    rla,
    sre,
    rra,
    sax,
    lax,
    dcp,
    isc,
    anc,
    alr,
    arr,
    ane,
    lxa,
    axs,
    sha,
    shx,
    shy,
    tas,
    las,
    jam,
};

pub const Info = struct {
    op: Op,
    mode: AddrMode,
    class: Class = .other,
};

/// Opcodes whose bus sequence fits no addressing mode's generic shape, and
/// which `Cpu.step` therefore routes by mnemonic before ever consulting
/// `mode`/`class`. Every other opcode -- including branches and the
/// register/flag operations -- goes through a per-mode handler.
pub const special_cased = [_]Op{ .brk, .jsr, .rts, .rti, .pha, .php, .pla, .plp, .jmp, .jam };

/// A general entry, dispatched on its addressing mode.
fn e(op: Op, mode: AddrMode, class: Class) Info {
    return .{ .op = op, .mode = mode, .class = class };
}

/// Register and flag operations, plus the accumulator-mode shifts. Two cycles,
/// no operand, so the class never comes up.
fn im(op: Op) Info {
    return .{ .op = op, .mode = .implied };
}

/// A conditional branch. Relative addressing has its own handler because
/// branches are the one instruction whose interrupt polling is not the usual
/// once-at-the-next-to-last-cycle.
fn rel(op: Op) Info {
    return .{ .op = op, .mode = .relative };
}

// zig fmt: off
pub const table: [256]Info = .{
    // 0x00
    im(.brk),                         e(.ora, .indirect_x, .read),      im(.jam),                         e(.slo, .indirect_x, .rmw),
    e(.nop, .zero_page, .read),       e(.ora, .zero_page, .read),       e(.asl, .zero_page, .rmw),        e(.slo, .zero_page, .rmw),
    im(.php),                         e(.ora, .immediate, .read),       im(.asl),                         e(.anc, .immediate, .read),
    e(.nop, .absolute, .read),        e(.ora, .absolute, .read),        e(.asl, .absolute, .rmw),         e(.slo, .absolute, .rmw),
    // 0x10
    rel(.bpl),                        e(.ora, .indirect_y, .read),      im(.jam),                         e(.slo, .indirect_y, .rmw),
    e(.nop, .zero_page_x, .read),     e(.ora, .zero_page_x, .read),     e(.asl, .zero_page_x, .rmw),      e(.slo, .zero_page_x, .rmw),
    im(.clc),                         e(.ora, .absolute_y, .read),      im(.nop),                         e(.slo, .absolute_y, .rmw),
    e(.nop, .absolute_x, .read),      e(.ora, .absolute_x, .read),      e(.asl, .absolute_x, .rmw),       e(.slo, .absolute_x, .rmw),
    // 0x20
    im(.jsr),                         e(.@"and", .indirect_x, .read),   im(.jam),                         e(.rla, .indirect_x, .rmw),
    e(.bit, .zero_page, .read),       e(.@"and", .zero_page, .read),    e(.rol, .zero_page, .rmw),        e(.rla, .zero_page, .rmw),
    im(.plp),                         e(.@"and", .immediate, .read),    im(.rol),                         e(.anc, .immediate, .read),
    e(.bit, .absolute, .read),        e(.@"and", .absolute, .read),     e(.rol, .absolute, .rmw),         e(.rla, .absolute, .rmw),
    // 0x30
    rel(.bmi),                        e(.@"and", .indirect_y, .read),   im(.jam),                         e(.rla, .indirect_y, .rmw),
    e(.nop, .zero_page_x, .read),     e(.@"and", .zero_page_x, .read),  e(.rol, .zero_page_x, .rmw),      e(.rla, .zero_page_x, .rmw),
    im(.sec),                         e(.@"and", .absolute_y, .read),   im(.nop),                         e(.rla, .absolute_y, .rmw),
    e(.nop, .absolute_x, .read),      e(.@"and", .absolute_x, .read),   e(.rol, .absolute_x, .rmw),       e(.rla, .absolute_x, .rmw),
    // 0x40
    im(.rti),                         e(.eor, .indirect_x, .read),      im(.jam),                         e(.sre, .indirect_x, .rmw),
    e(.nop, .zero_page, .read),       e(.eor, .zero_page, .read),       e(.lsr, .zero_page, .rmw),        e(.sre, .zero_page, .rmw),
    im(.pha),                         e(.eor, .immediate, .read),       im(.lsr),                         e(.alr, .immediate, .read),
    e(.jmp, .absolute, .other),       e(.eor, .absolute, .read),        e(.lsr, .absolute, .rmw),         e(.sre, .absolute, .rmw),
    // 0x50
    rel(.bvc),                        e(.eor, .indirect_y, .read),      im(.jam),                         e(.sre, .indirect_y, .rmw),
    e(.nop, .zero_page_x, .read),     e(.eor, .zero_page_x, .read),     e(.lsr, .zero_page_x, .rmw),      e(.sre, .zero_page_x, .rmw),
    im(.cli),                         e(.eor, .absolute_y, .read),      im(.nop),                         e(.sre, .absolute_y, .rmw),
    e(.nop, .absolute_x, .read),      e(.eor, .absolute_x, .read),      e(.lsr, .absolute_x, .rmw),       e(.sre, .absolute_x, .rmw),
    // 0x60
    im(.rts),                         e(.adc, .indirect_x, .read),      im(.jam),                         e(.rra, .indirect_x, .rmw),
    e(.nop, .zero_page, .read),       e(.adc, .zero_page, .read),       e(.ror, .zero_page, .rmw),        e(.rra, .zero_page, .rmw),
    im(.pla),                         e(.adc, .immediate, .read),       im(.ror),                         e(.arr, .immediate, .read),
    e(.jmp, .indirect, .other),       e(.adc, .absolute, .read),        e(.ror, .absolute, .rmw),         e(.rra, .absolute, .rmw),
    // 0x70
    rel(.bvs),                        e(.adc, .indirect_y, .read),      im(.jam),                         e(.rra, .indirect_y, .rmw),
    e(.nop, .zero_page_x, .read),     e(.adc, .zero_page_x, .read),     e(.ror, .zero_page_x, .rmw),      e(.rra, .zero_page_x, .rmw),
    im(.sei),                         e(.adc, .absolute_y, .read),      im(.nop),                         e(.rra, .absolute_y, .rmw),
    e(.nop, .absolute_x, .read),      e(.adc, .absolute_x, .read),      e(.ror, .absolute_x, .rmw),       e(.rra, .absolute_x, .rmw),
    // 0x80
    e(.nop, .immediate, .read),       e(.sta, .indirect_x, .write),     e(.nop, .immediate, .read),       e(.sax, .indirect_x, .write),
    e(.sty, .zero_page, .write),      e(.sta, .zero_page, .write),      e(.stx, .zero_page, .write),      e(.sax, .zero_page, .write),
    im(.dey),                         e(.nop, .immediate, .read),       im(.txa),                         e(.ane, .immediate, .read),
    e(.sty, .absolute, .write),       e(.sta, .absolute, .write),       e(.stx, .absolute, .write),       e(.sax, .absolute, .write),
    // 0x90
    rel(.bcc),                        e(.sta, .indirect_y, .write),     im(.jam),                         e(.sha, .indirect_y, .write),
    e(.sty, .zero_page_x, .write),    e(.sta, .zero_page_x, .write),    e(.stx, .zero_page_y, .write),    e(.sax, .zero_page_y, .write),
    im(.tya),                         e(.sta, .absolute_y, .write),     im(.txs),                         e(.tas, .absolute_y, .write),
    e(.shy, .absolute_x, .write),     e(.sta, .absolute_x, .write),     e(.shx, .absolute_y, .write),     e(.sha, .absolute_y, .write),
    // 0xA0
    e(.ldy, .immediate, .read),       e(.lda, .indirect_x, .read),      e(.ldx, .immediate, .read),       e(.lax, .indirect_x, .read),
    e(.ldy, .zero_page, .read),       e(.lda, .zero_page, .read),       e(.ldx, .zero_page, .read),       e(.lax, .zero_page, .read),
    im(.tay),                         e(.lda, .immediate, .read),       im(.tax),                         e(.lxa, .immediate, .read),
    e(.ldy, .absolute, .read),        e(.lda, .absolute, .read),        e(.ldx, .absolute, .read),        e(.lax, .absolute, .read),
    // 0xB0
    rel(.bcs),                        e(.lda, .indirect_y, .read),      im(.jam),                         e(.lax, .indirect_y, .read),
    e(.ldy, .zero_page_x, .read),     e(.lda, .zero_page_x, .read),     e(.ldx, .zero_page_y, .read),     e(.lax, .zero_page_y, .read),
    im(.clv),                         e(.lda, .absolute_y, .read),      im(.tsx),                         e(.las, .absolute_y, .read),
    e(.ldy, .absolute_x, .read),      e(.lda, .absolute_x, .read),      e(.ldx, .absolute_y, .read),      e(.lax, .absolute_y, .read),
    // 0xC0
    e(.cpy, .immediate, .read),       e(.cmp, .indirect_x, .read),      e(.nop, .immediate, .read),       e(.dcp, .indirect_x, .rmw),
    e(.cpy, .zero_page, .read),       e(.cmp, .zero_page, .read),       e(.dec, .zero_page, .rmw),        e(.dcp, .zero_page, .rmw),
    im(.iny),                         e(.cmp, .immediate, .read),       im(.dex),                         e(.axs, .immediate, .read),
    e(.cpy, .absolute, .read),        e(.cmp, .absolute, .read),        e(.dec, .absolute, .rmw),         e(.dcp, .absolute, .rmw),
    // 0xD0
    rel(.bne),                        e(.cmp, .indirect_y, .read),      im(.jam),                         e(.dcp, .indirect_y, .rmw),
    e(.nop, .zero_page_x, .read),     e(.cmp, .zero_page_x, .read),     e(.dec, .zero_page_x, .rmw),      e(.dcp, .zero_page_x, .rmw),
    im(.cld),                         e(.cmp, .absolute_y, .read),      im(.nop),                         e(.dcp, .absolute_y, .rmw),
    e(.nop, .absolute_x, .read),      e(.cmp, .absolute_x, .read),      e(.dec, .absolute_x, .rmw),       e(.dcp, .absolute_x, .rmw),
    // 0xE0
    e(.cpx, .immediate, .read),       e(.sbc, .indirect_x, .read),      e(.nop, .immediate, .read),       e(.isc, .indirect_x, .rmw),
    e(.cpx, .zero_page, .read),       e(.sbc, .zero_page, .read),       e(.inc, .zero_page, .rmw),        e(.isc, .zero_page, .rmw),
    im(.inx),                         e(.sbc, .immediate, .read),       im(.nop),                         e(.sbc, .immediate, .read),
    e(.cpx, .absolute, .read),        e(.sbc, .absolute, .read),        e(.inc, .absolute, .rmw),         e(.isc, .absolute, .rmw),
    // 0xF0
    rel(.beq),                        e(.sbc, .indirect_y, .read),      im(.jam),                         e(.isc, .indirect_y, .rmw),
    e(.nop, .zero_page_x, .read),     e(.sbc, .zero_page_x, .read),     e(.inc, .zero_page_x, .rmw),      e(.isc, .zero_page_x, .rmw),
    im(.sed),                         e(.sbc, .absolute_y, .read),      im(.nop),                         e(.isc, .absolute_y, .rmw),
    e(.nop, .absolute_x, .read),      e(.sbc, .absolute_x, .read),      e(.inc, .absolute_x, .rmw),       e(.isc, .absolute_x, .rmw),
};
// zig fmt: on

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

fn isSpecialCased(op: Op) bool {
    return std.mem.indexOfScalar(Op, &special_cased, op) != null;
}

test "every entry is dispatchable by Cpu.step" {
    for (table, 0..) |info, opcode| {
        errdefer std.debug.print("opcode ${X:0>2}: {any}\n", .{ opcode, info });
        if (isSpecialCased(info.op)) continue;
        switch (info.mode) {
            // The operand-less modes have handlers that need no class:
            // `implied` acts on registers, `relative` on the branch offset.
            .implied, .relative => try testing.expectEqual(Class.other, info.class),
            // `indirect` exists only for JMP ($6C), which is special-cased.
            .indirect => try testing.expect(false),
            // Everything else reaches a per-mode handler, which has to know
            // what to do with the operand it fetched.
            else => try testing.expect(info.class != .other),
        }
    }
}

test "class .other means the opcode never fetches an operand to act on" {
    for (table, 0..) |info, opcode| {
        errdefer std.debug.print("opcode ${X:0>2}: {any}\n", .{ opcode, info });
        if (info.class != .other) continue;
        try testing.expect(isSpecialCased(info.op) or
            info.mode == .implied or
            info.mode == .relative);
    }
}

test "an immediate operand can only be read" {
    for (table, 0..) |info, opcode| {
        errdefer std.debug.print("opcode ${X:0>2}: {any}\n", .{ opcode, info });
        if (info.mode == .immediate) try testing.expectEqual(Class.read, info.class);
    }
}

test "the 151 documented opcodes are all present, alongside 12 JAMs" {
    var documented: usize = 0;
    var jams: usize = 0;
    var nops: usize = 0;
    var sbcs: usize = 0;
    for (table) |info| {
        switch (info.op) {
            .jam => jams += 1,
            .nop => nops += 1,
            .sbc => sbcs += 1,
            .slo, .rla, .sre, .rra, .sax, .lax, .dcp, .isc => {},
            .anc, .alr, .arr, .ane, .lxa, .axs, .sha, .shx, .shy, .tas, .las => {},
            else => documented += 1,
        }
    }
    // NOP and SBC each have unofficial encodings beyond the documented ones:
    // 27 extra NOPs and $EB, a second immediate SBC.
    try testing.expectEqual(@as(usize, 28), nops);
    try testing.expectEqual(@as(usize, 9), sbcs);
    try testing.expectEqual(@as(usize, 151), documented + 1 + (sbcs - 1));
    try testing.expectEqual(@as(usize, 12), jams);
}

test "the four opcodes with a page-crossing write penalty are the unstable stores" {
    // SHA/SHX/SHY/TAS corrupt the address's high byte when indexing crosses a
    // page, which `Cpu.writeAddress` keys off `info.op`. They must all be
    // write-class and indexed, or that code is unreachable for some of them.
    for (table) |info| {
        switch (info.op) {
            .sha, .shx, .shy, .tas => {
                try testing.expectEqual(Class.write, info.class);
                try testing.expect(info.mode == .absolute_x or
                    info.mode == .absolute_y or
                    info.mode == .indirect_y);
            },
            else => {},
        }
    }
}

test "known opcodes decode to the right entry" {
    // Spot checks at the boundaries of the table's structure: the first entry,
    // the two JMP forms, the accumulator shifts, and an unofficial RMW.
    try testing.expectEqual(Info{ .op = .brk, .mode = .implied }, table[0x00]);
    try testing.expectEqual(Info{ .op = .jmp, .mode = .absolute }, table[0x4C]);
    try testing.expectEqual(Info{ .op = .jmp, .mode = .indirect }, table[0x6C]);
    try testing.expectEqual(Info{ .op = .lsr, .mode = .implied }, table[0x4A]);
    try testing.expectEqual(
        Info{ .op = .isc, .mode = .absolute_x, .class = .rmw },
        table[0xFF],
    );
    try testing.expectEqual(
        Info{ .op = .lda, .mode = .immediate, .class = .read },
        table[0xA9],
    );
}

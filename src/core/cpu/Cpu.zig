// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! Cycle-stepped Ricoh 2A03 CPU core: an NMOS 6502 with decimal mode removed.
//!
//! `step` executes exactly one bus cycle per call, matching the contract of
//! `Nes.stepCycle`. An instruction is decoded once at opcode fetch and then
//! walked cycle by cycle by a handler shared across every opcode using the
//! same addressing mode, so dummy reads, read-modify-write double writes and
//! page-crossing penalties fall out of the same code path hardware uses rather
//! than being bolted on as special cases.
//!
//! ## Interrupts
//!
//! Every generic handler polls NMI/IRQ once, at the instruction's
//! next-to-last cycle -- its only cycle, for a two-cycle instruction -- using
//! the I flag as it stood at the *start* of that cycle. That single rule is
//! what gives CLI/SEI/PLP their one-instruction latency without special-casing
//! them. Branches are the sole exception; see `stepBranch`.
//!
//! NMI is edge-latched independently of polling (see `pollEdges`), which is
//! what makes hijacking work: an NMI arriving mid-BRK/IRQ dispatch takes over
//! the vector already in flight, because the vector is not resolved until the
//! last possible moment (see `stepInterruptDispatch`).

const Cpu = @This();
const Nes = @import("../Nes.zig");
const opcodes = @import("opcodes.zig");

/// The 6502's status flags. Bits 4 ("B") and 5 are not real flip-flops -- they
/// exist only in the byte pushed to the stack -- so they live outside this
/// type entirely; see `packFlags` and `unpackFlags`.
pub const Flags = packed struct {
    c: bool = false,
    z: bool = false,
    i: bool = true,
    d: bool = false,
    v: bool = false,
    n: bool = false,
};

pub const init: Cpu = .{};

a: u8 = 0,
x: u8 = 0,
y: u8 = 0,
s: u8 = 0,
pc: u16 = 0,
p: Flags = .{},

/// 0 means "fetch the next opcode, or begin interrupt dispatch". Any other
/// value indexes into the current opcode's bus-cycle sequence.
cycle: u8 = 0,
opcode: u8 = 0,
info: opcodes.Info = opcodes.table[0],

// Addressing-mode scratch, reused across the cycles of one instruction.
ea: u16 = 0,
uncorrected_addr: u16 = 0,
ptr: u8 = 0,
lo: u8 = 0,
hi: u8 = 0,
val: u8 = 0,
page_crossed: bool = false,

/// Set by `Nes.stepCycle` whenever a DMA steals a cycle mid-instruction.
/// Consumed only by the unstable stores' high-byte correction; see
/// `writeValue`.
dma_interrupted: bool = false,

// Interrupt and BRK dispatch state.
entered_via_brk: bool = false,
interrupt_vector: u16 = 0,
nmi_pending: bool = false,
interrupt_ready: bool = false,

jammed: bool = false,
resetting: bool = false,

/// Arms the 7-cycle reset sequence: two dummy PC reads, three dummy stack
/// reads with S decrementing, then the reset vector fetch. `step` walks it
/// exactly like an interrupt dispatch, so PPU dot counts and total cycle
/// counts line up with hardware from the first post-reset instruction onward.
///
/// Callers must pump `Nes.stepCycle` until `resetting` goes false before
/// treating the system as ready.
pub fn reset(self: *Cpu) void {
    self.resetting = true;
    self.jammed = false;
    self.interrupt_ready = false;
    self.nmi_pending = false;
    self.cycle = 1;
}

/// Drains the NMI edge the PPU latched into the CPU's own pending flag. Must
/// run every CPU cycle, including cycles stolen by DMA and cycles where the
/// CPU is doing nothing, because that flag is what makes hijacking work.
///
/// The edge itself is detected dot by dot inside the PPU, since the line can
/// pulse high and low again inside a single CPU cycle.
pub fn pollEdges(self: *Cpu, nes: *Nes) void {
    if (nes.ppu.nmi_edge_pending) {
        nes.ppu.nmi_edge_pending = false;
        self.nmi_pending = true;
    }
}

/// The address the CPU's address bus currently holds, which is what a halted
/// CPU keeps driving and therefore what a DMA's dummy read cycle actually
/// reads from.
///
/// This tracks each addressing-mode handler's own cycle sequence because the
/// scratch fields only hold the right value once the cycle that sets them has
/// run. A DMA landing earlier -- still fetching operand bytes, or reading an
/// unindexed pointer -- must see what is genuinely on the bus at that point,
/// not a leftover from the previous instruction or this instruction's
/// not-yet-computed final address.
pub fn busAddress(self: *const Cpu) u16 {
    if (self.cycle == 0) return self.pc;
    return switch (self.info.mode) {
        .zero_page => if (self.cycle == 1) self.pc else self.ea,
        .zero_page_x, .zero_page_y => switch (self.cycle) {
            1 => self.pc,
            2 => self.ptr,
            else => self.ea,
        },
        .absolute => if (self.cycle <= 2) self.pc else self.ea,
        .absolute_x, .absolute_y => switch (self.cycle) {
            1, 2 => self.pc,
            3 => self.uncorrected_addr,
            else => self.ea,
        },
        .indirect_x => switch (self.cycle) {
            1 => self.pc,
            2, 3 => self.ptr,
            4 => self.ptr +% 1,
            else => self.ea,
        },
        .indirect_y => switch (self.cycle) {
            1 => self.pc,
            2 => self.ptr,
            3 => self.ptr +% 1,
            4 => self.uncorrected_addr,
            else => self.ea,
        },
        // implied/immediate/relative/indirect: no effective address distinct
        // from the operand stream itself.
        else => self.pc,
    };
}

/// Whether the *next* call to `step` would perform a bus write.
///
/// Hardware samples RDY -- a DMA's halt request -- only on read cycles, so a
/// DMA can never preempt a write and an already-pending one simply waits for
/// the CPU's next read. `Nes.stepCycle` uses this to defer a DMA that would
/// otherwise land on a write, which delays it by up to three cycles: two for
/// a read-modify-write's pair of writes, three for an interrupt sequence's
/// PCH/PCL/P pushes.
///
/// Stack pushes count even though the instructions making them belong to no
/// write class, and getting them wrong is not a corner case: a DMA pushed one
/// cycle late is a DMA one cycle shorter, which changes when the CPU gets the
/// bus back and shifts everything downstream of it.
pub fn nextCycleIsWrite(self: *const Cpu) bool {
    if (self.cycle == 0) return false;
    switch (self.info.op) {
        // Interrupt dispatch, whether from a real BRK or a hardware IRQ/NMI:
        // push PCH, PCL, then P.
        .brk => return self.cycle >= 2 and self.cycle <= 4,
        // Push PCH then PCL, between the stack-pointer read and the high
        // operand fetch.
        .jsr => return self.cycle == 3 or self.cycle == 4,
        .pha, .php => return self.cycle == 2,
        else => {},
    }
    const is_rmw = self.info.class == .rmw;
    if (!is_rmw and self.info.class != .write) return false;
    // A write-class instruction writes on its last cycle; a read-modify-write
    // writes on its last two, the dummy write-back and the real one.
    const last: u8 = switch (self.info.mode) {
        .zero_page => if (is_rmw) 4 else 2,
        .zero_page_x, .zero_page_y => if (is_rmw) 5 else 3,
        .absolute => if (is_rmw) 5 else 3,
        .absolute_x, .absolute_y => if (is_rmw) 6 else 4,
        .indirect_x, .indirect_y => if (is_rmw) 7 else 5,
        else => return false,
    };
    return self.cycle == last or (is_rmw and self.cycle == last - 1);
}

/// Executes exactly one bus cycle.
pub fn step(self: *Cpu, nes: *Nes) void {
    if (self.jammed) return;
    if (self.resetting) {
        self.stepReset(nes);
        return;
    }

    if (self.cycle == 0) {
        if (self.interrupt_ready) {
            self.beginInterrupt(nes);
            return;
        }
        self.fetchOpcode(nes);
        return;
    }

    switch (self.info.op) {
        .brk => self.stepInterruptDispatch(nes),
        .jsr => self.stepJsr(nes),
        .rts => self.stepRts(nes),
        .rti => self.stepRti(nes),
        .pha, .php => self.stepPush(nes),
        .pla, .plp => self.stepPull(nes),
        .jmp => self.stepJmp(nes),
        .jam => self.stepJam(nes),
        else => switch (self.info.mode) {
            .implied => self.stepImplied(nes),
            .immediate => self.stepImmediate(nes),
            .zero_page => self.stepZeroPage(nes),
            .zero_page_x => self.stepZeroPageIndexed(nes, self.x),
            .zero_page_y => self.stepZeroPageIndexed(nes, self.y),
            .absolute => self.stepAbsolute(nes),
            .absolute_x => self.stepAbsoluteIndexed(nes, self.x),
            .absolute_y => self.stepAbsoluteIndexed(nes, self.y),
            .indirect_x => self.stepIndirectX(nes),
            .indirect_y => self.stepIndirectY(nes),
            .relative => self.stepBranch(nes),
            .indirect => unreachable, // only reachable via JMP, handled above
        },
    }
}

fn fetchOpcode(self: *Cpu, nes: *Nes) void {
    self.opcode = nes.cpuRead(self.pc);
    self.pc +%= 1;
    self.info = opcodes.table[self.opcode];
    // A real BRK consumes its padding byte and pushes B=1; a hardware
    // interrupt reuses the same sequence and does neither.
    self.entered_via_brk = self.info.op == .brk;
    self.cycle = 1;
    self.dma_interrupted = false;
}

fn beginInterrupt(self: *Cpu, nes: *Nes) void {
    self.interrupt_ready = false;
    self.entered_via_brk = false;
    // Route the following cycles to `stepInterruptDispatch`. Without this,
    // `info` would still hold whatever opcode was decoded before the interrupt
    // fired, and its cycles would be misread as cycles of that instruction.
    self.info = opcodes.table[0x00];
    // Cycle 1 of 7: the opcode fetch the CPU performs and throws away. PC does
    // not advance, so the same instruction is re-fetched once the handler
    // returns.
    _ = nes.cpuRead(self.pc);
    self.cycle = 1;
}

fn finishInstruction(self: *Cpu) void {
    self.cycle = 0;
}

/// Latches whether an interrupt sequence should begin the moment the current
/// instruction finishes. `flag_i` is the I flag as it stood before this
/// cycle's effects, so CLI/SEI/PLP naturally poll with the old mask.
fn pollForInterrupt(self: *Cpu, nes: *Nes, flag_i: bool) void {
    const irq_line = nes.apu.irqLine() or
        nes.apu.dmc.irq_flag or
        nes.cart.mapper.irqPending(nes.ppu.dots_elapsed);
    if (self.nmi_pending or (irq_line and !flag_i)) self.interrupt_ready = true;
}

// --- Addressing-mode handlers --------------------------------------------
//
// Each executes exactly one bus cycle per call and threads control forward
// via `self.cycle`.

fn stepImplied(self: *Cpu, nes: *Nes) void {
    const old_i = self.p.i;
    _ = nes.cpuRead(self.pc); // dummy read of the next byte; PC unchanged
    self.applyImplied();
    self.pollForInterrupt(nes, old_i);
    self.finishInstruction();
}

fn stepImmediate(self: *Cpu, nes: *Nes) void {
    self.val = nes.cpuRead(self.pc);
    self.pc +%= 1;
    self.applyRead();
    self.pollForInterrupt(nes, self.p.i);
    self.finishInstruction();
}

fn stepZeroPage(self: *Cpu, nes: *Nes) void {
    switch (self.cycle) {
        1 => {
            self.ea = nes.cpuRead(self.pc);
            self.pc +%= 1;
            self.cycle = 2;
        },
        2 => switch (self.info.class) {
            .read => self.finishRead(nes, nes.cpuRead(self.ea)),
            .write => self.finishWrite(nes, self.ea),
            .rmw => {
                self.val = nes.cpuRead(self.ea);
                self.cycle = 3;
            },
            .other => unreachable,
        },
        3 => {
            nes.cpuWrite(self.ea, self.val); // dummy write-back of the old value
            self.cycle = 4;
        },
        4 => self.finishRmw(nes, self.ea),
        else => unreachable,
    }
}

fn stepZeroPageIndexed(self: *Cpu, nes: *Nes, index: u8) void {
    switch (self.cycle) {
        1 => {
            self.ptr = nes.cpuRead(self.pc);
            self.pc +%= 1;
            self.cycle = 2;
        },
        2 => {
            _ = nes.cpuRead(self.ptr); // dummy read at the unindexed address
            self.ea = self.ptr +% index;
            self.cycle = 3;
        },
        3 => switch (self.info.class) {
            .read => self.finishRead(nes, nes.cpuRead(self.ea)),
            .write => self.finishWrite(nes, self.ea),
            .rmw => {
                self.val = nes.cpuRead(self.ea);
                self.cycle = 4;
            },
            .other => unreachable,
        },
        4 => {
            nes.cpuWrite(self.ea, self.val);
            self.cycle = 5;
        },
        5 => self.finishRmw(nes, self.ea),
        else => unreachable,
    }
}

fn stepAbsolute(self: *Cpu, nes: *Nes) void {
    switch (self.cycle) {
        1 => {
            self.lo = nes.cpuRead(self.pc);
            self.pc +%= 1;
            self.cycle = 2;
        },
        2 => {
            self.hi = nes.cpuRead(self.pc);
            self.pc +%= 1;
            self.ea = (@as(u16, self.hi) << 8) | self.lo;
            self.cycle = 3;
        },
        3 => switch (self.info.class) {
            .read => self.finishRead(nes, nes.cpuRead(self.ea)),
            .write => self.finishWrite(nes, self.ea),
            .rmw => {
                self.val = nes.cpuRead(self.ea);
                self.cycle = 4;
            },
            .other => unreachable,
        },
        4 => {
            nes.cpuWrite(self.ea, self.val);
            self.cycle = 5;
        },
        5 => self.finishRmw(nes, self.ea),
        else => unreachable,
    }
}

/// Absolute,X and absolute,Y. Read-class instructions skip the extra cycle
/// when indexing does not cross a page; write and read-modify-write
/// instructions always pay for it, because they cannot begin their access
/// before the address is known to be correct.
fn stepAbsoluteIndexed(self: *Cpu, nes: *Nes, index: u8) void {
    switch (self.cycle) {
        1 => {
            self.lo = nes.cpuRead(self.pc);
            self.pc +%= 1;
            self.cycle = 2;
        },
        2 => {
            self.hi = nes.cpuRead(self.pc);
            self.pc +%= 1;
            const indexed_lo: u16 = @as(u16, self.lo) + index;
            self.page_crossed = indexed_lo > 0xFF;
            self.uncorrected_addr = (@as(u16, self.hi) << 8) | (indexed_lo & 0xFF);
            self.ea = ((@as(u16, self.hi) << 8) | self.lo) +% index;
            self.cycle = 3;
        },
        3 => switch (self.info.class) {
            .read => {
                const v = nes.cpuRead(self.uncorrected_addr);
                if (self.page_crossed) self.cycle = 4 else self.finishRead(nes, v);
            },
            .write, .rmw => {
                _ = nes.cpuRead(self.uncorrected_addr); // dummy read, cross or not
                self.cycle = 4;
            },
            .other => unreachable,
        },
        4 => switch (self.info.class) {
            .read => self.finishRead(nes, nes.cpuRead(self.ea)),
            .write => self.finishWrite(nes, self.ea),
            .rmw => {
                self.val = nes.cpuRead(self.ea);
                self.cycle = 5;
            },
            .other => unreachable,
        },
        5 => {
            nes.cpuWrite(self.ea, self.val);
            self.cycle = 6;
        },
        6 => self.finishRmw(nes, self.ea),
        else => unreachable,
    }
}

fn stepIndirectX(self: *Cpu, nes: *Nes) void {
    switch (self.cycle) {
        1 => {
            self.ptr = nes.cpuRead(self.pc);
            self.pc +%= 1;
            self.cycle = 2;
        },
        2 => {
            _ = nes.cpuRead(self.ptr); // dummy read at the unindexed pointer
            self.ptr +%= self.x;
            self.cycle = 3;
        },
        3 => {
            self.lo = nes.cpuRead(self.ptr);
            self.cycle = 4;
        },
        4 => {
            self.hi = nes.cpuRead(self.ptr +% 1);
            self.ea = (@as(u16, self.hi) << 8) | self.lo;
            self.cycle = 5;
        },
        5 => switch (self.info.class) {
            .read => self.finishRead(nes, nes.cpuRead(self.ea)),
            .write => self.finishWrite(nes, self.ea),
            .rmw => {
                self.val = nes.cpuRead(self.ea);
                self.cycle = 6;
            },
            .other => unreachable,
        },
        6 => {
            nes.cpuWrite(self.ea, self.val);
            self.cycle = 7;
        },
        7 => self.finishRmw(nes, self.ea),
        else => unreachable,
    }
}

/// (Indirect),Y. Same page-crossing asymmetry as absolute,X/Y: only reads skip
/// the extra cycle when indexing stays on the same page.
fn stepIndirectY(self: *Cpu, nes: *Nes) void {
    switch (self.cycle) {
        1 => {
            self.ptr = nes.cpuRead(self.pc);
            self.pc +%= 1;
            self.cycle = 2;
        },
        2 => {
            self.lo = nes.cpuRead(self.ptr);
            self.cycle = 3;
        },
        3 => {
            self.hi = nes.cpuRead(self.ptr +% 1);
            const indexed_lo: u16 = @as(u16, self.lo) + self.y;
            self.page_crossed = indexed_lo > 0xFF;
            self.uncorrected_addr = (@as(u16, self.hi) << 8) | (indexed_lo & 0xFF);
            self.ea = ((@as(u16, self.hi) << 8) | self.lo) +% self.y;
            self.cycle = 4;
        },
        4 => switch (self.info.class) {
            .read => {
                const v = nes.cpuRead(self.uncorrected_addr);
                if (self.page_crossed) self.cycle = 5 else self.finishRead(nes, v);
            },
            .write, .rmw => {
                _ = nes.cpuRead(self.uncorrected_addr);
                self.cycle = 5;
            },
            .other => unreachable,
        },
        5 => switch (self.info.class) {
            .read => self.finishRead(nes, nes.cpuRead(self.ea)),
            .write => self.finishWrite(nes, self.ea),
            .rmw => {
                self.val = nes.cpuRead(self.ea);
                self.cycle = 6;
            },
            .other => unreachable,
        },
        6 => {
            nes.cpuWrite(self.ea, self.val);
            self.cycle = 7;
        },
        7 => self.finishRmw(nes, self.ea),
        else => unreachable,
    }
}

/// Branches are the one instruction that does not simply poll at its own
/// next-to-last cycle. They poll at a fixed point right after the opcode
/// fetch, and -- only when the branch runs long enough to have a fourth cycle,
/// i.e. taken and crossing a page -- once more at another fixed point, right
/// before that fourth cycle. Nothing polls in between.
///
/// The consequence is the well-known branch interrupt delay: a *taken* branch
/// that stays on the same page never polls again after that first fixed point,
/// so an interrupt asserted while it executes is deferred a whole extra
/// instruction. A not-taken branch behaves like any other two-cycle
/// instruction, and a taken page-crossing branch's second poll lands exactly
/// where the usual next-to-last-cycle rule would have put it anyway.
fn stepBranch(self: *Cpu, nes: *Nes) void {
    switch (self.cycle) {
        1 => {
            self.val = nes.cpuRead(self.pc);
            self.pc +%= 1;
            self.pollForInterrupt(nes, self.p.i); // the one unconditional poll
            if (self.branchTaken()) {
                self.cycle = 2;
            } else {
                self.finishInstruction();
            }
        },
        2 => {
            _ = nes.cpuRead(self.pc); // dummy read of the byte after the operand
            const offset: i8 = @bitCast(self.val);
            const target = self.pc +% @as(u16, @bitCast(@as(i16, offset)));
            self.page_crossed = (target & 0xFF00) != (self.pc & 0xFF00);
            self.ea = target; // stash the corrected target for cycle 3
            self.pc = (self.pc & 0xFF00) | (target & 0x00FF);
            if (self.page_crossed) {
                self.cycle = 3;
            } else {
                self.finishInstruction(); // deliberately without polling
            }
        },
        3 => {
            _ = nes.cpuRead(self.pc); // dummy read at the not-yet-fixed-up address
            self.pc = self.ea;
            self.pollForInterrupt(nes, self.p.i);
            self.finishInstruction();
        },
        else => unreachable,
    }
}

fn stepPush(self: *Cpu, nes: *Nes) void {
    switch (self.cycle) {
        1 => {
            _ = nes.cpuRead(self.pc);
            self.cycle = 2;
        },
        2 => {
            const value: u8 = if (self.info.op == .pha) self.a else self.packFlags(true);
            nes.cpuWrite(0x0100 | @as(u16, self.s), value);
            self.s -%= 1;
            self.pollForInterrupt(nes, self.p.i);
            self.finishInstruction();
        },
        else => unreachable,
    }
}

fn stepPull(self: *Cpu, nes: *Nes) void {
    switch (self.cycle) {
        1 => {
            _ = nes.cpuRead(self.pc);
            self.cycle = 2;
        },
        2 => {
            _ = nes.cpuRead(0x0100 | @as(u16, self.s));
            self.s +%= 1;
            self.cycle = 3;
        },
        3 => {
            const old_i = self.p.i;
            const value = nes.cpuRead(0x0100 | @as(u16, self.s));
            if (self.info.op == .pla) {
                self.a = value;
                self.setZN(self.a);
            } else {
                self.unpackFlags(value);
            }
            self.pollForInterrupt(nes, old_i);
            self.finishInstruction();
        },
        else => unreachable,
    }
}

fn stepJsr(self: *Cpu, nes: *Nes) void {
    switch (self.cycle) {
        1 => {
            self.lo = nes.cpuRead(self.pc);
            self.pc +%= 1;
            self.cycle = 2;
        },
        2 => {
            _ = nes.cpuRead(0x0100 | @as(u16, self.s));
            self.cycle = 3;
        },
        3 => {
            nes.cpuWrite(0x0100 | @as(u16, self.s), @truncate(self.pc >> 8));
            self.s -%= 1;
            self.cycle = 4;
        },
        4 => {
            nes.cpuWrite(0x0100 | @as(u16, self.s), @truncate(self.pc & 0xFF));
            self.s -%= 1;
            self.cycle = 5;
        },
        5 => {
            self.hi = nes.cpuRead(self.pc);
            self.pc = (@as(u16, self.hi) << 8) | self.lo;
            self.pollForInterrupt(nes, self.p.i);
            self.finishInstruction();
        },
        else => unreachable,
    }
}

fn stepRts(self: *Cpu, nes: *Nes) void {
    switch (self.cycle) {
        1 => {
            _ = nes.cpuRead(self.pc);
            self.cycle = 2;
        },
        2 => {
            _ = nes.cpuRead(0x0100 | @as(u16, self.s));
            self.s +%= 1;
            self.cycle = 3;
        },
        3 => {
            self.lo = nes.cpuRead(0x0100 | @as(u16, self.s));
            self.s +%= 1;
            self.cycle = 4;
        },
        4 => {
            self.hi = nes.cpuRead(0x0100 | @as(u16, self.s));
            self.pc = (@as(u16, self.hi) << 8) | self.lo;
            self.cycle = 5;
        },
        5 => {
            _ = nes.cpuRead(self.pc);
            self.pc +%= 1;
            self.pollForInterrupt(nes, self.p.i);
            self.finishInstruction();
        },
        else => unreachable,
    }
}

fn stepRti(self: *Cpu, nes: *Nes) void {
    switch (self.cycle) {
        1 => {
            _ = nes.cpuRead(self.pc);
            self.cycle = 2;
        },
        2 => {
            _ = nes.cpuRead(0x0100 | @as(u16, self.s));
            self.s +%= 1;
            self.cycle = 3;
        },
        3 => {
            self.unpackFlags(nes.cpuRead(0x0100 | @as(u16, self.s)));
            self.s +%= 1;
            self.cycle = 4;
        },
        4 => {
            self.lo = nes.cpuRead(0x0100 | @as(u16, self.s));
            self.s +%= 1;
            self.cycle = 5;
        },
        5 => {
            self.hi = nes.cpuRead(0x0100 | @as(u16, self.s));
            self.pc = (@as(u16, self.hi) << 8) | self.lo;
            // The I flag pulled on the previous cycle is already live here, so
            // RTI polls with the *new* mask, unlike CLI/SEI/PLP.
            self.pollForInterrupt(nes, self.p.i);
            self.finishInstruction();
        },
        else => unreachable,
    }
}

fn stepJmp(self: *Cpu, nes: *Nes) void {
    switch (self.info.mode) {
        .absolute => switch (self.cycle) {
            1 => {
                self.lo = nes.cpuRead(self.pc);
                self.pc +%= 1;
                self.cycle = 2;
            },
            2 => {
                self.hi = nes.cpuRead(self.pc);
                self.pc = (@as(u16, self.hi) << 8) | self.lo;
                self.pollForInterrupt(nes, self.p.i);
                self.finishInstruction();
            },
            else => unreachable,
        },
        .indirect => switch (self.cycle) {
            1 => {
                self.lo = nes.cpuRead(self.pc);
                self.pc +%= 1;
                self.cycle = 2;
            },
            2 => {
                self.hi = nes.cpuRead(self.pc);
                self.pc +%= 1;
                self.ea = (@as(u16, self.hi) << 8) | self.lo;
                self.cycle = 3;
            },
            3 => {
                self.val = nes.cpuRead(self.ea);
                self.cycle = 4;
            },
            4 => {
                // The page-wrap bug: the pointer's low byte increments without
                // carrying into the high byte, so a pointer at $xxFF takes its
                // high byte from $xx00 rather than the next page.
                const hi_addr = (self.ea & 0xFF00) | ((self.ea +% 1) & 0x00FF);
                const hi = nes.cpuRead(hi_addr);
                self.pc = (@as(u16, hi) << 8) | self.val;
                self.pollForInterrupt(nes, self.p.i);
                self.finishInstruction();
            },
            else => unreachable,
        },
        else => unreachable,
    }
}

fn stepJam(self: *Cpu, nes: *Nes) void {
    _ = nes.cpuRead(self.pc);
    self.jammed = true;
}

fn stepReset(self: *Cpu, nes: *Nes) void {
    switch (self.cycle) {
        1, 2 => {
            _ = nes.cpuRead(self.pc);
            self.cycle += 1;
        },
        3, 4, 5 => {
            _ = nes.cpuRead(0x0100 | @as(u16, self.s));
            self.s -%= 1;
            self.cycle += 1;
        },
        6 => {
            self.lo = nes.cpuRead(0xFFFC);
            self.cycle = 7;
        },
        7 => {
            self.hi = nes.cpuRead(0xFFFD);
            self.pc = (@as(u16, self.hi) << 8) | self.lo;
            self.p.i = true;
            self.resetting = false;
            self.finishInstruction();
        },
        else => unreachable,
    }
}

/// Shared body for BRK and hardware NMI/IRQ dispatch. Both are the same
/// seven-cycle sequence and differ only in whether the second cycle's operand
/// read advances PC and whether the pushed B flag reads 1 (`entered_via_brk`).
///
/// A hardware interrupt burns that second cycle too, so dispatch is seven
/// cycles either way -- a six-cycle version would make every interrupt-driven
/// loop a cycle short.
///
/// The hijack check at cycle 4 is what lets a newly latched NMI steal the
/// vector out from under an in-flight BRK or IRQ: the pushes have already
/// happened, so the flags on the stack still say B=1 for a hijacked BRK, but
/// the vector has not been chosen yet.
fn stepInterruptDispatch(self: *Cpu, nes: *Nes) void {
    switch (self.cycle) {
        1 => {
            // Both paths spend a cycle reading the byte after the opcode. BRK
            // consumes it, hence "BRK skips the following byte"; a hardware
            // interrupt discards it and leaves PC alone, so the interrupted
            // instruction is re-fetched after RTI.
            _ = nes.cpuRead(self.pc);
            if (self.entered_via_brk) self.pc +%= 1;
            self.cycle = 2;
        },
        2 => {
            nes.cpuWrite(0x0100 | @as(u16, self.s), @truncate(self.pc >> 8));
            self.s -%= 1;
            self.cycle = 3;
        },
        3 => {
            nes.cpuWrite(0x0100 | @as(u16, self.s), @truncate(self.pc & 0xFF));
            self.s -%= 1;
            self.cycle = 4;
        },
        4 => {
            nes.cpuWrite(0x0100 | @as(u16, self.s), self.packFlags(self.entered_via_brk));
            self.s -%= 1;
            if (self.nmi_pending) {
                self.nmi_pending = false;
                self.interrupt_vector = 0xFFFA;
            } else {
                self.interrupt_vector = 0xFFFE;
            }
            self.cycle = 5;
        },
        5 => {
            self.lo = nes.cpuRead(self.interrupt_vector);
            self.cycle = 6;
        },
        6 => {
            self.hi = nes.cpuRead(self.interrupt_vector +% 1);
            self.pc = (@as(u16, self.hi) << 8) | self.lo;
            self.p.i = true;
            self.finishInstruction();
        },
        else => unreachable,
    }
}

// --- Shared read/write/rmw tails -----------------------------------------

fn finishRead(self: *Cpu, nes: *Nes, value: u8) void {
    self.val = value;
    self.applyRead();
    self.pollForInterrupt(nes, self.p.i);
    self.finishInstruction();
}

fn finishWrite(self: *Cpu, nes: *Nes, addr: u16) void {
    const value = self.writeValue();
    nes.cpuWrite(self.writeAddress(addr, value), value);
    self.pollForInterrupt(nes, self.p.i);
    self.finishInstruction();
}

fn finishRmw(self: *Cpu, nes: *Nes, addr: u16) void {
    nes.cpuWrite(addr, self.applyRmw(self.val));
    self.pollForInterrupt(nes, self.p.i);
    self.finishInstruction();
}

/// The address a write-class instruction actually writes to.
///
/// SHA/SHX/SHY/TAS corrupt it when indexing crossed a page: the high byte
/// becomes the same already-ANDed byte being stored, not just the operand's
/// high byte plus one. These four opcodes only exist in indexed modes, so
/// `page_crossed` always belongs to the current instruction here.
fn writeAddress(self: *const Cpu, addr: u16, value: u8) u16 {
    return switch (self.info.op) {
        .sha, .shx, .shy, .tas => if (self.page_crossed)
            (@as(u16, value) << 8) | (addr & 0x00FF)
        else
            addr,
        else => addr,
    };
}

/// The byte a write-class instruction stores: a register for STA/STX/STY/SAX,
/// and for the unstable SHA/SHX/SHY/TAS a register ANDed with the operand's
/// high byte plus one.
///
/// That correction lives in a latch that misses its update if RDY halts the
/// CPU around the right cycle, in which case the AND term drops out entirely
/// and the plain register is stored. Modelled by neutralizing the term rather
/// than branching on it.
fn writeValue(self: *Cpu) u8 {
    const high: u8 = if (self.dma_interrupted) 0xFF else self.hi +% 1;
    return switch (self.info.op) {
        .sta => self.a,
        .stx => self.x,
        .sty => self.y,
        .sax => self.a & self.x,
        .sha => self.a & self.x & high,
        .shx => self.x & high,
        .shy => self.y & high,
        .tas => blk: {
            self.s = self.a & self.x;
            break :blk self.s & high;
        },
        else => unreachable,
    };
}

// --- Operation semantics -------------------------------------------------

fn setZN(self: *Cpu, value: u8) void {
    self.p.z = value == 0;
    self.p.n = (value & 0x80) != 0;
}

fn adc(self: *Cpu, value: u8) void {
    const a = self.a;
    const sum: u16 = @as(u16, a) + @as(u16, value) + @intFromBool(self.p.c);
    const result: u8 = @truncate(sum);
    self.p.c = sum > 0xFF;
    // Overflow means the operands agreed in sign and the result disagreed.
    self.p.v = (~(a ^ value) & (a ^ result) & 0x80) != 0;
    self.a = result;
    self.setZN(result);
}

/// NMOS SBC is ADC with the operand's bits inverted. With no decimal mode on
/// this chip that identity is exact, not an approximation.
fn sbc(self: *Cpu, value: u8) void {
    self.adc(~value);
}

fn compare(self: *Cpu, reg: u8, value: u8) void {
    self.p.c = reg >= value;
    self.setZN(reg -% value);
}

fn branchTaken(self: *Cpu) bool {
    return switch (self.info.op) {
        .bpl => !self.p.n,
        .bmi => self.p.n,
        .bvc => !self.p.v,
        .bvs => self.p.v,
        .bcc => !self.p.c,
        .bcs => self.p.c,
        .bne => !self.p.z,
        .beq => self.p.z,
        else => unreachable,
    };
}

/// The status byte as it reads live. Bit 4 ("B") is not a real flip-flop and
/// only appears in the byte pushed to the stack, so it always reads 0 here.
pub fn status(self: Cpu) u8 {
    return self.packFlags(false);
}

fn packFlags(self: *const Cpu, brk: bool) u8 {
    var p: u8 = 0x20; // bit 5 is not a flag either, and always reads 1
    if (self.p.c) p |= 0x01;
    if (self.p.z) p |= 0x02;
    if (self.p.i) p |= 0x04;
    if (self.p.d) p |= 0x08;
    if (brk) p |= 0x10;
    if (self.p.v) p |= 0x40;
    if (self.p.n) p |= 0x80;
    return p;
}

fn unpackFlags(self: *Cpu, p: u8) void {
    self.p.c = (p & 0x01) != 0;
    self.p.z = (p & 0x02) != 0;
    self.p.i = (p & 0x04) != 0;
    self.p.d = (p & 0x08) != 0;
    self.p.v = (p & 0x40) != 0;
    self.p.n = (p & 0x80) != 0;
}

/// Register and flag operations, plus the four accumulator-mode shifts, which
/// share their arithmetic with the memory versions via `applyRmw`.
fn applyImplied(self: *Cpu) void {
    switch (self.info.op) {
        .clc => self.p.c = false,
        .sec => self.p.c = true,
        .cli => self.p.i = false,
        .sei => self.p.i = true,
        .cld => self.p.d = false,
        .sed => self.p.d = true,
        .clv => self.p.v = false,
        .dex => {
            self.x -%= 1;
            self.setZN(self.x);
        },
        .dey => {
            self.y -%= 1;
            self.setZN(self.y);
        },
        .inx => {
            self.x +%= 1;
            self.setZN(self.x);
        },
        .iny => {
            self.y +%= 1;
            self.setZN(self.y);
        },
        .tax => {
            self.x = self.a;
            self.setZN(self.x);
        },
        .tay => {
            self.y = self.a;
            self.setZN(self.y);
        },
        .txa => {
            self.a = self.x;
            self.setZN(self.a);
        },
        .tya => {
            self.a = self.y;
            self.setZN(self.a);
        },
        .tsx => {
            self.x = self.s;
            self.setZN(self.x);
        },
        .txs => self.s = self.x, // the one transfer that leaves flags alone
        .nop => {},
        .asl, .lsr, .rol, .ror => self.a = self.applyRmw(self.a),
        else => unreachable,
    }
}

/// Instructions whose operand is a fetched byte that feeds registers and flags
/// without being written back anywhere.
fn applyRead(self: *Cpu) void {
    const v = self.val;
    switch (self.info.op) {
        .lda => {
            self.a = v;
            self.setZN(self.a);
        },
        .ldx => {
            self.x = v;
            self.setZN(self.x);
        },
        .ldy => {
            self.y = v;
            self.setZN(self.y);
        },
        .lax => {
            self.a = v;
            self.x = v;
            self.setZN(v);
        },
        .@"and" => {
            self.a &= v;
            self.setZN(self.a);
        },
        .ora => {
            self.a |= v;
            self.setZN(self.a);
        },
        .eor => {
            self.a ^= v;
            self.setZN(self.a);
        },
        .adc => self.adc(v),
        .sbc => self.sbc(v),
        .cmp => self.compare(self.a, v),
        .cpx => self.compare(self.x, v),
        .cpy => self.compare(self.y, v),
        .bit => {
            self.p.z = (self.a & v) == 0;
            self.p.v = (v & 0x40) != 0;
            self.p.n = (v & 0x80) != 0;
        },
        .nop => {},
        .anc => {
            self.a &= v;
            self.setZN(self.a);
            self.p.c = self.p.n;
        },
        .alr => {
            self.a &= v;
            self.p.c = (self.a & 0x01) != 0;
            self.a >>= 1;
            self.setZN(self.a);
        },
        .arr => {
            self.a &= v;
            const carry_in: u8 = @intFromBool(self.p.c);
            self.a = (self.a >> 1) | (carry_in << 7);
            self.setZN(self.a);
            self.p.c = (self.a & 0x40) != 0;
            self.p.v = (((self.a >> 6) ^ (self.a >> 5)) & 1) != 0;
        },
        // ANE and LXA depend on an analog "magic constant" that varies by chip
        // and temperature. 0xFF -- i.e. the OR term contributing nothing -- is
        // the value software and other emulators agree on.
        .lxa => {
            self.a = (self.a | 0xFF) & v;
            self.x = self.a;
            self.setZN(self.a);
        },
        .ane => {
            self.a = (self.a | 0xFF) & self.x & v;
            self.setZN(self.a);
        },
        .axs => {
            const anded = self.a & self.x;
            self.p.c = anded >= v;
            self.x = anded -% v;
            self.setZN(self.x);
        },
        .las => {
            const r = v & self.s;
            self.a = r;
            self.x = r;
            self.s = r;
            self.setZN(r);
        },
        else => unreachable,
    }
}

/// Read-modify-write instructions. `value` is what was just read back from
/// memory, or the accumulator for the accumulator-mode shifts; the return
/// value is what gets written back.
///
/// The combined unofficial opcodes (SLO/RLA/SRE/RRA/DCP/ISC) do a shift or
/// increment and then an ALU operation, and it is the *second* operation whose
/// flags survive.
fn applyRmw(self: *Cpu, value: u8) u8 {
    return switch (self.info.op) {
        .asl => blk: {
            self.p.c = (value & 0x80) != 0;
            const r = value << 1;
            self.setZN(r);
            break :blk r;
        },
        .lsr => blk: {
            self.p.c = (value & 0x01) != 0;
            const r = value >> 1;
            self.setZN(r);
            break :blk r;
        },
        .rol => blk: {
            const carry_in: u8 = @intFromBool(self.p.c);
            self.p.c = (value & 0x80) != 0;
            const r = (value << 1) | carry_in;
            self.setZN(r);
            break :blk r;
        },
        .ror => blk: {
            const carry_in: u8 = @intFromBool(self.p.c);
            self.p.c = (value & 0x01) != 0;
            const r = (value >> 1) | (carry_in << 7);
            self.setZN(r);
            break :blk r;
        },
        .inc => blk: {
            const r = value +% 1;
            self.setZN(r);
            break :blk r;
        },
        .dec => blk: {
            const r = value -% 1;
            self.setZN(r);
            break :blk r;
        },
        .slo => blk: {
            self.p.c = (value & 0x80) != 0;
            const r = value << 1;
            self.a |= r;
            self.setZN(self.a);
            break :blk r;
        },
        .rla => blk: {
            const carry_in: u8 = @intFromBool(self.p.c);
            self.p.c = (value & 0x80) != 0;
            const r = (value << 1) | carry_in;
            self.a &= r;
            self.setZN(self.a);
            break :blk r;
        },
        .sre => blk: {
            self.p.c = (value & 0x01) != 0;
            const r = value >> 1;
            self.a ^= r;
            self.setZN(self.a);
            break :blk r;
        },
        .rra => blk: {
            const carry_in: u8 = @intFromBool(self.p.c);
            self.p.c = (value & 0x01) != 0;
            const r = (value >> 1) | (carry_in << 7);
            self.adc(r); // ADC's carry and overflow overwrite ROR's carry
            break :blk r;
        },
        .isc => blk: {
            const r = value +% 1;
            self.sbc(r);
            break :blk r;
        },
        .dcp => blk: {
            const r = value -% 1;
            self.compare(self.a, r); // CMP's flags overwrite DEC's
            break :blk r;
        },
        else => unreachable,
    };
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;
const Cartridge = @import("../cart/Cartridge.zig");

/// A 32 KiB NROM image with `code` at $8000 and the reset vector pointing
/// there.
fn romWith(comptime code: []const u8) [16 + 32 * 1024]u8 {
    var bytes: [16 + 32 * 1024]u8 = @splat(0);
    bytes[0..4].* = .{ 'N', 'E', 'S', 0x1A };
    bytes[4] = 2; // 32 KiB PRG
    for (code, 0..) |byte, i| bytes[16 + i] = byte;
    bytes[16 + 0x7FFC] = 0x00;
    bytes[16 + 0x7FFD] = 0x80;
    return bytes;
}

/// A console booted into `code` at $8000. `cart` must outlive the result,
/// since `Nes` only borrows it.
fn testNes(cart: *Cartridge, comptime code: []const u8) Nes {
    const rom = struct {
        const bytes = romWith(code);
    };
    cart.* = Cartridge.load(&rom.bytes) catch unreachable;
    return Nes.init(cart);
}

/// Runs one full instruction and returns how many CPU cycles it took.
fn runInstruction(nes: *Nes) u64 {
    const start = nes.total_cycles;
    nes.stepCycle();
    while (nes.cpu.cycle != 0) nes.stepCycle();
    return nes.total_cycles - start;
}

test "the status byte round-trips, except for the two bits with no flip-flop" {
    var cpu: Cpu = .init;
    // Every combination of the six real flags survives a round trip.
    for (0..64) |bits| {
        const packed_byte: u8 = @intCast((bits & 0x0F) | ((bits & 0x30) << 2));
        cpu.unpackFlags(packed_byte);
        try testing.expectEqual(packed_byte | 0x20, cpu.status());
    }

    // Bit 5 always reads 1 and bit 4 always reads 0, whatever was pulled.
    cpu.unpackFlags(0xFF);
    try testing.expectEqual(@as(u8, 0xEF), cpu.status());
    cpu.unpackFlags(0x00);
    try testing.expectEqual(@as(u8, 0x20), cpu.status());

    // B only exists in the byte a push produces.
    try testing.expectEqual(@as(u8, 0x30), cpu.packFlags(true));
}

test "ADC sets overflow only when the operands agree in sign and the result does not" {
    const cases = [_]struct { a: u8, v: u8, carry: bool, sum: u8, c: bool, v_flag: bool }{
        // positive + positive, no wrap into the sign bit
        .{ .a = 0x01, .v = 0x01, .carry = false, .sum = 0x02, .c = false, .v_flag = false },
        // positive + positive overflowing into the sign bit
        .{ .a = 0x7F, .v = 0x01, .carry = false, .sum = 0x80, .c = false, .v_flag = true },
        // negative + negative overflowing out of it
        .{ .a = 0x80, .v = 0xFF, .carry = false, .sum = 0x7F, .c = true, .v_flag = true },
        // mixed signs can never overflow
        .{ .a = 0x7F, .v = 0x80, .carry = false, .sum = 0xFF, .c = false, .v_flag = false },
        .{ .a = 0x80, .v = 0x7F, .carry = true, .sum = 0x00, .c = true, .v_flag = false },
        // the carry in is part of the sum, and can push it over on its own
        .{ .a = 0x7F, .v = 0x00, .carry = true, .sum = 0x80, .c = false, .v_flag = true },
    };
    for (cases) |case| {
        var cpu: Cpu = .init;
        cpu.a = case.a;
        cpu.p.c = case.carry;
        cpu.adc(case.v);
        try testing.expectEqual(case.sum, cpu.a);
        try testing.expectEqual(case.c, cpu.p.c);
        try testing.expectEqual(case.v_flag, cpu.p.v);
        try testing.expectEqual(case.sum == 0, cpu.p.z);
        try testing.expectEqual((case.sum & 0x80) != 0, cpu.p.n);
    }
}

test "SBC is exactly ADC with the operand inverted" {
    for (0..256) |a| {
        for ([_]u8{ 0x00, 0x01, 0x7F, 0x80, 0xFF }) |v| {
            for ([_]bool{ false, true }) |carry| {
                var viaSbc: Cpu = .init;
                viaSbc.a = @intCast(a);
                viaSbc.p.c = carry;
                viaSbc.sbc(v);

                var viaAdc: Cpu = .init;
                viaAdc.a = @intCast(a);
                viaAdc.p.c = carry;
                viaAdc.adc(~v);

                try testing.expectEqual(viaAdc.a, viaSbc.a);
                try testing.expectEqual(viaAdc.status(), viaSbc.status());
            }
        }
    }
}

test "compare sets carry on greater-or-equal and the flags on the difference" {
    var cpu: Cpu = .init;
    cpu.compare(0x50, 0x50);
    try testing.expect(cpu.p.c and cpu.p.z and !cpu.p.n);
    cpu.compare(0x50, 0x40);
    try testing.expect(cpu.p.c and !cpu.p.z and !cpu.p.n);
    cpu.compare(0x40, 0x50);
    try testing.expect(!cpu.p.c and !cpu.p.z and cpu.p.n);
}

test "nextCycleIsWrite finds the write cycles of every class and mode" {
    var cpu: Cpu = .init;

    // A write-class instruction writes on its last cycle only.
    const write_cases = [_]struct { opcode: u8, last: u8 }{
        .{ .opcode = 0x85, .last = 2 }, // STA zp
        .{ .opcode = 0x95, .last = 3 }, // STA zp,X
        .{ .opcode = 0x8D, .last = 3 }, // STA abs
        .{ .opcode = 0x9D, .last = 4 }, // STA abs,X
        .{ .opcode = 0x81, .last = 5 }, // STA (zp,X)
        .{ .opcode = 0x91, .last = 5 }, // STA (zp),Y
    };
    for (write_cases) |case| {
        cpu.info = opcodes.table[case.opcode];
        for (1..8) |cycle| {
            cpu.cycle = @intCast(cycle);
            try testing.expectEqual(cycle == case.last, cpu.nextCycleIsWrite());
        }
    }

    // A read-modify-write writes on its last two: the dummy write-back and
    // then the real one.
    const rmw_cases = [_]struct { opcode: u8, last: u8 }{
        .{ .opcode = 0xE6, .last = 4 }, // INC zp
        .{ .opcode = 0xF6, .last = 5 }, // INC zp,X
        .{ .opcode = 0xEE, .last = 5 }, // INC abs
        .{ .opcode = 0xFE, .last = 6 }, // INC abs,X
        .{ .opcode = 0xE3, .last = 7 }, // ISC (zp,X)
    };
    for (rmw_cases) |case| {
        cpu.info = opcodes.table[case.opcode];
        for (1..8) |cycle| {
            cpu.cycle = @intCast(cycle);
            const expected = cycle == case.last or cycle == case.last - 1;
            try testing.expectEqual(expected, cpu.nextCycleIsWrite());
        }
    }

    // Read-class instructions never write.
    cpu.info = opcodes.table[0xBD]; // LDA abs,X
    for (1..8) |cycle| {
        cpu.cycle = @intCast(cycle);
        try testing.expect(!cpu.nextCycleIsWrite());
    }
}

test "nextCycleIsWrite finds the stack pushes, which belong to no write class" {
    var cpu: Cpu = .init;
    const cases = [_]struct { opcode: u8, writes: []const u8 }{
        .{ .opcode = 0x00, .writes = &.{ 2, 3, 4 } }, // BRK: PCH, PCL, P
        .{ .opcode = 0x20, .writes = &.{ 3, 4 } }, // JSR: PCH, PCL
        .{ .opcode = 0x48, .writes = &.{2} }, // PHA
        .{ .opcode = 0x08, .writes = &.{2} }, // PHP
    };
    for (cases) |case| {
        cpu.info = opcodes.table[case.opcode];
        for (1..8) |cycle| {
            cpu.cycle = @intCast(cycle);
            const expected = std.mem.indexOfScalar(u8, case.writes, @intCast(cycle)) != null;
            try testing.expectEqual(expected, cpu.nextCycleIsWrite());
        }
    }

    // A pull writes nothing.
    cpu.info = opcodes.table[0x68]; // PLA
    for (1..8) |cycle| {
        cpu.cycle = @intCast(cycle);
        try testing.expect(!cpu.nextCycleIsWrite());
    }
}

test "the opcode fetch cycle is always a read" {
    var cpu: Cpu = .init;
    for (0..256) |opcode| {
        cpu.info = opcodes.table[opcode];
        cpu.cycle = 0;
        try testing.expect(!cpu.nextCycleIsWrite());
    }
}

test "busAddress tracks what each addressing mode has actually put on the bus" {
    var cpu: Cpu = .init;
    cpu.pc = 0x1234;
    cpu.ea = 0x4444;
    cpu.uncorrected_addr = 0x5555;
    cpu.ptr = 0x66;

    // Before the operand bytes have been fetched, the bus is still on PC.
    cpu.info = opcodes.table[0xBD]; // LDA abs,X
    cpu.cycle = 0;
    try testing.expectEqual(@as(u16, 0x1234), cpu.busAddress());
    cpu.cycle = 1;
    try testing.expectEqual(@as(u16, 0x1234), cpu.busAddress());
    cpu.cycle = 2;
    try testing.expectEqual(@as(u16, 0x1234), cpu.busAddress());
    // The dummy read uses the uncorrected address, the fixup the real one.
    cpu.cycle = 3;
    try testing.expectEqual(@as(u16, 0x5555), cpu.busAddress());
    cpu.cycle = 4;
    try testing.expectEqual(@as(u16, 0x4444), cpu.busAddress());

    // (zp,X) reads the pointer before it is indexed, then the pair after.
    cpu.info = opcodes.table[0xA1]; // LDA (zp,X)
    cpu.cycle = 2;
    try testing.expectEqual(@as(u16, 0x0066), cpu.busAddress());
    cpu.cycle = 4;
    try testing.expectEqual(@as(u16, 0x0067), cpu.busAddress());
    cpu.cycle = 5;
    try testing.expectEqual(@as(u16, 0x4444), cpu.busAddress());

    // Modes with no effective address of their own stay on PC throughout.
    cpu.info = opcodes.table[0xA9]; // LDA #imm
    cpu.cycle = 1;
    try testing.expectEqual(@as(u16, 0x1234), cpu.busAddress());
}

test "reset takes 7 cycles, leaves S three lower, and loads the vector" {
    var cart: Cartridge = undefined;
    const nes = testNes(&cart, &.{0xEA}); // NOP

    // `Nes.init` has already run the sequence.
    try testing.expectEqual(@as(u16, 0x8000), nes.cpu.pc);
    try testing.expectEqual(@as(u8, 0xFD), nes.cpu.s); // 0 - 3
    try testing.expect(nes.cpu.p.i);
    try testing.expectEqual(@as(u64, 7), nes.total_cycles);
}

test "instruction timing: the page-crossing penalty applies to reads only" {
    var cart: Cartridge = undefined;
    // LDX #$10; LDA $80F0,X   (no cross)
    // LDX #$20; LDA $80F0,X   (crosses into $8110)
    // LDX #$20; STA $80F0,X   (a write always pays)
    var nes = testNes(&cart, &.{
        0xA2, 0x0F, 0xBD, 0xF0, 0x80,
        0xA2, 0x20, 0xBD, 0xF0, 0x80,
        0xA2, 0x20, 0x9D, 0xF0, 0x00,
    });

    _ = runInstruction(&nes); // LDX
    try testing.expectEqual(@as(u64, 4), runInstruction(&nes));
    _ = runInstruction(&nes); // LDX
    try testing.expectEqual(@as(u64, 5), runInstruction(&nes));
    _ = runInstruction(&nes); // LDX
    try testing.expectEqual(@as(u64, 5), runInstruction(&nes));
}

test "branch timing: 2 cycles not taken, 3 taken, 4 taken across a page" {
    var cart: Cartridge = undefined;
    // A not-taken branch, a taken one that stays on the page, and a taken one
    // that crosses backwards into $7Fxx.
    var nes = testNes(&cart, &.{
        0xA9, 0x01, // LDA #$01   (clears Z)
        0xF0, 0x02, // BEQ +2     not taken
        0xA9, 0x00, // LDA #$00   (sets Z)
        0xF0, 0x00, // BEQ +0     taken, same page
        0xF0, 0x80, // BEQ -128   taken, crosses back
    });

    _ = runInstruction(&nes); // LDA
    try testing.expectEqual(@as(u64, 2), runInstruction(&nes));
    _ = runInstruction(&nes); // LDA
    try testing.expectEqual(@as(u64, 3), runInstruction(&nes));
    try testing.expectEqual(@as(u64, 4), runInstruction(&nes));
}

test "a taken branch that stays on its page defers an interrupt a whole instruction" {
    var cart: Cartridge = undefined;
    // SEC so BCS is taken, then the branch, then two NOPs.
    var nes = testNes(&cart, &.{ 0x38, 0xB0, 0x00, 0xEA, 0xEA });

    _ = runInstruction(&nes); // SEC

    // Assert NMI so it is latched before the branch's only poll, then clear
    // the latch: the branch's poll is the one that must see it.
    nes.cpu.nmi_pending = true;
    _ = runInstruction(&nes); // the taken branch
    try testing.expect(nes.cpu.interrupt_ready);

    // The same branch with the NMI arriving *after* its fixed poll leaves the
    // interrupt unlatched, so it waits for the next instruction's poll.
    var cart2: Cartridge = undefined;
    var late = testNes(&cart2, &.{ 0x38, 0xB0, 0x00, 0xEA, 0xEA });
    _ = runInstruction(&late); // SEC
    late.stepCycle(); // the branch's opcode fetch
    late.stepCycle(); // its one poll, which sees no NMI
    late.cpu.nmi_pending = true;
    while (late.cpu.cycle != 0) late.stepCycle();
    try testing.expect(!late.cpu.interrupt_ready);
}

test "an NMI arriving mid-BRK hijacks the vector the dispatch was going to use" {
    var cart: Cartridge = undefined;
    var nes = testNes(&cart, &.{0x00}); // BRK

    nes.stepCycle(); // opcode fetch
    // Cycles 1-3 push PC and P; the vector is not chosen until cycle 4.
    for (0..3) |_| nes.stepCycle();
    nes.cpu.nmi_pending = true;
    nes.stepCycle(); // cycle 4 resolves the vector
    try testing.expectEqual(@as(u16, 0xFFFA), nes.cpu.interrupt_vector);
    try testing.expect(!nes.cpu.nmi_pending); // consumed

    // Without the NMI it takes the IRQ/BRK vector.
    var cart2: Cartridge = undefined;
    var plain = testNes(&cart2, &.{0x00});
    for (0..5) |_| plain.stepCycle();
    try testing.expectEqual(@as(u16, 0xFFFE), plain.cpu.interrupt_vector);
}

test "BRK pushes B set and skips its padding byte; a hardware IRQ does neither" {
    var cart: Cartridge = undefined;
    var nes = testNes(&cart, &.{ 0x00, 0xFF, 0xEA }); // BRK, padding, NOP

    const s_before = nes.cpu.s;
    _ = runInstruction(&nes);
    // The pushed flags carry B, and PC skipped the padding byte.
    try testing.expectEqual(@as(u8, 0x10), nes.ram[0x0100 | @as(u16, s_before -% 2)] & 0x10);
    const pushed_pc = @as(u16, nes.ram[0x0100 | @as(u16, s_before)]) << 8 |
        nes.ram[0x0100 | @as(u16, s_before -% 1)];
    try testing.expectEqual(@as(u16, 0x8002), pushed_pc);
}

test "a read-modify-write writes the old value back before the new one" {
    var cart: Cartridge = undefined;
    // INC $10, with $10 in RAM. The dummy write-back is visible only from the
    // bus, so watch RAM cycle by cycle.
    var nes = testNes(&cart, &.{ 0xE6, 0x10 });
    nes.ram[0x10] = 0x41;

    nes.stepCycle(); // fetch
    nes.stepCycle(); // operand
    nes.stepCycle(); // read
    try testing.expectEqual(@as(u8, 0x41), nes.ram[0x10]);
    nes.stepCycle(); // dummy write-back of the old value
    try testing.expectEqual(@as(u8, 0x41), nes.ram[0x10]);
    nes.stepCycle(); // the real write
    try testing.expectEqual(@as(u8, 0x42), nes.ram[0x10]);
}

test "JMP (indirect) takes its high byte from the same page as the low one" {
    var cart: Cartridge = undefined;
    var nes = testNes(&cart, &.{ 0x6C, 0xFF, 0x02 }); // JMP ($02FF)
    nes.ram[0x02FF] = 0x34;
    nes.ram[0x0200] = 0x12; // where the wrapped high-byte fetch lands
    nes.ram[0x0300] = 0xAB; // where an unwrapped one would

    try testing.expectEqual(@as(u64, 5), runInstruction(&nes));
    try testing.expectEqual(@as(u16, 0x1234), nes.cpu.pc);
}

test "the stack pointer wraps inside page 1" {
    var cart: Cartridge = undefined;
    var nes = testNes(&cart, &.{ 0x48, 0x48 }); // PHA, PHA
    nes.cpu.s = 0x00;
    nes.cpu.a = 0x5A;

    _ = runInstruction(&nes);
    try testing.expectEqual(@as(u8, 0x5A), nes.ram[0x0100]);
    try testing.expectEqual(@as(u8, 0xFF), nes.cpu.s);
    _ = runInstruction(&nes);
    try testing.expectEqual(@as(u8, 0x5A), nes.ram[0x01FF]);
}

test "a JAM opcode stops the CPU for good" {
    var cart: Cartridge = undefined;
    var nes = testNes(&cart, &.{ 0x02, 0xEA }); // JAM, NOP

    nes.stepCycle(); // fetch
    nes.stepCycle(); // the JAM's read
    try testing.expect(nes.cpu.jammed);

    const pc = nes.cpu.pc;
    for (0..100) |_| nes.stepCycle();
    try testing.expectEqual(pc, nes.cpu.pc);
}

test "a DMA interrupting an unstable store drops its high-byte AND term" {
    var cpu: Cpu = .init;
    cpu.a = 0xFF;
    cpu.x = 0x0F;
    cpu.y = 0xF0;
    cpu.hi = 0x0F; // so the correction term is $10

    cpu.info = opcodes.table[0x9F]; // SHA abs,Y
    try testing.expectEqual(@as(u8, 0x0F & 0x10), cpu.writeValue());
    cpu.dma_interrupted = true;
    try testing.expectEqual(@as(u8, 0x0F), cpu.writeValue());

    cpu.dma_interrupted = false;
    cpu.info = opcodes.table[0x9E]; // SHX abs,Y
    try testing.expectEqual(@as(u8, 0x0F & 0x10), cpu.writeValue());
    cpu.info = opcodes.table[0x9C]; // SHY abs,X
    try testing.expectEqual(@as(u8, 0xF0 & 0x10), cpu.writeValue());

    // The stable stores are unaffected either way.
    cpu.info = opcodes.table[0x8D]; // STA abs
    cpu.dma_interrupted = true;
    try testing.expectEqual(@as(u8, 0xFF), cpu.writeValue());
}

test "an unstable store crossing a page corrupts the address it writes to" {
    var cpu: Cpu = .init;
    cpu.a = 0xFF;
    cpu.x = 0xFF;
    cpu.hi = 0x0F;
    cpu.info = opcodes.table[0x9F]; // SHA abs,Y

    const value = cpu.writeValue(); // $FF & $FF & $10 = $10
    cpu.page_crossed = false;
    try testing.expectEqual(@as(u16, 0x1234), cpu.writeAddress(0x1234, value));
    cpu.page_crossed = true;
    // The high byte becomes the same already-ANDed byte being stored.
    try testing.expectEqual(@as(u16, 0x1034), cpu.writeAddress(0x1234, value));
}

test "the combined unofficial opcodes keep the second operation's flags" {
    var cpu: Cpu = .init;

    // DCP decrements then compares: CMP's flags win over DEC's.
    cpu.info = opcodes.table[0xC7]; // DCP zp
    cpu.a = 0x40;
    const dcp = cpu.applyRmw(0x41);
    try testing.expectEqual(@as(u8, 0x40), dcp);
    try testing.expect(cpu.p.z and cpu.p.c); // A == the decremented value

    // SLO shifts then ORs: the OR's result sets Z/N, the shift sets C.
    cpu.info = opcodes.table[0x07]; // SLO zp
    cpu.a = 0x00;
    const slo = cpu.applyRmw(0x80);
    try testing.expectEqual(@as(u8, 0x00), slo);
    try testing.expect(cpu.p.c); // out of the shift
    try testing.expect(cpu.p.z); // A ended up 0
}

test "LAX loads both registers and SAX stores their intersection" {
    var cpu: Cpu = .init;
    cpu.info = opcodes.table[0xA7]; // LAX zp
    cpu.val = 0x96;
    cpu.applyRead();
    try testing.expectEqual(@as(u8, 0x96), cpu.a);
    try testing.expectEqual(@as(u8, 0x96), cpu.x);
    try testing.expect(cpu.p.n);

    cpu.info = opcodes.table[0x87]; // SAX zp
    cpu.a = 0xF0;
    cpu.x = 0x3C;
    try testing.expectEqual(@as(u8, 0x30), cpu.writeValue());
}

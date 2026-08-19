// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! Ricoh 2C02 PPU: background and sprite pipelines, scrolling, sprite
//! evaluation, sprite 0 hit and overflow, and VBlank/NMI timing, all driven
//! dot by dot from `tick`.
//!
//! ## The address register is the scroll register
//!
//! `v` is both the current VRAM pointer and the scroll position, with coarse
//! and fine X/Y packed into its 15 bits alongside the nametable select. `t` is
//! the pending copy of it that $2005 and $2006 assemble, `fine_x` the
//! three-bit horizontal offset that lives outside it, and `write_latch` the
//! shared toggle those two registers use to tell their first write from their
//! second. Everything the fetch cadence does to the address -- coarse X
//! increments, the fine Y increment at dot 256, the horizontal and vertical
//! reloads -- moves the scroll position at the same time, which is what makes
//! mid-frame $2006 writes a scrolling technique rather than a corruption.
//!
//! ## Nothing lands on the cycle it was written
//!
//! A CPU write reaches the PPU's internal registers a couple of PPU cycles
//! after the write cycle it rode in on, and a VRAM access straddles that gap.
//! `pending_mask`, `pending_v` and the $2007 state machine (`data_sm`) each
//! model one of those delays, and between them they are responsible for most
//! of the timing behavior software can observe here.
//!
//! ## Deliberate omissions
//!
//! OAM decay is not modelled, and will not be. OAM really is dynamic RAM
//! refreshed only by rendering, but the decay is more or less random,
//! sensitive to temperature, and not something a game can rely on. The two
//! figures for how fast it fades disagree by more than an order of magnitude
//! -- roughly one vertical blank (~1.3 ms), against the *whole frame* of
//! forced blank that AccuracyCoin's OAM Corruption test needs OAM to survive.
//! Both of that test's rows-copied checks fail against the short figure, in
//! opposite directions, so no choice of decayed bit value rescues it. Any
//! constant long enough to pass would be an invented number matching no
//! measurement, and no game is known to depend on OAM decaying while every
//! game depends on it persisting.
//!
//! "Early writes" are modelled in exactly one place. The CPU asserts a write
//! before it drives the data bus, so for about the first dot the PPU latches
//! open bus instead of the value -- normally the high byte of the address,
//! hence $20 for `sta $2001`. That reaches PPUMASK's two combinational bits
//! here (`pending_mask_early`), and nowhere else. It is also why AccuracyCoin
//! writes rendering-enable through the $3E01 mirror: $3E & $1F is $1E, so bits
//! 3 and 4 already agree during that window, where a plain $2001 write would
//! show $20 and blank for a dot.
//!
//! **Every other documented early-write path is deliberately absent.**
//! PPUMASK's rendering-enable bits and the second $2006 write break
//! hardware-verified test ROMs. The $2000 nametable bits put a wrong scanline
//! into *Super Mario Bros.* that hardware does not show, and the first $2005
//! write's fine X is unobservable by construction -- `writeRegister` runs
//! after the cycle's three dots, so the early value is corrected before any
//! dot is drawn with it.
//!
//! What survives is the one path that can only ever tint a single dot, never
//! move where the picture comes from. That asymmetry is the rule for any
//! future one: colour costs a dot, address costs a frame. A path no ROM
//! contradicts is not thereby permitted -- the ones above are contradicted by
//! hardware, by test ROMs, or by having no effect at all.

const Ppu = @This();
const Cartridge = @import("../cart/Cartridge.zig");
const Palette = @import("../video/Palette.zig");
const Mirroring = @import("../cart/mapper/mapper.zig").Mirroring;

const timing = @import("../timing.zig");
const dots_per_scanline = timing.dots_per_scanline;
const scanlines_per_frame = timing.scanlines_per_frame;
const visible_scanlines = timing.visible_scanlines;
const vblank_start_scanline = timing.vblank_start_scanline;
const prerender_scanline = timing.prerender_scanline;
pub const screen_width = timing.screen_width;
pub const screen_height = timing.screen_height;

/// See `pending_mask`'s doc comment.
///
/// **Do not raise this to the 3-4 dots the hardware documentation gives.**
/// That figure is real, and it comes with a note that the delay is what keeps
/// Battletoads from crashing -- but `ppu_vbl_nmi/10-even_odd_timing` measures
/// the constant directly and rejects anything above 2: at 3 it reports "Clock
/// is skipped too soon, relative to enabling BG", and 4 loses AccuracyCoin as
/// well. Reconciling the two means splitting where the odd-frame dot skip
/// reads the mask from where rendering-enable reads it, not moving this. If
/// Battletoads ever hangs, that split is the thing to suspect.
const mask_write_delay_ticks: u8 = 2;

/// How many dots after a forced blank lands the OAM corruption seed is read
/// off secondary OAM's address counter.
///
/// **Not the same instant the blank lands.** The corruption itself happens
/// two PPU cycles after the $2001 write, i.e. `mask_write_delay_ticks`, but
/// the address the seed takes settles a dot later still. Landing it too early
/// puts the seed on a row that is in use, which shows up as a sprite table
/// quietly disintegrating a hundred scanlines after rendering was toggled.
const oam_corruption_seed_delay: u16 = 3;

/// How many dots the CPU's view of /NMI lags the line the PPU drives.
/// See `nmi_line_shift`.
const nmi_line_delay_dots: u3 = 2;

/// See `pending_v`'s doc comment. One dot further out than the mask's
/// because this one is measured against a *read*, which happens on the
/// second dot of an access rather than the first.
const v_write_delay_ticks: u8 = 3;

/// Sprite evaluation occupies dots 65-256; see `eval_buffer_by_dot`.
const eval_window_start: u16 = 65;
const eval_window_len: usize = 256 - 65 + 1;

/// PPU cycles before an unrefreshed bit of the I/O data bus latch decays to
/// 0. The real decay is an analog effect with no fixed timing, and misbehaves
/// for a while right after power-on; anything between 5 and 30 frames is a
/// reasonable deterministic stand-in, and this picks 20 frames' worth.
const data_bus_decay_period: u32 = 20 * dots_per_scanline * scanlines_per_frame;

/// $2000 PPUCTRL. Bit widths/order match hardware exactly, so the whole
/// register round-trips through `@bitCast` to/from the byte the CPU
/// actually reads and writes.
pub const Ctrl = packed struct(u8) {
    nametable: u2 = 0,
    vram_increment: enum(u1) { add_1, add_32 } = .add_1,
    sprite_pattern_table: enum(u1) { at_0000, at_1000 } = .at_0000,
    background_pattern_table: enum(u1) { at_0000, at_1000 } = .at_0000,
    sprite_size: enum(u1) { size_8x8, size_8x16 } = .size_8x8,
    /// PPU master/slave select; wired but unused on the NES.
    master_slave: u1 = 0,
    nmi_enable: bool = false,
};

/// $2001 PPUMASK.
pub const Mask = packed struct(u8) {
    greyscale: bool = false,
    show_background_left: bool = false,
    show_sprites_left: bool = false,
    show_background: bool = false,
    show_sprites: bool = false,
    emphasize_red: bool = false,
    emphasize_green: bool = false,
    emphasize_blue: bool = false,
};

/// Sprite evaluation's state machine, as of one dot.
///
/// The whole scan is one narrow pipe: every byte that moves between primary
/// OAM and secondary OAM passes through the single-byte OAM buffer, on a
/// strict two-dot rhythm -- odd dots read primary OAM into the buffer, even
/// dots write the buffer into secondary OAM. That rhythm is directly
/// observable, because `$2004` hands the CPU the buffer, so software reading
/// it dot by dot sees the scan's intermediate state.
///
/// Kept as a plain value rather than as fields on `Ppu` so a copy can be
/// stepped forward speculatively without disturbing the real one; see
/// `spriteEvalAt`.
const SpriteEval = struct {
    const Phase = enum {
        /// Secondary OAM still has room: ordinary selection.
        scan,
        /// Secondary OAM is full but the sprite counter hasn't wrapped:
        /// this is where the overflow flag comes from, and where the
        /// famous "diagonal" address bug lives.
        overflow,
        /// The sprite counter wrapped. Reads continue, selection can't.
        done,
    };

    phase: Phase = .scan,
    /// Primary OAM address, i.e. hardware's 4n+m.
    addr: u8 = 0,
    /// Sprites examined; the counter that wraps at 64.
    n: u16 = 0,
    /// Bytes still owed to an in-range sprite whose Y byte has been taken.
    copy_left: u8 = 0,
    full: bool = false,
    has_sprite0: bool = false,
    /// The Y byte the preceding odd dot latched, which the even dot
    /// range-checks.
    y: u8 = 0xFF,
    buffer: u8 = 0xFF,
    oam2_addr: u8 = 0,
    /// Set on the dot the 9th in-range sprite is found. `renderTick`
    /// turns this into the status flag; `readRegister` peeks at it so a
    /// $2002 read landing on that dot already sees it.
    overflow_hit: bool = false,
};

/// Which line of the PPU DATA state machine is asserted on a given dot.
///
/// A CPU read of $2007 does not fetch anything itself; it starts a chain of
/// five D latches clocked alternately off both phases of the PPU clock. Two
/// PPU cycles after the read ends the chain raises ALE, and two cycles after
/// *that* it raises Read -- so the read buffer is filled four dots late, and
/// lands in the middle of the background/sprite fetch cadence if rendering is
/// on.
///
/// The two timing sources are independent, and the fetch cadence wins every
/// conflict for the address bus; see `cadenceOwnsBus`.
const DataSmPhase = enum { idle, ale, read };

/// One $2007 read travelling through that chain.
const DataRead = struct {
    /// Dots since the CPU read cycle it came from. ALE at 2, Read at 4.
    age: u8,
    /// `v` as of that read, before the increment the Read pulse applies.
    addr: u16,
};

/// $2002 PPUSTATUS. The low 5 bits aren't real PPU state -- reads mix in
/// whatever was last on the PPU data bus -- so they're kept as padding
/// here rather than modeled as fields.
pub const Status = packed struct(u8) {
    _unused: u5 = 0,
    sprite_overflow: bool = false,
    sprite0_hit: bool = false,
    vblank: bool = false,
};

cart: *Cartridge,

dot: u16 = 0,
scanline: u16 = 0,
frame: u64 = 0,
odd_frame: bool = false,

/// Completed pictures: bumped when rendering reaches the post-render
/// scanline, i.e. the instant `framebuffer` holds a whole finished image.
///
/// `frame` counts the same events one scanline-block later, at the wrap to
/// scanline 0, which is the right boundary for the PPU's own periodic state
/// but the wrong one for a frontend. A frontend wants to cut its loop *here*,
/// between the last visible dot and VBlank, for two reasons: the picture it
/// is about to display is complete, and the controller state it is about to
/// latch is still early enough to reach the NMI handler that runs a scanline
/// later. Cutting at scanline 0 instead puts a whole frame of rendering
/// between reading the input and the code that acts on it.
picture: u64 = 0,

ctrl: Ctrl = .{},
mask: Mask = .{},
/// A $2001 write does not reach the internal render-enable latch instantly:
/// it lands a couple of PPU cycles later, and exactly how many depends on the
/// CPU/PPU clock alignment the console powered up in. Modelled as a fixed
/// delay, since this emulator's CPU and PPU are locked to one alignment.
pending_mask: ?Mask = null,
mask_write_delay: u8 = 0,
/// The open-bus value a $2001 write shows in the mask register for the one
/// dot before the real value catches up, and the countdown before it lands.
///
/// **This is not a second write.** It is the same write seen through the
/// window where the CPU has asserted R/W but has not yet driven the data
/// bus, so the PPU sees whatever the bus last held -- normally the high byte
/// of the store's address. See `writeRegisterEarly`.
///
/// **Only bits 0 and 7 take it: greyscale and blue emphasis.** On the 2C02G
/// those two are processed asynchronously rather than through the register, so
/// the bus value reaches them directly -- any write to PPUMASK can turn the
/// monochrome flag off for one pixel, and can turn blue emphasis off for half
/// of one, whatever the subpixel phase.
///
/// **The rendering-enable bits ($18) must not take it.** Those belong to the
/// 2C02A, an earlier revision than the one this PPU models
/// (`applyOamRefreshBug` is 2C02G/H behavior). Letting them glitch is not a
/// harmless overshoot: applying the early value to $18 makes
/// `ppu_vbl_nmi/10-even_odd_timing` fail #5 ("Clock is skipped too late,
/// relative to disabling BG", `08 08 09 08` against the expected
/// `08 08 09 07`) and takes `sprite_overflow_tests` with it, because every
/// $2001 write that keeps rendering on would drop it for a dot and arm OAM
/// corruption.
pending_mask_early: ?u8 = null,
mask_early_delay: u8 = 0,
/// `renderingEnabled()` as it stood one dot ago -- i.e. the render-enable
/// signal seen through one extra register stage.
///
/// Hardware doesn't drive the whole rendering pipeline off a single gate.
/// The background/sprite *shift* clocks watch the mask register directly,
/// so they stop and restart on the very dot a $2001 write lands. Everything
/// on the *fetch* side (nametable/attribute/pattern reads, the sliver
/// commit that reloads the shift registers and increments coarse X, the
/// sprite fetch window, secondary-OAM clearing) is driven through a further
/// latch that updates at the top of each dot, so it stops and restarts one
/// dot later.
///
/// That one-dot skew is what makes a short forced blank observable at all.
/// With a single gate the first reload afterwards always lands early enough
/// to flush the shift register's serial-input bits back out, and the pattern
/// they would have drawn never appears.
rendering_delayed: bool = false,
status: Status = .{},
oam_addr: u8 = 0,
oam: [256]u8 = @splat(0),

/// PPU-side open bus, as last latched. Decays to 0 on real hardware if
/// nothing refreshes it for a while (an analog effect with no "canonical"
/// timing -- see `data_bus_decay_period`). Read it through `openBus`,
/// never directly: the decay lives in `data_bus_decay_at`, so this field
/// on its own can hold bits that have already rotted away.
data_bus: u8 = 0,
/// When each bit of `data_bus` goes stale, as a `dots_elapsed` stamp.
///
/// Per-bit, not one shared countdown, because a register read can refresh
/// *part* of the bus and leave the rest ageing: $2002 drives bits 7-5 and
/// leaves 4-0 alone, and a $2007 palette read drives 5-0 and leaves 7-6.
/// Software can hammer either of those reads for a second and still see the
/// untouched bits rot away, which a single shared timer cannot express: every
/// read would keep the whole bus alive forever.
///
/// Stored as expiry stamps rather than counters so `tick` doesn't have to
/// touch eight of them every dot; the check happens on register reads,
/// which are rare by comparison.
data_bus_decay_at: [8]u64 = @splat(0),
/// Free-running dot counter, only used as the time base for the above.
dots_elapsed: u64 = 0,

/// Internal read buffer for $2007 (all reads except palette are delayed
/// by one).
read_buffer: u8 = 0,

/// The external octal latch every NES cartridge carries, and the reason a
/// PPU memory access takes *two* dots rather than one.
///
/// The PPU only has 14 pins for a 14-bit address plus an 8-bit data bus,
/// so the low 8 are shared. On the first dot of an access ("ALE" -- see
/// `data_sm_phase`) the PPU drives all 14 address bits and the latch
/// captures the low 8; on the second dot it drives only the *upper 6*,
/// and the low 8 come back out of the latch while the same pins carry the
/// data being read.
///
/// So the address a read actually lands on is a hybrid: high bits as of
/// the read dot, low bits as of the dot before it. Normally those agree, but
/// a $2006 write timed to move `v` in between splits them, and the access
/// lands on an address that was never held whole.
octal_latch: u8 = 0,

/// The last byte the PPU pulled off the VRAM data bus. Only observable
/// through the latch: on a dot where ALE and Read are both asserted, the
/// latch is transparent while memory is driving those shared pins, so it
/// takes the data rather than the address. See `aleCycle`.
vram_data_bus: u8 = 0,

/// $2007 reads currently making their way through the state machine.
///
/// The latch chain is five stages deep, so a read entering it before the
/// previous one has come out the far end just travels behind it. That
/// matters as soon as two reads land on consecutive CPU cycles -- three dots
/// apart, inside the four a read takes -- which is what a DMA's pair of dummy
/// reads does when it halts the CPU mid-`LDA $2007`. Two slots is the most
/// that can ever be busy, since nothing can issue reads closer than one CPU
/// cycle apart.
data_sm: [2]?DataRead = @splat(null),
/// What the state machine is driving on the dot currently being ticked.
data_sm_phase: DataSmPhase = .idle,
/// The address behind `data_sm_phase`, i.e. the `v` of whichever read is
/// currently at that stage.
data_sm_addr: u16 = 0,

/// Loopy v/t/x/w registers, shared by $2005/$2006/rendering address.
v: u15 = 0,
/// `t` waiting to be copied into `v` by the second half of a $2006 write,
/// and the countdown before it lands. Same shape as `pending_mask`, and
/// the same reason: a CPU write reaches the PPU's own registers a couple
/// of PPU cycles after the write cycle it rode in on.
///
/// It has to be a couple of cycles and not zero because a VRAM access
/// straddles the gap. Land `v` too early and the address setup a dot before
/// the read already sees the new value; land it too late and the read does
/// too. Either way the access comes out coherent, and it is precisely its
/// *incoherence* that software can observe -- see `octal_latch`.
///
/// **There is no early-write stage on the way in**, though the write is
/// documented to have one: it is said to put open bus into the low three bits
/// of coarse Y and all five of coarse X for a pixel before the real value
/// lands, showing as an incorrect sliver.
///
/// AccuracyCoin's `Hybrid Addresses` subtest 2 rules that out at this PPU's
/// timing. That test writes $2F then $00 to $2006 mid-fetch and requires the
/// nametable read to come from $2F19 -- the *new* `v`'s high byte over the
/// octal latch the *previous* dot left at $19. Letting the open-bus byte
/// ($20, from the store's operand) into `v[7:0]` for the dot before the real
/// value lands puts $20 into that latch instead, the read goes to $2F20, and
/// the sprite 0 hit it is looking for never happens. Same shape as the
/// PPUMASK case in `pending_mask_early`: the documented early-write behaviour
/// covers more paths than this revision actually exposes, and the ROMs cut it
/// back.
pending_v: ?u15 = null,
pending_v_delay: u8 = 0,
t: u15 = 0,
fine_x: u3 = 0,
write_latch: bool = false,

nmi_output: bool = false,

/// The /NMI line as the PPU drives it (`nmi_output AND vblank`), and the
/// one-dot-delayed copy the CPU's edge detector actually samples.
///
/// The delay matters because `Nes.stepCycle` advances the PPU a whole CPU
/// cycle's worth (3 dots) before polling, which would otherwise let the CPU
/// react to an assertion that happened on the very last of those three dots
/// -- a third of a CPU cycle too early. Software can measure this by sweeping
/// the NMI's arrival against a run of two-cycle instructions one PPU cycle at
/// a time, and without the delay every step of that sweep lands early.
nmi_line: bool = false,
/// History of `nmi_line`, one bit per dot: bit 0 is the line as of the end
/// of the previous dot, bit 1 two dots ago, and so on. The edge detector
/// reads two adjacent bits out of this, `nmi_line_delay_dots` deep.
nmi_line_shift: u8 = 0,
/// Sticky latch for the delayed line's rising edge, set per *dot* and
/// consumed by `Cpu.pollEdges`. Edge detection has to happen at dot
/// granularity because the line can pulse high for a single dot and go
/// low again within one CPU cycle -- e.g. enabling NMI on the last dot
/// before the pre-render line clears VBlank. Sampling only once per CPU
/// cycle drops those pulses entirely.
nmi_edge_pending: bool = false,

/// The OAM buffer: the single-byte latch sitting between primary OAM and
/// secondary OAM, through which every byte of both passes. While the PPU
/// owns the OAM bus (rendering, on a visible or pre-render line) a `$2004`
/// read returns *this*, not `oam[oam_addr]` -- so what the CPU sees moves
/// every dot, tracking whatever step of the clear/evaluate/fetch machinery is
/// running -- so software reading $2004 across a whole scanline sees a
/// different byte on each of its 341 dots.
oam_buffer: u8 = 0xFF,

/// Secondary OAM's own 5-bit address counter, which hardware drives (the
/// CPU has no way to write it). Its per-dot value is what the buffer reads
/// and writes go through, and -- because it also survives a forced blank --
/// it's the "seed" that decides which row of OAM gets clobbered when
/// rendering comes back on. See `pending_oam_corruption`.
oam2_addr: u8 = 0,

/// Sprite evaluation's live state, advanced one dot at a time across the
/// 65-256 window by `tickSpriteEval`.
///
/// Stepped one dot at a time rather than computed in one shot, because three
/// things the scan depends on can change mid-scanline: rendering can be
/// switched off, which stops the scan where it stands; sprite height can
/// change through $2000; and OAM can be rewritten by DMA during a forced
/// blank. Predicting the result at the start of the window gets all three
/// wrong.
sprite_eval: SpriteEval = .{},
/// The dot `sprite_eval` has been advanced through, or 0 when the scan
/// hasn't run yet on this scanline. Consumers that ask about a dot the PPU
/// hasn't ticked yet (see `spriteEvalAt`) compare against this, and it is
/// what distinguishes "no scan yet, start a fresh one" from "mid-scan".
sprite_eval_dot: u16 = 0,

/// Secondary OAM's address at the moment rendering was switched off
/// mid-line, held until rendering comes back. Hardware's OAM cell array
/// can't be left un-driven the way a forced blank leaves it, and the first
/// rendering dot afterwards resolves the conflict by copying OAM row 0 (8
/// bytes) over the row this seed names -- plus `secondary_oam[0]` over
/// `secondary_oam[seed]`. Row 0 being the *source* is what keeps sprite 0
/// (and therefore ordinary sprite-0 hits) safe from it, and what makes the
/// dots 321-340 window -- where the seed is 0 and the copy is a no-op --
/// the safe place for a game to disable rendering.
pending_oam_corruption: ?u8 = null,

/// The PPU's internal reset signal, held from power-on or reset until the
/// first end of VBlank.
///
/// While it is asserted it holds PPUCTRL, PPUMASK, PPUSCROLL, PPUADDR, the
/// shared $2005/$2006 latch and the PPUDATA read buffer cleared, and a write
/// aimed at any of them lands on nothing. That is the warm-up software has to
/// wait out after a reset. It is cleared at the end of VBlank, by the same
/// signal that clears the VBlank, sprite 0 and overflow flags.
///
/// Modelled as that signal rather than as a fixed cycle count, because the
/// familiar figure of roughly 29658 CPU clocks is a *consequence* of coming
/// out of reset at the top of the picture and clearing at pre-render dot 1.
/// Deriving it costs nothing and cannot drift out of step with the rest of
/// the frame timing.
in_reset: bool = true,

/// Set when the odd-frame dot skip swallows pre-render's dot 340, so the
/// nametable read that dot owed can happen on the dot jumped to instead.
///
/// The skip jumps straight from (339, 261) to (0, 0) and performs the last
/// cycle of that dummy fetch on the dot it lands on. Dropping the fetch
/// instead would make odd frames issue one fewer VRAM read than even ones --
/// invisible on screen, but MMC3's IRQ counter is built out of exactly these
/// fetches.
deferred_nt_fetch: bool = false,

/// Set alongside `deferred_nt_fetch`: the same skipped dot also delays the
/// pulse that restarts the sprite X counters, so scanline 0's first dot
/// behaves as though every slot had already reached its X.
///
/// The pulse that restarts the counters is issued on dot 339, so when the
/// skip swallows the dot after it the signal reaches the shifters one dot
/// late. Every shifter emits its first pixel at X=0, and they start counting
/// on the next dot, emitting their remaining seven pixels at the usual time.
sprite_shifters_late: bool = false,

/// Armed by a $2002 read that happens on the same dot the VBlank flag is
/// about to be set; consumed (and cleared) by that dot's tick. See the
/// use site in `tick`.
suppress_vblank_set: bool = false,

vram: [0x800]u8 = @splat(0),
palette: [32]u8 = @splat(0),

// --- Background pipeline -------------------------------------------------
bg_shift_lo: u16 = 0,
bg_shift_hi: u16 = 0,
bg_attr_shift_lo: u16 = 0,
bg_attr_shift_hi: u16 = 0,
nt_latch: u8 = 0,
/// The 2-bit palette selection for the tile currently being fetched,
/// resolved from the attribute byte at fetch time (see `fetchCycle`'s
/// dot%8==4 case for why it can't be deferred to commit time).
next_attr_bits: u2 = 0,
/// The 2-bit palette selection most recently committed to the shift
/// registers, which also feeds their serial input -- unlike the pattern
/// planes, the attribute shifters don't clock in a constant. Invisible
/// while tiles keep arriving (the committed byte is 8 copies of this same
/// bit), and only observable once a forced blank stops the commits: the
/// background then keeps the last palette rather than falling back to
/// palette 0.
bg_attr_latch: u2 = 0,
bg_lo_latch: u8 = 0,
bg_hi_latch: u8 = 0,

// --- Sprite pipeline -----------------------------------------------------
/// Secondary OAM for the scanline currently being *evaluated* (i.e. the
/// one after `scanline`), populated at the end of the visible/prerender
/// fetch window and consumed via `sprite_*` below on the next scanline.
secondary_oam: [32]u8 = @splat(0xFF),
secondary_oam_has_sprite0: bool = false,

/// Sprites actually being rendered on the current scanline (fetched
/// during dots 257-320 of the *previous* scanline).
///
/// Sprites aren't addressed by comparing X against the current pixel:
/// each slot owns a down-counter loaded with the sprite's X, and the slot
/// only starts drawing once that counter hits zero -- from which point it
/// shifts one pixel out per dot forever, transparent once the pattern has
/// run dry. The distinction is invisible while rendering stays on for a
/// whole scanline, but counter and shifter are gated separately: a forced
/// blank stops one and not the other, and a slot left halted at zero draws
/// from the very first dot rendering comes back on.
sprite_shift_lo: [8]u8 = @splat(0),
sprite_shift_hi: [8]u8 = @splat(0),
sprite_counter: [8]u8 = @splat(0),
sprite_attr: [8]u8 = @splat(0),
sprite0_present: bool = false,

/// One entry per visible pixel: the 6-bit palette index that was output,
/// plus the three PPUMASK emphasis bits in force at that dot, packed as
/// `(emphasis << 6) | index`. RGB conversion is a presentation-layer
/// concern for whatever eventually reads this -- `Palette.table` is
/// indexed by exactly this value.
///
/// Emphasis has to travel per-pixel rather than be read off the register
/// at present time: it is part of PPUMASK, so a game can change it
/// mid-frame (and mid-scanline), which is the whole basis of the
/// full-screen flash and fade effects it gets used for.
framebuffer: [screen_width * screen_height]Palette.Pixel = @splat(0),

pub fn init(cart: *Cartridge) Ppu {
    return .{ .cart = cart };
}

pub fn powerOn(self: *Ppu) void {
    self.* = .{ .cart = self.cart };
}

/// Everything the internal reset signal clears: PPUCTRL, PPUMASK, PPUSCROLL,
/// PPUADDR, the shared $2005/$2006 latch and the PPUDATA read buffer, plus
/// the odd-frame flag.
///
/// **`v` is deliberately not cleared.** "Clearing PPUSCROLL and PPUADDR"
/// means clearing `t` and fine X; the VRAM address itself survives a reset.
pub fn reset(self: *Ppu) void {
    self.ctrl = .{};
    // PPUCTRL's bit 7 does not just live in `ctrl`: it is latched into the
    // signal that actually drives /NMI, and clearing the register without
    // clearing that leaves the PPU still asserting NMI from a PPUCTRL that
    // now reads as zero. The next VBlank then fires an NMI into a game that
    // is still in its reset code waiting for its *first* one -- which shows
    // up as one extra frame of drift every time the console is reset.
    self.nmi_output = false;
    // The line and the edge the CPU's detector staged off it go with it;
    // `Cpu.reset` clears its own end of the same latch.
    self.nmi_line = false;
    self.nmi_line_shift = 0;
    self.nmi_edge_pending = false;
    self.mask = .{};
    self.write_latch = false;
    self.t = 0;
    self.fine_x = 0;
    self.read_buffer = 0;
    self.odd_frame = false;
    self.dot = 0;
    self.scanline = 0;
    // The PPU comes out of reset at the top of the picture with its
    // internal reset signal asserted; see `in_reset`.
    self.in_reset = true;
}

fn renderingEnabled(self: *const Ppu) bool {
    return self.mask.show_background or self.mask.show_sprites;
}

/// The address a $2007 access issued right now lands on.
///
/// Not simply `v`: this PPU defers a read's increment of `v` to the state
/// machine's own Read stage, four dots out, because that is where hardware's
/// Read pulse drives it. Reads closer together than that would then all
/// capture the same pre-increment `v` and refetch one address, which is
/// wrong -- hardware increments promptly, so each read in a burst sees the
/// previous one's increment.
///
/// Adding back the increments still in flight reconciles the two. It only
/// ever matters when reads land less than four dots apart, which in practice
/// means a DMC DMA halting the CPU mid-`LDA $2007` and making it repeat the
/// read on the halt, dummy and alignment cycles.
fn dataPortAddress(self: *const Ppu) u16 {
    var pending: u15 = 0;
    for (self.data_sm) |slot| {
        if (slot != null) pending += 1;
    }
    if (pending == 0) return self.v & 0x3FFF;
    // The fetch cadence owns `v` while rendering, where the increment is a
    // coarse-X/fine-Y step rather than a flat add; don't try to predict it.
    if (self.renderingEnabled() and
        (self.scanline < visible_scanlines or self.scanline == prerender_scanline))
    {
        return self.v & 0x3FFF;
    }
    const step: u15 = if (self.ctrl.vram_increment == .add_32) 32 else 1;
    return (self.v +% pending * step) & 0x3FFF;
}

/// Feeds a $2007 read into the state machine. See `data_sm`.
fn armDataRead(self: *Ppu, addr: u16) void {
    for (&self.data_sm) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .age = 0, .addr = addr };
            return;
        }
    }
    // Unreachable in practice (see `data_sm`); retire whichever read is
    // furthest along rather than dropping the new one on the floor.
    var oldest: usize = 0;
    for (self.data_sm, 0..) |slot, i| {
        if (slot.?.age > self.data_sm[oldest].?.age) oldest = i;
    }
    self.data_sm[oldest] = .{ .age = 0, .addr = addr };
}

/// Whether the background/sprite fetch cadence is driving the VRAM bus on
/// the dot about to be ticked. It runs continuously from dot 1 to dot 340
/// of every rendering scanline, alternating address setup and read, and it
/// outranks the PPU DATA state machine on every dot they collide -- the
/// state machine's own address never reaches the bus while it's on.
///
/// (Dot 0 is the odd one out here: this model has no fetch on it, so the
/// state machine is free to use it.)
fn cadenceOwnsBus(self: *const Ppu) bool {
    if (!self.rendering_delayed) return false;
    if (self.scanline >= visible_scanlines and self.scanline != prerender_scanline) return false;
    return self.dot >= 1;
}

/// `nmi_line` as it stood `dots_ago` dots back, with 0 meaning right now,
/// i.e. after this dot's work. See `nmi_line_shift`.
fn lineWasHigh(self: *const Ppu, dots_ago: u3) bool {
    if (dots_ago == 0) return self.nmi_line;
    return (self.nmi_line_shift >> (dots_ago - 1)) & 1 != 0;
}

/// Recomputes the /NMI line, which is combinational: `nmi_enable AND vblank`,
/// and the CPU can change either input mid-dot through $2000 or $2002. So
/// anything touching an input has to refresh the line right away rather than
/// leaving a stale level for the next `tick`.
///
/// That staleness is exactly what NMI suppression hinges on. A $2002 read
/// just after the flag is set pulls the line back up too quickly for the CPU
/// to see it drop, whereas a line held asserted until the next dot boundary
/// would latch an edge hardware never delivers.
fn updateNmiLine(self: *Ppu) void {
    self.nmi_line = self.nmi_output and self.status.vblank;
}

pub fn tick(self: *Ppu) void {
    // Snapshot taken before this dot's work, so what the CPU samples at
    // the end of the 3-dot batch is the line as of the *second* dot. See
    // `nmi_line`.
    self.nmi_line_shift = (self.nmi_line_shift << 1) | @intFromBool(self.nmi_line);

    self.dots_elapsed += 1;

    // Sampled before the pending $2001 write is allowed to land, so this
    // holds the value the previous dot rendered with. See `rendering_delayed`.
    self.rendering_delayed = self.renderingEnabled();

    if (self.pending_v) |value| {
        self.pending_v_delay -= 1;
        if (self.pending_v_delay == 0) {
            self.v = value;
            self.pending_v = null;
            // With rendering off nothing else drives the address pins, so
            // `v` itself is what the cartridge sees. That is the whole way
            // software clocks an MMC3's A12 counter by hand from $2006, and
            // it happens whether or not any $2007 access follows.
            self.cart.mapper.ppuAddressBus(self.v & 0x3FFF, self.dots_elapsed);
        }
    }

    // Runs before the real value's stage below, so a write whose early value
    // lands on the same dot the previous write resolves still sees the
    // ordering hardware would: bus glitch first, latched value after.
    if (self.pending_mask_early) |bus| {
        if (self.mask_early_delay > 0) self.mask_early_delay -= 1;
        if (self.mask_early_delay == 0) {
            // Merged into whatever is latched rather than replacing it: the
            // registered bits still hold the old value during this window,
            // and only the two combinational ones follow the bus.
            self.mask.greyscale = (bus & 0x01) != 0;
            self.mask.emphasize_blue = (bus & 0x80) != 0;
            self.pending_mask_early = null;
        }
    }

    if (self.pending_mask) |m| {
        self.mask_write_delay -= 1;
        if (self.mask_write_delay == 0) {
            self.applyMask(m);
            self.pending_mask = null;
        }
    }

    // What the PPU DATA state machine drives on this dot, and -- when the
    // fetch cadence isn't already holding the bus -- the access it makes
    // with it. Set before `renderTick` so the fetch helpers can see the
    // collision cases; cleared at the end of the dot.
    self.data_sm_phase = .idle;
    for (self.data_sm) |slot| {
        const entry = slot orelse continue;
        // Read outranks ALE if they ever coincide, which needs two reads
        // exactly two dots apart -- closer than the CPU can manage.
        if (entry.age == 4) {
            self.data_sm_phase = .read;
            self.data_sm_addr = entry.addr;
        } else if (entry.age == 2 and self.data_sm_phase == .idle) {
            self.data_sm_phase = .ale;
            self.data_sm_addr = entry.addr;
        }
    }
    if (self.data_sm_phase != .idle and !self.cadenceOwnsBus()) {
        switch (self.data_sm_phase) {
            .ale => self.aleCycle(self.data_sm_addr),
            .read => self.read_buffer = self.busRead(self.data_sm_addr),
            .idle => unreachable,
        }
    }

    if (self.scanline < visible_scanlines or self.scanline == prerender_scanline) {
        self.renderTick();
    }

    // `v` advances off the state machine's own Read pulse, not off the CPU
    // cycle that armed it -- and after this dot's fetch, so the fetch still
    // sees the address the read was issued against. With rendering on that
    // ordering is directly visible: an increment applied even one fetch group
    // early shifts every subsequent fetch by a whole tile.
    if (self.data_sm_phase == .read) self.incrementVramAddress();
    for (&self.data_sm) |*slot| {
        const entry = &(slot.* orelse continue);
        if (entry.age >= 4) slot.* = null else entry.age += 1;
    }
    self.data_sm_phase = .idle;

    if (self.scanline == vblank_start_scanline and self.dot == 1) {
        // A $2002 read that lands on this exact dot races the flag's own
        // set and wins: the CPU reads back 0 *and* the set is cancelled,
        // so the flag stays clear for the whole frame (and, since NMI is
        // just `nmi_enable AND vblank` edge-detected, no NMI fires
        // either). Only this one dot is affected -- a read on dot 0
        // returns 0 and lets the flag set normally, and a read on dot 2
        // sees the flag set and clears it the ordinary way.
        if (!self.suppress_vblank_set) self.status.vblank = true;
    }
    self.suppress_vblank_set = false;
    if (self.scanline == prerender_scanline and self.dot == 1) {
        self.status = .{};
        // Same signal, so the warm-up ends here too.
        self.in_reset = false;
    }
    self.updateNmiLine();
    // Two separate things decide whether an assertion is recognized, and they
    // must not be conflated -- conflating them makes the "enable NMI during
    // VBlank" and "disable NMI during VBlank" cases impossible to satisfy at
    // once:
    //
    //  - *How late* the CPU sees the edge: `nmi_line_delay_dots`.
    //  - *How wide* the pulse has to be to be seen at all: fixed at two
    //    dots. A one-dot pulse -- enabling NMI on the very dot the
    //    pre-render line clears VBlank, or a $2002 read pulling the line
    //    back up right after the flag set drove it low -- is gone again
    //    before the CPU's sampling can latch it.
    //
    // So the persistence check always looks exactly one dot past the
    // rise, wherever the delay puts that rise, rather than looking at the
    // undelayed line (which would silently widen the requirement by one
    // dot for every dot of delay).
    const rose = self.lineWasHigh(nmi_line_delay_dots) and !self.lineWasHigh(nmi_line_delay_dots + 1);
    const still_high = self.lineWasHigh(nmi_line_delay_dots - 1);
    if (rose and still_high) {
        self.nmi_edge_pending = true;
    }

    self.dot += 1;
    // On odd frames, with rendering enabled, the pre-render scanline is
    // one dot short: dot 339 falls straight through to dot 0 of the next
    // frame instead of counting up to dot 340.
    const skip_last_dot = self.scanline == prerender_scanline and self.dot == dots_per_scanline - 1 and
        self.odd_frame and self.renderingEnabled();
    // The dot is skipped, but the read it would have done is not -- it
    // happens on the dot jumped to instead. See `deferred_nt_fetch`.
    if (skip_last_dot) {
        self.deferred_nt_fetch = true;
        self.sprite_shifters_late = true;
    }
    if (self.dot >= dots_per_scanline or skip_last_dot) {
        self.dot = 0;
        self.scanline += 1;
        // Every scanline gets its own scan; 0 means "not started yet", so
        // the next dot in the window begins a fresh one from OAMADDR.
        self.sprite_eval_dot = 0;
        if (self.scanline == visible_scanlines) self.picture += 1;
        if (self.scanline >= scanlines_per_frame) {
            self.scanline = 0;
            self.frame += 1;
            self.odd_frame = !self.odd_frame;
        }
    }
}

/// Runs the background/sprite fetch-and-shift machinery for one dot of a
/// visible or pre-render scanline. Hardware spends two dots on each fetched
/// byte -- one to settle the address, one to read -- but both use the same
/// address, so each fetch happens in one shot on the second dot of its
/// pair. Which dot that is still matters: the pattern high plane lands on
/// `dot % 8 == 0`, and the sliver commit rides on that same dot, so a
/// forced blank that just misses the read also just misses the commit.
fn renderTick(self: *Ppu) void {
    // Two gates, one dot apart -- see `rendering_delayed`. `shifting` is
    // the mask register as of this dot; `fetching` is one register stage
    // behind it.
    const shifting = self.renderingEnabled();
    const fetching = self.rendering_delayed;

    // The read owed by the dot the odd-frame skip swallowed. It lands
    // here, on the dot jumped to, rather than being lost.
    if (self.deferred_nt_fetch) {
        self.deferred_nt_fetch = false;
        if (fetching) self.garbageNametableFetch();
    }
    // The late counter-start pulse covers one dot -- the first visible one
    // -- and then everything runs normally again.
    const shifters_late_expires = self.sprite_shifters_late and self.dot >= 1;

    // A corruption armed by an earlier forced blank resolves on the very
    // first rendering dot of a line that runs sprite evaluation -- which is
    // why a blank opened and closed entirely inside VBlank never corrupts
    // anything, and why one opened mid-frame waits until the pre-render
    // line to bite. See `pending_oam_corruption`.
    if (shifting) {
        if (self.pending_oam_corruption) |seed| {
            self.applyOamCorruption(seed);
            self.pending_oam_corruption = null;
        }
        self.oamBusTick();
    }

    if (self.dot >= 1 and self.dot <= 256) {
        // Order within a dot is "fetch, output, shift, commit". The commit
        // (reload + coarse X) trailing the shift is what puts a freshly
        // fetched tile's leftmost pixel at the top of the register exactly
        // 8 shifts later, so the mux picks it up on the right dot.
        if (fetching) self.fetchCycle();
        if (self.scanline != prerender_scanline) self.outputPixel();
        self.spriteTick(shifting);
        if (shifting) {
            self.shiftRegisters();
            if (self.dot == 256) self.incrementFineY();
        }
        if (fetching) self.commitSliver();
        if (shifters_late_expires) self.sprite_shifters_late = false;
    } else if (self.dot >= 257 and self.dot <= 320) {
        // Each 8-dot sprite slot opens with two "garbage" nametable
        // fetches, before `spriteFetchTick` gets to the pattern reads in
        // the back half of the slot. Nothing consumes what they read, but
        // they're still driven onto the bus, where both the read buffer
        // and A12-edge-counting mappers can see them.
        //
        // Dot 257's ALE runs *before* the horizontal reset below, so the low
        // byte it leaves in the octal latch is the pre-reset one -- which is
        // why the read a dot later lands on a hybrid of old and new `v`.
        if (fetching and (self.dot % 8 == 1 or self.dot % 8 == 3)) self.aleCycle(self.nametableAddress());
        if (self.dot == 257 and shifting) self.v = (self.v & ~@as(u15, 0x041F)) | (self.t & 0x041F);
        // Real hardware holds OAMADDR at 0 through this whole window.
        // Continuously forcing it (not just once at dot 257) matters for
        // any game/test that writes $2003 mid-scanline -- e.g. as a side
        // effect of an OAM DMA triggered while rendering was left enabled
        // from an earlier unrelated write, which would otherwise land
        // sprite data at the wrong OAM offset.
        if (fetching) {
            self.oam_addr = 0;
            self.spriteFetchTick();
        }
        if (self.scanline == prerender_scanline and self.dot >= 280 and self.dot <= 304 and shifting) {
            self.v = (self.v & ~@as(u15, 0x7BE0)) | (self.t & 0x7BE0);
        }
        if (fetching and (self.dot % 8 == 2 or self.dot % 8 == 4)) self.garbageNametableFetch();
    } else if (self.dot >= 321 and self.dot <= 336) {
        if (fetching) self.fetchCycle();
        if (shifting) self.shiftRegisters();
        if (fetching) self.commitSliver();
    }
    // Dots 337-340: two more nametable fetches, both of the same byte the
    // next scanline will start by fetching.
    else if (self.dot >= 337 and self.dot <= 340) {
        if (fetching and (self.dot == 337 or self.dot == 339)) self.aleCycle(self.nametableAddress());
        if (fetching and (self.dot == 338 or self.dot == 340)) self.garbageNametableFetch();
        // Dot 339 is where hardware kicks every sprite slot back into
        // "counting" for the upcoming scanline. Under a forced blank that
        // pulse never arrives and the slots stay halted -- and a halted
        // slot draws from its very first dot, so every sprite behaves as
        // if its X were 0 no matter what the fetch loaded. Clearing the
        // counters expresses the same thing in this model, since "halted"
        // here just means "counter is zero".
        if (self.dot == 339 and !shifting) self.sprite_counter = @splat(0);
    }
}

/// One dot of the sprite counter/shifter machinery, run on dots 1-256 of
/// visible and pre-render lines. Each slot does exactly one of two things:
/// count down toward its X position, or -- once parked at zero -- shift a
/// pixel out. Only the shift is gated by rendering; the countdown keeps
/// going through a forced blank, which is why a sprite still lands at the X
/// it was loaded with even when rendering was off for part of the scanline.
fn spriteTick(self: *Ppu, shifting: bool) void {
    // The dot the odd-frame skip swallowed also delays the counters' start
    // pulse, so on this one dot nothing counts down and every slot draws.
    // See `sprite_shifters_late`.
    if (self.sprite_shifters_late) {
        if (shifting) {
            for (0..8) |i| {
                self.sprite_shift_lo[i] <<= 1;
                self.sprite_shift_hi[i] <<= 1;
            }
        }
        return;
    }
    for (0..8) |i| {
        if (self.sprite_counter[i] != 0) {
            self.sprite_counter[i] -= 1;
        } else if (shifting) {
            self.sprite_shift_lo[i] <<= 1;
            self.sprite_shift_hi[i] <<= 1;
        }
    }
}

/// Real hardware's "sliver commit": at the end of the dot whose pattern
/// high-plane read just completed, the four latches are transferred into
/// the low halves of the shift registers and coarse X advances to the next
/// tile. Both halves are one event driven by one signal, so a forced blank
/// that suppresses the fetch suppresses the reload with it -- the shift
/// registers then keep shifting (they're on the other gate) without ever
/// being refilled, which is what "BG Serial In" is built on.
fn commitSliver(self: *Ppu) void {
    if (self.dot % 8 != 0) return;
    self.reloadShiftersFromLatches();
    self.incrementCoarseX();
}

/// A nametable read that exists only to occupy the bus -- the sprite-fetch
/// window (dots 257-320) and the tail of the scanline (337-340) both make
/// them. The value lands in `nt_latch` exactly as a real fetch would; the
/// next real fetch at dot 2 (or 322) overwrites it before anything reads
/// it, so background output is unaffected.
fn garbageNametableFetch(self: *Ppu) void {
    self.nt_latch = self.busRead(self.nametableAddress());
}

/// First dot of a VRAM access: the PPU drives all 14 address bits and the
/// cartridge's octal latch captures the low 8. See `octal_latch`.
fn aleCycle(self: *Ppu, addr: u16) void {
    self.cart.mapper.ppuAddressBus(addr, self.dots_elapsed);
    if (self.data_sm_phase == .read) {
        // ALE and Read asserted together. The latch is transparent while
        // memory is driving those same eight pins, so instead of taking
        // the address it chases the data -- an analog feedback loop
        // (latch <- memory[high | latch]) that only settles when it hits
        // a fixed point. Not every starting value settles; the ones that
        // oscillate have no defined result on hardware either.
        var latch = self.vram_data_bus;
        for (0..8) |_| {
            const byte = self.readVram((addr & 0x3F00) | latch);
            if (byte == latch) break;
            latch = byte;
        }
        self.octal_latch = latch;
        // The Read line is the state machine's, so what the loop settled
        // on is what reaches the read buffer.
        self.vram_data_bus = self.readVram((addr & 0x3F00) | latch);
        self.read_buffer = self.vram_data_bus;
        return;
    }
    self.octal_latch = @truncate(addr);
}

/// Second dot of a VRAM access. Only `addr`'s upper 6 bits are used -- the
/// low 8 come out of the octal latch, whatever the dot before it left
/// there.
fn busRead(self: *Ppu, addr: u16) u8 {
    const a = (addr & 0x3F00) | self.octal_latch;
    self.cart.mapper.ppuAddressBus(a, self.dots_elapsed);
    self.vram_data_bus = self.readVram(a);
    // Read asserted by both the fetch cadence and the state machine: one
    // read, one value, and it lands in both places.
    if (self.data_sm_phase == .read) self.read_buffer = self.vram_data_bus;
    return self.vram_data_bus;
}

fn nametableAddress(self: *const Ppu) u16 {
    return 0x2000 | (self.v & 0x0FFF);
}

fn attributeAddress(self: *const Ppu) u16 {
    return 0x23C0 | (self.v & 0x0C00) | ((self.v >> 4) & 0x38) | ((self.v >> 2) & 0x07);
}

/// One dot of the background fetch cadence. Odd dots set the address up
/// (ALE), even dots read; both halves recompute the address from `v`,
/// which is what makes a mid-fetch change to `v` produce a hybrid address.
fn fetchCycle(self: *Ppu) void {
    switch (self.dot % 8) {
        1 => self.aleCycle(self.nametableAddress()),
        2 => self.nt_latch = self.busRead(self.nametableAddress()),
        3 => self.aleCycle(self.attributeAddress()),
        4 => {
            const byte = self.busRead(self.attributeAddress());
            // The quadrant select depends on this tile's coarse X/Y, so
            // it must be computed from `v` *now* (while it still points
            // at this tile) rather than later at commit time: coarse X
            // gets incremented at the end of this same 8-dot fetch group,
            // by which point `v` would already be pointing one tile ahead.
            const shift: u3 = @truncate(((self.v >> 4) & 0x04) | (self.v & 0x02));
            self.next_attr_bits = @truncate((byte >> shift) & 0x03);
        },
        5 => self.aleCycle(self.bgPatternAddress(self.nt_latch, 0)),
        6 => self.bg_lo_latch = self.busRead(self.bgPatternAddress(self.nt_latch, 0)),
        7 => self.aleCycle(self.bgPatternAddress(self.nt_latch, 8)),
        // The high-plane read closes the group; `commitSliver` runs at the
        // end of this same dot, gated by the same signal, so a suppressed
        // fetch is exactly a suppressed reload.
        0 => self.bg_hi_latch = self.busRead(self.bgPatternAddress(self.nt_latch, 8)),
        else => unreachable,
    }
}

fn bgPatternAddress(self: *Ppu, tile: u8, plane_offset: u16) u16 {
    const table: u16 = if (self.ctrl.background_pattern_table == .at_1000) 0x1000 else 0;
    const fine_y: u16 = (self.v >> 12) & 0x07;
    return table + (@as(u16, tile) * 16) + fine_y + plane_offset;
}

fn incrementCoarseX(self: *Ppu) void {
    if ((self.v & 0x001F) == 31) {
        self.v &= ~@as(u15, 0x001F);
        self.v ^= 0x0400;
    } else {
        self.v += 1;
    }
}

fn incrementFineY(self: *Ppu) void {
    if ((self.v & 0x7000) != 0x7000) {
        self.v += 0x1000;
        return;
    }
    self.v &= ~@as(u15, 0x7000);
    var y: u15 = (self.v & 0x03E0) >> 5;
    if (y == 29) {
        y = 0;
        self.v ^= 0x0800;
    } else if (y == 31) {
        y = 0;
    } else {
        y += 1;
    }
    self.v = (self.v & ~@as(u15, 0x03E0)) | (y << 5);
}

/// Whether rendering's address hardware is active on this dot at all.
fn renderOwnsV(self: *const Ppu) bool {
    return self.renderingEnabled() and
        (self.scanline < visible_scanlines or self.scanline == prerender_scanline);
}

fn reloadShiftersFromLatches(self: *Ppu) void {
    self.bg_shift_lo = (self.bg_shift_lo & 0xFF00) | self.bg_lo_latch;
    self.bg_shift_hi = (self.bg_shift_hi & 0xFF00) | self.bg_hi_latch;
    // Attribute bits cover the whole tile, so both attribute shift
    // registers get 8 copies of the same bit -- reusing the pattern
    // shifters' bit-selection logic for free. `next_attr_bits` was
    // already resolved at fetch time (see fetchCycle's dot%8==4 case).
    const bits = self.next_attr_bits;
    self.bg_attr_latch = bits;
    self.bg_attr_shift_lo = (self.bg_attr_shift_lo & 0xFF00) | (if (bits & 1 != 0) @as(u16, 0xFF) else 0);
    self.bg_attr_shift_hi = (self.bg_attr_shift_hi & 0xFF00) | (if (bits & 2 != 0) @as(u16, 0xFF) else 0);
}

fn shiftRegisters(self: *Ppu) void {
    // Real hardware's shift registers don't shift in zeroes: the low
    // bitplane's serial input is tied to logical 0 (a no-op against plain
    // `<<`), the high bitplane's is tied to logical 1, and the attribute
    // pair's are tied to the attribute latch. Only observable when
    // rendering is toggled mid-tile so a register goes many dots without a
    // fresh commit -- which precisely timed $2001 writes can arrange, drawing
    // a pattern out of a nametable made entirely of blank tiles.
    self.bg_shift_lo <<= 1;
    self.bg_shift_hi = (self.bg_shift_hi << 1) | 1;
    self.bg_attr_shift_lo = (self.bg_attr_shift_lo << 1) | (self.bg_attr_latch & 1);
    self.bg_attr_shift_hi = (self.bg_attr_shift_hi << 1) | (self.bg_attr_latch >> 1);
}

// --- Sprites -------------------------------------------------------------

fn spriteHeight(self: *const Ppu) u16 {
    return if (self.ctrl.sprite_size == .size_8x16) 16 else 8;
}

/// The scanline value the sprite in-range check compares OAM Y
/// coordinates against. Sprites are always prepared for the *next*
/// scanline. For visible lines that's `self.scanline + 1`, and since OAM
/// Y coordinates are themselves stored as "one less than" a sprite's
/// first displayed row, `(scanline + 1) - y - 1` collapses to plain
/// `scanline - y`.
///
/// Pre-render doesn't get the same cancellation (the next scanline is 0
/// of the *next frame*, not `prerender_scanline + 1`) -- and it isn't
/// "scanline -1" either. The internal counter feeding this comparison is
/// narrower than needed to hold 261, so it wraps: `261 & 0xFF` is 5, and the
/// pre-render line range-checks as if it *were* scanline 5. Note
/// this only applies to the fetch stage (dots 257-320) --
/// `tickSpriteEval` never runs on the pre-render line at all, so the
/// entries being range-checked there are the stale ones left over from
/// scanline 239. That combination is exactly what lets a sprite show up
/// on scanline 0, drawn from pattern row 5 of whatever tile the stale entry
/// names.
fn spriteReferenceLine(self: *const Ppu) i32 {
    return if (self.scanline == prerender_scanline) @as(i32, prerender_scanline) & 0xFF else self.scanline;
}

/// Advances the OAM buffer and secondary OAM's address counter by one dot.
///
/// Between them these two are the entire CPU-visible face of the sprite
/// hardware: `$2004` reads hand back the buffer, and the address counter is
/// the seed OAM corruption uses. The scanline splits into four regimes:
///
///   | dots    | what drives the pair                                    |
///   |---------|---------------------------------------------------------|
///   | 1-64    | secondary OAM clear: buffer forced to $FF, address       |
///   |         | stepping one slot every two dots, 0 through $1F         |
///   | 65-256  | sprite evaluation, stepped one dot at a time by           |
///   |         | `tickSpriteEval`                                         |
///   | 257-320 | sprite fetch: four reads per slot, the last held for     |
///   |         | five dots, so the address advances 4 per 8-dot slot      |
///   | 321-340 | idle. Eight slots' worth of advancing has taken the      |
///   |         | 5-bit address exactly back to 0, so these dots (and dot  |
///   |         | 0, which inherits from them) sit on slot 0 -- a seed of  |
///   |         | 0 makes OAM corruption copy row 0 onto itself, which is  |
///   |         | the wide safe window games rely on to turn rendering off |
fn oamBusTick(self: *Ppu) void {
    // Dot 0 has no driver of its own: both carry over from dot 340 of the
    // line before, which is where the "previous scanline's secondary OAM
    // slot 0" a $2004 read there hands back comes from.
    if (self.dot == 0) return;

    // The evaluation window is the one regime driven by a running state
    // machine rather than a formula, so it advances here -- and only here,
    // which is what makes a forced blank stop the scan where it stands
    // instead of letting it finish in the background.
    if (self.dot >= eval_window_start and self.dot <= 256) {
        // Evaluation doesn't run at all on the pre-render line, so
        // secondary OAM survives untouched from scanline 239's scan (or
        // from whenever rendering was last disabled) and is what the
        // pre-render sprite fetch picks up.
        if (self.scanline == prerender_scanline) {
            // Evaluation itself is disabled here, but the OAM refresh that
            // *starts* a frame's rendering still runs -- and drags a row of
            // OAM over the first one when OAMADDR isn't 0.
            if (self.dot == eval_window_start) self.applyOamRefreshBug();
        } else {
            self.sprite_eval = self.tickSpriteEval(self.spriteEvalBefore(), self.dot, true);
            self.sprite_eval_dot = self.dot;
            if (self.sprite_eval.overflow_hit) self.status.sprite_overflow = true;
            self.secondary_oam_has_sprite0 = self.sprite_eval.has_sprite0;
        }
    } else if (self.dot >= 1 and self.dot <= 64 and self.scanline != prerender_scanline) {
        // Dots 1-64 blank secondary OAM to $FF, two dots per slot.
        self.secondary_oam[@intCast((self.dot - 1) / 2)] = 0xFF;
    }

    self.oam_buffer = self.oamBufferForDot(self.dot);
    self.oam2_addr = self.oam2AddrForDot(self.dot);
}

/// Secondary OAM's address counter as of `d`. Written as a function of the
/// dot rather than as a running counter because both consumers ask about a
/// dot the PPU hasn't ticked yet: a `$2004` read is dispatched before the
/// dot it lands on runs, and a $2001 write that kills rendering freezes the
/// counter at the value the dot it lands on already carries.
///
/// ## Why there is no extra increment on dot 321
///
/// Hardware clears this counter outright on dots 63, 255 and 339, and is
/// described as taking an *extra* increment at the start of dot 321 on top of
/// the 32 the fetch window makes. Writing it as a function of the dot already
/// reproduces all three clears -- each regime below starts from 0 regardless
/// of what the one before it left -- but the extra increment is a real
/// difference, and it is deliberately absent.
///
/// It is absent because it is not observable *and* contradicts the one
/// measurement available. The extra increment would put this at 1 for dots
/// 321-338 and 0 only for 339-340, but AccuracyCoin's `$2004 Stress Test`
/// answer key reads `$2004` on all 341 dots of a scanline and requires
/// secondary OAM slot **0** on every one of dots 321-340 -- slot 1 there holds
/// a different byte, and putting the increment in fails two of its subtests.
/// The other channel it could show up in is the OAM corruption seed, and a
/// seed of 1 rather than 0 would make dots 321-338 unsafe to disable rendering
/// on -- the opposite of the wide safe window those dots are known for.
fn oam2AddrForDot(self: *Ppu, d: u16) u8 {
    if (d == 0) return 0;
    if (d <= 64) return @intCast((d - 1) / 2);
    if (d <= 256) return self.spriteEvalAt(d).oam2_addr;
    if (d <= 320) {
        // Y, tile and attribute each get their own dot of the slot; X is
        // re-read on the remaining four while the pattern fetches happen,
        // so the address advances 4 per slot and 32 across the window --
        // exactly back to 0, with nothing left over for dots 321-340.
        const slot = (d - 257) / 8;
        const phase = (d - 257) % 8;
        return @intCast((slot * 4 + @min(phase, 3)) & 0x1F);
    }
    return 0;
}

fn oamBufferForDot(self: *Ppu, d: u16) u8 {
    if (d == 0) return self.oam_buffer;
    if (d <= 64) return 0xFF;
    if (d <= 256) return self.spriteEvalAt(d).buffer;
    if (d <= 320) return self.secondary_oam[self.oam2AddrForDot(d)];
    return self.secondary_oam[0];
}

/// The seed a forced blank landing on the current dot leaves behind.
///
/// Mid-evaluation the address counter can be parked anywhere, but the
/// corruption only ever lands on a 4-byte boundary -- hardware rounds *up*
/// -- so dots 65-256 can only ever corrupt rows 0, 4, 8, ... 28.
fn oamCorruptionSeed(self: *Ppu) u8 {
    const d = @min(self.dot + oam_corruption_seed_delay, dots_per_scanline - 1);
    const addr = self.oam2AddrForDot(d);
    if (d >= eval_window_start and d <= 256 and addr % 4 != 0) {
        return (addr + 4) & 0x1C;
    }
    return addr & 0x1F;
}

/// Lands a value in the mask register, arming OAM corruption if this is the
/// edge that takes rendering away mid-line.
///
/// Rendering going away mid-line is what arms the corruption: secondary OAM's
/// address counter freezes wherever the scan had got to, and that frozen
/// value is the seed. Only the *first* such disable counts -- an already
/// pending corruption isn't re-seeded, because nothing has resolved it yet.
///
/// **Early writes come through here too** (see `pending_mask_early`), which
/// is deliberate: a $2001 write that re-asserts the value already in the
/// register still drops rendering for the one dot the open-bus value is
/// latched, and hardware arms the corruption on that edge like any other.
fn applyMask(self: *Ppu, m: Mask) void {
    self.mask = m;
    if (self.rendering_delayed and !self.renderingEnabled() and
        self.pending_oam_corruption == null and
        (self.scanline < visible_scanlines or self.scanline == prerender_scanline))
    {
        self.pending_oam_corruption = self.oamCorruptionSeed();
    }
}

/// The OAM hardware refresh bug: starting sprite evaluation with OAMADDR
/// somewhere other than 0 copies the 8 bytes beginning at `OAMADDR & $F8`
/// over OAM's first 8 bytes.
///
/// **This is not `applyOamCorruption`.** That one is the forced-blank case,
/// and it copies in the opposite direction: row 0 *onto* the row the address
/// counter names. Both are real, and they are separate mechanisms.
///
/// **Fires once per frame, on the pre-render line, not at every scanline's
/// evaluation.** The distinction is observable: software that sets OAMADDR to
/// $80 while rendering is already on, to make sprite 32 act as sprite 0, must
/// not find sprite 32 copied into sprite 0 on the following frame. What the
/// bug does catch is software that writes $2003 and *then* turns rendering
/// on, which is why some games fail to boot without it.
///
/// Masking with $F8 makes any OAMADDR below 8 a self-copy, so "not zero" and
/// "eight or greater" describe the same observable behavior.
fn applyOamRefreshBug(self: *Ppu) void {
    const row: u8 = self.oam_addr & 0xF8;
    if (row == 0) return;
    for (0..8) |i| self.oam[i] = self.oam[row + i];
}

/// Copies OAM row 0 over row `seed`, eight bytes at a time, plus slot 0 of
/// secondary OAM over slot `seed`. A seed of 0 is a no-op by construction.
fn applyOamCorruption(self: *Ppu, seed: u8) void {
    const row = @as(u16, seed & 0x1F) * 8;
    for (0..8) |i| self.oam[row + i] = self.oam[i];
    self.secondary_oam[seed & 0x1F] = self.secondary_oam[0];
}

/// Runs hardware's sprite-evaluation state machine for a single dot of the
/// 65-256 window, returning the state afterwards. Across the whole window
/// this is what populates secondary OAM for the *next* scanline.
///
/// Modelled as hardware's own byte-at-a-time address walk rather than as a
/// loop over 64 aligned sprites, because OAMADDR -- and therefore which byte
/// is read as a Y coordinate -- does not have to start on a sprite boundary:
/// a non-multiple-of-4 written to $2003 in the narrow window between the dot
/// 257-320 reset and the next scan makes every sprite record straddle its
/// neighbours' bytes.
///
/// Pure with respect to `Ppu` apart from `secondary_oam`, which it writes
/// only when `commit` is set -- that is what lets `spriteEvalAt` run a
/// throwaway copy one dot into the future without disturbing anything.
///
/// Three details, all of them visible to software reading $2004 dot by dot
/// across the evaluation window:
///
///   * The buffer is written to secondary OAM even for a sprite that turns
///     out to be off this scanline -- what makes it "not selected" is that
///     the address doesn't advance, so the next candidate overwrites it.
///     The last such reject is therefore still sitting in the first free
///     slot when the scan ends, in place of the $FF the clear left there.
///     That one leftover byte does escape into the sprite pipeline, on the
///     pre-render line: evaluation is skipped there, so the fetch stage
///     range-checks whatever scanline 239 left behind (see
///     `spriteReferenceLine`).
///   * Once secondary OAM is full its write port is dead, and the even-dot
///     write turns into a *read* -- the buffer comes back loaded with
///     `secondary_oam[oam2_addr]` instead of keeping what primary OAM just
///     put there. So the CPU sees the two memories alternating.
///   * When the sprite counter wraps past 63 the scan doesn't stop; it
///     drops into a final state that re-reads Y bytes at 4-byte strides
///     forever (and never selects anything) until the fetch window takes
///     over at dot 257.
fn tickSpriteEval(self: *Ppu, prev: SpriteEval, dot: u16, commit: bool) SpriteEval {
    var e = prev;
    e.overflow_hit = false;

    // --- odd dot: primary OAM into the buffer -------------------------
    if (dot % 2 == 1) {
        e.buffer = self.oam[e.addr];
        // Latched now, range-checked on the even dot that follows.
        e.y = e.buffer;
        return e;
    }

    // Whether the byte the odd dot read counts as a Y coordinate landing
    // on the scanline being prepared. Only meaningful when the machine is
    // between sprites (`copy_left == 0`). Height and reference line are
    // read live rather than latched at the start of the scan, so a $2000
    // write mid-window changes the answer from here on -- which is what
    // `5.Emulator` test 5 checks.
    const row = self.spriteReferenceLine() - @as(i32, e.y);
    const in_range = row >= 0 and row < self.spriteHeight();

    // --- even dot: the buffer into secondary OAM, or, when that write
    //     can't land, secondary OAM back into the buffer ---------------
    if (e.phase == .scan) {
        if (commit) self.secondary_oam[e.oam2_addr] = e.buffer;
    } else {
        e.buffer = self.secondary_oam[e.oam2_addr];
    }

    switch (e.phase) {
        .scan => {
            if (e.copy_left > 0) {
                e.copy_left -= 1;
                e.oam2_addr += 1;
                e.addr +%= 1;
                if (e.copy_left == 0) e.n += 1;
            } else if (in_range) {
                if (e.n == 0) e.has_sprite0 = true;
                e.copy_left = 3;
                e.oam2_addr += 1;
                e.addr +%= 1;
            } else {
                // Only the Y byte is read for a rejected sprite; the scan
                // then skips to the next 4-byte-aligned entry, which is
                // what re-aligns a misaligned scan.
                e.addr = (e.addr +% 4) & 0xFC;
                e.n += 1;
            }
            if (e.oam2_addr == 32) {
                // The address is 5 bits wide, so filling secondary OAM
                // wraps it back to 0 -- which is why the reads that
                // replace the dead writes from here on all come from
                // slot 0.
                e.oam2_addr = 0;
                e.full = true;
            }
            if (e.n == 64) {
                e.phase = .done;
                e.addr &= 0xFC;
            } else if (e.full) e.phase = .overflow;
        },
        .overflow => {
            if (e.copy_left > 0) {
                e.copy_left -= 1;
                e.addr +%= 1;
                // The three bytes trailing an overflow hit are read but
                // have nowhere to go; afterwards the machine gives up on
                // selection entirely rather than resuming the scan.
                if (e.copy_left == 0) {
                    e.phase = .done;
                    e.addr &= 0xFC;
                }
            } else if (in_range) {
                // The 9th sprite: the overflow flag's moment, reported on
                // this exact dot rather than at the end of the window.
                e.overflow_hit = true;
                e.copy_left = 3;
                e.addr +%= 1;
            } else {
                // The overflow-detection bug: a miss here increments
                // *both* halves of the address, and m is a 2-bit counter
                // that wraps 3->0 without carrying into n. With OAMADDR
                // being 4n+m that works out to +5 three times out of four
                // and +1 on the wrap, so the scan drifts one byte per
                // sprite and stays inside OAM for the whole sweep. A flat
                // +5 instead drifts a full sprite every 4 checks and wraps
                // back into the low entries, where it re-finds the very
                // sprites that filled secondary OAM and sets overflow on a
                // scanline that has exactly 8.
                e.addr = if (e.addr & 0x03 == 3) e.addr +% 1 else e.addr +% 5;
                e.n += 1;
                if (e.n == 64) {
                    e.phase = .done;
                    e.addr &= 0xFC;
                }
            }
        },
        // The terminal state reads one Y byte per entry and advances a
        // whole entry each time, wrapping through OAM indefinitely.
        .done => e.addr = (e.addr & 0xFC) +% 4,
    }
    return e;
}

/// The evaluation state as of `d`, which may be one dot ahead of what has
/// actually been ticked.
///
/// Both CPU-facing consumers ask about a dot the PPU hasn't run yet: a
/// `$2004` read is dispatched before the dot it lands on, and so is the
/// `$2002` read that has to see the overflow flag on the very dot the scan
/// finds the 9th sprite. Stepping a throwaway copy is what answers them
/// without the state machine having to run ahead of everything else.
fn spriteEvalAt(self: *Ppu, d: u16) SpriteEval {
    if (d < eval_window_start or d > 256) return self.sprite_eval;
    if (self.sprite_eval_dot != 0 and d <= self.sprite_eval_dot) return self.sprite_eval;
    return self.tickSpriteEval(self.spriteEvalBefore(), d, false);
}

/// The state a not-yet-run dot of the window starts from.
///
/// A fresh scan begins at the first dot of the window the PPU actually
/// evaluates -- normally dot 65, but later if rendering was off then. Its
/// starting OAM address is OAMADDR, which is usually 0 (forced every
/// scanline -- see the dot 257-320 handling in `renderTick`) but which a
/// game/test can move by writing $2003 in the window before this scan.
/// "Sprite zero" for hit-testing purposes isn't literally OAM index 0:
/// it's whichever entry gets examined *first* in this scan order, i.e. the
/// one at OAMADDR. If that first entry isn't in range, there's no sprite
/// zero this scanline at all, even if a later entry in the scan gets added
/// to secondary OAM.
fn spriteEvalBefore(self: *const Ppu) SpriteEval {
    if (self.sprite_eval_dot == 0) return .{ .addr = self.oam_addr };
    return self.sprite_eval;
}

/// One dot of the sprite fetch pipeline (dots 257-320), which fills the
/// counters and shift registers `outputPixel` reads on the *next* scanline
/// from the entries `tickSpriteEval` put in secondary OAM.
///
/// Hardware gives each of the eight slots its own 8-dot window and loads a
/// different piece of the slot on each dot of it -- attribute, then X
/// counter, then the two pattern planes -- with every one of those loads
/// gated by the fetch-side enable. So this can't run as one shot at dot
/// 257: rendering switched off partway through a window leaves the slot
/// half-updated, still holding the previous scanline's counter and pattern
/// bits -- which is what disabling rendering partway through the window is
/// used for.
fn spriteFetchTick(self: *Ppu) void {
    const slot: usize = (self.dot - 257) / 8;
    const phase = (self.dot - 257) % 8;
    // Sprite 0's presence is settled for the whole line as the window opens.
    if (self.dot == 257) self.sprite0_present = self.secondary_oam_has_sprite0;
    if (phase < 3) return;

    const y = self.secondary_oam[slot * 4 + 0];
    const tile = self.secondary_oam[slot * 4 + 1];
    const attr = self.secondary_oam[slot * 4 + 2];
    if (phase == 3) {
        self.sprite_attr[slot] = attr;
        return;
    }
    if (phase == 4) self.sprite_counter[slot] = self.secondary_oam[slot * 4 + 3];

    // The fetch stage re-runs the in-range check rather than trusting that
    // everything in secondary OAM belongs on the upcoming line. After a
    // normal evaluation that's redundant (evaluation only ever stores
    // in-range sprites), but on the pre-render line -- where evaluation is
    // skipped entirely -- secondary OAM is stale, and this check against
    // line 5 is the *only* thing deciding which of those leftovers reach
    // the shift registers. Out-of-range slots get transparent pattern
    // data, exactly as hardware does for the dummy $FF entries.
    const reference_line = self.spriteReferenceLine();
    const height = self.spriteHeight();
    const r = reference_line - @as(i32, y);
    const in_range = r >= 0 and r < height;

    // Hardware has no way to *skip* a fetch it has already committed the
    // bus to: an out-of-range slot still drives an address and still
    // reads, it just does so with the row counter parked at garbage. That
    // read is invisible in the shift registers (which are forced
    // transparent below) but very much visible on the bus, which is what
    // the sprite-fetch half of the "$2007 Stress Test" answer key is
    // reading back. Masking the row keeps the address inside the tile.
    const row: u16 = if (in_range) blk: {
        var v: u16 = @intCast(r);
        if ((attr & 0x80) != 0) v = height - 1 - v; // vertical flip
        break :blk v;
    } else @as(u16, @truncate(@as(u32, @bitCast(r)))) & (height - 1);

    const base = if (self.ctrl.sprite_size == .size_8x16)
        (@as(u16, tile & 0x01) * 0x1000) + (@as(u16, tile & 0xFE) * 16) + row + (if (row >= 8) @as(u16, 8) else 0)
    else
        (if (self.ctrl.sprite_pattern_table == .at_1000) @as(u16, 0x1000) else 0) + (@as(u16, tile) * 16) + row;
    const addr = if (phase <= 5) base else base + 8;

    if (phase == 4 or phase == 6) {
        self.aleCycle(addr);
        return;
    }
    var plane = self.busRead(addr);
    if (!in_range) plane = 0;
    if ((attr & 0x40) != 0) plane = reverseBits(plane); // horizontal flip
    if (phase == 5) self.sprite_shift_lo[slot] = plane else self.sprite_shift_hi[slot] = plane;
}

/// The `$2004` write behavior, shared with OAM DMA.
///
/// While rendering, OAM is busy with sprite evaluation and the write never
/// reaches it. What it *does* do is disturb the address counter: OAMADDR
/// jumps to the next sprite boundary (+4, realigned) instead of advancing
/// by one byte: OAM keeps its old contents, and the address lands on
/// `(addr + 4) & $FC`.
///
/// **OAM DMA goes through this too**, because $4014 transfers are literally
/// writes to $2004. A DMA fired with rendering left on therefore does not
/// rewrite sprites mid-screen; it only scrambles OAMADDR.
///
/// Deliberately *not* `writeRegister(4)`: a CPU register write also refreshes
/// the PPU I/O latch, whereas a DMA put drives the CPU's own buses instead
/// (which `Dma` handles). Whether a DMA put also refreshes the PPU latch on
/// hardware is not modelled either way.
pub fn writeOamData(self: *Ppu, value: u8) void {
    if (self.renderingEnabled() and
        (self.scanline < visible_scanlines or self.scanline == prerender_scanline))
    {
        self.oam_addr = (self.oam_addr +% 4) & 0xFC;
        return;
    }
    self.writeOam(self.oam_addr, value);
    self.oam_addr +%= 1;
}

/// Stores a byte into OAM. Byte 2 of each sprite (the attribute byte) only
/// has five real bits behind it -- bits 4-2 have no storage at all, so they
/// always read back as 0 no matter what was written. Filling OAM with $FF
/// therefore leaves every attribute byte reading $E3.
pub fn writeOam(self: *Ppu, addr: u8, value: u8) void {
    self.oam[addr] = if (addr % 4 == 2) value & 0xE3 else value;
}

fn reverseBits(value: u8) u8 {
    var v = value;
    v = (v & 0xF0) >> 4 | (v & 0x0F) << 4;
    v = (v & 0xCC) >> 2 | (v & 0x33) << 2;
    v = (v & 0xAA) >> 1 | (v & 0x55) << 1;
    return v;
}

// --- Pixel compositing ---------------------------------------------------

/// Whether a sprite 0 hit would be flagged on `dot`, which must be at or
/// after the current one. Used only by `$2002` reads, which sample the sprite
/// flags at the end of the read rather than its start.
///
/// The background bits are already sitting in the shift registers, just
/// `dot - self.dot` positions further down, so no simulation is needed. The
/// sprite side is only answered for the current dot: reporting a future one
/// would need the counters and shifters stepped forward too.
fn hitWouldOccurAt(self: *const Ppu, dot: u16) bool {
    if (self.status.sprite0_hit) return true;
    if (dot < 1 or dot > 256) return false;
    if (self.scanline >= visible_scanlines) return false;
    if (!self.renderingEnabled()) return false;
    if (!self.mask.show_background or !self.mask.show_sprites) return false;

    const ahead = dot - self.dot;
    if (ahead > 7) return false; // beyond what's still in the register
    const x = dot - 1;
    if (x == 255) return false;

    const shift: u4 = @intCast(@as(u16, 15 - @as(u16, self.fine_x)) - ahead);
    if (x < 8 and !self.mask.show_background_left) return false;
    const bg_hi: u2 = @truncate((self.bg_shift_hi >> shift) & 1);
    const bg_lo: u2 = @truncate((self.bg_shift_lo >> shift) & 1);
    if ((bg_hi << 1 | bg_lo) == 0) return false;

    if (x < 8 and !self.mask.show_sprites_left) return false;
    if (!self.sprite0_present or self.sprite_counter[0] != 0) return false;
    const s_lo: u2 = @truncate((self.sprite_shift_lo[0] >> 7) & 1);
    const s_hi: u2 = @truncate((self.sprite_shift_hi[0] >> 7) & 1);
    return (s_hi << 1 | s_lo) != 0;
}

fn outputPixel(self: *Ppu) void {
    const x = self.dot - 1;

    var bg_index: u2 = 0;
    var bg_palette: u2 = 0;
    if (self.mask.show_background and (x >= 8 or self.mask.show_background_left)) {
        const bit: u4 = 15 - @as(u4, self.fine_x);
        bg_index = @as(u2, @truncate((self.bg_shift_hi >> bit) & 1)) << 1 | @as(u2, @truncate((self.bg_shift_lo >> bit) & 1));
        bg_palette = @as(u2, @truncate((self.bg_attr_shift_hi >> bit) & 1)) << 1 | @as(u2, @truncate((self.bg_attr_shift_lo >> bit) & 1));
    }

    var sprite_index: u2 = 0;
    var sprite_palette: u2 = 0;
    var sprite_in_front = false;
    var sprite_zero_hit_candidate = false;
    if (self.mask.show_sprites and (x >= 8 or self.mask.show_sprites_left)) {
        // All eight slots, not just the ones the last evaluation filled:
        // unused slots hold transparent pattern data, and a slot whose
        // fetch window was skipped by a forced blank keeps last
        // scanline's -- which is the point of "Stale Sprite Shift
        // Registers" test 6.
        for (0..8) |i| {
            // On the dot after an odd-frame skip every shifter emits its
            // first pixel regardless of X; see `sprite_shifters_late`.
            if (self.sprite_counter[i] != 0 and !self.sprite_shifters_late) continue;
            const lo: u2 = @truncate((self.sprite_shift_lo[i] >> 7) & 1);
            const hi: u2 = @truncate((self.sprite_shift_hi[i] >> 7) & 1);
            const idx = (hi << 1) | lo;
            if (idx == 0) continue; // transparent pixel of this sprite; keep scanning lower-priority sprites

            sprite_index = idx;
            sprite_palette = @truncate(self.sprite_attr[i] & 0x03);
            sprite_in_front = (self.sprite_attr[i] & 0x20) == 0;
            sprite_zero_hit_candidate = self.sprite0_present and i == 0;
            break;
        }
    }

    if (sprite_zero_hit_candidate and bg_index != 0 and sprite_index != 0 and x != 255) {
        self.status.sprite0_hit = true;
    }

    const use_sprite = sprite_index != 0 and (bg_index == 0 or sprite_in_front);
    const color_addr: u16 = if (use_sprite)
        0x3F10 + (@as(u16, sprite_palette) << 2) + sprite_index
    else if (bg_index != 0)
        0x3F00 + (@as(u16, bg_palette) << 2) + bg_index
    else
        self.backdropAddress();

    if (self.scanline < visible_scanlines) {
        self.framebuffer[@as(usize, self.scanline) * screen_width + x] =
            @as(Palette.Pixel, self.readPalette(color_addr)) | self.emphasisBits();
    }
}

/// The colour last drawn at (`x`, `y`), or null when the point is off the
/// picture.
///
/// Reading the framebuffer by coordinate rather than by index is what keeps
/// the bounds check in one place: `x` covers the full width, but a `u8` `y`
/// reaches 255 against only 240 rows, and the callers that supply one are
/// aiming a light gun rather than walking the picture.
pub fn pixelAt(self: *const Ppu, x: u8, y: u8) ?Palette.Pixel {
    if (y >= screen_height) return null;
    return self.framebuffer[@as(usize, y) * screen_width + x];
}

/// How many dots ago the beam last drew the pixel at (`x`, `y`).
///
/// `outputPixel` emits the pixel for dot *d* at x = d-1, so (x, y) is drawn on
/// scanline y at dot x+1. A point the beam has not reached yet this frame was
/// last drawn one frame ago, which is what the wrap below counts.
///
/// **The odd-frame skipped dot is not accounted for.** It is one dot in 89342
/// and the only caller -- `Zapper`, measuring a sensor that stays lit for
/// thousands -- cannot tell.
pub fn dotsSinceDrawn(self: *const Ppu, x: u8, y: u8) u64 {
    const frame_dots = dots_per_scanline * scanlines_per_frame;
    const drawn_at = @as(u64, y) * dots_per_scanline + x + 1;
    const now = @as(u64, self.scanline) * dots_per_scanline + self.dot;
    return if (now >= drawn_at) now - drawn_at else now + frame_dots - drawn_at;
}

// --- Register access -----------------------------------------------------

/// A CPU read of one of the eight PPU registers, by index rather than address:
/// the bus is responsible for the mirroring across $2000-$3FFF.
pub fn readRegister(self: *Ppu, reg: u3) u8 {
    return switch (reg) {
        2 => blk: {
            var status_byte: u8 = @bitCast(self.status);
            // Bit 7 (VBlank) is latched as the read *begins*, but bits 6-5
            // (sprite 0 hit and overflow) are not latched at all: what
            // reaches the CPU is their value when the read *ends*, almost two
            // PPU cycles later. A read straddling the pre-render dot-1 clear
            // therefore hands back a still-set VBlank bit alongside
            // already-cleared sprite bits.
            if (self.scanline == prerender_scanline and self.dot <= 1) {
                status_byte &= ~@as(u8, 0x60);
            } else {
                // The same window on the setting side. A read is dispatched
                // before the dot `self.dot` names has run, so asking about
                // that dot -- rather than the one already ticked -- is what
                // lets a flag set on it reach the CPU.
                if (self.renderingEnabled() and self.spriteEvalAt(self.dot).overflow_hit) {
                    status_byte |= 0x20;
                }
                if (self.hitWouldOccurAt(self.dot)) status_byte |= 0x40;
            }
            const value = (status_byte & 0xE0) | (self.openBus() & 0x1F);
            // This read is dispatched before the PPU processes the dot
            // `self.dot` currently names, so matching it here means the
            // read and the flag's set land on the same dot -- see `tick`.
            if (self.scanline == vblank_start_scanline and self.dot == 1) {
                self.suppress_vblank_set = true;
            }
            self.status.vblank = false;
            self.updateNmiLine();
            self.write_latch = false;
            // Only the three flag bits are driven; 4-0 came from the bus
            // and must keep ageing.
            self.latchDataBusBits(value, 0xE0);
            break :blk value;
        },
        4 => blk: {
            // While rendering, $2004 doesn't see OAMADDR at all: the PPU
            // owns the OAM bus for the whole scanline and what comes back
            // is the OAM buffer, whatever the clear/evaluate/fetch
            // machinery happens to have left in it this dot. See
            // `oamBusTick`. Outside those lines (and with rendering off)
            // the buffer just follows OAM[OAMADDR], so read that directly.
            //
            // The dot asked for is the current one, not the one already
            // ticked: a read is dispatched before the PPU processes the dot
            // `self.dot` names, and what the CPU latches is the buffer as
            // that dot *ends*.
            const rendering = self.renderingEnabled() and (self.scanline < visible_scanlines or self.scanline == prerender_scanline);
            const value = if (rendering) self.oamBufferForDot(self.dot) else self.oam[self.oam_addr];
            self.latchDataBus(value);
            break :blk value;
        },
        7 => blk: {
            const addr = self.dataPortAddress();
            // Palette entries live inside the PPU, so a palette read
            // answers immediately -- but the bus access still happens, on
            // the nametable underneath the palette window, and it's that
            // access the read buffer ends up holding.
            const palette_read = addr >= 0x3F00;
            const value = if (palette_read)
                self.readPalette(addr) | (self.openBus() & 0xC0)
            else
                self.read_buffer;
            // Everything else about the fetch is deferred: the state
            // machine takes four more dots to get to its own Read, and
            // what it comes back with depends on what the fetch cadence
            // is doing meanwhile. See `DataSmPhase`.
            self.armDataRead(if (palette_read) addr - 0x1000 else addr);
            // A palette entry is only six bits wide, so 7-6 stay floating
            // and must keep ageing. A buffered read drives all eight.
            self.latchDataBusBits(value, if (palette_read) 0x3F else 0xFF);
            break :blk value;
        },
        // The write-only registers drive nothing at all: the CPU sees the
        // decay value, and the read does not refresh it.
        else => self.openBus(),
    };
}

/// The open-bus value the CPU would see right now, with each bit that has
/// outlived its refresh dropped to 0.
fn openBus(self: *const Ppu) u8 {
    var value = self.data_bus;
    for (self.data_bus_decay_at, 0..) |expires_at, bit| {
        if (self.dots_elapsed >= expires_at) value &= ~(@as(u8, 1) << @intCast(bit));
    }
    return value;
}

/// Refreshes the shared PPU I/O latch: written by every register access
/// (read or write, and regardless of whether that register is normally
/// read-only or write-only from the CPU's side -- e.g. writing to $2002
/// still updates it), and read back by any access that doesn't drive
/// every bit itself (the write-only registers, and the low bits of
/// $2002/$2007 palette reads).
fn latchDataBus(self: *Ppu, value: u8) void {
    self.latchDataBusBits(value, 0xFF);
}

/// Refreshes only the bits in `mask`. Bits outside it keep both their
/// value and their existing decay deadline, so a read that drives part of
/// the bus doesn't extend the life of the part it leaves floating.
///
/// Only two accesses are partial: $2002 drives bits 7-5, and a $2007 palette
/// read drives bits 5-0. Everything else drives all eight bits or none.
fn latchDataBusBits(self: *Ppu, value: u8, mask: u8) void {
    self.data_bus = (self.data_bus & ~mask) | (value & mask);
    for (0..8) |bit| {
        if ((mask >> @intCast(bit)) & 1 != 0) {
            self.data_bus_decay_at[bit] = self.dots_elapsed + data_bus_decay_period;
        }
    }
}

/// A CPU write to one of the eight PPU registers, by index, with no early
/// write to model -- i.e. the CPU data bus already held `value` before the
/// write began. See `writeRegisterEarly`.
pub fn writeRegister(self: *Ppu, reg: u3, value: u8) void {
    self.writeRegisterEarly(reg, value, value);
}

/// A CPU write to one of the eight PPU registers, by index; see `readRegister`.
///
/// `early` is what the CPU data bus held on the cycle *before* this write --
/// for an absolute store like `sta $2001` that is the operand's high byte,
/// $20. The 6502 asserts R/W before it drives the data bus, but the PPU
/// treats the data as valid for the whole write, so for about the first dot
/// several of these registers latch `early` instead of `value`. Which ones,
/// and why the rest are excluded, is in the module doc comment.
pub fn writeRegisterEarly(self: *Ppu, reg: u3, value: u8, early: u8) void {
    self.latchDataBus(value);
    // Warm-up: PPUCTRL/PPUMASK/PPUSCROLL/PPUADDR are held cleared by an
    // internal reset signal until the first end-of-VBlank, so a write
    // aimed at them lands on nothing -- not even the shared $2005/$2006
    // latch toggles. See `in_reset`.
    if (self.in_reset) switch (reg) {
        0, 1, 5, 6 => return,
        else => {},
    };
    switch (reg) {
        0 => {
            self.ctrl = @bitCast(value);
            self.t = (self.t & ~@as(u15, 0x0C00)) | (@as(u15, self.ctrl.nametable) << 10);
            self.nmi_output = self.ctrl.nmi_enable;
            self.updateNmiLine();
        },
        1 => {
            self.pending_mask = @bitCast(value);
            self.mask_write_delay = mask_write_delay_ticks;
            // The early-write blip rides one dot ahead of the real value, so
            // everything calibrated against "the mask lands at
            // `mask_write_delay_ticks`" keeps holding. Nothing to do when the
            // bus already agrees on both affected bits -- which is what
            // priming it (`sta $3E01`, or an indexed store) buys.
            if ((early & 0x81) != (value & 0x81)) {
                self.pending_mask_early = early;
                self.mask_early_delay = mask_write_delay_ticks - 1;
            }
        },
        3 => self.oam_addr = value,
        4 => self.writeOamData(value),
        5 => {
            if (!self.write_latch) {
                self.t = (self.t & ~@as(u15, 0x001F)) | (value >> 3);
                self.fine_x = @truncate(value & 0x07);
            } else {
                self.t = (self.t & ~@as(u15, 0x73E0)) |
                    (@as(u15, value & 0x07) << 12) |
                    (@as(u15, value & 0xF8) << 2);
            }
            self.write_latch = !self.write_latch;
        },
        6 => {
            if (!self.write_latch) {
                self.t = (self.t & 0x00FF) | (@as(u15, value & 0x3F) << 8);
            } else {
                self.t = (self.t & 0x7F00) | value;
                self.pending_v = self.t;
                self.pending_v_delay = v_write_delay_ticks;
            }
            self.write_latch = !self.write_latch;
        },
        7 => {
            // Same in-flight-increment correction as a read: a write can
            // arrive one CPU cycle after a read whose increment this PPU
            // hasn't applied yet, and it must still land on the address
            // *after* the one that read took. `sta $2007,x` does exactly
            // that: its dummy read hits $2007 one cycle before the real
            // write. See `dataPortAddress`.
            const addr = self.dataPortAddress();
            // The write drives the address pins even when the target is
            // palette RAM (which lives inside the PPU), so the cartridge
            // sees it either way.
            self.cart.mapper.ppuAddressBus(addr, self.dots_elapsed);
            if (addr >= 0x3F00) {
                self.writePalette(addr, value);
            } else {
                self.writeVram(addr, value);
            }
            self.incrementVramAddress();
        },
        2 => {}, // $2002 is read-only
    }
}

/// Advances `v` after a $2007 access.
///
/// The familiar "+1 or +32" is only what happens outside rendering. `v`
/// isn't a plain counter -- it's the scroll register, and its increment
/// hardware is the same coarse-X/fine-Y pair the fetch cadence uses. With
/// rendering on, a $2007 access pulses *both* of those at once instead of the
/// VRAM increment, so `v` moves a tile right and a row down together -- an
/// increment of $1001 in the common case where neither wraps.
fn incrementVramAddress(self: *Ppu) void {
    if (self.renderOwnsV()) {
        // The fetch cadence owns the pins here, so it -- not this -- is
        // what the cartridge sees.
        self.incrementCoarseX();
        self.incrementFineY();
        // This increment landing on the dot rendering reloads `v` from `t`
        // is one of the two PPU-internal bus conflicts. Neither is modelled:
        // whether one fires depends on sub-dot phase, which this PPU does not
        // carry, so modelling them at whole-dot granularity fires them far
        // more often than hardware does.
        return;
    }
    self.v +%= if (self.ctrl.vram_increment == .add_32) @as(u15, 32) else 1;
    // Idle pins follow `v`, so the increment alone moves the address bus,
    // with no access needed to carry it. A $2007 access at $0FFF therefore
    // ends with A12 high, which is enough to clock an MMC3's counter.
    self.cart.mapper.ppuAddressBus(self.v & 0x3FFF, self.dots_elapsed);
}

fn nametableIndex(self: *Ppu, addr: u16) u16 {
    const mirroring = self.cart.mirroring();
    const table = (addr >> 10) & 0x03;
    const offset = addr & 0x03FF;
    const physical_table: u16 = switch (mirroring) {
        .horizontal => table >> 1,
        .vertical => table & 0x01,
        .single_screen_lower => 0,
        .single_screen_upper => 1,
        .four_screen => table,
    };
    return physical_table * 0x400 + offset;
}

/// The byte `addr` names in nametable RAM.
///
/// Tables 2 and 3 only exist on a four-screen board, and the RAM backing them
/// is on the cartridge rather than in the console, so the index decides which
/// of the two arrays to land in. Folding it back with `& 0x7FF` instead would
/// silently turn every four-screen board into a vertically-mirrored one.
fn nametableByte(self: *Ppu, addr: u16) *u8 {
    const index = self.nametableIndex(addr);
    if (index >= 0x800) return &self.cart.ci_ram[index - 0x800];
    return &self.vram[index];
}

fn readVram(self: *Ppu, addr: u16) u8 {
    const a = addr & 0x3FFF;
    if (a < 0x2000) return self.cart.ppuRead(a);
    return self.nametableByte(a).*;
}

fn writeVram(self: *Ppu, addr: u16, value: u8) void {
    const a = addr & 0x3FFF;
    if (a < 0x2000) {
        self.cart.ppuWrite(a, value);
    } else {
        self.nametableByte(a).* = value;
    }
}

fn palIndex(addr: u16) u8 {
    var i: u8 = @truncate(addr & 0x1F);
    if (i >= 0x10 and (i & 0x03) == 0) i -= 0x10;
    return i;
}

/// Which palette entry a fully transparent pixel shows: normally the
/// backdrop at $3F00, but the entry `v` selects when a forced blank leaves
/// it pointing into palette RAM.
///
/// Not a feature so much as a consequence of palette RAM having one address
/// input: letting the CPU address it also changes what is being displayed.
/// Usually seen as the flash when a game updates palettes outside VBlank, and
/// deliberately used to draw colour bars.
fn backdropAddress(self: *const Ppu) u16 {
    if (!self.renderingEnabled() and (self.v & 0x3F00) == 0x3F00) return self.v & 0x3FFF;
    return 0x3F00;
}

/// The three PPUMASK emphasis bits, positioned for a `Palette.Pixel`.
/// Kept in the register's own bit order (red, green, blue from bit 5 up)
/// so `Palette.table`'s indexing and PPUMASK's agree.
///
/// Read live off `mask`, like the other `outputPixel` gates: emphasis is
/// applied at the very end of the video pipeline, so unlike the rendering
/// enables it has no fetch-stage delay to account for.
fn emphasisBits(self: *const Ppu) Palette.Pixel {
    var bits: Palette.Pixel = 0;
    if (self.mask.emphasize_red) bits |= 1 << 6;
    if (self.mask.emphasize_green) bits |= 1 << 7;
    if (self.mask.emphasize_blue) bits |= 1 << 8;
    return bits;
}

fn readPalette(self: *Ppu, addr: u16) u8 {
    return self.palette[palIndex(addr)] & if (self.mask.greyscale) @as(u8, 0x30) else @as(u8, 0x3F);
}

fn writePalette(self: *Ppu, addr: u16, value: u8) void {
    self.palette[palIndex(addr)] = value & 0x3F;
}

// --- Tests ---------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

/// A blank 16 KiB NROM image with CHR RAM. `Cartridge` aliases the bytes
/// it's handed rather than copying them, so this has to outlive any
/// cartridge built from it -- hence file scope rather than a local.
const blank_rom: [16 + 16 * 1024]u8 = blk: {
    var bytes: [16 + 16 * 1024]u8 = @splat(0);
    bytes[0..4].* = .{ 'N', 'E', 'S', 0x1A };
    bytes[4] = 1; // 16 KiB PRG
    bytes[5] = 0; // no CHR ROM, so CHR RAM
    break :blk bytes;
};

test "emphasis bits ride along with each pixel into the framebuffer" {
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);

    // Rendering stays off, so every pixel is the backdrop at $3F00. That
    // isolates the emphasis bits -- which apply either way, since they act
    // at the end of the video pipeline rather than on the fetch path.
    ppu.palette[0] = 0x21;
    ppu.scanline = 10;

    ppu.dot = 1;
    ppu.mask.emphasize_red = true;
    ppu.outputPixel();
    try testing.expectEqual(@as(Palette.Pixel, 0x21 | (1 << 6)), ppu.framebuffer[10 * 256]);

    ppu.dot = 2;
    ppu.mask.emphasize_red = false;
    ppu.mask.emphasize_blue = true;
    ppu.outputPixel();
    try testing.expectEqual(@as(Palette.Pixel, 0x21 | (1 << 8)), ppu.framebuffer[10 * 256 + 1]);

    ppu.dot = 3;
    ppu.mask.emphasize_red = true;
    ppu.mask.emphasize_green = true;
    ppu.mask.emphasize_blue = false;
    ppu.outputPixel();
    try testing.expectEqual(
        @as(Palette.Pixel, 0x21 | (1 << 6) | (1 << 7)),
        ppu.framebuffer[10 * 256 + 2],
    );
}

test "changing emphasis mid-scanline only affects pixels after the change" {
    // This is why emphasis is stored per-pixel instead of being read off
    // the register at present time: mid-frame changes are exactly what
    // games use it for, and a whole-frame read would smear them.
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    ppu.palette[0] = 0x0F;
    ppu.scanline = 0;

    for (1..129) |dot| {
        ppu.dot = @intCast(dot);
        ppu.outputPixel();
    }
    ppu.mask.emphasize_blue = true;
    for (129..257) |dot| {
        ppu.dot = @intCast(dot);
        ppu.outputPixel();
    }

    try testing.expectEqual(@as(Palette.Pixel, 0x0F), ppu.framebuffer[127]);
    try testing.expectEqual(@as(Palette.Pixel, 0x0F | (1 << 8)), ppu.framebuffer[128]);
}

test "greyscale and emphasis compose, and both survive into the framebuffer" {
    // Greyscale masks the index down to the grey column on the way out of
    // palette RAM; emphasis is added on top. They are separate stages of
    // the same pipeline and a game can use both at once.
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    ppu.palette[0] = 0x25;
    ppu.scanline = 0;
    ppu.dot = 1;
    ppu.mask.greyscale = true;
    ppu.mask.emphasize_green = true;

    ppu.outputPixel();

    try testing.expectEqual(@as(Palette.Pixel, 0x20 | (1 << 7)), ppu.framebuffer[0]);
}

test "a $2002 read drives bits 7-5 and leaves 4-0 ageing" {
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);

    // A register write refreshes the whole bus.
    ppu.writeRegister(0, 0xFF);
    try testing.expectEqual(@as(u8, 0xFF), ppu.openBus());

    // Read $2002 repeatedly for longer than the decay period. Bits 7-5 are
    // driven by the read each time and stay alive; 4-0 are not, so they
    // must rot away regardless of how often the read happens. This is
    // A read that drives part of the bus must not extend the life of the
    // part it leaves floating.
    var elapsed: u64 = 0;
    while (elapsed < data_bus_decay_period * 2) : (elapsed += 1) {
        ppu.dots_elapsed += 1;
        if (elapsed % 64 == 0) _ = ppu.readRegister(2);
    }
    try testing.expectEqual(@as(u8, 0), ppu.openBus() & 0x1F);
}

test "a $2007 palette read drives bits 5-0 and leaves 7-6 ageing" {
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);

    ppu.writeRegister(0, 0xFF);
    try testing.expectEqual(@as(u8, 0xFF), ppu.openBus());

    // A palette entry is six bits wide, so 7-6 are never driven.
    var elapsed: u64 = 0;
    while (elapsed < data_bus_decay_period * 2) : (elapsed += 1) {
        ppu.dots_elapsed += 1;
        if (elapsed % 64 == 0) {
            ppu.v = 0x3F00;
            _ = ppu.readRegister(7);
        }
    }
    try testing.expectEqual(@as(u8, 0), ppu.openBus() & 0xC0);
}

test "reading a write-only register returns the decay value without refreshing it" {
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);

    ppu.writeRegister(0, 0xA5);
    try testing.expectEqual(@as(u8, 0xA5), ppu.readRegister(0));

    // Polling a write-only register must not keep the bus alive.
    var elapsed: u64 = 0;
    while (elapsed < data_bus_decay_period * 2) : (elapsed += 1) {
        ppu.dots_elapsed += 1;
        if (elapsed % 64 == 0) _ = ppu.readRegister(0);
    }
    try testing.expectEqual(@as(u8, 0), ppu.readRegister(0));
}

/// Runs `dots` PPU dots and reports whether an NMI edge was latched at any
/// point, draining the latch the way the CPU would.
fn drainNmiOverDots(ppu: *Ppu, dots: usize) bool {
    var seen = false;
    for (0..dots) |_| {
        ppu.tick();
        if (ppu.nmi_edge_pending) {
            ppu.nmi_edge_pending = false;
            seen = true;
        }
    }
    return seen;
}

test "the CPU sees an NMI assertion nmi_line_delay_dots after the PPU drives it" {
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);

    // Park well away from any scanline boundary so nothing else moves the
    // line, then assert it by hand.
    ppu.scanline = 250;
    ppu.dot = 100;
    ppu.nmi_output = true;
    ppu.status.vblank = true;

    // The rise has to propagate through the delay line before the edge is
    // recognized -- and not before.
    for (0..nmi_line_delay_dots) |_| {
        ppu.tick();
        try testing.expect(!ppu.nmi_edge_pending);
    }
    ppu.tick();
    try testing.expect(ppu.nmi_edge_pending);
}

test "a one-dot pulse on the NMI line is never recognized, at any delay depth" {
    // This is a *pulse width* rule, and it must stay independent of
    // `nmi_line_delay_dots`. Tying the two together is what made
    // 07-nmi_on_timing and 08-nmi_off_timing mutually unsatisfiable --
    // every extra dot of delay silently demanded a wider pulse. See
    // recognized, so a line that goes high and low again inside one CPU
    // cycle is never seen.
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    ppu.scanline = 250;
    ppu.dot = 100;
    ppu.status.vblank = true;

    // High for exactly one dot, then low again.
    ppu.nmi_output = true;
    ppu.tick();
    ppu.nmi_output = false;

    try testing.expect(!drainNmiOverDots(&ppu, 8));
}

test "a two-dot pulse on the NMI line is recognized" {
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    ppu.scanline = 250;
    ppu.dot = 100;
    ppu.status.vblank = true;

    ppu.nmi_output = true;
    ppu.tick();
    ppu.tick();
    ppu.nmi_output = false;

    try testing.expect(drainNmiOverDots(&ppu, 8));
}

/// A PPU rendering scanline `line`, with `count` sprites parked on it and
/// every other OAM entry pushed off-screen.
fn spriteEvalTestPpu(cart: *Cartridge, count: usize, line: u16) Ppu {
    var ppu = Ppu.init(cart);
    ppu.mask.show_background = true;
    ppu.mask.show_sprites = true;
    ppu.scanline = line;
    ppu.dot = 0;
    for (0..64) |i| ppu.oam[i * 4] = 0xF0; // Y=240 is off the bottom
    for (0..count) |i| ppu.oam[i * 4] = @intCast(line);
    return ppu;
}

/// Ticks from the current dot through the end of the evaluation window.
fn runEvalWindow(ppu: *Ppu, disable_at: ?u16, size_16_at: ?u16) void {
    while (ppu.dot <= 256) {
        if (disable_at) |d| if (ppu.dot == d) {
            ppu.mask.show_background = false;
            ppu.mask.show_sprites = false;
        };
        if (size_16_at) |d| if (ppu.dot == d) {
            ppu.ctrl.sprite_size = .size_8x16;
        };
        ppu.tick();
    }
}

test "the ninth sprite on a scanline sets the overflow flag, the eighth doesn't" {
    var cart = try Cartridge.load(&blank_rom);
    for ([_]usize{ 8, 9 }) |count| {
        var ppu = spriteEvalTestPpu(&cart, count, 100);
        runEvalWindow(&ppu, null, null);
        try testing.expectEqual(count == 9, ppu.status.sprite_overflow);
    }
}

test "a forced blank part-way through the window stops the scan where it stands" {
    // The point of running evaluation dot by dot rather than predicting it
    // at dot 64: rendering going away has to actually stop the scan, so a
    // 9th sprite the scan never reaches sets nothing.
    var cart = try Cartridge.load(&blank_rom);

    // Sprite 8 -- the one that overflows -- is examined around dot 65+2*8.
    var ppu = spriteEvalTestPpu(&cart, 9, 100);
    runEvalWindow(&ppu, 70, null);
    try testing.expect(!ppu.status.sprite_overflow);

    // Blanking after the scan has already passed it changes nothing.
    var late = spriteEvalTestPpu(&cart, 9, 100);
    runEvalWindow(&late, 200, null);
    try testing.expect(late.status.sprite_overflow);
}

test "sprite height is read live, so when a $2000 write lands mid-scan matters" {
    // Sprites at Y=100 on scanline 110 are out of range at 8x8 and in range
    // at 8x16. Whether they count therefore depends on the height *at the
    // dot each one is examined*, which a scan latching the height up front
    // cannot express.
    var cart = try Cartridge.load(&blank_rom);

    var before = spriteEvalTestPpu(&cart, 9, 110);
    for (0..9) |i| before.oam[i * 4] = 100;
    runEvalWindow(&before, null, 64);
    try testing.expect(before.status.sprite_overflow);

    // Switching only after the scan has already rejected all nine at 8x8
    // leaves nothing to find.
    var after = spriteEvalTestPpu(&cart, 9, 110);
    for (0..9) |i| after.oam[i * 4] = 100;
    runEvalWindow(&after, null, 150);
    try testing.expect(!after.status.sprite_overflow);
}

test "warm-up ignores PPUCTRL/PPUMASK/PPUSCROLL/PPUADDR, and the latch with them" {
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    try testing.expect(ppu.in_reset);

    ppu.writeRegister(0, 0xFF);
    ppu.writeRegister(1, 0xFF);
    try testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(ppu.ctrl)));
    try testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(ppu.mask)));

    // "This also means that the PPUSCROLL/PPUADDR latch will not toggle."
    // A half-written address would otherwise leave the latch flipped and
    // desynchronise every later write pair.
    ppu.writeRegister(6, 0x3F);
    try testing.expect(!ppu.write_latch);
    try testing.expectEqual(@as(u15, 0), ppu.t);

    // The rest work immediately.
    ppu.writeRegister(3, 0x42);
    try testing.expectEqual(@as(u8, 0x42), ppu.oam_addr);
}

test "warm-up ends at the first end of VBlank, one frame after power-on" {
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);

    var dots: u64 = 0;
    while (ppu.in_reset and dots < 200_000) : (dots += 1) ppu.tick();

    // Pre-render dot 1 of the first frame, which is where the same signal
    // that clears the VBlank, sprite 0 and overflow flags also clears this
    // one. Deriving it from the frame geometry rather than hard-coding a
    // cycle count is what keeps it from drifting out of step with the rest
    // of the timing.
    try testing.expectEqual(
        @as(u64, prerender_scanline * dots_per_scanline + 2),
        dots,
    );
    try testing.expect(!ppu.in_reset);

    // And once it is over, the registers take writes.
    ppu.writeRegister(0, 0x80);
    try testing.expect(ppu.ctrl.nmi_enable);
}

test "a reset re-arms the warm-up" {
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    while (ppu.in_reset) ppu.tick();

    ppu.reset();
    try testing.expect(ppu.in_reset);
    ppu.writeRegister(1, 0x1E);
    try testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(ppu.mask)));
}

test "$2007 accesses one CPU cycle apart step through consecutive addresses" {
    // This PPU defers a read's fetch (and its increment of `v`) four dots,
    // so back-to-back accesses would otherwise all capture the same
    // pre-increment `v`. Only a DMC DMA halting the CPU mid-access, or an
    // indexed store's dummy read, gets them this close. See
    // `dataPortAddress`.
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    ppu.in_reset = false;
    for (0..8) |i| ppu.vram[i] = @intCast(0x11 * (i + 1));

    ppu.v = 0x2000;
    _ = ppu.readRegister(7); // buffered read, arms a fetch of $2000
    for (0..3) |_| ppu.tick(); // one CPU cycle later
    _ = ppu.readRegister(7); // must arm $2001, not $2000 again
    for (0..12) |_| ppu.tick(); // let both fetches retire

    try testing.expectEqual(@as(u8, 0x22), ppu.read_buffer);
    try testing.expectEqual(@as(u15, 0x2002), ppu.v);
}

test "a $2007 write one cycle after a read lands on the address after it" {
    // `sta $2007,x` with x=0: the absolute-indexed store's dummy read hits
    // $2007 one cycle before the real write, so the write must land on the
    // *next* address.
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    ppu.in_reset = false;
    for (0..8) |i| ppu.vram[i] = @intCast(0x11 * (i + 1));

    ppu.v = 0x2000;
    _ = ppu.readRegister(7); // the dummy read
    for (0..3) |_| ppu.tick();
    ppu.writeRegister(7, 0x99);

    try testing.expectEqual(@as(u8, 0x11), ppu.vram[0]); // untouched
    try testing.expectEqual(@as(u8, 0x99), ppu.vram[1]);
    // The deferred read still fetches what *it* was aimed at, not the byte
    // the write just put down.
    for (0..12) |_| ppu.tick();
    try testing.expectEqual(@as(u8, 0x11), ppu.read_buffer);
}

test "an isolated $2007 read is unaffected by the in-flight correction" {
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    ppu.in_reset = false;
    for (0..8) |i| ppu.vram[i] = @intCast(0x11 * (i + 1));

    ppu.v = 0x2000;
    _ = ppu.readRegister(7);
    for (0..12) |_| ppu.tick(); // fetch fully retired
    _ = ppu.readRegister(7);
    for (0..12) |_| ppu.tick();

    try testing.expectEqual(@as(u8, 0x22), ppu.read_buffer);
}

test "an OAM write during rendering is dropped and only glitches OAMADDR" {
    // Both the CPU's $2004 and OAM DMA land here, so a DMA fired with
    // rendering left on must not rewrite sprites mid-screen.
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    ppu.in_reset = false;
    ppu.oam[0x11] = 0xAB;

    ppu.mask.show_sprites = true;
    ppu.scanline = 100; // visible, so rendering is live
    ppu.oam_addr = 0x11;
    ppu.writeOamData(0x5A);

    try testing.expectEqual(@as(u8, 0xAB), ppu.oam[0x11]); // untouched
    try testing.expectEqual(@as(u8, 0x14), ppu.oam_addr); // (0x11+4) & 0xFC

    // Outside rendering the same call writes normally.
    ppu.mask.show_sprites = false;
    ppu.oam_addr = 0x11;
    ppu.writeOamData(0x5A);
    try testing.expectEqual(@as(u8, 0x5A), ppu.oam[0x11]);
    try testing.expectEqual(@as(u8, 0x12), ppu.oam_addr);
}

test "a forced blank with v in palette RAM draws that entry, not the backdrop" {
    // This is the mechanism behind the flash a game
    // gets when it updates palettes outside vblank.
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    ppu.in_reset = false;
    ppu.palette[0] = 0x0F; // backdrop
    ppu.palette[palIndex(0x3F11)] = 0x21;
    ppu.scanline = 10;

    // Forced blank with v parked on $3F11: that entry wins.
    ppu.v = 0x3F11;
    ppu.dot = 1;
    ppu.outputPixel();
    try testing.expectEqual(@as(Palette.Pixel, 0x21), ppu.framebuffer[10 * 256]);

    // v outside palette RAM: ordinary backdrop.
    ppu.v = 0x2000;
    ppu.dot = 2;
    ppu.outputPixel();
    try testing.expectEqual(@as(Palette.Pixel, 0x0F), ppu.framebuffer[10 * 256 + 1]);

    // With rendering on it is a normal transparent pixel again, even
    // though v still points into palette RAM.
    ppu.v = 0x3F11;
    ppu.mask.show_background = true;
    ppu.dot = 3;
    ppu.outputPixel();
    try testing.expectEqual(@as(Palette.Pixel, 0x0F), ppu.framebuffer[10 * 256 + 2]);
}

test "a four-screen board gets four distinct nametables" {
    // Folding tables 2/3 onto 0/1 would make every four-screen board behave
    // as a vertically-mirrored one and lose the cartridge's extra 2 KiB.
    var rom_bytes: [16 + 16 * 1024]u8 = @splat(0);
    rom_bytes[0..4].* = .{ 'N', 'E', 'S', 0x1A };
    rom_bytes[4] = 1;
    rom_bytes[6] = 0x08 | 0x40; // four-screen, mapper 4 (MMC3 boards use it)
    var cart = try Cartridge.load(&rom_bytes);
    var ppu = Ppu.init(&cart);
    ppu.in_reset = false;

    try testing.expectEqual(Mirroring.four_screen, cart.mirroring());

    // A distinct byte in each table, then read them all back.
    for (0..4) |t| ppu.writeVram(@intCast(0x2000 + t * 0x400), @intCast(0xA0 + t));
    for (0..4) |t| {
        try testing.expectEqual(@as(u8, @intCast(0xA0 + t)), ppu.readVram(@intCast(0x2000 + t * 0x400)));
    }
    // The upper pair really is the cartridge's RAM, not the console's.
    try testing.expectEqual(@as(u8, 0xA2), cart.ci_ram[0]);
    try testing.expectEqual(@as(u8, 0xA0), ppu.vram[0]);
}

test "a two-screen board still mirrors into the console's 2 KiB" {
    var rom_bytes: [16 + 16 * 1024]u8 = @splat(0);
    rom_bytes[0..4].* = .{ 'N', 'E', 'S', 0x1A };
    rom_bytes[4] = 1;
    rom_bytes[6] = 0x01; // vertical, mapper 0
    var cart = try Cartridge.load(&rom_bytes);
    var ppu = Ppu.init(&cart);
    ppu.in_reset = false;

    ppu.writeVram(0x2000, 0x11);
    try testing.expectEqual(@as(u8, 0x11), ppu.readVram(0x2800)); // table 2 aliases 0
    try testing.expectEqual(@as(u8, 0), cart.ci_ram[0]); // never touched
}

test "OAMADDR left non-zero when rendering starts drags a row over OAM row 0" {
    // Distinct from `applyOamCorruption`, which
    // copies the other way.
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    ppu.in_reset = false;
    for (0..256) |i| ppu.oam[i] = @intCast(i);

    ppu.mask.show_sprites = true;
    ppu.oam_addr = 0x83; // masks to row $80
    ppu.scanline = prerender_scanline;
    ppu.dot = eval_window_start;
    ppu.tick();

    for (0..8) |i| try testing.expectEqual(@as(u8, @intCast(0x80 + i)), ppu.oam[i]);
    // Only the first row moves.
    try testing.expectEqual(@as(u8, 8), ppu.oam[8]);
}

test "OAMADDR below 8 makes the refresh bug a self-copy" {
    // Which is why "not zero" and "eight or greater" describe the same
    // PPU_sprite_evaluation says "not zero" -- masking with $F8 makes the
    // two agree on everything observable.
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    ppu.in_reset = false;
    for (0..256) |i| ppu.oam[i] = @intCast(i);

    ppu.mask.show_sprites = true;
    ppu.oam_addr = 7;
    ppu.scanline = prerender_scanline;
    ppu.dot = eval_window_start;
    ppu.tick();

    for (0..8) |i| try testing.expectEqual(@as(u8, @intCast(i)), ppu.oam[i]);
}

test "the odd-frame dot skip moves the last dummy fetch rather than dropping it" {
    // Odd and even frames must issue the same number of VRAM reads; only
    // *when* the last one happens differs. The MMC3's counter is built out
    // of exactly these fetches.
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    ppu.in_reset = false;
    ppu.mask.show_background = true;
    ppu.rendering_delayed = true;
    ppu.vram[0] = 0xC3; // what the dummy nametable fetch will read back

    // Pre-render dot 339 on an odd frame: the next dot is skipped.
    ppu.scanline = prerender_scanline;
    ppu.dot = 339;
    ppu.odd_frame = true;
    ppu.v = 0x2000;
    ppu.nt_latch = 0;

    ppu.tick(); // dot 339 runs, then 340 is skipped
    try testing.expectEqual(@as(u16, 0), ppu.dot);
    try testing.expectEqual(@as(u16, 0), ppu.scanline);
    try testing.expect(ppu.deferred_nt_fetch); // the read is owed

    ppu.tick(); // dot 0 pays it
    try testing.expect(!ppu.deferred_nt_fetch);
    try testing.expectEqual(@as(u8, 0xC3), ppu.nt_latch);
}

test "an even frame runs dot 340 normally and owes nothing" {
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    ppu.in_reset = false;
    ppu.mask.show_background = true;
    ppu.rendering_delayed = true;

    ppu.scanline = prerender_scanline;
    ppu.dot = 339;
    ppu.odd_frame = false;
    ppu.tick();

    try testing.expectEqual(@as(u16, 340), ppu.dot);
    try testing.expect(!ppu.deferred_nt_fetch);
}

// --- Early writes --------------------------------------------------------

test "an early write drops greyscale for exactly one dot" {
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    ppu.in_reset = false;
    ppu.scanline = 10;
    ppu.dot = 10;
    ppu.mask.greyscale = true;

    // `sta $2001` of $1F (greyscale still set) with $20 left on the bus by
    // the operand fetch. Bit 0 of $20 is clear, so the register shows
    // greyscale off for the dot before the real value catches up: old and new
    // agree, and only the gap between them differs.
    ppu.writeRegisterEarly(1, 0x1F, 0x20);

    for (0..mask_write_delay_ticks - 1) |_| ppu.tick();
    try testing.expect(!ppu.mask.greyscale);
    ppu.tick();
    try testing.expect(ppu.mask.greyscale);
}

test "priming the bus through a mirror leaves no early-write glitch" {
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    ppu.in_reset = false;
    ppu.scanline = 10;
    ppu.dot = 10;
    ppu.mask.greyscale = true;

    // `sta $3F01`: the operand's high byte is $3F, whose bit 0 matches the
    // $1F being written, so nothing glitches. This is the mitigation
    // AccuracyCoin uses when it writes rendering-enable through $3E01.
    ppu.writeRegisterEarly(1, 0x1F, 0x3F);

    for (0..mask_write_delay_ticks + 1) |_| {
        try testing.expect(ppu.mask.greyscale);
        ppu.tick();
    }
}

test "the rendering-enable bits ignore the early value" {
    var cart = try Cartridge.load(&blank_rom);
    var ppu = Ppu.init(&cart);
    ppu.in_reset = false;
    ppu.scanline = 10;
    ppu.dot = 10;
    ppu.mask.show_background = true;

    // $20 has both rendering bits clear, so a naive early write would drop
    // rendering for a dot here and arm OAM corruption. On the 2C02G only the
    // $81 bits are combinational; letting $18 follow the bus costs
    // `10-even_odd_timing` #5 and `sprite_overflow_tests`.
    ppu.writeRegisterEarly(1, 0x08, 0x20);

    for (0..mask_write_delay_ticks + 1) |_| {
        try testing.expect(ppu.renderingEnabled());
        try testing.expect(ppu.pending_oam_corruption == null);
        ppu.tick();
    }
}

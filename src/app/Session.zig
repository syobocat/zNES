// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! One loaded ROM and the console running it.
//!
//! `Cartridge` borrows the ROM image it was loaded from and `Nes` borrows the
//! `Cartridge`, so the three have to live and die together and the cartridge
//! must not move once the console points at it. Bundling them into one
//! heap-allocated value is what makes that true by construction, and it is
//! what lets the app throw the whole thing away and load another ROM at
//! runtime -- which is the difference between an emulator that takes a path
//! on the command line and one you can drop a file onto.

const std = @import("std");
const Session = @This();
const Allocator = std.mem.Allocator;

const znes = @import("znes");
const Cartridge = znes.Cartridge;
const Nes = znes.Nes;

const input = @import("input");

/// The ROM image. `cart` points into this, so it is freed last.
rom: []u8,
/// The file's own name, without any directory, kept for the window title and
/// for error messages. Owned.
file_name: []u8,
cart: Cartridge,
nes: Nes,
/// What the cartridge is, for whoever has to decide whose save is whose.
/// Taken once here rather than per write, since hashing the ROM costs a
/// millisecond or so and a save goes out about once a second.
fingerprint: Cartridge.Fingerprint,

pub const LoadError = Cartridge.LoadError || Allocator.Error;

/// Boots a ROM image that has already been read, **taking ownership of it**.
/// On failure `rom` is left to the caller to free, since nothing here got as
/// far as owning it.
pub fn adopt(gpa: Allocator, file_name: []const u8, rom: []u8) LoadError!*Session {
    const name_copy = try gpa.dupe(u8, file_name);
    errdefer gpa.free(name_copy);

    const self = try gpa.create(Session);
    errdefer gpa.destroy(self);

    self.* = .{
        .rom = rom,
        .file_name = name_copy,
        .cart = try Cartridge.load(rom),
        .nes = undefined,
        .fingerprint = undefined,
    };
    self.fingerprint = self.cart.fingerprint();
    // Only now that `self.cart` has its final address, since the console
    // keeps a pointer to it.
    self.nes = Nes.init(&self.cart);
    return self;
}

pub fn deinit(self: *Session, gpa: Allocator) void {
    gpa.free(self.file_name);
    gpa.free(self.rom);
    gpa.destroy(self);
}

/// The reset button: leaves RAM and most component state alone.
pub fn reset(self: *Session) void {
    self.nes.reset();
}

/// The power switch: a cold boot, as if the console had been unplugged.
/// A movie plays back from here, since that is the state it was recorded
/// from.
pub fn powerCycle(self: *Session) void {
    self.nes.powerOn();
}

/// Hands this frame's input to the console: every pad's buttons, and where
/// the light gun is pointed.
///
/// Both go in unconditionally. Which of them the machine can see is decided
/// by what is plugged into it (`Nes.Peripherals`): a pad whose port is
/// currently occupied by the Zapper still has its buttons kept up to date,
/// since unplugging the gun must not hand the game a frozen pad.
pub fn applyInput(self: *Session, ports: input.Ports, gun: input.Gun) void {
    // The bit layouts have to agree for this cast to mean anything. They are
    // declared in two places on purpose -- the app and platform layers stay
    // free of NES types -- so the agreement is checked here, where the two
    // meet.
    comptime {
        const Button = znes.Controller.Button;
        const fields = @typeInfo(input.Buttons).@"struct".fields;
        std.debug.assert(fields.len == @typeInfo(Button).@"enum".fields.len);
        for (fields, 0..) |field, bit| {
            std.debug.assert(@intFromEnum(@field(Button, field.name)) == bit);
        }
    }
    for (&self.nes.controllers, ports) |*controller, buttons| {
        controller.setButtons(@bitCast(buttons));
    }
    self.nes.zapper.setAim(if (gun.on_screen) .{ .x = gun.x, .y = gun.y } else null);
    self.nes.zapper.setTrigger(gun.trigger, self.nes.ppu.dots_elapsed);
}

/// Plugs something else into the controller ports. Survives a power cycle,
/// since flipping the switch does not unplug anything.
pub fn setPeripherals(self: *Session, plugged_in: znes.Nes.Peripherals) void {
    self.nes.peripherals = plugged_in;
}

pub fn peripherals(self: *const Session) znes.Nes.Peripherals {
    return self.nes.peripherals;
}

/// How many complete pictures the console has produced. The main loop cuts
/// its frames on changes to this rather than counting cycles, so a frame is
/// exactly what the PPU says it is.
///
/// **The boundary is the end of the visible picture, not the wrap to
/// scanline 0.** Everything the console does with a frame's input happens in
/// the VBlank that follows the picture, so input read at this boundary
/// reaches the NMI handler one scanline later. Cutting the loop anywhere
/// after VBlank instead would hand the game input a frame late -- which is
/// exactly what desyncs a replayed movie against the emulator that recorded
/// it, and what makes live input feel a frame heavier than it needs to.
pub fn pictureCount(self: *const Session) u64 {
    return self.nes.ppu.picture;
}

/// Advances the console to the next picture boundary, handing every CPU
/// cycle to `sink.cycle()` on the way. `sink` is `{}` when nothing needs
/// sampling.
pub fn runFrame(self: *Session, sink: anytype) !void {
    const target = self.pictureCount() + 1;
    while (self.pictureCount() < target) {
        self.nes.stepCycle();
        if (@TypeOf(sink) != void) try sink.cycle(&self.nes);
    }
}

/// Runs out whatever is left of the picture in progress, leaving the console
/// sitting on a frame boundary.
///
/// Both `powerCycle` and `reset` put the PPU back at the *top* of the
/// picture, which is a fifth of a frame short of the boundary `runFrame` cuts
/// on. Without this the frame that follows either of them is a stub with no
/// VBlank in it -- harmless for a player holding a controller, but under a
/// movie that stub still costs a whole record, and every record after it is
/// then one frame out of step for good.
pub fn alignToFrame(self: *Session) void {
    const target = self.pictureCount() + 1;
    while (self.pictureCount() < target) self.nes.stepCycle();
}

/// The file name, for the window title. Already free of any directory: the
/// platform strips one off a path before handing it over, and a browser only
/// ever knows the bare name to begin with.
pub fn name(self: *const Session) []const u8 {
    return self.file_name;
}

// --- Battery saves -------------------------------------------------------

/// The cartridge RAM worth persisting, empty on a board with no battery.
/// Writable, so a platform can restore a save straight into it -- but only at
/// exactly this length; see `loadBatteryRam`.
pub fn batteryRam(self: *Session) []u8 {
    return self.cart.batteryRam();
}

/// Whether the save has been written since the last time this was asked.
pub fn takeBatteryRamDirty(self: *Session) bool {
    return self.cart.takeBatteryRamDirty();
}

// --- Tests ---------------------------------------------------------------

const testing = std.testing;

/// A blank 16 KiB NROM image, on the heap because a session takes ownership
/// of the one it is handed.
fn blankRom(gpa: Allocator) ![]u8 {
    const rom = try gpa.alloc(u8, 16 + 16 * 1024);
    @memset(rom, 0);
    rom[0..4].* = .{ 'N', 'E', 'S', 0x1A };
    rom[4] = 1; // one 16 KiB PRG bank
    return rom;
}

test "a session owns its ROM image, its name and its console" {
    const gpa = testing.allocator;
    const session = try Session.adopt(gpa, "blank.nes", try blankRom(gpa));
    defer session.deinit(gpa);

    try testing.expectEqualStrings("blank.nes", session.name());
    // The console must be looking at *this* session's cartridge, wherever the
    // allocator happened to put it.
    try testing.expectEqual(&session.cart, session.nes.cart);
}

test "a rejected ROM leaves its image for the caller to free" {
    const gpa = testing.allocator;
    const rom = try gpa.alloc(u8, 8); // too short to be a header
    defer gpa.free(rom); // the point of the test: this is still ours to free
    @memset(rom, 0);

    try testing.expectError(error.TruncatedRom, Session.adopt(gpa, "bad.nes", rom));
}

test "applyInput reaches every controller port in the right bit order" {
    const gpa = testing.allocator;
    const session = try Session.adopt(gpa, "blank.nes", try blankRom(gpa));
    defer session.deinit(gpa);

    session.applyInput(.{
        .{ .a = true, .start = true },
        .{ .right = true },
    }, .none);
    try testing.expectEqual(@as(u8, 0b0000_1001), session.nes.controllers[0].buttons);
    try testing.expectEqual(@as(u8, 0b1000_0000), session.nes.controllers[1].buttons);

    // And releasing means releasing, not just adding.
    session.applyInput(input.no_input, .none);
    try testing.expectEqual(@as(u8, 0), session.nes.controllers[0].buttons);
}

test "applyInput points the light gun, and pointing away is its own state" {
    const gpa = testing.allocator;
    const session = try Session.adopt(gpa, "blank.nes", try blankRom(gpa));
    defer session.deinit(gpa);

    session.applyInput(input.no_input, .{ .x = 128, .y = 60, .on_screen = true });
    try testing.expectEqual(@as(u8, 128), session.nes.zapper.aim.?.x);
    try testing.expectEqual(@as(u8, 60), session.nes.zapper.aim.?.y);

    // Off the screen is not "no input": the gun is still there, seeing black.
    session.applyInput(input.no_input, .{ .x = 128, .y = 60 });
    try testing.expectEqual(@as(?znes.Zapper.Aim, null), session.nes.zapper.aim);
}

test "a power cycle leaves the peripherals plugged in and the gun aimed" {
    const gpa = testing.allocator;
    const session = try Session.adopt(gpa, "blank.nes", try blankRom(gpa));
    defer session.deinit(gpa);

    session.setPeripherals(.zapper);
    session.applyInput(input.no_input, .{ .x = 40, .y = 50, .on_screen = true });
    session.powerCycle();

    try testing.expectEqual(znes.Nes.Peripherals.zapper, session.peripherals());
    try testing.expectEqual(@as(u8, 40), session.nes.zapper.aim.?.x);
}

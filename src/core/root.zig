// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! The `znes` module: an NTSC NES, and nothing that knows how to show one.
//!
//! `Nes` is the console and owns everything else. The rest of what is exported
//! here is the surface a frontend needs: a cartridge to load, the peripherals
//! that plug into the ports, the picture's dimensions, and the palette that
//! turns a framebuffer entry into a colour.
//!
//! Nothing in this module allocates. `Cartridge` borrows the ROM image it was
//! loaded from and keeps its writable regions inline, so the caller owns the
//! bytes and decides how long they live.
//!
//! This is also the root of the core's test build: every file reachable from
//! here by `@import` contributes its tests to `zig build test`.

const std = @import("std");

pub const Nes = @import("Nes.zig");
pub const Cartridge = @import("cart/Cartridge.zig");
pub const Controller = @import("peripheral/Controller.zig");
pub const Zapper = @import("peripheral/Zapper.zig");
pub const Ppu = @import("ppu/Ppu.zig");
pub const Palette = @import("video/Palette.zig");
pub const Mirroring = @import("cart/mapper/mapper.zig").Mirroring;

/// NTSC's frame shape and clock: the picture's size, which a frontend needs
/// to size a window and to walk `Ppu.framebuffer`, and the frame rate, which
/// it needs to pace a loop.
pub const timing = @import("timing.zig");
pub const screen_width = timing.screen_width;
pub const screen_height = timing.screen_height;
pub const frame_rate = timing.frame_rate;

test {
    std.testing.refAllDecls(@This());
}

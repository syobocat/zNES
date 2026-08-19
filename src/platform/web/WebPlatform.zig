//! Browser-backed platform: a canvas, a Web Audio device, and whatever the
//! page's key handlers have most recently told us is held. This is the web
//! build's answer to `SdlPlatform`, and its public surface is deliberately
//! the same one -- `App` imports whichever of the two it was built with and
//! cannot tell them apart.
//!
//! The division of labour with JavaScript is the same one `SdlPlatform` has
//! with SDL: this file decides *what* to show and play, and the host decides
//! how. So the palette-index framebuffer is converted to RGBA here, next to
//! the identical conversion in `SdlPlatform.present`, and the page's only job
//! is to hand the finished pixels to a canvas.
//!
//! The buffers the page reads out of linear memory are ordinary fields. That
//! works because `App` initialises in place and the web build keeps its one
//! at module scope, so their addresses hold for the life of the tab. The page
//! re-reads them every frame anyway (`refreshViews` in `znes.js`), since wasm
//! memory growth detaches any view built over it.
//!
//! Nothing here calls into the page except through `host`. Everything else --
//! input, and the bytes of a dropped file -- travels the other way, pushed in
//! by the exports in `main.zig` before the frame that reads them.

const std = @import("std");
const Web = @This();

const znes = @import("znes");
const Palette = znes.Palette;

const input = @import("input");
const interface = @import("interface");

// The console's, not a choice made here: `present` is handed a framebuffer
// of exactly this size.
const screen_width = znes.screen_width;
const screen_height = znes.screen_height;

/// `quit` and `dropped_path` are never set here: a tab closes without asking
/// us, and a browser hands over a dropped file's bytes -- which arrive by
/// `main.zig`'s `znesOpen` -- rather than a path the caller could go and read.
const InputState = interface.InputState;
const Overlay = interface.Overlay;
const save = @import("save");

/// The page's side of the boundary. These are the only calls that leave the
/// module; everything else the browser needs, it reads out of linear memory.
const host = struct {
    extern "znes" fn queueAudio(ptr: [*]const f32, len: usize) void;
    extern "znes" fn clearAudio() void;
    extern "znes" fn queuedAudioSamples() usize;
    /// Saves live in `localStorage`, one key per slot. That is the only
    /// persistent store a page has which can be read *now*: the alternatives
    /// are all asynchronous, and a cartridge's RAM has to be in place before
    /// the game's first frame reads it.
    ///
    /// `saveCount` takes the snapshot the walk below reads, so a slot moving
    /// cannot make the walk skip or repeat one.
    extern "znes" fn saveCount() usize;
    /// The name of the `index`th slot in that snapshot, written into `buf`.
    /// Returns its length, or 0 if it did not fit.
    extern "znes" fn saveNameAt(index: usize, buf: [*]u8, buf_len: usize) usize;
    /// The slot's whole length, having filled as much of `into` as fits.
    /// Zero when there is no such slot; a stored save is never empty.
    extern "znes" fn saveRead(
        name_ptr: [*]const u8,
        name_len: usize,
        into_ptr: [*]u8,
        into_len: usize,
    ) usize;
    extern "znes" fn saveWrite(
        name_ptr: [*]const u8,
        name_len: usize,
        ptr: [*]const u8,
        len: usize,
    ) void;
    extern "znes" fn saveRename(
        from_ptr: [*]const u8,
        from_len: usize,
        to_ptr: [*]const u8,
        to_len: usize,
    ) void;
    /// Copies a slot to a key of its own, which nothing here ever reads back.
    extern "znes" fn saveKeepGeneration(name_ptr: [*]const u8, name_len: usize) void;
};

/// The finished picture, RGBA8888 and ready to become an `ImageData`. Alpha
/// is opaque for every pixel and never written after `init`.
///
/// Zeroed rather than left undefined because the page shows it before the
/// first frame is ever drawn -- there is no console to draw one until a ROM
/// arrives -- and a debug build fills undefined memory with a pattern, which
/// would put static on the screen instead of the idle message.
framebuffer: [screen_width * screen_height * 4]u8 = @splat(0),

/// This frame's overlays, encoded for the page to draw with `fillText`. See
/// `encodeOverlays` for the format.
overlay: [overlay_capacity]u8 = undefined,
overlay_len: usize = 0,

/// The window title, which the page puts in `document.title`. Not
/// NUL-terminated -- `title_len` is what says where it ends.
title: [max_title]u8 = undefined,
title_len: usize = 0,

/// Buttons the page has pushed in, waiting to be picked up by `pollInput`.
pending: InputState = .{},

/// Room for every overlay `App` can produce at once (an idle message, a
/// replay counter and a toast) with their text and framing. Generous rather
/// than exact: overflowing it drops the overlay rather than the frame.
const overlay_capacity = 1024;

/// Longer than `App`'s own title buffer, so a title is never cut short here.
const max_title = 512;

/// `scale` and `audio_sample_rate` are the page's business -- the canvas is
/// sized by CSS and the sample rate comes from the `AudioContext` -- and there
/// is no filesystem here for `io` to reach, so all three are accepted and
/// ignored. They stay in the signature because this has to be the same
/// platform interface `SdlPlatform` presents.
pub fn init(
    self: *Web,
    window_title: [:0]const u8,
    scale: u32,
    audio_sample_rate: u32,
    io: ?std.Io,
) !void {
    _ = scale;
    _ = audio_sample_rate;
    _ = io;

    self.* = .{};
    // Alpha is set once here rather than every frame: `present` only ever
    // writes the three colour bytes of each pixel. Which leaves the picture
    // black and opaque until the first frame overwrites it.
    for (0..screen_width * screen_height) |i| self.framebuffer[i * 4 + 3] = 255;
    self.setTitle(window_title);
}

/// Nothing to release: the page owns the canvas and the audio graph, and the
/// wasm instance goes away with the tab.
pub fn deinit(self: *Web) void {
    _ = self;
}

pub fn setTitle(self: *Web, window_title: [:0]const u8) void {
    const len = @min(window_title.len, max_title);
    @memcpy(self.title[0..len], window_title[0..len]);
    self.title_len = len;
}

// --- Input ---------------------------------------------------------------

/// Hands over what the page has pushed in since the last call.
///
/// The console's own buttons are edge-triggered -- `App` acts on a press,
/// not on a hold -- so they are cleared as they are read. The controller
/// buttons are levels and are left alone, since holding one down means it
/// stays held for every frame until a keyup says otherwise.
pub fn pollInput(self: *Web) InputState {
    const state = self.pending;
    self.pending.console_button = null;
    self.pending.cycle_peripherals = false;
    return state;
}

// The page's side of the input seam. Each of these records what the user did
// into `pending`, which the next `pollInput` hands over and clears -- the
// inverse of the desktop backend's event drain, and the reason a browser can
// drive a loop it does not own.

/// Replaces one player's held buttons.
pub fn setButtons(self: *Web, player: usize, buttons: input.Buttons) void {
    if (player >= self.pending.players.len) return;
    self.pending.players[player] = buttons;
}

/// Replaces where the light gun is pointing. The page works in the canvas's
/// own pixels, which are the console's, so there is no scaling to undo here.
pub fn setGun(self: *Web, gun: input.Gun) void {
    self.pending.gun = gun;
}

/// Records a press of one of the console's own buttons.
pub fn pressConsoleButton(self: *Web, button: interface.ConsoleButton) void {
    self.pending.console_button = button;
}

/// Records a request to plug something else into the controller ports.
pub fn cyclePeripherals(self: *Web) void {
    self.pending.cycle_peripherals = true;
}

// --- Video ---------------------------------------------------------------

/// Converts the console's palette-index framebuffer to RGBA for the canvas,
/// and encodes the overlays for the page to draw on top.
///
/// A null framebuffer means there is no console yet, and leaves the pixels at
/// whatever they held before -- the page paints its own background in that
/// case, so there is nothing to do here but the overlay that explains it.
pub fn present(self: *Web, pixels: ?[]const Palette.Pixel, overlays: []const Overlay) !void {
    self.encodeOverlays(overlays);

    const framebuffer_pixels = pixels orelse return;
    std.debug.assert(framebuffer_pixels.len == screen_width * screen_height);
    // Alpha is untouched, which is why `init` can set it once; see there.
    Palette.expand(framebuffer_pixels, &self.framebuffer, 4);
}

/// Packs the overlay list into `overlay` as a run of blocks:
///
///     block := placement:u8, line_count:u8, line*
///     line  := byte_length:u16le, utf8_bytes
///
/// Length-prefixed rather than NUL-terminated because the page reads these
/// straight out of linear memory with a `TextDecoder`, which wants a range
/// and not a sentinel to hunt for.
///
/// An overlay that will not fit is dropped whole, so the page never sees half
/// a block. Losing a toast is not worth losing the frame it sat on.
fn encodeOverlays(self: *Web, overlays: []const Overlay) void {
    self.overlay_len = 0;
    for (overlays) |block| {
        std.debug.assert(block.lines.len <= std.math.maxInt(u8));

        var needed: usize = 2;
        for (block.lines) |line| needed += 2 + line.len;
        if (self.overlay_len + needed > self.overlay.len) continue;

        self.writeByte(@intFromEnum(block.placement));
        self.writeByte(@intCast(block.lines.len));
        for (block.lines) |line| {
            self.writeByte(@truncate(line.len));
            self.writeByte(@truncate(line.len >> 8));
            @memcpy(self.overlay[self.overlay_len..][0..line.len], line);
            self.overlay_len += line.len;
        }
    }
}

fn writeByte(self: *Web, byte: u8) void {
    self.overlay[self.overlay_len] = byte;
    self.overlay_len += 1;
}

/// Nothing to do: the page's `requestAnimationFrame` loop decides when the
/// next frame is due and calls in once it is. See `static/znes.js`.
pub fn paceFrame(self: *Web) void {
    _ = self;
}

// --- Audio ---------------------------------------------------------------

/// Hands mono f32 samples to the page, which forwards them to the audio
/// worklet's ring buffer.
pub fn queueAudio(self: *Web, samples: []const f32) !void {
    _ = self;
    if (samples.len == 0) return;
    host.queueAudio(samples.ptr, samples.len);
}

pub fn clearAudio(self: *Web) void {
    _ = self;
    host.clearAudio();
}

/// How many samples are queued but not yet played, which is what `App`'s
/// resampling feedback steers on. The page works this out from the audio
/// clock; see `static/znes.js` for why that is both necessary and enough.
pub fn queuedAudioSamples(self: *Web) usize {
    _ = self;
    return host.queuedAudioSamples();
}

// --- Battery saves -------------------------------------------------------

/// Which slot a save belongs in is decided by `save.zig`, the same way it is
/// on the desktop. All that differs here is where a slot lives: a
/// `localStorage` key rather than a file. The cost is a quota of a few
/// megabytes, which is thousands of saves.
pub fn loadBatteryRam(_: *Web, id: interface.SaveId, into: []u8) bool {
    const store: Store = .{};
    // Once per cartridge adopted, so the copy holds the save as it stood when
    // play started; one rolled on every write would hold the last second.
    host.saveKeepGeneration(id.name.ptr, id.name.len);
    return save.load(store, id, into);
}

pub fn storeBatteryRam(_: *Web, id: interface.SaveId, bytes: []const u8) void {
    const store: Store = .{};
    save.write(store, id, bytes);
}

/// The page's `localStorage`, in the shape `save.zig` asks for.
const Store = struct {
    pub fn read(_: Store, slot: []const u8, into: []u8) ?usize {
        const total = host.saveRead(slot.ptr, slot.len, into.ptr, into.len);
        return if (total == 0) null else total;
    }

    pub fn write(_: Store, slot: []const u8, bytes: []const u8) void {
        host.saveWrite(slot.ptr, slot.len, bytes.ptr, bytes.len);
    }

    pub fn rename(_: Store, from: []const u8, to: []const u8) void {
        host.saveRename(from.ptr, from.len, to.ptr, to.len);
    }

    pub fn iterate(_: Store) Iterator {
        return .{ .count = host.saveCount() };
    }

    const Iterator = struct {
        count: usize,
        index: usize = 0,
        name: [save.max_slot]u8 = undefined,

        pub fn next(self: *Iterator) ?[]const u8 {
            while (self.index < self.count) {
                const at = self.index;
                self.index += 1;
                const len = host.saveNameAt(at, &self.name, self.name.len);
                if (len == 0 or len > self.name.len) continue;
                return self.name[0..len];
            }
            return null;
        }

        /// Nothing to release: the page holds the snapshot, not this.
        pub fn close(_: *Iterator) void {}
    };
};

// --- Tests ---------------------------------------------------------------
//
// These run on the host, where the `host` externs are never reached, so only
// the parts that stay inside the module are exercised.

const testing = std.testing;

test "encodeOverlays packs a block per overlay, length-prefixed" {
    var self: Web = .{};
    const lines = [_][:0]const u8{ "ab", "cde" };
    self.encodeOverlays(&.{.{ .lines = &lines, .placement = .bottom_left }});

    // zig fmt: off
    try testing.expectEqualSlices(u8, &.{
        @intFromEnum(Overlay.Placement.bottom_left),
        2, // line count
        2, 0, 'a', 'b',
        3, 0, 'c', 'd', 'e',
    }, self.overlay[0..self.overlay_len]);
    // zig fmt: on
}

test "an overlay too big to fit is dropped whole, not truncated" {
    var self: Web = .{};
    const too_long: [overlay_capacity:0]u8 = @splat('x');
    const long_lines = [_][:0]const u8{&too_long};
    const short_lines = [_][:0]const u8{"ok"};

    self.encodeOverlays(&.{
        .{ .lines = &long_lines, .placement = .center },
        .{ .lines = &short_lines, .placement = .top_left },
    });

    // The one that fit is all that is there, and it starts at the top.
    // zig fmt: off
    try testing.expectEqualSlices(u8, &.{
        @intFromEnum(Overlay.Placement.top_left),
        1,
        2, 0, 'o', 'k',
    }, self.overlay[0..self.overlay_len]);
    // zig fmt: on
}

test "pollInput clears the console buttons but holds the controller ones" {
    var self: Web = .{};
    self.setButtons(0, .{ .a = true });
    self.pressConsoleButton(.reset);

    const first = self.pollInput();
    try testing.expectEqual(interface.ConsoleButton.reset, first.console_button);
    try testing.expectEqual(input.Buttons{ .a = true }, first.players[0]);

    // A press is an edge; a held button is a level.
    const second = self.pollInput();
    try testing.expectEqual(@as(?interface.ConsoleButton, null), second.console_button);
    try testing.expectEqual(input.Buttons{ .a = true }, second.players[0]);
}

test "setButtons ignores a player the console does not have" {
    var self: Web = .{};
    self.setButtons(input.player_count, .{ .a = true }); // must not trap
    for (self.pending.players) |buttons| {
        try testing.expectEqual(input.Buttons.none, buttons);
    }
}

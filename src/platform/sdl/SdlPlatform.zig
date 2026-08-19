// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! SDL3-backed platform: window, texture presentation, audio output, and
//! input from the keyboard and from gamepads. This is the only file in the
//! project that imports `sdl` directly. Its public surface deliberately never
//! mentions NES types (Nes/Ppu/Controller) -- it just takes a palette-index
//! framebuffer and mono f32 samples and hands back NES-button-shaped input --
//! so swapping this out for a different backend later doesn't ripple into the
//! emulation core, and swapping the emulation core for something else
//! wouldn't ripple into this file either.

const std = @import("std");
const Sdl3 = @This();
const sdl = @import("sdl");

const znes = @import("znes");
const Palette = znes.Palette;

const input = @import("input");
const interface = @import("interface");
const Saves = @import("saves.zig");

// The console's, not a choice made here: `present` is handed a framebuffer
// of exactly this size.
const screen_width = znes.screen_width;
const screen_height = znes.screen_height;

/// NTSC's frame rate. The console's, not the display's.
const nes_fps: f32 = @floatCast(znes.frame_rate);

/// How far a display's refresh rate may sit from a whole number of NES frames
/// and still be used to pace them. 2% takes in both 60.000 Hz and 59.94 Hz --
/// which are 0.16% and 0.26% off -- and turns away 144 Hz, whose closest
/// candidate is 20% out.
const refresh_tolerance = 0.02;

/// How far a stick has to leave centre before it counts as a direction.
/// Sticks rest noisily, and the console's d-pad has no in-between, so the
/// threshold sits well past the slack of a worn stick.
const stick_threshold: i16 = 8000;

/// Longest dropped path taken. Anything longer is ignored rather than
/// truncated -- a truncated path would name the wrong file, or none.
const max_drop_path = 4096;

/// Where battery saves go, under the OS's per-application data directory.
/// `org` should stay the same across an author's programs and `app` must never
/// change once chosen, since changing it orphans every save already written.
///
/// Most platforms nest the two, so this lands in `.../znes/znes/`. Leaving
/// `org` empty to flatten that does not work: SDL declines to name a directory
/// at all, and saving silently stops.
const save_org = "znes";
const save_app = "znes";
const InputState = interface.InputState;
const Overlay = interface.Overlay;

const init_flags = sdl.InitFlags{ .video = true, .audio = true, .events = true, .gamepad = true };

/// An opened gamepad and the instance id that identifies it in events. The
/// slot a pad sits in is the player it drives.
const Pad = struct {
    id: sdl.joystick.Id,
    handle: sdl.gamepad.Gamepad,
};

/// Where battery saves go. SDL names the directory; everything after that is
/// `saves.zig`'s business and has nothing to do with a window.
saves: Saves,
window: sdl.video.Window,
renderer: sdl.render.Renderer,
texture: sdl.render.Texture,
audio: sdl.audio.Stream,
frame_capper: sdl.extras.FramerateCapper(f32),
pads: [input.player_count]?Pad = @splat(null),
drop_path: [max_drop_path]u8 = undefined,
rgb_buffer: [screen_width * screen_height * 3]u8 = undefined,

pub fn init(
    self: *Sdl3,
    window_title: [:0]const u8,
    scale: u32,
    audio_sample_rate: u32,
    io: ?std.Io,
) !void {
    try sdl.init(init_flags);
    errdefer sdl.quit(init_flags);

    const window, const renderer = try sdl.render.Renderer.initWithWindow(
        window_title,
        screen_width * scale,
        screen_height * scale,
        .{
            .resizable = true,
            .high_pixel_density = true,
        },
    );
    // Registered in this order because `errdefer` runs in reverse: the renderer
    // has to go first, since destroying the window disposes of it too.
    errdefer window.deinit();
    errdefer renderer.deinit();

    try renderer.setLogicalPresentation(screen_width, screen_height, .letter_box);

    var frame_capper = sdl.extras.FramerateCapper(f32){ .mode = .{ .unlimited = {} } };
    configurePacing(window, renderer, &frame_capper);

    const texture = try renderer.createTexture(.array_rgb_24, .streaming, screen_width, screen_height);
    errdefer texture.deinit();
    try texture.setScaleMode(.nearest);

    const audio = try sdl.audio.Device.default_playback.openStream(
        .{ .format = .floating_32_bit, .num_channels = 1, .sample_rate = audio_sample_rate },
        void,
        null,
        null,
    );
    errdefer audio.deinit();
    try audio.resumeDevice();

    // Drop events are the whole of "open a ROM", so we ask for them
    // explicitly rather than trusting the backend's default.
    sdl.events.setEnabled(.drop_file, true);

    self.* = .{
        // Asked for once, here, because SDL creates the directory as a side
        // effect of naming it and there is no reason to do that per save.
        .saves = .{
            // Asked for once because SDL creates the directory as a side
            // effect of naming it, and there is no reason to do that per save.
            .dir = sdl.filesystem.getPrefPath(save_org, save_app) catch null,
            .io = io,
        },
        .window = window,
        .renderer = renderer,
        .texture = texture,
        .audio = audio,
        .frame_capper = frame_capper,
    };
}

pub fn deinit(self: *Sdl3) void {
    if (self.saves.dir) |dir| sdl.free(@constCast(dir));
    for (&self.pads) |*slot| {
        if (slot.*) |pad| pad.handle.deinit();
        slot.* = null;
    }
    self.audio.deinit();
    self.texture.deinit();
    self.renderer.deinit();
    self.window.deinit();
    sdl.quit(init_flags);
}

pub fn setTitle(self: *Sdl3, window_title: [:0]const u8) void {
    // A title that won't set is not worth failing a frame over.
    self.window.setTitle(window_title) catch {};
}

// --- Battery saves -------------------------------------------------------

pub fn loadBatteryRam(self: *Sdl3, id: interface.SaveId, into: []u8) bool {
    return self.saves.load(id, into);
}

pub fn storeBatteryRam(self: *Sdl3, id: interface.SaveId, bytes: []const u8) void {
    self.saves.store(id, bytes);
}

// --- Input ---------------------------------------------------------------

fn isHeld(keys: []const bool, code: sdl.Scancode) bool {
    const i = @intFromEnum(code);
    return i < keys.len and keys[i];
}

/// Player 1's keyboard mapping. Player 2 has none: a second player needs a
/// gamepad, since two people cannot share one keyboard's modifier keys
/// comfortably anyway.
fn keyboardButtons() input.Buttons {
    const keys = sdl.keyboard.getState();
    return .{
        .a = isHeld(keys, .z),
        .b = isHeld(keys, .x),
        .select = isHeld(keys, .right_shift),
        .start = isHeld(keys, .return_key),
        .up = isHeld(keys, .up),
        .down = isHeld(keys, .down),
        .left = isHeld(keys, .left),
        .right = isHeld(keys, .right),
    };
}

/// A gamepad's buttons, in NES terms.
///
/// The console's B sits left of its A, so they go on the west/south and
/// east/north halves of the face respectively: on an Xbox-style pad that is
/// A -> NES B and B -> NES A, which is the layout every other emulator
/// defaults to. Both sticks' worth of analogue is deliberately not read --
/// only the left one stands in for the d-pad.
fn padButtons(handle: sdl.gamepad.Gamepad) input.Buttons {
    const x = handle.getAxis(.left_x);
    const y = handle.getAxis(.left_y);
    return .{
        .a = handle.getButton(.east) or handle.getButton(.north),
        .b = handle.getButton(.south) or handle.getButton(.west),
        .select = handle.getButton(.back),
        .start = handle.getButton(.start),
        .up = handle.getButton(.dpad_up) or y <= -stick_threshold,
        .down = handle.getButton(.dpad_down) or y >= stick_threshold,
        .left = handle.getButton(.dpad_left) or x <= -stick_threshold,
        .right = handle.getButton(.dpad_right) or x >= stick_threshold,
    };
}

/// Takes the first free player slot for a newly connected pad. A pad that
/// arrives when both slots are taken is left closed, and picked up by a later
/// `gamepad_added` if one is ever re-plugged.
fn addPad(self: *Sdl3, id: sdl.joystick.Id) void {
    for (self.pads) |slot| {
        if (slot) |pad| if (pad.id.value == id.value) return; // already ours
    }
    const free = for (&self.pads) |*slot| {
        if (slot.* == null) break slot;
    } else return;
    free.* = .{ .id = id, .handle = sdl.gamepad.Gamepad.init(id) catch return };
}

fn removePad(self: *Sdl3, id: sdl.joystick.Id) void {
    for (&self.pads) |*slot| {
        const pad = slot.* orelse continue;
        if (pad.id.value != id.value) continue;
        pad.handle.deinit();
        slot.* = null;
    }
}

/// Drains the event queue and reads the live keyboard and gamepad state.
/// Call once per iteration of the main loop, before `paceFrame`.
pub fn pollInput(self: *Sdl3) InputState {
    var state: InputState = .{};
    var drop_len: usize = 0;

    while (sdl.events.poll()) |ev| switch (ev) {
        .quit, .terminating => state.quit = true,

        .key_down => |key| {
            if (key.repeat) continue;
            // Ctrl+R resets, Cmd+R too, since a Mac keyboard's Ctrl is not
            // where its user's hand is. Adding Shift makes it a cold boot.
            const command = key.mod.left_control or key.mod.right_control or
                key.mod.left_gui or key.mod.right_gui;
            const shift = key.mod.left_shift or key.mod.right_shift;
            if (command and key.scancode == .r) {
                state.console_button = if (shift) .power else .reset;
            }
            // Nothing on a cartridge says whether it wants a Zapper, so
            // plugging one in is a key rather than a guess.
            if (command and key.scancode == .z) state.cycle_peripherals = true;
        },

        .drop_file => |drop| {
            // SDL reclaims the event's string once the event loop moves on,
            // so it is copied here rather than borrowed.
            if (drop.file_name.len == 0 or drop.file_name.len > self.drop_path.len) continue;
            @memcpy(self.drop_path[0..drop.file_name.len], drop.file_name);
            drop_len = drop.file_name.len;
        },

        .gamepad_added => |dev| self.addPad(dev.id),
        .gamepad_removed => |dev| self.removePad(dev.id),

        // Dragged onto another monitor, or the same one had its refresh rate
        // changed underneath us: whichever clock was right before may not be
        // the right one now.
        .window_display_changed => configurePacing(self.window, self.renderer, &self.frame_capper),

        else => {},
    };

    if (drop_len != 0) state.dropped_path = self.drop_path[0..drop_len];

    state.players[0] = keyboardButtons();
    for (self.pads, 0..) |slot, player| {
        const pad = slot orelse continue;
        state.players[player] = state.players[player].merge(padButtons(pad.handle));
    }
    state.gun = self.gunState();
    return state;
}

/// Where a light gun would be pointing, taken from the mouse.
///
/// The renderer's logical presentation *is* the console's 256x240, so SDL has
/// already done the letterbox arithmetic: a pointer on the black bars comes
/// back outside that range rather than clamped to its edge. That distinction
/// is the whole of "pointed away from the screen", which games check for.
fn gunState(self: *Sdl3) input.Gun {
    const buttons, const window_x, const window_y = sdl.mouse.getState();
    const point = self.renderer.renderCoordinatesFromWindowCoordinates(
        .{ .x = window_x, .y = window_y },
    ) catch return .none;

    // Squeezing the trigger while pointed off the screen is a deliberate
    // miss, so the button survives being off the picture even though the
    // position does not.
    if (point.x < 0 or point.x >= screen_width or point.y < 0 or point.y >= screen_height) {
        return .{ .trigger = buttons.left };
    }
    return .{
        .x = @intFromFloat(point.x),
        .y = @intFromFloat(point.y),
        .on_screen = true,
        .trigger = buttons.left,
    };
}

/// Decides what paces the main loop, and sets both halves of the answer.
///
/// VSync is the better clock when the display can actually deliver NTSC's
/// rate: one NES frame per refresh on a 60 Hz panel, one per two refreshes on
/// a 120 Hz one, and so on. It costs nothing, it cannot tear, and it keeps the
/// emulator locked to the same clock the picture is drawn on.
///
/// It is the *wrong* clock everywhere else. On a 144 Hz panel no whole number
/// of refreshes lands anywhere near a frame -- two is 72 fps, three is 48 --
/// so syncing to it runs the console at 120% or 80% speed, with the audio
/// resampler unable to follow (it may bend the rate by 1%, not 20%). Worse,
/// the two cannot be combined: a software cap on top of vsync only ever
/// pushes each frame out to the *next* refresh, so 144 Hz plus a 60 fps cap
/// gives 48 fps rather than 60. So on those displays vsync goes off entirely
/// and the frame capper keeps time on its own, tearing and all.
fn configurePacing(
    window: sdl.video.Window,
    renderer: sdl.render.Renderer,
    capper: *sdl.extras.FramerateCapper(f32),
) void {
    if (vsyncInterval(window)) |interval| {
        if (renderer.setVSync(.{ .on_each_num_refresh = interval })) |_| {
            capper.mode = .{ .unlimited = {} };
            return;
        } else |_| {}
    }
    renderer.setVSync(null) catch {};
    capper.mode = .{ .limited = nes_fps };
}

/// How many refreshes of the display this window is on make one NES frame,
/// or null if no small whole number of them does.
fn vsyncInterval(window: sdl.video.Window) ?usize {
    const display = window.getDisplayForWindow() catch return null;
    const mode = display.getCurrentMode() catch return null;
    const hz = mode.refresh_rate orelse return null;

    // Past four the interval stops being worth having: a display that fast
    // can afford to be driven without vsync, and the deeper the division the
    // likelier a false match.
    for (1..5) |interval| {
        const fps = hz / @as(f32, @floatFromInt(interval));
        if (@abs(fps - nes_fps) / nes_fps < refresh_tolerance) return interval;
    }
    return null;
}

/// Blocks (via VSync, or the software cap where VSync is the wrong clock) to
/// pace the main loop to roughly NTSC's ~60.0988 fps.
pub fn paceFrame(self: *Sdl3) void {
    _ = self.frame_capper.delay();
}

// --- Video ---------------------------------------------------------------

/// What fills the window when there is no ROM to show. Not black, so an
/// empty emulator is visibly running rather than visibly broken.
const idle_background = sdl.pixels.Color{ .r = 24, .g = 24, .b = 32, .a = 255 };

/// What surrounds the picture when there is one. The letterbox bars belong
/// to the console's aspect ratio, not to the app, so they stay out of the way.
const letterbox = sdl.pixels.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };

/// Uploads a 256x240 framebuffer of `Palette.Pixel` (palette index plus the
/// emphasis bits that were in force at that pixel) and presents it, scaled to
/// fit the window with letterboxing, with `overlays` drawn on top.
///
/// A null framebuffer means there is nothing to show yet -- no ROM loaded --
/// and leaves the overlays on an empty background.
pub fn present(self: *Sdl3, pixels: ?[]const Palette.Pixel, overlays: []const Overlay) !void {
    try self.renderer.setDrawColor(if (pixels == null) idle_background else letterbox);
    try self.renderer.clear();

    if (pixels) |framebuffer| {
        std.debug.assert(framebuffer.len == screen_width * screen_height);
        Palette.expand(framebuffer, &self.rgb_buffer, 3);
        try self.texture.update(null, &self.rgb_buffer, screen_width * 3);
        try self.renderer.renderTexture(self.texture, null, null);
    }

    for (overlays) |overlay| try self.drawOverlay(overlay);
    try self.renderer.present();
}

const char_size: f32 = @floatFromInt(sdl.render.debug_text_font_character_size);
const line_height: f32 = char_size + 2;
const margin: f32 = 6;

fn drawOverlay(self: *Sdl3, overlay: Overlay) !void {
    if (overlay.lines.len == 0) return;
    const block_height = @as(f32, @floatFromInt(overlay.lines.len)) * line_height;

    var y: f32 = switch (overlay.placement) {
        .top_left => margin,
        .bottom_left => screen_height - margin - block_height,
        .center => (screen_height - block_height) / 2,
    };

    for (overlay.lines) |line| {
        const x: f32 = switch (overlay.placement) {
            .top_left, .bottom_left => margin,
            .center => (screen_width - @as(f32, @floatFromInt(line.len)) * char_size) / 2,
        };
        // A drop shadow, because the text has to stay readable over whatever
        // the game happens to be drawing underneath it.
        try self.renderer.setDrawColor(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
        try self.renderer.renderDebugText(.{ .x = x + 1, .y = y + 1 }, line);
        try self.renderer.setDrawColor(.{ .r = 255, .g = 255, .b = 255, .a = 255 });
        try self.renderer.renderDebugText(.{ .x = x, .y = y }, line);
        y += line_height;
    }
}

// --- Audio ---------------------------------------------------------------

/// Queues mono f32 samples for playback. Safe to call with a fresh batch
/// once per video frame.
pub fn queueAudio(self: *Sdl3, samples: []const f32) !void {
    try self.audio.putData(std.mem.sliceAsBytes(samples));
}

/// Throws away everything queued but not yet played. The caller does this
/// when the console it was feeding is no longer the one being listened to --
/// a ROM change, a reset -- so the old console's tail doesn't play over the
/// new one's opening.
pub fn clearAudio(self: *Sdl3) void {
    self.audio.clear() catch {};
}

/// How many samples are queued but not yet played. The caller needs this
/// to keep production and playback in step: the main loop is paced by the
/// display, whose refresh rate is not the audio device's clock divided by
/// the samples-per-frame, so without feedback the queue drifts until it
/// runs dry and the device plays silence between batches.
pub fn queuedAudioSamples(self: *Sdl3) usize {
    const bytes = self.audio.getQueued() catch return 0;
    return bytes / @sizeOf(f32);
}

// --- Tests ---------------------------------------------------------------
//
// Nothing here is testable without a window and an audio device, and a test
// that needed those would say more about the machine running it than about
// this file. The one part that was plain Zig -- the battery-save rules --
// lives in `saves.zig` and is tested there.

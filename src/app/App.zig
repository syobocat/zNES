// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! The application: one screen, at most one loaded ROM, and everything that
//! has to happen to get from one frame to the next.
//!
//! The console is optional here: the screen, the audio device and the event
//! loop have nothing to do with which cartridge is in the slot. Holding the
//! session behind a pointer that may be null is what lets the app start empty,
//! take a ROM by drag-and-drop, and swap it for another one without tearing
//! anything down.
//!
//! Where the input for a frame comes from is `tick`'s only real branch: a
//! movie being replayed supplies it instead of the keyboard and gamepads, and
//! can also press the console's own reset and power buttons.
//!
//! **Nothing here reads a file, and nothing here owns the loop.** Both are
//! platform-shaped: a desktop drop hands over a path to read, a browser drop
//! hands over the bytes directly, and a browser cannot be made to sit in a
//! `while (true)` at all. So the platform's `main` runs the loop and turns
//! whatever it was given into bytes, and calls `open` or `openDropped` with
//! them; `tick` is one iteration of the loop, not the loop itself.

const std = @import("std");
const App = @This();
const Allocator = std.mem.Allocator;

const znes = @import("znes");

const Platform = @import("platform");
const Session = @import("Session.zig");
const Movie = @import("Movie.zig");
const Osd = @import("Osd.zig");
const AudioClock = @import("AudioClock.zig");
const input = @import("input");
const interface = @import("interface");

// The platform is duck-typed -- `build.zig` binds the name to whichever
// backend this build uses -- so nothing else would notice a backend that had
// drifted out of shape until that backend's own build was attempted. This
// turns that into a compile error here, in the file whose expectations it is.
comptime {
    interface.verify(Platform);
}

const window_title = "znes";
const default_scale: u32 = 2;
/// The rate `queueAudio` is handed samples at. Public because the web page
/// has to open its audio device at the same rate and cannot ask for one.
pub const audio_sample_rate = AudioClock.sample_rate;

/// How long to wait after cartridge RAM changes before writing the save out,
/// in frames.
///
/// A game writes its save as a burst of stores -- a checksum pass over a whole
/// save slot is hundreds of them across a few frames -- and waiting turns the
/// burst into one file. A second is short enough that closing the window right
/// after saving still keeps it, and long enough that a game which touches its
/// RAM every frame (some use it as scratch) is not writing a file every frame.
///
/// The wait is *not* extended by further writes: it is a deadline set when the
/// RAM first goes dirty, so a game holding it dirty forever still gets saved
/// once a second rather than never.
const save_delay_frames: u32 = 60;

pub const Options = struct {
    /// How the platform reaches the filesystem, when it has one to reach.
    ///
    /// Passed straight through: nothing in this file touches a file, and the
    /// only thing that wants one is the desktop backend's battery-save
    /// storage. A browser build leaves it null and keeps its saves somewhere a
    /// browser can reach instead.
    io: ?std.Io = null,
    /// Which record a movie starts on, overriding the format's own answer
    /// (`Movie.startFrame`). Only worth touching if a movie plays back a
    /// frame or two out of step; see `Movie.fceux_dead_frames` for what the
    /// number compensates for and why it is what it is.
    replay_offset: ?usize = null,
    /// What to plug into the controller ports at startup. Nothing on a
    /// cartridge says which peripheral it wants, so this is the answer until
    /// the player says otherwise or a movie does.
    peripherals: znes.Nes.Peripherals = .standard,
};

pub const Error = error{
    /// A movie was named without a ROM to play it against.
    NoRomLoaded,
    /// The file is neither a ROM nor a movie this build understands.
    UnrecognizedFile,
};

gpa: Allocator,
platform: Platform,
session: ?*Session = null,
playback: ?Movie.Playback = null,
/// `Options.replay_offset`, kept because a movie can also arrive by being
/// dropped on the window long after the command line is gone.
replay_offset: ?usize = null,
/// What is currently plugged into the ports. Kept here rather than only in
/// the session, so that an adapter stays plugged in across loading another
/// ROM -- which is what happens on a real desk.
peripherals: znes.Nes.Peripherals = .standard,
/// What was plugged in before a replay took the ports over, so that ending
/// one puts it back. A movie borrows the ports for as long as it plays; it
/// does not get to unplug the player's Zapper for good.
peripherals_before_playback: ?znes.Nes.Peripherals = null,

/// Frames left before the pending battery save is written, or null when there
/// is nothing to write. See `save_delay_frames`.
save_countdown: ?u32 = null,

/// Resampling to the audio device's rate, and the feedback that keeps its
/// queue at a steady depth.
audio: AudioClock = .init,

title_buf: [256:0]u8 = undefined,
/// The text drawn over the picture, and the storage it points into.
osd: Osd = .init,

/// Brings up the screen and the audio device, with nothing loaded.
///
/// The caller opens whatever the user asked for -- see `open` -- and then
/// drives `tick` for as long as the app should keep running.
///
/// **Initialises in place rather than returning a value.** A backend can be
/// large -- the SDL one carries a framebuffer's worth of scratch -- and an
/// `App` holds one inline, so returning by value would copy the whole thing
/// out of this frame and put it on the caller's stack on the way past. It also
/// means a backend's buffers keep the address they were constructed at, which
/// is what lets one hand raw pointers to something outside the program.
pub fn init(self: *App, gpa: Allocator, options: Options) !void {
    self.* = .{
        .gpa = gpa,
        .platform = undefined,
        .replay_offset = options.replay_offset,
        .peripherals = options.peripherals,
    };
    try self.platform.init(window_title, default_scale, audio_sample_rate, options.io);
    self.updateTitle();
    self.primeAudio();
}

pub fn deinit(self: *App) void {
    // Before the platform goes, since it owns the storage the save goes to.
    self.flushSave();
    if (self.playback) |*playback| playback.deinit(self.gpa);
    if (self.session) |session| session.deinit(self.gpa);
    self.audio.deinit(self.gpa);
    self.platform.deinit();
}

// --- The loop ------------------------------------------------------------

/// What the platform has to say about this iteration: which buttons are
/// held, whether the console's own buttons were pressed, and whether the
/// user is done. The caller acts on anything platform-shaped in here -- a
/// dropped file it has to go and read, a window that has been closed --
/// before handing the rest to `tick`.
pub fn pollInput(self: *App) interface.InputState {
    return self.platform.pollInput();
}

/// One iteration: run a frame if there is a console to run, put it on the
/// screen, and keep the audio queue fed.
pub fn tick(self: *App, state: interface.InputState) !void {
    if (state.console_button) |button| self.pressConsoleButton(button);
    if (state.cycle_peripherals) self.cyclePeripherals();

    if (self.session) |session| {
        // The gun comes from the mouse even under a replay, since no movie
        // format this parses carries one. It reaches nothing unless a Zapper
        // is plugged in, and a replay decides that for itself -- so a live
        // hand on the mouse cannot desync one.
        session.applyInput(self.frameInput(state), state.gun);
        try self.runFrame(session);
        self.trackSave(session);
        try self.platform.present(&session.nes.ppu.framebuffer, self.overlays());
        try self.platform.queueAudio(self.audio.frame());
    } else {
        try self.platform.present(null, self.overlays());
    }

    self.osd.tick();
    self.platform.paceFrame();
}

/// What is plugged into the controller ports, in the order the key that
/// changes it walks them.
///
/// There is nothing to detect here -- a cartridge cannot say whether it wants
/// a gun -- so this is a switch the player flips, and the toast is how they
/// find out what they flipped it to.
fn cyclePeripherals(self: *App) void {
    const session = self.session orelse {
        self.setToast("no ROM loaded", .{});
        return;
    };
    // A switch rather than a table walk, so that adding a peripheral is a
    // compile error here instead of one silently missing from the cycle.
    const next: znes.Nes.Peripherals, const label = switch (session.peripherals()) {
        .standard => .{ .zapper, "controller + Zapper" },
        .zapper => .{ .standard, "2 controllers" },
    };
    self.peripherals = next;
    session.setPeripherals(next);
    self.setToast("ports: {s}", .{label});
}

/// The buttons the console sees this frame. A replay in progress supplies
/// them -- and its console commands -- in place of whatever is being held.
fn frameInput(self: *App, state: interface.InputState) input.Ports {
    const playback = if (self.playback) |*p| p else return state.players;
    const frame = playback.next() orelse {
        self.setToast("replay finished", .{});
        self.stopPlayback();
        return state.players;
    };
    // FDS and VS. System commands are parsed but have nothing to drive here.
    // FCEUX runs these at the top of the frame too, and the frame carrying
    // one is a whole frame there, so it has to be a whole one here.
    if (frame.commands.power) {
        self.session.?.powerCycle();
        self.session.?.alignToFrame();
    } else if (frame.commands.soft_reset) {
        self.session.?.reset();
        self.session.?.alignToFrame();
    }
    return frame.ports;
}

/// Hands each of the console's CPU cycles to the audio clock, which decides
/// which of them become samples.
const AudioSink = struct {
    app: *App,
    rate: f64,

    pub fn cycle(self: AudioSink, nes: *znes.Nes) !void {
        try self.app.audio.cycle(self.app.gpa, self.rate, nes.apu.takeSample());
    }
};

/// Runs the console forward exactly one video frame, recording its audio.
fn runFrame(self: *App, session: *Session) !void {
    const sink: AudioSink = .{
        .app = self,
        .rate = self.audio.rateFor(self.platform.queuedAudioSamples()),
    };
    self.audio.beginFrame();
    try session.runFrame(sink);
}

/// Refills the device's queue with the head start the feedback assumes, which
/// is wanted whenever the console being listened to changes.
fn primeAudio(self: *App) void {
    self.platform.clearAudio();
    self.platform.queueAudio(self.audio.prime(self.gpa)) catch {};
}

// --- Battery saves -------------------------------------------------------

/// Which cartridge a save belongs to. The name is where a platform looks
/// first; the fingerprint is what settles it when the ROM has been renamed,
/// or when two of them share a name.
fn saveId(session: *const Session) interface.SaveId {
    return .{ .name = session.name(), .fingerprint = session.fingerprint };
}

/// Notices that cartridge RAM changed and writes it out once the wait is up.
/// See `save_delay_frames`.
fn trackSave(self: *App, session: *Session) void {
    // Only the *first* dirty frame arms the countdown, so a game that keeps
    // its RAM dirty cannot push the write out forever.
    if (session.takeBatteryRamDirty() and self.save_countdown == null) {
        self.save_countdown = save_delay_frames;
    }
    const left = self.save_countdown orelse return;
    if (left > 0) self.save_countdown = left - 1 else self.flushSave();
}

/// Writes the pending save out now, if there is one. Called on the way out and
/// whenever the console being played changes, so that a save is never lost to
/// the wait it was sitting in.
fn flushSave(self: *App) void {
    if (self.save_countdown == null) return;
    self.save_countdown = null;
    const session = self.session orelse return;
    const ram = session.batteryRam();
    if (ram.len == 0) return;
    self.platform.storeBatteryRam(saveId(session), ram);
}

/// Restores a newly booted cartridge's save, if the board has a battery and
/// the platform has a file for it.
///
/// Done before the console runs a single frame: a game reads its save during
/// its own boot, and one that finds scratch there offers to start a new file.
fn restoreSave(self: *App, session: *Session) void {
    const ram = session.batteryRam();
    if (ram.len == 0) return;
    // The platform fills the cartridge's RAM in place, and only reports
    // success if it filled the whole thing -- so there is no staging buffer
    // here sized for the largest board imaginable, and a save of the wrong
    // length never reaches the cartridge at all.
    if (!self.platform.loadBatteryRam(saveId(session), ram)) return;
    // Filling it that way bypasses the cartridge's write path, so it does not
    // mark the save dirty. Clearing the flag anyway covers the boot writes
    // that happened before this ran: writing back what was just read is not
    // worth a file.
    _ = session.takeBatteryRamDirty();
}

// --- Loading -------------------------------------------------------------

/// Opens a file the user handed over while the app was running -- dropped on
/// the window, picked from a file dialog -- reporting failure on screen
/// rather than propagating it. An emulator that quit because you dropped the
/// wrong file on it would be a poor one.
pub fn openDropped(self: *App, name: []const u8, bytes: []const u8) void {
    self.open(name, bytes) catch |err| {
        self.setToast("{s}: {s}", .{ name, @errorName(err) });
    };
}

/// Opens a file: a ROM boots, a movie starts replaying, and anything else is
/// rejected. `name` is the file's own name without any directory, used to
/// guess a format and to label the window; `bytes` are borrowed only for the
/// duration of the call, and a ROM is copied out of them.
///
/// Copying rather than adopting is what lets the caller hand over a stack
/// buffer, a staging area it means to reuse, or memory it does not own --
/// which between them covers every way a file reaches us on either platform.
pub fn open(self: *App, name: []const u8, bytes: []const u8) !void {
    if (looksLikeRom(name, bytes)) return self.openRom(name, bytes);
    if (Movie.Format.detect(name, bytes) != null) return self.startMovie(name, bytes);
    return Error.UnrecognizedFile;
}

/// A ROM is known by its header magic. The extension only gets a say for
/// files that fail that test, so that a mis-named image still boots and a
/// mis-named movie still plays.
fn looksLikeRom(name: []const u8, bytes: []const u8) bool {
    if (std.mem.startsWith(u8, bytes, "NES\x1a")) return true;
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(name), ".nes");
}

fn openRom(self: *App, name: []const u8, bytes: []const u8) !void {
    const owned = try self.gpa.dupe(u8, bytes);
    errdefer self.gpa.free(owned);
    try self.adoptRom(name, owned);
}

/// Boots `bytes`, taking ownership of it, and retires whatever was running.
fn adoptRom(self: *App, name: []const u8, bytes: []u8) !void {
    const session = try Session.adopt(self.gpa, name, bytes);

    // The movie that was playing was recorded against the old cartridge.
    // Before reading `peripherals`, since ending a replay hands the ports back.
    self.stopPlayback();
    session.setPeripherals(self.peripherals);
    // The outgoing cartridge's save goes with it, while its RAM is still here.
    // Before `restoreSave`, not after: saves are keyed by ROM name, so reloading
    // the same ROM would otherwise boot the new console from the pre-flush file
    // and only then write the pending one over the top.
    self.flushSave();
    if (self.session) |old| old.deinit(self.gpa);
    self.session = session;

    // Before the first frame: the game reads its save while booting.
    self.restoreSave(session);
    session.alignToFrame(); // power-on leaves a stub of a picture in progress

    self.updateTitle();
    self.primeAudio();
    self.setToast("{s}", .{session.name()});
}

/// Starts replaying `bytes` against the running console, from power-on --
/// which is the state the movie was recorded from.
fn startMovie(self: *App, name: []const u8, bytes: []const u8) !void {
    const session = self.session orelse return Error.NoRomLoaded;
    const movie = try Movie.parse(self.gpa, name, bytes);

    self.stopPlayback();
    self.playback = .{
        .movie = movie,
        .frame = self.replay_offset orelse movie.startFrame(),
    };

    // No movie format parsed here carries a light gun, so a replay always
    // wants the two pads it was recorded with. `stopPlayback` above has
    // already put back anything an earlier replay borrowed, so this is the
    // player's own choice being saved.
    self.peripherals_before_playback = self.peripherals;
    self.peripherals = .standard;
    session.setPeripherals(self.peripherals);

    session.powerCycle();
    session.alignToFrame();

    self.updateTitle();
    self.primeAudio();

    if (movie.warnings.pal) {
        self.setToast("PAL movie on an NTSC core: expect desync", .{});
    } else if (movie.warnings.fourscore) {
        self.setToast("four score movie: replaying ports 1-2 only", .{});
    } else if (movie.warnings.reset_timing) {
        self.setToast("mid-frame reset timing: expect desync", .{});
    } else {
        self.setToast("replaying {d} frames", .{movie.frames.len});
    }
}

fn stopPlayback(self: *App) void {
    if (self.playback) |*playback| playback.deinit(self.gpa);
    self.playback = null;
    if (self.peripherals_before_playback) |before| {
        self.peripherals = before;
        self.peripherals_before_playback = null;
        if (self.session) |session| session.setPeripherals(before);
    }
    self.updateTitle();
}

/// Presses one of the console's own buttons.
///
/// Either one ends a replay: from here on the movie's input was recorded
/// against a machine whose state you have just changed out from under it, so
/// carrying on would only play back nonsense.
fn pressConsoleButton(self: *App, button: interface.ConsoleButton) void {
    self.stopPlayback();
    const session = self.session orelse return;
    switch (button) {
        .power => session.powerCycle(),
        .reset => session.reset(),
    }
    session.alignToFrame();
    self.primeAudio();
    self.setToast("{s}", .{switch (button) {
        .power => "power cycle",
        .reset => "reset",
    }});
}

// --- On-screen text ------------------------------------------------------

/// This frame's overlays. `Osd` owns the text and the storage; this only
/// tells it what the app is currently doing.
fn overlays(self: *App) []const interface.Overlay {
    const replay: ?Osd.ReplayPosition = if (self.playback) |playback|
        .{ .frame = playback.frame, .total = playback.total() }
    else
        null;
    return self.osd.list(self.session == null, replay);
}

/// Puts a short message on screen for a few seconds. Public because the
/// platform's own failures -- a path it could not read, say -- deserve the
/// same treatment as the ones the app finds for itself.
pub fn setToast(self: *App, comptime fmt: []const u8, args: anytype) void {
    self.osd.setToast(fmt, args);
}

fn updateTitle(self: *App) void {
    const title = if (self.session) |session|
        std.fmt.bufPrintZ(&self.title_buf, "{s} - {s}{s}", .{
            window_title,
            session.name(),
            if (self.playback != null) " [replay]" else "",
        }) catch window_title
    else
        window_title;
    self.platform.setTitle(title);
}

// --- Tests ---------------------------------------------------------------

test {
    _ = @import("tests/replay_timing.zig");
    _ = Session;
    _ = Movie;
    _ = Osd;
    _ = AudioClock;
    _ = input;
}

//! A recorded input movie, and the cursor that plays one back.
//!
//! A movie is a list of per-frame controller states plus the occasional
//! console-level command (reset, power cycle). Playing one back is just the
//! main loop taking its buttons from here instead of from the keyboard, so
//! everything format-specific ends its life at the parser: whatever the file
//! looked like, what comes out is `[]Frame`.
//!
//! Two formats are parsed: FCEUX's `.fm2` text movies (`movie/fm2.zig`),
//! which `.fm3` project files share an input log with, and BizHawk's `.bk2`
//! archives (`movie/bk2.zig`). Adding another means writing one more parser
//! that produces a `Movie` and adding a case to `Format.detect`; nothing
//! outside this directory has to change.
//!
//! **A movie assumes it starts from power-on.** Movies that resume from a
//! savestate are rejected rather than played from the wrong state, and even
//! a from-power-on movie only stays in sync for as long as this emulator
//! agrees with the one that recorded it -- which makes desync a useful
//! accuracy signal, not a bug in the player.

const std = @import("std");
const Movie = @This();
const Allocator = std.mem.Allocator;

const input = @import("input");
const bk2 = @import("movie/bk2.zig");
const fm2 = @import("movie/fm2.zig");

pub const Format = enum {
    /// FCEUX text movie. `.fm3`, the TAS Editor project file, wraps the same
    /// header and input log in extra sections and is parsed by the same code.
    fm2,
    /// BizHawk movie: a zip archive around a text input log.
    bk2,

    /// Guesses a movie's format from its name, falling back to its contents
    /// for files that arrive with an unhelpful extension (or none at all,
    /// which is what a drag-and-drop can hand us).
    pub fn detect(path: []const u8, bytes: []const u8) ?Format {
        const ext = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(ext, ".fm2") or std.ascii.eqlIgnoreCase(ext, ".fm3")) return .fm2;
        if (std.ascii.eqlIgnoreCase(ext, ".bk2")) return .bk2;
        if (fm2.looksLikeFm2(bytes)) return .fm2;
        if (bk2.looksLikeBk2(bytes)) return .bk2;
        return null;
    }
};

/// The console-level commands a movie can carry alongside its buttons. The
/// bit assignment is FCEUX's, which every other format's commands are mapped
/// onto rather than the other way round -- picking one and converting into
/// it is what keeps `Playback` format-agnostic.
pub const Commands = packed struct(u8) {
    /// The reset button.
    soft_reset: bool = false,
    /// The power switch.
    power: bool = false,
    /// Famicom Disk System: swap the inserted disk. Not modeled by the core.
    fds_insert: bool = false,
    /// Famicom Disk System: select a disk side. Not modeled by the core.
    fds_select: bool = false,
    /// VS. System: insert a coin. Not modeled by the core.
    vs_insert_coin: bool = false,
    _unused: u3 = 0,
};

pub const Frame = struct {
    commands: Commands = .{},
    ports: input.Ports = input.no_input,
};

/// Things about a movie that will make playback diverge but are not reason
/// enough to refuse it. The app surfaces these so a desync isn't a mystery.
pub const Warnings = struct {
    /// The movie was recorded on a PAL console. This core is NTSC-only, so
    /// the frame rate and CPU/PPU ratio are both wrong for it.
    pal: bool = false,
    /// The movie drives a Four Score's four controllers. Only the first two
    /// are replayed, since the console has two ports and nothing to put
    /// across them.
    fourscore: bool = false,
    /// The movie asks for a reset at a particular cycle *within* a frame,
    /// which the player can only do on a frame boundary. The console can tell
    /// the difference, so a movie that uses this will drift from here on.
    reset_timing: bool = false,

    pub fn any(self: Warnings) bool {
        return self.pal or self.fourscore or self.reset_timing;
    }
};

/// How many of an FCEUX movie's opening records belong to frames this console
/// does not have.
///
/// FCEUX holds its PPU dead for two frames after power-on, running the CPU
/// with the PPU switched off entirely -- no VBlank flag, no NMI -- before
/// emulating its first real frame. It consumes an input record for each of
/// those frames anyway.
///
/// This core has no such state: its first VBlank arrives on its first frame,
/// so a game gets through the `BIT $2002 / BPL` wait its boot code opens with
/// two records earlier than it did on FCEUX, and every record after that
/// lands two frames early. Dropping the two is what lines the two emulators
/// back up, and nothing is lost with them -- a game cannot read a controller
/// during a frame it spends waiting for a VBlank that never arrives.
pub const fceux_dead_frames = 2;

pub const ParseError = fm2.ParseError || bk2.ParseError || error{UnknownMovieFormat};

format: Format,
/// One entry per frame, in order. Owned; freed by `deinit`.
frames: []const Frame,
warnings: Warnings,

/// Parses `bytes` as a movie. `path` is only used to pick a format, and may
/// be anything the file was called; the contents get the final say when the
/// name is uninformative.
pub fn parse(gpa: Allocator, path: []const u8, bytes: []const u8) ParseError!Movie {
    const format = Format.detect(path, bytes) orelse return error.UnknownMovieFormat;
    return switch (format) {
        .fm2 => fm2.parse(gpa, bytes),
        .bk2 => bk2.parse(gpa, bytes),
    };
}

pub fn deinit(self: *Movie, gpa: Allocator) void {
    gpa.free(self.frames);
    self.* = undefined;
}

/// The record playback should start on, which is not always the first one:
/// see `fceux_dead_frames`.
pub fn startFrame(self: Movie) usize {
    return switch (self.format) {
        .fm2 => @min(fceux_dead_frames, self.frames.len),
        // BizHawk's NES core has no dead-PPU frames to skip, so its first
        // record is its first frame. Unlike the fm2 figure, which came out of
        // FCEUX's source and was then confirmed against real movies, this one
        // is only an absence of any reason to skip anything -- if a bk2 plays
        // back a frame or two out of step, `--replay-offset` is the knob.
        .bk2 => 0,
    };
}

/// A movie plus the position it has been played to.
pub const Playback = struct {
    movie: Movie,
    /// The frame `next` will return, i.e. how many frames have been played.
    frame: usize = 0,

    pub fn deinit(self: *Playback, gpa: Allocator) void {
        self.movie.deinit(gpa);
        self.* = undefined;
    }

    /// The next frame's input, or null once the movie has run out. The
    /// caller advances the console by exactly one frame per call.
    pub fn next(self: *Playback) ?Frame {
        if (self.frame >= self.movie.frames.len) return null;
        defer self.frame += 1;
        return self.movie.frames[self.frame];
    }

    pub fn total(self: *const Playback) usize {
        return self.movie.frames.len;
    }
};

// --- Tests ---------------------------------------------------------------

test {
    _ = bk2;
    _ = fm2;
    _ = input;
}

test "detect falls back to sniffing when the extension says nothing" {
    const body = "version 3\nport0 1\n|0|........|........||\n";
    try std.testing.expectEqual(Format.fm2, Format.detect("movie.fm2", "").?);
    try std.testing.expectEqual(Format.fm2, Format.detect("MOVIE.FM3", "").?);
    try std.testing.expectEqual(Format.fm2, Format.detect("movie", body).?);
    try std.testing.expectEqual(@as(?Format, null), Format.detect("rom.nes", "NES\x1a"));
}

test "playback walks the movie once and then reports the end" {
    const gpa = std.testing.allocator;
    var movie = try Movie.parse(gpa, "t.fm2", "|0|R.......|........||\n|1|........|........||\n");
    var playback: Playback = .{ .movie = movie };
    defer playback.deinit(gpa);
    movie = undefined; // owned by `playback` now

    try std.testing.expectEqual(@as(usize, 2), playback.total());
    try std.testing.expect(playback.next().?.ports[0].right);
    try std.testing.expect(playback.next().?.commands.soft_reset);
    try std.testing.expectEqual(@as(?Frame, null), playback.next());
}

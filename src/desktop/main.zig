// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! Desktop entry point: parses the command line, runs the loop, and is the
//! only place in the desktop build that touches the filesystem.
//!
//! Every argument is optional. `znes` on its own opens an empty window that
//! waits for a ROM to be dropped on it, which is also how a second ROM gets
//! loaded later, so nothing here is on the critical path for using the thing.
//!
//! `App` deals in bytes, not paths -- see its header for why -- so turning a
//! path into bytes is this file's job, whether the path came from the command
//! line or from a file dropped on the window.

const std = @import("std");
const Allocator = std.mem.Allocator;

const App = @import("app");

/// Ceiling on any file that gets read: big enough for the largest NES 2.0
/// image and for a movie of any length anyone has actually recorded.
const max_file_bytes = 16 * 1024 * 1024;

const usage =
    \\usage: znes [rom.nes] [options]
    \\
    \\options:
    \\  --replay FILE       replay an input movie (.fm2 or .bk2) from power-on
    \\  --replay-offset N   start the movie on record N instead of where the
    \\                      format says (2 for .fm2, which is how many records
    \\                      FCEUX spends on its dead-PPU frames at power-on;
    \\                      0 for .bk2, which has no such frames)
    \\  --zapper            plug a Zapper into port 2 (mouse aims, click fires)
    \\  -h, --help          show this message
    \\
    \\controls:
    \\  arrows / Z / X          d-pad / A / B
    \\  Enter / right Shift     start / select
    \\  Ctrl+R (Cmd+R)          reset
    \\  Ctrl+Shift+R            power cycle
    \\  Ctrl+Z (Cmd+Z)          swap port 2 between a controller and a Zapper
    \\  mouse                   aim the Zapper; the left button is its trigger
    \\  gamepad                 plug one in; the first two drive both ports
    \\  drag and drop           a .nes ROM to boot it, a movie file to replay it
    \\
;

pub fn main(init: std.process.Init) !void {
    const stderr = std.Io.File.stderr();

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next(); // skip argv[0]

    var options: App.Options = .{ .io = init.io };
    var rom_path: ?[]const u8 = null;
    var replay_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try std.Io.File.stdout().writeStreamingAll(init.io, usage);
            return;
        } else if (std.mem.eql(u8, arg, "--replay")) {
            replay_path = args.next() orelse {
                try stderr.writeStreamingAll(init.io, "znes: --replay needs a file\n");
                return error.MissingReplayPath;
            };
        } else if (std.mem.eql(u8, arg, "--replay-offset")) {
            const value = args.next() orelse {
                try stderr.writeStreamingAll(init.io, "znes: --replay-offset needs a number\n");
                return error.MissingReplayOffset;
            };
            options.replay_offset = std.fmt.parseInt(usize, value, 10) catch {
                try stderr.writeStreamingAll(init.io, "znes: --replay-offset wants a frame count\n");
                return error.BadReplayOffset;
            };
        } else if (std.mem.eql(u8, arg, "--zapper")) {
            options.peripherals = .zapper;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.writeStreamingAll(init.io, usage);
            return error.UnknownOption;
        } else if (rom_path == null) {
            rom_path = arg;
        } else {
            try stderr.writeStreamingAll(init.io, "znes: only one ROM at a time\n");
            return error.TooManyRoms;
        }
    }

    // A movie replays against a console that is already running, so there has
    // to be one. Dropping a movie on the window later is the other way in,
    // and by then a ROM has necessarily been loaded.
    if (replay_path != null and rom_path == null) {
        try stderr.writeStreamingAll(init.io, "znes: --replay needs a ROM to replay against\n");
        return error.MissingRomPath;
    }

    var app: App = undefined;
    try app.init(init.gpa, options);
    defer app.deinit();

    // Paths that came from the command line are fatal if they fail to load --
    // they are what the user asked for. Paths that arrive later, by
    // drag-and-drop, only earn an on-screen message.
    for ([_]?[]const u8{ rom_path, replay_path }) |maybe_path| {
        const path = maybe_path orelse continue;
        openPath(&app, init.gpa, init.io, path) catch |err| {
            report(init.io, path, err);
            std.process.exit(1);
        };
    }

    while (true) {
        const state = app.pollInput();
        if (state.quit) break;
        if (state.dropped_path) |path| {
            openPath(&app, init.gpa, init.io, path) catch |err| {
                app.setToast("{s}: {s}", .{ std.fs.path.basename(path), @errorName(err) });
            };
        }
        // A dropped frame is not worth ending the session over -- the web
        // build reports the same errors and keeps going, and a transient SDL
        // failure should not lose whatever the player has not saved.
        app.tick(state) catch |err| report(init.io, "frame", err);
    }
}

/// Reads `path` and hands its bytes to the app, under the file's own name.
/// The bytes are freed on the way out: `App.open` copies whatever it decides
/// to keep.
fn openPath(app: *App, gpa: Allocator, io: std.Io, path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes));
    defer gpa.free(bytes);
    try app.open(std.fs.path.basename(path), bytes);
}

/// Names the file that could not be loaded, on the way to giving up. A path
/// the user typed deserves better than a stack trace naming an error the path
/// is missing from.
/// Says what went wrong on stderr, best-effort. Reporting a failure is not
/// worth failing over, so nothing here propagates: the caller decides whether
/// the thing that failed was survivable.
fn report(io: std.Io, subject: []const u8, err: anyerror) void {
    var buf: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "znes: {s}: {s}\n", .{ subject, @errorName(err) }) catch
        "znes: something went wrong\n";
    std.Io.File.stderr().writeStreamingAll(io, message) catch {};
}

test {
    std.testing.refAllDecls(@This());
}

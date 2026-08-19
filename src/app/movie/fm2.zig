//! FCEUX `.fm2` movie parsing.
//!
//! An fm2 file is plain text: a run of `key value` header lines, then one
//! line per frame. A frame line is pipe-separated fields --
//!
//!     |commands|port0|port1|port2||
//!
//! -- where `commands` is a decimal bitfield and each port field is eight
//! characters, one per button, written from bit 7 down to bit 0. FCEUX
//! writes each held button as its mnemonic (`RLDUTSBA`) and each released
//! one as `.`, but the format only promises that `.` and a space mean
//! released, so anything else is read as held.
//!
//! With a Four Score the file carries four gamepad fields instead of three
//! ports; only the first two are replayed, since the core has two ports.
//!
//! The header is honoured for as long as it precedes the input log, which is
//! how FCEUX writes it. `.fm3` project files append further sections after
//! the log -- markers and, in places, binary blobs -- so parsing one is
//! best-effort: the input log comes out intact, and junk that reaches the
//! record parser is reported rather than silently truncating the movie.

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("input");
const Movie = @import("../Movie.zig");

pub const ParseError = error{
    /// `binary 1`: the input log is packed bytes rather than text.
    BinaryLogUnsupported,
    /// The movie resumes from an embedded savestate, so replaying it from
    /// power-on would start from the wrong state entirely.
    SavestateMovieUnsupported,
    /// A port drives something other than a standard controller -- a Zapper,
    /// say -- which the core has no equivalent for.
    UnsupportedInputDevice,
    /// A line beginning with `|` that is not a well-formed frame record.
    MalformedInputRecord,
} || Allocator.Error;

/// What a port is wired to, using fm2's `portN` numbering.
const PortKind = enum(u8) {
    none = 0,
    gamepad = 1,
    zapper = 2,
    _,
};

/// Whether `bytes` looks like an fm2 file, for callers that have to guess a
/// format from contents. Both marks are required: the `version` key is the
/// first line FCEUX writes, and the pipe rules out a header-only text file
/// that happens to start the same way.
pub fn looksLikeFm2(bytes: []const u8) bool {
    if (!std.mem.startsWith(u8, bytes, "version ")) return false;
    return std.mem.indexOfScalar(u8, bytes, '|') != null;
}

pub fn parse(gpa: Allocator, bytes: []const u8) ParseError!Movie {
    // FCEUX's defaults for a file that omits the keys: two gamepads, no
    // expansion port device.
    var ports: [3]PortKind = .{ .gamepad, .gamepad, .none };
    var warnings: Movie.Warnings = .{};
    var fourscore = false;

    var frames: std.ArrayList(Movie.Frame) = .empty;
    errdefer frames.deinit(gpa);

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;

        if (line[0] == '|') {
            try frames.append(gpa, try parseRecord(line, ports, fourscore));
            continue;
        }

        const key, const value = splitHeader(line);
        if (std.mem.eql(u8, key, "binary")) {
            if (parseFlag(value)) return error.BinaryLogUnsupported;
        } else if (std.mem.eql(u8, key, "savestate")) {
            // The key only appears at all when there is a state to resume
            // from, so its presence is the signal, not its value.
            if (value.len != 0) return error.SavestateMovieUnsupported;
        } else if (std.mem.eql(u8, key, "palFlag")) {
            warnings.pal = parseFlag(value);
        } else if (std.mem.eql(u8, key, "fourscore")) {
            fourscore = parseFlag(value);
            warnings.fourscore = fourscore;
        } else if (std.mem.eql(u8, key, "port0")) {
            ports[0] = parsePort(value);
        } else if (std.mem.eql(u8, key, "port1")) {
            ports[1] = parsePort(value);
        } else if (std.mem.eql(u8, key, "port2")) {
            ports[2] = parsePort(value);
        }
        // Everything else -- emuVersion, romFilename, rerecordCount, the
        // comment and subtitle lines, TAS Editor's own keys -- says nothing
        // about how to replay the input log.
    }

    return .{
        .format = .fm2,
        .frames = try frames.toOwnedSlice(gpa),
        .warnings = warnings,
    };
}

/// Splits `key value` at the first run of blanks. A key with no value yields
/// an empty value rather than failing; the caller decides whether that means
/// anything.
fn splitHeader(line: []const u8) struct { []const u8, []const u8 } {
    const end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
    return .{ line[0..end], std.mem.trim(u8, line[end..], " \t") };
}

fn parseFlag(value: []const u8) bool {
    return value.len != 0 and !std.mem.eql(u8, value, "0");
}

fn parsePort(value: []const u8) PortKind {
    const n = std.fmt.parseInt(u8, value, 10) catch return .none;
    return @enumFromInt(n);
}

fn parseRecord(line: []const u8, ports: [3]PortKind, fourscore: bool) ParseError!Movie.Frame {
    var fields = std.mem.splitScalar(u8, line, '|');

    // The line opens with the separator, so the first field is empty.
    if ((fields.next() orelse return error.MalformedInputRecord).len != 0) {
        return error.MalformedInputRecord;
    }

    var frame: Movie.Frame = .{
        .commands = try parseCommands(fields.next() orelse return error.MalformedInputRecord),
    };

    // A Four Score movie logs its four gamepads where the three ports would
    // otherwise be.
    const field_count: usize = if (fourscore) 4 else ports.len;
    for (0..field_count) |i| {
        const field = fields.next() orelse return error.MalformedInputRecord;
        switch (if (fourscore) PortKind.gamepad else ports[i]) {
            // An unconnected port contributes a field, but an empty one.
            .none => if (field.len != 0) return error.MalformedInputRecord,
            .gamepad => {
                const buttons = try parseButtons(field);
                if (i < frame.ports.len) frame.ports[i] = buttons;
            },
            else => return error.UnsupportedInputDevice,
        }
    }

    return frame;
}

fn parseCommands(field: []const u8) ParseError!Movie.Commands {
    const text = std.mem.trim(u8, field, " ");
    if (text.len == 0) return .{};
    const bits = std.fmt.parseInt(u8, text, 10) catch return error.MalformedInputRecord;
    return @bitCast(bits);
}

fn parseButtons(field: []const u8) ParseError!input.Buttons {
    if (field.len != 8) return error.MalformedInputRecord;
    var mask: u8 = 0;
    for (field, 0..) |char, i| {
        // Written most significant bit first: R L D U T S B A.
        const bit: u3 = @intCast(7 - i);
        if (char != '.' and char != ' ') mask |= @as(u8, 1) << bit;
    }
    return @bitCast(mask);
}

// --- Tests ---------------------------------------------------------------

const testing = std.testing;

fn parseFrames(source: []const u8) !Movie {
    return parse(testing.allocator, source);
}

test "each button character lands on the bit FCEUX gave it" {
    var movie = try parseFrames(
        \\version 3
        \\|0|RLDUTSBA|........||
        \\|0|.......A|........||
        \\|0|R.......|........||
        \\|0|...U.S..|........||
        \\
    );
    defer movie.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0xFF), @as(u8, @bitCast(movie.frames[0].ports[0])));
    try testing.expectEqual(input.Buttons{ .a = true }, movie.frames[1].ports[0]);
    try testing.expectEqual(input.Buttons{ .right = true }, movie.frames[2].ports[0]);
    try testing.expectEqual(input.Buttons{ .up = true, .select = true }, movie.frames[3].ports[0]);
}

test "anything that is not a dot or a space counts as held" {
    var movie = try parseFrames("|0|xxxxxxxx|   .   .||\n");
    defer movie.deinit(testing.allocator);

    try testing.expectEqual(@as(u8, 0xFF), @as(u8, @bitCast(movie.frames[0].ports[0])));
    try testing.expectEqual(input.Buttons.none, movie.frames[0].ports[1]);
}

test "both ports are replayed" {
    var movie = try parseFrames("|0|.......A|.......A||\n");
    defer movie.deinit(testing.allocator);

    try testing.expect(movie.frames[0].ports[0].a);
    try testing.expect(movie.frames[0].ports[1].a);
}

test "the commands field carries reset and power" {
    var movie = try parseFrames("|0|........|........||\n|1|........|........||\n|2|........|........||\n");
    defer movie.deinit(testing.allocator);

    try testing.expectEqual(Movie.Commands{}, movie.frames[0].commands);
    try testing.expect(movie.frames[1].commands.soft_reset);
    try testing.expect(movie.frames[2].commands.power);
}

test "an unconnected port logs an empty field" {
    // port1 0 means the second gamepad is absent, so its field is empty --
    // and the field that follows still belongs to port2, not to port1.
    var movie = try parseFrames(
        \\port0 1
        \\port1 0
        \\port2 0
        \\|0|.......A||||
        \\
    );
    defer movie.deinit(testing.allocator);

    try testing.expect(movie.frames[0].ports[0].a);
    try testing.expectEqual(input.Buttons.none, movie.frames[0].ports[1]);
}

test "a four score movie replays its first two pads and says so" {
    var movie = try parseFrames(
        \\fourscore 1
        \\|0|.......A|......B.|.....S..|....T...||
        \\
    );
    defer movie.deinit(testing.allocator);

    try testing.expect(movie.warnings.fourscore);
    try testing.expect(movie.frames[0].ports[0].a);
    try testing.expect(movie.frames[0].ports[1].b);
}

test "a PAL movie is playable but flagged" {
    var movie = try parseFrames("palFlag 1\n|0|........|........||\n");
    defer movie.deinit(testing.allocator);

    try testing.expect(movie.warnings.pal);
    try testing.expect(movie.warnings.any());
}

test "movies this player cannot honour are refused rather than desynced" {
    try testing.expectError(error.BinaryLogUnsupported, parseFrames("binary 1\n"));
    try testing.expectError(error.SavestateMovieUnsupported, parseFrames("savestate AAAA\n"));
    try testing.expectError(error.UnsupportedInputDevice, parseFrames("port0 2\n|0|0 0 0 0 0|........||\n"));
}

test "a malformed record is an error, not a truncated movie" {
    try testing.expectError(error.MalformedInputRecord, parseFrames("|0|.....|........||\n"));
    try testing.expectError(error.MalformedInputRecord, parseFrames("|0|........||\n"));
    try testing.expectError(error.MalformedInputRecord, parseFrames("|zz|........|........||\n"));
}

test "carriage returns and blank lines are tolerated" {
    var movie = try parseFrames("version 3\r\n\r\n|0|.......A|........||\r\n");
    defer movie.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), movie.frames.len);
    try testing.expect(movie.frames[0].ports[0].a);
}

test "looksLikeFm2 wants both the version key and an input log" {
    try testing.expect(looksLikeFm2("version 3\nport0 1\n|0|........|........||\n"));
    try testing.expect(!looksLikeFm2("version 3\nno input log here\n"));
    try testing.expect(!looksLikeFm2("NES\x1a"));
}

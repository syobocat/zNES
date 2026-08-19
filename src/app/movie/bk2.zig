//! BizHawk `.bk2` movie parsing.
//!
//! A bk2 is a zip archive; the member that matters is `Input Log.txt`:
//!
//!     [Input]
//!     LogKey:#Reset Cycle|Power|Reset|#P1 Up|P1 Down|P1 Left|P1 Right|P1 Start|P1 Select|P1 B|P1 A|#P2 Up|...|
//!     |    0,..|........|........|
//!     |    0,..|U.L.S..A|........|
//!     [/Input]
//!
//! The `LogKey` line names every column in order: `#` opens a group -- the
//! console's own buttons, then one per controller -- and each name inside a
//! group is followed by `|`. A log line carries the same groups as
//! `|`-delimited fields.
//!
//! Reading those *names* rather than a table of mnemonics is what keeps this
//! short and keeps it honest. BizHawk gives every button a one-character
//! mnemonic that varies by console and by controller, but the column names are
//! plain English and the log declares its own. A column this console has no
//! equivalent for is simply not recognised, and skipped.
//!
//! **Not every column is one character wide.** A button is, held unless it is
//! `.` or a space, but an axis -- `Reset Cycle` in the example above, a
//! Zapper's coordinates elsewhere -- is written as its value padded to five
//! places and closed with a comma. The `LogKey` gives no types, so `cellAt`
//! works the widths out from the text.
//!
//! `Header.txt` is read too, for the region and to make sure the movie is for
//! an NES at all -- an SNES bk2 also has a `P1 A`, and would otherwise parse
//! into something that looks fine and plays like noise.

const std = @import("std");
const Allocator = std.mem.Allocator;

const input = @import("input");
const Movie = @import("../Movie.zig");
const zip = @import("zip.zig");

const input_log_name = "Input Log.txt";
const header_name = "Header.txt";
const log_key_prefix = "LogKey:";

/// A long movie's input log runs to a few megabytes; this is well past any
/// real one and still small enough to refuse a decompression bomb.
const max_member_bytes = 64 * 1024 * 1024;

pub const ParseError = error{
    /// The archive carries no input log, so whatever it is, it is not a movie.
    MissingInputLog,
    /// The log never says what its columns mean.
    MissingLogKey,
    /// A log line does not account for the columns the `LogKey` declared:
    /// too few fields, or a field the columns do not add up to.
    MalformedInputRecord,
    /// The movie is for some other console.
    NotAnNesMovie,
} || zip.Error || Allocator.Error;

/// Whether `bytes` looks like a bk2, for callers that have to guess a format
/// from contents. Member names sit uncompressed in a zip's headers, so the
/// input log announces itself without anything being unpacked.
pub fn looksLikeBk2(bytes: []const u8) bool {
    if (!std.mem.startsWith(u8, bytes, &std.zip.local_file_header_sig)) return false;
    return std.mem.indexOf(u8, bytes, input_log_name) != null;
}

pub fn parse(gpa: Allocator, bytes: []const u8) ParseError!Movie {
    var warnings: Movie.Warnings = .{};
    if (try zip.readMember(gpa, bytes, header_name, max_member_bytes)) |header| {
        defer gpa.free(header);
        try readHeader(header, &warnings);
    }

    const log = (try zip.readMember(gpa, bytes, input_log_name, max_member_bytes)) orelse
        return error.MissingInputLog;
    defer gpa.free(log);

    var layout: Layout = .{};
    defer layout.deinit(gpa);

    var frames: std.ArrayList(Movie.Frame) = .empty;
    errdefer frames.deinit(gpa);

    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, log_key_prefix)) {
            try layout.read(gpa, line[log_key_prefix.len..], &warnings);
            continue;
        }
        // `[Input]`, `[/Input]`, and anything a future version puts between
        // them that is not a frame.
        if (line.len == 0 or line[0] != '|') continue;
        if (layout.columns.items.len == 0) return error.MissingLogKey;
        try frames.append(gpa, try layout.record(line, &warnings));
    }

    if (layout.columns.items.len == 0) return error.MissingLogKey;
    if (!layout.saw_controller) return error.NotAnNesMovie;

    return .{
        .format = .bk2,
        .frames = try frames.toOwnedSlice(gpa),
        .warnings = warnings,
    };
}

/// `Header.txt` is `Key Value` lines. Only two keys matter here, and a header
/// that mentions neither is taken at face value rather than rejected -- the
/// key set is not fixed across the versions that write these files, and the
/// input log is the
/// part this player actually depends on.
fn readHeader(header: []const u8, warnings: *Movie.Warnings) ParseError!void {
    var lines = std.mem.splitScalar(u8, header, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const end = std.mem.indexOfAny(u8, line, " \t") orelse continue;
        const key = line[0..end];
        const value = std.mem.trim(u8, line[end..], " \t");

        if (std.mem.eql(u8, key, "Platform") or std.mem.eql(u8, key, "SystemID")) {
            // A prefix rather than an exact match, so that a value carrying a
            // qualifier still counts. It costs nothing: the platform this has
            // to tell apart from an NES is an SNES, and "SNES" does not begin
            // with "NES".
            if (value.len < 3 or !std.ascii.eqlIgnoreCase(value[0..3], "NES")) {
                return error.NotAnNesMovie;
            }
        } else if (std.mem.eql(u8, key, "PAL")) {
            warnings.pal = truthy(value);
        }
    }
}

fn truthy(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    return !std.ascii.eqlIgnoreCase(value, "false");
}

/// What one column of the log does, worked out once from the `LogKey` and
/// then applied to every line.
const Column = union(enum) {
    /// A button this console does not have, or a player it does not have.
    ignored,
    /// Bits to set in the frame's commands.
    command: u8,
    button: struct { port: usize, mask: u8 },
    /// BizHawk's `Reset Cycle` and `Reset Instruction`: *when within the
    /// frame* a reset lands, which it needs because a reset's exact cycle is
    /// visible to the machine and TASes depend on it. This player resets on
    /// frame boundaries only, so the value is not honoured -- but a
    /// non-neutral one is worth warning about, since it is a real difference
    /// between what was recorded and what is about to be replayed.
    reset_timing,
};

/// One column's characters within a log field.
///
/// Boolean columns take one character each, but an axis is written as its
/// value padded to five places and closed with a comma, so `|    0,..|` is
/// three columns rather than eight. Nothing in the log says which columns are
/// which -- the `LogKey` gives names, not types -- so the shape of the text
/// has to answer it: a run of digits, sign and padding closed by a comma is
/// an axis, and anything else is one character of a button.
///
/// That leans on a button's mnemonic never being a digit or a space, which
/// holds for every button this file looks at. It does not have to hold
/// blindly: `record` checks that the columns it read account for the whole
/// field, so a misreading fails loudly instead of shifting every column along
/// by one.
fn cellAt(field: []const u8, pos: usize) []const u8 {
    var end = pos;
    while (end < field.len and isAxisChar(field[end])) end += 1;
    if (end < field.len and field[end] == ',') return field[pos .. end + 1];
    return field[pos..][0..1];
}

fn isAxisChar(char: u8) bool {
    return char == ' ' or char == '-' or char == '+' or std.ascii.isDigit(char);
}

/// Whether an axis cell holds its neutral value. Anything this player cannot
/// act on is only worth mentioning when it was actually used.
fn isNeutral(cell: []const u8) bool {
    const text = std.mem.trim(u8, cell, " ,");
    return text.len == 0 or std.mem.eql(u8, text, "0");
}

const Layout = struct {
    /// Every column, in order, with the groups laid end to end.
    columns: std.ArrayList(Column) = .empty,
    /// How many columns each group holds, so a log line's fields can be
    /// matched up with them.
    groups: std.ArrayList(u16) = .empty,
    /// Whether any column named a button on a controller. Its absence means
    /// the log describes some other machine's inputs entirely.
    saw_controller: bool = false,

    fn deinit(self: *Layout, gpa: Allocator) void {
        self.columns.deinit(gpa);
        self.groups.deinit(gpa);
    }

    fn read(self: *Layout, gpa: Allocator, key: []const u8, warnings: *Movie.Warnings) ParseError!void {
        self.columns.clearRetainingCapacity();
        self.groups.clearRetainingCapacity();

        var groups = std.mem.splitScalar(u8, key, '#');
        _ = groups.next(); // whatever precedes the first group, which is nothing
        while (groups.next()) |group| {
            var count: u16 = 0;
            var names = std.mem.splitScalar(u8, group, '|');
            while (names.next()) |raw_name| {
                // Every name is *followed* by its separator, so the split
                // leaves an empty behind at the end of each group.
                const name = std.mem.trim(u8, raw_name, " \t");
                if (name.len == 0) continue;
                try self.columns.append(gpa, self.classify(name, warnings));
                count += 1;
            }
            try self.groups.append(gpa, count);
        }
    }

    fn classify(self: *Layout, name: []const u8, warnings: *Movie.Warnings) Column {
        if (std.mem.eql(u8, name, "Reset")) return .{ .command = @bitCast(Movie.Commands{ .soft_reset = true }) };
        if (std.mem.eql(u8, name, "Power")) return .{ .command = @bitCast(Movie.Commands{ .power = true }) };
        // `Reset Cycle`, and `Reset Instruction` alongside it in newer
        // versions. The bare `Reset` above has no trailing space, so it is
        // matched first and never reaches this.
        if (std.mem.startsWith(u8, name, "Reset ")) return .reset_timing;

        // Controller columns are "P<n> <Button>". Everything else -- the FDS
        // and VS. System console buttons, another console's inputs -- falls
        // through to being ignored.
        if (name.len < 4 or name[0] != 'P' or name[2] != ' ') return .ignored;
        const player = std.fmt.charToDigit(name[1], 10) catch return .ignored;
        const mask = buttonMask(name[3..]) orelse return .ignored;

        self.saw_controller = true;
        if (player < 1 or player > input.player_count) {
            // A Four Score movie: ports three and four have nowhere to go.
            warnings.fourscore = true;
            return .ignored;
        }
        return .{ .button = .{ .port = player - 1, .mask = mask } };
    }

    fn buttonMask(name: []const u8) ?u8 {
        const buttons = input.Buttons;
        if (std.mem.eql(u8, name, "A")) return @bitCast(buttons{ .a = true });
        if (std.mem.eql(u8, name, "B")) return @bitCast(buttons{ .b = true });
        if (std.mem.eql(u8, name, "Select")) return @bitCast(buttons{ .select = true });
        if (std.mem.eql(u8, name, "Start")) return @bitCast(buttons{ .start = true });
        if (std.mem.eql(u8, name, "Up")) return @bitCast(buttons{ .up = true });
        if (std.mem.eql(u8, name, "Down")) return @bitCast(buttons{ .down = true });
        if (std.mem.eql(u8, name, "Left")) return @bitCast(buttons{ .left = true });
        if (std.mem.eql(u8, name, "Right")) return @bitCast(buttons{ .right = true });
        return null;
    }

    fn record(self: *const Layout, line: []const u8, warnings: *Movie.Warnings) ParseError!Movie.Frame {
        var frame: Movie.Frame = .{};
        var commands: u8 = 0;
        var ports: [input.player_count]u8 = @splat(0);

        var fields = std.mem.splitScalar(u8, line, '|');
        // The line opens with the separator, so the first field is empty.
        if ((fields.next() orelse return error.MalformedInputRecord).len != 0) {
            return error.MalformedInputRecord;
        }

        var at: usize = 0;
        for (self.groups.items) |count| {
            const field = fields.next() orelse return error.MalformedInputRecord;

            var pos: usize = 0;
            for (self.columns.items[at..][0..count]) |column| {
                if (pos >= field.len) return error.MalformedInputRecord;
                const cell = cellAt(field, pos);
                pos += cell.len;

                switch (column) {
                    .ignored => {},
                    .reset_timing => if (!isNeutral(cell)) {
                        warnings.reset_timing = true;
                    },
                    .command => |bits| if (!released(cell)) {
                        commands |= bits;
                    },
                    .button => |b| if (!released(cell)) {
                        ports[b.port] |= b.mask;
                    },
                }
            }
            // The columns have to account for the field exactly. Anything
            // left over means the widths above were read wrong, and a frame
            // of input read wrong is worse than one refused.
            if (pos != field.len) return error.MalformedInputRecord;
            at += count;
        }

        frame.commands = @bitCast(commands);
        for (&frame.ports, ports) |*port, bits| port.* = @bitCast(bits);
        return frame;
    }

    /// A button cell is one character, held unless it is `.` or a space.
    fn released(cell: []const u8) bool {
        return cell.len != 1 or cell[0] == '.' or cell[0] == ' ';
    }
};

// --- Tests ---------------------------------------------------------------

const testing = std.testing;

const nes_log_key = "LogKey:#Reset|Power|#P1 Up|P1 Down|P1 Left|P1 Right|P1 Start|P1 Select|P1 B|P1 A|" ++
    "#P2 Up|P2 Down|P2 Left|P2 Right|P2 Start|P2 Select|P2 B|P2 A|\n";

fn buildBk2(gpa: Allocator, header: ?[]const u8, log: []const u8) ![]u8 {
    var members: std.ArrayList(zip.TestMember) = .empty;
    defer members.deinit(gpa);
    if (header) |h| try members.append(gpa, .{ .name = header_name, .body = h });
    try members.append(gpa, .{ .name = input_log_name, .body = log });

    // Deflated, because that is what BizHawk writes.
    return zip.buildTestArchive(gpa, members.items, .deflate);
}

fn parseLog(header: ?[]const u8, log: []const u8) !Movie {
    const archive = try buildBk2(testing.allocator, header, log);
    defer testing.allocator.free(archive);
    return parse(testing.allocator, archive);
}

test "the log key says which character is which button" {
    var movie = try parseLog(null, "[Input]\n" ++ nes_log_key ++
        "|..|.......A|........|\n" ++ // P1 A, the last column of its group
        "|..|U.......|........|\n" ++ // P1 Up, the first
        "|..|UDLRSsBA|........|\n" ++ // everything at once
        "|..|........|.....s..|\n" ++ // P2 Select
        "[/Input]\n");
    defer movie.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), movie.frames.len);
    try testing.expectEqual(input.Buttons{ .a = true }, movie.frames[0].ports[0]);
    try testing.expectEqual(input.Buttons{ .up = true }, movie.frames[1].ports[0]);
    try testing.expectEqual(@as(u8, 0xFF), @as(u8, @bitCast(movie.frames[2].ports[0])));
    try testing.expectEqual(input.Buttons{ .select = true }, movie.frames[3].ports[1]);
}

test "the console group carries reset and power" {
    var movie = try parseLog(null, nes_log_key ++
        "|..|........|........|\n" ++
        "|r.|........|........|\n" ++
        "|.P|........|........|\n");
    defer movie.deinit(testing.allocator);

    try testing.expectEqual(Movie.Commands{}, movie.frames[0].commands);
    try testing.expect(movie.frames[1].commands.soft_reset);
    try testing.expect(movie.frames[2].commands.power);
}

/// The console group BizHawk actually writes for the NES, taken verbatim from
/// a real `.bk2`. `Reset Cycle` is an axis, so its three columns occupy eight
/// characters rather than three.
const real_log_key = "LogKey:#Reset Cycle|Power|Reset|" ++
    "#P1 Up|P1 Down|P1 Left|P1 Right|P1 Start|P1 Select|P1 B|P1 A|" ++
    "#P2 Up|P2 Down|P2 Left|P2 Right|P2 Start|P2 Select|P2 B|P2 A|\n";

test "an axis column takes a whole comma-terminated field, not one character" {
    var movie = try parseLog(null, "[Input]\r\n" ++ real_log_key ++
        "|    0,..|........|........|\r\n" ++
        "|    0,..|U.L.S..A|........|\r\n" ++
        "|    0,.r|........|........|\r\n" ++
        "|    0,P.|........|........|\r\n" ++
        "[/Input]\r\n");
    defer movie.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 4), movie.frames.len);
    // The two buttons after the axis are still read as the buttons they are.
    try testing.expectEqual(input.Buttons{
        .up = true,
        .left = true,
        .start = true,
        .a = true,
    }, movie.frames[1].ports[0]);
    try testing.expect(movie.frames[2].commands.soft_reset);
    try testing.expect(movie.frames[3].commands.power);
    // Every reset cycle was neutral, so there is nothing to warn about.
    try testing.expect(!movie.warnings.any());
}

test "a reset asked for mid-frame is replayed on the boundary, and said so" {
    var movie = try parseLog(null, real_log_key ++
        "|    0,..|........|........|\n" ++
        "|29780,.r|........|........|\n");
    defer movie.deinit(testing.allocator);

    try testing.expect(movie.warnings.reset_timing);
    try testing.expect(movie.frames[1].commands.soft_reset);
}

test "a negative or wide axis value is still one column" {
    var movie = try parseLog(null, "LogKey:#Reset Cycle|Power|Reset|#P1 A|\n" ++
        "|  -12,..|A|\n" ++
        "|1234567,.r|.|\n");
    defer movie.deinit(testing.allocator);

    try testing.expect(movie.frames[0].ports[0].a);
    try testing.expect(movie.frames[1].commands.soft_reset);
    try testing.expect(movie.warnings.reset_timing);
}

test "columns this console has no use for are skipped, not misread" {
    // An FDS movie's console group is wider, and its extra buttons have to
    // fall through without shifting the controller columns along.
    var movie = try parseLog(null, "LogKey:#Reset|Power|FDS Eject|FDS Insert 0|#P1 Up|P1 Down|P1 Left|P1 Right|P1 Start|P1 Select|P1 B|P1 A|\n" ++
        "|r..E|.......A|\n");
    defer movie.deinit(testing.allocator);

    try testing.expect(movie.frames[0].commands.soft_reset);
    try testing.expectEqual(input.Buttons{ .a = true }, movie.frames[0].ports[0]);
}

test "a four score movie replays its first two pads and says so" {
    var movie = try parseLog(null, "LogKey:#Reset|Power|#P1 A|#P2 A|#P3 A|#P4 A|\n" ++
        "|..|A|A|A|A|\n");
    defer movie.deinit(testing.allocator);

    try testing.expect(movie.warnings.fourscore);
    try testing.expect(movie.frames[0].ports[0].a);
    try testing.expect(movie.frames[0].ports[1].a);
}

test "the header decides the region and the console" {
    var pal = try parseLog("Platform NES\nPAL 1\n", nes_log_key ++ "|..|........|........|\n");
    defer pal.deinit(testing.allocator);
    try testing.expect(pal.warnings.pal);

    var ntsc = try parseLog("Platform NES\nPAL 0\n", nes_log_key ++ "|..|........|........|\n");
    defer ntsc.deinit(testing.allocator);
    try testing.expect(!ntsc.warnings.pal);

    try testing.expectError(error.NotAnNesMovie, parseLog(
        "Platform SNES\n",
        nes_log_key ++ "|..|........|........|\n",
    ));

    // A qualified value still names an NES.
    var qualified = try parseLog("SystemID NES (NTSC)\n", nes_log_key ++ "|..|........|........|\n");
    defer qualified.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), qualified.frames.len);
}

test "a movie for another machine entirely is refused" {
    // No column names a controller button this console has.
    try testing.expectError(error.NotAnNesMovie, parseLog(null, "LogKey:#Power|#P1 Tilt X|P1 Tilt Y|\n" ++
        "|.|..|\n"));
}

test "a log with no key, and a key with no log" {
    try testing.expectError(error.MissingLogKey, parseLog(null, "[Input]\n|..|........|........|\n"));

    var empty = try parseLog(null, nes_log_key);
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), empty.frames.len);
}

test "a line that does not fit the declared layout is an error" {
    // One character short in the controller group.
    try testing.expectError(error.MalformedInputRecord, parseLog(null, nes_log_key ++ "|..|.......|........|\n"));
    // A group missing altogether.
    try testing.expectError(error.MalformedInputRecord, parseLog(null, nes_log_key ++ "|..|........|\n"));
    // A field that is one character too long for its columns even after the
    // axis in it is accounted for.
    try testing.expectError(error.MalformedInputRecord, parseLog(null, "LogKey:#Reset Cycle|Power|Reset|#P1 A|\n" ++
        "|    0,...|A|\n"));
}

test "an axis on a controller is consumed and ignored, not mistaken for buttons" {
    // A Zapper's coordinates share the group with the buttons, so getting
    // their width wrong would drag every button along with it.
    var movie = try parseLog(null, "LogKey:#Reset|Power|#P1 A|P1 Zapper X|P1 Zapper Y|\n" ++
        "|..|A   128,   32,|\n");
    defer movie.deinit(testing.allocator);

    try testing.expectEqual(input.Buttons{ .a = true }, movie.frames[0].ports[0]);
}

test "an archive without an input log is not a movie" {
    const gpa = testing.allocator;
    const archive = try buildBk2(gpa, "Platform NES\n", "");
    defer gpa.free(archive);
    // Rename the log member out of existence by corrupting both copies of its
    // name; what is left is a zip with only a header in it.
    const renamed = try gpa.dupe(u8, archive);
    defer gpa.free(renamed);
    while (std.mem.indexOf(u8, renamed, input_log_name)) |at| {
        renamed[at] = 'X';
    }
    try testing.expectError(error.MissingInputLog, parse(gpa, renamed));
}

test "bk2 and fm2 agree on what a button is" {
    const fm2 = @import("fm2.zig");
    const gpa = testing.allocator;

    // The same four frames in both formats. The two do not write buttons in
    // the same order -- bk2 runs Up first and takes its meaning from the
    // column's position, fm2 runs Right first and gives each a mnemonic -- so
    // a mistake in either mapping shows up as a mismatch here. The fm2 side
    // is the one that has been checked against real movies, which is what
    // makes it worth comparing against.
    var from_bk2 = try parseLog(null, nes_log_key ++
        "|..|.......A|........|\n" ++
        "|..|UDLRSsBA|........|\n" ++
        "|..|...R....|........|\n" ++
        "|..|........|....S...|\n");
    defer from_bk2.deinit(gpa);

    var from_fm2 = try fm2.parse(gpa, "|0|.......A|........||\n" ++
        "|0|RLDUTSBA|........||\n" ++
        "|0|R.......|........||\n" ++
        "|0|........|....T...||\n");
    defer from_fm2.deinit(gpa);

    try testing.expectEqual(from_fm2.frames.len, from_bk2.frames.len);
    for (from_fm2.frames, from_bk2.frames) |expected, actual| {
        try testing.expectEqual(expected.ports, actual.ports);
    }
}

test "looksLikeBk2 wants a zip that contains an input log" {
    const gpa = testing.allocator;
    const archive = try buildBk2(gpa, null, nes_log_key);
    defer gpa.free(archive);

    try testing.expect(looksLikeBk2(archive));
    try testing.expect(!looksLikeBk2("PK\x03\x04 some other zip"));
    try testing.expect(!looksLikeBk2("version 3\n|0|........|........||\n"));
}

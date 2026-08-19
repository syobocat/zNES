// SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
//
// SPDX-License-Identifier: MIT-0

//! Just enough of the zip format to pull one named member out of an archive
//! that is already in memory.
//!
//! `std.zip` reads through a `File.Reader`, and movies arrive here as bytes --
//! read once, sniffed for a format, then parsed -- so rather than open the
//! file a second time this walks the central directory itself and hands the
//! member's payload to `std.compress.flate`. It still borrows `std.zip`'s
//! record layouts, so the field offsets below are the ones the standard
//! library maintains.
//!
//! Only what a zip writer actually produces for a handful of small text
//! members is handled: stored and deflated entries, no encryption, no zip64,
//! no spanning. Anything else is refused rather than guessed at.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

const Central = std.zip.CentralDirectoryFileHeader;
const Local = std.zip.LocalFileHeader;
const End = std.zip.EndRecord;

pub const Error = error{
    NotAZipArchive,
    /// Encrypted, zip64, or compressed with something other than deflate.
    UnsupportedZipFeature,
    /// Structurally broken, or compressed data that does not decode.
    CorruptZipArchive,
    /// The member decompresses to more than the caller is willing to hold.
    ZipMemberTooLarge,
} || Allocator.Error;

/// Returns the contents of the member called `name`, or null if the archive
/// has no member by that name. The caller owns the result.
pub fn readMember(
    gpa: Allocator,
    archive: []const u8,
    name: []const u8,
    max_size: usize,
) Error!?[]u8 {
    const end = try findEndRecord(archive);
    const record_count = read(End, "record_count_total", u16, end);
    if (record_count == std.math.maxInt(u16)) return error.UnsupportedZipFeature; // zip64

    var at: usize = read(End, "central_directory_offset", u32, end);
    if (at == std.math.maxInt(u32)) return error.UnsupportedZipFeature; // zip64
    for (0..record_count) |_| {
        const header = try take(archive, &at, @sizeOf(Central));
        if (!std.mem.eql(u8, header[0..4], &std.zip.central_file_header_sig)) {
            return error.CorruptZipArchive;
        }
        const name_len = read(Central, "filename_len", u16, header);
        const entry_name = try take(archive, &at, name_len);
        _ = try take(archive, &at, read(Central, "extra_len", u16, header) +
            @as(usize, read(Central, "comment_len", u16, header)));

        if (!std.mem.eql(u8, entry_name, name)) continue;
        return try readPayload(gpa, archive, header, max_size);
    }
    return null;
}

/// The end-of-central-directory record, which is what a zip reader has to
/// find first: it is the only fixed landmark, and it sits at the end.
///
/// The search runs backwards because the record may be followed by an archive
/// comment of any length, and a comment is free to contain the signature. The
/// last occurrence that has a whole record after it is the record.
///
/// (`std.zip.EndRecord.findBuffer` does the same job, but it
/// returns an error its own declared error set does not list, so it cannot be
/// called.)
fn findEndRecord(archive: []const u8) Error![]const u8 {
    if (archive.len < @sizeOf(End)) return error.NotAZipArchive;
    var start = archive.len - @sizeOf(End);
    while (true) : (start -= 1) {
        if (std.mem.eql(u8, archive[start..][0..4], &std.zip.end_record_sig)) {
            return archive[start..][0..@sizeOf(End)];
        }
        if (start == 0) return error.NotAZipArchive;
    }
}

/// Pulls one member's bytes out, following the central directory's entry to
/// the local header that precedes the payload.
///
/// The sizes come from the central directory rather than the local header: an
/// archiver that was streaming its output writes zeroes there and puts the
/// real numbers in a descriptor *after* the payload, which is no use to a
/// reader that has not read the payload yet.
fn readPayload(gpa: Allocator, archive: []const u8, header: []const u8, max_size: usize) Error![]u8 {
    var at: usize = read(Central, "local_file_header_offset", u32, header);
    const local = try take(archive, &at, @sizeOf(Local));
    if (!std.mem.eql(u8, local[0..4], &std.zip.local_file_header_sig)) {
        return error.CorruptZipArchive;
    }
    if (read(Local, "flags", u16, local) & 1 != 0) return error.UnsupportedZipFeature;
    _ = try take(archive, &at, read(Local, "filename_len", u16, local) +
        @as(usize, read(Local, "extra_len", u16, local)));

    const payload = try take(archive, &at, read(Central, "compressed_size", u32, header));
    // A cheap early out. It is only the directory's word for it, so the two
    // branches below each enforce the limit on what they actually produce.
    if (read(Central, "uncompressed_size", u32, header) > max_size) return error.ZipMemberTooLarge;

    return switch (@as(std.zip.CompressionMethod, @enumFromInt(read(Central, "compression_method", u16, header)))) {
        .store => if (payload.len > max_size) error.ZipMemberTooLarge else try gpa.dupe(u8, payload),
        .deflate => try inflate(gpa, payload, max_size),
        else => error.UnsupportedZipFeature,
    };
}

fn inflate(gpa: Allocator, payload: []const u8, max_size: usize) Error![]u8 {
    // The decompressor needs a whole window to resolve back-references
    // against, which is far too much to leave on the stack.
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);

    var compressed = std.Io.Reader.fixed(payload);
    var decompress = flate.Decompress.init(&compressed, .raw, window);
    return decompress.reader.allocRemaining(gpa, .limited(max_size)) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong => error.ZipMemberTooLarge,
        error.ReadFailed => error.CorruptZipArchive,
    };
}

/// One little-endian field of a zip record, located by name so the offsets
/// stay `std.zip`'s business rather than this file's.
fn read(comptime Record: type, comptime name: []const u8, comptime Int: type, bytes: []const u8) Int {
    return std.mem.readInt(Int, bytes[@offsetOf(Record, name)..][0..@divExact(@bitSizeOf(Int), 8)], .little);
}

/// `len` bytes from `at`, advancing it. Every read of the archive goes through
/// here, so a length field pointing off the end is an error rather than a
/// panic on a file the user only meant to open.
fn take(archive: []const u8, at: *usize, len: usize) Error![]const u8 {
    if (at.* > archive.len or len > archive.len - at.*) return error.CorruptZipArchive;
    defer at.* += len;
    return archive[at.*..][0..len];
}

// --- Test support --------------------------------------------------------

/// Builds an archive in memory. Used by this file's tests and by `bk2.zig`'s,
/// which is why it is public: a movie parser needs archives to parse, and a
/// generated one keeps both sets of tests free of binary fixtures while still
/// covering the compressed path a real archiver would take.
pub const TestMember = struct { name: []const u8, body: []const u8 };

pub fn buildTestArchive(
    gpa: Allocator,
    members: []const TestMember,
    method: std.zip.CompressionMethod,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var payloads: std.ArrayList([]u8) = .empty;
    defer {
        for (payloads.items) |p| gpa.free(p);
        payloads.deinit(gpa);
    }
    var offsets: std.ArrayList(u32) = .empty;
    defer offsets.deinit(gpa);

    for (members) |member| {
        try payloads.append(gpa, switch (method) {
            .store => try gpa.dupe(u8, member.body),
            .deflate => try deflateForTest(gpa, member.body),
            else => unreachable,
        });
    }

    for (members, payloads.items) |member, payload| {
        try offsets.append(gpa, @intCast(out.items.len));
        try out.appendSlice(gpa, &std.zip.local_file_header_sig);
        try appendInt(gpa, &out, u16, 20); // version needed
        try appendInt(gpa, &out, u16, 0); // flags
        try appendInt(gpa, &out, u16, @intFromEnum(method));
        try appendInt(gpa, &out, u32, 0); // time and date
        try appendInt(gpa, &out, u32, 0); // crc32, which this reader ignores
        try appendInt(gpa, &out, u32, @intCast(payload.len));
        try appendInt(gpa, &out, u32, @intCast(member.body.len));
        try appendInt(gpa, &out, u16, @intCast(member.name.len));
        try appendInt(gpa, &out, u16, 0); // extra length
        try out.appendSlice(gpa, member.name);
        try out.appendSlice(gpa, payload);
    }

    const cd_offset = out.items.len;
    for (members, payloads.items, offsets.items) |member, payload, local_offset| {
        try out.appendSlice(gpa, &std.zip.central_file_header_sig);
        try appendInt(gpa, &out, u16, 20); // version made by
        try appendInt(gpa, &out, u16, 20); // version needed
        try appendInt(gpa, &out, u16, 0); // flags
        try appendInt(gpa, &out, u16, @intFromEnum(method));
        try appendInt(gpa, &out, u32, 0); // time and date
        try appendInt(gpa, &out, u32, 0); // crc32
        try appendInt(gpa, &out, u32, @intCast(payload.len));
        try appendInt(gpa, &out, u32, @intCast(member.body.len));
        try appendInt(gpa, &out, u16, @intCast(member.name.len));
        try appendInt(gpa, &out, u16, 0); // extra length
        try appendInt(gpa, &out, u16, 0); // comment length
        try appendInt(gpa, &out, u16, 0); // disk number
        try appendInt(gpa, &out, u16, 0); // internal attributes
        try appendInt(gpa, &out, u32, 0); // external attributes
        try appendInt(gpa, &out, u32, local_offset);
        try out.appendSlice(gpa, member.name);
    }

    const cd_size = out.items.len - cd_offset;
    try out.appendSlice(gpa, &std.zip.end_record_sig);
    try appendInt(gpa, &out, u16, 0); // this disk
    try appendInt(gpa, &out, u16, 0); // disk holding the directory
    try appendInt(gpa, &out, u16, @intCast(members.len));
    try appendInt(gpa, &out, u16, @intCast(members.len));
    try appendInt(gpa, &out, u32, @intCast(cd_size));
    try appendInt(gpa, &out, u32, @intCast(cd_offset));
    try appendInt(gpa, &out, u16, 0); // comment length

    return out.toOwnedSlice(gpa);
}

fn appendInt(gpa: Allocator, out: *std.ArrayList(u8), comptime Int: type, value: Int) !void {
    var buf: [@divExact(@bitSizeOf(Int), 8)]u8 = undefined;
    std.mem.writeInt(Int, &buf, value, .little);
    try out.appendSlice(gpa, &buf);
}

fn deflateForTest(gpa: Allocator, body: []const u8) ![]u8 {
    var out = try std.Io.Writer.Allocating.initCapacity(gpa, 4096);
    errdefer out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);

    var compress = try flate.Compress.init(&out.writer, window, .raw, .default);
    try compress.writer.writeAll(body);
    try compress.finish();
    return out.toOwnedSlice();
}

// --- Tests ---------------------------------------------------------------

const testing = std.testing;

const log_name = "Input Log.txt";
const log_body = "[Input]\nLogKey:#Reset|\n|.|\n|r|\n[/Input]\n";

test "a member comes back byte for byte, stored or deflated" {
    const gpa = testing.allocator;
    for ([_]std.zip.CompressionMethod{ .store, .deflate }) |method| {
        const archive = try buildTestArchive(gpa, &.{
            .{ .name = "Header.txt", .body = "Platform NES\n" },
            .{ .name = log_name, .body = log_body },
        }, method);
        defer gpa.free(archive);

        const member = (try readMember(gpa, archive, log_name, 1 << 20)).?;
        defer gpa.free(member);
        try testing.expectEqualStrings(log_body, member);

        // And the member before it in the archive, so the walk of the
        // directory is not just finding whatever comes last.
        const header = (try readMember(gpa, archive, "Header.txt", 1 << 20)).?;
        defer gpa.free(header);
        try testing.expectEqualStrings("Platform NES\n", header);
    }
}

test "deflate really is compressing, so the stored path is not being tested twice" {
    const gpa = testing.allocator;
    const repetitive = "|..|........|........|\n" ** 200;
    const deflated = try deflateForTest(gpa, repetitive);
    defer gpa.free(deflated);
    try testing.expect(deflated.len < repetitive.len / 4);
}

test "a member that isn't there is absent, not an error" {
    const gpa = testing.allocator;
    const archive = try buildTestArchive(gpa, &.{.{ .name = "Header.txt", .body = "x" }}, .store);
    defer gpa.free(archive);

    try testing.expectEqual(@as(?[]u8, null), try readMember(gpa, archive, log_name, 1 << 20));
}

test "something that is not an archive is refused" {
    const gpa = testing.allocator;
    try testing.expectError(error.NotAZipArchive, readMember(gpa, "NES\x1a not a zip", "x", 1 << 20));
    try testing.expectError(error.NotAZipArchive, readMember(gpa, "", "x", 1 << 20));
}

test "a member larger than the caller allows is refused rather than allocated" {
    const gpa = testing.allocator;
    const archive = try buildTestArchive(gpa, &.{.{ .name = "big", .body = "0123456789" }}, .deflate);
    defer gpa.free(archive);

    try testing.expectError(error.ZipMemberTooLarge, readMember(gpa, archive, "big", 4));
}

test "a directory pointing outside the archive is an error, not a panic" {
    const gpa = testing.allocator;
    const archive = try buildTestArchive(gpa, &.{.{ .name = log_name, .body = log_body }}, .store);
    defer gpa.free(archive);

    // Keep the end record, but aim it past the end of the file.
    const damaged = try gpa.dupe(u8, archive);
    defer gpa.free(damaged);
    const record = damaged[damaged.len - @sizeOf(End) ..];
    std.mem.writeInt(u32, record[@offsetOf(End, "central_directory_offset")..][0..4], @intCast(archive.len), .little);

    try testing.expectError(error.CorruptZipArchive, readMember(gpa, damaged, log_name, 1 << 20));
}

test "a member whose compressed data is nonsense is an error, not a hang" {
    const gpa = testing.allocator;
    const archive = try buildTestArchive(gpa, &.{.{ .name = log_name, .body = log_body }}, .deflate);
    defer gpa.free(archive);

    const damaged = try gpa.dupe(u8, archive);
    defer gpa.free(damaged);
    // The payload follows the local header and the name; scribble over it.
    const payload_at = @sizeOf(Local) + log_name.len;
    @memset(damaged[payload_at..][0..8], 0xFF);

    try testing.expectError(error.CorruptZipArchive, readMember(gpa, damaged, log_name, 1 << 20));
}

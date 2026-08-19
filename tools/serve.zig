//! A static file server for developing the web app, and nothing more.
//!
//! It exists because `index.html` cannot be opened off the filesystem: a
//! `file://` page is not allowed to fetch the wasm module sitting beside it.
//! Something has to serve the directory over HTTP, and writing that something
//! in Zig is what keeps `zig build serve` working on a machine that has
//! nothing installed but Zig.
//!
//! Deliberately not a production server. It serves one directory, follows no
//! symlinks it was not pointed at, and has no interest in caching, ranges or
//! compression.

const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.Io.net;

const usage =
    \\usage: znes-serve DIRECTORY [--port N]
    \\
;

const default_port: u16 = 8080;

/// Enough for any request line and header block a browser will send us.
const head_buffer_size = 16 * 1024;

/// Ceiling on a file this will serve. The wasm module is the big one, and it
/// is nowhere near this even unoptimized.
const max_file_bytes = 64 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const stderr = std.Io.File.stderr();

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next(); // skip argv[0]

    var root: ?[]const u8 = null;
    var port = default_port;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            const value = args.next() orelse {
                try stderr.writeStreamingAll(io, "znes-serve: --port needs a number\n");
                return error.MissingPort;
            };
            port = std.fmt.parseInt(u16, value, 10) catch {
                try stderr.writeStreamingAll(io, "znes-serve: --port wants a port number\n");
                return error.BadPort;
            };
        } else if (root == null) {
            root = arg;
        } else {
            try stderr.writeStreamingAll(io, usage);
            return error.TooManyArguments;
        }
    }
    const directory = root orelse {
        try stderr.writeStreamingAll(io, usage);
        return error.MissingDirectory;
    };

    // Loopback only. This serves a working directory, and a working directory
    // is nobody else's business.
    const address: net.IpAddress = .{ .ip4 = .loopback(port) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    var message: [128]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(io, std.fmt.bufPrint(
        &message,
        "znes: serving {s} at http://127.0.0.1:{d}/\n",
        .{ directory, port },
    ) catch "znes: serving\n");

    accept(io, init.gpa, &server, directory);
}

/// One thread per connection, detached.
///
/// Browsers open connections speculatively and then sit on them, so a server
/// that handled one at a time would spend most of its life blocked in
/// `receiveHead` on a connection that has nothing to say, with the page's
/// actual requests queued behind it.
fn accept(io: std.Io, gpa: Allocator, server: *net.Server, directory: []const u8) void {
    while (true) {
        const stream = server.accept(io) catch continue;
        const thread = std.Thread.spawn(.{}, serve, .{ io, gpa, stream, directory }) catch {
            stream.close(io);
            continue;
        };
        thread.detach();
    }
}

fn serve(io: std.Io, gpa: Allocator, stream: net.Stream, directory: []const u8) void {
    defer stream.close(io);

    const in_buffer = gpa.alloc(u8, head_buffer_size) catch return;
    defer gpa.free(in_buffer);
    const out_buffer = gpa.alloc(u8, 64 * 1024) catch return;
    defer gpa.free(out_buffer);

    var reader = net.Stream.Reader.init(stream, io, in_buffer);
    var writer = net.Stream.Writer.init(stream, io, out_buffer);
    var http: std.http.Server = .init(&reader.interface, &writer.interface);

    while (true) {
        var request = http.receiveHead() catch return;
        respond(gpa, io, &request, directory) catch return;
        if (!request.head.keep_alive) return;
    }
}

fn respond(
    gpa: Allocator,
    io: std.Io,
    request: *std.http.Server.Request,
    directory: []const u8,
) !void {
    const relative = resolve(request.head.target) orelse {
        return request.respond("bad request\n", .{ .status = .bad_request });
    };

    const path = try std.fs.path.join(gpa, &.{ directory, relative });
    defer gpa.free(path);

    const body = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch {
        return request.respond("not found\n", .{ .status = .not_found });
    };
    defer gpa.free(body);

    try request.respond(body, .{
        .extra_headers = &.{
            .{ .name = "content-type", .value = mimeType(path) },
            // The whole point of running this is to see a change, so a cached
            // copy of the last one is never what is wanted.
            .{ .name = "cache-control", .value = "no-store" },
        },
    });
}

/// Turns a request target into a path within the served directory, or null if
/// it is not one.
///
/// Rejects rather than sanitizes: a target with a `..` in it is a request for
/// a file outside the directory, and answering a different question than the
/// one asked is how a path traversal gets through.
fn resolve(target: []const u8) ?[]const u8 {
    const without_query = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    if (!std.mem.startsWith(u8, without_query, "/")) return null;
    if (std.mem.indexOf(u8, without_query, "..") != null) return null;

    const relative = without_query[1..];
    return if (relative.len == 0) "index.html" else relative;
}

/// The content type matters for exactly one file here: `instantiateStreaming`
/// refuses a wasm module that does not arrive as `application/wasm`. The rest
/// are along for the ride.
fn mimeType(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    const table = .{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".wasm", "application/wasm" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".png", "image/png" },
        .{ ".ico", "image/x-icon" },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, extension, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}

// --- Tests ---------------------------------------------------------------

const testing = std.testing;

test "resolve maps the root to index.html and drops the query" {
    try testing.expectEqualStrings("index.html", resolve("/").?);
    try testing.expectEqualStrings("index.html", resolve("/?v=2").?);
    try testing.expectEqualStrings("znes.wasm", resolve("/znes.wasm").?);
    try testing.expectEqualStrings("znes.js", resolve("/znes.js?cachebust=1").?);
}

test "resolve refuses anything that could leave the directory" {
    try testing.expectEqual(@as(?[]const u8, null), resolve("/../build.zig"));
    try testing.expectEqual(@as(?[]const u8, null), resolve("/a/../../etc/passwd"));
    try testing.expectEqual(@as(?[]const u8, null), resolve("relative"));
}

test "mimeType names wasm the one way instantiateStreaming accepts" {
    try testing.expectEqualStrings("application/wasm", mimeType("/tmp/znes.wasm"));
    try testing.expectEqualStrings("text/html; charset=utf-8", mimeType("index.html"));
    try testing.expectEqualStrings("application/octet-stream", mimeType("rom.nes"));
}

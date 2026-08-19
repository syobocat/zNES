//! The text drawn over the picture: a transient message, a replay counter,
//! and what the window shows when it has nothing to run.
//!
//! Its own type because of the storage. An overlay is a list of slices, and
//! those slices have to point somewhere that outlives the `present` call they
//! are handed to -- so every line needs a buffer, and every list of lines
//! needs an array to be a slice of. That is seven fields whose only job is to
//! be pointable-at, and they were the least interesting thing in `App`.
//!
//! Nothing here draws. `list` returns what to draw and a platform decides how.

const std = @import("std");
const Osd = @This();
const interface = @import("interface");

/// How long a transient message stays on screen, in frames -- about three
/// seconds. Long enough to read an error, short enough not to sit over a game
/// you have gone back to playing.
const toast_frames: u32 = 180;

/// What the window shows when it has nothing to run.
const idle_lines = [_][:0]const u8{
    "zNES",
    "",
    "drop a .nes rom here",
};

toast_buf: [96:0]u8 = undefined,
toast_len: usize = 0,
toast_left: u32 = 0,

/// Scratch the per-frame overlay list is built in. It lives here rather than
/// on `list`'s stack because the list it returns points into it, and is
/// consumed by the `present` call on the next line.
overlay_buf: [3]interface.Overlay = undefined,
replay_buf: [40:0]u8 = undefined,
/// One-element arrays, so that a single line has an array to be a slice of.
replay_lines: [1][:0]const u8 = undefined,
toast_lines: [1][:0]const u8 = undefined,

pub const init: Osd = .{};

/// Where a replay has got to, for the counter in the corner.
pub const ReplayPosition = struct { frame: usize, total: usize };

/// Puts a short message on screen for a few seconds.
pub fn setToast(self: *Osd, comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrintZ(&self.toast_buf, fmt, args) catch blk: {
        // A message too long to show is still worth showing the start of.
        self.toast_buf[self.toast_buf.len - 1] = 0;
        break :blk self.toast_buf[0 .. self.toast_buf.len - 1 :0];
    };
    self.toast_len = written.len;
    self.toast_left = toast_frames;
}

/// Ages the transient message by one frame. Called once per iteration whether
/// or not there is a console running, so a toast fades on an empty screen too.
pub fn tick(self: *Osd) void {
    if (self.toast_left > 0) self.toast_left -= 1;
}

/// What to draw this frame. `replay` is the movie's position, or null when
/// nothing is being replayed; `idle` says there is no console to show.
///
/// The result borrows this `Osd` and is only good until the next call.
pub fn list(self: *Osd, idle: bool, replay: ?ReplayPosition) []const interface.Overlay {
    var count: usize = 0;

    if (idle) {
        self.overlay_buf[count] = .{ .lines = &idle_lines, .placement = .center };
        count += 1;
    }

    if (replay) |position| {
        self.replay_lines[0] = std.fmt.bufPrintZ(&self.replay_buf, "replay {d}/{d}", .{
            position.frame,
            position.total,
        }) catch "replay";
        self.overlay_buf[count] = .{ .lines = &self.replay_lines, .placement = .top_left };
        count += 1;
    }

    if (self.toast_left > 0) {
        self.toast_lines[0] = self.toast_buf[0..self.toast_len :0];
        self.overlay_buf[count] = .{ .lines = &self.toast_lines, .placement = .bottom_left };
        count += 1;
    }

    return self.overlay_buf[0..count];
}

// --- Tests ---------------------------------------------------------------

const testing = std.testing;

test "an idle screen shows the drop message and nothing else" {
    var osd: Osd = .init;
    const shown = osd.list(true, null);
    try testing.expectEqual(@as(usize, 1), shown.len);
    try testing.expectEqual(interface.Overlay.Placement.center, shown[0].placement);
}

test "a toast is shown for its lifetime and then stops" {
    var osd: Osd = .init;
    osd.setToast("saved {d}", .{7});
    try testing.expectEqualStrings("saved 7", osd.list(false, null)[0].lines[0]);

    for (0..toast_frames - 1) |_| osd.tick();
    try testing.expectEqual(@as(usize, 1), osd.list(false, null).len);
    osd.tick();
    try testing.expectEqual(@as(usize, 0), osd.list(false, null).len);
}

test "a message too long to fit is truncated rather than dropped" {
    var osd: Osd = .init;
    osd.setToast("{s}", .{"x" ** 500});
    const line = osd.list(false, null)[0].lines[0];
    try testing.expectEqual(@as(usize, 95), line.len);
    try testing.expectEqual(@as(u8, 'x'), line[0]);
}

test "all three overlays can be on screen at once, in a stable order" {
    var osd: Osd = .init;
    osd.setToast("hello", .{});
    const shown = osd.list(true, .{ .frame = 3, .total = 9 });
    try testing.expectEqual(@as(usize, 3), shown.len);
    try testing.expectEqual(interface.Overlay.Placement.center, shown[0].placement);
    try testing.expectEqual(interface.Overlay.Placement.top_left, shown[1].placement);
    try testing.expectEqualStrings("replay 3/9", shown[1].lines[0]);
    try testing.expectEqual(interface.Overlay.Placement.bottom_left, shown[2].placement);
}

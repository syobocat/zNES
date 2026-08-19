//! Where a cartridge's battery-backed RAM is kept on disk.
//!
//! Its own file because none of it is SDL. The only thing this needs from the
//! window system is the path to the application's data directory, which the
//! caller hands over -- so these rules can be tested without opening a window
//! or an audio device.
//!
//! Which save belongs to which cartridge is decided in `save.zig`, once, for
//! both backends. What is here is the directory this one keeps them in: a slot
//! is the file `<slot>.sav`, and the operations those rules need over it are a
//! read, a write, a rename and a walk.

const std = @import("std");
const save = @import("save");
const Saves = @This();

/// Ceiling on a save path: room for the directory, the longest slot name and
/// the extension.
const max_path = 2048;

/// Appended to a save's path to name the copy `load` sets aside.
const backup_suffix = ".bak";

/// What every save file ends in, and the only thing `Store.iterate` looks at
/// -- which is what keeps the backups above out of the search.
const extension = ".sav";

/// The application's data directory, ending in a separator, or null when the
/// platform could not name one -- in which case nothing is saved or loaded.
dir: ?[:0]const u8,
/// How to reach the filesystem. Null in a build that has none.
io: ?std.Io,

/// Restores `id`'s save into `into`, reporting whether it filled it.
///
/// Copies whatever is under the cartridge's own name aside as `.sav.bak` on
/// the way past. This runs once per cartridge adopted, so that copy holds the
/// save as it stood when play started; one rolled on every write would hold
/// the last second and undo nothing. What it covers is the file `save.load`
/// can neither claim nor identify well enough to file away -- a game that
/// corrupted its own save, or a headerless one of the wrong length.
pub fn load(self: Saves, id: save.Id, into: []u8) bool {
    const place = self.opened() orelse return false;
    place.keepGeneration(id.name);
    return save.load(place, id, into);
}

/// Writes `id`'s save out, best-effort. A failure is reported to nobody: it
/// happens once a second at most, the player cannot fix a full disk from
/// inside an emulator, and a toast per attempt would bury the screen.
pub fn store(self: Saves, id: save.Id, bytes: []const u8) void {
    const place = self.opened() orelse return;
    save.write(place, id, bytes);
}

fn opened(self: Saves) ?Store {
    return .{
        .dir = self.dir orelse return null,
        .io = self.io orelse return null,
    };
}

/// A save directory, in the shape `save.zig` asks for.
///
/// Saves live beside the application's other data rather than beside the ROM,
/// because the ROM's directory may not be writable (a read-only volume, a file
/// opened out of a downloads folder) and because a dropped file only ever
/// hands over a bare name anyway.
const Store = struct {
    /// Ends in a separator, as `SDL_GetPrefPath` guarantees.
    dir: []const u8,
    io: std.Io,

    /// The file a slot names, or null if it could not be one.
    ///
    /// A slot carrying a separator would reach outside the save directory.
    /// `save.zig` refuses one before its rules ever see it, but this is the
    /// single place every path here is built -- including `keepGeneration`,
    /// which is called with a name straight from the caller -- so the check
    /// belongs here rather than upstream of some of them.
    fn pathFor(self: Store, buf: *[max_path]u8, slot: []const u8) ?[]const u8 {
        if (slot.len == 0) return null;
        if (std.mem.indexOfAny(u8, slot, "/\\") != null) return null;
        return std.fmt.bufPrint(buf, "{s}{s}" ++ extension, .{ self.dir, slot }) catch null;
    }

    /// The slot's whole length, having filled as much of `into` as fits.
    ///
    /// The length reported is the file's rather than the read's, so a file
    /// longer than the board's save is recognised as the wrong size instead of
    /// being accepted as far as it goes.
    pub fn read(self: Store, slot: []const u8, into: []u8) ?usize {
        var buf: [max_path]u8 = undefined;
        const path = self.pathFor(&buf, slot) orelse return null;
        var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return null;
        defer file.close(self.io);

        const info = file.stat(self.io) catch return null;
        const total: usize = @intCast(info.size);
        var reader = file.reader(self.io, &.{});
        reader.interface.readSliceAll(into[0..@min(into.len, total)]) catch return null;
        return total;
    }

    /// Replaces a slot's contents, or creates it.
    ///
    /// The new contents go to a file of their own that is renamed over the
    /// save only once it is whole, so dying part-way through leaves the
    /// previous save intact instead of a truncated one. Losing a whole save to
    /// a write is the one case the save timer cannot bound, which is why the
    /// swap is worth the extra file.
    pub fn write(self: Store, slot: []const u8, bytes: []const u8) void {
        var buf: [max_path]u8 = undefined;
        const path = self.pathFor(&buf, slot) orelse return;

        var pending = std.Io.Dir.cwd().createFileAtomic(self.io, path, .{ .replace = true }) catch return;
        // Discards the half-written file if anything below fails, and is
        // required even after the rename succeeds.
        defer pending.deinit(self.io);

        pending.file.writeStreamingAll(self.io, bytes) catch return;
        // The rename is what makes the swap atomic; this is what carries it
        // through the machine losing power rather than just the process dying.
        // Failing it is no reason to withhold the new contents, since the file
        // being replaced is no safer.
        pending.file.sync(self.io) catch {};
        pending.replace(self.io) catch return;
    }

    pub fn rename(self: Store, from: []const u8, to: []const u8) void {
        var from_buf: [max_path]u8 = undefined;
        var to_buf: [max_path]u8 = undefined;
        const from_path = self.pathFor(&from_buf, from) orelse return;
        const to_path = self.pathFor(&to_buf, to) orelse return;
        const cwd = std.Io.Dir.cwd();
        cwd.rename(from_path, cwd, to_path, self.io) catch {};
    }

    /// Copies a slot aside, best-effort. There being nothing to copy is the
    /// ordinary case: a cartridge played for the first time has no file yet.
    pub fn keepGeneration(self: Store, slot: []const u8) void {
        var buf: [max_path]u8 = undefined;
        const path = self.pathFor(&buf, slot) orelse return;
        var backup_buf: [max_path + backup_suffix.len]u8 = undefined;
        const backup = std.fmt.bufPrint(&backup_buf, "{s}" ++ backup_suffix, .{path}) catch return;
        const cwd = std.Io.Dir.cwd();
        cwd.copyFile(path, cwd, backup, self.io, .{}) catch {};
    }

    pub fn iterate(self: Store) Iterator {
        const opened_dir = std.Io.Dir.cwd().openDir(self.io, self.dir, .{ .iterate = true }) catch null;
        return .{
            .io = self.io,
            .dir = opened_dir,
            .inner = if (opened_dir) |d| d.iterate() else null,
        };
    }

    /// Every save in the directory, named the way `save.zig` names slots: the
    /// file name with `.sav` taken off. Anything else in the directory is not
    /// a save and is passed over, which is how the `.sav.bak` copies stay out
    /// of the search.
    const Iterator = struct {
        io: std.Io,
        dir: ?std.Io.Dir,
        inner: ?std.Io.Dir.Iterator,

        pub fn next(self: *Iterator) ?[]const u8 {
            const inner = if (self.inner) |*it| it else return null;
            while (inner.next(self.io) catch null) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, extension)) continue;
                const slot = entry.name[0 .. entry.name.len - extension.len];
                if (slot.len == 0) continue;
                return slot;
            }
            self.close();
            return null;
        }

        pub fn close(self: *Iterator) void {
            if (self.dir) |*d| d.close(self.io);
            self.dir = null;
            self.inner = null;
        }
    };
};

// Three rules are worth pinning here, on top of the ones `save.zig` tests: a
// write lands whole or not at all, a rename of the ROM carries the file with
// it, and nothing but a `.sav` is mistaken for a save.

const testing = std.testing;

/// A save directory and nothing else, pointing at a temporary directory.
///
/// `dir` must outlive it and end in a separator, as `getPrefPath` guarantees.
fn saveOnly(dir: [:0]u8) Saves {
    return .{ .dir = dir, .io = testing.io };
}

/// `.zig-cache/tmp/<name>/`, NUL-terminated, for a directory `tmpDir` made.
fn tmpPath(buf: *[max_path]u8, tmp: *const testing.TmpDir) [:0]u8 {
    return std.fmt.bufPrintZ(buf, ".zig-cache/tmp/{s}/", .{tmp.sub_path}) catch unreachable;
}

fn idFor(name: []const u8, seed: u8) save.Id {
    return .{
        .name = name,
        .fingerprint = .{ .prg_len = 16384, .chr_len = 8192, .digest = @splat(seed) },
    };
}

test "a save round-trips through the save directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [max_path]u8 = undefined;
    const saves = saveOnly(tmpPath(&dir_buf, &tmp));
    const id = idFor("game.nes", 0xA1);

    const written = [_]u8{0xA5} ** 8192;
    saves.store(id, &written);

    var read: [8192]u8 = @splat(0);
    try testing.expect(saves.load(id, &read));
    try testing.expectEqualSlices(u8, &written, &read);
}

test "a missing save leaves the cartridge's RAM alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [max_path]u8 = undefined;
    const saves = saveOnly(tmpPath(&dir_buf, &tmp));

    var into = [_]u8{0x11} ** 64;
    try testing.expect(!saves.load(idFor("never-played.nes", 0xA1), &into));
    // Reporting failure is not enough: a partially-filled buffer would be a
    // corrupt save handed to the game.
    try testing.expect(std.mem.allEqual(u8, &into, 0x11));
}

test "renaming the ROM carries the save file with it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [max_path]u8 = undefined;
    const saves = saveOnly(tmpPath(&dir_buf, &tmp));

    const written = [_]u8{0xA5} ** 2048;
    saves.store(idFor("game.nes", 0xA1), &written);

    var read: [2048]u8 = @splat(0);
    try testing.expect(saves.load(idFor("Game (USA).nes", 0xA1), &read));
    try testing.expectEqualSlices(u8, &written, &read);

    // The file follows the ROM's new name, so the next boot needs no search.
    try tmp.dir.access(testing.io, "Game (USA).nes.sav", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "game.nes.sav", .{}));
}

test "a save of the wrong size is refused rather than padded or cut" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [max_path]u8 = undefined;
    const saves = saveOnly(tmpPath(&dir_buf, &tmp));

    // A 2 KiB save, then a board that wants 8 KiB. It names a different
    // cartridge, so this one has no save whatever the file is called.
    saves.store(idFor("game.nes", 0xA1), &[_]u8{0xA5} ** 2048);
    var big: [8192]u8 = @splat(0xEE);
    try testing.expect(!saves.load(idFor("game.nes", 0xB2), &big));
    try testing.expect(std.mem.allEqual(u8, &big, 0xEE));
}

test "the save as it stood when play started is kept aside" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [max_path]u8 = undefined;
    const saves = saveOnly(tmpPath(&dir_buf, &tmp));
    const id = idFor("game.nes", 0xA1);

    const at_boot = [_]u8{0xA5} ** 2048;
    saves.store(id, &at_boot);

    // Adopting the cartridge takes the copy. The writes during play do not,
    // or a second of play would be enough to lose the file being protected.
    var into: [2048]u8 = @splat(0);
    try testing.expect(saves.load(id, &into));
    saves.store(id, &[_]u8{0x5A} ** 2048);
    saves.store(id, &[_]u8{0x00} ** 2048);

    var buf: [4096]u8 = undefined;
    const kept = try tmp.dir.readFile(testing.io, "game.nes.sav.bak", &buf);
    try testing.expectEqualSlices(u8, &at_boot, kept[save.Header.len..]);
}

test "a backup is never mistaken for a save to search" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [max_path]u8 = undefined;
    const saves = saveOnly(tmpPath(&dir_buf, &tmp));

    const id = idFor("game.nes", 0xA1);
    saves.store(id, &[_]u8{0xA5} ** 2048);
    var into: [2048]u8 = @splat(0);
    try testing.expect(saves.load(id, &into)); // leaves a .sav.bak behind

    // Two files on disk now carry this fingerprint, and only the `.sav` is a
    // save. Taking the backup would leave the real one orphaned under its old
    // name.
    try testing.expect(saves.load(idFor("renamed.nes", 0xA1), &into));
    try tmp.dir.access(testing.io, "renamed.nes.sav", .{});
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "game.nes.sav", .{}));
}

test "a write leaves nothing behind but the save it was aimed at" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var dir_buf: [max_path]u8 = undefined;
    const saves = saveOnly(tmpPath(&dir_buf, &tmp));
    const id = idFor("game.nes", 0xA1);

    saves.store(id, &[_]u8{0xA5} ** 2048);
    saves.store(id, &[_]u8{0x5A} ** 2048);

    // The contents are staged under a name of their own and renamed into
    // place. That staging file has to be gone afterwards, or every second of
    // play would leave one in the save directory.
    var it = tmp.dir.iterate();
    var found: usize = 0;
    while (try it.next(testing.io)) |entry| {
        try testing.expectEqualStrings("game.nes.sav", entry.name);
        found += 1;
    }
    try testing.expectEqual(@as(usize, 1), found);
}

test "a name that could reach outside the directory cannot touch anything there" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // The save directory is a level down, so anything that climbs out of it
    // lands in `tmp` where this test can see it.
    try tmp.dir.createDirPath(testing.io, "saves");
    var dir_buf: [max_path]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dir_buf, ".zig-cache/tmp/{s}/saves/", .{tmp.sub_path}) catch unreachable;
    const saves = saveOnly(dir);

    // Something worth reaching for, one level above the save directory.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "outside.nes.sav", .data = "not yours" });

    // `save.zig` refuses these before its rules run, but the backup copy is
    // taken from the name exactly as handed over, so it is the directory that
    // has to refuse them.
    var into: [2048]u8 = @splat(0);
    for ([_][]const u8{ "../outside.nes", "..\\outside.nes", "" }) |name| {
        try testing.expect(!saves.load(idFor(name, 0xA1), &into));
        saves.store(idFor(name, 0xA1), &[_]u8{0x11} ** 2048);
    }

    // Nothing was written beside it, and it is untouched.
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "outside.nes.sav.bak", .{}));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("not yours", try tmp.dir.readFile(testing.io, "outside.nes.sav", &buf));
}

test "a search releases the directory it walked" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [max_path]u8 = undefined;
    const saves = saveOnly(tmpPath(&dir_buf, &tmp));

    saves.store(idFor("game.nes", 0xA1), &[_]u8{0x5A} ** 2048);

    // Every load below misses on the name and finds the save by walking the
    // directory, which means opening one. A walk that returns from inside
    // itself would keep that handle; the limit is too high to reach by
    // exhaustion, so the descriptors are counted instead.
    var into: [2048]u8 = @splat(0);
    try testing.expect(saves.load(idFor("first.nes", 0xA1), &into));
    const before = openDescriptors() orelse return error.SkipZigTest;

    var buf: [64]u8 = undefined;
    for (0..32) |i| {
        const name = try std.fmt.bufPrint(&buf, "take{d}.nes", .{i});
        try testing.expect(saves.load(idFor(name, 0xA1), &into));
    }

    try testing.expectEqual(before, openDescriptors() orelse return error.SkipZigTest);
    try testing.expect(std.mem.allEqual(u8, &into, 0x5A));
}

/// How many descriptors this process holds, or null where that cannot be
/// asked. Counting the same way on both sides cancels out the one this opens.
fn openDescriptors() ?usize {
    var dir = std.Io.Dir.cwd().openDir(testing.io, "/dev/fd", .{ .iterate = true }) catch return null;
    defer dir.close(testing.io);
    var it = dir.iterate();
    var n: usize = 0;
    while (it.next(testing.io) catch return null) |_| n += 1;
    return n;
}

test "with no filesystem behind it, storing and loading are no-ops" {
    var dir_buf: [max_path]u8 = undefined;
    var saves = saveOnly(std.fmt.bufPrintZ(&dir_buf, "unused/", .{}) catch unreachable);
    saves.io = null;

    var into = [_]u8{0x11} ** 64;
    saves.store(idFor("game.nes", 0xA1), &into); // must not fault
    try testing.expect(!saves.load(idFor("game.nes", 0xA1), &into));
}

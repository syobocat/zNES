//! The stored form of a cartridge's battery RAM, and the rules for finding it.
//!
//! Both backends keep saves in a flat namespace of named slots -- files in a
//! directory, or keys in a browser's `localStorage` -- so the awkward part is
//! the same on each: a slot is named after the ROM's file, and players rename
//! ROM files. The rules are written once here against any `store` that offers
//! the four operations `load` calls, so a backend supplies only those.
//!
//! A save carries a `Header` naming the cartridge it came off. That is what
//! makes these rules decidable: a slot can be opened and asked whether it
//! belongs to this cartridge, rather than trusted because of its name.
//!
//! A `store` is anything offering these four. Slot names carry no extension;
//! a store adds whatever its own namespace wants, which keeps a file's `.sav`
//! and a browser key's prefix out of the rules below.
//!
//!   read(slot, into) ?usize   the slot's whole length, having copied as much
//!                             of it as fits. Null when there is no such slot.
//!   write(slot, bytes) void   best-effort, replacing whatever was there
//!   rename(from, to) void     best-effort, replacing whatever `to` held
//!   iterate() Iterator        every slot in any order, `next()` returning a
//!                             name valid only until the call after it, and
//!                             `close()` releasing whatever the walk held

const std = @import("std");
const znes = @import("znes");

const Fingerprint = znes.Cartridge.Fingerprint;

/// Longest slot name handled, including the suffix `displacedSlot` adds.
pub const max_slot = 512;

/// The largest save any supported board has, and so the largest read back.
pub const max_bytes = 32 * 1024;

/// What a save starts with, before the RAM itself.
///
/// The encoded length is a multiple of three so a browser can decode one out
/// of base64 by slicing a fixed number of characters, without touching the
/// save behind it.
pub const Header = struct {
    fingerprint: Fingerprint,
    ram_len: u32,

    pub const magic = "ZNSV";
    pub const version = 1;
    pub const len = 33;

    comptime {
        std.debug.assert(len % 3 == 0);
    }

    pub fn encode(self: Header) [len]u8 {
        var out: [len]u8 = undefined;
        @memcpy(out[0..4], magic);
        out[4] = version;
        std.mem.writeInt(u32, out[5..9], self.fingerprint.prg_len, .little);
        std.mem.writeInt(u32, out[9..13], self.fingerprint.chr_len, .little);
        std.mem.writeInt(u32, out[13..17], self.ram_len, .little);
        @memcpy(out[17..33], &self.fingerprint.digest);
        return out;
    }

    /// The header `bytes` opens with, or null if it does not open with one.
    pub fn decode(bytes: []const u8) ?Header {
        if (bytes.len < len) return null;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return null;
        if (bytes[4] != version) return null;
        return .{
            .fingerprint = .{
                .prg_len = std.mem.readInt(u32, bytes[5..9], .little),
                .chr_len = std.mem.readInt(u32, bytes[9..13], .little),
                .digest = bytes[17..33].*,
            },
            .ram_len = std.mem.readInt(u32, bytes[13..17], .little),
        };
    }

    pub fn names(self: Header, cart: Fingerprint) bool {
        return self.fingerprint.prg_len == cart.prg_len and
            self.fingerprint.chr_len == cart.chr_len and
            std.mem.eql(u8, &self.fingerprint.digest, &cart.digest);
    }
};

/// A cartridge, and the slot its save is named after.
pub const Id = struct {
    /// The ROM's file name, already free of any directory.
    name: []const u8,
    fingerprint: Fingerprint,
};

/// Reads this cartridge's save into `into`, which must be exactly the length
/// the board has. Reports whether it filled it.
///
/// Looks under the ROM's own name first, which is where a save that has not
/// been renamed is. On a miss it searches every slot for one whose header
/// names this cartridge, and moves the winner into place so the next boot is a
/// direct hit. That is what survives a rename: the name stops being the only
/// route back to a save.
///
/// A save under our name belonging to a different cartridge is moved aside
/// rather than left to be overwritten, so a headed save is never destroyed by
/// a game that merely shares a file name with it.
pub fn load(store: anytype, id: Id, into: []u8) bool {
    if (into.len == 0 or into.len > max_bytes) return false;

    var slot_buf: [max_slot]u8 = undefined;
    const slot = slotFor(&slot_buf, id.name) orelse return false;

    // One window, reused for the slot named after the ROM and then for
    // whatever the search turns up. Only a header needs to outlive it.
    var window_buf: [Header.len + max_bytes]u8 = undefined;
    const window = window_buf[0 .. Header.len + into.len];

    if (store.read(slot, window)) |total| {
        switch (classify(window, total, into.len, id.fingerprint)) {
            .ours => |body| {
                @memcpy(into, body);
                return true;
            },
            // Headerless RAM can only ever be found by name, so this is the
            // one route by which a save written before headers existed comes
            // back. The next `write` gives it one.
            .legacy => {
                @memcpy(into, window[0..into.len]);
                return true;
            },
            // Moved now rather than once a save has been found for this
            // cartridge, because the write that follows takes this slot
            // whether or not the search below turns anything up.
            .stranger => moveAside(store, slot, window[0..Header.len].*),
            // Not a save this wrote and not the right length for one either,
            // so there is nothing to identify and nowhere to file it. The
            // write that follows replaces it.
            .unreadable => {},
        }
    }

    var other_buf: [max_slot]u8 = undefined;
    const other = searchFor(store, id, slot, into.len, &other_buf) orelse return false;

    // Read the winner before it moves, so a failure here leaves it where it
    // was rather than under a name whose save could not be read.
    const total = store.read(other, window) orelse return false;
    const body = switch (classify(window, total, into.len, id.fingerprint)) {
        .ours => |b| b,
        else => return false,
    };
    @memcpy(into, body);
    store.rename(other, slot);
    return true;
}

/// Writes this cartridge's save out, best-effort, under the ROM's own name.
/// Whatever `load` moved into place is already there, so this never searches.
pub fn write(store: anytype, id: Id, bytes: []const u8) void {
    if (bytes.len == 0 or bytes.len > max_bytes) return;
    var slot_buf: [max_slot]u8 = undefined;
    const slot = slotFor(&slot_buf, id.name) orelse return;

    var out: [Header.len + max_bytes]u8 = undefined;
    const header: Header = .{ .fingerprint = id.fingerprint, .ram_len = @intCast(bytes.len) };
    @memcpy(out[0..Header.len], &header.encode());
    @memcpy(out[Header.len..][0..bytes.len], bytes);
    store.write(slot, out[0 .. Header.len + bytes.len]);
}

/// The slot holding this cartridge's save under some other name, if one does.
fn searchFor(store: anytype, id: Id, skip: []const u8, ram_len: usize, out: *[max_slot]u8) ?[]const u8 {
    var head: [Header.len]u8 = undefined;
    var it = store.iterate();
    // A walk that finds what it wants returns from inside the loop, so an
    // iterator holding an open directory would leak one per search.
    defer it.close();
    while (it.next()) |candidate| {
        if (candidate.len > max_slot) continue;
        if (std.mem.eql(u8, candidate, skip)) continue;
        // Only the header is read. A namespace holds one slot per game ever
        // played, and all but one of them is about to be passed over.
        const total = store.read(candidate, &head) orelse continue;
        if (total != Header.len + ram_len) continue;
        const header = Header.decode(&head) orelse continue;
        if (header.ram_len != ram_len) continue;
        if (!header.names(id.fingerprint)) continue;
        @memcpy(out[0..candidate.len], candidate);
        return out[0..candidate.len];
    }
    return null;
}

/// Moves a save belonging to a different cartridge out of the way, to a name
/// derived from its own fingerprint -- stable, so re-displacing the same save
/// lands on the same slot, and still headed, so `searchFor` finds it if that
/// cartridge ever comes back.
fn moveAside(store: anytype, slot: []const u8, header_bytes: [Header.len]u8) void {
    const header = Header.decode(&header_bytes) orelse return;
    var buf: [max_slot]u8 = undefined;
    const aside = displacedSlot(&buf, slot, header.fingerprint) orelse return;
    store.rename(slot, aside);
}

/// What was found in a slot, given the board asking for it.
const Contents = union(enum) {
    /// A headed save for this cartridge; the payload is its RAM.
    ours: []const u8,
    /// Headerless RAM of exactly the right length, from before saves carried
    /// a header.
    legacy,
    /// A headed save for a different cartridge.
    stranger,
    /// Neither, so nothing can be said about it.
    unreadable,
};

/// A headed save is `Header.len` longer than the RAM in it, so it can never be
/// mistaken for the headerless RAM an earlier version wrote, whatever the
/// board's size.
fn classify(window: []const u8, total: usize, ram_len: usize, cart: Fingerprint) Contents {
    if (total == ram_len) return .legacy;
    if (total != Header.len + ram_len) return .unreadable;
    const header = Header.decode(window) orelse return .unreadable;
    if (header.ram_len != ram_len) return .unreadable;
    if (!header.names(cart)) return .stranger;
    return .{ .ours = window[Header.len..][0..ram_len] };
}

/// The slot a cartridge's save is named after: the ROM's own file name.
///
/// A name carrying a separator would escape a directory. Nothing should send
/// one -- callers pass a basename -- so refuse rather than sanitise.
fn slotFor(buf: *[max_slot]u8, rom_name: []const u8) ?[]const u8 {
    if (rom_name.len == 0 or rom_name.len > max_slot - displaced_suffix_len) return null;
    if (std.mem.indexOfAny(u8, rom_name, "/\\") != null) return null;
    @memcpy(buf[0..rom_name.len], rom_name);
    return buf[0..rom_name.len];
}

/// `.` plus eight hex digits.
const displaced_suffix_len = 9;

fn displacedSlot(buf: *[max_slot]u8, slot: []const u8, cart: Fingerprint) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}.{x}", .{ slot, cart.digest[0..4] }) catch null;
}

// --- Tests ---------------------------------------------------------------
//
// Run against a store held in memory, so what is pinned is the policy --
// which slot is read, which is written, what moves where -- rather than any
// one backend's idea of a file.

const testing = std.testing;

const FakeStore = struct {
    const max_name = 64;
    const max_data = Header.len + 4096;

    const Slot = struct {
        name: [max_name]u8 = undefined,
        name_len: usize = 0,
        data: [max_data]u8 = undefined,
        data_len: usize = 0,
        live: bool = false,
    };

    slots: [8]Slot = @splat(.{}),

    fn find(self: *FakeStore, name: []const u8) ?*Slot {
        for (&self.slots) |*slot| {
            if (slot.live and std.mem.eql(u8, slot.name[0..slot.name_len], name)) return slot;
        }
        return null;
    }

    fn read(self: *FakeStore, name: []const u8, into: []u8) ?usize {
        const slot = self.find(name) orelse return null;
        const stored = slot.data[0..slot.data_len];
        const n = @min(into.len, stored.len);
        @memcpy(into[0..n], stored[0..n]);
        return stored.len;
    }

    fn write(self: *FakeStore, name: []const u8, bytes: []const u8) void {
        const slot = self.find(name) orelse blk: {
            for (&self.slots) |*empty| {
                if (!empty.live) break :blk empty;
            }
            unreachable; // no test below fills it
        };
        slot.live = true;
        slot.name_len = name.len;
        @memcpy(slot.name[0..name.len], name);
        slot.data_len = bytes.len;
        @memcpy(slot.data[0..bytes.len], bytes);
    }

    fn rename(self: *FakeStore, from: []const u8, to: []const u8) void {
        const slot = self.find(from) orelse return;
        if (self.find(to)) |occupant| occupant.live = false;
        slot.name_len = to.len;
        @memcpy(slot.name[0..to.len], to);
    }

    const Iterator = struct {
        store: *FakeStore,
        index: usize = 0,

        fn next(self: *Iterator) ?[]const u8 {
            while (self.index < self.store.slots.len) {
                const slot = &self.store.slots[self.index];
                self.index += 1;
                if (slot.live) return slot.name[0..slot.name_len];
            }
            return null;
        }

        pub fn close(_: *Iterator) void {}
    };

    fn iterate(self: *FakeStore) Iterator {
        return .{ .store = self };
    }

    fn has(self: *FakeStore, name: []const u8) bool {
        return self.find(name) != null;
    }

    fn count(self: *FakeStore) usize {
        var n: usize = 0;
        for (&self.slots) |slot| {
            if (slot.live) n += 1;
        }
        return n;
    }
};

fn idFor(name: []const u8, seed: u8) Id {
    return .{
        .name = name,
        .fingerprint = .{ .prg_len = 16384, .chr_len = 8192, .digest = @splat(seed) },
    };
}

test "a save round-trips through the slot named after the ROM" {
    var store: FakeStore = .{};
    const id = idFor("game.nes", 0xA1);

    write(&store, id, &[_]u8{0x5A} ** 2048);
    try testing.expect(store.has("game.nes"));

    var into: [2048]u8 = @splat(0);
    try testing.expect(load(&store, id, &into));
    try testing.expect(std.mem.allEqual(u8, &into, 0x5A));
}

test "a renamed ROM finds its save and takes it under the new name" {
    var store: FakeStore = .{};
    write(&store, idFor("game.nes", 0xA1), &[_]u8{0x5A} ** 2048);

    // The same cartridge, renamed on disk. Nothing is under the name it looks
    // for, so only the fingerprint can lead back to the save.
    var into: [2048]u8 = @splat(0);
    try testing.expect(load(&store, idFor("Game (USA).nes", 0xA1), &into));
    try testing.expect(std.mem.allEqual(u8, &into, 0x5A));

    // Moved rather than copied: the next boot is a direct hit, and no
    // duplicate is left behind to go stale.
    try testing.expect(store.has("Game (USA).nes"));
    try testing.expect(!store.has("game.nes"));
    try testing.expectEqual(@as(usize, 1), store.count());
}

test "a save under our name belonging to another cartridge is refused" {
    var store: FakeStore = .{};
    write(&store, idFor("game.nes", 0xA1), &[_]u8{0x5A} ** 2048);

    var into: [2048]u8 = @splat(0xEE);
    try testing.expect(!load(&store, idFor("game.nes", 0xB2), &into));
    // Left alone rather than partly filled: half a save handed to a game is
    // worse than none.
    try testing.expect(std.mem.allEqual(u8, &into, 0xEE));
}

test "the cartridge already holding our name is moved aside, not overwritten" {
    var store: FakeStore = .{};
    const first = idFor("game.nes", 0xA1);
    write(&store, first, &[_]u8{0x5A} ** 2048);

    // A different ROM that happens to have the same file name. It finds
    // nothing of its own and takes the slot -- but only after what was there
    // has somewhere else to live.
    const second = idFor("game.nes", 0xB2);
    var into: [2048]u8 = @splat(0);
    _ = load(&store, second, &into);
    write(&store, second, &[_]u8{0x11} ** 2048);

    // The displaced save is still headed, so its own cartridge gets it back
    // by fingerprint.
    var back: [2048]u8 = @splat(0);
    try testing.expect(load(&store, first, &back));
    try testing.expect(std.mem.allEqual(u8, &back, 0x5A));
}

test "a headerless save from before headers existed is adopted and upgraded" {
    var store: FakeStore = .{};
    const id = idFor("game.nes", 0xA1);

    // What the previous version wrote: the RAM, and nothing else.
    store.write("game.nes", &[_]u8{0x77} ** 2048);

    var into: [2048]u8 = @splat(0);
    try testing.expect(load(&store, id, &into));
    try testing.expect(std.mem.allEqual(u8, &into, 0x77));

    // The next write gives it a header, after which it survives a rename like
    // any other save.
    write(&store, id, &into);
    var back: [2048]u8 = @splat(0);
    try testing.expect(load(&store, idFor("renamed.nes", 0xA1), &back));
    try testing.expect(std.mem.allEqual(u8, &back, 0x77));
}

test "a headerless save of the wrong length is not adopted by name" {
    var store: FakeStore = .{};
    // Some other board's size, and nothing in it says whose it is. The only
    // safe reading is that this cartridge has no save.
    store.write("game.nes", &[_]u8{0x77} ** 2048);

    var into: [8192]u8 = @splat(0xEE);
    try testing.expect(!load(&store, idFor("game.nes", 0xA1), &into));
    try testing.expect(std.mem.allEqual(u8, &into, 0xEE));
}

test "a header survives encoding" {
    const header: Header = .{
        .fingerprint = .{ .prg_len = 131072, .chr_len = 0, .digest = @splat(0x3C) },
        .ram_len = 8192,
    };
    const bytes = header.encode();
    const back = Header.decode(&bytes).?;
    try testing.expectEqual(header.ram_len, back.ram_len);
    try testing.expectEqual(header.fingerprint.prg_len, back.fingerprint.prg_len);
    try testing.expectEqual(header.fingerprint.chr_len, back.fingerprint.chr_len);
    try testing.expect(back.names(header.fingerprint));

    // Refusing anything else is what leaves a headerless save of the right
    // length readable as one.
    try testing.expectEqual(@as(?Header, null), Header.decode("not a save at all, but long enough"));
    try testing.expectEqual(@as(?Header, null), Header.decode(bytes[0 .. Header.len - 1]));
}

test "a ROM name that could reach outside the namespace has no slot" {
    var buf: [max_slot]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), slotFor(&buf, "../escape.nes"));
    try testing.expectEqual(@as(?[]const u8, null), slotFor(&buf, "sub\\escape.nes"));
    try testing.expectEqual(@as(?[]const u8, null), slotFor(&buf, ""));
    try testing.expectEqualStrings("game.nes", slotFor(&buf, "game.nes").?);
}

//! Web entry point: the surface the page calls, and nothing else.
//!
//! A wasm module has no `main` -- the browser instantiates it and then calls
//! its exports -- so this file is the loop's other half. `static/znes.js`
//! drives `znesTick` from `requestAnimationFrame`, having first pushed in
//! whatever the user did since the last frame.
//!
//! Everything here is a thin shell over `App`, which is the same `App` the
//! desktop build runs. The only things that live at this boundary are the
//! ones a wasm signature cannot express: a byte buffer for files coming in,
//! and errors turned into something the page can print.
//!
//! The exports below survive linking because the wasm module is built with
//! `rdynamic`. wasm-ld drops anything unreachable from a root, and `export fn`
//! alone is not one.

const std = @import("std");

const App = @import("app");
const Platform = @import("platform");
const input = @import("input");
const znes = @import("znes");

/// The whole application, for the life of the tab. It is a global because the
/// page holds pointers *into* it across calls -- the framebuffer and the
/// overlay buffer are fields of the platform inside it -- and because there is
/// nowhere else to put it: no stack frame spans the calls the browser makes.
///
/// The pointer exports below are addresses within this, so they stay good for
/// as long as the tab does. The page re-reads them every frame regardless,
/// since growing wasm memory detaches any view built over it.
var app: App = undefined;
var started = false;

/// Where a file's name and bytes arrive from the page, laid out as the name
/// first and the contents straight after it. One buffer rather than two
/// because the page fills it in one pass and `znesOpen` reads it in one pass;
/// splitting it would only add a second capacity to get wrong.
var staging: std.ArrayList(u8) = .empty;

/// Longest file name accepted. Anything longer is refused rather than cut
/// short -- a truncated name would label the window with the wrong file.
const max_name_bytes = 512;

/// `std.heap.wasm_allocator` is a real allocator backed by `memory.grow`,
/// which is what lets a ROM of any size be loaded without the module
/// reserving for the largest imaginable one up front.
const gpa = std.heap.wasm_allocator;

/// Panics become a message in the browser's console instead of a bare trap,
/// which is otherwise all a freestanding wasm module can manage.
pub const panic = std.debug.FullPanic(reportPanic);

fn reportPanic(message: []const u8, first_trace_address: ?usize) noreturn {
    _ = first_trace_address;
    host.report(message.ptr, message.len);
    @trap();
}

const host = struct {
    /// Logs a message for the developer. Nothing is returned: there is
    /// nothing useful this side could do about a failure to report.
    extern "znes" fn report(ptr: [*]const u8, len: usize) void;
};

// --- Startup -------------------------------------------------------------

/// Brings the app up. Returns false if it could not start, having already
/// said why through `host.report`.
export fn znesInit() bool {
    app.init(gpa, .{}) catch |err| {
        report("cannot start", err);
        return false;
    };
    started = true;
    return true;
}

// --- Files ---------------------------------------------------------------

/// Reserves `len` bytes for the page to write a file into, and returns where
/// they start. Null if there is not that much memory to be had.
///
/// **This can grow the module's memory, which detaches every `ArrayBuffer`
/// view the page is holding.** So can `znesOpen`, which allocates for the ROM
/// it keeps. The page rebuilds its views after either; see `refreshViews` in
/// `static/znes.js`.
export fn znesReserve(len: usize) ?[*]u8 {
    staging.resize(gpa, len) catch return null;
    return staging.items.ptr;
}

/// Opens the file now sitting in the reserved buffer: the first `name_len`
/// bytes are its name, the `data_len` after that are its contents.
///
/// Failure is reported on screen rather than returned, the same way a file
/// dropped on the desktop window is -- see `App.openDropped`. Every file that
/// reaches here arrived by the user's hand, and none of them are worth
/// stopping the emulator for.
export fn znesOpen(name_len: usize, data_len: usize) void {
    if (!started) return;
    if (name_len > max_name_bytes or name_len + data_len > staging.items.len) {
        app.setToast("cannot read that file", .{});
        return;
    }
    app.openDropped(staging.items[0..name_len], staging.items[name_len..][0..data_len]);
}

// --- The loop ------------------------------------------------------------

/// Runs one frame. The page calls this once for every frame that has come
/// due since the last one -- usually once, occasionally none or two, which is
/// how a display that does not refresh at the console's rate is kept from
/// running it fast or slow.
export fn znesTick() void {
    if (!started) return;
    const state = app.pollInput();
    app.tick(state) catch |err| report("frame failed", err);
}

/// The finished picture, RGBA8888, 256x240.
export fn znesFramebuffer() [*]const u8 {
    return &app.platform.framebuffer;
}

/// This frame's overlay text, in the format `WebPlatform.encodeOverlays`
/// documents. The length changes every frame.
export fn znesOverlayPtr() [*]const u8 {
    return &app.platform.overlay;
}

export fn znesOverlayLen() usize {
    if (!started) return 0;
    return app.platform.overlay_len;
}

/// What the page should put in `document.title`. UTF-8, not terminated.
export fn znesTitlePtr() [*]const u8 {
    return &app.platform.title;
}

export fn znesTitleLen() usize {
    if (!started) return 0;
    return app.platform.title_len;
}

// --- Constants the page would otherwise have to hard-code ----------------
//
// Each of these is a fact about the console or the app that `znes.js` needs
// and cannot derive. Exporting them beats writing them down twice, which is a
// silent desync the moment either side changes.

export fn znesScreenWidth() u32 {
    return znes.screen_width;
}

export fn znesScreenHeight() u32 {
    return znes.screen_height;
}

export fn znesPlayerCount() u32 {
    return input.player_count;
}

export fn znesSampleRate() u32 {
    return App.audio_sample_rate;
}

/// NTSC frames per second, for pacing the page's loop.
export fn znesFrameRate() f64 {
    return znes.frame_rate;
}

// --- Input ---------------------------------------------------------------

/// Replaces one player's held buttons. `mask` is bit-per-button in
/// `input.Buttons` order, which is also the console's own order.
export fn znesSetButtons(player: u32, mask: u8) void {
    if (!started) return;
    app.platform.setButtons(player, @as(input.Buttons, @bitCast(mask)));
}

/// Points the light gun at a canvas pixel, in the console's own 256x240
/// coordinates. `on_screen` false means the muzzle is off the picture, which
/// a game can tell from a gun that is merely aimed at something black.
export fn znesSetGun(x: u32, y: u32, on_screen: bool, trigger: bool) void {
    if (!started) return;
    app.platform.setGun(.{
        .x = @truncate(x),
        .y = @truncate(y),
        .on_screen = on_screen,
        .trigger = trigger,
    });
}

/// Presses one of the console's own buttons. A bool rather than the enum
/// `App` uses, because that is as much as a wasm signature can carry.
export fn znesPressConsoleButton(power: bool) void {
    if (!started) return;
    app.platform.pressConsoleButton(if (power) .power else .reset);
}

/// Plugs the next thing into the controller ports: two pads, a Zapper, and
/// back round.
export fn znesCyclePeripherals() void {
    if (!started) return;
    app.platform.cyclePeripherals();
}

// --- Reporting -----------------------------------------------------------

/// Sends a failure to the browser's console, naming the error. There is no
/// stderr here and no stack trace worth the size it would cost, so the name
/// is the whole of what can be said.
fn report(context: []const u8, err: anyerror) void {
    var buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "znes: {s}: {s}", .{ context, @errorName(err) }) catch
        "znes: something went wrong";
    host.report(message.ptr, message.len);
}

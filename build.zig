//! The module graph, bottom to top:
//!
//!     znes       the emulation core, which knows nothing else
//!     input      the controller vocabulary the two layers above share
//!     interface  the types `app` and a backend pass across the seam, and
//!                the compile-time check that a backend implements it
//!     platform   one backend: a window and an audio device, or a canvas
//!     app        everything between the two, and the only thing that has
//!                opinions about how an emulator should behave
//!
//! `platform` is the seam: `app` imports it by name and never learns which
//! backend answered. Building for the web swaps `SdlPlatform` for
//! `WebPlatform` there and changes nothing else. `interface.verify` turns a
//! backend that has drifted out of shape into a compile error rather than a
//! surprise at link time.
//!
//! On disk:
//!
//!     src/core/       the emulation core, by chip: cpu/ ppu/ apu/, plus
//!                     cart/ for the cartridge and its mappers,
//!                     peripheral/ for what plugs into the ports, and
//!                     video/ for the palette everyone reads
//!     src/platform/   interface.zig and input.zig, then one directory per
//!                     backend: sdl/ and web/
//!     src/app/        the emulator's own behaviour, backend-agnostic
//!     src/desktop/    and src/web/, the two entry points and the web page

const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const desktop = buildDesktop(b, target, optimize);
    const web = buildWeb(b, optimize);
    buildTests(b, desktop, target, optimize);
    serve(b, web, optimize);
}

// --- Desktop -------------------------------------------------------------

const Desktop = struct {
    core: *std.Build.Module,
    app: *std.Build.Module,
    /// The SDL backend, kept so its own tests can be built. Only the battery
    /// save path is testable without a display; see the tests in that file.
    platform: *std.Build.Module,
    exe: *std.Build.Step.Compile,
};

fn buildDesktop(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Desktop {
    // The one module this package publishes to anyone depending on it.
    const core = b.addModule("znes", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const in = inputModule(b, target, optimize);
    // One instance, shared: two modules built from the same file are two
    // distinct types, so a backend and `app` given separate copies would not
    // agree on `InputState` at all.
    const sav = saveModule(b, target, optimize, core);
    const iface = interfaceModule(b, target, optimize, core, in, sav);

    const platform = b.createModule(.{
        .root_source_file = b.path("src/platform/sdl/SdlPlatform.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "znes", .module = core },
            .{ .name = "input", .module = in },
            .{ .name = "interface", .module = iface },
            .{ .name = "save", .module = sav },
            .{ .name = "sdl", .module = sdlModule(b, target, optimize) },
        },
    });

    const app = appModule(b, target, optimize, core, in, iface, platform);

    const exe = b.addExecutable(.{
        .name = "znes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/desktop/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "app", .module = app }},
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    return .{ .core = core, .app = app, .platform = platform, .exe = exe };
}

// --- Web -----------------------------------------------------------------

/// Where `zig build wasm` puts the page, relative to the install prefix.
const web_dir = "web";

const Web = struct {
    /// The `wasm` step, so that anything wanting a built page -- `serve` --
    /// can depend on the whole of it rather than on one of its halves.
    step: *std.Build.Step,
};

fn buildWeb(b: *std.Build, optimize: std.builtin.OptimizeMode) Web {
    // The browser picks the target, not the command line, so this one is
    // pinned rather than taken from `standardTargetOptions`.
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const core = coreModule(b, target, optimize);
    const in = inputModule(b, target, optimize);
    const sav = saveModule(b, target, optimize, core);
    const iface = interfaceModule(b, target, optimize, core, in, sav);

    const platform = b.createModule(.{
        .root_source_file = b.path("src/platform/web/WebPlatform.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "znes", .module = core },
            .{ .name = "input", .module = in },
            .{ .name = "interface", .module = iface },
            .{ .name = "save", .module = sav },
        },
    });

    const app = appModule(b, target, optimize, core, in, iface, platform);

    // A wasm module is an executable with no entry point: the browser calls
    // its exports directly rather than running a `main`.
    const wasm = b.addExecutable(.{
        .name = "znes",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "app", .module = app },
                .{ .name = "platform", .module = platform },
                .{ .name = "input", .module = in },
                .{ .name = "znes", .module = core },
            },
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    const install_wasm = b.addInstallFileWithDir(
        wasm.getEmittedBin(),
        .{ .custom = web_dir },
        "znes.wasm",
    );
    const install_static = b.addInstallDirectory(.{
        .source_dir = b.path("src/web/static"),
        .install_dir = .{ .custom = web_dir },
        .install_subdir = "",
    });

    const wasm_step = b.step("wasm", "Build the web app into zig-out/" ++ web_dir);
    wasm_step.dependOn(&install_wasm.step);
    wasm_step.dependOn(&install_static.step);

    return .{ .step = wasm_step };
}

/// `zig build serve`: a static file server, so that developing the web app
/// needs nothing installed that building it did not already need. Opening
/// `index.html` off the filesystem is not an option -- a `file://` page is
/// not allowed to fetch the wasm module beside it.
fn serve(b: *std.Build, web: Web, optimize: std.builtin.OptimizeMode) void {
    const server = b.addExecutable(.{
        .name = "znes-serve",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/serve.zig"),
            // The host's, whatever that is: this one never leaves the machine
            // it was built on.
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });

    const run = b.addRunArtifact(server);
    run.addArg(b.getInstallPath(.{ .custom = web_dir }, ""));
    if (b.args) |args| run.addArgs(args);
    // The whole page, wasm included: serving a stale module beside fresh
    // JavaScript is a confusing way to spend an afternoon.
    run.step.dependOn(web.step);

    const serve_step = b.step("serve", "Build the web app and serve it over HTTP");
    serve_step.dependOn(&run.step);
}

// --- Tests ---------------------------------------------------------------

fn buildTests(
    b: *std.Build,
    desktop: Desktop,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const core_tests = b.addTest(.{ .root_module = desktop.core });
    const app_tests = b.addTest(.{ .root_module = desktop.app });
    const exe_tests = b.addTest(.{ .root_module = desktop.exe.root_module });
    const sdl_tests = b.addTest(.{ .root_module = desktop.platform });
    // These two get their own compiles: a module's tests are collected only
    // when it is the root of one, so neither's would run as part of `app`'s.
    const input_tests = b.addTest(.{ .root_module = inputModule(b, target, optimize) });
    // The battery-save rules are plain `std.Io`, so they get their own compile
    // and this one does not have to link SDL to run them.
    const saves_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/sdl/saves.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "save", .module = saveModule(b, target, optimize, coreModule(b, target, optimize)) },
            },
        }),
    });
    // Which slot a save is found in is decided the same way on both backends,
    // so it is tested once against a store held in memory.
    const save_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/save.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "znes", .module = coreModule(b, target, optimize) },
            },
        }),
    });
    const interface_tests = b.addTest(.{
        .root_module = blk: {
            const core = coreModule(b, target, optimize);
            break :blk interfaceModule(
                b,
                target,
                optimize,
                core,
                inputModule(b, target, optimize),
                saveModule(b, target, optimize, core),
            );
        },
    });
    const web = webHostModules(b, target, optimize);
    const web_tests = b.addTest(.{ .root_module = web.platform });
    // `App` compiled against the web backend. `zig build wasm` is the only
    // other thing that does this, and it is in no test step -- so without
    // this, a change to `App` could break the web build with every test
    // still green.
    const web_app_tests = b.addTest(.{ .root_module = web.app });
    const serve_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/serve.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const nes_test_roms = buildRomTest(b, desktop.core, optimize, "src/core/tests/nes_test_roms.zig");
    const accuracy_coin = buildRomTest(b, desktop.core, optimize, "src/core/tests/accuracy_coin.zig");

    const quick = [_]*std.Build.Step.Compile{
        core_tests, input_tests,   interface_tests, app_tests,
        exe_tests,  sdl_tests,     saves_tests,     save_tests,
        web_tests,  web_app_tests, serve_tests,
    };

    const test_step = b.step("test", "Run tests");
    const test_full_step = b.step("test-full", "Run all tests (takes several minutes)");
    for (quick) |compile| {
        const run = b.addRunArtifact(compile);
        test_step.dependOn(&run.step);
        test_full_step.dependOn(&run.step);
    }
    test_full_step.dependOn(&b.addRunArtifact(nes_test_roms).step);
    test_full_step.dependOn(&b.addRunArtifact(accuracy_coin).step);
}

/// The web backend, and `App` on top of it, built for the host so that both
/// can be tested here.
///
/// The backend only ever runs for real inside a browser, but the parts worth
/// testing -- the overlay encoding, the input latching -- are plain Zig that
/// never reaches the `host` externs, and those parts are much easier to get
/// wrong than they are to check. Compiling `App` against it additionally
/// type-checks the seam, which is what `interface.verify` reports on.
fn webHostModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) struct { platform: *std.Build.Module, app: *std.Build.Module } {
    const core = coreModule(b, target, optimize);
    const in = inputModule(b, target, optimize);
    const sav = saveModule(b, target, optimize, core);
    const iface = interfaceModule(b, target, optimize, core, in, sav);
    const platform = b.createModule(.{
        .root_source_file = b.path("src/platform/web/WebPlatform.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "znes", .module = core },
            .{ .name = "input", .module = in },
            .{ .name = "interface", .module = iface },
            .{ .name = "save", .module = sav },
        },
    });
    return .{
        .platform = platform,
        .app = appModule(b, target, optimize, core, in, iface, platform),
    };
}

fn buildRomTest(
    b: *std.Build,
    core: *std.Build.Module,
    optimize: std.builtin.OptimizeMode,
    root_source_file: []const u8,
) *std.Build.Step.Compile {
    return b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_source_file),
            .target = .{ .query = .{}, .result = builtin.target },
            .optimize = optimize,
            .imports = &.{.{ .name = "znes", .module = core }},
        }),
    });
}

// --- Shared modules ------------------------------------------------------

fn coreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });
}

fn inputModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/platform/input.zig"),
        .target = target,
        .optimize = optimize,
    });
}

/// The types `app` and a platform backend share, plus the compile-time check
/// that a backend implements what `app` calls. Both sides import it, which is
/// what makes the seam checkable rather than merely conventional.
fn interfaceModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
    in: *std.Build.Module,
    sav: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/platform/interface.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "znes", .module = core },
            .{ .name = "input", .module = in },
            .{ .name = "save", .module = sav },
        },
    });
}

fn saveModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/platform/save.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "znes", .module = core }},
    });
}

fn appModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
    in: *std.Build.Module,
    iface: *std.Build.Module,
    platform: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/app/App.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "znes", .module = core },
            .{ .name = "input", .module = in },
            .{ .name = "interface", .module = iface },
            .{ .name = "platform", .module = platform },
        },
    });
}

fn sdlModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const is_release = optimize != .Debug;
    return b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
        .c_sdl_strip = is_release,
        // Darwin's linker rejects SDL's LTO objects, so it is only enabled
        // where it actually works.
        .c_sdl_lto = if (is_release and target.result.os.tag != .macos)
            std.zig.LtoMode.full
        else
            std.zig.LtoMode.none,
        // SDL trips UBSan's function-pointer-type check on its own callback
        // tables, which is a false positive for C code built this way.
        .c_sdl_sanitize_c = .off,
    }).module("sdl3");
}

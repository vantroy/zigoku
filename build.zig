const std = @import("std");

// Generated vendored-libwebp decoder file list (scripts/vendor-libwebp.sh).
// Imported rather than hand-typed so the compiled set never drifts from the
// files on disk — see the addCSourceFiles call in build().
const webp_decoder = @import("src/c/webp/decoder_srcs.zig");

// Decoder-level image-dimension backstop, shared with cover.zig so the stb and
// libwebp decode-bomb caps can't drift. Injected into the stb shim below.
const decode_limits = @import("src/decode_limits.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Bundle SQLite: compile the vendored amalgamation straight into the binary
    // instead of dynamically linking system libsqlite3. The default is keyed to
    // the *target* OS:
    //
    //   * Linux  → OFF. Link the distro's libsqlite3 (fast builds, distro owns
    //     CVE patches). CI installs libsqlite3-dev for this.
    //   * macOS  → ON. Apple's system libsqlite3 is built SQLITE_THREADSAFE=2
    //     (multi-thread), but store.zig shares one connection handle across the
    //     UI loop and the history worker — safe only under *serialized* mode. A
    //     default macOS build thus links a non-serialized SQLite, trips the
    //     assert in store.zig open(), and crashes on startup (ROD-212). The
    //     vendored amalgamation is compiled THREADSAFE=1 below, so bundling is
    //     the fix — and it frees macOS from whatever SQLite Apple ships next.
    //
    // Release artifacts force it on for every target (-Dbundle-sqlite) so a
    // static musl build is one self-contained file with no libsqlite3.so
    // dependency. See ROD-145 → "SQLite bundling in Zig".
    const bundle_sqlite = b.option(
        bool,
        "bundle-sqlite",
        "Compile the vendored SQLite amalgamation instead of linking system libsqlite3",
    ) orelse (target.result.os.tag == .macos);

    // Strip debug info — release artifacts only. See exe creation below.
    const strip = b.option(bool, "strip", "Strip debug info from the binary") orelse false;

    // Position-independent executable. Off by default (release artifacts are
    // static-musl, dev builds want a plain exe); the AUR source package passes
    // -Dpie for Arch's standard hardening (ROD-146).
    const pie = b.option(bool, "pie", "Build a position-independent executable") orelse false;

    const mod = b.addModule("zigoku", .{
        .root_source_file = b.path("src/root.zig"),
        // Needed because this module is also the root of a test executable.
        .target = target,
        // M2 persistence (src/store.zig) talks to libsqlite3 via raw C interop,
        // so the whole library module links libc. The exe and test executables
        // that include this module inherit the linkage.
        .link_libc = true,
    });
    mod.addIncludePath(b.path("src/c"));
    // STBI_MAX_DIMENSIONS is injected from src/decode_limits.zig so the stb and
    // libwebp decode-bomb backstops share one value (see cover.zig).
    mod.addCSourceFile(.{
        .file = b.path("src/c/stb_image_impl.c"),
        .flags = &.{b.fmt("-DSTBI_MAX_DIMENSIONS={d}", .{decode_limits.max_dimension})},
    });

    // libwebp decoder subset (ROD-244) — AllAnime's cover CDN serves WebP no
    // matter the file extension, which stb_image cannot decode. We vendor the
    // decode-only translation units in-tree (src/c/webp, refreshed by
    // scripts/vendor-libwebp.sh) and compile them straight into the module —
    // the same hermetic, assume-nothing stance as stb_image above.
    //
    // libwebp self-includes root-relative ("src/dec/vp8i_dec.h"), so the
    // include path points at the dir that contains that src/ tree. Threads stay
    // off: we never define WEBP_USE_THREAD, so thread_utils.c collapses to
    // synchronous stubs and no pthread linkage is pulled in (decode is
    // one-shot per cover — a worker thread would buy nothing). Each ISA .c
    // self-gates on its target macro, so the full set cross-compiles: x86_64
    // lights up SSE2, aarch64 NEON, everything else scalar.
    //
    // UBSan is left ON (no -fno-sanitize): libwebp is the network-fed image
    // decoder, and per packaging/aur/README.md we keep the sanitizer trap on
    // exactly this attacker-reachable surface — a controlled trap on malformed
    // input beats raw UB in a release binary. Verified: the full test suite and
    // an adversarial corpus decode with UBSan trapping enabled and hit zero
    // traps, so it costs us nothing on valid covers.
    mod.addIncludePath(b.path("src/c/webp"));
    mod.addCSourceFiles(.{
        .root = b.path("src/c/webp/src"),
        .files = &webp_decoder.files,
    });

    // store.zig's @cImport(@cInclude("sqlite3.h")) resolves identically either
    // way — system header vs amalgamation header — so app code never changes.
    if (bundle_sqlite) {
        // Lazy dependency: only downloaded when this branch runs, i.e. only for
        // release builds that pass -Dbundle-sqlite. Returns null on the first
        // configure pass until the fetch lands, then zig re-runs build().
        if (b.lazyDependency("sqlite", .{})) |sqlite_dep| {
            mod.addIncludePath(sqlite_dep.path("."));
            mod.addCSourceFile(.{
                .file = sqlite_dep.path("sqlite3.c"),
                // THREADSAFE=1: the worker pool hits the store off the UI thread.
                // OMIT_LOAD_EXTENSION: we never load extensions; drops attack surface.
                .flags = &.{
                    "-DSQLITE_THREADSAFE=1",
                    "-DSQLITE_OMIT_LOAD_EXTENSION",
                },
            });
        }
    } else {
        mod.linkSystemLibrary("sqlite3", .{});
    }

    // libvaxis (ROD-71) — the M3 TUI toolkit. v0.6.0 targets Zig 0.16's std.Io.
    // The whole zigoku module gets it so src/tui/* can @import("vaxis").
    const vaxis_dep = b.dependency("vaxis", .{ .target = target, .optimize = optimize });
    const vaxis_mod = vaxis_dep.module("vaxis");
    mod.addImport("vaxis", vaxis_mod);

    const exe = b.addExecutable(.{
        .name = "zigoku",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // Strip debug info from release artifacts (-Dstrip). Off by default so
            // local/CI builds keep symbols for backtraces; Zig strips at link time,
            // which works for cross-compiled targets a host `strip` couldn't touch.
            .strip = strip,
            .imports = &.{
                .{ .name = "zigoku", .module = mod },
            },
        }),
    });
    exe.pie = pie;
    b.installArtifact(exe);

    // ── Spikes ────────────────────────────────────────────────────────────────
    // Throwaway executables that prove a risky unknown. Not installed; run via
    // their named step, e.g. `zig build spike-http -- frieren`.
    const spike_http = b.addExecutable(.{
        .name = "spike-http",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spikes/http_search.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_spike_http = b.addRunArtifact(spike_http);
    if (b.args) |args| run_spike_http.addArgs(args);
    const spike_http_step = b.step("spike-http", "ROD-55: AniList HTTP search spike");
    spike_http_step.dependOn(&run_spike_http.step);

    // spike-enrich: batched AniList enrichment per feed page (ROD-247 decision gate).
    const spike_enrich = b.addExecutable(.{
        .name = "spike-enrich",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spikes/discover_enrich.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_spike_enrich = b.addRunArtifact(spike_enrich);
    if (b.args) |args| run_spike_enrich.addArgs(args);
    const spike_enrich_step = b.step("spike-enrich", "ROD-247: batched AniList enrichment spike");
    spike_enrich_step.dependOn(&run_spike_enrich.step);

    // spike-sqlite: SQLite via raw C interop (ROD-56). Links libc + system sqlite3.
    const spike_sqlite_mod = b.createModule(.{
        .root_source_file = b.path("src/spikes/sqlite_store.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    spike_sqlite_mod.linkSystemLibrary("sqlite3", .{});
    const spike_sqlite = b.addExecutable(.{
        .name = "spike-sqlite",
        .root_module = spike_sqlite_mod,
    });
    const run_spike_sqlite = b.addRunArtifact(spike_sqlite);
    const spike_sqlite_step = b.step("spike-sqlite", "ROD-56: SQLite C-interop spike");
    spike_sqlite_step.dependOn(&run_spike_sqlite.step);

    // spike-concurrency: thread pool + channel (ROD-58).
    const spike_conc = b.addExecutable(.{
        .name = "spike-concurrency",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spikes/concurrency.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_spike_conc = b.addRunArtifact(spike_conc);
    const spike_conc_step = b.step("spike-concurrency", "ROD-58: threads + channel spike");
    spike_conc_step.dependOn(&run_spike_conc.step);

    // spike-stream: resolve a playable AllAnime stream via POST + AES-GCM (ROD-62).
    const spike_stream = b.addExecutable(.{
        .name = "spike-stream",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spikes/allanime_stream.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_spike_stream = b.addRunArtifact(spike_stream);
    if (b.args) |args| run_spike_stream.addArgs(args);
    const spike_stream_step = b.step("spike-stream", "ROD-62: AllAnime stream resolver spike");
    spike_stream_step.dependOn(&run_spike_stream.step);

    // spike-mpv: full pipeline → play in mpv (ROD-57). Args after the query
    // pass through to mpv (e.g. `-- frieren --frames=1 --vo=null` for a probe).
    const spike_mpv = b.addExecutable(.{
        .name = "spike-mpv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spikes/mpv_play.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_spike_mpv = b.addRunArtifact(spike_mpv);
    if (b.args) |args| run_spike_mpv.addArgs(args);
    const spike_mpv_step = b.step("spike-mpv", "ROD-57: full pipeline → play in mpv");
    spike_mpv_step.dependOn(&run_spike_mpv.step);

    // spike-tui: prove libvaxis boots under Zig 0.16 (ROD-71). Renders a
    // Terminal Ghost frame + event loop in a real terminal.
    const spike_tui = b.addExecutable(.{
        .name = "spike-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/spikes/tui_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis_mod },
            },
        }),
    });
    const run_spike_tui = b.addRunArtifact(spike_tui);
    if (b.args) |args| run_spike_tui.addArgs(args);
    const spike_tui_step = b.step("spike-tui", "ROD-71: libvaxis boot spike");
    spike_tui_step.dependOn(&run_spike_tui.step);

    // `zig build run [-- args]` — run from the install dir, not the cache.
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);

    // `zig build test` — test executables cover one module each, so the library
    // module and the exe's root module need separate test runs (they parallelize).
    const run_mod_tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
    const run_exe_tests = b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module }));
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

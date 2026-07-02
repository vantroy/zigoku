const std = @import("std");

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
    mod.addCSourceFile(.{ .file = b.path("src/c/stb_image_impl.c") });

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
    // lights up SSE2, aarch64 NEON, everything else scalar. -fno-sanitize=
    // undefined: this is pinned, audited third-party C; we don't want Zig's
    // UBSan trapping inside libwebp's deliberate integer arithmetic.
    mod.addIncludePath(b.path("src/c/webp"));
    mod.addCSourceFiles(.{
        .root = b.path("src/c/webp/src"),
        .files = &webp_decoder_srcs,
        .flags = &.{"-fno-sanitize=undefined"},
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

// libwebp decoder translation units, relative to src/c/webp/src. This mirrors
// LIBWEBPDECODER_OBJS (DEC + DSP_DEC + UTILS_DEC) from upstream's makefile.unix;
// scripts/vendor-libwebp.sh copies exactly this set. Keep the two in sync when
// bumping libwebp — a stale entry here is a link error, a missing one a decode
// gap. Generated once from the vendored tree; not hand-typed.
const webp_decoder_srcs = [_][]const u8{
    "dec/alpha_dec.c",
    "dec/buffer_dec.c",
    "dec/frame_dec.c",
    "dec/idec_dec.c",
    "dec/io_dec.c",
    "dec/quant_dec.c",
    "dec/tree_dec.c",
    "dec/vp8_dec.c",
    "dec/vp8l_dec.c",
    "dec/webp_dec.c",
    "dsp/alpha_processing.c",
    "dsp/alpha_processing_mips_dsp_r2.c",
    "dsp/alpha_processing_neon.c",
    "dsp/alpha_processing_sse2.c",
    "dsp/alpha_processing_sse41.c",
    "dsp/cpu.c",
    "dsp/dec.c",
    "dsp/dec_clip_tables.c",
    "dsp/dec_mips32.c",
    "dsp/dec_mips_dsp_r2.c",
    "dsp/dec_msa.c",
    "dsp/dec_neon.c",
    "dsp/dec_sse2.c",
    "dsp/dec_sse41.c",
    "dsp/filters.c",
    "dsp/filters_mips_dsp_r2.c",
    "dsp/filters_msa.c",
    "dsp/filters_neon.c",
    "dsp/filters_sse2.c",
    "dsp/lossless.c",
    "dsp/lossless_mips_dsp_r2.c",
    "dsp/lossless_msa.c",
    "dsp/lossless_neon.c",
    "dsp/lossless_sse2.c",
    "dsp/lossless_sse41.c",
    "dsp/rescaler.c",
    "dsp/rescaler_mips32.c",
    "dsp/rescaler_mips_dsp_r2.c",
    "dsp/rescaler_msa.c",
    "dsp/rescaler_neon.c",
    "dsp/rescaler_sse2.c",
    "dsp/upsampling.c",
    "dsp/upsampling_mips_dsp_r2.c",
    "dsp/upsampling_msa.c",
    "dsp/upsampling_neon.c",
    "dsp/upsampling_sse2.c",
    "dsp/upsampling_sse41.c",
    "dsp/yuv.c",
    "dsp/yuv_mips32.c",
    "dsp/yuv_mips_dsp_r2.c",
    "dsp/yuv_neon.c",
    "dsp/yuv_sse2.c",
    "dsp/yuv_sse41.c",
    "utils/bit_reader_utils.c",
    "utils/color_cache_utils.c",
    "utils/filters_utils.c",
    "utils/huffman_utils.c",
    "utils/palette.c",
    "utils/quant_levels_dec_utils.c",
    "utils/random_utils.c",
    "utils/rescaler_utils.c",
    "utils/thread_utils.c",
    "utils/utils.c",
};

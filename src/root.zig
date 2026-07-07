//! Zigoku — library root.
//!
//! Everything the app does lives behind this module: `main.zig` imports it as
//! `@import("zigoku")`. As of M1 the vertical slice is real — domain types, the
//! `SourceProvider` seam, the AllAnime provider behind it, and the mpv launcher
//! all hang off here. M2 adds the SQLite `Store` (history/resume/cache); the TUI
//! joins them in M3.

const std = @import("std");

// ── Public API ────────────────────────────────────────────────────────────────
pub const domain = @import("domain.zig");
pub const source = @import("source.zig");
pub const player = @import("player.zig");
pub const store = @import("store.zig");
pub const anilist = @import("anilist.zig");
pub const jikan = @import("providers/jikan.zig");
pub const aniskip = @import("aniskip.zig");
pub const config = @import("config.zig");
pub const auth = @import("auth.zig");
pub const login = @import("login.zig");
pub const login_loopback = @import("login_loopback.zig");
pub const sync = @import("sync.zig");
pub const provider_migrate = @import("provider_migrate.zig");
pub const paths = @import("paths.zig");
pub const log = @import("log.zig");
// NB: the log handler is installed via `std_options` in `main.zig` (the exe's
// compilation root). Declaring it here would be dead — when std resolves
// `@import("root")` this file is never the root (the exe roots at main.zig, the
// test binary at the test runner).
pub const Config = config.Config;
const tui_app = @import("tui/app.zig");

/// The TUI shell (M3, libvaxis). `zigoku` with no query opens it.
pub const tui = struct {
    pub const run = tui_app.run;
};

/// Persistence (M2): watch history, episode resume positions, episode-list cache.
pub const Store = store.Store;
pub const AnimeRecord = store.AnimeRecord;

/// The provider seam and its first implementation.
pub const SourceProvider = source.SourceProvider;
pub const SearchOptions = source.SearchOptions;
pub const AllAnime = @import("providers/allanime.zig").AllAnime;
pub const Senshi = @import("providers/senshi.zig").Senshi;

// Re-export the domain vocabulary at the top level for ergonomic call sites.
pub const Anime = domain.Anime;
pub const EpisodeNumber = domain.EpisodeNumber;
pub const StreamLink = domain.StreamLink;
pub const Translation = domain.Translation;
pub const Quality = domain.Quality;

/// Zigoku version. Keep in sync with `build.zig.zon`.
pub const version = "0.2.3";

const banner =
    \\  ╋ zigoku · 地獄
    \\    terminal anime, served in hell
    \\
;

/// Write the startup banner + version to any writer.
pub fn writeBanner(w: *std.Io.Writer) !void {
    try w.writeAll(banner);
    try w.print("    v{s}\n", .{version});
}

/// Write a clean, single-line version string for `--version` (ROD-221). Kept
/// separate from the banner so the version contract the distribution checks
/// (Homebrew formula test, release smoke step) lean on is its own line, not a
/// side effect of the usage/banner fallthrough.
pub fn writeVersion(w: *std.Io.Writer) !void {
    try w.print("zigoku v{s}\n", .{version});
}

test "writeVersion prints a clean line carrying the version" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try writeVersion(&aw.writer);
    const out = aw.writer.buffered();
    try std.testing.expectEqualStrings("zigoku v" ++ version ++ "\n", out);
}

test "version matches build.zig.zon" {
    // Pin the literal so a bump here without the matching `.version` edit in
    // build.zig.zon (or vice versa) trips CI — the "keep in sync" comment above
    // otherwise has no teeth.
    try std.testing.expectEqualStrings("0.2.3", version);
}

// Pull in the unit tests from every module so `zig build test` covers them all.
test {
    std.testing.refAllDecls(@This());
    _ = domain;
    _ = source;
    _ = player;
    _ = store;
    _ = anilist;
    _ = jikan;
    _ = aniskip;
    _ = config;
    _ = auth;
    _ = login;
    _ = login_loopback;
    _ = sync;
    _ = provider_migrate;
    _ = paths;
    _ = log;
    _ = tui;
    _ = @import("tui/app_test.zig");
    _ = @import("tui/discover_state.zig"); // ROD-268: pull the slot-hydrate test
    _ = @import("tui/discover_covers.zig");
    _ = @import("tui/view/discover.zig");
    _ = @import("tui/view/browse.zig"); // ROD-205: browse isn't pulled via app_test, wire it explicitly
    _ = @import("tui/render.zig"); // ROD-285: run progressFill (+ pre-existing render) tests

    _ = @import("providers/allanime.zig");
    _ = @import("providers/senshi.zig"); // ROD-301: run the senshi provider tests
    _ = @import("util/deadline.zig"); // ROD-262: run the lifted withDeadline tests
}

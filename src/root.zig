//! Zigoku — library root.
//!
//! Everything the app does lives behind this module: `main.zig` imports it as
//! `@import("zigoku")`. As of M1 the vertical slice is real — domain types, the
//! `SourceProvider` seam, the AllAnime provider behind it, and the mpv launcher
//! all hang off here. The SQLite store and the TUI join them in M2/M3.

const std = @import("std");

// ── Public API ────────────────────────────────────────────────────────────────
pub const domain = @import("domain.zig");
pub const source = @import("source.zig");
pub const player = @import("player.zig");

/// The provider seam and its first implementation.
pub const SourceProvider = source.SourceProvider;
pub const SearchOptions = source.SearchOptions;
pub const AllAnime = @import("providers/allanime.zig").AllAnime;

// Re-export the domain vocabulary at the top level for ergonomic call sites.
pub const Anime = domain.Anime;
pub const EpisodeNumber = domain.EpisodeNumber;
pub const StreamLink = domain.StreamLink;
pub const Translation = domain.Translation;

/// Zigoku version. Keep in sync with `build.zig.zon`.
pub const version = "0.0.0";

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

test "version is set" {
    try std.testing.expect(version.len > 0);
}

// Pull in the unit tests from every module so `zig build test` covers them all.
test {
    std.testing.refAllDecls(@This());
    _ = domain;
    _ = source;
    _ = player;
    _ = @import("providers/allanime.zig");
}

//! Zigoku — library root.
//!
//! Everything the app does lives behind this module: the `main.zig` CLI shell
//! imports it as `@import("zigoku")`. Domain types, the source provider, the
//! SQLite store, and the TUI will all hang off here as we build out the phases.

const std = @import("std");

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

//! Zigoku — mpv launcher (ROD-63).
//!
//! Blocking and dumb on purpose: spawn mpv on a resolved stream, wait for it to
//! exit. No IPC, no resume tracking — that's M5 (the unix-socket control channel).
//! Today the job is just "the bytes play in a window."

const std = @import("std");
const Io = std.Io;
const domain = @import("domain.zig");

pub const PlayError = error{
    /// mpv isn't installed / not on PATH — overwhelmingly the likely failure.
    MpvNotFound,
    /// mpv ran but exited non-zero or was killed by a signal.
    MpvFailed,
};

/// Launch mpv on `link` and block until it exits.
///
/// `title` becomes mpv's window/OSD title. `start_seconds` is the resume offset
/// (pass 0 until persistence lands — the seam is here so M2/M5 just fill it in).
pub fn play(
    arena: std.mem.Allocator,
    io: Io,
    link: domain.StreamLink,
    title: []const u8,
    start_seconds: u64,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, "mpv");
    try argv.append(arena, link.url);
    if (link.referer) |r| {
        // Safe today: referer is a hardcoded constant. When ROD-92 lands and
        // providers supply their own referer from API data, validate it (no
        // CR/LF, no header injection) before embedding it in this arg.
        try argv.append(arena, try std.fmt.allocPrint(arena, "--http-header-fields-append=Referer: {s}", .{r}));
    }
    try argv.append(arena, try std.fmt.allocPrint(arena, "--force-media-title={s}", .{title}));
    if (start_seconds > 0) {
        try argv.append(arena, try std.fmt.allocPrint(arena, "--start={d}", .{start_seconds}));
    }

    var child = std.process.spawn(io, .{ .argv = argv.items }) catch |err| switch (err) {
        error.FileNotFound => return error.MpvNotFound,
        else => return err,
    };

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.MpvFailed,
        else => return error.MpvFailed, // signalled / stopped / unknown
    }
}

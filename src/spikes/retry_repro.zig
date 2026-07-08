//! ROD-310 repro — drive the ROD-309 pre-playback retry loop against a fake mpv
//! that always exits 2 ("nothing could be opened/played"), to find out whether the
//! retry path panics on Linux the way it did for a macOS user (paraphrased
//! "unreachable code reached, could not generate stack trace").
//!
//! Faithfully replicates workers.playTask's retry loop: the REAL player.play(), a
//! fresh StreamLink per attempt (mirroring the senshi re-resolve), a live position
//! callback (so the IPC watcher thread spawns + joins each attempt like the app),
//! and the real 2s/4s nanosleep backoff between tries.
//!
//!   zig build spike-retry -- /abs/path/to/fake-mpv
//!
//! Clean exit "repro finished without panic" ⇒ the retry loop is NOT the crash on
//! Linux (points at a darwin-specific std path). A panic here ⇒ reproduced, debug it.

const std = @import("std");
const zigoku = @import("zigoku");
const domain = zigoku.domain;
const player = zigoku.player;

// Mirrors the constants + gate in src/tui/workers.zig so the loop below is the
// same shape as playTask's, minus the vaxis Loop (we print instead of postEvent).
const MAX_PLAY_ATTEMPTS: usize = 3;
const RETRY_BACKOFFS_MS = [_]u64{ 2000, 4000 };

fn playAttemptRetryable(cause: anyerror, attempt: usize, played: bool) bool {
    return cause == error.MpvOpenFailed and !played and attempt + 1 < MAX_PLAY_ATTEMPTS;
}

fn msToTimespec(ms: u64) std.c.timespec {
    return .{
        .sec = @intCast(ms / std.time.ms_per_s),
        .nsec = @intCast((ms % std.time.ms_per_s) * std.time.ns_per_ms),
    };
}
fn nanosleepMs(ms: u64) void {
    var req = msToTimespec(ms);
    _ = std.c.nanosleep(&req, null);
}

var cb_hits: usize = 0;
fn onPosition(ctx: *anyopaque, update: player.PositionUpdate) void {
    _ = ctx;
    _ = update;
    cb_hits += 1;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const mpv_path = if (args.len > 1) args[1] else "mpv";

    var out_buf: [4096]u8 = undefined;
    var out_fw: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_fw.interface;

    try out.print("ROD-310 repro: retry loop vs fake mpv = {s}\n", .{mpv_path});
    try out.flush();

    var dummy: usize = 0;
    var final_cause: ?anyerror = null;
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        // Stub re-resolve: a fresh StreamLink each attempt, same shape senshi hands
        // back (referer + browser UA + cloaked segments). The URL is never fetched —
        // the fake mpv exits 2 before opening anything.
        const link: domain.StreamLink = .{
            .url = "https://ninstream.example/WP7CeGRQ/playlist.m3u8",
            .referer = "https://example.com",
            .user_agent = "Mozilla/5.0 (repro) AppleWebKit/537.36",
            .cloaked_segments = true,
        };

        try out.print("  attempt {d}/{d}: launching fake mpv…\n", .{ attempt + 1, MAX_PLAY_ATTEMPTS });
        try out.flush();

        player.play(arena, io, mpv_path, link, "Repro Show", 0, .{
            .ctx = @ptrCast(&dummy),
            .func = onPosition,
        }, null) catch |e| {
            // The fake mpv never plays, so nothing was observed — the exact gate
            // condition (unplayed open-failure) that makes the retry fire.
            const played = false;
            try out.print("  attempt {d} failed: {s}\n", .{ attempt + 1, @errorName(e) });
            try out.flush();
            if (playAttemptRetryable(e, attempt, played)) {
                try out.print("  → retryable; backing off {d}ms then re-resolving\n", .{RETRY_BACKOFFS_MS[attempt]});
                try out.flush();
                nanosleepMs(RETRY_BACKOFFS_MS[attempt]);
                continue;
            }
            try out.print("  → budget exhausted (cause={s}); giving up\n", .{@errorName(e)});
            try out.flush();
            final_cause = e;
            break;
        };

        try out.print("  attempt {d}: play returned OK (unexpected for a code-2 fake)\n", .{attempt + 1});
        try out.flush();
        break;
    }

    // Guard's teeth: a *regression* here surfaces as a panic during play(), which
    // aborts and reds CI. But every non-panic outcome would otherwise exit 0 —
    // including the useless one where the fake mpv never LAUNCHED (a runner image
    // dropping python3, a bad path): play() would fail MpvNotFound/InvalidExe, the
    // loop would give up after one attempt, and we'd green while testing nothing,
    // silently disabling the guard. Assert the expected shape so that degrades to a
    // red instead: the fake must have driven every attempt to MpvOpenFailed.
    const drove_the_watcher_path = if (final_cause) |c| c == error.MpvOpenFailed else false;
    if (!drove_the_watcher_path or attempt + 1 != MAX_PLAY_ATTEMPTS) {
        const name = if (final_cause) |c| @errorName(c) else "none (play returned OK)";
        try out.print("REGRESSION GUARD INVALID: expected {d} attempts all failing MpvOpenFailed, got attempts={d} cause={s} — the fake mpv likely never launched, so this run tested NOTHING.\n", .{ MAX_PLAY_ATTEMPTS, attempt + 1, name });
        try out.flush();
        std.process.exit(1);
    }

    try out.print("repro finished without panic. attempts={d} watcher_cb_hits={d}\n", .{ attempt + 1, cb_hits });
    try out.flush();
}

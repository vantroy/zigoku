//! Zigoku — AniList OAuth login via a loopback listener (ROD-283, 2b).
//!
//! `zigoku login` (without `--paste`) drives this: mint a CSRF `state` nonce, open
//! the browser at the authorize URL, and run a one-shot HTTP listener on
//! 127.0.0.1:`login.PORT` (the app's registered redirect). The Implicit Grant
//! returns the token in the URL *fragment* — never sent to a server — so the first
//! hit gets an HTML+JS relay page that re-issues `location.hash` as
//! `/callback?<query>`; the listener then verifies `state`, hands the query to
//! `login.completeLogin` (the shared extract → verify → persist core), and renders
//! the outcome to the browser tab and the terminal.
//!
//! No *overall* timeout by design: it waits across connections for the browser to
//! return (or the user Ctrl-Cs, or re-runs with `--paste`). Each individual
//! connection *does* get a read deadline, so one silent/stalled socket can't wedge
//! the serial accept loop. If the port can't be bound or the nonce can't be minted,
//! it returns `error.LoopbackUnavailable` so the caller falls back to paste.
//!
//! Threat note: `state` defends against a *guessed* forged callback — it does NOT
//! hide the nonce from other local code. The URL (carrying `&state=`) rides in the
//! browser's argv when we shell out to open it, so it's visible in `ps` to
//! co-resident processes for the browser's lifetime — the known residual for a
//! native app handing a system browser an OAuth URL (RFC 8252). Bounded to local
//! attackers and to the seconds the listener is open; a non-issue on a single-user
//! machine. Bind is IPv4 127.0.0.1 only; a host that maps `localhost` solely to
//! `::1` can't reach it (rare — Happy Eyeballs falls back to IPv4).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const net = std.Io.net;
const http = std.http;
const auth = @import("auth.zig");
const login = @import("login.zig");
const deadline = @import("util/deadline.zig");
const c = @cImport({
    @cInclude("time.h"); // time(2) — matches store.zig / login.zig
});

const PORT = login.PORT; // single source of truth; login.REDIRECT is derived from it

/// Per-connection read deadline. A real localhost redirect completes in
/// milliseconds; this only bites a silent/stalled socket, so one hostile or dead
/// connection is dropped after a few seconds instead of wedging the accept loop.
const HEAD_DEADLINE = Io.Duration.fromSeconds(5);

/// Errors that mean "the loopback path can't run, use paste instead".
pub const Error = error{LoopbackUnavailable};

const html_header = [_]http.Header{.{ .name = "content-type", .value = "text/html; charset=utf-8" }};

/// Served on the browser's first landing: the token is in `location.hash`, which
/// never reaches the server, so JS re-issues it as a query string to `/callback`.
const relay_page =
    \\<!doctype html><meta charset="utf-8"><title>Zigoku sign-in</title>
    \\<body style="font:16px system-ui;padding:2rem">
    \\<p>Finishing sign-in… you can close this tab in a moment.</p>
    \\<script>location.replace("/callback?" + location.hash.substring(1));</script>
    \\</body>
;

const done_page =
    \\<!doctype html><meta charset="utf-8"><title>Zigoku</title>
    \\<body style="font:16px system-ui;padding:2rem">
    \\<h2>✓ Signed in to AniList</h2><p>You can close this tab and return to your terminal.</p></body>
;

const fail_page =
    \\<!doctype html><meta charset="utf-8"><title>Zigoku sign-in</title>
    \\<body style="font:16px system-ui;padding:2rem">
    \\<h2>Sign-in didn't complete</h2><p>Check your terminal for details.</p></body>
;

/// Where a request routes, decided purely from the target and the expected nonce.
/// Pulled out so the CSRF gate is unit-testable: a missing or forged `state` can
/// never resolve to `.complete`, and thus never reaches verify/persist.
const Route = enum { relay, bad_state, complete };

fn classify(target: []const u8, state: []const u8) Route {
    if (!std.mem.startsWith(u8, target, "/callback")) return .relay;
    const query = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[i + 1 ..] else "";
    if (!std.mem.eql(u8, queryParam(query, "state") orelse "", state)) return .bad_state;
    return .complete;
}

pub fn run(arena: Allocator, io: Io, out: *Io.Writer) !void {
    // CSRF nonce first — no real randomness ⇒ decline the listener rather than open
    // one with a guessable/empty state.
    var state: [32]u8 = undefined;
    mintState(io, &state) catch return error.LoopbackUnavailable;

    // Bind before opening a browser, so a busy port fails fast to the paste flow.
    var addr: net.IpAddress = .{ .ip4 = .loopback(PORT) };
    var server = addr.listen(io, .{ .reuse_address = true }) catch return error.LoopbackUnavailable;
    defer server.deinit(io);

    const path = try auth.defaultPath(arena);
    const existing = auth.load(arena, io, path);
    if (existing.hasAniList()) {
        try out.print("Already signed in as {s} — re-running replaces it.\n\n", .{existing.anilist.user_name});
    }

    const url = try std.fmt.allocPrint(arena, "{s}&state={s}", .{ login.AUTHORIZE, state });
    try out.print(
        \\Opening your browser to approve AniList access…
        \\  If it doesn't open, visit this URL yourself:
        \\  {s}
        \\
        \\Waiting for the redirect on {s}/ …
        \\  (Ctrl-C to cancel, or re-run `zigoku login --paste` for manual entry.)
        \\
    , .{ url, login.REDIRECT });
    try out.flush();
    openBrowser(io, url);

    var bad_state_warned = false;
    while (true) {
        var stream = server.accept(io) catch |err| {
            try out.print("\n  accept failed ({s}) — try `zigoku login --paste`.\n", .{@errorName(err)});
            try out.flush();
            return error.LoopbackUnavailable;
        };
        defer stream.close(io);

        var recv_buf: [8192]u8 = undefined;
        var send_buf: [8192]u8 = undefined;
        var conn_reader = stream.reader(io, &recv_buf);
        var conn_writer = stream.writer(io, &send_buf);
        var server_conn: http.Server = .init(&conn_reader.interface, &conn_writer.interface);

        // Bounded read: a silent/stalled socket returns error.Timeout and is dropped,
        // so it can't wedge the serial accept loop (slowloris). The op runs on a
        // separate unit of concurrency and is joined before this frame moves on, so
        // the stack pointers it borrows stay valid.
        var request = deadline.withDeadline(io, HEAD_DEADLINE, http.Server.receiveHead, .{&server_conn}) catch continue;

        switch (classify(request.head.target, &state)) {
            .relay => request.respond(relay_page, .{ .keep_alive = false, .extra_headers = &html_header }) catch {},
            .bad_state => {
                if (!bad_state_warned) {
                    try out.writeAll("  ⚠ ignoring callback(s) with a bad state (stray or forged requests).\n");
                    try out.flush();
                    bad_state_warned = true; // warn once — don't let a flood spam the terminal.
                }
                request.respond(fail_page, .{ .keep_alive = false, .extra_headers = &html_header }) catch {};
            },
            .complete => {
                const target = request.head.target;
                const query = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[i + 1 ..] else "";
                // Own the query: `completeLogin` persists a slice of it, so it must
                // outlive this connection's `recv_buf` (the paste path dupes too).
                const raw = arena.dupe(u8, query) catch query;
                const now: i64 = @intCast(c.time(null));
                switch (login.completeLogin(arena, io, raw, path, now)) {
                    .ok => |rec| {
                        request.respond(done_page, .{ .keep_alive = false, .extra_headers = &html_header }) catch {};
                        try out.print("  ✓ signed in as {s} (id {d}). Saved to {s}.\n", .{ rec.anilist.user_name, rec.anilist.user_id, path });
                    },
                    .no_token => {
                        request.respond(fail_page, .{ .keep_alive = false, .extra_headers = &html_header }) catch {};
                        try out.writeAll("  ✗ the redirect carried no access_token.\n");
                    },
                    .rejected => {
                        request.respond(fail_page, .{ .keep_alive = false, .extra_headers = &html_header }) catch {};
                        try out.writeAll("  ✗ AniList rejected the token (invalid or expired). Re-run to retry.\n");
                    },
                    .verify_failed => |err| {
                        request.respond(fail_page, .{ .keep_alive = false, .extra_headers = &html_header }) catch {};
                        try out.print("  ✗ couldn't reach AniList to verify ({s}) — re-run shortly.\n", .{@errorName(err)});
                    },
                    .save_failed => |err| {
                        request.respond(fail_page, .{ .keep_alive = false, .extra_headers = &html_header }) catch {};
                        try out.print("  ✗ verified, but couldn't write {s}: {s}\n", .{ path, @errorName(err) });
                    },
                }
                try out.flush();
                return; // one state-valid callback ends the flow, success or not.
            },
        }
    }
}

/// Fill `out` with 32 lowercase-hex chars of kernel randomness (16 bytes). Errors
/// if `/dev/urandom` can't be read — the caller then declines the loopback path.
/// (This Zig routes the CSPRNG behind the io interface; the raw device is the
/// simplest portable source here.)
fn mintState(io: Io, out: *[32]u8) !void {
    var raw: [16]u8 = undefined;
    var file = try std.Io.Dir.openFileAbsolute(io, "/dev/urandom", .{});
    defer file.close(io);
    var rbuf: [64]u8 = undefined;
    var reader = file.reader(io, &rbuf);
    try reader.interface.readSliceAll(&raw);
    hexEncode(&raw, out);
}

/// 16 bytes → 32 lowercase-hex chars. Split out so it's testable without a file.
fn hexEncode(raw: *const [16]u8, out: *[32]u8) void {
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
}

/// Best-effort browser launch. Fire-and-forget: the URL is already printed, so a
/// missing opener (or a headless/SSH box) just means the user opens it by hand.
fn openBrowser(io: Io, url: []const u8) void {
    const opener = if (builtin.os.tag == .macos) "open" else "xdg-open";
    _ = std.process.spawn(io, .{
        .argv = &.{ opener, url },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {};
}

/// Read `key`'s value out of a `k=v&k=v` query string, or null if absent.
/// (No percent-decoding — a JWT and a hex nonce are already URL-safe.)
fn queryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "classify routes relay/bad_state/complete and never lets a forged state through" {
    const nonce = "abc123";
    try testing.expectEqual(Route.relay, classify("/", nonce));
    try testing.expectEqual(Route.relay, classify("/favicon.ico", nonce));
    // Forged, absent, and query-less states must all be refused, never `.complete`.
    try testing.expectEqual(Route.bad_state, classify("/callback?access_token=eyJx&state=WRONG", nonce));
    try testing.expectEqual(Route.bad_state, classify("/callback?access_token=eyJx", nonce));
    try testing.expectEqual(Route.bad_state, classify("/callback", nonce));
    // Only an exact nonce match completes.
    try testing.expectEqual(Route.complete, classify("/callback?access_token=eyJx&state=abc123", nonce));
}

test "queryParam finds a value, ignores partial-key matches, null when absent" {
    const q = "access_token=eyJabc.def.ghi&token_type=Bearer&state=nonce123";
    try testing.expectEqualStrings("eyJabc.def.ghi", queryParam(q, "access_token").?);
    try testing.expectEqualStrings("nonce123", queryParam(q, "state").?);
    try testing.expectEqualStrings("Bearer", queryParam(q, "token_type").?);
    try testing.expect(queryParam(q, "token") == null); // not a prefix match for token_type
    try testing.expect(queryParam(q, "code") == null);
    try testing.expect(queryParam("", "state") == null);
}

test "hexEncode maps bytes to lowercase hex" {
    var out: [32]u8 = undefined;
    hexEncode(&[_]u8{ 0x00, 0x0f, 0xa5, 0xff } ++ [_]u8{0} ** 12, &out);
    try testing.expectEqualStrings("000fa5ff", out[0..8]);
}

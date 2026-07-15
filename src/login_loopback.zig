//! AniList OAuth login via loopback listener (ROD-283, 2b).
//!
//! `zigoku login` (no `--paste`): mint CSRF `state`, open authorize URL, one-shot
//! HTTP on 127.0.0.1:`login.PORT`. Implicit Grant puts the token in the URL fragment
//! (never sent to a server); first hit gets an HTML+JS relay that re-issues
//! `location.hash` as `/callback?<query>`. Listener verifies `state`, then
//! `login.completeLogin` (extract/verify/persist).
//!
//! No overall timeout: waits across connections for the browser (or Ctrl-C / --paste).
//! Per-connection read deadline so one stalled socket cannot wedge accept. Bind/nonce
//! failure → `error.LoopbackUnavailable` (caller falls back to paste).
//!
//! ROD-286 (TUI): accept core is `serveConn`; async path is `begin` → `awaitConnect` →
//! `requestCancel`. `begin` binds on the UI thread (bind failure is a toast, not a
//! half-open modal). Cancel wakes a blocked accept by dialing the port once after
//! setting the flag (documented self-connect).
//!
//! Threat: `state` blocks a guessed forged callback; it does not hide the nonce from
//! local code. The authorize URL (with `&state=`) is in the browser's argv (`ps`) for
//! the browser's lifetime (RFC 8252 residual). Bind is IPv4 127.0.0.1 only; pure-::1
//! localhost hosts cannot reach it (rare; Happy Eyeballs falls back to IPv4).

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
    @cInclude("time.h"); // time(2); matches store.zig / login.zig
});

const PORT = login.PORT; // single source of truth; login.REDIRECT is derived from it

/// Per-connection read deadline. Localhost redirect is milliseconds; this only drops
/// a stalled socket so it cannot wedge the serial accept loop.
const HEAD_DEADLINE = Io.Duration.fromSeconds(5);

/// Errors that mean "loopback can't run; use paste instead".
pub const Error = error{LoopbackUnavailable};

const html_header = [_]http.Header{.{ .name = "content-type", .value = "text/html; charset=utf-8" }};

/// Shared CSS for the three callback pages (tokens echo tui/colors.zig). No external
/// assets: must serve as-is off a bare loopback listener.
const page_style =
    \\<style>
    \\:root{--bg:#f4f7f5;--card:#ffffff;--border:#dde5e0;--fg:#10231a;--muted:#5b6b62;--accent:#1f7a3e;--fail:#c81f5c}
    \\@media(prefers-color-scheme:dark){:root{--bg:#020d06;--card:#0b1f18;--border:#1a4030;--fg:#39ff6a;--muted:#2a6040;--accent:#39ff6a;--fail:#ff2d78}}
    \\*{box-sizing:border-box}
    \\html,body{height:100%;margin:0}
    \\body{display:flex;align-items:center;justify-content:center;background:var(--bg);color:var(--fg);font-family:ui-monospace,SFMono-Regular,"Cascadia Code","Fira Code",Consolas,monospace;padding:1.5rem}
    \\.card{max-width:30rem;width:100%;text-align:center;padding:2rem 1.75rem;background:var(--card);border:1px solid var(--border);border-radius:.5rem}
    \\.brand{margin:0 0 1.25rem;color:var(--muted);letter-spacing:.08em;font-size:.8rem}
    \\h1{margin:0;font-size:1.15rem;font-weight:600;line-height:1.4}
    \\.ok{color:var(--accent)}
    \\.fail{color:var(--fail)}
    \\.cursor{display:inline-block;color:var(--accent);animation:blink 1s steps(1,end) infinite}
    \\@keyframes blink{50%{opacity:0}}
    \\p.sub{margin:.75rem 0 0;color:var(--muted);font-size:.85rem}
    \\</style>
;

/// First landing: token is in `location.hash` (never reaches the server); JS re-issues
/// it as a query to `/callback`. The redirect script is byte-critical: do not reformat
/// or rewrap it. done_page/fail_page scrub the query-string landing that follows.
const relay_page =
    \\<!doctype html><html lang="en"><head><meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width,initial-scale=1">
    \\<meta name="color-scheme" content="light dark">
    \\<title>Zigoku sign-in</title>
++ page_style ++
    \\</head><body><div class="card">
    \\<p class="brand">地獄 zigoku</p>
    \\<h1>finishing sign-in<span class="cursor">▌</span></h1>
    \\<p class="sub">don't close this tab yet…</p>
    \\</div>
    \\<script>location.replace("/callback?" + location.hash.substring(1));</script>
    \\</body></html>
;

/// Success page. Scrub script runs first so the token clears the address bar ASAP.
const done_page =
    \\<!doctype html><html lang="en"><head><meta charset="utf-8">
    \\<script>history.replaceState(null,'','/')</script>
    \\<meta name="viewport" content="width=device-width,initial-scale=1">
    \\<meta name="color-scheme" content="light dark">
    \\<title>Zigoku</title>
++ page_style ++
    \\</head><body><div class="card">
    \\<p class="brand">地獄 zigoku</p>
    \\<h1><span class="ok">✓</span> signed in to AniList</h1>
    \\<p class="sub">you can close this tab and return to your terminal.</p>
    \\</div>
    \\</body></html>
;

/// Failure page when `login.signedIn` is false (bad state, no token, verify/write fail).
/// Same early address-bar scrub as done_page.
const fail_page =
    \\<!doctype html><html lang="en"><head><meta charset="utf-8">
    \\<script>history.replaceState(null,'','/')</script>
    \\<meta name="viewport" content="width=device-width,initial-scale=1">
    \\<meta name="color-scheme" content="light dark">
    \\<title>Zigoku sign-in</title>
++ page_style ++
    \\</head><body><div class="card">
    \\<p class="brand">地獄 zigoku</p>
    \\<h1 class="fail">sign-in didn't complete</h1>
    \\<p class="sub">check your terminal for details.</p>
    \\</div>
    \\</body></html>
;

/// Route from target + expected nonce. CSRF gate unit-tested: forged/missing state
/// never resolves to `.complete` (never reaches verify/persist).
const Route = enum { relay, bad_state, complete };

fn classify(target: []const u8, state: []const u8) Route {
    if (!std.mem.startsWith(u8, target, "/callback")) return .relay;
    const query = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[i + 1 ..] else "";
    if (!std.mem.eql(u8, queryParam(query, "state") orelse "", state)) return .bad_state;
    return .complete;
}

/// True when a token was persisted (`login.signedIn`) so main can bootstrap sync
/// on a fresh sign-in (ROD-292). LoopbackUnavailable → paste flow.
pub fn run(arena: Allocator, io: Io, out: *Io.Writer) !bool {
    // No real randomness → decline listener rather than open with guessable state.
    var state: [32]u8 = undefined;
    mintState(io, &state) catch return error.LoopbackUnavailable;

    // Bind before browser so a busy port fails fast to paste.
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

        const now: i64 = @intCast(c.time(null));
        switch (serveConn(io, &stream, &state, arena, path, now)) {
            .keep => {},
            .bad_state => {
                if (!bad_state_warned) {
                    try out.writeAll("  ⚠ ignoring callback(s) with a bad state (stray or forged requests).\n");
                    try out.flush();
                    bad_state_warned = true; // warn once
                }
            },
            .complete => |result| {
                switch (result) {
                    .ok => |rec| try out.print("  ✓ signed in as {s} (id {d}). Saved to {s}.\n", .{ rec.anilist.user_name, rec.anilist.user_id, path }),
                    .no_token => try out.writeAll("  ✗ the redirect carried no access_token.\n"),
                    .rejected => try out.writeAll("  ✗ AniList rejected the token (invalid or expired). Re-run to retry.\n"),
                    .verify_failed => |err| try out.print("  ✗ couldn't reach AniList to verify ({s}) — re-run shortly.\n", .{@errorName(err)}),
                    .save_failed => |err| try out.print("  ✗ verified, but couldn't write {s}: {s}\n", .{ path, @errorName(err) }),
                }
                try out.flush();
                return login.signedIn(result); // one state-valid callback ends the flow
            },
        }
    }
}

/// Verdict of serving one accepted connection.
/// `keep`: relay or dropped socket (wait for next hit).
/// `bad_state`: forged/absent CSRF; fail page served.
/// `complete`: state-valid `/callback` ran completeLogin (any LoginResult arm ends the flow).
pub const Served = union(enum) {
    keep,
    bad_state,
    complete: login.LoginResult,
};

/// Serve one already-accepted connection: bounded receiveHead, CSRF classify, respond,
/// and only for state-valid callback run completeLogin. Shared by CLI `run` and
/// `awaitConnect`. No terminal/UI writes; caller renders the verdict.
pub fn serveConn(io: Io, stream: *net.Stream, state: []const u8, arena: Allocator, path: []const u8, now: i64) Served {
    var recv_buf: [8192]u8 = undefined;
    var send_buf: [8192]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buf);
    var conn_writer = stream.writer(io, &send_buf);
    var server_conn: http.Server = .init(&conn_reader.interface, &conn_writer.interface);

    // Bounded read: stalled socket → Timeout → `.keep` (slowloris).
    var request = deadline.withDeadline(io, HEAD_DEADLINE, http.Server.receiveHead, .{&server_conn}) catch return .keep;

    switch (classify(request.head.target, state)) {
        .relay => {
            request.respond(relay_page, .{ .keep_alive = false, .extra_headers = &html_header }) catch {};
            return .keep;
        },
        .bad_state => {
            request.respond(fail_page, .{ .keep_alive = false, .extra_headers = &html_header }) catch {};
            return .bad_state;
        },
        .complete => {
            const target = request.head.target;
            const query = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[i + 1 ..] else "";
            // Own the query: completeLogin may persist a slice of it past recv_buf.
            const raw = arena.dupe(u8, query) catch query;
            const result = login.completeLogin(arena, io, raw, path, now);
            const page = if (login.signedIn(result)) done_page else fail_page;
            request.respond(page, .{ .keep_alive = false, .extra_headers = &html_header }) catch {};
            return .{ .complete = result };
        },
    }
}

// ── Async (TUI) connect: begin → awaitConnect → requestCancel (ROD-286) ──────────

/// Worker→UI POD for a connect attempt. Ships by value. `.ok` carries nothing:
/// completeLogin already wrote auth.zon; UI reloads it. Failure arms mirror LoginResult;
/// `.canceled` is esc; `.accept_failed` is a hard listener error.
pub const ConnectOutcome = union(enum) {
    ok,
    no_token,
    rejected,
    verify_failed: anyerror,
    save_failed: anyerror,
    accept_failed: anyerror,
    canceled,
};

fn outcomeOf(result: login.LoginResult) ConnectOutcome {
    return switch (result) {
        .ok => .ok,
        .no_token => .no_token,
        .rejected => .rejected,
        .verify_failed => |e| .{ .verify_failed = e },
        .save_failed => |e| .{ .save_failed = e },
    };
}

/// Live loopback listener + UI strings. `server` borrowed by worker accept; owner
/// deinits only after joining the worker (never both at once). `url`/`path` arena-owned.
pub const Listener = struct {
    server: net.Server,
    state: [32]u8,
    url: []const u8,
    path: []const u8,
};

/// Bind + mint CSRF on the calling thread. LoopbackUnavailable on any setup failure
/// (UI toasts; no modal). Caller opens the browser with `listener.url` after return.
pub fn begin(arena: Allocator, io: Io) Error!Listener {
    var state: [32]u8 = undefined;
    mintState(io, &state) catch return error.LoopbackUnavailable;

    var addr: net.IpAddress = .{ .ip4 = .loopback(PORT) };
    var server = addr.listen(io, .{ .reuse_address = true }) catch return error.LoopbackUnavailable;
    // Close on later setup failure so a rare path/URL alloc fail does not leak the port.
    errdefer server.deinit(io);

    const path = auth.defaultPath(arena) catch return error.LoopbackUnavailable;
    const url = std.fmt.allocPrint(arena, "{s}&state={s}", .{ login.AUTHORIZE, state }) catch return error.LoopbackUnavailable;
    return .{ .server = server, .state = state, .url = url, .path = path };
}

/// Worker accept loop: state-valid callback → ConnectOutcome, or `.canceled` when
/// `cancel` is set. Re-check cancel after every accept (wake conn dropped unserved)
/// and at loop top. Hard accept error → `.accept_failed`. Arena must outlive the worker.
pub fn awaitConnect(listener: *Listener, arena: Allocator, io: Io, cancel: *std.atomic.Value(bool)) ConnectOutcome {
    while (true) {
        if (cancel.load(.acquire)) return .canceled;
        var stream = listener.server.accept(io) catch |err| {
            // Cancel wake may surface as accept error; prefer cancel over failure.
            if (cancel.load(.acquire)) return .canceled;
            return .{ .accept_failed = err };
        };
        defer stream.close(io);

        if (cancel.load(.acquire)) return .canceled;

        const now: i64 = @intCast(c.time(null));
        switch (serveConn(io, &stream, &listener.state, arena, listener.path, now)) {
            .keep, .bad_state => {},
            .complete => |result| {
                // completeLogin may take VIEWER_DEADLINE_S. If esc landed during verify,
                // return .canceled so connectTask skips its post (no "canceled" then
                // adopt, no join stall on a full event queue). Token may still sit on
                // disk for next launch; this session does not adopt an aborted connect.
                if (cancel.load(.acquire)) return .canceled;
                return outcomeOf(result);
            },
        }
    }
}

/// Wake a worker blocked in accept: dial localhost once. Caller MUST set cancel
/// (release) before this. Best-effort: refused dial means listener already gone or
/// a real callback won the race.
pub fn requestCancel(io: Io) void {
    var addr: net.IpAddress = .{ .ip4 = .loopback(PORT) };
    const stream = addr.connect(io, .{ .mode = .stream }) catch return;
    stream.close(io);
}

/// 32 lowercase-hex chars of kernel randomness. /dev/urandom failure → decline loopback.
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

/// Best-effort browser launch. URL already printed/modal-shown; missing opener → open by hand.
pub fn openBrowser(io: Io, url: []const u8) void {
    const opener = if (builtin.os.tag == .macos) "open" else "xdg-open";
    _ = std.process.spawn(io, .{
        .argv = &.{ opener, url },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {};
}

/// Read `key` from a `k=v&k=v` query, or null. No percent-decode (JWT/hex are URL-safe).
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
    try testing.expectEqual(Route.bad_state, classify("/callback?access_token=eyJx&state=WRONG", nonce));
    try testing.expectEqual(Route.bad_state, classify("/callback?access_token=eyJx", nonce));
    try testing.expectEqual(Route.bad_state, classify("/callback", nonce));
    try testing.expectEqual(Route.complete, classify("/callback?access_token=eyJx&state=abc123", nonce));
}

test "queryParam finds a value, ignores partial-key matches, null when absent" {
    const q = "access_token=eyJabc.def.ghi&token_type=Bearer&state=nonce123";
    try testing.expectEqualStrings("eyJabc.def.ghi", queryParam(q, "access_token").?);
    try testing.expectEqualStrings("nonce123", queryParam(q, "state").?);
    try testing.expectEqualStrings("Bearer", queryParam(q, "token_type").?);
    try testing.expect(queryParam(q, "token") == null);
    try testing.expect(queryParam(q, "code") == null);
    try testing.expect(queryParam("", "state") == null);
}

test "hexEncode maps bytes to lowercase hex" {
    var out: [32]u8 = undefined;
    hexEncode(&[_]u8{ 0x00, 0x0f, 0xa5, 0xff } ++ [_]u8{0} ** 12, &out);
    try testing.expectEqualStrings("000fa5ff", out[0..8]);
}

test "outcomeOf mirrors every LoginResult arm into a POD ConnectOutcome (ROD-286)" {
    try testing.expectEqual(ConnectOutcome.ok, outcomeOf(.{ .ok = .{} }));
    try testing.expectEqual(ConnectOutcome.no_token, outcomeOf(.no_token));
    try testing.expectEqual(ConnectOutcome.rejected, outcomeOf(.rejected));
    try testing.expectEqual(@as(anyerror, error.Unexpected), outcomeOf(.{ .verify_failed = error.Unexpected }).verify_failed);
    try testing.expectEqual(@as(anyerror, error.AccessDenied), outcomeOf(.{ .save_failed = error.AccessDenied }).save_failed);
}

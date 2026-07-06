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
//! ROD-286 (TUI connect): the CLI `run` blocks the calling thread, which the TUI
//! can't afford — vaxis owns the terminal. So the accept-handling core is factored
//! into `serveConn` (one connection → a `Served` verdict), which both `run` and the
//! async path share, and the setup/accept/cancel steps are exposed as `begin` →
//! `awaitConnect` → `requestCancel`: `begin` binds the port on the caller's thread
//! (a bind failure is synchronous — it toasts, never a half-open modal), a worker
//! runs `awaitConnect`, and the UI wakes a blocked `accept` for cancellation by
//! dialing the port once (`requestCancel`) after setting the shared cancel flag —
//! the documented `shutdown`/self-connect way to unblock `accept`, with no window
//! where a real callback is dropped by a racing deadline.
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

/// Shared inline styling for the three callback pages below — one constant,
/// concatenated in rather than copy-pasted per page, so a palette/contrast tweak
/// can't drift out of sync between them. Values echo the TUI's own tokens
/// (`tui/colors.zig`: bg_base/bg_elevated/chrome/fg/fg2/hot) so the browser tab
/// reads as the same product instead of a generic OAuth screen. Light is the
/// baseline (a browser with no color-scheme opinion still gets something clean);
/// dark activates via `prefers-color-scheme`, the likely case for anyone running
/// a terminal app in the first place. No external fonts/images — everything here
/// has to survive being served, as-is, off a bare loopback listener.
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

/// Served on the browser's first landing: the token is in `location.hash`, which
/// never reaches the server, so JS re-issues it as a query string to `/callback`.
/// The redirect script is byte-for-byte load-bearing — do not reformat, rewrap,
/// or otherwise touch it. (The token still transits *this* page's address bar
/// too, but only for the instant before the script below replaces it; `done_page`
/// / `fail_page` scrub the query-string landing that follows.)
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

/// Terminal success state. The callback that lands here carries the access token
/// in its query string (`/callback?access_token=…`) — the scrub script runs first,
/// before the stylesheet or body even parse, so the token clears the address bar
/// (and this tab's history entry) as early as the page can possibly manage it.
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

/// Terminal failure state — `serveConn` serves this instead of `done_page` whenever
/// `login.signedIn(result)` is false (bad state, no token, a rejected/unreachable
/// AniList verify, or a write failure). Same early address-bar scrub as `done_page`:
/// whatever AniList put in the query string doesn't get to linger either.
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

/// Returns whether a token was persisted (`login.signedIn`) so `main` can
/// bootstrap one full sync on a fresh sign-in (ROD-292). A `LoopbackUnavailable`
/// error routes the caller to the paste flow instead; any state-valid callback
/// that isn't `.ok` returns false.
pub fn run(arena: Allocator, io: Io, out: *Io.Writer) !bool {
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

        const now: i64 = @intCast(c.time(null));
        switch (serveConn(io, &stream, &state, arena, path, now)) {
            .keep => {},
            .bad_state => {
                if (!bad_state_warned) {
                    try out.writeAll("  ⚠ ignoring callback(s) with a bad state (stray or forged requests).\n");
                    try out.flush();
                    bad_state_warned = true; // warn once — don't let a flood spam the terminal.
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
                return login.signedIn(result); // one state-valid callback ends the flow, success or not.
            },
        }
    }
}

/// The verdict of serving one accepted connection. `keep`: a relay page (or a
/// dropped/stalled socket) — the accept loop should wait for the next hit.
/// `bad_state`: a forged/absent CSRF nonce; the fail page was served and the caller
/// may warn once. `complete`: a state-valid `/callback` ran `completeLogin`, whose
/// `LoginResult` (success or a specific failure arm) ends the flow.
pub const Served = union(enum) {
    keep,
    bad_state,
    complete: login.LoginResult,
};

/// Serve exactly one already-accepted connection: bounded `receiveHead`, CSRF
/// classify, respond with the matching page, and — only for a state-valid callback —
/// run the shared `completeLogin` (extract → verify → persist). Pulled out of `run`
/// so the blocking CLI loop and the async worker (`awaitConnect`) share ONE
/// accept-handling core; neither re-implements the CSRF gate or the respond/persist
/// sequence. No terminal or UI writes — the caller renders the verdict.
pub fn serveConn(io: Io, stream: *net.Stream, state: []const u8, arena: Allocator, path: []const u8, now: i64) Served {
    var recv_buf: [8192]u8 = undefined;
    var send_buf: [8192]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buf);
    var conn_writer = stream.writer(io, &send_buf);
    var server_conn: http.Server = .init(&conn_reader.interface, &conn_writer.interface);

    // Bounded read: a silent/stalled socket returns error.Timeout and is dropped
    // (`.keep`), so it can't wedge the serial accept loop (slowloris). The op runs on
    // a separate unit of concurrency and is joined before this frame moves on, so the
    // stack pointers it borrows stay valid.
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
            // Own the query: `completeLogin` persists a slice of it, so it must
            // outlive this connection's `recv_buf` (the paste path dupes too).
            const raw = arena.dupe(u8, query) catch query;
            const result = login.completeLogin(arena, io, raw, path, now);
            const page = if (login.signedIn(result)) done_page else fail_page;
            request.respond(page, .{ .keep_alive = false, .extra_headers = &html_header }) catch {};
            return .{ .complete = result };
        },
    }
}

// ── Async (TUI) connect: begin → awaitConnect → requestCancel (ROD-286) ──────────
//
// The CLI `run` above owns its whole flow on one blocking thread. The TUI can't
// block the render thread, so it drives the same listener in three steps: `begin`
// (main thread — bind + mint + build URL, so a bind failure is a synchronous toast
// not a half-open modal), `awaitConnect` (a worker thread — the accept loop, ending
// in a POD `ConnectOutcome` posted back to the UI), and `requestCancel` (main thread
// — wake a blocked `accept` so the worker can observe a set cancel flag and bail).

/// A worker→UI-safe distillation of a connect attempt. POD (an `anyerror` is a plain
/// error code, safe across the thread seam) so it ships by value in an event. `.ok`
/// carries nothing: `completeLogin` already persisted auth.zon, so the UI reloads it
/// to read the freshly-connected identity rather than marshalling a string across the
/// seam. The failure arms mirror `login.LoginResult`; `.canceled` is the user hitting
/// esc, `.accept_failed` a hard listener error (not a routine cancel wake).
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

/// A live loopback listener plus the two strings the UI needs. `server` is borrowed
/// by the worker (`accept`) and closed by the owner at teardown — never both at once
/// (the owner deinits only after joining the worker). `url`/`path` are caller-arena
/// owned: `url` (authorize URL + state nonce) renders in the modal and opens the
/// browser; `path` is auth.zon's location, where the worker persists.
pub const Listener = struct {
    server: net.Server,
    state: [32]u8,
    url: []const u8,
    path: []const u8,
};

/// Bind the loopback port and mint the CSRF nonce on the CALLING thread. Runs the
/// exact setup `run` does, minus the terminal prints, and returns a `Listener` the
/// caller stows (at a stable address) for the worker to borrow. `error.Loopback‐
/// Unavailable` on any setup failure — the UI shows a toast and never opens a modal.
/// The caller opens the browser (`openBrowser(io, listener.url)`) once this returns.
pub fn begin(arena: Allocator, io: Io) Error!Listener {
    var state: [32]u8 = undefined;
    mintState(io, &state) catch return error.LoopbackUnavailable;

    var addr: net.IpAddress = .{ .ip4 = .loopback(PORT) };
    var server = addr.listen(io, .{ .reuse_address = true }) catch return error.LoopbackUnavailable;
    // Close the bound socket if a later setup step fails — otherwise a rare
    // path/URL-alloc failure after a successful bind would leak the listener (and
    // hold the port), so the next connect attempt couldn't rebind.
    errdefer server.deinit(io);

    const path = auth.defaultPath(arena) catch return error.LoopbackUnavailable;
    const url = std.fmt.allocPrint(arena, "{s}&state={s}", .{ login.AUTHORIZE, state }) catch return error.LoopbackUnavailable;
    return .{ .server = server, .state = state, .url = url, .path = path };
}

/// The worker-thread accept loop: wait for the browser's state-valid callback and
/// return its `ConnectOutcome`, or `.canceled` when `cancel` is set (the UI wakes a
/// blocked `accept` via `requestCancel`). `cancel` is re-read right after every
/// `accept` — so a wake connection is dropped unserved — and at the loop top, so a
/// flag set before we even block still bails. A hard (non-cancel) accept error ends
/// the flow with `.accept_failed` rather than spinning. `arena` must outlive the
/// worker (the owner frees it only after joining).
pub fn awaitConnect(listener: *Listener, arena: Allocator, io: Io, cancel: *std.atomic.Value(bool)) ConnectOutcome {
    while (true) {
        if (cancel.load(.acquire)) return .canceled;
        var stream = listener.server.accept(io) catch |err| {
            // A cancel wake can surface as an accept error (e.g. the socket was torn
            // down mid-call); treat a set flag as the cancel it is, not a failure.
            if (cancel.load(.acquire)) return .canceled;
            return .{ .accept_failed = err };
        };
        defer stream.close(io);

        // Woken by the cancel self-connect: drop this connection unserved and bail.
        if (cancel.load(.acquire)) return .canceled;

        const now: i64 = @intCast(c.time(null));
        switch (serveConn(io, &stream, &listener.state, arena, listener.path, now)) {
            .keep, .bad_state => {},
            .complete => |result| {
                // `serveConn` ran a live network verify (`completeLogin` → `fetchViewer`),
                // a window of up to VIEWER_DEADLINE_S. If the user pressed esc during it,
                // honour the cancel: return `.canceled` so `connectTask` skips its post —
                // otherwise the UI would show "canceled" then contradictorily adopt the
                // token, and a post into a full event queue could stall teardown's join
                // (this is what makes the "join never blocks" contract true as written,
                // not just for the pre-serve cancel). A `.ok` here still persisted the
                // token to auth.zon, so a next launch adopts it — we just don't adopt it
                // into the session the user explicitly aborted.
                if (cancel.load(.acquire)) return .canceled;
                return outcomeOf(result);
            },
        }
    }
}

/// Wake a worker blocked in `accept` so it observes an already-set `cancel` flag:
/// dial the listener once from localhost. The dummy connection is accepted and
/// dropped unserved (the worker re-checks `cancel` before serving). Best-effort — a
/// refused dial means the listener is already gone or a real callback just won the
/// race, and the worker was going to return regardless. The caller MUST set the
/// shared cancel flag (release) BEFORE calling this, so the worker sees it on wake.
pub fn requestCancel(io: Io) void {
    var addr: net.IpAddress = .{ .ip4 = .loopback(PORT) };
    const stream = addr.connect(io, .{ .mode = .stream }) catch return;
    stream.close(io);
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

/// Best-effort browser launch. Fire-and-forget: the URL is already printed (or, in
/// the TUI, rendered in the connect modal), so a missing opener (or a headless/SSH
/// box) just means the user opens it by hand.
pub fn openBrowser(io: Io, url: []const u8) void {
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

test "outcomeOf mirrors every LoginResult arm into a POD ConnectOutcome (ROD-286)" {
    // The worker returns the async outcome by value across the thread seam; each
    // login arm must map to exactly one outcome (and only `.ok` signals a persisted
    // token, gating the bootstrap sync). `.canceled`/`.accept_failed` have no
    // LoginResult source — they're the worker's own, tested via awaitConnect's flow.
    try testing.expectEqual(ConnectOutcome.ok, outcomeOf(.{ .ok = .{} }));
    try testing.expectEqual(ConnectOutcome.no_token, outcomeOf(.no_token));
    try testing.expectEqual(ConnectOutcome.rejected, outcomeOf(.rejected));
    try testing.expectEqual(@as(anyerror, error.Unexpected), outcomeOf(.{ .verify_failed = error.Unexpected }).verify_failed);
    try testing.expectEqual(@as(anyerror, error.AccessDenied), outcomeOf(.{ .save_failed = error.AccessDenied }).save_failed);
}

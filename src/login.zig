//! Zigoku — AniList OAuth login capture (ROD-283).
//!
//! `zigoku login` walks the Implicit Grant capture by hand: print the authorize URL, take
//! the redirected URL back on stdin (SSH-safe manual paste), pull the bearer token from the
//! `#access_token=` fragment, verify it with a live `Viewer` call, and persist identity +
//! token to `auth.zon` (0600) via `auth.zig`.
//!
//! The capture CORE, `completeLogin`, is deliberately I/O-and-prompt free and injects its
//! clock, so slice 2b's loopback listener drives the exact same extract/verify/persist
//! sequence by handing it the relayed query string. That shared core guarantees "verify
//! before persist" for both paths from one place. This paste path stays the SSH-safe fallback.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const auth = @import("auth.zig");
const deadline = @import("util/deadline.zig");
const c = @cImport({
    @cInclude("time.h"); // time(2) — current unix seconds, matching store.zig
});

/// Wall-clock ceiling for the `Viewer` verify POST (ROD-286), matching the AniList
/// enrichment deadline in anilist.zig (ROD-262). std has no per-socket read timeout,
/// so a reachable-but-silent host would otherwise hang the call forever — harmless-ish
/// in the CLI (Ctrl-C kills it), but in the TUI the connect worker runs this, and
/// teardown joins that worker on the render thread: an unbounded verify there freezes
/// the whole UI, unkillable from inside. The bound turns that into a `.verify_failed`.
const VIEWER_DEADLINE_S = 10;

pub const CLIENT_ID = "43536";
/// The loopback port — the single source of truth. `REDIRECT` is derived from it,
/// and `login_loopback` binds it via `login.PORT`; changing it here moves both so
/// the listener can't drift off the URL AniList redirects to.
pub const PORT: u16 = 8765;
pub const REDIRECT = std.fmt.comptimePrint("http://localhost:{d}", .{PORT});
const ENDPOINT = "https://graphql.anilist.co";
// redirect_uri is omitted: the app has a single registered redirect (REDIRECT),
// so AniList uses it automatically. Adding it here would need URL-encoding for no gain.
pub const AUTHORIZE = "https://anilist.co/api/v2/oauth/authorize?client_id=" ++ CLIENT_ID ++ "&response_type=token";

/// Just enough of the `Viewer` query to confirm the token and stamp identity.
const Viewer = struct { id: i64 = 0, name: []const u8 = "" };

/// Outcome of a capture attempt, independent of how the raw redirect text was
/// obtained (stdin paste in 2a, loopback query string in 2b). The caller renders
/// each variant however it likes — CLI text here, an HTML page in 2b.
pub const LoginResult = union(enum) {
    ok: auth.Auth,
    no_token, //           no `access_token=` in the input
    rejected, //           AniList parsed clean but returned no Viewer (bad/expired token)
    verify_failed: anyerror, // couldn't reach/parse AniList to verify
    save_failed: anyerror, //   verified, but the write to auth.zon failed
};

/// The shared OAuth-capture core. `raw` is a pasted redirect URL (2a) or a
/// loopback request's relayed query string (2b) — both land here identically.
/// `now_unix` is injected (matching `AniListAuth.isExpired`'s convention) so the
/// sequence is clock-free and the control flow — never persist before a live
/// verify — is enforced here once for every caller.
pub fn completeLogin(arena: Allocator, io: Io, raw: []const u8, path: []const u8, now_unix: i64) LoginResult {
    const token = extractToken(raw);
    if (token.len < 20) return .no_token;
    const expires_in = extractExpiresIn(raw);

    const viewer = (fetchViewer(arena, io, token) catch |err| return .{ .verify_failed = err }) orelse return .rejected;

    const record: auth.Auth = .{ .anilist = .{
        .access_token = token,
        .token_type = "Bearer",
        .expires_at = if (expires_in > 0) now_unix + expires_in else 0,
        .user_id = viewer.id,
        .user_name = viewer.name,
    } };
    auth.save(io, record, path) catch |err| return .{ .save_failed = err };
    return .{ .ok = record };
}

/// Did a completed login actually persist a token? `.ok` is the only arm that
/// wrote auth.zon; every other arm aborted before saving. `main` gates the
/// ROD-292 post-login bootstrap sync on this, so a rejected, unreachable, or
/// unsaved attempt never triggers a stray sync report.
pub fn signedIn(result: LoginResult) bool {
    return switch (result) {
        .ok => true,
        else => false,
    };
}

/// Run the interactive paste login. Builds its own wide stdin reader: a pasted
/// redirect URL carries a ~1KB JWT, far past main's 256-byte prompt buffer.
/// Returns whether a token was persisted (`signedIn`) so `main` can bootstrap
/// one full sync on a fresh sign-in (ROD-292); an aborted paste returns false.
pub fn run(arena: Allocator, io: Io, out: *Io.Writer) !bool {
    const path = try auth.defaultPath(arena);
    const existing = auth.load(arena, io, path);
    if (existing.hasAniList()) {
        try out.print("Already signed in as {s} — re-running replaces it.\n\n", .{existing.anilist.user_name});
    }

    try out.print(
        \\Connect your AniList account (OAuth Implicit Grant).
        \\
        \\1. Open this URL in a browser and approve:
        \\
        \\   {s}
        \\
        \\2. You land on {s}/… — paste that whole URL below. If nothing is
        \\   listening there the page won't load; that's fine, the token is in the
        \\   address bar. Select the ENTIRE URL (the token has three dot-separated
        \\   parts — a double-click grabs only the first).
        \\
        \\redirect URL>
    , .{ AUTHORIZE, REDIRECT });
    try out.flush();

    var stdin_buf: [8192]u8 = undefined;
    var stdin_fr = Io.File.stdin().reader(io, &stdin_buf);
    const in = &stdin_fr.interface;

    const raw = in.takeDelimiterInclusive('\n') catch {
        try out.writeAll("\n  no input (or a paste past 8 KB) — aborted.\n");
        return false;
    };
    const line = try arena.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));

    try out.writeAll("\nverifying…\n");
    try out.flush();

    const now: i64 = @intCast(c.time(null));
    const result = completeLogin(arena, io, line, path, now);
    switch (result) {
        .ok => |rec| try out.print("  ✓ signed in as {s} (id {d}). Saved to {s}.\n", .{ rec.anilist.user_name, rec.anilist.user_id, path }),
        .no_token => try out.writeAll("  ✗ couldn't find an access_token in that — aborted.\n"),
        .rejected => try out.writeAll("  ✗ AniList rejected the token (invalid or expired). Re-copy the whole fragment and retry.\n"),
        .verify_failed => |err| try out.print("  ✗ couldn't reach AniList to verify ({s}) — check your connection and retry.\n", .{@errorName(err)}),
        .save_failed => |err| try out.print("  ✗ verified, but couldn't write {s}: {s}\n", .{ path, @errorName(err) }),
    }
    try out.flush();
    return signedIn(result);
}

/// Pull the JWT out of a pasted redirect URL (`…#access_token=<jwt>&…`) or a bare
/// token. Cuts at the first URL/whitespace delimiter so trailing `&token_type=…`
/// never rides along. Returns `""` when there's nothing token-shaped, so a denial
/// redirect (`?error=access_denied…`) or a bare `?state=…` isn't mistaken for a
/// token and fired at AniList as a bogus Bearer.
pub fn extractToken(raw: []const u8) []const u8 {
    const needle = "access_token=";
    if (std.mem.indexOf(u8, raw, needle)) |i| {
        const start = raw[i + needle.len ..];
        const end = std.mem.indexOfAny(u8, start, "&\r\n\t \"'") orelse start.len;
        return std.mem.trim(u8, start[0..end], " \t\r\n\"'");
    }
    // No `access_token=` — only accept a bare paste that actually looks like a JWT.
    // Every AniList JWT starts `eyJ` (base64 of `{"typ"…`); anything else is not a
    // token we should try.
    const bare = std.mem.trim(u8, raw, " \t\r\n\"'");
    if (!std.mem.startsWith(u8, bare, "eyJ")) return "";
    const end = std.mem.indexOfAny(u8, bare, "&\r\n\t \"'") orelse bare.len;
    return bare[0..end];
}

/// Read `expires_in=<secs>` from the fragment, 0 if absent. A bare-token paste has
/// no expiry → 0, which `auth.isExpired` treats as live (send it, let AniList 401).
pub fn extractExpiresIn(raw: []const u8) i64 {
    const needle = "expires_in=";
    const i = std.mem.indexOf(u8, raw, needle) orelse return 0;
    const rest = raw[i + needle.len ..];
    const end = std.mem.indexOfAny(u8, rest, "&\r\n\t \"'") orelse rest.len;
    return std.fmt.parseInt(i64, rest[0..end], 10) catch 0;
}

/// Map a raw `{Viewer{id name}}` response body to a Viewer. The token-validity
/// decision, split out from the network call so it's testable against canned JSON:
///   - `error.BadJson` → body didn't parse (server outage / HTML error page)
///   - `null`          → parsed, but no viewer — AniList returns `data:null` with
///                       an `errors` array for an invalid/expired token
///   - `Viewer`        → success
fn parseViewerResponse(arena: Allocator, raw_json: []const u8) error{BadJson}!?Viewer {
    const Resp = struct { data: ?struct { Viewer: ?Viewer = null } = null };
    const parsed = std.json.parseFromSlice(Resp, arena, raw_json, .{
        .ignore_unknown_fields = true,
    }) catch return error.BadJson;
    const data = parsed.value.data orelse return null;
    return data.Viewer;
}

/// One authenticated `{ Viewer { id name } }` call, bounded by `VIEWER_DEADLINE_S`
/// (ROD-286). A stalled fetch surfaces as `error.Timeout` — which `completeLogin`
/// folds into `.verify_failed`, exactly like any other transport failure — instead of
/// hanging the caller (in the TUI, the connect worker the render thread must join).
fn fetchViewer(arena: Allocator, io: Io, token: []const u8) !?Viewer {
    return deadline.withDeadline(io, .fromSeconds(VIEWER_DEADLINE_S), fetchViewerOnce, .{ arena, io, token });
}

/// The un-bounded verify POST, run as a cancelable unit by `fetchViewer`'s `withDeadline`
/// (ROD-262): it owns `client` (defer deinit), so the deadline's cancel turns the blocked
/// recv into `error.Canceled` and this frame unwinds, freeing the client rather than leaking
/// it. Transport failures propagate; an unparseable body surfaces as `error.BadJson`; a
/// parsed-but-viewerless body (bad token) returns null. Status is intentionally NOT gated on:
/// AniList answers an invalid token with HTTP 400 AND a JSON error body, so the parse outcome,
/// not the status, is the reliable "is this token good" signal.
fn fetchViewerOnce(arena: Allocator, io: Io, token: []const u8) !?Viewer {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    var resp_aw = std.Io.Writer.Allocating.init(arena);
    const authz = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});
    _ = try client.fetch(.{
        .location = .{ .url = ENDPOINT },
        .method = .POST,
        .payload = "{\"query\":\"{Viewer{id name}}\"}",
        .response_writer = &resp_aw.writer,
        .extra_headers = &.{
            .{ .name = "Authorization", .value = authz },
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Accept", .value = "application/json" },
        },
    });
    return parseViewerResponse(arena, resp_aw.writer.buffered());
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "extractToken pulls the JWT out of a full redirect URL" {
    const url = "http://localhost:8765/#access_token=eyJhbc.def.ghi&token_type=Bearer&expires_in=31536000";
    try testing.expectEqualStrings("eyJhbc.def.ghi", extractToken(url));
}

test "extractToken accepts a bare token unchanged" {
    try testing.expectEqualStrings("eyJhbc.def.ghi", extractToken("eyJhbc.def.ghi"));
}

test "extractToken trims stray quotes and whitespace" {
    try testing.expectEqualStrings("eyJhbc.def.ghi", extractToken("  '#access_token=eyJhbc.def.ghi' \n"));
}

test "extractToken returns empty for non-token queries (deny redirect, bare state)" {
    // A denial redirect or a bare state param must not be fired at AniList as a token.
    try testing.expectEqualStrings("", extractToken("error=access_denied&error_description=denied"));
    try testing.expectEqualStrings("", extractToken("state=6269b8e26c3de42af04f6a4c6e948f8f"));
    try testing.expectEqualStrings("", extractToken("a long string that is not token-shaped at all"));
    // …but an access_token= anywhere still wins.
    try testing.expectEqualStrings("eyJreal.tok.en", extractToken("error=x&access_token=eyJreal.tok.en"));
}

test "extractExpiresIn reads the lifetime, 0 when absent" {
    try testing.expectEqual(@as(i64, 31536000), extractExpiresIn("…&token_type=Bearer&expires_in=31536000"));
    try testing.expectEqual(@as(i64, 0), extractExpiresIn("#access_token=eyJhbc.def.ghi"));
    try testing.expectEqual(@as(i64, 0), extractExpiresIn("expires_in=notanumber"));
}

test "parseViewerResponse maps a real viewer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parseViewerResponse(arena.allocator(), "{\"data\":{\"Viewer\":{\"id\":7887529,\"name\":\"vantroy\"}}}");
    try testing.expect(v != null);
    try testing.expectEqual(@as(i64, 7887529), v.?.id);
    try testing.expectEqualStrings("vantroy", v.?.name);
}

test "parseViewerResponse returns null for a viewerless body (bad token)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // data present, Viewer explicitly null
    try testing.expect((try parseViewerResponse(a, "{\"data\":{\"Viewer\":null}}")) == null);
    // AniList's invalid-token shape: errors array + data null
    try testing.expect((try parseViewerResponse(a, "{\"errors\":[{\"message\":\"Invalid token\"}],\"data\":null}")) == null);
    // data key missing entirely
    try testing.expect((try parseViewerResponse(a, "{\"errors\":[{\"message\":\"x\"}]}")) == null);
}

test "parseViewerResponse errors on an unparseable body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.BadJson, parseViewerResponse(arena.allocator(), "<html>502 Bad Gateway</html>"));
}

test "signedIn is true only for the persisted-token (.ok) arm (ROD-292)" {
    // Only `.ok` wrote auth.zon, so only it may trigger the post-login bootstrap
    // sync — every failure arm must return false or a rejected login would fire a
    // stray sync report.
    try testing.expect(signedIn(.{ .ok = .{} }));
    try testing.expect(!signedIn(.no_token));
    try testing.expect(!signedIn(.rejected));
    try testing.expect(!signedIn(.{ .verify_failed = error.Unexpected }));
    try testing.expect(!signedIn(.{ .save_failed = error.Unexpected }));
}

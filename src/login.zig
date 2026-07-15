//! AniList OAuth login capture (ROD-283).
//!
//! `zigoku login` walks Implicit Grant by hand: authorize URL, paste redirect (SSH-safe),
//! extract token, live Viewer verify, persist via auth.zig. `completeLogin` is I/O-free so
//! the loopback path drives the same extract/verify/persist (verify-before-persist once).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const auth = @import("auth.zig");
const deadline = @import("util/deadline.zig");
const c = @cImport({
    @cInclude("time.h"); // time(2) — current unix seconds, matching store.zig
});

/// Viewer verify ceiling (ROD-286). TUI connect worker is joined on the render thread;
/// unbounded verify freezes the UI.
const VIEWER_DEADLINE_S = 10;

pub const CLIENT_ID = "43536";
/// Loopback port: single source of truth for REDIRECT and login_loopback bind.
pub const PORT: u16 = 8765;
pub const REDIRECT = std.fmt.comptimePrint("http://localhost:{d}", .{PORT});
const ENDPOINT = "https://graphql.anilist.co";
// Single registered redirect; AniList uses it without redirect_uri in the authorize URL.
pub const AUTHORIZE = "https://anilist.co/api/v2/oauth/authorize?client_id=" ++ CLIENT_ID ++ "&response_type=token";

const Viewer = struct { id: i64 = 0, name: []const u8 = "" };

/// Capture outcome for paste (2a) or loopback query (2b).
pub const LoginResult = union(enum) {
    ok: auth.Auth,
    no_token,
    rejected, // AniList parsed clean but no Viewer (bad/expired token)
    verify_failed: anyerror,
    save_failed: anyerror,
};

/// Shared OAuth core. Never persist before live verify. `now_unix` injected (clock-free).
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

/// True only if auth.zon was written (ROD-292 bootstrap sync gate).
pub fn signedIn(result: LoginResult) bool {
    return switch (result) {
        .ok => true,
        else => false,
    };
}

/// Interactive paste login. Wide stdin (JWT ~1KB). Returns whether a token was persisted.
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

/// JWT from `#access_token=` or bare eyJ… paste. Empty for deny redirects / bare state
/// (must not fire non-tokens at AniList as Bearer).
pub fn extractToken(raw: []const u8) []const u8 {
    const needle = "access_token=";
    if (std.mem.indexOf(u8, raw, needle)) |i| {
        const start = raw[i + needle.len ..];
        const end = std.mem.indexOfAny(u8, start, "&\r\n\t \"'") orelse start.len;
        return std.mem.trim(u8, start[0..end], " \t\r\n\"'");
    }
    const bare = std.mem.trim(u8, raw, " \t\r\n\"'");
    if (!std.mem.startsWith(u8, bare, "eyJ")) return "";
    const end = std.mem.indexOfAny(u8, bare, "&\r\n\t \"'") orelse bare.len;
    return bare[0..end];
}

/// `expires_in` seconds, or 0 (auth.isExpired treats 0 as live; AniList 401s if dead).
pub fn extractExpiresIn(raw: []const u8) i64 {
    const needle = "expires_in=";
    const i = std.mem.indexOf(u8, raw, needle) orelse return 0;
    const rest = raw[i + needle.len ..];
    const end = std.mem.indexOfAny(u8, rest, "&\r\n\t \"'") orelse rest.len;
    return std.fmt.parseInt(i64, rest[0..end], 10) catch 0;
}

/// Map Viewer JSON: BadJson / null (invalid token) / Viewer. Split from network for tests.
fn parseViewerResponse(arena: Allocator, raw_json: []const u8) error{BadJson}!?Viewer {
    const Resp = struct { data: ?struct { Viewer: ?Viewer = null } = null };
    const parsed = std.json.parseFromSlice(Resp, arena, raw_json, .{
        .ignore_unknown_fields = true,
    }) catch return error.BadJson;
    const data = parsed.value.data orelse return null;
    return data.Viewer;
}

/// Bounded verify (ROD-286). Timeout → verify_failed, same as other transport errors.
fn fetchViewer(arena: Allocator, io: Io, token: []const u8) !?Viewer {
    return deadline.withDeadline(io, .fromSeconds(VIEWER_DEADLINE_S), fetchViewerOnce, .{ arena, io, token });
}

/// Unbounded POST as cancelable unit. Status intentionally not gated: invalid token is
/// HTTP 400 + JSON errors; parse outcome is the reliable "is this token good" signal.
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
    try testing.expectEqualStrings("", extractToken("error=access_denied&error_description=denied"));
    try testing.expectEqualStrings("", extractToken("state=6269b8e26c3de42af04f6a4c6e948f8f"));
    try testing.expectEqualStrings("", extractToken("a long string that is not token-shaped at all"));
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
    try testing.expect((try parseViewerResponse(a, "{\"data\":{\"Viewer\":null}}")) == null);
    try testing.expect((try parseViewerResponse(a, "{\"errors\":[{\"message\":\"Invalid token\"}],\"data\":null}")) == null);
    try testing.expect((try parseViewerResponse(a, "{\"errors\":[{\"message\":\"x\"}]}")) == null);
}

test "parseViewerResponse errors on an unparseable body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.BadJson, parseViewerResponse(arena.allocator(), "<html>502 Bad Gateway</html>"));
}

test "signedIn is true only for the persisted-token (.ok) arm (ROD-292)" {
    try testing.expect(signedIn(.{ .ok = .{} }));
    try testing.expect(!signedIn(.no_token));
    try testing.expect(!signedIn(.rejected));
    try testing.expect(!signedIn(.{ .verify_failed = error.Unexpected }));
    try testing.expect(!signedIn(.{ .save_failed = error.Unexpected }));
}

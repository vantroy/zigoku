//! Zigoku — AniList OAuth login flow (ROD-283.2a).
//!
//! `zigoku login` walks the Implicit Grant capture by hand: print the authorize
//! URL, take the redirected URL back on stdin (SSH-safe manual paste), pull the
//! bearer token out of the `#access_token=` fragment, verify it with a `Viewer`
//! call, and persist identity + token to `auth.zon` (0600) via `auth.zig`.
//!
//! ROD-283.2b will add a loopback listener that auto-captures the token from the
//! browser redirect; this paste path stays as the fallback and the headless/SSH
//! route, so the manual option never goes away.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const auth = @import("auth.zig");
const c = @cImport({
    @cInclude("time.h"); // time(2) — current unix seconds, matching store.zig
});

const CLIENT_ID = "43536";
const REDIRECT = "http://localhost:8765";
const ENDPOINT = "https://graphql.anilist.co";
// redirect_uri is omitted: the app has a single registered redirect (localhost:8765),
// so AniList uses it automatically. Adding it here would need URL-encoding for no gain.
const AUTHORIZE = "https://anilist.co/api/v2/oauth/authorize?client_id=" ++ CLIENT_ID ++ "&response_type=token";

/// Just enough of the `Viewer` query to confirm the token and stamp identity.
const Viewer = struct { id: i64 = 0, name: []const u8 = "" };

/// Run the interactive login. Builds its own wide stdin reader: a pasted redirect
/// URL carries a ~1KB JWT, far past main's 256-byte prompt buffer.
pub fn run(arena: Allocator, io: Io, out: *Io.Writer) !void {
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
        try out.writeAll("\n  no input — aborted.\n");
        return;
    };
    const line = try arena.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));

    const token = extractToken(line);
    if (token.len < 20) {
        try out.writeAll("\n  couldn't find an access_token in that — aborted.\n");
        return;
    }
    const expires_in = extractExpiresIn(line);

    // Verify before persisting — never save a token AniList won't honour.
    try out.writeAll("\nverifying…\n");
    try out.flush();
    const viewer = (fetchViewer(arena, io, token) catch |err| {
        try out.print("  ✗ verification failed: {s}\n", .{@errorName(err)});
        return;
    }) orelse {
        try out.writeAll("  ✗ AniList rejected the token (Invalid token). Re-copy the whole fragment and retry.\n");
        return;
    };

    const now: i64 = @intCast(c.time(null));
    const record: auth.Auth = .{ .anilist = .{
        .access_token = token,
        .token_type = "Bearer",
        .expires_at = if (expires_in > 0) now + expires_in else 0,
        .user_id = viewer.id,
        .user_name = viewer.name,
    } };
    auth.save(io, record, path) catch |err| {
        try out.print("  ✗ couldn't write {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };
    try out.print("  ✓ signed in as {s} (id {d}). Saved to {s}.\n", .{ viewer.name, viewer.id, path });
    try out.flush();
}

/// Pull the JWT out of a pasted redirect URL (`…#access_token=<jwt>&…`) or a bare
/// token. Cuts at the first URL/whitespace delimiter so trailing `&token_type=…`
/// never rides along.
fn extractToken(raw: []const u8) []const u8 {
    const needle = "access_token=";
    const start = if (std.mem.indexOf(u8, raw, needle)) |i| raw[i + needle.len ..] else raw;
    const end = std.mem.indexOfAny(u8, start, "&\r\n\t \"'") orelse start.len;
    return std.mem.trim(u8, start[0..end], " \t\r\n\"'");
}

/// Read `expires_in=<secs>` from the fragment, 0 if absent. A bare-token paste has
/// no expiry → 0, which `auth.isExpired` treats as live (send it, let AniList 401).
fn extractExpiresIn(raw: []const u8) i64 {
    const needle = "expires_in=";
    const i = std.mem.indexOf(u8, raw, needle) orelse return 0;
    const rest = raw[i + needle.len ..];
    const end = std.mem.indexOfAny(u8, rest, "&\r\n\t \"'") orelse rest.len;
    return std.fmt.parseInt(i64, rest[0..end], 10) catch 0;
}

/// One authenticated `{ Viewer { id name } }` call. Returns the viewer on success,
/// null if AniList returned no `data.Viewer` (e.g. an invalid/expired token).
fn fetchViewer(arena: Allocator, io: Io, token: []const u8) !?Viewer {
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

    const Resp = struct { data: ?struct { Viewer: ?Viewer = null } = null };
    const parsed = std.json.parseFromSlice(Resp, arena, resp_aw.writer.buffered(), .{
        .ignore_unknown_fields = true,
    }) catch return null;
    const data = parsed.value.data orelse return null;
    return data.Viewer;
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

test "extractExpiresIn reads the lifetime, 0 when absent" {
    try testing.expectEqual(@as(i64, 31536000), extractExpiresIn("…&token_type=Bearer&expires_in=31536000"));
    try testing.expectEqual(@as(i64, 0), extractExpiresIn("#access_token=eyJhbc.def.ghi"));
    try testing.expectEqual(@as(i64, 0), extractExpiresIn("expires_in=notanumber"));
}

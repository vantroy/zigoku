//! Boot-time update check (ROD-370). Best-effort: compare our built-in version
//! against the tag GitHub reports for the latest release, and if we're behind,
//! hand the caller the newer version to toast. Cached 6h so the network is hit at
//! most once per window; every failure mode (offline, rate-limited, malformed
//! body, no cache dir) returns null; the check never blocks startup and never
//! surfaces an error. Whether to run at all is the caller's config gate
//! (`check_for_updates`), not this module's concern.
//!
//! Decoupled from `root` on purpose: the current version and the wall clock come
//! in as parameters, so the module carries no import cycle and stays unit-testable
//! without a real clock or network.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const http = @import("providers/http.zig");
const paths = @import("paths.zig");
const semver = @import("util/semver.zig");

const log = std.log.scoped(.update_check);

/// Re-check no more than once per this window. A background version poll doesn't
/// need to be fresher than "sometime today", and 6h keeps us far under GitHub's
/// unauthenticated rate limit even across many launches.
pub const CHECK_TTL_SECS: i64 = 6 * 60 * 60;

/// GitHub rejects API requests without a User-Agent (403). Identify ourselves.
const USER_AGENT = "zigoku-update-check";

const LATEST_URL = "https://api.github.com/repos/vantroy/zigoku/releases/latest";

/// What the 6h cache holds: when we last asked, and the tag we got back.
pub const CacheEntry = struct {
    checked_at: i64,
    latest_version: []const u8,
};

/// The one call the app makes. Returns the latest release tag ONLY when it's
/// strictly newer than `current_version` (so the caller toasts iff there's
/// something to update to); null otherwise, including on every failure. `now` is
/// unix seconds (`Store.nowSecs()`), passed in so the module needs no clock.
pub fn check(arena: Allocator, io: Io, current_version: []const u8, now: i64) ?[]const u8 {
    const latest = resolveLatest(arena, io, now) orelse return null;
    return if (semver.isNewer(latest, current_version)) latest else null;
}

/// The latest tag, from cache if the last check is still fresh, else from the
/// network (writing the cache on success). null on any failure or missing dir.
fn resolveLatest(arena: Allocator, io: Io, now: i64) ?[]const u8 {
    if (readCache(arena, io)) |entry| {
        if (isFresh(entry.checked_at, now)) return entry.latest_version;
    }

    const latest = fetchLatest(arena, io) catch |e| {
        log.debug("fetch failed: {s}", .{@errorName(e)});
        return null;
    };
    writeCache(arena, io, now, latest);
    return latest;
}

/// A cache write is still fresh if it's within the TTL and not dated in the
/// future. The future-date guard stops a clock that jumped backward (or a
/// hand-edited file) from wedging the check on a stale answer forever.
pub fn isFresh(checked_at: i64, now: i64) bool {
    if (checked_at > now) return false;
    return now - checked_at < CHECK_TTL_SECS;
}

/// `$XDG_CACHE_HOME/zigoku/update_check`, owned by `arena`. null when there's no
/// resolvable cache dir (no `$XDG_CACHE_HOME`/`$HOME`).
fn cachePath(arena: Allocator) ?[]const u8 {
    const dir = paths.cacheDir(arena) catch return null;
    return std.fmt.allocPrint(arena, "{s}/update_check", .{dir}) catch null;
}

/// Read + parse the cache file. null on any problem (missing, unreadable,
/// malformed): a bad cache is indistinguishable from no cache, and both mean
/// "re-check".
fn readCache(arena: Allocator, io: Io) ?CacheEntry {
    const path = cachePath(arena) orelse return null;
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);

    var reader = file.reader(io, &.{});
    const text = reader.interface.allocRemaining(arena, Io.Limit.limited(4096)) catch return null;
    return parseCache(text);
}

/// Parse the two-line cache body (`<checked_at>\n<tag>\n`). Pure so the format
/// contract is unit-tested without touching disk. Returns null on anything that
/// isn't a valid unix timestamp on line one and a non-empty tag on line two. The
/// returned tag borrows `text`.
pub fn parseCache(text: []const u8) ?CacheEntry {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const ts_line = std.mem.trim(u8, lines.next() orelse return null, " \r\t");
    const tag_line = std.mem.trim(u8, lines.next() orelse return null, " \r\t");
    if (tag_line.len == 0) return null;
    const checked_at = std.fmt.parseInt(i64, ts_line, 10) catch return null;
    return .{ .checked_at = checked_at, .latest_version = tag_line };
}

/// Best-effort cache write. A failure here (no dir, unwritable) just means the
/// next launch re-checks over the network, never worth surfacing.
fn writeCache(arena: Allocator, io: Io, now: i64, latest: []const u8) void {
    const dir = paths.cacheDir(arena) catch return;
    paths.ensureDir(dir);
    const path = std.fmt.allocPrint(arena, "{s}/update_check", .{dir}) catch return;

    var file = std.Io.Dir.createFileAbsolute(io, path, .{}) catch |e| {
        log.debug("cache write failed: {s}", .{@errorName(e)});
        return;
    };
    defer file.close(io);
    var buf: [128]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "{d}\n{s}\n", .{ now, latest }) catch return;
    file.writeStreamingAll(io, body) catch |e| log.debug("cache write failed: {s}", .{@errorName(e)});
}

/// GET the latest release and pull its tag. The body is capped by the shared
/// transport; GitHub's `/releases/latest` skips prereleases and drafts, so the
/// tag we read is the newest stable cut.
fn fetchLatest(arena: Allocator, io: Io) ![]const u8 {
    const body = try http.request(arena, io, .{
        .method = .GET,
        .url = LATEST_URL,
        .user_agent = USER_AGENT,
        .tag = "update_check",
    });
    return parseLatestTag(arena, body);
}

/// The one field we want out of the release JSON. Everything else is ignored.
const LatestRelease = struct { tag_name: []const u8 };

/// Extract `tag_name` from a `/releases/latest` body. Split out so the JSON
/// contract is testable against a captured payload. The returned tag is owned by
/// `arena` (the parsed document's strings live there).
fn parseLatestTag(arena: Allocator, body: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(LatestRelease, arena, body, .{ .ignore_unknown_fields = true });
    if (parsed.value.tag_name.len == 0) return error.EmptyTag;
    return parsed.value.tag_name;
}

// ── Tests ──────────────────────────────────────────────────────────────────────

test "isFresh: within TTL is fresh, past TTL and future are stale" {
    const now: i64 = 1_000_000;
    try std.testing.expect(isFresh(now, now)); // just checked
    try std.testing.expect(isFresh(now - (CHECK_TTL_SECS - 1), now)); // one sec inside
    try std.testing.expect(!isFresh(now - CHECK_TTL_SECS, now)); // exactly at TTL
    try std.testing.expect(!isFresh(now - (CHECK_TTL_SECS + 1), now)); // past TTL
    try std.testing.expect(!isFresh(now + 1, now)); // future-dated → stale, re-check
}

test "parseCache: valid two-line body" {
    const entry = parseCache("1700000000\nv0.5.0\n").?;
    try std.testing.expectEqual(@as(i64, 1700000000), entry.checked_at);
    try std.testing.expectEqualStrings("v0.5.0", entry.latest_version);
}

test "parseCache: tolerates trailing CR and no final newline" {
    const entry = parseCache("1700000000\r\nv0.5.0").?;
    try std.testing.expectEqual(@as(i64, 1700000000), entry.checked_at);
    try std.testing.expectEqualStrings("v0.5.0", entry.latest_version);
}

test "parseCache: rejects malformed bodies" {
    try std.testing.expectEqual(@as(?CacheEntry, null), parseCache(""));
    try std.testing.expectEqual(@as(?CacheEntry, null), parseCache("1700000000\n")); // no tag
    try std.testing.expectEqual(@as(?CacheEntry, null), parseCache("1700000000\n\n")); // empty tag
    try std.testing.expectEqual(@as(?CacheEntry, null), parseCache("notanumber\nv0.5.0\n"));
    try std.testing.expectEqual(@as(?CacheEntry, null), parseCache("onlyoneline"));
}

test "parseLatestTag: pulls tag_name, ignores the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\{"url":"https://api.github.com/...","tag_name":"v0.5.0","name":"v0.5.0","draft":false,"prerelease":false}
    ;
    const tag = try parseLatestTag(arena.allocator(), body);
    try std.testing.expectEqualStrings("v0.5.0", tag);
}

test "parseLatestTag: errors on a body with no usable tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.EmptyTag, parseLatestTag(arena.allocator(), "{\"tag_name\":\"\"}"));
    try std.testing.expectError(error.MissingField, parseLatestTag(arena.allocator(), "{}"));
}

//! Boot-time update check (ROD-370). Best-effort: compare built-in version to GitHub
//! latest tag; return newer version for toast, else null. Cached 1h; every failure
//! (offline, rate-limit, bad body, no cache dir) → null. Never blocks startup, never
//! surfaces errors. Caller's config (`check_for_updates`) gates whether to run.
//!
//! Version + wall clock are parameters (no root import cycle; unit-testable).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const http = @import("providers/http.zig");
const paths = @import("paths.zig");
const semver = @import("util/semver.zig");
const deadline = @import("util/deadline.zig");

const log = std.log.scoped(.update_check);

/// Ambient re-check window; stays under GitHub unauth rate limit across launches.
pub const CHECK_TTL_SECS: i64 = 1 * 60 * 60;

/// GitHub API rejects requests without User-Agent (403).
const USER_AGENT = "zigoku-update-check";

/// Cap on the one GET. Without it a silent host hangs boot-worker join on quit.
const FETCH_DEADLINE_S = 3;

const LATEST_URL = "https://api.github.com/repos/vantroy/zigoku/releases/latest";

pub const CacheEntry = struct {
    checked_at: i64,
    latest_version: []const u8,
};

/// Latest tag only when strictly newer than `current_version`; null otherwise / on failure.
/// `now` = unix seconds (injected; no clock in this module).
pub fn check(arena: Allocator, io: Io, current_version: []const u8, now: i64) ?[]const u8 {
    const latest = resolveLatest(arena, io, now) orelse return null;
    return if (semver.isNewer(latest, current_version)) latest else null;
}

/// Fresh network tag (bypasses 1h cache; refreshes it). For `zigoku update` (ROD-371).
pub fn latestFresh(arena: Allocator, io: Io, now: i64) ?[]const u8 {
    const tag = fetchLatest(arena, io) catch return null;
    writeCache(arena, io, now, tag);
    return tag;
}

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

/// Fresh if within TTL and not future-dated (backward clock / hand-edit must not wedge forever).
pub fn isFresh(checked_at: i64, now: i64) bool {
    if (checked_at > now) return false;
    return now - checked_at < CHECK_TTL_SECS;
}

fn cachePath(arena: Allocator) ?[]const u8 {
    const dir = paths.cacheDir(arena) catch return null;
    return std.fmt.allocPrint(arena, "{s}/update_check", .{dir}) catch null;
}

/// null on any problem: bad cache ≡ no cache → re-check.
fn readCache(arena: Allocator, io: Io) ?CacheEntry {
    const path = cachePath(arena) orelse return null;
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);

    var reader = file.reader(io, &.{});
    const text = reader.interface.allocRemaining(arena, Io.Limit.limited(4096)) catch return null;
    return parseCache(text);
}

/// Two-line body (`<checked_at>\n<tag>\n`). Pure; tag borrows `text`.
pub fn parseCache(text: []const u8) ?CacheEntry {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const ts_line = std.mem.trim(u8, lines.next() orelse return null, " \r\t");
    const tag_line = std.mem.trim(u8, lines.next() orelse return null, " \r\t");
    if (tag_line.len == 0) return null;
    const checked_at = std.fmt.parseInt(i64, ts_line, 10) catch return null;
    return .{ .checked_at = checked_at, .latest_version = tag_line };
}

/// Best-effort; failure means next launch re-checks.
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

/// GET latest release tag. `/releases/latest` skips prereleases/drafts.
fn fetchLatest(arena: Allocator, io: Io) ![]const u8 {
    const body = try deadline.withDeadline(io, .fromSeconds(FETCH_DEADLINE_S), http.request, .{
        arena, io,
        http.Request{
            .method = .GET,
            .url = LATEST_URL,
            .user_agent = USER_AGENT,
            .tag = "update_check",
        },
    });
    return parseLatestTag(arena, body);
}

const LatestRelease = struct { tag_name: []const u8 };

/// Arena-owned tag from JSON body (testable against a captured payload).
fn parseLatestTag(arena: Allocator, body: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(LatestRelease, arena, body, .{ .ignore_unknown_fields = true });
    if (parsed.value.tag_name.len == 0) return error.EmptyTag;
    return parsed.value.tag_name;
}

test "isFresh: within TTL is fresh, past TTL and future are stale" {
    const now: i64 = 1_000_000;
    try std.testing.expect(isFresh(now, now));
    try std.testing.expect(isFresh(now - (CHECK_TTL_SECS - 1), now));
    try std.testing.expect(!isFresh(now - CHECK_TTL_SECS, now));
    try std.testing.expect(!isFresh(now - (CHECK_TTL_SECS + 1), now));
    try std.testing.expect(!isFresh(now + 1, now)); // future-dated → re-check
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
    try std.testing.expectEqual(@as(?CacheEntry, null), parseCache("1700000000\n"));
    try std.testing.expectEqual(@as(?CacheEntry, null), parseCache("1700000000\n\n"));
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

//! Shared HLS master-playlist parsing + quality-cap selection (ROD-302). Lifted out
//! of allanime.zig so every provider that hands back an adaptive m3u8 master can honor
//! the user's quality preference through one implementation. Providers fetch the master
//! themselves (the CDN headers differ per source) and feed the bytes here; the cap
//! policy and the variant math live in this one place.

const std = @import("std");
const Allocator = std.mem.Allocator;
const domain = @import("../domain.zig");

/// One entry of a master playlist: a variant URI (verbatim, possibly relative) and
/// its vertical resolution when the STREAM-INF advertised one.
pub const Variant = struct { url: []const u8, resolution: ?u32 = null };

/// Vertical pixel count from a `RESOLUTION=1920x1080` attribute on an
/// EXT-X-STREAM-INF line; null if absent or malformed.
fn streamInfHeight(inf_line: []const u8) ?u32 {
    const key = "RESOLUTION=";
    const at = std.mem.indexOf(u8, inf_line, key) orelse return null;
    const rest = inf_line[at + key.len ..];
    const x = std.mem.indexOfScalar(u8, rest, 'x') orelse return null;
    var end: usize = x + 1;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    return std.fmt.parseInt(u32, rest[x + 1 .. end], 10) catch null;
}

/// Parse an m3u8 *master* playlist: each `#EXT-X-STREAM-INF:` (its resolution)
/// paired with the URI on the next non-comment line. URIs come back verbatim;
/// relative ones are joined against the playlist URL by the network caller. A
/// playlist with no STREAM-INF is already a media playlist (no variants) and
/// yields an empty slice; the caller then treats the link as one best stream.
pub fn parseMasterPlaylist(arena: Allocator, text: []const u8) ![]Variant {
    var out: std.ArrayList(Variant) = .empty;
    var expect_uri = false;
    var pending_res: ?u32 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#EXT-X-STREAM-INF")) {
            expect_uri = true;
            pending_res = streamInfHeight(line);
        } else if (line[0] == '#') {
            continue;
        } else if (expect_uri) {
            try out.append(arena, .{ .url = try arena.dupe(u8, line), .resolution = pending_res });
            expect_uri = false;
            pending_res = null;
        }
    }
    return out.toOwnedSlice(arena);
}

/// Resolve a possibly-relative m3u8 URI against the playlist URL it came from.
/// Absolute (`http…`) passes through; `/rooted` keeps scheme+host; otherwise
/// it's relative to the playlist's directory.
pub fn joinUrl(arena: Allocator, base: []const u8, ref: []const u8) ![]u8 {
    // Absolute refs pass through. `./`/`../` segments are left literal: the
    // URL is handed to mpv, which normalizes them, so we don't resolve here.
    if (std.mem.startsWith(u8, ref, "http://") or std.mem.startsWith(u8, ref, "https://"))
        return arena.dupe(u8, ref);
    const scheme_end = (std.mem.indexOf(u8, base, "://") orelse return error.BadBaseUrl) + 3;
    const host_end = std.mem.indexOfScalarPos(u8, base, scheme_end, '/') orelse base.len;
    if (std.mem.startsWith(u8, ref, "/")) return std.mem.concat(arena, u8, &.{ base[0..host_end], ref });
    const last_slash = std.mem.lastIndexOfScalar(u8, base, '/') orelse host_end;
    const dir_end = if (last_slash >= host_end) last_slash + 1 else host_end;
    return std.mem.concat(arena, u8, &.{ base[0..dir_end], ref });
}

/// Pick the variant matching the user's quality preference from the gathered candidates,
/// or null when there are none (ROD-152). Cap policy:
///   `best`:  highest resolution
///   `worst`: lowest resolution
///   a rung:  the highest variant at or below the rung; if every variant exceeds it, the
///            lowest available (never bump a capped user over their ceiling when we can
///            avoid it, but always return something the source offers, nearest-available).
pub fn selectVariant(variants: []const domain.StreamLink, quality: domain.Quality) ?domain.StreamLink {
    if (variants.len == 0) return null;
    var pick = variants[0];
    for (variants[1..]) |v| {
        if (preferred(v, pick, quality)) pick = v;
    }
    return pick;
}

/// True if candidate `a` beats incumbent `b` for `quality`. A KNOWN resolution always
/// beats an unknown one (null), and two unknowns tie: we never pick a stream on a
/// resolution we can't see over one we can. This is sharpest under a rung cap, where an
/// unknown stream (a BANDWIDTH-only STREAM-INF) could be any bitrate, so treating it as
/// "0p, safely in budget" would hand a capped user the exact firehose the cap prevents.
/// Unknowns are thus a last resort, chosen only when EVERY candidate is unknown. Over
/// known resolutions this is a strict weak order, so the fold yields the winner
/// regardless of arrival order.
fn preferred(a: domain.StreamLink, b: domain.StreamLink, quality: domain.Quality) bool {
    const ra = a.resolution orelse return false; // unknown `a` never beats `b`
    const rb = b.resolution orelse return true; // known `a` beats unknown `b`
    return switch (quality) {
        .best => ra > rb,
        .worst => ra < rb,
        // A rung: compare by cap-rank so a single `>` implements the policy.
        else => qualityRank(ra, quality.cap().?) > qualityRank(rb, quality.cap().?),
    };
}

/// Rank a resolution against a cap so one `>` comparison is the whole cap
/// policy. In-budget variants (≤ cap) score non-negative and rise with
/// resolution → the highest-≤-cap wins. Over-budget variants score negative
/// and rise toward zero as resolution shrinks → the smallest over-budget wins,
/// and any in-budget variant always outranks any over-budget one. i64 so the
/// negated u32 can't overflow.
fn qualityRank(res: u32, cap_px: u32) i64 {
    if (res <= cap_px) return @as(i64, res);
    return -@as(i64, res);
}

test "parseMasterPlaylist: extracts variant URIs and resolutions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const playlist =
        "#EXTM3U\n" ++
        "#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=842x480\n" ++
        "480/index.m3u8\n" ++
        "#EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=1280x720\n" ++
        "720/index.m3u8\n" ++
        "#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1920x1080\n" ++
        "1080/index.m3u8\n";
    const vs = try parseMasterPlaylist(a, playlist);
    try std.testing.expectEqual(@as(usize, 3), vs.len);
    try std.testing.expectEqualStrings("480/index.m3u8", vs[0].url);
    try std.testing.expectEqual(@as(?u32, 480), vs[0].resolution);
    try std.testing.expectEqual(@as(?u32, 720), vs[1].resolution);
    try std.testing.expectEqual(@as(?u32, 1080), vs[2].resolution);
}

test "parseMasterPlaylist: media playlist (no variants) yields empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const media = "#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:9.0,\nseg0.ts\n#EXTINF:9.0,\nseg1.ts\n#EXT-X-ENDLIST\n";
    const vs = try parseMasterPlaylist(a, media);
    try std.testing.expectEqual(@as(usize, 0), vs.len);
}

test "selectVariant: cap policy picks the right rung (ROD-152)" {
    const mk = struct {
        fn v(res: ?u32) domain.StreamLink {
            return .{ .url = "https://cdn.test/v.m3u8", .resolution = res };
        }
    }.v;

    // Empty candidate set → nothing to play.
    try std.testing.expectEqual(@as(?domain.StreamLink, null), selectVariant(&.{}, .best));

    var full = [_]domain.StreamLink{ mk(480), mk(1080), mk(720) };
    // best/worst select by extremum, order-independent.
    try std.testing.expectEqual(@as(?u32, 1080), selectVariant(&full, .best).?.resolution);
    try std.testing.expectEqual(@as(?u32, 480), selectVariant(&full, .worst).?.resolution);
    // Exact rung present → take it.
    try std.testing.expectEqual(@as(?u32, 480), selectVariant(&full, .p480).?.resolution);
    try std.testing.expectEqual(@as(?u32, 720), selectVariant(&full, .p720).?.resolution);
    try std.testing.expectEqual(@as(?u32, 1080), selectVariant(&full, .p1080).?.resolution);

    // Requested rung absent → highest variant at or below it.
    var gap = [_]domain.StreamLink{ mk(480), mk(1080) };
    try std.testing.expectEqual(@as(?u32, 480), selectVariant(&gap, .p720).?.resolution);

    // Every variant exceeds the cap → the smallest available (nearest-available).
    var over = [_]domain.StreamLink{ mk(720), mk(1080) };
    try std.testing.expectEqual(@as(?u32, 720), selectVariant(&over, .p480).?.resolution);

    // A known resolution always beats an unknown (null) one, in *every* mode:
    // we never act on a resolution we can't see. For a rung cap this is the H1
    // fix: an unknown could be any bitrate, so it must not masquerade as a safe
    // in-budget pick and beat a real (if over-budget) 720p.
    var withnull = [_]domain.StreamLink{ mk(null), mk(720) };
    try std.testing.expectEqual(@as(?u32, 720), selectVariant(&withnull, .best).?.resolution);
    try std.testing.expectEqual(@as(?u32, 720), selectVariant(&withnull, .worst).?.resolution);
    try std.testing.expectEqual(@as(?u32, 720), selectVariant(&withnull, .p480).?.resolution);

    // …but when *every* candidate is unknown, we still return one; never error
    // out when a stream actually exists.
    var allnull = [_]domain.StreamLink{ mk(null), mk(null) };
    try std.testing.expect(selectVariant(&allnull, .p720) != null);
}

test "joinUrl: absolute, rooted, and relative refs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = "https://h.example/x/y/master.m3u8";
    try std.testing.expectEqualStrings("https://cdn.other/v.ts", try joinUrl(a, base, "https://cdn.other/v.ts"));
    try std.testing.expectEqualStrings("https://h.example/a/b.ts", try joinUrl(a, base, "/a/b.ts"));
    try std.testing.expectEqualStrings("https://h.example/x/y/720/seg.ts", try joinUrl(a, base, "720/seg.ts"));
}

//! Shared HLS master-playlist parsing + quality-cap selection (ROD-302).
//! Providers fetch the master themselves (CDN headers differ per source) and feed the
//! bytes here; cap policy and variant math live in one place.

const std = @import("std");
const Allocator = std.mem.Allocator;
const domain = @import("../domain.zig");

/// Master playlist entry: variant URI (verbatim, possibly relative) + vertical
/// resolution when STREAM-INF advertised one.
pub const Variant = struct { url: []const u8, resolution: ?u32 = null };

/// Height from `RESOLUTION=WxH` on EXT-X-STREAM-INF; null if absent or malformed.
fn streamInfHeight(inf_line: []const u8) ?u32 {
    const key = "RESOLUTION=";
    const at = std.mem.indexOf(u8, inf_line, key) orelse return null;
    const rest = inf_line[at + key.len ..];
    const x = std.mem.indexOfScalar(u8, rest, 'x') orelse return null;
    var end: usize = x + 1;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    return std.fmt.parseInt(u32, rest[x + 1 .. end], 10) catch null;
}

/// Master playlist: each `#EXT-X-STREAM-INF:` (resolution) paired with the next
/// non-comment URI (verbatim). Network caller joins relatives against the playlist URL.
/// No STREAM-INF → media playlist, empty slice; caller treats the link as one stream.
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

/// Join a possibly-relative m3u8 URI against the playlist URL. Absolute http(s)
/// passes through; `/rooted` keeps scheme+host; else relative to playlist dir.
pub fn joinUrl(arena: Allocator, base: []const u8, ref: []const u8) ![]u8 {
    // Leave `./`/`../` literal: mpv normalizes; we don't resolve here.
    if (std.mem.startsWith(u8, ref, "http://") or std.mem.startsWith(u8, ref, "https://"))
        return arena.dupe(u8, ref);
    const scheme_end = (std.mem.indexOf(u8, base, "://") orelse return error.BadBaseUrl) + 3;
    const host_end = std.mem.indexOfScalarPos(u8, base, scheme_end, '/') orelse base.len;
    if (std.mem.startsWith(u8, ref, "/")) return std.mem.concat(arena, u8, &.{ base[0..host_end], ref });
    const last_slash = std.mem.lastIndexOfScalar(u8, base, '/') orelse host_end;
    const dir_end = if (last_slash >= host_end) last_slash + 1 else host_end;
    return std.mem.concat(arena, u8, &.{ base[0..dir_end], ref });
}

/// Pick by quality preference, or null if none (ROD-152). Cap policy:
///   best / worst: highest / lowest resolution
///   rung: highest ≤ cap; if every variant exceeds it, the lowest available
///         (never invent a ceiling breach; always return something the source offers)
pub fn selectVariant(variants: []const domain.StreamLink, quality: domain.Quality) ?domain.StreamLink {
    if (variants.len == 0) return null;
    var pick = variants[0];
    for (variants[1..]) |v| {
        if (preferred(v, pick, quality)) pick = v;
    }
    return pick;
}

/// Whether candidate `a` beats incumbent `b` for `quality`.
/// Landmine: a KNOWN resolution always beats unknown (null). Under a rung cap, a
/// BANDWIDTH-only STREAM-INF (null res) could be any bitrate; treating it as "0p, in
/// budget" would hand a capped user the firehose the cap prevents. Unknowns are last
/// resort, only when EVERY candidate is unknown. Known-vs-known is a strict weak order
/// (fold is arrival-order independent).
fn preferred(a: domain.StreamLink, b: domain.StreamLink, quality: domain.Quality) bool {
    const ra = a.resolution orelse return false; // unknown `a` never beats `b`
    const rb = b.resolution orelse return true; // known `a` beats unknown `b`
    return switch (quality) {
        .best => ra > rb,
        .worst => ra < rb,
        // Rung: one `>` via qualityRank encodes the whole cap policy.
        else => qualityRank(ra, quality.cap().?) > qualityRank(rb, quality.cap().?),
    };
}

/// Cap rank for a single `>` comparison. ≤ cap: non-negative, rises with res
/// (highest-≤-cap wins). Over budget: negative, rises toward zero as res shrinks
/// (smallest over-budget wins). Any in-budget always outranks any over-budget.
/// i64 so negated u32 cannot overflow.
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

    // Known always beats unknown, every mode (rung-cap landmine: null must not
    // masquerade as safe in-budget and beat a real over-budget 720p).
    var withnull = [_]domain.StreamLink{ mk(null), mk(720) };
    try std.testing.expectEqual(@as(?u32, 720), selectVariant(&withnull, .best).?.resolution);
    try std.testing.expectEqual(@as(?u32, 720), selectVariant(&withnull, .worst).?.resolution);
    try std.testing.expectEqual(@as(?u32, 720), selectVariant(&withnull, .p480).?.resolution);

    // All unknown: still return one (a stream exists; do not error out).
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

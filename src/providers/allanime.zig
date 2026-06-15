//! AllAnime — the first (and currently only) `SourceProvider`.
//!
//! The working recipe — POST not GET (Cloudflare only challenges GET), Apollo
//! *persisted-query* sha256 hashes instead of query strings, and an AES-256-GCM
//! `tobeparsed` blob — was reverse-engineered from anipy-cli (GPL-3.0,
//! https://github.com/sdaqo/anipy-cli) by observing its protocol and
//! reimplemented here in Zig. No code was copied. See ROD-91 / ROD-62 / ROD-55.
//!
//! AllAnime is fragile by nature. Every site-specific fact — endpoint, hashes,
//! referers, the decrypt scheme — is quarantined in this one file behind
//! `source.SourceProvider`. When it dies: replace this file, not the app.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const domain = @import("../domain.zig");
const source = @import("../source.zig");
const log = @import("../log.zig");

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

const API = "https://api.allanime.day/api";
// An old Chrome UA. AllAnime accepts it and it keeps us unremarkable.
const UA = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36";

// Apollo persisted-query hashes — the server identifies each GraphQL op by these
// instead of accepting a raw query string. Captured from anipy-cli's traffic.
const HASH_SEARCH = "a24c500a1b765c68ae1d8dd85174931f661c71369c89b92b88b75a725afc471c";
const HASH_EPISODES = "043448386c7a686bc2aabfbb6b80f6074e795d350df48015023b079527b0848a";
const HASH_VIDEO = "d405d0edd690624b66baba3068e0edc3ac90f1597d898a1ec8db4e5c43c00fec";

// AES-256-GCM key seed for the `tobeparsed` blob (key = sha256(seed)).
const GCM_SEED = "Xot36i3lK3:v1";

// Site origin: base for deciphered provider GETs (ROD-92) and the CDN referer.
const SITE = "https://allanime.day";

// Referers the API / CDN gate on, per operation.
const REFERER_API = "https://allmanga.to/"; // search + episodes + deciphered clock GET
const REFERER_VIDEO = "https://youtu-chan.com/"; // get_video
const STREAM_REFERER = SITE; // mpv → fast4speed CDN

// `extensions` is sent as a JSON *string* whose value is itself JSON, so its
// inner quotes are backslash-escaped. Built at comptime; only the hash varies.
fn extJson(comptime hash: []const u8) []const u8 {
    return "{\\\"persistedQuery\\\":{\\\"version\\\":1,\\\"sha256Hash\\\":\\\"" ++ hash ++ "\\\"}}";
}
const EXT_SEARCH = extJson(HASH_SEARCH);
const EXT_EPISODES = extJson(HASH_EPISODES);
const EXT_VIDEO = extJson(HASH_VIDEO);

/// Provider state. Stateless today, but the struct gives the vtable a real
/// `self` and a home for future config (debug logging, timeouts — ROD-92).
pub const AllAnime = struct {
    /// Stable identity for this source. The persistence layer keys history,
    /// resume, and cache rows on `(source_name, show_id)` — see store.zig.
    pub const source_name = "allanime";

    pub fn init() AllAnime {
        return .{};
    }

    /// Package this concrete provider into the erased `SourceProvider` the app
    /// holds. `self` must outlive every call made through the returned value.
    pub fn provider(self: *AllAnime) source.SourceProvider {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: source.SourceProvider.VTable = .{
        .name = nameErased,
        .search = searchErased,
        .episodes = episodesErased,
        .resolve = resolveErased,
    };

    // ── vtable trampolines: recover the typed self from the erased ptr ──────────
    fn nameErased(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return source_name;
    }
    fn searchErased(ptr: *anyopaque, arena: Allocator, io: Io, query: []const u8, opts: source.SearchOptions) anyerror![]domain.Anime {
        const self: *AllAnime = @ptrCast(@alignCast(ptr));
        return self.search(arena, io, query, opts);
    }
    fn episodesErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation) anyerror![]domain.EpisodeNumber {
        const self: *AllAnime = @ptrCast(@alignCast(ptr));
        return self.episodes(arena, io, show_id, tt);
    }
    fn resolveErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation) anyerror!domain.StreamLink {
        const self: *AllAnime = @ptrCast(@alignCast(ptr));
        return self.resolve(arena, io, show_id, ep, tt);
    }

    // ── search ─────────────────────────────────────────────────────────────────

    const AvailEps = struct { sub: u32 = 0, dub: u32 = 0 };
    const SEdge = struct { _id: []const u8, name: ?[]const u8 = null, availableEpisodes: AvailEps = .{} };
    const SShows = struct { edges: []SEdge };
    const SData = struct { shows: SShows };
    const SResp = struct { data: ?SData = null };

    pub fn search(self: *AllAnime, arena: Allocator, io: Io, query: []const u8, opts: source.SearchOptions) ![]domain.Anime {
        _ = self;
        // For search, `variables` is a plain object (not stringified — that's the
        // quirk that differs per persisted op). Only the query needs escaping.
        // We ask AllAnime for 26 candidates (its own page size) regardless of
        // opts.limit, so the ranking comparator has a full pool to reorder before
        // we trim to opts.limit below.
        const q = try jsonEscape(arena, query);
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"variables\":{{\"search\":{{\"query\":\"{s}\"}},\"limit\":26,\"page\":{d},\"translationType\":\"{s}\",\"countryOrigin\":\"ALL\"}},\"extensions\":\"{s}\"}}",
            .{ q, opts.page, opts.translation.str(), EXT_SEARCH },
        );

        const raw = try post(arena, io, body, REFERER_API);
        const parsed = try std.json.parseFromSlice(SResp, arena, raw, .{ .ignore_unknown_fields = true });
        const data = parsed.value.data orelse return error.NoSearchData;

        var list: std.ArrayList(domain.Anime) = .empty;
        for (data.shows.edges) |e| {
            try list.append(arena, .{
                .id = e._id,
                .name = e.name orelse "(untitled)",
                .eps_sub = e.availableEpisodes.sub,
                .eps_dub = e.availableEpisodes.dub,
            });
        }

        // Rank best-match-first. AllAnime returns rough relevance order; we
        // sharpen it with an explicit title-match score (ROD-60). No `score`
        // field comes back from AllAnime, so episode count is the only tie-break.
        std.mem.sort(domain.Anime, list.items, RankCtx{ .query = query, .tt = opts.translation }, rankGreater);

        if (list.items.len > opts.limit) list.shrinkRetainingCapacity(opts.limit);
        return list.items;
    }

    // ── episodes ─────────────────────────────────────────────────────────────────

    const EpDetail = struct { sub: []const []const u8 = &.{}, dub: []const []const u8 = &.{} };
    const EShow = struct { availableEpisodesDetail: EpDetail = .{} };
    const EData = struct { show: ?EShow = null };
    const EResp = struct { data: ?EData = null };

    pub fn episodes(self: *AllAnime, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation) ![]domain.EpisodeNumber {
        _ = self;
        // `variables` IS a stringified JSON value. The escaping happens twice on
        // purpose: `episodesInner` escapes the id at the *inner* JSON level so it
        // stays valid even with a stray `"`, then we escape the whole thing again
        // for the *outer* string layer.
        const inner = try episodesInner(arena, show_id);
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"variables\":\"{s}\",\"extensions\":\"{s}\"}}",
            .{ try jsonEscape(arena, inner), EXT_EPISODES },
        );

        const raw = try post(arena, io, body, REFERER_API);
        const parsed = try std.json.parseFromSlice(EResp, arena, raw, .{ .ignore_unknown_fields = true });
        const show = (parsed.value.data orelse return error.NoEpisodeData).show orelse return error.ShowNotFound;
        const arr = switch (tt) {
            .sub => show.availableEpisodesDetail.sub,
            .dub => show.availableEpisodesDetail.dub,
        };

        const eps = try arena.alloc(domain.EpisodeNumber, arr.len);
        for (arr, 0..) |e, i| eps[i] = .{ .raw = e };
        std.mem.sort(domain.EpisodeNumber, eps, {}, domain.EpisodeNumber.lessThan);
        return eps;
    }

    // ── resolve ──────────────────────────────────────────────────────────────────

    const VData = struct { tobeparsed: ?[]const u8 = null };
    const VResp = struct { data: ?VData = null };
    const Src = struct { sourceName: ?[]const u8 = null, sourceUrl: ?[]const u8 = null };
    const DecEp = struct { sourceUrls: []Src };
    const Dec = struct { episode: DecEp };

    // anipy's trusted provider allow-list (allanime_provider.py ~237). Only these
    // `sourceName`s are followed — the gate applies to both the fast4speed fast
    // path and the long-tail `--<hex>` providers, exactly as the oracle does.
    const ALLOWED_SOURCES = [_][]const u8{ "Yt-mp4", "S-Mp4", "Uv-mp4", "Ak", "Default" };

    fn sourceAllowed(name: ?[]const u8) bool {
        const n = name orelse return false;
        for (ALLOWED_SOURCES) |a| if (std.mem.eql(u8, n, a)) return true;
        return false;
    }

    pub fn resolve(self: *AllAnime, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation) !domain.StreamLink {
        _ = self;
        // Same two-level escaping as episodes(): `videoInner` escapes show_id and
        // the episode label at the inner JSON level, then jsonEscape wraps the
        // whole inner object for the outer string layer.
        const inner = try videoInner(arena, show_id, tt, ep.raw);
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"variables\":\"{s}\",\"extensions\":\"{s}\"}}",
            .{ try jsonEscape(arena, inner), EXT_VIDEO },
        );

        const raw = try post(arena, io, body, REFERER_VIDEO);
        const parsed = try std.json.parseFromSlice(VResp, arena, raw, .{ .ignore_unknown_fields = true });
        const tbp = (parsed.value.data orelse return error.NoVideoData).tobeparsed orelse return error.NotEncrypted;

        const plain = try decryptTobeparsed(arena, tbp);
        const decoded = try std.json.parseFromSlice(Dec, arena, plain, .{ .ignore_unknown_fields = true });

        const sources = decoded.value.episode.sourceUrls;

        // Fast path: the direct fast4speed CDN URL (no manifest) — the common case
        // for popular shows (it comes from the "Default" source). Return at once.
        for (sources) |s| {
            if (!sourceAllowed(s.sourceName)) continue;
            const url = s.sourceUrl orelse continue;
            if (std.mem.indexOf(u8, url, "tools.fast4speed.rsvp") != null) {
                return .{ .url = url, .resolution = 1080, .referer = STREAM_REFERER };
            }
        }

        // Long-tail (ROD-92): less-popular shows only expose `--<hex>` providers.
        // Decipher each, follow it, and keep the best variant across all of them.
        // One bad provider doesn't sink the rest — followProvider skips on error.
        var best: ?domain.StreamLink = null;
        for (sources) |s| {
            if (!sourceAllowed(s.sourceName)) continue;
            const url = s.sourceUrl orelse continue;
            if (!std.mem.startsWith(u8, url, "--")) continue;
            best = followProvider(arena, io, url[2..], best) catch |e| blk: {
                log.debug("allanime provider {s}: {s}", .{ url, @errorName(e) });
                break :blk best;
            };
        }
        return best orelse error.NoDirectStream;
    }

    // ── internals ────────────────────────────────────────────────────────────────

    /// One POST to the AllAnime GraphQL endpoint. Returns the response body
    /// (lives in `arena`). Errors `HttpNotOk` on any non-200 — the caller maps it.
    fn post(arena: Allocator, io: Io, body: []const u8, referer: []const u8) ![]u8 {
        var client: std.http.Client = .{ .allocator = arena, .io = io };
        defer client.deinit();
        var aw: std.Io.Writer.Allocating = .init(arena);
        const res = try client.fetch(.{
            .location = .{ .url = API },
            .method = .POST,
            .payload = body,
            .response_writer = &aw.writer,
            .headers = .{ .user_agent = .{ .override = UA } },
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Referer", .value = referer },
            },
        });
        if (res.status != .ok) {
            // The caller collapses this to HttpNotOk; keep the real status for a
            // --debug session, where "AllAnime rejected the request" isn't enough.
            log.debug("allanime POST {s}: HTTP {d}", .{ referer, @intFromEnum(res.status) });
            return error.HttpNotOk;
        }
        return aw.writer.buffered();
    }

    /// Hard cap on a long-tail response body. clock JSON and m3u8 manifests are
    /// kilobytes; this bounds memory against a hostile CDN streaming forever (N1).
    const MAX_RESP_BYTES = 4 << 20; // 4 MiB

    /// One GET for the ROD-92 long-tail follow (deciphered clock JSON + m3u8).
    /// Untrusted destination, so: SSRF-guard the URL first, refuse redirects (a
    /// 3xx must not bounce us past the guard), and cap the body. `HttpNotOk` on
    /// any failure — the caller skips the link.
    fn get(arena: Allocator, io: Io, url: []const u8, referer: []const u8) ![]u8 {
        try guardFetchUrl(url);
        var client: std.http.Client = .{ .allocator = arena, .io = io };
        defer client.deinit();
        const buf = try arena.alloc(u8, MAX_RESP_BYTES);
        var w = std.Io.Writer.fixed(buf);
        const res = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &w,
            .redirect_behavior = .not_allowed,
            .headers = .{ .user_agent = .{ .override = UA } },
            .extra_headers = &.{.{ .name = "Referer", .value = referer }},
        }) catch |e| {
            // Covers redirects (refused), oversize body (writer full), and network errors.
            log.debug("allanime GET {s}: {s}", .{ url, @errorName(e) });
            return error.HttpNotOk;
        };
        if (res.status != .ok) {
            log.debug("allanime GET {s}: HTTP {d}", .{ url, @intFromEnum(res.status) });
            return error.HttpNotOk;
        }
        return w.buffered();
    }

    /// SSRF policy for every long-tail fetch. Only plain http(s); no userinfo
    /// (defeats `https://allanime.day@evil/…`); and IP-literal or `localhost`
    /// destinations in private/loopback/link-local space are refused. Paired with
    /// `redirect_behavior=.not_allowed` so a redirect can't bounce past this.
    ///
    /// KNOWN RESIDUAL: a public DNS name whose record points at a private IP
    /// (rebinding) is NOT caught — std's Io net API exposes no pre-connect
    /// resolver to inspect, and the OS resolves inside the client. Closing this
    /// needs resolve-then-connect-to-validated-IP, which the std API doesn't
    /// cleanly allow today. Tracked for follow-up.
    fn guardFetchUrl(url: []const u8) !void {
        const uri = std.Uri.parse(url) catch return error.BadFetchUrl;
        if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return error.BadFetchUrl;
        if (uri.user != null or uri.password != null) return error.BadFetchUrl;
        const hc = uri.host orelse return error.BadFetchUrl;
        const host = switch (hc) { inline else => |h| h };
        if (host.len == 0) return error.BadFetchUrl;
        if (std.ascii.eqlIgnoreCase(host, "localhost") or
            (host.len >= 10 and std.ascii.eqlIgnoreCase(host[host.len - 10 ..], ".localhost")))
            return error.BlockedHost;
        if (parseHostIp(host)) |ip| if (isPrivateIp(ip)) return error.BlockedHost;
    }

    /// Parse a bare IPv4/IPv6 literal host (brackets stripped) into an address.
    /// Null when `host` is a DNS name rather than a literal.
    fn parseHostIp(host: []const u8) ?Io.net.IpAddress {
        const h = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
        return Io.net.IpAddress.parse(h, 0) catch null;
    }

    fn isPrivateIp(ip: Io.net.IpAddress) bool {
        return switch (ip) {
            .ip4 => |a| isPrivateV4(a.bytes),
            .ip6 => |a| isPrivateV6(a.bytes),
        };
    }

    fn isPrivateV4(b: [4]u8) bool {
        return switch (b[0]) {
            0, 10, 127 => true, // this-net, private, loopback
            100 => b[1] >= 64 and b[1] <= 127, // CGNAT 100.64/10
            169 => b[1] == 254, // link-local 169.254/16
            172 => b[1] >= 16 and b[1] <= 31, // private 172.16/12
            192 => b[1] == 168, // private 192.168/16
            else => false,
        };
    }

    fn isPrivateV6(b: [16]u8) bool {
        if (std.mem.allEqual(u8, b[0..15], 0)) return true; // :: (unspecified) and ::1 (loopback)
        if (b[0] == 0xfe and (b[1] & 0xc0) == 0x80) return true; // link-local fe80::/10
        if ((b[0] & 0xfe) == 0xfc) return true; // ULA fc00::/7
        if (std.mem.allEqual(u8, b[0..10], 0) and b[10] == 0xff and b[11] == 0xff)
            return isPrivateV4(.{ b[12], b[13], b[14], b[15] }); // IPv4-mapped ::ffff:a.b.c.d
        return false;
    }

    /// base64-decode then AES-256-GCM-decrypt the `tobeparsed` blob.
    /// Layout of the decoded bytes: [0]=1-byte prefix, [1..13]=nonce,
    /// [13..len-16]=ciphertext, [len-16..]=GCM tag. Key = sha256(GCM_SEED).
    fn decryptTobeparsed(arena: Allocator, tbp: []const u8) ![]u8 {
        var key: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(GCM_SEED, &key, .{});

        const b64 = std.base64.standard.Decoder;
        const raw = try arena.alloc(u8, try b64.calcSizeForSlice(tbp));
        try b64.decode(raw, tbp);
        if (raw.len < 1 + 12 + 16) return error.BlobTooSmall;

        const nonce: [12]u8 = raw[1..][0..12].*;
        const tag: [16]u8 = raw[raw.len - 16 ..][0..16].*;
        const ciphertext = raw[13 .. raw.len - 16];
        const plain = try arena.alloc(u8, ciphertext.len);
        try Aes256Gcm.decrypt(plain, ciphertext, tag, "", nonce, key);
        return plain;
    }

    // ── ROD-92: long-tail provider coverage ──────────────────────────────────────
    // Non-fast4speed sources hand back a `--<hex>` path that must be deciphered,
    // fetched, and parsed into stream variants. Two payload shapes come back: a
    // wixmp `.urlset` (string-split, no manifest) and real m3u8 master playlists.
    // These helpers are pure so the protocol stays unit-testable; the network
    // follow that strings them together lives in `resolve()`.

    /// One resolvable stream variant pulled from a provider payload.
    const Variant = struct { url: []const u8, resolution: ?u32 = null };

    /// Decipher a `--<hex>` provider path. Every hex pair is one byte, XOR-0x38.
    /// anipy-cli wraps that XOR in an `oct()`/`int(_, 8)` round-trip that is a
    /// no-op — verified equal across all 256 byte values — so we drop it. The
    /// caller strips the leading `--` and applies `clock` → `clock.json` after.
    fn decipherProviderPath(arena: Allocator, hex: []const u8) ![]u8 {
        if (hex.len % 2 != 0) return error.BadProviderPath;
        const out = try arena.alloc(u8, hex.len / 2);
        for (out, 0..) |*b, i| {
            const byte = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch return error.BadProviderPath;
            b.* = byte ^ 0x38;
        }
        return out;
    }

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
    /// paired with the URI on the next non-comment line. URIs come back verbatim —
    /// relative ones are joined against the playlist URL by the network caller. A
    /// playlist with no STREAM-INF is already a media playlist (no variants) and
    /// yields an empty slice; the caller then treats the link as one best stream.
    fn parseMasterPlaylist(arena: Allocator, text: []const u8) ![]Variant {
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

    /// Expand a wixmp `repackager` link into its per-quality variants. The link is
    /// `…repackager.wixmp.com/<base>,480p,720p,1080p,<tail>.urlset/…`: take
    /// everything before `.urlset`, splice out the `repackager.wixmp.com/` host,
    /// then comma-split — the first and last parts wrap each middle quality token.
    /// Returns null when `link` is not a wixmp repackager URL.
    fn wixmpVariants(arena: Allocator, link: []const u8) !?[]Variant {
        if (std.mem.indexOf(u8, link, "repackager.wixmp.com") == null) return null;
        const head = link[0 .. (std.mem.indexOf(u8, link, ".urlset") orelse link.len)];
        // Strip the repackager host wherever it appears (global, matching the
        // oracle's `.replace(...)`); the remaining comma list wraps each quality.
        const body = try std.mem.replaceOwned(u8, arena, head, "repackager.wixmp.com/", "");

        var parts: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, body, ',');
        while (it.next()) |p| try parts.append(arena, p);
        if (parts.items.len < 3) return error.BadWixmpUrl; // wrap + ≥1 quality + wrap

        const part_one = parts.items[0];
        const part_two = parts.items[parts.items.len - 1];
        var out: std.ArrayList(Variant) = .empty;
        for (parts.items[1 .. parts.items.len - 1]) |qual| {
            const url = try std.mem.concat(arena, u8, &.{ part_one, qual, part_two });
            const digits = if (qual.len > 0 and qual[qual.len - 1] == 'p') qual[0 .. qual.len - 1] else qual;
            const res = std.fmt.parseInt(u32, digits, 10) catch null;
            try out.append(arena, .{ .url = url, .resolution = res });
        }
        return try out.toOwnedSlice(arena);
    }

    // Shape of the deciphered `clock.json` response: a list of playable links,
    // each optionally carrying the Referer the CDN expects on the follow-up GET.
    const ClkHdr = struct { Referer: ?[]const u8 = null };
    const ClkLink = struct { link: ?[]const u8 = null, headers: ?ClkHdr = null };
    const ClkResp = struct { links: []ClkLink = &.{} };

    /// Insert `.json` after the first `clock` segment of a deciphered path
    /// (`…/clock?id=…` → `…/clock.json?id=…`). Passthrough if absent. First-match
    /// only, like the oracle's `.replace`; real paths are `/apivtwo/clock?…` so
    /// the substring is unambiguous.
    fn clockJson(arena: Allocator, path: []const u8) ![]u8 {
        const at = std.mem.indexOf(u8, path, "clock") orelse return arena.dupe(u8, path);
        const cut = at + "clock".len;
        return std.mem.concat(arena, u8, &.{ path[0..cut], ".json", path[cut..] });
    }

    /// Resolve a possibly-relative m3u8 URI against the playlist URL it came from.
    /// Absolute (`http…`) passes through; `/rooted` keeps scheme+host; otherwise
    /// it's relative to the playlist's directory.
    fn joinUrl(arena: Allocator, base: []const u8, ref: []const u8) ![]u8 {
        // Absolute refs pass through. `./`/`../` segments are left literal — the
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

    /// Keep whichever stream has the higher resolution (null counts as 0). This
    /// is the "default to best" policy — ROD-152's selector layers on top later.
    fn better(cur: ?domain.StreamLink, cand: domain.StreamLink) domain.StreamLink {
        const c = cur orelse return cand;
        return if ((cand.resolution orelse 0) > (c.resolution orelse 0)) cand else c;
    }

    /// True if `s` is safe to place in mpv's argv. Allowlist, not denylist: only
    /// printable ASCII (0x21–0x7e). This rejects CR/LF and other C0/DEL controls
    /// *and* the ≥0x80 line-break-equivalents (NEL, U+2028/9 as UTF-8) and spaces
    /// that a denylist on `< 0x20` would miss — URLs and Referers are ASCII anyway.
    fn cleanArg(s: []const u8) bool {
        for (s) |c| if (c < 0x21 or c > 0x7e) return false;
        return true;
    }

    /// A Referer safe for mpv's argv. The clock.json is fetched from an untrusted
    /// long-tail CDN, so a hostile `headers.Referer` carrying a newline could
    /// inject request headers — the exact hazard player.zig's TODO named. Fall
    /// back to SITE when the value is dirty or absent.
    fn safeReferer(r: ?[]const u8) []const u8 {
        const v = r orelse return SITE;
        return if (cleanArg(v)) v else SITE;
    }

    /// Fold a candidate variant into `best`, dropping anything unsafe for mpv's
    /// argv: the URL must be a clean `http(s)` — no control chars, no leading `--`
    /// that mpv would read as an option. Referer is pre-sanitized by safeReferer.
    fn consider(best: ?domain.StreamLink, url: []const u8, res: ?u32, referer: []const u8) ?domain.StreamLink {
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return best;
        if (!cleanArg(url)) return best;
        return better(best, .{ .url = url, .resolution = res, .referer = referer });
    }

    /// Follow one deciphered `--<hex>` provider to its best stream variant,
    /// folding into `best_in`. Network-bound; the parsers it calls are the tested
    /// part. A failed link is logged and skipped, not fatal — another provider or
    /// link may still yield a stream.
    fn followProvider(arena: Allocator, io: Io, hex_path: []const u8, best_in: ?domain.StreamLink) !?domain.StreamLink {
        var best = best_in;
        const deciphered = try decipherProviderPath(arena, hex_path);
        const path = try clockJson(arena, deciphered);
        // Defense-in-depth for the userinfo SSRF: a path not starting with `/`
        // (e.g. `@evil/x`) would make SITE the authority's userinfo, not the host.
        if (!std.mem.startsWith(u8, path, "/")) return error.BadProviderPath;
        const raw = try get(arena, io, try std.mem.concat(arena, u8, &.{ SITE, path }), REFERER_API);
        const parsed = try std.json.parseFromSlice(ClkResp, arena, raw, .{ .ignore_unknown_fields = true });

        for (parsed.value.links) |l| {
            const link = l.link orelse continue;
            const referer = safeReferer(if (l.headers) |h| h.Referer else null);

            // Shape 1: wixmp repackager — synthetic per-quality URLs, no manifest.
            if (try wixmpVariants(arena, link)) |vs| {
                for (vs) |v| best = consider(best, v.url, v.resolution, STREAM_REFERER);
                continue;
            }

            // Shape 2: a real m3u8. Fetch it (echoing any Referer the link names),
            // then parse the master playlist for variants.
            const body = get(arena, io, link, referer) catch |e| {
                log.debug("allanime m3u8 GET {s}: {s}", .{ link, @errorName(e) });
                continue;
            };
            const vs = try parseMasterPlaylist(arena, body);
            if (vs.len == 0) {
                // No variants → it's already a media playlist; play it directly.
                best = consider(best, link, 1080, referer);
            } else {
                for (vs) |v| best = consider(best, try joinUrl(arena, link, v.url), v.resolution, referer);
            }
        }
        return best;
    }

    // ── ranking ──────────────────────────────────────────────────────────────────

    const RankCtx = struct { query: []const u8, tt: domain.Translation };

    /// Relevance score: a big title-match bonus dominates, with a gentle
    /// log-scaled episode-count nudge to break ties toward the fuller series
    /// (a 28-episode show beats a 1-episode side-story of the same name).
    fn relevance(name: []const u8, query: []const u8, eps: u32) f64 {
        var s: f64 = 0;
        if (std.ascii.eqlIgnoreCase(name, query)) {
            s = 1000;
        } else if (std.ascii.startsWithIgnoreCase(name, query)) {
            s = 500;
        } else if (std.ascii.indexOfIgnoreCase(name, query) != null) {
            s = 250;
        }
        s += std.math.log2(@as(f64, @floatFromInt(eps)) + 2.0);
        return s;
    }

    /// `std.mem.sort` comparator — higher relevance sorts first (descending).
    fn rankGreater(ctx: RankCtx, a: domain.Anime, b: domain.Anime) bool {
        return relevance(a.name, ctx.query, a.episodeCount(ctx.tt)) >
            relevance(b.name, ctx.query, b.episodeCount(ctx.tt));
    }
};

/// Escape a UTF-8 string so it can sit inside a JSON string literal. We hand-roll
/// the request bodies (the persisted-query `extensions` field forces awkward
/// nested escaping that std.json's stringifier won't reproduce verbatim), so any
/// user-supplied text — the search query, mainly — must be escaped or a stray `"`
/// breaks the body. Covers the JSON mandatory escapes; control chars pass through
/// as-is, which is fine for anime titles.
fn jsonEscape(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        else => if (c < 0x20) {
            // RFC 8259 forbids raw control chars in a JSON string — they must be
            // \u-escaped. Below 0x20 the high byte is always 00, so `\u00XX`.
            const hex = "0123456789abcdef";
            try out.appendSlice(arena, "\\u00");
            try out.append(arena, hex[(c >> 4) & 0xf]);
            try out.append(arena, hex[c & 0xf]);
        } else try out.append(arena, c),
    };
    return out.items;
}

/// Build the inner `variables` object for the episodes query, with `show_id`
/// escaped at the inner JSON level. The caller wraps the result in a second
/// `jsonEscape` pass for the outer string layer. Pulled out as a pure function
/// so the escaping is unit-testable without hitting the network.
fn episodesInner(arena: Allocator, show_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"_id\":\"{s}\"}}", .{try jsonEscape(arena, show_id)});
}

/// Build the inner `variables` object for the get_video query, with `show_id`
/// and `episode` escaped at the inner JSON level. `tt` is only ever "sub"/"dub"
/// so it needs no escaping. Same caller contract as `episodesInner`.
fn videoInner(arena: Allocator, show_id: []const u8, tt: domain.Translation, episode: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"showId\":\"{s}\",\"translationType\":\"{s}\",\"episodeString\":\"{s}\"}}",
        .{ try jsonEscape(arena, show_id), tt.str(), try jsonEscape(arena, episode) },
    );
}

test "jsonEscape escapes quotes and backslashes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("a\\\"b", try jsonEscape(a, "a\"b"));
    try std.testing.expectEqualStrings("c\\\\d", try jsonEscape(a, "c\\d"));
    try std.testing.expectEqualStrings("plain", try jsonEscape(a, "plain"));
}

test "jsonEscape: newline, tab, carriage-return, mixed, empty" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try std.testing.expectEqualStrings("a\\nb", try jsonEscape(a, "a\nb"));
    try std.testing.expectEqualStrings("a\\tb", try jsonEscape(a, "a\tb"));
    try std.testing.expectEqualStrings("a\\rb", try jsonEscape(a, "a\rb"));
    // Mixed: all mandatory escapes in one string.
    try std.testing.expectEqualStrings("\\\"\\\\\\n", try jsonEscape(a, "\"\\\n"));
    // Empty input → empty output.
    try std.testing.expectEqualStrings("", try jsonEscape(a, ""));
}

test "jsonEscape: unicode passthrough" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // Multi-byte UTF-8 sequences must pass through untouched.
    try std.testing.expectEqualStrings("フリーレン", try jsonEscape(a, "フリーレン"));
    try std.testing.expectEqualStrings("葬送のフリーレン", try jsonEscape(a, "葬送のフリーレン"));
}

test "relevance: exact > prefix > substring > no match" {
    // Exact match scores highest.
    const exact = AllAnime.relevance("Frieren", "Frieren", 12);
    const prefix = AllAnime.relevance("Frieren: Beyond Journey's End", "Frieren", 12);
    const sub = AllAnime.relevance("The World of Frieren", "Frieren", 12);
    const none = AllAnime.relevance("Naruto", "Frieren", 12);

    try std.testing.expect(exact > prefix);
    try std.testing.expect(prefix > sub);
    try std.testing.expect(sub > none);
    // No match scores below any match.
    try std.testing.expect(none < sub);
}

test "relevance: episode count breaks ties via log2" {
    // Same title-match tier; more episodes should score strictly higher.
    const more = AllAnime.relevance("Frieren", "Frieren", 28);
    const fewer = AllAnime.relevance("Frieren", "Frieren", 1);
    try std.testing.expect(more > fewer);
}

test "relevance: case-insensitive match" {
    // The exact and prefix checks must be case-insensitive.
    const upper = AllAnime.relevance("FRIEREN", "frieren", 1);
    const lower = AllAnime.relevance("frieren", "FRIEREN", 1);
    const mixed = AllAnime.relevance("Frieren", "frIEReN", 1);
    // All three should land in the exact-match bucket (1000 + tiebreak).
    const threshold: f64 = 999;
    try std.testing.expect(upper > threshold);
    try std.testing.expect(lower > threshold);
    try std.testing.expect(mixed > threshold);
}

test "rankGreater: orders anime by descending relevance" {
    // Build two shows where a exactly matches the query and b does not.
    const ctx = AllAnime.RankCtx{ .query = "frieren", .tt = .sub };
    const exact: domain.Anime = .{ .id = "1", .name = "frieren", .eps_sub = 1 };
    const unrelated: domain.Anime = .{ .id = "2", .name = "naruto", .eps_sub = 500 };
    // rankGreater returns true when a should sort before b.
    try std.testing.expect(AllAnime.rankGreater(ctx, exact, unrelated));
    try std.testing.expect(!AllAnime.rankGreater(ctx, unrelated, exact));
}

test "jsonEscape: control characters are \\u-escaped (RFC 8259)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A NUL and a vertical tab (0x0B) must come out as \u00XX, not raw bytes.
    try std.testing.expectEqualStrings("\\u0000", try jsonEscape(a, "\x00"));
    try std.testing.expectEqualStrings("a\\u000bb", try jsonEscape(a, "a\x0bb"));
}

// H1 regression: the inner-body builders must escape ids/labels at the inner
// JSON level. Without this, a `"` in a show id or episode label produced
// structurally-broken JSON that the server silently rejected.
test "episodesInner escapes the show id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("{\"_id\":\"abc\"}", try episodesInner(a, "abc"));
    // A quote in the id is escaped → the inner object stays valid JSON.
    try std.testing.expectEqualStrings("{\"_id\":\"a\\\"b\"}", try episodesInner(a, "a\"b"));
}

test "videoInner escapes show id and episode label" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings(
        "{\"showId\":\"x\",\"translationType\":\"sub\",\"episodeString\":\"1\"}",
        try videoInner(a, "x", .sub, "1"),
    );
    // Quotes in both the id and the episode label are escaped; tt stays literal.
    try std.testing.expectEqualStrings(
        "{\"showId\":\"a\\\"b\",\"translationType\":\"dub\",\"episodeString\":\"1\\\"\"}",
        try videoInner(a, "a\"b", .dub, "1\""),
    );
}

// M1 review (Elara/Astra): a canned AES-256-GCM fixture cements the exact
// `tobeparsed` blob layout — 1-byte prefix, 12-byte nonce, ciphertext, 16-byte
// tag, key = sha256("Xot36i3lK3:v1") — and guards against the server scheme
// drifting silently. Generated offline with Python's `cryptography`.
test "decryptTobeparsed: known blob round-trips to plaintext" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const blob = "AAABAgMEBQYHCAkKCw/k3QdUZIc5wIflWKnNrBJlDJDvuoUtnAhztwaZ0MPdc+7QLkxnnkAqseAyPNsmcPKDx4IlVT/nzzS1VVCzmf7KRsutWoKHB/11G9S8i9qBiKecETa/9Yrge8E1Rv/TJ35g7iREfYhMrh8s";
    const want = "{\"episode\":{\"sourceUrls\":[{\"sourceName\":\"Default\",\"sourceUrl\":\"tools.fast4speed.rsvp/x\"}]}}";
    const got = try AllAnime.decryptTobeparsed(a, blob);
    try std.testing.expectEqualStrings(want, got);
}

// ── ROD-92 ───────────────────────────────────────────────────────────────────

// Golden vector generated from anipy-cli's `_decrypt`. The octal round-trip there
// is a verified no-op (byte^0x38 == anipy across all 256 byte values), so this
// also pins our simplification. Input is the hex *after* stripping the `--`.
test "decipherProviderPath: golden vector matches anipy-cli oracle" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const hex = "175948514e4c4f57175b54575b5307515c056a4d0c405901685b500b486075084c09";
    const want = "/apivtwo/clock?id=Ru4xa9Pch3pXM0t1";
    try std.testing.expectEqualStrings(want, try AllAnime.decipherProviderPath(a, hex));
}

test "decipherProviderPath: rejects odd-length and non-hex input" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectError(error.BadProviderPath, AllAnime.decipherProviderPath(a, "abc"));
    try std.testing.expectError(error.BadProviderPath, AllAnime.decipherProviderPath(a, "zz"));
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
    const vs = try AllAnime.parseMasterPlaylist(a, playlist);
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
    const vs = try AllAnime.parseMasterPlaylist(a, media);
    try std.testing.expectEqual(@as(usize, 0), vs.len);
}

test "wixmpVariants: expands repackager urlset into per-quality streams" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const link = "https://repackager.wixmp.com/video.wixstatic.com/video/abc/,480p,720p,1080p,/mp4/file.mp4.urlset/master.m3u8";
    const vs = (try AllAnime.wixmpVariants(a, link)).?;
    try std.testing.expectEqual(@as(usize, 3), vs.len);
    try std.testing.expectEqualStrings("https://video.wixstatic.com/video/abc/480p/mp4/file.mp4", vs[0].url);
    try std.testing.expectEqual(@as(?u32, 480), vs[0].resolution);
    try std.testing.expectEqual(@as(?u32, 1080), vs[2].resolution);
}

test "wixmpVariants: returns null for non-wixmp links" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqual(@as(?[]AllAnime.Variant, null), try AllAnime.wixmpVariants(a, "https://example.com/x.m3u8"));
}

test "sourceAllowed: only anipy's trusted provider names pass" {
    try std.testing.expect(AllAnime.sourceAllowed("Default"));
    try std.testing.expect(AllAnime.sourceAllowed("Yt-mp4"));
    try std.testing.expect(!AllAnime.sourceAllowed("Sak")); // not in list
    try std.testing.expect(!AllAnime.sourceAllowed(null));
}

test "consider/safeReferer: reject mpv-argv injection (C1)" {
    // A CR/LF-bearing Referer from a hostile clock.json falls back to SITE.
    try std.testing.expectEqualStrings("https://allanime.day", AllAnime.safeReferer("https://x/\r\nEvil: 1"));
    try std.testing.expectEqualStrings("https://ok.test/", AllAnime.safeReferer("https://ok.test/"));
    try std.testing.expectEqualStrings("https://allanime.day", AllAnime.safeReferer(null));
    // A URL with control chars, or one that mpv would read as an option, is dropped.
    try std.testing.expectEqual(@as(?domain.StreamLink, null), AllAnime.consider(null, "https://x/a\nb", 1080, "r"));
    try std.testing.expectEqual(@as(?domain.StreamLink, null), AllAnime.consider(null, "--script=evil.lua", 720, "r"));
    try std.testing.expectEqual(@as(?domain.StreamLink, null), AllAnime.consider(null, "ftp://x/v.ts", 720, "r"));
    // A clean http(s) URL is accepted.
    const ok = AllAnime.consider(null, "https://cdn.test/v.m3u8", 1080, "https://allanime.day").?;
    try std.testing.expectEqualStrings("https://cdn.test/v.m3u8", ok.url);
    try std.testing.expectEqual(@as(?u32, 1080), ok.resolution);
}

test "isPrivateV4: private/loopback/link-local ranges blocked, public allowed" {
    try std.testing.expect(AllAnime.isPrivateV4(.{ 127, 0, 0, 1 }));
    try std.testing.expect(AllAnime.isPrivateV4(.{ 10, 1, 2, 3 }));
    try std.testing.expect(AllAnime.isPrivateV4(.{ 169, 254, 169, 254 })); // cloud metadata
    try std.testing.expect(AllAnime.isPrivateV4(.{ 172, 16, 0, 1 }));
    try std.testing.expect(AllAnime.isPrivateV4(.{ 192, 168, 1, 1 }));
    try std.testing.expect(AllAnime.isPrivateV4(.{ 100, 64, 0, 1 }));
    try std.testing.expect(!AllAnime.isPrivateV4(.{ 8, 8, 8, 8 }));
    try std.testing.expect(!AllAnime.isPrivateV4(.{ 172, 32, 0, 1 }));
    try std.testing.expect(!AllAnime.isPrivateV4(.{ 100, 128, 0, 1 }));
}

test "isPrivateV6: loopback/ULA/link-local/mapped blocked" {
    const loop = [_]u8{0} ** 15 ++ [_]u8{1};
    const unspec = [_]u8{0} ** 16;
    var fe80 = [_]u8{0} ** 16;
    fe80[0] = 0xfe;
    fe80[1] = 0x80;
    var ula = [_]u8{0} ** 16;
    ula[0] = 0xfd;
    const mapped = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1 };
    var pub6 = [_]u8{0} ** 16;
    pub6[0] = 0x20;
    pub6[1] = 0x01; // 2001::
    try std.testing.expect(AllAnime.isPrivateV6(loop));
    try std.testing.expect(AllAnime.isPrivateV6(unspec));
    try std.testing.expect(AllAnime.isPrivateV6(fe80));
    try std.testing.expect(AllAnime.isPrivateV6(ula));
    try std.testing.expect(AllAnime.isPrivateV6(mapped));
    try std.testing.expect(!AllAnime.isPrivateV6(pub6));
}

test "guardFetchUrl: blocks SSRF vectors, allows public http(s)" {
    // userinfo SSRF: allanime.day is userinfo, evil is the real host.
    try std.testing.expectError(error.BadFetchUrl, AllAnime.guardFetchUrl("https://allanime.day@evil.example/x"));
    try std.testing.expectError(error.BadFetchUrl, AllAnime.guardFetchUrl("ftp://x/v.ts")); // non-http scheme
    try std.testing.expectError(error.BlockedHost, AllAnime.guardFetchUrl("http://127.0.0.1/x"));
    try std.testing.expectError(error.BlockedHost, AllAnime.guardFetchUrl("http://169.254.169.254/latest/meta-data/"));
    try std.testing.expectError(error.BlockedHost, AllAnime.guardFetchUrl("http://localhost:8080/admin"));
    try std.testing.expectError(error.BlockedHost, AllAnime.guardFetchUrl("http://[::1]/x"));
    try std.testing.expectError(error.BlockedHost, AllAnime.guardFetchUrl("http://10.0.0.5/x"));
    // public destinations pass.
    try AllAnime.guardFetchUrl("https://cdn.real.example/v.m3u8");
    try AllAnime.guardFetchUrl("https://allanime.day/apivtwo/clock.json?id=x");
}

test "clockJson: inserts .json after the clock segment" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("/apivtwo/clock.json?id=abc", try AllAnime.clockJson(a, "/apivtwo/clock?id=abc"));
    try std.testing.expectEqualStrings("/no/segment/here", try AllAnime.clockJson(a, "/no/segment/here"));
}

test "joinUrl: absolute, rooted, and relative refs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = "https://h.example/x/y/master.m3u8";
    try std.testing.expectEqualStrings("https://cdn.other/v.ts", try AllAnime.joinUrl(a, base, "https://cdn.other/v.ts"));
    try std.testing.expectEqualStrings("https://h.example/a/b.ts", try AllAnime.joinUrl(a, base, "/a/b.ts"));
    try std.testing.expectEqualStrings("https://h.example/x/y/720/seg.ts", try AllAnime.joinUrl(a, base, "720/seg.ts"));
}

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

    /// Human-facing name for user-visible copy. Separate from `source_name`:
    /// that one is the DB key (must never change); this one is for display.
    pub const display_name = "AllAnime";

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
        .displayName = displayNameErased,
        .search = searchErased,
        .episodes = episodesErased,
        .resolve = resolveErased,
    };

    // ── vtable trampolines: recover the typed self from the erased ptr ──────────
    fn nameErased(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return source_name;
    }
    fn displayNameErased(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return display_name;
    }
    fn searchErased(ptr: *anyopaque, arena: Allocator, io: Io, query: []const u8, opts: source.SearchOptions) anyerror![]domain.Anime {
        const self: *AllAnime = @ptrCast(@alignCast(ptr));
        return self.search(arena, io, query, opts);
    }
    fn episodesErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation) anyerror![]domain.EpisodeNumber {
        const self: *AllAnime = @ptrCast(@alignCast(ptr));
        return self.episodes(arena, io, show_id, tt);
    }
    fn resolveErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) anyerror!domain.StreamLink {
        const self: *AllAnime = @ptrCast(@alignCast(ptr));
        return self.resolve(arena, io, show_id, ep, tt, quality);
    }

    // ── search ─────────────────────────────────────────────────────────────────

    const AvailEps = struct { sub: u32 = 0, dub: u32 = 0 };
    // The persisted search op returns far more than the id/name/episodes we
    // historically parsed. We pull every field with a `domain.Anime` home in one
    // pass (ROD-181) so the parser never has to grow again. Two of these directly
    // fix AniList matching — `englishName` (matches AniList's `english` even when
    // its `romaji` uses an unreconcilable "Nth Season" form) and the year (revives
    // the year-weighted scoring branch + sequel tie-break) — and the rest seed the
    // AllAnime-first metadata so the detail pane is populated even when enrichment
    // never lands. `airedStart`/`season` are optional objects; `score` is a 0–10
    // float we rescale to AniList's 0–100 in `edgeToAnime`.
    // `airedStart` carries the real debut date (year+month, sometimes day);
    // `season` carries the broadcast cours (quarter + year). We keep every field
    // the payload sends rather than the bare year — the quarter feeds the season
    // chip and the month feeds the start-date detail row (ROD-140).
    const AiredStart = struct { year: ?u32 = null, month: ?u32 = null, day: ?u32 = null };
    const SeasonObj = struct { quarter: ?[]const u8 = null, year: ?u32 = null };
    const SEdge = struct {
        _id: []const u8,
        name: ?[]const u8 = null,
        englishName: ?[]const u8 = null,
        nativeName: ?[]const u8 = null,
        thumbnail: ?[]const u8 = null,
        type: ?[]const u8 = null,
        score: ?f64 = null,
        availableEpisodes: AvailEps = .{},
        airedStart: ?AiredStart = null,
        season: ?SeasonObj = null,
    };
    const SShows = struct { edges: []SEdge };
    const SData = struct { shows: SShows };
    const SResp = struct { data: ?SData = null };

    /// AllAnime serves most covers straight from AniList's CDN, and the filename
    /// embeds the AniList media id: `…/cover/large/bx182255-hash.jpg` → 182255.
    /// That id is a *deterministic* enrichment join key — strictly better than
    /// fuzzy title matching — so we mine it here (ROD-181). The leading letters
    /// are a size/kind bucket (`b`, `bx`, `n`, `nx`…); the digits are the id.
    /// Returns null for non-AniList thumbnails (~13% are MyAnimeList CDN urls,
    /// whose path is an image id, not a usable anime id) and any unrecognised
    /// shape — the caller then falls back to title matching.
    ///
    /// TRUST: this assumes AllAnime's thumbnail truthfully names the show it
    /// describes. A compromised provider (or a TLS MITM) could embed a wrong-but-
    /// valid id and mis-enrich one row's cover/synopsis. That is the same trust we
    /// already place in AllAnime — it picks the title we'd otherwise match on and
    /// serves the very streams we play — so this widens no boundary; `anilist_id`
    /// is a nullable enrichment column, not a key (store.zig), so there is no
    /// collision/persistence beyond a single row, overwritten on the next enrich.
    fn anilistIdFromThumb(url_opt: ?[]const u8) ?u64 {
        const url = url_opt orelse return null;
        if (std.mem.indexOf(u8, url, "anilistcdn/media/anime/cover/") == null) return null;
        const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return null;
        var i = slash + 1;
        while (i < url.len and std.ascii.isAlphabetic(url[i])) i += 1; // size-bucket prefix
        const start = i;
        while (i < url.len and std.ascii.isDigit(url[i])) i += 1;
        if (i == start) return null;
        return std.fmt.parseInt(u64, url[start..i], 10) catch null;
    }

    /// Map one raw search edge to a `domain.Anime`. String fields borrow the
    /// parsed-JSON slices (caller owns the lifetime); year prefers the actual
    /// debut (`airedStart`) and falls back to the broadcast season's year —
    /// either may be absent (ROD-181).
    fn edgeToAnime(e: SEdge) domain.Anime {
        const aired_year: ?u32 = if (e.airedStart) |a| a.year else null;
        const season_year: ?u32 = if (e.season) |s| s.year else null;
        // Primary-source metadata: fold the quarter to our canonical Season, and
        // keep `airedStart`'s precision as a full debut date (year is required
        // for the date to exist; month/day ride along when present).
        const season: ?domain.Season = if (e.season) |s|
            (if (s.quarter) |q| domain.Season.fromString(q) else null)
        else
            null;
        const start_date: ?domain.Date = if (e.airedStart) |sd|
            (if (sd.year) |y| domain.Date{ .year = y, .month = sd.month, .day = sd.day } else null)
        else
            null;
        // AllAnime scores 0–10 (one or two decimals); AniList — the canonical
        // scale downstream (`averageScore`) — is 0–100. Rescale so a search-seeded
        // score and an enrichment score read on the same axis. Clamp defensively.
        const score: ?u32 = if (e.score) |s| blk: {
            // NaN fails every comparison, so `s <= 0` alone won't reject it, and
            // @intFromFloat is UB on NaN/Inf/out-of-range — guard finiteness first.
            // (0/unrated → null; the @min caps a corrupt over-range score at 100.)
            if (!std.math.isFinite(s) or s <= 0) break :blk null;
            break :blk @intFromFloat(@min(@round(s * 10.0), 100.0));
        } else null;
        return .{
            .id = e._id,
            .name = e.name orelse "(untitled)",
            .english_name = e.englishName,
            .native_name = e.nativeName,
            .thumb = e.thumbnail,
            .anilist_id = anilistIdFromThumb(e.thumbnail),
            .kind = e.type,
            .score = score,
            .eps_sub = e.availableEpisodes.sub,
            .eps_dub = e.availableEpisodes.dub,
            .year = aired_year orelse season_year,
            .season = season,
            .start_date = start_date,
        };
    }

    pub fn search(self: *AllAnime, arena: Allocator, io: Io, query: []const u8, opts: source.SearchOptions) ![]domain.Anime {
        _ = self;
        // For search, `variables` is a plain object (not stringified — that's the
        // quirk that differs per persisted op). Only the query needs escaping.
        // Ask AllAnime for exactly one page (`search_page_size`): the server's page
        // stride then matches the UI's, so `page` always advances by the same count
        // the load-more footer keys off (ROD-201). We rank the returned page below
        // and trim to opts.limit (which workers set to the same constant).
        const q = try jsonEscape(arena, query);
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"variables\":{{\"search\":{{\"query\":\"{s}\"}},\"limit\":{d},\"page\":{d},\"translationType\":\"{s}\",\"countryOrigin\":\"ALL\"}},\"extensions\":\"{s}\"}}",
            .{ q, source.search_page_size, opts.page, opts.translation.str(), EXT_SEARCH },
        );

        const raw = try post(arena, io, body, REFERER_API);
        const parsed = try std.json.parseFromSlice(SResp, arena, raw, .{ .ignore_unknown_fields = true });
        const data = parsed.value.data orelse return error.NoSearchData;

        var list: std.ArrayList(domain.Anime) = .empty;
        for (data.shows.edges) |e| {
            try list.append(arena, edgeToAnime(e));
        }

        // Rank best-match-first. AllAnime returns rough relevance order; we
        // sharpen it with an explicit title-match score (ROD-60), tie-broken on
        // episode count. (AllAnime's own `score` is now parsed for metadata but
        // intentionally not part of the ranking — relevance, not popularity.)
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

    // Match case-insensitively (ROD-178): the oracle's casing doesn't track
    // AllAnime's live responses — the API sends `S-mp4` (lowercase m) where the
    // list carries `S-Mp4`, and an exact match silently dropped that provider,
    // costing long-tail coverage on shows where it was the only viable source.
    fn sourceAllowed(name: ?[]const u8) bool {
        const n = name orelse return false;
        for (ALLOWED_SOURCES) |a| if (std.ascii.eqlIgnoreCase(n, a)) return true;
        return false;
    }

    pub fn resolve(self: *AllAnime, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) !domain.StreamLink {
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
                // The direct path is single-variant 1080p; the quality preference
                // has nothing to pick from here. Log it so a `--debug` session
                // explains why `worst`/`480` look inert on a popular show.
                log.debug("allanime resolve: fast4speed direct 1080p, quality={s} not applicable", .{@tagName(quality)});
                return .{ .url = url, .resolution = 1080, .referer = STREAM_REFERER };
            }
        }

        // Long-tail (ROD-92): less-popular shows only expose `--<hex>` providers.
        // Decipher each, follow it, and gather every safe variant it exposes. One
        // bad provider doesn't sink the rest — followProvider appends what it has
        // and we log the error. The quality pick (ROD-152) happens once, at the
        // end, over the full candidate set — so the cap policy sees every rung
        // across every provider, not a per-provider local best.
        var variants: std.ArrayList(domain.StreamLink) = .empty;
        for (sources) |s| {
            if (!sourceAllowed(s.sourceName)) continue;
            const url = s.sourceUrl orelse continue;
            if (!std.mem.startsWith(u8, url, "--")) continue;
            followProvider(arena, io, url[2..], &variants) catch |e| {
                log.debug("allanime provider {s}: {s}", .{ url, @errorName(e) });
            };
        }
        const pick = selectVariant(variants.items, quality) orelse return error.NoDirectStream;
        // Make the selector observable: how many rungs we had, and which one the
        // preference landed on. This is the receipt that the cap policy actually
        // fired (and the difference between best/worst is real on this source).
        log.debug("allanime resolve: quality={s} picked {?d}p from {d} variant(s)", .{ @tagName(quality), pick.resolution, variants.items.len });
        return pick;
    }

    // ── internals ────────────────────────────────────────────────────────────────

    /// One POST to the AllAnime GraphQL endpoint. Returns the response body
    /// (lives in `arena`). Failures are split into distinct, actionable classes
    /// (ROD-173) so the caller can tell the user whether to retry, wait, or reach
    /// for a VPN, instead of collapsing everything into one signal:
    ///   * `NetworkDown` — timeout / refused / unreachable on our side.
    ///   * `Forbidden`   — 403/451: AllAnime is actively blocking us.
    ///   * `ServerError` — 5xx: the source itself is down.
    ///   * `HttpNotOk`   — any other non-200 (unexpected — the recipe may have drifted).
    fn post(arena: Allocator, io: Io, body: []const u8, referer: []const u8) ![]u8 {
        var client: std.http.Client = .{ .allocator = arena, .io = io };
        defer client.deinit();
        var aw: std.Io.Writer.Allocating = .init(arena);
        const res = client.fetch(.{
            .location = .{ .url = API },
            .method = .POST,
            .payload = body,
            .response_writer = &aw.writer,
            .headers = .{ .user_agent = .{ .override = UA } },
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Referer", .value = referer },
            },
        }) catch |e| return mapTransportError(e, referer);
        if (res.status != .ok) {
            // Keep the real status for a --debug session, where the mapped class
            // ("AllAnime rejected the request") isn't enough; the caller only ever
            // sees the class, not the code.
            log.debug("allanime POST {s}: HTTP {d}", .{ referer, @intFromEnum(res.status) });
            return statusToError(res.status);
        }
        return aw.writer.buffered();
    }

    /// Classify a non-200 status (ROD-173). 403/451 mean we're being blocked; any
    /// 5xx means the source itself is down; everything else stays the
    /// undifferentiated `HttpNotOk` (an unexpected response — likely recipe drift).
    fn statusToError(status: std.http.Status) error{ Forbidden, ServerError, HttpNotOk } {
        return switch (status) {
            .forbidden, .unavailable_for_legal_reasons => error.Forbidden,
            else => switch (status.class()) {
                .server_error => error.ServerError,
                else => error.HttpNotOk,
            },
        };
    }

    /// Map a transport-layer failure from `client.fetch` to `NetworkDown` when
    /// "check your connection" is the right advice. Two distinct families in
    /// std.Io's `FetchError` qualify (they are NOT aliases of each other):
    ///   * IP-level connect failures — refused / reset / host+network
    ///     unreachable / timeout.
    ///   * DNS `HostName.LookupError` — NXDOMAIN, SERVFAIL, malformed records,
    ///     no address returned, unreadable resolv.conf. The ticket calls for DNS
    ///     to land here, and these are their own error values, so they must be
    ///     listed explicitly — an earlier draft wrongly assumed they aliased the
    ///     connect errors.
    /// `TlsInitializationFailed` is included: against our Cloudflare-fronted
    /// upstream it is overwhelmingly a reset/intercepted handshake (a network
    /// condition), though it also absorbs the rare server-side cert-validation
    /// failure — an accepted imprecision over standing up a dedicated TLS class.
    /// Everything else (OOM, protocol, local socket misconfig) propagates
    /// unchanged so we never mislabel it as a dead network.
    fn mapTransportError(e: anyerror, referer: []const u8) anyerror {
        switch (e) {
            // IP-level connect failures.
            error.ConnectionRefused,
            error.ConnectionResetByPeer,
            error.HostUnreachable,
            error.NetworkUnreachable,
            error.NetworkDown,
            error.Timeout,
            error.TlsInitializationFailed,
            // DNS resolution failures (HostName.LookupError).
            error.UnknownHostName,
            error.NameServerFailure,
            error.NoAddressReturned,
            error.ResolvConfParseFailed,
            error.DetectingNetworkConfigurationFailed,
            error.InvalidDnsARecord,
            error.InvalidDnsAAAARecord,
            error.InvalidDnsCnameRecord,
            => {
                log.debug("allanime POST {s}: transport {s} -> NetworkDown", .{ referer, @errorName(e) });
                return error.NetworkDown;
            },
            else => return e,
        }
    }

    /// Hard cap on a long-tail response body. clock JSON and m3u8 manifests are
    /// kilobytes; this bounds memory against a hostile CDN streaming forever (N1).
    const MAX_RESP_BYTES = 4 << 20; // 4 MiB

    /// Wall-clock ceiling for one long-tail GET — connect, headers, and body, end
    /// to end. The payloads here are kilobytes, so this only ever trips on a CDN
    /// that accepts the connection then stalls or dribbles. std's stream reader
    /// exposes no per-read deadline, so `get` bounds the whole fetch by racing it
    /// against a timer and canceling the loser (ROD-153). Without it, one slow host
    /// freezes `resolve`'s sequential provider loop indefinitely; 20 s sits far
    /// above any healthy KB-sized fetch, so a legitimately slow-but-progressing
    /// response is never killed early.
    const FETCH_DEADLINE_S = 20;

    /// One GET for the ROD-92 long-tail follow (deciphered clock JSON + m3u8).
    /// Untrusted destination, so: SSRF-guard the URL first, refuse redirects (a
    /// 3xx must not bounce us past the guard), cap the body, and bound the whole
    /// fetch in wall-clock time (`FETCH_DEADLINE_S`). `HttpNotOk` on any failure —
    /// the caller skips the link.
    fn get(arena: Allocator, io: Io, url: []const u8, referer: []const u8) ![]u8 {
        try guardFetchUrl(url);
        return withDeadline(io, .fromSeconds(FETCH_DEADLINE_S), fetchBody, .{ arena, io, url, referer }) catch |e| {
            if (e == error.Timeout)
                log.debug("allanime GET {s}: aborted past {d}s deadline", .{ url, FETCH_DEADLINE_S });
            return error.HttpNotOk;
        };
    }

    /// The actual long-tail GET, run as a cancelable unit of concurrency by
    /// `withDeadline`. Refuses redirects and caps the body at `MAX_RESP_BYTES`.
    fn fetchBody(arena: Allocator, io: Io, url: []const u8, referer: []const u8) ![]u8 {
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
            // Covers redirects (refused), oversize body (writer full), the deadline
            // cancel (ReadFailed ← Canceled), and ordinary network errors.
            log.debug("allanime GET {s}: {s}", .{ url, @errorName(e) });
            return error.HttpNotOk;
        };
        if (res.status != .ok) {
            log.debug("allanime GET {s}: HTTP {d}", .{ url, @intFromEnum(res.status) });
            return error.HttpNotOk;
        }
        return w.buffered();
    }

    fn DeadlinePayload(comptime Func: type) type {
        return @typeInfo(@typeInfo(Func).@"fn".return_type.?).error_union.payload;
    }

    /// Run `func(args...)`, but abort it if it outlives `deadline`. std offers no
    /// per-read deadline on a socket, so we race the operation against a timer on a
    /// separate unit of concurrency and cancel whichever loses. If the timer wins,
    /// the operation's next cancelation point — the blocked `recv`, which the
    /// Threaded backend interrupts with a signal — returns `error.Canceled`, the
    /// task unwinds (freeing its connection), and we surface `error.Timeout`. If
    /// the runtime can't hand us concurrency (single-threaded build), fall back to
    /// running inline, unbounded — correct, just without the wall-clock ceiling.
    fn withDeadline(
        io: Io,
        deadline: Io.Duration,
        comptime func: anytype,
        args: std.meta.ArgsTuple(@TypeOf(func)),
    ) anyerror!DeadlinePayload(@TypeOf(func)) {
        const Ret = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        const Outcome = union(enum) { done: Ret, timed_out: void };
        var buf: [2]Outcome = undefined;
        var sel: Io.Select(Outcome) = .init(io, &buf);
        sel.concurrent(.done, func, args) catch return @call(.auto, func, args);
        sel.concurrent(.timed_out, sleepTimer, .{ io, deadline }) catch {
            // Timer didn't arm (OOM — the fetch arm already proved concurrency is
            // available). Awaiting the lone fetch here would reintroduce the very
            // unbounded hang this race exists to kill, so cancel it and fall back
            // to the inline, unbounded run instead — same contract as the .done arm.
            while (sel.cancel()) |_| {}
            return @call(.auto, func, args);
        };
        const first = sel.await() catch {
            while (sel.cancel()) |_| {}
            return error.Timeout;
        };
        // await pulled the winner; cancel() requests + joins every loser (looped
        // until null so each task's resources are reclaimed), so by return the
        // canceled fetch has fully unwound — no use of `arena` outlives this frame.
        while (sel.cancel()) |_| {}
        return switch (first) {
            .done => |r| r,
            .timed_out => error.Timeout,
        };
    }

    fn sleepTimer(io: Io, deadline: Io.Duration) void {
        io.sleep(deadline, .awake) catch {}; // .awake = monotonic; cancel → return
    }

    /// SSRF policy for every long-tail fetch. Only plain http(s); no userinfo
    /// (defeats `https://allanime.day@evil/…`); and IP-literal or `localhost`
    /// destinations in private/loopback/link-local space are refused. Paired with
    /// `redirect_behavior=.not_allowed` so a redirect can't bounce past this.
    ///
    /// We validate the *decoded* host (`getHost`/`toRaw`) — the same bytes
    /// std.http resolves against. Reading the raw component would let
    /// `127%2e0%2e0%2e1` slip by as a "hostname" while the client decodes it to
    /// loopback (a guard/client host disagreement — the percent-encode bypass).
    ///
    /// KNOWN RESIDUAL: a public DNS *name* whose record points at a private IP
    /// (DNS rebinding) is still NOT caught — std's Io net API exposes no
    /// pre-connect resolver to inspect, so we can't vet the resolved address
    /// before the client connects. Closing it needs resolve-then-connect-to-a-
    /// validated-IP, which the std API doesn't cleanly allow today. Tracked in
    /// ROD-172. (The body-read wall-clock deadline that used to live here too is
    /// now closed — see `get`/`withDeadline`, ROD-153.)
    fn guardFetchUrl(url: []const u8) !void {
        const uri = std.Uri.parse(url) catch return error.BadFetchUrl;
        if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) return error.BadFetchUrl;
        if (uri.user != null or uri.password != null) return error.BadFetchUrl;
        var host_buf: [Io.net.HostName.max_len]u8 = undefined;
        const host = (uri.getHost(&host_buf) catch return error.BadFetchUrl).bytes;
        if (host.len == 0) return error.BadFetchUrl;
        if (std.ascii.eqlIgnoreCase(host, "localhost") or
            (host.len >= 10 and std.ascii.eqlIgnoreCase(host[host.len - 10 ..], ".localhost")))
            return error.BlockedHost;
        if (parseHostIp(host)) |ip| {
            if (isPrivateIp(ip)) return error.BlockedHost;
        } else {
            // Not a canonical IP literal. std resolves numeric non-canonical forms
            // strictly today (they fail to parse → go to DNS as a bogus name, never
            // loopback), but that's one std change away (the getaddrinfo_a TODO in
            // Threaded.zig). Reject the alternate IP spellings a real host never
            // uses, so they can't become a bypass: any ':' (malformed/compressed
            // IPv6 like `::ffff:7f00:1`) or an all-numeric / `0x`-prefixed IPv4
            // (`2130706433`, `0x7f.0.0.1`, `127.1`). No public hostname looks like
            // these, so there are no false positives.
            if (std.mem.indexOfScalar(u8, host, ':') != null) return error.BlockedHost;
            if (looksNumericHost(host)) return error.BlockedHost;
        }
    }

    /// True if `host` is an alternate (non-dotted-quad) spelling of an IPv4
    /// address: `0x`-prefixed, or every dot-separated label is pure decimal
    /// digits. Only called after `parseHostIp` already rejected it as a canonical
    /// literal, so a genuine public IP like `8.8.8.8` never reaches here.
    fn looksNumericHost(host: []const u8) bool {
        if (host.len >= 2 and host[0] == '0' and (host[1] == 'x' or host[1] == 'X')) return true;
        var it = std.mem.splitScalar(u8, host, '.');
        var any_label = false;
        while (it.next()) |label| {
            if (label.len == 0) continue;
            any_label = true;
            for (label) |c| if (!std.ascii.isDigit(c)) return false;
        }
        return any_label;
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
            else => b[0] >= 224, // multicast 224/4, reserved 240/4, broadcast 255.255.255.255
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
        const head = link[0..(std.mem.indexOf(u8, link, ".urlset") orelse link.len)];
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

    /// Pick the variant matching the user's quality preference from the gathered
    /// candidates, or null when there are none (ROD-152). Cap policy:
    ///   `best`  → highest resolution
    ///   `worst` → lowest resolution
    ///   a rung  → the highest variant *at or below* the rung; if every variant
    ///             exceeds it, the lowest available — we never bump a capped user
    ///             over their ceiling when we can avoid it, but always return
    ///             *something* the source actually offers (nearest-available).
    fn selectVariant(variants: []const domain.StreamLink, quality: domain.Quality) ?domain.StreamLink {
        if (variants.len == 0) return null;
        var pick = variants[0];
        for (variants[1..]) |v| {
            if (preferred(v, pick, quality)) pick = v;
        }
        return pick;
    }

    /// True if candidate `a` beats incumbent `b` for `quality`. A *known*
    /// resolution always beats an unknown one (null), and two unknowns tie — we
    /// never pick a stream on a resolution we can't see over one we can. This
    /// matters most under a rung cap: an unknown stream (a BANDWIDTH-only
    /// STREAM-INF) could be any bitrate, so treating it as "0p, safely in budget"
    /// would hand a capped user the exact firehose the cap exists to prevent.
    /// Unknowns are thus a last resort, chosen only when *every* candidate is
    /// unknown. Over known resolutions this is a strict weak order, so the fold
    /// yields the cap-policy winner regardless of arrival order.
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

    /// Validate a candidate variant into a `StreamLink`, or null if it's unsafe
    /// for mpv's argv: the URL must start with `http(s)://` (which also rejects a
    /// leading `--` mpv would read as an option) and carry only clean argv bytes
    /// (no control chars). Referer is pre-sanitized by safeReferer. The quality
    /// pick is deferred to `selectVariant`; this only guards what's allowed to
    /// *become* a candidate.
    fn consider(url: []const u8, res: ?u32, referer: []const u8) ?domain.StreamLink {
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return null;
        if (!cleanArg(url)) return null;
        return .{ .url = url, .resolution = res, .referer = referer };
    }

    /// Follow one deciphered `--<hex>` provider, appending every safe stream
    /// variant it exposes to `out`. Network-bound; the parsers it calls are the
    /// tested part. A failed *link* is logged and skipped, not fatal — another
    /// link may still yield a stream; a failed *provider* (decipher/path/parse)
    /// errors out, but the variants already appended survive (the caller keeps
    /// the partial set). The quality pick happens later in `selectVariant`.
    fn followProvider(arena: Allocator, io: Io, hex_path: []const u8, out: *std.ArrayList(domain.StreamLink)) !void {
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
                for (vs) |v| {
                    if (consider(v.url, v.resolution, STREAM_REFERER)) |sl| try out.append(arena, sl);
                }
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
                if (consider(link, 1080, referer)) |sl| try out.append(arena, sl);
            } else {
                for (vs) |v| {
                    if (consider(try joinUrl(arena, link, v.url), v.resolution, referer)) |sl| try out.append(arena, sl);
                }
            }
        }
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

test "anilistIdFromThumb: mines the AniList media id from cover urls" {
    const f = AllAnime.anilistIdFromThumb;
    // The three live prefix shapes (size/kind buckets) all yield the digits.
    try std.testing.expectEqual(@as(?u64, 182255), f("https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx182255-butzrqd4I0aC.jpg"));
    try std.testing.expectEqual(@as(?u64, 9203), f("https://s4.anilist.co/file/anilistcdn/media/anime/cover/medium/b9203-Dvr3qxjibGHK.png"));
    try std.testing.expectEqual(@as(?u64, 437), f("https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/nx437-w44gw3LYmLba.jpg"));
    // MyAnimeList CDN (~13% of edges): path is an image id, not a usable anime id.
    try std.testing.expectEqual(@as(?u64, null), f("https://cdn.myanimelist.net/images/anime/10/11244.jpg"));
    // Defensive: null url, and an anilist-shaped path with no digits.
    try std.testing.expectEqual(@as(?u64, null), f(null));
    try std.testing.expectEqual(@as(?u64, null), f("https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx-nope.jpg"));
}

test "edgeToAnime: maps the widened search edge (ROD-181)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Edge 0: full payload incl. anilist-CDN thumb + airedStart year + score.
    // Edge 1: airedStart absent → season.year fallback; MAL thumb → no id.
    // Edge 2: only the required _id (everything else defaulted/absent).
    // Extra unknown fields (episodeDuration, characterCount) must be ignored.
    const json =
        \\{"data":{"shows":{"edges":[
        \\{"_id":"A","name":"Sousou no Frieren Season 2","englishName":"Frieren: Beyond Journey's End Season 2","nativeName":"葬送のフリーレン 第2期","thumbnail":"https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx182255-h.jpg","type":"TV","score":8.88,"availableEpisodes":{"sub":10,"dub":10,"raw":0},"airedStart":{"year":2026,"month":1},"season":{"quarter":"Winter","year":2026},"episodeDuration":"60000","characterCount":"9"},
        \\{"_id":"B","name":"Old Show","thumbnail":"https://cdn.myanimelist.net/images/anime/10/11244.jpg","score":0,"availableEpisodes":{"sub":12,"dub":0},"season":{"quarter":"Fall","year":1998}},
        \\{"_id":"C","availableEpisodes":{"sub":1,"dub":0}}
        \\]}}}
    ;
    const parsed = try std.json.parseFromSlice(AllAnime.SResp, a, json, .{ .ignore_unknown_fields = true });
    const edges = parsed.value.data.?.shows.edges;
    try std.testing.expectEqual(@as(usize, 3), edges.len);

    const f0 = AllAnime.edgeToAnime(edges[0]);
    try std.testing.expectEqualStrings("Sousou no Frieren Season 2", f0.name);
    try std.testing.expectEqualStrings("Frieren: Beyond Journey's End Season 2", f0.english_name.?);
    try std.testing.expectEqualStrings("葬送のフリーレン 第2期", f0.native_name.?);
    try std.testing.expectEqual(@as(?u64, 182255), f0.anilist_id);
    try std.testing.expectEqualStrings("TV", f0.kind.?);
    try std.testing.expectEqual(@as(?u32, 89), f0.score); // 8.88 → round(88.8) → 89
    try std.testing.expectEqual(@as(u32, 10), f0.eps_sub);
    try std.testing.expectEqual(@as(?u32, 2026), f0.year); // airedStart wins
    try std.testing.expectEqual(domain.Season.winter, f0.season.?); // season.quarter
    try std.testing.expectEqual(@as(?u32, 2026), f0.start_date.?.year); // airedStart precision
    try std.testing.expectEqual(@as(?u32, 1), f0.start_date.?.month);
    try std.testing.expectEqual(@as(?u32, null), f0.start_date.?.day); // not in payload

    const f1 = AllAnime.edgeToAnime(edges[1]);
    try std.testing.expectEqual(@as(?u64, null), f1.anilist_id); // MAL thumb
    try std.testing.expectEqual(@as(?u32, 1998), f1.year); // season.year fallback
    try std.testing.expectEqual(@as(?u32, null), f1.score); // score 0 → null
    try std.testing.expectEqual(@as(?[]const u8, null), f1.english_name);
    try std.testing.expectEqual(domain.Season.fall, f1.season.?); // quarter without airedStart
    try std.testing.expectEqual(@as(?domain.Date, null), f1.start_date); // no airedStart → no date

    const f2 = AllAnime.edgeToAnime(edges[2]);
    try std.testing.expectEqualStrings("C", f2.id);
    try std.testing.expectEqualStrings("(untitled)", f2.name);
    try std.testing.expectEqual(@as(?u32, null), f2.year);
    try std.testing.expectEqual(@as(?u64, null), f2.anilist_id);
    try std.testing.expectEqual(@as(?domain.Season, null), f2.season); // bare _id → no season
}

test "edgeToAnime: score rescale clamps over-range and rejects non-finite (ROD-181)" {
    const mk = struct {
        fn score(v: ?f64) ?u32 {
            return AllAnime.edgeToAnime(.{ ._id = "x", .score = v }).score;
        }
    }.score;
    try std.testing.expectEqual(@as(?u32, 89), mk(8.88)); // round(88.8)
    try std.testing.expectEqual(@as(?u32, 100), mk(9.999)); // round(99.99) → 100
    try std.testing.expectEqual(@as(?u32, 100), mk(11.5)); // over-range → clamp
    try std.testing.expectEqual(@as(?u32, 100), mk(999.0)); // absurd → clamp
    try std.testing.expectEqual(@as(?u32, null), mk(0)); // unrated
    try std.testing.expectEqual(@as(?u32, null), mk(-3.0)); // negative
    try std.testing.expectEqual(@as(?u32, null), mk(null)); // absent
    try std.testing.expectEqual(@as(?u32, null), mk(std.math.nan(f64))); // NaN guard
    try std.testing.expectEqual(@as(?u32, null), mk(std.math.inf(f64))); // Inf guard
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

// M1 review: a canned AES-256-GCM fixture cements the exact
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

test "sourceAllowed: case-insensitive match against anipy's trusted names" {
    try std.testing.expect(AllAnime.sourceAllowed("Default"));
    try std.testing.expect(AllAnime.sourceAllowed("Yt-mp4"));
    try std.testing.expect(!AllAnime.sourceAllowed("Sak")); // not in list
    try std.testing.expect(!AllAnime.sourceAllowed(null));
    // ROD-178: the match is case-insensitive. AllAnime sends `S-mp4` (lowercase
    // m) where our list carries `S-Mp4`; an exact match dropped it. Mixed casing
    // on any entry must still pass.
    try std.testing.expect(AllAnime.sourceAllowed("S-mp4")); // the real-world casing
    try std.testing.expect(AllAnime.sourceAllowed("default"));
    try std.testing.expect(AllAnime.sourceAllowed("UV-MP4"));
    try std.testing.expect(!AllAnime.sourceAllowed("S-mp5")); // near-miss: one char off, not a list entry
}

test "consider/safeReferer: reject mpv-argv injection (C1)" {
    // A CR/LF-bearing Referer from a hostile clock.json falls back to SITE.
    try std.testing.expectEqualStrings("https://allanime.day", AllAnime.safeReferer("https://x/\r\nEvil: 1"));
    try std.testing.expectEqualStrings("https://ok.test/", AllAnime.safeReferer("https://ok.test/"));
    try std.testing.expectEqualStrings("https://allanime.day", AllAnime.safeReferer(null));
    // A URL with control chars, or one that mpv would read as an option, is dropped.
    try std.testing.expectEqual(@as(?domain.StreamLink, null), AllAnime.consider("https://x/a\nb", 1080, "r"));
    try std.testing.expectEqual(@as(?domain.StreamLink, null), AllAnime.consider("--script=evil.lua", 720, "r"));
    try std.testing.expectEqual(@as(?domain.StreamLink, null), AllAnime.consider("ftp://x/v.ts", 720, "r"));
    // A clean http(s) URL is accepted.
    const ok = AllAnime.consider("https://cdn.test/v.m3u8", 1080, "https://allanime.day").?;
    try std.testing.expectEqualStrings("https://cdn.test/v.m3u8", ok.url);
    try std.testing.expectEqual(@as(?u32, 1080), ok.resolution);
}

test "selectVariant: cap policy picks the right rung (ROD-152)" {
    const mk = struct {
        fn v(res: ?u32) domain.StreamLink {
            return .{ .url = "https://cdn.test/v.m3u8", .resolution = res };
        }
    }.v;

    // Empty candidate set → nothing to play.
    try std.testing.expectEqual(@as(?domain.StreamLink, null), AllAnime.selectVariant(&.{}, .best));

    var full = [_]domain.StreamLink{ mk(480), mk(1080), mk(720) };
    // best/worst select by extremum, order-independent.
    try std.testing.expectEqual(@as(?u32, 1080), AllAnime.selectVariant(&full, .best).?.resolution);
    try std.testing.expectEqual(@as(?u32, 480), AllAnime.selectVariant(&full, .worst).?.resolution);
    // Exact rung present → take it.
    try std.testing.expectEqual(@as(?u32, 480), AllAnime.selectVariant(&full, .p480).?.resolution);
    try std.testing.expectEqual(@as(?u32, 720), AllAnime.selectVariant(&full, .p720).?.resolution);
    try std.testing.expectEqual(@as(?u32, 1080), AllAnime.selectVariant(&full, .p1080).?.resolution);

    // Requested rung absent → highest variant at or below it.
    var gap = [_]domain.StreamLink{ mk(480), mk(1080) };
    try std.testing.expectEqual(@as(?u32, 480), AllAnime.selectVariant(&gap, .p720).?.resolution);

    // Every variant exceeds the cap → the smallest available (nearest-available).
    var over = [_]domain.StreamLink{ mk(720), mk(1080) };
    try std.testing.expectEqual(@as(?u32, 720), AllAnime.selectVariant(&over, .p480).?.resolution);

    // A known resolution always beats an unknown (null) one, in *every* mode —
    // we never act on a resolution we can't see. For a rung cap this is the H1
    // fix: an unknown could be any bitrate, so it must not masquerade as a safe
    // in-budget pick and beat a real (if over-budget) 720p.
    var withnull = [_]domain.StreamLink{ mk(null), mk(720) };
    try std.testing.expectEqual(@as(?u32, 720), AllAnime.selectVariant(&withnull, .best).?.resolution);
    try std.testing.expectEqual(@as(?u32, 720), AllAnime.selectVariant(&withnull, .worst).?.resolution);
    try std.testing.expectEqual(@as(?u32, 720), AllAnime.selectVariant(&withnull, .p480).?.resolution);

    // …but when *every* candidate is unknown, we still return one — never error
    // out when a stream actually exists.
    var allnull = [_]domain.StreamLink{ mk(null), mk(null) };
    try std.testing.expect(AllAnime.selectVariant(&allnull, .p720) != null);
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
    try AllAnime.guardFetchUrl("http://8.8.8.8/x"); // public IP literal allowed
}

test "guardFetchUrl: percent-encoded host bypass blocked" {
    // Guard must validate the DECODED host, since std.http resolves the decoded form.
    try std.testing.expectError(error.BlockedHost, AllAnime.guardFetchUrl("http://127%2e0%2e0%2e1/x"));
    try std.testing.expectError(error.BlockedHost, AllAnime.guardFetchUrl("http://%6c%6fcalhost:8080/x"));
}

test "guardFetchUrl: alternate IP encodings blocked (defense-in-depth)" {
    try std.testing.expectError(error.BlockedHost, AllAnime.guardFetchUrl("http://2130706433/x")); // decimal 127.0.0.1
    try std.testing.expectError(error.BlockedHost, AllAnime.guardFetchUrl("http://2852039166/latest")); // decimal 169.254.169.254
    try std.testing.expectError(error.BlockedHost, AllAnime.guardFetchUrl("http://0x7f000001/x")); // hex
    try std.testing.expectError(error.BlockedHost, AllAnime.guardFetchUrl("http://0x7f.0.0.1/x"));
    try std.testing.expectError(error.BlockedHost, AllAnime.guardFetchUrl("http://127.1/x")); // short-form
    try std.testing.expectError(error.BlockedHost, AllAnime.guardFetchUrl("http://[::ffff:7f00:1]/x")); // compressed IPv4-mapped
}

test "withDeadline: aborts an operation that outlives the deadline (ROD-153)" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    // Stands in for a stalled fetch: sleeps far past the deadline. The deadline's
    // cancel turns the sleep into error.Canceled, so the task never reaches return.
    const stalled = struct {
        fn run(i: Io) ![]const u8 {
            try i.sleep(Io.Duration.fromSeconds(30), .awake);
            return "unreachable";
        }
    }.run;
    try std.testing.expectError(
        error.Timeout,
        AllAnime.withDeadline(io, Io.Duration.fromMilliseconds(20), stalled, .{io}),
    );
}

test "withDeadline: returns a fast operation's result untouched (ROD-153)" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const quick = struct {
        fn run() ![]const u8 {
            return "ok";
        }
    }.run;
    const out = try AllAnime.withDeadline(io, Io.Duration.fromSeconds(30), quick, .{});
    try std.testing.expectEqualStrings("ok", out);
}

test "withDeadline: propagates a winning operation's error untouched (ROD-153)" {
    // The op losing-or-winning the race must pass its own error through, not have
    // it masked by the deadline machinery — `fetchBody` leans on this to surface
    // HttpNotOk. Here the op finishes (with an error) well inside the deadline.
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const failing = struct {
        fn run() ![]const u8 {
            return error.Boom;
        }
    }.run;
    try std.testing.expectError(
        error.Boom,
        AllAnime.withDeadline(io, Io.Duration.fromSeconds(30), failing, .{}),
    );
}

test "isPrivateV4: multicast and broadcast blocked" {
    try std.testing.expect(AllAnime.isPrivateV4(.{ 224, 0, 0, 1 })); // multicast
    try std.testing.expect(AllAnime.isPrivateV4(.{ 255, 255, 255, 255 })); // broadcast
    try std.testing.expect(!AllAnime.isPrivateV4(.{ 93, 184, 216, 34 })); // public, allowed
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

test "statusToError: blocked / server-down / other split distinctly (ROD-173)" {
    // 403 and 451 are "they're blocking us" — collapse to Forbidden.
    try std.testing.expectEqual(error.Forbidden, AllAnime.statusToError(.forbidden));
    try std.testing.expectEqual(error.Forbidden, AllAnime.statusToError(.unavailable_for_legal_reasons));
    // Every 5xx is "the source is down" — ServerError, by class not by value, so
    // an unnamed 5xx still lands here.
    try std.testing.expectEqual(error.ServerError, AllAnime.statusToError(.internal_server_error));
    try std.testing.expectEqual(error.ServerError, AllAnime.statusToError(.bad_gateway));
    try std.testing.expectEqual(error.ServerError, AllAnime.statusToError(.service_unavailable));
    try std.testing.expectEqual(error.ServerError, AllAnime.statusToError(.gateway_timeout));
    // An unnamed 5xx (Status is non-exhaustive) must still classify by range, not
    // by tag — so a code we don't have a name for still reads as ServerError.
    try std.testing.expectEqual(error.ServerError, AllAnime.statusToError(@enumFromInt(599)));
    // Any other non-200 stays the undifferentiated HttpNotOk (recipe drift, 429…).
    try std.testing.expectEqual(error.HttpNotOk, AllAnime.statusToError(.not_found));
    try std.testing.expectEqual(error.HttpNotOk, AllAnime.statusToError(.bad_request));
    try std.testing.expectEqual(error.HttpNotOk, AllAnime.statusToError(.too_many_requests));
}

test "mapTransportError: connectivity failures become NetworkDown, rest pass through (ROD-173)" {
    // Genuine connectivity problems on our side → NetworkDown.
    try std.testing.expectEqual(error.NetworkDown, AllAnime.mapTransportError(error.ConnectionRefused, "t"));
    try std.testing.expectEqual(error.NetworkDown, AllAnime.mapTransportError(error.ConnectionResetByPeer, "t"));
    try std.testing.expectEqual(error.NetworkDown, AllAnime.mapTransportError(error.HostUnreachable, "t"));
    try std.testing.expectEqual(error.NetworkDown, AllAnime.mapTransportError(error.NetworkUnreachable, "t"));
    try std.testing.expectEqual(error.NetworkDown, AllAnime.mapTransportError(error.NetworkDown, "t"));
    try std.testing.expectEqual(error.NetworkDown, AllAnime.mapTransportError(error.Timeout, "t"));
    try std.testing.expectEqual(error.NetworkDown, AllAnime.mapTransportError(error.TlsInitializationFailed, "t"));
    // DNS resolution failures (HostName.LookupError) are their own error values,
    // not aliases of the connect errors — they must land on NetworkDown too so
    // "name didn't resolve" reads as a connectivity problem, per the ticket.
    try std.testing.expectEqual(error.NetworkDown, AllAnime.mapTransportError(error.UnknownHostName, "t"));
    try std.testing.expectEqual(error.NetworkDown, AllAnime.mapTransportError(error.NameServerFailure, "t"));
    try std.testing.expectEqual(error.NetworkDown, AllAnime.mapTransportError(error.NoAddressReturned, "t"));
    try std.testing.expectEqual(error.NetworkDown, AllAnime.mapTransportError(error.ResolvConfParseFailed, "t"));
    // Anything that isn't a transport failure must not be mislabelled as a dead
    // network — it propagates unchanged.
    try std.testing.expectEqual(error.OutOfMemory, AllAnime.mapTransportError(error.OutOfMemory, "t"));
    try std.testing.expectEqual(error.WriteFailed, AllAnime.mapTransportError(error.WriteFailed, "t"));
}

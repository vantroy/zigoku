//! AllAnime — a `SourceProvider` (senshi is the current default; this one predates it).
//!
//! The working recipe (POST not GET, since Cloudflare only challenges GET; Apollo
//! persisted-query sha256 hashes instead of query strings; an AES-256-GCM `tobeparsed`
//! blob) was reverse-engineered from anipy-cli (GPL-3.0,
//! https://github.com/sdaqo/anipy-cli) by observing its protocol and reimplemented here in
//! Zig. No code was copied. See ROD-91 / ROD-62 / ROD-55.
//!
//! AllAnime is fragile by nature. Every site-specific fact (endpoint, hashes, referers, the
//! decrypt scheme) is quarantined in this one file behind `source.SourceProvider`. When it
//! dies: replace this file, not the app.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const domain = @import("../domain.zig");
const source = @import("../source.zig");
const log = @import("../log.zig");
const http = @import("http.zig");
const hls = @import("hls.zig");
const deadline = @import("../util/deadline.zig");
const fetchguard = @import("../util/fetchguard.zig");

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

// AllAnime serves some covers as a bare, provider-relative `mcovers/…` path with no
// host (others are absolute AniList/MAL urls). This is the image CDN its own
// frontend resolves those against — a pass-through cache, Cloudflare-fronted, that
// 403s a refererless GET. Kept here so the host lives behind the vtable and never
// leaks upstream; a host rotation is a one-line change (ROD-267).
const COVER_CDN_BASE = "https://wp.youtube-anime.com/aln.youtube-anime.com/";

// Sanity cap on a cover ref before it's spliced into a fetch URL — real refs (a
// relative `mcovers/…` path or an absolute cover URL) are far shorter (ROD-267).
const max_cover_ref_len = 2048;

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
        .canonicalKey = canonicalKeyErased,
        .episodes = episodesErased,
        .resolve = resolveErased,
        .coverRequest = coverRequestErased,
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
    fn canonicalKeyErased(ptr: *anyopaque, arena: Allocator, canonical: domain.Anime) anyerror!?[]const u8 {
        _ = ptr;
        _ = arena;
        _ = canonical;
        // AllAnime keys shows by an opaque catalog id, not a canonical MAL/AniList id (its
        // id lives in the cover thumbnail, tier B, out of this resolver's scope), hence null.
        return null;
    }
    fn episodesErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation, count_hint: ?u32) anyerror![]domain.EpisodeNumber {
        const self: *AllAnime = @ptrCast(@alignCast(ptr));
        _ = count_hint; // real listing endpoint; the canonical count plays no part
        return self.episodes(arena, io, show_id, tt);
    }
    fn resolveErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) anyerror!domain.StreamLink {
        const self: *AllAnime = @ptrCast(@alignCast(ptr));
        return self.resolve(arena, io, show_id, ep, tt, quality);
    }
    /// Resolve a stored cover ref into a fetchable request (ROD-267). Absolute refs
    /// (AniList/MAL covers) fetch as-is, no CDN referer needed. A bare relative
    /// `mcovers/…` gets the cover CDN prepended and carries the site referer + our
    /// UA, which the Cloudflare-fronted CDN gates on. `url` is `gpa`-owned.
    fn coverRequestErased(ptr: *anyopaque, gpa: Allocator, ref: []const u8) anyerror!source.CoverRequest {
        _ = ptr;
        // `ref` is untrusted provider data (AllAnime's `thumbnail`) about to be
        // spliced into a URL we fetch. Reject anything that isn't bounded, non-empty,
        // printable-ASCII URL material: a CR/LF or space would let a hostile thumb
        // smuggle a header or a second request onto the wire (ROD-267 review).
        // `cleanArg` is the same printable-ASCII allowlist the mpv-argv path uses.
        // (Host-allowlist / SSRF is a separate layer — ROD-266.)
        if (ref.len == 0 or ref.len > max_cover_ref_len or !cleanArg(ref))
            return error.InvalidCoverRef;
        if (domain.isAbsoluteUrl(ref)) return .{ .url = try gpa.dupe(u8, ref) };
        return .{
            .url = try std.fmt.allocPrint(gpa, "{s}{s}", .{ COVER_CDN_BASE, ref }),
            .referer = SITE,
            .user_agent = UA,
        };
    }

    // ── search ─────────────────────────────────────────────────────────────────

    const AvailEps = struct { sub: u32 = 0, dub: u32 = 0 };
    // The persisted search op returns far more than the id/name/episodes we historically
    // parsed. We pull every field with a `domain.Anime` home in one pass (ROD-181) so the
    // parser never has to grow again. Two directly fix AniList matching: `englishName`
    // (matches AniList's `english` even when its `romaji` uses an unreconcilable "Nth
    // Season" form) and the year (revives year-weighted scoring + sequel tie-break); the
    // rest seed AllAnime-first metadata so the detail pane populates even when enrichment
    // never lands. `airedStart` carries the debut date (year+month, sometimes day) and
    // `season` the broadcast cour (quarter+year), feeding the season chip and start-date
    // row (ROD-140). `score` is a 0-10 float rescaled to AniList's 0-100 in `edgeToAnime`.
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

    /// AllAnime serves most covers from AniList's CDN, and the filename embeds the AniList
    /// media id: `…/cover/large/bx182255-hash.jpg` -> 182255. That id is a deterministic
    /// enrichment join key, strictly better than fuzzy title matching, so we mine it here
    /// (ROD-181). The leading letters are a size/kind bucket (`b`, `bx`, `n`, `nx`…); the
    /// digits are the id. Returns null for non-AniList thumbnails (~13% are MyAnimeList CDN
    /// urls, whose path is an image id, not a usable anime id) and any unrecognised shape,
    /// where the caller falls back to title matching.
    ///
    /// TRUST: this assumes AllAnime's thumbnail truthfully names the show. A compromised
    /// provider (or a TLS MITM) could embed a wrong-but-valid id and mis-enrich one row.
    /// That is the same trust we already place in AllAnime (it picks the title we'd match on
    /// and serves the streams we play), so it widens no boundary; `anilist_id` is a nullable
    /// enrichment column, not a key (store.zig), so a bad id can't collide or persist beyond
    /// a single row, overwritten on the next enrich.
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
        const data = parsed.value.data orelse {
            logGqlReject("search", raw);
            return error.NoSearchData;
        };

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
        const edata = parsed.value.data orelse {
            logGqlReject("episodes", raw);
            return error.NoEpisodeData;
        };
        const show = edata.show orelse return error.ShowNotFound;
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
        const vdata = parsed.value.data orelse {
            logGqlReject("video", raw);
            return error.NoVideoData;
        };
        const tbp = vdata.tobeparsed orelse {
            logGqlReject("video", raw);
            return error.NotEncrypted;
        };

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
        const pick = hls.selectVariant(variants.items, quality) orelse {
            // The video op succeeded (we had sources) but none were playable — a
            // provider/CDN failure, NOT hash rotation. The funnel counts tell the
            // two apart at a glance (ROD-300); this is always-on, unlike the
            // per-provider chatter above.
            log.warn("allanime resolve: no playable variant; {d} source(s) returned, {d} long-tail variant(s) gathered", .{ sources.len, variants.items.len });
            return error.NoDirectStream;
        };
        // Make the selector observable: how many rungs we had, and which one the
        // preference landed on. This is the receipt that the cap policy actually
        // fired (and the difference between best/worst is real on this source).
        log.debug("allanime resolve: quality={s} picked {?d}p from {d} variant(s)", .{ @tagName(quality), pick.resolution, variants.items.len });
        return pick;
    }

    // ── internals ────────────────────────────────────────────────────────────────

    /// Head of a rejected GraphQL body we surface on a `data:null` response.
    /// Bounded because a healthy body runs to kilobytes; the `errors` envelope
    /// sits at the front, so the head is the whole diagnosis.
    const GQL_REJECT_LOG_BYTES = 512;

    /// A GraphQL response with `data == null` means AllAnime accepted the HTTP request (200)
    /// but rejected the OPERATION, the signature of a rotated persisted-query hash, whose
    /// `errors[].message` reads `PersistedQueryNotFound`. That message is the whole diagnosis
    /// and lives only in the body we would otherwise discard. Emit a bounded prefix at `warn`,
    /// always-on and NOT gated behind `--debug` (exactly off when a user first reports
    /// "playback failed", ROD-300). The body is anime metadata with no secrets, safe to log.
    fn logGqlReject(stage: []const u8, raw: []const u8) void {
        const head = raw[0..@min(raw.len, GQL_REJECT_LOG_BYTES)];
        log.warn("allanime {s}: operation rejected (data:null); body head: {s}", .{ stage, head });
    }

    /// One POST to the AllAnime GraphQL endpoint. Returns the response body (in `arena`).
    /// `.ok_only`: the GraphQL endpoint answers 200 on success, so a 2xx-non-200 is
    /// itself a drift signal. Failures split into the ROD-173 classes (see http.zig).
    /// The `tag` is the referer, not "allanime": every call hits the same constant
    /// `API` url, so the referer (allmanga.to = search/episodes, youtu-chan.com =
    /// get_video) is the only thing that tells the two operation families apart in the
    /// log (the url still carries "allanime.day" for greppability).
    fn post(arena: Allocator, io: Io, body: []const u8, referer: []const u8) ![]u8 {
        return http.request(arena, io, .{
            .method = .POST,
            .url = API,
            .payload = body,
            .user_agent = UA,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "Referer", .value = referer },
            },
            .tag = referer,
            .accept = .ok_only,
        });
    }

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
        try fetchguard.guardFetchUrl(url);
        return deadline.withDeadline(io, .fromSeconds(FETCH_DEADLINE_S), fetchBody, .{ arena, io, url, referer }) catch |e| {
            if (e == error.Timeout)
                log.debug("allanime GET {s}: aborted past {d}s deadline", .{ url, FETCH_DEADLINE_S });
            return error.HttpNotOk;
        };
    }

    /// The actual long-tail GET, run as a cancelable unit of concurrency by
    /// `withDeadline`. Refuses redirects and caps the body at `http.MAX_RESP_BYTES`.
    fn fetchBody(arena: Allocator, io: Io, url: []const u8, referer: []const u8) ![]u8 {
        var client: std.http.Client = .{ .allocator = arena, .io = io };
        defer client.deinit();
        const buf = try arena.alloc(u8, http.MAX_RESP_BYTES);
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

    /// Expand a wixmp `repackager` link into its per-quality variants. The link is
    /// `…repackager.wixmp.com/<base>,480p,720p,1080p,<tail>.urlset/…`: take
    /// everything before `.urlset`, splice out the `repackager.wixmp.com/` host,
    /// then comma-split — the first and last parts wrap each middle quality token.
    /// Returns null when `link` is not a wixmp repackager URL.
    fn wixmpVariants(arena: Allocator, link: []const u8) !?[]hls.Variant {
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
        var out: std.ArrayList(hls.Variant) = .empty;
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
            const vs = try hls.parseMasterPlaylist(arena, body);
            if (vs.len == 0) {
                // No variants → it's already a media playlist; play it directly.
                if (consider(link, 1080, referer)) |sl| try out.append(arena, sl);
            } else {
                for (vs) |v| {
                    if (consider(try hls.joinUrl(arena, link, v.url), v.resolution, referer)) |sl| try out.append(arena, sl);
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
    try std.testing.expectEqual(@as(?[]hls.Variant, null), try AllAnime.wixmpVariants(a, "https://example.com/x.m3u8"));
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

test "clockJson: inserts .json after the clock segment" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("/apivtwo/clock.json?id=abc", try AllAnime.clockJson(a, "/apivtwo/clock?id=abc"));
    try std.testing.expectEqualStrings("/no/segment/here", try AllAnime.clockJson(a, "/no/segment/here"));
}

test "coverRequest: absolute refs pass through; relative mcovers get the CDN + referer (ROD-267)" {
    var aa: AllAnime = .{};
    const p = aa.provider();
    const gpa = std.testing.allocator;

    // Absolute AniList/MAL covers fetch as-is — no CDN referer/UA needed.
    {
        const req = try p.coverRequest(gpa, "https://s4.anilist.co/file/x/bx1-abc.jpg");
        defer gpa.free(req.url);
        try std.testing.expectEqualStrings("https://s4.anilist.co/file/x/bx1-abc.jpg", req.url);
        try std.testing.expect(req.referer == null);
        try std.testing.expect(req.user_agent == null);
    }
    // A bare relative `mcovers/…` gets the cover CDN prepended and carries the site
    // referer + our UA, which the Cloudflare-fronted CDN gates on.
    {
        const req = try p.coverRequest(gpa, "mcovers/a_tbs/dhw/B6AMhLy6EQHDgYgBF.webp");
        defer gpa.free(req.url);
        try std.testing.expectEqualStrings(COVER_CDN_BASE ++ "mcovers/a_tbs/dhw/B6AMhLy6EQHDgYgBF.webp", req.url);
        try std.testing.expectEqualStrings(SITE, req.referer.?);
        try std.testing.expectEqualStrings(UA, req.user_agent.?);
    }
}

test "coverRequest rejects control-char / whitespace / empty / oversize refs (ROD-267 review)" {
    var aa: AllAnime = .{};
    const p = aa.provider();
    const gpa = std.testing.allocator;

    // CR/LF header-splitting payload — the core hazard: untrusted thumb bytes must
    // never reach the socket as a smuggled header or second request.
    try std.testing.expectError(error.InvalidCoverRef, p.coverRequest(gpa, "mcovers/x.webp\r\nX-Injected: 1"));
    // An absolute-looking ref with a control char is rejected on that branch too.
    try std.testing.expectError(error.InvalidCoverRef, p.coverRequest(gpa, "https://evil/\r\nHost: x"));
    // Embedded space, empty, and oversize are all junk.
    try std.testing.expectError(error.InvalidCoverRef, p.coverRequest(gpa, "mcovers/a b.webp"));
    try std.testing.expectError(error.InvalidCoverRef, p.coverRequest(gpa, ""));
    try std.testing.expectError(error.InvalidCoverRef, p.coverRequest(gpa, "mcovers/" ++ ("a" ** (max_cover_ref_len + 1))));

    // A clean relative ref still resolves (regression guard).
    const req = try p.coverRequest(gpa, "mcovers/ok.webp");
    defer gpa.free(req.url);
    try std.testing.expect(std.mem.endsWith(u8, req.url, "mcovers/ok.webp"));
}

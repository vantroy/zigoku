//! senshi.live — a `SourceProvider` that replaces the captcha-walled AllAnime (ROD-301;
//! AllAnime bolted a Cloudflare Turnstile gate onto source resolution that a headless CLI
//! can't pass, ROD-300).
//!
//! senshi is far simpler than AllAnime: plain REST JSON on one origin, no persisted-query
//! hashes, no AES-GCM blob, no provider deciphering, and (verified live) no captcha or
//! `cf_clearance` cookie from a raw HTTP client. Everything is keyed by the show's
//! MyAnimeList id, which doubles as our AniSkip key for free.
//!
//! The API surface (reversed on ROD-300/301):
//!   * search / browse → POST /anime/filter  {searchTerm, sortBy, page, limit, …}
//!   * episode list    → GET  /episodes/{mal_id}
//!   * stream resolve  → GET  /episode-embeds/{mal_id}/{ep}
//!   * cover art       → /posters/{mal_id}.webp
//!
//! Every site-specific fact is quarantined here behind the `source.SourceProvider` vtable.
//! Lifting the m3u8/quality machinery out of allanime.zig into a shared module is ROD-302.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const domain = @import("../domain.zig");
const source = @import("../source.zig");
const log = @import("../log.zig");
const http = @import("http.zig");
const hls = @import("hls.zig");
const fetchguard = @import("../util/fetchguard.zig");

const API = "https://senshi.live";
// A current Chrome UA. senshi's Cloudflare edge serves a plain client with this
// UA without a challenge; keep it recent and unremarkable.
const UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

// The stream CDN (ninstream.com) 403s a refererless GET; it gates on this origin.
// Kept here for stage 3's resolve() so the referer lives behind the vtable.
const STREAM_REFERER = "https://senshi.live/";

// Cap on a cover ref before it's spliced into a fetch URL (mirrors AllAnime's
// guard). Real refs are a short `/posters/…webp` path or an absolute cover URL.
const max_cover_ref_len = 2048;

pub const Senshi = struct {
    /// Stable identity used by persistence keys `(source_name, show_id)`. NOTE the
    /// deliberate divergence from AllAnime: senshi keys shows by MAL id, so a user's
    /// old `("allanime", <opaque id>)` history rows do NOT map here — a fresh start
    /// until a migration lands (ROD-301 open item).
    pub const source_name = "senshi";

    /// Human-facing name for user-visible copy (toasts, banners, CLI).
    pub const display_name = "Senshi";

    pub fn init() Senshi {
        return .{};
    }

    /// Pack this concrete provider into the erased `SourceProvider` the app holds.
    /// `self` must outlive every call made through the returned value.
    pub fn provider(self: *Senshi) source.SourceProvider {
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
        const self: *Senshi = @ptrCast(@alignCast(ptr));
        return self.search(arena, io, query, opts);
    }
    fn canonicalKeyErased(ptr: *anyopaque, arena: Allocator, canonical: domain.Anime) anyerror!?[]const u8 {
        _ = ptr;
        // senshi's show handle IS the stringified MAL id (see mapAnime + the /episodes
        // /{mal_id} routes), so a canonical with a MAL id resolves for free. No MAL id →
        // null, and the resolver falls to a title search (tier C, ROD-328).
        const mal = canonical.mal_id orelse return null;
        return try std.fmt.allocPrint(arena, "{d}", .{mal});
    }
    fn episodesErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation, count_hint: ?u32) anyerror![]domain.EpisodeNumber {
        const self: *Senshi = @ptrCast(@alignCast(ptr));
        _ = count_hint; // real listing endpoint; the canonical count plays no part
        return self.episodes(arena, io, show_id, tt);
    }
    fn resolveErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) anyerror!domain.StreamLink {
        const self: *Senshi = @ptrCast(@alignCast(ptr));
        return self.resolve(arena, io, show_id, ep, tt, quality);
    }
    fn coverRequestErased(ptr: *anyopaque, gpa: Allocator, ref: []const u8) anyerror!source.CoverRequest {
        _ = ptr;
        // `ref` is untrusted provider data about to be spliced into a URL we fetch.
        // Reject anything that isn't bounded, non-empty, printable-ASCII URL
        // material — a CR/LF or space could smuggle a header (mirrors ROD-267).
        if (ref.len == 0 or ref.len > max_cover_ref_len or !cleanArg(ref))
            return error.InvalidCoverRef;
        // Absolute refs (rare — some rows may carry a full CDN url) pass through.
        if (domain.isAbsoluteUrl(ref)) return .{ .url = try gpa.dupe(u8, ref) };
        // A senshi-relative `/posters/…webp`: prepend the site host. The poster
        // host serves a plain client without a referer (verified), but we send the
        // site referer + UA anyway — harmless where not gated, correct where it is.
        const sep = if (std.mem.startsWith(u8, ref, "/")) "" else "/";
        return .{
            .url = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ API, sep, ref }),
            .referer = STREAM_REFERER,
            .user_agent = UA,
        };
    }

    // ── the catalog JSON shape ─────────────────────────────────────────────────
    // senshi returns rich, MAL-keyed anime objects from BOTH /anime/filter (as
    // `{data:[…]}`) and /anime/trending/{window} (as a bare array). We pull every
    // field with a `domain.Anime` home in one struct; `ignore_unknown_fields`
    // drops the social/relations/version columns we don't use. `id` is the MAL id
    // (the show handle episodes()/resolve() key on) and is always present.
    const SAnime = struct {
        id: u64,
        title: ?[]const u8 = null,
        title_english: ?[]const u8 = null,
        anime_picture: ?[]const u8 = null,
        type: ?[]const u8 = null,
        ani_source: ?[]const u8 = null,
        ani_episodes: ?[]const u8 = null, // sent as a JSON *string* ("16")
        ani_status: ?[]const u8 = null,
        duration: ?[]const u8 = null, // "23 min per ep"
        score: ?f64 = null, // 0–10
        ani_description: ?[]const u8 = null,
        ani_season: ?[]const u8 = null,
        ani_year: ?u32 = null,
        genres: ?[]const u8 = null, // "Action, Comedy"
        studios: ?[]const u8 = null, // "Lerche, …"
    };
    const FilterResp = struct { data: []SAnime = &.{} };

    /// Map one raw senshi anime object to a `domain.Anime`. String fields borrow
    /// the parsed-JSON slices (caller owns the arena lifetime).
    fn mapAnime(arena: Allocator, s: SAnime) !domain.Anime {
        // 0–10 → AniList's 0–100 axis, so a senshi score and an AniList-enriched
        // score read on the same scale. Guard finiteness (@intFromFloat is UB on
        // NaN/Inf) and clamp a corrupt over-range value.
        const score: ?u32 = if (s.score) |v| blk: {
            if (!std.math.isFinite(v) or v <= 0) break :blk null;
            break :blk @intFromFloat(@min(@round(v * 10.0), 100.0));
        } else null;

        const total_eps: ?u32 = if (s.ani_episodes) |e| parseLeadingUint(u32, e) else null;

        return .{
            // The MAL id, stringified, IS the provider show handle — it must
            // round-trip verbatim into episodes()/resolve().
            .id = try std.fmt.allocPrint(arena, "{d}", .{s.id}),
            .name = s.title orelse "(untitled)",
            .english_name = s.title_english,
            // senshi's `title` is romaji and it has no separate native field.
            .native_name = null,
            .mal_id = s.id, // free AniSkip key — no enrichment round-trip needed.
            .thumb = s.anime_picture,
            .kind = s.type,
            .source_material = s.ani_source,
            .score = score,
            // Catalog data doesn't split sub/dub counts (that's only known at
            // embed time). Surface the total both as `total_episodes` and as the
            // sub count (the dominant track) so ranking/`has(.sub)` behave; real
            // per-track availability lands with resolve (stage 3).
            .eps_sub = total_eps orelse 0,
            .eps_dub = 0,
            .total_episodes = total_eps,
            .duration = if (s.duration) |d| parseLeadingUint(u32, d) else null,
            .year = s.ani_year,
            .season = if (s.ani_season) |q| domain.Season.fromString(q) else null,
            .start_date = if (s.ani_year) |y| domain.Date{ .year = y } else null,
            .status = mapStatus(s.ani_status),
            .description = s.ani_description,
            .genres = try splitCsv(arena, s.genres),
            .studios = try splitCsv(arena, s.studios),
        };
    }

    // ── search ─────────────────────────────────────────────────────────────────

    pub fn search(self: *Senshi, arena: Allocator, io: Io, query: []const u8, opts: source.SearchOptions) ![]domain.Anime {
        _ = self;
        // senshi's server matches `searchTerm` across title/english/synonyms and
        // returns already-relevant results ranked by score — so, unlike AllAnime,
        // we do NOT re-rank on the romaji `name` (the English query would never
        // match it). Trust the server's order; just trim to the caller's limit.
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"searchTerm\":\"{s}\",\"types\":[],\"genres\":[],\"status\":[],\"seasons\":[],\"year\":\"\",\"studios\":[],\"producers\":[],\"languages\":[],\"page\":{d},\"limit\":{d},\"sortBy\":\"score_desc\",\"languagePreference\":\"{s}\"}}",
            .{ try jsonEscape(arena, query), opts.page, source.search_page_size, langPref(opts.translation) },
        );

        const raw = try request(arena, io, .POST, API ++ "/anime/filter", body);
        const parsed = try std.json.parseFromSlice(FilterResp, arena, raw, .{ .ignore_unknown_fields = true });

        var list: std.ArrayList(domain.Anime) = .empty;
        for (parsed.value.data) |s| try list.append(arena, try mapAnime(arena, s));
        if (list.items.len > opts.limit) list.shrinkRetainingCapacity(opts.limit);
        return list.items;
    }

    // ── episodes ──────────────────────────────────────────────────────────────

    /// One senshi episode row. `ep_id` is the episode NUMBER — the value resolve()
    /// feeds into /episode-embeds/{mal_id}/{ep}. senshi also carries the title,
    /// filler/recap flags, and intro/outro skip offsets on this row; the current
    /// `domain.EpisodeNumber` (just a label) can't hold them — surfacing senshi's
    /// built-in skip data to replace the AniSkip round-trip is a ROD-301 follow-up.
    /// Parsed as f64 to tolerate a fractional recap episode (e.g. 13.5).
    const SEp = struct { ep_id: f64 };

    pub fn episodes(self: *Senshi, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation) ![]domain.EpisodeNumber {
        _ = self;
        // senshi's /episodes list is track-agnostic: it lists every episode once,
        // and whether an episode has a sub and/or dub is only known at embed time.
        // So `tt` doesn't filter here — unlike AllAnime, which keyed the list per
        // track. A dub-only episode still lists; resolve() is where a missing dub
        // surfaces (stage 3).
        _ = tt;
        try guardShowId(show_id);
        const url = try std.fmt.allocPrint(arena, API ++ "/episodes/{s}", .{show_id});
        const raw = try request(arena, io, .GET, url, null);
        return parseEpisodes(arena, raw);
    }

    /// Parse the /episodes array into numerically-sorted episode labels. Pure over
    /// the response bytes so it's unit-testable without the network.
    ///
    /// Drops a phantom "episode 0": senshi lists a prologue slot at ep_id 0 for some shows,
    /// but its own /episode-embeds endpoint rejects 0 with 400 "Invalid episode number", so
    /// it is never playable; offering it only lets a user pick a stream that can't resolve,
    /// surfacing as a bare "returned an error" toast (ROD-301).
    fn parseEpisodes(arena: Allocator, raw: []const u8) ![]domain.EpisodeNumber {
        const parsed = try std.json.parseFromSlice([]SEp, arena, raw, .{ .ignore_unknown_fields = true });
        var eps: std.ArrayList(domain.EpisodeNumber) = .empty;
        for (parsed.value) |e| {
            if (e.ep_id == 0) continue; // unplayable prologue slot — see above
            try eps.append(arena, .{ .raw = try epLabel(arena, e.ep_id) });
        }
        std.mem.sort(domain.EpisodeNumber, eps.items, {}, domain.EpisodeNumber.lessThan);
        return eps.items;
    }

    // ── resolve ──────────────────────────────────────────────────────────────────

    /// One embed row from /episode-embeds/{mal_id}/{ep}: a direct HLS master `url`
    /// tagged with a `status` track ("Dub", "HardSub", "SoftSub", "Sub"). `serverFM`
    /// carries a `sub.info=…json` param pointing at the external subtitle sidecar
    /// (ROD-378): the `status` label is unreliable. Some shows tag a soft-sub embed
    /// "HardSub" yet ship no burned-in text, so the subs only render if we follow
    /// that sidecar. The other columns (server2/download/masked_base_url) are ignored.
    const Embed = struct { url: ?[]const u8 = null, status: ?[]const u8 = null, serverFM: ?[]const u8 = null };

    /// One track in the sidecar `sub.info` JSON: a `.vtt` `src`, a `label` ("ENG",
    /// "SDH (JPN)"), and the host's `default` hint (ROD-378).
    const SubTrack = struct { src: ?[]const u8 = null, label: ?[]const u8 = null, default: bool = false };

    pub fn resolve(self: *Senshi, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) !domain.StreamLink {
        _ = self;
        try guardShowId(show_id);
        try guardEpLabel(ep.raw);

        const url = try std.fmt.allocPrint(arena, API ++ "/episode-embeds/{s}/{s}", .{ show_id, ep.raw });
        const raw = try request(arena, io, .GET, url, null);
        const embeds = try std.json.parseFromSlice([]Embed, arena, raw, .{ .ignore_unknown_fields = true });

        const picked = pickEmbed(embeds.value, tt) orelse {
            // Always-on: the show/episode exists but the requested track doesn't —
            // distinct from a network failure, and the receipt says which.
            log.warn("senshi resolve: no {s} stream for show={s} ep={s} ({d} embed(s))", .{ tt.str(), show_id, ep.raw, embeds.value.len });
            return error.NoStreamForTrack;
        };
        const stream = picked.url orelse return error.NoStreamForTrack; // pickEmbed skips null urls
        // The embed url is senshi-provided data about to enter mpv's argv: require
        // an absolute http(s) url carrying only clean argv bytes (no CRLF/space/
        // controls that could smuggle a second mpv option or header).
        if (!domain.isAbsoluteUrl(stream) or !cleanArg(stream)) return error.BadStreamUrl;

        // Honor the quality cap. `.best` is what mpv already picks off the master's
        // bandwidth ladder, so skip the round-trip there; a cap (worst/rung) means
        // fetching the master, reading its variants, and applying the cap policy
        // (shared hls.zig, ROD-302). Best-effort: any failure falls back to the
        // adaptive master, exactly what senshi handed mpv before this landed.
        const chosen = if (quality == .best) stream else capVariant(arena, io, stream, quality) orelse stream;

        // Soft subs ride `link.sub_url` (ROD-354 seam) → mpv `--sub-file`. senshi's
        // `status` label lies (a "HardSub"-tagged embed can carry no burned-in text),
        // so we don't gate on it: for any sub resolve, follow the embed's sidecar and
        // attach the picked .vtt. Best-effort: a null keeps the stream playing raw,
        // exactly the pre-ROD-378 behavior.
        const sub_url = if (tt == .sub) fetchSubtitle(arena, io, picked.serverFM) else null;

        // The stream CDN (ninstream, Cloudflare-fronted) 403s a refererless GET; mpv echoes
        // the referer on the whole HLS chain (master/variant/segments) via
        // --http-header-fields. `user_agent`: the same browser UA the resolver used, part of
        // not tripping the CDN's bot/rate scoring that 403s ffmpeg's default requests (the
        // player also sends keep-alive + drops the Icy-MetaData tell; ROD-309).
        // `cloaked_segments`: senshi serves its `.ts` segments as `.jpg`, so the player must
        // relax ffmpeg's HLS segment-extension gate or nothing plays.
        return .{
            .url = chosen,
            .referer = STREAM_REFERER,
            .user_agent = UA,
            .cloaked_segments = true,
            .sub_url = sub_url,
        };
    }

    /// Follow the picked embed's `serverFM` sidecar to a soft-sub `.vtt` for mpv, or
    /// null to play raw. The sidecar url is host-controlled → it's the same SSRF +
    /// redirect-refuse gate megaplay's probe uses (ROD-266/377) before we fetch it;
    /// the chosen `.vtt` then enters mpv's argv, so it gets the same absolute-url +
    /// clean-arg gate as the stream. Any failure (no sidecar, fetch/parse error,
    /// unsafe url) returns null; the stream still plays.
    fn fetchSubtitle(arena: Allocator, io: Io, server_fm: ?[]const u8) ?[]const u8 {
        const info_url = subInfoUrl(arena, server_fm) orelse return null;
        // info_url is our fetch target (host-controlled): vet its shape, then SSRF-guard.
        if (!domain.isAbsoluteUrl(info_url) or !cleanArg(info_url)) return null;
        fetchguard.guardFetchUrl(info_url) catch return null;
        const body = http.request(arena, io, .{
            .method = .GET,
            .url = info_url,
            .user_agent = UA,
            .extra_headers = &.{.{ .name = "Referer", .value = STREAM_REFERER }},
            .redirect_behavior = .not_allowed,
            .tag = "senshi-sub",
            .accept = .ok_only,
        }) catch return null;
        const tracks = std.json.parseFromSlice([]SubTrack, arena, body, .{ .ignore_unknown_fields = true }) catch return null;
        const src = pickSubTrack(tracks.value) orelse return null;
        // The .vtt goes to mpv argv: absolute http(s) carrying only clean bytes.
        if (!domain.isAbsoluteUrl(src) or !cleanArg(src)) return null;
        return src;
    }

    /// Pull the `sub.info` param out of a `serverFM` embed url and percent-decode it
    /// into the sidecar JSON url. senshi encodes it as e.g.
    /// `…/e/abc/?sub.info=https%3A%2F%2F…%2Fsub_filemoon.json`. Null when the param is
    /// absent (a genuinely burned-in HardSub show carries no sidecar).
    fn subInfoUrl(arena: Allocator, server_fm: ?[]const u8) ?[]const u8 {
        const fm = server_fm orelse return null;
        const key = "sub.info=";
        const at = std.mem.indexOf(u8, fm, key) orelse return null;
        var val = fm[at + key.len ..];
        if (std.mem.indexOfScalar(u8, val, '&')) |amp| val = val[0..amp]; // stop at the next param
        if (val.len == 0) return null;
        return percentDecode(arena, val) catch null;
    }

    /// Choose the one subtitle track to hand mpv, mirroring megaplay's preference:
    /// the host `default` wins, then the first english-labeled track, then the first
    /// track at all. Language/SDH preference beyond that is out of scope (ROD-377).
    fn pickSubTrack(tracks: []const SubTrack) ?[]const u8 {
        var english: ?[]const u8 = null;
        var first: ?[]const u8 = null;
        for (tracks) |t| {
            const src = t.src orelse continue;
            if (t.default) return src;
            if (first == null) first = src;
            const label = t.label orelse continue;
            if (english == null and std.ascii.startsWithIgnoreCase(label, "eng")) english = src;
        }
        return english orelse first;
    }

    /// Percent-decode a URL-query value (`%3A`→`:`, `%2F`→`/`). A malformed escape
    /// (stray `%`, non-hex digit) is kept literal rather than dropped, and a decoded
    /// control byte is caught downstream by `cleanArg`. `+` stays literal: the value
    /// is a raw URL, not form data.
    fn percentDecode(arena: Allocator, s: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < s.len) {
            if (s[i] == '%' and i + 2 < s.len) {
                const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                    try out.append(arena, s[i]);
                    i += 1;
                    continue;
                };
                const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                    try out.append(arena, s[i]);
                    i += 1;
                    continue;
                };
                try out.append(arena, hi * 16 + lo);
                i += 3;
            } else {
                try out.append(arena, s[i]);
                i += 1;
            }
        }
        return out.items;
    }

    /// Fetch the adaptive master and return the variant URL matching the quality cap,
    /// or null when the master can't be fetched/parsed, has no variants, or none
    /// survive the argv-safety gate. Best-effort: resolve() falls back to the master.
    fn capVariant(arena: Allocator, io: Io, master_url: []const u8, quality: domain.Quality) ?[]const u8 {
        // The ninstream CDN 403s a refererless GET (same gate as the segment chain), so
        // send the stream referer + browser UA here, not request()'s JSON/API headers.
        const body = http.request(arena, io, .{
            .method = .GET,
            .url = master_url,
            .user_agent = UA,
            .extra_headers = &.{.{ .name = "Referer", .value = STREAM_REFERER }},
            .tag = "senshi",
            .accept = .ok_only,
        }) catch return null;
        const variants = hls.parseMasterPlaylist(arena, body) catch return null;
        if (variants.len == 0) return null; // already a media playlist: let mpv take the master

        // Build cap-policy candidates: join relative variant URIs against the master
        // and drop any that fail argv safety before they could reach mpv's command line.
        var links: std.ArrayList(domain.StreamLink) = .empty;
        for (variants) |v| {
            const vu = hls.joinUrl(arena, master_url, v.url) catch continue;
            if (!cleanArg(vu)) continue;
            links.append(arena, .{ .url = vu, .resolution = v.resolution }) catch return null;
        }
        const pick = hls.selectVariant(links.items, quality) orelse return null;
        log.debug("senshi resolve: quality={s} picked {?d}p from {d} variant(s)", .{ @tagName(quality), pick.resolution, links.items.len });
        return pick.url;
    }

    /// Choose the embed best matching the requested track. For dub we want the Dub
    /// embed; for sub we prefer a selectable SoftSub, then burned-in HardSub, then any
    /// other subbed variant. Returns the whole embed so the caller can also follow its
    /// `serverFM` sidecar (ROD-378). Null when the track isn't offered at all.
    fn pickEmbed(embeds: []const Embed, tt: domain.Translation) ?Embed {
        var best: ?Embed = null;
        var best_score: u8 = 0;
        for (embeds) |e| {
            if (e.url == null) continue;
            const sc = matchScore(e.status, tt);
            if (sc > best_score) {
                best_score = sc;
                best = e;
            }
        }
        return best;
    }

    /// Rank an embed's `status` for a track (0 = not this track). Sub prefers
    /// soft > hard > any-other-sub so a selectable subtitle track wins over a
    /// burned-in one; a "Dub" is never mistaken for a sub (and vice-versa).
    fn matchScore(status: ?[]const u8, tt: domain.Translation) u8 {
        const s = status orelse return 0;
        return switch (tt) {
            .dub => if (containsIgnoreCase(s, "dub")) 1 else 0,
            .sub => if (containsIgnoreCase(s, "dub"))
                0
            else if (containsIgnoreCase(s, "soft"))
                3
            else if (containsIgnoreCase(s, "hard"))
                2
            else if (containsIgnoreCase(s, "sub"))
                1
            else
                0,
        };
    }

    // ── internals ────────────────────────────────────────────────────────────────
    /// One request to the senshi API. `body` non-null → POST that JSON; null → GET.
    /// senshi is REST-shaped (write endpoints answer 201), so any 2xx is success. The
    /// transport + status error taxonomy lives in the shared http.zig (ROD-349).
    fn request(arena: Allocator, io: Io, method: std.http.Method, url: []const u8, body: ?[]const u8) ![]u8 {
        const extra: []const std.http.Header = if (body != null)
            &.{ .{ .name = "Content-Type", .value = "application/json" }, .{ .name = "Accept", .value = "application/json" } }
        else
            &.{.{ .name = "Accept", .value = "application/json" }};
        return http.request(arena, io, .{
            .method = method,
            .url = url,
            .payload = body,
            .user_agent = UA,
            .extra_headers = extra,
            .tag = "senshi",
        });
    }

    /// senshi's `ani_status` ("Finished Airing"/"Currently Airing"/"Not yet aired")
    /// folded onto the canonical vocab `domain.isStillAiring` settles on — it only
    /// treats an exact `FINISHED`/`CANCELLED` as settled, so a raw "Finished Airing"
    /// would wrongly read as still-airing and never auto-complete (ROD-296).
    fn mapStatus(s: ?[]const u8) ?[]const u8 {
        const v = s orelse return null;
        if (containsIgnoreCase(v, "finished")) return "FINISHED";
        if (containsIgnoreCase(v, "cancel")) return "CANCELLED";
        if (containsIgnoreCase(v, "not yet")) return "NOT_YET_RELEASED";
        if (containsIgnoreCase(v, "airing") or containsIgnoreCase(v, "current")) return "RELEASING";
        return v; // unknown → keep raw; isStillAiring defaults it to safe (airing)
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
    }

    /// languagePreference the filter expects: JP audio = the sub track, EN = dub.
    fn langPref(tt: domain.Translation) []const u8 {
        return switch (tt) {
            .sub => "JP",
            .dub => "EN",
        };
    }

    /// Split senshi's comma-space CSV field ("Action, Comedy") into owned slices.
    /// Null/empty → an empty list. Borrows nothing beyond the arena.
    fn splitCsv(arena: Allocator, csv: ?[]const u8) ![]const []const u8 {
        const s = csv orelse return &.{};
        if (s.len == 0) return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, s, ',');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t");
            if (trimmed.len > 0) try out.append(arena, trimmed);
        }
        return out.items;
    }

    /// Parse the leading run of digits of a string into `T` ("23 min per ep" → 23,
    /// "16" → 16). Null when there's no leading digit.
    fn parseLeadingUint(comptime T: type, s: []const u8) ?T {
        var end: usize = 0;
        while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
        if (end == 0) return null;
        return std.fmt.parseInt(T, s[0..end], 10) catch null;
    }

    /// Format an episode number as its label: an integral value drops the decimal
    /// ("1", "12"), a fractional recap keeps it ("13.5"). The bounded integer path
    /// keeps `@intFromFloat` in range (it's UB out of range); a non-finite value
    /// degrades to "0" rather than trap.
    fn epLabel(arena: Allocator, n: f64) ![]const u8 {
        if (!std.math.isFinite(n)) return arena.dupe(u8, "0");
        if (n >= 0 and n < 1_000_000 and @floor(n) == n)
            return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
        return std.fmt.allocPrint(arena, "{d}", .{n});
    }

    /// senshi keys shows by numeric MAL id, and our stored `Anime.id` is that id
    /// stringified — so a well-formed show id is all digits. Enforce that before
    /// splicing it into a URL path, so a corrupt/hostile id can't smuggle a path
    /// traversal or a second path segment (e.g. `../…`, `1/x`) onto the wire.
    fn guardShowId(show_id: []const u8) !void {
        if (show_id.len == 0) return error.InvalidShowId;
        for (show_id) |c| if (!std.ascii.isDigit(c)) return error.InvalidShowId;
    }

    /// An episode label is our own `epLabel` output — digits with at most one
    /// decimal point ("1", "13.5"). Enforce that before splicing it into the embed
    /// URL path, so a corrupt label can't smuggle a second path segment or a
    /// traversal (`../`, `1/x`) onto the wire.
    fn guardEpLabel(s: []const u8) !void {
        if (s.len == 0) return error.InvalidEpisode;
        var dots: u8 = 0;
        for (s) |c| {
            if (c == '.') {
                dots += 1;
                if (dots > 1) return error.InvalidEpisode;
            } else if (!std.ascii.isDigit(c)) return error.InvalidEpisode;
        }
    }

    /// True if `s` is safe to place in a fetch URL / mpv argv: printable ASCII only
    /// (0x21–0x7e), rejecting CR/LF, spaces and controls. Mirrors AllAnime's guard.
    fn cleanArg(s: []const u8) bool {
        for (s) |c| if (c < 0x21 or c > 0x7e) return false;
        return true;
    }

    /// Escape a UTF-8 string for a JSON string literal — the search query, mainly,
    /// so a stray `"` can't break the hand-rolled request body. Covers the JSON
    /// mandatory escapes; sub-0x20 controls become `\u00XX`.
    fn jsonEscape(arena: Allocator, s: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (s) |c| switch (c) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            else => if (c < 0x20) {
                const hex = "0123456789abcdef";
                try out.appendSlice(arena, "\\u00");
                try out.append(arena, hex[(c >> 4) & 0xf]);
                try out.append(arena, hex[c & 0xf]);
            } else try out.append(arena, c),
        };
        return out.items;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "mapAnime maps a filter row into a domain.Anime (ROD-301)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const row: Senshi.SAnime = .{
        .id = 59708,
        .title = "Youkoso Jitsuryoku Shijou Shugi no Kyoushitsu e 4th Season",
        .title_english = "Classroom of the Elite 4th Season",
        .anime_picture = "/posters/59708.webp",
        .type = "TV",
        .ani_source = "Light novel",
        .ani_episodes = "16",
        .ani_status = "Finished Airing",
        .duration = "23 min per ep",
        .score = 7.88,
        .ani_season = "spring",
        .ani_year = 2026,
        .genres = "Drama, Suspense",
        .studios = "Lerche",
    };
    const m = try Senshi.mapAnime(a, row);

    try testing.expectEqualStrings("59708", m.id); // MAL id, stringified → show handle
    try testing.expectEqual(@as(?u64, 59708), m.mal_id); // free AniSkip key
    try testing.expectEqualStrings("Classroom of the Elite 4th Season", m.english_name.?);
    try testing.expectEqual(@as(?u32, 79), m.score.?); // 7.88*10 → round 79
    try testing.expectEqual(@as(?u32, 16), m.total_episodes.?);
    try testing.expectEqual(@as(u32, 16), m.eps_sub);
    try testing.expectEqual(@as(?u32, 23), m.duration.?);
    try testing.expectEqual(domain.Season.spring, m.season.?);
    try testing.expectEqual(@as(u32, 2026), m.start_date.?.year);
    try testing.expectEqualStrings("FINISHED", m.status.?); // folded from "Finished Airing"
    try testing.expectEqual(@as(usize, 2), m.genres.len);
    try testing.expectEqualStrings("Drama", m.genres[0]);
    try testing.expectEqualStrings("Suspense", m.genres[1]);
}

test "mapStatus folds senshi wording onto the canonical airing vocab (ROD-296)" {
    // The whole point: isStillAiring must settle a finished show, and keep an
    // airing one airing, off senshi's prose.
    try testing.expectEqualStrings("FINISHED", Senshi.mapStatus("Finished Airing").?);
    try testing.expect(!domain.isStillAiring(Senshi.mapStatus("Finished Airing")));
    try testing.expectEqualStrings("RELEASING", Senshi.mapStatus("Currently Airing").?);
    try testing.expect(domain.isStillAiring(Senshi.mapStatus("Currently Airing")));
    try testing.expectEqualStrings("NOT_YET_RELEASED", Senshi.mapStatus("Not yet aired").?);
    try testing.expect(Senshi.mapStatus(null) == null);
}

test "splitCsv splits comma-space lists and drops blanks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const g = try Senshi.splitCsv(a, "Action, Comedy, Fantasy");
    try testing.expectEqual(@as(usize, 3), g.len);
    try testing.expectEqualStrings("Action", g[0]);
    try testing.expectEqualStrings("Fantasy", g[2]);
    try testing.expectEqual(@as(usize, 0), (try Senshi.splitCsv(a, null)).len);
    try testing.expectEqual(@as(usize, 0), (try Senshi.splitCsv(a, "")).len);
}

test "parseLeadingUint takes the digit prefix only" {
    try testing.expectEqual(@as(?u32, 23), Senshi.parseLeadingUint(u32, "23 min per ep"));
    try testing.expectEqual(@as(?u32, 16), Senshi.parseLeadingUint(u32, "16"));
    try testing.expect(Senshi.parseLeadingUint(u32, "unknown") == null);
    try testing.expect(Senshi.parseLeadingUint(u32, "") == null);
}

test "jsonEscape escapes quotes and backslashes for the search body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("a\\\"b", try Senshi.jsonEscape(a, "a\"b"));
    try testing.expectEqualStrings("c\\\\d", try Senshi.jsonEscape(a, "c\\d"));
    try testing.expectEqualStrings("plain", try Senshi.jsonEscape(a, "plain"));
}

test "parseEpisodes maps ep_id to numerically-sorted labels (ROD-301)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Out-of-order, with the extra columns senshi sends that we ignore, and a
    // "10" that must sort after "2" numerically (not lexically).
    const raw =
        \\[{"ep_id":3,"ep_title":"c","ep_filler":false,"intro_start":null},
        \\ {"ep_id":0,"ep_title":"Gray Phantom"},
        \\ {"ep_id":1,"ep_title":"a"},
        \\ {"ep_id":10,"ep_title":"j"},
        \\ {"ep_id":2,"ep_title":"b"}]
    ;
    const eps = try Senshi.parseEpisodes(a, raw);
    try testing.expectEqual(@as(usize, 4), eps.len); // the phantom ep 0 is dropped
    try testing.expectEqualStrings("1", eps[0].raw); // first playable episode, not "0"
    try testing.expectEqualStrings("2", eps[1].raw);
    try testing.expectEqualStrings("3", eps[2].raw);
    try testing.expectEqualStrings("10", eps[3].raw); // numeric, not lexical
}

test "epLabel: integral drops the decimal, fractional keeps it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("1", try Senshi.epLabel(a, 1.0));
    try testing.expectEqualStrings("12", try Senshi.epLabel(a, 12.0));
    try testing.expectEqualStrings("13.5", try Senshi.epLabel(a, 13.5));
    try testing.expectEqualStrings("0", try Senshi.epLabel(a, std.math.inf(f64))); // defensive
}

test "guardShowId accepts a numeric MAL id, rejects traversal/injection" {
    try Senshi.guardShowId("59708");
    try testing.expectError(error.InvalidShowId, Senshi.guardShowId(""));
    try testing.expectError(error.InvalidShowId, Senshi.guardShowId("../etc"));
    try testing.expectError(error.InvalidShowId, Senshi.guardShowId("59708/x"));
    try testing.expectError(error.InvalidShowId, Senshi.guardShowId("dsd8y")); // public_id, not our key
}

test "pickEmbed picks the right track and prefers soft subs (ROD-301)" {
    const embeds = [_]Senshi.Embed{
        .{ .url = "https://cdn/dub.m3u8", .status = "Dub" },
        .{ .url = "https://cdn/hard.m3u8", .status = "HardSub" },
        .{ .url = "https://cdn/soft.m3u8", .status = "SoftSub" },
    };
    // sub → SoftSub wins over HardSub; dub → the Dub embed.
    try testing.expectEqualStrings("https://cdn/soft.m3u8", Senshi.pickEmbed(&embeds, .sub).?.url.?);
    try testing.expectEqualStrings("https://cdn/dub.m3u8", Senshi.pickEmbed(&embeds, .dub).?.url.?);

    // A sub-only show offers no dub → null (resolve turns this into a clear error).
    const sub_only = [_]Senshi.Embed{.{ .url = "https://cdn/hard.m3u8", .status = "HardSub" }};
    try testing.expect(Senshi.pickEmbed(&sub_only, .dub) == null);
    try testing.expectEqualStrings("https://cdn/hard.m3u8", Senshi.pickEmbed(&sub_only, .sub).?.url.?);

    // An embed with no url is skipped, not chosen.
    const no_url = [_]Senshi.Embed{.{ .url = null, .status = "SoftSub" }};
    try testing.expect(Senshi.pickEmbed(&no_url, .sub) == null);
}

test "matchScore never crosses sub and dub" {
    try testing.expectEqual(@as(u8, 0), Senshi.matchScore("Dub", .sub));
    try testing.expectEqual(@as(u8, 0), Senshi.matchScore("HardSub", .dub));
    try testing.expectEqual(@as(u8, 0), Senshi.matchScore("Raw", .sub));
    try testing.expectEqual(@as(u8, 0), Senshi.matchScore(null, .sub));
    try testing.expect(Senshi.matchScore("SoftSub", .sub) > Senshi.matchScore("HardSub", .sub));
}

test "subInfoUrl decodes the sidecar url, null when absent (ROD-378)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The live serverFM shape: a filemoon embed url carrying an encoded sub.info.
    const fm = "https://host.example/e/abc123/?sub.info=https%3A%2F%2Fninstream.com%2Fx%2Fsub_filemoon.json";
    try testing.expectEqualStrings("https://ninstream.com/x/sub_filemoon.json", Senshi.subInfoUrl(a, fm).?);

    // A trailing param after sub.info is trimmed at the &.
    const fm2 = "https://host.example/e/abc/?sub.info=https%3A%2F%2Fc%2Fs.json&t=9";
    try testing.expectEqualStrings("https://c/s.json", Senshi.subInfoUrl(a, fm2).?);

    // A genuinely burned-in HardSub embed has no sub.info → no sidecar.
    try testing.expect(Senshi.subInfoUrl(a, "https://host.example/d/xyz") == null);
    try testing.expect(Senshi.subInfoUrl(a, null) == null);
}

test "pickSubTrack: default wins, english next, first as fallback (ROD-378)" {
    const eng: Senshi.SubTrack = .{ .src = "https://c/eng.vtt", .label = "ENG", .default = true };
    const jpn: Senshi.SubTrack = .{ .src = "https://c/jpn.vtt", .label = "SDH (JPN)" };
    // The live Yani shape: ENG default over the SDH (JPN) track.
    try testing.expectEqualStrings("https://c/eng.vtt", Senshi.pickSubTrack(&.{ eng, jpn }).?);

    // No default: english label wins over an earlier non-english track.
    const spa: Senshi.SubTrack = .{ .src = "https://c/spa.vtt", .label = "Spanish" };
    const eng2: Senshi.SubTrack = .{ .src = "https://c/eng2.vtt", .label = "English" };
    try testing.expectEqualStrings("https://c/eng2.vtt", Senshi.pickSubTrack(&.{ spa, eng2 }).?);

    // No default, no english: the first track with a src.
    const bare: Senshi.SubTrack = .{ .src = "https://c/bare.vtt" };
    try testing.expectEqualStrings("https://c/spa.vtt", Senshi.pickSubTrack(&.{ spa, bare }).?);

    // A src-less track is skipped; an empty list yields null.
    try testing.expectEqualStrings("https://c/bare.vtt", Senshi.pickSubTrack(&.{ .{ .label = "ENG" }, bare }).?);
    try testing.expect(Senshi.pickSubTrack(&.{}) == null);
}

test "percentDecode: escapes decode, malformed stays literal (ROD-378)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("://", try Senshi.percentDecode(a, "%3A%2F%2F"));
    try testing.expectEqualStrings("a b", try Senshi.percentDecode(a, "a%20b"));
    try testing.expectEqualStrings("plain", try Senshi.percentDecode(a, "plain"));
    // A stray or truncated % is preserved, not silently eaten.
    try testing.expectEqualStrings("100%", try Senshi.percentDecode(a, "100%"));
    try testing.expectEqualStrings("%zz", try Senshi.percentDecode(a, "%zz"));
    // A literal + is not treated as a space (this is a URL, not form data).
    try testing.expectEqualStrings("a+b", try Senshi.percentDecode(a, "a+b"));
}

test "sidecar url is guarded on both layers after percent-decode (ROD-378)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // A CRLF-injection payload smuggled through the sub.info percent-encoding
    // decodes to raw control bytes, which cleanArg (printable ASCII only) rejects
    // before the url could reach our fetch or mpv's argv.
    const crlf = try Senshi.percentDecode(a, "https://h/x%0d%0aHost:%20evil");
    try testing.expect(!Senshi.cleanArg(crlf));

    // A percent-encoded private-IP host decodes to bytes cleanArg PASSES (digits and
    // dots are printable), so cleanArg alone can't stop SSRF. fetchguard is the layer
    // that does: fetchSubtitle runs both, in that order, before the fetch.
    const priv = try Senshi.percentDecode(a, "http://127%2e0%2e0%2e1/latest");
    try testing.expect(Senshi.cleanArg(priv));
    try testing.expectError(error.BlockedHost, fetchguard.guardFetchUrl(priv));
}

test "guardEpLabel accepts numeric/decimal labels, rejects path tricks" {
    try Senshi.guardEpLabel("1");
    try Senshi.guardEpLabel("13.5");
    try testing.expectError(error.InvalidEpisode, Senshi.guardEpLabel(""));
    try testing.expectError(error.InvalidEpisode, Senshi.guardEpLabel("1/2"));
    try testing.expectError(error.InvalidEpisode, Senshi.guardEpLabel("../7"));
    try testing.expectError(error.InvalidEpisode, Senshi.guardEpLabel("1.2.3"));
    try testing.expectError(error.InvalidEpisode, Senshi.guardEpLabel("SP1"));
}

test "coverRequest: relative posters get the host; absolute passes through" {
    var s = Senshi.init();
    const p = s.provider();
    const rel = try p.coverRequest(testing.allocator, "/posters/59708.webp");
    defer testing.allocator.free(rel.url);
    try testing.expectEqualStrings("https://senshi.live/posters/59708.webp", rel.url);
    try testing.expect(rel.referer != null);

    const abs = try p.coverRequest(testing.allocator, "https://cdn.example/x.webp");
    defer testing.allocator.free(abs.url);
    try testing.expectEqualStrings("https://cdn.example/x.webp", abs.url);
    try testing.expect(abs.referer == null);
}

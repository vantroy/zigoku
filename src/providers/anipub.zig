//! anipub.xyz: the second live `SourceProvider` (ROD-342), tier B (ROD-340).
//!
//! Plain public JSON (Express + MongoDB, docs api.anipub.xyz): no auth, no key, no
//! captcha. Streams are hosted on megaplay.buzz; this module owns everything
//! anipub-specific (catalog search, the MALID bind fuel, turning a show id into
//! per-episode realids) and hands the realid to the provider-agnostic megaplay
//! extractor (ROD-341) for the actual stream.
//!
//! The API surface (recon + live probes on ROD-340/342):
//!   * search    → GET /api/search/{name}     → hits {Name, Id, Image}. THREE response
//!                 shapes: an array (N hits), a bare hit object (1 hit), {"found":false} (0)
//!   * bind info → GET /api/info/{Id}         → MALID string + rich metadata; only the
//!                 NUMERIC-id form carries MALID (the slug form omits it); a missing id
//!                 answers HTTP 200 with the bare JSON string "err"
//!   * episodes  → GET /v1/api/details/{Id}   → local.ep[], index = episode number; each
//!                 link carries a literal `src=` attribute prefix (not a clean URL) in
//!                 one of TWO live shapes, both megaplay-backed (ROD-350):
//!                 `https://anipub.xyz/video/{realid}/{lang}` or
//!                 `https://gogoanime.com.by/streaming.php?id={slug}&ep={realid}&…`
//!
//! Tier B: the canonical id (MALID) sits behind a per-show network call, so
//! `canonicalKey` returns null and the resolver routes `.needs_search`. search()
//! backfills MALID from /api/info onto its head candidates, which is what feeds
//! `resolver.bestIdMatch` (exact-id bind); a hit whose info fetch fails stays a bare
//! title-only candidate and can still fuzzy-match (tier C).
//!
//! anipub's catalog `Name` is the ENGLISH title and its search matches ONLY that
//! field (live-verified: a romaji query misses shows whose Name is English), which
//! is why the resolver retries the canonical's English title (workers, ROD-342).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const domain = @import("../domain.zig");
const source = @import("../source.zig");
const megaplay = @import("megaplay.zig");
const log = @import("../log.zig");

const SITE = "https://anipub.xyz";
// A current Chrome UA, same posture as senshi/megaplay: recent and unremarkable.
const UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

// Cap on a cover ref before it's spliced into a fetch URL (mirrors senshi's guard).
const max_cover_ref_len = 2048;

/// Cap on per-candidate /api/info backfill fetches inside search(). Each is one
/// sequential GET; the true hit for a specific-title resolver query sits in the
/// head of anipub's (small) result sets. Candidates past the cap stay bare:
/// still fuzzy-matchable by title, just without the exact-id fast path.
const max_info_backfill = 10;

pub const AniPub = struct {
    /// Stable identity used by persistence keys `(source_name, show_id)`. The show
    /// handle is anipub's own numeric site id (e.g. Frieren = "2454"), an OPAQUE
    /// id, unlike senshi's mal-key; the canonical link rides the binding row.
    pub const source_name = "anipub";

    /// Human-facing name for user-visible copy (toasts, banners, CLI).
    pub const display_name = "AniPub";

    pub fn init() AniPub {
        return .{};
    }

    /// Pack this concrete provider into the erased `SourceProvider` the app holds.
    /// `self` must outlive every call made through the returned value.
    pub fn provider(self: *AniPub) source.SourceProvider {
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
        const self: *AniPub = @ptrCast(@alignCast(ptr));
        return self.search(arena, io, query, opts);
    }
    fn canonicalKeyErased(ptr: *anyopaque, arena: Allocator, canonical: domain.Anime) anyerror!?[]const u8 {
        _ = ptr;
        _ = arena;
        _ = canonical;
        // Tier B: anipub's show handle is its own opaque site id, and the canonical
        // link (MALID) needs a network call, so no pure derivation exists. The
        // resolver routes `.needs_search`; search() carries the id-bind fuel.
        return null;
    }
    fn episodesErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation) anyerror![]domain.EpisodeNumber {
        const self: *AniPub = @ptrCast(@alignCast(ptr));
        return self.episodes(arena, io, show_id, tt);
    }
    fn resolveErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) anyerror!domain.StreamLink {
        const self: *AniPub = @ptrCast(@alignCast(ptr));
        return self.resolve(arena, io, show_id, ep, tt, quality);
    }
    fn coverRequestErased(ptr: *anyopaque, gpa: Allocator, ref: []const u8) anyerror!source.CoverRequest {
        _ = ptr;
        // `ref` is untrusted provider data about to be spliced into a URL we fetch
        // (mirrors senshi/ROD-267).
        if (ref.len == 0 or ref.len > max_cover_ref_len or !cleanArg(ref))
            return error.InvalidCoverRef;
        // Covers are normally absolute cdn.noitatnemucod.net URLs, which serve a
        // plain client (verified live); pass through headerless.
        if (domain.isAbsoluteUrl(ref)) return .{ .url = try gpa.dupe(u8, ref) };
        // A site-relative ref: prepend the anipub host and send its referer + UA
        // (harmless where not gated, correct where it is).
        const sep = if (std.mem.startsWith(u8, ref, "/")) "" else "/";
        return .{
            .url = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ SITE, sep, ref }),
            .referer = SITE ++ "/",
            .user_agent = UA,
        };
    }

    // ── search ─────────────────────────────────────────────────────────────────

    /// One raw search hit. `Id` is anipub's numeric site id (the show handle);
    /// `finder` (the slug) is ignored: the slug form of /api/info omits MALID,
    /// so everything downstream keys on the numeric id.
    const Hit = struct {
        Name: ?[]const u8 = null,
        Id: ?u64 = null,
        Image: ?[]const u8 = null,
    };

    pub fn search(self: *AniPub, arena: Allocator, io: Io, query: []const u8, opts: source.SearchOptions) ![]domain.Anime {
        _ = self;
        // No server-side pagination or language filter on this endpoint; the full
        // (small) hit list arrives at once and we trim to the caller's limit.
        const url = try std.fmt.allocPrint(arena, SITE ++ "/api/search/{s}", .{try pathEncode(arena, try foldPunct(arena, query))});
        const raw = try request(arena, io, url);
        const hits = try parseSearchHits(arena, raw);

        var list: std.ArrayList(domain.Anime) = .empty;
        for (hits) |h| {
            if (list.items.len >= opts.limit) break;
            const id = h.Id orelse continue; // an id-less hit can't be played; drop
            try list.append(arena, .{
                .id = try std.fmt.allocPrint(arena, "{d}", .{id}),
                .name = h.Name orelse "(untitled)",
                .thumb = h.Image,
            });
        }

        // Tier-B fuel: backfill MALID (+ the metadata the fuzzy tie-breakers read)
        // from /api/info onto the head candidates. Best-effort per candidate: a
        // failed or "err"-bodied info fetch leaves that hit bare, never fails the
        // search. Sequential, one provider request at a time (ROD-309).
        for (list.items[0..@min(list.items.len, max_info_backfill)]) |*a| {
            backfillInfo(arena, io, a) catch |e| {
                log.warn("anipub info {s}: {s}", .{ a.id, @errorName(e) });
            };
        }
        return list.items;
    }

    /// Parse the search response across its three live shapes: an array of hits,
    /// a BARE single-hit object (yes, really; verified live), or {"found":false}
    /// for no hits. Anything else is host drift.
    fn parseSearchHits(arena: Allocator, raw: []const u8) ![]Hit {
        const val = try std.json.parseFromSlice(std.json.Value, arena, raw, .{});
        switch (val.value) {
            .array => {
                const parsed = try std.json.parseFromValue([]Hit, arena, val.value, .{ .ignore_unknown_fields = true });
                return parsed.value;
            },
            .object => |o| {
                // The no-hit sentinel is {"found":false}. Check the VALUE, not key
                // presence: a hypothetical found:true carrying hit fields must
                // parse as a hit, not vanish as a false miss (chaos-pass find).
                // A non-bool "found" is drift; treat it as no hits, not a crash.
                if (o.get("found")) |f| {
                    if (f != .bool or !f.bool) return &.{};
                }
                const parsed = try std.json.parseFromValue(Hit, arena, val.value, .{ .ignore_unknown_fields = true });
                const one = try arena.alloc(Hit, 1);
                one[0] = parsed.value;
                return one;
            },
            else => return error.HttpNotOk, // drift; same bucket as an unexpected status
        }
    }

    // ── the /api/info shape (bind + metadata backfill) ─────────────────────────

    const Info = struct {
        MALID: ?[]const u8 = null,
        Synonyms: ?[]const u8 = null, // usually the native (Japanese) title
        Premiered: ?[]const u8 = null, // "Fall 2023"
        Aired: ?[]const u8 = null, // "Sep 29, 2023 to Mar 22, 2024"
        Duration: ?[]const u8 = null, // "25m"
        Status: ?[]const u8 = null, // "Finished" / "Currently Airing" / …
        MALScore: ?[]const u8 = null, // "9.36", 0–10 as a string
        Genres: []const []const u8 = &.{},
        Studios: ?[]const u8 = null, // CSV
        epCount: ?u32 = null,
        DescripTion: ?[]const u8 = null, // sic, anipub's own field name
    };

    /// Fetch /api/info/{id} and fold it onto `a`. A missing id answers 200 + the
    /// bare string "err", which fails the struct parse; the caller degrades.
    fn backfillInfo(arena: Allocator, io: Io, a: *domain.Anime) !void {
        // `a.id` was minted by search() from a numeric field, but it's about to be
        // spliced into a URL path: re-guard anyway.
        try guardShowId(a.id);
        const url = try std.fmt.allocPrint(arena, SITE ++ "/api/info/{s}", .{a.id});
        const raw = try request(arena, io, url);
        const parsed = try std.json.parseFromSlice(Info, arena, raw, .{ .ignore_unknown_fields = true });
        applyInfo(a, parsed.value);
    }

    /// Fold an info payload onto a bare search hit. Pure over the parsed struct so
    /// it's unit-testable without the network. An empty/garbage MALID stays null;
    /// the resolver then falls to the tier-C fuzzy match.
    fn applyInfo(a: *domain.Anime, inf: Info) void {
        a.mal_id = if (inf.MALID) |m| std.fmt.parseInt(u64, std.mem.trim(u8, m, " "), 10) catch null else null;
        a.native_name = inf.Synonyms;
        if (inf.epCount) |n| {
            a.total_episodes = n;
            // Catalog data doesn't split sub/dub; surface the total as the sub
            // (dominant) track so ranking behaves (same shape as senshi).
            a.eps_sub = n;
        }
        a.duration = if (inf.Duration) |d| parseLeadingUint(u32, d) else null;
        a.status = mapStatus(inf.Status);
        a.score = scoreFrom(inf.MALScore);
        a.description = inf.DescripTion;
        a.genres = inf.Genres;
        if (inf.Premiered) |p| {
            a.season = seasonFrom(p);
            a.year = firstYear(p);
        }
        if (a.year == null) {
            if (inf.Aired) |ad| a.year = firstYear(ad);
        }
        if (a.year) |y| a.start_date = domain.Date{ .year = y };
    }

    // ── episodes ──────────────────────────────────────────────────────────────

    const DEp = struct { link: ?[]const u8 = null };
    const DLocal = struct { ep: []DEp = &.{} };
    const DetailsResp = struct { local: ?DLocal = null };

    pub fn episodes(self: *AniPub, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation) ![]domain.EpisodeNumber {
        _ = self;
        // Track-agnostic like senshi: anipub stores one (sub-keyed) realid list and
        // the sub/dub fork happens inside the megaplay embed at resolve time. A
        // missing dub surfaces as a resolve error, not a shorter list.
        _ = tt;
        try guardShowId(show_id);
        const raw = try request(arena, io, try detailsUrl(arena, show_id));
        const eps = try parseDetailsEps(arena, raw);

        // ep[] index + 1 IS the episode number (recon-pinned invariant): labels are
        // positional, and resolve() maps a label back to ep[label-1]. A dead entry
        // (null/garbage link) still occupies its slot so the numbering never shifts;
        // it fails at resolve with a clean error instead.
        var out: std.ArrayList(domain.EpisodeNumber) = .empty;
        for (0..eps.len) |i| {
            try out.append(arena, .{ .raw = try std.fmt.allocPrint(arena, "{d}", .{i + 1}) });
        }
        return out.items;
    }

    fn detailsUrl(arena: Allocator, show_id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(arena, SITE ++ "/v1/api/details/{s}", .{show_id});
    }

    /// Parse the /v1/api/details envelope down to its ep[] list. Pure over the
    /// response bytes so it's unit-testable without the network.
    fn parseDetailsEps(arena: Allocator, raw: []const u8) ![]DEp {
        const parsed = try std.json.parseFromSlice(DetailsResp, arena, raw, .{ .ignore_unknown_fields = true });
        const local = parsed.value.local orelse return error.NoEpisodeList;
        return local.ep;
    }

    // ── resolve ──────────────────────────────────────────────────────────────────

    pub fn resolve(self: *AniPub, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) !domain.StreamLink {
        _ = self;
        // megaplay hands back an adaptive HLS master; mpv picks off the bandwidth
        // ladder. Honoring the quality cap waits on the shared hls.zig extraction,
        // same rationale as senshi (ROD-301 follow-up).
        _ = quality;
        try guardShowId(show_id);

        // Our own episodes() minted the label as a 1-based integer; anything else
        // is corrupt.
        const n = std.fmt.parseInt(usize, ep.raw, 10) catch return error.InvalidEpisode;
        if (n == 0) return error.InvalidEpisode;

        const raw = try request(arena, io, try detailsUrl(arena, show_id));
        const eps = try parseDetailsEps(arena, raw);
        if (n > eps.len) return error.InvalidEpisode;

        const link = eps[n - 1].link orelse return error.BadEpisodeLink;
        const realid = parseRealId(link) orelse parseGogoRealId(link) orelse {
            // Neither live link shape: host drift, or a junk slot (a bare
            // /anime/{slug} show page in an ep slot is live-observed). Log the
            // link so the receipt says what the show actually embeds.
            log.warn("anipub resolve: unsupported ep link for show={s} ep={s}: {s}", .{ show_id, ep.raw, link });
            return error.UnsupportedStreamHost;
        };

        // The megaplay extractor (ROD-341) owns the two-step embed → getSources
        // dance, including the sub/dub fork and the whole referer/UA gate.
        const stream = try megaplay.resolve(arena, io, realid, tt);
        // Softsub tracks + intro/outro skip stamps ride `stream` too, parked
        // until the player grows a seam for them (ROD-340).
        return stream.link;
    }

    /// Extract the megaplay realid out of a /video/-shaped ep link: the digit run
    /// after `/video/` in `src=https://anipub.xyz/video/107259/sub`. The literal
    /// `src=` attribute prefix needs no stripping (the marker search skips it),
    /// and a `www.` host variant is live-observed and irrelevant to the marker.
    /// Null when the link doesn't carry the shape (resolve then tries the
    /// gogoanime shape, ROD-350).
    fn parseRealId(link: []const u8) ?[]const u8 {
        const marker = "/video/";
        const at = std.mem.indexOf(u8, link, marker) orelse return null;
        var i = at + marker.len;
        const start = i;
        while (i < link.len and std.ascii.isDigit(link[i])) i += 1;
        if (i == start) return null;
        return link[start..i];
    }

    /// Extract the megaplay realid out of a gogoanime-shaped ep link: the digit
    /// run in the `ep=` query param of `…gogoanime.com.by/streaming.php?id={slug}
    /// &ep=10790&server=hd-1&type=dub`. streaming.php is a thin iframe wrapper
    /// around megaplay s-2 and its `ep` value IS the megaplay realid, so no
    /// gogoanime fetch ever happens (live-verified across server=hd-1/2/3, all
    /// ignored by the wrapper; ROD-350). The stored `type=` is likewise ignored:
    /// like the /video/ shape's lang segment, the sub/dub fork belongs to the
    /// caller's requested track. Null when the link isn't streaming.php-shaped
    /// or carries no numeric ep.
    fn parseGogoRealId(link: []const u8) ?[]const u8 {
        if (std.mem.indexOf(u8, link, "/streaming.php?") == null) return null;
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, link, from, "ep=")) |at| {
            from = at + "ep=".len;
            // Anchor on a param boundary so "ep=" inside another name
            // (e.g. "deep=") can't match.
            if (at == 0 or (link[at - 1] != '?' and link[at - 1] != '&')) continue;
            var i = from;
            const start = i;
            while (i < link.len and std.ascii.isDigit(link[i])) i += 1;
            if (i > start) return link[start..i];
        }
        return null;
    }

    // ── internals ────────────────────────────────────────────────────────────────
    // HTTP helper + error taxonomy mirror senshi/megaplay (ROD-173) pending the
    // shared providers/http.zig extraction (ROD-349). Keep the four in step.

    fn request(arena: Allocator, io: Io, url: []const u8) ![]u8 {
        var client: std.http.Client = .{ .allocator = arena, .io = io };
        defer client.deinit();
        var aw: std.Io.Writer.Allocating = .init(arena);
        const res = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &aw.writer,
            .headers = .{ .user_agent = .{ .override = UA } },
            .extra_headers = &.{.{ .name = "Accept", .value = "application/json" }},
        }) catch |e| {
            log.warn("anipub GET {s}: transport {s}", .{ url, @errorName(e) });
            return mapTransportError(e);
        };
        if (res.status.class() != .success) {
            log.warn("anipub GET {s}: HTTP {d}", .{ url, @intFromEnum(res.status) });
            return statusToError(res.status);
        }
        return aw.writer.buffered();
    }

    /// Classify a non-2xx status (ROD-173): 403/451 = blocked; 5xx = source down;
    /// anything else = the undifferentiated `HttpNotOk` (likely API drift).
    fn statusToError(status: std.http.Status) error{ Forbidden, ServerError, HttpNotOk } {
        return switch (status) {
            .forbidden, .unavailable_for_legal_reasons => error.Forbidden,
            else => switch (status.class()) {
                .server_error => error.ServerError,
                else => error.HttpNotOk,
            },
        };
    }

    /// Map a transport-layer failure to `NetworkDown` when "check your connection"
    /// is the right advice; everything else propagates unchanged.
    fn mapTransportError(e: anyerror) anyerror {
        return switch (e) {
            error.ConnectionRefused,
            error.ConnectionResetByPeer,
            error.HostUnreachable,
            error.NetworkUnreachable,
            error.NetworkDown,
            error.Timeout,
            error.TlsInitializationFailed,
            error.UnknownHostName,
            error.NameServerFailure,
            error.NoAddressReturned,
            error.ResolvConfParseFailed,
            error.DetectingNetworkConfigurationFailed,
            error.InvalidDnsARecord,
            error.InvalidDnsAAAARecord,
            error.InvalidDnsCnameRecord,
            => error.NetworkDown,
            else => e,
        };
    }

    /// anipub's `Status` prose folded onto the canonical vocab `domain.isStillAiring`
    /// settles on (same contract as senshi.mapStatus, ROD-296).
    fn mapStatus(s: ?[]const u8) ?[]const u8 {
        const v = s orelse return null;
        if (containsIgnoreCase(v, "finished")) return "FINISHED";
        if (containsIgnoreCase(v, "cancel")) return "CANCELLED";
        if (containsIgnoreCase(v, "not yet")) return "NOT_YET_RELEASED";
        // anipub says "Ongoing" (live-observed), and folding it is what keeps the
        // resolver's episode veto from treating a partial airing count as final.
        if (containsIgnoreCase(v, "airing") or containsIgnoreCase(v, "current") or containsIgnoreCase(v, "ongoing")) return "RELEASING";
        return v; // unknown → keep raw; isStillAiring defaults it to safe (airing)
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
    }

    /// MALScore "9.36" (0–10, string) → AniList's 0–100 axis, so anipub and
    /// enriched scores read on one scale. Same guards as senshi's mapping.
    fn scoreFrom(s: ?[]const u8) ?u32 {
        const v = std.fmt.parseFloat(f64, s orelse return null) catch return null;
        if (!std.math.isFinite(v) or v <= 0) return null;
        return @intFromFloat(@min(@round(v * 10.0), 100.0));
    }

    /// First plausible 4-digit year (1900–2100) in a prose date field
    /// ("Fall 2023", "Sep 29, 2023 to Mar 22, 2024").
    fn firstYear(s: []const u8) ?u32 {
        var i: usize = 0;
        while (i < s.len) {
            if (!std.ascii.isDigit(s[i])) {
                i += 1;
                continue;
            }
            var j = i;
            while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
            if (j - i == 4) {
                const y = std.fmt.parseInt(u32, s[i..j], 10) catch 0;
                if (y >= 1900 and y <= 2100) return y;
            }
            i = j;
        }
        return null;
    }

    /// Season word out of `Premiered` ("Fall 2023"); the first token feeds the
    /// case-insensitive canonical parse.
    fn seasonFrom(premiered: []const u8) ?domain.Season {
        var it = std.mem.splitScalar(u8, premiered, ' ');
        const word = it.next() orelse return null;
        return domain.Season.fromString(word);
    }

    /// Parse the leading run of digits ("25m" → 25). Null when none.
    fn parseLeadingUint(comptime T: type, s: []const u8) ?T {
        var end: usize = 0;
        while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
        if (end == 0) return null;
        return std.fmt.parseInt(T, s[0..end], 10) catch null;
    }

    /// anipub show handles are its numeric site ids and every id we mint is
    /// digits-only. Enforce that before splicing into a URL path so a corrupt/
    /// hostile id can't smuggle a traversal or a second segment.
    fn guardShowId(show_id: []const u8) !void {
        if (show_id.len == 0) return error.InvalidShowId;
        for (show_id) |c| if (!std.ascii.isDigit(c)) return error.InvalidShowId;
    }

    /// True if `s` is safe to place in a fetch URL / mpv argv: printable ASCII only
    /// (0x21–0x7e), rejecting CR/LF, spaces and controls. Mirrors senshi's guard.
    fn cleanArg(s: []const u8) bool {
        for (s) |c| if (c < 0x21 or c > 0x7e) return false;
        return true;
    }

    /// Fold typographic punctuation to its ASCII form before a search query hits
    /// the wire. anipub stores ASCII ("Journey's End") while AniList titles carry
    /// the Unicode marks (U+2019 etc), and anipub's match is literal: the curly
    /// form answers found:false for shows it stocks (live-verified, the Frieren
    /// bind failed on exactly this). Unrecognized bytes pass through untouched.
    fn foldPunct(arena: Allocator, s: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < s.len) {
            if (i + 2 < s.len and s[i] == 0xE2 and s[i + 1] == 0x80) {
                const rep: ?[]const u8 = switch (s[i + 2]) {
                    0x98, 0x99 => "'", // U+2018/2019 single quotes
                    0x9C, 0x9D => "\"", // U+201C/201D double quotes
                    0x93, 0x94 => "-", // U+2013/2014 dashes
                    0xA6 => "...", // U+2026 ellipsis
                    else => null,
                };
                if (rep) |r| {
                    try out.appendSlice(arena, r);
                    i += 3;
                    continue;
                }
            }
            if (i + 1 < s.len and s[i] == 0xC2 and s[i + 1] == 0xA0) { // U+00A0 nbsp
                try out.append(arena, ' ');
                i += 2;
                continue;
            }
            try out.append(arena, s[i]);
            i += 1;
        }
        return out.items;
    }

    /// Percent-encode a search query for a URL path segment: RFC 3986 unreserved
    /// bytes pass, everything else (spaces, `/`, `:`, UTF-8) encodes, so a hostile
    /// or CJK query can't break out of the path.
    fn pathEncode(arena: Allocator, s: []const u8) ![]const u8 {
        const hex = "0123456789ABCDEF";
        var out: std.ArrayList(u8) = .empty;
        for (s) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
                try out.append(arena, c);
            } else {
                try out.append(arena, '%');
                try out.append(arena, hex[c >> 4]);
                try out.append(arena, hex[c & 15]);
            }
        }
        return out.items;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "parseSearchHits: array shape maps every hit (ROD-342)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const raw =
        \\[{"Name":"Frieren: Beyond Journey's End","Id":2454,
        \\  "Image":"https://cdn.noitatnemucod.net/thumbnail/300x400/100/x.jpg",
        \\  "finder":"frieren-beyond-journeys-end"},
        \\ {"Name":"Frieren: Beyond Journey's End Season 2","Id":1443,"finder":"s2"}]
    ;
    const hits = try AniPub.parseSearchHits(a, raw);
    try testing.expectEqual(@as(usize, 2), hits.len);
    try testing.expectEqual(@as(?u64, 2454), hits[0].Id);
    try testing.expectEqualStrings("Frieren: Beyond Journey's End", hits[0].Name.?);
    try testing.expect(hits[1].Image == null);
}

test "parseSearchHits: a bare single-hit object and the found:false sentinel" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // One hit arrives as a BARE object, not a 1-element array (verified live).
    const one = try AniPub.parseSearchHits(a,
        \\{"Name":"Sousou no Frieren - Marumaru no Mahou (Mini Anime)","Id":2378,"finder":"mini"}
    );
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(@as(?u64, 2378), one[0].Id);

    // No hits: {"found":false}, not an empty array.
    const none = try AniPub.parseSearchHits(a,
        \\{"found":false}
    );
    try testing.expectEqual(@as(usize, 0), none.len);

    // A found:true shape carrying hit fields is a HIT, not a miss (the sentinel
    // keys on the value; key presence alone must not discard a real result).
    const found_true = try AniPub.parseSearchHits(a,
        \\{"found":true,"Name":"Attack on Titan","Id":16498}
    );
    try testing.expectEqual(@as(usize, 1), found_true.len);
    try testing.expectEqual(@as(?u64, 16498), found_true[0].Id);

    // Anything else is drift, not a silent empty result.
    try testing.expectError(error.HttpNotOk, AniPub.parseSearchHits(a, "\"err\""));
}

test "applyInfo folds the live info shape onto a bare hit (ROD-342)" {
    var anime: domain.Anime = .{ .id = "2454", .name = "Frieren: Beyond Journey's End" };
    const genres = [_][]const u8{ "Adventure", "Drama" };
    AniPub.applyInfo(&anime, .{
        .MALID = "52991",
        .Synonyms = "葬送のフリーレン",
        .Premiered = "Fall 2023",
        .Aired = "Sep 29, 2023 to Mar 22, 2024",
        .Duration = "25m",
        .Status = "Finished",
        .MALScore = "9.36",
        .Genres = &genres,
        .epCount = 27,
    });

    try testing.expectEqual(@as(?u64, 52991), anime.mal_id); // the tier-B bind key
    try testing.expectEqualStrings("葬送のフリーレン", anime.native_name.?);
    try testing.expectEqual(@as(?u32, 27), anime.total_episodes);
    try testing.expectEqual(@as(u32, 27), anime.eps_sub);
    try testing.expectEqual(@as(?u32, 25), anime.duration);
    try testing.expectEqualStrings("FINISHED", anime.status.?);
    try testing.expect(!domain.isStillAiring(anime.status)); // ROD-296 contract holds
    try testing.expectEqual(@as(?u32, 94), anime.score); // 9.36 → 0–100 axis
    try testing.expectEqual(domain.Season.fall, anime.season.?);
    try testing.expectEqual(@as(?u32, 2023), anime.year);
    try testing.expectEqual(@as(usize, 2), anime.genres.len);
}

test "mapStatus folds anipub wording onto the canonical airing vocab (ROD-296)" {
    try testing.expectEqualStrings("FINISHED", AniPub.mapStatus("Finished").?);
    try testing.expect(!domain.isStillAiring(AniPub.mapStatus("Finished")));
    // anipub's live spelling for an airing show; must NOT read as settled or the
    // resolver's episode veto rejects legitimately-partial listings.
    try testing.expectEqualStrings("RELEASING", AniPub.mapStatus("Ongoing").?);
    try testing.expect(domain.isStillAiring(AniPub.mapStatus("Ongoing")));
    try testing.expectEqualStrings("NOT_YET_RELEASED", AniPub.mapStatus("Not yet aired").?);
    try testing.expect(AniPub.mapStatus(null) == null);
}

test "applyInfo: empty or garbage MALID stays null (tier-C fallback fuel)" {
    var anime: domain.Anime = .{ .id = "7", .name = "X" };
    AniPub.applyInfo(&anime, .{ .MALID = "" });
    try testing.expect(anime.mal_id == null);
    AniPub.applyInfo(&anime, .{ .MALID = "n/a" });
    try testing.expect(anime.mal_id == null);
    // Year falls back to Aired when Premiered is absent.
    AniPub.applyInfo(&anime, .{ .Aired = "Sep 29, 2023 to ?" });
    try testing.expectEqual(@as(?u32, 2023), anime.year);
}

test "parseDetailsEps unwraps the local.ep envelope; missing local is drift" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const raw =
        \\{"local":{"_id":2454,"name":"Episode 1","link":"src=https://anipub.xyz/video/107257/sub",
        \\ "ep":[{"link":"src=https://anipub.xyz/video/107259/sub"},
        \\       {"link":"src=https://anipub.xyz/video/107260/sub"},
        \\       {"link":"src=https://anipub.xyz/video/107261/sub"}]}}
    ;
    const eps = try AniPub.parseDetailsEps(a, raw);
    try testing.expectEqual(@as(usize, 3), eps.len);
    // ep[0] is episode 1: the envelope's own top-level `link` (107257) is player
    // chrome, NOT the first episode (spike-verified: ep1 realid = 107259).
    try testing.expectEqualStrings("107259", AniPub.parseRealId(eps[0].link.?).?);

    try testing.expectError(error.NoEpisodeList, AniPub.parseDetailsEps(a,
        \\{"remote":{}}
    ));
}

test "parseRealId strips the src= attribute prefix and bounds on digits" {
    try testing.expectEqualStrings("107259", AniPub.parseRealId("src=https://anipub.xyz/video/107259/sub").?);
    try testing.expectEqualStrings("42", AniPub.parseRealId("https://anipub.xyz/video/42/dub").?);
    // The www. host variant is live-observed (Solo Leveling's catalog entry).
    try testing.expectEqualStrings("115276", AniPub.parseRealId("src=https://www.anipub.xyz/video/115276/dub").?);
    try testing.expect(AniPub.parseRealId("src=https://anipub.xyz/watch/107259/sub") == null);
    try testing.expect(AniPub.parseRealId("src=https://anipub.xyz/video//sub") == null);
    try testing.expect(AniPub.parseRealId("") == null);
}

test "parseGogoRealId: the streaming.php ep param is the megaplay realid (ROD-350)" {
    // The live shape, verbatim from /v1/api/details (JJK ep1). server= and
    // type= ride along and are ignored.
    try testing.expectEqualStrings("10790", AniPub.parseGogoRealId(
        "src=https://gogoanime.com.by/streaming.php?id=jujutsu-kaisen-tv-534&ep=10790&server=hd-1&type=dub",
    ).?);
    // server=hd-3 (Apothecary Diaries ep1, the ROD-350 repro) parses the same.
    try testing.expectEqualStrings("108899", AniPub.parseGogoRealId(
        "src=https://gogoanime.com.by/streaming.php?id=the-apothecary-diaries-18578&ep=108899&server=hd-3&type=dub",
    ).?);
    // ep as the first param.
    try testing.expectEqualStrings("42", AniPub.parseGogoRealId("https://gogoanime.com.by/streaming.php?ep=42").?);
}

test "parseGogoRealId rejects junk slots and near-miss params" {
    // A bare show page in an ep slot is live-observed (Spy x Family's movie
    // tail); its slug digits must not read as a realid.
    try testing.expect(AniPub.parseGogoRealId("src=https://gogoanime.com.by/anime/spy-x-family-code-white-19291") == null);
    // "ep=" inside another param name is not the ep param.
    try testing.expect(AniPub.parseGogoRealId("https://x/streaming.php?deep=123&type=dub") == null);
    // A boundary-anchored ep with no digits is a dead slot, not a realid; a
    // later real ep param still wins.
    try testing.expect(AniPub.parseGogoRealId("https://x/streaming.php?ep=abc") == null);
    try testing.expectEqualStrings("7", AniPub.parseGogoRealId("https://x/streaming.php?deep=1&ep=7").?);
    // A hostile link STARTING with "ep=" puts the match at index 0; the
    // boundary check must not underflow, and the anchored param still wins.
    try testing.expectEqualStrings("1", AniPub.parseGogoRealId("ep=9/streaming.php?ep=1").?);
    try testing.expect(AniPub.parseGogoRealId("") == null);
}

test "canonicalKey is always null: tier B routes via needs_search (ROD-342)" {
    var ap = AniPub.init();
    const p = ap.provider();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // Even a fully id-bearing canonical derives nothing without a network call.
    const key = try p.canonicalKey(arena_state.allocator(), .{
        .id = "154587",
        .name = "Sousou no Frieren",
        .anilist_id = 154587,
        .mal_id = 52991,
    });
    try testing.expect(key == null);
}

test "guardShowId accepts numeric site ids, rejects traversal/injection" {
    try AniPub.guardShowId("2454");
    try testing.expectError(error.InvalidShowId, AniPub.guardShowId(""));
    try testing.expectError(error.InvalidShowId, AniPub.guardShowId("../etc"));
    try testing.expectError(error.InvalidShowId, AniPub.guardShowId("2454/x"));
    try testing.expectError(error.InvalidShowId, AniPub.guardShowId("frieren-slug")); // slug form omits MALID; never our key
}

test "foldPunct folds typographic marks to the ASCII forms anipub stores" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // The live failure: AniList's curly apostrophe vs anipub's straight one.
    try testing.expectEqualStrings(
        "Frieren: Beyond Journey's End",
        try AniPub.foldPunct(a, "Frieren: Beyond Journey\u{2019}s End"),
    );
    try testing.expectEqualStrings("\"x\" - y...", try AniPub.foldPunct(a, "\u{201C}x\u{201D} \u{2013} y\u{2026}"));
    try testing.expectEqualStrings("a b", try AniPub.foldPunct(a, "a\u{00A0}b"));
    // Untouched: plain ASCII and unrelated UTF-8 (CJK) pass through byte-exact.
    try testing.expectEqualStrings("plain 'x'", try AniPub.foldPunct(a, "plain 'x'"));
    try testing.expectEqualStrings("葬送のフリーレン", try AniPub.foldPunct(a, "葬送のフリーレン"));
}

test "pathEncode passes unreserved bytes, encodes separators and UTF-8" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("frieren", try AniPub.pathEncode(a, "frieren"));
    try testing.expectEqualStrings("re%3Azero%202nd", try AniPub.pathEncode(a, "re:zero 2nd"));
    try testing.expectEqualStrings("a%2F..%2Fb", try AniPub.pathEncode(a, "a/../b"));
    try testing.expectEqualStrings("%E8%91%AC", try AniPub.pathEncode(a, "葬"));
}

test "scoreFrom / firstYear / seasonFrom parse the prose fields defensively" {
    try testing.expectEqual(@as(?u32, 94), AniPub.scoreFrom("9.36"));
    try testing.expectEqual(@as(?u32, 100), AniPub.scoreFrom("11.0")); // clamp corrupt over-range
    try testing.expect(AniPub.scoreFrom("nan") == null);
    try testing.expect(AniPub.scoreFrom(null) == null);

    try testing.expectEqual(@as(?u32, 2023), AniPub.firstYear("Fall 2023"));
    try testing.expectEqual(@as(?u32, 2023), AniPub.firstYear("Sep 29, 2023 to Mar 22, 2024"));
    try testing.expect(AniPub.firstYear("Sep 29 to ?") == null);
    try testing.expect(AniPub.firstYear("episode 10298 aired") == null); // 5-digit run is not a year

    try testing.expectEqual(domain.Season.fall, AniPub.seasonFrom("Fall 2023").?);
    try testing.expect(AniPub.seasonFrom("2023") == null);
}

test "coverRequest: absolute CDN refs pass headerless; relative gets the site" {
    var ap = AniPub.init();
    const p = ap.provider();

    const abs = try p.coverRequest(testing.allocator, "https://cdn.noitatnemucod.net/thumbnail/300x400/100/x.jpg");
    defer testing.allocator.free(abs.url);
    try testing.expectEqualStrings("https://cdn.noitatnemucod.net/thumbnail/300x400/100/x.jpg", abs.url);
    try testing.expect(abs.referer == null);

    const rel = try p.coverRequest(testing.allocator, "/covers/x.jpg");
    defer testing.allocator.free(rel.url);
    try testing.expectEqualStrings("https://anipub.xyz/covers/x.jpg", rel.url);
    try testing.expect(rel.referer != null);

    try testing.expectError(error.InvalidCoverRef, p.coverRequest(testing.allocator, ""));
    try testing.expectError(error.InvalidCoverRef, p.coverRequest(testing.allocator, "/x y.jpg"));
}

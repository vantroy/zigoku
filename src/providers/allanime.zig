//! AllAnime `SourceProvider` (senshi is the default; this one predates it).
//!
//! Protocol (reimplemented from anipy-cli traffic, GPL-3.0, no code copied;
//! ROD-91 / ROD-62 / ROD-55): POST not GET (Cloudflare only challenges GET);
//! Apollo persisted-query sha256 hashes; AES-256-GCM `tobeparsed` blob.
//!
//! Site-specific facts (endpoint, hashes, referers, decrypt) stay quarantined
//! here behind `source.SourceProvider`. When AllAnime dies: replace this file.

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
const json_escape = @import("../util/json_escape.zig");

const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

const API = "https://api.allanime.day/api";
// Old Chrome UA: accepted and unremarkable.
const UA = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/86.0.4240.198 Safari/537.36";

// Apollo persisted-query hashes (server identifies ops by these, not raw query).
const HASH_SEARCH = "a24c500a1b765c68ae1d8dd85174931f661c71369c89b92b88b75a725afc471c";
const HASH_EPISODES = "043448386c7a686bc2aabfbb6b80f6074e795d350df48015023b079527b0848a";
const HASH_VIDEO = "d405d0edd690624b66baba3068e0edc3ac90f1597d898a1ec8db4e5c43c00fec";

// AES-256-GCM key seed for `tobeparsed` (key = sha256(seed)).
const GCM_SEED = "Xot36i3lK3:v1";

// Site origin: deciphered provider GETs (ROD-92) and CDN referer.
const SITE = "https://allanime.day";

// Cover CDN for bare relative `mcovers/…` paths (absolute AniList/MAL urls pass
// through). Cloudflare-fronted; 403s without referer. Host stays behind the
// vtable so rotation is one line (ROD-267).
const COVER_CDN_BASE = "https://wp.youtube-anime.com/aln.youtube-anime.com/";

// Cap before splicing a cover ref into a fetch URL (ROD-267).
const max_cover_ref_len = 2048;

// Referers the API / CDN gate on.
const REFERER_API = "https://allmanga.to/"; // search + episodes + clock GET
const REFERER_VIDEO = "https://youtu-chan.com/"; // get_video
const STREAM_REFERER = SITE; // mpv → fast4speed CDN

// `extensions` is a JSON *string* of JSON; inner quotes backslash-escaped.
fn extJson(comptime hash: []const u8) []const u8 {
    return "{\\\"persistedQuery\\\":{\\\"version\\\":1,\\\"sha256Hash\\\":\\\"" ++ hash ++ "\\\"}}";
}
const EXT_SEARCH = extJson(HASH_SEARCH);
const EXT_EPISODES = extJson(HASH_EPISODES);
const EXT_VIDEO = extJson(HASH_VIDEO);

/// Stateless provider shell; vtable needs a real `self` (ROD-92).
pub const AllAnime = struct {
    /// DB key for history/resume/cache: `(source_name, show_id)`. Never rename.
    pub const source_name = "allanime";

    /// Display label only; `source_name` is the persistence key.
    pub const display_name = "AllAnime";

    pub fn init() AllAnime {
        return .{};
    }

    /// Erased `SourceProvider`. `self` must outlive every call through the return.
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

    // ── vtable trampolines ───────────────────────────────────────────────────
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
        // Opaque catalog id only (AniList id is tier B via thumb); no MAL/AL join here.
        return null;
    }
    fn episodesErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation, count_hint: ?u32) anyerror![]domain.EpisodeNumber {
        const self: *AllAnime = @ptrCast(@alignCast(ptr));
        _ = count_hint; // real listing; canonical count unused
        return self.episodes(arena, io, show_id, tt);
    }
    fn resolveErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) anyerror!domain.StreamLink {
        const self: *AllAnime = @ptrCast(@alignCast(ptr));
        return self.resolve(arena, io, show_id, ep, tt, quality);
    }
    /// Cover ref → fetch request (ROD-267). Absolute as-is; relative `mcovers/…`
    /// gets CDN + SITE referer + UA. `url` is gpa-owned.
    fn coverRequestErased(ptr: *anyopaque, gpa: Allocator, ref: []const u8) anyerror!source.CoverRequest {
        _ = ptr;
        // Untrusted `thumbnail`: bound + printable-ASCII (`cleanArg`, same as mpv
        // argv). CR/LF/space would smuggle headers onto the wire. Host allowlist
        // is separate (ROD-266).
        if (ref.len == 0 or ref.len > max_cover_ref_len or !cleanArg(ref))
            return error.InvalidCoverRef;
        if (domain.isAbsoluteUrl(ref)) return .{ .url = try gpa.dupe(u8, ref) };
        return .{
            .url = try std.fmt.allocPrint(gpa, "{s}{s}", .{ COVER_CDN_BASE, ref }),
            .referer = SITE,
            .user_agent = UA,
        };
    }

    // ── search ───────────────────────────────────────────────────────────────

    const AvailEps = struct { sub: u32 = 0, dub: u32 = 0 };
    // Search edge fields with a domain.Anime home (ROD-181): englishName + year
    // for AniList matching; airedStart/season for chips (ROD-140); score 0-10
    // rescaled in edgeToAnime.
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

    /// Mine AniList media id from cover filename `…/cover/…/bx182255-hash.jpg`
    /// (ROD-181). Leading letters are size/kind; digits are the id. Null for MAL
    /// CDN (~13%) and unknown shapes (caller falls back to title match).
    ///
    /// TRUST: assumes thumb truthfully names the show. Same trust as title/streams;
    /// anilist_id is a nullable enrich column, not a store key, so a bad id cannot
    /// collide and is overwritten on next enrich.
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

    /// Search edge → Anime. Strings borrow JSON slices. Year: airedStart, else
    /// season year (ROD-181).
    fn edgeToAnime(e: SEdge) domain.Anime {
        const aired_year: ?u32 = if (e.airedStart) |a| a.year else null;
        const season_year: ?u32 = if (e.season) |s| s.year else null;
        const season: ?domain.Season = if (e.season) |s|
            (if (s.quarter) |q| domain.Season.fromString(q) else null)
        else
            null;
        // Year required for Date; month/day optional.
        const start_date: ?domain.Date = if (e.airedStart) |sd|
            (if (sd.year) |y| domain.Date{ .year = y, .month = sd.month, .day = sd.day } else null)
        else
            null;
        // AllAnime 0-10 → AniList 0-100 so search-seeded and enrich scores share a scale.
        const score: ?u32 = if (e.score) |s| blk: {
            // NaN fails comparisons; @intFromFloat is UB on NaN/Inf. Guard finite first.
            // 0/unrated → null; @min caps corrupt over-range at 100.
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
        // Search `variables` is a plain object (not stringified; per-op quirk).
        // One page of search_page_size so stride matches load-more (ROD-201).
        const q = try json_escape.escape(arena, query);
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

        // Title-match rank (ROD-60); AllAnime popularity score is metadata only.
        std.mem.sort(domain.Anime, list.items, RankCtx{ .query = query, .tt = opts.translation }, rankGreater);

        if (list.items.len > opts.limit) list.shrinkRetainingCapacity(opts.limit);
        return list.items;
    }

    // ── episodes ─────────────────────────────────────────────────────────────

    const EpDetail = struct { sub: []const []const u8 = &.{}, dub: []const []const u8 = &.{} };
    const EShow = struct { availableEpisodesDetail: EpDetail = .{} };
    const EData = struct { show: ?EShow = null };
    const EResp = struct { data: ?EData = null };

    pub fn episodes(self: *AllAnime, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation) ![]domain.EpisodeNumber {
        _ = self;
        // Double escape on purpose: inner JSON (id), then outer string layer.
        const inner = try episodesInner(arena, show_id);
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"variables\":\"{s}\",\"extensions\":\"{s}\"}}",
            .{ try json_escape.escape(arena, inner), EXT_EPISODES },
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

    // ── resolve ──────────────────────────────────────────────────────────────

    const VData = struct { tobeparsed: ?[]const u8 = null };
    const VResp = struct { data: ?VData = null };
    const Src = struct { sourceName: ?[]const u8 = null, sourceUrl: ?[]const u8 = null };
    const DecEp = struct { sourceUrls: []Src };
    const Dec = struct { episode: DecEp };

    // anipy trusted sourceName allow-list (fast4speed + long-tail).
    const ALLOWED_SOURCES = [_][]const u8{ "Yt-mp4", "S-Mp4", "Uv-mp4", "Ak", "Default" };

    // Case-insensitive (ROD-178): API sends `S-mp4`, list has `S-Mp4`.
    fn sourceAllowed(name: ?[]const u8) bool {
        const n = name orelse return false;
        for (ALLOWED_SOURCES) |a| if (std.ascii.eqlIgnoreCase(n, a)) return true;
        return false;
    }

    /// Direct fast4speed URL through `consider` before mpv (ROD-396 F3). Null →
    /// long tail. Blob rides public-seed GCM; MITM could forge trusted substring
    /// + argv injection; `consider` is the gate long-tail uses too.
    fn fast4speedPick(sources: []const Src) ?domain.StreamLink {
        for (sources) |s| {
            if (!sourceAllowed(s.sourceName)) continue;
            const url = s.sourceUrl orelse continue;
            if (std.mem.indexOf(u8, url, "tools.fast4speed.rsvp") == null) continue;
            if (consider(url, 1080, STREAM_REFERER)) |sl| return sl;
        }
        return null;
    }

    pub fn resolve(self: *AllAnime, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) !domain.StreamLink {
        _ = self;
        // Same two-level escape as episodes (videoInner then outer escape).
        const inner = try videoInner(arena, show_id, tt, ep.raw);
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"variables\":\"{s}\",\"extensions\":\"{s}\"}}",
            .{ try json_escape.escape(arena, inner), EXT_VIDEO },
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

        // Fast path: direct fast4speed (ROD-396 F3). Unsafe match falls to long tail.
        if (fast4speedPick(sources)) |sl| {
            // Single-variant 1080p; quality pref has nothing to pick (explain worst/480).
            log.debug("allanime resolve: fast4speed direct 1080p, quality={s} not applicable", .{@tagName(quality)});
            return sl;
        }

        // Long-tail (ROD-92): `--<hex>` providers. One bad provider doesn't sink the
        // rest. Quality pick once over the full set (ROD-152).
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
            // Sources existed but none playable: CDN failure, not hash rotation (ROD-300).
            log.warn("allanime resolve: no playable variant; {d} source(s) returned, {d} long-tail variant(s) gathered", .{ sources.len, variants.items.len });
            return error.NoDirectStream;
        };
        log.debug("allanime resolve: quality={s} picked {?d}p from {d} variant(s)", .{ @tagName(quality), pick.resolution, variants.items.len });
        return pick;
    }

    // ── internals ────────────────────────────────────────────────────────────

    /// Bounded head of a rejected GraphQL body (`errors` sits at the front).
    const GQL_REJECT_LOG_BYTES = 512;

    /// `data == null` on HTTP 200: operation rejected (often rotated hash /
    /// `PersistedQueryNotFound`). Always-on warn (ROD-300); body has no secrets.
    fn logGqlReject(stage: []const u8, raw: []const u8) void {
        const head = raw[0..@min(raw.len, GQL_REJECT_LOG_BYTES)];
        log.warn("allanime {s}: operation rejected (data:null); body head: {s}", .{ stage, head });
    }

    /// GraphQL POST. `.ok_only`: non-200 2xx is drift. `tag` is the referer (same
    /// API url for all ops; referer splits search/episodes vs get_video in logs).
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

    /// Long-tail GET wall-clock cap (ROD-153). KB payloads; trips only on stall.
    /// Without it, one slow host freezes resolve's sequential loop.
    const FETCH_DEADLINE_S = 20;

    /// ROD-92 long-tail GET: SSRF-guard, no redirects, body cap, wall-clock bound.
    /// Any failure → HttpNotOk (caller skips).
    fn get(arena: Allocator, io: Io, url: []const u8, referer: []const u8) ![]u8 {
        try fetchguard.guardFetchUrl(url);
        return deadline.withDeadline(io, .fromSeconds(FETCH_DEADLINE_S), fetchBody, .{ arena, io, url, referer }) catch |e| {
            if (e == error.Timeout)
                log.debug("allanime GET {s}: aborted past {d}s deadline", .{ url, FETCH_DEADLINE_S });
            return error.HttpNotOk;
        };
    }

    /// Cancelable long-tail GET body; no redirects; cap at http.MAX_RESP_BYTES.
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
            log.debug("allanime GET {s}: {s}", .{ url, @errorName(e) });
            return error.HttpNotOk;
        };
        if (res.status != .ok) {
            log.debug("allanime GET {s}: HTTP {d}", .{ url, @intFromEnum(res.status) });
            return error.HttpNotOk;
        }
        return w.buffered();
    }

    /// base64 + AES-256-GCM `tobeparsed`. Layout: [0] prefix, [1..13] nonce,
    /// [13..len-16] ciphertext, [len-16..] tag. Key = sha256(GCM_SEED).
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

    // ── ROD-92: long-tail (`--<hex>` → clock.json → wixmp or m3u8) ───────────
    // Pure helpers for unit tests; network follow is in resolve/followProvider.

    /// Hex pairs → bytes XOR 0x38. anipy's oct()/int(_,8) wrap is a no-op
    /// (verified all 256 values); dropped. Caller strips `--`, then clockJson.
    fn decipherProviderPath(arena: Allocator, hex: []const u8) ![]u8 {
        if (hex.len % 2 != 0) return error.BadProviderPath;
        const out = try arena.alloc(u8, hex.len / 2);
        for (out, 0..) |*b, i| {
            const byte = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch return error.BadProviderPath;
            b.* = byte ^ 0x38;
        }
        return out;
    }

    /// Wixmp repackager `…,480p,720p,…<tail>.urlset/…` → per-quality URLs.
    /// Null if not a wixmp repackager link.
    fn wixmpVariants(arena: Allocator, link: []const u8) !?[]hls.Variant {
        if (std.mem.indexOf(u8, link, "repackager.wixmp.com") == null) return null;
        const head = link[0..(std.mem.indexOf(u8, link, ".urlset") orelse link.len)];
        // Global host strip (oracle .replace); first/last parts wrap each quality.
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

    const ClkHdr = struct { Referer: ?[]const u8 = null };
    const ClkLink = struct { link: ?[]const u8 = null, headers: ?ClkHdr = null };
    const ClkResp = struct { links: []ClkLink = &.{} };

    /// First `clock` → `clock.json` (oracle .replace; paths are `/apivtwo/clock?…`).
    fn clockJson(arena: Allocator, path: []const u8) ![]u8 {
        const at = std.mem.indexOf(u8, path, "clock") orelse return arena.dupe(u8, path);
        const cut = at + "clock".len;
        return std.mem.concat(arena, u8, &.{ path[0..cut], ".json", path[cut..] });
    }

    /// Safe for mpv argv: printable ASCII 0x21-0x7e only (allowlist, not denylist).
    /// Catches CR/LF and ≥0x80 line-break-equivalents a `<0x20` denylist would miss.
    fn cleanArg(s: []const u8) bool {
        for (s) |c| if (c < 0x21 or c > 0x7e) return false;
        return true;
    }

    /// Untrusted clock.json Referer → SITE if dirty/absent (header-injection hazard).
    fn safeReferer(r: ?[]const u8) []const u8 {
        const v = r orelse return SITE;
        return if (cleanArg(v)) v else SITE;
    }

    /// Candidate → StreamLink or null. Must be http(s) (also rejects leading `--`
    /// mpv would treat as an option) and cleanArg. Quality pick is selectVariant's job.
    fn consider(url: []const u8, res: ?u32, referer: []const u8) ?domain.StreamLink {
        if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return null;
        if (!cleanArg(url)) return null;
        return .{ .url = url, .resolution = res, .referer = referer };
    }

    /// Follow one `--<hex>` provider; append safe variants. Failed *link* skipped;
    /// failed *provider* errors (partial appends kept). Quality pick is later.
    fn followProvider(arena: Allocator, io: Io, hex_path: []const u8, out: *std.ArrayList(domain.StreamLink)) !void {
        const deciphered = try decipherProviderPath(arena, hex_path);
        const path = try clockJson(arena, deciphered);
        // Path must start with `/` or SITE becomes userinfo (`@evil/x` SSRF).
        if (!std.mem.startsWith(u8, path, "/")) return error.BadProviderPath;
        const raw = try get(arena, io, try std.mem.concat(arena, u8, &.{ SITE, path }), REFERER_API);
        const parsed = try std.json.parseFromSlice(ClkResp, arena, raw, .{ .ignore_unknown_fields = true });

        for (parsed.value.links) |l| {
            const link = l.link orelse continue;
            const referer = safeReferer(if (l.headers) |h| h.Referer else null);

            // Shape 1: wixmp repackager (synthetic per-quality URLs).
            if (try wixmpVariants(arena, link)) |vs| {
                for (vs) |v| {
                    if (consider(v.url, v.resolution, STREAM_REFERER)) |sl| try out.append(arena, sl);
                }
                continue;
            }

            // Shape 2: m3u8 master (or media playlist if no variants).
            const body = get(arena, io, link, referer) catch |e| {
                log.debug("allanime m3u8 GET {s}: {s}", .{ link, @errorName(e) });
                continue;
            };
            const vs = try hls.parseMasterPlaylist(arena, body);
            if (vs.len == 0) {
                if (consider(link, 1080, referer)) |sl| try out.append(arena, sl);
            } else {
                for (vs) |v| {
                    if (consider(try hls.joinUrl(arena, link, v.url), v.resolution, referer)) |sl| try out.append(arena, sl);
                }
            }
        }
    }

    // ── ranking ──────────────────────────────────────────────────────────────

    const RankCtx = struct { query: []const u8, tt: domain.Translation };

    /// Title-match bonus + log2 episode-count tiebreak (fuller series wins).
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

    /// Descending relevance for std.mem.sort.
    fn rankGreater(ctx: RankCtx, a: domain.Anime, b: domain.Anime) bool {
        return relevance(a.name, ctx.query, a.episodeCount(ctx.tt)) >
            relevance(b.name, ctx.query, b.episodeCount(ctx.tt));
    }
};

/// Episodes inner `variables` (id escaped). Caller applies outer escape.
fn episodesInner(arena: Allocator, show_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{{\"_id\":\"{s}\"}}", .{try json_escape.escape(arena, show_id)});
}

/// get_video inner `variables`. `tt` is only sub/dub. Same outer-escape contract.
fn videoInner(arena: Allocator, show_id: []const u8, tt: domain.Translation, episode: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"showId\":\"{s}\",\"translationType\":\"{s}\",\"episodeString\":\"{s}\"}}",
        .{ try json_escape.escape(arena, show_id), tt.str(), try json_escape.escape(arena, episode) },
    );
}

test "relevance: exact > prefix > substring > no match" {
    const exact = AllAnime.relevance("Frieren", "Frieren", 12);
    const prefix = AllAnime.relevance("Frieren: Beyond Journey's End", "Frieren", 12);
    const sub = AllAnime.relevance("The World of Frieren", "Frieren", 12);
    const none = AllAnime.relevance("Naruto", "Frieren", 12);

    try std.testing.expect(exact > prefix);
    try std.testing.expect(prefix > sub);
    try std.testing.expect(sub > none);
    try std.testing.expect(none < sub);
}

test "relevance: episode count breaks ties via log2" {
    const more = AllAnime.relevance("Frieren", "Frieren", 28);
    const fewer = AllAnime.relevance("Frieren", "Frieren", 1);
    try std.testing.expect(more > fewer);
}

test "relevance: case-insensitive match" {
    const upper = AllAnime.relevance("FRIEREN", "frieren", 1);
    const lower = AllAnime.relevance("frieren", "FRIEREN", 1);
    const mixed = AllAnime.relevance("Frieren", "frIEReN", 1);
    const threshold: f64 = 999;
    try std.testing.expect(upper > threshold);
    try std.testing.expect(lower > threshold);
    try std.testing.expect(mixed > threshold);
}

test "rankGreater: orders anime by descending relevance" {
    const ctx = AllAnime.RankCtx{ .query = "frieren", .tt = .sub };
    const exact: domain.Anime = .{ .id = "1", .name = "frieren", .eps_sub = 1 };
    const unrelated: domain.Anime = .{ .id = "2", .name = "naruto", .eps_sub = 500 };
    try std.testing.expect(AllAnime.rankGreater(ctx, exact, unrelated));
    try std.testing.expect(!AllAnime.rankGreater(ctx, unrelated, exact));
}

test "anilistIdFromThumb: mines the AniList media id from cover urls" {
    const f = AllAnime.anilistIdFromThumb;
    try std.testing.expectEqual(@as(?u64, 182255), f("https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx182255-butzrqd4I0aC.jpg"));
    try std.testing.expectEqual(@as(?u64, 9203), f("https://s4.anilist.co/file/anilistcdn/media/anime/cover/medium/b9203-Dvr3qxjibGHK.png"));
    try std.testing.expectEqual(@as(?u64, 437), f("https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/nx437-w44gw3LYmLba.jpg"));
    // MAL path is image id, not anime id.
    try std.testing.expectEqual(@as(?u64, null), f("https://cdn.myanimelist.net/images/anime/10/11244.jpg"));
    try std.testing.expectEqual(@as(?u64, null), f(null));
    try std.testing.expectEqual(@as(?u64, null), f("https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/bx-nope.jpg"));
}

test "edgeToAnime: maps the widened search edge (ROD-181)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // 0 full, 1 season.year + MAL, 2 bare _id; unknown fields ignored.
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
    try std.testing.expectEqual(@as(?u32, 89), f0.score); // 8.88 → 89
    try std.testing.expectEqual(@as(u32, 10), f0.eps_sub);
    try std.testing.expectEqual(@as(?u32, 2026), f0.year);
    try std.testing.expectEqual(domain.Season.winter, f0.season.?);
    try std.testing.expectEqual(@as(?u32, 2026), f0.start_date.?.year);
    try std.testing.expectEqual(@as(?u32, 1), f0.start_date.?.month);
    try std.testing.expectEqual(@as(?u32, null), f0.start_date.?.day);

    const f1 = AllAnime.edgeToAnime(edges[1]);
    try std.testing.expectEqual(@as(?u64, null), f1.anilist_id);
    try std.testing.expectEqual(@as(?u32, 1998), f1.year);
    try std.testing.expectEqual(@as(?u32, null), f1.score);
    try std.testing.expectEqual(@as(?[]const u8, null), f1.english_name);
    try std.testing.expectEqual(domain.Season.fall, f1.season.?);
    try std.testing.expectEqual(@as(?domain.Date, null), f1.start_date);

    const f2 = AllAnime.edgeToAnime(edges[2]);
    try std.testing.expectEqualStrings("C", f2.id);
    try std.testing.expectEqualStrings("(untitled)", f2.name);
    try std.testing.expectEqual(@as(?u32, null), f2.year);
    try std.testing.expectEqual(@as(?u64, null), f2.anilist_id);
    try std.testing.expectEqual(@as(?domain.Season, null), f2.season);
}

test "edgeToAnime: score rescale clamps over-range and rejects non-finite (ROD-181)" {
    const mk = struct {
        fn score(v: ?f64) ?u32 {
            return AllAnime.edgeToAnime(.{ ._id = "x", .score = v }).score;
        }
    }.score;
    try std.testing.expectEqual(@as(?u32, 89), mk(8.88));
    try std.testing.expectEqual(@as(?u32, 100), mk(9.999));
    try std.testing.expectEqual(@as(?u32, 100), mk(11.5));
    try std.testing.expectEqual(@as(?u32, 100), mk(999.0));
    try std.testing.expectEqual(@as(?u32, null), mk(0));
    try std.testing.expectEqual(@as(?u32, null), mk(-3.0));
    try std.testing.expectEqual(@as(?u32, null), mk(null));
    try std.testing.expectEqual(@as(?u32, null), mk(std.math.nan(f64)));
    try std.testing.expectEqual(@as(?u32, null), mk(std.math.inf(f64)));
}

// Inner builders must escape ids/labels; unescaped `"` breaks the body (server silent reject).
test "episodesInner escapes the show id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("{\"_id\":\"abc\"}", try episodesInner(a, "abc"));
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
    try std.testing.expectEqualStrings(
        "{\"showId\":\"a\\\"b\",\"translationType\":\"dub\",\"episodeString\":\"1\\\"\"}",
        try videoInner(a, "a\"b", .dub, "1\""),
    );
}

// Pins tobeparsed layout (prefix/nonce/ct/tag, key=sha256(GCM_SEED)); offline fixture.
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

// anipy-cli golden; hex after stripping `--`. Also pins dropping the octal no-op.
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
    try std.testing.expect(!AllAnime.sourceAllowed("Sak"));
    try std.testing.expect(!AllAnime.sourceAllowed(null));
    // ROD-178: API casing (`S-mp4`) must match list (`S-Mp4`).
    try std.testing.expect(AllAnime.sourceAllowed("S-mp4"));
    try std.testing.expect(AllAnime.sourceAllowed("default"));
    try std.testing.expect(AllAnime.sourceAllowed("UV-MP4"));
    try std.testing.expect(!AllAnime.sourceAllowed("S-mp5"));
}

test "consider/safeReferer: reject mpv-argv injection (C1)" {
    try std.testing.expectEqualStrings("https://allanime.day", AllAnime.safeReferer("https://x/\r\nEvil: 1"));
    try std.testing.expectEqualStrings("https://ok.test/", AllAnime.safeReferer("https://ok.test/"));
    try std.testing.expectEqualStrings("https://allanime.day", AllAnime.safeReferer(null));
    try std.testing.expectEqual(@as(?domain.StreamLink, null), AllAnime.consider("https://x/a\nb", 1080, "r"));
    try std.testing.expectEqual(@as(?domain.StreamLink, null), AllAnime.consider("--script=evil.lua", 720, "r"));
    try std.testing.expectEqual(@as(?domain.StreamLink, null), AllAnime.consider("ftp://x/v.ts", 720, "r"));
    const ok = AllAnime.consider("https://cdn.test/v.m3u8", 1080, "https://allanime.day").?;
    try std.testing.expectEqualStrings("https://cdn.test/v.m3u8", ok.url);
    try std.testing.expectEqual(@as(?u32, 1080), ok.resolution);
}

test "fast4speedPick: gates the direct fast4speed url through consider (ROD-396 F3)" {
    const S = AllAnime.Src;
    const clean = [_]S{.{ .sourceName = "Default", .sourceUrl = "https://tools.fast4speed.rsvp/hls/v.m3u8" }};
    const got = AllAnime.fast4speedPick(&clean).?;
    try std.testing.expectEqualStrings("https://tools.fast4speed.rsvp/hls/v.m3u8", got.url);
    try std.testing.expectEqual(@as(?u32, 1080), got.resolution);

    // Gate assertion: trusted substring + argv injection must drop (else raw to mpv).
    const nl = [_]S{.{ .sourceName = "Default", .sourceUrl = "https://tools.fast4speed.rsvp/v\n--script=evil.lua" }};
    try std.testing.expectEqual(@as(?domain.StreamLink, null), AllAnime.fast4speedPick(&nl));

    const dashed = [_]S{.{ .sourceName = "Default", .sourceUrl = "--tools.fast4speed.rsvp/v.m3u8" }};
    try std.testing.expectEqual(@as(?domain.StreamLink, null), AllAnime.fast4speedPick(&dashed));

    const spoofed = [_]S{.{ .sourceName = "spoofed", .sourceUrl = "https://tools.fast4speed.rsvp/x.m3u8" }};
    try std.testing.expectEqual(@as(?domain.StreamLink, null), AllAnime.fast4speedPick(&spoofed));
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

    {
        const req = try p.coverRequest(gpa, "https://s4.anilist.co/file/x/bx1-abc.jpg");
        defer gpa.free(req.url);
        try std.testing.expectEqualStrings("https://s4.anilist.co/file/x/bx1-abc.jpg", req.url);
        try std.testing.expect(req.referer == null);
        try std.testing.expect(req.user_agent == null);
    }
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

    // CR/LF must not reach the socket as a smuggled header.
    try std.testing.expectError(error.InvalidCoverRef, p.coverRequest(gpa, "mcovers/x.webp\r\nX-Injected: 1"));
    try std.testing.expectError(error.InvalidCoverRef, p.coverRequest(gpa, "https://evil/\r\nHost: x"));
    try std.testing.expectError(error.InvalidCoverRef, p.coverRequest(gpa, "mcovers/a b.webp"));
    try std.testing.expectError(error.InvalidCoverRef, p.coverRequest(gpa, ""));
    try std.testing.expectError(error.InvalidCoverRef, p.coverRequest(gpa, "mcovers/" ++ ("a" ** (max_cover_ref_len + 1))));

    const req = try p.coverRequest(gpa, "mcovers/ok.webp");
    defer gpa.free(req.url);
    try std.testing.expect(std.mem.endsWith(u8, req.url, "mcovers/ok.webp"));
}

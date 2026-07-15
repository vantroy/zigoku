//! senshi.live `SourceProvider` (ROD-301; replaces captcha-walled AllAnime, ROD-300).
//!
//! Plain REST JSON on one origin, keyed by MAL id (also the AniSkip key). No persisted
//! query hashes, AES-GCM blob, or captcha from a raw HTTP client.
//!
//! API surface (ROD-300/301):
//!   * search / browse → POST /anime/filter
//!   * episode list    → GET  /episodes/{mal_id}
//!   * stream resolve  → GET  /episode-embeds/{mal_id}/{ep}
//!   * cover art       → /posters/{mal_id}.webp
//!
//! Site-specific facts stay behind the `source.SourceProvider` vtable.
//! Shared m3u8/quality machinery is ROD-302.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const domain = @import("../domain.zig");
const source = @import("../source.zig");
const log = @import("../log.zig");
const http = @import("http.zig");
const hls = @import("hls.zig");
const fetchguard = @import("../util/fetchguard.zig");
const json_escape = @import("../util/json_escape.zig");

const API = "https://senshi.live";
// Chrome UA: Cloudflare edge serves a plain client with this without a challenge.
const UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

// Stream CDN (ninstream.com) 403s a refererless GET; gate on this origin.
const STREAM_REFERER = "https://senshi.live/";

// Cap on a cover ref before splicing into a fetch URL (mirrors AllAnime).
const max_cover_ref_len = 2048;

pub const Senshi = struct {
    /// Persistence key `(source_name, show_id)`. Senshi keys by MAL id; old
    /// `("allanime", <opaque id>)` history rows do not map here until migration (ROD-301).
    pub const source_name = "senshi";

    /// User-visible name (toasts, banners, CLI).
    pub const display_name = "Senshi";

    pub fn init() Senshi {
        return .{};
    }

    /// Pack into erased `SourceProvider`. `self` must outlive every call through the return.
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

    // ── vtable trampolines ─────────────────────────────────────────────────────
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
        // Show handle is the stringified MAL id. No MAL id → null; resolver falls to title search (ROD-328).
        const mal = canonical.mal_id orelse return null;
        return try std.fmt.allocPrint(arena, "{d}", .{mal});
    }
    fn episodesErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation, count_hint: ?u32) anyerror![]domain.EpisodeNumber {
        const self: *Senshi = @ptrCast(@alignCast(ptr));
        _ = count_hint; // real listing endpoint; canonical count unused
        return self.episodes(arena, io, show_id, tt);
    }
    fn resolveErased(ptr: *anyopaque, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) anyerror!domain.StreamLink {
        const self: *Senshi = @ptrCast(@alignCast(ptr));
        return self.resolve(arena, io, show_id, ep, tt, quality);
    }
    fn coverRequestErased(ptr: *anyopaque, gpa: Allocator, ref: []const u8) anyerror!source.CoverRequest {
        _ = ptr;
        // Untrusted provider data about to be spliced into a fetch URL.
        // Reject non-printable / CR/LF / space (header smuggle; mirrors ROD-267).
        if (ref.len == 0 or ref.len > max_cover_ref_len or !cleanArg(ref))
            return error.InvalidCoverRef;
        // Absolute CDN urls pass through.
        if (domain.isAbsoluteUrl(ref)) return .{ .url = try gpa.dupe(u8, ref) };
        // Relative `/posters/…webp`: prepend host. Send site referer + UA.
        const sep = if (std.mem.startsWith(u8, ref, "/")) "" else "/";
        return .{
            .url = try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ API, sep, ref }),
            .referer = STREAM_REFERER,
            .user_agent = UA,
        };
    }

    // ── catalog JSON shape ─────────────────────────────────────────────────────
    // Both /anime/filter (`{data:[…]}`) and /anime/trending (bare array). `id` is
    // the MAL id (show handle for episodes/resolve). ignore_unknown_fields drops the rest.
    const SAnime = struct {
        id: u64,
        title: ?[]const u8 = null,
        title_english: ?[]const u8 = null,
        anime_picture: ?[]const u8 = null,
        type: ?[]const u8 = null,
        ani_source: ?[]const u8 = null,
        ani_episodes: ?[]const u8 = null, // JSON string ("16")
        ani_status: ?[]const u8 = null,
        duration: ?[]const u8 = null, // "23 min per ep"
        score: ?f64 = null, // 0-10
        ani_description: ?[]const u8 = null,
        ani_season: ?[]const u8 = null,
        ani_year: ?u32 = null,
        genres: ?[]const u8 = null, // "Action, Comedy"
        studios: ?[]const u8 = null,
    };
    const FilterResp = struct { data: []SAnime = &.{} };

    /// Map one raw senshi anime object. String fields borrow parsed-JSON slices (arena-owned).
    fn mapAnime(arena: Allocator, s: SAnime) !domain.Anime {
        // 0-10 → AniList 0-100 axis. Guard finiteness (@intFromFloat UB on NaN/Inf).
        const score: ?u32 = if (s.score) |v| blk: {
            if (!std.math.isFinite(v) or v <= 0) break :blk null;
            break :blk @intFromFloat(@min(@round(v * 10.0), 100.0));
        } else null;

        const total_eps: ?u32 = if (s.ani_episodes) |e| parseLeadingUint(u32, e) else null;

        return .{
            // Stringified MAL id is the provider show handle; must round-trip into episodes/resolve.
            .id = try std.fmt.allocPrint(arena, "{d}", .{s.id}),
            .name = s.title orelse "(untitled)",
            .english_name = s.title_english,
            .native_name = null, // senshi has no separate native field
            .mal_id = s.id, // free AniSkip key
            .thumb = s.anime_picture,
            .kind = s.type,
            .source_material = s.ani_source,
            .score = score,
            // Catalog has no sub/dub split; surface total as eps_sub so ranking/has(.sub) work.
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
        // Server matches title/english/synonyms and ranks by score. Do not re-rank on
        // romaji `name` (English query would miss it). Trust server order; trim to limit.
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"searchTerm\":\"{s}\",\"types\":[],\"genres\":[],\"status\":[],\"seasons\":[],\"year\":\"\",\"studios\":[],\"producers\":[],\"languages\":[],\"page\":{d},\"limit\":{d},\"sortBy\":\"score_desc\",\"languagePreference\":\"{s}\"}}",
            .{ try json_escape.escape(arena, query), opts.page, source.search_page_size, langPref(opts.translation) },
        );

        const raw = try request(arena, io, .POST, API ++ "/anime/filter", body);
        const parsed = try std.json.parseFromSlice(FilterResp, arena, raw, .{ .ignore_unknown_fields = true });

        var list: std.ArrayList(domain.Anime) = .empty;
        for (parsed.value.data) |s| try list.append(arena, try mapAnime(arena, s));
        if (list.items.len > opts.limit) list.shrinkRetainingCapacity(opts.limit);
        return list.items;
    }

    // ── episodes ──────────────────────────────────────────────────────────────

    /// One episode row. `ep_id` is the number resolve feeds into /episode-embeds.
    /// Filler/skip fields exist on the wire but `domain.EpisodeNumber` is label-only
    /// (ROD-301 follow-up). f64 tolerates fractional recaps (e.g. 13.5).
    const SEp = struct { ep_id: f64 };

    pub fn episodes(self: *Senshi, arena: Allocator, io: Io, show_id: []const u8, tt: domain.Translation) ![]domain.EpisodeNumber {
        _ = self;
        // List is track-agnostic; sub/dub availability is only known at embed time.
        // Unlike AllAnime, `tt` does not filter here. Missing track surfaces in resolve.
        _ = tt;
        try guardShowId(show_id);
        const url = try std.fmt.allocPrint(arena, API ++ "/episodes/{s}", .{show_id});
        const raw = try request(arena, io, .GET, url, null);
        return parseEpisodes(arena, raw);
    }

    /// Parse /episodes into numerically-sorted labels. Pure over response bytes.
    ///
    /// Drops phantom ep 0: some shows list a prologue, but /episode-embeds rejects 0
    /// with 400, so offering it only yields an unresolvable pick (ROD-301).
    fn parseEpisodes(arena: Allocator, raw: []const u8) ![]domain.EpisodeNumber {
        const parsed = try std.json.parseFromSlice([]SEp, arena, raw, .{ .ignore_unknown_fields = true });
        var eps: std.ArrayList(domain.EpisodeNumber) = .empty;
        for (parsed.value) |e| {
            if (e.ep_id == 0) continue;
            try eps.append(arena, .{ .raw = try epLabel(arena, e.ep_id) });
        }
        std.mem.sort(domain.EpisodeNumber, eps.items, {}, domain.EpisodeNumber.lessThan);
        return eps.items;
    }

    // ── resolve ──────────────────────────────────────────────────────────────────

    /// One /episode-embeds row: HLS master `url` + `status` track + optional `serverFM`
    /// carrying `sub.info=…` for soft-sub sidecars (ROD-378). Status labels lie on some
    /// shows (tagged HardSub with no burn-in); follow the sidecar, do not trust the label.
    const Embed = struct { url: ?[]const u8 = null, status: ?[]const u8 = null, serverFM: ?[]const u8 = null };

    /// One track in the sidecar `sub.info` JSON (ROD-378).
    const SubTrack = struct { src: ?[]const u8 = null, label: ?[]const u8 = null, default: bool = false };

    pub fn resolve(self: *Senshi, arena: Allocator, io: Io, show_id: []const u8, ep: domain.EpisodeNumber, tt: domain.Translation, quality: domain.Quality) !domain.StreamLink {
        _ = self;
        try guardShowId(show_id);
        try guardEpLabel(ep.raw);

        const url = try std.fmt.allocPrint(arena, API ++ "/episode-embeds/{s}/{s}", .{ show_id, ep.raw });
        const raw = try request(arena, io, .GET, url, null);
        const embeds = try std.json.parseFromSlice([]Embed, arena, raw, .{ .ignore_unknown_fields = true });

        const picked = pickEmbed(embeds.value, tt) orelse {
            // Show/episode exists but requested track does not (distinct from network failure).
            log.warn("senshi resolve: no {s} stream for show={s} ep={s} ({d} embed(s))", .{ tt.str(), show_id, ep.raw, embeds.value.len });
            return error.NoStreamForTrack;
        };
        const stream = picked.url orelse return error.NoStreamForTrack;
        // Embed url enters mpv argv: absolute http(s) + cleanArg only (no CRLF/space smuggle).
        if (!domain.isAbsoluteUrl(stream) or !cleanArg(stream)) return error.BadStreamUrl;

        // `.best` leaves mpv on the master ladder; a cap fetches master variants (hls.zig, ROD-302).
        // Best-effort: failure falls back to the adaptive master.
        const chosen = if (quality == .best) stream else capVariant(arena, io, stream, quality) orelse stream;

        // Soft subs via `link.sub_url` → mpv `--sub-file`. Do not gate on status (ROD-378);
        // null keeps raw play (pre-ROD-378 behavior).
        const sub_url = if (tt == .sub) fetchSubtitle(arena, io, picked.serverFM) else null;

        // ninstream 403s refererless GETs; mpv echoes referer on the HLS chain.
        // Same browser UA as the resolver (ROD-309). cloaked_segments: .ts served as .jpg.
        return .{
            .url = chosen,
            .referer = STREAM_REFERER,
            .user_agent = UA,
            .cloaked_segments = true,
            .sub_url = sub_url,
        };
    }

    /// Sidecar CDN empty/403 windows (ROD-309). Bounded retries with escalating backoff;
    /// first try immediate. Dead sidecar must not stall resolve.
    const SUB_RETRY_BACKOFFS_MS = [_]i64{ 300, 700, 1200 };

    /// Follow `serverFM` to a soft-sub .vtt, or null to play raw. Host-controlled URL:
    /// same SSRF + redirect-refuse gate as megaplay (ROD-266/377). Chosen .vtt gets
    /// absolute-url + cleanArg before mpv argv. Any failure → null; stream still plays.
    fn fetchSubtitle(arena: Allocator, io: Io, server_fm: ?[]const u8) ?[]const u8 {
        const info_url = subInfoUrl(arena, server_fm) orelse return null;
        if (!domain.isAbsoluteUrl(info_url) or !cleanArg(info_url)) return null;
        fetchguard.guardFetchUrl(info_url) catch return null;

        // Empty-body 200 fails parse and retries; valid empty `[]` does not (ROD-381).
        const tracks = for (0..SUB_RETRY_BACKOFFS_MS.len + 1) |attempt| {
            if (attempt > 0) std.Io.sleep(io, .fromMilliseconds(SUB_RETRY_BACKOFFS_MS[attempt - 1]), .awake) catch {};
            const body = http.request(arena, io, .{
                .method = .GET,
                .url = info_url,
                .user_agent = UA,
                .extra_headers = &.{.{ .name = "Referer", .value = STREAM_REFERER }},
                .redirect_behavior = .not_allowed,
                .tag = "senshi-sub",
                .accept = .ok_only,
            }) catch continue;
            const parsed = std.json.parseFromSlice([]SubTrack, arena, body, .{ .ignore_unknown_fields = true }) catch continue;
            break parsed.value;
        } else {
            log.warn("senshi: subtitle sidecar unavailable after {d} tries; playing raw", .{SUB_RETRY_BACKOFFS_MS.len + 1});
            return null;
        };

        const src = pickSubTrack(tracks) orelse return null;
        if (!domain.isAbsoluteUrl(src) or !cleanArg(src)) return null;
        return src;
    }

    /// Pull percent-decoded `sub.info` from `serverFM`. Null when absent (true HardSub).
    fn subInfoUrl(arena: Allocator, server_fm: ?[]const u8) ?[]const u8 {
        const fm = server_fm orelse return null;
        const key = "sub.info=";
        const at = std.mem.indexOf(u8, fm, key) orelse return null;
        var val = fm[at + key.len ..];
        if (std.mem.indexOfScalar(u8, val, '&')) |amp| val = val[0..amp];
        if (val.len == 0) return null;
        return percentDecode(arena, val) catch null;
    }

    /// Prefer host `default`, then english-labeled, then first track (ROD-377).
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

    /// Percent-decode a query value. Malformed `%` kept literal; controls caught by cleanArg.
    /// `+` stays literal (raw URL, not form data).
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

    /// Fetch adaptive master, return variant matching quality cap, or null (resolve falls back).
    fn capVariant(arena: Allocator, io: Io, master_url: []const u8, quality: domain.Quality) ?[]const u8 {
        // Host-supplied stream already argv-vetted. In-process fetch still takes SSRF gate
        // + refuse redirects (same as sidecar / megaplay probe).
        fetchguard.guardFetchUrl(master_url) catch return null;
        // ninstream 403s refererless GET: send stream referer + browser UA, not API headers.
        const body = http.request(arena, io, .{
            .method = .GET,
            .url = master_url,
            .user_agent = UA,
            .extra_headers = &.{.{ .name = "Referer", .value = STREAM_REFERER }},
            .redirect_behavior = .not_allowed,
            .tag = "senshi",
            .accept = .ok_only,
        }) catch return null;
        const variants = hls.parseMasterPlaylist(arena, body) catch return null;
        if (variants.len == 0) return null; // media playlist: let mpv take the master

        // Join relative URIs; drop any that fail argv safety before mpv's command line.
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

    /// Best embed for the track. Sub: SoftSub > HardSub > other sub. Returns full embed
    /// so caller can follow `serverFM` (ROD-378). Null when track not offered.
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

    /// Rank status for a track (0 = wrong track). Sub never matches Dub and vice-versa.
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
    /// One API request. Non-null body → POST JSON; null → GET. Any 2xx is success (ROD-349).
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

    /// Fold senshi prose onto canonical status. isStillAiring only settles exact
    /// FINISHED/CANCELLED; raw "Finished Airing" would never auto-complete (ROD-296).
    fn mapStatus(s: ?[]const u8) ?[]const u8 {
        const v = s orelse return null;
        if (containsIgnoreCase(v, "finished")) return "FINISHED";
        if (containsIgnoreCase(v, "cancel")) return "CANCELLED";
        if (containsIgnoreCase(v, "not yet")) return "NOT_YET_RELEASED";
        if (containsIgnoreCase(v, "airing") or containsIgnoreCase(v, "current")) return "RELEASING";
        return v; // unknown → keep raw; isStillAiring defaults to safe (airing)
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
    }

    /// Filter languagePreference: JP = sub, EN = dub.
    fn langPref(tt: domain.Translation) []const u8 {
        return switch (tt) {
            .sub => "JP",
            .dub => "EN",
        };
    }

    /// Split comma-space CSV into owned slices. Null/empty → empty list.
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

    /// Leading digit run only ("23 min per ep" → 23). Null when no leading digit.
    fn parseLeadingUint(comptime T: type, s: []const u8) ?T {
        var end: usize = 0;
        while (end < s.len and std.ascii.isDigit(s[end])) end += 1;
        if (end == 0) return null;
        return std.fmt.parseInt(T, s[0..end], 10) catch null;
    }

    /// Integral drops decimal ("1"); fractional keeps it ("13.5"). Non-finite → "0".
    fn epLabel(arena: Allocator, n: f64) ![]const u8 {
        if (!std.math.isFinite(n)) return arena.dupe(u8, "0");
        if (n >= 0 and n < 1_000_000 and @floor(n) == n)
            return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
        return std.fmt.allocPrint(arena, "{d}", .{n});
    }

    /// Show id is digits only (stringified MAL id). Reject before URL path splice
    /// so `../…` or `1/x` cannot smuggle a second path segment.
    fn guardShowId(show_id: []const u8) !void {
        if (show_id.len == 0) return error.InvalidShowId;
        for (show_id) |c| if (!std.ascii.isDigit(c)) return error.InvalidShowId;
    }

    /// Episode label is epLabel shape: digits, at most one `.`. Reject path tricks before URL splice.
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

    /// Safe for fetch URL / mpv argv: printable ASCII only (0x21-0x7e). Mirrors AllAnime.
    fn cleanArg(s: []const u8) bool {
        for (s) |c| if (c < 0x21 or c > 0x7e) return false;
        return true;
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

    try testing.expectEqualStrings("59708", m.id);
    try testing.expectEqual(@as(?u64, 59708), m.mal_id);
    try testing.expectEqualStrings("Classroom of the Elite 4th Season", m.english_name.?);
    try testing.expectEqual(@as(?u32, 79), m.score.?); // 7.88*10 → 79
    try testing.expectEqual(@as(?u32, 16), m.total_episodes.?);
    try testing.expectEqual(@as(u32, 16), m.eps_sub);
    try testing.expectEqual(@as(?u32, 23), m.duration.?);
    try testing.expectEqual(domain.Season.spring, m.season.?);
    try testing.expectEqual(@as(u32, 2026), m.start_date.?.year);
    try testing.expectEqualStrings("FINISHED", m.status.?);
    try testing.expectEqual(@as(usize, 2), m.genres.len);
    try testing.expectEqualStrings("Drama", m.genres[0]);
    try testing.expectEqualStrings("Suspense", m.genres[1]);
}

test "mapStatus folds senshi wording onto the canonical airing vocab (ROD-296)" {
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

test "parseEpisodes maps ep_id to numerically-sorted labels (ROD-301)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Phantom ep 0 dropped; "10" sorts after "2" numerically.
    const raw =
        \\[{"ep_id":3,"ep_title":"c","ep_filler":false,"intro_start":null},
        \\ {"ep_id":0,"ep_title":"Gray Phantom"},
        \\ {"ep_id":1,"ep_title":"a"},
        \\ {"ep_id":10,"ep_title":"j"},
        \\ {"ep_id":2,"ep_title":"b"}]
    ;
    const eps = try Senshi.parseEpisodes(a, raw);
    try testing.expectEqual(@as(usize, 4), eps.len);
    try testing.expectEqualStrings("1", eps[0].raw);
    try testing.expectEqualStrings("2", eps[1].raw);
    try testing.expectEqualStrings("3", eps[2].raw);
    try testing.expectEqualStrings("10", eps[3].raw);
}

test "epLabel: integral drops the decimal, fractional keeps it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("1", try Senshi.epLabel(a, 1.0));
    try testing.expectEqualStrings("12", try Senshi.epLabel(a, 12.0));
    try testing.expectEqualStrings("13.5", try Senshi.epLabel(a, 13.5));
    try testing.expectEqualStrings("0", try Senshi.epLabel(a, std.math.inf(f64)));
}

test "guardShowId accepts a numeric MAL id, rejects traversal/injection" {
    try Senshi.guardShowId("59708");
    try testing.expectError(error.InvalidShowId, Senshi.guardShowId(""));
    try testing.expectError(error.InvalidShowId, Senshi.guardShowId("../etc"));
    try testing.expectError(error.InvalidShowId, Senshi.guardShowId("59708/x"));
    try testing.expectError(error.InvalidShowId, Senshi.guardShowId("dsd8y"));
}

test "pickEmbed picks the right track and prefers soft subs (ROD-301)" {
    const embeds = [_]Senshi.Embed{
        .{ .url = "https://cdn/dub.m3u8", .status = "Dub" },
        .{ .url = "https://cdn/hard.m3u8", .status = "HardSub" },
        .{ .url = "https://cdn/soft.m3u8", .status = "SoftSub" },
    };
    try testing.expectEqualStrings("https://cdn/soft.m3u8", Senshi.pickEmbed(&embeds, .sub).?.url.?);
    try testing.expectEqualStrings("https://cdn/dub.m3u8", Senshi.pickEmbed(&embeds, .dub).?.url.?);

    const sub_only = [_]Senshi.Embed{.{ .url = "https://cdn/hard.m3u8", .status = "HardSub" }};
    try testing.expect(Senshi.pickEmbed(&sub_only, .dub) == null);
    try testing.expectEqualStrings("https://cdn/hard.m3u8", Senshi.pickEmbed(&sub_only, .sub).?.url.?);

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

    const fm = "https://host.example/e/abc123/?sub.info=https%3A%2F%2Fninstream.com%2Fx%2Fsub_filemoon.json";
    try testing.expectEqualStrings("https://ninstream.com/x/sub_filemoon.json", Senshi.subInfoUrl(a, fm).?);

    const fm2 = "https://host.example/e/abc/?sub.info=https%3A%2F%2Fc%2Fs.json&t=9";
    try testing.expectEqualStrings("https://c/s.json", Senshi.subInfoUrl(a, fm2).?);

    try testing.expect(Senshi.subInfoUrl(a, "https://host.example/d/xyz") == null);
    try testing.expect(Senshi.subInfoUrl(a, null) == null);
}

test "pickSubTrack: default wins, english next, first as fallback (ROD-378)" {
    const eng: Senshi.SubTrack = .{ .src = "https://c/eng.vtt", .label = "ENG", .default = true };
    const jpn: Senshi.SubTrack = .{ .src = "https://c/jpn.vtt", .label = "SDH (JPN)" };
    try testing.expectEqualStrings("https://c/eng.vtt", Senshi.pickSubTrack(&.{ eng, jpn }).?);

    const spa: Senshi.SubTrack = .{ .src = "https://c/spa.vtt", .label = "Spanish" };
    const eng2: Senshi.SubTrack = .{ .src = "https://c/eng2.vtt", .label = "English" };
    try testing.expectEqualStrings("https://c/eng2.vtt", Senshi.pickSubTrack(&.{ spa, eng2 }).?);

    const bare: Senshi.SubTrack = .{ .src = "https://c/bare.vtt" };
    try testing.expectEqualStrings("https://c/spa.vtt", Senshi.pickSubTrack(&.{ spa, bare }).?);

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
    try testing.expectEqualStrings("100%", try Senshi.percentDecode(a, "100%"));
    try testing.expectEqualStrings("%zz", try Senshi.percentDecode(a, "%zz"));
    // `+` is not a space (URL, not form data).
    try testing.expectEqualStrings("a+b", try Senshi.percentDecode(a, "a+b"));
}

test "sidecar url is guarded on both layers after percent-decode (ROD-378)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // CRLF smuggled through percent-encoding → cleanArg rejects before fetch/mpv.
    const crlf = try Senshi.percentDecode(a, "https://h/x%0d%0aHost:%20evil");
    try testing.expect(!Senshi.cleanArg(crlf));

    // Private IP is printable: cleanArg alone cannot stop SSRF; fetchguard is the second layer.
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

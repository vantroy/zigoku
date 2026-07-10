//! Zigoku — core domain types.
//!
//! These are the vocabulary the whole app speaks: a show in the catalog, an episode, a
//! resolved stream. They are deliberately SOURCE-AGNOSTIC: nothing here knows which provider
//! exists. A provider (see `source.zig`) fills these in; the rest of the app depends only on
//! these shapes, never on where they came from. That indirection is the whole defensive play:
//! when a stream site rots and dies (2026 is a graveyard for them), we swap one provider file,
//! not this.

const std = @import("std");

/// True if `s` is an absolute http(s) URL (carries a scheme), as opposed to a
/// provider-relative path a source must still resolve. The one axis the cover
/// pipeline needs — a fetchable absolute URL vs a bare relative ref (ROD-267).
/// Source-agnostic on purpose: no site knowledge, just the scheme.
pub fn isAbsoluteUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "https://") or std.mem.startsWith(u8, s, "http://");
}

/// Which track we want from the source. AllAnime keys sub/dub at every layer
/// (search counts, episode lists, stream resolution), so it rides along
/// everywhere.
pub const Translation = enum {
    sub,
    dub,

    /// The literal AllAnime expects in its GraphQL `translationType`.
    pub fn str(self: Translation) []const u8 {
        return @tagName(self);
    }
};

/// Watchlist state for a tracked show (ROD-139, §2.4). Persisted as the lowercase
/// `@tagName` in `anime.list_status` (TEXT NOT NULL DEFAULT 'planning'). This enum
/// is the single source of valid states — the column carries no CHECK; it trusts us.
pub const ListStatus = enum {
    planning,
    watching,
    paused,
    completed,
    dropped,

    /// Persisted form — the literal stored in `anime.list_status`. `@tagName` keeps
    /// the column value and the tag in lockstep: add a state, its string comes free.
    pub fn str(self: ListStatus) []const u8 {
        return @tagName(self);
    }

    /// Parse the stored column value. Unknown/empty → `planning` (the column
    /// default): an absent or corrupt status is "not started", never a wrong
    /// active state. Exact-match against tag names — we only ever write tag names.
    pub fn fromString(s: []const u8) ListStatus {
        return std.meta.stringToEnum(ListStatus, s) orelse .planning;
    }

    /// The status produced by a play/progress event (ROD-139 §1, auto-transitions
    /// only). `progress` is the post-play high-water mark; `total` is the show's
    /// episode count (null = unknown/ongoing). `still_airing` is true when the
    /// show isn't known-finished (see `isStillAiring`) — its `total` may then be
    /// the *aired-so-far* count, not the real finale, so catching up must not
    /// complete it. Pure + exhaustive so the state machine is unit-testable with no
    /// DB. Manual states (pause/drop/force) go through `Store.setListStatus`, not here.
    pub fn afterPlay(current: ListStatus, progress: i64, total: ?i64, still_airing: bool) ListStatus {
        // A finished show stays finished — a rewatch must not demote it.
        if (current == .completed) return .completed;
        // A still-airing show never auto-completes, even at its latest aired
        // episode (ROD-296): `total` is the aired-so-far count mid-broadcast, so
        // `progress >= total` just means "caught up", not "season over". It stays
        // `watching` until the season finishes airing. Manual force-complete
        // (`setListStatus`) is still honoured for the user who wants it done.
        if (still_airing) return .watching;
        // Reaching the known finale completes it.
        if (total) |t| {
            if (t > 0 and progress >= t) return .completed;
        }
        // Any play of an unfinished show (planning/watching/paused/dropped) means
        // it's being watched now.
        return .watching;
    }

    /// History grouping order (ROD-139 §3 / §5.4); lower sorts higher in the list.
    /// Deliberately `planning` before `paused` — Rod's call, overriding the
    /// active-intent ordering (which put paused first). Not an accident. This is
    /// the single source of the order; `group_order` is its materialised inverse.
    pub fn groupRank(self: ListStatus) u8 {
        return switch (self) {
            .watching => 0,
            .planning => 1,
            .paused => 2,
            .completed => 3,
            .dropped => 4,
        };
    }

    const count = @typeInfo(ListStatus).@"enum".fields.len;

    /// The §5.4 group display order — `groupRank`'s inverse, materialised at
    /// comptime so the History renderer can iterate groups top-to-bottom with no
    /// runtime cost and no second copy of the order to drift out of sync.
    pub const group_order: [count]ListStatus = blk: {
        var arr: [count]ListStatus = undefined;
        for (std.enums.values(ListStatus)) |s| arr[s.groupRank()] = s;
        break :blk arr;
    };
};

/// Whether a show's episode count is still provisional, i.e. `total_episodes` may be the
/// aired-so-far count, not the real finale, so it's unsafe to auto-complete against
/// (ROD-296). `ListStatus.afterPlay` gates auto-completion on this: a mid-broadcast show
/// isn't marked done the moment you catch up.
///
/// Deliberately a DENYLIST: only `FINISHED`/`CANCELLED` are settled (a finished season's
/// total IS its finale; a cancelled show's last-aired count is all there'll ever be).
/// EVERYTHING else is "still airing" for completion:
///   - `RELEASING` / AllAnime `ongoing`: the obvious weekly case.
///   - `HIATUS`: split-cour break; the show WILL resume, `total` is only cour-1.
///   - `NOT_YET_RELEASED`: no episodes yet (progress 0 anyway; harmless).
///   - null / empty / unknown: never trust a total we can't classify.
/// Vocab matches `detail.statusChipFor` (case-insensitive). `status` self-heals via the
/// non-null COALESCE on enrich (`FINISHED` overwrites `RELEASING`), which is why we gate on
/// it and not the `next_airing_episode` proxy, which that same upsert can never null back out.
pub fn isStillAiring(status: ?[]const u8) bool {
    const s = status orelse return true;
    if (std.ascii.eqlIgnoreCase(s, "FINISHED")) return false;
    if (std.ascii.eqlIgnoreCase(s, "CANCELLED")) return false;
    return true;
}

/// The user's stream-quality preference (ROD-152). `best`/`worst` are the
/// open-ended sentinels; the rungs name a vertical-pixel ceiling. The provider
/// applies a *cap* policy against whatever variants a source actually exposes —
/// see `allanime.selectVariant`. Sources with no variants (the fast4speed direct
/// URL) ignore this entirely; it's a no-op there, not a dead toggle.
pub const Quality = enum {
    best,
    p1080,
    p720,
    p480,
    worst,

    /// Parse a config string into a preference, degrading anything unrecognized
    /// to `.best` — the safe default, and the same "degrade at the call site"
    /// contract `Config.translationEnum` keeps. The settings cycle stores bare
    /// strings ("1080", "best"…), so this is the one place they become typed.
    pub fn fromString(s: []const u8) Quality {
        if (std.mem.eql(u8, s, "worst")) return .worst;
        if (std.mem.eql(u8, s, "480")) return .p480;
        if (std.mem.eql(u8, s, "720")) return .p720;
        if (std.mem.eql(u8, s, "1080")) return .p1080;
        return .best;
    }

    /// The vertical-pixel ceiling for a rung, or null for the `best`/`worst`
    /// sentinels (which select by extremum, not by cap).
    pub fn cap(self: Quality) ?u32 {
        return switch (self) {
            .p1080 => 1080,
            .p720 => 720,
            .p480 => 480,
            .best, .worst => null,
        };
    }
};

/// Broadcast season (the cours a show debuts in). AniList serves these
/// uppercase (`WINTER`…), AllAnime capitalized (`Winter`…); both fold to one
/// canonical value here so the render layer maps a single set to kanji 春/夏/秋/冬
/// (ROD-141) instead of re-parsing two source spellings.
pub const Season = enum {
    winter,
    spring,
    summer,
    fall,

    /// Parse AniList's `season` or AllAnime's `season.quarter`, case-insensitive;
    /// `autumn` aliases `fall`. Unknown/empty → null (an absent season, never a
    /// wrong one).
    pub fn fromString(s: []const u8) ?Season {
        if (std.ascii.eqlIgnoreCase(s, "winter")) return .winter;
        if (std.ascii.eqlIgnoreCase(s, "spring")) return .spring;
        if (std.ascii.eqlIgnoreCase(s, "summer")) return .summer;
        if (std.ascii.eqlIgnoreCase(s, "fall") or std.ascii.eqlIgnoreCase(s, "autumn")) return .fall;
        return null;
    }

    /// DESIGN.md §2.3: kanji label for the season chip.
    /// 春 spring / 夏 summer / 秋 autumn / 冬 winter (ROD-141).
    pub fn kanji(self: Season) []const u8 {
        return switch (self) {
            .winter => "冬",
            .spring => "春",
            .summer => "夏",
            .fall => "秋",
        };
    }

    /// The cour a calendar month (1–12) falls in, using AniList's own season
    /// boundaries so the top-bar "current season" fallback (ROD-186) agrees with
    /// the show chips it sits beside: 冬 Dec–Feb, 春 Mar–May, 夏 Jun–Aug, 秋 Sep–Nov.
    /// Note December belongs to the *next* year's Winter cour on AniList — that
    /// year roll is the caller's concern (see currentCour); this is month→season
    /// only. Out-of-range months can't occur (std clock yields 1–12) but default to
    /// winter rather than trap.
    pub fn fromMonth(month: u4) Season {
        return switch (month) {
            3, 4, 5 => .spring,
            6, 7, 8 => .summer,
            9, 10, 11 => .fall,
            else => .winter, // 12, 1, 2
        };
    }
};

/// A broadcast cour: a season anchored to its year.
pub const Cour = struct { season: Season, year: u32 };

/// The broadcast cour for an epoch-ms instant, with December rolled into next
/// year's Winter cour per AniList's boundaries. The single cour computation: the
/// top-bar chip, the Discover NEW badge, and the This Season feed axis (ROD-334)
/// all read it, so they can never disagree on which cour "now" is. Total: a
/// pre-epoch instant clamps to 1970 rather than trapping.
pub fn currentCour(now_ms: i64) Cour {
    const secs: u64 = @intCast(@max(0, @divFloor(now_ms, std.time.ms_per_s)));
    const yd = (std.time.epoch.EpochSeconds{ .secs = secs }).getEpochDay().calculateYearDay();
    const month = yd.calculateMonthDay().month.numeric();
    const year: u32 = if (month == 12) @as(u32, yd.year) + 1 else yd.year;
    return .{ .season = Season.fromMonth(month), .year = year };
}

/// A calendar date at whatever precision the source offered. `year` is always
/// present when the date exists; `month`/`day` fill in when known (AllAnime
/// gives year+month from `airedStart`, AniList year+month+day from `startDate`).
/// A pure value type — no heap, so it copies and frees for free.
pub const Date = struct {
    year: u32,
    month: ?u32 = null,
    day: ?u32 = null,
};

/// One show in the catalog.
///
/// Only `id` and `name` are guaranteed. `id` is the PROVIDER's opaque show handle, the
/// single thing `episodes()` and `resolve()` need, so it must round-trip untouched.
/// Everything else is best-effort metadata: the provider fills the episode counts; the
/// richer fields (description, genres, cover, score, MAL/AniList ids) stay empty until
/// AniList enrichment lands. An optional being `null` means "this source didn't tell us,"
/// not "doesn't exist."
pub const Anime = struct {
    /// Provider-opaque show id. Downstream calls depend on this being verbatim.
    id: []const u8,
    name: []const u8,
    english_name: ?[]const u8 = null,
    /// True AniList romaji title (ROD-312), distinct from `name` (which stays the
    /// provider display seed). Filled by enrichment; carried to the canonical write
    /// so `canonical.title` heals to romaji while the anime-local title stays the
    /// unmatched-row fallback. Write-only on this path — read-back surfaces via
    /// `canonical.title` through the COALESCE join, so it never needs to hydrate.
    title_romaji: ?[]const u8 = null,
    /// Native (usually Japanese) title. Populated from the provider search where
    /// available; render-side use lands with the kanji chips (ROD-141).
    native_name: ?[]const u8 = null,
    /// MyAnimeList id — AniSkip needs it (M5). Filled by AniList enrichment.
    mal_id: ?u64 = null,
    /// AniList id — the future ID-join key into the metadata layer. Enrichment.
    anilist_id: ?u64 = null,
    thumb: ?[]const u8 = null,
    banner: ?[]const u8 = null,
    eps_sub: u32 = 0,
    eps_dub: u32 = 0,
    /// Total episode count from enrichment when the provider-side per-track count
    /// is missing or partial.
    total_episodes: ?u32 = null,
    /// Per-episode runtime in minutes, from AniList enrichment (ROD-261). Renders
    /// as "N min" on the detail metadata rail between Format and Studios.
    duration: ?u32 = null,
    year: ?u32 = null,
    /// Broadcast season (the cours of `year`). Sourced AllAnime-first from
    /// `season.quarter`, backfilled by AniList enrichment. Pairs with `year` for
    /// the season+year detail chip (ROD-141).
    season: ?Season = null,
    /// Full debut date when a source offers more than the year. AllAnime's
    /// `airedStart` gives year+month; AniList's `startDate` adds the day.
    start_date: ?Date = null,
    status: ?[]const u8 = null,
    description: ?[]const u8 = null,
    genres: []const []const u8 = &.{},
    score: ?u32 = null,
    studios: []const []const u8 = &.{},
    /// AniList adaptation source (MANGA/LIGHT_NOVEL/ORIGINAL…), stored raw and
    /// prettified at render (ROD-261). Named `source_material` — NOT `source` —
    /// because `source` is already the provider key elsewhere (AnimeRecord's PK).
    source_material: ?[]const u8 = null,
    /// The single ranking picked by AniList `selectRank` (ROD-261): position,
    /// type ("RATED"/"POPULAR"), and year (null = all-time). Rail-only render.
    rank: ?u32 = null,
    rank_type: ?[]const u8 = null,
    rank_year: ?u32 = null,
    /// Next-episode airing (ROD-261): absolute `airingAt` unix timestamp + episode
    /// number, from AniList. The chips row recomputes a live countdown from these
    /// against `state.now` — see DESIGN §4.4. Present only for airing shows.
    next_airing_at: ?i64 = null,
    next_airing_episode: ?u32 = null,
    /// AniList `countryOfOrigin` (JP/CN/KR…), surfaced only when not JP (ROD-261).
    country: ?[]const u8 = null,
    /// Show kind ("TV", "Movie", "OVA"…). `type` is too close to a keyword to
    /// read well, so: `kind`.
    kind: ?[]const u8 = null,
    /// Live view count, for the Discover/Popular feed (ROD-239). The *windowed*
    /// count (views within the active window), falling back to lifetime total for
    /// the All-Time window — so it always tracks the card's rank. Runtime-only:
    /// the show's standing in the feed at fetch time, not a durable show fact, so
    /// it is never persisted (AnimeRecord ignores it) and stays null outside the
    /// feed. The feed's rank is the array position; the TOP/NEW badges the site
    /// shows are client-derived (not in the payload), so they live render-side.
    view_count: ?u64 = null,

    /// Does this show offer the requested track at all?
    pub fn has(self: Anime, tt: Translation) bool {
        return self.episodeCount(tt) > 0;
    }

    pub fn episodeCount(self: Anime, tt: Translation) u32 {
        return switch (tt) {
            .sub => self.eps_sub,
            .dub => self.eps_dub,
        };
    }

    /// The primary label under the user's `title_language` preference (ROD-205),
    /// with a never-blank fallback chain. A thin shim over `preferredTitle` for
    /// the live-catalog shape; the stored `AnimeRecord` calls `preferredTitle`
    /// directly with its own columns. Returns a borrow of one of `self`'s fields
    /// — never allocates, so it inherits the caller's slice lifetime.
    pub fn displayTitle(self: Anime, pref: TitleLanguage) []const u8 {
        return preferredTitle(self.name, self.english_name, self.native_name, pref);
    }
};

/// Which title form the UI shows as the primary label (ROD-205). Every value is
/// "preferred-with-fallback": there is deliberately no separate "Auto" — `english`
/// already resolves as English-first-then-fallback. `config.titleLanguageEnum`
/// maps the config string onto this, degrading unknown values to `.romaji`.
pub const TitleLanguage = enum { romaji, english, native };

/// `s` if it is present and non-empty, else null — an empty string is treated as
/// absent so a blank `english_name`/`native_name` falls through the chain rather
/// than rendering an empty primary label.
fn present(s: ?[]const u8) ?[]const u8 {
    if (s) |v| if (v.len > 0) return v;
    return null;
}

/// Resolve the primary title under `pref` with a never-blank fallback chain
/// (ROD-205, DESIGN §9.1a). `romaji` is the only form every source guarantees, so
/// it is the universal backstop at the end of all three chains:
///   romaji  → romaji → english → native
///   english → english → romaji → native
///   native  → native → romaji → english
/// Returns a borrow of one of the inputs; the final `orelse romaji` never
/// allocates and yields romaji even if empty (the render sites' own `"—"`
/// placeholder, e.g. `detailRenderInfo`, backstops that pathological case).
pub fn preferredTitle(
    romaji: []const u8,
    english: ?[]const u8,
    native: ?[]const u8,
    pref: TitleLanguage,
) []const u8 {
    const rom = present(romaji);
    return switch (pref) {
        .romaji => rom orelse present(english) orelse present(native) orelse romaji,
        .english => present(english) orelse rom orelse present(native) orelse romaji,
        .native => present(native) orelse rom orelse present(english) orelse romaji,
    };
}

/// One rendered title row: the string plus whether it is the native/Japanese-
/// script form (which alone renders italic per §1.3).
pub const TitleRow = struct { text: []const u8, native: bool };

/// The alt-title rows to render beneath `primary`, in `romaji → english → native` order,
/// each skipped when empty, byte-equal to `primary`, OR byte-equal to an alt already emitted
/// (ROD-205, §9.1a). This generalizes ROD-231's partial de-dupe (English vs romaji only)
/// into a symmetric rule against whichever form resolved as primary, so a fallback (e.g.
/// `english` with a null `english_name` resolving to romaji) never duplicates its target
/// into an alt row. The `n >= out.len` guard bounds the write by construction, so even a
/// `primary` matching none of the three forms can never overrun `out`.
pub fn altTitles(
    romaji: []const u8,
    english: ?[]const u8,
    native: ?[]const u8,
    primary: []const u8,
    out: *[2]TitleRow,
) []TitleRow {
    const forms = [_]TitleRow{
        .{ .text = romaji, .native = false },
        .{ .text = english orelse "", .native = false },
        .{ .text = native orelse "", .native = true },
    };
    var n: usize = 0;
    for (forms) |f| {
        if (n >= out.len) break; // bound by construction — never write past out[1]
        if (f.text.len == 0) continue;
        if (std.mem.eql(u8, f.text, primary)) continue;
        // Skip a form byte-equal to one already emitted (e.g. english == native,
        // neither being the primary) — no duplicate alt rows.
        var dup = false;
        for (out[0..n]) |prev| {
            if (std.mem.eql(u8, prev.text, f.text)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        out[n] = f;
        n += 1;
    }
    return out[0..n];
}

/// An episode "number" — a *string*, because anime episode labels aren't
/// integers: "1", "1.5" (a recap wedged between episodes), "13.5", "SP1" (a
/// special). We keep the source's raw label for display, and derive a numeric
/// key on demand for sorting.
pub const EpisodeNumber = struct {
    raw: []const u8,

    /// Numeric sort key from the leading run of digits/'.': "1.5" → 1.5.
    /// Anything without a leading digit ("SP1", "OVA") sorts to the very end via
    /// +inf, which keeps specials below the numbered run instead of scrambling it.
    pub fn sortKey(self: EpisodeNumber) f64 {
        var end: usize = 0;
        while (end < self.raw.len) : (end += 1) {
            const c = self.raw[end];
            if (!std.ascii.isDigit(c) and c != '.') break;
        }
        if (end == 0) return std.math.inf(f64);
        return std.fmt.parseFloat(f64, self.raw[0..end]) catch std.math.inf(f64);
    }

    /// `std.mem.sort` comparator: ascending by numeric value.
    pub fn lessThan(_: void, a: EpisodeNumber, b: EpisodeNumber) bool {
        return a.sortKey() < b.sortKey();
    }
};

/// A resolved, playable stream — everything mpv needs to start the bytes flowing.
pub const StreamLink = struct {
    url: []const u8,
    /// Vertical resolution if known (1080, 720…), else null. The fast4speed CDN
    /// hands back one direct URL with no manifest, so this is a known 1080 there;
    /// real per-variant detection arrives with m3u8 parsing (ROD-92).
    resolution: ?u32 = null,
    /// HTTP Referer mpv must echo to the CDN, or null if the CDN doesn't gate on it.
    referer: ?[]const u8 = null,
    /// User-Agent mpv must send, or null to leave ffmpeg's default `Lavf/*`. Set so the
    /// media fetch presents the same browser-shaped client the resolver used, part of
    /// looking less like a scraper to the CDN's bot/rate scoring (ROD-309).
    user_agent: ?[]const u8 = null,
    /// The HLS segments are served under a disguised extension — senshi cloaks its
    /// `.ts` segments as `.jpg` to slip content filters (ROD-301). ffmpeg's HLS
    /// demuxer refuses non-standard segment extensions by default, so the player
    /// must relax that gate for such a stream. False for sources whose segments
    /// carry their true extension (AllAnime), keeping the default strict.
    cloaked_segments: bool = false,
};

test "episode numeric sort handles decimals and specials" {
    var eps = [_]EpisodeNumber{
        .{ .raw = "2" },
        .{ .raw = "1.5" },
        .{ .raw = "SP1" },
        .{ .raw = "1" },
        .{ .raw = "10" },
    };
    std.mem.sort(EpisodeNumber, &eps, {}, EpisodeNumber.lessThan);
    try std.testing.expectEqualStrings("1", eps[0].raw);
    try std.testing.expectEqualStrings("1.5", eps[1].raw);
    try std.testing.expectEqualStrings("2", eps[2].raw);
    try std.testing.expectEqualStrings("10", eps[3].raw);
    try std.testing.expectEqualStrings("SP1", eps[4].raw); // non-numeric → last
}

test "has / episodeCount respect translation" {
    const a: Anime = .{ .id = "x", .name = "X", .eps_sub = 12, .eps_dub = 0 };
    try std.testing.expect(a.has(.sub));
    try std.testing.expect(!a.has(.dub));
    try std.testing.expectEqual(@as(u32, 12), a.episodeCount(.sub));
}

test "EpisodeNumber.sortKey: exact values" {
    // Plain integers and decimals should parse exactly.
    try std.testing.expectEqual(@as(f64, 1.0), (EpisodeNumber{ .raw = "1" }).sortKey());
    try std.testing.expectEqual(@as(f64, 1.5), (EpisodeNumber{ .raw = "1.5" }).sortKey());
    try std.testing.expectEqual(@as(f64, 13.5), (EpisodeNumber{ .raw = "13.5" }).sortKey());
    try std.testing.expectEqual(@as(f64, 10.0), (EpisodeNumber{ .raw = "10" }).sortKey());
}

test "EpisodeNumber.sortKey: leading zeros and trailing text" {
    // Leading zeros: "01" and "001" are still 1.0.
    try std.testing.expectEqual(@as(f64, 1.0), (EpisodeNumber{ .raw = "01" }).sortKey());
    try std.testing.expectEqual(@as(f64, 1.0), (EpisodeNumber{ .raw = "001" }).sortKey());
    // Digits followed by text: sort key comes from the digit prefix only.
    try std.testing.expectEqual(@as(f64, 12.0), (EpisodeNumber{ .raw = "12v2" }).sortKey());
}

test "EpisodeNumber.sortKey: non-numeric labels go to +inf" {
    // No leading digit at all → treated as a special, sorts last.
    const inf = std.math.inf(f64);
    try std.testing.expectEqual(inf, (EpisodeNumber{ .raw = "SP1" }).sortKey());
    try std.testing.expectEqual(inf, (EpisodeNumber{ .raw = "OVA" }).sortKey());
    try std.testing.expectEqual(inf, (EpisodeNumber{ .raw = "OVA3" }).sortKey());
    try std.testing.expectEqual(inf, (EpisodeNumber{ .raw = "" }).sortKey());
}

test "EpisodeNumber.lessThan: specials after numbered run" {
    // All specials sort after any numbered episode.
    const num = EpisodeNumber{ .raw = "100" };
    const sp = EpisodeNumber{ .raw = "SP1" };
    const ova = EpisodeNumber{ .raw = "OVA" };
    try std.testing.expect(EpisodeNumber.lessThan({}, num, sp));
    try std.testing.expect(!EpisodeNumber.lessThan({}, sp, num));
    // Two specials are not less-than each other (neither < the other, both +inf).
    try std.testing.expect(!EpisodeNumber.lessThan({}, sp, ova));
    try std.testing.expect(!EpisodeNumber.lessThan({}, ova, sp));
}

test "Season.fromString folds AniList and AllAnime spellings" {
    // AniList uppercase, AllAnime capitalized — both fold to one value.
    try std.testing.expectEqual(Season.winter, Season.fromString("WINTER").?);
    try std.testing.expectEqual(Season.fall, Season.fromString("Fall").?);
    // `autumn` aliases `fall`; case is irrelevant.
    try std.testing.expectEqual(Season.fall, Season.fromString("autumn").?);
    try std.testing.expectEqual(Season.summer, Season.fromString("sUmMeR").?);
    // Unknown/empty → null, never a wrong guess.
    try std.testing.expect(Season.fromString("") == null);
    try std.testing.expect(Season.fromString("rainy") == null);
}

test "Translation.str returns correct tag name" {
    try std.testing.expectEqualStrings("sub", Translation.sub.str());
    try std.testing.expectEqualStrings("dub", Translation.dub.str());
}

test "preferredTitle honors each preference when all three forms are present (ROD-205)" {
    const rom = "Sousou no Frieren";
    const eng = "Frieren: Beyond Journey's End";
    const nat = "葬送のフリーレン";
    try std.testing.expectEqualStrings(rom, preferredTitle(rom, eng, nat, .romaji));
    try std.testing.expectEqualStrings(eng, preferredTitle(rom, eng, nat, .english));
    try std.testing.expectEqualStrings(nat, preferredTitle(rom, eng, nat, .native));
}

test "preferredTitle falls through the chain, never blank (ROD-205)" {
    const rom = "Bleach";
    // english pref, english absent → romaji (the guaranteed backstop), not native.
    try std.testing.expectEqualStrings(rom, preferredTitle(rom, null, "ブリーチ", .english));
    // native pref, native absent → romaji.
    try std.testing.expectEqualStrings(rom, preferredTitle(rom, "Bleach EN", null, .native));
    // An empty string is treated as absent (falls through), not rendered blank.
    try std.testing.expectEqualStrings(rom, preferredTitle(rom, "", "", .english));
    // Even with romaji itself empty the result is never a crash — degrades to romaji
    // ("" here), which the render sites' own "—" placeholder backstops.
    try std.testing.expectEqualStrings("only", preferredTitle("", "only", null, .romaji));
}

test "altTitles de-dupes against the resolved primary, native-marked (ROD-205)" {
    const rom = "Sousou no Frieren";
    const eng = "Frieren: Beyond Journey's End";
    const nat = "葬送のフリーレン";
    var buf: [2]TitleRow = undefined;

    // romaji primary → english + native alts, native flagged, romaji→english→native order.
    var alts = altTitles(rom, eng, nat, rom, &buf);
    try std.testing.expectEqual(@as(usize, 2), alts.len);
    try std.testing.expectEqualStrings(eng, alts[0].text);
    try std.testing.expect(!alts[0].native);
    try std.testing.expectEqualStrings(nat, alts[1].text);
    try std.testing.expect(alts[1].native);

    // english primary → romaji then native (order preserved, primary self-excluded).
    alts = altTitles(rom, eng, nat, eng, &buf);
    try std.testing.expectEqual(@as(usize, 2), alts.len);
    try std.testing.expectEqualStrings(rom, alts[0].text);
    try std.testing.expectEqualStrings(nat, alts[1].text);

    // A form byte-equal to the primary is dropped (english == romaji here).
    alts = altTitles("Bleach", "Bleach", nat, "Bleach", &buf);
    try std.testing.expectEqual(@as(usize, 1), alts.len);
    try std.testing.expectEqualStrings(nat, alts[0].text);

    // Fallback case: english pref resolved to romaji (english null) → only native alt,
    // the romaji-that-rendered-as-primary is not duplicated into an alt row.
    const primary = preferredTitle(rom, null, nat, .english);
    alts = altTitles(rom, null, nat, primary, &buf);
    try std.testing.expectEqual(@as(usize, 1), alts.len);
    try std.testing.expectEqualStrings(nat, alts[0].text);

    // Two alt forms byte-equal to each other (english == native, neither primary)
    // collapse to a single alt row — no duplicate line.
    alts = altTitles(rom, "同じ", "同じ", rom, &buf);
    try std.testing.expectEqual(@as(usize, 1), alts.len);
    try std.testing.expectEqualStrings("同じ", alts[0].text);
}

test "Season.kanji returns correct glyphs" {
    // DESIGN.md §2.3: 春 spring / 夏 summer / 秋 autumn / 冬 winter (ROD-141).
    try std.testing.expectEqualStrings("冬", Season.winter.kanji());
    try std.testing.expectEqualStrings("春", Season.spring.kanji());
    try std.testing.expectEqualStrings("夏", Season.summer.kanji());
    try std.testing.expectEqualStrings("秋", Season.fall.kanji());
}

test "currentCour: cour mapping, December year roll, pre-epoch clamp (ROD-334)" {
    // 2026-07-10T00:00:00Z → Summer 2026.
    const summer = currentCour(1_783_641_600 * 1000);
    try std.testing.expectEqual(Season.summer, summer.season);
    try std.testing.expectEqual(@as(u32, 2026), summer.year);
    // 2025-12-15T00:00:00Z: December belongs to NEXT year's Winter cour on AniList.
    const winter = currentCour(1_765_756_800 * 1000);
    try std.testing.expectEqual(Season.winter, winter.season);
    try std.testing.expectEqual(@as(u32, 2026), winter.year);
    // A pre-epoch instant clamps to 1970 rather than trapping.
    const clamped = currentCour(-42);
    try std.testing.expectEqual(Season.winter, clamped.season);
    try std.testing.expectEqual(@as(u32, 1970), clamped.year);
}

test "Season.fromMonth maps months to AniList cours (ROD-186)" {
    // 冬 Dec–Feb wraps the year boundary.
    try std.testing.expectEqual(Season.winter, Season.fromMonth(12));
    try std.testing.expectEqual(Season.winter, Season.fromMonth(1));
    try std.testing.expectEqual(Season.winter, Season.fromMonth(2));
    // 春 Mar–May, 夏 Jun–Aug, 秋 Sep–Nov.
    try std.testing.expectEqual(Season.spring, Season.fromMonth(3));
    try std.testing.expectEqual(Season.spring, Season.fromMonth(5));
    try std.testing.expectEqual(Season.summer, Season.fromMonth(6));
    try std.testing.expectEqual(Season.summer, Season.fromMonth(8));
    try std.testing.expectEqual(Season.fall, Season.fromMonth(9));
    try std.testing.expectEqual(Season.fall, Season.fromMonth(11));
}

test "ListStatus.fromString parses tags and falls back to planning" {
    try std.testing.expectEqual(ListStatus.watching, ListStatus.fromString("watching"));
    try std.testing.expectEqual(ListStatus.dropped, ListStatus.fromString("dropped"));
    // Round-trips through the persisted form.
    try std.testing.expectEqual(ListStatus.completed, ListStatus.fromString(ListStatus.completed.str()));
    // Unknown/empty/corrupt → planning ("not started"), never a wrong active state.
    try std.testing.expectEqual(ListStatus.planning, ListStatus.fromString(""));
    try std.testing.expectEqual(ListStatus.planning, ListStatus.fromString("garbage"));
    try std.testing.expectEqual(ListStatus.planning, ListStatus.fromString("WATCHING")); // case-sensitive: we only write lowercase
}

test "ListStatus.afterPlay drives the auto-transition table (ROD-139 §1)" {
    const S = ListStatus;
    const done = false; // not airing — the finished-show path
    // planning → watching on first play (no finale reached).
    try std.testing.expectEqual(S.watching, S.afterPlay(.planning, 1, 12, done));
    // watching stays watching mid-run.
    try std.testing.expectEqual(S.watching, S.afterPlay(.watching, 5, 12, done));
    // watching → completed when progress reaches the known finale.
    try std.testing.expectEqual(S.completed, S.afterPlay(.watching, 12, 12, done));
    try std.testing.expectEqual(S.completed, S.afterPlay(.watching, 13, 12, done)); // overshoot still completes
    // paused / dropped resume to watching on a play.
    try std.testing.expectEqual(S.watching, S.afterPlay(.paused, 3, 12, done));
    try std.testing.expectEqual(S.watching, S.afterPlay(.dropped, 3, 12, done));
    // A finished show stays finished across rewatches — no demotion.
    try std.testing.expectEqual(S.completed, S.afterPlay(.completed, 1, 12, done));
    try std.testing.expectEqual(S.completed, S.afterPlay(.completed, 12, 12, done));
    // Unknown total (ongoing): never auto-completes, just marks watching.
    try std.testing.expectEqual(S.watching, S.afterPlay(.planning, 99, null, done));
    // total <= 0 is treated as unknown (guards the AllAnime "0 episodes" quirk).
    try std.testing.expectEqual(S.watching, S.afterPlay(.watching, 5, 0, done));

    // ROD-296: a still-airing show never auto-completes, even when caught up to
    // the latest aired episode (progress == aired count). It stays watching until
    // the season finishes airing. Covers every non-completed entry state, since the
    // gate fires before any switch on `current`.
    try std.testing.expectEqual(S.watching, S.afterPlay(.watching, 12, 12, true));
    try std.testing.expectEqual(S.watching, S.afterPlay(.watching, 13, 12, true));
    try std.testing.expectEqual(S.watching, S.afterPlay(.planning, 1, 12, true));
    try std.testing.expectEqual(S.watching, S.afterPlay(.paused, 12, 12, true));
    try std.testing.expectEqual(S.watching, S.afterPlay(.dropped, 12, 12, true));
    // But a manual/prior completion still wins over the airing gate — no demotion.
    try std.testing.expectEqual(S.completed, S.afterPlay(.completed, 12, 12, true));
}

test "isStillAiring settles only on FINISHED/CANCELLED, else keeps airing (ROD-296)" {
    // Settled: total_episodes is a trustworthy finale → not airing → completable.
    try std.testing.expect(!isStillAiring("FINISHED"));
    try std.testing.expect(!isStillAiring("finished"));
    try std.testing.expect(!isStillAiring("CANCELLED"));
    // Not settled: total may be aired-so-far → still airing → never auto-complete.
    try std.testing.expect(isStillAiring("RELEASING"));
    try std.testing.expect(isStillAiring("releasing"));
    try std.testing.expect(isStillAiring("ongoing")); // AllAnime vocab
    try std.testing.expect(isStillAiring("Ongoing"));
    try std.testing.expect(isStillAiring("HIATUS")); // split-cour break — will resume
    try std.testing.expect(isStillAiring("NOT_YET_RELEASED"));
    // Unknown / unclassifiable / absent → default to safe (don't complete).
    try std.testing.expect(isStillAiring("SOME_FUTURE_STATUS"));
    try std.testing.expect(isStillAiring(""));
    try std.testing.expect(isStillAiring(null));
}

test "ListStatus.groupRank orders watching → planning → paused → completed → dropped" {
    // Rod's ordering (planning before paused), overriding the active-intent spec.
    try std.testing.expect(ListStatus.watching.groupRank() < ListStatus.planning.groupRank());
    try std.testing.expect(ListStatus.planning.groupRank() < ListStatus.paused.groupRank());
    try std.testing.expect(ListStatus.paused.groupRank() < ListStatus.completed.groupRank());
    try std.testing.expect(ListStatus.completed.groupRank() < ListStatus.dropped.groupRank());
}

test "ListStatus.group_order is groupRank materialised in display order" {
    try std.testing.expectEqual(
        [_]ListStatus{ .watching, .planning, .paused, .completed, .dropped },
        ListStatus.group_order,
    );
}

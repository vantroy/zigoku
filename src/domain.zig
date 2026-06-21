//! Zigoku — core domain types.
//!
//! These are the vocabulary the whole app speaks: a show in the catalog, an
//! episode, a resolved stream. They are deliberately *source-agnostic* — nothing
//! here knows AllAnime exists. A provider (see `source.zig`) fills these in; the
//! rest of the app depends only on these shapes, never on where they came from.
//! That indirection is the whole defensive play: when a stream site rots and
//! dies (2026 is a graveyard for them), we swap one provider file, not this.

const std = @import("std");

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
    /// episode count (null = unknown/ongoing). Pure + exhaustive so the state
    /// machine is unit-testable with no DB. Manual states (pause/drop/force) go
    /// through `Store.setListStatus`, never here.
    pub fn afterPlay(current: ListStatus, progress: i64, total: ?i64) ListStatus {
        // A finished show stays finished — a rewatch must not demote it.
        if (current == .completed) return .completed;
        // Reaching the known finale completes it.
        if (total) |t| {
            if (t > 0 and progress >= t) return .completed;
        }
        // Any play of an unfinished show (planning/watching/paused/dropped) means
        // it's being watched now.
        return .watching;
    }

    /// History grouping order (ROD-139 §3 / §5.4); lower sorts higher in the list.
    /// Deliberately `planning` before `paused` — Rod's call, overriding Mira's
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
            .fall   => "秋",
        };
    }

    /// The cour a calendar month (1–12) falls in, using AniList's own season
    /// boundaries so the top-bar "current season" fallback (ROD-186) agrees with
    /// the show chips it sits beside: 冬 Dec–Feb, 春 Mar–May, 夏 Jun–Aug, 秋 Sep–Nov.
    /// Note December belongs to the *next* year's Winter cour on AniList — that
    /// year roll is the caller's concern (see App.currentCour); this is month→season
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
/// Only `id` and `name` are guaranteed. `id` is the *provider's* opaque show
/// handle (for AllAnime, its Mongo `_id`) — the single thing `episodes()` and
/// `resolve()` need, so it must round-trip untouched. Everything else is
/// best-effort metadata: AllAnime fills the episode counts; the richer fields
/// (description, genres, cover art, score, MAL/AniList ids) stay empty until the
/// AniList enrichment layer lands (M3/M4/M5). An optional being `null` means
/// "this source didn't tell us," not "doesn't exist."
pub const Anime = struct {
    /// Provider-opaque show id. Downstream calls depend on this being verbatim.
    id: []const u8,
    name: []const u8,
    english_name: ?[]const u8 = null,
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
    /// Show kind ("TV", "Movie", "OVA"…). `type` is too close to a keyword to
    /// read well, so: `kind`.
    kind: ?[]const u8 = null,

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
};

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

test "Season.kanji returns correct glyphs" {
    // DESIGN.md §2.3: 春 spring / 夏 summer / 秋 autumn / 冬 winter (ROD-141).
    try std.testing.expectEqualStrings("冬", Season.winter.kanji());
    try std.testing.expectEqualStrings("春", Season.spring.kanji());
    try std.testing.expectEqualStrings("夏", Season.summer.kanji());
    try std.testing.expectEqualStrings("秋", Season.fall.kanji());
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
    // planning → watching on first play (no finale reached).
    try std.testing.expectEqual(S.watching, S.afterPlay(.planning, 1, 12));
    // watching stays watching mid-run.
    try std.testing.expectEqual(S.watching, S.afterPlay(.watching, 5, 12));
    // watching → completed when progress reaches the known finale.
    try std.testing.expectEqual(S.completed, S.afterPlay(.watching, 12, 12));
    try std.testing.expectEqual(S.completed, S.afterPlay(.watching, 13, 12)); // overshoot still completes
    // paused / dropped resume to watching on a play.
    try std.testing.expectEqual(S.watching, S.afterPlay(.paused, 3, 12));
    try std.testing.expectEqual(S.watching, S.afterPlay(.dropped, 3, 12));
    // A finished show stays finished across rewatches — no demotion.
    try std.testing.expectEqual(S.completed, S.afterPlay(.completed, 1, 12));
    try std.testing.expectEqual(S.completed, S.afterPlay(.completed, 12, 12));
    // Unknown total (ongoing): never auto-completes, just marks watching.
    try std.testing.expectEqual(S.watching, S.afterPlay(.planning, 99, null));
    // total <= 0 is treated as unknown (guards the AllAnime "0 episodes" quirk).
    try std.testing.expectEqual(S.watching, S.afterPlay(.watching, 5, 0));
}

test "ListStatus.groupRank orders watching → planning → paused → completed → dropped" {
    // Rod's ordering (planning before paused), overriding Mira's active-intent spec.
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

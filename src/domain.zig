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

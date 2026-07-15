//! Core domain types. Source-agnostic vocabulary (show, episode, stream):
//! providers fill these; the rest of the app never depends on provider identity.

const std = @import("std");

/// Absolute http(s) URL vs provider-relative ref (ROD-267). Scheme only, no site knowledge.
pub fn isAbsoluteUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "https://") or std.mem.startsWith(u8, s, "http://");
}

/// Sub/dub track. Rides search, episode lists, and resolve.
pub const Translation = enum {
    sub,
    dub,

    pub fn str(self: Translation) []const u8 {
        return @tagName(self);
    }
};

/// Watchlist state (ROD-139 §2.4). Persisted as lowercase @tagName in anime.list_status
/// (no SQL CHECK; column trusts the enum).
pub const ListStatus = enum {
    planning,
    watching,
    paused,
    completed,
    dropped,

    /// Column form: @tagName keeps string and tag in lockstep.
    pub fn str(self: ListStatus) []const u8 {
        return @tagName(self);
    }

    /// Unknown/empty → planning (never invent an active state). Tag names only.
    pub fn fromString(s: []const u8) ListStatus {
        return std.meta.stringToEnum(ListStatus, s) orelse .planning;
    }

    /// Auto-status after a play (ROD-139 §1). still_airing: total may be aired-so-far,
    /// so catch-up must not complete (ROD-296). Manual pause/drop/force via setListStatus.
    pub fn afterPlay(current: ListStatus, progress: i64, total: ?i64, still_airing: bool) ListStatus {
        // Completed stays completed (rewatch must not demote).
        if (current == .completed) return .completed;
        // Still airing: never auto-complete at latest aired ep (ROD-296).
        if (still_airing) return .watching;
        if (total) |t| {
            if (t > 0 and progress >= t) return .completed;
        }
        return .watching;
    }

    /// History group order (ROD-139 §3/§5.4); lower = higher in list.
    /// planning before paused by design. group_order is the materialised inverse.
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

    /// §5.4 top-to-bottom group order: groupRank inverse, comptime (no drift).
    pub const group_order: [count]ListStatus = blk: {
        var arr: [count]ListStatus = undefined;
        for (std.enums.values(ListStatus)) |s| arr[s.groupRank()] = s;
        break :blk arr;
    };
};

/// True when total_episodes may be aired-so-far, not the finale (ROD-296). afterPlay
/// gates auto-complete on this.
///
/// DENYLIST: only FINISHED/CANCELLED are settled. Everything else (RELEASING, HIATUS,
/// NOT_YET_RELEASED, null/unknown) is still airing for completion. Gate on status (COALESCE
/// heals RELEASING→FINISHED), not next_airing_episode (upsert cannot null it back out).
pub fn isStillAiring(status: ?[]const u8) bool {
    const s = status orelse return true;
    if (std.ascii.eqlIgnoreCase(s, "FINISHED")) return false;
    if (std.ascii.eqlIgnoreCase(s, "CANCELLED")) return false;
    return true;
}

/// Cap for listing-less grid allocs from untrusted AniList counts (ROD-359 / ROD-92).
pub const max_episode_hint: u32 = 10_000;

/// Episode-grid count from canonical data (ROD-359). count_hint for no-listing
/// providers (megaplay); real listings ignore it. While airing: next_airing-1 floor
/// (over-list ok; under-list hides eps). Clamped to max_episode_hint.
pub fn expectedEpisodeCount(a: Anime) ?u32 {
    const raw: ?u32 = if (isStillAiring(a.status)) blk: {
        const next = a.next_airing_episode orelse break :blk a.total_episodes;
        if (next <= 1) return null; // next is ep 1: nothing aired
        const aired = next - 1;
        break :blk if (a.total_episodes) |total| @min(aired, total) else aired;
    } else a.total_episodes;
    return if (raw) |n| @min(n, max_episode_hint) else null;
}

/// Stream quality pref (ROD-152). best/worst = extremum; rungs = pixel cap.
/// Providers with no variants ignore this.
pub const Quality = enum {
    best,
    p1080,
    p720,
    p480,
    worst,

    /// Config string → Quality; unknown → best (safe default).
    pub fn fromString(s: []const u8) Quality {
        if (std.mem.eql(u8, s, "worst")) return .worst;
        if (std.mem.eql(u8, s, "480")) return .p480;
        if (std.mem.eql(u8, s, "720")) return .p720;
        if (std.mem.eql(u8, s, "1080")) return .p1080;
        return .best;
    }

    /// Pixel ceiling, or null for best/worst.
    pub fn cap(self: Quality) ?u32 {
        return switch (self) {
            .p1080 => 1080,
            .p720 => 720,
            .p480 => 480,
            .best, .worst => null,
        };
    }
};

/// Broadcast cour. AniList/AllAnime spellings fold here; render maps to kanji (ROD-141).
pub const Season = enum {
    winter,
    spring,
    summer,
    fall,

    /// Case-insensitive; autumn → fall. Unknown → null.
    pub fn fromString(s: []const u8) ?Season {
        if (std.ascii.eqlIgnoreCase(s, "winter")) return .winter;
        if (std.ascii.eqlIgnoreCase(s, "spring")) return .spring;
        if (std.ascii.eqlIgnoreCase(s, "summer")) return .summer;
        if (std.ascii.eqlIgnoreCase(s, "fall") or std.ascii.eqlIgnoreCase(s, "autumn")) return .fall;
        return null;
    }

    /// DESIGN §2.3 season chip: 春/夏/秋/冬 (ROD-141).
    pub fn kanji(self: Season) []const u8 {
        return switch (self) {
            .winter => "冬",
            .spring => "春",
            .summer => "夏",
            .fall => "秋",
        };
    }

    /// Month 1–12 → AniList cour (ROD-186). Dec is next-year Winter: year roll is
    /// caller's (currentCour). Out-of-range → winter.
    pub fn fromMonth(month: u4) Season {
        return switch (month) {
            3, 4, 5 => .spring,
            6, 7, 8 => .summer,
            9, 10, 11 => .fall,
            else => .winter, // 12, 1, 2
        };
    }
};

/// Season + year.
pub const Cour = struct { season: Season, year: u32 };

/// Cour for epoch-ms; December → next year's Winter (AniList). Shared by chip,
/// Discover NEW, This Season (ROD-334). Pre-epoch clamps to 1970.
pub fn currentCour(now_ms: i64) Cour {
    const secs: u64 = @intCast(@max(0, @divFloor(now_ms, std.time.ms_per_s)));
    const yd = (std.time.epoch.EpochSeconds{ .secs = secs }).getEpochDay().calculateYearDay();
    const month = yd.calculateMonthDay().month.numeric();
    const year: u32 = if (month == 12) @as(u32, yd.year) + 1 else yd.year;
    return .{ .season = Season.fromMonth(month), .year = year };
}

/// Calendar date at available precision. year always set when present; no heap.
pub const Date = struct {
    year: u32,
    month: ?u32 = null,
    day: ?u32 = null,
};

/// Catalog show. Only id + name guaranteed. id is the provider opaque handle
/// (episodes/resolve round-trip). Optionals null = source didn't provide.
pub const Anime = struct {
    /// Provider show id; must stay verbatim for episodes/resolve.
    id: []const u8,
    name: []const u8,
    english_name: ?[]const u8 = null,
    /// AniList romaji (ROD-312), not provider display seed (`name`). Write-only here;
    /// read-back via canonical.title COALESCE.
    title_romaji: ?[]const u8 = null,
    native_name: ?[]const u8 = null,
    /// MAL id (AniSkip). Enrichment.
    mal_id: ?u64 = null,
    /// AniList id. Enrichment.
    anilist_id: ?u64 = null,
    thumb: ?[]const u8 = null,
    banner: ?[]const u8 = null,
    eps_sub: u32 = 0,
    eps_dub: u32 = 0,
    total_episodes: ?u32 = null,
    /// Runtime minutes (ROD-261).
    duration: ?u32 = null,
    year: ?u32 = null,
    /// Broadcast cour (ROD-141).
    season: ?Season = null,
    start_date: ?Date = null,
    status: ?[]const u8 = null,
    description: ?[]const u8 = null,
    genres: []const []const u8 = &.{},
    score: ?u32 = null,
    studios: []const []const u8 = &.{},
    /// AniList adaptation source raw (ROD-261). Not provider `source`.
    source_material: ?[]const u8 = null,
    /// selectRank pick (ROD-261).
    rank: ?u32 = null,
    rank_type: ?[]const u8 = null,
    rank_year: ?u32 = null,
    /// Absolute next air (ROD-261, DESIGN §4.4).
    next_airing_at: ?i64 = null,
    next_airing_episode: ?u32 = null,
    /// countryOfOrigin; UI surfaces non-JP (ROD-261).
    country: ?[]const u8 = null,
    /// TV/Movie/OVA… (`kind`, not `type`).
    kind: ?[]const u8 = null,

    pub fn has(self: Anime, tt: Translation) bool {
        return self.episodeCount(tt) > 0;
    }

    pub fn episodeCount(self: Anime, tt: Translation) u32 {
        return switch (tt) {
            .sub => self.eps_sub,
            .dub => self.eps_dub,
        };
    }

    /// Primary label under title_language (ROD-205). Borrow; never allocates.
    pub fn displayTitle(self: Anime, pref: TitleLanguage) []const u8 {
        return preferredTitle(self.name, self.english_name, self.native_name, pref);
    }
};

/// Primary title form (ROD-205). No separate Auto: english already falls back.
pub const TitleLanguage = enum { romaji, english, native };

/// Non-empty present, else null (blank does not win the chain).
fn present(s: ?[]const u8) ?[]const u8 {
    if (s) |v| if (v.len > 0) return v;
    return null;
}

/// Primary title under pref; romaji is universal backstop (ROD-205, DESIGN §9.1a).
/// Borrow of an input. Empty romaji still returned; render may show a placeholder.
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

/// Alt row: native form alone is italic (§1.3).
pub const TitleRow = struct { text: []const u8, native: bool };

/// Alts under primary in romaji→english→native order (ROD-205 §9.1a). Skip empty,
/// equal to primary, or already emitted. out is max 2; never overrun.
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
        if (n >= out.len) break;
        if (f.text.len == 0) continue;
        if (std.mem.eql(u8, f.text, primary)) continue;
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

/// Episode label as string ("1", "1.5", "SP1"). Sort via sortKey.
pub const EpisodeNumber = struct {
    raw: []const u8,

    /// Leading digits/'.' as f64; non-numeric → +inf (specials after numbered run).
    pub fn sortKey(self: EpisodeNumber) f64 {
        var end: usize = 0;
        while (end < self.raw.len) : (end += 1) {
            const c = self.raw[end];
            if (!std.ascii.isDigit(c) and c != '.') break;
        }
        if (end == 0) return std.math.inf(f64);
        return std.fmt.parseFloat(f64, self.raw[0..end]) catch std.math.inf(f64);
    }

    pub fn lessThan(_: void, a: EpisodeNumber, b: EpisodeNumber) bool {
        return a.sortKey() < b.sortKey();
    }
};

/// Playable stream for mpv.
pub const StreamLink = struct {
    url: []const u8,
    resolution: ?u32 = null,
    referer: ?[]const u8 = null,
    /// Browser-shaped UA for CDN bot scoring (ROD-309); null = ffmpeg default.
    user_agent: ?[]const u8 = null,
    /// HLS segments cloaked as .jpg (senshi, ROD-301); player must relax demuxer gate.
    cloaked_segments: bool = false,
    /// External WebVTT (megaplay softsub, ROD-354); null if hardsub/none. Untrusted like url.
    sub_url: ?[]const u8 = null,
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
    // AniList uppercase, AllAnime capitalized, both fold to one value.
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
    // Even with romaji itself empty the result is never a crash, degrades to romaji
    // ("" here), which the render sites' own ", " placeholder backstops.
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
    // collapse to a single alt row, no duplicate line.
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
    const done = false; // finished-show path
    try std.testing.expectEqual(S.watching, S.afterPlay(.planning, 1, 12, done));
    try std.testing.expectEqual(S.watching, S.afterPlay(.watching, 5, 12, done));
    try std.testing.expectEqual(S.completed, S.afterPlay(.watching, 12, 12, done));
    try std.testing.expectEqual(S.completed, S.afterPlay(.watching, 13, 12, done)); // overshoot still completes
    try std.testing.expectEqual(S.watching, S.afterPlay(.paused, 3, 12, done));
    try std.testing.expectEqual(S.watching, S.afterPlay(.dropped, 3, 12, done));
    try std.testing.expectEqual(S.completed, S.afterPlay(.completed, 1, 12, done));
    try std.testing.expectEqual(S.completed, S.afterPlay(.completed, 12, 12, done));
    try std.testing.expectEqual(S.watching, S.afterPlay(.planning, 99, null, done));
    try std.testing.expectEqual(S.watching, S.afterPlay(.watching, 5, 0, done)); // total<=0 as unknown

    // ROD-296: still airing never auto-completes at catch-up; completed still wins.
    try std.testing.expectEqual(S.watching, S.afterPlay(.watching, 12, 12, true));
    try std.testing.expectEqual(S.watching, S.afterPlay(.watching, 13, 12, true));
    try std.testing.expectEqual(S.watching, S.afterPlay(.planning, 1, 12, true));
    try std.testing.expectEqual(S.watching, S.afterPlay(.paused, 12, 12, true));
    try std.testing.expectEqual(S.watching, S.afterPlay(.dropped, 12, 12, true));
    try std.testing.expectEqual(S.completed, S.afterPlay(.completed, 12, 12, true));
}

test "isStillAiring settles only on FINISHED/CANCELLED, else keeps airing (ROD-296)" {
    try std.testing.expect(!isStillAiring("FINISHED"));
    try std.testing.expect(!isStillAiring("finished"));
    try std.testing.expect(!isStillAiring("CANCELLED"));
    try std.testing.expect(isStillAiring("RELEASING"));
    try std.testing.expect(isStillAiring("releasing"));
    try std.testing.expect(isStillAiring("ongoing")); // AllAnime vocab
    try std.testing.expect(isStillAiring("Ongoing"));
    try std.testing.expect(isStillAiring("HIATUS"));
    try std.testing.expect(isStillAiring("NOT_YET_RELEASED"));
    try std.testing.expect(isStillAiring("SOME_FUTURE_STATUS"));
    try std.testing.expect(isStillAiring(""));
    try std.testing.expect(isStillAiring(null));
}

test "expectedEpisodeCount: aired floor while airing, total when settled (ROD-359)" {
    try std.testing.expectEqual(@as(?u32, 28), expectedEpisodeCount(.{ .id = "x", .name = "x", .status = "FINISHED", .total_episodes = 28 }));
    try std.testing.expectEqual(@as(?u32, 13), expectedEpisodeCount(.{ .id = "x", .name = "x", .status = "RELEASING", .total_episodes = 24, .next_airing_episode = 14 }));
    try std.testing.expectEqual(@as(?u32, 24), expectedEpisodeCount(.{ .id = "x", .name = "x", .status = "RELEASING", .total_episodes = 24 }));
    try std.testing.expectEqual(@as(?u32, 12), expectedEpisodeCount(.{ .id = "x", .name = "x", .status = "RELEASING", .total_episodes = 12, .next_airing_episode = 99 }));
    try std.testing.expectEqual(@as(?u32, null), expectedEpisodeCount(.{ .id = "x", .name = "x", .status = "NOT_YET_RELEASED", .next_airing_episode = 1 }));
    try std.testing.expectEqual(@as(?u32, null), expectedEpisodeCount(.{ .id = "x", .name = "x" }));
    try std.testing.expectEqual(@as(?u32, 5), expectedEpisodeCount(.{ .id = "x", .name = "x", .next_airing_episode = 6 }));
    // Hostile count clamped (ROD-359), not passed to alloc.
    try std.testing.expectEqual(@as(?u32, max_episode_hint), expectedEpisodeCount(.{ .id = "x", .name = "x", .status = "FINISHED", .total_episodes = 4_294_967_295 }));
    try std.testing.expectEqual(@as(?u32, max_episode_hint), expectedEpisodeCount(.{ .id = "x", .name = "x", .status = "RELEASING", .next_airing_episode = 4_000_000_000 }));
}

test "ListStatus.groupRank orders watching → planning → paused → completed → dropped" {
    // planning before paused by design.
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

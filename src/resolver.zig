//! Provider binding resolver (ROD-328).
//!
//! Tier-C half of provider-binding resolve: given a known AniList canonical and a play
//! provider that does not id-key on a canonical id (`SourceProvider.canonicalKey` null),
//! fuzzy-match the canonical against that provider's catalog-search results.
//!
//! Strong match direction (ROD-307): score provider candidates against the full AniList
//! record (title + episode count + year). Scorer mirrors `anilist.bestMatch` /
//! `candidateScore` and reuses `anilist.titleScore`. Same thresholds (best >= 1200,
//! margin >= 250). Below either guard: no match (unbound state, ROD-329).
//!
//! Pure: no network, no threads, no `SourceProvider`. Worker runs `provider.search` and
//! feeds results here.

const std = @import("std");
const domain = @import("domain.zig");
const anilist = @import("anilist.zig");

const Anime = domain.Anime;

/// Min best score to bind (mirrors `anilist.bestMatch`).
const best_floor: i32 = 1200;
/// Min lead over runner-up; near-ties refuse rather than guess.
const match_margin: i32 = 250;

/// Tier-B exact-id match (ROD-342). Tried before `bestProviderMatch`; no title floor.
/// Id agreement alone can bind (romaji vs English often fails every fuzzy floor).
///
/// Landmines: metadata that contradicts the id (eps/year) is treated as a mis-stamp and
/// skipped; a wrong bind is a silently persisted watchlist row. Among survivors,
/// corroborated (eps or year agrees) beats bare regardless of list order; bare still
/// binds when nothing is corroborated. First-hit within a class. No-op when neither side
/// carries ids (senshi falls through to fuzzy).
pub fn bestIdMatch(canonical: Anime, candidates: []const Anime) ?usize {
    var bare: ?usize = null;
    for (candidates, 0..) |cand, i| {
        const id_agrees =
            (canonical.anilist_id != null and cand.anilist_id != null and
                canonical.anilist_id.? == cand.anilist_id.?) or
            (canonical.mal_id != null and cand.mal_id != null and
                canonical.mal_id.? == cand.mal_id.?);
        if (!id_agrees) continue;
        if (idMatchContradicted(canonical, cand)) continue;
        if (idMatchCorroborated(canonical, cand)) return i;
        if (bare == null) bare = i;
    }
    return bare;
}

/// Strong-evidence veto on an id agreement. Episode gap > 3 when total is authoritative,
/// or year gap > 1. Missing metadata never contradicts. Overflow-safe via `absDiff`.
fn idMatchContradicted(canonical: Anime, cand: Anime) bool {
    const known_eps = canonical.total_episodes orelse 0;
    const cand_eps = candidateEpisodes(cand);
    if (known_eps > 0 and cand_eps > 0 and
        totalIsAuthoritative(canonical.status) and absDiff(known_eps, cand_eps) > 3)
        return true;
    if (canonical.year != null and cand.year != null and
        absDiff(canonical.year.?, cand.year.?) > 1)
        return true;
    return false;
}

/// Positive agreement beyond the id: eps within veto tolerance, or year within 1.
fn idMatchCorroborated(canonical: Anime, cand: Anime) bool {
    const known_eps = canonical.total_episodes orelse 0;
    const cand_eps = candidateEpisodes(cand);
    if (known_eps > 0 and cand_eps > 0 and absDiff(known_eps, cand_eps) <= 3) return true;
    if (canonical.year != null and cand.year != null and
        absDiff(canonical.year.?, cand.year.?) <= 1) return true;
    return false;
}

/// Best provider candidate for `canonical`, or null below floor / inside margin.
/// Same shape as `anilist.bestMatch`, opposite direction.
pub fn bestProviderMatch(canonical: Anime, candidates: []const Anime) ?usize {
    if (candidates.len == 0) return null;

    var best_idx: ?usize = null;
    var best_score: i32 = std.math.minInt(i32);
    var second_score: i32 = std.math.minInt(i32);

    for (candidates, 0..) |cand, i| {
        const score = candidateScore(canonical, cand);
        if (score > best_score) {
            second_score = best_score;
            best_score = score;
            best_idx = i;
        } else if (score > second_score) {
            second_score = score;
        }
    }

    const idx = best_idx orelse return null;
    if (best_score < best_floor) return null;
    if (second_score >= 0 and best_score - second_score < match_margin) return null;
    return idx;
}

/// Score one provider candidate against the known canonical. Title is the floor;
/// episode count and year earn the margin. Mirrors `anilist.candidateScore`.
fn candidateScore(canonical: Anime, cand: Anime) i32 {
    var score: i32 = std.math.minInt(i32) / 4;

    // Best title agreement over known × candidate titles.
    const known = [_]?[]const u8{ canonical.name, canonical.english_name, canonical.native_name };
    const cand_titles = [_]?[]const u8{ cand.name, cand.english_name, cand.native_name };
    for (known) |ko| {
        const k = ko orelse continue;
        if (k.len == 0) continue;
        for (cand_titles) |c| score = @max(score, anilist.titleScore(k, c));
    }
    if (score < 0) return score; // no title overlap → reject before tie-breakers

    const known_eps = canonical.total_episodes orelse 0;
    const cand_eps = candidateEpisodes(cand);
    if (known_eps > 0 and cand_eps > 0) {
        const diff = absDiff(known_eps, cand_eps);
        if (diff == 0) {
            score += 180;
        } else if (diff <= 1) {
            score += 120;
        } else if (diff <= 3) {
            score += 60;
        } else if (totalIsAuthoritative(canonical.status)) {
            // Authoritative total off by >3 either direction = different work. Hard reject
            // so a lone exact-title hit cannot bind movie↔series. RELEASING spared (partial
            // listing is legitimate). Use `diff` / absDiff, never `cand_eps + 2` (u32 overflow).
            return -4000;
        } else {
            score -= 120;
        }
    }

    if (canonical.year) |ky| {
        if (cand.year) |cy| {
            const diff = absDiff(ky, cy);
            if (diff == 0) {
                score += 120;
            } else if (diff == 1) {
                score += 40;
            } else {
                score -= 160;
            }
        }
    }

    return score;
}

/// Catalog total if present, else max(eps_sub, eps_dub); 0 skips the eps signal.
fn candidateEpisodes(cand: Anime) u32 {
    if (cand.total_episodes) |t| return t;
    return @max(cand.eps_sub, cand.eps_dub);
}

/// Whether `total_episodes` can drive the episode veto. True for settled status AND for
/// null/unknown (doubtful total should reject a wild gap, not mint a wrong bind).
/// False only for RELEASING/HIATUS. Deliberately NOT `domain.isStillAiring`: that defaults
/// null → still airing (spare); a mis-bind guard wants null → reject the wild gap.
fn totalIsAuthoritative(status: ?[]const u8) bool {
    const s = status orelse return true;
    if (std.ascii.eqlIgnoreCase(s, "RELEASING")) return false;
    if (std.ascii.eqlIgnoreCase(s, "HIATUS")) return false;
    return true;
}

fn absDiff(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

// ── tests ──────────────────────────────────────────────────────────────────────

test "bestIdMatch binds on mal_id agreement regardless of title (ROD-342)" {
    // Id match needs no title agreement (English catalog vs romaji fails every fuzzy floor).
    const canonical: Anime = .{ .id = "154587", .name = "Sousou no Frieren", .anilist_id = 154587, .mal_id = 52991 };
    const candidates = [_]Anime{
        .{ .id = "1443", .name = "Frieren: Beyond Journey's End Season 2", .mal_id = 58305 },
        .{ .id = "2454", .name = "Frieren: Beyond Journey's End", .mal_id = 52991 },
    };
    const idx = bestIdMatch(canonical, &candidates) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("2454", candidates[idx].id);
}

test "bestIdMatch binds on anilist_id when the provider embeds one" {
    const canonical: Anime = .{ .id = "1", .name = "X", .anilist_id = 999 };
    const candidates = [_]Anime{
        .{ .id = "a", .name = "Y", .anilist_id = 998 },
        .{ .id = "b", .name = "Z", .anilist_id = 999 },
    };
    const idx = bestIdMatch(canonical, &candidates) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("b", candidates[idx].id);
}

test "bestIdMatch skips a candidate whose metadata contradicts the id (mis-stamped MALID)" {
    // ROD-342: same mal_id but metadata screaming different work must not bind.
    const canonical: Anime = .{ .id = "1", .name = "Attack on Titan", .anilist_id = 16498, .mal_id = 16498, .total_episodes = 25, .year = 2013, .status = "FINISHED" };
    const decoy_only = [_]Anime{
        .{ .id = "666", .name = "Some Random 1998 Cooking OVA", .mal_id = 16498, .total_episodes = 1, .year = 1998 },
    };
    try std.testing.expect(bestIdMatch(canonical, &decoy_only) == null);

    const with_real = [_]Anime{
        .{ .id = "666", .name = "Some Random 1998 Cooking OVA", .mal_id = 16498, .total_episodes = 1, .year = 1998 },
        .{ .id = "42", .name = "Shingeki no Kyojin", .mal_id = 16498, .total_episodes = 25, .year = 2013 },
    };
    const idx = bestIdMatch(canonical, &with_real) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("42", with_real[idx].id);
}

test "bestIdMatch prefers a corroborated survivor over an earlier bare one (sparse decoy)" {
    // Sparse hostile stamp is uncontradictable; corroboration must outrank list order.
    const canonical: Anime = .{ .id = "1", .name = "Fullmetal Alchemist: Brotherhood", .anilist_id = 5114, .mal_id = 5114, .total_episodes = 64, .year = 2009, .status = "FINISHED" };
    const candidates = [_]Anime{
        .{ .id = "sparse-decoy", .name = "Totally Different Show", .mal_id = 5114 },
        .{ .id = "real", .name = "Fullmetal Alchemist: Brotherhood", .mal_id = 5114, .total_episodes = 64, .year = 2009 },
    };
    const idx = bestIdMatch(canonical, &candidates) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("real", candidates[idx].id);

    // Sparse alone still binds: absence of corroboration is not a veto.
    const sparse_only = [_]Anime{.{ .id = "sparse-decoy", .name = "Totally Different Show", .mal_id = 5114 }};
    try std.testing.expect(bestIdMatch(canonical, &sparse_only) != null);
}

test "bestIdMatch veto: bare metadata never contradicts; releasing spares the eps gap" {
    const canonical: Anime = .{ .id = "1", .name = "X", .mal_id = 52991, .total_episodes = 28, .year = 2023, .status = "FINISHED" };
    const bare = [_]Anime{.{ .id = "2454", .name = "Y", .mal_id = 52991 }};
    try std.testing.expect(bestIdMatch(canonical, &bare) != null);

    // RELEASING partial count must not trip the eps veto.
    const airing: Anime = .{ .id = "1", .name = "X", .mal_id = 59978, .total_episodes = 28, .year = 2026, .status = "RELEASING" };
    const partial = [_]Anime{.{ .id = "1443", .name = "Y", .mal_id = 59978, .total_episodes = 4, .year = 2026 }};
    try std.testing.expect(bestIdMatch(airing, &partial) != null);

    const wrong_year = [_]Anime{.{ .id = "9", .name = "Y", .mal_id = 59978, .year = 1998 }};
    try std.testing.expect(bestIdMatch(airing, &wrong_year) == null);
}

test "bestIdMatch is a no-op when either side carries no ids (senshi shape)" {
    // Tier-C: canonical has no mal_id; senshi embeds no anilist_id.
    const no_mal_canonical: Anime = .{ .id = "1", .name = "X", .anilist_id = 999 };
    const mal_only = [_]Anime{.{ .id = "52991", .name = "X", .mal_id = 52991 }};
    try std.testing.expect(bestIdMatch(no_mal_canonical, &mal_only) == null);

    const bare = [_]Anime{.{ .id = "a", .name = "X" }};
    const full: Anime = .{ .id = "1", .name = "X", .anilist_id = 999, .mal_id = 52991 };
    try std.testing.expect(bestIdMatch(full, &bare) == null);
    try std.testing.expect(bestIdMatch(full, &.{}) == null);
}

test "bestProviderMatch binds an exact title with episode + year agreement" {
    const canonical: Anime = .{
        .id = "154587",
        .name = "Sousou no Frieren",
        .anilist_id = 154587,
        .total_episodes = 28,
        .year = 2023,
    };
    const candidates = [_]Anime{
        .{ .id = "999", .name = "Unrelated Show", .total_episodes = 12, .year = 2019 },
        .{ .id = "52991", .name = "Sousou no Frieren", .total_episodes = 28, .year = 2023 },
    };
    const idx = bestProviderMatch(canonical, &candidates) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("52991", candidates[idx].id);
}

test "bestProviderMatch rejects when no candidate clears the title floor" {
    const canonical: Anime = .{ .id = "1", .name = "Sousou no Frieren", .anilist_id = 1 };
    const candidates = [_]Anime{
        .{ .id = "a", .name = "Naruto" },
        .{ .id = "b", .name = "Bleach" },
    };
    try std.testing.expect(bestProviderMatch(canonical, &candidates) == null);
}

test "bestProviderMatch rejects an ambiguous near-tie (margin guard)" {
    // Identical scores → margin 0 → refuse rather than guess.
    const canonical: Anime = .{ .id = "1", .name = "Frieren", .anilist_id = 1, .year = 2023 };
    const candidates = [_]Anime{
        .{ .id = "x", .name = "Frieren", .year = 2023 },
        .{ .id = "y", .name = "Frieren", .year = 2023 },
    };
    try std.testing.expect(bestProviderMatch(canonical, &candidates) == null);
}

test "bestProviderMatch reconciles a Season-N title form against the canonical" {
    // canonSeason (via titleScore) folds "2nd Season" / "Season 2" to the same token.
    const canonical: Anime = .{ .id = "1", .name = "Re:Zero 2nd Season", .anilist_id = 1, .total_episodes = 25 };
    const candidates = [_]Anime{
        .{ .id = "hit", .name = "Re:Zero Season 2", .total_episodes = 25 },
        .{ .id = "miss", .name = "Completely Different", .total_episodes = 12 },
    };
    const idx = bestProviderMatch(canonical, &candidates) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("hit", candidates[idx].id);
}

test "bestProviderMatch rejects a lone same-title different work by the settled-canonical episode veto" {
    // Exact title + no rival would clear floor/margin without the eps veto (movie vs series).
    const canonical: Anime = .{ .id = "1", .name = "Given", .anilist_id = 1, .total_episodes = 25, .status = "FINISHED" };
    const candidates = [_]Anime{
        .{ .id = "movie", .name = "Given", .total_episodes = 1 },
    };
    try std.testing.expect(bestProviderMatch(canonical, &candidates) == null);
}

test "bestProviderMatch still picks the series when both it and its movie are in the catalog" {
    const canonical: Anime = .{ .id = "1", .name = "Given", .anilist_id = 1, .total_episodes = 11, .status = "FINISHED" };
    const candidates = [_]Anime{
        .{ .id = "movie", .name = "Given", .total_episodes = 1 },
        .{ .id = "series", .name = "Given", .total_episodes = 11 },
    };
    const idx = bestProviderMatch(canonical, &candidates) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("series", candidates[idx].id);
}

test "bestProviderMatch spares a still-airing canonical whose provider lists fewer episodes" {
    const canonical: Anime = .{ .id = "1", .name = "One Piece", .anilist_id = 1, .total_episodes = 1100, .status = "RELEASING" };
    const candidates = [_]Anime{
        .{ .id = "op", .name = "One Piece", .total_episodes = 1050 },
    };
    const idx = bestProviderMatch(canonical, &candidates) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("op", candidates[idx].id);
}

test "bestProviderMatch rejects a same-title long-runner with far more episodes (symmetric veto)" {
    // Symmetric: settled 12-ep must not bind a lone same-title 500-ep runner either.
    const canonical: Anime = .{ .id = "1", .name = "X", .anilist_id = 1, .total_episodes = 12, .status = "FINISHED" };
    const candidates = [_]Anime{
        .{ .id = "long-runner", .name = "X", .total_episodes = 500 },
    };
    try std.testing.expect(bestProviderMatch(canonical, &candidates) == null);
}

test "bestProviderMatch applies the veto to an unclassified (null-status) canonical" {
    // null must not spare (that reopened the movie mis-bind this ticket fixed).
    const canonical: Anime = .{ .id = "1", .name = "Given", .anilist_id = 1, .total_episodes = 25, .status = null };
    const candidates = [_]Anime{
        .{ .id = "movie", .name = "Given", .total_episodes = 1 },
    };
    try std.testing.expect(bestProviderMatch(canonical, &candidates) == null);
}

test "bestProviderMatch does not overflow on a garbage huge episode count" {
    // Hostile total near u32 max must not crash (`cand_eps + 2` panicked ReleaseSafe).
    const canonical: Anime = .{ .id = "1", .name = "X", .anilist_id = 1, .total_episodes = 100, .status = "FINISHED" };
    const candidates = [_]Anime{
        .{ .id = "garbage", .name = "X", .total_episodes = std.math.maxInt(u32) },
    };
    try std.testing.expect(bestProviderMatch(canonical, &candidates) == null);
}

test "bestProviderMatch returns null on an empty catalog page" {
    const canonical: Anime = .{ .id = "1", .name = "Anything", .anilist_id = 1 };
    try std.testing.expect(bestProviderMatch(canonical, &.{}) == null);
}

test "candidateEpisodes prefers total, falls back to the larger per-track count" {
    try std.testing.expectEqual(@as(u32, 24), candidateEpisodes(.{ .id = "x", .name = "X", .total_episodes = 24, .eps_sub = 12 }));
    try std.testing.expectEqual(@as(u32, 12), candidateEpisodes(.{ .id = "x", .name = "X", .eps_sub = 12, .eps_dub = 6 }));
    try std.testing.expectEqual(@as(u32, 0), candidateEpisodes(.{ .id = "x", .name = "X" }));
}

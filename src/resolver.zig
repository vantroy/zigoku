//! Zigoku: provider binding resolver (ROD-328).
//!
//! The tier-C half of the provider-binding resolve: given a KNOWN canonical (an AniList
//! search hit, fully enriched) and a play provider that does NOT id-key on a canonical id
//! (`SourceProvider.canonicalKey` returned null), find the provider's own opaque id for
//! that show by fuzzy-matching the canonical against the provider's catalog-search results.
//!
//! This is the STRONG match direction (ROD-307): we score provider candidates against the
//! full known AniList record (title + episode count + year), not two mystery titles. The
//! scorer mirrors `anilist.bestMatch`/`candidateScore` and reuses `anilist.titleScore` so
//! the two matchers share ONE title-normalization rule. Same thresholds (best >= 1200,
//! margin >= 250): a lone title agreement clears the floor; episode-count and year are
//! tie-breakers that earn the margin. Below either guard the resolver reports no match
//! (the explicit unmatched state is ROD-329) rather than binding a guess.
//!
//! Pure and provider-agnostic: no network, no threads, no `SourceProvider`. The worker
//! (`workers.resolveSearchTask`) runs `provider.search` and feeds the results here.

const std = @import("std");
const domain = @import("domain.zig");
const anilist = @import("anilist.zig");

const Anime = domain.Anime;

/// Minimum score the best candidate must reach to be a match (mirrors
/// `anilist.bestMatch`); below it the provider is treated as not stocking the show.
const best_floor: i32 = 1200;
/// Minimum lead the best candidate must hold over the runner-up. Guards against
/// ambiguous near-ties (a season/spinoff that scores almost as high): an unclear
/// win is no win.
const match_margin: i32 = 250;

/// Pick the provider search result that best matches `canonical`, or null when nothing
/// clears the confidence floor or the win is too narrow to trust. `candidates` are one
/// provider's own catalog-search results (`domain.Anime` keyed by its opaque id); the
/// returned index selects the row whose `.id` is the binding. Same shape as
/// `anilist.bestMatch`, opposite direction (known canonical vs provider candidates).
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

/// Score one provider candidate against the known canonical. Title agreement is the
/// spine (a hard floor); episode-count and year proximity are the tie-breakers that
/// earn the margin. Mirrors `anilist.candidateScore`, reading the known side from the
/// canonical (title set + `total_episodes` + `year`, since a search hit carries no
/// per-track `eps_sub`/`eps_dub`) and the candidate side from the provider row.
fn candidateScore(canonical: Anime, cand: Anime) i32 {
    var score: i32 = std.math.minInt(i32) / 4;

    // Best title agreement over the cross product of known × candidate titles. A null or
    // empty candidate title scores a large negative in titleScore, so it never wins.
    const known = [_]?[]const u8{ canonical.name, canonical.english_name, canonical.native_name };
    const cand_titles = [_]?[]const u8{ cand.name, cand.english_name, cand.native_name };
    for (known) |ko| {
        const k = ko orelse continue;
        if (k.len == 0) continue;
        for (cand_titles) |c| score = @max(score, anilist.titleScore(k, c));
    }
    if (score < 0) return score; // no title overlap → reject before the tie-breakers

    // Episode-count agreement. Known = the canonical's authoritative total; candidate = the
    // provider's listed count (its total, or the larger per-track count).
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
        } else if (!domain.isStillAiring(canonical.status) and cand_eps + 2 < known_eps) {
            // A SETTLED canonical (FINISHED/CANCELLED, so its total is authoritative) whose
            // candidate lists far fewer episodes is a different, smaller work sharing the
            // title: a movie, OVA, or recap, not the series. Hard-reject (the anilist matcher's
            // veto, restored) so a lone exact-title hit cannot bind it. A still-airing canonical
            // legitimately lists fewer (not all episodes exist yet), so the veto is gated on
            // settled status.
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

/// The candidate's episode count for scoring: its catalog total if it carries one, else
/// the larger of the per-track counts (0 when it lists none, which skips the eps signal).
fn candidateEpisodes(cand: Anime) u32 {
    if (cand.total_episodes) |t| return t;
    return @max(cand.eps_sub, cand.eps_dub);
}

fn absDiff(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

// ── tests ──────────────────────────────────────────────────────────────────────

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
    // Two catalog rows with the identical matching title: the winner's lead over the
    // runner-up is 0, below the margin, so binding either would be a guess.
    const canonical: Anime = .{ .id = "1", .name = "Frieren", .anilist_id = 1, .year = 2023 };
    const candidates = [_]Anime{
        .{ .id = "x", .name = "Frieren", .year = 2023 },
        .{ .id = "y", .name = "Frieren", .year = 2023 },
    };
    try std.testing.expect(bestProviderMatch(canonical, &candidates) == null);
}

test "bestProviderMatch reconciles a Season-N title form against the canonical" {
    // The provider spells the season one way, the canonical another; canonSeason (via
    // titleScore) folds both to the same token so the match still lands.
    const canonical: Anime = .{ .id = "1", .name = "Re:Zero 2nd Season", .anilist_id = 1, .total_episodes = 25 };
    const candidates = [_]Anime{
        .{ .id = "hit", .name = "Re:Zero Season 2", .total_episodes = 25 },
        .{ .id = "miss", .name = "Completely Different", .total_episodes = 12 },
    };
    const idx = bestProviderMatch(canonical, &candidates) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("hit", candidates[idx].id);
}

test "bestProviderMatch rejects a lone same-title different work by the settled-canonical episode veto" {
    // A FINISHED 25-ep series whose ONLY catalog hit shares the exact title but is the 1-ep
    // movie: an exact-title score alone would clear the floor (no rival to trip the margin
    // guard), so without the episode veto this would silently bind the movie to the series.
    const canonical: Anime = .{ .id = "1", .name = "Given", .anilist_id = 1, .total_episodes = 25, .status = "FINISHED" };
    const candidates = [_]Anime{
        .{ .id = "movie", .name = "Given", .total_episodes = 1 },
    };
    try std.testing.expect(bestProviderMatch(canonical, &candidates) == null);
}

test "bestProviderMatch still picks the series when both it and its movie are in the catalog" {
    // With the real series present, the episode agreement (+180) plus the movie's veto lets
    // the series win decisively; the veto never suppresses a genuine match.
    const canonical: Anime = .{ .id = "1", .name = "Given", .anilist_id = 1, .total_episodes = 11, .status = "FINISHED" };
    const candidates = [_]Anime{
        .{ .id = "movie", .name = "Given", .total_episodes = 1 },
        .{ .id = "series", .name = "Given", .total_episodes = 11 },
    };
    const idx = bestProviderMatch(canonical, &candidates) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("series", candidates[idx].id);
}

test "bestProviderMatch spares a still-airing canonical whose provider lists fewer episodes" {
    // A RELEASING canonical legitimately has a partial provider listing (not all episodes
    // exist yet), so the settled-only veto must NOT fire: the match still lands.
    const canonical: Anime = .{ .id = "1", .name = "One Piece", .anilist_id = 1, .total_episodes = 1100, .status = "RELEASING" };
    const candidates = [_]Anime{
        .{ .id = "op", .name = "One Piece", .total_episodes = 1050 },
    };
    const idx = bestProviderMatch(canonical, &candidates) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("op", candidates[idx].id);
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

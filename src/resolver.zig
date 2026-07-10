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
//! rather than binding a guess (the add-path miss becomes the explicit unbound state, ROD-329).
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

/// Tier-B exact-id match (ROD-342): the first candidate whose embedded canonical id
/// (anilist_id or mal_id, backfilled by a tier-B provider's catalog search, e.g. anipub's
/// /api/info MALID) agrees with the canonical's, and whose other metadata does not
/// contradict it. It is tried BEFORE `bestProviderMatch` and needs no title
/// floor/margin (the whole point: a romaji canonical vs an English catalog title
/// fails every fuzzy floor while the id still binds). But the id rides
/// provider-entered metadata, so a candidate whose episode count or year screams
/// "different work" is treated as a mis-stamped id and skipped, never bound: a
/// wrong bind is a silently persisted watchlist row, the one outcome this whole
/// resolver is designed to refuse. Among survivors, a CORROBORATED candidate
/// (episode count or year positively agrees) beats a bare one regardless of list
/// order, so a metadata-sparse decoy stamped with the target's id cannot outrank
/// the corroborated real entry behind it; a bare survivor still binds when no
/// corroborated one exists (a failed info backfill must not strand a legitimate
/// bind). Ties within a class break first-hit: same canonical id = same work
/// (the multi-binding case ROD-313 already collapses). No-op for a provider
/// whose search results carry no ids (senshi); falls through to fuzzy.
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

/// Strong-evidence veto on an id agreement. Mirrors the fuzzy path's episode veto
/// (authoritative canonical total vs a wild gap, either direction) and adds a year
/// check (same work premieres in the same year; tolerance 1 absorbs cour-boundary
/// drift). Absence of metadata never contradicts: a bare candidate with just an id
/// still binds. Overflow-safe via `absDiff`, same lesson as ROD-328.
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

/// Positive metadata agreement beyond the id itself: episode count inside the
/// veto tolerance, or the year inside its. The uncontradicted-but-unproven
/// middle (fields absent on either side) is neither corroborated nor vetoed.
fn idMatchCorroborated(canonical: Anime, cand: Anime) bool {
    const known_eps = canonical.total_episodes orelse 0;
    const cand_eps = candidateEpisodes(cand);
    if (known_eps > 0 and cand_eps > 0 and absDiff(known_eps, cand_eps) <= 3) return true;
    if (canonical.year != null and cand.year != null and
        absDiff(canonical.year.?, cand.year.?) <= 1) return true;
    return false;
}

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
        } else if (totalIsAuthoritative(canonical.status)) {
            // A canonical with an authoritative total whose candidate is off by more than 3 in
            // EITHER direction is a different work sharing the title: a movie/OVA with far fewer
            // episodes, or an unrelated long-runner with far more. Hard-reject so a lone
            // exact-title hit cannot bind it. A still-releasing canonical is spared (its provider
            // listing is legitimately partial). Compares via `diff`, never `cand_eps + 2`, so a
            // garbage or hostile episode count near u32 max cannot overflow-panic.
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

/// Whether the canonical's `total_episodes` can be trusted as a final count for the episode
/// veto. True for a settled show (FINISHED/CANCELLED) AND for an unknown/null status: a
/// doubtful count should reject a wild-episode-gap candidate rather than mint a wrong bind.
/// False only while a show is actively RELEASING or on HIATUS, where the provider legitimately
/// lists fewer episodes than the planned total. Deliberately NOT `domain.isStillAiring`: its
/// completion-side default (null means still airing, so spare it) is the opposite bias from
/// what a mis-bind guard wants (null means doubtful, so reject the wild gap).
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
    // The tier-B point: an id match needs no title agreement at all; anipub's
    // English Name vs the canonical romaji would fail every fuzzy floor.
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
    // Chaos-pass repro (ROD-342): a decoy row carrying the canonical's mal_id but
    // metadata screaming "different work" (1-ep 1998 OVA vs a settled 25-ep 2013
    // series) must NOT bind on the bare id. Without the veto this returned index 0.
    const canonical: Anime = .{ .id = "1", .name = "Attack on Titan", .anilist_id = 16498, .mal_id = 16498, .total_episodes = 25, .year = 2013, .status = "FINISHED" };
    const decoy_only = [_]Anime{
        .{ .id = "666", .name = "Some Random 1998 Cooking OVA", .mal_id = 16498, .total_episodes = 1, .year = 1998 },
    };
    try std.testing.expect(bestIdMatch(canonical, &decoy_only) == null);

    // With a clean same-id row later in the list, the scan skips the decoy and
    // binds the survivor instead of giving up.
    const with_real = [_]Anime{
        .{ .id = "666", .name = "Some Random 1998 Cooking OVA", .mal_id = 16498, .total_episodes = 1, .year = 1998 },
        .{ .id = "42", .name = "Shingeki no Kyojin", .mal_id = 16498, .total_episodes = 25, .year = 2013 },
    };
    const idx = bestIdMatch(canonical, &with_real) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("42", with_real[idx].id);
}

test "bestIdMatch prefers a corroborated survivor over an earlier bare one (sparse decoy)" {
    // Chaos re-verify find (ROD-342): a minimal hostile stamp ({"MALID":target},
    // nothing else) is uncontradictable, so first-hit-wins let a sparse decoy
    // ahead in the list beat the corroborated real entry behind it. Corroboration
    // now outranks list order.
    const canonical: Anime = .{ .id = "1", .name = "Fullmetal Alchemist: Brotherhood", .anilist_id = 5114, .mal_id = 5114, .total_episodes = 64, .year = 2009, .status = "FINISHED" };
    const candidates = [_]Anime{
        .{ .id = "sparse-decoy", .name = "Totally Different Show", .mal_id = 5114 },
        .{ .id = "real", .name = "Fullmetal Alchemist: Brotherhood", .mal_id = 5114, .total_episodes = 64, .year = 2009 },
    };
    const idx = bestIdMatch(canonical, &candidates) orelse return error.TestExpectationFailed;
    try std.testing.expectEqualStrings("real", candidates[idx].id);

    // A sparse survivor alone still binds: absence of corroboration is not a veto
    // (anipub's info backfill legitimately fails per candidate).
    const sparse_only = [_]Anime{.{ .id = "sparse-decoy", .name = "Totally Different Show", .mal_id = 5114 }};
    try std.testing.expect(bestIdMatch(canonical, &sparse_only) != null);
}

test "bestIdMatch veto: bare metadata never contradicts; releasing spares the eps gap" {
    // A candidate with ONLY the id (anipub info fetch failed for eps/year) still binds.
    const canonical: Anime = .{ .id = "1", .name = "X", .mal_id = 52991, .total_episodes = 28, .year = 2023, .status = "FINISHED" };
    const bare = [_]Anime{.{ .id = "2454", .name = "Y", .mal_id = 52991 }};
    try std.testing.expect(bestIdMatch(canonical, &bare) != null);

    // A RELEASING canonical legitimately sees a partial provider count (ongoing
    // show): the eps veto must not fire. Same sparing rule as the fuzzy veto.
    const airing: Anime = .{ .id = "1", .name = "X", .mal_id = 59978, .total_episodes = 28, .year = 2026, .status = "RELEASING" };
    const partial = [_]Anime{.{ .id = "1443", .name = "Y", .mal_id = 59978, .total_episodes = 4, .year = 2026 }};
    try std.testing.expect(bestIdMatch(airing, &partial) != null);

    // But a wild year gap contradicts even for a releasing show.
    const wrong_year = [_]Anime{.{ .id = "9", .name = "Y", .mal_id = 59978, .year = 1998 }};
    try std.testing.expect(bestIdMatch(airing, &wrong_year) == null);
}

test "bestIdMatch is a no-op when either side carries no ids (senshi shape)" {
    // senshi tier-C: candidates are mal-keyed but the canonical reaching the search
    // path has no mal_id (that's WHY it's tier-C), and senshi embeds no anilist_id.
    const no_mal_canonical: Anime = .{ .id = "1", .name = "X", .anilist_id = 999 };
    const mal_only = [_]Anime{.{ .id = "52991", .name = "X", .mal_id = 52991 }};
    try std.testing.expect(bestIdMatch(no_mal_canonical, &mal_only) == null);

    // Bare tier-C candidates (no ids at all) never id-match.
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

test "bestProviderMatch rejects a same-title long-runner with far more episodes (symmetric veto)" {
    // The veto is symmetric: a settled 12-ep canonical must not bind a lone same-title 500-ep
    // long-runner either. Before this it only rejected the far-FEWER (movie) direction.
    const canonical: Anime = .{ .id = "1", .name = "X", .anilist_id = 1, .total_episodes = 12, .status = "FINISHED" };
    const candidates = [_]Anime{
        .{ .id = "long-runner", .name = "X", .total_episodes = 500 },
    };
    try std.testing.expect(bestProviderMatch(canonical, &candidates) == null);
}

test "bestProviderMatch applies the veto to an unclassified (null-status) canonical" {
    // A null/unknown status must NOT spare the candidate (that reopened the exact movie
    // mis-bind this ticket fixed): a doubtful total rejects a wild-episode-gap hit.
    const canonical: Anime = .{ .id = "1", .name = "Given", .anilist_id = 1, .total_episodes = 25, .status = null };
    const candidates = [_]Anime{
        .{ .id = "movie", .name = "Given", .total_episodes = 1 },
    };
    try std.testing.expect(bestProviderMatch(canonical, &candidates) == null);
}

test "bestProviderMatch does not overflow on a garbage huge episode count" {
    // A hostile or broken provider row with total_episodes near u32 max must not crash the
    // scorer: a `cand_eps + 2` compare panicked in the shipped ReleaseSafe build. The settled
    // veto rejects it cleanly via absDiff instead.
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

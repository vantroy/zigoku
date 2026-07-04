//! Current-selection resolution (ROD-277), carved out of app.zig.
//!
//! One closed, side-effect-free concern: given the current navigation state,
//! resolve *which* anime/record is focused across Browse / History / Discover /
//! Detail, and format the derived display strings (the top-bar season chip, the
//! detail meta-rail fields) into App-owned scratch buffers. Every function here
//! is a pure read of App state plus at most one read-only `store.getAnime`; none
//! spawn work, write the store, or touch toast/undo — that transport stays on
//! App. The App methods that used to live here are now one-line forwards into
//! this module. Like the per-view passes (view/*.zig), the functions here thread
//! `*App` rather than owning state — they are not App-independent the way the
//! CoverState/SettingsState subsystem carves are; only the two type re-exports
//! below (DetailRenderInfo, MetaField) match that re-export idiom.
//!
//! Lifetime note: the formatters write into `chip_buf` / `detail_meta_buf` /
//! `detail_meta_fields`, which are App-owned precisely because vaxis cells hold a
//! *slice* into the text and the frame isn't emitted until after the pass returns
//! (the ROD-141 lifetime trap). They must not be moved to stack locals here.

const std = @import("std");
const vaxis = @import("vaxis");
const domain = @import("../domain.zig");
const store_mod = @import("../store.zig");
const source_mod = @import("../source.zig");
const event_mod = @import("event.zig");
const app_mod = @import("app.zig");

const Allocator = std.mem.Allocator;
const Anime = domain.Anime;
const AnimeRecord = store_mod.AnimeRecord;
const SourceProvider = source_mod.SourceProvider;
const Loop = event_mod.Loop;
const App = app_mod.App;

pub fn selectedAnime(self: *const App) ?Anime {
    if (self.search.results.items.len == 0 or self.list_cursor >= self.search.results.items.len) return null;
    return self.search.results.items[self.list_cursor];
}

/// The Discover card under the grid cursor (ROD-239) — the show a zoom opened
/// from Discover (`detail_origin == .discover`) is committed to. Reads the
/// active window's slot, so it carries that window's `view_count`.
pub fn selectedDiscoverAnime(self: *const App) ?Anime {
    const items = self.discover.activeSlot().results.items;
    if (self.discover.cursor >= items.len) return null;
    return items[self.discover.cursor];
}

/// Terminal cell size in pixels as `.{ w, h }`, or `.{ 0, 0 }` when the terminal
/// doesn't report pixel metrics (tmux/headless). Discover sizes its cover boxes
/// from this so a poster fills its width (ROD-247); 0 → the fixed fallback height.
pub fn cellPx(self: *const App) [2]u16 {
    if (self.term_cols == 0 or self.term_rows == 0 or self.term_x_pixel == 0 or self.term_y_pixel == 0)
        return .{ 0, 0 };
    return .{ self.term_x_pixel / self.term_cols, self.term_y_pixel / self.term_rows };
}

/// ROD-186: the top-bar season/year chip text (e.g. "冬 2024"), formatted into
/// the App-owned `chip_buf`. It MUST be App-owned, not a stack local: vaxis
/// cells hold a *slice* into the segment text and the frame isn't emitted until
/// after this returns (the same lifetime trap as the detail chip, ROD-141).
/// Returns "" when no chip should render.
///
/// Content rule (Rod): show the currently selected show's season+year when a
/// row is selected and both are known; otherwise the current real-world cour
/// from the system clock. The detail zoom is the exception — it is committed to
/// one show, so it shows only that show's season with no cour fallback (an
/// unenriched show shows no chip, never a misleading season). Settings has no
/// show context (per the header layout) and shows no chip.
pub fn topBarSeasonChip(self: *App) []const u8 {
    switch (self.active_view) {
        .settings => return "",
        // The Discover GRID chip reads the selected card's season once it's
        // batch-enriched (ROD-247): the popular feed nulls season/airedStart, so
        // a freshly-loaded card shows no chip until the page batch lands, then
        // the kanji+year appears. An unenriched / no-id card stays season-null →
        // "" (never a misleading cour fallback here, matching the zoom arm).
        .discover => {
            const a = selectedDiscoverAnime(self) orelse return "";
            if (a.season != null and a.year != null)
                return seasonChipText(self, a.season, a.year);
            return "";
        },
        .detail => switch (self.detail_origin) {
            .browse => {
                const a = selectedAnime(self) orelse return "";
                return seasonChipText(self, a.season, a.year);
            },
            .history => {
                const r = self.selectedHistoryRecord() orelse return "";
                return seasonChipText(self, historySeason(r), historyYear(r));
            },
            .discover => {
                const a = selectedDiscoverAnime(self) orelse return "";
                return seasonChipText(self, a.season, a.year);
            },
        },
        .browse => {
            if (selectedAnime(self)) |a| {
                if (a.season != null and a.year != null)
                    return seasonChipText(self, a.season, a.year);
            }
            return courChip(self);
        },
        .history => {
            if (self.selectedHistoryRecord()) |r| {
                const sea = historySeason(r);
                const yr = historyYear(r);
                if (sea != null and yr != null) return seasonChipText(self, sea, yr);
            }
            return courChip(self);
        },
    }
}

/// Format a season+year into `chip_buf`. "" if either half is unknown — the
/// chip is the kanji glyph plus the year; a season with no year (or vice
/// versa) isn't renderable as "季 YYYY" (§2.3: never an empty/partial chip).
fn seasonChipText(self: *App, season: ?domain.Season, year: ?u32) []const u8 {
    const sea = season orelse return "";
    const yr = year orelse return "";
    return std.fmt.bufPrint(&self.chip_buf, "{s} {d}", .{ sea.kanji(), yr }) catch "";
}

/// The current real-world cour, formatted into `chip_buf` — the no-selection
/// fallback for the Browse/History chip. Reads `now_ms` (wall-clock epoch ms,
/// refreshed every .tick) rather than re-querying the clock, so the render pass
/// stays io-free. Before the first tick `now_ms` is 0; we render no chip then
/// rather than flash 冬 1970 for one frame.
fn courChip(self: *App) []const u8 {
    if (self.now_ms <= 0) return "";
    const c = currentCour(self.now_ms);
    return seasonChipText(self, c.season, c.year);
}

/// Whether `a` is a current-cour release — the basis for the Discover NEW badge
/// (ROD-239). True when the show's season+year match the current real-world
/// cour. Needs `now_ms` (≤0 before the first tick → false, so no NEW flashes on
/// frame zero). The TOP badge is pure rank (#1) and is decided render-side.
pub fn isNewRelease(self: *const App, a: Anime) bool {
    if (self.now_ms <= 0) return false;
    const year = a.year orelse return false;
    const season = a.season orelse return false;
    const c = currentCour(self.now_ms);
    return year == c.year and season == c.season;
}

/// The broadcast cour for an epoch-ms instant, using AniList's season
/// boundaries (domain.Season.fromMonth) with December rolled into next year's
/// Winter cour — so the ambient chip names the same cour AniList would.
fn currentCour(now_ms: i64) struct { season: domain.Season, year: u32 } {
    const secs: u64 = @intCast(@divFloor(now_ms, std.time.ms_per_s));
    const yd = (std.time.epoch.EpochSeconds{ .secs = secs }).getEpochDay().calculateYearDay();
    const month = yd.calculateMonthDay().month.numeric();
    const year: u32 = if (month == 12) @as(u32, yd.year) + 1 else yd.year;
    return .{ .season = domain.Season.fromMonth(month), .year = year };
}

fn historySeason(r: AnimeRecord) ?domain.Season {
    return if (r.season) |tag| domain.Season.fromString(tag) else null;
}

fn historyYear(r: AnimeRecord) ?u32 {
    return if (r.year) |x| std.math.cast(u32, x) else null;
}

/// A borrowed view: the returned `Anime`'s slice fields (name, genres,
/// status, …) alias `rec`'s arena memory — this is NOT an ownership transfer.
/// Used transiently on the stack within render/nav; never store it past the
/// record's arena and never hand it to `freeOwnedAnime` (that frees gpa-owned
/// shapes; use `hydrateAnimeFromRecord` when you need a gpa-owned copy).
pub fn animeFromHistoryRecord(rec: AnimeRecord) Anime {
    return .{
        .id = rec.source_id,
        .name = rec.title,
        .english_name = rec.title_english,
        .native_name = rec.native_name,
        .mal_id = if (rec.mal_id) |x| std.math.cast(u64, x) else null,
        .anilist_id = if (rec.anilist_id) |x| std.math.cast(u64, x) else null,
        .thumb = rec.cover_url,
        .total_episodes = if (rec.total_episodes) |x| std.math.cast(u32, x) else null,
        .year = if (rec.year) |x| std.math.cast(u32, x) else null,
        .season = if (rec.season) |tag| domain.Season.fromString(tag) else null,
        .start_date = rec.startDate(),
        .status = rec.status,
        .description = rec.description,
        .genres = rec.genres,
        .studios = rec.studios,
        .score = if (rec.score) |x| std.math.cast(u32, x) else null,
        .kind = rec.kind,
        .duration = if (rec.duration) |x| std.math.cast(u32, x) else null,
        .source_material = rec.source_material,
        .rank = if (rec.rank) |x| std.math.cast(u32, x) else null,
        .rank_type = rec.rank_type,
        .rank_year = if (rec.rank_year) |x| std.math.cast(u32, x) else null,
        .next_airing_at = rec.next_airing_at,
        .next_airing_episode = if (rec.next_airing_episode) |x| std.math.cast(u32, x) else null,
        .country = rec.country,
    };
}

/// Whether a history-origin detail surface is active *and focused* — either
/// the persistent two-pane with the detail pane focused (active_view ==
/// .history, active_pane == .detail) or the full-screen zoom promoted from it
/// (active_view == .detail, detail_origin == .history). ROD-170 unified these:
/// both resolve the focused history record as the detail show, so the source/
/// status/record helpers and the play path treat them identically.
fn historyDetailActive(self: *const App) bool {
    return (self.active_view == .history and self.active_pane == .detail) or
        (self.active_view == .detail and self.detail_origin == .history);
}

pub fn currentDetailAnime(self: *const App) ?Anime {
    return switch (self.active_view) {
        .browse => if (self.active_pane == .detail) selectedAnime(self) else null,
        .detail => switch (self.detail_origin) {
            .browse => selectedAnime(self),
            .history => if (self.selectedHistoryRecord()) |rec| animeFromHistoryRecord(rec) else null,
            .discover => selectedDiscoverAnime(self),
        },
        // ROD-170: the focused record is the "actively-focused detail show"
        // only when the detail pane is focused — list focus must not let the
        // play/cache paths fire against a merely-previewed show.
        .history => if (self.active_pane == .detail)
            (if (self.selectedHistoryRecord()) |rec| animeFromHistoryRecord(rec) else null)
        else
            null,
        .settings => null,
        // Discover is single-pane: no in-view detail show (Enter opens the
        // standalone zoom, handled under .detail above).
        .discover => null,
    };
}

/// Whether the interactive episode grid should render in the detail pane — true
/// only for an actively-focused detail show (currentDetailAnime), not a mere
/// preview. A list-focused preview is null there, so a stale grid from a prior
/// detail visit can't bleed in (ROD-222: H from a focused History detail into
/// Browse leaves episodes.results loaded, and the Browse two-pane draws every
/// frame). Mirrors the gridless History preview and ROD-202's "grid on detail
/// entry, not on list hover." A render decision lifted to a testable predicate.
pub fn episodeGridVisible(self: *const App) bool {
    return currentDetailAnime(self) != null;
}

fn renderedDetailAnime(self: *const App) ?Anime {
    return switch (self.active_view) {
        .browse => selectedAnime(self),
        .detail => switch (self.detail_origin) {
            .browse => selectedAnime(self),
            .history => if (self.selectedHistoryRecord()) |rec| animeFromHistoryRecord(rec) else null,
            .discover => selectedDiscoverAnime(self),
        },
        // ROD-170: the preview pane always shows the focused record, whichever
        // pane has focus — the cover/metadata track the list cursor like Browse.
        .history => if (self.selectedHistoryRecord()) |rec| animeFromHistoryRecord(rec) else null,
        .settings => null,
        .discover => null, // single-pane; no in-view detail preview
    };
}

/// The show whose cover should be synced from the current navigation state.
/// When a preview/detail pane is on-screen alongside the list, this is the
/// list cursor, so the cover tracks the cursor like the cheap synchronous
/// fields already do via renderedDetailAnime:
///   - split browse (cols >= 60, list pane active): the results cursor;
///   - two-pane history (cols >= pane_split_min, ROD-170): the focused record.
/// Everywhere else it defers to currentDetailAnime's "actively-focused show"
/// contract, which is load-bearing for play/cache/stale-check paths and must
/// not shift (ROD-156).
pub fn detailSyncTarget(self: *const App) ?Anime {
    if (self.active_view == .browse and self.active_pane == .list and self.term_cols >= 60) {
        return selectedAnime(self);
    }
    if (self.active_view == .history and self.term_cols >= App.pane_split_min) {
        return if (self.selectedHistoryRecord()) |rec| animeFromHistoryRecord(rec) else null;
    }
    return currentDetailAnime(self);
}

/// The incremental list-scroll keys — j/k and ↓/↑. The cover-settle debounce
/// arms only for these: jump keys (g/G), filter input, and view/pane switches
/// all move the cursor too, but they're *discrete settle points*, so the cover
/// should sync at once rather than wait out the scroll debounce (ROD-202 review:
/// the cursor-delta proxy alone misfired on all three).
pub fn isListScrollKey(key: vaxis.Key) bool {
    return key.matches('j', .{}) or key.matches('k', .{}) or
        key.matches(vaxis.Key.down, .{}) or key.matches(vaxis.Key.up, .{});
}

/// Whether a list-cursor move changes detailSyncTarget — i.e. the cover preview
/// is on-screen and tracks the cursor (the two cursor-driven branches above).
/// Elsewhere the cover follows the focused detail, which a cursor move doesn't
/// touch, so no settle debounce is needed. Gates the cover-settle timer (ROD-202).
pub fn coverTracksCursor(self: *const App) bool {
    if (self.active_view == .browse and self.active_pane == .list and self.term_cols >= 60) {
        return self.search.results.items.len > 0;
    }
    return self.active_view == .history and self.term_cols >= App.pane_split_min;
}

/// Resolve the cover target from nav state and hand the primitives to the
/// subsystem (CoverState never reaches into selection state itself — ROD-160).
/// Called immediately for discrete nav (pane/view switch) and from the .tick
/// settle for cursor-tracked scrolling (ROD-202).
pub fn syncCover(self: *App, loop: *Loop, io: std.Io, provider: SourceProvider) void {
    const anime = detailSyncTarget(self);
    const started = self.cover.sync(
        self.gpa,
        loop,
        io,
        provider,
        &self.cover_caches,
        self.now_ms,
        if (anime) |a| a.id else null,
        if (anime) |a| a.thumb else null,
    );
    if (started) self.async_start_ms = self.now_ms;
}

pub const DetailRenderInfo = struct {
    anime: ?Anime,
    title: []const u8,
};

pub fn detailRenderInfo(self: *App) DetailRenderInfo {
    const anime = renderedDetailAnime(self);
    const title: []const u8 = if (anime) |a|
        if (a.name.len > 0) a.name else "—"
    else
        "—";
    return .{ .anime = anime, .title = title };
}

/// One detail-metadata field (ROD-260). Both the compact `drawMetaLine` and
/// the roomy `drawMetaRail` render from a shared, ordered `[]MetaField`, so
/// the two forms can't drift — same source, same order, same value strings.
pub const MetaField = struct {
    /// Rail-form label ("Episodes"/"Format"/"Studios") — ≤ 8 chars, the rail
    /// aligns values at a fixed column past the 8-col label gutter.
    label: []const u8,
    /// The value, identical in both forms: the rail draws it after the label,
    /// the compact line joins it with `·`. Formatted values live in the
    /// App-owned buffers above so vaxis's slice outlives the frame.
    value: []const u8,
    /// Compact-line-only unit suffix (" eps") for a field whose rail label
    /// already implies the unit — empty for everything else. Lets `Episodes 13`
    /// (rail) and `13 eps` (line) share one `value` without a second string.
    unit: []const u8 = "",
    /// Render `value` in `fg3` (dim) rather than `fg2` — the "? eps" count
    /// degrade only; present enrichment is always `fg2`.
    dim: bool = false,
    /// ROD-261: this field appears ONLY in the labeled rail, never on the compact
    /// line — `drawMetaLine` skips it. Rank is the sole rail-only field (verbose,
    /// lowest priority); it still rides the one ordered list, so the two forms
    /// stay in sync everywhere else.
    rail_only: bool = false,
};

/// The ordered detail-metadata fields (ROD-260), highest-priority first so a
/// height-starved rail sheds from the bottom (Episodes, emitted first, never
/// drops). Phase 1 ships the enrichment that survives to the store: Episodes
/// (always) and Format (the persisted `kind`) — no network, no schema change.
/// The AniList-enrichment follow-up slots studios/source/duration between
/// Format and the tail (and a rail-only rank) once those fields are fetched
/// and persisted; because both renderers iterate the list generically, that
/// lands here as data only — no renderer change. A field is emitted only when
/// it has a value (§9.1: no empty segment, no orphan `·`, no bare rail row);
/// Episodes is the floor, degrading to a dim "?" so neither form renders empty.
pub fn detailMetaFields(self: *App) []const MetaField {
    var n: usize = 0;
    const a = renderedDetailAnime(self) orelse {
        self.detail_meta_fields[0] = .{ .label = "Episodes", .value = "?", .unit = " eps", .dim = true };
        return self.detail_meta_fields[0..1];
    };

    // Episodes — the floor field. fg2 real count when either the per-track
    // count or the AniList total is known, else a dim "?" degrade.
    const eps = a.episodeCount(self.translation);
    const total: ?u32 = if (eps > 0) eps else a.total_episodes;
    if (total) |t| {
        const v = std.fmt.bufPrint(&self.detail_meta_buf, "{d}", .{t}) catch "?";
        self.detail_meta_fields[n] = .{ .label = "Episodes", .value = v, .unit = " eps" };
    } else {
        self.detail_meta_fields[n] = .{ .label = "Episodes", .value = "?", .unit = " eps", .dim = true };
    }
    n += 1;

    // Format (AniList `kind`, e.g. "TV") — omitted entirely when absent.
    if (a.kind) |kind| {
        if (kind.len > 0) {
            self.detail_meta_fields[n] = .{ .label = "Format", .value = kind };
            n += 1;
        }
    }

    // Source (ROD-261) — adaptation origin, prettified from the raw AniList enum
    // (LIGHT_NOVEL → "Light novel"). Slotted between Format and Duration per §5.3a;
    // omitted when absent.
    if (a.source_material) |src| {
        const v = formatSource(&self.detail_source_buf, src);
        if (v.len > 0) {
            self.detail_meta_fields[n] = .{ .label = "Source", .value = v };
            n += 1;
        }
    }

    // Duration (ROD-261) — per-episode runtime as "N min", slotted between Source
    // and Studios per §5.3a. Omitted when null or zero (a 0-minute runtime is a
    // missing value, not a fact).
    if (a.duration) |dur| {
        if (dur > 0) {
            const v = std.fmt.bufPrint(&self.detail_duration_buf, "{d} min", .{dur}) catch "";
            if (v.len > 0) {
                self.detail_meta_fields[n] = .{ .label = "Duration", .value = v };
                n += 1;
            }
        }
    }

    // Studios (ROD-261) — main animation studios, collapse-formatted A / A, B /
    // A, B +N. Rail tail (lowest visible priority for now), so a height-starved
    // rail sheds it first; omitted outright when the list is empty (§9.1). Source
    // will later slot between Format and Duration per §5.3a.
    if (a.studios.len > 0) {
        const v = formatStudios(&self.detail_studios_buf, a.studios);
        if (v.len > 0) {
            self.detail_meta_fields[n] = .{ .label = "Studios", .value = v };
            n += 1;
        }
    }

    // Rank (ROD-261) — rail-only (never on the compact line), the verbose standing
    // last in priority order. Emits only with both a position and a type; a
    // contextual pick carries its year, an all-time one doesn't (§5.3a).
    if (a.rank) |rank| {
        if (a.rank_type) |rtype| {
            const v = formatRank(&self.detail_rank_buf, rank, rtype, a.rank_year);
            if (v.len > 0) {
                self.detail_meta_fields[n] = .{ .label = "Rank", .value = v, .rail_only = true };
                n += 1;
            }
        }
    }

    return self.detail_meta_fields[0..n];
}

/// Prettify the raw AniList `source` enum for the rail (ROD-261): underscores to
/// spaces, everything lowercased, first letter capitalized — `LIGHT_NOVEL` →
/// `Light novel`, `ORIGINAL` → `Original`. Writes into the App-owned `buf`.
fn formatSource(buf: []u8, raw: []const u8) []const u8 {
    if (raw.len == 0) return "";
    var n: usize = 0;
    for (raw) |ch| {
        if (n >= buf.len) break;
        buf[n] = if (ch == '_') ' ' else std.ascii.toLower(ch);
        n += 1;
    }
    if (n > 0) buf[0] = std.ascii.toUpper(buf[0]);
    return buf[0..n];
}

/// Compose the rail-only Rank value (ROD-261): `#{rank} {type} {year}` for a
/// contextual pick, `#{rank} {type}` for an all-time one. The type is lowercased
/// (`RATED` → `rated`); the season name is deliberately dropped — the header's
/// season/year chip already carries that context (§5.3a).
fn formatRank(buf: []u8, rank: u32, rank_type: []const u8, rank_year: ?u32) []const u8 {
    var tbuf: [16]u8 = undefined;
    var tn: usize = 0;
    for (rank_type) |ch| {
        if (tn >= tbuf.len) break;
        tbuf[tn] = std.ascii.toLower(ch);
        tn += 1;
    }
    const tl = tbuf[0..tn];
    return if (rank_year) |y|
        std.fmt.bufPrint(buf, "#{d} {s} {d}", .{ rank, tl, y }) catch ""
    else
        std.fmt.bufPrint(buf, "#{d} {s}", .{ rank, tl }) catch "";
}

/// Collapse a studio list to the rail form: `A`, `A, B`, or `A, B +N` (ROD-261,
/// §5.3a). Caps at two named studios — mirroring the §3.8a genre-glyph cap — so a
/// long co-production credit can't blow the rail's 8-col gutter; the overflow
/// rides a `+N` suffix. Writes into the App-owned `buf` (slice must outlive the
/// frame); a name too long for `buf` degrades to the borrowed first name, whose
/// lifetime matches the field's `a` exactly as Format's borrowed `kind` does.
fn formatStudios(buf: []u8, studios: []const []const u8) []const u8 {
    return switch (studios.len) {
        0 => "",
        1 => std.fmt.bufPrint(buf, "{s}", .{studios[0]}) catch studios[0],
        2 => std.fmt.bufPrint(buf, "{s}, {s}", .{ studios[0], studios[1] }) catch studios[0],
        else => std.fmt.bufPrint(buf, "{s}, {s} +{d}", .{ studios[0], studios[1], studios.len - 2 }) catch studios[0],
    };
}

pub fn currentDetailSourceName(self: *const App, provider: SourceProvider) []const u8 {
    if (historyDetailActive(self)) {
        if (self.selectedHistoryRecord()) |rec| return rec.source;
    }
    return provider.name();
}

/// Resolve the history record whose cursor should seed the episode grid, or
/// null when the current nav state isn't history-origin detail. The episode
/// subsystem never reads nav state (ROD-180); the controller hands it the
/// record (or null) for both the cache-hit and fresh-fetch seed paths.
fn historyDetailRecord(self: *App) ?AnimeRecord {
    if (historyDetailActive(self)) return self.selectedHistoryRecord();
    return null;
}

/// Resolve the record that seeds the detail grid's §4.6 watched-dim + resume
/// cursor, for EITHER detail origin (ROD-163). History-origin reuses the
/// in-memory history record (slices live in `self.history`); browse-origin
/// reads the show's stored row so a Browse-opened show dims its already-watched
/// episodes exactly as a History-opened one does — the asymmetry ROD-131 left.
/// `arena` backs the browse-origin store read, so the returned record is valid
/// only until the caller frees the arena: seed synchronously. Null when there's
/// no detail show or no stored row (an unwatched show → nothing to dim).
/// `source` is optional for the browse path only: history-origin never needs it
/// (the in-memory record carries its own), and a null source can't key a store
/// read, so we return null explicitly rather than query with an empty string —
/// a silent masked miss.
pub fn detailSeedRecord(self: *App, arena: Allocator, source: ?[]const u8, source_id: []const u8) ?AnimeRecord {
    if (historyDetailRecord(self)) |rec| return rec;
    const st = self.store orelse return null;
    const src = source orelse return null;
    return st.getAnime(arena, src, source_id) catch null;
}

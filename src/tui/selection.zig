//! Current-selection resolution (ROD-277). Pure reads of App nav state: which
//! anime/record is focused, plus formatters into App-owned scratch (season chip,
//! detail meta fields). At most one read-only `store.getAnime`; no spawn/write/
//! toast. Threads `*App`.
//!
//! Lifetime: formatters write `chip_buf` / `detail_meta_buf` / `detail_meta_fields`
//! (App-owned). vaxis cells hold a SLICE; the frame emits after the pass returns
//! (ROD-141). Do not move these to stack locals.

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
const Registry = source_mod.Registry;
const Loop = event_mod.Loop;
const App = app_mod.App;

pub fn selectedAnime(self: *const App) ?Anime {
    if (self.search.results.items.len == 0 or self.list_cursor >= self.search.results.items.len) return null;
    return self.search.results.items[self.list_cursor];
}

/// Discover card under the grid cursor (ROD-239); active axis slot.
pub fn selectedDiscoverAnime(self: *const App) ?Anime {
    const items = self.discover.activeSlot().results.items;
    if (self.discover.cursor >= items.len) return null;
    return items[self.discover.cursor];
}

/// Cell size in pixels `.{ w, h }`, or `.{ 0, 0 }` when unreported (tmux/headless).
/// Discover cover boxes use this (ROD-247); 0 → fixed fallback height.
pub fn cellPx(self: *const App) [2]u16 {
    if (self.term_cols == 0 or self.term_rows == 0 or self.term_x_pixel == 0 or self.term_y_pixel == 0)
        return .{ 0, 0 };
    return .{ self.term_x_pixel / self.term_cols, self.term_y_pixel / self.term_rows };
}

/// ROD-186: top-bar season/year chip into App-owned `chip_buf` (ROD-141). "" = no chip.
/// Selected show's season+year when known; else real-world cour. Detail zoom: only
/// that show's season (no cour fallback). Settings: none.
pub fn topBarSeasonChip(self: *App) []const u8 {
    switch (self.active_view) {
        .settings => return "",
        // Discover grid: card season only (feed enriched, ROD-336); null → no chip.
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

/// season+year into `chip_buf`. "" if either half missing (§2.3: no partial chip).
fn seasonChipText(self: *App, season: ?domain.Season, year: ?u32) []const u8 {
    const sea = season orelse return "";
    const yr = year orelse return "";
    return std.fmt.bufPrint(&self.chip_buf, "{s} {d}", .{ sea.kanji(), yr }) catch "";
}

/// Real-world cour into `chip_buf` (Browse/History no-selection fallback). Uses
/// `now_ms` (io-free render). Before first tick `now_ms` is 0: no chip (not 冬 1970).
fn courChip(self: *App) []const u8 {
    if (self.now_ms <= 0) return "";
    const c = domain.currentCour(self.now_ms);
    return seasonChipText(self, c.season, c.year);
}

/// Current-cour release (Discover NEW badge, ROD-239). `now_ms` ≤0 → false (no
/// frame-zero NEW). TOP badge is rank #1, render-side.
pub fn isNewRelease(self: *const App, a: Anime) bool {
    if (self.now_ms <= 0) return false;
    const year = a.year orelse return false;
    const season = a.season orelse return false;
    const c = domain.currentCour(self.now_ms);
    return year == c.year and season == c.season;
}

fn historySeason(r: AnimeRecord) ?domain.Season {
    return if (r.season) |tag| domain.Season.fromString(tag) else null;
}

fn historyYear(r: AnimeRecord) ?u32 {
    return if (r.year) |x| std.math.cast(u32, x) else null;
}

/// Borrowed view: slice fields alias `rec` arena memory, NOT ownership transfer.
/// Stack-transient only; never past the record's arena; never freeOwnedAnime
/// (use hydrateAnimeFromRecord for a gpa-owned copy).
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

/// History-origin detail active *and focused* (ROD-170): two-pane with detail
/// focus, or full-screen zoom from history. Play/cache helpers treat both the same.
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
        // ROD-170: only when detail pane focused; list focus must not play/cache preview.
        .history => if (self.active_pane == .detail)
            (if (self.selectedHistoryRecord()) |rec| animeFromHistoryRecord(rec) else null)
        else
            null,
        .settings => null,
        // Discover single-pane: Enter opens zoom under .detail.
        .discover => null,
    };
}

/// Interactive episode grid only for focused detail, not preview (ROD-222).
/// Stale episodes.results after H→Browse must not bleed into list-focused preview.
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
        // ROD-170: preview always tracks focused record (either pane).
        .history => if (self.selectedHistoryRecord()) |rec| animeFromHistoryRecord(rec) else null,
        .settings => null,
        .discover => null,
    };
}

/// Cover sync target from nav. Split browse / two-pane history: list cursor so
/// cover tracks like renderedDetailAnime. Elsewhere: currentDetailAnime (play/
/// cache/stale-check; do not shift, ROD-156).
pub fn detailSyncTarget(self: *const App) ?Anime {
    if (self.active_view == .browse and self.active_pane == .list and self.term_cols >= 60) {
        return selectedAnime(self);
    }
    if (self.active_view == .history and self.term_cols >= App.pane_split_min) {
        return if (self.selectedHistoryRecord()) |rec| animeFromHistoryRecord(rec) else null;
    }
    return currentDetailAnime(self);
}

/// j/k ↓/↑ only. Cover-settle debounce arms for these; jump keys (g/G), filter,
/// view/pane switch settle immediately (ROD-202: cursor-delta alone misfired).
pub fn isListScrollKey(key: vaxis.Key) bool {
    return key.matches('j', .{}) or key.matches('k', .{}) or
        key.matches(vaxis.Key.down, .{}) or key.matches(vaxis.Key.up, .{});
}

/// True when list cursor moves change detailSyncTarget (cover tracks cursor).
/// Gates cover-settle timer (ROD-202).
pub fn coverTracksCursor(self: *const App) bool {
    if (self.active_view == .browse and self.active_pane == .list and self.term_cols >= 60) {
        return self.search.results.items.len > 0;
    }
    return self.active_view == .history and self.term_cols >= App.pane_split_min;
}

/// Cover target from nav → CoverState (subsystem never reads selection, ROD-160).
/// Immediate for discrete nav; .tick settle for cursor scroll (ROD-202).
pub fn syncCover(self: *App, loop: *Loop, io: std.Io, registry: Registry) void {
    const anime = detailSyncTarget(self);
    const started = self.cover.sync(
        self.gpa,
        loop,
        io,
        registry.primary(),
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
    // Primary under title-language pref (ROD-205); empty-title placeholder when blank.
    const title: []const u8 = if (anime) |a| blk: {
        const resolved = a.displayTitle(self.config.titleLanguageEnum());
        break :blk if (resolved.len > 0) resolved else "—";
    } else "—";
    return .{ .anime = anime, .title = title };
}

/// One detail-metadata field (ROD-260). Compact line and rail share ordered
/// `[]MetaField` so the two forms cannot drift.
pub const MetaField = struct {
    /// Rail label (≤8 chars; values align past 8-col gutter).
    label: []const u8,
    /// Value in both forms. Lives in App-owned buffers (vaxis slice outlives frame).
    value: []const u8,
    /// Compact-line unit suffix (" eps") when the rail label implies the unit.
    unit: []const u8 = "",
    /// fg3 instead of fg2 (only "? eps" degrade).
    dim: bool = false,
    /// ROD-261/348: skipped by drawMetaLine. Rank/Provider/Pinned; Provider/Pinned
    /// still reach compact via drawProviderLine (ROD-348/356).
    rail_only: bool = false,
};

/// Ordered meta fields, highest priority first (ROD-260). Height-starved rail
/// sheds from the bottom. Emit only with a value (§9.1); Episodes is the floor
/// (dim "?" so neither form is empty).
pub fn detailMetaFields(self: *App) []const MetaField {
    const base = detailMetaFieldsFor(self, renderedDetailAnime(self));
    var n = base.len;
    // Provider then Pinned (ROD-348/345): trail the enrichment sextet; shed first.
    // rail_only off the meta LINE; compact uses drawProviderLine. Nav-state only
    // (History preview must not inherit pin/availability of a different row).
    if (providerField(self)) |f| {
        self.detail_meta_fields[n] = f;
        n += 1;
    }
    if (self.show_pin) |pin| {
        self.detail_meta_fields[n] = .{ .label = "Pinned", .value = pin, .rail_only = true };
        n += 1;
    }
    return self.detail_meta_fields[0..n];
}

/// Provider field (ROD-348/356): one token per registry name in construction order
/// (not preference order, §5.3a). Dim only when all `?`. Omitted without canonical
/// id, empty names, or buffer overflow.
fn providerField(self: *App) ?MetaField {
    if (self.show_avail_aid == null) return null;
    const names = self.settings.provider_names;
    if (names.len == 0) return null;
    var w: usize = 0;
    var informative = false;
    for (names, 0..) |name, i| {
        if (i >= self.show_avail.len) break;
        const is_serving = if (self.episodes.for_source) |s| std.mem.eql(u8, s, name) else false;
        const marker: []const u8 = if (is_serving) "▸" else switch (self.show_avail[i]) {
            .bound => "+",
            .absent => "-",
            .unchecked => "?",
        };
        if (is_serving or self.show_avail[i] != .unchecked) informative = true;
        const sep: []const u8 = if (w > 0) " " else "";
        const written = std.fmt.bufPrint(self.detail_provider_buf[w..], "{s}{s}{s}", .{ sep, marker, name }) catch return null;
        w += written.len;
    }
    return .{ .label = "Provider", .value = self.detail_provider_buf[0..w], .dim = !informative, .rail_only = true };
}

/// Same field list for an explicit anime (History preview cannot use
/// renderedDetailAnime). App-owned buffers.
pub fn detailMetaFieldsFor(self: *App, maybe_a: ?Anime) []const MetaField {
    var n: usize = 0;
    const a = maybe_a orelse {
        self.detail_meta_fields[0] = .{ .label = "Episodes", .value = "?", .unit = " eps", .dim = true };
        return self.detail_meta_fields[0..1];
    };

    // Episodes floor: real count or dim "?".
    const eps = a.episodeCount(self.translation);
    const total: ?u32 = if (eps > 0) eps else a.total_episodes;
    if (total) |t| {
        const v = std.fmt.bufPrint(&self.detail_meta_buf, "{d}", .{t}) catch "?";
        self.detail_meta_fields[n] = .{ .label = "Episodes", .value = v, .unit = " eps" };
    } else {
        self.detail_meta_fields[n] = .{ .label = "Episodes", .value = "?", .unit = " eps", .dim = true };
    }
    n += 1;

    if (a.kind) |kind| {
        if (kind.len > 0) {
            self.detail_meta_fields[n] = .{ .label = "Format", .value = kind };
            n += 1;
        }
    }

    // Source (ROD-261): after Format, before Duration (§5.3a).
    if (a.source_material) |src| {
        const v = formatSource(&self.detail_source_buf, src);
        if (v.len > 0) {
            self.detail_meta_fields[n] = .{ .label = "Source", .value = v };
            n += 1;
        }
    }

    // Duration (ROD-261): omit null/zero.
    if (a.duration) |dur| {
        if (dur > 0) {
            const v = std.fmt.bufPrint(&self.detail_duration_buf, "{d} min", .{dur}) catch "";
            if (v.len > 0) {
                self.detail_meta_fields[n] = .{ .label = "Duration", .value = v };
                n += 1;
            }
        }
    }

    // Studios (ROD-261): second-to-last; shed early on short rail.
    if (a.studios.len > 0) {
        const v = formatStudios(&self.detail_studios_buf, a.studios);
        if (v.len > 0) {
            self.detail_meta_fields[n] = .{ .label = "Studios", .value = v };
            n += 1;
        }
    }

    // Rank (ROD-261): rail-only, last; needs position + type.
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

/// AniList source enum → rail text (ROD-261): `LIGHT_NOVEL` → `Light novel`.
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

/// Rail Rank (ROD-261): `#{rank} {type} {year}` or without year. Type lowercased;
/// season omitted (header chip already has it, §5.3a).
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

/// Studios: `A`, `A, B`, or `A, B +N` (ROD-261, §5.3a). Cap two names; overflow
/// as +N. App-owned `buf`; oversize name degrades to borrowed first name.
fn formatStudios(buf: []u8, studios: []const []const u8) []const u8 {
    return switch (studios.len) {
        0 => "",
        1 => std.fmt.bufPrint(buf, "{s}", .{studios[0]}) catch studios[0],
        2 => std.fmt.bufPrint(buf, "{s}, {s}", .{ studios[0], studios[1] }) catch studios[0],
        else => std.fmt.bufPrint(buf, "{s}, {s} +{d}", .{ studios[0], studios[1], studios.len - 2 }) catch studios[0],
    };
}

pub fn currentDetailSourceName(self: *const App, registry: Registry) []const u8 {
    if (historyDetailActive(self)) {
        if (self.selectedHistoryRecord()) |rec| return rec.source;
    }
    return registry.primary().name();
}

/// History record for episode-grid seed, or null. Episode subsystem never reads
/// nav (ROD-180); controller hands the record.
fn historyDetailRecord(self: *App) ?AnimeRecord {
    if (historyDetailActive(self)) return self.selectedHistoryRecord();
    return null;
}

/// Seed for §4.6 watched-dim + resume (ROD-163). History: in-memory record.
/// Browse: store row (same dim as History). Arena-backed browse read: seed
/// synchronously. Null without detail show / store row. Null source → null
/// (no empty-string store key).
pub fn detailSeedRecord(self: *App, arena: Allocator, source: ?[]const u8, source_id: []const u8) ?AnimeRecord {
    if (historyDetailRecord(self)) |rec| return rec;
    const st = self.store orelse return null;
    const src = source orelse return null;
    return st.getAnime(arena, src, source_id) catch null;
}

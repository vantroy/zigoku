//! Zigoku — TUI background workers and shared ownership helpers.

const std = @import("std");
const source_mod = @import("../source.zig");
const domain = @import("../domain.zig");
const store_mod = @import("../store.zig");
const anilist = @import("../anilist.zig");
const cover_mod = @import("../cover.zig");
const player_mod = @import("../player.zig");
const aniskip = @import("../aniskip.zig");
const lru_mod = @import("../util/lru.zig");
const event_mod = @import("event.zig");
const log = @import("../log.zig");

const Allocator = std.mem.Allocator;
const Store = store_mod.Store;
const SourceProvider = source_mod.SourceProvider;
const Anime = domain.Anime;
const Loop = event_mod.Loop;

const DecodedCoverCacheOps = struct {
    pub fn freeValue(alloc: Allocator, value: cover_mod.Pixels) void {
        alloc.free(value.rgba);
    }

    pub fn valueBytes(value: cover_mod.Pixels) usize {
        return value.rgba.len;
    }
};
pub const RawCoverCache = lru_mod.LruCache([]const u8, []u8, 20, lru_mod.SliceValueOps([]u8));
pub const DecodedCoverCache = lru_mod.LruCache([]const u8, cover_mod.Pixels, 5, DecodedCoverCacheOps);
pub const max_cover_raw_cache_bytes = 32 * 1024 * 1024;
pub const max_cover_decoded_cache_bytes = 48 * 1024 * 1024;

/// One slot of the episode hot-cache: a canonical GPA-owned episode list plus
/// the Unix-seconds expiry mirroring the DB episode_cache TTL, so the in-memory
/// mirror never serves data the DB itself would refuse as stale (ROD-130).
pub const EpisodeLruEntry = struct {
    episodes: []domain.EpisodeNumber,
    expires_at: i64,
};
const EpisodeListOps = struct {
    pub fn freeValue(alloc: Allocator, value: EpisodeLruEntry) void {
        for (value.episodes) |ep| alloc.free(ep.raw);
        alloc.free(value.episodes);
    }
    pub fn valueBytes(value: EpisodeLruEntry) usize {
        var total = value.episodes.len * @sizeOf(domain.EpisodeNumber);
        for (value.episodes) |ep| total += ep.raw.len; // each .raw is its own alloc
        return total;
    }
};
pub const episode_lru_cap = 8;
/// Hot in-memory mirror of the DB episode cache (ROD-130), keyed by
/// "source\x00source_id\x00translation". A synchronous hit bypasses the async
/// fetch so the detail pane opens instantly on repeat visits. Entries hold
/// canonical episode copies (each .raw individually owned); a hit dups into the
/// view, so LRU eviction can never invalidate displayed memory.
pub const EpisodeLruCache = lru_mod.LruCache([]const u8, EpisodeLruEntry, episode_lru_cap, EpisodeListOps);

/// Duplicate an episode list into a fresh canonical GPA allocation: a new outer
/// slice plus an individually-owned copy of every `.raw`. Mirrors the exact
/// ownership shape `episodesTask` produces, so the result is freeable by
/// `EpisodeState.freeResults` / `EpisodeListOps`. On OOM the partial allocation is
/// unwound and the error propagates (callers fall back to a network fetch).
pub fn dupEpisodesOwned(alloc: Allocator, eps: []const domain.EpisodeNumber) ![]domain.EpisodeNumber {
    const out = try alloc.alloc(domain.EpisodeNumber, eps.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |ep| alloc.free(ep.raw);
        alloc.free(out);
    }
    for (eps, 0..) |ep, i| {
        out[i] = .{ .raw = try alloc.dupe(u8, ep.raw) };
        filled = i + 1;
    }
    return out;
}

pub fn dupeOptText(alloc: Allocator, s: ?[]const u8) !?[]const u8 {
    return if (s) |x| try alloc.dupe(u8, x) else null;
}

/// Deep-copy a slice of strings (genres, studios) into a fresh owned slice plus
/// an individually-owned copy of every element — the shape `freeOwnedAnime`
/// frees. On OOM the partial allocation is unwound and the error propagates.
/// Returns `&.{}` for an empty input (no allocation, nothing to free).
pub fn dupeOwnedStrList(alloc: Allocator, items: []const []const u8) ![]const []const u8 {
    if (items.len == 0) return &.{};
    const out = try alloc.alloc([]const u8, items.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |s| alloc.free(s);
        alloc.free(out);
    }
    for (items, 0..) |s, i| {
        out[i] = try alloc.dupe(u8, s);
        filled = i + 1;
    }
    return out;
}

pub fn dupeOwnedAnime(alloc: Allocator, a: Anime) !Anime {
    var out: Anime = .{
        .id = try alloc.dupe(u8, a.id),
        .name = &.{},
        .mal_id = a.mal_id,
        .anilist_id = a.anilist_id,
        .eps_sub = a.eps_sub,
        .eps_dub = a.eps_dub,
        .total_episodes = a.total_episodes,
        .year = a.year,
        .season = a.season,
        .start_date = a.start_date,
        .score = a.score,
    };
    errdefer freeOwnedAnime(alloc, out);

    out.name = try alloc.dupe(u8, a.name);
    out.english_name = try dupeOptText(alloc, a.english_name);
    out.native_name = try dupeOptText(alloc, a.native_name);
    out.thumb = try dupeOptText(alloc, a.thumb);
    out.banner = try dupeOptText(alloc, a.banner);
    out.status = try dupeOptText(alloc, a.status);
    out.description = try dupeOptText(alloc, a.description);
    out.kind = try dupeOptText(alloc, a.kind);
    out.genres = try dupeOwnedStrList(alloc, a.genres);
    out.studios = try dupeOwnedStrList(alloc, a.studios);
    return out;
}

pub fn freeOwnedAnime(alloc: Allocator, a: Anime) void {
    alloc.free(a.id);
    if (a.name.len > 0) alloc.free(a.name);
    if (a.english_name) |x| alloc.free(x);
    if (a.native_name) |x| alloc.free(x);
    if (a.thumb) |x| alloc.free(x);
    if (a.banner) |x| alloc.free(x);
    if (a.status) |x| alloc.free(x);
    if (a.description) |x| alloc.free(x);
    if (a.kind) |x| alloc.free(x);
    if (a.genres.len > 0) {
        for (a.genres) |g| alloc.free(g);
        alloc.free(a.genres);
    }
    if (a.studios.len > 0) {
        for (a.studios) |s| alloc.free(s);
        alloc.free(a.studios);
    }
}

/// Background task: search and post results back to the UI thread.
pub fn searchTask(loop: *Loop, gpa: Allocator, io: std.Io, provider: SourceProvider, query: []const u8, page: u32, translation: domain.Translation) void {
    // NOTE: `query` ownership is transferred to the `search_done` event's `for_query`
    // on the success path; the UI thread frees it there. On all error paths we free it
    // here explicitly before returning. Do NOT add a defer — it would free the string
    // before the UI thread reads `ev.for_query`, causing a use-after-free.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const raw = provider.search(arena.allocator(), io, query, .{
        .translation = translation,
        .limit = 26,
        .page = page,
    }) catch |e| {
        log.debug("search failed: {s}", .{@errorName(e)});
        gpa.free(query);
        // @errorName is a static string (immortal) — safe to thread into the toast.
        loop.postEvent(.{ .task_error = @errorName(e) }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };

    // Dupe every owned string we might thread into the UI so arena teardown
    // cannot leave dangling references in the event payload.
    var owned = std.ArrayListUnmanaged(Anime).empty;
    owned.ensureTotalCapacity(gpa, raw.len) catch |e| {
        log.debug("search result alloc failed: {s}", .{@errorName(e)});
        gpa.free(query);
        loop.postEvent(.{ .task_error = @errorName(e) }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };
    for (raw) |a| {
        const duped = dupeOwnedAnime(gpa, a) catch continue;
        owned.appendAssumeCapacity(duped);
    }

    // `owned.items` is a sub-slice of an over-allocated backing buffer —
    // `ensureTotalCapacity` grows by more than requested so len < capacity.
    // `gpa.free(owned.items)` would mismatch the allocation length and panic.
    // `toOwnedSlice` resizes to exact fit (len == capacity), giving a slice
    // safe to pass to gpa.free on either path below.
    const exact = owned.toOwnedSlice(gpa) catch {
        for (owned.items) |r| freeOwnedAnime(gpa, r);
        owned.deinit(gpa);
        gpa.free(query);
        return;
    };

    loop.postEvent(.{ .search_done = .{
        .results = exact,
        .for_query = query,
        .page = page,
    } }) catch {
        // Post failed — we still own everything; free it all.
        for (exact) |r| freeOwnedAnime(gpa, r);
        gpa.free(exact); // exact-fit: len == capacity, free is valid
        gpa.free(query);
    };
    // On success: `exact` and `query` are now owned by the event.
    // The UI thread frees them via gpa.free(ev.results) and gpa.free(ev.for_query).
}

/// Background task: enrich one page of search results from AniList.
/// `results` and `query` are GPA-owned by this task and transferred to the event on success.
pub fn enrichTask(
    loop: *Loop,
    gpa: Allocator,
    io: std.Io,
    results: []Anime,
    query: []const u8,
    offset: usize,
) void {
    var posted = false;
    defer if (!posted) {
        for (results) |a| freeOwnedAnime(gpa, a);
        gpa.free(results);
        gpa.free(query);
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    for (results) |*a| {
        const meta = anilist.enrich(arena.allocator(), io, a.*) catch null orelse continue;
        // Fill only what AllAnime left blank (it's the source of truth); deep-copy
        // each string/slice into GPA before the arena `meta` came from is torn down.
        // A failed copy leaves the prior (blank) value rather than a dangling one.
        if (a.english_name == null) a.english_name = dupeOptText(gpa, meta.title_english) catch a.english_name;
        if (a.native_name == null) a.native_name = dupeOptText(gpa, meta.title_native) catch a.native_name;
        if (a.thumb == null) a.thumb = dupeOptText(gpa, meta.thumb) catch a.thumb;
        if (a.status == null) a.status = dupeOptText(gpa, meta.status) catch a.status;
        if (a.kind == null) a.kind = dupeOptText(gpa, meta.kind) catch a.kind;
        if (a.description == null) a.description = dupeOptText(gpa, meta.description) catch a.description;
        // Optional-on-OOM (matches the dupeOptText fields): a failed copy yields
        // null and we keep the prior slice, never aliasing the soon-dead arena.
        if (a.genres.len == 0) {
            if (dupeOwnedStrList(gpa, meta.genres) catch null) |g| a.genres = g;
        }
        if (a.studios.len == 0) {
            if (dupeOwnedStrList(gpa, meta.studios) catch null) |s| a.studios = s;
        }
        if (a.anilist_id == null) a.anilist_id = meta.anilist_id;
        if (a.mal_id == null) a.mal_id = meta.mal_id;
        if (a.total_episodes == null) a.total_episodes = meta.total_episodes;
        if (a.year == null) a.year = meta.year;
        if (a.season == null) a.season = meta.season;
        if (a.start_date == null) a.start_date = meta.start_date;
        if (a.score == null) a.score = meta.score;
    }

    loop.postEvent(.{ .search_enriched = .{ .results = results, .for_query = query, .offset = offset } }) catch |pe| {
        log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return; // `posted` stays false → the defer frees results/query
    };
    posted = true;
}

/// Background task: pull history and post it back to the UI thread. Errors are
/// reported as a toast-able message rather than crashing the worker.
pub fn loadHistoryTask(loop: *Loop, arena: Allocator, store: *Store) void {
    const recs = store.loadHistory(arena) catch |err| {
        log.debug("loadHistory failed: {s}", .{@errorName(err)});
        loop.postEvent(.{ .task_error = @errorName(err) }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };
    loop.postEvent(.{ .history_loaded = recs }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
}

/// Background task: fetch episode list and post to UI.
/// `id` ownership: transferred to episodes_done.for_id on success; freed here on error.
pub fn episodesTask(loop: *Loop, gpa: Allocator, io: std.Io, provider: SourceProvider, id: []const u8, translation: domain.Translation) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const raw = provider.episodes(arena.allocator(), io, id, translation) catch |e| {
        log.debug("episodes fetch failed: {s}", .{@errorName(e)});
        gpa.free(id);
        loop.postEvent(.episodes_error) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };

    var owned: std.ArrayListUnmanaged(domain.EpisodeNumber) = .empty;
    owned.ensureTotalCapacity(gpa, raw.len) catch |e| {
        log.debug("episodes alloc failed: {s}", .{@errorName(e)});
        gpa.free(id);
        loop.postEvent(.episodes_error) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };
    for (raw) |ep| {
        const raw_owned = gpa.dupe(u8, ep.raw) catch continue;
        owned.appendAssumeCapacity(.{ .raw = raw_owned });
    }
    const exact = owned.toOwnedSlice(gpa) catch {
        for (owned.items) |ep| gpa.free(ep.raw);
        owned.deinit(gpa);
        gpa.free(id);
        return;
    };

    loop.postEvent(.{ .episodes_done = .{ .episodes = exact, .for_id = id } }) catch {
        for (exact) |ep| gpa.free(ep.raw);
        gpa.free(exact);
        gpa.free(id);
    };
}

const PlaybackProgress = struct {
    time_pos_bits: std.atomic.Value(u64) = .init(0),
    duration_bits: std.atomic.Value(u64) = .init(0),
    seen_update: std.atomic.Value(bool) = .init(false),

    fn record(self: *PlaybackProgress, update: player_mod.PositionUpdate) void {
        self.time_pos_bits.store(@bitCast(update.time_pos), .release);
        self.duration_bits.store(@bitCast(update.duration), .release);
        self.seen_update.store(true, .release);
    }

    fn snapshot(self: *PlaybackProgress) ?player_mod.PositionUpdate {
        if (!self.seen_update.load(.acquire)) return null;
        return .{
            .time_pos = @bitCast(self.time_pos_bits.load(.acquire)),
            .duration = @bitCast(self.duration_bits.load(.acquire)),
        };
    }
};

const PlayTaskCallbackCtx = struct {
    loop: *Loop,
    progress: *PlaybackProgress,
};

fn observedPlaybackWasMeaningful(latest: ?player_mod.PositionUpdate) bool {
    const update = latest orelse return false;
    return update.isMeaningful();
}

fn persistFinalProgress(
    st: *Store,
    source_name: []const u8,
    source_id: []const u8,
    ep_raw: []const u8,
    translation: domain.Translation,
    latest: ?player_mod.PositionUpdate,
) void {
    const update = latest orelse return;
    st.saveProgress(source_name, source_id, translation, ep_raw, update.time_pos, update.duration, Store.nowSecs()) catch |e|
        log.debug("saveProgress failed: {s}", .{@errorName(e)});
}

fn postPositionUpdate(ctx: *anyopaque, update: player_mod.PositionUpdate) void {
    const cb: *PlayTaskCallbackCtx = @ptrCast(@alignCast(ctx));
    cb.progress.record(update);
    // Heartbeat-frequency event: a failed post means the queue is closing
    // (shutdown). Not worth a log line on every tick of a teardown.
    cb.loop.postEvent(.{ .position_update = .{
        .time_pos = update.time_pos,
        .duration = update.duration,
    } }) catch {};
}

/// Background task: resolve stream and launch mpv.
/// All string params are GPA-owned by this task and freed before return.
/// `mpv_path` and `skip_mode` are borrowed from `App.config` (ROD-85), which
/// outlives this thread — they must not be freed here.
pub fn playTask(loop: *Loop, gpa: Allocator, io: std.Io, provider: SourceProvider, id: []const u8, ep_raw: []const u8, translation: domain.Translation, title: []const u8, start_seconds: u64, mal_id: ?u32, episode_ordinal: u32, mpv_path: []const u8, skip_mode: []const u8, quality: domain.Quality) void {
    defer gpa.free(id);
    defer gpa.free(ep_raw);
    defer gpa.free(title);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const ep: domain.EpisodeNumber = .{ .raw = ep_raw };
    const link = provider.resolve(arena.allocator(), io, id, ep, translation, quality) catch |e| {
        log.debug("resolve failed: {s}", .{@errorName(e)});
        loop.postEvent(.{ .play_error = null }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };

    // ROD-83: fetch OP/ED skip data on this worker thread (never the UI thread).
    const skip = aniskip.prepare(arena.allocator(), io, mal_id, title, aniskip.episodeNumber(ep_raw, episode_ordinal), aniskip.SkipMode.fromString(skip_mode));

    var progress: PlaybackProgress = .{};
    var callback_ctx: PlayTaskCallbackCtx = .{ .loop = loop, .progress = &progress };
    player_mod.play(arena.allocator(), io, mpv_path, link, title, start_seconds, .{
        .ctx = @ptrCast(&callback_ctx),
        .func = postPositionUpdate,
    }, skip) catch |e| {
        log.debug("mpv playback failed: {s}", .{@errorName(e)});
        loop.postEvent(.{ .play_error = progress.snapshot() }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
        return;
    };

    loop.postEvent(.{ .play_done = progress.snapshot() }) catch |pe| log.debug("postEvent failed: {s}", .{@errorName(pe)});
}

const max_cover_encoded_bytes = 8 * 1024 * 1024;
const max_cover_dimension = 4096;
const max_cover_pixels = max_cover_dimension * max_cover_dimension;

fn postCoverError(loop: *Loop, gpa: Allocator, for_id: []const u8) void {
    loop.postEvent(.{ .cover_error = for_id }) catch gpa.free(for_id);
}

fn postCoverDoneOwned(loop: *Loop, gpa: Allocator, decoded: cover_mod.Pixels, for_id: []const u8) void {
    loop.postEvent(.{ .cover_done = .{
        .rgba = decoded.rgba,
        .width = decoded.w,
        .height = decoded.h,
        .for_id = for_id,
    } }) catch {
        gpa.free(decoded.rgba);
        gpa.free(for_id);
    };
}

fn postCoverDoneCloned(loop: *Loop, gpa: Allocator, decoded: cover_mod.Pixels, for_id: []const u8) void {
    const rgba = gpa.dupe(u8, decoded.rgba) catch {
        postCoverError(loop, gpa, for_id);
        return;
    };
    postCoverDoneOwned(loop, gpa, .{ .rgba = rgba, .w = decoded.w, .h = decoded.h }, for_id);
}

fn decodeCoverBody(gpa: Allocator, body: []const u8) !cover_mod.Pixels {
    const dims = cover_mod.probeDimensions(body) orelse return error.DecodeFailed;
    if (dims.w == 0 or dims.h == 0 or dims.w > max_cover_dimension or dims.h > max_cover_dimension) {
        return error.DecodeFailed;
    }
    const pixel_count = std.math.mul(u64, dims.w, dims.h) catch return error.DecodeFailed;
    if (pixel_count > max_cover_pixels) return error.DecodeFailed;
    return cover_mod.decodeRgba(gpa, body);
}

/// Background task: fetch cover bytes and decode them to RGBA.
/// `url` is task-owned and freed before return. `for_id` is transferred to the
/// event on success/error and freed by the UI thread there. Cache ownership stays
/// on the worker side; events get their own RGBA slice.
pub fn coverTask(
    loop: *Loop,
    gpa: Allocator,
    io: std.Io,
    url: []const u8,
    for_id: []const u8,
    raw_cache: *RawCoverCache,
    decoded_cache: *DecodedCoverCache,
) void {
    defer gpa.free(url);

    if (decoded_cache.get(url)) |decoded| {
        postCoverDoneCloned(loop, gpa, decoded, for_id);
        return;
    }

    if (raw_cache.get(url)) |body| {
        const decoded = decodeCoverBody(gpa, body) catch |e| {
            log.debug("cover decode (cached) failed: {s}", .{@errorName(e)});
            postCoverError(loop, gpa, for_id);
            return;
        };
        const cached = decoded_cache.putOwnedBounded(gpa, url, decoded, max_cover_decoded_cache_bytes) catch false;
        if (!cached) {
            postCoverDoneOwned(loop, gpa, decoded, for_id);
            return;
        }
        postCoverDoneCloned(loop, gpa, decoded, for_id);
        return;
    }

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const resp_buf = gpa.alloc(u8, max_cover_encoded_bytes) catch {
        postCoverError(loop, gpa, for_id);
        return;
    };
    defer gpa.free(resp_buf);
    var resp_writer: std.Io.Writer = .fixed(resp_buf);
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &resp_writer,
        .extra_headers = &.{
            .{ .name = "Accept", .value = "image/png,image/jpeg,*/*;q=0.1" },
        },
    }) catch |e| {
        log.debug("cover fetch failed: {s}", .{@errorName(e)});
        postCoverError(loop, gpa, for_id);
        return;
    };
    if (res.status != .ok) {
        log.debug("cover fetch HTTP {d}", .{@intFromEnum(res.status)});
        postCoverError(loop, gpa, for_id);
        return;
    }

    const body = resp_writer.buffered();
    const decoded = decodeCoverBody(gpa, body) catch |e| {
        log.debug("cover decode failed: {s}", .{@errorName(e)});
        postCoverError(loop, gpa, for_id);
        return;
    };
    if (gpa.dupe(u8, body)) |raw_copy| {
        const cached = raw_cache.putOwnedBounded(gpa, url, raw_copy, max_cover_raw_cache_bytes) catch false;
        if (!cached) gpa.free(raw_copy);
    } else |_| {}
    const cached = decoded_cache.putOwnedBounded(gpa, url, decoded, max_cover_decoded_cache_bytes) catch false;
    if (!cached) {
        postCoverDoneOwned(loop, gpa, decoded, for_id);
        return;
    }
    postCoverDoneCloned(loop, gpa, decoded, for_id);
}

/// Heartbeat thread: posts .tick every 100ms until `quit` is set.
pub fn tickTask(loop: *Loop, io: std.Io, quit: *std.atomic.Value(bool)) void {
    while (!quit.load(.acquire)) {
        std.Io.sleep(io, .fromMilliseconds(100), .awake) catch {};
        // Like position_update: a failed post here is just the queue closing.
        loop.postEvent(.tick) catch {};
    }
}

/// Current wall-clock time in milliseconds (ms since Unix epoch).
pub fn nowMs(io: std.Io) i64 {
    const ts = std.Io.Clock.real.now(io);
    return @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_ms));
}

test "dupeOwnedAnime round-trips the widened metadata fields leak-clean (ROD-140)" {
    const alloc = std.testing.allocator; // fails the test on any leak or double-free
    const src: Anime = .{
        .id = "show1",
        .name = "Sousou no Frieren",
        .english_name = "Frieren",
        .native_name = "葬送のフリーレン",
        .kind = "TV",
        .season = .fall,
        .start_date = .{ .year = 2023, .month = 9, .day = 29 },
        .genres = &.{ "Adventure", "Drama", "Fantasy" },
        .studios = &.{"Madhouse"},
    };

    const owned = try dupeOwnedAnime(alloc, src);
    defer freeOwnedAnime(alloc, owned);

    // Value types copy through; slices are deep, independent copies.
    try std.testing.expectEqual(domain.Season.fall, owned.season.?);
    try std.testing.expectEqual(@as(?u32, 29), owned.start_date.?.day);
    try std.testing.expectEqual(@as(usize, 3), owned.genres.len);
    try std.testing.expectEqualStrings("Fantasy", owned.genres[2]);
    try std.testing.expect(owned.genres.ptr != src.genres.ptr); // not aliasing the source
    try std.testing.expectEqual(@as(usize, 1), owned.studios.len);
    try std.testing.expectEqualStrings("Madhouse", owned.studios[0]);
}

test "dupeOwnedStrList returns the empty sentinel without allocating" {
    // &.{} in → &.{} out, freeable as a no-op (len 0). No allocator touch.
    const out = try dupeOwnedStrList(std.testing.allocator, &.{});
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "observedPlaybackWasMeaningful requires positive observed position" {
    try std.testing.expect(!observedPlaybackWasMeaningful(null));
    try std.testing.expect(!observedPlaybackWasMeaningful(.{ .time_pos = 0, .duration = 1440 }));
    try std.testing.expect(!observedPlaybackWasMeaningful(.{ .time_pos = -1, .duration = 1440 }));
    try std.testing.expect(observedPlaybackWasMeaningful(.{ .time_pos = 0.5, .duration = 1440 }));
}

test "persistFinalProgress writes the latest observed position" {
    var store = try Store.openMemory();
    defer store.close();
    try store.upsertAnime(.{ .source = "allanime", .source_id = "show1", .title = "Test Show" }, 1000);

    persistFinalProgress(&store, "allanime", "show1", "7", .sub, .{
        .time_pos = 91.5,
        .duration = 1440,
    });

    const saved_resume = (try store.getResume("allanime", "show1", .sub, "7")).?;
    try std.testing.expectApproxEqAbs(@as(f64, 91.5), saved_resume.position_secs, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1440), saved_resume.duration_secs, 0.001);
}

test "persistFinalProgress is a no-op without an observed update" {
    var store = try Store.openMemory();
    defer store.close();
    try store.upsertAnime(.{ .source = "allanime", .source_id = "show1", .title = "Test Show" }, 1000);

    persistFinalProgress(&store, "allanime", "show1", "7", .sub, null);
    try std.testing.expect((try store.getResume("allanime", "show1", .sub, "7")) == null);
}

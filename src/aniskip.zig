//! AniSkip — intro/outro auto-skip for the mpv playback path (ROD-83).
//!
//! AniSkip is a community database of opening/ending timestamps keyed on a
//! MyAnimeList id. We fetch the intervals for one episode, drop a tiny Lua script
//! into the cache dir, and hand mpv `--script` + `--script-opts` so it seeks past
//! the OP/ED on its own. Everything here is best-effort: any failure (no MAL id,
//! network down, empty data, unwritable cache) collapses to "no skip" and the
//! episode plays normally. The user never sees an error.
//!
//! The MAL id comes from AniList enrichment when available (`domain.Anime.mal_id`)
//! and falls back to Jikan (ROD-82). In the TUI these network calls run on the
//! playback worker thread, never the UI thread; the CLI calls them inline on its
//! already-blocking main thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const jikan = @import("providers/jikan.zig");
const player = @import("player.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

const ENDPOINT = "https://api.aniskip.com/v2/skip-times";

/// Which segments to auto-skip. Mirrors `config.skip_mode` (ROD-85).
pub const SkipMode = enum {
    none,
    intro,
    outro,
    both,

    /// Parse the `config.skip_mode` string, defaulting to `.both` for anything
    /// unrecognized — a typo in the config never silently disables skipping.
    pub fn fromString(s: []const u8) SkipMode {
        return std.meta.stringToEnum(SkipMode, s) orelse .both;
    }
};

/// Resolved skip window for one episode. Any field left `null` means AniSkip had
/// no timestamp for that segment.
pub const SkipTimes = struct {
    op_start: ?f64 = null,
    op_end: ?f64 = null,
    ed_start: ?f64 = null,
    ed_end: ?f64 = null,
};

// ── AniSkip API response shapes (only the fields we read) ──────────────────────

const Interval = struct {
    startTime: f64 = 0,
    endTime: f64 = 0,
};

const ResultItem = struct {
    interval: Interval = .{},
    // AniSkip sends this camelCase; std.json matches field names verbatim, so the
    // Zig field must be camelCase too or it silently parses to "".
    skipType: []const u8 = "",
};

const Resp = struct {
    results: []ResultItem = &.{},
};

/// Fetch OP/ED timestamps for `(mal_id, episode)`. Never errors — every failure
/// path returns an empty `SkipTimes`, so callers degrade silently.
pub fn fetch(arena: Allocator, io: Io, mal_id: u32, episode: u32) SkipTimes {
    return fetchInner(arena, io, mal_id, episode) catch .{};
}

fn fetchInner(arena: Allocator, io: Io, mal_id: u32, episode: u32) !SkipTimes {
    // Bounded: endpoint + two u32s + fixed query string is well under 256 bytes.
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        "{s}/{d}/{d}?types[]=op&types[]=ed&episodeLength=0",
        .{ ENDPOINT, mal_id, episode },
    );

    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();

    var resp_aw = std.Io.Writer.Allocating.init(arena);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &resp_aw.writer,
        .extra_headers = &.{
            .{ .name = "Accept", .value = "application/json" },
        },
    });
    if (res.status != .ok) return .{};

    const parsed = try std.json.parseFromSlice(Resp, arena, resp_aw.writer.buffered(), .{
        .ignore_unknown_fields = true,
    });
    return timesFromResults(parsed.value.results);
}

/// Fold AniSkip's result list into a single `SkipTimes`. First op/ed wins.
/// Degenerate intervals (negative start, or end ≤ start) are dropped — the
/// community DB has them, and a 0→0 window would make mpv seek-loop at the start.
fn timesFromResults(results: []const ResultItem) SkipTimes {
    var t: SkipTimes = .{};
    for (results) |r| {
        if (!validInterval(r.interval)) continue;
        if (std.mem.eql(u8, r.skipType, "op") and t.op_start == null) {
            t.op_start = r.interval.startTime;
            t.op_end = r.interval.endTime;
        } else if (std.mem.eql(u8, r.skipType, "ed") and t.ed_start == null) {
            t.ed_start = r.interval.startTime;
            t.ed_end = r.interval.endTime;
        }
    }
    return t;
}

/// Minimum OP/ED length we'll act on. Below this a skip isn't worth announcing,
/// and — since the script announces then seeks 0.4s later — a sub-second window
/// could be overrun by natural playback and turn the absolute seek into a rewind.
const min_interval_secs: f64 = 1.0;

fn validInterval(iv: Interval) bool {
    return iv.startTime >= 0 and iv.endTime - iv.startTime >= min_interval_secs;
}

/// Build the `--script-opts` value for `times` under `mode`, or `null` when there
/// is nothing worth skipping (mode `.none`, or no interval relevant to the mode).
/// Missing segments are emitted as `-1`, which the Lua script reads as "disabled".
fn buildOpts(arena: Allocator, t: SkipTimes, mode: SkipMode) !?[]const u8 {
    if (mode == .none) return null;
    const want_op = mode == .intro or mode == .both;
    const want_ed = mode == .outro or mode == .both;
    const have_op = want_op and t.op_start != null and t.op_end != null;
    const have_ed = want_ed and t.ed_start != null and t.ed_end != null;
    if (!have_op and !have_ed) return null;

    return try std.fmt.allocPrint(
        arena,
        "aniskip-op_start={d},aniskip-op_end={d},aniskip-ed_start={d},aniskip-ed_end={d},aniskip-mode={s}",
        .{
            if (have_op) t.op_start.? else @as(f64, -1),
            if (have_op) t.op_end.? else @as(f64, -1),
            if (have_ed) t.ed_start.? else @as(f64, -1),
            if (have_ed) t.ed_end.? else @as(f64, -1),
            @tagName(mode),
        },
    );
}

/// AniSkip wants an integer episode number. Prefer the integer parsed from the
/// provider's raw label; fall back to the 1-based list ordinal when it isn't one.
/// Caveat: for non-integer labels (OVA, "1.5") or gapped numbering the ordinal
/// can disagree with the real episode number — a wrong AniSkip lookup at worst,
/// which just yields no skip. Acceptable for a best-effort feature.
pub fn episodeNumber(raw: []const u8, ordinal: u32) u32 {
    const trimmed = std.mem.trim(u8, raw, " \t");
    return std.fmt.parseInt(u32, trimmed, 10) catch ordinal;
}

/// Resolve everything mpv needs to auto-skip this episode, or `null` to play
/// without skipping. Runs network calls (Jikan + AniSkip) — call it off the UI
/// thread. `known_mal_id` is the cached/enriched MAL id (ROD-82 cache read);
/// when absent we fall back to a Jikan lookup on `title`.
pub fn prepare(
    arena: Allocator,
    io: Io,
    known_mal_id: ?u32,
    title: []const u8,
    episode: u32,
    mode: SkipMode,
) ?player.SkipScript {
    if (mode == .none) return null;

    const mal_id = known_mal_id orelse (jikan.resolveId(arena, io, title) catch return null);
    const times = fetch(arena, io, mal_id, episode);
    const opts = (buildOpts(arena, times, mode) catch return null) orelse return null;
    const path = ensureScript(arena, io) catch return null;
    return .{ .path = path, .opts = opts };
}

// ── Lua script provisioning ────────────────────────────────────────────────────

/// The mpv user-script. Reads the OP/ED window from `--script-opts` and seeks
/// past whichever segment the current `time-pos` falls inside. `-1` disables a
/// segment; `mode` gates intro vs outro.
///
/// UX (design: Mira): announce the skip *before* cutting so the jump reads as
/// intentional, not a glitch. `skip_section` shows a calm OSD line, then seeks a
/// beat later. The `skipped` flags debounce the high-frequency time-pos observer
/// so the deferred seek fires exactly once per segment; `file-loaded` resets them
/// in case episodes are ever chained in one mpv process. To restyle the toast
/// (dim/top-left), prefix the label with ASS tags, e.g. `{\an7\fs18\alpha&H80&}`.
const LUA_SCRIPT =
    \\local opts = require("mp.options")
    \\local o = { op_start = -1, op_end = -1, ed_start = -1, ed_end = -1, mode = "both" }
    \\opts.read_options(o, "aniskip")
    \\
    \\local skipped = { op = false, ed = false }
    \\
    \\local function skip_section(target, label)
    \\    mp.osd_message(label, 2.0)
    \\    mp.add_timeout(0.4, function()
    \\        mp.commandv("seek", target, "absolute")
    \\    end)
    \\end
    \\
    \\mp.observe_property("time-pos", "number", function(_, pos)
    \\    if not pos then return end
    \\    if (o.mode == "intro" or o.mode == "both") and o.op_start >= 0
    \\        and not skipped.op and pos >= o.op_start and pos < o.op_end then
    \\        skipped.op = true
    \\        skip_section(o.op_end, "Skipping intro...")
    \\    end
    \\    if (o.mode == "outro" or o.mode == "both") and o.ed_start >= 0
    \\        and not skipped.ed and pos >= o.ed_start and pos < o.ed_end then
    \\        skipped.ed = true
    \\        skip_section(o.ed_end, "Skipping ending...")
    \\    end
    \\end)
    \\
    \\mp.register_event("file-loaded", function()
    \\    skipped.op = false
    \\    skipped.ed = false
    \\end)
    \\
;

/// Write `skip.lua` to the cache dir and return its absolute path. Always
/// rewrites: the script evolves between app versions, and a ~900-byte write once
/// per playback launch is cheaper than reasoning about staleness.
fn ensureScript(arena: Allocator, io: Io) ![]const u8 {
    const dir = try cacheDir(arena);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const path = try std.fmt.allocPrint(arena, "{s}/skip.lua", .{dir});

    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, LUA_SCRIPT);
    return path;
}

/// `$XDG_CACHE_HOME/zigoku`, falling back to `$HOME/.cache/zigoku`.
fn cacheDir(arena: Allocator) ![]const u8 {
    if (c.getenv("XDG_CACHE_HOME")) |x| {
        const base = std.mem.span(x);
        if (base.len > 0) return std.fmt.allocPrint(arena, "{s}/zigoku", .{base});
    }
    if (c.getenv("HOME")) |h| {
        const home = std.mem.span(h);
        if (home.len > 0) return std.fmt.allocPrint(arena, "{s}/.cache/zigoku", .{home});
    }
    return error.NoCacheDir;
}

// ── Tests ──────────────────────────────────────────────────────────────────────

test "timesFromResults maps op and ed, first of each wins" {
    const results = [_]ResultItem{
        .{ .interval = .{ .startTime = 12.5, .endTime = 84.3 }, .skipType = "op" },
        .{ .interval = .{ .startTime = 1340, .endTime = 1412 }, .skipType = "ed" },
        .{ .interval = .{ .startTime = 5, .endTime = 9 }, .skipType = "op" }, // ignored: op already set
    };
    const t = timesFromResults(&results);
    try std.testing.expectEqual(@as(?f64, 12.5), t.op_start);
    try std.testing.expectEqual(@as(?f64, 84.3), t.op_end);
    try std.testing.expectEqual(@as(?f64, 1340), t.ed_start);
    try std.testing.expectEqual(@as(?f64, 1412), t.ed_end);
}

test "timesFromResults leaves missing segments null" {
    const results = [_]ResultItem{
        .{ .interval = .{ .startTime = 12.5, .endTime = 84.3 }, .skipType = "op" },
    };
    const t = timesFromResults(&results);
    try std.testing.expectEqual(@as(?f64, null), t.ed_start);
    try std.testing.expectEqual(@as(?f64, null), t.ed_end);
}

test "timesFromResults drops degenerate intervals" {
    const results = [_]ResultItem{
        .{ .interval = .{ .startTime = 0, .endTime = 0 }, .skipType = "op" }, // zero-width
        .{ .interval = .{ .startTime = 100, .endTime = 50 }, .skipType = "ed" }, // inverted
    };
    const t = timesFromResults(&results);
    try std.testing.expectEqual(@as(?f64, null), t.op_start);
    try std.testing.expectEqual(@as(?f64, null), t.ed_start);
}

test "timesFromResults drops sub-second intervals" {
    const results = [_]ResultItem{
        .{ .interval = .{ .startTime = 10, .endTime = 10.5 }, .skipType = "op" }, // 0.5s
    };
    const t = timesFromResults(&results);
    try std.testing.expectEqual(@as(?f64, null), t.op_start);
}

test "timesFromResults parses real API field name (skipType)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const body =
        \\{"found":true,"results":[{"interval":{"startTime":3.221,"endTime":93.221},"skipType":"op","skipId":"x"},{"interval":{"startTime":1417.135,"endTime":1507.135},"skipType":"ed","skipId":"y"}]}
    ;
    const parsed = try std.json.parseFromSlice(Resp, arena.allocator(), body, .{ .ignore_unknown_fields = true });
    const t = timesFromResults(parsed.value.results);
    try std.testing.expectEqual(@as(?f64, 3.221), t.op_start);
    try std.testing.expectEqual(@as(?f64, 1507.135), t.ed_end);
}

test "buildOpts emits all keys with -1 for missing, gated by mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const both: SkipTimes = .{ .op_start = 12.5, .op_end = 84.3, .ed_start = 1340, .ed_end = 1412 };
    try std.testing.expectEqualStrings(
        "aniskip-op_start=12.5,aniskip-op_end=84.3,aniskip-ed_start=1340,aniskip-ed_end=1412,aniskip-mode=both",
        (try buildOpts(a, both, .both)).?,
    );

    // intro mode with only OP data: ED keys disabled.
    const op_only: SkipTimes = .{ .op_start = 12.5, .op_end = 84.3 };
    try std.testing.expectEqualStrings(
        "aniskip-op_start=12.5,aniskip-op_end=84.3,aniskip-ed_start=-1,aniskip-ed_end=-1,aniskip-mode=intro",
        (try buildOpts(a, op_only, .intro)).?,
    );
}

test "buildOpts returns null when no relevant interval or mode none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const op_only: SkipTimes = .{ .op_start = 12.5, .op_end = 84.3 };
    try std.testing.expectEqual(@as(?[]const u8, null), try buildOpts(a, op_only, .outro)); // wants ED, has none
    try std.testing.expectEqual(@as(?[]const u8, null), try buildOpts(a, .{}, .both)); // nothing at all
    try std.testing.expectEqual(@as(?[]const u8, null), try buildOpts(a, op_only, .none)); // disabled
}

test "episodeNumber parses raw label, falls back to ordinal" {
    try std.testing.expectEqual(@as(u32, 12), episodeNumber("12", 5));
    try std.testing.expectEqual(@as(u32, 1), episodeNumber("1", 1));
    try std.testing.expectEqual(@as(u32, 7), episodeNumber("12.5", 7)); // non-integer → ordinal
    try std.testing.expectEqual(@as(u32, 3), episodeNumber("OVA", 3));
}

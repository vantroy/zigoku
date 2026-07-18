//! CLI entry point (ROD-64). Scriptable path:
//! `zigoku <query> [--dub] [--quality …]` → search → pick → resolve → mpv.
//! Bare `zigoku` opens the TUI.

const std = @import("std");
const Io = std.Io;
const zigoku = @import("zigoku");

/// Zigoku log handler; `.debug` level so the runtime `--debug` gate works shipped.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = zigoku.log.logFn,
};

/// Live provider set and order (ROD-343): megaplay, senshi, allanime (ROD-380).
/// Slot order IS the default when `preferred_provider` is unset. Fat pointers
/// alias `self`: call `registry()` on a variable that outlives every use; don't
/// move it after. allanime is tier-B last (ROD-365).
const LiveProviders = struct {
    senshi: zigoku.Senshi,
    megaplay: zigoku.MegaPlay,
    allanime: zigoku.AllAnime,
    slots: [3]zigoku.SourceProvider,

    fn init() LiveProviders {
        return .{
            .senshi = zigoku.Senshi.init(),
            .megaplay = zigoku.MegaPlay.init(),
            .allanime = zigoku.AllAnime.init(),
            .slots = undefined,
        };
    }

    fn registry(self: *LiveProviders) zigoku.Registry {
        // Order = default fallback. megaplay leads; allanime trails as tier-B.
        self.slots = .{ self.megaplay.provider(), self.senshi.provider(), self.allanime.provider() };
        return .{ .providers = &self.slots };
    }
};

const Cli = struct {
    query: []const u8,
    translation: zigoku.Translation = .sub,
    /// Parsed; CLI quality select not fully wired (config default_quality used in resolve).
    quality: []const u8 = "best",
};

const PlaybackProgress = struct {
    time_pos_bits: std.atomic.Value(u64) = .init(0),
    duration_bits: std.atomic.Value(u64) = .init(0),
    seen_update: std.atomic.Value(bool) = .init(false),

    fn record(self: *PlaybackProgress, update: zigoku.player.PositionUpdate) void {
        self.time_pos_bits.store(@bitCast(update.time_pos), .release);
        self.duration_bits.store(@bitCast(update.duration), .release);
        self.seen_update.store(true, .release);
    }

    fn snapshot(self: *PlaybackProgress) ?zigoku.player.PositionUpdate {
        if (!self.seen_update.load(.acquire)) return null;
        return .{
            .time_pos = @bitCast(self.time_pos_bits.load(.acquire)),
            .duration = @bitCast(self.duration_bits.load(.acquire)),
        };
    }
};

fn recordPlaybackProgress(ctx: *anyopaque, update: zigoku.player.PositionUpdate) void {
    const progress: *PlaybackProgress = @ptrCast(@alignCast(ctx));
    progress.record(update);
}

fn observedPlaybackWasMeaningful(latest: ?zigoku.player.PositionUpdate) bool {
    const update = latest orelse return false;
    return update.isMeaningful();
}

/// ROD-168: store completion bar. Gates recordPlay high-water so a short watch
/// does not mark the episode done.
fn observedPlaybackCompleted(latest: ?zigoku.player.PositionUpdate) bool {
    const update = latest orelse return false;
    return update.reachedCompletion(zigoku.store.NATURAL_END_RATIO);
}

fn persistFinalProgress(
    st: *zigoku.Store,
    source: []const u8,
    source_id: []const u8,
    tt: zigoku.Translation,
    episode: []const u8,
    latest: ?zigoku.player.PositionUpdate,
) void {
    const update = latest orelse return;
    st.saveProgress(source, source_id, tt, episode, update.time_pos, update.duration, zigoku.Store.nowSecs()) catch |e|
        std.log.debug("saveProgress failed: {s}", .{@errorName(e)});
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    // ROD-88: set before workers/TUI so the gate is stable for the run.
    if (zigoku.log.envDebug() or hasFlag(args, "--debug")) zigoku.log.debug_enabled = true;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_fw.interface;

    // ROD-221: version before config/store/network (not via UnknownFlag→usage).
    if (try handleVersionFlag(args, out)) {
        try out.flush();
        return;
    }

    // ROD-283: subcommand, not a flag; intercept before query parse. Loopback
    // default; `--paste` or LoopbackUnavailable → manual paste.
    if (isLoginCommand(args)) {
        const signed_in: bool = if (hasFlag(args, "--paste"))
            try zigoku.login.run(arena, io, out)
        else
            zigoku.login_loopback.run(arena, io, out) catch |err| switch (err) {
                error.LoopbackUnavailable => blk: {
                    try out.print("  (couldn't start the loopback listener — falling back to paste)\n\n", .{});
                    break :blk try zigoku.login.run(arena, io, out);
                },
                else => return err,
            };
        // ROD-292: bootstrap sync only if a token landed (failed login → no summary).
        if (signed_in) {
            try out.writeByte('\n');
            try runSync(arena, io, out);
        }
        try out.flush();
        return;
    }

    // ROD-284: subcommand; delta push/pull via runSync.
    if (isSyncCommand(args)) {
        try runSync(arena, io, out);
        try out.flush();
        return;
    }

    // ROD-371: in-place update / package-manager hint / refuse root-owned install.
    if (isUpdateCommand(args)) {
        try zigoku.update.run(arena, io, out, zigoku.version, init.environ_map);
        try out.flush();
        return;
    }

    var stdin_buf: [256]u8 = undefined;
    var stdin_fr: Io.File.Reader = Io.File.stdin().reader(io, &stdin_buf);
    const in = &stdin_fr.interface;

    // ROD-85: total load (missing → defaults). null path when no XDG/HOME (empty
    // path would panic openFileAbsolute in debug). Path kept for Settings save (ROD-86).
    const cfg_path: ?[]const u8 = zigoku.config.defaultPath(arena) catch null;
    const cfg = if (cfg_path) |p| zigoku.config.load(arena, io, p) else zigoku.Config{};

    const cli = parseArgs(arena, args) catch |err| switch (err) {
        // No query → TUI (also bare flags like `zigoku --dub`). Bad flags → usage.
        error.NoQuery => return runTui(init, arena, cfg, cfg_path),
        else => {
            try usage(out);
            try out.flush();
            return;
        },
    };

    // Best-effort store: note once, continue without history/resume.
    var store_opt: ?zigoku.Store = openStore(arena) catch |err| blk: {
        try out.print("  (note: persistence off — {s})\n", .{describeOpenStoreError(err)});
        break :blk null;
    };
    defer if (store_opt) |*st| st.close();

    // One preferred provider for the run (ROD-344); CLI does not walk the registry.
    var live = LiveProviders.init();
    const provider = live.registry().preferred(cfg.preferred_provider);

    run(arena, io, out, in, cli, cfg, provider, if (store_opt) |*st| st else null) catch |err| {
        try reportError(out, err, provider.displayName());
        try out.flush();
        std.process.exit(1);
    };
    try out.flush();
}

fn openStore(arena: std.mem.Allocator) !zigoku.Store {
    const path = try zigoku.store.defaultDbPath(arena);
    return zigoku.Store.open(path);
}

/// Shared by CLI note and runSync (ROD-284): one wording per open-error variant.
fn describeOpenStoreError(err: anyerror) []const u8 {
    return switch (err) {
        error.SchemaTooNew => "DB was written by a newer Zigoku — delete it to start fresh",
        error.NoHomeDir => "couldn't locate a data directory (no $HOME/$XDG_DATA_HOME)",
        error.Unsupported => "this platform isn't supported yet (no data directory)",
        // ROD-287: WAL race or half-migrated schema → Exec; name it for the note.
        error.Exec => "the database was busy or its schema conflicted — running without history this session",
        error.Open => "couldn't open the database file — running without history this session",
        else => @errorName(err),
    };
}

/// `zigoku sync`: pull then push (ROD-285/284). Best-effort; engines return
/// summaries, never error.
fn runSync(arena: std.mem.Allocator, io: Io, out: *Io.Writer) !void {
    var store = openStore(arena) catch |err| {
        try out.print("  sync: no local library to push — {s}\n", .{describeOpenStoreError(err)});
        return;
    };
    defer store.close();

    const auth_path = zigoku.auth.defaultPath(arena) catch {
        try out.print("  sync: couldn't locate a config directory for the token\n", .{});
        return;
    };
    const credentials = zigoku.auth.load(arena, io, auth_path);
    const now = zigoku.Store.nowSecs();

    // Announce only when connected+unexpired (same gate as engines). Flush before paced push.
    const usable = credentials.hasAniList() and !credentials.anilist.isExpired(now);
    if (usable) {
        try out.print("  syncing with AniList — this can take a moment…\n", .{});
        try out.flush();
    }

    // Pull FIRST (ROD-285), then push (ROD-284). First-sync hazard: pushAll is a
    // blind upsert and never-synced rows are dirty, so push-first overwrites AniList
    // history with local defaults before the 3-way merge. Pull lands remote progress
    // (max); push then carries the merged value.
    var skip_push = false;
    if (usable) {
        const pull = zigoku.sync.pullAll(arena, io, &store, credentials, now);
        try printPullSummary(out, pull);
        // Skip push on walls the push would hit too (token/rate/store). Fetch miss
        // does not gate: push has its own transport. ROD-287: avoid double stall.
        skip_push = pull.unauthorized or pull.rate_limited or pull.store_error;
    }

    // When unusable, pull is silent on signed-out/expired; push summary owns those lines.
    if (!skip_push) {
        const push = zigoku.sync.pushAll(arena, io, &store, credentials, now);
        try printSyncSummary(out, push);
        // Unlinked engaged shows: actionable list under the count. Best-effort.
        if (push.no_link > 0) {
            const unlinked = store.loadEngagedWithoutAniListId(arena) catch &.{};
            try printShowList(out, unlinked);
        }
    }
}

/// Cap on inline show titles before "… and N more".
const SHOW_LIST_CAP: usize = 12;

fn printShowList(out: *Io.Writer, titles: []const []const u8) !void {
    const shown = @min(titles.len, SHOW_LIST_CAP);
    for (titles[0..shown]) |t| try out.print("      · {s}\n", .{t});
    if (titles.len > shown) try out.print("      … and {d} more\n", .{titles.len - shown});
}

/// PullSummary (ROD-285) → human text. signed-out/expired silent here (push owns them).
fn printPullSummary(out: *Io.Writer, s: zigoku.sync.PullSummary) !void {
    if (s.signed_out or s.expired) return; // push already said it
    if (s.no_user_id) {
        try out.print("  pull skipped: can't tell which AniList account this token is for — run `zigoku login` to reconnect.\n", .{});
        return;
    }
    if (s.unauthorized) {
        try out.print("  pull stopped: AniList rejected the token — run `zigoku login` to reconnect.\n", .{});
        return;
    }
    if (s.rate_limited) {
        try out.print("  pull stopped: hit AniList's rate limit — run `zigoku sync` again shortly.\n", .{});
        return;
    }
    if (s.fetch_failed) {
        try out.print("  pull failed: couldn't fetch your AniList list — re-run with --debug for details.\n", .{});
        return;
    }
    if (s.store_error) {
        try out.print("  pull: couldn't read the local library; nothing reconciled.\n", .{});
        return;
    }

    if (s.updated > 0) {
        try out.print("  pulled {d} update(s) from AniList.\n", .{s.updated});
    } else if (s.conflicts == 0) {
        // Suppress "up to date" when conflicts > 0 (still dirty for push).
        try out.print("  already up to date — nothing to pull in.\n", .{});
    }
    if (s.conflicts > 0) try out.print("  ({d} show(s) kept your local status over AniList's — they'll push back up next sync.)\n", .{s.conflicts});
    if (s.contended > 0) try out.print("  ({d} show(s) changed mid-sync — left as-is, will reconcile next run.)\n", .{s.contended});
    if (s.failed > 0) try out.print("  {d} local update(s) failed to save — re-run with --debug for details.\n", .{s.failed});
    if (s.unmatched > 0) {
        try out.print("  ({d} AniList show(s) aren't in your local library yet — not imported.)\n", .{s.unmatched});
        const shown = @min(s.unmatched_ids.len, SHOW_LIST_CAP);
        for (s.unmatched_ids[0..shown]) |id| try out.print("      · anilist.co/anime/{d}\n", .{id});
        if (s.unmatched_ids.len > shown) try out.print("      … and {d} more\n", .{s.unmatched_ids.len - shown});
    }
}

/// Push Summary (ROD-284) → human text.
fn printSyncSummary(out: *Io.Writer, s: zigoku.sync.Summary) !void {
    if (s.signed_out) {
        try out.print("  not connected — run `zigoku login` first.\n", .{});
        return;
    }
    if (s.expired) {
        try out.print("  your AniList token has expired — run `zigoku login` to reconnect.\n", .{});
        return;
    }
    if (s.store_error) {
        try out.print("  couldn't read the local library; nothing pushed.\n", .{});
        return;
    }

    if (s.dirty == 0) {
        try out.print("  already up to date — nothing to push.\n", .{});
    } else {
        try out.print("  pushed {d} of {d} change(s) to AniList.\n", .{ s.pushed, s.dirty });
    }
    if (s.failed > 0) try out.print("  {d} push(es) failed — re-run with --debug for details.\n", .{s.failed});
    if (s.unauthorized) try out.print("  stopped: AniList rejected the token mid-run — run `zigoku login` to reconnect.\n", .{});
    if (s.rate_limited) try out.print("  stopped: hit AniList's rate limit — run `zigoku sync` again shortly to finish.\n", .{});
    if (s.no_link > 0) try out.print("  ({d} show(s) have no AniList match yet, so they can't sync.)\n", .{s.no_link});
}

/// TUI (ROD-71). Store best-effort: empty history rather than refuse to run.
fn runTui(init: std.process.Init, arena: std.mem.Allocator, cfg: zigoku.Config, cfg_path: ?[]const u8) !void {
    // stderr is the render surface: diagnostics go to a file when possible.
    if (zigoku.paths.dataDir(arena)) |dir| {
        zigoku.paths.ensureDir(dir);
        zigoku.log.file_path = std.fmt.allocPrint(arena, "{s}/zigoku.log", .{dir}) catch null;
    } else |_| {}

    // Log store-open failure only if file_path is set. With no data dir, file_path
    // is null and log.zig would dump to stderr into the TUI's terminal (ROD-287).
    var store_opt: ?zigoku.Store = openStore(arena) catch |err| blk: {
        if (zigoku.log.file_path != null)
            std.log.warn("persistence off — {s}", .{describeOpenStoreError(err)});
        break :blk null;
    };
    defer if (store_opt) |*st| st.close();

    // ROD-308: one-time provider-cutover backfill (anilist_id→idMal for pre-idMal
    // rows). Marker-gated no-op after migrate. Before vaxis so progress hits scrollback.
    if (store_opt) |*st| {
        var mig_buf: [4096]u8 = undefined;
        var mig_fw: Io.File.Writer = .init(.stdout(), init.io, &mig_buf);
        const mig_out = &mig_fw.interface;
        _ = zigoku.provider_migrate.run(init.gpa, init.io, st, mig_out) catch |err| {
            if (zigoku.log.file_path != null)
                std.log.warn("provider backfill deferred — {s}", .{@errorName(err)});
        };
    }

    var live = LiveProviders.init();
    try zigoku.tui.run(init.gpa, init.io, init.environ_map, if (store_opt) |*st| st else null, live.registry(), cfg, cfg_path, zigoku.version);
}

/// CLI vertical slice. `store` optional: persistence never blocks playback.
fn run(arena: std.mem.Allocator, io: Io, out: *Io.Writer, in: *Io.Reader, cli: Cli, cfg: zigoku.Config, provider: zigoku.SourceProvider, store: ?*zigoku.Store) !void {
    try zigoku.writeBanner(out);
    if (!std.mem.eql(u8, cli.quality, "best")) {
        try out.print("\n  (note: --quality isn't wired up yet — playback uses the highest direct stream available.)\n", .{});
    }

    const SOURCE = provider.name();

    try out.print("\n→ searching {s} for \"{s}\" ({s})…\n", .{ provider.displayName(), cli.query, cli.translation.str() });
    try out.flush();

    const results = try provider.search(arena, io, cli.query, .{ .translation = cli.translation, .limit = 20 });
    if (results.len == 0) {
        try out.print("\n  no results for \"{s}\". Try a different spelling or romaji.\n", .{cli.query});
        return;
    }

    try out.print("\n  {d} results:\n\n", .{results.len});
    for (results, 0..) |a, i| {
        // Per-track when split; else total (senshi); never false "0 {track}" (ROD-301).
        const per_track = a.episodeCount(cli.translation);
        if (per_track > 0) {
            try out.print("  {d:>2}. {s}  ·  {d} {s} eps\n", .{ i + 1, a.name, per_track, cli.translation.str() });
        } else if (a.total_episodes) |t| {
            try out.print("  {d:>2}. {s}  ·  {d} eps\n", .{ i + 1, a.name, t });
        } else {
            try out.print("  {d:>2}. {s}\n", .{ i + 1, a.name });
        }
    }

    const show_idx = (try promptChoice(out, in, "\n  pick a show # (q to quit): ", results.len)) orelse {
        try out.writeAll("\n  bye.\n");
        return;
    };
    const show = results[show_idx];

    // ROD-66/97: upsert metadata; preserve play_count/progress/status.
    if (store) |st| st.upsertAnime(zigoku.AnimeRecord.fromDomain(SOURCE, show, cli.translation), zigoku.Store.nowSecs(), arena) catch |e|
        std.log.debug("upsertAnime failed: {s}", .{@errorName(e)});

    // ROD-68: cache-first episodes.
    const eps = try loadEpisodes(arena, io, out, provider, store, SOURCE, show, cli.translation);
    if (eps.len == 0) {
        try out.print("\n  no {s} episodes listed for this show.\n", .{cli.translation.str()});
        return;
    }

    try out.print("\n  {d} episodes:\n\n", .{eps.len});
    for (eps, 0..) |e, i| {
        try out.print("  {d:>3}. ep {s}\n", .{ i + 1, e.raw });
    }

    const ep_idx = (try promptChoice(out, in, "\n  pick an episode # (q to quit): ", eps.len)) orelse {
        try out.writeAll("\n  bye.\n");
        return;
    };
    const episode = eps[ep_idx];

    // ROD-69: resume position if any.
    var start_seconds: u64 = 0;
    if (store) |st| {
        if (st.getResume(SOURCE, show.id, cli.translation, episode.raw) catch null) |r| {
            start_seconds = r.startSecondsRewound(cfg.resume_offset_sec);
            if (start_seconds > 0) try out.print("  ↺ resuming at {d}s\n", .{start_seconds});
        }
    }

    try out.print("\n→ resolving ep {s} ({s})…\n", .{ episode.raw, cli.translation.str() });
    try out.flush();

    const link = try provider.resolve(arena, io, show.id, episode, cli.translation, zigoku.Quality.fromString(cfg.default_quality));
    const res_str = if (link.resolution) |r| r else 0;
    try out.print("  ✓ stream resolved ({d}p)\n", .{res_str});

    const title = try std.fmt.allocPrint(arena, "{s} — ep {s}", .{ show.name, episode.raw });

    // ROD-83: OP/ED skip. MAL from enrich (live or ROD-82 cache); else Jikan in prepare.
    var known_mal: ?u32 = if (show.mal_id) |m| std.math.cast(u32, m) else null;
    if (known_mal == null) {
        if (store) |st| {
            if (st.getAnime(arena, SOURCE, show.id) catch null) |rec| {
                if (rec.mal_id) |m| known_mal = std.math.cast(u32, m) orelse null;
            }
        }
    }
    // CLI is single-threaded: announce before Jikan/AniSkip round-trips.
    try out.print("  ⏭ checking skip data…\n", .{});
    try out.flush();
    const skip = zigoku.aniskip.prepare(arena, io, known_mal, show.name, zigoku.aniskip.episodeNumber(episode.raw, @intCast(ep_idx + 1)), zigoku.aniskip.SkipMode.fromString(cfg.skip_mode));

    try out.print("  ▶ launching mpv…\n", .{});
    try out.flush();

    var progress: PlaybackProgress = .{};
    zigoku.proxy.play(arena, io, cfg.mpv_path, link, title, start_seconds, .{
        .ctx = @ptrCast(&progress),
        .func = recordPlaybackProgress,
    }, skip) catch |err| {
        if (store) |st| {
            const latest = progress.snapshot();
            if (observedPlaybackWasMeaningful(latest)) {
                persistFinalProgress(st, SOURCE, show.id, cli.translation, episode.raw, latest);
                if (err == error.MpvFailed) st.recordPlay(SOURCE, show.id, @intCast(ep_idx + 1), zigoku.Store.nowSecs(), observedPlaybackCompleted(latest)) catch |e|
                    std.log.debug("recordPlay failed: {s}", .{@errorName(e)});
            }
        }
        return err;
    };

    if (store) |st| {
        const latest = progress.snapshot();
        if (observedPlaybackWasMeaningful(latest)) {
            persistFinalProgress(st, SOURCE, show.id, cli.translation, episode.raw, latest);
        }
        st.recordPlay(SOURCE, show.id, @intCast(ep_idx + 1), zigoku.Store.nowSecs(), observedPlaybackCompleted(latest)) catch |e|
            std.log.debug("recordPlay failed: {s}", .{@errorName(e)});
    }

    try out.print("\n✓ done. That was Zigoku, end to end.\n", .{});
}

test "live registry leads with megaplay as the default provider (ROD-380)" {
    // Slot order IS the default when preference is unset.
    var live = LiveProviders.init();
    const reg = live.registry();
    try std.testing.expectEqualStrings("megaplay", reg.primary().name());
    try std.testing.expectEqualStrings("megaplay", reg.preferred("").name());
    var it = reg.ordered("");
    try std.testing.expectEqualStrings("megaplay", it.next().?.name());
    try std.testing.expect(reg.byName("senshi") != null);
}

test "live registry registers allanime as the tier-B backstop, last (ROD-365)" {
    // allanime LAST: reorder would make it tier-A-eligible first.
    var live = LiveProviders.init();
    const reg = live.registry();
    try std.testing.expectEqual(@as(usize, 3), reg.providers.len);
    try std.testing.expect(reg.byName("allanime") != null);
    var it = reg.ordered("");
    try std.testing.expectEqualStrings("megaplay", it.next().?.name());
    try std.testing.expectEqualStrings("senshi", it.next().?.name());
    try std.testing.expectEqualStrings("allanime", it.next().?.name());
    try std.testing.expect(it.next() == null);
}

test "observedPlaybackWasMeaningful requires positive observed position" {
    try std.testing.expect(!observedPlaybackWasMeaningful(null));
    try std.testing.expect(!observedPlaybackWasMeaningful(.{ .time_pos = 0, .duration = 1440 }));
    try std.testing.expect(!observedPlaybackWasMeaningful(.{ .time_pos = -1, .duration = 1440 }));
    try std.testing.expect(observedPlaybackWasMeaningful(.{ .time_pos = 0.5, .duration = 1440 }));
}

test "observedPlaybackCompleted requires reaching the completion bar" {
    try std.testing.expect(!observedPlaybackCompleted(null));
    try std.testing.expect(!observedPlaybackCompleted(.{ .time_pos = 5, .duration = 1440 })); // short watch
    try std.testing.expect(!observedPlaybackCompleted(.{ .time_pos = 1200, .duration = 0 })); // unknown duration
    try std.testing.expect(observedPlaybackCompleted(.{ .time_pos = 1300, .duration = 1440 })); // ~90%
}

/// Cache-first episodes (ROD-68); best-effort store warm.
fn loadEpisodes(
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    provider: zigoku.SourceProvider,
    store: ?*zigoku.Store,
    source: []const u8,
    show: zigoku.Anime,
    tt: zigoku.Translation,
) ![]zigoku.EpisodeNumber {
    if (store) |st| {
        if (st.getCachedEpisodes(arena, source, show.id, tt, zigoku.Store.nowSecs()) catch null) |cached| {
            try out.print("\n→ episodes for \"{s}\" (cached)\n", .{show.name});
            return cached;
        }
    }

    try out.print("\n→ fetching episodes for \"{s}\"…\n", .{show.name});
    try out.flush();
    // CLI picks from provider search: show already has catalog metadata for the count hint.
    const fetched = try provider.episodes(arena, io, show.id, tt, zigoku.domain.expectedEpisodeCount(show));

    if (store) |st| {
        if (fetched.len > 0)
            st.putCachedEpisodes(source, show.id, tt, fetched, show.status, zigoku.Store.nowSecs(), arena) catch |e|
                std.log.debug("putCachedEpisodes failed: {s}", .{@errorName(e)});
    }
    return fetched;
}

/// 1-based choice in [1, max] → 0-based index; null on q/EOF. Re-prompts on garbage.
fn promptChoice(out: *Io.Writer, in: *Io.Reader, prompt: []const u8, max: usize) !?usize {
    while (true) {
        try out.writeAll(prompt);
        try out.flush();

        // Inclusive: exclusive leaves '\n' and next read returns "" forever.
        const line = in.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return null,
            error.StreamTooLong => return null,
            else => return err,
        };
        const t = std.mem.trim(u8, line, " \t\r\n");
        if (t.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(t, "q")) return null;

        const n = std.fmt.parseInt(usize, t, 10) catch {
            try out.print("  ? enter a number 1–{d} (or q)\n", .{max});
            continue;
        };
        if (n < 1 or n > max) {
            try out.print("  ? out of range — pick 1–{d}\n", .{max});
            continue;
        }
        return n - 1;
    }
}

/// Query words + flags. error.NoQuery when no positional.
fn parseArgs(arena: std.mem.Allocator, args: []const [:0]const u8) !Cli {
    var words: std.ArrayList([]const u8) = .empty;
    var cli: Cli = .{ .query = "" };

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--dub")) {
            cli.translation = .dub;
        } else if (std.mem.eql(u8, a, "--sub")) {
            cli.translation = .sub;
        } else if (std.mem.eql(u8, a, "--quality")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            cli.quality = args[i];
        } else if (std.mem.startsWith(u8, a, "--quality=")) {
            cli.quality = a["--quality=".len..];
        } else if (std.mem.eql(u8, a, "--debug")) {
            // Handled in main; consume so it is not a query word or UnknownFlag.
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.UnknownFlag;
        } else {
            try words.append(arena, a);
        }
    }

    if (words.items.len == 0) return error.NoQuery;
    cli.query = try std.mem.join(arena, " ", words.items);
    return cli;
}

fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

/// Position-independent so `zigoku frieren --version` still reports version.
fn hasVersionFlag(args: []const [:0]const u8) bool {
    return hasFlag(args, "--version") or hasFlag(args, "-V");
}

/// First non-flag positional equals `name` (flags may precede). After a real
/// query word, `name` is search text, not the subcommand.
fn isSubcommand(args: []const [:0]const u8, name: []const u8) bool {
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, name)) return true;
        if (!std.mem.startsWith(u8, a, "-")) return false; // first positional wasn't it
    }
    return false;
}

fn isLoginCommand(args: []const [:0]const u8) bool {
    return isSubcommand(args, "login");
}

fn isSyncCommand(args: []const [:0]const u8) bool {
    return isSubcommand(args, "sync");
}

fn isUpdateCommand(args: []const [:0]const u8) bool {
    return isSubcommand(args, "update");
}

/// ROD-221: version dispatch factored for unit tests. true → caller exits before work.
fn handleVersionFlag(args: []const [:0]const u8, out: *Io.Writer) !bool {
    if (!hasVersionFlag(args)) return false;
    try zigoku.writeVersion(out);
    return true;
}

test "hasVersionFlag detects --version and -V anywhere, ignores others" {
    const v1 = [_][:0]const u8{ "zigoku", "--version" };
    const v2 = [_][:0]const u8{ "zigoku", "frieren", "-V" };
    const none = [_][:0]const u8{ "zigoku", "frieren", "--dub" };
    const bare = [_][:0]const u8{"zigoku"};
    try std.testing.expect(hasVersionFlag(&v1));
    try std.testing.expect(hasVersionFlag(&v2));
    try std.testing.expect(!hasVersionFlag(&none));
    try std.testing.expect(!hasVersionFlag(&bare));
}

test "isLoginCommand accepts login behind flags, rejects it as a query word" {
    try std.testing.expect(isLoginCommand(&[_][:0]const u8{ "zigoku", "login" }));
    try std.testing.expect(isLoginCommand(&[_][:0]const u8{ "zigoku", "--debug", "login" }));
    try std.testing.expect(!isLoginCommand(&[_][:0]const u8{ "zigoku", "frieren" }));
    try std.testing.expect(!isLoginCommand(&[_][:0]const u8{ "zigoku", "frieren", "login" }));
    try std.testing.expect(!isLoginCommand(&[_][:0]const u8{"zigoku"}));
}

test "isSyncCommand accepts sync behind flags, rejects it as a query word (ROD-284)" {
    try std.testing.expect(isSyncCommand(&[_][:0]const u8{ "zigoku", "sync" }));
    try std.testing.expect(isSyncCommand(&[_][:0]const u8{ "zigoku", "--debug", "sync" }));
    try std.testing.expect(!isSyncCommand(&[_][:0]const u8{ "zigoku", "frieren" }));
    try std.testing.expect(!isSyncCommand(&[_][:0]const u8{ "zigoku", "frieren", "sync" }));
    try std.testing.expect(!isSyncCommand(&[_][:0]const u8{"zigoku"}));
}

test "isUpdateCommand accepts update behind flags, rejects it as a query word (ROD-371)" {
    try std.testing.expect(isUpdateCommand(&[_][:0]const u8{ "zigoku", "update" }));
    try std.testing.expect(isUpdateCommand(&[_][:0]const u8{ "zigoku", "--debug", "update" }));
    try std.testing.expect(!isUpdateCommand(&[_][:0]const u8{ "zigoku", "frieren" }));
    try std.testing.expect(!isUpdateCommand(&[_][:0]const u8{ "zigoku", "frieren", "update" }));
    try std.testing.expect(!isUpdateCommand(&[_][:0]const u8{"zigoku"}));
}

fn renderSummary(s: zigoku.sync.Summary, buf: *std.Io.Writer.Allocating) ![]const u8 {
    try printSyncSummary(&buf.writer, s);
    return buf.writer.buffered();
}

test "printSyncSummary: each mutually-exclusive lead line (ROD-284)" {
    const Case = struct { s: zigoku.sync.Summary, needle: []const u8 };
    const cases = [_]Case{
        .{ .s = .{ .signed_out = true }, .needle = "not connected" },
        .{ .s = .{ .expired = true }, .needle = "expired" },
        .{ .s = .{ .store_error = true }, .needle = "couldn't read" },
        .{ .s = .{ .dirty = 0 }, .needle = "already up to date" },
        .{ .s = .{ .dirty = 5, .pushed = 5 }, .needle = "pushed 5 of 5" },
    };
    for (cases) |c| {
        var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer aw.deinit();
        try std.testing.expect(std.mem.indexOf(u8, try renderSummary(c.s, &aw), c.needle) != null);
    }
}

test "printSyncSummary: advisory footers stack onto the tally (ROD-284)" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const out = try renderSummary(.{ .dirty = 4, .pushed = 2, .failed = 1, .rate_limited = true, .no_link = 3 }, &aw);
    try std.testing.expect(std.mem.indexOf(u8, out, "pushed 2 of 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "rate limit") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "no AniList match") != null);
    // Signed-out lead short-circuits: no tally/footers.
    var aw2 = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw2.deinit();
    const out2 = try renderSummary(.{ .signed_out = true, .no_link = 9 }, &aw2);
    try std.testing.expect(std.mem.indexOf(u8, out2, "no AniList match") == null);
    // The unauthorized footer stacks onto the tally like the others.
    var aw3 = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw3.deinit();
    const out3 = try renderSummary(.{ .dirty = 3, .pushed = 1, .unauthorized = true }, &aw3);
    try std.testing.expect(std.mem.indexOf(u8, out3, "pushed 1 of 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out3, "rejected the token") != null);
}

fn renderPull(s: zigoku.sync.PullSummary, buf: *std.Io.Writer.Allocating) ![]const u8 {
    try printPullSummary(&buf.writer, s);
    return buf.writer.buffered();
}

test "printPullSummary: each mutually-exclusive lead line (ROD-285)" {
    const Case = struct { s: zigoku.sync.PullSummary, needle: []const u8 };
    const cases = [_]Case{
        .{ .s = .{ .no_user_id = true }, .needle = "which AniList account" },
        .{ .s = .{ .unauthorized = true }, .needle = "rejected the token" },
        .{ .s = .{ .rate_limited = true }, .needle = "rate limit" },
        .{ .s = .{ .fetch_failed = true }, .needle = "couldn't fetch" },
        .{ .s = .{ .store_error = true }, .needle = "couldn't read" },
        .{ .s = .{ .updated = 0 }, .needle = "already up to date" },
        .{ .s = .{ .reconciled = 3, .updated = 2 }, .needle = "pulled 2 update" },
    };
    for (cases) |c| {
        var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer aw.deinit();
        try std.testing.expect(std.mem.indexOf(u8, try renderPull(c.s, &aw), c.needle) != null);
    }
}

test "printPullSummary: advisory footers stack; a lead line short-circuits (ROD-285)" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const unmatched_ids = [_]i64{ 12345, 67890 };
    const out = try renderPull(.{ .remote_entries = 9, .reconciled = 4, .updated = 2, .conflicts = 1, .contended = 1, .failed = 1, .unmatched = 2, .unmatched_ids = &unmatched_ids }, &aw);
    try std.testing.expect(std.mem.indexOf(u8, out, "pulled 2 update") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "kept your local status") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "changed mid-sync") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "failed to save") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "not imported") != null);
    // The unmatched ids print as lookup links under the count line.
    try std.testing.expect(std.mem.indexOf(u8, out, "anilist.co/anime/12345") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "anilist.co/anime/67890") != null);
    // updated==0 with conflicts must not print "up to date"; conflicts footer only.
    var aw2 = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw2.deinit();
    const out2 = try renderPull(.{ .reconciled = 2, .updated = 0, .conflicts = 2 }, &aw2);
    try std.testing.expect(std.mem.indexOf(u8, out2, "already up to date") == null);
    try std.testing.expect(std.mem.indexOf(u8, out2, "kept your local status") != null);
    // no-user-id lead short-circuits: no tally/footers.
    var aw3 = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw3.deinit();
    const out3 = try renderPull(.{ .no_user_id = true, .unmatched = 9 }, &aw3);
    try std.testing.expect(std.mem.indexOf(u8, out3, "not imported") == null);
}

test "printShowList: bullets the titles, collapses past the cap (ROD-285)" {
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    const three = [_][]const u8{ "Alpha", "Beta", "Gamma" };
    try printShowList(&aw.writer, &three);
    const out = aw.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "· Alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "· Gamma") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "more") == null); // under the cap, no collapse

    // Over the cap → first SHOW_LIST_CAP shown, the remainder collapsed to a count.
    var many: [SHOW_LIST_CAP + 3][]const u8 = undefined;
    for (&many) |*m| m.* = "Show";
    var aw2 = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw2.deinit();
    try printShowList(&aw2.writer, &many);
    try std.testing.expect(std.mem.indexOf(u8, aw2.writer.buffered(), "… and 3 more") != null);
}

test "handleVersionFlag emits the version line and signals exit only on a version flag" {
    // Flag present → version line (not usage), true so main exits before work.
    {
        var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer aw.deinit();
        const args = [_][:0]const u8{ "zigoku", "frieren", "--version" };
        const handled = try handleVersionFlag(&args, &aw.writer);
        try std.testing.expect(handled);
        const printed = aw.writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, printed, zigoku.version) != null);
        try std.testing.expect(std.mem.indexOf(u8, printed, "usage:") == null);
    }
    {
        var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer aw.deinit();
        const args = [_][:0]const u8{ "zigoku", "frieren" };
        const handled = try handleVersionFlag(&args, &aw.writer);
        try std.testing.expect(!handled);
        try std.testing.expectEqual(@as(usize, 0), aw.writer.buffered().len);
    }
}

fn usage(out: *Io.Writer) !void {
    try zigoku.writeBanner(out);
    try out.writeAll(
        \\
        \\  usage: zigoku <query> [--dub] [--debug]
        \\         zigoku --version
        \\
        \\    zigoku frieren
        \\    zigoku "cowboy bebop" --dub
        \\    zigoku --version
        \\
        \\  --version (or -V) prints the version and exits.
        \\  --debug (or ZIGOKU_DEBUG=1) writes diagnostics: stderr in CLI mode,
        \\  ~/.local/share/zigoku/zigoku.log in the TUI.
        \\
    );
}

/// Human error line. `source_name` from provider.displayName(); never hardcode the site.
fn reportError(out: *Io.Writer, err: anyerror, source_name: []const u8) !void {
    var buf: [256]u8 = undefined;
    const msg: []const u8 = switch (err) {
        error.MpvNotFound => "mpv isn't on your PATH. Install mpv and try again.",
        error.MpvFailed => "mpv exited badly (closed early, or couldn't play the stream).",
        error.MpvOpenFailed => "couldn't open the stream (the CDN blocked the request — try again in a moment).",
        error.NoDirectStream => "found the episode, but it only offers stream providers we can't resolve yet — try another show or episode for now.",
        error.NoSearchData => std.fmt.bufPrint(&buf, "{s} returned nothing for that search.", .{source_name}) catch @errorName(err),
        error.ShowNotFound, error.NoEpisodeData => std.fmt.bufPrint(&buf, "{s} had no episode data for that show.", .{source_name}) catch @errorName(err),
        error.NotEncrypted => std.fmt.bufPrint(&buf, "{s} returned an unexpected (unencrypted) video payload — the protocol may have shifted.", .{source_name}) catch @errorName(err),
        // ROD-173 POST classes; CLI can be more instructional than §4.7 toasts.
        error.NetworkDown => std.fmt.bufPrint(&buf, "can't reach {s} — check your network connection, then try again.", .{source_name}) catch @errorName(err),
        error.Forbidden => std.fmt.bufPrint(&buf, "{s} is blocking the request (HTTP 403/451). A VPN may get you through.", .{source_name}) catch @errorName(err),
        error.ServerError => std.fmt.bufPrint(&buf, "{s}'s servers are down (HTTP 5xx). Nothing to do but wait and retry.", .{source_name}) catch @errorName(err),
        error.HttpNotOk => std.fmt.bufPrint(&buf, "{s} rejected the request (unexpected HTTP error). The site may be down, or the recipe drifted.", .{source_name}) catch @errorName(err),
        else => @errorName(err),
    };
    try out.print("\n✗ {s}\n", .{msg});
}

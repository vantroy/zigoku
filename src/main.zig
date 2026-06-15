//! Zigoku — CLI entry point (ROD-64).
//!
//! The first runnable Zigoku and the close of the M1 vertical slice:
//!
//!     zigoku <query> [--dub] [--quality best|1080|720|480|worst]
//!
//! → search → pick a show → pick an episode → resolve → play in mpv.
//!
//! The TUI (libvaxis) replaces this prompt-driven flow in M3; this CLI stays as
//! the scriptable / headless path.

const std = @import("std");
const Io = std.Io;
const zigoku = @import("zigoku");

/// Route all logging through Zigoku's handler, and pin the level to `.debug` in
/// every build so the runtime `--debug` gate works in the shipped binary. See
/// `src/log.zig`.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = zigoku.log.logFn,
};

const Cli = struct {
    query: []const u8,
    translation: zigoku.Translation = .sub,
    /// Parsed but not yet honoured — quality select needs the full resolver
    /// (m3u8 variants), which is ROD-92. fast4speed is 1080p direct for now.
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
    return std.math.isFinite(update.time_pos) and update.time_pos > 0;
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

    // Debug logging (ROD-88): `--debug` flag or `ZIGOKU_DEBUG=1`. Set before any
    // worker thread or the TUI spawns, so the gate is stable for the run.
    if (zigoku.log.envDebug() or hasFlag(args, "--debug")) zigoku.log.debug_enabled = true;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const out = &stdout_fw.interface;

    var stdin_buf: [256]u8 = undefined;
    var stdin_fr: Io.File.Reader = Io.File.stdin().reader(io, &stdin_buf);
    const in = &stdin_fr.interface;

    // User config (ROD-85). Total: a missing/bad file yields defaults, so this
    // never blocks startup. Arena-allocated → lives for the whole process. When
    // neither $XDG_CONFIG_HOME nor $HOME is set there's no path — go straight to
    // defaults rather than hand an empty (non-absolute) path to openFileAbsolute,
    // whose absolute-path assert would panic in debug builds. The path is kept
    // for the Settings tab's save-on-exit (ROD-86).
    const cfg_path: ?[]const u8 = zigoku.config.defaultPath(arena) catch null;
    const cfg = if (cfg_path) |p| zigoku.config.load(arena, io, p) else zigoku.Config{};

    const cli = parseArgs(arena, args) catch |err| switch (err) {
        // No positional query → open the TUI, M3's default interface. This also
        // catches a lone flag like `zigoku --dub` (no query): the flag is
        // dropped and the TUI opens. Malformed flags (UnknownFlag/MissingValue)
        // still fall through to usage.
        error.NoQuery => return runTui(init, arena, cfg, cfg_path),
        else => {
            try usage(out);
            try out.flush();
            return;
        },
    };

    // Persistence (M2). Best-effort: if the DB can't be opened we note it once
    // and run without history/resume rather than refusing to play anything.
    var store_opt: ?zigoku.Store = openStore(arena) catch |err| blk: {
        const why: []const u8 = switch (err) {
            error.SchemaTooNew => "DB was written by a newer Zigoku — delete it to start fresh",
            error.NoHomeDir => "couldn't locate a data directory (no $HOME/$XDG_DATA_HOME)",
            error.Unsupported => "this platform isn't supported yet (no data directory)",
            else => @errorName(err),
        };
        try out.print("  (note: persistence off — {s})\n", .{why});
        break :blk null;
    };
    defer if (store_opt) |*st| st.close();

    run(arena, io, out, in, cli, cfg, if (store_opt) |*st| st else null) catch |err| {
        try reportError(out, err);
        try out.flush();
        std.process.exit(1);
    };
    try out.flush();
}

/// Open the on-disk store at its XDG default location.
fn openStore(arena: std.mem.Allocator) !zigoku.Store {
    const path = try zigoku.store.defaultDbPath(arena);
    return zigoku.Store.open(path);
}

/// Launch the libvaxis TUI (ROD-71). Persistence is best-effort — if the DB
/// won't open, the shell just shows an empty history rather than refusing to run.
fn runTui(init: std.process.Init, arena: std.mem.Allocator, cfg: zigoku.Config, cfg_path: ?[]const u8) !void {
    // In the TUI, stderr is the render surface — send diagnostics to a file
    // instead. Best-effort: a failure here just leaves logging on stderr.
    if (zigoku.paths.dataDir(arena)) |dir| {
        zigoku.paths.ensureDir(dir);
        zigoku.log.file_path = std.fmt.allocPrint(arena, "{s}/zigoku.log", .{dir}) catch null;
    } else |_| {}

    var store_opt: ?zigoku.Store = openStore(arena) catch null;
    defer if (store_opt) |*st| st.close();
    var allanime = zigoku.AllAnime.init();
    const provider = allanime.provider();
    try zigoku.tui.run(init.gpa, init.io, init.environ_map, if (store_opt) |*st| st else null, provider, cfg, cfg_path);
}

/// The whole vertical slice, top to bottom. `store` is optional — every
/// persistence touch is best-effort so a DB hiccup never blocks playback.
fn run(arena: std.mem.Allocator, io: Io, out: *Io.Writer, in: *Io.Reader, cli: Cli, cfg: zigoku.Config, store: ?*zigoku.Store) !void {
    try zigoku.writeBanner(out);
    if (!std.mem.eql(u8, cli.quality, "best")) {
        try out.print("\n  (note: --quality is parsed but not wired yet — fast4speed is 1080p direct; quality select is ROD-92)\n", .{});
    }

    var allanime = zigoku.AllAnime.init();
    const provider = allanime.provider();
    const SOURCE = provider.name();

    // 1. Search.
    try out.print("\n→ searching AllAnime for \"{s}\" ({s})…\n", .{ cli.query, cli.translation.str() });
    try out.flush();

    const results = try provider.search(arena, io, cli.query, .{ .translation = cli.translation, .limit = 20 });
    if (results.len == 0) {
        try out.print("\n  no results for \"{s}\". Try a different spelling or romaji.\n", .{cli.query});
        return;
    }

    try out.print("\n  {d} results:\n\n", .{results.len});
    for (results, 0..) |a, i| {
        const eps = a.episodeCount(cli.translation);
        try out.print("  {d:>2}. {s}  ·  {d} {s} eps\n", .{ i + 1, a.name, eps, cli.translation.str() });
    }

    const show_idx = (try promptChoice(out, in, "\n  pick a show # (q to quit): ", results.len)) orelse {
        try out.writeAll("\n  bye.\n");
        return;
    };
    const show = results[show_idx];

    // ROD-66/97: remember this show. Refreshes source metadata, preserves any
    // existing history (play_count/progress/status).
    if (store) |st| st.upsertAnime(zigoku.AnimeRecord.fromDomain(SOURCE, show, cli.translation), zigoku.Store.nowSecs()) catch |e|
        std.log.debug("upsertAnime failed: {s}", .{@errorName(e)});

    // 2. Episodes — ROD-68: serve from cache when warm, else fetch + cache.
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

    // ROD-69 (read side): start where the viewer left off, if anywhere.
    var start_seconds: u64 = 0;
    if (store) |st| {
        if (st.getResume(SOURCE, show.id, cli.translation, episode.raw) catch null) |r| {
            start_seconds = r.startSeconds();
            if (start_seconds > 0) try out.print("  ↺ resuming at {d}s\n", .{start_seconds});
        }
    }

    // 3. Resolve.
    try out.print("\n→ resolving ep {s} ({s})…\n", .{ episode.raw, cli.translation.str() });
    try out.flush();

    const link = try provider.resolve(arena, io, show.id, episode, cli.translation);
    const res_str = if (link.resolution) |r| r else 0;
    try out.print("  ✓ stream resolved ({d}p)\n", .{res_str});

    // 4. Play.
    const title = try std.fmt.allocPrint(arena, "{s} — ep {s}", .{ show.name, episode.raw });

    // ROD-83: resolve OP/ED skip data. MAL id comes from enrichment (in-memory or
    // persisted — ROD-82 cache read), falling back to Jikan inside `prepare`.
    var known_mal: ?u32 = if (show.mal_id) |m| std.math.cast(u32, m) else null;
    if (known_mal == null) {
        if (store) |st| {
            if (st.getAnime(arena, SOURCE, show.id) catch null) |rec| {
                if (rec.mal_id) |m| known_mal = std.math.cast(u32, m) orelse null;
            }
        }
    }
    // This is synchronous on the CLI's only thread (unlike the TUI, which fetches
    // on a worker), so tell the user before the Jikan/AniSkip round-trips.
    try out.print("  ⏭ checking skip data…\n", .{});
    try out.flush();
    const skip = zigoku.aniskip.prepare(arena, io, known_mal, show.name, zigoku.aniskip.episodeNumber(episode.raw, @intCast(ep_idx + 1)), zigoku.aniskip.SkipMode.fromString(cfg.skip_mode));

    try out.print("  ▶ launching mpv…\n", .{});
    try out.flush();

    var progress: PlaybackProgress = .{};
    zigoku.player.play(arena, io, cfg.mpv_path, link, title, start_seconds, .{
        .ctx = @ptrCast(&progress),
        .func = recordPlaybackProgress,
    }, skip) catch |err| {
        if (store) |st| {
            const latest = progress.snapshot();
            if (observedPlaybackWasMeaningful(latest)) {
                persistFinalProgress(st, SOURCE, show.id, cli.translation, episode.raw, latest);
                if (err == error.MpvFailed) st.recordPlay(SOURCE, show.id, @intCast(ep_idx + 1), zigoku.Store.nowSecs()) catch |e|
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
        st.recordPlay(SOURCE, show.id, @intCast(ep_idx + 1), zigoku.Store.nowSecs()) catch |e|
            std.log.debug("recordPlay failed: {s}", .{@errorName(e)});
    }

    try out.print("\n✓ done. That was Zigoku, end to end.\n", .{});
}

test "observedPlaybackWasMeaningful requires positive observed position" {
    try std.testing.expect(!observedPlaybackWasMeaningful(null));
    try std.testing.expect(!observedPlaybackWasMeaningful(.{ .time_pos = 0, .duration = 1440 }));
    try std.testing.expect(!observedPlaybackWasMeaningful(.{ .time_pos = -1, .duration = 1440 }));
    try std.testing.expect(observedPlaybackWasMeaningful(.{ .time_pos = 0.5, .duration = 1440 }));
}

/// Episode list for a show: cache-first (ROD-68), falling back to a live fetch
/// that then warms the cache. All store access is best-effort.
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
    const fetched = try provider.episodes(arena, io, show.id, tt);

    if (store) |st| {
        if (fetched.len > 0)
            st.putCachedEpisodes(source, show.id, tt, fetched, show.status, zigoku.Store.nowSecs(), arena) catch |e|
                std.log.debug("putCachedEpisodes failed: {s}", .{@errorName(e)});
    }
    return fetched;
}

/// Prompt, read a line, parse a 1-based choice in [1, max]. Returns the 0-based
/// index, or null if the user quits (q / empty EOF / Ctrl-D). Re-prompts on
/// garbage instead of bailing.
fn promptChoice(out: *Io.Writer, in: *Io.Reader, prompt: []const u8, max: usize) !?usize {
    while (true) {
        try out.writeAll(prompt);
        try out.flush();

        // Inclusive: consumes the trailing '\n' too. The exclusive variant
        // leaves the delimiter in the buffer → next read returns "" forever.
        const line = in.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return null, // Ctrl-D / no trailing newline at EOF
            error.StreamTooLong => return null, // absurd input; treat as quit
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

/// Parse `<query words…>` plus flags. Errors (→ usage) only when no query given.
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
            // Global logging flag — handled in `main` before parse; consumed here
            // so it isn't mistaken for a query word or an unknown flag.
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

/// True if `flag` appears anywhere in `args`.
fn hasFlag(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

fn usage(out: *Io.Writer) !void {
    try zigoku.writeBanner(out);
    try out.writeAll(
        \\
        \\  usage: zigoku <query> [--dub] [--quality best|1080|720|480|worst] [--debug]
        \\
        \\    zigoku frieren
        \\    zigoku "cowboy bebop" --dub
        \\
        \\  --debug (or ZIGOKU_DEBUG=1) writes diagnostics: stderr in CLI mode,
        \\  ~/.local/share/zigoku/zigoku.log in the TUI.
        \\
    );
}

/// Turn an error into a human line instead of a Zig stack trace.
fn reportError(out: *Io.Writer, err: anyerror) !void {
    const msg: []const u8 = switch (err) {
        error.MpvNotFound => "mpv isn't on your PATH. Install mpv and try again.",
        error.MpvFailed => "mpv exited badly (closed early, or couldn't play the stream).",
        error.NoDirectStream => "found the episode, but it only offers providers we can't resolve yet (the direct fast4speed link wasn't there). That's the ROD-92 follow-up — try another show/episode for now.",
        error.NoSearchData => "AllAnime returned nothing for that search.",
        error.ShowNotFound, error.NoEpisodeData => "AllAnime had no episode data for that show.",
        error.NotEncrypted => "AllAnime returned an unexpected (unencrypted) video payload — the protocol may have shifted.",
        error.HttpNotOk => "AllAnime rejected the request (HTTP error). The site may be down, or the recipe drifted.",
        else => @errorName(err),
    };
    try out.print("\n✗ {s}\n", .{msg});
}

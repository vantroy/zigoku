//! Zigoku — mpv launcher (ROD-63 / ROD-80).
//!
//! Still deliberately blocking at the top level: spawn mpv, optionally watch its
//! IPC socket from a side thread, then wait for exit. The non-blocking event-loop
//! integration is later scope; this ticket only adds live position observation.

const std = @import("std");
const Io = std.Io;
const domain = @import("domain.zig");
const paths = @import("paths.zig");
const c = @cImport({
    @cInclude("unistd.h"); // getuid, getpid
});

pub const PlayError = error{
    /// mpv isn't installed / not on PATH — overwhelmingly the likely failure.
    MpvNotFound,
    /// mpv ran but exited non-zero or was killed by a signal.
    MpvFailed,
    /// mpv exited code 2 — "nothing could be opened/played" — before any playback.
    /// For a network stream that's the CDN's transient open failure (403 in a
    /// Cloudflare penalty window / expiry); retryable with a fresh re-resolve (ROD-309).
    MpvOpenFailed,
};

pub const PositionUpdate = struct {
    time_pos: f64,
    duration: f64,

    /// Whether this is a real observed position worth persisting — a finite,
    /// positive time. mpv can emit 0 or NaN on an abrupt exit, which must not
    /// clobber a good checkpoint or record a play that never meaningfully ran.
    pub fn isMeaningful(self: PositionUpdate) bool {
        return std.math.isFinite(self.time_pos) and self.time_pos > 0;
    }

    /// Whether the watch reached `ratio` of the runtime — the bar for counting
    /// the episode as *watched* (bump the progress high-water mark, advance the
    /// detail cursor). Distinct from `isMeaningful`: a real position worth
    /// resuming from (5s in) is not the same as a watched episode. Requires a
    /// known finite duration; an unknown/zero duration cannot prove completion,
    /// so it conservatively returns false. `ratio` is the caller's policy (the
    /// store's NATURAL_END_RATIO) — player.zig stays free of store concerns.
    pub fn reachedCompletion(self: PositionUpdate, ratio: f64) bool {
        return std.math.isFinite(self.time_pos) and std.math.isFinite(self.duration) and
            self.duration > 0 and self.time_pos / self.duration >= ratio;
    }
};

/// An mpv user-script to load for this playback, with its `--script-opts` value.
/// AniSkip (ROD-83) builds these; `play` just wires them onto the command line.
pub const SkipScript = struct {
    /// Absolute path to the `.lua` script.
    path: []const u8,
    /// Value for `--script-opts` (e.g. `aniskip-op_start=12.5,...`).
    opts: []const u8,
};

pub const PositionCallback = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, update: PositionUpdate) void,

    pub fn call(self: PositionCallback, update: PositionUpdate) void {
        self.func(self.ctx, update);
    }
};

const IpcEvent = struct {
    name: ?[]const u8 = null,
    data: ?f64 = null,
};

var next_socket_id: std.atomic.Value(u64) = .init(1);

fn buildSocketPath(arena: std.mem.Allocator, base_dir: []const u8, uid: u64, pid: u64, unique_id: u64) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/zigoku-mpv-{d}-{d}-{d}.sock", .{ base_dir, uid, pid, unique_id });
}

fn mpvSocketPath(arena: std.mem.Allocator) ![]const u8 {
    // `runtimeDir` only fails on OOM (or Windows); fall back to a bare `/tmp` so a
    // transient socket always has a home. uid/pid/counter in the filename keep
    // concurrent launches from colliding inside the shared dir.
    const base_dir = paths.runtimeDir(arena) catch "/tmp/zigoku";
    paths.ensureDir(base_dir);

    const uid: u64 = @intCast(c.getuid());
    const pid: u64 = @intCast(c.getpid());
    const unique_id = next_socket_id.fetchAdd(1, .monotonic);
    return buildSocketPath(arena, base_dir, uid, pid, unique_id);
}

fn cleanupSocket(io: Io, socket_path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, socket_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {},
    };
}

fn waitForSocket(io: Io, socket_path: []const u8) bool {
    var tries: u8 = 0;
    while (tries < 40) : (tries += 1) {
        std.Io.Dir.accessAbsolute(io, socket_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.Io.sleep(io, .fromMilliseconds(50), .awake) catch return false;
                continue;
            },
            else => return false,
        };
        return true;
    }
    return false;
}

fn parsePositionLine(arena: std.mem.Allocator, line: []const u8, time_pos: *f64, duration: *f64) ?PositionUpdate {
    const parsed = std.json.parseFromSlice(IpcEvent, arena, line, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const name = parsed.value.name orelse return null;
    const value = parsed.value.data orelse return null;
    if (std.mem.eql(u8, name, "time-pos")) {
        time_pos.* = value;
        return .{ .time_pos = time_pos.*, .duration = duration.* };
    }
    if (std.mem.eql(u8, name, "duration")) {
        duration.* = value;
        return .{ .time_pos = time_pos.*, .duration = duration.* };
    }
    return null;
}

fn positionWatcher(io: Io, socket_path: []const u8, callback: PositionCallback) void {
    if (!waitForSocket(io, socket_path)) return;

    const addr = std.Io.net.UnixAddress.init(socket_path) catch return;
    var stream = std.Io.net.UnixAddress.connect(&addr, io) catch return;
    defer stream.close(io);

    var read_buf: [4096]u8 = undefined;
    var write_buf: [512]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    writer.interface.writeAll("{\"command\":[\"observe_property\",1,\"time-pos\"]}\n") catch return;
    writer.interface.writeAll("{\"command\":[\"observe_property\",2,\"duration\"]}\n") catch return;
    writer.interface.flush() catch return;

    var parse_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer parse_arena.deinit();

    var time_pos: f64 = 0;
    var duration: f64 = 0;
    while (true) {
        const line = (reader.interface.takeDelimiter('\n') catch break) orelse break;
        _ = parse_arena.reset(.retain_capacity);
        const update = parsePositionLine(parse_arena.allocator(), line, &time_pos, &duration) orelse continue;
        callback.call(update);
    }
}

/// Launch mpv on `link` and block until it exits.
///
/// `mpv_path` is the mpv binary to exec (an absolute path, or a bare `"mpv"` to resolve via
/// `$PATH`, ROD-85 config). `title` becomes mpv's window/OSD title. `start_seconds` is the
/// resume offset. When `position_callback` is present, a watcher thread observes mpv's unix
/// socket IPC and reports live time-pos/duration updates until mpv exits. When `skip` is
/// present, its Lua script + opts are loaded so mpv auto-skips the OP/ED (ROD-83).
pub fn play(
    arena: std.mem.Allocator,
    io: Io,
    mpv_path: []const u8,
    link: domain.StreamLink,
    title: []const u8,
    start_seconds: u64,
    position_callback: ?PositionCallback,
    skip: ?SkipScript,
) !void {
    const socket_path = try mpvSocketPath(arena);
    // mpv writes its own verbose log here so an opaque nonzero exit can be explained
    // (the HLS/ffmpeg reason: 403, expired token, connection reset, codec error…).
    // Kept on failure (its path is logged), deleted on a clean exit — see the term
    // switch below. Sibling of the per-playback socket, so it's collision-free too.
    const mpv_log_path = try std.fmt.allocPrint(arena, "{s}.log", .{socket_path});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, mpv_path);
    try argv.append(arena, link.url);
    if (link.referer) |r| {
        // Referer may originate from untrusted provider data (ROD-92 long-tail).
        // It is validated upstream before reaching here: allanime.zig's
        // `safeReferer`/`cleanArg` reject control chars (no CR/LF header
        // injection) and `consider` gates the URL. Keep that contract intact.
        try argv.append(arena, try std.fmt.allocPrint(arena, "--http-header-fields-append=Referer: {s}", .{r}));
    }
    if (link.user_agent) |ua| {
        // mpv's ffmpeg HTTP path otherwise sends its default `Lavf/*` User-Agent, which the
        // CDN's Cloudflare edge flags as a bot and 403s intermittently (ROD-309). The provider
        // sets this to the same browser UA its resolver used to pass CF, so the whole HLS chain
        // looks like the client that resolved it. Dedicated `--user-agent` (not
        // header-fields-append) so it REPLACES the default rather than sending two conflicting
        // UA headers. Same untrusted-bytes contract as Referer: cleanArg-vetted upstream, no
        // CR/LF header injection.
        try argv.append(arena, try std.fmt.allocPrint(arena, "--user-agent={s}", .{ua}));
    }
    if (std.mem.startsWith(u8, link.url, "http")) {
        // Be a gentler HTTP client so the CDN's Cloudflare bot/rate scoring stops sampling us
        // into an intermittent 403 (ROD-309). `multiple_requests=1`: keep the TCP/TLS
        // connection alive across the HLS chain instead of ffmpeg's default `Connection: close`,
        // which otherwise opens a fresh handshake per segment (hundreds an episode, the burst
        // that spikes a per-IP rate score). `icy=0`: drop the `Icy-MetaData: 1` SHOUTcast header
        // ffmpeg sends by default, a non-browser tell no real player emits for HLS. Constant
        // literal, protocol-layer options only (guarded to http(s) urls), no untrusted data.
        try argv.append(arena, "--stream-lavf-o=multiple_requests=1,icy=0");
    }
    if (link.sub_url) |s| {
        // Softsub sidecar (megaplay 'sub' streams are clean video + external vtt,
        // ROD-354). mpv fetches it over the same http stack as the video, so the
        // global --user-agent / Referer args above cover the vtt host's gate too
        // (spike-verified: lostproject.club 200s under the megaplay referer).
        // Same untrusted-bytes contract as `url`: cleanArg-vetted upstream.
        try argv.append(arena, try std.fmt.allocPrint(arena, "--sub-file={s}", .{s}));
        // Style the softsub for anime backgrounds (ROD-382): lift it off the very
        // bottom edge (sub-pos < 100 raises it) and render bold so thin glyphs hold
        // up over bright frames. Constant literals, no untrusted data. External subs
        // only (this block); burned-in hardsubs are pixels and untouchable.
        try argv.append(arena, "--sub-pos=90");
        try argv.append(arena, "--sub-bold=yes");
    }
    if (link.cloaked_segments) {
        // The stream's HLS segments use a disguised extension (senshi serves `.ts` as `.jpg`;
        // ROD-301). ffmpeg's HLS demuxer gates on a segment-extension allowlist a stock build
        // limits to real media extensions; `ALL` lifts it for the (https-only, provider-vetted)
        // playlist. Defense-in-depth: current mpv (v0.41) disables that gate itself via a compat
        // shim, so segments play with or without this, but raw ffmpeg and mpv builds lacking the
        // shim DO enforce it, so we set it. Constant literal, no untrusted data in the argv.
        try argv.append(arena, "--demuxer-lavf-o=allowed_extensions=ALL");
    }
    try argv.append(arena, try std.fmt.allocPrint(arena, "--force-media-title={s}", .{title}));
    // Window-manager title carries a stable "zigoku - " prefix so hypr-focus
    // (and taskbars/overviews) can identify the playback window while still
    // showing the episode. Use mpv's ${media-title} expansion rather than
    // interpolating `title` directly: media-title is set verbatim above and is
    // not re-expanded, so a title containing `${...}` can't trigger mpv
    // property expansion here.
    try argv.append(arena, "--title=zigoku - ${media-title}");
    try argv.append(arena, try std.fmt.allocPrint(arena, "--input-ipc-server={s}", .{socket_path}));
    try argv.append(arena, try std.fmt.allocPrint(arena, "--log-file={s}", .{mpv_log_path}));
    if (start_seconds > 0) {
        try argv.append(arena, try std.fmt.allocPrint(arena, "--start={d}", .{start_seconds}));
    }
    if (skip) |s| {
        try argv.append(arena, try std.fmt.allocPrint(arena, "--script={s}", .{s.path}));
        try argv.append(arena, try std.fmt.allocPrint(arena, "--script-opts={s}", .{s.opts}));
    }

    cleanupSocket(io, socket_path);
    defer cleanupSocket(io, socket_path);

    // Redirect mpv's stdout and stderr to /dev/null so its status lines and
    // codec info don't bleed through the alt-screen into the TUI's terminal.
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.MpvNotFound,
        else => return err,
    };

    var watcher_thread: ?std.Thread = null;
    errdefer if (watcher_thread) |t| t.join();
    if (position_callback) |callback| {
        watcher_thread = std.Thread.spawn(.{}, positionWatcher, .{ io, socket_path, callback }) catch |err| blk: {
            std.log.warn("mpv IPC watcher disabled: {s}", .{@errorName(err)});
            break :blk null;
        };
    }

    const term = try child.wait(io);
    if (watcher_thread) |t| {
        t.join();
        // Null the handle so the `errdefer` above can't join it a SECOND time when a
        // nonzero-exit arm below returns an error. A double pthread_join is undefined:
        // macOS detects it and `Thread.join` hits `unreachable` ("reached unreachable
        // code"), taking down the app the moment mpv exits non-zero — e.g. a senshi CDN
        // 403 (ROD-310). Linux's join happens to survive the second call, which is why
        // this only ever crashed on macOS. The errdefer stays for its one real job:
        // joining the watcher if `child.wait` itself fails before we reach here.
        watcher_thread = null;
    }
    switch (term) {
        .exited => |code| {
            if (code == 0) {
                std.Io.Dir.deleteFileAbsolute(io, mpv_log_path) catch {}; // clean exit → drop the log
                return;
            }
            // Log the reason we CAN see here (exit status, resume offset, and the
            // signed/expiring stream URL) and keep mpv's own log for the deep cause.
            std.log.err("mpv exited nonzero: code={d} start={d}s url={s} mpvlog={s}", .{
                code, start_seconds, link.url, mpv_log_path,
            });
            // Code 2 is mpv's "nothing could be opened/played" — for a network stream the
            // transient CDN open failure the caller can ride out with a re-resolve. Any
            // other nonzero code is a real fault we shouldn't hammer-retry.
            return if (code == 2) error.MpvOpenFailed else error.MpvFailed;
        },
        else => {
            // Format the whole term ({any}), not just its tag: for a signal death the
            // number (SIGSEGV vs SIGKILL vs SIGABRT) is often the ONLY diagnostic left,
            // since mpv rarely flushes its --log-file before a signal takes it down.
            std.log.err("mpv terminated abnormally: {any} start={d}s url={s} mpvlog={s}", .{
                term, start_seconds, link.url, mpv_log_path,
            });
            return error.MpvFailed; // signalled / stopped / unknown
        },
    }
}

test "buildSocketPath makes unique per-playback socket names" {
    const a = try buildSocketPath(std.testing.allocator, "/tmp", 1000, 1234, 1);
    defer std.testing.allocator.free(a);
    const b = try buildSocketPath(std.testing.allocator, "/tmp", 1000, 1234, 2);
    defer std.testing.allocator.free(b);

    try std.testing.expect(!std.mem.eql(u8, a, b));
    try std.testing.expectEqualStrings("/tmp/zigoku-mpv-1000-1234-1.sock", a);
    try std.testing.expectEqualStrings("/tmp/zigoku-mpv-1000-1234-2.sock", b);
}

test "parsePositionLine tracks time-pos and duration events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var time_pos: f64 = 0;
    var duration: f64 = 0;

    const first = parsePositionLine(
        arena.allocator(),
        "{\"event\":\"property-change\",\"name\":\"time-pos\",\"data\":91.5}",
        &time_pos,
        &duration,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f64, 91.5), first.time_pos, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), first.duration, 0.001);

    _ = arena.reset(.retain_capacity);
    const second = parsePositionLine(
        arena.allocator(),
        "{\"event\":\"property-change\",\"name\":\"duration\",\"data\":1440}",
        &time_pos,
        &duration,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f64, 91.5), second.time_pos, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1440), second.duration, 0.001);

    _ = arena.reset(.retain_capacity);
    try std.testing.expect(parsePositionLine(
        arena.allocator(),
        "{\"event\":\"property-change\",\"name\":\"time-pos\",\"data\":null}",
        &time_pos,
        &duration,
    ) == null);
}

test "reachedCompletion is a >= ratio gate that needs a known duration" {
    const r: f64 = 0.80;
    // Below / at / above the bar. 1152/1440 == 0.8 exactly (IEEE-correct).
    try std.testing.expect(!(PositionUpdate{ .time_pos = 1151, .duration = 1440 }).reachedCompletion(r));
    try std.testing.expect((PositionUpdate{ .time_pos = 1152, .duration = 1440 }).reachedCompletion(r));
    try std.testing.expect((PositionUpdate{ .time_pos = 1400, .duration = 1440 }).reachedCompletion(r));
    // A 5s test-quit of a 24min episode (the ROD-168 repro): nowhere near done.
    try std.testing.expect(!(PositionUpdate{ .time_pos = 5, .duration = 1440 }).reachedCompletion(r));
    // Unknown/degenerate duration can't prove completion → conservative false.
    try std.testing.expect(!(PositionUpdate{ .time_pos = 1200, .duration = 0 }).reachedCompletion(r));
    try std.testing.expect(!(PositionUpdate{ .time_pos = 1200, .duration = -1 }).reachedCompletion(r));
    const nan = std.math.nan(f64);
    try std.testing.expect(!(PositionUpdate{ .time_pos = nan, .duration = 1440 }).reachedCompletion(r));
    try std.testing.expect(!(PositionUpdate{ .time_pos = 1200, .duration = nan }).reachedCompletion(r));
}

//! mpv launcher (ROD-63 / ROD-80). Blocking: spawn, optional IPC watcher, wait for exit.
//! Non-blocking event-loop integration is later scope; this adds live position observation.

const std = @import("std");
const Io = std.Io;
const domain = @import("domain.zig");
const paths = @import("paths.zig");
const c = @cImport({
    @cInclude("unistd.h"); // getuid, getpid
});

pub const PlayError = error{
    /// mpv not on PATH.
    MpvNotFound,
    /// Nonzero exit or signal death.
    MpvFailed,
    /// Exit code 2: nothing opened/played. For network streams = transient CDN open
    /// failure (403 / expiry); retryable with a fresh re-resolve (ROD-309).
    MpvOpenFailed,
};

pub const PositionUpdate = struct {
    time_pos: f64,
    duration: f64,

    /// Finite positive time only. mpv can emit 0/NaN on abrupt exit; must not clobber
    /// a good checkpoint or record a play that never ran.
    pub fn isMeaningful(self: PositionUpdate) bool {
        return std.math.isFinite(self.time_pos) and self.time_pos > 0;
    }

    /// Reached `ratio` of runtime (watched high-water). Distinct from `isMeaningful`
    /// (5s is resume-worthy, not watched). Unknown/zero duration → false. `ratio` is
    /// caller policy; player stays free of store concerns.
    pub fn reachedCompletion(self: PositionUpdate, ratio: f64) bool {
        return std.math.isFinite(self.time_pos) and std.math.isFinite(self.duration) and
            self.duration > 0 and self.time_pos / self.duration >= ratio;
    }
};

/// AniSkip (ROD-83) builds these; `play` wires them onto the command line.
pub const SkipScript = struct {
    path: []const u8,
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
    // runtimeDir fails only on OOM (or Windows); fall back so a socket always has a home.
    // uid/pid/counter keep concurrent launches from colliding.
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
/// `mpv_path`: binary or bare `"mpv"` via `$PATH` (ROD-85). Optional IPC watcher and
/// AniSkip script (ROD-83).
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
    // Kept on failure (path logged), deleted on clean exit. Sibling of the socket.
    const mpv_log_path = try std.fmt.allocPrint(arena, "{s}.log", .{socket_path});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, mpv_path);
    try argv.append(arena, link.url);
    if (link.referer) |r| {
        // Untrusted provider data (ROD-92): cleanArg-vetted upstream (no CR/LF injection).
        try argv.append(arena, try std.fmt.allocPrint(arena, "--http-header-fields-append=Referer: {s}", .{r}));
    }
    if (link.user_agent) |ua| {
        // Dedicated --user-agent replaces Lavf/* default (CF 403s otherwise, ROD-309).
        // Same cleanArg contract as Referer. Not header-fields-append (would send two UAs).
        try argv.append(arena, try std.fmt.allocPrint(arena, "--user-agent={s}", .{ua}));
    }
    if (std.mem.startsWith(u8, link.url, "http")) {
        // Gentler HTTP for CF rate scoring (ROD-309): keep-alive across HLS segments;
        // drop Icy-MetaData SHOUTcast tell. Constant literal, no untrusted data.
        try argv.append(arena, "--stream-lavf-o=multiple_requests=1,icy=0");
    }
    if (link.sub_url) |s| {
        // Softsub sidecar (ROD-354). Same http stack as video (UA/Referer cover vtt host).
        try argv.append(arena, try std.fmt.allocPrint(arena, "--sub-file={s}", .{s}));
        // Softsub styling for anime backgrounds (ROD-382). External only; hardsubs are pixels.
        try argv.append(arena, "--sub-pos=92");
        try argv.append(arena, "--sub-bold=yes");
    }
    if (link.cloaked_segments) {
        // HLS segments with disguised extension (e.g. .ts as .jpg, ROD-301). ffmpeg allowlist
        // gate; stock mpv often disables it, raw ffmpeg / older builds do not. Constant literal.
        try argv.append(arena, "--demuxer-lavf-o=allowed_extensions=ALL");
    }
    try argv.append(arena, try std.fmt.allocPrint(arena, "--force-media-title={s}", .{title}));
    // Stable "zigoku - " prefix for WM/hypr-focus. ${media-title} expansion (not raw title
    // interpolation) so a title containing ${...} cannot re-expand properties.
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

    // Swallow mpv stdout/stderr so status lines don't bleed into the TUI alt-screen.
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
        // Null so errdefer cannot join a second time. Double pthread_join is UB: macOS
        // hits unreachable (ROD-310), Linux often survives. errdefer still covers wait failure.
        watcher_thread = null;
    }
    switch (term) {
        .exited => |code| {
            if (code == 0) {
                std.Io.Dir.deleteFileAbsolute(io, mpv_log_path) catch {};
                return;
            }
            std.log.err("mpv exited nonzero: code={d} start={d}s url={s} mpvlog={s}", .{
                code, start_seconds, link.url, mpv_log_path,
            });
            // Code 2 = open failure (retryable re-resolve). Other nonzero = real fault.
            return if (code == 2) error.MpvOpenFailed else error.MpvFailed;
        },
        else => {
            // Format whole term ({any}): signal number is often the only diagnostic left.
            std.log.err("mpv terminated abnormally: {any} start={d}s url={s} mpvlog={s}", .{
                term, start_seconds, link.url, mpv_log_path,
            });
            return error.MpvFailed;
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
    try std.testing.expect(!(PositionUpdate{ .time_pos = 1151, .duration = 1440 }).reachedCompletion(r));
    try std.testing.expect((PositionUpdate{ .time_pos = 1152, .duration = 1440 }).reachedCompletion(r));
    try std.testing.expect((PositionUpdate{ .time_pos = 1400, .duration = 1440 }).reachedCompletion(r));
    // 5s of a 24min episode (ROD-168): not done.
    try std.testing.expect(!(PositionUpdate{ .time_pos = 5, .duration = 1440 }).reachedCompletion(r));
    try std.testing.expect(!(PositionUpdate{ .time_pos = 1200, .duration = 0 }).reachedCompletion(r));
    try std.testing.expect(!(PositionUpdate{ .time_pos = 1200, .duration = -1 }).reachedCompletion(r));
    const nan = std.math.nan(f64);
    try std.testing.expect(!(PositionUpdate{ .time_pos = nan, .duration = 1440 }).reachedCompletion(r));
    try std.testing.expect(!(PositionUpdate{ .time_pos = 1200, .duration = nan }).reachedCompletion(r));
}

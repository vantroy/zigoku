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
};

pub const PositionUpdate = struct {
    time_pos: f64,
    duration: f64,
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
    const base_dir = paths.runtimeDir(arena) catch "/tmp";
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
/// `mpv_path` is the mpv binary to exec — an absolute path, or a bare `"mpv"`
/// to resolve via `$PATH` (ROD-85 config). `title` becomes mpv's window/OSD
/// title. `start_seconds` is the resume offset. When `position_callback` is
/// present, a watcher thread observes mpv's unix socket IPC and reports live
/// time-pos/duration updates until mpv exits. When `skip` is present, its Lua
/// script + opts are loaded so mpv auto-skips the OP/ED (ROD-83).
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

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, mpv_path);
    try argv.append(arena, link.url);
    if (link.referer) |r| {
        // Safe today: referer is a hardcoded constant. When ROD-92 lands and
        // providers supply their own referer from API data, validate it (no
        // CR/LF, no header injection) before embedding it in this arg.
        try argv.append(arena, try std.fmt.allocPrint(arena, "--http-header-fields-append=Referer: {s}", .{r}));
    }
    try argv.append(arena, try std.fmt.allocPrint(arena, "--force-media-title={s}", .{title}));
    try argv.append(arena, try std.fmt.allocPrint(arena, "--input-ipc-server={s}", .{socket_path}));
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
    if (watcher_thread) |t| t.join();
    switch (term) {
        .exited => |code| if (code != 0) return error.MpvFailed,
        else => return error.MpvFailed, // signalled / stopped / unknown
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

    const first = parsePositionLine(arena.allocator(),
        "{\"event\":\"property-change\",\"name\":\"time-pos\",\"data\":91.5}",
        &time_pos,
        &duration,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f64, 91.5), first.time_pos, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0), first.duration, 0.001);

    _ = arena.reset(.retain_capacity);
    const second = parsePositionLine(arena.allocator(),
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

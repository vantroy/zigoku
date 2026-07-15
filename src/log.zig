//! Logging policy (ROD-88). CLI → stderr; TUI → file (stderr is the render surface).
//!
//! Call sites use `std.log.*`; `logFn` (via std_options in main) routes bytes and gates debug.
//! log_level is `.debug` in every build; `--debug` / ZIGOKU_DEBUG is a runtime gate so
//! ReleaseSafe still honors --debug. Writes via libc O_APPEND (no Io handle; concurrent lines
//! don't interleave).

const std = @import("std");

// extern not @cImport: glibc fortify open fails translate-c under __OPTIMIZE__; std.posix
// open/write/close removed. open MUST be variadic (Apple ARM64 varargs on stack; fixed mode
// → junk permissions on O_CREAT, ROD-149 macOS CI).
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;

// NOFOLLOW: refuse pre-existing symlink (planted-redirect defense).
const open_append_flags: c_int = @bitCast(std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .NOFOLLOW = true });

/// Gate for .debug lines. info/warn/err always emit.
pub var debug_enabled: bool = false;

/// TUI: append here instead of stderr. Set once before workers spawn; never mutate after.
pub var file_path: ?[]const u8 = null;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (level == .debug and !debug_enabled) return;

    const scope_txt = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    var buf: [2048]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[" ++ level.asText() ++ "] " ++ scope_txt ++ fmt ++ "\n", args) catch return;
    emit(line);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    std.log.debug(fmt, args);
}
pub fn info(comptime fmt: []const u8, args: anytype) void {
    std.log.info(fmt, args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    std.log.warn(fmt, args);
}
pub fn err(comptime fmt: []const u8, args: anytype) void {
    std.log.err(fmt, args);
}

/// Truthy ZIGOKU_DEBUG only; explicit falsy ("0"/"false"/…) is off.
pub fn envDebug() bool {
    const v = getenv("ZIGOKU_DEBUG") orelse return false;
    const s = std.mem.span(v);
    inline for (.{ "1", "true", "yes", "on" }) |truthy| {
        if (std.ascii.eqlIgnoreCase(s, truthy)) return true;
    }
    return false;
}

fn emit(bytes: []const u8) void {
    if (file_path) |path| {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len < pbuf.len) {
            @memcpy(pbuf[0..path.len], path);
            pbuf[path.len] = 0;
            const fd = open((pbuf[0..path.len :0]).ptr, open_append_flags, @as(c_uint, 0o644));
            if (fd >= 0) {
                defer _ = close(fd);
                writeAll(fd, bytes);
            }
        }
        // TUI: never fall through to stderr (would punch the frame).
        return;
    }
    writeAll(2, bytes);
}

fn writeAll(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const testing = std.testing;

const test_libc = struct {
    extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
    extern "c" fn unlink(path: [*:0]const u8) c_int;
};

fn readBackAll(path: [:0]const u8, buf: []u8) ?[]const u8 {
    const fd = open(path.ptr, @bitCast(std.posix.O{ .ACCMODE = .RDONLY }));
    if (fd < 0) return null;
    defer _ = close(fd);
    const n = test_libc.read(fd, buf.ptr, buf.len);
    if (n <= 0) return null;
    return buf[0..@intCast(n)];
}

test "debug line lands in the configured file when the gate is on" {
    var anchor: u8 = 0;
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "/tmp/zigoku-logtest-{x}.log", .{@intFromPtr(&anchor)}, 0);
    defer testing.allocator.free(path);
    defer _ = test_libc.unlink(path.ptr);

    const saved_path = file_path;
    const saved_dbg = debug_enabled;
    defer {
        file_path = saved_path;
        debug_enabled = saved_dbg;
    }

    file_path = path;
    debug_enabled = true;
    // Call logFn directly: test binary's root is not ours, so std.log misses our handler.
    logFn(.debug, .default, "hello {d}", .{42});

    var buf: [256]u8 = undefined;
    const content = readBackAll(path, &buf) orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, content, "[debug] hello 42") != null);
}

test "debug is suppressed when the gate is off, but err still emits" {
    var anchor: u8 = 0;
    const path = try std.fmt.allocPrintSentinel(testing.allocator, "/tmp/zigoku-logtest-off-{x}.log", .{@intFromPtr(&anchor)}, 0);
    defer testing.allocator.free(path);
    defer _ = test_libc.unlink(path.ptr);

    const saved_path = file_path;
    const saved_dbg = debug_enabled;
    defer {
        file_path = saved_path;
        debug_enabled = saved_dbg;
    }

    file_path = path;
    debug_enabled = false;
    logFn(.debug, .default, "should not appear", .{});

    var buf: [256]u8 = undefined;
    try testing.expect(readBackAll(path, &buf) == null);

    logFn(.err, .default, "boom {s}", .{"now"});
    const content = readBackAll(path, &buf) orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, content, "[error] boom now") != null);
    try testing.expect(std.mem.indexOf(u8, content, "should not appear") == null);
}

test "envDebug honors truthy values and treats explicit falsy as off" {
    const libc = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    defer _ = libc.unsetenv("ZIGOKU_DEBUG");

    _ = libc.unsetenv("ZIGOKU_DEBUG");
    try testing.expect(!envDebug());

    for ([_][:0]const u8{ "1", "true", "YES", "on" }) |truthy| {
        _ = libc.setenv("ZIGOKU_DEBUG", truthy.ptr, 1);
        try testing.expect(envDebug());
    }
    for ([_][:0]const u8{ "0", "false", "no", "off", "" }) |falsy| {
        _ = libc.setenv("ZIGOKU_DEBUG", falsy.ptr, 1);
        try testing.expect(!envDebug());
    }
}

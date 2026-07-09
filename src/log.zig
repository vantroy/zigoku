//! Zigoku — logging policy (ROD-88).
//!
//! Zigoku has two output modes with opposite needs. The CLI owns the terminal and can write
//! diagnostics straight to stderr. The TUI RENDERS into that same terminal, so any stray
//! `std.log` line would punch a hole in the frame; its diagnostics have to go to a file.
//!
//! This module is the single place that policy lives. Call sites keep using the plain
//! `std.log.{debug,info,warn,err}` idiom; `logFn` (installed via `std_options` in `main.zig`)
//! decides WHERE the bytes land and WHETHER a debug line is emitted at all.
//!
//! Two deliberate choices:
//!   * `std_options.log_level` is pinned to `.debug` in every build mode, and the `--debug` /
//!     `ZIGOKU_DEBUG` toggle is a RUNTIME gate here. The usual comptime-drop trick would make
//!     `--debug` silently do nothing in the shipped ReleaseSafe binary, exactly when a user
//!     reaches for it.
//!   * Writes go through libc (`O_APPEND` for the file, fd 2 for stderr), not a
//!     `std.Io.Writer`: `logFn` has no `io` handle. `O_APPEND` makes each write's seek-to-end
//!     + write atomic (POSIX), so concurrent worker-thread lines don't interleave, no lock.

const std = @import("std");

// Declared directly rather than via `@cImport`: glibc's `fcntl.h` wraps `open` in fortify
// inlines that fail Zig's translate-c under `__OPTIMIZE__` (the ReleaseSafe build), and the
// std.Io migration removed `std.posix.{open,write,close}`. Plain libc symbols sidestep both.
// Flag values come from `std.posix.O` so they stay correct per target.
//
// `open` MUST be declared variadic (`...`), matching C's `int open(const char *, int, ...)`.
// The `mode` arg is a vararg, and the Apple ARM64 ABI passes varargs on the stack while named
// args go in registers. Declaring `open` with a fixed `mode` parameter puts it in a register,
// so libSystem reads garbage off the stack and O_CREAT files get junk permissions (ROD-149:
// the macOS CI job caught this). Benign on Linux/x86-64 only because that ABI passes both the
// same way. Pass `mode` as a typed value at the call site so vararg lowering is correct.
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn close(fd: c_int) c_int;

// NOFOLLOW: if the log path is a pre-existing symlink, fail the open rather than
// follow it (cheap defense against a planted-symlink redirect). A first run with
// no file still creates a plain regular file via CREAT.
const open_append_flags: c_int = @bitCast(std.posix.O{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .NOFOLLOW = true });

/// Gate for `.debug`-level lines. Flipped on by `--debug` / `ZIGOKU_DEBUG`.
/// Higher levels (info/warn/err) always emit.
pub var debug_enabled: bool = false;

/// When set, log lines append here instead of going to stderr. `main.zig` points
/// this at `{dataDir}/zigoku.log` before entering the TUI (where stderr is the
/// render surface). Left null on the CLI path, so diagnostics reach the terminal.
/// Set once before any worker thread spawns; never mutated afterward.
pub var file_path: ?[]const u8 = null;

/// `std.options.logFn` handler. Formats one line and routes it to the file (TUI)
/// or stderr (CLI), suppressing `.debug` unless `debug_enabled`.
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

// Call-site API. Thin pass-throughs to `std.log` so callers have one import and
// a consistent vocabulary; the real routing/gating happens in `logFn`. (Existing
// `std.log.*` calls elsewhere hit the same handler — both styles are fine.)
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

/// True if `ZIGOKU_DEBUG` is set to a recognized truthy value. Explicit falsy
/// values ("0", "false", "no", "off") and an unset/empty var all mean off — so
/// `ZIGOKU_DEBUG=0` does the obvious thing rather than enabling on non-emptiness.
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
        // file_path set means TUI mode, where stderr is the render surface — if
        // the open (or path) failed, drop the line rather than corrupt the frame.
        return;
    }
    writeAll(2, bytes); // CLI: stderr is free
}

/// Write every byte, advancing past short writes. A regular-file `O_APPEND` write
/// of a sub-buffer line won't fragment in practice, but ignoring the return
/// entirely would silently truncate one. Best-effort: a hard error (or a 0/-1
/// return) ends the attempt rather than spinning.
fn writeAll(fd: c_int, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return; // error or nothing written — give up (logging is best-effort)
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
    const fd = open(path.ptr, @bitCast(std.posix.O{ .ACCMODE = .RDONLY })); // RDONLY: no O_CREAT, mode omitted
    if (fd < 0) return null; // file never created
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
    // Call the handler directly: in a test binary `@import("root")` is the test
    // runner, so `std.log` (and thus the `debug`/`err` wrappers) routes to the
    // default handler, not ours. `logFn` is the policy under test.
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
    try testing.expect(readBackAll(path, &buf) == null); // nothing written, file not created

    logFn(.err, .default, "boom {s}", .{"now"}); // higher levels ignore the gate
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
    try testing.expect(!envDebug()); // unset → off

    for ([_][:0]const u8{ "1", "true", "YES", "on" }) |truthy| {
        _ = libc.setenv("ZIGOKU_DEBUG", truthy.ptr, 1);
        try testing.expect(envDebug());
    }
    for ([_][:0]const u8{ "0", "false", "no", "off", "" }) |falsy| {
        _ = libc.setenv("ZIGOKU_DEBUG", falsy.ptr, 1);
        try testing.expect(!envDebug());
    }
}

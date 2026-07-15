//! Wall-clock deadline for unbounded ops (ROD-153; shared util ROD-262).
//! `std` has no per-read socket timeout; `withDeadline` races the op against a timer
//! and cancels the loser → bounded `error.Timeout`. Deadline VALUE is each provider's
//! policy; this module owns only the race.

const std = @import("std");
const Io = std.Io;

// Routes through app logFn (TUI-safe). `warn`: hitting a fallback means the wall-clock
// ceiling is gone.
const log = std.log.scoped(.deadline);

/// Success payload of a `!T` operation: `withDeadline` returns this or `error.Timeout`.
pub fn DeadlinePayload(comptime Func: type) type {
    return @typeInfo(@typeInfo(Func).@"fn".return_type.?).error_union.payload;
}

/// Run `func(args...)`, abort if it outlives `deadline`. Timer win → cancel blocked recv
/// → `error.Timeout`. No concurrency available → run inline, unbounded (logged).
pub fn withDeadline(
    io: Io,
    deadline: Io.Duration,
    comptime func: anytype,
    args: std.meta.ArgsTuple(@TypeOf(func)),
) anyerror!DeadlinePayload(@TypeOf(func)) {
    const Ret = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    const Outcome = union(enum) { done: Ret, timed_out: void };
    var buf: [2]Outcome = undefined;
    var sel: Io.Select(Outcome) = .init(io, &buf);
    sel.concurrent(.done, func, args) catch {
        // No concurrency (OOM / pool full). Inline is correct but unbounded (ROD-262).
        log.warn("concurrency unavailable — running operation inline with no deadline", .{});
        return @call(.auto, func, args);
    };
    sel.concurrent(.timed_out, sleepTimer, .{ io, deadline }) catch {
        // Timer failed to arm; op is already in flight. Do not re-invoke func (double
        // fetch, ROD-264 #2) and do not await unbounded (hang + stuck worker caps,
        // ROD-264 #1/#3). Cancel in-flight and surface Timeout (bounded).
        log.warn("deadline timer unavailable — cancelling operation, surfacing timeout", .{});
        while (sel.cancel()) |_| {}
        return error.Timeout;
    };
    const first = sel.await() catch {
        while (sel.cancel()) |_| {}
        return error.Timeout;
    };
    // Drain losers so frames reclaim. KNOWN RESIDUAL (ROD-265): dropping cancel()
    // outcomes can leak a live gpa payload if the timer wins in the µs after the op
    // clears its last cancel point. Arena callers reclaim at request scope; a
    // gpa-backed caller (cover fetch) leaks it. Left as-is (needs success within
    // µs of deadline; generic free needs a finalizer).
    while (sel.cancel()) |_| {}
    return switch (first) {
        .done => |r| r,
        .timed_out => error.Timeout,
    };
}

fn sleepTimer(io: Io, deadline: Io.Duration) void {
    io.sleep(deadline, .awake) catch {}; // .awake = monotonic; cancel → return
}

test "withDeadline: aborts an operation that outlives the deadline (ROD-153)" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const stalled = struct {
        fn run(i: Io) ![]const u8 {
            try i.sleep(Io.Duration.fromSeconds(30), .awake);
            return "unreachable";
        }
    }.run;
    try std.testing.expectError(
        error.Timeout,
        withDeadline(io, Io.Duration.fromMilliseconds(20), stalled, .{io}),
    );
}

test "withDeadline: returns a fast operation's result untouched (ROD-153)" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const quick = struct {
        fn run() ![]const u8 {
            return "ok";
        }
    }.run;
    const out = try withDeadline(io, Io.Duration.fromSeconds(30), quick, .{});
    try std.testing.expectEqualStrings("ok", out);
}

test "withDeadline: propagates a winning operation's error untouched (ROD-153)" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const failing = struct {
        fn run() ![]const u8 {
            return error.Boom;
        }
    }.run;
    try std.testing.expectError(
        error.Boom,
        withDeadline(io, Io.Duration.fromSeconds(30), failing, .{}),
    );
}

test "withDeadline: no double-fetch and no unbounded wait when the timer arm can't spawn (ROD-264)" {
    // 1-slot pool: op takes concurrency, timer arm fails → cancel + Timeout once (ROD-264).
    // Suppress expected warn noise (test binary has no std_options logFn).
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();

    var calls: std.atomic.Value(u32) = .init(0);
    const op = struct {
        fn run(i: Io, c: *std.atomic.Value(u32)) ![]const u8 {
            _ = c.fetchAdd(1, .acq_rel);
            i.sleep(Io.Duration.fromSeconds(30), .awake) catch {};
            return "unreachable";
        }
    }.run;

    try std.testing.expectError(
        error.Timeout,
        withDeadline(io, Io.Duration.fromSeconds(30), op, .{ io, &calls }),
    );
    try std.testing.expectEqual(@as(u32, 1), calls.load(.acquire));
}

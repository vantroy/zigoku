//! Wall-clock deadline for an otherwise-unbounded operation (ROD-153, generalized
//! to a shared util in ROD-262). `std` exposes no per-read socket timeout, so a
//! reachable-but-silent host can hang a fetch forever. `withDeadline` races the
//! operation against a timer on a separate unit of concurrency and cancels
//! whichever loses, turning an unbounded hang into a bounded `error.Timeout`.
//!
//! Provider-agnostic: the AllAnime long-tail GET (ROD-153) and every AniList
//! enrichment POST (ROD-262) both route their fetch through this. The deadline
//! *value* stays each provider's own policy — this module owns only the race.

const std = @import("std");
const Io = std.Io;

// Routes through the app's `std_options.logFn` (log.zig) like every other call
// site — TUI-safe. `warn`, not `debug`: hitting a fallback means the wall-clock
// ceiling this module exists to enforce is gone, so it always emits.
const log = std.log.scoped(.deadline);

/// The success payload of a `!T`-returning operation — `withDeadline` returns this
/// (or `error.Timeout`).
pub fn DeadlinePayload(comptime Func: type) type {
    return @typeInfo(@typeInfo(Func).@"fn".return_type.?).error_union.payload;
}

/// Run `func(args...)`, but abort it if it outlives `deadline`. std offers no
/// per-read deadline on a socket, so we race the operation against a timer on a
/// separate unit of concurrency and cancel whichever loses. If the timer wins,
/// the operation's next cancelation point — the blocked `recv`, which the
/// Threaded backend interrupts with a signal — returns `error.Canceled`, the
/// task unwinds (freeing its connection), and we surface `error.Timeout`. If
/// the runtime can't hand us concurrency (single-threaded build), fall back to
/// running inline, unbounded — correct, just without the wall-clock ceiling.
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
        // No unit of concurrency to spawn the op on (OOM, or the thread pool is at
        // capacity and can't grow). Run it inline — correct, but with no deadline,
        // so log it: this is the one door through which the unbounded hang can
        // return (ROD-262).
        log.warn("concurrency unavailable — running operation inline with no deadline", .{});
        return @call(.auto, func, args);
    };
    sel.concurrent(.timed_out, sleepTimer, .{ io, deadline }) catch {
        // Timer didn't arm (OOM — the op arm above already proved concurrency was
        // available, so the op is *in flight*). We now have no deadline. Two wrong
        // ways out: the old code cancelled the op and re-invoked `func` — a SECOND
        // request for one logical call (ROD-264 #2); simply awaiting the op instead
        // trades that for an *unbounded* hang on a dead socket. That hang also leaks
        // the caller's concurrency accounting — a worker that never returns never
        // runs its `defer`s, and a caller-side cap that reads that count then stays
        // tripped (ROD-264 #1/#3). Do neither: cancel the in-flight op (its blocked
        // recv is interrupted, so this returns promptly) and surface error.Timeout —
        // the same bounded outcome as a real timeout, which every caller handles.
        log.warn("deadline timer unavailable — cancelling operation, surfacing timeout", .{});
        while (sel.cancel()) |_| {}
        return error.Timeout;
    };
    const first = sel.await() catch {
        while (sel.cancel()) |_| {}
        return error.Timeout;
    };
    // await pulled the winner; cancel() requests + joins every loser (looped
    // until null so each task's resources are reclaimed), so by return the
    // canceled operation has fully unwound — no borrowed state outlives this frame.
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
    // Stands in for a stalled fetch: sleeps far past the deadline. The deadline's
    // cancel turns the sleep into error.Canceled, so the task never reaches return.
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
    // The op losing-or-winning the race must pass its own error through, not have
    // it masked by the deadline machinery — a fetch leans on this to surface its
    // own network error. Here the op finishes (with an error) well inside the deadline.
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
    // Reproduce the timer-arm-failure branch deterministically. A 1-slot pool means
    // the operation arm takes the only unit of concurrency, so withDeadline's *timer*
    // arm fails to arm (ConcurrencyUnavailable) — the exact branch ROD-264 #1/#2 fixed.
    // Contract: cancel the in-flight op and surface error.Timeout (bounded — no hang
    // on a dead socket), and invoke `func` exactly ONCE (the pre-fix code re-invoked
    // it inline, a second request for one logical call).
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();

    var calls: std.atomic.Value(u32) = .init(0);
    const op = struct {
        fn run(i: Io, c: *std.atomic.Value(u32)) ![]const u8 {
            _ = c.fetchAdd(1, .acq_rel);
            // Hold the lone slot past withDeadline's timer-arm attempt (Threaded
            // decrements busy_count only when the op returns, on the worker), so
            // the fail branch is hit with no race. The branch's cancel interrupts
            // this sleep; the op count is what the assertion pins.
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

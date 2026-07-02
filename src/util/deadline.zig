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
    sel.concurrent(.done, func, args) catch return @call(.auto, func, args);
    sel.concurrent(.timed_out, sleepTimer, .{ io, deadline }) catch {
        // Timer didn't arm (OOM — the fetch arm already proved concurrency is
        // available). Awaiting the lone fetch here would reintroduce the very
        // unbounded hang this race exists to kill, so cancel it and fall back
        // to the inline, unbounded run instead — same contract as the .done arm.
        while (sel.cancel()) |_| {}
        return @call(.auto, func, args);
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
